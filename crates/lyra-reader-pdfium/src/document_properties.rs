//! The document information dictionary (`/Info`): the read-only facts a PDF cannot lie about
//! through layout, and the four properties the information panel edits.
//!
//! The page count comes from the page tree, the PDF version from the file header and the
//! encryption state from the security handler. The four editable entries are written through the
//! same verified incremental save as form values ([`crate::writeback::save_incremental_with_contract`]):
//! the original bytes stay the prefix, the temporary file is reopened and checked, and the
//! rename is atomic. An encrypted document is refused with a reason instead of being written
//! with a broken envelope.

use crate::forms::{
    decode_text_string, dict_get, document_is_encrypted, load_document, pdf_header_version,
    resolve, text_string_object,
};
use crate::writeback::{IncrementalSaveReport, SaveMode, save_incremental_with_contract};
use crate::xmp::parse_packet;
use crate::xmp_write::{
    MetadataUpdate, metadata_stream, prepare_metadata_update, preserved_fingerprint,
    read_metadata_packet, set_metadata_packet,
};
use lopdf::{Dictionary, Document, IncrementalDocument, Object};
use lyra_reader_core::{ErrorCode, LyraReaderError, Result};
use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

/// The four `/Info` entries the information panel edits.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DocumentProperties {
    pub title: String,
    pub author: String,
    pub subject: String,
    pub keywords: String,
}

impl DocumentProperties {
    fn entries(&self) -> [(&'static str, &str); 4] {
        [
            ("Title", &self.title),
            ("Author", &self.author),
            ("Subject", &self.subject),
            ("Keywords", &self.keywords),
        ]
    }
}

/// The facts the information panel shows but never edits.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DocumentFacts {
    pub page_count: u32,
    /// `1.4`, `1.7`, … from the file header; `unknown` when the header is unreadable.
    pub pdf_version: String,
    pub is_encrypted: bool,
}

/// Everything the information panel reads.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DocumentInfo {
    pub facts: DocumentFacts,
    pub properties: DocumentProperties,
    /// Whether the source has an `/Info` dictionary at all. A document without one can still be
    /// given one; the panel says "no information dictionary" rather than showing four empties
    /// as if they were stored.
    pub has_info_dictionary: bool,
}

/// What a successful properties save did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PropertiesSaveReport {
    pub destination: PathBuf,
    pub written_keys: Vec<String>,
    pub appended_bytes: u64,
    pub backup_path: Option<PathBuf>,
    pub cleaned_temporaries: usize,
    pub source_bytes_preserved: bool,
    /// True when the document had no XMP packet and this save created one.
    pub xmp_created: bool,
    /// True when an existing XMP packet was rewritten. False means the packet already agreed
    /// with the values and was left byte-for-byte untouched.
    pub xmp_updated: bool,
}

fn info_entry(document: &Document, dictionary: &Dictionary, key: &[u8]) -> Option<String> {
    dict_get(document, dictionary, key).and_then(|object| match object {
        Object::String(bytes, _) => Some(decode_text_string(bytes)),
        _ => None,
    })
}

fn info_dictionary(document: &Document) -> Option<&Dictionary> {
    document
        .trailer
        .get(b"Info")
        .ok()
        .and_then(|object| resolve(document, object))
        .and_then(|object| object.as_dict().ok())
}

fn properties_from(document: &Document) -> (DocumentProperties, bool) {
    let Some(dictionary) = info_dictionary(document) else {
        return (DocumentProperties::default(), false);
    };
    (
        DocumentProperties {
            title: info_entry(document, dictionary, b"Title").unwrap_or_default(),
            author: info_entry(document, dictionary, b"Author").unwrap_or_default(),
            subject: info_entry(document, dictionary, b"Subject").unwrap_or_default(),
            keywords: info_entry(document, dictionary, b"Keywords").unwrap_or_default(),
        },
        true,
    )
}

fn facts_from(document: &Document, path: &Path) -> DocumentFacts {
    DocumentFacts {
        page_count: u32::try_from(document.get_pages().len()).unwrap_or(u32::MAX),
        pdf_version: pdf_header_version(path),
        is_encrypted: document_is_encrypted(document),
    }
}

/// Reads the facts and the four editable properties.
pub fn read_document_info(path: &Path, password: Option<&str>) -> Result<DocumentInfo> {
    let document = load_document(path, password)?;
    let (properties, has_info_dictionary) = properties_from(&document);
    Ok(DocumentInfo {
        facts: facts_from(&document, path),
        properties,
        has_info_dictionary,
    })
}

/// Reads the facts without requiring the document to decrypt. Used for an encrypted file the
/// caller cannot open: the panel still has to say "encrypted", "N pages" and the version.
pub fn read_document_facts_unencrypted_header(path: &Path, page_count: u32) -> DocumentFacts {
    DocumentFacts {
        page_count,
        pdf_version: pdf_header_version(path),
        is_encrypted: true,
    }
}

fn validate(properties: &DocumentProperties) -> Result<()> {
    for (key, value) in properties.entries() {
        if value.len() > 100_000 || value.contains('\0') {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                format!("the {key} value is too long or contains a NUL"),
            ));
        }
    }
    Ok(())
}

/// Every `/Info` entry except the four this editor writes, as it was before the save.
fn other_info_entries(document: &Document) -> BTreeMap<Vec<u8>, Object> {
    let mut entries = BTreeMap::new();
    if let Some(dictionary) = info_dictionary(document) {
        for (key, value) in dictionary.iter() {
            if !matches!(
                key.as_slice(),
                b"Title" | b"Author" | b"Subject" | b"Keywords"
            ) {
                entries.insert(key.clone(), value.clone());
            }
        }
    }
    entries
}

fn verify_saved_properties(
    before: &Document,
    saved: &Path,
    expected: &DocumentProperties,
    password: Option<&str>,
    metadata: &MetadataUpdate,
) -> Result<()> {
    let after = load_document(saved, password)?;
    let (properties, has_info) = properties_from(&after);
    if !has_info || properties != *expected {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the saved file does not read back the properties that were written",
        )
        .with_detail(format!(
            "title {:?}, author {:?}, subject {:?}, keywords {:?}",
            properties.title, properties.author, properties.subject, properties.keywords
        )));
    }
    if other_info_entries(before) != other_info_entries(&after) {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "a document information entry the save did not ask for changed",
        ));
    }

    // Both sources must say the same thing, and the packet must be the one this save
    // constructed (not a stale revision left in the file).
    let packet = read_metadata_packet(&after)?.ok_or_else(|| {
        LyraReaderError::new(
            ErrorCode::Internal,
            "the saved file has no XMP metadata packet after the save",
        )
    })?;
    if packet != metadata.packet {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the saved file's XMP metadata packet is not the one that was written",
        ));
    }
    let text = std::str::from_utf8(&packet).map_err(|error| {
        LyraReaderError::new(
            ErrorCode::Internal,
            "the saved XMP metadata packet is not UTF-8",
        )
        .with_detail(error.to_string())
    })?;
    let parsed = parse_packet(text);
    let expected_title = normalized(&expected.title);
    let expected_title = (!expected_title.is_empty()).then_some(expected_title);
    if parsed.title.as_deref().map(normalized) != expected_title {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the saved XMP packet does not read back the title that was written",
        )
        .with_detail(format!(
            "XMP title {:?}, expected {:?}",
            parsed.title, expected.title
        )));
    }
    let expected_authors = expected
        .author
        .split(';')
        .map(str::trim)
        .filter(|author| !author.is_empty())
        .map(normalized)
        .collect::<Vec<_>>();
    let actual_authors = parsed
        .authors
        .iter()
        .map(|author| normalized(author))
        .collect::<Vec<_>>();
    if actual_authors != expected_authors {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the saved XMP packet does not read back the authors that were written",
        )
        .with_detail(format!(
            "XMP authors {actual_authors:?}, expected {expected_authors:?}"
        )));
    }
    // Every property the save did not own must still be present, unchanged.
    if let Some(original) = &metadata.original {
        let preserved = preserved_fingerprint(&packet);
        for fingerprint in preserved_fingerprint(original) {
            if !preserved.contains(&fingerprint) {
                return Err(LyraReaderError::new(
                    ErrorCode::Internal,
                    "an XMP property the save did not edit changed or disappeared",
                )
                .with_detail(fingerprint));
            }
        }
    }
    Ok(())
}

fn normalized(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Writes the four properties into a copy, or explicitly into the original, under the verified
/// incremental save contract. An encrypted document is refused before a byte is written.
pub fn save_document_properties(
    source: &Path,
    destination: &Path,
    properties: &DocumentProperties,
    password: Option<&str>,
    mode: SaveMode,
) -> Result<PropertiesSaveReport> {
    let base = load_document(source, password)?;
    if document_is_encrypted(&base) {
        return Err(LyraReaderError::new(
            ErrorCode::Encrypted,
            "this PDF is encrypted, so its document properties cannot be saved",
        )
        .with_detail(
            "the new information dictionary would have to be written into an encrypted file; \
             the reader does not rewrite the security envelope and refuses rather than writing \
             a file another viewer might reject"
                .to_string(),
        ));
    }
    validate(properties)?;
    // Refuse a malformed packet before any file is written: saving only /Info would leave the
    // two sources disagreeing, which is the bug this save exists to fix.
    let metadata = prepare_metadata_update(&base, properties)?;

    let previous_bytes = fs::read(source).map_err(|error| {
        LyraReaderError::new(
            ErrorCode::Io,
            "could not read the document before saving its properties",
        )
        .with_detail(format!("{}: {error}", source.display()))
    })?;
    let before = base.clone();
    let mut incremental = IncrementalDocument::create_from(previous_bytes, base);

    let existing_id = incremental
        .get_prev_documents()
        .trailer
        .get(b"Info")
        .ok()
        .and_then(|object| object.as_reference().ok());
    let info_id = if let Some(info_id) = existing_id {
        incremental
            .opt_clone_object_to_new_document(info_id)
            .map_err(|error| {
                LyraReaderError::new(
                    ErrorCode::CorruptDocument,
                    "could not copy the /Info dictionary",
                )
                .with_detail(error.to_string())
            })?;
        info_id
    } else {
        let dictionary = info_dictionary(&before).cloned().unwrap_or_default();
        incremental
            .new_document
            .add_object(Object::Dictionary(dictionary))
    };
    {
        let dictionary = incremental
            .new_document
            .get_object_mut(info_id)
            .map_err(|error| {
                LyraReaderError::new(ErrorCode::CorruptDocument, "the /Info object is missing")
                    .with_detail(error.to_string())
            })?
            .as_dict_mut()
            .map_err(|error| {
                LyraReaderError::new(ErrorCode::CorruptDocument, "/Info is not a dictionary")
                    .with_detail(error.to_string())
            })?;
        for (key, value) in properties.entries() {
            if value.is_empty() {
                dictionary.remove(key.as_bytes());
            } else {
                dictionary.set(key, text_string_object(value));
            }
        }
    }
    incremental
        .new_document
        .trailer
        .set("Info", Object::Reference(info_id));

    apply_metadata_update(&mut incremental, &metadata, &before)?;

    let report: IncrementalSaveReport = save_incremental_with_contract(
        source,
        destination,
        mode,
        |file| {
            incremental.save_to(file).map_err(|error| {
                LyraReaderError::new(ErrorCode::Io, "could not write the information dictionary")
                    .with_detail(error.to_string())
            })?;
            file.flush().map_err(|error| {
                LyraReaderError::new(ErrorCode::Io, "could not flush the information dictionary")
                    .with_detail(error.to_string())
            })?;
            Ok(())
        },
        |temp| verify_saved_properties(&before, temp, properties, password, &metadata),
    )?;

    Ok(PropertiesSaveReport {
        destination: report.destination,
        written_keys: properties
            .entries()
            .iter()
            .map(|(key, _)| (*key).to_string())
            .collect(),
        appended_bytes: report.appended_bytes,
        backup_path: report.backup_path,
        cleaned_temporaries: report.cleaned_temporaries,
        source_bytes_preserved: report.source_bytes_preserved,
        xmp_created: metadata.created,
        xmp_updated: metadata.created || metadata.changed,
    })
}

/// Writes the prepared packet into the incremental revision.
///
/// An existing stream keeps its object id (the update's xref points at the new revision). A new
/// packet is added as a new object and the catalog is cloned so it can reference it.
fn apply_metadata_update(
    incremental: &mut IncrementalDocument,
    metadata: &MetadataUpdate,
    base: &Document,
) -> Result<()> {
    if let Some(id) = metadata.existing_object {
        if !metadata.changed {
            return Ok(());
        }
        incremental
            .opt_clone_object_to_new_document(id)
            .map_err(|error| {
                LyraReaderError::new(
                    ErrorCode::CorruptDocument,
                    "could not copy the XMP metadata stream",
                )
                .with_detail(error.to_string())
            })?;
        let stream = incremental
            .new_document
            .get_object_mut(id)
            .map_err(|error| {
                LyraReaderError::new(
                    ErrorCode::CorruptDocument,
                    "the XMP metadata stream is missing",
                )
                .with_detail(error.to_string())
            })?
            .as_stream_mut()
            .map_err(|error| {
                LyraReaderError::new(ErrorCode::CorruptDocument, "/Metadata is not a stream")
                    .with_detail(error.to_string())
            })?;
        set_metadata_packet(stream, &metadata.packet)?;
        return Ok(());
    }

    if metadata.created {
        let stream = metadata_stream(metadata.packet.clone())?;
        let stream_id = incremental.new_document.add_object(Object::Stream(stream));
        let catalog_id = base
            .trailer
            .get(b"Root")
            .and_then(Object::as_reference)
            .map_err(|error| {
                LyraReaderError::new(
                    ErrorCode::CorruptDocument,
                    "the catalog is not an indirect object",
                )
                .with_detail(error.to_string())
            })?;
        incremental
            .opt_clone_object_to_new_document(catalog_id)
            .map_err(|error| {
                LyraReaderError::new(
                    ErrorCode::CorruptDocument,
                    "could not copy the document catalog",
                )
                .with_detail(error.to_string())
            })?;
        incremental
            .new_document
            .get_object_mut(catalog_id)
            .map_err(|error| {
                LyraReaderError::new(
                    ErrorCode::CorruptDocument,
                    "the document catalog is missing",
                )
                .with_detail(error.to_string())
            })?
            .as_dict_mut()
            .map_err(|error| {
                LyraReaderError::new(
                    ErrorCode::CorruptDocument,
                    "the document catalog is not a dictionary",
                )
                .with_detail(error.to_string())
            })?
            .set("Metadata", Object::Reference(stream_id));
    }
    Ok(())
}

/// The default output name for a properties copy: `<name> (properties).pdf`.
pub fn suggested_properties_copy_path(source: &Path) -> PathBuf {
    crate::forms::suggest(source, "properties")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::forms::read_form_document;
    use crate::test_support::{ScratchDir, fixture};

    #[test]
    fn editing_a_packet_document_updates_both_sources_and_keeps_untouched_xmp() {
        use crate::xmp::parse_packet;
        use crate::xmp_write::{preserved_fingerprint, read_metadata_packet};

        let scratch = ScratchDir::new("properties-xmp");
        let source = fixture("metadata-embedded.pdf");
        let destination = scratch.join("edited.pdf");
        let original = {
            let document = load_document(&source, None).unwrap();
            read_metadata_packet(&document)
                .unwrap()
                .expect("source packet")
        };
        let edited = DocumentProperties {
            title: "Edited & 100% Title".to_string(),
            author: "Ada Lovelace; Alan Turing; Grace Hopper".to_string(),
            subject: "A corrected subject".to_string(),
            keywords: "one, two".to_string(),
        };
        let report = save_document_properties(&source, &destination, &edited, None, SaveMode::Copy)
            .expect("save properties");
        assert!(report.xmp_updated, "the existing packet is rewritten");
        assert!(!report.xmp_created, "the packet already existed");

        let saved = load_document(&destination, None).unwrap();
        let packet = read_metadata_packet(&saved).unwrap().expect("saved packet");
        let text = String::from_utf8(packet.clone()).unwrap();
        assert!(text.contains(
            "<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">Edited &amp; 100% Title</rdf:li></rdf:Alt></dc:title>"
        ), "{text}");
        assert!(text.contains(
            "<dc:creator><rdf:Seq><rdf:li>Ada Lovelace</rdf:li><rdf:li>Alan Turing</rdf:li><rdf:li>Grace Hopper</rdf:li></rdf:Seq></dc:creator>"
        ), "{text}");
        assert!(text.contains(
            "<dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">A corrected subject</rdf:li></rdf:Alt></dc:description>"
        ), "{text}");
        assert!(
            text.contains("<pdf:Keywords>one, two</pdf:Keywords>"),
            "{text}"
        );
        assert!(
            !text.contains("Wrong Information Dictionary Title"),
            "{text}"
        );

        // The properties from other tools are still there, byte for byte.
        for kept in [
            "<prism:doi>10.1234/embedded.2024.001</prism:doi>",
            "<prism:publicationName>Journal of Embedded Testing</prism:publicationName>",
            "<prism:coverDate>2024-01-01</prism:coverDate>",
            "xmlns:prism=\"http://prismstandard.org/namespaces/basic/2.0/\"",
        ] {
            assert!(text.contains(kept), "lost {kept}\n{text}");
        }
        let after_fingerprints = preserved_fingerprint(&packet);
        for fingerprint in preserved_fingerprint(&original) {
            assert!(
                after_fingerprints.contains(&fingerprint),
                "unowned XMP property changed: {fingerprint}"
            );
        }
        let parsed = parse_packet(&text);
        assert_eq!(parsed.title.as_deref(), Some("Edited & 100% Title"));
        assert_eq!(
            parsed.authors,
            ["Ada Lovelace", "Alan Turing", "Grace Hopper"]
        );
        assert_eq!(parsed.doi.as_deref(), Some("10.1234/embedded.2024.001"));

        let info = read_document_info(&destination, None).unwrap();
        assert_eq!(info.properties, edited, "/Info reads the edited values");
    }

    #[test]
    fn a_document_without_a_packet_gains_one_through_the_catalog() {
        use crate::PdfiumBackend;
        use crate::xmp::parse_packet;
        use crate::xmp_write::read_metadata_packet;
        use lyra_reader_core::DocumentBackend;

        let scratch = ScratchDir::new("properties-no-xmp");
        let source = fixture("form-fields.pdf");
        let destination = scratch.join("with-metadata.pdf");
        let edited = DocumentProperties {
            title: "A New XMP Title".to_string(),
            author: "Ada Lovelace; Alan Turing".to_string(),
            subject: "A new subject".to_string(),
            keywords: "new, keywords".to_string(),
        };
        let report = save_document_properties(&source, &destination, &edited, None, SaveMode::Copy)
            .expect("save properties");
        assert!(report.xmp_created, "the document had no packet");
        assert!(report.xmp_updated);

        let saved = load_document(&destination, None).unwrap();
        let packet = read_metadata_packet(&saved)
            .unwrap()
            .expect("the catalog now has /Metadata");
        let text = String::from_utf8(packet).unwrap();
        assert!(text.starts_with("<?xpacket"), "{text}");
        assert!(text.contains("<x:xmpmeta"), "{text}");
        assert!(
            text.contains("xmlns:dc=\"http://purl.org/dc/elements/1.1/\""),
            "{text}"
        );
        assert!(
            text.contains("xmlns:pdf=\"http://ns.adobe.com/pdf/1.3/\""),
            "{text}"
        );
        let parsed = parse_packet(&text);
        assert_eq!(parsed.title.as_deref(), Some("A New XMP Title"));
        assert_eq!(parsed.authors, ["Ada Lovelace", "Alan Turing"]);

        // The backend the app uses reads the new packet, and the /Info values are the same.
        let backend = PdfiumBackend::open(&destination, None).expect("open saved copy");
        let embedded = backend.embedded_metadata().expect("embedded metadata");
        assert_eq!(
            embedded.xmp.title.as_deref(),
            Some("A New XMP Title"),
            "the XMP reader sees the created packet"
        );
        assert_eq!(
            embedded.xmp.authors,
            ["Ada Lovelace", "Alan Turing"],
            "the creator sequence is read back"
        );
        assert_eq!(embedded.info.title.as_deref(), Some("A New XMP Title"));
        assert_eq!(
            embedded.info.author.as_deref(),
            Some("Ada Lovelace; Alan Turing")
        );
        let info = read_document_info(&destination, None).unwrap();
        assert_eq!(info.properties, edited);
    }

    #[test]
    fn a_packet_whose_values_already_agree_is_preserved_verbatim() {
        use crate::xmp_write::read_metadata_packet;

        let scratch = ScratchDir::new("properties-verbatim");
        let source = fixture("metadata-embedded.pdf");
        let destination = scratch.join("same.pdf");
        let original = {
            let document = load_document(&source, None).unwrap();
            read_metadata_packet(&document)
                .unwrap()
                .expect("source packet")
        };
        // Exactly what the packet already says: title and creators match, no subject/keywords.
        let properties = DocumentProperties {
            title: "Embedded Metadata: A Study of {Braces} & Percent 100%".to_string(),
            author: "Ada Lovelace; Alan Turing".to_string(),
            subject: String::new(),
            keywords: String::new(),
        };
        let report =
            save_document_properties(&source, &destination, &properties, None, SaveMode::Copy)
                .expect("save properties");
        assert!(!report.xmp_updated, "the packet needed no update");
        let saved = load_document(&destination, None).unwrap();
        let packet = read_metadata_packet(&saved).unwrap().expect("packet");
        assert_eq!(packet, original, "the packet is byte-for-byte untouched");
        // /Info did change, because the source dictionary disagreed with its own XMP.
        let info = read_document_info(&destination, None).unwrap();
        assert_eq!(info.properties, properties);
    }

    #[test]
    fn clearing_the_properties_on_a_packet_document_clears_both_sources() {
        use crate::xmp::parse_xmp_bytes;
        use crate::xmp_write::read_metadata_packet;

        let scratch = ScratchDir::new("properties-cleared");
        let source = fixture("metadata-embedded.pdf");
        let destination = scratch.join("cleared.pdf");
        let cleared = DocumentProperties::default();
        let report =
            save_document_properties(&source, &destination, &cleared, None, SaveMode::Copy)
                .expect("clear properties");
        assert!(report.xmp_updated);

        let info = read_document_info(&destination, None).unwrap();
        assert_eq!(info.properties, cleared, "/Info has no values");
        // The catalog stream says the same, and the raw scan over the whole file must not
        // resurrect the earlier revision's title/authors.
        let saved = load_document(&destination, None).unwrap();
        let packet = read_metadata_packet(&saved).unwrap().expect("saved packet");
        let text = String::from_utf8(packet).unwrap();
        assert!(text.contains("<dc:title><rdf:Alt>"), "{text}");
        assert!(text.contains("<dc:creator><rdf:Seq></rdf:Seq>"), "{text}");
        assert!(
            text.contains("10.1234/embedded"),
            "unowned DOI was removed\n{text}"
        );
        let recognised = parse_xmp_bytes(&std::fs::read(&destination).unwrap());
        assert_eq!(recognised.title, None, "an older packet's title resurfaced");
        assert!(recognised.authors.is_empty(), "an older creator resurfaced");
        assert_eq!(recognised.doi.as_deref(), Some("10.1234/embedded.2024.001"));
    }

    #[test]
    fn a_malformed_packet_refuses_the_whole_save() {
        use crate::xmp_write::read_metadata_packet;

        let scratch = ScratchDir::new("properties-malformed");
        let source = scratch.join("malformed.pdf");
        let mut document = load_document(&fixture("metadata-embedded.pdf"), None).unwrap();
        let metadata_id = {
            let catalog = document.catalog().unwrap();
            catalog.get(b"Metadata").unwrap().as_reference().unwrap()
        };
        document
            .get_object_mut(metadata_id)
            .unwrap()
            .as_stream_mut()
            .unwrap()
            .set_plain_content(b"<rdf:RDF><dc:title>unclosed".to_vec());
        document.save(&source).unwrap();
        // The fixture really does carry the malformed packet.
        let loaded = load_document(&source, None).unwrap();
        assert_eq!(
            read_metadata_packet(&loaded).unwrap().unwrap(),
            b"<rdf:RDF><dc:title>unclosed"
        );

        let destination = scratch.join("out.pdf");
        let error = save_document_properties(
            &source,
            &destination,
            &DocumentProperties {
                title: "must not be written".to_string(),
                ..Default::default()
            },
            None,
            SaveMode::Copy,
        )
        .expect_err("a malformed packet refuses the save");
        assert_eq!(error.code, ErrorCode::CorruptDocument);
        assert!(error.message.contains("XMP"), "{}", error.message);
        assert!(
            error
                .detail
                .as_deref()
                .unwrap_or_default()
                .contains("never closed"),
            "{:?}",
            error.detail
        );
        assert!(!destination.exists(), "the refused save wrote nothing");
    }

    #[test]
    fn fixture_reports_facts_and_properties() {
        let path = fixture("form-fields.pdf");
        let info = read_document_info(&path, None).expect("read info");
        assert!(!info.facts.is_encrypted);
        assert_eq!(info.facts.page_count, 2);
        assert_eq!(info.facts.pdf_version, "1.7");
        assert!(info.has_info_dictionary);
        assert_eq!(info.properties.title, "LyraReader Form Fixture");
        assert_eq!(info.properties.author, "Fixture Author");
        assert_eq!(
            info.properties.subject,
            "AcroForm fields for the reader's form tool"
        );
        assert_eq!(info.properties.keywords, "forms, fixture, lyrareader");
    }

    #[test]
    fn saved_properties_read_back_and_keep_the_rest() {
        let scratch = ScratchDir::new("properties");
        let source = fixture("form-fields.pdf");
        let destination = scratch.join("properties.pdf");
        let before = read_document_info(&source, None).unwrap();
        let edited = DocumentProperties {
            title: "Edited & 100% Title".to_string(),
            author: "Ada Lovelace; Alan Turing".to_string(),
            subject: "A corrected subject".to_string(),
            keywords: "one, two".to_string(),
        };
        let report = save_document_properties(&source, &destination, &edited, None, SaveMode::Copy)
            .expect("save properties");
        assert!(report.source_bytes_preserved);
        assert!(report.appended_bytes > 0);
        let source_bytes = fs::read(&source).unwrap();
        let saved_bytes = fs::read(&destination).unwrap();
        assert_eq!(&saved_bytes[..source_bytes.len()], source_bytes.as_slice());
        let after = read_document_info(&destination, None).unwrap();
        assert_eq!(after.properties, edited);
        assert_eq!(after.facts.page_count, before.facts.page_count);
        // Creator/Producer survive the revision.
        assert_eq!(
            read_document_info(&destination, None)
                .unwrap()
                .facts
                .pdf_version,
            "1.7"
        );
        // The form fields are still there and still prefilled.
        let form = read_form_document(&destination, None).unwrap();
        assert_eq!(
            form.fields
                .iter()
                .find(|field| field.name == "email")
                .unwrap()
                .value
                .as_deref(),
            Some("prefilled@example.com")
        );
    }

    #[test]
    fn encrypted_file_properties_are_refused() {
        let scratch = ScratchDir::new("properties-encrypted");
        let source = fixture("form-fields-encrypted.pdf");
        let destination = scratch.join("out.pdf");
        let error = save_document_properties(
            &source,
            &destination,
            &DocumentProperties {
                title: "nope".to_string(),
                ..Default::default()
            },
            None,
            SaveMode::Copy,
        )
        .expect_err("encrypted properties save must be refused");
        assert_eq!(error.code, ErrorCode::Encrypted);
        assert!(!destination.exists());
    }
}
