import AppKit
import LyraReaderKit
import SwiftUI

/// Show/hide transitions for the sidebar and the secondary toolbar row.
///
/// The hosted-window assertions measure the real AppKit frames SwiftUI produces, not a model of
/// them. The canvas is a child `NSView`, so its width says how much of the window the sidebar is
/// taking, and its height / origin say whether the toolbar row pushed it. The hit tests use
/// `NSHostingView.hitTest`, the same AppKit path `HostedPreviewChecks` uses to prove that a click
/// reaches the Metal canvas through SwiftUI, with the point converted into the hosting view's
/// superview coordinates - the space `NSView.hitTest` documents.
@MainActor
private final class TransitionHarness {
    let state: AppState
    let host: NSHostingView<ReaderWindow>
    let window: NSWindow
    private(set) var canvas: MetalCanvasView!

    init(state: AppState) {
        self.state = state
        self.host = NSHostingView(rootView: ReaderWindow(
            state: state, opener: DocumentOpenCoordinator(state: state)))
        self.window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1100, height: 750),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
    }

    func mount() async throws {
        window.orderFrontRegardless()
        try await ReaderChecks.eventually("the hosted reader lays out its canvas", {
            self.host.layoutSubtreeIfNeeded()
            self.canvas = self.findCanvas(in: self.host)
            return self.canvas != nil
        })
        host.layoutSubtreeIfNeeded()
    }

    func close() {
        window.orderOut(nil)
    }

    private func findCanvas(in view: NSView) -> MetalCanvasView? {
        if let found = view as? MetalCanvasView { return found }
        return view.subviews.lazy.compactMap { self.findCanvas(in: $0) }.first
    }

    var canvasRect: CGRect {
        host.layoutSubtreeIfNeeded()
        // visibleRect also subtracts an overlay scroller while it is awake. Measure the
        // actual clip viewport, whose geometry must stay fixed when that scroller fades.
        if let clip = canvas.enclosingScrollView?.contentView {
            return host.convert(clip.bounds, from: clip)
        }
        return host.convert(canvas.bounds, from: canvas)
    }

    /// Width the layout gives the sidebar (panel plus its separator).
    ///
    /// The scroll indicator is its own lane now, so it is not part of the sidebar's width; the
    /// right panel is hidden in this harness.
    var sidebarWidth: CGFloat {
        let rect = canvasRect
        let lane = state.document == nil ? 0 : ReaderChrome.scrollIndicatorLaneWidthPt
        return host.bounds.width - rect.width - lane
    }

    /// Top of a page in the host view's coordinates, using the same transform the canvas uses.
    func pageTopInHost(page: Int) -> CGFloat? {
        guard let placement = state.canvasPageFrames.first(where: { $0.index == page }) else {
            return nil
        }
        let fromCanvasTop = (placement.topPt - state.scrollYPt) * state.zoomFactor
        return canvasRect.maxY - fromCanvasTop
    }

    /// Collects the rendered sidebar width for `seconds`, including the frame the toggle left.
    func sampleSidebarWidths(for seconds: TimeInterval) async throws -> [CGFloat] {
        var samples: [CGFloat] = []
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            samples.append(sidebarWidth)
            try await Task.sleep(for: .milliseconds(8))
        }
        samples.append(sidebarWidth)
        return samples
    }

    /// The canvas frame and the page's on-screen y on every sampled frame.
    func sampleCanvasGeometry(
        for seconds: TimeInterval, page: Int
    ) async throws -> [(frame: CGRect, pageTop: CGFloat)] {
        var samples: [(frame: CGRect, pageTop: CGFloat)] = []
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            host.layoutSubtreeIfNeeded()
            if let top = pageTopInHost(page: page) {
                samples.append((canvasRect, top))
            }
            try await Task.sleep(for: .milliseconds(8))
        }
        host.layoutSubtreeIfNeeded()
        if let top = pageTopInHost(page: page) {
            samples.append((canvasRect, top))
        }
        return samples
    }

    /// The view `NSHostingView` would hand this click to. A point is measured from the canvas's
    /// top-left, which is also the content area's top-left.
    func hit(fromCanvasTop offset: CGFloat, xFraction: CGFloat = 0.5) -> NSView? {
        host.layoutSubtreeIfNeeded()
        let local = CGPoint(x: canvas.bounds.width * xFraction,
                            y: canvas.bounds.height - offset)
        let inHost = host.convert(local, from: canvas)
        // `NSView.hitTest` takes a point in the receiver's superview coordinates, while the
        // hosting view is flipped. Converting host -> superview is what keeps a point near the
        // top of the content from being looked up near the bottom.
        return host.hitTest(host.convert(inHost, to: host.superview))
    }

    var canvasHeight: CGFloat { canvasRect.height }
    var canvasMinY: CGFloat { canvasRect.minY }

    /// How many points of the row are currently hit-testable, found by bisecting the boundary.
    /// Zero means collapsed; 45-46 means fully revealed; anything between is a frame of the
    /// expansion. Six or seven hit tests, so it can be sampled inside the animation.
    func rowBottomFromCanvasTop() -> CGFloat {
        func overlay(_ offset: CGFloat) -> Bool {
            guard let hit = hit(fromCanvasTop: offset) else { return false }
            return hit !== canvas
        }
        guard overlay(0) else { return 0 }
        var low: CGFloat = 0
        var high: CGFloat = 60
        while high - low > 1 {
            let mid = ((low + high) / 2).rounded()
            if overlay(mid) { low = mid } else { high = mid }
        }
        return low
    }
}

extension ReaderChecks {
    @MainActor static func transitionChecks(root: URL) async throws {
        _ = NSApplication.shared

        // The values first, with no window: the requested duration range and Reduce Motion.
        let savedReduceMotion = ReaderMotion.reduceMotionOverride
        defer { ReaderMotion.reduceMotionOverride = savedReduceMotion }
        ReaderMotion.reduceMotionOverride = false
        require((0.18...0.25).contains(ReaderMotion.sidebarDuration),
                "the sidebar timing is inside the requested 0.18-0.25 s (\(ReaderMotion.sidebarDuration) s)")
        require((0.18...0.25).contains(ReaderMotion.secondaryRowDuration),
                "the row timing is inside the requested 0.18-0.25 s (\(ReaderMotion.secondaryRowDuration) s)")
        require(ReaderMotion.sidebarAnimation != nil && ReaderMotion.secondaryRowAnimation != nil,
                "both transitions animate when Reduce Motion is off")
        ReaderMotion.reduceMotionOverride = true
        require(ReaderMotion.sidebarAnimation == nil && ReaderMotion.secondaryRowAnimation == nil,
                "Reduce Motion removes both animations")
        ReaderMotion.reduceMotionOverride = false

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-reader-transitions-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = scratch.appendingPathComponent("multipage.pdf")
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("tests/fixtures/multipage.pdf"), to: fixture)

        // ── The slide is cheap ────────────────────────────────────────────────────────────
        // The width animates over dozens of viewport updates. None of them may rebuild the
        // visible band, because for this document the page is narrower than every width in the
        // slide, so the band cannot change while the width moves.
        let cheap = AppState(engine: try RustEngine())
        cheap.setViewportSize(CGSize(width: 900, height: 700))
        cheap.newTab(url: fixture)
        try await eventually("the transition cost fixture opens", {
            cheap.document?.pageCount == 3
        })
        try await eventually("the transition cost fixture has a screen page raster", {
            cheap.pageRasterCacheCount > 0
        })
        try await Task.sleep(for: .milliseconds(120))
        let reloadsBefore = cheap.viewportReloadCount
        let rastersBefore = cheap.pageRasterCacheCount
        var width = 900.0
        while width >= 650 {
            cheap.setViewportSize(CGSize(width: width, height: 700))
            width -= 10
        }
        width = 650
        while width <= 900 {
            cheap.setViewportSize(CGSize(width: width, height: 700))
            width += 10
        }
        require(cheap.viewportReloadCount == reloadsBefore,
                "a width-only slide performs no visible-band rebuild per frame "
                    + "(\(reloadsBefore) rebuilds before and after 52 viewport updates)")
        require(cheap.pageRasterCacheCount == rastersBefore,
                "a width-only slide requests no page raster per frame")

        // When the page is wider than the canvas the visible columns can change. Those updates
        // are coalesced, so the loop below may schedule one rebuild but not one per step.
        cheap.zoomPercent = 390
        cheap.zoomIn()
        try await Task.sleep(for: .milliseconds(120))
        let zoomReloads = cheap.viewportReloadCount
        width = 900
        while width >= 650 {
            cheap.setViewportSize(CGSize(width: width, height: 700))
            width -= 10
        }
        require(cheap.viewportReloadCount == zoomReloads,
                "a zoomed-in width-only slide also does no band rebuild per frame")
        try await Task.sleep(for: .milliseconds(350))
        let coalesced = cheap.viewportReloadCount - zoomReloads
        require(coalesced >= 1 && coalesced < 26,
                "the zoomed-in slide settles with a coalesced rebuild, not one per step "
                    + "(\(coalesced) rebuilds for 26 width updates)")

        // ── First layout: no animation ───────────────────────────────────────────────────
        let homeState = AppState(engine: try RustEngine())
        let homeHarness = TransitionHarness(state: homeState)
        try await homeHarness.mount()
        require(abs(homeHarness.sidebarWidth) < 0.5,
                "the empty Home page uses the full content width without a blank document sidebar")
        homeHarness.close()
        let state = AppState(engine: try RustEngine())
        require(state.open(url: fixture), "the hosted transition fixture opens")
        let harness = TransitionHarness(state: state)
        defer { harness.close() }
        try await harness.mount()
        let firstVisibleWidth = harness.sidebarWidth
        require(abs(firstVisibleWidth - ReaderChrome.sidebarTotalWidthPt) < 0.5,
                "a new window lays the visible sidebar out at its resting width at once "
                    + "(\(firstVisibleWidth) pt, no open animation)")

        let hiddenState = AppState(engine: try RustEngine())
        hiddenState.sidebarVisible = false
        let hiddenHarness = TransitionHarness(state: hiddenState)
        defer { hiddenHarness.close() }
        try await hiddenHarness.mount()
        let firstHiddenWidth = hiddenHarness.sidebarWidth
        require(abs(firstHiddenWidth) < 0.5,
                "a new window whose sidebar starts hidden lays out closed at once "
                    + "(\(firstHiddenWidth) pt, no close animation)")
        hiddenHarness.close()

        try await eventually("the hosted canvas receives its page placements", {
            state.canvasPageFrames.contains { $0.index == 0 }
        })
        try await Task.sleep(for: .milliseconds(80))

        // ── Sidebar: both endpoints, and the state agrees with the screen ────────────────
        // Pin the drawer at known progress values instead of racing the display link. The
        // parameters above still pin the real animation; these steps pin the layout a real
        // frame would have, so "partly open" is deterministic on any runner.
        state.transitionProgressOverride = ReaderTransitionProgress(sidebar: 1)
        try await eventually("the pinned open layout is the 251 pt drawer", {
            abs(harness.sidebarWidth - ReaderChrome.sidebarTotalWidthPt) < 0.5
        })
        state.sidebarVisible = false
        try await eventually("a close begins from the pinned open layout", {
            abs(harness.sidebarWidth - ReaderChrome.sidebarTotalWidthPt) < 0.5
        })
        var closing: [CGFloat] = []
        for progress in stride(from: 1.0, through: 0.0, by: -0.25) {
            state.transitionProgressOverride = ReaderTransitionProgress(sidebar: progress)
            let expected = ReaderChrome.sidebarTotalWidthPt * CGFloat(progress)
            try await eventually("the close lays out at progress \(progress)", {
                abs(harness.sidebarWidth - expected) < 1.0
            })
            closing.append(harness.sidebarWidth)
        }
        require((closing.first ?? 0) > 40,
                "the first pinned frame of a close still shows the sidebar open "
                    + "(\(closing.first ?? -1) pt; an instant hide would be 0)")
        require(closing.contains { $0 > 20 && $0 < 230 },
                "at least one pinned frame is partly open during the close "
                    + "(range \(closing.min() ?? -1)...\(closing.max() ?? -1) pt)")
        require(zip(closing, closing.dropFirst()).allSatisfy { $0 > $1 },
                "the pinned close moves monotonically from open to closed (\(closing))")
        state.transitionProgressOverride = nil
        try await eventually("the close reaches the closed endpoint", {
            abs(harness.sidebarWidth) < 0.5
        })
        require(!state.sidebarVisible,
                "the state and the screen agree at the closed end (sidebarVisible=\(state.sidebarVisible))")

        state.transitionProgressOverride = ReaderTransitionProgress(sidebar: 0)
        try await eventually("the pinned closed layout is laid out", {
            abs(harness.sidebarWidth) < 0.5
        })
        state.sidebarVisible = true
        try await eventually("an open begins from the pinned closed layout", {
            abs(harness.sidebarWidth) < 0.5
        })
        var opening: [CGFloat] = []
        for progress in stride(from: 0.0, through: 1.0, by: 0.25) {
            state.transitionProgressOverride = ReaderTransitionProgress(sidebar: progress)
            let expected = ReaderChrome.sidebarTotalWidthPt * CGFloat(progress)
            try await eventually("the open lays out at progress \(progress)", {
                abs(harness.sidebarWidth - expected) < 1.0
            })
            opening.append(harness.sidebarWidth)
        }
        require((opening.first ?? 999) < 100,
                "the first pinned frame of an open still shows the sidebar closed "
                    + "(\(opening.first ?? -1) pt; an instant show would be 251)")
        require(opening.contains { $0 > 20 && $0 < 230 },
                "at least one pinned frame is partly open during the open "
                    + "(range \(opening.min() ?? -1)...\(opening.max() ?? -1) pt)")
        require(zip(opening, opening.dropFirst()).allSatisfy { $0 < $1 },
                "the pinned open moves monotonically from closed to open (\(opening))")
        state.transitionProgressOverride = nil
        try await eventually("the open reaches the open endpoint", {
            abs(harness.sidebarWidth - ReaderChrome.sidebarTotalWidthPt) < 0.5
        })
        require(state.sidebarVisible,
                "the state and the screen agree at the open end (sidebarVisible=\(state.sidebarVisible))")

        // ── The document stays put while the width animates ─────────────────────────────
        // The vertical scroll offset, the current page, the zoom and the canvas's own top and
        // height are all independent of the sidebar's width. This is the direct check for "the
        // document must not jump"; zoom is deliberately not rescaled (the reader has no
        // fit-to-width mode, so the page keeps its magnification through the slide).
        state.scroll(byScreenPoints: 140)
        try await Task.sleep(for: .milliseconds(80))
        let anchorScroll = state.scrollYPt
        let anchorPage = state.currentPage
        let anchorZoom = state.zoomPercent
        let anchorCanvasTop = harness.canvasMinY
        let anchorCanvasHeight = harness.canvasHeight
        state.transitionProgressOverride = ReaderTransitionProgress(sidebar: 1)
        try await eventually("the stability sample starts from the pinned open width", {
            abs(harness.sidebarWidth - ReaderChrome.sidebarTotalWidthPt) < 0.5
        })
        state.sidebarVisible = false
        try await eventually("the stability sample starts with the drawer still open", {
            abs(harness.sidebarWidth - ReaderChrome.sidebarTotalWidthPt) < 0.5
        })
        var widthFrames: [CGFloat] = []
        var scrollFrames: [CGFloat] = []
        var pageFrames: [Int] = []
        var topFrames: [CGFloat] = []
        var heightFrames: [CGFloat] = []
        for progress in stride(from: 1.0, through: 0.0, by: -0.25) {
            state.transitionProgressOverride = ReaderTransitionProgress(sidebar: progress)
            let expected = ReaderChrome.sidebarTotalWidthPt * CGFloat(progress)
            try await eventually("the stability sample lays out at progress \(progress)", {
                abs(harness.sidebarWidth - expected) < 1.0
            })
            widthFrames.append(harness.sidebarWidth)
            scrollFrames.append(state.scrollYPt)
            pageFrames.append(state.currentPage)
            topFrames.append(harness.canvasMinY)
            heightFrames.append(harness.canvasHeight)
        }
        require(widthFrames.contains { $0 > 20 && $0 < 230 },
                "the document-stability sample really covers the slide "
                    + "(width range \(widthFrames.min() ?? -1)...\(widthFrames.max() ?? -1) pt)")
        require(zip(widthFrames, widthFrames.dropFirst()).allSatisfy { $0 > $1 },
                "the document-stability sample moves the width monotonically (\(widthFrames))")
        require(scrollFrames.allSatisfy { abs($0 - anchorScroll) < 0.001 },
                "the vertical scroll offset stays at \(anchorScroll) pt through the whole slide")
        require(pageFrames.allSatisfy { $0 == anchorPage },
                "the current page stays at page \(anchorPage) through the whole slide")
        require(topFrames.allSatisfy { abs($0 - anchorCanvasTop) < 0.001 }
                    && heightFrames.allSatisfy { abs($0 - anchorCanvasHeight) < 0.001 },
                "the canvas top (\(anchorCanvasTop) pt) and height (\(anchorCanvasHeight) pt) "
                    + "are unchanged through the whole slide (tops \(topFrames), heights \(heightFrames))")
        require(state.zoomPercent == anchorZoom,
                "zoom stays at \(anchorZoom)% during and after the slide (no per-frame rescale)")
        state.transitionProgressOverride = nil
        try await eventually("the stability sample reaches the closed endpoint", {
            abs(harness.sidebarWidth) < 0.5
        })
        state.sidebarVisible = true
        try await eventually("the sidebar is open again for the row checks", {
            abs(harness.sidebarWidth - ReaderChrome.sidebarTotalWidthPt) < 0.5
        })

        // ── Rapid toggles ────────────────────────────────────────────────────────────────
        state.sidebarVisible = false
        state.sidebarVisible = true
        state.sidebarVisible = false
        _ = try await harness.sampleSidebarWidths(for: 0.50)
        try await eventually("a rapid double toggle ends closed", {
            abs(harness.sidebarWidth) < 0.5
        })
        require(!state.sidebarVisible,
                "a rapid double toggle ends consistent (sidebarVisible=\(state.sidebarVisible))")
        for _ in 0..<5 {
            state.sidebarVisible.toggle()
            try await Task.sleep(for: .milliseconds(15))
        }
        state.sidebarVisible = false
        _ = try await harness.sampleSidebarWidths(for: 0.50)
        try await eventually("a burst of toggles ends closed, not half open", {
            abs(harness.sidebarWidth) < 0.5
        })
        require(!state.sidebarVisible,
                "the burst leaves the state closed (sidebarVisible=\(state.sidebarVisible))")

        // ── Toggle while a document is opening ──────────────────────────────────────────
        let openingState = AppState(engine: try RustEngine())
        let openingHarness = TransitionHarness(state: openingState)
        defer { openingHarness.close() }
        try await openingHarness.mount()
        let heightBeforeOpen = openingHarness.canvasHeight
        openingState.sidebarVisible = false
        require(openingState.newTab(url: fixture),
                "a second window starts opening a document while its sidebar moves")
        try await Task.sleep(for: .milliseconds(20))
        openingState.sidebarVisible = true
        try await Task.sleep(for: .milliseconds(20))
        openingState.sidebarVisible = false
        try await eventually("the document finishes opening during the sidebar toggles", {
            openingState.document?.pageCount == 3
        })
        _ = try await openingHarness.sampleSidebarWidths(for: 0.50)
        try await eventually("toggling during document opening settles closed", {
            abs(openingHarness.sidebarWidth) < 0.5
        })
        require(!openingState.sidebarVisible,
                "toggling during document opening ends consistent "
                    + "(sidebarVisible=\(openingState.sidebarVisible))")
        require(abs(openingHarness.canvasHeight - heightBeforeOpen) < 0.5,
                "the canvas is not left mis-sized by the opening toggles "
                    + "(\(openingHarness.canvasHeight) pt vs \(heightBeforeOpen) pt)")

        // ── Secondary row: the canvas and the page do not move ──────────────────────────
        // Put the sidebar back open: the default reading layout is the one where the row must
        // start at the canvas edge rather than over the sidebar's tab picker.
        state.sidebarVisible = true
        try await Task.sleep(for: .milliseconds(300))
        // A settled, scrolled position with a page whose top can be measured explicitly.
        state.scroll(byScreenPoints: 140)
        try await Task.sleep(for: .milliseconds(100))
        try await eventually("the scrolled page is on the canvas", {
            state.canvasPageFrames.contains { $0.index == 1 }
        })
        harness.canvasRect
        let frameBefore = harness.canvasRect
        let pageTopBefore = harness.pageTopInHost(page: 1) ?? .nan
        require(frameBefore.height > 100 && frameBefore.width > 100,
                "the hosted canvas has a measurable frame before the row "
                    + "(\(Int(frameBefore.width))x\(Int(frameBefore.height)) at y=\(frameBefore.minY), "
                    + "page 2 top at y=\(pageTopBefore))")

        let collapsedHit = harness.hit(fromCanvasTop: 10)
        require(collapsedHit === harness.canvas,
                "with the row collapsed, a click at the top of the page reaches the canvas")

        state.transitionProgressOverride = ReaderTransitionProgress(row: 0)
        state.annotationToolsVisible = true
        try await eventually("the row is pinned collapsed", {
            harness.rowBottomFromCanvasTop() == 0
        })
        var rowBottoms: [CGFloat] = []
        var expanding: [(frame: CGRect, pageTop: CGFloat)] = []
        for progress in [0.25, 0.5, 0.75, 1.0] {
            state.transitionProgressOverride = ReaderTransitionProgress(row: progress)
            let expected = ReaderChrome.secondaryToolbarHeightPt * CGFloat(progress)
            try await eventually("the row lays out at progress \(progress)", {
                abs(harness.rowBottomFromCanvasTop() - expected) <= 2
            })
            rowBottoms.append(harness.rowBottomFromCanvasTop())
            if let top = harness.pageTopInHost(page: 1) {
                expanding.append((harness.canvasRect, top))
            }
        }
        require(rowBottoms.contains { $0 > 2 && $0 < 44 },
                "the row reveals its content over time instead of appearing whole "
                    + "(hit area bottom samples \(rowBottoms.map { Int($0) }))")
        require(zip(rowBottoms, rowBottoms.dropFirst()).allSatisfy { $0 <= $1 },
                "the pinned reveal moves monotonically from collapsed to full "
                    + "(hit area bottom samples \(rowBottoms.map { Int($0) }))")
        let heightDeviation = expanding.map { abs($0.frame.height - frameBefore.height) }.max() ?? .nan
        let originDeviation = expanding.map { abs($0.frame.minY - frameBefore.minY) }.max() ?? .nan
        let pageDeviation = expanding.map { abs($0.pageTop - pageTopBefore) }.max() ?? .nan
        require(heightDeviation < 0.01 && originDeviation < 0.01,
                "the canvas frame is identical on every pinned frame of the row's reveal "
                    + "(height \(frameBefore.height) pt, max height deviation \(heightDeviation), "
                    + "max origin deviation \(originDeviation))")
        require(pageDeviation < 0.01,
                "the page's on-screen y is identical on every pinned frame of the reveal "
                    + "(y \(pageTopBefore), max deviation \(pageDeviation))")
        state.transitionProgressOverride = nil
        let frameAfter = harness.canvasRect
        let pageTopAfter = harness.pageTopInHost(page: 1) ?? .nan
        require(abs(frameAfter.height - frameBefore.height) < 0.01
                    && abs(frameAfter.minY - frameBefore.minY) < 0.01
                    && abs(pageTopAfter - pageTopBefore) < 0.01,
                "after the reveal the canvas is still \(Int(frameAfter.width))x\(Int(frameAfter.height)) "
                    + "at y=\(frameAfter.minY) and the page top is still y=\(pageTopAfter)")

        try await eventually("the row finishes its reveal at the full 46 pt", {
            harness.rowBottomFromCanvasTop() >= 44
        })
        let revealedBottom = harness.rowBottomFromCanvasTop()
        require(revealedBottom <= 46,
                "the reveal ends at the full 46 pt row (hit area bottom \(revealedBottom) pt)")
        let overlayHit = harness.hit(fromCanvasTop: 10)
        require(overlayHit != nil && overlayHit !== harness.canvas,
                "a click on the revealed row does not fall through to the canvas "
                    + "(hit: \(overlayHit.map { String(describing: type(of: $0)) } ?? "nil"))")
        let belowHit = harness.hit(fromCanvasTop: 80)
        require(belowHit === harness.canvas,
                "a click below the row's 46 pt strip still reaches the canvas")

        state.transitionProgressOverride = ReaderTransitionProgress(row: 1)
        state.annotationToolsVisible = false
        try await eventually("the row is pinned open before the collapse", {
            harness.rowBottomFromCanvasTop() >= 44
        })
        var collapsing: [(frame: CGRect, pageTop: CGFloat)] = []
        for progress in stride(from: 1.0, through: 0.0, by: -0.25) {
            state.transitionProgressOverride = ReaderTransitionProgress(row: progress)
            let expected = ReaderChrome.secondaryToolbarHeightPt * CGFloat(progress)
            try await eventually("the row collapses at progress \(progress)", {
                abs(harness.rowBottomFromCanvasTop() - expected) <= 2
            })
            if let top = harness.pageTopInHost(page: 1) {
                collapsing.append((harness.canvasRect, top))
            }
        }
        let collapseHeightDeviation = collapsing.map { abs($0.frame.height - frameBefore.height) }.max() ?? .nan
        let collapsePageDeviation = collapsing.map { abs($0.pageTop - pageTopBefore) }.max() ?? .nan
        require(collapseHeightDeviation < 0.01 && collapsePageDeviation < 0.01,
                "the canvas and page stay put while the row collapses "
                    + "(height deviation \(collapseHeightDeviation), page deviation \(collapsePageDeviation))")
        state.transitionProgressOverride = nil
        try await eventually("the row finishes its collapse", {
            harness.rowBottomFromCanvasTop() == 0
        })
        require(harness.hit(fromCanvasTop: 10) === harness.canvas,
                "with the row collapsed again, the page's top receives clicks")

        // Lyra uses the very same moving, clipped row and leaves page geometry unchanged.
        state.transitionProgressOverride = ReaderTransitionProgress(row: 0)
        state.toggleAITools()
        var lyraBottoms: [CGFloat] = []
        for progress in [0.25, 0.5, 0.75, 1.0, 0.5, 0.0] {
            state.transitionProgressOverride = ReaderTransitionProgress(row: progress)
            let expected = ReaderChrome.secondaryToolbarHeightPt * CGFloat(progress)
            try await eventually("Lyra tools slide at progress \(progress)", {
                abs(harness.rowBottomFromCanvasTop() - expected) <= 2
            })
            lyraBottoms.append(harness.rowBottomFromCanvasTop())
        }
        require(lyraBottoms.contains { $0 > 2 && $0 < 44 },
                "Lyra tools have intermediate slide frames instead of popping in")
        require(abs(harness.canvasRect.height - frameBefore.height) < 0.01,
                "Lyra tool animation preserves the PDF canvas height")
        state.toggleAITools()
        state.transitionProgressOverride = nil

        // ── Page overview shares the one row slot ───────────────────────────────────────
        state.annotationToolsVisible = true
        try await Task.sleep(for: .milliseconds(250))
        state.pageOverviewVisible = true
        try await Task.sleep(for: .milliseconds(250))
        harness.canvasRect
        let overviewFrame = harness.canvasRect
        let overviewTopHit = harness.hit(fromCanvasTop: 10)
        require(overviewTopHit != nil && overviewTopHit !== harness.canvas,
                "page overview's row occupies the one overlay slot, not a second one")
        require(abs(overviewFrame.height - frameBefore.height) < 0.01,
                "the canvas frame is unchanged in page overview too "
                    + "(\(overviewFrame.height) pt vs \(frameBefore.height) pt)")
        state.pageOverviewVisible = false
        try await Task.sleep(for: .milliseconds(250))
        harness.canvasRect
        require(harness.hit(fromCanvasTop: 40) !== harness.canvas,
                "leaving page overview returns the annotation row in the same slot without a gap")
        state.annotationToolsVisible = false
        // Display-link transactions can start late when the shard has many hosted GPU views.
        // Observe the actual released hit area rather than assuming wall-clock sleep means
        // AppKit has presented the animation's last frame. A persistent overlay still fails.
        try await eventuallyExplaining(
            "closing the shared row restores the canvas's hit area at the top",
            {
                "Open rows: \(state.openSecondaryRows); overview: \(state.pageOverviewVisible); "
                    + "hit: \(harness.hit(fromCanvasTop: 10).map { String(describing: type(of: $0)) } ?? "nil")"
            },
            { harness.hit(fromCanvasTop: 10) === harness.canvas }
        )

        // ── Reduce Motion is immediate ──────────────────────────────────────────────────
        ReaderMotion.reduceMotionOverride = true
        if !state.sidebarVisible {
            state.sidebarVisible = true
            try await Task.sleep(for: .milliseconds(250))
        }
        state.sidebarVisible = false
        try await Task.sleep(for: .milliseconds(80))
        let reducedClose = harness.sidebarWidth
        require(abs(reducedClose) < 0.5,
                "with Reduce Motion on, closing the sidebar is immediate "
                    + "(\(reducedClose) pt after 80 ms)")
        state.sidebarVisible = true
        try await Task.sleep(for: .milliseconds(80))
        let reducedOpen = harness.sidebarWidth
        require(abs(reducedOpen - ReaderChrome.sidebarTotalWidthPt) < 0.5,
                "with Reduce Motion on, opening the sidebar is immediate "
                    + "(\(reducedOpen) pt after 80 ms)")
        state.annotationToolsVisible = false
        try await Task.sleep(for: .milliseconds(120))
        state.annotationToolsVisible = true
        try await Task.sleep(for: .milliseconds(80))
        require(harness.hit(fromCanvasTop: 44) !== harness.canvas,
                "with Reduce Motion on, the row is revealed at full height on the first update")
        state.annotationToolsVisible = false
        try await Task.sleep(for: .milliseconds(120))
        ReaderMotion.reduceMotionOverride = false

        // ── No animation while the window is resized live ──────────────────────────────
        // The old observation sampled a wall-clock animation and could miss its only
        // intermediate frame on a slow runner. The policy is now asserted on endpoints and on
        // the animation parameter: during the resize the toggle has to be at the open endpoint
        // after one short layout wait, and the shared animation has to be available again after
        // the resize ends. Neither assertion depends on a frame arriving on time.
        state.sidebarVisible = false
        try await eventually("the sidebar is closed before the live resize", {
            abs(harness.sidebarWidth) < 0.5
        })
        NotificationCenter.default.post(
            name: NSWindow.willStartLiveResizeNotification, object: harness.window)
        try await Task.sleep(for: .milliseconds(80))
        state.sidebarVisible = true
        try await Task.sleep(for: .milliseconds(120))
        let duringLiveResize = harness.sidebarWidth
        require(abs(duringLiveResize - ReaderChrome.sidebarTotalWidthPt) < 0.5,
                "a toggle during a live window resize is at the open endpoint after 120 ms "
                    + "(\(duringLiveResize) pt; an animated one would be part-way)")
        NotificationCenter.default.post(
            name: NSWindow.didEndLiveResizeNotification, object: harness.window)
        try await Task.sleep(for: .milliseconds(80))
        require(ReaderMotion.sidebarAnimation != nil,
                "the shared sidebar animation is available again after the live resize")
        state.sidebarVisible = false
        try await eventually("the restored close reaches the closed endpoint", {
            abs(harness.sidebarWidth) < 0.5
        })
        try await Task.sleep(for: .milliseconds(100))

        print("Transition checks passed")
    }
}
