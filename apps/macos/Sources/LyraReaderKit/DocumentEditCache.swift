import CryptoKit
import Foundation

/// Recoverable editor state lives in the application cache, never beside a user's PDF.
/// Legacy adjacent records are imported once, validated and backed up before removal.
@MainActor public enum DocumentEditCache {
    public static var rootOverride: URL?

    public static var root: URL {
        if let rootOverride { return rootOverride }
        if let path = ProcessInfo.processInfo.environment["LYRA_READER_DOCUMENT_CACHE_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LyraReader/Documents", isDirectory: true)
    }

    public static func directory(for document: URL) -> URL {
        let path = document.standardizedFileURL.resolvingSymlinksInPath().path
        let key = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent(key, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func annotationsURL(for document: URL) -> URL {
        directory(for: document).appendingPathComponent("annotations.json")
    }

    /// In-place translations live in the document's edit-cache directory, beside the annotations
    /// and revisions. They are never written next to the PDF: a translation is reader state, not
    /// document content, and it must not travel with a shared file.
    public static func translationsURL(for document: URL) -> URL {
        directory(for: document).appendingPathComponent("translations.json")
    }

    static func legacyURLs(for document: URL) -> [URL] {
        [document.appendingPathExtension("lyra-reader-annotations.json"),
         document.appendingPathExtension("aris-annotations.json")]
    }

    struct SourceStamp: Codable, Equatable {
        let size: Int
        let modified: Date?
        let sha256: String
        init(_ url: URL) throws {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            size = values.fileSize ?? 0
            modified = values.contentModificationDate
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        static func == (lhs: SourceStamp, rhs: SourceStamp) -> Bool {
            lhs.size == rhs.size && lhs.sha256 == rhs.sha256
        }
    }

    enum CacheError: LocalizedError {
        case sourceChanged
        case importVerification
        var errorDescription: String? {
            switch self {
            case .sourceChanged:
                return "The PDF changed outside LyraReader. Its recovery data was kept; back it up before starting fresh."
            case .importVerification:
                return "The legacy annotation import could not be verified. The original records were kept."
            }
        }
    }

    static func recordSource(for document: URL) throws {
        guard FileManager.default.fileExists(atPath: document.path) else { return }
        try JSONEncoder().encode(SourceStamp(document)).write(
            to: directory(for: document).appendingPathComponent("source.json"), options: .atomic)
    }

    static func validateSource(for document: URL) throws {
        let metadata = directory(for: document).appendingPathComponent("source.json")
        guard FileManager.default.fileExists(atPath: metadata.path),
              FileManager.default.fileExists(atPath: document.path) else { return }
        let expected = try JSONDecoder().decode(SourceStamp.self, from: Data(contentsOf: metadata))
        guard try SourceStamp(document) == expected else { throw CacheError.sourceChanged }
    }

    static func prepareAnnotations(for document: URL, pageCount: Int, paletteCount: Int) throws -> URL {
        let cache = annotationsURL(for: document)
        if FileManager.default.fileExists(atPath: cache.path)
            || FileManager.default.fileExists(atPath: pendingStateURL(for: document).path)
            || FileManager.default.fileExists(atPath: recoveryURL(for: document).path) {
            try validateSource(for: document)
            if !FileManager.default.fileExists(atPath: directory(for: document).appendingPathComponent("source.json").path) {
                try recordSource(for: document)
            }
            return cache
        }
        let legacy = legacyURLs(for: document).filter { FileManager.default.fileExists(atPath: $0.path) }
        if let source = legacy.first {
            let data = try Data(contentsOf: source)
            _ = try AnnotationRecords.decode(data, pageCount: pageCount, paletteCount: paletteCount)
            try data.write(to: cache, options: .atomic)
            guard try Data(contentsOf: cache) == data else { throw CacheError.importVerification }
            for source in legacy {
                let backup = directory(for: document).appendingPathComponent("import-\(UUID().uuidString).json")
                let original = try Data(contentsOf: source)
                try original.write(to: backup, options: .atomic)
                guard try Data(contentsOf: backup) == original else { throw CacheError.importVerification }
                try FileManager.default.removeItem(at: source)
            }
        }
        try recordSource(for: document)
        return cache
    }

    static func unreadableRecordsURL(for document: URL) -> URL {
        let cache = annotationsURL(for: document)
        if FileManager.default.fileExists(atPath: cache.path) { return cache }
        return legacyURLs(for: document).first { FileManager.default.fileExists(atPath: $0.path) } ?? cache
    }

    static func recoveryURL(for document: URL) -> URL {
        directory(for: document).appendingPathComponent("session.json")
    }

    static func pendingStateURL(for document: URL) -> URL {
        directory(for: document).appendingPathComponent("changes.json")
    }

    static func newSessionDirectory(for document: URL) throws -> URL {
        let result = directory(for: document).appendingPathComponent("session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
}
