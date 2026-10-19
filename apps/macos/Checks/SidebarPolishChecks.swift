import AppKit
import LyraReaderKit
import SwiftUI

@MainActor private final class GatedSearchEngine: PreviewEngine {
    var pending: CheckedContinuation<[SearchHit], Never>?
    override func search(_ pattern: String, limit: Int) async throws -> [SearchHit] {
        await withCheckedContinuation { pending = $0 }
    }
}

extension ReaderChecks {
    @MainActor static func sidebarPolishChecks(root: URL) async throws {
        // Exercise a request that has already entered the engine, then completes after Clear.
        let engine = try RustEngine()
        _ = try engine.openDocument(at: root.appendingPathComponent("tests/fixtures/multipage.pdf"))
        let hits = try await engine.search("a", limit: 50)
        require(hits.count > 5 && Set(hits.map(\.page)).count > 1,
                "sidebar fixture supplies wrapped results across multiple pages")
        let gated = GatedSearchEngine()
        let state = AppState(engine: gated)
        require(state.open(url: root.appendingPathComponent("tests/fixtures/multipage.pdf")),
                "sidebar-polish fixture opens")
        state.searchQuery = "a"
        state.runSearch()
        try await eventually("search enters the engine", { gated.pending != nil })
        state.clearSearch()
        require(state.searchQuery.isEmpty && state.searchHits.isEmpty && state.currentHitIndex == nil
                    && !state.isSearching && !state.searchSidebarVisible,
                "Clear empties the query/results and closes the right sidebar")
        gated.pending?.resume(returning: hits); gated.pending = nil
        try await Task.sleep(for: .milliseconds(50))
        require(state.searchHits.isEmpty && !state.searchSidebarVisible,
                "an already-running search cannot restore cleared results")
        state.searchQuery = "a"
        state.runSearch()
        try await eventually("second search enters the engine", { gated.pending != nil })
        gated.pending?.resume(returning: hits); gated.pending = nil
        try await eventually("second search populates its results", { !state.isSearching })

        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: ReaderChrome.sidebarTotalWidthPt, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        defer { window.orderOut(nil); window.contentView = nil }
        var frames: [String: CGRect] = [:]
        let host = NSHostingView(rootView: SearchResultSidebar(state: state) { frames = $0 })
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        func assertContinuousRows(_ label: String) {
            let ordered = frames.values.sorted { $0.minY < $1.minY }
            require(ordered.count > 5, "\(label) measures actual hosted search rows")
            let gaps = zip(ordered, ordered.dropFirst()).map { $1.minY - $0.maxY }
            require(gaps.allSatisfy { abs($0) < 1 },
                    "\(label) has no blank gaps between headers/results (largest \(gaps.max() ?? 0) pt)")
        }
        try await eventually("hosted search rows lay out", { host.layoutSubtreeIfNeeded(); return frames.count > 5 })
        assertContinuousRows("Light sidebar")
        func nativeScrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { nativeScrollViews(in: $0) }
        }
        try await eventually("hosted SwiftUI scrollbars receive the palette scroller", {
            let views = nativeScrollViews(in: host)
            return !views.isEmpty && views.allSatisfy { $0.verticalScroller is LyraReaderSidebarScroller }
        })
        window.appearance = NSAppearance(named: .darkAqua)
        state.showSearchHit(min(12, hits.count - 1))
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        assertContinuousRows("Dark sidebar after result navigation")
        require(state.currentHitIndex == min(12, hits.count - 1), "result navigation retains the selected hit")
        state.clearSearch()
        require(state.selection == nil, "clearing an active search removes its selected match")

        let documentState = AppState(engine: engine)
        documentState.sidebarTab = .thumbnails
        let sidebarHost = NSHostingView(rootView: SidebarView(state: documentState))
        window.contentView = sidebarHost
        require(documentState.open(url: root.appendingPathComponent("tests/fixtures/annotated-replies.pdf")),
                "sidebar lifecycle fixture opens after the empty panel was hosted")
        func sidebarScrollersAreThemed() -> Bool {
            sidebarHost.layoutSubtreeIfNeeded()
            let views = nativeScrollViews(in: sidebarHost)
            return !views.isEmpty && views.allSatisfy { $0.verticalScroller is LyraReaderSidebarScroller }
        }
        try await eventually("opening a document themes the existing sidebar", sidebarScrollersAreThemed)
        documentState.sidebarTab = .annotations
        try await eventually("switching to annotations themes its new scroll view", {
            !documentState.documentAnnotationsLoading && sidebarScrollersAreThemed()
        })

        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 250, height: 200))
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .legacy
        scroll.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 230, height: 2000))
        LyraReaderSidebarScroller.install(on: scroll)
        require(scroll.verticalScroller is LyraReaderSidebarScroller && scroll.scrollerStyle == .legacy,
                "themed scrollbars retain the user's legacy scrollbar style")
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 800))
        scroll.reflectScrolledClipView(scroll.contentView)
        require(scroll.verticalScroller?.isEnabled == true && scroll.verticalScroller!.knobProportion < 1,
                "the themed scroller remains enabled with a visible draggable thumb")
        let scroller = scroll.verticalScroller!
        scroller.appearance = NSAppearance(named: .aqua)
        if let bitmap = scroller.bitmapImageRepForCachingDisplay(in: scroller.bounds) {
            scroller.cacheDisplay(in: scroller.bounds, to: bitmap)
            let track = bitmap.colorAt(x: 1, y: 1)!.usingColorSpace(.sRGB)!
            require(abs(track.redComponent - 243.0 / 255) < 0.02
                        && abs(track.greenComponent - 239.0 / 255) < 0.02,
                    "the legacy scrollbar gutter is painted with the sidebar palette")
        } else { require(false, "the native scroller produces a bitmap for color verification") }
        require(scroll.contentView.bounds.minY == 800 && (scroll.verticalScroller?.floatValue ?? 0) > 0,
                "the themed native scroller still reflects document scrolling")
        scroll.scrollerStyle = .overlay
        require(scroll.verticalScroller is LyraReaderSidebarScroller,
                "the custom scroller also supports native overlay scrolling")

        let pages = [PagePlacement(index: 0, topPt: 10, leftPt: 0, widthPt: 100, heightPt: 200),
                     PagePlacement(index: 1, topPt: 10, leftPt: 112, widthPt: 100, heightPt: 200)]
        let rects = PageChromeGeometry.rectangles(frames: pages, viewport: CGSize(width: 500, height: 600),
            contentWidthPt: 212, zoom: 2, scrollYPt: 5)
        require(rects == [CGRect(x: 38, y: 10, width: 200, height: 400),
                          CGRect(x: 262, y: 10, width: 200, height: 400)],
                "page edges follow centred facing pages, zoom and scroll rather than individual tiles")
        let overlay = PageChromeOverlayView(frame: CGRect(x: 0, y: 0, width: 500, height: 600))
        overlay.update(frames: pages, contentWidthPt: 212, zoom: 2, scrollYPt: 5, scale: 2)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 500, pixelsHigh: 600,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        overlay.layer!.render(in: NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext)
        require(bitmap.colorAt(x: 100, y: 300)!.alphaComponent == 0,
                "page shadow masking leaves source paper pixels fully untouched")
        require(bitmap.colorAt(x: 37, y: 300)!.alphaComponent > 0,
                "the continuous page border is painted just outside the paper")
        require(overlay.hitTest(CGPoint(x: 40, y: 20)) == nil,
                "paper edges and shadows never intercept annotation or text-selection gestures")
        print("Sidebar polish checks passed")
    }
}
