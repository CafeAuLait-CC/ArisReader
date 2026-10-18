//! PDFium backend: the first implementation of [`aris_reader_core::DocumentBackend`].
//!
//! Task map (see the task list in the local design docs):
//!
//! | Task | Scope | Status |
//! | --- | --- | --- |
//! | T0.7 | load a document, rasterize a page, write a PNG through the CLI | done |
//! | T1.3 | tile/region rasterization, per-thread document copies, failure placeholders | pending |
//! | T2.1 | text page (per-character boxes, structure tree) | pending |
//! | T2.4 | outline / bookmarks | pending |
//! | T3.2 | annotation **read** (see `annotations.rs`); write, forms, incremental save | done |
//! | T3.9 | page operations: rotate, delete, reorder, insert blank, extract (see `page_ops.rs`) | done |
//! | T4.1 | link enumeration and destinations | pending |
//!
//! # Reading annotations
//!
//! [`annotations::AnnotationReader`] reads the annotations a document already contains. It owns a
//! second `FPDF_DOCUMENT` handle because the `/BM` (blend mode) and `/CA` (opacity) keys that
//! decide how a highlight must be drawn are not reachable through `pdfium-render`'s annotation
//! wrappers; the module docs say exactly which accessor is used for which field.
//!
//! # Threading
//!
//! PDFium itself is **not thread-safe**, and its authors recommend parallel
//! *processing* rather than multithreading. Note that `pdfium-render`'s
//! `thread_safe` feature does **not** serialise calls behind a global mutex (an
//! earlier assumption of ours); it only adds `unsafe impl Send/Sync` for handle
//! types. The safety story therefore stays ours:
//!
//! * one `PdfDocument` per raster thread (a "document copy"), never shared
//!   concurrently — see `docs/02-architecture.md` §3;
//! * the loaded library bindings are process-global and immutable, which is what
//!   makes the `OnceLock` in `backend` sound.
//!
//! # Loading the dynamic library
//!
//! Nothing is linked at build time: [`PdfiumBackend::open`] resolves the library
//! at runtime through [`library_candidates`], in this order:
//!
//! 1. `ARIS_READER_PDFIUM_PATH` (explicit override, e.g. a custom build);
//! 2. `<repo>/vendor/pdfium/lib` (development layout, filled by `scripts/fetch-pdfium.sh`);
//! 3. the bare library name, which the OS loader resolves through the executable's
//!    rpath (`@executable_path/../Frameworks`) when running from `ArisReader.app`.

#[cfg(feature = "pdfium")]
mod annotations;
#[cfg(feature = "pdfium")]
mod backend;
#[cfg(feature = "pdfium")]
mod page_ops;
#[cfg(not(feature = "pdfium"))]
mod stub;
#[cfg(feature = "pdfium")]
mod writeback;
#[cfg(feature = "pdfium")]
mod xmp;

#[cfg(feature = "pdfium")]
pub use annotations::{AnnotationAppender, AnnotationReader, WriteAnnotation, WriteAnnotationKind};
#[cfg(feature = "pdfium")]
pub use backend::{
    PdfiumBackend, destination_region_view_space as destination_view_rect, library_candidates,
};
#[cfg(feature = "pdfium")]
pub use page_ops::{
    PageOperation, PageOperationReport, apply_page_operation, extract_pages, publish_edited_copy,
    replace_original_with_edit,
};
#[cfg(not(feature = "pdfium"))]
pub use stub::PdfiumBackend;
#[cfg(feature = "pdfium")]
pub use writeback::{
    SaveMode, SaveReport, cleanup_interrupted_save_temporaries, interrupted_save_note,
    interrupted_save_temporaries, save_annotated_pdf, suggested_copy_path,
};

/// Environment variable that overrides the PDFium library location.
pub const PDFIUM_PATH_ENV: &str = "ARIS_READER_PDFIUM_PATH";

/// Returns `true` when the PDFium dynamic library can be located and loaded.
///
/// This performs a real load attempt (cached process-wide by the loader), so it
/// is cheap to call repeatedly but not free the first time.
pub fn is_available() -> bool {
    #[cfg(feature = "pdfium")]
    {
        backend::pdfium_instance().is_ok()
    }
    #[cfg(not(feature = "pdfium"))]
    {
        false
    }
}

/// Human-readable description of the build-time backend selection, used by
/// `--version` output and diagnostics.
pub fn backend_description() -> &'static str {
    #[cfg(feature = "pdfium")]
    {
        "pdfium (dynamic, loaded at runtime)"
    }
    #[cfg(not(feature = "pdfium"))]
    {
        "stub (built with --no-default-features)"
    }
}

#[cfg(all(test, feature = "pdfium"))]
mod link_border_tests;

#[cfg(all(test, feature = "pdfium"))]
mod test_support;

#[cfg(feature = "pdfium")]
mod link_borders;
