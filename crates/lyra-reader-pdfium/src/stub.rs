//! Stub backend, compiled only with `--no-default-features`.
//!
//! It exists so that the workspace still builds on machines (or CI targets)
//! without the PDFium dynamic library. Every method reports the task that will
//! implement it, mirroring the real backend's error surface.

use lyra_reader_core::{
    DocumentBackend, ErrorCode, LinkInfo, LyraReaderError, OutlineNode, PageIndex, PageInfo,
    RasterRequest, RasterTile, RawAnnotation, RawTextPage, Result,
};
use std::path::Path;

/// Placeholder for [`crate::PdfiumBackend`] when the `pdfium` feature is off.
pub struct PdfiumBackend {
    _private: (),
}

impl PdfiumBackend {
    /// Always fails: this build has no PDFium backend compiled in.
    pub fn open(path: &Path, _password: Option<&str>) -> Result<Self> {
        Err(LyraReaderError::new(
            ErrorCode::BackendUnavailable,
            "PDFium support is not compiled in",
        )
        .with_detail(format!(
            "path: {}; rebuild with the default `pdfium` feature",
            path.display()
        )))
    }
}

impl DocumentBackend for PdfiumBackend {
    fn page_count(&self) -> u32 {
        0
    }

    fn page_info(&self, _page: PageIndex) -> Result<PageInfo> {
        Err(LyraReaderError::not_implemented(
            "PdfiumBackend::page_info (T1.3)",
        ))
    }

    fn outline(&self) -> Result<Vec<OutlineNode>> {
        Err(LyraReaderError::not_implemented(
            "PdfiumBackend::outline (T2.4)",
        ))
    }

    fn links(&self, _page: PageIndex) -> Result<Vec<LinkInfo>> {
        Err(LyraReaderError::not_implemented(
            "PdfiumBackend::links (T4.1)",
        ))
    }

    fn raw_text_page(&self, _page: PageIndex) -> Result<RawTextPage> {
        Err(LyraReaderError::not_implemented(
            "PdfiumBackend::raw_text_page (T2.1)",
        ))
    }

    fn rasterize(&self, _request: &RasterRequest) -> Result<RasterTile> {
        Err(LyraReaderError::not_implemented(
            "PdfiumBackend::rasterize (T1.3)",
        ))
    }

    fn annotations(&self, _page: PageIndex) -> Result<Vec<RawAnnotation>> {
        Err(LyraReaderError::not_implemented(
            "PdfiumBackend::annotations (T3.2)",
        ))
    }

    fn is_encrypted(&self) -> bool {
        false
    }

    fn is_tagged(&self) -> bool {
        false
    }
}
