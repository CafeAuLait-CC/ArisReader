import AppKit
import ArisReaderKit
import SwiftUI

extension ReaderChecks {
    /// Regression for the reader's report: after the last tab closed, the previous page was still
    /// painted on the Metal canvas, with the empty state ("Open a paper to start reading" and its
    /// "Open PDF…" button) drawn over the middle of it.
    ///
    /// The model was already empty — the bug was in the frame path. `MetalCanvasView` returned
    /// before submitting a frame when there were no page quads, so no new drawable was presented
    /// and the `CAMetalLayer` kept showing the closed document. These checks therefore assert the
    /// **frame**, not just the model: after the last tab closes, a new frame must present with
    /// zero page quads. Waiting only for `canvasPages.isEmpty` would have passed on the broken
    /// build, which is exactly why the regression needs this observable.
    @MainActor static func canvasClearChecks(a: URL, b: URL) async throws {
        _ = NSApplication.shared

        /// One reader window built the way the app builds it: the real `ReaderWindow`, so
        /// `PDFCanvasView.updateNSView` hands `AppState.canvasPages` to the real `MetalCanvasView`
        /// and the empty state is the production one.
        func makeReader(at origin: CGPoint) throws -> (
            state: AppState,
            host: NSHostingView<ReaderWindow>,
            window: NSWindow,
            panels: ReferencePreviewPanelController
        ) {
            let state = AppState(engine: try RustEngine())
            state.setViewportSize(CGSize(width: 700, height: 500))
            let panels = ReferencePreviewPanelController()
            let host = NSHostingView(rootView: ReaderWindow(
                state: state,
                opener: DocumentOpenCoordinator(state: state),
                previewPanels: panels))
            let window = NSWindow(
                contentRect: CGRect(x: origin.x, y: origin.y, width: 700, height: 520),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = host
            return (state, host, window, panels)
        }

        func canvas(in view: NSView) -> MetalCanvasView? {
            if let found = view as? MetalCanvasView { return found }
            return view.subviews.lazy.compactMap { canvas(in: $0) }.first
        }

        /// The page a canvas quad belongs to, for both whole-page rasters and zoom tiles.
        func page(of index: Int) -> Int? {
            if PlacementIndex.isPageRaster(index) {
                // pageRaster(page) = -3·block - page, so undoing the encoding is a subtraction.
                return PlacementIndex.pageRaster(0) - index
            }
            if index >= 0 { return index >> 24 }
            return nil
        }

        let left = try makeReader(at: CGPoint(x: 24, y: 80))
        let right = try makeReader(at: CGPoint(x: 748, y: 80))
        defer {
            left.panels.close()
            right.panels.close()
            left.window.orderOut(nil)
            right.window.orderOut(nil)
        }

        // Side by side and both frontmost: a covered window is occluded to wgpu and never
        // presents, which would turn a real regression check into a timeout on any machine.
        left.window.makeKeyAndOrderFront(nil)
        right.window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        try await eventually("both hosted readers attach their canvas", {
            left.host.layoutSubtreeIfNeeded()
            right.host.layoutSubtreeIfNeeded()
            return canvas(in: left.host) != nil && canvas(in: right.host) != nil
        })
        guard let leftCanvas = canvas(in: left.host), let rightCanvas = canvas(in: right.host) else {
            fatalError("FAIL: missing Metal canvas in a hosted reader")
        }

        // The app's own start-up state, before any file is opened: each canvas must already have
        // presented the reading background with no quads. An uninitialised or stale drawable here
        // is the same defect, reached by the launch path instead of the close path.
        try await eventually("an unopened window presents a blank opening frame", {
            left.state.document == nil && right.state.document == nil
                && leftCanvas.submittedFrameCount > 0 && leftCanvas.lastSubmittedQuadCount == 0
                && rightCanvas.submittedFrameCount > 0 && rightCanvas.lastSubmittedQuadCount == 0
        })

        // The left window opens the three-page document, the right window the one-page one: after
        // the left closes and reopens a *different* document, any leftover page quad or cached
        // raster from the closed one would show up as a page the new document does not have.
        require(left.state.openDocumentInTab(b), "the first window opens its document")
        require(right.state.openDocumentInTab(a), "the second window opens its own document")
        try await eventually("each window's canvas presents the pages it opened", {
            (leftCanvas.lastSubmittedQuadCount ?? 0) > 0 && (rightCanvas.lastSubmittedQuadCount ?? 0) > 0
        })
        require(left.state.tabs.count == 1 && right.state.tabs.count == 1,
                "each window has exactly its own tab")

        // Put the closed document's *second* page on screen too, so the placement-index check
        // below has a page that only the old document had. This works for both raster paths:
        // a whole-page raster and zoom tiles encode the same page number.
        left.state.gotoPage(1)
        try await eventually("the closed document's second page rasterizes", {
            left.state.canvasPages.contains { page(of: $0.placement.index) == 1 }
        })
        let newestClosedGeneration = left.state.canvasPages.map(\.image.generation).max() ?? 0
        try await eventually("the closed document's second page frame presents", {
            (leftCanvas.lastSubmittedQuadCount ?? 0) > 0
        })

        // ── The regression: closing the last tab must present an empty frame ──────────────
        let framesBeforeClose = leftCanvas.submittedFrameCount
        left.state.closeTab(0)

        require(left.state.document == nil, "closing the last tab empties the window's document")
        require(left.state.canvasPages.isEmpty, "closing the last tab empties the canvas pages")
        try await eventually("closing the last tab hands the canvas no pages to draw", {
            leftCanvas.pages.isEmpty
        })
        try await eventually("closing the last tab presents a new frame with no page quads", {
            leftCanvas.submittedFrameCount > framesBeforeClose
                && leftCanvas.lastSubmittedQuadCount == 0
        })
        require(leftCanvas.lastSubmittedQuadCount == 0,
                "the frame presented after closing the last tab has no page quads")

        // In-flight rasters from the closed document must not repopulate anything afterwards.
        try await Task.sleep(for: .milliseconds(200))
        require(left.state.canvasPages.isEmpty && leftCanvas.pages.isEmpty,
                "no page returns to the canvas after the clear frame")
        require(left.state.tileCacheUsedBytes == 0 && left.state.tileCacheTileCount == 0
                && left.state.pinnedTiles.isEmpty,
                "the closed document's tile and placement caches are dropped")

        // ── Independence: the other window keeps its document and its picture ─────────────
        require(right.state.document?.url?.path == a.path,
                "closing a tab in one window leaves the other window's document alone")
        require(rightCanvas.pages.count > 0 && (rightCanvas.lastSubmittedQuadCount ?? 0) > 0,
                "the other window's canvas still paints its pages")
        try await eventually("the other window's canvas and model still agree", {
            right.state.canvasPages.count == rightCanvas.pages.count
                && !right.state.canvasPages.isEmpty
        })

        // ── The reverse direction: a new document presents, nothing old comes back ───────
        let framesAfterClear = leftCanvas.submittedFrameCount
        require(left.state.openDocumentInTab(a), "the cleared window opens another document")
        try await eventually("the reopened canvas presents the new first page", {
            leftCanvas.submittedFrameCount > framesAfterClear
                && (leftCanvas.lastSubmittedQuadCount ?? 0) > 0
                && !left.state.canvasPages.isEmpty
        })
        // Sidecar annotations loaded from the reopened file are legitimate quads of the *new*
        // document, not resurrected pages, so the cache assertions look only at page-bearing
        // quads (a whole-page raster or a zoom tile names the page it belongs to).
        let reopenedPageQuads = left.state.canvasPages.filter {
            page(of: $0.placement.index) != nil
        }
        require(!reopenedPageQuads.isEmpty, "the reopened canvas draws a page, not only overlays")
        require(reopenedPageQuads.allSatisfy { page(of: $0.placement.index) == 0 },
                "no page from the closed three-page document survives in the one-page reopen")
        require(reopenedPageQuads.allSatisfy { $0.image.generation > newestClosedGeneration },
                "every page quad in the reopened document is a fresh raster, not a cached one "
                    + "from the closed document")
        require(left.state.document?.url?.path == a.path,
                "the reopened window shows the document that was opened")

        // Opening a document that fails to load is the other path into "no document": it must
        // leave the window empty and the canvas clear, rather than revive the last drawable.
        let framesBeforeEmptyClose = leftCanvas.submittedFrameCount
        left.state.closeTab(0)
        try await eventually("closing the reopened tab clears the canvas again", {
            leftCanvas.submittedFrameCount > framesBeforeEmptyClose
                && leftCanvas.lastSubmittedQuadCount == 0
        })
        let missing = a.deletingLastPathComponent()
            .appendingPathComponent("missing-\(UUID()).pdf")
        require(!left.state.openDocumentInTab(missing),
                "opening a document that fails to load is rejected")
        require(left.state.document == nil && left.state.canvasPages.isEmpty,
                "a failed open with no document leaves the window empty")
        require(leftCanvas.lastSubmittedQuadCount == 0, "…and leaves the canvas clear")
    }
}
