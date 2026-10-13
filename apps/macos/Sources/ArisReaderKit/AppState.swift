import ArisReaderFFI
import Combine
import AppKit
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
    /// True while the user is scrolling, so the indicator stays on screen.
    @Published public private(set) var isScrolling = false
    /// Fades the indicator out once scrolling stops.
    private var scrollIdleTask: Task<Void, Never>?
    /// Debounces writing the reading position to `UserDefaults`.
    private var positionSaveTask: Task<Void, Never>?
    /// Total content height in points (for scrollbars and clamping).
    @Published public private(set) var contentHeightPt: CGFloat = 0
    /// Width of the widest page in points; the canvas centres the content with it.
    @Published public private(set) var contentWidthPt: CGFloat = 0

    /// Gap between pages, in points.
    public let pageGapPt: CGFloat = 12
    /// Viewport size in screen points, reported by the canvas.
    private var viewportSizePt: CGSize = .zero
    /// Tile edge in device pixels at LOD 0 (matches `EngineConfig::tile_size`).
    private let tileSizePx = 512
    /// Highest pyramid level we build (matches `EngineConfig::max_lod`).
    private let maxLod: UInt8 = 4

    /// Identity of one tile in the pyramid.
    private struct TileKey: Hashable {
        let page: Int
        let lod: UInt8
        let x: Int
        let y: Int
    }

    /// Rasterized tiles, ready to draw (each carries its placement in content space).
    private var tileCache: [TileKey: CanvasPage] = [:]
    /// Insertion order, used to evict the oldest tiles first.
    private var tileOrder: [TileKey] = []
    /// Tiles whose rasterization is in flight, so scrolling does not queue one twice.
    private var tilesInFlight: Set<TileKey> = []
    private let tileCacheLimit = 48
    /// Bumped whenever the cache is invalidated (zoom or document change): results that
    /// arrive afterwards are stale and get dropped.
    private var renderEpoch: UInt64 = 0

    /// Text layers, fetched once per page.
    private var textPages: [Int: TextPage] = [:]
    private var textPagesInFlight: Set<Int> = []
    /// Page placements from the last layout pass (hit-testing needs them).
    private var visiblePagePlacements: [PagePlacement] = []

    /// A highlight the reader added.
///
/// Stored in a sidecar JSON next to the document rather than inside the PDF itself: writing
/// PDF annotations means round-tripping the file through PDFium (`FPDF_Annot_*` +
/// `FPDF_SaveAsCopy`), and a sidecar keeps the original untouched until that lands. The
/// durable model and its undo/redo transactions belong in `aris-reader-edit` (T3.1).
public struct Annotation: Identifiable, Codable, Equatable, Sendable {
    /// How the annotation is drawn. Highlights fill the character box, underlines sit on the
    /// baseline; both address the same character range.
    public enum Kind: String, Codable, Sendable {
        case highlight
        case underline
    }

    public let id: UUID
    /// Defaults to `.highlight` for sidecars written before kinds existed.
    public var kind: Kind = .highlight
    public var page: Int
    /// Inclusive character range in the page's text layer.
    public var start: Int
    public var end: Int
    /// Index into `AppState.highlightPalette`.
    public var colorIndex: Int
    public var note: String
    public var createdAt: Date
}

/// A selection: a page and an inclusive character range in its text layer.
    public struct Selection: Equatable, Sendable {
        public let page: Int
        public let range: ClosedRange<Int>
    }

    @Published public private(set) var selection: Selection?

    /// The citation/figure preview (M4): what the floating panel is showing, if anything.
    ///
    /// Following an internal link opens this instead of jumping, so the reader keeps their
    /// place; the panel offers the jump explicitly.
    public struct ReferencePreview: Equatable, Sendable {
        public let page: Int
        public let title: String
        /// Where the link was found, shown in the panel for context.
        public let source: String
        /// Region of the target page to show, when the citation points at a figure or table
        /// rather than at the top of a page (view space, points).
        public let region: CGRect?
    }

    @Published public private(set) var referencePreview: ReferencePreview?
    /// Page content for the preview panel (its own render surface).
    @Published public private(set) var referencePreviewPages: [CanvasPage] = []
    @Published public private(set) var referencePreviewZoom: CGFloat = 1

    /// Width the preview panel gives the page, in points.
    private let referencePreviewWidthPt: CGFloat = 300

    /// Opens a floating preview of `page`.
    public func openReferencePreview(
        page: Int,
        title: String,
        from source: String,
        region: CGRect? = nil
    ) {
        guard document != nil, page >= 0 else { return }
        referencePreview = ReferencePreview(
            page: page,
            title: title,
            source: source,
            region: region
        )

        let widthPt = max(region?.width ?? engine.contentWidthPt(gapPt: pageGapPt), 1)
        let scale = referencePreviewWidthPt / widthPt * deviceScale

        Task { @MainActor [weak self] in
            guard let self else { return }
            let rasterized: PageImage?
            if let region {
                rasterized = try? await self.engine.rasterizeRegion(
                    page: page,
                    scale: scale,
                    xPt: region.minX,
                    yPt: region.minY,
                    widthPt: region.width,
                    heightPt: region.height
                )
            } else {
                rasterized = try? await self.engine.renderPage(page, scale: scale)
            }
            guard let image = rasterized else { return }

            self.referencePreviewPages = [
                CanvasPage(
                    placement: PagePlacement(
                        index: 700_000_000,
                        topPt: 0,
                        leftPt: 0,
                        widthPt: image.pointSize.width,
                        heightPt: image.pointSize.height
                    ),
                    image: image
                )
            ]
            self.referencePreviewZoom = self.referencePreviewWidthPt / max(image.pointSize.width, 1)
            FileHandle.standardError.write(
                Data("aris-preview: page \(page + 1) ready (\(image.pixelWidth)x\(image.pixelHeight) px)\n".utf8)
            )
        }
    }

    public func closeReferencePreview() {
        referencePreview = nil
        referencePreviewPages = []
    }

    /// Highlights the reader added, and the file they are stored in.
    @Published public private(set) var annotations: [Annotation] = []
    private var annotationsURL: URL?
    /// Highlight colours offered in the toolbar (BGRA, translucent so text stays readable).
    public static let highlightPalette: [(name: String, bgra: [UInt8])] = [
        ("Yellow", [0x40, 0xD8, 0xFF, 0x66]),
        ("Green", [0x60, 0xD0, 0x70, 0x66]),
        ("Blue", [0xF0, 0xA0, 0x60, 0x66]),
        ("Pink", [0xB0, 0x70, 0xE0, 0x66]),
    ]
    private lazy var highlightTextures: [PageImage] = Self.highlightPalette.enumerated().map {
        index, colour in
        PageImage(
            pixelWidth: 1,
            pixelHeight: 1,
            pointSize: .zero,
            bgra: Data(colour.bgra),
            generation: UInt64(2 + index)
        )
    }

    /// Citations per page and the document's reference list.
    private var citationsByPage: [Int: [Citation]] = [:]
    private var citationsInFlight: Set<Int> = []
    @Published public private(set) var references: [Reference] = []

    /// Links per page, fetched once and kept.
    private var linkCache: [Int: [DocumentLink]] = [:]
    private var linksInFlight: Set<Int> = []

    /// An open document. The engine holds one document at a time for now, so switching tabs
    /// reopens the file and reapplies the tab's own scroll offset.
    public struct OpenTab: Identifiable, Sendable {
        public let id = UUID()
        public let url: URL
        public var title: String
        public var scrollYPt: CGFloat
    }

    @Published public private(set) var tabs: [OpenTab] = []
    @Published public private(set) var activeTabIndex: Int?

    /// Document outline, loaded once per document.
    @Published public private(set) var outline: [OutlineEntry] = []
    /// Small page previews for the sidebar, keyed by page index.
    @Published public private(set) var thumbnails: [Int: PageImage] = [:]
    private var thumbnailsInFlight: Set<Int> = []
    /// Thumbnail width in points; height follows the page's aspect ratio.
    public let thumbnailWidthPt: CGFloat = 132
    /// How many pages get a preview. Loading every page of a 2000-page manual up front would
    /// be wasteful; the strip grows on demand (T2.5).
    private let thumbnailLimit = 24

    /// Search state. A hit is shown by selecting its character range, so highlighting and
    /// scrolling come for free.
    @Published public var searchQuery: String = ""
    @Published public private(set) var searchHits: [SearchHit] = []
    @Published public private(set) var currentHitIndex: Int?
    @Published public private(set) var isSearching = false
    /// Character the drag started on, so extending the selection stays anchored.
    private var selectionAnchor: Int?
    /// 1×1 texture drawn as a translucent quad over selected characters — the same
    /// textured-quad pipeline the pages use, so selection needs no new GPU path.
    private lazy var highlightImage = PageImage(
        pixelWidth: 1,
        pixelHeight: 1,
        pointSize: .zero,
        bgra: Data([0x40, 0xC0, 0xFF, 0x55]),
        generation: 1
    )

    /// Raster scale as a discrete pyramid level: the smallest LOD whose scale covers the
    /// zoom. Zooming therefore stops re-rasterizing anything — the GPU scales the quad from
    /// the nearest LOD, and only the tile *set* changes.
    private var rasterLod: UInt8 {
        let scale = max(zoomFactor * deviceScale, 0.05)
        let level = Int(ceil(log2(scale)))
        return UInt8(min(max(level, 0), Int(maxLod)))
    }

    /// Unique id per tile, used by the canvas as its texture-cache key.
    private func tileIdentifier(_ key: TileKey) -> Int {
        (key.page << 24) | (Int(key.lod) << 20) | (key.y << 10) | key.x
    }

    private func invalidateTiles() {
        tileCache.removeAll()
        tileOrder.removeAll()
        renderEpoch &+= 1
    }
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
                invalidateTiles()
            }
            if let raw = ProcessInfo.processInfo.environment["ARIS_READER_SCROLL"],
               let offset = Double(raw), offset > 0 {
                scrollYPt = CGFloat(offset)
                beginScrollActivity()
                schedulePositionSave()
            }
            reloadVisiblePages()

            // Resume where this document was left off, now that the layout knows how tall
            // the content is (the offset is clamped against it).
            if let opened = document?.url {
                restoreReadingPosition(for: opened)
            }
            // The first document opens a tab; later ones come through `newTab`.
            if activeTabIndex == nil, let opened = document?.url {
                tabs = [
                    OpenTab(
                        url: opened,
                        title: opened.deletingPathExtension().lastPathComponent,
                        scrollYPt: 0
                    )
                ]
                activeTabIndex = 0
            }
            FileHandle.standardError.write(
                Data("aris-tabs: \(tabs.count) tab(s), active \(activeTabIndex.map(String.init) ?? "none")\n".utf8)
            )

            if let opened = document?.url {
                loadAnnotations(for: opened)
            }
            loadOutline()
            loadThumbnails()
            loadLinks()
            loadCitations()
            loadReferences()

            // Development aid: report the sidebar's data so it can be checked headlessly.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self else { return }
                let line = "aris-sidebar: outline \(self.outline.count) entries, thumbnails \(self.thumbnails.count)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }

            // Development aid: ARIS_READER_SELECT="x1,y1;x2,y2" (content points) selects
            // between two points and copies, so the text path can be verified headlessly.
            if let raw = ProcessInfo.processInfo.environment["ARIS_READER_SELECT"], !raw.isEmpty {
                selectForVerification(raw)
            }

            // Development aid: ARIS_READER_CLICK="x,y" (content points) performs the click
            // path, so citation following is verifiable without a mouse.
            if let raw = ProcessInfo.processInfo.environment["ARIS_READER_CLICK"], !raw.isEmpty {
                let parts = raw.split(separator: ",").compactMap { Double($0) }
                if parts.count == 2 {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(1500))
                        guard let self else { return }
                        let point = CGPoint(x: parts[0], y: parts[1])
                        let followed = self.followLink(at: point)
                        let cited = followed ? false : self.openCitation(at: point)
                        let line = "aris-click: (\(parts[0]),\(parts[1])) link=\(followed) citation=\(cited) status=\(self.statusMessage)\n"
                        FileHandle.standardError.write(Data(line.utf8))
                    }
                }
            }

            // Development aid: ARIS_READER_PREVIEW=<page> opens the reference panel, so M4
            // is verifiable without clicking a link. ARIS_READER_PREVIEW_REGION="x,y,w,h"
            // (view-space points) shows just that rectangle — the figure/table case.
            if let raw = ProcessInfo.processInfo.environment["ARIS_READER_PREVIEW"],
               let page = Int(raw), page > 0 {
                var region: CGRect?
                if let spec = ProcessInfo.processInfo.environment["ARIS_READER_PREVIEW_REGION"] {
                    let parts = spec.split(separator: ",").compactMap { Double($0) }
                    if parts.count == 4 {
                        region = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
                    }
                }
                openReferencePreview(
                    page: page - 1,
                    title: region == nil ? "Page \(page)" : "Figure on page \(page)",
                    from: "ARIS_READER_PREVIEW",
                    region: region
                )
            }

            // Development aid: ARIS_READER_ANNOTATE="x1,y1;x2,y2" selects between two points
            // and highlights, so annotations are verifiable without a mouse.
            if let raw = ProcessInfo.processInfo.environment["ARIS_READER_ANNOTATE"], !raw.isEmpty {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(1200))
                    guard let self else { return }
                    self.selectForVerification(raw)
                    // `selectForVerification` settles the selection asynchronously (it waits
                    // for the text layers), so give it longer than its own delay.
                    try? await Task.sleep(for: .milliseconds(1100))
                    _ = self.addHighlightFromSelection()
                }
            }

            // Development aid: ARIS_READER_FIND="pattern" searches at launch and reports the
            // hits on stderr, so search is verifiable without typing.
            if let raw = ProcessInfo.processInfo.environment["ARIS_READER_FIND"], !raw.isEmpty {
                searchQuery = raw
                runSearch()
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(1200))
                    guard let self else { return }
                    let summary = self.searchHits.prefix(4).map { hit in
                        "p\(hit.page + 1):\(hit.snippet.prefix(28))"
                    }.joined(separator: " | ")
                    let line = "aris-find: \(self.searchHits.count) hits: \(summary)\n"
                    FileHandle.standardError.write(Data(line.utf8))
                }
            }
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
            invalidateTiles()
            scrollYPt = 0
            reloadVisiblePages()
        } catch {
            lastError = String(describing: error)
            statusMessage = "Couldn't open the document"
        }
    }

    public func zoomIn() {
        zoomPercent = min(400, zoomPercent + 10)
        invalidateTiles()
        reloadVisiblePages()
    }

    public func zoomOut() {
        zoomPercent = max(25, zoomPercent - 10)
        invalidateTiles()
        reloadVisiblePages()
    }

    public func zoomActual() {
        zoomPercent = 100
        invalidateTiles()
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
        invalidateTiles()
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
        beginScrollActivity()
        guard abs(next - scrollYPt) > 0.01 else { return }
        scrollYPt = next
        reloadVisiblePages()
        schedulePositionSave()
    }

    /// Selects between two content-space points and copies the result (development aid).
    private func selectForVerification(_ specification: String) {
        let points = specification.split(separator: ";").compactMap { pair -> CGPoint? in
            let parts = pair.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { return nil }
            return CGPoint(x: parts[0], y: parts[1])
        }
        guard let first = points.first else { return }

        Task { @MainActor [weak self] in
            // Text layers arrive asynchronously; give them a moment before hit-testing.
            try? await Task.sleep(for: .milliseconds(700))
            self?.beginSelection(at: first)
            if points.count > 1 {
                self?.extendSelection(to: points[1])
            }
            // Clear first: otherwise a failed selection would leave the *previous* run's
            // text on the pasteboard and the check would pass for the wrong reason.
            NSPasteboard.general.clearContents()
            self?.copySelection()

            let selected = NSPasteboard.general.string(forType: .string) ?? ""
            let line = "aris-select: \(selected.count) characters: \"\(selected)\"\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    /// Runs a search over the whole document.
    public func runSearch() {
        let pattern = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard document != nil, !pattern.isEmpty else {
            searchHits = []
            currentHitIndex = nil
            return
        }

        isSearching = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let hits = (try? await self.engine.search(pattern, limit: 500)) ?? []
            self.searchHits = hits
            self.isSearching = false
            self.currentHitIndex = hits.isEmpty ? nil : 0
            if hits.isEmpty {
                self.statusMessage = "No matches"
            } else {
                self.showHit(at: 0)
            }
        }
    }

    /// Moves to the next (or previous) hit, wrapping around.
    public func findNext() {
        advanceHit(by: 1)
    }

    public func findPrevious() {
        advanceHit(by: -1)
    }

    private func advanceHit(by delta: Int) {
        guard !searchHits.isEmpty else { return }
        let current = currentHitIndex ?? -1
        let next = ((current + delta) % searchHits.count + searchHits.count) % searchHits.count
        currentHitIndex = next
        showHit(at: next)
    }

    /// Shows a hit by selecting its character range and scrolling it into view, so
    /// highlighting reuses the selection machinery.
    // MARK: - Annotations

    /// Turns the current selection into an annotation.
    @discardableResult
    public func addAnnotationFromSelection(
        kind: Annotation.Kind = .highlight,
        colorIndex: Int = 0,
        note: String = ""
    ) -> Bool {
        guard let selection, let url = document?.url else { return false }

        let annotation = Annotation(
            id: UUID(),
            kind: kind,
            page: selection.page,
            start: selection.range.lowerBound,
            end: selection.range.upperBound,
            colorIndex: min(max(colorIndex, 0), Self.highlightPalette.count - 1),
            note: note,
            createdAt: Date()
        )

        annotationsURL = Self.sidecarURL(for: url)
        annotations.append(annotation)
        undoStack.append(.added(annotation))
        redoStack.removeAll()
        saveAnnotations()
        reloadVisiblePages()
        statusMessage = kind == .highlight
            ? "Highlighted \(selection.range.count) characters"
            : "Underlined \(selection.range.count) characters"
        return true
    }

    @discardableResult
    public func addHighlightFromSelection(colorIndex: Int = 0) -> Bool {
        addAnnotationFromSelection(kind: .highlight, colorIndex: colorIndex)
    }

    public func removeAnnotation(_ id: UUID) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        let removed = annotations.remove(at: index)
        undoStack.append(.removed(removed))
        redoStack.removeAll()
        saveAnnotations()
        reloadVisiblePages()
        statusMessage = "Deleted annotation"
    }

    // MARK: - Undo / redo

    /// One reversible change. A stack of these is what the shell offers today; the durable
    /// transaction model belongs in `aris-reader-edit` (T3.1).
    public enum UndoableAction: Sendable {
        case added(Annotation)
        case removed(Annotation)
    }

    @Published public private(set) var undoStack: [UndoableAction] = []
    @Published public private(set) var redoStack: [UndoableAction] = []

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func undo() {
        guard let action = undoStack.popLast() else { return }
        switch action {
        case .added(let annotation):
            annotations.removeAll { $0.id == annotation.id }
        case .removed(let annotation):
            annotations.append(annotation)
        }
        redoStack.append(action)
        saveAnnotations()
        reloadVisiblePages()
        statusMessage = "Undo"
    }

    public func redo() {
        guard let action = redoStack.popLast() else { return }
        switch action {
        case .added(let annotation):
            annotations.append(annotation)
        case .removed(let annotation):
            annotations.removeAll { $0.id == annotation.id }
        }
        undoStack.append(action)
        saveAnnotations()
        reloadVisiblePages()
        statusMessage = "Redo"
    }

    public func updateNote(_ note: String, for id: UUID) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[index].note = note
        saveAnnotations()
    }

    /// Shows an annotation: selects its range and scrolls it into view.
    public func jump(to annotation: Annotation) {
        selection = Selection(
            page: annotation.page,
            range: annotation.start...max(annotation.start, annotation.end)
        )
        selectionAnchor = nil

        let top = engine.pageTopPt(annotation.page, gapPt: pageGapPt)
        if top < scrollYPt || top > scrollYPt + viewportHeightContentPt {
            scrollYPt = top
        }
        reloadVisiblePages()
    }

    /// `document.pdf` → `document.pdf.aris-annotations.json`.
    private static func sidecarURL(for document: URL) -> URL {
        document.appendingPathExtension("aris-annotations.json")
    }

    private func loadAnnotations(for url: URL) {
        annotationsURL = Self.sidecarURL(for: url)
        guard let annotationsURL,
              let data = try? Data(contentsOf: annotationsURL),
              let decoded = try? JSONDecoder().decode([Annotation].self, from: data)
        else {
            annotations = []
            return
        }
        annotations = decoded
        FileHandle.standardError.write(
            Data("aris-annotate: loaded \(decoded.count) annotation(s)\n".utf8)
        )
    }

    private func saveAnnotations() {
        guard let annotationsURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(annotations) else { return }
        try? data.write(to: annotationsURL, options: .atomic)
        FileHandle.standardError.write(
            Data("aris-annotate: saved \(annotations.count) annotation(s)\n".utf8)
        )
    }

    /// Public entry point for the sidebar's search results list.
    public func showSearchHit(_ index: Int) {
        currentHitIndex = index
        showHit(at: index)
    }

    private func showHit(at index: Int) {
        guard searchHits.indices.contains(index) else { return }
        let hit = searchHits[index]

        selection = Selection(page: hit.page, range: hit.start...(max(hit.start, hit.end - 1)))
        selectionAnchor = nil

        let top = engine.pageTopPt(hit.page, gapPt: pageGapPt)
        if top < scrollYPt || top > scrollYPt + viewportHeightContentPt {
            scrollYPt = top
        }
        reloadVisiblePages()
        statusMessage = "Match \(index + 1) of \(searchHits.count)"
    }

    /// 0…1 position of the viewport inside the content (drives the scroll indicator).
    public var scrollFraction: Double {
        let scrollable = max(contentHeightPt - viewportHeightContentPt, 0)
        guard scrollable > 0 else { return 0 }
        return Double(min(max(scrollYPt / scrollable, 0), 1))
    }

    /// 0…1 share of the content the viewport covers (the indicator's thumb length).
    public var viewportFraction: Double {
        guard contentHeightPt > 0 else { return 1 }
        return Double(min(max(viewportHeightContentPt / contentHeightPt, 0.02), 1))
    }

    /// Whether the indicator should be visible: only while scrolling, and only when there is
    /// something to scroll.
    public var showsScrollIndicator: Bool {
        contentHeightPt > viewportHeightContentPt && isScrolling
    }

    /// Scrolls to a 0…1 position (drag on the indicator).
    /// Fetches the links of every visible page, so a click can be resolved immediately.
    private func loadLinks() {
        for placement in visiblePagePlacements where linkCache[placement.index] == nil {
            guard !linksInFlight.contains(placement.index) else { continue }
            linksInFlight.insert(placement.index)

            let page = placement.index
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.linksInFlight.remove(page) }
                if let links = try? await self.engine.links(page) {
                    self.linkCache[page] = links
                }
            }
        }
    }

    /// Ends a pointer interaction: a click follows a link, a drag keeps the selection so
    /// ⌘C can copy it.
    public func endPointerInteraction(at point: CGPoint, wasClick: Bool) {
        guard wasClick else { return }

        // A click first tries a link annotation, then an in-text citation. Keeping the order
        // means the PDF's own link always wins when both describe the same spot.
        let handled = followLink(at: point) || openCitation(at: point)
        if handled || selection == nil {
            clearSelection()
        }
    }

    /// Fetches the citations of every visible page, so a click resolves immediately.
    private func loadCitations() {
        for placement in visiblePagePlacements where citationsByPage[placement.index] == nil {
            guard !citationsInFlight.contains(placement.index) else { continue }
            citationsInFlight.insert(placement.index)

            let page = placement.index
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.citationsInFlight.remove(page) }
                if let found = try? await self.engine.citations(page) {
                    self.citationsByPage[page] = found
                }
            }
        }
    }

    /// Loads the reference list once (it never changes for an open document).
    private func loadReferences() {
        guard references.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.references = (try? await self.engine.references()) ?? []
            FileHandle.standardError.write(
                Data("aris-references: \(self.references.count) entries\n".utf8)
            )
        }
    }

    /// Opens the reference an in-text citation points at (M4).
    ///
    /// This is the path that works **without** a link annotation: detect `[12]`, resolve it
    /// against the reference list, and preview the entry's own rectangle. Returns false when
    /// the point is not on a citation, or when the citation names nothing we can resolve.
    @discardableResult
    public func openCitation(at point: CGPoint) -> Bool {
        for placement in visiblePagePlacements {
            let pageRect = CGRect(
                x: placement.leftPt,
                y: placement.topPt,
                width: placement.widthPt,
                height: placement.heightPt
            )
            guard pageRect.contains(point), let citations = citationsByPage[placement.index] else {
                continue
            }

            let local = CGPoint(x: point.x - placement.leftPt, y: point.y - placement.topPt)
            for citation in citations {
                let box = CGRect(
                    x: citation.xPt,
                    y: citation.yPt,
                    width: citation.widthPt,
                    height: citation.heightPt
                )
                guard box.contains(local) else { continue }

                // Try each label the citation names: `[12,13]` can match either entry.
                for label in citation.labels {
                    guard let reference = references.first(where: { $0.label == label }) else {
                        continue
                    }
                    let snippet = reference.text.prefix(48)
                    openReferencePreview(
                        page: reference.page,
                        title: "Reference [\(reference.label)]",
                        from: "page \(placement.index + 1)",
                        region: CGRect(
                            x: reference.xPt,
                            y: reference.yPt,
                            width: reference.widthPt,
                            height: reference.heightPt
                        )
                    )
                    statusMessage = "Reference [\(reference.label)]: \(snippet)"
                    return true
                }

                // A citation we cannot resolve (author-year list, unusual numbering) still
                // deserves feedback rather than a silent no-op.
                statusMessage = "Citation \"\(citation.text)\" has no matching entry"
                return true
            }
        }
        return false
    }

    /// Follows the link under a content-space point, if there is one.
    ///
    /// Called on a *click* (no drag): dragging selects text, clicking follows links — the
    /// convention PDF readers share.
    @discardableResult
    public func followLink(at point: CGPoint) -> Bool {
        for placement in visiblePagePlacements {
            let pageRect = CGRect(
                x: placement.leftPt,
                y: placement.topPt,
                width: placement.widthPt,
                height: placement.heightPt
            )
            guard pageRect.contains(point), let links = linkCache[placement.index] else {
                continue
            }

            let local = CGPoint(x: point.x - placement.leftPt, y: point.y - placement.topPt)
            for link in links {
                let box = CGRect(x: link.xPt, y: link.yPt, width: link.widthPt, height: link.heightPt)
                guard box.contains(local) else { continue }

                if let uri = link.uri, let url = URL(string: uri) {
                    // Only hand schemes we trust to the system.
                    if let scheme = url.scheme?.lowercased(),
                       ["http", "https", "mailto"].contains(scheme) {
                        NSWorkspace.shared.open(url)
                        statusMessage = "Opened \(url.host ?? uri)"
                        return true
                    }
                }
                if let page = link.page {
                    // M4: show the target in a floating panel rather than jumping, so the
                    // citation can be read without losing the place in the text. When the
                    // destination names a region (/FitR), only that region is shown -- which
                    // is what a citation to a figure or table means.
                    openReferencePreview(
                        page: page,
                        title: link.region == nil
                            ? "Page \(page + 1)"
                            : "Figure on page \(page + 1)",
                        from: "page \(placement.index + 1)",
                        region: link.region
                    )
                    statusMessage = "Previewing page \(page + 1)"
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Tabs

    /// Opens a document in a new tab and switches to it.
    public func newTab(url: URL) {
        saveActiveTabPosition()
        tabs.append(
            OpenTab(url: url, title: url.deletingPathExtension().lastPathComponent, scrollYPt: 0)
        )
        activeTabIndex = tabs.count - 1
        open(url: url)
        restoreActiveTabPosition()
    }

    /// Switches to a tab, reopening its document.
    public func selectTab(_ index: Int) {
        guard tabs.indices.contains(index), index != activeTabIndex else { return }
        saveActiveTabPosition()
        activeTabIndex = index
        let tab = tabs[index]
        open(url: tab.url)
        restoreActiveTabPosition()
    }

    /// Closes a tab and activates a neighbour.
    public func closeTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs.remove(at: index)

        guard !tabs.isEmpty else {
            activeTabIndex = nil
            document = nil
            canvasPages = []
            return
        }

        let next = min(index, tabs.count - 1)
        activeTabIndex = next
        open(url: tabs[next].url)
        restoreActiveTabPosition()
    }

    private func saveActiveTabPosition() {
        guard let index = activeTabIndex, tabs.indices.contains(index) else { return }
        tabs[index].scrollYPt = scrollYPt
    }

    private func restoreActiveTabPosition() {
        guard let index = activeTabIndex, tabs.indices.contains(index) else { return }
        let saved = tabs[index].scrollYPt
        guard saved > 0 else { return }
        scrollYPt = min(saved, max(0, contentHeightPt - viewportHeightContentPt))
        reloadVisiblePages()
    }

    /// Loads the document outline (once per document).
    public func loadOutline() {
        guard document != nil else {
            outline = []
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.outline = (try? await self.engine.outline()) ?? []
        }
    }

    /// Rasterizes the first pages at thumbnail size for the sidebar.
    public func loadThumbnails() {
        guard let document, document.pageCount > 0 else {
            thumbnails = [:]
            return
        }

        let scale = thumbnailWidthPt / max(document.firstPageSize.width, 1)
        for page in 0..<min(document.pageCount, thumbnailLimit) {
            guard thumbnails[page] == nil, !thumbnailsInFlight.contains(page) else { continue }
            thumbnailsInFlight.insert(page)

            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.thumbnailsInFlight.remove(page) }
                if let image = try? await self.engine.renderPage(page, scale: scale) {
                    self.thumbnails[page] = image
                }
            }
        }
    }

    /// Resumes where the reader left off.
    ///
    /// Saved per document path, debounced while scrolling, and clamped to the content so a
    /// window resize between sessions cannot put the reader past the end.
    private func restoreReadingPosition(for url: URL) {
        guard let saved = UserDefaults.standard.object(forKey: Self.positionKey(for: url)) as? Double
        else { return }

        let maxOffset = max(0, contentHeightPt - viewportHeightContentPt)
        let clamped = min(max(0, CGFloat(saved)), maxOffset)
        guard clamped > 0 else { return }

        scrollYPt = clamped
        reloadVisiblePages()
        FileHandle.standardError.write(
            Data("aris-position: restored \(Int(clamped)) pt of \(Int(contentHeightPt)) pt\n".utf8)
        )
    }

    private func schedulePositionSave() {
        guard let url = document?.url else { return }
        let offset = Double(scrollYPt)
        positionSaveTask?.cancel()
        positionSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            UserDefaults.standard.set(offset, forKey: Self.positionKey(for: url))
        }
    }

    private static func positionKey(for url: URL) -> String {
        "readingPosition:" + url.path
    }

    public func scroll(toFraction fraction: Double) {
        guard document != nil else { return }
        let scrollable = max(contentHeightPt - viewportHeightContentPt, 0)
        let next = CGFloat(min(max(fraction, 0), 1)) * scrollable
        beginScrollActivity()
        guard abs(next - scrollYPt) > 0.01 else { return }
        scrollYPt = next
        reloadVisiblePages()
    }

    /// Marks the indicator as in use and schedules it to fade out. The task is replaced on
    /// every scroll event, so momentum scrolling keeps it visible.
    private func beginScrollActivity() {
        isScrolling = true
        scrollIdleTask?.cancel()
        scrollIdleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            self?.isScrolling = false
        }
    }

    /// Jumps so that `page` (0-based) sits at the top of the viewport.
    public func gotoPage(_ page: Int) {
        guard document != nil else { return }
        scrollYPt = engine.pageTopPt(max(0, page), gapPt: pageGapPt)
        reloadVisiblePages()
        schedulePositionSave()
    }

    public var zoomFactor: CGFloat {
        CGFloat(zoomPercent) / 100.0
    }

    /// Viewport height in content points (the canvas draws at zoom × backing scale).
    private var viewportHeightContentPt: CGFloat {
        max(viewportSizePt.height / max(zoomFactor, 0.01), 1)
    }

    /// Makes sure the tiles covering the viewport exist, and hands the ready ones to the
    /// canvas.
    ///
    /// Rasterization happens off the main thread, so a tile that is not ready yet is simply
    /// not drawn this frame and appears when it lands. LOD selection is discrete: zooming
    /// changes which tiles are wanted, never how an existing one was rasterized.
    public func reloadVisiblePages() {
        guard document != nil else {
            canvasPages = []
            contentHeightPt = 0
            return
        }

        contentHeightPt = engine.contentHeightPt(gapPt: pageGapPt)
        contentWidthPt = engine.contentWidthPt(gapPt: pageGapPt)

        let viewportHeight = viewportHeightContentPt
        let margin = viewportHeight * 0.5
        let visible = engine.visiblePages(
            scrollYPt: scrollYPt,
            viewportHeightPt: viewportHeight,
            gapPt: pageGapPt,
            marginPt: margin
        )

        let lod = rasterLod
        let scale = CGFloat(1 << Int(lod))
        let tilePt = CGFloat(tileSizePx) / scale

        // Viewport in content points, expanded by the prefetch margin. Every column is
        // taken: a page is a handful of columns wide, and horizontal scrolling does not
        // exist yet.
        let top = scrollYPt - margin
        let bottom = scrollYPt + viewportHeight + margin

        visiblePagePlacements = Array(visible)

        var wanted = Set<TileKey>()
        var pages: [CanvasPage] = []

        for placement in visible {
            let columns = max(1, Int(ceil(placement.widthPt / tilePt)))
            let rows = max(1, Int(ceil(placement.heightPt / tilePt)))
            let firstRow = max(0, Int(floor((top - placement.topPt) / tilePt)))
            let lastRow = min(rows - 1, Int(floor((bottom - placement.topPt) / tilePt)))
            guard firstRow <= lastRow else { continue }

            for ty in firstRow...lastRow {
                for tx in 0..<columns {
                    let key = TileKey(page: placement.index, lod: lod, x: tx, y: ty)
                    wanted.insert(key)

                    let tilePlacement = PagePlacement(
                        index: tileIdentifier(key),
                        topPt: placement.topPt + CGFloat(ty) * tilePt,
                        leftPt: placement.leftPt + CGFloat(tx) * tilePt,
                        widthPt: tilePt,
                        heightPt: tilePt
                    )

                    if let cached = tileCache[key] {
                        pages.append(CanvasPage(placement: tilePlacement, image: cached.image))
                    } else {
                        scheduleTile(key, placement: tilePlacement)
                    }
                }
            }
        }

        appendSelectionHighlights(to: &pages)
        prefetchTextLayers(for: visible)
        evictTiles(keeping: wanted)
        canvasPages = pages
        currentPage = engine.pageIndex(atScrollYPt: scrollYPt, gapPt: pageGapPt) + 1
    }

    /// Adds one translucent quad per selected character, plus one per annotated character.
    ///
    /// Everything translucent — the selection and every highlight — is drawn by the same
    /// textured-quad pipeline as the pages, so annotation rendering needs no new GPU path.
    private func appendSelectionHighlights(to pages: inout [CanvasPage]) {
        if let selection {
            appendHighlight(
                page: selection.page,
                range: selection.range,
                image: highlightImage,
                idBase: 900_000_000,
                to: &pages
            )
        }

        for (annotationIndex, annotation) in annotations.enumerated() {
            guard highlightTextures.indices.contains(annotation.colorIndex) else { continue }
            appendHighlight(
                page: annotation.page,
                range: annotation.start...max(annotation.start, annotation.end),
                image: highlightTextures[annotation.colorIndex],
                // Distinct ids keep the canvas from reusing a texture it already has.
                idBase: 800_000_000 + annotationIndex * 4_096,
                // An underline is a thin bar on the baseline instead of a filled box.
                verticalScale: annotation.kind == .underline ? 0.1 : 1.0,
                verticalOffset: annotation.kind == .underline ? 0.9 : 0.0,
                to: &pages
            )
        }
    }

    private func appendHighlight(
        page: Int,
        range: ClosedRange<Int>,
        image: PageImage,
        idBase: Int,
        verticalScale: CGFloat = 1.0,
        verticalOffset: CGFloat = 0.0,
        to pages: inout [CanvasPage]
    ) {
        guard let textPage = textPages[page],
              let placement = visiblePagePlacements.first(where: { $0.index == page })
        else { return }

        for index in range where index < textPage.chars.count {
            let character = textPage.chars[index]
            pages.append(
                CanvasPage(
                    placement: PagePlacement(
                        index: idBase + index,
                        topPt: placement.topPt + character.yPt
                            + character.heightPt * verticalOffset,
                        leftPt: placement.leftPt + character.xPt,
                        widthPt: character.widthPt,
                        heightPt: max(character.heightPt * verticalScale, 1)
                    ),
                    image: image
                )
            )
        }
    }

    /// Fetches the text layer of every visible page (once), so hit-testing is instant.
    private func prefetchTextLayers(for placements: [PagePlacement]) {
        for placement in placements where textPages[placement.index] == nil {
            guard !textPagesInFlight.contains(placement.index) else { continue }
            textPagesInFlight.insert(placement.index)

            let page = placement.index
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.textPagesInFlight.remove(page) }
                if let extracted = try? await self.engine.textPage(page) {
                    self.textPages[page] = extracted
                    self.reloadVisiblePages()
                }
            }
        }
    }

    // MARK: - Selection

    /// Starts a selection at a point in content space.
    public func beginSelection(at point: CGPoint) {
        guard let hit = characterIndex(at: point) else {
            clearSelection()
            return
        }
        selectionAnchor = hit.index
        selection = Selection(page: hit.page, range: hit.index...hit.index)
        reloadVisiblePages()
    }

    /// Extends the selection to a point in content space.
    public func extendSelection(to point: CGPoint) {
        guard let anchor = selectionAnchor,
              let current = selection,
              let hit = characterIndex(at: point),
              hit.page == current.page
        else { return }

        selection = Selection(
            page: current.page,
            range: min(anchor, hit.index)...max(anchor, hit.index)
        )
        reloadVisiblePages()
    }

    public func clearSelection() {
        guard selection != nil || selectionAnchor != nil else { return }
        selection = nil
        selectionAnchor = nil
        reloadVisiblePages()
    }

    /// Copies the selected characters (⌘C from the canvas).
    public func copySelection() {
        guard let selection, let textPage = textPages[selection.page] else { return }
        let range = selection.range.clamped(to: 0...(textPage.chars.count - 1))
        guard !range.isEmpty else { return }

        let scalars = textPage.chars[range].compactMap { Unicode.Scalar($0.unicode) }
        let string = String(String.UnicodeScalarView(scalars))
        guard !string.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        statusMessage = "Copied \(string.count) characters"
    }

    /// Character under a content-space point: containment first, then the nearest box on
    /// the same line, so clicking just past the end of a word still lands somewhere useful.
    private func characterIndex(at point: CGPoint) -> (page: Int, index: Int)? {
        for placement in visiblePagePlacements {
            let pageRect = CGRect(
                x: placement.leftPt,
                y: placement.topPt,
                width: placement.widthPt,
                height: placement.heightPt
            )
            guard pageRect.contains(point), let textPage = textPages[placement.index] else {
                continue
            }

            let local = CGPoint(
                x: point.x - placement.leftPt,
                y: point.y - placement.topPt
            )
            var best: (index: Int, distance: CGFloat)?

            for (index, character) in textPage.chars.enumerated() {
                let box = CGRect(
                    x: character.xPt,
                    y: character.yPt,
                    width: character.widthPt,
                    height: character.heightPt
                )
                if box.contains(local) {
                    return (placement.index, index)
                }
                guard abs(box.midY - local.y) < max(box.height * 1.5, 14) else { continue }
                let distance = abs(box.midX - local.x)
                if best == nil || distance < best!.distance {
                    best = (index, distance)
                }
            }

            if let best { return (placement.index, best.index) }
            return nil
        }
        return nil
    }

    /// Rasterizes one tile in the background and folds it into the cache.
    private func scheduleTile(_ key: TileKey, placement: PagePlacement) {
        guard !tilesInFlight.contains(key) else { return }
        tilesInFlight.insert(key)

        let epoch = renderEpoch
        let tileSize = tileSizePx
        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let tile = try await self.engine.rasterizeTile(
                    page: key.page,
                    lod: key.lod,
                    tileX: key.x,
                    tileY: key.y,
                    tileSize: tileSize
                )
                // Clear the in-flight mark first: a stale result must still lead to a
                // re-request, otherwise the tile never appears at the new LOD.
                self.tilesInFlight.remove(key)

                guard epoch == self.renderEpoch else {
                    self.reloadVisiblePages()
                    return
                }

                let image = PageImage(
                    pixelWidth: tile.sizePx,
                    pixelHeight: tile.sizePx,
                    pointSize: CGSize(width: placement.widthPt, height: placement.heightPt),
                    bgra: tile.bgra,
                    generation: tile.generation
                )
                self.tileCache[key] = CanvasPage(placement: placement, image: image)
                self.tileOrder.append(key)
                self.reloadVisiblePages()
            } catch {
                self.tilesInFlight.remove(key)
                self.lastError = String(describing: error)
            }
        }
    }

    /// Keeps the cache bounded by dropping the oldest tiles that are no longer wanted.
    private func evictTiles(keeping wanted: Set<TileKey>) {
        guard tileCache.count > tileCacheLimit else { return }

        var remaining = tileCache.count - tileCacheLimit
        var scanned = 0
        while remaining > 0, scanned < tileOrder.count {
            let key = tileOrder[scanned]
            scanned += 1
            guard !wanted.contains(key) else { continue }
            if tileCache.removeValue(forKey: key) != nil {
                remaining -= 1
            }
        }
        tileOrder.removeFirst(min(scanned, tileOrder.count))
    }
}
