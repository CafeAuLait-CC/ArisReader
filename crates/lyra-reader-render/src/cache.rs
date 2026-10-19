//! Tile cache policy: **byte budget + LRU + pinned set** (the specification and test bed).
//!
//! ADR 0007 (`docs/adr/0007-tile-cache-and-scheduling.md`) decided where the production cache
//! lives and what this module is for: the hot-path cache stays in the shell, because a cache
//! lookup must sit next to the draw call rather than behind one FFI round trip per tile; and
//! the *policy* is this one — a budget in **bytes**, LRU order, and a pinned set that is never
//! evicted. The shell's `TileCache` (`apps/macos/Sources/LyraReaderKit/TileCache.swift`) is the
//! port of that policy onto the path users actually run, and it is checked against these
//! cases.
//!
//! So this module is deliberately *not* called by the app: deleting it would delete the
//! specification the shell is held to, and calling it from the shell would undo ADR 0007's
//! reason for keeping the cache in Swift. The eviction tests below are the executable half of
//! that specification.
//!
//! The current implementation is a **naive LRU** (each eviction scans for the oldest entry), good enough for the skeleton phase.
//! TODO(T1.6): switch to LRU-K with batch eviction (release 10% of capacity at once) to avoid frame-time jitter;
//! and split the budget into three tiers, "GPU texture / CPU bitmap / disk" (`docs/03-rendering.md` §6).

use crate::tile::TileKey;
use std::collections::{BTreeMap, HashMap, HashSet};

/// One cache record (`layer` is the texture array layer index allocated by `lyra-reader-gpu`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CacheEntry {
    pub layer: u32,
    pub bytes: u64,
}

/// Cache statistics.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CacheStats {
    pub hits: u64,
    pub misses: u64,
    pub insertions: u64,
    pub evictions: u64,
    /// Total bytes uploaded to the GPU.
    pub upload_bytes: u64,
}

impl CacheStats {
    pub fn hit_rate(&self) -> f64 {
        let total = self.hits + self.misses;
        if total == 0 {
            0.0
        } else {
            self.hits as f64 / total as f64
        }
    }
}

/// Tile cache.
pub struct TileCache {
    /// key → (record, last-used sequence number)
    entries: HashMap<TileKey, (CacheEntry, u64)>,
    /// sequence number → key (used to find the oldest entry in O(log n))
    order: BTreeMap<u64, TileKey>,
    /// Pinned set: visible tiles, next LOD, floating-preview target pages (never evicted)
    pinned: HashSet<TileKey>,
    tick: u64,
    budget_bytes: u64,
    used_bytes: u64,
    stats: CacheStats,
}

impl TileCache {
    pub fn new(budget_bytes: u64) -> Self {
        Self {
            entries: HashMap::new(),
            order: BTreeMap::new(),
            pinned: HashSet::new(),
            tick: 0,
            budget_bytes,
            used_bytes: 0,
            stats: CacheStats::default(),
        }
    }

    pub fn budget_bytes(&self) -> u64 {
        self.budget_bytes
    }

    pub fn used_bytes(&self) -> u64 {
        self.used_bytes
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn stats(&self) -> CacheStats {
        self.stats
    }

    pub fn contains(&self, key: &TileKey) -> bool {
        self.entries.contains_key(key)
    }

    /// Look up an entry and refresh its last-used time.
    pub fn get(&mut self, key: &TileKey) -> Option<CacheEntry> {
        let (entry, old_tick) = *self.entries.get(key)?;
        self.order.remove(&old_tick);
        let tick = self.bump();
        self.entries.insert(*key, (entry, tick));
        self.order.insert(tick, *key);
        self.stats.hits += 1;
        Some(entry)
    }

    /// Record a miss (for hit-rate statistics).
    pub fn record_miss(&mut self) {
        self.stats.misses += 1;
    }

    /// Insert (or replace) a record and return the evicted keys (the caller releases the corresponding GPU textures).
    pub fn insert(&mut self, key: TileKey, entry: CacheEntry) -> Vec<TileKey> {
        if let Some((old, old_tick)) = self.entries.remove(&key) {
            self.order.remove(&old_tick);
            self.used_bytes = self.used_bytes.saturating_sub(old.bytes);
        }
        let tick = self.bump();
        self.used_bytes += entry.bytes;
        self.entries.insert(key, (entry, tick));
        self.order.insert(tick, key);
        self.stats.insertions += 1;
        self.stats.upload_bytes += entry.bytes;
        self.evict_to_fit()
    }

    pub fn pin(&mut self, key: TileKey) {
        self.pinned.insert(key);
    }

    pub fn unpin(&mut self, key: &TileKey) {
        self.pinned.remove(key);
    }

    /// Replace the pinned set with a new one (the visible set is refreshed once per frame).
    pub fn set_pinned(&mut self, keys: impl IntoIterator<Item = TileKey>) {
        self.pinned = keys.into_iter().collect();
    }

    pub fn is_pinned(&self, key: &TileKey) -> bool {
        self.pinned.contains(key)
    }

    /// Evict until the budget is met; **pinned entries and the most recently inserted entry are never evicted**.
    ///
    /// The most recent insert is protected so that a tile just uploaded to the GPU is not dropped immediately (which would waste the upload).
    /// In the extreme case (everything pinned) the cache is allowed to exceed the budget temporarily — better to use extra memory than to lose visible content.
    pub fn evict_to_fit(&mut self) -> Vec<TileKey> {
        let mut evicted = Vec::new();
        let newest = self.order.keys().next_back().copied();
        while self.used_bytes > self.budget_bytes {
            let victim = self
                .order
                .iter()
                .find(|(tick, key)| Some(**tick) != newest && !self.pinned.contains(*key))
                .map(|(tick, key)| (*tick, *key));
            let Some((tick, key)) = victim else {
                break; // everything is pinned: exceed the budget rather than drop visible content
            };
            self.order.remove(&tick);
            if let Some((entry, _)) = self.entries.remove(&key) {
                self.used_bytes = self.used_bytes.saturating_sub(entry.bytes);
            }
            self.stats.evictions += 1;
            evicted.push(key);
        }
        evicted
    }

    /// Clear the cache (on document close or GPU device rebuild).
    pub fn clear(&mut self) -> Vec<TileKey> {
        let keys: Vec<TileKey> = self.entries.keys().copied().collect();
        self.entries.clear();
        self.order.clear();
        self.pinned.clear();
        self.used_bytes = 0;
        keys
    }

    pub fn set_budget(&mut self, budget_bytes: u64) -> Vec<TileKey> {
        self.budget_bytes = budget_bytes;
        self.evict_to_fit()
    }

    fn bump(&mut self) -> u64 {
        self.tick += 1;
        self.tick
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tile::Lod;
    use lyra_reader_core::{DocId, PageIndex};

    fn key(page: u32, col: u32, row: u32) -> TileKey {
        TileKey::new(DocId(1), PageIndex(page), Lod(1), col, row, 0)
    }

    fn entry(bytes: u64) -> CacheEntry {
        CacheEntry { layer: 0, bytes }
    }

    #[test]
    fn evicts_least_recently_used() {
        let mut cache = TileCache::new(300);
        cache.insert(key(0, 0, 0), entry(100));
        cache.insert(key(0, 1, 0), entry(100));
        cache.insert(key(0, 2, 0), entry(100));
        assert_eq!(cache.used_bytes(), 300);

        // touch tile 0 so that it becomes the most recently used
        assert!(cache.get(&key(0, 0, 0)).is_some());

        // inserting a new tile → the oldest one, (1,0), should be evicted
        let evicted = cache.insert(key(0, 3, 0), entry(100));
        assert_eq!(evicted, vec![key(0, 1, 0)]);
        assert!(!cache.contains(&key(0, 1, 0)));
        assert!(cache.contains(&key(0, 0, 0)));
        assert_eq!(cache.used_bytes(), 300);
    }

    #[test]
    fn pinned_entries_survive_eviction() {
        let mut cache = TileCache::new(200);
        cache.insert(key(0, 0, 0), entry(100));
        cache.insert(key(0, 1, 0), entry(100));
        cache.set_pinned([key(0, 0, 0)]); // pin the oldest tile

        let evicted = cache.insert(key(0, 2, 0), entry(100));
        assert_eq!(evicted, vec![key(0, 1, 0)]);
        assert!(cache.contains(&key(0, 0, 0)));
    }

    #[test]
    fn all_pinned_never_evicts() {
        let mut cache = TileCache::new(100);
        cache.insert(key(0, 0, 0), entry(100));
        cache.set_pinned([key(0, 0, 0)]);
        // neither the pinned entry nor the just-inserted one is evicted → the budget may be exceeded temporarily
        let evicted = cache.insert(key(0, 1, 0), entry(100));
        assert!(evicted.is_empty());
        assert_eq!(cache.len(), 2);
        assert!(cache.used_bytes() > cache.budget_bytes());
    }

    #[test]
    fn newest_insert_is_protected_but_older_ones_are_not() {
        let mut cache = TileCache::new(100);
        cache.insert(key(0, 0, 0), entry(100));
        // the second tile exceeds the budget: the first tile is not the newest, so it is evicted
        let evicted = cache.insert(key(0, 1, 0), entry(100));
        assert_eq!(evicted, vec![key(0, 0, 0)]);
        assert_eq!(cache.len(), 1);
        assert!(cache.contains(&key(0, 1, 0)));
    }

    #[test]
    fn replacing_same_key_does_not_double_count() {
        let mut cache = TileCache::new(1000);
        cache.insert(key(0, 0, 0), entry(100));
        cache.insert(key(0, 0, 0), entry(250));
        assert_eq!(cache.used_bytes(), 250);
        assert_eq!(cache.len(), 1);
    }

    #[test]
    fn hit_rate_is_reported() {
        let mut cache = TileCache::new(1000);
        cache.insert(key(0, 0, 0), entry(10));
        let _ = cache.get(&key(0, 0, 0));
        cache.record_miss();
        let stats = cache.stats();
        assert_eq!(stats.hits, 1);
        assert_eq!(stats.misses, 1);
        assert!((stats.hit_rate() - 0.5).abs() < 1e-9);
    }
}
