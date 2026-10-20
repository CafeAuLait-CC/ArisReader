//! Font metrics and character codes for the read-only text-edit analysis.
//!
//! Nothing here writes: it reads a font dictionary and answers two questions the safety rules
//! need — *how wide is a character code* (`/Widths` or `/W`) and *which Unicode character does
//! this code mean* (`/ToUnicode`, `/Encoding` with `/Differences`, or a built-in base encoding).
//! A font that cannot answer both is reported as a refusal on every run that uses it.

use lopdf::{Dictionary, Document, Object, Stream};
use std::collections::HashMap;

/// Upper bound on a single CMap range, so a corrupt `/ToUnicode` cannot expand into a huge map.
const MAX_CMAP_RANGE: u32 = 65_536;

/// How a code is interpreted inside a string.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FontSubtype {
    /// One byte per code (`/Type1`, `/TrueType`, `/MMType1`).
    Simple,
    /// `/Type0`; this analysis accepts only two-byte Identity-H/V code spaces.
    Type0,
    /// `/Type3` glyph procedures; metrics live in a `/FontMatrix` this analysis does not model.
    Type3,
    /// A subtype the analysis does not know.
    Other,
}

/// Where the glyph advance widths came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WidthSource {
    /// A simple font's `/FirstChar` + `/Widths` (plus `/MissingWidth` when stated).
    SimpleWidths,
    /// A composite font's `/W` with its `/DW` default.
    Type0W,
    /// No width table this analysis can compute.
    Unavailable,
}

/// A reason a font cannot be used for replacement. The first applicable problem wins.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FontProblem {
    Type3,
    UnsupportedSubtype,
    /// The `/Encoding` is an embedded CMap, a vertical writing mode, or an unknown name.
    UnsupportedEncoding,
    /// A composite font without `/ToUnicode` (there is no other code-to-Unicode bridge here).
    MissingUnicodeMap,
    /// `/ToUnicode` is malformed; it cannot be trusted to describe the file.
    MalformedToUnicode,
    /// The width table is missing, malformed, or a code has no stated width.
    MissingWidths,
}

/// The glyph advances of one font, in 1/1000 text-space units.
#[derive(Clone, Debug, Default)]
pub struct Widths {
    simple_first: u32,
    simple: Vec<f64>,
    simple_missing: Option<f64>,
    type0_default: f64,
    type0: HashMap<u32, f64>,
    source: Option<WidthSource>,
}

impl Widths {
    fn source(&self) -> WidthSource {
        self.source.unwrap_or(WidthSource::Unavailable)
    }

    /// The advance for `code`, or `None` when the file does not state one. A `None` refuses the
    /// run instead of guessing a width.
    pub fn get(&self, code: u32) -> Option<f64> {
        match self.source? {
            WidthSource::SimpleWidths => {
                if code >= self.simple_first {
                    let offset = (code - self.simple_first) as usize;
                    if let Some(width) = self.simple.get(offset) {
                        return Some(*width);
                    }
                }
                self.simple_missing
            }
            WidthSource::Type0W => self.type0.get(&code).copied().or(Some(self.type0_default)),
            WidthSource::Unavailable => None,
        }
    }
}

/// Everything the analysis needs to know about one font resource.
#[derive(Clone, Debug)]
pub struct FontData {
    pub base_font: String,
    pub subtype: FontSubtype,
    pub embedded: bool,
    pub subset: bool,
    pub vertical: bool,
    pub has_to_unicode: bool,
    pub encoding_label: String,
    pub code_bytes: u8,
    pub widths: Widths,
    pub problem: Option<FontProblem>,
    /// Code -> rendered Unicode text. Multi-character values are ligatures (`/fi`).
    pub code_to_text: HashMap<u32, String>,
    /// Single-character Unicode -> code, for building a replacement string with existing glyphs.
    pub to_code: HashMap<char, u32>,
}

impl FontData {
    pub fn unknown(name: String) -> Self {
        Self {
            base_font: name,
            subtype: FontSubtype::Other,
            embedded: false,
            subset: false,
            vertical: false,
            has_to_unicode: false,
            encoding_label: "unresolved resource".into(),
            code_bytes: 1,
            widths: Widths::default(),
            problem: Some(FontProblem::UnsupportedSubtype),
            code_to_text: HashMap::new(),
            to_code: HashMap::new(),
        }
    }

    pub fn width_source(&self) -> WidthSource {
        self.widths.source()
    }

    /// The characters a replacement may use without adding a new font.
    ///
    /// For a subset font, `observed` is the set of code points the page actually drew with this
    /// font and whose decoded character agreed with PDFium: those glyphs are unquestionably in
    /// the embedded subset, and the code is the one that reached the page. A complete font may
    /// use its whole encoding.
    pub fn replacement_chars(&self, observed: Option<&HashMap<char, u32>>) -> Vec<char> {
        if self.subset {
            let Some(observed) = observed else {
                return Vec::new();
            };
            return observed
                .iter()
                .filter(|(character, code)| {
                    self.code_to_text.get(code).is_some_and(|text| {
                        let mut characters = text.chars();
                        characters.next() == Some(**character) && characters.next().is_none()
                    }) && self.widths.get(**code).is_some()
                })
                .map(|(character, _)| *character)
                .collect();
        }
        self.to_code
            .iter()
            .filter(|(_, code)| self.widths.get(**code).is_some())
            .map(|(character, _)| *character)
            .collect()
    }
}

/// Resolve a direct or indirect dictionary.
fn as_dictionary<'a>(document: &'a Document, object: &'a Object) -> Option<&'a Dictionary> {
    match object {
        Object::Dictionary(dictionary) => Some(dictionary),
        Object::Reference(id) => document.get_dictionary(*id).ok(),
        _ => None,
    }
}

/// Resolve a direct or indirect stream.
fn as_stream<'a>(document: &'a Document, object: &'a Object) -> Option<&'a Stream> {
    match object {
        Object::Stream(stream) => Some(stream),
        Object::Reference(id) => document
            .get_object(*id)
            .ok()
            .and_then(|object| object.as_stream().ok()),
        _ => None,
    }
}

fn name_string(object: &Object) -> Option<String> {
    object
        .as_name()
        .ok()
        .map(|name| String::from_utf8_lossy(name).into_owned())
}

fn number(object: &Object) -> Option<f64> {
    match object {
        Object::Integer(value) => Some(*value as f64),
        Object::Real(value) => Some(f64::from(*value)),
        _ => None,
    }
}

fn integer(object: &Object) -> Option<i64> {
    match object {
        Object::Integer(value) => Some(*value),
        Object::Real(value) => Some(f64::from(*value) as i64),
        _ => None,
    }
}

fn resolve_array<'a>(document: &'a Document, object: &'a Object) -> Option<&'a Vec<Object>> {
    match object {
        Object::Array(array) => Some(array),
        Object::Reference(id) => document
            .get_object(*id)
            .ok()
            .and_then(|object| object.as_array().ok()),
        _ => None,
    }
}

fn stream_content(stream: &Stream) -> Option<Vec<u8>> {
    stream
        .decompressed_content()
        .ok()
        .or_else(|| Some(stream.content.clone()))
}

/// Read one font resource dictionary.
pub fn read_font(document: &Document, dictionary: &Dictionary) -> FontData {
    let subtype_name = dictionary
        .get(b"Subtype")
        .ok()
        .and_then(name_string)
        .unwrap_or_default();
    let subtype = match subtype_name.as_str() {
        "Type0" => FontSubtype::Type0,
        "Type3" => FontSubtype::Type3,
        "Type1" | "MMType1" | "TrueType" => FontSubtype::Simple,
        _ => FontSubtype::Other,
    };
    let base_font = dictionary
        .get(b"BaseFont")
        .ok()
        .and_then(name_string)
        .unwrap_or_else(|| "(unnamed)".into());
    let subset = is_subset_name(&base_font);
    if subtype == FontSubtype::Type3 {
        return unsupported(base_font, subtype, FontProblem::Type3);
    }
    if subtype == FontSubtype::Other {
        return unsupported(base_font, subtype, FontProblem::UnsupportedSubtype);
    }

    let (descriptor, descendant, top_encoding) = match subtype {
        FontSubtype::Type0 => {
            let descendants = dictionary
                .get(b"DescendantFonts")
                .ok()
                .and_then(|value| resolve_array(document, value));
            let descendant = descendants
                .and_then(|array| array.first())
                .and_then(|value| as_dictionary(document, value));
            let descriptor = descendant
                .and_then(|value| value.get(b"FontDescriptor").ok())
                .and_then(|value| as_dictionary(document, value));
            (descriptor, descendant, dictionary.get(b"Encoding").ok())
        }
        FontSubtype::Simple => {
            let descriptor = dictionary
                .get(b"FontDescriptor")
                .ok()
                .and_then(|value| as_dictionary(document, value));
            (descriptor, None, dictionary.get(b"Encoding").ok())
        }
        FontSubtype::Type3 | FontSubtype::Other => unreachable!(),
    };

    let embedded = descriptor
        .map(|descriptor| {
            descriptor.has(b"FontFile")
                || descriptor.has(b"FontFile2")
                || descriptor.has(b"FontFile3")
        })
        .unwrap_or(false);

    let (mut widths, width_problem) = read_widths(document, dictionary, descendant, subtype);
    if width_problem.is_some() {
        widths.source = None;
    }

    let to_unicode = dictionary
        .get(b"ToUnicode")
        .ok()
        .and_then(|value| as_stream(document, value))
        .and_then(stream_content)
        .map(|content| parse_to_unicode(&content));
    let has_to_unicode = to_unicode.is_some();

    let mut problem = width_problem;
    let mut vertical = false;
    let encoding_label: String;
    let mut code_to_text: HashMap<u32, String> = HashMap::new();

    if subtype == FontSubtype::Type0 {
        let (encoding_name, encoding_problem) = read_identity_h_encoding(document, top_encoding);
        vertical = encoding_name.as_deref() == Some("Identity-V");
        encoding_label = encoding_name.unwrap_or_else(|| "embedded/unknown CMap".into());
        if encoding_problem.is_some() {
            problem = problem.or(encoding_problem);
        }
        if descendant
            .and_then(|value| value.get(b"WMode").ok())
            .and_then(integer)
            == Some(1)
        {
            vertical = true;
        }
        if let Some(map) = &to_unicode {
            if map.ok {
                for (code, text) in &map.map {
                    if (2..=2).contains(&map.source_bytes_for(*code)) {
                        code_to_text.insert(*code, text.clone());
                    }
                }
            } else {
                problem = problem.or(Some(FontProblem::MalformedToUnicode));
            }
        } else {
            problem = problem.or(Some(FontProblem::MissingUnicodeMap));
        }
        if problem.is_none() && code_to_text.is_empty() {
            problem = Some(FontProblem::MissingUnicodeMap);
        }
    } else {
        // Simple font: ToUnicode first, then /Differences, then the base encoding.
        if let Some(map) = &to_unicode {
            if map.ok {
                for (code, text) in &map.map {
                    if *code <= 0xFF && map.source_bytes_for(*code) == 1 {
                        code_to_text.insert(*code, text.clone());
                    }
                }
            } else {
                problem = problem.or(Some(FontProblem::MalformedToUnicode));
            }
        }
        let (differences, base, label, encoding_problem) =
            read_simple_encoding(document, top_encoding);
        encoding_label = label;
        if encoding_problem.is_some() {
            problem = problem.or(encoding_problem);
        }
        for code in 0u32..=0xFF {
            if code_to_text.contains_key(&code) {
                continue;
            }
            if let Some(text) = differences.get(&code) {
                code_to_text.insert(code, text.clone());
                continue;
            }
            if let Some(character) = base.and_then(|encoding| encoding_char(encoding, code as u8)) {
                code_to_text.insert(code, character.to_string());
            }
        }
        if code_to_text.is_empty() {
            problem = problem.or(Some(FontProblem::MissingUnicodeMap));
        }
    }

    let mut to_code = HashMap::new();
    for (code, text) in &code_to_text {
        let mut characters = text.chars();
        if let (Some(character), None) = (characters.next(), characters.next()) {
            to_code.entry(character).or_insert(*code);
        }
    }
    // Prefer the lowest code deterministically, independent of hash-map iteration order.
    let mut by_char: Vec<(char, u32)> = to_code.into_iter().collect();
    by_char.sort_by_key(|(character, code)| (*character, *code));
    let mut to_code = HashMap::new();
    for (character, code) in by_char {
        to_code.entry(character).or_insert(code);
    }

    FontData {
        base_font,
        subtype,
        embedded,
        subset,
        vertical,
        has_to_unicode,
        encoding_label,
        code_bytes: if subtype == FontSubtype::Type0 { 2 } else { 1 },
        widths,
        problem,
        code_to_text,
        to_code,
    }
}

fn unsupported(base_font: String, subtype: FontSubtype, problem: FontProblem) -> FontData {
    FontData {
        base_font,
        subtype,
        embedded: false,
        subset: false,
        vertical: false,
        has_to_unicode: false,
        encoding_label: "unsupported".into(),
        code_bytes: 1,
        widths: Widths::default(),
        problem: Some(problem),
        code_to_text: HashMap::new(),
        to_code: HashMap::new(),
    }
}

fn is_subset_name(name: &str) -> bool {
    let bytes = name.as_bytes();
    bytes.len() > 7 && bytes[6] == b'+' && bytes[..6].iter().all(u8::is_ascii_uppercase)
}

fn read_widths(
    document: &Document,
    dictionary: &Dictionary,
    descendant: Option<&Dictionary>,
    subtype: FontSubtype,
) -> (Widths, Option<FontProblem>) {
    match subtype {
        FontSubtype::Simple => {
            let first = dictionary.get(b"FirstChar").ok().and_then(integer);
            let array = dictionary
                .get(b"Widths")
                .ok()
                .and_then(|value| resolve_array(document, value));
            let missing = dictionary
                .get(b"FontDescriptor")
                .ok()
                .and_then(|value| as_dictionary(document, value))
                .and_then(|value| value.get(b"MissingWidth").ok())
                .and_then(number);
            match (first, array) {
                (Some(first), Some(array)) if (0..=255).contains(&first) => {
                    let mut widths = Vec::with_capacity(array.len());
                    for value in array {
                        let Some(width) = number(value) else {
                            return (Widths::default(), Some(FontProblem::MissingWidths));
                        };
                        if !width.is_finite() {
                            return (Widths::default(), Some(FontProblem::MissingWidths));
                        }
                        widths.push(width);
                    }
                    (
                        Widths {
                            simple_first: first as u32,
                            simple: widths,
                            simple_missing: missing,
                            type0_default: 0.0,
                            type0: HashMap::new(),
                            source: Some(WidthSource::SimpleWidths),
                        },
                        None,
                    )
                }
                _ => (Widths::default(), Some(FontProblem::MissingWidths)),
            }
        }
        FontSubtype::Type0 => {
            let Some(descendant) = descendant else {
                return (Widths::default(), Some(FontProblem::MissingWidths));
            };
            let default = descendant
                .get(b"DW")
                .ok()
                .and_then(number)
                .unwrap_or(1000.0);
            let array = descendant
                .get(b"W")
                .ok()
                .and_then(|value| resolve_array(document, value));
            let mut widths = HashMap::new();
            if let Some(array) = array {
                let mut index = 0;
                while index < array.len() {
                    let Some(first) = integer(&array[index]) else {
                        return (Widths::default(), Some(FontProblem::MissingWidths));
                    };
                    index += 1;
                    if index >= array.len() {
                        return (Widths::default(), Some(FontProblem::MissingWidths));
                    }
                    match &array[index] {
                        Object::Array(values) => {
                            for (offset, value) in values.iter().enumerate() {
                                let Some(width) = number(value) else {
                                    return (Widths::default(), Some(FontProblem::MissingWidths));
                                };
                                widths.insert(first as u32 + offset as u32, width);
                            }
                            index += 1;
                        }
                        other => {
                            let Some(last) = integer(other) else {
                                return (Widths::default(), Some(FontProblem::MissingWidths));
                            };
                            index += 1;
                            let Some(width) = array.get(index).and_then(number) else {
                                return (Widths::default(), Some(FontProblem::MissingWidths));
                            };
                            index += 1;
                            if last < first || (last - first) as u32 > MAX_CMAP_RANGE {
                                return (Widths::default(), Some(FontProblem::MissingWidths));
                            }
                            for code in first..=last {
                                widths.insert(code as u32, width);
                            }
                        }
                    }
                }
            }
            (
                Widths {
                    simple_first: 0,
                    simple: Vec::new(),
                    simple_missing: None,
                    type0_default: default,
                    type0: widths,
                    source: Some(WidthSource::Type0W),
                },
                None,
            )
        }
        FontSubtype::Type3 | FontSubtype::Other => {
            (Widths::default(), Some(FontProblem::MissingWidths))
        }
    }
}

fn read_identity_h_encoding(
    _document: &Document,
    encoding: Option<&Object>,
) -> (Option<String>, Option<FontProblem>) {
    match encoding {
        Some(Object::Name(name)) => {
            let name = String::from_utf8_lossy(name).into_owned();
            if name == "Identity-H" || name == "Identity-V" {
                (Some(name), None)
            } else {
                (Some(name), Some(FontProblem::UnsupportedEncoding))
            }
        }
        Some(Object::Reference(_) | Object::Dictionary(_)) => (
            Some("embedded CMap".into()),
            Some(FontProblem::UnsupportedEncoding),
        ),
        Some(_) | None => (None, Some(FontProblem::UnsupportedEncoding)),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum BaseEncoding {
    Standard,
    WinAnsi,
    MacRoman,
    PdfDoc,
}

fn read_simple_encoding(
    document: &Document,
    encoding: Option<&Object>,
) -> (
    HashMap<u32, String>,
    Option<BaseEncoding>,
    String,
    Option<FontProblem>,
) {
    let mut differences: HashMap<u32, String> = HashMap::new();
    let mut base = None;
    let mut label = "builtin".to_string();
    let mut problem = None;
    let (base_object, differences_object) = match encoding {
        Some(Object::Name(_)) | None => (encoding, None),
        Some(Object::Dictionary(dictionary)) => (
            dictionary.get(b"BaseEncoding").ok(),
            dictionary.get(b"Differences").ok(),
        ),
        Some(Object::Reference(id)) => match document.get_dictionary(*id) {
            Ok(dictionary) => (
                dictionary.get(b"BaseEncoding").ok(),
                dictionary.get(b"Differences").ok(),
            ),
            Err(_) => (None, None),
        },
        Some(_) => (None, None),
    };
    if let Some(value) = base_object
        && let Ok(name) = value.as_name()
    {
        {
            let name = String::from_utf8_lossy(name);
            base = match name.as_ref() {
                "StandardEncoding" => Some(BaseEncoding::Standard),
                "WinAnsiEncoding" => Some(BaseEncoding::WinAnsi),
                "MacRomanEncoding" => Some(BaseEncoding::MacRoman),
                "PDFDocEncoding" => Some(BaseEncoding::PdfDoc),
                _ => {
                    problem = Some(FontProblem::UnsupportedEncoding);
                    None
                }
            };
            label = base
                .map(|encoding| encoding.label().to_string())
                .unwrap_or_else(|| name.into_owned());
        }
    }
    if let Some(value) = differences_object {
        let array = match value {
            Object::Array(array) => Some(array),
            Object::Reference(id) => document
                .get_object(*id)
                .ok()
                .and_then(|object| object.as_array().ok()),
            _ => None,
        };
        if let Some(array) = array {
            let mut code = 0u32;
            for value in array {
                if let Some(next) = integer(value) {
                    code = next as u32;
                    continue;
                }
                if let Ok(name) = value.as_name() {
                    let name = String::from_utf8_lossy(name);
                    if let Some(text) = glyph_name_to_unicode(name.as_bytes()) {
                        differences.insert(code, text);
                    }
                    code = code.saturating_add(1);
                }
            }
        }
    }
    if !differences.is_empty() {
        label = format!("{label} + {} difference(s)", differences.len());
    }
    (differences, base, label, problem)
}

impl BaseEncoding {
    fn label(self) -> &'static str {
        match self {
            Self::Standard => "StandardEncoding",
            Self::WinAnsi => "WinAnsiEncoding",
            Self::MacRoman => "MacRomanEncoding",
            Self::PdfDoc => "PDFDocEncoding",
        }
    }
}

fn encoding_char(encoding: BaseEncoding, code: u8) -> Option<char> {
    match encoding {
        BaseEncoding::WinAnsi => win_ansi(code),
        BaseEncoding::MacRoman => mac_roman(code),
        BaseEncoding::PdfDoc | BaseEncoding::Standard => latinish(code),
    }
}

fn latinish(code: u8) -> Option<char> {
    match code {
        0x20..=0x7E | 0xA0..=0xFF => char::from_u32(code as u32),
        _ => None,
    }
}

fn win_ansi(code: u8) -> Option<char> {
    const HIGH: [u16; 32] = [
        0x20AC, 0x0000, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160,
        0x2039, 0x0152, 0x0000, 0x017D, 0x0000, 0x0000, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022,
        0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x0000, 0x017E, 0x0178,
    ];
    match code {
        0x20..=0x7E | 0xA0..=0xFF => char::from_u32(code as u32),
        0x80..=0x9F => char::from_u32(u32::from(HIGH[(code - 0x80) as usize])),
        _ => None,
    }
}

fn mac_roman(code: u8) -> Option<char> {
    const HIGH: [u16; 128] = [
        0x00C4, 0x00C5, 0x00C7, 0x00C9, 0x00D1, 0x00D6, 0x00DC, 0x00E1, 0x00E0, 0x00E2, 0x00E4,
        0x00E3, 0x00E5, 0x00E7, 0x00E9, 0x00E8, 0x00EA, 0x00EB, 0x00ED, 0x00EC, 0x00EE, 0x00EF,
        0x00F1, 0x00F3, 0x00F2, 0x00F4, 0x00F6, 0x00F5, 0x00FA, 0x00F9, 0x00FB, 0x00FC, 0x2020,
        0x00B0, 0x00A2, 0x00A3, 0x00A7, 0x2022, 0x00B6, 0x00DF, 0x00AE, 0x00A9, 0x2122, 0x00B4,
        0x00A8, 0x2260, 0x00C6, 0x00D8, 0x221E, 0x00B1, 0x2264, 0x2265, 0x00A5, 0x00B5, 0x2202,
        0x2211, 0x220F, 0x03C0, 0x222B, 0x00AA, 0x00BA, 0x03A9, 0x00E6, 0x00F8, 0x00BF, 0x00A1,
        0x00AC, 0x221A, 0x0192, 0x2248, 0x2206, 0x00AB, 0x00BB, 0x2026, 0x00A0, 0x00C0, 0x00C3,
        0x00D5, 0x0152, 0x0153, 0x2013, 0x2014, 0x201C, 0x201D, 0x2018, 0x2019, 0x00F7, 0x25CA,
        0x00FF, 0x0178, 0x2044, 0x20AC, 0x2039, 0x203A, 0xFB01, 0xFB02, 0x2021, 0x00B7, 0x201A,
        0x201E, 0x2030, 0x00C2, 0x00CA, 0x00C1, 0x00CB, 0x00C8, 0x00CD, 0x00CE, 0x00CF, 0x00CC,
        0x00D3, 0x00D4, 0xF8FF, 0x00D2, 0x00DA, 0x00DB, 0x00D9, 0x0131, 0x02C6, 0x02DC, 0x00AF,
        0x02D8, 0x02D9, 0x02DA, 0x00B8, 0x02DD, 0x02DB, 0x02C7,
    ];
    match code {
        0x20..=0x7E => char::from_u32(code as u32),
        0x80..=0xFF => char::from_u32(u32::from(HIGH[(code - 0x80) as usize])),
        _ => None,
    }
}

/// Parse a `/ToUnicode` CMap. Returns `None` for an unreadable stream; the caller then treats the
/// font as lacking a mapping. `bfchar` and `bfrange` are the only sections that matter here.
pub fn parse_to_unicode(data: &[u8]) -> ToUnicodeMap {
    let mut map = ToUnicodeMap::default();
    let mut tokens = Tokens::new(data);
    let mut source_lengths: HashMap<u32, usize> = HashMap::new();
    let mut valid = true;
    while let Some(token) = tokens.next_token() {
        match token {
            Token::Word(word) if word == b"beginbfchar" => loop {
                let Some(first) = tokens.next_token() else {
                    valid = false;
                    break;
                };
                if matches!(first, Token::Word(ref word) if word == b"endbfchar") {
                    break;
                }
                let Token::Hex(source) = first else {
                    continue;
                };
                let Some(Token::Hex(destination)) = tokens.next_token() else {
                    valid = false;
                    break;
                };
                if let Some(text) = utf16_text(&destination) {
                    let code = code_of(&source);
                    source_lengths.entry(code).or_insert(source.len());
                    map.map.insert(code, text);
                } else {
                    valid = false;
                }
            },
            Token::Word(word) if word == b"beginbfrange" => loop {
                let Some(first) = tokens.next_token() else {
                    valid = false;
                    break;
                };
                if matches!(first, Token::Word(ref word) if word == b"endbfrange") {
                    break;
                }
                let Token::Hex(low) = first else {
                    continue;
                };
                let Some(Token::Hex(high)) = tokens.next_token() else {
                    valid = false;
                    break;
                };
                let source_length = low.len();
                let Some(destination) = tokens.next_token() else {
                    valid = false;
                    break;
                };
                let low = code_of(&low);
                let high = code_of(&high);
                if high < low || high - low > MAX_CMAP_RANGE {
                    valid = false;
                    continue;
                }
                match destination {
                    Token::Hex(bytes) => {
                        let Some(first_text) = utf16_text(&bytes) else {
                            valid = false;
                            continue;
                        };
                        let _ = first_text;
                        for offset in 0..=(high - low) {
                            let Some(mut units) = utf16_units(&bytes) else {
                                valid = false;
                                break;
                            };
                            if !increment_utf16(&mut units, offset) {
                                valid = false;
                                break;
                            }
                            if let Ok(text) = String::from_utf16(&units) {
                                map.map.insert(low + offset, text);
                                source_lengths.entry(low + offset).or_insert(source_length);
                            }
                        }
                    }
                    Token::LBracket => {
                        let mut offset = 0u32;
                        while let Some(token) = tokens.next_token() {
                            match token {
                                Token::RBracket => break,
                                Token::Hex(bytes) => {
                                    if let Some(text) = utf16_text(&bytes) {
                                        if low + offset <= high {
                                            map.map.insert(low + offset, text);
                                            source_lengths
                                                .entry(low + offset)
                                                .or_insert(source_length);
                                        }
                                    } else {
                                        valid = false;
                                    }
                                    offset = offset.saturating_add(1);
                                }
                                _ => {}
                            }
                        }
                    }
                    _ => {
                        valid = false;
                    }
                }
            },
            _ => {}
        }
    }
    map.ok = valid;
    map.source_lengths = source_lengths;
    map
}

/// The decoded `/ToUnicode` map plus its validity.
#[derive(Clone, Debug, Default)]
pub struct ToUnicodeMap {
    pub map: HashMap<u32, String>,
    pub ok: bool,
    source_lengths: HashMap<u32, usize>,
}

impl ToUnicodeMap {
    fn source_bytes_for(&self, code: u32) -> usize {
        self.source_lengths.get(&code).copied().unwrap_or(1)
    }
}

fn code_of(bytes: &[u8]) -> u32 {
    let mut code = 0u32;
    for byte in bytes.iter().take(4) {
        code = (code << 8) | u32::from(*byte);
    }
    code
}

fn utf16_text(bytes: &[u8]) -> Option<String> {
    let units = utf16_units(bytes)?;
    String::from_utf16(&units).ok()
}

fn utf16_units(bytes: &[u8]) -> Option<Vec<u16>> {
    if bytes.is_empty() || !bytes.len().is_multiple_of(2) {
        return None;
    }
    Some(
        bytes
            .as_chunks::<2>()
            .0
            .iter()
            .map(|pair| u16::from_be_bytes(*pair))
            .collect(),
    )
}

fn increment_utf16(units: &mut [u16], amount: u32) -> bool {
    let mut carry = amount as u64;
    for unit in units.iter_mut().rev() {
        let value = u64::from(*unit) + carry;
        *unit = (value & 0xFFFF) as u16;
        carry = value >> 16;
        if carry == 0 {
            return true;
        }
    }
    carry == 0
}

// ─── CMap tokenizer ──────────────────────────────────────────────────────────────────────────

#[derive(Debug)]
enum Token {
    Hex(Vec<u8>),
    Word(Vec<u8>),
    LBracket,
    RBracket,
}

struct Tokens<'a> {
    data: &'a [u8],
    position: usize,
}

impl<'a> Tokens<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, position: 0 }
    }

    fn next_token(&mut self) -> Option<Token> {
        self.skip_space();
        if self.position >= self.data.len() {
            return None;
        }
        match self.data[self.position] {
            b'<' if self.data.get(self.position + 1) == Some(&b'<') => {
                self.position += 2;
                Some(Token::Word(b"<<".to_vec()))
            }
            b'>' if self.data.get(self.position + 1) == Some(&b'>') => {
                self.position += 2;
                Some(Token::Word(b">>".to_vec()))
            }
            b'<' => {
                self.position += 1;
                let start = self.position;
                while self.position < self.data.len() && self.data[self.position] != b'>' {
                    self.position += 1;
                }
                let hex = &self.data[start..self.position.min(self.data.len())];
                self.position = (self.position + 1).min(self.data.len());
                let mut bytes = Vec::new();
                let mut high: Option<u8> = None;
                for byte in hex {
                    if let Some(value) = hex_digit(*byte) {
                        if let Some(high) = high.take() {
                            bytes.push(high << 4 | value);
                        } else {
                            high = Some(value);
                        }
                    }
                }
                Some(Token::Hex(bytes))
            }
            b'[' => {
                self.position += 1;
                Some(Token::LBracket)
            }
            b']' => {
                self.position += 1;
                Some(Token::RBracket)
            }
            b'(' => {
                // A literal string; CMap sections this analysis reads use hex strings, so the
                // content is skipped rather than parsed.
                self.skip_literal();
                Some(Token::Word(Vec::new()))
            }
            b'%' => {
                while self.position < self.data.len() && self.data[self.position] != b'\n' {
                    self.position += 1;
                }
                self.next_token()
            }
            b'/' => {
                self.position += 1;
                let start = self.position;
                while self.position < self.data.len() && !is_delimiter(self.data[self.position]) {
                    self.position += 1;
                }
                Some(Token::Word(self.data[start..self.position].to_vec()))
            }
            _ => {
                let start = self.position;
                while self.position < self.data.len() && !is_delimiter(self.data[self.position]) {
                    self.position += 1;
                }
                if start == self.position {
                    self.position += 1;
                    Some(Token::Word(Vec::new()))
                } else {
                    Some(Token::Word(self.data[start..self.position].to_vec()))
                }
            }
        }
    }

    fn skip_space(&mut self) {
        while self.position < self.data.len()
            && matches!(
                self.data[self.position],
                b' ' | b'\t' | b'\r' | b'\n' | b'\x0c' | 0
            )
        {
            self.position += 1;
        }
    }

    fn skip_literal(&mut self) {
        let mut depth = 0usize;
        while self.position < self.data.len() {
            match self.data[self.position] {
                b'\\' => self.position += 2,
                b'(' => {
                    depth += 1;
                    self.position += 1;
                }
                b')' => {
                    depth = depth.saturating_sub(1);
                    self.position += 1;
                    if depth == 0 {
                        break;
                    }
                }
                _ => self.position += 1,
            }
        }
    }
}

fn is_delimiter(byte: u8) -> bool {
    matches!(
        byte,
        b' ' | b'\t'
            | b'\r'
            | b'\n'
            | b'\x0c'
            | b'('
            | b')'
            | b'<'
            | b'>'
            | b'['
            | b']'
            | b'{'
            | b'}'
            | b'/'
            | b'%'
    )
}

fn hex_digit(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

// ─── Glyph names ────────────────────────────────────────────────────────────────────────────

/// Map an Adobe glyph name to its Unicode text. This is a deliberately partial table: it covers
/// ASCII, the Latin-1 names TeX producers write in `/Differences`, common punctuation, Greek and
/// the maths symbols that appear in paper fonts. Unknown names return `None`, which refuses the
/// run rather than guessing.
pub fn glyph_name_to_unicode(name: &[u8]) -> Option<String> {
    let name = std::str::from_utf8(name).ok()?;
    let base = name.split('.').next().unwrap_or(name);
    if base.len() == 1 && base.as_bytes()[0].is_ascii_alphanumeric() {
        return Some(base.to_string());
    }
    if let Some(hex) = base.strip_prefix("uni")
        && hex.len() == 4
        && hex.chars().all(|character| character.is_ascii_hexdigit())
    {
        let code = u32::from_str_radix(hex, 16).ok()?;
        return char::from_u32(code).map(|character| character.to_string());
    }
    if let Some(hex) = base.strip_prefix('u')
        && (4..=6).contains(&hex.len())
        && hex.chars().all(|character| character.is_ascii_hexdigit())
        && let Ok(code) = u32::from_str_radix(hex, 16)
    {
        return char::from_u32(code).map(|character| character.to_string());
    }
    glyph_name_table(base)
}

fn glyph_name_table(name: &str) -> Option<String> {
    GLYPH_NAMES
        .iter()
        .find(|(key, _)| *key == name)
        .map(|(_, value)| (*value).to_string())
}

/// (glyph name, Unicode text) pairs used by `/Differences`. The list is intentionally data, not
/// logic: adding a name is a one-line change and an unknown name is a refusal, never a guess.
static GLYPH_NAMES: &[(&str, &str)] = &[
    ("space", " "),
    ("exclam", "!"),
    ("quotedbl", "\""),
    ("numbersign", "#"),
    ("dollar", "$"),
    ("percent", "%"),
    ("ampersand", "&"),
    ("quotesingle", "'"),
    ("parenleft", "("),
    ("parenright", ")"),
    ("asterisk", "*"),
    ("plus", "+"),
    ("comma", ","),
    ("hyphen", "-"),
    ("period", "."),
    ("slash", "/"),
    ("zero", "0"),
    ("one", "1"),
    ("two", "2"),
    ("three", "3"),
    ("four", "4"),
    ("five", "5"),
    ("six", "6"),
    ("seven", "7"),
    ("eight", "8"),
    ("nine", "9"),
    ("colon", ":"),
    ("semicolon", ";"),
    ("less", "<"),
    ("equal", "="),
    ("greater", ">"),
    ("question", "?"),
    ("at", "@"),
    ("bracketleft", "["),
    ("backslash", "\\"),
    ("bracketright", "]"),
    ("asciicircum", "^"),
    ("underscore", "_"),
    ("grave", "`"),
    ("braceleft", "{"),
    ("bar", "|"),
    ("braceright", "}"),
    ("asciitilde", "~"),
    ("nbspace", "\u{a0}"),
    ("exclamdown", "¡"),
    ("cent", "¢"),
    ("sterling", "£"),
    ("currency", "¤"),
    ("yen", "¥"),
    ("brokenbar", "¦"),
    ("section", "§"),
    ("dieresis", "¨"),
    ("copyright", "©"),
    ("ordfeminine", "ª"),
    ("guillemotleft", "«"),
    ("logicalnot", "¬"),
    ("sfthyphen", "\u{AD}"),
    ("registered", "®"),
    ("macron", "¯"),
    ("degree", "°"),
    ("plusminus", "±"),
    ("twosuperior", "²"),
    ("threesuperior", "³"),
    ("acute", "´"),
    ("mu", "µ"),
    ("paragraph", "¶"),
    ("periodcentered", "·"),
    ("cedilla", "¸"),
    ("onesuperior", "¹"),
    ("ordmasculine", "º"),
    ("guillemotright", "»"),
    ("onequarter", "¼"),
    ("onehalf", "½"),
    ("threequarters", "¾"),
    ("questiondown", "¿"),
    ("Agrave", "À"),
    ("Aacute", "Á"),
    ("Acircumflex", "Â"),
    ("Atilde", "Ã"),
    ("Adieresis", "Ä"),
    ("Aring", "Å"),
    ("AE", "Æ"),
    ("Ccedilla", "Ç"),
    ("Egrave", "È"),
    ("Eacute", "É"),
    ("Ecircumflex", "Ê"),
    ("Edieresis", "Ë"),
    ("Igrave", "Ì"),
    ("Iacute", "Í"),
    ("Icircumflex", "Î"),
    ("Idieresis", "Ï"),
    ("Eth", "Ð"),
    ("Ntilde", "Ñ"),
    ("Ograve", "Ò"),
    ("Oacute", "Ó"),
    ("Ocircumflex", "Ô"),
    ("Otilde", "Õ"),
    ("Odieresis", "Ö"),
    ("multiply", "×"),
    ("Oslash", "Ø"),
    ("Ugrave", "Ù"),
    ("Uacute", "Ú"),
    ("Ucircumflex", "Û"),
    ("Udieresis", "Ü"),
    ("Yacute", "Ý"),
    ("Thorn", "Þ"),
    ("germandbls", "ß"),
    ("agrave", "à"),
    ("aacute", "á"),
    ("acircumflex", "â"),
    ("atilde", "ã"),
    ("adieresis", "ä"),
    ("aring", "å"),
    ("ae", "æ"),
    ("ccedilla", "ç"),
    ("egrave", "è"),
    ("eacute", "é"),
    ("ecircumflex", "ê"),
    ("edieresis", "ë"),
    ("igrave", "ì"),
    ("iacute", "í"),
    ("icircumflex", "î"),
    ("idieresis", "ï"),
    ("eth", "ð"),
    ("ntilde", "ñ"),
    ("ograve", "ò"),
    ("oacute", "ó"),
    ("ocircumflex", "ô"),
    ("otilde", "õ"),
    ("odieresis", "ö"),
    ("divide", "÷"),
    ("oslash", "ø"),
    ("ugrave", "ù"),
    ("uacute", "ú"),
    ("ucircumflex", "û"),
    ("udieresis", "ü"),
    ("yacute", "ý"),
    ("thorn", "þ"),
    ("ydieresis", "ÿ"),
    ("dotlessi", "ı"),
    ("OE", "Œ"),
    ("oe", "œ"),
    ("Scaron", "Š"),
    ("scaron", "š"),
    ("Zcaron", "Ž"),
    ("zcaron", "ž"),
    ("Ydieresis", "Ÿ"),
    ("florin", "ƒ"),
    ("circumflex", "ˆ"),
    ("caron", "ˇ"),
    ("breve", "˘"),
    ("dotaccent", "˙"),
    ("ring", "˚"),
    ("ogonek", "˛"),
    ("tilde", "˜"),
    ("hungarumlaut", "˝"),
    ("endash", "–"),
    ("emdash", "—"),
    ("quotesinglbase", "‚"),
    ("quotedblbase", "„"),
    ("quotedblleft", "“"),
    ("quotedblright", "”"),
    ("quoteleft", "‘"),
    ("quoteright", "’"),
    ("dagger", "†"),
    ("daggerdbl", "‡"),
    ("bullet", "•"),
    ("ellipsis", "…"),
    ("perthousand", "‰"),
    ("guilsinglleft", "‹"),
    ("guilsinglright", "›"),
    ("fraction", "⁄"),
    ("Euro", "€"),
    ("trademark", "™"),
    ("minus", "−"),
    ("fi", "fi"),
    ("fl", "fl"),
    ("ff", "ff"),
    ("ffi", "ffi"),
    ("ffl", "ffl"),
    ("dotlessj", "ȷ"),
    ("Delta", "Δ"),
    ("Omega", "Ω"),
    ("alpha", "α"),
    ("beta", "β"),
    ("gamma", "γ"),
    ("delta", "δ"),
    ("epsilon", "ε"),
    ("zeta", "ζ"),
    ("eta", "η"),
    ("theta", "θ"),
    ("iota", "ι"),
    ("kappa", "κ"),
    ("lambda", "λ"),
    ("nu", "ν"),
    ("xi", "ξ"),
    ("omicron", "ο"),
    ("pi", "π"),
    ("rho", "ρ"),
    ("sigma", "σ"),
    ("tau", "τ"),
    ("upsilon", "υ"),
    ("phi", "φ"),
    ("chi", "χ"),
    ("psi", "ψ"),
    ("omega", "ω"),
    ("Gamma", "Γ"),
    ("Theta", "Θ"),
    ("Lambda", "Λ"),
    ("Xi", "Ξ"),
    ("Pi", "Π"),
    ("Sigma", "Σ"),
    ("Upsilon", "Υ"),
    ("Phi", "Φ"),
    ("Psi", "Ψ"),
    ("epsilon1", "ϵ"),
    ("theta1", "ϑ"),
    ("phi1", "ϕ"),
    ("omega1", "ϖ"),
    ("sigma1", "ς"),
    ("rho1", "ϱ"),
    ("pi1", "ϖ"),
    ("gamma1", "γ"),
    ("lambda1", "λ"),
    ("summation", "∑"),
    ("product", "∏"),
    ("integral", "∫"),
    ("radical", "√"),
    ("infinity", "∞"),
    ("partialdiff", "∂"),
    ("nabla", "∇"),
    ("approxequal", "≈"),
    ("notequal", "≠"),
    ("lessequal", "≤"),
    ("greaterequal", "≥"),
    ("element", "∈"),
    ("notelement", "∉"),
    ("intersection", "∩"),
    ("union", "∪"),
    ("propersubset", "⊂"),
    ("reflexsubset", "⊃"),
    ("emptyset", "∅"),
    ("forall", "∀"),
    ("existential", "∃"),
    ("logicaland", "∧"),
    ("logicalor", "∨"),
    ("arrowright", "→"),
    ("arrowleft", "←"),
    ("arrowup", "↑"),
    ("arrowdown", "↓"),
    ("arrowboth", "↔"),
    ("arrowdblright", "⇒"),
    ("arrowdblleft", "⇐"),
    ("arrowdblboth", "⇔"),
    ("similar", "∼"),
    ("congruent", "≅"),
    ("equivalence", "≡"),
    ("proportional", "∝"),
    ("angle", "∠"),
    ("perpendicular", "⊥"),
    ("dotmath", "⋅"),
    ("prime", "′"),
    ("second", "″"),
    ("lozenge", "◊"),
    ("club", "♣"),
    ("diamond", "♦"),
    ("heart", "♥"),
    ("spade", "♠"),
    ("checkmark", "✓"),
    ("circledot", "⊙"),
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cmap_bfchar_and_bfrange_decode_to_unicode() {
        let cmap = br#"
            /CIDInit /ProcSet findresource begin
            1 begincodespacerange <0000> <FFFF> endcodespacerange
            2 beginbfchar
              <0001> <0041>
              <0002> <00660069>
            endbfchar
            2 beginbfrange
              <0010> <0012> <0030>
              <0020> <0021> [<0058> <0059>]
            endbfrange
            endcmap
        "#;
        let map = parse_to_unicode(cmap);
        assert!(map.ok);
        assert_eq!(map.map.get(&1).map(String::as_str), Some("A"));
        assert_eq!(map.map.get(&2).map(String::as_str), Some("fi"));
        assert_eq!(map.map.get(&0x10).map(String::as_str), Some("0"));
        assert_eq!(map.map.get(&0x12).map(String::as_str), Some("2"));
        assert_eq!(map.map.get(&0x20).map(String::as_str), Some("X"));
        assert_eq!(map.map.get(&0x21).map(String::as_str), Some("Y"));
    }

    #[test]
    fn malformed_cmap_is_not_trusted() {
        // A range whose high code is below its low code cannot describe a real mapping.
        let map = parse_to_unicode(b"beginbfrange <0010> <0001> <0041> endbfrange");
        assert!(!map.ok);
        // An incomplete bfchar section (no end marker) is not trusted either.
        let map = parse_to_unicode(b"beginbfchar <0001> <0041>");
        assert!(!map.ok);
    }

    #[test]
    fn win_ansi_and_mac_roman_tables_map_the_punctuation_producers_use() {
        assert_eq!(win_ansi(0x93), Some('“'));
        assert_eq!(win_ansi(0xE9), Some('é'));
        assert_eq!(mac_roman(0xD5), Some('’'));
        assert_eq!(latinish(0x41), Some('A'));
        assert_eq!(latinish(0x80), None);
    }

    #[test]
    fn glyph_names_resolve_ascii_ligatures_and_math() {
        assert_eq!(glyph_name_to_unicode(b"A").as_deref(), Some("A"));
        assert_eq!(glyph_name_to_unicode(b"space").as_deref(), Some(" "));
        assert_eq!(glyph_name_to_unicode(b"fi").as_deref(), Some("fi"));
        assert_eq!(glyph_name_to_unicode(b"summation").as_deref(), Some("∑"));
        assert_eq!(glyph_name_to_unicode(b"uni00E9").as_deref(), Some("é"));
        assert_eq!(glyph_name_to_unicode(b"bogusname"), None);
    }
}
