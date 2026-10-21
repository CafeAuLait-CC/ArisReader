import AppKit
import LyraReaderKit
import SwiftUI

extension ReaderChecks {
    /// Regression for the reader's report: after the last tab closed, the previous page was still
    /// painted on the Metal canvas, with the empty state ("Open a paper to start reading" and its
    /// "Open PDF…" button) drawn over the middle of it.
    ///
    /// The model was already empty — the bug was in the frame path. `MetalCanvasView` returned
    /// before submitting a frame when there were no page quads, so no new drawable was presented
    /// and the `CAMetalLayer` kept showing the closed document. These checks therefore assert the
    /// **frame**, not just the model: after the last tab closes, a new frame must be submitted
    /// with zero page quads. Waiting only for `canvasPages.isEmpty` would have passed on the
    /// broken build, which is exactly why the regression needs this observable.
    ///
    /// Presentation and submission are deliberately separate observables. wgpu refuses to draw
    /// into a window the WindowServer marks as occluded (covered by another app, a full-screen
    /// Space, a sleeping display), so on some machines — including an otherwise idle developer
    /// desk — a healthy canvas may never present. Submission still happens, and submitting the
    /// blank frame is what replaces a stale drawable; requiring *presentation* at start-up made
    /// this check dependent on whatever the person running the suite had in front of the reader.
    /// The checks therefore require the submission everywhere, and additionally require the
    /// presented frame wherever the window is visible. Because the empty window now shows the
    /// opaque Home surface, an unopened canvas has no stale drawable to hide in the first place;
    /// the submission requirement is what keeps the clear-frame path itself under test.
    @MainActor static func canvasClearChecks(a sourceA: URL, b sourceB: URL) async throws {
        // This check starts with pristine documents. Earlier interaction checks deliberately
        // leave recoverable rotations in the cache; reopening those paths would correctly
        // request Save before close and would no longer exercise an empty-tab close.
        let fixtures = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-canvas-clear-\(UUID())")
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtures) }
        let a = fixtures.appendingPathComponent("a.pdf")
        let b = fixtures.appendingPathComponent("b.pdf")
        try FileManager.default.copyItem(at: sourceA, to: a)
        try FileManager.default.copyItem(at: sourceB, to: b)
        _ = NSApplication.shared

        /// One reader window built the way the app builds it: the real `ReaderWindow`, so
        /// `PDFCanvasView.updateNSView` hands `AppState.canvasPages` to the real `MetalCanvasView`
        /// and the empty state is the production Home surface.
        func makeReader(at origin: CGPoint) throws -> (
            state: AppState,
            host: NSHostingView<ReaderWindow>,
            window: NSWindow,
            panels: ReferencePreviewPanelController
        ) {
            let state = AppState(engine: try RustEngine())
            state.setViewportSize(CGSize(width: 900, height: 500))
            let panels = ReferencePreviewPanelController()
            let host = NSHostingView(rootView: ReaderWindow(
                state: state,
                opener: DocumentOpenCoordinator(state: state),
                previewPanels: panels))
            // ReaderWindow's own minimum is 900×600. Ask for it explicitly instead of relying on
            // NSHostingView growing a 700×520 window after it has already laid the canvas out:
            // the canvas must be measured at the size the product uses.
            let window = NSWindow(
                contentRect: CGRect(x: origin.x, y: origin.y, width: 900, height: 600),
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
        // Far enough right that the two 900 pt windows cannot overlap, so the key window can
        // never be fully covering the other one.
        let right = try makeReader(at: CGPoint(x: 960, y: 80))
        defer {
            left.panels.close()
            right.panels.close()
            left.window.orderOut(nil)
            right.window.orderOut(nil)
        }

        // Side by side and both frontmost. The order-front call does not depend on the harness
        // being the active application (an unbundled executable cannot always activate); if the
        // WindowServer still reports a window occluded, the waits below accept a submitted frame
        // and report the occlusion instead of turning into a mystery timeout.
        left.window.makeKeyAndOrderFront(nil)
        right.window.makeKeyAndOrderFront(nil)
        left.window.orderFrontRegardless()
        right.window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)

        /// Everything a timeout needs to name the window that did not do what was expected:
        /// frame, on-screen/occlusion state, whether the Metal surface is attached, and both the
        /// submitted (presented) and attempted frame counters.
        func windowReport() -> String {
            func describe(
                _ label: String,
                state: AppState,
                window: NSWindow,
                metalCanvas: MetalCanvasView?
            ) -> String {
                let frame = NSStringFromRect(window.frame)
                let screen = window.screen.map { NSStringFromRect($0.visibleFrame) } ?? "none"
                let canvasText: String
                if let metalCanvas {
                    let attempted = metalCanvas.lastAttemptedQuadCount
                        .map { String($0) } ?? "nil"
                    let presented = metalCanvas.lastSubmittedQuadCount
                        .map { String($0) } ?? "nil"
                    canvasText = "surfaceAttached=\(metalCanvas.hasAttachedSurface) "
                        + "attempts=\(metalCanvas.frameAttemptCount) "
                        + "lastAttemptQuads=\(attempted) "
                        + "submitted=\(metalCanvas.submittedFrameCount) "
                        + "lastPresentedQuads=\(presented) "
                        + "canvasPages=\(metalCanvas.pages.count)"
                } else {
                    canvasText = "canvas=missing"
                }
                return "[\(label)] frame=\(frame) screen=\(screen) "
                    + "isVisible=\(window.isVisible) onActiveSpace=\(window.isOnActiveSpace) "
                    + "occlusion=\(window.occlusionState.rawValue) "
                    + "occlusionVisible=\(window.occlusionState.contains(.visible)) "
                    + "document=\(state.document != nil) modelPages=\(state.canvasPages.count) "
                    + canvasText
            }
            let app = NSApplication.shared
            return describe("left", state: left.state, window: left.window,
                            metalCanvas: canvas(in: left.host))
                + "\n" + describe("right", state: right.state, window: right.window,
                                  metalCanvas: canvas(in: right.host))
                + "\napp active=\(app.isActive) policy=\(app.activationPolicy().rawValue) "
                + "frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")"
        }

        /// The surface is attached before any frame can be expected. The previous wait only found
        /// the view; a layout that never mounted a GPU surface would then present a timeout with
        /// no explanation.
        try await eventuallyExplaining(
            "both hosted readers mount their Metal surface",
            windowReport
        ) {
            left.host.layoutSubtreeIfNeeded()
            right.host.layoutSubtreeIfNeeded()
            guard let leftCanvas = canvas(in: left.host),
                  let rightCanvas = canvas(in: right.host) else { return false }
            return leftCanvas.hasAttachedSurface && rightCanvas.hasAttachedSurface
        }
        guard let leftCanvas = canvas(in: left.host), let rightCanvas = canvas(in: right.host) else {
            fatalError("FAIL: missing Metal canvas in a hosted reader\n\(windowReport())")
        }

        /// A frame with page quads reached the screen, or — when the WindowServer says the
        /// window is occluded and nothing can present — was at least submitted to the engine.
        func pageFrameObserved(_ canvas: MetalCanvasView, window: NSWindow) -> Bool {
            if window.occlusionState.contains(.visible) {
                return canvas.submittedFrameCount > 0
                    && (canvas.lastSubmittedQuadCount ?? 0) > 0
            }
            return canvas.frameAttemptCount > 0
                && (canvas.lastAttemptedQuadCount ?? 0) > 0
        }

        /// The canvas was submitted in its empty state, and presented that way when the window
        /// allows presentation. The attempted frame is what matters: it is the clear that
        /// replaces a stale drawable. `lastSubmittedQuadCount` may be `nil` (never presented).
        func blankCanvasObserved(_ canvas: MetalCanvasView, window: NSWindow) -> Bool {
            guard canvas.hasAttachedSurface,
                  canvas.frameAttemptCount > 0,
                  canvas.lastAttemptedQuadCount == 0,
                  (canvas.lastSubmittedQuadCount ?? 0) == 0 else { return false }
            if window.occlusionState.contains(.visible) {
                return canvas.submittedFrameCount > 0 && canvas.lastSubmittedQuadCount == 0
            }
            return true
        }

        /// A clearing frame was submitted after the document emptied, and presented when the
        /// window allows it. `attemptsBefore`/`presentedBefore` are sampled before the change.
        func clearFrameObserved(
            _ canvas: MetalCanvasView,
            window: NSWindow,
            attemptsBefore: UInt64,
            presentedBefore: UInt64
        ) -> Bool {
            guard canvas.frameAttemptCount > attemptsBefore,
                  canvas.lastAttemptedQuadCount == 0 else { return false }
            if window.occlusionState.contains(.visible) {
                return canvas.submittedFrameCount > presentedBefore
                    && canvas.lastSubmittedQuadCount == 0
            }
            return true
        }

        // The app's own start-up state, before any file is opened: Home is on screen (the opaque
        // surface above the canvas), no canvas has a page quad, and each canvas has submitted the
        // background-only frame. The last requirement is the launch-path half of the same defect
        // the close path covers; presentation is additionally required when observable.
        try await eventuallyExplaining(
            "an unopened window shows Home with no page quads drawn",
            windowReport
        ) {
            left.state.document == nil && right.state.document == nil
                && left.state.canvasPages.isEmpty && right.state.canvasPages.isEmpty
                && leftCanvas.pages.isEmpty && rightCanvas.pages.isEmpty
                && blankCanvasObserved(leftCanvas, window: left.window)
                && blankCanvasObserved(rightCanvas, window: right.window)
        }

        // The left window opens the three-page document, the right window the one-page one: after
        // the left closes and reopens a *different* document, any leftover page quad or cached
        // raster from the closed one would show up as a page the new document does not have.
        require(left.state.openDocumentInTab(b), "the first window opens its document")
        require(right.state.openDocumentInTab(a), "the second window opens its own document")
        try await eventuallyExplaining(
            "each window's canvas draws the pages it opened",
            windowReport
        ) {
            pageFrameObserved(leftCanvas, window: left.window)
                && pageFrameObserved(rightCanvas, window: right.window)
        }
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
        try await eventuallyExplaining(
            "the closed document's second page frame is drawn",
            windowReport
        ) {
            pageFrameObserved(leftCanvas, window: left.window)
        }

        // ── The regression: closing the last tab must submit an empty frame ──────────────
        let framesBeforeClose = leftCanvas.submittedFrameCount
        let attemptsBeforeClose = leftCanvas.frameAttemptCount
        left.state.closeTab(0)

        require(left.state.document == nil, "closing the last tab empties the window's document")
        require(left.state.canvasPages.isEmpty, "closing the last tab empties the canvas pages")
        try await eventually("closing the last tab hands the canvas no pages to draw", {
            leftCanvas.pages.isEmpty
        })
        // Capture which branch satisfied the wait. Re-reading the visibility afterwards would
        // race the WindowServer: a window that became visible after an occluded wait would still
        // be showing the pre-close drawable until its retry lands.
        var closeFrameWasPresented = false
        try await eventuallyExplaining(
            "closing the last tab submits a new frame with no page quads",
            windowReport
        ) {
            guard clearFrameObserved(
                leftCanvas,
                window: left.window,
                attemptsBefore: attemptsBeforeClose,
                presentedBefore: framesBeforeClose) else { return false }
            closeFrameWasPresented = left.window.occlusionState.contains(.visible)
            return true
        }
        require(leftCanvas.lastAttemptedQuadCount == 0,
                "the frame submitted after closing the last tab has no page quads")
        if closeFrameWasPresented {
            require(leftCanvas.lastSubmittedQuadCount == 0,
                    "the frame presented after closing the last tab has no page quads")
        } else {
            print("NOTE: the left window is occluded; the clear frame was submitted but cannot "
                + "be presented here. \(windowReport())")
        }

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
        require(rightCanvas.pages.count > 0
                    && pageFrameObserved(rightCanvas, window: right.window),
                "the other window's canvas still paints its pages")
        try await eventually("the other window's canvas and model still agree", {
            right.state.canvasPages.count == rightCanvas.pages.count
                && !right.state.canvasPages.isEmpty
        })

        // ── The reverse direction: a new document presents, nothing old comes back ───────
        let framesAfterClear = leftCanvas.submittedFrameCount
        let attemptsAfterClear = leftCanvas.frameAttemptCount
        require(left.state.openDocumentInTab(a), "the cleared window opens another document")
        try await eventuallyExplaining(
            "the reopened canvas draws the new first page",
            windowReport
        ) {
            guard !left.state.canvasPages.isEmpty else { return false }
            if left.window.occlusionState.contains(.visible) {
                return leftCanvas.submittedFrameCount > framesAfterClear
                    && (leftCanvas.lastSubmittedQuadCount ?? 0) > 0
            }
            return leftCanvas.frameAttemptCount > attemptsAfterClear
                && (leftCanvas.lastAttemptedQuadCount ?? 0) > 0
        }
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
        let attemptsBeforeEmptyClose = leftCanvas.frameAttemptCount
        left.state.closeTab(0)
        try await eventuallyExplaining(
            "closing the reopened tab clears the canvas again",
            windowReport
        ) {
            clearFrameObserved(
                leftCanvas,
                window: left.window,
                attemptsBefore: attemptsBeforeEmptyClose,
                presentedBefore: framesBeforeEmptyClose)
        }
        let missing = a.deletingLastPathComponent()
            .appendingPathComponent("missing-\(UUID()).pdf")
        require(!left.state.openDocumentInTab(missing),
                "opening a document that fails to load is rejected")
        require(left.state.document == nil && left.state.canvasPages.isEmpty,
                "a failed open with no document leaves the window empty")
        // The presentation half was already required by the clearing-frame wait above whenever
        // the window was visible; here the submission is the stable observable.
        require(leftCanvas.lastAttemptedQuadCount == 0,
                "…and the canvas keeps submitting no page quads")
    }
}
