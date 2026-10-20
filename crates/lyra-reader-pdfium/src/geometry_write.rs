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
//! appearance stream that lays the exact text out in an embedded font at the requested size. The
//! font is a Type0/Identity-H CID font (`LyraReader Sans SC`, a Noto Sans SC subset) embedded once per
//! document with `FontFile2`, `CIDToGIDMap`, `/W` widths and a `/ToUnicode` CMap; only the glyphs
//! the document's text boxes use are included. A Chinese, Japanese, Greek or maths character is
//! therefore a real glyph in the appearance, not `?`, and extracting the appearance returns the
//! original string. `/DA` keeps Helvetica as the standard-14 fallback for a viewer that ignores
//! `/AP`; the appearance itself never uses it.
//!
//! A character outside the shipped font is encoded through `.notdef` with its own CID and its
//! exact Unicode in `/ToUnicode`. It paints as a visible missing-glyph box (never `?`), the
//! editor warns while typing, and `/Contents` stays exact. See [`crate::appearance_font`].
//!
//! A `/Text` sticky note deliberately has **no** appearance stream: the shape a viewer draws for
//! it is its own icon, selected by `/Name`, and the body lives in `/Contents` in the viewer's
//! note window. Writing an icon bitmap here would be a second, competing picture of the same
//! annotation.
//!
//! The stream's `/BBox` is the annotation's `/Rect`, with an identity `/Matrix`, so the content
//! is written in the page coordinates the rest of this crate uses.

use crate::annotations::{WriteAnnotation, WriteAnnotationKind};
use crate::appearance_font::{self, AppearanceSubset};
use flate2::Compression;
use flate2::write::ZlibEncoder;
use lopdf::{
    Dictionary, Document, IncrementalDocument, LoadOptions, Object, ObjectId, Stream, StringFormat,
};
use lyra_reader_core::{AnnotationAlignment, ErrorCode, LyraReaderError, Point, Rect, Result};
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

    // One font resource per document, not one per text box: every `/FreeText` appearance in this
    // save points at the same Type0 font object. The subset covers every character used by every
    // text box in this document, and nothing else.
    let free_text_font = build_free_text_font(&mut incremental.new_document, annotations)?;

    for annotation in annotations {
        if !annotation.kind.is_direct() {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "the direct writer was given a quad-based annotation",
            )
            .with_detail(format!("{}: {:?}", annotation.id, annotation.kind)));
        }
        append_one(&mut incremental, annotation, free_text_font.as_ref())?;
    }

    let mut file = File::create(output).map_err(|error| {
        io_error(
            "could not create the file for the annotation update",
            output,
            error,
        )
    })?;
    incremental.save_to(&mut file).map_err(|error| {
        LyraReaderError::new(ErrorCode::Io, "could not write the annotation update")
            .with_detail(error.to_string())
    })?;
    file.flush()
        .map_err(|error| io_error("could not flush the annotation update", output, error))?;
    file.sync_all()
        .map_err(|error| io_error("could not fsync the annotation update", output, error))?;
    Ok(())
}

/// One document's embedded appearance font. Every `/FreeText` appearance in the save points at
/// this single Type0 font object; form-field appearances use it the same way.
pub(crate) struct EmbeddedFreeTextFont {
    pub(crate) type0: ObjectId,
    pub(crate) subset: AppearanceSubset,
}

/// Builds the shared free-text font, or `None` when the save contains no visible text at all.
pub(crate) fn build_free_text_font(
    document: &mut Document,
    annotations: &[WriteAnnotation],
) -> Result<Option<EmbeddedFreeTextFont>> {
    let texts: Vec<&str> = annotations
        .iter()
        .filter(|annotation| {
            matches!(
                annotation.kind,
                WriteAnnotationKind::FreeText | WriteAnnotationKind::Stamp
            )
        })
        .filter_map(|annotation| annotation.contents.as_deref())
        .collect();
    build_appearance_font(document, &texts)
}

/// Builds one embedded Type0 font for every visible string the save needs to paint.
///
/// The annotation writer and the form writer call this with their own texts; the font object is
/// appended to `document` once, and every appearance stream points at it. The characters are
/// subset by [`AppearanceSubset`], and a character outside the shipped font keeps an exact
/// ToUnicode entry and paints as `.notdef` rather than as `?`.
pub(crate) fn build_appearance_font(
    document: &mut Document,
    texts: &[&str],
) -> Result<Option<EmbeddedFreeTextFont>> {
    let has_visible_text = texts.iter().any(|text| {
        text.chars()
            .any(|character| !appearance_font::is_layout_control(character))
    });
    if !has_visible_text {
        return Ok(None);
    }
    let subset = AppearanceSubset::build(texts)?;
    debug_assert!(
        subset.glyph_count() >= 1,
        "a font subset has at least .notdef"
    );
    if !subset.missing().is_empty() {
        // The editor warns while typing (appearance_coverage); the writer's fallback is the
        // .notdef glyph plus an exact ToUnicode entry. This stderr line makes the same fact
        // visible in the annotation instrumentation log the shell already writes.
        eprintln!(
            "lyra-reader-annotate: {} character(s) in this document's text are outside the bundled font; \
             the appearance uses .notdef and keeps the exact text in /Contents or /V",
            subset.missing().len()
        );
    }
    let type0 = add_free_text_font_objects(document, &subset)?;
    Ok(Some(EmbeddedFreeTextFont { type0, subset }))
}

/// Writes the Type0 → CIDFontType2 → FontDescriptor → FontFile2 graph.
///
/// The embedded program is `subsetter`'s output: `.notdef` plus only the glyphs the appearance
/// uses, with glyph IDs renumbered. `CIDToGIDMap` is explicit (two bytes per CID) rather than
/// `/Identity` so a `.notdef` fallback can share glyph 0 while keeping its own CID and ToUnicode
/// entry.
fn add_free_text_font_objects(
    document: &mut Document,
    subset: &AppearanceSubset,
) -> Result<ObjectId> {
    let mut font_file = Dictionary::new();
    font_file.set("Length1", Object::Integer(subset.font_file().len() as i64));
    let font_file_id = add_stream(document, font_file, subset.font_file().to_vec(), true)?;

    let cid_to_gid_id = add_stream(document, Dictionary::new(), subset.cid_to_gid_map(), false)?;
    let to_unicode_id = add_stream(document, Dictionary::new(), subset.to_unicode_cmap(), false)?;

    let metrics = embedded_font_metrics(subset)?;
    let mut descriptor = Dictionary::new();
    descriptor.set("Type", name("FontDescriptor"));
    descriptor.set("FontName", name(appearance_font::POSTSCRIPT_NAME));
    // Bit 3 (value 4): symbolic. A CID-keyed font's glyphs are addressed by CID, not by a
    // character encoding, so the font program is not expected to carry a Unicode cmap.
    descriptor.set("Flags", Object::Integer(4));
    descriptor.set(
        "FontBBox",
        Object::Array(
            metrics
                .bbox
                .iter()
                .map(|value| Object::Integer(*value))
                .collect(),
        ),
    );
    descriptor.set("ItalicAngle", Object::Integer(0));
    descriptor.set("Ascent", Object::Integer(metrics.ascent));
    descriptor.set("Descent", Object::Integer(metrics.descent));
    descriptor.set("CapHeight", Object::Integer(metrics.cap_height));
    descriptor.set("StemV", Object::Integer(80));
    descriptor.set("FontFile2", Object::Reference(font_file_id));
    let descriptor_id = add_object(document, Object::Dictionary(descriptor));

    let mut cid_system = Dictionary::new();
    cid_system.set(
        "Registry",
        Object::String(b"Adobe".to_vec(), StringFormat::Literal),
    );
    cid_system.set(
        "Ordering",
        Object::String(b"Identity".to_vec(), StringFormat::Literal),
    );
    cid_system.set("Supplement", Object::Integer(0));

    let mut cid_font = Dictionary::new();
    cid_font.set("Type", name("Font"));
    cid_font.set("Subtype", name("CIDFontType2"));
    cid_font.set("BaseFont", name(appearance_font::POSTSCRIPT_NAME));
    cid_font.set("CIDSystemInfo", Object::Dictionary(cid_system));
    cid_font.set("FontDescriptor", Object::Reference(descriptor_id));
    cid_font.set("DW", Object::Integer(1000));
    cid_font.set("W", width_array(&subset.width_groups()));
    cid_font.set("CIDToGIDMap", Object::Reference(cid_to_gid_id));
    let cid_font_id = add_object(document, Object::Dictionary(cid_font));

    let mut type0 = Dictionary::new();
    type0.set("Type", name("Font"));
    type0.set("Subtype", name("Type0"));
    type0.set("BaseFont", name(appearance_font::POSTSCRIPT_NAME));
    type0.set("Encoding", name("Identity-H"));
    type0.set(
        "DescendantFonts",
        Object::Array(vec![Object::Reference(cid_font_id)]),
    );
    type0.set("ToUnicode", Object::Reference(to_unicode_id));
    Ok(add_object(document, Object::Dictionary(type0)))
}

struct EmbeddedFontMetrics {
    bbox: [i64; 4],
    ascent: i64,
    descent: i64,
    cap_height: i64,
}

fn embedded_font_metrics(subset: &AppearanceSubset) -> Result<EmbeddedFontMetrics> {
    let face = ttf_parser::Face::parse(subset.font_file(), 0).map_err(|error| {
        LyraReaderError::new(
            ErrorCode::Internal,
            "the subset appearance font could not be parsed back for its metrics",
        )
        .with_detail(format!("{error:?}"))
    })?;
    let units_per_em = f64::from(face.units_per_em().max(1));
    let scale = |value: i32| -> i64 { (f64::from(value) * 1000.0 / units_per_em).round() as i64 };
    let bbox = face.global_bounding_box();
    let ascent = scale(i32::from(face.ascender()));
    let descent = scale(i32::from(face.descender()));
    let cap_height = (ascent as f64 * 0.7).round() as i64;
    Ok(EmbeddedFontMetrics {
        bbox: [
            scale(i32::from(bbox.x_min)),
            scale(i32::from(bbox.y_min)),
            scale(i32::from(bbox.x_max)),
            scale(i32::from(bbox.y_max)),
        ],
        ascent,
        descent,
        cap_height,
    })
}

fn add_stream(
    document: &mut Document,
    mut dictionary: Dictionary,
    data: Vec<u8>,
    compress: bool,
) -> Result<ObjectId> {
    let data = if compress {
        let mut encoder = ZlibEncoder::new(Vec::new(), Compression::default());
        encoder.write_all(&data).map_err(|error| {
            LyraReaderError::new(
                ErrorCode::Internal,
                "could not compress the appearance font",
            )
            .with_detail(error.to_string())
        })?;
        let compressed = encoder.finish().map_err(|error| {
            LyraReaderError::new(
                ErrorCode::Internal,
                "could not finish compressing the appearance font",
            )
            .with_detail(error.to_string())
        })?;
        dictionary.set("Filter", name("FlateDecode"));
        compressed
    } else {
        data
    };
    let mut stream = Stream::new(dictionary, data);
    // The font program was compressed above. ToUnicode and CIDToGIDMap are tiny and stay
    // readable in the incremental update.
    stream.allows_compression = false;
    Ok(add_object(document, Object::Stream(stream)))
}

fn width_array(groups: &[(u16, Vec<u16>)]) -> Object {
    let mut array = Vec::with_capacity(groups.len() * 2);
    for (first, widths) in groups {
        array.push(Object::Integer(i64::from(*first)));
        array.push(Object::Array(
            widths
                .iter()
                .map(|width| Object::Integer(i64::from(*width)))
                .collect(),
        ));
    }
    Object::Array(array)
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
            return Err(LyraReaderError::new(
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
                    return Err(LyraReaderError::new(
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
                    return Err(LyraReaderError::new(
                        ErrorCode::Internal,
                        "a written free-text annotation has no /DA",
                    )
                    .with_detail(expected.id.clone()));
                };
                if !da.contains("Tf") || !da.contains(&format!("{}", expected.font_size)) {
                    return Err(LyraReaderError::new(
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
                    return Err(LyraReaderError::new(
                        ErrorCode::Internal,
                        "a written free-text annotation's /Q does not match the request",
                    )
                    .with_detail(format!("{}: {quadding:?}", expected.id)));
                }
                verify_appearance(&document, dictionary, expected)?;
                verify_embedded_appearance_font(&document, dictionary, expected)?;
            }
            WriteAnnotationKind::Stamp | WriteAnnotationKind::Signature => {
                let subtype = dictionary
                    .get(b"Subtype")
                    .ok()
                    .and_then(|object| deref(&document, object))
                    .and_then(|object| object.as_name().ok());
                if subtype != Some(b"Stamp".as_slice()) {
                    return Err(LyraReaderError::new(
                        ErrorCode::Internal,
                        "a written stamp does not have /Subtype /Stamp",
                    )
                    .with_detail(format!("{}: {subtype:?}", expected.id)));
                }
                verify_stamp_key(&document, dictionary, expected)?;
                verify_stamp_name(&document, dictionary, expected)?;
                verify_appearance(&document, dictionary, expected)?;
                let Some(stream) = appearance_of(&document, dictionary) else {
                    return Err(LyraReaderError::new(
                        ErrorCode::Internal,
                        "a written stamp has no appearance stream to check",
                    )
                    .with_detail(expected.id.clone()));
                };
                let content = String::from_utf8_lossy(&stream.content);
                match expected.kind {
                    WriteAnnotationKind::Stamp => {
                        if !content.contains(" Tj") || !content.contains(" re S") {
                            return Err(LyraReaderError::new(
                                ErrorCode::Internal,
                                "a written text stamp's appearance has no text or border",
                            )
                            .with_detail(expected.id.clone()));
                        }
                        verify_embedded_appearance_font(&document, dictionary, expected)?;
                    }
                    WriteAnnotationKind::Signature => {
                        if !content.contains("/Im0 Do") {
                            return Err(LyraReaderError::new(
                                ErrorCode::Internal,
                                "a written image signature's appearance does not paint its image",
                            )
                            .with_detail(expected.id.clone()));
                        }
                        verify_stamp_image(&document, stream, expected)?;
                    }
                    _ => unreachable!("this arm only handles stamps"),
                }
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
                    return Err(LyraReaderError::new(
                        ErrorCode::Internal,
                        "a written ink or shape annotation has no /BS width",
                    )
                    .with_detail(expected.id.clone()));
                };
                if (f64::from(border) - expected.border_width).abs() > 0.02 {
                    return Err(LyraReaderError::new(
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
                return Err(LyraReaderError::new(
                    ErrorCode::Internal,
                    "the verifier was given a kind the direct writer does not write",
                )
                .with_detail(format!("{}: {:?}", expected.id, expected.kind)));
            }
        }
    }
    Ok(())
}

/// The form XObject `/AP /N` points at, when it is a stream (our writer always writes one).
fn appearance_of<'a>(document: &'a Document, dictionary: &'a Dictionary) -> Option<&'a Stream> {
    match dictionary
        .get(b"AP")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_dict().ok())
        .and_then(|ap| ap.get(b"N").ok())
        .and_then(|object| deref(document, object))
    {
        Some(Object::Stream(stream)) => Some(stream),
        _ => None,
    }
}

/// The private `/LyraReaderStamp` dictionary: the exact words and style this reader wrote.
fn verify_stamp_key(
    document: &Document,
    dictionary: &Dictionary,
    expected: &WriteAnnotation,
) -> Result<()> {
    let key = dictionary
        .get(b"LyraReaderStamp")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_dict().ok())
        .ok_or_else(|| {
            LyraReaderError::new(
                ErrorCode::Internal,
                "a written stamp has no /LyraReaderStamp key",
            )
            .with_detail(expected.id.clone())
        })?;
    let text = key
        .get(b"Text")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_str().ok())
        .map(|bytes| String::from_utf8_lossy(bytes).into_owned())
        .unwrap_or_default();
    let expected_text = expected.contents.clone().unwrap_or_default();
    if text != expected_text {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "a written stamp's private text does not match the request",
        )
        .with_detail(format!("{}: {text:?} != {expected_text:?}", expected.id)));
    }
    let style = key
        .get(b"Style")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_name().ok())
        .map(|name| String::from_utf8_lossy(name).into_owned())
        .unwrap_or_default();
    let expected_style = if expected.kind == WriteAnnotationKind::Signature {
        "signature".to_string()
    } else {
        expected
            .stamp_style
            .clone()
            .unwrap_or_else(|| "custom".to_string())
    };
    if style != expected_style {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "a written stamp's private style does not match the request",
        )
        .with_detail(format!("{}: {style:?} != {expected_style:?}", expected.id)));
    }
    Ok(())
}

/// The standard `/Name` that makes a viewer without `/AP` draw the right icon.
fn verify_stamp_name(
    document: &Document,
    dictionary: &Dictionary,
    expected: &WriteAnnotation,
) -> Result<()> {
    let name = dictionary
        .get(b"Name")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_name().ok())
        .map(|name| String::from_utf8_lossy(name).into_owned())
        .unwrap_or_default();
    if name != stamp_icon_name(expected) {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "a written stamp's /Name does not match its style",
        )
        .with_detail(format!("{}: {name:?}", expected.id)));
    }
    Ok(())
}

/// The image XObject a signature's appearance points at: its dimensions, and the `/SMask` that
/// carries the PNG's transparency.
fn verify_stamp_image(
    document: &Document,
    appearance: &Stream,
    expected: &WriteAnnotation,
) -> Result<()> {
    let Some(image) = &expected.stamp_image else {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "a written signature has no image in the request",
        )
        .with_detail(expected.id.clone()));
    };
    let xobject = appearance
        .dict
        .get(b"Resources")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_dict().ok())
        .and_then(|resources| resources.get(b"XObject").ok())
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_dict().ok())
        .and_then(|xobjects| xobjects.get(b"Im0").ok())
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_stream().ok());
    let Some(xobject) = xobject else {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "a written signature's appearance has no /Im0 image XObject",
        )
        .with_detail(expected.id.clone()));
    };
    let width = xobject
        .dict
        .get(b"Width")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_i64().ok());
    let height = xobject
        .dict
        .get(b"Height")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_i64().ok());
    if width != Some(i64::from(image.width)) || height != Some(i64::from(image.height)) {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "a written signature's image dimensions do not match the request",
        )
        .with_detail(format!(
            "{}: {width:?}×{height:?} != {}×{}",
            expected.id, image.width, image.height
        )));
    }
    let has_alpha = image
        .rgba
        .as_chunks::<4>()
        .0
        .iter()
        .any(|pixel| pixel[3] != 255);
    let mask = xobject
        .dict
        .get(b"SMask")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_stream().ok());
    if has_alpha && mask.is_none() {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "a written signature dropped the image's transparency (/SMask)",
        )
        .with_detail(expected.id.clone()));
    }
    if mask.is_some_and(|mask| mask.content.is_empty()) {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "a written signature's /SMask is empty",
        )
        .with_detail(expected.id.clone()));
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
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "a written annotation has no /AP /N appearance stream",
        )
        .with_detail(expected.id.clone()));
    };
    if stream.content.is_empty() {
        return Err(LyraReaderError::new(
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
        return Err(LyraReaderError::new(
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
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "a written annotation's appearance /BBox does not match its /Rect",
        )
        .with_detail(format!("{}: {bbox:?} != {expected_box:?}", expected.id)));
    }
    Ok(())
}

/// Checks the font graph a `/FreeText` appearance promises: Type0, Identity-H, a descendant
/// CIDFontType2 with `/W` and `CIDToGIDMap`, a `/FontFile2`, and a `/ToUnicode` CMap.
///
/// This is intentionally structural rather than a render: it runs on every save and catches the
/// failure mode this change exists to remove — an appearance that points at Helvetica/WinAnsi
/// instead of an embedded Unicode font.
fn verify_embedded_appearance_font(
    document: &Document,
    dictionary: &Dictionary,
    expected: &WriteAnnotation,
) -> Result<()> {
    let has_text = expected.contents.as_deref().is_some_and(|text| {
        text.chars()
            .any(|character| !appearance_font::is_layout_control(character))
    });
    if !has_text {
        return Ok(());
    }
    let fail = |detail: String| -> Result<()> {
        Err(LyraReaderError::new(
            ErrorCode::Internal,
            "a written free-text appearance has no proper embedded Type0 font",
        )
        .with_detail(format!("{}: {detail}", expected.id)))
    };

    let Some(Object::Stream(stream)) = dictionary
        .get(b"AP")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_dict().ok())
        .and_then(|ap| ap.get(b"N").ok())
        .and_then(|object| deref(document, object))
    else {
        return fail("no /AP /N stream".to_string());
    };
    let Some(resources) = stream
        .dict
        .get(b"Resources")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_dict().ok())
    else {
        return fail("no /Resources".to_string());
    };
    let Some(fonts) = resources
        .get(b"Font")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_dict().ok())
    else {
        return fail("no /Font resources".to_string());
    };

    let mut type0 = None;
    for (_, object) in fonts.iter() {
        let Some(font) = deref(document, object).and_then(|object| object.as_dict().ok()) else {
            continue;
        };
        if font
            .get(b"Subtype")
            .ok()
            .and_then(|object| object.as_name().ok())
            == Some(b"Type0".as_slice())
        {
            type0 = Some(font);
            break;
        }
    }
    let Some(type0) = type0 else {
        return fail("the appearance's font is not /Subtype /Type0".to_string());
    };
    if type0
        .get(b"Encoding")
        .ok()
        .and_then(|object| object.as_name().ok())
        != Some(b"Identity-H".as_slice())
    {
        return fail("missing /Encoding /Identity-H".to_string());
    }
    let Some(to_unicode) = type0
        .get(b"ToUnicode")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_stream().ok())
    else {
        return fail("missing /ToUnicode stream".to_string());
    };
    if to_unicode.content.is_empty() {
        return fail("empty /ToUnicode stream".to_string());
    }
    let Some(cid_font) = type0
        .get(b"DescendantFonts")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_array().ok())
        .and_then(|array| array.first())
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_dict().ok())
    else {
        return fail("missing /DescendantFonts".to_string());
    };
    if cid_font
        .get(b"Subtype")
        .ok()
        .and_then(|object| object.as_name().ok())
        != Some(b"CIDFontType2".as_slice())
    {
        return fail("the descendant is not /CIDFontType2".to_string());
    }
    let Some(widths) = cid_font
        .get(b"W")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_array().ok())
    else {
        return fail("missing /W widths".to_string());
    };
    if widths.is_empty() {
        return fail("empty /W widths".to_string());
    }
    let Some(cid_to_gid) = cid_font
        .get(b"CIDToGIDMap")
        .ok()
        .and_then(|object| deref(document, object))
    else {
        return fail("missing /CIDToGIDMap".to_string());
    };
    if cid_to_gid.as_stream().is_err() {
        return fail("/CIDToGIDMap is not a stream".to_string());
    }
    let Some(font_file) = cid_font
        .get(b"FontDescriptor")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_dict().ok())
        .and_then(|descriptor| descriptor.get(b"FontFile2").ok())
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_stream().ok())
    else {
        return fail("missing /FontFile2".to_string());
    };
    if font_file.content.is_empty() {
        return fail("empty /FontFile2".to_string());
    }
    Ok(())
}

impl WriteAnnotationKind {
    pub(crate) fn is_geometry(self) -> bool {
        matches!(self, Self::Ink | Self::Square | Self::Circle | Self::Line)
    }
}

/// Appends an image XObject (FlateDecode RGB, plus an `/SMask` when the picture has any
/// transparency) and returns its object id.
///
/// PDF has no PNG image filter. A signature is normally a PNG with an alpha channel, so the
/// RGBA samples are split into a DeviceRGB Flate stream and a DeviceGray Flate `/SMask`; that
/// is the standard way an image with transparency is stored in a PDF and every viewer draws it.
fn add_stamp_image(
    document: &mut Document,
    image: &crate::annotations::WriteStampImage,
) -> Option<ObjectId> {
    if image.width == 0
        || image.height == 0
        || image.rgba.len() != image.width as usize * image.height as usize * 4
    {
        return None;
    }
    let mut rgb = Vec::with_capacity(image.width as usize * image.height as usize * 3);
    let mut alpha = Vec::with_capacity(image.width as usize * image.height as usize);
    let mut has_alpha = false;
    for pixel in image.rgba.as_chunks::<4>().0 {
        rgb.extend_from_slice(&pixel[..3]);
        alpha.push(pixel[3]);
        has_alpha |= pixel[3] != 255;
    }
    let mask = if has_alpha {
        let mut dictionary = Dictionary::new();
        dictionary.set("Type", name("XObject"));
        dictionary.set("Subtype", name("Image"));
        dictionary.set("Width", Object::Integer(i64::from(image.width)));
        dictionary.set("Height", Object::Integer(i64::from(image.height)));
        dictionary.set("ColorSpace", name("DeviceGray"));
        dictionary.set("BitsPerComponent", Object::Integer(8));
        add_stream(document, dictionary, alpha, true).ok()
    } else {
        None
    };

    let mut dictionary = Dictionary::new();
    dictionary.set("Type", name("XObject"));
    dictionary.set("Subtype", name("Image"));
    dictionary.set("Width", Object::Integer(i64::from(image.width)));
    dictionary.set("Height", Object::Integer(i64::from(image.height)));
    dictionary.set("ColorSpace", name("DeviceRGB"));
    dictionary.set("BitsPerComponent", Object::Integer(8));
    if let Some(mask) = mask {
        dictionary.set("SMask", Object::Reference(mask));
    }
    add_stream(document, dictionary, rgb, true).ok()
}

/// Appends the form XObject an annotation's `/AP /N` points at, and returns its object id.
///
/// A `/Text` note has no appearance stream (its icon is drawn by the viewer from `/Name`); every
/// other directly written kind gets one. The appearance is generated from the same
/// [`WriteAnnotation`] the dictionary is, so the two descriptions of the mark cannot disagree.
pub(crate) fn add_appearance_object(
    document: &mut Document,
    annotation: &WriteAnnotation,
    free_text_font: Option<&EmbeddedFreeTextFont>,
) -> ObjectId {
    let mut resources = Dictionary::new();
    if matches!(
        annotation.kind,
        WriteAnnotationKind::FreeText | WriteAnnotationKind::Stamp
    ) && let Some(font) = free_text_font
    {
        // The appearance's own font: Type0/Identity-H, subset for this document. `/DA`
        // keeps Helvetica as the standard-14 fallback for a viewer that ignores `/AP`; the
        // appearance itself no longer uses WinAnsi and never writes `?`.
        let mut fonts = Dictionary::new();
        fonts.set("F1", Object::Reference(font.type0));
        resources.set("Font", Object::Dictionary(fonts));
    }
    if annotation.kind == WriteAnnotationKind::Signature
        && let Some(image) = &annotation.stamp_image
        && let Some(object) = add_stamp_image(document, image)
    {
        let mut images = Dictionary::new();
        images.set("Im0", Object::Reference(object));
        resources.set("XObject", Object::Dictionary(images));
    }
    let mut stream_dictionary = Dictionary::new();
    stream_dictionary.set("Type", name("XObject"));
    stream_dictionary.set("Subtype", name("Form"));
    stream_dictionary.set("BBox", rect_array(annotation.rect));
    stream_dictionary.set("Resources", Object::Dictionary(resources));
    let mut stream = Stream::new(
        stream_dictionary,
        appearance_content(annotation, free_text_font.map(|font| &font.subset)),
    );
    // Keep the content legible in the saved file; the whole document is already compressed
    // where its producer chose to compress it, and this stream is a few hundred bytes.
    stream.allows_compression = false;
    add_object(document, Object::Stream(stream))
}

pub(crate) fn append_one(
    incremental: &mut IncrementalDocument,
    annotation: &WriteAnnotation,
    free_text_font: Option<&EmbeddedFreeTextFont>,
) -> Result<()> {
    let page_id = {
        let pages = incremental.get_prev_documents().get_pages();
        *pages.get(&(annotation.page.get() + 1)).ok_or_else(|| {
            LyraReaderError::new(
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
    // directly written kind carries a form XObject here.
    let appearance_id = if annotation.kind == WriteAnnotationKind::Text {
        None
    } else {
        Some(add_appearance_object(
            &mut incremental.new_document,
            annotation,
            free_text_font,
        ))
    };

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
    if matches!(
        annotation.kind,
        WriteAnnotationKind::Stamp | WriteAnnotationKind::Signature
    ) {
        // The reader's own model of the stamp: the exact words and style, independent of what
        // the appearance stream paints. A stamp written by another producer has no such key and
        // is read from `/Contents`, `/Name` and `/AP` instead (see `stamp_read`).
        let mut lyra = Dictionary::new();
        lyra.set(
            "Text",
            text_string(annotation.contents.as_deref().unwrap_or("")),
        );
        lyra.set(
            "Style",
            name(match annotation.kind {
                WriteAnnotationKind::Signature => "signature",
                _ => annotation.stamp_style.as_deref().unwrap_or("custom"),
            }),
        );
        dictionary.set("LyraReaderStamp", Object::Dictionary(lyra));
        dictionary.set("Name", name(stamp_icon_name(annotation)));
    }
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
                return Err(LyraReaderError::new(
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
        WriteAnnotationKind::Stamp | WriteAnnotationKind::Signature => {}
        WriteAnnotationKind::Highlight
        | WriteAnnotationKind::Underline
        | WriteAnnotationKind::StrikeOut => {
            return Err(LyraReaderError::new(
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

/// The page's `/Annots`, cloned into the new revision and ready to edit.
pub(crate) fn annots_array(
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
        Some(other) => Err(LyraReaderError::new(
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

pub(crate) fn add_object(document: &mut Document, object: Object) -> ObjectId {
    let id = (document.max_id + 1, 0);
    document.max_id = id.0;
    document.objects.insert(id, object);
    id
}

pub(crate) fn appearance_content(
    annotation: &WriteAnnotation,
    free_text_font: Option<&AppearanceSubset>,
) -> Vec<u8> {
    if annotation.kind == WriteAnnotationKind::FreeText {
        return free_text_appearance(annotation, free_text_font);
    }
    if annotation.kind == WriteAnnotationKind::Stamp {
        return stamp_appearance(annotation, free_text_font);
    }
    if annotation.kind == WriteAnnotationKind::Signature {
        return signature_appearance(annotation);
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
        | WriteAnnotationKind::StrikeOut
        | WriteAnnotationKind::Text => {}
        WriteAnnotationKind::FreeText
        | WriteAnnotationKind::Stamp
        | WriteAnnotationKind::Signature => {
            unreachable!("handled at the top of this function")
        }
    }
    content.push_str("Q\n");
    content.into_bytes()
}

/// The appearance of a `/FreeText` annotation: the exact `/Contents` text, encoded as
/// Type0/Identity-H CIDs in the document's shared subset font.
///
/// The stream is a picture of the same text `/Contents` carries. It is deliberately not generated
/// from the file's own text layout: a free-text annotation owns its rectangle, and the reader
/// already measures the text with CoreText for the canvas. This one only has to agree with itself.
///
/// Characters the bundled font cannot show are encoded through `.notdef` with a CID of their own
/// and keep their exact Unicode in `/ToUnicode`; they paint as the font's missing-glyph box, never
/// as `?`. `/Contents` is unchanged either way. The editor warns while typing.
fn free_text_appearance(annotation: &WriteAnnotation, font: Option<&AppearanceSubset>) -> Vec<u8> {
    let [red, green, blue] = annotation.color;
    let size = annotation.font_size.max(1.0);
    let padding = (size * 0.15).clamp(1.0, 6.0);
    let max_width = (annotation.rect.size.width - 2.0 * padding).max(1.0);
    // Normalise line endings for layout only; `/Contents` keeps the original bytes as a PDF
    // string. A tab is laid out as a space by `wrap_free_text`.
    let text = annotation
        .contents
        .as_deref()
        .unwrap_or("")
        .replace("\r\n", "\n")
        .replace('\r', "\n");
    let leading = size * 1.2;
    let mut content = String::from("q\n");
    content.push_str(&format!(
        "{:.3} {:.3} {:.3} {:.3} re W n\n",
        annotation.rect.min_x(),
        annotation.rect.min_y(),
        annotation.rect.size.width.max(0.01),
        annotation.rect.size.height.max(0.01)
    ));
    let Some(font) = font else {
        content.push_str("Q\n");
        return content.into_bytes();
    };
    let lines = wrap_free_text(&text, size, max_width, font);
    content.push_str("BT\n");
    content.push_str(&format!(
        "/F1 {:.4} Tf\n{:.4} {:.4} {:.4} rg\n{:.4} TL\n",
        size,
        f64::from(red) / 255.0,
        f64::from(green) / 255.0,
        f64::from(blue) / 255.0,
        leading
    ));
    let mut baseline = annotation.rect.max_y() - padding - size;
    for line in &lines {
        let width = font.text_width(line, size);
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
            font.hex_string(line)
        ));
        baseline -= leading;
    }
    content.push_str("ET\nQ\n");
    content.into_bytes()
}

/// The standard `/Name` a stamp style maps to. A viewer that ignores `/AP` draws its own icon
/// for these names; one that uses `/AP` draws the appearance, which says the same thing.
pub(crate) fn stamp_icon_name(annotation: &WriteAnnotation) -> &'static str {
    if annotation.kind == WriteAnnotationKind::Signature {
        return "Signature";
    }
    match annotation.stamp_style.as_deref() {
        Some("approved") => "Approved",
        Some("reviewed") => "Reviewed",
        Some("draft") => "Draft",
        Some("confidential") => "Confidential",
        Some("date") => "Date",
        // Not a standard stamp name: the appearance says the words, and a viewer that ignores
        // `/AP` shows its generic mark rather than a false "Approved".
        Some("custom") => "Custom",
        _ => "Approved",
    }
}

/// The appearance of a text stamp: a double border in the stamp's colour and the stamp's own
/// words, centred, in the same embedded font free text uses.
///
/// The layout is deliberately simple and stated in one place ([`stamp_layout`]) because the
/// canvas draws the same stamp before it is saved: a border and one line of text cannot be laid
/// out two different ways without the reader and the file disagreeing.
fn stamp_appearance(annotation: &WriteAnnotation, font: Option<&AppearanceSubset>) -> Vec<u8> {
    let [red, green, blue] = annotation.color;
    let colour = (
        f64::from(red) / 255.0,
        f64::from(green) / 255.0,
        f64::from(blue) / 255.0,
    );
    let rect = annotation.rect;
    let border = stamp_border_width(rect);
    let outer_inset = border / 2.0;
    let inner_inset = 4.5;
    let mut content = format!(
        "q {:.4} {:.4} {:.4} RG {:.3} w\n",
        colour.0, colour.1, colour.2, border
    );
    content.push_str(&format!(
        "{:.3} {:.3} {:.3} {:.3} re S\n",
        rect.min_x() + outer_inset,
        rect.min_y() + outer_inset,
        (rect.size.width - 2.0 * outer_inset).max(0.01),
        (rect.size.height - 2.0 * outer_inset).max(0.01)
    ));
    content.push_str(&format!(
        "{:.3} {:.3} {:.3} {:.3} re S\n",
        rect.min_x() + inner_inset,
        rect.min_y() + inner_inset,
        (rect.size.width - 2.0 * inner_inset).max(0.01),
        (rect.size.height - 2.0 * inner_inset).max(0.01)
    ));
    if let Some(font) = font
        && let Some(layout) = stamp_layout(annotation, font)
    {
        content.push_str(&format!(
            "BT /F1 {:.4} Tf {:.4} {:.4} {:.4} rg 1 0 0 1 {:.3} {:.3} Tm {} Tj ET\n",
            layout.size,
            colour.0,
            colour.1,
            colour.2,
            layout.x,
            layout.baseline,
            font.hex_string(&stamp_text(annotation))
        ));
    }
    content.push_str("Q\n");
    content.into_bytes()
}

/// One line of stamp text, with runs of whitespace collapsed. `/Contents` keeps the exact
/// string; only the picture is a single line, which is what a stamp is.
fn stamp_text(annotation: &WriteAnnotation) -> String {
    annotation
        .contents
        .as_deref()
        .unwrap_or("")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

struct StampLayout {
    size: f64,
    x: f64,
    baseline: f64,
}

/// The font size, left edge and baseline of a text stamp's one line.
///
/// The size is the largest that fits the inner box at up to 42% of the stamp's height, so a
/// resized stamp scales its words instead of clipping them. The baseline is 35% of the size
/// below the centre, which centres capital letters and digits (a stamp is upper case) rather
/// than centring the font's full ascent+descent. The canvas uses the same three numbers.
fn stamp_layout(annotation: &WriteAnnotation, font: &AppearanceSubset) -> Option<StampLayout> {
    let text = stamp_text(annotation);
    if text.is_empty() {
        return None;
    }
    let rect = annotation.rect;
    let available = rect.size.width - 2.0 * 6.0;
    if available <= 1.0 {
        return None;
    }
    let mut size = (rect.size.height * 0.42).clamp(2.0, 200.0);
    let width = font.text_width(&text, size);
    if width > available {
        size *= available / width;
    }
    if size < 2.0 {
        return None;
    }
    let width = font.text_width(&text, size);
    Some(StampLayout {
        size,
        x: rect.min_x() + (rect.size.width - width) / 2.0,
        baseline: rect.min_y() + rect.size.height / 2.0 - size * 0.35,
    })
}

fn stamp_border_width(rect: Rect) -> f64 {
    (rect.size.height * 0.035).clamp(0.75, 2.0)
}

/// The appearance of an image signature: the image XObject filling the annotation's box.
///
/// The image is stored at its own pixel size and scaled by the appearance matrix; a signature
/// therefore keeps its resolution when the box is enlarged, and the canvas draws the same
/// pixels. The image's transparency travels in its `/SMask` (see [`add_stamp_image`]).
fn signature_appearance(annotation: &WriteAnnotation) -> Vec<u8> {
    format!(
        "q {:.3} 0 0 {:.3} {:.3} {:.3} cm /Im0 Do Q\n",
        annotation.rect.size.width.max(0.01),
        annotation.rect.size.height.max(0.01),
        annotation.rect.min_x(),
        annotation.rect.min_y()
    )
    .into_bytes()
}

/// Greedy line breaking with the embedded font's real advances.
///
/// Chinese and Japanese have no spaces, so a word-wrap that only splits whitespace would put an
/// entire sentence on one overflowing line. A break is allowed after a space, between two CJK
/// characters, and after a hyphen/slash; it is refused before closing punctuation (so a comma
/// does not start a line) and before opening punctuation. A Latin word wider than the box still
/// breaks at the last character that fits, because a text box must not silently clip a word.
fn wrap_free_text(text: &str, size: f64, max_width: f64, font: &AppearanceSubset) -> Vec<String> {
    let mut lines = Vec::new();
    for paragraph in text.split('\n') {
        let characters: Vec<char> = paragraph
            .chars()
            .map(|character| if character == '\t' { ' ' } else { character })
            .collect();
        if characters.is_empty() {
            lines.push(String::new());
            continue;
        }
        let mut start = 0;
        while start < characters.len() {
            while start < characters.len() && characters[start] == ' ' {
                start += 1;
            }
            if start >= characters.len() {
                if lines.is_empty() {
                    lines.push(String::new());
                }
                break;
            }
            let mut width = 0.0;
            let mut end = start;
            let mut last_break = None;
            while end < characters.len() {
                let advance = font.character_width(characters[end], size);
                if width + advance > max_width && end > start {
                    break;
                }
                width += advance;
                end += 1;
                if end < characters.len() && can_break_between(characters[end - 1], characters[end])
                {
                    last_break = Some(end);
                }
            }
            if end < characters.len()
                && let Some(break_at) = last_break.filter(|break_at| *break_at > start)
            {
                end = break_at;
            }
            let line: String = characters[start..end].iter().collect();
            lines.push(line.trim_end().to_string());
            start = end;
        }
    }
    if lines.is_empty() {
        lines.push(String::new());
    }
    lines
}

fn can_break_between(left: char, right: char) -> bool {
    if left == ' ' || matches!(left, '-' | '/' | '\u{2013}' | '\u{2014}') {
        return true;
    }
    if is_cjk(left) || is_cjk(right) {
        return !is_closing_punctuation(right) && !is_opening_punctuation(right);
    }
    false
}

fn is_cjk(character: char) -> bool {
    matches!(
        u32::from(character),
        0x2E80..=0x2FFF // CJK Radicals, Kangxi Radicals, Ideographic Description
            | 0x3000..=0x303F // CJK Symbols and Punctuation
            | 0x3040..=0x30FF // Hiragana, Katakana
            | 0x3100..=0x312F // Bopomofo
            | 0x3190..=0x31EF // Kanbun, CJK Strokes, Katakana Phonetic Extensions
            | 0x3400..=0x4DBF // CJK Unified Ideographs Extension A
            | 0x4E00..=0x9FFF // CJK Unified Ideographs
            | 0xF900..=0xFAFF // CJK Compatibility Ideographs
            | 0xFE30..=0xFE4F // CJK Compatibility Forms
            | 0xFF00..=0xFFEF // Halfwidth and Fullwidth Forms
            | 0x20000..=0x2FA1F // CJK Unified Ideographs Extension B–F
    )
}

fn is_closing_punctuation(character: char) -> bool {
    matches!(
        character,
        '、' | '。'
            | '，'
            | '．'
            | '！'
            | '？'
            | '；'
            | '：'
            | '）'
            | '〕'
            | '］'
            | '｝'
            | '〉'
            | '》'
            | '」'
            | '』'
            | '】'
            | '〗'
            | '〙'
            | '〛'
            | '”'
            | '’'
            | '…'
            | '‥'
            | 'ー'
    )
}

fn is_opening_punctuation(character: char) -> bool {
    matches!(
        character,
        '（' | '〔'
            | '［'
            | '｛'
            | '〈'
            | '《'
            | '「'
            | '『'
            | '【'
            | '〖'
            | '〘'
            | '〚'
            | '“'
            | '‘'
    )
}

pub(crate) fn quadding(alignment: AnnotationAlignment) -> i64 {
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

pub(crate) fn rect_array(rect: Rect) -> Object {
    Object::Array(vec![
        Object::Real(rect.min_x() as f32),
        Object::Real(rect.min_y() as f32),
        Object::Real(rect.max_x() as f32),
        Object::Real(rect.max_y() as f32),
    ])
}

pub(crate) fn colour_array(color: [u8; 3]) -> Object {
    Object::Array(
        color
            .into_iter()
            .map(|channel| Object::Real(f32::from(channel) / 255.0))
            .collect(),
    )
}

pub(crate) fn line_array(start: Point, end: Point) -> Object {
    Object::Array(vec![
        Object::Real(start.x as f32),
        Object::Real(start.y as f32),
        Object::Real(end.x as f32),
        Object::Real(end.y as f32),
    ])
}

pub(crate) fn name(value: &str) -> Object {
    Object::Name(value.as_bytes().to_vec())
}

pub(crate) fn text_string(value: &str) -> Object {
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

pub(crate) fn deref<'a>(document: &'a Document, object: &'a Object) -> Option<&'a Object> {
    document.dereference(object).ok().map(|(_, object)| object)
}

pub(crate) fn number(object: &Object) -> Option<f32> {
    match object {
        Object::Integer(value) => Some(*value as f32),
        Object::Real(value) if value.is_finite() => Some(*value),
        _ => None,
    }
}

pub(crate) fn load_document(path: &Path, password: Option<&str>) -> Result<Document> {
    let options = LoadOptions {
        password: password.map(str::to_owned),
        ..LoadOptions::default()
    };
    Document::load_with_options(path, options)
        .map_err(|error| lopdf_error("could not read the document for the stroked writer", error))
}

pub(crate) fn lopdf_error(action: &str, error: lopdf::Error) -> LyraReaderError {
    LyraReaderError::new(ErrorCode::Io, action).with_detail(error.to_string())
}

pub(crate) fn io_error(action: &str, path: &Path, error: std::io::Error) -> LyraReaderError {
    LyraReaderError::new(ErrorCode::Io, action).with_detail(format!("{}: {error}", path.display()))
}
