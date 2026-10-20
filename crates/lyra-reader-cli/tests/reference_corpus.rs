//! Opt-in regression checks against the local, uncommitted PDF corpus.
//! Run with PDFium available and LYRA_READER_PDF_SAMPLES pointing at pdf-samples:
//! cargo test -p lyra-reader-cli --test reference_corpus -- --ignored --nocapture

use lyra_reader_core::{DocumentBackend, PageIndex};
use lyra_reader_pdfium::PdfiumBackend;
use lyra_reader_text::{
    CitationStyle, find_citations_with, find_references, find_references_with_landings,
    resolve_reference,
};
use std::collections::BTreeMap;

mod common;

/// Longest a bibliography entry can plausibly be, in characters, before it reads as a collapsed
/// list rather than a reference: 1035 is the longest entry on these twelve samples apart from
/// the one paper pinned below, and the T4.17 collapse produced 3000–7831-character entries, one
/// per column. The bound and its derivation live with the evaluation harness
/// (`crates/lyra-reader-cli/tests/reference_eval.rs`, `PLAUSIBLE_ENTRY_CHARS`); this harness
/// repeats it so a collapse in a sample paper fails here too.
const PLAUSIBLE_ENTRY_CHARS: usize = 1800;

#[test]
#[ignore = "requires the private/local PDF samples and a PDFium shared library"]
fn sample_citations_resolve_to_bibliography_entries() {
    let directory = common::samples_dir();
    let files: Vec<_> = std::fs::read_dir(&directory)
        .expect("local PDF samples")
        .map(|p| p.unwrap().path())
        .collect();
    // These are coverage floors, not precision/recall scores: detection also has
    // false positives (e.g. a conference/year in parentheses). Check identities below.
    for (prefix, minimum_hits) in [
        ("2022-04-05", 0),
        ("Candidacy", 0),
        ("Dvoro", 9),
        ("Pan", 25),
        ("Wang et al. - 2025 - InstructAvatar", 25),
        ("Wang et al. - 2025 - Leader", 1),
        ("Ye", 27),
        ("Yin", 38),
        ("Zhang", 27),
        ("Zhong", 13),
        ("[HumanML3D]", 31),
        ("manuscript", 30),
    ] {
        let path = files
            .iter()
            .find(|p| p.file_name().unwrap().to_string_lossy().starts_with(prefix))
            .expect(prefix);
        let backend = PdfiumBackend::open(path, None).expect("open PDF");
        let pages: Vec<_> = (0..backend.page_count())
            .map(|p| {
                (
                    p,
                    backend.raw_text_page(PageIndex(p)).expect("extract page"),
                )
            })
            .collect();
        let provisional = find_references(pages.iter().map(|(p, t)| (*p, t)), 2000);
        let first_page = provisional
            .iter()
            .map(|e| e.page)
            .min()
            .expect("bibliography");
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
        let references = find_references_with_landings(&pages, &landings, 2000);
        for entry in &references {
            let text = &pages[entry.page as usize].1;
            assert!(
                entry.start < entry.end && entry.end <= text.chars.len(),
                "{prefix}: {entry:?}"
            );
        }
        // The collapse shape: a bibliography parsed as one entry per column instead of one per
        // reference. It has a length signature, and that is what is checked — the same rule and
        // the same 1800-character bound as the evaluation harness
        // (crates/lyra-reader-cli/tests/reference_eval.rs), where the derivation is written out.
        // `manuscript` used to be pinned higher (3950 characters, one over) because its last
        // entry absorbed the appendix that follows the list on the same page; T4.29 cut that tail
        // at the larger-set section, and the longest entry it prints is 849 characters, so it is
        // measured against the shared bound like every other paper here.
        let longest = references
            .iter()
            .map(|entry| entry.text.chars().count())
            .max()
            .unwrap_or(0);
        let over = references
            .iter()
            .filter(|entry| entry.text.chars().count() > PLAUSIBLE_ENTRY_CHARS)
            .count();
        assert!(
            longest <= PLAUSIBLE_ENTRY_CHARS && over == 0,
            "{prefix}: longest entry {longest} characters, {over} over {PLAUSIBLE_ENTRY_CHARS} — \
             a collapsed bibliography"
        );
        // The app's detector, style included: the corpus cites as `[n]` throughout, so the
        // superscript path stays off here — which is the point of measuring it, rather than
        // assuming it.
        let style = CitationStyle::for_document(&pages, &references);
        let citations: Vec<_> = pages
            .iter()
            .take(3)
            .flat_map(|(_, text)| find_citations_with(text, &style))
            .collect();
        let hits = citations
            .iter()
            .filter(|c| resolve_reference(&c.labels, &references).is_some())
            .count();
        println!(
            "{prefix}: {hits}/{} spans, {} entries, first page {}",
            citations.len(),
            references.len(),
            first_page + 1
        );
        assert!(hits >= minimum_hits, "{prefix}: {hits} < {minimum_hits}");
        if prefix.contains("InstructAvatar") {
            assert!(
                references.iter().all(|e| (7..=8).contains(&e.page)),
                "body prose in bibliography"
            );
            for (label, title) in [
                ("He 2024", "GAIA"),
                ("Ma 2023a", "TalkCLIP"),
                ("Ma 2023b", "Styletalk"),
                ("Ma 2023c", "Dreamtalk"),
                ("Ekman 1978", "Facial action"),
                ("Gulati 2020", "Conformer"),
                ("OpenAI 2023", "GPT-4V"),
            ] {
                let entry = resolve_reference(&[label.into()], &references).expect(label);
                assert!(entry.text.contains(title), "{label}: {}", entry.text);
                // The preview range must include the title, not only its author line.
                let raw = &pages[entry.page as usize].1;
                let slice: String = raw.chars[entry.start..entry.end]
                    .iter()
                    .filter_map(|c| char::from_u32(c.unicode))
                    .collect();
                assert!(slice.contains(title), "truncated preview for {label}");
            }
            assert!(
                resolve_reference(&["Tan 2024".into()], &references).is_none(),
                "ambiguous works"
            );
        }
        if prefix == "Pan" {
            assert_eq!(
                references.len(),
                35,
                "the printed bibliography has labels 1..35"
            );
            assert!(references.iter().all(|e| e.page == 8));
        }
        if prefix == "Candidacy" {
            assert_eq!(
                references.len(),
                185,
                "bibliography spans pages 55..82 with repeated headers"
            );
            assert_eq!(references.first().unwrap().label, "1");
            assert_eq!(references.last().unwrap().label, "185");
            // T4.29's regression cases, measured 2026-10-15. These entries span their own
            // paragraph gaps — 54.6, 41.3 and 41.2 points against a 13.9-point line pitch — so the
            // cut that ends an entry at a paragraph gap truncated them; the entry that ends the
            // list is cut by a *style* change instead, and these texts are what the thesis prints.
            for (label, length, tail) in [
                ("26", 429, "\u{2192} pages 10 46"),
                ("60", 461, "\u{2192} pages 14, 16 51"),
                ("77", 458, "pdf. \u{2192} pages 15 54"),
            ] {
                let entry = references
                    .iter()
                    .find(|entry| entry.label == label)
                    .unwrap_or_else(|| panic!("entry [{label}]"));
                assert_eq!(
                    entry.text.chars().count(),
                    length,
                    "[{label}] was truncated: {}",
                    entry.text
                );
                // The extractor's line breaks sit inside a numeric entry's text; compare the
                // words, which is what a truncation would remove.
                let words = entry.text.split_whitespace().collect::<Vec<_>>().join(" ");
                assert!(
                    words.ends_with(tail),
                    "[{label}] lost its end: {}",
                    entry.text
                );
            }
        }
        if prefix == "manuscript" {
            let entry = resolve_reference(&["Canales Cuba 2025".into()], &references).unwrap();
            assert!(entry.text.contains("Flowmotion"));
            assert_eq!(
                resolve_reference(&["Bazarevsky 2020".into()], &references)
                    .unwrap()
                    .page,
                9
            );
            // T4.29's regression case: the rejected paragraph-gap cut removed this entry's first
            // line (a 21.7-point gap before it) and the fix must not. Measured 2026-10-15: 286
            // characters, from the first author to the DOI, and no appendix after it.
            let entry = resolve_reference(&["Zhang 2024".into()], &references).unwrap();
            assert_eq!(entry.text.chars().count(), 286, "{}", entry.text);
            assert!(
                entry
                    .text
                    .starts_with("Mingyuan Zhang, Zhongang Cai, Liang Pan"),
                "first line lost: {}",
                entry.text
            );
            assert!(
                entry.text.ends_with("doi: 10.1109/TPAMI.2024.3355414."),
                "last line lost: {}",
                entry.text
            );
            assert!(
                !entry.text.contains("Common motion representation"),
                "the appendix is inside the entry: {}",
                entry.text
            );
        }
    }
}

/// Printed line 159 links only the year to a bibliography page. The text detector must
/// include the preceding author so the shell can open the entry instead of that page image.
#[test]
#[ignore = "requires the private/local PDF samples and a PDFium shared library"]
fn review_du_guo_narrative_citation_resolves_to_its_entry() {
    let path = common::samples_dir().join("with_annotations/review_du_0923.pdf");
    let backend = PdfiumBackend::open(&path, None).expect("review manuscript");
    let pages: Vec<_> = (0..backend.page_count())
        .map(|index| {
            (
                index,
                backend.raw_text_page(PageIndex(index)).expect("text page"),
            )
        })
        .collect();
    let entries = find_references(pages.iter().map(|(index, raw)| (*index, raw)), 2000);
    let style = CitationStyle::for_document(&pages, &entries);
    let citation = find_citations_with(&pages[2].1, &style)
        .into_iter()
        .find(|citation| citation.text == "Guo et al. (2022)")
        .expect("narrative citation around printed line 159");
    assert_eq!(citation.labels, ["Guo 2022"]);
    let entry = resolve_reference(&citation.labels, &entries).expect("Guo entry");
    assert_eq!(entry.page, 10);
    assert!(
        entry
            .text
            .contains("Generating diverse and natural 3d human motions from text")
    );
    assert!(entry.text.starts_with("Chuan Guo, Shihao Zou"));
}
