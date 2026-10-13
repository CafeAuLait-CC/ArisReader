//! UniFFI control plane: the object graph the shell drives.
//!
//! Scope for T0.8 is deliberately small — just enough to prove the generated-bindings
//! pipeline end to end and to replace the shell's mock engine with something real:
//!
//! * [`ArisEngine`] — version/backend information plus [`ArisEngine::probe_document`],
//!   which opens a PDF through the PDFium backend and returns a value-typed
//!   [`DocumentSummary`].
//!
//! The full object graph (long-lived documents, sessions, viewports, event streams)
//! lands in M1; its shape is specified in `docs/05-ffi.md` §3–§4.

use aris_reader_core::{
    DocumentBackend, ENGINE_VERSION, EngineConfig, ErrorCode, PageIndex, RasterRequest,
};
use aris_reader_pdfium::{PdfiumBackend, backend_description};
use aris_reader_session::DocumentLayout;
use std::sync::{Arc, Mutex};

/// Errors crossing the FFI boundary (they surface as Swift `throws`).
#[derive(Debug, uniffi::Error)]
pub enum ArisFfiError {
    /// The file could not be read or parsed.
    Document { message: String },
    /// No usable PDF backend (for example, PDFium could not be loaded).
    Backend { message: String },
    /// The caller passed something invalid.
    InvalidArgument { message: String },
}

impl std::fmt::Display for ArisFfiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Document { message } => write!(f, "document error: {message}"),
            Self::Backend { message } => write!(f, "backend error: {message}"),
            Self::InvalidArgument { message } => write!(f, "invalid argument: {message}"),
        }
    }
}

impl std::error::Error for ArisFfiError {}

impl From<aris_reader_core::ArisError> for ArisFfiError {
    fn from(error: aris_reader_core::ArisError) -> Self {
        let message = error.to_string();
        match error.code {
            ErrorCode::BackendUnavailable | ErrorCode::GpuUnavailable => Self::Backend { message },
            ErrorCode::InvalidArgument => Self::InvalidArgument { message },
            _ => Self::Document { message },
        }
    }
}

/// Value-typed document summary, safe to copy across the boundary.
#[derive(Debug, Clone, uniffi::Record)]
pub struct DocumentSummary {
    /// Absolute or user-supplied path the document was opened from.
    pub path: String,
    pub page_count: u32,
    /// First page size in points, already accounting for `/Rotate` and `/UserUnit`.
    pub first_page_width_pt: f64,
    pub first_page_height_pt: f64,
    /// `/Rotate` of the first page, in degrees (0/90/180/270).
    pub rotation_degrees: i32,
    pub is_encrypted: bool,
    /// Which backend produced this summary (for diagnostics in the UI).
    pub backend: String,
}

/// The engine handle owned by the shell.
///
/// It carries no per-document state yet, so it is cheap to construct and safe to hand
/// to several views; long-lived documents arrive with M1.
#[derive(Debug, uniffi::Object)]
pub struct ArisEngine {
    config: EngineConfig,
}

#[uniffi::export]
impl ArisEngine {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            config: EngineConfig::default(),
        })
    }

    /// Engine version (from the crate metadata).
    pub fn version(&self) -> String {
        ENGINE_VERSION.to_string()
    }

    /// Which PDF backend this build uses.
    pub fn backend(&self) -> String {
        backend_description().to_string()
    }

    /// How many raster threads the engine would use on this machine.
    pub fn raster_threads(&self) -> u32 {
        self.config.effective_raster_threads() as u32
    }

    /// Opens `path`, summarizes it and closes it again.
    ///
    /// Long-lived document handles, page textures and event streams are M1 work; this
    /// method exists so the shell can show real page counts today and so the control
    /// plane is exercised end to end.
    pub fn probe_document(
        &self,
        path: String,
        password: Option<String>,
    ) -> Result<DocumentSummary, ArisFfiError> {
        let backend = PdfiumBackend::open(std::path::Path::new(&path), password.as_deref())?;

        let page_count = backend.page_count();
        let (width, height, rotation) = if page_count > 0 {
            let info = backend.page_info(PageIndex(0))?;
            let view = info.geometry.view_size(1.0);
            (view.width, view.height, info.geometry.rotation.degrees())
        } else {
            (0.0, 0.0, 0)
        };

        Ok(DocumentSummary {
            path,
            page_count,
            first_page_width_pt: width,
            first_page_height_pt: height,
            rotation_degrees: rotation,
            is_encrypted: backend.is_encrypted(),
            backend: backend_description().to_string(),
        })
    }
}

/// Size of a page in points, already accounting for `/Rotate`.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct PageSize {
    pub width_pt: f64,
    pub height_pt: f64,
    pub rotation_degrees: i32,
}

/// A rasterized page, ready to be uploaded to the GPU.
///
/// `pixels` is BGRA (sRGB), exactly what the GPU layer expects — see
/// `docs/03-rendering.md` §5. The shell uploads it and draws a quad; until the tile
/// pipeline lands (T1.5–T1.7) a whole page is one texture.
#[derive(Debug, Clone, uniffi::Record)]
pub struct PageBitmap {
    pub width_px: u32,
    pub height_px: u32,
    pub stride: u32,
    pub width_pt: f64,
    pub height_pt: f64,
    /// Scale actually used. May be **lower** than requested: see
    /// [`ArisDocument::rasterize_page`]'s clamp, which keeps a single page texture inside
    /// a sane memory budget until tiles land (T1.5).
    pub scale_used: f64,
    pub pixels: Vec<u8>,
}

/// An open document.
///
/// Long-lived by design: the shell opens once and then asks for pages as the reader
/// navigates. Threading follows `docs/02-architecture.md` §3 — the backend is
/// `Send + Sync`, and rasterization happens on the caller's thread for now (the raster
/// pool arrives with T1.3).
#[derive(uniffi::Object)]
pub struct ArisDocument {
    backend: PdfiumBackend,
    path: String,
    /// Page sizes in points, filled on first layout request (a 2000-page manual would
    /// otherwise pay for every box at open time).
    page_sizes: Mutex<Option<Vec<(f64, f64)>>>,
    /// Last computed layout, keyed by the page gap it was built for.
    layout: Mutex<Option<(f64, Arc<DocumentLayout>)>>,
}

#[uniffi::export]
impl ArisDocument {
    /// The path this document was opened from.
    pub fn path(&self) -> String {
        self.path.clone()
    }

    pub fn page_count(&self) -> u32 {
        self.backend.page_count()
    }

    /// Page size in points (`/Rotate` applied).
    pub fn page_size_pt(&self, page: u32) -> Result<PageSize, ArisFfiError> {
        let info = self.backend.page_info(PageIndex(page))?;
        let view = info.geometry.view_size(1.0);
        Ok(PageSize {
            width_pt: view.width,
            height_pt: view.height,
            rotation_degrees: info.geometry.rotation.degrees(),
        })
    }

    /// Rasterizes `page` at `scale` (1.0 = 72 dpi) into a BGRA buffer.
    ///
    /// # Clamping
    ///
    /// A whole page is one texture until the tile pipeline lands, so deep zoom would
    /// allocate enormous bitmaps (400% on A4 is 32 MP ≈ 128 MB). The request is therefore
    /// clamped to [`EngineConfig::full_page_max_pixels`] (and to a maximum edge length),
    /// and the scale actually used is reported back in [`PageBitmap::scale_used`]; the
    /// shell keeps drawing the quad at its layout size, so the GPU upscales.
    ///
    /// # Threading
    ///
    /// Callable from any thread: the PDFium backend serialises rendering process-wide,
    /// because PDFium's renderer is not thread-safe even across documents. The shell still
    /// keeps its own queue so the main thread never blocks.
    pub fn rasterize_page(&self, page: u32, scale: f64) -> Result<PageBitmap, ArisFfiError> {
        if !(scale.is_finite() && scale > 0.0) {
            return Err(ArisFfiError::InvalidArgument {
                message: format!("scale must be positive and finite, got {scale}"),
            });
        }

        let size = self
            .page_sizes()
            .get(page as usize)
            .copied()
            .unwrap_or((612.0, 792.0));
        let scale = clamp_scale(size, scale);

        let request = RasterRequest::full_page(PageIndex(page), scale);
        let tile = self.backend.rasterize(&request)?;
        let info = self.backend.page_info(PageIndex(page))?;
        let view = info.geometry.view_size(1.0);

        Ok(PageBitmap {
            width_px: tile.size.width.round() as u32,
            height_px: tile.size.height.round() as u32,
            stride: tile.stride as u32,
            width_pt: view.width,
            height_pt: view.height,
            scale_used: scale,
            pixels: tile.pixels,
        })
    }

    /// Total height of the scrolling content for the given page gap.
    pub fn content_height_pt(&self, gap_pt: f64) -> f64 {
        self.layout(gap_pt).content_height_pt()
    }

    /// Width of the widest page (pages are centred horizontally).
    pub fn content_width_pt(&self, gap_pt: f64) -> f64 {
        self.layout(gap_pt).content_width_pt()
    }

    /// Top edge of a page in content space (for "go to page" and anchoring).
    pub fn page_top_pt(&self, page: u32, gap_pt: f64) -> f64 {
        self.layout(gap_pt).page_top_pt(page).unwrap_or(0.0)
    }

    /// Page occupying the viewport top — the "current page" for the HUD.
    pub fn page_index_at(&self, scroll_y_pt: f64, gap_pt: f64) -> u32 {
        self.layout(gap_pt).page_at(scroll_y_pt)
    }

    /// Pages overlapping the viewport, in reading order.
    ///
    /// `margin_pt` widens the window so the shell can prefetch the next page.
    pub fn visible_pages(
        &self,
        scroll_y_pt: f64,
        viewport_height_pt: f64,
        gap_pt: f64,
        margin_pt: f64,
    ) -> Vec<PagePlacementRecord> {
        self.layout(gap_pt)
            .visible_pages(scroll_y_pt, viewport_height_pt, margin_pt)
            .iter()
            .map(|page| PagePlacementRecord {
                index: page.index,
                top_pt: page.top_pt,
                left_pt: page.left_pt,
                width_pt: page.width_pt,
                height_pt: page.height_pt,
            })
            .collect()
    }
}

impl ArisDocument {
    /// Builds (and caches) the layout for `gap_pt`.
    fn layout(&self, gap_pt: f64) -> Arc<DocumentLayout> {
        // Rust 2024 let-chains keep the lookups flat.
        if let Ok(cache) = self.layout.lock()
            && let Some((cached_gap, layout)) = cache.as_ref()
            && (*cached_gap - gap_pt).abs() < f64::EPSILON
        {
            return Arc::clone(layout);
        }

        let sizes = self.page_sizes();
        let layout = Arc::new(DocumentLayout::new(sizes.iter().copied(), gap_pt));

        if let Ok(mut cache) = self.layout.lock() {
            *cache = Some((gap_pt, Arc::clone(&layout)));
        }
        layout
    }

    /// Page sizes in points, computed once and cached.
    fn page_sizes(&self) -> Vec<(f64, f64)> {
        if let Ok(cache) = self.page_sizes.lock()
            && let Some(sizes) = cache.as_ref()
        {
            return sizes.clone();
        }

        let count = self.backend.page_count();
        let mut sizes = Vec::with_capacity(count as usize);
        for index in 0..count {
            let size = self
                .backend
                .page_info(PageIndex(index))
                .map(|info| {
                    let view = info.geometry.view_size(1.0);
                    (view.width, view.height)
                })
                .unwrap_or((612.0, 792.0)); // US Letter as a safe fallback
            sizes.push(size);
        }

        if let Ok(mut cache) = self.page_sizes.lock() {
            *cache = Some(sizes.clone());
        }
        sizes
    }
}

/// Largest edge length a single page texture may have.
///
/// 8192 is safe across the Metal/Vulkan/DX12 backends we target; the pixel-count clamp
/// below is usually the tighter of the two.
const MAX_PAGE_EDGE_PX: f64 = 8192.0;

/// Reduces `scale` so that the resulting bitmap stays within the engine's budget.
fn clamp_scale(page_size_pt: (f64, f64), requested: f64) -> f64 {
    let config = EngineConfig::default();
    let (width_pt, height_pt) = page_size_pt;
    if width_pt <= 0.0 || height_pt <= 0.0 {
        return requested;
    }

    let requested_pixels = width_pt * requested * height_pt * requested;
    let budget = config.full_page_max_pixels as f64;
    let mut scale = requested;

    if requested_pixels > budget {
        scale *= (budget / requested_pixels).sqrt();
    }

    let longest_edge = width_pt.max(height_pt) * scale;
    if longest_edge > MAX_PAGE_EDGE_PX {
        scale *= MAX_PAGE_EDGE_PX / longest_edge;
    }

    scale
}

/// Where one page sits in the scrolling content (mirrors `PagePlacement`).
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct PagePlacementRecord {
    pub index: u32,
    pub top_pt: f64,
    pub left_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
}

#[uniffi::export]
impl ArisEngine {
    /// Opens a document and keeps it open (contrast with [`ArisEngine::probe_document`],
    /// which is a one-shot summary).
    pub fn open_document(
        &self,
        path: String,
        password: Option<String>,
    ) -> Result<Arc<ArisDocument>, ArisFfiError> {
        let backend = PdfiumBackend::open(std::path::Path::new(&path), password.as_deref())?;
        Ok(Arc::new(ArisDocument {
            backend,
            path,
            page_sizes: Mutex::new(None),
            layout: Mutex::new(None),
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn engine_reports_version_and_backend() {
        let engine = ArisEngine::new();
        assert_eq!(engine.version(), ENGINE_VERSION);
        assert!(engine.backend().contains("pdfium") || engine.backend().contains("stub"));
        assert!(engine.raster_threads() >= 1);
    }

    #[test]
    fn probing_a_missing_file_is_a_document_error() {
        let engine = ArisEngine::new();
        let result = engine.probe_document("/nonexistent/aris-reader.pdf".to_string(), None);
        match result {
            Err(ArisFfiError::Document { message }) => assert!(!message.is_empty()),
            other => panic!("expected a document error, got {other:?}"),
        }
    }

    #[test]
    fn deep_zoom_is_clamped_to_the_page_budget() {
        let budget = EngineConfig::default().full_page_max_pixels as f64;

        // 400% on A4 is 2380x3368 = 8 MP, which still fits the 16.7 MP budget: untouched.
        assert_eq!(clamp_scale((595.0, 842.0), 4.0), 4.0);

        // 800% is 32 MP, so the scale comes down until the page fits (rounding the pixel
        // dimensions up can leave a few hundred pixels over, hence the 1% tolerance).
        let clamped = clamp_scale((595.0, 842.0), 8.0);
        assert!(clamped < 8.0, "scale should be reduced, got {clamped}");
        let pixels = 595.0 * clamped * 842.0 * clamped;
        assert!(
            pixels <= budget * 1.01,
            "clamped page is still {pixels:.0} px"
        );

        // The edge cap covers long, narrow pages whose pixel count alone would pass.
        let narrow = clamp_scale((20.0, 20_000.0), 1.0);
        assert!(
            20_000.0 * narrow <= MAX_PAGE_EDGE_PX * 1.01,
            "edge not clamped: {narrow}"
        );
    }

    #[test]
    fn rasterizing_a_fixture_page_reports_the_scale_used() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/text-page.pdf");
        if !fixture.exists() || !aris_reader_pdfium::is_available() {
            eprintln!("skipping: fixture or PDFium unavailable");
            return;
        }

        let engine = ArisEngine::new();
        let document = engine
            .open_document(fixture.display().to_string(), None)
            .expect("open fixture");

        let bitmap = document.rasterize_page(0, 2.0).expect("rasterize");
        assert_eq!(
            bitmap.scale_used, 2.0,
            "a normal request must not be clamped"
        );
        assert_eq!(bitmap.width_px, 1190);
        assert_eq!(bitmap.height_px, 1684);

        let huge = document.rasterize_page(0, 8.0).expect("rasterize huge");
        assert!(huge.scale_used < 8.0, "deep zoom must be clamped");
        let pixels = u64::from(huge.width_px) * u64::from(huge.height_px);
        let budget = EngineConfig::default().full_page_max_pixels;
        assert!(
            pixels <= budget + budget / 100,
            "clamped page is {pixels} px"
        );
    }

    #[test]
    fn probing_the_fixture_reports_an_a4_page() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/text-page.pdf");
        if !fixture.exists() || !aris_reader_pdfium::is_available() {
            eprintln!("skipping: fixture or PDFium unavailable");
            return;
        }

        let engine = ArisEngine::new();
        let summary = engine
            .probe_document(fixture.display().to_string(), None)
            .expect("probe fixture");

        assert_eq!(summary.page_count, 1);
        assert_eq!(summary.first_page_width_pt, 595.0);
        assert_eq!(summary.first_page_height_pt, 842.0);
        assert_eq!(summary.rotation_degrees, 0);
        assert!(!summary.is_encrypted);
    }
}
