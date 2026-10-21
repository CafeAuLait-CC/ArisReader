//! The app's citation click path, end to end through the FFI object: a citation carries the page
//! it was found on, and that page decides which reference list it resolves against.
//!
//! The committed `multi-bibliography.pdf` prints a main list and an appendix list, both numbered
//! from 1, where `[3]` names different works. Before T4.42 the shell called a resolver that had
//! no page and always used the document-wide list, so the appendix's `[3]` previewed the main
//! list's third entry. These tests drive `LyraReaderEngine`/`LyraReaderDocument` — the same objects the Swift
//! `RustEngine` wraps — and assert the entries and the attributed list. They skip with a printed
//! reason when PDFium is absent (the Linux CI runner has no library).
//!
//! The Swift click path (`AppState.previewCitation` → `PDFEngine.resolveCitations(labels:page:)`
//! → `LyraReaderDocument::resolve_citations_on`) is compiled by `check.sh`; it is not driven here,
//! because these tests deliberately stay on the Rust side of the FFI boundary.

#[path = "support/index_cache.rs"]
mod cache_test;

use lyra_reader_ffi::api::{
    CitationRecord, IndexCacheOutcome, LyraReaderDocument, LyraReaderEngine, ReferenceRecord,
    ResolvedReference,
};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

/// Resolves a committed fixture at run time, without a compile-time path.
fn fixture(name: &str) -> PathBuf {
    if let Some(override_dir) = std::env::var_os("LYRA_READER_TEST_FIXTURES")
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
        let _ = fs::remove_dir_all(&self.path);
    }
}

fn scratch(label: &str) -> ScratchDir {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let root = std::env::temp_dir()
        .canonicalize()
        .unwrap_or_else(|_| std::env::temp_dir());
    let nanosecond = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    for _ in 0..64 {
        let sequence = NEXT.fetch_add(1, Ordering::Relaxed);
        let path = root.join(format!(
            "lyra-reader-citation-attribution-test-{}-{sequence}-{nanosecond}-{label}",
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

fn copy_named_fixture(label: &str, name: &str) -> (ScratchDir, PathBuf) {
    let directory = scratch(label);
    let path = directory.path.join("document.pdf");
    fs::copy(fixture(name), &path).expect("copy fixture");
    (directory, path)
}

fn open(path: &Path) -> (Arc<LyraReaderEngine>, Arc<LyraReaderDocument>) {
    let engine = LyraReaderEngine::new();
    let document = engine
        .open_document(path.display().to_string(), None)
        .expect("open document");
    (engine, document)
}

fn texts(resolved: &[ResolvedReference]) -> Vec<&str> {
    resolved
        .iter()
        .map(|resolved| resolved.reference.text.as_str())
        .collect()
}

#[test]
fn a_page_citation_resolves_into_the_list_its_section_cites() {
    if !lyra_reader_pdfium::is_available() {
        eprintln!("skipping: PDFium unavailable");
        return;
    }
    let (_directory, path) = copy_named_fixture("two-lists", "multi-bibliography.pdf");
    let (_engine, document) = open(&path);

    // The document-wide list is what the app lists as "the references"; it must not change.
    let document_wide = document.references().expect("references");
    assert_eq!(document_wide.len(), 6);
    assert!(
        document_wide
            .iter()
            .any(|entry| entry.label == "3" && entry.text.contains("Report work three"))
    );

    // The body's `[3]` — page 0 — is the main list's third entry.
    let body = document
        .resolve_citations_on(0, vec!["3".to_string()])
        .expect("resolve body citation");
    assert_eq!(body.len(), 1, "{body:?}");
    assert!(
        body[0].reference.text.contains("Report work three"),
        "{:?}",
        body[0].reference.text
    );
    assert_eq!(body[0].list_index, 0);
    assert_eq!(body[0].list_count, 2);
    assert_eq!(body[0].list_heading.as_deref(), Some("References"));
    assert_eq!(body[0].list_first_page, Some(1));
    assert!(body[0].document_wide, "{body:?}");
    assert!(!body[0].ambiguous);
    assert!(
        body[0].reason.contains("document-wide"),
        "{}",
        body[0].reason
    );

    // The appendix's `[3]` — page 2 — is the appendix list's third entry, a different work.
    let appendix = document
        .resolve_citations_on(2, vec!["3".to_string()])
        .expect("resolve appendix citation");
    assert_eq!(appendix.len(), 1, "{appendix:?}");
    assert!(
        appendix[0].reference.text.contains("Card work three"),
        "{:?}",
        appendix[0].reference.text
    );
    assert!(!appendix[0].reference.text.contains("Report work"));
    assert_eq!(appendix[0].list_index, 1);
    assert_eq!(appendix[0].list_first_page, Some(3));
    assert!(!appendix[0].document_wide);
    assert!(
        appendix[0].reason.contains("section"),
        "{}",
        appendix[0].reason
    );

    // A number only the appendix prints resolves there and names the appendix list.
    let only_appendix = document
        .resolve_citations_on(0, vec!["7".to_string()])
        .expect("resolve appendix-only citation");
    assert_eq!(only_appendix.len(), 1);
    assert!(only_appendix[0].reference.text.contains("Card work seven"));
    assert_eq!(only_appendix[0].list_index, 1);
    assert!(!only_appendix[0].document_wide);

    // After both lists, proximity alone does not choose: the document-wide list is used and the
    // ambiguity is reported.
    let closing = document
        .resolve_citations_on(4, vec!["3".to_string()])
        .expect("resolve closing citation");
    assert_eq!(closing.len(), 1);
    assert!(closing[0].reference.text.contains("Report work three"));
    assert!(closing[0].document_wide);
    assert!(closing[0].ambiguous, "{closing:?}");

    // The old, page-less method is unchanged: it still answers from the document-wide list, which
    // is exactly why the shell needed the page.
    let legacy = document
        .resolve_citations(vec!["3".to_string()])
        .expect("legacy resolve");
    assert_eq!(legacy.len(), 1);
    assert!(legacy[0].text.contains("Report work three"));
    assert!(!legacy[0].text.contains("Card work"));
}

#[test]
fn a_single_list_document_resolves_exactly_as_before() {
    if !lyra_reader_pdfium::is_available() {
        eprintln!("skipping: PDFium unavailable");
        return;
    }
    let (_directory, path) = copy_named_fixture("single-list", "numeric-citations.pdf");
    let (_engine, document) = open(&path);
    let _ = document.references().expect("references");

    // Every citation the app would show on the body page: the page-aware path must produce the
    // same entries, with the same identity and geometry, as the page-less path.
    let citations: Vec<CitationRecord> = document.citations(0).expect("citations");
    let mut checked = 0usize;
    for citation in citations {
        if citation.labels.is_empty() {
            continue;
        }
        let page_aware = document
            .resolve_citations_on(0, citation.labels.clone())
            .expect("page-aware resolution");
        let legacy = document
            .resolve_citations(citation.labels.clone())
            .expect("legacy resolution");
        let page_aware_entries: Vec<ReferenceRecord> = page_aware
            .iter()
            .map(|resolved| resolved.reference.clone())
            .collect();
        assert_eq!(
            page_aware_entries, legacy,
            "single-list resolution changed for {:?}",
            citation.labels
        );
        for resolved in &page_aware {
            assert_eq!(resolved.list_count, 1);
            assert_eq!(resolved.list_index, 0);
            assert!(resolved.document_wide);
            assert!(!resolved.ambiguous);
        }
        checked += 1;
    }
    assert!(checked > 0, "the fixture detected no citation to compare");
}

#[test]
fn a_cache_hit_keeps_the_lists_and_still_attributes_the_appendix() {
    if !cache_test::isolated("a_cache_hit_keeps_the_lists_and_still_attributes_the_appendix") {
        return;
    }
    if !lyra_reader_pdfium::is_available() {
        eprintln!("skipping: PDFium unavailable");
        return;
    }
    let (_directory, path) = copy_named_fixture("two-lists-cache", "multi-bibliography.pdf");
    {
        let (_engine, document) = open(&path);
        let fresh = document.index_cache_report();
        assert_eq!(fresh.outcome, IndexCacheOutcome::Missing, "{fresh:?}");
        let _ = document.references().expect("references");
        let _ = document.figures().expect("figures");
        let _ = document.metadata().expect("metadata");
        let _ = document.outline().expect("outline");
        let written = document.index_cache_report();
        assert!(
            written.cache_bytes > 0,
            "the cold open did not write an index: {written:?}"
        );
    }
    // A second open of the same bytes must hit the application cache and still know both lists.
    let (_engine, document) = open(&path);
    let hit = document.index_cache_report();
    assert_eq!(hit.outcome, IndexCacheOutcome::Hit, "{hit:?}");
    assert_eq!(hit.derived_parts, 0, "{hit:?}");
    let appendix = document
        .resolve_citations_on(2, vec!["3".to_string()])
        .expect("resolve appendix citation from cache");
    assert_eq!(appendix.len(), 1);
    assert!(appendix[0].reference.text.contains("Card work three"));
    assert_eq!(appendix[0].list_index, 1);
    let body = document
        .resolve_citations_on(0, vec!["3".to_string()])
        .expect("resolve body citation from cache");
    assert!(body[0].reference.text.contains("Report work three"));
    assert_eq!(
        texts(&body),
        ["Three 2021. Report work three."],
        "the cached document-wide list changed"
    );
}
