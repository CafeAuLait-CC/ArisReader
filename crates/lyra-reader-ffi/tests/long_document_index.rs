//! T4.13: a long document is indexed past page 120.
//!
//! The committed fixture `index-past-120.pdf` has 130 pages: a two-entry bibliography on page 2,
//! a real `Figure 1` caption on page 121, and a real `Table 1` caption plus a `[1]` citation on
//! page 125. Before T4.13 the caption index stopped at page 120, so both captions were simply
//! absent from `figures()`; the citation map stopped there too, so page 125 was re-extracted on
//! every click and never persisted. This test pins both halves:
//!
//! * the API returns the late captions and the late citation;
//! * the application cache on disk carries them, which is what makes the second open a hit rather than a
//!   re-derivation (a version-1 cache would have neither field for this file).
//!
//! Both the fixture and the application cache use private temporary directories, so the
//! committed fixtures and the user's cache remain untouched. Every assertion is skipped with an
//! announcement when PDFium is unavailable, like the other FFI integration tests.

#[path = "support/index_cache.rs"]
mod cache_test;

use lyra_reader_ffi::api::LyraReaderEngine;
use std::fs;
use std::path::{Path, PathBuf};

/// A unique scratch directory, removed when the test ends.
struct ScratchDir {
    path: PathBuf,
}

impl Drop for ScratchDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

fn scratch(label: &str) -> ScratchDir {
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let sequence = NEXT.fetch_add(1, Ordering::Relaxed);
    let path = std::env::temp_dir().join(format!(
        "lyra-reader-long-index-{label}-{}-{sequence}",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&path);
    fs::create_dir_all(&path).expect("scratch directory");
    ScratchDir { path }
}

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
    panic!("committed fixture {name:?} not found (LYRA_READER_TEST_FIXTURES overrides the search)");
}

fn cache_path(document: &Path) -> PathBuf {
    let path = lyra_reader_ffi::document_index_cache_path(document);
    fs::create_dir_all(path.parent().unwrap()).expect("create index cache directory");
    path
}

#[test]
fn captions_and_citations_past_page_120_are_returned_and_persisted() {
    if !cache_test::isolated("captions_and_citations_past_page_120_are_returned_and_persisted") {
        return;
    }
    if !lyra_reader_pdfium::is_available() {
        eprintln!("skipping: PDFium unavailable");
        return;
    }
    let directory = scratch("past-120");
    let path = directory.path.join("index-past-120.pdf");
    fs::copy(fixture("index-past-120.pdf"), &path).expect("copy fixture");

    let engine = LyraReaderEngine::new();
    let document = engine
        .open_document(path.display().to_string(), None)
        .expect("open the long fixture");
    assert_eq!(document.page_count(), 130);

    // Build every component the way a reader does: the cache is written only when all four
    // exist. `citations(124)` is the late page, not page 0.
    let _ = document.outline().expect("outline");
    let references = document.references().expect("references");
    let figures = document.figures().expect("figures");
    let _ = document.metadata().expect("metadata");
    let late_citations = document.citations(124).expect("late citations");

    assert_eq!(
        references.len(),
        2,
        "the reference list is found and parsed: {references:?}"
    );
    assert_eq!(
        references
            .iter()
            .map(|entry| entry.label.as_str())
            .collect::<Vec<_>>(),
        ["1", "2"]
    );

    let late_figure = figures
        .iter()
        .find(|figure| figure.page == 120)
        .expect("the Figure 1 caption on page 121 is in the index");
    assert_eq!(
        (late_figure.kind.as_str(), late_figure.label.as_str()),
        ("Figure", "1")
    );
    assert!(
        late_figure.caption_text.contains("Late figure on page 121"),
        "{late_figure:?}"
    );

    let late_table = figures
        .iter()
        .find(|figure| figure.page == 124)
        .expect("the Table 1 caption on page 125 is in the index");
    assert_eq!(
        (late_table.kind.as_str(), late_table.label.as_str()),
        ("Table", "1")
    );
    assert!(
        late_table.caption_text.contains("Late table on page 125"),
        "{late_table:?}"
    );

    // The citation on page 125 resolves against the bibliography, so this is not merely a span:
    // the document's own style and list are behind it.
    assert_eq!(
        late_citations.len(),
        1,
        "the late page's [1] citation: {late_citations:?}"
    );
    assert_eq!(late_citations[0].labels, ["1"]);
    assert_eq!(late_citations[0].page, 124);

    // The persisted index carries the late records. This is the part that fails on the capped
    // implementation: its figure list stopped at page 120 and its citation map at page 120, so a
    // second open of unchanged bytes could not have answered from the cache.
    let sidecar = cache_path(&path);
    let bytes = fs::read(&sidecar).unwrap_or_else(|error| {
        panic!(
            "the index cache was not written at {}: {error}",
            sidecar.display()
        )
    });
    let value: serde_json::Value = serde_json::from_slice(&bytes).expect("cache is JSON");
    let figures_json = value["figures"].as_array().expect("figures array");
    assert!(
        figures_json
            .iter()
            .any(|figure| figure["page"].as_u64().is_some_and(|page| page >= 120)),
        "the persisted figure index has no caption past page 120: {figures_json:?}"
    );
    let citations_json = value["citations"].as_object().expect("citations object");
    assert!(
        citations_json
            .get("124")
            .and_then(serde_json::Value::as_array)
            .is_some_and(|records| !records.is_empty()),
        "the persisted citation index has no entry for page 125: {citations_json:?}"
    );

    // And a second open of the same bytes answers from the cache, late records included.
    drop(document);
    let cached = engine
        .open_document(path.display().to_string(), None)
        .expect("cached open");
    assert_eq!(
        cached.index_cache_report().outcome,
        lyra_reader_ffi::api::IndexCacheOutcome::Hit,
        "the second open did not hit the cache"
    );
    let cached_figures = cached.figures().expect("cached figures");
    assert!(
        cached_figures
            .iter()
            .any(|figure| figure.page >= 120 && figure.label == "1"),
        "the cached figure index lost the late caption"
    );
    assert!(
        !cached
            .citations(124)
            .expect("cached late citations")
            .is_empty(),
        "the cached citation index lost page 125"
    );
}
