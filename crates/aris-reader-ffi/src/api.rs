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

use crate::index_cache::{
    CacheRead, CachedReferences, ContentIdentity, IndexCacheFile, cache_path,
    disabled_by_environment, read_cache, write_cache,
};
use aris_reader_ai::MockProvider;
use aris_reader_ai::chat::{
    Action as AiAction, ChatPlan, ChatSettings, MergePart, MergePlanRequest, PageChar, PageText,
    PlanRequest, ReasoningEncoding, ReasoningMode, SelectionRange as AiSelectionRange,
    build_merge_plan, build_plan, inspect_base_url, validate_model,
};
use aris_reader_ai::openai::{
    CancellationToken, RunEvent, StreamDiagnostics, TokenUsage, preview_headers, run_plan,
};
use aris_reader_core::{
    AnnotationDrawing, DocumentBackend, ENGINE_VERSION, EngineConfig, ErrorCode, PageGeometry,
    PageIndex, Point, RasterRequest, RawAnnotationLine, Transform2D,
};
use aris_reader_metadata::{BibEntry, MetadataSource, RecognizedMetadata, recognize};
use aris_reader_pdfium::{
    PageOperation, PdfiumBackend, SaveMode, WriteAnnotation, WriteAnnotationKind,
    backend_description,
};
use aris_reader_session::{DocumentLayout, LayoutMode};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Pages the reference-list locator reads.
///
/// The locator compares several candidate runs across the pages it is given (a paper's own
/// bibliography, an appendix's independent one, a list continued under a second numbering), so it
/// needs those pages' text together; that is the one index component whose working set grows with
/// its window. It is deliberately kept at the historical 120 pages for a document longer than
/// that: the reference list of a real paper is near its body, and pages beyond this window are
/// still read once, for the citation index ([`ArisDocument::citations`]). The visible
/// consequence for a book whose bibliography is printed after page 120 is stated by
/// [`ArisDocument::references`]: the locator returns no entries, and citations are derived from
/// the page shapes alone. Captions have no such window; see [`ArisDocument::figures`].
const REFERENCE_SCAN_PAGES: u32 = 120;

/// Errors crossing the FFI boundary (they surface as Swift `throws`).
#[derive(Debug, uniffi::Error)]
pub enum ArisFfiError {
    /// The file could not be read or parsed.
    Document { message: String },
    /// No usable PDF backend (for example, PDFium could not be loaded).
    Backend { message: String },
    /// The caller passed something invalid.
    InvalidArgument { message: String },
    /// The AI layer could not build a plan or run a request.
    Ai { message: String },
}

impl std::fmt::Display for ArisFfiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Document { message } => write!(f, "document error: {message}"),
            Self::Backend { message } => write!(f, "backend error: {message}"),
            Self::InvalidArgument { message } => write!(f, "invalid argument: {message}"),
            Self::Ai { message } => write!(f, "AI error: {message}"),
        }
    }
}

impl From<aris_reader_ai::AiError> for ArisFfiError {
    fn from(error: aris_reader_ai::AiError) -> Self {
        Self::Ai {
            message: error.to_string(),
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

/// How the session lays pages out horizontally.
///
/// Separate from the older [`aris_reader_session::Layout`] command enum because only the two
/// modes the shell can actually draw cross the FFI boundary today. `Facing` means the book
/// convention: page 1 alone, then 2–3, 4–5, … with odd pages on the right.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ReaderLayout {
    Continuous,
    Facing,
}

impl ReaderLayout {
    fn session(self) -> LayoutMode {
        match self {
            Self::Continuous => LayoutMode::Continuous,
            Self::Facing => LayoutMode::Facing,
        }
    }
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

/// Where a metadata field came from, as the panel shows it.
///
/// `Absent` is the only correct source of an empty field: "no value" is not a guess.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum, serde::Serialize, serde::Deserialize)]
pub enum MetadataSourceKind {
    Absent,
    Xmp,
    Info,
    FirstPage,
    PageFurniture,
    Text,
    ArxivDerived,
    Edited,
}

/// One field with its value(s) and the source that produced them.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MetadataFieldRecord {
    pub values: Vec<String>,
    pub source: MetadataSourceKind,
    /// Stable code for logs and checks (`xmp`, `first-page`, …).
    pub source_code: String,
    /// Short human label (`XMP`, `page 1 guess`, …).
    pub source_label: String,
    /// `embedded`, `identified`, `guessed`, `edited`, or `none`.
    pub trust: String,
    /// Whether the panel must mark this value as a guess.
    pub guessed: bool,
}

/// The recognised metadata for one document, plus the BibTeX its values generate.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DocumentMetadataRecord {
    pub title: MetadataFieldRecord,
    pub authors: MetadataFieldRecord,
    pub venue: MetadataFieldRecord,
    pub year: MetadataFieldRecord,
    pub doi: MetadataFieldRecord,
    pub arxiv_id: MetadataFieldRecord,
    pub bibtex: String,
}

/// The values the shell sends back after the reader corrected a field.
///
/// Provenance is not part of the request: an edited value is the reader's, not the file's.
#[derive(Debug, Clone, uniffi::Record)]
pub struct MetadataDraftRecord {
    pub title: String,
    pub authors: Vec<String>,
    pub venue: String,
    pub year: String,
    pub doi: String,
    pub arxiv_id: String,
}

fn metadata_kind(source: Option<MetadataSource>) -> MetadataSourceKind {
    match source {
        None => MetadataSourceKind::Absent,
        Some(MetadataSource::Xmp) => MetadataSourceKind::Xmp,
        Some(MetadataSource::Info) => MetadataSourceKind::Info,
        Some(MetadataSource::FirstPage) => MetadataSourceKind::FirstPage,
        Some(MetadataSource::PageFurniture) => MetadataSourceKind::PageFurniture,
        Some(MetadataSource::Text) => MetadataSourceKind::Text,
        Some(MetadataSource::ArxivDerived) => MetadataSourceKind::ArxivDerived,
        Some(MetadataSource::Edited) => MetadataSourceKind::Edited,
    }
}

fn metadata_field(field: &aris_reader_metadata::MetadataField) -> MetadataFieldRecord {
    MetadataFieldRecord {
        values: field.values.clone(),
        source: metadata_kind(field.source),
        source_code: field.source_code().to_string(),
        source_label: field.source_label().to_string(),
        trust: field.trust().to_string(),
        guessed: field.is_guessed(),
    }
}

fn metadata_report(metadata: &RecognizedMetadata) -> DocumentMetadataRecord {
    DocumentMetadataRecord {
        title: metadata_field(&metadata.title),
        authors: metadata_field(&metadata.authors),
        venue: metadata_field(&metadata.venue),
        year: metadata_field(&metadata.year),
        doi: metadata_field(&metadata.doi),
        arxiv_id: metadata_field(&metadata.arxiv_id),
        bibtex: metadata.bibtex(),
    }
}

/// Generates the BibTeX entry for the values currently in the panel.
///
/// The same Rust function generates the preview, the clipboard payload and the `.bib` file,
/// so those three cannot disagree with each other.
#[uniffi::export]
pub fn generate_bibtex_entry(draft: MetadataDraftRecord) -> String {
    BibEntry {
        title: draft.title,
        authors: draft.authors,
        venue: draft.venue,
        year: draft.year,
        doi: draft.doi,
        arxiv_id: draft.arxiv_id,
    }
    .to_bibtex()
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
    /// Last computed layout, keyed by the mode and page gap it was built for.
    layout: Mutex<Option<(ReaderLayout, f64, Arc<DocumentLayout>)>>,
    /// Parsed reference list, with the citation style it implies (scanning the tail pages is
    /// not free, and neither ever changes while the document is open).
    ///
    /// `Arc` so [`ArisDocument::citations`] can borrow the style without cloning a hundred
    /// entries per page. The persistent index cache stores exactly these records.
    references: Mutex<Option<Arc<ReferenceCache>>>,
    /// Figure/table captions with their preview regions; same caching rule as `references`.
    figures: Mutex<Option<Vec<FigureRecord>>>,
    /// Annotations already stored in the PDF, in view space; same caching rule as `figures`.
    annotations: Mutex<Option<Vec<AnnotationRecord>>>,
    /// Recognised metadata; page one does not change while the document is open.
    metadata: Mutex<Option<DocumentMetadataRecord>>,
    /// Outline, flattened once. Cheap to store and part of the cached index, so a warm open does
    /// not touch the PDF's outline tree at all.
    outline: Mutex<Option<Vec<OutlineEntry>>>,
    /// Citation spans per page, in view space. Filled by the reference scan (which already has
    /// every page's text in hand) and from the cache; pages outside the scan window fall back to
    /// a one-page read. This is what makes a warm click independent of the PDF text layer.
    citations: Mutex<Option<std::collections::BTreeMap<u32, Vec<CitationRecord>>>>,
    /// State of the persistent index cache: whether it was looked up, what was found, and the
    /// timings/counters the checks and the measurement report.
    index: Mutex<IndexRuntime>,
    /// Set when [`ArisDocument::replace_with_annotations`] has replaced the file on disk. The
    /// in-memory PDFium document is the pre-replacement one, so every content read would be a
    /// stale answer; the shell reopens the file immediately and this makes a missed reopen a
    /// loud error instead of a quiet one.
    replaced: std::sync::atomic::AtomicBool,
    /// Plain text per page, extracted once for AI context building. Text cannot change while
    /// the document is open (the annotation writer replaces the file, and then the shell
    /// reopens it), so this cache has the document's lifetime.
    ai_text: Mutex<std::collections::HashMap<u32, (String, Vec<PageChar>)>>,
}

/// The parsed reference list together with the citation style it implies.
///
/// One cache rather than two: both are derived from the same scan of the document, and the
/// detector must judge a superscript run against exactly the list the resolver will answer from.
#[derive(Clone)]
struct ReferenceCache {
    records: Vec<ReferenceRecord>,
    style: aris_reader_text::CitationStyle,
}

/// What the persistent index cache lookup found when a document was first indexed.
///
/// Reported for checks and measurements (and visible in the app's stderr log), not shown in the
/// UI. `Hit` means no index component was derived from the PDF for this document instance.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IndexCacheOutcome {
    /// No index access has happened yet, so nothing was looked up.
    NotAttempted,
    /// A current-format cache matched the PDF's content identity.
    Hit,
    /// No cache file exists.
    Missing,
    /// A cache exists but was built from different bytes (or a different page count).
    Stale,
    /// The cache could not be parsed. A complete re-index may replace it.
    Corrupt,
    /// The cache has fields this build does not understand; it is preserved and ignored.
    Incompatible,
    /// The cache's format version is newer than this build; it is preserved and ignored.
    FutureVersion,
    /// The cache is disabled for this process (`ARIS_READER_INDEX_CACHE`).
    Disabled,
    /// The cache could not be read (permissions, I/O, oversize); it is preserved.
    Unreadable,
}

/// Counters and timings for one document's index cache.
///
/// All times are microseconds spent in the current process for the current document instance.
/// `derived_parts` is the number of index components built from the PDF (references, figures,
/// metadata, outline); a cache hit leaves it at zero, which is the check that a second open did
/// not reparse anything.
#[derive(Clone, Debug)]
pub struct IndexCacheReport {
    pub outcome: IndexCacheOutcome,
    pub cache_path: String,
    pub cache_bytes: u64,
    /// Time spent hashing the PDF and reading/validating the cache.
    pub validation_micros: u64,
    /// Index components derived from the PDF in this document instance.
    pub derived_parts: u32,
    /// Total time spent deriving those components.
    pub derived_micros: u64,
    /// SHA-256 of the PDF this document's cache is bound to; `None` when hashing was skipped.
    pub content_sha256: Option<String>,
    /// True after a read-only/future file was seen or a write failed: this document will not
    /// write to the cache path.
    pub write_disabled: bool,
    /// Last write failure, for diagnostics; `None` when no write was attempted or it succeeded.
    pub write_error: Option<String>,
}

/// Mutable cache bookkeeping, guarded by `ArisDocument::index`.
struct IndexRuntime {
    attempted: bool,
    outcome: IndexCacheOutcome,
    identity: Option<ContentIdentity>,
    cache_path: Option<PathBuf>,
    cache_bytes: u64,
    validation: Duration,
    derived_parts: u32,
    derived: Duration,
    write_disabled: bool,
    write_error: Option<String>,
}

impl Default for IndexRuntime {
    fn default() -> Self {
        Self {
            attempted: false,
            outcome: IndexCacheOutcome::NotAttempted,
            identity: None,
            cache_path: None,
            cache_bytes: 0,
            validation: Duration::ZERO,
            derived_parts: 0,
            derived: Duration::ZERO,
            write_disabled: false,
            write_error: None,
        }
    }
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
        self.rasterize_page_bitmap(page, scale, false)
    }

    /// Rasterizes `page` with the file's own annotations burned in, for a thumbnail.
    ///
    /// The same page, clamp and threading rules as [`ArisDocument::rasterize_page`]; the only
    /// difference is PDFium's `FPDF_ANNOT` flag. The canvas must keep using the plain method:
    /// it draws annotations itself, with live editing and the app's own sidecar marks. This one
    /// is for a small preview whose job is to show *where the marks are* — including marks the
    /// canvas does not model. It does not include the sidecar, which is not part of the PDF.
    pub fn rasterize_page_with_annotations(
        &self,
        page: u32,
        scale: f64,
    ) -> Result<PageBitmap, ArisFfiError> {
        self.rasterize_page_bitmap(page, scale, true)
    }

    fn rasterize_page_bitmap(
        &self,
        page: u32,
        scale: f64,
        annotations: bool,
    ) -> Result<PageBitmap, ArisFfiError> {
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

        let mut request = RasterRequest::full_page(PageIndex(page), scale);
        request.flags.annotations = annotations;
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
            annotations: Mutex::new(None),
            metadata: Mutex::new(None),
            outline: Mutex::new(None),
            citations: Mutex::new(None),
            index: Mutex::new(IndexRuntime::default()),
            replaced: std::sync::atomic::AtomicBool::new(false),
            ai_text: Mutex::new(std::collections::HashMap::new()),
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

        let chars: Vec<TextChar> = raw
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
    ///
    /// A page's citations are not a page-local question any more: a superscript numeral is only
    /// a citation when the document's bibliography carries its label, so this call depends on
    /// the document's reference list and its citation style. The first access builds that index
    /// (or loads it from the sidecar); the reference scan already holds the scanned pages' text,
    /// so it records each page's spans at the same time and reads the pages past its window for
    /// this purpose. A cached index therefore makes this call independent of the PDF text layer
    /// for every page of the document.
    ///
    /// Every page is in the index: the reference scan reads the whole document once and stores
    /// one record per page, so this call is a lookup for a page 800 as it is for page 8. The
    /// one-page read below remains as the fallback for a page the index could not read (and for
    /// documents opened before the index exists, where it is the first read). The result is
    /// produced by the same `find_citations_with` call with the same style either way.
    pub fn citations(&self, page: u32) -> Result<Vec<CitationRecord>, ArisFfiError> {
        self.ensure_index_loaded();

        // Superscript numerals are only reported when the document's own bibliography
        // corroborates them, which is why this reads the shared style rather than the page.
        let style = self.reference_cache()?.style.clone();
        if let Ok(cache) = self.citations.lock()
            && let Some(cached) = cache.as_ref().and_then(|pages| pages.get(&page))
        {
            return Ok(cached.clone());
        }

        let raw = self.backend.raw_text_page(PageIndex(page))?;
        let transform = self
            .backend
            .page_info(PageIndex(page))?
            .geometry
            .page_to_view(1.0);
        let records = citation_records(&raw, &style, page, transform);

        // Remember the page for repeated clicks even when it is outside the scan window. It is
        // not written back to the sidecar: the cache is complete for every page the scan saw,
        // and a late page is a one-page read, not a reason to rewrite the document index.
        if let Ok(mut cache) = self.citations.lock() {
            cache
                .get_or_insert_with(std::collections::BTreeMap::new)
                .insert(page, records.clone());
        }
        Ok(records)
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
        self.ensure_index_loaded();
        Ok(self.reference_cache()?.records.clone())
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
                // Only labels and pages matter for resolution; the record handed back below
                // carries the geometry the cache built.
                fragments: Vec::new(),
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
    /// the whole readable body, so every page is scanned. The scan keeps no page's text or
    /// geometry after the page is read — only the caption records themselves — so a 900-page
    /// document costs one page of working memory, not nine hundred.
    ///
    /// The box is the region `aris_reader_text::caption_region_from` derives, converted to **view
    /// space** so it can be handed straight to [`ArisDocument::rasterize_region`]: the caption
    /// plus the table grid for a `Table` whose borders are drawn, the caption plus its nearby
    /// image object for a raster figure, and the full page when neither can be bounded reliably
    /// (vector figures, `booktabs` tables with too few rules, algorithms).
    pub fn figures(&self) -> Result<Vec<FigureRecord>, ArisFfiError> {
        self.ensure_index_loaded();
        if let Ok(cache) = self.figures.lock()
            && let Some(cached) = cache.as_ref()
        {
            return Ok(cached.clone());
        }

        let started = Instant::now();
        let total = self.backend.page_count();
        let mut records = Vec::new();
        for index in 0..total {
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
            // A table has no object of its own; its grid is in the page's vector geometry, and
            // the text inside the cells is what confirms it. Both are best-effort for the same
            // reason the images are.
            let rules = self
                .backend
                .page_line_segments(PageIndex(index))
                .unwrap_or_default();
            let lines = aris_reader_text::lines_from(&text);
            let evidence = aris_reader_text::PageEvidence {
                images: &images,
                rules: &rules,
                lines: &lines,
            };
            // Regions are derived in page space and clamped to the full visible CropBox; its
            // origin can be non-zero. Transforming all four corners below also handles /Rotate.
            let page_bounds = info.geometry.crop_box;

            for caption in aris_reader_text::find_captions(&text) {
                let region = aris_reader_text::caption_region_from(&caption, evidence, page_bounds);
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
        self.note_derived(started.elapsed());
        self.maybe_write_index();
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
    /// records, which keeps the FFI surface small. Stored in the index cache like the rest of
    /// the derived data: a warm open does not read the outline tree.
    pub fn outline(&self) -> Result<Vec<OutlineEntry>, ArisFfiError> {
        self.ensure_index_loaded();
        if let Ok(cache) = self.outline.lock()
            && let Some(cached) = cache.as_ref()
        {
            return Ok(cached.clone());
        }

        let started = Instant::now();
        let mut entries = Vec::new();
        flatten_outline(&self.backend.outline()?, 0, &mut entries);
        if let Ok(mut cache) = self.outline.lock() {
            *cache = Some(entries.clone());
        }
        self.note_derived(started.elapsed());
        self.maybe_write_index();
        Ok(entries)
    }

    /// The document's recognised metadata, with the source of every field.
    ///
    /// The three sources are read once and cached: XMP, `/Info`, then page one's text layer
    /// for anything the file did not state. An empty field is returned empty with source
    /// `absent`; this call never invents a title, author, venue, year, DOI or arXiv id.
    ///
    /// The BibTeX string in the report is generated from exactly these values. After the
    /// reader edits a field, [`generate_bibtex_entry`] regenerates the entry from the draft.
    pub fn metadata(&self) -> Result<DocumentMetadataRecord, ArisFfiError> {
        self.ensure_index_loaded();
        if let Ok(cache) = self.metadata.lock()
            && let Some(cached) = cache.as_ref()
        {
            return Ok(cached.clone());
        }

        let started = Instant::now();
        let embedded = self.backend.embedded_metadata()?;
        let first_page = self.backend.raw_text_page(PageIndex(0)).ok();
        // The text boxes are in unrotated PDF user space; the footer band is measured there.
        let page_height = self
            .backend
            .page_info(PageIndex(0))
            .map(|info| info.geometry.crop_box.size.height)
            .unwrap_or(842.0);
        let recognized = recognize(&embedded, first_page.as_ref(), page_height);
        let report = metadata_report(&recognized);
        if let Ok(mut cache) = self.metadata.lock() {
            *cache = Some(report.clone());
        }
        self.note_derived(started.elapsed());
        self.maybe_write_index();
        Ok(report)
    }

    /// Annotations the document **already carries**, from every page, in **view space**.
    ///
    /// This is the other half of this application's annotation story: the sidecar holds what the
    /// reader wrote, and this reads what is in the file — a PDF marked up in Preview, or one
    /// somebody else annotated. Every page is scanned: a cap like the reference index's 120 pages
    /// would silently hide notes in the back matter, and an annotation-free page costs one page
    /// load and one count (measured 2026-10-15 on the generated 300-page fixture through
    /// `FPDF_LoadPage` + `FPDFPage_GetAnnotCount`: 6.7 ms for all 300, 22 µs per page — a one-off
    /// cost on the open path, cached below).
    ///
    /// Cached for the lifetime of the open document, like [`ArisDocument::figures`]: a PDF cannot
    /// change under us while it is open, and the canvas would otherwise re-scan on every rebuild.
    ///
    /// A page whose annotations cannot be read fails the whole call rather than quietly
    /// disappearing from the answer — "the file has no annotations" and "we could not read them"
    /// are different things, and the shell says so.
    pub fn annotations(&self) -> Result<Vec<AnnotationRecord>, ArisFfiError> {
        if self.replaced.load(std::sync::atomic::Ordering::Acquire) {
            return Err(ArisFfiError::Document {
                message: "the document was replaced on disk; reopen it before reading annotations"
                    .to_string(),
            });
        }
        if let Ok(cache) = self.annotations.lock()
            && let Some(cached) = cache.as_ref()
        {
            return Ok(cached.clone());
        }

        let mut records = Vec::new();
        let mut geometries: std::collections::HashMap<u32, aris_reader_core::PageGeometry> =
            std::collections::HashMap::new();

        for page in 0..self.backend.page_count() {
            let geometry = match geometries.get(&page) {
                Some(geometry) => *geometry,
                None => {
                    let geometry = self.backend.page_info(PageIndex(page))?.geometry;
                    geometries.insert(page, geometry);
                    geometry
                }
            };

            for annotation in self.backend.annotations(PageIndex(page))? {
                let view = page_region_to_view(annotation.rect, geometry);
                // Classified before the record is built: the answer travels with the annotation
                // rather than being re-derived by every consumer from `kind` and `visible`.
                let drawing = annotation.drawing();
                let quads = annotation
                    .quads
                    .into_iter()
                    .map(|quad| {
                        let view = page_region_to_view(quad, geometry);
                        AnnotationQuad {
                            x_pt: view.origin.x,
                            y_pt: view.origin.y,
                            width_pt: view.size.width,
                            height_pt: view.size.height,
                        }
                    })
                    .collect();
                let to_view = geometry.page_to_view(1.0);
                let ink_paths = annotation
                    .ink_paths
                    .iter()
                    .map(|path| {
                        path.iter()
                            .map(|point| {
                                let view = to_view.apply(*point);
                                AnnotationPoint {
                                    x_pt: view.x,
                                    y_pt: view.y,
                                }
                            })
                            .collect()
                    })
                    .collect();
                let (line_start, line_end) = match annotation.line {
                    Some(line) => {
                        let start = to_view.apply(line.start);
                        let end = to_view.apply(line.end);
                        (
                            Some(AnnotationPoint {
                                x_pt: start.x,
                                y_pt: start.y,
                            }),
                            Some(AnnotationPoint {
                                x_pt: end.x,
                                y_pt: end.y,
                            }),
                        )
                    }
                    None => (None, None),
                };
                let kind = if annotation.kind == aris_reader_core::RawAnnotationKind::Line
                    && annotation.line_arrow
                {
                    "arrow".to_string()
                } else {
                    annotation.kind.as_str().to_string()
                };

                records.push(AnnotationRecord {
                    page,
                    id: annotation.id,
                    parent_id: annotation.parent_id,
                    is_reply: annotation.is_reply,
                    kind,
                    x_pt: view.origin.x,
                    y_pt: view.origin.y,
                    width_pt: view.size.width,
                    height_pt: view.size.height,
                    quads,
                    ink_paths,
                    line_start,
                    line_end,
                    line_arrow: annotation.line_arrow,
                    border_width_pt: annotation.border_width,
                    color: annotation.color.map(|color| AnnotationColorRecord {
                        red: color.red,
                        green: color.green,
                        blue: color.blue,
                    }),
                    opacity: annotation.opacity,
                    blend: annotation.blend.as_str().to_string(),
                    contents: annotation.contents,
                    author: annotation.author,
                    modified: annotation.modified,
                    font_size_pt: annotation.font_size_pt,
                    alignment: annotation.alignment.as_str().to_string(),
                    drawing: drawing.as_str().to_string(),
                    skip_reason: match drawing {
                        AnnotationDrawing::Skipped(reason) => Some(reason.as_str().to_string()),
                        _ => None,
                    },
                    visible: annotation.visible,
                });
            }
        }

        if let Ok(mut cache) = self.annotations.lock() {
            *cache = Some(records.clone());
        }
        Ok(records)
    }

    /// The `/Rotate` of every page, in quarter turns (0–3).
    ///
    /// The shell reads this once when a page-edit session starts. "Reset to the file's original
    /// rotation" is a property of that snapshot: after a reorder the page has moved, and after a
    /// rotation the file no longer says what the original was.
    pub fn page_rotations(&self) -> Result<Vec<u32>, ArisFfiError> {
        let count = self.backend.page_count();
        let mut rotations = Vec::with_capacity(count as usize);
        for page in 0..count {
            let info = self.backend.page_info(PageIndex(page))?;
            rotations.push((info.geometry.rotation.degrees().rem_euclid(360) / 90) as u32);
        }
        Ok(rotations)
    }

    /// Applies a page operation to a **copy** of this document and writes it to `destination`.
    ///
    /// This object's file is never modified. The written file is verified to have the requested
    /// page count, rotations and page sizes before the final rename. `page_map[old] = Some(new)`
    /// lets the shell remap its sidecar annotations; `None` means the page was removed.
    pub fn apply_page_operation(
        &self,
        destination: String,
        operation: PageOperationRecord,
    ) -> Result<PageEditReport, ArisFfiError> {
        if self.replaced.load(std::sync::atomic::Ordering::Acquire) {
            return Err(ArisFfiError::Document {
                message: "the document was replaced on disk; reopen it before editing pages"
                    .to_string(),
            });
        }
        if self.backend.is_encrypted() {
            return Err(ArisFfiError::Document {
                message:
                    "this document is encrypted; page editing is not supported for encrypted files"
                        .to_string(),
            });
        }
        let operation = page_operation(operation);
        let report = aris_reader_pdfium::apply_page_operation(
            Path::new(&self.path),
            Path::new(&destination),
            &operation,
            self.password.as_deref(),
        )?;
        Ok(page_edit_report(report))
    }

    /// Extracts `pages` into a new PDF at `destination`; this document is not modified.
    pub fn extract_pages(
        &self,
        destination: String,
        pages: Vec<u32>,
    ) -> Result<PageEditReport, ArisFfiError> {
        if self.backend.is_encrypted() {
            return Err(ArisFfiError::Document {
                message:
                    "this document is encrypted; page editing is not supported for encrypted files"
                        .to_string(),
            });
        }
        let report = aris_reader_pdfium::extract_pages(
            Path::new(&self.path),
            Path::new(&destination),
            &pages,
            self.password.as_deref(),
        )?;
        Ok(page_edit_report(report))
    }

    /// Publishes the current page-edit revision as a new file, without touching the original.
    pub fn save_edited_copy(&self, destination: String) -> Result<PageEditReport, ArisFfiError> {
        let report = aris_reader_pdfium::publish_edited_copy(
            Path::new(&self.path),
            Path::new(&destination),
            self.backend.page_count(),
        )?;
        Ok(page_edit_report(report))
    }

    /// Replaces `original_path` with this page-edit revision.
    ///
    /// This is the explicitly destructive command. A byte-identical backup of `original_path` is
    /// written and verified first; the revision is written into a temporary file beside it,
    /// verified, and only then renamed over the original. The in-memory handle is marked stale so
    /// the shell must reopen the file rather than quietly reading the old page tree.
    pub fn replace_with_edited_pages(
        &self,
        original_path: String,
    ) -> Result<PageEditReport, ArisFfiError> {
        if self.backend.is_encrypted() {
            return Err(ArisFfiError::Document {
                message:
                    "this document is encrypted; page editing is not supported for encrypted files"
                        .to_string(),
            });
        }
        let report = aris_reader_pdfium::replace_original_with_edit(
            Path::new(&self.path),
            Path::new(&original_path),
            self.backend.page_count(),
        )?;
        self.replaced
            .store(true, std::sync::atomic::Ordering::Release);
        Ok(page_edit_report(report))
    }

    /// The name to offer when saving an annotated copy: `<name> (annotated).pdf`.
    pub fn suggested_copy_path(&self) -> String {
        aris_reader_pdfium::suggested_copy_path(Path::new(&self.path))
            .to_string_lossy()
            .into_owned()
    }

    /// Writes `annotations` into a **new PDF** at `destination`.
    ///
    /// The document that is open is not modified, and neither is its sidecar. `annotations`
    /// cross the boundary as view-space geometry at `zoom`; Rust converts it to page space with
    /// the page's own `/CropBox`, `/Rotate` and `/UserUnit`, so the same highlight saved at 100%
    /// and at 300% lands in the same PDF coordinates.
    ///
    /// The write is append-only: the destination begins with every byte of the source. It is
    /// written to a temporary file beside `destination`, flushed, reopened, verified annotation
    /// by annotation, and only then renamed into place. A failure leaves the source untouched.
    pub fn save_annotations_copy(
        &self,
        destination: String,
        annotations: Vec<WriteAnnotationRecord>,
        zoom: f64,
    ) -> Result<AnnotationSaveReport, ArisFfiError> {
        self.save_annotations_to(
            std::path::PathBuf::from(destination),
            annotations,
            zoom,
            SaveMode::Copy,
        )
    }

    /// Replaces the document that is open with a version carrying `annotations`.
    ///
    /// This is the explicit second choice, never the default. A byte-identical backup is written
    /// first to `<name>.lyra-backup-<unix>-<n>.<ext>`; if it cannot be written *and verified*,
    /// the save aborts before the original is touched. The replacement itself is the atomic
    /// rename of a verified temporary file, so a crash leaves the original readable.
    pub fn replace_with_annotations(
        &self,
        annotations: Vec<WriteAnnotationRecord>,
        zoom: f64,
    ) -> Result<AnnotationSaveReport, ArisFfiError> {
        self.save_annotations_to(
            std::path::PathBuf::from(&self.path),
            annotations,
            zoom,
            SaveMode::ReplaceOriginal,
        )
    }

    /// Whether a previous save of this document was interrupted.
    ///
    /// A save is only applied by the final rename, so a `<name>.lyra-save-*.tmp` file beside the
    /// document means the save never reached that point and the document is still the last good
    /// copy. The shell reports this on open; the next save removes the leftovers.
    pub fn interrupted_save_note(&self) -> Option<String> {
        aris_reader_pdfium::interrupted_save_note(Path::new(&self.path))
    }

    /// Total height of the scrolling content for the given page gap and layout.
    ///
    /// The three-argument `content_height_pt` below is the continuous mode this reader
    /// shipped before facing pages existed; it stays for callers that only know one layout.
    pub fn content_height_pt_for(&self, layout: ReaderLayout, gap_pt: f64) -> f64 {
        self.layout(layout, gap_pt).content_height_pt()
    }

    /// Total height of the scrolling content in continuous layout.
    pub fn content_height_pt(&self, gap_pt: f64) -> f64 {
        self.content_height_pt_for(ReaderLayout::Continuous, gap_pt)
    }

    /// Width of the widest page, or of the whole spread in facing layout.
    pub fn content_width_pt_for(&self, layout: ReaderLayout, gap_pt: f64) -> f64 {
        self.layout(layout, gap_pt).content_width_pt()
    }

    /// Width of the widest page in continuous layout.
    pub fn content_width_pt(&self, gap_pt: f64) -> f64 {
        self.content_width_pt_for(ReaderLayout::Continuous, gap_pt)
    }

    /// Top edge of a page in content space (for "go to page" and anchoring).
    pub fn page_top_pt_for(&self, page: u32, layout: ReaderLayout, gap_pt: f64) -> f64 {
        self.layout(layout, gap_pt).page_top_pt(page).unwrap_or(0.0)
    }

    /// Top edge of a page in continuous layout.
    pub fn page_top_pt(&self, page: u32, gap_pt: f64) -> f64 {
        self.page_top_pt_for(page, ReaderLayout::Continuous, gap_pt)
    }

    /// Page occupying the viewport top — the "current page" for the HUD.
    ///
    /// In facing layout a spread names its left page (see `DocumentLayout::page_at`).
    pub fn page_index_at_for(&self, scroll_y_pt: f64, layout: ReaderLayout, gap_pt: f64) -> u32 {
        self.layout(layout, gap_pt).page_at(scroll_y_pt)
    }

    /// Page occupying the viewport top in continuous layout.
    pub fn page_index_at(&self, scroll_y_pt: f64, gap_pt: f64) -> u32 {
        self.page_index_at_for(scroll_y_pt, ReaderLayout::Continuous, gap_pt)
    }

    /// Pages overlapping the viewport, in reading order.
    ///
    /// `margin_pt` widens the window so the shell can prefetch the next page.
    pub fn visible_pages_for(
        &self,
        scroll_y_pt: f64,
        viewport_height_pt: f64,
        layout: ReaderLayout,
        gap_pt: f64,
        margin_pt: f64,
    ) -> Vec<PagePlacementRecord> {
        self.layout(layout, gap_pt)
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

    /// Pages overlapping the viewport in continuous layout.
    pub fn visible_pages(
        &self,
        scroll_y_pt: f64,
        viewport_height_pt: f64,
        gap_pt: f64,
        margin_pt: f64,
    ) -> Vec<PagePlacementRecord> {
        self.visible_pages_for(
            scroll_y_pt,
            viewport_height_pt,
            ReaderLayout::Continuous,
            gap_pt,
            margin_pt,
        )
    }

    /// Build the context and request plan for the AI panel.
    ///
    /// This is local work: it reads the document's text layer, selects blocks, and assembles the
    /// prompts and JSON bodies. It does not read an API key and does not open a connection. The
    /// shell shows the returned plan and starts a request only after the reader presses Send.
    pub fn prepare_ai_plan(
        &self,
        request: AiPlanRequestRecord,
    ) -> Result<AiPlanRecord, ArisFfiError> {
        let action = match request.action {
            AiActionRecord::SummarizePage => AiAction::SummarizePage,
            AiActionRecord::SummarizeDocument => AiAction::SummarizeDocument,
            AiActionRecord::AskSelection => AiAction::AskSelection,
            AiActionRecord::TranslateSelection => AiAction::TranslateSelection,
        };
        let page_count = self.page_count();
        if page_count == 0 {
            return Err(ArisFfiError::Ai {
                message: "This document has no pages.".to_string(),
            });
        }
        if request.current_page >= page_count {
            return Err(ArisFfiError::Ai {
                message: format!(
                    "The current page {} is outside this document ({} pages).",
                    request.current_page + 1,
                    page_count
                ),
            });
        }
        let selection = request.selection.map(|selection| AiSelectionRange {
            page: selection.page,
            start: selection.start,
            end: selection.end,
        });
        if action.requires_selection() && selection.is_none() {
            return Err(ArisFfiError::Ai {
                message: "Select text first; there is no selection to send.".to_string(),
            });
        }
        if let Some(selection) = selection
            && selection.page >= page_count
        {
            return Err(ArisFfiError::Ai {
                message: format!(
                    "The selected page {} is outside this document.",
                    selection.page + 1
                ),
            });
        }

        // Translation only needs the selected page. Every other action can retrieve context
        // from the whole document, and a document summary needs all of it.
        let page_list: Vec<u32> = if action == AiAction::TranslateSelection {
            vec![selection.expect("checked above").page]
        } else {
            (0..page_count).collect()
        };
        let mut pages = Vec::with_capacity(page_list.len());
        for page in page_list {
            let (text, chars) = self.ai_page(page)?;
            pages.push(PageText { page, text, chars });
        }

        let temperature = request.temperature.and_then(|value| {
            if value.is_finite() {
                Some(value as f32)
            } else {
                None
            }
        });
        // A non-finite value becomes None, which would silently drop the field; keep the
        // validation honest by passing NaN through so the core rejects it.
        let temperature = if request.temperature.is_some_and(|value| !value.is_finite()) {
            Some(f32::NAN)
        } else {
            temperature
        };
        let reasoning_mode =
            ReasoningMode::from_wire(&request.reasoning_mode).ok_or_else(|| {
                ArisFfiError::InvalidArgument {
                    message: format!(
                        "Unknown reasoning mode {}. Use default, off, low, high or max.",
                        request.reasoning_mode
                    ),
                }
            })?;
        let reasoning_encoding = ReasoningEncoding::from_wire(&request.reasoning_encoding)
            .ok_or_else(|| ArisFfiError::InvalidArgument {
                message: format!(
                    "Unknown reasoning encoding {}. Use none, thinking, reasoning_effort, output_config or reasoning.effort.",
                    request.reasoning_encoding
                ),
            })?;
        let settings = ChatSettings {
            base_url: request.base_url,
            model: request.model,
            temperature,
            max_tokens: request.max_tokens,
            reasoning_mode,
            reasoning_encoding,
        };
        let document_title = Path::new(&self.path)
            .file_stem()
            .and_then(|stem| stem.to_str())
            .unwrap_or("Document")
            .to_string();
        let plan = build_plan(PlanRequest {
            action,
            document_title,
            page_count,
            current_page: request.current_page,
            selection,
            question: request.question,
            language: request.language,
            pages,
            settings,
        })?;
        Ok(ai_plan_record(plan))
    }
}

fn page_operation(record: PageOperationRecord) -> PageOperation {
    match record {
        PageOperationRecord::Rotate {
            pages,
            quarter_turns,
        } => PageOperation::Rotate {
            pages,
            quarter_turns,
        },
        PageOperationRecord::SetRotation {
            pages,
            quarter_turns,
        } => PageOperation::SetRotation {
            pages,
            quarter_turns,
        },
        PageOperationRecord::Delete { pages } => PageOperation::Delete { pages },
        PageOperationRecord::Move { pages, destination } => {
            PageOperation::Move { pages, destination }
        }
        PageOperationRecord::InsertBlank { index } => PageOperation::InsertBlank { index },
    }
}

fn page_edit_report(report: aris_reader_pdfium::PageOperationReport) -> PageEditReport {
    PageEditReport {
        destination_path: report.destination.to_string_lossy().into_owned(),
        page_count: report.page_count,
        page_map: report.page_map,
        rotations: report.rotations,
        inserted_page: report.inserted_page,
        backup_path: report
            .backup_path
            .map(|path| path.to_string_lossy().into_owned()),
        output_bytes: report.output_bytes,
        cleaned_temporary_files: u32::try_from(report.cleaned_temporaries).unwrap_or(u32::MAX),
    }
}

impl ArisDocument {
    /// Plain text and character boxes for one page, extracted once and kept for the
    /// document's lifetime. The boxes and the text come from the same `raw.chars` sequence, so
    /// the context builder's gutter rule and the canvas's selection indices agree.
    fn ai_page(&self, page: u32) -> Result<(String, Vec<PageChar>), ArisFfiError> {
        if page >= self.backend.page_count() {
            return Err(ArisFfiError::InvalidArgument {
                message: format!("page {page} is outside the document"),
            });
        }
        if let Some(cached) = self
            .ai_text
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(&page)
        {
            return Ok(cached.clone());
        }
        let raw = self.backend.raw_text_page(PageIndex(page))?;
        let geometry = self.backend.page_info(PageIndex(page))?.geometry;
        let chars: Vec<PageChar> = raw
            .chars
            .iter()
            .map(|character| {
                let top_left = Point::new(
                    character.rect.origin.x,
                    character.rect.origin.y + character.rect.size.height,
                );
                let view = geometry.page_to_view(1.0).apply(top_left);
                PageChar {
                    unicode: character.unicode,
                    x_pt: view.x,
                    y_pt: view.y,
                    width_pt: character.rect.size.width,
                    height_pt: character.rect.size.height,
                }
            })
            .collect();
        let text = text_of(&raw);
        self.ai_text
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .insert(page, (text.clone(), chars.clone()));
        Ok((text, chars))
    }

    fn save_annotations_to(
        &self,
        destination: std::path::PathBuf,
        annotations: Vec<WriteAnnotationRecord>,
        zoom: f64,
        mode: SaveMode,
    ) -> Result<AnnotationSaveReport, ArisFfiError> {
        if self.replaced.load(std::sync::atomic::Ordering::Acquire) {
            return Err(ArisFfiError::Document {
                message: "the document was replaced on disk; reopen it before saving again"
                    .to_string(),
            });
        }
        if self.backend.is_encrypted() {
            return Err(ArisFfiError::Document {
                message:
                    "this document is encrypted; saving annotations into it is not supported yet"
                        .to_string(),
            });
        }
        if !(zoom.is_finite() && zoom > 0.0 && zoom <= 64.0) {
            return Err(ArisFfiError::InvalidArgument {
                message: format!("zoom must be positive, finite and at most 64, got {zoom}"),
            });
        }
        let page_count = self.backend.page_count();
        let mut geometries: std::collections::HashMap<u32, PageGeometry> =
            std::collections::HashMap::new();
        let mut specs = Vec::with_capacity(annotations.len());
        for record in annotations {
            if record.page >= page_count {
                return Err(ArisFfiError::InvalidArgument {
                    message: format!(
                        "annotation {:?} names page {}, but the document has {page_count} page(s)",
                        record.id,
                        record.page + 1
                    ),
                });
            }
            let geometry = match geometries.get(&record.page) {
                Some(geometry) => *geometry,
                None => {
                    let geometry = self.backend.page_info(PageIndex(record.page))?.geometry;
                    geometries.insert(record.page, geometry);
                    geometry
                }
            };
            let inverse =
                geometry
                    .view_to_page(zoom)
                    .ok_or_else(|| ArisFfiError::InvalidArgument {
                        message: format!("page {} has no invertible geometry", record.page + 1),
                    })?;
            let quads = record
                .quads
                .iter()
                .map(|quad| view_box_to_page_rect(quad, inverse, &geometry))
                .collect::<Result<Vec<_>, _>>()?;
            let supplied_rect = view_box_to_page_rect(&record.rect, inverse, &geometry)?;
            let geometry_border = |id: &str, width: f64| -> Result<f64, ArisFfiError> {
                if !width.is_finite() || width <= 0.0 || width > 200.0 {
                    return Err(ArisFfiError::InvalidArgument {
                        message: format!("annotation {id:?} has a border width outside 0…200 pt"),
                    });
                }
                Ok(width)
            };
            let view_point = |point: &AnnotationPoint| -> Point {
                inverse.apply(Point::new(point.x_pt, point.y_pt))
            };
            let (kind, rect, quads, ink_paths, line, line_arrow, border_width) = match record.kind {
                AnnotationWriteKind::Note => (
                    WriteAnnotationKind::Text,
                    supplied_rect,
                    Vec::new(),
                    Vec::new(),
                    None,
                    false,
                    0.0,
                ),
                AnnotationWriteKind::Highlight | AnnotationWriteKind::Underline => {
                    if quads.is_empty() {
                        return Err(ArisFfiError::InvalidArgument {
                            message: format!("annotation {:?} has no quads to write", record.id),
                        });
                    }
                    let mut union = quads[0];
                    for quad in &quads[1..] {
                        union = union.union(*quad);
                    }
                    if !rects_close(union, supplied_rect) {
                        return Err(ArisFfiError::InvalidArgument {
                            message: format!(
                                "annotation {:?} has a rect that does not cover its quads",
                                record.id
                            ),
                        });
                    }
                    let kind = match record.kind {
                        AnnotationWriteKind::Highlight => WriteAnnotationKind::Highlight,
                        AnnotationWriteKind::Underline => WriteAnnotationKind::Underline,
                        _ => unreachable!("handled by the outer match"),
                    };
                    (kind, union, quads, Vec::new(), None, false, 0.0)
                }
                AnnotationWriteKind::Ink => {
                    if record.ink_paths.is_empty() {
                        return Err(ArisFfiError::InvalidArgument {
                            message: format!(
                                "ink annotation {:?} has no strokes to write",
                                record.id
                            ),
                        });
                    }
                    let border = geometry_border(&record.id, record.border_width_pt)?;
                    let paths: Vec<Vec<Point>> = record
                        .ink_paths
                        .iter()
                        .map(|path| path.iter().map(view_point).collect())
                        .collect();
                    (
                        WriteAnnotationKind::Ink,
                        supplied_rect,
                        Vec::new(),
                        paths,
                        None,
                        false,
                        border,
                    )
                }
                AnnotationWriteKind::Square | AnnotationWriteKind::Circle => {
                    let border = geometry_border(&record.id, record.border_width_pt)?;
                    let kind = match record.kind {
                        AnnotationWriteKind::Square => WriteAnnotationKind::Square,
                        AnnotationWriteKind::Circle => WriteAnnotationKind::Circle,
                        _ => unreachable!("handled by the outer match"),
                    };
                    (
                        kind,
                        supplied_rect,
                        Vec::new(),
                        Vec::new(),
                        None,
                        false,
                        border,
                    )
                }
                AnnotationWriteKind::Line => {
                    let border = geometry_border(&record.id, record.border_width_pt)?;
                    let (Some(start), Some(end)) = (record.line_start, record.line_end) else {
                        return Err(ArisFfiError::InvalidArgument {
                            message: format!(
                                "line annotation {:?} has no endpoints to write",
                                record.id
                            ),
                        });
                    };
                    (
                        WriteAnnotationKind::Line,
                        supplied_rect,
                        Vec::new(),
                        Vec::new(),
                        Some(RawAnnotationLine {
                            start: view_point(&start),
                            end: view_point(&end),
                        }),
                        record.line_arrow,
                        border,
                    )
                }
            };
            specs.push(WriteAnnotation {
                id: record.id,
                page: PageIndex(record.page),
                kind,
                rect,
                quads,
                ink_paths,
                line,
                line_arrow,
                border_width,
                color: [record.color.red, record.color.green, record.color.blue],
                opacity: record.opacity,
                contents: text_or_none(&record.contents),
                author: text_or_none(&record.author),
                modified: text_or_none(&record.modified),
            });
        }

        let report = aris_reader_pdfium::save_annotated_pdf(
            Path::new(&self.path),
            &destination,
            &specs,
            self.password.as_deref(),
            mode,
        )?;
        if mode == SaveMode::ReplaceOriginal {
            // The open backend still holds the pre-replacement in-memory document; the shell
            // reopens it after a replace, and every read before that reopen is refused rather
            // than answered from the old file.
            self.replaced
                .store(true, std::sync::atomic::Ordering::Release);
            if let Ok(mut cache) = self.annotations.lock() {
                *cache = None;
            }
        }
        Ok(AnnotationSaveReport {
            destination_path: report.destination.to_string_lossy().into_owned(),
            written_ids: report.written_ids,
            appended_bytes: report.appended_bytes,
            backup_path: report
                .backup_path
                .map(|path| path.to_string_lossy().into_owned()),
            preexisting_annotation_count: u32::try_from(report.preexisting_annotation_count)
                .unwrap_or(u32::MAX),
            cleaned_temporary_files: u32::try_from(report.cleaned_temporaries).unwrap_or(u32::MAX),
            source_bytes_preserved: report.source_bytes_preserved,
        })
    }

    /// Builds (and caches) the layout for `layout` and `gap_pt`.
    ///
    /// The cache key carries both: the same gap produces a different layout in facing mode,
    /// and a mode switch must not be answered from the previous mode's placements.
    fn layout(&self, layout: ReaderLayout, gap_pt: f64) -> Arc<DocumentLayout> {
        // Rust 2024 let-chains keep the lookups flat.
        if let Ok(cache) = self.layout.lock()
            && let Some((cached_layout, cached_gap, placements)) = cache.as_ref()
            && *cached_layout == layout
            && (*cached_gap - gap_pt).abs() < f64::EPSILON
        {
            return Arc::clone(placements);
        }

        let sizes = self.page_sizes();
        let placements = Arc::new(DocumentLayout::new_with_mode(
            sizes.iter().copied(),
            gap_pt,
            layout.session(),
        ));

        if let Ok(mut cache) = self.layout.lock() {
            *cache = Some((layout, gap_pt, Arc::clone(&placements)));
        }
        placements
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

    /// The reference list plus the citation style it implies, parsed once.
    ///
    /// [`ArisDocument::citations`] needs the same list: a superscript numeral is only a citation
    /// if the bibliography carries its label and the body does not bracket its citations. Both
    /// answers come from this one scan, so the detector can never disagree with the resolver
    /// about which labels exist.
    ///
    /// The scan reads every page's text and records each page's citation spans here as well.
    /// That is the same work a first click on a page would do, done once for the whole document
    /// and stored in the persistent cache: a citation on page 800 costs a map lookup, not a text
    /// extraction, and a 900-page book holds one citation record per span rather than one text
    /// layer per page. The reference-list locator itself still reads the first
    /// [`REFERENCE_SCAN_PAGES`] pages (see that constant).
    fn reference_cache(&self) -> Result<Arc<ReferenceCache>, ArisFfiError> {
        self.ensure_index_loaded();
        if let Ok(cache) = self.references.lock()
            && let Some(cached) = cache.as_ref()
        {
            return Ok(Arc::clone(cached));
        }

        let started = Instant::now();
        // Scanning from the front with a window, rather than only the tail: real papers put the
        // list anywhere from a third of the way in (with appendices after it) to the very end.
        // The window is what keeps a 2000-page manual's reference locator from holding every
        // page's text at once; the citation index still reads the remaining pages below.
        let total = self.backend.page_count();
        let scan_end = total.min(REFERENCE_SCAN_PAGES);
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
        let style = aris_reader_text::CitationStyle::for_document(&pages, &entries);

        let mut records = Vec::with_capacity(entries.len());
        // One page → view transform per page, not per fragment: a bibliography page holds dozens
        // of entries and each of their fragments asks for the same page again.
        let mut transforms: std::collections::HashMap<u32, aris_reader_core::Transform2D> =
            std::collections::HashMap::new();
        for entry in entries {
            // The entry's box comes from the character boxes of its own range, so the preview
            // can show exactly the entry rather than a whole page.
            let Ok(text) = self.backend.raw_text_page(PageIndex(entry.page)) else {
                continue;
            };
            if document_page_view(&self.backend, &mut transforms, entry.page).is_none() {
                continue;
            }
            // The single rectangle stays the box on the entry's own page. For one fragment that
            // is the fragment's own box, unchanged; when the entry is split, it is the union of
            // the pieces that page carries. A continuation on another page cannot be part of a
            // box here: the record names one page, and the preview rasterizes that page.
            let on_page = entry
                .fragments
                .iter()
                .filter(|fragment| fragment.page == entry.page)
                .map(|fragment| fragment.rect)
                .reduce(aris_reader_core::Rect::union);
            let rect = match on_page {
                Some(rect) => rect,
                // No fragment geometry (the text layer offered no boxes): fall back to the
                // character boxes of the entry's own range, as this used to read.
                None => {
                    let slice = &text.chars
                        [entry.start.min(text.chars.len())..entry.end.min(text.chars.len())];
                    let Some(rect) = union_of_char_boxes(slice) else {
                        continue;
                    };
                    rect
                }
            };
            let Some(view) = view_box(&self.backend, &mut transforms, entry.page, rect) else {
                continue;
            };

            let mut fragments = Vec::with_capacity(entry.fragments.len());
            for fragment in &entry.fragments {
                let Some(view) =
                    view_box(&self.backend, &mut transforms, fragment.page, fragment.rect)
                else {
                    continue;
                };
                fragments.push(ReferenceFragment {
                    page: fragment.page,
                    x_pt: view.x,
                    y_pt: view.y,
                    width_pt: fragment.rect.size.width,
                    height_pt: fragment.rect.size.height,
                });
            }

            records.push(ReferenceRecord {
                label: entry.label,
                text: entry.text,
                page: entry.page,
                x_pt: view.x,
                y_pt: view.y,
                width_pt: rect.size.width,
                height_pt: rect.size.height,
                fragments,
            });
        }

        // The body pages are in `pages` already; turn their text into click targets now, with
        // the same function and style a per-page call would use. Empty pages stay in the map so
        // a click on them is a lookup, not a second text extraction.
        let mut citations = std::collections::BTreeMap::new();
        for (index, text) in &pages {
            let Some(transform) = document_page_view(&self.backend, &mut transforms, *index) else {
                continue;
            };
            citations.insert(*index, citation_records(text, &style, *index, transform));
        }
        // The reference locator stops at its window, but the citation index does not: every page
        // past it is read once here, with the style the document's own list implied, and stored
        // in the same map (and in the cache). This is the difference between a 900-page book
        // indexing every page once and re-extracting a page on every click.
        for index in scan_end..total {
            let Ok(text) = self.backend.raw_text_page(PageIndex(index)) else {
                continue;
            };
            let Some(transform) = document_page_view(&self.backend, &mut transforms, index) else {
                continue;
            };
            citations.insert(index, citation_records(&text, &style, index, transform));
        }

        let cache = Arc::new(ReferenceCache { records, style });
        if let Ok(mut guard) = self.references.lock() {
            *guard = Some(Arc::clone(&cache));
        }
        if let Ok(mut guard) = self.citations.lock() {
            *guard = Some(citations);
        }
        self.note_derived(started.elapsed());
        self.maybe_write_index();
        Ok(cache)
    }
}

/// Index-cache bookkeeping and the persistent-index report.
///
/// These stay outside the `#[uniffi::export]` block: the shell does not need a new method, and
/// the report is a Rust-side check/measurement surface. Every accessor above funnels through
/// [`ArisDocument::ensure_index_loaded`], so the lookup happens exactly once per document.
impl ArisDocument {
    /// The cache state for this document, for checks and measurements.
    ///
    /// Calling this first performs the one cache lookup (hashing the PDF and reading the
    /// sidecar); it does not build any index component. `derived_parts` then says how much work
    /// the following accessors actually did.
    pub fn index_cache_report(&self) -> IndexCacheReport {
        self.ensure_index_loaded();
        if let Ok(runtime) = self.index.lock() {
            return IndexCacheReport {
                outcome: runtime.outcome,
                cache_path: runtime
                    .cache_path
                    .as_ref()
                    .map(|path| path.display().to_string())
                    .unwrap_or_default(),
                cache_bytes: runtime.cache_bytes,
                validation_micros: micros(runtime.validation),
                derived_parts: runtime.derived_parts,
                derived_micros: micros(runtime.derived),
                content_sha256: runtime
                    .identity
                    .as_ref()
                    .map(|identity| identity.sha256.clone()),
                write_disabled: runtime.write_disabled,
                write_error: runtime.write_error.clone(),
            };
        }
        IndexCacheReport {
            outcome: IndexCacheOutcome::NotAttempted,
            cache_path: String::new(),
            cache_bytes: 0,
            validation_micros: 0,
            derived_parts: 0,
            derived_micros: 0,
            content_sha256: None,
            write_disabled: true,
            write_error: Some("the index cache state is poisoned".to_string()),
        }
    }

    /// Looks the sidecar up once and, on a hit, fills every in-memory index component with it.
    ///
    /// Lazy by design: opening a document never hashes the file or reads the cache, so the page
    /// raster and the first paint do not wait for the index. The shell's background loaders are
    /// what call the accessors that reach this point.
    fn ensure_index_loaded(&self) {
        let mut runtime = match self.index.lock() {
            Ok(runtime) => runtime,
            Err(_) => return,
        };
        if runtime.attempted {
            return;
        }
        runtime.attempted = true;

        let path = cache_path(Path::new(&self.path));
        runtime.cache_path = Some(path.clone());
        if self.replaced.load(std::sync::atomic::Ordering::Acquire) {
            // The file on disk is no longer the file the backend parsed. A cache bound to
            // either set of bytes would be a guess; let the shell reopen first.
            runtime.outcome = IndexCacheOutcome::Unreadable;
            runtime.write_disabled = true;
            runtime.write_error = Some(
                "the document was replaced on disk before the index cache was read".to_string(),
            );
            return;
        }
        if disabled_by_environment() {
            runtime.outcome = IndexCacheOutcome::Disabled;
            runtime.write_disabled = true;
            return;
        }

        let started = Instant::now();
        let identity = match ContentIdentity::of(Path::new(&self.path)) {
            Ok(identity) => identity,
            Err(error) => {
                runtime.outcome = IndexCacheOutcome::Unreadable;
                runtime.write_disabled = true;
                runtime.write_error = Some(format!("could not hash the PDF: {error}"));
                runtime.validation = started.elapsed();
                return;
            }
        };
        runtime.cache_bytes = std::fs::metadata(&path)
            .map(|metadata| metadata.len())
            .unwrap_or(0);
        runtime.identity = Some(identity.clone());

        match read_cache(&path, &identity, self.backend.page_count()) {
            CacheRead::Hit(file) => {
                let IndexCacheFile {
                    outline,
                    references,
                    figures,
                    metadata,
                    citations,
                    ..
                } = *file;
                if let Ok(mut cache) = self.references.lock() {
                    *cache = Some(Arc::new(ReferenceCache {
                        records: references.records,
                        style: references.style,
                    }));
                }
                if let Ok(mut cache) = self.figures.lock() {
                    *cache = Some(figures);
                }
                if let Ok(mut cache) = self.metadata.lock() {
                    *cache = Some(metadata);
                }
                if let Ok(mut cache) = self.outline.lock() {
                    *cache = Some(outline);
                }
                if let Ok(mut cache) = self.citations.lock() {
                    *cache = Some(citations);
                }
                runtime.outcome = IndexCacheOutcome::Hit;
                runtime.validation = started.elapsed();
                eprintln!(
                    "aris-index: hit {} ({} bytes, sha256 {}…, validated in {:.1} ms)",
                    path.display(),
                    runtime.cache_bytes,
                    &identity.sha256[..identity.sha256.len().min(12)],
                    runtime.validation.as_secs_f64() * 1000.0,
                );
            }
            CacheRead::Stale => {
                runtime.outcome = IndexCacheOutcome::Stale;
                runtime.validation = started.elapsed();
                eprintln!(
                    "aris-index: stale cache (content changed), falling back to a full parse"
                );
            }
            CacheRead::Missing => {
                runtime.outcome = IndexCacheOutcome::Missing;
                runtime.validation = started.elapsed();
                eprintln!(
                    "aris-index: no cache (hashed in {:.1} ms), the index will be built",
                    runtime.validation.as_secs_f64() * 1000.0,
                );
            }
            CacheRead::Corrupt { detail } => {
                runtime.outcome = IndexCacheOutcome::Corrupt;
                runtime.validation = started.elapsed();
                eprintln!(
                    "aris-index: ignoring a corrupt cache ({detail}); the document will be parsed"
                );
            }
            CacheRead::Incompatible { detail } => {
                runtime.outcome = IndexCacheOutcome::Incompatible;
                runtime.write_disabled = true;
                runtime.validation = started.elapsed();
                eprintln!(
                    "aris-index: keeping an incompatible cache untouched ({detail}); using a full parse"
                );
            }
            CacheRead::FutureVersion { version } => {
                runtime.outcome = IndexCacheOutcome::FutureVersion;
                runtime.write_disabled = true;
                runtime.validation = started.elapsed();
                eprintln!(
                    "aris-index: cache format {version} is newer than this build (format {}); preserving it and using a full parse",
                    crate::index_cache::FORMAT_VERSION,
                );
            }
            CacheRead::Unreadable { detail } => {
                runtime.outcome = IndexCacheOutcome::Unreadable;
                runtime.write_disabled = true;
                runtime.validation = started.elapsed();
                eprintln!(
                    "aris-index: cannot read the cache ({detail}); using a full parse and preserving it"
                );
            }
        }
    }

    /// Writes the complete index once, the first time all four components are available.
    ///
    /// A partial index is never persisted: a cache without, say, its figures would make the next
    /// open return an empty figure set until the missing part was rebuilt, and a cache that can
    /// answer only half a question is exactly the silent-wrong-answer failure this task exists to
    /// prevent. If the write fails, the document keeps its in-memory index; the only cost is that
    /// the next open parses again.
    fn maybe_write_index(&self) {
        let mut runtime = match self.index.lock() {
            Ok(runtime) => runtime,
            Err(_) => return,
        };
        if self.replaced.load(std::sync::atomic::Ordering::Acquire) {
            return;
        }
        if !runtime.attempted
            || runtime.write_disabled
            || matches!(
                runtime.outcome,
                IndexCacheOutcome::Hit
                    | IndexCacheOutcome::Disabled
                    | IndexCacheOutcome::FutureVersion
                    | IndexCacheOutcome::Incompatible
                    | IndexCacheOutcome::Unreadable
            )
        {
            return;
        }
        let Some(path) = runtime.cache_path.clone() else {
            return;
        };
        let Some(identity) = runtime.identity.clone() else {
            return;
        };
        let Some(references) = self
            .references
            .lock()
            .ok()
            .and_then(|cache| cache.as_ref().cloned())
        else {
            return;
        };
        let Some(figures) = self.figures.lock().ok().and_then(|cache| cache.clone()) else {
            return;
        };
        let Some(metadata) = self.metadata.lock().ok().and_then(|cache| cache.clone()) else {
            return;
        };
        let Some(outline) = self.outline.lock().ok().and_then(|cache| cache.clone()) else {
            return;
        };
        let citations = self
            .citations
            .lock()
            .ok()
            .and_then(|cache| cache.clone())
            .unwrap_or_default();

        let file = IndexCacheFile {
            kind: crate::index_cache::KIND.to_string(),
            format_version: crate::index_cache::FORMAT_VERSION,
            engine_version: ENGINE_VERSION.to_string(),
            content: identity,
            page_count: self.backend.page_count(),
            outline,
            references: CachedReferences {
                style: references.style.clone(),
                records: references.records.clone(),
            },
            figures,
            metadata,
            citations,
        };
        let started = Instant::now();
        match write_cache(&path, &file) {
            Ok(bytes) => {
                runtime.cache_bytes = bytes;
                eprintln!(
                    "aris-index: wrote {} ({} bytes, {:.1} ms)",
                    path.display(),
                    bytes,
                    started.elapsed().as_secs_f64() * 1000.0,
                );
            }
            Err(error) => {
                runtime.write_disabled = true;
                runtime.write_error = Some(error.to_string());
                eprintln!(
                    "aris-index: cache not writable beside the PDF ({error}); continuing with the in-memory index"
                );
            }
        }
    }

    /// Records that one index component was derived from the PDF, with its elapsed time.
    fn note_derived(&self, elapsed: Duration) {
        if let Ok(mut runtime) = self.index.lock() {
            runtime.derived_parts = runtime.derived_parts.saturating_add(1);
            runtime.derived = runtime.derived.saturating_add(elapsed);
        }
    }
}

fn micros(duration: Duration) -> u64 {
    u64::try_from(duration.as_micros()).unwrap_or(u64::MAX)
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

/// One annotation that was already inside the PDF, boxed in **view space**.
///
/// `kind` is what this reader can act on: `highlight`, `underline`, `strikeout`, `squiggly`,
/// `text` (a sticky note) and `freeText`, or — for a subtype this build does not model — the
/// PDF's own `/Subtype` name (`Ink`, `Stamp`, …), so the shell can still list it.
///
/// The rectangle and the quads are in view space (points, top-left origin), the same convention
/// as [`LinkRecord`] and [`ReferenceFragment`]; `/QuadPoints` is what markup annotations are
/// really drawn from, so prefer `quads` and fall back to `x_pt`/`y_pt`/`width_pt`/`height_pt`
/// when it is empty.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AnnotationRecord {
    /// Page the annotation is on (0-based).
    pub page: u32,
    /// The annotation's identity: `nm:<NM>` when the file names it, otherwise a stable
    /// fingerprint (`fp:<hex>`) of its dictionary. This is what `/IRT` entries name, and it is
    /// unique among the annotations this reader reports for one document.
    pub id: String,
    /// The [`AnnotationRecord::id`] of the annotation this one replies to via `/IRT`; `None`
    /// when it is not a reply, or when `/IRT` is present but PDFium cannot resolve it.
    pub parent_id: Option<String>,
    /// Whether this annotation carries an `/IRT` entry, whether or not its parent could be read.
    ///
    /// The parent may be on another page, hidden from the page, or skipped from the reader's
    /// annotation list. Those are the shell's cases to resolve, not reasons to drop the reply.
    pub is_reply: bool,
    /// `highlight`, `underline`, `strikeout`, `squiggly`, `text`, `freeText`, or the PDF subtype.
    pub kind: String,
    pub x_pt: f64,
    pub y_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
    /// `/QuadPoints`, one box per quadrilateral; empty when the file has none.
    pub quads: Vec<AnnotationQuad>,
    /// `/InkList`, one polyline per stroke, each point in view space (top-left origin).
    pub ink_paths: Vec<Vec<AnnotationPoint>>,
    /// A `/Line` annotation's endpoints in view space; `None` for every other kind.
    pub line_start: Option<AnnotationPoint>,
    pub line_end: Option<AnnotationPoint>,
    /// Whether a line annotation carries an arrowhead (`/LE`, or `/Subj (Arrow)`).
    pub line_arrow: bool,
    /// `/BS /W`, in points, when the file states one.
    pub border_width_pt: Option<f64>,
    /// `/C` as 8-bit sRGB; `None` when the file carries no colour (sticky notes usually do not).
    pub color: Option<AnnotationColorRecord>,
    /// `/CA` constant opacity in `0.0..=1.0`; `None` when the file does not state one, which
    /// means opaque.
    pub opacity: Option<f64>,
    /// The blend mode the annotation is composited with: the file's `/BM` when it states one
    /// (`normal`, `multiply`, …), otherwise the mode that kind is drawn with by every renderer.
    ///
    /// Highlights are normally stored as `multiply`, and a highlight drawn with plain alpha-over
    /// does **not** look like the same highlight in Preview — the canvas answers that with
    /// `QuadBlend::Multiply`. Most producers (Preview among them) do not put `/BM` on the
    /// annotation at all: they composite through the appearance stream's `ExtGState`, which
    /// PDFium's C API does not expose, so a markup annotation with no `/BM` is reported with the
    /// blend it is drawn with (`aris-reader-pdfium` measures and documents that table).
    pub blend: String,
    /// `/Contents`.
    pub contents: Option<String>,
    /// `/T`.
    pub author: Option<String>,
    /// `/M`, as the file writes it (`D:YYYYMMDDHHmmSS±HH'mm'`).
    pub modified: Option<String>,
    /// The font size `/DA` states for this annotation's text, in points; `None` when the file
    /// states none, or states one no reader should draw (zero, negative, or page-sized — see
    /// `aris-reader-pdfium::annotations`).
    ///
    /// This is what a `/FreeText` annotation's size lives in, and it is read for every kind
    /// because the key is legal on all of them. The shell draws free text at this size when it has
    /// one, and otherwise at its own default, which it reports.
    pub font_size_pt: Option<f64>,
    /// `/Q`: `left`, `center` or `right` — how a `/FreeText` annotation's text is aligned in its
    /// rectangle. Always one of the three: the PDF's own default (left) stands in when the file
    /// says nothing, so the shell never has to decide what "no alignment" means.
    pub alignment: String,
    /// What to put on the page, and the reason when the answer is "nothing": `markup` (a tinted
    /// box per quad), `noteIcon` (a `/Text` sticky note), `freeText` (a `/FreeText` annotation's
    /// own text), or `skipped`.
    ///
    /// Stated by the reader rather than re-derived by each consumer, so the dump, the checks and
    /// the canvas cannot disagree about which annotations are supposed to appear.
    pub drawing: String,
    /// Why nothing is drawn, when `drawing` is `skipped`: `hidden` (the file's `/F` says so),
    /// `empty-rect` (no box to draw in) or `unmodelled` (a subtype this build has no rule for).
    /// `None` for every drawn annotation.
    pub skip_reason: Option<String>,
    /// False when the file marks the annotation hidden/invisible/`/NoView`.
    pub visible: bool,
}

/// One point of an ink stroke or a line, in view space (points, top-left origin).
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct AnnotationPoint {
    pub x_pt: f64,
    pub y_pt: f64,
}

/// One quadrilateral of an annotation's `/QuadPoints`, in view space.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct AnnotationQuad {
    pub x_pt: f64,
    pub y_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
}

/// An annotation colour, 8-bit sRGB.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct AnnotationColorRecord {
    pub red: u8,
    pub green: u8,
    pub blue: u8,
}

/// The PDF annotation a pending write becomes.
///
/// `Note` is a sticky note (`/Subtype /Text`): its `rect` is the icon box and its contents are
/// the note. `Highlight`/`Underline` are the quad-based text marks: their `quads` are the text
/// boxes and `contents` is the comment attached to the mark (what the shell's `note` field is).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AnnotationWriteKind {
    Highlight,
    Underline,
    Note,
    /// `/Ink`: `ink_paths` are the strokes, in view space.
    Ink,
    /// `/Square`: `rect` is the stroked rectangle.
    Square,
    /// `/Circle`: `rect` is the stroked ellipse.
    Circle,
    /// `/Line`: `line_start`/`line_end` are the endpoints; `line_arrow` adds a head.
    Line,
}

/// One annotation the shell asks the writer to put into a PDF.
///
/// Geometry is **view space at `zoom`** (points, top-left origin), exactly the space the canvas
/// draws in. The Rust side owns the single conversion into page space, so a highlight saved at
/// 100% and the same highlight saved at 300% produce identical PDF coordinates.
#[derive(Debug, Clone, uniffi::Record)]
pub struct WriteAnnotationRecord {
    /// Stable identity written as `/NM`; the shell uses the sidecar's UUID string so a saved
    /// annotation can be recognised after reopening.
    pub id: String,
    pub page: u32,
    pub kind: AnnotationWriteKind,
    /// View-space box at `zoom`. For a note this is its icon; for markup the union of `quads`
    /// is used and this box is validated for consistency.
    pub rect: AnnotationQuad,
    /// View-space `/QuadPoints` at `zoom`; empty for notes and for the stroked kinds.
    pub quads: Vec<AnnotationQuad>,
    /// View-space `/InkList` at `zoom`, one stroke per entry; only for [`AnnotationWriteKind::Ink`].
    pub ink_paths: Vec<Vec<AnnotationPoint>>,
    /// View-space `/L` endpoints at `zoom`; required for [`AnnotationWriteKind::Line`].
    pub line_start: Option<AnnotationPoint>,
    pub line_end: Option<AnnotationPoint>,
    /// Write `/LE [/None /ClosedArrow]`; only meaningful for a line.
    pub line_arrow: bool,
    /// `/BS /W` in points, for the stroked kinds.
    pub border_width_pt: f64,
    pub color: AnnotationColorRecord,
    /// `/CA`; the shell's colour alpha carries it (0…1).
    pub opacity: f64,
    /// `/Contents` — the highlight comment or the note body.
    pub contents: String,
    /// `/T`.
    pub author: String,
    /// `/M`, PDF date format (`D:YYYYMMDDHHmmSSOHH'mm'`).
    pub modified: String,
}

/// What a successful write did. Every value is about the *file that was written*, not about the
/// request: `written_ids` comes back so the shell removes exactly those sidecar entries.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AnnotationSaveReport {
    pub destination_path: String,
    pub written_ids: Vec<String>,
    /// Bytes appended to the original (the original prefix is kept byte-for-byte).
    pub appended_bytes: u64,
    /// Present only when the original was replaced; the file is verified byte-identical.
    pub backup_path: Option<String>,
    /// Content annotations the source already had; all were verified unchanged.
    pub preexisting_annotation_count: u32,
    /// Stale `.lyra-save-*.tmp` files removed before this save.
    pub cleaned_temporary_files: u32,
    /// True when the written file's prefix equals the source byte-for-byte.
    pub source_bytes_preserved: bool,
}

/// A destructive-ish page operation requested by the shell.
///
/// Every variant operates on a copy; the source path is this document's file. Page numbers are
/// 0-based. `Move.destination` is the index in the list **after** the moved pages are removed,
/// which is what PDFium's `FPDF_MovePages` expects; for a single page, moving it up is
/// `destination = page - 1` and moving it down is `destination = page` on a document with at
/// least one page after it.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum PageOperationRecord {
    Rotate {
        pages: Vec<u32>,
        quarter_turns: i32,
    },
    SetRotation {
        pages: Vec<u32>,
        quarter_turns: Vec<u32>,
    },
    Delete {
        pages: Vec<u32>,
    },
    Move {
        pages: Vec<u32>,
        destination: u32,
    },
    InsertBlank {
        index: u32,
    },
}

/// The result of a page operation or of publishing a page-edit revision.
#[derive(Debug, Clone, uniffi::Record)]
pub struct PageEditReport {
    /// The file that was written.
    pub destination_path: String,
    pub page_count: u32,
    /// `page_map[old] = Some(new)` for surviving pages, `None` for removed/not-extracted ones.
    pub page_map: Vec<Option<u32>>,
    /// `/Rotate` of every written page, in quarter turns.
    pub rotations: Vec<u32>,
    /// The inserted blank page's index, when the operation inserted one.
    pub inserted_page: Option<u32>,
    /// The verified backup, only when the original was replaced.
    pub backup_path: Option<String>,
    pub output_bytes: u64,
    /// Stale `.lyra-save-*.tmp` files removed before writing.
    pub cleaned_temporary_files: u32,
}

/// One outline entry.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
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

#[derive(Debug, Clone, PartialEq, uniffi::Record, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
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
///
/// `x_pt`/`y_pt`/`width_pt`/`height_pt` are the entry's box **on `page`**, which is what the
/// preview has always drawn: for an entry that fits in one column that box is unchanged, and for
/// one that is split it is the union of the pieces on `page` (see `fragments`). The pieces
/// themselves are in `fragments`; an entry spanning two pages has one there per page, and the
/// single box here can only ever describe `page`.
#[derive(Debug, Clone, PartialEq, uniffi::Record, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReferenceRecord {
    pub label: String,
    pub text: String,
    /// Page the entry starts on (0-based).
    pub page: u32,
    pub x_pt: f64,
    pub y_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
    /// The pieces the entry is drawn in, in reading order, in **view space**.
    ///
    /// One element for the common case — one column, one page — where it equals the box above.
    /// Two or more when the entry crosses a column gutter or continues on the next page; a
    /// preview that draws a rectangle per fragment never spans a gutter. Empty when the page's
    /// text layer offered no boxes at all, in which case the box above is the only geometry.
    pub fragments: Vec<ReferenceFragment>,
}

/// One piece of a reference entry: the page to draw on and the box to show, in **view space**.
#[derive(Debug, Clone, PartialEq, uniffi::Record, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReferenceFragment {
    /// Page the fragment is drawn on (0-based).
    pub page: u32,
    /// Box in view space (points, top-left origin), ready for `rasterize_region`.
    pub x_pt: f64,
    pub y_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
}

/// A figure or table caption, with the region of its page a floating preview should show.
#[derive(Debug, Clone, PartialEq, uniffi::Record, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
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

/// One view-space box at `zoom`, converted into page space.
///
/// The inverse of [`page_region_to_view`]'s transform, with the zoom the canvas is drawing at.
/// The returned rectangle is axis-aligned in page space: `/Rotate` is a multiple of 90° in PDF,
/// so a view rectangle maps to another axis-aligned rectangle (the canvas only ever produces
/// horizontal text boxes anyway). Bounds are checked against `/CropBox` with one point of slack
/// so a hairline round-off at the page edge is not turned into a refusal.
fn view_box_to_page_rect(
    view: &AnnotationQuad,
    inverse: Transform2D,
    geometry: &PageGeometry,
) -> Result<aris_reader_core::Rect, ArisFfiError> {
    let values = [view.x_pt, view.y_pt, view.width_pt, view.height_pt];
    if !values.iter().all(|value| value.is_finite())
        || view.width_pt <= 0.0
        || view.height_pt <= 0.0
    {
        return Err(ArisFfiError::InvalidArgument {
            message: format!(
                "a view-space box has no area or is not finite: {:?}",
                values
            ),
        });
    }
    let top_left = inverse.apply(Point::new(view.x_pt, view.y_pt));
    let bottom_right = inverse.apply(Point::new(
        view.x_pt + view.width_pt,
        view.y_pt + view.height_pt,
    ));
    let rect = aris_reader_core::Rect::new(
        top_left.x.min(bottom_right.x),
        top_left.y.min(bottom_right.y),
        (top_left.x - bottom_right.x).abs(),
        (top_left.y - bottom_right.y).abs(),
    );
    if !rect.origin.x.is_finite()
        || !rect.origin.y.is_finite()
        || !rect.size.width.is_finite()
        || !rect.size.height.is_finite()
        || rect.size.width <= 0.0
        || rect.size.height <= 0.0
    {
        return Err(ArisFfiError::InvalidArgument {
            message: "a view-space box converted to an empty page-space box".to_string(),
        });
    }
    let crop = geometry.crop_box;
    const SLACK: f64 = 1.0;
    if rect.min_x() < crop.min_x() - SLACK
        || rect.min_y() < crop.min_y() - SLACK
        || rect.max_x() > crop.max_x() + SLACK
        || rect.max_y() > crop.max_y() + SLACK
    {
        return Err(ArisFfiError::InvalidArgument {
            message: format!("annotation box {rect:?} falls outside the page's crop box {crop:?}"),
        });
    }
    Ok(rect)
}

/// An empty optional string means "the file should not carry this key".
fn text_or_none(text: &str) -> Option<String> {
    if text.is_empty() {
        None
    } else {
        Some(text.to_string())
    }
}

/// Whether two page-space rectangles agree to within half a point.
fn rects_close(left: aris_reader_core::Rect, right: aris_reader_core::Rect) -> bool {
    (left.min_x() - right.min_x()).abs() <= 0.5
        && (left.min_y() - right.min_y()).abs() <= 0.5
        && (left.max_x() - right.max_x()).abs() <= 0.5
        && (left.max_y() - right.max_y()).abs() <= 0.5
}

/// The view transform of `page`, remembered in `cache` for the rest of the scan.
fn document_page_view(
    backend: &PdfiumBackend,
    cache: &mut std::collections::HashMap<u32, aris_reader_core::Transform2D>,
    page: u32,
) -> Option<aris_reader_core::Transform2D> {
    if let Some(transform) = cache.get(&page) {
        return Some(*transform);
    }
    let transform = backend
        .page_info(PageIndex(page))
        .ok()?
        .geometry
        .page_to_view(1.0);
    cache.insert(page, transform);
    Some(transform)
}

/// Citation spans in one page's text layer, converted to the view space the canvas draws in.
///
/// One function for the per-page path and the document scan, so a cached span can never differ
/// from the span a fresh `citations(page)` call would produce.
fn citation_records(
    raw: &aris_reader_core::RawTextPage,
    style: &aris_reader_text::CitationStyle,
    page: u32,
    transform: aris_reader_core::Transform2D,
) -> Vec<CitationRecord> {
    aris_reader_text::find_citations_with(raw, style)
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
        .collect()
}

/// A page-space box as its view-space **top-left corner**, the convention the preview uses.
fn view_box(
    backend: &PdfiumBackend,
    cache: &mut std::collections::HashMap<u32, aris_reader_core::Transform2D>,
    page: u32,
    rect: aris_reader_core::Rect,
) -> Option<Point> {
    let transform = document_page_view(backend, cache, page)?;
    Some(transform.apply(Point::new(rect.origin.x, rect.origin.y + rect.size.height)))
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
            annotations: Mutex::new(None),
            metadata: Mutex::new(None),
            outline: Mutex::new(None),
            citations: Mutex::new(None),
            index: Mutex::new(IndexRuntime::default()),
            replaced: std::sync::atomic::AtomicBool::new(false),
            ai_text: Mutex::new(std::collections::HashMap::new()),
        }))
    }
}

// ── AI assistant: plans and streaming requests ──────────────────────────────────────────────

/// What the reader asked the assistant to do, as the Swift panel names it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AiActionRecord {
    SummarizePage,
    SummarizeDocument,
    AskSelection,
    TranslateSelection,
}

/// A selected character range on one page (0-based, inclusive).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct AiSelectionRecord {
    pub page: u32,
    pub start: u32,
    pub end: u32,
}

/// Everything needed to build a preview. The API key is deliberately absent.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AiPlanRequestRecord {
    pub action: AiActionRecord,
    pub current_page: u32,
    pub selection: Option<AiSelectionRecord>,
    pub question: Option<String>,
    pub language: Option<String>,
    pub base_url: String,
    pub model: String,
    pub temperature: Option<f64>,
    pub max_tokens: Option<u32>,
    /// One of `default`, `off`, `low`, `high`, `max`.
    pub reasoning_mode: String,
    /// One of `none`, `thinking`, `reasoning_effort`, `output_config`, `reasoning.effort`.
    pub reasoning_encoding: String,
}

/// One part summary used by the consolidation request.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AiMergePartRecord {
    pub index: u32,
    pub total: u32,
    pub pages: Vec<u32>,
    pub summary: String,
}

/// The local input to the consolidation request. It carries part summaries, not page text.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AiMergePlanRequestRecord {
    pub document_title: String,
    pub parts: Vec<AiMergePartRecord>,
    pub base_url: String,
    pub model: String,
    pub temperature: Option<f64>,
    pub max_tokens: Option<u32>,
    pub reasoning_mode: String,
    pub reasoning_encoding: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AiHeaderRecord {
    pub name: String,
    pub value: String,
}

/// One request in the preview. `wire_body` is the exact JSON body; the key is added only when
/// the reader presses Send, so it can never appear here.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AiPlanPartRecord {
    pub index: u32,
    pub total: u32,
    pub label: String,
    pub primary_page: u32,
    pub pages: Vec<u32>,
    pub page_characters: u64,
    pub request_characters: u64,
    pub system_prompt: String,
    pub user_prompt: String,
    pub wire_body: String,
    pub note: Option<String>,
}

/// The complete, previewable plan for one action.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AiPlanRecord {
    pub action: AiActionRecord,
    pub action_label: String,
    pub document_title: String,
    pub page_count: u32,
    pub base_url: String,
    pub endpoint: String,
    pub host: String,
    pub is_local: bool,
    pub model: String,
    pub temperature: Option<f64>,
    pub max_tokens: Option<u32>,
    pub parts: Vec<AiPlanPartRecord>,
    pub source_pages: Vec<u32>,
    pub note: Option<String>,
    pub preview_headers: Vec<AiHeaderRecord>,
    pub estimated_tokens: u64,
}

/// A validated base URL: the settings panel and the preview show the same normalised values.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AiEndpointRecord {
    pub base_url: String,
    pub endpoint: String,
    pub host: String,
    pub is_local: bool,
}

/// Validate and normalise a base URL without touching the network.
#[uniffi::export]
pub fn inspect_ai_base_url(base_url: String) -> Result<AiEndpointRecord, ArisFfiError> {
    let endpoint = inspect_base_url(&base_url)?;
    Ok(AiEndpointRecord {
        base_url: endpoint.base_url,
        endpoint: endpoint.endpoint,
        host: endpoint.host,
        is_local: endpoint.is_local,
    })
}

/// Validate a model name without touching the network.
#[uniffi::export]
pub fn validate_ai_model(model: String) -> Result<String, ArisFfiError> {
    Ok(validate_model(&model)?)
}

/// Per-request instrumentation. Counts and byte totals only; no content.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AiStreamDiagnostics {
    pub http_status: u16,
    pub bytes: u64,
    pub frames: u32,
    pub data_frames: u32,
    pub content_frames: u32,
    pub reasoning_frames: u32,
    pub role_only_frames: u32,
    pub empty_frames: u32,
    pub usage_frames: u32,
    pub content_shape: String,
    pub finish_reason: Option<String>,
    pub prompt_tokens: Option<u64>,
    pub completion_tokens: Option<u64>,
    pub total_tokens: Option<u64>,
    pub reasoning_tokens: Option<u64>,
}

/// One event from a running request. The shell polls a handle and renders these in order.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum AiEventRecord {
    PartStarted {
        index: u32,
        total: u32,
        label: String,
    },
    Delta {
        text: String,
    },
    /// The provider's reasoning/thinking channel. The shell shows it separately and never
    /// appends it to the answer.
    ReasoningDelta {
        text: String,
    },
    Usage {
        prompt_tokens: Option<u64>,
        completion_tokens: Option<u64>,
        total_tokens: Option<u64>,
        reasoning_tokens: Option<u64>,
    },
    Diagnostics {
        diagnostics: AiStreamDiagnostics,
    },
    Done,
    Error {
        message: String,
        cancelled: bool,
    },
}

struct AiJob {
    events: Mutex<std::collections::VecDeque<AiEventRecord>>,
    finished: std::sync::atomic::AtomicBool,
    cancel: CancellationToken,
}

impl Default for AiJob {
    fn default() -> Self {
        Self {
            events: Mutex::new(std::collections::VecDeque::new()),
            finished: std::sync::atomic::AtomicBool::new(false),
            cancel: CancellationToken::new(),
        }
    }
}

impl AiJob {
    fn push_event(&self, event: RunEvent) {
        let event = match event {
            RunEvent::PartStarted {
                index,
                total,
                label,
            } => AiEventRecord::PartStarted {
                index,
                total,
                label,
            },
            RunEvent::Delta(text) => AiEventRecord::Delta { text },
            RunEvent::ReasoningDelta(text) => AiEventRecord::ReasoningDelta { text },
            RunEvent::Usage(TokenUsage {
                prompt_tokens,
                completion_tokens,
                total_tokens,
                reasoning_tokens,
            }) => AiEventRecord::Usage {
                prompt_tokens,
                completion_tokens,
                total_tokens,
                reasoning_tokens,
            },
            RunEvent::Diagnostics(StreamDiagnostics {
                http_status,
                bytes,
                frames,
                data_frames,
                content_frames,
                reasoning_frames,
                role_only_frames,
                empty_frames,
                usage_frames,
                content_shape,
                finish_reason,
                usage,
            }) => AiEventRecord::Diagnostics {
                diagnostics: AiStreamDiagnostics {
                    http_status,
                    bytes,
                    frames,
                    data_frames,
                    content_frames,
                    reasoning_frames,
                    role_only_frames,
                    empty_frames,
                    usage_frames,
                    content_shape,
                    finish_reason,
                    prompt_tokens: usage.prompt_tokens,
                    completion_tokens: usage.completion_tokens,
                    total_tokens: usage.total_tokens,
                    reasoning_tokens: usage.reasoning_tokens,
                },
            },
            RunEvent::Done => AiEventRecord::Done,
        };
        self.push(event);
    }

    fn push(&self, event: AiEventRecord) {
        self.events
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .push_back(event);
    }
}

/// A running AI request. The worker thread owns the key for the duration of the request and
/// drops it when the worker ends; this handle holds only events and a cancellation flag.
#[derive(uniffi::Object)]
pub struct ArisAiRequest {
    job: Arc<AiJob>,
}

impl Drop for ArisAiRequest {
    fn drop(&mut self) {
        // The Swift handle owns this object. If the panel goes away without calling cancel, the
        // worker must still stop rather than stream into a queue nobody reads.
        self.job.cancel.cancel();
    }
}

#[uniffi::export]
impl ArisAiRequest {
    /// Events queued since the previous poll, oldest first.
    pub fn poll(&self) -> Vec<AiEventRecord> {
        let mut events = self
            .job
            .events
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        std::mem::take(&mut *events).into_iter().collect()
    }

    /// Ask the worker to stop. The transports observe this flag and the HTTP request is closed.
    pub fn cancel(&self) {
        self.job.cancel.cancel();
    }

    /// Whether the worker has stopped. A final `poll()` may still return the last events.
    pub fn is_finished(&self) -> bool {
        self.job.finished.load(std::sync::atomic::Ordering::SeqCst)
    }
}

/// Start a request for a previously previewed plan.
///
/// `api_key` crosses the FFI boundary here and is moved into the worker thread; it is not stored
/// in [`ArisAiRequest`], the job, or any record. `use_mock_provider` is the deterministic,
/// network-free path used by the checks; the app always passes `false`.
#[uniffi::export]
pub fn start_ai_request(
    plan: AiPlanRecord,
    api_key: String,
    use_mock_provider: bool,
) -> Result<Arc<ArisAiRequest>, ArisFfiError> {
    if api_key.is_empty() {
        return Err(ArisFfiError::Ai {
            message: "No API key is configured. Add one in Settings > AI; nothing was sent."
                .to_string(),
        });
    }
    if api_key.chars().any(|character| character.is_control()) {
        return Err(ArisFfiError::Ai {
            message: "The API key contains a control character or line break, so it was not sent."
                .to_string(),
        });
    }
    let plan = chat_plan_from_record(plan)?;
    let job = Arc::new(AiJob::default());
    let worker_job = Arc::clone(&job);
    std::thread::Builder::new()
        .name("lyra-ai-request".to_string())
        .spawn(move || {
            let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let mut emit = |event: RunEvent| worker_job.push_event(event);
                if use_mock_provider {
                    MockProvider::preset().run(&plan, &worker_job.cancel, &mut emit)
                } else {
                    run_plan(&plan, &api_key, &worker_job.cancel, &mut emit)
                }
            }));
            match outcome {
                Ok(Ok(())) => {}
                Ok(Err(aris_reader_ai::AiError::Cancelled)) => {
                    worker_job.push(AiEventRecord::Error {
                        message: "Cancelled".to_string(),
                        cancelled: true,
                    });
                }
                Ok(Err(error)) => {
                    worker_job.push(AiEventRecord::Error {
                        message: error.to_string(),
                        cancelled: false,
                    });
                }
                Err(_) => {
                    worker_job.push(AiEventRecord::Error {
                        message: "The AI request worker stopped unexpectedly.".to_string(),
                        cancelled: false,
                    });
                }
            }
            worker_job
                .finished
                .store(true, std::sync::atomic::Ordering::SeqCst);
        })
        .map_err(|error| ArisFfiError::Ai {
            message: format!("could not start the AI request worker: {error}"),
        })?;
    Ok(Arc::new(ArisAiRequest { job }))
}

/// Build the previewable consolidation request from part summaries. This never touches the
/// network; it is the same preview-before-send path as the part requests.
#[uniffi::export]
pub fn build_ai_merge_plan(
    request: AiMergePlanRequestRecord,
) -> Result<AiPlanRecord, ArisFfiError> {
    let temperature = request.temperature.and_then(|value| {
        if value.is_finite() {
            Some(value as f32)
        } else {
            None
        }
    });
    let reasoning_mode = ReasoningMode::from_wire(&request.reasoning_mode).ok_or_else(|| {
        ArisFfiError::InvalidArgument {
            message: format!(
                "Unknown reasoning mode {}. Use default, off, low, high or max.",
                request.reasoning_mode
            ),
        }
    })?;
    let reasoning_encoding =
        ReasoningEncoding::from_wire(&request.reasoning_encoding).ok_or_else(|| {
            ArisFfiError::InvalidArgument {
                message: format!(
                    "Unknown reasoning encoding {}. Use none, thinking, reasoning_effort, output_config or reasoning.effort.",
                    request.reasoning_encoding
                ),
            }
        })?;
    let plan = build_merge_plan(MergePlanRequest {
        document_title: request.document_title,
        settings: ChatSettings {
            base_url: request.base_url,
            model: request.model,
            temperature,
            max_tokens: request.max_tokens,
            reasoning_mode,
            reasoning_encoding,
        },
        parts: request
            .parts
            .into_iter()
            .map(|part| MergePart {
                index: part.index,
                total: part.total,
                pages: part.pages,
                summary: part.summary,
            })
            .collect(),
    })?;
    Ok(ai_plan_record(plan))
}

fn ai_plan_record(plan: ChatPlan) -> AiPlanRecord {
    let estimated_tokens = plan.estimated_tokens();
    AiPlanRecord {
        action: ai_action_record(plan.action),
        action_label: plan.action.label().to_string(),
        document_title: plan.document_title,
        page_count: plan.page_count,
        base_url: plan.base_url,
        endpoint: plan.endpoint,
        host: plan.host,
        is_local: plan.is_local,
        model: plan.model,
        temperature: plan.temperature.map(f64::from),
        max_tokens: plan.max_tokens,
        parts: plan
            .parts
            .into_iter()
            .map(|part| AiPlanPartRecord {
                index: part.index,
                total: part.total,
                label: part.label,
                primary_page: part.primary_page,
                pages: part.pages,
                page_characters: part.page_characters,
                request_characters: part.request_characters,
                system_prompt: part.system_prompt,
                user_prompt: part.user_prompt,
                wire_body: part.wire_body,
                note: part.note,
            })
            .collect(),
        source_pages: plan.source_pages,
        note: plan.note,
        preview_headers: preview_headers()
            .into_iter()
            .map(|(name, value)| AiHeaderRecord { name, value })
            .collect(),
        estimated_tokens,
    }
}

fn ai_action_record(action: AiAction) -> AiActionRecord {
    match action {
        AiAction::SummarizePage => AiActionRecord::SummarizePage,
        AiAction::SummarizeDocument => AiActionRecord::SummarizeDocument,
        AiAction::AskSelection => AiActionRecord::AskSelection,
        AiAction::TranslateSelection => AiActionRecord::TranslateSelection,
    }
}

fn chat_plan_from_record(plan: AiPlanRecord) -> Result<ChatPlan, ArisFfiError> {
    let action = match plan.action {
        AiActionRecord::SummarizePage => AiAction::SummarizePage,
        AiActionRecord::SummarizeDocument => AiAction::SummarizeDocument,
        AiActionRecord::AskSelection => AiAction::AskSelection,
        AiActionRecord::TranslateSelection => AiAction::TranslateSelection,
    };
    if !(plan.endpoint.starts_with("http://") || plan.endpoint.starts_with("https://")) {
        return Err(ArisFfiError::Ai {
            message: "The request preview has an invalid endpoint.".to_string(),
        });
    }
    if plan.parts.is_empty() {
        return Err(ArisFfiError::Ai {
            message: "The request preview has no requests.".to_string(),
        });
    }
    let parts = plan
        .parts
        .into_iter()
        .map(|part| aris_reader_ai::ChatPart {
            index: part.index,
            total: part.total,
            label: part.label,
            pages: part.pages,
            primary_page: part.primary_page,
            page_characters: part.page_characters,
            request_characters: part.request_characters,
            system_prompt: part.system_prompt,
            user_prompt: part.user_prompt,
            wire_body: part.wire_body,
            note: part.note,
        })
        .collect();
    Ok(ChatPlan {
        action,
        document_title: plan.document_title,
        page_count: plan.page_count,
        base_url: plan.base_url,
        endpoint: plan.endpoint,
        host: plan.host,
        is_local: plan.is_local,
        model: plan.model,
        temperature: plan.temperature.map(|value| value as f32),
        max_tokens: plan.max_tokens,
        parts,
        source_pages: plan.source_pages,
        note: plan.note,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::ErrorKind;
    use std::sync::atomic::{AtomicU64, Ordering};

    /// Resolves a committed fixture at run time.
    ///
    /// `CARGO_MANIFEST_DIR` is compiled into the binary. When several checkouts share one
    /// `target/` directory, cargo can run a binary that was built in a checkout which has since
    /// been deleted; the committed fixtures then exist only in the checkout running the tests.
    /// The working directory (the package root) and an explicit override are therefore searched
    /// as well.
    fn fixture(name: &str) -> std::path::PathBuf {
        let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        let mut roots = Vec::new();
        if let Some(override_dir) = std::env::var_os("ARIS_READER_TEST_FIXTURES")
            && !override_dir.is_empty()
        {
            roots.push(std::path::PathBuf::from(override_dir));
        }
        // The checkout currently running the tests wins over the one that compiled the binary.
        if let Ok(current_dir) = std::env::current_dir() {
            roots.extend(
                current_dir
                    .ancestors()
                    .map(|ancestor| ancestor.join("tests/fixtures")),
            );
        }
        roots.push(manifest.join("../../tests/fixtures"));
        let mut tried = Vec::new();
        for root in roots {
            let candidate = root.join(name);
            if candidate.is_file() {
                return candidate;
            }
            tried.push(candidate);
        }
        let tried = tried
            .iter()
            .map(|path| format!("  {}", path.display()))
            .collect::<Vec<_>>()
            .join("\n");
        panic!("test fixture {name:?} was not found. Tried:\n{tried}");
    }

    /// A scratch directory owned by one test and removed when the test ends (or panics).
    ///
    /// The name includes a process-wide sequence number as well as the pid and clock, and the
    /// directory itself is reserved with `create_dir`, so two tests can never share it.
    struct ScratchDir {
        path: std::path::PathBuf,
    }

    impl std::ops::Deref for ScratchDir {
        type Target = std::path::Path;
        fn deref(&self) -> &std::path::Path {
            &self.path
        }
    }

    impl AsRef<std::path::Path> for ScratchDir {
        fn as_ref(&self) -> &std::path::Path {
            &self.path
        }
    }

    impl Drop for ScratchDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    fn scratch(label: &str) -> ScratchDir {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let root = std::env::temp_dir();
        std::fs::create_dir_all(&root).unwrap_or_else(|error| {
            panic!(
                "could not create the temporary directory {}: {error}",
                root.display()
            )
        });
        let root = std::fs::canonicalize(&root).unwrap_or(root);
        let label: String = label
            .chars()
            .map(|character| {
                if character.is_ascii_alphanumeric() || character == '-' || character == '_' {
                    character
                } else {
                    '_'
                }
            })
            .take(48)
            .collect();
        for _ in 0..128 {
            let nanos = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|duration| duration.as_nanos())
                .unwrap_or(0);
            let sequence = NEXT.fetch_add(1, Ordering::Relaxed);
            let path = root.join(format!(
                "aris-ffi-test-{}-{sequence}-{nanos}-{label}",
                std::process::id()
            ));
            match std::fs::create_dir(&path) {
                Ok(()) => return ScratchDir { path },
                Err(error) if error.kind() == ErrorKind::AlreadyExists => continue,
                Err(error) => panic!(
                    "could not create test scratch directory {}: {error}",
                    path.display()
                ),
            }
        }
        panic!(
            "could not find a free test scratch directory under {}",
            root.display()
        );
    }

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
        // Without a PDFium library the engine fails before it can look at the path, so it
        // answers `BackendUnavailable` and the mapping pinned down here is unreachable. Same
        // guard as the other engine-backed tests below: the Linux CI job has no PDFium, and
        // scripts/fetch-pdfium.sh only downloads the macOS build.
        if !aris_reader_pdfium::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }

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
    fn annotations_already_in_the_pdf_cross_the_ffi_intact() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/annotated.pdf");
        if !fixture.exists() || !aris_reader_pdfium::is_available() {
            eprintln!("skipping: annotated fixture or PDFium unavailable");
            return;
        }

        let engine = ArisEngine::new();
        let document = engine
            .open_document(fixture.display().to_string(), None)
            .expect("open fixture");
        let records = document.annotations().expect("annotations");

        assert_eq!(records.len(), 7, "five on page 1, two on page 2");
        assert_eq!(
            records
                .iter()
                .map(|record| record.kind.as_str())
                .collect::<Vec<_>>(),
            vec![
                "highlight",
                "underline",
                "strikeout",
                "text",
                "freeText",
                "squiggly",
                "highlight"
            ]
        );

        let highlight = &records[0];
        assert_eq!(highlight.page, 0);
        // View space, top-left origin: `/Rect [72 671 460 701]` on an 842 pt page has its top edge
        // 842 - 701 = 141 pt below the top, and keeps its width and height.
        assert_eq!(highlight.x_pt, 72.0);
        assert_eq!(highlight.y_pt, 842.0 - 701.0);
        assert_eq!(highlight.width_pt, 388.0);
        assert_eq!(highlight.height_pt, 30.0);
        assert_eq!(highlight.quads.len(), 2, "the highlight spans two lines");
        assert_eq!(highlight.quads[1].x_pt, 72.0);
        assert_eq!(highlight.quads[1].y_pt, 842.0 - 686.0);
        assert_eq!(highlight.quads[1].width_pt, 288.0);
        assert_eq!(highlight.quads[1].height_pt, 15.0);

        // The colour the file carries, not a palette index: `/C [0.2 0.6 1]`.
        let color = highlight.color.expect("the highlight has a colour");
        assert_eq!((color.red, color.green, color.blue), (51, 153, 255));
        assert_eq!(highlight.opacity, Some(0.5));
        // The blend mode has to arrive with it: it is what makes the colour look the same here
        // as in the viewer that wrote the file.
        assert_eq!(highlight.blend, "multiply");
        assert_eq!(
            highlight.contents.as_deref(),
            Some("Highlight contents for the round trip.")
        );
        assert_eq!(highlight.author.as_deref(), Some("Reviewer A"));
        assert_eq!(highlight.modified.as_deref(), Some("D:20240102030405Z"));
        assert!(highlight.visible);

        // A sticky note keeps its text and reports no colour rather than inventing black.
        let sticky = &records[3];
        assert_eq!(sticky.kind, "text");
        assert_eq!(sticky.color, None);
        assert_eq!(sticky.contents.as_deref(), Some("A sticky note body."));
        assert_eq!(sticky.author.as_deref(), Some("Reviewer D"));
        // …and it arrives with the reader's own answer about what to do with it, so the shell
        // does not have to re-derive the rule from `kind` (the two drifted apart once already).
        assert_eq!(sticky.drawing, "noteIcon");
        assert_eq!(sticky.skip_reason, None);
        assert_eq!(sticky.alignment, "left", "no /Q is the PDF's own default");
        assert_eq!(sticky.font_size_pt, None, "a sticky note carries no /DA");

        // The free text is the annotation whose layout needs what only the file can say.
        let free_text = &records[4];
        assert_eq!(free_text.kind, "freeText");
        assert_eq!(free_text.drawing, "freeText");
        assert_eq!(free_text.font_size_pt, Some(10.0), "/DA (/Helv 10 Tf 0 g)");
        assert_eq!(free_text.alignment, "left");

        // Every record says either what to draw or why nothing is drawn; a record with neither
        // would be an annotation the reader reports and then loses.
        for record in &records {
            match record.drawing.as_str() {
                "skipped" => assert!(
                    record.skip_reason.is_some(),
                    "{record:?} is skipped without a reason"
                ),
                "markup" | "noteIcon" | "freeText" => assert_eq!(
                    record.skip_reason, None,
                    "{record:?} is drawn and also carries a skip reason"
                ),
                other => panic!("{record:?} has no drawing classification: {other}"),
            }
        }

        // Every record has to be inside its own page: a Y flip that quietly dropped the crop
        // origin would put one of these outside the box.
        let height = document.page_size_pt(0).expect("page size").height_pt;
        for record in &records {
            assert!(
                record.x_pt >= -1.0 && record.x_pt + record.width_pt <= 595.0 + 1.0,
                "{record:?} is outside the page horizontally"
            );
            assert!(
                record.y_pt >= -1.0 && record.y_pt + record.height_pt <= height + 1.0,
                "{record:?} is outside the page vertically"
            );
        }
    }

    /// `/IRT` parent identities cross the FFI, including for a parent on a different page, a
    /// parent the reader does not list, and a malformed two-annotation cycle.
    #[test]
    fn reply_parent_identities_cross_the_ffi() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/annotated-replies.pdf");
        if !fixture.exists() || !aris_reader_pdfium::is_available() {
            eprintln!("skipping: reply fixture or PDFium unavailable");
            return;
        }
        let engine = ArisEngine::new();
        let document = engine
            .open_document(fixture.display().to_string(), None)
            .expect("open reply fixture");
        let records = document.annotations().expect("annotations");

        assert_eq!(
            records.len(),
            11,
            "eight replies and three parents/other marks"
        );
        let by_id: std::collections::HashMap<&str, &AnnotationRecord> = records
            .iter()
            .map(|record| (record.id.as_str(), record))
            .collect();
        assert_eq!(
            by_id.len(),
            records.len(),
            "every annotation gets its own identity"
        );

        let nested = by_id["nm:reply-two"];
        assert!(nested.is_reply);
        assert_eq!(nested.parent_id.as_deref(), Some("nm:reply-one"));
        assert_eq!(
            nested.contents.as_deref(),
            Some("Second-level reply, answering the first reply.")
        );
        assert_eq!(nested.author.as_deref(), Some("Reviewer C"));
        assert_eq!(nested.modified.as_deref(), Some("D:20240102032000Z"));

        // The parent is on page 1, the reply on page 2; the identity is document-wide.
        let cross_page = by_id["nm:reply-cross-page"];
        assert_eq!(cross_page.page, 1);
        assert_eq!(cross_page.parent_id.as_deref(), Some("nm:parent-highlight"));
        assert_eq!(by_id["nm:parent-highlight"].page, 0);

        // A link is not a content annotation, so a reply to one has a parent identity that is
        // absent from the annotation list. The shell reports that as an orphan, not a crash.
        let to_link = by_id["nm:reply-to-link"];
        assert_eq!(to_link.parent_id.as_deref(), Some("nm:structural-parent"));
        assert!(!by_id.contains_key("nm:structural-parent"));

        // A two-annotation cycle arrives as two parent links; detecting it is the shell's job.
        assert_eq!(by_id["nm:cycle-a"].parent_id.as_deref(), Some("nm:cycle-b"));
        assert_eq!(by_id["nm:cycle-b"].parent_id.as_deref(), Some("nm:cycle-a"));

        // The hidden reply without /Contents still crosses the FFI as a reply.
        let empty = by_id["nm:reply-empty"];
        assert!(empty.is_reply && empty.contents.is_none());
        assert_eq!(empty.parent_id.as_deref(), Some("nm:parent-highlight"));
    }

    /// The user's question at the FFI boundary: somebody else's colour is reported as it is.
    #[test]
    fn a_colour_outside_the_palette_survives_the_ffi() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/annotated.pdf");
        if !fixture.exists() || !aris_reader_pdfium::is_available() {
            eprintln!("skipping: annotated fixture or PDFium unavailable");
            return;
        }
        let engine = ArisEngine::new();
        let document = engine
            .open_document(fixture.display().to_string(), None)
            .expect("open fixture");
        let records = document.annotations().expect("annotations");

        // The four colours `AppState.highlightPalette` used to be limited to, as RGB.
        let old_palette = [
            (255, 216, 64),
            (112, 208, 96),
            (96, 160, 240),
            (224, 112, 176),
        ];
        let blue = records[0].color.expect("colour");
        assert_eq!((blue.red, blue.green, blue.blue), (51, 153, 255));
        assert!(
            !old_palette.contains(&(blue.red, blue.green, blue.blue)),
            "the fixture's blue is deliberately outside the old palette"
        );
        // …and the same file's other annotations keep their own colours, not this one.
        let red = records[1].color.expect("underline colour");
        assert_eq!((red.red, red.green, red.blue), (229, 25, 25));
    }

    /// The shape Preview writes, at the boundary the shell reads: colour behind an appearance
    /// stream, and a blend mode the annotation dictionary never states.
    ///
    /// Before this was fixed, `FPDFAnnot_GetColor` refused every annotation in
    /// `annotated-appearance.pdf`, `AnnotationRecord::color` came through as `None`, and the
    /// canvas substituted an opaque grey — the highlight covered the text it was meant to tint.
    #[test]
    fn an_appearance_stream_annotation_arrives_with_its_colour_and_blend() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/annotated-appearance.pdf");
        if !fixture.exists() || !aris_reader_pdfium::is_available() {
            eprintln!("skipping: appearance-stream fixture or PDFium unavailable");
            return;
        }
        let engine = ArisEngine::new();
        let document = engine
            .open_document(fixture.display().to_string(), None)
            .expect("open fixture");
        let records = document.annotations().expect("annotations");
        assert_eq!(records.len(), 4);

        let highlight = &records[0];
        let color = highlight.color.expect("the highlight's /C is readable");
        assert_eq!((color.red, color.green, color.blue), (255, 255, 0));
        let opacity = highlight.opacity.expect("/CA 0.968627");
        assert!(
            (opacity - 0.968627).abs() < 1e-6,
            "/CA arrives exactly: {opacity}"
        );
        assert_eq!(
            highlight.blend, "multiply",
            "the shell draws through the multiply pipeline, not over the glyphs"
        );

        // A highlight whose colour the file never states: no colour, but the opacity is still
        // the file's, and the shell draws a neutral tint with it rather than an opaque bar.
        let colourless = &records[2];
        assert_eq!(colourless.color, None);
        assert_eq!(colourless.blend, "multiply");
        let opacity = colourless.opacity.expect("/CA 0.35");
        assert!(
            (opacity - 0.35).abs() < 1e-6,
            "/CA arrives exactly: {opacity}"
        );
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

    /// The outline fixture is three levels deep, and one section has no destination but does
    /// have children. `flatten_outline` has always carried a `depth`; before this fixture the
    /// backend put every bookmark at depth 0, so the sidebar could not number a hierarchy at all.
    #[test]
    fn outline_keeps_three_levels_and_a_section_without_a_page() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/outlined.pdf");
        if !fixture.exists() || !aris_reader_pdfium::is_available() {
            eprintln!("skipping: outline fixture or PDFium unavailable");
            return;
        }
        let engine = ArisEngine::new();
        let document = engine
            .open_document(fixture.display().to_string(), None)
            .expect("open outline fixture");
        let entries = document.outline().expect("outline");

        assert_eq!(
            entries
                .iter()
                .map(|entry| (entry.title.as_str(), entry.depth, entry.page))
                .collect::<Vec<_>>(),
            vec![
                ("Chapter One", 0, Some(0)),
                ("Background", 1, Some(0)),
                ("Prior work", 2, Some(1)),
                ("Chapter Two", 0, None),
                ("Method", 1, Some(1)),
                ("Detail", 2, Some(2)),
                ("Setup", 1, Some(2)),
                ("Chapter Three", 0, Some(2)),
            ],
            "the fixture's outline, depth-first with its real depths"
        );
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

    /// The thumbnail path asks PDFium to burn the file's annotations into the raster; the canvas
    /// path must keep asking for a plain page. `annotated-appearance.pdf`'s highlight carries an
    /// `/AP` (the shape Preview writes) and paints yellow, which the fixture's black text and blue
    /// page border cannot produce.
    #[test]
    fn the_thumbnail_raster_carries_the_files_marks() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/annotated-appearance.pdf");
        if !fixture.exists() || !aris_reader_pdfium::is_available() {
            eprintln!("skipping: annotated fixture or PDFium unavailable");
            return;
        }
        let engine = ArisEngine::new();
        let document = engine
            .open_document(fixture.display().to_string(), None)
            .expect("open fixture");

        let plain = document.rasterize_page(0, 1.0).expect("plain page");
        let marked = document
            .rasterize_page_with_annotations(0, 1.0)
            .expect("thumbnail page");
        assert_eq!(
            (plain.width_px, plain.height_px),
            (marked.width_px, marked.height_px)
        );
        assert_ne!(
            plain.pixels, marked.pixels,
            "the annotated raster must differ from the plain one"
        );

        // BGRA. The yellow highlight covers the first body line; the page's own blue rectangle
        // is at a different height, so limiting the sample to the highlight's box distinguishes
        // the mark from the page artwork. The highlight's view-space box is x 72…460, y 141…156.
        let width = marked.width_px as usize;
        let yellow_in_highlight = |pixels: &[u8]| {
            let mut count = 0;
            for y in 141..=156 {
                for x in 72..=460 {
                    let offset = (y * width + x) * 4;
                    let (b, g, r) = (
                        u16::from(pixels[offset]),
                        u16::from(pixels[offset + 1]),
                        u16::from(pixels[offset + 2]),
                    );
                    if r > 200 && g > 180 && b < 150 {
                        count += 1;
                    }
                }
            }
            count
        };
        assert!(
            yellow_in_highlight(&marked.pixels) > 100,
            "the thumbnail carries the highlight ({} yellow pixels)",
            yellow_in_highlight(&marked.pixels)
        );
        assert_eq!(
            yellow_in_highlight(&plain.pixels),
            0,
            "the canvas raster must stay annotation-free"
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

    // ── Annotation write-back ──────────────────────────────────────────────────────────

    /// A scratch copy of the committed annotated fixture, or `None` when PDFium is absent.
    fn writeback_fixture(name: &str) -> Option<ScratchDir> {
        if !aris_reader_pdfium::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return None;
        }
        let directory = scratch(name);
        let copy = directory.join("source.pdf");
        std::fs::copy(fixture("annotated.pdf"), &copy).expect("copy fixture");
        Some(directory)
    }

    fn zoom_annotation(zoom: f64) -> WriteAnnotationRecord {
        let box_at_zoom = |x: f64, y: f64, width: f64, height: f64| AnnotationQuad {
            x_pt: x * zoom,
            y_pt: y * zoom,
            width_pt: width * zoom,
            height_pt: height * zoom,
        };
        WriteAnnotationRecord {
            id: "33333333-3333-3333-3333-333333333333".to_string(),
            page: 0,
            kind: AnnotationWriteKind::Highlight,
            rect: box_at_zoom(72.0, 141.0, 388.0, 15.0),
            // View space at 100% is page space y-flipped: page [72 686 388 15] on an 842 pt
            // page is view (72, 842 - 686 - 15) = (72, 141).
            quads: vec![box_at_zoom(72.0, 141.0, 388.0, 15.0)],
            ink_paths: Vec::new(),
            line_start: None,
            line_end: None,
            line_arrow: false,
            border_width_pt: 0.0,
            color: AnnotationColorRecord {
                red: 255,
                green: 216,
                blue: 64,
            },
            opacity: 0.4,
            contents: "Saved at an arbitrary zoom.".to_string(),
            author: "Lyra".to_string(),
            modified: "D:20261016213000-07'00'".to_string(),
        }
    }

    fn zoom_stroke(zoom: f64) -> WriteAnnotationRecord {
        let point = |x: f64, y: f64| AnnotationPoint {
            x_pt: x * zoom,
            y_pt: y * zoom,
        };
        let box_at_zoom = |x: f64, y: f64, width: f64, height: f64| AnnotationQuad {
            x_pt: x * zoom,
            y_pt: y * zoom,
            width_pt: width * zoom,
            height_pt: height * zoom,
        };
        WriteAnnotationRecord {
            id: "44444444-4444-4444-4444-444444444444".to_string(),
            page: 0,
            kind: AnnotationWriteKind::Ink,
            // The outer box at view 100%: page [72 600 200 60] on an 842 pt page is
            // view (72, 842 - 600 - 60) = (72, 182), inflated by the stroke's half width.
            rect: box_at_zoom(72.0, 181.0, 201.0, 61.0),
            quads: Vec::new(),
            ink_paths: vec![vec![
                point(73.0, 182.0),
                point(120.0, 220.0),
                point(180.0, 190.0),
                point(272.0, 240.0),
            ]],
            line_start: None,
            line_end: None,
            line_arrow: false,
            border_width_pt: 2.5,
            color: AnnotationColorRecord {
                red: 220,
                green: 40,
                blue: 30,
            },
            opacity: 0.8,
            contents: "Stroked at an arbitrary zoom.".to_string(),
            author: "Lyra".to_string(),
            modified: "D:20261017120000-07'00'".to_string(),
        }
    }

    #[test]
    fn write_back_converts_view_space_at_any_zoom_to_the_same_page_space() {
        let Some(directory) = writeback_fixture("zoom") else {
            return;
        };
        let engine = ArisEngine::new();
        let source = directory.join("source.pdf");
        let document = engine
            .open_document(source.display().to_string(), None)
            .expect("open source");
        assert_eq!(document.annotations().expect("annotations").len(), 7);
        let source_bytes = std::fs::read(&source).expect("source readable");

        assert!(
            document
                .suggested_copy_path()
                .ends_with("source (annotated).pdf"),
            "the suggested name is <name> (annotated).pdf"
        );

        let at_100 = directory.join("at-100.pdf");
        let at_300 = directory.join("at-300.pdf");
        let report_100 = document
            .save_annotations_copy(
                at_100.display().to_string(),
                vec![zoom_annotation(1.0)],
                1.0,
            )
            .expect("save at 100%");
        let report_300 = document
            .save_annotations_copy(
                at_300.display().to_string(),
                vec![zoom_annotation(3.0)],
                3.0,
            )
            .expect("save at 300%");

        assert_eq!(report_100.written_ids, vec![zoom_annotation(1.0).id]);
        assert_eq!(report_100.backup_path, None);
        assert_eq!(report_100.preexisting_annotation_count, 7);
        assert!(report_100.appended_bytes > 0);
        assert!(report_100.source_bytes_preserved);
        assert_eq!(
            std::fs::read(&source).expect("source readable"),
            source_bytes,
            "a copy save leaves the open document untouched"
        );
        assert_eq!(report_300.preexisting_annotation_count, 7);

        // The two saves were made from different view-space geometry and zoom factors. Their
        // page-space output must be identical, which is the promise that a highlight saved at
        // one zoom reloads in the same place at another.
        let page_space = |path: &std::path::Path| {
            let backend = PdfiumBackend::open(path, None).expect("reopen saved copy");
            let annotations = backend.annotations(PageIndex(0)).expect("page annotations");
            annotations
                .into_iter()
                .find(|annotation| annotation.id == "nm:33333333-3333-3333-3333-333333333333")
                .expect("written annotation")
        };
        let first = page_space(&at_100);
        let second = page_space(&at_300);
        assert_eq!(first, second, "zoom must not change page-space geometry");
        assert_eq!(
            first.rect,
            aris_reader_core::Rect::new(72.0, 686.0, 388.0, 15.0)
        );
        assert_eq!(
            first.quads,
            vec![aris_reader_core::Rect::new(72.0, 686.0, 388.0, 15.0)]
        );

        // Reopening through the FFI at "another zoom" is the same file-space geometry: the
        // reader reports view space at 100%, and the canvas scales it. Both saved files agree
        // with the original view box, so the annotation reloads at the same place.
        for path in [&at_100, &at_300] {
            let reopened = engine
                .open_document(path.display().to_string(), None)
                .expect("reopen saved copy");
            let records = reopened.annotations().expect("annotations");
            let ours: Vec<_> = records
                .iter()
                .filter(|record| record.id == "nm:33333333-3333-3333-3333-333333333333")
                .collect();
            assert_eq!(ours.len(), 1, "exactly one copy of the written annotation");
            assert!((ours[0].x_pt - 72.0).abs() < 1e-6);
            assert!((ours[0].y_pt - 141.0).abs() < 1e-6);
            assert!((ours[0].width_pt - 388.0).abs() < 1e-6);
            assert!((ours[0].height_pt - 15.0).abs() < 1e-6);
            assert_eq!(
                ours[0].contents.as_deref(),
                Some("Saved at an arbitrary zoom.")
            );
            assert_eq!(ours[0].author.as_deref(), Some("Lyra"));
            assert_eq!(ours[0].blend, "multiply");
        }

        let bad_zoom = document.save_annotations_copy(
            directory.join("bad.pdf").display().to_string(),
            vec![zoom_annotation(1.0)],
            0.0,
        );
        assert!(bad_zoom.is_err(), "a zero zoom is refused before any write");

        let _ = std::fs::remove_dir_all(directory);
    }

    #[test]
    fn stroke_write_back_converts_view_space_at_any_zoom_to_the_same_page_space() {
        let Some(directory) = writeback_fixture("stroke-zoom") else {
            return;
        };
        let engine = ArisEngine::new();
        let source = directory.join("source.pdf");
        let document = engine
            .open_document(source.display().to_string(), None)
            .expect("open source");
        let at_100 = directory.join("stroke-100.pdf");
        let at_300 = directory.join("stroke-300.pdf");
        document
            .save_annotations_copy(at_100.display().to_string(), vec![zoom_stroke(1.0)], 1.0)
            .expect("save stroke at 100%");
        document
            .save_annotations_copy(at_300.display().to_string(), vec![zoom_stroke(3.0)], 3.0)
            .expect("save stroke at 300%");

        let page_space = |path: &std::path::Path| {
            let backend = PdfiumBackend::open(path, None).expect("reopen saved copy");
            backend
                .annotations(PageIndex(0))
                .expect("page annotations")
                .into_iter()
                .find(|annotation| annotation.id == "nm:44444444-4444-4444-4444-444444444444")
                .expect("written stroke")
        };
        let first = page_space(&at_100);
        let second = page_space(&at_300);
        assert_eq!(
            first, second,
            "zoom must not change the stroke's page-space points"
        );
        assert_eq!(first.kind, aris_reader_core::RawAnnotationKind::Ink);
        assert_eq!(first.ink_paths.len(), 1);
        let expected = [
            (73.0, 182.0),
            (120.0, 220.0),
            (180.0, 190.0),
            (272.0, 240.0),
        ];
        for (point, (x, y)) in first.ink_paths[0].iter().zip(expected) {
            // The view points above are page-space top-left; the writer's inverse flips them
            // back into PDF page space, so compare the y flip explicitly.
            assert!((point.x - x).abs() < 0.01, "{point:?} vs {x}");
            assert!((point.y - (842.0 - y)).abs() < 0.01, "{point:?} vs {y}");
        }
        assert_eq!(first.border_width, Some(2.5));
        assert!((first.opacity.expect("opacity") - 0.8).abs() < 0.01);
        let _ = std::fs::remove_dir_all(directory);
    }

    #[test]
    fn replacing_the_fixture_reports_a_verified_backup_and_reopens_once() {
        let Some(directory) = writeback_fixture("replace") else {
            return;
        };
        let engine = ArisEngine::new();
        let source = directory.join("source.pdf");
        let document = engine
            .open_document(source.display().to_string(), None)
            .expect("open source");
        let original = std::fs::read(&source).expect("source readable");

        // A next-open report can only be produced from a leftover temporary, and must not
        // change the document.
        let stale = directory.join("source.pdf.lyra-save-42-1.tmp");
        std::fs::write(&stale, b"partial").expect("write stale temp");
        let note = document
            .interrupted_save_note()
            .expect("interrupted save is reported");
        assert!(note.contains("interrupted"), "{note}");
        std::fs::remove_file(&stale).expect("remove stale temp");
        assert!(document.interrupted_save_note().is_none());

        let report = document
            .replace_with_annotations(vec![zoom_annotation(1.0)], 1.0)
            .expect("replace original");
        let backup = report.backup_path.expect("backup path");
        let backup_bytes = std::fs::read(&backup).expect("backup readable");
        assert_eq!(
            backup_bytes, original,
            "the backup is byte-identical to the original"
        );
        assert!(
            document.annotations().is_err(),
            "reads from the pre-replacement document are refused until the shell reopens it"
        );

        let reopened = engine
            .open_document(source.display().to_string(), None)
            .expect("reopen replaced source");
        let records = reopened.annotations().expect("annotations");
        assert_eq!(
            records.len(),
            8,
            "the seven pre-existing content annotations plus the new one"
        );
        assert_eq!(
            records
                .iter()
                .filter(|record| record.id == "nm:33333333-3333-3333-3333-333333333333")
                .count(),
            1,
            "the saved annotation appears exactly once"
        );
        assert!(
            std::fs::read(&source)
                .expect("replaced source")
                .starts_with(&original),
            "the replaced file still begins with the original bytes"
        );

        let _ = std::fs::remove_dir_all(directory);
    }
}
