import ArisReaderKit
import CoreGraphics
import Foundation

extension ReaderChecks {
    /// T2.13: bookmarks survive the sidecar's round trip and an older-format file, and every
    /// list operation writes what it says it wrote.
    ///
    /// The compatibility claim is tested from both directions this build can see:
    ///
    /// * an **older** sidecar (an annotation written before `kind`/bookmarks existed) loads
    ///   unchanged, and a bookmark can be added beside it without disturbing it;
    /// * a **newer** bookmark entry — one carrying a field this build does not know — is
    ///   preserved byte-for-byte when this build writes the file, and is not misread as one of
    ///   its own bookmarks.
    ///
    /// The third direction, "an annotation-only build preserves the bookmark", is a property of
    /// `AnnotationSidecar`'s unknown-kind rule that `annotationRecoveryChecks` already pins for
    /// `ink`: an entry whose `kind` is not `highlight`/`underline` goes to the verbatim slot
    /// before any of its other keys are looked at. The bookmark entries this check inspects all
    /// carry `"kind" : "bookmark"` for exactly that reason.
    @MainActor static func bookmarkChecks(url: URL) async throws {
        let directory = url.deletingLastPathComponent()
        let document = directory.appendingPathComponent("bookmarks-\(UUID()).pdf")
        let sidecar = document.appendingPathExtension("aris-annotations.json")
        try? FileManager.default.removeItem(at: document)
        try? FileManager.default.removeItem(at: sidecar)
        try FileManager.default.copyItem(at: url, to: document)
        defer {
            try? FileManager.default.removeItem(at: document)
            try? FileManager.default.removeItem(at: sidecar)
        }

        let encoder = JSONEncoder()
        let legacyAnnotation = AppState.Annotation(
            id: UUID(), page: 0, start: 0, end: 3,
            color: AppState.highlightPalette[0].color, note: "kept from the old build",
            createdAt: Date()
        )
        var legacyObject = try JSONSerialization.jsonObject(
            with: encoder.encode(legacyAnnotation)
        ) as! [String: Any]
        legacyObject.removeValue(forKey: "kind")
        try JSONSerialization.data(withJSONObject: [legacyObject]).write(to: sidecar)

        // ── An annotation-only sidecar, then a bookmark beside it ──────────────────────────
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 900, height: 300))
        state.open(url: document)
        require(state.annotations.count == 1 && state.bookmarks.isEmpty,
                "an older-format sidecar still loads, with no bookmarks to invent")
        require(state.annotations.first?.note == "kept from the old build",
                "the old annotation survives loading the newer model")

        state.gotoPage(0)
        state.scroll(byScreenPoints: 240)
        let firstPosition = state.scrollYPt
        require(state.addBookmarkAtCurrentPage(name: "  Introduction  "), "a bookmark is added")
        require(state.bookmarks.count == 1, "the bookmark appears in the sidebar's list")
        let first = state.bookmarks[0]
        require(first.title == "Introduction", "the name is trimmed and stored as given")
        require(first.page == 0 && abs(first.yPt - firstPosition) < 0.01,
                "the bookmark stores the page and the page-local position")

        var fileText = try String(decoding: Data(contentsOf: sidecar), as: UTF8.self)
        require(fileText.contains("\"kind\" : \"bookmark\""),
                "bookmarks carry the discriminator an annotation-only build treats as unknown")
        require(fileText.contains("\"note\" : \"kept from the old build\""),
                "adding a bookmark does not disturb the old annotation")
        require(fileText.contains("\"yPt\""),
                "the page-local position is part of the bookmark entry")

        state.scroll(byScreenPoints: 240)
        require(state.addBookmarkAtCurrentPage(), "a bookmark without a name gets the default")
        require(state.bookmarks.count == 2 && state.bookmarks[1].title == "Page 1",
                "an unnamed bookmark is called after its page")

        // ── Rename, reorder, delete: each one reaches disk ────────────────────────────────
        let second = state.bookmarks[1]
        state.renameBookmark(second.id, to: "Method")
        require(state.bookmarks[1].title == "Method", "rename updates the list")
        state.moveBookmark(second.id, by: -1)
        require(state.bookmarks.map(\.title) == ["Method", "Introduction"],
                "reorder moves the bookmark and keeps the rest in order")

        let reopened = AppState(engine: try RustEngine())
        reopened.setViewportSize(CGSize(width: 900, height: 300))
        reopened.open(url: document)
        require(reopened.bookmarks.map(\.title) == ["Method", "Introduction"],
                "the saved order survives a save/reopen round trip")
        require(reopened.bookmarks.map(\.page) == [0, 0],
                "the pages survive the round trip")
        require(abs(reopened.bookmarks[0].yPt - (firstPosition + 240)) < 0.01,
                "the page-local positions survive the round trip")
        require(reopened.annotations.count == 1,
                "the old annotation is still there after the bookmarks were written")

        reopened.removeBookmark(reopened.bookmarks[0].id)
        let afterDelete = AppState(engine: try RustEngine())
        afterDelete.setViewportSize(CGSize(width: 900, height: 300))
        afterDelete.open(url: document)
        require(afterDelete.bookmarks.map(\.title) == ["Introduction"],
                "delete persists across a reopen")

        // The sidebar's grouping model: one section per page, first appearance wins.
        let page0 = Bookmark(page: 0, title: "a")
        let page1 = Bookmark(page: 1, title: "b")
        let page0Again = Bookmark(page: 0, title: "c")
        let groups = BookmarkGrouping.groups(for: [page0, page1, page0Again])
        require(groups.map(\.page) == [0, 1],
                "bookmarks group by page in first-appearance order")
        require(groups[0].bookmarks.map(\.title) == ["a", "c"],
                "a page's bookmarks keep their relative order inside the group")
        require(groups[0].title == "Page 1 · 2 bookmarks",
                "the group label carries the count")

        // ── A newer build's bookmark entry is preserved, not misread ──────────────────────
        let futureID = UUID().uuidString
        let futureEntry = "{\"color\":\"#FF00FFFF\",\"createdAt\":800000000,"
            + "\"id\":\"\(futureID)\",\"kind\":\"bookmark\",\"page\":0,"
            + "\"title\":\"from a newer build\",\"yPt\":12}"
        fileText = try String(decoding: Data(contentsOf: sidecar), as: UTF8.self)
        let closed = fileText.hasSuffix("\n]") ? String(fileText.dropLast(2)) : fileText
        let withFuture = closed + ",\n  " + futureEntry + "\n]"
        try Data(withFuture.utf8).write(to: sidecar)

        let future = AppState(engine: try RustEngine())
        future.setViewportSize(CGSize(width: 900, height: 300))
        future.open(url: document)
        require(future.bookmarks.count == 1,
                "an extended bookmark entry is not half-read as one of this build's bookmarks")
        require(future.preservedAnnotationEntryCount == 1,
                "the extended entry is preserved instead of rejected")
        future.gotoPage(0)
        require(future.addBookmarkAtCurrentPage(name: "Local"), "a write is possible beside a future entry")
        let rewritten = try String(decoding: Data(contentsOf: sidecar), as: UTF8.self)
        require(rewritten.contains(futureEntry),
                "the newer entry survives the write byte-for-byte")
        require(rewritten.contains("\"title\" : \"Local\""),
                "this build's new bookmark is written too")
    }

    /// T2.10: facing pages place page 1 alone and 2–3 side by side; the geometry the canvas
    /// already relies on (centres under a zoom anchor, hit tests, the prefetch band, the
    /// screen-page cache, the scroll indicator) still holds; the gap applies immediately and
    /// clamps at both bounds.
    @MainActor static func facingLayoutChecks(url: URL) async throws {
        let engine = try RustEngine()
        let state = AppState(engine: engine)
        state.setViewportSize(CGSize(width: 1300, height: 900))
        state.open(url: url)
        require(state.document?.pageCount == 3, "the facing fixture has three pages")

        // ── Page 1 alone, then 2–3 side by side ──────────────────────────────────────────
        state.setLayoutMode(.facing)
        require(state.layoutMode == .facing, "the display mode is switchable")
        require(abs(state.contentWidthPt - (2 * 595 + 12)) < 0.01,
                "facing content is two page columns wide plus the gap")
        require(abs(state.contentHeightPt - (842 + 12 + 842)) < 0.01,
                "facing content is a cover row plus one spread row")

        state.gotoPage(0)
        require(state.pagePlacement(at: CGPoint(x: 650, y: 100))?.index == 0,
                "page 1 is on screen in facing mode")
        require(state.pagePlacement(at: CGPoint(x: 10, y: 100)) == nil,
                "page 1 is alone: there is no left-hand page beside it")

        state.gotoPage(1)
        let left = state.pagePlacement(at: CGPoint(x: 100, y: state.scrollYPt + 100))
        let right = state.pagePlacement(at: CGPoint(x: 620, y: state.scrollYPt + 100))
        require(left?.index == 1 && right?.index == 2,
                "the spread names pages 2 and 3 (0-based 1 and 2), got \(String(describing: left?.index)), \(String(describing: right?.index))")
        require(left?.topPt == right?.topPt, "a spread's two pages share a top edge")
        require(abs((left?.leftPt ?? .nan) - 0) < 0.01,
                "the left page starts at the left column")
        require(abs((right?.leftPt ?? .nan) - (595 + 12)) < 0.01,
                "the right page starts one page width plus the gap to the right")
        require(state.currentPage == 2,
                "the current page is the spread's left page, not the right one")

        // Click hit-testing on the right-hand page: a point inside it must select page 2's
        // text, not the left page's. Text layers arrive asynchronously, so retry.
        try await eventually("a click on the right page hit-tests that page", {
            state.beginSelection(at: CGPoint(x: (right?.leftPt ?? 0) + 300,
                                             y: (right?.topPt ?? 0) + 100))
            return state.selection?.page == 2
        })

        // The selection overlay is placed through the right page's placement, like every
        // annotation quad and the note overlay; it must not be drawn over the left page.
        if let rightSelection = state.canvasPages.first(where: {
            $0.placement.index >= PlacementIndex.selection(0) && $0.placement.index < 0
        }) {
            require(rightSelection.placement.leftPt >= (right?.leftPt ?? .infinity),
                    "the selection overlay for the right page is drawn over that page")
        } else {
            fatalError("FAIL: selecting on the right page produced no selection overlay")
        }

        // A clicked region's anchor (citation/figure preview, note overlay) resolves through
        // the same placement, so it must land on the right-hand page too.
        let rightRegion = CGRect(x: 10, y: 20, width: 30, height: 40)
        let rightAnchor = state.anchorViewRect(page: 2, region: rightRegion)
        require(rightAnchor == state.viewRect(local: rightRegion, on: right!),
                "a preview/note anchor on the right page uses the right page's placement")

        // ── Pointer-anchored zoom keeps a page centre still ──────────────────────────────
        state.clearSelection()
        state.gotoPage(1)
        // The spread is the last row, so its top cannot be scrolled to if that would leave
        // blank space below; start a little above it and let the anchor test use that offset.
        state.scroll(byScreenPoints: -100)
        let centerContentY = (left?.topPt ?? 0) + (left?.heightPt ?? 0) / 2
        let anchorViewY = (centerContentY - state.scrollYPt) * state.zoomFactor
        let beforeContentY = CanvasGeometry.contentY(
            viewY: anchorViewY, scrollYPt: state.scrollYPt, zoom: state.zoomFactor
        )
        let centerViewBefore = (centerContentY - state.scrollYPt) * state.zoomFactor
        require(state.zoomByPinch(0.1, anchorViewY: anchorViewY), "the pinch zooms")
        let afterContentY = CanvasGeometry.contentY(
            viewY: anchorViewY, scrollYPt: state.scrollYPt, zoom: state.zoomFactor
        )
        let centerViewAfter = (centerContentY - state.scrollYPt) * state.zoomFactor
        require(abs(beforeContentY - afterContentY) < 0.05,
                "the page centre stays under the pointer through a facing-page zoom")
        require(abs(centerViewBefore - anchorViewY) < 0.05
                    && abs(centerViewAfter - anchorViewY) < 0.05,
                "the page centre is at the same view point before and after the zoom")

        // ── The prefetch band knows both pages of a spread ───────────────────────────────
        let bandEngine = try RustEngine()
        let bandState = AppState(engine: bandEngine, preferFullPageRasters: false)
        bandState.setViewportSize(CGSize(width: 1300, height: 900))
        bandState.open(url: url)
        bandState.setLayoutMode(.facing)
        bandState.gotoPage(1)
        let bandPages = Set(bandState.pinnedTiles.map(\.page))
        require(bandPages.contains(1) && bandPages.contains(2),
                "the prefetch band wants both pages of the visible spread, got \(bandPages.sorted())")

        // ── The screen-resolution page cache holds both pages of a spread ────────────────
        let screenState = AppState(engine: try RustEngine())
        screenState.setViewportSize(CGSize(width: 1300, height: 900))
        screenState.open(url: url)
        screenState.setLayoutMode(.facing)
        screenState.gotoPage(1)
        try await eventually("both pages of the spread sharpen", {
            screenState.isScreenPageCached(1) && screenState.isScreenPageCached(2)
        })
        let rasterPages = Set(screenState.canvasPages.compactMap { page -> Int? in
            guard PlacementIndex.isPageRaster(page.placement.index) else { return nil }
            return page.placement.index
        })
        require(rasterPages.contains(PlacementIndex.pageRaster(1))
                    && rasterPages.contains(PlacementIndex.pageRaster(2)),
                "the canvas is handed a page raster for each half of the spread")

        // ── The gap applies immediately, in both axes, and clamps ───────────────────────
        state.setLayoutMode(.continuous)
        state.gotoPage(0)
        _ = state.contentHeightPt
        state.setLayoutMode(.facing)
        require(abs(state.contentHeightPt - (842 + 12 + 842)) < 0.01,
                "switching to facing changes the content height without a reopen")

        state.setPageGap(30)
        require(abs(state.pageGapPt - 30) < 0.01, "the gap is accepted")
        require(abs(state.contentHeightPt - (842 + 30 + 842)) < 0.01,
                "the new gap changes the vertical layout immediately")
        require(abs(state.contentWidthPt - (2 * 595 + 30)) < 0.01,
                "the new gap changes the horizontal layout immediately")

        state.setPageGap(999)
        require(abs(state.pageGapPt - 48) < 0.01, "the gap clamps at its upper bound")
        state.setPageGap(-10)
        require(abs(state.pageGapPt - 0) < 0.01, "the gap clamps at its lower bound")
        require(abs(state.contentHeightPt - (842 + 842)) < 0.01,
                "a zero gap packs the facing rows together")

        // Scroll-indicator geometry reads the content height, so it has to follow the layout.
        state.setPageGap(12)
        require(state.hasScrollableContent, "the spread document is scrollable")
        require(state.viewportFraction > 0 && state.viewportFraction <= 1,
                "the indicator thumb is sized from the new content height")
        require(state.scrollFraction >= 0 && state.scrollFraction <= 1,
                "the indicator position stays inside its track")
    }
}
