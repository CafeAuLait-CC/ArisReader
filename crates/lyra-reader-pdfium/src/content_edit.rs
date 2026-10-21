//! Editing the page's actual objects, rather than painting an annotation over its content.
//!
//! Coordinates and object identities belong to one immutable source revision. A command is
//! applied to a separate working PDF, verified after reopening, then atomically published.
//! The caller keeps these working revisions for undo; final publication uses the existing
//! signature-aware page-edit transaction. Paragraphs are spatial groups, not single Tj strings.

use crate::backend::{PDFIUM_LOCK, pdfium_instance};
use crate::rewrite::{TextComparison, verify_document_equivalence};
use crate::writeback::{OutputMode, write_rewritten_pdf};
use lyra_reader_core::{
    DocumentBackend, ErrorCode, LyraReaderError, PageIndex, RasterRequest, Rect, Result,
    Transform2D,
};
use pdfium_render::prelude::*;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::Path;
mod flat;
mod layout;
mod links;
mod nested;

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq)]
pub struct ContentBox {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
impl ContentBox {
    fn rect(self) -> Rect {
        Rect::new(self.x, self.y, self.width, self.height)
    }
    fn union(self, other: Self) -> Self {
        Self::from(self.rect().union(other.rect()))
    }
    fn valid(self) -> bool {
        [self.x, self.y, self.width, self.height]
            .iter()
            .all(|v| v.is_finite())
            && self.width > 0.0
            && self.height > 0.0
            && self.width <= 1_000_000.0
            && self.height <= 1_000_000.0
            && self.x.abs() <= 10_000_000.0
            && self.y.abs() <= 10_000_000.0
    }
    fn top(self) -> f64 {
        self.y + self.height
    }
    fn right(self) -> f64 {
        self.x + self.width
    }
}
impl From<Rect> for ContentBox {
    fn from(r: Rect) -> Self {
        Self {
            x: r.origin.x,
            y: r.origin.y,
            width: r.size.width,
            height: r.size.height,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ContentItem {
    pub id: String,
    pub kind: String,
    pub bounds: ContentBox,
    pub text: String,
    pub font: String,
    pub size: f64,
    pub colour: [u8; 4],
    pub can_edit_text: bool,
    pub reason: Option<String>,
    pub paths: Vec<Vec<usize>>,
    pub baseline: f64,
    pub link_page: Option<u32>,
    pub link_uri: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ContentPage {
    pub revision: String,
    pub page: u32,
    pub items: Vec<ContentItem>,
}

/// Typed wire format used by the FFI and CLI. All rectangles are PDF user space.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "camelCase", deny_unknown_fields)]
pub enum ContentCommand {
    Transform {
        revision: String,
        target: String,
        bounds: ContentBox,
        #[serde(default)]
        rotation: f64,
    },
    ReplaceText {
        revision: String,
        target: String,
        text: String,
        bounds: ContentBox,
        font: String,
        size: f64,
        colour: [u8; 4],
        alignment: u8,
    },
    InsertText {
        revision: String,
        text: String,
        bounds: ContentBox,
        font: String,
        size: f64,
        colour: [u8; 4],
        alignment: u8,
    },
    Delete {
        revision: String,
        target: String,
    },
    Redact {
        revision: String,
        bounds: ContentBox,
        blackout: bool,
    },
    InsertImage {
        revision: String,
        bounds: ContentBox,
        image_path: String,
    },
    ReplaceImage {
        revision: String,
        target: String,
        image_path: String,
    },
    CropImage {
        revision: String,
        target: String,
        crop: ContentBox,
    },
    SetLink {
        revision: String,
        target: Option<String>,
        bounds: ContentBox,
        page: Option<u32>,
        uri: Option<String>,
    },
}

fn failure(message: impl Into<String>) -> LyraReaderError {
    LyraReaderError::new(ErrorCode::InvalidArgument, message)
}
fn pdf_error(error: impl std::fmt::Display) -> LyraReaderError {
    LyraReaderError::new(ErrorCode::Internal, "PDF content operation failed")
        .with_detail(error.to_string())
}
fn fingerprint(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

pub fn inspect_content(source: &Path, page_index: u32) -> Result<ContentPage> {
    let bytes = fs::read(source).map_err(pdf_error)?;
    let pdfium = pdfium_instance()?;
    let mut snapshot = {
        let _guard = PDFIUM_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let doc = pdfium
            .load_pdf_from_byte_slice(&bytes, None)
            .map_err(pdf_error)?;
        inspect_open(&doc, page_index, fingerprint(&bytes))?
    };
    links::append(source, page_index, &mut snapshot)?;
    layout::apply(&bytes, &mut snapshot)?;
    flat::append(&bytes, &mut snapshot)?;
    nested::apply_clips(&bytes, &mut snapshot)?;
    Ok(snapshot)
}

fn inspect_open(doc: &PdfDocument<'_>, index: u32, revision: String) -> Result<ContentPage> {
    let page = doc
        .pages()
        .get(index.try_into().map_err(pdf_error)?)
        .map_err(pdf_error)?;
    let text = page.text().map_err(pdf_error)?;
    // Group and lay out text in the reader's orientation, with an upward Y axis.
    // The public snapshot and every command still use unrotated PDF user space.
    let sheet = crate::backend::page_geometry(&page)
        .page_to_view(1.0)
        .then(Transform2D::scale(1.0, -1.0));
    let mut items = Vec::new();
    for (index, object) in page.objects().iter().enumerate() {
        collect(
            object,
            vec![index],
            PdfMatrix::IDENTITY,
            sheet,
            &text,
            &mut items,
            0,
        )?;
    }
    for item in &mut items {
        item.bounds = sheet.apply_rect(item.bounds.rect()).into();
    }
    group_paragraphs(&mut items);
    let inverse = sheet
        .inverse()
        .ok_or_else(|| failure("The page transform is singular."))?;
    for item in &mut items {
        item.bounds = inverse.apply_rect(item.bounds.rect()).into();
    }
    Ok(ContentPage {
        revision,
        page: index,
        items,
    })
}

fn object_box(object: &PdfPageObject<'_>, parent: PdfMatrix) -> Result<ContentBox> {
    let r = object.bounds().map_err(pdf_error)?.to_rect();
    let corners = [
        (r.left(), r.bottom()),
        (r.left(), r.top()),
        (r.right(), r.bottom()),
        (r.right(), r.top()),
    ];
    let points: Vec<_> = corners
        .into_iter()
        .map(|(x, y)| parent.apply_to_points(x, y))
        .collect();
    let min_x = points
        .iter()
        .map(|(x, _)| f64::from(x.value))
        .fold(f64::INFINITY, f64::min);
    let max_x = points
        .iter()
        .map(|(x, _)| f64::from(x.value))
        .fold(f64::NEG_INFINITY, f64::max);
    let min_y = points
        .iter()
        .map(|(_, y)| f64::from(y.value))
        .fold(f64::INFINITY, f64::min);
    let max_y = points
        .iter()
        .map(|(_, y)| f64::from(y.value))
        .fold(f64::NEG_INFINITY, f64::max);
    Ok(ContentBox {
        x: min_x,
        y: min_y,
        width: max_x - min_x,
        height: max_y - min_y,
    })
}

fn collect(
    object: PdfPageObject<'_>,
    path: Vec<usize>,
    parent: PdfMatrix,
    sheet: Transform2D,
    text: &PdfPageText<'_>,
    out: &mut Vec<ContentItem>,
    depth: u8,
) -> Result<()> {
    if depth > 12 {
        return Err(failure("The page's graphics nesting is too deep to edit."));
    }
    let bounds = object_box(&object, parent)?;
    if !bounds.valid() {
        return Ok(());
    }
    let mut item = ContentItem {
        id: path
            .iter()
            .map(usize::to_string)
            .collect::<Vec<_>>()
            .join("."),
        kind: String::new(),
        bounds,
        text: String::new(),
        font: String::new(),
        size: 12.0,
        colour: [0, 0, 0, 255],
        can_edit_text: false,
        reason: None,
        baseline: 0.0,
        link_page: None,
        link_uri: None,
        paths: vec![path.clone()],
    };
    match &object {
        PdfPageObject::Text(o) => {
            item.text = text.for_object(o).trim().replace('\u{2}', "-");
            if item.text.trim().is_empty() || !o.is_visible() {
                return Ok(());
            }
            item.kind = "text".into();
            item.font = o.font().name();
            item.size = f64::from(o.unscaled_font_size().value);
            if let Ok(c) = o.fill_color() {
                item.colour = [c.red(), c.green(), c.blue(), c.alpha()];
            }
            let matrix = o.matrix().map_err(pdf_error)?;
            let combined = matrix.multiply(parent);
            let oriented = combined.multiply(pdf_matrix(sheet));
            item.baseline = f64::from(oriented.f());
            item.size *=
                f64::from((oriented.c() * oriented.c() + oriented.d() * oriented.d()).sqrt());
            item.can_edit_text = path.len() == 1
                && oriented.b().abs() < 0.001
                && oriented.c().abs() < 0.001
                && oriented.a() > 0.0
                && oriented.d() > 0.0
                && !item.font.contains("Type3");
            if !item.can_edit_text {
                item.reason =
                    Some("This graphic label can be moved; its text layout is preserved.".into());
            }
            out.push(item);
        }
        PdfPageObject::Image(_) => {
            item.kind = "image".into();
            out.push(item);
        }
        PdfPageObject::XObjectForm(form) => {
            item.kind = "graphic".into();
            out.push(item);
            let parent = form.matrix().map_err(pdf_error)?.multiply(parent);
            for (index, child) in form.iter().enumerate() {
                let mut child_path = path.clone();
                child_path.push(index);
                collect(child, child_path, parent, sheet, text, out, depth + 1)?;
            }
        }
        _ => {}
    }
    Ok(())
}

/// Join glyph fragments into visual lines, then adjacent lines in the same column. Large
/// horizontal holes (including erased content) remain boundaries instead of joining a paragraph.
fn group_paragraphs(items: &mut Vec<ContentItem>) {
    let mut text: Vec<_> = items.iter().filter(|i| i.kind == "text").cloned().collect();
    items.retain(|i| i.kind != "text");
    text.sort_by(|a, b| b.baseline.total_cmp(&a.baseline));
    let mut rows: Vec<Vec<ContentItem>> = Vec::new();
    for item in text {
        let row = rows.iter_mut().find(|row| {
            let first = &row[0];
            first.paths[0][..first.paths[0].len() - 1] == item.paths[0][..item.paths[0].len() - 1]
                && (first.baseline - item.baseline).abs() < first.size.max(item.size) * 0.18
        });
        if let Some(row) = row {
            row.push(item)
        } else {
            rows.push(vec![item])
        }
    }
    let mut lines: Vec<ContentItem> = Vec::new();
    for mut row in rows {
        row.sort_by(|a, b| a.bounds.x.total_cmp(&b.bounds.x));
        let mut line: Option<ContentItem> = None;
        for item in row {
            if let Some(current) = line.as_mut()
                && item.bounds.x - current.bounds.right() < item.size * 1.6
            {
                if item.bounds.x - current.bounds.right() > item.size * 0.18 {
                    current.text.push(' ')
                }
                merge_item(current, item, "");
            } else {
                if let Some(previous) = line.replace(item) {
                    lines.push(previous)
                }
            }
        }
        if let Some(line) = line {
            lines.push(line)
        }
    }
    let mut paragraphs: Vec<ContentItem> = Vec::new();
    for line in lines {
        let matching = paragraphs.iter_mut().rev().find(|p| {
            let overlap = p.bounds.right().min(line.bounds.right()) - p.bounds.x.max(line.bounds.x);
            p.paths[0][..p.paths[0].len() - 1] == line.paths[0][..line.paths[0].len() - 1]
                && (p.size - line.size).abs() < p.size * 0.15
                && p.font == line.font
                && (p.bounds.x - line.bounds.x).abs() < line.size * 1.2
                && p.bounds.y - line.bounds.top() >= -line.size * 0.25
                && p.bounds.y - line.bounds.top() < line.size * 0.8
                && overlap > p.bounds.width.min(line.bounds.width) * 0.6
        });
        if let Some(p) = matching {
            merge_item(p, line, "\n");
        } else {
            paragraphs.push(line);
        }
    }
    items.extend(paragraphs);
}

fn merge_item(a: &mut ContentItem, b: ContentItem, separator: &str) {
    a.can_edit_text &= b.can_edit_text && a.font == b.font && (a.size - b.size).abs() < 0.5;
    if !a.can_edit_text && a.reason.is_none() {
        a.reason=Some("Mixed typography is preserved when moving this block. Select a simpler text block to edit its words.".into());
    }
    a.id.push(';');
    a.id.push_str(&b.id);
    a.bounds = a.bounds.union(b.bounds);
    a.text.push_str(separator);
    a.text.push_str(&b.text);
    a.paths.extend(b.paths);
}

/// Build and verify a working revision. Never writes to the source or silently rebases stale
/// object indices onto a newer file. Final save/replace is the page-edit publisher's job.
pub fn edit_content(
    source: &Path,
    destination: &Path,
    page_index: u32,
    command: &ContentCommand,
) -> Result<()> {
    let snapshot = inspect_content(source, page_index)?;
    let (revision, target) = match command {
        ContentCommand::Transform {
            revision, target, ..
        }
        | ContentCommand::ReplaceText {
            revision, target, ..
        }
        | ContentCommand::Delete { revision, target }
        | ContentCommand::ReplaceImage {
            revision, target, ..
        }
        | ContentCommand::CropImage {
            revision, target, ..
        } => (revision, Some(target)),
        ContentCommand::InsertText { revision, .. }
        | ContentCommand::Redact { revision, .. }
        | ContentCommand::InsertImage { revision, .. } => (revision, None),
        ContentCommand::SetLink {
            revision, target, ..
        } => (revision, target.as_ref()),
    };
    if revision != &snapshot.revision {
        return Err(failure(
            "The document changed; reload its edit objects before trying again.",
        ));
    }
    let item = target
        .map(|id| {
            snapshot
                .items
                .iter()
                .find(|i| &i.id == id)
                .ok_or_else(|| failure("The selected page object no longer exists."))
        })
        .transpose()?;
    let old = item.map(|i| i.bounds);
    let new = match command {
        ContentCommand::Transform { bounds, .. }
        | ContentCommand::ReplaceText { bounds, .. }
        | ContentCommand::InsertText { bounds, .. }
        | ContentCommand::Redact { bounds, .. }
        | ContentCommand::InsertImage { bounds, .. } => Some(*bounds),
        ContentCommand::SetLink { bounds, .. } => Some(*bounds),
        _ => None,
    };
    if new.is_some_and(|r| !r.valid()) {
        return Err(failure(
            "The edited region must have finite coordinates and a positive size.",
        ));
    }
    let rotated = if let ContentCommand::Transform {
        bounds, rotation, ..
    } = command
    {
        if !rotation.is_finite() {
            return Err(failure("Rotation must be finite."));
        }
        let (sin, cos) = rotation.to_radians().sin_cos();
        let width = bounds.width * cos.abs() + bounds.height * sin.abs();
        let height = bounds.width * sin.abs() + bounds.height * cos.abs();
        Some(ContentBox {
            x: bounds.x + (bounds.width - width) / 2.0,
            y: bounds.y + (bounds.height - height) / 2.0,
            width,
            height,
        })
    } else {
        None
    };
    let allowed = old
        .into_iter()
        .chain(new)
        .chain(rotated)
        .reduce(ContentBox::union)
        .ok_or_else(|| failure("No editable area was selected."))?;
    let bytes = fs::read(source).map_err(pdf_error)?;
    if fingerprint(&bytes) != snapshot.revision {
        return Err(failure("The source changed while preparing this edit."));
    }
    if let ContentCommand::Redact {
        bounds, blackout, ..
    } = command
    {
        let fill = if *blackout {
            crate::redaction::RedactionFill::Blackout
        } else {
            crate::redaction::RedactionFill::Erase
        };
        crate::redaction::stage_content_redaction(
            source,
            destination,
            &[crate::RedactionArea::new(page_index, bounds.rect())],
            fill,
            &bytes,
        )?;
        return Ok(());
    }
    let built = build_revision(&bytes, page_index, command, item)?;
    let mut parsed = lopdf::Document::load_mem(&built).map_err(pdf_error)?;
    layout::update(&mut parsed, page_index, command, item)?;
    parsed.prune_objects();
    let mut output = Vec::new();
    parsed.save_to(&mut output).map_err(pdf_error)?;
    write_rewritten_pdf(
        source,
        destination,
        OutputMode::WorkingRevision,
        |file| std::io::Write::write_all(file, &output).map_err(pdf_error),
        |saved| {
            if fingerprint(&fs::read(source).map_err(pdf_error)?) != snapshot.revision {
                return Err(failure("The source changed during this edit."));
            }
            verify_document_equivalence(source, saved, None, TextComparison::CallerVerified)?;
            verify_pixels(source, saved, page_index, allowed)?;
            if let ContentCommand::ReplaceText { text, .. }
            | ContentCommand::InsertText { text, .. } = command
            {
                let backend = crate::PdfiumBackend::open(saved, None)?;
                let actual: String = backend
                    .raw_text_page(PageIndex(page_index))?
                    .chars
                    .iter()
                    .filter(|c| {
                        new.is_some_and(|r| {
                            c.origin.x >= r.x - 2.0
                                && c.origin.x <= r.right() + 2.0
                                && c.origin.y >= r.y - 2.0
                                && c.origin.y <= r.top() + 2.0
                        })
                    })
                    .filter_map(|c| char::from_u32(c.unicode))
                    .collect();
                let compact = |s: &str| {
                    s.chars()
                        .filter(|c| !c.is_whitespace())
                        .map(|c| if c == '\u{2}' { '-' } else { c })
                        .collect::<String>()
                };
                if !compact(&actual).contains(&compact(text)) {
                    return Err(failure(
                        "The original font cannot encode this text. Choose an installed editor font and try again.",
                    ));
                }
            }
            Ok(())
        },
    )?;
    Ok(())
}

fn build_revision(
    bytes: &[u8],
    index: u32,
    command: &ContentCommand,
    item: Option<&ContentItem>,
) -> Result<Vec<u8>> {
    if let Some(group) = item.filter(|i| i.id.starts_with("group:")) {
        let (bytes, item) = flat::materialize(bytes, index, group)?;
        return build_revision(&bytes, index, command, Some(&item));
    }
    if let ContentCommand::CropImage { crop, .. } = command
        && let Some(item) = item.filter(|i| i.kind == "graphic")
    {
        return nested::crop_graphic(bytes, index, item, *crop);
    }
    if matches!(command, ContentCommand::SetLink { .. }) || item.is_some_and(|i| i.kind == "link") {
        return links::rewrite(bytes, index, command, item);
    }
    if let ContentCommand::Transform {
        bounds, rotation, ..
    } = command
    {
        let item = item.ok_or_else(|| failure("No object selected."))?;
        if item.paths.iter().any(|p| p.len() > 1) {
            if !rotation.is_finite() {
                return Err(failure("Rotation must be finite."));
            }
            let old = item.bounds;
            let sx = bounds.width / old.width;
            let sy = bounds.height / old.height;
            let (sin, cos) = rotation.to_radians().sin_cos();
            let cx = bounds.x + bounds.width / 2.0;
            let cy = bounds.y + bounds.height / 2.0;
            let scale = PdfMatrix::new(
                sx as f32,
                0.0,
                0.0,
                sy as f32,
                (bounds.x - old.x * sx) as f32,
                (bounds.y - old.y * sy) as f32,
            );
            let rotate = PdfMatrix::new(
                cos as f32,
                sin as f32,
                -sin as f32,
                cos as f32,
                (cx - cos * cx + sin * cy) as f32,
                (cy - sin * cx - cos * cy) as f32,
            );
            let mut output = bytes.to_vec();
            for path in &item.paths {
                output = nested::rewrite_path(&output, index, path, scale.multiply(rotate))?;
            }
            return Ok(output);
        }
    }
    let pdfium = pdfium_instance()?;
    let _guard = PDFIUM_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    let mut doc = pdfium
        .load_pdf_from_byte_slice(bytes, None)
        .map_err(pdf_error)?;
    let mut page = doc
        .pages()
        .get(index.try_into().map_err(pdf_error)?)
        .map_err(pdf_error)?;
    let sheet = crate::backend::page_geometry(&page)
        .page_to_view(1.0)
        .then(Transform2D::scale(1.0, -1.0));
    let from_sheet = pdf_matrix(
        sheet
            .inverse()
            .ok_or_else(|| failure("The page transform is singular."))?,
    );
    page.set_content_regeneration_strategy(PdfPageContentRegenerationStrategy::Manual);
    match command {
        ContentCommand::Transform {
            bounds, rotation, ..
        } => {
            let item = item.ok_or_else(|| failure("No object selected."))?;
            if !rotation.is_finite() {
                return Err(failure("Rotation must be finite."));
            }
            let old = item.bounds;
            let sx = bounds.width / old.width;
            let sy = bounds.height / old.height;
            let radians = rotation.to_radians();
            let (sin, cos) = radians.sin_cos();
            let cx = bounds.x + bounds.width / 2.0;
            let cy = bounds.y + bounds.height / 2.0;
            let scale = PdfMatrix::new(
                sx as f32,
                0.0,
                0.0,
                sy as f32,
                (bounds.x - old.x * sx) as f32,
                (bounds.y - old.y * sy) as f32,
            );
            let rotate = PdfMatrix::new(
                cos as f32,
                sin as f32,
                -sin as f32,
                cos as f32,
                (cx - cos * cx + sin * cy) as f32,
                (cy - sin * cx - cos * cy) as f32,
            );
            let transform = scale.multiply(rotate);
            for path in &item.paths {
                transform_path(&page, path, transform)?;
            }
        }
        ContentCommand::ReplaceText {
            text,
            bounds,
            font,
            size,
            colour,
            alignment,
            ..
        }
        | ContentCommand::InsertText {
            text,
            bounds,
            font,
            size,
            colour,
            alignment,
            ..
        } => {
            if item.is_some_and(|i| !i.can_edit_text) {
                return Err(failure(
                    "This block can be moved, but its mixed or graphic text cannot be replaced.",
                ));
            }
            let token = if font == "Original" {
                let item = item.ok_or_else(|| failure("Choose a font for new text."))?;
                let object = page.objects().get(item.paths[0][0]).map_err(pdf_error)?;
                object
                    .as_text_object()
                    .ok_or_else(|| failure("The object is no longer text."))?
                    .font()
                    .token()
            } else {
                choose_font(&mut doc, font)?
            };
            if font == "LyraReader Sans SC"
                && !crate::appearance_font::missing_glyphs(text)?.is_empty()
            {
                return Err(failure(
                    "The editor font does not contain every character. Choose another font or simplify this text.",
                ));
            }
            let objects = layout_text(
                &doc,
                text,
                sheet.apply_rect(bounds.rect()).into(),
                token,
                *size,
                *colour,
                *alignment,
            )?;
            if let Some(item) = item {
                remove_top_level(&mut page, &item.paths)?;
            }
            for mut object in objects {
                object
                    .transform(
                        from_sheet.a(),
                        from_sheet.b(),
                        from_sheet.c(),
                        from_sheet.d(),
                        from_sheet.e(),
                        from_sheet.f(),
                    )
                    .map_err(pdf_error)?;
                page.objects_mut()
                    .add_text_object(object)
                    .map_err(pdf_error)?;
            }
        }
        ContentCommand::Delete { .. } => remove_top_level(
            &mut page,
            &item.ok_or_else(|| failure("No object selected."))?.paths,
        )?,
        ContentCommand::Redact { .. } => unreachable!("redactions use the glyph-removal writer"),
        ContentCommand::SetLink { .. } => unreachable!("links use the annotation writer"),
        ContentCommand::InsertImage {
            bounds, image_path, ..
        } => {
            let (width, height, rgba) = decode_png(Path::new(image_path))?;
            let bounds: ContentBox = sheet.apply_rect(bounds.rect()).into();
            let matrix = PdfMatrix::new(
                bounds.width as f32,
                0.0,
                0.0,
                bounds.height as f32,
                bounds.x as f32,
                bounds.y as f32,
            )
            .multiply(from_sheet);
            let image = new_image(&doc, width, height, rgba, matrix)?;
            page.objects_mut()
                .add_image_object(image)
                .map_err(pdf_error)?;
        }
        ContentCommand::ReplaceImage { image_path, .. } => {
            let item = item.ok_or_else(|| failure("No image selected."))?;
            if item.paths.len() != 1 || item.paths[0].len() != 1 {
                return Err(failure(
                    "Select a top-level image or its complete graphic to replace it.",
                ));
            }
            let matrix = {
                let object = page.objects().get(item.paths[0][0]).map_err(pdf_error)?;
                if let Some(image) = object.as_image_object() {
                    image.matrix().map_err(pdf_error)?
                } else if item.kind == "graphic" {
                    PdfMatrix::new(
                        item.bounds.width as f32,
                        0.0,
                        0.0,
                        item.bounds.height as f32,
                        item.bounds.x as f32,
                        item.bounds.y as f32,
                    )
                } else {
                    return Err(failure("The selection is not an image."));
                }
            };
            let (width, height, rgba) = decode_png(Path::new(image_path))?;
            let image = new_image(&doc, width, height, rgba, matrix)?;
            remove_top_level(&mut page, &item.paths)?;
            page.objects_mut()
                .add_image_object(image)
                .map_err(pdf_error)?;
        }
        ContentCommand::CropImage { crop, .. } => {
            let item = item.ok_or_else(|| failure("No image selected."))?;
            if !crop.valid()
                || crop.x < 0.0
                || crop.y < 0.0
                || crop.right() > 1.000001
                || crop.top() > 1.000001
            {
                return Err(failure("The crop must lie inside the image."));
            }
            if item.paths.len() != 1 || item.paths[0].len() != 1 {
                return Err(failure("Select a top-level bitmap image to crop it."));
            }
            let (width, height, rgba, matrix) = {
                let object = page.objects().get(item.paths[0][0]).map_err(pdf_error)?;
                let image = object
                    .as_image_object()
                    .ok_or_else(|| failure("Cropping requires a bitmap image."))?;
                let bitmap = image.get_raw_bitmap().map_err(pdf_error)?;
                (
                    bitmap.width() as u32,
                    bitmap.height() as u32,
                    bitmap.as_rgba_bytes(),
                    image.matrix().map_err(pdf_error)?,
                )
            };
            let x = (crop.x * f64::from(width)).round() as u32;
            let y = (crop.y * f64::from(height)).round() as u32;
            let w = (crop.width * f64::from(width)).round().max(1.0) as u32;
            let h = (crop.height * f64::from(height)).round().max(1.0) as u32;
            let w = w.min(width - x);
            let h = h.min(height - y);
            if w == 0 || h == 0 {
                return Err(failure("The crop has no image pixels."));
            }
            let mut pixels = Vec::with_capacity(w as usize * h as usize * 4);
            for row in y..y + h {
                let start = ((row * width + x) * 4) as usize;
                pixels.extend_from_slice(&rgba[start..start + w as usize * 4]);
            }
            let crop_matrix = PdfMatrix::new(
                w as f32 / width as f32,
                0.0,
                0.0,
                h as f32 / height as f32,
                x as f32 / width as f32,
                1.0 - (y + h) as f32 / height as f32,
            )
            .multiply(matrix);
            let image = new_image(&doc, w, h, pixels, crop_matrix)?;
            remove_top_level(&mut page, &item.paths)?;
            page.objects_mut()
                .add_image_object(image)
                .map_err(pdf_error)?;
        }
    }
    page.regenerate_content().map_err(pdf_error)?;
    drop(page);
    doc.save_to_bytes().map_err(pdf_error)
}

fn pdf_matrix(t: Transform2D) -> PdfMatrix {
    PdfMatrix::new(
        t.a as f32,
        t.b as f32,
        t.c as f32,
        t.d as f32,
        t.tx as f32,
        t.ty as f32,
    )
}

fn decode_png(path: &Path) -> Result<(u32, u32, Vec<u8>)> {
    let mut decoder = png::Decoder::new(std::io::BufReader::new(
        fs::File::open(path).map_err(pdf_error)?,
    ));
    decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut reader = decoder.read_info().map_err(pdf_error)?;
    let info = reader.info();
    if info.width == 0
        || info.height == 0
        || u64::from(info.width) * u64::from(info.height) > 40_000_000
    {
        return Err(failure("The image exceeds the 40 megapixel editing limit."));
    }
    let mut buffer = vec![
        0;
        reader
            .output_buffer_size()
            .ok_or_else(|| failure("The image is too large."))?
    ];
    let info = reader.next_frame(&mut buffer).map_err(pdf_error)?;
    let samples = &buffer[..info.buffer_size()];
    let mut rgba = Vec::with_capacity(info.width as usize * info.height as usize * 4);
    match info.color_type {
        png::ColorType::Rgba => rgba.extend_from_slice(samples),
        png::ColorType::Rgb => {
            for p in samples.as_chunks::<3>().0 {
                rgba.extend_from_slice(&[p[0], p[1], p[2], 255])
            }
        }
        png::ColorType::Grayscale => {
            for p in samples {
                rgba.extend_from_slice(&[*p, *p, *p, 255])
            }
        }
        png::ColorType::GrayscaleAlpha => {
            for p in samples.as_chunks::<2>().0 {
                rgba.extend_from_slice(&[p[0], p[0], p[0], p[1]])
            }
        }
        _ => {
            return Err(failure(
                "Convert this image to RGB PNG before inserting it.",
            ));
        }
    }
    Ok((info.width, info.height, rgba))
}
fn new_image<'a>(
    doc: &PdfDocument<'a>,
    width: u32,
    height: u32,
    mut rgba: Vec<u8>,
    matrix: PdfMatrix,
) -> Result<PdfPageImageObject<'a>> {
    for pixel in rgba.as_chunks_mut::<4>().0 {
        pixel.swap(0, 2)
    }
    let bitmap = PdfBitmap::from_bytes(
        width.try_into().map_err(pdf_error)?,
        height.try_into().map_err(pdf_error)?,
        PdfBitmapFormat::BGRA,
        &mut rgba,
    )
    .map_err(pdf_error)?;
    let mut image = PdfPageImageObject::new(doc).map_err(pdf_error)?;
    image.set_bitmap(&bitmap).map_err(pdf_error)?;
    image.reset_matrix(matrix).map_err(pdf_error)?;
    Ok(image)
}

pub fn content_image(source: &Path, index: u32, target: &str, revision: &str) -> Result<Vec<u8>> {
    let snapshot = inspect_content(source, index)?;
    if snapshot.revision != revision {
        return Err(failure("The image belongs to an older document revision."));
    }
    let item = snapshot
        .items
        .iter()
        .find(|i| i.id == target && i.kind == "image")
        .ok_or_else(|| failure("Select a bitmap image to export."))?;
    let bytes = fs::read(source).map_err(pdf_error)?;
    if fingerprint(&bytes) != snapshot.revision {
        return Err(failure("The source changed while exporting this image."));
    }
    let pdfium = pdfium_instance()?;
    let _guard = PDFIUM_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    let doc = pdfium
        .load_pdf_from_byte_slice(&bytes, None)
        .map_err(pdf_error)?;
    let page = doc
        .pages()
        .get(index.try_into().map_err(pdf_error)?)
        .map_err(pdf_error)?;
    let object = page.objects().get(item.paths[0][0]).map_err(pdf_error)?;
    export_nested(object, &item.paths[0][1..])
}
fn export_nested(object: PdfPageObject<'_>, path: &[usize]) -> Result<Vec<u8>> {
    if let Some((&index, rest)) = path.split_first() {
        return export_nested(
            object
                .as_x_object_form_object()
                .ok_or_else(|| failure("The image hierarchy changed."))?
                .get(index)
                .map_err(pdf_error)?,
            rest,
        );
    }
    let image = object
        .as_image_object()
        .ok_or_else(|| failure("The object is not a bitmap image."))?;
    let bitmap = image.get_raw_bitmap().map_err(pdf_error)?;
    let mut output = Vec::new();
    {
        let mut encoder =
            png::Encoder::new(&mut output, bitmap.width() as u32, bitmap.height() as u32);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder.write_header().map_err(pdf_error)?;
        writer
            .write_image_data(&bitmap.as_rgba_bytes())
            .map_err(pdf_error)?;
    }
    Ok(output)
}

fn remove_top_level(page: &mut PdfPage<'_>, paths: &[Vec<usize>]) -> Result<()> {
    if paths.iter().any(|p| p.len() != 1) {
        return Err(failure(
            "Deleting nested graphic content is not supported; move the label or select its whole graphic.",
        ));
    }
    let mut indices: Vec<_> = paths.iter().map(|p| p[0]).collect();
    indices.sort_unstable();
    indices.dedup();
    for index in indices.into_iter().rev() {
        page.objects_mut()
            .remove_object_at_index(index)
            .map_err(pdf_error)?;
    }
    Ok(())
}

fn transform_path(page: &PdfPage<'_>, path: &[usize], matrix: PdfMatrix) -> Result<()> {
    let object = page.objects().get(path[0]).map_err(pdf_error)?;
    transform_nested(object, &path[1..], matrix)
}
fn transform_nested(
    mut object: PdfPageObject<'_>,
    path: &[usize],
    matrix: PdfMatrix,
) -> Result<()> {
    if path.is_empty() {
        match &mut object {
            PdfPageObject::Text(o) => o.transform(
                matrix.a(),
                matrix.b(),
                matrix.c(),
                matrix.d(),
                matrix.e(),
                matrix.f(),
            ),
            PdfPageObject::Image(o) => o.transform(
                matrix.a(),
                matrix.b(),
                matrix.c(),
                matrix.d(),
                matrix.e(),
                matrix.f(),
            ),
            PdfPageObject::XObjectForm(o) => o.transform(
                matrix.a(),
                matrix.b(),
                matrix.c(),
                matrix.d(),
                matrix.e(),
                matrix.f(),
            ),
            PdfPageObject::Path(o) => o.transform(
                matrix.a(),
                matrix.b(),
                matrix.c(),
                matrix.d(),
                matrix.e(),
                matrix.f(),
            ),
            _ => return Err(failure("This object cannot be transformed.")),
        }
        .map_err(pdf_error)?;
    } else {
        let form = object
            .as_x_object_form_object_mut()
            .ok_or_else(|| failure("The graphic object hierarchy changed."))?;
        let parent = form.matrix().map_err(pdf_error)?;
        let inverse = parent.invert();
        let local = parent.multiply(matrix).multiply(inverse);
        transform_nested(form.get(path[0]).map_err(pdf_error)?, &path[1..], local)?;
        form.reset_matrix(parent).map_err(pdf_error)?;
    }
    Ok(())
}

fn choose_font(doc: &mut PdfDocument<'_>, name: &str) -> Result<PdfFontToken> {
    let fonts = doc.fonts_mut();
    Ok(match name {
        "Helvetica" => fonts.helvetica(),
        "Helvetica-Bold" => fonts.helvetica_bold(),
        "Helvetica-Oblique" => fonts.helvetica_oblique(),
        "Helvetica-BoldOblique" => fonts.helvetica_bold_oblique(),
        "Times-Roman" => fonts.times_roman(),
        "Times-Bold" => fonts.times_bold(),
        "Times-Italic" => fonts.times_italic(),
        "Times-BoldItalic" => fonts.times_bold_italic(),
        "Courier" => fonts.courier(),
        "Courier-Bold" => fonts.courier_bold(),
        "LyraReader Sans SC" => fonts
            .load_true_type_from_bytes(crate::appearance_font::font_bytes()?, true)
            .map_err(pdf_error)?,
        _ => return Err(failure("Choose a supported editor font.")),
    })
}

fn layout_text<'a>(
    doc: &PdfDocument<'a>,
    text: &str,
    bounds: ContentBox,
    font: PdfFontToken,
    size: f64,
    colour: [u8; 4],
    alignment: u8,
) -> Result<Vec<PdfPageTextObject<'a>>> {
    if !size.is_finite()
        || !(1.0..=512.0).contains(&size)
        || text.chars().count() > 100_000
        || alignment > 2
    {
        return Err(failure("The text style or text length is invalid."));
    }
    if text.trim().is_empty() {
        return Ok(Vec::new());
    }
    if text
        .chars()
        .any(|c| c.is_control() && c != '\n' && c != '\t')
    {
        return Err(failure(
            "Remove unsupported control characters from the edited text.",
        ));
    }
    let mut probe =
        PdfPageTextObject::new(doc, "M", font, PdfPoints::new(size as f32)).map_err(pdf_error)?;
    let mut width = |s: &str| -> Result<f64> {
        if s.is_empty() {
            return Ok(0.0);
        }
        probe.set_text(s).map_err(pdf_error)?;
        Ok(f64::from(
            probe.bounds().map_err(pdf_error)?.to_rect().width().value,
        ))
    };
    let mut lines = Vec::new();
    for paragraph in text.split('\n') {
        let mut line = String::new();
        for word in paragraph.split_whitespace() {
            let candidate = if line.is_empty() {
                word.to_string()
            } else {
                format!("{line} {word}")
            };
            if width(&candidate)? <= bounds.width {
                line = candidate;
                continue;
            }
            if !line.is_empty() {
                lines.push(std::mem::take(&mut line));
            }
            for character in word.chars() {
                let candidate = format!("{line}{character}");
                if !line.is_empty() && width(&candidate)? > bounds.width {
                    lines.push(std::mem::take(&mut line));
                }
                line.push(character);
            }
        }
        lines.push(line);
    }
    let leading = size * 1.2;
    if size + (lines.len().saturating_sub(1) as f64) * leading > bounds.height + size * 0.3 {
        return Err(failure(
            "The edited text exceeds this block. Enlarge the block or reduce its font size.",
        ));
    }
    let mut objects = Vec::new();
    for (index, line) in lines.iter().enumerate() {
        if line.is_empty() {
            continue;
        }
        let w = width(line)?;
        let x = bounds.x
            + match alignment {
                1 => (bounds.width - w) / 2.0,
                2 => bounds.width - w,
                _ => 0.0,
            };
        let mut object = PdfPageTextObject::new(doc, line, font, PdfPoints::new(size as f32))
            .map_err(pdf_error)?;
        object
            .set_fill_color(PdfColor::new(colour[0], colour[1], colour[2], colour[3]))
            .map_err(pdf_error)?;
        object
            .translate(
                PdfPoints::new(x as f32),
                PdfPoints::new((bounds.top() - size * 0.8 - index as f64 * leading) as f32),
            )
            .map_err(pdf_error)?;
        objects.push(object);
    }
    Ok(objects)
}

/// A changed shared form, leaked graphics state or moved neighbour is a failed transaction,
/// even when the edited text itself extracts correctly.
fn verify_pixels(source: &Path, saved: &Path, index: u32, allowed: ContentBox) -> Result<()> {
    let before = crate::PdfiumBackend::open(source, None)?;
    let after = crate::PdfiumBackend::open(saved, None)?;
    for page in 0..before.page_count() {
        let a = before.raw_text_page(PageIndex(page))?;
        let b = after.raw_text_page(PageIndex(page))?;
        if page != index && a.text != b.text {
            return Err(failure(
                "An unrelated page's text changed; the edit was not saved.",
            ));
        }
        if page != index {
            let request = RasterRequest::full_page(PageIndex(page), 1.0);
            let a = before.rasterize(&request)?;
            let b = after.rasterize(&request)?;
            if a.pixels != b.pixels {
                return Err(failure(
                    "An unrelated page's appearance changed; the edit was not saved.",
                ));
            }
        }
    }
    let page = PageIndex(index);
    let info = before.page_info(page)?;
    let tile_a = before.rasterize(&RasterRequest::full_page(page, 1.0))?;
    let tile_b = after.rasterize(&RasterRequest::full_page(page, 1.0))?;
    if tile_a.pixels.len() != tile_b.pixels.len() {
        return Err(failure("The page geometry changed unexpectedly."));
    }
    let rect = allowed.rect();
    let mut changed = 0;
    for (index, (a, b)) in tile_a
        .pixels
        .as_chunks::<4>()
        .0
        .iter()
        .zip(tile_b.pixels.as_chunks::<4>().0)
        .enumerate()
    {
        let width = tile_a.size.width as usize;
        let x = (index % width) as f64 + 0.5;
        let y = (index / width) as f64 + 0.5;
        let point = info
            .geometry
            .view_to_page(1.0)
            .ok_or_else(|| failure("The page transform is singular."))?
            .apply(lyra_reader_core::Point::new(x, y));
        let in_region = point.x >= rect.origin.x - 4.0
            && point.x <= rect.max_x() + 4.0
            && point.y >= rect.origin.y - 4.0
            && point.y <= rect.max_y() + 4.0;
        if !in_region && a.iter().zip(b).any(|(x, y)| x.abs_diff(*y) > 16) {
            changed += 1;
        }
    }
    if changed > 8 {
        return Err(failure(format!(
            "The edit changed {changed} pixels outside the selected area; it was not saved."
        )));
    }
    Ok(())
}
