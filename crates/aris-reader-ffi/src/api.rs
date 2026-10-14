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
    DocumentBackend, ENGINE_VERSION, EngineConfig, ErrorCode, PageIndex, Point, RasterRequest,
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
    /// Kept so [`ArisDocument::reopen`] can hand a worker its own copy.
    password: Option<String>,
    /// Page sizes in points, filled on first layout request (a 2000-page manual would
    /// otherwise pay for every box at open time).
    page_sizes: Mutex<Option<Vec<(f64, f64)>>>,
    /// Last computed layout, keyed by the page gap it was built for.
    layout: Mutex<Option<(f64, Arc<DocumentLayout>)>>,
    /// Parsed reference list (scanning the tail pages is not free, and it never changes).
    references: Mutex<Option<Vec<ReferenceRecord>>>,
    /// Figure/table captions with their preview regions; same caching rule as `references`.
    figures: Mutex<Option<Vec<FigureRecord>>>,
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

    /// Opens an independent copy of this document for another worker thread.
    ///
    /// PDFium documents must not be shared between threads, so a raster pool keeps one
    /// copy per worker; [`ArisDocument::rasterize_tile`] on each copy then runs in
    /// parallel with the others.
    pub fn reopen(&self) -> Result<Arc<ArisDocument>, ArisFfiError> {
        let backend =
            PdfiumBackend::open(std::path::Path::new(&self.path), self.password.as_deref())?;
        Ok(Arc::new(ArisDocument {
            backend,
            path: self.path.clone(),
            password: self.password.clone(),
            page_sizes: Mutex::new(None),
            layout: Mutex::new(None),
            references: Mutex::new(None),
            figures: Mutex::new(None),
        }))
    }

    /// Rasterizes one tile of `page` at a discrete LOD (`scale = 2^lod`).
    ///
    /// Tile `(tile_x, tile_y)` covers device pixels `[x·S, y·S, S, S]` at that scale,
    /// which is `S / 2^lod` points of view space. Deep zoom costs more tiles rather than
    /// one unbounded bitmap — the memory clamp in [`ArisDocument::rasterize_page`] never
    /// applies here, because a tile is small by construction.
    pub fn rasterize_tile(
        &self,
        page: u32,
        lod: u8,
        tile_x: u32,
        tile_y: u32,
        tile_size: u32,
    ) -> Result<TileBitmap, ArisFfiError> {
        let max_lod = EngineConfig::default().max_lod;
        if lod > max_lod {
            return Err(ArisFfiError::InvalidArgument {
                message: format!("lod {lod} exceeds the maximum of {max_lod}"),
            });
        }
        if tile_size == 0 || tile_size > 4096 {
            return Err(ArisFfiError::InvalidArgument {
                message: format!("tile size {tile_size} is outside 1..=4096"),
            });
        }
        if page >= self.backend.page_count() {
            return Err(ArisFfiError::InvalidArgument {
                message: format!("page {page} is out of range"),
            });
        }

        let scale = 2f64.powi(i32::from(lod));
        let tile_size_pt = f64::from(tile_size) / scale;
        let request = RasterRequest::tile(
            PageIndex(page),
            scale,
            (
                f64::from(tile_x) * tile_size_pt,
                f64::from(tile_y) * tile_size_pt,
            ),
            (tile_size_pt, tile_size_pt),
        );

        let tile = self.backend.rasterize(&request)?;
        Ok(TileBitmap {
            page,
            lod,
            tile_x,
            tile_y,
            size_px: tile.size.width.round() as u32,
            pixels: tile.pixels,
        })
    }

    /// Rasterizes an arbitrary rectangle of `page`, in **view space** (points, top-left origin).
    ///
    /// The tile path proves PDFium's matrix rendering is exact; this exposes the same
    /// capability for a rectangle the caller chooses, which is what a figure or table preview
    /// needs (a citation points at a region, not at a whole page).
    pub fn rasterize_region(
        &self,
        page: u32,
        scale: f64,
        x_pt: f64,
        y_pt: f64,
        width_pt: f64,
        height_pt: f64,
    ) -> Result<PageBitmap, ArisFfiError> {
        if !(scale.is_finite() && scale > 0.0) {
            return Err(ArisFfiError::InvalidArgument {
                message: format!("scale must be positive and finite, got {scale}"),
            });
        }
        if page >= self.backend.page_count() {
            return Err(ArisFfiError::InvalidArgument {
                message: format!("page {page} is out of range"),
            });
        }
        if !(x_pt.is_finite()
            && y_pt.is_finite()
            && width_pt.is_finite()
            && height_pt.is_finite()
            && width_pt > 0.0
            && height_pt > 0.0
            && (x_pt + width_pt).is_finite()
            && (y_pt + height_pt).is_finite())
        {
            return Err(ArisFfiError::InvalidArgument {
                message: format!(
                    "region ({x_pt}, {y_pt}, {width_pt}×{height_pt}) must be finite with positive dimensions"
                ),
            });
        }
        let geometry = self.backend.page_info(PageIndex(page))?.geometry;
        let page_size = geometry.view_size(1.0);
        let tolerance = 1e-6;
        if x_pt < -tolerance
            || y_pt < -tolerance
            || x_pt + width_pt > page_size.width + tolerance
            || y_pt + height_pt > page_size.height + tolerance
        {
            return Err(ArisFfiError::InvalidArgument {
                message: format!(
                    "region ({x_pt}, {y_pt}, {width_pt}×{height_pt}) is outside the page bounds ({}, {})",
                    page_size.width, page_size.height
                ),
            });
        }

        // A caller can request an arbitrary region, so apply the same pixel and edge limits as a
        // whole-page bitmap before asking PDFium to allocate it.
        let scale = clamp_scale((width_pt, height_pt), scale);
        if !(scale.is_finite() && scale > 0.0 && (scale as f32) > 0.0) {
            return Err(ArisFfiError::InvalidArgument {
                message: "region dimensions exceed the renderer's supported range".to_string(),
            });
        }
        let request =
            RasterRequest::tile(PageIndex(page), scale, (x_pt, y_pt), (width_pt, height_pt));
        let tile = self.backend.rasterize(&request)?;

        Ok(PageBitmap {
            width_px: tile.size.width.round() as u32,
            height_px: tile.size.height.round() as u32,
            stride: tile.stride as u32,
            width_pt,
            height_pt,
            scale_used: scale,
            pixels: tile.pixels,
        })
    }

    /// Extracts the text layer of `page`.
    ///
    /// Character boxes come back in **view space** (points, top-left origin), which is what
    /// hit-testing needs, so the shell never touches page space. The order is the engine's
    /// character order, not necessarily visual reading order (see `docs/03-rendering.md`).
    pub fn text_page(&self, page: u32) -> Result<TextPage, ArisFfiError> {
        let raw = self.backend.raw_text_page(PageIndex(page))?;
        let geometry = self.backend.page_info(PageIndex(page))?.geometry;

        let chars = raw
            .chars
            .iter()
            .map(|character| {
                // Page boxes use a bottom-left origin, so the glyph's *top* edge is what
                // maps to the view-space y after the single Y-flip.
                let top_left = Point::new(
                    character.rect.origin.x,
                    character.rect.origin.y + character.rect.size.height,
                );
                // `page_to_view(1.0)` is the page→view transform at 100%: character boxes are
                // reported in content points, and the canvas applies the zoom itself.
                let view = geometry.page_to_view(1.0).apply(top_left);
                TextChar {
                    unicode: character.unicode,
                    x_pt: view.x,
                    y_pt: view.y,
                    width_pt: character.rect.size.width,
                    height_pt: character.rect.size.height,
                }
            })
            .collect();

        Ok(TextPage {
            page,
            chars,
            text: raw.text,
            has_unicode_map_error: raw.has_unicode_map_error,
        })
    }

    /// Searches every page for `pattern` (ASCII-case-insensitive).
    ///
    /// Returns at most `limit` hits in reading order. A hit is a **character range** into
    /// the page's text layer, which is exactly what the shell's selection and highlighting
    /// already address, so showing a hit needs no new machinery.
    pub fn search(&self, pattern: String, limit: u32) -> Result<Vec<SearchHit>, ArisFfiError> {
        if pattern.trim().is_empty() {
            return Ok(Vec::new());
        }

        let mut hits = Vec::new();
        let page_count = self.backend.page_count();
        for page in 0..page_count {
            let raw = self.backend.raw_text_page(PageIndex(page))?;
            let haystack = text_of(&raw);
            for hit in aris_reader_text::find_all(&haystack, &pattern) {
                if hits.len() >= limit as usize {
                    return Ok(hits);
                }
                let snippet: String = haystack
                    .chars()
                    .skip(hit.start.saturating_sub(24))
                    .take((hit.end - hit.start) + 48)
                    .collect();
                hits.push(SearchHit {
                    page,
                    start: hit.start as u32,
                    end: hit.end as u32,
                    snippet,
                });
            }
        }
        Ok(hits)
    }

    /// Citations in the body text of `page`, boxed in view space.
    pub fn citations(&self, page: u32) -> Result<Vec<CitationRecord>, ArisFfiError> {
        let raw = self.backend.raw_text_page(PageIndex(page))?;
        let transform = self
            .backend
            .page_info(PageIndex(page))?
            .geometry
            .page_to_view(1.0);

        Ok(aris_reader_text::find_citations(&raw)
            .into_iter()
            .map(|citation| {
                let top_left = Point::new(
                    citation.rect.origin.x,
                    citation.rect.origin.y + citation.rect.size.height,
                );
                let view = transform.apply(top_left);
                CitationRecord {
                    page,
                    text: citation.text,
                    labels: citation.labels,
                    x_pt: view.x,
                    y_pt: view.y,
                    width_pt: citation.rect.size.width,
                    height_pt: citation.rect.size.height,
                }
            })
            .collect())
    }

    /// `Figure N` / `Fig. N` / `Table N` / `Algorithm N` references in the body text of `page`,
    /// boxed in view space.
    ///
    /// These are the click targets: `kind` + `label` are the key into
    /// [`ArisDocument::figures`], which carries the region to preview, and the box is where the
    /// pointer has to be. The caption's own label is not among them (it is already on screen);
    /// see `aris_reader_text::find_caption_mentions`.
    ///
    /// Not cached, for the same reason as [`ArisDocument::citations`]: it reads one page.
    pub fn caption_mentions(&self, page: u32) -> Result<Vec<CaptionMentionRecord>, ArisFfiError> {
        let raw = self.backend.raw_text_page(PageIndex(page))?;
        let transform = self
            .backend
            .page_info(PageIndex(page))?
            .geometry
            .page_to_view(1.0);

        Ok(aris_reader_text::find_caption_mentions(&raw)
            .into_iter()
            .map(|mention| {
                // Page boxes use a bottom-left origin, so the mention's top edge is its y.
                let top_left = Point::new(mention.rect.origin.x, mention.rect.max_y());
                let view = transform.apply(top_left);
                CaptionMentionRecord {
                    page,
                    kind: mention.kind,
                    label: mention.label,
                    start: mention.start as u32,
                    end: mention.end as u32,
                    x_pt: view.x,
                    y_pt: view.y,
                    width_pt: mention.rect.size.width,
                    height_pt: mention.rect.size.height,
                }
            })
            .collect())
    }

    /// The document's reference list, parsed once and cached.
    ///
    /// This is what makes a citation work **without** a link annotation: the shell resolves
    /// `[12]` to an entry and previews the entry's own rectangle.
    pub fn references(&self) -> Result<Vec<ReferenceRecord>, ArisFfiError> {
        if let Ok(cache) = self.references.lock()
            && let Some(cached) = cache.as_ref()
        {
            return Ok(cached.clone());
        }

        // Scanning from the front with a cap, rather than only the tail: real papers put the
        // list anywhere from a third of the way in (with appendices after it) to the very end.
        // `find_references` stops as soon as the list ends, so the cost is bounded by the list's
        // position, and the cap keeps a 2000-page manual from being read page by page.
        let total = self.backend.page_count();
        let scan_end = total.min(120);
        let mut pages = Vec::new();
        for index in 0..scan_end {
            if let Ok(text) = self.backend.raw_text_page(PageIndex(index)) {
                pages.push((index, text));
            }
        }

        // Ground-truth pass: a paper that links its citations into the bibliography is telling us
        // exactly where each entry starts, and those landings beat any numbering rule. Collect
        // them first, then let the shared locator decide page by page.
        let mut landings: std::collections::BTreeMap<u32, Vec<f64>> =
            std::collections::BTreeMap::new();
        if let Some(first_list_page) =
            aris_reader_text::find_references(pages.iter().map(|(page, text)| (*page, text)), 2000)
                .iter()
                .map(|entry| entry.page)
                .min()
        {
            // Only the body can point into the list, so there is no need to scan past it.
            for body_page in 0..first_list_page {
                let Ok(links) = self.backend.link_targets(PageIndex(body_page)) else {
                    continue;
                };
                for link in links {
                    if let (Some(target), Some(top)) = (link.page, link.dest_top_y)
                        && target.get() >= first_list_page
                    {
                        landings.entry(target.get()).or_default().push(top);
                    }
                }
            }
        }

        let entries = aris_reader_text::find_references_with_landings(&pages, &landings, 2000);

        let mut records = Vec::with_capacity(entries.len());
        for entry in entries {
            // The entry's box comes from the character boxes of its own range, so the preview
            // can show exactly the entry rather than a whole page.
            let Ok(text) = self.backend.raw_text_page(PageIndex(entry.page)) else {
                continue;
            };
            let slice =
                &text.chars[entry.start.min(text.chars.len())..entry.end.min(text.chars.len())];
            let Some(rect) = union_of_char_boxes(slice) else {
                continue;
            };
            let transform = self
                .backend
                .page_info(PageIndex(entry.page))?
                .geometry
                .page_to_view(1.0);
            let top_left = Point::new(rect.origin.x, rect.origin.y + rect.size.height);
            let view = transform.apply(top_left);

            records.push(ReferenceRecord {
                label: entry.label,
                text: entry.text,
                page: entry.page,
                x_pt: view.x,
                y_pt: view.y,
                width_pt: rect.size.width,
                height_pt: rect.size.height,
            });
        }

        if let Ok(mut cache) = self.references.lock() {
            *cache = Some(records.clone());
        }
        Ok(records)
    }

    /// Resolves every label of a citation against the reference list.
    ///
    /// A citation routinely names several works at once — `[1,2]`, `(He et al. 2024; Kim 2023)`
    /// — and the reader expects all of them, so the plural form exists: the shell asks once for
    /// the whole group instead of resolving label by label and re-implementing the matching
    /// conventions (exact label match, then position for a numeric citation against an
    /// unnumbered list) on the Swift side. Entries come back in label order and are
    /// de-duplicated by `(label, page)`. An empty vector means nothing in the group could be
    /// resolved, which is an ordinary outcome for the caller to report, not an error.
    pub fn resolve_citations(
        &self,
        labels: Vec<String>,
    ) -> Result<Vec<ReferenceRecord>, ArisFfiError> {
        let references = self.references()?;
        let parsed: Vec<aris_reader_text::ReferenceEntry> = references
            .iter()
            .map(|record| aris_reader_text::ReferenceEntry {
                label: record.label.clone(),
                text: record.text.clone(),
                page: record.page,
                start: 0,
                end: 0,
            })
            .collect();

        Ok(aris_reader_text::resolve_references(&labels, &parsed)
            .into_iter()
            .filter_map(|entry| {
                // Resolution ran against `parsed`, whose entries mirror `references` one to
                // one; `(label, page)` is also the key the resolver de-duplicates by, so it
                // identifies the record to hand back.
                references
                    .iter()
                    .find(|record| record.label == entry.label && record.page == entry.page)
                    .cloned()
            })
            .collect())
    }

    /// Figure, table, and algorithm captions across the document, each with the region to preview.
    ///
    /// This is what makes a `Figure 3` in the body work **without** a link annotation: the shell
    /// resolves the mention's `kind` + `label` here and previews the record's own box. Cached
    /// like [`ArisDocument::references`], and for the same reason — the caption set cannot change
    /// while the document is open.
    ///
    /// Unlike the reference scan there is nothing to stop early on: a figure index is wanted for
    /// the whole readable body, so the scan is a flat cap of the first 120 pages (the cap that
    /// `references` and the CLI already use for a 2000-page manual).
    ///
    /// The box is the region `aris_reader_text::caption_region` derives — the caption plus its
    /// nearby image object for raster figures, or the full page when the artwork cannot be bounded
    /// reliably (vector figures, tables, and algorithms) — converted to **view space**, so it can
    /// be handed straight to [`ArisDocument::rasterize_region`].
    pub fn figures(&self) -> Result<Vec<FigureRecord>, ArisFfiError> {
        if let Ok(cache) = self.figures.lock()
            && let Some(cached) = cache.as_ref()
        {
            return Ok(cached.clone());
        }

        let total = self.backend.page_count();
        let scan_end = total.min(120);
        let mut records = Vec::new();
        for index in 0..scan_end {
            let Ok(text) = self.backend.raw_text_page(PageIndex(index)) else {
                continue;
            };
            let Ok(info) = self.backend.page_info(PageIndex(index)) else {
                continue;
            };
            // Images are a best-effort input: a caption with no image object still previews its
            // own box, so a page whose objects cannot be read is not a page with no figures.
            let (images, _rule_count) = self
                .backend
                .page_object_summary(PageIndex(index))
                .unwrap_or_default();
            // Regions are derived in page space and clamped to the full visible CropBox; its
            // origin can be non-zero. Transforming all four corners below also handles /Rotate.
            let page_bounds = info.geometry.crop_box;

            for caption in aris_reader_text::find_captions(&text) {
                let region = aris_reader_text::caption_region(&caption, &images, page_bounds);
                let view = page_region_to_view(region, info.geometry);
                records.push(FigureRecord {
                    kind: caption.kind,
                    label: caption.label,
                    page: index,
                    caption_text: caption.text,
                    x_pt: view.origin.x,
                    y_pt: view.origin.y,
                    width_pt: view.size.width,
                    height_pt: view.size.height,
                });
            }
        }

        if let Ok(mut cache) = self.figures.lock() {
            *cache = Some(records.clone());
        }
        Ok(records)
    }

    /// Links on `page`, in **view space** (points, top-left origin).
    ///
    /// Only actionable links come back: a page to jump to, a URL to open, or both.
    pub fn links(&self, page: u32) -> Result<Vec<LinkRecord>, ArisFfiError> {
        let geometry = self.backend.page_info(PageIndex(page))?.geometry;

        Ok(self
            .backend
            .link_targets(PageIndex(page))?
            .into_iter()
            .map(|link| {
                let view = page_region_to_view(link.rect, geometry);
                // The destination region lives on the *target* page, so it needs that page's
                // full transform, including its rotation and CropBox origin.
                let region = link.dest_rect.and_then(|rect| {
                    let target = link.page?;
                    let target_geometry = self.backend.page_info(target).ok()?.geometry;
                    let view = page_region_to_view(rect, target_geometry);
                    Some(LinkRegion {
                        x_pt: view.origin.x,
                        y_pt: view.origin.y,
                        width_pt: view.size.width,
                        height_pt: view.size.height,
                    })
                });

                LinkRecord {
                    x_pt: view.origin.x,
                    y_pt: view.origin.y,
                    width_pt: view.size.width,
                    height_pt: view.size.height,
                    uri: link.uri,
                    page: link.page.map(|page| page.get()),
                    region,
                }
            })
            .collect())
    }

    /// Document outline, flattened depth-first with a depth per entry.
    ///
    /// Flat is what a sidebar list wants; nesting is carried by `depth` instead of nested
    /// records, which keeps the FFI surface small.
    pub fn outline(&self) -> Result<Vec<OutlineEntry>, ArisFfiError> {
        let mut entries = Vec::new();
        flatten_outline(&self.backend.outline()?, 0, &mut entries);
        Ok(entries)
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

/// One link: a clickable box plus where it leads.
#[derive(Debug, Clone, uniffi::Record)]
pub struct LinkRecord {
    pub x_pt: f64,
    pub y_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
    /// External URL, when the link is a URI action.
    pub uri: Option<String>,
    /// Internal target page (0-based), when the link is a local destination.
    pub page: Option<u32>,
    /// Region of the target page the citation points at, when the destination is a `/FitR`.
    pub region: Option<LinkRegion>,
}

/// A rectangle on a page, in view space (points, top-left origin).
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct LinkRegion {
    pub x_pt: f64,
    pub y_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
}

/// One outline entry.
#[derive(Debug, Clone, uniffi::Record)]
pub struct OutlineEntry {
    pub title: String,
    /// Target page (0-based), when the destination resolves to one.
    pub page: Option<u32>,
    /// Nesting level; 0 is a top-level entry.
    pub depth: u32,
}

/// Flattens an outline tree into sidebar rows.
fn flatten_outline(
    nodes: &[aris_reader_core::OutlineNode],
    depth: u32,
    out: &mut Vec<OutlineEntry>,
) {
    for node in nodes {
        out.push(OutlineEntry {
            title: node.title.clone(),
            page: node.page.map(|page| page.get()),
            depth,
        });
        flatten_outline(&node.children, depth + 1, out);
    }
}

/// A citation in the body text, boxed in **view space**.
#[derive(Debug, Clone, uniffi::Record)]
pub struct CitationRecord {
    pub page: u32,
    /// As it appears, e.g. `[12,13]` or `He et al. 2024`.
    pub text: String,
    /// Reference labels it names (`12`, `13`, …), or the year for author-year styles.
    pub labels: Vec<String>,
    pub x_pt: f64,
    pub y_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
}

/// One entry of the reference list, with the box it occupies on its page.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ReferenceRecord {
    pub label: String,
    pub text: String,
    pub page: u32,
    pub x_pt: f64,
    pub y_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
}

/// A figure or table caption, with the region of its page a floating preview should show.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FigureRecord {
    /// `Figure`, `Table`, or `Algorithm`.
    pub kind: String,
    /// The number as printed: `3`, `12`.
    pub label: String,
    /// Page the caption lives on (0-based); the region is on that same page.
    pub page: u32,
    /// Caption text after the label, for the preview's title bar.
    pub caption_text: String,
    /// Region to preview, in **view space** (points, top-left origin).
    pub x_pt: f64,
    pub y_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
}

/// A `Figure N` / `Fig. N` / `Table N` / `Algorithm N` reference in the body text, boxed in **view space**.
///
/// `kind` + `label` resolve against [`FigureRecord`]s; `start`/`end` address the page's text
/// layer, the same range [`CitationRecord`] uses for a citation.
#[derive(Debug, Clone, uniffi::Record)]
pub struct CaptionMentionRecord {
    pub page: u32,
    pub kind: String,
    pub label: String,
    /// First character of the mention inside its page's text layer.
    pub start: u32,
    /// One past the last character of the mention.
    pub end: u32,
    pub x_pt: f64,
    pub y_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
}

/// One search hit: a character range in a page's text layer.
#[derive(Debug, Clone, uniffi::Record)]
pub struct SearchHit {
    pub page: u32,
    /// First matching character index.
    pub start: u32,
    /// One past the last matching character.
    pub end: u32,
    /// Surrounding text, for the results list.
    pub snippet: String,
}

/// Union of a run of character boxes (page space), or `None` when the run is empty.
fn union_of_char_boxes(chars: &[aris_reader_core::RawCharBox]) -> Option<aris_reader_core::Rect> {
    chars
        .iter()
        .fold(None::<aris_reader_core::Rect>, |accumulated, character| {
            let rect = character.rect;
            Some(match accumulated {
                None => rect,
                Some(current) => {
                    let min_x = current.origin.x.min(rect.origin.x);
                    let min_y = current.origin.y.min(rect.origin.y);
                    let max_x = (current.origin.x + current.size.width)
                        .max(rect.origin.x + rect.size.width);
                    let max_y = (current.origin.y + current.size.height)
                        .max(rect.origin.y + rect.size.height);
                    aris_reader_core::Rect::new(min_x, min_y, max_x - min_x, max_y - min_y)
                }
            })
        })
}

/// Converts a page-space rectangle to its view-space bounding rectangle, including page rotation.
fn page_region_to_view(
    region: aris_reader_core::Rect,
    geometry: aris_reader_core::PageGeometry,
) -> aris_reader_core::Rect {
    geometry.page_to_view(1.0).apply_rect(region)
}

/// The page text **rebuilt from the character sequence**, so indices address the same
/// array that selection uses (PDFium's own string may insert separators that have no
/// character box).
fn text_of(raw: &aris_reader_core::RawTextPage) -> String {
    raw.chars
        .iter()
        .map(|character| char::from_u32(character.unicode).unwrap_or(char::REPLACEMENT_CHARACTER))
        .collect()
}

/// One character of a page's text layer, boxed in **view space** (points, top-left origin).
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct TextChar {
    pub unicode: u32,
    pub x_pt: f64,
    pub y_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
}

/// A page's text layer plus the whole-page string.
#[derive(Debug, Clone, uniffi::Record)]
pub struct TextPage {
    pub page: u32,
    pub chars: Vec<TextChar>,
    /// Whole-page text, aligned with `chars` (line breaks as `\n`).
    pub text: String,
    /// The Unicode mapping has errors, which makes search unreliable.
    pub has_unicode_map_error: bool,
}

/// One rasterized tile of a page.
#[derive(Debug, Clone, uniffi::Record)]
pub struct TileBitmap {
    pub page: u32,
    /// Pyramid level; the raster scale is `2^lod`.
    pub lod: u8,
    pub tile_x: u32,
    pub tile_y: u32,
    /// Actual edge length in pixels (BGRA, tightly packed).
    pub size_px: u32,
    pub pixels: Vec<u8>,
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
            password,
            page_sizes: Mutex::new(None),
            layout: Mutex::new(None),
            references: Mutex::new(None),
            figures: Mutex::new(None),
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn figure_region_bounds_are_transformed_with_rotation_and_crop_origin() {
        let geometry = aris_reader_core::PageGeometry::new(
            aris_reader_core::Rect::new(0.0, 0.0, 500.0, 700.0),
            aris_reader_core::Rect::new(100.0, 200.0, 200.0, 300.0),
            aris_reader_core::Rotation::Clockwise90,
            1.0,
        );
        let region = aris_reader_core::Rect::new(120.0, 240.0, 30.0, 20.0);
        let view = page_region_to_view(region, geometry);
        assert!((view.size.width - 20.0).abs() < 1e-9);
        assert!((view.size.height - 30.0).abs() < 1e-9);
        assert!(view.origin.x >= 0.0 && view.origin.y >= 0.0);
        let page = geometry.view_size(1.0);
        assert!(view.max_x() <= page.width && view.max_y() <= page.height);
    }

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
    fn text_page_returns_boxes_inside_the_page() {
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

        let text = document.text_page(0).expect("text page");
        assert!(!text.text.is_empty(), "the fixture has a text layer");
        assert!(
            text.chars.len() > 50,
            "only {} characters",
            text.chars.len()
        );

        let size = document.page_size_pt(0).expect("page size");
        for character in &text.chars {
            assert!(
                character.x_pt >= -1.0 && character.x_pt <= size.width_pt + 1.0,
                "character x {} outside the page width {}",
                character.x_pt,
                size.width_pt
            );
            // View space: y grows downwards from the top edge.
            assert!(
                character.y_pt >= -1.0 && character.y_pt <= size.height_pt + 1.0,
                "character y {} outside the page height {}",
                character.y_pt,
                size.height_pt
            );
        }

        // The whole-page string is what search will run on, so it must be the same text.
        assert!(
            text.text.chars().count() >= text.chars.len() / 2,
            "the page string looks truncated: {} chars of text for {} boxes",
            text.text.chars().count(),
            text.chars.len()
        );
    }

    #[test]
    fn citations_and_references_are_reported_without_erroring() {
        // The fixtures carry neither citations nor a reference list, so the contract to pin
        // down is "absent means empty, not an error". Real-document behaviour is measured by
        // `aris-reader-cli cite` against the sample corpus.
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

        let citations = document.citations(0).expect("citations");
        assert!(citations.is_empty(), "the fixture has no citations");

        let references = document.references().expect("references");
        assert!(references.is_empty(), "the fixture has no reference list");

        let size = document.page_size_pt(0).expect("page size");
        for citation in document.citations(0).expect("citations") {
            assert!(citation.x_pt >= -1.0 && citation.x_pt <= size.width_pt + 1.0);
            assert!(citation.y_pt >= -1.0 && citation.y_pt <= size.height_pt + 1.0);
        }
    }

    #[test]
    fn figures_and_caption_mentions_are_reported_without_erroring() {
        // The fixture's text is placeholder prose with no captions, so the contract to pin down
        // is "absent means empty, not an error" plus well-formed boxes when there are any. The
        // real-document behaviour is measured by `aris-reader-cli figures` against the corpus.
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

        let figures = document.figures().expect("figures");
        assert!(figures.is_empty(), "the fixture has no figure captions");
        assert!(
            document.figures().expect("cached figures").is_empty(),
            "the cached read must agree with the first"
        );
        assert!(document.caption_mentions(0).expect("mentions").is_empty());

        // The same well-formedness rules as citations: a record that exists must be boxed
        // inside its page.
        let size = document.page_size_pt(0).expect("page size");
        for figure in &figures {
            assert_eq!(figure.page, 0);
            assert!(figure.x_pt >= -1.0 && figure.x_pt <= size.width_pt + 1.0);
            assert!(figure.y_pt >= -1.0 && figure.y_pt <= size.height_pt + 1.0);
            assert!(figure.width_pt > 0.0 && figure.height_pt > 0.0);
        }
        for mention in document.caption_mentions(0).expect("mentions") {
            assert!(mention.x_pt >= -1.0 && mention.x_pt <= size.width_pt + 1.0);
            assert!(mention.y_pt >= -1.0 && mention.y_pt <= size.height_pt + 1.0);
            assert!(mention.width_pt > 0.0 && mention.height_pt > 0.0);
            assert!(mention.end > mention.start);
        }
    }

    #[test]
    fn links_are_reported_in_view_space() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/multipage.pdf");
        if !fixture.exists() || !aris_reader_pdfium::is_available() {
            eprintln!("skipping: fixture or PDFium unavailable");
            return;
        }

        let engine = ArisEngine::new();
        let document = engine
            .open_document(fixture.display().to_string(), None)
            .expect("open fixture");

        // The fixture has no link annotations, so the contract is "empty, not an error" --
        // and every link that does exist must be actionable and inside the page.
        let size = document.page_size_pt(0).expect("page size");
        for page in 0..document.page_count() {
            for link in document.links(page).expect("links") {
                assert!(
                    link.uri.is_some() || link.page.is_some(),
                    "a link with no target should not be reported"
                );
                assert!(link.x_pt >= -1.0 && link.x_pt <= size.width_pt + 1.0);
                assert!(link.y_pt >= -1.0 && link.y_pt <= size.height_pt + 1.0);
                assert!(link.width_pt > 0.0 && link.height_pt > 0.0);
                if let Some(target) = link.page {
                    assert!(target < document.page_count());
                }
            }
        }
    }

    #[test]
    fn outline_is_reported_flat_with_depths() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/multipage.pdf");
        if !fixture.exists() || !aris_reader_pdfium::is_available() {
            eprintln!("skipping: fixture or PDFium unavailable");
            return;
        }

        let engine = ArisEngine::new();
        let document = engine
            .open_document(fixture.display().to_string(), None)
            .expect("open fixture");

        // The fixture has no bookmarks, so the contract to pin down is "no outline is an
        // empty list, not an error" plus well-formed entries when there are some.
        let entries = document.outline().expect("outline");
        for entry in &entries {
            assert!(!entry.title.is_empty() || entry.page.is_some());
            assert!(
                entry.depth < 32,
                "implausible nesting depth {}",
                entry.depth
            );
            if let Some(page) = entry.page {
                assert!(page < document.page_count());
            }
        }
    }

    #[test]
    fn search_finds_text_across_pages() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/multipage.pdf");
        if !fixture.exists() || !aris_reader_pdfium::is_available() {
            eprintln!("skipping: fixture or PDFium unavailable");
            return;
        }

        let engine = ArisEngine::new();
        let document = engine
            .open_document(fixture.display().to_string(), None)
            .expect("open fixture");

        // Every page of this fixture carries "Page N of 3".
        let hits = document.search("page".to_string(), 50).expect("search");
        assert!(hits.len() >= 3, "only {} hits", hits.len());
        assert_eq!(hits[0].page, 0, "hits come back in reading order");
        assert!(
            hits.iter().any(|hit| hit.page == 2),
            "page 3 was not searched"
        );
        assert!(hits[0].end > hits[0].start);
        assert!(!hits[0].snippet.is_empty());

        // A pattern that cannot occur returns nothing rather than erroring.
        assert!(
            document
                .search("zzzzz".to_string(), 50)
                .expect("search")
                .is_empty()
        );
        assert!(
            document
                .search("   ".to_string(), 50)
                .expect("blank")
                .is_empty()
        );
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

        let region = document
            .rasterize_region(0, 1000.0, 0.0, 0.0, 595.0, 842.0)
            .expect("rasterize bounded region");
        assert!(region.scale_used < 1000.0);
        assert_eq!((region.width_pt, region.height_pt), (595.0, 842.0));
        let region_pixels = u64::from(region.width_px) * u64::from(region.height_px);
        assert!(
            region_pixels <= budget + budget / 100,
            "clamped region is {region_pixels} px"
        );

        assert!(matches!(
            document.rasterize_region(0, 1.0, f64::NAN, 0.0, 10.0, 10.0),
            Err(ArisFfiError::InvalidArgument { .. })
        ));
        assert!(matches!(
            document.rasterize_region(0, 1.0, 0.0, 0.0, f64::INFINITY, 10.0),
            Err(ArisFfiError::InvalidArgument { .. })
        ));
        assert!(matches!(
            document.rasterize_region(0, 1.0, 0.0, 0.0, 10_000.0, 10.0),
            Err(ArisFfiError::InvalidArgument { .. })
        ));
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
