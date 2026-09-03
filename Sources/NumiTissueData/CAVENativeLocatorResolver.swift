import Foundation
import NumiTissueIO

public struct CAVENativeLocatorResolverConfiguration: Sendable, Equatable {
    public var apiVersion: Int
    public var defaultServiceBaseURL: String?
    public var serviceBaseURLByDatastack: [String: String]
    public var responseCompression: String

    public init(
        apiVersion: Int = 3,
        defaultServiceBaseURL: String? = nil,
        serviceBaseURLByDatastack: [String: String] = [:],
        responseCompression: String = "gzip"
    ) {
        self.apiVersion = apiVersion
        self.defaultServiceBaseURL = defaultServiceBaseURL
        self.serviceBaseURLByDatastack = serviceBaseURLByDatastack
        self.responseCompression = responseCompression
    }

    public func validated() throws -> Self {
        guard apiVersion == 2 || apiVersion == 3,
              !responseCompression.isEmpty,
              serviceBaseURLByDatastack.keys.allSatisfy({ !$0.isEmpty }) else {
            throw NativeBiologicalDataTransportError.invalidConfiguration("cave")
        }
        if let defaultServiceBaseURL {
            _ = try BiologicalNativeURLBuilder.baseComponents(defaultServiceBaseURL)
        }
        for value in serviceBaseURLByDatastack.values {
            _ = try BiologicalNativeURLBuilder.baseComponents(value)
        }
        return self
    }
}

public struct CAVENativeLocatorResolver: BiologicalNativeLocatorResolver {
    public let configuration: CAVENativeLocatorResolverConfiguration

    public init(
        configuration: CAVENativeLocatorResolverConfiguration =
            CAVENativeLocatorResolverConfiguration()
    ) throws {
        self.configuration = try configuration.validated()
    }

    public var resolverID: String { "cave-materialization-v3" }
    public var scheme: DataLocatorScheme { .cave }

    public func resolve(
        _ sourceRequest: BiologicalDataRequest
    ) throws -> BiologicalNativeLocatorResolution {
        let request = try sourceRequest.validated()
        guard case .cave(
            let datastack,
            let locatorTable,
            let locatorVersion,
            let query
        ) = request.locator else {
            throw NativeBiologicalDataTransportError.locatorSchemeMismatch(
                expected: scheme,
                actual: request.locator.scheme
            )
        }
        guard let query,
              let queryData = query.data(using: .utf8) else {
            throw NativeBiologicalDataTransportError.invalidPayload(
                request.locator.canonicalDescription
            )
        }
        let descriptor = try ScientificCanonicalJSON.decode(
            CAVEQueryDescriptor.self,
            from: queryData
        ).validated()
        guard descriptor.table == locatorTable,
              descriptor.materializationVersion == locatorVersion else {
            throw NativeBiologicalDataTransportError.invalidPayload(
                "CAVE locator and descriptor disagree"
            )
        }
        let serviceBaseURL = try serviceBaseURL(
            datastack: datastack,
            descriptor: descriptor
        )
        let resolution = try resolvedRequest(
            request,
            datastack: datastack,
            serviceBaseURL: serviceBaseURL,
            descriptor: descriptor
        )
        return BiologicalNativeLocatorResolution(
            originalLocator: request.locator,
            resolvedRequest: resolution,
            resolverID: resolverID,
            metadata: [
                "repository": "cave",
                "datastack": datastack,
                "operation": descriptor.operation.rawValue,
                "service-base-url": serviceBaseURL
            ]
        )
    }

    private func serviceBaseURL(
        datastack: String,
        descriptor: CAVEQueryDescriptor
    ) throws -> String {
        let value = descriptor.metadata["cave.server-base-url"] ??
            configuration.serviceBaseURLByDatastack[datastack] ??
            configuration.defaultServiceBaseURL
        guard let value else {
            throw NativeBiologicalDataTransportError.invalidConfiguration(
                "CAVE service URL for datastack \(datastack)"
            )
        }
        let components = try BiologicalNativeURLBuilder.baseComponents(value)
        guard let normalized = components.url?.absoluteString else {
            throw NativeBiologicalDataTransportError.invalidServiceURL(value)
        }
        return normalized.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
    }

    private func resolvedRequest(
        _ sourceRequest: BiologicalDataRequest,
        datastack: String,
        serviceBaseURL: String,
        descriptor: CAVEQueryDescriptor
    ) throws -> BiologicalDataRequest {
        var request = sourceRequest
        request.byteRange = nil
        var headers = request.headers
        headers["Accept"] = "application/json"

        switch descriptor.operation {
        case .datastackInfo:
            guard request.method == .get else {
                throw NativeBiologicalDataTransportError.unsupportedOperation(
                    "CAVE datastack info requires GET"
                )
            }
            request.locator = .https(url: try BiologicalNativeURLBuilder.url(
                baseURL: serviceBaseURL,
                pathComponents: [
                    "info",
                    "api",
                    "v2",
                    "datastack",
                    "full",
                    datastack
                ]
            ))
            request.body = nil
        case .materializationVersions:
            guard request.method == .get else {
                throw NativeBiologicalDataTransportError.unsupportedOperation(
                    "CAVE materialization versions require GET"
                )
            }
            request.locator = .https(url: try BiologicalNativeURLBuilder.url(
                baseURL: serviceBaseURL,
                pathComponents: [
                    "materialize",
                    "api",
                    "v\(configuration.apiVersion)",
                    "datastack",
                    datastack,
                    "versions"
                ],
                queryItems: [URLQueryItem(name: "expired", value: "true")]
            ))
            request.body = nil
        case .materializationTable:
            guard request.method == .post,
                  let table = descriptor.table,
                  let version = descriptor.materializationVersion else {
                throw NativeBiologicalDataTransportError.unsupportedOperation(
                    "CAVE table query requires POST, table, and materialization"
                )
            }
            request.locator = .https(url: try BiologicalNativeURLBuilder.url(
                baseURL: serviceBaseURL,
                pathComponents: [
                    "materialize",
                    "api",
                    "v\(configuration.apiVersion)",
                    "datastack",
                    datastack,
                    "version",
                    String(version),
                    "table",
                    table,
                    "query"
                ],
                queryItems: [
                    URLQueryItem(name: "return_pyarrow", value: "false"),
                    URLQueryItem(name: "arrow_format", value: "false"),
                    URLQueryItem(name: "split_positions", value: "true"),
                    URLQueryItem(name: "direct_sql_pandas", value: "true")
                ]
            ))
            request.body = try serverQueryBody(descriptor, table: table)
            headers["Content-Type"] = "application/json"
            headers["Accept-Encoding"] = configuration.responseCompression
        }
        request.headers = headers
        return try request.validated()
    }

    private func serverQueryBody(
        _ descriptor: CAVEQueryDescriptor,
        table: String
    ) throws -> Data {
        var payload: [String: Any] = [:]
        if !descriptor.filterIn.isEmpty {
            payload["filter_in_dict"] = [
                table: descriptor.filterIn.mapValues {
                    $0.map(Self.scalarValue)
                }
            ]
        }
        if !descriptor.filterEqual.isEmpty {
            payload["filter_equal_dict"] = [
                table: descriptor.filterEqual.mapValues(Self.scalarValue)
            ]
        }
        if !descriptor.spatialBounds.isEmpty {
            guard descriptor.spatialBounds.count == 1,
                  let column = descriptor.metadata["cave.spatial-column"],
                  !column.isEmpty else {
                throw NativeBiologicalDataTransportError.invalidPayload(
                    "CAVE query requires one spatial window and a spatial column"
                )
            }
            let bounds = try descriptor.spatialBounds[0].validated()
            payload["filter_spatial_dict"] = [
                table: [column: [bounds.minimum, bounds.maximum]]
            ]
        }
        if !descriptor.selectedColumns.isEmpty {
            payload["select_columns"] = descriptor.selectedColumns
        }
        if descriptor.offset > 0 { payload["offset"] = descriptor.offset }
        if let limit = descriptor.limit { payload["limit"] = limit }
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw NativeBiologicalDataTransportError.invalidPayload(
                "CAVE materialization query"
            )
        }
        return try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )
    }

    private static func scalarValue(_ source: String) -> Any {
        if let value = UInt64(source) { return NSNumber(value: value) }
        if let value = Int64(source) { return NSNumber(value: value) }
        if let value = Double(source), value.isFinite {
            return NSNumber(value: value)
        }
        switch source.lowercased() {
        case "true": return NSNumber(value: true)
        case "false": return NSNumber(value: false)
        default: return source
        }
    }
}
