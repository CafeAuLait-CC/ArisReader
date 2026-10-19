//! Writing the reader's bookmarks into the document's `/Outlines`, as **one independent
//! top-level subtree** that is merged into — never substituted for — the existing outline.
//!
//! # Why a direct writer
//!
//! PDFium's public C API reads bookmarks (`FPDFBookmark_*`) but has no call that creates, moves
//! or rewrites one. Every write here is therefore a dictionary edit through lopdf's incremental
//! writer, in the same temporary file as [`crate::writeback::save_annotated_pdf`], under the same
//! contract: the source bytes stay the prefix, the file is reopened and verified, and only then
//! renamed.
//!
//! # The shape that is written
//!
//! The document's own `/Outlines` root is kept, and every existing node is left where it is.
//! One top-level node is owned by the reader:
//!
//! ```text
//! /Outlines
//!   ├─ /Title (Chapter One)          ← the document's, untouched
//!   ├─ /Title (Chapter Two)          ← the document's, untouched
//!   ├─ …
//!   └─ /Title (My bookmarks)         ← ours
//!        /LyraReaderBookmarks (lyra-reader-bookmarks:v1)
//!        /Count 3                    ← positive: the subtree is open
//!        ├─ /Title (Alpha)  /Dest [page /XYZ x y null]  /LyraReaderID (uuid)
//!        ├─ /Title (Beta)   /Dest [page /XYZ x y null]  /LyraReaderID (uuid)
//!        └─ /Title (Gamma)  /Dest [page /XYZ x y null]  /LyraReaderID (uuid)
//! ```
//!
//! Bookmarks are flat in the reader's model, so they are written exactly one level under the
//! subtree root. The root gets the first bookmark's destination, so clicking it also navigates.
//!
//! # Identity and rewrite
//!
//! The private `/LyraReaderBookmarks` marker on the subtree root — not its title — is the
//! identity. On every save the marked node is found among the root's children and its child list
//! is replaced with the current bookmark list: the subtree is rewritten in place, never appended
//! a second time. A node another application authored with the same title is a *different* node:
//! the marker is not on it, so it is left alone and a distinguishable title (`My bookmarks
//! (LyraReader)`, then a numbered variant) is used for ours.
//!
//! # Verification
//!
//! [`append_bookmarks`] only writes. [`verify_outline`] reopens both the source and the written
//! temporary file and proves, before the caller's rename:
//!
//! * every node outside our marked subtree has the same title bytes, destination, order, open
//!   state and children as it had in the source (a whole-tree comparison, not a sample);
//! * the marked subtree appears exactly once, is a direct child of `/Outlines`, has the expected
//!   title, a positive `/Count` matching the bookmark count, and one child per bookmark;
//! * every child's `/Dest` names a page **object that is in the written file's page tree** and
//!   resolves to the bookmark's page index, with the requested page-local Y;
//! * `/Parent`, `/First`, `/Last`, `/Next` and `/Prev` form a consistent chain.
//!
//! # Page order
//!
//! The page index is resolved against the file being written, so a staged page reorder is
//! honoured: the shell remaps the sidecar's bookmark pages when it edits pages, and this writer
//! resolves those indices in the current revision. A bookmark whose page no longer exists is
//! refused by [`validate_bookmarks`] before anything is written, so a deleted page cannot leave
//! a dangling destination.

use crate::forms::{decode_text_string, text_string_object};
use lopdf::{Dictionary, Document, IncrementalDocument, LoadOptions, Object, ObjectId};
use lyra_reader_core::{
    ErrorCode, LyraReaderError, PageGeometry, PageIndex, Point, Rect, Result, Rotation,
};
use std::collections::HashSet;
use std::fs::{self, File};
use std::io::Write;
use std::path::Path;

/// The title the reader's subtree is offered as.
pub const DEFAULT_BOOKMARK_TITLE: &str = "My bookmarks";

/// Private key on the subtree root. Its value identifies the node as ours.
const MARKER_KEY: &[u8] = b"LyraReaderBookmarks";
const MARKER_VALUE: &str = "lyra-reader-bookmarks:v1";

/// Private key on every child: the sidecar bookmark's UUID, so a reopened document can adopt
/// the file's bookmarks with their identities intact.
pub(crate) const ID_KEY: &[u8] = b"LyraReaderID";

/// Hard limits, so a malformed shell request cannot ask the writer to build an unreasonable tree.
pub(crate) const MAX_BOOKMARKS: usize = 5_000;
const MAX_ID_BYTES: usize = 128;
const MAX_TITLE_BYTES: usize = 4_096;
const MAX_OUTLINE_DEPTH: usize = 64;

/// One bookmark the shell asks the writer to put into the outline.
///
/// `y_pt` is a **page-local view-space** Y: 0 at the top of the page, increasing downwards,
/// independent of zoom and window size (the same value the sidecar stores).
#[derive(Clone, Debug, PartialEq)]
pub struct WriteBookmark {
    pub id: String,
    pub page: PageIndex,
    pub title: String,
    pub y_pt: f64,
}

/// What a bookmark write did.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct OutlineWriteReport {
    pub written_ids: Vec<String>,
    /// The document's outline nodes outside our subtree, all of which were verified unchanged.
    pub preexisting_entry_count: usize,
    /// Title of the rewritten subtree; `None` when an empty bookmark list removed it.
    pub title: Option<String>,
}

/// One of the reader's own bookmarks as it exists in a written file.
#[derive(Clone, Debug, PartialEq)]
pub struct EmbeddedBookmark {
    pub id: String,
    pub title: String,
    pub page: Option<u32>,
    /// Page-local view-space Y, when the destination carries a position.
    pub y_pt: Option<f64>,
}

/// The reader's marked subtree as it exists in a written file.
#[derive(Clone, Debug, PartialEq)]
pub struct EmbeddedBookmarks {
    pub title: String,
    pub bookmarks: Vec<EmbeddedBookmark>,
}

/// Refuses a bookmark list the writer cannot represent faithfully.
pub(crate) fn validate_bookmarks(bookmarks: &[WriteBookmark], page_count: u32) -> Result<()> {
    if bookmarks.len() > MAX_BOOKMARKS {
        return Err(LyraReaderError::new(
            ErrorCode::InvalidArgument,
            format!("{MAX_BOOKMARKS} bookmarks is the most one save can write"),
        ));
    }
    let mut ids = HashSet::new();
    for bookmark in bookmarks {
        if bookmark.id.is_empty()
            || bookmark.id.len() > MAX_ID_BYTES
            || !bookmark.id.bytes().all(|byte| byte.is_ascii_graphic())
        {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "a bookmark identity must be 1–128 printable ASCII characters",
            )
            .with_detail(format!("id: {:?}", bookmark.id)));
        }
        if !ids.insert(bookmark.id.clone()) {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                format!(
                    "two bookmarks in one save share the identity {:?}",
                    bookmark.id
                ),
            ));
        }
        if bookmark.page.0 >= page_count {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                format!(
                    "bookmark {:?} names page {}, but the document has {page_count} page(s)",
                    bookmark.id,
                    bookmark.page.get()
                ),
            ));
        }
        if !bookmark.y_pt.is_finite() {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                format!("bookmark {:?} has a non-finite Y", bookmark.id),
            ));
        }
        if bookmark.title.len() > MAX_TITLE_BYTES {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                format!(
                    "bookmark {:?} has a title longer than {MAX_TITLE_BYTES} bytes",
                    bookmark.id
                ),
            ));
        }
        if bookmark.title.contains('\0') {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                format!("bookmark {:?} has a NUL in its title", bookmark.id),
            ));
        }
    }
    Ok(())
}

/// Adds the reader's bookmark subtree to `base`, writing the complete document to `output`.
///
/// `base` and `output` may be the same path: the bytes are read before the output is created.
/// `bookmarks` is the reader's **whole current list**; an empty list removes a marked subtree
/// that an earlier save wrote (and is a no-op when the document has none). Returns `None` when
/// there was nothing to do and nothing was written.
pub(crate) fn append_bookmarks(
    base: &Path,
    output: &Path,
    bookmarks: &[WriteBookmark],
    password: Option<&str>,
) -> Result<Option<OutlineWriteReport>> {
    let previous_bytes = fs::read(base).map_err(|error| {
        io_error(
            "could not read the document before writing bookmarks",
            base,
            error,
        )
    })?;
    let document = load_document(base, password)?;
    let pages = document.get_pages();
    let page_count = u32::try_from(pages.len()).unwrap_or(u32::MAX);
    validate_bookmarks(bookmarks, page_count)?;
    let pages_by_id: std::collections::HashMap<ObjectId, u32> =
        pages.iter().map(|(index, id)| (*id, index - 1)).collect();
    let catalog = catalog_id(&document)?;
    let old_view = OutlineView {
        old: &document,
        new: &document,
    };
    let old_root = outline_root(&document, catalog)?;
    if let Some(dictionary) = old_root.dictionary(&old_view) {
        ensure_reference_links(dictionary)?;
    }
    let old_children = old_root.children(&old_view);
    let markers: Vec<ObjectId> = old_children
        .iter()
        .copied()
        .filter(|id| old_view.is_marker(*id))
        .collect();
    let existing_marker = markers.first().copied();
    let marker_id = existing_marker;

    if bookmarks.is_empty() && marker_id.is_none() {
        return Ok(None);
    }

    // The document's existing tree, without our subtree: exactly what must survive untouched.
    let mut preexisting_entry_count = 0usize;
    for id in old_children.iter().filter(|id| !old_view.is_marker(**id)) {
        preexisting_entry_count += node_view(&old_view, *id, &pages_by_id)?.count_nodes();
    }

    // Everything that needs the old document must happen before it moves into the incremental
    // writer. Geometry and destinations are computed here; the requested Y is clamped into the
    // page's visible height so an out-of-range sidecar value cannot create a destination far off
    // the page.
    struct Prepared<'a> {
        bookmark: &'a WriteBookmark,
        title: String,
        page_id: ObjectId,
        dest_point: Point,
    }
    let mut prepared = Vec::with_capacity(bookmarks.len());
    for bookmark in bookmarks {
        let page_id = *pages.get(&(bookmark.page.get() + 1)).ok_or_else(|| {
            LyraReaderError::new(
                ErrorCode::InvalidArgument,
                format!(
                    "bookmark {:?} names page {}, which the document does not have",
                    bookmark.id,
                    bookmark.page.get()
                ),
            )
        })?;
        let geometry = page_geometry(&document, page_id)?;
        let dest_point = destination_point(&geometry, bookmark.y_pt)?;
        prepared.push(Prepared {
            bookmark,
            title: display_title(bookmark),
            page_id,
            dest_point,
        });
    }

    let title = match marker_id {
        Some(id) => {
            let preserved = old_view
                .dict(id)
                .and_then(raw_title)
                .map(|bytes| decode_text_string(&bytes))
                .filter(|title| !title.is_empty())
                .unwrap_or_else(|| DEFAULT_BOOKMARK_TITLE.to_string());
            let used_by_others: HashSet<String> = old_children
                .iter()
                .filter(|child| **child != id)
                .filter_map(|child| old_view.dict(*child).and_then(raw_title))
                .map(|bytes| decode_text_string(&bytes))
                .collect();
            if used_by_others.contains(&preserved) {
                choose_title(&used_by_others)
            } else {
                preserved
            }
        }
        None => {
            let used: HashSet<String> = old_children
                .iter()
                .filter_map(|child| old_view.dict(*child).and_then(raw_title))
                .map(|bytes| decode_text_string(&bytes))
                .collect();
            choose_title(&used)
        }
    };

    // Clone the catalog before the document moves; the rest of the write mutates the new
    // revision only.
    let mut incremental = IncrementalDocument::create_from(previous_bytes, document);
    let root_id = ensure_outline_root(&mut incremental, catalog)?;
    incremental
        .new_document
        .get_dictionary(root_id)
        .map_err(|error| lopdf_error("the outline root is not a dictionary", error))?;

    let new_marker = existing_marker.is_none();
    let marker_id = match existing_marker {
        Some(id) => {
            incremental
                .opt_clone_object_to_new_document(id)
                .map_err(|error| lopdf_error("could not copy the bookmark subtree", error))?;
            id
        }
        None => {
            let mut dictionary = Dictionary::new();
            dictionary.set("Title", text_string_object(&title));
            dictionary.set("Parent", Object::Reference(root_id));
            // The marker is the identity: a later save finds this node by it, never by title.
            dictionary.set(MARKER_KEY, text_string_object(MARKER_VALUE));
            add_object(
                &mut incremental.new_document,
                Object::Dictionary(dictionary),
            )
        }
    };

    // The children are new objects in every save; old children become unreachable when the
    // marker's First/Last are pointed at the new chain.
    let mut child_ids = Vec::with_capacity(prepared.len());
    for entry in &prepared {
        let mut dictionary = Dictionary::new();
        dictionary.set("Title", text_string_object(&entry.title));
        dictionary.set("Parent", Object::Reference(marker_id));
        dictionary.set(
            "Dest",
            Object::Array(vec![
                Object::Reference(entry.page_id),
                Object::Name(b"XYZ".to_vec()),
                Object::Real(entry.dest_point.x as f32),
                Object::Real(entry.dest_point.y as f32),
                Object::Null,
            ]),
        );
        dictionary.set(ID_KEY, text_string_object(&entry.bookmark.id));
        child_ids.push(add_object(
            &mut incremental.new_document,
            Object::Dictionary(dictionary),
        ));
    }
    for (index, id) in child_ids.iter().enumerate() {
        let dictionary = incremental
            .new_document
            .get_dictionary_mut(*id)
            .map_err(|error| lopdf_error("a new bookmark is not a dictionary", error))?;
        if index > 0 {
            dictionary.set("Prev", Object::Reference(child_ids[index - 1]));
        }
        if index + 1 < child_ids.len() {
            dictionary.set("Next", Object::Reference(child_ids[index + 1]));
        }
    }

    // The marker's own dictionary: title, count and child list. A positive /Count is what makes
    // the subtree open by default, so every bookmark is visible without a click.
    let marker_dictionary = incremental
        .new_document
        .get_dictionary_mut(marker_id)
        .map_err(|error| lopdf_error("the bookmark subtree root is not a dictionary", error))?;
    marker_dictionary.set("Title", text_string_object(&title));
    marker_dictionary.set("Parent", Object::Reference(root_id));
    marker_dictionary.set(MARKER_KEY, text_string_object(MARKER_VALUE));
    if let (Some(first), Some(last)) = (child_ids.first(), child_ids.last()) {
        marker_dictionary.set("First", Object::Reference(*first));
        marker_dictionary.set("Last", Object::Reference(*last));
        marker_dictionary.set("Count", Object::Integer(child_ids.len() as i64));
        // Clicking the subtree root navigates to its first bookmark, so the node is not a
        // dead end. The destination is the first child's, in the same page-local position.
        marker_dictionary.set(
            "Dest",
            Object::Array(vec![
                Object::Reference(prepared[0].page_id),
                Object::Name(b"XYZ".to_vec()),
                Object::Real(prepared[0].dest_point.x as f32),
                Object::Real(prepared[0].dest_point.y as f32),
                Object::Null,
            ]),
        );
    } else {
        marker_dictionary.remove(b"First");
        marker_dictionary.remove(b"Last");
        marker_dictionary.remove(b"Dest");
        marker_dictionary.set("Count", Object::Integer(0));
    }

    // Append the new marker to the end of the document's top-level chain (or unlink it and every
    // duplicate marker when the reader now has no bookmarks).
    if new_marker {
        append_marker(&mut incremental, root_id, marker_id)?;
    } else if bookmarks.is_empty() {
        for id in &markers {
            unlink_child(&mut incremental, root_id, *id)?;
        }
    }
    // Extra marked nodes (a corrupt file, or two writers racing) are never shown twice.
    for id in markers.iter().skip(1) {
        unlink_child(&mut incremental, root_id, *id)?;
    }
    // Keep our node's own /Prev//Next consistent with wherever it now sits, including after a
    // duplicate was unlinked from in front of it.
    relink_marker(&mut incremental, root_id, marker_id)?;

    refresh_root_count(&mut incremental, root_id)?;

    let mut file = File::create(output).map_err(|error| {
        io_error(
            "could not create the file for the bookmark update",
            output,
            error,
        )
    })?;
    incremental.save_to(&mut file).map_err(|error| {
        LyraReaderError::new(ErrorCode::Io, "could not write the bookmark update")
            .with_detail(error.to_string())
    })?;
    file.flush()
        .map_err(|error| io_error("could not flush the bookmark update", output, error))?;
    file.sync_all()
        .map_err(|error| io_error("could not fsync the bookmark update", output, error))?;

    Ok(Some(OutlineWriteReport {
        written_ids: bookmarks
            .iter()
            .map(|bookmark| bookmark.id.clone())
            .collect(),
        preexisting_entry_count,
        title: (!bookmarks.is_empty()).then_some(title),
    }))
}

/// What [`verify_outline`] proved about the written file.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct OutlineVerification {
    pub preexisting_entry_count: usize,
    pub written_ids: Vec<String>,
    pub title: Option<String>,
}

/// Reopens `saved` and proves that the existing outline is untouched and our subtree is right.
///
/// `report` is what [`append_bookmarks`] said it wrote; the verification does not trust it.
pub(crate) fn verify_outline(
    source: &Path,
    saved: &Path,
    bookmarks: &[WriteBookmark],
    report: Option<&OutlineWriteReport>,
    password: Option<&str>,
) -> Result<OutlineVerification> {
    let before_document = load_document(source, password)?;
    let after_document = load_document(saved, password)?;
    let before_pages = page_ids(&before_document);
    let after_pages = page_ids(&after_document);
    let before_catalog = catalog_id(&before_document)?;
    let after_catalog = catalog_id(&after_document)?;
    let before_view = OutlineView {
        old: &before_document,
        new: &before_document,
    };
    let after_view = OutlineView {
        old: &after_document,
        new: &after_document,
    };
    let before_root = outline_root(&before_document, before_catalog)?;
    let after_root = outline_root(&after_document, after_catalog)?;

    let before_existing = existing_nodes(&before_view, &before_root, &before_pages)?;
    let after_existing = existing_nodes(&after_view, &after_root, &after_pages)?;
    if before_existing != after_existing {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the bookmark write changed an outline node the document already had",
        )
        .with_detail(format!(
            "before: {:?}\nafter: {:?}",
            before_existing, after_existing
        )));
    }
    let preexisting_entry_count: usize = before_existing
        .iter()
        .map(OutlineNodeView::count_nodes)
        .sum();

    let after_children = after_root.children(&after_view);
    let markers: Vec<ObjectId> = after_children
        .iter()
        .copied()
        .filter(|id| after_view.is_marker(*id))
        .collect();
    if bookmarks.is_empty() {
        if !markers.is_empty() {
            return Err(LyraReaderError::new(
                ErrorCode::Internal,
                "the empty bookmark list did not remove the reader's outline subtree",
            ));
        }
        if let Some(report) = report
            && !report.written_ids.is_empty()
        {
            return Err(LyraReaderError::new(
                ErrorCode::Internal,
                "the writer reported bookmarks for a save that removed them",
            ));
        }
        if let Some(root_id) = after_root.id() {
            let children = after_root.children(&after_view);
            let root_dictionary = after_root
                .dictionary(&after_view)
                .ok_or_else(|| internal("the outline root is missing"))?;
            let first = root_dictionary
                .get(b"First")
                .ok()
                .and_then(|object| object.as_reference().ok());
            let last = root_dictionary
                .get(b"Last")
                .ok()
                .and_then(|object| object.as_reference().ok());
            if first != children.first().copied() || last != children.last().copied() {
                return Err(internal(
                    "the outline root's /First or /Last does not match its sibling chain",
                )
                .with_detail(format!("root {root_id:?}")));
            }
            let expected_count = root_visible_count(&after_view, &after_root);
            let actual_count = integer(root_dictionary, b"Count").unwrap_or(0);
            if actual_count != expected_count {
                return Err(internal(
                    "the outline root's /Count is inconsistent after removing the subtree",
                )
                .with_detail(format!("expected {expected_count}, found {actual_count}")));
            }
        }
        return Ok(OutlineVerification {
            preexisting_entry_count,
            written_ids: Vec::new(),
            title: None,
        });
    }

    let Some(marker_id) = markers.first().copied() else {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the saved file does not contain the reader's bookmark subtree",
        ));
    };
    if markers.len() != 1 {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the saved file contains the reader's bookmark subtree more than once",
        )
        .with_detail(format!("{} marked nodes", markers.len())));
    }
    let Some(report) = report else {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the writer did not report the bookmark subtree it wrote",
        ));
    };
    let marker_dictionary = after_view
        .dict(marker_id)
        .ok_or_else(|| internal("the bookmark subtree root is missing"))?;
    let title = raw_title(marker_dictionary)
        .map(|bytes| decode_text_string(&bytes))
        .unwrap_or_default();
    let Some(expected_title) = report.title.as_deref() else {
        return Err(internal("the writer reported no bookmark subtree title"));
    };
    if title != expected_title {
        return Err(internal("the bookmark subtree title changed on disk")
            .with_detail(format!("expected {expected_title:?}, found {title:?}")));
    }
    let Some(after_root_id) = after_root.id() else {
        return Err(internal(
            "the saved file's outline root is not an indirect object",
        ));
    };
    if marker_dictionary
        .get(b"Parent")
        .ok()
        .and_then(|object| object.as_reference().ok())
        != Some(after_root_id)
    {
        return Err(internal(
            "the bookmark subtree's /Parent is not the outline root",
        ));
    }
    verify_root_chain(&after_view, &after_root, marker_id, after_root_id)?;
    let marker_count = integer(marker_dictionary, b"Count").unwrap_or(0);
    if marker_count != bookmarks.len() as i64 {
        return Err(
            internal("the bookmark subtree's /Count does not match its bookmarks").with_detail(
                format!("expected +{}, found {marker_count}", bookmarks.len()),
            ),
        );
    }
    if marker_count <= 0 {
        return Err(internal(
            "the bookmark subtree is written closed; the bookmarks must be visible",
        ));
    }
    let child_ids = after_view.children(marker_id);
    if child_ids.len() != bookmarks.len() {
        return Err(
            internal("the bookmark subtree has the wrong number of children").with_detail(format!(
                "expected {}, found {}",
                bookmarks.len(),
                child_ids.len()
            )),
        );
    }
    let context = BookmarkNodeContext {
        view: &after_view,
        document: &after_document,
        pages: &after_pages,
        marker_id,
        siblings: &child_ids,
    };
    for (index, (child, expected)) in child_ids.iter().zip(bookmarks.iter()).enumerate() {
        verify_bookmark_node(&context, *child, expected, index)?;
        if index == 0 {
            // The subtree root carries the first bookmark's destination.
            let Some(root_page) =
                destination_page(&after_document, marker_dictionary, &after_pages)
            else {
                return Err(internal(
                    "the bookmark subtree root has no resolvable destination",
                ));
            };
            if root_page != expected.page.get() {
                return Err(
                    internal("the bookmark subtree root points at the wrong page").with_detail(
                        format!("expected {}, found {root_page}", expected.page.get()),
                    ),
                );
            }
        }
    }

    // The root's /Count is a derived value; every viewer uses it to decide what is visible.
    let expected_count = root_visible_count(&after_view, &after_root);
    let actual_count = after_root
        .dictionary(&after_view)
        .and_then(|dictionary| integer(dictionary, b"Count"))
        .unwrap_or(0);
    if actual_count != expected_count {
        return Err(internal("the outline root's /Count is inconsistent")
            .with_detail(format!("expected {expected_count}, found {actual_count}")));
    }

    let written_ids: Vec<String> = bookmarks
        .iter()
        .map(|bookmark| bookmark.id.clone())
        .collect();
    if report.written_ids != written_ids {
        return Err(internal(
            "the writer's report does not match the bookmark list it was given",
        ));
    }
    Ok(OutlineVerification {
        preexisting_entry_count,
        written_ids,
        title: Some(title),
    })
}

/// Whether the file carries the reader's marked bookmark subtree at all.
///
/// Used only to decide whether a save with an empty annotation **and** bookmark list has
/// anything to do: it may still be the save that removes the subtree an earlier one wrote.
pub(crate) fn has_bookmark_subtree(path: &Path, password: Option<&str>) -> Result<bool> {
    let document = load_document(path, password)?;
    let catalog = catalog_id(&document)?;
    let view = OutlineView {
        old: &document,
        new: &document,
    };
    let root = outline_root(&document, catalog)?;
    Ok(root.children(&view).iter().any(|id| view.is_marker(*id)))
}

/// Reads the reader's marked subtree from a written file, for the sidebar to adopt.
///
/// Returns `Ok(None)` when the file has no marked subtree. This never writes and never fails a
/// caller's outline read: a document whose outline cannot be parsed by lopdf simply has no
/// embedded bookmarks to adopt.
pub fn read_embedded_bookmarks(
    path: &Path,
    password: Option<&str>,
) -> Result<Option<EmbeddedBookmarks>> {
    let document = load_document(path, password)?;
    let catalog = catalog_id(&document)?;
    let view = OutlineView {
        old: &document,
        new: &document,
    };
    let root = outline_root(&document, catalog)?;
    let children = root.children(&view);
    let Some(marker_id) = children.iter().copied().find(|id| view.is_marker(*id)) else {
        return Ok(None);
    };
    let Some(marker_dictionary) = view.dict(marker_id) else {
        return Ok(None);
    };
    let title = raw_title(marker_dictionary)
        .map(|bytes| decode_text_string(&bytes))
        .unwrap_or_else(|| DEFAULT_BOOKMARK_TITLE.to_string());
    let pages = page_ids(&document);
    let mut bookmarks = Vec::new();
    for child in view.children(marker_id) {
        let Some(dictionary) = view.dict(child) else {
            continue;
        };
        let title = raw_title(dictionary)
            .map(|bytes| decode_text_string(&bytes))
            .unwrap_or_default();
        let page = destination_page(&document, dictionary, &pages);
        let id = dictionary
            .get(ID_KEY)
            .ok()
            .and_then(|object| match object {
                Object::String(bytes, _) => Some(decode_text_string(bytes)),
                _ => None,
            })
            .unwrap_or_default();
        let y_pt = page.and_then(|page| {
            let page_id = *pages.get(&(page + 1))?;
            let geometry = page_geometry(&document, page_id).ok()?;
            destination_point_of(&document, dictionary, &pages)
                .map(|point| page_to_view_y(&geometry, point))
        });
        bookmarks.push(EmbeddedBookmark {
            id,
            title,
            page,
            y_pt,
        });
    }
    Ok(Some(EmbeddedBookmarks { title, bookmarks }))
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Outline reading
// ─────────────────────────────────────────────────────────────────────────────────────────────

/// A view over the objects of an incremental save: changed objects come from `new`, every other
/// object still comes from `old`.
struct OutlineView<'a> {
    old: &'a Document,
    new: &'a Document,
}

impl<'a> OutlineView<'a> {
    fn object(&self, id: ObjectId) -> Option<&'a Object> {
        self.new
            .objects
            .get(&id)
            .or_else(|| self.old.objects.get(&id))
    }

    fn dict(&self, id: ObjectId) -> Option<&'a Dictionary> {
        self.object(id).and_then(|object| object.as_dict().ok())
    }

    fn reference(&self, dictionary: &Dictionary, key: &[u8]) -> Option<ObjectId> {
        dictionary
            .get(key)
            .ok()
            .and_then(|object| object.as_reference().ok())
    }

    fn first_child(&self, id: ObjectId) -> Option<ObjectId> {
        self.dict(id)
            .and_then(|dictionary| self.reference(dictionary, b"First"))
    }

    fn next_sibling(&self, id: ObjectId) -> Option<ObjectId> {
        self.dict(id)
            .and_then(|dictionary| self.reference(dictionary, b"Next"))
    }

    /// The document's top-level (or one node's) children, walking `/First` → `/Next` with a
    /// cycle guard. Only indirect children are followed: that is what the writer produces and
    /// what every real producer uses.
    fn children(&self, id: ObjectId) -> Vec<ObjectId> {
        let mut seen = HashSet::new();
        let mut children = Vec::new();
        let mut current = self.first_child(id);
        while let Some(child) = current {
            if !seen.insert(child) {
                break;
            }
            children.push(child);
            current = self.next_sibling(child);
        }
        children
    }

    fn is_marker(&self, id: ObjectId) -> bool {
        self.dict(id)
            .and_then(|dictionary| dictionary.get(MARKER_KEY).ok())
            .and_then(|object| match object {
                Object::String(bytes, _) => Some(decode_text_string(bytes)),
                _ => None,
            })
            .as_deref()
            == Some(MARKER_VALUE)
    }
}

/// Where a document's outline root lives. A producer that wrote the root inline makes it a copy
/// on the first bookmark save; everything the copy references is kept.
enum OutlineRoot<'a> {
    Missing,
    Indirect(ObjectId),
    Direct(&'a Dictionary),
}

impl<'a> OutlineRoot<'a> {
    fn id(&self) -> Option<ObjectId> {
        match self {
            Self::Indirect(id) => Some(*id),
            Self::Missing | Self::Direct(_) => None,
        }
    }

    fn dictionary(&self, view: &OutlineView<'a>) -> Option<&'a Dictionary> {
        match self {
            Self::Indirect(id) => view.dict(*id),
            Self::Direct(dictionary) => Some(dictionary),
            Self::Missing => None,
        }
    }

    fn children(&self, view: &OutlineView<'a>) -> Vec<ObjectId> {
        match self {
            Self::Indirect(id) => view.children(*id),
            Self::Direct(dictionary) => {
                let mut seen = HashSet::new();
                let mut children = Vec::new();
                let mut current = view.reference(dictionary, b"First");
                while let Some(child) = current {
                    if !seen.insert(child) {
                        break;
                    }
                    children.push(child);
                    current = view.next_sibling(child);
                }
                children
            }
            Self::Missing => Vec::new(),
        }
    }
}

fn outline_root<'a>(document: &'a Document, catalog: ObjectId) -> Result<OutlineRoot<'a>> {
    let dictionary = document
        .get_dictionary(catalog)
        .map_err(|error| lopdf_error("the document catalog is not a dictionary", error))?;
    match dictionary.get(b"Outlines") {
        Ok(Object::Reference(id)) => Ok(OutlineRoot::Indirect(*id)),
        Ok(Object::Dictionary(dictionary)) => Ok(OutlineRoot::Direct(dictionary)),
        Ok(_) => Err(LyraReaderError::new(
            ErrorCode::CorruptDocument,
            "the document's /Outlines entry is neither a dictionary nor a reference",
        )),
        Err(_) => Ok(OutlineRoot::Missing),
    }
}

/// A semantic snapshot of one outline node, for the "nothing the document had changed" proof.
#[derive(Clone, Debug, PartialEq)]
struct OutlineNodeView {
    title: Vec<u8>,
    /// The raw `/Dest` and `/A` objects. Object numbers do not change in an incremental save, so
    /// comparing these proves the destination (page reference included) is the same one.
    dest: String,
    action: String,
    page: Option<u32>,
    count: i64,
    children: Vec<OutlineNodeView>,
}

impl OutlineNodeView {
    fn count_nodes(&self) -> usize {
        1 + self.children.iter().map(Self::count_nodes).sum::<usize>()
    }
}

fn existing_nodes(
    view: &OutlineView<'_>,
    root: &OutlineRoot<'_>,
    pages: &std::collections::HashMap<u32, ObjectId>,
) -> Result<Vec<OutlineNodeView>> {
    let pages_by_id: std::collections::HashMap<ObjectId, u32> =
        pages.iter().map(|(index, id)| (*id, index - 1)).collect();
    let mut nodes = Vec::new();
    for child in root.children(view) {
        if view.is_marker(child) {
            continue;
        }
        nodes.push(node_view(view, child, &pages_by_id)?);
    }
    Ok(nodes)
}

fn node_view(
    view: &OutlineView<'_>,
    id: ObjectId,
    pages_by_id: &std::collections::HashMap<ObjectId, u32>,
) -> Result<OutlineNodeView> {
    let mut visited = HashSet::new();
    node_view_inner(view, id, pages_by_id, &mut visited, 0)
}

fn node_view_inner(
    view: &OutlineView<'_>,
    id: ObjectId,
    pages_by_id: &std::collections::HashMap<ObjectId, u32>,
    visited: &mut HashSet<ObjectId>,
    depth: usize,
) -> Result<OutlineNodeView> {
    if depth > MAX_OUTLINE_DEPTH || !visited.insert(id) {
        return Err(LyraReaderError::new(
            ErrorCode::CorruptDocument,
            "the document's outline tree is cyclic or too deep to read",
        ));
    }
    let dictionary = view
        .dict(id)
        .ok_or_else(|| internal("an outline node is not a dictionary"))?;
    ensure_reference_links(dictionary)?;
    let title = raw_title(dictionary).unwrap_or_default();
    let page = destination_page_of(dictionary, view.old, pages_by_id);
    let mut children = Vec::new();
    for child in view.children(id) {
        children.push(node_view_inner(
            view,
            child,
            pages_by_id,
            visited,
            depth + 1,
        )?);
    }
    Ok(OutlineNodeView {
        title,
        dest: format!("{:?}", dictionary.get(b"Dest").ok()),
        action: format!("{:?}", dictionary.get(b"A").ok()),
        page,
        count: integer(dictionary, b"Count").unwrap_or(0),
        children,
    })
}

/// Resolves a node's `/Dest` (or `/A << /S /GoTo /D … >>`) page to a **0-based page index**,
/// using the page tree of the document the dictionary belongs to.
/// Refuses an outline whose child links are inline dictionaries rather than indirect objects.
///
/// The writer appends indirect nodes and can only prove it left a sibling chain intact when it
/// can name every link. Rather than silently orphaning an inline node, such a document is
/// refused; the reader still opens and shows its outline.
fn ensure_reference_links(dictionary: &Dictionary) -> Result<()> {
    for key in [b"First".as_slice(), b"Next".as_slice()] {
        if let Ok(object) = dictionary.get(key)
            && object.as_reference().is_err()
        {
            return Err(LyraReaderError::new(
                ErrorCode::CorruptDocument,
                "the document's outline uses an inline node; bookmarks cannot be merged into it safely",
            )
            .with_detail(format!(
                "/{} is not an indirect reference",
                String::from_utf8_lossy(key)
            )));
        }
    }
    Ok(())
}

fn destination_page(
    document: &Document,
    dictionary: &Dictionary,
    pages: &std::collections::HashMap<u32, ObjectId>,
) -> Option<u32> {
    let pages_by_id: std::collections::HashMap<ObjectId, u32> =
        pages.iter().map(|(index, id)| (*id, index - 1)).collect();
    destination_page_of(dictionary, document, &pages_by_id)
}

fn destination_page_of(
    dictionary: &Dictionary,
    document: &Document,
    pages_by_id: &std::collections::HashMap<ObjectId, u32>,
) -> Option<u32> {
    let destination = dictionary.get(b"Dest").ok().or_else(|| {
        dictionary
            .get(b"A")
            .ok()
            .and_then(|object| resolve(document, object))
            .and_then(|object| object.as_dict().ok())
            .and_then(|action| action.get(b"D").ok())
    })?;
    let array = resolve(document, destination)?.as_array().ok()?;
    let page_id = array.first()?.as_reference().ok()?;
    pages_by_id.get(&page_id).copied()
}

/// The page-space point a node's destination names, when it is a `/XYZ` array. Our writer emits
/// exactly that form; documents that use another form simply have no position to adopt.
fn destination_point_of(
    document: &Document,
    dictionary: &Dictionary,
    pages: &std::collections::HashMap<u32, ObjectId>,
) -> Option<Point> {
    let pages_by_id: std::collections::HashMap<ObjectId, u32> =
        pages.iter().map(|(index, id)| (*id, index - 1)).collect();
    let destination = dictionary.get(b"Dest").ok()?;
    let array = resolve(document, destination)?.as_array().ok()?;
    let page_id = array.first()?.as_reference().ok()?;
    if !pages_by_id.contains_key(&page_id) {
        return None;
    }
    if array.get(1).and_then(|object| object.as_name().ok()) != Some(b"XYZ".as_slice()) {
        return None;
    }
    let x = number(array.get(2))?;
    let y = number(array.get(3))?;
    Some(Point::new(x, y))
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Outline mutation
// ─────────────────────────────────────────────────────────────────────────────────────────────

/// Makes the document's outline root an indirect object (creating it when the document has no
/// outline at all) and returns its object number.
fn ensure_outline_root(
    incremental: &mut IncrementalDocument,
    catalog: ObjectId,
) -> Result<ObjectId> {
    incremental
        .opt_clone_object_to_new_document(catalog)
        .map_err(|error| lopdf_error("could not copy the document catalog", error))?;
    let outlines = incremental
        .new_document
        .get_dictionary(catalog)
        .map_err(|error| lopdf_error("the document catalog is not a dictionary", error))?
        .get(b"Outlines")
        .ok()
        .cloned();
    let root_id = match outlines {
        Some(Object::Reference(id)) => {
            incremental
                .opt_clone_object_to_new_document(id)
                .map_err(|error| lopdf_error("could not copy the outline root", error))?;
            id
        }
        Some(Object::Dictionary(dictionary)) => {
            let id = add_object(
                &mut incremental.new_document,
                Object::Dictionary(dictionary),
            );
            set_catalog_outlines(&mut incremental.new_document, catalog, id)?;
            id
        }
        Some(other) => {
            return Err(LyraReaderError::new(
                ErrorCode::CorruptDocument,
                "the document's /Outlines entry is neither a dictionary nor a reference",
            )
            .with_detail(format!("{other:?}")));
        }
        None => {
            let mut dictionary = Dictionary::new();
            dictionary.set("Type", Object::Name(b"Outlines".to_vec()));
            let id = add_object(
                &mut incremental.new_document,
                Object::Dictionary(dictionary),
            );
            set_catalog_outlines(&mut incremental.new_document, catalog, id)?;
            id
        }
    };
    Ok(root_id)
}

fn set_catalog_outlines(
    document: &mut Document,
    catalog: ObjectId,
    outlines: ObjectId,
) -> Result<()> {
    document
        .get_dictionary_mut(catalog)
        .map_err(|error| lopdf_error("the document catalog is not a dictionary", error))?
        .set("Outlines", Object::Reference(outlines));
    Ok(())
}

/// Appends a newly created marker node to the end of the outline's top-level chain.
fn append_marker(
    incremental: &mut IncrementalDocument,
    root_id: ObjectId,
    marker_id: ObjectId,
) -> Result<()> {
    let last_id = {
        let view = OutlineView {
            old: incremental.get_prev_documents(),
            new: &incremental.new_document,
        };
        view.children(root_id).last().copied()
    };
    if let Some(last_id) = last_id {
        incremental
            .opt_clone_object_to_new_document(last_id)
            .map_err(|error| lopdf_error("could not copy the last outline node", error))?;
        incremental
            .new_document
            .get_dictionary_mut(last_id)
            .map_err(|error| lopdf_error("the last outline node is not a dictionary", error))?
            .set("Next", Object::Reference(marker_id));
        incremental
            .new_document
            .get_dictionary_mut(marker_id)
            .map_err(|error| lopdf_error("the bookmark subtree root is missing", error))?
            .set("Prev", Object::Reference(last_id));
        incremental
            .new_document
            .get_dictionary_mut(root_id)
            .map_err(|error| lopdf_error("the outline root is not a dictionary", error))?
            .set("Last", Object::Reference(marker_id));
    } else {
        // The document had no outline at all: our node is both the first and the last child.
        let root = incremental
            .new_document
            .get_dictionary_mut(root_id)
            .map_err(|error| lopdf_error("the outline root is not a dictionary", error))?;
        root.set("First", Object::Reference(marker_id));
        root.set("Last", Object::Reference(marker_id));
    }
    Ok(())
}

/// Removes one direct child of the outline root, keeping the surrounding `/Next`/`Prev` chain
/// and the root's `/First`/`/Last` consistent.
fn unlink_child(
    incremental: &mut IncrementalDocument,
    root_id: ObjectId,
    child_id: ObjectId,
) -> Result<()> {
    let (children, position) = {
        let view = OutlineView {
            old: incremental.get_prev_documents(),
            new: &incremental.new_document,
        };
        let children = view.children(root_id);
        let position = children.iter().position(|id| *id == child_id);
        (children, position)
    };
    let Some(position) = position else {
        return Ok(());
    };
    let next = children.get(position + 1).copied();
    let previous = position.checked_sub(1).map(|index| children[index]);
    if let Some(previous) = previous {
        incremental
            .opt_clone_object_to_new_document(previous)
            .map_err(|error| lopdf_error("could not copy the previous outline node", error))?;
        let dictionary = incremental
            .new_document
            .get_dictionary_mut(previous)
            .map_err(|error| lopdf_error("the previous outline node is not a dictionary", error))?;
        match next {
            Some(next) => dictionary.set("Next", Object::Reference(next)),
            None => {
                dictionary.remove(b"Next");
            }
        }
    }
    let root = incremental
        .new_document
        .get_dictionary_mut(root_id)
        .map_err(|error| lopdf_error("the outline root is not a dictionary", error))?;
    if position == 0 {
        match next {
            Some(next) => root.set("First", Object::Reference(next)),
            None => {
                root.remove(b"First");
                root.remove(b"Last");
            }
        }
    }
    if position + 1 == children.len() {
        match previous {
            Some(previous) => root.set("Last", Object::Reference(previous)),
            None => {
                root.remove(b"Last");
            }
        }
    }
    // The removed node itself stays in the file (an incremental save cannot delete an object)
    // but is unreachable from the root, so no viewer shows it.
    Ok(())
}

/// Recomputes the outline root's `/Count` from the visible tree: every top-level node, plus the
/// descendants of every node whose own `/Count` is positive. Existing nodes' own counts are
/// never modified — only the derived root total is.
/// Recomputes the marker's `/Prev` and `/Next` from the root's actual sibling chain.
fn relink_marker(
    incremental: &mut IncrementalDocument,
    root_id: ObjectId,
    marker_id: ObjectId,
) -> Result<()> {
    let (previous, next) = {
        let view = OutlineView {
            old: incremental.get_prev_documents(),
            new: &incremental.new_document,
        };
        let children = view.children(root_id);
        match children.iter().position(|id| *id == marker_id) {
            Some(position) => (
                position.checked_sub(1).map(|index| children[index]),
                children.get(position + 1).copied(),
            ),
            None => (None, None),
        }
    };
    let dictionary = incremental
        .new_document
        .get_dictionary_mut(marker_id)
        .map_err(|error| lopdf_error("the bookmark subtree root is not a dictionary", error))?;
    match previous {
        Some(previous) => dictionary.set("Prev", Object::Reference(previous)),
        None => {
            dictionary.remove(b"Prev");
        }
    }
    match next {
        Some(next) => dictionary.set("Next", Object::Reference(next)),
        None => {
            dictionary.remove(b"Next");
        }
    }
    Ok(())
}

fn refresh_root_count(incremental: &mut IncrementalDocument, root_id: ObjectId) -> Result<()> {
    let count = {
        let view = OutlineView {
            old: incremental.get_prev_documents(),
            new: &incremental.new_document,
        };
        let children = view.children(root_id);
        children
            .iter()
            .map(|child| 1 + open_descendants(&view, *child))
            .sum::<i64>()
    };
    incremental
        .new_document
        .get_dictionary_mut(root_id)
        .map_err(|error| lopdf_error("the outline root is not a dictionary", error))?
        .set("Count", Object::Integer(count));
    Ok(())
}

fn open_descendants(view: &OutlineView<'_>, id: ObjectId) -> i64 {
    open_descendants_at(view, id, 0)
}

fn open_descendants_at(view: &OutlineView<'_>, id: ObjectId, depth: usize) -> i64 {
    if depth > MAX_OUTLINE_DEPTH {
        return 0;
    }
    let Some(dictionary) = view.dict(id) else {
        return 0;
    };
    if integer(dictionary, b"Count").unwrap_or(0) <= 0 {
        return 0;
    }
    view.children(id)
        .iter()
        .map(|child| 1 + open_descendants_at(view, *child, depth + 1))
        .sum()
}

fn root_visible_count(view: &OutlineView<'_>, root: &OutlineRoot<'_>) -> i64 {
    root.children(view)
        .iter()
        .map(|child| 1 + open_descendants(view, *child))
        .sum()
}

/// The fixed context every child of one subtree is verified against.
struct BookmarkNodeContext<'a> {
    view: &'a OutlineView<'a>,
    document: &'a Document,
    pages: &'a std::collections::HashMap<u32, ObjectId>,
    marker_id: ObjectId,
    siblings: &'a [ObjectId],
}

/// Checks the outline root's `/First`/`/Last` and our marker's `/Prev`/`/Next` against the
/// sibling chain a reader actually walks.
fn verify_root_chain(
    view: &OutlineView<'_>,
    root: &OutlineRoot<'_>,
    marker_id: ObjectId,
    root_id: ObjectId,
) -> Result<()> {
    let Some(root_dictionary) = root.dictionary(view) else {
        return Err(internal("the outline root is missing"));
    };
    let children = root.children(view);
    let Some(position) = children.iter().position(|id| *id == marker_id) else {
        return Err(internal(
            "the bookmark subtree is not a child of the outline root",
        ));
    };
    let first = root_dictionary
        .get(b"First")
        .ok()
        .and_then(|object| object.as_reference().ok());
    let last = root_dictionary
        .get(b"Last")
        .ok()
        .and_then(|object| object.as_reference().ok());
    if first != children.first().copied() || last != children.last().copied() {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the outline root's /First or /Last does not match its sibling chain",
        )
        .with_detail(format!(
            "root {root_id:?}: First {first:?}, Last {last:?}; chain {:?}",
            (children.first(), children.last())
        )));
    }
    let marker_dictionary = view
        .dict(marker_id)
        .ok_or_else(|| internal("the bookmark subtree root is missing"))?;
    let previous = marker_dictionary
        .get(b"Prev")
        .ok()
        .and_then(|object| object.as_reference().ok());
    let next = marker_dictionary
        .get(b"Next")
        .ok()
        .and_then(|object| object.as_reference().ok());
    let expected_previous = position.checked_sub(1).map(|index| children[index]);
    let expected_next = children.get(position + 1).copied();
    if previous != expected_previous || next != expected_next {
        return Err(internal(
            "the bookmark subtree's /Prev or /Next does not match its siblings",
        ));
    }
    if marker_dictionary
        .get(b"Parent")
        .ok()
        .and_then(|object| object.as_reference().ok())
        != Some(root_id)
    {
        return Err(internal(
            "the bookmark subtree's /Parent is not the outline root",
        ));
    }
    Ok(())
}

fn verify_bookmark_node(
    context: &BookmarkNodeContext<'_>,
    id: ObjectId,
    expected: &WriteBookmark,
    index: usize,
) -> Result<()> {
    let BookmarkNodeContext {
        view,
        document,
        pages,
        marker_id,
        siblings,
    } = context;
    let marker_id = *marker_id;
    let dictionary = view
        .dict(id)
        .ok_or_else(|| internal("a written bookmark is not a dictionary"))?;
    let title = raw_title(dictionary)
        .map(|bytes| decode_text_string(&bytes))
        .unwrap_or_default();
    if title != display_title(expected) {
        return Err(
            internal("a written bookmark has the wrong title").with_detail(format!(
                "expected {:?}, found {title:?}",
                display_title(expected)
            )),
        );
    }
    if dictionary
        .get(b"Parent")
        .ok()
        .and_then(|object| object.as_reference().ok())
        != Some(marker_id)
    {
        return Err(internal(
            "a written bookmark's /Parent is not the subtree root",
        ));
    }
    let identity = dictionary
        .get(ID_KEY)
        .ok()
        .and_then(|object| match object {
            Object::String(bytes, _) => Some(decode_text_string(bytes)),
            _ => None,
        })
        .unwrap_or_default();
    if identity != expected.id {
        return Err(internal("a written bookmark's identity changed")
            .with_detail(format!("expected {:?}, found {identity:?}", expected.id)));
    }
    let previous = dictionary
        .get(b"Prev")
        .ok()
        .and_then(|object| object.as_reference().ok());
    let next = dictionary
        .get(b"Next")
        .ok()
        .and_then(|object| object.as_reference().ok());
    let expected_previous = index.checked_sub(1).map(|i| siblings[i]);
    let expected_next = siblings.get(index + 1).copied();
    if previous != expected_previous || next != expected_next {
        return Err(internal(
            "a written bookmark's /Prev or /Next does not form the expected chain",
        ));
    }
    let Some(page) = destination_page(document, dictionary, pages) else {
        return Err(
            internal("a written bookmark's /Dest does not resolve to a page object")
                .with_detail(expected.id.clone()),
        );
    };
    if page != expected.page.get() {
        return Err(
            internal("a written bookmark points at the wrong page").with_detail(format!(
                "{}: expected {}, found {}",
                expected.id,
                expected.page.get(),
                page
            )),
        );
    }
    let Some(point) = destination_point_of(document, dictionary, pages) else {
        return Err(internal("a written bookmark has no /XYZ destination"));
    };
    let page_id = pages[&(expected.page.get() + 1)];
    let geometry = page_geometry(document, page_id)?;
    let expected_point = destination_point(&geometry, expected.y_pt)?;
    if (point.x - expected_point.x).abs() > 0.01 || (point.y - expected_point.y).abs() > 0.01 {
        return Err(
            internal("a written bookmark points at the wrong position").with_detail(format!(
                "{}: expected ({:.3}, {:.3}), found ({:.3}, {:.3})",
                expected.id, expected_point.x, expected_point.y, point.x, point.y
            )),
        );
    }
    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Geometry and small helpers
// ─────────────────────────────────────────────────────────────────────────────────────────────

fn catalog_id(document: &Document) -> Result<ObjectId> {
    document
        .trailer
        .get(b"Root")
        .ok()
        .and_then(|object| object.as_reference().ok())
        .ok_or_else(|| internal("the document has no /Root catalog reference"))
}

/// 1-based page number → page object, as lopdf reports the page tree.
fn page_ids(document: &Document) -> std::collections::HashMap<u32, ObjectId> {
    document.get_pages().into_iter().collect()
}

/// The page-local Y (0 at the page top) a page-space point maps to.
fn page_to_view_y(geometry: &PageGeometry, point: Point) -> f64 {
    let height = geometry.view_size(1.0).height;
    geometry.page_to_view(1.0).apply(point).y.clamp(0.0, height)
}

/// The page-space destination for a bookmark's page-local Y.
fn destination_point(geometry: &PageGeometry, y_pt: f64) -> Result<Point> {
    let height = geometry.view_size(1.0).height;
    let y = if y_pt.is_finite() {
        y_pt.clamp(0.0, height)
    } else {
        return Err(LyraReaderError::new(
            ErrorCode::InvalidArgument,
            "a bookmark has a non-finite page position",
        ));
    };
    geometry
        .view_to_page(1.0)
        .map(|transform| transform.apply(Point::new(0.0, y)))
        .ok_or_else(|| internal("the page geometry is not invertible"))
}

/// Reads the page box, rotation and `/UserUnit` the reader's coordinate system uses.
///
/// Boxes and `/Rotate` are inheritable page attributes; the walk follows `/Parent` so a page
/// that inherits its box gets the same geometry PDFium reports for it.
fn page_geometry(document: &Document, page_id: ObjectId) -> Result<PageGeometry> {
    let media = inherited_rect(document, page_id, b"MediaBox")
        .or_else(|| inherited_rect(document, page_id, b"CropBox"))
        .ok_or_else(|| {
            LyraReaderError::new(
                ErrorCode::CorruptDocument,
                "a page has no /MediaBox or /CropBox, so a bookmark cannot be placed on it",
            )
            .with_detail(format!("page object {page_id:?}"))
        })?;
    let crop = inherited_rect(document, page_id, b"CropBox").unwrap_or(media);
    let rotation = Rotation::from_degrees(
        inherited(document, page_id, b"Rotate")
            .and_then(|object| number(Some(&object)))
            .unwrap_or(0.0) as i32,
    );
    let user_unit = inherited(document, page_id, b"UserUnit")
        .and_then(|object| number(Some(&object)))
        .filter(|unit| unit.is_finite() && *unit > 0.0)
        .unwrap_or(1.0);
    Ok(PageGeometry::new(media, crop, rotation, user_unit))
}

fn inherited(document: &Document, page_id: ObjectId, key: &[u8]) -> Option<Object> {
    let mut current = page_id;
    let mut seen = HashSet::new();
    for _ in 0..MAX_OUTLINE_DEPTH {
        if !seen.insert(current) {
            break;
        }
        let dictionary = document.get_dictionary(current).ok()?;
        if let Ok(object) = dictionary.get(key)
            && !matches!(object, Object::Null)
        {
            return Some(resolve(document, object)?.clone());
        }
        current = dictionary.get(b"Parent").ok()?.as_reference().ok()?;
    }
    None
}

fn inherited_rect(document: &Document, page_id: ObjectId, key: &[u8]) -> Option<Rect> {
    let object = inherited(document, page_id, key)?;
    let array = object.as_array().ok()?;
    if array.len() < 4 {
        return None;
    }
    let left = number(array.first())?;
    let bottom = number(array.get(1))?;
    let right = number(array.get(2))?;
    let top = number(array.get(3))?;
    let width = (right - left).abs();
    let height = (top - bottom).abs();
    if width <= 0.0 || height <= 0.0 {
        return None;
    }
    Some(Rect::new(left.min(right), bottom.min(top), width, height))
}

fn resolve<'a>(document: &'a Document, object: &'a Object) -> Option<&'a Object> {
    let mut current = object;
    for _ in 0..32 {
        match current {
            Object::Reference(id) => current = document.get_object(*id).ok()?,
            _ => return Some(current),
        }
    }
    None
}

fn raw_title(dictionary: &Dictionary) -> Option<Vec<u8>> {
    match dictionary.get(b"Title").ok()? {
        Object::String(bytes, _) => Some(bytes.clone()),
        _ => None,
    }
}

fn integer(dictionary: &Dictionary, key: &[u8]) -> Option<i64> {
    match dictionary.get(key).ok()? {
        Object::Integer(value) => Some(*value),
        Object::Real(value) if value.is_finite() => Some(*value as i64),
        _ => None,
    }
}

fn number(object: Option<&Object>) -> Option<f64> {
    match object? {
        Object::Integer(value) => Some(*value as f64),
        Object::Real(value) if value.is_finite() => Some(f64::from(*value)),
        _ => None,
    }
}

fn display_title(bookmark: &WriteBookmark) -> String {
    if bookmark.title.is_empty() {
        format!("Page {}", bookmark.page.get() + 1)
    } else {
        bookmark.title.clone()
    }
}

/// Chooses the closest title not already used by a top-level node owned by someone else.
fn choose_title(used: &HashSet<String>) -> String {
    if !used.contains(DEFAULT_BOOKMARK_TITLE) {
        return DEFAULT_BOOKMARK_TITLE.to_string();
    }
    let mut candidate = format!("{DEFAULT_BOOKMARK_TITLE} (LyraReader)");
    if !used.contains(&candidate) {
        return candidate;
    }
    for number in 2..1_000 {
        candidate = format!("{DEFAULT_BOOKMARK_TITLE} (LyraReader {number})");
        if !used.contains(&candidate) {
            return candidate;
        }
    }
    format!(
        "{DEFAULT_BOOKMARK_TITLE} (LyraReader {})",
        std::process::id()
    )
}

fn add_object(document: &mut Document, object: Object) -> ObjectId {
    let id = (document.max_id + 1, 0);
    document.max_id = id.0;
    document.objects.insert(id, object);
    id
}

fn load_document(path: &Path, password: Option<&str>) -> Result<Document> {
    let options = LoadOptions {
        password: password.map(str::to_owned),
        ..LoadOptions::default()
    };
    Document::load_with_options(path, options).map_err(|error| match error {
        lopdf::Error::InvalidPassword => {
            LyraReaderError::new(ErrorCode::Encrypted, "the document is password protected")
                .with_detail(format!("path: {}", path.display()))
        }
        _ => LyraReaderError::new(
            ErrorCode::CorruptDocument,
            "could not read the document to edit its outline",
        )
        .with_detail(format!("path: {} → {error}", path.display())),
    })
}

fn internal(message: impl Into<String>) -> LyraReaderError {
    LyraReaderError::new(ErrorCode::Internal, message)
}

fn lopdf_error(action: &str, error: lopdf::Error) -> LyraReaderError {
    LyraReaderError::new(ErrorCode::Io, action).with_detail(error.to_string())
}

fn io_error(action: &str, path: &Path, error: std::io::Error) -> LyraReaderError {
    LyraReaderError::new(ErrorCode::Io, action).with_detail(format!("{}: {error}", path.display()))
}
