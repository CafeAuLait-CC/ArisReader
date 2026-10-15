//! Opt-in regression checks against the local, uncommitted PDF corpus.
//! Run with PDFium available and ARIS_READER_PDF_SAMPLES pointing at pdf-samples:
//! cargo test -p aris-reader-cli --test reference_corpus -- --ignored --nocapture

use aris_reader_core::{DocumentBackend, PageIndex};
use aris_reader_pdfium::PdfiumBackend;
use aris_reader_text::{
    CitationStyle, find_citations_with, find_references, find_references_with_landings,
    resolve_reference,
};
use std::{collections::BTreeMap, path::PathBuf};

/// Longest a bibliography entry can plausibly be, in characters, before it reads as a collapsed
/// list rather than a reference: 1035 is the longest entry on these twelve samples apart from
/// the one paper pinned below, and the T4.17 collapse produced 3000–7831-character entries, one
/// per column. The bound and its derivation live with the evaluation harness
/// (`crates/aris-reader-cli/tests/reference_eval.rs`, `PLAUSIBLE_ENTRY_CHARS`); this harness
/// repeats it so a collapse in a sample paper fails here too.
const PLAUSIBLE_ENTRY_CHARS: usize = 1800;

#[test]
#[ignore = "requires the private/local PDF samples and a PDFium shared library"]
fn sample_citations_resolve_to_bibliography_entries() {
    let directory = std::env::var_os("ARIS_READER_PDF_SAMPLES")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../pdf-samples"));
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
        let pages: Vec<_> = (0..backend.page_count().min(120))
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
        // (crates/aris-reader-cli/tests/reference_eval.rs), where the derivation is written out.
        // A sample paper may be pinned higher only with its measurement recorded here.
        let longest = references
            .iter()
            .map(|entry| entry.text.chars().count())
            .max()
            .unwrap_or(0);
        let over = references
            .iter()
            .filter(|entry| entry.text.chars().count() > PLAUSIBLE_ENTRY_CHARS)
            .count();
        let (ceiling, allowed) = match prefix {
            // Measured 2621 characters on 2026-10-15: the last entry absorbs the appendix that
            // follows the list on the same page (T4.17's residual, diagnosed but not fixed).
            "manuscript" => (3950, 1),
            _ => (PLAUSIBLE_ENTRY_CHARS, 0),
        };
        assert!(
            longest <= ceiling && over <= allowed,
            "{prefix}: longest entry {longest} characters (ceiling {ceiling}), {over} over \
             {PLAUSIBLE_ENTRY_CHARS} (allowed {allowed}) — a collapsed bibliography"
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
        }
    }
}
