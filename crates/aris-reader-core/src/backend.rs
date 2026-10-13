//! PDF engine interface.
//!
//! # Neutral DTO principle
//!
//! `aris-reader-core` does **not** know about the rich models of `aris-reader-text` / `aris-reader-edit` (that would create a circular dependency).
//! The backend therefore returns **neutral DTOs**: [`RawTextPage`] (per-character boxes) and
//! the raw annotation-related queries on [`crate::backend::DocumentBackend`],
//! from which the upper-layer crates build the rich models:
//!
//! ```text
//! aris-reader-core  (trait + RawTextPage)  ←──  aris-reader-pdfium (implementation)
//!        ↑
//! aris-reader-text                             aris-reader-edit
//!   TextPage / selection / reading order       Annotation / transactions
//! ```
//!
//! This way, "swapping the engine" only requires implementing this trait, and "swapping the text model" does not affect the engine.

use crate::document::{LinkInfo, OutlineNode, PageIndex, PageInfo};
use crate::error::Result;
use crate::geometry::{Point, Rect};
use std::path::Path;

/// Pixel format of rasterization output.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RasterFormat {
    /// BGRA, 8 bits per channel, **premultiplied alpha** — maps directly to `wgpu::TextureFormat::Bgra8UnormSrgb`, zero conversion.
    Bgra8Premultiplied,
}

/// Rasterization options (corresponding to PDFium render flags).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RasterFlags {
    /// Whether to burn annotations into the bitmap. Default **false**: we draw annotations ourselves so they can be edited and toggled live.
    pub annotations: bool,
    /// Subpixel antialiasing (`FPDF_LCD_TEXT`); needs an A/B evaluation on Retina before deciding.
    pub lcd_text: bool,
    /// Limit the engine's internal image cache (`FPDF_RENDER_LIMITEDIMAGECACHE`) so it does not duplicate memory held by our own cache.
    pub limit_image_cache: bool,
}

impl Default for RasterFlags {
    fn default() -> Self {
        Self {
            annotations: false,
            lcd_text: false,
            limit_image_cache: true,
        }
    }
}

/// A single rasterization request.
///
/// `scale` is the scale relative to the PDF 72dpi baseline (LOD level n corresponds to `2^n`);
/// `region` is an area in Page Space (`None` = whole page).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RasterRequest {
    pub page: PageIndex,
    pub scale: f64,
    pub region: Option<Rect>,
    pub format: RasterFormat,
    pub flags: RasterFlags,
    /// Background color (RGBA, not premultiplied); the PDF page itself may be transparent.
    pub background: [u8; 4],
}

impl RasterRequest {
    /// A sub-rectangle of a page ("tile") in **view space** (points, top-left origin).
    ///
    /// Tiles are how deep zoom stays sharp and bounded: each one is rasterised on its own
    /// through PDFium's matrix path, so a 4× render costs 16 tiles of 1× work instead of
    /// one enormous bitmap.
    pub fn tile(page: PageIndex, scale: f64, origin: (f64, f64), size: (f64, f64)) -> Self {
        Self {
            region: Some(Rect::new(origin.0, origin.1, size.0, size.1)),
            ..Self::full_page(page, scale)
        }
    }

    pub fn full_page(page: PageIndex, scale: f64) -> Self {
        Self {
            page,
            scale,
            region: None,
            format: RasterFormat::Bgra8Premultiplied,
            flags: RasterFlags::default(),
            background: [0xFF, 0xFF, 0xFF, 0xFF],
        }
    }
}

/// Rasterization result.
#[derive(Clone, Debug, PartialEq)]
pub struct RasterTile {
    pub size: crate::geometry::Size,
    /// Row stride in bytes. **Must be provided by the producer**; do not assume it equals `width * 4`.
    pub stride: usize,
    pub pixels: Vec<u8>,
    pub format: RasterFormat,
}

impl RasterTile {
    pub fn byte_len(&self) -> usize {
        self.stride * self.size.height as usize
    }
}

/// Raw geometry of a single character (from `FPDFText_GetCharBox` and similar).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RawCharBox {
    /// Bounding box of the character in Page Space.
    pub rect: Rect,
    /// Character origin (left end of the baseline), used for precise selection anchoring.
    pub origin: Point,
    /// Unicode code point (PDFium returns UTF-16; normalized to a code point here).
    pub unicode: u32,
    /// Font size (Page Space units).
    pub font_size: f64,
    /// Text rotation angle (radians; 0 = horizontal).
    pub angle: f64,
}

/// Raw text layer of a single page.
///
/// **The order is the character order produced by the engine** (usually content stream order, which is not necessarily the visual reading order);
/// a reliable multi-column reading order requires `aris-reader-text` to infer it from the structure tree or geometric clustering
/// (see `docs/03-rendering.md` and `docs/06-ai.md`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct RawTextPage {
    pub page: PageIndex,
    pub chars: Vec<RawCharBox>,
    /// Whole-page text (aligned with `chars`; line breaks use `\n`).
    pub text: String,
    /// The engine reports the page text as "generated" (no real text layer; possibly inferred by OCR).
    pub is_generated: bool,
    /// The Unicode mapping contains errors (`FPDFText_HasUnicodeMapError`) — affects search reliability.
    pub has_unicode_map_error: bool,
}

/// PDF engine interface. See `aris-reader-pdfium` for an implementation (the first backend); a pure Rust backend may follow.
///
/// **Threading rules**: implementations must be `Send + Sync`, but PDFium itself is not thread-safe —
/// `aris-reader-pdfium` handles this with "one document copy per raster thread" while still exposing a `Sync`
/// interface to the outside (see `docs/02-architecture.md` §3).
pub trait DocumentBackend: Send + Sync {
    /// Page count.
    fn page_count(&self) -> u32;

    /// Geometry information for a single page.
    fn page_info(&self, page: PageIndex) -> Result<PageInfo>;

    /// Document outline (returns an empty vec when there is no outline).
    fn outline(&self) -> Result<Vec<OutlineNode>>;

    /// Link annotations of a page.
    fn links(&self, page: PageIndex) -> Result<Vec<LinkInfo>>;

    /// Raw text layer (built lazily and cached by the upper layer).
    fn raw_text_page(&self, page: PageIndex) -> Result<RawTextPage>;

    /// Rasterize (CPU, PDFium).
    fn rasterize(&self, request: &RasterRequest) -> Result<RasterTile>;

    /// Whether the document is encrypted (and has been unlocked with a password).
    fn is_encrypted(&self) -> bool;

    /// Whether the document has a tagged structure (determines the reading-order strategy).
    fn is_tagged(&self) -> bool;

    /// Save incrementally to a new file (M3: used after annotation/page operations).
    fn save_incremental(&self, target: &Path) -> Result<u64> {
        let _ = target;
        Err(crate::error::ArisError::not_implemented(
            "save_incremental (T3.7)",
        ))
    }
}
