import AppKit
import ArisReaderKit
import Combine
import Foundation
import SwiftUI

/// Checks for the interaction work: pointer-anchored zoom, and the floating preview panel.
///
/// Everything here is asserted as arithmetic or as AppKit state, never as a picture: the session
/// these run in has no usable display, and a screenshot would prove less than the numbers do.
extension ReaderChecks {
    // MARK: - Scroll events

    /// The y offset between an event's global display position and the window position AppKit
    /// hands back, measured once so the events below can aim at a point *inside* the view.
    ///
    /// AppKit converts a synthetic scroll event's location itself, and the conversion depends on
    /// the display attached to the session; a hard-coded location would put the pointer outside
    /// the canvas on some machines and make the anchoring assertion vacuous.
    @MainActor private static func displayHeightOffset() -> CGFloat {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                               wheel1: 1, wheel2: 0, wheel3: 0) else { return 900 }
        cg.location = .zero
        guard let event = NSEvent(cgEvent: cg) else { return 900 }
        // A global y of 0 reads back as the display height in window coordinates.
        let height = event.locationInWindow.y
        return height > 0 ? height : 900
    }

    /// Builds a scroll event the way AppKit delivers one, so the checks exercise the real
    /// `scrollWheel(with:)` path rather than a re-implementation of it.
    ///
    /// `precise: false` is a discrete wheel notch; `precise: true` is a trackpad. Both are
    /// available in a process that never posts an event — only posting needs permissions, and
    /// these are handed to the view directly.
    @MainActor private static func scrollEvent(
        wheel1: Int32,
        precise: Bool,
        modifiers: NSEvent.ModifierFlags,
        atViewPoint point: CGPoint,
        viewHeight: CGFloat,
        displayOffset: CGFloat
    ) -> NSEvent? {
        guard let cg = CGEvent(
            scrollWheelEvent2Source: nil,
            units: precise ? .pixel : .line,
            wheelCount: 1,
            wheel1: wheel1,
            wheel2: 0,
            wheel3: 0
        ) else { return nil }
        cg.location = CGPoint(x: point.x, y: displayOffset - point.y)
        if modifiers.contains(.control) { cg.flags.insert(.maskControl) }
        if modifiers.contains(.command) { cg.flags.insert(.maskCommand) }
        _ = viewHeight
        return NSEvent(cgEvent: cg)
    }

    /// The pointer in view space (top-left origin) exactly as the canvas reads it.
    @MainActor private static func anchorViewY(_ event: NSEvent, in view: MetalCanvasView) -> CGFloat {
        let point = view.convert(event.locationInWindow, from: nil)
        return view.bounds.height - point.y
    }

    // MARK: - Zoom

    /// Ctrl+scroll zooms, and the content point under the pointer stays under it.
    @MainActor static func pointerZoomChecks(url: URL) async throws {
        let state = AppState(engine: try RustEngine(), preferFullPageRasters: false)
        state.setViewportSize(CGSize(width: 700, height: 500))
        require(state.open(url: url), "zoom fixture opens")
        // Mid-document, so the anchored offset is not pinned by either end of the content.
        state.scroll(toFraction: 0.5)
        require(state.scrollYPt > 0, "zoom fixture starts away from the top of the document")

        let view = MetalCanvasView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        view.onScroll = { delta in state.scroll(byScreenPoints: delta) }
        view.onScrollStep = { delta in state.scrollByWheelStep(delta) }
        view.onKeyboardStep = { delta in state.scrollByKeyboardStep(delta) }
        view.onZoomScroll = { delta, anchor in
            state.zoomByScroll(delta: delta, anchorViewY: anchor)
        }
        view.interactionSnapshot = { (state.canvasPages, state.scrollYPt, state.zoomFactor) }

        let offset = displayHeightOffset()
        // An interior point of the canvas: 350 pt from the left, 250 pt down from its top.
        let pointer = CGPoint(x: 350, y: 250)
        func event(_ wheel: Int32, precise: Bool = false,
                   _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
            guard let event = scrollEvent(wheel1: wheel, precise: precise, modifiers: modifiers,
                                          atViewPoint: pointer, viewHeight: view.bounds.height,
                                          displayOffset: offset) else {
                fatalError("FAIL: a scroll event can be built")
            }
            return event
        }

        let plain = event(1, [])
        let control = event(1, [.control])
        let command = event(1, [.command])
        let controlOut = event(-1, [.control])
        require(control.modifierFlags.contains(.control) && control.scrollingDeltaY != 0,
                "the Ctrl+scroll event carries its modifier and its delta")
        let anchor = anchorViewY(control, in: view)
        require(anchor > 100 && anchor < 400,
                "the synthesized pointer lands inside the canvas (view y \(anchor))")

        // ── A plain wheel notch scrolls, and must not zoom ────────────────────────────────
        let zoomBeforePlain = state.zoomPercent
        let scrollBeforePlain = state.scrollYPt
        let pagesBeforePlain = state.canvasPages.map(\.placement.index)
        view.scrollWheel(with: plain)
        require(state.zoomPercent == zoomBeforePlain,
                "an ordinary scroll does not change the zoom")
        require(state.scrollYPt < scrollBeforePlain && state.scrollDestinationYPt == nil,
                "an ordinary wheel scroll moves immediately without queued motion")
        require(pagesBeforePlain == state.canvasPages.map(\.placement.index) || state.canvasPages.isEmpty,
                "an ordinary scroll keeps the same pages in the band")

        // ── Ctrl + the same notch zooms, anchored at the pointer ──────────────────────────
        let pagesBefore = state.canvasPages.map(\.placement.index)
        let contentYBefore = CanvasGeometry.contentY(
            viewY: anchor, scrollYPt: state.scrollYPt, zoom: state.zoomFactor
        )
        let zoomBefore = state.zoomPercent
        let scrollBefore = state.scrollYPt
        view.scrollWheel(with: control)
        require(state.zoomPercent > zoomBefore,
                "Ctrl+scroll zooms (was \(zoomBefore)%, now \(state.zoomPercent)%)")
        require(state.scrollYPt != scrollBefore,
                "the zoom moves the scroll offset to hold the anchor")
        let contentYAfter = CanvasGeometry.contentY(
            viewY: anchor, scrollYPt: state.scrollYPt, zoom: state.zoomFactor
        )
        require(abs(contentYAfter - contentYBefore) < 0.5,
                "the content point under the pointer is preserved "
                + "(\(contentYBefore) → \(contentYAfter) pt)")
        require(pagesBefore == state.canvasPages.map(\.placement.index),
                "the zoom keeps the same pages in the band (no page churn, no cleared canvas)")

        // ── ⌘+scroll is the same zoom, for the Accessibility conflict case ────────────────
        let zoomBeforeCommand = state.zoomPercent
        let contentYBeforeCommand = CanvasGeometry.contentY(
            viewY: anchor, scrollYPt: state.scrollYPt, zoom: state.zoomFactor
        )
        view.scrollWheel(with: command)
        require(state.zoomPercent > zoomBeforeCommand, "⌘+scroll zooms as well")
        require(abs(CanvasGeometry.contentY(viewY: anchor, scrollYPt: state.scrollYPt,
                                            zoom: state.zoomFactor) - contentYBeforeCommand) < 0.5,
                "⌘+scroll is anchored at the pointer too")

        // ── Pinch zooms through the same anchored path ────────────────────────────────────
        let zoomBeforePinch = state.zoomPercent
        let contentYBeforePinch = CanvasGeometry.contentY(
            viewY: anchor, scrollYPt: state.scrollYPt, zoom: state.zoomFactor
        )
        require(state.zoomByPinch(0.1, anchorViewY: anchor), "a pinch step zooms")
        require(state.zoomPercent == zoomBeforePinch + 10, "a 0.1 pinch is ten percent")
        require(abs(CanvasGeometry.contentY(viewY: anchor, scrollYPt: state.scrollYPt,
                                            zoom: state.zoomFactor) - contentYBeforePinch) < 0.5,
                "pinch keeps the pointer anchored as well")

        // ── Zooming out is anchored too ───────────────────────────────────────────────────
        let zoomBeforeOut = state.zoomPercent
        let contentYBeforeOut = CanvasGeometry.contentY(
            viewY: anchor, scrollYPt: state.scrollYPt, zoom: state.zoomFactor
        )
        view.scrollWheel(with: controlOut)
        require(state.zoomPercent < zoomBeforeOut, "Ctrl+scrolling the other way zooms out")
        require(abs(CanvasGeometry.contentY(viewY: anchor, scrollYPt: state.scrollYPt,
                                            zoom: state.zoomFactor) - contentYBeforeOut) < 0.5,
                "zooming out is anchored at the pointer as well")

        // ── A trackpad's precise deltas accumulate instead of being dropped ───────────────
        let trackpadZoom = state.zoomPercent
        for _ in 0..<4 { view.scrollWheel(with: event(2, precise: true, [.control])) }
        require(state.zoomPercent != trackpadZoom,
                "a slow precise Ctrl+scroll still moves the zoom (sub-percent deltas accumulate)")

        // ── The limits are the toolbar's, and scrolling past them does not overshoot ──────
        for _ in 0..<8 { view.scrollWheel(with: event(40, [.control])) }
        require(state.zoomPercent == AppState.maximumZoomPercent,
                "Ctrl+scroll stops at the maximum zoom (\(state.zoomPercent)%)")
        for _ in 0..<16 { view.scrollWheel(with: event(-40, [.control])) }
        require(state.zoomPercent == AppState.minimumZoomPercent,
                "Ctrl+scroll stops at the minimum zoom (\(state.zoomPercent)%)")
        state.zoomActual()

        // ── The zoom went through the ordinary path ───────────────────────────────────────
        try await eventually("the zoomed band still rasterizes through the normal scheduler", {
            !state.canvasPages.isEmpty
        })
        require(state.zoomPercent == 100, "the toolbar zoom still owns the same integer zoom")
        print("PASS: pointer-anchored zoom (Ctrl, ⌘ and pinch) leaves the plain scroll path alone")
    }

    // MARK: - Panel geometry

    /// The panel is movable by its background, resizable only within its limits, and placed
    /// against the anchor rather than in a corner.
    @MainActor static func previewPanelChecks() throws {
        _ = NSApplication.shared
        // A 1440×900 screen at the origin, so the arithmetic below is readable.
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

        // ── Limits ────────────────────────────────────────────────────────────────────────
        require(PreviewPanelGeometry.clampSize(CGSize(width: 10, height: 10), onScreen: screen)
                    == PreviewPanelGeometry.minimumSize,
                "a resize below the minimum is clamped up to 320×240")
        require(PreviewPanelGeometry.clampSize(CGSize(width: 5000, height: 5000), onScreen: screen)
                    == PreviewPanelGeometry.maximumSize(onScreen: screen),
                "a resize above the maximum is clamped to 80% of the screen")
        require(abs(PreviewPanelGeometry.maximumSize(onScreen: screen).width - 1152) < 0.01,
                "the maximum is 80% of the screen's width")

        // ── Anchored opening: below the anchor, flipping above when there is no room ──────
        let anchor = CGRect(x: 400, y: 500, width: 60, height: 12)
        let below = PreviewPanelGeometry.anchoredFrame(
            size: PreviewPanelGeometry.defaultSize, anchor: anchor, onScreen: screen
        )
        require(abs(below.maxY - (anchor.minY - PreviewPanelGeometry.anchorGap)) < 0.01,
                "the panel opens below the anchor, \(PreviewPanelGeometry.anchorGap) pt away")
        require(abs(below.minX - anchor.minX) < 0.01, "the panel's left edge lines up with the anchor")

        let lowAnchor = CGRect(x: 400, y: 20, width: 60, height: 12)
        let flipped = PreviewPanelGeometry.anchoredFrame(
            size: PreviewPanelGeometry.defaultSize, anchor: lowAnchor, onScreen: screen
        )
        require(abs(flipped.minY - (lowAnchor.maxY + PreviewPanelGeometry.anchorGap)) < 0.01,
                "an anchor with no room below flips the panel above it")
        require(screen.contains(flipped), "the flipped panel is still on screen")

        let edgeAnchor = CGRect(x: 2, y: 500, width: 12, height: 12)
        let atEdge = PreviewPanelGeometry.anchoredFrame(
            size: PreviewPanelGeometry.defaultSize, anchor: edgeAnchor, onScreen: screen
        )
        require(abs(atEdge.minX - (screen.minX + PreviewPanelGeometry.edgeMargin)) < 0.01,
                "an anchor at the screen edge opens the panel inset by the margin")

        // ── Staying on screen when dragged to an edge ─────────────────────────────────────
        let offRight = CGRect(x: 5000, y: -400, width: 480, height: 360)
        let confined = PreviewPanelGeometry.confinedFrame(offRight, onScreen: screen)
        require(screen.contains(confined) && confined.size == offRight.size,
                "a panel dragged past the corner is pulled back on screen at its own size")

        // ── Resizing from the corner keeps the top-left and honours the limits ────────────
        let start = PreviewPanelGeometry.confinedFrame(
            CGRect(x: 600, y: 300, width: 480, height: 360), onScreen: screen
        )
        let grown = PreviewPanelGeometry.resizedByBottomRight(
            start, by: CGVector(dx: 120, dy: -80), onScreen: screen
        )
        require(abs(grown.maxX - (start.maxX + 120)) < 0.01
                    && abs(grown.minY - (start.minY - 80)) < 0.01,
                "dragging the corner grows the panel by the drag")
        require(abs(grown.maxY - start.maxY) < 0.01 && abs(grown.minX - start.minX) < 0.01,
                "the opposite corner stays put while resizing")
        require(PreviewPanelGeometry.resizedByBottomRight(
            start, by: CGVector(dx: -5000, dy: 5000), onScreen: screen).size
                    == PreviewPanelGeometry.minimumSize,
                "dragging the corner past the minimum stops at 320×240")
        require(PreviewPanelGeometry.resizedByBottomRight(
            start, by: CGVector(dx: 5000, dy: -5000), onScreen: screen).size
                    == PreviewPanelGeometry.maximumSize(onScreen: screen),
                "dragging the corner past the maximum stops at the screen fraction")

        // ── The real panel carries those rules ────────────────────────────────────────────
        let panel = ReferencePreviewPanel(screen: screen)
        defer { panel.orderOut(nil) }
        require(panel.styleMask.contains(.borderless) && !panel.styleMask.contains(.titled),
                "the preview panel is borderless (no title bar)")
        require(panel.isMovableByWindowBackground,
                "the preview panel is movable by its background")
        require(panel.minSize == PreviewPanelGeometry.minimumSize
                    && panel.maxSize == PreviewPanelGeometry.maximumSize(onScreen: screen),
                "the panel's own size limits are the geometry's limits")
        require(panel.windowWillResize(panel, to: NSSize(width: 1, height: 1))
                    == PreviewPanelGeometry.minimumSize,
                "an interactive resize is clamped to the minimum")
        require(panel.windowWillResize(panel, to: NSSize(width: 9000, height: 9000))
                    == PreviewPanelGeometry.maximumSize(onScreen: screen),
                "an interactive resize is clamped to the maximum")

        let hosting = NSHostingView(rootView: Color.clear.frame(width: 400, height: 300))
        hosting.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        panel.contentView = hosting
        panel.applyProgrammaticFrame(CGRect(x: 100, y: 100, width: 400, height: 300))
        hosting.layoutSubtreeIfNeeded()
        let hit = hosting.hitTest(CGPoint(x: 200, y: 150))
        require(hit?.mouseDownCanMoveWindow == true,
                "AppKit is told a drag on the panel's background moves the window")

        // A placement the controller makes is not a reader adjustment...
        var reported: CGRect?
        panel.onUserFrameChange = { reported = $0 }
        panel.applyProgrammaticFrame(CGRect(x: 120, y: 140, width: 520, height: 400))
        require(reported == nil, "a placement the controller makes is not a reader adjustment")
        // ...while a frame the reader produced is reported exactly once, as-is.
        panel.applyUserFrame(CGRect(x: 200, y: 220, width: 560, height: 420))
        require(reported?.origin == CGPoint(x: 200, y: 220),
                "the reader's frame is reported as-is")
        print("PASS: the preview panel is borderless, background-draggable and clamped to its limits")
    }

    // MARK: - Panel behaviour

    /// New reference previews fit their own content; manual changes last for one preview.
    @MainActor static func previewPanelSessionChecks(url: URL) async throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let controller = ReferencePreviewPanelController.shared
        controller.close()

        let state = AppState(engine: PreviewEngine())
        require(state.open(url: url), "panel fixture opens")

        let longText = String(repeating: "A very long bibliography entry. ", count: 40)
        let entries = [
            AppState.CitationEntry(label: "7", text: longText, page: 0),
            AppState.CitationEntry(label: "8", text: "A short second work.", page: 1),
        ]
        // The canvas sits in the lower half of the screen; the click is 300 pt down its own
        // height, so the anchor is at screen y = 400 + (600 - 312) = 688.
        let canvas = CGRect(x: 100, y: 400, width: 900, height: 600)
        let click = CGRect(x: 200, y: 300, width: 40, height: 12)
        state.openReferencePreview(page: 0, title: "[7,8]", from: "page 1", kind: .reference,
                                   anchor: click, entries: entries)
        require(!state.referencePreviewLoading && state.referencePreviewPages.isEmpty,
                "a reference preview renders no page image at all")
        controller.sync(state: state, canvasOnScreen: canvas, canvasHeightPt: canvas.height,
                        screen: screen)

        guard let panel = controller.panel else { fatalError("FAIL: the preview opens a panel") }
        require(controller.rememberedFrame == nil && !controller.userAdjustedFrame,
                "an untried panel has no frame of its own yet")
        require(screen.contains(panel.frame), "the panel opens inside the screen")
        require(panel.frame.width == PreviewPanelGeometry.defaultSize.width,
                "the panel opens at its default width")
        let fittedHeight = PreviewPanelGeometry.clampSize(
            CGSize(width: panel.frame.width, height: controller.model.fullContentHeight(panelWidthPt: panel.frame.width)),
            onScreen: screen).height
        require(abs(panel.frame.height - fittedHeight) < 1,
                "the panel fits the full long citation up to its screen limit")
        require(panel.frame.height >= PreviewPanelGeometry.minimumSize.height
                    && panel.frame.height <= PreviewPanelGeometry.maximumSize(onScreen: screen).height,
                "the panel's height is inside its limits")

        // The reader drags it somewhere else; that frame is the session's from then on.
        let moved = CGRect(x: 60, y: 90, width: 520, height: 320)
        panel.applyUserFrame(moved)
        require(controller.userAdjustedFrame && controller.rememberedFrame == moved,
                "a frame the reader produced is remembered")
        require(panel.frame == moved, "the panel is where the reader put it")
        controller.close()
        require(controller.panel == nil, "closing the preview closes the panel")
        require(controller.rememberedFrame == nil && !controller.userAdjustedFrame,
                "closing forgets the manual size so the next preview fits its own content")

        state.openReferencePreview(page: 1, title: "[8]", from: "page 2", kind: .reference,
                                   entries: [entries[1]])
        controller.sync(state: state, canvasOnScreen: canvas, canvasHeightPt: canvas.height,
                        screen: screen)
        require(controller.panel?.frame != moved && controller.panel?.frame.height == PreviewPanelGeometry.minimumSize.height,
                "a short new preview automatically shrinks after a manually resized long preview")

        // A frame dragged clean off the screen comes back.
        controller.panel?.applyUserFrame(CGRect(x: 9000, y: 9000, width: 520, height: 320))
        guard let parked = controller.panel?.frame else { fatalError("FAIL: the panel is there") }
        require(screen.contains(parked), "a panel dragged off the screen is pulled back on")

        // A figure preview keeps its image: the reference path is the only one that shows text.
        controller.close()
        state.openReferencePreview(page: 0, title: "Figure 1", from: "page 1", kind: .figure,
                                   region: CGRect(x: 0, y: 0, width: 300, height: 200),
                                   entries: [AppState.CitationEntry(label: "Figure 1",
                                                                    text: "A caption.")])
        try await eventually("a figure preview still rasterizes its region", {
            !state.referencePreviewPages.isEmpty && !state.referencePreviewLoading
        })
        require(state.referencePreview?.kind == .figure, "the figure preview keeps its own kind")

        // The figure panel hosts a second Metal canvas, in its own window. A display-less session
        // cannot present a frame, but it can say whether the canvas reached the GPU at all: a
        // surface that never attaches is the failure mode worth catching here.
        controller.sync(state: state, canvasOnScreen: canvas, canvasHeightPt: canvas.height,
                        screen: screen)
        if let hosted = firstCanvasView(controller.panel?.contentView) {
            require(hosted.hasAttachedSurface || hosted.submittedFrameCount > 0,
                    "the figure preview's canvas attaches a Metal surface inside the panel")
            require(hosted.canvasClearColor === LyraTheme.raisedBgColor,
                    "the figure preview clears to the panel colour behind transparent paper")
        } else {
            print("NOTE: the panel's canvas had not materialised in this environment; "
                  + "the second surface inside the panel is unverified here")
        }
        state.closeReferencePreview()
        controller.close()
    }

    // MARK: - Smooth scrolling

    /// Trackpad precision and keyboard animation remain independent of the immediate wheel path.
    @MainActor static func smoothScrollChecks(url: URL) async throws {
        let state = AppState(engine: try RustEngine(), preferFullPageRasters: false)
        state.setViewportSize(CGSize(width: 700, height: 500))
        require(state.open(url: url), "scroll fixture opens")
        state.scroll(toFraction: 0.35)
        let base = state.scrollYPt
        state.scroll(byScreenPoints: 7.25)
        state.scroll(byScreenPoints: 3.5)
        require(abs(state.scrollYPt - base - 10.75) < 1e-9 && state.scrollDestinationYPt == nil,
                "precise deltas keep their fractional distances without animation")
        let view = MetalCanvasView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        view.onScrollStep = { state.scrollByWheelStep($0) }
        view.onKeyboardStep = { state.scrollByKeyboardStep($0) }
        let beforeKey = state.scrollYPt
        view.keyDown(with: keyEvent("\u{F72D}"))
        require(state.scrollYPt == beforeKey && state.scrollDestinationYPt == beforeKey + 450,
                "Page Down still animates to a full page destination")
        try await eventually("keyboard navigation reaches its destination", {
            state.scrollDestinationYPt == nil && abs(state.scrollYPt - beforeKey - 450) < 1e-6
        })
        view.keyDown(with: keyEvent("\u{F72C}"))
        require(state.scrollDestinationYPt != nil, "Page Up starts its animation")
        state.scrollByWheelStep(40)
        let parked = state.scrollYPt
        require(state.scrollDestinationYPt == nil, "wheel input cancels a keyboard animation")
        try await Task.sleep(for: .milliseconds(150))
        require(state.scrollYPt == parked, "a canceled keyboard driver cannot move the document later")
    }

    /// The glide's own arithmetic, independent of any document or timer.
    @MainActor static func scrollGlideChecks() throws {
        var glide = ScrollGlide()
        require(!glide.isActive && glide.destination == nil, "a new glide is not moving")
        glide.aim(at: 100)
        require(glide.isActive && glide.destination == 100, "aiming starts it")
        var offset: CGFloat = 0
        var steps = 0
        var monotonic = true
        while steps < 1000 {
            let (next, finished) = glide.step(from: offset, elapsed: 0.008)
            monotonic = monotonic && next >= offset && next <= 100
            offset = next
            steps += 1
            if finished { break }
        }
        require(monotonic, "the glide is monotonic and never overshoots")
        require(offset == 100, "the glide lands exactly on its destination")
        require(steps > 4, "it takes several ticks to get there (\(steps))")
        glide.cancel()
        require(!glide.isActive, "cancelling stops it")
        require(glide.step(from: 40, elapsed: 0.008).offset == 40,
                "a cancelled glide does not move the offset")

        // A big target is speed-limited at the start and eased at the end.
        glide.aim(at: -1000)
        let (first, firstDone) = glide.step(from: 0, elapsed: 0.008)
        require(!firstDone && abs(first) <= ScrollGlide.defaultMaximumSpeed * 0.008 + 1e-6,
                "the first tick of a long glide is speed-limited (\(first) pt)")
        let (idle, _) = glide.step(from: 0, elapsed: 0)
        require(idle == 0, "a zero-length tick moves nothing")
        // A tick that arrives late while the notches are still coming must not swallow the glide:
        // a long tick counts as one frame of the ceiling and the rest arrives on later ticks.
        // Aimed without a lead: this case is about a stalled tick, not about the bound
        // (`ScrollTailChecks` and `smoothScrollChecks` pin that), so the whole 1000 pt is owed.
        glide.aim(at: -1000, from: 0, mostAhead: nil, maximumSpeed: 1_000_000)
        let (stalled, stalledDone) = glide.step(from: 0, elapsed: 0.04)
        let stalledCeiling = 1_000_000 * ScrollGlide.maximumStepTime
        require(!stalledDone && abs(stalled) <= stalledCeiling + 1e-6,
                "a stalled tick moves at most one frame of its ceiling (\(stalled) pt of "
                + "\(stalledCeiling), not the whole 1000)")
        var catchingUp = stalled
        for _ in 0..<200 {
            let (next, finished) = glide.step(from: catchingUp, elapsed: 0.04)
            catchingUp = next
            if finished { break }
        }
        require(catchingUp == -1000, "and the glide still lands on its destination")
        glide.cancel()

        // Once the wheel has stopped, the distance still owed is finished rather than eased into -
        // that is what removes the tail the reader reported - but still one frame of the speed
        // ceiling at a time, so even a 10 s tick lengthens the finish instead of jumping it. A CI
        // runner ran the driver's 8 ms ticks 40 ms late and published a 96 pt glide as three
        // offsets; `ScrollTailChecks` pins that case on a simulated clock.
        glide.aim(at: -1000, from: 0, mostAhead: nil)
        var finishing: CGFloat = -300
        var largestFinishStep: CGFloat = 0
        var finishTicks = 0
        while finishTicks < 500 {
            let (next, done) = glide.step(from: finishing, elapsed: 10)
            largestFinishStep = max(largestFinishStep, abs(next - finishing))
            finishing = next
            finishTicks += 1
            if done { break }
        }
        require(finishing == -1000, "a glide whose wheel has stopped still lands exactly")
        let frame = ScrollGlide.defaultMaximumSpeed * CGFloat(ScrollGlide.maximumStepTime)
        require(largestFinishStep <= frame + 1e-6,
                "and a 10 s tick moves one frame of the speed ceiling, not the whole 700 pt "
                + "(\(largestFinishStep) pt of \(frame) pt per tick, \(finishTicks) ticks)")

        // The ceiling is per aim, so a zoomed-in canvas glides at screen speed, not content speed.
        glide.aim(at: 100, maximumSpeed: 500)
        let (zoomed, _) = glide.step(from: 0, elapsed: 0.008)
        require(abs(zoomed) <= 500 * 0.008 + 1e-6, "the speed ceiling is the one that was aimed")
        print("PASS: the glide is monotonic, speed-limited, overshoot-free and lands exactly")
    }

    /// The first `MetalCanvasView` in a view tree, if SwiftUI has materialised one.
    @MainActor private static func firstCanvasView(_ view: NSView?) -> MetalCanvasView? {
        guard let view else { return nil }
        if let canvas = view as? MetalCanvasView { return canvas }
        for subview in view.subviews {
            if let found = firstCanvasView(subview) { return found }
        }
        return nil
    }

    @MainActor private static func keyEvent(_ characters: String) -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           characters: characters,
                                           charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: 121) else {
            fatalError("FAIL: a key event can be built")
        }
        return event
    }

    // MARK: - Reference entry text
    /// Full entries stay intact, and their measured height controls sizing and scrolling.
    @MainActor static func referenceEntryTextChecks() throws {
        let model = ReferencePreviewModel()
        let short = AppState.CitationEntry(label: "1", text: "An ordinary citation.", page: 1)
        let long = AppState.CitationEntry(label: "2", text: String(repeating: "A complete bibliography entry. ", count: 200), page: 2)
        model.update(entries: [short])
        let shortHeight = model.fullContentHeight(panelWidthPt: 520)
        model.update(entries: [short, long])
        require(model.entries.map(\.text) == [short.text, long.text],
                "all citation entries preserve their full text without truncation")
        require(model.entries.map(\.citationEntry) == [short, long],
                "title headings retain original entry destinations and text")
        let height = model.fullContentHeight(panelWidthPt: 520)
        require(height > shortHeight, "long citations increase the automatic content height")
        require(model.fullContentHeight(panelWidthPt: 320) > height,
                "citation height accounts for wrapping when the column gets narrower")
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        require(height > PreviewPanelGeometry.maximumSize(onScreen: screen).height,
                "a very long citation exceeds the allowed window height")
        require(PreviewPanelGeometry.clampSize(CGSize(width: 520, height: height), onScreen: screen).height
                    == PreviewPanelGeometry.maximumSize(onScreen: screen).height,
                "large citations stop at the screen limit and use scrolling")
    }
}
