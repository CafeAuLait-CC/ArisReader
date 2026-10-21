//! Editing and removing annotations a PDF **already carries**, through an incremental update.
//!
//! The append-only writer in [`crate::geometry_write`] can add objects; this module is the other
//! half: it rewrites the annotation dictionary the file already has, and removes annotations from
//! the page's `/Annots`. Both use lopdf's [`IncrementalDocument`], so every original byte stays
//! the output's prefix (the save contract in [`crate::writeback`] verifies that) and a file
//! somebody may have signed keeps its signature valid.
//!
//! # Why the annotation object is copied, not rebuilt
//!
//! A foreign annotation carries keys this reader does not model: `/Popup`, `/Parent`, `/IRT`,
//! `/Name`, `/Open`, `/IC`, `/DS`, producer-private keys. Rebuilding the dictionary from the
//! reader's model would drop them, and a reply whose `/IRT` disappeared is an orphan. This
//! module therefore clones the source dictionary and changes **only** the keys the editor owns
//! (`/C`, `/CA`, `/Contents`, `/M`, the geometry keys, `/DA`/`/Q` for free text, and `/AP` when
//! the appearance must change). `/NM`, `/T`, `/Subj`, `/F`, `/Popup`, `/Parent`, `/IRT` and every
//! unknown key are byte-for-byte what they were.
//!
//! # What is regenerated, and what is not
//!
//! | kind | appearance |
//! | --- | --- |
//! | `/Highlight`, `/Underline`, `/StrikeOut` | no `/AP` is written; when colour or opacity changes the old `/AP` is **removed**, so every viewer synthesises the mark from the new `/C` with the multiply default those kinds have. A comment-only edit keeps the file's own `/AP` untouched. |
//! | `/Text` (sticky note) | untouched. The icon is the viewer's glyph, selected by `/Name`; moving `/Rect` keeps it. |
//! | `/FreeText` | regenerated: a form XObject with the exact new text, colour, size and alignment, in the bundled font. |
//! | `/Ink`, `/Square`, `/Circle`, `/Line` | regenerated when colour, opacity, geometry or border width changes; a comment-only edit keeps the producer's own appearance. |
//!
//! The quad geometry of a text mark is never rewritten: this reader can edit its comment and
//! colour but not the words it covers, so `/Rect` and `/QuadPoints` stay the file's own. An ink
//! stroke or a shape can be moved; its geometry is written back from the editor's page-space
//! model.
//!
//! # Deletion, popups and replies
//!
//! Deleting an annotation does two things in the same incremental revision:
//!
//! 1. removes its reference from every page's `/Annots`; and
//! 2. removes the annotations that depend on it — every `/IRT` reply, transitively, and its
//!    `/Popup` (the note window; an annotation with `/Parent` pointing at the deleted one).
//!
//! A reply is never left pointing at an object that is no longer in the annotation tree. The
//! popup is not a reply: it is the window of the deleted note, and keeping it would leave a
//! window with no note. The objects themselves stay in the file as unreferenced bytes, because
//! an incremental update cannot free an object; they are no longer part of the document's
//! annotation tree. A full rewrite (the redaction path) could drop those bytes, at the cost of
//! invalidating signatures — this reader deliberately does not do that here.
//!
//! # Identity
//!
//! Annotations are found by the same identity [`crate::annotations::AnnotationReader`] reports:
//! `nm:<NM>` when the file names the annotation, otherwise a stable fingerprint of its subtype,
//! `/Rect`, `/Contents`, `/T` and `/M`. An annotation that has no `/NM` gets one when it is first
//! edited (the shell supplies its cached annotation UUID as `assign_name`), so the identity the reader
//! shows after the save is stable too.

#![allow(unsafe_code)]

use crate::annotations::{WriteAnnotation, WriteAnnotationKind};
use crate::geometry_write::{
    EmbeddedFreeTextFont, add_appearance_object, annots_array, build_free_text_font, colour_array,
    deref, line_array, load_document, lopdf_error, name, number, quadding, rect_array,
    stamp_icon_name, text_string,
};
use lopdf::{Dictionary, Document, IncrementalDocument, Object, ObjectId};
use lyra_reader_core::{ErrorCode, LyraReaderError, Point, RawAnnotationLine, Rect, Result};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File};
use std::io::Write;
use std::path::Path;

/// One annotation the editor changed.
#[derive(Clone, Debug, PartialEq)]
pub struct AnnotationUpdate {
    /// The identity the reader reported for the annotation (`nm:…` or `fp:…`).
    pub target: String,
    /// The edited model. `values.id` is the shell's entry identity and is used only for the save
    /// report; the PDF's own `/NM` is preserved.
    pub values: WriteAnnotation,
    /// `/NM` to give the annotation when the file has none. Required when `target` is an `fp:`
    /// fingerprint, because the fingerperint is derived from `/Contents` and `/M`, which this
    /// edit changes.
    pub assign_name: Option<String>,
}

/// One annotation to remove, together with everything that depends on it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AnnotationDelete {
    /// The identity the reader reported for the annotation.
    pub target: String,
}

/// Everything one save asks the writer to do to annotations already in the file.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct AnnotationChanges {
    /// New annotations, appended exactly as before this module existed.
    pub additions: Vec<WriteAnnotation>,
    pub updates: Vec<AnnotationUpdate>,
    pub deletions: Vec<AnnotationDelete>,
}

impl AnnotationChanges {
    pub fn is_empty(&self) -> bool {
        self.additions.is_empty() && self.updates.is_empty() && self.deletions.is_empty()
    }
}

/// What [`apply_changes`] did, in the terms the shell needs for its annotation cache.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AppliedChangesReport {
    /// Identities of every annotation removed from the annotation tree, including replies and
    /// popups removed because they depended on a deleted annotation.
    pub deleted_ids: Vec<String>,
    /// How many of [`Self::deleted_ids`] were `/IRT` replies.
    pub deleted_reply_count: usize,
    /// How many were `/Popup` windows.
    pub deleted_popup_count: usize,
    /// Identities that were given an `/NM` because the file had none.
    pub assigned_names: Vec<String>,
    /// Object numbers of every dictionary the removal detached (the targets, their replies and
    /// their popups). A full rewrite uses them to delete the objects themselves rather than
    /// leaving their bytes unreachable in the file.
    pub(crate) removed_objects: Vec<(u32, u16)>,
}

/// One annotation found in the source, for planning and verification.
#[derive(Clone, Debug)]
struct AnnotationInfo {
    page: usize,
    identity: Option<String>,
    reply: bool,
    popup: bool,
}

/// Applies `changes` to `base` and writes the complete document to `output`.
///
/// `base` and `output` may name the same file: the bytes are read before the output is created.
/// Nothing here renames or verifies; those are [`crate::writeback`]'s contract.
pub(crate) fn apply_changes(
    base: &Path,
    output: &Path,
    changes: &AnnotationChanges,
    password: Option<&str>,
) -> Result<AppliedChangesReport> {
    if changes.is_empty() {
        return Ok(AppliedChangesReport::default());
    }
    let previous_bytes = fs::read(base).map_err(|error| {
        crate::geometry_write::io_error(
            "could not read the document before editing its annotations",
            base,
            error,
        )
    })?;
    let document = load_document(base, password)?;
    let mut incremental = IncrementalDocument::create_from(previous_bytes, document);

    let source = collect_annotations(incremental.get_prev_documents())?;
    let removal = plan_removal(
        incremental.get_prev_documents(),
        &source,
        &changes.deletions,
    )?;
    let updates = plan_updates(&source, &removal.removed, changes)?;

    // One embedded font per document, shared by every `/FreeText` appearance this save writes.
    let free_text: Vec<WriteAnnotation> = changes
        .additions
        .iter()
        .chain(changes.updates.iter().map(|update| &update.values))
        .filter(|annotation| {
            matches!(
                annotation.kind,
                WriteAnnotationKind::FreeText | WriteAnnotationKind::Stamp
            )
        })
        .cloned()
        .collect();
    let font = build_free_text_font(&mut incremental.new_document, &free_text)?;

    apply_removals(&mut incremental, &removal)?;
    for (object_id, update) in &updates {
        update_one(&mut incremental, *object_id, update, font.as_ref())?;
    }
    for annotation in &changes.additions {
        if !annotation.kind.is_direct() {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "the annotation editor was given a quad-based addition",
            )
            .with_detail(format!("{}: {:?}", annotation.id, annotation.kind)));
        }
        crate::geometry_write::append_one(&mut incremental, annotation, font.as_ref())?;
    }

    let mut file = File::create(output).map_err(|error| {
        crate::geometry_write::io_error(
            "could not create the file for the annotation edit",
            output,
            error,
        )
    })?;
    incremental.save_to(&mut file).map_err(|error| {
        LyraReaderError::new(ErrorCode::Io, "could not write the annotation edit")
            .with_detail(error.to_string())
    })?;
    file.flush().map_err(|error| {
        crate::geometry_write::io_error("could not flush the annotation edit", output, error)
    })?;
    file.sync_all().map_err(|error| {
        crate::geometry_write::io_error("could not fsync the annotation edit", output, error)
    })?;

    let mut report = removal.report;
    report.assigned_names = updates
        .iter()
        .filter(|(_, update)| update.target.starts_with("fp:"))
        .filter_map(|(_, update)| update.assign_name.clone())
        .collect();
    Ok(report)
}

/// Every annotation referenced by a page's `/Annots`, keyed by object id.
///
/// Pages are numbered from one in `get_pages`; the reported page is the zero-based index the
/// shell uses. Annotations that are only referenced from a `/Popup` key are added by the removal
/// planner, because their page is the page of the annotation that owns the window.
fn collect_annotations(document: &Document) -> Result<BTreeMap<ObjectId, AnnotationInfo>> {
    let mut infos = BTreeMap::new();
    for (number, page_id) in document.get_pages() {
        let page = usize::try_from(number.saturating_sub(1)).unwrap_or(usize::MAX);
        for object_id in page_annotation_ids(document, page_id)? {
            if infos.contains_key(&object_id) {
                continue;
            }
            let info = annotation_info(document, object_id, page)?;
            infos.insert(object_id, info);
        }
    }
    Ok(infos)
}

fn annotation_info(
    document: &Document,
    object_id: ObjectId,
    page: usize,
) -> Result<AnnotationInfo> {
    let dictionary = annotation_dictionary(document, object_id)?;
    Ok(AnnotationInfo {
        page,
        identity: annotation_identity(document, dictionary),
        reply: dictionary.get(b"IRT").is_ok(),
        popup: subtype(dictionary).as_deref() == Some("Popup"),
    })
}

fn annotation_dictionary(document: &Document, object_id: ObjectId) -> Result<&Dictionary> {
    document
        .get_object(object_id)
        .and_then(Object::as_dict)
        .map_err(|error| {
            LyraReaderError::new(
                ErrorCode::CorruptDocument,
                "an annotation reference does not name an annotation dictionary",
            )
            .with_detail(format!("{object_id:?}: {error}"))
        })
}

fn page_annotation_ids(document: &Document, page_id: ObjectId) -> Result<Vec<ObjectId>> {
    let page = document.get_dictionary(page_id).map_err(|error| {
        lopdf_error("could not read a page while looking for annotations", error)
    })?;
    let Some(annots) = page
        .get(b"Annots")
        .ok()
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_array().ok())
    else {
        return Ok(Vec::new());
    };
    Ok(annots
        .iter()
        .filter_map(|object| object.as_reference().ok())
        .collect())
}

fn subtype(dictionary: &Dictionary) -> Option<String> {
    dictionary
        .get(b"Subtype")
        .ok()
        .and_then(|object| object.as_name().ok())
        .map(|name| String::from_utf8_lossy(name).into_owned())
}

/// The identity [`crate::annotations::AnnotationReader`] reports for this dictionary.
///
/// `/NM` wins. The fingerprint is the same FNV-1a of subtype, `/Rect` and the three strings the
/// reader uses, with the rect values rounded through `f32` exactly as PDFium hands them over.
fn annotation_identity(document: &Document, dictionary: &Dictionary) -> Option<String> {
    if let Some(name) = dictionary
        .get(b"NM")
        .ok()
        .and_then(|object| pdf_text(document, object))
        .filter(|name| !name.is_empty())
    {
        return Some(format!("nm:{name}"));
    }
    let subtype = subtype_number(dictionary)?;
    let mut hash = StableHash::new();
    hash.integer(subtype);
    if let Some(rect) = rect_values(dictionary) {
        for value in rect {
            hash.integer(u64::from(value.to_bits()));
        }
    }
    for key in [b"Contents".as_slice(), b"T".as_slice(), b"M".as_slice()] {
        if let Some(value) = dictionary
            .get(key)
            .ok()
            .and_then(|object| pdf_text(document, object))
        {
            hash.string(&value);
        }
    }
    Some(format!("fp:{:016x}", hash.finish()))
}

/// The PDFium `FPDF_ANNOTATION_SUBTYPE` number for a `/Subtype` name, used only by the fallback
/// identity. The numbers are `fpdf_annot.h`'s constants; the mapping is the same one
/// `AnnotationReader` reads through PDFium.
fn subtype_number(dictionary: &Dictionary) -> Option<u64> {
    match subtype(dictionary)?.as_str() {
        "Text" => Some(1),
        "Link" => Some(2),
        "FreeText" => Some(3),
        "Line" => Some(4),
        "Square" => Some(5),
        "Circle" => Some(6),
        "Polygon" => Some(7),
        "PolyLine" => Some(8),
        "Highlight" => Some(9),
        "Underline" => Some(10),
        "Squiggly" => Some(11),
        "StrikeOut" => Some(12),
        "Stamp" => Some(13),
        "Caret" => Some(14),
        "Ink" => Some(15),
        "Popup" => Some(16),
        "FileAttachment" => Some(17),
        "Sound" => Some(18),
        "Movie" => Some(19),
        "Widget" => Some(20),
        "Screen" => Some(21),
        "PrinterMark" => Some(22),
        "TrapNet" => Some(23),
        "Watermark" => Some(24),
        "3D" => Some(25),
        "RichMedia" => Some(26),
        _ => None,
    }
}

/// The fields of the FNV-1a identity hash, copied from `annotations.rs` so the two derivations
/// cannot drift.
struct StableHash(u64);

impl StableHash {
    fn new() -> Self {
        Self(0xcbf2_9ce4_8422_2325)
    }

    fn bytes(&mut self, bytes: &[u8]) {
        for byte in bytes {
            self.0 ^= u64::from(*byte);
            self.0 = self.0.wrapping_mul(0x0000_0100_0000_01b3);
        }
        self.bytes_raw(&[0xff]);
    }

    fn bytes_raw(&mut self, bytes: &[u8]) {
        for byte in bytes {
            self.0 ^= u64::from(*byte);
            self.0 = self.0.wrapping_mul(0x0000_0100_0000_01b3);
        }
    }

    fn integer(&mut self, value: u64) {
        self.bytes_raw(&value.to_le_bytes());
    }

    fn string(&mut self, value: &str) {
        self.bytes(value.as_bytes());
    }

    fn finish(&self) -> u64 {
        self.0
    }
}

fn rect_values(dictionary: &Dictionary) -> Option<[f32; 4]> {
    let array = dictionary.get(b"Rect").ok()?.as_array().ok()?;
    if array.len() != 4 {
        return None;
    }
    let mut values = [0.0f32; 4];
    for (slot, object) in values.iter_mut().zip(array) {
        *slot = number(object)?;
    }
    Some(values)
}

fn pdf_text(document: &Document, object: &Object) -> Option<String> {
    let bytes = deref(document, object)?.as_str().ok()?;
    if bytes.starts_with(&[0xFE, 0xFF]) {
        let units: Vec<u16> = bytes[2..]
            .chunks(2)
            .filter(|pair| pair.len() == 2)
            .map(|pair| u16::from_be_bytes([pair[0], pair[1]]))
            .collect();
        Some(String::from_utf16_lossy(&units))
    } else {
        Some(String::from_utf8_lossy(bytes).into_owned())
    }
}

/// The annotations a deletion removes: the targets, their reply descendants and their popup
/// windows, plus any popup of an annotation that is itself being removed.
struct RemovalPlan {
    removed: BTreeSet<ObjectId>,
    report: AppliedChangesReport,
}

fn plan_removal(
    document: &Document,
    annotations: &BTreeMap<ObjectId, AnnotationInfo>,
    deletions: &[AnnotationDelete],
) -> Result<RemovalPlan> {
    let mut removed = BTreeSet::new();
    for deletion in deletions {
        let object_id = find_identity(annotations, &deletion.target)?;
        removed.insert(object_id);
    }

    // A popup can be referenced by `/Popup` without being in a page's `/Annots`; collect those
    // objects too so the closure below can see them.
    let mut extra: BTreeMap<ObjectId, AnnotationInfo> = BTreeMap::new();
    for object_id in annotations.keys().copied().collect::<Vec<_>>() {
        collect_popup(document, object_id, &mut extra)?;
    }
    let all: BTreeMap<ObjectId, AnnotationInfo> = annotations
        .iter()
        .chain(extra.iter())
        .map(|(id, info)| (*id, info.clone()))
        .collect();

    loop {
        let mut added = Vec::new();
        for (object_id, info) in &all {
            if removed.contains(object_id) {
                continue;
            }
            let dictionary = annotation_dictionary(document, *object_id)?;
            let reply_to_removed = dictionary
                .get(b"IRT")
                .ok()
                .and_then(|object| object.as_reference().ok())
                .is_some_and(|parent| removed.contains(&parent));
            let popup_of_removed = info.popup
                && dictionary
                    .get(b"Parent")
                    .ok()
                    .and_then(|object| object.as_reference().ok())
                    .is_some_and(|parent| removed.contains(&parent));
            if reply_to_removed || popup_of_removed {
                added.push(*object_id);
            }
        }
        for object_id in removed.iter().copied().collect::<Vec<_>>() {
            if let Ok(dictionary) = annotation_dictionary(document, object_id)
                && let Ok(popup) = dictionary.get(b"Popup").and_then(Object::as_reference)
                && all.contains_key(&popup)
                && !removed.contains(&popup)
            {
                added.push(popup);
            }
        }
        if added.is_empty() {
            break;
        }
        removed.extend(added);
    }

    let mut report = AppliedChangesReport::default();
    for object_id in &removed {
        let Some(info) = all.get(object_id) else {
            continue;
        };
        if info.reply {
            report.deleted_reply_count += 1;
        }
        if info.popup {
            report.deleted_popup_count += 1;
        }
        if let Some(identity) = &info.identity {
            report.deleted_ids.push(identity.clone());
        }
    }
    report.deleted_ids.sort();
    report.removed_objects = removed.iter().copied().collect();
    Ok(RemovalPlan { removed, report })
}

fn collect_popup(
    document: &Document,
    object_id: ObjectId,
    extra: &mut BTreeMap<ObjectId, AnnotationInfo>,
) -> Result<()> {
    let Ok(dictionary) = annotation_dictionary(document, object_id) else {
        return Ok(());
    };
    let Ok(popup) = dictionary.get(b"Popup").and_then(Object::as_reference) else {
        return Ok(());
    };
    if extra.contains_key(&popup) {
        return Ok(());
    }
    let page = 0;
    let info = annotation_info(document, popup, page)?;
    extra.insert(popup, info);
    Ok(())
}

fn apply_removals(incremental: &mut IncrementalDocument, plan: &RemovalPlan) -> Result<()> {
    let pages: Vec<ObjectId> = incremental
        .get_prev_documents()
        .get_pages()
        .values()
        .copied()
        .collect();
    for page_id in pages {
        let existing = page_annotation_ids(incremental.get_prev_documents(), page_id)?;
        if !existing.iter().any(|id| plan.removed.contains(id)) {
            continue;
        }
        let annots = annots_array(incremental, page_id)?;
        annots.retain(|object| {
            object
                .as_reference()
                .map(|id| !plan.removed.contains(&id))
                .unwrap_or(true)
        });
    }

    // A surviving annotation must not keep a link to an object that is no longer in the tree.
    // Cascading already removes every reply and popup that depends on a deleted target, so this
    // finds only a malformed file; it is still cheaper to clear the link than to leave a viewer
    // following a dangling reference.
    let mut remaining: BTreeSet<ObjectId> = BTreeSet::new();
    for page_id in incremental.get_prev_documents().get_pages().values() {
        remaining.extend(page_annotation_ids(
            incremental.get_prev_documents(),
            *page_id,
        )?);
    }
    remaining.retain(|id| !plan.removed.contains(id));
    for object_id in remaining {
        let needs_clone = {
            let dictionary = annotation_dictionary(incremental.get_prev_documents(), object_id)?;
            [b"IRT".as_slice(), b"Popup".as_slice()].iter().any(|key| {
                dictionary
                    .get(key)
                    .ok()
                    .and_then(|object| object.as_reference().ok())
                    .is_some_and(|target| plan.removed.contains(&target))
            })
        };
        if !needs_clone {
            continue;
        }
        incremental
            .opt_clone_object_to_new_document(object_id)
            .map_err(|error| lopdf_error("could not copy an annotation for link cleanup", error))?;
        let dictionary = incremental
            .new_document
            .get_object_mut(object_id)
            .map_err(|error| lopdf_error("the annotation is missing from the new revision", error))?
            .as_dict_mut()
            .map_err(|error| lopdf_error("the annotation is not a dictionary", error))?;
        for key in [b"IRT".as_slice(), b"Popup".as_slice()] {
            let removed = dictionary
                .get(key)
                .ok()
                .and_then(|object| object.as_reference().ok())
                .is_some_and(|target| plan.removed.contains(&target));
            if removed {
                dictionary.remove(key);
            }
        }
    }
    Ok(())
}

fn plan_updates<'a>(
    annotations: &BTreeMap<ObjectId, AnnotationInfo>,
    removed: &BTreeSet<ObjectId>,
    changes: &'a AnnotationChanges,
) -> Result<Vec<(ObjectId, &'a AnnotationUpdate)>> {
    let mut planned = Vec::with_capacity(changes.updates.len());
    let mut targets = BTreeSet::new();
    for update in &changes.updates {
        let object_id = find_identity(annotations, &update.target)?;
        if removed.contains(&object_id) {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "an annotation cannot be both edited and deleted in one save",
            )
            .with_detail(update.target.clone()));
        }
        if !targets.insert(object_id) {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "the same annotation was edited twice in one save",
            )
            .with_detail(update.target.clone()));
        }
        let info = &annotations[&object_id];
        if info.page != usize::try_from(update.values.page.get()).unwrap_or(usize::MAX) {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "an edited annotation is not on the page the edit names",
            )
            .with_detail(format!(
                "{}: file page {}, edit page {}",
                update.target,
                info.page,
                update.values.page.get()
            )));
        }
        planned.push((object_id, update));
    }
    Ok(planned)
}

fn find_identity(
    annotations: &BTreeMap<ObjectId, AnnotationInfo>,
    target: &str,
) -> Result<ObjectId> {
    let mut found = Vec::new();
    for (object_id, info) in annotations {
        if info.identity.as_deref() == Some(target) {
            found.push(*object_id);
        }
    }
    match found.as_slice() {
        [object_id] => Ok(*object_id),
        [] => Err(LyraReaderError::new(
            ErrorCode::NotFound,
            "the PDF does not contain the annotation this edit names",
        )
        .with_detail(format!(
            "{target} (the file may have been changed after it was opened)"
        ))),
        _ => Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the PDF contains the same annotation identity on more than one page",
        )
        .with_detail(target.to_string())),
    }
}

fn update_one(
    incremental: &mut IncrementalDocument,
    object_id: ObjectId,
    update: &AnnotationUpdate,
    font: Option<&EmbeddedFreeTextFont>,
) -> Result<()> {
    let source = incremental
        .get_prev_documents()
        .get_object(object_id)
        .and_then(Object::as_dict)
        .map_err(|error| lopdf_error("could not read the annotation being edited", error))?
        .clone();

    let expected_subtype = update.values.kind.pdf_name();
    let actual_subtype = subtype(&source).unwrap_or_default();
    if actual_subtype != expected_subtype {
        return Err(LyraReaderError::new(
            ErrorCode::InvalidArgument,
            "the annotation's kind changed between reading and saving",
        )
        .with_detail(format!(
            "{}: file /{actual_subtype}, edit /{expected_subtype}",
            update.target
        )));
    }

    let kind = update.values.kind;
    let visual_changed = visual_change(&source, &update.values);
    let regenerate = match kind {
        WriteAnnotationKind::FreeText
        | WriteAnnotationKind::Stamp
        | WriteAnnotationKind::Signature => true,
        WriteAnnotationKind::Ink
        | WriteAnnotationKind::Square
        | WriteAnnotationKind::Circle
        | WriteAnnotationKind::Line => visual_changed,
        WriteAnnotationKind::Highlight
        | WriteAnnotationKind::Underline
        | WriteAnnotationKind::StrikeOut
        | WriteAnnotationKind::Text => false,
    };
    // The appearance is appended before the dictionary is borrowed mutably.
    let appearance = regenerate
        .then(|| add_appearance_object(&mut incremental.new_document, &update.values, font));

    incremental
        .opt_clone_object_to_new_document(object_id)
        .map_err(|error| {
            lopdf_error("could not copy the annotation into the new revision", error)
        })?;
    let dictionary = incremental
        .new_document
        .get_object_mut(object_id)
        .map_err(|error| lopdf_error("the edited annotation is missing", error))?
        .as_dict_mut()
        .map_err(|error| lopdf_error("the edited annotation is not a dictionary", error))?;

    dictionary.set("C", colour_array(update.values.color));
    dictionary.set("CA", Object::Real(update.values.opacity as f32));
    match update.values.contents.as_deref() {
        Some(contents) => dictionary.set("Contents", text_string(contents)),
        None => {
            dictionary.remove(b"Contents");
        }
    }
    if let Some(modified) = update.values.modified.as_deref() {
        dictionary.set("M", text_string(modified));
    }

    match kind {
        WriteAnnotationKind::Stamp | WriteAnnotationKind::Signature => {
            dictionary.set("Rect", rect_array(update.values.rect));
            set_stamp_key(dictionary, &update.values);
            dictionary.set("Name", name(stamp_icon_name(&update.values)));
            if let Some(appearance) = appearance {
                set_normal_appearance(dictionary, appearance);
            }
        }
        WriteAnnotationKind::Highlight
        | WriteAnnotationKind::Underline
        | WriteAnnotationKind::StrikeOut => {
            // Geometry is the text's, not the editor's. Colour and opacity are the only visual
            // fields, so only those can make the file's own appearance stale.
            if visual_changed {
                dictionary.remove(b"AP");
            }
        }
        WriteAnnotationKind::Text => {
            dictionary.set("Rect", rect_array(update.values.rect));
            // `/Name`, `/Open`, `/AP` and every producer key stay as they were.
        }
        WriteAnnotationKind::FreeText => {
            dictionary.set("Rect", rect_array(update.values.rect));
            let da = dictionary
                .get(b"DA")
                .ok()
                .and_then(|object| object.as_str().ok())
                .map(<[u8]>::to_vec);
            dictionary.set(
                "DA",
                text_string(&da_with_font_size(da.as_deref(), update.values.font_size)),
            );
            dictionary.set("Q", Object::Integer(quadding(update.values.alignment)));
            set_normal_appearance(dictionary, appearance.expect("free text regenerates /AP"));
        }
        WriteAnnotationKind::Ink => {
            dictionary.set("Rect", rect_array(update.values.rect));
            dictionary.set("InkList", ink_list(&update.values.ink_paths));
            set_border_width(dictionary, update.values.border_width);
            if let Some(appearance) = appearance {
                set_normal_appearance(dictionary, appearance);
            }
        }
        WriteAnnotationKind::Square | WriteAnnotationKind::Circle => {
            dictionary.set("Rect", rect_array(update.values.rect));
            set_border_width(dictionary, update.values.border_width);
            if let Some(appearance) = appearance {
                set_normal_appearance(dictionary, appearance);
            }
        }
        WriteAnnotationKind::Line => {
            dictionary.set("Rect", rect_array(update.values.rect));
            let Some(line) = update.values.line else {
                return Err(LyraReaderError::new(
                    ErrorCode::InvalidArgument,
                    "an edited line annotation has no endpoints",
                )
                .with_detail(update.target.clone()));
            };
            dictionary.set("L", line_array(line.start, line.end));
            // `/LE` is preserved: the editor models "has an arrowhead", not the arrow's style,
            // and replacing an `/OpenArrow` with this writer's closed arrow would silently
            // change another producer's mark.
            set_border_width(dictionary, update.values.border_width);
            if let Some(appearance) = appearance {
                set_normal_appearance(dictionary, appearance);
            }
        }
    }

    if !update.target.starts_with("nm:")
        && let Some(assigned) = update.assign_name.as_deref()
        && dictionary
            .get(b"NM")
            .ok()
            .and_then(|object| object.as_str().ok())
            .map(|bytes| bytes.is_empty())
            .unwrap_or(true)
    {
        dictionary.set("NM", text_string(assigned));
    }
    Ok(())
}

/// Whether the edit changes anything an appearance stream paints.
///
/// A comment-only edit on an ink stroke, shape or line keeps the producer's appearance stream:
/// rewriting the comment must not silently redraw the stroke with this writer's line caps.
fn visual_change(source: &Dictionary, values: &WriteAnnotation) -> bool {
    let color = source_colour(source);
    if color != Some(values.color) {
        return true;
    }
    let opacity = source_opacity(source).unwrap_or(1.0);
    if (opacity - values.opacity).abs() > 0.5 / 255.0 {
        return true;
    }
    match values.kind {
        WriteAnnotationKind::Highlight
        | WriteAnnotationKind::Underline
        | WriteAnnotationKind::StrikeOut
        | WriteAnnotationKind::Text => false,
        WriteAnnotationKind::FreeText
        | WriteAnnotationKind::Stamp
        | WriteAnnotationKind::Signature => true,
        WriteAnnotationKind::Ink => {
            let source_ink = source_ink(source);
            !ink_equal(&source_ink, &values.ink_paths)
                || !rect_close(source_rect(source), values.rect)
        }
        WriteAnnotationKind::Square | WriteAnnotationKind::Circle => {
            !rect_close(source_rect(source), values.rect)
                || !width_close(source_width(source), values.border_width)
        }
        WriteAnnotationKind::Line => {
            !line_close(source_line(source), values.line)
                || !rect_close(source_rect(source), values.rect)
                || !width_close(source_width(source), values.border_width)
        }
    }
}

fn source_colour(dictionary: &Dictionary) -> Option<[u8; 3]> {
    let array = dictionary.get(b"C").ok()?.as_array().ok()?;
    if array.len() < 3 {
        return None;
    }
    let mut channels = [0u8; 3];
    for (slot, object) in channels.iter_mut().zip(array) {
        let value = number(object)?;
        *slot = (value.clamp(0.0, 1.0) * 255.0).round() as u8;
    }
    Some(channels)
}

fn source_opacity(dictionary: &Dictionary) -> Option<f64> {
    let value = number(dictionary.get(b"CA").ok()?)?;
    Some(f64::from(value.clamp(0.0, 1.0)))
}

fn source_rect(dictionary: &Dictionary) -> Option<Rect> {
    let values = rect_values(dictionary)?;
    Some(Rect::new(
        f64::from(values[0]),
        f64::from(values[1]),
        f64::from(values[2] - values[0]),
        f64::from(values[3] - values[1]),
    ))
}

fn source_ink(dictionary: &Dictionary) -> Vec<Vec<Point>> {
    let Ok(paths) = dictionary.get(b"InkList").and_then(Object::as_array) else {
        return Vec::new();
    };
    paths
        .iter()
        .filter_map(|path| path.as_array().ok())
        .map(|path| {
            path.chunks(2)
                .filter(|pair| pair.len() == 2)
                .filter_map(|pair| {
                    let x = number(&pair[0])?;
                    let y = number(&pair[1])?;
                    Some(Point::new(f64::from(x), f64::from(y)))
                })
                .collect::<Vec<_>>()
        })
        .filter(|path| !path.is_empty())
        .collect()
}

fn source_line(dictionary: &Dictionary) -> Option<RawAnnotationLine> {
    let array = dictionary.get(b"L").ok()?.as_array().ok()?;
    if array.len() != 4 {
        return None;
    }
    let mut values = [0.0f32; 4];
    for (slot, object) in values.iter_mut().zip(array) {
        *slot = number(object)?;
    }
    Some(RawAnnotationLine {
        start: Point::new(f64::from(values[0]), f64::from(values[1])),
        end: Point::new(f64::from(values[2]), f64::from(values[3])),
    })
}

fn source_width(dictionary: &Dictionary) -> Option<f64> {
    if let Some(width) = dictionary
        .get(b"BS")
        .ok()
        .and_then(|object| object.as_dict().ok())
        .and_then(|bs| bs.get(b"W").ok())
        .and_then(number)
    {
        return Some(f64::from(width));
    }
    dictionary
        .get(b"Border")
        .ok()
        .and_then(|object| object.as_array().ok())
        .and_then(|array| array.get(2))
        .and_then(number)
        .map(f64::from)
}

fn ink_equal(left: &[Vec<Point>], right: &[Vec<Point>]) -> bool {
    left.len() == right.len()
        && left.iter().zip(right).all(|(left, right)| {
            left.len() == right.len()
                && left.iter().zip(right).all(|(left, right)| {
                    (left.x - right.x).abs() <= 0.02 && (left.y - right.y).abs() <= 0.02
                })
        })
}

fn rect_close(left: Option<Rect>, right: Rect) -> bool {
    let Some(left) = left else {
        return false;
    };
    (left.origin.x - right.origin.x).abs() <= 0.05
        && (left.origin.y - right.origin.y).abs() <= 0.05
        && (left.size.width - right.size.width).abs() <= 0.05
        && (left.size.height - right.size.height).abs() <= 0.05
}

fn line_close(left: Option<RawAnnotationLine>, right: Option<RawAnnotationLine>) -> bool {
    let (Some(left), Some(right)) = (left, right) else {
        return false;
    };
    (left.start.x - right.start.x).abs() <= 0.02
        && (left.start.y - right.start.y).abs() <= 0.02
        && (left.end.x - right.end.x).abs() <= 0.02
        && (left.end.y - right.end.y).abs() <= 0.02
}

fn width_close(left: Option<f64>, right: f64) -> bool {
    left.is_some_and(|left| (left - right).abs() <= 0.02)
}

fn ink_list(paths: &[Vec<Point>]) -> Object {
    Object::Array(
        paths
            .iter()
            .map(|path| {
                Object::Array(
                    path.iter()
                        .flat_map(|point| {
                            [Object::Real(point.x as f32), Object::Real(point.y as f32)]
                        })
                        .collect(),
                )
            })
            .collect(),
    )
}

/// Sets `/BS /W` and the legacy `/Border` width while preserving the style keys (`/S`, `/D`)
/// the producer put in `/BS` and the dash array in `/Border`.
fn set_border_width(dictionary: &mut Dictionary, width: f64) {
    let mut border_style = dictionary
        .get(b"BS")
        .ok()
        .and_then(|object| object.as_dict().ok())
        .cloned()
        .unwrap_or_else(|| {
            let mut style = Dictionary::new();
            style.set("S", name("S"));
            style
        });
    border_style.set("W", Object::Real(width as f32));
    dictionary.set("BS", Object::Dictionary(border_style));

    let mut border = dictionary
        .get(b"Border")
        .ok()
        .and_then(|object| object.as_array().ok())
        .cloned()
        .unwrap_or_else(|| vec![Object::Integer(0), Object::Integer(0), Object::Real(0.0)]);
    if border.len() < 3 {
        border.resize(3, Object::Integer(0));
    }
    border[2] = Object::Real(width as f32);
    dictionary.set("Border", Object::Array(border));
}

/// Sets `/AP /N` while preserving any other appearance states (`/R`, `/D`).
fn set_normal_appearance(dictionary: &mut Dictionary, appearance: ObjectId) {
    let mut ap = dictionary
        .get(b"AP")
        .ok()
        .and_then(|object| object.as_dict().ok())
        .cloned()
        .unwrap_or_default();
    ap.set("N", Object::Reference(appearance));
    dictionary.set("AP", Object::Dictionary(ap));
}

/// Replaces only the size operand of `/DA`'s `Tf`, preserving the font resource the producer
/// chose and any colour/other operators in the string.
fn da_with_font_size(original: Option<&[u8]>, size: f64) -> String {
    let size = format!("{size:.4}");
    let Some(original) = original
        .map(|bytes| String::from_utf8_lossy(bytes).into_owned())
        .filter(|text| !text.trim().is_empty())
    else {
        return format!("/Helv {size} Tf 0 g");
    };
    let mut tokens: Vec<String> = original.split_whitespace().map(str::to_string).collect();
    if let Some(tf) = tokens.iter().rposition(|token| token == "Tf")
        && tf >= 2
    {
        tokens[tf - 1] = size;
        return tokens.join(" ");
    }
    format!("/Helv {size} Tf 0 g")
}

// ── Verification ─────────────────────────────────────────────────────────────────────────────

/// Keys this module may change. Everything else in an edited dictionary must be identical.
fn owned_key(key: &[u8]) -> bool {
    matches!(
        key,
        b"C" | b"CA"
            | b"Contents"
            | b"M"
            | b"Rect"
            | b"QuadPoints"
            | b"InkList"
            | b"L"
            | b"BS"
            | b"Border"
            | b"AP"
            | b"DA"
            | b"Q"
            | b"LE"
            | b"NM"
            // A stamp edit owns its appearance's `/Name` and this writer's private stamp model.
            // Both are namespaced to the stamp path: no other kind's edit sets them.
            | b"Name"
            | b"LyraReaderStamp"
    )
}

/// Reopens the saved file and proves the edit did only what it promised.
///
/// This runs in addition to [`crate::writeback`]'s reader-level verification: that one proves
/// what PDFium sees; this one proves what the dictionary kept, including the keys the reader
/// does not model (`/Popup`, `/Parent`, `/IRT`, `/F`, `/T`, `/Subj`, private keys).
pub(crate) fn verify_changes(
    source: &Path,
    saved: &Path,
    changes: &AnnotationChanges,
    password: Option<&str>,
) -> Result<()> {
    if changes.updates.is_empty() && changes.deletions.is_empty() {
        return Ok(());
    }
    let source_document = load_document(source, password)?;
    let saved_document = load_document(saved, password)?;
    let source_annotations = collect_annotations(&source_document)?;
    let saved_annotations = collect_annotations(&saved_document)?;
    let removal = plan_removal(&source_document, &source_annotations, &changes.deletions)?;

    // Nothing removed may still be reachable, and nothing reachable may point at it.
    for page_id in saved_document.get_pages().values() {
        for object_id in page_annotation_ids(&saved_document, *page_id)? {
            if removal.removed.contains(&object_id) {
                return Err(verification(
                    "a deleted annotation is still in a page's /Annots",
                    format!("{object_id:?}"),
                ));
            }
            let dictionary = annotation_dictionary(&saved_document, object_id)?;
            for key in [b"IRT".as_slice(), b"Popup".as_slice()] {
                if let Ok(target) = dictionary.get(key).and_then(Object::as_reference)
                    && removal.removed.contains(&target)
                {
                    return Err(verification(
                        "an annotation still points at a deleted annotation",
                        format!("{object_id:?} /{key:?} -> {target:?}"),
                    ));
                }
            }
        }
    }

    // Untouched annotations are semantically identical, key by key.
    for (object_id, info) in &source_annotations {
        if removal.removed.contains(object_id) {
            continue;
        }
        let updated = changes
            .updates
            .iter()
            .find(|update| info.identity.as_deref() == Some(update.target.as_str()));
        if updated.is_some() {
            continue;
        }
        let before = annotation_dictionary(&source_document, *object_id)?;
        let after = annotation_dictionary(&saved_document, *object_id)?;
        if before != after {
            return Err(verification(
                "an annotation the save did not edit changed",
                info.identity
                    .clone()
                    .unwrap_or_else(|| format!("{object_id:?}")),
            ));
        }
    }

    for update in &changes.updates {
        let source_id = find_identity(&source_annotations, &update.target)?;
        let before = annotation_dictionary(&source_document, source_id)?;
        let after = find_saved_annotation(&saved_document, &saved_annotations, update)?;
        verify_update(&source_document, before, &saved_document, after, update)?;
    }
    Ok(())
}

fn find_saved_annotation<'a>(
    document: &'a Document,
    annotations: &'a BTreeMap<ObjectId, AnnotationInfo>,
    update: &AnnotationUpdate,
) -> Result<&'a Dictionary> {
    let expected = if update.target.starts_with("nm:") {
        update.target.clone()
    } else {
        update
            .assign_name
            .as_deref()
            .map(|name| format!("nm:{name}"))
            .ok_or_else(|| {
                verification(
                    "an edited annotation without /NM was saved without a name",
                    update.target.clone(),
                )
            })?
    };
    let object_id = find_identity(annotations, &expected).map_err(|_| {
        verification(
            "the edited annotation is not in the saved file under its expected identity",
            format!("{} -> {expected}", update.target),
        )
    })?;
    annotation_dictionary(document, object_id)
}

fn verify_update(
    source_document: &Document,
    before: &Dictionary,
    saved_document: &Document,
    after: &Dictionary,
    update: &AnnotationUpdate,
) -> Result<()> {
    let fail =
        |detail: String| verification("the saved annotation does not match the edit", detail);
    let values = &update.values;

    // Every key the editor does not own is untouched, and no private key is dropped.
    for (key, value) in before.iter() {
        if owned_key(key) {
            continue;
        }
        if after.get(key).ok() != Some(value) {
            return Err(fail(format!(
                "{}: /{} changed or disappeared",
                update.target,
                String::from_utf8_lossy(key)
            )));
        }
    }
    for (key, _) in after.iter() {
        if owned_key(key) || before.has(key) {
            continue;
        }
        return Err(fail(format!(
            "{}: unexpected new key /{}",
            update.target,
            String::from_utf8_lossy(key)
        )));
    }

    if after.get(b"C").ok().and_then(colour_of) != Some(values.color) {
        return Err(fail(format!("{}: /C", update.target)));
    }
    if (after
        .get(b"CA")
        .ok()
        .and_then(number)
        .map(f64::from)
        .unwrap_or(1.0)
        - values.opacity)
        .abs()
        > 1.0 / 255.0 + 1e-6
    {
        return Err(fail(format!("{}: /CA", update.target)));
    }
    let contents = after
        .get(b"Contents")
        .ok()
        .and_then(|object| pdf_text(saved_document, object));
    if contents != values.contents {
        return Err(fail(format!(
            "{}: /Contents expected {:?}, found {contents:?}",
            update.target, values.contents
        )));
    }
    if let Some(modified) = values.modified.as_deref()
        && after
            .get(b"M")
            .ok()
            .and_then(|object| pdf_text(saved_document, object))
            .as_deref()
            != Some(modified)
    {
        return Err(fail(format!("{}: /M", update.target)));
    }

    match values.kind {
        WriteAnnotationKind::Stamp | WriteAnnotationKind::Signature => {
            verify_rect(after, values.rect, &fail, &update.target)?;
            verify_stamp_key_saved(saved_document, after, values, &fail, &update.target)?;
            verify_appearance_policy(before, after, update, saved_document, &fail)?;
        }
        WriteAnnotationKind::Highlight
        | WriteAnnotationKind::Underline
        | WriteAnnotationKind::StrikeOut => {
            for key in [b"Rect".as_slice(), b"QuadPoints".as_slice()] {
                if before.get(key).ok() != after.get(key).ok() {
                    return Err(fail(format!(
                        "{}: /{} is not the file's own geometry",
                        update.target,
                        String::from_utf8_lossy(key)
                    )));
                }
            }
        }
        WriteAnnotationKind::Text => {
            verify_rect(after, values.rect, &fail, &update.target)?;
        }
        WriteAnnotationKind::FreeText => {
            verify_rect(after, values.rect, &fail, &update.target)?;
            verify_da(after, values.font_size, &fail, &update.target)?;
            let alignment = after
                .get(b"Q")
                .ok()
                .and_then(|object| object.as_i64().ok())
                .unwrap_or(0);
            if alignment != quadding(values.alignment) {
                return Err(fail(format!("{}: /Q", update.target)));
            }
            verify_normal_appearance(saved_document, after, &fail, &update.target)?;
        }
        WriteAnnotationKind::Ink => {
            verify_rect(after, values.rect, &fail, &update.target)?;
            let ink = source_ink(after);
            if !ink_equal(&ink, &values.ink_paths) {
                return Err(fail(format!("{}: /InkList", update.target)));
            }
            verify_width(after, values.border_width, &fail, &update.target)?;
            verify_appearance_policy(before, after, update, saved_document, &fail)?;
        }
        WriteAnnotationKind::Square | WriteAnnotationKind::Circle => {
            verify_rect(after, values.rect, &fail, &update.target)?;
            verify_width(after, values.border_width, &fail, &update.target)?;
            verify_appearance_policy(before, after, update, saved_document, &fail)?;
        }
        WriteAnnotationKind::Line => {
            verify_rect(after, values.rect, &fail, &update.target)?;
            if !line_close(source_line(after), values.line) {
                return Err(fail(format!("{}: /L", update.target)));
            }
            verify_width(after, values.border_width, &fail, &update.target)?;
            if before.get(b"LE").ok() != after.get(b"LE").ok() {
                return Err(fail(format!("{}: /LE changed", update.target)));
            }
            verify_appearance_policy(before, after, update, saved_document, &fail)?;
        }
    }
    if !update.target.starts_with("nm:") {
        let assigned = update.assign_name.as_deref().unwrap_or_default();
        if after
            .get(b"NM")
            .ok()
            .and_then(|object| pdf_text(saved_document, object))
            .as_deref()
            != Some(assigned)
        {
            return Err(fail(format!("{}: /NM was not assigned", update.target)));
        }
    }
    // `/Popup`, `/Parent` and `/IRT` are not owned: the loop above already proved them equal.
    let _ = source_document;
    Ok(())
}

/// Writes the private stamp model an edit keeps in step with the appearance.
fn set_stamp_key(dictionary: &mut Dictionary, values: &WriteAnnotation) {
    let mut key = Dictionary::new();
    key.set(
        "Text",
        text_string(values.contents.as_deref().unwrap_or("")),
    );
    key.set(
        "Style",
        name(if values.kind == WriteAnnotationKind::Signature {
            "signature"
        } else {
            values.stamp_style.as_deref().unwrap_or("custom")
        }),
    );
    dictionary.set("LyraReaderStamp", Object::Dictionary(key));
}

/// Checks the private stamp model after an edit.
fn verify_stamp_key_saved(
    document: &Document,
    dictionary: &Dictionary,
    values: &WriteAnnotation,
    fail: &impl Fn(String) -> LyraReaderError,
    id: &str,
) -> Result<()> {
    let Some(key) = dictionary
        .get(b"LyraReaderStamp")
        .ok()
        .and_then(|object| object.as_dict().ok())
    else {
        return Err(fail(format!("{id}: no /LyraReaderStamp after the edit")));
    };
    let text = key
        .get(b"Text")
        .ok()
        .and_then(|object| pdf_text(document, object))
        .unwrap_or_default();
    if text != values.contents.clone().unwrap_or_default() {
        return Err(fail(format!("{id}: stamp /Text")));
    }
    let expected = if values.kind == WriteAnnotationKind::Signature {
        "signature"
    } else {
        values.stamp_style.as_deref().unwrap_or("custom")
    };
    let style = key
        .get(b"Style")
        .ok()
        .and_then(|object| object.as_name().ok())
        .map(String::from_utf8_lossy);
    if style.as_deref() != Some(expected) {
        return Err(fail(format!("{id}: stamp /Style")));
    }
    Ok(())
}

fn verify_appearance_policy(
    before: &Dictionary,
    after: &Dictionary,
    update: &AnnotationUpdate,
    saved_document: &Document,
    fail: &impl Fn(String) -> LyraReaderError,
) -> Result<()> {
    if visual_change(before, &update.values) {
        verify_normal_appearance(saved_document, after, fail, &update.target)
    } else if before.get(b"AP").ok() != after.get(b"AP").ok() {
        Err(fail(format!(
            "{}: a comment-only edit changed /AP",
            update.target
        )))
    } else {
        Ok(())
    }
}

fn verify_normal_appearance(
    document: &Document,
    dictionary: &Dictionary,
    fail: &impl Fn(String) -> LyraReaderError,
    id: &str,
) -> Result<()> {
    let stream = dictionary
        .get(b"AP")
        .ok()
        .and_then(|object| object.as_dict().ok())
        .and_then(|ap| ap.get(b"N").ok())
        .and_then(|object| deref(document, object))
        .and_then(|object| object.as_stream().ok());
    match stream {
        Some(stream) if !stream.content.is_empty() => Ok(()),
        _ => Err(fail(format!("{id}: /AP /N is missing or empty"))),
    }
}

fn verify_rect(
    dictionary: &Dictionary,
    expected: Rect,
    fail: &impl Fn(String) -> LyraReaderError,
    id: &str,
) -> Result<()> {
    if !rect_close(source_rect(dictionary), expected) {
        return Err(fail(format!(
            "{id}: /Rect expected {expected:?}, found {:?}",
            source_rect(dictionary)
        )));
    }
    Ok(())
}

fn verify_width(
    dictionary: &Dictionary,
    expected: f64,
    fail: &impl Fn(String) -> LyraReaderError,
    id: &str,
) -> Result<()> {
    if !width_close(source_width(dictionary), expected) {
        return Err(fail(format!(
            "{id}: /BS /W expected {expected}, found {:?}",
            source_width(dictionary)
        )));
    }
    Ok(())
}

fn verify_da(
    dictionary: &Dictionary,
    expected: f64,
    fail: &impl Fn(String) -> LyraReaderError,
    id: &str,
) -> Result<()> {
    let size = dictionary
        .get(b"DA")
        .ok()
        .and_then(|object| object.as_str().ok())
        .and_then(|bytes| {
            let text = String::from_utf8_lossy(bytes);
            let tokens: Vec<&str> = text.split_whitespace().collect();
            let tf = tokens.iter().rposition(|token| *token == "Tf")?;
            tokens.get(tf.checked_sub(1)?)?.parse::<f64>().ok()
        });
    if !size.is_some_and(|size| (size - expected).abs() <= 0.02) {
        return Err(fail(format!(
            "{id}: /DA font size expected {expected}, found {size:?}"
        )));
    }
    Ok(())
}

fn colour_of(object: &Object) -> Option<[u8; 3]> {
    let array = object.as_array().ok()?;
    let mut channels = [0u8; 3];
    for (slot, object) in channels.iter_mut().zip(array) {
        let value = number(object)?;
        *slot = (value.clamp(0.0, 1.0) * 255.0).round() as u8;
    }
    Some(channels)
}

fn verification(message: &str, detail: String) -> LyraReaderError {
    LyraReaderError::new(ErrorCode::Internal, message).with_detail(detail)
}
