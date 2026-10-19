//! Writing the reader's annotations into a PDF, under the safety contract.
//!
//! # Why this lives beside the PDFium backend
//!
//! The write itself is PDFium's: `FPDFPage_CreateAnnot` + `FPDFAnnot_Set*` + `FPDF_SaveAsCopy`
//! with [`FPDF_INCREMENTAL`](https://pdfium.googlesource.com/pdfium/). Everything else in this
//! module is the part that must not depend on PDFium being correct:
//!
//! 1. **A user choice, not a background write.** Nothing here runs unless the caller asks for
//!    [`SaveMode::Copy`] or [`SaveMode::ReplaceOriginal`]. There is no autosave.
//! 2. **Append-only.** The incremental save leaves every original byte at its original offset.
//!    [`save_annotated_pdf`] verifies that the output's prefix *is* the source before it accepts
//!    the result, so a PDFium regression that rewrote the file would be caught here.
//! 3. **Atomic.** The bytes are written to a new temporary file in the destination's own
//!    directory, flushed, `fsync`ed, reopened and verified, and only then renamed over the
//!    target. A crash at any earlier point leaves the target untouched and at most one
//!    `<name>.lyra-reader-save-*.tmp` file behind, which
//!    [`cleanup_interrupted_save_temporaries`] removes on the next save and
//!    [`interrupted_save_note`] reports on the next open.
//! 4. **A backup before replacement.** [`SaveMode::ReplaceOriginal`] writes
//!    `<name>.lyra-reader-backup-<unix>-<n>.<ext>` first, verifies it byte-for-byte, and refuses to run
//!    if any part of that fails. Overwriting the original happens by rename after the backup is
//!    durable.
//! 5. **Verified.** Before the rename, the temporary file is reopened with
//!    [`AnnotationReader`] and every requested annotation is checked field by field. Every
//!    annotation the source already had is also read before and after and compared, so an
//!    incremental save that disturbes an existing annotation fails instead of replacing the
//!    original.
//!
//! # Appearance streams (honest limitation)
//!
//! PDFium's C API has exactly one way to attach an appearance stream to an annotation:
//! `FPDFAnnot_SetAP`. Its implementation creates the form XObject **and its `/ExtGState`**, and
//! that graphics state is hard-coded to `/BM /Normal` (PDFium `fpdf_annot.cpp`,
//! `SetExtGStateInResourceDict(doc, annot_dict, "Normal")`; measured against the vendored
//! dylib, whose output contains `/BM/Normal`). There is no public call that puts `/BM /Multiply`
//! in that state, and writing a `Normal` state for a translucent highlight would make Preview
//! tint the glyphs instead of multiplying into the page — strictly worse than no appearance at
//! all, because the two viewers would then disagree about the same file.
//!
//! This writer therefore does **not** write `/AP` for the quad-based kinds, which now includes
//! `/StrikeOut`: it has the same `/QuadPoints` and `/C` contract as an underline, just a
//! different line position. Both PDFium and PDFKit synthesize the appearance from those keys;
//! the macOS test suite renders a saved copy with PDFKit and asserts that the highlight covers
//! the line while the glyph pixels stay black, which is the multiply-like result Preview is
//! expected to show. A viewer that requires an explicit `/AP` (some older readers do) will show
//! nothing; the alternative was to
//! write a state that is knowingly wrong. See the task report and `README.md` for the measurement.
//!
//! Ink, shapes, sticky notes and free text are different: they have no blend mode to get wrong,
//! and PDFium's C API cannot write the keys they need (`/BS`, `/L`, `/Name`, `/DA`, `/Q`, or a
//! real `/AP` form XObject). They are written by [`crate::geometry_write`] (the direct lopdf
//! writer, named for the first kinds it handled): a stroked mark gets a real `/AP /N` **and** its
//! geometry, a sticky note gets `/Name /Comment`, and a text box gets `/DA`, `/Q` **and** an
//! appearance stream. The appearance objects are appended by the same save as the annotation
//! dictionaries and are verified before the rename. A viewer that ignores the appearance can
//! still synthesize the stroke or the free text; a viewer that ignores both shows nothing, which
//! no such viewer in this environment did.
//!
//! # Threading
//!
//! Every PDFium call made here is delegated to [`AnnotationAppender`] /
//! [`AnnotationReader`], which serialise on `PDFIUM_LOCK`. The file-system half of this module
//! holds no lock.

use crate::annotations::{
    AnnotationAppender, AnnotationReader, WriteAnnotation, WriteAnnotationKind,
};
use crate::geometry_write::{append_direct_annotations, verify_direct_annotations};
use lyra_reader_core::{
    ErrorCode, LyraReaderError, PageIndex, Point, RawAnnotation, RawAnnotationKind, Result,
};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

/// How the caller asked for the bytes to land.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SaveMode {
    /// Write `destination`; never touch the document that is open. This is the default action.
    Copy,
    /// Replace the source document. A verified backup is written first, always.
    ReplaceOriginal,
}

/// What a successful save did, for the UI and for the tests.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SaveReport {
    /// The file the verified bytes were renamed onto (absolute as far as the OS resolves it).
    pub destination: PathBuf,
    /// The `/NM` values written, in the order the caller supplied them.
    pub written_ids: Vec<String>,
    /// Bytes appended to the original, measured after verification.
    pub appended_bytes: u64,
    /// The verified backup, only for [`SaveMode::ReplaceOriginal`].
    pub backup_path: Option<PathBuf>,
    /// Content annotations the source already had (they are all verified unchanged).
    pub preexisting_annotation_count: usize,
    /// Stale `*.lyra-reader-save-*.tmp` files removed from the destination directory before this save.
    pub cleaned_temporaries: usize,
    /// True when the output's prefix equals the source byte-for-byte. Always true on `Ok`.
    pub source_bytes_preserved: bool,
}

/// How a rewritten document (page edits, extraction) is allowed to land.
///
/// This is deliberately **not** [`SaveMode`]: an annotation save appends to the source, so
/// `ReplaceOriginal` can require `source == destination`. A page rewrite consumes the source and
/// produces an unrelated file, and the shell's working copy is a temporary revision, so the file
/// that gets replaced is the *destination* (the original document) while the source is the
/// revision. [`OutputMode::ReplaceDestination`] makes that asymmetry explicit: the destination is
/// backed up and verified before it is replaced.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum OutputMode {
    /// Write a new file. Refuses to name the source.
    Copy,
    /// Replace the destination with the rewritten source after a verified backup.
    ReplaceDestination,
}

/// What [`write_rewritten_pdf`] did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct RewrittenOutput {
    pub destination: PathBuf,
    /// The verified backup of the destination, only for [`OutputMode::ReplaceDestination`].
    pub backup_path: Option<PathBuf>,
    /// Stale `*.lyra-reader-save-*.tmp` files removed before this write.
    pub cleaned_temporaries: usize,
    /// Size of the verified output file.
    pub output_bytes: u64,
}

/// The marker in every temporary file this module creates. Kept distinctive so a file left by a
/// crash is recognisable, and so the cleanup can never match an unrelated file.
const TEMP_MARKER: &str = ".lyra-reader-save-";
const TEMP_SUFFIX: &str = ".tmp";
const BACKUP_MARKER: &str = ".lyra-reader-backup-";
const COPY_BUFFER: usize = 64 * 1024;

/// Hard limits, so a malformed shell request cannot ask the writer to build an unreasonable PDF.
const MAX_ANNOTATIONS: usize = 20_000;
const MAX_QUADS: usize = 1_000;
const MAX_INK_PATHS: usize = 256;
const MAX_INK_POINTS: usize = 100_000;
const MAX_TEXT_BYTES: usize = 100_000;
const MAX_AUTHOR_BYTES: usize = 1_024;
const MAX_ID_BYTES: usize = 128;

/// Appends `annotations` to `source` and writes the result to `destination`.
///
/// Does nothing to `source` for [`SaveMode::Copy`]. For [`SaveMode::ReplaceOriginal`],
/// `destination` must name the same file as `source`, and a verified backup is written before
/// the original is replaced.
///
/// # Safety contract (what the caller can rely on)
///
/// * On `Err`, `source` is untouched unless the error says the rename itself failed — and even
///   then the original is still the old inode, because rename is the last step.
/// * On `Ok`, `destination` has been reopened and verified to contain every requested
///   annotation exactly once, every annotation that was already in the file unchanged, and the
///   source's bytes as a prefix.
/// * Temporary files are removed on every error path on a best-effort basis; leftovers are
///   cleaned by the next save and reported by [`interrupted_save_note`].
pub fn save_annotated_pdf(
    source: &Path,
    destination: &Path,
    annotations: &[WriteAnnotation],
    password: Option<&str>,
    mode: SaveMode,
) -> Result<SaveReport> {
    let source = fs::canonicalize(source)
        .map_err(|error| io_error("could not resolve the document being saved", source, error))?;
    if !source.is_file() {
        return Err(LyraReaderError::new(
            ErrorCode::NotFound,
            "the document being saved is not a regular file",
        )
        .with_detail(source.display().to_string()));
    }
    let destination = canonical_destination(destination)?;
    match mode {
        SaveMode::Copy if destination == source => {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "the annotated copy would overwrite the original; choose another name or the explicit replace action",
            ));
        }
        SaveMode::ReplaceOriginal if destination != source => {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "the replace action can only write the document it was opened from",
            )
            .with_detail(format!(
                "opened: {} · requested: {}",
                source.display(),
                destination.display()
            )));
        }
        _ => {}
    }

    let source_bytes = fs::metadata(&source)
        .map_err(|error| io_error("could not read the source metadata", &source, error))?;
    let source_len = source_bytes.len();
    let source_modified = source_bytes.modified().ok();

    let mut cleaned_temporaries = cleanup_interrupted_save_temporaries(&destination)?;
    if destination != source {
        // A crashed *replace* leaves its temporary beside the source; a copy save is the next
        // operation that can safely clean it, and the source is what it was protecting.
        cleaned_temporaries += cleanup_interrupted_save_temporaries(&source)?;
    }

    // Open the writer first: it reports unsupported PDFium builds and a corrupt document before
    // any file is created. The source handle stays open for the whole operation.
    let mut appender = AnnotationAppender::open(&source, password)?;
    let page_count = appender.page_count();
    validate(annotations, page_count)?;
    // Two writers, one save contract. PDFium creates the quad-based markup kinds; the rest need
    // `/BS`, `/L`, `/Name`, `/DA`, `/Q` or a real appearance XObject, none of which its C API can
    // write (see `geometry_write`). Both write into the same temporary file and are verified
    // together before the rename.
    let (pdfium_annotations, direct_annotations): (Vec<WriteAnnotation>, Vec<WriteAnnotation>) =
        annotations
            .iter()
            .cloned()
            .partition(|annotation| annotation.kind.uses_pdfium());

    let preexisting = read_annotations(&source, password, page_count)?;
    let preexisting_annotation_count: usize = preexisting.iter().map(Vec::len).sum();
    reject_identities_already_in_the_pdf(&preexisting, annotations)?;

    // A backup must exist and be byte-identical before the original can be replaced.
    let backup_path = match mode {
        SaveMode::ReplaceOriginal => Some(write_backup(&source)?),
        SaveMode::Copy => None,
    };

    let (temp, file) = TempFile::create(&destination)?;
    let result = (|| -> Result<SaveReport> {
        // PDFium writes into the already-open file; there is no window in which another
        // process could replace the just-created path before the first byte is written.
        for annotation in &pdfium_annotations {
            appender.add(annotation)?;
        }
        let mut written_bytes = if pdfium_annotations.is_empty() {
            0
        } else {
            appender.save_incremental(file)?
        };
        if !direct_annotations.is_empty() {
            // With no PDFium update the temporary file is still empty; the direct writer starts
            // from the source. With one, it starts from the already-appended file, so the final
            // document has the source and the PDFium update as its prefix.
            let base = if pdfium_annotations.is_empty() {
                source.as_path()
            } else {
                temp.path()
            };
            append_direct_annotations(base, temp.path(), &direct_annotations, password)?;
            written_bytes = fs::metadata(temp.path())
                .map_err(|error| io_error("could not measure the saved file", temp.path(), error))?
                .len();
        }

        // The document must not have moved under us while the update was being produced.
        let after = fs::metadata(&source)
            .map_err(|error| io_error("could not re-read the source metadata", &source, error))?;
        if after.len() != source_len || after.modified().ok() != source_modified {
            return Err(LyraReaderError::new(
                ErrorCode::Io,
                "the document changed on disk while it was being saved; the original was left untouched",
            ));
        }

        verify_prefix(&source, temp.path(), source_len)?;

        let saved = read_annotations(temp.path(), password, page_count)?;
        verify_all(&preexisting, &saved, annotations)?;
        verify_direct_annotations(temp.path(), annotations, password)?;

        if written_bytes < source_len {
            return Err(LyraReaderError::new(
                ErrorCode::Internal,
                "the incremental save produced fewer bytes than the original",
            )
            .with_detail(format!("{written_bytes} < {source_len}")));
        }

        // Keep the source's mode (a 0600 document must not become world-readable). The backup
        // already has it too.
        fs::set_permissions(temp.path(), source_bytes.permissions()).map_err(|error| {
            io_error(
                "could not preserve the document's permissions",
                temp.path(),
                error,
            )
        })?;

        fs::rename(temp.path(), &destination).map_err(|error| {
            io_error(
                "could not move the verified file into place",
                &destination,
                error,
            )
        })?;
        temp.disarm();
        sync_directory(destination.parent());

        Ok(SaveReport {
            destination: destination.clone(),
            written_ids: annotations.iter().map(|a| a.id.clone()).collect(),
            appended_bytes: written_bytes.saturating_sub(source_len),
            backup_path: backup_path.clone(),
            preexisting_annotation_count,
            cleaned_temporaries,
            source_bytes_preserved: true,
        })
    })();

    // `appender` is dropped after this, closing the source document handle. On an error the temp
    // guard removes the partial output; on success it was disarmed by the rename.
    result
}

/// What an incremental save that is not an annotation write produced.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct IncrementalSaveReport {
    /// The file the verified bytes were renamed onto.
    pub destination: PathBuf,
    /// Bytes appended to the original, measured after verification.
    pub appended_bytes: u64,
    /// The verified backup, only for [`SaveMode::ReplaceOriginal`].
    pub backup_path: Option<PathBuf>,
    /// Stale `*.lyra-reader-save-*.tmp` files removed from the destination directory before this save.
    pub cleaned_temporaries: usize,
    /// True when the output's prefix equals the source byte-for-byte. Always true on `Ok`.
    pub source_bytes_preserved: bool,
}

/// Runs an **incremental** writer under the same file-safety contract as
/// [`save_annotated_pdf`], for updates that are not annotations (form values, `/Info`).
///
/// `build` receives the temporary file and must produce the complete output — the source bytes
/// followed by the update — exactly as the direct annotation writer does. `verify` receives the
/// temporary path after it has been flushed and must reopen it and prove the update is there and
/// that everything it did not change is still unchanged. This function adds the parts that
/// protect the user, so both writers cannot drift apart:
///
/// 1. The source is canonicalised and must be a regular file; a copy may not be the source and a
///    replace must be the source.
/// 2. A replace writes a byte-identical backup before the temporary file is created.
/// 3. The output is written to a temporary file beside the destination, flushed and `fsync`ed.
/// 4. The source is checked for concurrent modification, and its bytes must be the output's
///    prefix.
/// 5. `verify` reopens the temporary file before it is renamed.
/// 6. The destination's permissions are preserved and the rename is the last step.
pub(crate) fn save_incremental_with_contract<Build, Verify>(
    source: &Path,
    destination: &Path,
    mode: SaveMode,
    build: Build,
    verify: Verify,
) -> Result<IncrementalSaveReport>
where
    Build: FnOnce(&mut File) -> Result<()>,
    Verify: FnOnce(&Path) -> Result<()>,
{
    let source = fs::canonicalize(source)
        .map_err(|error| io_error("could not resolve the document being saved", source, error))?;
    if !source.is_file() {
        return Err(LyraReaderError::new(
            ErrorCode::NotFound,
            "the document being saved is not a regular file",
        )
        .with_detail(source.display().to_string()));
    }
    let destination = canonical_destination(destination)?;
    match mode {
        SaveMode::Copy if destination == source => {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "the saved copy would overwrite the original; choose another name or the explicit replace action",
            ));
        }
        SaveMode::ReplaceOriginal if destination != source => {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "the replace action can only write the document it was opened from",
            )
            .with_detail(format!(
                "opened: {} · requested: {}",
                source.display(),
                destination.display()
            )));
        }
        _ => {}
    }

    let source_metadata = fs::metadata(&source)
        .map_err(|error| io_error("could not read the source metadata", &source, error))?;
    let source_len = source_metadata.len();
    let source_modified = source_metadata.modified().ok();

    let mut cleaned_temporaries = cleanup_interrupted_save_temporaries(&destination)?;
    if destination != source {
        cleaned_temporaries += cleanup_interrupted_save_temporaries(&source)?;
    }

    let backup_path = match mode {
        SaveMode::ReplaceOriginal => Some(write_backup(&source)?),
        SaveMode::Copy => None,
    };

    let (temp, mut file) = TempFile::create(&destination)?;
    (|| -> Result<IncrementalSaveReport> {
        build(&mut file)?;
        file.flush()
            .map_err(|error| io_error("could not flush the saved document", temp.path(), error))?;
        file.sync_all()
            .map_err(|error| io_error("could not fsync the saved document", temp.path(), error))?;
        drop(file);

        let written_bytes = fs::metadata(temp.path())
            .map_err(|error| io_error("could not measure the saved file", temp.path(), error))?
            .len();
        if written_bytes < source_len {
            return Err(LyraReaderError::new(
                ErrorCode::Internal,
                "the incremental save produced fewer bytes than the original",
            )
            .with_detail(format!("{written_bytes} < {source_len}")));
        }

        let after = fs::metadata(&source)
            .map_err(|error| io_error("could not re-read the source metadata", &source, error))?;
        if after.len() != source_len || after.modified().ok() != source_modified {
            return Err(LyraReaderError::new(
                ErrorCode::Io,
                "the document changed on disk while it was being saved; nothing was replaced",
            ));
        }

        verify_prefix(&source, temp.path(), source_len)?;
        verify(temp.path())?;

        fs::set_permissions(temp.path(), source_metadata.permissions()).map_err(|error| {
            io_error(
                "could not preserve the document's permissions",
                temp.path(),
                error,
            )
        })?;

        fs::rename(temp.path(), &destination).map_err(|error| {
            io_error(
                "could not move the verified file into place",
                &destination,
                error,
            )
        })?;
        temp.disarm();
        sync_directory(destination.parent());

        Ok(IncrementalSaveReport {
            destination: destination.clone(),
            appended_bytes: written_bytes.saturating_sub(source_len),
            backup_path: backup_path.clone(),
            cleaned_temporaries,
            source_bytes_preserved: true,
        })
    })()
}

/// Writes a **rewritten** document under the same file-safety contract as an annotation save.
///
/// Used by page operations, which cannot be incremental: `FPDF_SaveAsCopy` without
/// `FPDF_INCREMENTAL` produces a complete new file, so a byte-prefix check does not apply. What
/// does apply, and is shared with [`save_annotated_pdf`], is everything that protects the user:
///
/// 1. `build` writes into a fresh temporary file in the destination's own directory.
/// 2. The file is flushed and `fsync`ed, then `verify` *reopens the temporary file* and checks
///    it before anything is renamed.
/// 3. For [`OutputMode::ReplaceDestination`], a byte-identical backup of the destination is
///    written and verified **before** the temporary is built. A failure at any point leaves the
///    destination as it was.
/// 4. The source and (when replacing) the destination are checked for concurrent modification
///    during the operation.
/// 5. The final step is an atomic rename; leftovers use the same `.lyra-reader-save-*.tmp` marker as
///    annotation saves, so [`cleanup_interrupted_save_temporaries`] handles both.
pub(crate) fn write_rewritten_pdf<Build, Verify>(
    source: &Path,
    destination: &Path,
    mode: OutputMode,
    build: Build,
    verify: Verify,
) -> Result<RewrittenOutput>
where
    Build: FnOnce(&mut File) -> Result<()>,
    Verify: FnOnce(&Path) -> Result<()>,
{
    let source = fs::canonicalize(source).map_err(|error| {
        io_error(
            "could not resolve the document being rewritten",
            source,
            error,
        )
    })?;
    if !source.is_file() {
        return Err(LyraReaderError::new(
            ErrorCode::NotFound,
            "the document being rewritten is not a regular file",
        )
        .with_detail(source.display().to_string()));
    }
    let destination = canonical_destination(destination)?;
    if mode == OutputMode::Copy && destination == source {
        return Err(LyraReaderError::new(
            ErrorCode::InvalidArgument,
            "an edited copy cannot overwrite the document it was made from",
        )
        .with_detail(destination.display().to_string()));
    }
    if mode == OutputMode::ReplaceDestination && destination == source {
        return Err(LyraReaderError::new(
            ErrorCode::InvalidArgument,
            "the rewritten file is the file being replaced; nothing would change",
        )
        .with_detail(destination.display().to_string()));
    }
    if mode == OutputMode::ReplaceDestination && !destination.is_file() {
        return Err(LyraReaderError::new(
            ErrorCode::NotFound,
            "the file to be replaced does not exist",
        )
        .with_detail(destination.display().to_string()));
    }

    let source_before = fs::metadata(&source)
        .map_err(|error| io_error("could not read the source metadata", &source, error))?;
    let destination_before = if mode == OutputMode::ReplaceDestination {
        Some(fs::metadata(&destination).map_err(|error| {
            io_error(
                "could not read the destination metadata",
                &destination,
                error,
            )
        })?)
    } else {
        fs::metadata(&destination).ok()
    };

    let mut cleaned_temporaries = cleanup_interrupted_save_temporaries(&destination)?;
    if destination != source {
        cleaned_temporaries += cleanup_interrupted_save_temporaries(&source)?;
    }

    // The backup comes first: a crash immediately after this point still leaves the reader a
    // byte-identical copy of what was about to be replaced.
    let backup_path = match mode {
        OutputMode::ReplaceDestination => Some(write_backup(&destination)?),
        OutputMode::Copy => None,
    };

    let (temp, mut file) = TempFile::create(&destination)?;
    (|| -> Result<RewrittenOutput> {
        build(&mut file)?;
        file.flush().map_err(|error| {
            io_error("could not flush the rewritten document", temp.path(), error)
        })?;
        file.sync_all().map_err(|error| {
            io_error("could not fsync the rewritten document", temp.path(), error)
        })?;
        drop(file);

        // Neither input may have moved while the output was being produced.
        let source_after = fs::metadata(&source)
            .map_err(|error| io_error("could not re-read the source metadata", &source, error))?;
        if source_after.len() != source_before.len()
            || source_after.modified().ok() != source_before.modified().ok()
        {
            return Err(LyraReaderError::new(
                ErrorCode::Io,
                "the document changed on disk while the edited copy was being written; nothing was replaced",
            ));
        }
        if let Some(before) = &destination_before {
            let after = fs::metadata(&destination).map_err(|error| {
                io_error(
                    "could not re-read the destination metadata; nothing was replaced",
                    &destination,
                    error,
                )
            })?;
            if after.len() != before.len() || after.modified().ok() != before.modified().ok() {
                return Err(LyraReaderError::new(
                    ErrorCode::Io,
                    "the destination changed on disk while the edited copy was being written; nothing was replaced",
                ));
            }
        }

        verify(temp.path())?;
        let output_bytes = fs::metadata(temp.path())
            .map_err(|error| {
                io_error(
                    "could not measure the rewritten document",
                    temp.path(),
                    error,
                )
            })?
            .len();

        let permissions = destination_before
            .as_ref()
            .unwrap_or(&source_before)
            .permissions();
        fs::set_permissions(temp.path(), permissions).map_err(|error| {
            io_error(
                "could not preserve the document's permissions",
                temp.path(),
                error,
            )
        })?;

        fs::rename(temp.path(), &destination).map_err(|error| {
            io_error(
                "could not move the verified file into place",
                &destination,
                error,
            )
        })?;
        temp.disarm();
        sync_directory(destination.parent());

        Ok(RewrittenOutput {
            destination: destination.clone(),
            backup_path: backup_path.clone(),
            cleaned_temporaries,
            output_bytes,
        })
    })()
}

/// Every temporary file this module would create for `target`. Does not remove anything.
pub fn interrupted_save_temporaries(target: &Path) -> Vec<PathBuf> {
    let Some(name) = target.file_name().and_then(|name| name.to_str()) else {
        return Vec::new();
    };
    let prefix = format!("{name}{TEMP_MARKER}");
    let directory = target.parent().filter(|path| !path.as_os_str().is_empty());
    let Some(directory) = directory else {
        return Vec::new();
    };
    let Ok(entries) = fs::read_dir(directory) else {
        return Vec::new();
    };
    let mut found: Vec<PathBuf> = entries
        .filter_map(std::result::Result::ok)
        .filter(|entry| {
            entry
                .file_type()
                .map(|kind| kind.is_file())
                .unwrap_or(false)
        })
        .filter(|entry| {
            let file_name = entry.file_name();
            let file_name = file_name.to_string_lossy();
            file_name.starts_with(&prefix) && file_name.ends_with(TEMP_SUFFIX)
        })
        .map(|entry| entry.path())
        .collect();
    found.sort();
    found
}

/// A human sentence for the next open: a half-finished save is detected by the presence of a
/// `<name>.lyra-reader-save-*.tmp` file beside the document, and the document itself is intact because
/// the rename is the last step.
pub fn interrupted_save_note(target: &Path) -> Option<String> {
    let temporaries = interrupted_save_temporaries(target);
    if temporaries.is_empty() {
        return None;
    }
    let names: Vec<String> = temporaries
        .iter()
        .filter_map(|path| {
            path.file_name()
                .map(|name| name.to_string_lossy().into_owned())
        })
        .collect();
    Some(format!(
        "A previous save of “{}” was interrupted before it could replace the document. The document itself is intact (a save only takes effect at the final rename); {} temporary file(s) left behind: {}. They will be removed on the next save.",
        target
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| target.display().to_string()),
        temporaries.len(),
        names.join(", ")
    ))
}

/// Removes stale temporaries for `target`, returning how many were removed.
///
/// Best effort: a temporary this process cannot delete (another user's file, a read-only
/// directory) is not a reason to refuse a save that protects the document itself. The document
/// is never the temporary file, so leaving one behind costs disk space, not data.
pub fn cleanup_interrupted_save_temporaries(target: &Path) -> Result<usize> {
    let mut removed = 0;
    for path in interrupted_save_temporaries(target) {
        if fs::remove_file(&path).is_ok() {
            removed += 1;
        }
    }
    Ok(removed)
}

/// The default name a copy is offered as: `<name> (annotated).pdf`.
pub fn suggested_copy_path(source: &Path) -> PathBuf {
    let stem = source
        .file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .unwrap_or_else(|| "document".to_string());
    let extension = source
        .extension()
        .map(|extension| extension.to_string_lossy().into_owned())
        .unwrap_or_else(|| "pdf".to_string());
    source.with_file_name(format!("{stem} (annotated).{extension}"))
}

fn validate(annotations: &[WriteAnnotation], page_count: u32) -> Result<()> {
    if annotations.is_empty() {
        return Err(LyraReaderError::new(
            ErrorCode::InvalidArgument,
            "there are no annotations to save",
        ));
    }
    if annotations.len() > MAX_ANNOTATIONS {
        return Err(LyraReaderError::new(
            ErrorCode::InvalidArgument,
            format!("{MAX_ANNOTATIONS} annotations is the most one save can write"),
        ));
    }

    let mut ids = HashSet::new();
    for annotation in annotations {
        let id = &annotation.id;
        if id.is_empty()
            || id.len() > MAX_ID_BYTES
            || !id.bytes().all(|byte| byte.is_ascii_graphic())
        {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "an annotation identity must be 1–128 printable ASCII characters",
            )
            .with_detail(format!("id: {id:?}")));
        }
        if !ids.insert(id.clone()) {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                format!("two annotations in one save share the identity {id:?}"),
            ));
        }
        if annotation.page.0 >= page_count {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                format!(
                    "annotation {id:?} names page {}, but the document has {page_count} page(s)",
                    annotation.page.get()
                ),
            ));
        }
        if !annotation.opacity.is_finite() || !(0.0..=1.0).contains(&annotation.opacity) {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                format!("annotation {id:?} has an opacity outside 0…1"),
            ));
        }
        validate_rect(&annotation.rect, id, "rect")?;
        match annotation.kind {
            WriteAnnotationKind::Text => {
                if !annotation.quads.is_empty() {
                    return Err(LyraReaderError::new(
                        ErrorCode::InvalidArgument,
                        format!("text annotation {id:?} must not carry /QuadPoints"),
                    ));
                }
            }
            WriteAnnotationKind::FreeText => {
                if !annotation.quads.is_empty() {
                    return Err(LyraReaderError::new(
                        ErrorCode::InvalidArgument,
                        format!("free-text annotation {id:?} must not carry /QuadPoints"),
                    ));
                }
                if !annotation.font_size.is_finite()
                    || annotation.font_size < 1.0
                    || annotation.font_size > 400.0
                {
                    return Err(LyraReaderError::new(
                        ErrorCode::InvalidArgument,
                        format!("free-text annotation {id:?} has a font size outside 1…400 pt"),
                    ));
                }
            }
            WriteAnnotationKind::Highlight
            | WriteAnnotationKind::Underline
            | WriteAnnotationKind::StrikeOut => {
                if annotation.quads.is_empty() {
                    return Err(LyraReaderError::new(
                        ErrorCode::InvalidArgument,
                        format!("markup annotation {id:?} has no /QuadPoints"),
                    ));
                }
                if annotation.quads.len() > MAX_QUADS {
                    return Err(LyraReaderError::new(
                        ErrorCode::InvalidArgument,
                        format!("annotation {id:?} has more than {MAX_QUADS} quads"),
                    ));
                }
                for quad in &annotation.quads {
                    validate_rect(quad, id, "quad")?;
                }
            }
            WriteAnnotationKind::Ink => {
                validate_geometry_common(annotation, id)?;
                if !annotation.quads.is_empty() {
                    return Err(LyraReaderError::new(
                        ErrorCode::InvalidArgument,
                        format!("ink annotation {id:?} must not carry /QuadPoints"),
                    ));
                }
                if annotation.ink_paths.is_empty() {
                    return Err(LyraReaderError::new(
                        ErrorCode::InvalidArgument,
                        format!("ink annotation {id:?} has no /InkList"),
                    ));
                }
                if annotation.ink_paths.len() > MAX_INK_PATHS {
                    return Err(LyraReaderError::new(
                        ErrorCode::InvalidArgument,
                        format!("ink annotation {id:?} has more than {MAX_INK_PATHS} strokes"),
                    ));
                }
                let mut points = 0usize;
                for path in &annotation.ink_paths {
                    // One point cannot describe a stroke; a dot would need a rendering rule the
                    // canvas does not have, and silently turning it into a line would invent one.
                    if path.len() < 2 {
                        return Err(LyraReaderError::new(
                            ErrorCode::InvalidArgument,
                            format!(
                                "ink annotation {id:?} has a stroke with fewer than two points"
                            ),
                        ));
                    }
                    points += path.len();
                    for point in path {
                        validate_point(*point, annotation.rect, id, "ink point")?;
                    }
                }
                if points > MAX_INK_POINTS {
                    return Err(LyraReaderError::new(
                        ErrorCode::InvalidArgument,
                        format!("ink annotation {id:?} has more than {MAX_INK_POINTS} points"),
                    ));
                }
            }
            WriteAnnotationKind::Line => {
                validate_geometry_common(annotation, id)?;
                if !annotation.quads.is_empty() {
                    return Err(LyraReaderError::new(
                        ErrorCode::InvalidArgument,
                        format!("line annotation {id:?} must not carry /QuadPoints"),
                    ));
                }
                let Some(line) = annotation.line else {
                    return Err(LyraReaderError::new(
                        ErrorCode::InvalidArgument,
                        format!("line annotation {id:?} has no /L endpoints"),
                    ));
                };
                validate_point(line.start, annotation.rect, id, "line start")?;
                validate_point(line.end, annotation.rect, id, "line end")?;
            }
            WriteAnnotationKind::Square | WriteAnnotationKind::Circle => {
                validate_geometry_common(annotation, id)?;
                if !annotation.quads.is_empty() {
                    return Err(LyraReaderError::new(
                        ErrorCode::InvalidArgument,
                        format!("shape annotation {id:?} must not carry /QuadPoints"),
                    ));
                }
            }
        }
        if let Some(contents) = &annotation.contents {
            if contents.len() > MAX_TEXT_BYTES {
                return Err(LyraReaderError::new(
                    ErrorCode::InvalidArgument,
                    format!("annotation {id:?} has more than {MAX_TEXT_BYTES} bytes of text"),
                ));
            }
            if contents.contains('\0') {
                return Err(LyraReaderError::new(
                    ErrorCode::InvalidArgument,
                    format!("annotation {id:?} has a NUL in its contents"),
                ));
            }
        }
        if let Some(author) = &annotation.author {
            if author.len() > MAX_AUTHOR_BYTES {
                return Err(LyraReaderError::new(
                    ErrorCode::InvalidArgument,
                    format!("annotation {id:?} has an author longer than {MAX_AUTHOR_BYTES} bytes"),
                ));
            }
            if author.contains('\0') {
                return Err(LyraReaderError::new(
                    ErrorCode::InvalidArgument,
                    format!("annotation {id:?} has a NUL in its author"),
                ));
            }
        }
        if let Some(modified) = &annotation.modified
            && (!modified.starts_with("D:")
                || !modified.is_ascii()
                || modified.len() > 64
                || modified.contains('\0'))
        {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                format!("annotation {id:?} has a malformed PDF date"),
            )
            .with_detail(format!("{modified:?}")));
        }
    }
    Ok(())
}

fn validate_rect(rect: &lyra_reader_core::Rect, id: &str, what: &str) -> Result<()> {
    let values = [
        rect.origin.x,
        rect.origin.y,
        rect.size.width,
        rect.size.height,
    ];
    if !values.iter().all(|value| value.is_finite())
        || rect.size.width <= 0.0
        || rect.size.height <= 0.0
    {
        return Err(LyraReaderError::new(
            ErrorCode::InvalidArgument,
            format!("annotation {id:?} has an empty or non-finite {what}"),
        )
        .with_detail(format!("{rect:?}")));
    }
    Ok(())
}

/// The checks every stroked kind shares: a positive border width and no quads.
fn validate_geometry_common(annotation: &WriteAnnotation, id: &str) -> Result<()> {
    if !annotation.border_width.is_finite()
        || annotation.border_width <= 0.0
        || annotation.border_width > 200.0
    {
        return Err(LyraReaderError::new(
            ErrorCode::InvalidArgument,
            format!("annotation {id:?} has a border width outside 0…200 pt"),
        ));
    }
    Ok(())
}

/// A point must be finite and inside the annotation's own box (with half a point of slack for
/// float conversion). A mark whose `/Rect` does not contain its geometry is malformed: some
/// viewers clip the appearance to it, so writing one would produce a file that shows different
/// things in different readers.
fn validate_point(
    point: lyra_reader_core::Point,
    rect: lyra_reader_core::Rect,
    id: &str,
    what: &str,
) -> Result<()> {
    const SLACK: f64 = 0.5;
    if !point.x.is_finite()
        || !point.y.is_finite()
        || point.x < rect.min_x() - SLACK
        || point.x > rect.max_x() + SLACK
        || point.y < rect.min_y() - SLACK
        || point.y > rect.max_y() + SLACK
    {
        return Err(LyraReaderError::new(
            ErrorCode::InvalidArgument,
            format!("annotation {id:?} has a {what} outside its /Rect"),
        )
        .with_detail(format!("{point:?} is not inside {rect:?}")));
    }
    Ok(())
}

fn reject_identities_already_in_the_pdf(
    preexisting: &[Vec<RawAnnotation>],
    annotations: &[WriteAnnotation],
) -> Result<()> {
    let existing: HashSet<&str> = preexisting
        .iter()
        .flatten()
        .map(|annotation| annotation.id.as_str())
        .collect();
    for annotation in annotations {
        let identity = format!("nm:{}", annotation.id);
        if existing.contains(identity.as_str()) {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                format!(
                    "annotation {:?} is already in the document; saving it again would create a duplicate",
                    annotation.id
                ),
            ));
        }
    }
    Ok(())
}

/// Reads every content annotation, page by page. The `AnnotationReader` owns a second PDFium
/// document handle, so this is safe to run before and after the write.
fn read_annotations(
    path: &Path,
    password: Option<&str>,
    page_count: u32,
) -> Result<Vec<Vec<RawAnnotation>>> {
    let reader = {
        let _guard = crate::backend::PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        AnnotationReader::open(path, password)?
    };
    let mut pages = Vec::with_capacity(page_count as usize);
    for page in 0..page_count {
        let annotations = {
            let _guard = crate::backend::PDFIUM_LOCK
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            reader.page(PageIndex(page))?
        };
        pages.push(annotations);
    }
    // `AnnotationReader::drop` takes `PDFIUM_LOCK` itself; every guard above is out of scope.
    drop(reader);
    Ok(pages)
}

/// Reopens the temporary file and checks it really contains what was asked for.
fn verify_all(
    preexisting: &[Vec<RawAnnotation>],
    saved: &[Vec<RawAnnotation>],
    annotations: &[WriteAnnotation],
) -> Result<()> {
    let mut saved_by_id: HashMap<&str, (&RawAnnotation, usize)> = HashMap::new();
    for (page, records) in saved.iter().enumerate() {
        for record in records {
            if let Some((_, previous_page)) = saved_by_id.insert(record.id.as_str(), (record, page))
            {
                return Err(LyraReaderError::new(
                    ErrorCode::Internal,
                    "the saved file contains an annotation identity twice",
                )
                .with_detail(format!("{} on pages {previous_page} and {page}", record.id)));
            }
        }
    }

    for (page, records) in preexisting.iter().enumerate() {
        for original in records {
            let Some((saved_original, saved_page)) = saved_by_id.get(original.id.as_str()) else {
                return Err(LyraReaderError::new(
                    ErrorCode::Internal,
                    "the saved file lost an annotation the source already had",
                )
                .with_detail(format!("{} (page {page})", original.id)));
            };
            if *saved_page != page || *saved_original != original {
                return Err(LyraReaderError::new(
                    ErrorCode::Internal,
                    "the saved file changed an annotation the source already had",
                )
                .with_detail(format!(
                    "{} was on page {page}, is now on page {saved_page}",
                    original.id
                )));
            }
        }
    }

    let expected = preexisting.iter().map(Vec::len).sum::<usize>() + annotations.len();
    let actual: usize = saved.iter().map(Vec::len).sum();
    if actual != expected {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the saved file does not contain exactly the source's annotations plus the new ones",
        )
        .with_detail(format!("expected {expected}, found {actual}")));
    }

    for annotation in annotations {
        let identity = format!("nm:{}", annotation.id);
        let occurrences: Vec<&RawAnnotation> = saved
            .iter()
            .flatten()
            .filter(|record| record.id == identity)
            .collect();
        if occurrences.len() != 1 {
            return Err(LyraReaderError::new(
                ErrorCode::Internal,
                "a written annotation did not survive the round trip exactly once",
            )
            .with_detail(format!(
                "{}: found {} occurrence(s)",
                annotation.id,
                occurrences.len()
            )));
        }
        verify_one(occurrences[0], annotation)?;
    }
    Ok(())
}

fn verify_one(record: &RawAnnotation, expected: &WriteAnnotation) -> Result<()> {
    let mismatch = |field: &str, detail: String| {
        LyraReaderError::new(
            ErrorCode::Internal,
            "the saved annotation does not match what was written",
        )
        .with_detail(format!("{} ({field}): {detail}", expected.id))
    };

    if record.page != expected.page {
        return Err(mismatch(
            "page",
            format!(
                "expected {}, got {}",
                expected.page.get(),
                record.page.get()
            ),
        ));
    }
    let kind = match expected.kind {
        WriteAnnotationKind::Highlight => RawAnnotationKind::Highlight,
        WriteAnnotationKind::Underline => RawAnnotationKind::Underline,
        WriteAnnotationKind::StrikeOut => RawAnnotationKind::Strikeout,
        WriteAnnotationKind::Text => RawAnnotationKind::Text,
        WriteAnnotationKind::FreeText => RawAnnotationKind::FreeText,
        WriteAnnotationKind::Ink => RawAnnotationKind::Ink,
        WriteAnnotationKind::Square => RawAnnotationKind::Square,
        WriteAnnotationKind::Circle => RawAnnotationKind::Circle,
        WriteAnnotationKind::Line => RawAnnotationKind::Line,
    };
    if record.kind != kind {
        return Err(mismatch(
            "kind",
            format!("expected {kind:?}, got {:?}", record.kind),
        ));
    }
    if !approximately(record.rect, expected.rect, 0.01) {
        return Err(mismatch(
            "rect",
            format!("expected {:?}, got {:?}", expected.rect, record.rect),
        ));
    }
    if expected.kind.uses_pdfium() {
        if record.quads.len() != expected.quads.len()
            || record
                .quads
                .iter()
                .zip(&expected.quads)
                .any(|(left, right)| !approximately(*left, *right, 0.01))
        {
            return Err(mismatch(
                "quads",
                format!("expected {:?}, got {:?}", expected.quads, record.quads),
            ));
        }
    } else {
        if !record.quads.is_empty() {
            return Err(mismatch(
                "quads",
                format!(
                    "a note or stroked annotation must not write /QuadPoints, found {:?}",
                    record.quads
                ),
            ));
        }
        if expected.kind.is_geometry() {
            verify_geometry(record, expected, &mismatch)?;
        }
    }
    let color = record
        .color
        .ok_or_else(|| mismatch("color", "the file reports no /C".into()))?;
    if [color.red, color.green, color.blue] != expected.color {
        return Err(mismatch(
            "color",
            format!(
                "expected {:?}, got [{}, {}, {}]",
                expected.color, color.red, color.green, color.blue
            ),
        ));
    }
    let alpha = (expected.opacity.clamp(0.0, 1.0) * 255.0).round() / 255.0;
    // `FPDFAnnot_SetColor` omits `/CA` when the alpha is 255, and the reader reports an absent
    // `/CA` as "the file did not say" — which a consumer treats as opaque. A fully opaque note
    // is therefore verified against its semantic opacity, not against the key's presence.
    let opacity = record.opacity.unwrap_or(1.0);
    // The 8-bit writers store `/CA` as a rounded byte; the dictionary writer stores the exact
    // requested number. One byte of quantisation is the difference that is allowed here.
    if (opacity - alpha).abs() > 1.0 / 255.0 + 1e-6 {
        return Err(mismatch(
            "opacity",
            format!("expected {alpha}, got {opacity}"),
        ));
    }
    // The writer deliberately does not set /BM: a highlight/underline with no /BM is
    // multiplied by the reader and by every renderer that implements table 164's default for
    // these kinds; a note is alpha-over. Assert the effective blend, not the absence of a key.
    let expected_blend = match expected.kind {
        WriteAnnotationKind::Highlight
        | WriteAnnotationKind::Underline
        | WriteAnnotationKind::StrikeOut => lyra_reader_core::AnnotationBlend::Multiply,
        WriteAnnotationKind::Text
        | WriteAnnotationKind::FreeText
        | WriteAnnotationKind::Ink
        | WriteAnnotationKind::Square
        | WriteAnnotationKind::Circle
        | WriteAnnotationKind::Line => lyra_reader_core::AnnotationBlend::Normal,
    };
    if record.blend != expected_blend {
        return Err(mismatch(
            "blend",
            format!("expected {expected_blend:?}, got {:?}", record.blend),
        ));
    }
    if record.contents != non_empty(expected.contents.as_deref()) {
        return Err(mismatch(
            "contents",
            format!(
                "expected {:?}, got {:?}",
                expected.contents, record.contents
            ),
        ));
    }
    if record.author != non_empty(expected.author.as_deref()) {
        return Err(mismatch(
            "author",
            format!("expected {:?}, got {:?}", expected.author, record.author),
        ));
    }
    if record.modified != non_empty(expected.modified.as_deref()) {
        return Err(mismatch(
            "modified",
            format!(
                "expected {:?}, got {:?}",
                expected.modified, record.modified
            ),
        ));
    }
    if expected.kind == WriteAnnotationKind::FreeText {
        let Some(size) = record.font_size_pt else {
            return Err(mismatch(
                "font size",
                "the saved file reports no /DA font size".into(),
            ));
        };
        if (size - expected.font_size).abs() > 0.02 {
            return Err(mismatch(
                "font size",
                format!("expected {}, got {size}", expected.font_size),
            ));
        }
        if record.alignment != expected.alignment {
            return Err(mismatch(
                "alignment",
                format!(
                    "expected {:?}, got {:?}",
                    expected.alignment, record.alignment
                ),
            ));
        }
    }
    if !record.visible {
        return Err(mismatch(
            "visible",
            "the written annotation is hidden".into(),
        ));
    }
    Ok(())
}

/// The geometry a stroked annotation was asked to carry, as the reader reads it back.
fn verify_geometry(
    record: &RawAnnotation,
    expected: &WriteAnnotation,
    mismatch: &impl Fn(&str, String) -> LyraReaderError,
) -> Result<()> {
    match expected.kind {
        WriteAnnotationKind::Ink => {
            let matches = record.ink_paths.len() == expected.ink_paths.len()
                && record
                    .ink_paths
                    .iter()
                    .zip(&expected.ink_paths)
                    .all(|(left, right)| {
                        left.len() == right.len()
                            && left.iter().zip(right).all(|(left, right)| {
                                (left.x - right.x).abs() <= 0.02 && (left.y - right.y).abs() <= 0.02
                            })
                    });
            if !matches {
                return Err(mismatch(
                    "ink",
                    format!(
                        "expected {} stroke(s), got {}",
                        expected.ink_paths.len(),
                        record.ink_paths.len()
                    ),
                ));
            }
        }
        WriteAnnotationKind::Line => {
            let Some(expected_line) = expected.line else {
                return Err(mismatch("line", "the request has no endpoints".into()));
            };
            let Some(line) = record.line else {
                return Err(mismatch("line", "the saved file reports no /L".into()));
            };
            let close = |left: Point, right: Point| {
                (left.x - right.x).abs() <= 0.02 && (left.y - right.y).abs() <= 0.02
            };
            if !close(line.start, expected_line.start) || !close(line.end, expected_line.end) {
                return Err(mismatch(
                    "line",
                    format!("expected {expected_line:?}, got {line:?}"),
                ));
            }
            if record.line_arrow != expected.line_arrow {
                return Err(mismatch(
                    "line_arrow",
                    format!(
                        "expected {}, got {}",
                        expected.line_arrow, record.line_arrow
                    ),
                ));
            }
        }
        WriteAnnotationKind::Square | WriteAnnotationKind::Circle => {}
        WriteAnnotationKind::Highlight
        | WriteAnnotationKind::Underline
        | WriteAnnotationKind::StrikeOut
        | WriteAnnotationKind::Text
        | WriteAnnotationKind::FreeText => {
            unreachable!("only called for a stroked kind")
        }
    }
    let Some(width) = record.border_width else {
        return Err(mismatch(
            "border",
            "the saved file reports no /BS width".into(),
        ));
    };
    if (width - expected.border_width).abs() > 0.02 {
        return Err(mismatch(
            "border",
            format!("expected {}, got {width}", expected.border_width),
        ));
    }
    Ok(())
}

fn non_empty(value: Option<&str>) -> Option<String> {
    value.filter(|value| !value.is_empty()).map(str::to_string)
}

fn approximately(
    left: lyra_reader_core::Rect,
    right: lyra_reader_core::Rect,
    tolerance: f64,
) -> bool {
    (left.origin.x - right.origin.x).abs() <= tolerance
        && (left.origin.y - right.origin.y).abs() <= tolerance
        && (left.size.width - right.size.width).abs() <= tolerance
        && (left.size.height - right.size.height).abs() <= tolerance
}

fn verify_prefix(source: &Path, saved: &Path, source_len: u64) -> Result<()> {
    let mut original = File::open(source).map_err(|error| {
        io_error(
            "could not reopen the original for verification",
            source,
            error,
        )
    })?;
    let mut output = File::open(saved).map_err(|error| {
        io_error(
            "could not reopen the saved file for verification",
            saved,
            error,
        )
    })?;
    let output_len = output
        .metadata()
        .map_err(|error| io_error("could not measure the saved file", saved, error))?
        .len();
    if output_len < source_len {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the saved file is shorter than the original; the incremental save did not append",
        )
        .with_detail(format!("{output_len} < {source_len}")));
    }

    let mut expected = vec![0u8; COPY_BUFFER];
    let mut actual = vec![0u8; COPY_BUFFER];
    loop {
        let read = original.read(&mut expected).map_err(|error| {
            io_error(
                "could not read the original for verification",
                source,
                error,
            )
        })?;
        if read == 0 {
            break;
        }
        output
            .read_exact(&mut actual[..read])
            .map_err(|error| io_error("could not read the saved prefix", saved, error))?;
        if expected[..read] != actual[..read] {
            return Err(LyraReaderError::new(
                ErrorCode::Internal,
                "the saved file did not preserve the original bytes; refusing to replace it",
            ));
        }
    }
    Ok(())
}

/// Writes a byte-identical backup next to `source`, or fails without touching the source.
fn write_backup(source: &Path) -> Result<PathBuf> {
    let metadata = fs::metadata(source).map_err(|error| {
        io_error(
            "could not read the document before backing it up",
            source,
            error,
        )
    })?;
    let parent = source
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let stem = source
        .file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .unwrap_or_else(|| "document".to_string());
    let extension = source
        .extension()
        .map(|extension| extension.to_string_lossy().into_owned())
        .unwrap_or_else(|| "pdf".to_string());
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0);

    let mut last_error = None;
    for attempt in 0..100 {
        let name = if attempt == 0 {
            format!("{stem}{BACKUP_MARKER}{seconds}.{extension}")
        } else {
            format!("{stem}{BACKUP_MARKER}{seconds}-{attempt}.{extension}")
        };
        let path = parent.join(name);
        let mut destination = match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                last_error = Some(error);
                continue;
            }
            Err(error) => {
                return Err(LyraReaderError::new(
                    ErrorCode::Io,
                    "could not write the backup; the original was left untouched",
                )
                .with_detail(format!("{}: {error}", path.display())));
            }
        };

        let backup_result = (|| -> std::io::Result<()> {
            let mut original = File::open(source)?;
            std::io::copy(&mut original, &mut destination)?;
            destination.flush()?;
            destination.sync_all()?;
            Ok(())
        })();
        if let Err(error) = backup_result {
            let _ = fs::remove_file(&path);
            return Err(LyraReaderError::new(
                ErrorCode::Io,
                "could not write the backup; the original was left untouched",
            )
            .with_detail(format!("{}: {error}", path.display())));
        }
        drop(destination);

        if let Err(error) = fs::set_permissions(&path, metadata.permissions()) {
            let _ = fs::remove_file(&path);
            return Err(LyraReaderError::new(
                ErrorCode::Io,
                "could not give the backup the document's permissions; the original was left untouched",
            )
            .with_detail(format!("{}: {error}", path.display())));
        }
        if let Err(error) = verify_same_bytes(source, &path) {
            let _ = fs::remove_file(&path);
            return Err(LyraReaderError::new(
                ErrorCode::Io,
                "the backup was not byte-identical to the original, so it was discarded and the original was left untouched",
            )
            .with_detail(format!("{}: {error}", path.display())));
        }
        sync_directory(Some(parent));
        return Ok(path);
    }

    Err(LyraReaderError::new(
        ErrorCode::Io,
        "could not choose a new backup name; the original was left untouched",
    )
    .with_detail(
        last_error
            .map(|error| error.to_string())
            .unwrap_or_default(),
    ))
}

fn verify_same_bytes(left: &Path, right: &Path) -> std::io::Result<()> {
    let mut left = File::open(left)?;
    let mut right = File::open(right)?;
    let left_len = left.metadata()?.len();
    let right_len = right.metadata()?.len();
    if left_len != right_len {
        return Err(std::io::Error::other("different lengths"));
    }
    let mut left_buffer = vec![0u8; COPY_BUFFER];
    let mut right_buffer = vec![0u8; COPY_BUFFER];
    loop {
        let read = left.read(&mut left_buffer)?;
        if read == 0 {
            return Ok(());
        }
        right.read_exact(&mut right_buffer[..read])?;
        if left_buffer[..read] != right_buffer[..read] {
            return Err(std::io::Error::other("bytes differ"));
        }
    }
}

fn canonical_destination(destination: &Path) -> Result<PathBuf> {
    if destination.exists() {
        return fs::canonicalize(destination)
            .map_err(|error| io_error("could not resolve the destination", destination, error));
    }
    let parent = destination
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let parent = fs::canonicalize(parent).map_err(|error| {
        io_error(
            "the destination directory does not exist",
            destination,
            error,
        )
    })?;
    let name = destination.file_name().ok_or_else(|| {
        LyraReaderError::new(
            ErrorCode::InvalidArgument,
            "the destination has no file name",
        )
        .with_detail(destination.display().to_string())
    })?;
    Ok(parent.join(name))
}

/// A temporary file in the destination's own directory, removed on drop unless disarmed.
///
/// Same directory is what makes the final rename atomic: a cross-device rename would be a copy
/// followed by a delete, with a window where neither file is complete.
struct TempFile {
    path: PathBuf,
    armed: bool,
}

impl TempFile {
    fn create(destination: &Path) -> Result<(Self, File)> {
        let parent = destination
            .parent()
            .filter(|path| !path.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new("."));
        let name = destination.file_name().ok_or_else(|| {
            LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "the destination has no file name",
            )
        })?;
        for attempt in 0..100 {
            let path = parent.join(format!(
                "{}{TEMP_MARKER}{}-{}-{attempt}{TEMP_SUFFIX}",
                name.to_string_lossy(),
                std::process::id(),
                nonce()
            ));
            match OpenOptions::new().write(true).create_new(true).open(&path) {
                Ok(file) => return Ok((Self { path, armed: true }, file)),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => {
                    return Err(io_error(
                        "could not create a temporary file next to the destination",
                        &path,
                        error,
                    ));
                }
            }
        }
        Err(LyraReaderError::new(
            ErrorCode::Io,
            "could not choose a unique temporary file name",
        ))
    }

    fn path(&self) -> &Path {
        &self.path
    }

    fn disarm(mut self) {
        self.armed = false;
    }
}

impl Drop for TempFile {
    fn drop(&mut self) {
        if self.armed {
            let _ = fs::remove_file(&self.path);
        }
    }
}

fn nonce() -> u64 {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or(0);
    nanos ^ COUNTER.fetch_add(1, Ordering::Relaxed).rotate_left(17)
}

fn sync_directory(directory: Option<&Path>) {
    // Best effort: the rename is already atomic, and `fsync` on a directory is about durability
    // across a power loss rather than about the file being readable. A platform that refuses to
    // open a directory for sync must not turn a successful save into an error.
    if let Some(directory) = directory
        && let Ok(handle) = File::open(directory)
    {
        let _ = handle.sync_all();
    }
}

fn io_error(action: &str, path: &Path, error: std::io::Error) -> LyraReaderError {
    LyraReaderError::new(ErrorCode::Io, action).with_detail(format!("{}: {error}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::scratch;
    use lyra_reader_core::{AnnotationAlignment, Rect};
    use std::os::unix::fs::PermissionsExt;

    fn copy_fixture(directory: &Path, name: &str) -> PathBuf {
        crate::test_support::copy_fixture(directory, "annotated.pdf", name)
    }

    fn highlight() -> WriteAnnotation {
        WriteAnnotation {
            id: "11111111-1111-1111-1111-111111111111".to_string(),
            page: PageIndex(0),
            kind: WriteAnnotationKind::Highlight,
            rect: Rect::new(72.0, 686.0, 388.0, 15.0),
            quads: vec![Rect::new(72.0, 686.0, 388.0, 15.0)],
            ink_paths: Vec::new(),
            line: None,
            line_arrow: false,
            border_width: 0.0,
            font_size: 0.0,
            alignment: AnnotationAlignment::Left,
            color: [255, 216, 64],
            opacity: 0.4,
            contents: Some("LyraReader round-trip highlight.".to_string()),
            author: Some("LyraReader Test".to_string()),
            modified: Some("D:20261016213000-07'00'".to_string()),
        }
    }

    fn strikeout() -> WriteAnnotation {
        WriteAnnotation {
            id: "55555555-5555-5555-5555-555555555555".to_string(),
            page: PageIndex(0),
            kind: WriteAnnotationKind::StrikeOut,
            rect: Rect::new(72.0, 641.0, 388.0, 15.0),
            quads: vec![Rect::new(72.0, 641.0, 388.0, 15.0)],
            ink_paths: Vec::new(),
            line: None,
            line_arrow: false,
            border_width: 0.0,
            font_size: 0.0,
            alignment: AnnotationAlignment::Left,
            color: [230, 80, 40],
            opacity: 0.9,
            contents: Some("LyraReader round-trip strikeout.".to_string()),
            author: Some("LyraReader Test".to_string()),
            modified: Some("D:20261018101500-07'00'".to_string()),
        }
    }

    fn note() -> WriteAnnotation {
        WriteAnnotation {
            id: "22222222-2222-2222-2222-222222222222".to_string(),
            page: PageIndex(1),
            kind: WriteAnnotationKind::Text,
            rect: Rect::new(500.0, 700.0, 26.0, 26.0),
            quads: Vec::new(),
            ink_paths: Vec::new(),
            line: None,
            line_arrow: false,
            border_width: 0.0,
            font_size: 0.0,
            alignment: AnnotationAlignment::Left,
            color: [255, 216, 64],
            opacity: 1.0,
            contents: Some("LyraReader round-trip note.".to_string()),
            author: Some("LyraReader Test".to_string()),
            modified: Some("D:20261016213000-07'00'".to_string()),
        }
    }

    fn free_text() -> WriteAnnotation {
        WriteAnnotation {
            id: "44444444-4444-4444-4444-444444444444".to_string(),
            page: PageIndex(0),
            kind: WriteAnnotationKind::FreeText,
            rect: Rect::new(72.0, 500.0, 380.0, 60.0),
            quads: Vec::new(),
            ink_paths: Vec::new(),
            line: None,
            line_arrow: false,
            border_width: 0.0,
            font_size: 14.0,
            alignment: AnnotationAlignment::Center,
            color: [20, 20, 20],
            opacity: 1.0,
            contents: Some("LyraReader round-trip free text.\nA second line.".to_string()),
            author: Some("LyraReader Test".to_string()),
            modified: Some("D:20261017120000-07'00'".to_string()),
        }
    }

    fn ink() -> WriteAnnotation {
        WriteAnnotation {
            id: "33333333-3333-3333-3333-333333333331".to_string(),
            page: PageIndex(0),
            kind: WriteAnnotationKind::Ink,
            rect: Rect::new(60.0, 580.0, 200.0, 80.0),
            quads: Vec::new(),
            ink_paths: vec![vec![
                Point::new(72.0, 600.0),
                Point::new(110.0, 640.0),
                Point::new(160.0, 595.0),
                Point::new(240.0, 650.0),
            ]],
            line: None,
            line_arrow: false,
            border_width: 2.5,
            font_size: 0.0,
            alignment: AnnotationAlignment::Left,
            color: [220, 40, 40],
            opacity: 0.75,
            contents: Some("LyraReader round-trip ink.".to_string()),
            author: Some("LyraReader Test".to_string()),
            modified: Some("D:20261017120000-07'00'".to_string()),
        }
    }

    fn square() -> WriteAnnotation {
        WriteAnnotation {
            id: "33333333-3333-3333-3333-333333333332".to_string(),
            page: PageIndex(0),
            kind: WriteAnnotationKind::Square,
            rect: Rect::new(320.0, 600.0, 120.0, 60.0),
            quads: Vec::new(),
            ink_paths: Vec::new(),
            line: None,
            line_arrow: false,
            border_width: 3.0,
            font_size: 0.0,
            alignment: AnnotationAlignment::Left,
            color: [30, 90, 200],
            opacity: 1.0,
            contents: None,
            author: Some("LyraReader Test".to_string()),
            modified: Some("D:20261017120000-07'00'".to_string()),
        }
    }

    fn arrow() -> WriteAnnotation {
        WriteAnnotation {
            id: "33333333-3333-3333-3333-333333333333".to_string(),
            page: PageIndex(0),
            kind: WriteAnnotationKind::Line,
            rect: Rect::new(70.0, 480.0, 190.0, 50.0),
            quads: Vec::new(),
            ink_paths: Vec::new(),
            line: Some(lyra_reader_core::RawAnnotationLine {
                start: Point::new(80.0, 490.0),
                end: Point::new(250.0, 520.0),
            }),
            line_arrow: true,
            border_width: 2.0,
            font_size: 0.0,
            alignment: AnnotationAlignment::Left,
            color: [20, 140, 60],
            opacity: 1.0,
            contents: Some("An arrow.".to_string()),
            author: Some("LyraReader Test".to_string()),
            modified: Some("D:20261017120000-07'00'".to_string()),
        }
    }

    #[test]
    fn a_mixed_save_keeps_the_pdfium_update_and_appends_the_stroked_objects() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("mixed-round-trip");
        let source = copy_fixture(&directory, "source.pdf");
        let destination = directory.join("saved.pdf");
        let original = fs::read(&source).expect("read source");

        let report = save_annotated_pdf(
            &source,
            &destination,
            &[highlight(), ink(), square()],
            None,
            SaveMode::Copy,
        )
        .expect("save a mixed set");
        assert_eq!(report.preexisting_annotation_count, 7);
        assert!(
            fs::read(&destination)
                .expect("saved")
                .starts_with(&original)
        );

        let saved = read_annotations(&destination, None, 2).expect("read saved");
        assert_eq!(saved.iter().map(Vec::len).sum::<usize>(), 10);
        for expected in [highlight(), ink(), square()] {
            let identity = format!("nm:{}", expected.id);
            let matches: Vec<&RawAnnotation> = saved
                .iter()
                .flatten()
                .filter(|record| record.id == identity)
                .collect();
            assert_eq!(matches.len(), 1, "{} appears exactly once", expected.id);
            verify_one(matches[0], &expected).expect("the written annotation verifies");
        }
        // The source's own annotations are byte-for-byte the same records they were.
        let before = read_annotations(&source, None, 2).expect("read source");
        for (page, records) in before.iter().enumerate() {
            for original in records {
                assert!(saved[page].contains(original));
            }
        }
    }

    #[test]
    fn strikeout_round_trips_as_strikeout_and_leaves_preexisting_annotations_alone() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("strikeout-round-trip");
        let source = copy_fixture(&directory, "source.pdf");
        let destination = directory.join("saved.pdf");
        let original_bytes = fs::read(&source).expect("read fixture");

        let report =
            save_annotated_pdf(&source, &destination, &[strikeout()], None, SaveMode::Copy)
                .expect("save a strikeout");

        assert_eq!(report.written_ids, vec![strikeout().id]);
        assert_eq!(report.preexisting_annotation_count, 7);
        assert!(report.source_bytes_preserved);
        assert!(
            fs::read(&destination)
                .expect("saved")
                .starts_with(&original_bytes),
            "the source bytes are preserved as the output's prefix"
        );

        let saved = read_annotations(&destination, None, 2).expect("read saved");
        let records: Vec<&RawAnnotation> = saved.iter().flatten().collect();
        assert_eq!(records.len(), 8, "seven pre-existing plus the strikeout");

        let written = records
            .iter()
            .find(|record| record.id == format!("nm:{}", strikeout().id))
            .expect("strikeout in saved file");
        assert_eq!(written.kind, RawAnnotationKind::Strikeout);
        assert_eq!(written.rect, strikeout().rect);
        assert_eq!(written.quads, strikeout().quads);
        assert_eq!(
            written
                .color
                .map(|color| [color.red, color.green, color.blue]),
            Some(strikeout().color)
        );
        assert!((written.opacity.expect("opacity") - 0.9).abs() < 0.01);
        assert_eq!(
            written.contents.as_deref(),
            Some("LyraReader round-trip strikeout.")
        );

        // No duplicate identities, and every pre-existing annotation is the exact record it was.
        let mut ids: Vec<&str> = records.iter().map(|record| record.id.as_str()).collect();
        ids.sort_unstable();
        let unique = ids.len();
        ids.dedup();
        assert_eq!(ids.len(), unique, "no annotation identity appears twice");
        let before = read_annotations(&source, None, 2).expect("read source");
        for (page, page_records) in before.iter().enumerate() {
            for original in page_records {
                assert!(
                    saved[page].contains(original),
                    "pre-existing annotation {} on page {page} changed",
                    original.id
                );
            }
        }

        // The saved bytes name the PDF subtype explicitly. No appearance stream is written for
        // any quad-based markup kind; the honesty note in `writeback` says what that costs.
        let bytes = fs::read(&destination).expect("saved bytes");
        assert!(
            bytes
                .windows(b"/StrikeOut".len())
                .any(|window| window == b"/StrikeOut"),
            "the saved file carries /Subtype /StrikeOut"
        );
    }

    #[test]
    fn stroked_kinds_round_trip_with_bs_l_and_appearances() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("stroked-round-trip");
        let source = copy_fixture(&directory, "source.pdf");
        let destination = directory.join("saved.pdf");
        let original_bytes = fs::read(&source).expect("read fixture");

        let report = save_annotated_pdf(
            &source,
            &destination,
            &[ink(), square(), arrow()],
            None,
            SaveMode::Copy,
        )
        .expect("save stroked annotations");

        assert_eq!(report.written_ids, vec![ink().id, square().id, arrow().id]);
        assert_eq!(report.preexisting_annotation_count, 7);
        assert!(report.source_bytes_preserved);
        assert!(
            fs::read(&destination)
                .expect("saved")
                .starts_with(&original_bytes)
        );

        let saved = read_annotations(&destination, None, 2).expect("read saved");
        let records: Vec<&RawAnnotation> = saved.iter().flatten().collect();
        assert_eq!(
            records.len(),
            10,
            "seven pre-existing plus the three written"
        );

        let saved_ink = records
            .iter()
            .find(|record| record.id == format!("nm:{}", ink().id))
            .expect("ink in saved file");
        assert_eq!(saved_ink.kind, RawAnnotationKind::Ink);
        assert_eq!(saved_ink.ink_paths, ink().ink_paths);
        assert_eq!(saved_ink.border_width, Some(2.5));
        assert!((saved_ink.opacity.expect("opacity") - 0.75).abs() < 1e-6);

        let saved_square = records
            .iter()
            .find(|record| record.id == format!("nm:{}", square().id))
            .expect("square in saved file");
        assert_eq!(saved_square.kind, RawAnnotationKind::Square);
        assert_eq!(saved_square.rect, square().rect);
        assert_eq!(saved_square.border_width, Some(3.0));

        let saved_arrow = records
            .iter()
            .find(|record| record.id == format!("nm:{}", arrow().id))
            .expect("arrow in saved file");
        assert_eq!(saved_arrow.kind, RawAnnotationKind::Line);
        assert_eq!(saved_arrow.line, arrow().line);
        assert!(saved_arrow.line_arrow, "/LE and /Subj both say arrow");

        // No duplicate identities, and every pre-existing annotation is unchanged.
        let mut ids: Vec<&str> = saved.iter().flatten().map(|a| a.id.as_str()).collect();
        ids.sort_unstable();
        let unique = ids.len();
        ids.dedup();
        assert_eq!(ids.len(), unique);
        let before = read_annotations(&source, None, 2).expect("read source");
        for (page, records) in before.iter().enumerate() {
            for original in records {
                assert!(
                    saved[page].contains(original),
                    "pre-existing annotation {} on page {page} changed",
                    original.id
                );
            }
        }

        // The appearance streams and /BS the verification checks are real dictionary objects,
        // not something PDFium happened to write: read them back from the saved bytes.
        let bytes = fs::read(&destination).expect("saved bytes");
        for needle in [b"/InkList".as_slice(), b"/BS".as_slice(), b"/AP".as_slice()] {
            assert!(
                bytes.windows(needle.len()).any(|window| window == needle),
                "the saved file carries {}",
                String::from_utf8_lossy(needle)
            );
        }
        assert!(
            bytes
                .windows(b"/ClosedArrow".len())
                .any(|window| window == b"/ClosedArrow"),
            "a line with an arrow writes /LE"
        );
    }

    #[test]
    fn sticky_note_and_free_text_carry_name_da_q_and_an_appearance() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("note-free-text");
        let source = copy_fixture(&directory, "source.pdf");
        let destination = directory.join("saved.pdf");
        let original_bytes = fs::read(&source).expect("read fixture");

        let report = save_annotated_pdf(
            &source,
            &destination,
            &[note(), free_text()],
            None,
            SaveMode::Copy,
        )
        .expect("save a note and a text box");
        assert_eq!(report.preexisting_annotation_count, 7);
        assert!(report.source_bytes_preserved);

        let saved_bytes = fs::read(&destination).expect("saved readable");
        assert!(saved_bytes.starts_with(&original_bytes));
        for needle in [
            b"/Name /Comment".as_slice(),
            b"/DA".as_slice(),
            b"/FreeText".as_slice(),
            b"/Q 1".as_slice(),
            b"/AP".as_slice(),
        ] {
            assert!(
                saved_bytes
                    .windows(needle.len())
                    .any(|window| window == needle),
                "the saved file carries {}",
                String::from_utf8_lossy(needle)
            );
        }
        assert!(
            saved_bytes
                .windows(b"/Helv".len())
                .any(|window| window == b"/Helv"),
            "/DA keeps Helvetica as the standard-14 fallback for a viewer that ignores /AP"
        );
        assert!(
            saved_bytes
                .windows(b"/Type0".len())
                .any(|window| window == b"/Type0"),
            "the appearance itself uses the embedded Type0/Identity-H font"
        );
        assert!(
            saved_bytes
                .windows(b"/FontFile2".len())
                .any(|window| window == b"/FontFile2"),
            "the appearance font carries an embedded TrueType program"
        );

        let saved = read_annotations(&destination, None, 2).expect("read saved");
        let records: Vec<&RawAnnotation> = saved.iter().flatten().collect();
        assert_eq!(records.len(), 9, "seven pre-existing plus the two written");

        let saved_note = records
            .iter()
            .find(|record| record.id == format!("nm:{}", note().id))
            .expect("note in saved file");
        assert_eq!(saved_note.kind, RawAnnotationKind::Text);
        assert_eq!(saved_note.rect, note().rect);
        assert_eq!(
            saved_note.contents.as_deref(),
            Some("LyraReader round-trip note.")
        );

        let saved_text = records
            .iter()
            .find(|record| record.id == format!("nm:{}", free_text().id))
            .expect("free text in saved file");
        assert_eq!(saved_text.kind, RawAnnotationKind::FreeText);
        assert_eq!(saved_text.rect, free_text().rect);
        assert_eq!(saved_text.font_size_pt, Some(14.0));
        assert_eq!(saved_text.alignment, AnnotationAlignment::Center);
        assert_eq!(
            saved_text.contents.as_deref(),
            Some("LyraReader round-trip free text.\nA second line.")
        );

        // The source's own annotations are unchanged and nothing was duplicated.
        let mut ids: Vec<&str> = records.iter().map(|record| record.id.as_str()).collect();
        ids.sort_unstable();
        let unique = ids.len();
        ids.dedup();
        assert_eq!(ids.len(), unique);
        let before = read_annotations(&source, None, 2).expect("read source");
        for (page, page_records) in before.iter().enumerate() {
            for original in page_records {
                assert!(
                    saved[page].contains(original),
                    "pre-existing annotation {} on page {page} changed",
                    original.id
                );
            }
        }
    }

    #[test]
    fn round_trip_preserves_fields_and_preexisting_annotations() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("round-trip");
        let source = copy_fixture(&directory, "source.pdf");
        let destination = directory.join("saved.pdf");
        let original_bytes = fs::read(&source).expect("read fixture");

        let report = save_annotated_pdf(
            &source,
            &destination,
            &[highlight(), note()],
            None,
            SaveMode::Copy,
        )
        .expect("save annotated copy");

        assert_eq!(
            report.written_ids,
            vec![highlight().id.clone(), note().id.clone()]
        );
        assert_eq!(report.backup_path, None);
        assert_eq!(report.preexisting_annotation_count, 7);
        assert!(report.appended_bytes > 0);
        assert!(report.source_bytes_preserved);
        assert_eq!(
            fs::read(&source).expect("source readable"),
            original_bytes,
            "a copy save must not touch the source"
        );
        let saved_bytes = fs::read(&destination).expect("saved readable");
        assert!(
            saved_bytes.starts_with(&original_bytes),
            "the incremental save must keep every original byte as a prefix"
        );

        let page_count = 2;
        let preexisting = read_annotations(&source, None, page_count).expect("read source");
        let saved = read_annotations(&destination, None, page_count).expect("read saved");
        assert_eq!(
            preexisting.iter().map(Vec::len).sum::<usize>(),
            7,
            "the fixture's own annotations are all content annotations (the link is structural)"
        );
        assert_eq!(saved.iter().map(Vec::len).sum::<usize>(), 9);

        let ids: Vec<&str> = saved.iter().flatten().map(|a| a.id.as_str()).collect();
        assert_eq!(
            ids.iter()
                .filter(|id| id.ends_with(&highlight().id))
                .count(),
            1,
            "the highlight appears exactly once"
        );
        assert_eq!(
            ids.iter().filter(|id| id.ends_with(&note().id)).count(),
            1,
            "the note appears exactly once"
        );

        // The verifier is not vacuous: independently assert the exact fields a round trip has
        // to carry, including the blend the reader reports for a file with no /BM.
        let saved_highlight = saved[0]
            .iter()
            .find(|a| a.id == format!("nm:{}", highlight().id))
            .expect("highlight in saved file");
        assert_eq!(saved_highlight.kind, RawAnnotationKind::Highlight);
        assert_eq!(
            saved_highlight.quads,
            vec![Rect::new(72.0, 686.0, 388.0, 15.0)]
        );
        assert_eq!(saved_highlight.rect, Rect::new(72.0, 686.0, 388.0, 15.0));
        let colour = saved_highlight.color.expect("colour");
        assert_eq!([colour.red, colour.green, colour.blue], [255, 216, 64]);
        assert!((saved_highlight.opacity.expect("opacity") - 0.4).abs() < 1e-6);
        assert_eq!(
            saved_highlight.blend,
            lyra_reader_core::AnnotationBlend::Multiply,
            "a highlight with no /BM is multiplied by the reader, which is what Preview writes"
        );
        assert_eq!(
            saved_highlight.contents.as_deref(),
            Some("LyraReader round-trip highlight.")
        );
        assert_eq!(saved_highlight.author.as_deref(), Some("LyraReader Test"));
        assert_eq!(
            saved_highlight.modified.as_deref(),
            Some("D:20261016213000-07'00'")
        );

        let saved_note = saved[1]
            .iter()
            .find(|a| a.id == format!("nm:{}", note().id))
            .expect("note in saved file");
        assert_eq!(saved_note.kind, RawAnnotationKind::Text);
        assert_eq!(saved_note.rect, Rect::new(500.0, 700.0, 26.0, 26.0));
        assert_eq!(
            saved_note.contents.as_deref(),
            Some("LyraReader round-trip note.")
        );
        assert_eq!(saved_note.author.as_deref(), Some("LyraReader Test"));
        assert_eq!(saved_note.blend, lyra_reader_core::AnnotationBlend::Normal);
    }

    #[test]
    fn replacing_the_original_requires_and_verifies_a_backup() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("replace");
        let source = copy_fixture(&directory, "source.pdf");
        let original_bytes = fs::read(&source).expect("read fixture");

        // A copy save leaves the original alone and writes no backup.
        let copy = directory.join("copy.pdf");
        let report = save_annotated_pdf(
            &source,
            &copy,
            std::slice::from_ref(&highlight()),
            None,
            SaveMode::Copy,
        )
        .expect("save copy");
        assert_eq!(report.backup_path, None);
        assert_eq!(fs::read(&source).expect("source"), original_bytes);

        // Replacing needs the same path; a foreign destination is refused.
        let refused = save_annotated_pdf(
            &source,
            &copy,
            std::slice::from_ref(&highlight()),
            None,
            SaveMode::ReplaceOriginal,
        );
        assert!(refused.is_err(), "replace must not write a copy path");

        let report = save_annotated_pdf(
            &source,
            &source,
            std::slice::from_ref(&highlight()),
            None,
            SaveMode::ReplaceOriginal,
        )
        .expect("replace original");
        let backup = report.backup_path.expect("backup path");
        assert!(backup.exists(), "the backup must exist on disk");
        assert_eq!(
            fs::read(&backup).expect("backup readable"),
            original_bytes,
            "the backup must be byte-identical to the original"
        );
        let replaced = fs::read(&source).expect("replaced readable");
        assert!(replaced.starts_with(&original_bytes));
        assert_ne!(replaced, original_bytes, "the original must now be updated");

        // The backup's mode is the document's mode, not whatever umask created it with.
        let metadata = fs::metadata(&source).expect("source metadata");
        let backup_metadata = fs::metadata(&backup).expect("backup metadata");
        assert_eq!(
            metadata.permissions().mode() & 0o777,
            backup_metadata.permissions().mode() & 0o777
        );
    }

    #[test]
    fn a_failed_backup_aborts_before_touching_the_original() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("backup-failure");
        let source = copy_fixture(&directory, "source.pdf");
        let original_bytes = fs::read(&source).expect("read fixture");

        // A read-only directory makes the backup create fail. If the process can still write
        // (root, or a filesystem that ignores the mode), the premise of the test is unavailable.
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o500))
            .expect("make directory read-only");
        let probe = directory.join("probe");
        if OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&probe)
            .is_ok()
        {
            let _ = fs::remove_file(probe);
            let _ = fs::set_permissions(&directory, fs::Permissions::from_mode(0o700));
            eprintln!("skipping: a read-only directory is still writable here");
            return;
        }

        let result = save_annotated_pdf(
            &source,
            &source,
            std::slice::from_ref(&highlight()),
            None,
            SaveMode::ReplaceOriginal,
        );
        let _ = fs::set_permissions(&directory, fs::Permissions::from_mode(0o700));
        let error = result.expect_err("a failed backup must abort the save");
        let detail = format!("{error:?}");
        assert!(
            detail.to_lowercase().contains("backup"),
            "the error names the backup: {detail}"
        );
        assert_eq!(
            fs::read(&source).expect("source still readable"),
            original_bytes,
            "the original must be untouched when the backup cannot be written"
        );
        assert!(
            interrupted_save_temporaries(&source).is_empty(),
            "a refused save must not leave a temporary file"
        );
    }

    #[test]
    fn an_interrupted_save_is_detected_cleaned_and_leaves_the_original_readable() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("interrupted");
        let source = copy_fixture(&directory, "source.pdf");
        let original_bytes = fs::read(&source).expect("read fixture");

        // A crash leaves the temporary file behind; the document is still the last good file.
        let stale = directory.join(format!("source.pdf{TEMP_MARKER}999-1{TEMP_SUFFIX}"));
        fs::write(&stale, b"partial PDF").expect("write stale temp");
        let note = interrupted_save_note(&source).expect("interruption is detected");
        assert!(
            note.contains("interrupted"),
            "note explains the state: {note}"
        );
        assert_eq!(interrupted_save_temporaries(&source), vec![stale.clone()]);
        assert_eq!(fs::read(&source).expect("source readable"), original_bytes);

        // The next save removes it and reports having done so.
        let destination = directory.join("saved.pdf");
        let report = save_annotated_pdf(
            &source,
            &destination,
            std::slice::from_ref(&highlight()),
            None,
            SaveMode::Copy,
        )
        .expect("save after interruption");
        assert_eq!(report.cleaned_temporaries, 1);
        assert!(!stale.exists(), "the stale temporary is gone");
        assert!(interrupted_save_note(&source).is_none());

        // A save that fails after the bytes were written (the destination is a directory, so
        // the final rename cannot succeed) must leave the source unchanged and no temp behind.
        let directory_destination = directory.join("not-a-file");
        fs::create_dir(&directory_destination).expect("destination directory");
        let before = fs::read(&source).expect("source before failed save");
        let result = save_annotated_pdf(
            &source,
            &directory_destination,
            std::slice::from_ref(&highlight()),
            None,
            SaveMode::Copy,
        );
        assert!(result.is_err(), "renaming onto a directory must fail");
        assert_eq!(
            fs::read(&source).expect("source after failed save"),
            before,
            "a failed save leaves the original readable and unchanged"
        );
        assert!(
            interrupted_save_temporaries(&destination).is_empty(),
            "a failed save cleans its own temporary file"
        );
        let reopened =
            read_annotations(&source, None, 2).expect("original still opens after a failed save");
        assert_eq!(reopened.iter().map(Vec::len).sum::<usize>(), 7);
    }

    #[test]
    fn validation_refuses_empty_or_malformed_requests() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("validation");
        let source = copy_fixture(&directory, "source.pdf");
        let destination = directory.join("saved.pdf");

        let empty = save_annotated_pdf(&source, &destination, &[], None, SaveMode::Copy);
        assert!(empty.is_err(), "an empty request is not a save");

        let mut duplicate = highlight();
        duplicate.id = highlight().id;
        let duplicate_error = save_annotated_pdf(
            &source,
            &destination,
            &[highlight(), duplicate],
            None,
            SaveMode::Copy,
        );
        assert!(duplicate_error.is_err(), "duplicate identities are refused");

        let mut outside = highlight();
        outside.page = PageIndex(99);
        let outside_error =
            save_annotated_pdf(&source, &destination, &[outside], None, SaveMode::Copy);
        assert!(outside_error.is_err(), "an unknown page is refused");

        let mut already_saved = highlight();
        already_saved.id = "not-yet-there".to_string();
        assert!(
            save_annotated_pdf(
                &source,
                &destination,
                std::slice::from_ref(&already_saved),
                None,
                SaveMode::Copy
            )
            .is_ok()
        );
        let second = save_annotated_pdf(
            &source,
            &destination,
            std::slice::from_ref(&already_saved),
            None,
            SaveMode::Copy,
        )
        .expect("writing a fresh copy of the source is still fine");
        assert_eq!(second.preexisting_annotation_count, 7);

        // Saving the same identity again into the file that now carries it is refused.
        let in_destination = save_annotated_pdf(
            &destination,
            &destination,
            std::slice::from_ref(&already_saved),
            None,
            SaveMode::ReplaceOriginal,
        );
        assert!(
            in_destination.is_err(),
            "an identity already in the file must not be duplicated"
        );
    }

    #[test]
    fn a_copy_may_not_overwrite_its_source() {
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("same-path");
        let source = copy_fixture(&directory, "source.pdf");
        let result = save_annotated_pdf(
            &source,
            &source,
            std::slice::from_ref(&highlight()),
            None,
            SaveMode::Copy,
        );
        assert!(result.is_err(), "copy mode refuses the source path");
    }
}
