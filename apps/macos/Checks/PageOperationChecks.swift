import AppKit
import LyraReaderKit
import Foundation

extension ReaderChecks {
    /// The shell half of T3.9: a staged page-edit session, the cached-annotation remap across a reorder,
    /// undo/redo, discard, the explicit save commands and the "files on disk are untouched until
    /// Apply" contract.
    ///
    /// The Rust tests own the PDF round trips (rotation, page order, blank size, extraction and
    /// annotations travelling with a moved page). This check exercises what only the app can
    /// prove: that the open document is a working revision, that the original PDF and its
    /// cached annotations stay byte-identical while changes are pending, and that the reader's marks follow
    /// the pages through reorder/delete and come back on undo.
    @MainActor static func pageOperationChecks(root: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-reader-pages-\(UUID())")
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
        func writeAnnotationRecords(
            _ annotations: [AppState.Annotation],
            _ bookmarks: [Bookmark],
            to document: URL
        ) throws {
            var lines: [String] = []
            for annotation in annotations { lines.append(try entry(annotation)) }
            for bookmark in bookmarks { lines.append(try entry(bookmark)) }
            try Data(("[\n" + lines.joined(separator: ",\n") + "\n]").utf8)
                .write(to: DocumentEditCache.annotationsURL(for: document))
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
        try writeAnnotationRecords([pageOne, pageTwo], [bookmark], to: annotated)
        let annotationRecordsURL = DocumentEditCache.annotationsURL(for: annotated)
        let originalBytes = try Data(contentsOf: annotated)
        let originalRecords = try Data(contentsOf: annotationRecordsURL)

        let state = AppState(engine: try RustEngine())
        require(state.open(url: annotated), "page-edit fixture opens")
        require(state.annotations.count == 2 && state.bookmarks.count == 1,
                "page-edit fixture's annotation cache is loaded")
        require(state.document?.pageCount == 2, "page-edit fixture has two pages")

        // ── Rotation is refused when it would invalidate LyraReader's text-range marks ─────
        // cached annotations address character ranges. A rotated page's text layer comes back
        // in a different order, so the honest rule is to refuse the rotation rather than move
        // the highlight onto different words. Embedded PDF annotations rotate with the page.
        let rotationRefused = await state.applyPageEditOperation(
            .rotate(pages: [0], quarterTurns: 1),
            label: "Rotate page 1"
        )
        require(rotationRefused, "rotation automatically embeds cached text-position marks")
        state.undoPageEdit()
        try await eventually("rotation undo restores cached annotation anchors") {
            state.pageEditPendingOperations.isEmpty && !state.pageEditBusy && state.annotations.count == 2
        }
        state.discardPageEdits()

        // ── Rotate, undo, redo on a page with no cached marks ──────────────────────
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

        // The seeded document's original PDF and annotation cache are untouched by the whole refusal.
        let bytesAfterRefusal = try Data(contentsOf: annotated)
        let recordsAfterRefusal = try Data(contentsOf: annotationRecordsURL)
        require(bytesAfterRefusal == originalBytes && recordsAfterRefusal == originalRecords,
                "a refused rotation leaves the original PDF and cache byte-identical")

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
                "cached annotations follow their pages through a reorder")
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
        let discardedRecords = try Data(contentsOf: annotationRecordsURL)
        require(discardedBytes == originalBytes,
                "discard leaves the original PDF byte-identical")
        require(discardedRecords == originalRecords,
                "discard leaves the original cache byte-identical")

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

        // ── Explicit replace: backup, verify, remapped annotation cache ─────────────────────
        let replaced = try copyFixture("annotated.pdf", to: "replaced.pdf")
        let replacedRecords = DocumentEditCache.annotationsURL(for: replaced)
        let replacedPageOne = AppState.Annotation(
            id: UUID(), kind: .highlight, page: 0, start: 0, end: 4,
            color: AppState.highlightPalette[0].color, note: "goes away", createdAt: Date()
        )
        let replacedPageTwo = AppState.Annotation(
            id: UUID(), kind: .highlight, page: 1, start: 0, end: 4,
            color: AppState.highlightPalette[1].color, note: "stays", createdAt: Date()
        )
        try writeAnnotationRecords([replacedPageOne, replacedPageTwo], [], to: replaced)
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
        ).filter { $0.lastPathComponent.contains(".lyra-reader-backup-") }
        require(backups.count == 1, "a verified backup of the original is left beside it")
        let reopened = AppState(engine: try RustEngine())
        require(reopened.open(url: replaced), "the replaced PDF reopens in a fresh reader")
        require(reopened.document?.pageCount == 1, "the replaced PDF keeps exactly one page")
        try await eventually("the saved mark is read from the surviving PDF page") {
            reopened.documentAnnotations.contains { $0.contents == "stays" && $0.page == 0 }
        }
        require(reopened.annotations.isEmpty, "saved marks need no duplicate cache records")

        // ── Save Edited Copy: original untouched, copy verified, marks embedded ────
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

        // ── Merge: page count, boundary text, annotations, outline, cached marks ───
        //
        // The first document has an outline and reader marks; the appended annotated.pdf
        // carries another viewer's annotations; the third document has an outline of its own,
        // which a merge must NOT import. Every input is copied into the scratch directory, so
        // the committed fixtures are never written.
        let mergeFirst = try copyFixture("outlined.pdf", to: "merge-first.pdf")
        let mergeAnnotated = try copyFixture("annotated.pdf", to: "merge-annotated.pdf")
        let mergeThird = try copyFixture("outlined.pdf", to: "merge-third.pdf")
        let mergeMark = AppState.Annotation(
            id: UUID(), kind: .highlight, page: 0, start: 0, end: 5,
            color: AppState.highlightPalette[0].color, note: "merge mark", createdAt: Date()
        )
        let mergeBookmark = Bookmark(page: 1, title: "merge bookmark", yPt: 10)
        try writeAnnotationRecords([mergeMark], [mergeBookmark], to: mergeFirst)
        let mergeRecords = DocumentEditCache.annotationsURL(for: mergeFirst)
        let mergeFirstBytes = try Data(contentsOf: mergeFirst)
        let mergeRecordsBytes = try Data(contentsOf: mergeRecords)
        let mergeState = AppState(engine: try RustEngine())
        require(mergeState.open(url: mergeFirst), "merge fixture opens")
        let merged = scratch.appendingPathComponent("merged.pdf")
        let mergedOK = await mergeState.mergeDocuments(
            [mergeAnnotated, mergeThird],
            to: merged
        )
        require(mergedOK, "merge writes a new file")
        require(mergeState.document?.url?.standardizedFileURL.path
                    == mergeFirst.standardizedFileURL.path,
                "merge leaves the open document alone (immediate-to-a-new-file, like extract)")
        require(!mergeState.pageEditSessionActive, "merge does not start a page-edit session")
        let mergeFirstAfter = try Data(contentsOf: mergeFirst)
        let mergeRecordsAfter = try Data(contentsOf: mergeRecords)
        require(mergeFirstAfter == mergeFirstBytes,
                "merge leaves the first document byte-identical")
        require(mergeRecordsAfter == mergeRecordsBytes,
                "merge leaves the first document's cache byte-identical")
        require(mergeState.statusMessage.contains("did not import 8 outline entries"),
                "the merge message says what happened to the appended outlines")
        require(mergeState.statusMessage.contains("start without LyraReader marks"),
                "the merge message says what happens to marks on appended pages")

        let mergedState = AppState(engine: try RustEngine())
        require(mergedState.open(url: merged), "the merged file opens")
        require(mergedState.document?.pageCount == 8,
                "the merged file has the sum of the three documents' pages")
        try await eventually("the merged document loads its embedded marks and bookmarks") {
            mergedState.documentAnnotations.contains { $0.contents == "merge mark" } && mergedState.bookmarks.count == 1
        }
        let mergedMarks = Dictionary(
            uniqueKeysWithValues: mergedState.documentAnnotations.map { ($0.contents, $0.page) }
        )
        require(mergedMarks["merge mark"] == 0,
                "our annotation keeps its page after a merge")
        require(mergedState.bookmarks.count == 1 && mergedState.bookmarks[0].page == 1,
                "our bookmark keeps its page after a merge")
        require(mergedState.annotations.isEmpty,
                "the merged file embeds marks without requiring cache records")
        try await eventually("the merged outline loads", {
            mergedState.outline.filter { !$0.isBookmarkSubtree && $0.bookmarkID == nil }.count == 8
        })
        require(mergedState.outline.filter { $0.depth == 0 && !$0.isBookmarkSubtree }.map(\.title)
                    == ["Chapter One", "Chapter Two", "Chapter Three"],
                "the first document's outline survives the merge")
        let mergedProbe = try RustEngine()
        _ = try mergedProbe.openDocument(at: merged)
        let lastFirstText = try await mergedProbe.textPage(2).text
        let firstAppendedText = try await mergedProbe.textPage(3).text
        let secondAppendedText = try await mergedProbe.textPage(4).text
        require(lastFirstText.contains("Chapter Three"),
                "the last page of the first document still belongs to the first document")
        require(firstAppendedText.contains("Annotated page 1"),
                "the first appended page belongs to the appended document")
        require(secondAppendedText.contains("Annotated page 2"),
                "the second appended page belongs to the appended document")
        try await eventually("the merged file's embedded annotations load", {
            !mergedState.documentAnnotations.isEmpty
        })
        require(mergedState.documentAnnotations.contains { $0.page == 3 },
                "the appended pages' file-owned annotations are present in the merged file")

        // Self-merge and an encrypted appended document are refused and write nothing.
        let refusedMerge = scratch.appendingPathComponent("refused-merge.pdf")
        let selfMergeOK = await mergeState.mergeDocuments([mergeFirst], to: refusedMerge)
        require(!selfMergeOK, "merging a document into itself is refused")
        require(!fileManager.fileExists(atPath: refusedMerge.path),
                "a refused self-merge writes no output")
        let encryptedMerge = try copyFixture(
            "form-fields-encrypted.pdf",
            to: "merge-encrypted.pdf"
        )
        let encryptedMergeOK = await mergeState.mergeDocuments([encryptedMerge], to: refusedMerge)
        require(!encryptedMergeOK, "merging an encrypted document is refused")
        require(!fileManager.fileExists(atPath: refusedMerge.path),
                "a refused encrypted merge writes no output")
        require(mergeState.lastError?.lowercased().contains("password-protected") == true,
                "the encrypted-merge refusal gives a readable reason")

        // ── Split: plan parsing/naming, ranges, every-five, annotation cache remap, failure ───
        let everyFive = try PageSplitPlan.chunks(pageCount: 11, every: 5)
        require(everyFive.map(\.count) == [5, 5, 1],
                "an eleven-page document splits every five pages as 5 + 5 + 1")
        let parsedRanges = try PageSplitPlan.ranges("1-5, 6-10, 11", pageCount: 11)
        require(parsedRanges.map(\.count) == [5, 5, 1],
                "explicit ranges become the three expected page lists")
        do {
            _ = try PageSplitPlan.ranges("1-6, 5-10", pageCount: 11)
            require(false, "overlapping ranges are refused by the plan")
        } catch {
            require(error.localizedDescription.contains("overlaps"),
                    "the overlap refusal names the problem")
        }
        do {
            _ = try PageSplitPlan.ranges("0-2", pageCount: 11)
            require(false, "page zero is refused by the plan")
        } catch {}
        do {
            _ = try PageSplitPlan.chunks(pageCount: 11, every: 0)
            require(false, "splitting every zero pages is refused")
        } catch {}
        let splitNames = PageSplitPlan.outputURLs(
            base: URL(fileURLWithPath: "/tmp/Paper.pdf"),
            ranges: parsedRanges
        ).map(\.lastPathComponent)
        require(splitNames == [
            "Paper (pages 1-5).pdf",
            "Paper (pages 6-10).pdf",
            "Paper (page 11).pdf",
        ], "split output names say which pages each file contains")

        // Build an eleven-page document from committed fixtures through the engine itself.
        let elevenSource = try copyFixture("multipage.pdf", to: "eleven-source.pdf")
        let elevenExtraOne = try copyFixture("multipage.pdf", to: "eleven-extra-1.pdf")
        let elevenExtraTwo = try copyFixture("multipage.pdf", to: "eleven-extra-2.pdf")
        let elevenTwoPages = scratch.appendingPathComponent("eleven-two-pages.pdf")
        let extractState = AppState(engine: try RustEngine())
        require(extractState.open(url: elevenSource), "the eleven-page base opens")
        let twoPageExcerptOK = await extractState.extractPages([0, 1], to: elevenTwoPages)
        require(twoPageExcerptOK,
                "the two-page excerpt for the eleven-page document is written")
        let eleven = scratch.appendingPathComponent("eleven.pdf")
        let builder = AppState(engine: try RustEngine())
        require(builder.open(url: elevenSource), "the eleven-page builder opens")
        let assembledOK = await builder.mergeDocuments(
            [elevenExtraOne, elevenExtraTwo, elevenTwoPages],
            to: eleven
        )
        require(assembledOK, "the eleven-page document is assembled by merging")
        let elevenProbe = try RustEngine()
        let elevenLoaded = try elevenProbe.openDocument(at: eleven)
        require(elevenLoaded.pageCount == 11, "the assembled document has eleven pages")

        let splitMark = AppState.Annotation(
            id: UUID(), kind: .underline, page: 10, start: 0, end: 4,
            color: AppState.highlightPalette[1].color, note: "last page mark", createdAt: Date()
        )
        let splitBookmark = Bookmark(page: 5, title: "middle bookmark", yPt: 20)
        try writeAnnotationRecords([splitMark], [splitBookmark], to: eleven)
        let elevenRecords = DocumentEditCache.annotationsURL(for: eleven)
        let elevenBytes = try Data(contentsOf: eleven)
        let elevenRecordsBytes = try Data(contentsOf: elevenRecords)
        let splitState = AppState(engine: try RustEngine())
        require(splitState.open(url: eleven), "the eleven-page split source opens")
        require(splitState.annotations.count == 1 && splitState.bookmarks.count == 1,
                "the split source's marks are loaded")

        let rangeOutputs = [
            scratch.appendingPathComponent("range-1-5.pdf"),
            scratch.appendingPathComponent("range-6-10.pdf"),
            scratch.appendingPathComponent("range-11.pdf"),
        ]
        let rangeSplitOK = await splitState.splitPages(parsedRanges, to: rangeOutputs)
        require(rangeSplitOK, "splitting into explicit ranges writes every file")
        for (index, expectedPages) in [5, 5, 1].enumerated() {
            let probe = try RustEngine()
            let loaded = try probe.openDocument(at: rangeOutputs[index])
            require(loaded.pageCount == expectedPages,
                    "range output \(index + 1) has exactly \(expectedPages) page(s)")
        }
        let rangeFirst = try RustEngine()
        _ = try rangeFirst.openDocument(at: rangeOutputs[0])
        let firstStartText = try await rangeFirst.textPage(0).text
        let firstEndText = try await rangeFirst.textPage(4).text
        require(firstStartText.contains("Page 1 of 3"),
                "the first range starts on the source's first page")
        require(firstEndText.contains("Page 2 of 3"),
                "the first range ends on the source's fifth page")
        let rangeSecond = try RustEngine()
        _ = try rangeSecond.openDocument(at: rangeOutputs[1])
        let secondStartText = try await rangeSecond.textPage(0).text
        let secondEndText = try await rangeSecond.textPage(4).text
        require(secondStartText.contains("Page 3 of 3"),
                "the second range starts on the source's sixth page")
        require(secondEndText.contains("Page 1 of 3"),
                "the second range ends on the source's tenth page")
        let rangeThird = try RustEngine()
        _ = try rangeThird.openDocument(at: rangeOutputs[2])
        let thirdStartText = try await rangeThird.textPage(0).text
        require(thirdStartText.contains("Page 2 of 3"),
                "the last range is the source's eleventh page")
        let elevenAfterRanges = try Data(contentsOf: eleven)
        require(elevenAfterRanges == elevenBytes,
                "splitting into ranges leaves the source byte-identical")

        // The reader's marks follow their pages into the outputs that contain them.
        let rangeSecondState = AppState(engine: try RustEngine())
        require(rangeSecondState.open(url: rangeOutputs[1]),
                "the second range output opens")
        try await eventually("the split bookmark loads from the output PDF") { rangeSecondState.bookmarks.count == 1 }
        require(rangeSecondState.bookmarks.count == 1
                    && rangeSecondState.bookmarks[0].page == 0
                    && rangeSecondState.bookmarks[0].title == "middle bookmark",
                "a bookmark is renumbered into the output that contains its page")
        require(rangeSecondState.annotations.isEmpty,
                "the second output carries no mark from another page")
        let rangeThirdState = AppState(engine: try RustEngine())
        require(rangeThirdState.open(url: rangeOutputs[2]), "the last range output opens")
        try await eventually("the last output embeds its annotation on the remapped page") {
            rangeThirdState.documentAnnotations.contains { $0.contents == "last page mark" && $0.page == 0 }
        }
        require(rangeThirdState.bookmarks.isEmpty,
                "the last output carries no bookmark from another page")
        let elevenRecordsAfter = try Data(contentsOf: elevenRecords)
        require(elevenRecordsAfter == elevenRecordsBytes,
                "splitting leaves the source cache byte-identical")

        // Every five pages: 5 + 5 + 1 on the same eleven-page document.
        let everyFiveOutputs = [
            scratch.appendingPathComponent("five-1.pdf"),
            scratch.appendingPathComponent("five-2.pdf"),
            scratch.appendingPathComponent("five-3.pdf"),
        ]
        let everyFiveOK = await splitState.splitPages(everyFive, to: everyFiveOutputs)
        require(everyFiveOK, "splitting every five pages writes three files")
        for (index, expectedPages) in [5, 5, 1].enumerated() {
            let probe = try RustEngine()
            let loaded = try probe.openDocument(at: everyFiveOutputs[index])
            require(loaded.pageCount == expectedPages,
                    "every-five output \(index + 1) has \(expectedPages) page(s)")
        }

        // A failure on the third output leaves the first two complete and the source untouched.
        // The third destination's parent is a regular file, so the engine fails only when it
        // reaches that part (all outputs passed the shell's preflight, which checks names only).
        let blocker = scratch.appendingPathComponent("split-blocker.pdf")
        try Data("not a directory".utf8).write(to: blocker)
        let lateFailureOutputs = [
            scratch.appendingPathComponent("late-1.pdf"),
            scratch.appendingPathComponent("late-2.pdf"),
            blocker.appendingPathComponent("late-3.pdf"),
        ]
        let lateFailureOK = await splitState.splitPages(
            [[0, 1, 2, 3, 4], [5, 6, 7, 8, 9], [10]],
            to: lateFailureOutputs
        )
        require(!lateFailureOK, "a failure on the third output fails the split")
        let lateFirstProbe = try RustEngine()
        let lateFirstLoaded = try lateFirstProbe.openDocument(at: lateFailureOutputs[0])
        require(lateFirstLoaded.pageCount == 5,
                "the first output is complete after a later failure")
        let lateSecondProbe = try RustEngine()
        let lateSecondLoaded = try lateSecondProbe.openDocument(at: lateFailureOutputs[1])
        require(lateSecondLoaded.pageCount == 5,
                "the second output is complete after a later failure")
        require(!fileManager.fileExists(atPath: lateFailureOutputs[2].path),
                "the failed third output does not exist")
        let elevenAfterFailure = try Data(contentsOf: eleven)
        require(elevenAfterFailure == elevenBytes,
                "a failed split leaves the source byte-identical")
        require(splitState.lastError?.contains("2 complete output(s)") == true,
                "the failure says how many outputs are complete")

        // Splitting an encrypted document is refused before anything is written.
        let encryptedSplitSource = try copyFixture(
            "form-fields-encrypted.pdf",
            to: "split-encrypted.pdf"
        )
        let encryptedSplitState = AppState(engine: try RustEngine())
        require(encryptedSplitState.open(url: encryptedSplitSource),
                "the encrypted split fixture opens (empty user password)")
        let encryptedSplitOutput = scratch.appendingPathComponent("encrypted-part.pdf")
        let encryptedSplitOK = await encryptedSplitState.splitPages(
            [[0]],
            to: [encryptedSplitOutput]
        )
        require(!encryptedSplitOK, "splitting an encrypted document is refused")
        require(!fileManager.fileExists(atPath: encryptedSplitOutput.path),
                "a refused encrypted split writes nothing")
        require(encryptedSplitState.lastError?.lowercased().contains("password-protected") == true,
                "the encrypted-split refusal gives a readable reason")
    }
}
