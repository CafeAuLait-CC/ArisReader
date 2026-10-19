//! Prints what a saved PDF's free-text appearance actually contains.
//!
//! This is the extraction half of the CJK evidence: it decodes the appearance stream's
//! Identity-H CIDs through the embedded `/ToUnicode` CMap and compares that string with the
//! annotation's `/Contents`. It also reports the shared font object, the subset size and the
//! glyph count.
//!
//! ```text
//! cargo run -p lyra-reader-pdfium --example cjk_appearance_inspect -- /tmp/lyra-reader-cjk-evidence.pdf
//! ```

use lopdf::{Document, Object, ObjectId, Stream};
use std::collections::HashMap;

fn deref<'a>(document: &'a Document, object: &'a Object) -> Option<&'a Object> {
    document.dereference(object).ok().map(|(_, object)| object)
}

fn text_string(bytes: &[u8]) -> String {
    if let Some(rest) = bytes.strip_prefix(&[0xFE, 0xFF]) {
        let units: Vec<u16> = rest
            .chunks(2)
            .map(|chunk| u16::from_be_bytes([chunk[0], chunk[1]]))
            .collect();
        return String::from_utf16(&units).unwrap_or_else(|_| "<invalid UTF-16>".to_string());
    }
    bytes.iter().map(|byte| char::from(*byte)).collect()
}

fn tounicode(stream: &Stream) -> HashMap<u16, char> {
    let bytes = stream.decompressed_content().expect("ToUnicode");
    let text = String::from_utf8(bytes).expect("ASCII CMap");
    let mut map = HashMap::new();
    let mut inside = false;
    for line in text.lines() {
        let line = line.trim();
        if line.ends_with("beginbfchar") {
            inside = true;
            continue;
        }
        if line == "endbfchar" {
            inside = false;
            continue;
        }
        if !inside {
            continue;
        }
        let mut parts = line.split_whitespace();
        let source = parts.next().unwrap().trim_matches(|c| c == '<' || c == '>');
        let destination = parts.next().unwrap().trim_matches(|c| c == '<' || c == '>');
        let cid = u16::from_str_radix(source, 16).unwrap();
        let units: Vec<u16> = destination
            .as_bytes()
            .chunks(4)
            .map(|chunk| u16::from_str_radix(std::str::from_utf8(chunk).unwrap(), 16).unwrap())
            .collect();
        map.insert(
            cid,
            String::from_utf16(&units).unwrap().chars().next().unwrap(),
        );
    }
    map
}

fn decode(stream: &Stream, map: &HashMap<u16, char>) -> String {
    let bytes = stream.decompressed_content().expect("appearance");
    let mut result = String::new();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'<' && bytes.get(index + 1) != Some(&b'<') {
            let start = index + 1;
            let Some(relative) = bytes[start..].iter().position(|byte| *byte == b'>') else {
                break;
            };
            let end = start + relative;
            let hex = std::str::from_utf8(&bytes[start..end]).unwrap();
            for chunk in hex.as_bytes().chunks(4) {
                let cid = u16::from_str_radix(std::str::from_utf8(chunk).unwrap(), 16).unwrap();
                result.push(*map.get(&cid).unwrap_or(&'\u{FFFD}'));
            }
            index = end + 1;
        } else {
            index += 1;
        }
    }
    result
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = std::env::args().nth(1).expect("usage: inspect <pdf>");
    let document = Document::load(&path)?;
    let mut seen_fonts: HashMap<ObjectId, usize> = HashMap::new();
    for (page_number, page_id) in document.get_pages() {
        let page = document.get_dictionary(page_id)?;
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
            let Some(nm) = dictionary
                .get(b"NM")
                .ok()
                .and_then(|object| deref(&document, object))
                .and_then(|object| object.as_str().ok())
            else {
                continue;
            };
            let id = text_string(nm);
            if !id.starts_with("cjk-evidence") {
                continue;
            }
            let contents = dictionary
                .get(b"Contents")
                .ok()
                .and_then(|object| deref(&document, object))
                .and_then(|object| object.as_str().ok())
                .map(text_string)
                .unwrap_or_default();
            let appearance = dictionary
                .get(b"AP")
                .ok()
                .and_then(|object| deref(&document, object))
                .and_then(|object| object.as_dict().ok())
                .and_then(|ap| ap.get(b"N").ok())
                .and_then(|object| deref(&document, object))
                .and_then(|object| object.as_stream().ok())
                .expect("appearance");
            let resources = appearance
                .dict
                .get(b"Resources")
                .ok()
                .and_then(|object| deref(&document, object))
                .and_then(|object| object.as_dict().ok())
                .expect("resources");
            let fonts = resources
                .get(b"Font")
                .ok()
                .and_then(|object| deref(&document, object))
                .and_then(|object| object.as_dict().ok())
                .expect("fonts");
            let (font_name, font_id) = fonts
                .iter()
                .find_map(|(name, object)| match object {
                    Object::Reference(id) => Some((name.clone(), *id)),
                    _ => None,
                })
                .expect("indirect font resource");
            *seen_fonts.entry(font_id).or_default() += 1;
            let type0 = document.get_dictionary(font_id)?;
            let unicode = tounicode(
                type0
                    .get(b"ToUnicode")
                    .ok()
                    .and_then(|object| deref(&document, object))
                    .and_then(|object| object.as_stream().ok())
                    .expect("ToUnicode"),
            );
            let descendants = type0
                .get(b"DescendantFonts")
                .ok()
                .and_then(|object| deref(&document, object))
                .and_then(|object| object.as_array().ok())
                .expect("descendants");
            let cid_font = deref(&document, &descendants[0])
                .and_then(|object| object.as_dict().ok())
                .expect("CID font");
            let descriptor = cid_font
                .get(b"FontDescriptor")
                .ok()
                .and_then(|object| deref(&document, object))
                .and_then(|object| object.as_dict().ok())
                .expect("descriptor");
            let font_file = descriptor
                .get(b"FontFile2")
                .ok()
                .and_then(|object| deref(&document, object))
                .and_then(|object| object.as_stream().ok())
                .expect("FontFile2")
                .decompressed_content()?;
            let face = ttf_parser::Face::parse(&font_file, 0)?;
            let cid_map = cid_font
                .get(b"CIDToGIDMap")
                .ok()
                .and_then(|object| deref(&document, object))
                .and_then(|object| object.as_stream().ok())
                .expect("CIDToGIDMap")
                .decompressed_content()?;
            let widths = cid_font
                .get(b"W")
                .ok()
                .and_then(|object| deref(&document, object))
                .and_then(|object| object.as_array().ok())
                .expect("W");
            let extracted = decode(appearance, &unicode);
            println!("page {} annotation {id}", page_number - 1);
            println!(
                "  font resource /{} -> object {font_id:?} (shared count {})",
                String::from_utf8_lossy(&font_name),
                seen_fonts[&font_id]
            );
            println!(
                "  Type0 Identity-H, CIDFontType2, {} glyphs, FontFile2 {} bytes, CIDToGIDMap {} CIDs, /W {} entries, ToUnicode {} entries",
                face.number_of_glyphs(),
                font_file.len(),
                cid_map.len() / 2,
                widths.len(),
                unicode.len()
            );
            println!("  /Contents : {contents:?}");
            println!("  appearance: {extracted:?}");
            println!("  match     : {}", extracted == contents);
        }
    }
    println!("distinct font objects: {}", seen_fonts.len());
    Ok(())
}
