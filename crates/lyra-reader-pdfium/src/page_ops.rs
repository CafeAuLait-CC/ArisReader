//! Page operations on a **copy** of a PDF: rotate, delete, reorder, insert blank, extract, merge
//! and split.
//!
//! # Why this uses PDFium's C ABI directly
//!
//! `pdfium-render` covers rendering and page geometry, but the editing calls this feature needs
//! (`FPDFPage_SetRotation`, `FPDFPage_Delete`, `FPDF_MovePages`, `FPDFPage_New`,
//! `FPDF_ImportPagesByIndex`, `FPDF_SaveAsCopy`) are either not wrapped or wrapped without a
//! mutating document handle. The module therefore resolves the edit symbols from the same
//! dynamic library the backend already loads. Every call happens under
//! [`PDFIUM_LOCK`](crate::backend::PDFIUM_LOCK), exactly like the annotation reader/writer.
//!
//! # The safety model in one paragraph
//!
//! The source file is **read into memory** and never modified. The operation is applied to that
//! in-memory copy, saved into a temporary file, reopened and verified, and only then renamed into
//! the destination. A copy destination is never the source; replacing a destination writes a
//! byte-identical backup first. This is the same contract as
//! [`crate::writeback::save_annotated_pdf`], and the file-handling half is literally the same
//! code ([`writeback::write_rewritten_pdf`]).
//!
//! # Page maps
//!
//! Every report carries `page_map`: `page_map[old] = Some(new)` for a page that survived and
//! `None` for a page that was deleted (or not selected by an extraction). The shell uses it to
//! remap the reader's sidecar annotations and bookmarks. Embedded PDF annotations are handled by
//! PDFium: moving a page moves its annotation dictionary with it, deleting a page deletes its
//! annotations, and importing pages copies them. The tests assert that, because it is the kind
//! of behaviour a viewer must not assume from a page-tree edit.
//!
//! # Merge and split
//!
//! [`merge_documents`] appends every page of one or more other PDFs to the first document and
//! writes a new file. [`split_pages`] extracts several disjoint selections into separate files.
//! Both use the same verified write path as every other page operation: the input is read into
//! memory, each output is built in a temporary file beside its destination, flushed and fsynced,
//! reopened and checked, and only then renamed. The inputs are never modified.
//!
//! **Outline rule.** A merge keeps the first document's outline exactly as it was (its page
//! numbers do not move because pages are appended), and does **not** import the other documents'
//! outlines: PDFium's page-import call copies page dictionaries, not a document-level bookmark
//! tree, and inventing destinations for another author's outline would be worse than leaving it
//! out. [`MergeReport::dropped_outline_entries`] counts what was left out so the shell can say
//! so. A split keeps no outline in any output for the same reason: the source outline's
//! destinations refer to pages that may be in a different output; the shell's sidecar bookmarks
//! are remapped per output instead.
//!
//! **Sidecar rule.** The reader's own annotations/bookmarks live outside this module, in a
//! sidecar keyed by page index. Merge only appends, so the first document's pages keep their
//! indices and every existing mark keeps pointing at its page; the appended pages are new
//! indices with no sidecar marks, because this app has no sidecar for the other documents (their
//! file-owned annotations do travel with them). Split outputs are renumbered, so the shell
//! remaps the sidecar per output.
//!
//! **Split failure model.** The whole plan is validated before anything is written (indices,
//! overlapping outputs, destinations). Outputs are then written one at a time, each with its own
//! temporary file and atomic rename. If output *k* fails, outputs 1…*k*−1 are already complete
//! and verified and are left in place; output *k* is not renamed (its temporary is removed);
//! later outputs are not attempted; the source is unchanged. The split is therefore **not** one
//! transaction across files — it is a sequence of atomic, verified steps, and the error says how
//! many files were completed.
//!
//! # Rotation
//!
//! Page rotation is `/Rotate`, not baked-in geometry. Rotating a page rotates its content and
//! its annotations at display time. [`PageOperation::SetRotation`] takes explicit values because
//! "reset to the file's original rotation" is a property of the file the session started from,
//! which this module cannot recover after earlier edits; the shell keeps the per-page original
//! values and passes them back.
//!
//! # What this module refuses
//!
//! * Deleting every page: a PDF must keep at least one.
//! * Page indices outside the document, duplicate indices, empty selections.
//! * Password-protected documents (PDFium's re-save of an encrypted document cannot be verified
//!   without the password and may drop encryption; refusing is safer than writing an output the
//!   caller cannot check). This includes PDFs that open with an empty user password: they are
//!   detected through `FPDF_GetSecurityHandlerRevision`, not only through a supplied password.
//! * Merging a document into itself, merging the same file twice, and any output that would
//!   overwrite one of the inputs.
//! * A split plan with an empty part, a page named twice (within one part or across parts), or
//!   two outputs at the same path.
//! * Any operation whose verified output does not have the expected page count, rotations,
//!   page sizes (and, for merge/split, page text and file-owned annotations). The destination
//!   is then untouched (and a backup, if one was made, still exists).
//!
//! # Threading
//!
//! [`RawDocument`] owns one `FPDF_DOCUMENT` and takes the process-wide lock for each call. A
//! document handle is never used without the lock. Drop closes it under the lock as well.

#![allow(unsafe_code)]

use crate::annotations::AnnotationReader;
use crate::backend::{PDFIUM_LOCK, PdfiumBackend};
use crate::writeback::{OutputMode, RewrittenOutput, write_rewritten_pdf};
use libloading::Library;
use lyra_reader_core::{
    DocumentBackend, ErrorCode, LyraReaderError, OutlineNode, PageIndex, RawAnnotation, Result,
};
use std::collections::HashSet;
use std::ffi::{CString, c_char, c_int, c_uint, c_ulong, c_void};
use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// `FPDF_NO_INCREMENTAL` (`fpdf_save.h`). A page edit rewrites the document; appending cannot
/// express a deletion or a reorder. The output is still written only to a temporary file and
/// verified before the rename.
const SAVE_NO_INCREMENTAL: c_uint = 2;

type FpdfDocument = *mut c_void;
type FpdfPage = *mut c_void;

/// One page operation, with pages as 0-based indices into the **source** document.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PageOperation {
    /// Add `quarter_turns` × 90° clockwise to each page (negative turns anticlockwise).
    Rotate { pages: Vec<u32>, quarter_turns: i32 },
    /// Set each page's `/Rotate` to an explicit number of quarter turns (0–3).
    ///
    /// `quarter_turns` has one entry per entry in `pages`. The shell uses this to reset a page
    /// to the rotation the original file had.
    SetRotation {
        pages: Vec<u32>,
        quarter_turns: Vec<u32>,
    },
    /// Delete pages. At least one page must remain.
    Delete { pages: Vec<u32> },
    /// Move `pages` (in the given order, inserted as a block) so the first lands at
    /// `destination`. `destination` is an index in the document **after** the pages are
    /// removed, which is what `FPDF_MovePages` expects.
    Move { pages: Vec<u32>, destination: u32 },
    /// Insert one blank page at `index`, with the visible size of its neighbour.
    InsertBlank { index: u32 },
}

/// What an operation did, in terms the shell can act on.
#[derive(Clone, Debug, PartialEq)]
pub struct PageOperationReport {
    pub destination: PathBuf,
    /// Page count of the written file.
    pub page_count: u32,
    /// `page_map[old] = Some(new)` for surviving pages, `None` for removed/not-extracted ones.
    pub page_map: Vec<Option<u32>>,
    /// `/Rotate` of every written page, as quarter turns (0–3).
    pub rotations: Vec<u32>,
    /// View size of every written page, in points.
    pub page_sizes: Vec<(f64, f64)>,
    /// The new blank page's index, for [`PageOperation::InsertBlank`].
    pub inserted_page: Option<u32>,
    /// The verified backup of the replaced destination, when one was made.
    pub backup_path: Option<PathBuf>,
    /// Bytes of the written file.
    pub output_bytes: u64,
    /// Stale `.lyra-reader-save-*.tmp` files removed before writing.
    pub cleaned_temporaries: usize,
}

/// One output of [`split_pages`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SplitPart {
    /// Where this part is written.
    pub destination: PathBuf,
    /// 0-based pages from the source. The engine sorts them ascending and refuses duplicates;
    /// pages may not appear in two parts.
    pub pages: Vec<u32>,
}

/// What [`split_pages`] wrote for one part.
#[derive(Clone, Debug, PartialEq)]
pub struct SplitPartReport {
    pub destination: PathBuf,
    pub page_count: u32,
    /// The source pages this output carries, in output order (0-based).
    pub source_pages: Vec<u32>,
    /// `/Rotate` of every written page, as quarter turns (0–3).
    pub rotations: Vec<u32>,
    /// View size of every written page, in points.
    pub page_sizes: Vec<(f64, f64)>,
    pub output_bytes: u64,
}

/// What [`split_pages`] did.
///
/// The parts are returned in the caller's order. On error, the report is not returned; the
/// error's detail says how many complete outputs were left in place.
#[derive(Clone, Debug, PartialEq)]
pub struct SplitReport {
    pub parts: Vec<SplitPartReport>,
    pub source_page_count: u32,
    pub cleaned_temporaries: usize,
}

/// What [`merge_documents`] did.
#[derive(Clone, Debug, PartialEq)]
pub struct MergeReport {
    pub destination: PathBuf,
    /// Page count of the written file: the sum of every input's page count.
    pub page_count: u32,
    /// Pages the first document contributed.
    pub first_page_count: u32,
    /// Pages each appended document contributed, in the order the caller named them.
    pub appended_page_counts: Vec<u32>,
    /// File-owned content annotations on the appended pages, per appended document.
    ///
    /// They are copied with their pages; the verification compares every appended page's
    /// annotation list with its source page.
    pub appended_annotation_counts: Vec<usize>,
    /// `/Rotate` of every written page, as quarter turns (0–3).
    pub rotations: Vec<u32>,
    /// View size of every written page, in points.
    pub page_sizes: Vec<(f64, f64)>,
    /// Flattened outline entries the first document had and the output kept.
    pub first_outline_entries: usize,
    /// Flattened outline entries in the other documents that were **not** imported.
    pub dropped_outline_entries: usize,
    pub output_bytes: u64,
    pub cleaned_temporaries: usize,
}

/// Applies `operation` to a copy of `source` and writes the result to `destination`.
///
/// Never modifies `source`. If `destination` already exists and is not `source`, it is replaced
/// only after the rewritten document has been verified; this is a copy action, not a command to
/// replace the original.
pub fn apply_page_operation(
    source: &Path,
    destination: &Path,
    operation: &PageOperation,
    password: Option<&str>,
) -> Result<PageOperationReport> {
    apply_page_operation_with_mode(source, destination, operation, password, OutputMode::Copy)
}

/// Creates an internal page-edit revision, retaining the original's signature evidence for the
/// session's read-only policy. This is not a user export: publish it with `publish_edited_copy`
/// to remove invalid signature material before the file becomes a deliverable.
pub fn stage_page_operation(
    source: &Path,
    destination: &Path,
    operation: &PageOperation,
    password: Option<&str>,
) -> Result<PageOperationReport> {
    apply_page_operation_with_mode(
        source,
        destination,
        operation,
        password,
        OutputMode::WorkingRevision,
    )
}

fn apply_page_operation_with_mode(
    source: &Path,
    destination: &Path,
    operation: &PageOperation,
    password: Option<&str>,
    mode: OutputMode,
) -> Result<PageOperationReport> {
    reject_password(password)?;
    let api = api()?;
    let document = open_editable(api, source, "the document being edited")?;
    let page_count = document.page_count();
    let rotations = document.rotations()?;
    let sizes = document.sizes()?;
    let expected = plan(operation, page_count, &rotations, &sizes)?;

    // Mutate only after every page index has been validated, so no rejected request can leave
    // the in-memory copy half-changed (it could not damage the source anyway, but an error
    // should also mean "nothing happened").
    match operation {
        PageOperation::Rotate {
            pages,
            quarter_turns,
        } => document.rotate(pages, *quarter_turns)?,
        PageOperation::SetRotation {
            pages,
            quarter_turns,
        } => document.set_rotation(pages, quarter_turns)?,
        PageOperation::Delete { pages } => document.delete(pages)?,
        PageOperation::Move { pages, destination } => document.move_pages(pages, *destination)?,
        PageOperation::InsertBlank { index } => {
            let neighbour = expected.neighbour_size.expect("insert plan has a size");
            document.insert_blank(*index, neighbour)?;
        }
    }

    let rewritten = write_rewritten_pdf(
        source,
        destination,
        mode,
        |file| document.save(file),
        |path| {
            verify_output(
                path,
                expected.rotations.len() as u32,
                &expected.rotations,
                &expected.sizes,
            )
        },
    )?;

    Ok(report_from(
        rewritten,
        expected.page_map,
        expected.rotations,
        expected.sizes,
        expected.inserted_page,
    ))
}

/// Extracts `pages` from `source` into a new PDF at `destination`.
///
/// Importing pages with `FPDF_ImportPagesByIndex` copies each page's annotations and links with
/// it. The source is never touched.
pub fn extract_pages(
    source: &Path,
    destination: &Path,
    pages: &[u32],
    password: Option<&str>,
) -> Result<PageOperationReport> {
    reject_password(password)?;
    let api = api()?;
    let document = open_editable(api, source, "the document being extracted")?;
    let page_count = document.page_count();
    let rotations = document.rotations()?;
    let sizes = document.sizes()?;
    let selected = validate_pages(pages, page_count, "extract")?;
    if selected.is_empty() {
        return Err(LyraReaderError::new(
            ErrorCode::InvalidArgument,
            "select at least one page to extract",
        ));
    }

    let imported = RawDocument::new_document(api)?;
    imported.import_pages(&document, &selected, 0)?;

    let mut page_map = vec![None; page_count as usize];
    for (new, old) in selected.iter().enumerate() {
        page_map[*old as usize] = Some(new as u32);
    }
    let expected_rotations: Vec<u32> = selected
        .iter()
        .map(|old| rotations[*old as usize])
        .collect();
    let expected_sizes: Vec<PageSize> = selected.iter().map(|old| sizes[*old as usize]).collect();

    let rewritten = write_rewritten_pdf(
        source,
        destination,
        OutputMode::Copy,
        |file| imported.save(file),
        |path| {
            verify_output(
                path,
                expected_rotations.len() as u32,
                &expected_rotations,
                &expected_sizes,
            )
        },
    )?;

    Ok(report_from(
        rewritten,
        page_map,
        expected_rotations,
        expected_sizes,
        None,
    ))
}

/// Appends every page of `others` to `source` and writes the result to `destination`.
///
/// The first document's pages keep their indices; every other document's pages follow in the
/// order given. The source and every appended document are never modified, and the output may
/// not be any of them. The result is verified before its atomic rename: page count, rotations,
/// sizes, per-page text, per-page file-owned annotations, and the first document's outline.
///
/// What happens to the second document's outline, and to the reader's sidecar, is documented at
/// the top of this module. In short: its outline is not imported (and is counted in the report),
/// its embedded annotations travel, and the first document's sidecar marks keep their page
/// indices because nothing before the appended pages moves.
pub fn merge_documents(
    source: &Path,
    others: &[PathBuf],
    destination: &Path,
    password: Option<&str>,
) -> Result<MergeReport> {
    reject_password(password)?;
    if others.is_empty() {
        return Err(LyraReaderError::new(
            ErrorCode::InvalidArgument,
            "choose at least one document whose pages should be appended",
        ));
    }
    let source = canonical_input(source, "the document to append to")?;
    let mut inputs = vec![source.clone()];
    for other in others {
        let other = canonical_input(other, "a document being appended")?;
        if same_file(&other, &source) {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "a document cannot be merged into itself; choose a different file",
            )
            .with_detail(other.display().to_string()));
        }
        if inputs.iter().any(|input| same_file(input, &other)) {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "the same document was selected to be appended twice",
            )
            .with_detail(other.display().to_string()));
        }
        inputs.push(other);
    }
    let destination_resolved = canonical_output(destination)?;
    for input in &inputs {
        if same_file(&destination_resolved, input) {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "the merged output would overwrite one of its input documents; choose a new file",
            )
            .with_detail(input.display().to_string()));
        }
    }

    let api = api()?;
    let merged = open_editable(api, &source, "the document to append to")?;
    let first_page_count = merged.page_count();
    if first_page_count == 0 {
        return Err(empty_document_error(&source));
    }
    let mut expected_rotations = merged.rotations()?;
    let mut expected_sizes = merged.sizes()?;
    let mut expected_texts = page_texts(&source)?;
    let mut expected_annotations = page_annotations(&source)?;
    let first_outline = outline_signature(&source)?;
    let mut appended_page_counts = Vec::with_capacity(others.len());
    let mut appended_annotation_counts = Vec::with_capacity(others.len());
    let mut dropped_outline_entries = 0usize;

    for other in inputs.iter().skip(1) {
        let appended = open_editable(api, other, "a document being appended")?;
        let count = appended.page_count();
        if count == 0 {
            return Err(empty_document_error(other));
        }
        let pages: Vec<u32> = (0..count).collect();
        merged.import_pages(&appended, &pages, merged.page_count())?;
        expected_rotations.extend(appended.rotations()?);
        expected_sizes.extend(appended.sizes()?);
        expected_texts.extend(page_texts(other)?);
        let annotations = page_annotations(other)?;
        appended_annotation_counts.push(annotations.iter().map(Vec::len).sum::<usize>());
        expected_annotations.extend(annotations);
        appended_page_counts.push(count);
        dropped_outline_entries += outline_signature(other)?.len();
    }

    let page_count = expected_rotations.len() as u32;
    let first_outline_entries = first_outline.len();
    let rotations_for_report = expected_rotations.clone();
    let sizes_for_report = expected_sizes.clone();
    let rewritten = write_rewritten_pdf(
        &source,
        destination,
        OutputMode::Copy,
        |file| merged.save(file),
        |path| {
            verify_output(path, page_count, &expected_rotations, &expected_sizes)?;
            verify_text_pages(path, &expected_texts)?;
            verify_annotation_pages(path, &expected_annotations)?;
            verify_outline(path, &first_outline)?;
            Ok(())
        },
    )?;

    Ok(MergeReport {
        destination: rewritten.destination,
        page_count,
        first_page_count,
        appended_page_counts,
        appended_annotation_counts,
        rotations: rotations_for_report,
        page_sizes: sizes_for_report
            .into_iter()
            .map(|size| (size.width, size.height))
            .collect(),
        first_outline_entries,
        dropped_outline_entries,
        output_bytes: rewritten.output_bytes,
        cleaned_temporaries: rewritten.cleaned_temporaries,
    })
}

/// Splits `source` into `parts`, each written atomically to its own destination.
///
/// A part's pages are sorted ascending and must not overlap with another part's; parts may leave
/// source pages out (that is what makes "1–5, 6–10" valid on an eleven-page document). All
/// destinations are validated before the first output is built, so a bad plan writes nothing.
///
/// # Failure model
///
/// Each output is an independent verified atomic write. If a later output fails, the earlier
/// outputs are complete, verified files that stay in place; the failed output's temporary file is
/// removed and later outputs are not attempted. The error's message says how many outputs were
/// completed. The source is never modified. There is no rollback of the completed outputs,
/// because they are valid deliverables, not half-written state.
pub fn split_pages(
    source: &Path,
    parts: &[SplitPart],
    password: Option<&str>,
) -> Result<SplitReport> {
    reject_password(password)?;
    if parts.is_empty() {
        return Err(LyraReaderError::new(
            ErrorCode::InvalidArgument,
            "choose at least two pages or at least one range to split",
        ));
    }
    let source = canonical_input(source, "the document being split")?;
    let api = api()?;
    let document = open_editable(api, &source, "the document being split")?;
    let page_count = document.page_count();
    if page_count == 0 {
        return Err(empty_document_error(&source));
    }
    let rotations = document.rotations()?;
    let sizes = document.sizes()?;
    let texts = page_texts(&source)?;
    let annotations = page_annotations(&source)?;

    let mut seen_pages = HashSet::new();
    let mut seen_destinations: Vec<PathBuf> = Vec::with_capacity(parts.len());
    let mut validated: Vec<(PathBuf, Vec<u32>)> = Vec::with_capacity(parts.len());
    for (index, part) in parts.iter().enumerate() {
        let pages = validate_split_pages(&part.pages, page_count, index, parts.len())?;
        for page in &pages {
            if !seen_pages.insert(*page) {
                return Err(LyraReaderError::new(
                    ErrorCode::InvalidArgument,
                    format!(
                        "page {} appears in more than one split output; a page can only be written once",
                        page + 1
                    ),
                ));
            }
        }
        let destination = canonical_output(&part.destination)?;
        if same_file(&destination, &source) {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "a split output would overwrite the document being split; choose new files",
            )
            .with_detail(destination.display().to_string()));
        }
        if seen_destinations
            .iter()
            .any(|seen| seen == &destination || same_file(seen, &destination))
        {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "two split outputs point at the same file; each part needs its own name",
            )
            .with_detail(destination.display().to_string()));
        }
        seen_destinations.push(destination.clone());
        validated.push((destination, pages));
    }

    let mut written_parts = Vec::with_capacity(validated.len());
    let mut cleaned_temporaries = 0usize;
    for (index, (destination, pages)) in validated.iter().enumerate() {
        let imported = RawDocument::new_document(api)?;
        imported.import_pages(&document, pages, 0)?;
        let expected_rotations: Vec<u32> =
            pages.iter().map(|page| rotations[*page as usize]).collect();
        let expected_sizes: Vec<PageSize> =
            pages.iter().map(|page| sizes[*page as usize]).collect();
        let expected_texts: Vec<String> = pages
            .iter()
            .map(|page| texts[*page as usize].clone())
            .collect();
        let expected_annotations: Vec<Vec<RawAnnotation>> = pages
            .iter()
            .map(|page| annotations[*page as usize].clone())
            .collect();
        let result = write_rewritten_pdf(
            &source,
            destination,
            OutputMode::Copy,
            |file| imported.save(file),
            |path| {
                verify_output(
                    path,
                    pages.len() as u32,
                    &expected_rotations,
                    &expected_sizes,
                )?;
                verify_text_pages(path, &expected_texts)?;
                verify_annotation_pages(path, &expected_annotations)?;
                Ok(())
            },
        );
        match result {
            Ok(output) => {
                cleaned_temporaries += output.cleaned_temporaries;
                written_parts.push(SplitPartReport {
                    destination: output.destination,
                    page_count: pages.len() as u32,
                    source_pages: pages.clone(),
                    rotations: expected_rotations,
                    page_sizes: expected_sizes
                        .into_iter()
                        .map(|size| (size.width, size.height))
                        .collect(),
                    output_bytes: output.output_bytes,
                });
            }
            Err(error) => {
                return Err(split_output_error(
                    error,
                    index,
                    validated.len(),
                    written_parts.len(),
                ));
            }
        }
    }

    Ok(SplitReport {
        parts: written_parts,
        source_page_count: page_count,
        cleaned_temporaries,
    })
}

/// Publishes the current page-edit revision as a new file, without applying another operation.
///
/// This is "save the edited copy": the source revision is not modified and `destination` must not
/// be the revision. The copy is written to a temporary file, reopened and verified to have the
/// same page count, rotations and sizes, and only then renamed into place.
pub fn publish_edited_copy(
    source: &Path,
    destination: &Path,
    expected_page_count: u32,
) -> Result<PageOperationReport> {
    publish_without_operation(source, destination, expected_page_count, OutputMode::Copy)
}

/// Replaces `original` with the current page-edit revision.
///
/// This is the explicitly destructive choice. A byte-identical backup of `original` is written
/// and verified first; the revision is copied into a temporary file beside it, verified, and only
/// then renamed over it. A failure leaves the original exactly as it was.
pub fn replace_original_with_edit(
    source: &Path,
    original: &Path,
    expected_page_count: u32,
) -> Result<PageOperationReport> {
    publish_without_operation(
        source,
        original,
        expected_page_count,
        OutputMode::ReplaceDestination,
    )
}

fn publish_without_operation(
    source: &Path,
    destination: &Path,
    expected_page_count: u32,
    mode: OutputMode,
) -> Result<PageOperationReport> {
    let (rotations, sizes) = properties(source)?;
    if rotations.len() as u32 != expected_page_count {
        return Err(LyraReaderError::new(
            ErrorCode::InvalidArgument,
            "the edited revision no longer has the page count the editor saw",
        )
        .with_detail(format!(
            "expected {expected_page_count}, found {}",
            rotations.len()
        )));
    }
    let page_map = (0..rotations.len() as u32).map(Some).collect();
    let rewritten = write_rewritten_pdf(
        source,
        destination,
        mode,
        |file| {
            let mut input = File::open(source)
                .map_err(|error| io_error("could not reopen the edited revision", source, error))?;
            std::io::copy(&mut input, file).map_err(|error| {
                io_error("could not copy the edited revision", destination, error)
            })?;
            Ok(())
        },
        |path| verify_output(path, expected_page_count, &rotations, &sizes),
    )?;
    Ok(report_from(rewritten, page_map, rotations, sizes, None))
}

fn properties(path: &Path) -> Result<(Vec<u32>, Vec<PageSize>)> {
    let backend = PdfiumBackend::open(path, None)?;
    let count = backend.page_count();
    let mut rotations = Vec::with_capacity(count as usize);
    let mut sizes = Vec::with_capacity(count as usize);
    for index in 0..count {
        let info = backend.page_info(PageIndex(index))?;
        rotations.push((info.geometry.rotation.degrees().rem_euclid(360) / 90) as u32);
        let view = info.geometry.view_size(1.0);
        sizes.push(PageSize {
            width: view.width,
            height: view.height,
        });
    }
    Ok((rotations, sizes))
}

/// The plan for one operation: everything the writer promises the verifier it will find.
struct Expectation {
    page_map: Vec<Option<u32>>,
    rotations: Vec<u32>,
    sizes: Vec<PageSize>,
    inserted_page: Option<u32>,
    /// Size for an inserted blank page, or `None` when this is not an insertion.
    neighbour_size: Option<PageSize>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct PageSize {
    width: f64,
    height: f64,
}

impl PageSize {
    fn swapped(self) -> Self {
        Self {
            width: self.height,
            height: self.width,
        }
    }

    fn close(self, other: Self) -> bool {
        (self.width - other.width).abs() <= 1.0 && (self.height - other.height).abs() <= 1.0
    }
}

fn plan(
    operation: &PageOperation,
    page_count: u32,
    rotations: &[u32],
    sizes: &[PageSize],
) -> Result<Expectation> {
    let identity = || (0..page_count).map(Some).collect::<Vec<_>>();
    match operation {
        PageOperation::Rotate {
            pages,
            quarter_turns,
        } => {
            let pages = validate_pages(pages, page_count, "rotation")?;
            let delta = quarter_turns.rem_euclid(4);
            let mut expected_rotations = rotations.to_vec();
            let mut expected_sizes = sizes.to_vec();
            for page in pages {
                let old = expected_rotations[page as usize];
                expected_rotations[page as usize] = (old + delta as u32) % 4;
                if delta % 2 == 1 {
                    expected_sizes[page as usize] = expected_sizes[page as usize].swapped();
                }
            }
            Ok(Expectation {
                page_map: identity(),
                rotations: expected_rotations,
                sizes: expected_sizes,
                inserted_page: None,
                neighbour_size: None,
            })
        }
        PageOperation::SetRotation {
            pages,
            quarter_turns,
        } => {
            if pages.len() != quarter_turns.len() {
                return Err(LyraReaderError::new(
                    ErrorCode::InvalidArgument,
                    "each page being reset needs exactly one rotation value",
                ));
            }
            let mut pairs: Vec<(u32, u32)> = pages
                .iter()
                .copied()
                .zip(quarter_turns.iter().map(|value| value % 4))
                .collect();
            if pairs.is_empty() {
                return Err(LyraReaderError::new(
                    ErrorCode::InvalidArgument,
                    "select at least one page to reset",
                ));
            }
            pairs.sort_unstable();
            for window in pairs.windows(2) {
                if window[0].0 == window[1].0 {
                    return Err(LyraReaderError::new(
                        ErrorCode::InvalidArgument,
                        "a page was named twice in one rotation request",
                    ));
                }
            }
            for (page, _) in &pairs {
                if *page >= page_count {
                    return Err(page_out_of_range(*page, page_count));
                }
            }
            let mut expected_rotations = rotations.to_vec();
            let mut expected_sizes = sizes.to_vec();
            for (page, new_rotation) in pairs {
                let old = expected_rotations[page as usize];
                expected_rotations[page as usize] = new_rotation;
                if old % 2 != new_rotation % 2 {
                    expected_sizes[page as usize] = expected_sizes[page as usize].swapped();
                }
            }
            Ok(Expectation {
                page_map: identity(),
                rotations: expected_rotations,
                sizes: expected_sizes,
                inserted_page: None,
                neighbour_size: None,
            })
        }
        PageOperation::Delete { pages } => {
            let deleted = validate_pages(pages, page_count, "deletion")?;
            if deleted.len() as u32 >= page_count {
                return Err(LyraReaderError::new(
                    ErrorCode::InvalidArgument,
                    "a PDF must keep at least one page; every page was selected for deletion",
                ));
            }
            let removed: std::collections::HashSet<u32> = deleted.iter().copied().collect();
            let survivors: Vec<u32> = (0..page_count)
                .filter(|page| !removed.contains(page))
                .collect();
            let mut page_map = vec![None; page_count as usize];
            for (new, old) in survivors.iter().enumerate() {
                page_map[*old as usize] = Some(new as u32);
            }
            Ok(Expectation {
                page_map,
                rotations: survivors
                    .iter()
                    .map(|page| rotations[*page as usize])
                    .collect(),
                sizes: survivors.iter().map(|page| sizes[*page as usize]).collect(),
                inserted_page: None,
                neighbour_size: None,
            })
        }
        PageOperation::Move { pages, destination } => {
            let moving = validate_pages(pages, page_count, "move")?;
            if moving.is_empty() {
                return Err(LyraReaderError::new(
                    ErrorCode::InvalidArgument,
                    "select at least one page to move",
                ));
            }
            let moving_set: std::collections::HashSet<u32> = moving.iter().copied().collect();
            let mut rest: Vec<u32> = (0..page_count)
                .filter(|page| !moving_set.contains(page))
                .collect();
            if *destination as usize > rest.len() {
                return Err(LyraReaderError::new(
                    ErrorCode::InvalidArgument,
                    format!(
                        "page {} cannot be the destination: only {} page(s) remain after removing the moved pages",
                        *destination + 1,
                        rest.len()
                    ),
                ));
            }
            let insert_at = *destination as usize;
            rest.splice(insert_at..insert_at, moving.iter().copied());
            let order = rest;
            let mut page_map = vec![None; page_count as usize];
            for (new, old) in order.iter().enumerate() {
                page_map[*old as usize] = Some(new as u32);
            }
            Ok(Expectation {
                page_map,
                rotations: order.iter().map(|page| rotations[*page as usize]).collect(),
                sizes: order.iter().map(|page| sizes[*page as usize]).collect(),
                inserted_page: None,
                neighbour_size: None,
            })
        }
        PageOperation::InsertBlank { index } => {
            if *index > page_count {
                return Err(LyraReaderError::new(
                    ErrorCode::InvalidArgument,
                    format!(
                        "cannot insert a page at {}, the document has {} page(s)",
                        index + 1,
                        page_count
                    ),
                ));
            }
            // The blank page takes the visible size of the page before it, or of the first page
            // when inserting at the front, or US Letter for an empty document.
            let neighbour_size = if page_count == 0 {
                PageSize {
                    width: 612.0,
                    height: 792.0,
                }
            } else if *index > 0 {
                sizes[(*index - 1) as usize]
            } else {
                sizes[0]
            };
            let mut expected_rotations = Vec::with_capacity(page_count as usize + 1);
            let mut expected_sizes = Vec::with_capacity(page_count as usize + 1);
            let mut page_map = vec![None; page_count as usize];
            for old in 0..page_count {
                if old == *index {
                    expected_rotations.push(0);
                    expected_sizes.push(neighbour_size);
                }
                expected_rotations.push(rotations[old as usize]);
                expected_sizes.push(sizes[old as usize]);
                page_map[old as usize] = Some(if old < *index { old } else { old + 1 });
            }
            if *index == page_count {
                expected_rotations.push(0);
                expected_sizes.push(neighbour_size);
            }
            Ok(Expectation {
                page_map,
                rotations: expected_rotations,
                sizes: expected_sizes,
                inserted_page: Some(*index),
                neighbour_size: Some(neighbour_size),
            })
        }
    }
}

fn page_out_of_range(page: u32, page_count: u32) -> LyraReaderError {
    LyraReaderError::new(
        ErrorCode::InvalidArgument,
        format!(
            "page {} is outside the document ({} page(s))",
            page + 1,
            page_count
        ),
    )
}

/// Sorts and deduplicates a page selection, refusing empty and out-of-range requests.
fn validate_pages(pages: &[u32], page_count: u32, what: &str) -> Result<Vec<u32>> {
    if pages.is_empty() {
        return Err(LyraReaderError::new(
            ErrorCode::InvalidArgument,
            format!("select at least one page for {what}"),
        ));
    }
    let mut unique = pages.to_vec();
    unique.sort_unstable();
    unique.dedup();
    for page in &unique {
        if *page >= page_count {
            return Err(page_out_of_range(*page, page_count));
        }
    }
    Ok(unique)
}

fn reject_password(password: Option<&str>) -> Result<()> {
    if password.is_some() {
        return Err(LyraReaderError::new(
            ErrorCode::UnsupportedFeature,
            "page operations on a password-protected document are not supported; the document was left untouched",
        ));
    }
    Ok(())
}

/// Resolves a file that an operation reads, refusing a missing or non-regular input.
fn canonical_input(path: &Path, what: &str) -> Result<PathBuf> {
    let resolved = fs::canonicalize(path)
        .map_err(|error| io_error("could not resolve the document", path, error))?;
    if !resolved.is_file() {
        return Err(LyraReaderError::new(
            ErrorCode::NotFound,
            format!("{what} is not a regular file"),
        )
        .with_detail(path.display().to_string()));
    }
    Ok(resolved)
}

/// Resolves a destination the same way [`writeback::write_rewritten_pdf`] will, without
/// requiring the destination itself to exist yet.
fn canonical_output(path: &Path) -> Result<PathBuf> {
    if path.exists() {
        return fs::canonicalize(path)
            .map_err(|error| io_error("could not resolve the destination", path, error));
    }
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let parent = fs::canonicalize(parent)
        .map_err(|error| io_error("the destination directory does not exist", path, error))?;
    let name = path.file_name().ok_or_else(|| {
        LyraReaderError::new(
            ErrorCode::InvalidArgument,
            "the destination has no file name",
        )
        .with_detail(path.display().to_string())
    })?;
    Ok(parent.join(name))
}

/// Whether two existing paths name the same directory entry (canonical path or hard link).
fn same_file(left: &Path, right: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        match (fs::metadata(left), fs::metadata(right)) {
            (Ok(left), Ok(right)) => left.dev() == right.dev() && left.ino() == right.ino(),
            _ => false,
        }
    }
    #[cfg(not(unix))]
    {
        match (fs::canonicalize(left), fs::canonicalize(right)) {
            (Ok(left), Ok(right)) => left == right,
            _ => false,
        }
    }
}

/// Opens a document for a page operation, with a readable refusal for encrypted files.
///
/// `PdfiumBackend::open` distinguishes "needs a password" from "corrupt", but a PDF encrypted
/// with an **empty user password** opens without one. The security-handler revision is the only
/// reliable signal in that case, so it is checked on the loaded raw document as well.
fn open_editable(api: &'static PageApi, path: &Path, role: &str) -> Result<RawDocument> {
    let bytes = read_source(path)?;
    let document = match RawDocument::load(api, bytes, None) {
        Ok(document) => document,
        Err(error) => {
            return match PdfiumBackend::open(path, None) {
                Ok(_) => Err(error),
                Err(backend_error) if backend_error.code == ErrorCode::Encrypted => {
                    Err(encrypted_refusal(role, path))
                }
                Err(backend_error) => Err(backend_error),
            };
        }
    };
    if document.security_revision() >= 0 {
        return Err(encrypted_refusal(role, path));
    }
    Ok(document)
}

fn encrypted_refusal(role: &str, path: &Path) -> LyraReaderError {
    LyraReaderError::new(
        ErrorCode::Encrypted,
        format!(
            "{role} is password-protected; encrypted documents cannot be merged or split and no output was written"
        ),
    )
    .with_detail(path.display().to_string())
}

fn empty_document_error(path: &Path) -> LyraReaderError {
    LyraReaderError::new(
        ErrorCode::CorruptDocument,
        "a document with no pages cannot be merged or split",
    )
    .with_detail(path.display().to_string())
}

/// Sorts a split part's pages and refuses empty, duplicate and out-of-range selections.
fn validate_split_pages(
    pages: &[u32],
    page_count: u32,
    part_index: usize,
    part_count: usize,
) -> Result<Vec<u32>> {
    if pages.is_empty() {
        return Err(LyraReaderError::new(
            ErrorCode::InvalidArgument,
            format!(
                "split output {} of {part_count} selects no pages",
                part_index + 1
            ),
        ));
    }
    let mut unique = pages.to_vec();
    unique.sort_unstable();
    for window in unique.windows(2) {
        if window[0] == window[1] {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                format!(
                    "page {} is selected twice in split output {} of {part_count}",
                    window[0] + 1,
                    part_index + 1
                ),
            ));
        }
    }
    for page in &unique {
        if *page >= page_count {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                format!(
                    "page {} is outside the document ({} page(s))",
                    page + 1,
                    page_count
                ),
            ));
        }
    }
    Ok(unique)
}

/// Adds the split failure model to a per-output error: what is complete and what was not tried.
fn split_output_error(
    error: LyraReaderError,
    failed_index: usize,
    part_count: usize,
    completed: usize,
) -> LyraReaderError {
    let completed = if completed == 0 {
        "no output was completed".to_string()
    } else {
        format!("{completed} earlier output(s) are complete and verified and stay in place")
    };
    LyraReaderError::new(
        error.code,
        format!(
            "split output {} of {part_count} failed; {completed}; the source is unchanged; later outputs were not attempted",
            failed_index + 1
        ),
    )
    .with_detail(error.to_string())
}

/// Every page's text, in page order, built from the character boxes the engine reports.
///
/// Matches the test helper this module already uses; it works for rotated pages, where the
/// higher-level `text.all()` representation can come back empty.
fn page_texts(path: &Path) -> Result<Vec<String>> {
    let backend = PdfiumBackend::open(path, None)?;
    (0..backend.page_count())
        .map(|page| {
            let raw = backend.raw_text_page(PageIndex(page))?;
            Ok(raw
                .chars
                .iter()
                .filter_map(|character| char::from_u32(character.unicode))
                .collect())
        })
        .collect()
}

/// Every page's file-owned content annotations, in page order.
fn page_annotations(path: &Path) -> Result<Vec<Vec<RawAnnotation>>> {
    let backend = PdfiumBackend::open(path, None)?;
    let count = backend.page_count();
    drop(backend);
    let reader = AnnotationReader::open(path, None)?;
    let mut pages = Vec::with_capacity(count as usize);
    for page in 0..count {
        let records = {
            let _guard = PDFIUM_LOCK
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            reader.page_locked(PageIndex(page))?
        };
        pages.push(records);
    }
    Ok(pages)
}

fn verify_text_pages(path: &Path, expected: &[String]) -> Result<()> {
    let actual = page_texts(path)?;
    if actual.len() != expected.len() {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the rewritten document does not have the expected page count",
        )
        .with_detail(format!(
            "expected {} page(s), reopened {}",
            expected.len(),
            actual.len()
        )));
    }
    for (page, (expected, actual)) in expected.iter().zip(actual.iter()).enumerate() {
        if expected != actual {
            return Err(LyraReaderError::new(
                ErrorCode::Internal,
                "a rewritten page's text does not match its source page",
            )
            .with_detail(format!(
                "page {}: expected {} character(s), reopened {}",
                page + 1,
                expected.chars().count(),
                actual.chars().count()
            )));
        }
    }
    Ok(())
}

/// Annotation records read from a different page carry that page in `page`; compare content only.
fn normalized_annotations(mut records: Vec<RawAnnotation>) -> Vec<RawAnnotation> {
    for record in &mut records {
        record.page = PageIndex(0);
    }
    records
}

fn verify_annotation_pages(path: &Path, expected: &[Vec<RawAnnotation>]) -> Result<()> {
    let actual = page_annotations(path)?;
    if actual.len() != expected.len() {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the rewritten document does not have the expected page count",
        )
        .with_detail(format!(
            "expected {} page(s), reopened {}",
            expected.len(),
            actual.len()
        )));
    }
    for (page, (expected, actual)) in expected.iter().zip(actual.iter()).enumerate() {
        if normalized_annotations(expected.clone()) != normalized_annotations(actual.clone()) {
            return Err(LyraReaderError::new(
                ErrorCode::Internal,
                "a rewritten page's file-owned annotations do not match its source page",
            )
            .with_detail(format!(
                "page {}: expected {} annotation(s), reopened {}",
                page + 1,
                expected.len(),
                actual.len()
            )));
        }
    }
    Ok(())
}

/// A flattened outline: title, target page and depth. Enough to prove structure and destinations
/// survived, while ignoring destination view coordinates PDFium may normalise.
fn outline_signature(path: &Path) -> Result<Vec<(String, Option<u32>, usize)>> {
    let backend = PdfiumBackend::open(path, None)?;
    let nodes = backend.outline()?;
    let mut flattened = Vec::new();
    flatten_outline(&nodes, 0, &mut flattened);
    Ok(flattened)
}

fn flatten_outline(
    nodes: &[OutlineNode],
    depth: usize,
    flattened: &mut Vec<(String, Option<u32>, usize)>,
) {
    for node in nodes {
        flattened.push((node.title.clone(), node.page.map(|page| page.get()), depth));
        flatten_outline(&node.children, depth + 1, flattened);
    }
}

fn verify_outline(path: &Path, expected: &[(String, Option<u32>, usize)]) -> Result<()> {
    let actual = outline_signature(path)?;
    if actual != expected {
        let first_difference = actual
            .iter()
            .zip(expected.iter())
            .position(|(actual, expected)| actual != expected)
            .unwrap_or_else(|| actual.len().min(expected.len()));
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the merged document's outline does not match the first document's outline",
        )
        .with_detail(format!(
            "expected {} entr(ies), reopened {}; first difference at entry {}: expected {:?}, reopened {:?}",
            expected.len(),
            actual.len(),
            first_difference + 1,
            expected.get(first_difference),
            actual.get(first_difference)
        )));
    }
    Ok(())
}

fn read_source(source: &Path) -> Result<Vec<u8>> {
    let metadata = fs::metadata(source)
        .map_err(|error| io_error("could not read the document being edited", source, error))?;
    if !metadata.is_file() {
        return Err(LyraReaderError::new(
            ErrorCode::NotFound,
            "the document being edited is not a regular file",
        )
        .with_detail(source.display().to_string()));
    }
    if metadata.len() > i32::MAX as u64 {
        return Err(LyraReaderError::new(
            ErrorCode::UnsupportedFeature,
            "the document is too large to edit in memory",
        )
        .with_detail(format!("{} bytes", metadata.len())));
    }
    fs::read(source)
        .map_err(|error| io_error("could not read the document being edited", source, error))
}

fn report_from(
    output: RewrittenOutput,
    page_map: Vec<Option<u32>>,
    rotations: Vec<u32>,
    page_sizes: Vec<PageSize>,
    inserted_page: Option<u32>,
) -> PageOperationReport {
    PageOperationReport {
        destination: output.destination,
        page_count: rotations.len() as u32,
        page_map,
        rotations,
        page_sizes: page_sizes
            .into_iter()
            .map(|size| (size.width, size.height))
            .collect(),
        inserted_page,
        backup_path: output.backup_path,
        output_bytes: output.output_bytes,
        cleaned_temporaries: output.cleaned_temporaries,
    }
}

/// Reopens the written file and checks the properties the operation promises.
fn verify_output(
    path: &Path,
    expected_count: u32,
    expected_rotations: &[u32],
    expected_sizes: &[PageSize],
) -> Result<()> {
    let backend = PdfiumBackend::open(path, None)?;
    let count = backend.page_count();
    if count != expected_count {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the rewritten document does not have the expected page count",
        )
        .with_detail(format!("expected {expected_count}, reopened {count}")));
    }
    for index in 0..expected_count {
        let info = backend.page_info(PageIndex(index))?;
        let rotation = (info.geometry.rotation.degrees().rem_euclid(360) / 90) as u32;
        if rotation != expected_rotations[index as usize] {
            return Err(LyraReaderError::new(
                ErrorCode::Internal,
                "a rewritten page does not have the expected rotation",
            )
            .with_detail(format!(
                "page {}: expected /Rotate {}, reopened {}",
                index + 1,
                expected_rotations[index as usize] * 90,
                rotation * 90
            )));
        }
        let view = info.geometry.view_size(1.0);
        let expected = expected_sizes[index as usize];
        let actual = PageSize {
            width: view.width,
            height: view.height,
        };
        if !actual.close(expected) {
            return Err(LyraReaderError::new(
                ErrorCode::Internal,
                "a rewritten page does not have the expected size",
            )
            .with_detail(format!(
                "page {}: expected {}×{} pt, reopened {}×{} pt",
                index + 1,
                expected.width,
                expected.height,
                actual.width,
                actual.height
            )));
        }
    }
    Ok(())
}

// ── PDFium C ABI ─────────────────────────────────────────────────────────────

/// The edit entry points this module needs. A separate resolver from the annotation writer:
/// a build that can read annotations may not export editing calls, and the failure has to be
/// reported as "this build cannot edit pages" rather than a generic annotation error.
struct PageApi {
    _library: Library,
    load_mem_document: unsafe extern "C" fn(*const c_void, c_int, *const c_char) -> FpdfDocument,
    close_document: unsafe extern "C" fn(FpdfDocument),
    create_new_document: unsafe extern "C" fn() -> FpdfDocument,
    get_page_count: unsafe extern "C" fn(FpdfDocument) -> c_int,
    security_revision: unsafe extern "C" fn(FpdfDocument) -> c_int,
    load_page: unsafe extern "C" fn(FpdfDocument, c_int) -> FpdfPage,
    close_page: unsafe extern "C" fn(FpdfPage),
    page_delete: unsafe extern "C" fn(FpdfDocument, c_int),
    page_new: unsafe extern "C" fn(FpdfDocument, c_int, f64, f64) -> FpdfPage,
    move_pages: unsafe extern "C" fn(FpdfDocument, *const c_int, c_ulong, c_int) -> c_int,
    get_rotation: unsafe extern "C" fn(FpdfPage) -> c_int,
    set_rotation: unsafe extern "C" fn(FpdfPage, c_int),
    get_page_width: unsafe extern "C" fn(FpdfPage) -> f32,
    get_page_height: unsafe extern "C" fn(FpdfPage) -> f32,
    import_pages_by_index:
        unsafe extern "C" fn(FpdfDocument, FpdfDocument, *const c_int, c_ulong, c_int) -> c_int,
    save_as_copy: unsafe extern "C" fn(FpdfDocument, *mut FpdfFileWrite, c_uint) -> c_int,
}

static PAGE_API: OnceLock<Option<&'static PageApi>> = OnceLock::new();

fn api() -> Result<&'static PageApi> {
    PAGE_API
        .get_or_init(|| {
            for candidate in crate::backend::library_candidates() {
                // SAFETY: loading a dynamic library is inherently unsafe. These are the same
                // PDFium paths the backend loads; `resolve` checks every entry point by name.
                let Ok(library) = (unsafe { Library::new(candidate.as_os_str()) }) else {
                    continue;
                };
                // SAFETY: the library at these paths is PDFium, and every signature below is
                // transcribed from the vendored `fpdf_*.h`.
                if let Some(api) = unsafe { resolve(library) } {
                    return Some(&*Box::leak(Box::new(api)));
                }
            }
            None
        })
        .as_ref()
        .copied()
        .ok_or_else(|| {
            LyraReaderError::new(
                ErrorCode::BackendUnavailable,
                "this PDFium build does not export the page-editing API",
            )
            .with_detail(
                "missing one of FPDFPage_SetRotation / FPDFPage_Delete / FPDF_MovePages / FPDFPage_New / FPDF_ImportPagesByIndex / FPDF_SaveAsCopy / FPDF_GetSecurityHandlerRevision",
            )
        })
}

/// Resolves the editing entry points.
///
/// # Safety
///
/// The caller must have loaded a PDFium-compatible library. Getting a signature wrong is
/// undefined behaviour, so each is transcribed from `vendor/pdfium/include/fpdf_edit.h`,
/// `fpdf_ppo.h` and `fpdf_save.h`.
unsafe fn resolve(library: Library) -> Option<PageApi> {
    // SAFETY: same contract as `resolve` in `annotations.rs`; each name is the exported PDFium
    // symbol for the function type declared next to it in `PageApi`.
    unsafe fn symbol<T: Copy>(library: &Library, name: &[u8]) -> Option<T> {
        unsafe { library.get::<T>(name).ok().map(|symbol| *symbol) }
    }

    let api = PageApi {
        load_mem_document: unsafe { symbol(&library, b"FPDF_LoadMemDocument\0")? },
        close_document: unsafe { symbol(&library, b"FPDF_CloseDocument\0")? },
        create_new_document: unsafe { symbol(&library, b"FPDF_CreateNewDocument\0")? },
        get_page_count: unsafe { symbol(&library, b"FPDF_GetPageCount\0")? },
        security_revision: unsafe { symbol(&library, b"FPDF_GetSecurityHandlerRevision\0")? },
        load_page: unsafe { symbol(&library, b"FPDF_LoadPage\0")? },
        close_page: unsafe { symbol(&library, b"FPDF_ClosePage\0")? },
        page_delete: unsafe { symbol(&library, b"FPDFPage_Delete\0")? },
        page_new: unsafe { symbol(&library, b"FPDFPage_New\0")? },
        move_pages: unsafe { symbol(&library, b"FPDF_MovePages\0")? },
        get_rotation: unsafe { symbol(&library, b"FPDFPage_GetRotation\0")? },
        set_rotation: unsafe { symbol(&library, b"FPDFPage_SetRotation\0")? },
        get_page_width: unsafe { symbol(&library, b"FPDF_GetPageWidthF\0")? },
        get_page_height: unsafe { symbol(&library, b"FPDF_GetPageHeightF\0")? },
        import_pages_by_index: unsafe { symbol(&library, b"FPDF_ImportPagesByIndex\0")? },
        save_as_copy: unsafe { symbol(&library, b"FPDF_SaveAsCopy\0")? },
        _library: library,
    };
    Some(api)
}

/// `FPDF_FILEWRITE`, by value. PDFium calls [`write_block`] for every output block.
#[repr(C)]
struct FpdfFileWrite {
    version: c_int,
    write_block: unsafe extern "C" fn(*mut FpdfFileWrite, *const c_void, c_ulong) -> c_int,
}

/// The callback state. `header` must stay first: PDFium hands the same pointer back.
#[repr(C)]
struct FileSink {
    header: FpdfFileWrite,
    file: File,
    failed: bool,
}

/// # Safety
///
/// `this` is the `FPDF_FILEWRITE*` PDFium was given, which is `&mut FileSink.header`; the sink
/// outlives the save call. `data`/`size` describe a readable buffer for the call.
unsafe extern "C" fn write_block(
    this: *mut FpdfFileWrite,
    data: *const c_void,
    size: c_ulong,
) -> c_int {
    if this.is_null() || (data.is_null() && size != 0) {
        return 0;
    }
    // SAFETY: `header` is the first field of `FileSink`, so the cast points at the same object.
    let sink = unsafe { &mut *this.cast::<FileSink>() };
    if sink.failed {
        return 0;
    }
    let bytes = if size == 0 {
        &[][..]
    } else {
        // SAFETY: PDFium provides a buffer of `size` bytes valid for this call.
        unsafe { std::slice::from_raw_parts(data.cast::<u8>(), size as usize) }
    };
    match sink.file.write_all(bytes) {
        Ok(()) => 1,
        Err(_) => {
            sink.failed = true;
            0
        }
    }
}

/// One PDFium document opened from memory, plus the buffer it borrows.
///
/// Keeping the bytes inside the struct is not a convenience: `FPDF_LoadMemDocument` documents
/// that the buffer must stay valid while the document is open, and a page operation keeps the
/// handle alive across save and verification.
struct RawDocument {
    api: &'static PageApi,
    document: FpdfDocument,
    _bytes: Vec<u8>,
}

// SAFETY: every method (and `Drop`) serialises on `PDFIUM_LOCK`, which is what makes it sound to
// move the handle between calls. It is never used concurrently.
unsafe impl Send for RawDocument {}

impl RawDocument {
    fn load(api: &'static PageApi, bytes: Vec<u8>, password: Option<&str>) -> Result<Self> {
        crate::backend::pdfium_instance()?;
        let password = password.map(CString::new).transpose().map_err(|_| {
            LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "the password contains a NUL byte",
            )
        })?;
        let document = {
            let _guard = PDFIUM_LOCK
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            // SAFETY: `bytes` lives in the returned struct and the library is initialised by
            // `pdfium_instance` (called by the backend open path).
            unsafe {
                (api.load_mem_document)(
                    bytes.as_ptr().cast(),
                    bytes.len() as c_int,
                    password
                        .as_ref()
                        .map_or(std::ptr::null(), |value| value.as_ptr()),
                )
            }
        };
        if document.is_null() {
            return Err(LyraReaderError::new(
                ErrorCode::CorruptDocument,
                "PDFium could not open the document for page editing",
            ));
        }
        Ok(Self {
            api,
            document,
            _bytes: bytes,
        })
    }

    fn new_document(api: &'static PageApi) -> Result<Self> {
        // Make sure the library is initialised the same way the rest of the backend does it.
        crate::backend::pdfium_instance()?;
        let document = {
            let _guard = PDFIUM_LOCK
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            // SAFETY: no arguments, returns a new document or null.
            unsafe { (api.create_new_document)() }
        };
        if document.is_null() {
            return Err(LyraReaderError::new(
                ErrorCode::Internal,
                "PDFium could not create a new document for extraction",
            ));
        }
        Ok(Self {
            api,
            document,
            _bytes: Vec::new(),
        })
    }

    fn page_count(&self) -> u32 {
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        // SAFETY: `document` is live.
        unsafe { (self.api.get_page_count)(self.document) }.max(0) as u32
    }

    /// `FPDF_GetSecurityHandlerRevision`: -1 when the PDF carries no encryption dictionary.
    ///
    /// Unlike `PdfiumBackend::is_encrypted` (which records whether a password was supplied),
    /// this detects a document encrypted with an empty user password, which PDFium opens
    /// without asking. That is the case the merge/split refusal must not miss.
    fn security_revision(&self) -> c_int {
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        // SAFETY: `document` is live and the API is documented to accept it.
        unsafe { (self.api.security_revision)(self.document) }
    }

    fn rotations(&self) -> Result<Vec<u32>> {
        let count = self.page_count();
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let mut rotations = Vec::with_capacity(count as usize);
        for index in 0..count {
            // SAFETY: `document` is live and `index` is below the page count.
            let page = unsafe { (self.api.load_page)(self.document, index as c_int) };
            if page.is_null() {
                return Err(page_load_error(index));
            }
            // SAFETY: `page` came from `load_page` and is closed before the next call.
            let rotation = unsafe { (self.api.get_rotation)(page) };
            unsafe { (self.api.close_page)(page) };
            if rotation < 0 {
                return Err(LyraReaderError::new(
                    ErrorCode::RenderFailed,
                    format!("PDFium could not read the rotation of page {}", index + 1),
                ));
            }
            rotations.push((rotation as u32) % 4);
        }
        Ok(rotations)
    }

    fn sizes(&self) -> Result<Vec<PageSize>> {
        let count = self.page_count();
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let mut sizes = Vec::with_capacity(count as usize);
        for index in 0..count {
            // SAFETY: `document` is live and `index` is below the page count.
            let page = unsafe { (self.api.load_page)(self.document, index as c_int) };
            if page.is_null() {
                return Err(page_load_error(index));
            }
            // SAFETY: `page` is live; the accessors take the page only.
            let width = f64::from(unsafe { (self.api.get_page_width)(page) });
            let height = f64::from(unsafe { (self.api.get_page_height)(page) });
            unsafe { (self.api.close_page)(page) };
            if !(width.is_finite() && height.is_finite()) || width <= 0.0 || height <= 0.0 {
                return Err(LyraReaderError::new(
                    ErrorCode::RenderFailed,
                    format!("page {} reports an invalid size", index + 1),
                ));
            }
            sizes.push(PageSize { width, height });
        }
        Ok(sizes)
    }

    fn rotate(&self, pages: &[u32], quarter_turns: i32) -> Result<()> {
        let delta = quarter_turns.rem_euclid(4) as u32;
        if delta == 0 {
            return Ok(());
        }
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        for page_index in pages {
            let page = self.load_page_locked(*page_index)?;
            // SAFETY: `page` is live; the rotation is written before the handle is closed.
            let old = unsafe { (self.api.get_rotation)(page) };
            if old < 0 {
                unsafe { (self.api.close_page)(page) };
                return Err(LyraReaderError::new(
                    ErrorCode::RenderFailed,
                    format!(
                        "PDFium could not read the rotation of page {}",
                        page_index + 1
                    ),
                ));
            }
            let new = (old as u32 + delta) % 4;
            unsafe { (self.api.set_rotation)(page, new as c_int) };
            let written = unsafe { (self.api.get_rotation)(page) };
            unsafe { (self.api.close_page)(page) };
            if written != new as c_int {
                return Err(LyraReaderError::new(
                    ErrorCode::Internal,
                    "PDFium did not keep the requested page rotation",
                )
                .with_detail(format!(
                    "page {}: wanted {new}, read {written}",
                    page_index + 1
                )));
            }
        }
        Ok(())
    }

    fn set_rotation(&self, pages: &[u32], rotations: &[u32]) -> Result<()> {
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        for (page_index, rotation) in pages.iter().zip(rotations) {
            let page = self.load_page_locked(*page_index)?;
            let value = (*rotation % 4) as c_int;
            // SAFETY: `page` is live; the handle is closed after the write.
            unsafe { (self.api.set_rotation)(page, value) };
            let written = unsafe { (self.api.get_rotation)(page) };
            unsafe { (self.api.close_page)(page) };
            if written != value {
                return Err(LyraReaderError::new(
                    ErrorCode::Internal,
                    "PDFium did not keep the requested page rotation",
                )
                .with_detail(format!(
                    "page {}: wanted {value}, read {written}",
                    page_index + 1
                )));
            }
        }
        Ok(())
    }

    fn delete(&self, pages: &[u32]) -> Result<()> {
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        // Descending order: deleting a lower index first would shift the higher ones.
        let mut descending = pages.to_vec();
        descending.sort_unstable_by(|left, right| right.cmp(left));
        for index in descending {
            // SAFETY: `document` is live and `index` was validated against the count.
            unsafe { (self.api.page_delete)(self.document, index as c_int) };
        }
        Ok(())
    }

    fn move_pages(&self, pages: &[u32], destination: u32) -> Result<()> {
        let indices: Vec<c_int> = pages.iter().map(|page| *page as c_int).collect();
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        // SAFETY: `document` is live and `indices` outlives the call; the API copies the list.
        let moved = unsafe {
            (self.api.move_pages)(
                self.document,
                indices.as_ptr(),
                indices.len() as c_ulong,
                destination as c_int,
            )
        };
        if moved == 0 {
            return Err(LyraReaderError::new(
                ErrorCode::RenderFailed,
                "PDFium refused to move the selected pages",
            ));
        }
        Ok(())
    }

    fn insert_blank(&self, index: u32, size: PageSize) -> Result<()> {
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        // SAFETY: `document` is live; width/height are finite and positive (checked by `plan`).
        let page =
            unsafe { (self.api.page_new)(self.document, index as c_int, size.width, size.height) };
        if page.is_null() {
            return Err(LyraReaderError::new(
                ErrorCode::RenderFailed,
                format!("PDFium could not insert a blank page at {}", index + 1),
            ));
        }
        // SAFETY: the new page handle is live and is not used after this point.
        unsafe { (self.api.close_page)(page) };
        Ok(())
    }

    /// Imports `pages` from `source`, inserting them so the first lands at `index`.
    ///
    /// The final `FPDF_ImportPagesByIndex` argument is an insertion index, not "append when 0":
    /// a merge must pass the destination's current page count, or the imported pages land at the
    /// front and every page (and outline destination) shifts.
    fn import_pages(&self, source: &RawDocument, pages: &[u32], index: u32) -> Result<()> {
        let indices: Vec<c_int> = pages.iter().map(|page| *page as c_int).collect();
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        // SAFETY: both documents are live; `indices` outlives the call and PDFium copies it.
        let imported = unsafe {
            (self.api.import_pages_by_index)(
                self.document,
                source.document,
                indices.as_ptr(),
                indices.len() as c_ulong,
                index as c_int,
            )
        };
        if imported == 0 {
            return Err(LyraReaderError::new(
                ErrorCode::RenderFailed,
                "PDFium refused to import the selected pages",
            ));
        }
        Ok(())
    }

    fn save(&self, file: &mut File) -> Result<()> {
        let mut sink = FileSink {
            header: FpdfFileWrite {
                version: 1,
                write_block,
            },
            // The callback writes through a raw pointer to this file. Ownership would be moved
            // and PDFium's callback would then write into a different object, so the sink borrows
            // by reopening the same temporary path instead. That costs one open and keeps the
            // file handle owned by the caller, which flushes and fsyncs it afterwards.
            file: file.try_clone().map_err(|error| {
                LyraReaderError::new(
                    ErrorCode::Io,
                    "could not open the page-edit output for writing",
                )
                .with_detail(error.to_string())
            })?,
            failed: false,
        };
        let ok = {
            let _guard = PDFIUM_LOCK
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            // SAFETY: `document` is live and `sink.header` is the FPDF_FILEWRITE whose callback
            // writes into `sink`. PDFium calls it only during this call.
            unsafe {
                (self.api.save_as_copy)(
                    self.document,
                    std::ptr::addr_of_mut!(sink.header),
                    SAVE_NO_INCREMENTAL,
                )
            }
        };
        if ok == 0 || sink.failed {
            return Err(LyraReaderError::new(
                ErrorCode::RenderFailed,
                "PDFium failed to write the edited document",
            )
            .with_detail(format!("save_as_copy={ok}, write_error={}", sink.failed)));
        }
        sink.file.flush().map_err(|error| {
            LyraReaderError::new(ErrorCode::Io, "could not flush the edited document")
                .with_detail(error.to_string())
        })?;
        Ok(())
    }

    fn load_page_locked(&self, index: u32) -> Result<FpdfPage> {
        // SAFETY: `document` is live and the caller holds `PDFIUM_LOCK`.
        let page = unsafe { (self.api.load_page)(self.document, index as c_int) };
        if page.is_null() {
            return Err(page_load_error(index));
        }
        Ok(page)
    }
}

impl Drop for RawDocument {
    fn drop(&mut self) {
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        // SAFETY: the handle came from `load_mem_document`/`create_new_document` and is closed
        // exactly once, here.
        unsafe { (self.api.close_document)(self.document) };
    }
}

fn page_load_error(index: u32) -> LyraReaderError {
    LyraReaderError::new(
        ErrorCode::RenderFailed,
        format!("PDFium could not load page {} for editing", index + 1),
    )
}

fn io_error(action: &str, path: &Path, error: std::io::Error) -> LyraReaderError {
    LyraReaderError::new(ErrorCode::Io, action).with_detail(format!("{}: {error}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::annotations::AnnotationReader;
    use crate::test_support::scratch;
    use lyra_reader_core::RawAnnotation;

    fn copy_fixture(directory: &Path, name: &str) -> PathBuf {
        crate::test_support::copy_fixture(directory, name, name)
    }

    fn texts(path: &Path) -> Vec<String> {
        let backend = PdfiumBackend::open(path, None).expect("open");
        (0..backend.page_count())
            .map(|page| {
                let raw = backend.raw_text_page(PageIndex(page)).expect("text page");
                // `raw_text_page` reports the character boxes even where pdfium-render's
                // `text.all()` comes back empty (it does for a page with /Rotate 90), so the
                // tests build the string from the characters the engine actually reported.
                raw.chars
                    .iter()
                    .filter_map(|character| char::from_u32(character.unicode))
                    .collect()
            })
            .collect()
    }

    fn sorted_chars(text: &str) -> Vec<char> {
        let mut chars: Vec<char> = text
            .chars()
            .filter(|character| !character.is_whitespace())
            .collect();
        chars.sort_unstable();
        chars
    }

    fn rotations(path: &Path) -> Vec<u32> {
        let backend = PdfiumBackend::open(path, None).expect("open");
        (0..backend.page_count())
            .map(|page| {
                (backend
                    .page_info(PageIndex(page))
                    .expect("page info")
                    .geometry
                    .rotation
                    .degrees()
                    .rem_euclid(360)
                    / 90) as u32
            })
            .collect()
    }

    fn sizes(path: &Path) -> Vec<(f64, f64)> {
        let backend = PdfiumBackend::open(path, None).expect("open");
        (0..backend.page_count())
            .map(|page| {
                let view = backend
                    .page_info(PageIndex(page))
                    .expect("page info")
                    .geometry
                    .view_size(1.0);
                (view.width, view.height)
            })
            .collect()
    }

    fn annotations(path: &Path) -> Vec<Vec<RawAnnotation>> {
        let count = PdfiumBackend::open(path, None).expect("open").page_count();
        let reader = AnnotationReader::open(path, None).expect("annotation reader");
        let mut pages = Vec::with_capacity(count as usize);
        for page in 0..count {
            let records = {
                let _guard = PDFIUM_LOCK
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                reader
                    .page_locked(PageIndex(page))
                    .expect("annotation page")
            };
            pages.push(records);
        }
        drop(reader);
        pages
    }

    /// Annotations are reported with the page they were read from; when comparing "the same
    /// annotation after it moved", normalise that one field so the content is what is compared.
    fn on_page(mut records: Vec<RawAnnotation>, page: u32) -> Vec<RawAnnotation> {
        for record in &mut records {
            record.page = PageIndex(page);
        }
        records
    }

    fn snapshot(directory: &Path, name: &str) -> (PathBuf, Vec<u8>, Vec<String>, usize) {
        let path = copy_fixture(directory, name);
        let backend = PdfiumBackend::open(&path, None).expect("open snapshot");
        let count = backend.page_count();
        drop(backend);
        let bytes = fs::read(&path).expect("read snapshot");
        let texts = texts(&path);
        (path, bytes, texts, count as usize)
    }

    #[test]
    fn rotation_round_trip_and_reset() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("rotate");
        let (source, original_bytes, original_texts, page_count) =
            snapshot(&directory, "multipage.pdf");
        let original_sizes = sizes(&source);
        let rotated = directory.join("rotated.pdf");

        let report = apply_page_operation(
            &source,
            &rotated,
            &PageOperation::Rotate {
                pages: vec![1],
                quarter_turns: 1,
            },
            None,
        )
        .expect("rotate one page");
        assert_eq!(report.page_count, page_count as u32);
        assert_eq!(
            report.page_map,
            (0..page_count as u32).map(Some).collect::<Vec<_>>()
        );
        assert_eq!(report.rotations, {
            let mut expected = vec![0; page_count];
            expected[1] = 1;
            expected
        });
        assert_eq!(
            fs::read(&source).expect("source"),
            original_bytes,
            "a copy operation must not touch its source"
        );

        assert_eq!(rotations(&rotated), {
            let mut expected = vec![0; page_count];
            expected[1] = 1;
            expected
        });
        let rotated_sizes = sizes(&rotated);
        assert!((rotated_sizes[1].0 - original_sizes[1].1).abs() <= 1.0);
        assert!((rotated_sizes[1].1 - original_sizes[1].0).abs() <= 1.0);
        // PDFium's text order follows the rotated content stream: a 90° page comes out in a
        // different character order, so compare the content per page, not the raw sequence.
        let rotated_texts = texts(&rotated);
        assert!(rotated_texts[1].contains("Page 2 of 3"));
        assert_eq!(
            sorted_chars(&rotated_texts[1]),
            sorted_chars(&original_texts[1])
        );
        assert_eq!(rotated_texts[0], original_texts[0]);
        assert_eq!(rotated_texts[2], original_texts[2]);

        // Embedded PDF annotations are page-space geometry, so they rotate with the page and
        // must survive the rewrite unchanged.
        let annotated = copy_fixture(&directory, "annotated.pdf");
        let before = annotations(&annotated);
        let rotated_annotated = directory.join("annotated-rotated.pdf");
        apply_page_operation(
            &annotated,
            &rotated_annotated,
            &PageOperation::Rotate {
                pages: vec![0],
                quarter_turns: 1,
            },
            None,
        )
        .expect("rotate an annotated page");
        let after = annotations(&rotated_annotated);
        assert_eq!(after.len(), before.len());
        for page in 0..before.len() {
            assert_eq!(
                on_page(after[page].clone(), page as u32),
                on_page(before[page].clone(), page as u32),
                "embedded annotations on page {} must survive a rotation",
                page + 1
            );
        }
        assert_eq!(rotations(&rotated_annotated), vec![1, 0]);

        // Reset is an absolute rotation, because the session may have rotated the page before.
        let reset = directory.join("reset.pdf");
        let report = apply_page_operation(
            &rotated,
            &reset,
            &PageOperation::SetRotation {
                pages: vec![1],
                quarter_turns: vec![0],
            },
            None,
        )
        .expect("reset rotation");
        assert_eq!(report.rotations[1], 0);
        assert_eq!(rotations(&reset), vec![0; page_count]);
        assert!((sizes(&reset)[1].0 - original_sizes[1].0).abs() <= 1.0);

        // Anticlockwise wraps: 0 - 1 => 3.
        let anticlockwise = directory.join("anticlockwise.pdf");
        apply_page_operation(
            &source,
            &anticlockwise,
            &PageOperation::Rotate {
                pages: vec![0],
                quarter_turns: -1,
            },
            None,
        )
        .expect("rotate anticlockwise");
        assert_eq!(rotations(&anticlockwise)[0], 3);

        // 180° keeps the view size.
        let half = directory.join("half.pdf");
        apply_page_operation(
            &source,
            &half,
            &PageOperation::Rotate {
                pages: vec![0],
                quarter_turns: 2,
            },
            None,
        )
        .expect("rotate 180");
        assert_eq!(rotations(&half)[0], 2);
        assert!((sizes(&half)[0].0 - original_sizes[0].0).abs() <= 1.0);
        assert!((sizes(&half)[0].1 - original_sizes[0].1).abs() <= 1.0);
    }

    #[test]
    fn delete_round_trip_removes_the_right_pages_and_their_annotations() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("delete");
        let (source, original_bytes, original_texts, _) = snapshot(&directory, "multipage.pdf");
        let deleted = directory.join("deleted.pdf");
        let report = apply_page_operation(
            &source,
            &deleted,
            &PageOperation::Delete { pages: vec![1] },
            None,
        )
        .expect("delete one page");
        assert_eq!(report.page_count as usize, original_texts.len() - 1);
        assert_eq!(report.page_map[1], None);
        assert_eq!(report.page_map[0], Some(0));
        assert_eq!(report.page_map[2], Some(1));
        let remaining = texts(&deleted);
        assert_eq!(remaining[0], original_texts[0]);
        assert_eq!(remaining[1], original_texts[2]);
        assert_eq!(fs::read(&source).expect("source"), original_bytes);

        // The fixture's annotations live two per page: deleting page 0 must delete its six and
        // keep the two on the surviving page, never push them onto a neighbour.
        let annotated = copy_fixture(&directory, "annotated.pdf");
        let before = annotations(&annotated);
        let after_path = directory.join("annotated-deleted.pdf");
        let report = apply_page_operation(
            &annotated,
            &after_path,
            &PageOperation::Delete { pages: vec![0] },
            None,
        )
        .expect("delete annotated page");
        assert_eq!(report.page_map, vec![None, Some(0)]);
        let after = annotations(&after_path);
        assert_eq!(after.len(), 1);
        assert_eq!(
            on_page(after[0].clone(), 0),
            on_page(before[1].clone(), 0),
            "the surviving page's annotations must be exactly the ones it had"
        );
        assert_eq!(texts(&after_path)[0], texts(&annotated)[1]);
    }

    #[test]
    fn reorder_round_trip_keeps_text_and_annotations_with_their_pages() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("reorder");
        let (source, original_bytes, original_texts, _) = snapshot(&directory, "multipage.pdf");
        let reordered = directory.join("reordered.pdf");
        let report = apply_page_operation(
            &source,
            &reordered,
            &PageOperation::Move {
                pages: vec![2],
                destination: 0,
            },
            None,
        )
        .expect("move page 3 to the front");
        assert_eq!(report.page_map[0], Some(1));
        assert_eq!(report.page_map[1], Some(2));
        assert_eq!(report.page_map[2], Some(0));
        let mut expected_texts = original_texts.clone();
        let moved = expected_texts.remove(2);
        expected_texts.insert(0, moved);
        assert_eq!(texts(&reordered), expected_texts);
        assert_eq!(fs::read(&source).expect("source"), original_bytes);

        // A contiguous range move: [1, 2] to index 0.
        let range = directory.join("range.pdf");
        apply_page_operation(
            &source,
            &range,
            &PageOperation::Move {
                pages: vec![1, 2],
                destination: 0,
            },
            None,
        )
        .expect("move a range");
        let mut expected_texts = original_texts.clone();
        let range_texts: Vec<String> = expected_texts.drain(1..=2).collect();
        for (offset, text) in range_texts.into_iter().enumerate() {
            expected_texts.insert(offset, text);
        }
        assert_eq!(texts(&range), expected_texts);

        // Move to the end.
        let end = directory.join("end.pdf");
        apply_page_operation(
            &source,
            &end,
            &PageOperation::Move {
                pages: vec![0],
                destination: 2,
            },
            None,
        )
        .expect("move page 1 to the end");
        let mut expected_texts = original_texts.clone();
        let moved = expected_texts.remove(0);
        expected_texts.push(moved);
        assert_eq!(texts(&end), expected_texts);

        // Annotations travel with their page — the dedicated regression.
        let annotated = copy_fixture(&directory, "annotated.pdf");
        let before = annotations(&annotated);
        let moved_path = directory.join("annotated-moved.pdf");
        apply_page_operation(
            &annotated,
            &moved_path,
            &PageOperation::Move {
                pages: vec![1],
                destination: 0,
            },
            None,
        )
        .expect("move annotated page");
        let after = annotations(&moved_path);
        assert_eq!(after.len(), 2);
        assert_eq!(
            on_page(after[0].clone(), 0),
            on_page(before[1].clone(), 0),
            "page 2's annotations moved to page 1"
        );
        assert_eq!(
            on_page(after[1].clone(), 1),
            on_page(before[0].clone(), 1),
            "page 1's annotations moved to page 2"
        );
        assert_eq!(texts(&moved_path), {
            let mut expected = texts(&annotated);
            expected.swap(0, 1);
            expected
        });
    }

    #[test]
    fn insert_blank_round_trip_matches_the_neighbours_size() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("insert");
        let (source, original_bytes, original_texts, _) = snapshot(&directory, "multipage.pdf");
        let original_sizes = sizes(&source);
        let inserted = directory.join("inserted.pdf");
        let report = apply_page_operation(
            &source,
            &inserted,
            &PageOperation::InsertBlank { index: 1 },
            None,
        )
        .expect("insert blank page");
        assert_eq!(report.inserted_page, Some(1));
        assert_eq!(report.page_count as usize, original_texts.len() + 1);
        assert_eq!(report.page_map[0], Some(0));
        assert_eq!(report.page_map[1], Some(2));
        assert_eq!(report.rotations[1], 0);
        let after_texts = texts(&inserted);
        assert_eq!(after_texts.len(), original_texts.len() + 1);
        assert!(
            after_texts[1].trim().is_empty(),
            "the inserted page is blank"
        );
        assert_eq!(after_texts[0], original_texts[0]);
        assert_eq!(after_texts[2], original_texts[1]);
        let after_sizes = sizes(&inserted);
        assert!((after_sizes[1].0 - original_sizes[0].0).abs() <= 1.0);
        assert!((after_sizes[1].1 - original_sizes[0].1).abs() <= 1.0);
        assert_eq!(fs::read(&source).expect("source"), original_bytes);

        // At the front the neighbour is the old first page, and the old pages shift right.
        let front = directory.join("front.pdf");
        apply_page_operation(
            &source,
            &front,
            &PageOperation::InsertBlank { index: 0 },
            None,
        )
        .expect("insert blank at the front");
        let front_sizes = sizes(&front);
        assert!((front_sizes[0].0 - original_sizes[0].0).abs() <= 1.0);
        assert_eq!(texts(&front)[1], original_texts[0]);

        // At the end the neighbour is the old last page.
        let end = directory.join("end.pdf");
        let last = original_texts.len() as u32;
        apply_page_operation(
            &source,
            &end,
            &PageOperation::InsertBlank { index: last },
            None,
        )
        .expect("insert blank at the end");
        let end_sizes = sizes(&end);
        let last_size = original_sizes[original_sizes.len() - 1];
        assert!((end_sizes[last as usize].0 - last_size.0).abs() <= 1.0);
        assert!(texts(&end)[last as usize].trim().is_empty());
    }

    #[test]
    fn extract_produces_a_file_with_exactly_the_selected_pages() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("extract");
        let (source, original_bytes, original_texts, _) = snapshot(&directory, "multipage.pdf");
        let extracted = directory.join("extracted.pdf");
        let report = extract_pages(&source, &extracted, &[2, 0], None).expect("extract pages");
        assert_eq!(report.page_count, 2);
        assert_eq!(report.page_map[0], Some(0));
        assert_eq!(report.page_map[1], None);
        assert_eq!(report.page_map[2], Some(1));
        assert_eq!(
            texts(&extracted),
            vec![original_texts[0].clone(), original_texts[2].clone()]
        );
        assert_eq!(fs::read(&source).expect("source"), original_bytes);

        // Extraction of annotated pages carries their annotations, because PDFium imports the
        // page dictionary rather than copying text only.
        let annotated = copy_fixture(&directory, "annotated.pdf");
        let before = annotations(&annotated);
        let one = directory.join("annotated-page-2.pdf");
        let report = extract_pages(&annotated, &one, &[1], None).expect("extract annotated page");
        assert_eq!(report.page_count, 1);
        assert_eq!(report.page_map, vec![None, Some(0)]);
        assert_eq!(
            on_page(annotations(&one)[0].clone(), 0),
            on_page(before[1].clone(), 0)
        );

        let all = directory.join("all.pdf");
        let count = original_texts.len() as u32;
        let report = extract_pages(&source, &all, &(0..count).collect::<Vec<_>>(), None)
            .expect("extract every page");
        assert_eq!(report.page_count, count);
        assert_eq!(texts(&all), original_texts);
    }

    #[test]
    fn a_failed_operation_leaves_the_document_untouched_and_readable() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("failure");
        let (source, original_bytes, original_texts, page_count) =
            snapshot(&directory, "multipage.pdf");
        let destination = directory.join("failed.pdf");

        let out_of_range = apply_page_operation(
            &source,
            &destination,
            &PageOperation::Rotate {
                pages: vec![99],
                quarter_turns: 1,
            },
            None,
        );
        assert!(out_of_range.is_err(), "an out-of-range page is refused");
        let delete_everything = apply_page_operation(
            &source,
            &destination,
            &PageOperation::Delete {
                pages: (0..page_count as u32).collect(),
            },
            None,
        );
        assert!(delete_everything.is_err(), "deleting every page is refused");
        assert!(!destination.exists(), "a rejected request writes no file");
        assert_eq!(fs::read(&source).expect("source"), original_bytes);
        assert_eq!(texts(&source), original_texts);
        assert!(
            crate::writeback::interrupted_save_temporaries(&destination).is_empty(),
            "a rejected request leaves no temporary"
        );

        // The rename fails when the destination is a directory. The temporary must be cleaned
        // and the source must still open with every page.
        let directory_destination = directory.join("not-a-file");
        fs::create_dir(&directory_destination).expect("destination directory");
        let rename_failure = apply_page_operation(
            &source,
            &directory_destination,
            &PageOperation::Rotate {
                pages: vec![0],
                quarter_turns: 1,
            },
            None,
        );
        assert!(
            rename_failure.is_err(),
            "renaming onto a directory must fail"
        );
        assert_eq!(
            fs::read(&source).expect("source after failure"),
            original_bytes
        );
        assert_eq!(rotations(&source), vec![0; page_count]);
        assert_eq!(texts(&source), original_texts);
        assert!(
            crate::writeback::interrupted_save_temporaries(&directory_destination).is_empty(),
            "a failed write cleans its temporary"
        );
    }

    #[test]
    fn replacing_the_original_is_backup_first_and_verifies_the_edit() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("replace");
        let annotated = copy_fixture(&directory, "annotated.pdf");
        let original_bytes = fs::read(&annotated).expect("original bytes");
        let revision = directory.join("revision.pdf");
        let report = apply_page_operation(
            &annotated,
            &revision,
            &PageOperation::Delete { pages: vec![0] },
            None,
        )
        .expect("make a revision");
        assert_eq!(report.page_count, 1);

        // The same revision can be published as a new file without touching either input.
        let copy = directory.join("edited-copy.pdf");
        let published = publish_edited_copy(&revision, &copy, 1).expect("publish an edited copy");
        assert_eq!(published.page_count, 1);
        assert_eq!(published.page_map, vec![Some(0)]);
        assert_eq!(published.backup_path, None);
        assert_eq!(texts(&copy).len(), 1);
        assert_eq!(annotations(&copy).len(), 1);
        assert_eq!(fs::read(&annotated).expect("annotated"), original_bytes);

        let replaced =
            replace_original_with_edit(&revision, &annotated, 1).expect("replace the original");
        let backup = replaced.backup_path.expect("a backup must be reported");
        assert!(backup.exists());
        assert_eq!(
            fs::read(&backup).expect("backup"),
            original_bytes,
            "the backup is the old original, byte for byte"
        );
        assert_eq!(texts(&annotated).len(), 1);
        assert_eq!(annotations(&annotated).len(), 1);
        assert_eq!(
            fs::metadata(&annotated).expect("metadata").len(),
            replaced.output_bytes
        );

        // A revision cannot replace itself, and a source that is not the revision cannot be
        // published as an edited copy over itself.
        let refused = replace_original_with_edit(&annotated, &annotated, 1);
        assert!(refused.is_err());
        let self_copy = publish_edited_copy(&annotated, &annotated, 1);
        assert!(self_copy.is_err());
    }

    #[test]
    fn page_plan_maps_are_consistent_for_every_operation() {
        let rotations = vec![0, 1, 2, 3, 0];
        let sizes = vec![
            PageSize {
                width: 100.0,
                height: 200.0,
            },
            PageSize {
                width: 200.0,
                height: 100.0,
            },
            PageSize {
                width: 300.0,
                height: 400.0,
            },
            PageSize {
                width: 400.0,
                height: 300.0,
            },
            PageSize {
                width: 500.0,
                height: 600.0,
            },
        ];
        let rotated = plan(
            &PageOperation::Rotate {
                pages: vec![1, 3],
                quarter_turns: 1,
            },
            5,
            &rotations,
            &sizes,
        )
        .expect("rotate plan");
        assert_eq!(rotated.rotations, vec![0, 2, 2, 0, 0]);
        assert_eq!(rotated.sizes[1], sizes[1].swapped());

        let moved = plan(
            &PageOperation::Move {
                pages: vec![0, 4],
                destination: 1,
            },
            5,
            &rotations,
            &sizes,
        )
        .expect("move plan");
        assert_eq!(
            moved.page_map,
            vec![Some(1), Some(0), Some(3), Some(4), Some(2)]
        );

        let deleted = plan(
            &PageOperation::Delete { pages: vec![4, 1] },
            5,
            &rotations,
            &sizes,
        )
        .expect("delete plan");
        assert_eq!(
            deleted.page_map,
            vec![Some(0), None, Some(1), Some(2), None]
        );

        let inserted = plan(
            &PageOperation::InsertBlank { index: 2 },
            5,
            &rotations,
            &sizes,
        )
        .expect("insert plan");
        assert_eq!(
            inserted.page_map,
            vec![Some(0), Some(1), Some(3), Some(4), Some(5)]
        );
        assert_eq!(inserted.rotations, vec![0, 1, 0, 2, 3, 0]);
        assert_eq!(inserted.sizes.len(), 6);
        assert_eq!(inserted.sizes[2], sizes[1]);

        assert!(
            plan(
                &PageOperation::Move {
                    pages: vec![0],
                    destination: 5
                },
                5,
                &rotations,
                &sizes
            )
            .is_err()
        );
    }

    fn copy_named(directory: &Path, source: &str, destination: &str) -> PathBuf {
        crate::test_support::copy_fixture(directory, source, destination)
    }

    /// An eleven-page document built only from committed fixtures, so the "every five pages"
    /// split can be asserted as 5 + 5 + 1 without adding a fixture to the repository.
    fn eleven_page_document(directory: &Path) -> PathBuf {
        let multipage = copy_fixture(directory, "multipage.pdf");
        let second = copy_named(directory, "multipage.pdf", "multipage-2.pdf");
        let third = copy_named(directory, "multipage.pdf", "multipage-3.pdf");
        let last_two = directory.join("last-two.pdf");
        extract_pages(&multipage, &last_two, &[0, 1], None).expect("extract two pages");
        let eleven = directory.join("eleven-pages.pdf");
        merge_documents(&multipage, &[second, third, last_two], &eleven, None)
            .expect("build the eleven-page source");
        assert_eq!(texts(&eleven).len(), 11);
        eleven
    }

    fn split_plan(directory: &Path, chunks: &[&[u32]]) -> Vec<SplitPart> {
        chunks
            .iter()
            .enumerate()
            .map(|(index, pages)| SplitPart {
                destination: directory.join(format!("part-{}.pdf", index + 1)),
                pages: pages.to_vec(),
            })
            .collect()
    }

    #[test]
    fn merge_appends_pages_annotations_and_keeps_the_first_outline() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("merge");
        let first = copy_fixture(&directory, "outlined.pdf");
        let second = copy_fixture(&directory, "annotated.pdf");
        let third = copy_named(&directory, "outlined.pdf", "outlined-again.pdf");
        let first_bytes = fs::read(&first).expect("first bytes");
        let second_bytes = fs::read(&second).expect("second bytes");
        let third_bytes = fs::read(&third).expect("third bytes");
        let first_texts = texts(&first);
        let second_texts = texts(&second);
        let third_texts = texts(&third);
        let first_outline = outline_signature(&first).expect("first outline");
        let third_outline = outline_signature(&third).expect("third outline");
        assert!(
            !first_outline.is_empty(),
            "the first fixture has an outline"
        );
        assert!(
            !third_outline.is_empty(),
            "the appended fixture has an outline"
        );
        let second_annotations = annotations(&second);
        let merged = directory.join("merged.pdf");

        let report = merge_documents(&first, &[second.clone(), third.clone()], &merged, None)
            .expect("merge three documents");

        assert_eq!(report.page_count, 8);
        assert_eq!(report.first_page_count, 3);
        assert_eq!(report.appended_page_counts, vec![2, 3]);
        assert_eq!(
            report.appended_annotation_counts,
            vec![second_annotations.iter().map(Vec::len).sum::<usize>(), 0]
        );
        assert_eq!(report.first_outline_entries, first_outline.len());
        assert_eq!(report.dropped_outline_entries, third_outline.len());
        assert_eq!(
            report.rotations,
            rotations(&merged),
            "the report lists the output's rotations"
        );

        // Content identity, including the two boundary pages.
        let expected_texts: Vec<String> = first_texts
            .iter()
            .chain(second_texts.iter())
            .chain(third_texts.iter())
            .cloned()
            .collect();
        assert_eq!(texts(&merged), expected_texts);
        assert!(texts(&merged)[2].contains("Chapter Three"));
        assert!(texts(&merged)[3].contains("Annotated page 1"));
        assert!(texts(&merged)[4].contains("Annotated page 2"));
        assert!(texts(&merged)[5].contains("Chapter One"));

        // File-owned annotations travel with their appended pages.
        let merged_annotations = annotations(&merged);
        assert!(!second_annotations[0].is_empty());
        assert_eq!(
            on_page(merged_annotations[3].clone(), 0),
            on_page(second_annotations[0].clone(), 0),
            "the first appended page keeps its annotations"
        );
        assert_eq!(
            on_page(merged_annotations[4].clone(), 0),
            on_page(second_annotations[1].clone(), 0),
            "the second appended page keeps its annotations"
        );
        assert!(merged_annotations[5].is_empty() && merged_annotations[7].is_empty());

        // The first document's outline survives unchanged; the appended outline was not imported.
        assert_eq!(
            outline_signature(&merged).expect("merged outline"),
            first_outline
        );

        // Every input is byte-identical.
        assert_eq!(fs::read(&first).expect("first after"), first_bytes);
        assert_eq!(fs::read(&second).expect("second after"), second_bytes);
        assert_eq!(fs::read(&third).expect("third after"), third_bytes);
    }

    #[test]
    fn merge_keeps_appended_rotations_and_page_sizes() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("merge-rotations");
        let first = copy_fixture(&directory, "multipage.pdf");
        let rotated = copy_fixture(&directory, "rotated.pdf");
        let expected_rotations: Vec<u32> = rotations(&first)
            .into_iter()
            .chain(rotations(&rotated))
            .collect();
        let expected_sizes: Vec<(f64, f64)> =
            sizes(&first).into_iter().chain(sizes(&rotated)).collect();
        let merged = directory.join("merged-rotations.pdf");
        let report = merge_documents(&first, std::slice::from_ref(&rotated), &merged, None)
            .expect("merge a rotated document");
        assert_eq!(report.page_count, 5);
        assert_eq!(report.rotations, expected_rotations);
        assert_eq!(report.page_sizes.len(), expected_sizes.len());
        for (reported, expected) in report.page_sizes.iter().zip(&expected_sizes) {
            assert!((reported.0 - expected.0).abs() < 0.001);
            assert!((reported.1 - expected.1).abs() < 0.001);
        }
        assert_eq!(rotations(&merged), expected_rotations);
        let merged_sizes = sizes(&merged);
        for (actual, expected) in merged_sizes.iter().zip(&expected_sizes) {
            assert!((actual.0 - expected.0).abs() < 0.001);
            assert!((actual.1 - expected.1).abs() < 0.001);
        }
    }

    #[test]
    fn merge_refuses_self_encrypted_and_overwriting_inputs_and_writes_nothing() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("merge-refuse");
        let first = copy_fixture(&directory, "multipage.pdf");
        let second = copy_fixture(&directory, "text-page.pdf");
        let encrypted = copy_fixture(&directory, "form-fields-encrypted.pdf");
        let first_bytes = fs::read(&first).expect("first bytes");
        let destination = directory.join("refused.pdf");

        let self_merge = merge_documents(&first, std::slice::from_ref(&first), &destination, None)
            .expect_err("merging a document into itself is refused");
        assert!(
            self_merge.to_string().contains("into itself"),
            "{self_merge}"
        );
        assert!(!destination.exists());

        let duplicate = merge_documents(
            &first,
            &[second.clone(), second.clone()],
            &destination,
            None,
        )
        .expect_err("the same file twice is refused");
        assert!(duplicate.to_string().contains("twice"), "{duplicate}");
        assert!(!destination.exists());

        let overwrite = merge_documents(&first, std::slice::from_ref(&second), &first, None)
            .expect_err("the output cannot be an input");
        assert!(overwrite.to_string().contains("overwrite"), "{overwrite}");

        let encrypted_other =
            merge_documents(&first, std::slice::from_ref(&encrypted), &destination, None)
                .expect_err("an encrypted appended document is refused");
        assert!(
            encrypted_other.to_string().contains("password-protected"),
            "{encrypted_other}"
        );
        assert!(!destination.exists(), "a refused merge writes no output");

        let encrypted_primary = merge_documents(
            &encrypted,
            std::slice::from_ref(&second),
            &destination,
            None,
        )
        .expect_err("an encrypted primary document is refused");
        assert!(
            encrypted_primary.to_string().contains("password-protected"),
            "{encrypted_primary}"
        );
        assert!(!destination.exists(), "a refused merge writes no output");
        assert_eq!(fs::read(&first).expect("first after"), first_bytes);
        assert!(
            crate::writeback::interrupted_save_temporaries(&destination).is_empty(),
            "a refused merge leaves no temporary behind"
        );
    }

    #[test]
    fn split_by_ranges_matches_every_selected_page() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("split-ranges");
        let source = eleven_page_document(&directory);
        let source_bytes = fs::read(&source).expect("source bytes");
        let source_texts = texts(&source);
        let source_rotations = rotations(&source);
        let source_sizes = sizes(&source);

        let plan = split_plan(&directory, &[&[0, 1, 2, 3, 4], &[5, 6, 7, 8, 9]]);
        let report = split_pages(&source, &plan, None).expect("split into two ranges");
        assert_eq!(report.source_page_count, 11);
        assert_eq!(report.parts.len(), 2);
        for (part, (start, end)) in report.parts.iter().zip([(0usize, 5usize), (5, 10)]) {
            assert_eq!(part.page_count, 5);
            assert_eq!(
                part.source_pages,
                (start..end).map(|page| page as u32).collect::<Vec<_>>()
            );
            let output_texts = texts(&part.destination);
            assert_eq!(output_texts, source_texts[start..end]);
            assert_eq!(part.rotations, source_rotations[start..end]);
            assert_eq!(part.page_sizes, source_sizes[start..end]);
        }
        // Page 11 was not selected by either range; it is not written anywhere.
        assert!(!plan[0].destination.with_file_name("part-3.pdf").exists());
        assert_eq!(fs::read(&source).expect("source after"), source_bytes);
    }

    #[test]
    fn split_every_five_pages_on_eleven_pages_is_five_five_one() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("split-every-five");
        let source = eleven_page_document(&directory);
        let source_bytes = fs::read(&source).expect("source bytes");
        let source_texts = texts(&source);
        let all: Vec<u32> = (0..11).collect();
        let chunks: Vec<&[u32]> = all.chunks(5).collect();
        let plan = split_plan(&directory, &chunks);
        let report = split_pages(&source, &plan, None).expect("split every five");
        assert_eq!(
            report
                .parts
                .iter()
                .map(|part| part.page_count)
                .collect::<Vec<_>>(),
            vec![5, 5, 1]
        );
        let mut start = 0;
        for part in &report.parts {
            let end = start + part.page_count as usize;
            assert_eq!(texts(&part.destination), source_texts[start..end]);
            start = end;
        }
        assert_eq!(start, 11);
        assert_eq!(fs::read(&source).expect("source after"), source_bytes);
    }

    #[test]
    fn split_refuses_bad_plans_and_encrypted_documents_and_writes_nothing() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("split-refuse");
        let source = copy_fixture(&directory, "multipage.pdf");
        let source_bytes = fs::read(&source).expect("source bytes");
        let encrypted = copy_fixture(&directory, "form-fields-encrypted.pdf");

        let empty_part = split_pages(
            &source,
            &[SplitPart {
                destination: directory.join("empty.pdf"),
                pages: vec![],
            }],
            None,
        )
        .expect_err("an empty part is refused");
        assert!(empty_part.to_string().contains("no pages"), "{empty_part}");
        assert!(!directory.join("empty.pdf").exists());

        let duplicate_page = split_pages(
            &source,
            &[SplitPart {
                destination: directory.join("dup.pdf"),
                pages: vec![0, 0],
            }],
            None,
        )
        .expect_err("a page named twice inside a part is refused");
        assert!(
            duplicate_page.to_string().contains("twice"),
            "{duplicate_page}"
        );
        assert!(!directory.join("dup.pdf").exists());

        let overlapping = split_pages(
            &source,
            &[
                SplitPart {
                    destination: directory.join("a.pdf"),
                    pages: vec![0, 1],
                },
                SplitPart {
                    destination: directory.join("b.pdf"),
                    pages: vec![1, 2],
                },
            ],
            None,
        )
        .expect_err("a page in two outputs is refused");
        assert!(
            overlapping
                .to_string()
                .contains("more than one split output"),
            "{overlapping}"
        );
        assert!(!directory.join("a.pdf").exists() && !directory.join("b.pdf").exists());

        let overlapping_destination = split_pages(
            &source,
            &[
                SplitPart {
                    destination: directory.join("same.pdf"),
                    pages: vec![0],
                },
                SplitPart {
                    destination: directory.join("same.pdf"),
                    pages: vec![1],
                },
            ],
            None,
        )
        .expect_err("two outputs at the same path are refused");
        assert!(
            overlapping_destination.to_string().contains("same file"),
            "{overlapping_destination}"
        );

        let source_output = split_pages(
            &source,
            &[SplitPart {
                destination: source.clone(),
                pages: vec![0],
            }],
            None,
        )
        .expect_err("a split cannot overwrite its source");
        assert!(
            source_output.to_string().contains("overwrite"),
            "{source_output}"
        );

        let encrypted_split = split_pages(
            &encrypted,
            &[SplitPart {
                destination: directory.join("encrypted-part.pdf"),
                pages: vec![0],
            }],
            None,
        )
        .expect_err("splitting an encrypted document is refused");
        assert!(
            encrypted_split.to_string().contains("password-protected"),
            "{encrypted_split}"
        );
        assert!(!directory.join("encrypted-part.pdf").exists());
        assert_eq!(fs::read(&source).expect("source after"), source_bytes);
    }

    #[test]
    fn a_later_split_failure_keeps_earlier_outputs_valid_and_the_source_untouched() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("split-late-failure");
        let source = eleven_page_document(&directory);
        let source_bytes = fs::read(&source).expect("source bytes");
        let source_texts = texts(&source);
        let blocked = directory.join("blocked-third-output.pdf");
        fs::create_dir(&blocked).expect("a directory where the third output should go");
        let plan = vec![
            SplitPart {
                destination: directory.join("first.pdf"),
                pages: (0..5).collect(),
            },
            SplitPart {
                destination: directory.join("second.pdf"),
                pages: (5..10).collect(),
            },
            SplitPart {
                destination: blocked.clone(),
                pages: vec![10],
            },
        ];

        let error =
            split_pages(&source, &plan, None).expect_err("the third output cannot be renamed");
        let message = error.to_string();
        assert!(message.contains("split output 3 of 3"), "{message}");
        assert!(
            message.contains("2 earlier output(s) are complete"),
            "{message}"
        );
        assert!(message.contains("source is unchanged"), "{message}");

        // The first two outputs are complete, verified and carry exactly their pages.
        assert_eq!(texts(&plan[0].destination), source_texts[0..5]);
        assert_eq!(texts(&plan[1].destination), source_texts[5..10]);
        assert!(blocked.is_dir(), "the failed destination was not replaced");
        assert_eq!(fs::read(&source).expect("source after"), source_bytes);
        assert!(
            crate::writeback::interrupted_save_temporaries(&blocked).is_empty(),
            "the failed output cleaned its temporary"
        );
    }

    #[test]
    fn split_carries_a_pages_file_owned_annotations() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("split-annotations");
        let source = copy_fixture(&directory, "annotated.pdf");
        let source_annotations = annotations(&source);
        assert!(!source_annotations[1].is_empty());
        let destination = directory.join("page-two.pdf");
        let report = split_pages(
            &source,
            &[SplitPart {
                destination: destination.clone(),
                pages: vec![1],
            }],
            None,
        )
        .expect("split an annotated page");
        assert_eq!(report.parts[0].page_count, 1);
        assert_eq!(
            on_page(annotations(&destination)[0].clone(), 0),
            on_page(source_annotations[1].clone(), 0)
        );
    }
}
