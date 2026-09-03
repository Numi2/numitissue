import Foundation

public struct BiologicalNativeLocatorResolution: Sendable, Equatable {
    public var originalLocator: DataLocator
    public var resolvedRequest: BiologicalDataRequest
    public var resolverID: String
    public var metadata: [String: String]

    public init(
        originalLocator: DataLocator,
        resolvedRequest: BiologicalDataRequest,
        resolverID: String,
        metadata: [String: String] = [:]
    ) {
        self.originalLocator = originalLocator
        self.resolvedRequest = resolvedRequest
        self.resolverID = resolverID
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        _ = try originalLocator.validated()
        _ = try resolvedRequest.validated()
        guard !resolverID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              resolvedRequest.locator.scheme == .https ||
                resolvedRequest.locator.scheme == .local,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw NativeBiologicalDataTransportError.invalidResolution(resolverID)
        }
        return self
    }
}

public protocol BiologicalNativeLocatorResolver: Sendable {
    var resolverID: String { get }
    var scheme: DataLocatorScheme { get }

    func resolve(
        _ request: BiologicalDataRequest
    ) throws -> BiologicalNativeLocatorResolution
}

public struct BiologicalNativeLocatorResolverRegistry: Sendable {
    private let resolvers: [DataLocatorScheme: any BiologicalNativeLocatorResolver]

    public init(
        resolvers sourceResolvers: [any BiologicalNativeLocatorResolver]
    ) throws {
        var result: [DataLocatorScheme: any BiologicalNativeLocatorResolver] = [:]
        for resolver in sourceResolvers {
            guard !resolver.resolverID
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty else {
                throw NativeBiologicalDataTransportError.invalidResolver(
                    resolver.resolverID
                )
            }
            guard resolver.scheme != .https, resolver.scheme != .local else {
                throw NativeBiologicalDataTransportError.directSchemeRegistration(
                    resolver.scheme
                )
            }
            guard result[resolver.scheme] == nil else {
                throw NativeBiologicalDataTransportError.duplicateResolver(
                    resolver.scheme
                )
            }
            result[resolver.scheme] = resolver
        }
        resolvers = result
    }

    public var schemes: Set<DataLocatorScheme> { Set(resolvers.keys) }

    public func resolverID(for scheme: DataLocatorScheme) -> String? {
        resolvers[scheme]?.resolverID
    }

    public func resolve(
        _ sourceRequest: BiologicalDataRequest
    ) throws -> BiologicalNativeLocatorResolution {
        let request = try sourceRequest.validated()
        guard request.locator.scheme != .https,
              request.locator.scheme != .local else {
            throw NativeBiologicalDataTransportError.directLocator(
                request.locator.canonicalDescription
            )
        }
        guard let resolver = resolvers[request.locator.scheme] else {
            throw NativeBiologicalDataTransportError.missingResolver(
                request.locator.scheme
            )
        }
        let resolution = try resolver.resolve(request).validated()
        guard resolution.originalLocator == request.locator,
              resolution.resolvedRequest.id == request.id else {
            throw NativeBiologicalDataTransportError.invalidResolution(
                resolver.resolverID
            )
        }
        return resolution
    }
}

public struct NativeLocatorBiologicalDataTransport: BiologicalDataTransport {
    public let downstream: any BiologicalDataTransport
    public let resolvers: BiologicalNativeLocatorResolverRegistry

    public init(
        downstream: any BiologicalDataTransport,
        resolvers: BiologicalNativeLocatorResolverRegistry
    ) {
        self.downstream = downstream
        self.resolvers = resolvers
    }

    public func execute(
        _ sourceRequest: BiologicalDataRequest
    ) async throws -> BiologicalDataResponse {
        let request = try sourceRequest.validated()
        let resolution = try resolvers.resolve(request)
        let response = try await downstream.execute(resolution.resolvedRequest)
        guard response.requestID == request.id else {
            throw NativeBiologicalDataTransportError.responseIdentityMismatch(
                request.id
            )
        }
        return response
    }
}

public enum NativeBiologicalDataTransportError: Error, Sendable, CustomStringConvertible {
    case invalidResolver(String)
    case duplicateResolver(DataLocatorScheme)
    case missingResolver(DataLocatorScheme)
    case directSchemeRegistration(DataLocatorScheme)
    case directLocator(String)
    case locatorSchemeMismatch(
        expected: DataLocatorScheme,
        actual: DataLocatorScheme
    )
    case invalidResolution(String)
    case responseIdentityMismatch(String)
    case invalidConfiguration(String)
    case invalidServiceURL(String)
    case invalidPathComponent(String)
    case invalidObjectKey(String)
    case unsupportedOperation(String)
    case invalidPayload(String)

    public var description: String {
        switch self {
        case .invalidResolver(let identifier):
            return "Native biological locator resolver \(identifier) is invalid."
        case .duplicateResolver(let scheme):
            return "A native biological locator resolver is already registered for \(scheme.rawValue)."
        case .missingResolver(let scheme):
            return "No native biological locator resolver is registered for \(scheme.rawValue)."
        case .directSchemeRegistration(let scheme):
            return "Direct locator scheme \(scheme.rawValue) must not be registered as native."
        case .directLocator(let locator):
            return "Direct locator \(locator) does not require native resolution."
        case .locatorSchemeMismatch(let expected, let actual):
            return "Resolver for \(expected.rawValue) received \(actual.rawValue)."
        case .invalidResolution(let identifier):
            return "Native biological locator resolver \(identifier) produced an invalid request."
        case .responseIdentityMismatch(let requestID):
            return "Native biological transport returned a mismatched response for \(requestID)."
        case .invalidConfiguration(let identifier):
            return "Native biological locator configuration \(identifier) is invalid."
        case .invalidServiceURL(let value):
            return "Native biological service URL is invalid: \(value)."
        case .invalidPathComponent(let value):
            return "Native biological service path component is invalid: \(value)."
        case .invalidObjectKey(let value):
            return "Native biological object key is invalid: \(value)."
        case .unsupportedOperation(let value):
            return "Native biological operation is unsupported: \(value)."
        case .invalidPayload(let value):
            return "Native biological request payload is invalid: \(value)."
        }
    }
}

extension BiologicalDataRequest {
    func resolving(
        locator: DataLocator,
        method: BiologicalRequestMethod? = nil,
        headers: [String: String]? = nil,
        body: Data?? = nil,
        byteRange: ByteRange?? = nil
    ) -> Self {
        Self(
            id: id,
            method: method ?? self.method,
            locator: locator,
            byteRange: byteRange ?? self.byteRange,
            headers: headers ?? self.headers,
            body: body ?? self.body,
            credentialScope: credentialScope,
            timeoutSeconds: timeoutSeconds,
            maximumResponseBytes: maximumResponseBytes
        )
    }
}

enum BiologicalNativeURLBuilder {
    static func baseComponents(_ source: String) throws -> URLComponents {
        guard var components = URLComponents(string: source),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw NativeBiologicalDataTransportError.invalidServiceURL(source)
        }
        let normalized = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/")
        components.path = normalized.isEmpty ? "" : "/" + normalized
        return components
    }

    static func pathComponent(_ source: String) throws -> String {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("\0") else {
            throw NativeBiologicalDataTransportError.invalidPathComponent(source)
        }
        return value
    }

    static func objectKeyComponents(_ source: String) throws -> [String] {
        guard !source.isEmpty,
              !source.hasPrefix("/"),
              !source.contains("\\"),
              !source.contains("\0") else {
            throw NativeBiologicalDataTransportError.invalidObjectKey(source)
        }
        let components = source
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw NativeBiologicalDataTransportError.invalidObjectKey(source)
        }
        return components
    }

    static func url(
        baseURL: String,
        pathComponents: [String],
        queryItems: [URLQueryItem] = []
    ) throws -> String {
        var components = try baseComponents(baseURL)
        var path = components.path
        for component in pathComponents {
            path += "/" + (try pathComponent(component))
        }
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url?.absoluteString else {
            throw NativeBiologicalDataTransportError.invalidServiceURL(baseURL)
        }
        return url
    }
}
