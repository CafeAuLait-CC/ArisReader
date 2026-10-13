//! PDFium backend: the first implementation of `aris_reader_core::DocumentBackend`.
//!
//! Currently a **skeleton**; see `docs/08-tasks.md` for the concrete work:
//!
//! | Task | Scope |
//! | --- | --- |
//! | T1.3 | Loading, page info, rasterization (BGRA + stride + render flags), per-thread document copy pool |
//! | T0.7 | `aris-reader-cli render` smoke test (symbol compatibility check: bindings 7881 vs released build 8100) |
//! | T3.2 | Annotation read/write (`FPDFAnnot_*`), forms, incremental save |
//! | T2.1 | Text page (`FPDFText_*` per-character boxes + structure-tree reading order) |
//!
//! # Threading model (critical)
//!
//! PDFium is not thread-safe; the official guidance is "parallel processing" rather than multithreading. Strategy:
//!
//! - **Baseline**: the `thread_safe` feature of `pdfium-render` serializes every call behind one global lock (correct, but zero parallelism).
//! - **Default**: each raster thread keeps its own independent `FPDF_DOCUMENT` copy (copy pool, LRU cap
//!   [`aris_reader_core::EngineConfig::max_document_copies`]), which gives true parallel rasterization.
//!
//! See `docs/02-architecture.md` §3 for details.

#![cfg_attr(not(feature = "pdfium"), allow(dead_code))]

use aris_reader_core::{
    ArisError, DocumentBackend, ErrorCode, LinkInfo, OutlineNode, PageIndex, PageInfo,
    RasterRequest, RasterTile, RawTextPage, Result,
};
use std::path::Path;

/// Source the dynamic library is loaded from (determines the `dlopen` search strategy).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LibrarySource {
    /// Load from the app bundle's `Contents/Frameworks` (`@rpath`) — the production path.
    Rpath,
    /// Load from the path named by the `ARIS_READER_PDFIUM_PATH` environment variable — the development/CLI path.
    EnvPath,
}

/// PDFium backend handle.
///
/// TODO(T1.3): will own the copy pool, the page size cache and the `FPDF_DOCUMENT` handle.
pub struct PdfiumBackend {
    _path: std::path::PathBuf,
}

impl PdfiumBackend {
    /// Open a document. If the document is encrypted and `password` is `None`, returns [`ErrorCode::Encrypted`].
    pub fn open(path: &Path, _password: Option<&str>) -> Result<Self> {
        // TODO(T1.3): FPDF_LoadDocument / FPDF_LoadMemDocument + FPDF_GetLastError mapping
        let _ = path;
        Err(ArisError::new(
            ErrorCode::BackendUnavailable,
            "PDFium backend not implemented yet (see tasks T0.7 / T1.3)",
        ))
    }
}

impl DocumentBackend for PdfiumBackend {
    fn page_count(&self) -> u32 {
        0
    }

    fn page_info(&self, _page: PageIndex) -> Result<PageInfo> {
        Err(ArisError::not_implemented(
            "PdfiumBackend::page_info (T1.3)",
        ))
    }

    fn outline(&self) -> Result<Vec<OutlineNode>> {
        Err(ArisError::not_implemented("PdfiumBackend::outline (T2.4)"))
    }

    fn links(&self, _page: PageIndex) -> Result<Vec<LinkInfo>> {
        Err(ArisError::not_implemented("PdfiumBackend::links (T4.1)"))
    }

    fn raw_text_page(&self, _page: PageIndex) -> Result<RawTextPage> {
        Err(ArisError::not_implemented(
            "PdfiumBackend::raw_text_page (T2.1)",
        ))
    }

    fn rasterize(&self, _request: &RasterRequest) -> Result<RasterTile> {
        Err(ArisError::not_implemented(
            "PdfiumBackend::rasterize (T1.3)",
        ))
    }

    fn is_encrypted(&self) -> bool {
        false
    }

    fn is_tagged(&self) -> bool {
        false
    }
}

/// Whether the PDFium dynamic library can be found and loaded at runtime.
///
/// TODO(T0.6): implement the `dlopen` probe (`@rpath/libpdfium.dylib` → `ARIS_READER_PDFIUM_PATH`).
pub fn is_available() -> bool {
    false
}
