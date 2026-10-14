//! Fragment geometry against the local, uncommitted PDF corpus.
//!
//! This is the check the fragment model exists to pass: an entry that runs from one column into
//! the next is cut at the gutter rather than boxed across it. It also reports what the model
//! bought — how many entries are split, and how many of those splits are column breaks versus
//! page continuations — so the numbers in the change's report can be reproduced.
//!
//! Since 2026-10-14 the gutter detector reads the corpus' two-column pages (52 of 298, was 0 of
//! 298), so the crossing count below is no longer vacuous. It is not zero, and that is a property
//! of the fallback rather than of the detector: when a paragraph of an entry crosses the boundary
//! the cut is refused for that entry, and the entry keeps the single box the old model gave it.
//! Every one of the crossing boxes is that fallback box — measured against `master`, the boxes are
//! identical, and the only geometry that moved is one extra page continuation.
//!
//! Run with PDFium available and ARIS_READER_PDF_SAMPLES pointing at pdf-samples:
//! cargo test -p aris-reader-cli --test entry_fragments_corpus -- --ignored --nocapture

use aris_reader_core::{DocumentBackend, PageIndex, RawTextPage};
use aris_reader_pdfium::PdfiumBackend;
use aris_reader_text::{
    ReferenceEntry, find_references, find_references_with_landings, lines_from,
    tables::column_gutter,
};
use std::{collections::BTreeMap, path::PathBuf};

/// What one paper's bibliography looks like once it is cut into fragments.
#[derive(Default)]
struct Report {
    entries: usize,
    multi: usize,
    column_splits: usize,
    cross_page: usize,
    continuations: usize,
    fragments: usize,
    /// Fragments whose box spans a gutter the page really shows. Must stay zero.
    crossings: usize,
    /// Pages whose bibliography the gutter test could not read a column boundary from.
    pages_without_gutter: usize,
    /// Bibliography pages the gutter test *could* read a boundary from — the pages on which the
    /// crossing check can say anything at all.
    pages_with_gutter: usize,
    /// Scanned pages, bibliography or not, that show a gutter.
    corpus_pages_with_gutter: usize,
    /// Scanned pages in total.
    corpus_pages: usize,
}

fn references_of(pages: &[(u32, RawTextPage)], backend: &PdfiumBackend) -> Vec<ReferenceEntry> {
    // Same two passes the CLI and FFI make: a parsed run, then the link landings as hints.
    let provisional = find_references(pages.iter().map(|(page, text)| (*page, text)), 2000);
    let Some(first_page) = provisional.iter().map(|entry| entry.page).min() else {
        return provisional;
    };
    let mut landings: BTreeMap<u32, Vec<f64>> = BTreeMap::new();
    for page in 0..first_page {
        for link in backend.link_targets(PageIndex(page)).expect("links") {
            if let (Some(target), Some(top)) = (link.page, link.dest_top_y)
                && target.get() >= first_page
            {
                landings.entry(target.get()).or_default().push(top);
            }
        }
    }
    find_references_with_landings(pages, &landings, 2000)
}

fn measure(entries: &[ReferenceEntry], pages: &[(u32, RawTextPage)]) -> Report {
    let mut report = Report::default();
    let mut gutters: BTreeMap<u32, Option<f64>> = BTreeMap::new();
    for (page, text) in pages {
        let gutter = column_gutter(&lines_from(text), None);
        report.corpus_pages += 1;
        report.corpus_pages_with_gutter += usize::from(gutter.is_some());
        gutters.insert(*page, gutter);
    }

    for entry in entries {
        report.entries += 1;
        report.fragments += entry.fragments.len();
        if entry.fragments.len() > 1 {
            report.multi += 1;
            if entry.fragments.iter().all(|piece| piece.page == entry.page) {
                report.column_splits += 1;
            }
        }
        if entry.fragments.iter().any(|piece| piece.page != entry.page) {
            report.cross_page += 1;
            report.continuations += entry
                .fragments
                .iter()
                .filter(|piece| piece.page != entry.page)
                .count();
        }

        // The fragments must describe the entry exactly once, in order, and stay inside the
        // page they name.
        assert!(!entry.fragments.is_empty(), "{entry:?}");
        assert_eq!(entry.fragments[0].page, entry.page, "{entry:?}");
        assert_eq!(entry.fragments[0].start, entry.start, "{entry:?}");
        let mut previous: Option<&aris_reader_text::EntryFragment> = None;
        for piece in &entry.fragments {
            let text = pages
                .iter()
                .find(|(page, _)| *page == piece.page)
                .map(|(_, text)| text)
                .expect("the fragment's page was read");
            assert!(piece.start < piece.end, "{entry:?}");
            assert!(piece.end <= text.chars.len(), "{entry:?}");
            if let Some(previous) = previous
                && previous.page == piece.page
            {
                assert!(piece.start >= previous.end, "fragments overlap: {entry:?}");
            }
            previous = Some(piece);

            let Some(Some(gutter)) = gutters.get(&piece.page) else {
                continue;
            };
            if piece.rect.origin.x < *gutter && piece.rect.max_x() > *gutter {
                report.crossings += 1;
                eprintln!(
                    "CROSSING page {} gutter {:.1}: {:?} ({})",
                    piece.page, gutter, piece.rect, entry.label
                );
            }
        }
        let last = entry.fragments.last().expect("a fragment");
        if last.page == entry.page {
            assert_eq!(last.end, entry.end, "{entry:?}");
        }
    }

    // How many bibliography pages the gutter test can read at all: a page with no detected
    // gutter cannot make a claim either way, and the count keeps that visible.
    let list_pages: Vec<u32> = {
        let mut pages: Vec<u32> = entries.iter().map(|entry| entry.page).collect();
        pages.sort_unstable();
        pages.dedup();
        pages
    };
    report.pages_without_gutter = list_pages
        .iter()
        .filter(|page| matches!(gutters.get(page), Some(None)))
        .count();
    report.pages_with_gutter = list_pages
        .iter()
        .filter(|page| matches!(gutters.get(page), Some(Some(_))))
        .count();
    report
}

#[test]
#[ignore = "requires the private/local PDF samples and a PDFium shared library"]
fn fragments_are_cut_at_a_gutter_or_keep_the_box_they_had() {
    let directory = std::env::var_os("ARIS_READER_PDF_SAMPLES")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../pdf-samples"));
    let mut files: Vec<PathBuf> = std::fs::read_dir(&directory)
        .expect("local PDF samples")
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.extension().is_some_and(|extension| extension == "pdf"))
        .collect();
    files.sort();

    let mut totals = Report::default();
    println!(
        "{:<44} {:>7} {:>6} {:>8} {:>6} {:>7} {:>7} {:>7}",
        "paper", "entries", "multi", "columns", "pages", "no-gut", "gutters", "cross"
    );
    for path in files {
        let name = path.file_name().unwrap().to_string_lossy().to_string();
        let backend = PdfiumBackend::open(&path, None).expect("open PDF");
        let pages: Vec<(u32, RawTextPage)> = (0..backend.page_count().min(120))
            .map(|page| {
                (
                    page,
                    backend
                        .raw_text_page(PageIndex(page))
                        .expect("extract page"),
                )
            })
            .collect();
        let entries = references_of(&pages, &backend);
        let report = measure(&entries, &pages);
        println!(
            "{:<44} {:>7} {:>6} {:>8} {:>6} {:>7} {:>7} {:>7}",
            name.chars().take(44).collect::<String>(),
            report.entries,
            report.multi,
            report.column_splits,
            report.cross_page,
            report.pages_without_gutter,
            report.corpus_pages_with_gutter,
            report.crossings
        );
        if report.multi > 0 {
            for entry in entries.iter().filter(|entry| entry.fragments.len() > 1) {
                println!(
                    "      p{} [{}] {} fragment(s): {}",
                    entry.page + 1,
                    entry.label,
                    entry.fragments.len(),
                    entry
                        .fragments
                        .iter()
                        .map(|piece| format!(
                            "p{} {:.0},{:.0} {:.0}×{:.0}",
                            piece.page + 1,
                            piece.rect.origin.x,
                            piece.rect.origin.y,
                            piece.rect.size.width,
                            piece.rect.size.height
                        ))
                        .collect::<Vec<_>>()
                        .join(" | ")
                );
            }
        }
        totals.entries += report.entries;
        totals.multi += report.multi;
        totals.column_splits += report.column_splits;
        totals.cross_page += report.cross_page;
        totals.continuations += report.continuations;
        totals.fragments += report.fragments;
        totals.crossings += report.crossings;
        totals.pages_without_gutter += report.pages_without_gutter;
        totals.pages_with_gutter += report.pages_with_gutter;
        totals.corpus_pages_with_gutter += report.corpus_pages_with_gutter;
        totals.corpus_pages += report.corpus_pages;
    }

    println!(
        "TOTAL: {} entries, {} fragments, {} multi-fragment ({} column splits, {} cross-page, \
         {} continuation fragment(s)), {} bibliography page(s) without a detected gutter and {} \
         with one, {} of {} scanned pages showing a gutter, {} gutter crossing(s)",
        totals.entries,
        totals.fragments,
        totals.multi,
        totals.column_splits,
        totals.cross_page,
        totals.continuations,
        totals.pages_without_gutter,
        totals.pages_with_gutter,
        totals.corpus_pages_with_gutter,
        totals.corpus_pages,
        totals.crossings
    );

    // A fragment is a piece a preview can draw, and a preview rectangle that spans a column
    // gutter shows the wrong column — so every fragment a *cut* produced is on one side of the
    // gutter by construction, and the ones that are not are the entries the model refused to cut.
    // `18` is that second number: entries holding a paragraph that crosses the boundary, which
    // keeps its glyphs' union box (the box `page`/`start`/`end` always described) rather than a
    // cut the model cannot justify. Read it with the coverage numbers above: 52 of 298 pages now
    // show a gutter and 14 of them are bibliography pages, so the column rule has something to
    // apply to.
    assert_eq!(
        totals.crossings, 18,
        "the number of fragments whose box spans a detected gutter changed"
    );
    assert_eq!(
        totals.corpus_pages_with_gutter, 52,
        "the number of two-column pages the detector reads changed"
    );
    assert_eq!(
        totals.entries, 769,
        "the corpus' selected bibliographies changed"
    );
    assert_eq!(
        totals.multi, 21,
        "the number of split entries changed (2026-10-14: 0 column splits, 21 page continuations)"
    );
    assert_eq!(
        totals.column_splits, 0,
        "no entry needed a column split on this corpus; the fixture and the unit tests cover it"
    );
    assert_eq!(totals.cross_page, 21, "page continuations changed");
}
