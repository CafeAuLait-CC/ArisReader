import ArisReaderFFI
import Combine
import Foundation

/// Sidebar tabs (see `docs/04-ui-ux.md` §2.2).
public enum SidebarTab: String, CaseIterable, Identifiable, Sendable {
    case thumbnails
    case outline
    case bookmarks
    case annotations
    case search
    case ai

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .thumbnails: return "Thumbnails"
        case .outline: return "Outline"
        case .bookmarks: return "Bookmarks"
        case .annotations: return "Annotations"
        case .search: return "Search"
        case .ai: return "AI"
        }
    }

    public var systemImage: String {
        switch self {
        case .thumbnails: return "square.grid.2x2"
        case .outline: return "list.bullet.indent"
        case .bookmarks: return "bookmark"
        case .annotations: return "highlighter"
        case .search: return "magnifyingglass"
        case .ai: return "sparkles"
        }
    }

    /// Milestone in which this tab becomes available (the UI uses it to show a "not implemented" hint).
    public var milestone: String {
        switch self {
        case .thumbnails, .outline: return "M2"
        case .bookmarks: return "M2"
        case .annotations: return "M3"
        case .search: return "M2"
        case .ai: return "M5"
        }
    }
}

/// Application state (the single source of truth is the Rust engine; only **view state** is kept here).
///
/// The skeleton phase uses `ObservableObject` (rather than the newer `@Observable`) to maximize
/// toolchain compatibility; see the "Negatives / costs" section of `docs/adr/0006`.
@MainActor
public final class AppState: ObservableObject {
    @Published public var document: LoadedDocument?
    @Published public var sidebarTab: SidebarTab = .thumbnails
    @Published public var sidebarVisible: Bool = true
    @Published public var zoomPercent: Int = 100
    @Published public var currentPage: Int = 1
    @Published public var statusMessage: String = "Drag in a PDF, or press ⌘O to open a document"
    @Published public var lastError: String?
    @Published public var showFileImporter: Bool = false

    /// Pages the canvas should draw right now (usually one or two while scrolling).
    @Published public private(set) var canvasPages: [CanvasPage] = []
    /// Scroll offset in content points; 0 is the top of the first page.
    @Published public private(set) var scrollYPt: CGFloat = 0
    /// Total content height in points (for scrollbars and clamping).
    @Published public private(set) var contentHeightPt: CGFloat = 0
    /// Width of the widest page in points; the canvas centres the content with it.
    @Published public private(set) var contentWidthPt: CGFloat = 0

    /// Gap between pages, in points.
    public let pageGapPt: CGFloat = 12
    /// Viewport size in screen points, reported by the canvas.
    private var viewportSizePt: CGSize = .zero
    /// Rasterized pages kept while scrolling; the canvas keeps one texture per entry, so
    /// this doubles as the texture budget until the tile cache lands (T1.6).
    private var pageCache: [Int: PageImage] = [:]
    private let pageCacheLimit = 6
    /// Pages whose rasterization is currently in flight, so a scroll does not queue the
    /// same page twice.
    private var inFlight: Set<Int> = []
    /// Bumped whenever the cache is invalidated (zoom or document change): results that
    /// arrive afterwards are stale and get dropped.
    private var renderEpoch: UInt64 = 0
    /// Backing scale reported by the canvas; the engine rasterizes at this resolution.
    private var deviceScale: CGFloat = 2.0

    /// Human-readable GPU/frame status shown in the toolbar (updated a few times
    /// per second by the canvas, so it must stay cheap).
    @Published public var gpuStatus: String = "GPU: starting…"
    /// Whether the second render surface (a floating preview panel) is visible.
    /// The M0 T0.5 spike turns it on with ARIS_READER_SPIKE_SECOND_SURFACE=1.
    @Published public var showSecondSurface: Bool =
        ProcessInfo.processInfo.environment["ARIS_READER_SPIKE_SECOND_SURFACE"] == "1"

    /// Records a frame report coming from a canvas surface.
    public func updateGpuStatus(_ stats: ArisFrameStats, label: String) {
        let color = stats.center_bgra
        let red = (color >> 16) & 0xFF
        let green = (color >> 8) & 0xFF
        let blue = color & 0xFF
        let format = stats.srgb == 1 ? "sRGB" : "linear"
        // The centre pixel is only meaningful on the paths that opt into readback
        // (the M0 spike did; the page path does not), so omit it rather than lie.
        let center = stats.center_bgra == 0
            ? ""
            : String(format: " · centre #%02X%02X%02X", red, green, blue)
        gpuStatus = String(
            format: "%@: %llu frames · %ux%u px · %@%@ · %.1f ms",
            label,
            stats.frame_index,
            stats.width,
            stats.height,
            format,
            center,
            Double(stats.elapsed_us) / 1000.0
        )
    }

    /// Records a canvas failure (GPU unavailable, surface lost, …).
    public func reportGpuFailure(_ message: String) {
        gpuStatus = "GPU error: \(message)"
    }

    public let engine: PDFEngine

    public init(engine: PDFEngine? = nil) {
        // Prefer the real engine; fall back to the mock so the window still works when
        // the Rust backend cannot start (docs/02-architecture.md §8).
        if let engine {
            self.engine = engine
        } else if let rustEngine = try? RustEngine() {
            self.engine = rustEngine
        } else {
            self.engine = MockEngine()
        }
        statusMessage = self.engine.version

        // Developer/test affordance: open a document at launch
        // (`ARIS_READER_OPEN=/path/to.pdf ArisReader`), which also lets a headless run
        // exercise the whole Swift → UniFFI → PDFium path.
        if let path = ProcessInfo.processInfo.environment["ARIS_READER_OPEN"], !path.isEmpty {
            open(url: URL(fileURLWithPath: path))
            // Optional 1-based page for headless checks: ARIS_READER_OPEN_PAGE=3
            if let raw = ProcessInfo.processInfo.environment["ARIS_READER_OPEN_PAGE"],
               let page = Int(raw), page > 0 {
                currentPage = page
            }
            if let raw = ProcessInfo.processInfo.environment["ARIS_READER_ZOOM"],
               let zoom = Int(raw), zoom > 0 {
                zoomPercent = zoom
                pageCache.removeAll()
        renderEpoch &+= 1
            }
            if let raw = ProcessInfo.processInfo.environment["ARIS_READER_SCROLL"],
               let offset = Double(raw), offset > 0 {
                scrollYPt = CGFloat(offset)
            }
            reloadVisiblePages()
        }
    }

    public var windowTitle: String {
        document?.title ?? "ArisReader"
    }

    public var pageLabel: String {
        guard let document, document.pageCount > 0 else { return "— / —" }
        return "\(currentPage) / \(document.pageCount)"
    }

    public func open(url: URL) {
        do {
            let loaded = try engine.openDocument(at: url)
            document = loaded
            currentPage = 1
            if loaded.pageCount > 0 {
                statusMessage = String(
                    format: "Opened %d page(s) · first page %.0f×%.0f pt · %@",
                    loaded.pageCount,
                    loaded.firstPageSize.width,
                    loaded.firstPageSize.height,
                    loaded.backend
                )
            } else {
                statusMessage = "Opened \(loaded.title) (no pages reported)"
            }
            pageCache.removeAll()
        renderEpoch &+= 1
            scrollYPt = 0
            reloadVisiblePages()
        } catch {
            lastError = String(describing: error)
            statusMessage = "Couldn't open the document"
        }
    }

    public func zoomIn() {
        zoomPercent = min(400, zoomPercent + 10)
        pageCache.removeAll()
        renderEpoch &+= 1
        reloadVisiblePages()
    }

    public func zoomOut() {
        zoomPercent = max(25, zoomPercent - 10)
        pageCache.removeAll()
        renderEpoch &+= 1
        reloadVisiblePages()
    }

    public func zoomActual() {
        zoomPercent = 100
        pageCache.removeAll()
        renderEpoch &+= 1
        reloadVisiblePages()
    }

    public func nextPage() {
        guard let document, document.pageCount > 0 else { return }
        gotoPage(min(document.pageCount, currentPage + 1) - 1)
    }

    public func previousPage() {
        guard currentPage > 1 else { return }
        gotoPage(max(1, currentPage - 1) - 1)
    }

    /// Called by the canvas once it knows the display's backing scale.
    public func setDeviceScale(_ scale: CGFloat) {
        guard scale > 0, abs(scale - deviceScale) > 0.01 else { return }
        deviceScale = scale
        pageCache.removeAll()
        renderEpoch &+= 1
        reloadVisiblePages()
    }

    /// Called by the canvas whenever its size changes.
    public func setViewportSize(_ size: CGSize) {
        guard size != viewportSizePt else { return }
        viewportSizePt = size
        reloadVisiblePages()
    }

    /// Scrolls by a delta measured in **screen points** (what `scrollWheel` reports).
    public func scroll(byScreenPoints delta: CGFloat) {
        guard document != nil else { return }
        let contentDelta = delta / max(zoomFactor, 0.01)
        let maxOffset = max(0, contentHeightPt - viewportHeightContentPt)
        let next = min(max(0, scrollYPt - contentDelta), maxOffset)
        guard abs(next - scrollYPt) > 0.01 else { return }
        scrollYPt = next
        reloadVisiblePages()
    }

    /// Jumps so that `page` (0-based) sits at the top of the viewport.
    public func gotoPage(_ page: Int) {
        guard document != nil else { return }
        scrollYPt = engine.pageTopPt(max(0, page), gapPt: pageGapPt)
        reloadVisiblePages()
    }

    public var zoomFactor: CGFloat {
        CGFloat(zoomPercent) / 100.0
    }

    /// Viewport height in content points (the canvas draws at zoom × backing scale).
    private var viewportHeightContentPt: CGFloat {
        max(viewportSizePt.height / max(zoomFactor, 0.01), 1)
    }

    /// Rasterizes the pages overlapping the viewport and hands them to the canvas.
    ///
    /// Synchronous on purpose for this slice: a full A4 page takes single-digit
    /// milliseconds with PDFium, and scrolling normally adds one page at a time. The
    /// raster pool (T1.3) and tile caching (T1.5/T1.6) replace this next.
    public func reloadVisiblePages() {
        guard document != nil else {
            canvasPages = []
            contentHeightPt = 0
            return
        }

        contentHeightPt = engine.contentHeightPt(gapPt: pageGapPt)
        contentWidthPt = engine.contentWidthPt(gapPt: pageGapPt)
        let viewportHeight = viewportHeightContentPt
        // Prefetch half a viewport ahead so the next page is ready before it appears.
        let visible = engine.visiblePages(
            scrollYPt: scrollYPt,
            viewportHeightPt: viewportHeight,
            gapPt: pageGapPt,
            marginPt: viewportHeight * 0.5
        )

        var pages: [CanvasPage] = []
        var keep = Set<Int>()
        for placement in visible {
            keep.insert(placement.index)
            if let image = pageCache[placement.index] {
                pages.append(CanvasPage(placement: placement, image: image))
            } else {
                // Rasterize off the main thread; the page appears as soon as it lands.
                scheduleRender(of: placement.index)
            }
        }

        if pageCache.count > pageCacheLimit {
            for key in pageCache.keys where !keep.contains(key) {
                pageCache.removeValue(forKey: key)
            }
        }

        canvasPages = pages
        currentPage = engine.pageIndex(atScrollYPt: scrollYPt, gapPt: pageGapPt) + 1
    }

    /// Rasterizes one page in the background and folds it into the cache.
    private func scheduleRender(of page: Int) {
        guard !inFlight.contains(page) else { return }
        inFlight.insert(page)

        let epoch = renderEpoch
        let scale = zoomFactor * deviceScale
        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let image = try await self.engine.renderPage(page, scale: scale)
                // Clear the in-flight mark *before* re-scheduling: otherwise a stale
                // result would be dropped and the page would never be rendered again.
                self.inFlight.remove(page)

                guard epoch == self.renderEpoch else {
                    // Zoom or document changed while rasterizing — this bitmap is stale,
                    // but the page is still wanted, at the new scale.
                    self.reloadVisiblePages()
                    return
                }
                self.pageCache[page] = image
                self.reloadVisiblePages()
            } catch {
                self.inFlight.remove(page)
                self.lastError = String(describing: error)
                self.statusMessage = "Couldn't render page \(page + 1)"
            }
        }
    }
}
