//! A real PDF, read through PDFium: the T4.12 caption false-positive fixture.
//!
//! `scripts/make-fixtures.py` writes `tests/fixtures/caption-false-positive.pdf` with the shape
//! that used to put running prose into the figure index. Page 1 is a paragraph printed across
//! three lines; the extractor breaks it at the printer's line ends, so the middle line begins
//! `Table 3. We observe …` — the label is the tail of the sentence above. The same page carries a
//! real `Figure 1` caption after a paragraph break, and page 2 carries the real `Table 3` caption.
//!
//! The assertions are the T4.12 contract in both directions: the wrapped prose occurrence yields
//! no caption and is a mention (a click target in the body), while the real label of the same
//! number on another page is a caption. A detector that only reads line-start punctuation fails
//! the first assertion; one that drops label lines generally fails the second.

use lyra_reader_core::{DocumentBackend, PageIndex, RawTextPage};
use lyra_reader_pdfium::PdfiumBackend;
use lyra_reader_text::{find_caption_mentions, find_captions};
mod common;

fn open_fixture() -> Option<(PdfiumBackend, Vec<(u32, RawTextPage)>)> {
    if !lyra_reader_pdfium::is_available() {
        eprintln!("skipping: no PDFium");
        return None;
    }
    let backend = PdfiumBackend::open(&common::fixture("caption-false-positive.pdf"), None)
        .expect("open fixture");
    let pages = (0..backend.page_count())
        .map(|page| {
            (
                page,
                backend
                    .raw_text_page(PageIndex(page))
                    .expect("extract fixture page"),
            )
        })
        .collect();
    Some((backend, pages))
}

#[test]
fn a_wrapped_prose_label_is_a_mention_and_the_real_labels_are_captions() {
    let Some((_backend, pages)) = open_fixture() else {
        return;
    };
    assert_eq!(pages.len(), 2, "the fixture is two pages");

    // Page 1: the prose occurrence of `Table 3` is not a caption; the real `Figure 1` is.
    let page_one = find_captions(&pages[0].1);
    let kinds: Vec<(&str, &str)> = page_one
        .iter()
        .map(|caption| (caption.kind.as_str(), caption.label.as_str()))
        .collect();
    assert_eq!(kinds, [("Figure", "1")], "{page_one:?}");
    assert!(
        page_one[0].text.contains("three stages") && page_one[0].text.contains("one encoder"),
        "the caption's continuation line is part of it: {:?}",
        page_one[0].text
    );

    // The prose occurrence returns to the mention stream: it is a click target in the body, and
    // the occurrence that opens the real caption on page 2 is not.
    let mentions = find_caption_mentions(&pages[0].1);
    let table_mentions: Vec<_> = mentions
        .iter()
        .filter(|mention| mention.kind == "Table" && mention.label == "3")
        .collect();
    assert_eq!(table_mentions.len(), 1, "{mentions:?}");

    // Page 2: the real `Table 3:` caption is found.
    let page_two = find_captions(&pages[1].1);
    assert_eq!(page_two.len(), 1, "{page_two:?}");
    assert_eq!(
        (page_two[0].kind.as_str(), page_two[0].label.as_str()),
        ("Table", "3")
    );
    assert!(
        page_two[0].text.contains("Settings used by every run"),
        "{:?}",
        page_two[0].text
    );
    // The real caption's own start is suppressed from the mention stream.
    assert!(
        find_caption_mentions(&pages[1].1)
            .iter()
            .all(|mention| !(mention.kind == "Table" && mention.label == "3")),
        "the real caption was also offered as a mention"
    );
}
