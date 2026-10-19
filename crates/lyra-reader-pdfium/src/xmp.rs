//! The XMP metadata stream, without a second PDF parser.
//!
//! PDFium's C ABI exposes the `/Info` dictionary (`FPDF_GetMetaText`) but **not** the
//! catalog's `/Metadata` stream, and XMP is where a publisher records the DOI and the venue.
//! This module therefore reads the source file's bytes directly and looks for the one object
//! shape an XMP packet always has:
//!
//! ```text
//! << /Type /Metadata /Subtype /XML /Filter /FlateDecode /Length 1234 >>
//! stream
//! ...compressed packet...
//! endstream
//! ```
//!
//! It is not a general PDF parser: it finds `stream` keywords, checks the immediately
//! preceding dictionary for `/Metadata` or `/Subtype /XML`, honours `/Length` when it is a
//! direct number (falling back to `endstream`), inflates `FlateDecode`, and parses only the
//! handful of properties the metadata feature consumes. Anything malformed, encrypted or
//! absent degrades to an empty [`XmpMetadata`] — the recogniser then falls back to the text
//! layer or reports "no metadata", never a guess.
//!
//! The parser is deliberately namespace-literal: `dc:title`, `dc:creator`, `prism:doi`,
//! `prism:publicationName`, `prism:coverDate`. Those are the property names XMP defines for
//! exactly these facts, and accepting arbitrary prefixes would make "a DOI" mean whatever an
//! unrelated vocabulary happened to call one.

use lyra_reader_core::XmpMetadata;
use std::io::Read;
use std::path::Path;

/// Reads the XMP fields from `path`, or returns an empty value when anything is missing.
///
/// Metadata is optional. An unreadable file, an encrypted stream, a malformed packet and a
/// file with no XMP all produce the same honest answer: nothing was recognised.
pub(crate) fn read_xmp(path: &Path) -> XmpMetadata {
    match std::fs::read(path) {
        Ok(bytes) => parse_xmp_bytes(&bytes),
        Err(_) => XmpMetadata::default(),
    }
}

/// Parses every XMP packet in `bytes` and merges them in file order (later revisions win,
/// while a property only an earlier revision carried is kept).
pub(crate) fn parse_xmp_bytes(bytes: &[u8]) -> XmpMetadata {
    let mut result = XmpMetadata::default();
    for packet in packets(bytes) {
        let text = String::from_utf8_lossy(&packet);
        let presence = packet_presence(&text);
        merge(&mut result, parse_packet(&text), presence);
    }
    result
}

/// Which of the revision-merged properties a packet states at all.
///
/// A later incremental revision that *states* `dc:title` but gives it an empty value is an
/// explicit clear; one that does not mention the property keeps whatever an earlier revision
/// said. [`crate::xmp_write`] relies on this when it clears a value in place.
struct PacketPresence {
    title: bool,
    creators: bool,
}

fn packet_presence(text: &str) -> PacketPresence {
    PacketPresence {
        title: mentions(text, "dc:title"),
        creators: mentions(text, "dc:creator"),
    }
}

fn mentions(text: &str, name: &str) -> bool {
    let opening = format!("<{name}");
    let mut cursor = 0usize;
    while let Some(offset) = text[cursor..].find(&opening) {
        let after = cursor + offset + opening.len();
        if matches!(
            text.as_bytes().get(after),
            Some(byte) if byte.is_ascii_whitespace() || *byte == b'>' || *byte == b'/'
        ) {
            return true;
        }
        cursor = after;
    }
    let attribute = format!("{name}=\"");
    let mut cursor = 0usize;
    while let Some(offset) = text[cursor..].find(&attribute) {
        let at = cursor + offset;
        if at == 0
            || text.as_bytes()[at - 1].is_ascii_whitespace()
            || text.as_bytes()[at - 1] == b'<'
        {
            return true;
        }
        cursor = at + 1;
    }
    false
}

fn merge(into: &mut XmpMetadata, from: XmpMetadata, presence: PacketPresence) {
    if presence.title {
        into.title = from.title;
    }
    if presence.creators {
        into.authors = from.authors;
    }
    if from.doi.is_some() {
        into.doi = from.doi;
    }
    if from.venue.is_some() {
        into.venue = from.venue;
    }
    if from.year.is_some() {
        into.year = from.year;
    }
}

/// The decoded XMP packets found in `bytes`.
fn packets(bytes: &[u8]) -> Vec<Vec<u8>> {
    let mut found = Vec::new();
    let mut cursor = 0usize;

    while let Some(offset) = find(&bytes[cursor..], b"stream") {
        let keyword = cursor + offset;
        // `endstream` contains `stream`; a real keyword is not preceded by a letter.
        let preceded_by_word = keyword > 0 && bytes[keyword - 1].is_ascii_alphanumeric();
        let search_from = keyword + b"stream".len();
        cursor = search_from.max(keyword + 1);
        if preceded_by_word {
            continue;
        }

        // The dictionary is written immediately before the keyword. A 4 KiB window avoids
        // rescanning the whole file without losing a realistic metadata dictionary.
        let window_start = keyword.saturating_sub(4096);
        let dictionary = &bytes[window_start..keyword];
        if !looks_like_metadata_dictionary(dictionary) {
            continue;
        }

        let mut body_start = search_from;
        if bytes.get(body_start) == Some(&b'\r') {
            body_start += 1;
        }
        if bytes.get(body_start) == Some(&b'\n') {
            body_start += 1;
        }
        let Some(end) = stream_end(bytes, body_start, dictionary) else {
            continue;
        };
        let body = &bytes[body_start..end];
        let decoded = decode_stream(body, dictionary);
        if contains_packet_marker(&decoded) {
            found.push(decoded);
        }
    }

    // A producer may write the packet outside a stream we can recognise (for example a
    // malformed `/Length`); the packet markers themselves are unambiguous.
    if found.is_empty() {
        found.extend(raw_packets(bytes));
    }
    found
}

fn looks_like_metadata_dictionary(dictionary: &[u8]) -> bool {
    contains(dictionary, b"/Metadata")
        || contains(dictionary, b"/Subtype/XML")
        || contains(dictionary, b"/Subtype /XML")
}

/// Where a stream's data ends: its direct `/Length`, or the `endstream` keyword.
fn stream_end(bytes: &[u8], body_start: usize, dictionary: &[u8]) -> Option<usize> {
    if let Some(length) = direct_length(dictionary)
        && body_start.saturating_add(length) <= bytes.len()
    {
        return Some(body_start + length);
    }
    find(&bytes[body_start..], b"endstream").map(|offset| body_start + offset)
}

/// The last direct `/Length` number in `dictionary`, or `None` for an indirect reference.
fn direct_length(dictionary: &[u8]) -> Option<usize> {
    let mut cursor = 0usize;
    let mut length = None;
    while let Some(offset) = find(&dictionary[cursor..], b"/Length") {
        let start = cursor + offset + b"/Length".len();
        let rest = &dictionary[start..];
        let digits = rest
            .iter()
            .skip_while(|byte| byte.is_ascii_whitespace())
            .take_while(|byte| byte.is_ascii_digit())
            .copied()
            .collect::<Vec<_>>();
        if !digits.is_empty() {
            length = std::str::from_utf8(&digits)
                .ok()
                .and_then(|value| value.parse::<usize>().ok());
        }
        cursor = start;
        if cursor >= dictionary.len() {
            break;
        }
    }
    length
}

fn decode_stream(body: &[u8], dictionary: &[u8]) -> Vec<u8> {
    let filtered = contains(dictionary, b"/FlateDecode") || contains(dictionary, b"/Fl ");
    if filtered && let Some(decoded) = inflate(body) {
        return decoded;
        // A broken filter must not hide a packet that was in fact stored verbatim.
    }
    body.to_vec()
}

fn inflate(body: &[u8]) -> Option<Vec<u8>> {
    // PDF's FlateDecode is zlib; a few producers omit the zlib wrapper.
    for deflate in [false, true] {
        let mut output = Vec::new();
        let read = if deflate {
            flate2::read::DeflateDecoder::new(body).read_to_end(&mut output)
        } else {
            flate2::read::ZlibDecoder::new(body).read_to_end(&mut output)
        };
        if read.is_ok() && contains_packet_marker(&output) {
            return Some(output);
        }
    }
    None
}

fn contains_packet_marker(bytes: &[u8]) -> bool {
    contains(bytes, b"<rdf:RDF") || contains(bytes, b"<x:xmpmeta") || contains(bytes, b"<?xpacket")
}

fn raw_packets(bytes: &[u8]) -> Vec<Vec<u8>> {
    let mut packets = Vec::new();
    let mut cursor = 0usize;
    while let Some(offset) = find(&bytes[cursor..], b"<?xpacket") {
        let start = cursor + offset;
        let end = find(&bytes[start..], b"<?xpacket end=")
            .map(|tail| {
                let after = start + tail;
                find(&bytes[after..], b"?>")
                    .map(|close| after + close + 2)
                    .unwrap_or(bytes.len())
            })
            .unwrap_or_else(|| {
                find(&bytes[start..], b"</x:xmpmeta>")
                    .map(|tail| start + tail + b"</x:xmpmeta>".len())
                    .unwrap_or(bytes.len())
            });
        packets.push(bytes[start..end.min(bytes.len())].to_vec());
        cursor = end.max(start + 1);
    }
    packets
}

/// Parses one XMP packet into the properties this reader understands.
pub(crate) fn parse_packet(text: &str) -> XmpMetadata {
    let title = property(text, "dc:title").or_else(|| attribute(text, "dc:title"));
    let authors = creator_list(text);
    let doi = property(text, "prism:doi").or_else(|| attribute(text, "prism:doi"));
    let venue = property(text, "prism:publicationName")
        .or_else(|| attribute(text, "prism:publicationName"));
    let cover = property(text, "prism:coverDate")
        .or_else(|| attribute(text, "prism:coverDate"))
        .or_else(|| property(text, "prism:coverDisplayDate"));
    let year = cover.as_deref().and_then(four_digit_year);

    XmpMetadata {
        title,
        authors,
        doi,
        venue,
        year,
    }
}

/// The text of an element, with any RDF container flattened to its first item.
fn property(text: &str, name: &str) -> Option<String> {
    let opening = format!("<{name}");
    let start = text.find(&opening)?;
    let after_name = start + opening.len();
    match text.as_bytes().get(after_name) {
        Some(byte) if byte.is_ascii_whitespace() || *byte == b'>' || *byte == b'/' => {}
        _ => return None,
    }
    let tag_end = after_name + text[after_name..].find('>')?;
    if text.as_bytes().get(tag_end - 1) == Some(&b'/') {
        return None;
    }
    let inner_start = tag_end + 1;
    let closing = format!("</{name}>");
    let inner_end = inner_start + text[inner_start..].find(&closing)?;
    let inner = &text[inner_start..inner_end];

    let items = list_items(inner);
    if let Some(first) = items.first() {
        return clean(first);
    }
    clean(&strip_tags(inner))
}

/// Every `rdf:li` value inside an element.
fn list_items(inner: &str) -> Vec<String> {
    let mut items = Vec::new();
    let mut cursor = 0usize;
    while let Some(offset) = inner[cursor..].find("<rdf:li") {
        let start = cursor + offset;
        let Some(tag_end) = inner[start..].find('>').map(|value| start + value) else {
            break;
        };
        if inner.as_bytes().get(tag_end - 1) == Some(&b'/') {
            cursor = tag_end + 1;
            continue;
        }
        let content_start = tag_end + 1;
        let Some(close) = inner[content_start..]
            .find("</rdf:li>")
            .map(|value| content_start + value)
        else {
            break;
        };
        if let Some(value) = clean(&strip_tags(&inner[content_start..close])) {
            items.push(value);
        }
        cursor = close + "</rdf:li>".len();
    }
    items
}

fn creator_list(text: &str) -> Vec<String> {
    let mut creators = Vec::new();
    if let Some(inner) = element_inner(text, "dc:creator") {
        for item in list_items(&inner) {
            for value in item.split(';') {
                if let Some(value) = clean(value) {
                    creators.push(value);
                }
            }
        }
        if creators.is_empty()
            && let Some(value) = clean(&strip_tags(&inner))
        {
            creators.push(value);
        }
    }
    if creators.is_empty()
        && let Some(value) = attribute(text, "dc:creator")
        && let Some(value) = clean(&value)
    {
        creators.push(value);
    }
    creators
}

fn element_inner(text: &str, name: &str) -> Option<String> {
    let opening = format!("<{name}");
    let start = text.find(&opening)?;
    let tag_end = start + text[start..].find('>')?;
    if text.as_bytes().get(tag_end - 1) == Some(&b'/') {
        return None;
    }
    let content_start = tag_end + 1;
    let closing = format!("</{name}>");
    let end = content_start + text[content_start..].find(&closing)?;
    Some(text[content_start..end].to_string())
}

/// The attribute form: `<rdf:Description dc:title="…" prism:doi="…">`.
fn attribute(text: &str, name: &str) -> Option<String> {
    let needle = format!("{name}=\"");
    let start = text.find(&needle)? + needle.len();
    let end = start + text[start..].find('"')?;
    clean(&decode_entities(&text[start..end]))
}

fn strip_tags(text: &str) -> String {
    let mut output = String::with_capacity(text.len());
    let mut in_tag = false;
    for character in text.chars() {
        match character {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => output.push(character),
            _ => {}
        }
    }
    decode_entities(&output)
}

fn decode_entities(text: &str) -> String {
    let mut output = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(position) = rest.find('&') {
        output.push_str(&rest[..position]);
        let after = &rest[position..];
        let Some(end) = after.find(';').filter(|end| *end <= 10) else {
            output.push('&');
            rest = &after[1..];
            continue;
        };
        let entity = &after[1..end];
        let decoded = match entity {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            _ if entity.starts_with("#x") || entity.starts_with("#X") => {
                u32::from_str_radix(&entity[2..], 16)
                    .ok()
                    .and_then(char::from_u32)
            }
            _ if entity.starts_with('#') => {
                entity[1..].parse::<u32>().ok().and_then(char::from_u32)
            }
            _ => None,
        };
        if let Some(character) = decoded {
            output.push(character);
            rest = &after[end + 1..];
        } else {
            output.push('&');
            rest = &after[1..];
        }
    }
    output.push_str(rest);
    output
}

fn clean(value: &str) -> Option<String> {
    let collapsed = value.split_whitespace().collect::<Vec<_>>().join(" ");
    let trimmed = collapsed.trim_matches(|character: char| character.is_control());
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn four_digit_year(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    for window in bytes.windows(4) {
        if window.iter().all(u8::is_ascii_digit) {
            let text = std::str::from_utf8(window).ok()?;
            let year = text.parse::<u32>().ok()?;
            if (1900..=2099).contains(&year) {
                return Some(text.to_string());
            }
        }
    }
    None
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    find(haystack, needle).is_some()
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

#[cfg(test)]
mod tests {
    use super::*;

    const PACKET: &str = r#"<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmlns:prism="http://prismstandard.org/namespaces/basic/2.0/">
   <dc:title><rdf:Alt><rdf:li xml:lang="x-default">A &amp; B: Testing {Braces}</rdf:li></rdf:Alt></dc:title>
   <dc:creator><rdf:Seq><rdf:li>Ada Lovelace</rdf:li><rdf:li>Alan Turing</rdf:li></rdf:Seq></dc:creator>
   <prism:doi>10.1145/1234567.8901234</prism:doi>
   <prism:publicationName>Journal of Testing</prism:publicationName>
   <prism:coverDate>2024-03-15</prism:coverDate>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>"#;

    #[test]
    fn a_standard_packet_yields_title_creators_doi_venue_and_year() {
        let xmp = parse_packet(PACKET);
        assert_eq!(xmp.title.as_deref(), Some("A & B: Testing {Braces}"));
        assert_eq!(xmp.authors, vec!["Ada Lovelace", "Alan Turing"]);
        assert_eq!(xmp.doi.as_deref(), Some("10.1145/1234567.8901234"));
        assert_eq!(xmp.venue.as_deref(), Some("Journal of Testing"));
        assert_eq!(xmp.year.as_deref(), Some("2024"));
    }

    #[test]
    fn the_attribute_form_is_read_too() {
        let text = r#"<rdf:Description dc:title="Attribute &amp; title" dc:creator="Grace Hopper" prism:doi="10.1000/xyz123" prism:publicationName="Proceedings of the Test Conference" prism:coverDate="2021-06-01"/>"#;
        let xmp = parse_packet(text);
        assert_eq!(xmp.title.as_deref(), Some("Attribute & title"));
        assert_eq!(xmp.authors, vec!["Grace Hopper"]);
        assert_eq!(xmp.doi.as_deref(), Some("10.1000/xyz123"));
        assert_eq!(
            xmp.venue.as_deref(),
            Some("Proceedings of the Test Conference")
        );
        assert_eq!(xmp.year.as_deref(), Some("2021"));
    }

    #[test]
    fn a_flate_compressed_metadata_stream_is_decoded() {
        use flate2::Compression;
        use flate2::write::ZlibEncoder;
        use std::io::Write;

        let mut encoder = ZlibEncoder::new(Vec::new(), Compression::default());
        encoder.write_all(PACKET.as_bytes()).expect("compress");
        let compressed = encoder.finish().expect("finish");
        let mut bytes =
            b"%PDF-1.7\n1 0 obj\n<< /Type /Metadata /Subtype /XML /Filter /FlateDecode /Length "
                .to_vec();
        bytes.extend_from_slice(compressed.len().to_string().as_bytes());
        bytes.extend_from_slice(b" >>\nstream\n");
        bytes.extend_from_slice(&compressed);
        bytes.extend_from_slice(b"\nendstream\nendobj\n%%EOF\n");

        let xmp = parse_xmp_bytes(&bytes);
        assert_eq!(xmp.doi.as_deref(), Some("10.1145/1234567.8901234"));
        assert_eq!(xmp.authors.len(), 2);
    }

    #[test]
    fn an_uncompressed_stream_is_read_and_entities_are_decoded() {
        let mut bytes = b"%PDF-1.7\n1 0 obj\n<< /Type /Metadata /Subtype /XML /Length ".to_vec();
        bytes.extend_from_slice(PACKET.len().to_string().as_bytes());
        bytes.extend_from_slice(b" >>\nstream\n");
        bytes.extend_from_slice(PACKET.as_bytes());
        bytes.extend_from_slice(b"\nendstream\nendobj\n%%EOF\n");

        let xmp = parse_xmp_bytes(&bytes);
        assert_eq!(xmp.title.as_deref(), Some("A & B: Testing {Braces}"));
    }

    #[test]
    fn a_file_without_xmp_is_empty_and_a_broken_packet_does_not_panic() {
        assert_eq!(
            parse_xmp_bytes(b"%PDF-1.7\nno metadata here\n"),
            XmpMetadata::default()
        );
        assert_eq!(
            parse_xmp_bytes(b"<rdf:RDF><dc:title>"),
            XmpMetadata::default()
        );
        assert_eq!(
            parse_xmp_bytes(b"<< /Type /Metadata >>\nstream\n<rdf:RDF>"),
            XmpMetadata::default()
        );
    }
}
