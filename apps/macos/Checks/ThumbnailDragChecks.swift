import AppKit
import LyraReaderKit
import Foundation

extension ReaderChecks {
    /// Drag-to-reorder on the thumbnail strip.
    ///
    /// The AppKit drag session itself cannot be driven without a window server, so these checks
    /// drive the exact value rules the drag source and drop target call — the press threshold,
    /// the block a drag carries, the insertion boundary under a pointer, and the drop resolution
    /// — and then hand the resulting request to `AppState.performThumbnailDrop`, the one entry
    /// point the drop target uses. Everything after that request is the real staged session, so
    /// the assertions are about the document the reader would get, not a parallel model.
    @MainActor static func thumbnailDragChecks(root: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-reader-thumbnail-drag-\(UUID())")
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
        func sidecarEntry<Value: Encodable>(_ value: Value) throws -> String {
            let encoded = String(decoding: try encoder.encode([value]), as: UTF8.self)
            return String(encoded.dropFirst(2).dropLast(2))
        }
        func writeSidecar(
            _ annotations: [AppState.Annotation],
            _ bookmarks: [Bookmark],
            beside document: URL
        ) throws {
            var lines: [String] = []
            for annotation in annotations { lines.append(try sidecarEntry(annotation)) }
            for bookmark in bookmarks { lines.append(try sidecarEntry(bookmark)) }
            try Data(("[\n" + lines.joined(separator: ",\n") + "\n]").utf8)
                .write(to: document.appendingPathExtension("lyra-reader-annotations.json"))
        }
        func annotation(_ note: String, page: Int) -> AppState.Annotation {
            AppState.Annotation(
                id: UUID(),
                kind: .highlight,
                page: page,
                start: 0,
                end: 4,
                color: AppState.highlightPalette[0].color,
                note: note,
                createdAt: Date()
            )
        }
        func notePages(_ state: AppState) -> [String: Int] {
            Dictionary(uniqueKeysWithValues: state.annotations.map { ($0.note, $0.page) })
        }
        func pageTexts(_ url: URL, count: Int) async throws -> [String] {
            let engine = try RustEngine()
            _ = try engine.openDocument(at: url)
            var texts: [String] = []
            for page in 0..<count {
                texts.append(try await engine.textPage(page).text)
            }
            return texts
        }
        func describes(_ texts: [String], page: Int) -> Bool {
            texts.contains { $0.contains("Page \(page) of 3") }
        }
        func isBlank(_ text: String) -> Bool {
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        func singleColumn(pageCount: Int) -> ThumbnailStripGeometry {
            var frames: [Int: CGRect] = [:]
            for page in 0..<pageCount {
                frames[page] = CGRect(
                    x: 0,
                    y: CGFloat(page) * 160,
                    width: 100,
                    height: 140
                )
            }
            return ThumbnailStripGeometry(
                pageCount: pageCount,
                frames: frames,
                bounds: CGRect(x: 0, y: 0, width: 100, height: CGFloat(pageCount) * 160 + 40)
            )
        }

        // ── The press threshold ─────────────────────────────────────────────────
        // A press must stay a click until the pointer has actually travelled, because the
        // thumbnail is still a navigation control; only then does it become a page drag.
        var stillPress = ThumbnailPressTracker(page: 1, at: CGPoint(x: 20, y: 20))
        require(!stillPress.moved(to: CGPoint(x: 22, y: 20)),
                "a two-point move is below the drag threshold")
        require(stillPress.isClick, "a press that did not move is still a click")
        var dragging = ThumbnailPressTracker(page: 1, at: CGPoint(x: 20, y: 20))
        require(dragging.moved(to: CGPoint(x: 20, y: 25)),
                "five points of movement starts the drag")
        require(!dragging.isClick, "a drag is not also a click")

        // ── Which pages a drag carries ──────────────────────────────────────────
        func block(
            _ pressed: Int,
            selection: Set<Int>,
            pageCount: Int = 5
        ) -> ThumbnailDragBlock {
            guard case .block(let block) = ThumbnailDrag.block(
                pressedPage: pressed,
                selection: selection,
                pageCount: pageCount,
                isEditable: true
            ) else {
                fatalError("expected a draggable block for page \(pressed)")
            }
            return block
        }
        require(
            block(2, selection: []).pages == [2],
            "dragging an unselected thumbnail carries just that page"
        )
        require(
            block(2, selection: [1, 2, 3]).pages == [1, 2, 3],
            "dragging a selected thumbnail carries the whole contiguous block"
        )
        require(
            ThumbnailDrag.block(
                pressedPage: 1,
                selection: [1, 3],
                pageCount: 5,
                isEditable: true
            ) == .refused(.scatteredSelection),
            "a scattered selection has no block to move in order"
        )
        require(
            ThumbnailDrag.block(
                pressedPage: 1,
                selection: [1],
                pageCount: 5,
                isEditable: false
            ) == .refused(.cannotEdit),
            "a drag is refused while page editing is unavailable"
        )

        // ── Insertion boundaries and the indicator ──────────────────────────────
        let threeCells = singleColumn(pageCount: 3)
        require(
            threeCells.insertionBoundary(at: CGPoint(x: 50, y: 170)) == 1,
            "the top half of a single-column thumbnail inserts before it")
        require(
            threeCells.insertionBoundary(at: CGPoint(x: 50, y: 290)) == 2,
            "the bottom half inserts after it")
        require(
            threeCells.insertionBoundary(at: CGPoint(x: 50, y: 500)) == 3,
            "below the last thumbnail inserts at the end")
        require(
            threeCells.insertionBoundary(at: CGPoint(x: -2, y: 20)) == nil,
            "a pointer outside the strip has no insertion boundary")
        let line = threeCells.indicatorRect(for: 1)
        require(line?.minX == 1 && line?.minY == 160 && line?.height == 140,
                "the insertion line sits at the boundary, on the row it belongs to")

        // A two-column row reads left to right: the midpoint between cells is the boundary.
        let grid = ThumbnailStripGeometry(
            pageCount: 4,
            frames: [
                0: CGRect(x: 0, y: 0, width: 90, height: 100),
                1: CGRect(x: 100, y: 0, width: 90, height: 100),
                2: CGRect(x: 0, y: 110, width: 90, height: 100),
                3: CGRect(x: 100, y: 110, width: 90, height: 100),
            ],
            bounds: CGRect(x: 0, y: 0, width: 190, height: 240)
        )
        require(
            grid.insertionBoundary(at: CGPoint(x: 20, y: 50)) == 0,
            "the left half of the first cell inserts at the row start")
        require(
            grid.insertionBoundary(at: CGPoint(x: 95, y: 50)) == 1,
            "the gap between two columns inserts before the second cell")
        require(
            grid.insertionBoundary(at: CGPoint(x: 180, y: 50)) == 2,
            "the right half of the last cell inserts after the row")
        require(
            grid.insertionBoundary(at: CGPoint(x: 20, y: 225)) == 4,
            "the blank space below the last row inserts after the whole row")

        // ── Refusals: no indicator means no command ─────────────────────────────
        let pageThree = block(2, selection: [], pageCount: 3)
        require(
            ThumbnailDrag.drop(block: pageThree, boundary: nil, pageCount: 3)
                == .refused(.outsideStrip),
            "a drag that leaves the strip is cancelled"
        )
        require(
            ThumbnailDrag.drop(block: pageThree, boundary: 3, pageCount: 3)
                == .refused(.noChange),
            "dropping after the page that is already last is a no-op"
        )
        require(
            ThumbnailDrag.drop(block: pageThree, boundary: 2, pageCount: 3)
                == .refused(.noChange),
            "dropping where the block already is is a no-op"
        )
        require(
            ThumbnailDrag.drop(block: pageThree, boundary: 0, pageCount: 3).request
                == ThumbnailDropRequest(pages: [2], destination: 0, pressedPage: 2),
            "moving page 3 before page 1 resolves to destination 0"
        )

        // ── Drag page 3 before page 1, through the staged session ───────────────
        let dragURL = try copyFixture("multipage.pdf", to: "drag-pages.pdf")
        try writeSidecar(
            [annotation("Page 1 mark", page: 0),
             annotation("Page 2 mark", page: 1),
             annotation("Page 3 mark", page: 2)],
            [Bookmark(page: 1, title: "on page two", yPt: 12)],
            beside: dragURL
        )
        let sidecarURL = dragURL.appendingPathExtension("lyra-reader-annotations.json")
        let originalPDF = try Data(contentsOf: dragURL)
        let originalSidecar = try Data(contentsOf: sidecarURL)
        let dragState = AppState(engine: try RustEngine())
        require(dragState.open(url: dragURL), "drag fixture opens")
        require(dragState.document?.pageCount == 3, "drag fixture has three pages")
        let beforeDrag = try await pageTexts(dragURL, count: 3)
        require(describes(beforeDrag, page: 1) && describes(beforeDrag, page: 2)
                    && describes(beforeDrag, page: 3),
                "the drag fixture starts in page order")

        // A press without movement still navigates, through the same handler the overlay calls.
        dragState.gotoPage(0)
        let click = ThumbnailPressTracker(page: 1, at: CGPoint(x: 20, y: 20))
        require(click.isClick, "the navigation press did not become a drag")
        dragState.handleThumbnailClick(1, modifiers: [])
        require(dragState.currentPage == 2,
                "a press without movement still navigates to the page")
        require(dragState.pageSelection == [1],
                "the navigation press still selects the clicked page")

        // A drag that is cancelled outside the strip leaves no session behind.
        let cancelled = ThumbnailDrag.drop(
            block: dragState.thumbnailDragBlock(startingAt: 2).block ?? pageThree,
            boundary: threeCells.insertionBoundary(at: CGPoint(x: -2, y: 20)),
            pageCount: 3
        )
        require(cancelled == .refused(.outsideStrip),
                "the cancelled drag never resolves to a move")
        require(!dragState.pageEditSessionActive,
                "a cancelled drag leaves the staged session untouched")
        require(dragState.document?.url?.standardizedFileURL == dragURL.standardizedFileURL,
                "a cancelled drag leaves the open document where it was")

        // A no-op request is refused by the command too, not just by the indicator.
        let noOp = await dragState.performThumbnailDrop(
            ThumbnailDropRequest(pages: [2], destination: 2, pressedPage: 2)
        )
        require(!noOp, "a drop at the block's own position stages nothing")
        require(!dragState.pageEditSessionActive,
                "a refused drop starts no page-edit session")

        let dragBlock = dragState.thumbnailDragBlock(startingAt: 2).block
        require(dragBlock?.pages == [2],
                "the drag starts on the unselected page 3 and carries just it")
        let dragDrop = ThumbnailDrag.drop(
            block: dragBlock ?? pageThree,
            boundary: threeCells.insertionBoundary(at: CGPoint(x: 50, y: 5)),
            pageCount: 3
        )
        guard let dragRequest = dragDrop.request else {
            fatalError("FAIL: the drag over page 1 resolved to no request")
        }
        let stagedDrag = await dragState.performThumbnailDrop(dragRequest)
        require(stagedDrag, "the drag is staged through the page-edit session")
        require(dragState.pageEditPendingOperations.count == 1,
                "the drag leaves exactly one pending page change")
        require(dragState.pageEditPendingSummary?.contains("file on disk is unchanged") == true,
                "the drag keeps the file-on-disk-unchanged contract")
        require(dragState.pageSelection == [0],
                "the page the reader moved is selected where it landed")
        let afterDrag = try await pageTexts(dragState.document!.url!, count: 3)
        require(describes([afterDrag[0]], page: 3)
                    && describes([afterDrag[1]], page: 1)
                    && describes([afterDrag[2]], page: 2),
                "dragging page 3 before page 1 produces pages 3, 1, 2 in the staged document")
        let notesAfterDrag = notePages(dragState)
        require(notesAfterDrag["Page 3 mark"] == 0
                    && notesAfterDrag["Page 1 mark"] == 1
                    && notesAfterDrag["Page 2 mark"] == 2,
                "the annotations follow their pages through the drag")
        require(dragState.bookmarks.first?.page == 2,
                "the bookmark follows its page through the drag")
        let pendingDragPDF = try Data(contentsOf: dragURL)
        let pendingDragSidecar = try Data(contentsOf: sidecarURL)
        require(pendingDragPDF == originalPDF,
                "the original PDF is byte-identical while the drag is pending")
        require(pendingDragSidecar == originalSidecar,
                "the original sidecar is byte-identical while the drag is pending")

        dragState.undoPageEdit()
        try await eventually("undo the dragged reorder", {
            dragState.pageEditPendingOperations.isEmpty && dragState.canRedoPageEdit
        })
        let afterUndo = try await pageTexts(dragState.document!.url!, count: 3)
        require(describes([afterUndo[0]], page: 1)
                    && describes([afterUndo[1]], page: 2)
                    && describes([afterUndo[2]], page: 3),
                "undo after a drag restores the original page order")
        let notesAfterUndo = notePages(dragState)
        require(notesAfterUndo["Page 1 mark"] == 0
                    && notesAfterUndo["Page 2 mark"] == 1
                    && notesAfterUndo["Page 3 mark"] == 2,
                "undo puts the annotations back on their original pages")
        require(dragState.bookmarks.first?.page == 1,
                "undo puts the bookmark back on its original page")
        let undoneDragPDF = try Data(contentsOf: dragURL)
        require(undoneDragPDF == originalPDF,
                "undo leaves the original PDF byte-identical")
        dragState.discardPageEdits()

        // ── A three-page selection moves as one block, in order ────────────────
        let blockSource = try copyFixture("multipage.pdf", to: "block-source.pdf")
        let fixtureEngine = try RustEngine()
        _ = try fixtureEngine.openDocument(at: blockSource)
        let fiveAPages = scratch.appendingPathComponent("block-five-a.pdf")
        _ = try await fixtureEngine.applyPageOperation(.insertBlank(index: 3), to: fiveAPages)
        _ = try fixtureEngine.openDocument(at: fiveAPages)
        let fivePages = scratch.appendingPathComponent("block-five.pdf")
        _ = try await fixtureEngine.applyPageOperation(.insertBlank(index: 4), to: fivePages)
        try writeSidecar(
            [annotation("Page 2 mark", page: 1),
             annotation("Page 3 mark", page: 2),
             annotation("Blank mark", page: 3)],
            [Bookmark(page: 2, title: "on page three", yPt: 10)],
            beside: fivePages
        )
        let fiveSidecar = fivePages.appendingPathExtension("lyra-reader-annotations.json")
        let fiveOriginal = try Data(contentsOf: fivePages)
        let fiveSidecarBytes = try Data(contentsOf: fiveSidecar)
        let blockState = AppState(engine: try RustEngine())
        require(blockState.open(url: fivePages), "five-page block fixture opens")
        require(blockState.document?.pageCount == 5,
                "the block fixture has five pages (three text, two blank)")
        let beforeBlock = try await pageTexts(fivePages, count: 5)
        require(describes([beforeBlock[0]], page: 1)
                    && describes([beforeBlock[1]], page: 2)
                    && describes([beforeBlock[2]], page: 3)
                    && isBlank(beforeBlock[3]) && isBlank(beforeBlock[4]),
                "the block fixture starts in page order")

        blockState.selectPage(1, extending: false, toggling: false)
        blockState.selectPage(3, extending: true, toggling: false)
        require(blockState.pageSelection == [1, 2, 3],
                "the fixture's three-page range is selected")
        let selectedBlock = blockState.thumbnailDragBlock(startingAt: 2).block
        require(selectedBlock?.pages == [1, 2, 3],
                "the three-page selection is the block the drag carries")
        let blockGeometry = singleColumn(pageCount: 5)
        let blockDrop = ThumbnailDrag.drop(
            block: selectedBlock ?? block(2, selection: [1, 2, 3]),
            boundary: blockGeometry.insertionBoundary(at: CGPoint(x: 50, y: 5)),
            pageCount: 5
        )
        guard let blockRequest = blockDrop.request else {
            fatalError("FAIL: the three-page drag resolved to no request")
        }
        require(blockRequest.destination == 0 && blockRequest.pages == [1, 2, 3],
                "the block lands at the front without reordering inside itself")
        let stagedBlock = await blockState.performThumbnailDrop(blockRequest)
        require(stagedBlock, "the three-page block drag is staged")
        require(blockState.pageEditPendingOperations.count == 1,
                "the block drag leaves one pending page change")
        require(blockState.pageSelection == [0, 1, 2],
                "the moved block is selected at its landing place")
        let afterBlock = try await pageTexts(blockState.document!.url!, count: 5)
        require(describes([afterBlock[0]], page: 2)
                    && describes([afterBlock[1]], page: 3)
                    && isBlank(afterBlock[2])
                    && describes([afterBlock[3]], page: 1)
                    && isBlank(afterBlock[4]),
                "the three-page block keeps its internal order and lands as a block")
        let blockNotes = notePages(blockState)
        require(blockNotes["Page 2 mark"] == 0
                    && blockNotes["Page 3 mark"] == 1
                    && blockNotes["Blank mark"] == 2
                    && blockNotes["Page 1 mark"] == nil,
                "annotations follow the pages inside a block move")
        require(blockState.bookmarks.first?.page == 1,
                "the bookmark follows its page inside a block move")
        let pendingBlockPDF = try Data(contentsOf: fivePages)
        let pendingBlockSidecar = try Data(contentsOf: fiveSidecar)
        require(pendingBlockPDF == fiveOriginal,
                "the block fixture's PDF is byte-identical while pending")
        require(pendingBlockSidecar == fiveSidecarBytes,
                "the block fixture's sidecar is byte-identical while pending")

        blockState.undoPageEdit()
        try await eventually("undo the block drag", {
            blockState.pageEditPendingOperations.isEmpty && blockState.canRedoPageEdit
        })
        let blockUndone = try await pageTexts(blockState.document!.url!, count: 5)
        require(describes([blockUndone[0]], page: 1)
                    && describes([blockUndone[1]], page: 2)
                    && describes([blockUndone[2]], page: 3)
                    && isBlank(blockUndone[3]) && isBlank(blockUndone[4]),
                "undo restores the block's original page order")
        let blockUndoneNotes = notePages(blockState)
        require(blockUndoneNotes["Page 2 mark"] == 1
                    && blockUndoneNotes["Page 3 mark"] == 2
                    && blockUndoneNotes["Blank mark"] == 3,
                "undo restores the block's annotation pages")
        blockState.discardPageEdits()

        // ── The menu reorder command is untouched ──────────────────────────────
        let menuURL = try copyFixture("multipage.pdf", to: "menu-order.pdf")
        let menuState = AppState(engine: try RustEngine())
        require(menuState.open(url: menuURL), "menu reorder fixture opens")
        menuState.selectPage(0, extending: false, toggling: false)
        menuState.moveSelectedPagesDown()
        try await eventually("the Pages-menu move still stages", {
            menuState.pageEditPendingOperations.count == 1
        })
        let menuTexts = try await pageTexts(menuState.document!.url!, count: 3)
        require(describes([menuTexts[0]], page: 2) && describes([menuTexts[1]], page: 1),
                "the menu/keyboard move command still reorders pages")
        menuState.discardPageEdits()
    }
}
