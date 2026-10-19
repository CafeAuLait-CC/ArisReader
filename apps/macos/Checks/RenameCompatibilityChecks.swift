import Foundation
import LyraReaderKit

extension ReaderChecks {
    @MainActor static func renameCompatibilityChecks(root: URL) throws {
        let domain = "lyrareader.rename-check.\(UUID())"
        let oldDomain = domain + ".legacy"
        let defaults = UserDefaults(suiteName: domain)!
        defer {
            defaults.removePersistentDomain(forName: domain)
            defaults.removePersistentDomain(forName: oldDomain)
        }
        let accounts = Data("old-account-metadata".utf8)
        defaults.setPersistentDomain([
            "lyra.paperAppearance": "warm", "lyra.recentDocuments": Data("[]".utf8),
            "readerLayoutMode": "facing", "chatGPTAccounts": accounts,
            "readingPosition:/paper.pdf": 125.0
        ], forName: oldDomain)
        defaults.set("night", forKey: "lyrareader.paperAppearance")
        ReaderDataCompatibility.migratePreferences(defaults: defaults, legacyDomains: [oldDomain])
        require(defaults.string(forKey: "lyrareader.paperAppearance") == "night",
                "rename preserves the new installation's preference over the old value")
        require(defaults.string(forKey: "readerLayoutMode") == "facing"
                && defaults.data(forKey: "chatGPTAccounts") == accounts
                && defaults.double(forKey: "readingPosition:/paper.pdf") == 125,
                "rename imports layout, account metadata and document reading positions")
        require(defaults.data(forKey: "lyrareader.recentDocuments") == Data("[]".utf8),
                "rename imports recent documents under the new preference key")
        defaults.removeObject(forKey: "lyrareader.recentDocuments")
        ReaderDataCompatibility.migratePreferences(defaults: defaults, legacyDomains: [oldDomain])
        require(defaults.data(forKey: "lyrareader.recentDocuments") == nil,
                "rename does not resurrect history cleared after the first migration")

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("lyrareader-upgrade-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let pdf = scratch.appendingPathComponent("paper.pdf")
        try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: pdf)
        let current = pdf.appendingPathExtension("lyra-reader-annotations.json")
        let legacy = pdf.appendingPathExtension("aris-annotations.json")
        require(ReaderDataCompatibility.annotationSidecarURL(for: pdf) == current,
                "a new document uses the LyraReader annotation suffix")
        let annotation = AppState.Annotation(id: UUID(), page: 0, start: 0, end: 3,
            color: AppState.highlightPalette[0].color, note: "before rename", createdAt: Date())
        try JSONEncoder().encode([annotation]).write(to: legacy)
        let state = AppState(engine: try RustEngine())
        state.open(url: pdf)
        require(state.annotations.first?.note == "before rename",
                "a real document reopens annotations from its old sidecar")
        state.updateNote("after rename", for: annotation.id)
        state.flushPendingAnnotationWrite()
        let saved = try JSONDecoder().decode([AppState.Annotation].self, from: Data(contentsOf: legacy))
        require(saved.first?.note == "after rename" && !FileManager.default.fileExists(atPath: current.path),
                "editing an upgraded document persists in place without splitting annotation history")
        try Data("[]".utf8).write(to: current)
        require(ReaderDataCompatibility.annotationSidecarURL(for: pdf) == current,
                "the new sidecar wins deterministically if both versions exist")
        try FileManager.default.removeItem(at: current)
        let corrupt = Data("{broken legacy sidecar".utf8)
        try corrupt.write(to: legacy)
        state.open(url: pdf)
        require(state.canRecoverUnreadableAnnotationSidecar && (try? Data(contentsOf: legacy)) == corrupt,
                "a corrupt legacy sidecar still blocks writes and preserves the original bytes")
        print("Rename compatibility checks passed")
    }
}
