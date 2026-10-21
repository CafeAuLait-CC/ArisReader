import Foundation

/// Upgrade only storage that is safe to copy.
///
/// `legacyAnnotationURL(for:)` names the old companion file the one-time import reads. It is
/// kept as a small, testable helper even though the production load path goes through
/// `DocumentEditCache.prepareAnnotations`, which applies the same suffix rule.
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

    public static func legacyAnnotationURL(for document: URL) -> URL {
        let current = document.appendingPathExtension("lyra-reader-annotations.json")
        let legacy = document.appendingPathExtension("aris-annotations.json")
        if !FileManager.default.fileExists(atPath: current.path),
           FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        return current
    }
}
