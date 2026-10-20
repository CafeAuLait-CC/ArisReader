//! PDF engine interface.
//!
//! # Neutral DTO principle
//!
//! `lyra-reader-core` does **not** know about the rich models of `lyra-reader-text` / `lyra-reader-edit` (that would create a circular dependency).
//! The backend therefore returns **neutral DTOs**: [`RawTextPage`] (per-character boxes) and
//! the raw annotation-related queries on [`crate::backend::DocumentBackend`],
//! from which the upper-layer crates build the rich models:
//!
//! ```text
//! lyra-reader-core  (trait + RawTextPage)  ←──  lyra-reader-pdfium (implementation)
//!        ↑
//! lyra-reader-text                             lyra-reader-edit
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
    ///
    /// A raster requested with a transparent [`RasterRequest::background`] carries **straight
    /// (unpremultiplied)** coverage alpha instead: PDFium composites its marks onto the cleared
    /// buffer and the canvas's alpha-over blend consumes that form. Opaque pixels are identical
    /// under either interpretation, so the opaque page and tile paths are unaffected.
    Bgra8Premultiplied,
}

/// Rasterization options (corresponding to PDFium render flags).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RasterFlags {
    /// Whether to burn content annotations into the bitmap. Default **false**: the shell draws
    /// these so they can be edited live. Navigation link borders are always rendered as the PDF
    /// specifies, including zero-width/hidden borders.
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
    /// Background colour (RGBA, not premultiplied); the PDF page itself may be transparent.
    ///
    /// PDF pages paint no paper of their own, so a zero-alpha clear leaves the page background
    /// untouched and PDFium's coverage becomes the bitmap's alpha channel. That alpha is
    /// **straight (unpremultiplied)**, which is the form the canvas's alpha-over blend consumes;
    /// with the opaque white default every pixel is opaque and the distinction does not arise.
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
#[derive(Clone, Debug, PartialEq)]
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
    /// Font name as the engine reports it.
    ///
    /// Kept because it is the only practical handle on mathematical typesetting: LaTeX
    /// formulas come out in CMMI/CMSY/CMEX (or STIX/MathJax) rather than the body font, so a
    /// run of characters in those faces is a formula candidate.
    pub font_name: String,
}

/// Raw text layer of a single page.
///
/// **The order is the character order produced by the engine** (usually content stream order, which is not necessarily the visual reading order);
/// a reliable multi-column reading order requires `lyra-reader-text` to infer it from the structure tree or geometric clustering
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

/// What an annotation found inside a PDF is, reduced to what a reader can act on.
///
/// The four markup kinds carry quad points, which is what makes them drawable as highlights;
/// `Text` is a sticky note, drawn as its icon in `/Rect`, and `FreeText` is a note drawn directly
/// on the page, drawn as its own text in `/Rect`. Everything else is reported but not drawn —
/// [`AnnotationDrawing`] is where that "not drawn" comes with a reason attached.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RawAnnotationKind {
    Highlight,
    Underline,
    Strikeout,
    Squiggly,
    /// `/Text`: a sticky note.
    Text,
    /// `/FreeText`: text placed on the page.
    FreeText,
    /// `/Ink`: freehand strokes, carried in [`RawAnnotation::ink_paths`].
    Ink,
    /// `/Square`: a rectangle drawn with a stroke; its geometry is [`RawAnnotation::rect`].
    Square,
    /// `/Circle`: an ellipse drawn with a stroke; its geometry is [`RawAnnotation::rect`].
    Circle,
    /// `/Line`: a line from [`RawAnnotation::line`]'s start to its end. An arrowhead is the
    /// file's `/LE` (or this writer's `/Subj`), reported as [`RawAnnotation::line_arrow`].
    Line,
    /// `/Stamp`: a rubber stamp. Its text and/or image live in
    /// [`RawAnnotation::stamp`]; both the ones this reader writes and the ones another
    /// producer writes are reported the same way.
    Stamp,
    /// A subtype this build does not model; the PDF's own `/Subtype` name is carried with it.
    Other(String),
}

impl RawAnnotationKind {
    /// Stable lower-case name, used as-is across the FFI boundary.
    pub fn as_str(&self) -> &str {
        match self {
            Self::Highlight => "highlight",
            Self::Underline => "underline",
            Self::Strikeout => "strikeout",
            Self::Squiggly => "squiggly",
            Self::Text => "text",
            Self::FreeText => "freeText",
            Self::Ink => "ink",
            Self::Square => "square",
            Self::Circle => "circle",
            Self::Line => "line",
            Self::Stamp => "stamp",
            Self::Other(name) => name,
        }
    }

    /// Whether this is one of the four text-markup kinds the canvas draws geometry for.
    ///
    /// `Text` and `FreeText` are notes (drawn as a note icon and as text, not as markup boxes),
    /// and everything else is reported without a drawing rule. The shell has the same predicate
    /// (`DocumentAnnotation.isMarkup` in `apps/macos`); it is stated once here so the CLI dump and
    /// the canvas cannot disagree about which annotations are supposed to be drawn.
    pub fn is_markup(&self) -> bool {
        matches!(
            self,
            Self::Highlight | Self::Underline | Self::Strikeout | Self::Squiggly
        )
    }

    /// Whether this kind is a note: something whose `/Contents` is the point of it.
    ///
    /// The two note kinds are what a review PDF is mostly made of — measured 2026-10-15 on the
    /// seven annotated review PDFs the user supplied (`pdf-samples/with_annotations/`): 122 of
    /// their 242 content annotations are notes, and one of the seven is *only* notes.
    pub fn is_note(&self) -> bool {
        matches!(self, Self::Text | Self::FreeText)
    }

    /// The blend mode this kind is composited with when the file states no `/BM`.
    ///
    /// PDF 32000-1 table 164 gives `/Normal` as the dictionary default, but for the text-markup
    /// kinds that default is not what any viewer draws, and taking it literally is visible: a
    /// yellow highlight at `/CA 0.97` painted alpha-over turns the glyphs yellow and *erases*
    /// them, where a multiplied one leaves them black and only tints the paper.
    ///
    /// Measured 2026-10-15 against the vendored PDFium 157 (`FPDF_RenderPageBitmap` with
    /// `FPDF_ANNOT`, no `/BM` and no `/AP`, a black bar under a `/C [1 1 0] /CA 0.5` annotation):
    ///
    /// | `/Subtype`  | pixels over the black bar | PDFium's compositing |
    /// |-------------|---------------------------|----------------------|
    /// | `Highlight` | 0 of 3000 changed         | multiply             |
    /// | `Underline` | 300 changed, 0 yellow     | multiply             |
    /// | `StrikeOut` | 300 changed, 0 yellow     | multiply             |
    /// | `Squiggly`  | 375 changed, 150 yellow   | alpha-over           |
    /// | `Square`    | 318 changed, 318 yellow   | alpha-over           |
    ///
    /// (Multiply leaves a black backdrop black; alpha-over paints `a·c` over it, which for a
    /// yellow at half opacity is 128,128,0 — the "yellow" column.) Every `/Highlight`,
    /// `/Underline` and `/StrikeOut` in the local review corpus whose appearance stream is a
    /// plain object uses `/BM /Multiply` in its `ExtGState` for the same reason, so the default
    /// here agrees with both the file and the renderer.
    pub fn default_blend(&self) -> AnnotationBlend {
        match self {
            Self::Highlight | Self::Underline | Self::Strikeout => AnnotationBlend::Multiply,
            // A squiggly is drawn as a wave *beside* the text rather than through it, and PDFium
            // composites it alpha-over; a note's icon and its free text are opaque glyphs and
            // alpha-over too, and everything unmodelled is not drawn at all.
            Self::Squiggly
            | Self::Text
            | Self::FreeText
            | Self::Ink
            | Self::Square
            | Self::Circle
            | Self::Line
            | Self::Stamp
            | Self::Other(_) => AnnotationBlend::Normal,
        }
    }
}

/// How an annotation is composited with the page (`/BM`, the blend mode).
///
/// This is not decoration: highlights are normally stored as `/BM /Multiply`, and drawing one
/// with plain alpha-over produces a visibly different colour from what Preview shows for the
/// same file. The values this build can render are [`AnnotationBlend::Normal`] and
/// [`AnnotationBlend::Multiply`]; anything else is reported verbatim so the caller can say what
/// the file asked for instead of pretending it was normal.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub enum AnnotationBlend {
    #[default]
    Normal,
    Multiply,
    Other(String),
}

impl AnnotationBlend {
    /// Parses a `/BM` name (`/Multiply`, `/Screen`, …).
    pub fn from_pdf_name(name: &str) -> Self {
        match name {
            "Normal" | "Compatible" => Self::Normal,
            "Multiply" => Self::Multiply,
            other => Self::Other(other.to_string()),
        }
    }

    /// Stable name for the FFI and for diagnostics.
    pub fn as_str(&self) -> &str {
        match self {
            Self::Normal => "normal",
            Self::Multiply => "multiply",
            Self::Other(name) => name,
        }
    }
}

/// How a `/FreeText` annotation's text sits inside its rectangle (`/Q`, the quadding).
///
/// PDF 32000-1 table 174 gives `/Q` for free text (and for the markup kinds, where it does not
/// change any geometry this reader draws). The dictionary default is 0, which is left.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum AnnotationAlignment {
    #[default]
    Left,
    Center,
    Right,
}

impl AnnotationAlignment {
    /// `/Q`: 0 left, 1 centre, 2 right. Anything else — including a malformed value — is left,
    /// which is what the spec's default says rather than a guess at what the file meant.
    pub fn from_quadding(value: i64) -> Self {
        match value {
            1 => Self::Center,
            2 => Self::Right,
            _ => Self::Left,
        }
    }

    /// Stable lower-case name, used as-is across the FFI boundary.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Left => "left",
            Self::Center => "center",
            Self::Right => "right",
        }
    }
}

/// What a reader should put on the page for one annotation.
///
/// This exists so that "it is in the sidebar but not on the page" is always an *answer* rather
/// than an absence of one: every content annotation the reader reports classifies as exactly one
/// of these, and the only way to draw nothing is [`AnnotationDrawing::Skipped`], which carries the
/// reason. The CLI dump prints the same value the canvas acts on, so the two cannot drift.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AnnotationDrawing {
    /// One of the four text-markup kinds: a tinted box per `/QuadPoints` entry.
    Markup,
    /// `/Text`: the sticky note's icon, filling `/Rect`.
    NoteIcon,
    /// `/FreeText`: the annotation's own text, laid out in `/Rect`.
    FreeText,
    /// `/Ink`, `/Square`, `/Circle` or `/Line`: a stroked path the canvas draws from its
    /// page-space geometry (`ink_paths`, `line` or `rect`) in the annotation's colour and
    /// border width.
    Geometry,
    /// `/Stamp`: a stamp badge drawn from [`RawAnnotation::stamp`] — its text, or its image,
    /// in `/Rect`.
    Stamp,
    /// Nothing is drawn, for the reason carried.
    Skipped(AnnotationSkipReason),
}

impl AnnotationDrawing {
    /// Stable lower-case name, used as-is across the FFI boundary and by the CLI dump.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Markup => "markup",
            Self::NoteIcon => "noteIcon",
            Self::FreeText => "freeText",
            Self::Geometry => "geometry",
            Self::Stamp => "stamp",
            Self::Skipped(_) => "skipped",
        }
    }
}

/// Why an annotation the reader reports is not drawn.
///
/// Deliberately a closed set with a reason each: a reader that silently drops an annotation is
/// indistinguishable from one that cannot read it, which is the failure this whole area exists to
/// prevent.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AnnotationSkipReason {
    /// `/F` marks it `/Invisible`, `/Hidden` or `/NoView`; drawing it would contradict the file.
    ///
    /// The review corpus is full of these: 49 of its 99 sticky notes are "completed" markers that
    /// an Acrobat review workflow flagged hidden and left at `/Rect [0 0 1 1]`.
    Hidden,
    /// `/Rect` has no area, so there is no box to put an icon or a line of text in.
    EmptyRect,
    /// A `/FreeText` with no `/Contents`: there is no text to lay out, and this reader draws the
    /// annotation's text rather than its box. (A sticky note with no text is still drawn — its
    /// icon is the point, which is why that case is not here.)
    EmptyContents,
    /// The subtype has no drawing rule in this build (`Stamp`, …). Listing it is all this
    /// reader promises for now, and the PDF's own `/Subtype` name travels with the annotation.
    Unmodelled,
    /// A stroked geometry annotation whose dictionary carries no path to draw: an `/Ink` with
    /// an empty or unreadable `/InkList`, or a `/Line` with no `/L`.
    EmptyGeometry,
    /// A `/Stamp` whose only picture is an image in an encoding this build cannot read, and
    /// which carries no text to draw in its place.
    StampImageUnreadable,
}

impl AnnotationSkipReason {
    /// Stable lower-case name, used for diagnostics and by the CLI dump.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Hidden => "hidden",
            Self::EmptyRect => "empty-rect",
            Self::EmptyContents => "no-text",
            Self::Unmodelled => "unmodelled",
            Self::EmptyGeometry => "empty-geometry",
            Self::StampImageUnreadable => "stamp-image-unreadable",
        }
    }
}

/// An annotation colour as an 8-bit sRGB triple (`/C`, `/IC`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RawAnnotationColor {
    pub red: u8,
    pub green: u8,
    pub blue: u8,
}

/// A `/Line` annotation's endpoints, in page space (bottom-left origin).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RawAnnotationLine {
    pub start: Point,
    pub end: Point,
}

/// One `/Stamp` annotation's own content, reduced to what the reader can draw.
///
/// A stamp is either text, an image, or (in a malformed file) neither. Both the stamps this
/// reader writes and the ones another producer writes are reported the same way: `/Contents`,
/// `/Name`, the private keys this writer adds, and the appearance stream's own text and image
/// are read in that order, so a file written by Preview, PDFKit or Acrobat is still drawable.
#[derive(Clone, Debug, PartialEq)]
pub struct RawStamp {
    /// The words on the stamp, when the file states them or the appearance paints them.
    pub text: Option<String>,
    /// A stable style name: `approved`, `reviewed`, `draft`, `confidential`, `date`, or
    /// `custom` when the file does not say. It decides the colour and `/Name` the reader
    /// writes back, not what is drawn.
    pub style: String,
    /// The stamp's image, re-encoded as PNG or passed through as JPEG.
    pub image: Option<RawStampImage>,
    /// Why an image that is present could not be decoded; `None` when there is no image or it
    /// was decoded. The shell states this rather than pretending the stamp is empty.
    pub image_error: Option<String>,
}

/// One image carried by a `/Stamp` appearance stream.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RawStampImage {
    pub width: u32,
    pub height: u32,
    pub encoding: RawStampImageEncoding,
    /// The encoded bytes (`encoding` names the codec), ready for the shell's image decoder.
    pub data: Vec<u8>,
}

/// The codec of [`RawStampImage::data`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RawStampImageEncoding {
    /// A PNG this reader re-encoded from a FlateDecode image XObject (the usual case for a
    /// signature, including the PNG-with-transparency a reader chooses).
    Png,
    /// The file's own DCTDecode (JPEG) bytes, passed through. The shell decodes them with the
    /// same image library it uses for a chosen signature.
    Jpeg,
}

impl RawStampImageEncoding {
    /// Stable lower-case name across the FFI and the CLI dump.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Png => "png",
            Self::Jpeg => "jpeg",
        }
    }
}

/// One annotation that already exists inside the PDF.
///
/// Geometry is in **page space** (bottom-left origin), exactly like [`RawCharBox`]; the single
/// Y-flip into view space happens in the FFI layer through `PageGeometry::page_to_view`.
#[derive(Clone, Debug, PartialEq)]
pub struct RawAnnotation {
    pub page: PageIndex,
    /// Identity other annotations use to point at this one.
    ///
    /// The PDF gives an annotation a `/NM` (its "annotation name"), which is the only
    /// document-level identity PDFium's C API exposes: the handles from
    /// `FPDFPage_GetAnnot` are wrappers, so two calls that return the same annotation do not
    /// compare equal (measured against the review corpus, 2026-10-16). The reader therefore
    /// reports `/NM` as `nm:<name>`; when a file carries no `/NM`, it falls back to a stable
    /// fingerprint of the annotation's own dictionary so replies to it can still be
    /// recognised. See [`RawAnnotation::is_reply`] and [`RawAnnotation::parent_id`].
    pub id: String,
    /// The identity of the annotation this one answers through `/IRT`, when it is a reply.
    ///
    /// `None` means either "not a reply" (see [`RawAnnotation::is_reply`]) or "the file has
    /// an `/IRT` entry but PDFium could not resolve it"; the two cases are deliberately
    /// distinguished because only one of them is an orphaned reply.
    pub parent_id: Option<String>,
    /// Whether the file carries a `/IRT` entry for this annotation, making it a reply.
    ///
    /// The parent need not be on this page, and need not be something the reader shows
    /// (hidden annotations are still read). The shell is responsible for noticing when the
    /// parent is absent from the list it is rendering.
    pub is_reply: bool,
    /// Whether the file links a `/Popup` window to this annotation.
    ///
    /// A popup is a structural annotation and is not listed as an editable mark, but its text
    /// belongs to the annotation's review thread. Deleting the annotation deletes the window
    /// with it, so a caller that only *edits* geometry has to know it is there.
    pub has_popup: bool,
    pub kind: RawAnnotationKind,
    /// The annotation's `/Rect` — the icon box for a sticky note, the text box for free text.
    pub rect: Rect,
    /// `/QuadPoints`, one rectangle per quadrilateral, when the subtype carries them.
    ///
    /// Empty when the file has none. Consumers should fall back to `rect`: a highlight without
    /// `/QuadPoints` is malformed but does occur, and its `/Rect` is still the right box.
    pub quads: Vec<Rect>,
    /// `/InkList`: one entry per stroke, each a sequence of page-space points.
    ///
    /// Empty for every kind except `/Ink`; a malformed ink annotation with no list is still
    /// reported (and classified [`AnnotationDrawing::Skipped`] with
    /// [`AnnotationSkipReason::EmptyGeometry`]) so the reader never silently loses it.
    pub ink_paths: Vec<Vec<Point>>,
    /// `/L` for a `/Line` annotation, in page space; `None` for every other kind.
    pub line: Option<RawAnnotationLine>,
    /// Whether the line carries an arrowhead: the file's `/LE` names one, or its `/Subj` says
    /// "Arrow". Only meaningful for [`RawAnnotationKind::Line`].
    pub line_arrow: bool,
    /// `/BS /W` (the border width) in points, when the file states a usable one.
    ///
    /// `None` means "the file did not say"; the canvas then draws the `PDF` default of 1 pt.
    pub border_width: Option<f64>,
    /// `/C` — `None` when the file carries no colour at all (common for sticky notes, whose
    /// colour is the icon's, not the file's).
    pub color: Option<RawAnnotationColor>,
    /// `/CA`, the constant opacity, when the file states one.
    ///
    /// `None` means "the file did not say", which a reader should treat as opaque rather than
    /// as transparent.
    pub opacity: Option<f64>,
    pub blend: AnnotationBlend,
    /// `/Contents` — what the annotation says.
    pub contents: Option<String>,
    /// `/T` — who wrote it.
    pub author: Option<String>,
    /// `/M` — modification date, as the PDF writes it (`D:YYYYMMDDHHmmSS±HH'mm'`).
    pub modified: Option<String>,
    /// The font size `/DA` states, in points, when it states one.
    ///
    /// `/DA` is required on a `/FreeText` and is where the size of its text lives; PDF 32000-1
    /// table 174. It is read for every kind (the key is legal on all of them) and is `None` when
    /// the file carries no `/DA`, no `Tf` operator, or a size no reader should trust — a negative,
    /// zero, non-finite or absurdly large one. A caller that gets `None` has to choose a size; the
    /// shell draws free text at its own default and says so.
    pub font_size_pt: Option<f64>,
    /// `/Q`, how the text of a `/FreeText` is aligned in `/Rect`; the PDF default (left) when the
    /// file states none.
    pub alignment: AnnotationAlignment,
    /// The stamp's text and/or image. `Some` exactly for [`RawAnnotationKind::Stamp`].
    pub stamp: Option<RawStamp>,
    /// False when the file marks the annotation `/Hidden`, `/Invisible` or `/NoView`, i.e. when
    /// drawing it would contradict the file.
    pub visible: bool,
}

impl RawAnnotation {
    /// What to draw for this annotation.
    ///
    /// The single place the drawing rules live, so the CLI dump, the native checks and the canvas
    /// cannot disagree about which annotations are supposed to appear on the page. The shell's
    /// half of the same question is `DocumentAnnotation.placementKind` in `apps/macos`, which
    /// switches on the `kind` string this classification is named after.
    pub fn drawing(&self) -> AnnotationDrawing {
        if !self.visible {
            return AnnotationDrawing::Skipped(AnnotationSkipReason::Hidden);
        }
        // A box with no area cannot hold an icon or a line of text. A markup annotation is still
        // drawn from its `/QuadPoints` when it has them, so only the two note kinds care.
        let has_area = self.rect.size.width > 0.0 && self.rect.size.height > 0.0;
        let has_text = self
            .contents
            .as_deref()
            .is_some_and(|text| !text.trim().is_empty());
        match self.kind {
            RawAnnotationKind::Highlight
            | RawAnnotationKind::Underline
            | RawAnnotationKind::Strikeout
            | RawAnnotationKind::Squiggly => AnnotationDrawing::Markup,
            RawAnnotationKind::Text | RawAnnotationKind::FreeText if !has_area => {
                AnnotationDrawing::Skipped(AnnotationSkipReason::EmptyRect)
            }
            RawAnnotationKind::Text => AnnotationDrawing::NoteIcon,
            // This reader draws a free-text annotation's *text*, not its box, so a file that
            // carries no text has nothing to show — one such annotation is in the review corpus
            // (an empty 2×12 pt box), and drawing an empty box would put a mark on the page that
            // the file does not have.
            RawAnnotationKind::FreeText if !has_text => {
                AnnotationDrawing::Skipped(AnnotationSkipReason::EmptyContents)
            }
            RawAnnotationKind::FreeText => AnnotationDrawing::FreeText,
            RawAnnotationKind::Ink if self.ink_paths.is_empty() => {
                AnnotationDrawing::Skipped(AnnotationSkipReason::EmptyGeometry)
            }
            RawAnnotationKind::Line if self.line.is_none() => {
                AnnotationDrawing::Skipped(AnnotationSkipReason::EmptyGeometry)
            }
            RawAnnotationKind::Ink
            | RawAnnotationKind::Square
            | RawAnnotationKind::Circle
            | RawAnnotationKind::Line => AnnotationDrawing::Geometry,
            RawAnnotationKind::Stamp if !has_area => {
                AnnotationDrawing::Skipped(AnnotationSkipReason::EmptyRect)
            }
            RawAnnotationKind::Stamp => match &self.stamp {
                Some(stamp)
                    if stamp.image.is_some()
                        || stamp
                            .text
                            .as_deref()
                            .is_some_and(|text| !text.trim().is_empty()) =>
                {
                    AnnotationDrawing::Stamp
                }
                Some(stamp) if stamp.image_error.is_some() => {
                    AnnotationDrawing::Skipped(AnnotationSkipReason::StampImageUnreadable)
                }
                _ => AnnotationDrawing::Skipped(AnnotationSkipReason::Unmodelled),
            },
            RawAnnotationKind::Other(_) => {
                AnnotationDrawing::Skipped(AnnotationSkipReason::Unmodelled)
            }
        }
    }
}

/// PDF engine interface. See `lyra-reader-pdfium` for an implementation (the first backend); a pure Rust backend may follow.
///
/// **Threading rules**: implementations must be `Send + Sync`, but PDFium itself is not thread-safe —
/// `lyra-reader-pdfium` handles this with "one document copy per raster thread" while still exposing a `Sync`
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

    /// Annotations **already stored in the document** (highlights, notes, free text, …).
    ///
    /// Read-only and page-scoped like [`DocumentBackend::links`]: this is what someone else's
    /// PDF carries, not what this application wrote (that lives in the sidecar).
    fn annotations(&self, page: PageIndex) -> Result<Vec<RawAnnotation>>;

    /// Raw text layer (built lazily and cached by the upper layer).
    fn raw_text_page(&self, page: PageIndex) -> Result<RawTextPage>;

    /// The document's own description of itself: `/Info` plus the XMP metadata stream.
    ///
    /// Deliberately raw. No field is cleaned or rejected here, because "empty" and "garbage"
    /// are recognition questions and a backend that silently dropped a placeholder title would
    /// hide the evidence from the panel that shows the reader where each field came from.
    /// Implementations that cannot read metadata return [`EmbeddedMetadata::default`].
    fn embedded_metadata(&self) -> Result<crate::document::EmbeddedMetadata> {
        Ok(crate::document::EmbeddedMetadata::default())
    }

    /// Rasterize (CPU, PDFium).
    fn rasterize(&self, request: &RasterRequest) -> Result<RasterTile>;

    /// Whether the document is encrypted (and has been unlocked with a password).
    fn is_encrypted(&self) -> bool;

    /// Whether the document has a tagged structure (determines the reading-order strategy).
    fn is_tagged(&self) -> bool;

    /// Save incrementally to a new file (M3: used after annotation/page operations).
    fn save_incremental(&self, target: &Path) -> Result<u64> {
        let _ = target;
        Err(crate::error::LyraReaderError::not_implemented(
            "save_incremental (T3.7)",
        ))
    }
}
