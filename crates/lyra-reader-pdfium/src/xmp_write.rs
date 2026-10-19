//! Writing the XMP metadata packet, without reserialising properties the reader does not own.
//!
//! The information panel edits four `/Info` entries (title, author, subject, keywords). A file
//! that also carries an XMP packet would keep the old title there, and because the metadata
//! recogniser prefers XMP the panel would keep showing the stale value after a save. This module
//! makes the packet agree with the dictionary.
//!
//! # Surgical, not reserialised
//!
//! An XMP packet is XML written by another tool: a camera may have put exposure data in it, a
//! publisher a rights statement, an editor a custom namespace. Parsing and reserialising the
//! packet would silently drop everything this reader does not understand, so the writer does the
//! opposite: it scans the packet's tag structure, replaces **only** the four properties being
//! edited, and leaves every other byte — other properties, their values, namespace declarations,
//! the `xpacket` wrapper, formatting — untouched. A property that is not being edited (including
//! the `prism:doi`, venue and date the recogniser reads) is not rewritten even when its value is
//! identical.
//!
//! The four mappings are the ones PDF defines between `/Info` and XMP:
//!
//! | `/Info`   | XMP                                      |
//! |-----------|------------------------------------------|
//! | `Title`   | `dc:title` (`rdf:Alt`, `x-default`)      |
//! | `Author`  | `dc:creator` (`rdf:Seq`, one `rdf:li`)   |
//! | `Subject` | `dc:description` (`rdf:Alt`, `x-default`)|
//! | `Keywords`| `pdf:Keywords` (plain text)              |
//!
//! Multi-valued forms are written as real RDF containers (a `Seq` of authors, an `Alt` with an
//! `x-default` item), never as a comma-joined string inside one container.
//!
//! # Creating a packet
//!
//! When the catalog has no `/Metadata`, a minimal packet is created: the standard `x:xmpmeta`
//! wrapper, an `rdf:RDF`/`rdf:Description`, and the Dublin Core / PDF schema declarations for the
//! properties that have values. The caller adds it to the catalog as `/Metadata`.
//!
//! # Malformed packets are refused, not overwritten
//!
//! A packet that cannot be scanned (invalid UTF-8, unbalanced tags, no `rdf:RDF`, no
//! `rdf:Description`, a `dc`/`pdf` prefix bound to an unexpected namespace, a stream that is not
//! a stream) is a packet this writer cannot update without guessing. Saving only `/Info` would
//! leave the two sources disagreeing — exactly the bug this module exists to fix — so the whole
//! save is refused before anything is written. The error says which part of the packet was
//! unusable, and the original file is left untouched.
//!
//! # Clearing a value
//!
//! An incremental save appends the new revision; the reader still sees the old packet bytes
//! earlier in the file. To make "clear the title" stick, the new packet states the property even
//! when the new value is empty (an empty `rdf:Alt`/`rdf:Seq`), and [`crate::xmp`] treats a
//! present-but-empty property in a later packet as an explicit clear. A property the later
//! packet does not mention at all is still kept from an earlier revision.

use crate::xmp::parse_packet;
use lopdf::{Dictionary, Document, Object, ObjectId, Stream};
use lyra_reader_core::{ErrorCode, LyraReaderError, Result};
use std::fmt::Write as _;
use std::io::Write as _;

/// A packet larger than this is not a metadata packet this reader will edit. Real packets are
/// kilobytes; the bound stops a decompression bomb from being inflated in memory.
pub(crate) const MAX_PACKET_BYTES: usize = 16 * 1024 * 1024;

const DC_NAMESPACE: &str = "http://purl.org/dc/elements/1.1/";
const PDF_NAMESPACE: &str = "http://ns.adobe.com/pdf/1.3/";

/// The result of preparing a packet for a properties save.
pub(crate) struct MetadataUpdate {
    /// The packet that must be the `/Metadata` stream after the save.
    pub packet: Vec<u8>,
    /// The packet as it was before the save, when one existed (for preservation checks).
    pub original: Option<Vec<u8>>,
    /// The existing stream object, when the catalog already had `/Metadata`.
    pub existing_object: Option<ObjectId>,
    /// True when there was no packet and a minimal one was created.
    pub created: bool,
    /// False when the packet already said exactly what the save is writing; the stream is then
    /// left byte-for-byte untouched instead of being written again.
    pub changed: bool,
}

fn malformed(detail: impl Into<String>) -> LyraReaderError {
    LyraReaderError::new(
        ErrorCode::CorruptDocument,
        "the document's XMP metadata packet is malformed or unsupported, so the properties were \
         not saved; the information dictionary was left untouched so the two metadata sources \
         cannot disagree",
    )
    .with_detail(detail.into())
}

/// Reads the catalog's `/Metadata` stream from an already loaded document.
///
/// `Ok(None)` means the catalog has no `/Metadata`. A `/Metadata` entry that is not an indirect
/// stream is reported as malformed rather than replaced: the entry belongs to another tool and
/// guessing what it meant is how metadata gets destroyed.
pub(crate) fn read_metadata_packet(document: &Document) -> Result<Option<Vec<u8>>> {
    let catalog = document
        .catalog()
        .map_err(|error| malformed(format!("the catalog cannot be read: {error}")))?;
    let Some(object) = catalog.get(b"Metadata").ok() else {
        return Ok(None);
    };
    let id = object.as_reference().map_err(|_| {
        malformed("/Metadata is not an indirect stream, so it cannot be updated safely")
    })?;
    let object = document
        .get_object(id)
        .map_err(|error| malformed(format!("/Metadata object {id:?} is missing: {error}")))?;
    let stream = object
        .as_stream()
        .map_err(|_| malformed("/Metadata does not point at a stream"))?;
    let content = stream
        .get_plain_content_with_limit(MAX_PACKET_BYTES)
        .map_err(|error| malformed(format!("the /Metadata stream cannot be decoded: {error}")))?;
    Ok(Some(content))
}

/// Reads the existing packet (if any) and produces the packet the save must write.
pub(crate) fn prepare_metadata_update(
    document: &Document,
    properties: &crate::document_properties::DocumentProperties,
) -> Result<MetadataUpdate> {
    let existing = read_metadata_packet(document)?;
    let mut update = match existing.as_deref() {
        None => MetadataUpdate {
            packet: create_packet(properties)?,
            original: None,
            existing_object: None,
            created: true,
            changed: true,
        },
        Some(packet) => {
            let planned = update_packet(packet, properties)?;
            MetadataUpdate {
                changed: planned != packet,
                packet: planned,
                original: Some(packet.to_vec()),
                existing_object: metadata_object_id(document)?,
                created: false,
            }
        }
    };
    if !update.changed {
        // Keep the bytes we read, not a re-rendered equivalent.
        if let Some(packet) = existing {
            update.packet = packet;
        }
    }
    Ok(update)
}

fn metadata_object_id(document: &Document) -> Result<Option<ObjectId>> {
    let catalog = document
        .catalog()
        .map_err(|error| malformed(format!("the catalog cannot be read: {error}")))?;
    Ok(catalog
        .get(b"Metadata")
        .ok()
        .and_then(|object| object.as_reference().ok()))
}

/// The four editable fields, in the order the panel lists them.
fn edited_fields(
    properties: &crate::document_properties::DocumentProperties,
) -> [(&'static str, &str); 4] {
    [
        ("dc:title", properties.title.as_str()),
        ("dc:creator", properties.author.as_str()),
        ("dc:description", properties.subject.as_str()),
        ("pdf:Keywords", properties.keywords.as_str()),
    ]
}

fn validate_xml(value: &str, key: &str) -> Result<()> {
    for character in value.chars() {
        let scalar = character as u32;
        let allowed = matches!(character, '\t' | '\n' | '\r')
            || (0x20..=0xD7FF).contains(&scalar)
            || (0xE000..=0xFFFD).contains(&scalar)
            || (0x10000..=0x10FFFF).contains(&scalar);
        if !allowed {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                format!("the {key} value contains a character XML cannot carry"),
            )
            .with_detail(format!("U+{scalar:04X} is not a valid XML character")));
        }
    }
    Ok(())
}

fn validate_all(properties: &crate::document_properties::DocumentProperties) -> Result<()> {
    for (key, value) in edited_fields(properties) {
        validate_xml(value, key)?;
    }
    Ok(())
}

fn escape_text(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            // XML normalises a literal CR away; a character reference keeps it.
            '\r' => escaped.push_str("&#13;"),
            _ => escaped.push(character),
        }
    }
    escaped
}

fn escape_attribute(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            '"' => escaped.push_str("&quot;"),
            '\'' => escaped.push_str("&apos;"),
            // Attribute-value normalisation turns these into spaces unless they are references.
            '\t' => escaped.push_str("&#9;"),
            '\n' => escaped.push_str("&#10;"),
            '\r' => escaped.push_str("&#13;"),
            _ => escaped.push(character),
        }
    }
    escaped
}

/// Authors are separated by semicolons in the panel and in `/Info`, matching the recogniser.
fn split_authors(value: &str) -> Vec<String> {
    value
        .split(';')
        .map(str::trim)
        .filter(|author| !author.is_empty())
        .map(str::to_string)
        .collect()
}

fn alt(inner: &str) -> String {
    format!("<rdf:Alt><rdf:li xml:lang=\"x-default\">{inner}</rdf:li></rdf:Alt>")
}

fn seq(items: &[String]) -> String {
    let mut body = String::from("<rdf:Seq>");
    for item in items {
        let _ = write!(body, "<rdf:li>{}</rdf:li>", escape_text(item));
    }
    body.push_str("</rdf:Seq>");
    body
}

/// The inner XML for a property, or `None` when the property must not be present.
///
/// `dc:title` and `dc:creator` are always present in an edited packet (an empty container
/// clears an older revision's value); `dc:description` and `pdf:Keywords` are omitted when
/// empty, because no source reads them through the revision-merge path.
///
/// `existing` is the property's current inner XML. When a title/subject `rdf:Alt` carries
/// additional language alternatives, those `rdf:li` items are kept and the edited value becomes
/// the first (`x-default`) item, so the recogniser reads the edit while the translations another
/// tool wrote are not thrown away.
fn property_inner(
    name: &str,
    properties: &crate::document_properties::DocumentProperties,
    existing: Option<&str>,
) -> Option<String> {
    match name {
        "dc:title" => Some(alt_updated(existing.unwrap_or(""), &properties.title)),
        "dc:creator" => Some(seq(&split_authors(&properties.author))),
        "dc:description" if !properties.subject.is_empty() => {
            Some(alt_updated(existing.unwrap_or(""), &properties.subject))
        }
        "pdf:Keywords" if !properties.keywords.is_empty() => {
            Some(escape_text(&properties.keywords))
        }
        _ => None,
    }
}

/// Rebuilds an `rdf:Alt` with the edited `x-default` first and other languages preserved.
fn alt_updated(existing: &str, value: &str) -> String {
    let preserved = preserved_alternatives(existing);
    if preserved.is_empty() {
        alt(&escape_text(value))
    } else {
        format!(
            "<rdf:Alt><rdf:li xml:lang=\"x-default\">{}</rdf:li>{preserved}</rdf:Alt>",
            escape_text(value)
        )
    }
}

/// Every `rdf:li` of the existing `rdf:Alt` whose language is not `x-default`, raw.
fn preserved_alternatives(existing: &str) -> String {
    let Ok(elements) = scan(existing) else {
        return String::new();
    };
    let Some((alt_index, _)) = elements
        .iter()
        .enumerate()
        .find(|(_, element)| element.name == "rdf:Alt" && element.parent.is_none())
    else {
        return String::new();
    };
    let mut preserved = String::new();
    for element in &elements {
        if element.name != "rdf:li" || element.parent != Some(alt_index) {
            continue;
        }
        match attribute_value(element, existing, "xml:lang") {
            Some(language) if language != "x-default" => {
                preserved.push_str(&existing[element.start..element.end]);
            }
            _ => {}
        }
    }
    preserved
}

fn element(name: &str, inner: &str) -> String {
    format!("<{name}>{inner}</{name}>")
}

/// Builds the minimal packet a document without `/Metadata` receives.
fn create_packet(properties: &crate::document_properties::DocumentProperties) -> Result<Vec<u8>> {
    validate_all(properties)?;
    let mut children = String::new();
    for (name, value) in edited_fields(properties) {
        if value.is_empty() {
            continue;
        }
        let inner = property_inner(name, properties, None)
            .ok_or_else(|| malformed(format!("no XMP form is defined for {name}")))?;
        let _ = write!(children, "\n   {}", element(name, &inner));
    }
    let mut namespaces = String::new();
    if !properties.title.is_empty()
        || !properties.author.is_empty()
        || !properties.subject.is_empty()
    {
        let _ = write!(namespaces, "\n    xmlns:dc=\"{DC_NAMESPACE}\"");
    }
    if !properties.keywords.is_empty() {
        let _ = write!(namespaces, "\n    xmlns:pdf=\"{PDF_NAMESPACE}\"");
    }
    let mut packet = String::new();
    packet.push_str("<?xpacket begin=\"\u{feff}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n");
    packet.push_str("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">\n");
    packet.push_str(" <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n");
    let _ = write!(
        packet,
        "  <rdf:Description rdf:about=\"\"{namespaces}>{children}\n  </rdf:Description>\n"
    );
    packet.push_str(" </rdf:RDF>\n</x:xmpmeta>\n<?xpacket end=\"w\"?>");
    Ok(packet.into_bytes())
}

// ── A tag-structure scanner ──────────────────────────────────────────────────
//
// XMP is XML, but pulling in an XML parser (and, more importantly, reserialising through it) is
// the thing this module exists to avoid. The scanner only needs what the four properties use:
// element spans, attributes, comments/CDATA skipping and balanced-tag validation. It rejects
// anything it cannot express exactly instead of guessing.

#[derive(Clone, Debug)]
struct Attribute {
    name: String,
    /// Start of the attribute name, including the whitespace before it.
    removal_start: usize,
    /// End of the closing quote.
    end: usize,
    value_start: usize,
    value_end: usize,
}

#[derive(Clone, Debug)]
struct Element {
    name: String,
    start: usize,
    /// After the opening `>`.
    open_end: usize,
    /// Start of the closing `</name`; equals `open_end` for a self-closing element.
    close_start: usize,
    /// After the closing `>`.
    end: usize,
    /// Index of `/` for a self-closing tag, otherwise the index of `>`.
    tag_close: usize,
    self_closing: bool,
    parent: Option<usize>,
    attributes: Vec<Attribute>,
}

fn name_end(bytes: &[u8], start: usize) -> std::result::Result<usize, String> {
    let mut cursor = start;
    while cursor < bytes.len() {
        let byte = bytes[cursor];
        if byte.is_ascii_whitespace() || matches!(byte, b'>' | b'/' | b'<' | b'=') {
            break;
        }
        cursor += 1;
    }
    if cursor == start {
        return Err("an XML tag has no name".to_string());
    }
    Ok(cursor)
}

/// The index of the `>` that ends a tag, respecting quoted attribute values.
fn tag_end(bytes: &[u8], start: usize) -> std::result::Result<usize, String> {
    let mut cursor = start;
    let mut quote = None;
    while cursor < bytes.len() {
        let byte = bytes[cursor];
        match quote {
            Some(active) if byte == active => quote = None,
            Some(_) => {}
            None if byte == b'"' || byte == b'\'' => quote = Some(byte),
            None if byte == b'>' => return Ok(cursor),
            None if byte == b'<' => return Err("a tag contains another '<'".to_string()),
            None => {}
        }
        cursor += 1;
    }
    Err("a tag is not closed before the end of the packet".to_string())
}

fn parse_attributes(
    text: &str,
    start: usize,
    end: usize,
) -> std::result::Result<Vec<Attribute>, String> {
    let bytes = text.as_bytes();
    let mut attributes = Vec::new();
    let mut cursor = start;
    while cursor < end {
        let removal_start = cursor;
        while cursor < end && bytes[cursor].is_ascii_whitespace() {
            cursor += 1;
        }
        if cursor >= end {
            break;
        }
        let name_start = cursor;
        while cursor < end
            && !bytes[cursor].is_ascii_whitespace()
            && !matches!(bytes[cursor], b'=' | b'/' | b'>')
        {
            cursor += 1;
        }
        let name = &text[name_start..cursor];
        if name.is_empty() {
            return Err("an XML attribute has no name".to_string());
        }
        while cursor < end && bytes[cursor].is_ascii_whitespace() {
            cursor += 1;
        }
        if cursor >= end || bytes[cursor] != b'=' {
            return Err(format!("the XML attribute {name:?} has no value"));
        }
        cursor += 1;
        while cursor < end && bytes[cursor].is_ascii_whitespace() {
            cursor += 1;
        }
        let quote = *bytes
            .get(cursor)
            .filter(|byte| **byte == b'"' || **byte == b'\'')
            .ok_or_else(|| format!("the XML attribute {name:?} is not quoted"))?;
        cursor += 1;
        let value_start = cursor;
        while cursor < end && bytes[cursor] != quote {
            cursor += 1;
        }
        if cursor >= end {
            return Err(format!("the XML attribute {name:?} is not closed"));
        }
        let value_end = cursor;
        cursor += 1;
        if attributes
            .iter()
            .any(|attribute: &Attribute| attribute.name == name)
        {
            return Err(format!("the XML attribute {name:?} appears twice"));
        }
        attributes.push(Attribute {
            name: name.to_string(),
            removal_start,
            end: cursor,
            value_start,
            value_end,
        });
    }
    Ok(attributes)
}

fn scan(text: &str) -> std::result::Result<Vec<Element>, String> {
    let bytes = text.as_bytes();
    let mut elements: Vec<Element> = Vec::new();
    let mut stack: Vec<usize> = Vec::new();
    let mut cursor = 0usize;

    while cursor < bytes.len() {
        let Some(offset) = text[cursor..].find('<') else {
            break;
        };
        let start = cursor + offset;

        if text[start..].starts_with("<!--") {
            let close = text[start + 4..]
                .find("-->")
                .ok_or_else(|| "an XML comment is not closed".to_string())?;
            cursor = start + 4 + close + 3;
            continue;
        }
        if text[start..].starts_with("<![CDATA[") {
            let close = text[start + 9..]
                .find("]]>")
                .ok_or_else(|| "a CDATA section is not closed".to_string())?;
            cursor = start + 9 + close + 3;
            continue;
        }
        if text[start..].starts_with("<?") {
            let close = text[start + 2..]
                .find("?>")
                .ok_or_else(|| "a processing instruction is not closed".to_string())?;
            cursor = start + 2 + close + 2;
            continue;
        }
        if text[start..].starts_with("<!") {
            let close = tag_end(bytes, start + 2)?;
            cursor = close + 1;
            continue;
        }

        if text[start..].starts_with("</") {
            let name_start = start + 2;
            let name_end = name_end(bytes, name_start)?;
            let close = tag_end(bytes, name_end)?;
            let name = &text[name_start..name_end];
            let open = stack
                .pop()
                .ok_or_else(|| format!("the closing tag </{name}> has no opening tag"))?;
            if elements[open].name != name {
                return Err(format!(
                    "the closing tag </{name}> does not match <{}>",
                    elements[open].name
                ));
            }
            elements[open].close_start = start;
            elements[open].end = close + 1;
            cursor = close + 1;
            continue;
        }

        let name_start = start + 1;
        let name_end = name_end(bytes, name_start)?;
        let name = text[name_start..name_end].to_string();
        let close = tag_end(bytes, name_end)?;
        let mut slash = close;
        while slash > name_end && bytes[slash - 1].is_ascii_whitespace() {
            slash -= 1;
        }
        let self_closing = slash > name_end && bytes[slash - 1] == b'/';
        let tag_close = if self_closing { slash - 1 } else { close };
        let attributes = parse_attributes(text, name_end, tag_close)?;
        let parent = stack.last().copied();
        let index = elements.len();
        elements.push(Element {
            name,
            start,
            open_end: close + 1,
            close_start: if self_closing { close + 1 } else { 0 },
            end: if self_closing { close + 1 } else { 0 },
            tag_close,
            self_closing,
            parent,
            attributes,
        });
        if !self_closing {
            stack.push(index);
        }
        cursor = close + 1;
    }

    if let Some(open) = stack.last() {
        return Err(format!("<{}> is never closed", elements[*open].name));
    }
    Ok(elements)
}

#[derive(Clone, Copy, Debug)]
enum Occurrence {
    Element(usize),
    Attribute { element: usize, attribute: usize },
}

fn occurrences(elements: &[Element], name: &str) -> Vec<Occurrence> {
    let mut found = Vec::new();
    for (index, element) in elements.iter().enumerate() {
        if element.name == name {
            found.push(Occurrence::Element(index));
        }
        for (attribute_index, attribute) in element.attributes.iter().enumerate() {
            if attribute.name == name {
                found.push(Occurrence::Attribute {
                    element: index,
                    attribute: attribute_index,
                });
            }
        }
    }
    found
}

struct Replacement {
    start: usize,
    end: usize,
    text: String,
}

fn apply_replacements(
    text: &str,
    mut replacements: Vec<Replacement>,
) -> std::result::Result<String, String> {
    replacements.sort_by_key(|replacement| replacement.start);
    for pair in replacements.windows(2) {
        if pair[0].end > pair[1].start {
            return Err(format!("two updates overlap at byte {}", pair[0].end));
        }
    }
    let mut output = text.to_string();
    for replacement in replacements.into_iter().rev() {
        output.replace_range(replacement.start..replacement.end, &replacement.text);
    }
    Ok(output)
}

fn update_packet(
    packet: &[u8],
    properties: &crate::document_properties::DocumentProperties,
) -> Result<Vec<u8>> {
    validate_all(properties)?;
    let text = std::str::from_utf8(packet)
        .map_err(|error| malformed(format!("the packet is not UTF-8: {error}")))?;
    let elements = scan(text)
        .map_err(|error| malformed(format!("the packet's XML is not balanced: {error}")))?;
    if !elements.iter().any(|element| element.name == "rdf:RDF") {
        return Err(malformed("the packet has no <rdf:RDF> container"));
    }

    let mut replacements = Vec::new();
    let mut missing: Vec<&str> = Vec::new();

    for (name, _) in edited_fields(properties) {
        let should_exist = property_inner(name, properties, None).is_some();
        let found = occurrences(&elements, name);
        if !should_exist {
            for occurrence in found {
                match occurrence {
                    Occurrence::Element(index) => {
                        let element = &elements[index];
                        replacements.push(Replacement {
                            start: element.start,
                            end: element.end,
                            text: String::new(),
                        });
                    }
                    Occurrence::Attribute {
                        element: element_index,
                        attribute: attribute_index,
                    } => {
                        let attribute = &elements[element_index].attributes[attribute_index];
                        replacements.push(Replacement {
                            start: attribute.removal_start,
                            end: attribute.end,
                            text: String::new(),
                        });
                    }
                }
            }
            continue;
        }
        if found.is_empty() {
            missing.push(name);
        }
        for occurrence in found {
            match occurrence {
                Occurrence::Element(index) => {
                    let element = &elements[index];
                    let existing_inner = if element.self_closing {
                        ""
                    } else {
                        &text[element.open_end..element.close_start]
                    };
                    let inner = property_inner(name, properties, Some(existing_inner))
                        .ok_or_else(|| malformed(format!("no XMP form is defined for {name}")))?;
                    let opening = if element.self_closing {
                        let mut opening = text[element.start..element.tag_close].to_string();
                        while opening.chars().last().is_some_and(char::is_whitespace) {
                            opening.pop();
                        }
                        opening.push('>');
                        opening
                    } else {
                        text[element.start..element.open_end].to_string()
                    };
                    replacements.push(Replacement {
                        start: element.start,
                        end: element.end,
                        text: format!("{opening}{inner}</{name}>"),
                    });
                }
                Occurrence::Attribute {
                    element: element_index,
                    attribute: attribute_index,
                } => {
                    let attribute = &elements[element_index].attributes[attribute_index];
                    let value = match name {
                        "dc:creator" => split_authors(&properties.author).join("; "),
                        "dc:title" => properties.title.clone(),
                        "dc:description" => properties.subject.clone(),
                        "pdf:Keywords" => properties.keywords.clone(),
                        _ => String::new(),
                    };
                    replacements.push(Replacement {
                        start: attribute.value_start,
                        end: attribute.value_end,
                        text: escape_attribute(&value),
                    });
                }
            }
        }
    }

    let updated = apply_replacements(text, replacements)
        .map_err(|error| malformed(format!("the packet's properties overlap: {error}")))?;

    let with_missing = if missing.is_empty() {
        updated
    } else {
        insert_missing(&updated, &missing, properties)?
    };

    validate_packet(&with_missing, properties)?;
    Ok(with_missing.into_bytes())
}

fn attribute_value(element: &Element, text: &str, name: &str) -> Option<String> {
    element
        .attributes
        .iter()
        .find(|attribute| attribute.name == name)
        .map(|attribute| text[attribute.value_start..attribute.value_end].to_string())
}

fn insert_missing(
    text: &str,
    missing: &[&str],
    properties: &crate::document_properties::DocumentProperties,
) -> Result<String> {
    let elements = scan(text).map_err(|error| malformed(error.to_string()))?;
    let description = elements
        .iter()
        .enumerate()
        .filter(|(_, element)| element.name == "rdf:Description")
        .filter(|(_, element)| {
            element
                .parent
                .is_some_and(|parent| elements[parent].name == "rdf:RDF")
        })
        .max_by_key(|(_, element)| {
            // Prefer the description that is about the empty resource (the document itself);
            // it is the one a packet conventionally describes.
            usize::from(matches!(
                attribute_value(element, text, "rdf:about").as_deref(),
                Some("")
            ))
        })
        .map(|(index, _)| index)
        .ok_or_else(|| malformed("the packet has no top-level <rdf:Description>"))?;
    let description = &elements[description];

    let mut needed_dc = false;
    let mut needed_pdf = false;
    for name in missing {
        match *name {
            "dc:title" | "dc:creator" | "dc:description" => needed_dc = true,
            "pdf:Keywords" => needed_pdf = true,
            _ => {}
        }
    }

    let mut declarations = String::new();
    if needed_dc {
        match attribute_value(description, text, "xmlns:dc") {
            Some(value) if value == DC_NAMESPACE => {}
            Some(value) => {
                return Err(malformed(format!(
                    "the packet binds dc: to {value:?}, not the Dublin Core namespace"
                )));
            }
            None => {
                let _ = write!(declarations, " xmlns:dc=\"{DC_NAMESPACE}\"");
            }
        }
    }
    if needed_pdf {
        match attribute_value(description, text, "xmlns:pdf") {
            Some(value) if value == PDF_NAMESPACE => {}
            Some(value) => {
                return Err(malformed(format!(
                    "the packet binds pdf: to {value:?}, not the Adobe PDF namespace"
                )));
            }
            None => {
                let _ = write!(declarations, " xmlns:pdf=\"{PDF_NAMESPACE}\"");
            }
        }
    }

    let mut children = String::new();
    for name in missing {
        let inner = property_inner(name, properties, None)
            .ok_or_else(|| malformed(format!("no XMP form is defined for {name}")))?;
        let _ = write!(children, "\n   {}", element(name, &inner));
    }
    children.push_str("\n  ");

    if description.self_closing {
        let mut opening = text[description.start..description.tag_close].to_string();
        while opening.chars().last().is_some_and(char::is_whitespace) {
            opening.pop();
        }
        let replacement = format!("{opening}{declarations}>{children}</rdf:Description>");
        let mut updated = text.to_string();
        updated.replace_range(description.start..description.open_end, &replacement);
        Ok(updated)
    } else {
        let mut replacements = vec![Replacement {
            start: description.close_start,
            end: description.close_start,
            text: children,
        }];
        if !declarations.is_empty() {
            replacements.push(Replacement {
                start: description.tag_close,
                end: description.tag_close,
                text: declarations,
            });
        }
        apply_replacements(text, replacements).map_err(|error| malformed(error.to_string()))
    }
}

/// Checks that the packet this writer produced still reads as the four values being written.
fn validate_packet(
    text: &str,
    properties: &crate::document_properties::DocumentProperties,
) -> Result<()> {
    let elements =
        scan(text).map_err(|error| malformed(format!("the written packet is invalid: {error}")))?;
    let parsed = parse_packet(text);
    if properties.title.is_empty() {
        if parsed.title.is_some() {
            return Err(malformed(
                "the written packet does not read back an empty title",
            ));
        }
    } else if collapsed(parsed.title.as_deref().unwrap_or_default()) != collapsed(&properties.title)
    {
        return Err(malformed(format!(
            "the written packet reads back title {:?}, not {:?}",
            parsed.title, properties.title
        )));
    }
    let expected_authors = split_authors(&properties.author)
        .iter()
        .map(|author| collapsed(author))
        .collect::<Vec<_>>();
    let actual_authors = parsed
        .authors
        .iter()
        .map(|author| collapsed(author))
        .collect::<Vec<_>>();
    if expected_authors != actual_authors {
        return Err(malformed(format!(
            "the written packet reads back authors {actual_authors:?}, not {expected_authors:?}"
        )));
    }
    if !properties.subject.is_empty() && occurrences(&elements, "dc:description").is_empty() {
        return Err(malformed("the written packet has no dc:description"));
    }
    if !properties.keywords.is_empty() && occurrences(&elements, "pdf:Keywords").is_empty() {
        return Err(malformed("the written packet has no pdf:Keywords"));
    }
    Ok(())
}

fn collapsed(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Fingerprints every property and namespace declaration this writer does **not** own.
///
/// Used by the save verification: each fingerprint found in the source packet must still be
/// present, unchanged, in the saved packet. Properties the writer owns (`dc:title`, `dc:creator`,
/// `dc:description`, `pdf:Keywords`), their `rdf:li` items and the containers around them are
/// excluded; everything else — camera fields, software, rights, custom namespaces, `rdf:about` —
/// is recorded with its exact raw value.
pub(crate) fn preserved_fingerprint(packet: &[u8]) -> Vec<String> {
    let text = match std::str::from_utf8(packet) {
        Ok(text) => text,
        Err(_) => return vec![format!("<invalid utf-8: {} bytes>", packet.len())],
    };
    let elements = match scan(text) {
        Ok(elements) => elements,
        Err(error) => return vec![format!("<invalid xml: {error}>")],
    };
    let owned = ["dc:title", "dc:creator", "dc:description", "pdf:Keywords"];
    let owned_elements: std::collections::BTreeSet<usize> = elements
        .iter()
        .enumerate()
        .filter(|(_, element)| owned.contains(&element.name.as_str()))
        .map(|(index, _)| index)
        .collect();
    let inside_owned = |index: usize| {
        let mut current = Some(index);
        while let Some(element) = current {
            if owned_elements.contains(&element) {
                return true;
            }
            current = elements[element].parent;
        }
        false
    };
    let mut fingerprints: Vec<String> = Vec::new();
    for (index, element) in elements.iter().enumerate() {
        if inside_owned(index) {
            continue;
        }
        let has_child_elements = elements
            .iter()
            .any(|candidate| candidate.parent == Some(index));
        if !has_child_elements {
            let content = if element.self_closing {
                String::new()
            } else {
                text[element.open_end..element.close_start].to_string()
            };
            fingerprints.push(format!("element {} = {content}", element.name));
        }
        for attribute in &element.attributes {
            fingerprints.push(format!(
                "attribute {} = {}",
                attribute.name,
                &text[attribute.value_start..attribute.value_end]
            ));
        }
    }
    fingerprints.sort();
    fingerprints
}

/// Builds the stream a created `/Metadata` entry receives.
pub(crate) fn metadata_stream(packet: Vec<u8>) -> Result<Stream> {
    let compressed = compress(&packet)?;
    let mut dictionary = Dictionary::new();
    dictionary.set("Type", Object::Name(b"Metadata".to_vec()));
    dictionary.set("Subtype", Object::Name(b"XML".to_vec()));
    dictionary.set("Filter", Object::Name(b"FlateDecode".to_vec()));
    let mut stream = Stream::new(dictionary, compressed);
    stream.allows_compression = false;
    Ok(stream)
}

/// Writes `packet` into an existing metadata stream, preserving its dictionary except for the
/// encoding keys this writer has to own.
pub(crate) fn set_metadata_packet(stream: &mut Stream, packet: &[u8]) -> Result<()> {
    if !stream.dict.has(b"Type") {
        stream.dict.set("Type", Object::Name(b"Metadata".to_vec()));
    }
    if !stream.dict.has(b"Subtype") {
        stream.dict.set("Subtype", Object::Name(b"XML".to_vec()));
    }
    let was_compressed = stream.dict.get(b"Filter").is_ok();
    if was_compressed {
        let compressed = compress(packet)?;
        stream.dict.remove(b"DecodeParms");
        stream
            .dict
            .set("Filter", Object::Name(b"FlateDecode".to_vec()));
        stream.set_content(compressed);
    } else {
        stream.set_plain_content(packet.to_vec());
    }
    Ok(())
}

fn compress(packet: &[u8]) -> Result<Vec<u8>> {
    let mut encoder = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(packet).map_err(|error| {
        LyraReaderError::new(ErrorCode::Io, "could not compress the XMP metadata packet")
            .with_detail(error.to_string())
    })?;
    encoder.finish().map_err(|error| {
        LyraReaderError::new(ErrorCode::Io, "could not finish the compressed XMP packet")
            .with_detail(error.to_string())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document_properties::DocumentProperties;

    const PACKET: &str = r#"<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmlns:pdf="http://ns.adobe.com/pdf/1.3/"
    xmlns:prism="http://prismstandard.org/namespaces/basic/2.0/"
    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
    xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
   <dc:title><rdf:Alt><rdf:li xml:lang="x-default">Old title</rdf:li></rdf:Alt></dc:title>
   <dc:creator><rdf:Seq><rdf:li>Old Author</rdf:li></rdf:Seq></dc:creator>
   <prism:doi>10.1234/keep.me</prism:doi>
   <prism:publicationName>Journal of Things</prism:publicationName>
   <prism:coverDate>2021-04-05</prism:coverDate>
   <xmp:CreatorTool>Some Camera Software 3.2</xmp:CreatorTool>
   <photoshop:ColorMode>RGB</photoshop:ColorMode>
   <photoshop:History>first edit</photoshop:History>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>"#;

    fn edited() -> DocumentProperties {
        DocumentProperties {
            title: "Edited & <New> Title".to_string(),
            author: "Ada Lovelace; Alan Turing; Grace Hopper".to_string(),
            subject: "A corrected subject".to_string(),
            keywords: "one, two".to_string(),
        }
    }

    #[test]
    fn updates_only_the_edited_properties_and_keeps_the_rest_verbatim() {
        let before = PACKET.as_bytes();
        let after = update_packet(before, &edited()).expect("update packet");
        let text = String::from_utf8(after.clone()).unwrap();
        assert!(text.contains("Edited &amp; &lt;New&gt; Title"));
        assert!(text.contains("<rdf:Seq><rdf:li>Ada Lovelace</rdf:li><rdf:li>Alan Turing</rdf:li><rdf:li>Grace Hopper</rdf:li></rdf:Seq>"));
        assert!(text.contains("<dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">A corrected subject</rdf:li></rdf:Alt></dc:description>"));
        assert!(text.contains("<pdf:Keywords>one, two</pdf:Keywords>"));
        assert!(!text.contains("Old title"));
        assert!(!text.contains("Old Author"));
        // Every unowned property is still there with the same value.
        assert!(text.contains("<prism:doi>10.1234/keep.me</prism:doi>"));
        assert!(text.contains("<prism:publicationName>Journal of Things</prism:publicationName>"));
        assert!(text.contains("<prism:coverDate>2021-04-05</prism:coverDate>"));
        assert!(text.contains("<xmp:CreatorTool>Some Camera Software 3.2</xmp:CreatorTool>"));
        assert!(text.contains("<photoshop:ColorMode>RGB</photoshop:ColorMode>"));
        assert!(text.contains("<photoshop:History>first edit</photoshop:History>"));
        // Namespace declarations survive.
        for declaration in [
            "xmlns:dc=\"http://purl.org/dc/elements/1.1/\"",
            "xmlns:pdf=\"http://ns.adobe.com/pdf/1.3/\"",
            "xmlns:prism=\"http://prismstandard.org/namespaces/basic/2.0/\"",
            "xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"",
            "xmlns:photoshop=\"http://ns.adobe.com/photoshop/1.0/\"",
        ] {
            assert!(text.contains(declaration), "{declaration}");
        }
        assert_eq!(preserved_fingerprint(before), preserved_fingerprint(&after));
        // The xpacket wrapper is untouched.
        assert!(text.starts_with("<?xpacket begin=\"\u{feff}\""));
        assert!(text.ends_with("<?xpacket end=\"w\"?>"));
    }

    #[test]
    fn parses_back_the_edited_values() {
        let after = update_packet(PACKET.as_bytes(), &edited()).unwrap();
        let parsed = parse_packet(std::str::from_utf8(&after).unwrap());
        assert_eq!(parsed.title.as_deref(), Some("Edited & <New> Title"));
        assert_eq!(
            parsed.authors,
            vec!["Ada Lovelace", "Alan Turing", "Grace Hopper"]
        );
        assert_eq!(parsed.doi.as_deref(), Some("10.1234/keep.me"));
        assert_eq!(parsed.venue.as_deref(), Some("Journal of Things"));
        assert_eq!(parsed.year.as_deref(), Some("2021"));
    }

    #[test]
    fn a_missing_property_is_inserted_with_its_namespace() {
        let packet = r#"<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about="" xmlns:prism="http://prismstandard.org/namespaces/basic/2.0/">
   <prism:doi>10.1/keep</prism:doi>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>"#;
        let after = update_packet(packet.as_bytes(), &edited()).unwrap();
        let text = String::from_utf8(after).unwrap();
        assert!(text.contains("xmlns:dc=\"http://purl.org/dc/elements/1.1/\""));
        assert!(text.contains("xmlns:pdf=\"http://ns.adobe.com/pdf/1.3/\""));
        assert!(text.contains("<dc:title>"));
        assert!(text.contains("<dc:creator>"));
        assert!(text.contains("<dc:description>"));
        assert!(text.contains("<pdf:Keywords>"));
        assert!(text.contains("<prism:doi>10.1/keep</prism:doi>"));
    }

    #[test]
    fn an_empty_title_is_written_as_an_empty_alt_so_an_older_revision_cannot_reappear() {
        let mut properties = edited();
        properties.title.clear();
        properties.author.clear();
        let after = update_packet(PACKET.as_bytes(), &properties).unwrap();
        let text = String::from_utf8(after).unwrap();
        assert!(
            text.contains(
                "<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\"></rdf:li></rdf:Alt></dc:title>"
            ),
            "{text}"
        );
        assert!(
            text.contains("<dc:creator><rdf:Seq></rdf:Seq></dc:creator>"),
            "{text}"
        );
        let parsed = parse_packet(&text);
        assert_eq!(parsed.title, None);
        assert!(parsed.authors.is_empty());
    }

    #[test]
    fn self_closing_descriptions_and_attributes_are_handled() {
        let packet = r#"<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" dc:title="Old attribute title" xmlns:dc="http://purl.org/dc/elements/1.1/"/></rdf:RDF>"#;
        let after = update_packet(packet.as_bytes(), &edited()).unwrap();
        let text = String::from_utf8(after).unwrap();
        assert!(
            text.contains("dc:title=\"Edited &amp; &lt;New&gt; Title\""),
            "{text}"
        );
        assert!(text.contains("<dc:creator><rdf:Seq>"), "{text}");
        assert!(text.contains("</rdf:Description></rdf:RDF>"), "{text}");
        let parsed = parse_packet(&text);
        assert_eq!(parsed.title.as_deref(), Some("Edited & <New> Title"));
    }

    #[test]
    fn an_unbalanced_or_non_xmp_packet_is_refused() {
        for packet in [
            "<rdf:RDF><dc:title>",
            "<html><body>not xmp</body></html>",
            "<rdf:RDF></rdf:RDF>",
            "<?xpacket?><not-rdf/>",
        ] {
            let error = update_packet(packet.as_bytes(), &edited()).expect_err(packet);
            assert_eq!(error.code, ErrorCode::CorruptDocument, "{packet}");
            assert!(error.message.contains("XMP"), "{}", error.message);
        }
    }

    #[test]
    fn a_creator_sequence_with_several_authors_round_trips() {
        let packet = r#"<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:creator><rdf:Seq><rdf:li>Ada Lovelace</rdf:li><rdf:li>Alan Turing</rdf:li></rdf:Seq></dc:creator></rdf:Description></rdf:RDF>"#;
        let after = update_packet(packet.as_bytes(), &edited()).unwrap();
        let text = String::from_utf8(after).unwrap();
        let creator = text
            .split("<dc:creator>")
            .nth(1)
            .and_then(|rest| rest.split("</dc:creator>").next())
            .expect("creator element");
        assert_eq!(creator.matches("<rdf:li>").count(), 3, "{text}");
        assert_eq!(creator.matches("</rdf:li>").count(), 3, "{text}");
        let parsed = parse_packet(&text);
        assert_eq!(
            parsed.authors,
            vec!["Ada Lovelace", "Alan Turing", "Grace Hopper"]
        );
    }

    #[test]
    fn a_created_packet_is_valid_and_reads_back() {
        let packet = create_packet(&edited()).unwrap();
        let text = std::str::from_utf8(&packet).unwrap();
        assert!(text.starts_with("<?xpacket"));
        assert!(text.contains("<x:xmpmeta"));
        assert!(text.contains("<rdf:RDF"));
        assert!(text.contains("xmlns:dc=\"http://purl.org/dc/elements/1.1/\""));
        assert!(text.contains("xmlns:pdf=\"http://ns.adobe.com/pdf/1.3/\""));
        let parsed = parse_packet(text);
        assert_eq!(parsed.title.as_deref(), Some("Edited & <New> Title"));
        assert_eq!(
            parsed.authors,
            vec!["Ada Lovelace", "Alan Turing", "Grace Hopper"]
        );
        scan(text).expect("balanced");
    }

    #[test]
    fn other_language_title_alternatives_are_preserved() {
        let packet = r#"<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title><rdf:Alt><rdf:li xml:lang="x-default">Old title</rdf:li><rdf:li xml:lang="fr">Vieux titre</rdf:li><rdf:li xml:lang="de">Alter Titel</rdf:li></rdf:Alt></dc:title></rdf:Description></rdf:RDF>"#;
        let after = update_packet(packet.as_bytes(), &edited()).unwrap();
        let text = String::from_utf8(after).unwrap();
        assert!(
            text.contains(
                "<rdf:Alt><rdf:li xml:lang=\"x-default\">Edited &amp; &lt;New&gt; Title</rdf:li><rdf:li xml:lang=\"fr\">Vieux titre</rdf:li><rdf:li xml:lang=\"de\">Alter Titel</rdf:li></rdf:Alt>"
            ),
            "{text}"
        );
        assert_eq!(
            parse_packet(&text).title.as_deref(),
            Some("Edited & <New> Title"),
            "the recogniser reads the edited x-default first"
        );
        scan(&text).expect("balanced");
    }

    #[test]
    fn a_value_with_xml_control_characters_is_refused() {
        let mut properties = edited();
        properties.title.push('\u{1}');
        let error = update_packet(PACKET.as_bytes(), &properties).expect_err("control character");
        assert_eq!(error.code, ErrorCode::InvalidArgument);
    }
}
