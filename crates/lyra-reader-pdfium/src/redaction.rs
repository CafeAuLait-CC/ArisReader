//! Removing content from a PDF for real: glyphs, vector paths, images and form XObjects.
//!
//! Task mapping: T3.12 (redaction that actually removes content).
//!
//! # What "removal" covers
//!
//! A redaction area is a rectangle on one page. Applying redactions rewrites the page content
//! streams and then **drops every object the rewrite no longer references** (the file is written
//! as a complete new document, not as an incremental update):
//!
//! * **Glyphs** whose PDFium loose box intersects an area are removed from the text-showing
//!   operator itself (`Tj` and `TJ`, including `'` and `"`). A `TJ` spacing adjustment takes the
//!   place of each removed run, so the surviving glyphs on the same line keep their original
//!   positions. Text outside the area is untouched and remains extractable.
//! * **Vector paths** whose painted bounding box intersects an area lose their painting
//!   operator. The whole path is removed even when only part of it intersects (redaction is
//!   allowed to remove more than asked, never less), which is observable: pixels of a long rule
//!   outside the black mark disappear too.
//! * **Images and form XObjects** whose placed bounding box intersects an area are removed as
//!   whole objects.
//! * **Inline images and shadings** cannot be attributed to a rectangle with the parser this
//!   module owns. A page that contains one and is being redacted is **rasterised** instead: the
//!   page is painted at [`RASTER_DPI`] with the areas burned in black, and its content is
//!   replaced by that one image. That removes everything on the page, including its text layer.
//!   The same fallback is used when the text page cannot be mapped one-to-one onto the page's
//!   text-showing operators (text inside a form XObject is the common case), because a redaction
//!   that misses extractable text is worse than one that removes too much.
//! * Every area is finally painted with a black fill rectangle, so the result shows the mark.
//!
//! After the new document is written to its temporary file, [`redact_pdf`] reopens it and
//! proves four things before the atomic rename: the page count is unchanged, no extractable
//! character intersects any area, the characters outside every area are exactly the characters
//! that were outside it before (except on rasterised pages, where the whole text layer is gone by
//! design), and the centre of every area renders black.
//!
//! # Safety contract
//!
//! This is destructive and irreversible, so it shares the writer's contract:
//!
//! 1. [`RedactionMode::Copy`] never touches the source; its destination may not be the source.
//! 2. [`RedactionMode::ReplaceOriginal`] writes and verifies a byte-identical backup of the
//!    original **before** the replacement file is built. If the backup cannot be written, nothing
//!    is replaced. The replacement itself is an atomic rename of a verified temporary file.
//! 3. On any error the original is left as it was and the temporary file is removed.
//! 4. Encrypted documents are refused: a full rewrite of an encrypted document cannot be
//!    verified without re-encrypting it, and a silently decrypted output would be worse than a
//!    refusal.
//!
//! # Coordinates
//!
//! [`RedactionArea::rect`] is in PDF user space (origin at the page's bottom-left corner, the
//! space `/MediaBox` and `/CropBox` use). The FFI layer converts the shell's top-left view-space
//! rectangles to this space with the same [`PageGeometry::view_to_page`] transform the rest of the
//! engine uses, so a redaction saved at any zoom lands on the same page content.

#![allow(unsafe_code)]

use crate::backend::PDFIUM_LOCK;
use crate::page_ops::replace_original_with_edit;
use crate::rewrite::{TextComparison, verify_document_equivalence};
use crate::writeback::{OutputMode, write_rewritten_pdf};
use flate2::Compression;
use flate2::write::ZlibEncoder;
use libloading::Library;
use lopdf::content::{Content, Operation};
use lopdf::{Dictionary, Document, Object, ObjectId, Stream, StringFormat};
use lyra_reader_core::{ErrorCode, LyraReaderError, Rect, Result};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// Resolution of the rasterised fallback. 300 DPI is the usual print resolution; the fallback is
/// about removing content, not about keeping a small file, and 150 DPI made resampled text fuzzy.
pub const RASTER_DPI: f64 = 300.0;

/// How a redaction is allowed to land.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RedactionMode {
    /// Write a new file; the source document is not touched.
    Copy,
    /// Replace the source document after a verified backup.
    ReplaceOriginal,
}

/// The visible result after the sensitive content has actually been removed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RedactionFill {
    Blackout,
    Erase,
}
impl RedactionFill {
    fn component(self) -> u8 {
        if self == Self::Erase { 255 } else { 0 }
    }
}

/// Stage either redaction style for the content editor's reversible working-copy session.
pub fn stage_content_redaction(
    source: &Path,
    destination: &Path,
    areas: &[RedactionArea],
    fill: RedactionFill,
) -> Result<RedactionReport> {
    redact_with_fill(
        source,
        destination,
        areas,
        None,
        RedactionMode::Copy,
        fill,
        true,
    )
}

/// One rectangle on one page, in PDF user space.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RedactionArea {
    pub page: u32,
    pub rect: Rect,
}

impl RedactionArea {
    pub fn new(page: u32, rect: Rect) -> Self {
        Self { page, rect }
    }
}

/// What one redaction area will do, computed without writing anything.
#[derive(Clone, Debug, PartialEq)]
pub struct RedactionPagePreview {
    pub page: u32,
    /// Extractable characters whose box intersects an area on this page.
    pub characters: usize,
    /// A short excerpt of those characters, in page text order (whitespace collapsed).
    pub text_preview: String,
    /// Vector paths, images, shadings and form XObjects whose bounds intersect an area.
    ///
    /// This is the honest "what else is in the way" count. The writer removes a path/image/form
    /// whole when it intersects; it never merely paints over one.
    pub graphics: usize,
}

/// What applying redactions would lose, gathered before the confirmation.
#[derive(Clone, Debug, PartialEq)]
pub struct RedactionPreview {
    pub pages: Vec<RedactionPagePreview>,
    pub removed_characters: usize,
}

/// Per-page outcome of an applied redaction.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RedactionPageReport {
    pub page: u32,
    pub removed_characters: usize,
    /// Vector paths, images and form XObjects removed as whole objects.
    pub removed_graphics: usize,
    /// True when the page's content was replaced by a raster image. Its text layer is gone.
    pub rasterized: bool,
    /// Black fill marks painted (one per area on the page).
    pub fill_marks: usize,
}

/// What [`redact_pdf`] did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RedactionReport {
    pub destination: PathBuf,
    /// The verified backup, only for [`RedactionMode::ReplaceOriginal`].
    pub backup_path: Option<PathBuf>,
    pub pages: Vec<RedactionPageReport>,
    pub removed_characters: usize,
    pub output_bytes: u64,
    /// Stale `.lyra-reader-save-*.tmp` files removed before writing.
    pub cleaned_temporaries: usize,
    /// The reopened output was verified: no text in any area, text outside preserved, marks black.
    pub verified: bool,
    /// True for [`RedactionMode::Copy`]: the source file was not modified.
    pub original_unchanged: bool,
}

/// The name to offer when saving a redacted copy: `<name> (redacted).pdf`.
pub fn suggested_redaction_copy_path(source: &Path) -> PathBuf {
    let stem = source
        .file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .unwrap_or_else(|| "document".to_string());
    source.with_file_name(format!("{stem} (redacted).pdf"))
}

/// Reports what applying `areas` would remove, without writing.
///
/// Text counts come from PDFium's own character boxes with the same loose box the writer uses, so
/// the confirmation and the removal cannot disagree about which characters are covered.
pub fn preview_redactions(source: &Path, areas: &[RedactionArea]) -> Result<RedactionPreview> {
    validate_areas(areas)?;
    let bytes = read_source(source)?;
    reject_encrypted(&bytes)?;
    let api = redact_api()?;
    let document = RedactDocument::load(api, bytes, None)?;
    let page_count = document.page_count();
    let grouped = group_areas(areas, page_count)?;

    let mut pages = Vec::with_capacity(grouped.len());
    let mut removed_characters = 0;
    for (&page, rects) in &grouped {
        let chars = document.page_chars(page)?;
        let mut preview = String::new();
        let mut characters = 0;
        for character in &chars {
            if character.generated || !rects.iter().any(|rect| intersects(rect, &character.rect)) {
                continue;
            }
            characters += 1;
            if let Some(value) = char::from_u32(character.unicode) {
                if value.is_whitespace() {
                    if !preview.ends_with(' ') && !preview.is_empty() {
                        preview.push(' ');
                    }
                } else if preview.chars().count() < 220 {
                    preview.push(value);
                }
            }
        }
        let graphics = document.intersecting_graphics(page, rects)?;
        pages.push(RedactionPagePreview {
            page,
            characters,
            text_preview: preview.trim().to_string(),
            graphics,
        });
        removed_characters += characters;
    }

    Ok(RedactionPreview {
        pages,
        removed_characters,
    })
}

/// Applies `areas` and writes the result according to `mode`.
///
/// See the module documentation for exactly what is removed, what the fallback rasterisation
/// costs, and the backup/atomic-rename contract.
pub fn redact_pdf(
    source: &Path,
    destination: &Path,
    areas: &[RedactionArea],
    password: Option<&str>,
    mode: RedactionMode,
) -> Result<RedactionReport> {
    redact_with_fill(
        source,
        destination,
        areas,
        password,
        mode,
        RedactionFill::Blackout,
        false,
    )
}

fn redact_with_fill(
    source: &Path,
    destination: &Path,
    areas: &[RedactionArea],
    password: Option<&str>,
    mode: RedactionMode,
    fill: RedactionFill,
    working: bool,
) -> Result<RedactionReport> {
    validate_areas(areas)?;
    if password.is_some() {
        return Err(refusal(
            "encrypted documents cannot be redacted",
            "a full rewrite of an encrypted document cannot be verified without re-encrypting it",
        ));
    }
    if mode == RedactionMode::ReplaceOriginal {
        let opened = fs::canonicalize(source).map_err(|error| {
            io_error("could not resolve the document to replace", source, error)
        })?;
        let requested = fs::canonicalize(destination).map_err(|error| {
            io_error(
                "could not resolve the file to replace; nothing was replaced",
                destination,
                error,
            )
        })?;
        if opened != requested {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "the replace action can only rewrite the document it was opened from",
            )
            .with_detail(format!(
                "opened: {} · requested: {}",
                opened.display(),
                requested.display()
            )));
        }
    }
    let source_bytes = read_source(source)?;
    reject_encrypted(&source_bytes)?;
    let api = redact_api()?;
    let original = RedactDocument::load(api, source_bytes.clone(), None)?;
    let page_count = original.page_count();
    let grouped = group_areas(areas, page_count)?;

    // Everything the verifier will look for, computed from the source before it is touched.
    let mut expected = HashMap::new();
    for (&page, rects) in &grouped {
        let chars = original.real_page_chars(page)?;
        expected.insert(page, outside_text(&chars, rects));
    }

    let analysis = analyse(&source_bytes, &grouped, &original, api, fill)?;
    let stats = collect_stats(&analysis);
    let rasterized: HashSet<u32> = stats
        .iter()
        .filter(|(_, report)| report.rasterized)
        .map(|(&page, _)| page)
        .collect();
    if working && !rasterized.is_empty() {
        return Err(refusal(
            "this region needs a raster redaction",
            "the content editor keeps surviving text editable; this page's nested or unsupported content cannot yet be erased without rasterising the page",
        ));
    }
    let expected_outside: HashMap<u32, Vec<(u32, f64, f64)>> = expected;
    let verify_stats = stats.clone();

    let build =
        |file: &mut fs::File| -> Result<()> { write_redacted(&source_bytes, &analysis, file) };
    let verify = |path: &Path| -> Result<()> {
        verify_redacted(
            path,
            &grouped,
            &expected_outside,
            &rasterized,
            &verify_stats,
            page_count,
            fill,
        )?;
        // The redaction verifier owns the text claim (outside the marks unchanged, inside the
        // marks gone). Everything a redaction does not intend to touch still has to survive the
        // prune-and-rewrite: page count, forms, outline, XMP/Info and embedded files.
        verify_document_equivalence(source, path, None, TextComparison::CallerVerified)
    };

    let (destination_path, backup_path, output_bytes, cleaned_temporaries, original_unchanged) =
        match mode {
            RedactionMode::Copy => {
                let written = write_rewritten_pdf(
                    source,
                    destination,
                    if working {
                        OutputMode::WorkingRevision
                    } else {
                        OutputMode::Copy
                    },
                    build,
                    verify,
                )?;
                (
                    written.destination,
                    None,
                    written.output_bytes,
                    written.cleaned_temporaries,
                    true,
                )
            }
            RedactionMode::ReplaceOriginal => {
                // A rewrite cannot land on its own source (`write_rewritten_pdf` refuses it), so
                // the redacted revision is built, verified and then published through the page-edit
                // publisher, which writes the backup of the destination first.
                let staging = staging_path(destination)?;
                let written =
                    match write_rewritten_pdf(source, &staging, OutputMode::Copy, build, verify) {
                        Ok(written) => written,
                        Err(error) => {
                            let _ = fs::remove_file(&staging);
                            return Err(error);
                        }
                    };
                let published = match replace_original_with_edit(&staging, destination, page_count)
                {
                    Ok(published) => published,
                    Err(error) => {
                        let _ = fs::remove_file(&staging);
                        return Err(error);
                    }
                };
                let _ = fs::remove_file(&staging);
                (
                    published.destination,
                    published.backup_path,
                    published.output_bytes,
                    written.cleaned_temporaries + published.cleaned_temporaries,
                    false,
                )
            }
        };

    let mut pages: Vec<RedactionPageReport> = stats.into_values().collect();
    pages.sort_by_key(|report| report.page);
    Ok(RedactionReport {
        destination: destination_path,
        backup_path,
        removed_characters: pages.iter().map(|report| report.removed_characters).sum(),
        pages,
        output_bytes,
        cleaned_temporaries,
        verified: true,
        original_unchanged,
    })
}

/// One page's work, computed once from the source and shared by the writer and the verifier.
#[derive(Clone, Debug, Default)]
struct PageBuildStats {
    fill_marks: usize,
    removed_characters: usize,
    removed_graphics: usize,
    rasterized: bool,
}

fn collect_stats(analysis: &Analysis) -> HashMap<u32, RedactionPageReport> {
    analysis
        .pages
        .iter()
        .map(|(&page, page_analysis)| {
            (
                page,
                RedactionPageReport {
                    page,
                    removed_characters: page_analysis.stats.removed_characters,
                    removed_graphics: page_analysis.stats.removed_graphics,
                    rasterized: page_analysis.stats.rasterized,
                    fill_marks: page_analysis.stats.fill_marks,
                },
            )
        })
        .collect()
}

// ─── Analysis ────────────────────────────────────────────────────────────────────────────────

/// Everything the writer needs to know about one page, computed before any byte is written.
#[derive(Clone, Debug, Default)]
struct PageAnalysis {
    stats: PageBuildStats,
    /// True when the page content must be replaced by a raster image.
    rasterize: bool,
    /// The page size for the raster image and the black marks, in points.
    page_width: f64,
    page_height: f64,
    /// The RGB raster for a rasterised page, already marked.
    raster: Option<RasterImage>,
    /// The rewritten content stream for a non-rasterised page, with black marks appended.
    content: Option<Vec<u8>>,
    /// The raster crop box, for the content stream's image placement.
    crop: Option<Rect>,
}

#[derive(Debug, Default)]
struct Analysis {
    pages: BTreeMap<u32, PageAnalysis>,
}

fn analyse(
    source_bytes: &[u8],
    grouped: &BTreeMap<u32, Vec<Rect>>,
    original: &RedactDocument,
    api: &'static RedactApi,
    fill: RedactionFill,
) -> Result<Analysis> {
    // The lopdf document is the rewrite target; PDFium is only the microscope (char boxes,
    // object bounds, the fallback raster). The two are loaded from the same bytes.
    let document = Document::load_mem(source_bytes).map_err(|error| {
        LyraReaderError::new(
            ErrorCode::CorruptDocument,
            "the document could not be parsed for redaction",
        )
        .with_detail(error.to_string())
    })?;
    if document.is_encrypted() {
        return Err(refusal(
            "encrypted documents cannot be redacted",
            "the document has an /Encrypt dictionary",
        ));
    }
    let page_ids: Vec<ObjectId> = document.get_pages().into_values().collect();
    let mut analysis = Analysis::default();

    for (&page, rects) in grouped {
        let page_id = *page_ids.get(page as usize).ok_or_else(|| {
            LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "a redaction names a page outside the document",
            )
            .with_detail(format!("page index {page} (page count {})", page_ids.len()))
        })?;
        let (width, height) = document_page_size(&document, page_id);
        let chars = original.real_page_chars(page)?;
        let fonts = page_fonts(&document, page_id);
        let content = document.get_page_content(page_id);
        let parsed = parse_content(&content, &fonts, &document, page_id, rects);
        #[cfg(debug_assertions)]
        if std::env::var_os("LYRA_REDACTION_DEBUG").is_some() {
            if let Ok(parsed) = &parsed {
                eprintln!(
                    "redaction mapping page {page}: supported={}, encoded glyphs={}, PDFium characters={}, shows={}",
                    parsed.supported,
                    parsed.total_glyphs,
                    chars.len(),
                    parsed.show_ops.len()
                );
            }
        }
        let page_analysis = match parsed {
            Ok(parsed) if parsed.supported => {
                let mapped = if chars.len() != parsed.total_glyphs {
                    map_expanded_characters(
                        &document,
                        page_id,
                        &content,
                        &chars,
                        parsed.total_glyphs,
                    )
                } else {
                    None
                };
                let glyph_chars = mapped.as_deref().unwrap_or(&chars);
                let glyph_removals = map_glyphs_to_chars(&parsed, glyph_chars, rects)?;
                if let Some(removals) = glyph_removals {
                    let removed_characters = removals.iter().filter(|removed| **removed).count();
                    let bytes = rewrite_content(&parsed, glyph_chars, &removals, rects, fill)?;
                    PageAnalysis {
                        stats: PageBuildStats {
                            fill_marks: rects.len(),
                            removed_characters,
                            removed_graphics: parsed.removed_graphics,
                            rasterized: false,
                        },
                        rasterize: false,
                        page_width: width,
                        page_height: height,
                        raster: None,
                        content: Some(bytes),
                        crop: parsed.crop,
                    }
                } else {
                    // Text did not map one-to-one: fall back to a raster. The page's whole text
                    // layer is lost, which the confirmation has warned about.
                    let raster = render_raster(original, api, page, rects, fill)?;
                    PageAnalysis {
                        stats: PageBuildStats {
                            fill_marks: rects.len(),
                            removed_characters: chars.len(),
                            removed_graphics: parsed.removed_graphics,
                            rasterized: true,
                        },
                        rasterize: true,
                        page_width: width,
                        page_height: height,
                        raster: Some(raster),
                        content: None,
                        crop: parsed.crop,
                    }
                }
            }
            _ => {
                let raster = render_raster(original, api, page, rects, fill)?;
                PageAnalysis {
                    stats: PageBuildStats {
                        fill_marks: rects.len(),
                        removed_characters: chars.len(),
                        removed_graphics: 0,
                        rasterized: true,
                    },
                    rasterize: true,
                    page_width: width,
                    page_height: height,
                    raster: Some(raster),
                    content: None,
                    crop: None,
                }
            }
        };
        analysis.pages.insert(page, page_analysis);
    }
    Ok(analysis)
}

fn group_areas(areas: &[RedactionArea], page_count: u32) -> Result<BTreeMap<u32, Vec<Rect>>> {
    let mut grouped: BTreeMap<u32, Vec<Rect>> = BTreeMap::new();
    for area in areas {
        if area.page >= page_count {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "a redaction names a page outside the document",
            )
            .with_detail(format!("page {} of {}", area.page + 1, page_count)));
        }
        if !area.rect.origin.x.is_finite()
            || !area.rect.origin.y.is_finite()
            || !area.rect.size.width.is_finite()
            || !area.rect.size.height.is_finite()
        {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "a redaction rectangle has a non-finite coordinate",
            ));
        }
        let rect = normalize_rect(area.rect);
        if rect.size.width < 0.5 || rect.size.height < 0.5 {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "a redaction rectangle is smaller than half a point",
            )
            .with_detail(format!("{}×{}", rect.size.width, rect.size.height)));
        }
        grouped.entry(area.page).or_default().push(rect);
    }
    Ok(grouped)
}

fn normalize_rect(rect: Rect) -> Rect {
    let left = rect.origin.x.min(rect.origin.x + rect.size.width);
    let right = rect.origin.x.max(rect.origin.x + rect.size.width);
    let bottom = rect.origin.y.min(rect.origin.y + rect.size.height);
    let top = rect.origin.y.max(rect.origin.y + rect.size.height);
    Rect::new(left, bottom, right - left, top - bottom)
}

/// Axis-aligned rectangle overlap in PDF user space (origin bottom-left, size positive).
fn intersects(left: &Rect, right: &Rect) -> bool {
    left.origin.x < right.origin.x + right.size.width
        && left.origin.x + left.size.width > right.origin.x
        && left.origin.y < right.origin.y + right.size.height
        && left.origin.y + left.size.height > right.origin.y
}

fn validate_areas(areas: &[RedactionArea]) -> Result<()> {
    if areas.is_empty() {
        return Err(LyraReaderError::new(
            ErrorCode::InvalidArgument,
            "there are no redaction areas to apply",
        ));
    }
    if areas.len() > 10_000 {
        return Err(LyraReaderError::new(
            ErrorCode::InvalidArgument,
            "too many redaction areas",
        ));
    }
    Ok(())
}

fn reject_encrypted(bytes: &[u8]) -> Result<()> {
    // The lopdf check covers an /Encrypt dictionary even when the parser cannot decrypt the
    // strings; PDFium's own open may still succeed with an empty user password.
    if let Ok(document) = Document::load_mem(bytes)
        && document.is_encrypted()
    {
        return Err(refusal(
            "encrypted documents cannot be redacted",
            "the document has an /Encrypt dictionary",
        ));
    }
    Ok(())
}

fn refusal(message: &str, detail: &str) -> LyraReaderError {
    LyraReaderError::new(ErrorCode::InvalidArgument, message).with_detail(detail)
}

fn read_source(source: &Path) -> Result<Vec<u8>> {
    let source = fs::canonicalize(source)
        .map_err(|error| io_error("could not resolve the document to redact", source, error))?;
    if !source.is_file() {
        return Err(LyraReaderError::new(
            ErrorCode::NotFound,
            "the document to redact is not a regular file",
        )
        .with_detail(source.display().to_string()));
    }
    fs::read(&source)
        .map_err(|error| io_error("could not read the document to redact", &source, error))
}

fn staging_path(destination: &Path) -> Result<PathBuf> {
    let parent = destination
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let stem = destination
        .file_stem()
        .map(|value| value.to_string_lossy().into_owned())
        .unwrap_or_else(|| "document".to_string());
    let unique = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|value| value.as_nanos())
        .unwrap_or(0);
    Ok(parent.join(format!(
        ".{stem}.lyra-reader-redaction-{}-{unique}.pdf",
        std::process::id()
    )))
}

fn document_page_size(document: &Document, page_id: ObjectId) -> (f64, f64) {
    document
        .get_dictionary(page_id)
        .ok()
        .and_then(|page| page.get(b"MediaBox").ok())
        .map(|object| {
            if let Ok(array) = object.as_array()
                && array.len() >= 4
            {
                let values: Vec<f64> = array.iter().filter_map(number).collect();
                if values.len() >= 4 {
                    return ((values[2] - values[0]).abs(), (values[3] - values[1]).abs());
                }
            }
            (612.0, 792.0)
        })
        .unwrap_or((612.0, 792.0))
}

fn io_error(action: &str, path: &Path, error: std::io::Error) -> LyraReaderError {
    LyraReaderError::new(ErrorCode::Io, action).with_detail(format!("{}: {error}", path.display()))
}

// ─── Text mapping ────────────────────────────────────────────────────────────────────────────

/// One character PDFium reports for a page.
#[derive(Clone, Debug)]
struct PageChar {
    unicode: u32,
    rect: Rect,
    origin_x: f64,
    origin_y: f64,
    font_size: f64,
    /// Effective text-space → page-space matrix (`FPDFText_GetMatrix`).
    matrix: [f64; 6],
    /// A synthetic line break PDFium inserts between text objects.
    generated: bool,
}

impl PageChar {
    /// A zero-area loose box is common (measured at 15-20% of characters on the sample corpus).
    /// Without a repair, a glyph under a redaction rectangle would neither be removed nor caught
    /// by the verifier, and its text would stay extractable. Estimate from the origin and the
    /// effective font size instead, biased deliberately large: a redaction may cover a glyph it
    /// did not have to.
    fn repair_degenerate_box(&mut self) {
        let height = self.font_size
            * (self.matrix[0] * self.matrix[0] + self.matrix[1] * self.matrix[1])
                .sqrt()
                .max(0.01);
        if self.rect.size.height <= 0.01 {
            self.rect.origin.y = self.origin_y - height * 0.2;
            self.rect.size.height = height;
        }
        if self.rect.size.width <= 0.01 {
            self.rect.origin.x = self.origin_x;
            self.rect.size.width = (height * 0.5).max(0.5);
        }
    }

    fn intersects_any(&self, rects: &[Rect]) -> bool {
        rects.iter().any(|rect| intersects(rect, &self.rect))
    }
}

/// The character boxes outside `rects`, in content order. Used by the verifier to prove that
/// redaction did not disturb text it did not cover.
fn outside_text(chars: &[PageChar], rects: &[Rect]) -> Vec<(u32, f64, f64)> {
    chars
        .iter()
        .filter(|character| !character.intersects_any(rects))
        .map(|character| (character.unicode, character.origin_x, character.origin_y))
        .collect()
}

/// Maps every glyph of the page's text-showing operators onto a PDFium character.
///
/// Returns `None` when the counts do not match, which is the signal to rasterise the page: glyphs
/// that cannot be matched cannot be removed with confidence.
/// A single encoded ligature may expand into several PDFium characters. Decode the original
/// font CMaps and prove the entire Unicode sequence and origins before associating them with
/// one source glyph. The verifier still compares every original Unicode character afterwards.
fn map_expanded_characters(
    document: &Document,
    page_id: ObjectId,
    content: &[u8],
    chars: &[PageChar],
    expected: usize,
) -> Option<Vec<PageChar>> {
    let parsed = crate::text_edit::content::parse_page(document, page_id, content);
    let debug = std::env::var_os("LYRA_REDACTION_DEBUG").is_some();
    if debug {
        eprintln!(
            "decoded glyphs={}, expected={expected}, problem={:?}",
            parsed.glyphs.len(),
            parsed.problem
        );
    }
    if parsed.problem.is_some() || parsed.glyphs.len() != expected {
        return None;
    }
    let mut offset = 0;
    let mut mapped = Vec::with_capacity(expected);
    for (index, glyph) in parsed.glyphs.into_iter().enumerate() {
        let text = match glyph.text {
            Some(text) => text,
            None => char::from_u32(chars.get(offset)?.unicode)?.to_string(),
        };
        let unicode: Vec<u32> = text
            .chars()
            .flat_map(|c| match c {
                '\u{fb00}' => "ff".chars().collect::<Vec<_>>(),
                '\u{fb01}' => "fi".chars().collect(),
                '\u{fb02}' => "fl".chars().collect(),
                '\u{fb03}' => "ffi".chars().collect(),
                '\u{fb04}' => "ffl".chars().collect(),
                _ => vec![c],
            })
            .map(u32::from)
            .collect();
        if unicode.is_empty() {
            return None;
        }
        let slice = chars.get(offset..offset + unicode.len())?;
        if slice.iter().map(|c| c.unicode).ne(unicode) {
            if debug {
                eprintln!(
                    "Unicode mismatch at glyph {index}, character {offset}, code {}",
                    glyph.code
                );
            }
            return None;
        }
        if (slice[0].origin_x - glyph.origin[0]).abs() > 0.5
            || (slice[0].origin_y - glyph.origin[1]).abs() > 0.5
        {
            if debug {
                eprintln!(
                    "origin mismatch at glyph {index}: PDFium {},{} vs {},{}",
                    slice[0].origin_x, slice[0].origin_y, glyph.origin[0], glyph.origin[1]
                );
            }
            return None;
        }
        let mut representative = slice[0].clone();
        for character in &slice[1..] {
            representative.rect = representative.rect.union(character.rect);
        }
        mapped.push(representative);
        offset += slice.len();
    }
    (offset == chars.len()).then_some(mapped)
}

fn map_glyphs_to_chars(
    parsed: &ParsedContent,
    chars: &[PageChar],
    rects: &[Rect],
) -> Result<Option<Vec<bool>>> {
    if chars.len() != parsed.total_glyphs {
        return Ok(None);
    }
    Ok(Some(
        chars
            .iter()
            .map(|character| character.intersects_any(rects))
            .collect(),
    ))
}

// ─── Content parsing ─────────────────────────────────────────────────────────────────────────

#[derive(Clone, Debug)]
enum FontKind {
    /// One byte per code.
    Simple,
    /// Two bytes per code (`/Type0`).
    Composite,
}

#[derive(Clone, Debug)]
struct FontInfo {
    kind: FontKind,
}

#[derive(Clone, Debug)]
struct ShowOp {
    /// The number of the operation in the content stream.
    index: usize,
    /// Glyph index of the first code of this operation.
    glyph_start: usize,
    glyph_count: usize,
    /// The font in effect for this operator, resolved from the page resources.
    font: FontInfo,
}

#[derive(Clone, Debug)]
struct ParsedContent {
    operations: Vec<Operation>,
    /// Glyph count over every text-showing operator.
    total_glyphs: usize,
    show_ops: Vec<ShowOp>,
    /// Operation indices of paint operators that must become `n`.
    removed_paints: HashSet<usize>,
    /// Operation indices of `Do` operators that must disappear.
    removed_objects: HashSet<usize>,
    /// How many whole graphics objects those removals account for.
    removed_graphics: usize,
    /// False when the page contains graphics this parser cannot attribute.
    supported: bool,
    /// `/CropBox`, when the page states one.
    crop: Option<Rect>,
}

fn parse_content(
    content: &[u8],
    fonts: &BTreeMap<Vec<u8>, FontInfo>,
    document: &Document,
    page_id: ObjectId,
    rects: &[Rect],
) -> Result<ParsedContent> {
    let parsed = Content::decode(content).map_err(|error| {
        LyraReaderError::new(
            ErrorCode::CorruptDocument,
            "a page content stream could not be parsed",
        )
        .with_detail(error.to_string())
    })?;
    let xobjects = page_resources(document, page_id)
        .and_then(|resources| resources.get(b"XObject").ok())
        .and_then(|value| resolve_dict(document, value));
    let crop = page_crop_box(document, page_id);

    let mut state = GraphicsState::default();
    let mut stack: Vec<GraphicsState> = Vec::new();
    let mut path = PathBox::default();
    let mut show_ops = Vec::new();
    let mut total_glyphs = 0usize;
    let mut removed_paints = HashSet::new();
    let mut removed_objects = HashSet::new();
    let mut removed_graphics = 0usize;
    let mut supported = true;

    for (index, operation) in parsed.operations.iter().enumerate() {
        match operation.operator.as_str() {
            "q" => stack.push(state.clone()),
            "Q" => {
                if let Some(previous) = stack.pop() {
                    state = previous;
                }
            }
            "cm" => {
                if let Some(matrix) = matrix_operands(&operation.operands) {
                    state.ctm = compose(state.ctm, matrix);
                }
            }
            "w" => {
                if let Some(width) = operation.operands.first().and_then(number) {
                    state.line_width = width.max(0.0);
                }
            }
            "Tf" => {
                let Some(name) = operation.operands.first().and_then(name_bytes) else {
                    supported = false;
                    continue;
                };
                match fonts.get(name) {
                    Some(font) => state.font = Some(font.clone()),
                    None => supported = false,
                }
                if let Some(size) = operation.operands.get(1).and_then(number) {
                    state.font_size = size;
                }
            }
            "Tc" => {
                if let Some(value) = operation.operands.first().and_then(number) {
                    state.char_spacing = value;
                }
            }
            "Tw" => {
                if let Some(value) = operation.operands.first().and_then(number) {
                    state.word_spacing = value;
                }
            }
            "Tz" => {
                if let Some(value) = operation.operands.first().and_then(number) {
                    state.horizontal_scale = value / 100.0;
                }
            }
            "Tj" | "TJ" | "'" | "\"" => {
                let Some(font) = state.font.clone() else {
                    supported = false;
                    continue;
                };
                let count = glyph_count(operation, &font);
                if count == 0 {
                    continue;
                }
                show_ops.push(ShowOp {
                    index,
                    glyph_start: total_glyphs,
                    glyph_count: count,
                    font: font.clone(),
                });
                total_glyphs += count;
            }
            "m" | "l" => {
                if let Some((x, y)) = pair(&operation.operands) {
                    path.include(state.ctm, x, y);
                }
            }
            "c" => {
                if let Some(points) = six_numbers(&operation.operands) {
                    for pair_index in 0..3 {
                        path.include(
                            state.ctm,
                            points[pair_index * 2],
                            points[pair_index * 2 + 1],
                        );
                    }
                }
            }
            "v" | "y" => {
                if let Some(values) = four_numbers(&operation.operands) {
                    path.include(state.ctm, values[0], values[1]);
                    path.include(state.ctm, values[2], values[3]);
                }
            }
            "re" => {
                if let Some(values) = four_numbers(&operation.operands) {
                    let (x, y, width, height) = (values[0], values[1], values[2], values[3]);
                    path.include(state.ctm, x, y);
                    path.include(state.ctm, x + width, y);
                    path.include(state.ctm, x, y + height);
                    path.include(state.ctm, x + width, y + height);
                }
            }
            "h" => path.close(),
            "S" | "s" | "f" | "F" | "f*" | "B" | "B*" | "b" | "b*" => {
                if path.intersects(rects, state.line_width) {
                    removed_paints.insert(index);
                    removed_graphics += 1;
                }
                path = PathBox::default();
            }
            "n" => path = PathBox::default(),
            "W" | "W*" => {}
            "Do" => {
                let Some(name) = operation.operands.first().and_then(name_bytes) else {
                    supported = false;
                    continue;
                };
                let Some(xobjects) = &xobjects else {
                    supported = false;
                    continue;
                };
                let Some(target) = xobjects
                    .get(name)
                    .ok()
                    .and_then(|value| value.as_reference().ok())
                else {
                    supported = false;
                    continue;
                };
                let Some(stream) = document
                    .get_object(target)
                    .ok()
                    .and_then(|object| object.as_stream().ok())
                else {
                    supported = false;
                    continue;
                };
                let subtype = stream
                    .dict
                    .get(b"Subtype")
                    .ok()
                    .and_then(|value| value.as_name().ok());
                let bounds = match subtype {
                    Some(b"Image") => Some(transform_unit_square(state.ctm)),
                    Some(b"Form") => form_bounds(document, stream, state.ctm),
                    _ => None,
                };
                match bounds {
                    Some(bounds) if rects.iter().any(|rect| intersects(rect, &bounds)) => {
                        removed_objects.insert(index);
                        removed_graphics += 1;
                    }
                    Some(_) => {}
                    None => supported = false,
                }
            }
            // Inline images and shadings cannot be attributed with this parser. The page is
            // rasterised instead, which removes them without guessing.
            "BI" | "ID" | "EI" | "sh" => supported = false,
            _ => {}
        }
    }

    Ok(ParsedContent {
        operations: parsed.operations,
        total_glyphs,
        show_ops,
        removed_paints,
        removed_objects,
        removed_graphics,
        supported,
        crop,
    })
}

const IDENTITY_MATRIX: [f64; 6] = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0];

#[derive(Clone, Debug)]
struct GraphicsState {
    ctm: [f64; 6],
    font: Option<FontInfo>,
    font_size: f64,
    char_spacing: f64,
    word_spacing: f64,
    horizontal_scale: f64,
    line_width: f64,
}

impl Default for GraphicsState {
    fn default() -> Self {
        Self {
            ctm: IDENTITY_MATRIX,
            font: None,
            font_size: 0.0,
            char_spacing: 0.0,
            word_spacing: 0.0,
            horizontal_scale: 1.0,
            line_width: 1.0,
        }
    }
}

#[derive(Clone, Debug, Default)]
struct PathBox {
    points: Vec<(f64, f64)>,
}

impl PathBox {
    fn include(&mut self, ctm: [f64; 6], x: f64, y: f64) {
        self.points.push((
            ctm[0] * x + ctm[2] * y + ctm[4],
            ctm[1] * x + ctm[3] * y + ctm[5],
        ));
    }

    fn close(&mut self) {}

    fn bounds(&self) -> Option<Rect> {
        let (&(first_x, first_y), rest) = self.points.split_first()?;
        let (mut min_x, mut max_x, mut min_y, mut max_y) = (first_x, first_x, first_y, first_y);
        for &(x, y) in rest {
            min_x = min_x.min(x);
            max_x = max_x.max(x);
            min_y = min_y.min(y);
            max_y = max_y.max(y);
        }
        Some(Rect::new(min_x, min_y, max_x - min_x, max_y - min_y))
    }

    fn intersects(&self, rects: &[Rect], line_width: f64) -> bool {
        let Some(bounds) = self.bounds() else {
            return false;
        };
        let padding = line_width.max(0.0) / 2.0;
        let padded = Rect::new(
            bounds.origin.x - padding,
            bounds.origin.y - padding,
            bounds.size.width + padding * 2.0,
            bounds.size.height + padding * 2.0,
        );
        rects.iter().any(|rect| intersects(rect, &padded))
    }
}

fn compose(outer: [f64; 6], inner: [f64; 6]) -> [f64; 6] {
    [
        outer[0] * inner[0] + outer[2] * inner[1],
        outer[1] * inner[0] + outer[3] * inner[1],
        outer[0] * inner[2] + outer[2] * inner[3],
        outer[1] * inner[2] + outer[3] * inner[3],
        outer[0] * inner[4] + outer[2] * inner[5] + outer[4],
        outer[1] * inner[4] + outer[3] * inner[5] + outer[5],
    ]
}

fn glyph_count(operation: &Operation, font: &FontInfo) -> usize {
    match operation.operator.as_str() {
        "Tj" | "'" => operation
            .operands
            .first()
            .and_then(string_bytes)
            .map(|bytes| string_glyph_count(bytes, font))
            .unwrap_or(0),
        "\"" => operation
            .operands
            .get(2)
            .and_then(string_bytes)
            .map(|bytes| string_glyph_count(bytes, font))
            .unwrap_or(0),
        "TJ" => operation
            .operands
            .first()
            .and_then(|value| value.as_array().ok())
            .map(|array| {
                array
                    .iter()
                    .filter_map(|item| item.as_str().ok())
                    .map(|bytes| string_glyph_count(bytes, font))
                    .sum()
            })
            .unwrap_or(0),
        _ => 0,
    }
}

fn string_glyph_count(bytes: &[u8], font: &FontInfo) -> usize {
    match font.kind {
        FontKind::Simple => bytes.len(),
        FontKind::Composite => bytes.len() / 2,
    }
}

fn page_fonts(document: &Document, page_id: ObjectId) -> BTreeMap<Vec<u8>, FontInfo> {
    let mut fonts = BTreeMap::new();
    for resources in page_resource_dicts(document, page_id) {
        let Ok(font_dict) = resources.get(b"Font") else {
            continue;
        };
        let Some(font_dict) = resolve_dict(document, font_dict) else {
            continue;
        };
        for (name, value) in font_dict.iter() {
            let Some(dictionary) = resolve_dict(document, value) else {
                continue;
            };
            let composite = dictionary
                .get(b"Subtype")
                .ok()
                .and_then(|value| value.as_name().ok())
                .map(|name| name == b"Type0")
                .unwrap_or(false);
            fonts.entry(name.clone()).or_insert(FontInfo {
                kind: if composite {
                    FontKind::Composite
                } else {
                    FontKind::Simple
                },
            });
        }
    }
    fonts
}

/// Every `/Resources` dictionary a page inherits, nearest first.
fn page_resource_dicts(document: &Document, page_id: ObjectId) -> Vec<&Dictionary> {
    let mut dictionaries = Vec::new();
    let Ok(page) = document.get_dictionary(page_id) else {
        return dictionaries;
    };
    if let Ok(value) = page.get(b"Resources")
        && let Some(dictionary) = resolve_dict(document, value)
    {
        dictionaries.push(dictionary);
    }
    let Ok((_, resource_ids)) = document.get_page_resources(page_id) else {
        return dictionaries;
    };
    for id in resource_ids {
        if let Ok(resources) = document.get_dictionary(id)
            && !dictionaries
                .iter()
                .any(|existing| std::ptr::eq(*existing, resources))
        {
            dictionaries.push(resources);
        }
    }
    dictionaries
}

fn page_resources(document: &Document, page_id: ObjectId) -> Option<&Dictionary> {
    page_resource_dicts(document, page_id).into_iter().next()
}

fn resolve_dict<'a>(document: &'a Document, value: &'a Object) -> Option<&'a Dictionary> {
    match value {
        Object::Dictionary(dictionary) => Some(dictionary),
        Object::Reference(id) => document.get_dictionary(*id).ok(),
        _ => None,
    }
}

fn page_crop_box(document: &Document, page_id: ObjectId) -> Option<Rect> {
    let page = document.get_dictionary(page_id).ok()?;
    let object = page.get(b"CropBox").ok()?;
    let array = object.as_array().ok()?;
    if array.len() < 4 {
        return None;
    }
    let values: Vec<f64> = array.iter().filter_map(number).collect();
    if values.len() < 4 {
        return None;
    }
    let left = values[0].min(values[2]);
    let right = values[0].max(values[2]);
    let bottom = values[1].min(values[3]);
    let top = values[1].max(values[3]);
    Some(Rect::new(left, bottom, right - left, top - bottom))
}

fn form_bounds(document: &Document, stream: &Stream, ctm: [f64; 6]) -> Option<Rect> {
    let _ = document;
    let bbox = stream.dict.get(b"BBox").ok()?.as_array().ok()?;
    if bbox.len() < 4 {
        return None;
    }
    let values: Vec<f64> = bbox.iter().filter_map(number).collect();
    if values.len() < 4 {
        return None;
    }
    let matrix = stream
        .dict
        .get(b"Matrix")
        .ok()
        .and_then(|value| value.as_array().ok())
        .and_then(|array| {
            let values: Vec<f64> = array.iter().filter_map(number).collect();
            if values.len() == 6 {
                Some([
                    values[0], values[1], values[2], values[3], values[4], values[5],
                ])
            } else {
                None
            }
        })
        .unwrap_or(IDENTITY_MATRIX);
    let combined = compose(ctm, matrix);
    let corners = [
        (values[0], values[1]),
        (values[2], values[1]),
        (values[0], values[3]),
        (values[2], values[3]),
    ];
    Some(transformed_bounds(&corners, combined))
}

fn transform_unit_square(ctm: [f64; 6]) -> Rect {
    let corners = [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)];
    transformed_bounds(&corners, ctm)
}

fn transformed_bounds(corners: &[(f64, f64)], matrix: [f64; 6]) -> Rect {
    let transformed: Vec<(f64, f64)> = corners
        .iter()
        .map(|&(x, y)| {
            (
                matrix[0] * x + matrix[2] * y + matrix[4],
                matrix[1] * x + matrix[3] * y + matrix[5],
            )
        })
        .collect();
    let (mut min_x, mut max_x, mut min_y, mut max_y) = (
        transformed[0].0,
        transformed[0].0,
        transformed[0].1,
        transformed[0].1,
    );
    for &(x, y) in transformed.iter().skip(1) {
        min_x = min_x.min(x);
        max_x = max_x.max(x);
        min_y = min_y.min(y);
        max_y = max_y.max(y);
    }
    Rect::new(min_x, min_y, max_x - min_x, max_y - min_y)
}

// ─── Content rewriting ───────────────────────────────────────────────────────────────────────

fn rewrite_content(
    parsed: &ParsedContent,
    chars: &[PageChar],
    removals: &[bool],
    rects: &[Rect],
    fill: RedactionFill,
) -> Result<Vec<u8>> {
    let shows: HashMap<usize, &ShowOp> = parsed
        .show_ops
        .iter()
        .map(|show| (show.index, show))
        .collect();
    let mut output: Vec<Operation> = Vec::with_capacity(parsed.operations.len() + rects.len() * 6);

    for (index, operation) in parsed.operations.iter().enumerate() {
        if parsed.removed_paints.contains(&index) {
            output.push(Operation::new("n", vec![]));
            continue;
        }
        if parsed.removed_objects.contains(&index) {
            continue;
        }
        if let Some(show) = shows.get(&index) {
            let start = show.glyph_start;
            let end = (start + show.glyph_count).min(removals.len());
            let slice = &removals[start..end];
            if slice.iter().any(|removed| *removed) {
                rewrite_show(operation, &show.font, chars, start, slice, &mut output)?;
                continue;
            }
        }
        output.push(operation.clone());
    }

    // The black mark: a new graphics state with an identity CTM, so a page whose stream leaves a
    // transformed CTM behind still gets the rectangle where the reader drew it.
    let mut bytes = Content { operations: output }.encode().map_err(|error| {
        LyraReaderError::new(
            ErrorCode::Internal,
            "could not encode the redacted content stream",
        )
        .with_detail(error.to_string())
    })?;
    if !bytes.ends_with(b"\n") {
        bytes.push(b'\n');
    }
    bytes.extend_from_slice(if fill == RedactionFill::Erase {
        b"q\n1 0 0 1 0 0 cm\n1 1 1 rg\n1 1 1 RG\n"
    } else {
        b"q\n1 0 0 1 0 0 cm\n0 0 0 rg\n0 0 0 RG\n"
    });
    for rect in rects {
        bytes.extend_from_slice(
            format!(
                "{:.4} {:.4} {:.4} {:.4} re\n",
                rect.origin.x, rect.origin.y, rect.size.width, rect.size.height
            )
            .as_bytes(),
        );
    }
    bytes.extend_from_slice(b"f\nQ\n");
    Ok(bytes)
}

fn rewrite_show(
    operation: &Operation,
    font: &FontInfo,
    chars: &[PageChar],
    glyph_start: usize,
    removals: &[bool],
    output: &mut Vec<Operation>,
) -> Result<()> {
    match operation.operator.as_str() {
        "Tj" => {
            let string = operation
                .operands
                .first()
                .and_then(string_bytes)
                .ok_or_else(|| malformed("a Tj operator had no string"))?;
            let parts = rewritten_parts(string, font, chars, glyph_start, removals);
            emit_separate_text_parts(parts, output);
        }
        "'" => {
            let string = operation
                .operands
                .first()
                .and_then(string_bytes)
                .ok_or_else(|| malformed("a ' operator had no string"))?;
            let parts = rewritten_parts(string, font, chars, glyph_start, removals);
            output.push(Operation::new("T*", vec![]));
            emit_separate_text_parts(parts, output);
        }
        "\"" => {
            let Some(string) = operation.operands.get(2).and_then(string_bytes) else {
                return Err(malformed("a \" operator had no string"));
            };
            let word_spacing = operation
                .operands
                .first()
                .cloned()
                .unwrap_or(Object::Integer(0));
            let char_spacing = operation
                .operands
                .get(1)
                .cloned()
                .unwrap_or(Object::Integer(0));
            let parts = rewritten_parts(string, font, chars, glyph_start, removals);
            output.push(Operation::new("Tw", vec![word_spacing]));
            output.push(Operation::new("Tc", vec![char_spacing]));
            output.push(Operation::new("T*", vec![]));
            emit_separate_text_parts(parts, output);
        }
        "TJ" => {
            let array = operation
                .operands
                .first()
                .and_then(|value| value.as_array().ok())
                .ok_or_else(|| malformed("a TJ operator had no array"))?;
            let mut parts: Vec<Object> = Vec::new();
            let mut glyph = glyph_start;
            for item in array {
                match item {
                    Object::String(bytes, format) => {
                        let count = string_glyph_count(bytes, font);
                        let end = (glyph + count).min(removals.len());
                        let slice = &removals[glyph..end];
                        parts.extend(rewritten_string_parts(
                            bytes, *format, font, chars, glyph, slice,
                        ));
                        glyph = end;
                    }
                    other => parts.push(other.clone()),
                }
            }
            emit_separate_text_parts(parts, output);
        }
        _ => {}
    }
    Ok(())
}

// A separate text-showing operator per surviving segment lets PDFium rebuild disjoint
// object bounds after an erase. Numeric TJ advances still preserve every surviving origin.
fn emit_separate_text_parts(parts: Vec<Object>, output: &mut Vec<Operation>) {
    let mut pending = Vec::new();
    for part in parts {
        let is_text = matches!(&part, Object::String(..));
        pending.push(part);
        if is_text {
            output.push(Operation::new(
                "TJ",
                vec![Object::Array(std::mem::take(&mut pending))],
            ));
        }
    }
    if !pending.is_empty() {
        output.push(Operation::new("TJ", vec![Object::Array(pending)]));
    }
}

/// Rewrites one string into TJ array elements, inserting a spacing adjustment for every removed
/// run. The kept bytes are copied verbatim, so the font subset and encoding are unchanged.
fn rewritten_parts(
    bytes: &[u8],
    font: &FontInfo,
    chars: &[PageChar],
    glyph_start: usize,
    removals: &[bool],
) -> Vec<Object> {
    rewritten_string_parts(
        bytes,
        StringFormat::Literal,
        font,
        chars,
        glyph_start,
        removals,
    )
}

fn rewritten_string_parts(
    bytes: &[u8],
    format: StringFormat,
    font: &FontInfo,
    chars: &[PageChar],
    glyph_start: usize,
    removals: &[bool],
) -> Vec<Object> {
    let width = match font.kind {
        FontKind::Simple => 1,
        FontKind::Composite => 2,
    };
    let count = bytes.len() / width;
    let mut parts: Vec<Object> = Vec::new();
    let mut kept: Vec<u8> = Vec::new();
    let mut removed_run: Option<usize> = None;

    for offset in 0..count {
        let removed = removals.get(offset).copied().unwrap_or(false);
        if removed {
            removed_run.get_or_insert(offset);
            continue;
        }
        if let Some(run_start) = removed_run.take() {
            // The next kept glyph is this one: the origin difference between it and the first
            // removed glyph is exactly the advance the run must skip.
            let adjustment = adjustment_for_run(
                chars,
                glyph_start + run_start,
                Some(glyph_start + offset),
                glyph_start + offset,
            );
            if !kept.is_empty() {
                parts.push(Object::String(std::mem::take(&mut kept), format));
            }
            if adjustment != 0 {
                parts.push(Object::Integer(adjustment));
            }
        }
        kept.extend_from_slice(&bytes[offset * width..(offset + 1) * width]);
    }

    if let Some(run_start) = removed_run {
        if !kept.is_empty() {
            parts.push(Object::String(std::mem::take(&mut kept), format));
        }
        let adjustment =
            adjustment_for_run(chars, glyph_start + run_start, None, glyph_start + count);
        if adjustment != 0 {
            parts.push(Object::Integer(adjustment));
        }
    } else if !kept.is_empty() {
        parts.push(Object::String(kept, format));
    }
    if parts.is_empty() {
        parts.push(Object::Integer(0));
    }
    parts
}

/// The TJ number (thousandths of text space) that skips the removed glyphs starting at
/// `first_removed`.
///
/// When the next kept glyph is known, the page-space origin difference is exact: it is the sum of
/// the removed glyphs' advances *including* character and word spacing and kerning. When the run
/// is at the end of a string, the width of each removed glyph's loose box is used instead (an
/// estimate only for the text matrix position after the operator; the visual glyphs before it are
/// unaffected either way).
fn adjustment_for_run(
    chars: &[PageChar],
    first_removed: usize,
    next_kept: Option<usize>,
    end: usize,
) -> i64 {
    let Some(first) = chars.get(first_removed) else {
        return 0;
    };
    let [a, b, _, _, _, _] = first.matrix;
    let scale = a * a + b * b;
    if !scale.is_finite() || scale <= 1e-12 || first.font_size.abs() <= 1e-9 {
        return 0;
    }
    if let Some(next) = next_kept.and_then(|index| chars.get(index)) {
        let dx = next.origin_x - first.origin_x;
        let dy = next.origin_y - first.origin_y;
        let advance_em = (dx * a + dy * b) / (first.font_size * scale);
        return -((advance_em * 1000.0).round() as i64);
    }
    let mut em = 0.0;
    for character in chars.iter().take(end.min(chars.len())).skip(first_removed) {
        let projected = (character.rect.size.width * a.abs()
            + character.rect.size.height * b.abs())
            / scale.sqrt();
        em += projected / (first.font_size * scale.sqrt()).max(1e-9);
    }
    -((em * 1000.0).round() as i64)
}

fn is_layout_whitespace(unicode: u32) -> bool {
    char::from_u32(unicode).is_some_and(char::is_whitespace)
}

fn malformed(detail: &str) -> LyraReaderError {
    LyraReaderError::new(
        ErrorCode::CorruptDocument,
        "a page content stream is malformed",
    )
    .with_detail(detail)
}

// ─── Writing ──────────────────────────────────────────────────────────────────────────────────

fn write_redacted(source_bytes: &[u8], analysis: &Analysis, file: &mut fs::File) -> Result<()> {
    let mut document = Document::load_mem(source_bytes).map_err(|error| {
        LyraReaderError::new(
            ErrorCode::CorruptDocument,
            "the document could not be parsed for redaction",
        )
        .with_detail(error.to_string())
    })?;
    let page_ids: Vec<ObjectId> = document.get_pages().into_values().collect();

    for (&page, page_analysis) in &analysis.pages {
        let page_id = *page_ids.get(page as usize).ok_or_else(|| {
            LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "a redaction names a page outside the document",
            )
        })?;
        if page_analysis.rasterize {
            replace_page_with_raster(&mut document, page_id, page_analysis)?;
        } else if let Some(content) = &page_analysis.content {
            let stream = Stream::new(Dictionary::new(), content.clone());
            let id = document.add_object(Object::Stream(stream));
            let page_dictionary = document
                .get_object_mut(page_id)
                .and_then(|object| object.as_dict_mut())
                .map_err(|error| {
                    LyraReaderError::new(ErrorCode::CorruptDocument, "a page has no dictionary")
                        .with_detail(error.to_string())
                })?;
            page_dictionary.set("Contents", Object::Reference(id));
        }
    }

    // A redaction removes content, not just references: unreferenced objects (the old page
    // content streams, the resources of a rasterised page) are dropped from the output.
    document.prune_objects();
    document.renumber_objects();

    let mut buffer = Vec::new();
    document.save_to(&mut buffer).map_err(|error| {
        LyraReaderError::new(ErrorCode::Io, "the redacted document could not be written")
            .with_detail(error.to_string())
    })?;
    file.write_all(&buffer).map_err(|error| {
        io_error(
            "could not write the redacted document",
            Path::new("<redacted output>"),
            error,
        )
    })
}

fn replace_page_with_raster(
    document: &mut Document,
    page_id: ObjectId,
    page_analysis: &PageAnalysis,
) -> Result<()> {
    let Some(raster) = &page_analysis.raster else {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "a rasterised page had no raster",
        ));
    };
    let mut compressed = Vec::new();
    {
        let mut encoder = ZlibEncoder::new(&mut compressed, Compression::best());
        encoder.write_all(&raster.rgb).map_err(|error| {
            LyraReaderError::new(ErrorCode::Internal, "could not compress the page raster")
                .with_detail(error.to_string())
        })?;
        encoder.finish().map_err(|error| {
            LyraReaderError::new(ErrorCode::Internal, "could not compress the page raster")
                .with_detail(error.to_string())
        })?;
    }

    let mut dictionary = Dictionary::new();
    dictionary.set("Type", Object::Name(b"XObject".to_vec()));
    dictionary.set("Subtype", Object::Name(b"Image".to_vec()));
    dictionary.set("Width", Object::Integer(raster.width as i64));
    dictionary.set("Height", Object::Integer(raster.height as i64));
    dictionary.set("ColorSpace", Object::Name(b"DeviceRGB".to_vec()));
    dictionary.set("BitsPerComponent", Object::Integer(8));
    dictionary.set("Filter", Object::Name(b"FlateDecode".to_vec()));
    let image_id = document.add_object(Object::Stream(Stream::new(dictionary, compressed)));

    let (width, height) = if let Some(crop) = page_analysis.crop {
        (crop.size.width.max(1.0), crop.size.height.max(1.0))
    } else {
        (
            page_analysis.page_width.max(1.0),
            page_analysis.page_height.max(1.0),
        )
    };
    let content =
        format!("q\n{width:.4} 0 0 {height:.4} 0 0 cm\n/LyraReaderRedactionImage Do\nQ\n");
    let content_id = document.add_object(Object::Stream(Stream::new(
        Dictionary::new(),
        content.into_bytes(),
    )));

    let mut xobjects = Dictionary::new();
    xobjects.set("LyraReaderRedactionImage", Object::Reference(image_id));
    let mut resources = Dictionary::new();
    resources.set("XObject", Object::Dictionary(xobjects));

    let page_dictionary = document
        .get_object_mut(page_id)
        .and_then(|object| object.as_dict_mut())
        .map_err(|error| {
            LyraReaderError::new(ErrorCode::CorruptDocument, "a page has no dictionary")
                .with_detail(error.to_string())
        })?;
    page_dictionary.set("Contents", Object::Reference(content_id));
    page_dictionary.set("Resources", Object::Dictionary(resources));
    // The raster is in the page's displayed orientation. A rotation left on the page would turn
    // it a second time; the rasteriser refuses rotated pages, so this is a defensive reset.
    page_dictionary.set("Rotate", Object::Integer(0));
    Ok(())
}

// ─── Verification ────────────────────────────────────────────────────────────────────────────

fn verify_redacted(
    path: &Path,
    grouped: &BTreeMap<u32, Vec<Rect>>,
    expected_outside: &HashMap<u32, Vec<(u32, f64, f64)>>,
    rasterized: &HashSet<u32>,
    stats: &HashMap<u32, RedactionPageReport>,
    page_count: u32,
    fill: RedactionFill,
) -> Result<()> {
    let api = redact_api()?;
    let bytes = fs::read(path)
        .map_err(|error| io_error("could not reopen the redacted document", path, error))?;
    let document = RedactDocument::load(api, bytes, None)?;
    if document.page_count() != page_count {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the redacted document changed the page count",
        )
        .with_detail(format!(
            "expected {page_count}, found {}",
            document.page_count()
        )));
    }

    for (&page, rects) in grouped {
        let chars = document.real_page_chars(page)?;
        if rasterized.contains(&page) {
            if !chars.is_empty() {
                return Err(LyraReaderError::new(
                    ErrorCode::Internal,
                    "a rasterised page still has extractable text",
                )
                .with_detail(format!(
                    "page {}: {} character(s)",
                    page + 1,
                    chars.len()
                )));
            }
        } else {
            for character in &chars {
                if character.intersects_any(rects) {
                    return Err(LyraReaderError::new(
                        ErrorCode::Internal,
                        "redacted text is still extractable from the saved file",
                    )
                    .with_detail(format!(
                        "page {}: U+{:04X}",
                        page + 1,
                        character.unicode
                    )));
                }
            }
            // Whitespace is compared loosely: removing glyphs leaves a visible gap, and PDFium
            // (like every extractor) may synthesize a space there. That is not lost content;
            // flipping a letter, losing a word or moving surviving text would be. The origin of
            // every surviving glyph is compared too, so a wrong TJ adjustment cannot pass.
            let outside: Vec<(u32, f64, f64)> = chars
                .iter()
                .filter(|character| !character.intersects_any(rects))
                .map(|character| (character.unicode, character.origin_x, character.origin_y))
                .filter(|(unicode, _, _)| !is_layout_whitespace(*unicode))
                .collect();
            let expected: Vec<(u32, f64, f64)> = expected_outside
                .get(&page)
                .cloned()
                .unwrap_or_default()
                .into_iter()
                .filter(|(unicode, _, _)| !is_layout_whitespace(*unicode))
                .collect();
            let mismatch = outside
                .iter()
                .zip(expected.iter())
                .position(|(left, right)| {
                    left.0 != right.0
                        || (left.1 - right.1).abs() > 1.0
                        || (left.2 - right.2).abs() > 1.0
                })
                .unwrap_or_else(|| {
                    if outside.len() == expected.len() {
                        usize::MAX
                    } else {
                        outside.len().min(expected.len())
                    }
                });
            if mismatch != usize::MAX {
                let (expected_context, actual_context) =
                    match (expected.get(mismatch), outside.get(mismatch)) {
                        (Some(expected), Some(actual)) => (
                            format!(
                                "U+{:04X} at ({:.2},{:.2})",
                                expected.0, expected.1, expected.2
                            ),
                            format!("U+{:04X} at ({:.2},{:.2})", actual.0, actual.1, actual.2),
                        ),
                        _ => (
                            "fewer characters".to_string(),
                            "fewer characters".to_string(),
                        ),
                    };
                return Err(LyraReaderError::new(
                    ErrorCode::Internal,
                    "text outside the redaction areas changed",
                )
                .with_detail(format!(
                    "page {}: expected {} character(s), found {}; first difference at {}: expected {}, found {}",
                    page + 1,
                    expected.len(),
                    outside.len(),
                    mismatch,
                    expected_context,
                    actual_context
                )));
            }
        }

        // The mark must be visible. Sampling the centre of each area keeps this independent of
        // how the page was rewritten: text pages got a fill operator, raster pages a burned-in
        // rectangle.
        let raster = document.render_page(page, 1.0)?;
        for rect in rects {
            let x = rect.origin.x + rect.size.width / 2.0;
            let y = rect.origin.y + rect.size.height / 2.0;
            let Some(pixel) = raster.pixel_at(x, y) else {
                return Err(LyraReaderError::new(
                    ErrorCode::Internal,
                    "a redaction mark could not be sampled on the saved page",
                ));
            };
            if [pixel.0, pixel.1, pixel.2]
                .iter()
                .any(|c| c.abs_diff(fill.component()) > 48)
            {
                return Err(LyraReaderError::new(
                    ErrorCode::Internal,
                    "a redaction mark has the wrong fill on the saved page",
                )
                .with_detail(format!(
                    "page {}: sampled ({}, {}, {})",
                    page + 1,
                    pixel.0,
                    pixel.1,
                    pixel.2
                )));
            }
        }
        if let Some(report) = stats.get(&page)
            && report.fill_marks != rects.len()
        {
            return Err(LyraReaderError::new(
                ErrorCode::Internal,
                "the redaction report does not match the requested areas",
            ));
        }
    }
    Ok(())
}

// ─── PDFium ──────────────────────────────────────────────────────────────────────────────────

type FpdfDocument = *mut std::ffi::c_void;
type FpdfPage = *mut std::ffi::c_void;
type FpdfTextPage = *mut std::ffi::c_void;
type FpdfBitmap = *mut std::ffi::c_void;
type FpdfPageObject = *mut std::ffi::c_void;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
struct FsRectF {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
struct FsMatrix {
    a: f32,
    b: f32,
    c: f32,
    d: f32,
    e: f32,
    f: f32,
}

struct RedactApi {
    _library: Library,
    load_mem_document: unsafe extern "C" fn(
        *const std::ffi::c_void,
        std::ffi::c_int,
        *const std::ffi::c_char,
    ) -> FpdfDocument,
    close_document: unsafe extern "C" fn(FpdfDocument),
    get_page_count: unsafe extern "C" fn(FpdfDocument) -> std::ffi::c_int,
    load_page: unsafe extern "C" fn(FpdfDocument, std::ffi::c_int) -> FpdfPage,
    close_page: unsafe extern "C" fn(FpdfPage),
    get_page_width: unsafe extern "C" fn(FpdfPage) -> f32,
    get_page_height: unsafe extern "C" fn(FpdfPage) -> f32,
    get_rotation: unsafe extern "C" fn(FpdfPage) -> std::ffi::c_int,
    get_crop_box:
        unsafe extern "C" fn(FpdfPage, *mut f32, *mut f32, *mut f32, *mut f32) -> std::ffi::c_int,
    count_objects: unsafe extern "C" fn(FpdfPage) -> std::ffi::c_int,
    get_object: unsafe extern "C" fn(FpdfPage, std::ffi::c_int) -> FpdfPageObject,
    get_object_type: unsafe extern "C" fn(FpdfPageObject) -> std::ffi::c_int,
    get_object_bounds: unsafe extern "C" fn(
        FpdfPageObject,
        *mut f32,
        *mut f32,
        *mut f32,
        *mut f32,
    ) -> std::ffi::c_int,
    create_bitmap:
        unsafe extern "C" fn(std::ffi::c_int, std::ffi::c_int, std::ffi::c_int) -> FpdfBitmap,
    bitmap_get_buffer: unsafe extern "C" fn(FpdfBitmap) -> *mut std::ffi::c_void,
    bitmap_get_stride: unsafe extern "C" fn(FpdfBitmap) -> std::ffi::c_int,
    bitmap_fill_rect: unsafe extern "C" fn(
        FpdfBitmap,
        std::ffi::c_int,
        std::ffi::c_int,
        std::ffi::c_int,
        std::ffi::c_int,
        std::ffi::c_uint,
    ),
    render_page_bitmap: unsafe extern "C" fn(
        FpdfBitmap,
        FpdfPage,
        std::ffi::c_int,
        std::ffi::c_int,
        std::ffi::c_int,
        std::ffi::c_int,
        std::ffi::c_int,
        std::ffi::c_int,
    ),
    destroy_bitmap: unsafe extern "C" fn(FpdfBitmap),
    load_text_page: unsafe extern "C" fn(FpdfPage) -> FpdfTextPage,
    close_text_page: unsafe extern "C" fn(FpdfTextPage),
    text_count_chars: unsafe extern "C" fn(FpdfTextPage) -> std::ffi::c_int,
    text_get_unicode: unsafe extern "C" fn(FpdfTextPage, std::ffi::c_int) -> std::ffi::c_uint,
    text_is_generated: unsafe extern "C" fn(FpdfTextPage, std::ffi::c_int) -> std::ffi::c_int,
    text_get_loose_box:
        unsafe extern "C" fn(FpdfTextPage, std::ffi::c_int, *mut FsRectF) -> std::ffi::c_int,
    text_get_origin:
        unsafe extern "C" fn(FpdfTextPage, std::ffi::c_int, *mut f64, *mut f64) -> std::ffi::c_int,
    text_get_font_size: unsafe extern "C" fn(FpdfTextPage, std::ffi::c_int) -> f64,
    text_get_matrix:
        unsafe extern "C" fn(FpdfTextPage, std::ffi::c_int, *mut FsMatrix) -> std::ffi::c_int,
}

static REDACT_API: OnceLock<Option<&'static RedactApi>> = OnceLock::new();

fn redact_api() -> Result<&'static RedactApi> {
    REDACT_API
        .get_or_init(|| {
            for candidate in crate::backend::library_candidates() {
                // SAFETY: loading a dynamic library is inherently unsafe; these are the same
                // PDFium paths the backend loads, and `resolve_api` checks every name.
                let Ok(library) = (unsafe { Library::new(candidate.as_os_str()) }) else {
                    continue;
                };
                // SAFETY: the library at these paths is PDFium, and every signature below is
                // transcribed from the vendored `fpdf_*.h` headers.
                if let Some(api) = unsafe { resolve_api(library) } {
                    return Some(&*Box::leak(Box::new(api)));
                }
            }
            None
        })
        .as_ref()
        .copied()
        .ok_or_else(|| {
            LyraReaderError::new(
                ErrorCode::BackendUnavailable,
                "this PDFium build does not export the redaction API",
            )
            .with_detail(
                "missing one of FPDFText_* / FPDF_RenderPageBitmap / FPDFPage_CountObjects",
            )
        })
}

/// # Safety
///
/// The caller must have loaded a PDFium-compatible library. Every signature is transcribed from
/// the vendored headers; a wrong signature would be undefined behaviour.
unsafe fn resolve_api(library: Library) -> Option<RedactApi> {
    unsafe fn symbol<T: Copy>(library: &Library, name: &[u8]) -> Option<T> {
        // SAFETY: `T` is always one of the `extern "C" fn` types declared in `RedactApi`.
        unsafe { library.get::<T>(name).ok().map(|symbol| *symbol) }
    }
    Some(RedactApi {
        load_mem_document: unsafe { symbol(&library, b"FPDF_LoadMemDocument\0")? },
        close_document: unsafe { symbol(&library, b"FPDF_CloseDocument\0")? },
        get_page_count: unsafe { symbol(&library, b"FPDF_GetPageCount\0")? },
        load_page: unsafe { symbol(&library, b"FPDF_LoadPage\0")? },
        close_page: unsafe { symbol(&library, b"FPDF_ClosePage\0")? },
        get_page_width: unsafe { symbol(&library, b"FPDF_GetPageWidthF\0")? },
        get_page_height: unsafe { symbol(&library, b"FPDF_GetPageHeightF\0")? },
        get_rotation: unsafe { symbol(&library, b"FPDFPage_GetRotation\0")? },
        get_crop_box: unsafe { symbol(&library, b"FPDFPage_GetCropBox\0")? },
        count_objects: unsafe { symbol(&library, b"FPDFPage_CountObjects\0")? },
        get_object: unsafe { symbol(&library, b"FPDFPage_GetObject\0")? },
        get_object_type: unsafe { symbol(&library, b"FPDFPageObj_GetType\0")? },
        get_object_bounds: unsafe { symbol(&library, b"FPDFPageObj_GetBounds\0")? },
        create_bitmap: unsafe { symbol(&library, b"FPDFBitmap_Create\0")? },
        bitmap_get_buffer: unsafe { symbol(&library, b"FPDFBitmap_GetBuffer\0")? },
        bitmap_get_stride: unsafe { symbol(&library, b"FPDFBitmap_GetStride\0")? },
        bitmap_fill_rect: unsafe { symbol(&library, b"FPDFBitmap_FillRect\0")? },
        render_page_bitmap: unsafe { symbol(&library, b"FPDF_RenderPageBitmap\0")? },
        destroy_bitmap: unsafe { symbol(&library, b"FPDFBitmap_Destroy\0")? },
        load_text_page: unsafe { symbol(&library, b"FPDFText_LoadPage\0")? },
        close_text_page: unsafe { symbol(&library, b"FPDFText_ClosePage\0")? },
        text_count_chars: unsafe { symbol(&library, b"FPDFText_CountChars\0")? },
        text_get_unicode: unsafe { symbol(&library, b"FPDFText_GetUnicode\0")? },
        text_is_generated: unsafe { symbol(&library, b"FPDFText_IsGenerated\0")? },
        text_get_loose_box: unsafe { symbol(&library, b"FPDFText_GetLooseCharBox\0")? },
        text_get_origin: unsafe { symbol(&library, b"FPDFText_GetCharOrigin\0")? },
        text_get_font_size: unsafe { symbol(&library, b"FPDFText_GetFontSize\0")? },
        text_get_matrix: unsafe { symbol(&library, b"FPDFText_GetMatrix\0")? },
        _library: library,
    })
}

struct RedactDocument {
    api: &'static RedactApi,
    document: FpdfDocument,
    _bytes: Vec<u8>,
}

// SAFETY: every method (and `Drop`) serialises on `PDFIUM_LOCK`; the handle is never used
// concurrently. The same justification as `page_ops::RawDocument`.
unsafe impl Send for RedactDocument {}

impl RedactDocument {
    fn load(api: &'static RedactApi, bytes: Vec<u8>, password: Option<&str>) -> Result<Self> {
        crate::backend::pdfium_instance()?;
        let password = password
            .map(std::ffi::CString::new)
            .transpose()
            .map_err(|_| {
                LyraReaderError::new(
                    ErrorCode::InvalidArgument,
                    "the password contains a NUL byte",
                )
            })?;
        let document = {
            let _guard = PDFIUM_LOCK
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            // SAFETY: `bytes` lives in the returned struct; PDFium documents that the buffer must
            // stay valid while the document is open.
            unsafe {
                (api.load_mem_document)(
                    bytes.as_ptr().cast(),
                    bytes.len() as std::ffi::c_int,
                    password
                        .as_ref()
                        .map_or(std::ptr::null(), |value| value.as_ptr()),
                )
            }
        };
        if document.is_null() {
            return Err(LyraReaderError::new(
                ErrorCode::CorruptDocument,
                "PDFium could not open the document for redaction",
            ));
        }
        Ok(Self {
            api,
            document,
            _bytes: bytes,
        })
    }

    fn page_count(&self) -> u32 {
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        // SAFETY: the document handle is live.
        unsafe { (self.api.get_page_count)(self.document) }.max(0) as u32
    }

    /// The real characters of a page, with degenerate boxes repaired and PDFium's synthetic line
    /// breaks removed. This is the sequence the glyph remover indexes into.
    fn real_page_chars(&self, page: u32) -> Result<Vec<PageChar>> {
        let mut chars = self.page_chars(page)?;
        for character in &mut chars {
            character.repair_degenerate_box();
        }
        chars.retain(|character| !character.generated);
        Ok(chars)
    }

    fn page_chars(&self, page: u32) -> Result<Vec<PageChar>> {
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        // SAFETY: the document is live and the page index comes from the caller's validated set.
        let page_handle = unsafe { (self.api.load_page)(self.document, page as std::ffi::c_int) };
        if page_handle.is_null() {
            return Err(page_error(page));
        }
        let text_page = unsafe { (self.api.load_text_page)(page_handle) };
        if text_page.is_null() {
            unsafe { (self.api.close_page)(page_handle) };
            return Err(LyraReaderError::new(
                ErrorCode::RenderFailed,
                "PDFium could not read a page's text layer",
            )
            .with_detail(format!("page {}", page + 1)));
        }
        let count = unsafe { (self.api.text_count_chars)(text_page) }.max(0);
        let mut chars = Vec::with_capacity(count as usize);
        for index in 0..count {
            // SAFETY: `index` is below the count just returned for this text page.
            let unicode = unsafe { (self.api.text_get_unicode)(text_page, index) };
            let mut box_rect = FsRectF::default();
            let has_box = unsafe {
                (self.api.text_get_loose_box)(text_page, index, std::ptr::addr_of_mut!(box_rect))
            } != 0;
            let mut origin_x = 0.0;
            let mut origin_y = 0.0;
            unsafe {
                (self.api.text_get_origin)(
                    text_page,
                    index,
                    std::ptr::addr_of_mut!(origin_x),
                    std::ptr::addr_of_mut!(origin_y),
                )
            };
            let font_size = unsafe { (self.api.text_get_font_size)(text_page, index) };
            let mut matrix = FsMatrix {
                a: 1.0,
                b: 0.0,
                c: 0.0,
                d: 1.0,
                e: 0.0,
                f: 0.0,
            };
            unsafe { (self.api.text_get_matrix)(text_page, index, std::ptr::addr_of_mut!(matrix)) };
            let (left, top, right, bottom) = if has_box {
                (
                    f64::from(box_rect.left),
                    f64::from(box_rect.top),
                    f64::from(box_rect.right),
                    f64::from(box_rect.bottom),
                )
            } else {
                (origin_x, origin_y, origin_x, origin_y)
            };
            let width = (right - left).abs();
            let height = (top - bottom).abs();
            // PDFium also synthesises spaces between positioned objects. They have non-zero
            // boxes, but no encoded glyph to remove; counting them breaks real-paper mapping.
            let generated = unsafe { (self.api.text_is_generated)(text_page, index) } == 1;
            chars.push(PageChar {
                unicode,
                rect: Rect::new(left.min(right), bottom.min(top), width, height),
                origin_x,
                origin_y,
                font_size,
                matrix: [
                    f64::from(matrix.a),
                    f64::from(matrix.b),
                    f64::from(matrix.c),
                    f64::from(matrix.d),
                    f64::from(matrix.e),
                    f64::from(matrix.f),
                ],
                generated,
            });
        }
        unsafe { (self.api.close_text_page)(text_page) };
        unsafe { (self.api.close_page)(page_handle) };
        Ok(chars)
    }

    fn intersecting_graphics(&self, page: u32, rects: &[Rect]) -> Result<usize> {
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let page_handle = unsafe { (self.api.load_page)(self.document, page as std::ffi::c_int) };
        if page_handle.is_null() {
            return Err(page_error(page));
        }
        let count = unsafe { (self.api.count_objects)(page_handle) }.max(0);
        let mut hits = 0;
        for index in 0..count {
            let object = unsafe { (self.api.get_object)(page_handle, index) };
            if object.is_null() {
                continue;
            }
            let object_type = unsafe { (self.api.get_object_type)(object) };
            // 1 = text, 2 = path, 3 = image, 4 = shading, 5 = form. Text is counted as
            // characters, not graphics.
            if object_type <= 1 {
                continue;
            }
            let mut left = 0.0f32;
            let mut top = 0.0f32;
            let mut right = 0.0f32;
            let mut bottom = 0.0f32;
            let ok = unsafe {
                (self.api.get_object_bounds)(
                    object,
                    std::ptr::addr_of_mut!(left),
                    std::ptr::addr_of_mut!(top),
                    std::ptr::addr_of_mut!(right),
                    std::ptr::addr_of_mut!(bottom),
                )
            } != 0;
            if !ok {
                continue;
            }
            let bounds = Rect::new(
                f64::from(left.min(right)),
                f64::from(bottom.min(top)),
                f64::from((right - left).abs()),
                f64::from((top - bottom).abs()),
            );
            if rects.iter().any(|rect| intersects(rect, &bounds)) {
                hits += 1;
            }
        }
        unsafe { (self.api.close_page)(page_handle) };
        Ok(hits)
    }

    fn render_page(&self, page: u32, scale: f64) -> Result<RasterImage> {
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        render_page_locked(self.api, self.document, page, scale)
    }
}

impl Drop for RedactDocument {
    fn drop(&mut self) {
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        // SAFETY: the handle came from `load_mem_document` and is closed exactly once.
        unsafe { (self.api.close_document)(self.document) };
    }
}

fn page_error(page: u32) -> LyraReaderError {
    LyraReaderError::new(
        ErrorCode::RenderFailed,
        "PDFium could not load a page for redaction",
    )
    .with_detail(format!("page {}", page + 1))
}

#[derive(Clone, Debug)]
struct RasterImage {
    width: usize,
    height: usize,
    /// Tightly packed RGB, 3 bytes per pixel, row-major top-to-bottom.
    rgb: Vec<u8>,
    /// Page-space rectangle the raster covers (crop box origin at its bottom-left).
    bounds: Rect,
}

impl RasterImage {
    fn pixel_at(&self, page_x: f64, page_y: f64) -> Option<(u8, u8, u8)> {
        if self.bounds.size.width <= 0.0 || self.bounds.size.height <= 0.0 {
            return None;
        }
        let x =
            ((page_x - self.bounds.origin.x) / self.bounds.size.width * self.width as f64).floor();
        let y = ((self.bounds.origin.y + self.bounds.size.height - page_y)
            / self.bounds.size.height
            * self.height as f64)
            .floor();
        if x < 0.0 || y < 0.0 || x >= self.width as f64 || y >= self.height as f64 {
            return None;
        }
        let offset = (y as usize * self.width + x as usize) * 3;
        Some((self.rgb[offset], self.rgb[offset + 1], self.rgb[offset + 2]))
    }

    fn fill(&mut self, rect: &Rect, fill: RedactionFill) {
        if self.bounds.size.width <= 0.0 || self.bounds.size.height <= 0.0 {
            return;
        }
        let sx = self.width as f64 / self.bounds.size.width;
        let sy = self.height as f64 / self.bounds.size.height;
        let left = ((rect.origin.x - self.bounds.origin.x) * sx)
            .floor()
            .max(0.0) as usize;
        let right = (((rect.origin.x + rect.size.width - self.bounds.origin.x) * sx).ceil())
            .clamp(0.0, self.width as f64) as usize;
        let top = ((self.bounds.origin.y + self.bounds.size.height
            - (rect.origin.y + rect.size.height))
            * sy)
            .floor()
            .max(0.0) as usize;
        let bottom = (((self.bounds.origin.y + self.bounds.size.height - rect.origin.y) * sy)
            .ceil())
        .clamp(0.0, self.height as f64) as usize;
        for y in top..bottom {
            for x in left..right {
                let offset = (y * self.width + x) * 3;
                self.rgb[offset] = fill.component();
                self.rgb[offset + 1] = fill.component();
                self.rgb[offset + 2] = fill.component();
            }
        }
    }
}

fn render_raster(
    document: &RedactDocument,
    api: &'static RedactApi,
    page: u32,
    rects: &[Rect],
    fill: RedactionFill,
) -> Result<RasterImage> {
    let scale = RASTER_DPI / 72.0;
    let mut raster = {
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        render_page_locked(api, document.document, page, scale)?
    };
    for rect in rects {
        raster.fill(rect, fill);
    }
    Ok(raster)
}

fn render_page_locked(
    api: &'static RedactApi,
    document: FpdfDocument,
    page: u32,
    scale: f64,
) -> Result<RasterImage> {
    let page_handle = unsafe { (api.load_page)(document, page as std::ffi::c_int) };
    if page_handle.is_null() {
        return Err(page_error(page));
    }
    let rotation = unsafe { (api.get_rotation)(page_handle) };
    if rotation.rem_euclid(360) != 0 {
        unsafe { (api.close_page)(page_handle) };
        return Err(LyraReaderError::new(
            ErrorCode::UnsupportedFeature,
            "a redaction could not be attributed on a rotated page",
        )
        .with_detail(format!(
            "page {} is rotated {rotation}°; rasterising it is not supported here",
            page + 1
        )));
    }
    let width_pt = f64::from(unsafe { (api.get_page_width)(page_handle) }).max(1.0);
    let height_pt = f64::from(unsafe { (api.get_page_height)(page_handle) }).max(1.0);
    let mut crop = FsRectF::default();
    let has_crop = unsafe {
        (api.get_crop_box)(
            page_handle,
            std::ptr::addr_of_mut!(crop.left),
            std::ptr::addr_of_mut!(crop.bottom),
            std::ptr::addr_of_mut!(crop.right),
            std::ptr::addr_of_mut!(crop.top),
        )
    } != 0;
    let bounds = if has_crop {
        Rect::new(
            f64::from(crop.left),
            f64::from(crop.bottom),
            f64::from((crop.right - crop.left).abs()),
            f64::from((crop.top - crop.bottom).abs()),
        )
    } else {
        Rect::new(0.0, 0.0, width_pt, height_pt)
    };
    let width = (bounds.size.width * scale).round().max(1.0) as std::ffi::c_int;
    let height = (bounds.size.height * scale).round().max(1.0) as std::ffi::c_int;
    // FPDFBitmap_Create(alpha = 1) gives BGRA with a usable alpha channel.
    let bitmap = unsafe { (api.create_bitmap)(width, height, 1) };
    if bitmap.is_null() {
        unsafe { (api.close_page)(page_handle) };
        return Err(LyraReaderError::new(
            ErrorCode::RenderFailed,
            "PDFium could not allocate a page raster for redaction",
        ));
    }
    unsafe {
        // FPDF_ARGB white.
        (api.bitmap_fill_rect)(bitmap, 0, 0, width, height, 0xFFFF_FFFF);
        (api.render_page_bitmap)(bitmap, page_handle, 0, 0, width, height, 0, 0);
    }
    let stride = unsafe { (api.bitmap_get_stride)(bitmap) } as usize;
    let buffer = unsafe { (api.bitmap_get_buffer)(bitmap) }.cast::<u8>();
    if buffer.is_null() {
        unsafe {
            (api.destroy_bitmap)(bitmap);
            (api.close_page)(page_handle);
        }
        return Err(LyraReaderError::new(
            ErrorCode::RenderFailed,
            "PDFium returned no pixels for a page raster",
        ));
    }
    let mut rgb = Vec::with_capacity(width as usize * height as usize * 3);
    for row in 0..height as usize {
        let row_start = buffer as usize + row * stride;
        for column in 0..width as usize {
            let offset = column * 4;
            // SAFETY: the bitmap buffer has `stride * height` bytes; `column` and `row` are
            // inside the bitmap.
            let pixel = unsafe { std::slice::from_raw_parts((row_start + offset) as *const u8, 3) };
            // BGRA on little-endian; `FPDFBitmap_BGRA` is what `FPDFBitmap_Create` produces.
            rgb.extend_from_slice(&[pixel[2], pixel[1], pixel[0]]);
        }
    }
    unsafe {
        (api.destroy_bitmap)(bitmap);
        (api.close_page)(page_handle);
    }
    Ok(RasterImage {
        width: width as usize,
        height: height as usize,
        rgb,
        bounds,
    })
}

// ─── Small helpers ──────────────────────────────────────────────────────────────────────────

fn matrix_operands(operands: &[Object]) -> Option<[f64; 6]> {
    let values: Vec<f64> = operands.iter().filter_map(number).collect();
    if values.len() < 6 {
        return None;
    }
    Some([
        values[0], values[1], values[2], values[3], values[4], values[5],
    ])
}

fn pair(operands: &[Object]) -> Option<(f64, f64)> {
    let values: Vec<f64> = operands.iter().filter_map(number).collect();
    if values.len() < 2 {
        return None;
    }
    Some((values[0], values[1]))
}

fn four_numbers(operands: &[Object]) -> Option<[f64; 4]> {
    let values: Vec<f64> = operands.iter().filter_map(number).collect();
    if values.len() < 4 {
        return None;
    }
    Some([values[0], values[1], values[2], values[3]])
}

fn six_numbers(operands: &[Object]) -> Option<[f64; 6]> {
    let values: Vec<f64> = operands.iter().filter_map(number).collect();
    if values.len() < 6 {
        return None;
    }
    Some([
        values[0], values[1], values[2], values[3], values[4], values[5],
    ])
}

fn number(object: &Object) -> Option<f64> {
    match object {
        Object::Integer(value) => Some(*value as f64),
        Object::Real(value) => Some(f64::from(*value)),
        _ => None,
    }
}

fn name_bytes(object: &Object) -> Option<&[u8]> {
    match object {
        Object::Name(name) => Some(name),
        _ => None,
    }
}

fn string_bytes(object: &Object) -> Option<&[u8]> {
    match object {
        Object::String(bytes, _) => Some(bytes),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::redaction::RedactDocument;
    use crate::test_support::{copy_fixture, scratch};

    #[test]
    fn raster_redaction_respects_nonzero_crop_box_coordinates() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let scratch = scratch("redaction-crop-box");
        let source = copy_fixture(&scratch, "text-page.pdf", "cropped.pdf");
        let mut document = lopdf::Document::load(&source).unwrap();
        let page = *document.get_pages().values().next().unwrap();
        document
            .get_object_mut(page)
            .unwrap()
            .as_dict_mut()
            .unwrap()
            .set(
                "CropBox",
                vec![
                    Object::Integer(10),
                    Object::Integer(20),
                    Object::Integer(200),
                    Object::Integer(300),
                ],
            );
        document.save(&source).unwrap();
        let document =
            RedactDocument::load(redact_api().unwrap(), fs::read(&source).unwrap(), None).unwrap();
        let raster = document.render_page(0, 1.0).unwrap();
        assert_eq!(raster.bounds, Rect::new(10.0, 20.0, 190.0, 280.0));
        assert_eq!((raster.width, raster.height), (190, 280));
    }

    fn text_of(path: &Path, page: u32) -> String {
        let api = redact_api().expect("api");
        let document =
            RedactDocument::load(api, fs::read(path).expect("read"), None).expect("open");
        document
            .real_page_chars(page)
            .expect("chars")
            .iter()
            .filter_map(|character| char::from_u32(character.unicode))
            .collect()
    }

    fn word_rect(path: &Path, page: u32, word: &str) -> Rect {
        let api = redact_api().expect("api");
        let document =
            RedactDocument::load(api, fs::read(path).expect("read"), None).expect("open");
        let chars = document.real_page_chars(page).expect("chars");
        let needle: Vec<u32> = word.chars().map(u32::from).collect();
        let position = chars
            .windows(needle.len())
            .position(|window| {
                window
                    .iter()
                    .map(|character| character.unicode)
                    .eq(needle.iter().copied())
            })
            .unwrap_or_else(|| panic!("{word:?} not found on page {}", page + 1));
        let mut rect = chars[position].rect;
        for character in &chars[position..position + needle.len()] {
            let left = rect.origin.x.min(character.rect.origin.x);
            let right = (rect.origin.x + rect.size.width)
                .max(character.rect.origin.x + character.rect.size.width);
            let bottom = rect.origin.y.min(character.rect.origin.y);
            let top = (rect.origin.y + rect.size.height)
                .max(character.rect.origin.y + character.rect.size.height);
            rect = Rect::new(left, bottom, right - left, top - bottom);
        }
        // A little padding, like a dragged rectangle would have.
        Rect::new(
            rect.origin.x - 1.0,
            rect.origin.y - 1.0,
            rect.size.width + 2.0,
            rect.size.height + 2.0,
        )
    }

    fn pixel(path: &Path, page: u32, x: f64, y: f64) -> (u8, u8, u8) {
        let api = redact_api().expect("api");
        let document =
            RedactDocument::load(api, fs::read(path).expect("read"), None).expect("open");
        document
            .render_page(page, 1.0)
            .expect("raster")
            .pixel_at(x, y)
            .expect("sample")
    }

    #[test]
    fn a_text_redaction_removes_the_covered_glyphs_and_keeps_the_rest() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("redact-text");
        let source = copy_fixture(&directory, "text-page.pdf", "page.pdf");
        let original = fs::read(&source).expect("original bytes");
        let rect = word_rect(&source, 0, "brown");
        let destination = directory.join("redacted.pdf");

        let report = redact_pdf(
            &source,
            &destination,
            &[RedactionArea::new(0, rect)],
            None,
            RedactionMode::Copy,
        )
        .expect("redact");

        assert!(report.verified);
        assert!(report.original_unchanged);
        assert!(report.backup_path.is_none());
        assert_eq!(
            fs::read(&source).expect("source after"),
            original,
            "the copy mode must not touch the source"
        );
        let page = report.pages.first().expect("page report");
        assert!(
            !page.rasterized,
            "the text page must be rewritten, not rasterised"
        );
        assert!(page.removed_characters >= 5);

        let saved = text_of(&destination, 0);
        assert!(
            !saved.contains("brown"),
            "the covered word must not be extractable: {saved}"
        );
        assert!(
            saved.contains("quick"),
            "text before the mark survives: {saved}"
        );
        assert!(
            saved.contains("jumps"),
            "text after the mark survives: {saved}"
        );
        assert!(saved.contains("LyraReader fixture"), "other lines survive");
        assert!(saved.contains("Line 6:"), "the last text line survives");

        let (red, green, blue) = pixel(
            &destination,
            0,
            rect.origin.x + rect.size.width / 2.0,
            rect.origin.y + rect.size.height / 2.0,
        );
        assert!(
            red < 40 && green < 40 && blue < 40,
            "the saved page shows the black mark (got {red},{green},{blue})"
        );
    }

    #[test]
    fn a_vector_redaction_removes_the_whole_intersecting_path() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("redact-vector");
        let source = copy_fixture(&directory, "text-page.pdf", "page.pdf");
        // The fixture strokes a 451×120 pt blue rectangle from (72, 300) to (523, 420). This
        // small mark touches only the rectangle's interior, so if the writer merely painted a
        // box over the mark, the stroke at (450, 420) would still be blue.
        let mark = Rect::new(200.0, 350.0, 20.0, 20.0);
        let before = pixel(&source, 0, 450.0, 420.0);
        assert!(
            before.2 > 150 && before.0 < 100,
            "fixture stroke is blue: {before:?}"
        );
        let destination = directory.join("redacted.pdf");
        let report = redact_pdf(
            &source,
            &destination,
            &[RedactionArea::new(0, mark)],
            None,
            RedactionMode::Copy,
        )
        .expect("redact");
        assert!(!report.pages[0].rasterized);
        assert!(
            report.pages[0].removed_graphics >= 1,
            "the intersecting vector path is removed as a whole object"
        );
        let after = pixel(&destination, 0, 450.0, 420.0);
        assert!(
            after.0 > 220 && after.1 > 220 && after.2 > 220,
            "the vector path outside the mark is gone, not painted over ({after:?})"
        );
        let saved = text_of(&destination, 0);
        assert!(
            saved.contains("Line 1:"),
            "text on the page survives a vector redaction"
        );
    }

    #[test]
    fn replacing_the_original_writes_a_verified_backup_and_removes_the_text() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("redact-replace");
        let source = copy_fixture(&directory, "text-page.pdf", "page.pdf");
        let original = fs::read(&source).expect("original bytes");
        let rect = word_rect(&source, 0, "quick");
        let report = redact_pdf(
            &source,
            &source,
            &[RedactionArea::new(0, rect)],
            None,
            RedactionMode::ReplaceOriginal,
        )
        .expect("replace");

        let backup = report.backup_path.expect("a backup");
        assert_eq!(fs::read(&backup).expect("backup bytes"), original);
        assert_ne!(fs::read(&source).expect("redacted bytes"), original);
        assert!(!report.original_unchanged);
        let saved = text_of(&source, 0);
        assert!(
            !saved.contains("quick"),
            "the word is gone from the replaced file"
        );
        assert!(saved.contains("fox"), "the rest of the line survives");
    }

    #[test]
    fn a_copy_may_not_overwrite_its_source() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("redact-refuse");
        let source = copy_fixture(&directory, "text-page.pdf", "page.pdf");
        let error = redact_pdf(
            &source,
            &source,
            &[RedactionArea::new(0, Rect::new(10.0, 10.0, 20.0, 20.0))],
            None,
            RedactionMode::Copy,
        )
        .expect_err("a copy onto the source must be refused");
        assert!(error.to_string().contains("overwrite"), "{error}");
    }

    #[test]
    fn a_page_with_form_text_is_rasterised_and_loses_its_whole_text_layer() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("redact-raster");
        let source = directory.join("form-text.pdf");
        write_form_text_fixture(&source);
        let rect = word_rect(&source, 0, "Secret");
        let destination = directory.join("redacted.pdf");
        let report = redact_pdf(
            &source,
            &destination,
            &[RedactionArea::new(0, rect)],
            None,
            RedactionMode::Copy,
        )
        .expect("redact");
        assert!(report.pages[0].rasterized, "form text cannot be attributed");
        assert!(
            text_of(&destination, 0).trim().is_empty(),
            "the rasterised page has no extractable text at all"
        );
        let (red, green, blue) = pixel(
            &destination,
            0,
            rect.origin.x + rect.size.width / 2.0,
            rect.origin.y + rect.size.height / 2.0,
        );
        assert!(red < 40 && green < 40 && blue < 40);
    }

    #[test]
    fn the_preview_reports_what_the_confirmation_needs() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("redact-preview");
        let source = copy_fixture(&directory, "text-page.pdf", "page.pdf");
        let rect = word_rect(&source, 0, "brown");
        let preview = preview_redactions(&source, &[RedactionArea::new(0, rect)]).expect("preview");
        assert_eq!(preview.pages.len(), 1);
        assert_eq!(preview.pages[0].page, 0);
        assert!(preview.pages[0].text_preview.contains("brown"));
        assert_eq!(preview.removed_characters, preview.pages[0].characters);
        assert!(preview.removed_characters >= 5);
    }

    #[test]
    fn an_image_under_a_mark_is_removed_as_a_whole_object() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("redact-image");
        let source = directory.join("image.pdf");
        write_image_fixture(&source);
        let before = pixel(&source, 0, 180.0, 180.0);
        assert!(
            before.0 > 180 && before.1 < 80,
            "the fixture image is red at (180,180): {before:?}"
        );
        // The mark is inside the image but does not cover (180,180).
        let mark = Rect::new(140.0, 140.0, 20.0, 20.0);
        let destination = directory.join("redacted.pdf");
        let report = redact_pdf(
            &source,
            &destination,
            &[RedactionArea::new(0, mark)],
            None,
            RedactionMode::Copy,
        )
        .expect("image redaction");
        assert!(!report.pages[0].rasterized);
        assert!(
            report.pages[0].removed_graphics >= 1,
            "the intersecting image is removed as a whole object"
        );
        let after = pixel(&destination, 0, 180.0, 180.0);
        assert!(
            after.0 > 230 && after.1 > 230 && after.2 > 230,
            "the image outside the mark is gone, not painted over ({after:?})"
        );
        let saved = text_of(&destination, 0);
        assert!(saved.contains("Image test"), "the page text survives");
    }

    #[test]
    fn scaled_text_keeps_its_outside_glyphs_where_they_were() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("redact-scaled");
        let source = directory.join("scaled.pdf");
        write_text_fixture(
            &source,
            b"BT /F1 10 Tf 2 0 0 2 72 700 Tm (Hello scaled world) Tj ET".to_vec(),
        );
        let rect = word_rect(&source, 0, "scaled");
        let destination = directory.join("redacted.pdf");
        let report = redact_pdf(
            &source,
            &destination,
            &[RedactionArea::new(0, rect)],
            None,
            RedactionMode::Copy,
        )
        .expect("scaled redaction");
        assert!(!report.pages[0].rasterized);
        let saved = text_of(&destination, 0);
        assert!(!saved.contains("scaled"), "{saved}");
        assert!(
            saved.contains("Hello") && saved.contains("world"),
            "{saved}"
        );
    }

    #[test]
    fn a_tj_array_with_numbers_keeps_the_rest_of_the_line_in_place() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("redact-tj");
        let source = directory.join("tj.pdf");
        write_text_fixture(
            &source,
            b"BT /F1 12 Tf 72 700 Td [(Hello ) -120 (scaled) 80 ( world)] TJ ET".to_vec(),
        );
        let rect = word_rect(&source, 0, "scaled");
        let destination = directory.join("redacted.pdf");
        let report = redact_pdf(
            &source,
            &destination,
            &[RedactionArea::new(0, rect)],
            None,
            RedactionMode::Copy,
        )
        .expect("TJ redaction");
        assert!(!report.pages[0].rasterized);
        let saved = text_of(&destination, 0);
        assert!(!saved.contains("scaled"), "{saved}");
        assert!(
            saved.contains("Hello") && saved.contains("world"),
            "{saved}"
        );
    }

    fn write_image_fixture(path: &Path) {
        use lopdf::dictionary;
        let mut document = Document::with_version("1.7");
        let pages_id = document.new_object_id();
        let font_id = document.add_object(dictionary! {
            "Type" => "Font",
            "Subtype" => "Type1",
            "BaseFont" => "Helvetica",
        });
        // A 2x2 red image, uncompressed DeviceRGB.
        let mut image_dict = Dictionary::new();
        image_dict.set("Type", Object::Name(b"XObject".to_vec()));
        image_dict.set("Subtype", Object::Name(b"Image".to_vec()));
        image_dict.set("Width", Object::Integer(2));
        image_dict.set("Height", Object::Integer(2));
        image_dict.set("ColorSpace", Object::Name(b"DeviceRGB".to_vec()));
        image_dict.set("BitsPerComponent", Object::Integer(8));
        let image_id = document.add_object(Object::Stream(Stream::new(
            image_dict,
            vec![255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0, 0],
        )));
        let content =
            b"BT /F1 12 Tf 72 700 Td (Image test) Tj ET\nq 100 0 0 100 100 100 cm /Im0 Do Q"
                .to_vec();
        let contents_id = document.add_object(Object::Stream(Stream::new(dictionary! {}, content)));
        let page_id = document.add_object(dictionary! {
            "Type" => "Page",
            "Parent" => pages_id,
            "MediaBox" => vec![0.into(), 0.into(), 612.into(), 792.into()],
            "Resources" => dictionary! {
                "Font" => dictionary! { "F1" => font_id },
                "XObject" => dictionary! { "Im0" => image_id },
            },
            "Contents" => contents_id,
        });
        document.objects.insert(
            pages_id,
            Object::Dictionary(dictionary! {
                "Type" => "Pages",
                "Kids" => vec![page_id.into()],
                "Count" => 1,
            }),
        );
        let catalog_id = document.add_object(dictionary! {
            "Type" => "Catalog",
            "Pages" => pages_id,
        });
        document.trailer.set("Root", catalog_id);
        document.save(path).expect("save fixture");
    }

    fn write_text_fixture(path: &Path, content: Vec<u8>) {
        use lopdf::dictionary;
        let mut document = Document::with_version("1.7");
        let pages_id = document.new_object_id();
        let font_id = document.add_object(dictionary! {
            "Type" => "Font",
            "Subtype" => "Type1",
            "BaseFont" => "Helvetica",
        });
        let contents_id = document.add_object(Object::Stream(Stream::new(dictionary! {}, content)));
        let page_id = document.add_object(dictionary! {
            "Type" => "Page",
            "Parent" => pages_id,
            "MediaBox" => vec![0.into(), 0.into(), 612.into(), 792.into()],
            "Resources" => dictionary! { "Font" => dictionary! { "F1" => font_id } },
            "Contents" => contents_id,
        });
        document.objects.insert(
            pages_id,
            Object::Dictionary(dictionary! {
                "Type" => "Pages",
                "Kids" => vec![page_id.into()],
                "Count" => 1,
            }),
        );
        let catalog_id = document.add_object(dictionary! {
            "Type" => "Catalog",
            "Pages" => pages_id,
        });
        document.trailer.set("Root", catalog_id);
        document.save(path).expect("save fixture");
    }

    fn write_form_text_fixture(path: &Path) {
        use lopdf::dictionary;
        let mut document = Document::with_version("1.7");
        let pages_id = document.new_object_id();
        let font_id = document.add_object(dictionary! {
            "Type" => "Font",
            "Subtype" => "Type1",
            "BaseFont" => "Helvetica",
        });
        let form_content = b"BT /F1 24 Tf 72 700 Td (Secret form text) Tj ET".to_vec();
        let form_id = document.add_object(Object::Stream(Stream::new(
            dictionary! {
                "Type" => "XObject",
                "Subtype" => "Form",
                "BBox" => vec![0.into(), 0.into(), 612.into(), 792.into()],
                "Resources" => dictionary! { "Font" => dictionary! { "F1" => font_id } },
            },
            form_content,
        )));
        let contents_id = document.add_object(Object::Stream(Stream::new(
            dictionary! {},
            b"q /Fm0 Do Q".to_vec(),
        )));
        let page_id = document.add_object(dictionary! {
            "Type" => "Page",
            "Parent" => pages_id,
            "MediaBox" => vec![0.into(), 0.into(), 612.into(), 792.into()],
            "Resources" => dictionary! {
                "XObject" => dictionary! { "Fm0" => form_id },
            },
            "Contents" => contents_id,
        });
        document.objects.insert(
            pages_id,
            Object::Dictionary(dictionary! {
                "Type" => "Pages",
                "Kids" => vec![page_id.into()],
                "Count" => 1,
            }),
        );
        let catalog_id = document.add_object(dictionary! {
            "Type" => "Catalog",
            "Pages" => pages_id,
        });
        document.trailer.set("Root", catalog_id);
        document.save(path).expect("save fixture");
    }
}
