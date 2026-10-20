//! Evidence test for the CJK appearance font.
//!
//! It writes two `/FreeText` annotations into a copy of a committed fixture and checks the
//! structure a viewer needs: one shared Type0/Identity-H font, a CIDFontType2 descendant with
//! `/W`, `CIDToGIDMap` and `FontFile2`, a `/ToUnicode` CMap, and a subset that contains only the
//! glyphs the two text boxes use. It also decodes the appearance stream through that CMap and
//! compares the result with the exact input and with `/Contents`.
//!
//! Run with PDFium available:
//! `LYRA_READER_PDFIUM_PATH=vendor/pdfium/lib/libpdfium.dylib \
//!  cargo test -p lyra-reader-pdfium --test cjk_appearance -- --nocapture`

use lopdf::{Dictionary, Document, Object, ObjectId, Stream};
use lyra_reader_core::{AnnotationAlignment, PageIndex, Rect};
use lyra_reader_pdfium::{SaveMode, WriteAnnotation, WriteAnnotationKind, save_annotated_pdf};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

const CHINESE: &str = "中文 α";
const JAPANESE: &str = "β 日本語";

fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/outlined.pdf")
        .canonicalize()
        .expect("the committed fixture exists")
}

fn scratch() -> PathBuf {
    // The two tests in this binary run in parallel. A clock-derived suffix alone is not unique
    // on a runner whose clock ticks coarsely: both tests can sample the same nanosecond, share
    // a scratch directory, and then one test's cleanup removes the other's saved PDF. The
    // write-back's `TempFile::nonce` pairs its clock with a counter for the same reason.
    static SEQUENCE: AtomicU64 = AtomicU64::new(0);
    let unique = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("clock")
        .as_nanos();
    let sequence = SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let path = std::env::temp_dir().join(format!(
        "lyra-reader-cjk-appearance-{}-{unique}-{sequence}",
        std::process::id()
    ));
    std::fs::create_dir_all(&path).expect("create scratch directory");
    path
}

fn annotation(id: &str, text: &str, y: f64) -> WriteAnnotation {
    WriteAnnotation {
        id: id.to_string(),
        page: PageIndex(1),
        kind: WriteAnnotationKind::FreeText,
        rect: Rect::new(72.0, y, 440.0, 64.0),
        quads: Vec::new(),
        ink_paths: Vec::new(),
        line: None,
        line_arrow: false,
        stamp_style: None,
        stamp_image: None,
        border_width: 0.0,
        font_size: 14.0,
        alignment: AnnotationAlignment::Left,
        color: [20, 20, 20],
        opacity: 1.0,
        contents: Some(text.to_string()),
        author: Some("LyraReader CJK test".to_string()),
        modified: Some("D:20261018010000-07'00'".to_string()),
    }
}

fn deref<'a>(document: &'a Document, object: &'a Object) -> Option<&'a Object> {
    document.dereference(object).ok().map(|(_, object)| object)
}

fn find_annotation<'a>(document: &'a Document, id: &str) -> &'a Dictionary {
    for (_, page_id) in document.get_pages() {
        let Ok(page) = document.get_dictionary(page_id) else {
            continue;
        };
        let Some(annots) = page
            .get(b"Annots")
            .ok()
            .and_then(|object| deref(document, object))
            .and_then(|object| object.as_array().ok())
        else {
            continue;
        };
        for object in annots {
            let Some(dictionary) = deref(document, object).and_then(|object| object.as_dict().ok())
            else {
                continue;
            };
            if dictionary
                .get(b"NM")
                .ok()
                .and_then(|object| deref(document, object))
                .and_then(|object| object.as_str().ok())
                == Some(id.as_bytes())
            {
                return dictionary;
            }
        }
    }
    panic!("annotation {id:?} is not in the saved file");
}

fn appearance_stream<'a>(document: &'a Document, annotation: &'a Dictionary) -> &'a Stream {
    annotation
        .get(b"AP")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_dict().ok())
        .and_then(|ap| ap.get(b"N").ok())
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_stream().ok())
        .expect("the annotation has an appearance stream")
}

fn font_reference(document: &Document, appearance: &Stream) -> ObjectId {
    let resources = appearance
        .dict
        .get(b"Resources")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_dict().ok())
        .expect("/Resources");
    let fonts = resources
        .get(b"Font")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_dict().ok())
        .expect("/Font resources");
    assert_eq!(fonts.len(), 1, "one font resource per appearance");
    match fonts.iter().next().expect("font entry").1 {
        Object::Reference(id) => *id,
        other => panic!("font resource is not an indirect reference: {other:?}"),
    }
}

fn dict<'a>(document: &'a Document, dictionary: &'a Dictionary, key: &[u8]) -> &'a Dictionary {
    dictionary
        .get(key)
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_dict().ok())
        .unwrap_or_else(|| panic!("missing dictionary /{}", String::from_utf8_lossy(key)))
}

fn array<'a>(document: &'a Document, dictionary: &'a Dictionary, key: &[u8]) -> &'a Vec<Object> {
    dictionary
        .get(key)
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_array().ok())
        .unwrap_or_else(|| panic!("missing array /{}", String::from_utf8_lossy(key)))
}

fn stream<'a>(document: &'a Document, dictionary: &'a Dictionary, key: &[u8]) -> &'a Stream {
    dictionary
        .get(key)
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_stream().ok())
        .unwrap_or_else(|| panic!("missing stream /{}", String::from_utf8_lossy(key)))
}

fn parse_tounicode(bytes: &[u8]) -> HashMap<u16, char> {
    let text = std::str::from_utf8(bytes).expect("the ToUnicode CMap is ASCII");
    let mut map = HashMap::new();
    let mut in_char_block = false;
    for line in text.lines() {
        let line = line.trim();
        if line.ends_with("beginbfchar") {
            in_char_block = true;
            continue;
        }
        if line == "endbfchar" {
            in_char_block = false;
            continue;
        }
        if !in_char_block {
            continue;
        }
        let mut parts = line.split_whitespace();
        let source = parts
            .next()
            .expect("CID")
            .trim_matches(|c| c == '<' || c == '>');
        let destination = parts
            .next()
            .expect("UTF-16BE destination")
            .trim_matches(|c| c == '<' || c == '>');
        let cid = u16::from_str_radix(source, 16).expect("hex CID");
        assert_eq!(
            destination.len() % 4,
            0,
            "UTF-16 code units are 4 hex digits"
        );
        let units: Vec<u16> = destination
            .as_bytes()
            .chunks(4)
            .map(|chunk| {
                u16::from_str_radix(std::str::from_utf8(chunk).expect("hex"), 16)
                    .expect("hex code unit")
            })
            .collect();
        let decoded = String::from_utf16(&units).expect("valid UTF-16");
        let character = decoded.chars().next().expect("one character");
        assert!(map.insert(cid, character).is_none(), "duplicate CID {cid}");
    }
    map
}

fn decode_appearance(bytes: &[u8], unicode: &HashMap<u16, char>) -> String {
    let mut decoded = String::new();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'<' && bytes.get(index + 1) != Some(&b'<') {
            let start = index + 1;
            let Some(relative_end) = bytes[start..].iter().position(|byte| *byte == b'>') else {
                break;
            };
            let end = start + relative_end;
            let hex = std::str::from_utf8(&bytes[start..end]).expect("hex string");
            assert_eq!(hex.len() % 4, 0, "two bytes per Identity-H CID");
            for chunk in hex.as_bytes().chunks(4) {
                let cid = u16::from_str_radix(std::str::from_utf8(chunk).expect("hex"), 16)
                    .expect("hex CID");
                decoded.push(
                    *unicode
                        .get(&cid)
                        .unwrap_or_else(|| panic!("CID {cid} has no ToUnicode entry")),
                );
            }
            index = end + 1;
        } else {
            index += 1;
        }
    }
    decoded
}

/// Decode a PDF text string: UTF-16BE/LE with a BOM, otherwise PDFDocEncoding (ASCII for the
/// strings this test writes with `/NM`, and Latin-1 for the ASCII subset).
fn pdf_text(bytes: &[u8]) -> String {
    if let Some(rest) = bytes.strip_prefix(&[0xFE, 0xFF]) {
        let units: Vec<u16> = rest
            .chunks(2)
            .map(|chunk| u16::from_be_bytes([chunk[0], chunk[1]]))
            .collect();
        return String::from_utf16(&units).expect("valid UTF-16BE PDF string");
    }
    if let Some(rest) = bytes.strip_prefix(&[0xFF, 0xFE]) {
        let units: Vec<u16> = rest
            .chunks(2)
            .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]))
            .collect();
        return String::from_utf16(&units).expect("valid UTF-16LE PDF string");
    }
    bytes.iter().map(|byte| char::from(*byte)).collect()
}

fn verify_shared_font(path: &Path, expected_texts: &[(&str, &str)]) {
    let document = Document::load(path).expect("reopen the saved PDF");
    let mut shared_font: Option<ObjectId> = None;
    let mut total_glyphs = None;
    for (id, expected) in expected_texts {
        let annotation = find_annotation(&document, id);
        let contents = annotation
            .get(b"Contents")
            .ok()
            .and_then(|object| deref(&document, object))
            .and_then(|object| object.as_str().ok())
            .expect("/Contents");
        assert_eq!(
            pdf_text(contents),
            *expected,
            "/Contents keeps the exact input string"
        );

        let appearance = appearance_stream(&document, annotation);
        let font_id = font_reference(&document, appearance);
        if let Some(shared) = shared_font {
            assert_eq!(font_id, shared, "both text boxes share one font resource");
        } else {
            shared_font = Some(font_id);
        }

        let type0 = document.get_dictionary(font_id).expect("font object");
        assert_eq!(
            type0
                .get(b"Subtype")
                .ok()
                .and_then(|object| object.as_name().ok()),
            Some(b"Type0".as_slice())
        );
        assert_eq!(
            type0
                .get(b"Encoding")
                .ok()
                .and_then(|object| object.as_name().ok()),
            Some(b"Identity-H".as_slice())
        );
        let unicode = parse_tounicode(
            &stream(&document, type0, b"ToUnicode")
                .decompressed_content()
                .expect("ToUnicode"),
        );
        assert!(!unicode.is_empty());

        let descendants = array(&document, type0, b"DescendantFonts");
        let cid_font = deref(&document, &descendants[0])
            .and_then(|object| object.as_dict().ok())
            .expect("CID font");
        assert_eq!(
            cid_font
                .get(b"Subtype")
                .ok()
                .and_then(|object| object.as_name().ok()),
            Some(b"CIDFontType2".as_slice())
        );
        assert!(!array(&document, cid_font, b"W").is_empty(), "/W widths");
        let cid_map = stream(&document, cid_font, b"CIDToGIDMap")
            .decompressed_content()
            .expect("CIDToGIDMap");
        assert_eq!(cid_map.len() % 2, 0);
        let descriptor = dict(&document, cid_font, b"FontDescriptor");
        let font_file = stream(&document, descriptor, b"FontFile2")
            .decompressed_content()
            .expect("FontFile2");
        assert!(!font_file.is_empty());
        let face = ttf_parser::Face::parse(&font_file, 0).expect("the embedded font parses");
        if let Some(glyphs) = total_glyphs {
            assert_eq!(face.number_of_glyphs(), glyphs);
        } else {
            total_glyphs = Some(face.number_of_glyphs());
        }

        // CIDToGIDMap must address glyphs inside the embedded subset.
        for chunk in cid_map.chunks(2) {
            let glyph = u16::from_be_bytes([chunk[0], chunk[1]]);
            if glyph != 0 {
                assert!(glyph < face.number_of_glyphs());
            }
        }

        let decoded = decode_appearance(
            &appearance
                .decompressed_content()
                .expect("appearance content"),
            &unicode,
        );
        assert_eq!(
            decoded, *expected,
            "text extracted through the appearance's ToUnicode equals the input"
        );
    }

    let used: HashSet<char> = expected_texts
        .iter()
        .flat_map(|(_, text)| text.chars())
        .collect();
    let glyphs = total_glyphs.expect("at least one font");
    assert_eq!(
        glyphs as usize,
        used.len() + 1,
        "the subset is .notdef plus exactly the glyphs the text boxes use"
    );
    eprintln!("shared Type0 subset: {glyphs} glyphs for {used:?}");
}

#[test]
fn free_text_appearance_is_a_shared_type0_subset_with_tounicode() {
    if !lyra_reader_pdfium::is_available() {
        eprintln!("skipping: PDFium unavailable");
        return;
    }
    let directory = scratch();
    let destination = directory.join("cjk.pdf");
    let source = fixture();

    // The font is loaded independently of PDFium; this asserts the path the test binary uses.
    let coverage = lyra_reader_pdfium::appearance_coverage(CHINESE).expect("coverage");
    assert!(coverage.missing.is_empty(), "Chinese sample is covered");
    assert!(coverage.glyph_count > 10_000);

    let chinese = annotation("cjk-chinese", CHINESE, 420.0);
    let japanese = annotation("cjk-japanese", JAPANESE, 330.0);
    let report = save_annotated_pdf(
        &source,
        &destination,
        &[chinese, japanese],
        &[],
        None,
        SaveMode::Copy,
    )
    .expect("write two CJK text boxes");
    eprintln!(
        "appended {} bytes for two text boxes",
        report.appended_bytes
    );

    verify_shared_font(
        &destination,
        &[("cjk-chinese", CHINESE), ("cjk-japanese", JAPANESE)],
    );

    std::fs::remove_dir_all(&directory).ok();
}

#[test]
fn a_character_outside_the_font_uses_notdef_and_keeps_extraction_exact() {
    if !lyra_reader_pdfium::is_available() {
        eprintln!("skipping: PDFium unavailable");
        return;
    }
    let directory = scratch();
    let destination = directory.join("fallback.pdf");
    let source = fixture();
    let text = "中😀文";
    let annotation = annotation("cjk-fallback", text, 420.0);
    save_annotated_pdf(
        &source,
        &destination,
        &[annotation],
        &[],
        None,
        SaveMode::Copy,
    )
    .expect("write the fallback text box");

    let document = Document::load(&destination).expect("reopen");
    let dictionary = find_annotation(&document, "cjk-fallback");
    let appearance = appearance_stream(&document, dictionary);
    let type0 = document
        .get_dictionary(font_reference(&document, appearance))
        .expect("font");
    let unicode = parse_tounicode(
        &stream(&document, type0, b"ToUnicode")
            .decompressed_content()
            .expect("ToUnicode"),
    );
    let decoded = decode_appearance(
        &appearance.decompressed_content().expect("appearance"),
        &unicode,
    );
    assert_eq!(decoded, text, "the emoji is still extracted exactly");

    let descendants = array(&document, type0, b"DescendantFonts");
    let cid_font = deref(&document, &descendants[0])
        .and_then(|object| object.as_dict().ok())
        .expect("CID font");
    let cid_map = stream(&document, cid_font, b"CIDToGIDMap")
        .decompressed_content()
        .expect("CIDToGIDMap");
    let emoji_cid = unicode
        .iter()
        .find_map(|(cid, character)| (*character == '😀').then_some(*cid))
        .expect("the emoji has a CID");
    assert_eq!(
        u16::from_be_bytes([
            cid_map[usize::from(emoji_cid) * 2],
            cid_map[usize::from(emoji_cid) * 2 + 1]
        ]),
        0,
        "the emoji is encoded through .notdef, not a question-mark glyph"
    );

    let contents = dictionary
        .get(b"Contents")
        .ok()
        .and_then(|object| deref(&document, object))
        .and_then(|object| object.as_str().ok())
        .expect("Contents");
    assert_eq!(pdf_text(contents), text);

    let descriptor = dict(&document, cid_font, b"FontDescriptor");
    let font_file = stream(&document, descriptor, b"FontFile2")
        .decompressed_content()
        .expect("FontFile2");
    let face = ttf_parser::Face::parse(&font_file, 0).expect("subset font");
    assert_eq!(
        face.number_of_glyphs(),
        3,
        ".notdef plus 中 and 文; the emoji adds a CID but no glyph"
    );

    std::fs::remove_dir_all(&directory).ok();
}
