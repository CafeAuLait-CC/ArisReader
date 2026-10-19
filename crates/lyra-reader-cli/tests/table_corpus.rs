//! Opt-in regression checks for table regions against the local, uncommitted PDF corpus.
//! Run with PDFium available and `LYRA_READER_PDF_SAMPLES` pointing at pdf-samples:
//! `cargo test -p lyra-reader-cli --test table_corpus -- --ignored --nocapture`
//!
//! The numbers asserted here are the ones `lyra-reader-cli tables` reports, and they are floors
//! rather than targets: a change that finds *more* tables is welcome, a change that finds fewer
//! has to be explained. What the grid rectangles actually contain was checked by eye — nineteen
//! of the twenty regions on this corpus are one table with its caption and nothing else, and the
//! measured numbers below are what the module docs quote.

use lyra_reader_core::{DocumentBackend, PageIndex};
use lyra_reader_pdfium::PdfiumBackend;
use lyra_reader_text::{find_captions, lines_from, tables::table_outcome};
use std::path::PathBuf;

mod common;

/// Every `Table` caption in the corpus, and how many of them got a grid region.
#[test]
#[ignore = "requires the private/local PDF samples and a PDFium shared library"]
fn table_captions_get_a_grid_region_when_the_page_draws_one() {
    let directory = common::samples_dir();
    let mut files: Vec<PathBuf> = std::fs::read_dir(&directory)
        .expect("local PDF samples")
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.extension().is_some_and(|kind| kind == "pdf"))
        .collect();
    files.sort();

    let mut captions = 0usize;
    let mut grids = 0usize;
    let mut manuscript_grids = 0usize;
    let mut humanmm_table_one = None;

    for path in &files {
        let name = path.file_name().unwrap().to_string_lossy().to_string();
        let backend = PdfiumBackend::open(path, None).expect("open PDF");
        let mut file_grids = 0usize;
        let mut file_captions = 0usize;

        for index in 0..backend.page_count() {
            let Ok(text) = backend.raw_text_page(PageIndex(index)) else {
                continue;
            };
            let tables: Vec<_> = find_captions(&text)
                .into_iter()
                .filter(|caption| caption.kind == "Table")
                .collect();
            if tables.is_empty() {
                continue;
            }
            let rules = backend
                .page_line_segments(PageIndex(index))
                .unwrap_or_default();
            let lines = lines_from(&text);

            for caption in tables {
                file_captions += 1;
                let (outcome, grid) = table_outcome(&caption, &rules, &lines);
                if let Some(grid) = grid {
                    file_grids += 1;
                    // A grid region is never degenerate, and never the whole page.
                    assert!(
                        grid.size.width >= 60.0 && grid.size.height >= 8.0,
                        "{name} p{} Table {}: {grid:?}",
                        index + 1,
                        caption.label
                    );
                    assert!(
                        grid.size.height < 700.0,
                        "{name} p{} Table {}: a grid taller than the page text: {grid:?}",
                        index + 1,
                        caption.label
                    );
                    if name.starts_with("Zhang") && index == 6 && caption.label == "1" {
                        humanmm_table_one = Some((grid, outcome));
                    }
                }
            }
        }

        if name.starts_with("manuscript") {
            manuscript_grids = file_grids;
        }
        println!("{name}: {file_captions} table caption(s), {file_grids} with a grid");
        captions += file_captions;
        grids += file_grids;
    }

    println!("total: {captions} table caption(s), {grids} with a grid region");

    // Measured 2026-10-13 on the 12-paper corpus: 41 `Table` captions, 20 of them with a grid.
    // T4.12 removed one of the 41 on 2026-10-17 — the wrapped prose `Table 3. Our correction
    // reduce …` on page 9 of the Leader paper, which was never a caption — leaving 40 captions,
    // the same 20 grid regions (the removed line was a fallback) and 20 fallbacks. A change that
    // finds *more* tables is still welcome; this pins the count so a loss is not mistaken for it.
    assert_eq!(captions, 40, "the corpus's table caption count changed");
    assert!(
        grids >= 20,
        "the corpus had 20 grid-derived tables; found {grids}"
    );
    // `manuscript_0925.pdf` is 13 `booktabs` tables with no vertical rules at all, which only the
    // text tier can accept: it is the paper that says whether that tier works.
    assert!(
        manuscript_grids >= 8,
        "manuscript_0925.pdf: {manuscript_grids} of 13 tables, expected at least 8"
    );

    // The concrete grid of one table, checked against the page: `Table 1` of the HumanMM paper is
    // the wide ruled table on page 7, its caption set under it. The preview adds the caption, so
    // the region the shell shows is (58.5, 609.6) 495.0 × 110.0.
    let (grid, outcome) = humanmm_table_one.expect("HumanMM page 7 Table 1");
    assert_eq!(
        (
            grid.origin.x.round(),
            grid.origin.y.round(),
            grid.size.width.round(),
            grid.size.height.round()
        ),
        (60.0, 622.0, 492.0, 97.0),
        "the region moved: {grid:?}"
    );
    // Its vertical rules cover only the top two thirds of the grid (they stop at the last
    // `\cmidrule` group), so the rows below them are believed on their text — which is the tier
    // working as intended rather than a miss.
    assert_eq!(outcome.label(), "text-only");
}
