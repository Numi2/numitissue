import Foundation

public struct PublicCloudObjectEndpointConfiguration: Sendable, Equatable {
    public var awsRegion: String?
    public var awsEndpointSuffix: String
    public var forceS3PathStyle: Bool
    public var googleStorageHost: String

    public init(
        awsRegion: String? = nil,
        awsEndpointSuffix: String = "amazonaws.com",
        forceS3PathStyle: Bool = false,
        googleStorageHost: String = "storage.googleapis.com"
    ) {
        self.awsRegion = awsRegion
        self.awsEndpointSuffix = awsEndpointSuffix
        self.forceS3PathStyle = forceS3PathStyle
        self.googleStorageHost = googleStorageHost
    }

    public func validated() throws -> Self {
        guard awsRegion.map(Self.isDNSLabel) ?? true,
              Self.isDNSName(awsEndpointSuffix),
              Self.isDNSName(googleStorageHost) else {
            throw NativeBiologicalDataTransportError.invalidConfiguration(
                "public-cloud-object"
            )
        }
        return self
    }

    fileprivate static func isDNSLabel(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 63,
              value.first != "-",
              value.last != "-" else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-"
        }
    }

    fileprivate static func isDNSName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 253 else { return false }
        return value.split(separator: ".").allSatisfy {
            isDNSLabel(String($0))
        }
    }
}

public struct PublicS3NativeLocatorResolver: BiologicalNativeLocatorResolver {
    public let configuration: PublicCloudObjectEndpointConfiguration

    public init(
        configuration: PublicCloudObjectEndpointConfiguration =
            PublicCloudObjectEndpointConfiguration()
    ) throws {
        self.configuration = try configuration.validated()
    }

    public var resolverID: String { "public-s3-https-v1" }
    public var scheme: DataLocatorScheme { .s3 }

    public func resolve(
        _ sourceRequest: BiologicalDataRequest
    ) throws -> BiologicalNativeLocatorResolution {
        let request = try sourceRequest.validated()
        guard case .s3(let bucket, let key, let versionID) = request.locator else {
            throw NativeBiologicalDataTransportError.locatorSchemeMismatch(
                expected: scheme,
                actual: request.locator.scheme
            )
        }
        let url = try s3URL(bucket: bucket, key: key, versionID: versionID)
        return BiologicalNativeLocatorResolution(
            originalLocator: request.locator,
            resolvedRequest: request.resolving(locator: .https(url: url)),
            resolverID: resolverID,
            metadata: [
                "object-store": "s3",
                "bucket": bucket,
                "key": key
            ]
        )
    }

    public func s3URL(
        bucket: String,
        key: String,
        versionID: String? = nil
    ) throws -> String {
        guard Self.isBucket(bucket), !key.isEmpty else {
            throw NativeBiologicalDataTransportError.invalidObjectKey(
                "s3://\(bucket)/\(key)"
            )
        }
        var components = URLComponents()
        components.scheme = "https"
        let regionalHost = configuration.awsRegion.map {
            "s3.\($0).\(configuration.awsEndpointSuffix)"
        } ?? "s3.\(configuration.awsEndpointSuffix)"
        let usePathStyle = configuration.forceS3PathStyle || bucket.contains(".")
        if usePathStyle {
            components.host = regionalHost
            components.percentEncodedPath = "/" + Self.encodePath(bucket + "/" + key)
        } else {
            components.host = bucket + "." + regionalHost
            components.percentEncodedPath = "/" + Self.encodePath(key)
        }
        if let versionID {
            guard !versionID.isEmpty else {
                throw NativeBiologicalDataTransportError.invalidObjectKey(
                    "s3://\(bucket)/\(key)"
                )
            }
            components.queryItems = [
                URLQueryItem(name: "versionId", value: versionID)
            ]
        }
        guard let url = components.url?.absoluteString else {
            throw NativeBiologicalDataTransportError.invalidObjectKey(
                "s3://\(bucket)/\(key)"
            )
        }
        return url
    }

    private static func isBucket(_ value: String) -> Bool {
        guard value.count >= 3,
              value.count <= 63,
              value.first != ".",
              value.last != ".",
              value.first != "-",
              value.last != "-",
              !value.contains("..") else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.lowercaseLetters.contains($0) ||
                CharacterSet.decimalDigits.contains($0) ||
                $0 == "." ||
                $0 == "-"
        }
    }

    private static func encodePath(_ value: String) -> String {
        PublicCloudObjectPathEncoding.encode(value)
    }
}

public struct PublicGCSNativeLocatorResolver: BiologicalNativeLocatorResolver {
    public let configuration: PublicCloudObjectEndpointConfiguration

    public init(
        configuration: PublicCloudObjectEndpointConfiguration =
            PublicCloudObjectEndpointConfiguration()
    ) throws {
        self.configuration = try configuration.validated()
    }

    public var resolverID: String { "public-gcs-https-v1" }
    public var scheme: DataLocatorScheme { .gcs }

    public func resolve(
        _ sourceRequest: BiologicalDataRequest
    ) throws -> BiologicalNativeLocatorResolution {
        let request = try sourceRequest.validated()
        guard case .gcs(let bucket, let key, let generation) = request.locator else {
            throw NativeBiologicalDataTransportError.locatorSchemeMismatch(
                expected: scheme,
                actual: request.locator.scheme
            )
        }
        let url = try gcsURL(bucket: bucket, key: key, generation: generation)
        return BiologicalNativeLocatorResolution(
            originalLocator: request.locator,
            resolvedRequest: request.resolving(locator: .https(url: url)),
            resolverID: resolverID,
            metadata: [
                "object-store": "gcs",
                "bucket": bucket,
                "key": key
            ]
        )
    }

    public func gcsURL(
        bucket: String,
        key: String,
        generation: String? = nil
    ) throws -> String {
        guard Self.isBucket(bucket), !key.isEmpty else {
            throw NativeBiologicalDataTransportError.invalidObjectKey(
                "gs://\(bucket)/\(key)"
            )
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = configuration.googleStorageHost
        components.percentEncodedPath = "/" +
            PublicCloudObjectPathEncoding.encode(bucket + "/" + key)
        if let generation {
            guard !generation.isEmpty,
                  generation.allSatisfy(\.isNumber) else {
                throw NativeBiologicalDataTransportError.invalidObjectKey(
                    "gs://\(bucket)/\(key)"
                )
            }
            components.queryItems = [
                URLQueryItem(name: "generation", value: generation)
            ]
        }
        guard let url = components.url?.absoluteString else {
            throw NativeBiologicalDataTransportError.invalidObjectKey(
                "gs://\(bucket)/\(key)"
            )
        }
        return url
    }

    private static func isBucket(_ value: String) -> Bool {
        guard value.count >= 3,
              value.count <= 222,
              value.first != ".",
              value.last != ".",
              value.first != "-",
              value.last != "-",
              !value.contains("..") else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.lowercaseLetters.contains($0) ||
                CharacterSet.decimalDigits.contains($0) ||
                $0 == "." ||
                $0 == "-" ||
                $0 == "_"
        }
    }
}

enum PublicCloudObjectPathEncoding {
    private static let segmentCharacters: CharacterSet = {
        var value = CharacterSet.alphanumerics
        value.insert(charactersIn: "-._~")
        return value
    }()

    static func encode(_ value: String) -> String {
        value.split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in
                String(segment).addingPercentEncoding(
                    withAllowedCharacters: segmentCharacters
                ) ?? ""
            }
            .joined(separator: "/")
    }
}
