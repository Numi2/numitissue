import Foundation

public struct BiologicalRetryPolicy: Sendable, Equatable {
    public var maximumAttempts: Int
    public var initialDelaySeconds: Double
    public var maximumDelaySeconds: Double
    public var multiplier: Double
    public var deterministicJitterFraction: Double
    public var retryableStatusCodes: Set<Int>

    public init(
        maximumAttempts: Int = 5,
        initialDelaySeconds: Double = 0.5,
        maximumDelaySeconds: Double = 30,
        multiplier: Double = 2,
        deterministicJitterFraction: Double = 0.2,
        retryableStatusCodes: Set<Int> = [408, 409, 425, 429, 500, 502, 503, 504]
    ) {
        self.maximumAttempts = maximumAttempts
        self.initialDelaySeconds = initialDelaySeconds
        self.maximumDelaySeconds = maximumDelaySeconds
        self.multiplier = multiplier
        self.deterministicJitterFraction = deterministicJitterFraction
        self.retryableStatusCodes = retryableStatusCodes
    }

    public func validated() throws -> Self {
        guard maximumAttempts > 0,
              maximumAttempts <= 32,
              initialDelaySeconds.isFinite,
              initialDelaySeconds >= 0,
              maximumDelaySeconds.isFinite,
              maximumDelaySeconds >= initialDelaySeconds,
              multiplier.isFinite,
              multiplier >= 1,
              deterministicJitterFraction.isFinite,
              (0...1).contains(deterministicJitterFraction),
              retryableStatusCodes.allSatisfy({ (100...599).contains($0) }) else {
            throw BiologicalTransportError.invalidConfiguration
        }
        return self
    }

    public func delaySeconds(requestID: String, failedAttempt: Int) -> Double {
        guard failedAttempt > 0 else { return 0 }
        let exponential = min(
            maximumDelaySeconds,
            initialDelaySeconds * pow(multiplier, Double(failedAttempt - 1))
        )
        guard deterministicJitterFraction > 0, exponential > 0 else {
            return exponential
        }
        let hash = StableTextHash.fnv1a64("\(requestID)#\(failedAttempt)")
        let unit = Double(hash & 0x00ff_ffff) / Double(0x00ff_ffff)
        let centered = 2 * unit - 1
        return max(
            0,
            exponential * (1 + deterministicJitterFraction * centered)
        )
    }
}

public struct RetryingBiologicalDataTransport: BiologicalDataTransport {
    public let base: any BiologicalDataTransport
    public let policy: BiologicalRetryPolicy

    public init(
        base: any BiologicalDataTransport,
        policy: BiologicalRetryPolicy = BiologicalRetryPolicy()
    ) throws {
        self.base = base
        self.policy = try policy.validated()
    }

    public func execute(
        _ request: BiologicalDataRequest
    ) async throws -> BiologicalDataResponse {
        var attempt = 1
        while true {
            do {
                return try await base.execute(request)
            } catch {
                guard attempt < policy.maximumAttempts,
                      isRetryable(error) else {
                    throw error
                }
                let delay = policy.delaySeconds(
                    requestID: request.id,
                    failedAttempt: attempt
                )
                attempt += 1
                guard delay > 0 else { continue }
                let nanosecondsDouble = delay * 1_000_000_000
                let nanoseconds = UInt64(
                    min(nanosecondsDouble, Double(UInt64.max))
                )
                try await Task.sleep(nanoseconds: nanoseconds)
            }
        }
    }

    private func isRetryable(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        if let transport = error as? BiologicalTransportError {
            switch transport {
            case .httpStatus(let status, _, _):
                return policy.retryableStatusCodes.contains(status)
            case .nonHTTPResponse,
                 .rangeIgnored,
                 .invalidRangeResponse:
                return true
            case .invalidConfiguration,
                 .invalidRequest,
                 .unsupportedLocator,
                 .missingTransport,
                 .hostNotAllowed,
                 .credentialHeaderCollision,
                 .responseTooLarge,
                 .localPathOutsideRoot,
                 .localFileNotRegular:
                return false
            }
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        let retryableCodes: Set<Int> = [
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorResourceUnavailable,
            NSURLErrorInternationalRoamingOff,
            NSURLErrorCallIsActive,
            NSURLErrorDataNotAllowed
        ]
        return retryableCodes.contains(nsError.code)
    }
}
