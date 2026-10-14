import Foundation

/// Identity of one tile in the pyramid: page, LOD, column, row.
///
/// Public (like `TileCache` itself) so the budget checks in `apps/macos/Checks` can drive the
/// cache directly instead of only through a full `AppState` viewport update.
public struct TileKey: Hashable, Sendable {
    public let page: Int
    public let lod: UInt8
    public let x: Int
    public let y: Int

    public init(page: Int, lod: UInt8, x: Int, y: Int) {
        self.page = page
        self.lod = lod
        self.x = x
        self.y = y
    }
}

/// Tile-cache counters for `ARIS_READER_RENDER_STATS=1` and for the checks.
public struct TileCacheStats: Equatable, Sendable {
    public var hits = 0
    public var misses = 0
    public var insertions = 0
    public var evictions = 0
    /// Bytes dropped by eviction, so the counter can be read as "the budget did work".
    public var evictedBytes = 0

    public init() {}

    public var hitRate: Double {
        let total = hits + misses
        return total == 0 ? 0 : Double(hits) / Double(total)
    }
}

/// Byte-budgeted, LOD-aware LRU cache of rasterized tiles.
///
/// ADR 0007 split the two tile caches in this repository: the hot-path cache stays in the
/// shell, but it adopts the **byte budget** policy that `crates/aris-reader-render/src/cache.rs`
/// already encoded. This type is that policy, ported to Swift; the Rust module stays as its
/// specification and test bed. The rules, in the order they matter:
///
/// 1. **Bytes, not tiles.** The budget is spent from `PageImage.bgra.count` — the actual
///    bitmap the cache retains (tile pixel size × 4), never an estimate. A tile count cannot
///    bound memory: at deep zoom the reader wants many more tiles, and the pre-ADR count cap
///    of 96 was exceeded whenever those wanted tiles filled it (measured: 110 tiles).
/// 2. **Pinned tiles are never evicted.** The caller passes what must survive: the tiles
///    visible in the current viewport plus the rasters in flight. If the pinned set alone
///    exceeds the budget, the cache exceeds the budget — dropping a visible tile to hit a
///    number would trade correctness for memory. (Same rule as `all_pinned_never_evicts`.)
/// 3. **The newest insert is protected** during the eviction pass that follows it, so a tile
///    that was just rasterized is not thrown away before it can be drawn. (Rust:
///    `newest_insert_is_protected_but_older_ones_are_not`.)
/// 4. **LOD-aware LRU.** Among evictable tiles, one from a LOD *other* than the current one
///    goes first: after a zoom, the previous level's tiles are the ones nothing will draw
///    again. Within a LOD class the least recently used tile goes first.
public struct TileCache {
    /// One cached tile: the pixels plus the accounting the budget is spent from.
    private struct Entry {
        let image: PageImage
        var lastUsed: UInt64
    }

    public private(set) var budgetBytes: Int
    public private(set) var usedBytes = 0
    /// High-water mark since the cache was created (survives `removeAll`), for the HUD.
    public private(set) var peakBytes = 0
    public private(set) var stats = TileCacheStats()

    private var entries: [TileKey: Entry] = [:]
    /// Monotonic use counter; the smallest value is the least recently used entry.
    private var tick: UInt64 = 0
    /// Most recent insertion, protected in the following eviction pass (rule 3).
    private var newest: TileKey?

    public init(budgetBytes: Int) {
        self.budgetBytes = max(1, budgetBytes)
    }

    public var count: Int { entries.count }

    /// Exact bytes one tile occupies: the real bitmap, `pixelWidth × pixelHeight × 4`, not an
    /// estimate from the tile size and the LOD (edge tiles are cropped).
    private static func byteCount(of image: PageImage) -> Int {
        image.bgra.count
    }

    public func contains(_ key: TileKey) -> Bool {
        entries[key] != nil
    }

    /// Looks a tile up and marks it as most recently used; a hit is counted.
    public mutating func image(for key: TileKey) -> PageImage? {
        guard var entry = entries[key] else { return nil }
        entry.lastUsed = bump()
        entries[key] = entry
        stats.hits += 1
        return entry.image
    }

    /// Records a miss (a tile the caller has to rasterize) for the hit-rate counter.
    public mutating func recordMiss() {
        stats.misses += 1
    }

    /// Inserts (or replaces) a tile. Replacing does not double-count its bytes.
    @discardableResult
    public mutating func insert(_ image: PageImage, for key: TileKey) -> Int {
        let bytes = Self.byteCount(of: image)
        if let old = entries.removeValue(forKey: key) {
            usedBytes -= Self.byteCount(of: old.image)
        }
        entries[key] = Entry(image: image, lastUsed: bump())
        usedBytes += bytes
        peakBytes = max(peakBytes, usedBytes)
        newest = key
        stats.insertions += 1
        return bytes
    }

    /// Sets a new budget; the caller follows with `evictToFit`.
    public mutating func setBudget(_ bytes: Int) {
        budgetBytes = max(1, bytes)
    }

    /// Evicts until `usedBytes <= budgetBytes`, or until only pinned/newest tiles are left.
    ///
    /// Returns the evicted keys (the caller may want to release GPU textures for them).
    @discardableResult
    public mutating func evictToFit(pinned: Set<TileKey>, currentLod: UInt8) -> [TileKey] {
        var evicted: [TileKey] = []
        while usedBytes > budgetBytes {
            guard let victim = victim(pinned: pinned, currentLod: currentLod) else { break }
            remove(victim)
            evicted.append(victim)
        }
        return evicted
    }

    /// Drops every tile (document close, zoom invalidation). Counters and the peak survive, so
    /// the HUD still reports what the run reached.
    public mutating func removeAll() {
        entries.removeAll()
        usedBytes = 0
        newest = nil
    }

    // MARK: - Private

    /// Rule 4: stale-LOD tiles first, least recently used first inside each class.
    private func victim(pinned: Set<TileKey>, currentLod: UInt8) -> TileKey? {
        var bestKey: TileKey?
        var bestRank: (stale: Int, lastUsed: UInt64)?
        for (key, entry) in entries where !pinned.contains(key) && key != newest {
            let rank = (stale: key.lod == currentLod ? 1 : 0, lastUsed: entry.lastUsed)
            if bestRank == nil || rank < bestRank! {
                bestKey = key
                bestRank = rank
            }
        }
        return bestKey
    }

    private mutating func remove(_ key: TileKey) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        usedBytes -= Self.byteCount(of: entry.image)
        stats.evictions += 1
        stats.evictedBytes += Self.byteCount(of: entry.image)
        if newest == key { newest = nil }
    }

    private mutating func bump() -> UInt64 {
        tick += 1
        return tick
    }
}
