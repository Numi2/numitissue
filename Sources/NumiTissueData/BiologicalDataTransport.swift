import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum DataLocatorScheme: String, Codable, Sendable, CaseIterable, Hashable {
    case https
    case s3
    case gcs
    case cave
    case dandi
    case modelDB
    case local
}

public extension DataLocator {
    var scheme: DataLocatorScheme {
        switch self {
        case .https: return .https
        case .s3: return .s3
        case .gcs: return .gcs
        case .cave: return .cave
        case .dandi: return .dandi
        case .modelDB: return .modelDB
        case .local: return .local
        }
    }
}

public struct BiologicalDataRequest: Sendable, Equatable {
    public var id: String
    public var method: BiologicalRequestMethod
    public var locator: DataLocator
    public var byteRange: ByteRange?
    public var headers: [String: String]
    public var body: Data?
    public var credentialScope: String?
    public var timeoutSeconds: Double?
    public var maximumResponseBytes: UInt64?

    public init(
        id: String,
        method: BiologicalRequestMethod,
        locator: DataLocator,
        byteRange: ByteRange? = nil,
        headers: [String: String] = [:],
        body: Data? = nil,
        credentialScope: String? = nil,
        timeoutSeconds: Double? = nil,
        maximumResponseBytes: UInt64? = nil
    ) {
        self.id = id
        self.method = method
        self.locator = locator
        self.byteRange = byteRange
        self.headers = headers
        self.body = body
        self.credentialScope = credentialScope
        self.timeoutSeconds = timeoutSeconds
        self.maximumResponseBytes = maximumResponseBytes
    }

    public init(
        query: DatasetQueryRequest,
        timeoutSeconds: Double? = nil,
        maximumResponseBytes: UInt64? = nil,
        additionalHeaders: [String: String] = [:]
    ) {
        var merged = query.headers
        for key in additionalHeaders.keys.sorted() {
            merged[key] = additionalHeaders[key]
        }
        self.init(
            id: query.id,
            method: query.method,
            locator: query.locator,
            byteRange: query.byteRange,
            headers: merged,
            body: query.body,
            credentialScope: query.credentialScope,
            timeoutSeconds: timeoutSeconds,
            maximumResponseBytes: maximumResponseBytes
        )
    }

    public func validated() throws -> Self {
        guard !id.isEmpty,
              timeoutSeconds.map({ $0.isFinite && $0 > 0 }) ?? true,
              maximumResponseBytes.map({ $0 > 0 }) ?? true,
              headers.keys.allSatisfy({ !$0.isEmpty }) else {
            throw BiologicalTransportError.invalidRequest(id)
        }
        _ = try locator.validated()
        if let byteRange { _ = try byteRange.validated() }
        if method != .post, body != nil {
            throw BiologicalTransportError.invalidRequest(id)
        }
        return self
    }
}

public struct BiologicalDataResponse: Sendable, Equatable {
    public var requestID: String
    public var statusCode: Int
    public var data: Data
    public var headers: [String: String]
    public var finalLocator: DataLocator
    public var receivedAt: Date
    public var transferDurationSeconds: Double

    public init(
        requestID: String,
        statusCode: Int,
        data: Data,
        headers: [String: String] = [:],
        finalLocator: DataLocator,
        receivedAt: Date = Date(),
        transferDurationSeconds: Double = 0
    ) {
        self.requestID = requestID
        self.statusCode = statusCode
        self.data = data
        self.headers = headers
        self.finalLocator = finalLocator
        self.receivedAt = receivedAt
        self.transferDurationSeconds = transferDurationSeconds
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }
    public var isNotModified: Bool { statusCode == 304 }
    public var etag: String? { header("etag") }
    public var lastModified: String? { header("last-modified") }
    public var contentType: String? { header("content-type") }
    public var contentRange: String? { header("content-range") }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

public protocol BiologicalDataTransport: Sendable {
    func execute(_ request: BiologicalDataRequest) async throws -> BiologicalDataResponse
}

public protocol BiologicalCredentialProvider: Sendable {
    func headers(
        for scope: String,
        locator: DataLocator
    ) async throws -> [String: String]
}

public struct NoBiologicalCredentials: BiologicalCredentialProvider {
    public init() {}

    public func headers(
        for scope: String,
        locator: DataLocator
    ) async throws -> [String: String] {
        [:]
    }
}

public struct BiologicalHTTPTransportConfiguration: Sendable, Equatable {
    public var userAgent: String
    public var defaultTimeoutSeconds: Double
    public var maximumResponseBytes: UInt64
    public var allowedHosts: Set<String>?
    public var requirePartialContentForRanges: Bool
    public var allowsCellularAccess: Bool
    public var waitsForConnectivity: Bool

    public init(
        userAgent: String = "NumiTissueData/1",
        defaultTimeoutSeconds: Double = 120,
        maximumResponseBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024,
        allowedHosts: Set<String>? = nil,
        requirePartialContentForRanges: Bool = true,
        allowsCellularAccess: Bool = true,
        waitsForConnectivity: Bool = true
    ) {
        self.userAgent = userAgent
        self.defaultTimeoutSeconds = defaultTimeoutSeconds
        self.maximumResponseBytes = maximumResponseBytes
        self.allowedHosts = allowedHosts
        self.requirePartialContentForRanges = requirePartialContentForRanges
        self.allowsCellularAccess = allowsCellularAccess
        self.waitsForConnectivity = waitsForConnectivity
    }

    public func validated() throws -> Self {
        guard !userAgent.isEmpty,
              defaultTimeoutSeconds.isFinite,
              defaultTimeoutSeconds > 0,
              maximumResponseBytes > 0,
              allowedHosts?.allSatisfy({ !$0.isEmpty }) ?? true else {
            throw BiologicalTransportError.invalidConfiguration
        }
        return self
    }
}

public actor URLSessionBiologicalDataTransport: BiologicalDataTransport {
    public let configuration: BiologicalHTTPTransportConfiguration
    private let session: URLSession
    private let credentials: any BiologicalCredentialProvider

    public init(
        configuration: BiologicalHTTPTransportConfiguration =
            BiologicalHTTPTransportConfiguration(),
        credentials: any BiologicalCredentialProvider = NoBiologicalCredentials(),
        sessionConfiguration: URLSessionConfiguration? = nil
    ) throws {
        self.configuration = try configuration.validated()
        self.credentials = credentials
        let urlConfiguration = sessionConfiguration ?? .ephemeral
        urlConfiguration.httpCookieStorage = nil
        urlConfiguration.httpShouldSetCookies = false
        urlConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        urlConfiguration.timeoutIntervalForRequest = configuration.defaultTimeoutSeconds
        urlConfiguration.timeoutIntervalForResource = configuration.defaultTimeoutSeconds
        urlConfiguration.allowsCellularAccess = configuration.allowsCellularAccess
        urlConfiguration.waitsForConnectivity = configuration.waitsForConnectivity
        urlConfiguration.httpMaximumConnectionsPerHost = 16
        session = URLSession(configuration: urlConfiguration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func execute(
        _ sourceRequest: BiologicalDataRequest
    ) async throws -> BiologicalDataResponse {
        let request = try sourceRequest.validated()
        guard case .https(let sourceURL) = request.locator,
              let url = URL(string: sourceURL),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            throw BiologicalTransportError.unsupportedLocator(
                request.locator.canonicalDescription
            )
        }
        if let allowedHosts = configuration.allowedHosts,
           !allowedHosts.contains(host) {
            throw BiologicalTransportError.hostNotAllowed(host)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeoutSeconds ??
            configuration.defaultTimeoutSeconds
        urlRequest.httpShouldHandleCookies = false
        urlRequest.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        for key in request.headers.keys.sorted() {
            urlRequest.setValue(request.headers[key], forHTTPHeaderField: key)
        }
        if let range = request.byteRange {
            guard let endOffset = range.endOffset, endOffset > 0 else {
                throw BiologicalTransportError.invalidRequest(request.id)
            }
            urlRequest.setValue(
                "bytes=\(range.offset)-\(endOffset - 1)",
                forHTTPHeaderField: "Range"
            )
        }
        if let scope = request.credentialScope {
            let credentialHeaders = try await credentials.headers(
                for: scope,
                locator: request.locator
            )
            for key in credentialHeaders.keys.sorted() {
                guard urlRequest.value(forHTTPHeaderField: key) == nil else {
                    throw BiologicalTransportError.credentialHeaderCollision(key)
                }
                urlRequest.setValue(
                    credentialHeaders[key],
                    forHTTPHeaderField: key
                )
            }
        }

        let start = ContinuousClock.now
        let (data, response) = try await session.data(for: urlRequest)
        let duration = start.duration(to: .now)
        guard let http = response as? HTTPURLResponse else {
            throw BiologicalTransportError.nonHTTPResponse(request.id)
        }
        let headers = Self.normalizedHeaders(http.allHeaderFields)
        let status = http.statusCode
        guard (200..<300).contains(status) || status == 304 else {
            throw BiologicalTransportError.httpStatus(
                status,
                requestID: request.id,
                retryAfter: headers["retry-after"]
            )
        }
        if request.byteRange != nil,
           configuration.requirePartialContentForRanges,
           status != 206,
           status != 304 {
            throw BiologicalTransportError.rangeIgnored(request.id)
        }

        let maximum = min(
            request.maximumResponseBytes ?? configuration.maximumResponseBytes,
            configuration.maximumResponseBytes
        )
        guard UInt64(data.count) <= maximum else {
            throw BiologicalTransportError.responseTooLarge(
                requestID: request.id,
                received: UInt64(data.count),
                maximum: maximum
            )
        }
        if let range = request.byteRange,
           status == 206,
           UInt64(data.count) > range.length {
            throw BiologicalTransportError.invalidRangeResponse(request.id)
        }

        let finalURL = http.url?.absoluteString ?? sourceURL
        return BiologicalDataResponse(
            requestID: request.id,
            statusCode: status,
            data: data,
            headers: headers,
            finalLocator: .https(url: finalURL),
            transferDurationSeconds: Self.seconds(duration)
        )
    }

    private static func normalizedHeaders(
        _ source: [AnyHashable: Any]
    ) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in source {
            result[String(describing: key).lowercased()] = String(describing: value)
        }
        return result
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) +
            Double(components.attoseconds) / 1e18
    }
}

public actor LocalFileBiologicalDataTransport: BiologicalDataTransport {
    public let allowedRoot: URL?

    public init(allowedRoot: URL? = nil) {
        self.allowedRoot = allowedRoot?.standardizedFileURL
    }

    public func execute(
        _ sourceRequest: BiologicalDataRequest
    ) async throws -> BiologicalDataResponse {
        let request = try sourceRequest.validated()
        guard case .local(let path) = request.locator,
              request.method == .get || request.method == .head else {
            throw BiologicalTransportError.unsupportedLocator(
                request.locator.canonicalDescription
            )
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if let allowedRoot {
            let root = allowedRoot.resolvingSymlinksInPath().pathComponents
            let candidate = url.resolvingSymlinksInPath().pathComponents
            guard candidate.count >= root.count,
                  Array(candidate.prefix(root.count)) == root else {
                throw BiologicalTransportError.localPathOutsideRoot(path)
            }
        }

        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .isRegularFileKey
        ])
        guard values.isRegularFile == true else {
            throw BiologicalTransportError.localFileNotRegular(path)
        }
        let size = UInt64(values.fileSize ?? 0)
        let headers: [String: String] = [
            "content-length": String(size),
            "last-modified": values.contentModificationDate.map {
                ISO8601DateFormatter().string(from: $0)
            } ?? ""
        ]
        if request.method == .head {
            return BiologicalDataResponse(
                requestID: request.id,
                statusCode: 200,
                data: Data(),
                headers: headers,
                finalLocator: request.locator
            )
        }

        let data: Data
        if let range = request.byteRange {
            guard let endOffset = range.endOffset, endOffset <= size else {
                throw BiologicalTransportError.invalidRangeResponse(request.id)
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: range.offset)
            data = try handle.read(upToCount: Int(range.length)) ?? Data()
            guard UInt64(data.count) == range.length else {
                throw BiologicalTransportError.invalidRangeResponse(request.id)
            }
        } else {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        }
        if let maximum = request.maximumResponseBytes,
           UInt64(data.count) > maximum {
            throw BiologicalTransportError.responseTooLarge(
                requestID: request.id,
                received: UInt64(data.count),
                maximum: maximum
            )
        }
        return BiologicalDataResponse(
            requestID: request.id,
            statusCode: request.byteRange == nil ? 200 : 206,
            data: data,
            headers: headers,
            finalLocator: request.locator
        )
    }
}

public actor BiologicalDataTransportRouter: BiologicalDataTransport {
    private var transports: [DataLocatorScheme: any BiologicalDataTransport]

    public init(transports: [DataLocatorScheme: any BiologicalDataTransport] = [:]) {
        self.transports = transports
    }

    public func register(
        _ transport: any BiologicalDataTransport,
        for scheme: DataLocatorScheme
    ) {
        transports[scheme] = transport
    }

    public func execute(
        _ request: BiologicalDataRequest
    ) async throws -> BiologicalDataResponse {
        guard let transport = transports[request.locator.scheme] else {
            throw BiologicalTransportError.missingTransport(
                request.locator.scheme
            )
        }
        return try await transport.execute(request)
    }
}

public enum BiologicalTransportError: Error, Sendable, CustomStringConvertible {
    case invalidConfiguration
    case invalidRequest(String)
    case unsupportedLocator(String)
    case missingTransport(DataLocatorScheme)
    case hostNotAllowed(String)
    case credentialHeaderCollision(String)
    case nonHTTPResponse(String)
    case httpStatus(Int, requestID: String, retryAfter: String?)
    case rangeIgnored(String)
    case invalidRangeResponse(String)
    case responseTooLarge(requestID: String, received: UInt64, maximum: UInt64)
    case localPathOutsideRoot(String)
    case localFileNotRegular(String)

    public var description: String {
        switch self {
        case .invalidConfiguration:
            return "Biological data transport configuration is invalid."
        case .invalidRequest(let identifier):
            return "Biological data request \(identifier) is invalid."
        case .unsupportedLocator(let value):
            return "Biological data locator is unsupported: \(value)."
        case .missingTransport(let scheme):
            return "No biological data transport is registered for \(scheme.rawValue)."
        case .hostNotAllowed(let host):
            return "Biological data host \(host) is not permitted."
        case .credentialHeaderCollision(let header):
            return "Credential header \(header) conflicts with a planned request header."
        case .nonHTTPResponse(let request):
            return "Biological data request \(request) returned a non-HTTP response."
        case .httpStatus(let status, let requestID, _):
            return "Biological data request \(requestID) returned HTTP \(status)."
        case .rangeIgnored(let request):
            return "Biological data request \(request) ignored the required byte range."
        case .invalidRangeResponse(let request):
            return "Biological data request \(request) returned an invalid range."
        case .responseTooLarge(let requestID, let received, let maximum):
            return "Biological data request \(requestID) returned \(received) bytes; maximum is \(maximum)."
        case .localPathOutsideRoot(let path):
            return "Local biological data path is outside the permitted root: \(path)."
        case .localFileNotRegular(let path):
            return "Local biological data path is not a regular file: \(path)."
        }
    }
}
