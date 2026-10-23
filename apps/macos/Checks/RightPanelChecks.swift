import AppKit
import LyraReaderKit
import SwiftUI

/// The AI assistant's right-hand panel.
///
/// This suite is the acceptance evidence for moving the assistant out of the left sidebar:
/// layout numbers measured on a hosted `ReaderWindow`, the panel's persistence and clamps, the
/// two-panel canvas width, page stability while it opens, the animation policy, and the sidebar
/// tab migration. It deliberately uses the real AI view as the panel content; the model is
/// pointed at an in-memory settings store so no Keychain entry or network request is involved.
@MainActor
private final class RightPanelHarness {
    let state: AppState
    let host: NSHostingView<ReaderWindow>
    let window: NSWindow
    private(set) var canvas: MetalCanvasView!

    init(state: AppState, aiAssistant: AIAssistantModel) {
        self.state = state
        self.host = NSHostingView(rootView: ReaderWindow(
            state: state,
            opener: DocumentOpenCoordinator(state: state),
            aiAssistant: aiAssistant
        ))
        self.window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false
        )
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
        window.contentView = nil
    }

    private func findCanvas(in view: NSView) -> MetalCanvasView? {
        if let found = view as? MetalCanvasView { return found }
        return view.subviews.lazy.compactMap { self.findCanvas(in: $0) }.first
    }

    var canvasRect: CGRect {
        host.layoutSubtreeIfNeeded()
        if let clip = canvas.enclosingScrollView?.contentView {
            return host.convert(clip.bounds, from: clip)
        }
        return host.convert(canvas.bounds, from: canvas)
    }

    var liveCanvas: MetalCanvasView? { findCanvas(in: host) }

    private var laneWidth: CGFloat {
        state.document == nil ? 0 : ReaderChrome.scrollIndicatorLaneWidthPt
    }

    /// The panel's whole footprint (handle + separator + content), measured from the real
    /// AppKit frames. Zero when it is closed.
    var panelTotalWidth: CGFloat {
        host.layoutSubtreeIfNeeded()
        func marker(_ view: NSView) -> ReaderSidePanelMarkerView? {
            if let found = view as? ReaderSidePanelMarkerView { return found }
            return view.subviews.lazy.compactMap { marker($0) }.first
        }
        return marker(host)?.bounds.width ?? 0
    }

    var panelContentWidth: CGFloat {
        max(0, panelTotalWidth
            - ReaderSidePanelMetrics.resizeHandleWidthPt
            - ReaderSidePanelMetrics.separatorWidthPt)
    }

    func pageTopInHost(page: Int) -> CGFloat? {
        guard let placement = state.canvasPageFrames.first(where: { $0.index == page }) else {
            return nil
        }
        let fromCanvasTop = (placement.topPt - state.scrollYPt) * state.zoomFactor
        return canvasRect.maxY - fromCanvasTop
    }

    /// Widths sampled for `seconds`; the harness re-lays out every sample so it sees the frames
    /// SwiftUI actually produced, not just the state's target.
    func samplePanelWidths(for seconds: TimeInterval) async throws -> [CGFloat] {
        var samples: [CGFloat] = []
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            samples.append(panelTotalWidth)
            try await Task.sleep(for: .milliseconds(8))
        }
        samples.append(panelTotalWidth)
        return samples
    }
}

extension ReaderChecks {
    /// Standalone entry point: `LyraReaderChecks --check-right-panel .`
    @MainActor static func rightPanelChecks(root: URL) async throws {
        try rightPanelPreferenceChecks()
        try rightPanelMotionChecks()
        try rightPanelShortcutChecks()
        try sidebarAIMigrationChecks()
        try await rightPanelWindowChecks(root: root)
    }

    // MARK: - Preferences, geometry and persistence

    @MainActor
    private static func rightPanelPreferenceChecks() throws {
        let suiteName = "lyra-reader-right-panel-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("FAIL: could not make an isolated preferences suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        require(ReaderSidePanelMetrics.defaultContentWidthPt == 320,
                "the right panel's default content width is 320 pt")
        require(ReaderSidePanelMetrics.minimumContentWidthPt == 240
                    && ReaderSidePanelMetrics.maximumContentWidthPt == 520,
                "the panel's resize range is 240...520 pt")
        require(ReaderSidePanelMetrics.totalWidth(contentWidth: 320) == 327,
                "the panel's footprint is content + 6 pt handle + 1 pt separator")
        require(!ReaderSidePanelPreferences.isVisible(defaults: defaults),
                "a fresh install starts with the panel closed")
        require(ReaderSidePanelPreferences.width(defaults: defaults) == 320,
                "a fresh install starts at the default width")

        ReaderSidePanelPreferences.store(width: 410, defaults: defaults)
        ReaderSidePanelPreferences.store(visible: true, defaults: defaults)
        require(ReaderSidePanelPreferences.width(defaults: defaults) == 410,
                "the panel width is remembered (410 pt)")
        require(ReaderSidePanelPreferences.isVisible(defaults: defaults),
                "the panel's open state is remembered")

        ReaderSidePanelPreferences.store(width: 10, defaults: defaults)
        require(ReaderSidePanelPreferences.width(defaults: defaults) == 240,
                "a stored width below the minimum is clamped up to 240 pt")
        ReaderSidePanelPreferences.store(width: 9000, defaults: defaults)
        require(ReaderSidePanelPreferences.width(defaults: defaults) == 520,
                "a stored width above the maximum is clamped down to 520 pt")

        defaults.set("not-a-number", forKey: ReaderSidePanelPreferences.widthKey)
        require(ReaderSidePanelPreferences.width(defaults: defaults) == 320,
                "an unreadable stored width falls back to the default (320 pt)")

        require(ReaderSidePanelMetrics.contentWidth(base: 320, dragTranslationX: -120) == 440,
                "dragging the inner edge 120 pt left widens the panel to 440 pt")
        require(ReaderSidePanelMetrics.contentWidth(base: 320, dragTranslationX: -9999) == 520,
                "a drag past the maximum stops at 520 pt")
        require(ReaderSidePanelMetrics.contentWidth(base: 320, dragTranslationX: 9999) == 240,
                "a drag past the minimum stops at 240 pt")
        require(ReaderSidePanelMetrics.contentWidth(base: 320, dragTranslationX: .nan) == 320,
                "a non-finite drag sample does not corrupt the width")
        require(ReaderSidePanelMetrics.clampedContentWidth(.infinity) == 320,
                "a non-finite stored width falls back to the default")

        // The same values through AppState, including a second instance reading the same suite:
        // this is the "remembered across launches" assertion, not just a defaults round-trip.
        let savedPreferenceMode = AppState.usesStoredSidePanelPreferences
        AppState.usesStoredSidePanelPreferences = true
        defer { AppState.usesStoredSidePanelPreferences = savedPreferenceMode }
        ReaderSidePanelPreferences.store(visible: false, defaults: defaults)
        let first = AppState(engine: try RustEngine(), panelDefaults: defaults)
        require(first.rightPanelWidthPt == 320 && !first.rightPanelVisible,
                "a new session reads the default width and the stored closed state")
        first.setRightPanelWidth(455)
        first.rightPanelVisible = true
        let second = AppState(engine: try RustEngine(), panelDefaults: defaults)
        require(second.rightPanelWidthPt == 455,
                "the next session remembers the 455 pt width the previous one settled on")
        require(second.rightPanelVisible,
                "the next session remembers that the panel was open")
        second.setRightPanelWidth(1000)
        require(second.rightPanelWidthPt == 520,
                "the state clamps the maximum width to 520 pt")
        second.setRightPanelWidth(0)
        require(second.rightPanelWidthPt == 240,
                "the state clamps the minimum width to 240 pt")

        let trailing = ReaderChrome.trailingChromeWidth(
            documentOpen: true, pageOverviewVisible: false,
            searchVisible: false, rightPanelVisible: true, rightPanelContentWidth: 320
        )
        require(trailing == 327,
                "with only the right panel open, the secondary row covers the scroll lane "
                    + "(\(trailing) pt)")
        let withSearch = ReaderChrome.trailingChromeWidth(
            documentOpen: true, pageOverviewVisible: false,
            searchVisible: true, rightPanelVisible: true, rightPanelContentWidth: 320
        )
        require(withSearch == trailing + ReaderChrome.sidebarTotalWidthPt,
                "search results sit between the canvas and the right panel")
        require(ReaderChrome.trailingChromeWidth(
            documentOpen: true, pageOverviewVisible: true,
            searchVisible: true, rightPanelVisible: true, rightPanelContentWidth: 320
        ) == 0, "page overview draws over the whole content area")
    }

    // MARK: - Motion and shortcuts

    @MainActor
    private static func rightPanelMotionChecks() throws {
        let savedReduceMotion = ReaderMotion.reduceMotionOverride
        defer { ReaderMotion.reduceMotionOverride = savedReduceMotion }

        require((0.18...0.25).contains(ReaderMotion.panelDuration),
                "the panel timing is inside the requested 0.18-0.25 s "
                    + "(\(ReaderMotion.panelDuration) s)")
        require(ReaderMotion.panelDuration == ReaderMotion.sidebarDuration,
                "the panel uses the same duration language as the left sidebar")
        ReaderMotion.reduceMotionOverride = false
        require(ReaderMotion.panelAnimation != nil,
                "the panel animates when Reduce Motion is off")
        ReaderMotion.reduceMotionOverride = true
        require(ReaderMotion.panelAnimation == nil,
                "Reduce Motion removes the panel animation")
        ReaderMotion.reduceMotionOverride = false
    }

    @MainActor
    private static func rightPanelShortcutChecks() throws {
        require(String(ReaderShortcuts.toggleAIPanelKey.character) == "a",
                "the AI panel command is bound to A")
        require(ReaderShortcuts.toggleAIPanelModifiers == [.command, .shift],
                "the AI panel command uses ⇧⌘A")
        require(ReaderShortcuts.toggleAIPanelLabel == "Toggle AI Assistant",
                "the menu command is named Toggle AI Assistant")

        // The chords already on ReaderCommands, the toolbar menus and the Rust keymap. A new
        // shortcut has to be absent from every one of them.
        let taken: [(name: String, key: Character, modifiers: EventModifiers)] = [
            ("Open", "o", [.command]),
            ("Save", "s", [.command]),
            ("Save and Replace", "s", [.command, .shift]),
            ("Export", "e", [.command]),
            ("Print", "p", [.command]),
            ("Document Information", "i", [.command, .option]),
            ("Actual Size", "0", [.command]),
            ("Fit Width", "9", [.command]),
            ("Fit Page", "9", [.command, .shift]),
            ("Zoom In", "+", [.command]),
            ("Zoom Out", "-", [.command]),
            ("Back", "[", [.command]),
            ("Forward", "]", [.command]),
            ("Find Next", "g", [.command]),
            ("Find Previous", "g", [.command, .shift]),
            ("Toggle Sidebar", "s", [.command, .option]),
            ("Add Bookmark", "d", [.command]),
            ("Copy BibTeX", "b", [.command, .shift]),
            ("Continuous", "1", [.command]),
            ("Facing", "3", [.command]),
            ("Redact Tool", "r", [.command, .shift]),
            ("Mark Redaction", "r", [.command, .option]),
        ]
        let newKey = String(ReaderShortcuts.toggleAIPanelKey.character)
        let newModifiers = ReaderShortcuts.toggleAIPanelModifiers
        for shortcut in taken {
            require(!(String(shortcut.key) == newKey && shortcut.modifiers == newModifiers),
                    "⇧⌘A does not collide with \(shortcut.name)")
        }
    }

    // MARK: - Sidebar tab migration

    @MainActor
    private static func sidebarAIMigrationChecks() throws {
        require(!SidebarTab.sidebarPickerTabs.contains(where: { $0.title == "AI" }),
                "the left sidebar's picker no longer offers an AI tab")
        require(SidebarTab.sidebarPickerTabs.count == 4,
                "the picker still has exactly four tabs: bookmarks, outline, annotations, "
                    + "thumbnails")
        require(SidebarTab.sidebarPickerTabs.allSatisfy(\.isSidebarPickerTab),
                "every picker entry resolves to a valid tab")
        require(SidebarTab(rawValue: "ai") == nil,
                "the removed AI tab no longer decodes from a persisted raw value")

        let suiteName = "lyra-reader-sidebar-tab-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("FAIL: could not make an isolated preferences suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("ai", forKey: SidebarTab.persistedKey)
        let migrated = SidebarTab.restored(defaults: defaults)
        require(migrated == .thumbnails,
                "a persisted AI tab falls back to Thumbnails instead of an empty sidebar")
        require(defaults.string(forKey: SidebarTab.persistedKey) == SidebarTab.thumbnails.rawValue,
                "the fallback is written back so the invalid value is not retried every launch")

        defaults.set(SidebarTab.annotations.rawValue, forKey: SidebarTab.persistedKey)
        require(SidebarTab.restored(defaults: defaults) == .annotations,
                "a valid persisted tab is restored")

        defaults.set(SidebarTab.search.rawValue, forKey: SidebarTab.persistedKey)
        require(SidebarTab.restored(defaults: defaults) == .thumbnails,
                "a persisted value that is not a picker tab also falls back to a valid tab")
    }

    // MARK: - The hosted window

    @MainActor
    private static func rightPanelWindowChecks(root: URL) async throws {
        _ = NSApplication.shared
        // Pin motion for this window suite rather than inheriting the machine's setting. The
        // animation checks need to know whether a toggle animates; the Reduce Motion section
        // below sets its own value and the defer restores whatever the process had.
        let savedReduceMotion = ReaderMotion.reduceMotionOverride
        ReaderMotion.reduceMotionOverride = false
        defer { ReaderMotion.reduceMotionOverride = savedReduceMotion }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-reader-right-panel-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = scratch.appendingPathComponent("multipage.pdf")
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("tests/fixtures/multipage.pdf"), to: fixture)

        let state = AppState(engine: try RustEngine())
        require(state.open(url: fixture), "the right-panel fixture opens")
        state.setDisplayCalibration(.uncalibratedDefault)
        let aiSuiteName = "lyra-reader-right-panel-ai-\(UUID().uuidString)"
        let aiDefaults = UserDefaults(suiteName: aiSuiteName)!
        aiDefaults.removePersistentDomain(forName: aiSuiteName)
        defer { aiDefaults.removePersistentDomain(forName: aiSuiteName) }
        let aiModel = AIAssistantModel(settings: AISettingsStore(
            defaults: aiDefaults, keyStore: InMemoryAPIKeyStore(key: nil)))

        // First layout: a session restored with the panel already open must get the full drawer
        // at once. The transaction that animates a *toggle* must not animate the initial state.
        let firstLayoutState = AppState(engine: try RustEngine())
        require(firstLayoutState.open(url: fixture), "the first-layout fixture opens")
        firstLayoutState.setRightPanelWidth(360)
        firstLayoutState.rightPanelVisible = true
        let firstLayoutHarness = RightPanelHarness(state: firstLayoutState, aiAssistant: aiModel)
        try await firstLayoutHarness.mount()
        let firstLayoutWidth = firstLayoutHarness.panelTotalWidth
        require(abs(firstLayoutWidth
                    - ReaderSidePanelMetrics.totalWidth(contentWidth: 360)) < 0.5,
                "a panel restored open lays out at its full 360 pt width on first layout, "
                    + "without an opening animation (measured \(firstLayoutWidth) pt)")
        firstLayoutHarness.close()

        let harness = RightPanelHarness(state: state, aiAssistant: aiModel)
        defer { harness.close() }
        try await harness.mount()

        try await eventually("the right panel starts closed", {
            abs(harness.panelTotalWidth) < 0.5
        })
        require(abs(harness.panelContentWidth) < 0.5,
                "a closed panel takes no content width (measured \(harness.panelContentWidth) pt)")
        require(!state.rightPanelVisible, "a new reader session starts with the panel closed")

        // The panel opens from the menu/state path. Measure the drawer, not just the boolean.
        state.toggleRightPanel()
        require(state.rightPanelVisible, "the toggle opens the panel")
        try await eventually("the open panel lays out at its 320 pt width", {
            abs(harness.panelContentWidth - ReaderSidePanelMetrics.defaultContentWidthPt) < 0.5
        })
        let openFootprint = harness.panelTotalWidth
        require(abs(openFootprint - ReaderSidePanelMetrics.totalWidth(contentWidth: 320)) < 0.5,
                "the open panel's footprint is 327 pt (measured \(openFootprint) pt)")
        try await eventually("the canvas reports the width the panel left it", {
            abs(state.canvasViewportWidthPt - harness.canvasRect.width) < 0.5
        })

        // The AI view is the panel's content, not a copy of it or a placeholder: the assistant's
        // own marker view is in the AppKit hierarchy, and its scrolling content is an NSScrollView
        // inside the panel's region.
        require(containsAIAssistantPanelMarker(in: harness.host),
                "the right panel hosts the AI assistant view itself (marker present)")
        require(nativeScrollViewCount(in: harness.host) > 0,
                "the AI view's scrolling content is present in the panel")
        if let marker = findAIAssistantPanelMarker(in: harness.host) {
            let markerRect = harness.host.convert(marker.bounds, from: marker)
            require(markerRect.minX >= harness.canvasRect.maxX - harness.panelTotalWidth - 0.5,
                    "the AI view is inside the trailing overlay (marker x=\(markerRect.minX) pt)")
        } else {
            require(false, "the AI assistant marker has a measurable frame")
        }

        // ── Opening mid-document does not move the page ─────────────────────────────────
        state.gotoPage(1)
        try await eventually("the mid-document page has placements", {
            state.currentPage == 2 && state.canvasPageFrames.contains { $0.index == 1 }
        })
        state.scroll(byScreenPoints: 90)
        try await Task.sleep(for: .milliseconds(80))
        guard let pageTopBefore = harness.pageTopInHost(page: 1) else {
            fatalError("FAIL: page 2 has no on-screen top before the panel opens")
        }
        let scrollBefore = state.scrollYPt
        state.transitionProgressOverride = ReaderTransitionProgress(panel: 0)
        state.rightPanelVisible = false
        try await eventually("the pinned closed panel lays out", {
            abs(harness.panelTotalWidth) < 0.5
        })
        state.rightPanelVisible = true
        var pageTops: [CGFloat] = []
        var scrollOffsets: [CGFloat] = []
        var panelWidths: [CGFloat] = []
        for progress in stride(from: 0.0, through: 1.0, by: 0.25) {
            state.transitionProgressOverride = ReaderTransitionProgress(panel: progress)
            let expected = ReaderSidePanelMetrics.totalWidth(contentWidth: 320) * CGFloat(progress)
            try await eventually("the panel lays out at progress \(progress)", {
                abs(harness.panelTotalWidth - expected) < 1.0
            })
            panelWidths.append(harness.panelTotalWidth)
            scrollOffsets.append(state.scrollYPt)
            if let top = harness.pageTopInHost(page: 1) { pageTops.append(top) }
        }
        require(panelWidths.contains { $0 > 20 && $0 < 300 },
                "at least one pinned frame is partly open (widths \(panelWidths.map { Int($0) }))")
        require(zip(panelWidths, panelWidths.dropFirst()).allSatisfy { $0 < $1 },
                "the pinned open moves monotonically from closed to open")
        require(scrollOffsets.allSatisfy { abs($0 - scrollBefore) < 0.001 },
                "the scroll offset stays at \(scrollBefore) pt while the panel opens")
        require(pageTops.count == panelWidths.count
                    && pageTops.allSatisfy { abs($0 - pageTopBefore) < 0.01 },
                "the page's on-screen top stays at \(pageTopBefore) pt while the panel opens (\(pageTops))")

        // The mirror image: pin the close from open to closed and keep measuring the same page.
        state.rightPanelVisible = false
        var closingTops: [CGFloat] = []
        var closingScrolls: [CGFloat] = []
        var closingWidths: [CGFloat] = []
        for progress in stride(from: 1.0, through: 0.0, by: -0.25) {
            state.transitionProgressOverride = ReaderTransitionProgress(panel: progress)
            let expected = ReaderSidePanelMetrics.totalWidth(contentWidth: 320) * CGFloat(progress)
            try await eventually("the close lays out at progress \(progress)", {
                abs(harness.panelTotalWidth - expected) < 1.0
            })
            closingWidths.append(harness.panelTotalWidth)
            closingScrolls.append(state.scrollYPt)
            if let top = harness.pageTopInHost(page: 1) { closingTops.append(top) }
        }
        require(zip(closingWidths, closingWidths.dropFirst()).allSatisfy { $0 > $1 },
                "the pinned close moves monotonically from open to closed")
        require(closingScrolls.allSatisfy { abs($0 - scrollBefore) < 0.001 },
                "the scroll offset stays at \(scrollBefore) pt while the panel closes")
        require(closingTops.count == closingWidths.count
                    && closingTops.allSatisfy { abs($0 - pageTopBefore) < 0.01 },
                "the page's on-screen top stays at \(pageTopBefore) pt while the panel closes")
        state.transitionProgressOverride = nil
        state.rightPanelVisible = true
        try await eventually("the panel finishes opening at 320 pt", {
            abs(harness.panelContentWidth - 320) < 0.5
        })

        // ── Fit Width fits the canvas, not the window ───────────────────────────────────
        try await eventually("the canvas viewport follows the settled panel", {
            abs(state.canvasViewportWidthPt - harness.canvasRect.width) < 0.5
        })
        let pageWidth = state.document?.firstPageSize.width ?? 0
        let canvasWidth = harness.canvasRect.width
        let calibration = state.displayCalibration.factor
        let available = canvasWidth - 2 * AppState.zoomPresetInsetPt
        require(pageWidth > 0 && available > 0,
                "the fit-width fixture has a measurable page and canvas (\(pageWidth) pt page, "
                    + "\(canvasWidth) pt canvas, calibration \(calibration))")
        state.zoomFitWidth()
        let expectedCanvasPercent = min(
            AppState.maximumZoomPercent,
            max(AppState.minimumZoomPercent,
                Int((available / (pageWidth * calibration) * 100).rounded(.down)))
        )
        require(state.zoomPercent == expectedCanvasPercent,
                "Fit Width uses the \(Int(canvasWidth)) pt canvas: \(state.zoomPercent)% "
                    + "(expected \(expectedCanvasPercent)%)")
        let fittedWidthPt = pageWidth * state.zoomFactor
        require(fittedWidthPt <= available + 0.5,
                "the fitted page (\(fittedWidthPt) pt) does not overflow the canvas "
                    + "(\(available) pt available)")
        require(fittedWidthPt >= available - pageWidth * calibration / 100,
                "the fitted page fills the canvas to within the integer percentage step")
        let windowAvailable = harness.host.bounds.width - 2 * AppState.zoomPresetInsetPt
        let windowPercent = min(
            AppState.maximumZoomPercent,
            max(AppState.minimumZoomPercent,
                Int((windowAvailable / (pageWidth * calibration) * 100).rounded(.down)))
        )
        require(windowPercent != expectedCanvasPercent,
                "the canvas number differs from a window-width fit "
                    + "(\(expectedCanvasPercent)% vs \(windowPercent)%)")

        // Fit Page still runs after the width change, and its horizontal extent remains inside
        // the canvas. (Its fit axis is the height; the check is that the narrower canvas did not
        // make the page overflow sideways.)
        state.zoomFitPage()
        require(state.statusMessage.contains("Fit page"),
                "Fit Page runs through the canvas viewport after the panel opened "
                    + "(\(state.statusMessage))")
        let fittedCanvasWidth = pageWidth * state.zoomFactor
        require(fittedCanvasWidth <= canvasWidth + 0.5,
                "Fit Page's horizontal extent stays inside the canvas "
                    + "(\(fittedCanvasWidth) pt of \(canvasWidth) pt)")

        // ── Both panels open: the canvas is exactly what is left ────────────────────────
        state.sidebarVisible = true
        state.transitionProgressOverride = nil
        try await eventually("both panels are settled open", {
            abs(harness.panelTotalWidth
                - ReaderSidePanelMetrics.totalWidth(contentWidth: state.rightPanelWidthPt)) < 0.5
                && abs(harness.canvasRect.minX - ReaderChrome.sidebarTotalWidthPt) < 0.5
        })
        let expectedCanvas = harness.host.bounds.width
            - ReaderChrome.sidebarTotalWidthPt
            - ReaderChrome.scrollIndicatorLaneWidthPt
            - harness.panelTotalWidth
        require(abs(harness.canvasRect.width - expectedCanvas) < 0.5,
                "both panels open: canvas width \(harness.canvasRect.width) pt = window "
                    + "\(harness.host.bounds.width) - sidebar \(ReaderChrome.sidebarTotalWidthPt) "
                    + "- indicator \(ReaderChrome.scrollIndicatorLaneWidthPt) - panel \(harness.panelTotalWidth) pt")
        require(abs(state.canvasViewportWidthPt - expectedCanvas) < 0.5,
                "the canvas viewport equals the same number (\(state.canvasViewportWidthPt) pt)")
        require(harness.canvasRect.minX >= ReaderChrome.sidebarTotalWidthPt - 0.5,
                "the canvas starts after the left sidebar (x=\(harness.canvasRect.minX) pt)")
        require(abs(harness.canvasRect.maxX + ReaderChrome.scrollIndicatorLaneWidthPt
                    + harness.panelTotalWidth
                    - harness.host.bounds.width) < 0.5,
                "the scroll lane separates the document viewport from the right panel")
        require(abs(harness.panelTotalWidth
                    - ReaderSidePanelMetrics.totalWidth(contentWidth: 320)) < 0.5,
                "the two panels coexist without either changing the other's width")

        // ── Resize clamps and the settled canvas ───────────────────────────────────────
        state.setRightPanelWidth(10)
        require(state.rightPanelWidthPt == 240,
                "dragging to the minimum clamps the panel at 240 pt")
        try await eventually("the 240 pt panel settles into the layout", {
            abs(harness.panelContentWidth - 240) < 0.5
        })
        var expectedResizedCanvas = harness.host.bounds.width
            - ReaderChrome.sidebarTotalWidthPt
            - ReaderChrome.scrollIndicatorLaneWidthPt
            - harness.panelTotalWidth
        require(abs(harness.canvasRect.width - expectedResizedCanvas) < 0.5,
                "the canvas follows the minimum width (\(harness.canvasRect.width) pt)")
        require(abs(state.canvasViewportWidthPt - expectedResizedCanvas) < 0.5,
                "the canvas viewport follows the minimum width too")

        state.setRightPanelWidth(10_000)
        require(state.rightPanelWidthPt == 520,
                "dragging to the maximum clamps the panel at 520 pt")
        try await eventually("the 520 pt panel settles into the layout", {
            abs(harness.panelContentWidth - 520) < 0.5
        })
        expectedResizedCanvas = harness.host.bounds.width
            - ReaderChrome.sidebarTotalWidthPt
            - ReaderChrome.scrollIndicatorLaneWidthPt
            - harness.panelTotalWidth
        require(abs(harness.canvasRect.width - expectedResizedCanvas) < 0.5,
                "the canvas follows the maximum width (\(harness.canvasRect.width) pt)")
        require(expectedResizedCanvas > 100,
                "even at 520 pt there is a usable canvas at this window width")
        let windowFrameBeforeResize = harness.window.frame
        state.setRightPanelWidth(320)
        try await eventually("the panel returns to 320 pt", {
            abs(harness.panelContentWidth - 320) < 0.5
        })
        require(harness.window.frame == windowFrameBeforeResize,
                "changing the panel width does not resize the window")

        // ── The slide is cheap ─────────────────────────────────────────────────────────
        // Zoom out until the page is narrower than every canvas width in the slide. Then a
        // width-only change cannot alter the visible band at all: no band rebuild, no raster.
        state.zoomPercent = 25
        state.reloadVisiblePages()
        try await eventually("the cheap-slide fixture has a page raster", {
            state.pageRasterCacheCount > 0
        })
        // A text layer or a raster arriving during the 11 sampled frames also re-evaluates the
        // band (`viewportReloadCount` moves for that reason too, see AppState). Wait until the
        // visible pages' text layers are in and the counter has stopped moving, so the sample
        // measures the panel slide rather than unrelated late background work.
        try await eventually("the cheap-slide pages have their text layers", {
            state.canvasPageFrames.allSatisfy { state.hasTextLayer($0.index) }
        })
        var lastReloadCount = -1
        var stableSamples = 0
        while stableSamples < 5 {
            if state.viewportReloadCount == lastReloadCount {
                stableSamples += 1
            } else {
                stableSamples = 0
                lastReloadCount = state.viewportReloadCount
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(150))
        let reloadsBefore = state.viewportReloadCount
        let rastersBefore = state.pageRasterCacheCount
        let canvasBeforeSlide = harness.liveCanvas
        let windowBeforeSlide = harness.window.frame
        state.rightPanelVisible = false
        try await eventually("the panel closes for the cost sample", {
            abs(harness.panelTotalWidth) < 0.5
        })
        state.transitionProgressOverride = ReaderTransitionProgress(panel: 0)
        state.rightPanelVisible = true
        var slideCanvasWidths: [CGFloat] = []
        for step in 0...10 {
            state.transitionProgressOverride = ReaderTransitionProgress(panel: Double(step) / 10)
            // Let the hosted view apply this frame. Without a turn of the run loop the state
            // changes pile up and the viewport below is still the one from before the slide,
            // which would make "no rebuild" true by not laying anything out.
            try await Task.sleep(for: .milliseconds(20))
            slideCanvasWidths.append(harness.canvasRect.width)
            harness.canvasRect
        }
        state.transitionProgressOverride = ReaderTransitionProgress(panel: 1)
        try await Task.sleep(for: .milliseconds(80))
        require((slideCanvasWidths.first ?? 0) - (slideCanvasWidths.last ?? 0) > 300,
                "opening the panel smoothly reserves its width in the document viewport "
                    + "(\(slideCanvasWidths.first ?? 0) -> \(slideCanvasWidths.last ?? 0) pt)")
        require(state.viewportReloadCount == reloadsBefore,
                "a width-only panel open performs no visible-band rebuild per frame "
                    + "(\(reloadsBefore) before and after 11 laid-out frames)")
        require(state.pageRasterCacheCount == rastersBefore,
                "a width-only panel open requests no page raster per frame")
        require(harness.liveCanvas === canvasBeforeSlide && harness.window.frame == windowBeforeSlide,
                "opening AI preserves the Metal view instance and the window frame")
        state.transitionProgressOverride = nil
        try await Task.sleep(for: .milliseconds(120))

        // Resizing is also width-only: sweep the whole range without rebuilding the band. The
        // begin/end pair is what the drag gesture calls, so this measures the production path.
        let reloadsBeforeResize = state.viewportReloadCount
        let coalescedBeforeResize = state.coalescedViewportReloadCount
        let rastersBeforeResize = state.pageRasterCacheCount
        state.beginRightPanelResize()
        for width in stride(from: CGFloat(240), through: 520, by: 20) {
            state.resizeRightPanel(to: width)
            try await Task.sleep(for: .milliseconds(20))
            harness.canvasRect
        }
        state.endRightPanelResize()
        state.commitRightPanelWidth()
        try await Task.sleep(for: .milliseconds(300))
        require(state.coalescedViewportReloadCount == coalescedBeforeResize,
                "resizing the panel does not rebuild the visible band per step")
        require(state.viewportReloadCount == reloadsBeforeResize,
                "the resize's settled state adds no band rebuild when the page fits")
        require(state.pageRasterCacheCount == rastersBeforeResize,
                "resizing the panel does not re-raster pages per step")

        // At a zoom where the page is wider than the canvas, the visible columns can change.
        // The movement holds those updates and releases exactly one rebuild when it ends.
        state.zoomPercent = 300
        state.reloadVisiblePages()
        try await Task.sleep(for: .milliseconds(400))
        let zoomedReloads = state.coalescedViewportReloadCount
        state.beginRightPanelResize()
        for width in stride(from: CGFloat(240), through: 520, by: 20) {
            state.resizeRightPanel(to: width)
            try await Task.sleep(for: .milliseconds(20))
            harness.canvasRect
        }
        require(state.coalescedViewportReloadCount == zoomedReloads,
                "a zoomed-in drawer defers visible-column rebuilds throughout the drag")
        state.endRightPanelResize()
        try await Task.sleep(for: .milliseconds(350))
        let coalesced = state.coalescedViewportReloadCount - zoomedReloads
        require(coalesced <= 1,
                "a zoomed-in drawer releases at most one rebuild after the drag "
                    + "(\(coalesced) rebuilds for 15 width updates)")

        // A real (not pinned) animated close and open at the same zoom: the state holds the
        // per-frame viewport reports for the animation and releases them once. The wait covers
        // the animation, its tail, and the deferred rebuild.
        let beforeAnimatedClose = state.coalescedViewportReloadCount
        state.rightPanelVisible = false
        try await eventually("the real animated overlay closes", {
            harness.panelTotalWidth < 0.5
        })
        try await Task.sleep(for: .milliseconds(120))
        let animatedCloseReloads = state.coalescedViewportReloadCount - beforeAnimatedClose
        require(animatedCloseReloads == 0,
                "closing the overlay keeps the PDF band unchanged "
                    + "(\(animatedCloseReloads) rebuilds, not one per frame)")
        let beforeAnimatedOpen = state.coalescedViewportReloadCount
        state.rightPanelVisible = true
        try await eventually("the real animated overlay opens", {
            abs(harness.panelContentWidth - state.rightPanelWidthPt) < 0.5
        })
        try await Task.sleep(for: .milliseconds(120))
        let animatedOpenReloads = state.coalescedViewportReloadCount - beforeAnimatedOpen
        require(animatedOpenReloads == 0,
                "opening the overlay keeps the PDF band unchanged "
                    + "(\(animatedOpenReloads) rebuilds, not one per frame)")

        // ── Reduce Motion ──────────────────────────────────────────────────────────────
        state.transitionProgressOverride = nil
        state.setRightPanelWidth(320)
        state.rightPanelVisible = true
        try await Task.sleep(for: .milliseconds(300))
        ReaderMotion.reduceMotionOverride = true
        state.rightPanelVisible = false
        try await Task.sleep(for: .milliseconds(80))
        require(abs(harness.panelTotalWidth) < 0.5,
                "with Reduce Motion on, closing the panel is immediate "
                    + "(\(harness.panelTotalWidth) pt after 80 ms)")
        state.rightPanelVisible = true
        try await Task.sleep(for: .milliseconds(80))
        require(abs(harness.panelTotalWidth
                    - ReaderSidePanelMetrics.totalWidth(contentWidth: 320)) < 0.5,
                "with Reduce Motion on, opening the panel is immediate "
                    + "(\(harness.panelTotalWidth) pt after 80 ms)")
        ReaderMotion.reduceMotionOverride = false

        // ── No animation during a live window resize ───────────────────────────────────
        state.rightPanelVisible = false
        try await eventually("the panel is closed before the live resize", {
            abs(harness.panelTotalWidth) < 0.5
        })
        NotificationCenter.default.post(
            name: NSWindow.willStartLiveResizeNotification, object: harness.window)
        try await Task.sleep(for: .milliseconds(80))
        state.rightPanelVisible = true
        try await Task.sleep(for: .milliseconds(120))
        require(abs(harness.panelTotalWidth
                    - ReaderSidePanelMetrics.totalWidth(contentWidth: 320)) < 0.5,
                "a toggle during a live window resize is at the open endpoint after 120 ms "
                    + "(\(harness.panelTotalWidth) pt; an animated one would be part-way)")
        NotificationCenter.default.post(
            name: NSWindow.didEndLiveResizeNotification, object: harness.window)
        try await Task.sleep(for: .milliseconds(80))
        require(ReaderMotion.panelAnimation != nil,
                "the panel animation is available again after the live resize")

        // ── Rapid toggles settle ───────────────────────────────────────────────────────
        for _ in 0..<5 {
            state.rightPanelVisible.toggle()
            try await Task.sleep(for: .milliseconds(15))
        }
        state.rightPanelVisible = false
        _ = try await harness.samplePanelWidths(for: 0.50)
        try await eventually("a burst of panel toggles ends closed, not half open", {
            abs(harness.panelTotalWidth) < 0.5
        })
        require(!state.rightPanelVisible,
                "the burst leaves the state closed (rightPanelVisible=\(state.rightPanelVisible))")

        // Keep the Metal textures as well as the CPU bitmaps when a drawer covers them.
        // Wait for raster/text arrivals to settle before sampling the actual submitted IDs.
        var stableRasters = 0
        var lastRasters = -1
        for _ in 0..<100 {
            let count = state.tileRasterCount
            stableRasters = count == lastRasters ? stableRasters + 1 : 0
            lastRasters = count
            if stableRasters >= 10 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let screenBottom = state.scrollYPt + harness.canvasRect.height / state.zoomFactor
        let visibleIDs = Set(state.canvasPages.filter {
            $0.placement.index >= 0 && $0.placement.topPt < screenBottom
                && $0.placement.topPt + $0.placement.heightPt > state.scrollYPt
        }.map { $0.placement.index })
        let texturesBefore = harness.canvas.residentTextureIDs.filter { visibleIDs.contains($0.key) }
        require(!texturesBefore.isEmpty, "deep zoom has resident sharp textures before drawer cover")
        state.transitionProgressOverride = ReaderTransitionProgress(panel: 1)
        state.rightPanelVisible = true
        try await Task.sleep(for: .milliseconds(500))
        require(texturesBefore.allSatisfy { harness.canvas.residentTextureIDs[$0.key] == $0.value },
                "opening the drawer keeps every previously visible sharp GPU texture")
        state.rightPanelVisible = false
        state.transitionProgressOverride = ReaderTransitionProgress(panel: 0)
        try await Task.sleep(for: .milliseconds(500))
        require(texturesBefore.allSatisfy { harness.canvas.residentTextureIDs[$0.key] == $0.value },
                "closing the drawer reveals the same textures without re-upload")

        state.transitionProgressOverride = ReaderTransitionProgress(row: 1, panel: 0, editingPanel: 1)
        state.toggleContentEditing()
        require(state.contentEditEnabled && !state.rightPanelVisible, "Edit closes the AI overlay")
        func chromeRect(_ kind: ReaderChromeMarkerView.Kind) -> CGRect? {
            func find(_ view: NSView) -> ReaderChromeMarkerView? {
                if let found = view as? ReaderChromeMarkerView, found.kind == kind { return found }
                return view.subviews.lazy.compactMap { find($0) }.first
            }
            harness.host.layoutSubtreeIfNeeded()
            guard let marker = find(harness.host) else { return nil }
            return harness.host.convert(marker.bounds, from: marker)
        }
        try await eventually("the edit inspector and secondary row have measurable frames", {
            (chromeRect(.editingInspector)?.width ?? 0) > 290
                && (chromeRect(.secondaryToolbar)?.height ?? 0) > 45
        })
        let row = chromeRect(.secondaryToolbar)!
        let inspector = chromeRect(.editingInspector)!
        require(abs(row.maxX - inspector.minX) < 0.5,
                "the secondary toolbar covers the scroll track and meets the inspector without a gap")
        require(abs(inspector.maxY - harness.canvasRect.maxY) < 0.5,
                "the inspector begins at the content top without a toolbar-height blank strip")
        state.contentTextRecovery = "Preserve this draft"
        state.toggleRightPanel()
        require(state.contentEditEnabled && !state.rightPanelVisible,
                "a recovered draft blocks panel switching until it is resolved")
        state.discardContentTextRecovery()
        state.toggleRightPanel()
        require(state.rightPanelVisible && !state.contentEditEnabled, "AI closes the Edit inspector")
        state.toggleContentEditing()
        require(!state.rightPanelVisible && state.contentEditEnabled, "opening Edit again closes AI")

        print("Right-panel checks passed")
    }

    // MARK: - Accessibility helpers

    @MainActor
    private static func findAIAssistantPanelMarker(
        in view: NSView
    ) -> AIAssistantPanelMarkerView? {
        if let marker = view as? AIAssistantPanelMarkerView { return marker }
        return view.subviews.lazy.compactMap { findAIAssistantPanelMarker(in: $0) }.first
    }

    @MainActor
    private static func containsAIAssistantPanelMarker(in view: NSView) -> Bool {
        findAIAssistantPanelMarker(in: view) != nil
    }

    @MainActor
    private static func nativeScrollViewCount(in view: NSView) -> Int {
        (view as? NSScrollView).map { _ in 1 } ?? view.subviews.reduce(0) {
            $0 + nativeScrollViewCount(in: $1)
        }
    }
}
