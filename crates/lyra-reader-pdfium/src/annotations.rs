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
//! # Annotations that carry an appearance stream
//!
//! Both of those hold only for an annotation **without** `/AP`. `fpdf_annot.h` says of
//! `FPDFAnnot_GetColor`: *"Fails when called on annotations with appearance streams already
//! defined; instead use `FPDFPageObj_Get{Stroke|Fill}Color()`"*, and that is what a review PDF
//! looks like in practice: measured on the seven annotated review PDFs the user supplied
//! (`pdf-samples/with_annotations/`, 2026-10-15), **every one of the 242 text-markup annotations
//! has an `/AP`**, and `FPDFAnnot_GetColor` returned `FALSE` for every single one of them. The
//! reader reported "no colour", the canvas substituted an opaque grey, and a page of highlights
//! came out as a page of grey bars covering the text.
//!
//! [`AnnotationReader::color`] therefore clears the appearance dictionary on **its own**
//! `FPDF_DOCUMENT` handle (`FPDFAnnot_SetAP(annot, NORMAL, nullptr)`, a documented call: "If
//! `value` is nullptr, the AP is cleared for that mode") and reads the colour again. The
//! dictionary's `/C` then comes back unchanged — measured on the corpus, the colour read this way
//! is within one unit of the colour the appearance stream paints, because the appearance *is*
//! generated from `/C` — and the handle is private to this reader: it is never rasterised, never
//! saved, and dropped when the document closes, so nothing the user sees or writes is affected.
//! `FPDFPageObj_GetFillColor` is not used instead: on the same corpus it reports the *first*
//! object's fill, which for a strikeout is the black object rather than the annotation's colour,
//! and a `/C` that came back black for a red annotation would be a worse lie than no colour.
//!
//! # The blend mode when the file states none
//!
//! None of those 242 annotations states `/BM` either: the multiply Preview composites a highlight
//! with lives in the appearance stream's `ExtGState` (`/BM /Multiply`), which PDFium's C ABI does
//! not expose — there is no `GetBlendMode` anywhere in `fpdf_annot.h` or `fpdf_edit.h` (checked
//! against the exported symbols of the vendored dylib). Reporting the dictionary default
//! `/Normal` is what made the same files look wrong a second time: a yellow highlight at
//! `/CA 0.97` drawn alpha-over paints over the glyphs instead of tinting them.
//!
//! So a markup annotation with no `/BM` is reported with the blend mode PDFium itself composites
//! it with — see [`RawAnnotationKind::default_blend`], whose table comes from rendering such an
//! annotation with `FPDF_ANNOT` and reading the pixels. A stated `/BM` always wins.
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

use crate::stamp_read::{StampCatalog, read_stamp_catalog};
use libloading::Library;
use lopdf::{Document, LoadOptions, Object};
use lyra_reader_core::{
    AnnotationAlignment, AnnotationBlend, ErrorCode, LyraReaderError, PageIndex, Point,
    RawAnnotation, RawAnnotationColor, RawAnnotationKind, RawAnnotationLine, Rect, Result,
};
use std::collections::HashMap;
use std::ffi::{CStr, CString, c_char, c_int, c_uint, c_ulong, c_void};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// Opaque PDFium handles (see `fpdfview.h`).
type FpdfDocument = *mut c_void;
type FpdfPage = *mut c_void;
type FpdfAnnotation = *mut c_void;

/// `FS_RECTF`: note the field order — PDFium writes `left, top, right, bottom`, not the
/// left/bottom/right/top order every other rectangle in this workspace uses.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub(crate) struct FsRectF {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
}

/// `FS_QUADPOINTSF`: the four corners of one quadrilateral, page space.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub(crate) struct FsQuadPointsF {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    x3: f32,
    y3: f32,
    x4: f32,
    y4: f32,
}

/// `FS_POINTF`: one point in page space, used by `/InkList` paths and `/L` endpoints.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub(crate) struct FsPointF {
    x: f32,
    y: f32,
}

// `FPDF_ANNOTATION_SUBTYPE` values (fpdf_annot.h). Named because the numbers are meaningless at
// the call site, and because a wrong one would silently mislabel every annotation in a document.
const ANNOT_TEXT: c_ulong = 1;
const ANNOT_LINK: c_ulong = 2;
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

/// `FPDF_ANNOT_APPEARANCEMODE_NORMAL` — the `/AP /N` entry, and the mode
/// `FPDFAnnot_SetAP(annot, NORMAL, nullptr)` clears together with `/R` and `/D`.
const APPEARANCE_MODE_NORMAL: c_int = 0;

/// `FPDF_ANNOT_FLAG_*` (fpdf_annot.h): an annotation carrying one of these is not meant to be
/// seen, and drawing it would contradict the file.
const FLAG_INVISIBLE: c_int = 1 << 0;
const FLAG_HIDDEN: c_int = 1 << 1;
const FLAG_NOVIEW: c_int = 1 << 5;

/// `FPDF_ANNOT_FLAG_PRINT` — the annotation is printed. The review corpus and Preview both
/// write `/F 4`; an annotation that exists but disappears when the document is printed is a
/// surprise, so the writer sets the same bit.
const FLAG_PRINT: c_int = 1 << 2;

/// `FPDF_INCREMENTAL` (`fpdf_save.h`): append an update, keep every original byte. The writer
/// never passes `FPDF_NO_INCREMENTAL` — the incremental save is the whole data-safety story for
/// a file somebody may have signed.
const SAVE_INCREMENTAL: c_uint = 1;

/// FNV-1a over the annotation fields that make up a fallback identity.
///
/// Deliberately not `DefaultHasher`: its output is allowed to change between Rust releases, and
/// an annotation identity is carried across the FFI and stored in the shell's row selection. A
/// fixed algorithm makes `fp:…` repeatable for the same file on every run.
struct StableHash(u64);

impl StableHash {
    fn new() -> Self {
        Self(0xcbf2_9ce4_8422_2325)
    }

    fn bytes(&mut self, bytes: &[u8]) {
        for byte in bytes {
            self.0 ^= u64::from(*byte);
            self.0 = self.0.wrapping_mul(0x0000_0100_0000_01b3);
        }
        // A separator so ("ab", "c") and ("a", "bc") do not hash alike.
        self.bytes_raw(&[0xff]);
    }

    fn bytes_raw(&mut self, bytes: &[u8]) {
        for byte in bytes {
            self.0 ^= u64::from(*byte);
            self.0 = self.0.wrapping_mul(0x0000_0100_0000_01b3);
        }
    }

    fn integer(&mut self, value: u64) {
        self.bytes_raw(&value.to_le_bytes());
    }

    fn string(&mut self, value: &str) {
        self.bytes(value.as_bytes());
    }

    fn finish(&self) -> u64 {
        self.0
    }
}

/// The largest `/DA` font size this reader will report, in points.
///
/// Not a rendering limit: a malformed `/DA` can state a size of any magnitude (and one in the
/// wild states 4288 pt), and a free-text annotation drawn at that size covers the page. Above
/// this the size is reported as "the file did not say", which is where the shell's own default
/// takes over. 200 pt is larger than any page heading a reader would annotate with free text.
const MAX_FONT_SIZE_PT: f64 = 200.0;

/// The largest `/BS /W` this reader reports, in points. A border wider than a page is not a
/// stroke a reader should draw, and PDFium would otherwise hand its value straight through.
const MAX_BORDER_WIDTH_PT: f64 = 200.0;

/// A hostile `/InkList` entry cannot make the reader allocate without bound. 100 000 points is
/// far more than a real freehand stroke (measured: a dense signature-sized stroke is a few
/// thousand), and less than a page-sized bitmap.
const MAX_INK_POINTS_PER_PATH: c_ulong = 100_000;

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
    /// `/InkList` and `/L` accessors (fpdf_annot.h, experimental but exported by the vendored
    /// build): the geometry of the two stroked kinds PDFium will not create itself.
    get_ink_list_count: unsafe extern "C" fn(FpdfAnnotation) -> c_ulong,
    get_ink_list_path:
        unsafe extern "C" fn(FpdfAnnotation, c_ulong, *mut FsPointF, c_ulong) -> c_ulong,
    get_line: unsafe extern "C" fn(FpdfAnnotation, *mut FsPointF, *mut FsPointF) -> c_int,
    /// `/BS /W`, or the legacy `/Border` width when there is no `/BS`.
    get_border: unsafe extern "C" fn(FpdfAnnotation, *mut f32, *mut f32, *mut f32) -> c_int,
    set_ap: unsafe extern "C" fn(FpdfAnnotation, c_int, *const u16) -> c_int,
    /// `FPDFAnnot_GetLinkedAnnot`: follows `/IRT` or `/Popup` to another annotation.
    get_linked_annot: unsafe extern "C" fn(FpdfAnnotation, *const c_char) -> FpdfAnnotation,
}

/// The PDFium entry points only an annotation **writer** needs.
///
/// Resolved separately from [`Api`] on purpose: a PDFium build that can read annotations but
/// exports no write symbols must keep reading, and the read path must not start failing because
/// a save feature found a missing symbol once. [`AnnotationAppender::open`] reports the missing
/// API instead.
struct WriteApi {
    _library: Library,
    load_document: unsafe extern "C" fn(*const c_char, *const c_char) -> FpdfDocument,
    close_document: unsafe extern "C" fn(FpdfDocument),
    get_page_count: unsafe extern "C" fn(FpdfDocument) -> c_int,
    load_page: unsafe extern "C" fn(FpdfDocument, c_int) -> FpdfPage,
    close_page: unsafe extern "C" fn(FpdfPage),
    create_annot: unsafe extern "C" fn(FpdfPage, c_ulong) -> FpdfAnnotation,
    close_annot: unsafe extern "C" fn(FpdfAnnotation),
    set_rect: unsafe extern "C" fn(FpdfAnnotation, *const FsRectF) -> c_int,
    append_attachment_points: unsafe extern "C" fn(FpdfAnnotation, *const FsQuadPointsF) -> c_int,
    set_color: unsafe extern "C" fn(FpdfAnnotation, c_int, c_uint, c_uint, c_uint, c_uint) -> c_int,
    set_string_value: unsafe extern "C" fn(FpdfAnnotation, *const c_char, *const u16) -> c_int,
    set_flags: unsafe extern "C" fn(FpdfAnnotation, c_int) -> c_int,
    save_as_copy: unsafe extern "C" fn(FpdfDocument, *mut FpdfFileWrite, c_uint) -> c_int,
}

static WRITE_API: OnceLock<Option<&'static WriteApi>> = OnceLock::new();

/// One annotation the writer appends. Page space, like every other annotation geometry in this
/// crate; the FFI layer does the view → page conversion.
#[derive(Clone, Debug, PartialEq)]
pub struct WriteAnnotation {
    /// `/NM`, the annotation name. Unique in the document and used by the shell to recognise
    /// the annotation after it has been saved (and therefore to stop showing it twice).
    pub id: String,
    pub page: PageIndex,
    pub kind: WriteAnnotationKind,
    /// Outer box, page space. For a markup annotation this is the union of `quads`.
    pub rect: Rect,
    /// `/QuadPoints`, page space. Empty for a note and for every stroked geometry kind.
    pub quads: Vec<Rect>,
    /// `/InkList`, page space. One stroke per entry; empty for every kind except ink.
    pub ink_paths: Vec<Vec<Point>>,
    /// `/L`, page space. `Some` for a line or arrow and `None` for every other kind.
    pub line: Option<RawAnnotationLine>,
    /// Whether a line carries an arrowhead (`/LE`, plus `/Subj (Arrow)` for readers that only
    /// look there).
    pub line_arrow: bool,
    /// `/BS /W`, in points. Always positive; written for every stroked geometry kind and
    /// ignored for the quad-based kinds.
    pub border_width: f64,
    /// `/DA` font size, in points. Used by `/FreeText`; 0 for every other kind.
    pub font_size: f64,
    /// The stamp's style (`approved`, `reviewed`, `draft`, `confidential`, `date`). Written as
    /// the private `/LyraReaderStamp /Style` key and as the standard `/Name`; `None` for every
    /// kind except [`WriteAnnotationKind::Stamp`].
    pub stamp_style: Option<String>,
    /// The signature image, for [`WriteAnnotationKind::Signature`]. The writer stores its
    /// pixels as a FlateDecode image XObject plus an `/SMask`, inside the appearance stream.
    pub stamp_image: Option<WriteStampImage>,
    /// `/Q` text alignment, used by `/FreeText`; the PDF default (left) for every other kind.
    pub alignment: AnnotationAlignment,
    pub color: [u8; 3],
    /// `/CA`; 1.0 means fully opaque and is still written, because the shell's model carries
    /// an opacity for every annotation.
    pub opacity: f64,
    pub contents: Option<String>,
    pub author: Option<String>,
    /// `/M`, already formatted as a PDF date (`D:YYYYMMDDHHmmSSOHH'mm'`).
    pub modified: Option<String>,
}

/// The pixels of one image-signature stamp, straight (non-premultiplied) RGBA.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WriteStampImage {
    pub width: u32,
    pub height: u32,
    /// `width * height * 4` bytes, top row first.
    pub rgba: Vec<u8>,
}

/// What a [`WriteAnnotation`] becomes in the PDF.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WriteAnnotationKind {
    /// `/Highlight`: the filled, quad-based text markup.
    Highlight,
    /// `/Underline`: the same shape as a highlight, drawn along the baseline. Not required by
    /// the write-back task, but the sidecar already models underlines and the code is the same.
    Underline,
    /// `/StrikeOut`: the same quads and colour as an underline, drawn through the middle of the
    /// glyphs by the viewer that synthesises its appearance.
    StrikeOut,
    /// `/Text`: a sticky note whose `/Contents` is the note and whose `/Rect` is its icon.
    Text,
    /// `/FreeText`: text laid out in `/Rect`, with `/DA`, `/Q` and an appearance stream.
    FreeText,
    /// `/Ink`: a freehand stroke list. Written with `/InkList` and `/BS`.
    Ink,
    /// `/Square`: a stroked rectangle. Written with `/Rect` and `/BS`.
    Square,
    /// `/Circle`: a stroked ellipse. Written with `/Rect` and `/BS`.
    Circle,
    /// `/Line`: a line from `/L`, optionally with an arrowhead (`/LE`, `line_arrow`).
    Line,
    /// `/Stamp`: a text stamp. `/Contents` is the words, `stamp_style` the style, `/C` the
    /// colour, and the appearance stream draws the border and text with the embedded font.
    Stamp,
    /// `/Stamp`: an image signature. `stamp_image` is drawn inside the appearance stream as an
    /// image XObject; `/Contents` is empty. Both this and [`Self::Stamp`] are the same PDF
    /// subtype, because a signature image is what PDF calls a stamp.
    Signature,
}

impl WriteAnnotationKind {
    fn subtype(self) -> c_ulong {
        match self {
            Self::Highlight => ANNOT_HIGHLIGHT,
            Self::Underline => ANNOT_UNDERLINE,
            Self::StrikeOut => ANNOT_STRIKEOUT,
            Self::Text => ANNOT_TEXT,
            Self::FreeText => ANNOT_FREETEXT,
            Self::Ink => ANNOT_INK,
            Self::Square => ANNOT_SQUARE,
            Self::Circle => ANNOT_CIRCLE,
            Self::Line => ANNOT_LINE,
            Self::Stamp | Self::Signature => ANNOT_STAMP,
        }
    }

    /// The PDF `/Subtype` name for this kind.
    pub(crate) fn pdf_name(self) -> &'static str {
        match self {
            Self::Highlight => "Highlight",
            Self::Underline => "Underline",
            Self::StrikeOut => "StrikeOut",
            Self::Text => "Text",
            Self::FreeText => "FreeText",
            Self::Ink => "Ink",
            Self::Square => "Square",
            Self::Circle => "Circle",
            Self::Line => "Line",
            Self::Stamp | Self::Signature => "Stamp",
        }
    }

    /// `/Subj` (the subject line a viewer shows in the annotation list).
    pub(crate) fn subject(self) -> &'static str {
        match self {
            Self::Highlight => "Highlight",
            Self::Underline => "Underline",
            Self::StrikeOut => "StrikeOut",
            Self::Text => "Note",
            Self::FreeText => "Free Text",
            Self::Ink => "Ink",
            Self::Square => "Square",
            Self::Circle => "Circle",
            Self::Line => "Line",
            Self::Stamp => "Stamp",
            Self::Signature => "Signature",
        }
    }

    /// Whether this kind is written through PDFium's `FPDFPage_CreateAnnot`.
    ///
    /// PDFium will not create `/Line` at all (`FPDFPage_CreateAnnot` returns null), and none of
    /// the stroked kinds can carry `/BS` or an appearance stream through its C API: the only
    /// border setter writes `/Border`, and the only appearance setter stores a text string
    /// rather than a form XObject. A sticky note has the same problem with `/Name` (the icon
    /// name), and a free-text annotation needs `/DA`, `/Q` and a real `/AP` form XObject.
    ///
    /// Those facts are why highlights, underlines and strikeouts keep the PDFium path and every kind whose
    /// appearance matters is written by the dictionary writer in `geometry_write` (which now
    /// writes `/Text` and `/FreeText` too, despite the file's historical name).
    pub(crate) fn uses_pdfium(self) -> bool {
        matches!(self, Self::Highlight | Self::Underline | Self::StrikeOut)
    }

    /// Whether this kind is written by the direct (lopdf) writer.
    pub(crate) fn is_direct(self) -> bool {
        !self.uses_pdfium()
    }
}

/// `FPDF_FILEWRITE` (fpdf_save.h), by value: PDFium's incremental writer calls back into
/// [`FileSink`] for every byte it produces.
#[repr(C)]
struct FpdfFileWrite {
    version: c_int,
    write_block: unsafe extern "C" fn(*mut FpdfFileWrite, *const c_void, c_ulong) -> c_int,
}

/// The state behind the callback. `header` **must stay first**: PDFium passes the same pointer
/// it was given, and the callback casts it back to `FileSink`.
#[repr(C)]
struct FileSink {
    header: FpdfFileWrite,
    file: std::fs::File,
    failed: bool,
}

/// Writes one block into the sink, returning `1` exactly when every byte was written.
///
/// # Safety
///
/// PDFium calls this with the `FPDF_FILEWRITE*` it was handed, which is `&mut FileSink.header`
/// from [`FileSink::new`]. `data`/`size` describe a readable buffer for the duration of the call.
unsafe extern "C" fn write_block(
    this: *mut FpdfFileWrite,
    data: *const c_void,
    size: c_ulong,
) -> c_int {
    if this.is_null() || (data.is_null() && size != 0) {
        return 0;
    }
    // SAFETY: `this` is the `header` field of a `FileSink` that outlives the save call, and
    // `header` is the first field, so the cast points at the same object.
    let sink = unsafe { &mut *this.cast::<FileSink>() };
    if sink.failed {
        return 0;
    }
    let bytes = if size == 0 {
        &[][..]
    } else {
        // SAFETY: PDFium hands a buffer of `size` bytes that is valid for this call.
        unsafe { std::slice::from_raw_parts(data.cast::<u8>(), size as usize) }
    };
    match std::io::Write::write_all(&mut sink.file, bytes) {
        Ok(()) => 1,
        Err(_) => {
            sink.failed = true;
            0
        }
    }
}

impl FileSink {
    fn new(file: std::fs::File) -> Self {
        Self {
            header: FpdfFileWrite {
                version: 1,
                write_block,
            },
            file,
            failed: false,
        }
    }
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
        get_ink_list_count: unsafe { symbol(&library, b"FPDFAnnot_GetInkListCount\0")? },
        get_ink_list_path: unsafe { symbol(&library, b"FPDFAnnot_GetInkListPath\0")? },
        get_line: unsafe { symbol(&library, b"FPDFAnnot_GetLine\0")? },
        get_border: unsafe { symbol(&library, b"FPDFAnnot_GetBorder\0")? },
        set_ap: unsafe { symbol(&library, b"FPDFAnnot_SetAP\0")? },
        get_linked_annot: unsafe { symbol(&library, b"FPDFAnnot_GetLinkedAnnot\0")? },
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

/// Resolves the write entry points, which are a superset of the read ones plus the annotation
/// creation and incremental-save calls.
///
/// # Safety
///
/// The caller must have loaded a PDFium-compatible library; every signature is transcribed from
/// `vendor/pdfium/include/fpdf_annot.h` and `fpdf_save.h`.
unsafe fn resolve_write(library: Library) -> Option<WriteApi> {
    // SAFETY: same contract as `resolve` above.
    unsafe fn symbol<T: Copy>(library: &Library, name: &[u8]) -> Option<T> {
        // SAFETY: `T` is always one of the `extern "C" fn` types declared in `WriteApi`, matching
        // the exported PDFium symbol of that name.
        unsafe { library.get::<T>(name).ok().map(|symbol| *symbol) }
    }

    let api = WriteApi {
        load_document: unsafe { symbol(&library, b"FPDF_LoadDocument\0")? },
        close_document: unsafe { symbol(&library, b"FPDF_CloseDocument\0")? },
        get_page_count: unsafe { symbol(&library, b"FPDF_GetPageCount\0")? },
        load_page: unsafe { symbol(&library, b"FPDF_LoadPage\0")? },
        close_page: unsafe { symbol(&library, b"FPDF_ClosePage\0")? },
        create_annot: unsafe { symbol(&library, b"FPDFPage_CreateAnnot\0")? },
        close_annot: unsafe { symbol(&library, b"FPDFPage_CloseAnnot\0")? },
        set_rect: unsafe { symbol(&library, b"FPDFAnnot_SetRect\0")? },
        append_attachment_points: unsafe {
            symbol(&library, b"FPDFAnnot_AppendAttachmentPoints\0")?
        },
        set_color: unsafe { symbol(&library, b"FPDFAnnot_SetColor\0")? },
        set_string_value: unsafe { symbol(&library, b"FPDFAnnot_SetStringValue\0")? },
        set_flags: unsafe { symbol(&library, b"FPDFAnnot_SetFlags\0")? },
        save_as_copy: unsafe { symbol(&library, b"FPDF_SaveAsCopy\0")? },
        _library: library,
    };
    Some(api)
}

fn write_api() -> Option<&'static WriteApi> {
    WRITE_API
        .get_or_init(|| {
            for candidate in crate::backend::library_candidates() {
                // SAFETY: `Library::new` loads arbitrary code; these are the same PDFium paths the
                // rest of the backend resolves, and `resolve_write` checks every symbol.
                let Ok(library) = (unsafe { Library::new(candidate.as_os_str()) }) else {
                    continue;
                };
                // SAFETY: the library at these paths is PDFium, whose annotation ABI is fixed by
                // the vendored headers.
                if let Some(api) = unsafe { resolve_write(library) } {
                    return Some(&*Box::leak(Box::new(api)));
                }
            }
            None
        })
        .as_ref()
        .copied()
}

/// Appends annotations to one open PDF and saves it incrementally.
///
/// This type touches PDFium only; it does **not** decide where bytes go. The safety policy —
/// temporary file, verification, backup, atomic rename — lives one layer up in
/// [`crate::writeback::save_annotated_pdf`], which is the only public entry point.
///
/// Every method takes the process-wide `PDFIUM_LOCK`, because a PDFium call is never safe to run
/// concurrently with another one, even on a different document.
pub struct AnnotationAppender {
    api: &'static WriteApi,
    document: FpdfDocument,
    page_count: u32,
}

// SAFETY: raw PDFium handles are not thread-safe; every method (and `Drop`) serialises on
// `PDFIUM_LOCK`, which is what makes the markers sound.
unsafe impl Send for AnnotationAppender {}
unsafe impl Sync for AnnotationAppender {}

impl AnnotationAppender {
    /// Opens `path` for writing. The document is modified in memory only; call
    /// [`AnnotationAppender::save_incremental`] to produce bytes.
    pub fn open(path: &Path, password: Option<&str>) -> Result<Self> {
        let Some(api) = write_api() else {
            return Err(LyraReaderError::new(
                ErrorCode::BackendUnavailable,
                "this PDFium build does not export the annotation-writing API",
            )
            .with_detail(
                "missing one of FPDFPage_CreateAnnot / FPDFAnnot_Set* / FPDF_SaveAsCopy",
            ));
        };
        // Make sure the library is initialised the same way the rest of the backend does it.
        // `pdfium_instance` is process-cached, so this costs nothing after the first open.
        crate::backend::pdfium_instance()?;

        let path = CString::new(path.to_string_lossy().as_bytes()).map_err(|_| {
            LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "the document path contains a NUL byte",
            )
        })?;
        let password = password.map(CString::new).transpose().map_err(|_| {
            LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "the password contains a NUL byte",
            )
        })?;

        // SAFETY: the C strings outlive the call and the library is initialised above.
        let document = {
            let _guard = crate::backend::PDFIUM_LOCK
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            unsafe {
                (api.load_document)(
                    path.as_ptr(),
                    password
                        .as_ref()
                        .map_or(std::ptr::null(), |value| value.as_ptr()),
                )
            }
        };
        if document.is_null() {
            return Err(LyraReaderError::new(
                ErrorCode::CorruptDocument,
                "PDFium could not open the document for annotation writing",
            )
            .with_detail(format!("path: {}", path.to_string_lossy())));
        }

        // SAFETY: `document` is a live document handle.
        let page_count = {
            let _guard = crate::backend::PDFIUM_LOCK
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            unsafe { (api.get_page_count)(document) }.max(0) as u32
        };

        Ok(Self {
            api,
            document,
            page_count,
        })
    }

    pub fn page_count(&self) -> u32 {
        self.page_count
    }

    /// Appends one annotation. The caller has already validated the geometry and identity.
    pub fn add(&mut self, annotation: &WriteAnnotation) -> Result<()> {
        if annotation.page.get() >= self.page_count {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                format!(
                    "annotation {} names page {}, but the document has {} page(s)",
                    annotation.id,
                    annotation.page.get(),
                    self.page_count
                ),
            ));
        }
        let page_index = c_int::try_from(annotation.page.get()).map_err(|_| {
            LyraReaderError::new(
                ErrorCode::InvalidArgument,
                format!("page {} is out of range for PDFium", annotation.page.get()),
            )
        })?;

        let _guard = crate::backend::PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

        // SAFETY: `document` is live and `page_index` was checked against the page count.
        let page = unsafe { (self.api.load_page)(self.document, page_index) };
        if page.is_null() {
            return Err(LyraReaderError::new(
                ErrorCode::RenderFailed,
                format!(
                    "PDFium could not load page {} for annotation writing",
                    annotation.page.get()
                ),
            ));
        }

        let result = self.add_to_page(page, annotation);
        // SAFETY: `page` came from `load_page` and is not used after this point.
        unsafe { (self.api.close_page)(page) };
        result
    }

    /// The annotation-dictionary half of [`AnnotationAppender::add`], split out so the page
    /// handle is closed on every path.
    fn add_to_page(&self, page: FpdfPage, annotation: &WriteAnnotation) -> Result<()> {
        // SAFETY: `page` is a live page handle.
        let handle = unsafe { (self.api.create_annot)(page, annotation.kind.subtype()) };
        if handle.is_null() {
            return Err(LyraReaderError::new(
                ErrorCode::RenderFailed,
                format!(
                    "PDFium did not create a {:?} annotation named {}",
                    annotation.kind, annotation.id
                ),
            ));
        }

        let result = self.populate(handle, annotation);
        // SAFETY: `handle` came from `create_annot` and is not used after this point. Closing it
        // does not remove the annotation from the page.
        unsafe { (self.api.close_annot)(handle) };
        result
    }

    fn populate(&self, handle: FpdfAnnotation, annotation: &WriteAnnotation) -> Result<()> {
        // SAFETY (all calls below): `handle` is a live annotation for the duration of this
        // function, and every pointer points at a local that outlives the call.
        unsafe {
            let rect = FsRectF {
                left: annotation.rect.min_x() as f32,
                top: annotation.rect.max_y() as f32,
                right: annotation.rect.max_x() as f32,
                bottom: annotation.rect.min_y() as f32,
            };
            if (self.api.set_rect)(handle, &rect) == 0 {
                return Err(write_error("FPDFAnnot_SetRect", &annotation.id));
            }

            // PDF 32000-1 table 179 order: upper-left, upper-right, lower-left, lower-right.
            // PDFKit refuses to fill a highlight whose points are in any other order (measured
            // with PDFKit on a hand-written fixture, 2026-10-16: LL/LR/UR/UL draws two thin
            // bars instead of a filled quad). PDFium only takes the bounding box, so the
            // standard order is the one to write.
            for quad in &annotation.quads {
                let points = FsQuadPointsF {
                    x1: quad.min_x() as f32,
                    y1: quad.max_y() as f32,
                    x2: quad.max_x() as f32,
                    y2: quad.max_y() as f32,
                    x3: quad.min_x() as f32,
                    y3: quad.min_y() as f32,
                    x4: quad.max_x() as f32,
                    y4: quad.min_y() as f32,
                };
                if (self.api.append_attachment_points)(handle, &points) == 0 {
                    return Err(write_error(
                        "FPDFAnnot_AppendAttachmentPoints",
                        &annotation.id,
                    ));
                }
            }

            let alpha = (annotation.opacity.clamp(0.0, 1.0) * 255.0).round() as c_uint;
            if (self.api.set_color)(
                handle,
                COLORTYPE_COLOR,
                c_uint::from(annotation.color[0]),
                c_uint::from(annotation.color[1]),
                c_uint::from(annotation.color[2]),
                alpha,
            ) == 0
            {
                return Err(write_error("FPDFAnnot_SetColor", &annotation.id));
            }

            set_string(self.api, handle, c"NM", Some(&annotation.id))?;
            set_string(self.api, handle, c"T", annotation.author.as_deref())?;
            set_string(
                self.api,
                handle,
                c"Contents",
                annotation.contents.as_deref(),
            )?;
            set_string(self.api, handle, c"M", annotation.modified.as_deref())?;
            set_string(self.api, handle, c"Subj", Some(annotation.kind.subject()))?;

            // Preview and the review corpus write `/F 4` (print). No appearance stream is set:
            // see the module-level note in `writeback` for why, and what other viewers show.
            if (self.api.set_flags)(handle, FLAG_PRINT) == 0 {
                return Err(write_error("FPDFAnnot_SetFlags", &annotation.id));
            }
        }
        Ok(())
    }

    /// Writes the incrementally-updated document into `file`, flushes it and `fsync`s it.
    ///
    /// Returns the number of bytes written (the full output, including the original prefix).
    pub fn save_incremental(&mut self, file: std::fs::File) -> Result<u64> {
        let mut sink = FileSink::new(file);
        let ok = {
            let _guard = crate::backend::PDFIUM_LOCK
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            // SAFETY: `self.document` is live, and `sink.header` is an `FPDF_FILEWRITE` whose
            // callback writes into `sink`. PDFium only calls it during this call.
            unsafe {
                (self.api.save_as_copy)(
                    self.document,
                    std::ptr::addr_of_mut!(sink.header),
                    SAVE_INCREMENTAL,
                )
            }
        };
        if ok == 0 || sink.failed {
            return Err(LyraReaderError::new(
                ErrorCode::RenderFailed,
                "PDFium failed to write the incremental update",
            )
            .with_detail(format!("save_as_copy={ok}, write_error={}", sink.failed)));
        }
        std::io::Write::flush(&mut sink.file).map_err(|error| {
            LyraReaderError::new(ErrorCode::Io, "could not flush the saved PDF")
                .with_detail(error.to_string())
        })?;
        sink.file.sync_all().map_err(|error| {
            LyraReaderError::new(ErrorCode::Io, "could not fsync the saved PDF")
                .with_detail(error.to_string())
        })?;
        let bytes = sink.file.metadata().map(|meta| meta.len()).unwrap_or(0);
        Ok(bytes)
    }
}

impl Drop for AnnotationAppender {
    fn drop(&mut self) {
        // SAFETY: the handle came from `load_document` and is closed exactly once, here.
        let _guard = crate::backend::PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        unsafe { (self.api.close_document)(self.document) };
    }
}

fn write_error(call: &str, id: &str) -> LyraReaderError {
    LyraReaderError::new(
        ErrorCode::RenderFailed,
        format!("PDFium refused {call} while writing annotation {id}"),
    )
}

/// Sets one UTF-16 dictionary string. An absent value is not an error: the key is simply not
/// written, which is what "the file did not have an author" should mean on the way out too.
fn set_string(
    api: &WriteApi,
    handle: FpdfAnnotation,
    key: &CStr,
    value: Option<&str>,
) -> Result<()> {
    let Some(value) = value.filter(|value| !value.is_empty()) else {
        return Ok(());
    };
    let mut wide: Vec<u16> = value.encode_utf16().collect();
    wide.push(0);
    // SAFETY: `handle` is live, `key` is NUL-terminated and `wide` is a valid UTF-16LE buffer
    // terminated by a NUL unit.
    let ok = unsafe { (api.set_string_value)(handle, key.as_ptr(), wide.as_ptr()) };
    if ok == 0 {
        return Err(write_error(
            "FPDFAnnot_SetStringValue",
            key.to_string_lossy().as_ref(),
        ));
    }
    Ok(())
}

/// Reads annotations from one open document.
///
/// Owns its own `FPDF_DOCUMENT`: PDFium has no way to hand out the handle behind the
/// `pdfium-render` facade, and re-opening the same file is how this workspace already gives each
/// worker its own handle ([`crate::backend::PdfiumBackend::reopen`]). The public methods serialize on
/// `PDFIUM_LOCK`; the `_locked` helpers are only for callers already holding it.
pub struct AnnotationReader {
    api: &'static Api,
    document: FpdfDocument,
    /// The file this reader opened. Kept for the two dictionary facts PDFium's C ABI does not
    /// expose: a line's `/LE` endings are read with lopdf, keyed by `/NM`.
    path: PathBuf,
    password: Option<String>,
    /// Annotation name → "has an arrowhead", built once on the first `/Line` read.
    line_endings: OnceLock<HashMap<String, bool>>,
    /// Annotation name → `/BS /W` (or the legacy `/Border` width), built on the first stroked
    /// read. PDFium's `FPDFAnnot_GetBorder` reads `/Border` but not the `/BS` dictionary this
    /// writer uses, so the dictionary itself is the authority here.
    border_widths: OnceLock<HashMap<String, f64>>,
    /// Every `/Stamp` annotation's text and picture, built on the first stamp read. PDFium's C
    /// ABI exposes neither `/Contents`-as-drawn nor `/AP`, so the dictionary pass in
    /// [`crate::stamp_read`] is where a stamp becomes drawable.
    stamp_details: OnceLock<StampCatalog>,
}

// SAFETY: raw PDFium handles are not thread-safe, and these markers are only sound because every
// public method serialises on `PDFIUM_LOCK`, including opening and destruction.
unsafe impl Send for AnnotationReader {}
unsafe impl Sync for AnnotationReader {}

impl AnnotationReader {
    /// Opens `path` for annotation reading, with the same `password` the document was opened with.
    ///
    /// Fails when this PDFium build does not export the `FPDFAnnot_*` family, or when the document
    /// cannot be opened a second time — both are reported to the caller rather than silently
    /// turning into "this document has no annotations".
    pub fn open(path: &Path, password: Option<&str>) -> Result<Self> {
        crate::backend::pdfium_instance()?;
        let _guard = crate::backend::PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        Self::open_locked(path, password)
    }

    /// The caller already holds `PDFIUM_LOCK` for a larger PDFium transaction.
    pub(crate) fn open_locked(path: &Path, password: Option<&str>) -> Result<Self> {
        let Some(api) = api() else {
            return Err(LyraReaderError::new(
                ErrorCode::BackendUnavailable,
                "this PDFium build does not export the annotation API",
            )
            .with_detail("missing one of the FPDFAnnot_* / FPDFPage_*Annot* entry points"));
        };

        let source_path = path.to_path_buf();
        let source_password = password.map(str::to_owned);
        let path = CString::new(path.to_string_lossy().as_bytes()).map_err(|_| {
            LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "the document path contains a NUL byte",
            )
        })?;
        let password = password.map(CString::new).transpose().map_err(|_| {
            LyraReaderError::new(
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
            return Err(LyraReaderError::new(
                ErrorCode::CorruptDocument,
                "PDFium could not open the document a second time for annotation reading",
            )
            .with_detail(format!("path: {}", path.to_string_lossy())));
        }

        Ok(Self {
            api,
            document,
            path: source_path,
            password: source_password,
            line_endings: OnceLock::new(),
            border_widths: OnceLock::new(),
            stamp_details: OnceLock::new(),
        })
    }

    /// Every content annotation on `page`, in the order the document stores them.
    ///
    /// Structural annotations (links, widgets, popups, page furniture) are left out — see
    /// [`is_content_annotation`] for what that means and why, with the measurement behind it.
    ///
    /// Annotations this build cannot load (a damaged one, or a page that will not open) are
    /// skipped rather than failing the whole page: a reader must not refuse to show the other
    /// twenty highlights because the twenty-first is broken.
    pub fn page(&self, page: PageIndex) -> Result<Vec<RawAnnotation>> {
        let _guard = crate::backend::PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        self.page_locked(page)
    }

    /// The caller already holds `PDFIUM_LOCK` for a larger PDFium transaction.
    pub(crate) fn page_locked(&self, page: PageIndex) -> Result<Vec<RawAnnotation>> {
        let index = c_int::try_from(page.get()).map_err(|_| {
            LyraReaderError::new(
                ErrorCode::InvalidArgument,
                format!("page {} is out of range for PDFium", page.get()),
            )
        })?;

        // SAFETY: the document handle is live for as long as `self`, and every call here is
        // serialised by the caller's `PDFIUM_LOCK`.
        let page_handle = unsafe { (self.api.load_page)(self.document, index) };
        if page_handle.is_null() {
            return Err(LyraReaderError::new(
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

    /// Reads one annotation, or `None` when it is not content or its `/Rect` is unreadable.
    fn read(&self, handle: FpdfAnnotation, page: PageIndex) -> Option<RawAnnotation> {
        // SAFETY: `handle` is a live annotation for the duration of `read`.
        let subtype = unsafe { (self.api.get_subtype)(handle) };
        if !is_content_annotation(subtype) {
            return None;
        }

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

        let kind = subtype_kind(subtype);
        // The identity is needed before the line geometry: `/LE` is read through lopdf, which
        // keys the answer by `/NM`. Reading it here also keeps one identity derivation.
        let id = self.identity(handle, subtype);
        let quads = self.quad_points(handle);
        let ink_paths = if kind == RawAnnotationKind::Ink {
            self.ink_paths(handle)
        } else {
            Vec::new()
        };
        let line = if kind == RawAnnotationKind::Line {
            self.line(handle)
        } else {
            None
        };
        let line_arrow = kind == RawAnnotationKind::Line && self.line_is_arrow(&id, handle);
        let border_width = if matches!(
            kind,
            RawAnnotationKind::Ink
                | RawAnnotationKind::Square
                | RawAnnotationKind::Circle
                | RawAnnotationKind::Line
        ) {
            self.border_width(handle, &id)
        } else {
            None
        };
        let color = self.color(handle);
        let opacity = self.opacity(handle);
        // The file's own `/BM` wins; when it states none, the kind's measured default does (a
        // highlight with no `/BM` is multiplied by every renderer, including PDFium — see
        // [`RawAnnotationKind::default_blend`]). Reporting "normal" there is what painted
        // Preview's highlights over the text instead of into it.
        let blend = self.string(handle, c"BM").map_or_else(
            || kind.default_blend(),
            |name| AnnotationBlend::from_pdf_name(&name),
        );
        // SAFETY: `handle` is live; the call reads one integer flag set.
        let flags = unsafe { (self.api.get_flags)(handle) };
        let hidden = flags & (FLAG_INVISIBLE | FLAG_HIDDEN | FLAG_NOVIEW) != 0;

        // Finish reading the child before following `/IRT`: closing the linked handle must not
        // be able to invalidate a field this annotation still has to report, even if a malformed
        // file links an annotation to itself.
        let contents = self.string(handle, c"Contents");
        let author = self.string(handle, c"T");
        let modified = self.string(handle, c"M");
        let font_size_pt = self.font_size(handle);
        let alignment = self.alignment(handle);

        // `/IRT` is the reply link. Close the linked handle PDFium hands back: `fpdf_annot.h`
        // says the caller owns it. A reply whose parent is hidden, on another page, or not a
        // content annotation still gets an identity here; deciding whether it can be nested is
        // the shell's job, done against the whole list.
        let is_reply = self.has_key(handle, c"IRT");
        let parent_id = if is_reply {
            self.linked_identity(handle)
        } else {
            None
        };
        // `/Popup` is a reference to the annotation's popup window. The window itself is
        // structural and never listed, but its presence is what tells a caller that removing
        // this annotation would take review text with it.
        let has_popup = self.has_key(handle, c"Popup");

        let stamp = if kind == RawAnnotationKind::Stamp {
            let name = id.strip_prefix("nm:");
            let values = [rect.min_x(), rect.min_y(), rect.max_x(), rect.max_y()];
            self.stamps()
                .find(name, page.get(), values)
                .map(|details| lyra_reader_core::RawStamp {
                    text: details.text.clone(),
                    style: details.style.clone(),
                    image: details.image.clone(),
                    image_error: details.image_error.clone(),
                })
        } else {
            None
        };

        Some(RawAnnotation {
            page,
            id,
            parent_id,
            is_reply,
            has_popup,
            kind,
            rect,
            quads,
            ink_paths,
            line,
            line_arrow,
            border_width,
            color,
            opacity,
            blend,
            contents,
            author,
            modified,
            font_size_pt,
            alignment,
            stamp,
            visible: !hidden,
        })
    }

    /// The identity a `/IRT` entry uses for this annotation.
    ///
    /// `/NM` is the file's own annotation name and the only identity PDFium exposes across
    /// pages. The fallback is a fingerprint of the fields the linked handle can read too: a file
    /// that omits `/NM` still gets a stable key, at the cost that two byte-identical unnamed
    /// annotations would share one. The corpus carries `/NM` on every annotation, so this is a
    /// malformed-file fallback rather than the normal path.
    fn identity(&self, handle: FpdfAnnotation, subtype: c_ulong) -> String {
        if let Some(name) = self.string(handle, c"NM") {
            return format!("nm:{name}");
        }

        let mut hash = StableHash::new();
        hash.integer(subtype);
        let mut raw_rect = FsRectF::default();
        // SAFETY: `handle` is live and `raw_rect` is a valid out-pointer.
        if unsafe { (self.api.get_rect)(handle, &mut raw_rect) } != 0 {
            for value in [raw_rect.left, raw_rect.bottom, raw_rect.right, raw_rect.top] {
                hash.integer(u64::from(value.to_bits()));
            }
        }
        for key in [c"Contents", c"T", c"M"] {
            if let Some(value) = self.string(handle, key) {
                hash.string(&value);
            }
        }
        format!("fp:{:016x}", hash.finish())
    }

    /// The identity of the annotation `/IRT` points at, or `None` if PDFium cannot follow it.
    fn linked_identity(&self, handle: FpdfAnnotation) -> Option<String> {
        // SAFETY: `handle` is live and the key is NUL-terminated. The returned handle is owned by
        // the caller according to fpdf_annot.h, so it is closed before this function returns.
        let linked = unsafe { (self.api.get_linked_annot)(handle, c"IRT".as_ptr()) };
        if linked.is_null() {
            return None;
        }
        // SAFETY: `linked` is a live annotation handle until `close_annot` below.
        let subtype = unsafe { (self.api.get_subtype)(linked) };
        let identity = self.identity(linked, subtype);
        // SAFETY: the handle came from `get_linked_annot` and is not used afterwards.
        unsafe { (self.api.close_annot)(linked) };
        Some(identity)
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

    /// `/InkList`, one page-space polyline per stroke.
    ///
    /// PDFium's two-step pattern: a null buffer returns the point count, then a buffer of that
    /// size is filled. A malformed entry is skipped rather than failing the whole annotation —
    /// the sidebar should still be able to say "an ink annotation is here".
    fn ink_paths(&self, handle: FpdfAnnotation) -> Vec<Vec<Point>> {
        // SAFETY: `handle` is live; the count is the number of paths in the ink list.
        let count = unsafe { (self.api.get_ink_list_count)(handle) };
        let mut paths = Vec::new();
        for index in 0..count {
            // SAFETY: `index` is inside the count just read. A null buffer with length 0 asks
            // for the point count and touches no memory.
            let length =
                unsafe { (self.api.get_ink_list_path)(handle, index, std::ptr::null_mut(), 0) };
            // A path larger than a whole page's worth of samples is malformed; the limit also
            // keeps a hostile file from making the reader allocate without bound.
            if length == 0 || length > MAX_INK_POINTS_PER_PATH {
                continue;
            }
            let mut points = vec![FsPointF::default(); length as usize];
            // SAFETY: `points` has room for `length` points, which is what the call writes.
            let written =
                unsafe { (self.api.get_ink_list_path)(handle, index, points.as_mut_ptr(), length) };
            let points: Vec<Point> = points
                .into_iter()
                .take(written as usize)
                .filter(|point| point.x.is_finite() && point.y.is_finite())
                .map(|point| Point::new(f64::from(point.x), f64::from(point.y)))
                .collect();
            if !points.is_empty() {
                paths.push(points);
            }
        }
        paths
    }

    /// `/L`, the two endpoints of a `/Line` annotation, in page space.
    fn line(&self, handle: FpdfAnnotation) -> Option<RawAnnotationLine> {
        let mut start = FsPointF::default();
        let mut end = FsPointF::default();
        // SAFETY: `handle` is live and both out-pointers are valid.
        let ok = unsafe { (self.api.get_line)(handle, &mut start, &mut end) };
        if ok == 0
            || ![start.x, start.y, end.x, end.y]
                .iter()
                .all(|value| value.is_finite())
        {
            return None;
        }
        Some(RawAnnotationLine {
            start: Point::new(f64::from(start.x), f64::from(start.y)),
            end: Point::new(f64::from(end.x), f64::from(end.y)),
        })
    }

    /// `/BS /W` (or the legacy `/Border` width) in points, when it is usable.
    ///
    /// The map read from the dictionary wins: it sees `/BS`, which PDFium's accessor does not.
    /// PDFium's answer is the fallback for a file whose dictionary could not be read a second
    /// time (a damaged file still has its geometry through PDFium).
    fn border_width(&self, handle: FpdfAnnotation, id: &str) -> Option<f64> {
        if let Some(name) = id.strip_prefix("nm:")
            && let Some(width) = self.border_widths().get(name).copied()
        {
            return Some(width);
        }
        let (mut horizontal, mut vertical, mut width) = (0.0f32, 0.0f32, 0.0f32);
        // SAFETY: `handle` is live and the three out-pointers are valid.
        let ok =
            unsafe { (self.api.get_border)(handle, &mut horizontal, &mut vertical, &mut width) };
        if ok == 0 || !horizontal.is_finite() || !vertical.is_finite() {
            return None;
        }
        let width = f64::from(width);
        (width.is_finite() && width > 0.0 && width <= MAX_BORDER_WIDTH_PT).then_some(width)
    }

    /// Whether a `/Line` annotation says it has an arrowhead.
    ///
    /// Two sources, because producers disagree: this writer puts `/Subj (Arrow)` beside a
    /// standard `/LE`, while other writers only put `/LE`. PDFium exposes neither array nor
    /// name list, so `/LE` comes from a lopdf read of the same file, keyed by `/NM`.
    fn line_is_arrow(&self, id: &str, handle: FpdfAnnotation) -> bool {
        if self
            .string(handle, c"Subj")
            .is_some_and(|subject| subject.to_ascii_lowercase().contains("arrow"))
        {
            return true;
        }
        let Some(name) = id.strip_prefix("nm:") else {
            return false;
        };
        self.line_endings().get(name).copied().unwrap_or(false)
    }

    /// The `/BS` map for this document, read once.
    fn border_widths(&self) -> &HashMap<String, f64> {
        self.border_widths.get_or_init(|| {
            read_border_widths(&self.path, self.password.as_deref()).unwrap_or_default()
        })
    }

    /// The `/LE` map for this document, read once.
    ///
    /// A failure to parse the file a second time is not an error here: the annotation is still
    /// a line, and drawing it without an arrowhead is better than turning "PDFium could read the
    /// geometry but lopdf could not re-open the file" into a failed page.
    fn line_endings(&self) -> &HashMap<String, bool> {
        self.line_endings.get_or_init(|| {
            read_line_endings(&self.path, self.password.as_deref()).unwrap_or_default()
        })
    }

    /// Every `/Stamp`'s content for this document, read once.
    ///
    /// A failure to parse the file a second time is not an error: the stamp is still a stamp,
    /// and reporting its `/Rect` with no words is better than dropping the annotation.
    fn stamps(&self) -> &StampCatalog {
        self.stamp_details.get_or_init(|| {
            read_stamp_catalog(&self.path, self.password.as_deref()).unwrap_or_default()
        })
    }

    /// `/C`, but only when the file actually carries it.
    ///
    /// `FPDFAnnot_GetColor` answers `TRUE` with black for an annotation that has no colour at all
    /// (measured; see the module docs), so its result is not trusted on its own — a sticky note
    /// must be reported as "no colour", not as black.
    ///
    /// It also answers `FALSE` for **any** annotation with an appearance stream, which is every
    /// markup annotation Preview and Acrobat write (measured: 242 of 242 in the review corpus).
    /// Clearing `/AP` on this reader's private handle makes the documented accessor work again
    /// and hands back the dictionary's own `/C`; see the module docs for why that is sound here
    /// and why the `FPDFPageObj_GetFillColor` alternative was rejected.
    fn color(&self, handle: FpdfAnnotation) -> Option<RawAnnotationColor> {
        if !self.has_key(handle, c"C") {
            return None;
        }
        if let Some(color) = self.color_value(handle) {
            return Some(color);
        }
        if !self.clear_appearance(handle) {
            return None;
        }
        self.color_value(handle)
    }

    /// One `FPDFAnnot_GetColor` call, as a colour or nothing.
    fn color_value(&self, handle: FpdfAnnotation) -> Option<RawAnnotationColor> {
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

    /// Drops the annotation's appearance dictionary, on this reader's own document handle only.
    ///
    /// Only called when `FPDFAnnot_GetColor` refused a `/C` that `HasKey` says is there, which is
    /// the appearance-stream case. Returns whether there was an appearance dictionary to clear —
    /// a `false` means the caller's retry has nothing new to try, not that anything failed.
    ///
    /// Nothing is written to disk and no other handle sees this: [`AnnotationReader`] owns a
    /// second `FPDF_DOCUMENT` opened for reading, never rasterised and never saved (see the type's
    /// docs), and `PDFIUM_LOCK` is held for the whole call.
    fn clear_appearance(&self, handle: FpdfAnnotation) -> bool {
        if !self.has_key(handle, c"AP") {
            return false;
        }
        // SAFETY: `handle` is live. A null `value` is the documented "clear it" argument for the
        // mode; the mode is Normal, which `fpdf_annot.h` documents as clearing `/R` and `/D`
        // too. The call only touches this document's in-memory object.
        unsafe { (self.api.set_ap)(handle, APPEARANCE_MODE_NORMAL, std::ptr::null()) != 0 }
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

    /// The font size `/DA` states, in points.
    ///
    /// `/DA` is a content-stream fragment (`/DFWaWaSC-W5 18.000 Tf` in the review corpus); only
    /// its `Tf` size is wanted here, and the font itself is deliberately not carried: the file
    /// names a font this process does not have (a Chinese face in 22 of the corpus's 23 free-text
    /// annotations), so the shell draws the text in its own face at the size the file asked for.
    ///
    /// The size is the operand *before* `Tf`, and PDF allows the operands and the operator to be
    /// separated by any whitespace. A value that is not a usable size — zero, negative,
    /// non-finite, or larger than [`MAX_FONT_SIZE_PT`] — is reported as "no size" rather than
    /// clamped: a reader that invents 4288 pt of text is worse than one that falls back to its
    /// own default and says the file did not state a size.
    fn font_size(&self, handle: FpdfAnnotation) -> Option<f64> {
        font_size_from_da(&self.string(handle, c"DA")?)
    }

    /// `/Q`, the quadding, as the file states it.
    ///
    /// `FPDFAnnot_GetNumberValue` is documented for numbers and `/Q` is an integer, so it is
    /// readable with the same call as `/CA`. An absent or unreadable `/Q` is the PDF default
    /// (left), which is also what a malformed value means.
    fn alignment(&self, handle: FpdfAnnotation) -> AnnotationAlignment {
        if !self.has_key(handle, c"Q") {
            return AnnotationAlignment::default();
        }
        let mut value = 0.0f32;
        // SAFETY: `handle` is live and `value` is a valid out-pointer.
        let ok = unsafe { (self.api.get_number_value)(handle, c"Q".as_ptr(), &mut value) };
        if ok == 0 || !value.is_finite() {
            return AnnotationAlignment::default();
        }
        AnnotationAlignment::from_quadding(value.round() as i64)
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

/// The size operand of the `Tf` operator in a `/DA` string, when it states a usable one.
///
/// A `/DA` is a content-stream fragment, so the operands and the operator may be separated by any
/// whitespace and the fragment may hold more than one operator (`/Helv 12 Tf 0 g`). The *last*
/// operand before `Tf` is the size (the operand before that is the font's resource name).
///
/// Split out of [`AnnotationReader::font_size`] so it can be tested without a PDFium document:
/// the parsing is where the edge cases live (a missing `Tf`, a `Tf` with too few operands, a size
/// that is not a number, a size no reader should draw), and none of them needs a file.
fn font_size_from_da(da: &str) -> Option<f64> {
    let mut operands: Vec<&str> = Vec::new();
    for token in da.split_whitespace() {
        if token == "Tf" {
            let size: f64 = operands.last()?.parse().ok()?;
            return (size.is_finite() && size > 0.0 && size <= MAX_FONT_SIZE_PT).then_some(size);
        }
        operands.push(token);
    }
    None
}

/// Whether an annotation of this subtype is something a reader would show or list.
///
/// Not everything PDFium counts as an annotation is one in the reader's sense. Measured on the
/// local twelve-paper corpus (2026-10-15): 2767 annotations in seven documents, of which **2751
/// are `/Link`** — navigation, which this backend already answers through
/// [`crate::backend::PdfiumBackend::link_targets`], and which a sidebar must not list 1950 times.
/// `/Popup` is a markup annotation's own popup window, `/Widget` and `/XFAWidget` are form fields,
/// and `/Screen`, `/PrinterMark`, `/TrapNet` and `/Watermark` are page furniture. None of them is
/// something somebody drew to be read, so the reader skips them and reports the rest — including
/// subtypes it cannot draw (`Ink`, `Stamp`, …), because those *are* content.
fn is_content_annotation(subtype: c_ulong) -> bool {
    !matches!(
        subtype,
        ANNOT_LINK
            | ANNOT_POPUP
            | ANNOT_WIDGET
            | ANNOT_XFAWIDGET
            | ANNOT_SCREEN
            | ANNOT_PRINTERMARK
            | ANNOT_TRAPNET
            | ANNOT_WATERMARK
            | ANNOT_FILEATTACHMENT
            | ANNOT_SOUND
            | ANNOT_MOVIE
            | ANNOT_THREED
            | ANNOT_RICHMEDIA
            | ANNOT_REDACT
    )
}

/// Maps `FPDF_ANNOTATION_SUBTYPE` to what the reader can act on.
///
/// Subtypes outside the four text-markup kinds, sticky notes and free text keep their PDF name:
/// an `Ink` or `Stamp` annotation is still worth listing for the user even though this build does
/// not draw it.
/// The `/BS /W` (else `/Border`) width of every annotation, keyed by `/NM`.
///
/// `/BS` supersedes `/Border` when both are present (PDF 32000-1 12.5.4). The value is read
/// from the dictionary rather than through PDFium because the vendored build's
/// `FPDFAnnot_GetBorder` reports the `/Border` default of 1 pt for an annotation that only
/// states `/BS` — measured on the write-back round trip, where a 3 pt ink border came back as
/// 1 pt.
fn read_border_widths(path: &Path, password: Option<&str>) -> Option<HashMap<String, f64>> {
    let options = LoadOptions {
        password: password.map(str::to_owned),
        max_decompressed_size: Some(64 * 1024 * 1024),
        ..LoadOptions::default()
    };
    let document = Document::load_with_options(path, options).ok()?;
    let mut widths = HashMap::new();
    for (_, page_id) in document.get_pages() {
        let Ok(page) = document.get_dictionary(page_id) else {
            continue;
        };
        let Some(annots) =
            deref(&document, page.get(b"Annots").ok()?).and_then(|object| object.as_array().ok())
        else {
            continue;
        };
        for object in annots {
            let Some(annotation) =
                deref(&document, object).and_then(|object| object.as_dict().ok())
            else {
                continue;
            };
            let Some(name) = annotation
                .get(b"NM")
                .ok()
                .and_then(|object| deref(&document, object))
                .and_then(pdf_string)
            else {
                continue;
            };
            let width = annotation
                .get(b"BS")
                .ok()
                .and_then(|object| deref(&document, object))
                .and_then(|object| object.as_dict().ok())
                .and_then(|bs| {
                    bs.get(b"W")
                        .ok()
                        .and_then(|object| deref(&document, object))
                        .and_then(number)
                })
                .or_else(|| {
                    annotation
                        .get(b"Border")
                        .ok()
                        .and_then(|object| deref(&document, object))
                        .and_then(|object| object.as_array().ok())
                        .and_then(|array| array.get(2))
                        .and_then(|object| deref(&document, object))
                        .and_then(number)
                });
            if let Some(width) = width
                && width.is_finite()
                && width > 0.0
                && f64::from(width) <= MAX_BORDER_WIDTH_PT
            {
                widths.insert(name, f64::from(width));
            }
        }
    }
    Some(widths)
}

/// The `/LE` line-ending map of a PDF, keyed by `/NM`.
/// The `/LE` line-ending map of a PDF, keyed by `/NM`.
///
/// PDF 32000-1 table 184 stores line endings as names (`/ClosedArrow`, `/OpenArrow`, …) in an
/// array that starts with the start ending. This reader only needs "does either end name an
/// arrow", not the shape: the canvas draws the one arrow this application creates. `/Subj` and
/// `/IT /LineArrow` are accepted because producers use them too, and because our own writer
/// states `/Subj (Arrow)` beside the standard `/LE`.
fn read_line_endings(path: &Path, password: Option<&str>) -> Option<HashMap<String, bool>> {
    let options = LoadOptions {
        password: password.map(str::to_owned),
        max_decompressed_size: Some(64 * 1024 * 1024),
        ..LoadOptions::default()
    };
    let document = Document::load_with_options(path, options).ok()?;
    let mut endings = HashMap::new();
    for (_, page_id) in document.get_pages() {
        let Ok(page) = document.get_dictionary(page_id) else {
            continue;
        };
        let Some(annots) =
            deref(&document, page.get(b"Annots").ok()?).and_then(|o| o.as_array().ok())
        else {
            continue;
        };
        for object in annots {
            let Some(annotation) = deref(&document, object).and_then(|o| o.as_dict().ok()) else {
                continue;
            };
            if annotation.get(b"Subtype").and_then(Object::as_name).ok() != Some(b"Line") {
                continue;
            }
            let Some(name) = annotation
                .get(b"NM")
                .ok()
                .and_then(|object| deref(&document, object))
                .and_then(pdf_string)
            else {
                continue;
            };
            let mut arrow = annotation
                .get(b"Subj")
                .ok()
                .and_then(|object| deref(&document, object))
                .and_then(pdf_string)
                .is_some_and(|subject| subject.to_ascii_lowercase().contains("arrow"));
            arrow |= annotation
                .get(b"IT")
                .ok()
                .and_then(|object| deref(&document, object))
                .and_then(|object| object.as_name().ok())
                .is_some_and(|name| name.eq_ignore_ascii_case(b"LineArrow"));
            if let Some(le) = annotation
                .get(b"LE")
                .ok()
                .and_then(|object| deref(&document, object))
                .and_then(|object| object.as_array().ok())
            {
                arrow |= le.iter().any(|object| {
                    deref(&document, object)
                        .and_then(|object| object.as_name().ok())
                        .is_some_and(|name| {
                            !name.eq_ignore_ascii_case(b"None")
                                && name
                                    .windows(5)
                                    .any(|window| window.eq_ignore_ascii_case(b"arrow"))
                        })
                });
            }
            endings.insert(name, arrow);
        }
    }
    Some(endings)
}

fn number(object: &Object) -> Option<f32> {
    match object {
        Object::Integer(value) => Some(*value as f32),
        Object::Real(value) if value.is_finite() => Some(*value),
        _ => None,
    }
}

fn deref<'a>(document: &'a Document, object: &'a Object) -> Option<&'a Object> {
    document.dereference(object).ok().map(|(_, object)| object)
}

/// A PDF string as text: UTF-16BE with a BOM when it has one, UTF-8/Latin-1 otherwise.
///
/// `/NM` is an ASCII annotation name in every file this reader is tested against, but `/Subj`
/// is human text and may be a PDFDocEncoding or UTF-16 string. A lossy decode is the honest
/// answer here: the only consumer is an arrowhead flag.
fn pdf_string(object: &Object) -> Option<String> {
    let bytes = object.as_str().ok()?;
    if bytes.starts_with(&[0xFE, 0xFF]) {
        let units: Vec<u16> = bytes[2..]
            .chunks(2)
            .filter(|pair| pair.len() == 2)
            .map(|pair| u16::from_be_bytes([pair[0], pair[1]]))
            .collect();
        Some(String::from_utf16_lossy(&units))
    } else {
        Some(String::from_utf8_lossy(bytes).into_owned())
    }
}

fn subtype_kind(subtype: c_ulong) -> RawAnnotationKind {
    match subtype {
        ANNOT_HIGHLIGHT => RawAnnotationKind::Highlight,
        ANNOT_UNDERLINE => RawAnnotationKind::Underline,
        ANNOT_STRIKEOUT => RawAnnotationKind::Strikeout,
        ANNOT_SQUIGGLY => RawAnnotationKind::Squiggly,
        ANNOT_TEXT => RawAnnotationKind::Text,
        ANNOT_FREETEXT => RawAnnotationKind::FreeText,
        // The subtypes `is_content_annotation` skips are still named, so a future caller that
        // wants them (a form editor, a link inspector) gets a name rather than a number.
        ANNOT_LINK => RawAnnotationKind::Other("Link".to_string()),
        // PDFium reports 0 for a `/Subtype` name it does not recognise, which is also the right
        // answer for us: the annotation stays readable (rect, contents, author) but unclassified.
        0 => RawAnnotationKind::Other("Unknown".to_string()),
        ANNOT_LINE => RawAnnotationKind::Line,
        ANNOT_SQUARE => RawAnnotationKind::Square,
        ANNOT_CIRCLE => RawAnnotationKind::Circle,
        ANNOT_POLYGON => RawAnnotationKind::Other("Polygon".to_string()),
        ANNOT_POLYLINE => RawAnnotationKind::Other("Polyline".to_string()),
        ANNOT_STAMP => RawAnnotationKind::Stamp,
        ANNOT_CARET => RawAnnotationKind::Other("Caret".to_string()),
        ANNOT_INK => RawAnnotationKind::Ink,
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
    fn structural_annotations_are_not_content() {
        // Links are the measured case: 2751 of the corpus's 2767 annotations.
        assert!(!is_content_annotation(ANNOT_LINK));
        assert!(!is_content_annotation(ANNOT_WIDGET));
        assert!(!is_content_annotation(ANNOT_POPUP));
        // Everything somebody drew is content, including subtypes this build cannot draw.
        assert!(is_content_annotation(ANNOT_HIGHLIGHT));
        assert!(is_content_annotation(ANNOT_TEXT));
        assert!(is_content_annotation(ANNOT_FREETEXT));
        assert!(is_content_annotation(ANNOT_INK));
        assert!(is_content_annotation(ANNOT_STAMP));
    }

    /// The blend a markup annotation is composited with when the file states no `/BM`.
    ///
    /// This is the difference between "the highlight tints the text" and "the highlight paints over
    /// it": `Highlight`, `Underline` and `StrikeOut` are multiplied by PDFium and by Preview, while
    /// a squiggly is drawn beside the text and stays alpha-over. The table in
    /// [`RawAnnotationKind::default_blend`] is the measurement; this pins it.
    #[test]
    fn markup_kinds_carry_the_blend_they_are_drawn_with() {
        assert_eq!(
            subtype_kind(ANNOT_HIGHLIGHT).default_blend(),
            AnnotationBlend::Multiply
        );
        assert_eq!(
            subtype_kind(ANNOT_UNDERLINE).default_blend(),
            AnnotationBlend::Multiply
        );
        assert_eq!(
            subtype_kind(ANNOT_STRIKEOUT).default_blend(),
            AnnotationBlend::Multiply
        );
        assert_eq!(
            subtype_kind(ANNOT_SQUIGGLY).default_blend(),
            AnnotationBlend::Normal
        );
        // Notes and unmodelled subtypes have no markup drawing rule at all.
        assert_eq!(
            subtype_kind(ANNOT_TEXT).default_blend(),
            AnnotationBlend::Normal
        );
        assert_eq!(
            subtype_kind(ANNOT_FREETEXT).default_blend(),
            AnnotationBlend::Normal
        );
        assert_eq!(
            subtype_kind(ANNOT_INK).default_blend(),
            AnnotationBlend::Normal
        );
    }

    #[test]
    fn subtypes_map_to_the_kinds_the_reader_acts_on() {
        assert_eq!(subtype_kind(ANNOT_HIGHLIGHT), RawAnnotationKind::Highlight);
        assert_eq!(subtype_kind(ANNOT_UNDERLINE), RawAnnotationKind::Underline);
        assert_eq!(subtype_kind(ANNOT_STRIKEOUT), RawAnnotationKind::Strikeout);
        assert_eq!(subtype_kind(ANNOT_SQUIGGLY), RawAnnotationKind::Squiggly);
        assert_eq!(subtype_kind(ANNOT_TEXT), RawAnnotationKind::Text);
        assert_eq!(subtype_kind(ANNOT_FREETEXT), RawAnnotationKind::FreeText);
        assert_eq!(subtype_kind(ANNOT_INK), RawAnnotationKind::Ink);
        assert_eq!(subtype_kind(ANNOT_SQUARE), RawAnnotationKind::Square);
        assert_eq!(subtype_kind(ANNOT_CIRCLE), RawAnnotationKind::Circle);
        assert_eq!(subtype_kind(ANNOT_LINE), RawAnnotationKind::Line);
        // An unrecognised subtype stays readable, with the number in its name.
        assert_eq!(
            subtype_kind(999),
            RawAnnotationKind::Other("Subtype999".to_string())
        );
    }

    /// `/DA` is the only place a free-text annotation's size lives, and it is a content-stream
    /// fragment rather than a number. Every shape below is one this reader has to survive: the
    /// two the review corpus actually writes, a colour operator after the `Tf`, and the malformed
    /// ones a hand-edited file can carry.
    #[test]
    fn a_default_appearance_string_yields_its_font_size_or_nothing() {
        // The 22 Chinese free-text annotations in the review corpus: no colour operator at all.
        assert_eq!(font_size_from_da("/DFWaWaSC-W5 18.000 Tf"), Some(18.0));
        // The one the corpus writes alongside a text-rise operand.
        assert_eq!(font_size_from_da("/SimSun 12 Tf 16.25 TL "), Some(12.0));
        // A colour operator after the size, the shape most producers write.
        assert_eq!(font_size_from_da("/Helv 10 Tf 0 g"), Some(10.0));
        // Any whitespace separates operands, and the last operand before `Tf` is the size.
        assert_eq!(font_size_from_da("  /F1\t9.5\nTf "), Some(9.5));
        // A `Tf` with no size in front of it is not a size.
        assert_eq!(font_size_from_da("Tf"), None);
        assert_eq!(font_size_from_da("/Helv Tf"), None);
        assert_eq!(font_size_from_da("/Helv abc Tf"), None);
        // No `Tf` at all, an empty string, and nothing to read.
        assert_eq!(font_size_from_da("/Helv 12 rg"), None);
        assert_eq!(font_size_from_da(""), None);
        // A size no reader should draw: zero, negative, not finite, or larger than a page.
        assert_eq!(font_size_from_da("/Helv 0 Tf"), None);
        assert_eq!(font_size_from_da("/Helv -12 Tf"), None);
        assert_eq!(font_size_from_da("/Helv inf Tf"), None);
        assert_eq!(font_size_from_da("/Helv 4288 Tf"), None);
        assert_eq!(font_size_from_da("/Helv 200 Tf"), Some(200.0));
    }

    #[test]
    fn quadding_maps_to_the_three_alignments_with_left_as_the_default() {
        assert_eq!(
            AnnotationAlignment::from_quadding(0),
            AnnotationAlignment::Left
        );
        assert_eq!(
            AnnotationAlignment::from_quadding(1),
            AnnotationAlignment::Center
        );
        assert_eq!(
            AnnotationAlignment::from_quadding(2),
            AnnotationAlignment::Right
        );
        // Anything else is the PDF's own default rather than a guess.
        assert_eq!(
            AnnotationAlignment::from_quadding(7),
            AnnotationAlignment::Left
        );
        assert_eq!(
            AnnotationAlignment::from_quadding(-1),
            AnnotationAlignment::Left
        );
        assert_eq!(AnnotationAlignment::default(), AnnotationAlignment::Left);
        assert_eq!(AnnotationAlignment::Right.as_str(), "right");
    }
}
