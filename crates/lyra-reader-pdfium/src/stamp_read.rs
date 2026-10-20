//! Reading the content of `/Stamp` annotations.
//!
//! PDFium's C API sees a `/Stamp` only as a subtype number and a `/Rect`; its appearance, its
//! `/Name` and its `/Contents` are what make it a stamp. A stamp this reader writes carries a
//! private `/LyraReaderStamp` dictionary so it can be rebuilt exactly, but a stamp written by
//! Preview, PDFKit or Acrobat carries only the keys the standard defines (and often a picture
//! in `/AP /N`). This module reads both through `lopdf`, which is also how the line-ending and
//! border readers reach the keys PDFium does not expose.
//!
//! # What is read, in order
//!
//! * **Text**: `/LyraReaderStamp /Text` first (this writer's exact model), then `/Contents`,
//!   then the standard `/Name` (`Approved`, `Reviewed`, …), then the strings the appearance
//!   stream paints. The last is a heuristic: it reads the literal and printable hex strings of
//!   the content stream, so a producer that draws `(APPROVED)` into its appearance is still
//!   understood. A Type0 font's CIDs that are not valid text are ignored rather than shown as
//!   mojibake.
//! * **Style**: `/LyraReaderStamp /Style`, else the standard `/Name`, else `custom`.
//! * **Image**: the first image XObject reachable from `/AP /N`'s resources, one Form level
//!   deep. A FlateDecode image (with or without a `/SMask` and PNG predictor) is decoded and
//!   re-encoded as PNG so the shell can draw it with its ordinary image decoder. A DCTDecode
//!   image is passed through as JPEG. Anything else is reported as an unreadable image rather
//!   than as "no image": a stamp that exists but cannot be shown must say so.
//!
//! The second pass over the file is a convenience, not a requirement: a file `lopdf` cannot
//! open still yields a plain `/Stamp` from PDFium, just without the stamp content.

use lopdf::{Dictionary, Document, LoadOptions, Object, Stream};
use lyra_reader_core::{RawStampImage, RawStampImageEncoding};
use std::collections::HashMap;
use std::path::Path;

/// The largest image, in pixels, this reader will decode. A signature is tens of thousands of
/// pixels; a malformed stamp the size of a poster must not turn into a gigabyte allocation.
const MAX_IMAGE_PIXELS: u64 = 16_000_000;
/// The largest side, in pixels, this reader will decode.
const MAX_IMAGE_SIDE: u32 = 8_192;
/// A decompressed stream larger than this is refused by the image and text readers.
const MAX_STREAM_BYTES: usize = 64 * 1024 * 1024;

/// One page and a rounded `/Rect`, the fallback identity for a stamp with no `/NM`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) struct StampRectKey {
    pub page: u32,
    pub x: i64,
    pub y: i64,
}

/// What one `/Stamp` annotation carries, keyed by the two identities the PDF can supply.
#[derive(Clone, Debug, Default)]
pub(crate) struct StampDetails {
    pub text: Option<String>,
    pub style: String,
    pub image: Option<RawStampImage>,
    pub image_error: Option<String>,
}

/// The document's stamp details, read once.
#[derive(Default)]
pub(crate) struct StampCatalog {
    pub by_name: HashMap<String, StampDetails>,
    pub by_rect: HashMap<StampRectKey, StampDetails>,
}

impl StampCatalog {
    /// The details for a stamp, by `/NM` and then by page + rounded `/Rect`.
    pub(crate) fn find(
        &self,
        name: Option<&str>,
        page: u32,
        rect: [f64; 4],
    ) -> Option<&StampDetails> {
        if let Some(name) = name
            && let Some(details) = self.by_name.get(name)
        {
            return Some(details);
        }
        self.by_rect.get(&rect_key(page, rect))
    }
}

pub(crate) fn rect_key(page: u32, rect: [f64; 4]) -> StampRectKey {
    let round = |value: f64| -> i64 {
        if value.is_finite() {
            (value * 10.0).round() as i64
        } else {
            i64::MIN
        }
    };
    StampRectKey {
        page,
        x: round(rect[0]),
        y: round(rect[1]),
    }
}

/// Reads every `/Stamp` in `path`, or `None` when the file cannot be read a second time.
pub(crate) fn read_stamp_catalog(path: &Path, password: Option<&str>) -> Option<StampCatalog> {
    let options = LoadOptions {
        password: password.map(str::to_owned),
        max_decompressed_size: Some(MAX_STREAM_BYTES),
        ..LoadOptions::default()
    };
    let document = Document::load_with_options(path, options).ok()?;
    let mut catalog = StampCatalog::default();
    for (page_number, page_id) in document.get_pages() {
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
            let Some(annotation) =
                deref(&document, object).and_then(|object| object.as_dict().ok())
            else {
                continue;
            };
            if annotation.get(b"Subtype").and_then(Object::as_name).ok() != Some(b"Stamp") {
                continue;
            }
            let details = read_one(&document, annotation);
            let page = page_number.saturating_sub(1);
            let name = annotation
                .get(b"NM")
                .ok()
                .and_then(|object| deref(&document, object))
                .and_then(string_value);
            if let Some(name) = name {
                catalog.by_name.insert(name, details.clone());
            }
            if let Some(rect) = annotation_rect(&document, annotation) {
                catalog.by_rect.insert(rect_key(page, rect), details);
            }
        }
    }
    Some(catalog)
}

fn annotation_rect(document: &Document, annotation: &Dictionary) -> Option<[f64; 4]> {
    let array = annotation
        .get(b"Rect")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_array().ok())?;
    if array.len() != 4 {
        return None;
    }
    let mut values = [0.0f64; 4];
    for (slot, object) in values.iter_mut().zip(array) {
        *slot = deref(document, object).and_then(number)?;
    }
    Some(values)
}

fn read_one(document: &Document, annotation: &Dictionary) -> StampDetails {
    let private = annotation
        .get(b"LyraReaderStamp")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_dict().ok());
    let mut style = private
        .and_then(|dictionary| dictionary.get(b"Style").ok())
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_name().ok())
        .map(|name| String::from_utf8_lossy(name).to_ascii_lowercase())
        .unwrap_or_default();

    let mut text = private
        .and_then(|dictionary| dictionary.get(b"Text").ok())
        .and_then(|object| deref(document, object))
        .and_then(string_value);
    if text.as_deref().is_some_and(|text| text.trim().is_empty()) {
        text = None;
    }
    if text.is_none() {
        text = annotation
            .get(b"Contents")
            .ok()
            .and_then(|object| deref(document, object))
            .and_then(string_value)
            .filter(|text| !text.trim().is_empty());
    }

    let name = annotation
        .get(b"Name")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_name().ok())
        .map(|name| String::from_utf8_lossy(name).into_owned());
    let mapped_name = name.as_deref().and_then(standard_name);
    if text.is_none()
        && let Some((name_text, _)) = mapped_name
    {
        text = Some(name_text.to_string());
    }
    if style.is_empty()
        && let Some((_, name_style)) = mapped_name
    {
        style = name_style.to_string();
    }

    let appearance = appearance_stream(document, annotation);
    if text.is_none()
        && let Some(stream) = appearance
        && let Ok(content) = stream.decompressed_content()
    {
        text = appearance_text(&content);
    }
    if style.is_empty() {
        style = "custom".to_string();
    }

    let (image, image_error) = match appearance.and_then(|stream| first_image(document, stream, 0))
    {
        Some(Ok(image)) => (Some(image), None),
        Some(Err(reason)) => (None, Some(reason)),
        None => (None, None),
    };

    StampDetails {
        text,
        style,
        image,
        image_error,
    }
}

/// The standard stamp names PDF 32000-1 table 8.34 lists, with the words a reader shows and the
/// style the reader uses when it writes the stamp back.
fn standard_name(name: &str) -> Option<(&'static str, &'static str)> {
    match name.to_ascii_lowercase().as_str() {
        "approved" => Some(("APPROVED", "approved")),
        "reviewed" => Some(("REVIEWED", "reviewed")),
        "draft" => Some(("DRAFT", "draft")),
        "confidential" => Some(("CONFIDENTIAL", "confidential")),
        "final" => Some(("FINAL", "custom")),
        "forcomment" => Some(("FOR COMMENT", "custom")),
        "forpublicrelease" => Some(("FOR PUBLIC RELEASE", "custom")),
        "notapproved" => Some(("NOT APPROVED", "custom")),
        "notforpublicrelease" => Some(("NOT FOR PUBLIC RELEASE", "custom")),
        "topsecret" => Some(("TOP SECRET", "custom")),
        "experimental" => Some(("EXPERIMENTAL", "custom")),
        "expired" => Some(("EXPIRED", "custom")),
        "sold" => Some(("SOLD", "custom")),
        "department" => Some(("DEPARTMENT", "custom")),
        "asis" => Some(("AS IS", "custom")),
        _ => None,
    }
}

/// `/AP /N`, whatever shape the producer used: a stream, a dictionary of states, or an array.
fn appearance_stream<'a>(document: &'a Document, annotation: &'a Dictionary) -> Option<&'a Stream> {
    let normal = annotation
        .get(b"AP")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_dict().ok())
        .and_then(|ap| ap.get(b"N").ok())
        .and_then(|object| deref(document, object))?;
    stream_of(document, normal)
}

fn stream_of<'a>(document: &'a Document, object: &'a Object) -> Option<&'a Stream> {
    match object {
        Object::Stream(stream) => Some(stream),
        Object::Array(array) => array.iter().find_map(|object| {
            deref(document, object).and_then(|object| stream_of(document, object))
        }),
        Object::Dictionary(dictionary) => dictionary.iter().find_map(|(_, object)| {
            deref(document, object).and_then(|object| stream_of(document, object))
        }),
        _ => None,
    }
}

/// The first image XObject reachable from a stream's resources, one Form level deep.
fn first_image<'a>(
    document: &'a Document,
    stream: &'a Stream,
    depth: usize,
) -> Option<std::result::Result<RawStampImage, String>> {
    if depth > 2 {
        return None;
    }
    let resources = stream
        .dict
        .get(b"Resources")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_dict().ok())?;
    let xobjects = resources
        .get(b"XObject")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_dict().ok())?;
    for (_, object) in xobjects.iter() {
        let Some(Object::Stream(candidate)) = deref(document, object) else {
            continue;
        };
        match candidate
            .dict
            .get(b"Subtype")
            .ok()
            .and_then(|object| object.as_name().ok())
        {
            Some(b"Image") => return Some(decode_image(document, candidate)),
            Some(b"Form") => {
                if let Some(found) = first_image(document, candidate, depth + 1) {
                    return Some(found);
                }
            }
            _ => {}
        }
    }
    None
}

fn decode_image(
    document: &Document,
    stream: &Stream,
) -> std::result::Result<RawStampImage, String> {
    let width = integer(document, &stream.dict, b"Width").unwrap_or(0);
    let height = integer(document, &stream.dict, b"Height").unwrap_or(0);
    if width <= 0 || height <= 0 {
        return Err("the image XObject has no size".to_string());
    }
    let width = u32::try_from(width).map_err(|_| "the image width is out of range".to_string())?;
    let height =
        u32::try_from(height).map_err(|_| "the image height is out of range".to_string())?;
    if width > MAX_IMAGE_SIDE
        || height > MAX_IMAGE_SIDE
        || u64::from(width) * u64::from(height) > MAX_IMAGE_PIXELS
    {
        return Err(format!(
            "the image is {width}×{height} pixels, larger than this reader decodes"
        ));
    }

    let filters = filter_names(document, &stream.dict);
    if filters.iter().any(|filter| filter == "JPXDecode") {
        return Err("the image uses JPXDecode, which this reader does not decode".to_string());
    }
    if filters.iter().any(|filter| filter == "DCTDecode") {
        return Ok(RawStampImage {
            width,
            height,
            encoding: RawStampImageEncoding::Jpeg,
            data: stream.content.clone(),
        });
    }
    if filters.iter().any(|filter| {
        filter != "FlateDecode" && filter != "ASCIIHexDecode" && filter != "ASCII85Decode"
    }) {
        return Err(format!(
            "the image uses {}, which this reader does not decode",
            filters.join(" + ")
        ));
    }
    let mut data = stream
        .decompressed_content()
        .map_err(|error| format!("the image stream could not be decompressed: {error}"))?;
    let predictor = decode_parms(document, &stream.dict).unwrap_or_default();
    if predictor.predictor >= 10 {
        data = png_unpredict(&data, predictor.columns, predictor.colors, predictor.bits)
            .ok_or_else(|| "the image's PNG predictor is malformed".to_string())?;
    } else if predictor.predictor == 2 {
        data = tiff_unpredict(&data, predictor.columns, predictor.colors, predictor.bits)
            .ok_or_else(|| "the image's TIFF predictor is malformed".to_string())?;
    }

    let components = colour_components(document, &stream.dict)?;
    if integer(document, &stream.dict, b"BitsPerComponent").unwrap_or(8) != 8 {
        return Err("the image is not 8 bits per component".to_string());
    }
    let expected = width as usize * height as usize * components;
    if data.len() < expected {
        return Err(format!(
            "the image has {} byte(s), shorter than its {width}×{height}×{components} samples",
            data.len()
        ));
    }

    let mut rgba = vec![255u8; width as usize * height as usize * 4];
    for pixel in 0..(width as usize * height as usize) {
        let source = &data[pixel * components..pixel * components + components];
        let target = &mut rgba[pixel * 4..pixel * 4 + 4];
        match components {
            1 => {
                target[0] = source[0];
                target[1] = source[0];
                target[2] = source[0];
            }
            3 => target[..3].copy_from_slice(&source[..3]),
            4 => {
                // DeviceCMYK is additive in reverse; this is the standard naive conversion the
                // built-in viewers use, and it is only reached by an uncommon stamp.
                let k = u16::from(source[3]);
                for channel in 0..3 {
                    target[channel] = (u16::from(source[channel]) * (255 - k) / 255) as u8;
                }
            }
            _ => return Err("the image's colour space is not supported".to_string()),
        }
    }

    if let Some(mask) = stream
        .dict
        .get(b"SMask")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_stream().ok())
    {
        let mut alpha = mask
            .decompressed_content()
            .map_err(|error| format!("the image's /SMask could not be decompressed: {error}"))?;
        let mask_predictor = decode_parms(document, &mask.dict).unwrap_or_default();
        if mask_predictor.predictor >= 10 {
            alpha = png_unpredict(
                &alpha,
                mask_predictor.columns,
                mask_predictor.colors,
                mask_predictor.bits,
            )
            .ok_or_else(|| "the image's /SMask predictor is malformed".to_string())?;
        }
        if alpha.len() < width as usize * height as usize {
            return Err("the image's /SMask is shorter than its picture".to_string());
        }
        for (pixel, value) in alpha
            .iter()
            .take(width as usize * height as usize)
            .enumerate()
        {
            rgba[pixel * 4 + 3] = *value;
        }
    }

    let png = encode_png(width, height, &rgba)?;
    Ok(RawStampImage {
        width,
        height,
        encoding: RawStampImageEncoding::Png,
        data: png,
    })
}

struct Predictor {
    predictor: i64,
    colors: usize,
    bits: usize,
    columns: usize,
}

impl Default for Predictor {
    fn default() -> Self {
        Self {
            predictor: 1,
            colors: 1,
            bits: 8,
            columns: 1,
        }
    }
}

fn decode_parms(document: &Document, dictionary: &Dictionary) -> Option<Predictor> {
    let parms = dictionary
        .get(b"DecodeParms")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_dict().ok())?;
    Some(Predictor {
        predictor: integer(document, parms, b"Predictor").unwrap_or(1),
        colors: integer(document, parms, b"Colors").unwrap_or(1).max(1) as usize,
        bits: integer(document, parms, b"BitsPerComponent")
            .unwrap_or(8)
            .max(1) as usize,
        columns: integer(document, parms, b"Columns").unwrap_or(1).max(1) as usize,
    })
}

fn filter_names(document: &Document, dictionary: &Dictionary) -> Vec<String> {
    let filter = dictionary
        .get(b"Filter")
        .ok()
        .and_then(|object| deref(document, object));
    let mut names = Vec::new();
    match filter {
        Some(Object::Name(name)) => names.push(String::from_utf8_lossy(name).into_owned()),
        Some(Object::Array(array)) => {
            for object in array {
                if let Some(Object::Name(name)) = deref(document, object) {
                    names.push(String::from_utf8_lossy(name).into_owned());
                }
            }
        }
        _ => {}
    }
    names
}

fn colour_components(
    document: &Document,
    dictionary: &Dictionary,
) -> std::result::Result<usize, String> {
    let colour_space = dictionary
        .get(b"ColorSpace")
        .ok()
        .and_then(|object| deref(document, object));
    match colour_space {
        Some(Object::Name(name)) => match name.as_slice() {
            b"DeviceRGB" | b"RGB" | b"CalRGB" => Ok(3),
            b"DeviceGray" | b"G" | b"CalGray" => Ok(1),
            b"DeviceCMYK" | b"CMYK" => Ok(4),
            _ => Err(format!(
                "the image's colour space /{} is not supported",
                String::from_utf8_lossy(name)
            )),
        },
        Some(Object::Array(array)) => {
            let family = array
                .first()
                .and_then(|object| deref(document, object))
                .and_then(|object| object.as_name().ok())
                .unwrap_or(b"");
            match family {
                b"ICCBased" => {
                    let profile = array
                        .get(1)
                        .and_then(|object| deref(document, object))
                        .and_then(|object| object.as_stream().ok());
                    let count = profile
                        .and_then(|stream| integer(document, &stream.dict, b"N"))
                        .unwrap_or(3);
                    match count {
                        1 | 3 | 4 => Ok(count as usize),
                        _ => Err("the ICC profile's component count is not supported".to_string()),
                    }
                }
                b"Indexed" => Err("an indexed-colour stamp image is not supported".to_string()),
                b"DeviceRGB" | b"CalRGB" => Ok(3),
                b"DeviceGray" | b"CalGray" => Ok(1),
                b"DeviceCMYK" => Ok(4),
                _ => Err("the image's colour space is not supported".to_string()),
            }
        }
        _ => Ok(3),
    }
}

fn integer(document: &Document, dictionary: &Dictionary, key: &[u8]) -> Option<i64> {
    dictionary
        .get(key)
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| match object {
            Object::Integer(value) => Some(*value),
            _ => None,
        })
}

fn number(object: &Object) -> Option<f64> {
    match object {
        Object::Integer(value) => Some(*value as f64),
        Object::Real(value) if value.is_finite() => Some(f64::from(*value)),
        _ => None,
    }
}

fn deref<'a>(document: &'a Document, object: &'a Object) -> Option<&'a Object> {
    document.dereference(object).ok().map(|(_, object)| object)
}

fn string_value(object: &Object) -> Option<String> {
    decode_pdf_string(object.as_str().ok()?)
}

/// A PDF text string as text: UTF-16BE with a BOM, UTF-8, or PDFDocEncoding approximated by
/// Latin-1. The same rule the line-ending reader uses for `/Subj`.
fn decode_pdf_string(bytes: &[u8]) -> Option<String> {
    if bytes.is_empty() {
        return None;
    }
    if bytes.starts_with(&[0xFE, 0xFF]) {
        let units: Vec<u16> = bytes[2..]
            .chunks(2)
            .filter(|pair| pair.len() == 2)
            .map(|pair| u16::from_be_bytes([pair[0], pair[1]]))
            .collect();
        return Some(String::from_utf16_lossy(&units));
    }
    if std::str::from_utf8(bytes).is_ok() {
        return Some(String::from_utf8_lossy(bytes).into_owned());
    }
    Some(bytes.iter().map(|byte| char::from(*byte)).collect())
}

/// The strings an appearance stream paints, when they read as text.
///
/// A stamp's appearance is a picture of its own words, so the strings in it are the words. This
/// accepts literal `( … )` strings and `< … >` hex strings that decode to printable text; a
/// Type0 font's arbitrary CIDs are skipped rather than shown as mojibake. The order of the
/// content stream is kept, which is the order a person reads.
fn appearance_text(content: &[u8]) -> Option<String> {
    let mut pieces: Vec<String> = Vec::new();
    let mut index = 0;
    while index < content.len() {
        match content[index] {
            b'(' => {
                let (text, next) = literal_string(content, index);
                index = next;
                if let Some(text) = text.filter(|text| printable_text(text)) {
                    pieces.push(text);
                }
            }
            b'<' if content.get(index + 1) != Some(&b'<') => {
                let Some(end) = content[index + 1..].iter().position(|byte| *byte == b'>') else {
                    break;
                };
                let hex = &content[index + 1..index + 1 + end];
                index += end + 2;
                if let Some(text) = hex_text(hex).filter(|text| printable_text(text)) {
                    pieces.push(text);
                }
            }
            b'%' => {
                while index < content.len() && content[index] != b'\n' {
                    index += 1;
                }
            }
            _ => index += 1,
        }
    }
    if pieces.is_empty() {
        return None;
    }
    let joined = pieces.join(" ");
    let collapsed = joined.split_whitespace().collect::<Vec<_>>().join(" ");
    (!collapsed.is_empty()).then_some(collapsed)
}

fn printable_text(text: &str) -> bool {
    let mut visible = 0usize;
    let mut total = 0usize;
    for character in text.chars() {
        if character.is_whitespace() {
            continue;
        }
        total += 1;
        if !character.is_control() {
            visible += 1;
        }
    }
    total > 0 && visible * 5 >= total * 4
}

/// One literal `( … )` string starting at `start`, with PDF escapes and balanced parentheses.
fn literal_string(content: &[u8], start: usize) -> (Option<String>, usize) {
    let mut index = start + 1;
    let mut depth = 1usize;
    let mut bytes = Vec::new();
    while index < content.len() {
        match content[index] {
            b'\\' => {
                index += 1;
                let Some(byte) = content.get(index).copied() else {
                    break;
                };
                match byte {
                    b'n' => bytes.push(b'\n'),
                    b'r' => bytes.push(b'\r'),
                    b't' => bytes.push(b'\t'),
                    b'b' => bytes.push(0x08),
                    b'f' => bytes.push(0x0C),
                    b'\n' => {}
                    b'\r' => {
                        if content.get(index + 1) == Some(&b'\n') {
                            index += 1;
                        }
                    }
                    b'0'..=b'7' => {
                        let mut value = u16::from(byte - b'0');
                        for _ in 0..2 {
                            match content.get(index + 1) {
                                Some(next @ b'0'..=b'7') => {
                                    value = value * 8 + u16::from(*next - b'0');
                                    index += 1;
                                }
                                _ => break,
                            }
                        }
                        bytes.push(value as u8);
                    }
                    other => bytes.push(other),
                }
                index += 1;
            }
            b'(' => {
                depth += 1;
                bytes.push(b'(');
                index += 1;
            }
            b')' => {
                depth -= 1;
                index += 1;
                if depth == 0 {
                    break;
                }
                bytes.push(b')');
            }
            byte => {
                bytes.push(byte);
                index += 1;
            }
        }
    }
    let text = if bytes.starts_with(&[0xFE, 0xFF]) {
        decode_pdf_string(&bytes)
    } else if std::str::from_utf8(&bytes).is_ok() {
        Some(String::from_utf8_lossy(&bytes).into_owned())
    } else {
        // A single-byte encoding other than UTF-8 is read as PDFDocEncoding; Latin-1 is the
        // same for the ASCII words a stamp uses.
        Some(bytes.iter().map(|byte| char::from(*byte)).collect())
    };
    (text, index)
}

fn hex_text(hex: &[u8]) -> Option<String> {
    if !hex.len().is_multiple_of(2) {
        return None;
    }
    let mut bytes = Vec::with_capacity(hex.len() / 2);
    for pair in hex.chunks(2) {
        let value = hex_value(pair[0])? * 16 + hex_value(pair[1])?;
        bytes.push(value);
    }
    decode_pdf_string(&bytes)
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn png_unpredict(data: &[u8], columns: usize, colors: usize, bits: usize) -> Option<Vec<u8>> {
    let bytes_per_pixel = (colors * bits).div_ceil(8).max(1);
    let row_len = (columns * colors * bits).div_ceil(8);
    if row_len == 0 {
        return None;
    }
    let mut output = Vec::new();
    let mut previous = vec![0u8; row_len];
    let mut index = 0;
    while index < data.len() {
        let filter = *data.get(index)?;
        index += 1;
        let row = data.get(index..index + row_len)?;
        index += row_len;
        let mut current = vec![0u8; row_len];
        for slot in 0..row_len {
            let left = if slot >= bytes_per_pixel {
                current[slot - bytes_per_pixel]
            } else {
                0
            };
            let up = previous[slot];
            let up_left = if slot >= bytes_per_pixel {
                previous[slot - bytes_per_pixel]
            } else {
                0
            };
            current[slot] = match filter {
                0 => row[slot],
                1 => row[slot].wrapping_add(left),
                2 => row[slot].wrapping_add(up),
                3 => row[slot].wrapping_add(((u16::from(left) + u16::from(up)) / 2) as u8),
                4 => row[slot].wrapping_add(paeth(left, up, up_left)),
                _ => return None,
            };
        }
        output.extend_from_slice(&current);
        previous = current;
    }
    Some(output)
}

fn paeth(left: u8, up: u8, up_left: u8) -> u8 {
    let p = i32::from(left) + i32::from(up) - i32::from(up_left);
    let pa = (p - i32::from(left)).abs();
    let pb = (p - i32::from(up)).abs();
    let pc = (p - i32::from(up_left)).abs();
    if pa <= pb && pa <= pc {
        left
    } else if pb <= pc {
        up
    } else {
        up_left
    }
}

fn tiff_unpredict(data: &[u8], columns: usize, colors: usize, bits: usize) -> Option<Vec<u8>> {
    if bits != 8 {
        return None;
    }
    let row_len = columns * colors;
    if row_len == 0 {
        return None;
    }
    let mut output = data.to_vec();
    for row in output.chunks_mut(row_len) {
        for slot in colors..row.len() {
            row[slot] = row[slot].wrapping_add(row[slot - colors]);
        }
    }
    Some(output)
}

fn encode_png(width: u32, height: u32, rgba: &[u8]) -> std::result::Result<Vec<u8>, String> {
    let mut output = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut output, width, height);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder
            .write_header()
            .map_err(|error| format!("the stamp image could not be encoded: {error}"))?;
        writer
            .write_image_data(rgba)
            .map_err(|error| format!("the stamp image could not be encoded: {error}"))?;
    }
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn standard_names_map_to_words_and_styles() {
        assert_eq!(standard_name("Approved"), Some(("APPROVED", "approved")));
        assert_eq!(
            standard_name("NotForPublicRelease"),
            Some(("NOT FOR PUBLIC RELEASE", "custom"))
        );
        assert_eq!(standard_name("Signature"), None);
    }

    #[test]
    fn png_predictor_reconstructs_filtered_rows() {
        // Two 2-byte rows: filter 0 then filter 2 (Up).
        let data = [0u8, 10, 20, 2, 1, 2];
        let output = png_unpredict(&data, 2, 1, 8).expect("predictor");
        assert_eq!(output, vec![10, 20, 11, 22]);
    }

    #[test]
    fn appearance_text_reads_literal_and_hex_strings() {
        let content = b"q BT /F1 12 Tf 10 10 Td (APPROVED) Tj ET Q";
        assert_eq!(appearance_text(content).as_deref(), Some("APPROVED"));
        let content = b"BT <415050524f564544> Tj ET";
        assert_eq!(appearance_text(content).as_deref(), Some("APPROVED"));
    }

    #[test]
    fn cid_strings_are_not_reported_as_text() {
        // Two-byte CIDs in the range this writer emits for .notdef/subset glyphs.
        let content = b"BT <00010002> Tj ET";
        assert_eq!(appearance_text(content), None);
    }
}
