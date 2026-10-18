import ArisReaderFFI
import Combine
import AppKit
import Foundation
import UniformTypeIdentifiers

/// Sidebar tabs (see `docs/04-ui-ux.md` §2.2).
public enum SidebarTab: String, CaseIterable, Identifiable, Sendable {
    case thumbnails
    case outline
    case bookmarks
    case annotations
    case metadata
    case search
    case ai

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .thumbnails: return "Thumbnails"
        case .outline: return "Outline"
        case .bookmarks: return "Bookmarks"
        case .annotations: return "Annotations"
        case .metadata: return "Metadata"
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
        case .metadata: return "text.badge.checkmark"
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
        case .metadata: return "M4"
        case .search: return "M2"
        case .ai: return "M5"
        }
    }
}

/// Application state (the single source of truth is the Rust engine; only **view state** is kept here).
///
/// The skeleton phase uses `ObservableObject` (rather than the newer `@Observable`) to maximize
/// toolchain compatibility; see the "Negatives / costs" section of `docs/adr/0006`.
/// A colour an annotation is drawn in: 8-bit sRGB channels plus opacity.
///
/// The alpha channel exists because a PDF annotation carries its opacity separately from its
/// colour (`/C` and `/CA`), and because a highlight is *meant* to be translucent: 0x66 is the
/// alpha every preset below uses, so the text under a highlight stays readable.
///
/// Encoded as a single `#RRGGBBAA` string in the sidecar: one key, and impossible to misread the
/// channel order of.
public struct AnnotationColor: Codable, Equatable, Hashable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    /// 255 = fully opaque.
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `#RRGGBBAA`, upper case, the same shape `to_hex_with_alpha` uses on the Rust side.
    public var hex: String {
        String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
    }

    /// Parses `#RRGGBBAA` (or `#RRGGBB`, taken as opaque). Anything else is rejected rather than
    /// guessed at: a sidecar is a file the reader must be able to trust.
    public init?(hex: String) {
        var digits = hex
        guard digits.hasPrefix("#") else { return nil }
        digits.removeFirst()
        guard digits.count == 6 || digits.count == 8,
              digits.allSatisfy({ $0.isHexDigit }),
              let value = UInt32(digits, radix: 16)
        else { return nil }
        if digits.count == 6 {
            self.init(
                red: UInt8((value >> 16) & 0xFF),
                green: UInt8((value >> 8) & 0xFF),
                blue: UInt8(value & 0xFF),
                alpha: 255
            )
        } else {
            self.init(
                red: UInt8((value >> 24) & 0xFF),
                green: UInt8((value >> 16) & 0xFF),
                blue: UInt8((value >> 8) & 0xFF),
                alpha: UInt8(value & 0xFF)
            )
        }
    }

    /// BGRA — the byte order every texture in this engine is uploaded in.
    public var bgra: [UInt8] { [blue, green, red, alpha] }

    /// The colour a sticky note is drawn in when the file states none of its own.
    ///
    /// The file's `/C` always wins. This is only the "the file did not say" case, and it is a
    /// note yellow rather than the neutral grey the markup path substitutes: a note's icon is a
    /// *glyph* that says "there is a comment here", and every viewer draws it in the colour people
    /// read as one. (The sticky note in `tests/fixtures/annotated.pdf` has no `/C` at all, so this
    /// is what that page shows.)
    public static let defaultNote = AnnotationColor(
        red: 0xFF,
        green: 0xCC,
        blue: 0x33,
        alpha: 0xFF
    )

    public init(bgra: [UInt8]) {
        self.init(red: bgra[2], green: bgra[1], blue: bgra[0], alpha: bgra[3])
    }

    /// Blends this colour towards white by `opacity`, in the stored (gamma-encoded) space.
    ///
    /// This is what a `/BM /Multiply` highlight needs before it is uploaded: PDF composites a
    /// multiply annotation as `page × (a·colour + (1 − a))`, and the GPU multiplies in linear
    /// light, so the opacity has to be folded into the colour here or a translucent highlight
    /// comes out visibly brighter than the file says (measured 23/255 on a mid tone at `/CA 0.5`).
    public func baked(opacity: Double) -> AnnotationColor {
        let a = min(max(opacity, 0.0), 1.0)
        let opaque: Double = 1.0 - a
        func mix(_ channel: UInt8) -> UInt8 {
            let value: Double = a * Double(channel) + opaque * 255.0
            return UInt8(min(max(value.rounded(), 0.0), 255.0))
        }
        return AnnotationColor(red: mix(red), green: mix(green), blue: mix(blue), alpha: 255)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let color = AnnotationColor(hex: text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "expected #RRGGBB or #RRGGBBAA, got \(text)"
            )
        }
        self = color
    }
}

/// A user bookmark: a named place in this document.
///
/// `yPt` is a **page-local** content-space Y (0 at the page's top), not a scroll offset. A
/// bookmark therefore stays on its paragraph when the window is resized, the zoom changes or
/// the layout switches between continuous and facing pages — all of those move a page's top
/// without moving anything inside the page.
///
/// Persisted in the same sidecar as the reader's annotations, tagged `"kind": "bookmark"`.
/// The tag is what keeps an annotation-only build from misreading the entry: that build puts
/// unknown kinds in its verbatim bucket before it looks at `page` or `title`, so it preserves
/// this entry even though `yPt` is not an annotation key. See `AnnotationSidecar`.
public struct Bookmark: Identifiable, Codable, Equatable, Sendable {
    /// The discriminator written to the sidecar. Also the reason an older build preserves the
    /// entry instead of trying to decode it as a highlight.
    public static let sidecarKind = "bookmark"

    public let id: UUID
    public var page: Int
    public var title: String
    /// Page-local Y in points, 0 at the page's top.
    public var yPt: CGFloat
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        page: Int,
        title: String,
        yPt: CGFloat = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.page = page
        self.title = title
        self.yPt = yPt
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, page, title, yPt, createdAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        // `kind` is checked by `AnnotationSidecar` before this decoder runs. Tolerating its
        // absence here keeps the model decodable on its own (tests, future formats).
        _ = try values.decodeIfPresent(String.self, forKey: .kind)
        page = try values.decode(Int.self, forKey: .page)
        title = try values.decode(String.self, forKey: .title)
        yPt = try values.decode(CGFloat.self, forKey: .yPt)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(Self.sidecarKind, forKey: .kind)
        try values.encode(page, forKey: .page)
        try values.encode(title, forKey: .title)
        try values.encode(yPt, forKey: .yPt)
        try values.encode(createdAt, forKey: .createdAt)
    }
}

/// The reader's global layout preferences (T2.10): facing pages and the gap between pages.
///
/// These are view preferences, not document content, so they live in `UserDefaults` rather
/// than in the sidecar: a reader who prefers facing spreads wants them in the next paper too,
/// and the sidecar is the place for marks on *this* file. The checks disable stored lookups
/// (`AppState.usesStoredReadingLayoutPreferences`) so their geometry never depends on what the
/// person running them chose in the app.
public enum ReadingLayoutPreferences {
    public static let layoutKey = "readerLayoutMode"
    public static let gapKey = "pageGapPt"
    public static let didChange = Notification.Name("LyraReadingLayoutPreferencesDidChange")

    public static let defaultGapPt: CGFloat = 12
    /// A continuous range with honest bounds: 0 packs pages together, 48 is already more
    /// whitespace than a reader needs between two pages. The layout clamps, it does not trust.
    public static let gapRange: ClosedRange<CGFloat> = 0...48

    public static func clampGap(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return defaultGapPt }
        return min(max(value, gapRange.lowerBound), gapRange.upperBound)
    }

    public static func layoutMode(defaults: UserDefaults = .standard) -> ReaderLayoutMode {
        guard let raw = defaults.string(forKey: layoutKey),
              let mode = ReaderLayoutMode(rawValue: raw) else { return .continuous }
        return mode
    }

    public static func gapPt(defaults: UserDefaults = .standard) -> CGFloat {
        guard defaults.object(forKey: gapKey) != nil else { return defaultGapPt }
        return clampGap(CGFloat(defaults.double(forKey: gapKey)))
    }

    static func store(layoutMode: ReaderLayoutMode, defaults: UserDefaults = .standard) {
        defaults.set(layoutMode.rawValue, forKey: layoutKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func store(gapPt: CGFloat, defaults: UserDefaults = .standard) {
        defaults.set(Double(clampGap(gapPt)), forKey: gapKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

@MainActor
public final class AppState: ObservableObject {
    @Published public var document: LoadedDocument?
    @Published public var sidebarTab: SidebarTab = .thumbnails
    @Published public var sidebarVisible: Bool = true
    @Published public var pageOverviewVisible: Bool = false
    @Published public var zoomPercent: Int = 100
    @Published public var currentPage: Int = 1
    @Published public var statusMessage: String = "Drag in a PDF, or press ⌘O to open a document"
    @Published public var lastError: String?
    @Published public var showFileImporter: Bool = false

    // ── Page editing (T3.9) ────────────────────────────────────────────────────
    /// Pages selected in the thumbnail sidebar (0-based). Empty means "the current page".
    @Published public private(set) var pageSelection: Set<Int> = []
    /// The page a shift-click extends from.
    private var pageSelectionAnchor: Int?
    /// Human-readable, newest-last list of page changes staged in the working copy.
    @Published public private(set) var pageEditPendingOperations: [String] = []
    /// Set only for a moment after an explicit apply, so the interface can say "applied".
    @Published public private(set) var pageEditIsApplied: Bool = false
    /// True while PDFium is rewriting a revision; commands are disabled rather than queued.
    @Published public private(set) var pageEditBusy: Bool = false
    /// The staged session. Nil means the file on disk is the document on screen.
    private var pageEditSession: PageEditSession?

    /// Pages the canvas should draw right now (usually one or two while scrolling).
    @Published public private(set) var canvasPages: [CanvasPage] = []
    private var canvasTiles: [CanvasPage] = []
    /// Scroll offset in content points; 0 is the top of the first page.
    @Published public private(set) var scrollYPt: CGFloat = 0
    /// True while the user is scrolling, so the indicator stays on screen.
    @Published public private(set) var isScrolling = false
    /// True while the pointer is in the indicator's lane, so a faded-out scroller comes back as
    /// soon as the reader reaches for it.
    @Published public private(set) var isScrollIndicatorHovered = false
    /// True from a press on the indicator's thumb until the release. It keeps the thumb visible
    /// and tells the view to stop easing the thumb while the hand is on it.
    @Published public private(set) var isDraggingScrollIndicator = false
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

    /// Gap between pages, in points. Set through `setPageGap` so it is clamped and the layout
    /// is rebuilt immediately; read by the engine on every layout query.
    @Published public private(set) var pageGapPt: CGFloat = ReadingLayoutPreferences.defaultGapPt
    /// How pages are arranged horizontally (continuous or facing spreads).
    @Published public private(set) var layoutMode: ReaderLayoutMode = .continuous
    /// The gap range the Settings slider and the checks share.
    public static let pageGapRange = ReadingLayoutPreferences.gapRange

    /// Whether this process reads (and writes) the stored reading preferences.
    ///
    /// The regression checks set this to `false` before constructing any state: their geometry
    /// must be the same on a machine where the reader happened to leave facing mode at 48 pt.
    /// The app never changes it.
    public static var usesStoredReadingLayoutPreferences = true

    /// Set while `AppState` listens for a preference change made in another window.
    private var layoutPreferencesObserver: NSObjectProtocol?

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
    /// Why the screen-resolution page path is off, or nil when it is on. Set with every
    /// viewport update (see `screenPagePathDecision`) and reported once per change to stderr
    /// and in the `ARIS_READER_RENDER_STATS` line, so a degraded configuration is visible
    /// rather than silent.
    public private(set) var screenPagePathNote: String?
    /// Compact form of the same reason, for the one-line stats field.
    public private(set) var screenPagePathSummary = "pending"
    private var lastScreenPagePathNote: String?
    private var hasReportedScreenPagePath = false
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
    /// How the annotation is drawn.
    ///
    /// The first two kinds address a character range in the page's text layer. `ink`, `square`,
    /// `circle`, `line` and `arrow` are geometry annotations stored in **page space** (points,
    /// origin at the page's top-left corner at 100% zoom), so a mark lands on the same place at
    /// every zoom. The four shapes are stroked, never filled: they are outlines, and keeping the
    /// interior transparent is what lets the text behind them stay selectable.
    public enum Kind: String, Codable, Sendable {
        case highlight
        case underline
        case ink
        case square
        case circle
        case line
        case arrow

        /// Whether this kind is stored as geometry rather than as a character range.
        public var isGeometry: Bool {
            switch self {
            case .highlight, .underline: return false
            case .ink, .square, .circle, .line, .arrow: return true
            }
        }
    }

    /// One point of a stored ink stroke or line, as the sidecar writes it.
    ///
    /// Deliberately not `CGPoint`: the JSON shape is part of the sidecar's compatibility story
    /// (a newer build reads it, an older build preserves the whole entry), and spelling out
    /// `x`/`y` keeps that shape independent of a platform type's Codable representation.
    public struct StoredPoint: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// One rectangle, in the same page space as `inkPaths`.
    public struct StoredRect: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// The sidecar schema version of a geometry entry.
    ///
    /// Text-markup entries have no version: they are the shape every older build already knows.
    /// Geometry entries do, so a newer build can change them without an older one guessing at
    /// the new meaning. `AnnotationSidecar` preserves any entry it cannot interpret verbatim.
    public static let geometryVersion = 1

    public let id: UUID
    /// Defaults to `.highlight` for sidecars written before kinds existed.
    public var kind: Kind = .highlight
    public var page: Int
    /// Inclusive character range in the page's text layer; zero for geometry annotations.
    public var start: Int
    public var end: Int
    /// The colour to draw, as it will be drawn.
    ///
    /// This used to be `colorIndex`, an index into a four-entry palette, which made every colour
    /// outside that palette unrepresentable — including every colour already inside a PDF
    /// somebody else had annotated. A stored colour is what the annotation *is*; the palette is
    /// only a list of presets offered when creating one.
    public var color: AnnotationColor
    public var note: String
    public var createdAt: Date
    /// Ink strokes, page space. Empty for every kind except `.ink`.
    public var inkPaths: [[CGPoint]] = []
    /// The stroked rectangle, page space. `nil` for every kind except `.square` and `.circle`.
    public var shapeRect: CGRect?
    /// Line endpoints, page space. `nil` for every kind except `.line` and `.arrow`.
    public var lineStart: CGPoint?
    public var lineEnd: CGPoint?
    /// The stroke width in points. Constant for the whole mark; zero for text markup.
    public var strokeWidth: CGFloat = 0

    private enum CodingKeys: String, CodingKey {
        case id, kind, page, start, end, color, colorIndex, note, createdAt
        case version, paths, rect, lineStart, lineEnd, strokeWidth
    }

    public init(
        id: UUID,
        kind: Kind = .highlight,
        page: Int,
        start: Int,
        end: Int,
        color: AnnotationColor,
        note: String,
        createdAt: Date,
        inkPaths: [[CGPoint]] = [],
        shapeRect: CGRect? = nil,
        lineStart: CGPoint? = nil,
        lineEnd: CGPoint? = nil,
        strokeWidth: CGFloat = 0
    ) {
        self.id = id
        self.kind = kind
        self.page = page
        self.start = start
        self.end = end
        self.color = color
        self.note = note
        self.createdAt = createdAt
        self.inkPaths = inkPaths
        self.shapeRect = shapeRect
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.strokeWidth = strokeWidth
    }

    /// Whether the annotation's geometry is complete and finite.
    ///
    /// The sidecar encoder and the write-back path both rely on this: a mark that cannot be
    /// drawn or written must be refused before it reaches a file, not turned into an empty
    /// annotation on the page.
    public var hasValidGeometry: Bool {
        guard strokeWidth.isFinite, strokeWidth > 0, strokeWidth <= 200 else { return false }
        switch kind {
        case .ink:
            return !inkPaths.isEmpty && inkPaths.allSatisfy { path in
                path.count >= 2 && path.allSatisfy { $0.x.isFinite && $0.y.isFinite }
            }
        case .square, .circle:
            guard let rect = shapeRect else { return false }
            return rect.minX.isFinite && rect.minY.isFinite
                && rect.width.isFinite && rect.height.isFinite
                && rect.width > 0 && rect.height > 0
        case .line, .arrow:
            guard let start = lineStart, let end = lineEnd else { return false }
            return start.x.isFinite && start.y.isFinite && end.x.isFinite && end.y.isFinite
                && hypot(end.x - start.x, end.y - start.y) > 0.01
        case .highlight, .underline:
            return false
        }
    }

    /// The page-space box the geometry occupies, for hit testing and the canvas overlay.
    public var geometryBounds: CGRect? {
        switch kind {
        case .ink:
            let points = inkPaths.flatMap { $0 }
            guard let first = points.first else { return nil }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
            return CGRect(x: minX, y: minY, width: max(maxX - minX, 0.01),
                          height: max(maxY - minY, 0.01))
        case .square, .circle:
            return shapeRect
        case .line, .arrow:
            guard let start = lineStart, let end = lineEnd else { return nil }
            return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: max(abs(end.x - start.x), 0.01),
                          height: max(abs(end.y - start.y), 0.01))
        case .highlight, .underline:
            return nil
        }
    }

    /// A copy moved by `dx`/`dy` in page points.
    public func translated(by dx: CGFloat, dy: CGFloat) -> Annotation {
        guard kind.isGeometry else { return self }
        var copy = self
        copy.inkPaths = inkPaths.map { path in
            path.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        }
        if let rect = shapeRect {
            copy.shapeRect = rect.offsetBy(dx: dx, dy: dy)
        }
        if let start = lineStart { copy.lineStart = CGPoint(x: start.x + dx, y: start.y + dy) }
        if let end = lineEnd { copy.lineEnd = CGPoint(x: end.x + dx, y: end.y + dy) }
        return copy
    }

    /// Older sidecars predate `kind`; decode them as highlights while preserving all
    /// explicitly stored kinds in newer sidecars.
    ///
    /// Colour has two shapes in the wild, and the order matters: `color` is this version's
    /// (any RGB value), `colorIndex` is the older build's index into `AppState.highlightPalette`.
    /// An index outside the palette is not decodable — `AnnotationSidecar` classifies such an
    /// entry as one this version cannot interpret and keeps it verbatim instead of guessing.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .highlight
        page = try values.decode(Int.self, forKey: .page)
        if kind.isGeometry {
            let version = try values.decodeIfPresent(Int.self, forKey: .version)
            guard version == Self.geometryVersion else {
                throw DecodingError.dataCorruptedError(
                    forKey: .version,
                    in: values,
                    debugDescription: "geometry annotation schema \(version.map(String.init) ?? "missing") is not supported"
                )
            }
            start = try values.decodeIfPresent(Int.self, forKey: .start) ?? 0
            end = try values.decodeIfPresent(Int.self, forKey: .end) ?? 0
            note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""
            strokeWidth = CGFloat(try values.decode(Double.self, forKey: .strokeWidth))
            let storedPaths = try values.decodeIfPresent([[StoredPoint]].self, forKey: .paths) ?? []
            inkPaths = storedPaths.map { path in
                path.map { CGPoint(x: $0.x, y: $0.y) }
            }
            if let rect = try values.decodeIfPresent(StoredRect.self, forKey: .rect) {
                shapeRect = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
            }
            if let point = try values.decodeIfPresent(StoredPoint.self, forKey: .lineStart) {
                lineStart = CGPoint(x: point.x, y: point.y)
            }
            if let point = try values.decodeIfPresent(StoredPoint.self, forKey: .lineEnd) {
                lineEnd = CGPoint(x: point.x, y: point.y)
            }
        } else {
            start = try values.decode(Int.self, forKey: .start)
            end = try values.decode(Int.self, forKey: .end)
            note = try values.decode(String.self, forKey: .note)
        }
        if let stored = try values.decodeIfPresent(AnnotationColor.self, forKey: .color) {
            color = stored
        } else {
            let index = try values.decode(Int.self, forKey: .colorIndex)
            guard AppState.highlightPalette.indices.contains(index) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .colorIndex,
                    in: values,
                    debugDescription: "colour index \(index) is outside the \(AppState.highlightPalette.count)-colour palette"
                )
            }
            color = AppState.highlightPalette[index].color
        }
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        if kind.isGeometry, !hasValidGeometry {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: values,
                debugDescription: "geometry annotation \(kind.rawValue) has incomplete or non-finite geometry"
            )
        }
    }

    /// Writes a palette colour as `colorIndex` and anything else as `color`.
    ///
    /// The asymmetry is deliberate and is the whole backward-compatibility story (see
    /// `AnnotationSidecar`): a colour that *is* one of the presets is written exactly as the
    /// older build wrote it, with no new key, so an older build both reads and draws it. Only a
    /// colour the old model cannot express needs the new key — and for that one the older build
    /// preserves the entry verbatim instead of misreading it.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(kind, forKey: .kind)
        try values.encode(page, forKey: .page)
        if kind.isGeometry {
            try values.encode(Self.geometryVersion, forKey: .version)
            try values.encode(strokeWidth, forKey: .strokeWidth)
            switch kind {
            case .ink:
                try values.encode(inkPaths.map { path in
                    path.map { StoredPoint(x: Double($0.x), y: Double($0.y)) }
                }, forKey: .paths)
            case .square, .circle:
                if let rect = shapeRect {
                    try values.encode(StoredRect(x: Double(rect.minX), y: Double(rect.minY),
                                                 width: Double(rect.width), height: Double(rect.height)),
                                      forKey: .rect)
                }
            case .line, .arrow:
                if let start = lineStart {
                    try values.encode(StoredPoint(x: Double(start.x), y: Double(start.y)),
                                      forKey: .lineStart)
                }
                if let end = lineEnd {
                    try values.encode(StoredPoint(x: Double(end.x), y: Double(end.y)),
                                      forKey: .lineEnd)
                }
            case .highlight, .underline:
                break
            }
        } else {
            try values.encode(start, forKey: .start)
            try values.encode(end, forKey: .end)
        }
        if let index = AppState.highlightPalette.firstIndex(where: { $0.color == color }) {
            try values.encode(index, forKey: .colorIndex)
        } else {
            try values.encode(color, forKey: .color)
        }
        try values.encode(note, forKey: .note)
        try values.encode(createdAt, forKey: .createdAt)
    }
}

/// A selection: a page and an inclusive character range in its text layer.
    public struct Selection: Equatable, Sendable {
        public let page: Int
        public let range: ClosedRange<Int>
    }

    @Published public private(set) var selection: Selection?

    /// What a floating preview is *for*. It decides what the panel's body shows, because the
    /// three cases genuinely want three different things.
    public enum ReferencePreviewKind: Equatable, Sendable {
        /// A bibliography entry a citation resolved to: the panel shows the entry **as text**.
        /// The reader wants to read the reference, and a crop of a two-column bibliography page
        /// makes that harder, not easier.
        case reference
        /// A figure or table caption: the panel shows the rendered region. A picture of a figure
        /// is the point.
        case figure
        /// A plain link destination — a page, or a `/FitR` region with no entry behind it: the
        /// panel shows the page image, which is the only thing there is to show.
        case page
    }

    /// The citation/figure preview (M4): what the floating panel is showing, if anything.
    ///
    /// Following an internal link opens this instead of jumping, so the reader keeps their
    /// place; the panel offers the jump explicitly.
    public struct ReferencePreview: Equatable, Sendable {
        public let page: Int
        public let title: String
        /// Where the link was found, shown in the panel for context.
        public let source: String
        /// What the preview is for; decides between the entry text and the page image.
        public let kind: ReferencePreviewKind
        /// The clicked rectangle — the citation, the `Figure 3` mention, the link box — in the
        /// canvas's view space (top-left origin). It is what the floating panel opens next to:
        /// the target of a citation is usually on a bibliography page the reader is nowhere
        /// near, while the thing they clicked is by definition under the pointer.
        public let anchor: CGRect?
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
                                 kind: preview.kind, anchor: preview.anchor,
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
                             kind: preview.kind, anchor: preview.anchor,
                             region: entry.region, entries: preview.entries)
    }

    public func showFullPreviewPage() {
        guard let preview = referencePreview else { return }
        // The page image is exactly what "Full page" is for, so the kind changes with the view.
        openReferencePreview(page: preview.page, title: preview.title, from: preview.source,
                             kind: .page, anchor: preview.anchor, entries: preview.entries)
    }

    /// Opens a floating preview of `page`.
    ///
    /// `entries` is the citation's whole group of resolved works; `page`, `title` and `region`
    /// describe the **first** of them, which is what a `.page` or `.figure` preview's image
    /// shows. `kind` decides which of the two bodies the panel builds, and `anchor` — the
    /// rectangle the reader clicked, in canvas view space — is where it opens.
    ///
    /// A `.reference` preview never rasterizes anything: the entry text *is* the body, so the
    /// panel opens immediately and no page, tile or prefetch work is started for it.
    public func openReferencePreview(
        page: Int,
        title: String,
        from source: String,
        kind: ReferencePreviewKind,
        anchor: CGRect? = nil,
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
            kind: kind,
            anchor: anchor,
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

        if kind == .reference {
            // Nothing to rasterize: the panel's body is the entry text, which the shell already
            // has. Reporting "loading" here would be a lie and leaving it set would keep the
            // panel's spinner up forever.
            referencePreviewLoading = false
            FileHandle.standardError.write(
                Data("aris-preview: entry text for \"\(title)\" (\(entries.count) entries, \(entries.reduce(0) { $0 + $1.text.count }) characters)\n".utf8)
            )
            return
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

    /// Annotations the **PDF itself carries**, in view space — highlights and notes somebody
    /// else made (or the reader made in another viewer).
    ///
    /// A different thing from `annotations` below: that is what this reader wrote to its sidecar,
    /// this is what the file says. The two are shown together on the canvas and listed separately
    /// in the sidebar, because only one of them can be edited here.
    @Published public private(set) var documentAnnotations: [DocumentAnnotation] = []
    /// True while the document's own annotations are being read (the sidebar shows it).
    @Published public private(set) var documentAnnotationsLoading = false
    /// Why the document's annotations could not be read, if they could not.
    @Published public private(set) var documentAnnotationsError: String?
    private var documentAnnotationsLoadCompleted = false

    /// The note the reader last clicked on the page, highlighted in the sidebar so its text is
    /// where the click put it. `nil` until a note is clicked or a document is opened.
    @Published public private(set) var selectedDocumentAnnotationID: String?

    /// The note currently expanded beside its glyph in the document.
    @Published public private(set) var openDocumentNoteID: String?

    public var openDocumentNote: DocumentAnnotation? {
        documentAnnotations.first { $0.visible && $0.id == openDocumentNoteID }
    }

    public func closeDocumentNote() { openDocumentNoteID = nil }

    public var inlineNoteMarkers: [InlineNoteMarker] {
        InlineNoteMarker.layout(annotations: documentAnnotations, textPages: textPages)
    }

    /// The paper belongs to the clicked label for inline notes, or the PDF's own note box.
    public func documentNoteAnchor(_ note: DocumentAnnotation) -> CGRect? {
        if let marker = inlineNoteMarkers.first(where: { $0.id == note.id }) {
            return anchorViewRect(page: note.page, region: marker.rect)
        }
        guard let box = note.boxes.first else { return nil }
        return anchorViewRect(page: note.page, region: CGRect(
            x: box.xPt, y: box.yPt, width: box.widthPt, height: box.heightPt))
    }

    /// The document's own annotations that are notes rather than markup — what the sidebar lists.
    ///
    /// Sticky notes and free text expose their `/Contents` in the sidebar and in a paper
    /// beside the glyph when clicked on the page.
    public var documentNotes: [DocumentAnnotation] {
        documentAnnotations.filter { $0.visible && $0.isNote }
    }

    /// Highlights the reader added, and the file they are stored in.
    ///
    /// This is the array this version can *render and edit*. Entries a newer version wrote in
    /// a shape this one does not understand are not in here: they live in
    /// `annotationSidecarSlots` as raw JSON and are written back untouched (see
    /// `AnnotationSidecar`).
    @Published public private(set) var annotations: [Annotation] = []
    /// The tool the canvas is in. Text markup is still selection-based; the tools here are the
    /// ones that change what a pointer drag on the page means.
    @Published public var annotationTool: AnnotationTool = .select
    /// The colour a newly created mark is stored in.
    ///
    /// The highlight palette's presets are translucent because a highlight sits over text. Pen
    /// and shape marks use the same hue at full opacity: a stroke is the reader's ink, not a
    /// wash over the page.
    @Published public var annotationColor: AnnotationColor = AppState.annotationPalette[0].color
    /// The geometry annotation the reader last clicked, if any. Only sidecar annotations can be
    /// selected: a PDF's own ink and shapes are drawn but not editable, because moving them
    /// would mean rewriting somebody else's annotation.
    @Published public private(set) var selectedAnnotationID: UUID?
    /// The mark being dragged, and where the drag started in its page's space.
    private var moveOriginalAnnotation: Annotation?
    private var moveStartPagePoint: CGPoint?
    /// The reader's bookmarks for this document, in the order the sidebar shows them.
    ///
    /// Stored in the same sidecar as `annotations` (see `Bookmark` and `AnnotationSidecar`);
    /// entries a newer build wrote in a shape this one cannot interpret stay in the slot list
    /// and are written back verbatim, exactly as foreign annotation entries are.
    @Published public private(set) var bookmarks: [Bookmark] = []
    /// Number of sidecar entries preserved verbatim because this version cannot interpret
    /// them (unknown `kind`, colour outside the palette, unknown fields).
    @Published public private(set) var preservedAnnotationEntryCount = 0
    /// How many times this document's sidecar has been written since the document opened.
    /// Instrumentation: it is what makes write coalescing measurable instead of asserted.
    @Published public private(set) var annotationWriteCount = 0
    /// True while a PDF write-back is running, so the save commands cannot run twice at once.
    @Published public private(set) var annotationSaveInProgress = false
    /// A note from the last open that a previous save of this document was interrupted.
    ///
    /// The document itself is intact (a save only takes effect at the final rename); this is
    /// how the shell tells the reader rather than staying silent about a leftover temp file.
    @Published public private(set) var interruptedAnnotationSaveNotice: String?
    /// What the last successful write-back did, for the status line, diagnostics and checks.
    @Published public private(set) var lastAnnotationWriteReport: AnnotationWriteReport?
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
    /// Highlight colours offered when **creating** an annotation (translucent, so the text under
    /// a highlight stays readable).
    ///
    /// The first four entries are the palette this application has always had, in the same order
    /// and with the same bytes: a sidecar written by an older build stores `colorIndex` 0…3, and
    /// those indices must keep meaning exactly what they meant. The rest were added because four
    /// colours is not a palette a reader can work in; a loaded annotation is not limited to these
    /// at all (see `AnnotationColor`).
    /// `nonisolated` because `Codable` conformances are not main-actor isolated: an annotation
    /// decodes its legacy `colorIndex` against this table from any thread. It is a `let` of
    /// `Sendable` values, so sharing it is safe.
    /// Lyra presets for new annotations. The legacy indexed palette below remains stable so
    /// old sidecars retain their original colors when decoded or re-saved.
    public nonisolated static let annotationPalette: [(name: String, color: AnnotationColor)] = [
        ("Gold", AnnotationColor(red: 0xE8, green: 0xBC, blue: 0x55, alpha: 82)),
        ("Apricot", AnnotationColor(red: 0xEF, green: 0xA7, blue: 0x7D, alpha: 77)),
        ("Sage", AnnotationColor(red: 0x90, green: 0xB7, blue: 0x9A, alpha: 71)),
        ("Mist Blue", AnnotationColor(red: 0x7D, green: 0xAD, blue: 0xD6, alpha: 66)),
        ("Lavender", AnnotationColor(red: 0xAB, green: 0x9A, blue: 0xCB, alpha: 71)),
        ("Rose", AnnotationColor(red: 0xD9, green: 0x9A, blue: 0x9B, alpha: 71)),
    ]

    public nonisolated static let highlightPalette: [(name: String, color: AnnotationColor)] = [
        ("Yellow", AnnotationColor(red: 0xFF, green: 0xD8, blue: 0x40, alpha: 0x66)),
        ("Green", AnnotationColor(red: 0x70, green: 0xD0, blue: 0x60, alpha: 0x66)),
        ("Blue", AnnotationColor(red: 0x60, green: 0xA0, blue: 0xF0, alpha: 0x66)),
        ("Pink", AnnotationColor(red: 0xE0, green: 0x70, blue: 0xB0, alpha: 0x66)),
        ("Orange", AnnotationColor(red: 0xFF, green: 0xA0, blue: 0x40, alpha: 0x66)),
        ("Purple", AnnotationColor(red: 0xA0, green: 0x80, blue: 0xF0, alpha: 0x66)),
        ("Teal", AnnotationColor(red: 0x40, green: 0xC0, blue: 0xC0, alpha: 0x66)),
        ("Grey", AnnotationColor(red: 0x90, green: 0x98, blue: 0xA0, alpha: 0x66)),
    ]

    /// Textures for this document's annotations, keyed by the colour they are drawn in.
    ///
    /// One 1x1 texture per distinct colour rather than one per palette entry: a loaded PDF can
    /// carry any colour, and a multiply draw needs its opacity baked into the texture (see
    /// `AnnotationColor.baked(opacity:)`), so the key has to include the blend.
    private var annotationTextures: [AnnotationTextureKey: PageImage] = [:]
    private var nextAnnotationTextureGeneration: UInt64 = 1_000

    /// Textures for the notes this document carries: one sticky-note icon or free-text raster per
    /// annotation, at the scale the canvas is currently drawing it at. Cleared with the rest of
    /// the annotation textures when the document changes.
    private var noteGlyphTextures: [NoteGlyphKey: PageImage] = [:]

    /// Whether to print the annotations handed to the canvas (`ARIS_READER_CANVAS_DUMP=1`).
    ///
    /// The canvas prints its own half of the same frame under that variable (`MetalCanvasView`),
    /// keyed by the same placement index, so "what we asked for" and "what was composited" can be
    /// read side by side. It exists because a wrong picture can come from either half, and the
    /// raster-level tests in the Rust crates can see neither.
    private let annotationDumpEnabled =
        ProcessInfo.processInfo.environment["ARIS_READER_CANVAS_DUMP"] == "1"

    private func annotationDump(_ message: String) {
        FileHandle.standardError.write(Data("aris-annot: \(message)\n".utf8))
    }

    /// `#RRGGBBAA` of a `PageImage`'s BGRA bytes.
    private static func hex(_ bgra: Data) -> String {
        guard bgra.count >= 4 else { return "?" }
        return String(format: "#%02X%02X%02X%02X", bgra[2], bgra[1], bgra[0], bgra[3])
    }

    private static func round(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    /// A 1x1 texture in `color`, uploaded straight or with `opacity` baked in for multiply.
    ///
    /// The colour already carries the annotation's opacity in its alpha channel (the engine sets
    /// it from `/CA`), which is exactly what alpha-over needs. Multiply is the case that needs the
    /// opacity folded into the channels instead: the GPU mixes in linear light where PDF mixes in
    /// the stored colour space, so an unbaked translucent highlight comes out visibly brighter
    /// than the file says (see `AnnotationColor.baked(opacity:)`).
    private func annotationTexture(for color: AnnotationColor, opacity: Double, blend: QuadBlend) -> PageImage {
        let drawn = blend == .multiply ? color.baked(opacity: opacity) : color
        let key = AnnotationTextureKey(color: drawn, blend: blend)
        if let cached = annotationTextures[key] { return cached }
        nextAnnotationTextureGeneration += 1
        let image = PageImage(
            pixelWidth: 1,
            pixelHeight: 1,
            pointSize: .zero,
            bgra: Data(key.color.bgra),
            generation: nextAnnotationTextureGeneration
        )
        annotationTextures[key] = image
        return image
    }

    /// Identity of a tint texture: the exact bytes drawn, so two annotations that differ only in
    /// opacity do not share one.
    private struct AnnotationTextureKey: Hashable {
        let color: AnnotationColor
        let blend: QuadBlend
    }

    /// Citations per page and the document's reference list.
    private var citationsByPage: [Int: [Citation]] = [:]
    /// The fetch of one page's citations, kept so a click made while it is still running can wait
    /// for it instead of paying for a second read of the page (see `startCitationLoad`).
    private var citationLoads: [Int: Task<[Citation]?, Never>] = [:]
    @Published public private(set) var references: [Reference] = []
    private var referencesLoadCompleted = false

    /// `Figure 3` / `Table 2` mentions per page, and the document's caption index.
    ///
    /// Mentions are keyed by `(kind, label)`, which is exactly how `figures` is looked up:
    /// the mention says *what* was referenced (and where the pointer has to be), the caption
    /// record says *where it is*. Both are view-state-free, so they live here rather than in
    /// the panel.
    private var captionMentionsByPage: [Int: [CaptionMention]] = [:]
    private var captionMentionsInFlight: Set<Int> = []
    @Published public private(set) var figures: [Figure] = []
    private var figuresLoadCompleted = false
    /// Recognised document metadata, with the source of every field.
    @Published public private(set) var metadata: DocumentMetadata?
    /// The editable values and the BibTeX generated from them. This is the panel's single
    /// source of truth; copying and saving use `metadataBibtex`, not a fresh guess.
    @Published public private(set) var metadataDraft: MetadataDraft = .empty
    @Published public private(set) var metadataBibtex: String = ""
    @Published public private(set) var metadataLoading = false
    @Published public private(set) var metadataError: String?
    private var metadataLoadCompleted = false
    /// Bumped on every document open, so caption data that arrives afterwards is dropped
    /// instead of being attributed to the document now on screen (the `renderEpoch` idea).
    private var documentEpoch: UInt64 = 0

    /// Links per page, fetched once and kept.
    private var linkCache: [Int: [DocumentLink]] = [:]
    private var linksInFlight: Set<Int> = []

    /// One tab. The document itself lives in the tab-retention cache below; a tab whose document
    /// is beyond the keep-limit keeps only its URL and reading position and reloads on selection.
    public struct OpenTab: Identifiable, Sendable {
        public let id = UUID()
        public let url: URL
        public var title: String
        public var scrollYPt: CGFloat
    }

    @Published public private(set) var tabs: [OpenTab] = []
    @Published public private(set) var activeTabIndex: Int?

    // MARK: - Tab document retention (LRU)

    /// How many documents (the active one plus the retained inactive ones) stay fully open.
    ///
    /// Three is the small bound the task asks for: the tab being read, the one before it and one
    /// more. With the default 48 MB tile budget the raster caches this keeps alive are bounded by
    /// three budgets, not by the number of tabs; the fourth document is closed through
    /// `RustEngine.closeDocument(at:)` and its tab reloads when selected again.
    public static let maximumRetainedDocuments = 3

    /// Everything about one document that must survive a tab switch. The active document's
    /// values live in `AppState`; an inactive document's values live in a `RetainedTab`.
    ///
    /// This is a value snapshot, so retaining it does not copy the raster bytes (Swift arrays and
    /// dictionaries are copy-on-write); when the active state is reset for another document the
    /// snapshot keeps its own storage.
    private struct TabDocumentState {
        var document: LoadedDocument
        var currentPage: Int
        var scrollYPt: CGFloat
        var contentHeightPt: CGFloat
        var contentWidthPt: CGFloat
        var statusMessage: String
        var pageSelection: Set<Int>
        var pageSelectionAnchor: Int?
        var pageEditSession: PageEditSession?
        var pageEditPendingOperations: [String]
        var pageEditIsApplied: Bool
        var selection: Selection?
        var selectionAnchor: Int?
        var searchHits: [SearchHit]
        var currentHitIndex: Int?
        var tileCache: TileCache
        var pagePreviews: [Int: PageImage]
        var pagePreviewScales: [Int: CGFloat]
        var desiredPreviewScale: CGFloat
        var failedPreviewPages: Set<Int>
        var failedTiles: Set<TileKey>
        var usesScreenPageRasters: Bool
        var screenPagePathNote: String?
        var screenPagePathSummary: String
        var lastScreenPagePathNote: String?
        var hasReportedScreenPagePath: Bool
        var textPages: [Int: TextPage]
        var canvasPages: [CanvasPage]
        var canvasTiles: [CanvasPage]
        var visiblePagePlacements: [PagePlacement]
        var linkCache: [Int: [DocumentLink]]
        var citationsByPage: [Int: [Citation]]
        var captionMentionsByPage: [Int: [CaptionMention]]
        var references: [Reference]
        var referencesLoadCompleted: Bool
        var figures: [Figure]
        var figuresLoadCompleted: Bool
        var metadata: DocumentMetadata?
        var metadataDraft: MetadataDraft
        var metadataBibtex: String
        var metadataError: String?
        var metadataLoadCompleted: Bool
        var documentAnnotations: [DocumentAnnotation]
        var documentAnnotationsError: String?
        var documentAnnotationsLoadCompleted: Bool
        var outline: [OutlineEntry]
        var outlineLoadCompleted: Bool
        var thumbnails: [Int: PageImage]
        var annotations: [Annotation]
        var bookmarks: [Bookmark]
        var preservedAnnotationEntryCount: Int
        var annotationWriteCount: Int
        var lastAnnotationWriteReport: AnnotationWriteReport?
        var interruptedAnnotationSaveNotice: String?
        var lastSidecarBackupURL: URL?
        var annotationsURL: URL?
        var annotationWritesBlockedReason: String?
        var annotationSidecarSlots: [AnnotationSidecar.Slot]
        var selectedDocumentAnnotationID: String?
        var openDocumentNoteID: String?
        var annotationTextures: [AnnotationTextureKey: PageImage]
        var noteGlyphTextures: [NoteGlyphKey: PageImage]
        var undoStack: [UndoableAction]
        var redoStack: [UndoableAction]
    }

    private struct RetainedTab {
        let tabID: UUID
        let url: URL
        var state: TabDocumentState
        var lastUsed: UInt64
    }

    private var retainedTabs: [UUID: RetainedTab] = [:]
    private var useTick: UInt64 = 0
    /// Diagnostic counter: each entry is one least-recently-used document closed because the
    /// keep-limit was exceeded.
    public private(set) var documentEvictionCount = 0
    public private(set) var lastEvictedDocumentURL: URL?
    /// Documents that are fully open right now: the active one (if any) plus the retained tabs.
    public var retainedDocumentCount: Int { (document == nil ? 0 : 1) + retainedTabs.count }
    /// Retained inactive tabs, for the checks and diagnostics.
    public var retainedTabCount: Int { retainedTabs.count }
    /// True between selecting an evicted tab and the first raster of its reloaded document. The
    /// interface shows a clear placeholder instead of an empty canvas in that window.
    @Published public private(set) var isRestoringDocument = false

    /// Document outline, loaded once per document.
    @Published public private(set) var outline: [OutlineEntry] = []
    private var outlineLoadCompleted = false
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

    /// Whether the `ARIS_READER_OPEN` launch hook has already opened its document.
    ///
    /// One process launches once. With a window per session there is an `AppState` per window, and
    /// the hook must stay what it says: the document *this launch* was given.
    private static var launchDocumentConsumed = false

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

        if Self.usesStoredReadingLayoutPreferences {
            layoutMode = ReadingLayoutPreferences.layoutMode()
            pageGapPt = ReadingLayoutPreferences.gapPt()
            // One preference change must reach every open window, not just the one that moved
            // the slider. Each state reads the stored value and preserves its own reading
            // position through the layout change.
            layoutPreferencesObserver = NotificationCenter.default.addObserver(
                forName: ReadingLayoutPreferences.didChange, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.adoptStoredReadingLayoutPreferences() }
            }
        }

        // Developer/test affordance: open a document at launch
        // (`ARIS_READER_OPEN=/path/to.pdf ArisReader`), which also lets a headless run
        // exercise the whole Swift → UniFFI → PDFium path.
        //
        // **Once per process.** The hook means "the document this launch was given", and a launch
        // makes exactly one window; since each window now builds its own `AppState`
        // (`ReaderSession`), consuming it per state would re-open the same file in every window
        // the reader opens afterwards. The first state in the process — the first window's — is
        // the one the hook belongs to.
        if !AppState.launchDocumentConsumed,
           let path = ProcessInfo.processInfo.environment["ARIS_READER_OPEN"], !path.isEmpty {
            AppState.launchDocumentConsumed = true
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
                    kind: region == nil ? .page : .figure,
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
    /// harness or the OS uses to stop the app. Called by each window when it appears — the check
    /// harness deliberately does not install it — and safe to call once per window.
    ///
    /// **Signals are installed once per process, and flush every window.** The signal path ends the
    /// process itself (`exit`, below), so with one signal source per window only the first window's
    /// writes would land and the rest would be lost with the process — a real regression now that
    /// each window owns its own state: an unsaved highlight or reading position in the second
    /// window would vanish on a SIGTERM from a harness. The normal quit path needs no such
    /// treatment: `willTerminateNotification` reaches every observer, so each state flushes its
    /// own pending writes and they cannot race with each other.
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

        AppState.liveStates.removeAll { $0.value == nil }
        AppState.liveStates.append(WeakState(self))
        AppState.installSignalFlushOnce()
    }

    /// Kept so the observers can be removed if the state ever outlives the notification centre.
    private var terminationObserver: NSObjectProtocol?

    /// A state that installed termination handling, held weakly: a closed window's state must not
    /// be kept alive by the flush list, and must not be flushed after it is gone.
    private final class WeakState {
        weak var value: AppState?
        init(_ value: AppState) { self.value = value }
    }

    /// Every state that installed termination handling, so one signal can flush them all.
    private static var liveStates: [WeakState] = []
    /// Kept alive for the life of the process: a resumed source that is released stops delivering.
    private static var terminationSignalSources: [DispatchSourceSignal] = []

    /// SIGTERM/SIGINT (what a harness or the OS sends). Flush every window and leave directly
    /// rather than asking AppKit to terminate: a *modal alert* holds `terminate` back
    /// indefinitely, and a process that ignores SIGTERM is worse than one that exits without
    /// animation.
    private static func installSignalFlushOnce() {
        guard terminationSignalSources.isEmpty else { return }
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    for state in AppState.liveStates { state.value?.flushPendingWrites() }
                }
                exit(128 + number) // the conventional "terminated by signal N" status
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    public var windowTitle: String {
        document?.title ?? "Lyra"
    }

    public var pageLabel: String {
        guard let document, document.pageCount > 0 else { return "— / —" }
        return "\(currentPage) / \(document.pageCount)"
    }

    /// How many open requests this state has served, whether they succeeded or not.
    ///
    /// One counter for the only loading path in the shell. The checks use it to show that the
    /// Dock, Finder, `open -a` and drop entry points all arrive here instead of at some parallel
    /// loader that would skip the rest of `open(url:)`.
    public private(set) var openRequestCount = 0

    @discardableResult
    public func open(url: URL) -> Bool {
        // Keep the document the reader left behind if it belongs to a tab. The snapshot is only
        // committed after the new document actually opens, so a refused open leaves the cache and
        // the screen exactly as they were.
        let previous = prepareActiveDocumentForReplacement()
        // A direct open with no tab (the launch hook, a check) has nobody to bring the old
        // document back; its handle must go, or an untabbed open path would leak one per file.
        let orphanURL = previous == nil && activeTabIndex == nil ? document?.url : nil
        guard loadDocument(url: url, restoringTabScroll: nil) else { return false }
        if var previous {
            // The new open may have discarded a page-edit session on the previous document
            // (after the explicit alert). Its revision is gone, so the retained tab must not
            // bring a dead session back.
            if previous.state.pageEditSession != nil && pageEditSession == nil {
                previous.state.pageEditSession = nil
                previous.state.pageEditPendingOperations = []
                previous.state.pageEditIsApplied = false
            }
            retain(previous)
        } else if let orphanURL, orphanURL != document?.url {
            releaseEngineDocumentIfUnused(orphanURL)
        }
        trimRetainedDocuments()
        return true
    }

    /// The one loading path. `restoringTabScroll` is non-nil only when a tab whose document was
    /// evicted is being reopened: the saved position is applied before the first raster is
    /// requested, so the placeholder never jumps to the top of the file first.
    @discardableResult
    private func loadDocument(url: URL, restoringTabScroll: CGFloat?,
                              preservingPageEditSessionInSnapshot: Bool = false) -> Bool {
        openRequestCount += 1
        if let session = pageEditSession {
            let same = Self.resolvesToSameFile(url, session.originalURL)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = same
                ? "Discard the pending page changes and reopen the original?"
                : "Discard the pending page changes to “\(session.originalURL.lastPathComponent)”?"
            alert.informativeText =
                "The original file is unchanged, but annotations and bookmarks added during the "
                + "page-editing session are discarded with the working copy."
            alert.addButton(withTitle: "Discard and Open")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            endPageEditSession(deleteFiles: true)
        }
        do {
            let loaded = try engine.openDocument(at: url)
            resetDocumentState()
            // A tab switch already put the old document's page-edit session in its retained
            // snapshot. The live copy belongs to the document being replaced and must not leak
            // into the new one; the working files stay alive for the snapshot.
            if preservingPageEditSessionInSnapshot {
                pageEditSession = nil
                pageEditPendingOperations = []
                pageEditIsApplied = false
            }
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
            noticeInterruptedSave(at: url)
            if let restoringTabScroll {
                contentHeightPt = engine.contentHeightPt(gapPt: pageGapPt, layout: layoutMode)
                contentWidthPt = engine.contentWidthPt(gapPt: pageGapPt, layout: layoutMode)
                scrollYPt = min(max(0, restoringTabScroll),
                                max(0, contentHeightPt - viewportHeightContentPt))
                reloadVisiblePages()
            } else {
                reloadVisiblePages()
                restoreReadingPosition(for: url)
            }
            loadOutline()
            loadThumbnails()
            loadReferences()
            loadFigures()
            loadMetadata()
            loadDocumentAnnotations()
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
        // A glide belongs to the document that was scrolling; the next one starts still.
        cancelScrollGlide()
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
        citationLoads = [:]
        captionMentionsByPage = [:]
        captionMentionsInFlight = []
        figures = []
        references = []
        metadata = nil
        metadataDraft = .empty
        metadataBibtex = ""
        metadataLoading = false
        metadataError = nil
        documentAnnotations = []
        documentAnnotationsLoading = false
        documentAnnotationsError = nil
        annotationSaveInProgress = false
        pageEditIsApplied = false
        interruptedAnnotationSaveNotice = nil
        lastAnnotationWriteReport = nil
        annotationTextures = [:]
        outline = []
        outlineLoadCompleted = false
        referencesLoadCompleted = false
        figuresLoadCompleted = false
        metadataLoadCompleted = false
        documentAnnotationsLoadCompleted = false
        isRestoringDocument = false
        thumbnails = [:]
        thumbnailsInFlight = []
        pendingThumbnails = []
        searchHits = []
        currentHitIndex = nil
        isSearching = false
        selection = nil
        selectionAnchor = nil
        selectedAnnotationID = nil
        moveOriginalAnnotation = nil
        moveStartPagePoint = nil
        annotationTool = .select
        annotations = []
        bookmarks = []
        pageSelection = []
        pageSelectionAnchor = nil
        annotationsURL = nil
        annotationWritesBlockedReason = nil
        annotationSidecarSlots = []
        preservedAnnotationEntryCount = 0
        hasPendingAnnotationWrite = false
        noteFlushTask?.cancel()
        noteFlushTask = nil
        undoStack = []
        redoStack = []
        selectedDocumentAnnotationID = nil
        openDocumentNoteID = nil
        noteGlyphTextures = [:]
        scrollYPt = 0
        contentHeightPt = 0
        contentWidthPt = 0
        // The next document starts still, with no pointer or drag left over from the old one:
        // both would otherwise keep the fresh indicator visible for a document nobody touched.
        scrollIdleTask?.cancel()
        scrollIdleTask = nil
        isScrolling = false
        isScrollIndicatorHovered = false
        isDraggingScrollIndicator = false
    }

    public func zoomIn() {
        zoomPercent = min(Self.maximumZoomPercent, zoomPercent + 10)
        reloadVisiblePages()
    }

    public func zoomOut() {
        zoomPercent = max(Self.minimumZoomPercent, zoomPercent - 10)
        reloadVisiblePages()
    }

    /// The zoom range the toolbar buttons and the pointer gestures share.
    public static let minimumZoomPercent = 25
    public static let maximumZoomPercent = 400

    /// How much zoom one screen point of a Ctrl/⌘+scroll asks for, in percent.
    ///
    /// `WheelMotion` reports a discrete wheel notch as 32 points and a precise trackpad delta as
    /// itself, so one notch is 16% and a 100-point two-finger swipe is 50%: both are one visible
    /// step, not a jump. The sign follows the browser convention — the gesture that scrolls the
    /// document forward (Ctrl+wheel *down*, the content moving up) zooms out, and the one that
    /// pulls it back zooms in.
    static let zoomPercentPerScrollPoint: CGFloat = -0.5

    /// Ctrl+scroll (and ⌘+scroll) zoom, anchored so the content point under the pointer stays
    /// under it.
    ///
    /// `delta` is the same screen-point delta `scroll(byScreenPoints:)` takes, and `anchorViewY`
    /// is the pointer in the canvas's view space (top-left origin). The anchor is applied
    /// vertically only: the canvas has no horizontal scroll offset to solve for
    /// (`CanvasGeometry.contentOffsetX`), so a point on the right of a wide page moves with the
    /// centring. Everything else is the ordinary zoom path — the same `zoomPercent` the toolbar
    /// writes, the same `reloadVisiblePages()`, the same debounced position save — so the
    /// sharp-tile and prefetch machinery sees a zoom it already knows how to handle.
    ///
    /// Returns whether the zoom actually moved.
    @discardableResult
    public func zoomByScroll(delta: CGFloat, anchorViewY: CGFloat) -> Bool {
        applyPointerZoom(delta * Self.zoomPercentPerScrollPoint, anchorViewY: anchorViewY)
    }

    /// Trackpad pinch, anchored at the pointer.
    ///
    /// `magnification` is `NSEvent.magnification`, a fraction (0.1 = +10%), which is already
    /// proportional to the gesture, so it needs no per-point scaling. This is also the zoom
    /// gesture the Accessibility "scroll gesture with modifier keys" setting cannot intercept.
    @discardableResult
    public func zoomByPinch(_ magnification: CGFloat, anchorViewY: CGFloat) -> Bool {
        applyPointerZoom(magnification * 100, anchorViewY: anchorViewY)
    }

    /// Fraction of a zoom percent a pointer gesture has asked for but not yet been given: the
    /// zoom itself is an integer percent, and dropping every sub-percent delta would make a slow
    /// trackpad gesture do nothing at all.
    private var pointerZoomRemainder: CGFloat = 0

    @discardableResult
    private func applyPointerZoom(_ percentDelta: CGFloat, anchorViewY: CGFloat) -> Bool {
        guard document != nil, percentDelta.isFinite, percentDelta != 0 else { return false }
        // Reversing direction drops the remainder: a half-percent of zoom-in must not pay for the
        // first half-percent of zoom-out.
        if percentDelta * pointerZoomRemainder < 0 { pointerZoomRemainder = 0 }
        pointerZoomRemainder += percentDelta
        let whole = pointerZoomRemainder.rounded(.towardZero)
        guard whole != 0 else { return false }
        pointerZoomRemainder -= whole

        let target = min(Self.maximumZoomPercent,
                         max(Self.minimumZoomPercent, zoomPercent + Int(whole)))
        guard target != zoomPercent else {
            // At a limit the remainder must not pile up, or the first step back would jump.
            pointerZoomRemainder = 0
            return false
        }

        let oldZoom = zoomFactor
        let previousScrollYPt = scrollYPt
        let anchorContentY = CanvasGeometry.contentY(
            viewY: anchorViewY, scrollYPt: scrollYPt, zoom: oldZoom
        )
        zoomPercent = target
        // The anchored offset replaces the old one outright; a glide still in flight would pull
        // it back toward where the wheel was heading before the zoom.
        cancelScrollGlide()
        // Solve the offset against the new zoom and clamp with the new viewport height, then let
        // the ordinary zoom path rebuild the band for it. Content height is in content points and
        // does not depend on the zoom, so the clamp is already using the right numbers.
        let anchored = CanvasGeometry.scrollYPt(
            keepingContentY: anchorContentY, atViewY: anchorViewY, zoom: zoomFactor
        )
        scrollYPt = clampedScrollOffset(anchored)
        reloadVisiblePages()
        // The anchored zoom is a scroll too: it moves the reading position, so it owes the same
        // debounced save every other scroll owes.
        if abs(scrollYPt - previousScrollYPt) > 0.01 { schedulePositionSave() }
        return true
    }

    /// The scroll offset clamped to the document (shared by every path that sets it).
    private func clampedScrollOffset(_ value: CGFloat) -> CGFloat {
        min(max(0, value), max(0, contentHeightPt - viewportHeightContentPt))
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
        cancelScrollGlide()
        let contentDelta = delta / max(zoomFactor, 0.01)
        if delta != 0 { scrollDirection = delta > 0 ? 1 : -1 }
        let next = clampedScrollOffset(scrollYPt + contentDelta)
        beginScrollActivity()
        guard abs(next - scrollYPt) > 0.01 else { return }
        scrollYPt = next
        reloadVisiblePages()
        schedulePositionSave()
    }

    /// Applies the wheel's accelerated distance immediately. Nothing is queued after the last
    /// event, so a fast spin keeps its full distance and stopping the wheel stops the document.
    public func scrollByWheelStep(_ delta: CGFloat) {
        scroll(byScreenPoints: delta)
    }

    /// Scrolls by a **stepped** delta the reader asked for as a destination rather than a speed:
    /// Page Down, Page Up and the arrows keep a short animation to their full destination.
    public func scrollByKeyboardStep(_ delta: CGFloat) {
        stepScroll(delta, mostAhead: nil)
    }

    private func stepScroll(_ delta: CGFloat, mostAhead lead: CGFloat?) {
        guard document != nil, delta != 0 else { return }
        scrollDirection = delta > 0 ? 1 : -1
        let contentDelta = delta / max(zoomFactor, 0.01)
        // Chaining off the *destination* keeps a burst honest: every notch adds its own distance
        // even when the previous one has not been drawn yet - as far as the lead allows. The
        // document's own end still wins over both. The speed ceiling is a screen speed, so it is
        // converted through the zoom like every other screen-point input, and so is the lead.
        let aimed = clampedScrollOffset((glide.destination ?? scrollYPt) + contentDelta)
        glide.aim(
            at: aimed,
            from: scrollYPt,
            mostAhead: lead.map { $0 / max(zoomFactor, 0.01) },
            maximumSpeed: ScrollGlide.defaultMaximumSpeed / max(zoomFactor, 0.01)
        )
        beginScrollActivity()
        startGlideDriver()
    }

    /// Where a glide in flight is heading, or nil when the offset is not animating. Read-only:
    /// it exists for the HUD and for the scroll measurement, not as a second source of truth.
    public var scrollDestinationYPt: CGFloat? { glide.destination }

    /// The glide in flight, if any.
    private var glide = ScrollGlide()
    private var glideDriver: Task<Void, Never>?
    /// Tick length of the driver: short enough to look continuous at 120 Hz, long enough that the
    /// per-tick band update stays cheap. The glide's arithmetic is time-based, so a late tick
    /// covers more ground instead of slowing the motion down — and because the driver keeps
    /// ticking after the last notch too, it is also what detects that the wheel has stopped and
    /// delivers the rest of the distance (`ScrollGlide.idleWindow`).
    private static let glideTick = Duration.milliseconds(8)

    private func startGlideDriver() {
        guard glideDriver == nil else { return }
        glideDriver = Task { @MainActor [weak self] in
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.glideTick)
                // A cancelled driver wakes up from its sleep immediately; it must not take one
                // last step, or it would land on a destination a newer gesture has replaced.
                guard !Task.isCancelled, let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let finished = self.advanceScrollGlide(elapsed: now - previous)
                previous = now
                if finished { break }
            }
            self?.glideDriver = nil
        }
    }

    /// One glide tick; returns whether the glide is over. Visible to the checks so they can drive
    /// the exact code the driver runs, without depending on how fast the machine is.
    @discardableResult
    package func advanceScrollGlide(elapsed: TimeInterval) -> Bool {
        let (offset, finished) = glide.step(from: scrollYPt, elapsed: elapsed)
        if abs(offset - scrollYPt) > 0.0001 {
            scrollYPt = offset
            reloadVisiblePages()
            schedulePositionSave()
        }
        if finished { glide.cancel() }
        return finished
    }

    /// Drops a glide in flight (continuous input arriving, a document change, a page jump).
    private func cancelScrollGlide() {
        glide.cancel()
        glideDriver?.cancel()
        glideDriver = nil
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
        color: AnnotationColor = AppState.annotationPalette[0].color,
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
            color: color,
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
    public func addHighlightFromSelection(
        color: AnnotationColor = AppState.annotationPalette[0].color
    ) -> Bool {
        addAnnotationFromSelection(kind: .highlight, color: color)
    }

    /// Attaches a note to the current selection.
    ///
    /// A note in this reader is a highlight that carries text (the same `Annotation.note` the
    /// sidebar edits), so this is not a second annotation model: it is
    /// ``addAnnotationFromSelection(kind:color:note:)`` with the note the reader typed. The text
    /// range stays visible on the page, and the note is edited where every other note is.
    @discardableResult
    public func addNoteFromSelection(note: String) -> Bool {
        addAnnotationFromSelection(kind: .highlight, note: note)
    }

    // MARK: - Ink and shapes (T3.4)

    /// The opaque colour a pen or shape is drawn in: the current annotation colour's hue at full
    /// opacity.
    public var annotationStrokeColor: AnnotationColor {
        AnnotationColor(red: annotationColor.red, green: annotationColor.green,
                        blue: annotationColor.blue, alpha: 255)
    }

    /// The width every newly drawn stroke uses, in points. A constant width is what makes a
    /// freehand line look like one stroke rather than a pressure-sensitive brush this reader
    /// does not model; `strokeWidth` is stored per annotation so a future width control can
    /// change it without changing the schema.
    public static let defaultAnnotationStrokeWidth: CGFloat = 2

    /// Adds a geometry mark whose coordinates are already **page space** (page-local, top-left,
    /// 100% points). This is the one creation entry point the canvas uses; all validation and
    /// persistence happens here.
    @discardableResult
    public func addGeometryAnnotation(
        kind: Annotation.Kind,
        page: Int,
        inkPaths: [[CGPoint]] = [],
        shapeRect: CGRect? = nil,
        lineStart: CGPoint? = nil,
        lineEnd: CGPoint? = nil,
        color: AnnotationColor? = nil,
        strokeWidth: CGFloat = AppState.defaultAnnotationStrokeWidth
    ) -> Bool {
        guard kind.isGeometry, let document, page >= 0, page < document.pageCount,
              let url = document.url else { return false }
        if annotationsURL == nil { loadAnnotations(for: url) }

        var normalizedPaths = inkPaths
        var normalizedRect = shapeRect
        switch kind {
        case .ink:
            normalizedPaths = normalizedPaths.filter { !$0.isEmpty }
            guard normalizedPaths.contains(where: { $0.count >= 2 }) else { return false }
        case .square, .circle:
            guard var rect = shapeRect else { return false }
            rect = rect.standardized
            guard rect.width >= 1, rect.height >= 1 else { return false }
            normalizedRect = rect
        case .line, .arrow:
            guard let start = lineStart, let end = lineEnd,
                  hypot(end.x - start.x, end.y - start.y) >= 1 else { return false }
        case .highlight, .underline:
            return false
        }

        let annotation = Annotation(
            id: UUID(),
            kind: kind,
            page: page,
            start: 0,
            end: 0,
            color: color ?? annotationStrokeColor,
            note: "",
            createdAt: Date(),
            inkPaths: normalizedPaths,
            shapeRect: normalizedRect,
            lineStart: lineStart,
            lineEnd: lineEnd,
            strokeWidth: strokeWidth
        )
        guard annotation.hasValidGeometry else { return false }

        var updated = annotations
        updated.append(annotation)
        guard saveAnnotations(updated, trigger: "add-\(kind.rawValue)") else { return false }
        undoStack.append(.added(annotation))
        redoStack.removeAll()
        selectedAnnotationID = annotation.id
        refreshSelectionOverlay()
        statusMessage = "Added \(kind.rawValue) annotation"
        return true
    }

    /// A pen stroke from page-space points.
    @discardableResult
    public func addInkAnnotation(
        page: Int,
        points: [CGPoint],
        color: AnnotationColor? = nil,
        strokeWidth: CGFloat = AppState.defaultAnnotationStrokeWidth
    ) -> Bool {
        addGeometryAnnotation(kind: .ink, page: page, inkPaths: [points], color: color,
                              strokeWidth: strokeWidth)
    }

    /// A shape dragged from `start` to `end` in page space. Line and arrow keep the drag
    /// direction; rectangle and ellipse use the normalized box the two corners describe.
    @discardableResult
    public func addShapeAnnotation(
        kind: Annotation.Kind,
        page: Int,
        start: CGPoint,
        end: CGPoint,
        color: AnnotationColor? = nil,
        strokeWidth: CGFloat = AppState.defaultAnnotationStrokeWidth
    ) -> Bool {
        switch kind {
        case .square, .circle:
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                              width: abs(end.x - start.x), height: abs(end.y - start.y))
            return addGeometryAnnotation(kind: kind, page: page, shapeRect: rect, color: color,
                                         strokeWidth: strokeWidth)
        case .line, .arrow:
            return addGeometryAnnotation(kind: kind, page: page, lineStart: start, lineEnd: end,
                                         color: color, strokeWidth: strokeWidth)
        case .ink:
            return addInkAnnotation(page: page, points: [start, end], color: color,
                                    strokeWidth: strokeWidth)
        case .highlight, .underline:
            return false
        }
    }

    /// The page under a **content point** and the point in that page's own space (top-left,
    /// 100% points).
    ///
    /// The canvas converts a view point to content points once, at the event boundary, the same
    /// way text selection does; this subtraction is therefore zoom-independent by construction.
    public func pagePoint(atContentPoint point: CGPoint) -> (page: Int, point: CGPoint)? {
        for placement in visiblePagePlacements {
            let rect = CGRect(x: placement.leftPt, y: placement.topPt,
                              width: placement.widthPt, height: placement.heightPt)
            guard rect.contains(point) else { continue }
            return (placement.index, CGPoint(x: point.x - placement.leftPt,
                                             y: point.y - placement.topPt))
        }
        return nil
    }

    /// Every geometry mark the overlay should draw, in sidecar order followed by the file's own.
    public var canvasAnnotationMarks: [CanvasAnnotationMark] {
        var marks: [CanvasAnnotationMark] = annotations.compactMap { annotation in
            guard annotation.kind.isGeometry else { return nil }
            return CanvasAnnotationMark(
                id: annotation.id.uuidString,
                page: annotation.page,
                kind: annotation.kind,
                inkPaths: annotation.inkPaths,
                shapeRect: annotation.shapeRect,
                lineStart: annotation.lineStart,
                lineEnd: annotation.lineEnd,
                color: annotation.color,
                strokeWidth: annotation.strokeWidth,
                isSelected: annotation.id == selectedAnnotationID,
                isEditable: true
            )
        }
        for annotation in documentAnnotations where annotation.visible && annotation.isGeometry {
            guard let kind = Annotation.Kind(rawValue: annotation.kind) else { continue }
            let opacity = annotation.opacity ?? 1.0
            let alpha = UInt8(min(max((opacity * 255.0).rounded(), 0), 255))
            let color = annotation.color ?? AnnotationColor(red: 0x80, green: 0x80,
                                                           blue: 0x80, alpha: alpha)
            let width = annotation.borderWidthPt ?? 1
            // A PDF shape's `/Rect` is the *outer* edge of its stroke. The canvas draws the
            // path down the centre line, so the box it draws is inset by half the border.
            let shapeRect: CGRect? = if kind == .square || kind == .circle {
                CGRect(x: annotation.xPt, y: annotation.yPt,
                       width: annotation.widthPt, height: annotation.heightPt)
                    .insetBy(dx: width / 2, dy: width / 2)
            } else {
                nil
            }
            marks.append(CanvasAnnotationMark(
                id: "pdf:" + annotation.id,
                page: annotation.page,
                kind: kind,
                inkPaths: annotation.inkPaths,
                shapeRect: shapeRect,
                lineStart: annotation.lineStart,
                lineEnd: annotation.lineEnd,
                color: color,
                strokeWidth: width,
                isSelected: false,
                isEditable: false
            ))
        }
        return marks
    }

    /// The page frames the canvas needs to map page-local marks into the view.
    public var canvasPageFrames: [PagePlacement] { visiblePagePlacements }

    /// The sidecar annotation whose stroke is within `tolerance` points of `point` (page space).
    public func hitTestGeometryAnnotation(page: Int, point: CGPoint,
                                          tolerance: CGFloat) -> UUID? {
        for annotation in annotations.reversed() where annotation.kind.isGeometry {
            guard annotation.page == page else { continue }
            let mark = CanvasAnnotationMark(
                id: annotation.id.uuidString, page: page, kind: annotation.kind,
                inkPaths: annotation.inkPaths, shapeRect: annotation.shapeRect,
                lineStart: annotation.lineStart, lineEnd: annotation.lineEnd,
                color: annotation.color, strokeWidth: annotation.strokeWidth,
                isSelected: false, isEditable: true)
            if AnnotationGeometry.hitTest(mark, at: point, tolerance: tolerance) {
                return annotation.id
            }
        }
        return nil
    }

    /// The sidecar annotation under a content point, with the point in its page space.
    ///
    /// `toleranceViewPt` is converted to page points with the current zoom: a 4 pt allowance on
    /// screen is 4/zoom points on the page, so a hairline stays easy to hit at 300% without
    /// becoming a click magnet at 25%.
    public func geometryAnnotationHit(
        atContentPoint point: CGPoint,
        toleranceViewPt: CGFloat = AnnotationGeometry.hitTolerancePt
    ) -> (id: UUID, page: Int, point: CGPoint)? {
        guard let hit = pagePoint(atContentPoint: point) else { return nil }
        let tolerance = toleranceViewPt / max(zoomFactor, 0.01)
        guard let id = hitTestGeometryAnnotation(page: hit.page, point: hit.point,
                                                tolerance: tolerance) else { return nil }
        return (id, hit.page, hit.point)
    }

    public func selectAnnotation(_ id: UUID?) {
        guard selectedAnnotationID != id else { return }
        selectedAnnotationID = id
        refreshSelectionOverlay()
    }

    /// Deletes the selected geometry annotation. Returns whether anything was deleted.
    @discardableResult
    public func deleteSelectedAnnotation() -> Bool {
        guard let id = selectedAnnotationID else { return false }
        selectedAnnotationID = nil
        removeAnnotation(id)
        return true
    }

    /// Moves a geometry annotation by a page-space delta and persists it as one undo step.
    @discardableResult
    public func moveAnnotation(_ id: UUID, by delta: CGPoint) -> Bool {
        guard delta.x != 0 || delta.y != 0,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return false }
        let before = annotations[index]
        guard before.kind.isGeometry else { return false }
        let after = before.translated(by: delta.x, dy: delta.y)
        guard after.hasValidGeometry else { return false }
        var updated = annotations
        updated[index] = after
        guard saveAnnotations(updated, trigger: "move-\(after.kind.rawValue)") else { return false }
        undoStack.append(.replaced(before: before, after: after))
        redoStack.removeAll()
        selectedAnnotationID = id
        refreshSelectionOverlay()
        statusMessage = "Moved \(after.kind.rawValue) annotation"
        return true
    }

    public func removeAnnotation(_ id: UUID) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        if selectedAnnotationID == id { selectedAnnotationID = nil }
        let removed = annotations[index]
        var updated = annotations
        updated.remove(at: index)
        guard saveAnnotations(updated, trigger: "remove") else { return }
        undoStack.append(.removed(removed))
        redoStack.removeAll()
        reloadVisiblePages()
        statusMessage = "Deleted annotation"
    }

    // MARK: - Bookmarks (T2.13)

    /// Adds a bookmark at the viewport top of the current page and persists it.
    ///
    /// The stored position is page-local (`yPt`), so the bookmark survives a zoom change, a
    /// window resize and a continuous↔facing switch without drifting inside the page.
    @discardableResult
    public func addBookmarkAtCurrentPage(name: String? = nil) -> Bool {
        guard let document, document.pageCount > 0, let url = document.url else { return false }
        if annotationsURL == nil { loadAnnotations(for: url) }
        if annotationWritesBlockedReason != nil {
            statusMessage = "Could not add the bookmark because the sidecar could not be loaded"
            lastError = statusMessage
            return false
        }

        let page = min(max(currentPage - 1, 0), document.pageCount - 1)
        let top = engine.pageTopPt(page, gapPt: pageGapPt, layout: layoutMode)
        let yPt = max(0, scrollYPt - top)
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = trimmed.isEmpty ? "Page \(page + 1)" : trimmed

        let bookmark = Bookmark(page: page, title: title, yPt: yPt)
        var updated = bookmarks
        updated.append(bookmark)
        var slots = annotationSidecarSlots
        slots.append(.bookmark(bookmark.id))
        guard writeSidecar(
            annotations: annotations,
            bookmarks: updated,
            slots: slots,
            trigger: "bookmark-add"
        ) else { return false }

        statusMessage = "Added bookmark “\(title)”"
        return true
    }

    /// Deletes a bookmark. Its slot is left in the file; the encoder skips an id that is no
    /// longer present, so a later save cannot accidentally revive it.
    public func removeBookmark(_ id: UUID) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        let title = bookmarks[index].title
        var updated = bookmarks
        updated.remove(at: index)
        guard writeSidecar(
            annotations: annotations,
            bookmarks: updated,
            slots: annotationSidecarSlots,
            trigger: "bookmark-remove"
        ) else { return }
        statusMessage = "Deleted bookmark “\(title)”"
    }

    /// Renames a bookmark. An empty title is allowed; the sidebar falls back to "Page N" when
    /// displaying it, and nothing is silently rewritten.
    public func renameBookmark(_ id: UUID, to title: String) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }),
              bookmarks[index].title != title else { return }
        var updated = bookmarks
        updated[index].title = title
        guard writeSidecar(
            annotations: annotations,
            bookmarks: updated,
            slots: annotationSidecarSlots,
            trigger: "bookmark-rename"
        ) else { return }
    }

    /// Moves a bookmark by `offset` places in the reader's order. The order is the array's,
    /// and it is persisted by reordering the bookmark slots in the sidecar in place, so
    /// foreign entries keep their positions.
    public func moveBookmark(_ id: UUID, by offset: Int) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }), offset != 0 else { return }
        let target = min(max(index + offset, 0), bookmarks.count - 1)
        guard target != index else { return }

        var updated = bookmarks
        let bookmark = updated.remove(at: index)
        updated.insert(bookmark, at: target)
        guard writeSidecar(
            annotations: annotations,
            bookmarks: updated,
            slots: bookmarkSlots(matching: updated),
            trigger: "bookmark-move"
        ) else { return }
        statusMessage = "Moved bookmark “\(bookmark.title)”"
    }

    /// Jumps so the bookmarked page position is at the top of the viewport.
    public func jump(to bookmark: Bookmark) {
        guard let document, bookmark.page >= 0, bookmark.page < document.pageCount else { return }
        cancelScrollGlide()
        let top = engine.pageTopPt(bookmark.page, gapPt: pageGapPt, layout: layoutMode)
        scrollYPt = clampedScrollOffset(top + bookmark.yPt)
        reloadVisiblePages()
        schedulePositionSave()
        statusMessage = "Jumped to “\(bookmark.title)”"
    }

    /// The display name for a bookmark with an empty custom title.
    public static func defaultBookmarkTitle(page: Int) -> String {
        "Page \(page + 1)"
    }

    /// The current bookmark list split into one section per page, in the reader's order.
    ///
    /// Grouping by page is what makes a list of named places readable; the order *within* and
    /// *between* sections is still the reader's (first appearance wins), which is what the
    /// move commands manipulate.
    public var bookmarkGroups: [BookmarkGroup] {
        BookmarkGrouping.groups(for: bookmarks)
    }

    /// Rebuilds the `.bookmark` slots in the current order while leaving every other slot in
    /// place. Appending covers bookmarks added after the file was loaded.
    private func bookmarkSlots(matching ordered: [Bookmark]) -> [AnnotationSidecar.Slot] {
        var remaining = ordered.makeIterator()
        var slots: [AnnotationSidecar.Slot] = []
        for slot in annotationSidecarSlots {
            if case .bookmark = slot {
                if let next = remaining.next() {
                    slots.append(.bookmark(next.id))
                }
            } else {
                slots.append(slot)
            }
        }
        while let next = remaining.next() {
            slots.append(.bookmark(next.id))
        }
        return slots
    }

    // MARK: - Undo / redo

    /// One reversible change. Note edits are represented as old/new values so an edit can
    /// be undone and redone together with annotation creation and deletion.
    public enum UndoableAction: Sendable {
        case added(Annotation)
        case removed(Annotation)
        /// A geometry mark moved, resized or otherwise replaced. The whole annotation is stored
        /// before and after, so undo/redo does not have to know which field the gesture touched.
        case replaced(before: Annotation, after: Annotation)
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
        case .replaced(let before, let after):
            let target = undoing ? before : after
            if let index = updated.firstIndex(where: { $0.id == target.id }) {
                updated[index] = target
            } else if !undoing {
                updated.append(target)
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

    /// Shows an annotation: selects its range (or its mark) and scrolls it into view.
    public func jump(to annotation: Annotation) {
        let top = engine.pageTopPt(annotation.page, gapPt: pageGapPt, layout: layoutMode)
        if annotation.kind.isGeometry {
            // A geometry mark has no character range. Select it so the overlay shows the
            // selection halo, and scroll to the mark rather than to the page's first character.
            selectedAnnotationID = annotation.id
            selection = nil
            selectionAnchor = nil
            let y = top + (annotation.geometryBounds?.midY ?? 0) - viewportHeightContentPt / 3
            if y < scrollYPt || y > scrollYPt + viewportHeightContentPt {
                scrollYPt = max(0, y)
            }
            reloadVisiblePages()
            return
        }
        selection = Selection(
            page: annotation.page,
            range: annotation.start...max(annotation.start, annotation.end)
        )
        selectionAnchor = nil
        selectedAnnotationID = nil
        if top < scrollYPt || top > scrollYPt + viewportHeightContentPt {
            scrollYPt = top
        }
        reloadVisiblePages()
    }

    /// Scrolls a page into view and highlights an annotation **the PDF carries**.
    ///
    /// A loaded annotation has no character range here (the text layer is not what it marks), so
    /// the only thing to show is where it is: scroll so its box is on screen, and select the
    /// text under the box when the page's text layer can tell us which characters those are —
    /// which is what makes a note in the sidebar feel like it points at something.
    public func jump(toDocumentAnnotation annotation: DocumentAnnotation) {
        // Both directions of "which annotation is the reader looking at" go through this: the
        // sidebar highlights the row it was asked to show, and a click on the annotation's own
        // glyph on the page comes here too.
        selectedDocumentAnnotationID = annotation.id
        let top = engine.pageTopPt(annotation.page, gapPt: pageGapPt, layout: layoutMode)
        let box = annotation.boxes.first
        // Put the annotation a third of the way down the viewport rather than at its very top:
        // a highlight is easier to recognise with the text above it visible.
        let target = top + (box?.yPt ?? 0) - viewportHeightContentPt / 3
        scrollYPt = max(0, min(target, max(0, contentHeightPt - viewportHeightContentPt)))

        selection = nil
        selectionAnchor = nil
        if !selectText(under: annotation) {
            // The page was off-screen, so its text layer may not be loaded yet; fetch it and
            // select afterwards. Without this, jumping to a note from the sidebar would land on
            // the right page with nothing marked.
            let page = annotation.page
            let epoch = documentEpoch
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let extracted = try? await self.engine.textPage(page) else { return }
                guard epoch == self.documentEpoch, self.selection == nil else { return }
                self.textPages[page] = extracted
                _ = self.selectText(under: annotation)
                self.reloadVisiblePages()
            }
        }
        reloadVisiblePages()
    }

    /// Selects the text an annotation's box covers, when its page's text layer is available.
    ///
    /// Returns false when it is not (yet), which the caller uses to decide whether to fetch it.
    @discardableResult
    private func selectText(under annotation: DocumentAnnotation) -> Bool {
        guard let box = annotation.boxes.first,
              let textPage = textPages[annotation.page] else { return false }
        // A sticky note's /Rect is the icon, which may sit in the margin next to the text it
        // comments on; the other kinds box the text itself.
        let range = textPage.characterRange(in: CGRect(
            x: box.xPt,
            y: box.yPt,
            width: box.widthPt,
            height: box.heightPt
        ))
        guard let range else { return false }
        selection = Selection(page: annotation.page, range: range)
        return true
    }

    // MARK: - Saving annotations into the PDF

    /// Whether the two PDF-writing commands can run.
    ///
    /// The sidecar is an unsaved-work store, not the feature: saving is always an explicit
    /// command from the reader, and it is disabled when there is nothing to write.
    public var canSaveAnnotationsToPDF: Bool {
        document != nil && !annotations.isEmpty && !annotationSaveInProgress
    }

    /// The name an annotated copy is offered as: `<name> (annotated).pdf`.
    public var suggestedAnnotatedCopyURL: URL? {
        guard let url = document?.url else { return nil }
        return engine.suggestedAnnotatedCopyURL(for: url)
    }

    /// The Save Annotated Copy panel. The writer's only job is to produce a new file; the
    /// document on screen (and its sidecar) stays exactly where it is.
    public func presentSaveAnnotatedCopyPanel() {
        guard let suggestion = suggestedAnnotatedCopyURL else { return }
        let panel = NSSavePanel()
        panel.title = "Save Annotated Copy"
        panel.message =
            "Every highlight and underline in the reader's list is written into a new PDF. "
            + "The original file is not modified."
        panel.nameFieldStringValue = suggestion.lastPathComponent
        panel.directoryURL = suggestion.deletingLastPathComponent()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { @MainActor [weak self] in
            await self?.saveAnnotatedCopy(to: destination)
        }
    }

    /// The clearly-labelled second choice: replace the original. The alert spells out the backup;
    /// the engine refuses the replacement if that backup cannot be written and verified.
    public func presentReplaceOriginalConfirmation() {
        guard let url = document?.url else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Replace “\(url.lastPathComponent)” with the annotated version?"
        alert.informativeText =
            "This changes the file on disk. A byte-identical backup is written first; "
            + "if the backup cannot be written, nothing is replaced."
        alert.addButton(withTitle: "Save and Replace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor [weak self] in
            await self?.replaceOriginalWithSavedAnnotations()
        }
    }

    /// Writes every annotation currently in the reader's list into a new PDF at `destination`.
    ///
    /// The original document is not touched, and its sidecar is not changed: the copy carries
    /// the annotations itself, so a fresh Lyra opening that copy sees them from the PDF and no
    /// sidecar duplicates them. Returns `false` when nothing was written.
    @discardableResult
    public func saveAnnotatedCopy(to destination: URL) async -> Bool {
        guard !annotationSaveInProgress else { return false }
        guard let documentURL = document?.url else {
            lastError = "Open a document before saving annotations"
            return false
        }
        guard !annotations.isEmpty else {
            statusMessage = "There are no annotations to save"
            return false
        }
        if Self.resolvesToSameFile(destination, documentURL) {
            lastError = "The annotated copy would be the original. Choose another name, or use “Save and Replace Original”."
            return false
        }
        // A sidecar beside the chosen copy would make every saved annotation appear twice when
        // that copy is opened: once from the PDF, once from the stale sidecar. Refuse rather
        // than silently deleting somebody else's file.
        let destinationSidecar = Self.sidecarURL(for: destination)
        if FileManager.default.fileExists(atPath: destinationSidecar.path) {
            lastError =
                "“\(destination.lastPathComponent)” already has a Lyra annotation sidecar. "
                + "Choose another name so the copy cannot show every annotation twice."
            return false
        }

        annotationSaveInProgress = true
        defer { annotationSaveInProgress = false }
        flushPendingWrites()
        guard !hasPendingAnnotationWrite else {
            lastError = "Could not flush the note that is still being edited; nothing was saved"
            return false
        }

        do {
            let requests = try await pendingAnnotationWrites()
            let report = try await engine.saveAnnotatedCopy(
                to: destination,
                annotations: requests,
                zoom: zoomFactor
            )
            lastAnnotationWriteReport = report
            let backup = report.backupPath.map { " · backup \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? ""
            statusMessage =
                "Saved \(report.writtenIDs.count) annotation(s) to \(destination.lastPathComponent)"
                + " · \(report.appendedBytes) bytes appended · the original is unchanged\(backup)"
            FileHandle.standardError.write(Data((
                "aris-annotate: saved \(report.writtenIDs.count) annotation(s) to \(destination.path)"
                + " (append \(report.appendedBytes) bytes)\(backup)\n"
            ).utf8))
            return true
        } catch {
            lastError = "Could not save the annotated copy: \(error.localizedDescription)"
            statusMessage = "Could not save the annotated copy"
            FileHandle.standardError.write(
                Data("aris-annotate: annotated-copy save failed: \(error)\n".utf8)
            )
            return false
        }
    }

    /// Replaces the open document with one carrying the reader's annotations.
    ///
    /// The engine writes a verified backup first and replaces the original by an atomic rename
    /// of a verified temporary file. Only after that succeeds are exactly the saved sidecar
    /// entries removed; the document is reopened so its annotations now come from the PDF.
    /// Returns `false` when nothing was replaced.
    @discardableResult
    public func replaceOriginalWithSavedAnnotations() async -> Bool {
        guard !annotationSaveInProgress else { return false }
        guard let url = document?.url else {
            lastError = "Open a document before saving annotations"
            return false
        }
        guard !annotations.isEmpty else {
            statusMessage = "There are no annotations to save"
            return false
        }

        annotationSaveInProgress = true
        defer { annotationSaveInProgress = false }
        flushPendingWrites()
        guard !hasPendingAnnotationWrite else {
            lastError = "Could not flush the note that is still being edited; nothing was replaced"
            return false
        }

        do {
            let requests = try await pendingAnnotationWrites()
            let report = try await engine.replaceWithAnnotations(requests, zoom: zoomFactor)

            // The PDF is now the source of truth. Remove exactly the written ids from the
            // sidecar so reopening the file does not show each annotation twice.
            let cleanedSidecar = forgetAnnotationsSavedToPDF(
                ids: Set(report.writtenIDs.compactMap { UUID(uuidString: $0) })
            )

            // The engine marks the old handle stale; reopen the file in place, keeping the
            // reading position and zoom.
            let loaded = try engine.openDocument(at: url)
            document = loaded
            documentEpoch &+= 1
            documentAnnotations = []
            documentAnnotationsLoading = false
            documentAnnotationsLoadCompleted = false
            documentAnnotationsError = nil
            interruptedAnnotationSaveNotice = nil
            selectedDocumentAnnotationID = nil
            openDocumentNoteID = nil
            invalidateTiles()
            if cleanedSidecar {
                loadAnnotations(for: url)
            }
            loadDocumentAnnotations()
            reloadVisiblePages()

            lastAnnotationWriteReport = report
            if !cleanedSidecar {
                lastError =
                    "The annotations are saved in the PDF, but the sidecar could not be updated. "
                    + "They will be reconciled the next time the document is opened, so they do not appear twice."
            }
            let backup = report.backupPath
                .map { URL(fileURLWithPath: $0).lastPathComponent } ?? "none"
            statusMessage =
                "Saved \(report.writtenIDs.count) annotation(s) into \(url.lastPathComponent)"
                + " · backup: \(backup)"
            if !cleanedSidecar {
                statusMessage += " · the sidecar could not be updated and will be reconciled on open"
            }
            FileHandle.standardError.write(Data((
                "aris-annotate: replaced \(url.path) with \(report.writtenIDs.count) annotation(s)"
                + ", backup \(backup), sidecar cleaned: \(cleanedSidecar)\n"
            ).utf8))
            return true
        } catch {
            lastError = "Could not replace the original: \(error.localizedDescription)"
            statusMessage = "Could not replace the original"
            FileHandle.standardError.write(
                Data("aris-annotate: replace failed: \(error)\n".utf8)
            )
            return false
        }
    }

    /// Builds write requests from the sidecar annotations.
    ///
    /// The quads are the same `TextPage.selectionRects` the canvas draws, scaled to the zoom the
    /// reader is at now. They are **view-space** on purpose: the engine inverts that scale with
    /// the page geometry, so the stored PDF coordinates do not depend on the zoom this happened
    /// to be called at.
    private func pendingAnnotationWrites() async throws -> [AnnotationWriteRequest] {
        guard let document else { return [] }
        let zoom = zoomFactor
        let savedAt = Date()
        let modified = Self.pdfDate(savedAt)
        var requests: [AnnotationWriteRequest] = []
        for annotation in annotations {
            guard annotation.page >= 0, annotation.page < document.pageCount else {
                throw NSError(
                    domain: "Lyra",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Annotation \(annotation.id.uuidString) names page \(annotation.page + 1), which is outside this document"]
                )
            }
            if annotation.kind.isGeometry {
                requests.append(try geometryWriteRequest(annotation, zoom: zoom, modified: modified))
                continue
            }
            let text: TextPage
            if let cached = textPages[annotation.page] {
                text = cached
            } else {
                text = try await engine.textPage(annotation.page)
                textPages[annotation.page] = text
            }
            guard annotation.start >= 0,
                  annotation.end >= annotation.start,
                  annotation.end < text.chars.count
            else {
                throw NSError(
                    domain: "Lyra",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Annotation \(annotation.id.uuidString) covers characters \(annotation.start)…\(annotation.end), "
                        + "but page \(annotation.page + 1) has \(text.chars.count) characters"]
                )
            }
            let rects = text.selectionRects(in: annotation.start...annotation.end)
            guard !rects.isEmpty else {
                throw NSError(
                    domain: "Lyra",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Annotation \(annotation.id.uuidString) covers no visible text and cannot be written"]
                )
            }
            let quads = rects.map { rect in
                CGRect(
                    x: rect.origin.x * zoom,
                    y: rect.origin.y * zoom,
                    width: rect.width * zoom,
                    height: rect.height * zoom
                )
            }
            let union = quads.dropFirst().reduce(quads[0]) { $0.union($1) }
            requests.append(AnnotationWriteRequest(
                id: annotation.id.uuidString,
                page: annotation.page,
                kind: annotation.kind == .highlight ? .highlight : .underline,
                rect: union,
                quads: quads,
                color: annotation.color,
                opacity: Double(annotation.color.alpha) / 255.0,
                contents: annotation.note,
                author: Self.annotationAuthor,
                modified: modified
            ))
        }
        return requests
    }

    /// One stroked annotation as a write request.
    ///
    /// The sidecar stores page-local view space at 100%; `AnnotationWriteRequest` wants the same
    /// space scaled to the zoom the canvas is at. That multiplication and the engine's inverse
    /// are the pair the zoom-independence check exercises: the PDF's coordinates come back
    /// identical whichever zoom this ran at.
    ///
    /// `/Rect` is the **outer** box of the stroke: a centred stroke extends half a width past
    /// the path, and an arrowhead extends past its endpoint. Writing the outer box is what makes
    /// the annotation's own `/AP` clip nothing, and reading it back insets shapes by half the
    /// border width again so the stroke is the same width in the PDF as on the page.
    private func geometryWriteRequest(
        _ annotation: Annotation,
        zoom: CGFloat,
        modified: String
    ) throws -> AnnotationWriteRequest {
        guard annotation.hasValidGeometry, let bounds = annotation.geometryBounds else {
            throw NSError(
                domain: "Lyra",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey:
                    "Annotation \(annotation.id.uuidString) has incomplete geometry and cannot be written"]
            )
        }
        let width = annotation.strokeWidth
        var outer = bounds
        switch annotation.kind {
        case .ink:
            outer = outer.insetBy(dx: -width / 2 - 1, dy: -width / 2 - 1)
        case .square, .circle:
            outer = outer.insetBy(dx: -width / 2 - 0.5, dy: -width / 2 - 0.5)
        case .line:
            outer = outer.insetBy(dx: -width / 2 - 1, dy: -width / 2 - 1)
        case .arrow:
            let head = max(width * 5, 8)
            outer = outer.insetBy(dx: -(width / 2 + head), dy: -(width / 2 + head))
        case .highlight, .underline:
            break
        }
        guard outer.width > 0.5, outer.height > 0.5 else {
            throw NSError(
                domain: "Lyra",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey:
                    "Annotation \(annotation.id.uuidString) has a box too small to write"]
            )
        }
        func scaled(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * zoom, y: rect.minY * zoom,
                   width: rect.width * zoom, height: rect.height * zoom)
        }
        func scaled(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * zoom, y: point.y * zoom)
        }
        let kind: AnnotationWriteRequest.Kind
        switch annotation.kind {
        case .ink: kind = .ink
        case .square: kind = .square
        case .circle: kind = .circle
        case .line, .arrow: kind = .line
        case .highlight, .underline: kind = .highlight
        }
        return AnnotationWriteRequest(
            id: annotation.id.uuidString,
            page: annotation.page,
            kind: kind,
            rect: scaled(outer),
            quads: [],
            inkPaths: annotation.inkPaths.map { $0.map(scaled) },
            lineStart: annotation.lineStart.map(scaled),
            lineEnd: annotation.lineEnd.map(scaled),
            lineArrow: annotation.kind == .arrow,
            borderWidthPt: width,
            color: annotation.color,
            opacity: Double(annotation.color.alpha) / 255.0,
            contents: annotation.note,
            author: Self.annotationAuthor,
            modified: modified
        )
    }

    /// Removes exactly `ids` from the sidecar, keeping every other entry, foreign entry, bookmark
    /// and their order. Returns false when the sidecar could not be written; the in-memory model
    /// is still trimmed so the canvas cannot show a duplicate until the next open reconciles it.
    @discardableResult
    private func forgetAnnotationsSavedToPDF(ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty else { return true }
        let remaining = annotations.filter { !ids.contains($0.id) }
        let slots = annotationSidecarSlots.filter { slot in
            if case .annotation(let id) = slot { return !ids.contains(id) }
            return true
        }
        undoStack.removeAll()
        redoStack.removeAll()
        if writeSidecar(
            annotations: remaining,
            bookmarks: bookmarks,
            slots: slots,
            trigger: "saved-to-pdf"
        ) {
            return true
        }
        annotations = remaining
        annotationSidecarSlots = slots
        FileHandle.standardError.write(Data(
            "aris-annotate: the PDF was saved but the sidecar could not be updated; the saved entries are hidden in memory and will be reconciled on the next open\n".utf8
        ))
        return false
    }

    /// The open-time half of duplicate avoidance.
    ///
    /// A write-back can succeed and then fail to update the sidecar (or somebody can restore an
    /// old sidecar). The PDF's `/NM` is the sidecar's UUID string, so an entry whose identity is
    /// already in the file is stale by definition: show the PDF's copy and drop the sidecar's,
    /// never both. The stale entries are removed from the slot list, so the next ordinary
    /// sidecar write also drops them from the file.
    private func reconcileAnnotationsAlreadySaved(_ found: [DocumentAnnotation]) {
        guard !annotations.isEmpty else { return }
        let identities = Set(found.map(\.id))
        let saved = annotations.filter { identities.contains("nm:\($0.id.uuidString)") }
        guard !saved.isEmpty else { return }
        let savedIDs = Set(saved.map(\.id))
        annotations.removeAll { savedIDs.contains($0.id) }
        annotationSidecarSlots.removeAll { slot in
            if case .annotation(let id) = slot { return savedIDs.contains(id) }
            return true
        }
        undoStack.removeAll()
        redoStack.removeAll()
        statusMessage =
            "\(savedIDs.count) annotation(s) in this PDF were already saved; they now come from the file"
        FileHandle.standardError.write(Data(
            "aris-annotate: reconciled \(savedIDs.count) sidecar entr(ies) already present in the PDF\n".utf8
        ))
    }

    /// Reports a leftover temporary from an interrupted save, without treating it as damage to
    /// the document: the rename is the last step, so the document is still the last good copy.
    private func noticeInterruptedSave(at url: URL) {
        interruptedAnnotationSaveNotice = engine.interruptedSaveNote(at: url)
        guard let notice = interruptedAnnotationSaveNotice else { return }
        statusMessage = notice
        FileHandle.standardError.write(Data("aris-annotate: \(notice)\n".utf8))
    }

    /// The account's display name for `/T`, or "Lyra" when it has none.
    public nonisolated static let annotationAuthor: String = {
        let name = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Lyra" : name
    }()

    /// A date in the PDF `/M` format: `D:YYYYMMDDHHmmSSOHH'mm'`.
    public nonisolated static func pdfDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMddHHmmss"
        let offset = TimeZone.current.secondsFromGMT(for: date)
        let sign = offset >= 0 ? "+" : "-"
        let absolute = abs(offset)
        let hours = absolute / 3600
        let minutes = (absolute % 3600) / 60
        return String(format: "D:%@%@%02d'%02d'", formatter.string(from: date), sign, hours, minutes)
    }

    /// Whether two URLs name the same file, resolving symlinks when both exist.
    private static func resolvesToSameFile(_ first: URL, _ second: URL) -> Bool {
        let firstPath = first.standardizedFileURL.resolvingSymlinksInPath().path
        let secondPath = second.standardizedFileURL.resolvingSymlinksInPath().path
        return firstPath == secondPath
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
            bookmarks = contents.bookmarks
            annotationSidecarSlots = contents.slots
            preservedAnnotationEntryCount = contents.preservedCount
            undoStack.removeAll()
            redoStack.removeAll()
            let line = "aris-annotate: loaded \(contents.annotations.count) annotation(s),"
                + " \(contents.bookmarks.count) bookmark(s),"
                + " \(contents.preservedCount) preserved from a newer version\n"
            FileHandle.standardError.write(Data(line.utf8))
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            annotations = []
            bookmarks = []
            undoStack.removeAll()
            redoStack.removeAll()
        } catch {
            annotations = []
            bookmarks = []
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
        writeSidecar(
            annotations: candidate,
            bookmarks: bookmarks,
            slots: annotationSidecarSlots,
            trigger: trigger
        )
    }

    /// Writes both kinds of entry to the one sidecar and publishes the new arrays only after
    /// the atomic write succeeds. Any unreadable/corrupt existing sidecar is protected from
    /// accidental replacement.
    ///
    /// `trigger` only labels the stderr instrumentation line, so a run can show *why* a write
    /// happened (a keystroke, a coalesced flush, a bookmark move, …).
    @discardableResult
    private func writeSidecar(
        annotations candidateAnnotations: [Annotation],
        bookmarks candidateBookmarks: [Bookmark],
        slots: [AnnotationSidecar.Slot],
        trigger: String
    ) -> Bool {
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
                annotations: candidateAnnotations,
                bookmarks: candidateBookmarks,
                slots: slots
            )
            try data.write(to: annotationsURL, options: .atomic)
            annotations = candidateAnnotations
            bookmarks = candidateBookmarks
            annotationSidecarSlots = slots
            hasPendingAnnotationWrite = false
            annotationWriteCount += 1
            let line = "aris-annotate: saved \(candidateAnnotations.count) annotation(s),"
                + " \(candidateBookmarks.count) bookmark(s)"
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

    // MARK: - Exporting annotations as text

    /// Whether the Export Annotations command can run.
    ///
    /// Deliberately true for a document with no annotations: invoking the command then says so
    /// and writes nothing. A disabled item would leave the reader wondering whether the document
    /// has annotations at all.
    public var canExportAnnotations: Bool { document != nil }

    /// True when the current document has anything the export would write.
    ///
    /// Every annotation the file carries is included, including ones whose `/F` hides them from
    /// the page: the flag says what to paint, not what the review thread contains. The reader's
    /// own sidecar entries are included of course. Bookmarks are not annotations and are not part
    /// of this export.
    public var hasAnnotationsToExport: Bool {
        !annotations.isEmpty || !documentAnnotations.isEmpty
    }

    /// Why an export found nothing, without pretending a failed read was an empty file.
    private var noAnnotationsToExportDetail: String {
        if let error = documentAnnotationsError {
            return "The PDF's annotations could not be read (\(error)), and Lyra's sidecar has "
                + "none, so no file was written."
        }
        return "This document has no annotations from Lyra and none in the PDF, so no file was written."
    }

    /// The save-panel suggestion for one format, e.g. `paper (annotations).md`.
    ///
    /// During a page-editing session the open document is a revision; the reader is still working
    /// on the original file, so the original's name is the one the export should carry.
    public func suggestedAnnotationExportFilename(for format: AnnotationExportFormat) -> String {
        AnnotationExport.suggestedFilename(documentURL: pageEditDisplayURL, format: format)
    }

    /// Opens the save panel that offers Markdown and CSV.
    ///
    /// The format is chosen in the panel, so there is one File menu command rather than two
    /// parallel ones. PDF annotations may still be loading when the reader picks the command
    /// (the engine reads them asynchronously on open), so the panel waits for that read to
    /// finish before deciding whether there is anything to export.
    public func presentExportAnnotationsPanel() {
        guard document != nil else {
            statusMessage = "Open a document before exporting annotations"
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.waitForDocumentAnnotationsIfNeeded()
            guard self.hasAnnotationsToExport else {
                self.statusMessage = "There are no annotations to export"
                self.lastError = self.noAnnotationsToExportDetail
                FileHandle.standardError.write(
                    Data("aris-annotate-export: nothing to export, no panel shown\n".utf8)
                )
                return
            }
            self.runExportAnnotationsPanel()
        }
    }

    private func runExportAnnotationsPanel() {
        guard document != nil else { return }
        let panel = NSSavePanel()
        panel.title = "Export Annotations"
        panel.prompt = "Export"
        panel.message =
            "Writes every annotation — the reader's and the PDF's own — to a text file. "
            + "Nothing is sent anywhere; the file is written on this Mac."
        panel.directoryURL = pageEditDisplayURL?.deletingLastPathComponent()
        panel.canCreateDirectories = true

        let accessory = AnnotationExportSavePanelAccessory(
            panel: panel,
            documentURL: pageEditDisplayURL
        )
        panel.accessoryView = accessory.view
        accessory.apply(format: .markdown)

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let format = accessory.format
        Task { @MainActor [weak self] in
            await self?.exportAnnotations(to: destination, format: format)
        }
    }

    /// The ordered, source-labelled export of the current document, or `nil` when it has no
    /// annotations.
    ///
    /// Text layers are fetched only for pages the export needs: a sidecar highlight's character
    /// range gives both its quote and its vertical position, and a file markup annotation's
    /// quads give its quote the same way. A page whose text layer cannot be read still exports
    /// its annotations — the quote and the vertical position are simply absent, rather than the
    /// whole export failing.
    public func annotationExportDocument(
        exportedAt: Date = Date(),
        timeZone: TimeZone = .current
    ) async -> AnnotationExportDocument? {
        guard let document else { return nil }
        await waitForDocumentAnnotationsIfNeeded()

        var neededPages = Set(annotations.map(\.page))
        for annotation in documentAnnotations where annotation.isMarkup {
            neededPages.insert(annotation.page)
        }
        var textByPage: [Int: TextPage] = [:]
        for page in neededPages.sorted() {
            guard page >= 0, page < document.pageCount else { continue }
            if let cached = textPages[page] {
                textByPage[page] = cached
                continue
            }
            if let fetched = try? await engine.textPage(page) {
                textByPage[page] = fetched
            }
        }

        var entries: [AnnotationExportEntry] = []
        for annotation in annotations {
            var quote: String?
            var yPt = CGFloat.greatestFiniteMagnitude
            if annotation.kind.isGeometry {
                // A stroke has no character range; exporting the first character of the page as
                // its "quote" would invent a relationship the mark does not have.
                yPt = annotation.geometryBounds?.minY ?? yPt
            } else if let page = textByPage[annotation.page],
               annotation.start >= 0,
               annotation.end >= annotation.start,
               annotation.end < page.chars.count {
                let range = annotation.start...annotation.end
                if let raw = AnnotationExport.text(in: page, range: range) {
                    quote = AnnotationExport.normalized(raw)
                }
                if let top = page.selectionRects(in: range).map(\.minY).min() {
                    yPt = top
                }
            }
            entries.append(AnnotationExportEntry(
                id: annotation.id.uuidString,
                page: annotation.page,
                kind: annotation.kind.rawValue,
                colorHex: annotation.color.hex,
                author: Self.annotationAuthor,
                date: annotation.createdAt,
                quote: quote,
                comment: AnnotationExport.normalized(annotation.note),
                source: .sidecar,
                yPt: yPt
            ))
        }

        for annotation in documentAnnotations {
            let page = textByPage[annotation.page]
            entries.append(AnnotationExportEntry(
                id: annotation.id,
                page: annotation.page,
                kind: annotation.kind,
                colorHex: annotation.color?.hex,
                author: annotation.author,
                date: AnnotationExport.date(fromPDFDate: annotation.modified),
                quote: AnnotationExport.quote(for: annotation, in: page),
                comment: AnnotationExport.normalized(annotation.contents),
                source: .pdf,
                parentID: annotation.parentID,
                yPt: annotation.boxes.map(\.yPt).min() ?? annotation.yPt
            ))
        }

        guard !entries.isEmpty else { return nil }
        return AnnotationExportDocument(
            fileName: pageEditDisplayURL?.lastPathComponent ?? document.title,
            pageCount: document.pageCount,
            exportedAt: exportedAt,
            timeZone: timeZone,
            entries: entries
        )
    }

    /// Writes the export at `destination` and returns whether a file was written.
    ///
    /// This is a local file write with the same atomic discipline as the sidecar: the complete
    /// document is written to a sibling temporary file and renamed into place, so an interrupted
    /// or failed export cannot leave a truncated file where the reader expects a complete one.
    /// With no annotations the method writes nothing, reports why, and returns `false`.
    @discardableResult
    public func exportAnnotations(
        to destination: URL,
        format: AnnotationExportFormat,
        exportedAt: Date = Date(),
        timeZone: TimeZone = .current
    ) async -> Bool {
        guard let document else {
            lastError = "Open a document before exporting annotations"
            statusMessage = "Open a document before exporting annotations"
            return false
        }
        if let documentURL = document.url, Self.resolvesToSameFile(destination, documentURL) {
            lastError = "The annotation export cannot overwrite the PDF it describes. Choose another name."
            statusMessage = "Could not export annotations"
            return false
        }
        // A note that is still inside the typing debounce is already in `annotations`; flushing
        // it first keeps the sidecar consistent with what this export says.
        flushPendingWrites()

        guard let export = await annotationExportDocument(exportedAt: exportedAt, timeZone: timeZone) else {
            statusMessage = "There are no annotations to export"
            lastError = noAnnotationsToExportDetail
            FileHandle.standardError.write(
                Data("aris-annotate-export: nothing to export, no file written\n".utf8)
            )
            return false
        }

        let text = AnnotationExport.render(export, format: format)
        do {
            try Data(text.utf8).write(to: destination, options: .atomic)
        } catch {
            lastError = "Could not export annotations: \(error.localizedDescription)"
            statusMessage = "Could not export annotations"
            FileHandle.standardError.write(
                Data("aris-annotate-export: write to \(destination.path) failed: \(error)\n".utf8)
            )
            return false
        }

        let sidecarCount = export.rows.filter { $0.entry.source == .sidecar }.count
        let pdfCount = export.rows.count - sidecarCount
        statusMessage =
            "Exported \(export.rows.count) annotation(s) to \(destination.lastPathComponent)"
            + " · \(format.displayName) · \(sidecarCount) from the sidecar, \(pdfCount) from the PDF"
        FileHandle.standardError.write(Data((
            "aris-annotate-export: wrote \(export.rows.count) annotation(s) to \(destination.path)"
            + " (\(format.rawValue), \(sidecarCount) sidecar, \(pdfCount) pdf)\n"
        ).utf8))
        return true
    }

    /// Waits briefly for the engine's document-wide annotation read when it is in flight.
    ///
    /// `/Annots` is read once per open document, asynchronously, so an export issued immediately
    /// after opening would otherwise silently omit the file's own annotations. A bounded wait
    /// keeps a slow or failed read from blocking the command forever; the export then proceeds
    /// with what is loaded.
    private func waitForDocumentAnnotationsIfNeeded() async {
        guard documentAnnotationsLoading else { return }
        let deadline = ContinuousClock.now + .milliseconds(3000)
        while documentAnnotationsLoading && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    // MARK: - Page editing (T3.9)
    //
    // The original file is never modified until the reader chooses "Replace Original". Every
    // operation is applied by the Rust engine to a temporary revision in a session directory;
    // the app renders that revision and keeps the reader's sidecar in a session copy. That gives
    // a coherent undo history (a stack of revisions, not an inverse operation that cannot restore
    // deleted content) and means a crash or a discarded session leaves the PDF and its sidecar
    // exactly as they were.

    /// One revision plus the reader's marks at that revision. Undo/redo restore both together:
    /// an annotation added to a page that a later undo removes must disappear, and come back on
    /// redo, rather than being pushed onto a neighbour.
    private struct PageEditSnapshot {
        let revisionURL: URL
        let revisionNumber: Int
        let currentToOriginal: [Int]
        let operations: [String]
        let annotations: [Annotation]
        let bookmarks: [Bookmark]
        let slots: [AnnotationSidecar.Slot]
        let currentPage: Int
        let selection: Set<Int>
        let label: String
    }

    private struct PageEditSession {
        let originalURL: URL
        let originalSidecarURL: URL
        let title: String
        let directory: URL
        let sidecarURL: URL
        /// `/Rotate` of every page of the file the session started from.
        let originalRotations: [Int]
        var revisionURL: URL
        var revisionNumber: Int
        /// current page index → index in `originalRotations`; -1 for an inserted blank page.
        var currentToOriginal: [Int]
        var operations: [String]
        var undo: [PageEditSnapshot]
        var redo: [PageEditSnapshot]
    }

    /// Whether the page commands can run at all.
    public var canPageEdit: Bool {
        document != nil && !annotationSaveInProgress && !pageEditBusy
    }

    public var pageEditSessionActive: Bool { pageEditSession != nil }
    public var canUndoPageEdit: Bool { pageEditSession?.undo.isEmpty == false && !pageEditBusy }
    public var canRedoPageEdit: Bool { pageEditSession?.redo.isEmpty == false && !pageEditBusy }
    public var canApplyPageEdits: Bool {
        pageEditSession != nil && !pageEditBusy && !annotationSaveInProgress
    }

    /// The entry point behind the menu commands, exposed separately so the headless checks can
    /// exercise the real session without driving AppKit menus or modal alerts.
    @discardableResult
    public func applyPageEditOperation(_ operation: PageEditOperation, label: String) async -> Bool {
        await applyPageEdit(operation, label: label)
    }

    /// What the interface must say about the staged state. Nil when nothing is pending.
    public var pageEditPendingSummary: String? {
        guard let session = pageEditSession else { return nil }
        let count = session.operations.count
        let label = count == 1 ? "1 page change pending" : "\(count) page changes pending"
        return "\(label) · the file on disk is unchanged"
    }

    /// The most recent pending action, for the banner's second line.
    public var pageEditLastAction: String? {
        pageEditSession?.operations.last
    }

    /// The pages a command acts on: the thumbnail selection, or the current page when there is
    /// no selection.
    public var selectedPageIndices: [Int] {
        let count = document?.pageCount ?? 0
        guard count > 0 else { return [] }
        let selected = pageSelection.filter { $0 >= 0 && $0 < count }.sorted()
        if !selected.isEmpty { return selected }
        return [min(max(currentPage - 1, 0), count - 1)]
    }

    /// The display name for suggestions and alerts. During a session the open document is a
    /// revision, but the reader is still working on the original file.
    private var pageEditDisplayURL: URL? {
        pageEditSession?.originalURL ?? document?.url
    }

    public func handleThumbnailClick(_ page: Int, modifiers: NSEvent.ModifierFlags) {
        guard let pageCount = document?.pageCount, page >= 0, page < pageCount else { return }
        if modifiers.contains(.shift) {
            selectPage(page, extending: true, toggling: false)
        } else if modifiers.contains(.command) {
            selectPage(page, extending: false, toggling: true)
        } else {
            selectPage(page, extending: false, toggling: false)
            gotoPage(page)
        }
    }

    public func selectPage(_ page: Int, extending: Bool, toggling: Bool) {
        guard let pageCount = document?.pageCount, page >= 0, page < pageCount else { return }
        if extending, let anchor = pageSelectionAnchor {
            pageSelection.formUnion(anchor <= page ? anchor...page : page...anchor)
        } else if toggling {
            if pageSelection.contains(page) {
                pageSelection.remove(page)
            } else {
                pageSelection.insert(page)
            }
            pageSelectionAnchor = page
        } else {
            pageSelection = [page]
            pageSelectionAnchor = page
        }
        statusMessage = pageSelection.count <= 1
            ? "Page \(page + 1) selected · ⌘-click to add pages, shift-click for a range"
            : "\(pageSelection.count) pages selected"
    }

    public func clearPageSelection() {
        pageSelection = []
        pageSelectionAnchor = nil
    }

    // MARK: Commands

    public func rotateSelectedPages(clockwise: Bool) {
        let pages = selectedPageIndices
        guard !pages.isEmpty else { return }
        if let conflict = rotationConflict(on: pages) {
            lastError = conflict
            statusMessage = "Rotation refused: the page has text-range annotations"
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.applyPageEdit(
                .rotate(pages: pages, quarterTurns: clockwise ? 1 : -1),
                label: "Rotate \(Self.pageList(pages)) \(clockwise ? "90° clockwise" : "90° anticlockwise")"
            )
        }
    }

    public func resetSelectedPageRotations() {
        let checkedPages = selectedPageIndices
        if let conflict = rotationConflict(on: checkedPages) {
            lastError = conflict
            statusMessage = "Rotation refused: the page has text-range annotations"
            return
        }
        Task { @MainActor [weak self] in
            guard let self, await self.ensurePageEditSession() else { return }
            guard let session = self.pageEditSession else { return }
            let pages = self.selectedPageIndices
            guard !pages.isEmpty else { return }
            let values = pages.map { page -> Int in
                guard page < session.currentToOriginal.count else { return 0 }
                let original = session.currentToOriginal[page]
                guard original >= 0, original < session.originalRotations.count else { return 0 }
                return session.originalRotations[original]
            }
            _ = await self.applyPageEdit(
                .setRotation(pages: pages, quarterTurns: values),
                label: "Reset rotation of \(Self.pageList(pages)) to the file's original"
            )
        }
    }

    public func confirmDeleteSelectedPages() {
        guard let document else { return }
        let pages = selectedPageIndices
        guard !pages.isEmpty else { return }
        guard pages.count < document.pageCount else {
            lastError = "A PDF must keep at least one page; every page is selected for deletion."
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = pages.count == 1
            ? "Delete page \(pages[0] + 1) from the working copy?"
            : "Delete \(pages.count) pages from the working copy?"
        alert.informativeText =
            "The file on disk is not changed. The pages disappear from this editing session, and "
            + "annotations or bookmarks on them are removed rather than pushed to a neighbour; "
            + "Undo restores them until you apply or discard the changes."
        alert.addButton(withTitle: "Delete Pages")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor [weak self] in
            _ = await self?.applyPageEdit(
                .delete(pages: pages),
                label: "Delete \(Self.pageList(pages))"
            )
        }
    }

    public func moveSelectedPagesUp() {
        moveSelectedPages(by: -1)
    }

    public func moveSelectedPagesDown() {
        moveSelectedPages(by: 1)
    }

    private func moveSelectedPages(by offset: Int) {
        guard let document else { return }
        let pages = selectedPageIndices
        guard let first = pages.first, let last = pages.last else { return }
        guard pages.count == last - first + 1 else {
            lastError = "Move requires a contiguous selection; select a range of pages, not a scattered set."
            return
        }
        if offset < 0 {
            guard first > 0 else {
                statusMessage = "The selected pages are already at the top"
                return
            }
        } else {
            guard last < document.pageCount - 1 else {
                statusMessage = "The selected pages are already at the bottom"
                return
            }
        }
        let destination = offset < 0 ? first - 1 : first + 1
        Task { @MainActor [weak self] in
            _ = await self?.applyPageEdit(
                .move(pages: pages, destination: destination),
                label: "Move \(Self.pageList(pages)) \(offset < 0 ? "up one page" : "down one page")"
            )
        }
    }

    public func insertBlankPage(before: Bool) {
        let pages = selectedPageIndices
        guard let first = pages.first, let last = pages.last else { return }
        let index = before ? first : last + 1
        Task { @MainActor [weak self] in
            _ = await self?.applyPageEdit(
                .insertBlank(index: index),
                label: before
                    ? "Insert a blank page before page \(first + 1)"
                    : "Insert a blank page after page \(last + 1)"
            )
        }
    }

    // MARK: Thumbnail drag reorder

    /// The block a drag that starts on `page` would carry, using the same page selection the
    /// Pages menu acts on. The thumbnail drag source asks this when the pointer passes the drag
    /// threshold; a refusal means no drag session starts (and so no insertion indicator either).
    public func thumbnailDragBlock(startingAt page: Int) -> ThumbnailDragBlockResolution {
        ThumbnailDrag.block(
            pressedPage: page,
            selection: pageSelection,
            pageCount: document?.pageCount ?? 0,
            isEditable: canPageEdit
        )
    }

    /// Stages a thumbnail drag's move through the same session as the Pages menu.
    ///
    /// This is the only entry point the drop target calls. It re-validates the request against
    /// the document as it is now (a drop can arrive after a revision or a tab switch), asks the
    /// same rules the indicator used, and then hands the move to ``applyPageEdit(_:label:)`` —
    /// so undo/redo, the remapped annotations and bookmarks, and the "file on disk is unchanged"
    /// contract are exactly the menu path's, not a second implementation.
    ///
    /// On success the moved block is the page selection, so the reader sees what they moved even
    /// when the drag started on an unselected thumbnail.
    @discardableResult
    public func performThumbnailDrop(_ request: ThumbnailDropRequest) async -> Bool {
        guard let document else {
            lastError = "There is no document to reorder."
            return false
        }
        let pageCount = document.pageCount
        let pages = request.pages
        guard let first = pages.first, let last = pages.last,
              first >= 0, last < pageCount,
              last - first + 1 == pages.count,
              request.destination >= 0,
              request.destination + pages.count <= pageCount else {
            lastError = "The page drag does not match the document any more; nothing was moved."
            statusMessage = "The page drag no longer matches the document"
            return false
        }
        // Re-run the drop rules on the request's final position. This catches a drag whose
        // document changed under it, and makes the no-op verdict the indicator showed true of
        // the command that actually runs.
        let boundary = request.destination < first
            ? request.destination
            : request.destination + pages.count
        let resolution = ThumbnailDrag.drop(
            block: ThumbnailDragBlock(pages: pages, pressedPage: request.pressedPage),
            boundary: boundary,
            pageCount: pageCount
        )
        if case .refused(let refusal) = resolution {
            statusMessage = refusal.message
            return false
        }
        let label = pages.count == 1
            ? "Move page \(first + 1) to position \(request.destination + 1)"
            : "Move pages \(first + 1)–\(last + 1) to position \(request.destination + 1)"
        let staged = await applyPageEdit(
            .move(pages: pages, destination: request.destination),
            label: label
        )
        guard staged else { return false }
        // The session remaps the old selection through the page map. A drag states its intent
        // more directly: the block the reader dropped is selected at its landing place.
        pageSelection = Set(request.finalRange)
        pageSelectionAnchor = request.destination
        return true
    }

    public func presentExtractPagesPanel() {
        guard let source = pageEditDisplayURL else { return }
        let pages = selectedPageIndices
        guard !pages.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Extract Pages"
        panel.message =
            "Writes the selected pages to a new PDF. The open document is not modified; "
            + "annotations embedded in the PDF travel with their pages."
        panel.nameFieldStringValue =
            "\(source.deletingPathExtension().lastPathComponent) (pages \(Self.pageList(pages))).pdf"
        panel.directoryURL = source.deletingLastPathComponent()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { @MainActor [weak self] in
            await self?.extractPages(pages, to: destination)
        }
    }

    @discardableResult
    public func extractPages(_ pages: [Int], to destination: URL) async -> Bool {
        guard let url = document?.url else { return false }
        guard !Self.resolvesToSameFile(destination, url) else {
            lastError = "The extracted pages cannot overwrite the document they came from."
            return false
        }
        pageEditBusy = true
        defer { pageEditBusy = false }
        do {
            let report = try await engine.extractPages(pages, to: destination)
            statusMessage =
                "Extracted \(Self.pageList(pages)) to \(destination.lastPathComponent)"
                + " · \(report.pageCount) page(s) written"
            FileHandle.standardError.write(Data((
                "aris-pages: extracted \(pages.count) page(s) to \(destination.path)"
                + " (\(report.outputBytes) bytes)\n"
            ).utf8))
            return true
        } catch {
            lastError = "Could not extract the pages: \(error.localizedDescription)"
            statusMessage = "Could not extract the pages"
            return false
        }
    }

    public func presentSavePageEditsCopyPanel() {
        guard let source = pageEditDisplayURL, pageEditSession != nil else { return }
        let panel = NSSavePanel()
        panel.title = "Save Edited Copy"
        panel.message =
            "Writes the staged page changes to a new PDF and leaves the original untouched. "
            + "The reader's annotations are saved beside the copy."
        panel.nameFieldStringValue =
            "\(source.deletingPathExtension().lastPathComponent) (page edits).pdf"
        panel.directoryURL = source.deletingLastPathComponent()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { @MainActor [weak self] in
            await self?.savePageEditsCopy(to: destination)
        }
    }

    @discardableResult
    public func savePageEditsCopy(to destination: URL) async -> Bool {
        guard let session = pageEditSession, !pageEditBusy else { return false }
        if Self.resolvesToSameFile(destination, session.originalURL) {
            lastError = "The edited copy would be the original. Use “Replace Original with Page Changes” for that."
            return false
        }
        let destinationSidecar = Self.sidecarURL(for: destination)
        if FileManager.default.fileExists(atPath: destinationSidecar.path) {
            lastError =
                "“\(destination.lastPathComponent)” already has a Lyra annotation sidecar. "
                + "Choose another name so the copy cannot show every annotation twice."
            return false
        }
        let sidecarData: Data?
        do {
            sidecarData = try pageEditSidecarData()
        } catch {
            lastError = "Could not prepare the annotations for the copy: \(error.localizedDescription)"
            return false
        }
        let hasMarks = !annotations.isEmpty || !bookmarks.isEmpty
        if hasMarks, let sidecarData {
            do {
                try sidecarData.write(to: destinationSidecar, options: .atomic)
            } catch {
                lastError = "Could not write the copy's annotation sidecar: \(error.localizedDescription)"
                return false
            }
        }
        pageEditBusy = true
        defer { pageEditBusy = false }
        do {
            let report = try await engine.saveEditedCopy(to: destination)
            endPageEditSession(deleteFiles: true)
            _ = open(url: destination)
            pageEditIsApplied = true
            let notes = hasMarks ? " · annotations saved beside it" : ""
            statusMessage =
                "Saved edited copy \(destination.lastPathComponent) · \(report.pageCount) page(s)"
                + " · the original is unchanged\(notes)"
            return true
        } catch {
            if hasMarks {
                try? FileManager.default.removeItem(at: destinationSidecar)
            }
            lastError = "Could not save the edited copy: \(error.localizedDescription)"
            statusMessage = "Could not save the edited copy"
            return false
        }
    }

    public func presentReplaceOriginalWithPageEditsConfirmation() {
        guard let session = pageEditSession else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Replace “\(session.originalURL.lastPathComponent)” with the page-edited version?"
        alert.informativeText =
            "This changes the file on disk. A byte-identical backup is written first; if the "
            + "backup cannot be written and verified, nothing is replaced. The reader's "
            + "annotations and bookmarks are remapped to the new page order."
        alert.addButton(withTitle: "Save and Replace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor [weak self] in
            await self?.replaceOriginalWithPageEdits()
        }
    }

    @discardableResult
    public func replaceOriginalWithPageEdits() async -> Bool {
        guard let session = pageEditSession, !pageEditBusy else { return false }
        let sidecarData: Data?
        do {
            sidecarData = try pageEditSidecarData()
        } catch {
            lastError = "Could not prepare the annotations for the replacement: \(error.localizedDescription)"
            return false
        }
        let hasMarks = !annotations.isEmpty || !bookmarks.isEmpty
        let hadSidecar = FileManager.default.fileExists(atPath: session.originalSidecarURL.path)
        let previousSidecar = hadSidecar ? try? Data(contentsOf: session.originalSidecarURL) : nil
        if hasMarks || hadSidecar, let sidecarData {
            do {
                try sidecarData.write(to: session.originalSidecarURL, options: .atomic)
            } catch {
                lastError = "Could not write the annotation sidecar; the original was left untouched: \(error.localizedDescription)"
                return false
            }
        }
        pageEditBusy = true
        defer { pageEditBusy = false }
        do {
            let report = try await engine.replaceOriginalWithPageEdits(original: session.originalURL)
            let backup = report.backupPath?.lastPathComponent ?? "none"
            endPageEditSession(deleteFiles: true)
            _ = open(url: session.originalURL)
            pageEditIsApplied = true
            statusMessage =
                "Applied page changes to \(session.originalURL.lastPathComponent)"
                + " · backup: \(backup)"
            FileHandle.standardError.write(Data((
                "aris-pages: replaced \(session.originalURL.path) · backup \(backup)\n"
            ).utf8))
            return true
        } catch {
            // The PDF was not replaced; put the sidecar back exactly as it was.
            if hadSidecar {
                if let previousSidecar {
                    try? previousSidecar.write(to: session.originalSidecarURL, options: .atomic)
                }
            } else {
                try? FileManager.default.removeItem(at: session.originalSidecarURL)
            }
            lastError = "Could not replace the original; it was left untouched: \(error.localizedDescription)"
            statusMessage = "Could not replace the original"
            return false
        }
    }

    public func presentDiscardPageEditsConfirmation() {
        guard pageEditSession != nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard the pending page changes?"
        alert.informativeText =
            "The working copy is closed and the original file stays exactly as it is. "
            + "Annotations and bookmarks added during this page-editing session are discarded too."
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        discardPageEdits()
    }

    public func discardPageEdits() {
        guard let session = pageEditSession else { return }
        endPageEditSession(deleteFiles: true)
        _ = open(url: session.originalURL)
        pageEditIsApplied = false
        statusMessage = "Discarded the page changes; \(session.originalURL.lastPathComponent) is unchanged"
    }

    public func undoPageEdit() {
        Task { @MainActor [weak self] in
            await self?.undoOrRedoPageEdit(redo: false)
        }
    }

    public func redoPageEdit() {
        Task { @MainActor [weak self] in
            await self?.undoOrRedoPageEdit(redo: true)
        }
    }

    private func undoOrRedoPageEdit(redo: Bool) async {
        guard var session = pageEditSession, !pageEditBusy else { return }
        let target = redo ? session.redo.last : session.undo.last
        guard let target, let current = pageEditSnapshot(label: redo ? "redo" : "undo") else { return }
        pageEditBusy = true
        defer { pageEditBusy = false }
        if redo {
            session.redo.removeLast()
            session.undo.append(current)
        } else {
            session.undo.removeLast()
            session.redo.append(current)
        }
        guard (try? loadPageEditRevision(
            at: target.revisionURL,
            title: session.title,
            sidecarURL: session.sidecarURL,
            annotations: target.annotations,
            bookmarks: target.bookmarks,
            slots: target.slots,
            currentPage: target.currentPage,
            selection: target.selection
        )) != nil else {
            lastError = "Could not reopen the revision for \(redo ? "redo" : "undo")"
            return
        }
        session.revisionURL = target.revisionURL
        session.revisionNumber = target.revisionNumber
        session.currentToOriginal = target.currentToOriginal
        session.operations = target.operations
        pageEditSession = session
        pageEditPendingOperations = session.operations
        pageEditIsApplied = false
        statusMessage = "\(redo ? "Redid" : "Undid") \(target.label) · \(session.operations.count) page change(s) still pending"
    }

    // MARK: Session plumbing

    private func pageEditSnapshot(label: String) -> PageEditSnapshot? {
        guard let session = pageEditSession, let url = document?.url else { return nil }
        return PageEditSnapshot(
            revisionURL: url,
            revisionNumber: session.revisionNumber,
            currentToOriginal: session.currentToOriginal,
            operations: session.operations,
            annotations: annotations,
            bookmarks: bookmarks,
            slots: annotationSidecarSlots,
            currentPage: currentPage,
            selection: pageSelection,
            label: label
        )
    }

    @discardableResult
    private func ensurePageEditSession() async -> Bool {
        if pageEditSession != nil { return true }
        guard document != nil, let url = document?.url else {
            lastError = "Open a document before editing pages"
            return false
        }
        guard preservedAnnotationEntryCount == 0 else {
            lastError =
                "This document's annotation sidecar contains entries written by a newer Lyra. "
                + "Their page numbers cannot be remapped safely, so page editing is disabled "
                + "rather than risking an annotation on the wrong page."
            return false
        }
        guard !annotationSaveInProgress else { return false }
        flushPendingWrites()
        guard !hasPendingAnnotationWrite else {
            lastError = "Could not flush the annotation that is still being edited; no page change was made"
            return false
        }
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("LyraPageEdits-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let originalRotations = try await engine.pageRotations()
            let pageCount = document?.pageCount ?? 0
            let session = PageEditSession(
                originalURL: url,
                originalSidecarURL: Self.sidecarURL(for: url),
                title: document?.title ?? url.deletingPathExtension().lastPathComponent,
                directory: directory,
                sidecarURL: directory.appendingPathComponent("annotations.json"),
                originalRotations: originalRotations,
                revisionURL: url,
                revisionNumber: 0,
                currentToOriginal: Array(0..<pageCount),
                operations: [],
                undo: [],
                redo: []
            )
            pageEditSession = session
            annotationsURL = session.sidecarURL
            let wrote = writeSidecar(
                annotations: annotations,
                bookmarks: bookmarks,
                slots: annotationSidecarSlots,
                trigger: "page-edit-session"
            )
            guard wrote else {
                pageEditSession = nil
                annotationsURL = session.originalSidecarURL
                try? FileManager.default.removeItem(at: directory)
                return false
            }
            pageEditPendingOperations = []
            pageEditIsApplied = false
            statusMessage = "Page editing: changes are staged in a working copy; the file on disk is unchanged"
            return true
        } catch {
            lastError = "Could not start the page-editing session: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    private func applyPageEdit(_ operation: PageEditOperation, label: String) async -> Bool {
        // A rotation changes the page's text-layer order (PDFium reports a 90° page's text in
        // rotated order). The sidecar addresses annotations by character range, so rotating a
        // page that has Lyra marks would silently move them onto different words. Embedded PDF
        // annotations are unaffected: they are page-space geometry and rotate with the page.
        let rotating: [Int]?
        switch operation {
        case .rotate(let pages, _), .setRotation(let pages, _): rotating = pages
        default: rotating = nil
        }
        if let rotating, let conflict = rotationConflict(on: rotating) {
            lastError = conflict
            statusMessage = "Rotation refused: the page has text-range annotations"
            return false
        }
        guard await ensurePageEditSession() else { return false }
        guard var session = pageEditSession, !pageEditBusy else { return false }
        guard let snapshot = pageEditSnapshot(label: label) else { return false }
        let nextNumber = session.revisionNumber + 1
        let nextURL = session.directory.appendingPathComponent("rev-\(nextNumber).pdf")
        pageEditBusy = true
        defer { pageEditBusy = false }
        do {
            let report = try await engine.applyPageOperation(operation, to: nextURL)
            let mappedAnnotations = Self.remap(annotations, with: report.pageMap)
            let mappedBookmarks = Self.remap(bookmarks, with: report.pageMap)
            let annotationIDs = Set(mappedAnnotations.map(\.id))
            let bookmarkIDs = Set(mappedBookmarks.map(\.id))
            let mappedSlots = annotationSidecarSlots.filter { slot in
                switch slot {
                case .annotation(let id): return annotationIDs.contains(id)
                case .bookmark(let id): return bookmarkIDs.contains(id)
                case .opaque: return true
                }
            }
            var mapping = [Int](repeating: -1, count: Int(report.pageCount))
            for (old, new) in report.pageMap.enumerated() {
                guard let new, new >= 0, new < mapping.count else { continue }
                mapping[new] = old < session.currentToOriginal.count ? session.currentToOriginal[old] : -1
            }
            let previousPage = min(max(currentPage - 1, 0), max(report.pageMap.count - 1, 0))
            var newPage = report.insertedPage
                ?? report.pageMap[previousPage]
                ?? min(previousPage, max(Int(report.pageCount) - 1, 0))
            if let inserted = report.insertedPage {
                newPage = inserted
            }
            var newSelection = Set<Int>()
            for selected in pageSelection {
                if selected < report.pageMap.count, let mapped = report.pageMap[selected] {
                    newSelection.insert(mapped)
                }
            }
            if let inserted = report.insertedPage {
                newSelection = [inserted]
                pageSelectionAnchor = inserted
            }

            guard (try? loadPageEditRevision(
                at: nextURL,
                title: session.title,
                sidecarURL: session.sidecarURL,
                annotations: mappedAnnotations,
                bookmarks: mappedBookmarks,
                slots: mappedSlots,
                currentPage: newPage + 1,
                selection: newSelection
            )) != nil else {
                lastError = "The page change was written, but the revision could not be reopened; the original is unchanged"
                return false
            }
            session.revisionURL = nextURL
            session.revisionNumber = nextNumber
            session.currentToOriginal = mapping
            session.operations.append(label)
            session.undo.append(snapshot)
            session.redo.removeAll()
            pageEditSession = session
            pageEditPendingOperations = session.operations
            pageEditIsApplied = false
            statusMessage =
                "\(label) · \(Self.annotationRule(for: operation)) · pending "
                + "(the file on disk is unchanged)"
            FileHandle.standardError.write(Data((
                "aris-pages: \(label) · revision \(nextNumber) · "
                + "\(session.operations.count) pending change(s)\n"
            ).utf8))
            return true
        } catch {
            lastError = "Page change failed; nothing was written: \(error.localizedDescription)"
            statusMessage = "Page change failed"
            // A failed operation may have created a partial revision file; it is never referenced
            // by the session, so remove it best-effort.
            try? FileManager.default.removeItem(at: nextURL)
            return false
        }
    }

    private func loadPageEditRevision(
        at url: URL,
        title: String,
        sidecarURL: URL,
        annotations newAnnotations: [Annotation],
        bookmarks newBookmarks: [Bookmark],
        slots newSlots: [AnnotationSidecar.Slot],
        currentPage newCurrentPage: Int,
        selection newSelection: Set<Int>
    ) throws {
        flushPendingWrites()
        guard !hasPendingAnnotationWrite else {
            throw NSError(
                domain: "Lyra",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "an annotation is still being edited"]
            )
        }
        let previousDocumentURL = document?.url
        resetDocumentState()
        var loaded = try engine.openDocument(at: url)
        loaded.title = title
        document = loaded
        annotationsURL = sidecarURL
        annotationWritesBlockedReason = nil
        preservedAnnotationEntryCount = 0
        annotations = newAnnotations
        bookmarks = newBookmarks
        annotationSidecarSlots = newSlots
        pageSelection = newSelection
        pageSelectionAnchor = newSelection.first
        currentPage = min(max(1, newCurrentPage), max(loaded.pageCount, 1))
        invalidateTiles()
        scrollYPt = engine.pageTopPt(currentPage - 1, gapPt: pageGapPt, layout: layoutMode)
        reloadVisiblePages()
        _ = writeSidecar(
            annotations: newAnnotations,
            bookmarks: newBookmarks,
            slots: newSlots,
            trigger: "page-edit-revision"
        )
        loadThumbnails()
        loadDocumentAnnotations()
        loadOutline()
        loadReferences()
        loadFigures()
        loadMetadata()
        // A page-editing session can create one working revision per command. Only the current
        // one is reachable after this load, so the previous handle is closed here rather than
        // accumulating every intermediate revision in the engine for the life of the session.
        if let previousDocumentURL, previousDocumentURL != loaded.url {
            engine.closeDocument(at: previousDocumentURL)
        }
    }

    private func endPageEditSession(deleteFiles: Bool) {
        let directory = pageEditSession?.directory
        let revisionURL = pageEditSession?.revisionURL
        let originalURL = pageEditSession?.originalURL
        pageEditSession = nil
        pageEditPendingOperations = []
        pageEditIsApplied = false
        if let revisionURL, revisionURL != originalURL {
            engine.closeDocument(at: revisionURL)
        }
        if deleteFiles, let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func pageEditSidecarData() throws -> Data? {
        if annotations.isEmpty && bookmarks.isEmpty && annotationSidecarSlots.isEmpty {
            return nil
        }
        return try AnnotationSidecar.encode(
            annotations: annotations,
            bookmarks: bookmarks,
            slots: annotationSidecarSlots
        )
    }

    /// Why rotating `pages` would invalidate Lyra's own marks, or nil when it is safe.
    ///
    /// Sidecar annotations address character ranges in the page's text layer, and a rotated
    /// page's text layer is reported in a different order. Rotating the page would not move the
    /// highlight with the words; it would leave the same offsets pointing at different text.
    /// Annotations already embedded in the PDF are page-space geometry and rotate correctly, so
    /// only entries this app owns are a reason to refuse.
    private func rotationConflict(on pages: [Int]) -> String? {
        let marked = Set(annotations.filter { pages.contains($0.page) }.map(\.page))
            .union(bookmarks.filter { pages.contains($0.page) }.map(\.page))
            .sorted()
        guard !marked.isEmpty else { return nil }
        return "Page \(Self.pageList(marked)) has Lyra annotations or bookmarks stored as "
            + "text positions. Rotating the page reorders its text layer, so those marks would "
            + "no longer point at the same words. The rotation was not applied. Annotations "
            + "already saved inside the PDF rotate with the page."
    }

    /// One sentence stating what happened to the reader's marks, shown with the pending action.
    private static func annotationRule(for operation: PageEditOperation) -> String {
        switch operation {
        case .move:
            return "annotations and bookmarks moved with their pages"
        case .delete:
            return "marks on deleted pages were removed; Undo restores them"
        case .insertBlank:
            return "the blank page carries no annotations"
        case .rotate, .setRotation:
            return "marks stay on their pages"
        }
    }

    private static func remap(_ annotations: [Annotation], with pageMap: [Int?]) -> [Annotation] {
        annotations.compactMap { annotation in
            guard annotation.page >= 0, annotation.page < pageMap.count,
                  let page = pageMap[annotation.page] else { return nil }
            var copy = annotation
            copy.page = page
            return copy
        }
    }

    private static func remap(_ bookmarks: [Bookmark], with pageMap: [Int?]) -> [Bookmark] {
        bookmarks.compactMap { bookmark in
            guard bookmark.page >= 0, bookmark.page < pageMap.count,
                  let page = pageMap[bookmark.page] else { return nil }
            var copy = bookmark
            copy.page = page
            return copy
        }
    }

    private static func pageList(_ pages: [Int]) -> String {
        guard let first = pages.first, let last = pages.last else { return "no pages" }
        if pages.count == 1 { return "page \(first + 1)" }
        if last - first + 1 == pages.count {
            return first == last ? "page \(first + 1)" : "pages \(first + 1)–\(last + 1)"
        }
        return "pages " + pages.map { String($0 + 1) }.joined(separator: ", ")
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
        bookmarks = []
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

        let top = engine.pageTopPt(hit.page, gapPt: pageGapPt, layout: layoutMode)
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

    /// Whether the document is longer than the viewport: there is something to scroll, so there
    /// is a scroller to show and to grab.
    public var hasScrollableContent: Bool {
        contentHeightPt > viewportHeightContentPt
    }

    /// Whether the indicator accepts pointer input.
    ///
    /// This is the document's own fact, deliberately **not** `isScrolling`. The indicator used to
    /// be hit-testable only while a scroll was in flight (`showsScrollIndicator`, which folded in
    /// `isScrolling`), so a reader who reached for the bar between scrolls had nothing under the
    /// mouse to grab. A scrollable document now always has a hit-testable thumb; only the fade
    /// depends on use, and a document that fits has neither.
    public var scrollIndicatorIsInteractive: Bool {
        hasScrollableContent
    }

    /// Whether the indicator is drawn. Reading is quiet: it fades in while a scroll is in flight,
    /// while the pointer is in its lane, or while the thumb is held, and fades out when idle.
    public var showsScrollIndicator: Bool {
        hasScrollableContent && (isScrolling || isScrollIndicatorHovered || isDraggingScrollIndicator)
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
    ///
    /// A click ends whatever was selected, wherever it lands and whether or not it resolves a
    /// target. That is what a click means everywhere else on the platform, and the alternative —
    /// keeping the selection alive under the pointer — leaves the reader with no way to drop it
    /// except by selecting something else. A press that moved past the canvas' slop never reaches
    /// here: that gesture is a drag, and a drag selects (see `MetalCanvasView.clickSlopPt`).
    public func endPointerInteraction(at point: CGPoint, wasClick: Bool) {
        if let original = moveOriginalAnnotation, let start = moveStartPagePoint {
            finishAnnotationMove(original: original, start: start, at: point, wasClick: wasClick)
            return
        }
        guard wasClick else {
            extendSelection(to: point)
            return
        }
        // Before the target is resolved, not after: a click that opens a citation or a figure
        // preview used to leave the old selection highlighted behind the panel, which reads as
        // "the click did not take". A click elsewhere also drops a selected mark; a click *on*
        // a mark returned above, before this point, so it keeps its selection.
        clearSelection()
        clearAnnotationSelection()
        closeDocumentNote()
        previewEpoch &+= 1

        // A visible inline-comment label wins over text underneath it. Elsewhere, preserve
        // navigation priority: the PDF's link, a citation, a caption mention, then a note glyph.
        _ = openInlineNote(at: point)
            || followLink(at: point)
            || openCitation(at: point)
            || openFigureMention(at: point)
            || openDocumentNote(at: point)
    }

    /// Commits or cancels the drag begun by `beginSelection`.
    ///
    /// A drag that moved the mark writes the sidecar once and records a single `.replaced`
    /// operation; a click (or a drag below one point) only selects it. A failed write puts the
    /// original geometry back, so the page never shows a position that is not on disk.
    private func finishAnnotationMove(original: Annotation, start: CGPoint,
                                      at point: CGPoint, wasClick: Bool) {
        defer {
            moveOriginalAnnotation = nil
            moveStartPagePoint = nil
        }
        guard let placement = visiblePagePlacements.first(where: { $0.index == original.page })
        else { return }
        let current = CGPoint(x: point.x - placement.leftPt, y: point.y - placement.topPt)
        let dx = current.x - start.x
        let dy = current.y - start.y
        if wasClick || hypot(dx, dy) < 0.5 {
            if wasClick { selectedAnnotationID = original.id }
            return
        }
        guard let moved = annotations.first(where: { $0.id == original.id }),
              moved.hasValidGeometry else { return }
        guard saveAnnotations(annotations, trigger: "move-\(original.kind.rawValue)") else {
            if let index = annotations.firstIndex(where: { $0.id == original.id }) {
                var restored = annotations
                restored[index] = original
                annotations = restored
            }
            selectedAnnotationID = original.id
            return
        }
        undoStack.append(.replaced(before: original, after: moved))
        redoStack.removeAll()
        selectedAnnotationID = original.id
        refreshSelectionOverlay()
        statusMessage = "Moved \(moved.kind.rawValue) annotation"
    }

    private func showDocumentNote(_ annotation: DocumentAnnotation) {
        selectedDocumentAnnotationID = annotation.id
        openDocumentNoteID = annotation.id
        let text = (annotation.contents ?? "").split(whereSeparator: \.isNewline)
            .first.map(String.init) ?? ""
        statusMessage = text.isEmpty
            ? "Page \(annotation.page + 1): a note with no text"
            : "Page \(annotation.page + 1): \(text.prefix(120))"
    }

    @discardableResult
    public func openInlineNote(at point: CGPoint) -> Bool {
        for marker in inlineNoteMarkers.reversed() {
            guard let placement = visiblePagePlacements.first(where: { $0.index == marker.page }) else { continue }
            let local = CGPoint(x: point.x - placement.leftPt, y: point.y - placement.topPt)
            guard marker.rect.contains(local) else { continue }
            showDocumentNote(documentAnnotations[marker.annotationIndex])
            return true
        }
        return false
    }

    /// Expands a fixed-size paper beside the clicked glyph without moving the document.
    @discardableResult
    public func openDocumentNote(at point: CGPoint) -> Bool {
        for placement in visiblePagePlacements {
            let pageRect = CGRect(
                x: placement.leftPt,
                y: placement.topPt,
                width: placement.widthPt,
                height: placement.heightPt
            )
            guard pageRect.contains(point) else { continue }
            let local = CGPoint(x: point.x - placement.leftPt, y: point.y - placement.topPt)

            // Backwards, so the note drawn last — the one the reader can see on top — wins.
            for annotation in documentAnnotations.reversed()
            where annotation.page == placement.index && annotation.visible {
                guard annotation.drawing == .noteIcon || annotation.drawing == .freeText,
                      let box = annotation.boxes.first
                else { continue }
                // A note's `/Rect` is its icon (20-26 pt in the review corpus), and a pointer is
                // worth a point or two of slack on each side: the alternative is a mark that is
                // drawn but cannot be hit.
                let hit = CGRect(x: box.xPt, y: box.yPt, width: box.widthPt, height: box.heightPt)
                    .insetBy(dx: -Self.noteClickSlackPt, dy: -Self.noteClickSlackPt)
                guard hit.contains(local) else { continue }

                showDocumentNote(annotation)
                FileHandle.standardError.write(
                    Data("aris-annot: opened note \(annotation.id) (\(annotation.drawing.rawValue)) on page \(annotation.page + 1)\n".utf8)
                )
                return true
            }
        }
        return false
    }

    /// How far outside a note's own box a click still counts as hitting it, in points.
    ///
    /// The same 3 pt the canvas uses to tell a click from a drag (`MetalCanvasView.clickSlopPt`),
    /// for the same reason: a pointer is not a pixel, and the smallest note icon in the review
    /// corpus is 20 pt across.
    static let noteClickSlackPt: CGFloat = 3

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
        guard !figuresLoadCompleted else { return }
        figuresLoadCompleted = true
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

    /// Loads the annotations the document itself carries (once per open document).
    ///
    /// Document-wide: the Rust side scans every page and caches the result for as long as the
    /// file is open, and the sidebar wants the notes from the whole document, not just the page
    /// on screen. A failure is reported rather than swallowed — "the file has no annotations" and
    /// "the annotations could not be read" look identical on an empty canvas otherwise.
    private func loadDocumentAnnotations() {
        guard !documentAnnotationsLoadCompleted, !documentAnnotationsLoading else { return }
        documentAnnotationsLoadCompleted = true
        documentAnnotationsLoading = true
        documentAnnotationsError = nil
        let epoch = documentEpoch
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard epoch == self.documentEpoch else { return }
            defer { if epoch == self.documentEpoch { self.documentAnnotationsLoading = false } }
            do {
                let found = try await self.engine.annotations()
                guard epoch == self.documentEpoch else { return }
                self.documentAnnotations = found
                self.reconcileAnnotationsAlreadySaved(found)
                self.reloadVisiblePages()
                FileHandle.standardError.write(
                    Data("aris-pdf-annotations: \(found.count) in the file, \(self.documentNotes.count) note(s)\n".utf8)
                )
            } catch {
                guard epoch == self.documentEpoch else { return }
                self.documentAnnotationsError = String(describing: error)
                self.statusMessage = "Could not read the annotations in this PDF"
                FileHandle.standardError.write(
                    Data("aris-pdf-annotations: read failed: \(error)\n".utf8)
                )
            }
        }
    }

    /// Fetches the citations of every visible page, so a click resolves immediately.
    private func loadCitations() {
        for placement in visiblePagePlacements where citationsByPage[placement.index] == nil {
            startCitationLoad(page: placement.index)
        }
    }

    /// Starts — or joins — the fetch of one page's citations, and hands back the task that
    /// carries it.
    ///
    /// A page's citations are the slowest of the click targets to read: the first call pays the
    /// document-wide reference scan, and it is queued behind the page rasters and text layers on
    /// the engine's serial queue. Returning the task instead of only marking the page "in flight"
    /// is what lets a click made in the meantime wait for the fetch that is already on its way
    /// rather than starting a second one (or, before, being dropped).
    @discardableResult
    private func startCitationLoad(page: Int) -> Task<[Citation]?, Never> {
        if let started = citationLoads[page] { return started }
        let epoch = documentEpoch
        let task: Task<[Citation]?, Never> = Task { @MainActor [weak self] in
            guard let self, epoch == self.documentEpoch else { return nil }
            let found = try? await self.engine.citations(page)
            guard epoch == self.documentEpoch else { return nil }
            self.citationLoads[page] = nil
            guard let found else { return nil }
            self.citationsByPage[page] = found
            return found
        }
        citationLoads[page] = task
        return task
    }

    /// Loads the reference list once (it never changes for an open document).
    private func loadReferences() {
        guard !referencesLoadCompleted else { return }
        referencesLoadCompleted = true
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

    /// Loads the recognised metadata once per open document.
    ///
    /// The engine reads XMP, `/Info` and page one, then caches the answer for the lifetime of the
    /// document. An empty field stays empty: this method never falls back to the filename or the
    /// file's creation date to make the panel look complete.
    private func loadMetadata() {
        guard document != nil, !metadataLoadCompleted else { return }
        metadataLoadCompleted = true
        metadataLoading = true
        metadataError = nil
        let epoch = documentEpoch
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard epoch == self.documentEpoch else { return }
            defer { if epoch == self.documentEpoch { self.metadataLoading = false } }
            do {
                let found = try await self.engine.metadata()
                guard epoch == self.documentEpoch else { return }
                self.metadata = found
                self.metadataDraft = MetadataDraft(metadata: found)
                self.metadataBibtex = found.bibtex
                FileHandle.standardError.write(Data((
                    "aris-metadata: title=\(found.title.source.label.lowercased()) "
                    + "authors=\(found.authors.source.label.lowercased()) "
                    + "venue=\(found.venue.source.label.lowercased()) "
                    + "year=\(found.year.source.label.lowercased()) "
                    + "doi=\(found.doi.source.label.lowercased()) "
                    + "arxiv=\(found.arxivID.source.label.lowercased())\n"
                ).utf8))
            } catch {
                guard epoch == self.documentEpoch else { return }
                self.metadata = nil
                self.metadataDraft = .empty
                self.metadataBibtex = ""
                self.metadataError = String(describing: error)
                self.statusMessage = "Could not read the document metadata"
                FileHandle.standardError.write(
                    Data("aris-metadata: read failed: \(error)\n".utf8)
                )
            }
        }
    }

    /// The visible source badge for a field. Edited values say "Edited", not the old source.
    public func metadataSource(for key: MetadataFieldKey) -> MetadataFieldSource {
        metadata?.field(key).source ?? .absent
    }

    public func metadataIsEmpty() -> Bool {
        metadata?.isEmpty ?? true
    }

    /// Applies a correction from the panel and regenerates the entry immediately.
    ///
    /// The field's provenance becomes `edited`: the reader's value is no longer a guess and no
    /// longer the file's claim, and the badge must say so.
    public func updateMetadata(_ key: MetadataFieldKey, text: String) {
        guard document != nil else { return }
        var draft = metadataDraft
        draft.setText(text, for: key)
        if var fields = metadata {
            switch key {
            case .authors:
                fields.authors.markEdited(values: metadataDraft.authors)
            case .title:
                fields.title.markEdited(value: metadataDraft.title)
            case .venue:
                fields.venue.markEdited(value: metadataDraft.venue)
            case .year:
                fields.year.markEdited(value: metadataDraft.year)
            case .doi:
                fields.doi.markEdited(value: metadataDraft.doi)
            case .arxivID:
                fields.arxivID.markEdited(value: metadataDraft.arxivID)
            }
            metadata = fields
        }
        let generated = engine.generateBibtex(draft)
        draft.bibtex = generated
        metadataDraft = draft
        metadataBibtex = generated
    }

    /// Copies **the panel's** generated entry. Nothing regenerates here: the payload is the
    /// string on screen, which is what the checks compare.
    public func copyMetadataBibtex() {
        guard document != nil, !metadataBibtex.isEmpty else {
            statusMessage = "There is no BibTeX to copy"
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(metadataBibtex, forType: .string)
        statusMessage = "Copied \(metadataBibtex.count) characters of BibTeX"
    }

    /// Writes the same string the panel shows, for the menu's Save command and the tests.
    @discardableResult
    public func saveMetadataBibtex(to url: URL) -> Bool {
        guard !metadataBibtex.isEmpty else {
            lastError = "There is no BibTeX to save"
            return false
        }
        do {
            try metadataBibtex.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Saved BibTeX to \(url.lastPathComponent)"
            return true
        } catch {
            lastError = "Could not save BibTeX: \(error.localizedDescription)"
            statusMessage = "Could not save BibTeX"
            return false
        }
    }

    /// The name to offer in the Save panel: the entry key, so a folder of PDFs and a folder of
    /// `.bib` files correspond one to one.
    public var suggestedBibtexFilename: String {
        let firstLine = metadataBibtex.split(separator: "\n").first.map(String.init) ?? ""
        var key = "reference"
        if let open = firstLine.firstIndex(of: "{"),
           let comma = firstLine[open...].firstIndex(of: ",")
        {
            let candidate = String(firstLine[firstLine.index(after: open)..<comma])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty { key = candidate }
        }
        let safe = key.map { character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "_"
        }
        return "\(String(safe)).bib"
    }

    public func presentSaveBibtexPanel() {
        guard document != nil else { return }
        let panel = NSSavePanel()
        panel.title = "Save BibTeX"
        panel.nameFieldStringValue = suggestedBibtexFilename
        if let type = UTType(filenameExtension: "bib") {
            panel.allowedContentTypes = [type]
        }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.saveMetadataBibtex(to: url)
        }
    }

    public var canCopyMetadataBibtex: Bool {
        document != nil && metadata != nil && !metadataBibtex.isEmpty
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
            guard pageRect.contains(point) else { continue }

            let local = CGPoint(x: point.x - placement.leftPt, y: point.y - placement.topPt)
            guard let citations = citationsByPage[placement.index] else {
                // The page's citations are still being fetched — their first read runs the
                // document-wide reference scan, queued behind this page's rasters and text layer,
                // so a click can easily beat them. The pointer has already said which page it
                // meant: resolve when the data lands instead of dropping the click. Nothing is
                // known synchronously, so report "not handled" and let the panel appear a moment
                // later, exactly as the figure-mention path does.
                resolveCitation(on: placement, at: local)
                return false
            }
            guard let citation = citation(at: local, in: citations) else { continue }
            previewCitation(citation, on: placement)
            return true
        }
        return false
    }

    /// The citation whose box contains a page-local point, if any.
    private func citation(at local: CGPoint, in citations: [Citation]) -> Citation? {
        citations.first { citation in
            CGRect(
                x: citation.xPt,
                y: citation.yPt,
                width: citation.widthPt,
                height: citation.heightPt
            ).contains(local)
        }
    }

    /// Opens the reference panel for a citation the reader clicked.
    ///
    /// Resolution lives in Rust: exact label match, then position for a numeric citation against
    /// an unnumbered list, once per label so a group resolves whole. The citation's page is part
    /// of the call so a document with several reference lists attributes it to the list its
    /// section cites. The shell only draws the result.
    private func previewCitation(_ citation: Citation, on placement: PagePlacement) {
        let labels = citation.labels
        // A long group can wrap in the text layer; the title and the log stay one line.
        let written = citation.text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let epoch = documentEpoch
        let request = previewEpoch
        // Read the anchor before the await: resolution can take a moment, and the reader
        // may have scrolled by the time it lands, but the panel belongs where they clicked.
        let anchor = viewRect(
            local: CGRect(x: citation.xPt, y: citation.yPt,
                          width: citation.widthPt, height: citation.heightPt),
            on: placement
        )
        Task { @MainActor [weak self] in
            guard let self, epoch == self.documentEpoch, request == self.previewEpoch else { return }
            let resolved = (try? await self.engine.resolveCitations(
                labels: labels,
                page: placement.index
            )) ?? []
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
                kind: .reference,
                anchor: anchor,
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
    }

    /// Opens the citation under a click that arrived before the page's citations were fetched.
    ///
    /// The fetch is the one `loadCitations` already started for this page whenever it is still on
    /// its way, so a click costs no second read of the page. A newer click, or a document switch,
    /// supersedes this lookup.
    private func resolveCitation(on placement: PagePlacement, at local: CGPoint) {
        let page = placement.index
        let epoch = documentEpoch
        let request = previewEpoch
        Task { @MainActor [weak self] in
            guard let self else { return }
            let citations: [Citation]
            if let cached = self.citationsByPage[page] {
                citations = cached
            } else {
                citations = await self.startCitationLoad(page: page).value ?? []
            }
            guard epoch == self.documentEpoch, request == self.previewEpoch else { return }
            guard let citation = self.citation(at: local, in: citations) else { return }
            // The placement is the one the reader clicked in even if the view has scrolled since:
            // the panel belongs where they clicked, the same rule `previewCitation` follows.
            self.previewCitation(citation, on: placement)
        }
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
            return openFigure(mention, from: placement.index,
                              anchor: anchor(of: mention, on: placement))
        }
        return false
    }

    /// A caption mention's box in canvas view space, which is what the panel opens next to.
    private func anchor(of mention: CaptionMention, on placement: PagePlacement) -> CGRect {
        viewRect(local: CGRect(x: mention.xPt, y: mention.yPt,
                               width: mention.widthPt, height: mention.heightPt),
                 on: placement)
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
    private func openFigure(_ mention: CaptionMention, from page: Int, anchor mentionAnchor: CGRect?) -> Bool {
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
            kind: .figure,
            anchor: mentionAnchor,
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
            guard let placement = self.visiblePagePlacements.first(where: { $0.index == page })
            else { return }
            self.openFigure(mention, from: page, anchor: self.anchor(of: mention, on: placement))
        }
    }

    /// The link whose box contains a content-space point, if any, with the page it is on.
    ///
    /// Links are loaded per visible page in the background (`loadLinks`); until a page's links
    /// have arrived, a right-click on that page has no link to offer. That is the same latency
    /// a click already has, rather than a second source of truth.
    private func linkHit(at point: CGPoint) -> (link: DocumentLink, placement: PagePlacement)? {
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
                return (link, placement)
            }
        }
        return nil
    }

    /// The link under a content-space point, **without following it**.
    ///
    /// This is the query a context menu asks before it offers "Open Link": an item that appears
    /// where there is no link would be a menu entry that does nothing. Following it stays
    /// ``followLink(at:)``'s job.
    public func link(at point: CGPoint) -> DocumentLink? {
        linkHit(at: point)?.link
    }

    /// The index of the page under a content-space point.
    ///
    /// The page-level context-menu commands act on a page, not on a character or a link, and the
    /// reader's right-click has already said which one they mean. Gaps between pages answer `nil`,
    /// so a right-click in the gap offers no page operation at all.
    public func pageIndex(at point: CGPoint) -> Int? {
        visiblePagePlacements.first { placement in
            CGRect(
                x: placement.leftPt,
                y: placement.topPt,
                width: placement.widthPt,
                height: placement.heightPt
            ).contains(point)
        }?.index
    }

    /// Follows the link under a content-space point, if there is one.
    ///
    /// Called on a *click* (no drag): dragging selects text, clicking follows links — the
    /// convention PDF readers share.
    @discardableResult
    public func followLink(at point: CGPoint) -> Bool {
        guard let (link, placement) = linkHit(at: point) else { return false }
        let box = CGRect(x: link.xPt, y: link.yPt, width: link.widthPt, height: link.heightPt)

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
                kind: link.region == nil ? .page : .figure,
                anchor: viewRect(local: box, on: placement),
                region: link.region
            )
            statusMessage = "Previewing page \(page + 1)"
            return true
        }
        return false
    }

    // MARK: - Tabs

    /// Opens a document in a new tab and switches to it.
    ///
    /// The tab is only added when the document actually opens, so a failure leaves the tabs and
    /// the document on screen exactly as they were.
    @discardableResult
    public func newTab(url: URL) -> Bool {
        openDocumentInTab(url)
    }

    /// Opens `url` as a new tab, makes it the active one, and reports whether it opened.
    ///
    /// This is the entry point for documents the app did not ask for itself: a PDF dropped on the
    /// Dock icon, Finder's “Open With”, `open -a Lyra …`, or a file dropped on the canvas. Failure
    /// is reported by returning `false` *after* `open(url:)` has set `lastError`, so the window can
    /// show the reader what happened.
    @discardableResult
    public func openDocumentInTab(_ url: URL) -> Bool {
        saveActiveTabPosition()
        guard open(url: url) else { return false }
        let tab = OpenTab(url: url, title: url.deletingPathExtension().lastPathComponent,
                          scrollYPt: scrollYPt)
        tabs.append(tab)
        activeTabIndex = tabs.count - 1
        isRestoringDocument = false
        trimRetainedDocuments()
        return true
    }

    /// Opens several documents at once — one tab each — and returns how many of them opened.
    ///
    /// This is the shell's multi-document policy: every document the system delivers is kept as
    /// its own tab, in arrival order, with the last one on screen. There is one engine and one
    /// window scene, so a window per document is not something the shell can support, and keeping
    /// only the last would silently discard the rest. See `DocumentOpenCoordinator`.
    @discardableResult
    public func openDocuments(_ urls: [URL]) -> Int {
        var opened = 0
        for url in urls {
            if openDocumentInTab(url) { opened += 1 }
        }
        return opened
    }

    /// Switches to a tab.
    ///
    /// A tab whose document is still retained is activated without reading the file: its engine
    /// handle, tile cache, page rasters and derived index are already in memory, so the page on
    /// screen does not go blank and the scroll offset comes back exactly. A tab whose document was
    /// evicted beyond `maximumRetainedDocuments` is reloaded through the existing `open` path,
    /// with a placeholder shown until its first raster arrives.
    public func selectTab(_ index: Int) {
        guard tabs.indices.contains(index), index != activeTabIndex else { return }
        saveActiveTabPosition()
        flushPendingWrites()
        let previousID = activeTabIndex.flatMap { tabs.indices.contains($0) ? tabs[$0].id : nil }
        if let previousID, document != nil {
            retainedTabs[previousID] = RetainedTab(
                tabID: previousID,
                url: tabs.first(where: { $0.id == previousID })?.url ?? document?.url
                    ?? URL(fileURLWithPath: "/"),
                state: captureDocumentState(),
                lastUsed: nextUseTick()
            )
        }

        let target = tabs[index]
        if let cached = retainedTabs.removeValue(forKey: target.id),
           engine.activateDocument(at: cached.state.document.url ?? cached.url) {
            activeTabIndex = index
            restoreDocumentState(cached.state)
            restoreDerivedDataIfNeeded()
            reloadVisiblePages()
            trimRetainedDocuments()
            return
        }

        // No retained state: this tab's document was evicted (or its activation failed). The
        // tab's saved offset is applied before the first raster request, and the placeholder
        // stays until the first page is available.
        isRestoringDocument = true
        guard loadDocument(url: target.url, restoringTabScroll: target.scrollYPt,
                           preservingPageEditSessionInSnapshot: true) else {
            isRestoringDocument = false
            // `loadDocument` leaves the previous live state untouched on failure; the snapshot
            // taken above would only duplicate it, so drop it.
            if let previousID { retainedTabs.removeValue(forKey: previousID) }
            return
        }
        activeTabIndex = index
        // `loadDocument` resets the document state (including this flag) before it renders.
        // Raise it again after the successful open so the placeholder covers the canvas until
        // the first reloaded raster arrives.
        isRestoringDocument = true
        restoreDerivedDataIfNeeded()
        trimRetainedDocuments()
    }

    public func closeTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        saveActiveTabPosition()
        let closing = tabs[index]
        if index != activeTabIndex {
            tabs.remove(at: index)
            if let active = activeTabIndex, index < active { activeTabIndex = active - 1 }
            if let retained = retainedTabs.removeValue(forKey: closing.id) {
                releaseEngineDocumentIfUnused(retained.state.document.url ?? retained.url)
            }
            return
        }

        tabs.remove(at: index)
        retainedTabs.removeValue(forKey: closing.id)
        let closingDocumentURL = document?.url
        activeTabIndex = nil
        // Flush first: while the page-edit session is still current, its sidecar path is the
        // working copy. Deleting the working directory before the flush would lose the note.
        resetDocumentState()
        endPageEditSession(deleteFiles: true)
        document = nil
        isRestoringDocument = false
        if let closingDocumentURL { releaseEngineDocumentIfUnused(closingDocumentURL) }
        guard !tabs.isEmpty else { return }
        let next = min(index, tabs.count - 1)
        let nextTab = tabs[next]
        if let cached = retainedTabs.removeValue(forKey: nextTab.id),
           engine.activateDocument(at: cached.state.document.url ?? cached.url) {
            activeTabIndex = next
            restoreDocumentState(cached.state)
            restoreDerivedDataIfNeeded()
            reloadVisiblePages()
            trimRetainedDocuments()
            return
        }
        isRestoringDocument = true
        if loadDocument(url: nextTab.url, restoringTabScroll: nextTab.scrollYPt) {
            activeTabIndex = next
            restoreDerivedDataIfNeeded()
        } else {
            isRestoringDocument = false
        }
        trimRetainedDocuments()
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

    // MARK: Tab document cache

    private func nextUseTick() -> UInt64 {
        useTick &+= 1
        return useTick
    }

    /// Snapshots the active tab before a new document replaces it. Only committed by the caller
    /// after the replacement succeeded, so a refused open does not disturb the cache.
    private func prepareActiveDocumentForReplacement() -> RetainedTab? {
        guard document != nil, let index = activeTabIndex, tabs.indices.contains(index) else {
            return nil
        }
        saveActiveTabPosition()
        flushPendingWrites()
        let tab = tabs[index]
        return RetainedTab(tabID: tab.id, url: tab.url,
                           state: captureDocumentState(), lastUsed: nextUseTick())
    }

    private func retain(_ tab: RetainedTab) {
        retainedTabs[tab.tabID] = tab
    }

    /// Everything document-specific, captured as one value. Transient tasks and epochs are not
    /// captured: on restore the epochs are bumped, which cancels every in-flight result that
    /// belonged to the document the reader left.
    private func captureDocumentState() -> TabDocumentState {
        TabDocumentState(
            document: document ?? LoadedDocument(title: "", pageCount: 0),
            currentPage: currentPage,
            scrollYPt: scrollYPt,
            contentHeightPt: contentHeightPt,
            contentWidthPt: contentWidthPt,
            statusMessage: statusMessage,
            pageSelection: pageSelection,
            pageSelectionAnchor: pageSelectionAnchor,
            pageEditSession: pageEditSession,
            pageEditPendingOperations: pageEditPendingOperations,
            pageEditIsApplied: pageEditIsApplied,
            selection: selection,
            selectionAnchor: selectionAnchor,
            searchHits: searchHits,
            currentHitIndex: currentHitIndex,
            tileCache: tileCache,
            pagePreviews: pagePreviews,
            pagePreviewScales: pagePreviewScales,
            desiredPreviewScale: desiredPreviewScale,
            failedPreviewPages: failedPreviewPages,
            failedTiles: failedTiles,
            usesScreenPageRasters: usesScreenPageRasters,
            screenPagePathNote: screenPagePathNote,
            screenPagePathSummary: screenPagePathSummary,
            lastScreenPagePathNote: lastScreenPagePathNote,
            hasReportedScreenPagePath: hasReportedScreenPagePath,
            textPages: textPages,
            canvasPages: canvasPages,
            canvasTiles: canvasTiles,
            visiblePagePlacements: visiblePagePlacements,
            linkCache: linkCache,
            citationsByPage: citationsByPage,
            captionMentionsByPage: captionMentionsByPage,
            references: references,
            referencesLoadCompleted: referencesLoadCompleted,
            figures: figures,
            figuresLoadCompleted: figuresLoadCompleted,
            metadata: metadata,
            metadataDraft: metadataDraft,
            metadataBibtex: metadataBibtex,
            metadataError: metadataError,
            metadataLoadCompleted: metadataLoadCompleted,
            documentAnnotations: documentAnnotations,
            documentAnnotationsError: documentAnnotationsError,
            documentAnnotationsLoadCompleted: documentAnnotationsLoadCompleted,
            outline: outline,
            outlineLoadCompleted: outlineLoadCompleted,
            thumbnails: thumbnails,
            annotations: annotations,
            bookmarks: bookmarks,
            preservedAnnotationEntryCount: preservedAnnotationEntryCount,
            annotationWriteCount: annotationWriteCount,
            lastAnnotationWriteReport: lastAnnotationWriteReport,
            interruptedAnnotationSaveNotice: interruptedAnnotationSaveNotice,
            lastSidecarBackupURL: lastSidecarBackupURL,
            annotationsURL: annotationsURL,
            annotationWritesBlockedReason: annotationWritesBlockedReason,
            annotationSidecarSlots: annotationSidecarSlots,
            selectedDocumentAnnotationID: selectedDocumentAnnotationID,
            openDocumentNoteID: openDocumentNoteID,
            annotationTextures: annotationTextures,
            noteGlyphTextures: noteGlyphTextures,
            undoStack: undoStack,
            redoStack: redoStack
        )
    }

    /// Puts a retained document's state back. The engine has already been told to make its
    /// document current (`RustEngine.activateDocument(at:)`), so no file is read here.
    private func restoreDocumentState(_ state: TabDocumentState) {
        documentEpoch &+= 1
        searchEpoch &+= 1
        renderEpoch &+= 1
        cancelScrollGlide()
        scrollIdleTask?.cancel()
        scrollIdleTask = nil
        positionSaveTask?.cancel()
        positionSaveTask = nil
        pendingPosition = nil
        noteFlushTask?.cancel()
        noteFlushTask = nil
        noteWindowSawKeystrokes = false
        closeReferencePreview()
        isRestoringDocument = false
        annotationSaveInProgress = false
        pageEditBusy = false
        documentAnnotationsLoading = false
        metadataLoading = false
        isSearching = false
        hasPendingAnnotationWrite = false

        document = state.document
        currentPage = state.currentPage
        scrollYPt = state.scrollYPt
        contentHeightPt = state.contentHeightPt
        contentWidthPt = state.contentWidthPt
        statusMessage = state.statusMessage
        pageSelection = state.pageSelection
        pageSelectionAnchor = state.pageSelectionAnchor
        pageEditSession = state.pageEditSession
        pageEditPendingOperations = state.pageEditPendingOperations
        pageEditIsApplied = state.pageEditIsApplied
        selection = state.selection
        selectionAnchor = state.selectionAnchor
        searchHits = state.searchHits
        currentHitIndex = state.currentHitIndex
        tileCache = state.tileCache
        pagePreviews = state.pagePreviews
        pagePreviewScales = state.pagePreviewScales
        desiredPreviewScale = state.desiredPreviewScale
        failedPreviewPages = state.failedPreviewPages
        failedTiles = state.failedTiles
        usesScreenPageRasters = state.usesScreenPageRasters
        screenPagePathNote = state.screenPagePathNote
        screenPagePathSummary = state.screenPagePathSummary
        lastScreenPagePathNote = state.lastScreenPagePathNote
        hasReportedScreenPagePath = state.hasReportedScreenPagePath
        textPages = state.textPages
        canvasPages = state.canvasPages
        canvasTiles = state.canvasTiles
        visiblePagePlacements = state.visiblePagePlacements
        linkCache = state.linkCache
        citationsByPage = state.citationsByPage
        captionMentionsByPage = state.captionMentionsByPage
        references = state.references
        referencesLoadCompleted = state.referencesLoadCompleted
        figures = state.figures
        figuresLoadCompleted = state.figuresLoadCompleted
        metadata = state.metadata
        metadataDraft = state.metadataDraft
        metadataBibtex = state.metadataBibtex
        metadataError = state.metadataError
        metadataLoadCompleted = state.metadataLoadCompleted
        documentAnnotations = state.documentAnnotations
        documentAnnotationsError = state.documentAnnotationsError
        documentAnnotationsLoadCompleted = state.documentAnnotationsLoadCompleted
        outline = state.outline
        outlineLoadCompleted = state.outlineLoadCompleted
        thumbnails = state.thumbnails
        annotations = state.annotations
        bookmarks = state.bookmarks
        preservedAnnotationEntryCount = state.preservedAnnotationEntryCount
        annotationWriteCount = state.annotationWriteCount
        lastAnnotationWriteReport = state.lastAnnotationWriteReport
        interruptedAnnotationSaveNotice = state.interruptedAnnotationSaveNotice
        lastSidecarBackupURL = state.lastSidecarBackupURL
        annotationsURL = state.annotationsURL
        annotationWritesBlockedReason = state.annotationWritesBlockedReason
        annotationSidecarSlots = state.annotationSidecarSlots
        selectedDocumentAnnotationID = state.selectedDocumentAnnotationID
        openDocumentNoteID = state.openDocumentNoteID
        annotationTextures = state.annotationTextures
        noteGlyphTextures = state.noteGlyphTextures
        undoStack = state.undoStack
        redoStack = state.redoStack

        // Nothing that was in flight for the previous document may land in this one.
        tilesInFlight.removeAll()
        pendingTiles = []
        wantedTiles = []
        textPagesInFlight.removeAll()
        linksInFlight.removeAll()
        citationLoads = [:]
        captionMentionsInFlight.removeAll()
        thumbnailsInFlight.removeAll()
        pendingThumbnails = []
        desiredPreviewPages = []
        pagePreviewInFlight = nil
        isScrolling = false
        isScrollIndicatorHovered = false
        isDraggingScrollIndicator = false
    }

    /// Loads whatever a restored snapshot did not have yet. A completed empty result keeps its
    /// flag, so a document with no figures is not re-indexed on every switch.
    private func restoreDerivedDataIfNeeded() {
        if !outlineLoadCompleted { loadOutline() }
        if thumbnails.isEmpty { loadThumbnails() }
        if !referencesLoadCompleted { loadReferences() }
        if !figuresLoadCompleted { loadFigures() }
        if !metadataLoadCompleted { loadMetadata() }
        if !documentAnnotationsLoadCompleted { loadDocumentAnnotations() }
    }

    /// Evicts least-recently-used retained documents beyond the keep-limit. The active document
    /// is never evicted; a tab with a pending page-edit session is skipped because its working
    /// revision cannot be reconstructed from the file on disk. (If every inactive tab has such a
    /// session the limit is exceeded temporarily rather than discarding a staged edit.)
    private func trimRetainedDocuments() {
        while retainedDocumentCount > Self.maximumRetainedDocuments {
            let victim = retainedTabs.values
                .filter { $0.state.pageEditSession == nil }
                .min { $0.lastUsed < $1.lastUsed }
            guard let victim else { return }
            retainedTabs.removeValue(forKey: victim.tabID)
            documentEvictionCount += 1
            let victimURL = victim.state.document.url ?? victim.url
            lastEvictedDocumentURL = victimURL
            releaseEngineDocumentIfUnused(victimURL)
            FileHandle.standardError.write(Data((
                "aris-tabs: evicted \(victim.url.lastPathComponent) "
                + "(LRU, \(Self.maximumRetainedDocuments) documents retained)\n"
            ).utf8))
        }
    }

    /// Closes an engine document once nothing in this window can activate it again. The check for
    /// the live document and for another retained snapshot is what makes eviction *exactly once*
    /// even when two tabs point at the same file.
    private func releaseEngineDocumentIfUnused(_ url: URL) {
        if document?.url == url { return }
        if retainedTabs.values.contains(where: { ($0.state.document.url ?? $0.url) == url }) { return }
        engine.closeDocument(at: url)
    }

    /// Loads the document outline (once per document).
    public func loadOutline() {
        guard document != nil else {
            outline = []
            return
        }
        guard !outlineLoadCompleted else { return }
        outlineLoadCompleted = true
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
            let image = try? await self.engine.renderThumbnail(page, scale: scale)
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
        cancelScrollGlide()
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
        cancelScrollGlide()
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

    /// The pointer entered or left the indicator's lane. Hover is input, not animation: it is
    /// what brings the faded-out thumb back before the reader presses it.
    public func setScrollIndicatorHovered(_ hovered: Bool) {
        guard hovered != isScrollIndicatorHovered else { return }
        isScrollIndicatorHovered = hovered
    }

    /// A press landed on the thumb. Any keyboard glide still in flight is dropped before the
    /// first drag event, so the document cannot keep travelling toward a page key's destination
    /// while the hand is moving the thumb somewhere else.
    public func beginScrollIndicatorDrag() {
        guard scrollIndicatorIsInteractive, !isDraggingScrollIndicator else { return }
        isDraggingScrollIndicator = true
        cancelScrollGlide()
        beginScrollActivity()
    }

    /// The hand released the thumb. The idle fade starts here, exactly as it does after a scroll.
    public func endScrollIndicatorDrag() {
        guard isDraggingScrollIndicator else { return }
        isDraggingScrollIndicator = false
        beginScrollActivity()
    }

    /// Jumps so that `page` (0-based) sits at the top of the viewport.
    public func gotoPage(_ page: Int) {
        guard document != nil else { return }
        cancelScrollGlide()
        scrollYPt = engine.pageTopPt(
            max(0, page), gapPt: pageGapPt, layout: layoutMode
        )
        reloadVisiblePages()
        schedulePositionSave()
    }

    // MARK: - Reading layout (T2.10)

    /// Switches between continuous and facing pages, keeping the reader's place.
    ///
    /// The anchor is the page under the viewport top and the offset *inside* that page. The
    /// same anchor is used for a gap change: both edits move page tops, and neither should
    /// throw the reader to a different paragraph.
    public func setLayoutMode(_ mode: ReaderLayoutMode) {
        guard mode != layoutMode else { return }
        let anchor = readingLayoutAnchor()
        layoutMode = mode
        if Self.usesStoredReadingLayoutPreferences {
            ReadingLayoutPreferences.store(layoutMode: mode)
        }
        applyLayoutChange(anchor)
        if mode == .facing { fitSpreadToViewportIfNeeded() }
        statusMessage = mode.title
    }

    /// Convenience for the View menu and the toolbar.
    public func toggleFacingPages() {
        setLayoutMode(layoutMode == .facing ? .continuous : .facing)
    }

    /// Sets the gap between pages, clamped to `pageGapRange`, and applies it immediately.
    public func setPageGap(_ value: CGFloat) {
        let clamped = ReadingLayoutPreferences.clampGap(value)
        guard abs(clamped - pageGapPt) > 0.0001 else { return }
        let anchor = readingLayoutAnchor()
        pageGapPt = clamped
        if Self.usesStoredReadingLayoutPreferences {
            ReadingLayoutPreferences.store(gapPt: clamped)
        }
        applyLayoutChange(anchor)
        statusMessage = String(format: "Page gap: %.0f pt", Double(clamped))
    }

    /// Reads the process-wide preferences. Called for this state when another window changed
    /// them (and by `ReaderWindowRegistry` when the Settings window moves the slider).
    public func adoptStoredReadingLayoutPreferences() {
        let mode = ReadingLayoutPreferences.layoutMode()
        let gap = ReadingLayoutPreferences.gapPt()
        guard mode != layoutMode || abs(gap - pageGapPt) > 0.0001 else { return }
        let anchor = readingLayoutAnchor()
        layoutMode = mode
        pageGapPt = gap
        applyLayoutChange(anchor)
        if mode == .facing { fitSpreadToViewportIfNeeded() }
    }

    /// Zooms a facing spread out until both pages fit the canvas.
    ///
    /// A facing pair is wider than the single page the reader was looking at: an A4 spread is
    /// 1202 pt at 100%, while the default window leaves about 960 pt for the canvas. Without
    /// this the right-hand page would be clipped and there is no horizontal scrolling to reach
    /// it. Only ever zooms **out**, and never below the normal minimum. The anchor is the
    /// viewport centre, so the spread opens where the reader was looking rather than at a page
    /// corner. The user's 100% zoom is still one ⌘+ away.
    private func fitSpreadToViewportIfNeeded() {
        guard layoutMode == .facing, contentWidthPt > 0, viewportSizePt.width > 0 else { return }
        let fitPercent = Int((viewportSizePt.width / contentWidthPt * 100).rounded(.down))
        guard fitPercent < zoomPercent else { return }
        let target = max(Self.minimumZoomPercent, fitPercent)
        guard target < zoomPercent else { return }

        cancelScrollGlide()
        pointerZoomRemainder = 0
        let centreContentY = scrollYPt + viewportHeightContentPt / 2
        zoomPercent = target
        let fittedViewport = viewportSizePt.height / zoomFactor
        scrollYPt = clampedScrollOffset(centreContentY - fittedViewport / 2)
        reloadVisiblePages()
        schedulePositionSave()
    }

    private struct ReadingLayoutAnchor {
        let page: Int
        /// Distance from the page's top to the viewport top, in content points.
        let offsetY: CGFloat
    }

    private func readingLayoutAnchor() -> ReadingLayoutAnchor {
        guard document != nil else { return ReadingLayoutAnchor(page: 0, offsetY: 0) }
        let page = engine.pageIndex(
            atScrollYPt: scrollYPt, gapPt: pageGapPt, layout: layoutMode
        )
        let top = engine.pageTopPt(page, gapPt: pageGapPt, layout: layoutMode)
        return ReadingLayoutAnchor(page: page, offsetY: max(0, scrollYPt - top))
    }

    /// Rebuilds the scroll geometry after `layoutMode` or `pageGapPt` changed and restores the
    /// anchored reading position. The tile cache is untouched: a page's pixels do not depend on
    /// where the page is placed, only its quads do.
    private func applyLayoutChange(_ anchor: ReadingLayoutAnchor) {
        guard document != nil else {
            contentHeightPt = 0
            contentWidthPt = 0
            canvasPages = []
            canvasTiles = []
            return
        }
        contentHeightPt = engine.contentHeightPt(gapPt: pageGapPt, layout: layoutMode)
        contentWidthPt = engine.contentWidthPt(gapPt: pageGapPt, layout: layoutMode)
        let top = engine.pageTopPt(anchor.page, gapPt: pageGapPt, layout: layoutMode)
        scrollYPt = clampedScrollOffset(top + anchor.offsetY)
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
    /// A page with no raster yet falls back to the sidebar thumbnail for exactly as long as its
    /// screen-resolution raster takes to render: measured with `--measure-page-fallback` on a
    /// real 115-page paper (959x715 pt viewport, 2x backing scale, 48 MiB budget, medians of five
    /// runs), 20.1 ms to a sharp 1224x1584 raster at 100% and 28.3 ms to 1714x2218 at 140%;
    /// at 400% the tile path shows a 1x preview for 35-55 ms instead. Rendering a half-scale
    /// raster first was measured and rejected (T4.36): it halves that window but adds a whole
    /// extra render before the sharp one.
    ///
    /// Zoom reuses the existing raster immediately. On a LOD change, retain the previous
    /// tiles until all visible tiles on that page are ready, then replace them together, so a
    /// half-finished LOD cannot mix two sharpness levels in one frame.
    ///
    /// That mixing belongs to this tiled deep-zoom path, not to the base's ordinary zoom: the
    /// verification of #37 found the base never had a 1x preview and pyramid tiles in the same
    /// frame (0 of 230 canvas updates), and that its real defect was a blurry 1x raster held
    /// for up to 26 consecutive canvas updates (84-88 ms per page jump). The comment here used
    /// to promise this retention removed a "visible diagonal sweep" of preview plus tiles,
    /// which overstates what the base did.
    public func reloadVisiblePages() {
        guard document != nil else {
            canvasPages = []
            canvasTiles = []
            contentHeightPt = 0
            return
        }

        contentHeightPt = engine.contentHeightPt(gapPt: pageGapPt, layout: layoutMode)
        contentWidthPt = engine.contentWidthPt(gapPt: pageGapPt, layout: layoutMode)

        let viewportHeight = viewportHeightContentPt
        let margin = viewportHeight * 2
        let visible = engine.visiblePages(
            scrollYPt: scrollYPt,
            viewportHeightPt: viewportHeight,
            gapPt: pageGapPt,
            marginPt: margin,
            layout: layoutMode
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
        let onScreen = band.filter {
            let p = $0.placement
            return CGRect(x: p.leftPt, y: p.topPt, width: p.widthPt, height: p.heightPt).intersects(viewport)
        }
        let screenPagePath = screenPagePathDecision(onScreen: onScreen, band: band, scale: screenScale)
        usesScreenPageRasters = screenPagePath.enabled
        screenPagePathNote = screenPagePath.note
        screenPagePathSummary = screenPagePath.summary
        reportScreenPagePath(scale: screenScale)
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
                pages.append(CanvasPage(placement: PagePlacement(index: PlacementIndex.pageRaster(placement.index),
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
        if isRestoringDocument && !pages.isEmpty { isRestoringDocument = false }
        currentPage = engine.pageIndex(atScrollYPt: scrollYPt, gapPt: pageGapPt, layout: layoutMode) + 1
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

    /// Where a page region sits in the **canvas's** view space (top-left origin), or nil when
    /// that page is not in the band the shell has placements for.
    ///
    /// The floating preview uses this to open next to the thing that was clicked rather than in a
    /// corner: the anchor is the entry's or figure's own rectangle, transformed exactly the way
    /// the canvas transforms it when drawing.
    public func anchorViewRect(page: Int, region: CGRect?) -> CGRect? {
        guard let placement = visiblePagePlacements.first(where: { $0.index == page }) else {
            return nil
        }
        let local = region ?? CGRect(x: 0, y: 0,
                                     width: placement.widthPt, height: placement.heightPt)
        return viewRect(local: local, on: placement)
    }

    /// The page under a content-space point, or nil for a gap, the margin or no document.
    ///
    /// The click paths all walk `visiblePagePlacements` in reading order and test the same
    /// rectangle; exposing the decision makes the facing-layout hit test checkable directly
    /// (a point in the right-hand page must name that page's index, not its partner's).
    public func pagePlacement(at point: CGPoint) -> PagePlacement? {
        visiblePagePlacements.first { placement in
            CGRect(
                x: placement.leftPt,
                y: placement.topPt,
                width: placement.widthPt,
                height: placement.heightPt
            ).contains(point)
        }
    }

    /// A page-local rectangle in the canvas's view space (top-left origin).
    ///
    /// The click paths use this to hand the floating panel the rectangle the reader actually
    /// clicked, transformed exactly the way the canvas transforms it while drawing.
    public func viewRect(local region: CGRect, on placement: PagePlacement) -> CGRect {
        CanvasGeometry.viewRect(
            pageTopPt: placement.topPt,
            pageLeftPt: placement.leftPt,
            region: region,
            scrollYPt: scrollYPt,
            zoom: zoomFactor,
            contentOffsetX: CanvasGeometry.contentOffsetX(
                viewportWidthPt: viewportSizePt.width,
                contentWidthPt: contentWidthPt,
                zoom: zoomFactor
            )
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
    ///
    /// The number the budget bounds is *not* the tile figure alone: whole-page rasters are
    /// reserved from the same budget (`TileCache.evictToFit(reservedBytes:)`), while sidebar
    /// thumbnails and text layers are held outside it. The line therefore labels the tile
    /// figure, prints the page rasters next to it, prints the two together against the budget
    /// ("shared"), and ends with the total the reader actually holds. Reporting only
    /// `cache X/48 MiB` made a 140% run look like 0 MiB while three 14.5 MiB page rasters were
    /// resident (T4.39).
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
        let pageRasterBytes = pagePreviews.values.reduce(0) { $0 + $1.bgra.count }
        let thumbnailBytes = thumbnails.values.reduce(0) { $0 + $1.bgra.count }
        let textBytes = textPages.values.reduce(0) { $0 + $1.chars.count * MemoryLayout<TextChar>.size }
        let sharedBytes = tileCache.usedBytes + pageRasterBytes
        let screenPages = screenPagePathSummary
        let line = String(
            format: "aris-stats: cache %d tiles · tiles %.1f/%.1f MiB · pageRasters %.1f MiB · shared %.1f/%.1f MiB · peak tiles %.1f MiB · thumbnails %.1f MiB · text %.1f MiB · rasters total %.1f MiB · screenPages %@ · wanted %d · queued %d · hits %d · misses %d · hit rate %.1f%% · insertions %d · evictions %d (%.1f MiB)\n",
            tileCache.count,
            Double(tileCache.usedBytes) / mib, Double(tileCache.budgetBytes) / mib,
            Double(pageRasterBytes) / mib,
            Double(sharedBytes) / mib, Double(tileCache.budgetBytes) / mib,
            Double(tileCache.peakBytes) / mib,
            Double(thumbnailBytes) / mib, Double(textBytes) / mib,
            Double(sharedBytes + thumbnailBytes + textBytes) / mib,
            screenPages,
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
        let previewBytes = pageRasterBytes
        // The same three consumers the `aris-stats` line totals, split by band class here: a
        // line that called the whole-page rasters "previews" is what made the two HUD lines
        // disagree about what the 48 MiB budget covers (T4.39).
        let bandLine = String(
            format: "aris-band: visible %d tiles (%.1f MiB) · ring %d (%.1f MiB) · offscreenCols %d (%.1f MiB) · stale %d (%.1f MiB) · pageRasters %.1f MiB · thumbnails %.1f MiB · text %.1f MiB · ringVh %.2f · visibleMiss %d · lod %d · tilePt %.0f · bandPages %d\n",
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
                idBase: PlacementIndex.selection(0),
                to: &pages
            )
        }

        for (annotationIndex, annotation) in annotations.enumerated() {
            // Geometry marks are drawn by the annotation overlay, not as tinted text boxes.
            guard !annotation.kind.isGeometry else { continue }
            appendHighlight(
                page: annotation.page,
                range: annotation.start...max(annotation.start, annotation.end),
                // Our own annotations are drawn alpha-over: the sidecar colour already carries
                // the opacity the reader chose, and it was chosen against a white page.
                image: annotationTexture(for: annotation.color, opacity: 1.0, blend: .normal),
                // Its own index block, one slot per line: the index is the key the canvas caches
                // this quad's texture under, so it must not collide with a page raster or with a
                // loaded annotation (see `PlacementIndex`).
                idBase: PlacementIndex.ownAnnotation(annotationIndex),
                // An underline is a thin bar on the baseline instead of a filled box.
                verticalScale: annotation.kind == .underline ? 0.1 : 1.0,
                verticalOffset: annotation.kind == .underline ? 0.9 : 0.0,
                to: &pages
            )
        }

        appendDocumentAnnotations(to: &pages)
    }

    /// Draws the annotations the PDF itself carries.
    ///
    /// Every one of them is drawn from the classification the **reader** made
    /// (`DocumentAnnotation.drawing`), not from a predicate re-derived here: a markup kind is one
    /// tinted box per `/QuadPoints` entry, a sticky note is its icon filling `/Rect`, a free text
    /// is its own text laid out in `/Rect`, and `skipped` is nothing — with the reason recorded by
    /// the reader, so the same annotation is never drawn here and called undrawable by the dump.
    ///
    /// The blend mode comes from the reader too: the file's `/BM` when it states one, and
    /// otherwise the mode that kind is composited with — highlighting a line in Preview stores
    /// `/Multiply` inside the appearance stream rather than on the annotation, and drawing that
    /// alpha-over replaces the page colour under the highlight instead of multiplying into it,
    /// which turns the glyphs the colour of the highlight. `/CA` is baked into the colour for
    /// multiply (see `AnnotationColor.baked`), because PDF mixes opacity in the stored colour
    /// space and the GPU mixes in linear light.
    ///
    /// An annotation with no `/C` is not black, it is "the file did not say": markup is drawn in a
    /// neutral grey that carries its `/CA`, a sticky note in the default note colour (an icon is a
    /// glyph, and every viewer draws it in the colour people read as "comment"), and free text in
    /// the same neutral grey the markup path uses.
    ///
    /// Notes were the 122 of the review corpus's 242 content annotations that used to be listed in
    /// the sidebar and nowhere else; `review_tang_0905.pdf` is nothing but notes, so it opened as
    /// a page with no sign it had ever been annotated.
    private func appendDocumentAnnotations(to pages: inout [CanvasPage]) {
        for (annotationIndex, annotation) in documentAnnotations.enumerated() {
            guard annotation.visible else { continue }
            guard let placement = visiblePagePlacements.first(where: { $0.index == annotation.page })
            else { continue }

            // A missing /C is not black: it is "the file did not say", and the mark is drawn in a
            // neutral grey so it is still visible without inventing a hue. The grey takes the
            // annotation's own opacity: `/CA` is the file's statement about how much of the page
            // shows through, and it holds whether or not `/C` could be read. A hard-coded opaque
            // grey here is what covered the text of every highlight whose colour the reader could
            // not report.
            let opacity = annotation.opacity ?? 1.0
            let neutral = UInt8(min(max((opacity * 255.0).rounded(), 0), 255))
            let neutralColor = AnnotationColor(red: 0x80, green: 0x80, blue: 0x80, alpha: neutral)

            switch annotation.drawing {
            case .skipped:
                // Nothing to draw, and the reader has already said why (the sidebar lists it).
                continue

            case .noteIcon:
                guard let box = annotation.boxes.first,
                      let image = noteGlyphTexture(
                          for: annotation,
                          index: annotationIndex,
                          color: annotation.color ?? .defaultNote,
                          boxPt: CGSize(width: box.widthPt, height: box.heightPt)
                      )
                else { continue }
                appendNoteGlyph(
                    image,
                    index: PlacementIndex.documentNote(annotationIndex),
                    box: box,
                    placement: placement,
                    annotation: annotation,
                    to: &pages
                )

            case .geometry:
                // The canvas overlay draws ink and shapes from their page-space geometry; a
                // textured quad would be the wrong shape and the wrong width.
                continue

            case .freeText:
                guard let box = annotation.boxes.first,
                      let image = noteGlyphTexture(
                          for: annotation,
                          index: annotationIndex,
                          color: annotation.color ?? neutralColor,
                          boxPt: CGSize(width: box.widthPt, height: box.heightPt)
                      )
                else { continue }
                appendNoteGlyph(
                    image,
                    index: PlacementIndex.documentNote(annotationIndex),
                    box: box,
                    placement: placement,
                    annotation: annotation,
                    to: &pages
                )

            case .markup:
                let color = annotation.color ?? neutralColor
                let blend = annotation.quadBlend
                let image = annotationTexture(for: color, opacity: opacity, blend: blend)

                for (boxIndex, box) in annotation.boxes.enumerated() {
                    // Underline, strikeout and squiggly are lines through or under the text, not
                    // filled boxes: the same thin-bar trick our own annotations use, with the bar
                    // placed at the bottom (underline, squiggly) or the middle (strikeout).
                    let isLine = annotation.kind != "highlight"
                    let scale: CGFloat = isLine ? 0.12 : 1.0
                    let offset: CGFloat = annotation.kind == "strikeout" ? 0.45 : 0.85
                    let index = PlacementIndex.documentAnnotation(annotationIndex, box: boxIndex)
                    let topPt = placement.topPt + box.yPt + box.heightPt * (isLine ? offset : 0)

                    pages.append(CanvasPage(
                        placement: PagePlacement(
                            index: index,
                            topPt: topPt,
                            leftPt: placement.leftPt + box.xPt,
                            widthPt: box.widthPt,
                            heightPt: max(box.heightPt * scale, 1)
                        ),
                        image: image,
                        blend: blend
                    ))

                    if annotationDumpEnabled {
                        // What the canvas is handed, before it uploads anything: the model's half
                        // of the answer to "is the picture wrong because of what we were asked to
                        // draw, or because of how it was composited?" (the canvas prints its half
                        // under the same variable; both lines carry the same placement index).
                        annotationDump(
                            "annot page=\(annotation.page) box=\(boxIndex)/\(annotation.boxes.count) "
                                + "idx=\(index) view=(\(Self.round(box.xPt)),\(Self.round(box.yPt)) "
                                + "\(Self.round(box.widthPt))x\(Self.round(box.heightPt)))pt "
                                + "drawn=(\(Self.round(topPt - placement.topPt)) "
                                + "\(Self.round(max(box.heightPt * scale, 1))))pt "
                                + "tint=\(image.bgra.count >= 4 ? Self.hex(image.bgra) : "?") "
                                + "blend=\(annotation.blend) kind=\(annotation.kind) "
                                + "/C=\(annotation.color.map { $0.hex } ?? "none") "
                                + "/CA=\(annotation.opacity.map { String(format: "%.3f", $0) } ?? "absent")")
                    }
                }
            }
        }
        for marker in inlineNoteMarkers {
            let annotation = documentAnnotations[marker.annotationIndex]
            guard let placement = visiblePagePlacements.first(where: { $0.index == marker.page }) else { continue }
            let color = annotation.color ?? AnnotationColor(red: 0x80, green: 0x80, blue: 0x80, alpha: 255)
            let opaque = AnnotationColor(red: color.red, green: color.green, blue: color.blue, alpha: 255)
            let box = AnnotationQuadBox(xPt: marker.rect.minX, yPt: marker.rect.minY,
                                        widthPt: marker.rect.width, heightPt: marker.rect.height)
            guard let image = noteGlyphTexture(for: annotation, index: marker.annotationIndex,
                                               color: opaque, boxPt: marker.rect.size) else { continue }
            appendNoteGlyph(image, index: PlacementIndex.documentNote(marker.annotationIndex),
                            box: box, placement: placement, annotation: annotation, to: &pages)
        }
    }

    /// Hands one note glyph — an icon or a rasterized free text — to the canvas.
    ///
    /// Both are a bitmap drawn into the annotation's `/Rect`, alpha-over: a note is an opaque
    /// glyph sitting on the page, not a tint multiplied into it. The index comes from
    /// `PlacementIndex.documentNote`, a block of its own (see there for why it is not one more
    /// `documentAnnotation` box).
    private func appendNoteGlyph(
        _ image: PageImage,
        index: Int,
        box: AnnotationQuadBox,
        placement: PagePlacement,
        annotation: DocumentAnnotation,
        to pages: inout [CanvasPage]
    ) {
        pages.append(CanvasPage(
            placement: PagePlacement(
                index: index,
                topPt: placement.topPt + box.yPt,
                leftPt: placement.leftPt + box.xPt,
                widthPt: box.widthPt,
                heightPt: box.heightPt
            ),
            image: image,
            blend: .normal
        ))

        if annotationDumpEnabled {
            annotationDump(
                "note page=\(annotation.page) idx=\(index) kind=\(annotation.kind) "
                    + "drawing=\(annotation.drawing.rawValue) "
                    + "view=(\(Self.round(box.xPt)),\(Self.round(box.yPt)) "
                    + "\(Self.round(box.widthPt))x\(Self.round(box.heightPt)))pt "
                    + "bitmap=\(image.pixelWidth)x\(image.pixelHeight) "
                    + "tint=\(annotation.color.map { $0.hex } ?? "none")"
                    + "\(annotation.drawing == .freeText ? " text=\"\(annotation.contents ?? "")\" size=\(annotation.fontSizePt.map { Self.round($0) } ?? "default") /Q=\(annotation.alignment)" : "")")
        }
    }

    /// The bitmap for one note annotation, from the cache or freshly rendered.
    ///
    /// Keyed by everything that changes the pixels — the kind, the colour, the text and its layout,
    /// the `/Rect` and the rasterization scale — so scrolling past the same note reuses its
    /// texture and zooming re-renders once per scale step (see `NoteGlyph.scale`).
    private func noteGlyphTexture(
        for annotation: DocumentAnnotation,
        index: Int,
        color: AnnotationColor,
        boxPt: CGSize
    ) -> PageImage? {
        let scale = NoteGlyph.scale(zoom: zoomFactor, deviceScale: deviceScale)
        let key = NoteGlyphKey(
            index: index,
            drawing: annotation.drawing,
            color: color,
            contents: annotation.contents ?? "",
            fontSizePt: annotation.fontSizePt ?? NoteGlyph.defaultFreeTextSizePt,
            alignment: annotation.alignment,
            boxPt: boxPt,
            scale: scale
        )
        if let cached = noteGlyphTextures[key] { return cached }

        nextAnnotationTextureGeneration += 1
        let generation = nextAnnotationTextureGeneration
        let image: PageImage? = switch annotation.drawing {
        case .noteIcon:
            NoteGlyph.noteIcon(color: color, boxPt: boxPt, scale: scale, generation: generation)
        case .freeText:
            NoteGlyph.freeText(
                annotation.contents ?? "",
                color: color,
                fontSizePt: annotation.fontSizePt ?? NoteGlyph.defaultFreeTextSizePt,
                alignment: annotation.alignment,
                boxPt: boxPt,
                scale: scale,
                generation: generation
            )
        case .markup:
            NoteGlyph.inlineComment(color: color, boxPt: boxPt, scale: scale, generation: generation)
        case .geometry, .skipped:
            nil
        }
        if let image { noteGlyphTextures[key] = image }
        return image
    }

    /// Identity of one note glyph texture: every input that changes a pixel of it.
    private struct NoteGlyphKey: Hashable {
        let index: Int
        let drawing: AnnotationDrawing
        let color: AnnotationColor
        let contents: String
        let fontSizePt: CGFloat
        let alignment: String
        let boxPt: CGSize
        let scale: CGFloat
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
    ///
    /// A click on one of the reader's own ink or shape strokes selects that mark and starts a
    /// move, and does **not** start a text selection. The hit test is geometric and tight — a
    /// few points around the stroke — so text a line away from a thin pen line is untouched and
    /// a click on the text goes on to select it. A PDF's own ink is deliberately not hit tested
    /// here: it can be seen, not edited.
    public func beginSelection(at point: CGPoint) {
        if annotationTool == .select,
           let hit = geometryAnnotationHit(atContentPoint: point),
           let annotation = annotations.first(where: { $0.id == hit.id }) {
            selectedAnnotationID = hit.id
            moveOriginalAnnotation = annotation
            moveStartPagePoint = hit.point
            selection = nil
            selectionAnchor = nil
            refreshSelectionOverlay()
            return
        }
        selectedAnnotationID = nil
        moveOriginalAnnotation = nil
        moveStartPagePoint = nil
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
        if let original = moveOriginalAnnotation,
           let start = moveStartPagePoint,
           let placement = visiblePagePlacements.first(where: { $0.index == original.page }) {
            let current = CGPoint(x: point.x - placement.leftPt, y: point.y - placement.topPt)
            let moved = original.translated(by: current.x - start.x, dy: current.y - start.y)
            guard moved.hasValidGeometry,
                  let index = annotations.firstIndex(where: { $0.id == original.id }) else { return }
            var updated = annotations
            updated[index] = moved
            // In memory only: one drag is one sidecar write, on mouse-up. Writing per pointer
            // event would turn a single gesture into hundreds of disk writes.
            annotations = updated
            return
        }
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

    /// Clears the selected geometry mark without touching a text selection.
    public func clearAnnotationSelection() {
        guard selectedAnnotationID != nil else { return }
        selectedAnnotationID = nil
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
        CanvasPage(placement: PagePlacement(index: PlacementIndex.pageRaster(placement.index),
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

    /// Whether the visible band is rendered as one screen-resolution raster per page, and when
    /// it is not, which limit turned it off.
    ///
    /// The exact thresholds, stated because a small cache used to disable this path silently
    /// (T4.37) and a reader who lowers the cache setting got a different renderer with no
    /// indication:
    ///   * `ARIS_READER_SHARP_PAGE_RASTERS=0`, or `ARIS_READER_PREVIEW_PAGES=0`, disables it;
    ///   * one page raster must be at most `min(budget / 2, 32 MiB)`. A US Letter page at 140%
    ///     on a 2x display is 1714x2218 px = 14.5 MiB, so the cache budget must be at least
    ///     29.0 MiB for the path to be available at all — 30 MiB as a whole-MiB setting — and
    ///     the default 48 MiB leaves a page raster at half the budget;
    ///   * a page's largest side must be at most 8192 px (the FFI's whole-page clamp would
    ///     otherwise silently return a smaller bitmap);
    ///   * at most 7 pages may be on screen at once (the prepared-neighbourhood ceiling);
    ///   * the on-screen pages' rasters together must fit the whole budget.
    private func screenPagePathDecision(onScreen: [BandSpan], band: [BandSpan],
                                        scale: CGFloat) -> (enabled: Bool, note: String?, summary: String) {
        let mib = 1024.0 * 1024.0
        if !preferFullPageRasters {
            return (false, "off: ARIS_READER_SHARP_PAGE_RASTERS=0 disables screen-resolution pages",
                    "off(feature-off)")
        }
        if Self.maxPreviewPages == 0 {
            return (false, "off: ARIS_READER_PREVIEW_PAGES=0 allows no whole-page raster",
                    "off(preview-pages 0)")
        }
        if band.isEmpty {
            return (false, "off: no page in the prefetch band", "off(no band)")
        }
        if onScreen.count > Self.maxPreviewPages {
            return (false, "off: \(onScreen.count) pages on screen exceed the \(Self.maxPreviewPages)-page ceiling",
                    "off(pages \(onScreen.count)>\(Self.maxPreviewPages))")
        }
        let onScreenBytes = onScreen.reduce(CGFloat(0)) { $0 + screenPageBytes($1.placement, scale: scale) }
        if onScreenBytes > CGFloat(tileCache.budgetBytes) {
            return (false, String(format: "off: on-screen page rasters %.1f MiB exceed the %.1f MiB cache budget",
                                  Double(onScreenBytes) / mib, Double(tileCache.budgetBytes) / mib),
                    String(format: "off(rasters %.1f>%.1f MiB)", Double(onScreenBytes) / mib,
                           Double(tileCache.budgetBytes) / mib))
        }
        let perPageCeiling = min(tileCache.budgetBytes / 2, 32 * 1024 * 1024)
        for span in band {
            let bytes = screenPageBytes(span.placement, scale: scale)
            let longestSide = max(span.placement.widthPt, span.placement.heightPt) * scale
            if bytes > CGFloat(perPageCeiling) {
                let pageMiB = Double(bytes) / mib
                let ceilingMiB = Double(perPageCeiling) / mib
                let budgetMiB = Double(tileCache.budgetBytes) / mib
                let capIsBudget = tileCache.budgetBytes / 2 <= 32 * 1024 * 1024
                return (false, String(
                    format: "off: one page raster is %.1f MiB, above the %.1f MiB page ceiling (half of the %.1f MiB cache budget%@); needs a >= %.1f MiB budget",
                    pageMiB, ceilingMiB, budgetMiB,
                    capIsBudget ? "" : ", capped at 32 MiB", Double(bytes) * 2 / mib),
                    capIsBudget
                        ? String(format: "off(page %.1f>%.1f MiB; budget <%.1f MiB)", pageMiB, ceilingMiB, Double(bytes) * 2 / mib)
                        : String(format: "off(page %.1f>%.1f MiB, 32 MiB cap)", pageMiB, ceilingMiB))
            }
            if longestSide > 8192 {
                return (false, String(format: "off: a page needs %.0f px on its longest side, above the 8192 px whole-page clamp (scale %.2f)",
                                      Double(longestSide), Double(scale)),
                        String(format: "off(page %.0f>8192 px)", Double(longestSide)))
            }
        }
        return (true, nil, "on")
    }

    /// Says *once per change* whether the screen-resolution path is on, and if not, why.
    ///
    /// A log line, not a silent fallback: lowering the cache setting below a page raster's cost
    /// is a legitimate way to hit this, and it should be visible without reading the source.
    private func reportScreenPagePath(scale: CGFloat) {
        guard !hasReportedScreenPagePath || screenPagePathNote != lastScreenPagePathNote else { return }
        hasReportedScreenPagePath = true
        lastScreenPagePathNote = screenPagePathNote
        let line: String
        if let note = screenPagePathNote {
            line = "aris-screen-page: \(note); using pyramid tiles\n"
        } else {
            line = String(format: "aris-screen-page: on · screen scale %.2f · %.1f MiB cache budget\n",
                          Double(scale), Double(tileCache.budgetBytes) / (1024.0 * 1024.0))
        }
        FileHandle.standardError.write(Data(line.utf8))
    }

    private func configurePagePreviews(visible: [PagePlacement], band: [BandSpan], viewport: CGRect,
                                       viewportHeight: CGFloat, screenScale: CGFloat) {
        desiredPreviewScale = usesScreenPageRasters ? screenScale : 1
        let current = engine.pageIndex(atScrollYPt: scrollYPt, gapPt: pageGapPt, layout: layoutMode)
        let bandPages = Set(band.map(\.placement.index))
        let candidates: [PagePlacement]
        let budget: Int
        if usesScreenPageRasters {
            candidates = engine.visiblePages(scrollYPt: scrollYPt, viewportHeightPt: viewportHeight,
                gapPt: pageGapPt, marginPt: max(viewportHeight * 2, (document?.firstPageSize.height ?? 0) * 3),
                layout: layoutMode)
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
