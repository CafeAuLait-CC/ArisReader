//! Engine configuration. Every tunable parameter lives here so it does not end up scattered around.

/// Cache budgets at each level (bytes).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CacheBudget {
    /// GPU texture cache (default 512 MB).
    pub gpu_texture_bytes: u64,
    /// CPU bitmap cache (default 128 MB; 0 = disabled).
    pub cpu_bitmap_bytes: u64,
    /// On-disk tile cache (default 0 = disabled; to be evaluated in M7).
    pub disk_bytes: u64,
}

impl Default for CacheBudget {
    fn default() -> Self {
        Self {
            gpu_texture_bytes: 512 * 1024 * 1024,
            cpu_bitmap_bytes: 128 * 1024 * 1024,
            disk_bytes: 0,
        }
    }
}

/// Global engine configuration.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EngineConfig {
    pub cache: CacheBudget,
    /// Number of raster worker threads (0 = automatic: `min(4, cores-1)`).
    pub raster_threads: usize,
    /// Upper limit on PDFium document copies (each copy backs one raster thread).
    pub max_document_copies: usize,
    /// Tile edge length in device pixels; 512 is recommended.
    pub tile_size: u32,
    /// Maximum tile pyramid level (LOD n corresponds to raster scale `2^n`).
    pub max_lod: u8,
    /// Pixel budget for a **single page texture**.
    ///
    /// Until the tile pipeline lands (T1.5), one page is one texture, so this doubles as
    /// the memory ceiling for a visible page: 8 MP ≈ 32 MB. It still gives A4 a crisp
    /// render at 400% zoom (2380 × 3368) and clamps only beyond that, which is also what
    /// keeps `ArisDocument::rasterize_page` from allocating 128 MB at 800%.
    pub full_page_max_pixels: u64,
    /// Enable the wgpu validation layer (during development).
    pub gpu_validation: bool,
}

impl Default for EngineConfig {
    fn default() -> Self {
        Self {
            cache: CacheBudget::default(),
            raster_threads: 0,
            max_document_copies: 4,
            tile_size: 512,
            max_lod: 4,
            full_page_max_pixels: 8 * 1024 * 1024,
            gpu_validation: cfg!(debug_assertions),
        }
    }
}

impl EngineConfig {
    /// Resolves the number of raster threads actually used.
    pub fn effective_raster_threads(&self) -> usize {
        if self.raster_threads > 0 {
            return self.raster_threads;
        }
        let cores = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(4);
        cores.saturating_sub(1).clamp(1, 4)
    }
}
