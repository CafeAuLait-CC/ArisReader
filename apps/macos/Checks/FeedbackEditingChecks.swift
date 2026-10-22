import AppKit
import PDFKit
import SwiftUI
@testable import LyraReaderKit

extension ReaderChecks {
    @MainActor static func feedbackEditingChecks(root: URL) async throws {
        guard let samples = ProcessInfo.processInfo.environment["LYRA_READER_FEEDBACK_PAPERS"] else {
            fatalError("Set LYRA_READER_FEEDBACK_PAPERS to the real-paper sample directory")
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-feedback-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for name in ["review_ashley_0826.pdf", "review_du_0923.pdf", "manuscript_0925.pdf"] {
            let source = scratch.appendingPathComponent(name)
            // Some review originals are Finder-locked (uchg). A test copy contains only their
            // bytes, so Save exercises editing rather than inheriting the original's lock flag.
            try Data(contentsOf: URL(fileURLWithPath: samples).appendingPathComponent(name)).write(to: source)
            let state = AppState(engine: try RustEngine())
            state.setViewportSize(CGSize(width: 1000, height: 800))
            state.newTab(url: source)
            try await eventually("real paper opens") { !state.canvasPageFrames.isEmpty }
            require(state.addGeometryAnnotation(kind: .square, page: 0,
                shapeRect: CGRect(x: 30, y: 80, width: 20, height: 20)), "add an unsaved annotation")
            require(state.hasUnsavedDocumentChanges && state.tabHasUnsavedChanges(0), "annotation marks its tab dirty")
            state.closeTab(0)
            require(state.contentCloseRequested && state.tabs.count == 1,
                    "annotation-only close asks once and preserves the tab")
            state.cancelContentClose()
            require(!state.prepareWindowClose(continueClosing: {}), "the native window close is deferred for unsaved annotations")
            state.cancelContentClose()
            state.toggleContentEditing()
            await state.reloadContentObjects()
            guard let item = state.contentEditPage?.items.first(where: {
                $0.can_edit_text && $0.bounds.width > 150 && $0.text.filter(\.isLetter).count > 100
            }) else { fatalError("No real body paragraph in \(name)") }
            let original = item.text.replacingOccurrences(of: "\n", with: " ")
            let variants = [original + " More text.", String(original.dropFirst(4)),
                original.replacingOccurrences(of: " ", with: " edited ", range: original.range(of: " ")),
                original + "\nAdditional text for a longer paragraph that wraps onto another line."]
            var current = item
            for (index, value) in variants.enumerated() {
                state.replaceContentText(current, text: value)
                try await eventuallyExplaining("real paper edit \(index) commits", {
                    state.contentTextNotice ?? state.lastError ?? state.statusMessage
                }, { !state.contentCommandInFlight && !state.pageEditBusy && !state.contentEditLoading })
                require(state.lastError == nil && state.contentTextRecovery == nil,
                    "\(name) supports ordinary editing alongside unsaved annotations: \(state.contentTextNotice ?? "")")
                let compact = value.filter { !$0.isWhitespace }
                guard let next = state.contentEditPage?.items.first(where: {
                    $0.text.filter { !$0.isWhitespace } == compact
                }) else {
                    fatalError("Reopened edited paragraph missing in \(name) edit \(index)")
                }
                current = next
            }
            state.toggleAnnotationTools()
            let count = state.pageEditPendingOperations.count
            state.undo()
            try await eventually("Undo works after leaving Edit PDF") {
                !state.pageEditBusy && state.pageEditPendingOperations.count == count - 1
            }
            state.redo()
            try await eventually("Redo works after leaving Edit PDF") {
                !state.pageEditBusy && state.pageEditPendingOperations.count == count
            }
            let saved = await state.saveDocumentToOriginal()
            require(saved, "real paper saves to the original test copy: \(state.lastError ?? "")")
            let reopened = PDFDocument(url: source)!
            require(reopened.page(at: 0)!.annotations.contains { $0.type == "Square" },
                    "unsaved annotation and content text save together")
            let reopenedText = reopened.string!.filter { !$0.isWhitespace }
            require(reopenedText.contains("Additionaltextforalongerparagraph") && reopenedText.contains("wrapsontoanotherline."),
                    "PDFKit independently reopens the new longer text")
            require(!state.hasUnsavedDocumentChanges, "successful save clears the dirty indicator")
            print("PASS real paper annotate/edit/undo/redo/save/reopen: \(name)")
        }
    }
}
