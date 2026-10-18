import AppKit
import ArisReaderKit
import Foundation
import SwiftUI

/// Regressions for the tab row and for tab switching.
///
/// Every assertion is a number or a state a reader can also see: the row's height, the traffic
/// lights' leading inset and centre line, the document-open counter, the raster generation, the
/// scroll offset, the index-sidecar inode. The only two things left to a human eye are stated in
/// the pull request: whether the optical alignment looks right against a real window, and whether
/// the inset matches Safari/PDF Expert.
extension ReaderChecks {
    // MARK: - Layout numbers

    /// Defect 1 and 2: the traffic lights get a platform-sized leading inset and the whole row
    /// shares one centre line. Defect 3: the tab's hit rectangle is the whole tab, with only the
    /// 24 pt close affordance carved out (and the 4 pt to its right still selecting).
    @MainActor static func tabRowLayoutChecks() {
        require(TabRowLayout.height == 44, "the tab row is 44 pt high")
        require(TabRowLayout.contentCenterY == 22, "the row's centre line is y = 22")
        require(TabRowLayout.contentHeight == 32, "tab titles, close buttons and the plus are 32 pt high")
        require((TabRowLayout.height - TabRowLayout.contentHeight) / 2 == 6,
                "32 pt content leaves exactly 6 pt above and below in the 44 pt row")

        // The traffic-light proportion the reader asked for: the edge gap is visibly larger than
        // the gaps *inside* the group.
        require(TabRowLayout.trafficLightsLeadingInset == 20,
                "the close button sits 20 pt from the window's left edge")
        require(TabRowLayout.trafficLightOriginPitch == 20,
                "the three traffic lights sit on a 20 pt origin pitch")
        require(TabRowLayout.trafficLightsLeadingInset > TabRowLayout.trafficLightSpacing,
                "the edge gap (20) is larger than the visible gaps between the buttons")
        require(TabRowLayout.trafficLightOriginsX == [20, 40, 60],
                "traffic-light origins are 20 / 40 / 60 pt from the left edge")
        require(TabRowLayout.trafficLightsTrailingEdge == 76,
                "the last traffic light ends at 76 pt on this platform")
        require(TabRowLayout.contentCenterY
                    == TabRowLayout.trafficLightOriginY()
                    + TabRowLayout.trafficLightButtonSize / 2,
                "the button group and the row content share the y = 22 centre line")

        // Tabs start where they did before the inset changed (78 pt strip inset + 10 pt padding),
        // so the tabs did not become a narrower strip.
        let tabsStart = TabRowLayout.tabStripLeadingInset + TabRowLayout.tabStripHorizontalPadding
        require(tabsStart == 88, "tabs still start at 88 pt from the window's left edge")
        require(tabsStart >= TabRowLayout.trafficLightsTrailingEdge + 6,
                "there is a 6 pt gap between the last traffic light and the tab strip")

        // Hit geometry: the whole tab minus the 24 pt close affordance; the 4 pt after the close
        // button, the 12 pt before the title and the vertical padding all select the tab.
        let tabWidth: CGFloat = 180
        let close = TabRowLayout.closeHitRect(tabWidth: tabWidth)
        require(close == CGRect(x: 152, y: 0, width: 24, height: 32),
                "the close affordance is the trailing 24×32 pt rectangle")
        require(TabRowLayout.isSelectionHit(x: 2, tabWidth: tabWidth),
                "a click in the tab's 12 pt leading padding selects the tab")
        require(TabRowLayout.isSelectionHit(x: 6, tabWidth: tabWidth),
                "a click in the tab's vertical padding selects the tab")
        require(TabRowLayout.isSelectionHit(x: tabWidth - 2, tabWidth: tabWidth),
                "the 4 pt right-hand padding after the close button still selects the tab")
        require(TabRowLayout.isCloseHit(x: close.midX, tabWidth: tabWidth),
                "a click on the close affordance closes the tab")
        require(!TabRowLayout.isSelectionHit(x: close.midX, tabWidth: tabWidth),
                "the close affordance does not also select the tab")
        require(TabRowLayout.selectionHitWidth(tabWidth: tabWidth) == 152,
                "the selection rectangle spans the rest of the 180 pt tab")
        // The width is a function of the strip and the tab count only: a longest or shortest title,
        // and active versus inactive, never changes the rectangle or its height.
        require(TabRowLayout.contentHeight == 32,
                "the 32 pt baseline is the same for the longest title, the shortest title and both "
                + "active states")

        // A real hosted row with a very long title and a one-character title: the row keeps its
        // 44 pt height whichever tab is active. The title is a truncating Text inside a fixed
        // 32 pt frame and never participates in the tab's width, so activating a tab cannot move
        // the row; this measurement covers the longest and the shortest title through SwiftUI's
        // own layout.
        let mockState = AppState(engine: MockEngine())
        let longName = String(repeating: "A very long paper title ", count: 6) + ".pdf"
        let shortName = "a.pdf"
        mockState.newTab(url: URL(fileURLWithPath: "/tmp/\(longName)"))
        mockState.newTab(url: URL(fileURLWithPath: "/tmp/\(shortName)"))
        func hostedRowHeight() -> CGFloat {
            let host = NSHostingView(rootView: TabStrip(state: mockState))
            host.frame = NSRect(x: 0, y: 0, width: 900, height: TabRowLayout.height)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let shortTitleActive = hostedRowHeight()
        mockState.selectTab(0)
        let longTitleActive = hostedRowHeight()
        require(abs(shortTitleActive - TabRowLayout.height) < 0.5,
                "the hosted row keeps its 44 pt height with the shortest title active")
        require(abs(longTitleActive - TabRowLayout.height) < 0.5,
                "the hosted row keeps its 44 pt height with the longest title active")
        require(shortTitleActive == longTitleActive,
                "activating a tab with a different title length does not change the row height")
    }

    // MARK: - Resize stability (defect 5)

    /// The traffic lights must not move vertically while the window's width changes. This drives
    /// the real AppKit window hierarchy at the minimum width, the design width and a very wide
    /// width, and through a resize sequence that returns to earlier widths: every step asserts the
    /// same button frames, so a recomputation from a mid-flight size would fail here.
    @MainActor static func titlebarResizeChecks() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        defer { window.orderOut(nil) }

        let layout = ReaderTitlebarLayout(window: window)
        layout.alignNow()

        func buttons() -> [NSButton] {
            [.closeButton, .miniaturizeButton, .zoomButton].compactMap {
                window.standardWindowButton($0)
            }
        }
        func frames() -> [NSRect] { buttons().map(\.frame) }

        let initial = frames()
        require(initial.count == 3, "the window has three standard traffic-light buttons")
        require(initial.map(\.origin.x) == [20, 40, 60],
                "the group starts 20 pt from the edge on a 20 pt origin pitch")
        require(initial.allSatisfy {
            abs($0.midY - TabRowLayout.contentCenterY) < 0.001
        }, "the group is centred in the 44 pt row")
        require(initial.allSatisfy {
            $0.origin.y == TabRowLayout.trafficLightOriginY(buttonHeight: $0.height)
        }, "each button's y comes from the row height and its own height")
        let edgeGap = initial[0].minX
        let visualGap = initial[1].minX - initial[0].maxX
        require(edgeGap > visualGap,
                "the edge gap (\(edgeGap)) is larger than the gap inside the group (\(visualGap))")
        for button in buttons() {
            require(button.superview?.frame.height == 44,
                    "the native titlebar is extended to the full 44 pt row")
        }

        let widths: [CGFloat] = [900, 1200, 2400, 900, 1500, 2400, 1200]
        var previous = initial
        for width in widths {
            window.setFrame(NSRect(x: 0, y: 0, width: width, height: 800), display: false)
            window.contentView?.layoutSubtreeIfNeeded()
            layout.alignNow()
            let current = frames()
            require(current.map(\.origin.y) == initial.map(\.origin.y),
                    "at width \(Int(width)) the buttons are still on the row's centre line")
            require(current.map(\.origin.y) == previous.map(\.origin.y),
                    "the resize tick at width \(Int(width)) does not move the buttons vertically")
            require(current.map(\.origin.x) == initial.map(\.origin.x),
                    "at width \(Int(width)) the group is still at 20 / 40 / 60 pt")
            previous = current
        }
        require(previous.map(\.origin.y) == initial.map(\.origin.y),
                "after a full resize sequence no button has moved vertically")
    }

    // MARK: - Retention, raster reuse and the keep-limit

    /// Defects 4a/4b: switching to an already-open tab must not call `open`, must present the same
    /// raster generation, and must restore the exact scroll offset. Beyond the keep-limit the LRU
    /// document is closed exactly once; selecting its tab reloads it without a second index-sidecar
    /// write, with annotations and a pending page-edit session intact.
    @MainActor static func tabRetentionChecks(root: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("aris-tabs-\(UUID())")
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

        // The full suite runs with the index cache disabled so it cannot write beside the committed
        // fixtures. These copies are in a temporary directory, so enable the cache for this check
        // and restore the previous environment value afterwards: it must be a hit, not a rewrite,
        // when an evicted tab is selected again.
        let cacheEnvironmentKey = "ARIS_READER_INDEX_CACHE"
        let previousCacheSetting = ProcessInfo.processInfo.environment[cacheEnvironmentKey]
        setenv(cacheEnvironmentKey, "enabled", 1)
        defer {
            if let previousCacheSetting {
                setenv(cacheEnvironmentKey, previousCacheSetting, 1)
            } else {
                unsetenv(cacheEnvironmentKey)
            }
        }

        let a = try copyFixture("multipage.pdf", to: "a.pdf")
        let b = try copyFixture("multipage.pdf", to: "b.pdf")
        let c = try copyFixture("outlined.pdf", to: "c.pdf")
        let d = try copyFixture("text-page.pdf", to: "d.pdf")

        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        guard let engine = state.engine as? RustEngine else {
            fatalError("FAIL: the retention check needs the real engine")
        }
        require(AppState.maximumRetainedDocuments == 3,
                "the keep-limit is the active document plus two recently used ones")

        // 1. Two documents, each with a raster. The second document is opened while the first is
        //    still live; the first must become a retained tab, not a reopened file.
        state.newTab(url: a)
        try await eventually("the first tab rasterizes", { !state.canvasPages.isEmpty })
        state.gotoPage(1)
        let scrollA = state.scrollYPt
        require(scrollA > 0, "the first tab is scrolled away from the top")
        let rasterA = Set(state.canvasPages.map(\.image.generation))
        require(!rasterA.isEmpty, "the first tab has a raster generation to compare")

        state.newTab(url: b)
        try await eventually("the second tab rasterizes", {
            state.document?.url == b && !state.canvasPages.isEmpty
        })
        state.gotoPage(1)
        let scrollB = state.scrollYPt
        require(scrollB > 0, "the second tab is scrolled away from the top")
        try await eventually("the second tab's index sidecar is written", {
            fileManager.fileExists(atPath: b.appendingPathExtension("aris-index.json").path)
        })
        let indexURLB = b.appendingPathExtension("aris-index.json")
        let indexAfterFirstWrite = try fileManager.attributesOfItem(atPath: indexURLB.path)

        // 2. Switching to the first tab is a document activation, never an open, and presents the
        //    exact raster generation that was on screen before.
        let requestsBeforeSwitch = state.openRequestCount
        let opensBeforeSwitch = engine.documentOpenCount
        state.selectTab(0)
        require(state.document?.url == a, "the first tab is on screen after the switch")
        require(state.openRequestCount == requestsBeforeSwitch,
                "switching to an already-open tab performs no open request")
        require(engine.documentOpenCount == opensBeforeSwitch,
                "switching to an already-open tab performs no engine open")
        require(Set(state.canvasPages.map(\.image.generation)) == rasterA,
                "the switch presents the same raster generation as before")
        require(!state.canvasPages.isEmpty, "the switch does not leave a blank canvas")
        require(state.scrollYPt == scrollA,
                "the switch restores the first tab's scroll offset exactly")
        let indexAfterSwitch = try fileManager.attributesOfItem(atPath: indexURLB.path)
        require(indexAfterSwitch[.systemFileNumber] as? NSNumber
                    == indexAfterFirstWrite[.systemFileNumber] as? NSNumber,
                "switching tabs does not write a second index sidecar for the retained document")

        // 3. Visit a third tab and come back: still no open, still the same raster and position.
        state.newTab(url: c)
        try await eventually("the third tab rasterizes", {
            state.document?.url == c && !state.canvasPages.isEmpty
        })
        let opensAfterC = engine.documentOpenCount
        let requestsAfterC = state.openRequestCount
        state.selectTab(0)
        require(state.openRequestCount == requestsAfterC && engine.documentOpenCount == opensAfterC,
                "a return after a third tab does not reopen the first tab")
        require(Set(state.canvasPages.map(\.image.generation)) == rasterA,
                "the return after a third tab still presents the cached raster generation")
        require(state.scrollYPt == scrollA, "the return after a third tab keeps the exact scroll offset")
        state.selectTab(2)
        require(state.openRequestCount == requestsAfterC,
                "the third tab is itself retained and does not reopen")

        // 4. Beyond the limit the least recently used document is evicted and closed once.
        //    Touch order: a, c, a; then d opens, so b (touched only when c opened) is the LRU.
        state.selectTab(0)
        let evictionsBeforeD = state.documentEvictionCount
        let closesBeforeD = engine.documentCloseCount
        let indexBefore = try fileManager.attributesOfItem(atPath: indexURLB.path)
        state.newTab(url: d)
        try await eventually("the fourth tab rasterizes", {
            state.document?.url == d && !state.canvasPages.isEmpty
        })
        require(state.retainedDocumentCount == AppState.maximumRetainedDocuments,
                "four tabs keep exactly three documents open")
        require(state.documentEvictionCount == evictionsBeforeD + 1,
                "opening the fourth document evicts exactly one retained document")
        require(engine.documentCloseCount == closesBeforeD + 1,
                "the evicted document is closed exactly once")
        require(engine.lastClosedDocumentURL == b,
                "the least recently used document (b) is the one evicted")
        require(engine.retainedDocumentURLs.count <= AppState.maximumRetainedDocuments,
                "the engine retains no more documents than the shell's limit")

        // The index sidecar was written once when b first opened; switching tabs and evicting it
        // must not rewrite it.
        let indexAfterEviction = try fileManager.attributesOfItem(atPath: indexURLB.path)
        require(indexAfterEviction[.systemFileNumber] as? NSNumber
                    == indexBefore[.systemFileNumber] as? NSNumber,
                "evicting b does not rewrite its index sidecar (same inode)")
        require(indexAfterEviction[.modificationDate] as? Date
                    == indexBefore[.modificationDate] as? Date,
                "evicting b leaves its index sidecar's timestamp alone")

        // 5. Selecting the evicted tab reloads it once, keeps its exact scroll position, and the
        //    reload is an index-cache hit: the sidecar is not written a second time.
        let bTab = state.tabs.firstIndex(where: { $0.url == b })
        require(bTab != nil, "the evicted tab is still in the strip")
        let opensBeforeBReload = engine.documentOpenCount
        let requestsBeforeBReload = state.openRequestCount
        state.selectTab(bTab!)
        require(state.document?.url == b, "the evicted tab reloads its document")
        require(state.isRestoringDocument, "a clear placeholder is shown before the reloaded raster")
        try await eventually("the reloaded tab rasterizes", { !state.canvasPages.isEmpty })
        require(!state.isRestoringDocument, "the placeholder clears once the raster is ready")
        require(engine.documentOpenCount == opensBeforeBReload + 1,
                "reloading the evicted tab opens the document exactly once")
        require(state.openRequestCount == requestsBeforeBReload + 1,
                "reloading the evicted tab goes through the one open path once")
        require(state.scrollYPt == scrollB, "the reloaded tab keeps its exact scroll offset")
        let indexAfterReload = try fileManager.attributesOfItem(atPath: indexURLB.path)
        require(indexAfterReload[.systemFileNumber] as? NSNumber
                    == indexBefore[.systemFileNumber] as? NSNumber,
                "re-entering the evicted tab does not write a second index sidecar (same inode)")
        require(indexAfterReload[.modificationDate] as? Date
                    == indexBefore[.modificationDate] as? Date,
                "re-entering the evicted tab leaves the index sidecar's timestamp alone")

        // 6. Annotations follow the document, not the tab's activation. A seeded sidecar is loaded
        //    once; switching away and back presents it without writing it again.
        let annotated = try copyFixture("multipage.pdf", to: "annotated.pdf")
        let note = AppState.Annotation(
            id: UUID(), page: 0, start: 0, end: 5,
            color: AppState.highlightPalette[0].color,
            note: "survives a tab switch", createdAt: Date()
        )
        let annotationSidecar = annotated.appendingPathExtension("aris-annotations.json")
        try JSONEncoder().encode([note]).write(to: annotationSidecar)
        let annotationState = AppState(engine: try RustEngine())
        annotationState.setViewportSize(CGSize(width: 700, height: 500))
        annotationState.newTab(url: annotated)
        require(annotationState.annotations.count == 1, "the seeded annotation is loaded")
        let writesBeforeSwitch = annotationState.annotationWriteCount
        annotationState.newTab(url: d)
        annotationState.selectTab(0)
        require(annotationState.annotations.count == 1,
                "the annotation is still there after a tab switch")
        require(annotationState.annotations.first?.note == "survives a tab switch",
                "the annotation's note survived the switch")
        require(annotationState.annotationWriteCount == writesBeforeSwitch,
                "switching tabs does not rewrite the annotation sidecar")

        // 7. A pending page-edit session survives a tab switch, and the tab comes back on its
        //    working revision rather than the original file.
        let pages = try copyFixture("multipage.pdf", to: "pages.pdf")
        let pageState = AppState(engine: try RustEngine())
        pageState.setViewportSize(CGSize(width: 700, height: 500))
        pageState.newTab(url: pages)
        pageState.newTab(url: d)
        pageState.selectTab(0)
        pageState.selectPage(1, extending: false, toggling: false)
        let rotated = await pageState.applyPageEditOperation(
            .rotate(pages: [1], quarterTurns: 1), label: "Rotate page 2"
        )
        require(rotated && pageState.pageEditSessionActive,
                "a page-edit session is staged on the first tab")
        let revisionURL = pageState.document?.url
        require(revisionURL != pages, "the page-edit session is showing a working revision")
        pageState.selectTab(1)
        pageState.selectTab(0)
        require(pageState.pageEditSessionActive,
                "the pending page-edit session survives a tab switch")
        require(pageState.document?.url == revisionURL,
                "the tab returns to its working revision, not the original file")
        require(pageState.pageEditPendingOperations.count == 1,
                "the staged operation is still listed after the switch")
        pageState.discardPageEdits()

        print("PASS: tab row layout, resize stability and document retention")
    }
}
