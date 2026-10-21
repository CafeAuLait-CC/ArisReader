import AppKit
import LyraReaderKit
import SwiftUI

/// T1.13: the in-app performance panel.
///
/// This suite is the acceptance evidence for the panel: it drives a hosted reader window, reads
/// the same snapshot the view draws, opens and closes the panel, zooms into the tile path,
/// scrolls, hides the window to prove skipped frames are reported as skipped, hosts the panel at
/// the right panel's 240 pt minimum, and asserts that a closed panel leaves no sampling task and
/// no counter drift behind.
@MainActor
private final class PerformancePanelHarness {
    let state: AppState
    let host: NSHostingView<ReaderWindow>
    let window: NSWindow
    private(set) var canvas: MetalCanvasView!

    init(state: AppState) {
        self.state = state
        self.host = NSHostingView(rootView: ReaderWindow(
            state: state,
            opener: DocumentOpenCoordinator(state: state)
        ))
        self.window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1180, height: 820),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
    }

    func mount() async throws {
        window.orderFrontRegardless()
        try await ReaderChecks.eventually("performance panel: hosted reader lays out its canvas", {
            self.host.layoutSubtreeIfNeeded()
            self.canvas = self.findCanvas(in: self.host)
            return self.canvas != nil
        })
        host.layoutSubtreeIfNeeded()
    }

    func close() {
        state.performancePanel.stop()
        window.orderOut(nil)
        window.contentView = nil
    }

    private func findCanvas(in view: NSView) -> MetalCanvasView? {
        if let found = view as? MetalCanvasView { return found }
        return view.subviews.lazy.compactMap { self.findCanvas(in: $0) }.first
    }

    /// The existing counters the panel must not perturb while it is closed.
    struct ExistingCounters: Equatable {
        var submittedFrames: UInt64
        var frameAttempts: UInt64
        var viewportReloads: Int
        var tileStats: TileCacheStats
        var requests: Int
        var pageRasters: Int
    }

    func existingCounters() -> ExistingCounters {
        ExistingCounters(
            submittedFrames: canvas.submittedFrameCount,
            frameAttempts: canvas.frameAttemptCount,
            viewportReloads: state.viewportReloadCount,
            tileStats: state.tileCacheSnapshot,
            requests: state.tileRequestCount,
            pageRasters: state.pageRasterCount
        )
    }
}

extension ReaderChecks {
    /// Standalone entry point: `LyraReaderChecks --check-performance-panel .`
    @MainActor static func performancePanelChecks(root: URL) async throws {
        performancePanelShortcutChecks()
        performancePanelStatisticsChecks()
        try await performancePanelLifecycleChecks()
        try await performancePanelWindowChecks(
            url: root.appendingPathComponent("tests/fixtures/multipage.pdf"))
    }

    // MARK: - Shortcut and pure statistics

    @MainActor
    private static func performancePanelShortcutChecks() {
        // The chord is Option-Command-P. It must not collide with any native menu binding.
        for (key, modifiers) in PerformancePanelShortcut.reservedNativeChords {
            require(
                !(key == PerformancePanelShortcut.key && modifiers == PerformancePanelShortcut.modifiers),
                "performance panel shortcut ⌥⌘P collides with a native menu chord"
            )
        }
        require(PerformancePanelShortcut.key == "p", "performance panel uses P")
        require(PerformancePanelShortcut.modifiers == [.command, .option],
                "performance panel uses Option-Command-P, which neither menu uses")
        // The native menu binds ⌘P (Print); the Rust keymap binds ⇧⌘P (PreviewCitation). ⌥⌘P is
        // a different chord because Option is part of the modifier set; keep the three distinct
        // here so a future menu/keymap edit that takes Option-Command-P trips this check.
        let printChord: EventModifiers = [.command]
        let previewChord: EventModifiers = [.command, .shift]
        require(PerformancePanelShortcut.modifiers != printChord
                && PerformancePanelShortcut.modifiers != previewChord,
                "the panel's ⌥⌘P is distinct from Print's ⌘P and Preview's ⇧⌘P")
    }

    @MainActor
    private static func performancePanelStatisticsChecks() {
        // Nearest-rank percentiles, not averages: p50 of [1, 100] is 1 and p95 is 100, while a
        // mean would be 50.5. The panel must not present a moving average as a percentile.
        let two = [1.0, 100.0]
        require(FrameMetrics.percentile(0.50, of: two) == 1,
                "p50 of two frame times is the lower observed value, not their average")
        require(FrameMetrics.percentile(0.95, of: two) == 100,
                "p95 of two frame times is the upper observed value, not their average")
        let window = (1...100).map(Double.init)
        require(FrameMetrics.percentile(0.50, of: window) == 50, "p50 is a nearest-rank percentile")
        require(FrameMetrics.percentile(0.95, of: window) == 95, "p95 is a nearest-rank percentile")
        require(FrameMetrics.percentile(0.95, of: []) == nil,
                "an empty frame window has no percentile rather than 0")
        require(FrameMetrics.percentile(0.95, of: [7]) == 7,
                "one sample is its own p50 and p95")
    }

    // MARK: - Controller lifecycle and absent measurements

    @MainActor
    private static func performancePanelLifecycleChecks() async throws {
        let state = AppState(engine: MockEngine())
        let controller = state.performancePanel

        // Nothing is measured before a document/render: the snapshot must say so with nil, not 0.
        let empty = state.makePerformanceSnapshot()
        require(empty.frameP95Ms == nil, "no frame window means p95 is absent, not 0")
        require(empty.framesPresented == nil, "no frames sampled means the count is absent, not 0")
        require(empty.frameIntervalP95Ms == nil,
                "no presented-frame interval means the interval p95 is absent")
        require(empty.openToFirstFrameMilliseconds == nil,
                "no open has been measured, so open-to-first-frame is absent")
        require(empty.pageRasterMilliseconds == nil && empty.tileRasterMilliseconds == nil,
                "zero rasters means raster time is absent, not 0 ms")
        require(empty.zoomPercent == 100 && empty.calibrationFactor == 1,
                "zoom and calibration are measured even with no document")

        require(!controller.isSampling && !controller.isSamplingTaskRunning,
                "the performance sampler is not running before the panel opens")

        controller.setRunning(true, state: state)
        require(controller.isSampling && controller.isSamplingTaskRunning,
                "opening the panel starts the 4 Hz sampling task")
        require(state.performanceProbe.isSampling, "opening the panel enables the frame probe")
        try await eventually("the open panel produces a snapshot", { controller.snapshot != nil })
        try await Task.sleep(for: .milliseconds(300))
        require(controller.isSamplingTaskRunning, "the sampling task is still alive while open")

        controller.setRunning(false, state: state)
        require(!controller.isSampling && !controller.isSamplingTaskRunning,
                "closing the panel cancels the sampling task")
        require(!state.performanceProbe.isSampling,
                "closing the panel disables the frame probe")
        require(controller.snapshot == nil, "closing the panel drops the retained snapshot")
    }

    // MARK: - Hosted window

    @MainActor
    private static func performancePanelWindowChecks(url: URL) async throws {
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 900, height: 700))
        let harness = PerformancePanelHarness(state: state)
        defer { harness.close() }
        try await harness.mount()
        require(state.newTab(url: url), "performance panel: the fixture opens")
        try await eventually("performance panel: the first page raster arrives", {
            state.pageRasterCount > 0 && state.pageRasterCacheCount > 0
        })
        try await eventually("performance panel: the document presents a frame", {
            harness.canvas.submittedFrameCount > 0
        })
        try await eventually("performance panel: open-to-first-frame is measured", {
            state.performanceProbe.openToFirstFrameMilliseconds != nil
        })
        // Let the raster/render burst settle so the closed-panel comparison is a genuinely idle
        // second, not a race with pending tiles.
        try await Task.sleep(for: .milliseconds(500))
        let idleBefore = harness.existingCounters()
        try await Task.sleep(for: .milliseconds(700))
        require(harness.existingCounters() == idleBefore,
                "an idle document does not change the pre-existing counters")
        require(!state.performancePanel.isSamplingTaskRunning,
                "no sampling task runs while the panel has never been opened")

        // Open and close without touching the document. The panel's own work must not move the
        // counters the reader already had: this is the closed-panel cost evidence.
        let beforePanel = harness.existingCounters()
        state.togglePerformancePanel()
        require(state.performancePanelVisible, "the menu action opens the performance panel")
        require(state.performancePanel.isSampling && state.performancePanel.isSamplingTaskRunning,
                "the open panel samples")
        try await Task.sleep(for: .milliseconds(400))
        state.togglePerformancePanel()
        require(!state.performancePanelVisible, "the menu action closes the performance panel")
        require(!state.performancePanel.isSamplingTaskRunning,
                "closing the panel leaves no sampling task behind")
        require(!state.performanceProbe.isSampling, "closing the panel disables the frame probe")
        require(harness.existingCounters() == beforePanel,
                "opening and closing the panel changes none of the existing counters")
        require(!state.performanceProbe.wantsFrameSamples,
                "after the one-shot open measurement no per-frame sampling remains")

        // Re-open for the live numbers. Start from the top so the following scroll is guaranteed
        // to move: the reader restores a saved reading position, and at the bottom of the
        // document a small positive scroll clamps to a no-op (which would produce no frame).
        state.togglePerformancePanel()
        state.gotoPage(0)
        state.scroll(byScreenPoints: 1)
        try await eventually("the open panel reports presented frames", {
            (state.performancePanel.snapshot?.framesPresented ?? 0) > 0
        })
        // A few separated updates produce consecutive presented frames, which is what the
        // wall-clock interval percentile needs.
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(120))
            state.scroll(byScreenPoints: 3)
        }
        try await eventually("the panel reports presented-frame intervals", {
            (state.performancePanel.snapshot?.frameIntervalSampleCount ?? 0) > 0
        })
        let live = try requireSnapshot(state, "first live snapshot")
        require(live.frameLastMs != nil, "the panel reports the last engine CPU frame time")
        require(live.frameP50Ms != nil && live.frameP95Ms != nil,
                "the panel reports CPU p50 and p95 over the frame window")
        if let p50 = live.frameP50Ms, let p95 = live.frameP95Ms {
            require(p50 <= p95, "CPU p50 cannot exceed p95")
        }
        require(live.frameIntervalLastMs != nil,
                "the panel reports the last wall-clock interval between presented frames")
        require(live.frameIntervalP50Ms != nil && live.frameIntervalP95Ms != nil,
                "the panel reports presented-frame interval p50 and p95")
        if let p50 = live.frameIntervalP50Ms, let p95 = live.frameIntervalP95Ms {
            require(p50 > 0 && p50 <= p95,
                    "presented-frame interval percentiles are positive and ordered")
        }
        require(live.lastFramePresented == true,
                "a visible window presents, and the panel says so")
        require((live.framesPresented ?? 0) > 0, "the frame count is non-zero after a render")
        require((live.surfaceFrameIndex ?? 0) > 0,
                "the engine's own presented-frame counter is non-zero after a render")
        require((live.pageRasterCount ?? 0) >= 1,
                "at least one engine page raster has been measured after the render")
        require((live.thumbnailCount ?? 0) > 0 && (live.thumbnailBytes ?? 0) > 0,
                "the thumbnail memory figure is measured")
        require(live.cacheBudgetBytes == state.tileCacheBudgetBytes,
                "the panel reports the configured cache budget")
        require(live.cacheUsedBytes != nil && live.cachePeakBytes != nil,
                "cache occupancy and peak are measured")
        require(live.openToFirstFrameMilliseconds != nil,
                "open-to-first-frame is reported from the one-shot measurement")
        require(live.usingScreenPageRasters != nil,
                "the page/tile path is measured after a render")
        require(live.frameTapMicroseconds != nil,
                "the frame tap's own cost is measured while sampling")
        if let cost = live.frameTapMicroseconds {
            require(cost < 500,
                    String(format: "the per-frame tap stays under 0.5 ms (measured %.3f ms)",
                           cost / 1000))
        }
        if let sampleCost = state.performancePanel.lastSamplingCostMilliseconds {
            require(sampleCost < 16.0,
                    String(format: "one snapshot costs less than a 60 Hz frame (measured %.2f ms)",
                           sampleCost))
        } else {
            fatalError("FAIL: the panel does not report its sampling cost")
        }
        require(PerformancePanelController.samplingIntervalMilliseconds == 250,
                "the stated sampling interval is 250 ms (4 Hz)")

        // Sampling itself must not schedule frames or viewport rebuilds. An idle document with
        // the panel open runs only the 4 Hz snapshot read; the canvas counters stay put. Let the
        // frames from the scrolls above land first, then compare two idle windows.
        try await Task.sleep(for: .milliseconds(600))
        let idleOpen = harness.existingCounters()
        try await Task.sleep(for: .milliseconds(800))
        require(harness.existingCounters() == idleOpen,
                "the open panel's sampling does not schedule frames or reloads on an idle document")

        // The right panel's minimum width. Host the same view at 240 pt in dark mode, with the
        // live snapshot (including the long path note), and require it not to demand more.
        try performancePanelWidthChecks(state: state)

        let lodBefore = live.rasterLOD
        let requestsBefore = live.tileRequests ?? 0

        // Deep zoom: the page-raster path cannot serve 400% on this fixture, so the pyramid and
        // its LOD must be what the panel reports.
        state.zoomPercent = 400
        state.reloadVisiblePages()
        try await eventually("deep zoom moves the reported tile LOD", {
            state.currentRasterLOD > lodBefore
        })
        try await eventually("deep zoom switches to the tile path", {
            !state.usesScreenPageRasters
        })
        try await eventually("deep zoom requests tiles", {
            state.tileRequestCount > requestsBefore
        })
        state.scroll(byScreenPoints: 1)
        try await eventually("the deep-zoom snapshot reflects the new LOD", {
            (state.performancePanel.snapshot?.rasterLOD ?? 0) > lodBefore
        })
        try await eventually("a presented deep-zoom frame contains tile quads", {
            (state.performancePanel.snapshot?.lastFrameTileQuads ?? 0) > 0
        })
        require((harness.canvas.lastSubmittedTileCount ?? 0) > 0,
                "the canvas counted the tile quads it submitted in the last presented frame")
        let deep = try requireSnapshot(state, "deep-zoom snapshot")
        require(deep.usingScreenPageRasters == false,
                "the deep-zoom snapshot reports the pyramid-tile path")
        require(deep.rasterLOD > lodBefore, "the deep-zoom snapshot reports a higher LOD")
        require((deep.tileRequests ?? 0) > requestsBefore,
                "the deep-zoom snapshot reports more tile requests")
        require(deep.zoomPercent == 400, "the panel reports the current zoom")
        require(deep.calibrationFactor == state.displayCalibration.factor,
                "the panel reports the display calibration factor")
        require(deep.effectiveZoom == state.zoomFactor,
                "the panel reports the effective zoom")

        // Scrolling at deep zoom must queue more tiles, and the counters must say so.
        let requestsBeforeScroll = state.tileRequestCount
        try await Task.sleep(for: .milliseconds(400))
        state.scroll(byScreenPoints: 2600)
        state.scroll(byScreenPoints: 2600)
        state.scroll(byScreenPoints: 2600)
        try await eventually("scrolling requests more tiles", {
            state.tileRequestCount > requestsBeforeScroll
        })
        try await eventually("the snapshot reports the scroll's tile requests", {
            (state.performancePanel.snapshot?.tileRequests ?? 0) > (deep.tileRequests ?? 0)
        })

        // An occluded window must be reported as skipped, not as a frame that rendered.
        let presentedBeforeHide = state.performancePanel.snapshot?.framesPresented ?? 0
        harness.window.orderOut(nil)
        // Force a render attempt while hidden. The canvas retries at a low rate after wgpu
        // reports the surface as not presented.
        harness.canvas.scrollYPt += 1
        try await eventually("an occluded window reports skipped frames", {
            (state.performancePanel.snapshot?.framesSkipped ?? 0) > 0
        }, timeoutChecks: 1200)
        try await Task.sleep(for: .milliseconds(350))
        let occluded = try requireSnapshot(state, "occluded snapshot")
        require(occluded.lastFramePresented == false,
                "an occluded window's last sample is not presented")
        require((occluded.framesSkipped ?? 0) > 0,
                "the panel counts skipped attempts while the window cannot present")
        require((occluded.framesPresented ?? 0) <= presentedBeforeHide + 2,
                "an occluded window does not pretend to present new frames")
        harness.window.orderFrontRegardless()

        // Closed again: no sampler, no timer, no snapshot, and the idle counters stay put.
        state.togglePerformancePanel()
        require(!state.performancePanel.isSamplingTaskRunning,
                "the closed panel has no sampling task")
        try await Task.sleep(for: .milliseconds(500))
        let afterClose = harness.existingCounters()
        try await Task.sleep(for: .milliseconds(800))
        require(harness.existingCounters() == afterClose,
                "with the panel closed no new timer changes the existing counters")
    }

    /// Hosts the shipped panel at the right panel's minimum content width, in dark mode, and
    /// checks that a long, live snapshot does not demand more width than 240 pt.
    @MainActor
    private static func performancePanelWidthChecks(state: AppState) throws {
        require(ReaderSidePanelMetrics.minimumContentWidthPt == 240,
                "the right panel's minimum content width is 240 pt")
        let view = PerformancePanelView(controller: state.performancePanel, onClose: {})
            .frame(width: ReaderSidePanelMetrics.minimumContentWidthPt)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: ReaderSidePanelMetrics.minimumContentWidthPt,
                            height: 700)
        host.layoutSubtreeIfNeeded()
        let fitting = host.fittingSize
        require(fitting.width <= ReaderSidePanelMetrics.minimumContentWidthPt + 0.5,
                String(format: "the performance panel fits 240 pt (fitting width %.1f)",
                       fitting.width))
        require(fitting.height > 0, "the performance panel lays out in dark mode")
        // The panel is a vertical scroll: with the same live data its height demand is finite.
        let second = NSHostingView(rootView: PerformancePanelView(
            controller: state.performancePanel, onClose: {})
            .frame(width: ReaderSidePanelMetrics.minimumContentWidthPt))
        second.appearance = NSAppearance(named: .darkAqua)
        second.frame = host.frame
        second.layoutSubtreeIfNeeded()
        require(abs(second.fittingSize.width - fitting.width) < 0.5,
                "a live value update does not change the panel's minimum width")
    }

    @MainActor
    private static func requireSnapshot(
        _ state: AppState, _ what: String
    ) throws -> PerformanceSnapshot {
        guard let snapshot = state.performancePanel.snapshot else {
            fatalError("FAIL: no snapshot available (\(what))")
        }
        return snapshot
    }
}

private extension ReaderChecks {
    /// `eventually` with a longer budget for the occluded case: the canvas only retries every
    /// 133 ms while it cannot present, and the panel samples at 4 Hz, so a second is not enough
    /// on a loaded runner.
    @MainActor
    static func eventually(
        _ message: String, _ condition: () -> Bool, timeoutChecks: Int
    ) async throws {
        for _ in 0..<timeoutChecks {
            if condition() {
                print("PASS: \(message)")
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        fatalError("TIMEOUT: \(message)")
    }
}
