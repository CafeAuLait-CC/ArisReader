import ArisReaderKit
import Foundation

/// A tile engine whose tiles are exactly `tileSize × tileSize` pixels, so a check can predict
/// the byte budget's arithmetic instead of measuring it. Its 10 pages are laid out like
/// `PreviewEngine`'s (`pageTopPt = 1200 × index`), so a page jump makes the previous pages'
/// tiles stale — which is what the budget is allowed to evict.
@MainActor private final class BudgetTileEngine: PreviewEngine {
    override func rasterizeTile(page: Int, lod: UInt8, tileX: Int, tileY: Int, tileSize: Int) async throws -> TileImage {
        TileImage(page: page, lod: lod, tileX: tileX, tileY: tileY, sizePx: tileSize,
                  bgra: Data(repeating: 200, count: tileSize * tileSize * 4),
                  generation: UInt64(9000 + page * 100 + tileY * 10 + tileX))
    }

    override func renderPage(_ page: Int, scale: CGFloat) async throws -> PageImage {
        PageImage(pixelWidth: 1, pixelHeight: 1, pointSize: CGSize(width: 600, height: 1200),
                  bgra: Data([255, 255, 255, 255]), generation: UInt64(800 + page))
    }

    override func visiblePages(scrollYPt: CGFloat, viewportHeightPt: CGFloat, gapPt: CGFloat, marginPt: CGFloat) -> [PagePlacement] {
        (0..<10).compactMap { page in
            let top = CGFloat(page) * 1200
            guard top + 1200 >= scrollYPt - marginPt, top <= scrollYPt + viewportHeightPt + marginPt else { return nil }
            return PagePlacement(index: page, topPt: top, leftPt: 0, widthPt: 600, heightPt: 1200)
        }
    }

    override func contentHeightPt(gapPt: CGFloat) -> CGFloat { 12_000 }

    override func pageIndex(atScrollYPt scrollYPt: CGFloat, gapPt: CGFloat) -> Int {
        min(9, max(0, Int(scrollYPt / 1200)))
    }
}

extension ReaderChecks {
    /// ADR 0007: the shell's tile cache spends a **byte** budget, evicts LOD-aware, and never
    /// drops a tile that is visible or pinned.
    ///
    /// The cases below are the Swift port of the specification and test bed in
    /// `crates/aris-reader-render/src/cache.rs` (`evicts_least_recently_used`,
    /// `pinned_entries_survive_eviction`, `all_pinned_never_evicts`,
    /// `newest_insert_is_protected_but_older_ones_are_not`,
    /// `replacing_same_key_does_not_double_count`, `hit_rate_is_reported`), plus the two rules
    /// this port adds: a budget that holds whenever the pinned working set fits inside it, and
    /// a LOD-aware eviction order.
    @MainActor static func tileCacheChecks(url: URL) async throws {
        func key(_ page: Int, _ x: Int, lod: UInt8 = 1) -> TileKey {
            TileKey(page: page, lod: lod, x: x, y: 0)
        }

        /// A bitmap of exactly `bytes` bytes: the budget must be spent from the real allocation.
        func image(_ bytes: Int) -> PageImage {
            PageImage(pixelWidth: bytes / 4, pixelHeight: 1, pointSize: CGSize(width: 1, height: 1),
                      bgra: Data(repeating: 0, count: bytes), generation: 1)
        }

        // evicts_least_recently_used
        var cache = TileCache(budgetBytes: 300)
        cache.insert(image(100), for: key(0, 0))
        cache.insert(image(100), for: key(0, 1))
        cache.insert(image(100), for: key(0, 2))
        require(cache.usedBytes == 300, "byte accounting uses the bitmap's real size")
        require(cache.image(for: key(0, 0)) != nil, "a cached tile is a hit")
        cache.insert(image(100), for: key(0, 3))
        var evicted = cache.evictToFit(pinned: [], currentLod: 1)
        require(evicted == [key(0, 1)], "over-budget insertion evicts the least recently used tile")
        require(cache.usedBytes == 300 && cache.usedBytes <= cache.budgetBytes,
                "usedBytes <= budgetBytes after eviction")
        require(cache.contains(key(0, 0)) && cache.contains(key(0, 3)),
                "the touched tile and the newest insert survive")

        cache = TileCache(budgetBytes: 300)
        cache.insert(image(100), for: key(0, 0))
        cache.insert(image(100), for: key(0, 1))
        cache.evictToFit(pinned: [], currentLod: 1, reservedBytes: 200)
        require(cache.usedBytes == 100,
                "page-raster bytes reserve space in the same cache budget")

        // pinned_entries_survive_eviction
        cache = TileCache(budgetBytes: 200)
        cache.insert(image(100), for: key(0, 0))
        cache.insert(image(100), for: key(0, 1))
        cache.insert(image(100), for: key(0, 2))
        evicted = cache.evictToFit(pinned: [key(0, 0)], currentLod: 1)
        require(evicted == [key(0, 1)], "a pinned (visible) tile is never evicted")
        require(cache.contains(key(0, 0)) && cache.usedBytes <= cache.budgetBytes,
                "eviction drops an unpinned tile instead of the pinned one")

        // newest_insert_is_protected_but_older_ones_are_not
        cache = TileCache(budgetBytes: 100)
        cache.insert(image(100), for: key(0, 0))
        cache.insert(image(100), for: key(0, 1))
        evicted = cache.evictToFit(pinned: [], currentLod: 1)
        require(evicted == [key(0, 0)] && cache.contains(key(0, 1)),
                "the tile just rasterized survives the eviction pass it triggered")

        // all_pinned_never_evicts: the budget yields rather than dropping visible content.
        cache = TileCache(budgetBytes: 100)
        cache.insert(image(100), for: key(0, 0))
        cache.insert(image(100), for: key(0, 1))
        evicted = cache.evictToFit(pinned: [key(0, 0)], currentLod: 1)
        require(evicted.isEmpty && cache.count == 2 && cache.usedBytes > cache.budgetBytes,
                "when the visible set alone exceeds the budget the cache stays over it")

        // replacing_same_key_does_not_double_count
        cache = TileCache(budgetBytes: 1000)
        cache.insert(image(100), for: key(0, 0))
        cache.insert(image(250), for: key(0, 0))
        require(cache.usedBytes == 250 && cache.count == 1, "replacing a tile does not double-count its bytes")

        // hit_rate_is_reported
        cache = TileCache(budgetBytes: 1000)
        cache.insert(image(10), for: key(0, 0))
        _ = cache.image(for: key(0, 0))
        _ = cache.image(for: key(0, 1))
        cache.recordMiss()
        require(cache.stats.hits == 1 && cache.stats.misses == 1
                && abs(cache.stats.hitRate - 0.5) < 1e-9,
                "hits, misses and hit rate are counted")

        // LOD-aware: after a zoom the previous level's tiles are dead weight, so they go first
        // even when they are more recently used than a current-LOD tile.
        cache = TileCache(budgetBytes: 200)
        cache.insert(image(100), for: key(0, 0, lod: 1))
        cache.insert(image(100), for: key(0, 1, lod: 2))
        cache.insert(image(100), for: key(0, 2, lod: 1))
        _ = cache.image(for: key(0, 0, lod: 1)) // the LOD-1 tile is now the most recently used
        evicted = cache.evictToFit(pinned: [], currentLod: 1)
        require(evicted == [key(0, 1, lod: 2)],
                "eviction prefers a stale-LOD tile over a current-LOD tile (evicted \(evicted))")
        require(cache.contains(key(0, 0, lod: 1)), "the current-LOD tile survives although LRU alone would drop it")

        // The budget always holds while the pinned working set fits inside it.
        cache = TileCache(budgetBytes: 400)
        let visibleKey = key(0, 0)
        cache.insert(image(100), for: visibleKey)
        for x in 1...6 {
            cache.insert(image(100), for: key(0, x))
            _ = cache.evictToFit(pinned: [visibleKey], currentLod: 1)
            require(cache.usedBytes <= cache.budgetBytes && cache.contains(visibleKey),
                    "usedBytes <= budgetBytes and the visible tile survives (insert \(x))")
        }
        require(cache.stats.evictions >= 3, "over-budget insertions did evict (\(cache.stats.evictions))")

        // The setting really sizes a live cache, and lowering it shrinks the cache immediately.
        // A dedicated suite keeps this hermetic: the checks must never write the reader's own
        // `cacheBudgetMB`, and a leftover value here would change every later check.
        let suiteName = "aris-reader-checks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(16, forKey: AppState.cacheBudgetSettingKey)
        require(AppState.configuredTileCacheBudgetBytes(environment: [:], defaults: defaults) == 16 * 1024 * 1024,
                "the cacheBudgetMB setting is what sizes the cache (was hard-coded to 512 before ADR 0007)")
        require(AppState.configuredTileCacheBudgetBytes(environment: ["ARIS_READER_CACHE_BUDGET_MB": "32"], defaults: defaults)
                    == 32 * 1024 * 1024,
                "the measurement override wins over the stored setting")
        require(AppState.configuredTileCacheBudgetBytes(environment: [:], defaults: defaults) != 512 * 1024 * 1024,
                "the old 512 MB default no longer applies")
        require(AppState.configuredTileCacheBudgetBytes(environment: ["ARIS_READER_CACHE_BUDGET_MB": "0"], defaults: defaults)
                    == 1024 * 1024,
                "a zero/garbage budget is clamped instead of disabling the cache")

        let state = AppState(engine: BudgetTileEngine(), tileCacheBudgetBytes: 16 * 1024 * 1024, preferFullPageRasters: false)
        state.setViewportSize(CGSize(width: 700, height: 500))
        state.setDeviceScale(1) // LOD 0: 512 px tiles cover each 600×1200 pt page in 2×3
        state.open(url: url)
        state.gotoPage(0)
        require(state.tileCacheBudgetBytes == 16 * 1024 * 1024,
                "a live AppState adopts the configured budget")
        try await eventually("tile cache fills through the budgeted path", { state.tileCacheTileCount > 0 })

        // A page jump makes the previous pages' tiles stale. At LOD 0 the wanted band on page 9
        // is ~4.5 MiB (page 8's last rows + page 9's three rows, edges cropped: 1 MiB is
        // 512×512×4), so a 5 MB budget has to evict the tiles the reader scrolled away from and
        // must keep the ones still on screen.
        let visibleOnPage0 = TileKey(page: 0, lod: 0, x: 0, y: 0)
        try await eventually("first page's visible tile is cached", { state.isTileCached(visibleOnPage0) })
        defaults.set(5, forKey: AppState.cacheBudgetSettingKey)
        state.applyCacheBudgetSetting(environment: [:], defaults: defaults)
        require(state.tileCacheBudgetBytes == 5 * 1024 * 1024, "Settings sets the live budget")

        let visibleOnPage9 = TileKey(page: 9, lod: 0, x: 0, y: 0)
        state.gotoPage(9)
        try await eventually("the scrolled-away tiles are evicted", { state.tileCacheEvictions > 0 })
        try await eventually("the new viewport's visible tile is cached", { state.isTileCached(visibleOnPage9) })
        require(state.isTileCached(visibleOnPage9),
                "a visible tile survives the eviction pass")
        require(state.tileCacheUsedBytes <= state.tileCacheBudgetBytes,
                "after eviction the live cache is inside its byte budget "
                + "(\(state.tileCacheUsedBytes) <= \(state.tileCacheBudgetBytes))")
        require(state.tileCachePeakBytes >= state.tileCacheUsedBytes,
                "the peak byte counter is reported for the HUD")
    }
}
