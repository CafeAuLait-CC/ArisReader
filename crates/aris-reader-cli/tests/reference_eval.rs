//! Evaluation harness for the citation/reference index (task T4.10).
//!
//! Why this is an integration test and not a CLI subcommand: the contract it complements
//! (`reference_corpus.rs`) is already an opt-in integration test in this crate, it needs the
//! same two things (PDFium plus a local, uncommitted corpus), and the failure it produces is a
//! test failure — `cargo test` is where this project already records parser quality. A CLI
//! subcommand would add a user-facing surface nobody asked for and would still need a test
//! wrapper to fail CI on the thresholds.
//!
//! The corpus is a list of links, never PDFs:
//!
//! ```text
//! ./scripts/fetch-eval-papers.sh                      # -> eval-papers/*.pdf (git-ignored)
//! cargo test -p aris-reader-cli --test reference_eval -- --ignored --nocapture
//! ```
//!
//! Two corpus reports and an independent gold-page check:
//!
//! * [`reference_eval_recall`] — one row per paper (entries, spans, resolved, unresolved,
//!   recall, longest entry) printed to stdout and, when the local-only `docs/` directory
//!   exists, written to `docs/eval-latest.md`. It fails a paper whose recall is below its floor
//!   and a paper whose bibliography has the shape of a collapse: an entry longer than its
//!   ceiling, or more over-long entries than its pin allows (T4.17: 2005.14165 used to parse as
//!   six entries of 3000–7831 characters, one per column, instead of 144).
//! * [`reference_eval_precision_audit`] — the same measurement, but it prints the individual
//!   matches that *look* wrong so a human can judge them. Precision is not a number this
//!   harness can produce on its own: a resolved match is only a false positive if a human says
//!   so. The audit makes the candidates visible instead of inventing a score.
//!
//! `gpt3_alphanumeric_gold_pages` checks the full inventory and every resolved label on
//! three independently annotated pages. It needs one specific locked PDF (2005.14165), not the
//! whole corpus, so it announces its own skip when that PDF is absent — the same
//! "absence is announced, never a failure" rule the two report modes follow. It used to panic
//! there, which made `cargo test -- --ignored` red on a machine without the corpus while the
//! reports passed.
//!
//! All three modes skip cleanly when their PDFs are absent and, on CI, emit a `::notice::` saying the
//! evaluation did NOT run: a silent pass here would be indistinguishable from a real one.
//! Set `ARIS_READER_REQUIRE_FULL_EVAL=1` to require every listed PDF (used by manual CI).
//! Every mode fails on document-open or page-text errors; partial extraction is not a score.

use aris_reader_core::{DocumentBackend, PageIndex, RawTextPage};
use aris_reader_pdfium::PdfiumBackend;
use aris_reader_text::{
    Citation, CitationStyle, ReferenceEntry, find_citations_with, find_references,
    find_references_with_landings, resolve_reference, resolve_references,
};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

mod common;

// ---------------------------------------------------------------------------
// Thresholds: every number this harness enforces lives here, and nowhere else.
// ---------------------------------------------------------------------------

/// Recall floor per paper, as a fraction of detected citation spans.
///
/// The floors were chosen **after** the first real measurement over the fetched corpus, not
/// before it: each one sits a little below the recall that paper actually produced, so a
/// regression trips the floor while ordinary noise (a different arXiv version of the same
/// paper) does not. The measured value is recorded next to each row so a future reader can see
/// what the floor was derived from instead of guessing.
struct Floor {
    id: &'static str,
    /// Minimum resolved spans / detected spans.
    recall: f64,
}

const FLOORS: &[Floor] = &[
    // Each row: the recall this paper actually produced on the first full run over the fetched
    // corpus (2026-10-14, twenty papers, 1758 detected spans), and the floor derived from it.
    // The floor sits a little below the measurement so that a regression trips it while an
    // ordinary change (a different arXiv version, one more unresolved span) does not.
    Floor {
        id: "1512.03385",
        recall: 0.90,
    }, // measured 98.8% (83/84)
    Floor {
        id: "1706.03762",
        recall: 0.90,
    }, // measured 98.0% (49/50)
    Floor {
        id: "1810.04805",
        recall: 0.80,
    }, // measured 90.0% (45/50); five unresolved spans
    Floor {
        id: "2303.08774",
        recall: 0.90,
    }, // T4.41: measured 100% (54/54) over the report's own body (pages 1–17) and its own list
    // (85 entries on pages 18–23). It measured 99.2% (245/247) over 105 entries while the
    // selection was the system card appendix's independently numbered list: the body window
    // ran to page 70 and the appendix cites its own list there, so both the window and the
    // recall figure changed with the selection. The floor is unchanged.
    Floor {
        id: "2103.00020",
        recall: 0.85,
    }, // measured 94.9% (111/117)
    Floor {
        id: "1905.11946",
        recall: 0.90,
    }, // measured 98.2% (110/112)
    Floor {
        id: "1912.01703",
        recall: 0.90,
    }, // measured 98.2% (56/57)
    Floor {
        id: "1301.3781",
        recall: 0.90,
    }, // measured 100% (47/47)
    Floor {
        id: "1602.05629",
        recall: 0.90,
    }, // measured 100% (32/32)
    Floor {
        id: "1408.5882",
        recall: 0.90,
    }, // measured 100% (46/46)
    Floor {
        id: "2010.11929",
        recall: 0.80,
    }, // measured 91.3% (42/46); author-year from prose
    Floor {
        id: "1807.06209",
        recall: 0.70,
    }, // measured 79.0% (203/257); 366 entries, heavy diacritics
    Floor {
        id: "1710.05833",
        recall: 0.75,
    }, // measured 87.3% (199/228); 382 entries, collaborations
    Floor {
        id: "1909.05722",
        recall: 0.90,
    }, // measured 100% (77/77)
    Floor {
        id: "2104.08886",
        recall: 0.90,
    }, // measured 100% (222/222)
    Floor {
        id: "2110.12477",
        recall: 0.90,
    }, // measured 100% (73/73)
    Floor {
        id: "2403.04370",
        recall: 0.90,
    }, // measured 100% (13/13)
    Floor {
        id: "2005.14165",
        recall: 0.95,
    }, // T4.16: 203/203 spans resolve in locked v4; previously 0 spans / 6 collapsed entries.
    Floor {
        id: "1712.01815",
        recall: 0.00,
    }, // NOT superscripts in this text layer: its citations are ordinary `(9)` / `(2, 14)` at
    // body size on the baseline (height ratio 0.97, rise +0.27 pt against a 10.69 pt body), so
    // no geometric rule can see them; the 20 shapes are counted by the `(12)` column
    Floor {
        id: "1710.05463",
        recall: 0.90,
    }, // measured 100% (18/18) once superscript numerals were detected, and 100% (38/38) with
       // T4.20's joined runs; the floor stays at 0.90 because the measurement did not move it —
       // it was 0.90 rather than 1.00 while only the part of the list the parser selected
       // (entries 34-68) could corroborate a label, because its main-text citations, labels 1-33,
       // were dropped by the label guard instead of being guessed at. The runs are joined now, so
       // that reason is gone and the floor is only the usual slack under a measured 100%
];

/// Floor for a paper in the corpus that has no row above. Deliberately low: the explicit rows
/// are the contract, this is only a guard against a new corpus entry being added and forgotten.
const DEFAULT_RECALL_FLOOR: f64 = 0.50;

/// Upper bound on the share of resolved spans the audit flags as suspicious, per paper.
///
/// This is the milestone's "false positives <= 2%" written down as the only thing a machine can
/// check without a human: how often the heuristics see a match that shares only a year with the
/// entry, or that shares no word with it at all. It is *not* a precision measurement — a wrong
/// match the heuristics do not recognise is not counted, and a flagged one may still be correct
/// — which is exactly why the audit prints every flag with its evidence.
const FALSE_POSITIVE_BUDGET: f64 = 0.02;

/// Longest a bibliography entry can plausibly be, in characters, before it reads as a collapsed
/// list rather than a reference.
///
/// Measured, not invented (T4.17 scan, 2026-10-15, the twelve sample papers and the twenty
/// evaluation papers): the longest entry that is genuinely *one* reference is 1366 characters —
/// `2303.08774`'s "On the Opportunities and Risks of Foundation Models" citation, whose author
/// list runs to about a hundred names — and the next longest are 1035 and 932. The collapsed
/// bibliography of `2005.14165` produced entries of 3000–7831 characters, one per column. 1800
/// sits 32% above the longest honest entry and 40% below the shortest collapsed one, so it
/// separates the two shapes with margin on both sides; it is a *plausibility* bound, not a
/// measurement of what a reference looks like.
const PLAUSIBLE_ENTRY_CHARS: usize = 1800;

/// Per-paper ceiling on the longest entry, and how many entries may exceed
/// [`PLAUSIBLE_ENTRY_CHARS`]: `(id, ceiling in characters, over-long entries allowed)`.
///
/// The ceiling is that paper's measured maximum plus half again, rounded up to 50, from the
/// T4.17 scan of 2026-10-15 (the FLOORS above were measured the day before); the measurement is
/// in the comment. Three papers used to get `over: 1` — a fourth, `manuscript_0925`, was pinned in
/// `reference_corpus.rs`: their list ends with an entry that absorbed the section following it on
/// the same page (an appendix, or `1710.05833`'s author list, 2209–3601 characters). T4.29 cut
/// that tail where the section it swallowed is set in a larger type than the entry's own body
/// (`trim_trailing_section`, `crates/aris-reader-text/src/bibliography.rs`), which took all four
/// to `over: 0` and left their longest *reference* at 443 (`1710.05833`), 462 (`1810.04805`) and
/// 935 (`1807.06209`) characters — so the pins below are re-measured against the entry the paper
/// really prints, with the same half-again margin, and the fourth paper needs no pin of its own. The pins still catch a collapse: it
/// would grow a paper past its ceiling, and the count would exceed `over` even if every new entry
/// stayed under the ceiling.
const ENTRY_LENGTH_CEILINGS: &[(&str, usize, usize)] = &[
    ("1301.3781", 400, 0),   // measured max 253
    ("1408.5882", 450, 0),   // measured max 288
    ("1512.03385", 350, 0),  // measured max 212
    ("1602.05629", 500, 0),  // measured max 328
    ("1706.03762", 450, 0),  // measured max 286
    ("1710.05463", 400, 0),  // measured max 245
    ("1710.05833", 700, 0),  // measured max 443; 3428 before T4.29 (LIGO author list)
    ("1712.01815", 700, 0),  // measured max 455
    ("1807.06209", 1450, 0), // measured max 935; 3601 before T4.29 (Appendix A)
    ("1810.04805", 700, 0),  // measured max 462; 2209 before T4.29 (the BERT appendix)
    ("1905.11946", 550, 0),  // measured max 354
    ("1909.05722", 350, 0),  // measured max 223
    ("1912.01703", 1100, 0), // measured max 723
    ("2005.14165", 650, 0),  // measured max 427; 3000–7831 when T4.17's collapse was live
    ("2010.11929", 800, 0),  // measured max 528
    ("2103.00020", 1000, 0), // measured max 648
    ("2104.08886", 1400, 0), // measured max 932
    ("2110.12477", 400, 0),  // measured max 257
    ("2303.08774", 2050, 0), // the report's own list (T4.41) peaks at 960; the bound stays at the
    // T4.17 scan's 2050, which the appendix list's 1366-character entry
    // (one reference, ~100 authors) derived, so both of this paper's
    // lists fit under it
    ("2403.04370", 750, 0), // measured max 469
];

/// Entries the bibliography parser may return, matching the callers in the app and the CLI.
const MAX_ENTRIES: usize = 2000;

/// Unresolved spans kept per paper as evidence. Recall is the headline; these are the receipt.
const MAX_EXAMPLES: usize = 8;

// ---------------------------------------------------------------------------
// Corpus plumbing
// ---------------------------------------------------------------------------

/// One line of `tests/eval/arxiv-links.txt`.
struct CorpusEntry {
    id: String,
    note: String,
}

fn repo_root() -> PathBuf {
    common::repo_root()
}

fn corpus_list(root: &Path) -> Vec<CorpusEntry> {
    let path = root.join("tests/eval/arxiv-links.txt");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("cannot read {}: {error}", path.display()));
    text.lines()
        .filter_map(|line| {
            let line = line.split('#').next().unwrap_or("").trim();
            let mut fields = line.split_whitespace();
            let id = fields.next()?.to_string();
            let note = fields.collect::<Vec<_>>().join(" ");
            Some(CorpusEntry { id, note })
        })
        .collect()
}

/// Where the fetched PDFs live: `eval-papers/` by default, overridable for a machine that keeps
/// them elsewhere. The directory is git-ignored; nothing here ever reaches a commit.
fn corpus_dir(root: &Path) -> PathBuf {
    std::env::var_os("ARIS_READER_EVAL_PAPERS")
        .map(PathBuf::from)
        .unwrap_or_else(|| root.join("eval-papers"))
}

/// Prints the "this did not run" message and returns the papers that are present (possibly none).
fn present_papers(dir: &Path, list: &[CorpusEntry]) -> Vec<usize> {
    list.iter()
        .enumerate()
        .filter(|(_, entry)| dir.join(format!("{}.pdf", entry.id)).is_file())
        .map(|(index, _)| index)
        .collect()
}

fn announce_skip(dir: &Path, list: &[CorpusEntry]) {
    println!(
        "skipping the reference-index evaluation: no PDFs in {} (0 of {} corpus papers fetched)",
        dir.display(),
        list.len()
    );
    println!("  the corpus is a list of links: tests/eval/arxiv-links.txt");
    println!("  fetch it into the git-ignored directory with ./scripts/fetch-eval-papers.sh");
    if std::env::var_os("CI").is_some() {
        println!(
            "::notice title=Reference eval NOT run::No evaluation corpus in {} — the citation/reference index was NOT measured here. The PDFs are never committed; fetch them with ./scripts/fetch-eval-papers.sh on a machine that can hold them. A green test run says nothing about recall.",
            dir.display()
        );
    }
}

// ---------------------------------------------------------------------------
// Measurement
// ---------------------------------------------------------------------------

/// A citation span that resolved to nothing, kept as evidence for the recall number.
struct Miss {
    page: u32,
    text: String,
    labels: String,
}

/// A resolved match the audit heuristics consider worth a human's attention.
struct Flag {
    page: u32,
    span: String,
    label: String,
    entry_label: String,
    entry_page: u32,
    reason: &'static str,
    excerpt: String,
    /// Whether this flag counts against the false-positive budget. The two heuristics the
    /// contract names do; the positional-guess and prose-entry flags are review material — they
    /// are reasons to look, not established false positives (a table's "[1]" is not a citation,
    /// but it is also not a wrong resolution of one).
    gated: bool,
}

struct Paper {
    id: String,
    state: State,
    pages: u32,
    entries: usize,
    /// Link annotations on the scanned pages. A paper without them gives the resolver nothing
    /// to work with when it looks for where a citation lands.
    links: usize,
    first_entry_page: Option<u32>,
    body_pages: u32,
    spans: usize,
    resolved: usize,
    partial: usize,
    misses: Vec<Miss>,
    flags: Vec<Flag>,
    /// Entries too long or too year-less to be a reference entry: the signature of a bibliography
    /// the parser collapsed (one "entry" per column). Capped for the printout.
    prose_entries: Vec<(String, u32, usize)>,
    /// Longest entry, in characters, and how many entries exceed [`PLAUSIBLE_ENTRY_CHARS`]. The
    /// collapse T4.17 describes shows up here as a max of thousands; see
    /// [`ENTRY_LENGTH_CEILINGS`] for what each paper is allowed.
    max_entry_chars: usize,
    long_entries: usize,
    /// Shapes of citation the detector does not model, counted in the body text: alphanumeric
    /// bracket labels (`[HR18]`) and short parenthesised numerals (`(12)`, `(2, 14)`).
    ///
    /// These are not spans and never enter recall. They are here so that "0 spans" on a paper
    /// full of citations reads as "the detector cannot see this style" instead of "this paper
    /// cites nothing" — the failure mode a number alone would hide.
    unmodelled_alnum: usize,
    unmodelled_paren: usize,
}

enum State {
    Measured,
    /// The paper is in the list but no PDF was fetched for it.
    Absent,
    /// The PDF is there but this machine could not read it (engine failure).
    Unreadable(String),
}

impl Paper {
    fn recall(&self) -> f64 {
        if self.spans == 0 {
            0.0
        } else {
            self.resolved as f64 / self.spans as f64
        }
    }

    /// Share of resolved spans the *gated* heuristics flagged: the number the false-positive
    /// budget is about.
    fn flag_rate(&self) -> f64 {
        if self.resolved == 0 {
            0.0
        } else {
            self.gated_flags() as f64 / self.resolved as f64
        }
    }

    fn gated_flags(&self) -> usize {
        self.flags.iter().filter(|flag| flag.gated).count()
    }
}

fn measure(id: &str, path: &Path) -> Paper {
    let mut paper = Paper {
        id: id.to_string(),
        state: State::Measured,
        pages: 0,
        entries: 0,
        links: 0,
        first_entry_page: None,
        body_pages: 0,
        spans: 0,
        resolved: 0,
        partial: 0,
        misses: Vec::new(),
        flags: Vec::new(),
        prose_entries: Vec::new(),
        max_entry_chars: 0,
        long_entries: 0,
        unmodelled_alnum: 0,
        unmodelled_paren: 0,
    };

    let backend = match PdfiumBackend::open(path, None) {
        Ok(backend) => backend,
        Err(error) => {
            paper.state = State::Unreadable(error.to_string());
            return paper;
        }
    };

    let total = backend.page_count();
    paper.pages = total;
    // Every page, like the reader's own index (T4.13 removed the 120-page cap); the arXiv
    // corpus's longest paper is 75 pages, so this matches the old bound on this corpus while a
    // longer document would be measured whole.
    let mut pages: Vec<(u32, RawTextPage)> = Vec::new();
    for index in 0..total {
        match backend.raw_text_page(PageIndex(index)) {
            Ok(text) => pages.push((text.page.get(), text)),
            Err(error) => {
                paper.state = State::Unreadable(format!(
                    "page {} text extraction failed: {error}",
                    index + 1
                ));
                return paper;
            }
        }
    }

    // Same two-pass selection the app uses: find the bibliography, collect the link landings
    // that point into it, then rebuild with that geometry (crates/aris-reader-cli/src/main.rs).
    let provisional = find_references(pages.iter().map(|(page, text)| (*page, text)), MAX_ENTRIES);
    let first_entry_page = provisional.iter().map(|entry| entry.page).min();
    let mut landings: BTreeMap<u32, Vec<f64>> = BTreeMap::new();
    if let Some(first) = first_entry_page {
        for page in 0..first {
            let Ok(links) = backend.link_targets(PageIndex(page)) else {
                continue;
            };
            for link in links {
                if let (Some(target), Some(top)) = (link.page, link.dest_top_y)
                    && target.get() >= first
                {
                    landings.entry(target.get()).or_default().push(top);
                }
            }
        }
    }
    let references = find_references_with_landings(&pages, &landings, MAX_ENTRIES);
    paper.entries = references.len();
    paper.first_entry_page = first_entry_page;
    paper.max_entry_chars = references
        .iter()
        .map(|entry| entry.text.chars().count())
        .max()
        .unwrap_or(0);
    paper.long_entries = references
        .iter()
        .filter(|entry| entry.text.chars().count() > PLAUSIBLE_ENTRY_CHARS)
        .count();
    paper.prose_entries = references
        .iter()
        .filter(|entry| looks_like_prose(&entry.text))
        .take(5)
        .map(|entry| (entry.label.clone(), entry.page, entry.text.chars().count()))
        .collect();

    // Diagnostics that describe the *shape* of the document, not the parser's output: how many
    // link annotations the body actually carries, and how many columns the reference list is set
    // in. Both are properties the twelve-paper corpus lacks, so they are measured here.
    for (page, _) in &pages {
        paper.links += backend
            .link_targets(PageIndex(*page))
            .map(|links| links.len())
            .unwrap_or(0);
    }

    // Citations are counted in the body only: a reference list cites the works it lists, and
    // counting those would measure the bibliography against itself. With no bibliography found,
    // fall back to the first three pages, the window the regression contract samples.
    let body_end = first_entry_page.unwrap_or(3).max(1);
    // The app's detector, not a stand-in for it: the same style object decides whether a raised
    // numeral is a superscript citation, so "0 spans" here means the app shows 0 too.
    let style = CitationStyle::for_document(&pages, &references);
    let mut citations: Vec<(u32, Citation)> = Vec::new();
    for (page, text) in pages.iter().filter(|(page, _)| *page < body_end) {
        for citation in find_citations_with(text, &style) {
            citations.push((*page, citation));
        }
        let (alnum, paren) = unmodelled_shapes(&text.text);
        if !style.uses_alphanumeric_labels() {
            paper.unmodelled_alnum += alnum;
        }
        paper.unmodelled_paren += paren;
    }
    paper.body_pages = pages.iter().filter(|(page, _)| *page < body_end).count() as u32;
    paper.spans = citations.len();

    let entries = EntryIndex::build(&references);
    for (page, citation) in &citations {
        let matched = resolve_references(&citation.labels, &references);
        if matched.is_empty() {
            if paper.misses.len() < MAX_EXAMPLES {
                paper.misses.push(Miss {
                    page: *page,
                    text: citation.text.clone(),
                    labels: citation.labels.join(", "),
                });
            }
            continue;
        }
        paper.resolved += 1;
        let every_label = citation
            .labels
            .iter()
            .all(|label| resolve_reference(std::slice::from_ref(label), &references).is_some());
        if !every_label {
            paper.partial += 1;
        }
        paper
            .flags
            .extend(audit(page, citation, &references, &entries));
    }

    paper
}

// ---------------------------------------------------------------------------
// Document-shape diagnostics
// ---------------------------------------------------------------------------

/// Counts shapes of citation the detector does not model, in one page of body text:
///
/// * alphanumeric bracket labels — `[HR18]`, `[VSP+ 17]`, GPT-3's whole citation style, which
///   the numeric path rejects because it accepts only digits and separators;
/// * short parenthesised numerals — `(9)`, `(2, 14)`, Science/Nature superscripts, which the
///   author-year path rejects because it requires words and a four-digit year.
///
/// Returned as `(alphanumeric labels, short parenthesised numerals)`.
fn unmodelled_shapes(text: &str) -> (usize, usize) {
    let characters: Vec<char> = text.chars().collect();
    let mut alnum = 0usize;
    let mut paren = 0usize;
    let mut index = 0usize;
    while index < characters.len() {
        match characters[index] {
            '[' => {
                let mut end = index + 1;
                while end < characters.len() && end - index <= 12 && characters[end] != ']' {
                    end += 1;
                }
                if end < characters.len() && characters[end] == ']' {
                    let inner: String = characters[index + 1..end].iter().collect();
                    let letters = inner.chars().filter(|c| c.is_ascii_alphabetic()).count();
                    let digits = inner.chars().filter(|c| c.is_ascii_digit()).count();
                    if letters > 0 && digits > 0 {
                        alnum += 1;
                    }
                    index = end + 1;
                    continue;
                }
            }
            '(' => {
                let mut end = index + 1;
                while end < characters.len() && end - index <= 10 && characters[end] != ')' {
                    end += 1;
                }
                if end < characters.len() && characters[end] == ')' {
                    let inner: String = characters[index + 1..end].iter().collect();
                    let short_numerals = !inner.is_empty()
                        && inner.chars().all(|c| {
                            c.is_ascii_digit() || matches!(c, ',' | ';' | ' ' | '-' | '\u{2013}')
                        })
                        && inner
                            .split(|c: char| !c.is_ascii_digit())
                            .filter(|part| !part.is_empty())
                            .all(|part| part.len() <= 3);
                    if short_numerals {
                        paren += 1;
                    }
                    index = end + 1;
                    continue;
                }
            }
            _ => {}
        }
        index += 1;
    }
    (alnum, paren)
}

// ---------------------------------------------------------------------------
// Precision audit
// ---------------------------------------------------------------------------

/// Tokens that say nothing about *which* work a citation means.
const STOPWORDS: &[&str] = &[
    "and",
    "the",
    "for",
    "with",
    "from",
    "into",
    "et",
    "al",
    "eds",
    "ed",
    "pp",
    "vol",
    "no",
    "fig",
    "eq",
    "arxiv",
    "preprint",
    "proc",
    "proceedings",
    "conference",
    "international",
    "pages",
    "press",
    "university",
];

fn words(text: &str) -> Vec<String> {
    text.split(|character: char| !character.is_alphanumeric())
        .filter(|word| word.chars().count() >= 2)
        .map(str::to_lowercase)
        .filter(|word| !STOPWORDS.contains(&word.as_str()))
        .collect()
}

/// Whether a token is nothing but a four-digit year.
fn is_year_token(word: &str) -> bool {
    word.len() == 4 && word.chars().all(|character| character.is_ascii_digit())
}

/// The year inside one token, if that token is a year: `2023` and `2023b` both say 2023 (the
/// letter is the author-year disambiguation suffix, not part of the year).
fn year_of_token(token: &str) -> Option<String> {
    let digits: String = token.chars().take_while(char::is_ascii_digit).collect();
    if digits.len() != 4 {
        return None;
    }
    let rest = &token[digits.len()..];
    if rest.chars().all(char::is_alphabetic)
        && (digits.starts_with("19") || digits.starts_with("20"))
    {
        Some(digits)
    } else {
        None
    }
}

/// The publication year a citation label names, if it names one (`He 2024`, `Ma 2023b`).
fn label_year(label: &str) -> Option<String> {
    words(label)
        .into_iter()
        .find_map(|word| year_of_token(&word))
}

/// Per-entry search material, built once per paper.
struct EntryIndex {
    tokens: Vec<BTreeSet<String>>,
    year: Vec<Option<String>>,
}

impl EntryIndex {
    fn build(references: &[ReferenceEntry]) -> Self {
        EntryIndex {
            tokens: references
                .iter()
                .map(|entry| {
                    let mut set: BTreeSet<String> = words(&entry.label).into_iter().collect();
                    set.extend(words(&entry.text));
                    set
                })
                .collect(),
            year: references.iter().map(entry_year).collect(),
        }
    }
}

/// The year an entry is dated with: its own label when that carries one, else the first year in
/// the opening words of its text.
fn entry_year(entry: &ReferenceEntry) -> Option<String> {
    if let Some(year) = label_year(&entry.label) {
        return Some(year);
    }
    let opening: String = entry.text.chars().take(120).collect();
    words(&opening)
        .into_iter()
        .find_map(|word| year_of_token(&word))
}

/// The audit: two questions about one resolved match.
///
/// * Does the match share *only a year* with the entry it landed on? A citation that names a
///   surname the entry never mentions, matched because both carry the same year, is the classic
///   false positive of an author-year resolver.
/// * Does the span share *any* meaningful word with the entry? A parenthesised citation whose
///   words appear nowhere in the entry it resolved to is at best a positional guess.
///
/// Numeric labels are exempt from the word checks: `[12]` shares no word with entry 12 by
/// construction, so testing them would only bury the real signal. Two further checks do apply
/// to them, and to entries the resolver never returned:
///
/// * a numeric citation on a list with **no printed labels** resolves by position — `[12]` means
///   "the twelfth entry" — and one wrong entry count anywhere earlier silently shifts every
///   later citation;
/// * an entry whose text reads like body prose is a collapsed bibliography, not a reference.
///
/// What a clean audit does and does not mean: `resolve_reference` only ever returns an entry
/// whose label matches, so "shares only a year" is nearly unreachable by construction (the
/// compound-surname fallback reads the surname out of the entry text it matched). Zero flags
/// therefore says "the resolver is conservative", not "the index is precise" — the audit's value
/// is the evidence it prints, not the count.
fn audit(
    page: &u32,
    citation: &Citation,
    references: &[ReferenceEntry],
    index: &EntryIndex,
) -> Vec<Flag> {
    let mut flags = Vec::new();
    // Years are removed before the overlap test: every author-year match shares a year by
    // construction (`resolve_reference` keys on it), so counting the year as an overlap would
    // make the test vacuous.
    let span_words: BTreeSet<String> = words(&citation.text)
        .into_iter()
        .filter(|word| !is_year_token(word))
        .collect();
    let entry_tokens_without_years = |position: usize| -> BTreeSet<String> {
        index.tokens[position]
            .iter()
            .filter(|word| !is_year_token(word))
            .cloned()
            .collect()
    };

    for label in &citation.labels {
        let numeric = label.chars().all(|character| character.is_ascii_digit());
        if numeric {
            // A numeric label on a list with no printed labels is a positional guess: `[12]` is
            // taken to mean the twelfth entry. That is a real convention, and a real risk — one
            // miscounted entry shifts every later citation silently — so it is worth a human's
            // eye whenever it happens. On a numbered list the label check is exact and there is
            // nothing to see.
            if list_is_unnumbered(references)
                && let Some(entry) = resolve_reference(std::slice::from_ref(label), references)
            {
                flags.push(Flag {
                    page: *page,
                    span: citation.text.clone(),
                    label: label.clone(),
                    entry_label: entry.label.clone(),
                    entry_page: entry.page,
                    reason: "the list carries no labels: resolved by position",
                    excerpt: excerpt(&entry.text),
                    gated: false,
                });
            }
            continue;
        }
        let Some(entry) = resolve_reference(std::slice::from_ref(label), references) else {
            continue;
        };
        let position = references
            .iter()
            .position(|candidate| std::ptr::eq(candidate, entry))
            .expect("resolved entry belongs to the reference list");
        let entry_tokens = &index.tokens[position];
        let entry_year = index.year[position].clone();
        let label_year = label_year(label);
        let label_words: Vec<String> = words(label)
            .into_iter()
            .filter(|word| !word.chars().all(|character| character.is_ascii_digit()))
            .collect();

        let shares_a_word = label_words.iter().any(|word| entry_tokens.contains(word));
        let shares_the_year = match (&label_year, &entry_year) {
            (Some(span), Some(entry)) => span == entry,
            _ => false,
        };
        if !shares_a_word && shares_the_year {
            flags.push(Flag {
                page: *page,
                span: citation.text.clone(),
                label: label.clone(),
                entry_label: entry.label.clone(),
                entry_page: entry.page,
                reason: "shares only a year",
                excerpt: excerpt(&entry.text),
                gated: true,
            });
            continue;
        }
        if label_year.is_some() && span_words.is_disjoint(&entry_tokens_without_years(position)) {
            flags.push(Flag {
                page: *page,
                span: citation.text.clone(),
                label: label.clone(),
                entry_label: entry.label.clone(),
                entry_page: entry.page,
                reason: "shares no word with the entry",
                excerpt: excerpt(&entry.text),
                gated: true,
            });
            continue;
        }
        if let (Some(span), Some(dated)) = (&label_year, &entry_year)
            && span != dated
        {
            flags.push(Flag {
                page: *page,
                span: citation.text.clone(),
                label: label.clone(),
                entry_label: entry.label.clone(),
                entry_page: entry.page,
                reason: "resolved to a different year",
                excerpt: excerpt(&entry.text),
                gated: true,
            });
        }
    }

    flags
}

/// Whether the reference list carries no numeric labels at all, which is what makes a numeric
/// citation resolve by *position* (`[12]` = the twelfth entry) instead of by a printed label.
fn list_is_unnumbered(references: &[ReferenceEntry]) -> bool {
    !references.is_empty()
        && references.iter().all(|entry| {
            !entry
                .label
                .chars()
                .next()
                .map(|character| character.is_ascii_digit())
                .unwrap_or(false)
        })
}

/// Whether an "entry" is too long, or too year-less, to be a reference entry: a real entry is a
/// few hundred characters and carries a year, a paragraph that swallowed half a column does not.
/// This is how a collapsed bibliography (one entry per column — 2005.14165's six "entries" over
/// five pages) becomes visible as suspicious instead of merely few.
fn looks_like_prose(text: &str) -> bool {
    text.chars().count() > 900 || !words(text).into_iter().any(|word| is_year_token(&word))
}

fn excerpt(text: &str) -> String {
    let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.chars().count() <= 90 {
        return flat;
    }
    let cut: String = flat.chars().take(90).collect();
    format!("{cut}…")
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

fn floor_for(id: &str) -> f64 {
    FLOORS
        .iter()
        .find(|floor| floor.id == id)
        .map(|floor| floor.recall)
        .unwrap_or(DEFAULT_RECALL_FLOOR)
}

/// What a paper may do with entry length: `(longest entry allowed, over-long entries allowed)`.
///
/// A paper with no row in [`ENTRY_LENGTH_CEILINGS`] gets the plausibility bound itself and no
/// over-long entries at all — so adding a paper to the corpus puts it under the strict rule, not
/// outside every rule.
fn entry_length_budget(id: &str) -> (usize, usize) {
    ENTRY_LENGTH_CEILINGS
        .iter()
        .find(|(paper, _, _)| *paper == id)
        .map(|(_, ceiling, over)| (*ceiling, *over))
        .unwrap_or((PLAUSIBLE_ENTRY_CHARS, 0))
}

/// Papers whose bibliography has the shape of a collapse: an entry past its ceiling, or more
/// over-long entries than its pin allows. Empty on a healthy corpus.
fn entry_length_failures(papers: &[&Paper]) -> Vec<String> {
    papers
        .iter()
        .filter_map(|paper| {
            let (ceiling, allowed) = entry_length_budget(&paper.id);
            if paper.max_entry_chars <= ceiling && paper.long_entries <= allowed {
                return None;
            }
            Some(format!(
                "{}: longest entry {} characters (ceiling {}), {} entries over {} (allowed {})",
                paper.id,
                paper.max_entry_chars,
                ceiling,
                paper.long_entries,
                PLAUSIBLE_ENTRY_CHARS,
                allowed
            ))
        })
        .collect()
}

fn percent(value: f64) -> String {
    format!("{:.1}%", value * 100.0)
}

/// The body-page window a paper was measured over: `1–67` for the pages a citation is counted
/// on, `—` when no page was measured.
///
/// It is in the table because the window is *not* stable between runs. Recall is resolved spans
/// divided by *detected* spans, and the body ends where the bibliography parser says the
/// reference list starts, so selecting the bibliography differently moves the window and changes
/// the denominator: GPT-3's body window went from 69 pages to 67 when its bibliography was found
/// earlier, and the two runs' recall figures are not comparable without saying so.
fn body_window(paper: &Paper) -> String {
    match paper.state {
        State::Measured if paper.body_pages > 0 => format!("1–{}", paper.body_pages),
        _ => "—".to_string(),
    }
}

/// The per-paper table. One renderer, so stdout and docs/eval-latest.md cannot drift apart.
///
/// `body` is the body-page window recall was measured over (see [`body_window`]), `links` the
/// link annotations on the scanned pages, and `[Xx12]`/`(12)` count citation shapes the detector
/// does not model (`[HR18]` alphanumeric labels, `(12)` short parenthesised numerals). A line
/// with `spans 0` next to a large `[Xx12]` or `(12)` is a style the detector cannot see, not a
/// paper without citations. `max entry` is the longest bibliography entry in characters and
/// `>1800` how many entries exceed [`PLAUSIBLE_ENTRY_CHARS`] — the two numbers that make a
/// collapse visible instead of merely "few entries".
fn render_table(papers: &[Paper]) -> String {
    let mut out = String::new();
    out.push_str("| paper | pages | body | entries | links | spans | resolved | unresolved | recall | [Xx12] | (12) | max entry | >1800 | floor | status |\n");
    out.push_str(
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |\n",
    );
    for paper in papers {
        match &paper.state {
            State::Absent => {
                out.push_str(&format!(
                    "| `{}` | — | — | — | — | — | — | — | — | — | — | — | — | — | not fetched |\n",
                    paper.id
                ));
            }
            State::Unreadable(error) => {
                out.push_str(&format!(
                    "| `{}` | {} | — | — | — | — | — | — | — | — | — | — | — | — | unreadable: {} |\n",
                    paper.id,
                    paper.pages,
                    error.replace('|', "/")
                ));
            }
            State::Measured => {
                let floor = floor_for(&paper.id);
                let status = if paper.recall() < floor {
                    "BELOW FLOOR"
                } else {
                    "ok"
                };
                out.push_str(&format!(
                    "| `{}` | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} |\n",
                    paper.id,
                    paper.pages,
                    body_window(paper),
                    paper.entries,
                    paper.links,
                    paper.spans,
                    paper.resolved,
                    paper.spans - paper.resolved,
                    percent(paper.recall()),
                    paper.unmodelled_alnum,
                    paper.unmodelled_paren,
                    paper.max_entry_chars,
                    paper.long_entries,
                    percent(floor),
                    status
                ));
            }
        }
    }
    out
}

fn measured(papers: &[Paper]) -> Vec<&Paper> {
    papers
        .iter()
        .filter(|paper| matches!(paper.state, State::Measured))
        .collect()
}

fn print_summary(papers: &[Paper]) {
    let measured = measured(papers);
    let spans: usize = measured.iter().map(|paper| paper.spans).sum();
    let resolved: usize = measured.iter().map(|paper| paper.resolved).sum();
    let partial: usize = measured.iter().map(|paper| paper.partial).sum();
    println!();
    println!(
        "{} of {} corpus papers measured; {} citations detected, {} resolved ({}), {} with at least one unresolved label",
        measured.len(),
        papers.len(),
        spans,
        resolved,
        percent(if spans == 0 {
            0.0
        } else {
            resolved as f64 / spans as f64
        }),
        partial
    );
    let absent = papers
        .iter()
        .filter(|paper| matches!(paper.state, State::Absent))
        .count();
    if absent > 0 {
        println!("{absent} corpus paper(s) not fetched: run ./scripts/fetch-eval-papers.sh");
    }
}

fn write_local_docs(root: &Path, name: &str, body: &str) {
    let docs = root.join("docs");
    if !docs.is_dir() {
        println!(
            "(docs/ does not exist — keeping this run out of it, it is a local-only directory)"
        );
        return;
    }
    let path = docs.join(name);
    match std::fs::write(&path, body) {
        Ok(()) => println!("wrote {}", path.display()),
        Err(error) => println!("could not write {}: {error}", path.display()),
    }
}

/// Measures the whole corpus. Shared by both modes so they cannot disagree.
fn measure_corpus() -> (Vec<Paper>, PathBuf) {
    let root = repo_root();
    let list = corpus_list(&root);
    let dir = corpus_dir(&root);
    let present = present_papers(&dir, &list);

    let mut papers = Vec::new();
    for (index, entry) in list.iter().enumerate() {
        if !present.contains(&index) {
            if dir.is_dir() {
                // A half-fetched corpus is a normal state, but it must be visible in the table.
                papers.push(absent(entry));
            }
            continue;
        }
        println!("== {} — {}", entry.id, entry.note);
        let paper = measure(&entry.id, &dir.join(format!("{}.pdf", entry.id)));
        match &paper.state {
            State::Measured => println!(
                "   {} entries from page {}, {} link annotations, {} body pages, {} spans ({} unresolved), {} suspicious\n     unmodelled shapes in the body: {} alphanumeric labels, {} short parenthesised numerals",
                paper.entries,
                paper.first_entry_page.map(|page| page + 1).unwrap_or(0),
                paper.links,
                paper.body_pages,
                paper.spans,
                paper.spans - paper.resolved,
                paper.flags.len(),
                paper.unmodelled_alnum,
                paper.unmodelled_paren
            ),
            State::Unreadable(error) => println!("   unreadable: {error}"),
            State::Absent => {}
        }
        papers.push(paper);
    }
    (papers, dir)
}

fn absent(entry: &CorpusEntry) -> Paper {
    Paper {
        id: entry.id.clone(),
        state: State::Absent,
        pages: 0,
        entries: 0,
        links: 0,
        first_entry_page: None,
        body_pages: 0,
        spans: 0,
        resolved: 0,
        partial: 0,
        misses: Vec::new(),
        flags: Vec::new(),
        prose_entries: Vec::new(),
        max_entry_chars: 0,
        long_entries: 0,
        unmodelled_alnum: 0,
        unmodelled_paren: 0,
    }
}

// ---------------------------------------------------------------------------
// Mode 1: recall + thresholds
// ---------------------------------------------------------------------------

#[test]
#[ignore = "needs the fetched arXiv corpus (eval-papers/) and a PDFium shared library"]
fn reference_eval_recall() {
    let root = repo_root();
    let list = corpus_list(&root);
    let dir = corpus_dir(&root);
    let present = present_papers(&dir, &list);
    if std::env::var("ARIS_READER_REQUIRE_FULL_EVAL").as_deref() == Ok("1") {
        assert_eq!(
            present.len(),
            list.len(),
            "complete evaluation requested, but some corpus PDFs are absent in {}",
            dir.display()
        );
        assert!(!list.is_empty(), "evaluation corpus list is empty");
    }
    if present.is_empty() {
        announce_skip(&dir, &list);
        return;
    }

    let (papers, dir) = measure_corpus();
    if let Some(gpt3) = papers
        .iter()
        .find(|p| p.id == "2005.14165" && matches!(p.state, State::Measured))
    {
        assert!(
            gpt3.spans >= 190 && gpt3.entries >= 140,
            "GPT-3 detection/bibliography coverage regressed: {} spans, {} entries",
            gpt3.spans,
            gpt3.entries
        );
    }
    // T4.20: `1710.05463` prints one numbering in two runs — 1–33 after the main text, 34–68
    // after the methods. Until the runs were joined the parser returned only the second, and the
    // label guard then dropped every main-text citation: 35 entries and 18 spans, and the body
    // window (which starts where the bibliography does) was 23 pages wide. The pins are the
    // shape, not the exact count: fixing this moved three numbers at once, and a regression would
    // move all three back.
    if let Some(nature) = papers
        .iter()
        .find(|p| p.id == "1710.05463" && matches!(p.state, State::Measured))
    {
        assert!(
            nature.entries >= 60 && nature.spans >= 30,
            "`1710.05463`'s two bibliography runs are not joined: {} entries, {} spans",
            nature.entries,
            nature.spans
        );
    }
    let table = render_table(&papers);
    println!();
    println!(
        "reference index evaluation — corpus {}/tests/eval/arxiv-links.txt",
        root.display()
    );
    println!("PDFs: {}", dir.display());
    println!();
    print!("{table}");
    print_summary(&papers);

    println!();
    println!("thresholds (crates/aris-reader-cli/tests/reference_eval.rs):");
    for floor in FLOORS {
        println!("  {}: recall >= {}", floor.id, percent(floor.recall));
    }
    println!(
        "  any other paper: recall >= {} (default); suspicious matches <= {} of resolved",
        percent(DEFAULT_RECALL_FLOOR),
        percent(FALSE_POSITIVE_BUDGET)
    );
    println!(
        "  longest entry: {} characters by default; pinned higher only where a known tail is \
         measured (see ENTRY_LENGTH_CEILINGS), and every over-long entry must be one of those pins",
        PLAUSIBLE_ENTRY_CHARS
    );

    println!();
    println!(
        "`body` is the window recall was measured over (page 1 through the page before the \
         bibliography). It moves when the bibliography parser selects the list differently, and \
         recall is a ratio over that window, so compare two runs only when their windows match."
    );

    let mut report = String::new();
    report.push_str("# Citation/reference index evaluation (T4.10)\n\n");
    report.push_str(
        "Generated locally by `cargo test -p aris-reader-cli --test reference_eval reference_eval_recall -- --ignored --nocapture`.\n\
         This file is local-only: `docs/` is never committed. The corpus is the list of links in\n\
         `tests/eval/arxiv-links.txt`, fetched into the git-ignored `eval-papers/` directory.\n\n",
    );
    report.push_str("## Per paper\n\n");
    report.push_str(&table);
    report.push_str(
        "\n`recall` = resolved spans / detected citation spans over the body pages. `body` is the \
         window recall was\nmeasured over (page 1 through the page before the bibliography). That \
         window moves when the\nbibliography parser selects the list differently — GPT-3's went \
         from 69 pages to 67 when its bibliography\nwas found earlier — and recall is a ratio over \
         it, so two runs are comparable only when their\nwindows match.\n\n",
    );
    report.push_str("## Thresholds\n\n");
    for floor in FLOORS {
        report.push_str(&format!(
            "* `{}`: recall floor {}\n",
            floor.id,
            percent(floor.recall)
        ));
    }
    report.push_str(&format!(
        "* any other paper: default recall floor {}\n",
        percent(DEFAULT_RECALL_FLOOR)
    ));
    report.push_str(&format!(
        "* false-positive budget: at most {} of resolved spans may be flagged as suspicious\n",
        percent(FALSE_POSITIVE_BUDGET)
    ));
    report.push_str(&format!(
        "* longest bibliography entry: {} characters (`PLAUSIBLE_ENTRY_CHARS`), plus a per-paper\n  ceiling and over-long count pinned in `ENTRY_LENGTH_CEILINGS` — a collapsed bibliography\n  shows up as a handful of entries of thousands of characters\n",
        PLAUSIBLE_ENTRY_CHARS
    ));
    report.push_str(
        "\nThe floors were picked from a real run over this corpus (each one below the measured\n\
         value), not invented before it; see the constants in `crates/aris-reader-cli/tests/reference_eval.rs`.\n",
    );
    write_local_docs(&root, "eval-latest.md", &report);

    let failures: Vec<String> = measured(&papers)
        .iter()
        .filter(|paper| paper.recall() < floor_for(&paper.id))
        .map(|paper| {
            format!(
                "{}: recall {} < floor {} ({} of {} spans resolved)",
                paper.id,
                percent(paper.recall()),
                percent(floor_for(&paper.id)),
                paper.resolved,
                paper.spans
            )
        })
        .collect();
    assert_readable(&papers);
    assert!(
        failures.is_empty(),
        "recall floor(s) not met:\n  {}",
        failures.join("\n  ")
    );
    let collapsed = entry_length_failures(&measured(&papers));
    assert!(
        collapsed.is_empty(),
        "bibliography entries longer than a reference plausibly is — the shape of the T4.17 \
         collapse (one entry per column instead of one per reference):\n  {}",
        collapsed.join("\n  ")
    );
}

// ---------------------------------------------------------------------------
// Mode 2: precision audit
// ---------------------------------------------------------------------------

#[test]
#[ignore = "needs the fetched arXiv corpus (eval-papers/) and a PDFium shared library"]
fn reference_eval_precision_audit() {
    let root = repo_root();
    let list = corpus_list(&root);
    let dir = corpus_dir(&root);
    let present = present_papers(&dir, &list);
    if std::env::var("ARIS_READER_REQUIRE_FULL_EVAL").as_deref() == Ok("1") {
        assert_eq!(
            present.len(),
            list.len(),
            "complete evaluation requested, but some corpus PDFs are absent in {}",
            dir.display()
        );
        assert!(!list.is_empty(), "evaluation corpus list is empty");
    }
    if present.is_empty() {
        announce_skip(&dir, &list);
        return;
    }

    let (papers, dir) = measure_corpus();
    assert_readable(&papers);
    println!();
    println!("precision audit — every match the heuristics find suspicious, with its evidence");
    println!("PDFs: {}", dir.display());
    println!();

    let mut report = String::new();
    report.push_str("# Citation/reference index precision audit (T4.10)\n\n");
    report.push_str(
        "Local-only. A flagged match is a *candidate* false positive for a human to judge, not a\n\
         measured one: the harness cannot know which entry a citation meant.\n",
    );

    let mut total_flags = 0;
    let mut total_gated = 0;
    let mut total_resolved = 0;
    let mut over_budget = Vec::new();
    for paper in measured(&papers) {
        total_flags += paper.flags.len();
        total_gated += paper.gated_flags();
        total_resolved += paper.resolved;
        println!(
            "== {} — {} entries, {} resolved, {} suspicious ({}), {} more for review",
            paper.id,
            paper.entries,
            paper.resolved,
            paper.gated_flags(),
            percent(paper.flag_rate()),
            paper.flags.len() - paper.gated_flags()
        );
        for flag in &paper.flags {
            println!(
                "   {} p{} [{}] \"{}\" -> \"{}\" (p{}): {}",
                if flag.gated { "!" } else { "-" },
                flag.page + 1,
                flag.label,
                flag.span,
                flag.entry_label,
                flag.entry_page + 1,
                flag.reason
            );
            println!("     entry: {}", flag.excerpt);
        }
        for miss in &paper.misses {
            println!(
                "   ? p{} unresolved: \"{}\" labels [{}]",
                miss.page + 1,
                miss.text,
                miss.labels
            );
        }
        for (label, page, length) in &paper.prose_entries {
            println!(
                "   ~ p{} entry [{}]: {} characters — too long or year-less for a reference entry",
                page + 1,
                label,
                length
            );
        }
        if paper.flag_rate() > FALSE_POSITIVE_BUDGET {
            over_budget.push(format!(
                "{}: {} suspicious of {} resolved ({}) > budget {}",
                paper.id,
                paper.gated_flags(),
                paper.resolved,
                percent(paper.flag_rate()),
                percent(FALSE_POSITIVE_BUDGET)
            ));
        }
        // The section header comes first: the entry-level lines below belong to *this* paper, and
        // pushing them before the header filed them under the previous one.
        report.push_str(&format!(
            "\n## `{}`\n\n{} entries, {} resolved, {} suspicious ({}), {} more for review\n\n",
            paper.id,
            paper.entries,
            paper.resolved,
            paper.gated_flags(),
            percent(paper.flag_rate()),
            paper.flags.len() - paper.gated_flags()
        ));
        for flag in &paper.flags {
            report.push_str(&format!(
                "* p{} `{}` → `{}` (p{}): {}\n  * entry: {}\n",
                flag.page + 1,
                flag.span.replace('`', "'"),
                flag.entry_label.replace('`', "'"),
                flag.entry_page + 1,
                flag.reason,
                flag.excerpt.replace('`', "'")
            ));
        }
        for miss in &paper.misses {
            report.push_str(&format!(
                "* unresolved p{}: `{}` labels [{}]\n",
                miss.page + 1,
                miss.text.replace('`', "'"),
                miss.labels.replace('`', "'")
            ));
        }
        for (label, page, length) in &paper.prose_entries {
            report.push_str(&format!(
                "* entry-level: p{} `{}` is {} characters — too long or year-less for a reference entry\n",
                page + 1,
                label.replace('`', "'"),
                length
            ));
        }
    }

    println!();
    println!(
        "{} suspicious match(es) ({} gated by the budget, {} for review) out of {} resolved span(s) across {} measured paper(s) ({})",
        total_flags,
        total_gated,
        total_flags - total_gated,
        total_resolved,
        measured(&papers).len(),
        percent(if total_resolved == 0 {
            0.0
        } else {
            total_flags as f64 / total_resolved as f64
        })
    );
    println!(
        "budget: {} of resolved spans per paper; the list above is what a human has to judge",
        percent(FALSE_POSITIVE_BUDGET)
    );
    report.push_str(&format!(
        "\n## Total\n\n{} suspicious of {} resolved ({})\n",
        total_flags,
        total_resolved,
        percent(if total_resolved == 0 {
            0.0
        } else {
            total_flags as f64 / total_resolved as f64
        })
    ));
    write_local_docs(&root, "eval-audit-latest.md", &report);

    assert!(
        over_budget.is_empty(),
        "suspicious-match budget exceeded:\n  {}",
        over_budget.join("\n  ")
    );
}

/// Neither mode may turn an engine/extraction failure into a passing quality score.
fn assert_readable(papers: &[Paper]) {
    let unreadable: Vec<_> = papers
        .iter()
        .filter_map(|paper| match &paper.state {
            State::Unreadable(error) => Some(format!("{}: {error}", paper.id)),
            _ => None,
        })
        .collect();
    assert!(
        unreadable.is_empty(),
        "corpus papers could not be measured:\n  {}",
        unreadable.join("\n  ")
    );
}

#[test]
#[should_panic(expected = "corpus papers could not be measured")]
fn unreadable_paper_cannot_pass_quality_gate() {
    let mut paper = absent(&CorpusEntry {
        id: "broken".into(),
        note: String::new(),
    });
    paper.state = State::Unreadable("text extraction failed".into());
    assert_readable(&[paper]);
}

/// The one PDF the gold check needs; it also belongs to the evaluation corpus, so
/// `ARIS_READER_EVAL_PAPERS` (or `eval-papers/`) locates it.
const GOLD_PDF: &str = "2005.14165.pdf";

/// How many words from the start of an entry an expected first-author surname may occupy.
///
/// The resolver matches on the label alone, so the gold check's job is to prove the entry it
/// returned is the work the hand-read annotation names. Requiring the surname to be one of the
/// entry's *opening* words is the reader's own, measurable assumption about a reference entry —
/// the first author is in the author list, which opens the entry — and it is deliberately not a
/// window tuned to this data: six words cover the deepest first-author surname here (three
/// given-name words before it), and the binding is asserted against the whole bibliography
/// below, so a wrong window is reported rather than compensated for.
const OPENING_WORDS: usize = 6;

/// The gold check's skip message, the same shape as [`announce_skip`]: a machine without the
/// corpus is *announced*, and the check passes, because an absent PDF is not a parser
/// regression. It is not silent — a silent pass is indistinguishable from a real one — and the
/// other failure direction is preserved: a PDF that is present but unreadable still fails.
fn announce_gold_skip(path: &Path) {
    println!(
        "skipping the GPT-3 gold inventory check: {} is not present",
        path.display()
    );
    println!("  this check needs that one locked PDF, not the whole corpus");
    println!(
        "  fetch it with ./scripts/fetch-eval-papers.sh (or point ARIS_READER_EVAL_PAPERS at it)"
    );
    if std::env::var_os("CI").is_some() {
        println!(
            "::notice title=GPT-3 gold inventory NOT checked::{} is not present, so the independently annotated GPT-3 gold inventory (3 pages, 8 citation spans, 18 labels) was NOT checked in this run. The PDFs are never committed; ./scripts/fetch-eval-papers.sh downloads the corpus that holds it. A green test run says nothing about the gold pages.",
            path.display()
        );
    }
}

/// The gold TSV: the committed annotation by default, or the file named by
/// `ARIS_READER_GPT3_GOLD`. The override exists so the identity predicate can be mutation-tested
/// against a scratch copy of the file; CI never sets it, and the default is the committed file.
fn gold_source() -> String {
    match std::env::var_os("ARIS_READER_GPT3_GOLD") {
        Some(path) => std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("cannot read {}: {error}", Path::new(&path).display())),
        None => include_str!("../../../tests/eval/gpt3-alpha-gold.tsv").to_string(),
    }
}

/// `(citation spans per annotated page, label -> expected first-author surname)`.
///
/// The page map counts citation *spans* — one per gold row, however many labels that span groups —
/// so a page's `find_citations_with` output can be compared span by span. A page annotated as
/// carrying no citations stays in the map with a count of zero: that is an assertion too.
fn gold_inventory(source: &str) -> (BTreeMap<u32, usize>, BTreeMap<String, String>) {
    let mut spans_per_page: BTreeMap<u32, usize> = BTreeMap::new();
    let mut authors: BTreeMap<String, String> = BTreeMap::new();
    for line in source
        .lines()
        .filter(|line| !line.starts_with('#') && !line.is_empty())
    {
        let columns: Vec<&str> = line.split('\t').collect();
        assert_eq!(columns.len(), 3, "gold line {line:?}");
        let page: u32 = columns[0].parse().expect("gold page number");
        spans_per_page.entry(page).or_default();
        if columns[1] == "-" {
            continue;
        }
        let labels: Vec<&str> = columns[1].split(',').collect();
        let surnames: Vec<&str> = columns[2].split(',').collect();
        assert_eq!(
            labels.len(),
            surnames.len(),
            "gold page {}: {} labels but {} surnames",
            page + 1,
            labels.len(),
            surnames.len()
        );
        *spans_per_page.entry(page).or_default() += 1;
        for (label, surname) in labels.into_iter().zip(surnames) {
            assert!(
                authors
                    .insert(label.to_string(), surname.to_string())
                    .is_none(),
                "gold label {label} is listed twice"
            );
        }
    }
    (spans_per_page, authors)
}

/// The publication year a citation key encodes, if it encodes one: four digits anywhere in the
/// key (`NK19` -> 2019, `PNZtY18` -> 2018), else its last two digits read as a 21st-century year.
/// The keys of this bibliography are `surname initial(s) + two-digit year`, so the year is
/// derived from the *citation*, never copied out of the entry text it is checked against.
fn label_identity_year(label: &str) -> Option<String> {
    let digits: String = label.chars().filter(char::is_ascii_digit).collect();
    let mut found: Option<String> = None;
    for start in 0..digits.len().saturating_sub(3) {
        let candidate = &digits[start..start + 4];
        if candidate.starts_with("19") || candidate.starts_with("20") {
            found = Some(candidate.to_string());
        }
    }
    if found.is_none() && digits.len() >= 2 {
        found = Some(format!("20{}", &digits[digits.len() - 2..]));
    }
    found
}

/// Whether `surname` is one of the first `opening_words` words of `text`, compared whole-word.
///
/// Substring containment anywhere in the entry is what made the old predicate weak. Measured over
/// this bibliography's 144 entries, the 18 gold identities matched 105 entries by containment
/// (`Lan` alone matched 49 — it is inside "language" — and `Liu` 19, `Radford` 7, `Yang` 7), and
/// 37 by this opening window. The resolved entry is the *only* match for 15 of the 18; the
/// remaining three (`DL15`/Dai, `RSR+19`/Raffel, `LOG+19`/Liu) share a surname with another
/// first author here, and for those the year check below is what separates them — measured, not
/// assumed: with the year, each of the three narrows to one entry.
fn opening_names(text: &str, surname: &str, opening_words: usize) -> bool {
    let wanted = surname.to_lowercase();
    text.split(|character: char| !character.is_alphanumeric())
        .filter(|word| !word.is_empty())
        .take(opening_words)
        .any(|word| word.to_lowercase() == wanted)
}

/// Where `year` appears in `text` as a whole number, in characters from the start.
///
/// Whole-number matching is the point: `1301` inside `arXiv:1301.3781` is not a year, and digits
/// inside a longer run are not either.
fn year_position(text: &str, year: &str) -> Option<usize> {
    let padded = format!(" {} ", text.to_lowercase());
    let mut from = 0usize;
    while let Some(offset) = padded[from..].find(year) {
        let at = from + offset;
        let before = padded[..at].chars().next_back();
        let after = padded[at + year.len()..].chars().next();
        let bounded = |character: Option<char>| character.is_none_or(|c| !c.is_alphanumeric());
        if bounded(before) && bounded(after) {
            return Some(padded[..at].chars().count());
        }
        from = at + year.len();
    }
    None
}

/// Independent full-page gold inventory: catches both missing groups and extra detections, and
/// proves that every label resolves to the entry the hand-read annotation names.
///
/// The identity predicate is two facts the resolver does not use, both read off the entry itself:
/// the expected first-author surname is one of the entry's opening words ([`OPENING_WORDS`]), and
/// the year the citation key encodes labels that same entry. It used to be
/// `entry.text.contains(author)` — containment anywhere — which most of the gold labels could not
/// falsify even if the resolver returned the wrong entry. The old predicate never failed on a
/// *correct* resolution, so this one is strictly sharper; every expectation was read from a
/// rendered page and never generated from the detector.
#[test]
#[ignore = "needs the locked arXiv corpus and PDFium"]
fn gpt3_alphanumeric_gold_pages() {
    let root = repo_root();
    let path = corpus_dir(&root).join(GOLD_PDF);
    if !path.is_file() {
        announce_gold_skip(&path);
        return;
    }
    let backend = PdfiumBackend::open(&path, None).expect("locked GPT-3 PDF must be readable");
    let pages: Vec<_> = (0..backend.page_count())
        .map(|p| {
            (
                p,
                backend
                    .raw_text_page(PageIndex(p))
                    .expect("extract gold document"),
            )
        })
        .collect();
    let references = find_references(pages.iter().map(|(p, t)| (*p, t)), MAX_ENTRIES);
    let style = CitationStyle::for_document(&pages, &references);
    assert!(style.uses_alphanumeric_labels());
    let (spans_per_page, authors) = gold_inventory(&gold_source());

    let mut labels_checked = 0;
    let mut years_checked = 0;
    let mut late_years = 0usize;
    let mut first_page: Option<u32> = None;
    for (page, spans) in &spans_per_page {
        let raw = &pages[*page as usize].1;
        let found = find_citations_with(raw, &style);
        assert_eq!(
            found.len(),
            *spans,
            "gold page {}: unexpected/missing citation",
            page + 1
        );
        if !found.is_empty() {
            first_page.get_or_insert(*page);
        }
        for citation in &found {
            let entries = resolve_references(&citation.labels, &references);
            assert_eq!(
                entries.len(),
                citation.labels.len(),
                "gold page {}: every label must resolve",
                page + 1
            );
            for (entry, label) in entries.iter().zip(&citation.labels) {
                let author = &authors[label];
                assert_eq!(
                    &entry.label,
                    label,
                    "gold page {}: entry label does not match the resolved label",
                    page + 1
                );
                assert!(
                    opening_names(&entry.text, author, OPENING_WORDS),
                    "{label} must resolve to the {author} entry: {author} is not one of its first \
                     {OPENING_WORDS} words (entry on page {}, opening: {:?})",
                    entry.page + 1,
                    entry.text.chars().take(90).collect::<String>()
                );
                // Every key in this gold set encodes a year; a future row whose key does not would
                // fall back to the hand-read surname alone.
                if let Some(year) = label_identity_year(label) {
                    match year_position(&entry.text, &year) {
                        Some(at) => {
                            years_checked += 1;
                            // A long author list puts the year far down the entry. Say so rather
                            // than let a reader take "contains the year" for a tight check.
                            late_years += usize::from(at > 200);
                        }
                        None => panic!(
                            "{label} ({year}) resolves to an entry that names {year} nowhere: {:?}",
                            entry.text.chars().take(140).collect::<String>()
                        ),
                    }
                }
                assert!(!entry.fragments.is_empty(), "preview geometry for {label}");
                labels_checked += 1;
            }
            let source: String = raw.chars[citation.start..citation.end]
                .iter()
                .map(|c| char::from_u32(c.unicode).unwrap_or(char::REPLACEMENT_CHARACTER))
                .collect();
            assert_eq!(
                citation.text, source,
                "character offsets preserve the source span"
            );
        }
    }
    let cited_pages = spans_per_page.values().filter(|spans| **spans > 0).count();
    let cited_spans = spans_per_page.values().sum::<usize>();
    println!(
        "GPT-3 gold: {} annotated pages ({} of them carry the {cited_spans} citation spans; the \
         others must detect nothing), {labels_checked}/18 labels with checked identities; the \
         year in the citation key also labelled the entry for {years_checked} of those keys \
         ({late_years} of the {years_checked} years sit past character 200, i.e. behind a long \
         author list; a key that encoded no year would be checked by surname alone)",
        spans_per_page.len(),
        cited_pages,
    );
    assert_eq!(labels_checked, 18);
    assert!(years_checked > 0, "no citation key encoded a year");
    assert!(first_page.is_some(), "no gold page produced a citation");
}

// ---------------------------------------------------------------------------
// T4.41 — two bibliographies under independent numberings
// ---------------------------------------------------------------------------

/// The one PDF the two-bibliography check needs; it is also in the evaluation corpus, so
/// `ARIS_READER_EVAL_PAPERS` (or `eval-papers/`) locates it.
const TWO_BIBLIOGRAPHY_PDF: &str = "2303.08774.pdf";

/// The skip message, the same shape as the gold check's: an absent PDF is announced, not a
/// failure, and CI is told the check did not run.
fn announce_two_bibliography_skip(path: &Path) {
    println!(
        "skipping the GPT-4 two-bibliography check: {} is not present",
        path.display()
    );
    println!("  this check needs that one locked PDF (2303.08774v6), not the whole corpus");
    println!(
        "  fetch it with ./scripts/fetch-eval-papers.sh (or point ARIS_READER_EVAL_PAPERS at it)"
    );
    if std::env::var_os("CI").is_some() {
        println!(
            "::notice title=GPT-4 two-bibliography check NOT run::{} is not present, so the check that the report's main text resolves into its own reference list — not into the system card appendix's independently numbered list — was NOT run. The PDFs are never committed; ./scripts/fetch-eval-papers.sh downloads the corpus that holds it. A green test run says nothing about this paper.",
            path.display()
        );
    }
}

/// `2303.08774` prints **two** reference lists, each numbered from `[1]`: the report's own
/// (pages 18–23, 85 entries) and the system card appendix's (pages 71–78, 105 entries). The
/// appendix's list is longer and headed, so the layout score alone picks it, and every citation
/// in the report's main text then resolves into it: the main text's `[13]` (Kojima, zero-shot
/// reasoners) previews the appendix's `[13]` (Christiano, deep reinforcement learning from human
/// preferences) instead. Both lists are real lists, so no layout test can call one of them wrong;
/// what the parser has to read is which one the citing text refers to.
///
/// This check is label-level on purpose. The paper's recall was 99.2% while the defect was live —
/// a wrong-but-internally-consistent list resolves every label — so a page number or a hit rate
/// cannot see it. What is asserted here is the identity of the entry a label reaches: the report's
/// `[13]` must be the Kojima entry, the report's `[1]` the Brown "Language Models are Few-Shot
/// Learners" entry, and every numeric citation in the main text must land on a page of the
/// report's own list (18–23), never on the appendix's (71–78).
#[test]
#[ignore = "needs the locked arXiv corpus and PDFium"]
fn gpt4_main_text_resolves_into_the_reports_own_bibliography() {
    let root = repo_root();
    let path = corpus_dir(&root).join(TWO_BIBLIOGRAPHY_PDF);
    if !path.is_file() {
        announce_two_bibliography_skip(&path);
        return;
    }
    let backend = PdfiumBackend::open(&path, None).expect("locked GPT-4 PDF must be readable");
    let pages: Vec<(u32, RawTextPage)> = (0..backend.page_count())
        .map(|page| {
            (
                page,
                backend
                    .raw_text_page(PageIndex(page))
                    .expect("extract locked document"),
            )
        })
        .collect();
    // The app's own two passes: find the list, collect the link landings that point into it,
    // rebuild with that geometry (crates/aris-reader-cli/src/main.rs).
    let provisional = find_references(pages.iter().map(|(page, text)| (*page, text)), MAX_ENTRIES);
    let first = provisional
        .iter()
        .map(|entry| entry.page)
        .min()
        .expect("bibliography");
    let mut landings: BTreeMap<u32, Vec<f64>> = BTreeMap::new();
    for page in 0..first {
        for link in backend.link_targets(PageIndex(page)).expect("links") {
            if let (Some(target), Some(top)) = (link.page, link.dest_top_y)
                && target.get() >= first
            {
                landings.entry(target.get()).or_default().push(top);
            }
        }
    }
    let references = find_references_with_landings(&pages, &landings, MAX_ENTRIES);
    assert_eq!(
        (
            references.iter().map(|entry| entry.page).min(),
            references.iter().map(|entry| entry.page).max(),
            references.len()
        ),
        (Some(17), Some(22), 85),
        "the selected bibliography is not the report's own list (pages 18–23, 85 entries)"
    );

    let entry = |label: &str| {
        resolve_reference(&[label.to_string()], &references)
            .unwrap_or_else(|| panic!("[{label}] must resolve"))
    };
    let thirteen = entry("13");
    assert!(
        thirteen.text.contains("Kojima") && thirteen.text.contains("zero-shot reasoners"),
        "[13] must be the report's Kojima entry: {:?}",
        thirteen.text.chars().take(120).collect::<String>()
    );
    assert!(
        !thirteen.text.contains("Christiano"),
        "[13] resolved into the system card appendix's list: {:?}",
        thirteen.text.chars().take(120).collect::<String>()
    );
    let one = entry("1");
    assert!(
        one.text.contains("Brown") && one.text.contains("few-shot learners"),
        "[1] must be the report's Brown entry: {:?}",
        one.text.chars().take(120).collect::<String>()
    );

    // The whole main text, not one label: every numeric label it cites must resolve onto the
    // report's list. This is the user-visible claim — clicking a citation in the body previews an
    // entry of the list that body cites — and it is what failed before T4.41, when all of them
    // landed on pages 71–78.
    let style = CitationStyle::for_document(&pages, &references);
    let mut spans = 0usize;
    let mut labels = 0usize;
    let mut carried_thirteen = false;
    for (page, text) in pages.iter().filter(|(page, _)| *page < first) {
        for citation in find_citations_with(text, &style) {
            if citation.labels.is_empty()
                || !citation
                    .labels
                    .iter()
                    .all(|label| label.chars().all(|c| c.is_ascii_digit()))
            {
                continue;
            }
            spans += 1;
            for label in &citation.labels {
                let resolved = resolve_reference(std::slice::from_ref(label), &references)
                    .unwrap_or_else(|| panic!("page {}: [{label}] must resolve", page + 1));
                assert!(
                    (17..=22).contains(&resolved.page),
                    "page {}: [{label}] resolved to page {}, outside the report's own list",
                    page + 1,
                    resolved.page + 1
                );
                carried_thirteen |= label == "13";
                labels += 1;
            }
        }
    }
    assert!(spans > 0, "the main text detected no numeric citation");
    assert!(
        carried_thirteen,
        "no main-text citation carries label 13, so the identity check above is the only evidence"
    );
    println!(
        "GPT-4 two-bibliography check: {} entries on pages 18–23; [1] Brown, [13] Kojima; \
         {labels} label(s) over {spans} main-text span(s), every one inside the report's list",
        references.len()
    );
}
