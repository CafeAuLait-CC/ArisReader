//! Feasibility analysis for in-place text editing (task T3.18, phase one).
//!
//! This module is **read-only**. It answers, for every string operand on every page, whether the
//! characters could be replaced in place without corrupting the document, and if not, why not.
//! The rules are conservative by construction:
//!
//! * a run is one string operand of one text-showing operator (`Tj`, `TJ`, `'`, `"`); a numeric
//!   adjustment inside a `TJ` array ends a run and cannot be crossed;
//! * text inside a form XObject, under an active clip, painted with a pattern, rotated, vertical,
//!   invisible, or set in a font whose widths or Unicode mapping cannot be computed is refused;
//! * the replacement may advance no further than the distance from the run's origin to the next
//!   glyph on the same baseline, or — for the last run on a line — to the right edge of the crop
//!   box;
//! * only characters whose glyphs already exist in the same font may be typed; for a subset font
//!   that means characters the document has already drawn with that font.
//!
//! Nothing here creates, opens for writing, or modifies a PDF. Phase two would build on the
//! analysis, but only after this study shows a safe subset worth shipping.

pub(crate) mod content;
pub(crate) mod font;

use content::{Glyph, ParsedPage, RunCandidate};
use font::{FontData, FontProblem, FontSubtype, WidthSource};
use lyra_reader_core::{DocumentBackend, ErrorCode, LyraReaderError, PageIndex, Rect, Result};
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::{Path, PathBuf};

/// Why one run is refused.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum TextEditRefusalReason {
    /// The document is encrypted; the analysis does not attempt a decrypted rewrite.
    EncryptedDocument,
    /// The document follows the existing read-only policy for signed files.
    SignedDocument,
    /// A page's content stream could not be parsed.
    ContentUnreadable,
    /// PDFium's character sequence and the content-stream glyph sequence disagree, so a run cannot
    /// be mapped to what the viewer shows.
    MappingMismatch,
    /// The glyphs come from a form XObject, which is shared content and not edited in place.
    FormXObject,
    /// A clipping path is active while the text is painted.
    ClippedText,
    /// Text is filled or stroked with a pattern.
    PatternText,
    /// The effective text matrix rotates or mirrors the glyphs.
    RotatedText,
    /// The font is vertical (`Identity-V` / `/WMode 1`).
    VerticalText,
    /// Render mode 3 (invisible) or 7 (clip).
    InvisibleText,
    /// The run is a string inside a `TJ` array that also carries numeric kerning adjustments.
    /// The conservative policy refuses it: re-spacing the rest of the array is a writer change
    /// this phase does not propose.
    TjKerningAdjustment,
    /// A form, inline image, shading or other content the walker cannot attribute.
    UnsupportedContent,
    /// A Type3 font, whose glyph procedures this analysis does not model.
    Type3Font,
    /// A font subtype the analysis does not know.
    UnsupportedFont,
    /// A code-to-Unicode bridge this analysis cannot build (`/ToUnicode` missing or an embedded
    /// CMap).
    UnsupportedEncoding,
    /// The font's widths are absent, malformed, or a code has no stated width.
    MissingWidths,
    /// The font has no usable code-to-Unicode mapping.
    MissingUnicodeMapping,
    /// A string is not a whole number of codes for its font.
    MalformedString,
    /// The computed glyph origin disagrees with PDFium's, so the run's geometry is not trusted.
    PositionMismatch,
    /// The decoded text disagrees with PDFium's Unicode sequence.
    UnicodeMismatch,
    /// The run contains only whitespace, which is not useful to replace.
    WhitespaceOnly,
    /// The font has no character this analysis could type into the run.
    NoReplacementCharacters,
    /// The next glyph on the line is already at or before the run's origin.
    NoRoom,
}

impl TextEditRefusalReason {
    /// Stable machine name used by the CLI's JSON output.
    pub fn code(self) -> &'static str {
        match self {
            Self::EncryptedDocument => "encryptedDocument",
            Self::SignedDocument => "signedDocument",
            Self::ContentUnreadable => "contentUnreadable",
            Self::MappingMismatch => "mappingMismatch",
            Self::FormXObject => "formXObject",
            Self::ClippedText => "clippedText",
            Self::PatternText => "patternText",
            Self::RotatedText => "rotatedText",
            Self::VerticalText => "verticalText",
            Self::InvisibleText => "invisibleText",
            Self::TjKerningAdjustment => "tjKerningAdjustment",
            Self::UnsupportedContent => "unsupportedContent",
            Self::Type3Font => "type3Font",
            Self::UnsupportedFont => "unsupportedFont",
            Self::UnsupportedEncoding => "unsupportedEncoding",
            Self::MissingWidths => "missingWidths",
            Self::MissingUnicodeMapping => "missingUnicodeMapping",
            Self::MalformedString => "malformedString",
            Self::PositionMismatch => "positionMismatch",
            Self::UnicodeMismatch => "unicodeMismatch",
            Self::WhitespaceOnly => "whitespaceOnly",
            Self::NoReplacementCharacters => "noReplacementCharacters",
            Self::NoRoom => "noRoom",
        }
    }

    /// One sentence a person can act on.
    pub fn sentence(self) -> &'static str {
        match self {
            Self::EncryptedDocument => {
                "The document is encrypted; a decrypted rewrite cannot be verified, so it is not attempted."
            }
            Self::SignedDocument => {
                "The document is digitally signed and follows the existing read-only-in-place policy."
            }
            Self::ContentUnreadable => "A page content stream could not be parsed.",
            Self::MappingMismatch => {
                "The viewer's characters and the content-stream glyphs do not map one-to-one, so a run cannot be addressed safely."
            }
            Self::FormXObject => {
                "The text is inside a form XObject, whose appearance is shared content rather than one line."
            }
            Self::ClippedText => "The text is painted inside an active clipping path.",
            Self::PatternText => "The text is painted with a pattern.",
            Self::RotatedText => "The text is rotated, mirrored or sheared.",
            Self::VerticalText => "The font writes vertically.",
            Self::InvisibleText => "The text is invisible or used as a clipping path.",
            Self::TjKerningAdjustment => {
                "The run sits inside a TJ array that uses numeric kerning adjustments; the conservative policy does not re-space the rest of the array."
            }
            Self::UnsupportedContent => "The page contains content this analysis cannot attribute.",
            Self::Type3Font => {
                "The text uses a Type3 font, whose glyph procedures are not modelled."
            }
            Self::UnsupportedFont => "The text uses a font subtype this analysis does not know.",
            Self::UnsupportedEncoding => {
                "The font's encoding is an embedded CMap, vertical, or otherwise unsupported."
            }
            Self::MissingWidths => {
                "One or more glyph widths cannot be computed from /Widths or /W."
            }
            Self::MissingUnicodeMapping => {
                "The font has no usable /ToUnicode (or equivalent) character mapping."
            }
            Self::MalformedString => "A text string is not a whole number of character codes.",
            Self::PositionMismatch => {
                "The computed glyph position disagrees with the viewer's text layer."
            }
            Self::UnicodeMismatch => "The decoded text disagrees with the viewer's text layer.",
            Self::WhitespaceOnly => "The run contains only whitespace.",
            Self::NoReplacementCharacters => {
                "The font contains no character this analysis can type into the run."
            }
            Self::NoRoom => "The run has no room before the next glyph.",
        }
    }
}

/// A page run that passed every safety rule, or one that did not and carries the first failing
/// rule.
#[derive(Clone, Debug, PartialEq)]
pub struct TextEditRun {
    pub text: String,
    /// Bounding box in PDF user space (origin bottom-left).
    pub rect: Rect,
    pub font: TextEditFontInfo,
    /// Effective font size in page units.
    pub font_size: f64,
    pub operator: TextEditOperator,
    /// True when the run is a string inside a `TJ` array that also carries numeric adjustments.
    pub tj_adjusted: bool,
    /// Index of the operator in the page's decoded content stream.
    pub operator_index: usize,
    /// The run's advance in page units.
    pub original_advance: f64,
    /// Room from the run's origin to the next glyph on the same baseline, or to the crop box's
    /// right edge for the last run on a line.
    pub available_advance: f64,
    pub at_line_end: bool,
    /// Removing the whole run leaves no visible gap only when it is the last run on its line.
    pub deletion_safe: bool,
    /// Distinct characters this analysis can type into the run using the existing font.
    pub replacement_char_count: usize,
    /// At most 64 of those characters, in sorted order, for a human sample.
    pub replacement_sample: String,
    /// `None` when the run is editable.
    pub refusal: Option<TextEditRefusalReason>,
    /// Extra context for a refusal, when there is one (`form Fm1`, `font F2`, …).
    pub detail: Option<String>,
}

impl TextEditRun {
    pub fn is_editable(&self) -> bool {
        self.refusal.is_none()
    }
}

/// The public font facts the report prints.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TextEditFontInfo {
    pub base_font: String,
    pub subtype: TextEditFontSubtype,
    pub embedded: bool,
    pub subset: bool,
    pub vertical: bool,
    pub to_unicode: bool,
    pub encoding: String,
    pub width_source: TextEditWidthSource,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextEditFontSubtype {
    Simple,
    Type0,
    Type3,
    Other,
}

impl TextEditFontSubtype {
    pub fn code(self) -> &'static str {
        match self {
            Self::Simple => "simple",
            Self::Type0 => "type0",
            Self::Type3 => "type3",
            Self::Other => "other",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextEditWidthSource {
    SimpleWidths,
    Type0W,
    Unavailable,
}

impl TextEditWidthSource {
    pub fn code(self) -> &'static str {
        match self {
            Self::SimpleWidths => "widths",
            Self::Type0W => "w",
            Self::Unavailable => "unavailable",
        }
    }
}

/// The text-showing operator that produced a run.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextEditOperator {
    Tj,
    TjArrayString,
    TjQuote,
    TjDoubleQuote,
}

impl TextEditOperator {
    pub fn code(self) -> &'static str {
        match self {
            Self::Tj => "Tj",
            Self::TjArrayString => "TJ",
            Self::TjQuote => "'",
            Self::TjDoubleQuote => "\"",
        }
    }
}

/// How many runs/chars one refusal covers on a page.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TextEditRefusalStats {
    pub runs: usize,
    pub characters: usize,
}

/// One page's analysis.
#[derive(Clone, Debug, PartialEq)]
pub struct TextEditPageAnalysis {
    pub page: u32,
    pub crop: Rect,
    /// Characters PDFium reports for the page (synthetic line breaks removed).
    pub text_characters: usize,
    /// Glyphs found in the page's own content streams and its form XObjects.
    pub glyphs: usize,
    pub runs: Vec<TextEditRun>,
    pub refusals: BTreeMap<TextEditRefusalReason, TextEditRefusalStats>,
    pub editable_runs: usize,
    pub editable_characters: usize,
    pub refused_characters: usize,
    /// Numeric `TJ` adjustments, each of which is a boundary a replacement may not cross.
    pub tj_boundaries: usize,
    pub page_refusal: Option<TextEditRefusalReason>,
    pub note: Option<String>,
}

/// Document totals.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TextEditTotals {
    pub pages: usize,
    pub pages_with_editable_runs: usize,
    pub runs: usize,
    pub editable_runs: usize,
    pub refused_runs: usize,
    pub glyphs: usize,
    pub text_characters: usize,
    pub editable_characters: usize,
    pub refused_characters: usize,
    pub tj_boundaries: usize,
    pub refusals: BTreeMap<TextEditRefusalReason, TextEditRefusalStats>,
}

/// How strictly the analysis treats `TJ` arrays that carry kerning adjustments.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextEditPolicy {
    /// Refuse every string inside a `TJ` array that has a numeric adjustment. This is the policy
    /// phase one proposes; it never needs to re-space a neighbouring element.
    Conservative,
    /// Report such strings as addressable for measurement only. No writer is proposed under this
    /// policy, because a replacement there requires rewriting the following `TJ` number.
    AllowTjKerning,
}

impl TextEditPolicy {
    pub fn code(self) -> &'static str {
        match self {
            Self::Conservative => "conservative",
            Self::AllowTjKerning => "allowTjKerning",
        }
    }
}

/// The feasibility report for one document.
#[derive(Clone, Debug, PartialEq)]
pub struct TextEditAnalysis {
    pub path: PathBuf,
    pub page_count: u32,
    pub encrypted: bool,
    pub signed: bool,
    pub policy: TextEditPolicy,
    pub signature_summary: String,
    /// Set when the whole document is refused (encrypted or signed).
    pub document_refusal: Option<TextEditRefusalReason>,
    pub doc_note: Option<String>,
    pub pages: Vec<TextEditPageAnalysis>,
    pub totals: TextEditTotals,
}

impl TextEditAnalysis {
    /// Whether any page has at least one run this analysis would let phase two replace.
    pub fn has_editable_runs(&self) -> bool {
        self.totals.editable_runs > 0
    }
}

/// Analyse `path` without modifying it.
///
/// PDFium is used only for the text layer (character order, origins and boxes); `lopdf` is used
/// only to read dictionaries and content streams. Neither is asked to write.
pub fn analyze_text_edit(path: &Path, password: Option<&str>) -> Result<TextEditAnalysis> {
    analyze_text_edit_with_policy(path, password, TextEditPolicy::Conservative)
}

/// Analyse `path` under an explicit `TJ` policy. Both policies are read-only.
pub fn analyze_text_edit_with_policy(
    path: &Path,
    password: Option<&str>,
    policy: TextEditPolicy,
) -> Result<TextEditAnalysis> {
    let bytes = fs::read(path).map_err(|error| {
        LyraReaderError::new(ErrorCode::Io, format!("cannot read {}", path.display()))
            .with_detail(error.to_string())
    })?;
    let document = lopdf::Document::load_mem(&bytes).map_err(|error| {
        LyraReaderError::new(
            ErrorCode::CorruptDocument,
            format!("cannot parse {}", path.display()),
        )
        .with_detail(error.to_string())
    })?;
    // `lopdf`'s page map is keyed 1..=N; PDFium and the rest of the engine index from zero.
    let page_ids: Vec<(u32, lopdf::ObjectId)> = document
        .get_pages()
        .into_iter()
        .map(|(number, id)| (number.saturating_sub(1), id))
        .collect();
    let page_count = page_ids.len() as u32;
    let encrypted = document.is_encrypted();
    let signature = crate::detect_signature(path, password, 0);
    let signed = signature.is_signed();

    if encrypted {
        return Ok(TextEditAnalysis {
            path: path.to_path_buf(),
            page_count,
            encrypted: true,
            signed,
            policy,
            signature_summary: signature.summary(),
            document_refusal: Some(TextEditRefusalReason::EncryptedDocument),
            doc_note: Some("The document is encrypted; this analysis does not decrypt it.".into()),
            pages: Vec::new(),
            totals: TextEditTotals {
                pages: page_count as usize,
                ..TextEditTotals::default()
            },
        });
    }

    let backend = crate::PdfiumBackend::open(path, password)?;

    let mut pages = Vec::with_capacity(page_ids.len());
    for (page, page_id) in &page_ids {
        pages.push(analyze_page(&document, &backend, *page, *page_id, policy));
    }

    let mut analysis = TextEditAnalysis {
        path: path.to_path_buf(),
        page_count,
        encrypted: false,
        signed,
        policy,
        signature_summary: signature.summary(),
        document_refusal: signed.then_some(TextEditRefusalReason::SignedDocument),
        doc_note: signed.then(|| signature.read_only_reason().unwrap_or_default()),
        pages,
        totals: TextEditTotals::default(),
    };
    if signed {
        // The policy is a document-level refusal: keep the analysis for reading, but no run is
        // offered for replacement.
        for page in &mut analysis.pages {
            for run in &mut page.runs {
                if run.refusal.is_none() {
                    run.refusal = Some(TextEditRefusalReason::SignedDocument);
                    run.detail = Some(signature.summary());
                }
            }
            recompute_page_counts(page);
        }
    }
    analysis.totals = totals(&analysis.pages);
    Ok(analysis)
}

fn analyze_page(
    document: &lopdf::Document,
    backend: &crate::PdfiumBackend,
    page: u32,
    page_id: lopdf::ObjectId,
    policy: TextEditPolicy,
) -> TextEditPageAnalysis {
    let crop = backend
        .page_info(PageIndex(page))
        .map(|info| info.geometry.crop_box)
        .unwrap_or_else(|_| Rect::new(0.0, 0.0, 0.0, 0.0));
    let content = document.get_page_content(page_id);
    let parsed = content::parse_page(document, page_id, &content);
    let raw = match backend.raw_text_page(PageIndex(page)) {
        Ok(raw) => raw,
        Err(error) => {
            return empty_page(
                page,
                crop,
                Some(TextEditRefusalReason::ContentUnreadable),
                Some(error.to_string()),
            );
        }
    };
    let raw_chars: Vec<&lyra_reader_core::RawCharBox> = raw
        .chars
        .iter()
        .filter(|character| !is_generated(character))
        .collect();
    if let Some(problem) = parsed.problem {
        return TextEditPageAnalysis {
            page,
            crop,
            text_characters: raw_chars.len(),
            glyphs: parsed.glyphs.len(),
            runs: Vec::new(),
            refusals: BTreeMap::new(),
            editable_runs: 0,
            editable_characters: 0,
            refused_characters: raw_chars.len(),
            tj_boundaries: parsed.tj_boundaries,
            page_refusal: Some(problem),
            note: parsed.note,
        };
    }
    let Some(mut page_analysis) = build_runs(crop, &parsed, &raw_chars, policy) else {
        let note = Some(format!(
            "{} glyph(s) in the content streams but {} character(s) in the text layer",
            parsed.glyphs.len(),
            raw_chars.len()
        ));
        return TextEditPageAnalysis {
            page,
            crop,
            text_characters: raw_chars.len(),
            glyphs: parsed.glyphs.len(),
            runs: Vec::new(),
            refusals: BTreeMap::new(),
            editable_runs: 0,
            editable_characters: 0,
            refused_characters: raw_chars.len(),
            tj_boundaries: parsed.tj_boundaries,
            page_refusal: Some(TextEditRefusalReason::MappingMismatch),
            note,
        };
    };
    page_analysis.page = page;
    page_analysis.crop = crop;
    page_analysis.tj_boundaries = parsed.tj_boundaries;
    recompute_page_counts(&mut page_analysis);
    page_analysis
}

fn empty_page(
    page: u32,
    crop: Rect,
    refusal: Option<TextEditRefusalReason>,
    note: Option<String>,
) -> TextEditPageAnalysis {
    TextEditPageAnalysis {
        page,
        crop,
        text_characters: 0,
        glyphs: 0,
        runs: Vec::new(),
        refusals: BTreeMap::new(),
        editable_runs: 0,
        editable_characters: 0,
        refused_characters: 0,
        tj_boundaries: 0,
        page_refusal: refusal,
        note,
    }
}

fn is_generated(character: &lyra_reader_core::RawCharBox) -> bool {
    matches!(character.unicode, 10 | 13)
        && character.rect.size.width <= 1e-6
        && character.rect.size.height <= 1e-6
}

/// Pair the content walk with PDFium's character sequence, then decide each run.
fn build_runs(
    crop: Rect,
    parsed: &ParsedPage,
    raw: &[&lyra_reader_core::RawCharBox],
    policy: TextEditPolicy,
) -> Option<TextEditPageAnalysis> {
    let alignment = align_glyphs(&parsed.glyphs, raw);
    if alignment.matched == 0 && !parsed.glyphs.is_empty() && !raw.is_empty() {
        return None;
    }
    if parsed.glyphs.is_empty() && !raw.is_empty() {
        return None;
    }
    let ranges = &alignment.ranges;
    let unicode_mismatch = &alignment.unicode_mismatch;
    let position_mismatch = &alignment.position_mismatch;
    let observed = observed_codes(parsed, ranges, unicode_mismatch);

    let mut runs = Vec::with_capacity(parsed.runs.len());
    for candidate in &parsed.runs {
        runs.push(decide_run(
            crop,
            parsed,
            raw,
            candidate,
            ranges,
            unicode_mismatch,
            position_mismatch,
            &observed,
            policy,
        ));
    }
    let mut analysis = TextEditPageAnalysis {
        page: 0,
        crop,
        text_characters: raw.len(),
        glyphs: parsed.glyphs.len(),
        runs,
        refusals: BTreeMap::new(),
        editable_runs: 0,
        editable_characters: 0,
        refused_characters: 0,
        tj_boundaries: parsed.tj_boundaries,
        page_refusal: None,
        note: None,
    };
    recompute_page_counts(&mut analysis);
    Some(analysis)
}

struct Alignment {
    ranges: Vec<(usize, usize)>,
    unicode_mismatch: Vec<bool>,
    position_mismatch: Vec<bool>,
    matched: usize,
}

/// Pair each content glyph with the PDFium character at the same place.
///
/// PDFium's text layer is not a byte-for-byte mirror of the content stream: it inserts spaces for
/// visual word gaps, can collapse a ligature glyph into several characters (or one U+FFFD), and
/// omits glyphs it cannot render. Pairing by position rather than by Unicode sequence keeps later
/// glyphs aligned through those differences. A glyph with no nearby character, or one whose
/// decoded text disagrees with the character found there, marks its run as refused; it never
/// aborts the whole page unless *no* glyph could be paired at all.
fn align_glyphs(glyphs: &[Glyph], raw: &[&lyra_reader_core::RawCharBox]) -> Alignment {
    let mut alignment = Alignment {
        ranges: vec![(0, 0); glyphs.len()],
        unicode_mismatch: vec![false; glyphs.len()],
        position_mismatch: vec![false; glyphs.len()],
        matched: 0,
    };
    let mut cursor = 0usize;
    for (glyph_index, glyph) in glyphs.iter().enumerate() {
        let tolerance = (glyph.font_size * 0.08).clamp(0.75, 2.0);
        let decoded: Vec<Option<char>> = match &glyph.text {
            Some(text) => text.chars().map(Some).collect(),
            None => vec![None],
        };
        let wanted = decoded.len();
        let first_character = decoded.first().copied().flatten();
        let whitespace_glyph = first_character.is_some_and(char::is_whitespace);
        let mut found = None;
        let search_end = (cursor + 64).min(raw.len());
        for (index, character) in raw.iter().enumerate().take(search_end).skip(cursor) {
            let actual = char::from_u32(character.unicode);
            if actual.is_some_and(char::is_whitespace) && !whitespace_glyph {
                // A space PDFium inserted for a word gap that the content stream painted as a
                // positioning adjustment. It belongs to no glyph.
                continue;
            }
            let dx = glyph.origin[0] - character.origin.x;
            let dy = glyph.origin[1] - character.origin.y;
            if dx.abs() <= tolerance && dy.abs() <= tolerance {
                found = Some(index);
                break;
            }
        }
        let Some(start) = found else {
            if whitespace_glyph {
                // A content space that PDFium merged into a gap: harmless, no character to edit.
                continue;
            }
            alignment.position_mismatch[glyph_index] = true;
            continue;
        };
        let mut consumed = 1usize;
        if wanted > 1 {
            // A ligature: consume the following characters that occupy the same narrow band.
            for offset in 1..wanted {
                let index = start + offset;
                if index >= raw.len() {
                    break;
                }
                let dx = glyph.origin[0] - raw[index].origin.x;
                let dy = glyph.origin[1] - raw[index].origin.y;
                if dx.abs() <= tolerance.max(1.0) && dy.abs() <= tolerance {
                    consumed += 1;
                } else {
                    break;
                }
            }
        }
        alignment.matched += 1;
        alignment.ranges[glyph_index] = (start, start + consumed);
        if decoded.len() != consumed && !(decoded.len() == 1 && decoded[0].is_none()) {
            alignment.unicode_mismatch[glyph_index] = true;
        }
        if let Some(expected) = &glyph.text {
            for (offset, character) in expected.chars().enumerate() {
                let index = start + offset;
                if index >= start + consumed {
                    break;
                }
                if raw[index].unicode != character as u32 {
                    alignment.unicode_mismatch[glyph_index] = true;
                }
            }
        }
        let dx = glyph.origin[0] - raw[start].origin.x;
        let dy = glyph.origin[1] - raw[start].origin.y;
        if dx.abs() > tolerance || dy.abs() > tolerance {
            alignment.position_mismatch[glyph_index] = true;
        }
        cursor = start + consumed;
    }
    alignment
}

#[allow(clippy::too_many_arguments)]
fn decide_run(
    crop: Rect,
    parsed: &ParsedPage,
    raw: &[&lyra_reader_core::RawCharBox],
    candidate: &RunCandidate,
    ranges: &[(usize, usize)],
    unicode_mismatch: &[bool],
    position_mismatch: &[bool],
    observed: &HashMap<String, HashMap<char, u32>>,
    policy: TextEditPolicy,
) -> TextEditRun {
    let glyphs: &[Glyph] = &parsed.glyphs[candidate.start..candidate.end];
    let font = &candidate.font;
    let mut text = String::new();
    let mut any_unmapped = false;
    let mut rect: Option<Rect> = None;
    for (offset, glyph) in glyphs.iter().enumerate() {
        let range = ranges[candidate.start + offset];
        if let Some(decoded) = &glyph.text {
            text.push_str(decoded);
        } else {
            any_unmapped = true;
            text.push_str(&raw_char_text(raw[range.0]));
        }
        for character in &raw[range.0..range.1] {
            rect = Some(union(rect, character.rect));
        }
    }
    let rect = rect.unwrap_or_else(|| {
        Rect::new(
            glyphs.first().map_or(0.0, |glyph| glyph.origin[0]),
            glyphs.first().map_or(0.0, |glyph| glyph.origin[1]),
            glyphs
                .iter()
                .map(|glyph| glyph.advance)
                .sum::<f64>()
                .max(0.1),
            candidate.font_size.max(1.0),
        )
    });

    let start_x = glyphs.first().map_or(0.0, |glyph| glyph.origin[0]);
    let baseline = glyphs.first().map_or(0.0, |glyph| glyph.origin[1]);
    let font_size = candidate.font_size;
    let line_tolerance = (font_size * 0.3).clamp(0.5, 3.0);
    let run_raw_range = (
        ranges[candidate.start].0,
        ranges[candidate.end - 1].1.max(ranges[candidate.start].0),
    );
    let next_origin = raw
        .iter()
        .enumerate()
        .filter(|(index, _)| *index < run_raw_range.0 || *index >= run_raw_range.1)
        .filter(|(_, character)| {
            (character.origin.y - baseline).abs() <= line_tolerance
                && character.origin.x > start_x + 0.01
        })
        .map(|(_, character)| character.origin.x)
        .fold(None, |minimum: Option<f64>, x| {
            Some(minimum.map_or(x, |value| value.min(x)))
        });
    let (available_advance, at_line_end) = match next_origin {
        Some(next) => (next - start_x, false),
        None => (crop.origin.x + crop.size.width - start_x, true),
    };
    let original_advance = glyphs.iter().map(|glyph| glyph.advance).sum::<f64>();
    let mut replacement: Vec<char> = font
        .replacement_chars(observed.get(&font.base_font))
        .into_iter()
        .filter(|character| !character.is_control())
        .collect();
    replacement.sort_unstable();
    replacement.dedup();
    let replacement_sample: String = replacement.iter().take(64).collect();
    let replacement_char_count = replacement.len();

    let mut refusal = None;
    let mut detail = None;

    if candidate.flags & content::FLAG_IN_FORM != 0 {
        note_refusal(
            &mut refusal,
            &mut detail,
            TextEditRefusalReason::FormXObject,
            Some("form XObject".into()),
        );
    }
    if candidate.flags & content::FLAG_CLIPPED != 0 {
        note_refusal(
            &mut refusal,
            &mut detail,
            TextEditRefusalReason::ClippedText,
            Some("active clip".into()),
        );
    }
    if candidate.flags & content::FLAG_PATTERN != 0 {
        note_refusal(
            &mut refusal,
            &mut detail,
            TextEditRefusalReason::PatternText,
            Some("pattern colour".into()),
        );
    }
    if candidate.flags & content::FLAG_ROTATED != 0 {
        note_refusal(
            &mut refusal,
            &mut detail,
            TextEditRefusalReason::RotatedText,
            Some("non-horizontal text matrix".into()),
        );
    }
    if candidate.flags & content::FLAG_VERTICAL != 0 {
        note_refusal(
            &mut refusal,
            &mut detail,
            TextEditRefusalReason::VerticalText,
            Some(font.base_font.clone()),
        );
    }
    if candidate.flags & content::FLAG_INVISIBLE != 0 {
        note_refusal(
            &mut refusal,
            &mut detail,
            TextEditRefusalReason::InvisibleText,
            Some("render mode".into()),
        );
    }
    if policy == TextEditPolicy::Conservative && candidate.tj_adjusted {
        note_refusal(
            &mut refusal,
            &mut detail,
            TextEditRefusalReason::TjKerningAdjustment,
            Some("TJ numeric adjustment in the same operator".into()),
        );
    }
    if candidate.flags & content::FLAG_MALFORMED_STRING != 0 {
        note_refusal(
            &mut refusal,
            &mut detail,
            TextEditRefusalReason::MalformedString,
            Some("partial character code".into()),
        );
    }
    if let Some(problem) = font.problem {
        let (reason, detail_text) = match problem {
            FontProblem::Type3 => (TextEditRefusalReason::Type3Font, font.base_font.clone()),
            FontProblem::UnsupportedSubtype => (
                TextEditRefusalReason::UnsupportedFont,
                font.base_font.clone(),
            ),
            FontProblem::UnsupportedEncoding => (
                TextEditRefusalReason::UnsupportedEncoding,
                font.encoding_label.clone(),
            ),
            FontProblem::MissingUnicodeMap | FontProblem::MalformedToUnicode => (
                TextEditRefusalReason::MissingUnicodeMapping,
                font.base_font.clone(),
            ),
            FontProblem::MissingWidths => {
                (TextEditRefusalReason::MissingWidths, font.base_font.clone())
            }
        };
        note_refusal(&mut refusal, &mut detail, reason, Some(detail_text));
    }
    if candidate.flags & content::FLAG_WIDTH_MISSING != 0 {
        note_refusal(
            &mut refusal,
            &mut detail,
            TextEditRefusalReason::MissingWidths,
            Some(font.base_font.clone()),
        );
    }
    if any_unmapped {
        note_refusal(
            &mut refusal,
            &mut detail,
            TextEditRefusalReason::MissingUnicodeMapping,
            Some(font.base_font.clone()),
        );
    }
    if (candidate.start..candidate.end).any(|index| unicode_mismatch[index]) {
        note_refusal(
            &mut refusal,
            &mut detail,
            TextEditRefusalReason::UnicodeMismatch,
            Some(font.base_font.clone()),
        );
    }
    if (candidate.start..candidate.end).any(|index| position_mismatch[index]) {
        note_refusal(
            &mut refusal,
            &mut detail,
            TextEditRefusalReason::PositionMismatch,
            Some(font.base_font.clone()),
        );
    }
    if text.trim().is_empty() {
        note_refusal(
            &mut refusal,
            &mut detail,
            TextEditRefusalReason::WhitespaceOnly,
            None,
        );
    }
    if refusal.is_none()
        && (replacement_char_count == 0
            || !replacement
                .iter()
                .any(|character| !character.is_whitespace()))
    {
        note_refusal(
            &mut refusal,
            &mut detail,
            TextEditRefusalReason::NoReplacementCharacters,
            Some(font.base_font.clone()),
        );
    }
    if refusal.is_none() && available_advance <= 0.01 {
        note_refusal(
            &mut refusal,
            &mut detail,
            TextEditRefusalReason::NoRoom,
            Some(format!("{available_advance:.2} pt")),
        );
    }
    if refusal.is_none() && original_advance > available_advance + 0.5 {
        note_refusal(
            &mut refusal,
            &mut detail,
            TextEditRefusalReason::NoRoom,
            Some(format!(
                "run {original_advance:.2} pt, room {available_advance:.2} pt"
            )),
        );
    }

    TextEditRun {
        text,
        rect,
        font: font_info(font),
        font_size,
        operator: candidate.operator,
        tj_adjusted: candidate.tj_adjusted,
        operator_index: candidate.operator_index,
        original_advance,
        available_advance,
        at_line_end,
        deletion_safe: at_line_end,
        replacement_char_count,
        replacement_sample,
        refusal,
        detail,
    }
}

fn font_info(font: &FontData) -> TextEditFontInfo {
    TextEditFontInfo {
        base_font: font.base_font.clone(),
        subtype: match font.subtype {
            FontSubtype::Simple => TextEditFontSubtype::Simple,
            FontSubtype::Type0 => TextEditFontSubtype::Type0,
            FontSubtype::Type3 => TextEditFontSubtype::Type3,
            FontSubtype::Other => TextEditFontSubtype::Other,
        },
        embedded: font.embedded,
        subset: font.subset,
        vertical: font.vertical,
        to_unicode: font.has_to_unicode,
        encoding: font.encoding_label.clone(),
        width_source: match font.width_source() {
            WidthSource::SimpleWidths => TextEditWidthSource::SimpleWidths,
            WidthSource::Type0W => TextEditWidthSource::Type0W,
            WidthSource::Unavailable => TextEditWidthSource::Unavailable,
        },
    }
}

/// The code each character was actually drawn with on this page, per font.
///
/// Only glyphs whose decoded character agreed with PDFium are recorded: the pair (character,
/// code) is then proven by the file's own content, not inferred from an encoding table. Subset
/// fonts use this map as their safe replacement alphabet.
fn observed_codes(
    parsed: &ParsedPage,
    ranges: &[(usize, usize)],
    unicode_mismatch: &[bool],
) -> HashMap<String, HashMap<char, u32>> {
    let mut observed: HashMap<String, HashMap<char, u32>> = HashMap::new();
    for (index, glyph) in parsed.glyphs.iter().enumerate() {
        if unicode_mismatch[index] || ranges[index].0 >= ranges[index].1 {
            continue;
        }
        let Some(text) = &glyph.text else {
            continue;
        };
        let mut characters = text.chars();
        let (Some(character), None) = (characters.next(), characters.next()) else {
            continue;
        };
        observed
            .entry(parsed.glyphs[index].font.base_font.clone())
            .or_default()
            .entry(character)
            .or_insert(parsed.glyphs[index].code);
    }
    observed
}

fn note_refusal(
    refusal: &mut Option<TextEditRefusalReason>,
    detail: &mut Option<String>,
    reason: TextEditRefusalReason,
    detail_text: Option<String>,
) {
    if refusal.is_none() {
        *refusal = Some(reason);
        *detail = detail_text;
    }
}

fn raw_char_text(character: &lyra_reader_core::RawCharBox) -> String {
    char::from_u32(character.unicode)
        .map(|character| character.to_string())
        .unwrap_or_else(|| "\u{fffd}".into())
}

fn union(current: Option<Rect>, rect: Rect) -> Rect {
    let Some(current) = current else {
        return rect;
    };
    let left = current.origin.x.min(rect.origin.x);
    let bottom = current.origin.y.min(rect.origin.y);
    let right = (current.origin.x + current.size.width).max(rect.origin.x + rect.size.width);
    let top = (current.origin.y + current.size.height).max(rect.origin.y + rect.size.height);
    Rect::new(left, bottom, right - left, top - bottom)
}

fn recompute_page_counts(page: &mut TextEditPageAnalysis) {
    page.refusals.clear();
    page.editable_runs = 0;
    page.editable_characters = 0;
    let mut editable = 0usize;
    for run in &page.runs {
        let characters = run.text.chars().count();
        if let Some(reason) = run.refusal {
            let stats = page.refusals.entry(reason).or_default();
            stats.runs += 1;
            stats.characters += characters;
        } else {
            page.editable_runs += 1;
            editable += characters;
        }
    }
    page.editable_characters = editable;
    page.refused_characters = page.text_characters.saturating_sub(editable);
}

fn totals(pages: &[TextEditPageAnalysis]) -> TextEditTotals {
    let mut totals = TextEditTotals {
        pages: pages.len(),
        ..TextEditTotals::default()
    };
    for page in pages {
        totals.pages_with_editable_runs += usize::from(page.editable_runs > 0);
        totals.runs += page.runs.len();
        totals.editable_runs += page.editable_runs;
        totals.refused_runs += page.runs.len() - page.editable_runs;
        totals.glyphs += page.glyphs;
        totals.text_characters += page.text_characters;
        totals.editable_characters += page.editable_characters;
        totals.refused_characters += page.refused_characters;
        totals.tj_boundaries += page.tj_boundaries;
        for (reason, stats) in &page.refusals {
            let total = totals.refusals.entry(*reason).or_default();
            total.runs += stats.runs;
            total.characters += stats.characters;
        }
    }
    totals
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn fixture_separates_editable_runs_from_every_refusal() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let fixture = crate::test_support::fixture("text-edit.pdf");
        let before = std::fs::read(&fixture).unwrap();
        let analysis = analyze_text_edit(&fixture, None).unwrap();
        assert_eq!(
            std::fs::read(&fixture).unwrap(),
            before,
            "analysis must not write"
        );
        assert_eq!(analysis.page_count, 1);
        assert_eq!(analysis.policy, TextEditPolicy::Conservative);
        assert_eq!(analysis.totals.editable_runs, 3, "{:#?}", analysis.totals);
        let editable: Vec<&str> = analysis.pages[0]
            .runs
            .iter()
            .filter(|run| run.is_editable())
            .map(|run| run.text.as_str())
            .collect();
        assert_eq!(editable, ["Hello world", "Plain", " array"]);

        let refused = |reason: TextEditRefusalReason| {
            analysis.pages[0]
                .refusals
                .get(&reason)
                .copied()
                .unwrap_or_default()
        };
        assert_eq!(
            refused(TextEditRefusalReason::TjKerningAdjustment).runs,
            2,
            "Ke and rned share a TJ array with a numeric adjustment"
        );
        assert_eq!(refused(TextEditRefusalReason::FormXObject).runs, 1);
        assert_eq!(refused(TextEditRefusalReason::ClippedText).runs, 1);
        assert_eq!(refused(TextEditRefusalReason::RotatedText).runs, 1);
        assert_eq!(analysis.pages[0].tj_boundaries, 1);

        // The analysis-only policy widens the report to the two TJ fragments, but the other
        // refusals are structural and stay refused.
        let relaxed =
            analyze_text_edit_with_policy(&fixture, None, TextEditPolicy::AllowTjKerning).unwrap();
        assert_eq!(relaxed.totals.editable_runs, 5);
        assert_eq!(
            relaxed.pages[0]
                .refusals
                .get(&TextEditRefusalReason::FormXObject)
                .map(|stats| stats.runs),
            Some(1)
        );
    }

    #[test]
    fn refusal_codes_are_stable_and_unique() {
        let all = [
            TextEditRefusalReason::EncryptedDocument,
            TextEditRefusalReason::SignedDocument,
            TextEditRefusalReason::ContentUnreadable,
            TextEditRefusalReason::MappingMismatch,
            TextEditRefusalReason::FormXObject,
            TextEditRefusalReason::ClippedText,
            TextEditRefusalReason::PatternText,
            TextEditRefusalReason::RotatedText,
            TextEditRefusalReason::VerticalText,
            TextEditRefusalReason::InvisibleText,
            TextEditRefusalReason::TjKerningAdjustment,
            TextEditRefusalReason::UnsupportedContent,
            TextEditRefusalReason::Type3Font,
            TextEditRefusalReason::UnsupportedFont,
            TextEditRefusalReason::UnsupportedEncoding,
            TextEditRefusalReason::MissingWidths,
            TextEditRefusalReason::MissingUnicodeMapping,
            TextEditRefusalReason::MalformedString,
            TextEditRefusalReason::PositionMismatch,
            TextEditRefusalReason::UnicodeMismatch,
            TextEditRefusalReason::WhitespaceOnly,
            TextEditRefusalReason::NoReplacementCharacters,
            TextEditRefusalReason::NoRoom,
        ];
        let mut codes = HashSet::new();
        for reason in all {
            assert!(codes.insert(reason.code()));
            assert!(!reason.sentence().is_empty());
        }
    }
}
