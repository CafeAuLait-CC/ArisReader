//! Writing the annotations whose dictionaries and appearance streams PDFium's C API cannot
//! produce faithfully: `/Ink`, `/Square`, `/Circle`, `/Line`, `/Text` and `/FreeText`.
//!
//! # Why this does not go through PDFium
//!
//! The quad-based kinds are created with `FPDFPage_CreateAnnot`. The others cannot be:
//!
//! * `FPDFPage_CreateAnnot` returns **null** for `FPDF_ANNOT_LINE` (measured on the vendored
//!   build: subtypes 1, 2, 3, 5, 6, 9–13, 15–17 are creatable; 4, 7, 8, 14 and 18+ are not).
//! * `FPDFAnnot_SetBorder` writes `/Border`, not the `/BS` dictionary this task requires.
//! * `FPDFAnnot_SetAP` does not store an appearance content stream: it runs the argument through
//!   `PDF_EncodeText`, producing a UTF-16 text string inside a form XObject. Measured on the
//!   vendored dylib, a request to draw a line came back as `\xfe\xff q 1 0 0GR3 w 7...`, which
//!   is not paint.
//! * PDFium's annotation API has no setter for `/Name`, the sticky note's icon name, and none
//!   for `/DA` or `/Q`, the free-text fields a viewer that synthesises an appearance needs.
//!
//! So these kinds are written as PDF dictionary objects through lopdf's **incremental** writer:
//! the page's `/Annots` array is copied into the new revision, one indirect annotation object and
//! (for free text and the stroked kinds) one indirect appearance stream are appended per mark,
//! and the original bytes stay the file's prefix. The safety contract around this call —
//! temporary file, verification, backup, atomic rename — is still [`crate::writeback`]'s,
//! unchanged.
//!
//! # Appearance streams, and where they stop
//!
//! A stroked mark's appearance is a Form XObject that strokes the same path the dictionary
//! describes. PDFKit, Preview and Acrobat use it; a viewer that ignores `/AP` still has
//! `/InkList`, `/Rect`, `/L`, `/BS` and `/C` to synthesise from. The two descriptions agree
//! because both are generated from the same [`WriteAnnotation`]; the `/BS` width is the width
//! the stream strokes with.
//!
//! A `/FreeText` annotation gets the same treatment: `/Rect`, `/Contents`, `/DA`, `/Q` and an
//! appearance stream that lays the text out in Helvetica at the requested size. The stream is
//! WinAnsi, so text outside that encoding is written as `?` **in the appearance stream** while
//! `/Contents` keeps the exact Unicode text. A viewer that honours `/AP` shows the WinAnsi form;
//! Lyra and viewers that lay out `/Contents` themselves show the full text. This is the honest
//! limit of not embedding a font, and it is why the shell's own glyph renderer does not read the
//! stream.
//!
//! A `/Text` sticky note deliberately has **no** appearance stream: the shape a viewer draws for
//! it is its own icon, selected by `/Name`, and the body lives in `/Contents` in the viewer's
//! note window. Writing an icon bitmap here would be a second, competing picture of the same
//! annotation.
//!
//! The stream's `/BBox` is the annotation's `/Rect`, with an identity `/Matrix`, so the content
//! is written in the page coordinates the rest of this crate uses.

use crate::annotations::{WriteAnnotation, WriteAnnotationKind};
use aris_reader_core::{AnnotationAlignment, ArisError, ErrorCode, Point, Rect, Result};
use lopdf::{
    Dictionary, Document, IncrementalDocument, LoadOptions, Object, ObjectId, Stream, StringFormat,
};
use std::fs::{self, File};
use std::io::Write;
use std::path::Path;

/// Append the direct-write annotations to `base`, writing the result to `output`.
///
/// `base` and `output` may be the same path: the bytes are read before the output is created.
/// The output is the complete document, not just the update, and its prefix is `base`
/// byte-for-byte. Nothing here renames or verifies; those are the caller's contract.
pub(crate) fn append_direct_annotations(
    base: &Path,
    output: &Path,
    annotations: &[WriteAnnotation],
    password: Option<&str>,
) -> Result<()> {
    if annotations.is_empty() {
        return Ok(());
    }
    let previous_bytes = fs::read(base).map_err(|error| {
        io_error(
            "could not read the document before adding direct-write annotations",
            base,
            error,
        )
    })?;
    let document = load_document(base, password)?;
    let mut incremental = IncrementalDocument::create_from(previous_bytes, document);

    for annotation in annotations {
        if !annotation.kind.is_direct() {
            return Err(ArisError::new(
                ErrorCode::InvalidArgument,
                "the direct writer was given a quad-based annotation",
            )
            .with_detail(format!("{}: {:?}", annotation.id, annotation.kind)));
        }
        append_one(&mut incremental, annotation)?;
    }

    let mut file = File::create(output).map_err(|error| {
        io_error(
            "could not create the file for the annotation update",
            output,
            error,
        )
    })?;
    incremental.save_to(&mut file).map_err(|error| {
        ArisError::new(ErrorCode::Io, "could not write the annotation update")
            .with_detail(error.to_string())
    })?;
    file.flush()
        .map_err(|error| io_error("could not flush the annotation update", output, error))?;
    file.sync_all()
        .map_err(|error| io_error("could not fsync the annotation update", output, error))?;
    Ok(())
}

/// Reopen `path` and check that every direct-write annotation carries what this writer promised.
///
/// The annotation reader can see `/Name`, `/DA`, `/Q`, geometry and `/BS` through PDFium (or, for
/// `/Name`, not at all); the appearance dictionary is not exposed by its C ABI, so those parts are
/// checked with lopdf. This is part of the save's verification, not a test-only helper.
pub(crate) fn verify_direct_annotations(
    path: &Path,
    annotations: &[WriteAnnotation],
    password: Option<&str>,
) -> Result<()> {
    let direct: Vec<&WriteAnnotation> = annotations
        .iter()
        .filter(|annotation| annotation.kind.is_direct())
        .collect();
    if direct.is_empty() {
        return Ok(());
    }
    let options = LoadOptions {
        password: password.map(str::to_owned),
        ..LoadOptions::default()
    };
    let document = Document::load_with_options(path, options).map_err(|error| {
        lopdf_error(
            "could not reopen the saved file to verify appearances",
            error,
        )
    })?;
    let mut by_name = std::collections::HashMap::new();
    for (_, page_id) in document.get_pages() {
        let Ok(page) = document.get_dictionary(page_id) else {
            continue;
        };
        let Some(annots) = page
            .get(b"Annots")
            .ok()
            .and_then(|object| deref(&document, object))
            .and_then(|object| object.as_array().ok())
        else {
            continue;
        };
        for object in annots {
            let Some(dictionary) =
                deref(&document, object).and_then(|object| object.as_dict().ok())
            else {
                continue;
            };
            let Some(name) = dictionary
                .get(b"NM")
                .ok()
                .and_then(|object| deref(&document, object))
                .and_then(|object| object.as_str().ok())
                .map(|bytes| String::from_utf8_lossy(bytes).into_owned())
            else {
                continue;
            };
            by_name.insert(name, dictionary);
        }
    }

    for expected in direct {
        let Some(dictionary) = by_name.get(&expected.id) else {
            return Err(ArisError::new(
                ErrorCode::Internal,
                "a written annotation is missing from the saved file",
            )
            .with_detail(expected.id.clone()));
        };
        match expected.kind {
            WriteAnnotationKind::Text => {
                let icon = dictionary
                    .get(b"Name")
                    .ok()
                    .and_then(|object| deref(&document, object))
                    .and_then(|object| object.as_name().ok());
                if icon != Some(b"Comment".as_slice()) {
                    return Err(ArisError::new(
                        ErrorCode::Internal,
                        "a written sticky note has no /Name /Comment icon",
                    )
                    .with_detail(format!("{}: {icon:?}", expected.id)));
                }
            }
            WriteAnnotationKind::FreeText => {
                let da = dictionary
                    .get(b"DA")
                    .ok()
                    .and_then(|object| deref(&document, object))
                    .and_then(|object| object.as_str().ok())
                    .map(|bytes| String::from_utf8_lossy(bytes).into_owned());
                let Some(da) = da else {
                    return Err(ArisError::new(
                        ErrorCode::Internal,
                        "a written free-text annotation has no /DA",
                    )
                    .with_detail(expected.id.clone()));
                };
                if !da.contains("Tf") || !da.contains(&format!("{}", expected.font_size)) {
                    return Err(ArisError::new(
                        ErrorCode::Internal,
                        "a written free-text annotation's /DA does not state its font size",
                    )
                    .with_detail(format!("{}: {da:?}", expected.id)));
                }
                let quadding = dictionary
                    .get(b"Q")
                    .ok()
                    .and_then(|object| deref(&document, object))
                    .and_then(|object| object.as_i64().ok());
                let expected_quadding = match expected.alignment {
                    AnnotationAlignment::Left => 0,
                    AnnotationAlignment::Center => 1,
                    AnnotationAlignment::Right => 2,
                };
                if quadding != Some(expected_quadding) {
                    return Err(ArisError::new(
                        ErrorCode::Internal,
                        "a written free-text annotation's /Q does not match the request",
                    )
                    .with_detail(format!("{}: {quadding:?}", expected.id)));
                }
                verify_appearance(&document, dictionary, expected)?;
            }
            kind if kind.is_geometry() => {
                let border = dictionary
                    .get(b"BS")
                    .ok()
                    .and_then(|object| deref(&document, object))
                    .and_then(|object| object.as_dict().ok())
                    .and_then(|bs| {
                        bs.get(b"W")
                            .ok()
                            .and_then(|object| deref(&document, object))
                            .and_then(number)
                    });
                let Some(border) = border else {
                    return Err(ArisError::new(
                        ErrorCode::Internal,
                        "a written ink or shape annotation has no /BS width",
                    )
                    .with_detail(expected.id.clone()));
                };
                if (f64::from(border) - expected.border_width).abs() > 0.02 {
                    return Err(ArisError::new(
                        ErrorCode::Internal,
                        "a written ink or shape annotation's /BS width does not match the request",
                    )
                    .with_detail(format!(
                        "{}: {border} != {}",
                        expected.id, expected.border_width
                    )));
                }
                verify_appearance(&document, dictionary, expected)?;
            }
            _ => {
                return Err(ArisError::new(
                    ErrorCode::Internal,
                    "the verifier was given a kind the direct writer does not write",
                )
                .with_detail(format!("{}: {:?}", expected.id, expected.kind)));
            }
        }
    }
    Ok(())
}

/// Checks the form XObject every directly written kind except `/Text` carries.
fn verify_appearance(
    document: &Document,
    dictionary: &Dictionary,
    expected: &WriteAnnotation,
) -> Result<()> {
    let appearance = dictionary
        .get(b"AP")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_dict().ok())
        .and_then(|ap| ap.get(b"N").ok())
        .and_then(|object| deref(document, object));
    let Some(Object::Stream(stream)) = appearance else {
        return Err(ArisError::new(
            ErrorCode::Internal,
            "a written annotation has no /AP /N appearance stream",
        )
        .with_detail(expected.id.clone()));
    };
    if stream.content.is_empty() {
        return Err(ArisError::new(
            ErrorCode::Internal,
            "a written annotation has an empty appearance stream",
        )
        .with_detail(expected.id.clone()));
    }
    let bbox = stream
        .dict
        .get(b"BBox")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_array().ok())
        .and_then(|array| {
            let values: Option<Vec<f32>> = array
                .iter()
                .map(|object| deref(document, object).and_then(number))
                .collect();
            values.filter(|values| values.len() == 4)
        });
    let Some(bbox) = bbox else {
        return Err(ArisError::new(
            ErrorCode::Internal,
            "a written annotation's appearance has no /BBox",
        )
        .with_detail(expected.id.clone()));
    };
    let expected_box = [
        expected.rect.min_x() as f32,
        expected.rect.min_y() as f32,
        expected.rect.max_x() as f32,
        expected.rect.max_y() as f32,
    ];
    if bbox
        .iter()
        .zip(expected_box)
        .any(|(left, right)| (left - right).abs() > 0.05)
    {
        return Err(ArisError::new(
            ErrorCode::Internal,
            "a written annotation's appearance /BBox does not match its /Rect",
        )
        .with_detail(format!("{}: {bbox:?} != {expected_box:?}", expected.id)));
    }
    Ok(())
}

impl WriteAnnotationKind {
    pub(crate) fn is_geometry(self) -> bool {
        matches!(self, Self::Ink | Self::Square | Self::Circle | Self::Line)
    }
}

fn append_one(incremental: &mut IncrementalDocument, annotation: &WriteAnnotation) -> Result<()> {
    let page_id = {
        let pages = incremental.get_prev_documents().get_pages();
        *pages.get(&(annotation.page.get() + 1)).ok_or_else(|| {
            ArisError::new(
                ErrorCode::InvalidArgument,
                "the annotation's page is not in the document",
            )
            .with_detail(format!(
                "{}: page {}",
                annotation.id,
                annotation.page.get() + 1
            ))
        })?
    };

    // A `/Text` note's picture is its icon, which the viewer draws from `/Name`; every other
    // directly written kind carries a form XObject here. Free text's stream needs the font its
    // `/DA` names.
    let mut appearance_id = None;
    if annotation.kind != WriteAnnotationKind::Text {
        let mut resources = Dictionary::new();
        if annotation.kind == WriteAnnotationKind::FreeText {
            let mut font = Dictionary::new();
            font.set("Type", name("Font"));
            font.set("Subtype", name("Type1"));
            font.set("BaseFont", name("Helvetica"));
            font.set("Encoding", name("WinAnsiEncoding"));
            let mut fonts = Dictionary::new();
            fonts.set("Helv", Object::Dictionary(font));
            resources.set("Font", Object::Dictionary(fonts));
        }
        let mut stream_dictionary = Dictionary::new();
        stream_dictionary.set("Type", name("XObject"));
        stream_dictionary.set("Subtype", name("Form"));
        stream_dictionary.set("BBox", rect_array(annotation.rect));
        stream_dictionary.set("Resources", Object::Dictionary(resources));
        let mut stream = Stream::new(stream_dictionary, appearance_content(annotation));
        // Keep the content legible in the saved file; the whole document is already compressed
        // where its producer chose to compress it, and this stream is a few hundred bytes.
        stream.allows_compression = false;
        appearance_id = Some(add_object(
            &mut incremental.new_document,
            Object::Stream(stream),
        ));
    }

    let mut dictionary = Dictionary::new();
    dictionary.set("Type", name("Annot"));
    dictionary.set("Subtype", name(annotation.kind.pdf_name()));
    dictionary.set("Rect", rect_array(annotation.rect));
    dictionary.set("C", colour_array(annotation.color));
    dictionary.set("CA", Object::Real(annotation.opacity as f32));
    dictionary.set("F", Object::Integer(4));
    dictionary.set("NM", text_string(&annotation.id));
    if let Some(author) = annotation.author.as_deref() {
        dictionary.set("T", text_string(author));
    }
    if let Some(contents) = annotation.contents.as_deref() {
        dictionary.set("Contents", text_string(contents));
    }
    if let Some(modified) = annotation.modified.as_deref() {
        dictionary.set("M", text_string(modified));
    }
    dictionary.set("Subj", name(annotation.kind.subject()));
    if let Some(appearance_id) = appearance_id {
        let mut ap = Dictionary::new();
        ap.set("N", Object::Reference(appearance_id));
        dictionary.set("AP", Object::Dictionary(ap));
    }

    match annotation.kind {
        WriteAnnotationKind::Text => {
            // The icon name PDF 32000-1 table 182 defines. Every viewer with a note UI knows
            // `/Comment`; it is also the shape the reader draws for a `/Text` annotation, so the
            // page, the sidebar and Preview agree about what a note looks like.
            dictionary.set("Name", name("Comment"));
            dictionary.set("Open", Object::Boolean(false));
        }
        WriteAnnotationKind::FreeText => {
            // `/DA` is required on `/FreeText` and is where its font and size live; `/Q` is the
            // quadding. The same values are used by the appearance stream, so a viewer that
            // synthesises and a viewer that uses `/AP` show the same text.
            let [red, green, blue] = annotation.color;
            dictionary.set(
                "DA",
                text_string(&format!(
                    "/Helv {:.4} Tf {:.4} {:.4} {:.4} rg",
                    annotation.font_size,
                    f64::from(red) / 255.0,
                    f64::from(green) / 255.0,
                    f64::from(blue) / 255.0
                )),
            );
            dictionary.set("Q", Object::Integer(quadding(annotation.alignment)));
        }
        WriteAnnotationKind::Ink => {
            let strokes: Vec<Object> = annotation
                .ink_paths
                .iter()
                .map(|path| {
                    Object::Array(
                        path.iter()
                            .flat_map(|point| {
                                [Object::Real(point.x as f32), Object::Real(point.y as f32)]
                            })
                            .collect(),
                    )
                })
                .collect();
            dictionary.set("InkList", Object::Array(strokes));
        }
        WriteAnnotationKind::Line => {
            let Some(line) = annotation.line else {
                return Err(ArisError::new(
                    ErrorCode::InvalidArgument,
                    "a line annotation has no endpoints",
                )
                .with_detail(annotation.id.clone()));
            };
            dictionary.set("L", line_array(line.start, line.end));
            let ending = if annotation.line_arrow {
                name("ClosedArrow")
            } else {
                name("None")
            };
            dictionary.set("LE", Object::Array(vec![name("None"), ending]));
        }
        WriteAnnotationKind::Square | WriteAnnotationKind::Circle => {}
        WriteAnnotationKind::Highlight | WriteAnnotationKind::Underline => {
            return Err(ArisError::new(
                ErrorCode::InvalidArgument,
                "a quad-based annotation reached the direct writer",
            ));
        }
    }

    if annotation.kind.is_geometry() {
        let mut border = Dictionary::new();
        border.set("W", Object::Real(annotation.border_width as f32));
        border.set("S", name("S"));
        dictionary.set("BS", Object::Dictionary(border));
        // `/BS` is the modern key and the one this writer promises. `/Border` is the legacy
        // three-number array; some readers (and PDFium's own `FPDFAnnot_GetBorder`) only look at
        // it, so the same width is stated in both. The spec says `/BS` supersedes `/Border` when
        // both are present, so the two cannot disagree in a viewer that understands `/BS`.
        dictionary.set(
            "Border",
            Object::Array(vec![
                Object::Integer(0),
                Object::Integer(0),
                Object::Real(annotation.border_width as f32),
            ]),
        );
    } else {
        // A zero-width border: the annotation is a text object, not a frame around one.
        dictionary.set(
            "Border",
            Object::Array(vec![
                Object::Integer(0),
                Object::Integer(0),
                Object::Integer(0),
            ]),
        );
    }

    let annotation_id = add_object(
        &mut incremental.new_document,
        Object::Dictionary(dictionary),
    );

    let annots = annots_array(incremental, page_id)?;
    annots.push(Object::Reference(annotation_id));
    Ok(())
}

/// The page's `/Annots`, cloned into the new revision and ready to append to.
fn annots_array(
    incremental: &mut IncrementalDocument,
    page_id: ObjectId,
) -> Result<&mut Vec<Object>> {
    incremental
        .opt_clone_object_to_new_document(page_id)
        .map_err(|error| lopdf_error("could not copy the page into the new revision", error))?;
    let existing = incremental
        .new_document
        .get_dictionary(page_id)
        .map_err(|error| lopdf_error("the page object is not a dictionary", error))?
        .get(b"Annots")
        .ok()
        .cloned();
    match existing {
        Some(Object::Reference(array_id)) => {
            incremental
                .opt_clone_object_to_new_document(array_id)
                .map_err(|error| lopdf_error("could not copy the /Annots array", error))?;
            incremental
                .new_document
                .get_object_mut(array_id)
                .map_err(|error| lopdf_error("the /Annots object is missing", error))?
                .as_array_mut()
                .map_err(|error| lopdf_error("/Annots is not an array", error))
        }
        Some(Object::Array(_)) => incremental
            .new_document
            .get_dictionary_mut(page_id)
            .map_err(|error| lopdf_error("the page object is not a dictionary", error))?
            .get_mut(b"Annots")
            .map_err(|error| lopdf_error("the page has no /Annots array", error))?
            .as_array_mut()
            .map_err(|error| lopdf_error("/Annots is not an array", error)),
        Some(other) => Err(ArisError::new(
            ErrorCode::InvalidArgument,
            "the page's /Annots is not an array or a reference to one",
        )
        .with_detail(format!("{other:?}"))),
        None => {
            let page = incremental
                .new_document
                .get_dictionary_mut(page_id)
                .map_err(|error| lopdf_error("the page object is not a dictionary", error))?;
            page.set("Annots", Object::Array(Vec::new()));
            page.get_mut(b"Annots")
                .map_err(|error| lopdf_error("the new /Annots entry vanished", error))?
                .as_array_mut()
                .map_err(|error| lopdf_error("the new /Annots entry is not an array", error))
        }
    }
}

fn add_object(document: &mut Document, object: Object) -> ObjectId {
    let id = (document.max_id + 1, 0);
    document.max_id = id.0;
    document.objects.insert(id, object);
    id
}

fn appearance_content(annotation: &WriteAnnotation) -> Vec<u8> {
    if annotation.kind == WriteAnnotationKind::FreeText {
        return free_text_appearance(annotation);
    }
    let [red, green, blue] = annotation.color;
    let width = annotation.border_width.max(0.1);
    let mut content = format!(
        "q {:.4} {:.4} {:.4} RG {:.4} {:.4} {:.4} rg {:.3} w 1 J 1 j\n",
        f64::from(red) / 255.0,
        f64::from(green) / 255.0,
        f64::from(blue) / 255.0,
        f64::from(red) / 255.0,
        f64::from(green) / 255.0,
        f64::from(blue) / 255.0,
        width
    );
    match annotation.kind {
        WriteAnnotationKind::Ink => {
            for path in &annotation.ink_paths {
                let Some(first) = path.first() else { continue };
                content.push_str(&format!("{:.3} {:.3} m\n", first.x, first.y));
                for point in &path[1..] {
                    content.push_str(&format!("{:.3} {:.3} l\n", point.x, point.y));
                }
                content.push_str("S\n");
            }
        }
        WriteAnnotationKind::Square => {
            let inset = width / 2.0;
            let x = annotation.rect.min_x() + inset;
            let y = annotation.rect.min_y() + inset;
            let width = (annotation.rect.size.width - width).max(0.01);
            let height = (annotation.rect.size.height - width).max(0.01);
            content.push_str(&format!("{x:.3} {y:.3} {width:.3} {height:.3} re S\n"));
        }
        WriteAnnotationKind::Circle => {
            let inset = width / 2.0;
            let x = annotation.rect.min_x() + inset;
            let y = annotation.rect.min_y() + inset;
            let w = (annotation.rect.size.width - width).max(0.01);
            let h = (annotation.rect.size.height - width).max(0.01);
            content.push_str(&ellipse_path(x, y, w, h));
            content.push_str("S\n");
        }
        WriteAnnotationKind::Line => {
            if let Some(line) = annotation.line {
                content.push_str(&format!(
                    "{:.3} {:.3} m {:.3} {:.3} l S\n",
                    line.start.x, line.start.y, line.end.x, line.end.y
                ));
                if annotation.line_arrow {
                    content.push_str(&arrow_head(line.start, line.end, width));
                }
            }
        }
        WriteAnnotationKind::Highlight
        | WriteAnnotationKind::Underline
        | WriteAnnotationKind::Text => {}
        WriteAnnotationKind::FreeText => unreachable!("handled at the top of this function"),
    }
    content.push_str("Q\n");
    content.into_bytes()
}

/// The appearance of a `/FreeText` annotation: the text laid out at the `/DA` size in Helvetica,
/// wrapped to the box and aligned by `/Q`.
///
/// The stream is a picture of the same text `/Contents` carries. It is deliberately not generated
/// from the file's own text layout: a free-text annotation owns its rectangle, and the reader
/// already measures the text with CoreText for the canvas. This one only has to agree with itself.
fn free_text_appearance(annotation: &WriteAnnotation) -> Vec<u8> {
    let [red, green, blue] = annotation.color;
    let size = annotation.font_size.max(1.0);
    let padding = (size * 0.15).clamp(1.0, 6.0);
    let max_width = (annotation.rect.size.width - 2.0 * padding).max(1.0);
    let text = annotation.contents.as_deref().unwrap_or("");
    let lines = wrap_free_text(text, size, max_width);
    let leading = size * 1.2;
    let mut content = String::from("q\n");
    content.push_str(&format!(
        "{:.3} {:.3} {:.3} {:.3} re W n\n",
        annotation.rect.min_x(),
        annotation.rect.min_y(),
        annotation.rect.size.width.max(0.01),
        annotation.rect.size.height.max(0.01)
    ));
    content.push_str("BT\n");
    content.push_str(&format!(
        "/Helv {:.4} Tf\n{:.4} {:.4} {:.4} rg\n{:.4} TL\n",
        size,
        f64::from(red) / 255.0,
        f64::from(green) / 255.0,
        f64::from(blue) / 255.0,
        leading
    ));
    let mut baseline = annotation.rect.max_y() - padding - size;
    for line in lines {
        let width = text_width(&line, size);
        let x = match annotation.alignment {
            AnnotationAlignment::Left => annotation.rect.min_x() + padding,
            AnnotationAlignment::Center => {
                annotation.rect.min_x() + (annotation.rect.size.width - width) / 2.0
            }
            AnnotationAlignment::Right => annotation.rect.max_x() - padding - width,
        };
        if baseline + size < annotation.rect.min_y() {
            break;
        }
        content.push_str(&format!(
            "1 0 0 1 {:.3} {:.3} Tm\n{} Tj\n",
            x,
            baseline,
            pdf_literal_string(&line)
        ));
        baseline -= leading;
    }
    content.push_str("ET\nQ\n");
    content.into_bytes()
}

/// Greedy word wrap for the appearance stream, at Helvetica's width for `size`.
fn wrap_free_text(text: &str, size: f64, max_width: f64) -> Vec<String> {
    let mut lines = Vec::new();
    for paragraph in text.split('\n') {
        let mut line = String::new();
        for word in paragraph.split_whitespace() {
            let candidate = if line.is_empty() {
                word.to_string()
            } else {
                format!("{line} {word}")
            };
            if text_width(&candidate, size) <= max_width || line.is_empty() {
                line = candidate;
            } else {
                lines.push(std::mem::take(&mut line));
                line = word.to_string();
            }
        }
        lines.push(line);
    }
    if lines.is_empty() {
        lines.push(String::new());
    }
    lines
}

/// Width of `text` in Helvetica points, from the standard font's advance widths.
fn text_width(text: &str, size: f64) -> f64 {
    text.chars().map(helvetica_width).sum::<f64>() * size / 1000.0
}

/// Helvetica advance widths (1/1000 em) for the printable ASCII range. Characters outside it
/// use a middle-of-the-road 556, which is only a wrapping estimate; the text itself is WinAnsi.
fn helvetica_width(character: char) -> f64 {
    match character {
        ' ' => 278.0,
        '!' => 278.0,
        '"' => 355.0,
        '#' => 556.0,
        '$' => 556.0,
        '%' => 889.0,
        '&' => 667.0,
        '\'' => 191.0,
        '(' | ')' => 333.0,
        '*' => 389.0,
        '+' => 584.0,
        ',' => 278.0,
        '-' => 333.0,
        '.' => 278.0,
        '/' => 278.0,
        '0'..='9' => 556.0,
        ':' | ';' => 278.0,
        '<' | '=' | '>' => 584.0,
        '?' => 556.0,
        '@' => 1015.0,
        'A' => 667.0,
        'B' => 667.0,
        'C' => 722.0,
        'D' => 722.0,
        'E' => 667.0,
        'F' => 611.0,
        'G' => 778.0,
        'H' => 722.0,
        'I' => 278.0,
        'J' => 500.0,
        'K' => 667.0,
        'L' => 556.0,
        'M' => 833.0,
        'N' => 722.0,
        'O' => 778.0,
        'P' => 667.0,
        'Q' => 778.0,
        'R' => 722.0,
        'S' => 667.0,
        'T' => 611.0,
        'U' => 722.0,
        'V' => 667.0,
        'W' => 944.0,
        'X' => 667.0,
        'Y' => 667.0,
        'Z' => 611.0,
        '[' | ']' | '\\' => 278.0,
        '^' => 469.0,
        '_' => 556.0,
        '`' => 333.0,
        'a' => 556.0,
        'b' => 556.0,
        'c' => 500.0,
        'd' => 556.0,
        'e' => 556.0,
        'f' => 278.0,
        'g' => 556.0,
        'h' => 556.0,
        'i' | 'j' | 'l' => 222.0,
        'k' => 500.0,
        'm' => 833.0,
        'n' => 556.0,
        'o' => 556.0,
        'p' => 556.0,
        'q' => 556.0,
        'r' => 333.0,
        's' => 500.0,
        't' => 278.0,
        'u' => 556.0,
        'v' => 500.0,
        'w' => 722.0,
        'x' => 500.0,
        'y' => 500.0,
        'z' => 500.0,
        '{' | '}' => 334.0,
        '|' => 260.0,
        '~' => 584.0,
        _ => 556.0,
    }
}

/// A PDF literal string in WinAnsi: `\`, `(` and `)` escaped, bytes outside WinAnsi written as
/// `?`. The full text remains in `/Contents`; this is only the appearance stream's copy.
fn pdf_literal_string(text: &str) -> String {
    let mut escaped = String::with_capacity(text.len() + 2);
    escaped.push('(');
    for character in text.chars() {
        let byte = win_ansi_byte(character).unwrap_or(b'?');
        match byte {
            b'\\' | b'(' | b')' => {
                escaped.push('\\');
                escaped.push(char::from(byte));
            }
            b'\n' => escaped.push_str("\\n"),
            b'\r' => escaped.push_str("\\r"),
            b'\t' => escaped.push_str("\\t"),
            0x20..=0x7E => escaped.push(char::from(byte)),
            _ => escaped.push_str(&format!("\\{:03o}", byte)),
        }
    }
    escaped.push(')');
    escaped
}

/// One character in WinAnsiEncoding (cp1252 minus the five undefined bytes). The common Latin-1
/// range and the typographic punctuation Windows writes are mapped; anything else has no byte.
fn win_ansi_byte(character: char) -> Option<u8> {
    match character {
        '\u{20AC}' => Some(0x80),
        '\u{201A}' => Some(0x82),
        '\u{0192}' => Some(0x83),
        '\u{201E}' => Some(0x84),
        '\u{2026}' => Some(0x85),
        '\u{2020}' => Some(0x86),
        '\u{2021}' => Some(0x87),
        '\u{02C6}' => Some(0x88),
        '\u{2030}' => Some(0x89),
        '\u{0160}' => Some(0x8A),
        '\u{2039}' => Some(0x8B),
        '\u{0152}' => Some(0x8C),
        '\u{017D}' => Some(0x8E),
        '\u{2018}' => Some(0x91),
        '\u{2019}' => Some(0x92),
        '\u{201C}' => Some(0x93),
        '\u{201D}' => Some(0x94),
        '\u{2022}' => Some(0x95),
        '\u{2013}' => Some(0x96),
        '\u{2014}' => Some(0x97),
        '\u{02DC}' => Some(0x98),
        '\u{2122}' => Some(0x99),
        '\u{0161}' => Some(0x9A),
        '\u{203A}' => Some(0x9B),
        '\u{0153}' => Some(0x9C),
        '\u{017E}' => Some(0x9E),
        '\u{0178}' => Some(0x9F),
        character if (character as u32) <= 0xFF && character != '\u{7F}' => Some(character as u8),
        _ => None,
    }
}

fn quadding(alignment: AnnotationAlignment) -> i64 {
    match alignment {
        AnnotationAlignment::Left => 0,
        AnnotationAlignment::Center => 1,
        AnnotationAlignment::Right => 2,
    }
}

/// Four cubic Bézier curves, the standard circle approximation (`k = 0.5522848`).
fn ellipse_path(x: f64, y: f64, width: f64, height: f64) -> String {
    let (cx, cy) = (x + width / 2.0, y + height / 2.0);
    let (rx, ry) = (width / 2.0, height / 2.0);
    let kx = rx * 0.552_284_8;
    let ky = ry * 0.552_284_8;
    format!(
        "{:.3} {:.3} m {:.3} {:.3} {:.3} {:.3} {:.3} {:.3} c \
         {:.3} {:.3} {:.3} {:.3} {:.3} {:.3} c \
         {:.3} {:.3} {:.3} {:.3} {:.3} {:.3} c \
         {:.3} {:.3} {:.3} {:.3} {:.3} {:.3} c h\n",
        cx + rx,
        cy,
        cx + rx,
        cy + ky,
        cx + kx,
        cy + ry,
        cx,
        cy + ry,
        cx - kx,
        cy + ry,
        cx - rx,
        cy + ky,
        cx - rx,
        cy,
        cx - rx,
        cy - ky,
        cx - kx,
        cy - ry,
        cx,
        cy - ry,
        cx + kx,
        cy - ry,
        cx + rx,
        cy - ky,
        cx + rx,
        cy,
    )
}

fn arrow_head(start: Point, end: Point, width: f64) -> String {
    let dx = end.x - start.x;
    let dy = end.y - start.y;
    let length = (dx * dx + dy * dy).sqrt();
    if length < 1e-6 {
        return String::new();
    }
    let (ux, uy) = (dx / length, dy / length);
    let arrow = (width * 5.0).max(8.0);
    let half = (width * 1.8).max(3.0);
    let base = (end.x - ux * arrow, end.y - uy * arrow);
    let left = (base.0 - uy * half, base.1 + ux * half);
    let right = (base.0 + uy * half, base.1 - ux * half);
    format!(
        "{:.3} {:.3} m {:.3} {:.3} l {:.3} {:.3} l {:.3} {:.3} l f\n",
        end.x, end.y, left.0, left.1, right.0, right.1, end.x, end.y
    )
}

fn rect_array(rect: Rect) -> Object {
    Object::Array(vec![
        Object::Real(rect.min_x() as f32),
        Object::Real(rect.min_y() as f32),
        Object::Real(rect.max_x() as f32),
        Object::Real(rect.max_y() as f32),
    ])
}

fn colour_array(color: [u8; 3]) -> Object {
    Object::Array(
        color
            .into_iter()
            .map(|channel| Object::Real(f32::from(channel) / 255.0))
            .collect(),
    )
}

fn line_array(start: Point, end: Point) -> Object {
    Object::Array(vec![
        Object::Real(start.x as f32),
        Object::Real(start.y as f32),
        Object::Real(end.x as f32),
        Object::Real(end.y as f32),
    ])
}

fn name(value: &str) -> Object {
    Object::Name(value.as_bytes().to_vec())
}

fn text_string(value: &str) -> Object {
    if value.is_ascii() {
        Object::String(value.as_bytes().to_vec(), StringFormat::Literal)
    } else {
        let mut bytes = Vec::with_capacity(2 + value.len() * 2);
        bytes.extend_from_slice(&[0xFE, 0xFF]);
        for unit in value.encode_utf16() {
            bytes.extend_from_slice(&unit.to_be_bytes());
        }
        Object::String(bytes, StringFormat::Literal)
    }
}

fn deref<'a>(document: &'a Document, object: &'a Object) -> Option<&'a Object> {
    document.dereference(object).ok().map(|(_, object)| object)
}

fn number(object: &Object) -> Option<f32> {
    match object {
        Object::Integer(value) => Some(*value as f32),
        Object::Real(value) if value.is_finite() => Some(*value),
        _ => None,
    }
}

fn load_document(path: &Path, password: Option<&str>) -> Result<Document> {
    let options = LoadOptions {
        password: password.map(str::to_owned),
        ..LoadOptions::default()
    };
    Document::load_with_options(path, options)
        .map_err(|error| lopdf_error("could not read the document for the stroked writer", error))
}

fn lopdf_error(action: &str, error: lopdf::Error) -> ArisError {
    ArisError::new(ErrorCode::Io, action).with_detail(error.to_string())
}

fn io_error(action: &str, path: &Path, error: std::io::Error) -> ArisError {
    ArisError::new(ErrorCode::Io, action).with_detail(format!("{}: {error}", path.display()))
}
