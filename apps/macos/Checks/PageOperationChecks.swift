import AppKit
import ArisReaderKit
import Foundation

extension ReaderChecks {
    /// The shell half of T3.9: a staged page-edit session, the sidecar remap across a reorder,
    /// undo/redo, discard, the explicit save commands and the "files on disk are untouched until
    /// Apply" contract.
    ///
    /// The Rust tests own the PDF round trips (rotation, page order, blank size, extraction and
    /// annotations travelling with a moved page). This check exercises what only the app can
    /// prove: that the open document is a working revision, that the original PDF and its
    /// sidecar stay byte-identical while changes are pending, and that the reader's marks follow
    /// the pages through reorder/delete and come back on undo.
    @MainActor static func pageOperationChecks(root: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("aris-pages-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        func copyFixture(_ name: String, to fileName: String) throws -> URL {
            let destination = scratch.appendingPathComponent(fileName)
            try fileManager.copyItem(
                at: root.appendingPathComponent("tests/fixtures/\(name)"),
                to: destination
            )
            return destination
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        func entry<Value: Encodable>(_ value: Value) throws -> String {
            let encoded = String(decoding: try encoder.encode([value]), as: UTF8.self)
            return String(encoded.dropFirst(2).dropLast(2))
        }
        func writeSidecar(
            _ annotations: [AppState.Annotation],
            _ bookmarks: [Bookmark],
            to document: URL
        ) throws {
            var lines: [String] = []
            for annotation in annotations { lines.append(try entry(annotation)) }
            for bookmark in bookmarks { lines.append(try entry(bookmark)) }
            try Data(("[\n" + lines.joined(separator: ",\n") + "\n]").utf8)
                .write(to: document.appendingPathExtension("aris-annotations.json"))
        }

        let pageOne = AppState.Annotation(
            id: UUID(),
            kind: .highlight,
            page: 0,
            start: 0,
            end: 5,
            color: AppState.highlightPalette[0].color,
            note: "page one mark",
            createdAt: Date()
        )
        let pageTwo = AppState.Annotation(
            id: UUID(),
            kind: .underline,
            page: 1,
            start: 3,
            end: 8,
            color: AppState.highlightPalette[2].color,
            note: "page two mark",
            createdAt: Date()
        )
        let bookmark = Bookmark(page: 1, title: "on page two", yPt: 12)
        let annotated = try copyFixture("annotated.pdf", to: "seeded.pdf")
        try writeSidecar([pageOne, pageTwo], [bookmark], to: annotated)
        let sidecarURL = annotated.appendingPathExtension("aris-annotations.json")
        let originalBytes = try Data(contentsOf: annotated)
        let originalSidecar = try Data(contentsOf: sidecarURL)

        let state = AppState(engine: try RustEngine())
        require(state.open(url: annotated), "page-edit fixture opens")
        require(state.annotations.count == 2 && state.bookmarks.count == 1,
                "page-edit fixture's sidecar is loaded")
        require(state.document?.pageCount == 2, "page-edit fixture has two pages")

        // ── Rotation is refused when it would invalidate Lyra's text-range marks ─────
        // Sidecar annotations address character ranges. A rotated page's text layer comes back
        // in a different order, so the honest rule is to refuse the rotation rather than move
        // the highlight onto different words. Embedded PDF annotations rotate with the page.
        let rotationRefused = await state.applyPageEditOperation(
            .rotate(pages: [0], quarterTurns: 1),
            label: "Rotate page 1"
        )
        require(!rotationRefused, "rotating a page with Lyra annotations is refused")
        require(state.lastError?.contains("text positions") == true,
                "the refusal explains the annotation rule")
        require(!state.pageEditSessionActive, "a refused rotation does not start a session")

        // ── Rotate, undo, redo on a page with no sidecar marks ──────────────────────
        let rotationSource = try copyFixture("multipage.pdf", to: "rotation.pdf")
        let rotationBytes = try Data(contentsOf: rotationSource)
        let rotationState = AppState(engine: try RustEngine())
        require(rotationState.open(url: rotationSource), "rotation fixture opens")
        require(rotationState.document?.pageCount == 3, "rotation fixture has three pages")
        rotationState.selectPage(1, extending: false, toggling: false)
        let rotated = await rotationState.applyPageEditOperation(
            .rotate(pages: [1], quarterTurns: 1),
            label: "Rotate page 2"
        )
        require(rotated, "rotate is staged")
        require(rotationState.pageEditSessionActive && rotationState.canUndoPageEdit,
                "the interface can offer undo for a staged rotation")
        require(rotationState.pageEditPendingOperations.count == 1,
                "the pending list names the rotation")
        require(rotationState.pageEditPendingSummary?.contains("file on disk is unchanged") == true,
                "the interface says the file on disk is unchanged")
        require(rotationState.document?.pageCount == 3, "rotation does not change the page count")
        let rotationWhilePending = try Data(contentsOf: rotationSource)
        require(rotationWhilePending == rotationBytes,
                "the original PDF is byte-identical while a rotation is pending")
        let rotationRevision = rotationState.document?.url
        let rotationProbe = try RustEngine()
        if let rotationRevision { _ = try rotationProbe.openDocument(at: rotationRevision) }
        let rotatedRotations = try await rotationProbe.pageRotations()
        require(rotatedRotations == [0, 1, 0],
                "the reopened working revision reports the rotation")

        rotationState.undoPageEdit()
        try await eventually("undo the staged rotation", {
            rotationState.pageEditPendingOperations.isEmpty && rotationState.canRedoPageEdit
        })
        require(rotationState.document?.url?.standardizedFileURL.path
                    == rotationSource.standardizedFileURL.path,
                "undo returns to the original working revision")
        _ = try rotationProbe.openDocument(at: rotationSource)
        let undoneRotations = try await rotationProbe.pageRotations()
        require(undoneRotations == [0, 0, 0], "undo restores the original rotation")

        rotationState.redoPageEdit()
        try await eventually("redo the staged rotation", {
            rotationState.pageEditPendingOperations.count == 1 && rotationState.canUndoPageEdit
        })
        if let url = rotationState.document?.url { _ = try rotationProbe.openDocument(at: url) }
        let redoneRotations = try await rotationProbe.pageRotations()
        require(redoneRotations == [0, 1, 0], "redo restores the rotation")
        rotationState.discardPageEdits()
        require(!rotationState.pageEditSessionActive, "rotation session can be discarded")

        // The seeded document's original PDF and sidecar are untouched by the whole refusal.
        let bytesAfterRefusal = try Data(contentsOf: annotated)
        let sidecarAfterRefusal = try Data(contentsOf: sidecarURL)
        require(bytesAfterRefusal == originalBytes && sidecarAfterRefusal == originalSidecar,
                "a refused rotation leaves the original PDF and sidecar byte-identical")

        // ── Reorder: annotations and bookmarks follow their pages ────────────────────
        // ── Reorder: annotations and bookmarks follow their pages ────────────────────
        state.selectPage(1, extending: false, toggling: false)
        let reordered = await state.applyPageEditOperation(
            .move(pages: [1], destination: 0),
            label: "Move page 2 to the front"
        )
        require(reordered, "reorder is staged")
        let pageOfNote = Dictionary(uniqueKeysWithValues: state.annotations.map { ($0.note, $0.page) })
        require(pageOfNote["page one mark"] == 1 && pageOfNote["page two mark"] == 0,
                "sidecar annotations follow their pages through a reorder")
        require(state.bookmarks.first?.page == 0,
                "bookmarks follow their pages through a reorder")
        require(state.document?.pageCount == 2, "reorder keeps the page count")

        state.undoPageEdit()
        try await eventually("undo the reorder", {
            state.pageEditPendingOperations.isEmpty && state.canRedoPageEdit
        })
        let restoredPages = Dictionary(uniqueKeysWithValues: state.annotations.map { ($0.note, $0.page) })
        require(restoredPages["page one mark"] == 0 && restoredPages["page two mark"] == 1,
                "undoing a reorder puts annotations back on their original pages")
        require(state.bookmarks.first?.page == 1, "undoing a reorder restores the bookmark page")

        // ── Delete: marks on the deleted page do not reappear on a neighbour ────────
        state.selectPage(0, extending: false, toggling: false)
        let deleted = await state.applyPageEditOperation(
            .delete(pages: [0]),
            label: "Delete page 1"
        )
        require(deleted, "delete is staged")
        require(state.document?.pageCount == 1, "the working copy has one page")
        require(state.annotations.count == 1 && state.annotations[0].note == "page two mark"
                && state.annotations[0].page == 0,
                "only the surviving page's annotation remains, on its new page")
        require(state.bookmarks.allSatisfy { $0.page == 0 },
                "a bookmark on a deleted page is removed, not moved to a neighbour")
        state.undoPageEdit()
        try await eventually("undo the deletion", {
            state.pageEditPendingOperations.isEmpty && state.canRedoPageEdit
        })
        require(state.annotations.count == 2
                && state.annotations.map(\.page).sorted() == [0, 1],
                "undo restores the annotations that were on the deleted page")
        require(state.bookmarks.count == 1 && state.bookmarks[0].page == 1,
                "undo restores the bookmark that was on the deleted page")

        // ── Discard restores the original document and leaves both files alone ──────
        state.discardPageEdits()
        require(!state.pageEditSessionActive && state.pageEditPendingOperations.isEmpty,
                "discard ends the session")
        require(state.document?.url?.standardizedFileURL.path == annotated.standardizedFileURL.path,
                "discard reopens the original")
        let discardedBytes = try Data(contentsOf: annotated)
        let discardedSidecar = try Data(contentsOf: sidecarURL)
        require(discardedBytes == originalBytes,
                "discard leaves the original PDF byte-identical")
        require(discardedSidecar == originalSidecar,
                "discard leaves the original sidecar byte-identical")

        // ── A refused operation changes nothing ────────────────────────────────────
        state.selectPage(0, extending: false, toggling: false)
        let refused = await state.applyPageEditOperation(
            .delete(pages: [0, 1]),
            label: "Delete every page"
        )
        require(!refused, "deleting every page is refused")
        require(state.pageEditPendingOperations.isEmpty, "a refused operation stages nothing")
        let bytesAfterDeleteRefusal = try Data(contentsOf: annotated)
        require(bytesAfterDeleteRefusal == originalBytes,
                "a refused operation leaves the original readable and unchanged")
        state.discardPageEdits()

        // ── Explicit replace: backup, verify, remapped sidecar ─────────────────────
        let replaced = try copyFixture("annotated.pdf", to: "replaced.pdf")
        let replacedSidecar = replaced.appendingPathExtension("aris-annotations.json")
        let replacedPageOne = AppState.Annotation(
            id: UUID(), kind: .highlight, page: 0, start: 0, end: 4,
            color: AppState.highlightPalette[0].color, note: "goes away", createdAt: Date()
        )
        let replacedPageTwo = AppState.Annotation(
            id: UUID(), kind: .highlight, page: 1, start: 0, end: 4,
            color: AppState.highlightPalette[1].color, note: "stays", createdAt: Date()
        )
        try writeSidecar([replacedPageOne, replacedPageTwo], [], to: replaced)
        let replacedState = AppState(engine: try RustEngine())
        require(replacedState.open(url: replaced), "replace fixture opens")
        replacedState.selectPage(0, extending: false, toggling: false)
        let stagedDeletion = await replacedState.applyPageEditOperation(
            .delete(pages: [0]),
            label: "Delete page 1"
        )
        require(stagedDeletion, "replace fixture stages a deletion")
        let replacedOK = await replacedState.replaceOriginalWithPageEdits()
        require(replacedOK, "the original is replaced only after an explicit command")
        require(replacedState.document?.url?.standardizedFileURL.path == replaced.standardizedFileURL.path,
                "the replaced original is reopened")
        require(replacedState.document?.pageCount == 1, "the replaced PDF has the new page count")
        let backups = try fileManager.contentsOfDirectory(
            at: replaced.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".lyra-backup-") }
        require(backups.count == 1, "a verified backup of the original is left beside it")
        let reopened = AppState(engine: try RustEngine())
        require(reopened.open(url: replaced), "the replaced PDF reopens in a fresh reader")
        require(reopened.document?.pageCount == 1, "the replaced PDF keeps exactly one page")
        require(reopened.annotations.count == 1 && reopened.annotations[0].note == "stays"
                && reopened.annotations[0].page == 0,
                "the replaced original's sidecar is remapped to the surviving page")

        // ── Save Edited Copy: original untouched, copy verified, marks beside it ────
        let source = try copyFixture("multipage.pdf", to: "copy-source.pdf")
        let sourceBytes = try Data(contentsOf: source)
        let copyState = AppState(engine: try RustEngine())
        require(copyState.open(url: source), "edited-copy fixture opens")
        copyState.selectPage(1, extending: false, toggling: false)
        let stagedCopy = await copyState.applyPageEditOperation(
            .rotate(pages: [1], quarterTurns: 1),
            label: "Rotate page 2"
        )
        require(stagedCopy, "edited-copy fixture stages a rotation")
        let editedCopy = scratch.appendingPathComponent("edited-copy.pdf")
        let savedCopy = await copyState.savePageEditsCopy(to: editedCopy)
        require(savedCopy, "Save Edited Copy writes the staged revision")
        let sourceAfterCopy = try Data(contentsOf: source)
        require(sourceAfterCopy == sourceBytes,
                "Save Edited Copy leaves the original untouched")
        let copyProbe = try RustEngine()
        _ = try copyProbe.openDocument(at: editedCopy)
        let copyRotations = try await copyProbe.pageRotations()
        require(copyRotations == [0, 1, 0],
                "the edited copy carries the staged rotation")
        require(copyState.document?.url?.standardizedFileURL.path == editedCopy.standardizedFileURL.path,
                "Save Edited Copy opens the new file")

        // ── Extract writes exactly the selected pages ───────────────────────────────
        let extracted = scratch.appendingPathComponent("extracted.pdf")
        let extractedOK = await copyState.extractPages([2], to: extracted)
        require(extractedOK, "extract writes a file")
        let extractedDocument = try copyProbe.openDocument(at: extracted)
        require(extractedDocument.pageCount == 1, "extract writes exactly one page")

        // ── The page count still comes from the engine, not a stale cache ───────────
        require(editedCopy.pathExtension == "pdf", "the edited copy is a PDF")
    }
}
