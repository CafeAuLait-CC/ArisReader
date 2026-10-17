//! A real PDF, read through PDFium: the bare parenthesised numeral fixture.
//!
//! `scripts/make-fixtures.py` writes `tests/fixtures/numeric-citations.pdf` in the Nature/IEEE
//! numeric style: a two-page document whose bibliography prints `1.` … `14.` and whose body page
//! holds every accepted form (`(12)`, `(3–5)`, `(7, 9)`, `(3–5, 9)`) next to the non-citation
//! forms the detector must refuse — an equation number pushed to the right margin, a function
//! call, a year, two enumerations, a figure sub-label, a section reference and a number beyond
//! the bibliography's count.
//!
//! The test asserts every classification, that the accepted labels resolve, and that the
//! bracketed form of the same citation lands on the same bibliography entry. The fixture is
//! generated, not hand-edited: run `python3 scripts/make-fixtures.py` to reproduce it byte for
//! byte.

use aris_reader_core::{DocumentBackend, PageIndex, Point, RawCharBox, RawTextPage, Rect};
use aris_reader_pdfium::PdfiumBackend;
use aris_reader_text::{
    CitationStyle, ParenthesisedCandidate, find_citations, find_citations_with, find_references,
    inspect_parenthesised_citations, resolve_reference,
};
use std::path::Path;

fn fixture_path() -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/numeric-citations.pdf")
}

fn open_fixture() -> Option<(PdfiumBackend, Vec<(u32, RawTextPage)>)> {
    let fixture = fixture_path();
    if !fixture.exists() || !aris_reader_pdfium::is_available() {
        eprintln!("skipping: no numeric-citations fixture or no PDFium");
        return None;
    }
    let backend = PdfiumBackend::open(&fixture, None).expect("open fixture");
    let pages = (0..backend.page_count())
        .map(|page| {
            let text = backend
                .raw_text_page(PageIndex(page))
                .expect("extract fixture page");
            (page, text)
        })
        .collect();
    Some((backend, pages))
}

fn candidate<'a>(
    candidates: &'a [ParenthesisedCandidate],
    text: &str,
) -> &'a ParenthesisedCandidate {
    candidates
        .iter()
        .find(|candidate| candidate.text == text)
        .unwrap_or_else(|| panic!("candidate {text}: {candidates:?}"))
}

#[test]
fn every_parenthesised_numeral_shape_is_classified_on_a_real_pdf() {
    let Some((_backend, pages)) = open_fixture() else {
        return;
    };
    let references = find_references(pages.iter().map(|(page, text)| (*page, text)), 100);
    assert_eq!(
        references
            .iter()
            .map(|entry| entry.label.as_str())
            .collect::<Vec<_>>(),
        (1..=14)
            .map(|number| number.to_string())
            .collect::<Vec<_>>(),
        "the fixture bibliography must print 1. … 14."
    );
    let style = CitationStyle::for_document(&pages, &references);
    assert!(
        style.bibliography_is_numeric(),
        "the fixture bibliography is numbered"
    );
    assert_eq!(style.reference_count(), 14);
    assert_eq!(style.numeric_label_count(), 14);
    assert!(
        style.accepts_parenthesised_numerals(),
        "a numbered, non-bracketing bibliography enables the detector"
    );

    let body = &pages[0].1;
    assert!(
        find_citations(body).is_empty(),
        "the fixture body has no bracket or author-year citation"
    );

    let citations = find_citations_with(body, &style);
    let texts: Vec<&str> = citations
        .iter()
        .map(|citation| citation.text.as_str())
        .collect();
    assert_eq!(
        texts,
        ["(12)", "(3–5)", "(7, 9)", "(3–5, 9)"],
        "accepted spans, in reading order"
    );
    assert_eq!(citations[0].labels, ["12"]);
    assert_eq!(citations[1].labels, ["3", "4", "5"]);
    assert_eq!(citations[2].labels, ["7", "9"]);
    assert_eq!(citations[3].labels, ["3", "4", "5", "9"]);

    // Every citation resolves, and every label inside a group does too.
    for citation in &citations {
        assert!(
            resolve_reference(&citation.labels, &references).is_some(),
            "{} did not resolve",
            citation.text
        );
        for label in &citation.labels {
            assert!(
                resolve_reference(std::slice::from_ref(label), &references).is_some(),
                "{} label {label} did not resolve",
                citation.text
            );
        }
    }
    let single = resolve_reference(&citations[0].labels, &references).expect("(12)");
    assert_eq!(single.label, "12");
    assert!(
        single.text.contains("The cited baseline method"),
        "{}",
        single.text
    );

    // The bracketed form of the same citation produces the same labels, and therefore resolves
    // to the very same entry. This is what makes the existing click, preview and bibliography
    // code work without a branch for parenthesised numerals.
    let bracket_page = page_from("As shown in [12], the method works.");
    let bracketed = find_citations(&bracket_page);
    assert_eq!(bracketed.len(), 1);
    assert_eq!(bracketed[0].labels, citations[0].labels);
    let bracketed_entry = resolve_reference(&bracketed[0].labels, &references).expect("[12]");
    assert_eq!(
        (
            bracketed_entry.label.as_str(),
            bracketed_entry.text.as_str(),
            bracketed_entry.page,
            bracketed_entry.start,
            bracketed_entry.end,
        ),
        (
            single.label.as_str(),
            single.text.as_str(),
            single.page,
            single.start,
            single.end
        ),
        "the parenthesised and bracketed forms must land on the same entry"
    );

    // Every candidate, accepted or rejected, with the reason the CLI prints.
    let candidates = inspect_parenthesised_citations(body, &style);
    let accepted: Vec<&str> = candidates
        .iter()
        .filter(|candidate| candidate.accepted)
        .map(|candidate| candidate.text.as_str())
        .collect();
    assert_eq!(accepted, texts);
    for candidate in candidates.iter().filter(|candidate| candidate.accepted) {
        assert!(
            candidate.reason.contains("prose"),
            "{}: {}",
            candidate.text,
            candidate.reason
        );
        assert!(candidate.rect.size.width > 0.0);
    }

    // Year-shaped.
    let year = candidate(&candidates, "(2020)");
    assert!(!year.accepted && year.reason.contains("year"), "{year:?}");
    assert_eq!(year.labels, ["2020"]);

    // Enumerations: both open their line.
    for text in ["(1)", "(2)"] {
        let enumeration = candidate(&candidates, text);
        assert!(
            !enumeration.accepted && enumeration.reason.contains("enumeration"),
            "{enumeration:?}"
        );
    }

    // Out of range: fourteen entries, so 25 cannot label one.
    let outside = candidate(&candidates, "(25)");
    assert!(!outside.accepted && outside.reason.contains("entry count"));

    // Two `(3)` spans: the display equation's right-aligned number and the function call
    // `f(3)`. Both are rejected, for different positional reasons.
    let threes: Vec<&ParenthesisedCandidate> = candidates
        .iter()
        .filter(|candidate| candidate.text == "(3)")
        .collect();
    assert_eq!(threes.len(), 2, "{candidates:?}");
    assert!(
        threes
            .iter()
            .any(|candidate| !candidate.accepted && candidate.reason.contains("equation")),
        "{threes:?}"
    );
    assert!(
        threes
            .iter()
            .any(|candidate| !candidate.accepted && candidate.reason.contains("function")),
        "{threes:?}"
    );

    // `Figure 3(b)` is not a numeral candidate at all; `Section 4` has no parenthesised number.
    assert!(
        candidates
            .iter()
            .all(|candidate| !candidate.text.contains('b')),
        "{candidates:?}"
    );
    assert!(
        candidates.len() == 10,
        "unexpected candidates: {candidates:?}"
    );
}

/// A minimal synthetic page for the bracket-path comparison.
fn page_from(text: &str) -> RawTextPage {
    RawTextPage {
        page: PageIndex(0),
        chars: text
            .chars()
            .enumerate()
            .map(|(index, character)| RawCharBox {
                rect: Rect::new(index as f64 * 5.0, 700.0, 5.0, 10.0),
                origin: Point::new(index as f64 * 5.0, 700.0),
                unicode: character as u32,
                font_size: 10.0,
                angle: 0.0,
                font_name: "Body".to_string(),
            })
            .collect(),
        text: text.to_string(),
        is_generated: false,
        has_unicode_map_error: false,
    }
}
