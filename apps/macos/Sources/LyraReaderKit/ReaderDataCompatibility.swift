import Foundation

/// Upgrade only storage that is safe to copy. Annotation sidecars stay at their existing URL,
/// so old and new app versions cannot silently fork a document's annotation history.
@MainActor public enum ReaderDataCompatibility {
    private static let migrationKey = "lyrareader.didMigratePreferences"

    public static func migratePreferences(
        defaults: UserDefaults = .standard,
        legacyDomains: [String] = ["com.alex.lyra", "com.alex.arisreader", "ArisReader"]
    ) {
        guard !defaults.bool(forKey: migrationKey) else { return }
        for domain in legacyDomains {
            for (key, value) in defaults.persistentDomain(forName: domain) ?? [:] {
                let destination = key.hasPrefix("lyra.")
                    ? "lyrareader." + key.dropFirst("lyra.".count) : key
                if defaults.object(forKey: destination) == nil {
                    defaults.set(value, forKey: destination)
                }
            }
        }
        defaults.set(true, forKey: migrationKey)
    }

    public static func annotationSidecarURL(for document: URL) -> URL {
        let current = document.appendingPathExtension("lyra-reader-annotations.json")
        let legacy = document.appendingPathExtension("aris-annotations.json")
        if !FileManager.default.fileExists(atPath: current.path),
           FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        return current
    }
}
