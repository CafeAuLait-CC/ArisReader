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

    /// A selection: a page and an inclusive character range in its text layer.
    public struct Selection: Equatable, Sendable {
        public let page: Int
        public let range: ClosedRange<Int>
    }

    @Published public private(set) var selection: Selection?
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
            }
            reloadVisiblePages()

            // Development aid: ARIS_READER_SELECT="x1,y1;x2,y2" (content points) selects
            // between two points and copies, so the text path can be verified headlessly.
            if let raw = ProcessInfo.processInfo.environment["ARIS_READER_SELECT"], !raw.isEmpty {
                selectForVerification(raw)
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

    /// Adds one translucent quad per selected character.
    private func appendSelectionHighlights(to pages: inout [CanvasPage]) {
        guard let selection,
              let textPage = textPages[selection.page],
              let placement = visiblePagePlacements.first(where: { $0.index == selection.page })
        else { return }

        for index in selection.range where index < textPage.chars.count {
            let character = textPage.chars[index]
            pages.append(
                CanvasPage(
                    placement: PagePlacement(
                        index: 900_000_000 + index,
                        topPt: placement.topPt + character.yPt,
                        leftPt: placement.leftPt + character.xPt,
                        widthPt: character.widthPt,
                        heightPt: character.heightPt
                    ),
                    image: highlightImage
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
