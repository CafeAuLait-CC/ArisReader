//! Flattening a copy: paint annotation appearances and form-field values into page content.
//!
//! # What "flatten" means here
//!
//! A flattened copy is a **new PDF**. For every page it draws the current appearance of each
//! annotation into the page's content stream, then removes the annotation objects; it does the
//! same for every AcroForm widget and removes the `/AcroForm` entry. Nothing is rasterised: the
//! appearances are Form XObjects (or, for the quad-based markup kinds, drawing commands
//! synthesised from `/QuadPoints`), so text, vectors and the text layer stay text and vectors.
//!
//! This is an appearance export, not a security feature. Removing an annotation makes it
//! slightly less easy to delete by accident; it does **not** prevent a content editor from
//! changing the painted bytes, and only a digital signature can reveal that the file changed
//! after signing.
//!
//! # What is deliberately kept
//!
//! * `/Link` annotations: they are navigation, not editable content. Flattening a link would
//!   turn a clickable reference into dead pixels.
//! * `/Text` sticky notes: their body is never painted on the page, so flattening one would
//!   silently destroy the only copy of the text. They stay as annotations, and the report says
//!   how many were kept.
//! * Replies (`/IRT`) and an annotation that has replies: a comment thread is not recoverable
//!   once its dictionaries are gone. Keeping the thread is the honest choice; the report counts
//!   the annotations kept for this reason.
//! * Any field whose appearance cannot be baked faithfully (no `/AP`, a push button, an orphan
//!   widget, a kind this build does not understand). The field and its widgets stay, the
//!   AcroForm is kept for them, and the report names the field and the reason.
//! * Signature fields are removed rather than baked: a flattened copy is a derived copy, and
//!   the reader's existing policy strips signature material from every derived copy. The report
//!   counts them.
//!
//! A markup annotation's `/Contents` (a comment attached to a highlight, an ink stroke, …) is
//! metadata rather than page paint. It is not drawn and cannot survive the removal of the
//! annotation; the report counts those comments so the loss is never silent.
//!
//! # Fidelity
//!
//! An annotation's `/AP /N` stream is placed by the algorithm in PDF 32000-1 §12.5.5: the
//! appearance box (BBox transformed by Matrix) is scaled independently in x and y into `/Rect`
//! and translated into place. The form is then drawn with `Do`, so its own `/Resources` (fonts,
//! images, `/SMask`, blend groups) remain intact and its `/Matrix` applies as the viewer would
//! apply it. No appearance stream is copied or rewritten; the page resources gain one named
//! reference to the original object.

use crate::forms::{decode_text_string, document_is_encrypted, load_document, resolve};
use crate::rewrite::verify_flatten_equivalence;
use crate::writeback::{OutputMode, write_rewritten_pdf};
use lopdf::{Dictionary, Document, Object, ObjectId, Stream};
use lyra_reader_core::{ErrorCode, LyraReaderError, Result};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::io::Write;
use std::path::{Path, PathBuf};

/// One kind and how many of it were baked, for the report and the shell's status line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FlattenKindCount {
    pub kind: String,
    pub count: u32,
}

/// One annotation that the flattened copy deliberately keeps.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeptAnnotation {
    pub page: u32,
    pub kind: String,
    pub reason: String,
    pub has_comment: bool,
}

/// One form field that the flattened copy deliberately keeps.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeptField {
    pub name: String,
    pub kind: String,
    pub reason: String,
}

/// What a successful flattened copy did.
#[derive(Clone, Debug, PartialEq)]
pub struct FlattenReport {
    pub destination: PathBuf,
    pub pages: u32,
    pub flattened_annotations: u32,
    pub flattened_annotation_kinds: Vec<FlattenKindCount>,
    pub flattened_fields: u32,
    pub flattened_field_kinds: Vec<FlattenKindCount>,
    pub kept_annotations: Vec<KeptAnnotation>,
    pub kept_fields: Vec<KeptField>,
    pub sticky_notes_kept: u32,
    pub links_kept: u32,
    /// Comments on annotations whose painted appearance was flattened. The paint is in the
    /// page; the comment text is metadata and is not carried over.
    pub comments_not_carried: u32,
    /// Signature fields removed from the derived copy (the existing signature-copy policy).
    pub signature_fields_removed: u32,
    pub output_bytes: u64,
    pub cleaned_temporaries: usize,
}

/// Writes a flattened copy of `source` at `destination`.
///
/// The source is never modified. The output is written into a temporary file beside the
/// destination, reopened and verified, and only then renamed; a failure leaves no partial file.
/// A signed source is allowed: the flattened copy is a derived copy and is stripped of signature
/// material by [`crate::rewrite::strip_signature_from_copy`], exactly like every other derived
/// copy. An XFA form and an encrypted document are refused.
pub fn flatten_to_copy(
    source: &Path,
    destination: &Path,
    password: Option<&str>,
) -> Result<FlattenReport> {
    flatten_to_copy_inner(source, destination, password, false)
}

pub(crate) fn flatten_to_copy_inner(
    source: &Path,
    destination: &Path,
    password: Option<&str>,
    fail_during_build: bool,
) -> Result<FlattenReport> {
    let expected = plan_expected(source, password)?;
    let mut stats: Option<BuildStats> = None;
    let mut failure = None;
    let rewritten = write_rewritten_pdf(
        source,
        destination,
        OutputMode::Copy,
        |file| {
            let built = build_flattened(source, password)?;
            // Write some bytes first when the test asks for a mid-build failure, so the test
            // proves the temporary file is removed rather than merely never created.
            if fail_during_build {
                file.write_all(&built.bytes[..built.bytes.len() / 2])
                    .map_err(|error| {
                        LyraReaderError::new(ErrorCode::Io, "could not write the test bytes")
                            .with_detail(error.to_string())
                    })?;
                file.flush().map_err(|error| {
                    LyraReaderError::new(ErrorCode::Io, "could not flush the test bytes")
                        .with_detail(error.to_string())
                })?;
                failure = Some(LyraReaderError::new(
                    ErrorCode::Internal,
                    "a deliberately interrupted flatten; nothing may be published",
                ));
                return Err(failure.take().expect("failure was just set"));
            }
            file.write_all(&built.bytes).map_err(|error| {
                LyraReaderError::new(ErrorCode::Io, "could not write the flattened copy")
                    .with_detail(error.to_string())
            })?;
            stats = Some(built.stats);
            Ok(())
        },
        |path| verify_flattened(path, source, &expected, password),
    )?;
    let stats = stats.ok_or_else(|| {
        LyraReaderError::new(ErrorCode::Internal, "the flattened copy produced no report")
    })?;
    let mut flattened_annotation_kinds: Vec<FlattenKindCount> = stats
        .annotation_kinds
        .into_iter()
        .map(|(kind, count)| FlattenKindCount { kind, count })
        .collect();
    flattened_annotation_kinds.sort_by(|left, right| {
        right
            .count
            .cmp(&left.count)
            .then_with(|| left.kind.cmp(&right.kind))
    });
    let mut flattened_field_kinds: Vec<FlattenKindCount> = stats
        .field_kinds
        .into_iter()
        .map(|(kind, count)| FlattenKindCount { kind, count })
        .collect();
    flattened_field_kinds.sort_by(|left, right| {
        right
            .count
            .cmp(&left.count)
            .then_with(|| left.kind.cmp(&right.kind))
    });
    Ok(FlattenReport {
        destination: rewritten.destination,
        pages: stats.pages,
        flattened_annotations: stats.flattened_annotations,
        flattened_annotation_kinds,
        flattened_fields: stats.flattened_fields,
        flattened_field_kinds,
        kept_annotations: stats.kept_annotations,
        kept_fields: stats.kept_fields,
        sticky_notes_kept: stats.sticky_notes_kept,
        links_kept: stats.links_kept,
        comments_not_carried: stats.comments_not_carried,
        signature_fields_removed: stats.signature_fields_removed,
        output_bytes: rewritten.output_bytes,
        cleaned_temporaries: rewritten.cleaned_temporaries,
    })
}

/// The name to offer for a flattened copy: `<name> (flattened).pdf`.
pub fn suggested_flatten_copy_path(source: &Path) -> PathBuf {
    crate::forms::suggest(source, "flattened")
}

// ── Planning ────────────────────────────────────────────────────────────────────────────────

#[derive(Default)]
struct BuildStats {
    pages: u32,
    flattened_annotations: u32,
    annotation_kinds: BTreeMap<String, u32>,
    flattened_fields: u32,
    field_kinds: BTreeMap<String, u32>,
    kept_annotations: Vec<KeptAnnotation>,
    kept_fields: Vec<KeptField>,
    sticky_notes_kept: u32,
    links_kept: u32,
    comments_not_carried: u32,
    signature_fields_removed: u32,
}

/// Everything the verifier needs to know about what the plan intends to leave behind.
struct Expected {
    pages: u32,
    remaining: Vec<(u32, String)>,
    kept_fields: Vec<(String, String)>,
    acro_form_expected: bool,
}

fn plan_expected(source: &Path, password: Option<&str>) -> Result<Expected> {
    let document = load_document(source, password)?;
    refuse_unflattenable(&document)?;
    let plan = plan_document(&document)?;
    let mut remaining = Vec::new();
    for page in &plan.pages {
        for entry in &page.entries {
            if entry.remove {
                continue;
            }
            remaining.push((page.number, entry.kind.clone()));
        }
    }
    let kept_fields = collect_kept_fields(&plan.fields);
    let acro_form_expected = !kept_fields.is_empty();
    let pages = u32::try_from(plan.pages.len()).unwrap_or(u32::MAX);
    Ok(Expected {
        pages,
        remaining,
        kept_fields,
        acro_form_expected,
    })
}

fn refuse_unflattenable(document: &Document) -> Result<()> {
    if document_is_encrypted(document) {
        return Err(LyraReaderError::new(
            ErrorCode::Encrypted,
            "This PDF is encrypted, so a flattened copy is not supported: the writer would have \
             to re-encrypt the new content. Open it in a PDF editor that can export a decrypted \
             copy, then flatten that copy.",
        ));
    }
    let has_xfa = document
        .catalog()
        .ok()
        .and_then(|catalog| catalog.get(b"AcroForm").ok())
        .and_then(|object| resolve(document, object))
        .and_then(|object| object.as_dict().ok())
        .is_some_and(|form| form.get(b"XFA").is_ok());
    if has_xfa {
        return Err(LyraReaderError::new(
            ErrorCode::ReadOnly,
            "This PDF is an XFA form. LyraReader renders it read-only from its XML; a flattened \
             copy of the synthetic rendering would not be the form. Filling, annotation, \
             editing and saving edits are unavailable. Reading, zoom, search, selection and \
             summaries still work.",
        ));
    }
    Ok(())
}

struct PagePlan {
    number: u32,
    page_id: ObjectId,
    entries: Vec<EntryPlan>,
}

struct EntryPlan {
    /// The original `/Annots` entry, kept for a surviving annotation.
    raw: Object,
    object_id: Option<ObjectId>,
    kind: String,
    action: AnnotationAction,
    remove: bool,
    has_comment: bool,
    /// Set for an annotation that two passes classify (a popup waits for its parent).
    popup_parent: Option<ObjectId>,
}

enum AnnotationAction {
    Appearance(AppearancePlan),
    Synthesize(SynthPlan),
    Keep(String),
}

struct DocumentPlan {
    pages: Vec<PagePlan>,
    fields: Vec<FieldPlan>,
    /// Annotation objects removed by the plan, including popups and field widgets.
    delete: BTreeSet<ObjectId>,
    draws: Vec<Vec<DrawOp>>,
    /// The annotation plans that were flattened, for the stats.
    flattened: Vec<(u32, String, bool)>,
    kept: Vec<KeptAnnotation>,
    flattened_fields: Vec<(String, String)>,
    signature_fields_removed: u32,
    field_plans_keep: Vec<FieldPlanKept>,
}

struct FieldPlanKept {
    name: String,
    kind: String,
    reason: String,
}

#[derive(Clone)]
enum DrawOp {
    Appearance(AppearancePlan),
    Synthesize(SynthPlan),
}

struct FieldPlan {
    node_id: Option<ObjectId>,
    name: String,
    kind: String,
    action: FieldAction,
    widgets: Vec<WidgetPlan>,
    children: Vec<FieldPlan>,
}

enum FieldAction {
    Flatten,
    Keep(String),
    RemoveSignature,
    Branch,
}

impl FieldPlan {
    fn kept(&self) -> bool {
        match self.action {
            FieldAction::Keep(_) => true,
            FieldAction::Branch => self.children.iter().any(FieldPlan::kept),
            FieldAction::Flatten | FieldAction::RemoveSignature => false,
        }
    }
}

struct WidgetPlan {
    page: usize,
    annot: usize,
    object_id: Option<ObjectId>,
    appearance: Option<AppearancePlan>,
}

#[derive(Clone)]
enum ApSource {
    Reference(ObjectId),
    Inline(Stream),
}

#[derive(Clone)]
struct AppearancePlan {
    source: ApSource,
    rect: [f64; 4],
    bbox: [f64; 4],
    matrix: [f64; 6],
}

#[derive(Clone)]
enum SynthPlan {
    Quad {
        kind: QuadKind,
        quads: Vec<[f64; 8]>,
        color: [f64; 3],
        opacity: f64,
        blend: Option<Vec<u8>>,
    },
    Ink {
        paths: Vec<Vec<(f64, f64)>>,
        width: f64,
        color: [f64; 3],
        opacity: f64,
        blend: Option<Vec<u8>>,
    },
    Line {
        start: (f64, f64),
        end: (f64, f64),
        width: f64,
        color: [f64; 3],
        opacity: f64,
        blend: Option<Vec<u8>>,
        start_arrow: Option<Arrow>,
        end_arrow: Option<Arrow>,
    },
    Box {
        rect: [f64; 4],
        ellipse: bool,
        width: f64,
        color: [f64; 3],
        fill: Option<[f64; 3]>,
        opacity: f64,
        blend: Option<Vec<u8>>,
        dash: Option<Vec<f64>>,
        dash_phase: f64,
    },
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum QuadKind {
    Highlight,
    Underline,
    StrikeOut,
    Squiggly,
}

#[derive(Clone, Copy)]
enum Arrow {
    Closed,
    Open,
}

// ── Plan construction ───────────────────────────────────────────────────────────────────────

fn plan_document(document: &Document) -> Result<DocumentPlan> {
    let pages_map = document.get_pages();
    let page_count = pages_map.len();
    let mut pages: Vec<PagePlan> = Vec::with_capacity(page_count);
    // Widget id -> (page index, annots index), used to attach a field to its page geometry.
    let mut widget_locations: HashMap<ObjectId, (usize, usize)> = HashMap::new();
    let mut parent_of: HashMap<ObjectId, ObjectId> = HashMap::new();

    for (page_index, page_id) in pages_map.values().copied().enumerate() {
        let page_number = u32::try_from(page_index).unwrap_or(u32::MAX);
        let annots = page_annots(document, page_id);
        let mut entries = Vec::new();
        for (annot_index, raw) in annots.iter().enumerate() {
            let (dict, object_id) = match raw {
                Object::Reference(id) => match document.get_object(*id).ok() {
                    Some(Object::Dictionary(dictionary)) => (dictionary.clone(), Some(*id)),
                    _ => (Dictionary::new(), Some(*id)),
                },
                Object::Dictionary(dictionary) => (dictionary.clone(), None),
                _ => (Dictionary::new(), None),
            };
            let kind = name_of(&dict, b"Subtype").unwrap_or_else(|| "Unknown".to_string());
            let has_comment = has_text(&dict, b"Contents");
            let popup_parent = reference_of(&dict, b"Parent").or_else(|| {
                if kind == "Popup" {
                    reference_of(&dict, b"Popup")
                } else {
                    None
                }
            });
            if kind == "Widget"
                && let Some(id) = object_id
            {
                widget_locations.insert(id, (page_index, annot_index));
            }
            if let Some(id) = object_id
                && let Some(parent) = reference_of(&dict, b"Parent")
            {
                parent_of.insert(id, parent);
            }
            entries.push(EntryPlan {
                raw: raw.clone(),
                object_id,
                kind,
                action: AnnotationAction::Keep(String::new()),
                remove: false,
                has_comment,
                popup_parent,
            });
        }
        pages.push(PagePlan {
            number: page_number,
            page_id,
            entries,
        });
    }

    // Fields first: their widgets are annotations, and a field's action decides whether a
    // widget survives. The plan is also what tells the annotation pass which widgets to skip.
    let mut handled_widgets: HashSet<ObjectId> = HashSet::new();
    let fields = match acro_form(document) {
        Some(form) => {
            let roots = form
                .get(b"Fields")
                .ok()
                .and_then(|object| resolve(document, object))
                .and_then(|object| object.as_array().ok())
                .cloned()
                .unwrap_or_default();
            let mut plans = Vec::new();
            for root in &roots {
                if let Some(plan) = plan_field(
                    document,
                    root,
                    None,
                    None,
                    "",
                    0,
                    &widget_locations,
                    &mut handled_widgets,
                )? {
                    plans.push(plan);
                }
            }
            plans
        }
        None => Vec::new(),
    };

    let mut plan = DocumentPlan {
        pages,
        fields,
        delete: BTreeSet::new(),
        draws: vec![Vec::new(); page_count],
        flattened: Vec::new(),
        kept: Vec::new(),
        flattened_fields: Vec::new(),
        signature_fields_removed: 0,
        field_plans_keep: Vec::new(),
    };

    // Replies are kept: a comment thread whose parent disappears would point at a deleted
    // object, and the thread text exists nowhere else. A parent that has replies is kept too.
    let mut reply_parents: HashSet<ObjectId> = HashSet::new();
    for page in &plan.pages {
        for entry in &page.entries {
            if let Some(dict) = entry_dictionary(document, entry)
                && let Some(parent) = reference_of(dict, b"IRT")
            {
                reply_parents.insert(parent);
            }
        }
    }

    // Classify everything except popups, whose fate depends on the parent.
    for page_index in 0..plan.pages.len() {
        for annot_index in 0..plan.pages[page_index].entries.len() {
            let (kind, object_id, has_irt) = {
                let entry = &plan.pages[page_index].entries[annot_index];
                let dict = entry_dictionary(document, entry);
                (
                    entry.kind.clone(),
                    entry.object_id,
                    dict.and_then(|dict| reference_of(dict, b"IRT")).is_some(),
                )
            };
            if kind == "Widget" {
                // A widget that belongs to a field is handled with it; an orphan widget is
                // treated like any other annotation with an appearance.
                if object_id.is_some_and(|id| handled_widgets.contains(&id)) {
                    continue;
                }
            }
            if kind == "Popup" {
                continue;
            }
            let dict =
                match entry_dictionary(document, &plan.pages[page_index].entries[annot_index]) {
                    Some(dict) => dict.clone(),
                    None => {
                        plan.pages[page_index].entries[annot_index].action = AnnotationAction::Keep(
                            "the annotation dictionary could not be read".to_string(),
                        );
                        continue;
                    }
                };
            let keep_because_thread =
                has_irt || object_id.is_some_and(|id| reply_parents.contains(&id));
            let action = if annotation_is_hidden(&dict) {
                AnnotationAction::Keep(
                    "the annotation is hidden (or has NoView), so painting it would make it \
                     visible"
                        .to_string(),
                )
            } else if kind == "Link" {
                AnnotationAction::Keep(
                    "a link is navigation, not editable page content".to_string(),
                )
            } else if kind == "Text" {
                AnnotationAction::Keep(
                    "a sticky note's text is only visible in its note window".to_string(),
                )
            } else if keep_because_thread {
                AnnotationAction::Keep(
                    "it is part of a reply thread; flattening it would lose the thread".to_string(),
                )
            } else if kind == "Widget" {
                match plan_annotation_appearance(document, &dict) {
                    Ok(appearance) => AnnotationAction::Appearance(appearance),
                    Err(reason) => AnnotationAction::Keep(reason),
                }
            } else if is_known_visual(&kind) {
                match plan_annotation_appearance(document, &dict) {
                    Ok(appearance) => AnnotationAction::Appearance(appearance),
                    Err(_) => match plan_synth(document, &dict, &kind) {
                        Ok(synth) => AnnotationAction::Synthesize(synth),
                        Err(reason) => AnnotationAction::Keep(reason),
                    },
                }
            } else {
                AnnotationAction::Keep(format!(
                    "the {kind} annotation kind is not flattened by this build"
                ))
            };
            plan.pages[page_index].entries[annot_index].action = action;
        }
    }

    // Popups: keep one only with a surviving parent, or when it carries text of its own.
    let mut index_of: HashMap<ObjectId, (usize, usize)> = HashMap::new();
    for (page_index, page) in plan.pages.iter().enumerate() {
        for (annot_index, entry) in page.entries.iter().enumerate() {
            if let Some(id) = entry.object_id {
                index_of.insert(id, (page_index, annot_index));
            }
        }
    }
    for page_index in 0..plan.pages.len() {
        for annot_index in 0..plan.pages[page_index].entries.len() {
            if plan.pages[page_index].entries[annot_index].kind != "Popup" {
                continue;
            }
            let parent = plan.pages[page_index].entries[annot_index].popup_parent;
            let parent_kept = parent
                .and_then(|id| index_of.get(&id).copied())
                .map(|(page, annot)| {
                    matches!(
                        plan.pages[page].entries[annot].action,
                        AnnotationAction::Keep(_)
                    )
                })
                .unwrap_or(true);
            let has_text = plan.pages[page_index].entries[annot_index].has_comment;
            let action = if parent_kept || has_text {
                AnnotationAction::Keep(if has_text {
                    "the popup carries its own text".to_string()
                } else {
                    "the popup belongs to a sticky note that is kept".to_string()
                })
            } else {
                AnnotationAction::Keep(String::new())
            };
            if !parent_kept && !has_text {
                plan.pages[page_index].entries[annot_index].remove = true;
                if let Some(id) = plan.pages[page_index].entries[annot_index].object_id {
                    plan.delete.insert(id);
                }
            }
            plan.pages[page_index].entries[annot_index].action = action;
        }
    }

    // Turn the classified actions into draw operations and kept/removed bookkeeping.
    for page_index in 0..plan.pages.len() {
        for annot_index in 0..plan.pages[page_index].entries.len() {
            if plan.pages[page_index].entries[annot_index].remove {
                continue;
            }
            let entry = &plan.pages[page_index].entries[annot_index];
            match &entry.action {
                AnnotationAction::Appearance(appearance) => {
                    plan.draws[page_index].push(DrawOp::Appearance(appearance.clone()));
                    plan.flattened.push((
                        plan.pages[page_index].number,
                        entry.kind.clone(),
                        entry.has_comment,
                    ));
                    if let Some(id) = entry.object_id {
                        plan.delete.insert(id);
                    }
                    if let Some(popup) = entry_dictionary(document, entry)
                        .and_then(|dict| reference_of(dict, b"Popup"))
                    {
                        plan.delete.insert(popup);
                        if let Some((page, annot)) = index_of.get(&popup).copied() {
                            plan.pages[page].entries[annot].remove = true;
                            plan.pages[page].entries[annot].action =
                                AnnotationAction::Keep(String::new());
                        }
                    }
                    plan.pages[page_index].entries[annot_index].remove = true;
                }
                AnnotationAction::Synthesize(synth) => {
                    plan.draws[page_index].push(DrawOp::Synthesize(synth.clone()));
                    plan.flattened.push((
                        plan.pages[page_index].number,
                        entry.kind.clone(),
                        entry.has_comment,
                    ));
                    if let Some(id) = entry.object_id {
                        plan.delete.insert(id);
                    }
                    plan.pages[page_index].entries[annot_index].remove = true;
                }
                AnnotationAction::Keep(reason) => {
                    if reason.is_empty() {
                        // A popup removed by the pass above, already marked.
                        continue;
                    }
                    let page_number = plan.pages[page_index].number;
                    plan.kept.push(KeptAnnotation {
                        page: page_number,
                        kind: entry.kind.clone(),
                        reason: reason.clone(),
                        has_comment: entry.has_comment,
                    });
                }
            }
        }
    }

    // Fields: flatten what can be flattened, keep what cannot, remove signature fields.
    let mut field_keep = Vec::new();
    let mut flattened_fields = Vec::new();
    let mut signature_fields_removed = 0;
    apply_field_plans(
        &plan.fields,
        &mut plan.draws,
        &mut plan.pages,
        &mut plan.delete,
        &mut flattened_fields,
        &mut field_keep,
        &mut signature_fields_removed,
    )?;
    plan.flattened_fields = flattened_fields;
    plan.field_plans_keep = field_keep;
    plan.signature_fields_removed = signature_fields_removed;
    Ok(plan)
}

fn entry_dictionary<'a>(document: &'a Document, entry: &'a EntryPlan) -> Option<&'a Dictionary> {
    match &entry.raw {
        Object::Dictionary(dictionary) => Some(dictionary),
        Object::Reference(id) => document
            .get_object(*id)
            .ok()
            .and_then(|object| object.as_dict().ok()),
        _ => None,
    }
}

fn apply_field_plans(
    plans: &[FieldPlan],
    draws: &mut [Vec<DrawOp>],
    pages: &mut [PagePlan],
    delete: &mut BTreeSet<ObjectId>,
    flattened_fields: &mut Vec<(String, String)>,
    kept_fields: &mut Vec<FieldPlanKept>,
    signature_fields_removed: &mut u32,
) -> Result<()> {
    for plan in plans {
        if let Some(id) = plan.node_id
            && matches!(
                plan.action,
                FieldAction::Flatten | FieldAction::RemoveSignature
            )
        {
            delete.insert(id);
        }
        match &plan.action {
            FieldAction::Flatten => {
                for widget in &plan.widgets {
                    if let Some(appearance) = &widget.appearance {
                        draws[widget.page].push(DrawOp::Appearance(appearance.clone()));
                    }
                    pages[widget.page].entries[widget.annot].remove = true;
                    pages[widget.page].entries[widget.annot].action =
                        AnnotationAction::Keep(String::new());
                    if let Some(id) = widget.object_id {
                        delete.insert(id);
                    }
                }
                flattened_fields.push((plan.name.clone(), plan.kind.clone()));
            }
            FieldAction::RemoveSignature => {
                for widget in &plan.widgets {
                    pages[widget.page].entries[widget.annot].remove = true;
                    pages[widget.page].entries[widget.annot].action =
                        AnnotationAction::Keep(String::new());
                    if let Some(id) = widget.object_id {
                        delete.insert(id);
                    }
                }
                *signature_fields_removed += 1;
            }
            FieldAction::Keep(reason) => {
                kept_fields.push(FieldPlanKept {
                    name: plan.name.clone(),
                    kind: plan.kind.clone(),
                    reason: reason.clone(),
                });
            }
            FieldAction::Branch => {
                apply_field_plans(
                    &plan.children,
                    draws,
                    pages,
                    delete,
                    flattened_fields,
                    kept_fields,
                    signature_fields_removed,
                )?;
            }
        }
    }
    Ok(())
}

fn collect_kept_fields(plans: &[FieldPlan]) -> Vec<(String, String)> {
    let mut kept = Vec::new();
    fn walk(plan: &FieldPlan, kept: &mut Vec<(String, String)>) {
        match plan.action {
            FieldAction::Keep(_) => kept.push((plan.name.clone(), plan.kind.clone())),
            FieldAction::Branch => {
                for child in &plan.children {
                    walk(child, kept);
                }
            }
            FieldAction::Flatten | FieldAction::RemoveSignature => {}
        }
    }
    for plan in plans {
        walk(plan, &mut kept);
    }
    kept.sort();
    kept
}

#[allow(clippy::too_many_arguments)]
fn plan_field(
    document: &Document,
    object: &Object,
    inherited_ft: Option<&[u8]>,
    inherited_ff: Option<i64>,
    parent_name: &str,
    depth: usize,
    widget_locations: &HashMap<ObjectId, (usize, usize)>,
    handled_widgets: &mut HashSet<ObjectId>,
) -> Result<Option<FieldPlan>> {
    if depth > 64 {
        return Err(LyraReaderError::new(
            ErrorCode::CorruptDocument,
            "the form field tree is cyclic or too deep; nothing was written",
        ));
    }
    let (dictionary, node_id) = match object {
        Object::Reference(id) => match document.get_object(*id).ok() {
            Some(Object::Dictionary(dictionary)) => (dictionary.clone(), Some(*id)),
            _ => return Ok(None),
        },
        Object::Dictionary(dictionary) => (dictionary.clone(), None),
        _ => return Ok(None),
    };
    let ft = name_bytes(&dictionary, b"FT").or_else(|| inherited_ft.map(<[u8]>::to_vec));
    let ff = integer_of(&dictionary, b"Ff").or(inherited_ff);
    let own_name = text_of(&dictionary, b"T");
    let name = match (&own_name, parent_name.is_empty()) {
        (Some(own), true) => own.clone(),
        (Some(own), false) => format!("{parent_name}.{own}"),
        (None, _) => parent_name.to_string(),
    };
    let (kind_code, kind_name) = field_kind(ft.as_deref(), ff);
    let kids = dictionary
        .get(b"Kids")
        .ok()
        .and_then(|object| resolve(document, object))
        .and_then(|object| object.as_array().ok())
        .cloned()
        .unwrap_or_default();
    let kids_are_widgets = !kids.is_empty()
        && kids.iter().all(|kid| {
            resolve(document, kid)
                .and_then(|object| object.as_dict().ok())
                .is_some_and(|dict| name_of(dict, b"Subtype").as_deref() == Some("Widget"))
        });

    if !kids.is_empty() && !kids_are_widgets {
        // A non-terminal field: recurse into the child fields. A widget listed beside a child
        // field is unusual; it is kept as an orphan by the annotation pass rather than baked
        // into an ambiguous place.
        let mut children = Vec::new();
        for kid in &kids {
            if let Some(plan) = plan_field(
                document,
                kid,
                ft.as_deref(),
                ff,
                &name,
                depth + 1,
                widget_locations,
                handled_widgets,
            )? {
                children.push(plan);
            }
        }
        let action = if ft.is_some() && kind_code.is_some() && children.is_empty() {
            FieldAction::Keep("the field has no widget on a page".to_string())
        } else {
            FieldAction::Branch
        };
        return Ok(Some(FieldPlan {
            node_id,
            name,
            kind: kind_name,
            action,
            widgets: Vec::new(),
            children,
        }));
    }

    // Terminal field: the widgets are either the kids or the field object itself.
    let widget_objects: Vec<(Object, Option<ObjectId>)> = if kids_are_widgets {
        kids.iter()
            .map(|kid| {
                (
                    kid.clone(),
                    match kid {
                        Object::Reference(id) => Some(*id),
                        _ => None,
                    },
                )
            })
            .collect()
    } else if let Object::Reference(id) = object {
        if name_of(&dictionary, b"Subtype").as_deref() == Some("Widget") {
            vec![(object.clone(), Some(*id))]
        } else {
            Vec::new()
        }
    } else {
        Vec::new()
    };

    for (_, id) in &widget_objects {
        if let Some(id) = id {
            handled_widgets.insert(*id);
        }
    }

    let mut widgets = Vec::new();
    let mut reason: Option<String> = None;
    for (widget_object, widget_id) in &widget_objects {
        let Some(widget_id) = widget_id else {
            reason = Some("the field has an inline widget that cannot be located".to_string());
            break;
        };
        let Some(&(page, annot)) = widget_locations.get(widget_id) else {
            reason = Some("the field's widget is not attached to a page".to_string());
            break;
        };
        let widget_dict = resolve(document, widget_object).and_then(|object| object.as_dict().ok());
        let Some(widget_dict) = widget_dict else {
            reason = Some("the field's widget dictionary could not be read".to_string());
            break;
        };
        let appearance = if matches!(kind_code, Some(FormKind::Signature | FormKind::PushButton)) {
            None
        } else {
            match plan_widget_appearance(document, widget_dict) {
                Ok(appearance) => Some(appearance),
                Err(error) => {
                    reason = Some(error);
                    break;
                }
            }
        };
        widgets.push(WidgetPlan {
            page,
            annot,
            object_id: Some(*widget_id),
            appearance,
        });
    }

    let action = if kind_code == Some(FormKind::Signature) {
        FieldAction::RemoveSignature
    } else if kind_code == Some(FormKind::PushButton) {
        FieldAction::Keep("a push button runs an action rather than showing a value".to_string())
    } else if widget_objects.is_empty() {
        FieldAction::Keep("the field has no widget on a page".to_string())
    } else if let Some(reason) = reason {
        FieldAction::Keep(reason)
    } else {
        FieldAction::Flatten
    };
    Ok(Some(FieldPlan {
        node_id,
        name,
        kind: kind_name,
        action,
        widgets,
        children: Vec::new(),
    }))
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum FormKind {
    Text,
    CheckBox,
    Radio,
    ComboBox,
    ListBox,
    Signature,
    PushButton,
    Other,
}

fn field_kind(ft: Option<&[u8]>, ff: Option<i64>) -> (Option<FormKind>, String) {
    match ft {
        Some(b"Tx") => (Some(FormKind::Text), "text".to_string()),
        Some(b"Ch") => {
            let combo = ff.is_some_and(|flags| flags & (1 << 17) != 0);
            (
                Some(if combo {
                    FormKind::ComboBox
                } else {
                    FormKind::ListBox
                }),
                if combo { "comboBox" } else { "listBox" }.to_string(),
            )
        }
        Some(b"Btn") => {
            let flags = ff.unwrap_or(0);
            if flags & (1 << 15) != 0 {
                (Some(FormKind::Radio), "radio".to_string())
            } else if flags & (1 << 16) != 0 {
                (Some(FormKind::PushButton), "pushButton".to_string())
            } else {
                (Some(FormKind::CheckBox), "checkBox".to_string())
            }
        }
        Some(b"Sig") => (Some(FormKind::Signature), "signature".to_string()),
        Some(_) => (Some(FormKind::Other), "unknown".to_string()),
        None => (None, "unknown".to_string()),
    }
}

fn plan_widget_appearance(
    document: &Document,
    widget: &Dictionary,
) -> std::result::Result<AppearancePlan, String> {
    appearance_plan(document, widget).map_err(|reason| format!("the widget {reason}"))
}

fn plan_annotation_appearance(
    document: &Document,
    annotation: &Dictionary,
) -> std::result::Result<AppearancePlan, String> {
    appearance_plan(document, annotation).map_err(|reason| format!("the annotation {reason}"))
}

fn appearance_plan(
    document: &Document,
    owner: &Dictionary,
) -> std::result::Result<AppearancePlan, String> {
    let rect = rect_of(document, owner)
        .ok_or_else(|| "has no usable /Rect, so its appearance cannot be placed".to_string())?;
    let ap = owner
        .get(b"AP")
        .ok()
        .and_then(|object| resolve(document, object))
        .and_then(|object| object.as_dict().ok())
        .ok_or_else(|| "has no /AP appearance".to_string())?;
    let normal = ap
        .get(b"N")
        .ok()
        .and_then(|object| resolve(document, object))
        .ok_or_else(|| "has no /AP /N appearance".to_string())?;
    let source = normal_appearance_source(document, owner, normal)
        .ok_or_else(|| "has an /AP /N that is not a drawable form appearance".to_string())?;
    let stream = match &source {
        ApSource::Reference(id) => document
            .get_object(*id)
            .ok()
            .and_then(|object| object.as_stream().ok()),
        ApSource::Inline(stream) => Some(stream),
    }
    .ok_or_else(|| "has an /AP /N that is not a stream".to_string())?;
    if let Some(subtype) = stream.dict.get(b"Subtype").ok()
        && subtype.as_name().ok() != Some(b"Form")
    {
        return Err("has an /AP /N that is not a Form XObject".to_string());
    }
    let bbox = stream_rect(&stream.dict, b"BBox")
        .ok_or_else(|| "has an /AP /N with no usable /BBox".to_string())?;
    let matrix = stream_matrix(&stream.dict);
    Ok(AppearancePlan {
        source,
        rect,
        bbox,
        matrix,
    })
}

fn normal_appearance_source(
    document: &Document,
    owner: &Dictionary,
    normal: &Object,
) -> Option<ApSource> {
    match normal {
        Object::Stream(_) => stream_source(document, normal),
        Object::Reference(id) => match document.get_object(*id).ok() {
            Some(Object::Stream(_)) => stream_source(document, normal),
            Some(Object::Dictionary(states)) => {
                let selected = selected_state(owner, states)?;
                stream_source(document, selected)
            }
            _ => None,
        },
        Object::Dictionary(states) => {
            let selected = selected_state(owner, states)?;
            stream_source(document, selected)
        }
        _ => None,
    }
}

/// The appearance state to draw: `/AS` when it names one, otherwise the only state, otherwise
/// `/Off` (the unchecked/off appearance). A radio or check box always has `/AS`.
fn selected_state<'a>(owner: &Dictionary, states: &'a Dictionary) -> Option<&'a Object> {
    let state = name_of(owner, b"AS")
        .or_else(|| name_of(owner, b"V"))
        .or_else(|| {
            if states.len() == 1 {
                states
                    .iter()
                    .next()
                    .map(|(key, _)| String::from_utf8_lossy(key).into_owned())
            } else {
                None
            }
        })?;
    if let Ok(object) = states.get(state.as_bytes()) {
        return Some(object);
    }
    states.get(b"Off").ok()
}

fn stream_source(document: &Document, object: &Object) -> Option<ApSource> {
    match object {
        Object::Reference(id) => match document.get_object(*id).ok()? {
            Object::Stream(_) => Some(ApSource::Reference(*id)),
            _ => None,
        },
        Object::Stream(stream) => Some(ApSource::Inline(stream.clone())),
        _ => None,
    }
}

fn stream_rect(dictionary: &Dictionary, key: &[u8]) -> Option<[f64; 4]> {
    let values = dictionary.get(key).ok()?.as_array().ok()?;
    if values.len() != 4 {
        return None;
    }
    let mut numbers = [0.0f64; 4];
    for (index, value) in values.iter().enumerate() {
        numbers[index] = match value {
            Object::Integer(value) => *value as f64,
            Object::Real(value) => *value as f64,
            _ => return None,
        };
    }
    Some([
        numbers[0].min(numbers[2]),
        numbers[1].min(numbers[3]),
        numbers[0].max(numbers[2]),
        numbers[1].max(numbers[3]),
    ])
}

fn stream_matrix(dictionary: &Dictionary) -> [f64; 6] {
    let Some(values) = dictionary
        .get(b"Matrix")
        .ok()
        .and_then(|object| object.as_array().ok())
    else {
        return [1.0, 0.0, 0.0, 1.0, 0.0, 0.0];
    };
    if values.len() != 6 {
        return [1.0, 0.0, 0.0, 1.0, 0.0, 0.0];
    }
    let mut matrix = [0.0f64; 6];
    for (index, value) in values.iter().enumerate() {
        matrix[index] = match value {
            Object::Integer(value) => *value as f64,
            Object::Real(value) => *value as f64,
            _ => return [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
        };
    }
    matrix
}

// ── Small dictionary readers ───────────────────────────────────────────────────────────────

fn page_annots(document: &Document, page_id: ObjectId) -> Vec<Object> {
    document
        .get_dictionary(page_id)
        .ok()
        .and_then(|page| page.get(b"Annots").ok())
        .and_then(|object| resolve(document, object))
        .and_then(|object| object.as_array().ok())
        .cloned()
        .unwrap_or_default()
}

fn acro_form(document: &Document) -> Option<&Dictionary> {
    document
        .catalog()
        .ok()
        .and_then(|catalog| catalog.get(b"AcroForm").ok())
        .and_then(|object| resolve(document, object))
        .and_then(|object| object.as_dict().ok())
}

fn name_of(dictionary: &Dictionary, key: &[u8]) -> Option<String> {
    dictionary
        .get(key)
        .ok()
        .and_then(|object| object.as_name().ok())
        .map(|bytes| String::from_utf8_lossy(bytes).into_owned())
}

fn name_bytes(dictionary: &Dictionary, key: &[u8]) -> Option<Vec<u8>> {
    dictionary
        .get(key)
        .ok()
        .and_then(|object| object.as_name().ok())
        .map(<[u8]>::to_vec)
}

fn integer_of(dictionary: &Dictionary, key: &[u8]) -> Option<i64> {
    dictionary
        .get(key)
        .ok()
        .and_then(|object| object.as_i64().ok())
}

fn text_of(dictionary: &Dictionary, key: &[u8]) -> Option<String> {
    dictionary
        .get(key)
        .ok()
        .and_then(|object| object.as_str().ok())
        .map(decode_text_string)
}

fn has_text(dictionary: &Dictionary, key: &[u8]) -> bool {
    text_of(dictionary, key).is_some_and(|text| !text.trim().is_empty())
}

fn reference_of(dictionary: &Dictionary, key: &[u8]) -> Option<ObjectId> {
    dictionary
        .get(key)
        .ok()
        .and_then(|object| object.as_reference().ok())
}

fn number_of(dictionary: &Dictionary, key: &[u8]) -> Option<f64> {
    match dictionary.get(key).ok()? {
        Object::Integer(value) => Some(*value as f64),
        Object::Real(value) => Some(*value as f64),
        _ => None,
    }
}

fn numbers_of(dictionary: &Dictionary, key: &[u8]) -> Option<Vec<f64>> {
    dictionary
        .get(key)
        .ok()
        .and_then(|object| object.as_array().ok())
        .map(|array| {
            array
                .iter()
                .filter_map(|object| match object {
                    Object::Integer(value) => Some(*value as f64),
                    Object::Real(value) => Some(*value as f64),
                    _ => None,
                })
                .collect()
        })
}

fn rect_of(document: &Document, dictionary: &Dictionary) -> Option<[f64; 4]> {
    let values = dictionary
        .get(b"Rect")
        .ok()
        .and_then(|object| resolve(document, object))
        .and_then(|object| object.as_array().ok())?;
    let mut numbers = Vec::with_capacity(4);
    for value in values {
        numbers.push(match value {
            Object::Integer(value) => *value as f64,
            Object::Real(value) => *value as f64,
            _ => return None,
        });
    }
    if numbers.len() != 4 {
        return None;
    }
    let rect = [
        numbers[0].min(numbers[2]),
        numbers[1].min(numbers[3]),
        numbers[0].max(numbers[2]),
        numbers[1].max(numbers[3]),
    ];
    (rect[2] - rect[0] > 0.0 && rect[3] - rect[1] > 0.0).then_some(rect)
}

fn color_of(dictionary: &Dictionary, key: &[u8], fallback: [f64; 3]) -> [f64; 3] {
    let Some(values) = numbers_of(dictionary, key) else {
        return fallback;
    };
    if values.len() < 3 {
        return fallback;
    }
    let scale = if values.iter().any(|value| *value > 1.0) {
        255.0
    } else {
        1.0
    };
    [
        (values[0] / scale).clamp(0.0, 1.0),
        (values[1] / scale).clamp(0.0, 1.0),
        (values[2] / scale).clamp(0.0, 1.0),
    ]
}

fn opacity_of(dictionary: &Dictionary) -> f64 {
    number_of(dictionary, b"CA")
        .or_else(|| {
            dictionary
                .get(b"CA")
                .ok()
                .and_then(|object| object.as_i64().ok())
                .map(|value| value as f64)
        })
        .unwrap_or(1.0)
        .clamp(0.0, 1.0)
}

fn blend_of(dictionary: &Dictionary) -> Option<Vec<u8>> {
    name_bytes(dictionary, b"BM")
}

fn border_width_of(dictionary: &Dictionary) -> f64 {
    let width = dictionary
        .get(b"BS")
        .ok()
        .and_then(|object| object.as_dict().ok())
        .and_then(|bs| number_of(bs, b"W"))
        .or_else(|| numbers_of(dictionary, b"Border").and_then(|values| values.first().copied()))
        .unwrap_or(1.0);
    width.clamp(0.1, 100.0)
}

fn dash_of(dictionary: &Dictionary) -> (Option<Vec<f64>>, f64) {
    let bs = dictionary
        .get(b"BS")
        .ok()
        .and_then(|object| object.as_dict().ok());
    let Some(bs) = bs else {
        return (None, 0.0);
    };
    let style = name_of(bs, b"S").unwrap_or_else(|| "S".to_string());
    if style != "D" {
        return (None, 0.0);
    }
    let Some(values) = numbers_of(bs, b"D") else {
        return (None, 0.0);
    };
    if values.is_empty() {
        return (None, 0.0);
    }
    // A border-style dash array is `[dash gap …]`; the phase is a separate number when a
    // producer writes one. The fixtures use the common two-number pattern with phase 0.
    let (phase, pattern) = if values.len() > 2 && values.len() % 2 == 1 {
        (
            values[values.len() - 1],
            values[..values.len() - 1].to_vec(),
        )
    } else {
        (0.0, values)
    };
    if pattern.iter().all(|value| *value <= 0.0) {
        (None, phase)
    } else {
        (Some(pattern), phase)
    }
}

/// `/F` bits 1 (Invisible), 2 (Hidden) and 32 (NoView) mean the mark is not displayed in at
/// least one viewing context. Flattening one would turn it into visible page paint.
fn annotation_is_hidden(dictionary: &Dictionary) -> bool {
    integer_of(dictionary, b"F").is_some_and(|flags| flags & (1 | 2 | 32) != 0)
}

fn is_known_visual(kind: &str) -> bool {
    matches!(
        kind,
        "Highlight"
            | "Underline"
            | "StrikeOut"
            | "Squiggly"
            | "Ink"
            | "Square"
            | "Circle"
            | "Line"
            | "FreeText"
            | "Stamp"
    )
}

fn plan_synth(
    _document: &Document,
    annotation: &Dictionary,
    kind: &str,
) -> std::result::Result<SynthPlan, String> {
    let mut blend = blend_of(annotation);
    let opacity = opacity_of(annotation);
    let color = color_of(annotation, b"C", [0.0, 0.0, 0.0]);
    match kind {
        "Highlight" | "Underline" | "StrikeOut" | "Squiggly" => {
            let rect = rect_of(_document, annotation).ok_or_else(|| {
                "the markup annotation has no /Rect, so it has no quad geometry".to_string()
            })?;
            let quads = quad_points(_document, annotation).unwrap_or_else(|| {
                vec![[
                    rect[0], rect[1], rect[2], rect[1], rect[2], rect[3], rect[0], rect[3],
                ]]
            });
            if kind == "Highlight" && blend.is_none() {
                // PDF 32000-1 table 179: a highlight's default blend mode is Multiply. Keeping
                // that default is what makes a baked highlight tint the glyphs instead of
                // painting over them.
                blend = Some(b"Multiply".to_vec());
            }
            let kind = match kind {
                "Highlight" => QuadKind::Highlight,
                "Underline" => QuadKind::Underline,
                "StrikeOut" => QuadKind::StrikeOut,
                _ => QuadKind::Squiggly,
            };
            Ok(SynthPlan::Quad {
                kind,
                quads,
                color,
                opacity,
                blend,
            })
        }
        "Ink" => {
            let paths = ink_paths(_document, annotation)
                .ok_or_else(|| "the ink annotation has no usable /InkList".to_string())?;
            Ok(SynthPlan::Ink {
                paths,
                width: border_width_of(annotation),
                color,
                opacity,
                blend,
            })
        }
        "Line" => {
            let values = numbers_of(annotation, b"L")
                .ok_or_else(|| "the line annotation has no /L".to_string())?;
            if values.len() < 4 {
                return Err("the line annotation's /L is incomplete".to_string());
            }
            let endings = line_endings(annotation);
            Ok(SynthPlan::Line {
                start: (values[0], values[1]),
                end: (values[2], values[3]),
                width: border_width_of(annotation),
                color,
                opacity,
                blend,
                start_arrow: endings.0,
                end_arrow: endings.1,
            })
        }
        "Square" | "Circle" => {
            let rect = rect_of(_document, annotation)
                .ok_or_else(|| "the shape annotation has no /Rect to draw".to_string())?;
            let (dash, dash_phase) = dash_of(annotation);
            Ok(SynthPlan::Box {
                rect,
                ellipse: kind == "Circle",
                width: border_width_of(annotation),
                color,
                fill: numbers_of(annotation, b"IC").map(|_| color_of(annotation, b"IC", color)),
                opacity,
                blend,
                dash,
                dash_phase,
            })
        }
        "FreeText" | "Stamp" => Err(format!(
            "the {kind} annotation has no /AP appearance to bake; its text cannot be laid out \
             faithfully"
        )),
        other => Err(format!(
            "the {other} annotation kind is not flattened by this build"
        )),
    }
}

fn quad_points(document: &Document, annotation: &Dictionary) -> Option<Vec<[f64; 8]>> {
    let values = annotation
        .get(b"QuadPoints")
        .ok()
        .and_then(|object| resolve(document, object))
        .and_then(|object| object.as_array().ok())?;
    let numbers: Vec<f64> = values
        .iter()
        .filter_map(|value| match value {
            Object::Integer(value) => Some(*value as f64),
            Object::Real(value) => Some(*value as f64),
            _ => None,
        })
        .collect();
    if numbers.len() < 8 || !numbers.len().is_multiple_of(8) {
        return None;
    }
    let (quads, _) = numbers.as_chunks::<8>();
    Some(quads.to_vec())
}

fn ink_paths(document: &Document, annotation: &Dictionary) -> Option<Vec<Vec<(f64, f64)>>> {
    let list = annotation
        .get(b"InkList")
        .ok()
        .and_then(|object| resolve(document, object))
        .and_then(|object| object.as_array().ok())?;
    let mut paths = Vec::new();
    for path in list {
        let numbers = match path {
            Object::Array(values) => values
                .iter()
                .filter_map(|value| match value {
                    Object::Integer(value) => Some(*value as f64),
                    Object::Real(value) => Some(*value as f64),
                    _ => None,
                })
                .collect::<Vec<_>>(),
            _ => continue,
        };
        if numbers.len() < 4 || numbers.len() % 2 != 0 {
            continue;
        }
        let (pairs, _) = numbers.as_chunks::<2>();
        paths.push(pairs.iter().map(|pair| (pair[0], pair[1])).collect());
    }
    (!paths.is_empty()).then_some(paths)
}

fn line_endings(annotation: &Dictionary) -> (Option<Arrow>, Option<Arrow>) {
    let Some(names) = annotation
        .get(b"LE")
        .ok()
        .and_then(|object| object.as_array().ok())
    else {
        return (None, None);
    };
    let arrow = |index: usize| -> Option<Arrow> {
        let name = names.get(index)?.as_name().ok()?;
        match name {
            b"ClosedArrow" | b"RClosedArrow" => Some(Arrow::Closed),
            b"OpenArrow" | b"ROpenArrow" => Some(Arrow::Open),
            _ => None,
        }
    };
    (arrow(0), arrow(1))
}

// ── Build ──────────────────────────────────────────────────────────────────────────────────

struct Built {
    bytes: Vec<u8>,
    stats: BuildStats,
}

fn build_flattened(source: &Path, password: Option<&str>) -> Result<Built> {
    let mut document = load_document(source, password)?;
    refuse_unflattenable(&document)?;
    let plan = plan_document(&document)?;
    let pages = u32::try_from(plan.pages.len()).unwrap_or(u32::MAX);
    let mut stats = BuildStats {
        pages,
        flattened_annotations: 0,
        annotation_kinds: BTreeMap::new(),
        flattened_fields: 0,
        field_kinds: BTreeMap::new(),
        kept_annotations: Vec::new(),
        kept_fields: Vec::new(),
        sticky_notes_kept: 0,
        links_kept: 0,
        comments_not_carried: 0,
        signature_fields_removed: plan.signature_fields_removed,
    };
    for (_, kind, has_comment) in &plan.flattened {
        stats.flattened_annotations += 1;
        *stats.annotation_kinds.entry(kind.clone()).or_insert(0) += 1;
        if *has_comment && !matches!(kind.as_str(), "FreeText" | "Stamp") {
            stats.comments_not_carried += 1;
        }
    }
    for (_, kind) in &plan.flattened_fields {
        stats.flattened_fields += 1;
        *stats.field_kinds.entry(kind.clone()).or_insert(0) += 1;
    }
    for kept in &plan.kept {
        if kept.kind == "Link" {
            stats.links_kept += 1;
        }
        if kept.kind == "Text" {
            stats.sticky_notes_kept += 1;
        }
        stats.kept_annotations.push(KeptAnnotation {
            page: kept.page,
            kind: kept.kind.clone(),
            reason: kept.reason.clone(),
            has_comment: kept.has_comment,
        });
    }
    for kept in &plan.field_plans_keep {
        stats.kept_fields.push(KeptField {
            name: kept.name.clone(),
            kind: kept.kind.clone(),
            reason: kept.reason.clone(),
        });
    }

    // Fields: update the form tree before the page arrays are rewritten. A field that survived
    // is reachable from the catalog; a flattened one is detached.
    update_acro_form(&mut document, &plan.fields)?;

    // Page arrays: drop the annotations and widgets the plan flattened.
    for page in &plan.pages {
        if let Ok(dictionary) = document.get_dictionary_mut(page.page_id) {
            let kept: Vec<Object> = page
                .entries
                .iter()
                .filter(|entry| !entry.remove)
                .map(|entry| entry.raw.clone())
                .collect();
            if kept.is_empty() {
                dictionary.remove(b"Annots");
            } else {
                dictionary.set("Annots", Object::Array(kept));
            }
        }
    }

    // Page content: append the appearance drawings, then publish the resources they need.
    for (page_index, page) in plan.pages.iter().enumerate() {
        if plan.draws[page_index].is_empty() {
            continue;
        }
        if let Some(commands) =
            build_page_drawing(&mut document, page.page_id, &plan.draws[page_index])?
        {
            append_page_content(&mut document, page.page_id, &commands)?;
        }
    }

    for id in &plan.delete {
        if document.objects.contains_key(id) {
            document.delete_object(*id);
        }
    }
    document.prune_objects();
    let mut bytes = Vec::new();
    document.save_to(&mut bytes).map_err(|error| {
        LyraReaderError::new(ErrorCode::Io, "the flattened document could not be written")
            .with_detail(error.to_string())
    })?;
    Ok(Built { bytes, stats })
}

fn update_acro_form(document: &mut Document, fields: &[FieldPlan]) -> Result<()> {
    let kept_roots: Vec<&FieldPlan> = fields.iter().filter(|field| field.kept()).collect();
    let Some(form) = acro_form(document).cloned() else {
        return Ok(());
    };
    if kept_roots.is_empty() {
        let catalog = document.catalog_mut().map_err(|error| {
            LyraReaderError::new(ErrorCode::CorruptDocument, "the document has no catalog")
                .with_detail(error.to_string())
        })?;
        catalog.remove(b"AcroForm");
        return Ok(());
    }
    let mut kept_refs = Vec::new();
    for root in &kept_roots {
        if let Some(id) = root.node_id {
            kept_refs.push(Object::Reference(id));
        }
    }
    let catalog = document.catalog_mut().map_err(|error| {
        LyraReaderError::new(ErrorCode::CorruptDocument, "the document has no catalog")
            .with_detail(error.to_string())
    })?;
    let mut form = form;
    form.set("Fields", Object::Array(kept_refs));
    catalog.set("AcroForm", Object::Dictionary(form));
    // A surviving branch field must not still reference flattened children.
    for root in kept_roots {
        update_branch_kids(document, root);
    }
    Ok(())
}

fn update_branch_kids(document: &mut Document, plan: &FieldPlan) {
    if !matches!(plan.action, FieldAction::Branch) {
        return;
    }
    let Some(id) = plan.node_id else {
        return;
    };
    let kept_children: Vec<Object> = plan
        .children
        .iter()
        .filter(|child| child.kept())
        .filter_map(|child| child.node_id.map(Object::Reference))
        .collect();
    if let Ok(dictionary) = document.get_dictionary_mut(id) {
        dictionary.set("Kids", Object::Array(kept_children));
    }
    for child in &plan.children {
        update_branch_kids(document, child);
    }
}

fn build_page_drawing(
    document: &mut Document,
    page_id: ObjectId,
    draws: &[DrawOp],
) -> Result<Option<Vec<u8>>> {
    let mut commands = String::new();
    let mut xobjects: Vec<(String, ObjectId)> = Vec::new();
    let mut extgstates: Vec<(String, Dictionary)> = Vec::new();
    let mut counter = 0usize;
    let mut used: HashSet<String> = existing_resource_names(document, page_id);
    for draw in draws {
        match draw {
            DrawOp::Appearance(appearance) => {
                let name = next_resource_name(&mut counter, "LyraFlatX", &mut used);
                let object = match &appearance.source {
                    ApSource::Reference(id) => *id,
                    ApSource::Inline(stream) => document.add_object(Object::Stream(stream.clone())),
                };
                xobjects.push((name.clone(), object));
                let placement =
                    appearance_placement(appearance.rect, appearance.bbox, appearance.matrix);
                commands.push_str("q\n");
                push_matrix(&mut commands, placement);
                commands.push_str(&format!("/{name} Do\nQ\n"));
            }
            DrawOp::Synthesize(synth) => {
                let style = synth_style(synth);
                let gs_name = style.map(|(opacity, blend)| {
                    let name = next_resource_name(&mut counter, "LyraFlatGS", &mut used);
                    extgstates.push((name.clone(), graphics_state(opacity, blend)));
                    name
                });
                synth_commands(&mut commands, synth, gs_name.as_deref());
            }
        }
    }
    if commands.is_empty() {
        return Ok(None);
    }
    add_page_resources(document, page_id, &xobjects, &extgstates)?;
    Ok(Some(commands.into_bytes()))
}

/// Every name already present in the page's `/XObject` and `/ExtGState` resource dictionaries.
fn existing_resource_names(document: &Document, page_id: ObjectId) -> HashSet<String> {
    let mut names = HashSet::new();
    let Some(resources) = inherited_resources(document, page_id) else {
        return names;
    };
    for key in [b"XObject".as_slice(), b"ExtGState".as_slice()] {
        let Some(dictionary) = resources
            .get(key)
            .ok()
            .and_then(|object| resolve(document, object))
            .and_then(|object| object.as_dict().ok())
        else {
            continue;
        };
        for (name, _) in dictionary.iter() {
            names.insert(String::from_utf8_lossy(name).into_owned());
        }
    }
    names
}

fn next_resource_name(counter: &mut usize, prefix: &str, used: &mut HashSet<String>) -> String {
    loop {
        *counter += 1;
        let name = format!("{prefix}{counter}");
        if used.insert(name.clone()) {
            return name;
        }
    }
}

fn synth_style(synth: &SynthPlan) -> Option<(f64, Option<&[u8]>)> {
    let (opacity, blend) = match synth {
        SynthPlan::Quad { opacity, blend, .. }
        | SynthPlan::Ink { opacity, blend, .. }
        | SynthPlan::Line { opacity, blend, .. }
        | SynthPlan::Box { opacity, blend, .. } => (*opacity, blend.as_deref()),
    };
    (opacity < 1.0 || blend.is_some()).then_some((opacity, blend))
}

fn graphics_state(opacity: f64, blend: Option<&[u8]>) -> Dictionary {
    let mut dictionary = Dictionary::new();
    dictionary.set("Type", Object::Name(b"ExtGState".to_vec()));
    if let Some(blend) = blend {
        dictionary.set("BM", Object::Name(blend.to_vec()));
    }
    dictionary.set("ca", Object::Real(opacity as f32));
    dictionary.set("CA", Object::Real(opacity as f32));
    dictionary.set("AIS", Object::Boolean(false));
    dictionary
}

fn synth_commands(commands: &mut String, synth: &SynthPlan, gs: Option<&str>) {
    match synth {
        SynthPlan::Quad {
            kind, quads, color, ..
        } => {
            commands.push_str("q\n");
            if let Some(gs) = gs {
                commands.push_str(&format!("/{gs} gs\n"));
            }
            match kind {
                QuadKind::Highlight => {
                    push_color(commands, "rg", *color);
                    for quad in quads {
                        let points = sorted_quad(quad);
                        for (index, (x, y)) in points.iter().enumerate() {
                            commands.push_str(&format!(
                                "{} {} {}\n",
                                number(*x),
                                number(*y),
                                if index == 0 { "m" } else { "l" }
                            ));
                        }
                        commands.push_str("h f\n");
                    }
                }
                QuadKind::Underline | QuadKind::StrikeOut | QuadKind::Squiggly => {
                    push_color(commands, "RG", *color);
                    for quad in quads {
                        let points = sorted_quad(quad);
                        let min_x = points.iter().map(|(x, _)| *x).fold(f64::MAX, f64::min);
                        let max_x = points.iter().map(|(x, _)| *x).fold(f64::MIN, f64::max);
                        let min_y = points.iter().map(|(_, y)| *y).fold(f64::MAX, f64::min);
                        let max_y = points.iter().map(|(_, y)| *y).fold(f64::MIN, f64::max);
                        // The border width is on the shape, not on the line; a 11 pt line box
                        // gets a readable 1 pt rule by default.
                        let width = 1.0;
                        commands.push_str(&format!("{} w\n", number(width)));
                        match kind {
                            QuadKind::Underline => {
                                commands.push_str(&format!(
                                    "{} {} m {} {} l S\n",
                                    number(min_x),
                                    number(min_y + 0.5),
                                    number(max_x),
                                    number(min_y + 0.5)
                                ));
                            }
                            QuadKind::StrikeOut => {
                                let middle = (min_y + max_y) / 2.0;
                                commands.push_str(&format!(
                                    "{} {} m {} {} l S\n",
                                    number(min_x),
                                    number(middle),
                                    number(max_x),
                                    number(middle)
                                ));
                            }
                            QuadKind::Squiggly => {
                                let amplitude = 1.2;
                                let period = 8.0;
                                let y = min_y + 1.0;
                                let mut x = min_x;
                                let mut up = true;
                                commands.push_str(&format!("{} {} m\n", number(x), number(y)));
                                while x < max_x {
                                    x = (x + period / 2.0).min(max_x);
                                    let offset = if up { amplitude } else { 0.0 };
                                    commands.push_str(&format!(
                                        "{} {} l\n",
                                        number(x),
                                        number(y + offset)
                                    ));
                                    up = !up;
                                }
                                commands.push_str("S\n");
                            }
                            QuadKind::Highlight => {}
                        }
                    }
                }
            }
            commands.push_str("Q\n");
        }
        SynthPlan::Ink {
            paths,
            width,
            color,
            ..
        } => {
            commands.push_str("q\n");
            if let Some(gs) = gs {
                commands.push_str(&format!("/{gs} gs\n"));
            }
            push_color(commands, "RG", *color);
            commands.push_str(&format!("{} w\n1 J\n1 j\n", number(*width)));
            for path in paths {
                for (index, (x, y)) in path.iter().enumerate() {
                    commands.push_str(&format!(
                        "{} {} {}\n",
                        number(*x),
                        number(*y),
                        if index == 0 { "m" } else { "l" }
                    ));
                }
                commands.push_str("S\n");
            }
            commands.push_str("Q\n");
        }
        SynthPlan::Line {
            start,
            end,
            width,
            color,
            start_arrow,
            end_arrow,
            ..
        } => {
            commands.push_str("q\n");
            if let Some(gs) = gs {
                commands.push_str(&format!("/{gs} gs\n"));
            }
            push_color(commands, "RG", *color);
            commands.push_str(&format!("{} w\n0 J\n0 j\n", number(*width)));
            commands.push_str(&format!(
                "{} {} m {} {} l S\n",
                number(start.0),
                number(start.1),
                number(end.0),
                number(end.1)
            ));
            if let Some(arrow) = end_arrow {
                push_arrow(commands, *start, *end, *width, *arrow);
            }
            if let Some(arrow) = start_arrow {
                push_arrow(commands, *end, *start, *width, *arrow);
            }
            commands.push_str("Q\n");
        }
        SynthPlan::Box {
            rect,
            ellipse,
            width,
            color,
            fill,
            dash,
            dash_phase,
            ..
        } => {
            commands.push_str("q\n");
            if let Some(gs) = gs {
                commands.push_str(&format!("/{gs} gs\n"));
            }
            if let Some(fill) = fill {
                push_color(commands, "rg", *fill);
                if *ellipse {
                    push_ellipse(commands, *rect);
                    commands.push_str("f\n");
                } else {
                    commands.push_str(&format!(
                        "{} {} {} {} re f\n",
                        number(rect[0]),
                        number(rect[1]),
                        number(rect[2] - rect[0]),
                        number(rect[3] - rect[1])
                    ));
                }
            }
            push_color(commands, "RG", *color);
            commands.push_str(&format!("{} w\n", number(*width)));
            if let Some(dash) = dash {
                commands.push_str(&format!(
                    "[{}] {} d\n",
                    dash.iter()
                        .map(|value| number(*value))
                        .collect::<Vec<_>>()
                        .join(" "),
                    number(*dash_phase)
                ));
            }
            if *ellipse {
                push_ellipse(commands, *rect);
                commands.push_str("S\n");
            } else {
                commands.push_str(&format!(
                    "{} {} {} {} re S\n",
                    number(rect[0]),
                    number(rect[1]),
                    number(rect[2] - rect[0]),
                    number(rect[3] - rect[1])
                ));
            }
            commands.push_str("Q\n");
        }
    }
}

fn sorted_quad(quad: &[f64; 8]) -> Vec<(f64, f64)> {
    let mut points: Vec<(f64, f64)> = (0..4)
        .map(|index| (quad[index * 2], quad[index * 2 + 1]))
        .collect();
    let cx = points.iter().map(|(x, _)| *x).sum::<f64>() / 4.0;
    let cy = points.iter().map(|(_, y)| *y).sum::<f64>() / 4.0;
    points.sort_by(|left, right| {
        (left.1 - cy)
            .atan2(left.0 - cx)
            .partial_cmp(&(right.1 - cy).atan2(right.0 - cx))
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    points
}

fn push_matrix(commands: &mut String, matrix: [f64; 6]) {
    commands.push_str(&format!(
        "{} {} {} {} {} {} cm\n",
        number(matrix[0]),
        number(matrix[1]),
        number(matrix[2]),
        number(matrix[3]),
        number(matrix[4]),
        number(matrix[5])
    ));
}

fn push_color(commands: &mut String, operator: &str, color: [f64; 3]) {
    commands.push_str(&format!(
        "{} {} {} {}\n",
        number(color[0]),
        number(color[1]),
        number(color[2]),
        operator
    ));
}

fn push_ellipse(commands: &mut String, rect: [f64; 4]) {
    let cx = (rect[0] + rect[2]) / 2.0;
    let cy = (rect[1] + rect[3]) / 2.0;
    let rx = (rect[2] - rect[0]) / 2.0;
    let ry = (rect[3] - rect[1]) / 2.0;
    let kx = 0.552_284_749_8 * rx;
    let ky = 0.552_284_749_8 * ry;
    commands.push_str(&format!(
        "{} {} m\n{} {} {} {} {} {} c\n{} {} {} {} {} {} c\n{} {} {} {} {} {} c\n{} {} {} {} {} {} c\n",
        number(cx + rx),
        number(cy),
        number(cx + rx),
        number(cy + ky),
        number(cx + kx),
        number(cy + ry),
        number(cx),
        number(cy + ry),
        number(cx - kx),
        number(cy + ry),
        number(cx - rx),
        number(cy + ky),
        number(cx - rx),
        number(cy),
        number(cx - rx),
        number(cy - ky),
        number(cx - kx),
        number(cy - ry),
        number(cx),
        number(cy - ry),
        number(cx + kx),
        number(cy - ry),
        number(cx + rx),
        number(cy - ky),
        number(cx + rx),
        number(cy),
    ));
}

fn push_arrow(commands: &mut String, from: (f64, f64), to: (f64, f64), width: f64, arrow: Arrow) {
    let dx = to.0 - from.0;
    let dy = to.1 - from.1;
    let length = (dx * dx + dy * dy).sqrt();
    if length < 1e-6 {
        return;
    }
    let ux = dx / length;
    let uy = dy / length;
    let head = (width * 4.0).max(6.0);
    let half = (width * 1.5).max(2.0);
    let base = (to.0 - ux * head, to.1 - uy * head);
    let left = (base.0 - uy * half, base.1 + ux * half);
    let right = (base.0 + uy * half, base.1 - ux * half);
    match arrow {
        Arrow::Closed => {
            commands.push_str(&format!(
                "{} {} m {} {} l {} {} l h f\n",
                number(to.0),
                number(to.1),
                number(left.0),
                number(left.1),
                number(right.0),
                number(right.1)
            ));
        }
        Arrow::Open => {
            commands.push_str(&format!(
                "{} {} m {} {} l {} {} m {} {} l S\n",
                number(left.0),
                number(left.1),
                number(to.0),
                number(to.1),
                number(right.0),
                number(right.1),
                number(to.0),
                number(to.1)
            ));
        }
    }
}

fn number(value: f64) -> String {
    let mut text = format!("{value:.4}");
    while text.contains('.') && text.ends_with('0') {
        text.pop();
    }
    if text.ends_with('.') {
        text.pop();
    }
    if text == "-0" { "0".to_string() } else { text }
}

// ── Geometry ───────────────────────────────────────────────────────────────────────────────

/// PDF 32000-1 §12.5.5: scale the transformed appearance box independently in x and y into
/// `/Rect`, and translate it into place.
fn appearance_placement(rect: [f64; 4], bbox: [f64; 4], matrix: [f64; 6]) -> [f64; 6] {
    let corners = [
        (bbox[0], bbox[1]),
        (bbox[2], bbox[1]),
        (bbox[2], bbox[3]),
        (bbox[0], bbox[3]),
    ];
    let transformed: Vec<(f64, f64)> = corners
        .iter()
        .map(|(x, y)| {
            (
                matrix[0] * x + matrix[2] * y + matrix[4],
                matrix[1] * x + matrix[3] * y + matrix[5],
            )
        })
        .collect();
    let min_x = transformed.iter().map(|(x, _)| *x).fold(f64::MAX, f64::min);
    let max_x = transformed.iter().map(|(x, _)| *x).fold(f64::MIN, f64::max);
    let min_y = transformed.iter().map(|(_, y)| *y).fold(f64::MAX, f64::min);
    let max_y = transformed.iter().map(|(_, y)| *y).fold(f64::MIN, f64::max);
    let width = max_x - min_x;
    let height = max_y - min_y;
    if width.abs() < 1e-9 || height.abs() < 1e-9 {
        return [1.0, 0.0, 0.0, 1.0, rect[0], rect[1]];
    }
    let x_ratio = (rect[2] - rect[0]) / width;
    let y_ratio = (rect[3] - rect[1]) / height;
    [
        x_ratio,
        0.0,
        0.0,
        y_ratio,
        rect[0] - min_x * x_ratio,
        rect[1] - min_y * y_ratio,
    ]
}

// ── Page resources and content ─────────────────────────────────────────────────────────────

fn add_page_resources(
    document: &mut Document,
    page_id: ObjectId,
    xobjects: &[(String, ObjectId)],
    extgstates: &[(String, Dictionary)],
) -> Result<()> {
    if xobjects.is_empty() && extgstates.is_empty() {
        return Ok(());
    }
    let mut resources = inherited_resources(document, page_id).unwrap_or_default();
    if !xobjects.is_empty() {
        let mut existing = resources
            .get(b"XObject")
            .ok()
            .and_then(|object| resolve(document, object))
            .and_then(|object| object.as_dict().ok())
            .cloned()
            .unwrap_or_default();
        for (name, id) in xobjects {
            existing.set(name.as_bytes(), Object::Reference(*id));
        }
        resources.set("XObject", Object::Dictionary(existing));
    }
    if !extgstates.is_empty() {
        let mut existing = resources
            .get(b"ExtGState")
            .ok()
            .and_then(|object| resolve(document, object))
            .and_then(|object| object.as_dict().ok())
            .cloned()
            .unwrap_or_default();
        for (name, state) in extgstates {
            existing.set(name.as_bytes(), Object::Dictionary(state.clone()));
        }
        resources.set("ExtGState", Object::Dictionary(existing));
    }
    let page = document.get_dictionary_mut(page_id).map_err(|error| {
        LyraReaderError::new(ErrorCode::CorruptDocument, "a page has no dictionary")
            .with_detail(error.to_string())
    })?;
    page.set("Resources", Object::Dictionary(resources));
    Ok(())
}

fn inherited_resources(document: &Document, page_id: ObjectId) -> Option<Dictionary> {
    let mut current = page_id;
    for _ in 0..64 {
        let page = document.get_dictionary(current).ok()?;
        if let Some(resources) = page
            .get(b"Resources")
            .ok()
            .and_then(|object| resolve(document, object))
            .and_then(|object| object.as_dict().ok())
        {
            return Some(resources.clone());
        }
        current = reference_of(page, b"Parent")?;
    }
    None
}

fn append_page_content(document: &mut Document, page_id: ObjectId, commands: &[u8]) -> Result<()> {
    if commands.is_empty() {
        return Ok(());
    }
    let new_id = document.add_object(Object::Stream(Stream::new(
        Dictionary::new(),
        commands.to_vec(),
    )));
    let contents = document
        .get_dictionary(page_id)
        .ok()
        .and_then(|page| page.get(b"Contents").ok())
        .cloned();
    let mut replacement: Vec<Object> = Vec::new();
    match contents {
        None | Some(Object::Null) => {}
        Some(Object::Array(entries)) => {
            for entry in entries {
                match entry {
                    Object::Stream(stream) => {
                        replacement.push(Object::Reference(
                            document.add_object(Object::Stream(stream)),
                        ));
                    }
                    other => replacement.push(other),
                }
            }
        }
        Some(Object::Stream(stream)) => {
            replacement.push(Object::Reference(
                document.add_object(Object::Stream(stream)),
            ));
        }
        Some(Object::Reference(id)) => {
            let contents = document.get_object(id).ok().cloned();
            match contents {
                Some(Object::Array(entries)) => {
                    for entry in entries {
                        match entry {
                            Object::Stream(stream) => replacement.push(Object::Reference(
                                document.add_object(Object::Stream(stream)),
                            )),
                            other => replacement.push(other),
                        }
                    }
                }
                _ => replacement.push(Object::Reference(id)),
            }
        }
        Some(other) => replacement.push(other),
    }
    replacement.push(Object::Reference(new_id));
    let page = document.get_dictionary_mut(page_id).map_err(|error| {
        LyraReaderError::new(ErrorCode::CorruptDocument, "a page has no dictionary")
            .with_detail(error.to_string())
    })?;
    page.set("Contents", Object::Array(replacement));
    Ok(())
}

// ── Verification ──────────────────────────────────────────────────────────────────────────

fn verify_flattened(
    path: &Path,
    source: &Path,
    expected: &Expected,
    password: Option<&str>,
) -> Result<()> {
    let document = load_document(path, password)?;
    let page_count = document.get_pages().len();
    if page_count != expected.pages as usize {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the flattened copy changed the page count; nothing was published",
        )
        .with_detail(format!(
            "source has {} page(s), output has {page_count}",
            expected.pages
        )));
    }
    let mut remaining: Vec<(u32, String)> = Vec::new();
    let mut widgets = 0usize;
    for (page_index, page_id) in document.get_pages().values().copied().enumerate() {
        let page_number = u32::try_from(page_index).unwrap_or(u32::MAX);
        for object in page_annots(&document, page_id) {
            let dictionary = match &object {
                Object::Reference(id) => document
                    .get_object(*id)
                    .ok()
                    .and_then(|object| object.as_dict().ok()),
                Object::Dictionary(dictionary) => Some(dictionary),
                _ => None,
            };
            let Some(dictionary) = dictionary else {
                return Err(LyraReaderError::new(
                    ErrorCode::Internal,
                    "the flattened copy has an unreadable annotation; nothing was published",
                ));
            };
            let kind = name_of(dictionary, b"Subtype").unwrap_or_else(|| "Unknown".to_string());
            if kind == "Widget" {
                widgets += 1;
            }
            remaining.push((page_number, kind));
        }
    }
    remaining.sort();
    let mut expected_remaining = expected.remaining.clone();
    expected_remaining.sort();
    if remaining != expected_remaining {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the flattened copy's annotation tree is not the one the plan promised; nothing was \
             published",
        )
        .with_detail(format!(
            "remaining {remaining:?}, expected {expected_remaining:?}"
        )));
    }
    let form = acro_form(&document);
    let kept = read_kept_field_signature(&document);
    if kept != expected.kept_fields {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the flattened copy's form fields are not the ones the plan promised; nothing was \
             published",
        )
        .with_detail(format!(
            "remaining {kept:?}, expected {:?}",
            expected.kept_fields
        )));
    }
    if expected.acro_form_expected {
        if form.is_none() {
            return Err(LyraReaderError::new(
                ErrorCode::Internal,
                "the flattened copy lost a form field the plan kept; nothing was published",
            ));
        }
    } else if form.is_some() {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the flattened copy still has an /AcroForm; nothing was published",
        ));
    }
    if !expected.acro_form_expected && widgets > 0 {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the flattened copy still has a form widget; nothing was published",
        ));
    }
    verify_flatten_equivalence(source, path, password)?;
    Ok(())
}

fn read_kept_field_signature(document: &Document) -> Vec<(String, String)> {
    let mut fields = Vec::new();
    let Some(form) = acro_form(document) else {
        return fields;
    };
    let Some(roots) = form
        .get(b"Fields")
        .ok()
        .and_then(|object| resolve(document, object))
        .and_then(|object| object.as_array().ok())
    else {
        return fields;
    };
    fn walk(
        document: &Document,
        object: &Object,
        fields: &mut Vec<(String, String)>,
        depth: usize,
    ) {
        if depth > 64 {
            return;
        }
        let Some(dictionary) = resolve(document, object).and_then(|object| object.as_dict().ok())
        else {
            return;
        };
        let name = text_of(dictionary, b"T").unwrap_or_default();
        let (_, kind) = field_kind(
            name_bytes(dictionary, b"FT").as_deref(),
            integer_of(dictionary, b"Ff"),
        );
        if let Some(kids) = dictionary
            .get(b"Kids")
            .ok()
            .and_then(|object| resolve(document, object))
            .and_then(|object| object.as_array().ok())
            && kids.iter().any(|kid| {
                resolve(document, kid)
                    .and_then(|object| object.as_dict().ok())
                    .is_some_and(|kid| name_of(kid, b"Subtype").as_deref() != Some("Widget"))
            })
        {
            for kid in kids {
                walk(document, kid, fields, depth + 1);
            }
        } else {
            fields.push((name, kind));
        }
    }
    for root in roots {
        walk(document, root, &mut fields, 0);
    }
    fields.sort();
    fields
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{ScratchDir, copy_fixture};
    use std::fs;

    fn require_pdfium() -> bool {
        if crate::is_available() {
            true
        } else {
            eprintln!("skipping: PDFium unavailable");
            false
        }
    }

    #[test]
    fn a_flattened_copy_bakes_the_fixture_and_leaves_no_annotations_or_acro_form() {
        if !require_pdfium() {
            return;
        }
        let scratch = ScratchDir::new("flatten-basic");
        let source = copy_fixture(&scratch, "flatten.pdf", "source.pdf");
        let source_bytes = fs::read(&source).expect("read source");
        let destination = scratch.join("flat.pdf");
        let report = flatten_to_copy(&source, &destination, None).expect("flatten the fixture");
        assert_eq!(report.pages, 1);
        assert!(report.flattened_annotations >= 6, "{report:?}");
        assert_eq!(report.flattened_fields, 1, "{report:?}");
        assert_eq!(fs::read(&source).expect("read source after"), source_bytes);
        let output = load_document(&destination, None).expect("load output");
        assert_eq!(output.get_pages().len(), 1);
        for page_id in output.get_pages().values().copied() {
            assert!(
                page_annots(&output, page_id).is_empty(),
                "an annotation survived"
            );
        }
        assert!(acro_form(&output).is_none(), "/AcroForm survived");
        let bytes = fs::read(&destination).expect("read output");
        let text = String::from_utf8_lossy(&bytes);
        assert!(
            !text.contains("/AcroForm"),
            "/AcroForm is still in the bytes"
        );
    }

    #[test]
    fn a_sticky_note_is_kept_and_reported() {
        if !require_pdfium() {
            return;
        }
        let scratch = ScratchDir::new("flatten-note");
        let source = copy_fixture(&scratch, "annotated-inline-notes.pdf", "source.pdf");
        let destination = scratch.join("flat.pdf");
        let report = flatten_to_copy(&source, &destination, None).expect("flatten notes fixture");
        assert_eq!(report.sticky_notes_kept, 1, "{report:?}");
        assert!(
            report
                .kept_annotations
                .iter()
                .any(|annotation| annotation.kind == "Text"
                    && annotation.reason.contains("sticky note")),
            "{report:?}"
        );
        // The fixture also carries one Hidden highlight. Painting it would make an invisible
        // mark visible, so it stays an annotation and is reported.
        assert!(
            report.kept_annotations.iter().any(|annotation| {
                annotation.kind == "Highlight" && annotation.reason.contains("hidden")
            }),
            "{report:?}"
        );
        let output = load_document(&destination, None).expect("load output");
        let remaining: usize = output
            .get_pages()
            .values()
            .copied()
            .map(|page_id| page_annots(&output, page_id).len())
            .sum();
        assert_eq!(
            remaining, 2,
            "the sticky note and the hidden highlight remain"
        );
    }

    #[test]
    fn all_four_quad_markup_kinds_are_synthesised() {
        if !require_pdfium() {
            return;
        }
        let scratch = ScratchDir::new("flatten-quads");
        let source = copy_fixture(&scratch, "annotated.pdf", "source.pdf");
        let destination = scratch.join("flat.pdf");
        let report = flatten_to_copy(&source, &destination, None).expect("flatten the markup");
        let kinds: BTreeMap<&str, u32> = report
            .flattened_annotation_kinds
            .iter()
            .map(|count| (count.kind.as_str(), count.count))
            .collect();
        for kind in ["Highlight", "Underline", "StrikeOut", "Squiggly"] {
            assert!(
                kinds.get(kind).copied().unwrap_or(0) >= 1,
                "{kind}: {report:?}"
            );
        }
        // The sticky note, the link and the free-text annotation without an appearance stay.
        for kept in ["Text", "Link", "FreeText"] {
            assert!(
                report
                    .kept_annotations
                    .iter()
                    .any(|annotation| annotation.kind == kept),
                "{kept}: {report:?}"
            );
        }
    }

    #[test]
    fn ink_and_shapes_are_synthesised_when_the_producer_wrote_no_appearance() {
        if !require_pdfium() {
            return;
        }
        let scratch = ScratchDir::new("flatten-synth");
        let source = copy_fixture(&scratch, "annotated-strokes.pdf", "source.pdf");
        {
            let mut document = load_document(&source, None).expect("load stroke fixture");
            for object in document.objects.values_mut() {
                let Object::Dictionary(dictionary) = object else {
                    continue;
                };
                if matches!(
                    name_of(dictionary, b"Subtype").as_deref(),
                    Some("Ink" | "Square" | "Circle" | "Line")
                ) {
                    dictionary.remove(b"AP");
                }
            }
            let mut bytes = Vec::new();
            document.save_to(&mut bytes).expect("write edited fixture");
            fs::write(&source, bytes).expect("replace the test fixture copy");
        }
        let destination = scratch.join("flat.pdf");
        let report = flatten_to_copy(&source, &destination, None).expect("flatten the strokes");
        assert_eq!(report.flattened_annotations, 5, "{report:?}");
        let kinds: BTreeMap<&str, u32> = report
            .flattened_annotation_kinds
            .iter()
            .map(|count| (count.kind.as_str(), count.count))
            .collect();
        assert_eq!(kinds.get("Ink"), Some(&1));
        assert_eq!(kinds.get("Square"), Some(&1));
        assert_eq!(kinds.get("Circle"), Some(&1));
        assert_eq!(kinds.get("Line"), Some(&2));
        let output = load_document(&destination, None).expect("load output");
        for page_id in output.get_pages().values().copied() {
            assert!(
                page_annots(&output, page_id).is_empty(),
                "an annotation survived"
            );
        }
    }

    #[test]
    fn links_are_kept_as_navigation() {
        if !require_pdfium() {
            return;
        }
        let scratch = ScratchDir::new("flatten-links");
        let source = copy_fixture(&scratch, "link-borders.pdf", "source.pdf");
        let destination = scratch.join("flat.pdf");
        let report = flatten_to_copy(&source, &destination, None).expect("flatten link fixture");
        assert_eq!(report.links_kept, 5, "{report:?}");
        assert_eq!(report.flattened_annotations, 1, "{report:?}");
    }

    #[test]
    fn a_signed_document_gets_a_copy_without_signature_fields() {
        if !require_pdfium() {
            return;
        }
        let scratch = ScratchDir::new("flatten-signed");
        let source = copy_fixture(&scratch, "signed-signature.pdf", "source.pdf");
        let source_bytes = fs::read(&source).expect("read source");
        let destination = scratch.join("flat.pdf");
        let report = flatten_to_copy(&source, &destination, None).expect("flatten signed fixture");
        assert_eq!(fs::read(&source).expect("source after"), source_bytes);
        assert!(report.signature_fields_removed >= 1, "{report:?}");
        let output = load_document(&destination, None).expect("load output");
        let signatures = read_kept_field_signature(&output)
            .into_iter()
            .filter(|(_, kind)| kind == "signature")
            .count();
        assert_eq!(signatures, 0, "a signature field survived");
    }

    #[test]
    fn an_unbakeable_field_is_kept_and_reported() {
        if !require_pdfium() {
            return;
        }
        let scratch = ScratchDir::new("flatten-unbakeable");
        let source = copy_fixture(&scratch, "form-fields.pdf", "source.pdf");
        // Remove the email widget's /AP: without an appearance, the field cannot be baked
        // faithfully. It must survive, with its AcroForm parent, and the report must say why.
        {
            let mut document = load_document(&source, None).expect("load form fixture");
            for object in document.objects.values_mut() {
                let Object::Dictionary(dictionary) = object else {
                    continue;
                };
                if text_of(dictionary, b"T").as_deref() == Some("email") {
                    dictionary.remove(b"AP");
                }
            }
            let mut bytes = Vec::new();
            document.save_to(&mut bytes).expect("write edited fixture");
            fs::write(&source, bytes).expect("replace the test fixture copy");
        }
        let destination = scratch.join("flat.pdf");
        let report = flatten_to_copy(&source, &destination, None).expect("flatten the form");
        assert_eq!(report.kept_fields.len(), 1, "{report:?}");
        assert_eq!(report.kept_fields[0].name, "email", "{report:?}");
        assert!(
            report.kept_fields[0].reason.contains("no /AP"),
            "{report:?}"
        );
        assert_eq!(report.flattened_fields, 6, "{report:?}");
        assert_eq!(report.signature_fields_removed, 1, "{report:?}");
        let output = load_document(&destination, None).expect("load output");
        assert!(
            acro_form(&output).is_some(),
            "the kept field needs its AcroForm"
        );
        let fields = read_kept_field_signature(&output);
        assert_eq!(fields, vec![("email".to_string(), "text".to_string())]);
    }

    #[test]
    fn an_encrypted_document_is_refused_and_writes_nothing() {
        if !require_pdfium() {
            return;
        }
        let scratch = ScratchDir::new("flatten-encrypted");
        let source = copy_fixture(&scratch, "form-fields-encrypted.pdf", "source.pdf");
        let destination = scratch.join("flat.pdf");
        let error = flatten_to_copy(&source, &destination, None)
            .expect_err("an encrypted document must refuse");
        assert_eq!(error.code, ErrorCode::Encrypted, "{error:?}");
        assert!(
            error.message.to_lowercase().contains("encrypted"),
            "{error:?}"
        );
        assert!(
            !destination.exists(),
            "a refused encrypted flatten wrote a file"
        );
    }

    #[test]
    fn xfa_is_refused_and_writes_nothing() {
        if !require_pdfium() {
            return;
        }
        let scratch = ScratchDir::new("flatten-xfa");
        let source = copy_fixture(&scratch, "xfa-refusal.pdf", "source.pdf");
        let destination = scratch.join("flat.pdf");
        let error = flatten_to_copy(&source, &destination, None).expect_err("XFA must refuse");
        assert!(error.message.contains("XFA"), "{error:?}");
        assert!(!destination.exists(), "a refused XFA flatten wrote a file");
    }

    #[test]
    fn an_interrupted_build_leaves_no_partial_output() {
        if !require_pdfium() {
            return;
        }
        let scratch = ScratchDir::new("flatten-failure");
        let source = copy_fixture(&scratch, "flatten.pdf", "source.pdf");
        let destination = scratch.join("flat.pdf");
        let error = flatten_to_copy_inner(&source, &destination, None, true)
            .expect_err("the interrupted build must fail");
        assert!(error.message.contains("interrupted"), "{error:?}");
        assert!(
            !destination.exists(),
            "a failed flatten published a partial file"
        );
        let leftovers = fs::read_dir(&scratch)
            .expect("read scratch")
            .filter_map(|entry| entry.ok())
            .filter(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .contains(".lyra-reader-save-")
            })
            .count();
        assert_eq!(leftovers, 0, "the temporary file was left behind");
    }
}
