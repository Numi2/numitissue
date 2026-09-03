import Foundation

public extension SONATAConfigurationLoader {
    /// Loads SONATA configuration while canonicalizing manifest keys to the token form consumed by
    /// `SONATACircuitConfiguration.resolve`. SONATA configuration commonly declares keys such as
    /// `$BASE_DIR`; the runtime stores the canonical identifier `BASE_DIR` and still accepts an
    /// already-normalized key for compatibility.
    static func loadCanonical(url: URL) throws -> SONATACircuitConfiguration {
        var configuration = try load(url: url)
        var canonical: [String: String] = [:]
        canonical.reserveCapacity(configuration.manifest.count)
        for (sourceKey, value) in configuration.manifest {
            let key = sourceKey.hasPrefix("$")
                ? String(sourceKey.dropFirst())
                : sourceKey
            guard !key.isEmpty else {
                throw SONATAError.invalidConfiguration(
                    "Manifest contains an empty variable name"
                )
            }
            if let previous = canonical.updateValue(value, forKey: key),
               previous != value {
                throw SONATAError.invalidConfiguration(
                    "Manifest defines conflicting values for $\(key)"
                )
            }
        }
        configuration.manifest = canonical
        return configuration
    }
}
