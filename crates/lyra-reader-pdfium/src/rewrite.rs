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
//! nothing is removed. A signed document is never rewritten in place; a **modified derived
//! copy** of one is passed to [`strip_signature_from_copy`], which also uses the pruned-rewrite
//! machinery to remove signature material before the copy is renamed.
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

/// What a signature strip removed from a modified derived copy.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SignatureStripReport {
    /// Signature fields (and their `/V` dictionaries) removed from the copy.
    pub signature_fields: usize,
    /// Objects detached from the document (the fields, their widgets and signature dictionaries).
    pub removed_objects: usize,
}

#[derive(Default)]
struct SignatureMaterial {
    objects: std::collections::BTreeSet<ObjectId>,
    remove_perms: bool,
    remove_dss: bool,
    remove_sig_flags: bool,
    signature_fields: usize,
}

impl SignatureMaterial {
    fn is_empty(&self) -> bool {
        self.objects.is_empty() && !self.remove_perms && !self.remove_dss && !self.remove_sig_flags
    }
}

/// Removes every trace of a digital signature from a **modified copy**, atomically.
///
/// A derived file whose bytes no longer match a signature field's `/V` must not look signed:
/// a reader that trusts the field would report a valid signature over different content. The
/// strip removes the signature fields (with their widgets and signature dictionaries), clears
/// `/AcroForm /SigFlags`, and drops the catalog's `/Perms` and `/DSS`. Non-signature form fields,
/// pages, text, outline, metadata and embedded files are verified unchanged before the copy is
/// replaced; a verification failure deletes the copy and refuses instead of keeping a misleading
/// file.
///
/// Returns `Ok(None)` for a copy that carries no signature material (an ordinary unsigned
/// export) and does not touch it.
pub fn strip_signature_from_copy(path: &Path) -> Result<Option<SignatureStripReport>> {
    let bytes = std::fs::read(path).map_err(|error| {
        LyraReaderError::new(ErrorCode::Io, "could not read the derived copy")
            .with_detail(format!("{}: {error}", path.display()))
    })?;
    let mut document = Document::load_mem(&bytes).map_err(|error| {
        LyraReaderError::new(
            ErrorCode::CorruptDocument,
            "the derived copy could not be parsed",
        )
        .with_detail(error.to_string())
    })?;
    let material = signature_material(&document);
    if material.is_empty() {
        return Ok(None);
    }
    remove_signature_material(&mut document, &material);
    document.prune_objects();
    let mut sanitized = Vec::new();
    document.save_to(&mut sanitized).map_err(|error| {
        LyraReaderError::new(
            ErrorCode::Io,
            "the signature-free copy could not be written",
        )
        .with_detail(error.to_string())
    })?;

    let staging = signature_staging_path(path)?;
    let result = (|| -> Result<()> {
        {
            use std::io::Write;
            let mut file = std::fs::File::create(&staging).map_err(|error| {
                LyraReaderError::new(ErrorCode::Io, "could not create the signature-strip source")
                    .with_detail(format!("{}: {error}", staging.display()))
            })?;
            file.write_all(&sanitized).map_err(|error| {
                LyraReaderError::new(ErrorCode::Io, "could not write the signature-strip source")
                    .with_detail(format!("{}: {error}", staging.display()))
            })?;
            file.sync_all().map_err(|error| {
                LyraReaderError::new(ErrorCode::Io, "could not fsync the signature-strip source")
                    .with_detail(format!("{}: {error}", staging.display()))
            })?;
        }
        let verify = |candidate: &Path| verify_signature_strip(path, candidate, &material);
        let build = |file: &mut std::fs::File| -> Result<()> {
            use std::io::Write;
            file.write_all(&sanitized).map_err(|error| {
                LyraReaderError::new(ErrorCode::Io, "could not write the signature-free copy")
                    .with_detail(error.to_string())
            })
        };
        crate::writeback::write_rewritten_pdf(
            &staging,
            path,
            crate::writeback::OutputMode::Copy,
            build,
            verify,
        )?;
        Ok(())
    })();
    let _ = std::fs::remove_file(&staging);
    if let Err(error) = result {
        // The copy on disk is the writer's signed-looking file. Keeping it would be the one
        // outcome the policy forbids, so remove it rather than return an error next to it.
        let _ = std::fs::remove_file(path);
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the derived copy could not be made signature-free; nothing was kept",
        )
        .with_detail(error.to_string()));
    }
    Ok(Some(SignatureStripReport {
        signature_fields: material.signature_fields,
        removed_objects: material.objects.len(),
    }))
}

fn signature_staging_path(destination: &Path) -> Result<std::path::PathBuf> {
    let parent = destination
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let name = destination.file_name().ok_or_else(|| {
        LyraReaderError::new(ErrorCode::InvalidArgument, "the copy has no file name")
    })?;
    for attempt in 0..100 {
        let candidate = parent.join(format!(
            ".{}.lyra-reader-signature-strip-{}-{attempt}.tmp",
            name.to_string_lossy(),
            std::process::id()
        ));
        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&candidate)
        {
            Ok(_) => return Ok(candidate),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(LyraReaderError::new(
                    ErrorCode::Io,
                    "could not create a signature-strip staging file",
                )
                .with_detail(format!("{}: {error}", candidate.display())));
            }
        }
    }
    Err(LyraReaderError::new(
        ErrorCode::Io,
        "could not choose a unique signature-strip staging file",
    ))
}

fn signature_material(document: &Document) -> SignatureMaterial {
    let mut material = SignatureMaterial::default();
    let mut evidence = false;
    let Some(catalog_id) = document
        .trailer
        .get(b"Root")
        .ok()
        .and_then(|object| object.as_reference().ok())
    else {
        return material;
    };
    let Some(catalog) = document.get_dictionary(catalog_id).ok() else {
        return material;
    };
    material.remove_perms = catalog.get(b"Perms").is_ok();
    material.remove_dss = catalog.get(b"DSS").is_ok();
    if material.remove_perms || material.remove_dss {
        evidence = true;
    }
    if let Some(form) = catalog
        .get(b"AcroForm")
        .ok()
        .and_then(|object| crate::forms::resolve(document, object))
        .and_then(|object| object.as_dict().ok())
    {
        material.remove_sig_flags = form.get(b"SigFlags").is_ok();
        if material.remove_sig_flags
            && form
                .get(b"SigFlags")
                .ok()
                .and_then(|object| crate::forms::resolve(document, object))
                .and_then(|object| object.as_i64().ok())
                .is_some_and(|flags| flags & 1 != 0)
        {
            evidence = true;
        }
        if let Ok(fields) = form.get(b"Fields").and_then(Object::as_array) {
            evidence |= collect_signature_fields(document, fields, None, &mut material);
        }
    }
    // A signature dictionary copied without its `/AcroForm` parent is still signature material:
    // a viewer may find it through a page annotation or a structure tree.
    for (&id, object) in &document.objects {
        let Some(dictionary) = object.as_dict().ok() else {
            continue;
        };
        let is_signature = dictionary
            .get(b"FT")
            .ok()
            .and_then(|object| crate::forms::resolve(document, object))
            .and_then(|object| object.as_name().ok())
            == Some(b"Sig");
        if is_signature {
            evidence |= signature_value(document, dictionary);
            if material.objects.insert(id) {
                material.signature_fields += 1;
            }
        }
    }
    // An unsigned signature field (no `/V`, no SigFlags/Perms/DSS) does not make a document
    // look signed; do not rewrite an ordinary form copy just because it has one.
    if !evidence {
        return SignatureMaterial::default();
    }
    material
}

fn signature_value(document: &Document, dictionary: &Dictionary) -> bool {
    dictionary
        .get(b"V")
        .ok()
        .and_then(|object| crate::forms::resolve(document, object))
        .is_some_and(|value| match value {
            Object::Null => false,
            Object::String(bytes, _) => !bytes.is_empty(),
            Object::Array(array) => !array.is_empty(),
            Object::Dictionary(dictionary) => !dictionary.is_empty(),
            Object::Stream(stream) => !stream.content.is_empty(),
            _ => true,
        })
}

const MAX_SIGNATURE_FIELD_DEPTH: usize = 64;

fn collect_signature_fields(
    document: &Document,
    fields: &[Object],
    inherited_type: Option<&[u8]>,
    material: &mut SignatureMaterial,
) -> bool {
    let mut evidence = false;
    for field in fields {
        let Some(dictionary) =
            crate::forms::resolve(document, field).and_then(|object| object.as_dict().ok())
        else {
            continue;
        };
        let field_type = dictionary
            .get(b"FT")
            .ok()
            .and_then(|object| crate::forms::resolve(document, object))
            .and_then(|object| object.as_name().ok())
            .or(inherited_type);
        if field_type == Some(b"Sig") {
            material.signature_fields += 1;
            evidence |= signature_value(document, dictionary);
            if let Ok(id) = field.as_reference() {
                material.objects.insert(id);
            }
            collect_signature_descendants(document, dictionary, material, 0);
        } else if let Ok(kids) = dictionary.get(b"Kids").and_then(Object::as_array) {
            evidence |= collect_signature_fields(document, kids, field_type, material);
        }
    }
    evidence
}

fn collect_signature_descendants(
    document: &Document,
    dictionary: &Dictionary,
    material: &mut SignatureMaterial,
    depth: usize,
) {
    if depth > MAX_SIGNATURE_FIELD_DEPTH {
        return;
    }
    if let Ok(kids) = dictionary.get(b"Kids").and_then(Object::as_array) {
        for kid in kids {
            if let Ok(id) = kid.as_reference() {
                material.objects.insert(id);
            }
            if let Some(dictionary) =
                crate::forms::resolve(document, kid).and_then(|object| object.as_dict().ok())
            {
                collect_signature_descendants(document, dictionary, material, depth + 1);
            }
        }
    }
}

fn remove_signature_material(document: &mut Document, material: &SignatureMaterial) {
    for id in &material.objects {
        if document.objects.contains_key(id) {
            document.delete_object(*id);
        }
    }
    let Some(catalog_id) = document
        .trailer
        .get(b"Root")
        .ok()
        .and_then(|object| object.as_reference().ok())
    else {
        return;
    };
    let acro_form_id = document
        .get_dictionary(catalog_id)
        .ok()
        .and_then(|catalog| catalog.get(b"AcroForm").ok())
        .and_then(|object| object.as_reference().ok());
    let form_is_empty = {
        let form = match acro_form_id {
            Some(id) => document.get_dictionary(id).ok(),
            None => document
                .get_dictionary(catalog_id)
                .ok()
                .and_then(|catalog| catalog.get(b"AcroForm").ok())
                .and_then(|object| object.as_dict().ok()),
        };
        form.is_none_or(|form| {
            form.get(b"Fields")
                .and_then(Object::as_array)
                .map(|fields| fields.is_empty())
                .unwrap_or(true)
        })
    };
    if let Some(id) = acro_form_id
        && let Ok(form) = document.get_object_mut(id).and_then(Object::as_dict_mut)
    {
        form.remove(b"SigFlags");
    }
    let Ok(catalog) = document
        .get_object_mut(catalog_id)
        .and_then(Object::as_dict_mut)
    else {
        return;
    };
    if let Ok(form) = catalog
        .get_mut(b"AcroForm")
        .and_then(|object| object.as_dict_mut())
    {
        form.remove(b"SigFlags");
    }
    if material.remove_perms {
        catalog.remove(b"Perms");
    }
    if material.remove_dss {
        catalog.remove(b"DSS");
    }
    if form_is_empty {
        catalog.remove(b"AcroForm");
    }
}

fn verify_signature_strip(
    before: &Path,
    after: &Path,
    _material: &SignatureMaterial,
) -> Result<()> {
    compare_page_text(before, after, None, TextComparison::Exact)?;
    compare_outline(before, after, None)?;
    compare_metadata_and_info(before, after, None)?;
    compare_embedded_files(before, after, None)?;

    let before_form = read_form_document(before, None)?;
    let after_form = read_form_document(after, None)?;
    let signature = |field: &crate::forms::FormField| {
        (
            field.name.clone(),
            field.kind,
            field.value.clone(),
            field.checked,
            field.selected.clone(),
        )
    };
    let mut before_kept: Vec<_> = before_form
        .fields
        .iter()
        .filter(|field| field.kind != crate::forms::FormFieldKind::Signature)
        .map(signature)
        .collect();
    let mut after_fields: Vec<_> = after_form.fields.iter().map(signature).collect();
    before_kept.sort_by(|a, b| a.0.cmp(&b.0));
    after_fields.sort_by(|a, b| a.0.cmp(&b.0));
    if after_form
        .fields
        .iter()
        .any(|field| field.kind == crate::forms::FormFieldKind::Signature)
    {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the signature-free copy still contains a signature field",
        ));
    }
    if before_kept != after_fields {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the signature-free copy changed a non-signature form field",
        ));
    }

    if crate::detect_signature(after, None, 0).is_signed() {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the signature-free copy still reports signature evidence",
        ));
    }
    if crate::PdfiumBackend::open(after, None)?.signature_count() != 0 {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "PDFium still sees a signature in the signature-free copy",
        ));
    }
    Ok(())
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
    fn signature_field_count(path: &Path) -> usize {
        crate::forms::read_form_document(path, None)
            .expect("read form")
            .fields
            .iter()
            .filter(|field| field.kind == crate::forms::FormFieldKind::Signature)
            .count()
    }

    /// A modified copy must not keep a signature field whose `/V` no longer covers its bytes.
    #[test]
    fn a_modified_copy_loses_its_signature_material() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let scratch = ScratchDir::new("signature-strip");
        for (name, expected_fields) in [("signed-signature.pdf", 1), ("signed-docmdp.pdf", 0)] {
            let copy = scratch.join(format!("copy-{name}"));
            fs::copy(fixture(name), &copy).expect("copy the fixture");
            let before = crate::detect_signature(&copy, None, 0);
            assert!(before.is_signed(), "{name} must start signed");
            let before_pages = crate::PdfiumBackend::open(&copy, None)
                .expect("open before")
                .page_count();
            let before_form = crate::forms::read_form_document(&copy, None).expect("form");
            let before_text = (0..before_pages)
                .map(|page| {
                    use lyra_reader_core::DocumentBackend;
                    crate::PdfiumBackend::open(&copy, None)
                        .expect("open before")
                        .raw_text_page(PageIndex(page))
                        .expect("text")
                        .text
                })
                .collect::<Vec<_>>();

            let report = strip_signature_from_copy(&copy)
                .expect("strip the signature")
                .expect("signature material was found");
            assert_eq!(report.signature_fields, expected_fields, "{name}");
            assert!(
                !crate::detect_signature(&copy, None, 0).is_signed(),
                "{name}"
            );
            assert_eq!(
                crate::PdfiumBackend::open(&copy, None)
                    .expect("open after")
                    .signature_count(),
                0,
                "{name}: PDFium still sees a signature"
            );
            // The bytes may legitimately contain the words "/Perms" or "SigFlags" in page
            // content (the DocMDP fixture's text says so), so assert on the document's
            // dictionaries instead of a raw substring scan.
            let stripped_document = Document::load(&copy).expect("parse the stripped copy");
            assert!(
                signature_material(&stripped_document).is_empty(),
                "{name}: signature material is still reachable"
            );
            let after_form = crate::forms::read_form_document(&copy, None).expect("form");
            assert_eq!(
                signature_field_count(&copy),
                0,
                "{name}: a signature field survived"
            );
            assert_eq!(
                before_form.fields.len() - expected_fields,
                after_form.fields.len(),
                "{name}: a non-signature field was lost"
            );
            let after_pages = crate::PdfiumBackend::open(&copy, None)
                .expect("open after")
                .page_count();
            assert_eq!(before_pages, after_pages, "{name}: page count changed");
            let after_text = (0..after_pages)
                .map(|page| {
                    use lyra_reader_core::DocumentBackend;
                    crate::PdfiumBackend::open(&copy, None)
                        .expect("open after")
                        .raw_text_page(PageIndex(page))
                        .expect("text")
                        .text
                })
                .collect::<Vec<_>>();
            assert_eq!(before_text, after_text, "{name}: page text changed");
        }
    }

    /// An ordinary unsigned copy is not rewritten at all; a byte-identical export of a signed
    /// file keeps its valid signature and is therefore not touched either.
    #[test]
    fn a_copy_without_signature_material_is_untouched() {
        let scratch = ScratchDir::new("signature-strip-none");
        // `annotated.pdf` has no form at all; `form-fields.pdf` has an unsigned signature field
        // (no `/V`, no `/SigFlags`), which must not trigger a rewrite either.
        for name in ["annotated.pdf", "form-fields.pdf"] {
            let copy = scratch.join(name);
            fs::copy(fixture(name), &copy).expect("copy the fixture");
            let before = fs::read(&copy).expect("read");
            assert!(
                strip_signature_from_copy(&copy)
                    .expect("strip attempts")
                    .is_none(),
                "{name}: an unsigned copy has nothing to strip"
            );
            assert_eq!(fs::read(&copy).expect("reread"), before, "{name}");
        }
    }

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
