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
    Ok(())
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
        |temp| verify_saved_properties(&before, temp, properties, password),
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
    })
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
