//! Render scheduling layer (**no GPU code**): translates "viewport changes" into "which tiles to rasterize and in what order".
//!
//! Task mapping: T1.5 (pyramid + LOD + priority + banded cancellation), T1.6 (cache).
//!
//! Data flow (see `docs/03-rendering.md` §3–§5 for details):
//!
//! ```text
//! viewport ──▶ visible_tiles() ──▶ select_lod() ──▶ cache lookup ──▶ task enqueue (priority)
//!                                                       │                           │
//!                                                  hit ─┘                           └─▶ raster thread pool
//! ```

pub mod cache;
pub mod tile;

pub use cache::{CacheEntry, CacheStats, TileCache};
pub use tile::{
    LOD_DOWNGRADE_FACTOR, LOD_UPGRADE_FACTOR, Lod, RenderPriority, RenderRequest, TileKey,
    gesture_lod, select_lod, tile_dims, visible_tiles,
};

/// Texture identity (allocated by `aris-reader-gpu`; the scheduling layer only holds an opaque handle).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct TextureId(pub u32);

/// Render statistics (for the HUD and tuning, see `docs/03-rendering.md` §11).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct RenderStats {
    pub frames: u64,
    pub tiles_rasterized: u64,
    pub tiles_uploaded: u64,
    pub last_frame_ms: f32,
    pub average_frame_ms: f32,
    pub cache: CacheStats,
}

/// Raster task scheduler.
///
/// TODO(T1.5): priority queue (binary heap) + in-flight deduplication + epoch invalidation + per-frame submit cap (K=8).
#[derive(Default)]
pub struct RenderScheduler {
    _private: (),
}

impl RenderScheduler {
    pub fn new() -> Self {
        Self::default()
    }

    /// Recompute the pending task set when the viewport changes.
    ///
    /// TODO(T1.5): implement the three-tier priority split "visible → target LOD / one LOD lower / prefetch".
    pub fn on_viewport_changed(&mut self, _epoch: u64) {}

    /// Maximum number of tasks submitted to the raster thread pool per frame (avoids dropped frames caused by momentary CPU saturation while scrolling).
    pub const MAX_RASTER_SUBMITS_PER_FRAME: usize = 8;

    /// Task queue capacity (backpressure; when exceeded, tasks with priority ≥ [`RenderPriority::Thumbnail`] are dropped).
    pub const MAX_QUEUE_LEN: usize = 512;
}
