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
//! Two modes:
//!
//! * [`reference_eval_recall`] — one row per paper (entries, spans, resolved, unresolved,
//!   recall) printed to stdout and, when the local-only `docs/` directory exists, written to
//!   `docs/eval-latest.md`. It fails a paper whose recall is below its floor.
//! * [`reference_eval_precision_audit`] — the same measurement, but it prints the individual
//!   matches that *look* wrong so a human can judge them. Precision is not a number this
//!   harness can produce on its own: a resolved match is only a false positive if a human says
//!   so. The audit makes the candidates visible instead of inventing a score.
//!
//! Both modes skip cleanly when the corpus is absent and, on CI, emit a `::notice::` saying the
//! evaluation did NOT run: a silent pass here would be indistinguishable from a real one.
//! Set `ARIS_READER_REQUIRE_FULL_EVAL=1` to require every listed PDF (used by manual CI).
//! Both modes fail on document-open or page-text errors; partial extraction is not a score.

use aris_reader_core::{DocumentBackend, PageIndex, RawTextPage};
use aris_reader_pdfium::PdfiumBackend;
use aris_reader_text::{
    Citation, CitationStyle, ReferenceEntry, find_citations_with, find_references,
    find_references_with_landings, resolve_reference, resolve_references,
};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

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
    }, // measured 99.2% (245/247); 100 pages, 105 entries
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
    // Papers whose citation style the detector has no path for. The floor is 0.00 because the
    // measurement is vacuous, NOT because the parser is fine: the table's probe columns are what
    // expose them.
    Floor {
        id: "2005.14165",
        recall: 0.00,
    }, // alphanumeric labels: 224 in the body, 0 spans detected
    Floor {
        id: "1712.01815",
        recall: 0.00,
    }, // NOT superscripts in this text layer: its citations are ordinary `(9)` / `(2, 14)` at
    // body size on the baseline (height ratio 0.97, rise +0.27 pt against a 10.69 pt body), so
    // no geometric rule can see them; the 20 shapes are counted by the `(12)` column
    Floor {
        id: "1710.05463",
        recall: 0.90,
    }, // measured 100% (18/18) once superscript numerals were detected; the floor is new, and it
       // is 0.90 rather than 1.00 because only the part of the list the bibliography parser
       // selects (entries 34-68) can corroborate a label: its main-text citations, labels 1-33,
       // are dropped by the label guard instead of being guessed at
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

/// Pages extracted per paper. The reader caps its own index at 120 pages (T4.13), so a longer
/// document is measured exactly as the app would see it.
const MAX_PAGES: u32 = 120;

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
    Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..")
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
    let scan_end = total.min(MAX_PAGES);
    let mut pages: Vec<(u32, RawTextPage)> = Vec::new();
    for index in 0..scan_end {
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
        for page in 0..first.min(scan_end) {
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
        paper.unmodelled_alnum += alnum;
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

fn percent(value: f64) -> String {
    format!("{:.1}%", value * 100.0)
}

/// The per-paper table. One renderer, so stdout and docs/eval-latest.md cannot drift apart.
///
/// `bib` is the measured column count of the reference list, `links` the link annotations on the
/// scanned pages, and the last two columns count citation shapes the detector does not model
/// (`[HR18]` alphanumeric labels, `(12)` short parenthesised numerals). A line with `spans 0`
/// next to a large `[Xx12]` or `(12)` is a style the detector cannot see, not a paper without
/// citations.
fn render_table(papers: &[Paper]) -> String {
    let mut out = String::new();
    out.push_str("| paper | pages | entries | links | spans | resolved | unresolved | recall | [Xx12] | (12) | floor | status |\n");
    out.push_str(
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |\n",
    );
    for paper in papers {
        match &paper.state {
            State::Absent => {
                out.push_str(&format!(
                    "| `{}` | — | — | — | — | — | — | — | — | — | — | not fetched |\n",
                    paper.id
                ));
            }
            State::Unreadable(error) => {
                out.push_str(&format!(
                    "| `{}` | {} | — | — | — | — | — | — | — | — | — | unreadable: {} |\n",
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
                    "| `{}` | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} |\n",
                    paper.id,
                    paper.pages,
                    paper.entries,
                    paper.links,
                    paper.spans,
                    paper.resolved,
                    paper.spans - paper.resolved,
                    percent(paper.recall()),
                    paper.unmodelled_alnum,
                    paper.unmodelled_paren,
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

    let mut report = String::new();
    report.push_str("# Citation/reference index evaluation (T4.10)\n\n");
    report.push_str(
        "Generated locally by `cargo test -p aris-reader-cli --test reference_eval reference_eval_recall -- --ignored --nocapture`.\n\
         This file is local-only: `docs/` is never committed. The corpus is the list of links in\n\
         `tests/eval/arxiv-links.txt`, fetched into the git-ignored `eval-papers/` directory.\n\n",
    );
    report.push_str("## Per paper\n\n");
    report.push_str(&table);
    report
        .push_str("\n`recall` = resolved spans / detected citation spans over the body pages.\n\n");
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
