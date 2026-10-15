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
    private var canvasTiles: [CanvasPage] = []
    /// Scroll offset in content points; 0 is the top of the first page.
    @Published public private(set) var scrollYPt: CGFloat = 0
    /// True while the user is scrolling, so the indicator stays on screen.
    @Published public private(set) var isScrolling = false
    /// Fades the indicator out once scrolling stops.
    private var scrollIdleTask: Task<Void, Never>?
    /// Debounces writing the reading position to `UserDefaults`.
    private var positionSaveTask: Task<Void, Never>?
    /// The position waiting for that debounce, so a flush can write it without waiting.
    private struct PendingPosition {
        let url: URL
        let offset: CGFloat
    }
    private var pendingPosition: PendingPosition?
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

    /// How many tile rasters may run at once.
    ///
    /// This is also the bound on what moving the viewport can leave behind: a raster that has
    /// already started cannot be cancelled, but nothing else survives `reloadVisiblePages`'s
    /// `pendingTiles = []`. The checks assert that bound against this configured number rather
    /// than against how quickly the machine happens to schedule the raster tasks.
    public static let maxConcurrentTileRasters = 2

    /// Highest pyramid level we build (matches `EngineConfig::max_lod`).
    private let maxLod: UInt8 = 4

    /// Default tile-cache budget in MB, for a reader who never opened Settings.
    ///
    /// Chosen by measurement, not by inheritance (ADR 0007; the shell used to cap the cache at
    /// 96 tiles, which is ~96 MiB of pixels and no bound at all once every wanted tile is
    /// pinned). What the measurements say:
    ///
    /// * the wanted band (visible + prefetch, pinned — see `wantedTiles`) peaks at ~28-32 MiB
    ///   on a real paper at 100% zoom in a 959×715 pt window, and at ~94-99 MiB at 400% zoom;
    /// * evicting *pinned* tiles is a loss: the scheduler immediately re-rasterizes them, and
    ///   the churn cost 150-200 MiB of RSS at 400% zoom (an effectively unbounded budget
    ///   reproduced the pre-change numbers exactly, which is what attributes the difference);
    /// * evicting *stale* tiles is free: the bench's 120-step scroll rasterizes exactly the same
    ///   636 (synthetic) / 675 (real paper) tiles with the same 60.7%/60.1% hit rate at 16 MB
    ///   as at 96 MB, while peak occupancy falls from 61.2/59.2 MiB to 20.9/20.2 MiB;
    /// * below ~40 MB the budget can no longer hold two adjacent LODs of one page at once
    ///   (8.0 MB at LOD 1 + 32.1 MB at LOD 2 for the regression fixture), so zooming back
    ///   re-rasterizes instead of reusing the cache — the behaviour `InteractionChecks` pins.
    ///   Measured: 32 MB passed 2 of 3 check runs, 40 MB 3 of 3, 48 MB 3 of 3.
    ///
    /// 48 MB is therefore the smallest budget that keeps zoom-back reuse and still bounds a
    /// sustained scroll: ~52 MiB peak occupancy against the old count cap's ~60 MiB, with
    /// identical rasterization and hit rate. Above it the extra bytes only buy scroll-back
    /// history nobody measured a need for; below it, the cache starts re-rasterizing on zoom.
    public static let defaultTileCacheBudgetMB = 48

    /// Byte budget for the tile cache, resolved the same way for `AppState` and the checks:
    /// the `ARIS_READER_CACHE_BUDGET_MB` override (measurement only) → the `cacheBudgetMB`
    /// setting written by the Settings window → `defaultTileCacheBudgetMB`.
    ///
    /// The value is clamped, not trusted: a 0 or negative setting would disable the cache and an
    /// absurd one would make the budget meaningless, which is the bug ADR 0007 fixes rather than
    /// a feature. The Settings stepper's own range starts higher (16 MB), so the floor only
    /// catches a corrupt stored value or a bad override.
    public static func configuredTileCacheBudgetBytes(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> Int {
        let override = environment["ARIS_READER_CACHE_BUDGET_MB"].flatMap(Int.init)
        let stored = defaults.integer(forKey: cacheBudgetSettingKey)
        let megabytes = override ?? (stored > 0 ? stored : defaultTileCacheBudgetMB)
        return min(max(megabytes, 1), 4096) * 1024 * 1024
    }

    /// `@AppStorage` key shared with `SettingsView`.
    public static let cacheBudgetSettingKey = "cacheBudgetMB"

    /// Rasterized tiles, ready to draw, under the byte budget of ADR 0007 (`TileCache`).
    ///
    /// The policy — byte budget, LOD-aware LRU, pinned tiles never evicted — is the one
    /// `crates/aris-reader-render/src/cache.rs` encodes; the hot path stays here per ADR 0007.
    private var tileCache = TileCache(budgetBytes: AppState.configuredTileCacheBudgetBytes())
    /// Tiles the last viewport update wanted: the visible band *and* the prefetch band. These
    /// are the pinned set, and the reason is measured rather than aesthetic.
    ///
    /// Pinning only the tiles on screen and evicting the prefetch band looks like the obvious
    /// reading of "never evict a visible tile", and it is what this change first did. It was
    /// 150-200 MiB **worse** at 400% zoom: the scheduler re-requests any wanted tile it does
    /// not find, so every eviction bought a fresh rasterization (and a fresh GPU upload), and
    /// the churn's transient allocations outgrew the bytes the budget saved (before: 462-510
    /// MiB with 0 evictions; evicting prefetch: 651-697 MiB with ~280 evictions). Pinning the
    /// whole wanted band keeps scrolling smooth and still bounds what the budget is for: the
    /// tiles the reader has scrolled *away* from, and the previous LOD's tiles after a zoom.
    private var wantedTiles: Set<TileKey> = []
    /// The scheduler's wanted set from the last viewport update (visible + prefetch band): the
    /// tiles the byte cache may not evict.
    ///
    /// Public so `ArisReaderChecks` can assert the band's invariants — that every tile the
    /// viewport can show is wanted at any zoom, and that the band does not reach for columns the
    /// reader cannot scroll to. Nothing else observes it; drawing goes through `canvasPages`.
    public var pinnedTiles: Set<TileKey> { wantedTiles }
    /// Tiles whose rasterization is in flight, so scrolling does not queue one twice.
    private var tilesInFlight: Set<TileKey> = []

    // MARK: - Prefetch band

    /// Longest prefetch ring the band may use, in viewport heights (ADR 0007 shipped 3.5
    /// viewports of *band*, i.e. a 2.5-viewport ring plus the viewport itself).
    ///
    /// This is the ceiling, not the value: `prefetchRingVh` shortens the ring whenever the
    /// band it would produce does not fit `prefetchBandBudgetBytes`. The reason is measured — at
    /// 400% zoom the fixed band pinned 110 tiles / 99.2 MiB, of which the viewport showed 16
    /// tiles: the band, not the cache budget, was most of what the peak RSS was made of.
    static let maxPrefetchRingVh: CGFloat = 2.5
    /// Ring distance below which the band is not shortened further.
    ///
    /// The floor is measured, not chosen: the bench's step scroll (`phase_scroll`) records the
    /// raster time the viewport spent *waiting* for tiles that were not ready — p95 0.00 ms and
    /// 9 misses over 120 steps at a 1.0-viewport ring, but p95 8.1 ms and 141 misses (worst
    /// 120 ms) at 0.5. A ring shorter than a viewport cannot cover one step of the bench's
    /// scroll (half a viewport) plus raster time, so the reader starts seeing the preview
    /// instead of the page. 0.75 is the shortest ring that measured no worse than 1.0.
    static let minPrefetchRingVh: CGFloat = 0.75
    /// Columns kept ready beyond the ones on screen.
    ///
    /// Zero, deliberately. The canvas left-aligns a page that is wider than the viewport and
    /// there is no horizontal scrolling, so an off-screen column can only be revealed by a
    /// widening window — and the band's byte budget is spent better on the ring the reader
    /// actually moves through. A resize rasterizes the new column on demand, behind the
    /// whole-page preview that is already there for exactly this case.
    static let prefetchColumnsToTheRight = 0
    /// Ceiling on nearby whole-page rasters; the shared byte budget usually limits this first.
    /// `ARIS_READER_PREVIEW_PAGES=<n>` overrides it for measurement.
    static let defaultMaxPreviewPages = 7
    private static let maxPreviewPages = ProcessInfo.processInfo.environment["ARIS_READER_PREVIEW_PAGES"]
        .flatMap(Int.init).map { min(max($0, 0), 32) } ?? defaultMaxPreviewPages

    /// Byte target for the whole wanted band (visible + ring + the ready columns).
    ///
    /// The band is the *pinned* set — `TileCache.evictToFit` never drops it — so a fixed band
    /// in viewport heights is an unbounded commitment in bytes: the same 3.5 viewports cost
    /// 27 MiB at 100% zoom and 99 MiB at 400%, and the peak followed (measured on a real
    /// 115-page paper: 417.7 MiB and 515.1 MiB). A third of the cache budget is the rule, with
    /// an 8 MiB floor so that a reader who shrinks the cache in Settings still gets a band:
    /// the pinned third keeps scrolling fed, the rest stays for what the reader scrolled *away*
    /// from and for the previous LOD — which is what makes scrolling and zooming back cache
    /// hits — and raising the budget raises both together.
    ///
    /// 16 MiB at the default 48 MB budget is the measured operating point; the curve it was
    /// chosen from is in the pull request (peak RSS against the bench's raster wait at 8, 16,
    /// 24 and 48 MiB, and against the fixed 3.5-viewport band).
    public static func prefetchBandBudgetBytes(cacheBudgetBytes: Int) -> Int {
        max(8 * 1024 * 1024, cacheBudgetBytes / 3)
    }

    /// `ARIS_READER_PREFETCH_RING_VH=<viewports>`: measurement override that pins the ring to
    /// exactly that distance instead of deriving it from the byte target (`2.5` reproduces the
    /// pre-change band). Documented next to the cache-budget override, and used the same way.
    static func configuredPrefetchRingOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CGFloat? {
        guard let raw = environment["ARIS_READER_PREFETCH_RING_VH"], let value = Double(raw) else {
            return nil
        }
        return min(max(CGFloat(value), 0), 4)
    }

    /// `ARIS_READER_PREFETCH_ALL_COLUMNS=1`: measurement override that restores the pre-change
    /// "every column of the page is wanted" rule, so the two halves of the band can be
    /// attributed separately.
    static func configuredWantAllColumns(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["ARIS_READER_PREFETCH_ALL_COLUMNS"] == "1"
    }

    /// `ARIS_READER_PREFETCH_BAND_MIB=<N>`: measurement override for the band's byte target, so
    /// the curve can be swept without also changing the cache budget (which is what makes the
    /// zoom-back interaction work). `ARIS_READER_PREFETCH_COLUMNS=<N>` overrides the number of
    /// columns kept ready beyond the visible ones.
    static func configuredPrefetchColumns(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        guard let raw = environment["ARIS_READER_PREFETCH_COLUMNS"], let columns = Int(raw) else {
            return prefetchColumnsToTheRight
        }
        return min(max(columns, 0), 16)
    }

    /// The `ARIS_READER_PREFETCH_*` overrides are read once: they are constants for the
    /// process, and the band is rebuilt (with `bandSpans` several times inside it) on every
    /// viewport update, i.e. on the scrolling path.
    private static let prefetchRingOverride = configuredPrefetchRingOverride()
    private static let wantAllColumns = configuredWantAllColumns()
    private static let prefetchColumns = configuredPrefetchColumns()
    private static let prefetchBandMiB = ProcessInfo.processInfo.environment["ARIS_READER_PREFETCH_BAND_MIB"]
    private static let renderStatsEnabled =
        ProcessInfo.processInfo.environment["ARIS_READER_RENDER_STATS"] == "1"
    private var pendingTiles: [(TileKey, PagePlacement)] = []
    private var pagePreviews: [Int: PageImage] = [:]
    private var pagePreviewScales: [Int: CGFloat] = [:]
    private var desiredPreviewScale: CGFloat = 1
    private let preferFullPageRasters: Bool
    public private(set) var usesScreenPageRasters = false
    public var pageRasterCacheUsedBytes: Int { pagePreviews.values.reduce(0) { $0 + $1.bgra.count } }
    public var pageRasterCacheCount: Int { pagePreviews.count }
    public func isScreenPageCached(_ page: Int) -> Bool {
        guard let image = pagePreviews[page] else { return false }
        return image.pixelWidth >= Int(floor(image.pointSize.width * zoomFactor * deviceScale))
            && image.pixelHeight >= Int(floor(image.pointSize.height * zoomFactor * deviceScale))
    }
    private var pagePreviewInFlight: Int?
    private var desiredPreviewPages: [Int] = []
    private var failedPreviewPages: Set<Int> = []
    private var failedTiles: Set<TileKey> = []
    private var scrollDirection: CGFloat = 1
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

    private enum CodingKeys: String, CodingKey {
        case id, kind, page, start, end, colorIndex, note, createdAt
    }

    public init(
        id: UUID,
        kind: Kind = .highlight,
        page: Int,
        start: Int,
        end: Int,
        colorIndex: Int,
        note: String,
        createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.page = page
        self.start = start
        self.end = end
        self.colorIndex = colorIndex
        self.note = note
        self.createdAt = createdAt
    }

    /// Older sidecars predate `kind`; decode them as highlights while preserving all
    /// explicitly stored kinds in newer sidecars.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .highlight
        page = try values.decode(Int.self, forKey: .page)
        start = try values.decode(Int.self, forKey: .start)
        end = try values.decode(Int.self, forKey: .end)
        colorIndex = try values.decode(Int.self, forKey: .colorIndex)
        note = try values.decode(String.self, forKey: .note)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
    }
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
        /// Every bibliography entry the citation named, in citation order. A grouped citation
        /// (`[1,2]`, `(He et al. 2024; Kim 2023)`) names several works and the panel lists all
        /// of them; a plain link or a figure preview has none.
        public let entries: [CitationEntry]
    }

    /// One resolved bibliography entry, as the panel lists it.
    public struct CitationEntry: Equatable, Sendable {
        public let label: String
        public let text: String
        public let page: Int?
        public let region: CGRect?

        public init(label: String, text: String, page: Int? = nil, region: CGRect? = nil) {
            self.label = label
            self.text = text
            self.page = page
            self.region = region
        }
    }

    @Published public private(set) var referencePreview: ReferencePreview?
    /// Page content for the preview panel (its own render surface).
    @Published public private(set) var referencePreviewPages: [CanvasPage] = []
    @Published public private(set) var referencePreviewZoom: CGFloat = 1

    /// Width the preview panel gives the page, in points.
    private var referencePreviewWidthPt: CGFloat = 480
    private var referencePreviewHeightPt: CGFloat = 380
    private var previewEpoch: UInt64 = 0
    @Published public private(set) var referencePreviewScrollYPt: CGFloat = 0
    @Published public private(set) var referencePreviewError: String?
    @Published public private(set) var referencePreviewLoading = false

    public func setReferencePreviewViewport(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let widthChanged = abs(referencePreviewWidthPt - size.width) > 1
        referencePreviewWidthPt = size.width
        referencePreviewHeightPt = size.height
        if widthChanged, let preview = referencePreview {
            openReferencePreview(page: preview.page, title: preview.title, from: preview.source,
                                 region: preview.region, entries: preview.entries)
        } else {
            scrollReferencePreview(by: 0)
        }
    }

    public func scrollReferencePreview(by delta: CGFloat) {
        let height = referencePreviewPages.first?.placement.heightPt ?? 0
        let visible = referencePreviewHeightPt / max(referencePreviewZoom, 0.01)
        referencePreviewScrollYPt = min(max(0, referencePreviewScrollYPt + delta / max(referencePreviewZoom, 0.01)),
                                       max(0, height - visible))
    }

    public func selectPreviewEntry(_ entry: CitationEntry) {
        guard let preview = referencePreview, let page = entry.page else { return }
        openReferencePreview(page: page, title: entry.label, from: preview.source,
                             region: entry.region, entries: preview.entries)
    }

    public func showFullPreviewPage() {
        guard let preview = referencePreview else { return }
        openReferencePreview(page: preview.page, title: preview.title, from: preview.source,
                             entries: preview.entries)
    }

    /// Opens a floating preview of `page`.
    ///
    /// `entries` is the citation's whole group of resolved works; `page`, `title` and `region`
    /// describe the **first** of them, which is what the panel's page image shows.
    public func openReferencePreview(
        page: Int,
        title: String,
        from source: String,
        region: CGRect? = nil,
        entries: [CitationEntry] = []
    ) {
        guard let document, page >= 0, page < document.pageCount else { return }
        if let region {
            guard region.minX.isFinite, region.minY.isFinite, region.width.isFinite,
                  region.height.isFinite, region.width > 0, region.height > 0 else { return }
        }
        previewEpoch &+= 1
        let request = previewEpoch
        referencePreviewPages = []
        referencePreviewScrollYPt = 0
        referencePreviewError = nil
        referencePreviewLoading = true
        referencePreview = ReferencePreview(
            page: page,
            title: title,
            source: source,
            region: region,
            entries: entries
        )

        if !entries.isEmpty {
            // stderr, not print: it is flushed immediately and survives SIGTERM, which is how
            // the "the panel received every entry" claim stays verifiable in the dev hooks.
            let labels = entries.map(\.label).joined(separator: ", ")
            FileHandle.standardError.write(
                Data("aris-preview: \"\(title)\" lists \(entries.count) entries: \(labels)\n".utf8)
            )
        }

        let widthPt = max(region?.width ?? engine.contentWidthPt(gapPt: pageGapPt), 1)
        let scale = referencePreviewWidthPt / widthPt * deviceScale
        let epoch = documentEpoch

        Task { @MainActor [weak self] in
            guard let self, request == self.previewEpoch, epoch == self.documentEpoch else { return }
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
            guard epoch == self.documentEpoch, request == self.previewEpoch else { return }
            self.referencePreviewLoading = false
            guard let image = rasterized else {
                self.referencePreviewError = "This preview could not be rendered. Try opening the full page."
                return
            }

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
        previewEpoch &+= 1
        referencePreviewLoading = false
        referencePreviewError = nil
        referencePreviewScrollYPt = 0
        referencePreview = nil
        referencePreviewPages = []
    }

    /// Highlights the reader added, and the file they are stored in.
    ///
    /// This is the array this version can *render and edit*. Entries a newer version wrote in
    /// a shape this one does not understand are not in here: they live in
    /// `annotationSidecarSlots` as raw JSON and are written back untouched (see
    /// `AnnotationSidecar`).
    @Published public private(set) var annotations: [Annotation] = []
    /// Number of sidecar entries preserved verbatim because this version cannot interpret
    /// them (unknown `kind`, colour outside the palette, unknown fields).
    @Published public private(set) var preservedAnnotationEntryCount = 0
    /// How many times this document's sidecar has been written since the document opened.
    /// Instrumentation: it is what makes write coalescing measurable instead of asserted.
    @Published public private(set) var annotationWriteCount = 0
    /// True while the note editor holds text that has not reached the sidecar yet.
    @Published public private(set) var hasPendingAnnotationWrite = false
    /// The last recovery backup, so the UI can offer to reveal it in Finder.
    @Published public private(set) var lastSidecarBackupURL: URL?
    private var annotationsURL: URL?
    /// A failed read permanently blocks writes for this document, protecting its sidecar.
    /// The only way out is the explicit recovery action, which backs the file up first.
    private var annotationWritesBlockedReason: String?
    /// The order entries had in the sidecar, so foreign entries keep their place across saves.
    private var annotationSidecarSlots: [AnnotationSidecar.Slot] = []
    /// Open coalescing window for note typing; see `updateNote`.
    private var noteFlushTask: Task<Void, Never>?
    /// True when a keystroke arrived after the current window's flush was scheduled, i.e. the
    /// reader is still typing and the window should stay open for another round.
    private var noteWindowSawKeystrokes = false
    /// How long a note edit may stay in memory only. At most one sidecar write per window
    /// while typing, plus immediate writes on commit, blur, undo, redo and flush points.
    private static let noteCoalescingWindow = Duration.milliseconds(500)
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

    /// `Figure 3` / `Table 2` mentions per page, and the document's caption index.
    ///
    /// Mentions are keyed by `(kind, label)`, which is exactly how `figures` is looked up:
    /// the mention says *what* was referenced (and where the pointer has to be), the caption
    /// record says *where it is*. Both are view-state-free, so they live here rather than in
    /// the panel.
    private var captionMentionsByPage: [Int: [CaptionMention]] = [:]
    private var captionMentionsInFlight: Set<Int> = []
    @Published public private(set) var figures: [Figure] = []
    /// Bumped on every document open, so caption data that arrives afterwards is dropped
    /// instead of being attributed to the document now on screen (the `renderEpoch` idea).
    private var documentEpoch: UInt64 = 0

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
    private var pendingThumbnails: [Int] = []
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
    private lazy var selectionImage = PageImage(
        pixelWidth: 1,
        pixelHeight: 1,
        pointSize: .zero,
        bgra: Data([0xFF, 0x80, 0x00, 0x55]),
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
        tilesInFlight.removeAll()
        wantedTiles.removeAll()
        pendingTiles = []
        failedTiles = []
        pagePreviews = [:]
        pagePreviewScales = [:]
        pagePreviewInFlight = nil
        desiredPreviewPages = []
        failedPreviewPages = []
        renderEpoch &+= 1
    }

    /// Adopts the `cacheBudgetMB` setting into the live cache (ADR 0007 wired the setting to a
    /// real consumer; the Settings window calls this when its stepper moves, so a change takes
    /// effect without a relaunch).
    ///
    /// `environment`/`defaults` are injectable so the checks can drive the same resolution the
    /// app uses without depending on how the test machine is configured.
    public func applyCacheBudgetSetting(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) {
        let bytes = Self.configuredTileCacheBudgetBytes(environment: environment, defaults: defaults)
        guard bytes != tileCache.budgetBytes else { return }
        tileCache.setBudget(bytes)
        reloadVisiblePages()
    }

    /// Tile-cache occupancy, for `ARIS_READER_RENDER_STATS=1` and the budget checks: bytes in
    /// use, the budget they fit, the high-water mark, and how many tiles were evicted.
    public var tileCacheUsedBytes: Int { tileCache.usedBytes }
    public var tileCacheBudgetBytes: Int { tileCache.budgetBytes }
    public var tileCachePeakBytes: Int { tileCache.peakBytes }
    public var tileCacheEvictions: Int { tileCache.stats.evictions }
    public var tileCacheTileCount: Int { tileCache.count }

    /// Whether one tile is cached. The budget checks use it to prove that a visible tile
    /// survived an eviction pass that a stale tile did not.
    public func isTileCached(_ key: TileKey) -> Bool { tileCache.contains(key) }
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

    /// `tileCacheBudgetBytes` pins the tile-cache budget instead of resolving it from the
    /// environment and the `cacheBudgetMB` setting; the checks use it so their arithmetic does
    /// not depend on how the machine running them is configured.
    public init(engine: PDFEngine? = nil, tileCacheBudgetBytes: Int? = nil,
                preferFullPageRasters: Bool? = nil) {
        self.preferFullPageRasters = preferFullPageRasters
            ?? (ProcessInfo.processInfo.environment["ARIS_READER_SHARP_PAGE_RASTERS"] != "0")
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
        if let tileCacheBudgetBytes { tileCache.setBudget(max(1, tileCacheBudgetBytes)) }

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
                        let figured = (followed || cited) ? false : self.openFigureMention(at: point)
                        // Resolution is asynchronous when it goes through the reference list, so
                        // give it a moment before reporting the status line.
                        try? await Task.sleep(for: .milliseconds(700))
                        let line = "aris-click: (\(parts[0]),\(parts[1])) link=\(followed) citation=\(cited) figure=\(figured) status=\(self.statusMessage)\n"
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

            // Development aid: ARIS_READER_SCROLL_AFTER=<ms> scrolls that long after launch
            // (ARIS_READER_SCROLL_FRACTION, default 0.5), so a quit or a kill can be aimed
            // inside the position debounce window instead of racing the app's startup.
            if let raw = ProcessInfo.processInfo.environment["ARIS_READER_SCROLL_AFTER"],
               let milliseconds = Int(raw), milliseconds >= 0 {
                let fraction = ProcessInfo.processInfo.environment["ARIS_READER_SCROLL_FRACTION"]
                    .flatMap(Double.init) ?? 0.5
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(milliseconds))
                    guard let self, self.document != nil else { return }
                    self.scroll(toFraction: fraction)
                    let line = "aris-position: hook scrolled to \(Int(self.scrollYPt)) pt"
                        + " at +\(milliseconds) ms (\(fraction) of the content)\n"
                    FileHandle.standardError.write(Data(line.utf8))
                }
            }

            // Measurement-only input calls the model method used by wheel events, paced
            // by wall time without waiting for rasters. It bypasses scrollWheel's immediate
            // canvas draw, exercising the queued redraw path rather than NSEvent delivery.
            if let raw = ProcessInfo.processInfo.environment["ARIS_READER_SCROLL_TRACE_SECONDS"],
               let seconds = Double(raw), seconds.isFinite, seconds > 0, seconds <= 120 {
                let speed = Double(ProcessInfo.processInfo.environment["ARIS_READER_SCROLL_TRACE_SPEED"] ?? "") ?? 600
                if speed.isFinite && speed > 0 && speed <= 10000 {
                    let epoch = documentEpoch
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(2))
                        guard let self, epoch == self.documentEpoch else { return }
                        self.scroll(toFraction: 0)
                        let start = ProcessInfo.processInfo.systemUptime
                        var previous = start
                        FileHandle.standardError.write(Data("aris-scroll-trace: {\"kind\":\"start\",\"time\":\(start)}\n".utf8))
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(1000.0 / 60.0))
                            guard epoch == self.documentEpoch, self.document != nil else { return }
                            let now = ProcessInfo.processInfo.systemUptime
                            let end = min(now, start + seconds)
                            self.scroll(byScreenPoints: CGFloat((end - previous) * speed))
                            previous = end
                            let line = "aris-scroll-trace: {\"kind\":\"tick\",\"time\":\(now),\"y\":\(self.scrollYPt),\"pending\":\(self.pendingTiles.count),\"in_flight\":\(self.tilesInFlight.count)}\n"
                            FileHandle.standardError.write(Data(line.utf8))
                            if now >= start + seconds { break }
                        }
                        let end = ProcessInfo.processInfo.systemUptime
                        FileHandle.standardError.write(Data("aris-scroll-trace: {\"kind\":\"end\",\"time\":\(end)}\n".utf8))
                    }
                }
            }

            // Development aid: ARIS_READER_ZOOM_SEQUENCE="100,400,100" applies each zoom level
            // in turn, ARIS_READER_ZOOM_STEP_MS apart (default 1200 ms), so the raster cost of
            // a zoom-in → zoom-out → zoom-in sequence is measurable headlessly: every step logs
            // the tile cache's cumulative insertion counter, and the difference between two
            // steps is how many tiles that leg rasterized. Zoom changes here go through the
            // same path as the UI's (`zoomPercent` + `reloadVisiblePages`), *without*
            // `invalidateTiles`, because dropping the cache would answer the question by
            // construction.
            if let raw = ProcessInfo.processInfo.environment["ARIS_READER_ZOOM_SEQUENCE"], !raw.isEmpty {
                let levels = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                let stepMs = Int(ProcessInfo.processInfo.environment["ARIS_READER_ZOOM_STEP_MS"] ?? "") ?? 1200
                Task { @MainActor [weak self] in
                    for (index, level) in levels.enumerated() {
                        if index > 0 { try? await Task.sleep(for: .milliseconds(stepMs)) }
                        guard let self, self.document != nil else { return }
                        self.zoomPercent = min(400, max(25, level))
                        self.reloadVisiblePages()
                        // Report the counters once this leg's band has settled: read at the
                        // instant of the zoom they would bill the *next* leg for this leg's
                        // rasters (measured: a zoom-out looked like 24 rasters that the
                        // preceding zoom-in had queued).
                        for _ in 0..<400 where !(self.pendingTiles.isEmpty && self.tilesInFlight.isEmpty) {
                            try? await Task.sleep(for: .milliseconds(25))
                        }
                        let stats = self.tileCache.stats
                        let line = "aris-zoom: step \(index) → \(self.zoomPercent)% (lod \(self.rasterLod))"
                            + " insertions \(stats.insertions) evictions \(stats.evictions)"
                            + " queue \(self.pendingTiles.count) inFlight \(self.tilesInFlight.count)\n"
                        FileHandle.standardError.write(Data(line.utf8))
                    }
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
            // Development aid: ARIS_READER_NOTE="text" types that text into the first
            // annotation's note one character at a time (a TextField setter per keystroke), so
            // write coalescing is measurable: ARIS_READER_NOTE_INTERVAL_MS sets the delay
            // between keystrokes, ARIS_READER_NOTE_COMMIT=1 commits the field at the end.
            if let text = ProcessInfo.processInfo.environment["ARIS_READER_NOTE"], !text.isEmpty {
                let interval = Int(ProcessInfo.processInfo.environment["ARIS_READER_NOTE_INTERVAL_MS"] ?? "") ?? 30
                let commit = ProcessInfo.processInfo.environment["ARIS_READER_NOTE_COMMIT"] == "1"
                Task { @MainActor [weak self] in
                    // `ARIS_READER_ANNOTATE` needs ~2.3 s to settle a selection; typing into
                    // its annotation starts after that.
                    try? await Task.sleep(for: .milliseconds(2500))
                    guard let self, let id = self.annotations.first?.id else {
                        FileHandle.standardError.write(
                            Data("aris-annotate: note hook found no annotation to type into\n".utf8)
                        )
                        return
                    }
                    let prefix = self.annotations.first(where: { $0.id == id })?.note ?? ""
                    var typed = prefix
                    for character in text {
                        typed.append(character)
                        self.updateNote(typed, for: id)
                        try? await Task.sleep(for: .milliseconds(interval))
                    }
                    if commit { self.commitNoteEdits() }
                    let line = "aris-annotate: note hook typed \(text.count) character(s)"
                        + " in \(interval) ms steps, writes so far #\(self.annotationWriteCount)\n"
                    FileHandle.standardError.write(Data(line.utf8))
                }
            }

            // Development aid: ARIS_READER_RECOVER_SIDECAR=1 runs the explicit recovery for a
            // sidecar that failed to load, so the backup path is visible on stderr.
            if ProcessInfo.processInfo.environment["ARIS_READER_RECOVER_SIDECAR"] == "1" {
                if let reason = annotationWritesBlockedReason {
                    FileHandle.standardError.write(
                        Data("aris-annotate: writes blocked: \(reason)\n".utf8)
                    )
                    let backup = recoverUnreadableAnnotationSidecar()
                    FileHandle.standardError.write(
                        Data("aris-annotate: recovery \(backup == nil ? "failed" : "backup=\(backup!.path)")\n".utf8)
                    )
                } else {
                    FileHandle.standardError.write(
                        Data("aris-annotate: recovery hook found no blocked sidecar\n".utf8)
                    )
                }
            }
        }
    }

    /// Installs the flush hooks a shell needs: the normal AppKit quit path, and the signals a
    /// harness or the OS uses to stop the app. Called once by the window when it appears — the
    /// check harness deliberately does not install it.
    public func installTerminationHandling() {
        guard terminationObserver == nil else { return }

        // A normal quit: ⌘Q, the app menu, or `NSApplication.terminate`. Delivered synchronously
        // on the posting (main) thread, before the process leaves.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPendingWrites() }
        }

        // SIGTERM/SIGINT (what a harness or the OS sends). Flush and leave directly rather than
        // asking AppKit to terminate: a *modal alert* holds `terminate` back indefinitely, and a
        // process that ignores SIGTERM is worse than one that exits without animation.
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                self?.flushPendingWrites()
                exit(128 + number) // the conventional "terminated by signal N" status
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    /// Kept so the observers can be removed if the state ever outlives the notification centre.
    private var terminationObserver: NSObjectProtocol?
    private var terminationSignalSources: [DispatchSourceSignal] = []

    public var windowTitle: String {
        document?.title ?? "Lyra"
    }

    public var pageLabel: String {
        guard let document, document.pageCount > 0 else { return "— / —" }
        return "\(currentPage) / \(document.pageCount)"
    }

    @discardableResult
    public func open(url: URL) -> Bool {
        do {
            let loaded = try engine.openDocument(at: url)
            resetDocumentState()
            document = loaded
            lastError = nil
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

            loadAnnotations(for: url)
            reloadVisiblePages()
            restoreReadingPosition(for: url)
            loadOutline()
            loadThumbnails()
            loadReferences()
            loadFigures()
            return true

        } catch {
            lastError = String(describing: error)
            statusMessage = "Couldn't open the document"
            return false
        }
    }

    private func resetDocumentState() {
        // Pending writes describe the document being replaced or closed, so they have to land
        // before the state that carries them (sidecar URL, scroll offset) is cleared.
        flushPendingWrites()
        documentEpoch &+= 1
        searchEpoch &+= 1
        positionSaveTask?.cancel()
        pendingPosition = nil
        closeReferencePreview()
        invalidateTiles()
        canvasPages = []
        canvasTiles = []
        visiblePagePlacements = []
        textPages = [:]
        textPagesInFlight = []
        linkCache = [:]
        linksInFlight = []
        citationsByPage = [:]
        citationsInFlight = []
        captionMentionsByPage = [:]
        captionMentionsInFlight = []
        figures = []
        references = []
        outline = []
        thumbnails = [:]
        thumbnailsInFlight = []
        pendingThumbnails = []
        searchHits = []
        currentHitIndex = nil
        isSearching = false
        selection = nil
        selectionAnchor = nil
        annotations = []
        annotationsURL = nil
        annotationWritesBlockedReason = nil
        annotationSidecarSlots = []
        preservedAnnotationEntryCount = 0
        hasPendingAnnotationWrite = false
        noteFlushTask?.cancel()
        noteFlushTask = nil
        undoStack = []
        redoStack = []
        scrollYPt = 0
        contentHeightPt = 0
        contentWidthPt = 0
    }

    public func zoomIn() {
        zoomPercent = min(400, zoomPercent + 10)
        reloadVisiblePages()
    }

    public func zoomOut() {
        zoomPercent = max(25, zoomPercent - 10)
        reloadVisiblePages()
    }

    public func zoomActual() {
        zoomPercent = 100
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
        thumbnails = [:]
        loadThumbnails()
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
        if delta != 0 { scrollDirection = delta > 0 ? 1 : -1 }
        let maxOffset = max(0, contentHeightPt - viewportHeightContentPt)
        let next = min(max(0, scrollYPt + contentDelta), maxOffset)
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
    private var searchEpoch: UInt64 = 0

    public func runSearch() {
        searchEpoch &+= 1
        let request = searchEpoch
        let epoch = documentEpoch
        let pattern = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard document != nil, !pattern.isEmpty else {
            searchHits = []
            currentHitIndex = nil
            isSearching = false
            return
        }

        isSearching = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard epoch == self.documentEpoch, request == self.searchEpoch else { return }
            let hits = (try? await self.engine.search(pattern, limit: 500)) ?? []
            guard epoch == self.documentEpoch, request == self.searchEpoch else { return }
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
        if annotationsURL == nil { loadAnnotations(for: url) }

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
        var updated = annotations
        updated.append(annotation)
        guard saveAnnotations(updated, trigger: "add") else { return false }
        undoStack.append(.added(annotation))
        redoStack.removeAll()
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
        let removed = annotations[index]
        var updated = annotations
        updated.remove(at: index)
        guard saveAnnotations(updated, trigger: "remove") else { return }
        undoStack.append(.removed(removed))
        redoStack.removeAll()
        reloadVisiblePages()
        statusMessage = "Deleted annotation"
    }

    // MARK: - Undo / redo

    /// One reversible change. Note edits are represented as old/new values so an edit can
    /// be undone and redone together with annotation creation and deletion.
    public enum UndoableAction: Sendable {
        case added(Annotation)
        case removed(Annotation)
        case noteChanged(id: UUID, oldNote: String, newNote: String)
    }

    @Published public private(set) var undoStack: [UndoableAction] = []
    @Published public private(set) var redoStack: [UndoableAction] = []

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func undo() {
        guard let action = undoStack.last else { return }
        flushPendingAnnotationWrite()
        let updated = annotations(applying: action, undoing: true)
        guard saveAnnotations(updated, trigger: "undo") else { return }
        undoStack.removeLast()
        redoStack.append(action)
        reloadVisiblePages()
        statusMessage = "Undo"
    }

    public func redo() {
        guard let action = redoStack.last else { return }
        flushPendingAnnotationWrite()
        let updated = annotations(applying: action, undoing: false)
        guard saveAnnotations(updated, trigger: "redo") else { return }
        redoStack.removeLast()
        undoStack.append(action)
        reloadVisiblePages()
        statusMessage = "Redo"
    }

    private func annotations(applying action: UndoableAction, undoing: Bool) -> [Annotation] {
        var updated = annotations
        switch action {
        case .added(let annotation):
            if undoing {
                updated.removeAll { $0.id == annotation.id }
            } else if !updated.contains(where: { $0.id == annotation.id }) {
                updated.append(annotation)
            }
        case .removed(let annotation):
            if undoing {
                if !updated.contains(where: { $0.id == annotation.id }) { updated.append(annotation) }
            } else {
                updated.removeAll { $0.id == annotation.id }
            }
        case .noteChanged(let id, let oldNote, let newNote):
            if let index = updated.firstIndex(where: { $0.id == id }) {
                updated[index].note = undoing ? oldNote : newNote
            }
        }
        return updated
    }

    /// Applies a note keystroke.
    ///
    /// Memory and the undo stack update on every call — typing has to stay responsive — but the
    /// *disk* write is coalesced: the first keystroke of a window writes as every other
    /// mutation does (candidate first, publish only if it landed), and further keystrokes
    /// within `noteCoalescingWindow` are carried to disk by one scheduled flush. Committing the
    /// field, blurring it, undo/redo, switching documents and quitting all flush immediately.
    public func updateNote(_ note: String, for id: UUID) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        let oldNote = annotations[index].note
        guard oldNote != note else { return }

        var updated = annotations
        updated[index].note = note
        let mergedUndo = undoStack(mergingNoteEditFor: id, from: oldNote, to: note)

        if noteFlushTask != nil {
            // A coalescing window is already open: publish now, let the scheduled flush write.
            annotations = updated
            undoStack = mergedUndo
            redoStack.removeAll()
            hasPendingAnnotationWrite = true
            noteWindowSawKeystrokes = true
            return
        }

        // First keystroke of a window: exactly the old, safe path — the candidate goes to disk
        // first and memory/undo are published only if that write succeeded.
        guard saveAnnotations(updated, trigger: "keystroke") else { return }
        annotations = updated
        undoStack = mergedUndo
        redoStack.removeAll()
        scheduleNoteFlush()
    }

    /// SwiftUI's TextField setter fires for each keystroke. Merge consecutive edits to
    /// the same note into one undo step while preserving the original value.
    private func undoStack(
        mergingNoteEditFor id: UUID,
        from oldNote: String,
        to note: String
    ) -> [UndoableAction] {
        var stack = undoStack
        if let last = stack.last,
           case .noteChanged(let lastID, let original, let previous) = last,
           lastID == id, previous == oldNote {
            stack.removeLast()
            if original != note {
                stack.append(.noteChanged(id: id, oldNote: original, newNote: note))
            }
        } else {
            stack.append(.noteChanged(id: id, oldNote: oldNote, newNote: note))
        }
        return stack
    }

    private func scheduleNoteFlush() {
        noteFlushTask?.cancel()
        noteWindowSawKeystrokes = false
        noteFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.noteCoalescingWindow)
            guard !Task.isCancelled else { return }
            self?.noteCoalescingWindowElapsed()
        }
    }

    /// One coalescing window is over: write what is pending, and stay open while the reader is
    /// still typing. That is what bounds a burst to roughly one write per window instead of
    /// one write per keystroke *and* a second one each time a window closes.
    private func noteCoalescingWindowElapsed() {
        noteFlushTask = nil
        if hasPendingAnnotationWrite {
            _ = saveAnnotations(annotations, trigger: "coalesced")
        }
        // A failed write closes the window instead of rescheduling: the next keystroke then
        // takes the safe synchronous path again and can report the failure to the reader.
        guard noteWindowSawKeystrokes, !hasPendingAnnotationWrite else { return }
        scheduleNoteFlush()
    }

    /// True while an open coalescing window is still holding note text back from the sidecar.
    /// (Instrumentation: it is what lets a check or a log line tell "queued" from "written".)
    public var noteWriteWindowIsOpen: Bool { noteFlushTask != nil }

    /// Called when the note field is committed (Return) or loses focus: the text reaches the
    /// sidecar now instead of at the end of the coalescing window.
    public func commitNoteEdits() {
        flushPendingAnnotationWrite()
    }

    /// Writes a note edit that is still only in memory. Returns false when the write failed
    /// (the pending state is kept, so the next flush point retries it).
    @discardableResult
    public func flushPendingAnnotationWrite() -> Bool {
        noteFlushTask?.cancel()
        noteFlushTask = nil
        noteWindowSawKeystrokes = false
        guard hasPendingAnnotationWrite else { return true }
        return saveAnnotations(annotations, trigger: "flush")
    }

    /// Lands everything that is still only in memory. Called on quit, on document switch, on
    /// tab close and by `resetDocumentState`, so a scroll or a typed note cannot be lost just
    /// because the debounce had not expired yet.
    public func flushPendingWrites() {
        let pendingNote = hasPendingAnnotationWrite
        let pendingPosition = self.pendingPosition != nil
        guard pendingNote || pendingPosition else { return }
        if pendingNote { flushPendingAnnotationWrite() }
        if pendingPosition { flushPendingPositionSave() }
        let written = [pendingNote ? "note" : nil, pendingPosition ? "position" : nil]
            .compactMap { $0 }
            .joined(separator: " + ")
        FileHandle.standardError.write(Data("aris-annotate: flushed pending \(written)\n".utf8))
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
        let sidecarURL = Self.sidecarURL(for: url)
        annotationsURL = sidecarURL
        annotationWritesBlockedReason = nil
        preservedAnnotationEntryCount = 0
        annotationSidecarSlots = []
        annotationWriteCount = 0
        hasPendingAnnotationWrite = false

        do {
            _ = try FileManager.default.attributesOfItem(atPath: sidecarURL.path)
            let data = try Data(contentsOf: sidecarURL)
            let contents = try AnnotationSidecar.decode(
                data,
                pageCount: document?.pageCount ?? 0,
                paletteCount: Self.highlightPalette.count
            )
            annotations = contents.annotations
            annotationSidecarSlots = contents.slots
            preservedAnnotationEntryCount = contents.preservedCount
            undoStack.removeAll()
            redoStack.removeAll()
            let line = "aris-annotate: loaded \(contents.annotations.count) annotation(s)"
                + ", \(contents.preservedCount) preserved from a newer version\n"
            FileHandle.standardError.write(Data(line.utf8))
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            annotations = []
            undoStack.removeAll()
            redoStack.removeAll()
        } catch {
            annotations = []
            undoStack.removeAll()
            redoStack.removeAll()
            annotationWritesBlockedReason = error.localizedDescription
            statusMessage = "Could not read annotations; the sidecar is protected from overwrite"
            lastError = statusMessage
            FileHandle.standardError.write(
                Data("aris-annotate: read failed; writes blocked: \(error)\n".utf8)
            )
        }
    }

    /// Writes a candidate first and publishes it only after the atomic write succeeds.
    /// Any unreadable/corrupt existing sidecar is protected from accidental replacement.
    ///
    /// `trigger` only labels the stderr instrumentation line, so a run can show *why* a write
    /// happened (a keystroke, a coalesced flush, a tab switch, …).
    @discardableResult
    private func saveAnnotations(_ candidate: [Annotation], trigger: String) -> Bool {
        guard let annotationsURL else {
            statusMessage = "Could not save annotations: no document sidecar is selected"
            lastError = statusMessage
            return false
        }
        if let reason = annotationWritesBlockedReason {
            statusMessage = "Could not save annotations because the sidecar could not be loaded; it was left untouched"
            lastError = statusMessage
            FileHandle.standardError.write(
                Data("aris-annotate: write blocked [\(trigger)]: \(reason)\n".utf8)
            )
            return false
        }

        do {
            let data = try AnnotationSidecar.encode(
                annotations: candidate,
                slots: annotationSidecarSlots
            )
            try data.write(to: annotationsURL, options: .atomic)
            annotations = candidate
            hasPendingAnnotationWrite = false
            annotationWriteCount += 1
            let line = "aris-annotate: saved \(candidate.count) annotation(s)"
                + " (\(preservedAnnotationEntryCount) preserved),"
                + " write #\(annotationWriteCount) [\(trigger)]\n"
            FileHandle.standardError.write(Data(line.utf8))
            return true
        } catch {
            statusMessage = "Could not save annotations: \(error.localizedDescription)"
            lastError = statusMessage
            FileHandle.standardError.write(
                Data("aris-annotate: save failed [\(trigger)]: \(error)\n".utf8)
            )
            return false
        }
    }

    // MARK: - Recovery from a sidecar that cannot be read

    /// True when this document's sidecar failed to load, so writes are refused until the
    /// reader explicitly decides what to do with the file.
    public var canRecoverUnreadableAnnotationSidecar: Bool {
        annotationsURL != nil && annotationWritesBlockedReason != nil
    }

    /// The explicit way out of the blocked state.
    ///
    /// It never overwrites the unreadable file: the sidecar is *moved* to
    /// `<name>.corrupt-<timestamp>.json` in the same directory, so the reader can inspect or
    /// restore it, and only then is a fresh empty sidecar written. Returns the backup URL, or
    /// `nil` when nothing was recovered (in which case the blocked state is kept and the
    /// reason is reported).
    @discardableResult
    public func recoverUnreadableAnnotationSidecar() -> URL? {
        guard let sidecarURL = annotationsURL, annotationWritesBlockedReason != nil else { return nil }

        let fileManager = FileManager.default
        var backupURL: URL?
        if fileManager.fileExists(atPath: sidecarURL.path) {
            let destination = Self.uniqueBackupURL(for: sidecarURL)
            do {
                try fileManager.moveItem(at: sidecarURL, to: destination)
                backupURL = destination
                FileHandle.standardError.write(
                    Data("aris-annotate: moved unreadable sidecar to \(destination.path)\n".utf8)
                )
            } catch {
                let message = "Could not back up the unreadable annotation sidecar: \(error.localizedDescription)"
                statusMessage = message
                lastError = message
                FileHandle.standardError.write(
                    Data("aris-annotate: recovery failed, sidecar left in place: \(error)\n".utf8)
                )
                return nil
            }
        }

        // The path is free now, so a stale blocked flag must not stop the fresh write.
        annotationWritesBlockedReason = nil
        annotations = []
        annotationSidecarSlots = []
        preservedAnnotationEntryCount = 0
        undoStack.removeAll()
        redoStack.removeAll()
        lastSidecarBackupURL = backupURL

        guard saveAnnotations([], trigger: "recovery") else {
            // The rename succeeded but the directory is not writable: keep refusing writes so
            // the state stays honest, and let the reader retry (the file is already backed up).
            annotationWritesBlockedReason = lastError ?? "the sidecar could not be recreated"
            return nil
        }

        statusMessage = backupURL.map {
            "Backed up the unreadable annotations to \($0.lastPathComponent) and started a fresh sidecar"
        } ?? "Started a fresh annotation sidecar"
        return backupURL
    }

    /// `<doc>.pdf.aris-annotations.json` → `<doc>.pdf.aris-annotations.corrupt-<stamp>.json`,
    /// with a numeric suffix if that name is taken: an earlier backup is never overwritten.
    static func uniqueBackupURL(for sidecarURL: URL, now: Date = Date()) -> URL {
        let base = sidecarURL.deletingPathExtension()
        let stamp = backupStampFormatter.string(from: now)
        var candidate = base.appendingPathExtension("corrupt-\(stamp).json")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = base.appendingPathExtension("corrupt-\(stamp)-\(counter).json")
            counter += 1
        }
        return candidate
    }

    private static let backupStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// Reveals a recovery backup in Finder (called by the UI, never by the checks).
    public func revealSidecarBackupInFinder(_ url: URL? = nil) {
        guard let target = url ?? lastSidecarBackupURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([target])
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
            let epoch = documentEpoch
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard epoch == self.documentEpoch else { return }
                defer { if epoch == self.documentEpoch { self.linksInFlight.remove(page) } }
                if let links = try? await self.engine.links(page) {
                    guard epoch == self.documentEpoch else { return }
                    self.linkCache[page] = links
                }
            }
        }
    }

    /// Ends a pointer interaction: a click follows a link, a drag keeps the selection so
    /// ⌘C can copy it.
    public func endPointerInteraction(at point: CGPoint, wasClick: Bool) {
        guard wasClick else {
            extendSelection(to: point)
            return
        }
        previewEpoch &+= 1

        // A click tries three things, in this order:
        //   1. a link annotation — the PDF's own target, and the only one that can leave the
        //      document (a URI), so it always wins;
        //   2. an in-text citation — `[12]`, `(Kim 2023)`;
        //   3. a `Figure 3` / `Table 2` mention.
        // Citation before mention because the two can overlap at one point (a citation group
        // inside a sentence that also names a figure), and the citation is the narrower,
        // more specific match; a mention never resolves to something a citation resolves to,
        // so nothing is lost by the order. Each step returns false when it has nothing, so
        // the chain falls through cleanly.
        let handled = followLink(at: point)
            || openCitation(at: point)
            || openFigureMention(at: point)
        if handled || selection == nil {
            clearSelection()
        }
    }

    /// Fetches the figure/table mentions of every visible page, so a click resolves immediately.
    ///
    /// Called from `reloadVisiblePages`, so a page that has just been scrolled into view gets
    /// its mentions before the pointer can reach them; the cache makes the repeated calls free.
    private func loadCaptionMentions() {
        for placement in visiblePagePlacements where captionMentionsByPage[placement.index] == nil {
            guard !captionMentionsInFlight.contains(placement.index) else { continue }
            captionMentionsInFlight.insert(placement.index)

            let page = placement.index
            let epoch = documentEpoch
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard epoch == self.documentEpoch else { return }
                defer { if epoch == self.documentEpoch { self.captionMentionsInFlight.remove(page) } }
                if let found = try? await self.engine.captionMentions(page: page) {
                    guard epoch == self.documentEpoch else { return }
                    self.captionMentionsByPage[page] = found
                }
            }
        }
    }

    /// Loads the figure/table caption index once per open document (see `open(url:)`).
    private func loadFigures() {
        guard figures.isEmpty else { return }
        let epoch = documentEpoch
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard epoch == self.documentEpoch else { return }
            let found = (try? await self.engine.figures()) ?? []
            guard epoch == self.documentEpoch else { return }
            self.figures = found
            FileHandle.standardError.write(
                Data("aris-figures: \(self.figures.count) caption(s)\n".utf8)
            )
        }
    }

    /// Fetches the citations of every visible page, so a click resolves immediately.
    private func loadCitations() {
        for placement in visiblePagePlacements where citationsByPage[placement.index] == nil {
            guard !citationsInFlight.contains(placement.index) else { continue }
            citationsInFlight.insert(placement.index)

            let page = placement.index
            let epoch = documentEpoch
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard epoch == self.documentEpoch else { return }
                defer { if epoch == self.documentEpoch { self.citationsInFlight.remove(page) } }
                if let found = try? await self.engine.citations(page) {
                    guard epoch == self.documentEpoch else { return }
                    self.citationsByPage[page] = found
                }
            }
        }
    }

    /// Loads the reference list once (it never changes for an open document).
    private func loadReferences() {
        guard references.isEmpty else { return }
        let epoch = documentEpoch
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard epoch == self.documentEpoch else { return }
            let found = (try? await self.engine.references()) ?? []
            guard epoch == self.documentEpoch else { return }
            self.references = found
            FileHandle.standardError.write(
                Data("aris-references: \(self.references.count) entries\n".utf8)
            )
        }
    }

    /// Opens the references an in-text citation points at (M4).
    ///
    /// This is the path that works **without** a link annotation: detect `[12,13]`, resolve
    /// **every** label against the reference list, and preview them. The panel's image shows
    /// the first entry's own rectangle and lists all of them. Returns false when the point is
    /// not on a citation, or when the citation names nothing we can resolve.
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

                // Resolution lives in Rust: exact label match, then position for a numeric
                // citation against an unnumbered list, once per label so a group resolves
                // whole. The shell only draws the result.
                let labels = citation.labels
                // A long group can wrap in the text layer; the title and the log stay one line.
                let written = citation.text
                    .split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ")
                let epoch = documentEpoch
                let request = previewEpoch
                Task { @MainActor [weak self] in
                    guard let self, epoch == self.documentEpoch, request == self.previewEpoch else { return }
                    let resolved = (try? await self.engine.resolveCitations(labels: labels)) ?? []
                    guard epoch == self.documentEpoch, request == self.previewEpoch else { return }
                    guard let first = resolved.first else {
                        self.statusMessage = "Citation \"\(written)\" has no matching entry"
                        return
                    }

                    self.openReferencePreview(
                        page: first.page,
                        // The panel names the citation as it appears in the text, so a group
                        // is recognisable at a glance.
                        title: written,
                        from: "page \(placement.index + 1)",
                        region: CGRect(
                            x: first.xPt,
                            y: first.yPt,
                            width: first.widthPt,
                            height: first.heightPt
                        ),
                        entries: resolved.map {
                            CitationEntry(label: $0.label, text: $0.text, page: $0.page,
                                region: CGRect(x: $0.xPt, y: $0.yPt, width: $0.widthPt, height: $0.heightPt))
                        }
                    )
                    if resolved.count == 1 {
                        self.statusMessage = "Reference [\(first.label)]: \(first.text.prefix(48))"
                    } else {
                        let named = resolved.map(\.label).joined(separator: ", ")
                        self.statusMessage = "\(written) names \(resolved.count) references: \(named)"
                    }
                }
                return true
            }
        }
        return false
    }

    /// Opens the caption a `Figure 3` / `Table 2` mention in the body points at (M4).
    ///
    /// This is the path that works **without** a link annotation: the mention is found in the
    /// page's text layer, its `kind` + `label` are the key into the document-wide caption
    /// index (`figures()`), and the record carries the region to preview — the artwork plus
    /// its caption, or the caption alone for vector figures.
    ///
    /// True means the preview was opened. False means it was not: the point is not on a
    /// mention, the caption is not in the index (the scan stops after 120 pages, so a
    /// reference to a late figure has nothing to show), or the page's mentions are still on
    /// their way — that last case continues in `resolveFigureMention`, so the panel opens a
    /// moment later even though this call could not know it yet.
    @discardableResult
    public func openFigureMention(at point: CGPoint) -> Bool {
        for placement in visiblePagePlacements {
            let pageRect = CGRect(
                x: placement.leftPt,
                y: placement.topPt,
                width: placement.widthPt,
                height: placement.heightPt
            )
            guard pageRect.contains(point) else { continue }

            let local = CGPoint(x: point.x - placement.leftPt, y: point.y - placement.topPt)
            guard let mentions = captionMentionsByPage[placement.index] else {
                // The page's mentions are still being fetched — their first read is queued
                // behind the document-wide scans, so a click can beat them. The pointer has
                // already said which page it meant: resolve when the data lands instead of
                // dropping the click. Nothing is known synchronously, so report "not handled"
                // and let the panel appear a moment later.
                resolveFigureMention(on: placement.index, at: local)
                return false
            }
            guard let mention = mention(at: local, in: mentions) else { continue }
            return openFigure(mention, from: placement.index)
        }
        return false
    }

    /// The mention whose box contains a view-space point, if any.
    private func mention(at local: CGPoint, in mentions: [CaptionMention]) -> CaptionMention? {
        mentions.first { mention in
            CGRect(
                x: mention.xPt,
                y: mention.yPt,
                width: mention.widthPt,
                height: mention.heightPt
            ).contains(local)
        }
    }

    /// Opens the preview for the caption `mention` names (the tail both click paths share).
    @discardableResult
    private func openFigure(_ mention: CaptionMention, from page: Int) -> Bool {
        guard let figure = figures.first(where: {
            $0.kind == mention.kind && $0.label == mention.label
        }) else {
            statusMessage = "No caption indexed for \"\(mention.title)\""
            return false
        }

        let title = figure.title
        // stderr, not print: unbuffered, so the hit is visible even when the process is killed
        // right after the click (the same reason the raster log exists).
        FileHandle.standardError.write(
            Data(String(
                format: "aris-figure: \"%@\" -> page %d region (%.1f, %.1f, %.1f, %.1f)\n",
                title,
                figure.page + 1,
                figure.xPt,
                figure.yPt,
                figure.widthPt,
                figure.heightPt
            ).utf8)
        )

        openReferencePreview(
            page: figure.page,
            title: title,
            from: "page \(page + 1)",
            region: CGRect(
                x: figure.xPt,
                y: figure.yPt,
                width: figure.widthPt,
                height: figure.heightPt
            ),
            // The panel's body is the reference-entry list, so the caption rides in it as a
            // single entry rather than a second text path in the panel.
            entries: [CitationEntry(label: title, text: figure.captionText)]
        )
        statusMessage = "Previewing \(title)"
        return true
    }

    /// Fetches what the cold click path is missing (the page's mentions, the caption index)
    /// and opens the caption if the point really was on a mention.
    ///
    /// The document-wide index is usually already in flight (`loadFigures`); asking the engine
    /// again here costs one extra scan only in the rare case where a click beats both loads,
    /// which is cheaper than keeping a second copy of the in-flight state.
    private func resolveFigureMention(on page: Int, at local: CGPoint) {
        let epoch = documentEpoch
        let request = previewEpoch
        Task { @MainActor [weak self] in
            guard let self else { return }
            let index = self.figures.isEmpty
                ? ((try? await self.engine.figures()) ?? [])
                : self.figures
            let mentions: [CaptionMention]
            if let cached = self.captionMentionsByPage[page] {
                mentions = cached
            } else {
                mentions = (try? await self.engine.captionMentions(page: page)) ?? []
            }

            // A newer click or document switch supersedes this lookup.
            guard epoch == self.documentEpoch, request == self.previewEpoch else { return }
            self.figures = index
            self.captionMentionsByPage[page] = mentions

            guard let mention = self.mention(at: local, in: mentions) else { return }
            self.openFigure(mention, from: page)
        }
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
                    if openCitation(at: point) || openFigureMention(at: point) { return true }
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
        guard open(url: url) else { return }
        tabs.append(OpenTab(url: url, title: url.deletingPathExtension().lastPathComponent,
                            scrollYPt: scrollYPt))
        activeTabIndex = tabs.count - 1
    }

    public func selectTab(_ index: Int) {
        guard tabs.indices.contains(index), index != activeTabIndex else { return }
        saveActiveTabPosition()
        guard open(url: tabs[index].url) else { return }
        activeTabIndex = index
        restoreActiveTabPosition()
    }

    public func closeTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        saveActiveTabPosition()
        if index != activeTabIndex {
            tabs.remove(at: index)
            if let active = activeTabIndex, index < active { activeTabIndex = active - 1 }
            return
        }
        tabs.remove(at: index)
        activeTabIndex = nil
        resetDocumentState()
        document = nil
        guard !tabs.isEmpty else { return }
        let next = min(index, tabs.count - 1)
        if open(url: tabs[next].url) {
            activeTabIndex = next
            restoreActiveTabPosition()
        }
    }

    private func saveActiveTabPosition() {
        guard let index = activeTabIndex, tabs.indices.contains(index) else { return }
        tabs[index].scrollYPt = scrollYPt
    }

    private func restoreActiveTabPosition() {
        guard let index = activeTabIndex, tabs.indices.contains(index) else { return }
        let saved = tabs[index].scrollYPt
        scrollYPt = min(saved, max(0, contentHeightPt - viewportHeightContentPt))
        reloadVisiblePages()
    }

    /// Loads the document outline (once per document).
    public func loadOutline() {
        guard document != nil else {
            outline = []
            return
        }
        let epoch = documentEpoch
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard epoch == self.documentEpoch else { return }
            let found = (try? await self.engine.outline()) ?? []
            guard epoch == self.documentEpoch else { return }
            self.outline = found
        }
    }

    /// Rasterizes the first pages at thumbnail size for the sidebar.
    public func loadThumbnails(page requestedPage: Int? = nil) {
        guard let document, document.pageCount > 0 else {
            thumbnails = [:]
            return
        }

        let pages = requestedPage.map { [$0] } ?? Array(0..<min(document.pageCount, thumbnailLimit))
        for page in pages where page >= 0 && page < document.pageCount {
            guard thumbnails[page] == nil, !thumbnailsInFlight.contains(page), !pendingThumbnails.contains(page) else { continue }
            if requestedPage != nil { pendingThumbnails.insert(page, at: 0) }
            else { pendingThumbnails.append(page) }
        }
        pumpThumbnails()
    }

    private func pumpThumbnails() {
        guard thumbnailsInFlight.isEmpty, !pendingThumbnails.isEmpty, let document else { return }
        let page = pendingThumbnails.removeFirst()
        thumbnailsInFlight.insert(page)
        let backingScale = deviceScale
        let targetWidth = Int((thumbnailWidthPt * max(backingScale, 1)).rounded())
        // Supersample before reduction: a PDFium minimum-width stroke must not
        // become an opaque pixel in the final thumbnail (or two on a Retina display).
        let scale = CGFloat(targetWidth * 4) / max(document.firstPageSize.width, 1)
        let epoch = documentEpoch
        Task { @MainActor [weak self] in
            guard let self, epoch == self.documentEpoch else { return }
            let image = try? await self.engine.renderPage(page, scale: scale)
            guard epoch == self.documentEpoch else { return }
            if backingScale == self.deviceScale, let image {
                let reduced = await Task.detached { image.downsampled(toWidth: targetWidth) }.value
                guard epoch == self.documentEpoch else { return }
                if backingScale == self.deviceScale { self.thumbnails[page] = reduced }
                else { self.pendingThumbnails.insert(page, at: 0) }
            } else if backingScale != self.deviceScale {
                self.pendingThumbnails.insert(page, at: 0)
            }
            self.thumbnailsInFlight.remove(page)
            self.pumpThumbnails()
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
        pendingPosition = PendingPosition(url: url, offset: scrollYPt)
        positionSaveTask?.cancel()
        positionSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.positionSaveTask = nil
            _ = self?.commitPendingPositionSave(trigger: "debounce")
        }
    }

    /// Writes a position that is still only in memory (quit, document switch, tab close).
    @discardableResult
    public func flushPendingPositionSave() -> Bool {
        positionSaveTask?.cancel()
        positionSaveTask = nil
        return commitPendingPositionSave(trigger: "flush")
    }

    private func commitPendingPositionSave(trigger: String) -> Bool {
        guard let pending = pendingPosition else { return true }
        pendingPosition = nil
        // Prefer the live offset: while its document is still on screen it is the reader's
        // real position, which matters when a restore or a resize moved it after scheduling.
        let offset = document?.url == pending.url ? scrollYPt : pending.offset
        UserDefaults.standard.set(Double(offset), forKey: Self.positionKey(for: pending.url))
        // The system flushes defaults on a normal quit but not when the process is killed,
        // and losing the reading position is exactly what this flush exists to prevent.
        UserDefaults.standard.synchronize()
        FileHandle.standardError.write(
            Data("aris-position: saved \(Int(offset)) pt [\(trigger)]\n".utf8)
        )
        return true
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
        // A scrollbar drag is a scroll like any other: it has to schedule the same debounced
        // position save, or a drag right before quitting would be lost.
        schedulePositionSave()
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

    /// Ordinary zoom uses an atomic screen-resolution page plus a byte-bounded neighborhood.
    /// Large pages/deep zoom use tiles. Complete visible-width rows sharpen during scrolling;
    /// already sharp rows stay in place while newly exposed rows load.
    ///
    /// Zoom reuses the existing raster immediately. On a LOD change, retain the previous
    /// tiles until all visible tiles on that page are ready, then replace them together.
    /// This prevents the page from disappearing or sharpening in a visible diagonal sweep.
    public func reloadVisiblePages() {
        guard document != nil else {
            canvasPages = []
            canvasTiles = []
            contentHeightPt = 0
            return
        }

        contentHeightPt = engine.contentHeightPt(gapPt: pageGapPt)
        contentWidthPt = engine.contentWidthPt(gapPt: pageGapPt)

        let viewportHeight = viewportHeightContentPt
        let margin = viewportHeight * 2
        let visible = engine.visiblePages(
            scrollYPt: scrollYPt,
            viewportHeightPt: viewportHeight,
            gapPt: pageGapPt,
            marginPt: margin
        )

        let lod = rasterLod
        let scale = CGFloat(1 << Int(lod))
        let tilePt = CGFloat(tileSizePx) / scale

        // What the reader can actually see, in content points. The canvas centres the content
        // when it is narrower than the viewport, which is the same transform `PDFCanvasView`
        // applies to every page; when the page is wider there is no horizontal scrolling, so
        // the visible window is the left one.
        let viewport = visibleContentRect(viewportHeight: viewportHeight)

        // The band: viewport + ring, where the ring is picked so the band's bytes fit the
        // band budget (see `prefetchRingVh`).
        let ringVh = prefetchRingVh(viewportHeight: viewportHeight, tilePt: tilePt, pages: visible)
        let band = bandSpans(ringVh: ringVh, viewportHeight: viewportHeight, tilePt: tilePt, pages: visible)

        visiblePagePlacements = Array(visible)

        // `wanted` is the scheduling set (viewport + prefetch band); it doubles as the pinned
        // set for eviction and is rebuilt with every viewport update.
        wantedTiles.removeAll()

        pendingTiles = []
        // At ordinary zoom, one screen-resolution raster is cheaper than many
        // oversized pyramid tiles and can be presented atomically. Larger pages
        // and deep zoom retain the bounded tile path.
        let screenScale = max(zoomFactor * deviceScale, 0.05)
        usesScreenPageRasters = preferFullPageRasters && Self.maxPreviewPages > 0 && !band.isEmpty
            && band.allSatisfy { canRasterizeScreenPage($0.placement, scale: screenScale) }
        configurePagePreviews(visible: visible, band: band, viewport: viewport,
                              viewportHeight: viewportHeight, screenScale: screenScale)
        schedulePagePreview()
        var wanted = Set<TileKey>()
        var pages: [CanvasPage] = []
        var bandReport = BandReport()

        for span in band {
            let placement = span.placement
            var sharpRows: [CanvasPage] = []
            var complete = true
            let previous = canvasTiles.filter { $0.placement.index >= 0 && $0.placement.index >> 24 == placement.index }
            let changingLOD = previous.contains { ($0.placement.index >> 20) & 15 != Int(lod) }
            if usesScreenPageRasters, !failedPreviewPages.contains(placement.index) {
                let preview = pagePreviews[placement.index]
                let attempted = (pagePreviewScales[placement.index] ?? 0) >= screenScale
                // A backend-clamped/invalid page raster must fall back to tiles,
                // rather than treating an undersized image as screen-resolution.
                if !attempted || isScreenPageCached(placement.index) {
                    if let preview, isScreenPageCached(placement.index) || previous.isEmpty {
                        pages.append(canvasPageRaster(preview, placement: placement))
                    } else if !previous.isEmpty {
                        pages.append(contentsOf: previous)
                    } else if let thumbnail = thumbnails[placement.index] {
                        pages.append(canvasPageRaster(thumbnail, placement: placement))
                    }
                    continue
                }
            }
            // The pinned set is the *shown* band plus the ring the byte budget allows: a tile
            // outside the band may be re-rasterized, a visible one may not be dropped.

            for ty in span.rows {
                var rowReady: [CanvasPage] = []
                var rowComplete = true
                for tx in span.columns {
                    let key = TileKey(page: placement.index, lod: lod, x: tx, y: ty)
                    wanted.insert(key)

                    let tilePlacement = PagePlacement(
                        index: tileIdentifier(key),
                        topPt: placement.topPt + CGFloat(ty) * tilePt,
                        leftPt: placement.leftPt + CGFloat(tx) * tilePt,
                        widthPt: min(tilePt, placement.widthPt - CGFloat(tx) * tilePt),
                        heightPt: min(tilePt, placement.heightPt - CGFloat(ty) * tilePt)
                    )
                    let classOf = BandClass(
                        rect: CGRect(x: tilePlacement.leftPt, y: tilePlacement.topPt,
                                     width: tilePlacement.widthPt, height: tilePlacement.heightPt),
                        viewport: viewport
                    )

                    if let cached = tileCache.image(for: key) {
                        rowReady.append(CanvasPage(placement: tilePlacement, image: cached))
                        bandReport.record(classOf, bytes: cached.bgra.count)
                    } else {
                        tileCache.recordMiss()
                        bandReport.record(classOf, bytes: 0)
                        if tilePlacement.leftPt < viewport.maxX,
                           tilePlacement.leftPt + tilePlacement.widthPt > viewport.minX {
                            rowComplete = false
                        }
                        if classOf == .visible {
                            complete = false
                            bandReport.visibleMisses += 1
                        }
                        scheduleTile(key, placement: tilePlacement)
                    }
                }
                if rowComplete {
                    sharpRows.append(contentsOf: rowReady)
                } else {
                    // A newly exposed row may be incomplete. Never blur tiles that were
                    // already shown sharply, including after a viewport widens.
                    sharpRows.append(contentsOf: previous.filter {
                        ($0.placement.index >> 20) & 15 == Int(lod)
                            && ($0.placement.index >> 10) & 1023 == ty
                            && span.columns.contains($0.placement.index & 1023)
                    })
                }
            }
            if !complete, !changingLOD,
               let preview = pagePreviews[placement.index] ?? thumbnails[placement.index] {
                // The preview is only a backdrop for uncovered rows, never a replacement
                // for the sharp content the reader is already looking at.
                pages.append(CanvasPage(placement: PagePlacement(index: -3_000_000_000 - placement.index,
                    topPt: placement.topPt, leftPt: placement.leftPt,
                    widthPt: placement.widthPt, heightPt: placement.heightPt), image: preview))
            }
            if changingLOD && !complete {
                pages.append(contentsOf: previous)
            } else {
                pages.append(contentsOf: sharpRows)
            }
        }
        let viewportTop = scrollYPt
        pendingTiles.sort { a, b in
            func priority(_ item: (TileKey, PagePlacement)) -> (Int, CGFloat) {
                let rect = item.1
                let visible = CGRect(x: rect.leftPt, y: rect.topPt,
                                     width: rect.widthPt, height: rect.heightPt).intersects(viewport)
                let distance = max(viewportTop - rect.topPt - rect.heightPt,
                    rect.topPt - viewportTop - viewportHeight, 0)
                // An offscreen neighbor touching the viewport also has distance zero.
                // A page jump must fill its destination before that prefetch work.
                return (visible ? 0 : 1, distance)
            }
            return priority(a) < priority(b)
        }
        pumpTiles()

        canvasTiles = pages
        appendSelectionHighlights(to: &pages)
        prefetchTextLayers(for: visible)
        loadCaptionMentions()
        loadLinks()
        loadCitations()
        wantedTiles = wanted
        evictTiles()
        canvasPages = pages
        currentPage = engine.pageIndex(atScrollYPt: scrollYPt, gapPt: pageGapPt) + 1
        reportTileCacheStats(
            wanted: wanted.count, scheduled: pendingTiles.count, band: bandReport,
            ringVh: ringVh, lod: lod, tilePt: tilePt, pages: pages.count
        )
    }

    /// Where one wanted tile sits relative to what the viewport shows. The band HUD reports
    /// tiles and bytes per class, because "the prefetch band" is three different costs: what is
    /// on screen (which may not be dropped), the rows above and below (the ring), and the
    /// columns a page wider than the viewport adds (which nothing can scroll to).
    enum BandClass {
        case visible
        case ring
        case offscreenColumn

        init(rect: CGRect, viewport: CGRect) {
            if rect.intersects(viewport) {
                self = .visible
            } else if rect.maxY > viewport.minY && rect.minY < viewport.maxY {
                self = .offscreenColumn
            } else {
                self = .ring
            }
        }
    }

    /// Running totals for one viewport update (`ARIS_READER_RENDER_STATS=1`).
    struct BandReport {
        var tileCounts: [Int] = [0, 0, 0]
        var byteCounts: [Int] = [0, 0, 0]
        /// Visible tiles that were *not* cached: raster work the reader is waiting for. It is
        /// the number the band exists to keep at zero, and the one a shorter band can push up.
        var visibleMisses = 0

        private func index(_ kind: BandClass) -> Int {
            switch kind {
            case .visible: return 0
            case .ring: return 1
            case .offscreenColumn: return 2
            }
        }

        mutating func record(_ kind: BandClass, bytes: Int) {
            tileCounts[index(kind)] += 1
            byteCounts[index(kind)] += bytes
        }

        func tiles(_ kind: BandClass) -> Int { tileCounts[index(kind)] }
        func bytes(_ kind: BandClass) -> Int { byteCounts[index(kind)] }
    }

    /// The part of the content the viewport shows, in content points. The canvas centres the
    /// content when it is narrower than the viewport (`PDFCanvasView.renderFrame`), which is
    /// the same transform; when a page is wider there is no horizontal scrolling, so the
    /// visible window is its left edge.
    private func visibleContentRect(viewportHeight: CGFloat) -> CGRect {
        let zoom = max(zoomFactor, 0.01)
        let centreOffsetPt = max(0, (viewportSizePt.width - contentWidthPt * zoomFactor) / 2)
        return CGRect(
            x: -centreOffsetPt / zoom,
            y: scrollYPt,
            width: max(1, viewportSizePt.width) / zoom,
            height: viewportHeight
        )
    }

    /// The ring above and below the viewport, in viewport heights.
    ///
    /// Both numbers are distances from the viewport's *top* edge (`scrollYPt`), which is how
    /// ADR 0007 wrote them: the viewport itself is the interval [0, 1], so a ring of `R`
    /// viewports is `above + below = 1 + R` and never less than 1 — the band must contain the
    /// viewport whatever the budget says, or the reader stares at tiles the scheduler decided
    /// not to want.
    ///
    /// The ring is asymmetric on purpose — most of it points the way the reader is scrolling —
    /// and the shape ADR 0007 shipped (0.5 above / 2.0 below the viewport going down, 2.0/0.5
    /// going up) is kept as the *ratio* for every shorter ring, so shortening the band never
    /// changes which side it favours, only how far it reaches.
    private func ringSplit(_ ringVh: CGFloat) -> (above: CGFloat, below: CGFloat) {
        if scrollDirection < 0 {
            return (ringVh * 2.0 / Self.maxPrefetchRingVh, 1 + ringVh * 0.5 / Self.maxPrefetchRingVh)
        }
        return (ringVh * 0.5 / Self.maxPrefetchRingVh, 1 + ringVh * 2.0 / Self.maxPrefetchRingVh)
    }

    /// Rungs the ring is chosen from, longest first, ending at the floor. The ladder is coarse
    /// on purpose: each rung is a whole row of tiles at ordinary geometries, so a finer ladder
    /// would buy bytes the band HUD cannot even show.
    static let prefetchRingLadder: [CGFloat] = [2.5, 2.0, 1.5, 1.25, 1.0, minPrefetchRingVh]

    /// Picks the ring distance: the longest rung whose band fits `prefetchBandBudgetBytes`.
    ///
    /// The estimate is the band this update is about to build, tile for tile — cached tiles at
    /// their real (often cropped) size, the rest at a full tile — so the choice and the
    /// scheduling loop cannot drift apart.
    private func prefetchRingVh(
        viewportHeight: CGFloat,
        tilePt: CGFloat,
        pages: [PagePlacement]
    ) -> CGFloat {
        if let override = Self.prefetchRingOverride {
            return min(override, Self.maxPrefetchRingVh)
        }
        let budget = Self.prefetchBandMiB.flatMap(Int.init)
            .map { min(max($0, 1), 512) * 1024 * 1024 }
            ?? Self.prefetchBandBudgetBytes(cacheBudgetBytes: tileCache.budgetBytes)
        let lod = rasterLod
        let fullTileBytes = tileSizePx * tileSizePx * 4
        for rung in Self.prefetchRingLadder {
            let bytes = bandSpans(ringVh: rung, viewportHeight: viewportHeight, tilePt: tilePt, pages: pages)
                .reduce(0) { bandBytes, span in
                    bandBytes + span.rows.reduce(0) { rowBytes, ty in
                        rowBytes + span.columns.reduce(0) { columnBytes, tx in
                            columnBytes + (tileCache.bytes(for: TileKey(page: span.placement.index, lod: lod, x: tx, y: ty))
                                ?? fullTileBytes)
                        }
                    }
                }
            if bytes <= budget { return rung }
        }
        return Self.prefetchRingLadder.last ?? Self.minPrefetchRingVh
    }

    /// The tile rows and columns the band covers, per visible page.
    private struct BandSpan {
        let placement: PagePlacement
        let columns: ClosedRange<Int>
        let rows: ClosedRange<Int>
    }

    /// The rows and columns of every visible page that the band covers.
    ///
    /// Rows come from the ring; columns come from what the viewport can reveal. ADR 0007 wanted
    /// *every* column, on the grounds that "a page is a handful of columns wide" — true at 100%
    /// zoom (3 columns, all on screen), false at 400% (10 columns, 3 on screen), where the
    /// unreachable ones were 24 of the 110 tiles (22.2 of 99.2 MiB). There is no horizontal
    /// scrolling, so the columns off to the right can only be revealed by a widening window,
    /// which rasterizes them on demand behind the whole-page preview that is already there for
    /// an incomplete page — that trade is measured, not assumed: see `minPrefetchRingVh`.
    private func bandSpans(
        ringVh: CGFloat,
        viewportHeight: CGFloat,
        tilePt: CGFloat,
        pages: [PagePlacement]
    ) -> [BandSpan] {
        let (above, below) = ringSplit(ringVh)
        let top = scrollYPt - viewportHeight * above
        let bottom = scrollYPt + viewportHeight * below
        let viewport = visibleContentRect(viewportHeight: viewportHeight)
        let allColumns = Self.wantAllColumns

        return pages.compactMap { placement in
            let rows = max(1, Int(ceil(placement.heightPt / tilePt)))
            let firstRow = max(0, Int(floor((top - placement.topPt) / tilePt)))
            let lastRow = min(rows - 1, Int(floor((bottom - placement.topPt) / tilePt)))
            guard firstRow <= lastRow else { return nil }

            let columns = max(1, Int(ceil(placement.widthPt / tilePt)))
            var firstColumn = 0
            var lastColumn = columns - 1
            if !allColumns {
                firstColumn = max(0, min(columns - 1, Int(floor((viewport.minX - placement.leftPt) / tilePt))))
                lastColumn = min(columns - 1, max(firstColumn, Int(floor((viewport.maxX - placement.leftPt) / tilePt))
                    + Self.prefetchColumns))
            }
            return BandSpan(
                placement: placement,
                columns: firstColumn...lastColumn,
                rows: firstRow...lastRow
            )
        }
    }

    /// `ARIS_READER_RENDER_STATS=1`: the shell's half of the HUD documented in docs/09 §9 —
    /// tile-cache occupancy in tiles *and bytes*, hit rate, evictions and the byte peak per
    /// viewport update. Off by default and silent unless asked for; it changes no scheduling
    /// decision, it only counts and reports. The byte counters are what proves the ADR 0007
    /// budget actually bounds the cache.
    private func reportTileCacheStats(
        wanted: Int,
        scheduled: Int,
        band: BandReport,
        ringVh: CGFloat,
        lod: UInt8,
        tilePt: CGFloat,
        pages: Int
    ) {
        guard Self.renderStatsEnabled else { return }
        let stats = tileCache.stats
        let mib = 1024.0 * 1024.0
        let line = String(
            format: "aris-stats: cache %d tiles · %.1f/%.1f MiB · peak %.1f MiB · wanted %d · queued %d · hits %d · misses %d · hit rate %.1f%% · insertions %d · evictions %d (%.1f MiB)\n",
            tileCache.count,
            Double(tileCache.usedBytes) / mib, Double(tileCache.budgetBytes) / mib,
            Double(tileCache.peakBytes) / mib,
            wanted, scheduled, stats.hits, stats.misses, stats.hitRate * 100.0,
            stats.insertions, stats.evictions, Double(stats.evictedBytes) / mib
        )
        FileHandle.standardError.write(Data(line.utf8))

        // What the peak is actually made of: the band split by what the reader can see, what
        // the cache holds *besides* the band (scroll-back history and the previous LOD), and
        // the other rasters the shell keeps (page previews, sidebar thumbnails, text layers).
        var staleTiles = 0
        var staleBytes = 0
        for key in tileCache.keys() where !wantedTiles.contains(key) {
            staleTiles += 1
            staleBytes += tileCache.bytes(for: key) ?? 0
        }
        let previewBytes = pagePreviews.values.reduce(0) { $0 + $1.bgra.count }
        let thumbnailBytes = thumbnails.values.reduce(0) { $0 + $1.bgra.count }
        let textBytes = textPages.values.reduce(0) { $0 + $1.chars.count * MemoryLayout<TextChar>.size }
        let bandLine = String(
            format: "aris-band: visible %d tiles (%.1f MiB) · ring %d (%.1f MiB) · offscreenCols %d (%.1f MiB) · stale %d (%.1f MiB) · previews %.1f MiB · thumbnails %.1f MiB · text %.1f MiB · ringVh %.2f · visibleMiss %d · lod %d · tilePt %.0f · bandPages %d\n",
            band.tiles(.visible), Double(band.bytes(.visible)) / mib,
            band.tiles(.ring), Double(band.bytes(.ring)) / mib,
            band.tiles(.offscreenColumn), Double(band.bytes(.offscreenColumn)) / mib,
            staleTiles, Double(staleBytes) / mib,
            Double(previewBytes) / mib, Double(thumbnailBytes) / mib, Double(textBytes) / mib,
            ringVh, band.visibleMisses, Int(lod), tilePt, pages
        )
        FileHandle.standardError.write(Data(bandLine.utf8))
    }

    /// Updates overlays without reloading tiles or scheduling document analysis during a drag.
    private func refreshSelectionOverlay() {
        var pages = canvasTiles
        appendSelectionHighlights(to: &pages)
        canvasPages = pages
    }

    /// Adds continuous line rectangles for selection and annotations.
    ///
    /// Everything translucent — the selection and every highlight — is drawn by the same
    /// textured-quad pipeline as the pages, so annotation rendering needs no new GPU path.
    private func appendSelectionHighlights(to pages: inout [CanvasPage]) {
        if let selection {
            appendHighlight(
                page: selection.page,
                range: selection.range,
                image: selectionImage,
                idBase: -1_000_000_000,
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
                idBase: -2_000_000_000 + annotationIndex * 4_096,
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

        for (index, rect) in textPage.selectionRects(in: range).enumerated() {
            pages.append(CanvasPage(
                placement: PagePlacement(
                    index: idBase + index,
                    topPt: placement.topPt + rect.minY + rect.height * verticalOffset,
                    leftPt: placement.leftPt + rect.minX,
                    widthPt: rect.width,
                    heightPt: max(rect.height * verticalScale, 1)
                ),
                image: image
            ))
        }
    }

    /// Fetches the text layer of every visible page (once), so hit-testing is instant.
    private func prefetchTextLayers(for placements: [PagePlacement]) {
        for placement in placements where textPages[placement.index] == nil {
            guard !textPagesInFlight.contains(placement.index) else { continue }
            textPagesInFlight.insert(placement.index)

            let page = placement.index
            let epoch = documentEpoch
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard epoch == self.documentEpoch else { return }
                defer { if epoch == self.documentEpoch { self.textPagesInFlight.remove(page) } }
                if let extracted = try? await self.engine.textPage(page) {
                    guard epoch == self.documentEpoch else { return }
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
        refreshSelectionOverlay()
    }

    /// Extends the selection to a point in content space.
    public func extendSelection(to point: CGPoint) {
        guard let anchor = selectionAnchor,
              let current = selection,
              let hit = characterIndex(at: point, extendingSelection: true),
              hit.page == current.page
        else { return }

        let range = min(anchor, hit.index)...max(anchor, hit.index)
        guard range != current.range else { return }
        selection = Selection(page: current.page, range: range)
        refreshSelectionOverlay()
    }

    public func clearSelection() {
        guard selection != nil || selectionAnchor != nil else { return }
        selection = nil
        selectionAnchor = nil
        refreshSelectionOverlay()
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

    /// Hit-test the nearest visual line, including inferred whitespace, before its characters.
    private func characterIndex(at point: CGPoint, extendingSelection: Bool = false) -> (page: Int, index: Int)? {
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
            if let index = textPage.characterIndex(at: local, extendingSelection: extendingSelection) {
                return (placement.index, index)
            }
            return nil
        }
        return nil
    }

    /// Rasterizes one tile in the background and folds it into the cache.
    private func scheduleTile(_ key: TileKey, placement: PagePlacement) {
        guard !tilesInFlight.contains(key), !failedTiles.contains(key) else { return }
        pendingTiles.append((key, placement))
    }

    private func pumpTiles() {
        while tilesInFlight.count < Self.maxConcurrentTileRasters, !pendingTiles.isEmpty {
            let (key, placement) = pendingTiles.removeFirst()
            startTile(key, placement: placement)
        }
    }

    private func startTile(_ key: TileKey, placement: PagePlacement) {
        tilesInFlight.insert(key)

        let epoch = renderEpoch
        let tileSize = tileSizePx
        Task { @MainActor [weak self] in
            guard let self, epoch == self.renderEpoch else { return }

            do {
                let tile = try await self.engine.rasterizeTile(
                    page: key.page,
                    lod: key.lod,
                    tileX: key.x,
                    tileY: key.y,
                    tileSize: tileSize
                )
                guard epoch == self.renderEpoch else { return }
                self.tilesInFlight.remove(key)

                let image = tile.pageImage(pointSize: CGSize(width: placement.widthPt, height: placement.heightPt))
                self.tileCache.insert(image, for: key)
                self.reloadVisiblePages()
            } catch {
                guard epoch == self.renderEpoch else { return }
                self.tilesInFlight.remove(key)
                self.failedTiles.insert(key)
                self.lastError = String(describing: error)
                self.reloadVisiblePages()
            }
        }
    }

    private func canvasPageRaster(_ image: PageImage, placement: PagePlacement) -> CanvasPage {
        CanvasPage(placement: PagePlacement(index: -3_000_000_000 - placement.index,
            topPt: placement.topPt, leftPt: placement.leftPt,
            widthPt: placement.widthPt, heightPt: placement.heightPt), image: image)
    }

    private func screenPageBytes(_ placement: PagePlacement, scale: CGFloat) -> CGFloat {
        ceil(placement.widthPt * scale) * ceil(placement.heightPt * scale) * 4
    }

    private func canRasterizeScreenPage(_ placement: PagePlacement, scale: CGFloat) -> Bool {
        let bytes = screenPageBytes(placement, scale: scale)
        // Leave room for at least two visible/adjacent pages, and stay below the
        // FFI's 8-Mpixel / 8192px whole-page clamp (which would silently blur it).
        return bytes <= CGFloat(min(tileCache.budgetBytes / 2, 8 * 1024 * 1024 * 4))
            && max(placement.widthPt, placement.heightPt) * scale <= 8192
    }

    private func configurePagePreviews(visible: [PagePlacement], band: [BandSpan], viewport: CGRect,
                                       viewportHeight: CGFloat, screenScale: CGFloat) {
        desiredPreviewScale = usesScreenPageRasters ? screenScale : 1
        let current = engine.pageIndex(atScrollYPt: scrollYPt, gapPt: pageGapPt)
        let bandPages = Set(band.map(\.placement.index))
        let candidates: [PagePlacement]
        let budget: Int
        if usesScreenPageRasters {
            candidates = engine.visiblePages(scrollYPt: scrollYPt, viewportHeightPt: viewportHeight,
                gapPt: pageGapPt, marginPt: max(viewportHeight * 2, (document?.firstPageSize.height ?? 0) * 3))
                .filter { abs($0.index - current) <= 3 && canRasterizeScreenPage($0, scale: screenScale) }
            budget = tileCache.budgetBytes
        } else {
            candidates = visible.filter { bandPages.contains($0.index) }
            // Previews and tiles share one pixel budget, including their different
            // resolutions. The unavoidable visible/pinned set may exceed it.
            let tileBytes = band.reduce(0) { total, span in
                total + span.rows.reduce(0) { rowTotal, y in
                    rowTotal + span.columns.reduce(0) { columnTotal, x in
                        columnTotal + (tileCache.bytes(for: TileKey(page: span.placement.index,
                            lod: rasterLod, x: x, y: y)) ?? tileSizePx * tileSizePx * 4)
                    }
                }
            }
            budget = max(0, tileCache.budgetBytes - tileBytes)
        }
        func onScreen(_ p: PagePlacement) -> Bool {
            CGRect(x: p.leftPt, y: p.topPt, width: p.widthPt, height: p.heightPt).intersects(viewport)
        }
        let ordered = candidates.sorted { a, b in
            if onScreen(a) != onScreen(b) { return onScreen(a) }
            let ad = abs(a.index - current), bd = abs(b.index - current)
            if ad != bd { return ad < bd }
            return scrollDirection > 0 ? a.index > b.index : a.index < b.index
        }
        var bytes = 0
        desiredPreviewPages = []
        for p in ordered {
            guard desiredPreviewPages.count < (usesScreenPageRasters ? Self.maxPreviewPages : min(4, Self.maxPreviewPages))
            else { break }
            let cost = max(pagePreviews[p.index]?.bgra.count ?? 0,
                           Int(screenPageBytes(p, scale: desiredPreviewScale)))
            // A page currently on screen is the same exception as a pinned tile.
            if bytes + cost <= budget || onScreen(p) {
                desiredPreviewPages.append(p.index)
                bytes += cost
            }
        }
        let keeping = Set(desiredPreviewPages)
        pagePreviews = pagePreviews.filter { keeping.contains($0.key) }
        pagePreviewScales = pagePreviewScales.filter { keeping.contains($0.key) }
    }

    /// One page request at a time: each wheel event updates the neighborhood and
    /// direction immediately, without waiting for scroll idle or queueing old pages.
    private func schedulePagePreview() {
        guard pagePreviewInFlight == nil,
              let page = desiredPreviewPages.first(where: {
                  (pagePreviewScales[$0] ?? 0) < desiredPreviewScale && !failedPreviewPages.contains($0)
              }) else { return }
        pagePreviewInFlight = page
        let scale = desiredPreviewScale
        let epoch = renderEpoch
        Task { @MainActor [weak self] in
            guard let self, epoch == self.renderEpoch else { return }
            do {
                let image = try await self.engine.renderPage(page, scale: scale)
                guard epoch == self.renderEpoch else { return }
                if self.desiredPreviewPages.contains(page), scale >= (self.pagePreviewScales[page] ?? 0) {
                    self.pagePreviews[page] = image
                    self.pagePreviewScales[page] = scale
                }
            } catch {
                guard epoch == self.renderEpoch else { return }
                self.failedPreviewPages.insert(page)
            }
            self.pagePreviewInFlight = nil
            self.reloadVisiblePages()
        }
    }

    /// Brings the cache back inside its byte budget (ADR 0007).
    ///
    /// Pinned: every tile the current viewport update wants (the visible band *and* the
    /// prefetch band — see `wantedTiles` for the measurement behind that) plus every raster in
    /// flight. Everything else is evictable, and the order is LOD-aware LRU
    /// (`TileCache.evictToFit`): a tile from a LOD the reader has zoomed away from goes first,
    /// then the least recently used tile the reader has scrolled past.
    ///
    /// If the wanted band alone exceeds the budget the cache stays over it: evicting a tile the
    /// scheduler is about to ask for again trades a bounded number of bytes for an unbounded
    /// number of re-rasterizations, and the measurement says that trade is a loss.
    private func evictTiles() {
        guard tileCache.usedBytes + pageRasterCacheUsedBytes > tileCache.budgetBytes else { return }
        tileCache.evictToFit(pinned: wantedTiles.union(tilesInFlight), currentLod: rasterLod,
                            reservedBytes: pageRasterCacheUsedBytes)
    }
}
