import LyraReaderFFI
import Combine
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Sidebar tabs (see `docs/04-ui-ux.md` §2.2).
///
/// The AI assistant used to be a tab here. It now lives in the reader's right-hand panel
/// (``ReaderSidePanel``), so a window can show the document and the assistant at the same time.
/// `.search` and `.metadata` remain because their content is reachable programmatically (search
/// results and the information sheet), but they are not part of the picker.
public enum SidebarTab: String, CaseIterable, Identifiable, Sendable {
    case thumbnails
    case outline
    case bookmarks
    case annotations
    case metadata
    case search

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .thumbnails: return "Thumbnails"
        case .outline: return "Outline"
        case .bookmarks: return "Bookmarks"
        case .annotations: return "Annotations"
        case .metadata: return "Metadata"
        case .search: return "Search"
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
        }
    }

    /// The tabs the left sidebar's picker offers, in reading order. No AI entry: it moved out.
    public static let sidebarPickerTabs: [SidebarTab] = [
        .bookmarks, .outline, .annotations, .thumbnails,
    ]

    public var isSidebarPickerTab: Bool { Self.sidebarPickerTabs.contains(self) }

    /// `UserDefaults` key for the reader's last sidebar tab.
    public static let persistedKey = "sidebarTab"

    /// Reads the persisted picker tab, falling back to a valid tab when the stored value names a
    /// tab that no longer exists.
    ///
    /// This is the migration path for a reader who left the sidebar on the old AI tab: the raw
    /// value `"ai"` no longer decodes, and an unreadable or non-picker value must not leave the
    /// sidebar blank. The fallback is written back so the next launch does not repeat the lookup.
    public static func restored(defaults: UserDefaults = .standard) -> SidebarTab {
        let stored = defaults.string(forKey: persistedKey)
        let restored = stored.flatMap(SidebarTab.init(rawValue:))
            .flatMap { $0.isSidebarPickerTab ? $0 : nil }
            ?? .thumbnails
        if stored != restored.rawValue {
            defaults.set(restored.rawValue, forKey: persistedKey)
        }
        return restored
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
    public static let didChange = Notification.Name("LyraReaderReadingLayoutPreferencesDidChange")

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
    /// Enabled by the application entry point; library/check hosts never alter user history.
    public static var recordsRecentDocuments = false
    @Published public var document: LoadedDocument?
    @Published public var sidebarTab: SidebarTab = .thumbnails {
        didSet {
            guard oldValue != sidebarTab, Self.usesStoredSidebarTab else { return }
            UserDefaults.standard.set(sidebarTab.rawValue, forKey: SidebarTab.persistedKey)
        }
    }
    @Published public var sidebarVisible: Bool = true
    /// Whether the right-hand panel (the AI assistant's new home) is open.
    ///
    /// The panel is a drawer, not a conditional view: this stays true while the window animates
    /// it closed, so the content keeps its geometry and an answer is not thrown away by a toggle.
    @Published public var rightPanelVisible: Bool = false {
        didSet {
            if rightPanelVisible, contentEditEnabled {
                if deferContentTransition({ [weak self] in self?.rightPanelVisible = true }) {
                    rightPanelVisible = false
                    return
                }
                contentEditEnabled = false
            }
            guard oldValue != rightPanelVisible, Self.usesStoredSidePanelPreferences else { return }
            ReaderSidePanelPreferences.store(visible: rightPanelVisible, defaults: panelDefaults)
        }
    }
    /// Content width of the right-hand panel, kept across launches and clamped on every write.
    /// The 6 pt resize handle and 1 pt separator are added by ``ReaderSidePanelMetrics``.
    @Published public private(set) var rightPanelWidthPt =
        ReaderSidePanelMetrics.defaultContentWidthPt
    /// Test-only transition progress. The app never sets it; `TransitionChecks` pins a value and
    /// steps it so a "partly open" frame is a deterministic layout, not a race with the display
    /// link on a loaded runner.
    @Published public var transitionProgressOverride: ReaderTransitionProgress?
    @Published public var searchSidebarVisible = false
    @Published public var showDocumentInformation = false
    // ── Form filling and document properties ───────────────────────────────────
    /// The AcroForm fields and facts read from the open document.
    @Published public private(set) var formInfo: FormInfo = .empty
    /// The reader's unsaved values, keyed by field identity. Empty means "the file's values".
    @Published public private(set) var formDraft: [String: FormFieldValue] = [:]
    @Published public private(set) var formLoading = false
    @Published public private(set) var formError: String?
    @Published public private(set) var formLoadCompleted = false
    /// The form tool is a mode like the ink and markup tools: while it is on, a click on a field
    /// edits it and a click elsewhere still reads the page. Leaving it restores normal reading.
    @Published public var formToolActive = false
    /// The field that owns the keyboard while the form tool is active.
    @Published public private(set) var formFocusedFieldID: String?
    /// The drop-down whose option list is open, when the form tool is active.
    @Published public private(set) var formOpenChoiceFieldID: String?
    @Published public private(set) var formSaveInProgress = false
    /// Facts and `/Info` values for the information panel, loaded when it opens.
    @Published public private(set) var documentInfo: DocumentInfo?
    @Published public private(set) var documentPropertiesDraft: DocumentProperties = .init()
    @Published public private(set) var documentInfoLoading = false
    @Published public private(set) var documentInfoError: String?
    @Published public private(set) var propertiesSaveInProgress = false
    @Published public var pageOverviewVisible: Bool = false
    /// Whether the annotation tools row is expanded. The row is an overlay on the canvas, not a
    /// layout row above it, so this is the value its show/hide transition animates.
    @Published public var annotationToolsVisible: Bool = false
    /// 100% means actual physical size, scaled by the current screen's calibration.
    @Published public var zoomPercent: Int = 100 {
        willSet {if newValue != zoomPercent,contentTextEditing {commitContentText?()}}
    }
    @Published public private(set) var displayCalibration = DisplayCalibration.uncalibratedDefault
    @Published public var currentPage: Int = 1 {
        willSet {if newValue != currentPage,contentTextEditing {commitContentText?()}}
        didSet {
            // A selected mark belongs to the page it is on. Turning to another page drops it,
            // so Delete can never remove a mark the reader can no longer see.
            if currentPage != oldValue {
                cancelPendingMarkSelection()
                if selectedAnnotationID != nil { selectedAnnotationID = nil }
            }
        }
    }
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
    private var pageEditSession: PageEditSession? {
        didSet {
            if let session = pageEditSession {
                Self.pageEditOwners[DocumentEditCache.recoveryURL(for: session.originalURL).path] = WeakState(self)
                persistPageEditRecovery()
            }
        }
    }
    private static var pageEditOwners: [String: WeakState] = [:]
    private var isChangingDocumentState = false
    @Published public private(set) var annotationCacheIsDirty = false

    @Published public var contentEditEnabled = false {
        didSet { if contentEditEnabled { rightPanelVisible = false } }
    }
    @Published public var contentEditTool = "select"
    @Published public var contentEditPage: PDFContentPage?
    @Published public var contentEditSelection: String?
    @Published public var contentEditLoading = false
    @Published public var contentLinkDraft: CGRect?
    @Published public var contentTextEditing = false
    @Published public var contentTextRecovery: String?
    @Published public private(set) var contentCommandInFlight = false
    @Published public var contentCloseRequested = false
    private var contentRecoveryCommand: (command: PDFContentCommand, page: Int, url: URL?)?
    private var pendingContentClose: Int?
    var commitContentText: (() -> Void)?
    private var contentEditTask: Task<Bool,Never>?
    private var contentLoadToken = UUID()

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

    /// Whether this process restores and records the sidebar's selected tab. Checks turn it off
    /// so a run cannot move the person's sidebar to whatever tab the checks exercise.
    public static var usesStoredSidebarTab = true

    /// Whether this process restores and records the right panel's width and visibility. Checks
    /// turn it off and pass an isolated defaults suite where they need to prove persistence.
    public static var usesStoredSidePanelPreferences = true

    /// Set while `AppState` listens for a preference change made in another window.
    private var layoutPreferencesObserver: NSObjectProtocol?

    /// Viewport size in screen points, reported by the canvas.
    private var viewportSizePt: CGSize = .zero
    /// One coalesced rebuild for width-only changes that can move the visible columns.
    private var pendingViewportReload: DispatchWorkItem?
    /// True while the right panel is sliding or being dragged. Its width changes arrive once per
    /// display frame; on a loaded runner a frame can take longer than the ordinary coalescing
    /// window, so those updates are held here and released as one rebuild when the movement ends.
    private var rightPanelLayoutIsMoving = false
    /// Set when a width-only update during that movement really could change the visible
    /// columns. No rebuild is needed at all when the page fits every width in the range.
    private var rightPanelDeferredReloadNeeded = false
    private var rightPanelSettleTask: Task<Void, Never>?
    /// How many times the visible band was rebuilt. Read by the transition checks: a width-only
    /// slide that cannot move the band must leave this unchanged for the whole animation.
    public private(set) var viewportReloadCount = 0
    /// The subset of ``viewportReloadCount`` that came from the width-only coalescing path.
    ///
    /// `viewportReloadCount` also moves when a raster arrives (the band is re-evaluated with the
    /// finished image), so it cannot answer "did resizing the panel rebuild the band per frame?"
    /// on a zoomed-in document. This counter only moves for a deferred width-only rebuild, which
    /// is exactly the cost the panel must not pay per frame.
    public private(set) var coalescedViewportReloadCount = 0
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
    /// the `LYRA_READER_CACHE_BUDGET_MB` override (measurement only) → the `cacheBudgetMB`
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
        let override = environment["LYRA_READER_CACHE_BUDGET_MB"].flatMap(Int.init)
        let stored = defaults.integer(forKey: cacheBudgetSettingKey)
        let megabytes = override ?? (stored > 0 ? stored : defaultTileCacheBudgetMB)
        return min(max(megabytes, 1), 4096) * 1024 * 1024
    }

    /// `@AppStorage` key shared with `SettingsView`.
    public static let cacheBudgetSettingKey = "cacheBudgetMB"

    /// Rasterized tiles, ready to draw, under the byte budget of ADR 0007 (`TileCache`).
    ///
    /// The policy — byte budget, LOD-aware LRU, pinned tiles never evicted — is the one
    /// `crates/lyra-reader-render/src/cache.rs` encodes; the hot path stays here per ADR 0007.
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
    /// Public so `LyraReaderChecks` can assert the band's invariants — that every tile the
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
    /// `LYRA_READER_PREVIEW_PAGES=<n>` overrides it for measurement.
    static let defaultMaxPreviewPages = 7
    private static let maxPreviewPages = ProcessInfo.processInfo.environment["LYRA_READER_PREVIEW_PAGES"]
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

    /// `LYRA_READER_PREFETCH_RING_VH=<viewports>`: measurement override that pins the ring to
    /// exactly that distance instead of deriving it from the byte target (`2.5` reproduces the
    /// pre-change band). Documented next to the cache-budget override, and used the same way.
    static func configuredPrefetchRingOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CGFloat? {
        guard let raw = environment["LYRA_READER_PREFETCH_RING_VH"], let value = Double(raw) else {
            return nil
        }
        return min(max(CGFloat(value), 0), 4)
    }

    /// `LYRA_READER_PREFETCH_ALL_COLUMNS=1`: measurement override that restores the pre-change
    /// "every column of the page is wanted" rule, so the two halves of the band can be
    /// attributed separately.
    static func configuredWantAllColumns(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["LYRA_READER_PREFETCH_ALL_COLUMNS"] == "1"
    }

    /// `LYRA_READER_PREFETCH_BAND_MIB=<N>`: measurement override for the band's byte target, so
    /// the curve can be swept without also changing the cache budget (which is what makes the
    /// zoom-back interaction work). `LYRA_READER_PREFETCH_COLUMNS=<N>` overrides the number of
    /// columns kept ready beyond the visible ones.
    static func configuredPrefetchColumns(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        guard let raw = environment["LYRA_READER_PREFETCH_COLUMNS"], let columns = Int(raw) else {
            return prefetchColumnsToTheRight
        }
        return min(max(columns, 0), 16)
    }

    /// The `LYRA_READER_PREFETCH_*` overrides are read once: they are constants for the
    /// process, and the band is rebuilt (with `bandSpans` several times inside it) on every
    /// viewport update, i.e. on the scrolling path.
    private static let prefetchRingOverride = configuredPrefetchRingOverride()
    private static let wantAllColumns = configuredWantAllColumns()
    private static let prefetchColumns = configuredPrefetchColumns()
    private static let prefetchBandMiB = ProcessInfo.processInfo.environment["LYRA_READER_PREFETCH_BAND_MIB"]
    private static let renderStatsEnabled =
        ProcessInfo.processInfo.environment["LYRA_READER_RENDER_STATS"] == "1"
    private var pendingTiles: [(TileKey, PagePlacement)] = []
    private var pagePreviews: [Int: PageImage] = [:]
    private var pagePreviewScales: [Int: CGFloat] = [:]
    private var desiredPreviewScale: CGFloat = 1
    private let preferFullPageRasters: Bool
    public private(set) var usesScreenPageRasters = false
    /// Why the screen-resolution page path is off, or nil when it is on. Set with every
    /// viewport update (see `screenPagePathDecision`) and reported once per change to stderr
    /// and in the `LYRA_READER_RENDER_STATS` line, so a degraded configuration is visible
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
    private var textPages: [Int: TextPage] = [:] {
        didSet {
            if textPages.isEmpty { passageTextMaps = [:] }
            rebuildAnnotationPassages()
        }
    }
    private var passageTextMaps: [Int: AnnotationSentenceMap] = [:]
    @Published package private(set) var annotationPassages: [AnnotationPassage] = []
    @Published package private(set) var annotationSidebarPages: [AnnotationSidebarPage] = []
    private var textPagesInFlight: Set<Int> = []
    /// Page placements from the last layout pass (hit-testing needs them).
    private var visiblePagePlacements: [PagePlacement] = []

    /// The small, honest set of stamps a reader actually uses.
///
/// The words and colours are the stamp's whole design, so they live in one place: the toolbar
/// menu, the canvas badge, the sidebar row and the PDF appearance all read them from here. A
/// date stamp freezes today's date into `note` when it is placed, so moving or resaving it never
/// changes what the stamp says.
public enum StampStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case approved
    case reviewed
    case draft
    case confidential
    /// A dated mark: its words are the local date at placement time (`YYYY-MM-DD`).
    case date

    public var id: String { rawValue }

    /// The menu label, in the reader's words.
    public var title: String {
        switch self {
        case .approved: return "Approved"
        case .reviewed: return "Reviewed"
        case .draft: return "Draft"
        case .confidential: return "Confidential"
        case .date: return "Date"
        }
    }

    /// The words on the stamp. A date stamp is computed when it is placed; every other style is
    /// a fixed phrase.
    public func text(on day: Date = Date()) -> String {
        switch self {
        case .approved: return "APPROVED"
        case .reviewed: return "REVIEWED"
        case .draft: return "DRAFT"
        case .confidential: return "CONFIDENTIAL"
        case .date:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: day)
        }
    }

    /// The ink and border colour. Deliberately a small palette with a meaning, not a free
    /// colour: a green "APPROVED" and a red "CONFIDENTIAL" are read before the words are.
    public var color: AnnotationColor {
        switch self {
        case .approved:
            return AnnotationColor(red: 0x1B, green: 0x7F, blue: 0x3B, alpha: 255)
        case .reviewed:
            return AnnotationColor(red: 0x1F, green: 0x5F, blue: 0xA8, alpha: 255)
        case .draft:
            return AnnotationColor(red: 0x6B, green: 0x72, blue: 0x80, alpha: 255)
        case .confidential:
            return AnnotationColor(red: 0xB3, green: 0x26, blue: 0x1E, alpha: 255)
        case .date:
            return AnnotationColor(red: 0x33, green: 0x41, blue: 0x55, alpha: 255)
        }
    }

    /// The style a file's private key or standard `/Name` maps to.
    public init?(fileStyle: String) {
        switch fileStyle.lowercased() {
        case "approved": self = .approved
        case "reviewed": self = .reviewed
        case "draft": self = .draft
        case "confidential": self = .confidential
        case "date": self = .date
        default: return nil
        }
    }
}

/// A highlight the reader added.
///
/// Stored in a sidecar JSON next to the document rather than inside the PDF itself: writing
/// PDF annotations means round-tripping the file through PDFium (`FPDF_Annot_*` +
/// `FPDF_SaveAsCopy`), and a sidecar keeps the original untouched until that lands. The
/// durable model and its undo/redo transactions belong in `lyra-reader-edit` (T3.1).
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
        /// A line through the middle of the selected glyphs. A text-markup kind like the two
        /// above: same range model, same `/QuadPoints` write path, different `/Subtype`.
        case strikeout
        case ink
        case square
        case circle
        case line
        case arrow
        /// A placeable sticky note: an icon at a page point, with its text in `note`.
        case stickyNote
        /// A placeable text box laid out in `shapeRect`, with its text in `note`.
        case textBox
        /// A rubber stamp: `note` is its wording, `stampStyle` its style, `shapeRect` its box.
        /// Written into the PDF as `/Stamp` with an appearance stream that draws the border and
        /// the words in the bundled font, which is the same font the canvas draws.
        case stamp
        /// An image signature: `imageData` is the picture the reader chose, `shapeRect` its box.
        /// Written into the PDF as a `/Stamp` whose appearance stream paints the image.
        case signature

        /// Whether this kind is stored as geometry rather than as a character range.
        public var isGeometry: Bool {
            switch self {
            case .highlight, .underline, .strikeout: return false
            case .ink, .square, .circle, .line, .arrow: return true
            case .stickyNote, .textBox, .stamp, .signature: return false
            }
        }

        public var isTextMarkup: Bool { self == .highlight || self == .underline || self == .strikeout }

        /// Whether this kind is a placed text annotation (a sticky note or a text box).
        ///
        /// These carry page-space geometry like an ink stroke, but they are drawn from a glyph
        /// bitmap rather than a vector path and they carry their text in `note`. They are
        /// versioned separately from the stroked kinds so a newer schema is preserved rather
        /// than partially read.
        public var isPlacedText: Bool {
            switch self {
            case .stickyNote, .textBox: return true
            case .highlight, .underline, .strikeout, .ink, .square, .circle, .line, .arrow,
                 .stamp, .signature:
                return false
            }
        }

        /// Whether this kind is an image or a stamp badge whose box is placed, moved and
        /// resized like a note's but whose content is not text to be edited in a text view.
        public var isStampArtwork: Bool {
            self == .stamp || self == .signature
        }

        /// Whether this kind occupies a page box that the select tool can move and resize.
        ///
        /// This is the union the canvas needs, not a statement about how the content is drawn:
        /// ink and shapes move by their geometry, placed text by its box, and a stamp by the box
        /// its appearance fills.
        public var isPlacement: Bool { isGeometry || isPlacedText || isStampArtwork }
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

    /// The sidecar schema version of a placed-text entry (sticky note or text box).
    ///
    /// Separate from `geometryVersion` on purpose: the two kinds are drawn and written by
    /// different code, and a future change to one must never make the other's entries look
    /// half-understood. `AnnotationSidecar` preserves any version it does not know.
    public static let placedTextVersion = 1

    /// The sidecar schema version of a text stamp entry.
    public static let stampVersion = 1

    /// The sidecar schema version of an image-signature entry.
    public static let signatureVersion = 1

    /// The size a newly placed sticky note icon occupies on the page, in points.
    public static let stickyNoteSize = CGSize(width: 22, height: 22)

    /// The default font size of a new text box, in points.
    public static let defaultTextBoxFontSize: CGFloat = 14

    /// The size a newly placed stamp occupies, in page points. Wide enough for `CONFIDENTIAL`
    /// at a readable size; the reader can move and resize it afterwards.
    public static let defaultStampSize = CGSize(width: 150, height: 50)

    /// The height a newly placed image signature occupies, in page points. Its width follows the
    /// picture's aspect ratio, so a tall signature is not stretched on the way in.
    public static let defaultSignatureHeight: CGFloat = 64

    /// The smallest text box the reader may create or resize to, in points.
    ///
    /// The width is wide enough for a few narrow glyphs but small enough for the box a
    /// double-click creates (about three characters, see `TextBoxLayout.creationSize`); the
    /// height is one line at the smallest font. Older sidecars' larger boxes stay valid.
    public static let minimumTextBoxSize = CGSize(width: 24, height: 24)

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
    /// The stroke width in points. Constant for the whole mark; zero for text markup and
    /// placed text.
    public var strokeWidth: CGFloat = 0
    /// The font size a text box is drawn and written at, in page points. Zero for every other
    /// kind. This is `/DA`'s size on the way into the PDF.
    public var fontSize: CGFloat = 0
    /// The PDF's own identity for an annotation this entry **edits**, or `nil` for an entry this
    /// reader created.
    ///
    /// The value is exactly `DocumentAnnotation.id` (`nm:<NM>`, or `fp:<fingerprint>` when the
    /// file carries no `/NM`). It is what the writer resolves at save time, so the annotation's
    /// `/NM`, author, flags, popup, parent and reply links stay the file's own. Sidecar entries
    /// with an identity are hidden from the PDF-annotation list while they are open, so a mark
    /// is never drawn twice.
    public var fileIdentity: String?
    /// The page-space boxes of a text mark the PDF already carries.
    ///
    /// A text mark this reader creates is a character range, but a foreign highlight's characters
    /// are in somebody else's text layer. These are the file's own boxes, so the adopted mark is
    /// drawn exactly where it was and can be selected without re-deriving a range. The writer
    /// never rewrites a text mark's `/QuadPoints`: its geometry belongs to the text, not to this
    /// editor.
    public var fileQuads: [StoredRect]?
    /// `/Q` of an adopted `/FreeText` annotation: `left`, `center` or `right`.
    ///
    /// Kept so a text box written by another producer keeps the alignment it was saved with
    /// when its text or box is edited. `nil` for every entry except an adopted text box.
    public var textAlignment: String?
    /// The style of a `.stamp` entry: `approved`, `reviewed`, `draft`, `confidential` or
    /// `date`. `nil` for every other kind.
    public var stampStyle: String?
    /// The picture of a `.signature` entry, exactly the bytes the reader chose (PNG or JPEG).
    /// Stored base64 in the sidecar, and re-encoded into the PDF as an image XObject on save.
    public var imageData: Data?

    private enum CodingKeys: String, CodingKey {
        case id, kind, page, start, end, color, colorIndex, note, createdAt
        case version, paths, rect, lineStart, lineEnd, strokeWidth, fontSize
        case fileIdentity, quads, textAlignment
        case stampStyle, image
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
        strokeWidth: CGFloat = 0,
        fontSize: CGFloat = 0,
        fileIdentity: String? = nil,
        fileQuads: [StoredRect]? = nil,
        textAlignment: String? = nil,
        stampStyle: String? = nil,
        imageData: Data? = nil
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
        self.fontSize = fontSize
        self.fileIdentity = fileIdentity
        self.fileQuads = fileQuads
        self.textAlignment = textAlignment
        self.stampStyle = stampStyle
        self.imageData = imageData
    }

    /// True when this entry edits an annotation the PDF already carries.
    public var isFileOwned: Bool { fileIdentity != nil }

    /// Whether the annotation's geometry is complete and finite.
    ///
    /// The sidecar encoder and the write-back path both rely on this: a mark that cannot be
    /// drawn or written must be refused before it reaches a file, not turned into an empty
    /// annotation on the page.
    public var hasValidGeometry: Bool {
        guard strokeWidth.isFinite, strokeWidth >= 0, strokeWidth <= 200 else { return false }
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
        case .stickyNote:
            guard let rect = shapeRect else { return false }
            return rect.minX.isFinite && rect.minY.isFinite
                && rect.width.isFinite && rect.height.isFinite
                && rect.width >= 1 && rect.height >= 1
        case .stamp:
            guard let rect = shapeRect else { return false }
            return rect.minX.isFinite && rect.minY.isFinite
                && rect.width.isFinite && rect.height.isFinite
                && rect.width >= 12 && rect.height >= 8
                && !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .signature:
            guard let rect = shapeRect else { return false }
            return rect.minX.isFinite && rect.minY.isFinite
                && rect.width.isFinite && rect.height.isFinite
                && rect.width >= 6 && rect.height >= 6
                && !(imageData?.isEmpty ?? true)
        case .textBox:
            guard let rect = shapeRect else { return false }
            return rect.minX.isFinite && rect.minY.isFinite
                && rect.width.isFinite && rect.height.isFinite
                && rect.width >= Self.minimumTextBoxSize.width
                && rect.height >= Self.minimumTextBoxSize.height
                && fontSize.isFinite && fontSize >= 1 && fontSize <= 400
        case .highlight, .underline, .strikeout:
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
        case .stickyNote, .textBox, .stamp, .signature:
            return shapeRect
        case .highlight, .underline, .strikeout:
            return nil
        }
    }

    /// A copy moved by `dx`/`dy` in page points.
    public func translated(by dx: CGFloat, dy: CGFloat) -> Annotation {
        guard kind.isPlacement else { return self }
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
        fileIdentity = try values.decodeIfPresent(String.self, forKey: .fileIdentity)
        fileQuads = try values.decodeIfPresent([StoredRect].self, forKey: .quads)
        textAlignment = try values.decodeIfPresent(String.self, forKey: .textAlignment)
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
        } else if kind.isPlacedText {
            let version = try values.decodeIfPresent(Int.self, forKey: .version)
            guard version == Self.placedTextVersion else {
                throw DecodingError.dataCorruptedError(
                    forKey: .version,
                    in: values,
                    debugDescription: "placed-text annotation schema \(version.map(String.init) ?? "missing") is not supported"
                )
            }
            start = 0
            end = 0
            note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""
            fontSize = CGFloat(try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? 0)
            if let rect = try values.decodeIfPresent(StoredRect.self, forKey: .rect) {
                shapeRect = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
            }
        } else if kind.isStampArtwork {
            let expected = kind == .stamp ? Self.stampVersion : Self.signatureVersion
            let version = try values.decodeIfPresent(Int.self, forKey: .version)
            guard version == expected else {
                throw DecodingError.dataCorruptedError(
                    forKey: .version,
                    in: values,
                    debugDescription: "stamp annotation schema \(version.map(String.init) ?? "missing") is not supported"
                )
            }
            start = 0
            end = 0
            note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""
            stampStyle = try values.decodeIfPresent(String.self, forKey: .stampStyle)
            imageData = try values.decodeIfPresent(Data.self, forKey: .image)
            if let rect = try values.decodeIfPresent(StoredRect.self, forKey: .rect) {
                shapeRect = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
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
        if (kind.isPlacement), !hasValidGeometry {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: values,
                debugDescription: "\(kind.rawValue) annotation has incomplete or non-finite geometry"
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
            case .stickyNote, .textBox, .stamp, .signature,
                 .highlight, .underline, .strikeout:
                break
            }
        } else if kind.isPlacedText {
            try values.encode(Self.placedTextVersion, forKey: .version)
            if let rect = shapeRect {
                try values.encode(StoredRect(x: Double(rect.minX), y: Double(rect.minY),
                                             width: Double(rect.width), height: Double(rect.height)),
                                  forKey: .rect)
            }
            try values.encode(Double(fontSize), forKey: .fontSize)
        } else if kind.isStampArtwork {
            try values.encode(
                kind == .stamp ? Self.stampVersion : Self.signatureVersion,
                forKey: .version)
            if let rect = shapeRect {
                try values.encode(StoredRect(x: Double(rect.minX), y: Double(rect.minY),
                                             width: Double(rect.width), height: Double(rect.height)),
                                  forKey: .rect)
            }
            if let stampStyle { try values.encode(stampStyle, forKey: .stampStyle) }
            if let imageData { try values.encode(imageData, forKey: .image) }
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
        if let fileIdentity { try values.encode(fileIdentity, forKey: .fileIdentity) }
        if let fileQuads { try values.encode(fileQuads, forKey: .quads) }
        if let textAlignment { try values.encode(textAlignment, forKey: .textAlignment) }
    }
}

/// A selection: a page and an inclusive character range in its text layer.
    public struct Selection: Equatable, Sendable {
        public let page: Int
        public let range: ClosedRange<Int>
    }

    @Published public private(set) var selection: Selection?

    /// A passage the AI chat is pointing at. This is deliberately **not** an annotation: it is
    /// drawn for a moment, fades in three steps and disappears, and nothing is written to the
    /// PDF or the sidecar. `id` makes two clicks on the same page restart the fade.
    public struct AISourceHighlight: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let page: Int
        /// Page-local view space (points, top-left origin, 100% zoom).
        public let rects: [CGRect]
        public var phase: Phase

        public enum Phase: Equatable, Sendable {
            case full, soft, faint
        }

        public init(id: UUID = UUID(), page: Int, rects: [CGRect], phase: Phase = .full) {
            self.id = id
            self.page = page
            self.rects = rects
            self.phase = phase
        }
    }

    @Published public private(set) var aiSourceHighlight: AISourceHighlight?
    private var aiSourceHighlightTask: Task<Void, Never>?

    /// A rectangle the reader marked for redaction, pending until the explicit apply command.
    public struct PendingRedaction: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let page: Int
        /// Page-local view space (points, top-left origin, 100% zoom).
        public let rect: CGRect

        public init(id: UUID = UUID(), page: Int, rect: CGRect) {
            self.id = id
            self.page = page
            self.rect = rect
        }
    }

    /// Areas marked for redaction but not applied yet. They are drawn on the canvas, and
    /// clearing them leaves the file completely untouched.
    @Published public private(set) var pendingRedactions: [PendingRedaction] = []
    @Published public private(set) var redactionBusy = false
    /// The last applied redaction, for the status line and the checks.
    @Published public private(set) var lastRedactionReport: RedactionReport?

    /// What a floating preview is *for*. It decides what the panel's body shows, because the
    /// four cases genuinely want four different things.
    public enum ReferencePreviewKind: Equatable, Sendable {
        /// A bibliography entry a citation resolved to: the panel shows the entry **as text**.
        /// The reader wants to read the reference, and a crop of a two-column bibliography page
        /// makes that harder, not easier.
        case reference
        /// A figure or table caption: the panel shows the rendered region. A picture of a figure
        /// is the point.
        case figure
        /// A section, chapter or appendix reference (`Sec. 2`, `Chapter IV`, `Appendix A`): a
        /// picture of the target page is useless, so the panel shows the section's title as text
        /// and leaves the page number as the click target.
        case section
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
        /// A `.section` preview's title from the document outline. `nil` means the page has no
        /// outline entry; the panel then shows `sectionReference` and says why.
        public let sectionTitle: String?
        /// A `.section` preview's reference as printed (`Sec. 2`), used as the fallback title and
        /// shown for context. `nil` only when no reference text could be read at all.
        public let sectionReference: String?
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

    /// Where the reader was before a jump the preview started.
    ///
    /// `scrollYPt` is the **exact** content offset, not a page number rounded to a page top: a
    /// reader halfway down a long page must come back halfway down it. `selection` and `preview`
    /// ride along because both are already values in memory — returning to a highlighted
    /// paragraph should not lose the highlight — and they cost a copy of references, not a
    /// re-render.
    public struct ReaderLocation: Equatable, Sendable {
        /// 0-based, the page under the viewport's top edge.
        public let page: Int
        /// Content offset in points, exactly as ``AppState/scrollYPt`` held it.
        public let scrollYPt: CGFloat
        public let selection: Selection?
        /// The preview that was open when the jump was made. Kept for context; Back does not
        /// reopen a panel the reader has since closed.
        public let preview: ReferencePreview?
    }

    @Published public private(set) var referencePreview: ReferencePreview?
    /// A pinned preview stays exactly as it is while the reader keeps working.
    ///
    /// Pinning is a property of the preview, not of a second panel: while it is set, a new
    /// interaction in the document that would normally replace the preview is refused instead of
    /// replacing it (`openReferencePreview`). Unpinning only clears the flag; the next preview
    /// request updates the panel again. Closing the preview or leaving the document clears it, so
    /// a pin can never outlive the content it protects.
    @Published public private(set) var referencePreviewPinned = false
    /// Page content for the preview panel (its own render surface).
    @Published public private(set) var referencePreviewPages: [CanvasPage] = []
    @Published public private(set) var referencePreviewZoom: CGFloat = 1

    /// Width the preview panel gives the page, in points.
    private var referencePreviewWidthPt: CGFloat = 480
    private var referencePreviewHeightPt: CGFloat = 380
    private var previewEpoch: UInt64 = 0
    /// Click/content identity, independent of raster requests caused by panel resizing.
    private var previewLookupEpoch: UInt64 = 0
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
                                 region: preview.region, entries: preview.entries,
                                 sectionTitle: preview.sectionTitle,
                                 sectionReference: preview.sectionReference)
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
                             region: entry.region, entries: preview.entries,
                             sectionTitle: preview.sectionTitle,
                             sectionReference: preview.sectionReference)
    }

    public func showFullPreviewPage() {
        guard let preview = referencePreview else { return }
        // The page image is exactly what "Full page" is for, so the kind changes with the view.
        // A section preview's text body is traded for the page it points at, which is the one
        // place its crop is still the point.
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
    /// A `.reference` or `.section` preview never rasterizes anything: the entry or section title
    /// *is* the body, so the panel opens immediately and no page, tile or prefetch work is
    /// started for it.
    ///
    /// Returns `false` when the request was refused. The only refusal that is not an invalid
    /// target is a **pinned** preview: a new interaction in the document must not replace what
    /// the reader pinned, so the panel keeps its original content until it is unpinned. A request
    /// for the preview already on screen (a viewport re-fit, for instance) is not a replacement
    /// and still runs.
    @discardableResult
    public func openReferencePreview(
        page: Int,
        title: String,
        from source: String,
        kind: ReferencePreviewKind,
        anchor: CGRect? = nil,
        region: CGRect? = nil,
        entries: [CitationEntry] = [],
        sectionTitle: String? = nil,
        sectionReference: String? = nil
    ) -> Bool {
        guard let document, page >= 0, page < document.pageCount else { return false }
        if let region {
            guard region.minX.isFinite, region.minY.isFinite, region.width.isFinite,
                  region.height.isFinite, region.width > 0, region.height > 0 else { return false }
        }
        let requested = ReferencePreview(
            page: page,
            title: title,
            source: source,
            kind: kind,
            anchor: anchor,
            region: region,
            entries: entries,
            sectionTitle: sectionTitle,
            sectionReference: sectionReference
        )
        if referencePreviewPinned, let current = referencePreview, current != requested {
            statusMessage = "Preview pinned — unpin it to preview a new reference"
            return false
        }
        if requested != referencePreview { previewLookupEpoch &+= 1 }
        previewEpoch &+= 1
        let request = previewEpoch
        referencePreviewPages = []
        referencePreviewScrollYPt = 0
        referencePreviewError = nil
        referencePreviewLoading = true
        referencePreview = requested

        if !entries.isEmpty {
            // stderr, not print: it is flushed immediately and survives SIGTERM, which is how
            // the "the panel received every entry" claim stays verifiable in the dev hooks.
            let labels = entries.map(\.label).joined(separator: ", ")
            FileHandle.standardError.write(
                Data("lyra-reader-preview: \"\(title)\" lists \(entries.count) entries: \(labels)\n".utf8)
            )
        }

        if kind == .reference || kind == .section {
            // Nothing to rasterize: the panel's body is text the shell already has. Reporting
            // "loading" here would be a lie and leaving it set would keep the panel's spinner up
            // forever.
            referencePreviewLoading = false
            if kind == .reference {
                FileHandle.standardError.write(
                    Data("lyra-reader-preview: entry text for \"\(title)\" (\(entries.count) entries, \(entries.reduce(0) { $0 + $1.text.count }) characters)\n".utf8)
                )
            } else {
                FileHandle.standardError.write(
                    Data("lyra-reader-preview: section text for \"\(title)\" on page \(page + 1) (no crop)\n".utf8)
                )
            }
            return true
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
                    heightPt: region.height,
                    // A figure/table crop is shown on the panel's own colour, so its white
                    // page margin must be transparent. A whole-page preview keeps its paper.
                    transparentBackground: kind == .figure
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
                Data("lyra-reader-preview: page \(page + 1) ready (\(image.pixelWidth)x\(image.pixelHeight) px)\n".utf8)
            )
        }
        return true
    }

    public func closeReferencePreview() {
        previewLookupEpoch &+= 1
        previewEpoch &+= 1
        referencePreviewPinned = false
        referencePreviewLoading = false
        referencePreviewError = nil
        referencePreviewScrollYPt = 0
        referencePreview = nil
        referencePreviewPages = []
    }

    // MARK: - Preview actions (T4.8)

    /// Whether the current preview can be pinned. Every preview kind can: pinning protects the
    /// panel, not one body.
    public var canPinReferencePreview: Bool { referencePreview != nil }

    /// Pins or unpins the current preview. A pinned preview is frozen: new interactions in the
    /// document are refused instead of replacing it. Unpinning re-arms the ordinary update path;
    /// the next preview request lands in the same panel.
    public func toggleReferencePreviewPin() {
        guard referencePreview != nil else { return }
        referencePreviewPinned.toggle()
        statusMessage = referencePreviewPinned
            ? "Preview pinned — new interactions will not replace it"
            : "Preview unpinned — the next preview replaces it"
    }

    /// Whether a citation preview can copy a BibTeX entry.
    ///
    /// Only a `.reference` preview has bibliography entries, and the only BibTeX the app can
    /// generate is the open document's (the same string Document Information shows). A printed
    /// bibliography entry is unstructured text, not recognised metadata, so there is nothing
    /// honest to synthesise for the cited work when the document itself has no metadata.
    public var canCopyPreviewBibtex: Bool {
        referencePreview?.kind == .reference && canCopyMetadataBibtex
    }

    /// Copies the open document's generated BibTeX from a citation preview: the **same** payload
    /// `copyMetadataBibtex` puts on the clipboard. Returns `false` — and leaves the clipboard
    /// alone — when this is not a citation preview or no metadata (and therefore no entry) is
    /// available; the status line says which.
    @discardableResult
    public func copyPreviewBibtex() -> Bool {
        guard referencePreview?.kind == .reference else {
            statusMessage = "BibTeX is available only from a citation preview"
            return false
        }
        guard canCopyMetadataBibtex else {
            statusMessage = "No BibTeX is available for this document"
            return false
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(metadataBibtex, forType: .string)
        statusMessage = "Copied \(metadataBibtex.count) characters of BibTeX"
        return true
    }

    /// Copies one bibliography entry's text. The panel already lets the reader select the text;
    /// this is the explicit affordance next to it.
    @discardableResult
    public func copyPreviewEntryText(_ entry: CitationEntry) -> Bool {
        guard referencePreview?.kind == .reference else {
            statusMessage = "Entry text is available only from a citation preview"
            return false
        }
        guard !entry.text.isEmpty else {
            statusMessage = "This entry has no text to copy"
            return false
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        statusMessage = "Copied \(entry.text.count) characters of entry text"
        return true
    }

    /// Moves a freshly opened window to the page and position a preview points at.
    ///
    /// The preview carries the target rectangle in page view space, so this is the same
    /// arithmetic a preview raster uses: page top plus the rectangle's top, less a small reading
    /// margin. The offset is clamped by the same `scrollYPt` rules as every other scroll, so a
    /// target near the end of a page still lands on it. A preview without a region (a plain page
    /// or a section) starts at the page top.
    public func reveal(page: Int, region: CGRect?) {
        guard let document, page >= 0, page < document.pageCount else { return }
        guard let region, region.width > 0, region.height > 0,
              region.minY.isFinite else {
            gotoPage(page)
            return
        }
        cancelScrollGlide()
        let top = engine.pageTopPt(page, gapPt: pageGapPt, layout: layoutMode)
        let margin: CGFloat = 24
        scrollYPt = clampedScrollOffset(top + region.minY - margin)
        reloadVisiblePages()
        schedulePositionSave()
        statusMessage = "Opened page \(page + 1) at the referenced position"
    }

    // MARK: - Preview jumps and Back

    /// How many past (and future) locations one window remembers.
    ///
    /// Each direction's stack is trimmed to this many entries when a jump or a back would exceed
    /// it, so a reader who follows the same preview twenty-five times keeps the twenty most
    /// recent places. Twenty entries of value types is bounded memory, and far more than a
    /// preview jump normally needs.
    public static let navigationHistoryLimit = 20

    @Published public private(set) var backHistory: [ReaderLocation] = []
    @Published public private(set) var forwardHistory: [ReaderLocation] = []
    public var canGoBack: Bool { !backHistory.isEmpty }
    public var canGoForward: Bool { !forwardHistory.isEmpty }

    /// A jump the **preview** started: record where the reader is, then move.
    ///
    /// Only this entry point records history. Page turns, sidebar jumps, tab restores and Back
    /// itself all move the reader without becoming entries, which is what keeps programmatic
    /// scroll restoration out of the stack.
    public func jumpFromPreview(to page: Int) {
        guard let document, page >= 0, page < document.pageCount else { return }
        recordReaderLocation()
        gotoPage(page)
    }

    /// Returns to the reader's previous location. True when there was one.
    @discardableResult
    public func goBack() -> Bool {
        guard let target = backHistory.popLast() else { return false }
        forwardHistory.append(currentReaderLocation())
        trimNavigationHistory()
        applyReaderLocation(target, message: "Back to page")
        return true
    }

    /// Moves forward again. True when the forward branch had an entry.
    @discardableResult
    public func goForward() -> Bool {
        guard let target = forwardHistory.popLast() else { return false }
        backHistory.append(currentReaderLocation())
        trimNavigationHistory()
        applyReaderLocation(target, message: "Forward to page")
        return true
    }

    /// Leaving a document throws its history away; the document reset path calls this.
    public func clearNavigationHistory() {
        guard !backHistory.isEmpty || !forwardHistory.isEmpty else { return }
        backHistory = []
        forwardHistory = []
    }

    /// Whether a page's text layer is already in memory.
    ///
    /// The section-reference click path reads the clicked line to tell a `Sec. 2` link from a
    /// generic page link; a page whose layer has not arrived yet is simply previewed as a page
    /// rather than guessed at. Exposed so the native checks can wait for the real precondition
    /// instead of sleeping.
    public func hasTextLayer(_ page: Int) -> Bool {
        textPages[page] != nil
    }

    private func currentReaderLocation() -> ReaderLocation {
        ReaderLocation(page: max(0, currentPage - 1), scrollYPt: scrollYPt,
                       selection: selection, preview: referencePreview)
    }

    private func recordReaderLocation() {
        backHistory.append(currentReaderLocation())
        // A new jump has a new future: the forward branch it replaced is stale.
        forwardHistory.removeAll()
        trimNavigationHistory()
    }

    private func trimNavigationHistory() {
        if backHistory.count > Self.navigationHistoryLimit {
            backHistory.removeFirst(backHistory.count - Self.navigationHistoryLimit)
        }
        if forwardHistory.count > Self.navigationHistoryLimit {
            forwardHistory.removeFirst(forwardHistory.count - Self.navigationHistoryLimit)
        }
    }

    /// Restores a remembered **offset**, not just its page. `reloadVisiblePages` then re-derives
    /// the current page, visible placements and selection highlights from it.
    private func applyReaderLocation(_ location: ReaderLocation, message: String) {
        cancelScrollGlide()
        // Clamp only if the content shrank since (a window resize or a layout change); on the
        // ordinary path this is exactly the remembered number.
        scrollYPt = clampedScrollOffset(location.scrollYPt)
        selection = location.selection
        selectionAnchor = nil
        reloadVisiblePages()
        schedulePositionSave()
        statusMessage = "\(message) \(currentPage)"
    }

    /// Annotations the **PDF itself carries**, in view space — highlights and notes somebody
    /// else made (or the reader made in another viewer).
    ///
    /// A different thing from `annotations` below: that is what this reader wrote to its sidecar,
    /// this is what the file says. Both sources share sentence excerpts in the sidebar, while
    /// only the sidecar annotations can be edited here.
    @Published public private(set) var documentAnnotations: [DocumentAnnotation] = [] {
        didSet { passageTextMaps = [:]; rebuildAnnotationPassages() }
    }
    /// True while the document's own annotations are being read (the sidebar shows it).
    @Published public private(set) var documentAnnotationsLoading = false
    /// Why the document's annotations could not be read, if they could not.
    @Published public private(set) var documentAnnotationsError: String?
    private var documentAnnotationsLoadCompleted = false

    /// One annotation the reader removed from the PDF's annotation list but has not written to a
    /// file yet.
    ///
    /// The deletion is a pending change, like an unsaved highlight: the PDF on disk still has
    /// the annotation until "Save Copy" or "Save and Replace Original". The identity is what the
    /// writer resolves; the page is kept for the sidebar and for the report.
    public struct FileAnnotationDeletion: Identifiable, Codable, Equatable, Sendable {
        public let identity: String
        public let page: Int
        public var id: String { identity }

        public init(identity: String, page: Int) {
            self.identity = identity
            self.page = page
        }
    }

    /// Annotations deleted in this session, waiting for the next explicit save.
    @Published public private(set) var pendingFileDeletions: [FileAnnotationDeletion] = [] {
        didSet { persistPendingAnnotationState() }
    }
    /// `/Popup` presence for every annotation the file carries, keyed by identity. An adopted
    /// entry is no longer in `documentAnnotations`, but the file still owns its popup, so the
    /// eraser guard needs this to survive adoption.
    private var documentPopupFlags: [String: Bool] = [:]

    /// True when at least one annotation the PDF carries is marked for deletion.
    public var hasPendingFileDeletions: Bool { !pendingFileDeletions.isEmpty }

    /// The identities of adopted file annotations, for hiding their PDF copies exactly once.
    public var adoptedFileAnnotationIDs: Set<String> {
        Set(annotations.compactMap(\.fileIdentity))
    }

    /// What this reader can do with an annotation the PDF carries.
    ///
    /// One policy for every surface: click selection, the eraser, the sidebar and the save
    /// writer all ask this, so a kind cannot be refused on the page and silently accepted in the
    /// list. A reply is editable only through its thread (editing it directly would still be
    /// safe, but deleting a parent would then have to delete the user's adopted entry too, which
    /// this version does not model).
    public enum DocumentAnnotationEditability: Equatable, Sendable {
        case editable
        case unsupported(reason: String)
    }

    /// Why an annotation the PDF carries cannot be edited here, stated once.
    public static func documentAnnotationUnsupportedReason(_ annotation: DocumentAnnotation) -> String? {
        switch documentAnnotationEditability(annotation) {
        case .editable:
            return nil
        case .unsupported(let reason):
            return reason
        }
    }

    /// The one editability decision. Called by the canvas, the eraser, the sidebar and the
    /// writer; nothing re-derives it.
    public static func documentAnnotationEditability(
        _ annotation: DocumentAnnotation
    ) -> DocumentAnnotationEditability {
        if annotation.isReply {
            return .unsupported(
                reason: "This is a reply. Edit or delete the annotation at the top of the thread; "
                    + "the replies stay attached to it.")
        }
        guard annotation.visible else {
            return .unsupported(reason: "This annotation is hidden by the file (/F).")
        }
        switch annotation.kind {
        case "highlight", "underline", "strikeout", "text", "freeText",
             "ink", "square", "circle", "line", "stamp":
            break
        case "squiggly":
            return .unsupported(
                reason: "LyraReader has no editable model for /Squiggly; editing it would have to "
                    + "change the mark's subtype.")
        default:
            return .unsupported(
                reason: "LyraReader has no editable model for a /\(annotation.kind) annotation yet.")
        }
        if annotation.kind == "ink" && annotation.inkPaths.isEmpty {
            return .unsupported(reason: "This ink annotation carries no /InkList to move or draw.")
        }
        if annotation.kind == "line" && (annotation.lineStart == nil || annotation.lineEnd == nil) {
            return .unsupported(reason: "This line annotation carries no /L endpoints.")
        }
        if annotation.kind == "stamp",
           annotation.stampImageData == nil,
           (annotation.stampText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let reason = annotation.stampImageError {
            return .unsupported(
                reason: "This stamp's picture could not be decoded (\(reason)), so it can be "
                    + "deleted here but not moved, resized or edited.")
        }
        if annotation.drawing == .skipped {
            return .unsupported(reason: "This annotation is not drawn by the reader.")
        }
        return .editable
    }

    /// A copy of a file annotation in the editable model, or `nil` when the kind cannot be
    /// represented.
    ///
    /// Text marks keep the file's fixed page-space quads; they have no character range in this
    /// reader's text layer. Every other kind maps to the reader's own geometry, with the same
    /// coordinate convention (page space, top-left origin) `DocumentAnnotation` already uses.
    public static func adoptedAnnotation(
        from document: DocumentAnnotation,
        id: UUID = UUID(),
        now: Date = Date()
    ) -> Annotation? {
        guard documentAnnotationEditability(document) == .editable else { return nil }
        let kind: Annotation.Kind
        switch document.kind {
        case "highlight": kind = .highlight
        case "underline": kind = .underline
        case "strikeout": kind = .strikeout
        case "text": kind = .stickyNote
        case "freeText": kind = .textBox
        case "ink": kind = .ink
        case "square": kind = .square
        case "circle": kind = .circle
        case "line": kind = document.lineArrow ? .arrow : .line
        case "stamp":
            if !(document.stampText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                kind = .stamp
            } else if document.stampImageData != nil {
                kind = .signature
            } else {
                return nil
            }
        default: return nil
        }
        let opacity = min(max(document.opacity ?? 1.0, 0.0), 1.0)
        let alpha = UInt8(min(max((opacity * 255.0).rounded(), 0), 255))
        let box = CGRect(x: document.xPt, y: document.yPt,
                         width: document.widthPt, height: document.heightPt)
        let width = min(max(document.borderWidthPt ?? 1.0, 0.1), 200.0)
        let colour: AnnotationColor
        if let fileColour = document.color {
            colour = AnnotationColor(red: fileColour.red, green: fileColour.green,
                                     blue: fileColour.blue, alpha: alpha)
        } else if kind == .stickyNote {
            colour = AnnotationColor(red: AnnotationColor.defaultNote.red,
                                     green: AnnotationColor.defaultNote.green,
                                     blue: AnnotationColor.defaultNote.blue, alpha: alpha)
        } else if kind == .stamp {
            let style = StampStyle(fileStyle: document.stampStyle)?.color
                ?? AnnotationColor(red: 0x80, green: 0x80, blue: 0x80, alpha: 255)
            colour = AnnotationColor(red: style.red, green: style.green, blue: style.blue,
                                     alpha: alpha)
        } else {
            let grey = UInt8(min(max((opacity * 255.0).rounded(), 0), 255))
            colour = AnnotationColor(red: 0x80, green: 0x80, blue: 0x80, alpha: grey)
        }

        switch kind {
        case .highlight, .underline, .strikeout:
            let quads = document.boxes.map {
                Annotation.StoredRect(x: Double($0.xPt), y: Double($0.yPt),
                                      width: Double($0.widthPt),
                                      height: Double($0.heightPt))
            }
            guard !quads.isEmpty else { return nil }
            return Annotation(
                id: id, kind: kind, page: document.page, start: 0, end: 0,
                color: colour, note: document.contents ?? "", createdAt: now,
                fileIdentity: document.id, fileQuads: quads)
        case .stickyNote:
            guard box.width > 0, box.height > 0 else { return nil }
            return Annotation(
                id: id, kind: kind, page: document.page, start: 0, end: 0,
                color: colour, note: document.contents ?? "", createdAt: now,
                shapeRect: box, fileIdentity: document.id)
        case .textBox:
            guard box.width >= 1, box.height >= 1 else { return nil }
            let size = min(max(document.fontSizePt ?? Annotation.defaultTextBoxFontSize, 1), 400)
            return Annotation(
                id: id, kind: kind, page: document.page, start: 0, end: 0,
                color: colour, note: document.contents ?? "", createdAt: now,
                shapeRect: box, fontSize: size, fileIdentity: document.id,
                textAlignment: document.alignment)
        case .ink:
            guard !document.inkPaths.isEmpty else { return nil }
            return Annotation(
                id: id, kind: kind, page: document.page, start: 0, end: 0,
                color: colour, note: document.contents ?? "", createdAt: now,
                inkPaths: document.inkPaths, strokeWidth: width, fileIdentity: document.id)
        case .square, .circle:
            guard box.width > 0, box.height > 0 else { return nil }
            // The sidecar stores the stroke's centre line; a PDF `/Rect` is its outer edge.
            let inset = box.insetBy(dx: width / 2, dy: width / 2)
            guard inset.width > 0, inset.height > 0 else { return nil }
            return Annotation(
                id: id, kind: kind, page: document.page, start: 0, end: 0,
                color: colour, note: document.contents ?? "", createdAt: now,
                shapeRect: inset, strokeWidth: width, fileIdentity: document.id)
        case .line, .arrow:
            guard let start = document.lineStart, let end = document.lineEnd else { return nil }
            return Annotation(
                id: id, kind: kind, page: document.page, start: 0, end: 0,
                color: colour, note: document.contents ?? "", createdAt: now,
                lineStart: start, lineEnd: end, strokeWidth: width,
                fileIdentity: document.id)
        case .stamp:
            let text = document.stampText ?? document.contents ?? ""
            guard box.width >= 12, box.height >= 8,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Annotation(
                id: id, kind: .stamp, page: document.page, start: 0, end: 0,
                color: colour, note: text, createdAt: now, shapeRect: box,
                fileIdentity: document.id,
                stampStyle: StampStyle(fileStyle: document.stampStyle)?.rawValue ?? "custom")
        case .signature:
            guard box.width >= 6, box.height >= 6,
                  let data = document.stampImageData, !data.isEmpty else { return nil }
            return Annotation(
                id: id, kind: .signature, page: document.page, start: 0, end: 0,
                color: colour, note: "", createdAt: now, shapeRect: box,
                fileIdentity: document.id, stampStyle: "signature", imageData: data)
        }
    }

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

    /// The annotations the reader added (highlights, underlines, ink, shapes, sticky notes and
    /// text boxes), and the file they are stored in.
    ///
    /// This is the array this version can *render and edit*. Entries a newer version wrote in
    /// a shape this one does not understand are not in here: they live in
    /// `annotationSidecarSlots` as raw JSON and are written back untouched (see
    /// `AnnotationSidecar`).
    @Published public private(set) var annotations: [Annotation] = [] {
        didSet { rebuildAnnotationPassages() }
    }
    /// The stamp style the armed stamp tool will place, or `nil` when no style is armed.
    @Published public var pendingStampStyle: StampStyle?
    /// The picture the armed signature tool will place, or `nil` when it is not armed.
    @Published public var pendingSignatureImageData: Data?
    /// The one active canvas tool. A text-markup case makes finished text selections mark
    /// themselves; the pen and shape cases draw on a drag. The eraser removes ink on a drag. The
    /// modes cannot both be active.
    @Published public var annotationTool: AnnotationTool = .select {
        didSet {
            // The form tool and the drawing tools are modes of the same canvas; choosing a
            // drawing tool leaves the form tool (and never the other way around).
            if annotationTool != .select && formToolActive {
                formToolActive = false
                formFocusedFieldID = nil
                formOpenChoiceFieldID = nil
            }
            if annotationTool != oldValue {
                // The hover halo and any draft gesture belong to the tool that was armed. A tool
                // switch from the toolbar mid-drag cannot leave a half-erased gesture behind.
                if annotationTool != .eraser {
                    eraserHoverMarkID = nil
                    cancelEraserGesture()
                }
                // A placed stamp or signature picture belongs to its own tool; leaving that tool
                // disarms it so a later click cannot place the wrong picture.
                if annotationTool != .stamp { pendingStampStyle = nil }
                if annotationTool != .signature { pendingSignatureImageData = nil }
                // Selection is the Select tool's business: arming a pen, shape, markup or the
                // eraser drops the halo instead of leaving a mark that Delete would still act on.
                cancelPendingMarkSelection()
                if selectedAnnotationID != nil { selectedAnnotationID = nil }
                // A selection on screen is drawn as the mark the tool will commit, or as the
                // ordinary blue selection when no markup tool is armed. Leaving the tool has to
                // restore that look immediately, even if no pointer sample follows.
                if selection != nil {
                    refreshSelectionOverlay()
                }
            }
        }
    }
    /// The ink stroke under an armed eraser, in `canvasAnnotationMarks` order. The overlay draws
    /// the select tool's halo around it before a press begins to cut it, so the reader sees
    /// exactly which stroke the eraser will touch.
    @Published public private(set) var eraserHoverMarkID: String?
    /// Ink strokes the eraser has shortened or removed since their absence was last written to
    /// a PDF. While this is non-empty the interface says that the PDF on disk is still unchanged.
    @Published public private(set) var erasedInkStrokeIDs: Set<UUID> = [] {
        didSet { persistPendingAnnotationState() }
    }
    /// Why a plain click last refused to select a mark the PDF itself carries.
    ///
    /// A mark with no editable model (a reply, a hidden annotation, a subtype this reader does
    /// not know) states that one reason in a banner instead of acting as if the click were never
    /// made.
    @Published public private(set) var markSelectionRefusalNotice: String?
    /// Why the eraser refused to cut a file-owned stroke: splitting it would delete review text
    /// the PDF attaches to that stroke. Persists until dismissed or the next gesture starts.
    @Published public private(set) var eraserRefusalNotice: String?
    /// The colour a newly created mark is stored in.
    ///
    /// The highlight palette's presets are translucent because a highlight sits over text. Pen
    /// and shape marks use the same hue at full opacity: a stroke is the reader's ink, not a
    /// wash over the page.
    @Published public var annotationColor: AnnotationColor = AppState.annotationPalette[0].color {
        didSet {
            // The live markup preview is drawn in this colour, so a palette change while a
            // selection is on screen has to repaint it in place.
            guard annotationColor != oldValue, annotationTool.isTextMarkup,
                  selection != nil else { return }
            refreshSelectionOverlay()
        }
    }
    /// The annotation the reader last clicked, if any. Only sidecar annotations can be selected:
    /// a PDF's own ink, shapes, notes and text are drawn but not editable, because moving them
    /// would mean rewriting somebody else's annotation.
    @Published public private(set) var selectedAnnotationID: UUID?
    /// A press that may still turn out to be a plain click on a text mark or an unselected text
    /// box.
    ///
    /// The selection is decided on mouse-up, not on the press: a drag that starts on top of a
    /// highlight must still select the text under it, and a drag inside an unselected text box
    /// must still select the text underneath. Only a press that stays inside the canvas' click
    /// slop selects the mark. The text anchor is resolved on the press so the deferred text
    /// selection starts exactly where the reader aimed.
    private struct PendingMarkSelection {
        let id: UUID
        /// The character a drag from the press point would anchor a text selection at.
        let textAnchor: (page: Int, index: Int)?
    }
    private var pendingMarkSelection: PendingMarkSelection?
    /// The mark being dragged, and where the drag started in its page's space.
    private var moveOriginalAnnotation: Annotation?
    private var moveStartPagePoint: CGPoint?
    /// The text box being resized, where the drag started, and which edge or handle it grabbed.
    private var resizeOriginalAnnotation: Annotation?
    private var resizeStartPagePoint: CGPoint?
    private var resizeHandle: TextBoxResizeHandle?
    /// The sidecar annotation whose text editor is open, and the state needed to commit or
    /// cancel that one editing session as one undoable change.
    @Published public private(set) var editingAnnotationID: UUID?
    private var editingWasCreated = false
    private var editingOriginalText = ""
    private var editingOriginalAnnotation: Annotation?
    private var editingUndoDepth = 0
    /// The annotations as they were when the current eraser drag began, and the cuts it has made
    /// so far. Both are empty when no gesture is in flight.
    private var eraserGestureBase: [Annotation]?
    /// One splitter per original path, keyed by the sidecar annotation they came from.
    private var eraserGestureSidecarSplits: [UUID: SidecarInkSplit] = [:]
    /// The same for ink the PDF carries; a split of one of those is a **cross-reader** change:
    /// the original annotation is deleted by identity and its surviving pieces become new
    /// sidecar ink.
    private var eraserGestureDocumentSplits: [String: DocumentInkSplit] = [:]
    /// File-owned strokes this drag found but must not touch: splitting one would orphan its
    /// review thread. Cached so every pointer sample does not rebuild the same sentence.
    private var eraserGestureRefusedDocumentIDs: Set<String> = []
    /// Adopted sidecar entries that are file-owned and carry review text, refused for this drag.
    private var eraserGestureRefusedSidecarIDs: Set<UUID> = []
    /// What the canvas should draw while a drag is cutting. `nil` while no gesture is in flight.
    /// Preview marks are not annotations: they carry stable, throwaway identities so a pointer
    /// sample cannot churn the model or the sidecar.
    @Published public private(set) var eraserPreviewMarks: [CanvasAnnotationMark]?
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
    /// LyraReader presets for new annotations. The legacy indexed palette below remains stable so
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
    /// Textures for the sidecar's sticky notes and text boxes: the icon and the laid-out text,
    /// keyed by every input that changes a pixel.
    private var placedGlyphTextures: [PlacedGlyphKey: PageImage] = [:]
    /// Stamp badges and signature images, keyed by every input that changes a pixel.
    private var stampGlyphTextures: [StampGlyphKey: PageImage] = [:]

    /// Whether to print the annotations handed to the canvas (`LYRA_READER_CANVAS_DUMP=1`).
    ///
    /// The canvas prints its own half of the same frame under that variable (`MetalCanvasView`),
    /// keyed by the same placement index, so "what we asked for" and "what was composited" can be
    /// read side by side. It exists because a wrong picture can come from either half, and the
    /// raster-level tests in the Rust crates can see neither.
    private let annotationDumpEnabled =
        ProcessInfo.processInfo.environment["LYRA_READER_CANVAS_DUMP"] == "1"

    private func annotationDump(_ message: String) {
        FileHandle.standardError.write(Data("lyra-reader-annot: \(message)\n".utf8))
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
        var pendingRedactions: [PendingRedaction]
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
        var formInfo: FormInfo
        var formDraft: [String: FormFieldValue]
        var formToolActive: Bool
        var formLoadCompleted: Bool
        var formError: String?
        var documentInfo: DocumentInfo?
        var documentInfoLoading: Bool
        var documentAnnotations: [DocumentAnnotation]
        var documentPopupFlags: [String: Bool]
        var pendingFileDeletions: [FileAnnotationDeletion]
        var documentAnnotationsError: String?
        var documentAnnotationsLoadCompleted: Bool
        var outline: [OutlineEntry]
        var outlineLoadCompleted: Bool
        var thumbnails: [Int: PageImage]
        var annotations: [Annotation]
        /// Ink erasures still pending a PDF write, so their banner survives a tab switch.
        var erasedInkStrokeIDs: Set<UUID>
        var bookmarks: [Bookmark]
        var preservedAnnotationEntryCount: Int
        var annotationWriteCount: Int
        var annotationCacheIsDirty: Bool
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
        var placedGlyphTextures: [PlacedGlyphKey: PageImage]
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

    /// The AI source highlight fades through three 1×1 amber textures. They use the same
    /// textured-quad pipeline as selection, so no overlay view or annotation path is involved.
    private lazy var aiSourceFullImage = PageImage(
        pixelWidth: 1,
        pixelHeight: 1,
        pointSize: .zero,
        bgra: Data([0x00, 0xB0, 0xFF, 0x66]),
        generation: 1
    )
    private lazy var aiSourceSoftImage = PageImage(
        pixelWidth: 1,
        pixelHeight: 1,
        pointSize: .zero,
        bgra: Data([0x00, 0xB0, 0xFF, 0x3D]),
        generation: 1
    )
    private lazy var aiSourceFaintImage = PageImage(
        pixelWidth: 1,
        pixelHeight: 1,
        pointSize: .zero,
        bgra: Data([0x00, 0xB0, 0xFF, 0x1A]),
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

    /// Tile-cache occupancy, for `LYRA_READER_RENDER_STATS=1` and the budget checks: bytes in
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
    /// The M0 T0.5 spike turns it on with LYRA_READER_SPIKE_SECOND_SURFACE=1.
    @Published public var showSecondSurface: Bool =
        ProcessInfo.processInfo.environment["LYRA_READER_SPIKE_SECOND_SURFACE"] == "1"

    /// Records a frame report coming from a canvas surface.
    public func updateGpuStatus(_ stats: LyraReaderFrameStats, label: String) {
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

    /// Domain the right panel's width/visibility are remembered in. The app uses `.standard`; a
    /// check can pass an isolated suite so "remembered across launches" is proved without
    /// touching the reader's own preferences.
    private let panelDefaults: UserDefaults

    /// Whether the `LYRA_READER_OPEN` launch hook has already opened its document.
    ///
    /// One process launches once. With a window per session there is an `AppState` per window, and
    /// the hook must stay what it says: the document *this launch* was given.
    private static var launchDocumentConsumed = false

    /// `tileCacheBudgetBytes` pins the tile-cache budget instead of resolving it from the
    /// environment and the `cacheBudgetMB` setting; the checks use it so their arithmetic does
    /// not depend on how the machine running them is configured.
    public init(engine: PDFEngine? = nil, tileCacheBudgetBytes: Int? = nil,
                preferFullPageRasters: Bool? = nil,
                panelDefaults: UserDefaults = .standard) {
        self.panelDefaults = panelDefaults
        self.preferFullPageRasters = preferFullPageRasters
            ?? (ProcessInfo.processInfo.environment["LYRA_READER_SHARP_PAGE_RASTERS"] != "0")
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

        if Self.usesStoredSidebarTab {
            sidebarTab = SidebarTab.restored()
        }
        if Self.usesStoredSidePanelPreferences {
            rightPanelWidthPt = ReaderSidePanelPreferences.width(defaults: panelDefaults)
            rightPanelVisible = ReaderSidePanelPreferences.isVisible(defaults: panelDefaults)
        }

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
        // (`LYRA_READER_OPEN=/path/to.pdf LyraReader`), which also lets a headless run
        // exercise the whole Swift → UniFFI → PDFium path.
        //
        // **Once per process.** The hook means "the document this launch was given", and a launch
        // makes exactly one window; since each window now builds its own `AppState`
        // (`ReaderSession`), consuming it per state would re-open the same file in every window
        // the reader opens afterwards. The first state in the process — the first window's — is
        // the one the hook belongs to.
        if !AppState.launchDocumentConsumed,
           let path = ProcessInfo.processInfo.environment["LYRA_READER_OPEN"], !path.isEmpty {
            AppState.launchDocumentConsumed = true
            open(url: URL(fileURLWithPath: path))
            // Optional 1-based page for headless checks: LYRA_READER_OPEN_PAGE=3
            if let raw = ProcessInfo.processInfo.environment["LYRA_READER_OPEN_PAGE"],
               let page = Int(raw), page > 0 {
                currentPage = page
            }
            if let raw = ProcessInfo.processInfo.environment["LYRA_READER_ZOOM"],
               let zoom = Int(raw), zoom > 0 {
                zoomPercent = zoom
                invalidateTiles()
            }
            if let raw = ProcessInfo.processInfo.environment["LYRA_READER_SCROLL"],
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
                Data("lyra-reader-tabs: \(tabs.count) tab(s), active \(activeTabIndex.map(String.init) ?? "none")\n".utf8)
            )

            // Development aid: report the sidebar's data so it can be checked headlessly.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self else { return }
                let line = "lyra-reader-sidebar: outline \(self.outline.count) entries, thumbnails \(self.thumbnails.count)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }

            // Development aid: LYRA_READER_SELECT="x1,y1;x2,y2" (content points) selects
            // between two points and copies, so the text path can be verified headlessly.
            if let raw = ProcessInfo.processInfo.environment["LYRA_READER_SELECT"], !raw.isEmpty {
                selectForVerification(raw)
            }

            // Development aid: LYRA_READER_CLICK="x,y" (content points) performs the click
            // path, so citation following is verifiable without a mouse.
            if let raw = ProcessInfo.processInfo.environment["LYRA_READER_CLICK"], !raw.isEmpty {
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
                        let line = "lyra-reader-click: (\(parts[0]),\(parts[1])) link=\(followed) citation=\(cited) figure=\(figured) status=\(self.statusMessage)\n"
                        FileHandle.standardError.write(Data(line.utf8))
                    }
                }
            }

            // Development aid: LYRA_READER_PREVIEW=<page> opens the reference panel, so M4
            // is verifiable without clicking a link. LYRA_READER_PREVIEW_REGION="x,y,w,h"
            // (view-space points) shows just that rectangle — the figure/table case.
            if let raw = ProcessInfo.processInfo.environment["LYRA_READER_PREVIEW"],
               let page = Int(raw), page > 0 {
                var region: CGRect?
                if let spec = ProcessInfo.processInfo.environment["LYRA_READER_PREVIEW_REGION"] {
                    let parts = spec.split(separator: ",").compactMap { Double($0) }
                    if parts.count == 4 {
                        region = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
                    }
                }
                openReferencePreview(
                    page: page - 1,
                    title: region == nil ? "Page \(page)" : "Figure on page \(page)",
                    from: "LYRA_READER_PREVIEW",
                    kind: region == nil ? .page : .figure,
                    region: region
                )
            }

            // Development aid: LYRA_READER_ANNOTATE="x1,y1;x2,y2" selects between two points
            // and highlights, so annotations are verifiable without a mouse.
            if let raw = ProcessInfo.processInfo.environment["LYRA_READER_ANNOTATE"], !raw.isEmpty {
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

            // Development aid: LYRA_READER_SCROLL_AFTER=<ms> scrolls that long after launch
            // (LYRA_READER_SCROLL_FRACTION, default 0.5), so a quit or a kill can be aimed
            // inside the position debounce window instead of racing the app's startup.
            if let raw = ProcessInfo.processInfo.environment["LYRA_READER_SCROLL_AFTER"],
               let milliseconds = Int(raw), milliseconds >= 0 {
                let fraction = ProcessInfo.processInfo.environment["LYRA_READER_SCROLL_FRACTION"]
                    .flatMap(Double.init) ?? 0.5
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(milliseconds))
                    guard let self, self.document != nil else { return }
                    self.scroll(toFraction: fraction)
                    let line = "lyra-reader-position: hook scrolled to \(Int(self.scrollYPt)) pt"
                        + " at +\(milliseconds) ms (\(fraction) of the content)\n"
                    FileHandle.standardError.write(Data(line.utf8))
                }
            }

            // Measurement-only input calls the model method used by wheel events, paced
            // by wall time without waiting for rasters. It bypasses scrollWheel's immediate
            // canvas draw, exercising the queued redraw path rather than NSEvent delivery.
            if let raw = ProcessInfo.processInfo.environment["LYRA_READER_SCROLL_TRACE_SECONDS"],
               let seconds = Double(raw), seconds.isFinite, seconds > 0, seconds <= 120 {
                let speed = Double(ProcessInfo.processInfo.environment["LYRA_READER_SCROLL_TRACE_SPEED"] ?? "") ?? 600
                if speed.isFinite && speed > 0 && speed <= 10000 {
                    let epoch = documentEpoch
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(2))
                        guard let self, epoch == self.documentEpoch else { return }
                        self.scroll(toFraction: 0)
                        let start = ProcessInfo.processInfo.systemUptime
                        var previous = start
                        FileHandle.standardError.write(Data("lyra-reader-scroll-trace: {\"kind\":\"start\",\"time\":\(start)}\n".utf8))
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(1000.0 / 60.0))
                            guard epoch == self.documentEpoch, self.document != nil else { return }
                            let now = ProcessInfo.processInfo.systemUptime
                            let end = min(now, start + seconds)
                            self.scroll(byScreenPoints: CGFloat((end - previous) * speed))
                            previous = end
                            let line = "lyra-reader-scroll-trace: {\"kind\":\"tick\",\"time\":\(now),\"y\":\(self.scrollYPt),\"pending\":\(self.pendingTiles.count),\"in_flight\":\(self.tilesInFlight.count)}\n"
                            FileHandle.standardError.write(Data(line.utf8))
                            if now >= start + seconds { break }
                        }
                        let end = ProcessInfo.processInfo.systemUptime
                        FileHandle.standardError.write(Data("lyra-reader-scroll-trace: {\"kind\":\"end\",\"time\":\(end)}\n".utf8))
                    }
                }
            }

            // Development aid: LYRA_READER_ZOOM_SEQUENCE="100,400,100" applies each zoom level
            // in turn, LYRA_READER_ZOOM_STEP_MS apart (default 1200 ms), so the raster cost of
            // a zoom-in → zoom-out → zoom-in sequence is measurable headlessly: every step logs
            // the tile cache's cumulative insertion counter, and the difference between two
            // steps is how many tiles that leg rasterized. Zoom changes here go through the
            // same path as the UI's (`zoomPercent` + `reloadVisiblePages`), *without*
            // `invalidateTiles`, because dropping the cache would answer the question by
            // construction.
            if let raw = ProcessInfo.processInfo.environment["LYRA_READER_ZOOM_SEQUENCE"], !raw.isEmpty {
                let levels = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                let stepMs = Int(ProcessInfo.processInfo.environment["LYRA_READER_ZOOM_STEP_MS"] ?? "") ?? 1200
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
                        let line = "lyra-reader-zoom: step \(index) → \(self.zoomPercent)% (lod \(self.rasterLod))"
                            + " insertions \(stats.insertions) evictions \(stats.evictions)"
                            + " queue \(self.pendingTiles.count) inFlight \(self.tilesInFlight.count)\n"
                        FileHandle.standardError.write(Data(line.utf8))
                    }
                }
            }

            // Development aid: LYRA_READER_FIND="pattern" searches at launch and reports the
            // hits on stderr, so search is verifiable without typing.
            if let raw = ProcessInfo.processInfo.environment["LYRA_READER_FIND"], !raw.isEmpty {
                searchQuery = raw
                runSearch()
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(1200))
                    guard let self else { return }
                    let summary = self.searchHits.prefix(4).map { hit in
                        "p\(hit.page + 1):\(hit.snippet.prefix(28))"
                    }.joined(separator: " | ")
                    let line = "lyra-reader-find: \(self.searchHits.count) hits: \(summary)\n"
                    FileHandle.standardError.write(Data(line.utf8))
                }
            }
            // Development aid: LYRA_READER_NOTE="text" types that text into the first
            // annotation's note one character at a time (a TextField setter per keystroke), so
            // write coalescing is measurable: LYRA_READER_NOTE_INTERVAL_MS sets the delay
            // between keystrokes, LYRA_READER_NOTE_COMMIT=1 commits the field at the end.
            if let text = ProcessInfo.processInfo.environment["LYRA_READER_NOTE"], !text.isEmpty {
                let interval = Int(ProcessInfo.processInfo.environment["LYRA_READER_NOTE_INTERVAL_MS"] ?? "") ?? 30
                let commit = ProcessInfo.processInfo.environment["LYRA_READER_NOTE_COMMIT"] == "1"
                Task { @MainActor [weak self] in
                    // `LYRA_READER_ANNOTATE` needs ~2.3 s to settle a selection; typing into
                    // its annotation starts after that.
                    try? await Task.sleep(for: .milliseconds(2500))
                    guard let self, let id = self.annotations.first?.id else {
                        FileHandle.standardError.write(
                            Data("lyra-reader-annotate: note hook found no annotation to type into\n".utf8)
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
                    let line = "lyra-reader-annotate: note hook typed \(text.count) character(s)"
                        + " in \(interval) ms steps, writes so far #\(self.annotationWriteCount)\n"
                    FileHandle.standardError.write(Data(line.utf8))
                }
            }

            // Development aid: LYRA_READER_RECOVER_SIDECAR=1 runs the explicit recovery for a
            // sidecar that failed to load, so the backup path is visible on stderr.
            if ProcessInfo.processInfo.environment["LYRA_READER_RECOVER_SIDECAR"] == "1" {
                if let reason = annotationWritesBlockedReason {
                    FileHandle.standardError.write(
                        Data("lyra-reader-annotate: writes blocked: \(reason)\n".utf8)
                    )
                    let backup = recoverUnreadableAnnotationSidecar()
                    FileHandle.standardError.write(
                        Data("lyra-reader-annotate: recovery \(backup == nil ? "failed" : "backup=\(backup!.path)")\n".utf8)
                    )
                } else {
                    FileHandle.standardError.write(
                        Data("lyra-reader-annotate: recovery hook found no blocked sidecar\n".utf8)
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
        document?.title ?? "LyraReader"
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
        if deferContentTransition({[weak self] in _ = self?.open(url:url)}) {return true}
        // Keep the document the reader left behind if it belongs to a tab. The snapshot is only
        // committed after the new document actually opens, so a refused open leaves the cache and
        // the screen exactly as they were.
        let previous = prepareActiveDocumentForReplacement()
        // A direct open with no tab (the launch hook, a check) has nobody to bring the old
        // document back; its handle must go, or an untabbed open path would leak one per file.
        let orphanURL = previous == nil && activeTabIndex == nil ? document?.url : nil
        let preserveSession = previous != nil && pageEditSession.map { !Self.resolvesToSameFile(url,$0.originalURL) } == true
        guard loadDocument(url: url, restoringTabScroll: nil,preservingPageEditSessionInSnapshot:preserveSession) else { return false }
        if var previous {
            // The new open may have discarded a page-edit session on the previous document
            // (after the explicit alert). Its revision is gone, so the retained tab must not
            // bring a dead session back.
            if previous.state.pageEditSession != nil && pageEditSession == nil && !preserveSession {
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
        if let session = pageEditSession, !preservingPageEditSessionInSnapshot {
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
            loadFormInfo()
            restoreCachedPageEdits(for: url)
            return true

        } catch {
            lastError = String(describing: error)
            statusMessage = "Couldn't open the document"
            return false
        }
    }

    private func resetDocumentState() {
        let wasChanging = isChangingDocumentState
        isChangingDocumentState = true
        defer { isChangingDocumentState = wasChanging }
        contentLoadToken = UUID()
        contentEditPage = nil
        contentEditSelection = nil
        contentLinkDraft = nil
        contentEditLoading = false
        contentTextEditing = false
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
        // The history belongs to the document that is leaving; a jump from its preview must not
        // be able to scroll the next document to an offset it never had.
        clearNavigationHistory()
        invalidateTiles()
        canvasPages = []
        canvasTiles = []
        visiblePagePlacements = []
        pendingRedactions = []
        redactionBusy = false
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
        formInfo = .empty
        formDraft = [:]
        formLoading = false
        formError = nil
        formLoadCompleted = false
        formToolActive = false
        formFocusedFieldID = nil
        formOpenChoiceFieldID = nil
        formSaveInProgress = false
        documentInfo = nil
        documentPropertiesDraft = .init()
        documentInfoLoading = false
        documentInfoError = nil
        propertiesSaveInProgress = false
        documentAnnotations = []
        pendingFileDeletions = []
        documentPopupFlags = [:]
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
        clearAISourceHighlight()
        selectedAnnotationID = nil
        pendingMarkSelection = nil
        moveOriginalAnnotation = nil
        moveStartPagePoint = nil
        resizeOriginalAnnotation = nil
        resizeStartPagePoint = nil
        resizeHandle = nil
        editingAnnotationID = nil
        editingWasCreated = false
        editingOriginalText = ""
        editingUndoDepth = 0
        annotationTool = .select
        transitionProgressOverride = nil
        annotations = []
        bookmarks = []
        erasedInkStrokeIDs = []
        eraserHoverMarkID = nil
        markSelectionRefusalNotice = nil
        eraserRefusalNotice = nil
        eraserGestureBase = nil
        eraserGestureSidecarSplits = [:]
        eraserGestureDocumentSplits = [:]
        eraserGestureRefusedDocumentIDs = []
        eraserGestureRefusedSidecarIDs = []
        eraserPreviewMarks = nil
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
        placedGlyphTextures = [:]
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

    /// The inset the Fit Width and Fit Page presets leave between a page edge and the viewport
    /// edge, measured on each side. 8 logical points is small enough that a fitted page still
    /// reads as "fit" and large enough that it does not touch the window chrome.
    public static let zoomPresetInsetPt: CGFloat = 8

    /// The current page's row geometry in content points.
    ///
    /// In facing mode a "page" for fitting purposes is the whole row (both pages), and its
    /// height is the taller of the two; in continuous mode it is just the page. The width to fit
    /// is the page's own width in continuous mode and the spread's width in facing mode.
    private struct PageFitGeometry {
        let page: Int
        let pageHeightPt: CGFloat
        let widthToFitPt: CGFloat
    }

    private func pageFitGeometry() -> PageFitGeometry? {
        guard let document, document.pageCount > 0 else { return nil }
        let page = min(max(0, currentPage - 1), document.pageCount - 1)
        let placement = visiblePagePlacements.first { $0.index == page }
            ?? engine.visiblePages(
                scrollYPt: scrollYPt,
                viewportHeightPt: viewportHeightContentPt,
                gapPt: pageGapPt,
                marginPt: 0,
                layout: layoutMode
            ).first { $0.index == page }
        let fallback = document.firstPageSize
        let pageHeight = placement?.heightPt ?? fallback.height
        guard pageHeight > 0, pageHeight.isFinite else { return nil }
        let rowTop = placement?.topPt
        let rowHeight: CGFloat
        if let rowTop {
            rowHeight = visiblePagePlacements
                .filter { abs($0.topPt - rowTop) < 0.5 }
                .map(\.heightPt)
                .max() ?? pageHeight
        } else {
            rowHeight = pageHeight
        }
        let width: CGFloat
        if layoutMode == .facing {
            // The row, not always the full spread: a cover page is a one-page row centred in
            // the spread's width, and fitting it to the viewport should fill with the cover.
            let rowPages: [PagePlacement]
            if let rowTop {
                rowPages = visiblePagePlacements.filter { abs($0.topPt - rowTop) < 0.5 }
            } else {
                rowPages = []
            }
            if let minX = rowPages.map(\.leftPt).min(),
               let maxX = rowPages.map({ $0.leftPt + $0.widthPt }).max(),
               maxX > minX {
                width = maxX - minX
            } else {
                width = contentWidthPt > 0 ? contentWidthPt : (placement?.widthPt ?? fallback.width)
            }
        } else {
            width = placement?.widthPt ?? fallback.width
        }
        guard width > 0, width.isFinite else { return nil }
        return PageFitGeometry(page: page, pageHeightPt: rowHeight, widthToFitPt: width)
    }

    /// The integer percentage that fits `contentPt` into `viewportPt` minus the preset inset.
    ///
    /// Flooring is deliberate: a fit that rounds up would leave a sliver of the page outside the
    /// viewport (there is no horizontal scrolling to reach it, and the vertical one would show a
    /// scrollbar for a page that was supposed to fit).
    private func fitZoomPercent(fittingContentPt contentPt: CGFloat,
                                intoViewportPt viewportPt: CGFloat) -> Int? {
        let available = viewportPt - 2 * Self.zoomPresetInsetPt
        guard contentPt.isFinite, contentPt > 0,
              available.isFinite, available > 0,
              displayCalibration.factor.isFinite, displayCalibration.factor > 0
        else { return nil }
        let percent = available / (contentPt * displayCalibration.factor) * 100
        guard percent.isFinite else { return nil }
        return min(Self.maximumZoomPercent,
                   max(Self.minimumZoomPercent, Int(percent.rounded(.down))))
    }

    private enum ZoomPresetAnchor {
        /// Keep the content point at the viewport top where it is (Fit Width).
        ///
        /// The offset is in content points, so the reader keeps looking at the same part of the
        /// page; only the amount of content visible at the same window size changes.
        case viewportTop
        /// Put the current page's top at the viewport top (Fit Page).
        ///
        /// The fit already leaves `zoomPresetInsetPt` per side in the *scale*, so the page is
        /// smaller than the viewport. It is top-aligned rather than centred because the current
        /// page is defined by the content point at the viewport top: scrolling even into the gap
        /// above a page would report the previous page while the fitted page fills the screen.
        case pageTop(page: Int)
    }

    /// Applies a preset percentage through the ordinary zoom path and re-anchors the scroll.
    ///
    /// The percentage is an integer like every other zoom, so a preset and the toolbar show the
    /// same number. `reloadVisiblePages` then rebuilds the band and the tile/raster choice for
    /// the new effective scale, exactly as `zoomIn` does.
    private func applyZoomPreset(_ percent: Int, anchoring anchor: ZoomPresetAnchor) {
        guard document != nil else { return }
        cancelScrollGlide()
        pointerZoomRemainder = 0
        zoomPercent = percent
        switch anchor {
        case .viewportTop:
            scrollYPt = clampedScrollOffset(scrollYPt)
        case .pageTop(let page):
            scrollYPt = clampedScrollOffset(
                engine.pageTopPt(page, gapPt: pageGapPt, layout: layoutMode))
        }
        reloadVisiblePages()
        schedulePositionSave()
    }

    /// Fits the current page — the current spread row in facing mode — to the viewport width,
    /// leaving ``zoomPresetInsetPt`` on each side. Vertical scrolling stays available.
    ///
    /// Idempotent: the fit is computed from the page and viewport, not from the current zoom, and
    /// the content point at the viewport top is kept.
    public func zoomFitWidth() {
        guard let geometry = pageFitGeometry(),
              let target = fitZoomPercent(fittingContentPt: geometry.widthToFitPt,
                                          intoViewportPt: viewportSizePt.width)
        else { return }
        applyZoomPreset(target, anchoring: .viewportTop)
        statusMessage = "Fit width · \(zoomPercent)%"
    }

    /// Fits the current page — the current spread row in facing mode — to the viewport **height**,
    /// leaving ``zoomPresetInsetPt`` on each side. Other pages remain reachable by scrolling;
    /// width is the job of ``zoomFitWidth``.
    ///
    /// Idempotent for the same reason as ``zoomFitWidth``: the current page's top is the anchor,
    /// and the target is recomputed from the page geometry and the viewport.
    public func zoomFitPage() {
        guard let geometry = pageFitGeometry(),
              let target = fitZoomPercent(fittingContentPt: geometry.pageHeightPt,
                                          intoViewportPt: viewportSizePt.height)
        else { return }
        applyZoomPreset(target, anchoring: .pageTop(page: geometry.page))
        statusMessage = "Fit page · \(zoomPercent)%"
    }

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

    /// Actual physical size: 100% of the calibrated scale (⌘0).
    ///
    /// The percentage is the reader's number; the calibration makes it physical. On a screen whose
    /// logical density is 108.5 ppi the factor is ≈1.507, so a US Letter page is ≈922 logical
    /// points wide, which is its real 8.5 inches on that panel.
    public func zoomActual() {
        guard document != nil else { return }
        cancelScrollGlide()
        pointerZoomRemainder = 0
        zoomPercent = 100
        scrollYPt = clampedScrollOffset(scrollYPt)
        reloadVisiblePages()
        statusMessage = "Actual size · 100%"
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
    ///
    /// A height change always rebuilds the visible band: it changes which page rows can be seen.
    /// A **width-only** change is different. The canvas centres the content from its own surface
    /// width, and the pages/tiles are placed in content coordinates, so when the whole content
    /// width fits inside both the old and the new viewport there is nothing to rebuild - the band
    /// is exactly the same. That is the normal case while the sidebar slides, and skipping the
    /// rebuild is what keeps the slide from re-running the visible-set loop (and from asking for
    /// a raster or a tile) on every frame.
    ///
    /// When the content is wider than one of the widths the visible columns can change. Those
    /// changes are coalesced into one rebuild shortly after the width stops moving, so a slide or
    /// a live window resize still settles correctly without doing that work per frame.
    public func setViewportSize(_ size: CGSize) {
        guard size != viewportSizePt else { return }
        let previous = viewportSizePt
        viewportSizePt = size

        let heightChanged = abs(size.height - previous.height) > 0.5
        if !heightChanged {
            let contentWidth = contentWidthPt * max(zoomFactor, 0.01)
            let fitsBoth = contentWidth <= min(previous.width, size.width) + 0.5
            if rightPanelLayoutIsMoving {
                // The panel is the source of this width change. Holding the update until the
                // movement ends is what makes "no rebuild per frame" true even when a frame on a
                // loaded machine is slower than the ordinary coalescing window. Re-arming on
                // every frame is also what makes the release follow the animation's real end
                // instead of a fixed timer that a loaded machine can outrun.
                cancelPendingViewportReload()
                if !fitsBoth { rightPanelDeferredReloadNeeded = true }
                armRightPanelSettle(after: 0.15)
            } else if fitsBoth {
                cancelPendingViewportReload()
            } else {
                scheduleViewportReload()
            }
            return
        }
        reloadVisiblePages()
    }

    /// The canvas width the engine last received, in points.
    ///
    /// Read-only on purpose: the canvas owns the viewport. The right-panel checks need the number
    /// to prove that Fit Width fits the canvas and not the window, and that a panel resize lands
    /// on the expected width after the layout settles.
    public var canvasViewportWidthPt: CGFloat { viewportSizePt.width }

    /// Opens or closes the right-hand panel.
    ///
    /// Opening it leaves page overview: the assistant is a reading surface and the overview
    /// covers the whole content area, so keeping both on would show the assistant "open" behind
    /// a grid. The left sidebar's old AI button had the same rule.
    public func toggleRightPanel() {
        if rightPanelVisible {
            rightPanelVisible = false
        } else {
            pageOverviewVisible = false
            rightPanelVisible = true
        }
    }

    /// Sets the panel width and remembers it at once (one discrete change, not a gesture). A live
    /// drag uses ``resizeRightPanel(to:)`` for every pointer sample and commits on release.
    public func setRightPanelWidth(_ width: CGFloat) {
        resizeRightPanel(to: width)
        commitRightPanelWidth()
    }

    /// Follows the pointer during a resize. Deliberately does not write preferences per frame:
    /// the drag commits once when it ends.
    public func resizeRightPanel(to width: CGFloat) {
        let clamped = ReaderSidePanelMetrics.clampedContentWidth(width)
        guard abs(clamped - rightPanelWidthPt) > 0.01 else { return }
        rightPanelWidthPt = clamped
    }

    /// Persists the settled panel width (the resize gesture's release).
    public func commitRightPanelWidth() {
        guard Self.usesStoredSidePanelPreferences else { return }
        ReaderSidePanelPreferences.store(width: rightPanelWidthPt, defaults: panelDefaults)
    }

    /// Called by the window when the right panel's visibility changes. A real animation holds
    /// width updates for its duration; Reduce Motion and a live window resize toggle at once, so
    /// they take the instantaneous branch.
    public func noteRightPanelVisibilityChange(animated: Bool) {
        guard document != nil else { return }
        beginRightPanelMovement()
        guard animated else {
            finishRightPanelMovement()
            return
        }
        // Hold for at least the animation's nominal length. Every frame that arrives re-arms
        // this, so a loaded machine that delivers the slide late does not release the hold early.
        armRightPanelSettle(after: ReaderMotion.panelDuration + 0.15)
    }

    /// A drag of the panel's inner edge began. The view calls this once per gesture.
    public func beginRightPanelResize() {
        beginRightPanelMovement()
    }

    /// The drag ended (or was cancelled): release the single deferred rebuild, if one is needed.
    ///
    /// The release waits briefly for the last layout pass. The pointer can be released before
    /// SwiftUI has laid out the final width; those trailing viewport reports belong to the drag
    /// and must be held too, or a loaded machine turns them back into one rebuild per frame.
    public func endRightPanelResize() {
        armRightPanelSettle(after: 0.15)
    }

    /// Releases the movement once `seconds` pass without another width report. The timer is
    /// replaced, not accumulated, so the rebuild happens after the last frame, not after the
    /// first one.
    private func armRightPanelSettle(after seconds: TimeInterval) {
        rightPanelSettleTask?.cancel()
        rightPanelSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            guard !Task.isCancelled, let self else { return }
            self.finishRightPanelMovement()
        }
    }

    private func beginRightPanelMovement() {
        rightPanelLayoutIsMoving = true
        rightPanelSettleTask?.cancel()
        rightPanelSettleTask = nil
        cancelPendingViewportReload()
    }

    private func finishRightPanelMovement() {
        rightPanelSettleTask?.cancel()
        rightPanelSettleTask = nil
        guard rightPanelLayoutIsMoving else { return }
        rightPanelLayoutIsMoving = false
        if rightPanelDeferredReloadNeeded {
            rightPanelDeferredReloadNeeded = false
            scheduleViewportReload(after: 0.02)
        }
    }

    /// A width-only change that can move the visible columns (a zoomed-in page wider than the
    /// canvas) is rebuilt once after the width stops changing rather than on every frame.
    private func scheduleViewportReload(after delay: TimeInterval = 0.08) {
        pendingViewportReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingViewportReload = nil
                self.coalescedViewportReloadCount += 1
                self.reloadVisiblePages()
            }
        }
        pendingViewportReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPendingViewportReload() {
        pendingViewportReload?.cancel()
        pendingViewportReload = nil
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
            let line = "lyra-reader-select: \(selected.count) characters: \"\(selected)\"\n"
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

        searchSidebarVisible = true
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

    /// Clearing invalidates in-flight work as well as the visible result list.
    public func clearSearch() {
        let hadSearchSelection = currentHitIndex != nil
        searchQuery = ""
        runSearch()
        searchSidebarVisible = false
        if hadSearchSelection { clearSelection() }
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

    /// True while a finished selection is being turned into a mark, so the canvas' mouse-up
    /// path cannot recursively add a second annotation for the same selection.
    private var isMarkingTextSelection = false

    /// Turns the current selection into an annotation.
    ///
    /// This is the **only** creation path for a text mark: the sticky tools' automatic marking,
    /// the toolbar activation and the context menu all call it. It leaves the text selection in
    /// place — the context menu can then attach a note to the same words — while the sticky
    /// path clears it after a successful mark (``markSelectionWithActiveTool``).
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
        guard saveAnnotations(updated, trigger: "add-\(kind.rawValue)") else { return false }
        undoStack.append(.added(annotation))
        redoStack.removeAll()
        reloadVisiblePages()
        let count = selection.range.count
        statusMessage = switch kind {
        case .highlight: "Highlighted \(count) characters"
        case .underline: "Underlined \(count) characters"
        case .strikeout: "Struck through \(count) characters"
        default: "Added a \(kind.rawValue) annotation over \(count) characters"
        }
        return true
    }

    /// Activates a sticky text-markup tool, or turns it off when it is already active.
    ///
    /// Activating one markup tool replaces whatever tool was active, including another markup
    /// kind or a pen/shape tool: the canvas has one mode, so "highlight, then underline" cannot
    /// leave two tools claiming the next selection. A selection that already exists is marked
    /// immediately, which is the old select-then-click behaviour and is still the fastest path.
    public func toggleTextMarkupTool(_ kind: Annotation.Kind) {
        guard let tool = AnnotationTool(textMarkup: kind) else { return }
        if annotationTool == tool {
            annotationTool = .select
            return
        }
        annotationTool = tool
        _ = markSelectionWithActiveTool()
    }

    /// Marks the current selection with the active markup tool, if there is one.
    ///
    /// Returns false when no markup tool is active, when nothing is selected, or when the save
    /// fails. Called by the toolbar after activation and by the canvas when a text-selection
    /// drag ends; both use ``addAnnotationFromSelection(kind:color:note:)`` underneath.
    @discardableResult
    public func markSelectionWithActiveTool() -> Bool {
        guard !isMarkingTextSelection, let kind = annotationTool.textMarkupKind else { return false }
        guard selection != nil else { return false }
        isMarkingTextSelection = true
        defer { isMarkingTextSelection = false }
        let added = addAnnotationFromSelection(kind: kind, color: annotationColor)
        if added {
            // The finished selection has become a mark. Keeping the blue selection on top of it
            // would make the canvas look as if a second mark were about to land, and the next
            // click would try to mark the same words again.
            clearSelection()
        }
        return added
    }

    /// The Select button leaves whatever mode is active, including a sticky markup tool.
    public func selectTool() {
        annotationTool = .select
    }

    /// Whether the toolbar's eraser button has something to act on.
    ///
    /// The button used to be a disabled `pending("Eraser")` placeholder. It is enabled exactly
    /// when a document is open, and arming it is the only way to enter the mode.
    public var canUseEraserTool: Bool { canEditAnnotations }

    /// The toolbar's eraser button: arms the mode, or leaves it when it is already active.
    public func toggleEraserTool() {
        guard canUseEraserTool else { return }
        annotationTool = annotationTool == .eraser ? .select : .eraser
    }

    /// Escape and the Select button leave every mode that has no finished draft to keep.
    ///
    /// Returns whether anything was left or cleared, so the canvas consumes Escape only when it
    /// did something. A selected mark is dropped even in plain Select mode: Escape is the
    /// platform-wide way to end a selection, and Delete must not still have a target afterwards.
    /// Text markup and the eraser are left; the pen and shape tools keep their existing
    /// behaviour (only the live draft is cancelled).
    @discardableResult
    public func cancelActiveAnnotationTool() -> Bool {
        let hadMarkSelection = selectedAnnotationID != nil || pendingMarkSelection != nil
        if cancelTextMarkupTool() {
            if hadMarkSelection { clearAnnotationSelection() }
            return true
        }
        if annotationTool == .redact {
            annotationTool = .select
            statusMessage = "Redaction tool off · pending marks were kept"
            if hadMarkSelection { clearAnnotationSelection() }
            return true
        }
        if annotationTool == .eraser {
            cancelEraserGesture()
            annotationTool = .select
            if hadMarkSelection { clearAnnotationSelection() }
            return true
        }
        if annotationTool == .stamp || annotationTool == .signature {
            pendingStampStyle = nil
            pendingSignatureImageData = nil
            annotationTool = .select
            statusMessage = "Stamp tool off"
            if hadMarkSelection { clearAnnotationSelection() }
            return true
        }
        guard hadMarkSelection else { return false }
        clearAnnotationSelection()
        return true
    }

    /// Escape and the Select button leave the sticky markup mode.
    ///
    /// Returns whether a mode was actually left, so the canvas can consume the Escape key only
    /// when it did something. Pen and shape tools keep their existing Escape behaviour (the
    /// live draft is cancelled; the tool stays selected).
    @discardableResult
    public func cancelTextMarkupTool() -> Bool {
        guard annotationTool.isTextMarkup else { return false }
        // Escape during a drag abandons the gesture: the words under the pointer are not a
        // finished selection, and leaving them blue would hand the reader a selection they
        // never asked for. A selection that is not being dragged belongs to reading and keeps
        // its ordinary look when the tool is left.
        cancelMarkupDragSelection()
        annotationTool = .select
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

    /// The context menu starts a themed paper editor directly beside the selected line.
    public func beginNoteFromSelection() {
        guard let selected = selection else { return }
        let existing = annotations.first {
            $0.kind.isTextMarkup && $0.page == selected.page
                && $0.start == selected.range.lowerBound && $0.end == selected.range.upperBound
        }
        let id: UUID
        if let existing { id = existing.id }
        else {
            guard addAnnotationFromSelection(kind: .highlight, color: annotationColor),
                  let created = annotations.last else { return }
            id = created.id
        }
        annotationTool = .select
        beginEditingAnnotation(id, created: existing == nil)
        sidebarTab = .annotations
        sidebarVisible = true
    }

    public var ownInlineNoteMarkers: [InlineNoteMarker] {
        InlineNoteMarker.layoutOwn(annotations: annotations, textPages: textPages, editingID: editingAnnotationID,
                                  occupied: inlineNoteMarkers)
    }

    public var editingAnnotationAnchor: CGRect? {
        guard let annotation = editingAnnotation else { return nil }
        let rect = annotation.shapeRect ?? ownInlineNoteMarkers.first(where: { $0.id == annotation.id.uuidString })?.rect
        return anchorViewRect(page: annotation.page, region: rect)
    }

    private func rebuildAnnotationPassages() {
        let wanted = Set(documentAnnotations.filter { $0.drawing == .markup }.map(\.page)
            + annotations.filter { $0.kind.isTextMarkup }.map(\.page))
        for page in wanted where passageTextMaps[page] == nil {
            if let text = textPages[page] { passageTextMaps[page] = AnnotationSentenceMap(text) }
        }
        annotationPassages = AnnotationPassage.build(document: documentAnnotations, own: annotations,
            pages: textPages, maps: &passageTextMaps)
        annotationSidebarPages = AnnotationSidebarPage.build(passages: annotationPassages,
            document: documentAnnotations, own: annotations)
    }

    /// Only the pages with text markup need extraction, and only when the annotation list opens.
    public func loadAnnotationPassages() async {
        let epoch = documentEpoch
        let pages = Set(documentAnnotations.filter { $0.drawing == .markup }.map(\.page)
            + annotations.filter { $0.kind.isTextMarkup }.map(\.page))
        for page in pages.sorted() {
            guard epoch == documentEpoch, !Task.isCancelled else { return }
            guard textPages[page] == nil, !textPagesInFlight.contains(page) else { continue }
            textPagesInFlight.insert(page)
            if let text = try? await engine.textPage(page), epoch == documentEpoch { textPages[page] = text }
            if epoch == documentEpoch { textPagesInFlight.remove(page) }
        }
    }

    package func openPassageNote(_ source: AnnotationSource) {
        jump(to: source)
        switch source {
        case .document(let id):
            selectedDocumentAnnotationID = id
            openDocumentNoteID = id
        case .own(let id): beginEditingAnnotation(id)
        }
    }

    package func jump(to source: AnnotationSource) {
        switch source {
        case .document(let id):
            if let annotation = documentAnnotations.first(where: { $0.id == id }) { jump(toDocumentAnnotation: annotation) }
        case .own(let id):
            if let annotation = annotations.first(where: { $0.id == id }) { jump(to: annotation) }
        }
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
        case .highlight, .underline, .strikeout, .stickyNote, .textBox, .stamp, .signature:
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
        case .highlight, .underline, .strikeout, .stickyNote, .textBox, .stamp, .signature:
            return false
        }
    }

    // MARK: - Stamps and image signatures

    /// Arms the stamp tool with one style. The next click on a page places it.
    public func armStampTool(_ style: StampStyle) {
        pendingStampStyle = style
        pendingSignatureImageData = nil
        annotationTool = .stamp
        statusMessage = "Click on the page to place a \(style.title) stamp"
    }

    /// Arms the signature tool with the image the reader chose. The next click places it.
    ///
    /// A hand-drawn signature is the pen, not a second signature tool: the pen writes an `/Ink`
    /// annotation, which every viewer can read, while this places a picture.
    public func armSignatureTool(imageData: Data) {
        guard !imageData.isEmpty else {
            lastError = "That image file is empty."
            return
        }
        pendingSignatureImageData = imageData
        pendingStampStyle = nil
        annotationTool = .signature
        statusMessage = "Click on the page to place the signature image"
    }

    /// Places the armed stamp centred on a content point. Returns whether it was added.
    @discardableResult
    public func placeStamp(atContentPoint point: CGPoint) -> Bool {
        guard let style = pendingStampStyle,
              let hit = pagePoint(atContentPoint: point) else { return false }
        let placed = addStampAnnotation(page: hit.page, style: style, center: hit.point)
        if placed { pendingStampStyle = nil; annotationTool = .select }
        return placed
    }

    /// Places the armed signature image centred on a content point.
    @discardableResult
    public func placeSignature(atContentPoint point: CGPoint) -> Bool {
        guard let data = pendingSignatureImageData,
              let hit = pagePoint(atContentPoint: point) else { return false }
        let placed = addSignatureAnnotation(page: hit.page, imageData: data, center: hit.point)
        if placed { pendingSignatureImageData = nil; annotationTool = .select }
        return placed
    }

    /// Adds a text stamp centred at `center` in page space. Exposed for the checks and the
    /// toolbar; the click path is [`placeStamp`].
    @discardableResult
    public func addStampAnnotation(page: Int, style: StampStyle, center: CGPoint) -> Bool {
        guard let document, page >= 0, page < document.pageCount,
              let url = document.url else { return false }
        if annotationsURL == nil { loadAnnotations(for: url) }
        guard annotationWritesBlockedReason == nil else {
            lastError = annotationWritesBlockedReason
            return false
        }
        let text = style.text()
        guard let box = placementBox(page: page, size: Annotation.defaultStampSize,
                                     center: center) else { return false }
        let annotation = Annotation(
            id: UUID(),
            kind: .stamp,
            page: page,
            start: 0,
            end: 0,
            color: style.color,
            note: text,
            createdAt: Date(),
            shapeRect: box,
            strokeWidth: 0,
            stampStyle: style.rawValue
        )
        return appendPlacedArtwork(annotation)
    }

    /// Adds an image signature centred at `center` in page space. The picture's aspect ratio
    /// decides the initial width, so a tall signature is not stretched on the way in.
    @discardableResult
    public func addSignatureAnnotation(page: Int, imageData: Data, center: CGPoint) -> Bool {
        guard let document, page >= 0, page < document.pageCount,
              let url = document.url else { return false }
        if annotationsURL == nil { loadAnnotations(for: url) }
        guard annotationWritesBlockedReason == nil else {
            lastError = annotationWritesBlockedReason
            return false
        }
        guard let size = Self.signatureBoxSize(imageData) else {
            lastError = "That file is not an image the reader can place."
            return false
        }
        guard let box = placementBox(page: page, size: size, center: center) else { return false }
        let annotation = Annotation(
            id: UUID(),
            kind: .signature,
            page: page,
            start: 0,
            end: 0,
            color: AnnotationColor(red: 0, green: 0, blue: 0, alpha: 255),
            note: "",
            createdAt: Date(),
            shapeRect: box,
            strokeWidth: 0,
            stampStyle: "signature",
            imageData: imageData
        )
        return appendPlacedArtwork(annotation)
    }

    /// The one commit path for a placed stamp or signature: sidecar first, then one undo step.
    private func appendPlacedArtwork(_ annotation: Annotation) -> Bool {
        guard annotation.hasValidGeometry else { return false }
        var updated = annotations
        updated.append(annotation)
        guard saveAnnotations(updated, trigger: "add-\(annotation.kind.rawValue)") else {
            return false
        }
        undoStack.append(.added(annotation))
        redoStack.removeAll()
        selectedAnnotationID = annotation.id
        refreshSelectionOverlay()
        reloadVisiblePages()
        statusMessage = "Placed a \(annotation.kind == .stamp ? "stamp" : "signature image")"
        return true
    }

    /// A page-space box of `size` centred at `center`, clamped inside the page.
    private func placementBox(page: Int, size: CGSize, center: CGPoint) -> CGRect? {
        let pageSize: CGSize
        if let placement = visiblePagePlacements.first(where: { $0.index == page }) {
            pageSize = CGSize(width: placement.widthPt, height: placement.heightPt)
        } else if page == 0 {
            pageSize = document?.firstPageSize ?? .zero
        } else {
            return nil
        }
        guard pageSize.width > 1, pageSize.height > 1 else { return nil }
        let width = min(size.width, pageSize.width)
        let height = min(size.height, pageSize.height)
        let x = min(max(0, center.x - width / 2), max(0, pageSize.width - width))
        let y = min(max(0, center.y - height / 2), max(0, pageSize.height - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The initial page-space size of an image signature, from the picture's pixel aspect ratio.
    private static func signatureBoxSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        let aspect = width / height
        let clamped = min(max(aspect, 0.2), 8.0)
        return CGSize(width: Annotation.defaultSignatureHeight * clamped,
                      height: Annotation.defaultSignatureHeight)
    }

    /// Decodes an image signature into the straight RGBA the PDF writer stores.
    ///
    /// The picture is capped at 2048 px on its longest side: a signature is displayed at tens of
    /// points, and an 8000 px scan would add megabytes to every save without adding detail a
    /// reader can see. The alpha channel is un-premultiplied because that is what the writer's
    /// `/SMask` expects.
    static func signaturePixels(_ data: Data) -> (width: Int, height: Int, rgba: [UInt8])? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let longest = max(image.width, image.height)
        let scale = longest > 2048 ? 2048.0 / Double(longest) : 1.0
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let success = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { return nil }
        for pixel in stride(from: 0, to: rgba.count - 3, by: 4) {
            let alpha = Int(rgba[pixel + 3])
            if alpha == 255 || alpha == 0 { continue }
            for channel in 0..<3 {
                let value = (Int(rgba[pixel + channel]) * 255 + alpha / 2) / alpha
                rgba[pixel + channel] = UInt8(min(value, 255))
            }
        }
        return (width, height, rgba)
    }

    /// One stamp or signature as a write request: a `/Stamp` with text or an image.
    private func stampWriteRequest(
        _ annotation: Annotation,
        zoom: CGFloat,
        modified: String
    ) throws -> AnnotationWriteRequest {
        guard annotation.hasValidGeometry, let box = annotation.shapeRect else {
            throw NSError(
                domain: "LyraReader",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey:
                    "Annotation \(annotation.id.uuidString) has no box and cannot be written"]
            )
        }
        let rect = CGRect(x: box.minX * zoom, y: box.minY * zoom,
                          width: box.width * zoom, height: box.height * zoom)
        guard rect.width > 0.5, rect.height > 0.5 else {
            throw NSError(
                domain: "LyraReader",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey:
                    "Annotation \(annotation.id.uuidString) has a box too small to write"]
            )
        }
        if annotation.kind == .stamp {
            guard !annotation.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(
                    domain: "LyraReader",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Stamp \(annotation.id.uuidString) has no text to write"]
                )
            }
            return AnnotationWriteRequest(
                id: annotation.id.uuidString,
                page: annotation.page,
                kind: .stamp,
                rect: rect,
                quads: [],
                color: annotation.color,
                opacity: Double(annotation.color.alpha) / 255.0,
                contents: annotation.note,
                author: Self.annotationAuthor,
                modified: modified,
                stampStyle: annotation.stampStyle ?? "custom"
            )
        }
        guard let data = annotation.imageData,
              let pixels = Self.signaturePixels(data) else {
            throw NSError(
                domain: "LyraReader",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey:
                    "Signature \(annotation.id.uuidString) has no image the writer can read"]
            )
        }
        return AnnotationWriteRequest(
            id: annotation.id.uuidString,
            page: annotation.page,
            kind: .signature,
            rect: rect,
            quads: [],
            color: annotation.color,
            opacity: 1.0,
            contents: "",
            author: Self.annotationAuthor,
            modified: modified,
            signatureWidth: pixels.width,
            signatureHeight: pixels.height,
            signatureRGBA: pixels.rgba
        )
    }

    // MARK: - Placeable notes and text boxes

    /// A hit on one of the reader's placed-text annotations, in page space.
    public struct PlacedTextHit: Sendable {
        public let id: UUID
        public let page: Int
        public let point: CGPoint
        /// The resize handle the point grabbed; `nil` means move (or select).
        public let handle: TextBoxResizeHandle?
    }

    /// The sticky-note or text-box annotation under a content point.
    ///
    /// A note is hit anywhere inside its icon (plus the same small slack a pointer deserves). A
    /// text box is hit anywhere on the box, frame or interior. That is only a *candidate* for a
    /// click: `beginSelection` defers the actual selection to mouse-up, so a drag that starts on
    /// an unselected box still selects the text underneath, while a plain click selects the box.
    /// Once the box is selected, dragging its interior moves it and its handles resize it.
    public func placedTextHit(
        atContentPoint point: CGPoint,
        toleranceViewPt: CGFloat = AppState.noteClickSlackPt
    ) -> PlacedTextHit? {
        guard let pageHit = pagePoint(atContentPoint: point) else { return nil }
        let tolerance = toleranceViewPt / max(zoomFactor, 0.01)
        for annotation in annotations.reversed() where annotation.kind.isPlacement {
            guard annotation.page == pageHit.page, let rect = annotation.shapeRect else { continue }
            let local = pageHit.point
            switch annotation.kind {
            case .stickyNote:
                guard rect.insetBy(dx: -tolerance, dy: -tolerance).contains(local) else { continue }
                return PlacedTextHit(id: annotation.id, page: annotation.page, point: local,
                                     handle: nil)
            case .textBox, .stamp, .signature:
                let selected = annotation.id == selectedAnnotationID
                if selected,
                   let handle = textBoxHandle(at: local, in: rect, tolerance: tolerance) {
                    return PlacedTextHit(id: annotation.id, page: annotation.page, point: local,
                                         handle: handle)
                }
                if selected, AnnotationGeometry.distance(local, toRectOutline: rect) <= tolerance {
                    return PlacedTextHit(id: annotation.id, page: annotation.page, point: local,
                                         handle: textBoxEdge(at: local, in: rect))
                }
                if rect.insetBy(dx: -tolerance, dy: -tolerance).contains(local) {
                    return PlacedTextHit(id: annotation.id, page: annotation.page, point: local,
                                         handle: nil)
                }
            case .ink, .square, .circle, .line, .arrow, .highlight, .underline, .strikeout:
                continue
            }
        }
        return nil
    }

    /// The corner or edge handle within `tolerance` of a point, nearest first.
    private func textBoxHandle(
        at point: CGPoint,
        in rect: CGRect,
        tolerance: CGFloat
    ) -> TextBoxResizeHandle? {
        // The drawn handle is about 7 view points across, so its half-size is part of the target.
        let reach = tolerance + 4 / max(zoomFactor, 0.01)
        var best: (handle: TextBoxResizeHandle, distance: CGFloat)?
        for handle in TextBoxResizeHandle.allCases {
            let distance = hypot(point.x - handle.point(in: rect).x,
                                 point.y - handle.point(in: rect).y)
            if distance <= reach, best == nil || distance < best!.distance {
                best = (handle, distance)
            }
        }
        return best?.handle
    }

    /// Which edge a point on a selected box's outline belongs to, for edge resizing.
    private func textBoxEdge(
        at point: CGPoint,
        in rect: CGRect
    ) -> TextBoxResizeHandle? {
        let edges: [(TextBoxResizeHandle, CGFloat)] = [
            (.left, AnnotationGeometry.distance(
                point, toSegmentFrom: CGPoint(x: rect.minX, y: rect.minY),
                to: CGPoint(x: rect.minX, y: rect.maxY))),
            (.right, AnnotationGeometry.distance(
                point, toSegmentFrom: CGPoint(x: rect.maxX, y: rect.minY),
                to: CGPoint(x: rect.maxX, y: rect.maxY))),
            (.top, AnnotationGeometry.distance(
                point, toSegmentFrom: CGPoint(x: rect.minX, y: rect.minY),
                to: CGPoint(x: rect.maxX, y: rect.minY))),
            (.bottom, AnnotationGeometry.distance(
                point, toSegmentFrom: CGPoint(x: rect.minX, y: rect.maxY),
                to: CGPoint(x: rect.maxX, y: rect.maxY))),
        ]
        return edges.min(by: { $0.1 < $1.1 })?.0
    }

    /// The sticky-note tool's click: open an existing icon under the pointer, or place a new
    /// note at the page point the pointer names.
    @discardableResult
    public func placeOrOpenStickyNote(atContentPoint point: CGPoint) -> Bool {
        if let hit = placedTextHit(atContentPoint: point),
           let annotation = annotations.first(where: { $0.id == hit.id }),
           annotation.kind == .stickyNote {
            selectedAnnotationID = annotation.id
            beginEditingAnnotation(annotation.id)
            return true
        }
        // A note that belongs to the PDF is read-only; opening its paper is better than placing
        // a sidecar note on top of it.
        if openDocumentNote(at: point) { return true }
        guard let pageHit = pagePoint(atContentPoint: point) else { return false }
        return placeStickyNote(page: pageHit.page, at: pageHit.point)
    }

    /// Creates a sticky note centred on `point` (page space) and opens its editor.
    ///
    /// The icon's box is page-space geometry, like a stroke: the point the reader clicked is the
    /// same page point at every zoom. It is clamped inside the page so an icon placed on the
    /// margin is still reachable.
    @discardableResult
    public func placeStickyNote(page: Int, at point: CGPoint) -> Bool {
        guard let document, page >= 0, page < document.pageCount,
              let placement = visiblePagePlacements.first(where: { $0.index == page }),
              let url = document.url else { return false }
        if annotationsURL == nil { loadAnnotations(for: url) }

        let size = Annotation.stickyNoteSize
        var rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                          width: size.width, height: size.height)
        rect.origin.x = min(max(0, rect.origin.x), max(0, placement.widthPt - size.width))
        rect.origin.y = min(max(0, rect.origin.y), max(0, placement.heightPt - size.height))

        let annotation = Annotation(
            id: UUID(),
            kind: .stickyNote,
            page: page,
            start: 0,
            end: 0,
            color: annotationStrokeColor,
            note: "",
            createdAt: Date(),
            shapeRect: rect,
            strokeWidth: 0,
            fontSize: 0
        )
        guard annotation.hasValidGeometry else { return false }
        var updated = annotations
        updated.append(annotation)
        guard saveAnnotations(updated, trigger: "add-stickyNote") else { return false }
        undoStack.append(.added(annotation))
        redoStack.removeAll()
        selectedAnnotationID = annotation.id
        beginEditingAnnotation(annotation.id, created: true)
        statusMessage = "Placed a sticky note"
        return true
    }

    /// The text-box tool's double-click: open an existing box under the pointer, or place a new
    /// one at the page point the pointer names.
    ///
    /// A double-click inside an existing box edits it instead of stacking a second box on top;
    /// the select tool's double-click uses the same `beginEditingAnnotation`.
    @discardableResult
    public func placeOrOpenTextBox(atContentPoint point: CGPoint) -> Bool {
        guard let pageHit = pagePoint(atContentPoint: point) else { return false }
        for annotation in annotations.reversed() where annotation.kind == .textBox {
            guard annotation.page == pageHit.page,
                  let rect = annotation.shapeRect, rect.contains(pageHit.point) else { continue }
            selectedAnnotationID = annotation.id
            beginEditingAnnotation(annotation.id)
            return true
        }
        return placeTextBox(page: pageHit.page, at: pageHit.point)
    }

    /// Places an empty, one-line text box whose **top-left corner is `point`** (page space).
    ///
    /// The click lands where the caret will be, and the box grows right and down from there, so
    /// a box placed beside existing text does not cover it. Near a page edge the origin is
    /// shifted just enough to keep the whole box on the page.
    @discardableResult
    public func placeTextBox(page: Int, at point: CGPoint) -> Bool {
        guard let placement = visiblePagePlacements.first(where: { $0.index == page })
        else { return false }
        let size = TextBoxLayout.creationSize(fontSize: Annotation.defaultTextBoxFontSize)
        var origin = point
        origin.x = min(max(0, origin.x), max(0, placement.widthPt - size.width))
        origin.y = min(max(0, origin.y), max(0, placement.heightPt - size.height))
        return addTextBox(page: page, rect: CGRect(origin: origin, size: size))
    }

    /// Creates an empty text box in `rect` (page space) and opens its editor.
    ///
    /// The double-click path (`placeTextBox`) computes the one-line-high creation rect; this
    /// rectangle-based entry point remains for callers that already have a box, such as an
    /// older sidecar or a restored session. Its contents then grow from that box.
    @discardableResult
    public func addTextBox(page: Int, rect: CGRect) -> Bool {
        guard let document, page >= 0, page < document.pageCount,
              let placement = visiblePagePlacements.first(where: { $0.index == page }),
              let url = document.url else { return false }
        if annotationsURL == nil { loadAnnotations(for: url) }

        var box = rect.standardized
        box.size.width = max(box.width, Annotation.minimumTextBoxSize.width)
        box.size.height = max(box.height, Annotation.minimumTextBoxSize.height)
        box.origin.x = min(max(0, box.origin.x), max(0, placement.widthPt - box.width))
        box.origin.y = min(max(0, box.origin.y), max(0, placement.heightPt - box.height))

        let annotation = Annotation(
            id: UUID(),
            kind: .textBox,
            page: page,
            start: 0,
            end: 0,
            color: AppState.defaultTextBoxColor,
            note: "",
            createdAt: Date(),
            shapeRect: box,
            strokeWidth: 0,
            fontSize: Annotation.defaultTextBoxFontSize
        )
        guard annotation.hasValidGeometry else { return false }
        var updated = annotations
        updated.append(annotation)
        guard saveAnnotations(updated, trigger: "add-textBox") else { return false }
        undoStack.append(.added(annotation))
        redoStack.removeAll()
        selectedAnnotationID = annotation.id
        beginEditingAnnotation(annotation.id, created: true)
        statusMessage = "Added a text box"
        return true
    }

    /// The colour a text box's text is stored in: dark ink, not the translucent markup palette.
    ///
    /// A text box is body text, and gold text on a white page is not readable. Keeping this
    /// separate from `annotationColor` is the same distinction as a pen's opaque stroke: the
    /// palette chooses highlights, not the colour of text somebody has to read.
    public nonisolated static let defaultTextBoxColor =
        AnnotationColor(red: 0x2B, green: 0x2B, blue: 0x2E, alpha: 255)

    // MARK: - Editing placed text

    /// The annotation whose text editor is open.
    public var editingAnnotation: Annotation? {
        guard let id = editingAnnotationID else { return nil }
        return annotations.first { $0.id == id }
    }

    /// Opens the text editor for a placed-text annotation or text-linked note.
    public func beginEditingAnnotation(_ id: UUID, created: Bool = false) {
        guard editingAnnotationID != id else { return }
        guard let annotation = annotations.first(where: { $0.id == id }),
              annotation.kind.isPlacedText || annotation.kind.isTextMarkup else { return }
        guard commitTextEditing() else { return }
        // Leaving the text-box tool first: changing the tool clears a mark selection, and the
        // editor needs the selection it is about to restore to win. Order matters.
        if annotation.kind == .textBox { annotationTool = .select }
        selectedAnnotationID = id
        cancelPendingMarkSelection()
        selection = nil
        selectionAnchor = nil
        closeDocumentNote()
        editingAnnotationID = id
        editingWasCreated = created
        editingOriginalText = annotation.note
        editingOriginalAnnotation = annotation
        editingUndoDepth = undoStack.count
        refreshSelectionOverlay()
    }

    /// Applies text typed in the editor. Sidecar writes are coalesced by `updateNote`; undo
    /// merges consecutive keystrokes into one step for the session.
    public func updateEditingText(_ text: String) {
        guard let id = editingAnnotationID,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        guard annotations[index].kind == .textBox, let box = annotations[index].shapeRect else {
            updateNote(text, for: id)
            refreshSelectionOverlay()
            return
        }
        let before = annotations[index]
        let placement = visiblePagePlacements.first { $0.index == before.page }
        let pageSize = CGSize(width: placement?.widthPt ?? box.maxX + 320, height: placement?.heightPt ?? box.maxY + 600)
        var after = before
        after.note = text
        after.shapeRect = TextBoxLayout.fittedRect(text: text, fontSize: before.fontSize,
            origin: box.origin,
            maximumWidth: max(1, pageSize.width - box.minX),
            maximumHeight: max(1, pageSize.height - box.minY))
        guard after != before else { return }
        var updated = annotations
        updated[index] = after
        if noteFlushTask == nil {
            guard saveAnnotations(updated, trigger: "edit-text-box") else { return }
            scheduleNoteFlush()
        } else {
            annotations = updated
            hasPendingAnnotationWrite = true
            noteWindowSawKeystrokes = true
        }
        if undoStack.count > editingUndoDepth,
           case .replaced(let original, _) = undoStack.last, original.id == id {
            undoStack.removeLast()
            undoStack.append(.replaced(before: original, after: after))
        } else { undoStack.append(.replaced(before: before, after: after)) }
        redoStack.removeAll()
        refreshSelectionOverlay()
    }

    /// Commits the open editor: flushes the coalesced sidecar write and closes the editor.
    @discardableResult
    public func commitTextEditing() -> Bool {
        guard editingAnnotationID != nil else { return true }
        let isTextBox = editingAnnotation?.kind == .textBox
        let written = flushPendingAnnotationWrite()
        guard written else { return false }
        editingAnnotationID = nil
        editingOriginalAnnotation = nil
        if isTextBox { selectedAnnotationID = nil }
        editingWasCreated = false
        editingOriginalText = ""
        editingUndoDepth = 0
        reloadVisiblePages()
        return written
    }

    /// Cancels the open editor, restoring the text it started with.
    ///
    /// Cancelling a brand-new note or box removes it again (and the creation step); cancelling
    /// an edit restores the previous text and drops the undo steps the session added. In both
    /// cases the sidecar is written once so memory and disk agree.
    public func cancelTextEditing() {
        guard let id = editingAnnotationID else { return }
        noteFlushTask?.cancel()
        noteFlushTask = nil
        noteWindowSawKeystrokes = false
        let wasCreated = editingWasCreated
        let originalText = editingOriginalText
        let originalAnnotation = editingOriginalAnnotation
        editingOriginalAnnotation = nil
        let depth = editingUndoDepth
        editingAnnotationID = nil
        editingWasCreated = false
        editingOriginalText = ""
        editingUndoDepth = 0

        var updated = annotations
        if wasCreated {
            updated.removeAll { $0.id == id }
        } else if let index = updated.firstIndex(where: { $0.id == id }) {
            if let originalAnnotation { updated[index] = originalAnnotation }
            else { updated[index].note = originalText }
        }
        guard saveAnnotations(updated, trigger: wasCreated ? "cancel-new-text" : "cancel-text") else {
            return
        }
        annotations = updated
        undoStack = Array(undoStack.prefix(max(0, wasCreated ? depth - 1 : depth)))
        redoStack.removeAll()
        hasPendingAnnotationWrite = false
        reloadVisiblePages()
    }

    /// Opens the editor for a text box on a double-click anywhere inside it, even when the box
    /// is not selected yet. A single click inside an unselected box still goes to the text.
    @discardableResult
    public func beginEditingTextBox(atContentPoint point: CGPoint) -> Bool {
        guard let pageHit = pagePoint(atContentPoint: point) else { return false }
        for annotation in annotations.reversed() where annotation.kind == .textBox {
            guard annotation.page == pageHit.page, let rect = annotation.shapeRect,
                  rect.contains(pageHit.point) else { continue }
            selectedAnnotationID = annotation.id
            beginEditingAnnotation(annotation.id)
            return true
        }
        // A note or text box the PDF carries is adopted on the double-click that asks to edit
        // it, then edited through the same editor as the reader's own.
        for document in documentAnnotations.reversed()
        where document.kind == "freeText" || document.kind == "text" {
            guard document.page == pageHit.page,
                  let box = document.boxes.first,
                  CGRect(x: box.xPt, y: box.yPt, width: box.widthPt, height: box.heightPt)
                    .contains(pageHit.point) else { continue }
            guard Self.documentAnnotationEditability(document) == .editable,
                  let id = adoptDocumentAnnotation(document.id),
                  let adopted = annotations.first(where: { $0.id == id }) else { return false }
            selectedAnnotationID = adopted.id
            beginEditingAnnotation(adopted.id)
            return true
        }
        return false
    }

    /// The rectangle after dragging `handle` by a page-space delta, clamped to the page and the
    /// minimum text-box size.
    public func resizedTextBox(
        _ original: Annotation,
        handle: TextBoxResizeHandle,
        delta: CGPoint
    ) -> CGRect? {
        guard let box = original.shapeRect,
              let placement = visiblePagePlacements.first(where: { $0.index == original.page })
        else { return nil }
        var minX = box.minX, maxX = box.maxX, minY = box.minY, maxY = box.maxY
        if handle.movesLeft { minX += delta.x }
        if handle.movesRight { maxX += delta.x }
        if handle.movesTop { minY += delta.y }
        if handle.movesBottom { maxY += delta.y }
        let minimum = Self.minimumPlacementSize(for: original.kind)
        if maxX - minX < minimum.width {
            if handle.movesLeft { minX = maxX - minimum.width } else { maxX = minX + minimum.width }
        }
        if maxY - minY < minimum.height {
            if handle.movesTop { minY = maxY - minimum.height } else { maxY = minY + minimum.height }
        }
        minX = max(0, min(minX, placement.widthPt - minimum.width))
        maxX = max(minX + minimum.width, min(maxX, placement.widthPt))
        minY = max(0, min(minY, placement.heightPt - minimum.height))
        maxY = max(minY + minimum.height, min(maxY, placement.heightPt))
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The smallest page-space box a placed mark may be resized to.
    ///
    /// A text box keeps room for one line at its smallest font; a stamp keeps its border and one
    /// short word legible; a signature keeps enough pixels to be recognisable.
    static func minimumPlacementSize(for kind: Annotation.Kind) -> CGSize {
        switch kind {
        case .textBox: return Annotation.minimumTextBoxSize
        case .stamp: return CGSize(width: 60, height: 20)
        case .signature: return CGSize(width: 24, height: 12)
        case .stickyNote: return CGSize(width: 8, height: 8)
        default: return CGSize(width: 8, height: 8)
        }
    }

    /// Commits a resize on mouse-up: one sidecar write and one undo step for the whole drag.
    private func finishAnnotationResize(
        original: Annotation,
        handle: TextBoxResizeHandle,
        start: CGPoint,
        at point: CGPoint,
        wasClick: Bool
    ) {
        defer {
            resizeOriginalAnnotation = nil
            resizeStartPagePoint = nil
            resizeHandle = nil
        }
        guard let placement = visiblePagePlacements.first(where: { $0.index == original.page })
        else { return }
        let current = CGPoint(x: point.x - placement.leftPt, y: point.y - placement.topPt)
        guard let finalRect = resizedTextBox(
            original, handle: handle,
            delta: CGPoint(x: current.x - start.x, y: current.y - start.y)
        ) else { return }
        guard !wasClick, finalRect != original.shapeRect,
              let index = annotations.firstIndex(where: { $0.id == original.id })
        else { return }
        var resized = annotations[index]
        resized.shapeRect = finalRect
        guard resized.hasValidGeometry else {
            annotations[index] = original
            return
        }
        var updated = annotations
        updated[index] = resized
        guard saveAnnotations(updated, trigger: "resize-textBox") else {
            annotations[index] = original
            selectedAnnotationID = original.id
            refreshSelectionOverlay()
            return
        }
        undoStack.append(.replaced(before: original, after: resized))
        redoStack.removeAll()
        selectedAnnotationID = original.id
        refreshSelectionOverlay()
        statusMessage = "Resized the \(original.kind == .textBox ? "text box" : original.kind.rawValue)"
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
    ///
    /// Text marks travel here too, carrying the quads of the character range they cover. They
    /// are not stroked by the overlay (the canvas draws their tint), but the quads are what the
    /// overlay hit-tests and what its dashed selection halo follows.
    ///
    /// While an eraser drag is cutting, the gesture's preview marks stand in for the model:
    /// untouched marks are unchanged, and a touched stroke is drawn as the pieces that survive.
    public var canvasAnnotationMarks: [CanvasAnnotationMark] {
        if let preview = eraserPreviewMarks { return preview }
        var marks = annotations.compactMap(canvasMark(for:))
        for annotation in documentAnnotations {
            if let mark = canvasMark(for: annotation) { marks.append(mark) }
        }
        // A stamp the PDF carries is drawn by the canvas' texture pass, but its box is on the
        // overlay so the select tool can hit-test and the adoption path can take it over. The
        // overlay's `layers(for:)` deliberately draws nothing for a stamp: one picture, one owner.
        for annotation in documentAnnotations
        where annotation.visible && annotation.drawing == .stamp {
            let color = annotation.color ?? AnnotationColor(
                red: 0x80, green: 0x80, blue: 0x80, alpha: 255)
            marks.append(CanvasAnnotationMark(
                id: "pdf:" + annotation.id,
                page: annotation.page,
                kind: .stamp,
                shapeRect: CGRect(x: annotation.xPt, y: annotation.yPt,
                                  width: annotation.widthPt, height: annotation.heightPt),
                color: color,
                strokeWidth: 0,
                isSelected: false,
                isEditable: true
            ))
        }
        return marks
    }

    /// A stamp the PDF carries under a content point.
    ///
    /// Unlike [`documentGeometryHit`] this returns a stamp the reader cannot edit as well: the
    /// click has to reach the one sentence that says why (it can still be deleted), rather than
    /// falling through to the text underneath and looking like the stamp was not there.
    public func documentStampHit(atContentPoint point: CGPoint)
        -> (annotation: DocumentAnnotation, page: Int, point: CGPoint)? {
        guard let hit = pagePoint(atContentPoint: point) else { return nil }
        for annotation in documentAnnotations.reversed()
        where annotation.visible && annotation.drawing == .stamp
            && annotation.page == hit.page {
            let rect = CGRect(x: annotation.xPt, y: annotation.yPt,
                              width: annotation.widthPt, height: annotation.heightPt)
            let slack = Self.noteClickSlackPt / max(zoomFactor, 0.01)
            if rect.insetBy(dx: -slack, dy: -slack).contains(hit.point) {
                return (annotation, hit.page, hit.point)
            }
        }
        return nil
    }

    /// One sidecar annotation as the canvas draws it, or `nil` for a kind the canvas does not
    /// paint itself (its text layer or note bitmap does).
    private func canvasMark(for annotation: Annotation) -> CanvasAnnotationMark? {
        guard annotation.kind.isPlacement || annotation.kind.isTextMarkup else { return nil }
        return CanvasAnnotationMark(
            id: annotation.id.uuidString,
            page: annotation.page,
            kind: annotation.kind,
            inkPaths: annotation.inkPaths,
            shapeRect: annotation.shapeRect,
            lineStart: annotation.lineStart,
            lineEnd: annotation.lineEnd,
            textQuads: textQuads(for: annotation),
            color: annotation.color,
            strokeWidth: annotation.strokeWidth,
            isSelected: annotation.id == selectedAnnotationID
                && !(editingAnnotationID == annotation.id && annotation.kind == .textBox),
            isEraseTarget: annotation.id.uuidString == eraserHoverMarkID,
            isEditable: true
        )
    }

    /// One annotation the PDF carries as the canvas draws it.
    private func canvasMark(for annotation: DocumentAnnotation) -> CanvasAnnotationMark? {
        guard annotation.visible && annotation.isGeometry,
              let kind = Annotation.Kind(rawValue: annotation.kind) else { return nil }
        let opacity = annotation.opacity ?? 1.0
        let alpha = UInt8(min(max((opacity * 255.0).rounded(), 0), 255))
        let color = annotation.color ?? AnnotationColor(red: 0x80, green: 0x80,
                                                       blue: 0x80, alpha: alpha)
        let width = annotation.borderWidthPt ?? 1
        // A PDF shape's `/Rect` is the *outer* edge of its stroke. The canvas draws the path down
        // the centre line, so the box it draws is inset by half the border.
        let shapeRect: CGRect? = if kind == .square || kind == .circle {
            CGRect(x: annotation.xPt, y: annotation.yPt,
                   width: annotation.widthPt, height: annotation.heightPt)
                .insetBy(dx: width / 2, dy: width / 2)
        } else {
            nil
        }
        return CanvasAnnotationMark(
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
            isEraseTarget: eraserHoverMarkID == "pdf:" + annotation.id,
            isEditable: true
        )
    }

    /// The page frames the canvas needs to map page-local marks into the view.
    public var canvasPageFrames: [PagePlacement] { visiblePagePlacements }

    /// The page-space quads a text mark covers, one per visual line.
    ///
    /// Empty until the page's text layer has been extracted: a text mark is a character range,
    /// so it has no geometry of its own. Callers treat an empty list as "not hit-testable yet"
    /// rather than falling back to a bounding box, which would claim text the mark does not
    /// cover.
    public func textQuads(for annotation: Annotation) -> [CGRect] {
        guard annotation.kind.isTextMarkup else { return [] }
        // A mark the PDF itself carried keeps the file's own boxes: its characters are in
        // somebody else's text layer, so re-deriving a range here would move the mark.
        if let fixed = annotation.fileQuads, !fixed.isEmpty {
            return fixed.map {
                CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            }
        }
        guard let textPage = textPages[annotation.page] else { return [] }
        let lower = min(annotation.start, annotation.end)
        let upper = max(annotation.start, annotation.end)
        guard lower >= 0, upper >= lower else { return [] }
        return textPage.selectionRects(in: lower...upper)
    }

    /// The reader's own text mark under a content point, with the point in its page space.
    ///
    /// Only sidecar marks are considered: a highlight the PDF itself carries is reported by
    /// `fileOwnedMarkupHit` so the click can be refused with an explanation. The hit is the
    /// marked words themselves, including a few points of hand tolerance.
    public func textMarkupHit(
        atContentPoint point: CGPoint,
        toleranceViewPt: CGFloat = AnnotationGeometry.hitTolerancePt
    ) -> (id: UUID, page: Int, point: CGPoint)? {
        guard let hit = pagePoint(atContentPoint: point) else { return nil }
        let tolerance = toleranceViewPt / max(zoomFactor, 0.01)
        for annotation in annotations.reversed()
            where annotation.kind.isTextMarkup && annotation.page == hit.page {
            let quads = textQuads(for: annotation)
            if quads.contains(where: {
                $0.insetBy(dx: -tolerance, dy: -tolerance).contains(hit.point)
            }) {
                return (annotation.id, hit.page, hit.point)
            }
        }
        return nil
    }

    /// A text mark the PDF itself carries under a content point.
    ///
    /// The click turns it into an adopted, selected mark (or states the one unsupported reason
    /// when its kind has no editable model), so there is no separate refusal path.
    public func fileOwnedMarkupHit(atContentPoint point: CGPoint) -> DocumentAnnotation? {
        guard let hit = pagePoint(atContentPoint: point) else { return nil }
        let slack = Self.noteClickSlackPt
        for annotation in documentAnnotations.reversed()
            where annotation.visible && annotation.drawing == .markup
                && annotation.page == hit.page {
            for box in annotation.boxes {
                let rect = CGRect(x: box.xPt, y: box.yPt,
                                  width: box.widthPt, height: box.heightPt)
                    .insetBy(dx: -slack, dy: -slack)
                if rect.contains(hit.point) { return annotation }
            }
        }
        return nil
    }

    /// A geometric annotation the PDF carries (ink, a shape or a line) under a content point.
    public func documentGeometryHit(
        atContentPoint point: CGPoint,
        toleranceViewPt: CGFloat = AnnotationGeometry.hitTolerancePt
    ) -> (annotation: DocumentAnnotation, page: Int, point: CGPoint)? {
        guard let hit = pagePoint(atContentPoint: point) else { return nil }
        let tolerance = toleranceViewPt / max(zoomFactor, 0.01)
        for annotation in documentAnnotations.reversed()
        where annotation.visible && annotation.isGeometry && annotation.page == hit.page {
            guard Self.documentAnnotationEditability(annotation) == .editable else { continue }
            if AnnotationGeometry.hitTest(documentMark(annotation), at: hit.point,
                                          tolerance: tolerance) {
                return (annotation, hit.page, hit.point)
            }
        }
        return nil
    }

    /// A file annotation as the canvas overlay draws it, for hit testing.
    private func documentMark(_ annotation: DocumentAnnotation) -> CanvasAnnotationMark {
        let kind = Annotation.Kind(rawValue: annotation.kind) ?? .ink
        let width = annotation.borderWidthPt ?? 1
        let alpha = UInt8(min(max(((annotation.opacity ?? 1.0) * 255.0).rounded(), 0), 255))
        let color = annotation.color ?? AnnotationColor(red: 0x80, green: 0x80, blue: 0x80,
                                                       alpha: alpha)
        let shapeRect: CGRect? = if kind == .square || kind == .circle {
            CGRect(x: annotation.xPt, y: annotation.yPt,
                   width: annotation.widthPt, height: annotation.heightPt)
                .insetBy(dx: width / 2, dy: width / 2)
        } else {
            nil
        }
        return CanvasAnnotationMark(
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
            isEditable: true
        )
    }

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

    // MARK: - Eraser

    // The eraser removes the ink under its pointer path, not whole annotations. A stroke is cut
    // where the pointer reaches it; the pieces that survive become new ink annotations, and one
    // undo restores the original. The geometry rule lives in `InkStrokeSplitter`; this section is
    // the model half: identity, ordering, the sidecar and the undo action.

    /// What an armed eraser is over, and therefore what a press would begin to cut.
    ///
    /// Sidecar strokes are cut into pieces. A stroke the PDF itself carries follows the
    /// cross-reader path: its surviving pieces become new sidecar ink and the original annotation
    /// is staged for deletion by identity, because the writer deletes a file annotation rather
    /// than rewriting its `/InkList` in place.
    public enum EraserTarget: Equatable, Sendable {
        case sidecar(id: UUID, page: Int)
        case document(id: String, page: Int)

        public var page: Int {
            switch self {
            case .sidecar(_, let page), .document(_, let page): return page
            }
        }

        /// True when the eraser can remove the target. Both halves of the model are removable
        /// now: an adopted file annotation lives in the annotation list, and an ink annotation
        /// the file carries is deleted through the same incremental writer.
        public var isEditable: Bool { true }
    }

    /// The ink stroke an armed eraser would remove at a content point, or the file-owned stroke
    /// it must refuse.
    ///
    /// Only `.ink` is considered: highlights, underlines, strikeouts, notes, text boxes and the
    /// four shapes are annotations, not ink, and the eraser deliberately leaves them alone (they
    /// are still removed with Select + Delete). Sidecar ink is tested before the PDF's own ink so
    /// a stroke the reader drew on top of a file annotation stays erasable; the hover halo shows
    /// which one the eraser picked.
    public func eraserTarget(atContentPoint point: CGPoint) -> EraserTarget? {
        guard annotationTool == .eraser, let hit = pagePoint(atContentPoint: point) else {
            return nil
        }
        let tolerance = AnnotationGeometry.eraserToleranceViewPt / max(zoomFactor, 0.01)
        for annotation in annotations.reversed()
            where annotation.kind == .ink && annotation.page == hit.page
                && inkAttachmentRefusal(for: annotation) == nil {
            let mark = CanvasAnnotationMark(
                id: annotation.id.uuidString, page: hit.page, kind: .ink,
                inkPaths: annotation.inkPaths, color: annotation.color,
                strokeWidth: annotation.strokeWidth, isSelected: false, isEditable: true)
            if AnnotationGeometry.hitTest(mark, at: hit.point, tolerance: tolerance) {
                return .sidecar(id: annotation.id, page: hit.page)
            }
        }
        for annotation in documentAnnotations.reversed()
            where annotation.visible && annotation.kind == "ink" && annotation.page == hit.page
                && Self.documentAnnotationEditability(annotation) == .editable
                && inkAttachmentRefusal(for: annotation) == nil {
            if AnnotationGeometry.hitTest(documentInkMark(annotation), at: hit.point,
                                          tolerance: tolerance) {
                return .document(id: annotation.id, page: hit.page)
            }
        }
        return nil
    }

    /// Updates the pre-erase indication as the pointer moves.
    ///
    /// The overlay draws the same dashed halo the select tool uses around the returned stroke.
    /// Both halves of the model get one: the halo says which ink the press will begin to cut,
    /// not whether the whole annotation will disappear.
    public func updateEraserHover(atContentPoint point: CGPoint?) {
        guard annotationTool == .eraser, let point, !eraserGestureActive,
              let target = eraserTarget(atContentPoint: point) else {
            if eraserHoverMarkID != nil { eraserHoverMarkID = nil }
            return
        }
        let id: String? = switch target {
        case .sidecar(let id, _): id.uuidString
        case .document(let id, _): "pdf:" + id
        }
        if eraserHoverMarkID != id { eraserHoverMarkID = id }
    }

    /// Starts one eraser gesture. A completed gesture is one undo step, however many strokes it
    /// cuts and however many pieces they become.
    ///
    /// The model is not touched while the pointer moves: the gesture only accumulates the
    /// parameter intervals each stroke has lost and publishes throwaway preview marks. The
    /// sidecar write, the final annotations and the undo step are created together on release,
    /// so a cancel or a failed write leaves the page exactly as it was.
    public func beginEraserGesture(atContentPoint point: CGPoint) {
        guard annotationTool == .eraser, document != nil else { return }
        cancelEraserGesture()
        eraserRefusalNotice = nil
        eraserGestureBase = annotations
        eraseInk(alongContentSegment: point, to: point)
    }

    /// Continues the gesture along the pointer's path. `previous` and `point` are the two ends of
    /// the segment the pointer travelled since the last event; the whole segment is tested, so a
    /// fast drag cannot skip a stroke that lies between two samples.
    public func extendEraserGesture(fromContentPoint previous: CGPoint,
                                    toContentPoint point: CGPoint) {
        guard eraserGestureActive else { return }
        eraseInk(alongContentSegment: previous, to: point)
    }

    /// Ends the gesture and writes its result to the sidecar as one change.
    ///
    /// Every original stroke the drag reached is replaced by the pieces that survived, in the
    /// original's place in drawing order and in the original path's order. The originals are
    /// removed from the sidecar; the pieces get new identities. A stroke the PDF itself carried
    /// is removed through the cross-reader path: its identity joins `pendingFileDeletions`, and
    /// its surviving pieces become ordinary sidecar ink, so saving a copy both prunes the
    /// original geometry and appends the pieces.
    ///
    /// The PDF on disk is untouched. Returns the number of original strokes the drag changed
    /// (not the number of pieces), or `0` when it reached nothing or the sidecar write failed.
    @discardableResult
    public func endEraserGesture() -> Int {
        guard let base = eraserGestureBase else { return 0 }
        let sidecarSplits = eraserGestureSidecarSplits
        let documentSplits = eraserGestureDocumentSplits
        resetEraserGesture()
        guard !sidecarSplits.isEmpty || !documentSplits.isEmpty else {
            // A refused file-owned stroke is not "nothing happened": the banner explains what
            // would have been destroyed, and the page is untouched.
            statusMessage = eraserRefusalNotice ?? "The eraser did not reach any ink"
            return 0
        }

        // Rebuild the sidecar list: each touched stroke stands where it did, as its surviving
        // pieces (none at all when the drag covered it completely).
        var updated: [Annotation] = []
        var pieces = 0
        var slotInsertions: [(original: UUID, pieces: [UUID])] = []
        for annotation in base {
            guard let split = sidecarSplits[annotation.id] else {
                updated.append(annotation)
                continue
            }
            let segments = inkSegments(from: annotation, paths: split.survivingPaths)
            pieces += segments.count
            updated.append(contentsOf: segments)
            if !segments.isEmpty {
                slotInsertions.append((annotation.id, segments.map(\.id)))
            }
        }

        // A file-owned stroke's pieces are new sidecar ink, after the reader's own marks, in the
        // order the page drew the file's annotations.
        var documents: [ErasedFileAnnotation] = []
        var deletions: [FileAnnotationDeletion] = []
        var erasedIDs: Set<UUID> = []
        for (index, annotation) in documentAnnotations.enumerated() {
            guard let split = documentSplits[annotation.id] else { continue }
            documents.append(ErasedFileAnnotation(document: annotation, index: index))
            addDeletion(FileAnnotationDeletion(identity: annotation.id, page: annotation.page),
                        to: &deletions)
            let segments = inkSegments(from: annotation, paths: split.survivingPaths)
            pieces += segments.count
            updated.append(contentsOf: segments)
        }
        for annotation in base {
            guard let split = sidecarSplits[annotation.id] else { continue }
            if let identity = split.annotation.fileIdentity {
                addDeletion(FileAnnotationDeletion(identity: identity,
                                                   page: split.annotation.page),
                            to: &deletions)
            } else {
                erasedIDs.insert(annotation.id)
            }
        }
        deletions = deletions.filter { deletion in
            !pendingFileDeletions.contains(where: { $0.identity == deletion.identity })
        }

        // Keep the sidecar's own entry order: the original's slot stays as the anchor (it is
        // skipped while the annotation is absent) and the pieces' slots follow it. Undo restores
        // the original array, and the now-orphaned piece slots are skipped by the encoder, so
        // the untouched bytes come back exactly; redo finds the piece slots already in place.
        let slotsBefore = annotationSidecarSlots
        if !slotInsertions.isEmpty {
            var slots = annotationSidecarSlots
            for insertion in slotInsertions {
                guard let index = slots.firstIndex(where: { slot in
                    if case .annotation(let id) = slot { return id == insertion.original }
                    return false
                }) else { continue }
                slots.insert(contentsOf: insertion.pieces.map { .annotation($0) },
                             at: index + 1)
            }
            annotationSidecarSlots = slots
        }
        if updated != base {
            guard saveAnnotations(updated, trigger: "erase-ink") else {
                // The write never reached disk: no annotation is removed, no deletion is staged
                // and no undo step claims a cut the sidecar does not have.
                annotationSidecarSlots = slotsBefore
                statusMessage = "Could not save the cut ink; the page is unchanged"
                refreshSelectionOverlay()
                return 0
            }
        } else {
            annotations = updated
        }

        // Only now, with the sidecar holding the pieces, remove the file-owned originals from
        // the page and stage their pruned deletion.
        let removedDocumentIDs = Set(documents.map(\.document.id))
        documentAnnotations.removeAll { removedDocumentIDs.contains($0.id) }
        for deletion in deletions
        where !pendingFileDeletions.contains(where: { $0.identity == deletion.identity }) {
            pendingFileDeletions.append(deletion)
        }
        if let selected = selectedAnnotationID,
           !annotations.contains(where: { $0.id == selected }) {
            selectedAnnotationID = nil
        }
        undoStack.append(.erasedInk(before: base, after: updated, documents: documents,
                                    deletions: deletions, erasedStrokeIDs: erasedIDs))
        redoStack.removeAll()
        erasedInkStrokeIDs.formUnion(erasedIDs)
        reloadVisiblePages()
        refreshSelectionOverlay()

        let changed = sidecarSplits.count + documentSplits.count
        let fullyRemoved = (sidecarSplits.values.filter { $0.survivingPaths.isEmpty }.count)
            + (documentSplits.values.filter { $0.survivingPaths.isEmpty }.count)
        if pieces == 0 {
            statusMessage = changed == 1
                ? "Erased 1 ink stroke · the PDF on disk is unchanged"
                : "Erased \(changed) ink strokes · the PDF on disk is unchanged"
        } else if fullyRemoved > 0 {
            statusMessage = "Cut \(changed) ink stroke\(changed == 1 ? "" : "s") into "
                + "\(pieces) piece\(pieces == 1 ? "" : "s") · the PDF on disk is unchanged"
        } else {
            statusMessage = "Split \(changed) ink stroke\(changed == 1 ? "" : "s") into "
                + "\(pieces) piece\(pieces == 1 ? "" : "s") · the PDF on disk is unchanged"
        }
        return changed
    }

    /// Abandons a gesture in flight (Escape, or a tool switch). Nothing reached the model, the
    /// sidecar or the PDF, so clearing the preview is the whole undo.
    public func cancelEraserGesture() {
        guard eraserGestureBase != nil else { return }
        resetEraserGesture()
        refreshSelectionOverlay()
    }

    /// Clears the transient gesture state. The model and the files were never mutated while the
    /// pointer was down, so this is also the cancel path.
    private func resetEraserGesture() {
        eraserGestureBase = nil
        eraserGestureSidecarSplits = [:]
        eraserGestureDocumentSplits = [:]
        eraserGestureRefusedDocumentIDs = []
        eraserPreviewMarks = nil
    }

    /// The refusal banner's Dismiss button.
    public func dismissEraserRefusal() {
        eraserRefusalNotice = nil
    }

    /// Appends a deletion once, preserving the order the gesture found the strokes in.
    private func addDeletion(_ deletion: FileAnnotationDeletion,
                             to deletions: inout [FileAnnotationDeletion]) {
        guard !deletions.contains(where: { $0.identity == deletion.identity }) else { return }
        deletions.append(deletion)
    }

    /// True while an eraser drag owns the pointer.
    public var eraserGestureActive: Bool { eraserGestureBase != nil }

    /// The number of reader-created strokes the eraser has shortened or removed whose absence
    /// has not reached a PDF yet.
    public var hasPendingInkErasure: Bool { !erasedInkStrokeIDs.isEmpty }

    /// The eraser/annotation-deletion banner's second line, in the same language as the
    /// page-edit and form banners.
    public var eraserPendingSummary: String? {
        var parts: [String] = []
        if !erasedInkStrokeIDs.isEmpty {
            let count = erasedInkStrokeIDs.count
            parts.append(count == 1 ? "1 ink stroke erased or shortened"
                                    : "\(count) ink strokes erased or shortened")
        }
        if !pendingFileDeletions.isEmpty {
            let count = pendingFileDeletions.count
            parts.append(count == 1 ? "1 file annotation deleted"
                                    : "\(count) file annotations deleted")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
            + " · the PDF on disk is unchanged until you save"
    }

    /// The selection refusal banner's Dismiss button.
    public func dismissMarkSelectionRefusal() {
        markSelectionRefusalNotice = nil
    }

    // MARK: - Eraser gesture state and geometry

    /// One sidecar ink annotation's cuts, with the splitters that produced them.
    private struct SidecarInkSplit {
        let annotation: Annotation
        var splitters: [InkStrokeSplitter]
        var survivingPaths: [[CGPoint]]
    }

    /// One file-owned ink annotation's cuts. The original stays in `documentAnnotations` until
    /// the gesture ends, so a cancel cannot forget where it came from; the split state only
    /// remembers its original geometry.
    private struct DocumentInkSplit {
        let annotation: DocumentAnnotation
        var splitters: [InkStrokeSplitter]
        var survivingPaths: [[CGPoint]]
    }

    /// Why a file-owned ink stroke must not be split, or `nil` when it carries nothing a split
    /// would orphan.
    ///
    /// Splitting a PDF-owned stroke is implemented as "delete the original annotation by
    /// identity, append its surviving pieces as new sidecar ink". That is the cross-reader path
    /// and it is safe for bare ink, but the original annotation can also own review data the
    /// reader does not model as separate marks: its `/Contents`, a `/Popup` window, and the
    /// `/IRT` replies that name it. Deleting it would destroy that conversation, so the eraser
    /// leaves the stroke whole and says what is at stake. Sidecar ink has no such attachments.
    private func inkAttachmentRefusal(for annotation: DocumentAnnotation) -> String? {
        inkAttachmentRefusal(contents: annotation.contents,
                             hasPopup: annotation.hasPopup,
                             identity: annotation.id)
    }

    /// The adopted-entry form. It is still a file-owned stroke: the sidecar entry edits the PDF's
    /// own annotation by identity, so the file's popup (remembered in `documentPopupFlags`), its
    /// current comment (kept in the sidecar note), and the `/IRT` replies still in
    /// `documentAnnotations` would all be deleted by a split.
    private func inkAttachmentRefusal(for annotation: Annotation) -> String? {
        guard let identity = annotation.fileIdentity else { return nil }
        return inkAttachmentRefusal(contents: annotation.note,
                                    hasPopup: documentPopupFlags[identity] ?? false,
                                    identity: identity)
    }

    private func inkAttachmentRefusal(contents: String?, hasPopup: Bool,
                                      identity: String) -> String? {
        var losses: [String] = []
        if let contents,
           !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            losses.append("a comment")
        }
        if hasPopup {
            losses.append("a popup")
        }
        let replyCount = documentAnnotations.filter {
            $0.isReply && $0.parentID == identity
        }.count
        if replyCount == 1 {
            losses.append("1 reply")
        } else if replyCount > 1 {
            losses.append("\(replyCount) replies")
        }
        guard !losses.isEmpty else { return nil }
        let list: String = switch losses.count {
        case 1: losses[0]
        case 2: "\(losses[0]) and \(losses[1])"
        default: losses.dropLast().joined(separator: ", ") + " and " + losses[losses.count - 1]
        }
        let pronoun = losses.count == 1 ? "it" : "them"
        return "This stroke belongs to the PDF and carries \(list); splitting it would delete \(pronoun)."
    }

    /// Tests one pointer segment against the ink that existed when the gesture began.
    ///
    /// Each page the segment touches is handled in that page's own space (the segment is clipped
    /// to the page first). The split state always looks back at the **original** path, so
    /// extending a gap cannot accumulate rounding: every preview and every final piece is
    /// rebuilt from the same original points and the union of the pointer capsules.
    private func eraseInk(alongContentSegment start: CGPoint, to end: CGPoint) {
        guard let base = eraserGestureBase else { return }
        let zoom = max(zoomFactor, 0.01)
        var changed = false
        for placement in visiblePagePlacements {
            let rect = CGRect(x: placement.leftPt, y: placement.topPt,
                              width: placement.widthPt, height: placement.heightPt)
            guard let clipped = AnnotationGeometry.clippedSegment(from: start, to: end, in: rect)
            else { continue }
            let localStart = CGPoint(x: clipped.start.x - placement.leftPt,
                                     y: clipped.start.y - placement.topPt)
            let localEnd = CGPoint(x: clipped.end.x - placement.leftPt,
                                   y: clipped.end.y - placement.topPt)
            for annotation in base
            where annotation.kind == .ink && annotation.page == placement.index {
                if eraserGestureRefusedSidecarIDs.contains(annotation.id) { continue }
                if let reason = inkAttachmentRefusal(for: annotation) {
                    eraserGestureRefusedSidecarIDs.insert(annotation.id)
                    eraserRefusalNotice = reason
                    statusMessage = reason
                    continue
                }
                let reach = AnnotationGeometry.eraserReach(
                    strokeWidth: annotation.strokeWidth, zoom: zoom)
                var split = eraserGestureSidecarSplits[annotation.id]
                    ?? SidecarInkSplit(
                        annotation: annotation,
                        splitters: annotation.inkPaths.map {
                            InkStrokeSplitter(points: $0, reach: reach)
                        },
                        survivingPaths: annotation.inkPaths)
                var pathChanged = false
                for index in split.splitters.indices
                where split.splitters[index].remove(pointerFrom: localStart, to: localEnd) {
                    pathChanged = true
                }
                if pathChanged {
                    split.survivingPaths = Self.survivingPaths(of: split.splitters)
                    eraserGestureSidecarSplits[annotation.id] = split
                    changed = true
                }
            }
            for annotation in documentAnnotations
            where annotation.visible && annotation.kind == "ink"
                && annotation.page == placement.index
                && Self.documentAnnotationEditability(annotation) == .editable {
                if eraserGestureRefusedDocumentIDs.contains(annotation.id) { continue }
                if let reason = inkAttachmentRefusal(for: annotation) {
                    // Refuse this stroke for the whole gesture: no cuts, no pending deletion,
                    // no sidecar entry. Other strokes under the same drag still split.
                    eraserGestureRefusedDocumentIDs.insert(annotation.id)
                    eraserRefusalNotice = reason
                    statusMessage = reason
                    continue
                }
                let mark = documentInkMark(annotation)
                let reach = AnnotationGeometry.eraserReach(
                    strokeWidth: mark.strokeWidth, zoom: zoom)
                var split = eraserGestureDocumentSplits[annotation.id]
                    ?? DocumentInkSplit(
                        annotation: annotation,
                        splitters: mark.inkPaths.map {
                            InkStrokeSplitter(points: $0, reach: reach)
                        },
                        survivingPaths: mark.inkPaths)
                var pathChanged = false
                for index in split.splitters.indices
                where split.splitters[index].remove(pointerFrom: localStart, to: localEnd) {
                    pathChanged = true
                }
                if pathChanged {
                    split.survivingPaths = Self.survivingPaths(of: split.splitters)
                    eraserGestureDocumentSplits[annotation.id] = split
                    changed = true
                }
            }
        }
        if changed { rebuildEraserPreviewMarks() }
    }

    /// The pieces of a multi-path stroke, in path order and then in along-path order.
    ///
    /// The model requires an ink annotation to have at least two points per path, so a malformed
    /// one-point `/InkList` entry cannot be carried into a piece. A file that carries one loses
    /// that entry only when the eraser rebuilds the annotation; a well-formed path is never
    /// dropped.
    private static func survivingPaths(of splitters: [InkStrokeSplitter]) -> [[CGPoint]] {
        splitters.flatMap(\.survivingPaths).filter { $0.count >= 2 }
    }

    /// What the canvas should draw while a drag is cutting: every untouched mark as it is, and
    /// every touched ink stroke as its surviving pieces instead of itself.
    ///
    /// These are previews, not model entries: their identities are derived from the original and
    /// the piece index, so a pointer sample cannot create annotation churn. On release the same
    /// geometry becomes real annotations with real UUIDs and one sidecar write.
    private func rebuildEraserPreviewMarks() {
        guard let base = eraserGestureBase else {
            eraserPreviewMarks = nil
            return
        }
        var marks: [CanvasAnnotationMark] = []
        for annotation in base {
            if let split = eraserGestureSidecarSplits[annotation.id] {
                for (index, path) in split.survivingPaths.enumerated() {
                    marks.append(previewInkMark(
                        id: "erase-preview:\(annotation.id.uuidString):\(index)",
                        page: annotation.page, path: path, color: annotation.color,
                        strokeWidth: annotation.strokeWidth))
                }
            } else if let mark = canvasMark(for: annotation) {
                marks.append(mark)
            }
        }
        for annotation in documentAnnotations {
            if let split = eraserGestureDocumentSplits[annotation.id] {
                let ink = documentInkMark(annotation)
                for (index, path) in split.survivingPaths.enumerated() {
                    marks.append(previewInkMark(
                        id: "erase-preview:pdf:\(annotation.id):\(index)",
                        page: annotation.page, path: path, color: ink.color,
                        strokeWidth: ink.strokeWidth))
                }
            } else if let mark = canvasMark(for: annotation) {
                marks.append(mark)
            }
        }
        eraserPreviewMarks = marks
    }

    private func previewInkMark(id: String, page: Int, path: [CGPoint],
                                color: AnnotationColor,
                                strokeWidth: CGFloat) -> CanvasAnnotationMark {
        CanvasAnnotationMark(
            id: id, page: page, kind: .ink, inkPaths: [path], color: color,
            strokeWidth: strokeWidth, isSelected: false, isEraseTarget: false,
            isEditable: true)
    }

    /// The new ink annotations a split produces, in path order.
    ///
    /// The pieces keep the original's colour and width, which is what makes them look like the
    /// same pen after the cut. Their identities are new. A reader-created stroke's note travels
    /// with its first piece so a comment is never silently dropped; the rest start empty.
    /// `createdAt` stays the original's, because the ink was drawn then even though the pieces
    /// were named now.
    private func inkSegments(from annotation: Annotation,
                             paths: [[CGPoint]]) -> [Annotation] {
        paths.enumerated().map { index, path in
            Annotation(
                id: UUID(),
                kind: .ink,
                page: annotation.page,
                start: 0,
                end: 0,
                color: annotation.color,
                note: index == 0 ? annotation.note : "",
                createdAt: annotation.createdAt,
                inkPaths: [path],
                strokeWidth: annotation.strokeWidth)
        }
    }

    /// The new sidecar ink a file-owned split produces. The original's identity and review
    /// thread are not copied: the original annotation is deleted by identity through the
    /// cross-reader path, and these pieces are the reader's new ink.
    private func inkSegments(from annotation: DocumentAnnotation,
                             paths: [[CGPoint]]) -> [Annotation] {
        let ink = documentInkMark(annotation)
        let now = Date()
        return paths.map { path in
            Annotation(
                id: UUID(),
                kind: .ink,
                page: annotation.page,
                start: 0,
                end: 0,
                color: ink.color,
                note: "",
                createdAt: now,
                inkPaths: [path],
                strokeWidth: ink.strokeWidth)
        }
    }
    /// A PDF-owned ink stroke as the canvas draws it, for hit testing and eraser refusal.
    private func documentInkMark(_ annotation: DocumentAnnotation) -> CanvasAnnotationMark {
        CanvasAnnotationMark(
            id: "pdf:" + annotation.id,
            page: annotation.page,
            kind: .ink,
            inkPaths: annotation.inkPaths,
            color: annotation.color ?? AnnotationColor(red: 0x80, green: 0x80, blue: 0x80,
                                                       alpha: 255),
            strokeWidth: annotation.borderWidthPt ?? 1,
            isSelected: false,
            isEditable: false
        )
    }

    public func selectAnnotation(_ id: UUID?) {
        cancelPendingMarkSelection()
        guard selectedAnnotationID != id else { return }
        selectedAnnotationID = id
        refreshSelectionOverlay()
    }

    /// Deletes the selected annotation (ink, shape, text mark, note or text box). Returns
    /// whether anything was deleted.
    ///
    /// Every kind goes through the same removal: one sidecar write, one undo step, one reload.
    @discardableResult
    public func deleteSelectedAnnotation() -> Bool {
        guard let id = selectedAnnotationID else { return false }
        cancelPendingMarkSelection()
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
        guard before.kind.isPlacement else { return false }
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

    /// Resizes a placed mark to `rect` in page space, as one undo step.
    ///
    /// The drag path calls this through `resizedTextBox`; the checks use it to exercise a
    /// resize without synthesising pointer events. A box below the kind's minimum is refused
    /// rather than silently clamped, so a caller cannot turn a stamp into an invisible mark.
    @discardableResult
    public func resizeAnnotation(_ id: UUID, to rect: CGRect) -> Bool {
        guard let index = annotations.firstIndex(where: { $0.id == id }),
              annotations[index].kind.isPlacement else { return false }
        let before = annotations[index]
        let minimum = Self.minimumPlacementSize(for: before.kind)
        guard rect.width >= minimum.width, rect.height >= minimum.height,
              rect.minX.isFinite, rect.minY.isFinite else { return false }
        var after = before
        after.shapeRect = rect
        guard after.hasValidGeometry else { return false }
        var updated = annotations
        updated[index] = after
        guard saveAnnotations(updated, trigger: "resize-\(after.kind.rawValue)") else { return false }
        undoStack.append(.replaced(before: before, after: after))
        redoStack.removeAll()
        selectedAnnotationID = id
        refreshSelectionOverlay()
        reloadVisiblePages()
        statusMessage = "Resized the \(after.kind.rawValue)"
        return true
    }

    /// The canvas bitmap the reader draws for one stamp the PDF carries.
    ///
    /// Only the checks call this, to prove the same routine the canvas uses produced a picture
    /// from a foreign producer's stamp. It is package-internal for that reason.
    package func documentStampBitmapForCheck(_ documentID: String) -> PageImage? {
        guard let index = documentAnnotations.firstIndex(where: { $0.id == documentID }) else {
            return nil
        }
        let annotation = documentAnnotations[index]
        guard let box = annotation.boxes.first else { return nil }
        return stampGlyphTexture(
            kind: annotation.stampText?.isEmpty == false ? .stamp : .signature,
            text: annotation.stampText ?? "",
            style: annotation.stampStyle,
            color: annotation.color ?? AnnotationColor(red: 0x80, green: 0x80, blue: 0x80,
                                                       alpha: 255),
            imageData: annotation.stampImageData,
            boxPt: CGSize(width: box.widthPt, height: box.heightPt),
            cacheKey: "doc-check:\(index)")
    }

    // MARK: - Adopting and deleting annotations the PDF carries

    /// Moves one annotation the PDF carries into the editable model.
    ///
    /// The file's identity (`/NM`, or the stable fingerprint when there is none) travels with the
    /// sidecar entry; the PDF's copy is removed from `documentAnnotations` so the page shows the
    /// adopted mark exactly once. Nothing about the file changes until an explicit save. Returns
    /// the new entry's id, or `nil` when the kind has no editable model.
    @discardableResult
    public func adoptDocumentAnnotation(_ documentID: String) -> UUID? {
        guard let index = documentAnnotations.firstIndex(where: { $0.id == documentID }) else {
            return nil
        }
        let document = documentAnnotations[index]
        if let reason = Self.documentAnnotationUnsupportedReason(document) {
            lastError = reason
            statusMessage = reason
            return nil
        }
        guard let adopted = Self.adoptedAnnotation(from: document) else {
            let reason = "This annotation has no geometry the reader can edit."
            lastError = reason
            statusMessage = reason
            return nil
        }
        var updated = annotations
        updated.append(adopted)
        guard saveAnnotations(updated, trigger: "adopt-file-annotation") else { return nil }
        if index < documentAnnotations.count, documentAnnotations[index].id == documentID {
            documentAnnotations.remove(at: index)
        } else {
            documentAnnotations.removeAll { $0.id == documentID }
        }
        selectedDocumentAnnotationID = nil
        openDocumentNoteID = nil
        selectedAnnotationID = adopted.id
        undoStack.append(.adoptedFile(annotation: adopted, document: document, index: index))
        redoStack.removeAll()
        refreshSelectionOverlay()
        statusMessage = annotationStatus(adopted)
        return adopted.id
    }

    /// Selects an annotation the PDF carries, adopting it first when it is editable.
    ///
    /// This is the click-selection replacement for the old refusal: a file-owned highlight,
    /// underline, strikeout or text box becomes a normal selected mark, and a sticky note opens
    /// its editor. A kind with no editable model still states the one reason, from
    /// `documentAnnotationEditability`.
    @discardableResult
    public func selectDocumentAnnotation(_ documentID: String) -> Bool {
        if let existing = annotations.first(where: { $0.fileIdentity == documentID }) {
            selectedAnnotationID = existing.id
            selectedDocumentAnnotationID = nil
            refreshSelectionOverlay()
            statusMessage = annotationStatus(existing)
            return true
        }
        guard let index = documentAnnotations.firstIndex(where: { $0.id == documentID }) else {
            return false
        }
        let document = documentAnnotations[index]
        if let reason = Self.documentAnnotationUnsupportedReason(document) {
            selectedDocumentAnnotationID = documentID
            markSelectionRefusalNotice = reason
            statusMessage = reason
            return false
        }
        guard let id = adoptDocumentAnnotation(documentID) else { return false }
        if document.kind == "text", let adopted = annotations.first(where: { $0.id == id }) {
            beginEditingAnnotation(adopted.id)
        }
        return true
    }

    /// Deletes an annotation the PDF carries. The removal is pending until the next save, and
    /// one undo step restores it before it reaches any file.
    ///
    /// Deletion works for every content annotation, whether or not this reader can edit its
    /// fields: the writer only needs the identity, and it takes the annotation's `/IRT` reply
    /// thread and `/Popup` window with it so no reply is left pointing at nothing.
    @discardableResult
    public func deleteDocumentAnnotation(_ documentID: String) -> Bool {
        guard let index = documentAnnotations.firstIndex(where: { $0.id == documentID }) else {
            return false
        }
        let document = documentAnnotations[index]
        if pendingFileDeletions.contains(where: { $0.identity == documentID }) {
            return true
        }
        documentAnnotations.remove(at: index)
        pendingFileDeletions.append(FileAnnotationDeletion(identity: document.id,
                                                           page: document.page))
        if selectedDocumentAnnotationID == documentID { selectedDocumentAnnotationID = nil }
        if openDocumentNoteID == documentID { openDocumentNoteID = nil }
        selectedAnnotationID = nil
        undoStack.append(.deletedFile(document: document, index: index))
        redoStack.removeAll()
        reloadVisiblePages()
        let replyCount = documentAnnotations.filter { $0.isReply && $0.parentID == documentID }.count
        statusMessage = replyCount > 0
            ? "Deleted a file annotation and its \(replyCount) repl\(replyCount == 1 ? "y" : "ies")"
                + " · the PDF is unchanged until you save"
            : "Deleted a file annotation · the PDF is unchanged until you save"
        return true
    }

    /// Changes a colour on the reader's own or an adopted annotation as one undo step.
    @discardableResult
    public func setAnnotationColor(_ id: UUID, to color: AnnotationColor) -> Bool {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return false }
        let before = annotations[index]
        guard before.color != color else { return true }
        var after = before
        after.color = color
        var updated = annotations
        updated[index] = after
        guard saveAnnotations(updated, trigger: "recolor-\(after.kind.rawValue)") else { return false }
        undoStack.append(.replaced(before: before, after: after))
        redoStack.removeAll()
        selectedAnnotationID = id
        refreshSelectionOverlay()
        reloadVisiblePages()
        statusMessage = "Changed the annotation colour"
        return true
    }

    /// Adopts a file annotation and changes its colour in one step.
    @discardableResult
    public func setDocumentAnnotationColor(_ documentID: String, to color: AnnotationColor) -> Bool {
        let id: UUID
        if let existing = annotations.first(where: { $0.fileIdentity == documentID }) {
            id = existing.id
        } else {
            guard let adopted = adoptDocumentAnnotation(documentID) else { return false }
            id = adopted
        }
        return setAnnotationColor(id, to: color)
    }

    /// One line describing a selected mark, shared by the page status and the sidebar.
    private func annotationStatus(_ annotation: Annotation) -> String {
        let noun = annotation.kind == .textBox ? "text box" : annotation.kind.rawValue
        if annotation.isFileOwned {
            return "Selected a \(noun) from the PDF · edit it here, or Delete removes it"
        }
        return "Selected a \(noun) · Delete removes it"
    }

    public func removeAnnotation(_ id: UUID) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        if editingAnnotationID == id {
            noteFlushTask?.cancel()
            noteFlushTask = nil
            noteWindowSawKeystrokes = false
            editingAnnotationID = nil
            editingWasCreated = false
            editingOriginalText = ""
            editingUndoDepth = 0
        }
        if selectedAnnotationID == id { selectedAnnotationID = nil }
        let removed = annotations[index]
        var updated = annotations
        updated.remove(at: index)
        guard saveAnnotations(updated, trigger: "remove") else { return }
        if let identity = removed.fileIdentity,
           !pendingFileDeletions.contains(where: { $0.identity == identity }) {
            pendingFileDeletions.append(
                FileAnnotationDeletion(identity: identity, page: removed.page))
        }
        undoStack.append(.removed(removed))
        redoStack.removeAll()
        reloadVisiblePages()
        statusMessage = removed.isFileOwned
            ? "Deleted a file annotation · the PDF is unchanged until you save"
            : "Deleted annotation"
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

    /// One file-owned ink annotation an eraser gesture removed, with its position in the
    /// `documentAnnotations` array so undo restores the order the page drew it in.
    public struct ErasedFileAnnotation: Equatable, Sendable {
        public let document: DocumentAnnotation
        public let index: Int

        public init(document: DocumentAnnotation, index: Int) {
            self.document = document
            self.index = index
        }
    }

    /// One reversible change. Note edits are represented as old/new values so an edit can
    /// be undone and redone together with annotation creation and deletion.
    public enum UndoableAction: Sendable {
        case added(Annotation)
        case removed(Annotation)
        /// A geometry mark moved, resized or otherwise replaced. The whole annotation is stored
        /// before and after, so undo/redo does not have to know which field the gesture touched.
        case replaced(before: Annotation, after: Annotation)
        case noteChanged(id: UUID, oldNote: String, newNote: String)
        /// Everything one eraser drag changed. The two annotation arrays are the **complete**
        /// before/after state of the sidecar list, so undo restores the exact original strokes —
        /// geometry, order and identities — and redo re-applies the exact pieces. A drag is one
        /// gesture and therefore **one undo step**, even when it splits five strokes into
        /// twelve pieces: one ⌘Z puts the drawing back together, because the reader made one
        /// motion.
        ///
        /// `documents` are file-owned originals removed through the cross-reader path, with
        /// their pre-gesture indices. `deletions` are every file identity the gesture stages for
        /// deletion (including adopted sidecar entries, which are represented in the arrays).
        /// `erasedStrokeIDs` are the reader-created strokes whose absence is pending a PDF.
        case erasedInk(before: [Annotation], after: [Annotation],
                       documents: [ErasedFileAnnotation],
                       deletions: [FileAnnotationDeletion],
                       erasedStrokeIDs: Set<UUID>)
        /// A file annotation was adopted into the editable model. Undo puts it back in the PDF's
        /// list and removes the sidecar entry, exactly as if it had never been touched.
        case adoptedFile(annotation: Annotation, document: DocumentAnnotation, index: Int)
        /// A file annotation was deleted in this session. Undo restores it (and cancels the
        /// pending deletion) until a save makes the removal real.
        case deletedFile(document: DocumentAnnotation, index: Int)
    }

    @Published public private(set) var undoStack: [UndoableAction] = []
    @Published public private(set) var redoStack: [UndoableAction] = []

    public var canUndo: Bool { contentTextEditing ? (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.canUndo == true : (contentEditEnabled ? canUndoPageEdit : !undoStack.isEmpty) }
    public var canRedo: Bool { contentTextEditing ? (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.canRedo == true : (contentEditEnabled ? canRedoPageEdit : !redoStack.isEmpty) }

    public func undo() {
        if contentTextEditing {(NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.undo();return}
        if contentEditEnabled { undoPageEdit(); return }
        guard let action = undoStack.last else { return }
        if editingAnnotationID != nil { commitTextEditing() }
        flushPendingAnnotationWrite()
        // A direct deletion never touched the sidecar, so undo is a pure in-memory restoration
        // (and the pending deletion goes away with it).
        if case .deletedFile(let document, let index) = action {
            pendingFileDeletions.removeAll { $0.identity == document.id }
            if !documentAnnotations.contains(where: { $0.id == document.id }) {
                documentAnnotations.insert(document, at: min(index, documentAnnotations.count))
            }
            undoStack.removeLast()
            redoStack.append(action)
            selectedDocumentAnnotationID = document.id
            reloadVisiblePages()
            statusMessage = "Undo"
            return
        }
        let updated = annotations(applying: action, undoing: true)
        guard saveAnnotations(updated, trigger: "undo") else { return }
        undoStack.removeLast()
        redoStack.append(action)
        switch action {
        case .adoptedFile(_, let document, let index):
            if !documentAnnotations.contains(where: { $0.id == document.id }) {
                documentAnnotations.insert(document, at: min(index, documentAnnotations.count))
            }
            pendingFileDeletions.removeAll { $0.identity == document.id }
        case .removed(let annotation):
            if let identity = annotation.fileIdentity {
                pendingFileDeletions.removeAll { $0.identity == identity }
            }
        case .erasedInk(_, _, let documents, let deletions, let erasedStrokeIDs):
            erasedInkStrokeIDs.subtract(erasedStrokeIDs)
            let identities = Set(deletions.map(\.identity))
            pendingFileDeletions.removeAll { identities.contains($0.identity) }
            for erased in documents.sorted(by: { $0.index < $1.index }) {
                if !documentAnnotations.contains(where: { $0.id == erased.document.id }) {
                    documentAnnotations.insert(
                        erased.document,
                        at: min(erased.index, documentAnnotations.count))
                }
            }
        case .added, .replaced, .noteChanged, .deletedFile:
            break
        }
        reloadVisiblePages()
        statusMessage = "Undo"
    }

    public func redo() {
        if contentTextEditing {(NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.redo();return}
        if contentEditEnabled { redoPageEdit(); return }
        guard let action = redoStack.last else { return }
        if editingAnnotationID != nil { commitTextEditing() }
        flushPendingAnnotationWrite()
        if case .deletedFile(let document, let index) = action {
            documentAnnotations.removeAll { $0.id == document.id }
            if !pendingFileDeletions.contains(where: { $0.identity == document.id }) {
                pendingFileDeletions.append(
                    FileAnnotationDeletion(identity: document.id, page: document.page))
            }
            _ = index
            redoStack.removeLast()
            undoStack.append(action)
            selectedDocumentAnnotationID = nil
            reloadVisiblePages()
            statusMessage = "Redo"
            return
        }
        let updated = annotations(applying: action, undoing: false)
        guard saveAnnotations(updated, trigger: "redo") else { return }
        redoStack.removeLast()
        undoStack.append(action)
        switch action {
        case .adoptedFile(_, let document, _):
            documentAnnotations.removeAll { $0.id == document.id }
            pendingFileDeletions.removeAll { $0.identity == document.id }
        case .removed(let annotation):
            if let identity = annotation.fileIdentity,
               !pendingFileDeletions.contains(where: { $0.identity == identity }) {
                pendingFileDeletions.append(
                    FileAnnotationDeletion(identity: identity, page: annotation.page))
            }
        case .erasedInk(_, _, let documents, let deletions, let erasedStrokeIDs):
            erasedInkStrokeIDs.formUnion(erasedStrokeIDs)
            for deletion in deletions
            where !pendingFileDeletions.contains(where: { $0.identity == deletion.identity }) {
                pendingFileDeletions.append(deletion)
            }
            let removedDocumentIDs = Set(documents.map(\.document.id))
            documentAnnotations.removeAll { removedDocumentIDs.contains($0.id) }
        case .added, .replaced, .noteChanged, .deletedFile:
            break
        }
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
        case .adoptedFile(let annotation, _, _):
            if undoing {
                updated.removeAll { $0.id == annotation.id }
            } else if !updated.contains(where: { $0.id == annotation.id }) {
                updated.append(annotation)
            }
        case .deletedFile:
            break
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
        case .erasedInk(let before, let after, _, _, _):
            // The arrays are the exact sidecar state on either side of the gesture, so restoring
            // them is what guarantees the original identities, geometry and order (and lets redo
            // re-apply the same pieces).
            updated = undoing ? before : after
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
        // Merging is for a burst of typing, not for a later visit to the same note: the first
        // keystroke of an editor session starts a new undo step whose `oldNote` is the text the
        // session began with. The sidebar's inline field opens no session (`editingAnnotationID`
        // is nil) and keeps its original per-burst merging.
        let canMerge: Bool
        if let editingID = editingAnnotationID {
            canMerge = editingID == id && stack.count > editingUndoDepth
        } else {
            canMerge = true
        }
        if canMerge,
           let last = stack.last,
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
        if editingAnnotationID != nil { commitTextEditing() }
        let pendingNote = hasPendingAnnotationWrite
        let pendingPosition = self.pendingPosition != nil
        defer { persistPageEditRecovery() }
        guard pendingNote || pendingPosition else { return }
        if pendingNote { flushPendingAnnotationWrite() }
        if pendingPosition { flushPendingPositionSave() }
        let written = [pendingNote ? "note" : nil, pendingPosition ? "position" : nil]
            .compactMap { $0 }
            .joined(separator: " + ")
        FileHandle.standardError.write(Data("lyra-reader-annotate: flushed pending \(written)\n".utf8))
    }

    /// Shows an annotation: selects its range (or its mark) and scrolls it into view.
    public func jump(to annotation: Annotation) {
        let top = engine.pageTopPt(annotation.page, gapPt: pageGapPt, layout: layoutMode)
        if annotation.kind.isGeometry || annotation.kind.isPlacedText {
            // A geometry mark and a placed note/box have no character range. Select the mark so
            // the overlay shows its halo, and scroll to it rather than to the page's first
            // character.
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

    // MARK: - Forms

    /// The fields of the open document, in reading order (page, then top-to-bottom, then left
    /// to right — the same order Tab walks).
    public var formFields: [FormField] { formInfo.fields }

    public func formField(id: String) -> FormField? {
        formInfo.fields.first { $0.id == id }
    }

    /// Loads the form fields once per open document. Reading never writes.
    private func loadFormInfo() {
        guard document != nil, !formLoadCompleted else { return }
        formLoadCompleted = true
        formLoading = true
        formError = nil
        let epoch = documentEpoch
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if epoch == self.documentEpoch { self.formLoading = false } }
            do {
                let info = try await self.engine.formInfo()
                guard epoch == self.documentEpoch else { return }
                self.formInfo = info
                self.formDraft = [:]
                if let refusal = info.refusal {
                    FileHandle.standardError.write(Data(
                        "lyra-reader-forms: \(refusal)\n".utf8
                    ))
                }
            } catch {
                guard epoch == self.documentEpoch else { return }
                self.formInfo = .empty
                self.formError = "Could not read the document's form fields: \(error.localizedDescription)"
                FileHandle.standardError.write(Data(
                    "lyra-reader-forms: read failed: \(error)\n".utf8
                ))
            }
        }
    }

    /// The value the form currently shows for `field`: the reader's draft when there is one,
    /// otherwise the file's own value.
    public func formCurrentValue(_ field: FormField) -> FormFieldValue {
        if let draft = formDraft[field.id] { return draft }
        switch field.kind {
        case .text:
            return FormFieldValue(fieldID: field.id, text: field.value ?? "")
        case .checkBox:
            return FormFieldValue(fieldID: field.id, checked: field.checked)
        case .radio, .comboBox, .listBox:
            return FormFieldValue(fieldID: field.id, selected: field.selected.first)
        case .signature:
            return FormFieldValue(fieldID: field.id)
        }
    }

    public func formCurrentText(_ field: FormField) -> String {
        formCurrentValue(field).text ?? ""
    }

    public func formCurrentChecked(_ field: FormField) -> Bool {
        formCurrentValue(field).checked ?? false
    }

    public func formCurrentSelection(_ field: FormField) -> Int? {
        formCurrentValue(field).selected
    }

    /// Whether the field holds a value on screen now. An empty text field is not filled.
    public func formValueIsFilled(_ field: FormField) -> Bool {
        switch field.kind {
        case .text:
            return !formCurrentText(field).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .checkBox:
            return formCurrentChecked(field)
        case .radio, .comboBox, .listBox:
            return formCurrentSelection(field) != nil
        case .signature:
            return false
        }
    }

    /// How many fields the reader has filled (including values the file already carried).
    public var formFilledCount: Int {
        formInfo.fields.filter { $0.editable && formValueIsFilled($0) }.count
    }

    /// The fields whose on-screen value differs from the file's.
    public var formChangedFields: [FormField] {
        formInfo.fields.filter { field in
            guard field.editable else { return false }
            let current = formCurrentValue(field)
            switch field.kind {
            case .text:
                return (current.text ?? "") != (field.value ?? "")
            case .checkBox:
                return (current.checked ?? false) != field.checked
            case .radio, .comboBox, .listBox:
                return current.selected != field.selected.first
            case .signature:
                return false
            }
        }
    }

    public var formHasPendingChanges: Bool { !formChangedFields.isEmpty }

    /// The banner's first line, in the same language as the page-edit session's.
    public var formPendingSummary: String? {
        guard formHasPendingChanges else { return nil }
        let count = formChangedFields.count
        let noun = count == 1 ? "1 form change pending" : "\(count) form changes pending"
        return "\(noun) · the file on disk is unchanged"
    }

    public var canSaveFilledForm: Bool {
        document != nil && formHasPendingChanges
            && !formSaveInProgress && !formInfo.encrypted
    }

    /// Writing values into the signed file itself. The copy command above stays available.
    public var canReplaceOriginalWithFilledForm: Bool {
        canSaveFilledForm && !isReadOnlyDocument
    }

    /// Whether the Fill & Sign placeholder has something to offer.
    public var canUseFormTool: Bool {
        document != nil && !formInfo.encrypted
            && formInfo.fields.contains(where: { $0.editable })
    }

    /// The toolbar button. Activating the form tool leaves the annotation tool in its normal
    /// selection mode, so a click on a field is an edit and a click elsewhere still reads.
    public func toggleFormTool() {
        guard document != nil else { return }
        if formInfo.encrypted {
            lastError = formInfo.refusal
                ?? "This PDF is encrypted, so the reader will not fill it."
            return
        }
        guard canUseFormTool else {
            statusMessage = formInfo.fields.isEmpty
                ? "This document has no form fields"
                : "This document has no fillable form fields"
            return
        }
        if formToolActive {
            leaveFormTool()
            return
        }
        formToolActive = true
        annotationTool = .select
        formFocusedFieldID = nil
        formOpenChoiceFieldID = nil
        statusMessage = formHasPendingChanges
            ? (formPendingSummary ?? "Form tool: click a field to fill it")
            : "Form tool: click a field to fill it · Tab next field · Esc leaves"
        FileHandle.standardError.write(Data(
            "lyra-reader-forms: tool on · \(formInfo.fields.count) field(s) · "
            .appending("encrypted: \(formInfo.encrypted)\n").utf8
        ))
    }

    /// Escape on the canvas: leave the form tool when it is active. Returns whether a mode was
    /// consumed, so the canvas can fall through to its other Escape handling when it was not.
    @discardableResult
    public func cancelFormTool() -> Bool {
        guard formToolActive || formFocusedFieldID != nil else { return false }
        leaveFormTool()
        return true
    }

    /// Leaves the form tool and returns the canvas to normal reading. Pending values stay in the
    /// reader and the banner keeps saying so; only an explicit save writes them.
    public func leaveFormTool() {
        let wasActive = formToolActive || formFocusedFieldID != nil
        formToolActive = false
        formFocusedFieldID = nil
        formOpenChoiceFieldID = nil
        if wasActive {
            statusMessage = formHasPendingChanges
                ? (formPendingSummary ?? "Reading mode")
                : "Reading mode · form values are unchanged"
        }
    }

    /// Puts the keyboard in a field. Only the form tool can focus an editable field.
    public func focusFormField(_ id: String) {
        guard formToolActive, let field = formField(id: id), field.editable else { return }
        formFocusedFieldID = id
        formOpenChoiceFieldID = field.kind == .comboBox ? id : nil
    }

    /// Ends field editing without leaving the tool. Escape in a field calls this.
    public func blurFormField() {
        formFocusedFieldID = nil
        formOpenChoiceFieldID = nil
    }

    /// Tab order: the engine's reading order — page ascending, then the widget's top edge
    /// top-to-bottom, then its left edge. Wraps around at both ends.
    public func focusNextFormField(backwards: Bool = false) {
        let editable = formInfo.fields.filter { $0.editable }
        guard !editable.isEmpty else { return }
        let current = formFocusedFieldID.flatMap { id in
            editable.firstIndex { $0.id == id }
        }
        let next: Int
        if let current {
            next = (current + (backwards ? -1 : 1) + editable.count) % editable.count
        } else {
            next = backwards ? editable.count - 1 : 0
        }
        let field = editable[next]
        formFocusedFieldID = field.id
        formOpenChoiceFieldID = field.kind == .comboBox ? field.id : nil
    }

    /// One text edit. `maxLength` is enforced as characters, matching how PDF `/MaxLen` counts.
    public func updateFormText(_ id: String, text: String) {
        guard let field = formField(id: id), field.kind == .text, field.editable else { return }
        var value = text
        if let maxLength = field.maxLength, value.count > maxLength {
            value = String(value.prefix(maxLength))
        }
        formDraft[id] = FormFieldValue(fieldID: id, text: value)
    }

    public func toggleFormCheckbox(_ id: String) {
        guard let field = formField(id: id), field.kind == .checkBox, field.editable else { return }
        formDraft[id] = FormFieldValue(fieldID: id, checked: !formCurrentChecked(field))
        formFocusedFieldID = id
        formOpenChoiceFieldID = nil
    }

    public func selectFormRadioOption(_ id: String, index: Int) {
        guard let field = formField(id: id), field.kind == .radio, field.editable,
              field.options.indices.contains(index) else { return }
        formDraft[id] = FormFieldValue(fieldID: id, selected: index)
        formFocusedFieldID = id
        formOpenChoiceFieldID = nil
    }

    public func selectFormChoice(_ id: String, index: Int) {
        guard let field = formField(id: id), field.kind.isChoice, field.editable,
              field.options.indices.contains(index) else { return }
        formDraft[id] = FormFieldValue(fieldID: id, selected: index)
        formFocusedFieldID = id
        formOpenChoiceFieldID = nil
    }

    /// The drop-down's option list open/closed state (the combo is the only popup; a list box
    /// shows its options inside its rectangle).
    public func toggleFormChoiceMenu(_ id: String) {
        guard let field = formField(id: id), field.kind == .comboBox, field.editable else { return }
        formFocusedFieldID = id
        formOpenChoiceFieldID = formOpenChoiceFieldID == id ? nil : id
    }

    public func discardFormChanges() {
        guard formHasPendingChanges else {
            statusMessage = "There are no form changes to discard"
            return
        }
        formDraft = [:]
        formFocusedFieldID = nil
        formOpenChoiceFieldID = nil
        statusMessage = "Form changes discarded · the file on disk is unchanged"
    }

    /// The values an explicit save sends: only the fields that differ from the file, with the
    /// complete value a writer needs (a choice carries its option's export value).
    private func formValueRecords() -> [FormFieldValue] {
        formChangedFields.map { field in
            let current = formCurrentValue(field)
            switch field.kind {
            case .text:
                return FormFieldValue(fieldID: field.id, text: current.text ?? "")
            case .checkBox:
                return FormFieldValue(fieldID: field.id, checked: current.checked ?? false)
            case .radio:
                return FormFieldValue(fieldID: field.id, selected: current.selected)
            case .comboBox, .listBox:
                let index = current.selected
                let value = index.flatMap { field.options.indices.contains($0) ? field.options[$0].value : nil }
                return FormFieldValue(fieldID: field.id, text: value, selected: index)
            case .signature:
                return FormFieldValue(fieldID: field.id)
            }
        }
    }

    public func presentSaveFilledFormPanel() {
        guard let url = document?.url else { return }
        guard formHasPendingChanges else {
            statusMessage = "There are no form changes to save"
            return
        }
        let suggestion = engine.suggestedFilledCopyURL(for: url)
        let panel = NSSavePanel()
        panel.title = "Save Filled Form Copy"
        panel.message =
            "The values in the reader are written into a copy. The original file is not modified."
        panel.nameFieldStringValue = suggestion.lastPathComponent
        panel.directoryURL = suggestion.deletingLastPathComponent()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { @MainActor [weak self] in
            await self?.saveFilledForm(to: destination)
        }
    }

    /// Writes the pending values into a new PDF through the verified incremental save.
    @discardableResult
    public func saveFilledForm(to destination: URL) async -> Bool {
        guard let url = document?.url else {
            lastError = "Open a document before filling its form"
            return false
        }
        let values = formValueRecords()
        guard !values.isEmpty else {
            statusMessage = "There are no form changes to save"
            return false
        }
        guard !formInfo.encrypted else {
            lastError = formInfo.refusal
                ?? "This PDF is encrypted, so the reader will not fill it."
            return false
        }
        formSaveInProgress = true
        defer { formSaveInProgress = false }
        do {
            let report = try await engine.saveFilledForm(to: destination, values: values)
            statusMessage =
                "Saved \(report.writtenFieldIDs.count) filled field(s) to "
                + "\(destination.lastPathComponent)"
                + (report.sourceBytesPreserved
                   ? " · \(report.appendedBytes) bytes appended"
                   : " · signature fields removed from the copy")
                + " · the original is unchanged"
            FileHandle.standardError.write(Data((
                "lyra-reader-forms: saved \(report.writtenFieldIDs.count) field(s) to "
                + "\(destination.path) (append \(report.appendedBytes) bytes)\n"
            ).utf8))
            return true
        } catch {
            lastError = "Could not save the filled copy: \(error.localizedDescription)"
            statusMessage = "Could not save the filled form"
            FileHandle.standardError.write(Data(
                "lyra-reader-forms: copy save failed (\(url.lastPathComponent)): \(error)\n".utf8
            ))
            return false
        }
    }

    public func presentReplaceOriginalWithFilledFormConfirmation() {
        guard guardWritable() else { return }
        guard canReplaceOriginalWithFilledForm else { return }
        guard let url = document?.url else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Replace “\(url.lastPathComponent)” with the filled form?"
        alert.informativeText =
            "This changes the file on disk. A byte-identical backup is written first; if the "
            + "backup cannot be written and verified, nothing is replaced. The widgets stay "
            + "interactive."
        alert.addButton(withTitle: "Save and Replace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor [weak self] in
            await self?.replaceOriginalWithFilledForm()
        }
    }

    @discardableResult
    public func replaceOriginalWithFilledForm() async -> Bool {
        guard guardWritable() else { return false }
        guard let url = document?.url else {
            lastError = "Open a document before filling its form"
            return false
        }
        let values = formValueRecords()
        guard !values.isEmpty else {
            statusMessage = "There are no form changes to save"
            return false
        }
        formSaveInProgress = true
        defer { formSaveInProgress = false }
        do {
            let report = try await engine.replaceWithFilledForm(values)
            let backup = report.backupPath?.lastPathComponent ?? "none"
            formDraft = [:]
            formInfo = .empty
            formToolActive = false
            formFocusedFieldID = nil
            formOpenChoiceFieldID = nil
            formLoadCompleted = false
            _ = open(url: url)
            statusMessage =
                "Saved \(report.writtenFieldIDs.count) filled field(s) into "
                + "\(url.lastPathComponent) · backup: \(backup)"
            FileHandle.standardError.write(Data((
                "lyra-reader-forms: replaced \(url.path) with \(report.writtenFieldIDs.count) "
                + "field(s), backup \(backup)\n"
            ).utf8))
            return true
        } catch {
            lastError = "Could not replace the original: \(error.localizedDescription)"
            statusMessage = "Could not replace the original"
            FileHandle.standardError.write(Data(
                "lyra-reader-forms: replace failed: \(error)\n".utf8
            ))
            return false
        }
    }

    // MARK: - Document properties

    /// Loads the facts and `/Info` entries when the information panel opens. The recognized
    /// metadata panel is a separate, layout-based view; these are the file's own dictionary.
    public func loadDocumentInfo(force: Bool = false) {
        guard document != nil else {
            documentInfo = nil
            return
        }
        if documentInfoLoading { return }
        if !force, documentInfo != nil { return }
        documentInfoLoading = true
        documentInfoError = nil
        let epoch = documentEpoch
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if epoch == self.documentEpoch { self.documentInfoLoading = false } }
            do {
                let info = try await self.engine.documentInfo()
                guard epoch == self.documentEpoch else { return }
                self.documentInfo = info
                self.documentPropertiesDraft = DocumentProperties(
                    title: info.title,
                    author: info.author,
                    subject: info.subject,
                    keywords: info.keywords
                )
            } catch {
                guard epoch == self.documentEpoch else { return }
                self.documentInfoError = "Could not read the document information: "
                    + error.localizedDescription
                self.documentInfo = nil
            }
        }
    }

    public func updateDocumentProperty(_ key: DocumentPropertyKey, text: String) {
        switch key {
        case .title: documentPropertiesDraft.title = text
        case .author: documentPropertiesDraft.author = text
        case .subject: documentPropertiesDraft.subject = text
        case .keywords: documentPropertiesDraft.keywords = text
        }
    }

    public var documentPropertiesAreDirty: Bool {
        guard let info = documentInfo else { return false }
        return documentPropertiesDraft.title != info.title
            || documentPropertiesDraft.author != info.author
            || documentPropertiesDraft.subject != info.subject
            || documentPropertiesDraft.keywords != info.keywords
    }

    public var canSaveDocumentProperties: Bool {
        document != nil && documentInfo != nil
            && documentPropertiesAreDirty && !propertiesSaveInProgress
            && !(documentInfo?.isEncrypted ?? true)
    }

    /// Writing properties into the signed file itself. The copy command above stays available.
    public var canReplaceOriginalWithDocumentProperties: Bool {
        canSaveDocumentProperties && !isReadOnlyDocument
    }

    /// Why the Save buttons are disabled, shown in the panel. Nil when they are available.
    public var documentPropertiesRefusal: String? {
        guard let info = documentInfo else { return nil }
        if info.isEncrypted {
            return "This PDF is encrypted. The reader will not write its document information: "
                + "the new dictionary would need the security envelope rewritten, and a file "
                + "written anyway might not open in another viewer."
        }
        return nil
    }

    public func presentSaveDocumentPropertiesPanel() {
        guard let url = document?.url else { return }
        guard documentPropertiesAreDirty else {
            statusMessage = "The document information has no changes to save"
            return
        }
        let suggestion = engine.suggestedPropertiesCopyURL(for: url)
        let panel = NSSavePanel()
        panel.title = "Save Document Properties Copy"
        panel.message =
            "The four information entries are written into a copy. The original file is not modified."
        panel.nameFieldStringValue = suggestion.lastPathComponent
        panel.directoryURL = suggestion.deletingLastPathComponent()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { @MainActor [weak self] in
            await self?.saveDocumentProperties(to: destination)
        }
    }

    @discardableResult
    public func saveDocumentProperties(to destination: URL) async -> Bool {
        guard let url = document?.url else {
            lastError = "Open a document before editing its properties"
            return false
        }
        guard documentPropertiesAreDirty else {
            statusMessage = "The document information has no changes to save"
            return false
        }
        guard documentInfo?.isEncrypted != true else {
            lastError = documentPropertiesRefusal
                ?? "This PDF is encrypted, so its document properties cannot be saved."
            return false
        }
        propertiesSaveInProgress = true
        defer { propertiesSaveInProgress = false }
        do {
            let report = try await engine.saveDocumentProperties(
                to: destination,
                properties: documentPropertiesDraft
            )
            statusMessage =
                "Saved the document properties to \(destination.lastPathComponent)"
                + (report.sourceBytesPreserved
                   ? " · \(report.appendedBytes) bytes appended"
                   : " · signature fields removed from the copy")
                + " · the original is unchanged"
            FileHandle.standardError.write(Data((
                "lyra-reader-properties: saved \(report.writtenKeys.joined(separator: ",")) to "
                + "\(destination.path)\n"
            ).utf8))
            return true
        } catch {
            lastError = "Could not save the document properties: \(error.localizedDescription)"
            statusMessage = "Could not save the document properties"
            FileHandle.standardError.write(Data(
                "lyra-reader-properties: copy save failed (\(url.lastPathComponent)): \(error)\n".utf8
            ))
            return false
        }
    }

    public func presentReplaceOriginalWithPropertiesConfirmation() {
        guard guardWritable() else { return }
        guard canReplaceOriginalWithDocumentProperties else { return }
        guard let url = document?.url else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Write the document properties into “\(url.lastPathComponent)”?"
        alert.informativeText =
            "This changes the file on disk. A byte-identical backup is written first; if the "
            + "backup cannot be written and verified, nothing is replaced."
        alert.addButton(withTitle: "Save and Replace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor [weak self] in
            await self?.replaceOriginalWithProperties()
        }
    }

    @discardableResult
    public func replaceOriginalWithProperties() async -> Bool {
        guard guardWritable() else { return false }
        guard let url = document?.url else {
            lastError = "Open a document before editing its properties"
            return false
        }
        guard documentPropertiesAreDirty else {
            statusMessage = "The document information has no changes to save"
            return false
        }
        guard documentInfo?.isEncrypted != true else {
            lastError = documentPropertiesRefusal
                ?? "This PDF is encrypted, so its document properties cannot be saved."
            return false
        }
        propertiesSaveInProgress = true
        defer { propertiesSaveInProgress = false }
        do {
            let report = try await engine.replaceWithDocumentProperties(documentPropertiesDraft)
            let backup = report.backupPath?.lastPathComponent ?? "none"
            documentInfo = nil
            _ = open(url: url)
            loadDocumentInfo(force: true)
            statusMessage =
                "Saved the document properties into \(url.lastPathComponent)"
                + " · backup: \(backup)"
            return true
        } catch {
            lastError = "Could not replace the original: \(error.localizedDescription)"
            statusMessage = "Could not replace the original"
            return false
        }
    }

    // MARK: - Signed documents (read-only)

    /// The signature evidence for the open document, read by the engine once at open.
    public var documentSignature: DocumentSignature { pageEditSession?.originalSignature ?? document?.signature ?? .unsigned }

    /// True when the file carries a digital signature and every **in-place** write is refused.
    ///
    /// Edits are still allowed: they go to the sidecar and can be saved to a new file. The
    /// decision lives in Rust; the shell mirrors it only to disable the in-place controls and
    /// explain them. A direct engine call is still refused by the same gate, so a stale button
    /// cannot rewrite a signed file.
    public var isReadOnlyDocument: Bool { documentSignature.signed }

    /// The one sentence every in-place write refuses with.
    public var readOnlyReason: String? { documentSignature.readOnlyReason }

    /// The banner's headline. The reason below it names the evidence.
    public var readOnlyBannerTitle: String { "Signed PDF · read-only in place" }

    /// The evidence, one line, for the banner's second line.
    public var readOnlyBannerEvidence: String {
        documentSignature.evidence.map(\.detail).joined(separator: " · ")
    }

    /// What a signed document can still do. Shown in the banner next to the reason.
    public var readOnlyBannerNote: String {
        "Saving a copy is allowed; the copy leaves the signature fields out."
    }

    /// True when annotation tools may create or remove marks. Sidecar edits are allowed for a
    /// signed document too: they can be written to a copy, and the signed original is untouched.
    public var canEditAnnotations: Bool { document != nil }

    /// Refuses an in-place write and states the shared reason. Returns true when the file is
    /// writable.
    ///
    /// Every public replace/original write entry point calls this before doing anything, so a
    /// call that bypasses a disabled button still gets the same answer as the UI.
    @discardableResult
    private func guardWritable() -> Bool {
        guard let reason = readOnlyReason else { return true }
        lastError = reason
        statusMessage = "Signed PDF · read-only"
        FileHandle.standardError.write(Data(
            "lyra-reader-signature: write refused · \(reason)\n".utf8
        ))
        return false
    }

    // MARK: - Saving annotations into the PDF

    public var canSaveDocument: Bool {
        document != nil && !pageEditBusy && !annotationSaveInProgress &&
            (canSaveAnnotationsToPDF || canSavePageEditsCopy || contentCommandInFlight)
    }

    public func saveDocument() {
        if isReadOnlyDocument { presentSaveDocumentCopyPanel(); return }
        Task { @MainActor [weak self] in _ = await self?.saveDocumentToOriginal() }
    }

    public func presentSaveDocumentCopyPanel() {
        if pageEditSession != nil || contentTextEditing { presentSavePageEditsCopyPanel() }
        else { presentSaveAnnotatedCopyPanel() }
    }

    @discardableResult
    public func saveDocumentToOriginal() async -> Bool {
        guard guardWritable(), document != nil, contentTextRecovery == nil else { return false }
        commitContentText?()
        if let task = contentEditTask {
            let succeeded = await task.value
            contentEditTask = nil
            if !succeeded { return false }
        }
        if pageEditSession != nil { return await replaceOriginalWithPageEdits() }
        return await replaceOriginalWithSavedAnnotations()
    }

    /// Whether the two PDF-writing commands can run.
    ///
    /// The sidecar is an unsaved-work store, not the feature: saving is always an explicit
    /// command from the reader, and it is disabled when there is nothing to write. A pending
    /// erasure counts even when it removed the last annotation: the copy must still be
    /// obtainable so the eraser's "Save Copy…" action cannot become a disabled promise.
    public var canSaveAnnotationsToPDF: Bool {
        guard document != nil, !annotationSaveInProgress else { return false }
        // A signed document cannot be edited, but exporting a copy (with whatever sidecar
        // annotations it already carries, or none) never touches the signed original.
        if isReadOnlyDocument { return true }
        return annotationCacheIsDirty || hasPendingInkErasure || hasPendingFileDeletions
    }

    /// Whether the open document's outline already contains the reader's marked bookmark
    /// subtree. Deleting the last bookmark still has something to save: the save removes that
    /// subtree, so the command must not become disabled at exactly that moment.
    public var hasEmbeddedBookmarkSubtree: Bool {
        outline.contains { $0.isBookmarkSubtree }
    }

    /// Replacing the original has something to write when an annotation or bookmark remains, or
    /// when the file already carries the reader's bookmark subtree (deleting the last bookmark
    /// still has work to do: removing it). A copy is still offered after the eraser removed the
    /// last annotation (it is the source bytes), but replacing a file with an identical copy
    /// would be a destructive no-op with a backup.
    public var canReplaceOriginalWithAnnotations: Bool {
        canSaveAnnotationsToPDF && !isReadOnlyDocument
            && (!annotations.isEmpty || !bookmarks.isEmpty
                || hasEmbeddedBookmarkSubtree || hasPendingFileDeletions)
    }

    /// The name an annotated copy is offered as: `<name> (annotated).pdf`.
    public var suggestedAnnotatedCopyURL: URL? {
        guard let url = document?.url else { return nil }
        return engine.suggestedAnnotatedCopyURL(for: url)
    }

    /// The Save Annotated Copy panel. The writer's only job is to produce a new file; the
    /// document on screen (and its sidecar) stays exactly where it is.
    public func presentSaveAnnotatedCopyPanel() {
        if pageEditSession != nil || contentTextEditing { presentSavePageEditsCopyPanel(); return }
        guard let suggestion = suggestedAnnotatedCopyURL else { return }
        let panel = NSSavePanel()
        panel.title = "Save Annotated Copy"
        panel.message =
            "Every highlight, ink mark, note, text box and bookmark in the reader's list is written "
            + "into a new PDF. The original file is not modified."
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
        guard canReplaceOriginalWithAnnotations, let url = document?.url else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText =
            "Replace “\(url.lastPathComponent)” with the reader's annotations and bookmarks?"
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
    /// the annotations itself, so a fresh LyraReader opening that copy sees them from the PDF and no
    /// sidecar duplicates them. When an eraser gesture removed the last annotation there is
    /// nothing to append, and the copy is the source file byte for byte. Returns `false` when
    /// nothing was written.
    @discardableResult
    public func saveAnnotatedCopy(to destination: URL) async -> Bool {
        if pageEditSession != nil || contentTextEditing { return await savePageEditsCopy(to: destination) }
        guard !annotationSaveInProgress else { return false }
        guard let documentURL = document?.url else {
            lastError = "Open a document before saving annotations"
            return false
        }
        guard !annotations.isEmpty || !bookmarks.isEmpty || hasEmbeddedBookmarkSubtree
                || hasPendingInkErasure || hasPendingFileDeletions
                || isReadOnlyDocument else {
            statusMessage = "There are no annotations or bookmarks to save"
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
                "“\(destination.lastPathComponent)” already has a LyraReader annotation sidecar. "
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
            let changes = try await pendingAnnotationChanges()
            let bookmarkRequests = bookmarkWriteRequests()
            if changes.isEmpty && bookmarkRequests.isEmpty {
                // The eraser removed the last annotation and there is no bookmark to write, or
                // the document is signed and has nothing the reader may add: the engine
                // deliberately refuses an empty request. The honest copy is the source bytes.
                // It still matters: the pending banner (or the signed banner's copy promise)
                // offers "Save Copy…" and that action must work precisely in this case.
                let source = try Data(contentsOf: documentURL, options: .mappedIfSafe)
                try source.write(to: destination, options: .atomic)
                lastAnnotationWriteReport = AnnotationWriteReport(
                    destinationPath: destination.path,
                    writtenIDs: [],
                    writtenBookmarkIDs: [],
                    bookmarkOutlineTitle: nil,
                    preexistingOutlineEntryCount: 0,
                    appendedBytes: 0,
                    backupPath: nil,
                    preexistingAnnotationCount: documentAnnotations.count,
                    cleanedTemporaryFiles: 0,
                    sourceBytesPreserved: true
                )
                erasedInkStrokeIDs.removeAll()
                statusMessage = isReadOnlyDocument
                    ? "Saved a copy of the signed PDF to \(destination.lastPathComponent)"
                        + " · the original is unchanged"
                    : "Saved a copy without annotations to \(destination.lastPathComponent)"
                        + " · the original is unchanged"
                FileHandle.standardError.write(Data((
                    "lyra-reader-annotate: saved a byte copy to \(destination.path)"
                    + (isReadOnlyDocument ? " (signed, export only)\n" : " (without annotations)\n")
                ).utf8))
                return true
            }
            let report = try await engine.saveAnnotationChanges(
                to: destination,
                additions: changes.additions,
                bookmarks: bookmarkRequests,
                updates: changes.updates,
                deletions: changes.deletions,
                zoom: zoomFactor
            )
            lastAnnotationWriteReport = report
            // The erasure now exists in a PDF (the copy), so the pending-erasure banner has
            // nothing left to warn about. The open document and its sidecar are unchanged; a
            // pending *file deletion* stays pending because the open file still has the mark.
            erasedInkStrokeIDs.removeAll()
            let backup = report.backupPath.map { " · backup \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? ""
            let written = Self.markCount(
                annotations: report.writtenIDs.count,
                bookmarks: report.writtenBookmarkIDs.count
            )
            let deleted = changes.deletions.count
            let outcome = report.fullRewrite
                ? " · pruned the removed annotations out of the saved bytes"
                : (report.sourceBytesPreserved
                   ? " · \(report.appendedBytes) bytes appended"
                   : " · signature fields removed from the copy")
            statusMessage =
                "Saved \(written) to \(destination.lastPathComponent)"
                + (deleted > 0 ? " · \(deleted) annotation(s) deleted" : "")
                + "\(outcome) · the original is unchanged\(backup)"
            FileHandle.standardError.write(Data((
                "lyra-reader-annotate: saved \(written), \(deleted) annotation deletion(s) to \(destination.path)"
                + " (\(outcome))\(backup)\n"
            ).utf8))
            return true
        } catch {
            lastError = "Could not save the annotated copy: \(error.localizedDescription)"
            statusMessage = "Could not save the annotated copy"
            FileHandle.standardError.write(
                Data("lyra-reader-annotate: annotated-copy save failed: \(error)\n".utf8)
            )
            return false
        }
    }

    /// Replaces the open document with one carrying the reader's annotations and bookmarks.
    ///
    /// The engine writes a verified backup first and replaces the original by an atomic rename
    /// of a verified temporary file. Only after that succeeds are exactly the saved sidecar
    /// entries removed; the document is reopened so its annotations and bookmark subtree now
    /// come from the PDF.
    /// Returns `false` when nothing was replaced.
    @discardableResult
    public func replaceOriginalWithSavedAnnotations() async -> Bool {
        if pageEditSession != nil { return await replaceOriginalWithPageEdits() }
        guard guardWritable() else { return false }
        guard !annotationSaveInProgress else { return false }
        guard let url = document?.url else {
            lastError = "Open a document before saving annotations"
            return false
        }
        guard !annotations.isEmpty || !bookmarks.isEmpty || hasEmbeddedBookmarkSubtree
                || hasPendingFileDeletions else {
            annotationCacheIsDirty = false
            persistPendingAnnotationState()
            statusMessage = "There are no annotations or bookmarks to save"
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
            try DocumentEditCache.validateSource(for: url)
            let changes = try await pendingAnnotationChanges()
            let bookmarkRequests = bookmarkWriteRequests()
            let report = try await engine.replaceWithAnnotationChanges(
                changes.additions,
                bookmarks: bookmarkRequests,
                updates: changes.updates,
                deletions: changes.deletions,
                zoom: zoomFactor
            )

            try? DocumentEditCache.recordSource(for: url)

            // The PDF is now the source of truth. Remove exactly the written entries and the
            // adopted entries whose annotation was deleted (including a thread's cascaded
            // replies) from the sidecar, so reopening shows each annotation once.
            let deletedFileIDs = Set(report.deletedFileIDs)
            let writtenEntries = Set(report.writtenIDs.compactMap { UUID(uuidString: $0) })
            let deletedAdopted = Set(annotations.compactMap { annotation -> UUID? in
                guard let identity = annotation.fileIdentity,
                      deletedFileIDs.contains(identity) else { return nil }
                return annotation.id
            })
            let cleanedAnnotations = forgetAnnotationsSavedToPDF(ids: writtenEntries.union(deletedAdopted))
            let cleanedBookmarks = forgetBookmarksSavedToPDF(
                ids: Set(report.writtenBookmarkIDs.compactMap { UUID(uuidString: $0) })
            )
            let cleanedSidecar = cleanedAnnotations && cleanedBookmarks
            pendingFileDeletions.removeAll()
            annotationCacheIsDirty = false
            persistPendingAnnotationState()

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
            // The file now carries the bookmark subtree; reload the outline so the sidebar can
            // show it (and adopt the file's bookmarks instead of a duplicate sidecar list).
            outline = []
            outlineLoadCompleted = false
            loadOutline()
            loadDocumentAnnotations()
            reloadVisiblePages()

            lastAnnotationWriteReport = report
            // The current annotations (and therefore the erasures) are in the PDF itself now.
            erasedInkStrokeIDs.removeAll()
            if !cleanedSidecar {
                lastError =
                    "The annotations are saved in the PDF, but the sidecar could not be updated. "
                    + "They will be reconciled the next time the document is opened, so they do not appear twice."
            }
            let backup = report.backupPath
                .map { URL(fileURLWithPath: $0).lastPathComponent } ?? "none"
            let written = Self.markCount(
                annotations: report.writtenIDs.count,
                bookmarks: report.writtenBookmarkIDs.count
            )
            let deletedCount = report.deletedFileIDs.count
            statusMessage =
                "Saved \(written) into \(url.lastPathComponent)"
                + (deletedCount > 0 ? " · \(deletedCount) annotation(s) deleted" : "")
                + (report.fullRewrite ? " · removed content pruned from the file" : "")
                + " · backup: \(backup)"
            if report.deletedReplyCount > 0 {
                statusMessage += " · \(report.deletedReplyCount) repl\(report.deletedReplyCount == 1 ? "y" : "ies") removed with their thread"
            }
            if !cleanedSidecar {
                statusMessage += " · the sidecar could not be updated and will be reconciled on open"
            }
            FileHandle.standardError.write(Data((
                "lyra-reader-annotate: replaced \(url.path) with \(written),"
                + " \(deletedCount) annotation deletion(s), backup \(backup), sidecar cleaned: \(cleanedSidecar)\n"
            ).utf8))
            return true
        } catch {
            lastError = "Could not replace the original: \(error.localizedDescription)"
            statusMessage = "Could not replace the original"
            FileHandle.standardError.write(
                Data("lyra-reader-annotate: replace failed: \(error)\n".utf8)
            )
            return false
        }
    }

    /// The current bookmarks as writer requests, in the order the sidebar shows them.
    private func bookmarkWriteRequests() -> [BookmarkWriteRequest] {
        bookmarks.map { bookmark in
            BookmarkWriteRequest(
                id: bookmark.id,
                page: bookmark.page,
                title: bookmark.title,
                yPt: bookmark.yPt
            )
        }
    }

    /// A count for the status line that names both kinds only when both were written.
    private static func markCount(annotations: Int, bookmarks: Int) -> String {
        switch (annotations, bookmarks) {
        case (0, 0): return "0 marks"
        case (0, let bookmarks): return "\(bookmarks) bookmark(s)"
        case (let annotations, 0): return "\(annotations) annotation(s)"
        case (let annotations, let bookmarks):
            return "\(annotations) annotation(s) and \(bookmarks) bookmark(s)"
        }
    }

    /// Builds write requests from the sidecar annotations.
    ///
    /// The quads are the same `TextPage.selectionRects` the canvas draws, scaled to the zoom the
    /// reader is at now. They are **view-space** on purpose: the engine inverts that scale with
    /// the page geometry, so the stored PDF coordinates do not depend on the zoom this happened
    /// to be called at.
    private func pendingAnnotationChanges() async throws -> PendingAnnotationChanges {
        guard let document else { return PendingAnnotationChanges() }
        let zoom = zoomFactor
        let modified = Self.pdfDate(Date())
        var changes = PendingAnnotationChanges()
        func record(_ request: AnnotationWriteRequest, for annotation: Annotation) {
            if let identity = annotation.fileIdentity {
                let assigned = identity.hasPrefix("fp:") ? annotation.id.uuidString : nil
                changes.updates.append(AnnotationUpdateRequest(
                    target: identity, annotation: request, assignedName: assigned))
            } else {
                changes.additions.append(request)
            }
        }
        for annotation in annotations {
            guard annotation.page >= 0, annotation.page < document.pageCount else {
                throw NSError(
                    domain: "LyraReader",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Annotation \(annotation.id.uuidString) names page \(annotation.page + 1), which is outside this document"]
                )
            }
            if annotation.kind.isPlacedText {
                record(try placedTextWriteRequest(annotation, zoom: zoom, modified: modified),
                       for: annotation)
                continue
            }
            if annotation.kind.isStampArtwork {
                record(try stampWriteRequest(annotation, zoom: zoom, modified: modified),
                       for: annotation)
                continue
            }
            if annotation.kind.isGeometry {
                record(try geometryWriteRequest(annotation, zoom: zoom, modified: modified),
                       for: annotation)
                continue
            }

            // A text mark this reader created is a character range; a mark the PDF carried keeps
            // the file's own boxes, because its characters are in somebody else's text layer.
            let quads: [CGRect]
            if let fixed = annotation.fileQuads, !fixed.isEmpty {
                quads = fixed.map { box in
                    CGRect(x: box.x * zoom, y: box.y * zoom,
                           width: box.width * zoom, height: box.height * zoom)
                }
            } else {
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
                        domain: "LyraReader",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey:
                            "Annotation \(annotation.id.uuidString) covers characters \(annotation.start)…\(annotation.end), "
                            + "but page \(annotation.page + 1) has \(text.chars.count) characters"]
                    )
                }
                let rects = text.selectionRects(in: annotation.start...annotation.end)
                guard !rects.isEmpty else {
                    throw NSError(
                        domain: "LyraReader",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey:
                            "Annotation \(annotation.id.uuidString) covers no visible text and cannot be written"]
                    )
                }
                quads = rects.map { rect in
                    CGRect(
                        x: rect.origin.x * zoom,
                        y: rect.origin.y * zoom,
                        width: rect.width * zoom,
                        height: rect.height * zoom
                    )
                }
            }
            let union = quads.dropFirst().reduce(quads[0]) { $0.union($1) }
            let writeKind: AnnotationWriteRequest.Kind = switch annotation.kind {
            case .highlight: .highlight
            case .underline: .underline
            case .strikeout: .strikeout
            default: .highlight
            }
            record(AnnotationWriteRequest(
                id: annotation.id.uuidString,
                page: annotation.page,
                kind: writeKind,
                rect: union,
                quads: quads,
                color: annotation.color,
                opacity: Double(annotation.color.alpha) / 255.0,
                contents: annotation.note,
                author: Self.annotationAuthor,
                modified: modified
            ), for: annotation)
        }
        changes.deletions = pendingFileDeletions.map {
            AnnotationDeleteRequest(target: $0.identity, page: $0.page)
        }
        return changes
    }

    /// Everything one explicit save writes: additions, edits of annotations the PDF carries, and
    /// deletions of those annotations.
    private struct PendingAnnotationChanges {
        var additions: [AnnotationWriteRequest] = []
        var updates: [AnnotationUpdateRequest] = []
        var deletions: [AnnotationDeleteRequest] = []

        var isEmpty: Bool { additions.isEmpty && updates.isEmpty && deletions.isEmpty }
    }

    /// One placed-text annotation as a write request: a `/Text` sticky note for an icon, a
    /// `/FreeText` annotation for a box.
    ///
    /// The sidecar's box is page space at 100%; the request wants view space at the current zoom,
    /// exactly like the stroked kinds. A text box keeps its font size in page points (the zoom
    /// is a display transform, not part of the stored text) and carries its alignment.
    private func placedTextWriteRequest(
        _ annotation: Annotation,
        zoom: CGFloat,
        modified: String
    ) throws -> AnnotationWriteRequest {
        guard annotation.hasValidGeometry, let box = annotation.shapeRect else {
            throw NSError(
                domain: "LyraReader",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey:
                    "Annotation \(annotation.id.uuidString) has no box and cannot be written"]
            )
        }
        let rect = CGRect(x: box.minX * zoom, y: box.minY * zoom,
                          width: box.width * zoom, height: box.height * zoom)
        guard rect.width > 0.5, rect.height > 0.5 else {
            throw NSError(
                domain: "LyraReader",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey:
                    "Annotation \(annotation.id.uuidString) has a box too small to write"]
            )
        }
        return AnnotationWriteRequest(
            id: annotation.id.uuidString,
            page: annotation.page,
            kind: annotation.kind == .stickyNote ? .note : .freeText,
            rect: rect,
            quads: [],
            color: annotation.color,
            opacity: Double(annotation.color.alpha) / 255.0,
            contents: annotation.note,
            author: Self.annotationAuthor,
            modified: modified,
            fontSizePt: annotation.kind == .textBox ? annotation.fontSize : 0,
            textAlignment: annotation.textAlignment ?? "left"
        )
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
                domain: "LyraReader",
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
        case .highlight, .underline, .strikeout, .stickyNote, .textBox, .stamp, .signature:
            break
        }
        guard outer.width > 0.5, outer.height > 0.5 else {
            throw NSError(
                domain: "LyraReader",
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
        case .highlight: kind = .highlight
        case .underline: kind = .underline
        case .strikeout: kind = .strikeout
        case .stickyNote, .textBox, .stamp, .signature:
            throw NSError(
                domain: "LyraReader",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey:
                    "Placed text and stamp artwork are written by their own request builders"])
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
            "lyra-reader-annotate: the PDF was saved but the sidecar could not be updated; the saved entries are hidden in memory and will be reconciled on the next open\n".utf8
        ))
        return false
    }

    /// Removes exactly the bookmark entries a replacement wrote into the outline.
    ///
    /// Mirrors [`forgetAnnotationsSavedToPDF`]: the PDF now owns them, so the sidecar must not
    /// keep a second copy. Returns `false` when the sidecar write failed; the in-memory list is
    /// still trimmed, and the next open adopts the file's copy instead of showing both.
    @discardableResult
    private func forgetBookmarksSavedToPDF(ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty else { return true }
        let remaining = bookmarks.filter { !ids.contains($0.id) }
        let slots = annotationSidecarSlots.filter { slot in
            if case .bookmark(let id) = slot { return !ids.contains(id) }
            return true
        }
        undoStack.removeAll()
        redoStack.removeAll()
        if writeSidecar(
            annotations: annotations,
            bookmarks: remaining,
            slots: slots,
            trigger: "bookmarks-saved-to-pdf"
        ) {
            return true
        }
        bookmarks = remaining
        annotationSidecarSlots = slots
        FileHandle.standardError.write(Data(
            ("lyra-reader-annotate: the PDF carries the bookmarks but the sidecar could not be "
                + "updated; the saved entries are hidden in memory and the outline supplies them "
                + "on the next open\n").utf8
        ))
        return false
    }

    /// The open-time half of duplicate avoidance for bookmarks.
    ///
    /// A saved file carries its bookmarks in the outline, with the sidecar's UUID in a private
    /// key. Adopting them gives the sidebar back the reader's own list — identities, titles and
    /// page positions — without a sidecar and without showing a second copy. This runs once per
    /// open, after [`loadOutline`]; it never writes a sidecar on its own.
    private func adoptEmbeddedBookmarks(from entries: [OutlineEntry]) {
        guard let document else { return }
        var known = Set(bookmarks.map(\.id))
        var adopted: [Bookmark] = []
        for entry in entries {
            guard let text = entry.bookmarkID,
                  let id = UUID(uuidString: text),
                  !known.contains(id),
                  let page = entry.page,
                  page >= 0,
                  page < document.pageCount else { continue }
            known.insert(id)
            adopted.append(
                Bookmark(
                    id: id,
                    page: page,
                    title: entry.title,
                    yPt: CGFloat(entry.yPt ?? 0)
                )
            )
        }
        guard !adopted.isEmpty else { return }
        bookmarks.append(contentsOf: adopted)
        let line = "lyra-reader-annotate: adopted \(adopted.count) bookmark(s) from the document outline\n"
        FileHandle.standardError.write(Data(line.utf8))
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
            "lyra-reader-annotate: reconciled \(savedIDs.count) sidecar entr(ies) already present in the PDF\n".utf8
        ))
    }

    /// Reports a leftover temporary from an interrupted save, without treating it as damage to
    /// the document: the rename is the last step, so the document is still the last good copy.
    private func noticeInterruptedSave(at url: URL) {
        interruptedAnnotationSaveNotice = engine.interruptedSaveNote(at: url)
        guard let notice = interruptedAnnotationSaveNotice else { return }
        statusMessage = notice
        FileHandle.standardError.write(Data("lyra-reader-annotate: \(notice)\n".utf8))
    }

    /// The account's display name for `/T`, or "LyraReader" when it has none.
    public nonisolated static let annotationAuthor: String = {
        let name = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "LyraReader" : name
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

    /// `document.pdf` → `document.pdf.lyra-reader-annotations.json`.
    private static func sidecarURL(for document: URL) -> URL {
        DocumentEditCache.annotationsURL(for: document)
    }

    private func loadAnnotations(for url: URL) {
        let wasChanging = isChangingDocumentState
        isChangingDocumentState = true
        defer { isChangingDocumentState = wasChanging }
        annotationCacheIsDirty = false
        let sidecarURL = Self.sidecarURL(for: url)
        annotationsURL = sidecarURL
        annotationWritesBlockedReason = nil
        preservedAnnotationEntryCount = 0
        annotationSidecarSlots = []
        annotationWriteCount = 0
        hasPendingAnnotationWrite = false
        erasedInkStrokeIDs = []
        pendingFileDeletions = []
        eraserHoverMarkID = nil

        do {
            let prepared = try DocumentEditCache.prepareAnnotations(for: url,
                pageCount: document?.pageCount ?? 0, paletteCount: Self.highlightPalette.count)
            annotationsURL = prepared
            _ = try FileManager.default.attributesOfItem(atPath: sidecarURL.path)
            let data = try Data(contentsOf: sidecarURL)
            let contents = try AnnotationSidecar.decode(
                data,
                pageCount: document?.pageCount ?? 0,
                paletteCount: Self.highlightPalette.count
            )
            annotations = contents.annotations
            bookmarks = contents.bookmarks
            annotationCacheIsDirty = !annotations.isEmpty || !bookmarks.isEmpty
            annotationSidecarSlots = contents.slots
            preservedAnnotationEntryCount = contents.preservedCount
            undoStack.removeAll()
            redoStack.removeAll()
            let line = "lyra-reader-annotate: loaded \(contents.annotations.count) annotation(s),"
                + " \(contents.bookmarks.count) bookmark(s),"
                + " \(contents.preservedCount) preserved from a newer version\n"
            FileHandle.standardError.write(Data(line.utf8))
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            annotations = []
            bookmarks = []
            undoStack.removeAll()
            redoStack.removeAll()
        } catch {
            annotationsURL = DocumentEditCache.unreadableRecordsURL(for: url)
            annotations = []
            bookmarks = []
            undoStack.removeAll()
            redoStack.removeAll()
            annotationWritesBlockedReason = error.localizedDescription
            statusMessage = "Could not restore annotations; recovery data was kept"
            lastError = statusMessage
            FileHandle.standardError.write(
                Data("lyra-reader-annotate: read failed; writes blocked: \(error)\n".utf8)
            )
        }
        if annotationWritesBlockedReason == nil,
           FileManager.default.fileExists(atPath: DocumentEditCache.pendingStateURL(for: url).path) {
            do {
                let data = try Data(contentsOf: DocumentEditCache.pendingStateURL(for: url))
                let saved = try JSONDecoder().decode(PendingAnnotationState.self, from: data)
                pendingFileDeletions = saved.deletions
                erasedInkStrokeIDs = saved.erasedInk
                annotationCacheIsDirty = saved.dirty
            } catch {
                annotationWritesBlockedReason = error.localizedDescription
                lastError = "Pending PDF changes could not be restored; the cache was kept."
            }
        }
    }

    private struct PendingAnnotationState: Codable {
        let dirty: Bool
        let deletions: [FileAnnotationDeletion]
        let erasedInk: Set<UUID>
    }

    private func persistPendingAnnotationState() {
        guard !isChangingDocumentState, annotationWritesBlockedReason == nil,
              document != nil, let records = annotationsURL else { return }
        do {
            let saved = PendingAnnotationState(dirty: annotationCacheIsDirty,
                deletions: pendingFileDeletions, erasedInk: erasedInkStrokeIDs)
            try JSONEncoder().encode(saved).write(to:
                records.deletingLastPathComponent().appendingPathComponent("changes.json"), options: .atomic)
        } catch { lastError = "Could not cache pending PDF changes: \(error.localizedDescription)" }
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
                Data("lyra-reader-annotate: write blocked [\(trigger)]: \(reason)\n".utf8)
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
            if !["page-edit-session", "page-edit-revision", "saved-to-pdf", "bookmarks-saved-to-pdf", "recovery"].contains(trigger) {
                annotationCacheIsDirty = true
            }
            persistPendingAnnotationState()
            persistPageEditRecovery()
            hasPendingAnnotationWrite = false
            annotationWriteCount += 1
            let line = "lyra-reader-annotate: saved \(candidateAnnotations.count) annotation(s),"
                + " \(candidateBookmarks.count) bookmark(s)"
                + " (\(preservedAnnotationEntryCount) preserved),"
                + " write #\(annotationWriteCount) [\(trigger)]\n"
            FileHandle.standardError.write(Data(line.utf8))
            return true
        } catch {
            statusMessage = "Could not save annotations: \(error.localizedDescription)"
            lastError = statusMessage
            FileHandle.standardError.write(
                Data("lyra-reader-annotate: save failed [\(trigger)]: \(error)\n".utf8)
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
            return "The PDF's annotations could not be read (\(error)), and LyraReader's sidecar has "
                + "none, so no file was written."
        }
        return "This document has no annotations from LyraReader and none in the PDF, so no file was written."
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
                    Data("lyra-reader-annotate-export: nothing to export, no panel shown\n".utf8)
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
            if annotation.kind.isGeometry || annotation.kind.isPlacedText {
                // A stroke or a placed note has no character range; exporting the first character
                // of the page as its "quote" would invent a relationship the mark does not have.
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
                Data("lyra-reader-annotate-export: nothing to export, no file written\n".utf8)
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
                Data("lyra-reader-annotate-export: write to \(destination.path) failed: \(error)\n".utf8)
            )
            return false
        }

        let sidecarCount = export.rows.filter { $0.entry.source == .sidecar }.count
        let pdfCount = export.rows.count - sidecarCount
        statusMessage =
            "Exported \(export.rows.count) annotation(s) to \(destination.lastPathComponent)"
            + " · \(format.displayName) · \(sidecarCount) from the sidecar, \(pdfCount) from the PDF"
        FileHandle.standardError.write(Data((
            "lyra-reader-annotate-export: wrote \(export.rows.count) annotation(s) to \(destination.path)"
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

    // MARK: - Redaction (T3.12)

    /// The pending marks as canvas rectangles, for the warning overlay.
    public var pendingRedactionMarks: [CanvasRedactionMark] {
        pendingRedactions.map {
            CanvasRedactionMark(id: $0.id.uuidString, page: $0.page, rect: $0.rect)
        }
    }

    /// The pending marks as engine requests, in page-local view space at 100%.
    public var pendingRedactionAreas: [RedactionArea] {
        pendingRedactions.map { RedactionArea(page: $0.page, rect: $0.rect) }
    }

    public var pendingRedactionPageCount: Int {
        Set(pendingRedactions.map(\.page)).count
    }

    public var canMarkRedactions: Bool {
        document != nil && !redactionBusy && pageEditSession == nil
    }

    public var canApplyRedactions: Bool {
        canMarkRedactions && !pendingRedactions.isEmpty && !annotationSaveInProgress
    }

    /// Replacing the signed file with the redacted version. "Apply to Copy" stays available.
    public var canReplaceOriginalWithRedactions: Bool {
        canApplyRedactions && !isReadOnlyDocument
    }

    /// Arms the redaction tool, or leaves it when it is already armed.
    public func toggleRedactionTool() {
        guard canMarkRedactions else {
            lastError = pageEditSession != nil
                ? "Finish or discard the pending page changes before redacting."
                : "Open a document before marking redactions."
            return
        }
        if annotationTool == .redact {
            annotationTool = .select
            statusMessage = "Redaction tool off · pending marks were kept"
        } else {
            annotationTool = .redact
            statusMessage =
                "Redaction tool · drag over content to mark it; nothing is removed until you apply"
        }
    }

    /// Adds every line rectangle of the current text selection as a pending redaction.
    @discardableResult
    public func markSelectionForRedaction() -> Bool {
        guard let selection, let document else {
            lastError = "Select text before marking it for redaction."
            return false
        }
        guard selection.page >= 0, selection.page < document.pageCount else {
            lastError = "The selection is outside the document."
            return false
        }
        guard let text = textPages[selection.page] else {
            lastError = "The selected page's text is still loading; try again in a moment."
            return false
        }
        let rects = text.selectionRects(in: selection.range)
        guard !rects.isEmpty else {
            lastError = "The selection has no drawable rectangles."
            return false
        }
        for rect in rects {
            addPendingRedaction(page: selection.page, rect: rect)
        }
        statusMessage =
            "Marked \(rects.count) text line(s) for redaction · still pending, the file is unchanged"
        return true
    }

    /// Adds one pending rectangle, clipped to the page's visible box.
    public func addPendingRedaction(page: Int, rect: CGRect) {
        guard let document, page >= 0, page < document.pageCount else { return }
        var clipped = rect
        if let frame = visiblePagePlacements.first(where: { $0.index == page }) {
            let pageBox = CGRect(x: 0, y: 0, width: frame.widthPt, height: frame.heightPt)
            clipped = rect.intersection(pageBox)
        }
        guard clipped.width >= 1, clipped.height >= 1,
              clipped.minX.isFinite, clipped.minY.isFinite else { return }
        let normalized = CGRect(
            x: clipped.minX,
            y: clipped.minY,
            width: clipped.width,
            height: clipped.height
        )
        guard !pendingRedactions.contains(where: {
            $0.page == page && $0.rect.equalTo(normalized)
        }) else { return }
        pendingRedactions.append(PendingRedaction(page: page, rect: normalized))
        statusMessage = pendingRedactions.count == 1
            ? "Marked 1 area for redaction · pending, the file is unchanged"
            : "Marked \(pendingRedactions.count) areas for redaction · pending, the file is unchanged"
    }

    public func removeLastPendingRedaction() {
        guard !pendingRedactions.isEmpty else { return }
        pendingRedactions.removeLast()
        statusMessage = pendingRedactions.isEmpty
            ? "No pending redactions"
            : "Removed the last redaction mark · \(pendingRedactions.count) pending"
    }

    public func clearPendingRedactions() {
        guard !pendingRedactions.isEmpty else { return }
        pendingRedactions = []
        statusMessage = "Cleared the pending redaction marks · the file is unchanged"
    }

    /// The confirmation wording. It states what the file loses, not just that something happens.
    private func redactionConfirmation(replacing: Bool) -> (title: String, message: String) {
        let areas = pendingRedactions.count
        let pages = pendingRedactionPageCount
        let name = document?.title ?? "the document"
        let title = replacing
            ? "Replace “\(name)” with the redacted version?"
            : "Apply \(areas) redaction\(areas == 1 ? "" : "s") to a copy of “\(name)”?"
        var message =
            "\(areas) marked area\(areas == 1 ? "" : "s") on \(pages) page\(pages == 1 ? "" : "s"). "
            + "The covered text is deleted from the page content, not merely covered: it cannot be "
            + "extracted or copied from the saved file. Vector graphics and images that intersect a "
            + "mark are removed whole; a page whose content cannot be attributed is rasterised and "
            + "loses its whole text layer. Every mark is painted black."
        if replacing {
            message +=
                "\n\nThis is irreversible and changes the file on disk. A byte-identical backup is "
                + "written and verified first; if it cannot be written, nothing is replaced. The "
                + "replacement is an atomic rename of a verified temporary file."
        } else {
            message +=
                "\n\nThe original file is not touched; you will choose where to save the copy. The "
                + "copy is written atomically: a temporary file, reopened and verified, then renamed."
        }
        return (title, message)
    }

    private func redactionPreviewSummary(_ preview: RedactionPreview?) -> String {
        guard let preview else { return "" }
        var lines: [String] = []
        for page in preview.pages.prefix(8) {
            var line = "Page \(page.page + 1): \(page.characters) character\(page.characters == 1 ? "" : "s")"
            if page.graphics > 0 {
                line += " + \(page.graphics) graphic object\(page.graphics == 1 ? "" : "s")"
            }
            if !page.textPreview.isEmpty {
                line += " — “\(page.textPreview.prefix(120))”"
            }
            lines.append(line)
        }
        if preview.pages.count > 8 {
            lines.append("…and \(preview.pages.count - 8) more page(s)")
        }
        guard !lines.isEmpty else { return "" }
        return "\n\nWhat is under the marks:\n" + lines.joined(separator: "\n")
    }

    /// Presents the "apply to a copy" confirmation and, on approval, a save panel.
    public func presentApplyRedactionsPanel() {
        guard canApplyRedactions else {
            lastError = pendingRedactions.isEmpty
                ? "Mark at least one area before applying redactions."
                : "Redactions cannot be applied while another write is in progress."
            return
        }
        let areas = pendingRedactionAreas
        Task { @MainActor [weak self] in
            guard let self else { return }
            let preview = try? await self.engine.previewRedactions(areas)
            if preview == nil {
                self.lastError = "Could not read the text under the marks; nothing was changed."
                return
            }
            let confirmation = self.redactionConfirmation(replacing: false)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = confirmation.title
            alert.informativeText = confirmation.message
                + self.redactionPreviewSummary(preview)
            alert.addButton(withTitle: "Choose Copy Destination…")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            guard let source = self.document?.url else { return }
            let panel = NSSavePanel()
            panel.title = "Save Redacted Copy"
            panel.message =
                "Writes the redacted document to a new PDF and leaves the original untouched."
            panel.nameFieldStringValue =
                self.engine.suggestedRedactionCopyURL(for: source).lastPathComponent
            panel.directoryURL = source.deletingLastPathComponent()
            panel.allowedContentTypes = [.pdf]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            await self.redactCopy(to: destination, areas: areas)
        }
    }

    /// Presents the destructive confirmation for replacing the file on disk.
    public func presentReplaceRedactionsConfirmation() {
        guard guardWritable() else { return }
        guard canReplaceOriginalWithRedactions else {
            lastError = pendingRedactions.isEmpty
                ? "Mark at least one area before replacing the document."
                : "Redactions cannot be applied while another write is in progress."
            return
        }
        let areas = pendingRedactionAreas
        Task { @MainActor [weak self] in
            guard let self else { return }
            let preview = try? await self.engine.previewRedactions(areas)
            if preview == nil {
                self.lastError = "Could not read the text under the marks; nothing was changed."
                return
            }
            let confirmation = self.redactionConfirmation(replacing: true)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = confirmation.title
            alert.informativeText = confirmation.message
                + self.redactionPreviewSummary(preview)
            alert.addButton(withTitle: "Replace Original")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            await self.redactReplacingOriginal(areas: areas)
        }
    }

    @discardableResult
    private func redactCopy(to destination: URL, areas: [RedactionArea]) async -> Bool {
        guard let source = document?.url else { return false }
        guard !Self.resolvesToSameFile(destination, source) else {
            lastError = "The redacted copy cannot overwrite the document it came from."
            return false
        }
        redactionBusy = true
        defer { redactionBusy = false }
        do {
            let report = try await engine.redactToCopy(to: destination, areas: areas)
            lastRedactionReport = report
            pendingRedactions = []
            annotationTool = .select
            let pages = report.pages.count
            statusMessage =
                "Saved redacted copy \(destination.lastPathComponent) · \(report.removedCharacters) "
                + "character(s) removed on \(pages) page(s) · verified · the original is unchanged"
            FileHandle.standardError.write(Data((
                "lyra-reader-redact: copy \(destination.path) · \(report.removedCharacters) character(s) "
                + "on \(pages) page(s) · \(report.outputBytes) bytes · verified\n"
            ).utf8))
            return true
        } catch {
            lastError = "Could not write the redacted copy: \(error.localizedDescription)"
            statusMessage = "Could not write the redacted copy"
            FileHandle.standardError.write(Data("lyra-reader-redact: copy failed: \(error)\n".utf8))
            return false
        }
    }

    @discardableResult
    private func redactReplacingOriginal(areas: [RedactionArea]) async -> Bool {
        guard guardWritable() else { return false }
        guard let url = document?.url else { return false }
        redactionBusy = true
        defer { redactionBusy = false }
        do {
            let report = try await engine.replaceWithRedactions(areas)
            lastRedactionReport = report
            let backup = report.backupPath.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "none"
            pendingRedactions = []
            annotationTool = .select
            _ = open(url: url)
            statusMessage =
                "Replaced \(url.lastPathComponent) with redacted content · "
                + "\(report.removedCharacters) character(s) removed on \(report.pages.count) page(s) "
                + "· backup: \(backup)"
            FileHandle.standardError.write(Data((
                "lyra-reader-redact: replaced \(url.path) · \(report.removedCharacters) character(s) "
                + "on \(report.pages.count) page(s) · backup \(backup)\n"
            ).utf8))
            return true
        } catch {
            lastError = "Could not replace the document; it was left untouched: \(error.localizedDescription)"
            statusMessage = "Could not replace the document"
            FileHandle.standardError.write(Data("lyra-reader-redact: replace failed: \(error)\n".utf8))
            return false
        }
    }

    // MARK: - Printing (T3.12)

    /// File > Print: a print operation over a view that renders one page at print resolution
    /// when the print system asks for it.
    ///
    /// The page range and the copy count are the print panel's own, because the panel is the
    /// system's; the view supplies the page count through `knowsPageRange`. Only the pages the
    /// panel selected are rendered, one at a time, by [`ReaderPrintView`].
    public func printDocument() {
        guard let document, document.pageCount > 0 else {
            lastError = "Open a document before printing."
            return
        }
        let pageCount = document.pageCount
        let pageSize = document.firstPageSize.width > 1 && document.firstPageSize.height > 1
            ? document.firstPageSize
            : CGSize(width: 612, height: 792)
        let snapshot = annotations.map(PrintAnnotation.init)
        let markupPages = Set(snapshot.filter { $0.kind.isTextMarkup }.map(\.page))
        let engine = self.engine
        // The print system draws synchronously; the text layers a highlight needs are loaded
        // before the operation starts, so `draw` never waits for one.
        var texts = textPages
        Task { @MainActor [weak self] in
            for page in markupPages where texts[page] == nil {
                if let text = try? await engine.textPage(page) {
                    texts[page] = text
                }
            }
            guard let self else { return }
            let view = ReaderPrintView(
                pageCount: pageCount,
                pageSizePt: pageSize,
                annotations: snapshot,
                pageImage: { page, scale in
                    engine.renderPageForPrint(page, scale: scale)
                },
                textPage: { texts[$0] }
            )
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.paperSize = pageSize
            info.topMargin = 0
            info.bottomMargin = 0
            info.leftMargin = 0
            info.rightMargin = 0
            info.horizontalPagination = .fit
            info.verticalPagination = .fit
            info.orientation = pageSize.width > pageSize.height ? .landscape : .portrait
            let operation = NSPrintOperation(view: view, printInfo: info)
            operation.showsPrintPanel = true
            operation.showsProgressPanel = true
            let printed = operation.run()
            guard printed else {
                self.statusMessage = "Printing cancelled"
                return
            }
            let count = view.printedPages.count
            self.statusMessage =
                "Sent \(count) page\(count == 1 ? "" : "s") to the printer"
                + " · rendered at \(Int(ReaderPrintView.printDPI)) dpi as the printer asked"
            FileHandle.standardError.write(Data((
                "lyra-reader-print: \(count) page(s) rendered at \(Int(ReaderPrintView.printDPI)) dpi"
                + " · peak cached pages \(ReaderPrintView.maximumCachedPages)\n"
            ).utf8))
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
    private struct PageEditSnapshot: Codable {
        let revisionURL: URL
        let revisionNumber: Int
        let currentToOriginal: [Int]
        let operations: [String]
        let annotations: [Annotation]
        let bookmarks: [Bookmark]
        let slots: [AnnotationSidecar.Slot]
        let deletions: [FileAnnotationDeletion]
        let erasedInk: Set<UUID>
        let annotationDirty: Bool
        let currentPage: Int
        let selection: Set<Int>
        let label: String
    }

    private struct PageEditSession: Codable {
        let originalURL: URL
        let originalSignature: DocumentSignature
        let sourceStamp: DocumentEditCache.SourceStamp
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
        document != nil && !annotationSaveInProgress && !pageEditBusy && !contentCommandInFlight
    }

    /// Page operations that write a new file (extract, merge, split).
    public var canPageOperations: Bool { document != nil }

    public var pageEditSessionActive: Bool { pageEditSession != nil }
    public var canUndoPageEdit: Bool { pageEditSession?.undo.isEmpty == false && !pageEditBusy }
    public var canRedoPageEdit: Bool { pageEditSession?.redo.isEmpty == false && !pageEditBusy }
    public var canSavePageEditsCopy: Bool {
        (pageEditSession != nil || contentTextEditing) && !pageEditBusy && !annotationSaveInProgress
    }

    /// Applying the staged revision to the signed file itself. "Save Copy" stays available.
    public var canReplaceOriginalWithPageEdits: Bool {
        canSavePageEditsCopy && !isReadOnlyDocument
    }

    /// The entry point behind the menu commands, exposed separately so the headless checks can
    /// exercise the real session without driving AppKit menus or modal alerts.
    @discardableResult
    public func applyPageEditOperation(_ operation: PageEditOperation, label: String) async -> Bool {
        return await applyPageEdit(operation, label: label)
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.applyPageEdit(
                .rotate(pages: pages, quarterTurns: clockwise ? 1 : -1),
                label: "Rotate \(Self.pageList(pages)) \(clockwise ? "90° clockwise" : "90° anticlockwise")"
            )
        }
    }

    public func resetSelectedPageRotations() {
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
        guard pageEditSession.map({ !Self.resolvesToSameFile(destination, $0.originalURL) }) ?? true else {
            lastError = "Extracted pages cannot replace the original editing document."
            return false
        }
        let bookmarkSnapshot = bookmarks
        pageEditBusy = true
        defer { pageEditBusy = false }
        do {
            let export = try await preparedExportEngine(includeBookmarks: false)
            defer { try? FileManager.default.removeItem(at: export.directory) }
            let temporary = export.directory.appendingPathComponent("extracted.pdf")
            let report = try await export.engine.extractPages(pages, to: temporary)
            try await publishExport(temporary, to: destination, pages: pages.sorted(), bookmarks: bookmarkSnapshot)
            statusMessage =
                "Extracted \(Self.pageList(pages)) to \(destination.lastPathComponent)"
                + " · \(report.pageCount) page(s) written"
            FileHandle.standardError.write(Data((
                "lyra-reader-pages: extracted \(pages.count) page(s) to \(destination.path)"
                + " (\(report.outputBytes) bytes)\n"
            ).utf8))
            return true
        } catch {
            lastError = "Could not extract the pages: \(error.localizedDescription)"
            statusMessage = "Could not extract the pages"
            return false
        }
    }

    // MARK: - Merge and split (T3.9)
    //
    // Merge and split are **immediate-to-a-new-file**, exactly like Extract: they work on the
    // file that is open now (the working revision during a page-edit session), never end the
    // session and are not undoable. The source is only read. The outputs are files the reader
    // asked for by name, each written through the engine's verified temporary-file path.
    //
    // Sidecar rules: a merge appends, so existing pages keep their indices and the reader's
    // marks are copied unchanged to the merged file's sidecar. The appended pages start with no
    // LyraReader marks because this app has no sidecar for the other documents (their file-owned
    // annotations travel inside the PDF). A split renumbers pages per output, so each output's
    // sidecar holds exactly the marks whose pages that output contains, at their new indices.

    public func presentMergeDocumentsPanel() {
        guard let source = pageEditDisplayURL else { return }
        let open = NSOpenPanel()
        open.title = "Append PDFs"
        open.message =
            "Choose one or more PDFs whose pages will be appended to “"
            + source.lastPathComponent + "” in the order they are selected. "
            + "The open document and the chosen PDFs are not modified. "
            + "Encrypted PDFs and the open document itself are refused."
        open.allowedContentTypes = [.pdf]
        open.allowsMultipleSelection = true
        open.canChooseDirectories = false
        open.directoryURL = source.deletingLastPathComponent()
        guard open.runModal() == .OK else { return }
        let others = open.urls
        guard !others.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = "Merge PDFs"
        panel.message =
            "Writes the current document followed by the chosen PDFs' pages to a new file. "
            + "The first document's outline is kept; the appended documents' outlines are not "
            + "imported. Annotations stored inside the PDFs travel with their pages. Your "
            + "LyraReader marks keep their pages; appended pages carry none."
        panel.nameFieldStringValue =
            "\(source.deletingPathExtension().lastPathComponent) (merged).pdf"
        panel.directoryURL = source.deletingLastPathComponent()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { @MainActor [weak self] in
            await self?.mergeDocuments(others, to: destination)
        }
    }

    /// Appends `others` to the open document and writes a new file at `destination`.
    ///
    /// The open document (and any staged page-edit session) is left exactly as it is: this is
    /// the same immediate-to-a-new-file shape as ``extractPages(_:to:)``. The destination's
    /// sidecar receives the current marks unchanged, because appending does not move a page.
    @discardableResult
    public func mergeDocuments(_ others: [URL], to destination: URL) async -> Bool {
        guard let source = document?.url else { return false }
        guard !others.isEmpty else {
            lastError = "Choose at least one PDF to append."
            return false
        }
        guard !pageEditBusy && !annotationSaveInProgress else { return false }
        if let reason = annotationWritesBlockedReason {
            lastError =
                "This document's annotation cache could not be read (\(reason)), so the merge "
                + "was not started: it could not tell which marks the merged file should carry."
            return false
        }
        if Self.resolvesToSameFile(destination, source)
            || others.contains(where: { Self.resolvesToSameFile($0, source) }) {
            lastError = "A document cannot be merged into itself; choose another file."
            return false
        }
        if let original = pageEditSession?.originalURL,
           Self.resolvesToSameFile(destination, original) {
            lastError =
                "The merged file cannot replace the document the page-edit session started from. "
                + "Choose another name; the original is unchanged until Replace Original is used."
            return false
        }
        guard !Self.sidecarFileExists(for: destination) else {
            lastError = "The destination has unsaved recovery data. Open it before replacing it."
            return false
        }
        pageEditBusy = true
        defer { pageEditBusy = false }
        do {
            let export = try await preparedExportEngine(includeBookmarks: true)
            defer { try? FileManager.default.removeItem(at: export.directory) }
            let report = try await export.engine.mergeDocuments(others: others, to: destination)
            let appendedNotes = report.appendedAnnotationCounts.reduce(0, +)
            let outlineNote = report.droppedOutlineEntries == 0
                ? "kept the first document's outline (\(report.firstOutlineEntries) entries); "
                    + "the appended documents had no outline"
                : "kept the first document's outline (\(report.firstOutlineEntries) entries) and "
                    + "did not import \(report.droppedOutlineEntries) outline "
                    + "entr\(report.droppedOutlineEntries == 1 ? "y" : "ies") from the appended documents"
            let marksNote: String
            if annotations.isEmpty && bookmarks.isEmpty {
                marksNote = "there were no LyraReader marks to carry"
            } else {
                marksNote =
                    "your \(annotations.count) annotation(s) and \(bookmarks.count) bookmark(s) "
                    + "stay on pages 1–\(report.firstPageCount); the \(report.pageCount - report.firstPageCount) "
                    + "appended page(s) start without LyraReader marks"
            }
            statusMessage =
                "Merged into \(destination.lastPathComponent) · \(report.pageCount) pages · "
                + "\(outlineNote) · \(appendedNotes) embedded annotation(s) traveled · "
                + "\(marksNote) · the open document is unchanged"
            FileHandle.standardError.write(Data((
                "lyra-reader-pages: merged \(others.count) document(s) into \(destination.path) "
                + "· \(report.pageCount) page(s), first \(report.firstPageCount) · "
                + "dropped \(report.droppedOutlineEntries) outline entries · "
                + "\(report.outputBytes) bytes\n"
            ).utf8))
            return true
        } catch {
            lastError = "Could not merge the documents; nothing was written: \(error.localizedDescription)"
            statusMessage = "Could not merge the documents"
            FileHandle.standardError.write(Data("lyra-reader-pages: merge failed: \(error)\n".utf8))
            return false
        }
    }

    public func presentSplitPagesPanel() {
        guard let source = pageEditDisplayURL, let pageCount = document?.pageCount, pageCount > 0 else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "Split “\(source.lastPathComponent)”"
        alert.informativeText =
            "Each part is written as its own verified file; the source is not modified. "
            + "Choose page ranges (for example 1-5, 6-10) or a fixed page count. "
            + "The reader's marks are copied to the output that contains their page."

        let mode = NSPopUpButton(frame: NSRect(x: 0, y: 72, width: 320, height: 26), pullsDown: false)
        mode.addItems(withTitles: ["Page ranges", "Every N pages"])
        let field = NSTextField(frame: NSRect(x: 0, y: 40, width: 320, height: 26))
        field.stringValue = pageCount > 5 ? "1-5" : "1-\(pageCount)"
        field.placeholderString = "1-5, 6-10"
        let hint = NSTextField(labelWithString:
            "Ranges are 1-based and must not overlap. Every N pages: type just the number, "
            + "for example 5.")
        hint.frame = NSRect(x: 0, y: 0, width: 320, height: 32)
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
        accessory.addSubview(mode)
        accessory.addSubview(field)
        accessory.addSubview(hint)
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Choose Folder…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let ranges: [[Int]]
        do {
            if mode.indexOfSelectedItem == 0 {
                ranges = try PageSplitPlan.ranges(field.stringValue, pageCount: pageCount)
            } else {
                guard let every = Int(field.stringValue.trimmingCharacters(in: .whitespaces)),
                      every >= 1 else {
                    throw PageSplitPlanError.invalid("Type a whole number of pages, for example 5.")
                }
                ranges = try PageSplitPlan.chunks(pageCount: pageCount, every: every)
            }
        } catch {
            lastError = "Could not use that split: \(error.localizedDescription)"
            statusMessage = "Split not started"
            return
        }

        let folderPanel = NSOpenPanel()
        folderPanel.title = "Choose a Folder for the Split"
        folderPanel.message =
            "\(ranges.count) file(s) will be written here, named like "
            + "“\(source.deletingPathExtension().lastPathComponent) (pages 1-5).pdf”. "
            + "Nothing is overwritten: an existing file or recovery data stops the split before it starts."
        folderPanel.prompt = "Choose Folder"
        folderPanel.canChooseFiles = false
        folderPanel.canChooseDirectories = true
        folderPanel.canCreateDirectories = true
        folderPanel.allowsMultipleSelection = false
        folderPanel.directoryURL = source.deletingLastPathComponent()
        guard folderPanel.runModal() == .OK, let folder = folderPanel.url else { return }
        let base = folder.appendingPathComponent(source.lastPathComponent)
        let destinations = PageSplitPlan.outputURLs(base: base, ranges: ranges)
        Task { @MainActor [weak self] in
            await self?.splitPages(ranges, to: destinations)
        }
    }

    /// Splits the open document into `ranges` written at `destinations` (same order).
    ///
    /// Like ``extractPages(_:to:)`` this is immediate: it does not start or end a page-edit
    /// session. Every output is verified by the engine. If a later output fails, earlier outputs
    /// are complete and stay in place; each one that exists gets its remapped sidecar, so a
    /// partial split still leaves usable files with the right marks.
    @discardableResult
    public func splitPages(_ ranges: [[Int]], to destinations: [URL]) async -> Bool {
        guard let source = document?.url else { return false }
        guard !ranges.isEmpty, ranges.count == destinations.count else {
            lastError = "A split needs one destination for every page range."
            return false
        }
        guard !pageEditBusy && !annotationSaveInProgress else { return false }
        if let reason = annotationWritesBlockedReason {
            lastError =
                "This document's annotation cache could not be read (\(reason)), so the split "
                + "was not started: it could not tell which marks each output should carry."
            return false
        }
        guard preservedAnnotationEntryCount == 0 else {
            lastError =
                "This document's annotation cache contains entries written by a newer LyraReader. "
                + "Their pages cannot be remapped into the split outputs safely, so the split was "
                + "not started."
            return false
        }
        for (range, destination) in zip(ranges, destinations) {
            guard !range.isEmpty else {
                lastError = "A split range is empty; nothing was written."
                return false
            }
            if Self.resolvesToSameFile(destination, source)
                || pageEditSession.map({ Self.resolvesToSameFile(destination, $0.originalURL) }) == true {
                lastError = "A split output cannot overwrite the document being split."
                return false
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                lastError =
                    "“\(destination.lastPathComponent)” already exists. Nothing was written; choose "
                    + "another folder or remove the file."
                return false
            }
            if Self.sidecarFileExists(for: destination) {
                lastError =
                    "“\(destination.lastPathComponent)” already has LyraReader annotations beside it. "
                    + "Nothing was written; choose another folder."
                return false
            }
        }

        let ordered = ranges.map { $0.sorted() }
        let bookmarkSnapshot = bookmarks
        pageEditBusy = true
        defer { pageEditBusy = false }
        do {
            let export = try await preparedExportEngine(includeBookmarks: false)
            defer { try? FileManager.default.removeItem(at: export.directory) }
            let temporary = ordered.indices.map { export.directory.appendingPathComponent("part-\($0).pdf") }
            let parts = zip(ordered, temporary).map { PageSplitPart(pages: $0.0, destination: $0.1) }
            _ = try await export.engine.splitPages(parts)
            for index in ordered.indices {
                try await publishExport(temporary[index], to: destinations[index], pages: ordered[index], bookmarks: bookmarkSnapshot)
            }
            statusMessage = "Split into \(destinations.count) verified PDFs · annotations and bookmarks are embedded · source unchanged"
            return true
        } catch {
            let completed = destinations.filter { FileManager.default.fileExists(atPath: $0.path) }.count
            lastError = "Could not finish the split; \(completed) complete output(s) are on disk: \(error.localizedDescription)"
            statusMessage = completed == 0 ? "Split failed; nothing was written" : "Split stopped after \(completed) complete output(s)"
            return false
        }
    }

    /// A separate engine exports a snapshot so the reader's active revision and undo stay intact.
    private func preparedExportEngine(includeBookmarks: Bool) async throws -> (engine: any PDFEngine, directory: URL) {
        guard let source = document?.url, annotationWritesBlockedReason == nil,
              preservedAnnotationEntryCount == 0 else {
            throw NSError(domain: "LyraReader", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The annotation recovery data must be restored before exporting."])
        }
        flushPendingWrites()
        guard !hasPendingAnnotationWrite else {
            throw NSError(domain: "LyraReader", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The active annotation could not be cached."])
        }
        let changes = try await pendingAnnotationChanges()
        let marks = includeBookmarks ? bookmarkWriteRequests() : []
        guard document?.url == source else {
            throw NSError(domain: "LyraReader", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The active document changed before exporting."])
        }
        let directory = try DocumentEditCache.newSessionDirectory(for: pageEditDisplayURL ?? source)
        guard !changes.isEmpty || !marks.isEmpty else { return (engine, directory) }
        do {
            let snapshot = directory.appendingPathComponent("source.pdf")
            _ = try await engine.saveAnnotationChanges(to: snapshot, additions: changes.additions,
                bookmarks: marks, updates: changes.updates, deletions: changes.deletions, zoom: zoomFactor)
            let isolated = try RustEngine()
            _ = try isolated.openDocument(at: snapshot)
            return (isolated, directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func publishExport(_ source: URL, to destination: URL, pages: [Int], bookmarks snapshot: [Bookmark]) async throws {
        let export = try RustEngine()
        _ = try export.openDocument(at: source)
        let positions = Dictionary(uniqueKeysWithValues: pages.enumerated().map { ($0.element, $0.offset) })
        let marks = snapshot.compactMap { bookmark -> BookmarkWriteRequest? in
            guard let page = positions[bookmark.page] else { return nil }
            return BookmarkWriteRequest(id: bookmark.id, page: page, title: bookmark.title, yPt: bookmark.yPt)
        }
        if marks.isEmpty { _ = try await export.saveEditedCopy(to: destination) }
        else { _ = try await export.saveAnnotationChanges(to: destination, additions: [], bookmarks: marks,
            updates: [], deletions: [], zoom: zoomFactor) }
    }

    /// True when either naming convention of the reader's sidecar exists beside `document`.
    private static func sidecarFileExists(for document: URL) -> Bool {
        let fileManager = FileManager.default
        return ([Self.sidecarURL(for: document)] + DocumentEditCache.legacyURLs(for: document))
            .contains { fileManager.fileExists(atPath: $0.path) }
    }

    public func presentSavePageEditsCopyPanel() {
        guard let source = pageEditDisplayURL, pageEditSession != nil || contentTextEditing else { return }
        let panel = NSSavePanel()
        panel.title = "Save Edited Copy"
        panel.message =
            "Writes the edited pages, annotations and bookmarks into a new PDF."
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
        guard contentTextRecovery == nil else { lastError = "Finish or discard the recovered draft before saving."; return false }
        commitContentText?()
        if let task = contentEditTask {
            let succeeded = await task.value
            contentEditTask = nil
            if !succeeded { return false }
        }
        guard let original = pageEditSession?.originalURL, !pageEditBusy else { return false }
        guard !Self.resolvesToSameFile(destination, original) else {
            lastError = "Choose another name for Save As, or use Save to update the original."
            return false
        }
        guard !Self.sidecarFileExists(for: destination) else {
            lastError = "The destination has unsaved recovery data. Open it before replacing it."
            return false
        }
        do {
            _ = try await materializeAnnotationsInWorkingCopy()
            pageEditBusy = true
            defer { pageEditBusy = false }
            let report = try await engine.saveEditedCopy(to: destination)
            // The output already contains every annotation; it needs no companion records.
            endPageEditSession(deleteFiles: true)
            _ = open(url: destination)
            pageEditIsApplied = true
            statusMessage = "Saved \(destination.lastPathComponent) · \(report.pageCount) page(s)"
            return true
        } catch {
            lastError = "Could not save the PDF copy: \(error.localizedDescription)"
            return false
        }
    }

    public func presentReplaceOriginalWithPageEditsConfirmation() {
        if contentTextEditing {
            commitContentText?()
            Task { @MainActor [weak self] in
                guard let self, let task=contentEditTask, await task.value else{return}
                contentEditTask=nil
                presentReplaceOriginalWithPageEditsConfirmation()
            }
            return
        }
        guard guardWritable() else { return }
        guard canReplaceOriginalWithPageEdits, let session = pageEditSession else { return }
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
        guard guardWritable(), contentTextRecovery == nil else { return false }
        commitContentText?()
        if let task = contentEditTask {
            let succeeded = await task.value
            contentEditTask = nil
            if !succeeded { return false }
        }
        guard let original = pageEditSession?.originalURL, !pageEditBusy else { return false }
        do {
            try DocumentEditCache.validateSource(for: original)
            _ = try await materializeAnnotationsInWorkingCopy()
            pageEditBusy = true
            defer { pageEditBusy = false }
            let report = try await engine.replaceOriginalWithPageEdits(original: original)
            // Retire cached marks only after the verified PDF transaction succeeds.
            var cleanupError: String?
            do {
                try Data("[]".utf8).write(to: DocumentEditCache.annotationsURL(for: original), options: .atomic)
                try JSONEncoder().encode(PendingAnnotationState(dirty: false, deletions: [], erasedInk: [])).write(
                    to: DocumentEditCache.pendingStateURL(for: original), options: .atomic)
                try DocumentEditCache.recordSource(for: original)
            } catch { cleanupError = error.localizedDescription }
            endPageEditSession(deleteFiles: cleanupError == nil)
            _ = open(url: original)
            pageEditIsApplied = true
            statusMessage = "Saved \(original.lastPathComponent) · backup: \(report.backupPath?.lastPathComponent ?? "none")"
            if let cleanupError { lastError = "The PDF was saved, but its old recovery data was kept: \(cleanupError)" }
            return true
        } catch {
            lastError = "Could not save the original; the editing cache was kept: \(error.localizedDescription)"
            persistPageEditRecovery()
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
        if deferContentTransition({[weak self] in self?.undoPageEdit()}) {return}
        Task { @MainActor [weak self] in
            await self?.undoOrRedoPageEdit(redo: false)
        }
    }

    public func redoPageEdit() {
        if deferContentTransition({[weak self] in self?.redoPageEdit()}) {return}
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
        pendingFileDeletions = target.deletions
        erasedInkStrokeIDs = target.erasedInk
        annotationCacheIsDirty = target.annotationDirty
        persistPendingAnnotationState()
        persistPageEditRecovery()
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
            deletions: pendingFileDeletions,
            erasedInk: erasedInkStrokeIDs,
            annotationDirty: annotationCacheIsDirty,
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
        if let owner = Self.pageEditOwners[DocumentEditCache.recoveryURL(for: url).path]?.value,
           owner !== self {
            lastError = "This PDF is being edited in another window. Save or close that editing session first."
            return false
        }
        guard preservedAnnotationEntryCount == 0 else {
            lastError =
                "This document's annotation cache contains entries written by a newer LyraReader. "
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
            let directory = try DocumentEditCache.newSessionDirectory(for: url)
            let originalRotations = try await engine.pageRotations()
            let pageCount = document?.pageCount ?? 0
            let session = PageEditSession(
                originalURL: url,
                originalSignature: documentSignature,
                sourceStamp: try DocumentEditCache.SourceStamp(url),
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
        // page that has LyraReader marks would silently move them onto different words. Embedded PDF
        // annotations are unaffected: they are page-space geometry and rotate with the page.
        let rotating: [Int]?
        switch operation {
        case .rotate(let pages, _), .setRotation(let pages, _): rotating = pages
        default: rotating = nil
        }
        guard await ensurePageEditSession() else { return false }
        guard var session = pageEditSession, !pageEditBusy else { return false }
        guard let snapshot = pageEditSnapshot(label: label) else { return false }
        let nextNumber = session.revisionNumber + 1
        let nextURL = session.directory.appendingPathComponent("rev-\(nextNumber).pdf")
        pageEditBusy = true
        defer { pageEditBusy = false }
        do {
            if let rotating, rotationConflict(on: rotating) != nil {
                if try await materializeAnnotationsInWorkingCopy(), let updated = pageEditSession {
                    session = updated
                }
            }
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
                "lyra-reader-pages: \(label) · revision \(nextNumber) · "
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
                domain: "LyraReader",
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
        if let originalURL {
            let key = DocumentEditCache.recoveryURL(for: originalURL).path
            if Self.pageEditOwners[key]?.value === self { Self.pageEditOwners.removeValue(forKey: key) }
        }
        pageEditSession = nil
        pageEditPendingOperations = []
        pageEditIsApplied = false
        if let revisionURL, revisionURL != originalURL {
            engine.closeDocument(at: revisionURL)
        }
        if deleteFiles, let directory {
            if let originalURL { try? FileManager.default.removeItem(at: DocumentEditCache.recoveryURL(for: originalURL)) }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private struct PageEditRecovery: Codable {
        let version: Int
        let session: PageEditSession
        let snapshot: PageEditSnapshot
    }

    private func persistPageEditRecovery() {
        guard let session = pageEditSession,
              let snapshot = pageEditSnapshot(label: "Recovered editing session") else { return }
        do {
            let recovery = PageEditRecovery(version: 1, session: session, snapshot: snapshot)
            try JSONEncoder().encode(recovery).write(to: DocumentEditCache.recoveryURL(for: session.originalURL), options: .atomic)
        } catch {
            lastError = "Could not cache the editing session: \(error.localizedDescription)"
        }
    }

    /// Freeze text-range marks into PDF geometry before changing the text layer. This is an
    /// internal cached revision; the original PDF is only touched by the explicit Save command.
    @discardableResult
    private func materializeAnnotationsInWorkingCopy() async throws -> Bool {
        guard !annotations.isEmpty || !bookmarks.isEmpty || hasPendingFileDeletions else { return false }
        guard await ensurePageEditSession(), var session = pageEditSession else {
            throw NSError(domain: "LyraReader", code: 1,
                userInfo: [NSLocalizedDescriptionKey: lastError ?? "Could not prepare the PDF cache"])
        }
        flushPendingWrites()
        guard !hasPendingAnnotationWrite else {
            throw NSError(domain: "LyraReader", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not cache the active annotation"])
        }
        let changes = try await pendingAnnotationChanges()
        let marks = bookmarkWriteRequests()
        guard !changes.isEmpty || !marks.isEmpty else { return false }
        let next = session.directory.appendingPathComponent("marks-\(UUID().uuidString).pdf")
        _ = try await engine.saveAnnotationChanges(to: next, additions: changes.additions,
            bookmarks: marks, updates: changes.updates, deletions: changes.deletions, zoom: zoomFactor)
        let oldScroll = scrollYPt
        try loadPageEditRevision(at: next, title: session.title, sidecarURL: session.sidecarURL,
            annotations: [], bookmarks: [], slots: [], currentPage: currentPage, selection: pageSelection)
        session.revisionURL = next
        pendingFileDeletions = []
        erasedInkStrokeIDs = []
        pageEditSession = session
        scrollYPt = clampedScrollOffset(oldScroll)
        reloadVisiblePages()
        return true
    }

    private func restoreCachedPageEdits(for original: URL) {
        guard pageEditSession == nil else { return }
        let recoveryURL = DocumentEditCache.recoveryURL(for: original)
        if let owner = Self.pageEditOwners[recoveryURL.path]?.value, owner !== self { return }
        guard FileManager.default.fileExists(atPath: recoveryURL.path) else { return }
        do {
            let saved = try JSONDecoder().decode(PageEditRecovery.self, from: Data(contentsOf: recoveryURL))
            let session = saved.session
            let directory = DocumentEditCache.directory(for: original).standardizedFileURL.path + "/"
            guard saved.version == 1, Self.resolvesToSameFile(session.originalURL, original),
                  session.sourceStamp == (try DocumentEditCache.SourceStamp(original)),
                  session.directory.standardizedFileURL.path.hasPrefix(directory),
                  session.sidecarURL.standardizedFileURL.path.hasPrefix(session.directory.path + "/") else {
                throw DocumentEditCache.CacheError.sourceChanged
            }
            func validRevision(_ url: URL) -> Bool {
                url.standardizedFileURL == original.standardizedFileURL ||
                    url.standardizedFileURL.path.hasPrefix(session.directory.standardizedFileURL.path + "/")
            }
            guard validRevision(saved.snapshot.revisionURL),
                  (session.undo + session.redo).allSatisfy({ validRevision($0.revisionURL) }) else {
                throw DocumentEditCache.CacheError.sourceChanged
            }
            try loadPageEditRevision(at: saved.snapshot.revisionURL, title: session.title,
                sidecarURL: session.sidecarURL, annotations: saved.snapshot.annotations,
                bookmarks: saved.snapshot.bookmarks, slots: saved.snapshot.slots,
                currentPage: saved.snapshot.currentPage, selection: saved.snapshot.selection)
            pendingFileDeletions = saved.snapshot.deletions
            erasedInkStrokeIDs = saved.snapshot.erasedInk
            annotationCacheIsDirty = saved.snapshot.annotationDirty
            pageEditSession = session
            pageEditPendingOperations = session.operations
            statusMessage = "Recovered unsaved PDF changes · Save to update \(original.lastPathComponent)"
        } catch {
            lastError = "The cached editing session was kept but could not be restored: \(error.localizedDescription)"
        }
    }

    /// Why rotating `pages` would invalidate LyraReader's own marks, or nil when it is safe.
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
        return "Page \(Self.pageList(marked)) has LyraReader annotations or bookmarks stored as "
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
        guard let original = pageEditSession?.originalURL ?? document?.url else { return nil }

        let fileManager = FileManager.default
        var backupURL: URL?
        let records = [sidecarURL, DocumentEditCache.pendingStateURL(for: original),
                       DocumentEditCache.recoveryURL(for: original),
                       DocumentEditCache.directory(for: original).appendingPathComponent("source.json")]
            + DocumentEditCache.legacyURLs(for: original)
        var copied: [(URL, URL)] = []
        var seen: Set<String> = []
        do {
            for source in records where seen.insert(source.path).inserted
                && fileManager.fileExists(atPath: source.path) {
                let destination = DocumentEditCache.directory(for: original)
                    .appendingPathComponent("unreadable-\(UUID().uuidString)-\(source.lastPathComponent)")
                let bytes = try Data(contentsOf: source)
                try bytes.write(to: destination, options: .atomic)
                guard try Data(contentsOf: destination) == bytes else {
                    throw DocumentEditCache.CacheError.importVerification
                }
                copied.append((source, destination))
            }
            // Verify every recovery record before retiring any. Cached PDF revisions remain
            // available alongside the backed-up manifest for manual recovery.
            for (source, _) in copied { try fileManager.removeItem(at: source) }
            backupURL = copied.first?.1
        } catch {
            let message = "Could not back up the unreadable recovery data: \(error.localizedDescription)"
            statusMessage = message
            lastError = message
            return nil
        }

        // The path is free now, so a stale blocked flag must not stop the fresh write.
        annotationWritesBlockedReason = nil
        annotationsURL = DocumentEditCache.annotationsURL(for: original)
        do { try DocumentEditCache.recordSource(for: original) }
        catch { annotationWritesBlockedReason = error.localizedDescription; lastError = error.localizedDescription; return nil }
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
            annotationWritesBlockedReason = lastError ?? "the annotation cache could not be recreated"
            return nil
        }

        statusMessage = backupURL.map {
            "Backed up the unreadable annotations to \($0.lastPathComponent) and started a fresh annotation cache"
        } ?? "Started a fresh annotation cache"
        return backupURL
    }

    /// `<doc>.pdf.lyra-reader-annotations.json` → `<doc>.pdf.lyra-reader-annotations.corrupt-<stamp>.json`,
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
    ///
    /// A click that stayed on a text mark or an unselected text box selects that mark here,
    /// before the ordinary click path can clear it. This is the other half of the deferred
    /// decision `beginSelection` starts: the press only remembered a candidate.
    public func endPointerInteraction(at point: CGPoint, wasClick: Bool) {
        // A click on the page (outside the editor) ends an open editing session. A press that
        // begins a drag has already committed in `beginSelection`; this covers the plain click
        // that never passes the drag slop.
        if editingAnnotationID != nil { commitTextEditing() }
        markSelectionRefusalNotice = nil
        if let original = resizeOriginalAnnotation, let handle = resizeHandle,
           let start = resizeStartPagePoint {
            finishAnnotationResize(original: original, handle: handle, start: start,
                                   at: point, wasClick: wasClick)
            return
        }
        if let original = moveOriginalAnnotation, let start = moveStartPagePoint {
            finishAnnotationMove(original: original, start: start, at: point, wasClick: wasClick)
            return
        }
        if wasClick, let pending = pendingMarkSelection {
            pendingMarkSelection = nil
            finishPendingMarkSelection(pending)
            return
        }
        pendingMarkSelection = nil
        guard wasClick else {
            extendSelection(to: point)
            // A drag is a finished text selection. When a sticky markup tool is active, the
            // selection becomes its mark here, without a second click; when none is active this
            // is the no-op it has always been.
            _ = markSelectionWithActiveTool()
            return
        }
        // Before the target is resolved, not after: a click that opens a citation or a figure
        // preview used to leave the old selection highlighted behind the panel, which reads as
        // "the click did not take". A click elsewhere also drops a selected mark; a click *on*
        // a mark returned above, before this point, so it keeps its selection.
        clearSelection()
        clearAnnotationSelection()
        closeDocumentNote()
        previewLookupEpoch &+= 1
        previewEpoch &+= 1

        // A visible inline-comment label wins over text underneath it. Elsewhere, preserve
        // navigation priority: the PDF's link, a citation, a caption mention, then a note glyph.
        let resolved = openInlineNote(at: point)
            || followLink(at: point)
            || openCitation(at: point)
            || openFigureMention(at: point)
            || openDocumentNote(at: point)
        // Nothing above claimed the click, and it landed on markup the file itself carries.
        // Adopt it into the editable model and select it; a kind with no editable model states
        // its one reason instead. Only the Select tool owns mark selection; the armed markup
        // tools keep their old click behaviour.
        if annotationTool == .select, !resolved,
           let document = fileOwnedMarkupHit(atContentPoint: point) {
            _ = selectDocumentAnnotation(document.id)
        }
    }

    /// Selects the mark whose press was waiting for the click-versus-drag decision.
    private func finishPendingMarkSelection(_ pending: PendingMarkSelection) {
        guard let annotation = annotations.first(where: { $0.id == pending.id }) else {
            selection = nil
            selectionAnchor = nil
            clearAnnotationSelection()
            return
        }
        selection = nil
        selectionAnchor = nil
        selectedAnnotationID = annotation.id
        refreshSelectionOverlay()
        let noun = annotation.kind == .textBox ? "text box" : annotation.kind.rawValue
        statusMessage = "Selected a \(noun) · Delete removes it"
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
            if wasClick {
                selectedAnnotationID = original.id
                if original.kind == .stickyNote {
                    beginEditingAnnotation(original.id)
                }
            }
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
        for marker in ownInlineNoteMarkers.reversed() {
            guard let placement = visiblePagePlacements.first(where: { $0.index == marker.page }) else { continue }
            let local = CGPoint(x: point.x - placement.leftPt, y: point.y - placement.topPt)
            guard marker.rect.contains(local), annotations.indices.contains(marker.annotationIndex) else { continue }
            beginEditingAnnotation(annotations[marker.annotationIndex].id)
            return true
        }
        for marker in inlineNoteMarkers.reversed() {
            guard let placement = visiblePagePlacements.first(where: { $0.index == marker.page }) else { continue }
            let local = CGPoint(x: point.x - placement.leftPt, y: point.y - placement.topPt)
            guard marker.rect.contains(local) else { continue }
            let annotation = documentAnnotations[marker.annotationIndex]
            showDocumentNote(annotation)
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

                // A single click opens the file's own note paper, exactly as before: reading
                // somebody's note must not silently rewrite it. A double-click (see
                // `beginEditingTextBox`) or the sidebar adopts it for editing.
                showDocumentNote(annotation)
                FileHandle.standardError.write(
                    Data("lyra-reader-annot: opened note \(annotation.id) (\(annotation.drawing.rawValue)) on page \(annotation.page + 1)\n".utf8)
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
    public static let noteClickSlackPt: CGFloat = 3

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
                Data("lyra-reader-figures: \(self.figures.count) caption(s)\n".utf8)
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
                // An adopted entry is drawn from the editable model, and a pending deletion is
                // drawn nowhere: hiding both here is what keeps a mark from appearing twice (or
                // after the reader deleted it) until the save makes the change real.
                let hidden = self.adoptedFileAnnotationIDs
                    .union(self.pendingFileDeletions.map(\.identity))
                var popupFlags: [String: Bool] = [:]
                for annotation in found {
                    popupFlags[annotation.id] = annotation.hasPopup
                }
                self.documentPopupFlags = popupFlags
                self.documentAnnotations = found.filter { !hidden.contains($0.id) }
                self.reconcileAnnotationsAlreadySaved(found)
                self.reloadVisiblePages()
                FileHandle.standardError.write(
                    Data("lyra-reader-pdf-annotations: \(found.count) in the file, \(self.documentNotes.count) note(s)\n".utf8)
                )
            } catch {
                guard epoch == self.documentEpoch else { return }
                self.documentAnnotationsError = String(describing: error)
                self.statusMessage = "Could not read the annotations in this PDF"
                FileHandle.standardError.write(
                    Data("lyra-reader-pdf-annotations: read failed: \(error)\n".utf8)
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
                Data("lyra-reader-references: \(self.references.count) entries\n".utf8)
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
                    "lyra-reader-metadata: title=\(found.title.source.label.lowercased()) "
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
                    Data("lyra-reader-metadata: read failed: \(error)\n".utf8)
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
        let request = previewLookupEpoch
        // Read the anchor before the await: resolution can take a moment, and the reader
        // may have scrolled by the time it lands, but the panel belongs where they clicked.
        let anchor = viewRect(
            local: CGRect(x: citation.xPt, y: citation.yPt,
                          width: citation.widthPt, height: citation.heightPt),
            on: placement
        )
        Task { @MainActor [weak self] in
            guard let self, epoch == self.documentEpoch, request == self.previewLookupEpoch else { return }
            let resolved = (try? await self.engine.resolveCitations(
                labels: labels,
                page: placement.index
            )) ?? []
            guard epoch == self.documentEpoch, request == self.previewLookupEpoch else { return }
            guard let first = resolved.first else {
                self.statusMessage = "Citation \"\(written)\" has no matching entry"
                return
            }

            let opened = self.openReferencePreview(
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
            // A pinned panel keeps its own content and has already said so; the citation must not
            // overwrite that message with a preview that did not happen.
            guard opened else { return }
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
        let request = previewLookupEpoch
        Task { @MainActor [weak self] in
            guard let self else { return }
            let citations: [Citation]
            if let cached = self.citationsByPage[page] {
                citations = cached
            } else {
                citations = await self.startCitationLoad(page: page).value ?? []
            }
            guard epoch == self.documentEpoch, request == self.previewLookupEpoch else { return }
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
            if figures.isEmpty {
                resolveFigureMention(on: placement.index, at: local)
                return false
            }
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
                format: "lyra-reader-figure: \"%@\" -> page %d region (%.1f, %.1f, %.1f, %.1f)\n",
                title,
                figure.page + 1,
                figure.xPt,
                figure.yPt,
                figure.widthPt,
                figure.heightPt
            ).utf8)
        )

        guard openReferencePreview(
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
        ) else { return false }
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
        let request = previewLookupEpoch
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
            guard epoch == self.documentEpoch, request == self.previewLookupEpoch else { return }
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
            // Reserve this click before starting asynchronous resolution. A temporary page
            // preview must not cancel its own lookup; panel resizing has a separate raster epoch.
            previewLookupEpoch &+= 1
            previewEpoch &+= 1
            let local = CGPoint(x: point.x - placement.leftPt, y: point.y - placement.topPt)
            if let citations = citationsByPage[placement.index],
               let citation = citation(at: local, in: citations) {
                previewCitation(citation, on: placement)
                return true
            }
            if let mentions = captionMentionsByPage[placement.index],
               let mention = mention(at: local, in: mentions),
               openFigure(mention, from: placement.index, anchor: anchor(of: mention, on: placement)) {
                return true
            }
            // A section link is a reference to a *heading*, not to a picture: the clicked line
            // says so (`Sec. 2`, `Chapter IV`, `Appendix A`). A `/FitR` link already means a
            // figure or table region, so only a plain destination is considered.
            if link.region == nil,
               let section = sectionReference(near: box, on: placement) {
                openSectionPreview(page: page, reference: section,
                                   from: placement.index,
                                   anchor: viewRect(local: box, on: placement))
                return true
            }
            // M4: show the target in a floating panel rather than jumping, so the
            // citation can be read without losing the place in the text. When the
            // destination names a region (/FitR), only that region is shown -- which
            // is what a citation to a figure or table means.
            let opened = openReferencePreview(
                page: page,
                title: link.region == nil
                    ? "Page \(page + 1)"
                    : "Figure on page \(page + 1)",
                from: "page \(placement.index + 1)",
                kind: link.region == nil ? .page : .figure,
                anchor: viewRect(local: box, on: placement),
                region: link.region
            )
            if opened {
                statusMessage = "Previewing page \(page + 1)"
                resolveLinkedPreview(on: placement, at: local)
            }
            return true
        }
        return false
    }

    /// Classify a linked cold click after its temporary page preview has opened. Keep one
    /// request identity through citation, mention and caption loads, and preserve the fallback
    /// when none of them names an indexed entry. A later click, close or document switch wins.
    private func resolveLinkedPreview(on placement: PagePlacement, at local: CGPoint) {
        let epoch = documentEpoch
        let request = previewLookupEpoch
        Task { @MainActor [weak self] in
            guard let self, epoch == self.documentEpoch, request == self.previewLookupEpoch else { return }
            let citations: [Citation]
            if let cached = self.citationsByPage[placement.index] {
                citations = cached
            } else {
                citations = await self.startCitationLoad(page: placement.index).value ?? []
            }
            guard epoch == self.documentEpoch, request == self.previewLookupEpoch else { return }
            if let citation = self.citation(at: local, in: citations) {
                self.previewCitation(citation, on: placement)
                return
            }
            let mentions: [CaptionMention]
            if let cached = self.captionMentionsByPage[placement.index] {
                mentions = cached
            } else {
                mentions = (try? await self.engine.captionMentions(page: placement.index)) ?? []
            }
            guard epoch == self.documentEpoch, request == self.previewLookupEpoch else { return }
            self.captionMentionsByPage[placement.index] = mentions
            guard let mention = self.mention(at: local, in: mentions) else { return }
            let index = self.figures.isEmpty
                ? ((try? await self.engine.figures()) ?? []) : self.figures
            guard epoch == self.documentEpoch, request == self.previewLookupEpoch else { return }
            self.figures = index
            self.openFigure(mention, from: placement.index,
                            anchor: self.anchor(of: mention, on: placement))
        }
    }

    /// The section reference printed around a link box, if the link is one.
    ///
    /// The **line** the box touches is the evidence, not the box itself: papers routinely link
    /// only the numeral of `Section 2`, and the word that gives it meaning sits outside the
    /// annotation. `nil` when the page's text layer is not in memory yet; a generic page preview
    /// is the honest fallback then, and a later click (after the layer arrives) classifies it.
    private func sectionReference(near box: CGRect, on placement: PagePlacement) -> SectionReference? {
        guard let textPage = textPages[placement.index] else { return nil }
        let line = textPage.lineBounds(overlapping: box) ?? box
        guard let range = textPage.characterRange(in: line) else { return nil }
        return SectionReferenceText.reference(in: textPage.string(in: range))
    }

    /// Opens the text-only preview for a section reference, resolving its title from the outline.
    ///
    /// The title is the outline entry for the destination page (`designation` prefers the entry
    /// that names the same number/letter when a page holds several). Without one, the printed
    /// reference is the title; without either, the panel says so instead of showing an empty box.
    private func openSectionPreview(
        page: Int,
        reference: SectionReference,
        from sourcePage: Int,
        anchor: CGRect?
    ) {
        let title = SectionReferenceText.title(
            from: outline, page: page, designation: reference.designation
        )
        let opened = openReferencePreview(
            page: page,
            title: title ?? reference.printed,
            from: "page \(sourcePage + 1)",
            kind: .section,
            anchor: anchor,
            entries: [],
            sectionTitle: title,
            sectionReference: reference.printed
        )
        guard opened else { return }
        let resolved = title.map { "\"\($0)\"" } ?? "from the reference text"
        let line = "lyra-reader-section: \"\(reference.printed)\" -> page \(page + 1) title \(resolved)\n"
        FileHandle.standardError.write(Data(line.utf8))
        statusMessage = title.map { "Previewing \($0)" } ?? "Previewing \(reference.printed)"
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
    /// Dock icon, Finder's “Open With”, `open -a LyraReader …`, or a file dropped on the canvas. Failure
    /// is reported by returning `false` *after* `open(url:)` has set `lastError`, so the window can
    /// show the reader what happened.
    @discardableResult
    public func openDocumentInTab(_ url: URL) -> Bool {
        if deferContentTransition({[weak self] in _ = self?.openDocumentInTab(url)}) {return true}
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
        if deferContentTransition({[weak self] in self?.selectTab(index)}) {return}
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
        if deferContentTransition({[weak self] in self?.closeTab(index)}) {return}
        if index != activeTabIndex, retainedTabs[tabs[index].id]?.state.pageEditSession?.operations.isEmpty == false {selectTab(index)}
        if index == activeTabIndex, pageEditSession?.operations.isEmpty == false {
            pendingContentClose=index;contentCloseRequested=true;return
        }
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
            pendingRedactions: pendingRedactions,
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
            formInfo: formInfo,
            formDraft: formDraft,
            formToolActive: formToolActive,
            formLoadCompleted: formLoadCompleted,
            formError: formError,
            documentInfo: documentInfo,
            documentInfoLoading: documentInfoLoading,
            documentAnnotations: documentAnnotations,
            documentPopupFlags: documentPopupFlags,
            pendingFileDeletions: pendingFileDeletions,
            documentAnnotationsError: documentAnnotationsError,
            documentAnnotationsLoadCompleted: documentAnnotationsLoadCompleted,
            outline: outline,
            outlineLoadCompleted: outlineLoadCompleted,
            thumbnails: thumbnails,
            annotations: annotations,
            erasedInkStrokeIDs: erasedInkStrokeIDs,
            bookmarks: bookmarks,
            preservedAnnotationEntryCount: preservedAnnotationEntryCount,
            annotationWriteCount: annotationWriteCount,
            annotationCacheIsDirty: annotationCacheIsDirty,
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
            placedGlyphTextures: placedGlyphTextures,
            undoStack: undoStack,
            redoStack: redoStack
        )
    }

    /// Puts a retained document's state back. The engine has already been told to make its
    /// document current (`RustEngine.activateDocument(at:)`), so no file is read here.
    private func restoreDocumentState(_ state: TabDocumentState) {
        let wasChanging = isChangingDocumentState
        isChangingDocumentState = true
        defer { isChangingDocumentState = wasChanging }
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
        // Switching tabs leaves the document the history was recorded in.
        clearNavigationHistory()
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
        pendingRedactions = state.pendingRedactions
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
        formInfo = state.formInfo
        formDraft = state.formDraft
        formToolActive = state.formToolActive
        formLoadCompleted = state.formLoadCompleted
        formError = state.formError
        formLoading = false
        formFocusedFieldID = nil
        formOpenChoiceFieldID = nil
        formSaveInProgress = false
        documentInfo = state.documentInfo
        documentInfoLoading = state.documentInfoLoading
        documentInfoError = nil
        propertiesSaveInProgress = false
        documentAnnotations = state.documentAnnotations
        documentPopupFlags = state.documentPopupFlags
        pendingFileDeletions = state.pendingFileDeletions
        documentAnnotationsError = state.documentAnnotationsError
        documentAnnotationsLoadCompleted = state.documentAnnotationsLoadCompleted
        outline = state.outline
        outlineLoadCompleted = state.outlineLoadCompleted
        thumbnails = state.thumbnails
        annotations = state.annotations
        erasedInkStrokeIDs = state.erasedInkStrokeIDs
        eraserHoverMarkID = nil
        eraserGestureBase = nil
        eraserGestureSidecarSplits = [:]
        eraserGestureDocumentSplits = [:]
        eraserPreviewMarks = nil
        bookmarks = state.bookmarks
        preservedAnnotationEntryCount = state.preservedAnnotationEntryCount
        annotationWriteCount = state.annotationWriteCount
        annotationCacheIsDirty = state.annotationCacheIsDirty
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
        placedGlyphTextures = state.placedGlyphTextures
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
        if !formLoadCompleted { loadFormInfo() }
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
                "lyra-reader-tabs: evicted \(victim.url.lastPathComponent) "
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
            self.adoptEmbeddedBookmarks(from: found)
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
            Data("lyra-reader-position: restored \(Int(clamped)) pt of \(Int(contentHeightPt)) pt\n".utf8)
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
            Data("lyra-reader-position: saved \(Int(offset)) pt [\(trigger)]\n".utf8)
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

    /// Jump to a chat citation's page and flash the passage it came from.
    ///
    /// This creates no annotation and writes no sidecar: the boxes live in `aiSourceHighlight`
    /// for the length of the fade and are then dropped. The page is scrolled so the first line
    /// of the passage is visible, not merely so the page top is.
    public func revealAISource(page: Int, rects: [CGRect]) {
        guard let document, page >= 0, page < document.pageCount else { return }
        let clipped = rects.filter {
            $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0
        }
        let pageTop = engine.pageTopPt(page, gapPt: pageGapPt, layout: layoutMode)
        let passageTop = clipped.map(\.minY).min() ?? 0
        cancelScrollGlide()
        scrollYPt = clampedScrollOffset(max(pageTop, pageTop + passageTop - 40))
        let highlight = AISourceHighlight(page: page, rects: clipped)
        aiSourceHighlight = highlight
        reloadVisiblePages()
        schedulePositionSave()
        statusMessage = clipped.isEmpty
            ? "Jumped to page \(page + 1). The source region has no text geometry."
            : "Source highlighted on page \(page + 1); it fades and is not saved."
        fadeAISourceHighlight(id: highlight.id)
    }

    /// Drop the transient highlight immediately (new document, panel closed, clear chat).
    public func clearAISourceHighlight() {
        aiSourceHighlightTask?.cancel()
        aiSourceHighlightTask = nil
        guard aiSourceHighlight != nil else { return }
        aiSourceHighlight = nil
        refreshSelectionOverlay()
    }

    private func fadeAISourceHighlight(id: UUID) {
        aiSourceHighlightTask?.cancel()
        let clock = ContinuousClock()
        let started = clock.now
        aiSourceHighlightTask = Task { @MainActor [weak self] in
            // Absolute deadlines avoid extending every later phase when raster work delays
            // one main-actor resumption on a busy window or CI runner.
            for (phase, delay) in [
                (AISourceHighlight.Phase.soft, Duration.milliseconds(450)),
                (.faint, .milliseconds(900)),
            ] {
                try? await clock.sleep(until: started.advanced(by: delay))
                guard !Task.isCancelled, let self,
                      self.aiSourceHighlight?.id == id else { return }
                self.aiSourceHighlight?.phase = phase
                self.refreshSelectionOverlay()
            }
            try? await clock.sleep(until: started.advanced(by: .milliseconds(1_400)))
            guard !Task.isCancelled, let self,
                  self.aiSourceHighlight?.id == id else { return }
            self.aiSourceHighlight = nil
            self.refreshSelectionOverlay()
        }
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

    /// Follows an outline row. The reader's own bookmark subtree carries a page-local Y, so the
    /// click lands on the bookmarked paragraph; a document node without one goes to the page top.
    public func gotoOutlineEntry(_ entry: OutlineEntry) {
        guard document != nil, let page = entry.page else { return }
        guard let y = entry.yPt, y.isFinite, y > 0 else {
            gotoPage(page)
            return
        }
        cancelScrollGlide()
        let top = engine.pageTopPt(max(0, page), gapPt: pageGapPt, layout: layoutMode)
        scrollYPt = clampedScrollOffset(top + CGFloat(y))
        reloadVisiblePages()
        schedulePositionSave()
        statusMessage = "Jumped to “\(entry.title)”"
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
    /// it. Only ever zooms **out**, and never below the normal minimum. The fit uses the same
    /// calibration and inset as the Fit Width preset, and the anchor is the viewport centre, so
    /// the spread opens where the reader was looking rather than at a page corner. The user's
    /// 100% zoom is still one ⌘+ away.
    private func fitSpreadToViewportIfNeeded() {
        guard layoutMode == .facing, contentWidthPt > 0, viewportSizePt.width > 0 else { return }
        guard let fitPercent = fitZoomPercent(fittingContentPt: contentWidthPt,
                                              intoViewportPt: viewportSizePt.width)
        else { return }
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

    /// The viewer scale: `zoomPercent/100 × displayCalibration.factor`.
    ///
    /// This is the **only** place display calibration enters the render path. The canvas draws a
    /// page quad at `placement.widthPt × zoomFactor × backingScale` device pixels, so 100% is the
    /// page's physical width and 150% is 1.5× paper. The percentage stays the reader's setting;
    /// moving to another screen changes `displayCalibration.factor`, not `zoomPercent`.
    public var zoomFactor: CGFloat {
        CGFloat(zoomPercent) / 100.0 * displayCalibration.factor
    }

    /// Adopts the screen's calibration. The reader's percentage is kept: "100%" stays 100%, which
    /// now means actual size on the new screen.
    ///
    /// **Scroll position.** `scrollYPt` is in content points, so it is left exactly where it was,
    /// then clamped to the new scrollable range. Away from the document end the content point at
    /// the viewport top therefore stays put and the current page does not change; at the end the
    /// bottom-aligned view stays bottom-aligned, which can move the top to the previous page.
    /// Only the physical size of the visible region changes (a denser screen shows fewer page
    /// points at the same window size). An open document is re-laid out and its raster band
    /// rebuilt for the new effective scale.
    public func setDisplayCalibration(_ calibration: DisplayCalibration) {
        guard calibration.factor.isFinite, calibration.factor > 0 else { return }
        let factorChanged = abs(calibration.factor - displayCalibration.factor) > 1e-9
        guard factorChanged || calibration != displayCalibration else { return }
        displayCalibration = calibration
        // A different screen with the same density changes nothing on screen; only adopt its
        // description. A real factor change re-lays out the open document.
        guard factorChanged, document != nil else { return }
        cancelScrollGlide()
        let previousScroll = scrollYPt
        scrollYPt = clampedScrollOffset(scrollYPt)
        reloadVisiblePages()
        if abs(scrollYPt - previousScroll) > 0.01 { schedulePositionSave() }
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
        // Any explicit rebuild supersedes a width-only rebuild that was waiting to settle.
        pendingViewportReload?.cancel()
        pendingViewportReload = nil
        viewportReloadCount += 1
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

    /// Running totals for one viewport update (`LYRA_READER_RENDER_STATS=1`).
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

    /// `LYRA_READER_RENDER_STATS=1`: the shell's half of the HUD documented in docs/09 §9 —
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
            format: "lyra-reader-stats: cache %d tiles · tiles %.1f/%.1f MiB · pageRasters %.1f MiB · shared %.1f/%.1f MiB · peak tiles %.1f MiB · thumbnails %.1f MiB · text %.1f MiB · rasters total %.1f MiB · screenPages %@ · wanted %d · queued %d · hits %d · misses %d · hit rate %.1f%% · insertions %d · evictions %d (%.1f MiB)\n",
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
        // The same three consumers the `lyra-reader-stats` line totals, split by band class here: a
        // line that called the whole-page rasters "previews" is what made the two HUD lines
        // disagree about what the 48 MiB budget covers (T4.39).
        let bandLine = String(
            format: "lyra-reader-band: visible %d tiles (%.1f MiB) · ring %d (%.1f MiB) · offscreenCols %d (%.1f MiB) · stale %d (%.1f MiB) · pageRasters %.1f MiB · thumbnails %.1f MiB · text %.1f MiB · ringVh %.2f · visibleMiss %d · lod %d · tilePt %.0f · bandPages %d\n",
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
        if let highlight = aiSourceHighlight,
           let placement = visiblePagePlacements.first(where: { $0.index == highlight.page }) {
            let image: PageImage = switch highlight.phase {
            case .full: aiSourceFullImage
            case .soft: aiSourceSoftImage
            case .faint: aiSourceFaintImage
            }
            for (index, rect) in highlight.rects.enumerated() {
                pages.append(CanvasPage(
                    placement: PagePlacement(
                        index: PlacementIndex.aiSource(index),
                        topPt: placement.topPt + rect.minY,
                        leftPt: placement.leftPt + rect.minX,
                        widthPt: rect.width,
                        heightPt: rect.height
                    ),
                    image: image,
                    blend: .normal
                ))
            }
        }

        if let selection, !isMarkingTextSelection {
            // While a markup tool is armed the selection *is* the mark about to be committed:
            // it is drawn with the same quads, colour and blend as the finished annotation, so
            // the gesture reads as annotation rather than as selection. The ordinary blue
            // selection is used for every other tool, exactly as before.
            if let kind = annotationTool.textMarkupKind {
                let bar = Self.textMarkupBar(for: kind)
                appendHighlight(
                    page: selection.page,
                    range: selection.range,
                    // The same tint the committed mark uses: `addAnnotationFromSelection`
                    // stores `annotationColor`, and the own-annotation pass below draws it
                    // through this same call.
                    image: annotationTexture(for: annotationColor, opacity: 1.0, blend: .multiply),
                    idBase: PlacementIndex.selection(0),
                    verticalScale: bar.scale,
                    verticalOffset: bar.offset,
                    blend: .multiply,
                    to: &pages
                )
            } else {
                appendHighlight(
                    page: selection.page,
                    range: selection.range,
                    image: selectionImage,
                    idBase: PlacementIndex.selection(0),
                    to: &pages
                )
            }
        }

        for (annotationIndex, annotation) in annotations.enumerated() {
            // Geometry marks are drawn by the annotation overlay, and placed text is drawn from
            // its own glyph below; neither is a tinted text box.
            guard !annotation.kind.isGeometry, !annotation.kind.isPlacedText else { continue }
            let bar = Self.textMarkupBar(for: annotation.kind)
            let image = annotationTexture(for: annotation.color, opacity: 1.0, blend: .multiply)
            let idBase = PlacementIndex.ownAnnotation(annotationIndex)
            if let fixed = annotation.fileQuads, !fixed.isEmpty {
                appendHighlight(
                    quads: fixed.map {
                        CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                    },
                    page: annotation.page,
                    image: image,
                    idBase: idBase,
                    verticalScale: bar.scale,
                    verticalOffset: bar.offset,
                    blend: .multiply,
                    to: &pages
                )
            } else {
                appendHighlight(
                    page: annotation.page,
                    range: annotation.start...max(annotation.start, annotation.end),
                    // Multiply preserves black glyphs while tinting the paper, just like PDF
                    // markup.
                    image: image,
                    // Its own index block, one slot per line: the index is the key the canvas
                    // caches this quad's texture under, so it must not collide with a page raster
                    // or with a loaded annotation (see `PlacementIndex`).
                    idBase: idBase,
                    verticalScale: bar.scale,
                    verticalOffset: bar.offset,
                    blend: .multiply,
                    to: &pages
                )
            }
        }

        // Sticky notes and text boxes are glyphs, not tinted text boxes: an icon and a laid-out
        // paragraph. They go through their own placement block for the reason `PlacementIndex`
        // spells out. A text box being edited hides its page copy so the editor is the only text
        // on screen; a sticky note keeps its icon beside the editor.
        for (annotationIndex, annotation) in annotations.enumerated()
        where annotation.kind.isPlacedText {
            if editingAnnotationID == annotation.id, annotation.kind == .textBox { continue }
            guard let placement = visiblePagePlacements.first(where: { $0.index == annotation.page }),
                  let box = annotation.shapeRect,
                  let image = placedGlyphTexture(for: annotation, index: annotationIndex)
            else { continue }
            pages.append(CanvasPage(
                placement: PagePlacement(
                    index: PlacementIndex.ownNote(annotationIndex),
                    topPt: placement.topPt + box.minY,
                    leftPt: placement.leftPt + box.minX,
                    widthPt: box.width,
                    heightPt: box.height
                ),
                image: image,
                blend: .normal
            ))
        }

        // Stamps and image signatures are pictures, like a note icon: the canvas' textured-quad
        // path draws them, and the overlay only draws the selection halo and the resize handles.
        for (annotationIndex, annotation) in annotations.enumerated()
        where annotation.kind.isStampArtwork {
            guard let placement = visiblePagePlacements.first(where: { $0.index == annotation.page }),
                  let box = annotation.shapeRect,
                  let image = stampGlyphTexture(
                    kind: annotation.kind,
                    text: annotation.note,
                    style: annotation.stampStyle ?? "",
                    color: annotation.color,
                    imageData: annotation.imageData,
                    boxPt: box.size,
                    cacheKey: "own:\(annotationIndex)")
            else { continue }
            pages.append(CanvasPage(
                placement: PagePlacement(
                    index: PlacementIndex.ownNote(annotationIndex),
                    topPt: placement.topPt + box.minY,
                    leftPt: placement.leftPt + box.minX,
                    widthPt: box.width,
                    heightPt: box.height
                ),
                image: image,
                blend: .normal
            ))
        }

        for marker in ownInlineNoteMarkers {
            let annotation = annotations[marker.annotationIndex]
            guard let placement = visiblePagePlacements.first(where: { $0.index == marker.page }),
                  let image = ownInlineGlyph(annotation: annotation, index: marker.annotationIndex, size: marker.rect.size)
            else { continue }
            pages.append(CanvasPage(placement: PagePlacement(index: PlacementIndex.ownNote(marker.annotationIndex),
                topPt: placement.topPt + marker.rect.minY, leftPt: placement.leftPt + marker.rect.minX,
                widthPt: marker.rect.width, heightPt: marker.rect.height), image: image))
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

            case .stamp:
                guard let box = annotation.boxes.first,
                      let image = stampGlyphTexture(
                        kind: annotation.stampText?.isEmpty == false ? .stamp : .signature,
                        text: annotation.stampText ?? "",
                        style: annotation.stampStyle,
                        color: annotation.color ?? neutralColor,
                        imageData: annotation.stampImageData,
                        boxPt: CGSize(width: box.widthPt, height: box.heightPt),
                        cacheKey: "doc:\(annotationIndex)")
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
        case .geometry, .stamp, .skipped:
            nil
        }
        if let image { noteGlyphTextures[key] = image }
        return image
    }

    /// The bitmap for one sidecar sticky note or text box, from the cache or freshly rendered.
    private func placedGlyphTexture(for annotation: Annotation, index: Int) -> PageImage? {
        guard let box = annotation.shapeRect, box.width > 0, box.height > 0 else { return nil }
        let scale = NoteGlyph.scale(zoom: zoomFactor, deviceScale: deviceScale)
        let key = PlacedGlyphKey(
            index: index,
            kind: annotation.kind.rawValue,
            color: annotation.color,
            text: annotation.note,
            fontSize: annotation.fontSize,
            boxPt: box.size,
            scale: scale
        )
        if let cached = placedGlyphTextures[key] { return cached }
        // One cached bitmap per placed annotation: a resize walks through many box sizes (and a
        // zoom through scale steps), and keeping them all would grow with the gesture instead of
        // with the document.
        placedGlyphTextures = placedGlyphTextures.filter { $0.key.index != index }

        nextAnnotationTextureGeneration += 1
        let generation = nextAnnotationTextureGeneration
        let image: PageImage? = switch annotation.kind {
        case .stickyNote:
            NoteGlyph.noteIcon(color: annotation.color, boxPt: box.size, scale: scale,
                               generation: generation)
        case .textBox:
            NoteGlyph.freeText(annotation.note, color: annotation.color,
                               fontSizePt: annotation.fontSize > 0
                                   ? annotation.fontSize : Annotation.defaultTextBoxFontSize,
                               alignment: "left", boxPt: box.size, scale: scale,
                               generation: generation, useAppearanceFont: true)
        default:
            nil
        }
        if let image { placedGlyphTextures[key] = image }
        return image
    }

    /// The bitmap for one stamp badge or image signature, from the cache or freshly rendered.
    ///
    /// A text stamp is drawn with the same bundled font, border insets and fitted size the PDF
    /// writer uses, so the badge on screen and the `/AP` stream in the file say the same thing.
    /// An image signature is drawn from the picture's own pixels; a file-owned one arrives
    /// already decoded (`png`/`jpeg`) from the Rust reader.
    private func stampGlyphTexture(
        kind: AppState.Annotation.Kind,
        text: String,
        style: String,
        color: AnnotationColor,
        imageData: Data?,
        boxPt: CGSize,
        cacheKey: String
    ) -> PageImage? {
        guard boxPt.width > 0, boxPt.height > 0 else { return nil }
        let scale = NoteGlyph.scale(zoom: zoomFactor, deviceScale: deviceScale)
        let key = StampGlyphKey(
            cacheKey: cacheKey,
            kind: kind,
            text: text,
            style: style,
            color: color,
            imageData: imageData,
            boxPt: boxPt,
            scale: scale
        )
        if let cached = stampGlyphTextures[key] { return cached }

        nextAnnotationTextureGeneration += 1
        let generation = nextAnnotationTextureGeneration
        let image: PageImage?
        switch kind {
        case .signature:
            image = imageData
                .flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                .flatMap { NoteGlyph.signatureImage($0, boxPt: boxPt, scale: scale,
                                                    generation: generation) }
        case .stamp:
            image = NoteGlyph.stamp(text, color: color, boxPt: boxPt, scale: scale,
                                    generation: generation)
        default:
            image = nil
        }
        if let image { stampGlyphTextures[key] = image }
        return image
    }

    /// Identity of one stamp badge or signature image: every input that changes a pixel.
    private struct StampGlyphKey: Hashable {
        let cacheKey: String
        let kind: AppState.Annotation.Kind
        let text: String
        let style: String
        let color: AnnotationColor
        let imageData: Data?
        let boxPt: CGSize
        let scale: CGFloat
    }

    /// Identity of one placed-text glyph: every input that changes a pixel of it.
    private struct PlacedGlyphKey: Hashable {
        let index: Int
        let kind: String
        let color: AnnotationColor
        let text: String
        let fontSize: CGFloat
        let boxPt: CGSize
        let scale: CGFloat
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

    private func ownInlineGlyph(annotation: Annotation, index: Int, size: CGSize) -> PageImage? {
        let scale = NoteGlyph.scale(zoom: zoomFactor, deviceScale: deviceScale)
        let key = PlacedGlyphKey(index: index, kind: "inline-comment", color: annotation.color,
            text: "", fontSize: 0, boxPt: size, scale: scale)
        if let image = placedGlyphTextures[key] { return image }
        placedGlyphTextures = placedGlyphTextures.filter { $0.key.index != index }
        nextAnnotationTextureGeneration &+= 1
        let image = NoteGlyph.inlineComment(color: annotation.color, boxPt: size, scale: scale,
            generation: nextAnnotationTextureGeneration)
        if let image { placedGlyphTextures[key] = image }
        return image
    }

    /// Appends one tinted box per fixed page-space quad, for a mark the PDF carried.
    private func appendHighlight(
        quads: [CGRect],
        page: Int,
        image: PageImage,
        idBase: Int,
        verticalScale: CGFloat = 1.0,
        verticalOffset: CGFloat = 0.0,
        blend: QuadBlend = .normal,
        to pages: inout [CanvasPage]
    ) {
        guard let placement = visiblePagePlacements.first(where: { $0.index == page }) else { return }
        for (index, rect) in quads.enumerated() {
            pages.append(CanvasPage(
                placement: PagePlacement(
                    index: idBase + index,
                    topPt: placement.topPt + rect.minY + rect.height * verticalOffset,
                    leftPt: placement.leftPt + rect.minX,
                    widthPt: rect.width,
                    heightPt: max(rect.height * verticalScale, 1)
                ),
                image: image,
                blend: blend
            ))
        }
    }

    private func appendHighlight(
        page: Int,
        range: ClosedRange<Int>,
        image: PageImage,
        idBase: Int,
        verticalScale: CGFloat = 1.0,
        verticalOffset: CGFloat = 0.0,
        blend: QuadBlend = .normal,
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
                image: image,
                blend: blend
            ))
        }
    }

    /// The thin bar that represents a selected line in an underline or a strikeout.
    ///
    /// `offset` is the fraction of the selection rect's height where the bar starts and `scale`
    /// is its height as a fraction of the line. Both the live preview and the committed mark
    /// call this, so releasing the pointer cannot move or resize the mark that was under it.
    private static func textMarkupBar(for kind: Annotation.Kind) -> (scale: CGFloat, offset: CGFloat) {
        switch kind {
        case .underline: return (0.1, 0.9)
        case .strikeout: return (0.12, 0.45)
        // A highlight fills the whole quad; anything else is not a text mark and never reaches
        // here, so it gets the harmless fill style rather than an invented line.
        default: return (1.0, 0.0)
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
    /// A press on one of the reader's own ink or shape strokes selects that mark and starts a
    /// move, and does **not** start a text selection. The hit test is geometric and tight — a
    /// few points around the stroke — so text a line away from a thin pen line is untouched and
    /// a click on the text goes on to select it. A PDF's own ink is deliberately not hit tested
    /// here: it can be seen, not edited.
    ///
    /// A press on a text mark or an unselected text box is only a **candidate** for selection:
    /// it is remembered and decided on mouse-up (see `endPointerInteraction`). That is what lets
    /// a drag starting on a highlight, or inside an unselected text box, select the text under
    /// it instead of the mark.
    public func beginSelection(at point: CGPoint) {
        // A click that reached the canvas is outside every field (the form overlay consumes
        // field clicks), so it ends field editing and lets the press become a text selection.
        if formFocusedFieldID != nil { blurFormField() }
        if editingAnnotationID != nil { commitTextEditing() }
        pendingMarkSelection = nil
        if annotationTool == .select {
            if let hit = placedTextHit(atContentPoint: point),
               let annotation = annotations.first(where: { $0.id == hit.id }) {
                if annotation.kind == .textBox, annotation.id != selectedAnnotationID {
                    // A plain click selects the box; a drag still selects the text under it.
                    beginPendingMarkSelection(annotation, at: point)
                    return
                }
                selectedAnnotationID = hit.id
                selection = nil
                selectionAnchor = nil
                moveOriginalAnnotation = nil
                moveStartPagePoint = nil
                resizeOriginalAnnotation = nil
                resizeStartPagePoint = nil
                resizeHandle = nil
                if let handle = hit.handle {
                    resizeOriginalAnnotation = annotation
                    resizeStartPagePoint = hit.point
                    resizeHandle = handle
                } else {
                    moveOriginalAnnotation = annotation
                    moveStartPagePoint = hit.point
                }
                refreshSelectionOverlay()
                return
            }
            if let hit = geometryAnnotationHit(atContentPoint: point),
               let annotation = annotations.first(where: { $0.id == hit.id }) {
                selectedAnnotationID = hit.id
                moveOriginalAnnotation = annotation
                moveStartPagePoint = hit.point
                resizeOriginalAnnotation = nil
                resizeStartPagePoint = nil
                resizeHandle = nil
                selection = nil
                selectionAnchor = nil
                refreshSelectionOverlay()
                return
            }
            if let hit = documentStampHit(atContentPoint: point) {
                if Self.documentAnnotationEditability(hit.annotation) == .editable,
                   let id = adoptDocumentAnnotation(hit.annotation.id),
                   let annotation = annotations.first(where: { $0.id == id }) {
                    selectedAnnotationID = id
                    moveOriginalAnnotation = annotation
                    moveStartPagePoint = hit.point
                    resizeOriginalAnnotation = nil
                    resizeStartPagePoint = nil
                    resizeHandle = nil
                    selection = nil
                    selectionAnchor = nil
                    refreshSelectionOverlay()
                    return
                }
                _ = selectDocumentAnnotation(hit.annotation.id)
                return
            }
            if let hit = documentGeometryHit(atContentPoint: point),
               let id = adoptDocumentAnnotation(hit.annotation.id),
               let annotation = annotations.first(where: { $0.id == id }) {
                selectedAnnotationID = id
                moveOriginalAnnotation = annotation
                moveStartPagePoint = hit.point
                resizeOriginalAnnotation = nil
                resizeStartPagePoint = nil
                resizeHandle = nil
                selection = nil
                selectionAnchor = nil
                refreshSelectionOverlay()
                return
            }
            if let hit = textMarkupHit(atContentPoint: point),
               let annotation = annotations.first(where: { $0.id == hit.id }) {
                // Text reading wins over mark selection for as long as the pointer is moving;
                // only a click that stays inside the slop selects the mark on release.
                beginPendingMarkSelection(annotation, at: point)
                return
            }
        }
        selectedAnnotationID = nil
        moveOriginalAnnotation = nil
        moveStartPagePoint = nil
        resizeOriginalAnnotation = nil
        resizeStartPagePoint = nil
        resizeHandle = nil
        guard let hit = characterIndex(at: point) else {
            clearSelection()
            return
        }
        selectionAnchor = hit.index
        selection = Selection(page: hit.page, range: hit.index...hit.index)
        refreshSelectionOverlay()
    }

    /// Remembers a press that a plain click would turn into a mark selection.
    ///
    /// The character under the press is resolved now, while the point is known, so a drag can
    /// begin exactly where the reader aimed without asking the canvas to re-report the press.
    private func beginPendingMarkSelection(_ annotation: Annotation, at point: CGPoint) {
        cancelPendingMarkSelection()
        pendingMarkSelection = PendingMarkSelection(
            id: annotation.id,
            textAnchor: characterIndex(at: point)
        )
        moveOriginalAnnotation = nil
        moveStartPagePoint = nil
        resizeOriginalAnnotation = nil
        resizeStartPagePoint = nil
        resizeHandle = nil
    }

    private func cancelPendingMarkSelection() {
        pendingMarkSelection = nil
    }

    /// Turns a pending press into the text selection a drag means.
    ///
    /// Called by `extendSelection` the first time the pointer has actually moved past the
    /// canvas' click slop: the mark has not been selected, and the drag becomes an ordinary
    /// text selection anchored on the character the reader pressed.
    private func beginDeferredTextSelection() {
        guard let pending = pendingMarkSelection else { return }
        pendingMarkSelection = nil
        selectedAnnotationID = nil
        if let anchor = pending.textAnchor {
            selectionAnchor = anchor.index
            selection = Selection(page: anchor.page, range: anchor.index...anchor.index)
        } else {
            selectionAnchor = nil
            selection = nil
        }
        refreshSelectionOverlay()
    }

    /// Extends the selection to a point in content space.
    public func extendSelection(to point: CGPoint) {
        if pendingMarkSelection != nil {
            beginDeferredTextSelection()
        }
        if let original = resizeOriginalAnnotation, let handle = resizeHandle,
           let start = resizeStartPagePoint,
           let placement = visiblePagePlacements.first(where: { $0.index == original.page }) {
            let current = CGPoint(x: point.x - placement.leftPt, y: point.y - placement.topPt)
            guard let rect = resizedTextBox(
                original, handle: handle,
                delta: CGPoint(x: current.x - start.x, y: current.y - start.y)
            ), let index = annotations.firstIndex(where: { $0.id == original.id })
            else { return }
            annotations[index].shapeRect = rect
            // The text box's text is a canvas quad, so it has to be re-laid out at the new size
            // while the drag is in flight. This is a canvas refresh, not a sidecar write: the
            // file is written once, on mouse-up.
            refreshSelectionOverlay()
            return
        }
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
            if original.kind.isPlacedText {
                // A note icon and a text box are quads on the canvas rather than paths on the
                // overlay, so the picture follows the drag through the canvas refresh, not the
                // model write.
                refreshSelectionOverlay()
            }
            return
        }
        guard let anchor = selectionAnchor,
              let current = selection
        else { return }
        guard let hit = characterIndex(at: point, extendingSelection: true),
              hit.page == current.page
        else {
            // A markup drag that leaves the page it started on is abandoned rather than
            // clamped: the reader pointed away from those words, and committing the last
            // in-page sample on release would mark words the gesture had left behind.
            if annotationTool.isTextMarkup, !isOnSelectionPage(point, page: current.page) {
                cancelMarkupDragSelection()
            }
            return
        }

        let range = min(anchor, hit.index)...max(anchor, hit.index)
        guard range != current.range else { return }
        selection = Selection(page: current.page, range: range)
        refreshSelectionOverlay()
    }

    /// Whether a content point is inside the page a text selection belongs to.
    private func isOnSelectionPage(_ point: CGPoint, page: Int) -> Bool {
        visiblePagePlacements.contains { placement in
            placement.index == page
                && CGRect(x: placement.leftPt, y: placement.topPt,
                          width: placement.widthPt, height: placement.heightPt).contains(point)
        }
    }

    /// Drops a text selection that a markup drag is still extending, without committing it.
    ///
    /// Only a drag has an anchor; a selection that is merely on screen (a search hit, or one
    /// that survived leaving the tool) is reading state and is left alone.
    private func cancelMarkupDragSelection() {
        guard selectionAnchor != nil else { return }
        selection = nil
        selectionAnchor = nil
        refreshSelectionOverlay()
    }

    public func clearSelection() {
        guard selection != nil || selectionAnchor != nil else { return }
        selection = nil
        selectionAnchor = nil
        refreshSelectionOverlay()
    }

    /// Clears the selected mark without touching a text selection.
    public func clearAnnotationSelection() {
        cancelPendingMarkSelection()
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
    ///   * `LYRA_READER_SHARP_PAGE_RASTERS=0`, or `LYRA_READER_PREVIEW_PAGES=0`, disables it;
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
            return (false, "off: LYRA_READER_SHARP_PAGE_RASTERS=0 disables screen-resolution pages",
                    "off(feature-off)")
        }
        if Self.maxPreviewPages == 0 {
            return (false, "off: LYRA_READER_PREVIEW_PAGES=0 allows no whole-page raster",
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
            line = "lyra-reader-screen-page: \(note); using pyramid tiles\n"
        } else {
            line = String(format: "lyra-reader-screen-page: on · screen scale %.2f · %.1f MiB cache budget\n",
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

extension AppState {
    public var selectedContentItem: PDFContentItem? {
        contentEditPage?.items.first { $0.id == contentEditSelection }
    }

    public func selectContentTool(_ tool: String) {
        guard ["select", "text", "image", "link", "erase", "blackout"].contains(tool) else { return }
        if deferContentTransition({ [weak self] in self?.selectContentTool(tool) }) { return }
        contentEditTool = tool
        contentEditSelection = nil
        contentLinkDraft = nil
    }

    public func toggleAnnotationTools() {
        if contentEditEnabled, deferContentTransition({ [weak self] in self?.toggleAnnotationTools() }) { return }
        contentEditEnabled = false
        pageOverviewVisible = false
        annotationToolsVisible.toggle()
    }

    public func toggleContentEditing() {
        if contentEditEnabled, deferContentTransition({[weak self] in self?.toggleContentEditing()}) {return}
        contentEditEnabled.toggle()
        if contentEditEnabled { pageOverviewVisible = false }
        annotationTool = .select
        annotationToolsVisible = false
        contentEditSelection = nil
    }

    public func reloadContentObjects() async {
        guard contentEditEnabled, let url = document?.url else { return }
        let token = UUID()
        contentLoadToken = token
        contentEditLoading = true
        contentEditPage = nil
        contentEditSelection = nil
        let page = currentPage - 1
        do {
            let snapshot = try await engine.contentObjects(page: page)
            guard token == contentLoadToken, document?.url == url, currentPage - 1 == page else {
                return
            }
            contentEditPage = snapshot
            contentEditLoading = false
        } catch {
            guard token == contentLoadToken else { return }
            lastError = "Could not inspect page content: \(error.localizedDescription)"
            contentEditLoading = false
        }
    }

    public func transformContent(_ item: PDFContentItem, to rect: CGRect, rotation: Double = 0) {
        guard let page = contentEditPage else { return }
        var command = PDFContentCommand(action: "transform", revision: page.revision)
        command.target = item.id
        command.bounds = PDFContentBox(rect)
        command.rotation = rotation
        if item.can_edit_text, abs(rotation) < 0.001,
            abs(rect.width - item.bounds.width) > 0.1 || abs(rect.height - item.bounds.height) > 0.1
        {
            command.action = "replaceText"
            command.rotation = nil
            command.text = item.text
            command.font = "Original"
            command.size = item.size
            command.colour = item.colour
            command.alignment = 0
        }
        stageContentEdit(command, page: page.page, label: "Move or resize \(item.kind)")
    }

    public func replaceContentText(
        _ item: PDFContentItem, text: String, font: String = "Original", size: Double? = nil,
        colour: [UInt8]? = nil, alignment: Int = 0
    ) {
        guard let page = contentEditPage else { return }
        var command = PDFContentCommand(action: "replaceText", revision: page.revision)
        command.target = item.id
        command.bounds = item.bounds
        command.text = text
        command.font = font
        command.size = size ?? item.size
        command.colour = colour ?? item.colour
        command.alignment = alignment
        stageContentEdit(command, page: page.page, label: "Edit page text")
    }

    public func insertContentText(at rect: CGRect) {
        guard let page = contentEditPage else { return }
        var command = PDFContentCommand(action: "insertText", revision: page.revision)
        command.bounds = PDFContentBox(rect)
        command.text = "New text"
        command.font = "Helvetica"
        command.size = 12
        command.colour = [0, 0, 0, 255]
        command.alignment = 0
        stageContentEdit(command, page: page.page, label: "Insert page text")
    }

    public func deleteContent(_ item: PDFContentItem) {
        guard let page = contentEditPage else { return }
        var command = PDFContentCommand(action: "delete", revision: page.revision)
        command.target = item.id
        stageContentEdit(command, page: page.page, label: "Delete \(item.kind)")
    }

    public func redactContent(in rect: CGRect, blackout: Bool) {
        guard let page = contentEditPage else { return }
        var command = PDFContentCommand(action: "redact", revision: page.revision)
        command.bounds = PDFContentBox(rect)
        command.blackout = blackout
        stageContentEdit(
            command, page: page.page,
            label: blackout ? "Blackout page content" : "Erase page content")
    }

    public func setContentLink(_ item: PDFContentItem?, page: Int?, uri: String?) {
        guard let snapshot = contentEditPage, let bounds = item?.bounds.rect ?? contentLinkDraft
        else { return }
        if let page, page < 0 || page >= (document?.pageCount ?? 0) {
            lastError = "Choose a page inside this document."
            return
        }
        var command = PDFContentCommand(action: "setLink", revision: snapshot.revision)
        command.target = item?.id
        command.bounds = PDFContentBox(bounds)
        command.page = page
        command.uri = uri
        contentLinkDraft = nil
        stageContentEdit(
            command, page: snapshot.page, label: item == nil ? "Insert link" : "Edit link")
    }

    public func chooseContentImage(at rect: CGRect? = nil, replacing item: PDFContentItem? = nil) {
        guard let page = contentEditPage else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url),
            let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { return }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LyraContentImage-\(UUID().uuidString).png")
        do { try png.write(to: path, options: .atomic) } catch {
            lastError = error.localizedDescription
            return
        }
        var command = PDFContentCommand(
            action: item == nil ? "insertImage" : "replaceImage", revision: page.revision)
        command.target = item?.id
        command.image_path = path.path
        if let rect {
            command.bounds = PDFContentBox(
                CGRect(
                    x: rect.minX, y: rect.minY, width: 180,
                    height: 180 * Double(cg.height) / Double(cg.width)))
        }
        stageContentEdit(
            command, page: page.page, label: item == nil ? "Insert image" : "Replace image")
    }

    public func cropContentImage(_ item: PDFContentItem, to crop: CGRect) {
        guard let page = contentEditPage else { return }
        var command = PDFContentCommand(action: "cropImage", revision: page.revision)
        command.target = item.id
        command.crop = PDFContentBox(crop)
        stageContentEdit(command, page: page.page, label: "Crop image")
    }

    public func contentImageData(_ item: PDFContentItem) async throws -> Data {
        guard let page = contentEditPage else { throw NSError(domain: "LyraReader", code: 1) }
        if item.kind == "image" {
            return try await engine.contentImagePNG(
                page: page.page, target: item.id, revision: page.revision)
        }
        let r = item.bounds.rect
        let image = try await engine.rasterizeRegion(
            page: page.page, scale: 2, xPt: r.minX, yPt: r.minY, widthPt: r.width,
            heightPt: r.height, transparentBackground: false)
        guard let data = image.contentPNGData() else {
            throw NSError(domain: "LyraReader", code: 2)
        }
        return data
    }

    public func exportContentImage(_ item: PDFContentItem) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let data = try await contentImageData(item)
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.nameFieldStringValue = "image.png"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
                statusMessage = "Image exported"
            } catch { lastError = "Image export failed: \(error.localizedDescription)" }
        }
    }

    private func preserveContentFailure(
        _ command: PDFContentCommand, _ message: String, page: Int? = nil, url: URL? = nil
    ) {
        if command.action == "replaceText", let text = command.text {
            contentRecoveryCommand = (
                command, page ?? contentEditPage?.page ?? currentPage - 1, url ?? document?.url
            )
            contentTextRecovery = text
            contentEditEnabled = true
        }
        lastError = message
    }

    public func retryContentText(font: String) {
        guard let pending = contentRecoveryCommand, let text = contentTextRecovery,
            let snapshot = contentEditPage
        else { return }
        var command = pending.command
        guard snapshot.revision == command.revision, document?.url == pending.url else {
            lastError = "This draft belongs to an older page. Copy it before discarding the draft."
            return
        }
        command.text = text
        command.font = font
        contentTextRecovery = nil
        stageContentEdit(command, page: pending.page, label: "Edit page text")
    }
    public func recoverDetachedContentText(
        _ item: PDFContentItem, text: String, revision: String, page: Int, url: URL?
    ) {
        var command = PDFContentCommand(action: "replaceText", revision: revision)
        command.target = item.id
        command.bounds = item.bounds
        command.text = text
        command.font = "Original"
        command.size = item.size
        command.colour = item.colour
        command.alignment = 0
        preserveContentFailure(
            command,
            "The page changed before this text draft was committed. Your words are preserved in the Edit sidebar.",
            page: page, url: url)
    }
    public func discardContentTextRecovery() {
        contentTextRecovery = nil
        contentRecoveryCommand = nil
        contentEditTask = nil
    }

    private func deferContentTransition(_ action: @escaping @MainActor () -> Void) -> Bool {
        guard contentTextRecovery == nil else {
            lastError = "Finish or discard the recovered text draft before leaving this document."
            return true
        }
        let hadDraft = contentTextEditing
        if hadDraft { commitContentText?() }
        if hadDraft || contentCommandInFlight, let task = contentEditTask {
            Task { @MainActor in if await task.value { action() } }
            return true
        }
        return false
    }

    public func cancelContentClose() {
        contentCloseRequested = false
        pendingContentClose = nil
    }
    public func discardContentAndClose() {
        guard let index = pendingContentClose else { return }
        cancelContentClose()
        discardPageEdits()
        closeTab(index)
    }
    public func saveContentAndClose() {
        guard let index = pendingContentClose else { return }
        contentCloseRequested = false
        var destination: URL?
        if isReadOnlyDocument {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = "Edited document.pdf"
            guard panel.runModal() == .OK, let url = panel.url else { cancelContentClose(); return }
            destination = url
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let saved: Bool
            if let destination { saved = await savePageEditsCopy(to: destination) }
            else { saved = await saveDocumentToOriginal() }
            guard saved else { return }
            pendingContentClose = nil
            closeTab(index)
        }
    }

    private func stageContentEdit(_ command: PDFContentCommand, page: Int, label: String) {
        guard contentTextRecovery == nil else {
            lastError = "Finish or discard the recovered text draft before another edit."
            return
        }
        guard !contentCommandInFlight, !pageEditBusy, !contentEditLoading else {
            preserveContentFailure(
                command, "Wait for the current page change to finish.", page: page)
            return
        }
        guard contentEditPage?.revision == command.revision else {
            preserveContentFailure(command, "The page changed before this edit. Reload the page before retrying.", page: page)
            return
        }
        contentCommandInFlight = true
        let source = document?.url
        contentEditTask = Task { @MainActor [weak self] in
            defer {
                self?.contentCommandInFlight = false
                if let path = command.image_path,
                    URL(fileURLWithPath: path).lastPathComponent.hasPrefix("LyraContentImage-")
                {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
            guard let self else { return false }
            guard await ensurePageEditSession(),
                let snapshot = pageEditSnapshot(label: label), document?.url == source
            else {
                preserveContentFailure(command, "Could not prepare the working copy.", page: page)
                return false
            }
            var next: URL?
            var effectiveCommand = command
            do {
                if try await materializeAnnotationsInWorkingCopy() {
                    effectiveCommand.revision = try await engine.contentObjects(page: page).revision
                }
                guard var session = pageEditSession else { return false }
                pageEditBusy = true
                defer { pageEditBusy = false }
                let destination = session.directory.appendingPathComponent("rev-\(UUID().uuidString).pdf")
                next = destination
                let editingSource = document?.url
                try await engine.applyContentEdit(page: page, command: effectiveCommand, to: destination)
                guard document?.url == editingSource else {
                    throw NSError(
                        domain: "LyraReader", code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey: "The active document changed during the edit"
                        ])
                }
                try loadPageEditRevision(
                    at: destination, title: session.title, sidecarURL: session.sidecarURL,
                    annotations: annotations, bookmarks: bookmarks, slots: annotationSidecarSlots,
                    currentPage: currentPage, selection: pageSelection)
                session.revisionURL = destination
                session.revisionNumber += 1
                session.operations.append(label)
                session.undo.append(snapshot)
                session.redo.removeAll()
                pageEditSession = session
                pageEditPendingOperations = session.operations
                pageEditIsApplied = false
                if command.action == "replaceText" {
                    contentRecoveryCommand = nil
                    contentTextRecovery = nil
                }
                statusMessage = "\(label) · unsaved PDF changes"
                await reloadContentObjects()
                return true
            } catch {
                await reloadContentObjects()
                preserveContentFailure(
                    effectiveCommand,
                    "Content edit failed; the previous revision is unchanged: \(error.localizedDescription)",
                    page: page, url: document?.url)
                if let next { try? FileManager.default.removeItem(at: next) }
                return false
            }
        }
    }
}
