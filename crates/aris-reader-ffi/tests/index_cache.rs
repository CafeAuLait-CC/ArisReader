//! The persistent document index cache, exercised through the same FFI object the shell uses.
//!
//! Every test that writes a cache copies a committed fixture into its own scratch directory:
//! opening `tests/fixtures/*.pdf` directly would leave sidecars in the repository, and a test
//! suite must not dirty the tree it is checking.
//!
//! The central assertion is a counter, not a clock: `IndexCacheReport::derived_parts` is the
//! number of index components this document instance built from the PDF. A second open that
//! reports `Hit` **and** zero derived parts cannot have reparsed anything, whatever the machine's
//! speed.

use aris_reader_ffi::api::{
    ArisDocument, ArisEngine, CitationRecord, DocumentMetadataRecord, FigureRecord,
    IndexCacheOutcome, OutlineEntry, ReferenceRecord,
};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime};

/// Resolves a committed fixture at run time, without a compile-time path.
fn fixture(name: &str) -> PathBuf {
    if let Some(override_dir) = std::env::var_os("ARIS_READER_TEST_FIXTURES")
        && !override_dir.is_empty()
    {
        let candidate = PathBuf::from(override_dir).join(name);
        if candidate.is_file() {
            return candidate;
        }
    }
    if let Ok(current) = std::env::current_dir() {
        for ancestor in current.ancestors() {
            let candidate = ancestor.join("tests/fixtures").join(name);
            if candidate.is_file() {
                return candidate;
            }
        }
    }
    panic!("test fixture {name:?} was not found from the current directory");
}

struct ScratchDir {
    path: PathBuf,
}

impl Drop for ScratchDir {
    fn drop(&mut self) {
        // Tests that make the directory read-only restore it before this runs; see ReadOnlyDir.
        let _ = fs::remove_dir_all(&self.path);
    }
}

fn scratch(label: &str) -> ScratchDir {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let root = std::env::temp_dir()
        .canonicalize()
        .unwrap_or_else(|_| std::env::temp_dir());
    let nanosecond = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    for _ in 0..64 {
        let sequence = NEXT.fetch_add(1, Ordering::Relaxed);
        let path = root.join(format!(
            "aris-index-cache-test-{}-{sequence}-{nanosecond}-{label}",
            std::process::id()
        ));
        match fs::create_dir(&path) {
            Ok(()) => return ScratchDir { path },
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => panic!("could not create scratch directory: {error}"),
        }
    }
    panic!("could not reserve a scratch directory");
}

fn cache_path(document: &Path) -> PathBuf {
    let mut path = document.as_os_str().to_os_string();
    path.push(".aris-index.json");
    PathBuf::from(path)
}

fn copy_named_fixture(label: &str, name: &str) -> (ScratchDir, PathBuf) {
    let directory = scratch(label);
    let path = directory.path.join("document.pdf");
    fs::copy(fixture(name), &path).expect("copy fixture");
    (directory, path)
}

fn copy_fixture(label: &str) -> (ScratchDir, PathBuf) {
    copy_named_fixture(label, "two-column-references.pdf")
}

/// The whole derived index as the API returns it, for field-by-field comparison.
#[derive(Debug, PartialEq)]
struct Snapshot {
    outline: Vec<OutlineEntry>,
    references: Vec<ReferenceRecord>,
    figures: Vec<FigureRecord>,
    metadata: DocumentMetadataRecord,
    citations: BTreeMap<u32, Vec<CitationRecord>>,
}

fn snapshot(document: &ArisDocument) -> Snapshot {
    // Prime the cache lookup the same way a shell open does not: the caller asks for data first.
    let _ = document.index_cache_report();
    let outline = document.outline().expect("outline");
    let references = document.references().expect("references");
    let figures = document.figures().expect("figures");
    let metadata = document.metadata().expect("metadata");
    let mut citations = BTreeMap::new();
    for page in 0..document.page_count() {
        citations.insert(page, document.citations(page).expect("citations"));
    }
    Snapshot {
        outline,
        references,
        figures,
        metadata,
        citations,
    }
}

fn open(path: &Path) -> (std::sync::Arc<ArisEngine>, std::sync::Arc<ArisDocument>) {
    let engine = ArisEngine::new();
    let document = engine
        .open_document(path.display().to_string(), None)
        .expect("open document");
    (engine, document)
}

#[test]
fn a_second_open_uses_the_cache_and_returns_the_same_index_field_by_field() {
    if !aris_reader_pdfium::is_available() {
        eprintln!("skipping: PDFium unavailable");
        return;
    }
    let (_directory, path) = copy_fixture("second-open");
    let (engine, first) = open(&path);
    let fresh = snapshot(&first);
    let report = first.index_cache_report();
    assert_eq!(
        report.derived_parts, 4,
        "the four components are built from the PDF on a cold open"
    );
    let sidecar = cache_path(&path);
    assert!(
        sidecar.is_file(),
        "the complete index was written beside the PDF"
    );
    drop(first);

    let second = engine
        .open_document(path.display().to_string(), None)
        .expect("second open");
    let cached = second.index_cache_report();
    assert_eq!(cached.outcome, IndexCacheOutcome::Hit, "{cached:?}");
    assert_eq!(
        cached.derived_parts, 0,
        "a hit derives nothing from the PDF"
    );
    let from_cache = snapshot(&second);
    assert_eq!(from_cache.outline, fresh.outline, "outline differs");
    assert_eq!(from_cache.references, fresh.references, "references differ");
    assert_eq!(from_cache.figures, fresh.figures, "figures differ");
    assert_eq!(from_cache.metadata, fresh.metadata, "metadata differs");
    assert_eq!(
        from_cache.citations, fresh.citations,
        "citation spans differ"
    );
    assert_eq!(
        second.index_cache_report().derived_parts,
        0,
        "reading the cached index a second time still derives nothing"
    );
    assert_eq!(second.index_cache_report().outcome, IndexCacheOutcome::Hit);
    let _ = engine;
}

#[test]
fn every_index_component_survives_a_cache_round_trip() {
    if !aris_reader_pdfium::is_available() {
        eprintln!("skipping: PDFium unavailable");
        return;
    }
    // The reference fixture carries the bibliography and its citation spans, the cross-reference
    // fixture carries captions, the outline fixture carries bookmarks, and the metadata fixture
    // carries XMP/Info fields. Together they make every field of the cache non-trivial somewhere,
    // so this is a field-by-field check rather than a comparison of four empty vectors.
    let mut saw_outline = false;
    let mut saw_references = false;
    let mut saw_figures = false;
    let mut saw_metadata = false;
    for (index, name) in [
        "two-column-references.pdf",
        "cross-references.pdf",
        "outlined.pdf",
        "metadata-arxiv.pdf",
    ]
    .into_iter()
    .enumerate()
    {
        let (_directory, path) = copy_named_fixture(&format!("round-trip-{index}"), name);
        let (engine, first) = open(&path);
        let fresh = snapshot(&first);
        saw_outline |= !fresh.outline.is_empty();
        saw_references |= !fresh.references.is_empty();
        saw_figures |= !fresh.figures.is_empty();
        saw_metadata |=
            !fresh.metadata.title.values.is_empty() || !fresh.metadata.authors.values.is_empty();
        drop(first);

        let cached = engine
            .open_document(path.display().to_string(), None)
            .expect("cached open");
        assert_eq!(
            cached.index_cache_report().outcome,
            IndexCacheOutcome::Hit,
            "{name} did not hit its cache"
        );
        assert_eq!(
            cached.index_cache_report().derived_parts,
            0,
            "{name} reparsed instead of reading the cache"
        );
        assert_eq!(
            snapshot(&cached),
            fresh,
            "{name} differs after the round trip"
        );
    }
    assert!(saw_outline, "no fixture exercised the outline");
    assert!(saw_references, "no fixture exercised the reference list");
    assert!(saw_figures, "no fixture exercised the caption index");
    assert!(saw_metadata, "no fixture exercised metadata");
}

#[test]
fn touching_the_file_keeps_the_cache_and_changing_a_byte_invalidates_it() {
    if !aris_reader_pdfium::is_available() {
        eprintln!("skipping: PDFium unavailable");
        return;
    }
    let (_directory, path) = copy_fixture("touch-and-change");
    let (engine, first) = open(&path);
    let fresh = snapshot(&first);
    drop(first);

    // Same bytes, new mtime. Modification time is not part of the identity.
    File::open(&path)
        .expect("open for set_modified")
        .set_modified(SystemTime::now() + Duration::from_secs(60))
        .expect("touch the document");
    let touched = engine
        .open_document(path.display().to_string(), None)
        .expect("open after touch");
    assert_eq!(
        touched.index_cache_report().outcome,
        IndexCacheOutcome::Hit,
        "a touch that does not change bytes must not invalidate the cache"
    );
    assert_eq!(touched.index_cache_report().derived_parts, 0);
    drop(touched);

    // One appended byte is a different content identity even though the PDF still parses and
    // the parse results are unchanged.
    let mut append = OpenOptions::new()
        .append(true)
        .open(&path)
        .expect("open for append");
    append.write_all(b" ").expect("append one byte");
    drop(append);
    let changed = engine
        .open_document(path.display().to_string(), None)
        .expect("open after a one-byte change");
    let report = changed.index_cache_report();
    assert_eq!(
        report.outcome,
        IndexCacheOutcome::Stale,
        "one changed byte must not hit the old cache"
    );
    let after = snapshot(&changed);
    assert_eq!(
        after, fresh,
        "the changed-byte document still parses as before"
    );
    drop(changed);

    // The changed document's complete index is now the cache, and it hits.
    let rebuilt = engine
        .open_document(path.display().to_string(), None)
        .expect("open after rebuild");
    assert_eq!(rebuilt.index_cache_report().outcome, IndexCacheOutcome::Hit);
}

#[test]
fn a_truncated_cache_is_ignored_rebuilt_and_the_document_still_parses() {
    if !aris_reader_pdfium::is_available() {
        eprintln!("skipping: PDFium unavailable");
        return;
    }
    let (_directory, path) = copy_fixture("truncated");
    let (engine, first) = open(&path);
    let fresh = snapshot(&first);
    drop(first);

    let sidecar = cache_path(&path);
    let length = fs::metadata(&sidecar).expect("cache exists").len();
    OpenOptions::new()
        .write(true)
        .open(&sidecar)
        .expect("open cache")
        .set_len(length / 2)
        .expect("truncate cache");

    let damaged = engine
        .open_document(path.display().to_string(), None)
        .expect("open with a truncated cache");
    assert_eq!(
        damaged.index_cache_report().outcome,
        IndexCacheOutcome::Corrupt,
        "a truncated cache is not a partial hit"
    );
    assert_eq!(
        snapshot(&damaged),
        fresh,
        "the document still parses identically"
    );
    drop(damaged);

    let rebuilt = engine
        .open_document(path.display().to_string(), None)
        .expect("open after repair");
    assert_eq!(
        rebuilt.index_cache_report().outcome,
        IndexCacheOutcome::Hit,
        "the repaired cache is usable again"
    );
}

#[test]
fn a_newer_cache_is_ignored_and_left_byte_for_byte_untouched() {
    if !aris_reader_pdfium::is_available() {
        eprintln!("skipping: PDFium unavailable");
        return;
    }
    let (_directory, path) = copy_fixture("future-version");
    let sidecar = cache_path(&path);
    let future = br#"{
  "kind": "lyra-document-index",
  "format_version": 9999,
  "engine_version": "future",
  "content": {"sha256": "00", "bytes": 0},
  "page_count": 1,
  "outline": [],
  "references": {"style": {}, "records": []},
  "figures": [],
  "metadata": {},
  "citations": {}
}
"#;
    fs::write(&sidecar, future).expect("write a future cache");

    let (engine, document) = open(&path);
    let report = document.index_cache_report();
    assert_eq!(
        report.outcome,
        IndexCacheOutcome::FutureVersion,
        "{report:?}"
    );
    assert!(report.write_disabled, "a newer cache is never overwritten");
    let references = document.references().expect("references from a full parse");
    assert!(
        !references.is_empty(),
        "the fixture has a reference list, so this proves the parse still happened"
    );
    let _ = document.figures().expect("figures");
    let _ = document.outline().expect("outline");
    let _ = document.metadata().expect("metadata");
    drop(document);
    drop(engine);

    assert_eq!(
        fs::read(&sidecar).expect("future cache still exists"),
        future,
        "the newer Lyra's cache must survive this build opening the document"
    );
}

#[test]
fn a_read_only_directory_still_opens_and_indexes() {
    if !aris_reader_pdfium::is_available() {
        eprintln!("skipping: PDFium unavailable");
        return;
    }
    let directory = scratch("read-only");
    let path = directory.path.join("document.pdf");
    fs::copy(fixture("two-column-references.pdf"), &path).expect("copy fixture");
    let guard = ReadOnlyDir::new(&directory.path);
    let sidecar = cache_path(&path);

    let (engine, document) = open(&path);
    // Report first: the lookup itself must not fail just because the directory is read-only.
    let report = document.index_cache_report();
    assert!(
        matches!(
            report.outcome,
            IndexCacheOutcome::Missing | IndexCacheOutcome::Unreadable
        ),
        "{report:?}"
    );
    let references = document.references().expect("references");
    let figures = document.figures().expect("figures");
    let metadata = document.metadata().expect("metadata");
    let outline = document.outline().expect("outline");
    assert!(!references.is_empty(), "the fixture's index is not empty");
    let _ = (figures, metadata, outline);
    let after = document.index_cache_report();
    if sidecar.exists() {
        // Root (or a filesystem that ignores the mode) can still write; the requirement is that
        // the document worked, so do not turn a permissive environment into a failure.
        eprintln!("note: the scratch directory is still writable by this user");
    } else {
        assert!(
            after.write_disabled,
            "a failed cache write disables further writes: {after:?}"
        );
        assert!(
            after.write_error.is_some(),
            "the failure is reported, not hidden"
        );
    }
    drop(document);
    drop(engine);
    drop(guard);
}

/// Makes a directory non-writable for the duration of a test, restoring it on drop (and on panic,
/// so the scratch directory can still be removed).
struct ReadOnlyDir {
    path: PathBuf,
    original: Option<fs::Permissions>,
}

impl ReadOnlyDir {
    fn new(path: &Path) -> Self {
        use std::os::unix::fs::PermissionsExt;
        let original = fs::metadata(path)
            .ok()
            .map(|metadata| metadata.permissions());
        let mut permissions = original
            .clone()
            .unwrap_or_else(|| fs::Permissions::from_mode(0o755));
        permissions.set_mode(0o555);
        fs::set_permissions(path, permissions).expect("make the scratch directory read-only");
        Self {
            path: path.to_path_buf(),
            original,
        }
    }
}

impl Drop for ReadOnlyDir {
    fn drop(&mut self) {
        if let Some(permissions) = self.original.take() {
            let _ = fs::set_permissions(&self.path, permissions);
        }
    }
}
