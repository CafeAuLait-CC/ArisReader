//! Reading the annotations a PDF already contains, through PDFium's C API.
//!
//! # Why this module talks to `FPDFAnnot_*` directly
//!
//! `pdfium-render` wraps annotations, but its two accessors that matter most here are narrower
//! than the C API:
//!
//! * `PdfPageAnnotationCommon::contents()`/`creator()`/`modification_date()` go through
//!   `FPDFAnnot_GetStringValue`, and the wrapper returns `None` unless
//!   `FPDFAnnot_GetValueType` reports `FPDF_OBJECT_STRING`. `/BM` is a **name**, so the blend
//!   mode — the one key that decides whether a highlight is multiplied into the page or painted
//!   over it — is invisible through it.
//! * `/CA` (constant opacity) is a **number**, and no wrapper accessor reads annotation numbers
//!   at all.
//!
//! Both are plain, documented parts of PDFium's public ABI, so this module resolves the dozen
//! entry points it needs from the same dynamic library the rest of the backend uses and reads the
//! annotation dictionary directly. Everything it returns is a neutral [`RawAnnotation`] in page
//! space; the FFI layer applies the single Y-flip.
//!
//! Two PDFium behaviours found by measurement (2026-10-15, fixture `tests/fixtures/annotated.pdf`,
//! probed both through this module and with a ctypes harness against the same library) shape the
//! code below:
//!
//! * `FPDFAnnot_GetColor` returns `TRUE` and hands back **black** for an annotation with no `/C`
//!   at all (a sticky note is the normal case). Its return value alone therefore says nothing;
//!   the colour is only reported when `FPDFAnnot_HasKey(annot, "C")` is true.
//! * The alpha channel `FPDFAnnot_GetColor` writes is `/CA` scaled to 0-255 (a `/CA 0.5`
//!   highlight comes back as 127), so the colour and the opacity agree. `/CA` is still read on
//!   its own, because the caller wants the file's own number, not a rounded byte.
//!
//! # Threading
//!
//! Every call here happens under the process-wide `PDFIUM_LOCK` held by
//! [`crate::backend::PdfiumBackend`]; PDFium's own annotation API is not thread-safe, and the
//! `Send`/`Sync` markers on [`AnnotationReader`] are only sound because of that lock.

// The workspace warns on `unsafe_code` by default (`Cargo.toml`, `[workspace.lints.rust]`). This
// module is the one place outside the FFI crate that needs it: PDFium is a C library, and the two
// keys that decide how a highlight must be drawn (`/BM`, `/CA`) are not reachable through the safe
// wrapper. Every block below carries a SAFETY comment naming what it relies on, and no other module
// gains the exemption.
#![allow(unsafe_code)]

use aris_reader_core::{
    AnnotationBlend, ArisError, ErrorCode, PageIndex, RawAnnotation, RawAnnotationColor,
    RawAnnotationKind, Rect, Result,
};
use libloading::Library;
use std::ffi::{CStr, CString, c_char, c_int, c_uint, c_ulong, c_void};
use std::path::Path;
use std::sync::OnceLock;

/// Opaque PDFium handles (see `fpdfview.h`).
type FpdfDocument = *mut c_void;
type FpdfPage = *mut c_void;
type FpdfAnnotation = *mut c_void;

/// `FS_RECTF`: note the field order — PDFium writes `left, top, right, bottom`, not the
/// left/bottom/right/top order every other rectangle in this workspace uses.
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct FsRectF {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
}

/// `FS_QUADPOINTSF`: the four corners of one quadrilateral, page space.
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct FsQuadPointsF {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    x3: f32,
    y3: f32,
    x4: f32,
    y4: f32,
}

// `FPDF_ANNOTATION_SUBTYPE` values (fpdf_annot.h). Named because the numbers are meaningless at
// the call site, and because a wrong one would silently mislabel every annotation in a document.
const ANNOT_TEXT: c_ulong = 1;
const ANNOT_FREETEXT: c_ulong = 3;
const ANNOT_LINE: c_ulong = 4;
const ANNOT_SQUARE: c_ulong = 5;
const ANNOT_CIRCLE: c_ulong = 6;
const ANNOT_POLYGON: c_ulong = 7;
const ANNOT_POLYLINE: c_ulong = 8;
const ANNOT_HIGHLIGHT: c_ulong = 9;
const ANNOT_UNDERLINE: c_ulong = 10;
const ANNOT_SQUIGGLY: c_ulong = 11;
const ANNOT_STRIKEOUT: c_ulong = 12;
const ANNOT_STAMP: c_ulong = 13;
const ANNOT_CARET: c_ulong = 14;
const ANNOT_INK: c_ulong = 15;
const ANNOT_POPUP: c_ulong = 16;
const ANNOT_FILEATTACHMENT: c_ulong = 17;
const ANNOT_SOUND: c_ulong = 18;
const ANNOT_MOVIE: c_ulong = 19;
const ANNOT_WIDGET: c_ulong = 20;
const ANNOT_SCREEN: c_ulong = 21;
const ANNOT_PRINTERMARK: c_ulong = 22;
const ANNOT_TRAPNET: c_ulong = 23;
const ANNOT_WATERMARK: c_ulong = 24;
const ANNOT_THREED: c_ulong = 25;
const ANNOT_RICHMEDIA: c_ulong = 26;
const ANNOT_XFAWIDGET: c_ulong = 27;
const ANNOT_REDACT: c_ulong = 28;

/// `FPDFANNOT_COLORTYPE_Color` — the `/C` entry, which for every markup annotation is *the*
/// colour (a highlight's fill, an underline's stroke).
const COLORTYPE_COLOR: c_int = 0;

/// `FPDF_ANNOT_FLAG_*` (fpdf_annot.h): an annotation carrying one of these is not meant to be
/// seen, and drawing it would contradict the file.
const FLAG_INVISIBLE: c_int = 1 << 0;
const FLAG_HIDDEN: c_int = 1 << 1;
const FLAG_NOVIEW: c_int = 1 << 5;

/// The PDFium entry points this module uses, resolved once per process.
struct Api {
    /// Keeps the dynamic library loaded for as long as the function pointers live.
    _library: Library,
    load_document: unsafe extern "C" fn(*const c_char, *const c_char) -> FpdfDocument,
    close_document: unsafe extern "C" fn(FpdfDocument),
    load_page: unsafe extern "C" fn(FpdfDocument, c_int) -> FpdfPage,
    close_page: unsafe extern "C" fn(FpdfPage),
    get_annot_count: unsafe extern "C" fn(FpdfPage) -> c_int,
    get_annot: unsafe extern "C" fn(FpdfPage, c_int) -> FpdfAnnotation,
    close_annot: unsafe extern "C" fn(FpdfAnnotation),
    get_subtype: unsafe extern "C" fn(FpdfAnnotation) -> c_ulong,
    get_rect: unsafe extern "C" fn(FpdfAnnotation, *mut FsRectF) -> c_int,
    count_attachment_points: unsafe extern "C" fn(FpdfAnnotation) -> c_ulong,
    get_attachment_points:
        unsafe extern "C" fn(FpdfAnnotation, c_ulong, *mut FsQuadPointsF) -> c_int,
    get_color: unsafe extern "C" fn(
        FpdfAnnotation,
        c_int,
        *mut c_uint,
        *mut c_uint,
        *mut c_uint,
        *mut c_uint,
    ) -> c_int,
    has_key: unsafe extern "C" fn(FpdfAnnotation, *const c_char) -> c_int,
    get_string_value:
        unsafe extern "C" fn(FpdfAnnotation, *const c_char, *mut u16, c_ulong) -> c_ulong,
    get_number_value: unsafe extern "C" fn(FpdfAnnotation, *const c_char, *mut f32) -> c_int,
    get_flags: unsafe extern "C" fn(FpdfAnnotation) -> c_int,
}

/// The resolved API, or `None` when this PDFium build does not export it.
///
/// A `OnceLock` and not a `Result`: the answer cannot change during a process, and a PDFium
/// without the `FPDFAnnot_*` family (a barebones build) must fail the same way every time.
static API: OnceLock<Option<&'static Api>> = OnceLock::new();

/// Resolves the annotation entry points from `library`.
///
/// # Safety
///
/// The caller must have loaded a PDFium-compatible library; the signatures below are the ones
/// `fpdf_annot.h` declares, and getting one wrong would be undefined behaviour. They are
/// transcribed from the vendored header (`vendor/pdfium/include/fpdf_annot.h`).
unsafe fn resolve(library: Library) -> Option<Api> {
    /// Copies one function pointer out of the library, or gives up on the whole API.
    unsafe fn symbol<T: Copy>(library: &Library, name: &[u8]) -> Option<T> {
        // SAFETY: `T` is always one of the `extern "C" fn` types declared in `Api`, matching the
        // exported PDFium symbol of that name.
        unsafe { library.get::<T>(name).ok().map(|symbol| *symbol) }
    }

    // SAFETY (every `symbol` call below): each name is the exported PDFium symbol for the
    // `extern "C" fn` type declared next to it in `Api`, transcribed from `fpdf_annot.h`.
    let api = Api {
        load_document: unsafe { symbol(&library, b"FPDF_LoadDocument\0")? },
        close_document: unsafe { symbol(&library, b"FPDF_CloseDocument\0")? },
        load_page: unsafe { symbol(&library, b"FPDF_LoadPage\0")? },
        close_page: unsafe { symbol(&library, b"FPDF_ClosePage\0")? },
        get_annot_count: unsafe { symbol(&library, b"FPDFPage_GetAnnotCount\0")? },
        get_annot: unsafe { symbol(&library, b"FPDFPage_GetAnnot\0")? },
        close_annot: unsafe { symbol(&library, b"FPDFPage_CloseAnnot\0")? },
        get_subtype: unsafe { symbol(&library, b"FPDFAnnot_GetSubtype\0")? },
        get_rect: unsafe { symbol(&library, b"FPDFAnnot_GetRect\0")? },
        count_attachment_points: unsafe { symbol(&library, b"FPDFAnnot_CountAttachmentPoints\0")? },
        get_attachment_points: unsafe { symbol(&library, b"FPDFAnnot_GetAttachmentPoints\0")? },
        get_color: unsafe { symbol(&library, b"FPDFAnnot_GetColor\0")? },
        has_key: unsafe { symbol(&library, b"FPDFAnnot_HasKey\0")? },
        get_string_value: unsafe { symbol(&library, b"FPDFAnnot_GetStringValue\0")? },
        get_number_value: unsafe { symbol(&library, b"FPDFAnnot_GetNumberValue\0")? },
        get_flags: unsafe { symbol(&library, b"FPDFAnnot_GetFlags\0")? },
        _library: library,
    };
    Some(api)
}

/// Loads (once) the annotation entry points from the first library candidate that resolves them.
///
/// This is a **second** handle on the same dynamic library PDFium rendering already loaded
/// (`dlopen` reference-counts, so nothing is loaded twice). The facade in
/// [`crate::backend::pdfium_instance`] keeps its bindings to itself, and the alternative —
/// re-deriving a page handle from it — is not possible through its public API.
fn api() -> Option<&'static Api> {
    API.get_or_init(|| {
        for candidate in crate::backend::library_candidates() {
            // SAFETY: `Library::new` is unsafe because loading arbitrary code is; these paths are
            // the same ones the PDFium facade already loaded, or an explicit user override.
            let Ok(library) = (unsafe { Library::new(candidate.as_os_str()) }) else {
                continue;
            };
            // SAFETY: the library at these paths is PDFium, whose annotation ABI is fixed by
            // `fpdf_annot.h` (vendored under `vendor/pdfium/include`).
            if let Some(api) = unsafe { resolve(library) } {
                // Leaked on purpose: the resolved entry points live as long as the process, and
                // the library handle inside the `Api` keeps the code they point at mapped.
                return Some(&*Box::leak(Box::new(api)));
            }
        }
        None
    })
    .as_ref()
    .copied()
}

/// Reads annotations from one open document.
///
/// Owns its own `FPDF_DOCUMENT`: PDFium has no way to hand out the handle behind the
/// `pdfium-render` facade, and re-opening the same file is how this workspace already gives each
/// worker its own handle ([`crate::backend::PdfiumBackend::reopen`]). The caller must hold
/// `PDFIUM_LOCK` for every method here.
pub struct AnnotationReader {
    api: &'static Api,
    document: FpdfDocument,
}

// SAFETY: raw PDFium handles are not thread-safe, and these markers are only sound because every
// call site in this crate serialises on the process-wide `PDFIUM_LOCK` (see the module docs).
unsafe impl Send for AnnotationReader {}
unsafe impl Sync for AnnotationReader {}

impl AnnotationReader {
    /// Opens `path` for annotation reading, with the same `password` the document was opened with.
    ///
    /// Fails when this PDFium build does not export the `FPDFAnnot_*` family, or when the document
    /// cannot be opened a second time — both are reported to the caller rather than silently
    /// turning into "this document has no annotations".
    pub fn open(path: &Path, password: Option<&str>) -> Result<Self> {
        let Some(api) = api() else {
            return Err(ArisError::new(
                ErrorCode::BackendUnavailable,
                "this PDFium build does not export the annotation API",
            )
            .with_detail("missing one of the FPDFAnnot_* / FPDFPage_*Annot* entry points"));
        };

        let path = CString::new(path.to_string_lossy().as_bytes()).map_err(|_| {
            ArisError::new(
                ErrorCode::InvalidArgument,
                "the document path contains a NUL byte",
            )
        })?;
        let password = password.map(CString::new).transpose().map_err(|_| {
            ArisError::new(
                ErrorCode::InvalidArgument,
                "the password contains a NUL byte",
            )
        })?;

        // SAFETY: `path`/`password` are NUL-terminated and outlive the call; the library is
        // initialised because `PdfiumBackend::open` loads the facade before constructing this.
        let document = unsafe {
            (api.load_document)(
                path.as_ptr(),
                password
                    .as_ref()
                    .map_or(std::ptr::null(), |value| value.as_ptr()),
            )
        };
        if document.is_null() {
            return Err(ArisError::new(
                ErrorCode::CorruptDocument,
                "PDFium could not open the document a second time for annotation reading",
            )
            .with_detail(format!("path: {}", path.to_string_lossy())));
        }

        Ok(Self { api, document })
    }

    /// Every annotation on `page`, in the order the document stores them.
    ///
    /// Annotations this build cannot load (a damaged one, or a page that will not open) are
    /// skipped rather than failing the whole page: a reader must not refuse to show the other
    /// twenty highlights because the twenty-first is broken.
    pub fn page(&self, page: PageIndex) -> Result<Vec<RawAnnotation>> {
        let index = c_int::try_from(page.get()).map_err(|_| {
            ArisError::new(
                ErrorCode::InvalidArgument,
                format!("page {} is out of range for PDFium", page.get()),
            )
        })?;

        // SAFETY: the document handle is live for as long as `self`, and every call here is
        // serialised by the caller's `PDFIUM_LOCK`.
        let page_handle = unsafe { (self.api.load_page)(self.document, index) };
        if page_handle.is_null() {
            return Err(ArisError::new(
                ErrorCode::RenderFailed,
                format!("PDFium could not load page {}", page.get()),
            ));
        }

        let mut annotations = Vec::new();
        // SAFETY: `page_handle` is a loaded page and stays valid until `close_page` below.
        let count = unsafe { (self.api.get_annot_count)(page_handle) }.max(0);
        for slot in 0..count {
            // SAFETY: `slot` is inside the count just read.
            let handle = unsafe { (self.api.get_annot)(page_handle, slot) };
            if handle.is_null() {
                continue;
            }
            if let Some(annotation) = self.read(handle, page) {
                annotations.push(annotation);
            }
            // SAFETY: the handle came from `get_annot` and is not used afterwards.
            unsafe { (self.api.close_annot)(handle) };
        }
        // SAFETY: the handle came from `load_page` and holds no borrowed data after this point.
        unsafe { (self.api.close_page)(page_handle) };

        Ok(annotations)
    }

    /// Reads one annotation, or `None` when even its `/Rect` is unreadable.
    fn read(&self, handle: FpdfAnnotation, page: PageIndex) -> Option<RawAnnotation> {
        let mut raw_rect = FsRectF::default();
        // SAFETY: `handle` is a live annotation; `raw_rect` is a valid out-pointer.
        if unsafe { (self.api.get_rect)(handle, &mut raw_rect) } == 0 {
            return None;
        }
        let rect = Rect::new(
            f64::from(raw_rect.left),
            f64::from(raw_rect.bottom),
            f64::from(raw_rect.right - raw_rect.left),
            f64::from(raw_rect.top - raw_rect.bottom),
        );

        // SAFETY: `handle` is a live annotation for the duration of `read`.
        let subtype = unsafe { (self.api.get_subtype)(handle) };
        let kind = subtype_kind(subtype);
        let quads = self.quad_points(handle);
        let color = self.color(handle);
        let opacity = self.opacity(handle);
        let blend = self
            .string(handle, c"BM")
            .map_or(AnnotationBlend::Normal, |name| {
                AnnotationBlend::from_pdf_name(&name)
            });
        // SAFETY: `handle` is live; the call reads one integer flag set.
        let flags = unsafe { (self.api.get_flags)(handle) };
        let hidden = flags & (FLAG_INVISIBLE | FLAG_HIDDEN | FLAG_NOVIEW) != 0;

        Some(RawAnnotation {
            page,
            kind,
            rect,
            quads,
            color,
            opacity,
            blend,
            contents: self.string(handle, c"Contents"),
            author: self.string(handle, c"T"),
            modified: self.string(handle, c"M"),
            visible: !hidden,
        })
    }

    /// `/QuadPoints` as bounding rectangles.
    ///
    /// PDFium hands back the four corners of each quadrilateral. This application draws
    /// axis-aligned boxes (the same shape a text selection produces), so each quad is reduced to
    /// its bounding rectangle — exact for the horizontal text these annotations mark up, and
    /// deliberately not an approximation of a rotation the canvas cannot draw anyway.
    fn quad_points(&self, handle: FpdfAnnotation) -> Vec<Rect> {
        // SAFETY: `handle` is live; the count is the length of the annotation's quad list.
        let count = unsafe { (self.api.count_attachment_points)(handle) };
        let mut quads = Vec::new();
        for index in 0..count {
            let mut quad = FsQuadPointsF::default();
            // SAFETY: `index` is inside the count just read; `quad` is a valid out-pointer.
            if unsafe { (self.api.get_attachment_points)(handle, index, &mut quad) } == 0 {
                continue;
            }
            let xs = [quad.x1, quad.x2, quad.x3, quad.x4];
            let ys = [quad.y1, quad.y2, quad.y3, quad.y4];
            let left = xs.iter().copied().fold(f32::INFINITY, f32::min);
            let right = xs.iter().copied().fold(f32::NEG_INFINITY, f32::max);
            let bottom = ys.iter().copied().fold(f32::INFINITY, f32::min);
            let top = ys.iter().copied().fold(f32::NEG_INFINITY, f32::max);
            quads.push(Rect::new(
                f64::from(left),
                f64::from(bottom),
                f64::from(right - left),
                f64::from(top - bottom),
            ));
        }
        quads
    }

    /// `/C`, but only when the file actually carries it.
    ///
    /// `FPDFAnnot_GetColor` answers `TRUE` with black for an annotation that has no colour at all
    /// (measured; see the module docs), so its result is not trusted on its own — a sticky note
    /// must be reported as "no colour", not as black.
    fn color(&self, handle: FpdfAnnotation) -> Option<RawAnnotationColor> {
        if !self.has_key(handle, c"C") {
            return None;
        }
        let (mut red, mut green, mut blue, mut alpha) = (0 as c_uint, 0, 0, 0);
        // SAFETY: `handle` is live and the four out-pointers are valid.
        let ok = unsafe {
            (self.api.get_color)(
                handle,
                COLORTYPE_COLOR,
                &mut red,
                &mut green,
                &mut blue,
                &mut alpha,
            )
        };
        if ok == 0 {
            return None;
        }
        Some(RawAnnotationColor {
            red: red.min(255) as u8,
            green: green.min(255) as u8,
            blue: blue.min(255) as u8,
        })
    }

    /// `/CA`, the constant opacity, when the file states one.
    fn opacity(&self, handle: FpdfAnnotation) -> Option<f64> {
        if !self.has_key(handle, c"CA") {
            return None;
        }
        let mut value = 0.0f32;
        // SAFETY: `handle` is live and `value` is a valid out-pointer.
        let ok = unsafe { (self.api.get_number_value)(handle, c"CA".as_ptr(), &mut value) };
        if ok == 0 || !value.is_finite() {
            return None;
        }
        Some(f64::from(value.clamp(0.0, 1.0)))
    }

    fn has_key(&self, handle: FpdfAnnotation, key: &CStr) -> bool {
        // SAFETY: `handle` is live and `key` is NUL-terminated.
        unsafe { (self.api.has_key)(handle, key.as_ptr()) != 0 }
    }

    /// A dictionary string, decoded from the UTF-16LE that `FPDFAnnot_GetStringValue` writes.
    ///
    /// The call is the documented two-step: a null buffer returns the length **in bytes,
    /// including the two-byte terminator**, and the second call fills a buffer of that size. The
    /// terminating unit is dropped from the decoded string; a length of 2 means "empty".
    fn string(&self, handle: FpdfAnnotation, key: &CStr) -> Option<String> {
        // SAFETY: `handle` is live; a null buffer with length 0 is the documented way to ask for
        // the required length and touches no memory.
        let byte_len = unsafe {
            (self.api.get_string_value)(handle, key.as_ptr(), std::ptr::null_mut(), 0) as usize
        };
        if byte_len <= 2 {
            return None;
        }

        let mut buffer = vec![0u16; byte_len.div_ceil(2)];
        // SAFETY: `buffer` has room for `byte_len` bytes, which is what the call writes.
        let written = unsafe {
            (self.api.get_string_value)(
                handle,
                key.as_ptr(),
                buffer.as_mut_ptr(),
                byte_len as c_ulong,
            ) as usize
        };
        if written < 2 {
            return None;
        }
        // Drop the trailing UTF-16 NUL the API includes in its length.
        let units = ((written - 2) / 2).min(buffer.len());
        let text = String::from_utf16_lossy(&buffer[..units]);
        if text.is_empty() { None } else { Some(text) }
    }
}

impl Drop for AnnotationReader {
    fn drop(&mut self) {
        // Closing a document is a PDFium call like any other, so it takes the same process-wide
        // lock: the neighbouring raster backend serialises its own teardown the same way, and a
        // close racing a load is exactly the kind of cross-document interaction this build has
        // crashed on before (see the `PDFIUM_LOCK` note in `backend.rs`).
        let _guard = crate::backend::PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        // SAFETY: the handle came from `FPDF_LoadDocument` and is closed exactly once, here.
        unsafe { (self.api.close_document)(self.document) };
    }
}

/// Maps `FPDF_ANNOTATION_SUBTYPE` to what the reader can act on.
///
/// Subtypes outside the four text-markup kinds, sticky notes and free text keep their PDF name:
/// an `Ink` or `Stamp` annotation is still worth listing for the user even though this build does
/// not draw it.
fn subtype_kind(subtype: c_ulong) -> RawAnnotationKind {
    match subtype {
        ANNOT_HIGHLIGHT => RawAnnotationKind::Highlight,
        ANNOT_UNDERLINE => RawAnnotationKind::Underline,
        ANNOT_STRIKEOUT => RawAnnotationKind::Strikeout,
        ANNOT_SQUIGGLY => RawAnnotationKind::Squiggly,
        ANNOT_TEXT => RawAnnotationKind::Text,
        ANNOT_FREETEXT => RawAnnotationKind::FreeText,
        // PDFium reports 0 for a `/Subtype` name it does not recognise, which is also the right
        // answer for us: the annotation stays readable (rect, contents, author) but unclassified.
        0 => RawAnnotationKind::Other("Unknown".to_string()),
        ANNOT_LINE => RawAnnotationKind::Other("Line".to_string()),
        ANNOT_SQUARE => RawAnnotationKind::Other("Square".to_string()),
        ANNOT_CIRCLE => RawAnnotationKind::Other("Circle".to_string()),
        ANNOT_POLYGON => RawAnnotationKind::Other("Polygon".to_string()),
        ANNOT_POLYLINE => RawAnnotationKind::Other("Polyline".to_string()),
        ANNOT_STAMP => RawAnnotationKind::Other("Stamp".to_string()),
        ANNOT_CARET => RawAnnotationKind::Other("Caret".to_string()),
        ANNOT_INK => RawAnnotationKind::Other("Ink".to_string()),
        ANNOT_POPUP => RawAnnotationKind::Other("Popup".to_string()),
        ANNOT_FILEATTACHMENT => RawAnnotationKind::Other("FileAttachment".to_string()),
        ANNOT_SOUND => RawAnnotationKind::Other("Sound".to_string()),
        ANNOT_MOVIE => RawAnnotationKind::Other("Movie".to_string()),
        ANNOT_WIDGET => RawAnnotationKind::Other("Widget".to_string()),
        ANNOT_SCREEN => RawAnnotationKind::Other("Screen".to_string()),
        ANNOT_PRINTERMARK => RawAnnotationKind::Other("PrinterMark".to_string()),
        ANNOT_TRAPNET => RawAnnotationKind::Other("TrapNet".to_string()),
        ANNOT_WATERMARK => RawAnnotationKind::Other("Watermark".to_string()),
        ANNOT_THREED => RawAnnotationKind::Other("3D".to_string()),
        ANNOT_RICHMEDIA => RawAnnotationKind::Other("RichMedia".to_string()),
        ANNOT_XFAWIDGET => RawAnnotationKind::Other("XFAWidget".to_string()),
        ANNOT_REDACT => RawAnnotationKind::Other("Redact".to_string()),
        other => RawAnnotationKind::Other(format!("Subtype{other}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blend_names_map_to_the_two_modes_this_build_draws() {
        assert_eq!(
            AnnotationBlend::from_pdf_name("Multiply"),
            AnnotationBlend::Multiply
        );
        assert_eq!(
            AnnotationBlend::from_pdf_name("Normal"),
            AnnotationBlend::Normal
        );
        // `/Compatible` is the PDF 1.4 spelling of Normal (PDF 32000-1 table 136).
        assert_eq!(
            AnnotationBlend::from_pdf_name("Compatible"),
            AnnotationBlend::Normal
        );
        // Anything else is reported verbatim rather than silently treated as normal.
        assert_eq!(
            AnnotationBlend::from_pdf_name("Screen"),
            AnnotationBlend::Other("Screen".to_string())
        );
        assert_eq!(AnnotationBlend::Multiply.as_str(), "multiply");
    }

    #[test]
    fn subtypes_map_to_the_kinds_the_reader_acts_on() {
        assert_eq!(subtype_kind(ANNOT_HIGHLIGHT), RawAnnotationKind::Highlight);
        assert_eq!(subtype_kind(ANNOT_UNDERLINE), RawAnnotationKind::Underline);
        assert_eq!(subtype_kind(ANNOT_STRIKEOUT), RawAnnotationKind::Strikeout);
        assert_eq!(subtype_kind(ANNOT_SQUIGGLY), RawAnnotationKind::Squiggly);
        assert_eq!(subtype_kind(ANNOT_TEXT), RawAnnotationKind::Text);
        assert_eq!(subtype_kind(ANNOT_FREETEXT), RawAnnotationKind::FreeText);
        assert_eq!(
            subtype_kind(ANNOT_INK),
            RawAnnotationKind::Other("Ink".to_string())
        );
        // An unrecognised subtype stays readable, with the number in its name.
        assert_eq!(
            subtype_kind(999),
            RawAnnotationKind::Other("Subtype999".to_string())
        );
    }
}
