import Foundation

public struct DANDINativeLocatorResolverConfiguration: Sendable, Equatable {
    public var apiBaseURL: String
    public var pageSize: Int
    public var orderByPath: Bool

    public init(
        apiBaseURL: String = "https://api.dandiarchive.org/api",
        pageSize: Int = 100,
        orderByPath: Bool = true
    ) {
        self.apiBaseURL = apiBaseURL
        self.pageSize = pageSize
        self.orderByPath = orderByPath
    }

    public func validated() throws -> Self {
        _ = try BiologicalNativeURLBuilder.baseComponents(apiBaseURL)
        guard pageSize > 0, pageSize <= 1_000 else {
            throw NativeBiologicalDataTransportError.invalidConfiguration(
                "dandi"
            )
        }
        return self
    }
}

public struct DANDINativeLocatorResolver: BiologicalNativeLocatorResolver {
    public let configuration: DANDINativeLocatorResolverConfiguration

    public init(
        configuration: DANDINativeLocatorResolverConfiguration =
            DANDINativeLocatorResolverConfiguration()
    ) throws {
        self.configuration = try configuration.validated()
    }

    public var resolverID: String { "dandi-rest-v1" }
    public var scheme: DataLocatorScheme { .dandi }

    public func resolve(
        _ sourceRequest: BiologicalDataRequest
    ) throws -> BiologicalNativeLocatorResolution {
        let request = try sourceRequest.validated()
        guard case .dandi(let dandiset, let version, let assetPath) = request.locator else {
            throw NativeBiologicalDataTransportError.locatorSchemeMismatch(
                expected: scheme,
                actual: request.locator.scheme
            )
        }
        guard request.method == .get || request.method == .head else {
            throw NativeBiologicalDataTransportError.unsupportedOperation(
                "DANDI \(request.method.rawValue)"
            )
        }
        var queryItems = [
            URLQueryItem(name: "page_size", value: String(configuration.pageSize))
        ]
        if configuration.orderByPath {
            queryItems.append(URLQueryItem(name: "ordering", value: "path"))
        }
        if let assetPath {
            guard !assetPath.isEmpty else {
                throw NativeBiologicalDataTransportError.invalidPathComponent(
                    assetPath
                )
            }
            queryItems.append(URLQueryItem(name: "path", value: assetPath))
        }
        var url = try BiologicalNativeURLBuilder.url(
            baseURL: configuration.apiBaseURL,
            pathComponents: [
                "dandisets",
                dandiset,
                "versions",
                version,
                "assets"
            ],
            queryItems: queryItems
        )
        url = try Self.withTrailingSlashBeforeQuery(url)
        var headers = request.headers
        headers["Accept"] = headers["Accept"] ?? "application/json"
        let resolved = request.resolving(
            locator: .https(url: url),
            headers: headers
        )
        return BiologicalNativeLocatorResolution(
            originalLocator: request.locator,
            resolvedRequest: resolved,
            resolverID: resolverID,
            metadata: [
                "repository": "dandi",
                "dandiset": dandiset,
                "version": version,
                "asset-path": assetPath ?? ""
            ]
        )
    }

    private static func withTrailingSlashBeforeQuery(_ source: String) throws -> String {
        guard var components = URLComponents(string: source) else {
            throw NativeBiologicalDataTransportError.invalidServiceURL(source)
        }
        if !components.path.hasSuffix("/") { components.path += "/" }
        guard let result = components.url?.absoluteString else {
            throw NativeBiologicalDataTransportError.invalidServiceURL(source)
        }
        return result
    }
}

public struct ModelDBNativeLocatorResolverConfiguration: Sendable, Equatable {
    public var apiBaseURL: String

    public init(apiBaseURL: String = "https://modeldb.science/api/v1") {
        self.apiBaseURL = apiBaseURL
    }

    public func validated() throws -> Self {
        _ = try BiologicalNativeURLBuilder.baseComponents(apiBaseURL)
        return self
    }
}

public struct ModelDBNativeLocatorResolver: BiologicalNativeLocatorResolver {
    public let configuration: ModelDBNativeLocatorResolverConfiguration

    public init(
        configuration: ModelDBNativeLocatorResolverConfiguration =
            ModelDBNativeLocatorResolverConfiguration()
    ) throws {
        self.configuration = try configuration.validated()
    }

    public var resolverID: String { "modeldb-rest-v1" }
    public var scheme: DataLocatorScheme { .modelDB }

    public func resolve(
        _ sourceRequest: BiologicalDataRequest
    ) throws -> BiologicalNativeLocatorResolution {
        let request = try sourceRequest.validated()
        guard case .modelDB(let accession, let path) = request.locator else {
            throw NativeBiologicalDataTransportError.locatorSchemeMismatch(
                expected: scheme,
                actual: request.locator.scheme
            )
        }
        guard request.method == .get || request.method == .head else {
            throw NativeBiologicalDataTransportError.unsupportedOperation(
                "ModelDB \(request.method.rawValue)"
            )
        }
        guard path == nil else {
            throw NativeBiologicalDataTransportError.unsupportedOperation(
                "ModelDB code path discovery must be decoded from the model record"
            )
        }
        let url = try BiologicalNativeURLBuilder.url(
            baseURL: configuration.apiBaseURL,
            pathComponents: ["models", String(accession)]
        )
        var headers = request.headers
        headers["Accept"] = headers["Accept"] ?? "application/json"
        return BiologicalNativeLocatorResolution(
            originalLocator: request.locator,
            resolvedRequest: request.resolving(
                locator: .https(url: url),
                headers: headers
            ),
            resolverID: resolverID,
            metadata: [
                "repository": "modeldb",
                "accession": String(accession)
            ]
        )
    }
}
