import AppKit
import LyraReaderKit
import Foundation
import PDFKit

extension ReaderChecks {
    /// One row of a PDF outline as PDFKit sees it.
    private struct PDFOutlineRow: Equatable {
        let title: String
        let depth: Int
        let page: Int?
    }

    /// Bookmark write-back: the document's outline is merged with one independent subtree.
    ///
    /// The source is a scratch copy of `tests/fixtures/outlined.pdf`, which has three levels and
    /// eight real outline entries. Three sidecar bookmarks are saved into a copy; the check then
    /// compares the whole outline **before and after with PDFKit** (the engine Preview uses),
    /// saves a second time to prove the subtree is rewritten rather than accumulated, and
    /// replaces the copy's original to prove the sidecar no longer duplicates what the file
    /// carries.
    @MainActor static func bookmarkWritebackChecks(root: URL) async throws {
        let fileManager = FileManager.default
        let fixture = root.appendingPathComponent("tests/fixtures/outlined.pdf")
        guard fileManager.fileExists(atPath: fixture.path) else {
            print("INFO: skipping bookmark write-back (no outlined fixture at \(fixture.path))")
            return
        }
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-reader-bookmark-writeback-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("outlined.pdf")
        try fileManager.copyItem(at: fixture, to: source)
        let sidecar = source.appendingPathExtension("lyra-reader-annotations.json")
        let bookmarks = [
            Bookmark(page: 0, title: "Alpha", yPt: 120),
            Bookmark(page: 1, title: "Beta", yPt: 340),
            Bookmark(page: 2, title: "Gamma", yPt: 50),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(bookmarks).write(to: sidecar)
        let sourceBytes = try Data(contentsOf: source)
        let sidecarBytes = try Data(contentsOf: sidecar)

        // ── 1. A document with bookmarks but no annotations can be saved ────────────────
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        state.open(url: source)
        try await eventually("the sidecar's three bookmarks load", {
            state.bookmarks.map(\.id) == bookmarks.map(\.id)
        })
        require(state.annotations.isEmpty, "the fixture has no sidecar annotations")
        require(state.canSaveAnnotationsToPDF,
                "bookmarks alone enable the save commands")
        require(state.canReplaceOriginalWithAnnotations,
                "bookmarks alone enable the replace command")

        let marked = scratch.appendingPathComponent("marked.pdf")
        let copied = await state.saveAnnotatedCopy(to: marked)
        require(copied, "saving a bookmarks-only copy succeeds")
        require(state.lastAnnotationWriteReport?.writtenBookmarkIDs == bookmarks.map(\.id.uuidString),
                "the report names the three written bookmarks")
        require(state.lastAnnotationWriteReport?.bookmarkOutlineTitle == "My bookmarks",
                "the report names the subtree title")
        require(state.lastAnnotationWriteReport?.preexistingOutlineEntryCount == 8,
                "the report counts the document's eight existing entries")
        let sourceAfterCopy = try Data(contentsOf: source)
        let sidecarAfterCopy = try Data(contentsOf: sidecar)
        require(sourceAfterCopy == sourceBytes,
                "the original PDF is untouched by a copy save")
        require(sidecarAfterCopy == sidecarBytes,
                "the original sidecar is untouched by a copy save")
        require(!fileManager.fileExists(
                    atPath: marked.appendingPathExtension("lyra-reader-annotations.json").path),
                "the saved copy carries no sidecar")

        // ── 2. The reader reads the merged outline back ─────────────────────────────────
        let reopened = AppState(engine: try RustEngine())
        reopened.setViewportSize(CGSize(width: 700, height: 500))
        reopened.open(url: marked)
        try await eventually("the reopened copy adopts the file's bookmarks", {
            reopened.bookmarks.map(\.id) == bookmarks.map(\.id)
        })
        for (found, expected) in zip(reopened.bookmarks, bookmarks) {
            require(found.title == expected.title && found.page == expected.page,
                    "the adopted bookmark \(expected.title) keeps its title and page")
            require(abs(found.yPt - expected.yPt) < 0.01,
                    "the adopted bookmark \(expected.title) keeps its page-local position")
        }
        try await eventually("the reopened copy's outline is complete", {
            reopened.outline.count == 12
        })
        require(reopened.outline.filter { $0.depth == 0 }.map(\.title)
                    == ["Chapter One", "Chapter Two", "Chapter Three", "My bookmarks"],
                "the document's top-level entries keep their order; ours is appended")
        require(reopened.outline.first { $0.isBookmarkSubtree }?.title == "My bookmarks",
                "the sidebar flags the reader's own subtree")
        let adoptedRows = reopened.outline.filter { $0.bookmarkID != nil }
        require(adoptedRows.map(\.title) == ["Alpha", "Beta", "Gamma"],
                "the subtree's children are the saved bookmarks, in order")
        require(adoptedRows.map(\.page) == [0, 1, 2],
                "the subtree's destinations resolve to the saved pages")
        require(adoptedRows.allSatisfy { $0.yPt != nil },
                "the subtree carries a page-local position for every bookmark")
        // Clicking the outline row lands where the bookmarks tab's own jump lands, not merely on
        // the page: both use the same page-local Y.
        if let gammaRow = reopened.outline.first(where: {
                    $0.bookmarkID == bookmarks[2].id.uuidString
                }) {
            reopened.jump(to: reopened.bookmarks[2])
            let viaBookmark = reopened.scrollYPt
            reopened.gotoPage(0)
            reopened.gotoOutlineEntry(gammaRow)
            require(abs(reopened.scrollYPt - viaBookmark) < 0.5,
                    "clicking the outline row lands on the bookmark's page position")
            require(reopened.scrollYPt > 0,
                    "the outline click is not merely the top of the page")
        } else {
            require(false, "the outline carries the saved bookmark's identity")
        }

        // ── 3. PDFKit (the engine Preview uses) sees the same outline ───────────────────
        guard let originalPDF = PDFDocument(url: source),
              let savedPDF = PDFDocument(url: marked) else {
            require(false, "PDFKit could not open the original or the saved copy")
            return
        }
        let beforeRows = pdfOutlineRows(originalPDF)
        let afterRows = pdfOutlineRows(savedPDF)
        require(beforeRows.count == 8, "PDFKit reads the fixture's eight outline entries")
        require(Array(afterRows.prefix(8)) == beforeRows,
                "PDFKit sees every existing node at the same depth, destination and page")
        require(afterRows.count == 12, "PDFKit sees the existing tree plus our subtree")
        require(afterRows[8] == PDFOutlineRow(title: "My bookmarks", depth: 0, page: 0),
                "PDFKit reads the subtree root at top level, pointing at its first bookmark")
        require(afterRows[9...].map(\.title) == ["Alpha", "Beta", "Gamma"],
                "PDFKit reads the three bookmarks as children")
        require(afterRows[9...].map(\.page) == [0, 1, 2],
                "PDFKit resolves each bookmark's destination page")
        require(afterRows[9...].allSatisfy { $0.depth == 1 },
                "the bookmarks are one level under the subtree root")
        FileHandle.standardError.write(Data((
            "lyra-reader-bookmarks: PDFKit outline before=\(beforeRows.count) "
            + "after=\(afterRows.count)\n").utf8))

        // ── 4. A second save rewrites the subtree instead of accumulating it ────────────
        let second = scratch.appendingPathComponent("marked-again.pdf")
        let savedAgain = await reopened.saveAnnotatedCopy(to: second)
        require(savedAgain, "re-saving a document that already carries the subtree succeeds")
        require(reopened.lastAnnotationWriteReport?.writtenBookmarkIDs.count == 3,
                "the second save rewrites all three bookmarks")
        guard let secondPDF = PDFDocument(url: second) else {
            require(false, "PDFKit could not open the second save")
            return
        }
        let secondRows = pdfOutlineRows(secondPDF)
        require(secondRows.count == 12, "the second save still has one subtree")
        require(secondRows.filter { $0.title == "My bookmarks" }.count == 1,
                "the subtree is not duplicated")
        let reopenedAgain = AppState(engine: try RustEngine())
        reopenedAgain.setViewportSize(CGSize(width: 700, height: 500))
        reopenedAgain.open(url: second)
        try await eventually("reopening the second save adopts one copy of each bookmark", {
            reopenedAgain.bookmarks.map(\.id) == bookmarks.map(\.id)
        })
        require(reopenedAgain.outline.filter { $0.isBookmarkSubtree }.count == 1,
                "the reader shows exactly one bookmark subtree")

        // ── 5. Replace: the sidecar drops what the file now carries ─────────────────────
        let replaced = await reopenedAgain.replaceOriginalWithSavedAnnotations()
        require(replaced, "replacing the original with its bookmarks succeeds")
        require(reopenedAgain.lastAnnotationWriteReport?.writtenBookmarkIDs.count == 3,
                "the replace writes the three bookmarks")
        let replacedSidecar = second.appendingPathExtension("lyra-reader-annotations.json")
        let replacedSidecarText = String(
            decoding: (try? Data(contentsOf: replacedSidecar)) ?? Data(),
            as: UTF8.self
        )
        require(!bookmarks.contains(where: {
                    replacedSidecarText.contains($0.id.uuidString)
                }),
                "the replaced file's sidecar no longer duplicates the saved bookmarks")
        try await eventually("the replaced document adopts its bookmarks from the file", {
            reopenedAgain.bookmarks.map(\.id) == bookmarks.map(\.id)
        })
        require(reopenedAgain.outline.filter { $0.isBookmarkSubtree }.count == 1,
                "one subtree after the replace, not two")
        if let replacedPDF = PDFDocument(url: second) {
            require(pdfOutlineRows(replacedPDF).filter { $0.title == "My bookmarks" }.count == 1,
                    "PDFKit still sees exactly one subtree after a replace")
        } else {
            require(false, "PDFKit could not open the replaced file")
        }

        // ── 6. The crash window: a stale sidecar must not duplicate the file's copy ─────
        // Replacing the PDF and failing to update the sidecar is the one failure mode that
        // leaves both stores populated. Identity, not presence, decides: the outline's entries
        // are the same bookmarks, so the sidebar shows three, not six.
        try encoder.encode(bookmarks).write(to: replacedSidecar)
        let stale = AppState(engine: try RustEngine())
        stale.setViewportSize(CGSize(width: 700, height: 500))
        stale.open(url: second)
        try await eventually("the stale sidecar loads its three bookmarks", {
            stale.bookmarks.count == 3
        })
        try await eventually("the saved file's outline loads beside it", {
            stale.outline.contains { $0.isBookmarkSubtree }
        })
        require(stale.bookmarks.count == 3,
                "a bookmark the file already carries is not shown twice")
        require(Set(stale.bookmarks.map(\.id)).count == 3,
                "every displayed bookmark has one identity")
    }

    /// Flattens a PDFKit outline depth-first into comparable rows.
    @MainActor
    private static func pdfOutlineRows(_ document: PDFDocument) -> [PDFOutlineRow] {
        var rows: [PDFOutlineRow] = []
        func walk(_ outline: PDFOutline?, depth: Int) {
            guard let outline else { return }
            for index in 0..<outline.numberOfChildren {
                guard let child = outline.child(at: index) else { continue }
                let page = child.destination.flatMap { destination in
                    destination.page.flatMap { document.index(for: $0) }
                }
                rows.append(
                    PDFOutlineRow(title: child.label ?? "", depth: depth, page: page)
                )
                walk(child, depth: depth + 1)
            }
        }
        walk(document.outlineRoot, depth: 0)
        return rows
    }
}
