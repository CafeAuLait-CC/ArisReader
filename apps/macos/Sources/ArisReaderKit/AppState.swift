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

    /// The page bitmap currently on screen (nil until a document is open).
    @Published public private(set) var pageImage: PageImage?
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
            }
            reloadPage()
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
            reloadPage()
        } catch {
            lastError = String(describing: error)
            statusMessage = "Couldn't open the document"
        }
    }

    public func zoomIn() {
        zoomPercent = min(400, zoomPercent + 10)
        reloadPage()
    }

    public func zoomOut() {
        zoomPercent = max(25, zoomPercent - 10)
        reloadPage()
    }

    public func zoomActual() {
        zoomPercent = 100
        reloadPage()
    }

    public func nextPage() {
        guard let document, document.pageCount > 0 else { return }
        currentPage = min(document.pageCount, currentPage + 1)
        reloadPage()
    }

    public func previousPage() {
        guard currentPage > 1 else { return }
        currentPage = max(1, currentPage - 1)
        reloadPage()
    }

    /// Called by the canvas once it knows the display's backing scale.
    public func setDeviceScale(_ scale: CGFloat) {
        guard scale > 0, abs(scale - deviceScale) > 0.01 else { return }
        deviceScale = scale
        reloadPage()
    }

    /// Rasterizes the current page at the current zoom and hands it to the canvas.
    ///
    /// Synchronous on purpose for this slice: a full A4 page takes single-digit
    /// milliseconds with PDFium. Moving it to the raster pool (T1.3) is what makes
    /// scrolling stay smooth once tiles arrive.
    public func reloadPage() {
        guard document != nil else {
            pageImage = nil
            return
        }
        let scale = CGFloat(zoomPercent) / 100.0 * deviceScale
        do {
            pageImage = try engine.renderPage(currentPage - 1, scale: scale)
        } catch {
            pageImage = nil
            lastError = String(describing: error)
            statusMessage = "Couldn't render page \(currentPage)"
        }
    }
}
