//! Full pruned rewrites and the equivalence check that guards them.
//!
//! # Why a full rewrite
//!
//! An incremental update cannot free an object: deleting an annotation removes its reference
//! from a page's `/Annots`, but the annotation dictionary (its `/NM`, `/Contents`, geometry and
//! appearance) stays in the file as unreachable bytes. For an unsigned document that is a data
//! leak: the content the reader just "removed" is still extractable with a text editor. The
//! redaction writer already solved this by loading the document, replacing the page content and
//! calling [`lopdf::Document::prune_objects`]; this module applies the same shape to annotation
//! deletions and to the eraser.
//!
//! The rewrite is deliberately not used for an ordinary append or edit: an incremental save is
//! cheaper, keeps every original byte at its original offset, and is the correct default when
//! nothing is removed. A signed document never reaches this module at all — the FFI gate refuses
//! the write before the file is opened.
//!
//! # Equivalence, not hope
//!
//! Re-serialising a PDF is not a no-op. Loaders are lenient, writers normalise, and a document
//! can carry features this reader does not model. Before the temporary file is renamed, the
//! rewrite is therefore compared with the source on every contract the reader promises to
//! preserve:
//!
//! * page count;
//! * every page's text;
//! * form field count and values;
//! * outline entry count and titles (outside the reader's own bookmark subtree, which a save
//!   may legitimately change);
//! * XMP presence and the four `/Info` properties the reader owns;
//! * embedded files, when the source has any.
//!
//! A mismatch is a **refusal**, not a warning: the temporary file is dropped and the caller gets
//! the feature that could not be preserved. Silently dropping an attachment or an outline is
//! worse than leaving the document untouched.

use crate::document_properties::read_document_info;
use crate::forms::{decode_text_string, load_document, read_form_document};
use crate::outline_write::outline_equivalence;
use crate::xmp_write::read_metadata_packet;
use lopdf::{Dictionary, Document, Object, ObjectId, Stream};
use lyra_reader_core::{DocumentBackend, ErrorCode, LyraReaderError, PageIndex, Result};
use std::collections::BTreeMap;
use std::path::Path;

/// A deliberately broken rewrite, only constructible inside a test build.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RewriteFault {
    None,
    /// Simulates a rewrite that loses the embedded-file name tree, so the equivalence check can
    /// be shown to refuse and write nothing.
    DropEmbeddedFiles,
}

/// Whether page text is part of the equivalence contract.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum TextComparison {
    /// Every page's extracted text must be byte-for-byte the same (annotation deletion, eraser).
    Exact,
    /// The caller has its own, stricter text check (redaction proves text outside every mark is
    /// unchanged and text inside a mark is gone), so the shared check does not compare it.
    CallerVerified,
}

/// Loads `input`, deletes the object dictionaries the removal plan detached, prunes everything
/// no longer reachable, and returns the new file's bytes.
///
/// Deleting the objects themselves (rather than only pruning) also detaches a structure-tree
/// reference to a deleted annotation: a caller scanning the output for the annotation's `/NM`
/// will not find it through a tagged-PDF parent.
pub(crate) fn prune_rewrite(
    input: &Path,
    removed: &[(u32, u16)],
    fault: RewriteFault,
) -> Result<Vec<u8>> {
    let mut document = load_document(input, None)?;
    for &(number, generation) in removed {
        let id: ObjectId = (number, generation);
        if document.objects.contains_key(&id) {
            document.delete_object(id);
        }
    }
    if fault == RewriteFault::DropEmbeddedFiles {
        drop_embedded_file_tree(&mut document);
    }

    document.prune_objects();
    // Object numbers are deliberately *not* renumbered. The annotation verifier compares the
    // saved file with the source by object number, and a renumber can hand a removed object's
    // number to an annotation that survived, which would look like a deleted annotation still
    // being present. Sparse object numbers are legal PDF; the bytes of the removed objects are
    // gone either way.
    let mut buffer = Vec::new();
    document.save_to(&mut buffer).map_err(|error| {
        LyraReaderError::new(ErrorCode::Io, "the pruned document could not be written")
            .with_detail(error.to_string())
    })?;
    Ok(buffer)
}

/// Removes the embedded-file name tree, for [`RewriteFault::DropEmbeddedFiles`].
fn drop_embedded_file_tree(document: &mut Document) {
    let Some(root_id) = document
        .trailer
        .get(b"Root")
        .ok()
        .and_then(|object| object.as_reference().ok())
    else {
        return;
    };
    if let Ok(dictionary) = document
        .get_object_mut(root_id)
        .and_then(Object::as_dict_mut)
    {
        dictionary.remove(b"Names");
    }
}

/// Reopens both files and proves the rewrite preserved everything it promised to preserve.
///
/// Returns a refusal that names the feature that could not be preserved; never a silent pass.
pub(crate) fn verify_document_equivalence(
    source: &Path,
    rewritten: &Path,
    password: Option<&str>,
    text: TextComparison,
) -> Result<()> {
    compare_page_text(source, rewritten, password, text)?;
    compare_form_fields(source, rewritten, password)?;
    compare_outline(source, rewritten, password)?;
    compare_metadata_and_info(source, rewritten, password)?;
    compare_embedded_files(source, rewritten, password)?;
    Ok(())
}

fn refusal(feature: &str, detail: String) -> LyraReaderError {
    LyraReaderError::new(
        ErrorCode::Internal,
        format!(
            "the full rewrite would not preserve the document's {feature}; nothing was written"
        ),
    )
    .with_detail(detail)
}

fn compare_page_text(
    source: &Path,
    rewritten: &Path,
    password: Option<&str>,
    text: TextComparison,
) -> Result<()> {
    if text == TextComparison::CallerVerified {
        // Still compare the page count: it is the frame every other page fact hangs from.
        let source = crate::PdfiumBackend::open(source, password)?;
        let rewritten = crate::PdfiumBackend::open(rewritten, password)?;
        if source.page_count() != rewritten.page_count() {
            return Err(refusal(
                "page count",
                format!(
                    "source has {}, rewritten file has {}",
                    source.page_count(),
                    rewritten.page_count()
                ),
            ));
        }
        return Ok(());
    }

    let source_backend = crate::PdfiumBackend::open(source, password)?;
    let rewritten_backend = crate::PdfiumBackend::open(rewritten, password)?;
    let source_pages = source_backend.page_count();
    if source_pages != rewritten_backend.page_count() {
        return Err(refusal(
            "page count",
            format!(
                "source has {source_pages}, rewritten file has {}",
                rewritten_backend.page_count()
            ),
        ));
    }
    for page in 0..source_pages {
        let before = source_backend.raw_text_page(PageIndex(page))?.text;
        let after = rewritten_backend.raw_text_page(PageIndex(page))?.text;
        if before != after {
            let at = before
                .char_indices()
                .zip(after.char_indices())
                .position(|((_, a), (_, b))| a != b)
                .unwrap_or_else(|| before.chars().count().min(after.chars().count()));
            return Err(refusal(
                "page text",
                format!(
                    "page {} differs at character {at}: source has {} character(s), rewritten file has {}",
                    page + 1,
                    before.chars().count(),
                    after.chars().count()
                ),
            ));
        }
    }
    Ok(())
}

fn compare_form_fields(source: &Path, rewritten: &Path, password: Option<&str>) -> Result<()> {
    let before = read_form_document(source, password)?;
    let after = read_form_document(rewritten, password)?;
    if before.fields.len() != after.fields.len() {
        return Err(refusal(
            "form fields",
            format!(
                "source has {} field(s), rewritten file has {}",
                before.fields.len(),
                after.fields.len()
            ),
        ));
    }
    let signature = |field: &crate::forms::FormField| {
        (
            field.name.clone(),
            field.kind,
            field.value.clone(),
            field.checked,
            field.selected.clone(),
        )
    };
    let mut before_fields: Vec<_> = before.fields.iter().map(signature).collect();
    let mut after_fields: Vec<_> = after.fields.iter().map(signature).collect();
    before_fields.sort_by(|a, b| a.0.cmp(&b.0));
    after_fields.sort_by(|a, b| a.0.cmp(&b.0));
    if before_fields != after_fields {
        let first = before_fields
            .iter()
            .zip(after_fields.iter())
            .find(|(a, b)| a != b)
            .map(|(a, _)| a.0.clone())
            .unwrap_or_else(|| "?".to_string());
        return Err(refusal(
            "form field values",
            format!("the first field that changed is {first:?}"),
        ));
    }
    Ok(())
}

fn compare_outline(source: &Path, rewritten: &Path, password: Option<&str>) -> Result<()> {
    let before = outline_equivalence(source, password)?;
    let after = outline_equivalence(rewritten, password)?;
    if before != after {
        let first = before
            .iter()
            .zip(after.iter())
            .position(|(a, b)| a != b)
            .unwrap_or_else(|| before.len().min(after.len()));
        return Err(refusal(
            "outline",
            format!(
                "source has {} entr(ies), rewritten file has {}; first difference at entry {}: \
                 source {:?}, rewritten {:?}",
                before.len(),
                after.len(),
                first + 1,
                before.get(first),
                after.get(first)
            ),
        ));
    }
    Ok(())
}

fn compare_metadata_and_info(
    source: &Path,
    rewritten: &Path,
    password: Option<&str>,
) -> Result<()> {
    let before = read_document_info(source, password)?;
    let after = read_document_info(rewritten, password)?;
    if before.has_info_dictionary != after.has_info_dictionary
        || before.properties != after.properties
    {
        return Err(refusal(
            "document information (/Info)",
            format!(
                "source has an information dictionary: {}; rewritten file: {}",
                before.has_info_dictionary, after.has_info_dictionary
            ),
        ));
    }
    let before_document = load_document(source, password)?;
    let after_document = load_document(rewritten, password)?;
    let before_packet = read_metadata_packet(&before_document)?;
    let after_packet = read_metadata_packet(&after_document)?;
    match (before_packet.as_deref(), after_packet.as_deref()) {
        (None, None) => {}
        (Some(_), None) => {
            return Err(refusal(
                "XMP metadata",
                "the source carries an XMP packet and the rewritten file does not".to_string(),
            ));
        }
        (None, Some(_)) => {
            return Err(refusal(
                "XMP metadata",
                "the rewritten file gained an XMP packet the source did not have".to_string(),
            ));
        }
        (Some(before), Some(after)) if before != after => {
            return Err(refusal(
                "XMP metadata",
                format!(
                    "the XMP packet changed ({} byte(s) before, {} after)",
                    before.len(),
                    after.len()
                ),
            ));
        }
        _ => {}
    }
    // Every `/Info` entry other than the four the properties editor owns also has to survive:
    // a full rewrite that dropped `/Producer` or `/CreationDate` loses metadata the reader
    // shows nowhere but the file's other viewers do.
    compare_other_info_entries(&before_document, &after_document)?;
    Ok(())
}

fn compare_other_info_entries(before: &Document, after: &Document) -> Result<()> {
    fn info(document: &Document) -> BTreeMap<Vec<u8>, Vec<u8>> {
        let Some(dictionary) = document
            .trailer
            .get(b"Info")
            .ok()
            .and_then(|object| crate::forms::resolve(document, object))
            .and_then(|object| object.as_dict().ok())
        else {
            return BTreeMap::new();
        };
        dictionary
            .iter()
            .filter(|(key, _)| {
                !matches!(
                    key.as_slice(),
                    b"Title" | b"Author" | b"Subject" | b"Keywords"
                )
            })
            .map(|(key, value)| (key.clone(), format!("{value:?}").into_bytes()))
            .collect()
    }
    let before = info(before);
    let after = info(after);
    if before != after {
        return Err(refusal(
            "document information (/Info)",
            "an /Info entry outside Title, Author, Subject and Keywords changed".to_string(),
        ));
    }
    Ok(())
}

fn compare_embedded_files(source: &Path, rewritten: &Path, password: Option<&str>) -> Result<()> {
    let before_document = load_document(source, password)?;
    let after_document = load_document(rewritten, password)?;
    let before = embedded_files(&before_document);
    let after = embedded_files(&after_document);
    if before == after {
        return Ok(());
    }
    let before_names: Vec<&str> = before.iter().map(|(name, _)| name.as_str()).collect();
    let after_names: Vec<&str> = after.iter().map(|(name, _)| name.as_str()).collect();
    let missing: Vec<&str> = before_names
        .iter()
        .copied()
        .filter(|name| !after_names.contains(name))
        .collect();
    Err(refusal(
        "embedded files",
        format!(
            "source has {} embedded file(s) {:?}, rewritten file has {} {:?}{}",
            before.len(),
            before_names,
            after.len(),
            after_names,
            if missing.is_empty() {
                String::new()
            } else {
                format!("; missing: {missing:?}")
            }
        ),
    ))
}

/// Every embedded file as `(name, encoded stream bytes)`.
///
/// `EmbeddedFile` streams are compared by their encoded content: the rewrite does not decode or
/// re-encode stream data, so a byte change would be a lost attachment either way.
fn embedded_files(document: &Document) -> Vec<(String, Vec<u8>)> {
    let mut files = BTreeMap::new();
    let Some(catalog) = document
        .trailer
        .get(b"Root")
        .ok()
        .and_then(|object| crate::forms::resolve(document, object))
        .and_then(|object| object.as_dict().ok())
    else {
        return Vec::new();
    };
    let Some(names) = catalog
        .get(b"Names")
        .ok()
        .and_then(|object| crate::forms::resolve(document, object))
        .and_then(|object| object.as_dict().ok())
    else {
        return Vec::new();
    };
    let Some(embedded) = names
        .get(b"EmbeddedFiles")
        .ok()
        .and_then(|object| crate::forms::resolve(document, object))
        .and_then(|object| object.as_dict().ok())
    else {
        return Vec::new();
    };
    collect_name_tree(document, embedded, &mut files, 0);
    files.into_iter().collect()
}

fn collect_name_tree(
    document: &Document,
    node: &Dictionary,
    files: &mut BTreeMap<String, Vec<u8>>,
    depth: usize,
) {
    if depth > 64 {
        return;
    }
    if let Ok(entries) = node.get(b"Names").and_then(Object::as_array) {
        for pair in entries.chunks(2) {
            let [name, filespec] = pair else {
                continue;
            };
            let name = crate::forms::resolve(document, name)
                .and_then(|object| object.as_str().ok())
                .map(decode_text_string)
                .unwrap_or_default();
            let Some(dictionary) =
                crate::forms::resolve(document, filespec).and_then(|object| object.as_dict().ok())
            else {
                continue;
            };
            let Some(stream) = dictionary
                .get(b"EF")
                .ok()
                .and_then(|object| crate::forms::resolve(document, object))
                .and_then(|object| object.as_dict().ok())
                .and_then(|embedded| embedded.get(b"F").ok())
                .and_then(|object| crate::forms::resolve(document, object))
                .and_then(|object| object.as_stream().ok())
            else {
                continue;
            };
            files.insert(name, stream_bytes(stream));
        }
    }
    if let Ok(kids) = node.get(b"Kids").and_then(Object::as_array) {
        for kid in kids {
            if let Some(dictionary) =
                crate::forms::resolve(document, kid).and_then(|object| object.as_dict().ok())
            {
                collect_name_tree(document, dictionary, files, depth + 1);
            }
        }
    }
}

fn stream_bytes(stream: &Stream) -> Vec<u8> {
    stream.content.clone()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{ScratchDir, fixture};
    use std::fs;

    /// A debug-only fault that drops `/Names` must be caught by the embedded-file comparison.
    #[test]
    fn a_lost_embedded_file_is_refused() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let scratch = ScratchDir::new("rewrite-equivalence");
        let source = fixture("embedded-file.pdf");
        let broken = scratch.join("broken.pdf");

        let mut document = load_document(&source, None).expect("load the fixture");
        let root = document
            .trailer
            .get(b"Root")
            .expect("root")
            .as_reference()
            .expect("indirect root");
        document
            .get_object_mut(root)
            .expect("catalog")
            .as_dict_mut()
            .expect("dictionary")
            .remove(b"Names");
        document.save(&broken).expect("write the broken file");

        let error = verify_document_equivalence(&source, &broken, None, TextComparison::Exact)
            .expect_err("a lost attachment must be refused");
        assert!(error.message.contains("embedded file"), "{error}");
        assert!(error.detail.unwrap_or_default().contains("notes.txt"));
    }

    #[test]
    fn an_unchanged_rewrite_passes() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let scratch = ScratchDir::new("rewrite-equivalence-ok");
        for name in [
            "embedded-file.pdf",
            "outlined.pdf",
            "form-fields.pdf",
            "metadata-embedded.pdf",
            "annotated-replies.pdf",
        ] {
            let source = fixture(name);
            let rewritten = scratch.join(name);
            let bytes = fs::read(&source).expect("read fixture");
            let mut document = Document::load_mem(&bytes).expect("parse fixture");
            document.prune_objects();
            document.renumber_objects();
            let mut output = Vec::new();
            document.save_to(&mut output).expect("save fixture");
            fs::write(&rewritten, output).expect("write fixture");
            verify_document_equivalence(&source, &rewritten, None, TextComparison::Exact)
                .unwrap_or_else(|error| panic!("{name}: {error}"));
        }
    }

    fn contains(haystack: &[u8], needle: &[u8]) -> bool {
        haystack
            .windows(needle.len())
            .any(|window| window == needle)
    }

    /// The evidence the feature exists for: the removed annotation's identity and content must
    /// not survive anywhere in the saved bytes, while the annotations that were not removed do.
    #[test]
    fn deleting_an_annotation_removes_its_bytes() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        use crate::annotation_edit::{AnnotationChanges, AnnotationDelete};
        use crate::writeback::{SaveMode, save_annotation_changes};

        let scratch = ScratchDir::new("prune-deletion");
        let source = fixture("annotated-strokes.pdf");
        let destination = scratch.join("deleted.pdf");
        let changes = AnnotationChanges {
            deletions: vec![AnnotationDelete {
                target: "nm:external-ink".to_string(),
            }],
            ..AnnotationChanges::default()
        };
        let report =
            save_annotation_changes(&source, &destination, &changes, &[], None, SaveMode::Copy)
                .expect("the deletion saves");

        assert!(report.full_rewrite, "a deletion must prune the file");
        assert!(
            !report.source_bytes_preserved,
            "a full rewrite does not keep the source prefix"
        );
        let saved = fs::read(&destination).expect("read the saved file");
        assert!(
            !contains(&saved, b"external-ink"),
            "the removed annotation's /NM is still in the bytes"
        );
        assert!(
            !contains(&saved, b"Ink written by another producer."),
            "the removed annotation's /Contents is still in the bytes"
        );
        assert!(
            contains(&saved, b"external-square"),
            "an annotation that was not removed must survive"
        );
        assert!(
            contains(&saved, b"/Square"),
            "the surviving annotations keep their subtype"
        );

        // The normal save path still uses the source as its prefix: pruning is opt-in by
        // deletion, not the new default.
        let append_destination = scratch.join("appended.pdf");
        let additions = AnnotationChanges {
            additions: vec![crate::annotations::WriteAnnotation {
                id: "new-highlight".to_string(),
                page: lyra_reader_core::PageIndex(0),
                kind: crate::annotations::WriteAnnotationKind::Highlight,
                rect: lyra_reader_core::Rect::new(80.0, 620.0, 180.0, 90.0),
                quads: vec![lyra_reader_core::Rect::new(80.0, 620.0, 180.0, 90.0)],
                ink_paths: Vec::new(),
                line: None,
                line_arrow: false,
                border_width: 0.0,
                font_size: 0.0,
                alignment: lyra_reader_core::AnnotationAlignment::Left,
                color: [255, 230, 0],
                opacity: 1.0,
                contents: None,
                author: None,
                modified: None,
            }],
            ..AnnotationChanges::default()
        };
        let report = save_annotation_changes(
            &source,
            &append_destination,
            &additions,
            &[],
            None,
            SaveMode::Copy,
        )
        .expect("the append saves");
        assert!(!report.full_rewrite, "an append stays incremental");
        assert!(report.source_bytes_preserved, "an append keeps the prefix");
        let source_bytes = fs::read(&source).expect("read source");
        let appended = fs::read(&append_destination).expect("read append");
        assert!(appended.starts_with(&source_bytes));
    }

    /// The fault is injected into the rewrite only; the save must still leave nothing behind.
    #[test]
    fn an_equivalence_failure_is_refused_and_writes_nothing() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        use crate::annotation_edit::{AnnotationChanges, AnnotationDelete};
        use crate::writeback::{SaveMode, save_annotation_changes_with_fault};

        let scratch = ScratchDir::new("rewrite-refusal");
        let source = fixture("embedded-file-annotated.pdf");
        let destination = scratch.join("must-not-exist.pdf");
        let changes = AnnotationChanges {
            deletions: vec![AnnotationDelete {
                target: "nm:doomed-highlight".to_string(),
            }],
            ..AnnotationChanges::default()
        };
        let error = save_annotation_changes_with_fault(
            &source,
            &destination,
            &changes,
            &[],
            None,
            SaveMode::Copy,
        )
        .expect_err("losing the attachment must be refused");
        assert!(
            error.message.contains("embedded files"),
            "the refusal must name the feature: {error}"
        );
        assert!(
            error
                .detail
                .as_deref()
                .unwrap_or_default()
                .contains("notes.txt"),
            "the refusal must name the file: {error}"
        );
        assert!(
            !destination.exists(),
            "a refused save must leave no output file"
        );
        let leftovers: Vec<_> = fs::read_dir(&scratch)
            .expect("scratch")
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .collect();
        assert!(
            leftovers.is_empty(),
            "temporary files left behind: {leftovers:?}"
        );
        // The source is untouched by the failed save.
        let original = fs::read(&source).expect("read source");
        assert_eq!(
            original,
            fs::read(fixture("embedded-file-annotated.pdf")).expect("reread")
        );
    }
}
