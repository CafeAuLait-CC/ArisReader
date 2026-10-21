import AppKit
import Foundation
import PDFKit
@testable import LyraReaderKit

extension ReaderChecks {
    @MainActor static func documentCacheChecks(root: URL) async throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("lyra-cache-check-\(UUID())")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let oldRoot = DocumentEditCache.rootOverride
        DocumentEditCache.rootOverride = scratch.appendingPathComponent("cache")
        defer { DocumentEditCache.rootOverride = oldRoot; try? fm.removeItem(at: scratch) }

        func fixture(_ name: String) throws -> URL {
            let url = scratch.appendingPathComponent(name)
            try fm.copyItem(at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: url)
            return url
        }
        let source = try fixture("paper.pdf")
        let original = try Data(contentsOf: source)
        let mark = AppState.Annotation(id: UUID(), page: 0, start: 0, end: 3,
            color: AppState.highlightPalette[0].color, note: "Keep this evidence", createdAt: Date())
        let bookmark = Bookmark(page: 0, title: "Research question", yPt: 30)
        let legacy = source.appendingPathExtension("aris-annotations.json")
        let records = try AnnotationSidecar.encode(annotations: [mark], bookmarks: [bookmark],
            slots: [.annotation(mark.id), .bookmark(bookmark.id)])
        try records.write(to: legacy)
        weak var previousOwner: AppState?
        do {
        let state = AppState(engine: try RustEngine())
        previousOwner = state
        state.setViewportSize(CGSize(width: 1000, height: 800))
        require(state.open(url: source), "legacy fixture opens")
        require(state.annotations == [mark] && state.bookmarks == [bookmark], "legacy marks migrate without changes")
        let cachedRecords = DocumentEditCache.annotationsURL(for: source)
        require(cachedRecords.path.hasPrefix(scratch.appendingPathComponent("cache").path), "records live in the application cache")
        require(!fm.fileExists(atPath: legacy.path), "the legacy companion file is retired after import")
        let imports = try fm.contentsOfDirectory(at: cachedRecords.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("import-") }
        require(imports.count == 1 && (try? Data(contentsOf: imports[0])) == records,
                "migration keeps a byte-identical recovery backup")
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(30)], ofItemAtPath: source.path)
        try DocumentEditCache.validateSource(for: source)
        require(true, "touching an unchanged PDF does not invalidate recovery data")
        state.toggleContentEditing()
        await state.reloadContentObjects()
        guard let text = state.contentEditPage?.items.first(where: { $0.can_edit_text }) else {
            fatalError("Editable text missing")
        }
        state.replaceContentText(text, text: "Cached edit", font: "Helvetica", size: text.size)
        try await eventually("body editing succeeds with unsaved marks on the same page") {
            state.pageEditPendingOperations.count == 1 && !state.contentCommandInFlight
        }
        require(state.contentTextRecovery == nil, "unsaved annotations do not force a separate export")
        require((try? Data(contentsOf: source)) == original, "cached editing preserves the original until Save")
        require(PDFDocument(url: state.document!.url!)?.page(at: 0)?.annotations.count == 1,
                "the working PDF carries the highlight as page geometry")
        state.undo()
        try await eventually("undo restores the text and cached marks together") {
            state.pageEditPendingOperations.isEmpty && !state.pageEditBusy && state.annotations == [mark]
        }
        state.redo()
        try await eventually("redo restores the combined PDF revision") {
            state.pageEditPendingOperations.count == 1 && !state.pageEditBusy
        }
        state.flushPendingWrites()
        }
        try await eventually("the interrupted editing owner has been released") { previousOwner == nil }
        let resumed = AppState(engine: try RustEngine())
        resumed.setViewportSize(CGSize(width: 1000, height: 800))
        require(resumed.open(url: source), "the original reopens after an interrupted session")
        require(resumed.pageEditSessionActive && resumed.pageEditPendingOperations.count == 1,
                "the application cache restores unsaved PDF revisions")
        require(PDFDocument(url: resumed.document!.url!)?.string?.contains("Cached edit") == true,
                "recovery restores the actual edited text")
        let saved = await resumed.saveDocumentToOriginal()
        require(saved, "Save writes the cached document to its original path: \(resumed.lastError ?? "")")
        let published = PDFDocument(url: source)
        require(published?.string?.contains("Cached edit") == true, "the original now contains the edited body text")
        require(published?.page(at: 0)?.annotations.count == 1, "Save embeds the annotation exactly once")
        require(!resumed.pageEditSessionActive, "successful Save retires the working session")
        require(!fm.fileExists(atPath: DocumentEditCache.recoveryURL(for: source).path), "successful Save retires the recovery manifest")
        require(DocumentEditCache.legacyURLs(for: source).allSatisfy { !fm.fileExists(atPath: $0.path) },
                "saving does not recreate adjacent sidecars")
        try await eventually("saved bookmarks reload from the PDF outline") { resumed.bookmarks.count == 1 }
        require(!resumed.annotationCacheIsDirty, "embedded bookmarks do not mark a saved document dirty")

        let conflict = try fixture("external.pdf")
        let editing = AppState(engine: try RustEngine())
        editing.setViewportSize(CGSize(width: 1000, height: 800))
        editing.open(url: conflict)
        editing.toggleContentEditing()
        await editing.reloadContentObjects()
        let block = editing.contentEditPage!.items.first(where: { $0.can_edit_text })!
        editing.replaceContentText(block, text: "Pending", font: "Helvetica", size: block.size)
        try await eventually("external-change fixture has a cached edit") {
            editing.pageEditPendingOperations.count == 1 && !editing.contentCommandInFlight
        }
        var external = try Data(contentsOf: conflict)
        external.append(Data("\n% changed externally\n".utf8))
        try external.write(to: conflict, options: .atomic)
        let refused = await editing.saveDocumentToOriginal()
        require(!refused && (try? Data(contentsOf: conflict)) == external,
                "Save refuses an externally changed original without overwriting it")
        require(fm.fileExists(atPath: DocumentEditCache.recoveryURL(for: conflict).path),
                "a refused save preserves the editing recovery data")

        let invalid = try fixture("corrupt.pdf")
        let oldRecords = invalid.appendingPathExtension("lyra-reader-annotations.json")
        let corrupt = Data("{invalid legacy records".utf8)
        try corrupt.write(to: oldRecords)
        let protected = AppState(engine: try RustEngine())
        protected.open(url: invalid)
        require(protected.canRecoverUnreadableAnnotationSidecar && (try? Data(contentsOf: oldRecords)) == corrupt,
                "invalid legacy records are preserved and never silently replaced")
        let pendingCorrupt = Data("{invalid pending deletions".utf8)
        try pendingCorrupt.write(to: DocumentEditCache.pendingStateURL(for: invalid))
        let backup = protected.recoverUnreadableAnnotationSidecar()
        require(backup != nil && (try? Data(contentsOf: backup!)) == corrupt,
                "explicit recovery keeps the original unreadable annotation bytes")
        let recoveryFiles = try fm.contentsOfDirectory(at: DocumentEditCache.directory(for: invalid), includingPropertiesForKeys: nil)
        require(recoveryFiles.contains { (try? Data(contentsOf: $0)) == pendingCorrupt },
                "explicit recovery also preserves unreadable pending deletion metadata")
        require(!protected.canRecoverUnreadableAnnotationSidecar,
                "verified backup permits a fresh annotation cache")
        print("Document cache checks passed")
    }
}
