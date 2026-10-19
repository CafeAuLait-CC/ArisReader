//! Index-quality report: what the citation, caption and table indexes actually found, and what
//! happened to it.
//!
//! # Why this exists
//!
//! The corpus regression tests answer "did the number move?" with one pinned expectation per
//! paper. That is a good alarm and a poor diagnosis: a single citation that stops resolving and a
//! question the detector never saw both look like "one less", and a change that detects many more
//! spans at a lower resolution rate can look like an improvement in one number and a regression in
//! another. This subcommand turns the same measurements into a per-document report a person can
//! read, and into a versioned JSON baseline a later run can be compared against.
//!
//! # What is measured, and what is not
//!
//! * **Citations** are the spans `find_citations_with` reports in the citation window (the first
//!   three pages by default, the regression contract's sample; `--body-pages 0` scans every page
//!   before the document-wide bibliography). A span is **resolved** when at least one of its
//!   labels reaches an entry in the list the app would use for that page; a span whose labels all
//!   resolve is `resolved` in the span list, one with some labels missing is `partial`, and one
//!   with none is `unresolved`. `detected` is therefore the denominator, not a recall estimate:
//!   the detector is the same function the reader uses, and a citation it never found is not
//!   counted as a failure here. Precision is not claimed either: a resolved span can have landed
//!   on the wrong entry, and this report contains no ground truth to say so.
//! * **Captions** are every `find_captions` result on every page. A caption is `multi_line` when
//!   its character range covers more than one extraction line, and it `opens`/`does not close`
//!   when its text does not end with sentence or clause punctuation (the completeness check in
//!   `caption_corpus.rs`). The last line is reported with the page so a person can see what was
//!   cut.
//! * **Tables** are the `Table` captions; a table is a **grid region** when `table_outcome` finds
//!   rules (or a text tier) for it, and a fallback otherwise. The fallback reason is the
//!   `GridOutcome` label.
//!
//! # Corpus
//!
//! The corpus is local and never committed. `LYRA_READER_PDF_SAMPLES` and
//! `LYRA_READER_EVAL_PAPERS` each point at a directory of PDFs; either may be set, at least one
//! must be. A set variable whose directory is missing or empty is an error, not a skip.
//!
//! # Baseline format (version 1)
//!
//! ```json
//! {
//!   "format": "lyra-reader-index-quality",
//!   "version": 1,
//!   "citation_window": 3,
//!   "corpora": [
//!     {"id": "pdf-samples", "env": "LYRA_READER_PDF_SAMPLES", "documents": 12},
//!     {"id": "eval-papers", "env": "LYRA_READER_EVAL_PAPERS", "documents": 20}
//!   ],
//!   "totals": { "documents": 32, "citations": {...}, "captions": {...}, "tables": {...} },
//!   "documents": [{
//!     "id": "eval-papers/1512.03385.pdf",
//!     "corpus": "eval-papers",
//!     "file": "1512.03385.pdf",
//!     "pages": 12,
//!     "citations": {
//!       "detected": 84, "resolved": 83, "fully_resolved": 83, "partial": 0, "unresolved": 1,
//!       "labels": {"attempted": 84, "resolved": 83},
//!       "bibliography": {"entries": 50, "lists": 1, "first_page": 8},
//!       "spans": [{"page": 4, "text": "[256, 480]", "labels": ["256", "480"],
//!                   "status": "unresolved", "resolved_labels": [],
//!                   "missing_labels": [{"label": "256", "reason": "label_absent"}, ...]}]
//!     },
//!     "captions": {"detected": 14, "multi_line": 10, "closing": 13,
//!                   "open": [{"page": 7, "kind": "Figure", "label": "5",
//!                             "last_line": "..."}]},
//!     "tables": {"detected": 4, "grid_regions": 2, "fallbacks": 2,
//!                 "fallback_reasons": {"no rules near the caption": 2},
//!                 "regions": [{"page": 7, "label": "1", "outcome": "ruled", "grid": true}]}
//!   }]
//! }
//! ```
//!
//! Pages are one-based, as printed. Documents are sorted by corpus and file name, and the format
//! carries no timestamps, absolute paths or tool versions, so two runs over the same files produce
//! byte-identical JSON. The version is bumped when a field is removed or its meaning changes; the
//! comparator refuses a baseline of another version instead of guessing.
//!
//! # Failure reasons
//!
//! * `no_bibliography` — the document has no usable reference list, so no label could resolve.
//! * `list_not_found` — a list exists and prints the label, but not the list this citation was
//!   attributed to. This is a list-selection failure, not a missing entry.
//! * `label_absent` — no reference list in the document prints the label.
//! * `label_ambiguous` — the attributed list prints the label more than once, so the resolver
//!   refuses to pick one. (A label printed once in each of several lists is *not* a failure: the
//!   document-wide fallback resolves it; that is an attribution question, reported by `cite`.)

use lyra_reader_core::{DocumentBackend, PageIndex, RawTextPage};
use lyra_reader_pdfium::PdfiumBackend;
use lyra_reader_text::{
    Bibliography, Caption, CitationAttribution, CitationStyle, ReferenceEntry, attribute_citation,
    find_captions, find_citations_with, find_reference_lists_with_landings, find_references,
    lines_from, resolve_reference, tables::table_outcome,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

/// Identifies the JSON format. A reader checks this before the version.
pub const REPORT_FORMAT: &str = "lyra-reader-index-quality";
/// Bumped whenever a field is removed or its meaning changes.
pub const REPORT_VERSION: u32 = 1;

/// The citation window the regression contract samples.
const DEFAULT_CITATION_WINDOW: usize = 3;
/// The cap every other reference consumer uses; the corpora are far below it.
const MAX_ENTRIES: usize = 2000;

/// The two local corpora, in report order. The environment variable is the only way in: PDFs are
/// never committed and a path in the report would make baselines machine-specific.
const CORPORA: [(&str, &str); 2] = [
    ("pdf-samples", "LYRA_READER_PDF_SAMPLES"),
    ("eval-papers", "LYRA_READER_EVAL_PAPERS"),
];

// ---------------------------------------------------------------------------
// Report model
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Report {
    pub format: String,
    pub version: u32,
    /// Citation pages per document. `0` means every page before the bibliography.
    pub citation_window: usize,
    pub corpora: Vec<CorpusReport>,
    pub totals: Totals,
    pub documents: Vec<DocumentReport>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CorpusReport {
    /// Stable corpus name (`pdf-samples`, `eval-papers`), also the document id prefix.
    pub id: String,
    /// The environment variable the directory came from.
    pub env: String,
    pub documents: usize,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DocumentReport {
    /// `{corpus}/{file name}`; stable across checkouts because it carries no directory.
    pub id: String,
    pub corpus: String,
    pub file: String,
    pub pages: u32,
    pub citations: CitationReport,
    pub captions: CaptionReport,
    pub tables: TableReport,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CitationReport {
    /// Spans the detector found in the citation window.
    pub detected: usize,
    /// Spans with at least one label resolved. This is the contract's `resolved`.
    pub resolved: usize,
    /// Spans with every label resolved.
    pub fully_resolved: usize,
    /// Spans with some, but not all, labels resolved.
    pub partial: usize,
    /// Spans with no label resolved.
    pub unresolved: usize,
    pub labels: LabelReport,
    pub bibliography: BibliographyReport,
    /// Every detected span, in reading order. Baselines diff this list.
    pub spans: Vec<Span>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct LabelReport {
    pub attempted: usize,
    pub resolved: usize,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct BibliographyReport {
    /// Entries in the document-wide list.
    pub entries: usize,
    /// Every reference list the document prints.
    pub lists: usize,
    /// First page of the document-wide list, one-based.
    pub first_page: Option<u32>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Span {
    /// One-based page number.
    pub page: u32,
    /// The citation as printed (without brackets or parentheses).
    pub text: String,
    pub labels: Vec<String>,
    pub status: SpanStatus,
    /// Labels that reached an entry, in label order.
    pub resolved_labels: Vec<String>,
    /// Labels that did not, each with the reason.
    pub missing_labels: Vec<MissingLabel>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SpanStatus {
    /// Every label resolved.
    Resolved,
    /// Some labels resolved, some did not.
    Partial,
    /// No label resolved.
    Unresolved,
}

impl SpanStatus {
    fn label(self) -> &'static str {
        match self {
            Self::Resolved => "resolved",
            Self::Partial => "partial",
            Self::Unresolved => "unresolved",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MissingLabel {
    pub label: String,
    pub reason: MissReason,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MissReason {
    /// The document has no usable reference list.
    NoBibliography,
    /// The label is printed by a list, but not the list this citation was attributed to.
    ListNotFound,
    /// No list in the document prints the label.
    LabelAbsent,
    /// The attributed list prints the label more than once.
    LabelAmbiguous,
}

impl MissReason {
    fn label(self) -> &'static str {
        match self {
            Self::NoBibliography => "no bibliography",
            Self::ListNotFound => "list not found",
            Self::LabelAbsent => "label absent",
            Self::LabelAmbiguous => "label ambiguous",
        }
    }

    fn key(self) -> &'static str {
        match self {
            Self::NoBibliography => "no_bibliography",
            Self::ListNotFound => "list_not_found",
            Self::LabelAbsent => "label_absent",
            Self::LabelAmbiguous => "label_ambiguous",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CaptionReport {
    pub detected: usize,
    /// Captions whose character range covers more than one extraction line.
    pub multi_line: usize,
    /// Captions whose text ends with sentence or clause punctuation.
    pub closing: usize,
    /// Captions that do not close, with the page and the last line.
    pub open: Vec<OpenCaption>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OpenCaption {
    pub page: u32,
    pub kind: String,
    pub label: String,
    pub last_line: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TableReport {
    /// `Table` captions detected.
    pub detected: usize,
    /// Captions for which a grid region was found.
    pub grid_regions: usize,
    /// Captions that fell back to the page.
    pub fallbacks: usize,
    /// Fallback count per `GridOutcome` label. Stable keys, sorted.
    pub fallback_reasons: BTreeMap<String, usize>,
    /// Every table caption's region outcome, for baseline diffs.
    pub regions: Vec<TableRegion>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TableRegion {
    pub page: u32,
    pub label: String,
    /// The `GridOutcome` label (`ruled`, `text-only`, `no rules near the caption`, …).
    pub outcome: String,
    pub grid: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Totals {
    pub documents: usize,
    pub citations: CitationTotals,
    pub captions: CaptionTotals,
    pub tables: TableTotals,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CitationTotals {
    pub detected: usize,
    pub resolved: usize,
    pub fully_resolved: usize,
    pub partial: usize,
    pub unresolved: usize,
    pub labels_attempted: usize,
    pub labels_resolved: usize,
    pub documents_with_bibliography: usize,
    pub documents_without_bibliography: usize,
    pub bibliography_entries: usize,
    /// Missing labels per reason key, sorted.
    pub missing_reasons: BTreeMap<String, usize>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CaptionTotals {
    pub detected: usize,
    pub multi_line: usize,
    pub closing: usize,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TableTotals {
    pub detected: usize,
    pub grid_regions: usize,
    pub fallbacks: usize,
    pub fallback_reasons: BTreeMap<String, usize>,
}

fn recompute_totals<'a>(documents: impl IntoIterator<Item = &'a DocumentReport>) -> Totals {
    let mut documents_count = 0usize;
    let mut citations = CitationTotals {
        detected: 0,
        resolved: 0,
        fully_resolved: 0,
        partial: 0,
        unresolved: 0,
        labels_attempted: 0,
        labels_resolved: 0,
        documents_with_bibliography: 0,
        documents_without_bibliography: 0,
        bibliography_entries: 0,
        missing_reasons: BTreeMap::new(),
    };
    let mut captions = CaptionTotals {
        detected: 0,
        multi_line: 0,
        closing: 0,
    };
    let mut tables = TableTotals {
        detected: 0,
        grid_regions: 0,
        fallbacks: 0,
        fallback_reasons: BTreeMap::new(),
    };

    for document in documents {
        documents_count += 1;
        let report = &document.citations;
        citations.detected += report.detected;
        citations.resolved += report.resolved;
        citations.fully_resolved += report.fully_resolved;
        citations.partial += report.partial;
        citations.unresolved += report.unresolved;
        citations.labels_attempted += report.labels.attempted;
        citations.labels_resolved += report.labels.resolved;
        if report.bibliography.entries > 0 {
            citations.documents_with_bibliography += 1;
        } else {
            citations.documents_without_bibliography += 1;
        }
        citations.bibliography_entries += report.bibliography.entries;
        for span in &report.spans {
            for missing in &span.missing_labels {
                *citations
                    .missing_reasons
                    .entry(missing.reason.key().to_string())
                    .or_default() += 1;
            }
        }

        captions.detected += document.captions.detected;
        captions.multi_line += document.captions.multi_line;
        captions.closing += document.captions.closing;

        tables.detected += document.tables.detected;
        tables.grid_regions += document.tables.grid_regions;
        tables.fallbacks += document.tables.fallbacks;
        for (reason, count) in &document.tables.fallback_reasons {
            *tables.fallback_reasons.entry(reason.clone()).or_default() += count;
        }
    }

    Totals {
        documents: documents_count,
        citations,
        captions,
        tables,
    }
}

// ---------------------------------------------------------------------------
// Corpus discovery
// ---------------------------------------------------------------------------

struct CorpusFiles {
    id: &'static str,
    env: &'static str,
    dir: PathBuf,
    files: Vec<PathBuf>,
}

fn discover_corpora() -> Result<Vec<CorpusFiles>, String> {
    let mut corpora = Vec::new();
    for (id, env) in CORPORA {
        let Some(value) = std::env::var_os(env) else {
            continue;
        };
        if value.is_empty() {
            return Err(format!("{env} is set but empty"));
        }
        let dir = PathBuf::from(&value);
        if !dir.is_dir() {
            return Err(format!(
                "{env}={} is not a directory (PDFs are never committed; point it at the local corpus)",
                dir.display()
            ));
        }
        let mut files = Vec::new();
        let entries = std::fs::read_dir(&dir)
            .map_err(|error| format!("cannot read {env}={}: {error}", dir.display()))?;
        for entry in entries {
            let path = entry
                .map_err(|error| format!("cannot read {env}={}: {error}", dir.display()))?
                .path();
            if path.is_file()
                && path
                    .extension()
                    .is_some_and(|kind| kind.eq_ignore_ascii_case("pdf"))
            {
                files.push(path);
            }
        }
        files.sort();
        if files.is_empty() {
            return Err(format!(
                "{env}={} contains no PDFs (PDFs are never committed)",
                dir.display()
            ));
        }
        corpora.push(CorpusFiles {
            id,
            env,
            dir,
            files,
        });
    }
    if corpora.is_empty() {
        return Err(
            "no corpus: set LYRA_READER_PDF_SAMPLES and/or LYRA_READER_EVAL_PAPERS \
             to a directory of PDFs (at least one is required)"
                .to_string(),
        );
    }
    Ok(corpora)
}

// ---------------------------------------------------------------------------
// Measurement
// ---------------------------------------------------------------------------

fn measure_document(
    corpus: &str,
    path: &Path,
    citation_window: usize,
) -> Result<DocumentReport, String> {
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.display().to_string());
    let backend = PdfiumBackend::open(path, None)
        .map_err(|error| format!("cannot open {}: {error}", path.display()))?;
    let pages = read_pages(&backend, path)?;
    let bibliography = find_bibliography(&backend, &pages, path)?;
    let document_wide = bibliography
        .document_wide_list()
        .map(|list| list.entries.clone())
        .unwrap_or_default();
    let style = CitationStyle::for_document(&pages, &document_wide);

    let citations = measure_citations(&pages, &bibliography, &style, citation_window);
    let (captions, tables) = measure_captions(&backend, &pages, path)?;

    Ok(DocumentReport {
        id: format!("{corpus}/{name}"),
        corpus: corpus.to_string(),
        file: name,
        pages: backend.page_count(),
        citations,
        captions,
        tables,
    })
}

fn read_pages(backend: &PdfiumBackend, path: &Path) -> Result<Vec<(u32, RawTextPage)>, String> {
    let total = backend.page_count();
    let mut pages = Vec::with_capacity(total as usize);
    for index in 0..total {
        let text = backend.raw_text_page(PageIndex(index)).map_err(|error| {
            format!(
                "{}: page {} text failed: {error}",
                path.display(),
                index + 1
            )
        })?;
        pages.push((index, text));
    }
    Ok(pages)
}

/// The bibliography exactly as the app builds it: provisional parse, link landings into the list,
/// then every reference list with the document-wide one rebuilt from those landings.
fn find_bibliography(
    backend: &PdfiumBackend,
    pages: &[(u32, RawTextPage)],
    path: &Path,
) -> Result<Bibliography, String> {
    let provisional = find_references(pages.iter().map(|(page, text)| (*page, text)), MAX_ENTRIES);
    let first_list_page = provisional.iter().map(|entry| entry.page).min();
    let mut landings: BTreeMap<u32, Vec<f64>> = BTreeMap::new();
    if let Some(first) = first_list_page {
        for page in 0..first {
            let links = backend.link_targets(PageIndex(page)).map_err(|error| {
                format!(
                    "{}: page {} links failed: {error}",
                    path.display(),
                    page + 1
                )
            })?;
            for link in links {
                if let (Some(target), Some(top)) = (link.page, link.dest_top_y)
                    && target.get() >= first
                {
                    landings.entry(target.get()).or_default().push(top);
                }
            }
        }
    }
    Ok(find_reference_lists_with_landings(
        pages,
        &landings,
        MAX_ENTRIES,
    ))
}

fn measure_citations(
    pages: &[(u32, RawTextPage)],
    bibliography: &Bibliography,
    style: &CitationStyle,
    citation_window: usize,
) -> CitationReport {
    let total = pages.len() as u32;
    let end = if citation_window == 0 {
        bibliography
            .document_wide_list()
            .and_then(|list| list.first_page())
            .unwrap_or(total)
    } else {
        total.min(citation_window.min(u32::MAX as usize) as u32)
    };

    let mut report = CitationReport {
        detected: 0,
        resolved: 0,
        fully_resolved: 0,
        partial: 0,
        unresolved: 0,
        labels: LabelReport {
            attempted: 0,
            resolved: 0,
        },
        bibliography: BibliographyReport {
            entries: bibliography
                .document_wide_list()
                .map(|list| list.entries.len())
                .unwrap_or(0),
            lists: bibliography.lists.len(),
            first_page: bibliography
                .document_wide_list()
                .and_then(|list| list.first_page())
                .map(|page| page + 1),
        },
        spans: Vec::new(),
    };

    for (page, text) in pages.iter().filter(|(page, _)| *page < end) {
        for citation in find_citations_with(text, style) {
            // The detectors do not produce label-less spans today. If one ever does, counting it
            // as a resolution failure would blame the resolver for a detector result nobody can
            // resolve; it is left out and `detected` stays "spans that name a label".
            if citation.labels.is_empty() {
                continue;
            }
            let attribution = attribute_citation(bibliography, *page, &citation.labels);
            let entries = attribution
                .as_ref()
                .and_then(|attribution| bibliography.lists.get(attribution.list))
                .map(|list| list.entries.as_slice())
                .unwrap_or(&[]);

            let mut resolved_labels = Vec::new();
            let mut missing_labels = Vec::new();
            for label in &citation.labels {
                if resolve_reference(std::slice::from_ref(label), entries).is_some() {
                    resolved_labels.push(label.clone());
                } else {
                    missing_labels.push(MissingLabel {
                        label: label.clone(),
                        reason: missing_reason(bibliography, attribution.as_ref(), label),
                    });
                }
            }

            let status = if missing_labels.is_empty() {
                SpanStatus::Resolved
            } else if resolved_labels.is_empty() {
                SpanStatus::Unresolved
            } else {
                SpanStatus::Partial
            };

            report.detected += 1;
            report.labels.attempted += citation.labels.len();
            report.labels.resolved += resolved_labels.len();
            match status {
                SpanStatus::Resolved => {
                    report.resolved += 1;
                    report.fully_resolved += 1;
                }
                SpanStatus::Partial => {
                    report.resolved += 1;
                    report.partial += 1;
                }
                SpanStatus::Unresolved => report.unresolved += 1,
            }

            report.spans.push(Span {
                page: page + 1,
                text: citation.text,
                labels: citation.labels,
                status,
                resolved_labels,
                missing_labels,
            });
        }
    }

    debug_assert_eq!(
        report.resolved,
        report.fully_resolved + report.partial,
        "resolved counts every span with at least one hit"
    );
    debug_assert_eq!(
        report.detected,
        report.resolved + report.unresolved,
        "every detected span is resolved or not"
    );
    report
}

/// Why one label of a detected span did not reach an entry.
///
/// The attributed list is the app's decision for this page; the reason names the next question a
/// reader would ask. The four cases are deliberately distinct: "there is no bibliography" is a
/// document-level indexing failure, "no list prints the label" is a bibliography-completeness
/// question, and "the list prints it twice" is an ambiguity the resolver refuses to hide.
fn missing_reason(
    bibliography: &Bibliography,
    attribution: Option<&CitationAttribution>,
    label: &str,
) -> MissReason {
    if bibliography
        .lists
        .iter()
        .all(|list| list.entries.is_empty())
    {
        return MissReason::NoBibliography;
    }
    let Some(attribution) = attribution else {
        return MissReason::NoBibliography;
    };
    let Some(list) = bibliography.lists.get(attribution.list) else {
        return MissReason::NoBibliography;
    };
    let matches = exact_matches(&list.entries, label);
    if matches > 1 {
        return MissReason::LabelAmbiguous;
    }
    if matches == 0
        && bibliography.lists.iter().enumerate().any(|(index, other)| {
            index != attribution.list && exact_matches(&other.entries, label) > 0
        })
    {
        return MissReason::ListNotFound;
    }
    // A unique exact match resolves by construction; reaching here means no list printed the
    // label at all.
    MissReason::LabelAbsent
}

fn exact_matches(entries: &[ReferenceEntry], label: &str) -> usize {
    entries
        .iter()
        .filter(|entry| entry.label.eq_ignore_ascii_case(label))
        .count()
}

fn measure_captions(
    backend: &PdfiumBackend,
    pages: &[(u32, RawTextPage)],
    path: &Path,
) -> Result<(CaptionReport, TableReport), String> {
    let mut captions = CaptionReport {
        detected: 0,
        multi_line: 0,
        closing: 0,
        open: Vec::new(),
    };
    let mut tables = TableReport {
        detected: 0,
        grid_regions: 0,
        fallbacks: 0,
        fallback_reasons: BTreeMap::new(),
        regions: Vec::new(),
    };

    for (page, text) in pages {
        let found: Vec<Caption> = find_captions(text);
        if found.is_empty() {
            continue;
        }
        let mut geometry: Option<(
            Vec<lyra_reader_core::LineSegment>,
            Vec<lyra_reader_text::TextLine>,
        )> = None;

        for caption in &found {
            captions.detected += 1;
            let lines = caption_text_lines(text, caption);
            if lines.len() > 1 {
                captions.multi_line += 1;
            }
            if closes(&caption.text) {
                captions.closing += 1;
            } else {
                captions.open.push(OpenCaption {
                    page: page + 1,
                    kind: caption.kind.clone(),
                    label: caption.label.clone(),
                    last_line: lines.last().cloned().unwrap_or_default(),
                });
            }

            if caption.kind != "Table" {
                continue;
            }
            tables.detected += 1;
            if geometry.is_none() {
                let rules = backend
                    .page_line_segments(PageIndex(*page))
                    .map_err(|error| {
                        format!(
                            "{}: page {} line segments failed: {error}",
                            path.display(),
                            page + 1
                        )
                    })?;
                geometry = Some((rules, lines_from(text)));
            }
            let (rules, lines) = geometry.as_ref().expect("filled above");
            let (outcome, grid) = table_outcome(caption, rules, lines);
            let is_grid = grid.is_some();
            if is_grid {
                tables.grid_regions += 1;
            } else {
                tables.fallbacks += 1;
                *tables
                    .fallback_reasons
                    .entry(outcome.label().to_string())
                    .or_default() += 1;
            }
            tables.regions.push(TableRegion {
                page: page + 1,
                label: caption.label.clone(),
                outcome: outcome.label().to_string(),
                grid: is_grid,
            });
        }
    }

    debug_assert_eq!(captions.detected, captions.closing + captions.open.len());
    debug_assert_eq!(tables.detected, tables.grid_regions + tables.fallbacks);
    Ok((captions, tables))
}

/// The extraction lines a caption's character range covers, whitespace-collapsed and without
/// empty separators. A subtitle or a superscript that PDFium reports as its own line is one of
/// these, which is why this is the same notion of "multi-line" the completeness check uses.
fn caption_text_lines(text: &RawTextPage, caption: &Caption) -> Vec<String> {
    let chars: Vec<char> = text
        .chars
        .iter()
        .map(|character| char::from_u32(character.unicode).unwrap_or('\u{fffd}'))
        .collect();
    let start = caption.start.min(chars.len());
    let end = caption.end.min(chars.len());
    let mut lines = Vec::new();
    let mut line_start = start;
    for index in start..=end {
        let at_break = index == end || chars[index] == '\n';
        if !at_break {
            continue;
        }
        let visible: Vec<&lyra_reader_core::RawCharBox> = text.chars[line_start..index]
            .iter()
            .filter(|character| {
                char::from_u32(character.unicode)
                    .map(|character| !character.is_whitespace())
                    .unwrap_or(false)
            })
            .collect();
        if !visible.is_empty() {
            // The crate's caption run steps over a line from the other column rather than
            // ending the caption there. Reproduce that horizontal test so a two-column page
            // does not inflate `multi_line` with the neighbour's line.
            let x0 = visible
                .iter()
                .map(|character| character.rect.origin.x)
                .fold(f64::MAX, f64::min);
            let x1 = visible
                .iter()
                .map(|character| character.rect.max_x())
                .fold(f64::MIN, f64::max);
            let overlap = x1.min(caption.rect.max_x()) - x0.max(caption.rect.origin.x);
            let narrower = (x1 - x0).min(caption.rect.size.width);
            if caption.rect.size.width <= 0.0
                || (narrower > 0.0 && overlap > 0.0 && overlap >= 0.5 * narrower)
            {
                let compact = chars[line_start..index]
                    .iter()
                    .collect::<String>()
                    .split_whitespace()
                    .collect::<Vec<_>>()
                    .join(" ");
                if !compact.is_empty() {
                    lines.push(compact);
                }
            }
        }
        line_start = index + 1;
    }
    lines
}
/// The completeness check `caption_corpus.rs` applies: a caption should end a sentence, or at
/// least a clause.
fn closes(text: &str) -> bool {
    text.trim_end()
        .ends_with(['.', ':', '?', '!', ')', ']', '\u{201d}', ',', ';'])
}

// ---------------------------------------------------------------------------
// Baseline and comparison
// ---------------------------------------------------------------------------

fn write_baseline(path: &Path, report: &Report) -> Result<(), String> {
    let json = serde_json::to_string_pretty(report)
        .map_err(|error| format!("cannot encode report: {error}"))?;
    if let Some(parent) = path.parent()
        && !parent.as_os_str().is_empty()
    {
        std::fs::create_dir_all(parent)
            .map_err(|error| format!("cannot create {}: {error}", parent.display()))?;
    }
    std::fs::write(path, format!("{json}\n"))
        .map_err(|error| format!("cannot write {}: {error}", path.display()))
}

fn read_baseline(path: &Path) -> Result<Report, String> {
    let text = std::fs::read_to_string(path)
        .map_err(|error| format!("cannot read {}: {error}", path.display()))?;
    let report: Report = serde_json::from_str(&text).map_err(|error| {
        format!(
            "{} is not a {REPORT_FORMAT} version {REPORT_VERSION} baseline: {error}",
            path.display()
        )
    })?;
    if report.format != REPORT_FORMAT {
        return Err(format!(
            "{} has format {:?}, expected {REPORT_FORMAT:?}",
            path.display(),
            report.format
        ));
    }
    if report.version != REPORT_VERSION {
        return Err(format!(
            "{} is baseline version {}, this binary writes version {REPORT_VERSION}; \
             re-record it with --save-baseline",
            path.display(),
            report.version
        ));
    }
    let totals = recompute_totals(&report.documents);
    if totals != report.totals {
        return Err(format!(
            "{} is inconsistent: its totals do not match its documents",
            path.display()
        ));
    }
    Ok(report)
}

#[derive(Debug, Default)]
struct Diff {
    lines: Vec<String>,
    changes: usize,
}

impl Diff {
    fn changed(&mut self, line: impl Into<String>) {
        self.changes += 1;
        self.lines.push(line.into());
    }

    /// One document or aggregate group: the header is context, not another change, so the count
    /// is the number of field and span changes underneath it.
    fn changed_block(&mut self, header: impl Into<String>, changes: Vec<String>) {
        self.changes += changes.len();
        self.lines.push(header.into());
        self.lines
            .extend(changes.into_iter().map(|change| format!("    {change}")));
    }
}

fn compare_reports(baseline: &Report, current: &Report) -> Result<Diff, String> {
    if baseline.citation_window != current.citation_window {
        return Err(format!(
            "baseline citation window is {}, this run's is {}; re-run with --body-pages {} \
             or record a new baseline",
            baseline.citation_window, current.citation_window, baseline.citation_window
        ));
    }

    let mut diff = Diff::default();

    let baseline_corpora: BTreeMap<&str, &CorpusReport> = baseline
        .corpora
        .iter()
        .map(|corpus| (corpus.id.as_str(), corpus))
        .collect();
    let current_corpora: BTreeMap<&str, &CorpusReport> = current
        .corpora
        .iter()
        .map(|corpus| (corpus.id.as_str(), corpus))
        .collect();
    for id in baseline_corpora.keys() {
        if !current_corpora.contains_key(id) {
            diff.changed(format!("corpus removed: {id}"));
        }
    }
    for id in current_corpora.keys() {
        if !baseline_corpora.contains_key(id) {
            diff.changed(format!("corpus added: {id}"));
        }
    }

    let baseline_docs: BTreeMap<&str, &DocumentReport> = baseline
        .documents
        .iter()
        .map(|document| (document.id.as_str(), document))
        .collect();
    let current_docs: BTreeMap<&str, &DocumentReport> = current
        .documents
        .iter()
        .map(|document| (document.id.as_str(), document))
        .collect();
    let mut ids: Vec<&str> = baseline_docs
        .keys()
        .chain(current_docs.keys())
        .copied()
        .collect();
    ids.sort_unstable();
    ids.dedup();

    for id in ids {
        match (baseline_docs.get(id), current_docs.get(id)) {
            (None, Some(_)) => diff.changed(format!("document added: {id}")),
            (Some(_), None) => diff.changed(format!("document removed: {id}")),
            (Some(old), Some(new)) => {
                let mut lines = Vec::new();
                compare_document(old, new, &mut lines);
                if !lines.is_empty() {
                    diff.changed_block(format!("document {id}:"), lines);
                }
            }
            (None, None) => {}
        }
    }

    let mut aggregate = Vec::new();
    compare_totals(&baseline.totals, &current.totals, &mut aggregate);
    if !aggregate.is_empty() {
        diff.changed_block("aggregate:", aggregate);
    }

    Ok(diff)
}

fn compare_document(old: &DocumentReport, new: &DocumentReport, lines: &mut Vec<String>) {
    if old.pages != new.pages {
        lines.push(format!("pages {} → {}", old.pages, new.pages));
    }
    let oc = &old.citations;
    let nc = &new.citations;
    count_change(lines, "citations detected", oc.detected, nc.detected);
    count_change(lines, "citations resolved", oc.resolved, nc.resolved);
    count_change(
        lines,
        "citations fully resolved",
        oc.fully_resolved,
        nc.fully_resolved,
    );
    count_change(lines, "citations partial", oc.partial, nc.partial);
    count_change(lines, "citations unresolved", oc.unresolved, nc.unresolved);
    count_change(
        lines,
        "labels attempted",
        oc.labels.attempted,
        nc.labels.attempted,
    );
    count_change(
        lines,
        "labels resolved",
        oc.labels.resolved,
        nc.labels.resolved,
    );
    count_change(
        lines,
        "bibliography entries",
        oc.bibliography.entries,
        nc.bibliography.entries,
    );
    count_change(
        lines,
        "reference lists",
        oc.bibliography.lists,
        nc.bibliography.lists,
    );
    option_change(
        lines,
        "bibliography first page",
        oc.bibliography.first_page,
        nc.bibliography.first_page,
    );

    compare_spans(&oc.spans, &nc.spans, lines);

    count_change(
        lines,
        "captions detected",
        old.captions.detected,
        new.captions.detected,
    );
    count_change(
        lines,
        "captions multi-line",
        old.captions.multi_line,
        new.captions.multi_line,
    );
    count_change(
        lines,
        "captions closing",
        old.captions.closing,
        new.captions.closing,
    );
    compare_open_captions(&old.captions.open, &new.captions.open, lines);

    count_change(
        lines,
        "table captions",
        old.tables.detected,
        new.tables.detected,
    );
    count_change(
        lines,
        "table grid regions",
        old.tables.grid_regions,
        new.tables.grid_regions,
    );
    count_change(
        lines,
        "table fallbacks",
        old.tables.fallbacks,
        new.tables.fallbacks,
    );
    compare_table_regions(&old.tables.regions, &new.tables.regions, lines);
}

fn count_change(lines: &mut Vec<String>, name: &str, old: usize, new: usize) {
    if old != new {
        lines.push(format!("{name}: {old} → {new}"));
    }
}

fn option_change<T: PartialEq + std::fmt::Display>(
    lines: &mut Vec<String>,
    name: &str,
    old: Option<T>,
    new: Option<T>,
) {
    if old != new {
        let show = |value: Option<T>| {
            value
                .map(|value| value.to_string())
                .unwrap_or_else(|| "none".to_string())
        };
        lines.push(format!("{name}: {} → {}", show(old), show(new)));
    }
}

fn keyed_spans(spans: &[Span]) -> BTreeMap<String, &Span> {
    let mut occurrences: BTreeMap<String, usize> = BTreeMap::new();
    let mut keyed = BTreeMap::new();
    for span in spans {
        let base = format!("p{}|{}|{}", span.page, span.labels.join(","), span.text);
        let occurrence = occurrences.entry(base.clone()).or_default();
        *occurrence += 1;
        let key = if *occurrence == 1 {
            base
        } else {
            format!("{base}#{occurrence}")
        };
        keyed.insert(key, span);
    }
    keyed
}

fn compare_spans(old: &[Span], new: &[Span], lines: &mut Vec<String>) {
    let old = keyed_spans(old);
    let new = keyed_spans(new);
    let mut keys: Vec<&String> = old.keys().chain(new.keys()).collect();
    keys.sort_unstable();
    keys.dedup();
    for key in keys {
        match (old.get(key), new.get(key)) {
            (Some(before), None) => lines.push(format!(
                "span no longer detected: p{} {:?} labels {:?}",
                before.page, before.text, before.labels
            )),
            (None, Some(after)) => lines.push(format!(
                "span newly detected: p{} {:?} labels {:?}",
                after.page, after.text, after.labels
            )),
            (Some(before), Some(after)) => {
                if before.status != after.status {
                    lines.push(format!(
                        "span p{} {:?}: {} → {}{}",
                        before.page,
                        before.text,
                        before.status.label(),
                        after.status.label(),
                        reasons_note(after)
                    ));
                } else if before.resolved_labels != after.resolved_labels {
                    lines.push(format!(
                        "span p{} {:?}: resolved labels {:?} → {:?}",
                        before.page, before.text, before.resolved_labels, after.resolved_labels
                    ));
                }
                let before_reasons = missing_reasons(before);
                let after_reasons = missing_reasons(after);
                let mut labels: Vec<&String> =
                    before_reasons.keys().chain(after_reasons.keys()).collect();
                labels.sort_unstable();
                labels.dedup();
                for label in labels {
                    let old_reason = before_reasons.get(label);
                    let new_reason = after_reasons.get(label);
                    if old_reason != new_reason
                        && (old_reason.is_some() || new_reason.is_some())
                        && before.status == after.status
                    {
                        lines.push(format!(
                            "span p{} {:?}: label {label:?} {} → {}",
                            before.page,
                            before.text,
                            old_reason
                                .map(|reason| reason.label())
                                .unwrap_or("resolved"),
                            new_reason
                                .map(|reason| reason.label())
                                .unwrap_or("resolved"),
                        ));
                    }
                }
            }
            (None, None) => {}
        }
    }
}

fn missing_reasons(span: &Span) -> BTreeMap<String, MissReason> {
    span.missing_labels
        .iter()
        .map(|missing| (missing.label.clone(), missing.reason))
        .collect()
}

fn reasons_note(after: &Span) -> String {
    let mut reasons: Vec<&str> = after
        .missing_labels
        .iter()
        .map(|missing| missing.reason.label())
        .collect();
    reasons.sort_unstable();
    reasons.dedup();
    if reasons.is_empty() {
        String::new()
    } else {
        format!(" ({})", reasons.join(", "))
    }
}

fn compare_open_captions(old: &[OpenCaption], new: &[OpenCaption], lines: &mut Vec<String>) {
    let key = |caption: &OpenCaption| (caption.page, caption.kind.clone(), caption.label.clone());
    let old: BTreeMap<_, _> = old.iter().map(|caption| (key(caption), caption)).collect();
    let new: BTreeMap<_, _> = new.iter().map(|caption| (key(caption), caption)).collect();
    let mut keys: Vec<(&u32, &String, &String)> = old
        .keys()
        .map(|(page, kind, label)| (page, kind, label))
        .chain(new.keys().map(|(page, kind, label)| (page, kind, label)))
        .collect();
    keys.sort_unstable();
    keys.dedup();
    for (page, kind, label) in keys {
        let key = (*page, kind.clone(), label.clone());
        match (old.get(&key), new.get(&key)) {
            (None, Some(after)) => lines.push(format!(
                "caption p{page} {kind} {label} no longer closes: {:?}",
                after.last_line
            )),
            (Some(before), None) => lines.push(format!(
                "caption p{page} {kind} {label} now closes (was {:?})",
                before.last_line
            )),
            (Some(before), Some(after)) if before.last_line != after.last_line => {
                lines.push(format!(
                    "caption p{page} {kind} {label} last line changed: {:?} → {:?}",
                    before.last_line, after.last_line
                ))
            }
            _ => {}
        }
    }
}

fn compare_table_regions(old: &[TableRegion], new: &[TableRegion], lines: &mut Vec<String>) {
    let key = |region: &TableRegion| (region.page, region.label.clone());
    let old: BTreeMap<_, _> = old.iter().map(|region| (key(region), region)).collect();
    let new: BTreeMap<_, _> = new.iter().map(|region| (key(region), region)).collect();
    let mut keys: Vec<(&u32, &String)> = old
        .keys()
        .map(|(page, label)| (page, label))
        .chain(new.keys().map(|(page, label)| (page, label)))
        .collect();
    keys.sort_unstable();
    keys.dedup();
    for (page, label) in keys {
        let key = (*page, label.clone());
        match (old.get(&key), new.get(&key)) {
            (Some(before), Some(after)) if before.grid != after.grid => lines.push(format!(
                "table p{page} Table {label}: {} → {} ({})",
                if before.grid { "grid" } else { "fallback" },
                if after.grid { "grid" } else { "fallback" },
                after.outcome
            )),
            (Some(before), Some(after)) if before.outcome != after.outcome => lines.push(format!(
                "table p{page} Table {label}: outcome {} → {}",
                before.outcome, after.outcome
            )),
            (None, Some(after)) => lines.push(format!(
                "table p{page} Table {label}: newly detected ({})",
                after.outcome
            )),
            (Some(before), None) => lines.push(format!(
                "table p{page} Table {label}: no longer detected ({})",
                before.outcome
            )),
            _ => {}
        }
    }
}

fn compare_totals(old: &Totals, new: &Totals, lines: &mut Vec<String>) {
    count_change(lines, "documents", old.documents, new.documents);
    count_change(
        lines,
        "citations detected",
        old.citations.detected,
        new.citations.detected,
    );
    count_change(
        lines,
        "citations resolved",
        old.citations.resolved,
        new.citations.resolved,
    );
    count_change(
        lines,
        "citations unresolved",
        old.citations.unresolved,
        new.citations.unresolved,
    );
    count_change(
        lines,
        "labels resolved",
        old.citations.labels_resolved,
        new.citations.labels_resolved,
    );
    count_change(
        lines,
        "captions detected",
        old.captions.detected,
        new.captions.detected,
    );
    count_change(
        lines,
        "captions closing",
        old.captions.closing,
        new.captions.closing,
    );
    count_change(
        lines,
        "table captions",
        old.tables.detected,
        new.tables.detected,
    );
    count_change(
        lines,
        "table grid regions",
        old.tables.grid_regions,
        new.tables.grid_regions,
    );
    reason_changes(
        lines,
        "missing reason",
        &old.citations.missing_reasons,
        &new.citations.missing_reasons,
    );
    reason_changes(
        lines,
        "table fallback",
        &old.tables.fallback_reasons,
        &new.tables.fallback_reasons,
    );
}

fn reason_changes(
    lines: &mut Vec<String>,
    name: &str,
    old: &BTreeMap<String, usize>,
    new: &BTreeMap<String, usize>,
) {
    let mut keys: Vec<&String> = old.keys().chain(new.keys()).collect();
    keys.sort_unstable();
    keys.dedup();
    for key in keys {
        let before = old.get(key).copied().unwrap_or(0);
        let after = new.get(key).copied().unwrap_or(0);
        if before != after {
            lines.push(format!("{name} {key}: {before} → {after}"));
        }
    }
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

pub fn run(args: &[String]) -> ExitCode {
    match evaluate(args) {
        Ok(code) => code,
        Err(error) => {
            eprintln!("eval: {error}");
            ExitCode::from(2)
        }
    }
}

fn evaluate(args: &[String]) -> Result<ExitCode, String> {
    let (positional, options) = crate::parse(args);
    if options
        .iter()
        .any(|(key, _)| key == "-h" || key == "--help")
    {
        print_usage();
        return Ok(ExitCode::SUCCESS);
    }
    if !positional.is_empty() {
        return Err(format!(
            "eval takes no file arguments (got {:?}); the corpora come from \
             LYRA_READER_PDF_SAMPLES and LYRA_READER_EVAL_PAPERS",
            positional
        ));
    }
    for (key, _) in &options {
        if !matches!(
            key.as_str(),
            "--body-pages" | "--save-baseline" | "--compare"
        ) {
            return Err(format!("unknown option {key:?}"));
        }
    }

    let citation_window = match crate::opt(&options, &["--body-pages"]) {
        Some(value) => value
            .parse::<usize>()
            .map_err(|_| format!("--body-pages expects a number, got {value:?}"))?,
        None => DEFAULT_CITATION_WINDOW,
    };
    let save = crate::opt(&options, &["--save-baseline"]);
    let compare = crate::opt(&options, &["--compare"]);
    if save.is_some_and(str::is_empty) {
        return Err("--save-baseline needs a file path".to_string());
    }
    if compare.is_some_and(str::is_empty) {
        return Err("--compare needs a file path".to_string());
    }

    let corpora = discover_corpora()?;
    let mut documents = Vec::new();
    for corpus in &corpora {
        for path in &corpus.files {
            documents.push(measure_document(corpus.id, path, citation_window)?);
        }
    }

    let report = Report {
        format: REPORT_FORMAT.to_string(),
        version: REPORT_VERSION,
        citation_window,
        corpora: corpora
            .iter()
            .map(|corpus| CorpusReport {
                id: corpus.id.to_string(),
                env: corpus.env.to_string(),
                documents: corpus.files.len(),
            })
            .collect(),
        totals: recompute_totals(&documents),
        documents,
    };

    print_report(&report, &corpora);
    if let Some(path) = save {
        write_baseline(Path::new(path), &report)?;
        println!("\nbaseline written: {path}");
    }
    if let Some(path) = compare {
        let baseline = read_baseline(Path::new(path))?;
        let diff = compare_reports(&baseline, &report)?;
        print_diff(Path::new(path), &diff);
        if diff.changes > 0 {
            return Ok(ExitCode::from(1));
        }
    }
    Ok(ExitCode::SUCCESS)
}

fn print_usage() {
    println!(
        "\
lyra-reader-cli eval — index-quality report over the local PDF corpora

Usage:
  lyra-reader-cli eval [--body-pages N] [--save-baseline FILE] [--compare FILE]

Corpus (at least one; PDFs are never committed):
  LYRA_READER_PDF_SAMPLES   the twelve regression sample papers
  LYRA_READER_EVAL_PAPERS   the twenty evaluation papers

Options:
  --body-pages N       citation pages per document (default 3, the regression contract's
                       sample; 0 = every page before the document-wide bibliography)
  --save-baseline FILE write the report as versioned JSON
  --compare FILE       compare this run against a saved baseline; prints document and
                       span changes and exits 1 when anything differs

The report separates detected citations from resolved ones: a detected span that did not
resolve is a resolution failure, while a citation the detector never found is not counted
at all. See the module docs for the JSON format and the failure reasons."
    );
}

fn print_report(report: &Report, corpora: &[CorpusFiles]) {
    println!(
        "Index quality report (format {}, version {})",
        report.format, report.version
    );
    let window = if report.citation_window == 0 {
        "every page before the bibliography".to_string()
    } else if report.citation_window == 1 {
        "first page".to_string()
    } else {
        format!("first {} pages", report.citation_window)
    };
    println!("citation window: {window}");
    for (corpus, files) in report.corpora.iter().zip(corpora) {
        println!(
            "  {}: {} document(s) from {} ({})",
            corpus.id,
            corpus.documents,
            corpus.env,
            files.dir.display()
        );
    }
    println!();

    for corpus in &report.corpora {
        println!("{}", corpus.id);
        for document in report
            .documents
            .iter()
            .filter(|document| document.corpus == corpus.id)
        {
            print_document(document);
        }
        let documents: Vec<&DocumentReport> = report
            .documents
            .iter()
            .filter(|document| document.corpus == corpus.id)
            .collect();
        print_subtotal(corpus.id.as_str(), &documents);
        println!();
    }

    println!("aggregate — {} document(s)", report.totals.documents);
    print_totals(&report.totals);
    println!();
    println!(
        "Detected counts are what the indexer found. A detected span is resolved when at least\n\
         one of its labels reaches an entry; the ratio is resolution of detected spans, not\n\
         recall of citations. A citation the detector never found is not counted as a failure.\n\
         --compare lists spans that appeared or disappeared, so a detection gain that cost\n\
         resolution is visible; it cannot say whether a newly detected span is a true citation."
    );

    let unresolved: Vec<&DocumentReport> = report
        .documents
        .iter()
        .filter(|document| {
            document
                .citations
                .spans
                .iter()
                .any(|span| span.status == SpanStatus::Unresolved)
        })
        .collect();
    println!();
    println!(
        "Unresolved citation spans ({})",
        count_spans(&unresolved, SpanStatus::Unresolved)
    );
    for document in &unresolved {
        for span in document
            .citations
            .spans
            .iter()
            .filter(|span| span.status == SpanStatus::Unresolved)
        {
            print_span(document, span);
        }
    }

    let partial: Vec<&DocumentReport> = report
        .documents
        .iter()
        .filter(|document| {
            document
                .citations
                .spans
                .iter()
                .any(|span| span.status == SpanStatus::Partial)
        })
        .collect();
    println!();
    println!(
        "Incomplete citation spans ({}) — some labels resolved, some did not",
        count_spans(&partial, SpanStatus::Partial)
    );
    for document in &partial {
        for span in document
            .citations
            .spans
            .iter()
            .filter(|span| span.status == SpanStatus::Partial)
        {
            print_span(document, span);
        }
    }

    println!();
    println!(
        "Captions that do not close ({})",
        report
            .documents
            .iter()
            .map(|document| document.captions.open.len())
            .sum::<usize>()
    );
    for document in &report.documents {
        for caption in &document.captions.open {
            println!(
                "  {} p{} {} {} — last line: {:?}",
                document.id,
                caption.page,
                caption.kind,
                caption.label,
                truncate(&caption.last_line, 120)
            );
        }
    }

    if !report.totals.tables.fallback_reasons.is_empty() {
        println!();
        println!(
            "Table fallback reasons: {}",
            report
                .totals
                .tables
                .fallback_reasons
                .iter()
                .map(|(reason, count)| format!("{reason} {count}"))
                .collect::<Vec<_>>()
                .join(", ")
        );
    }
}

fn print_document(document: &DocumentReport) {
    println!("  {} ({} page(s))", document.id, document.pages);
    if document.citations.bibliography.entries == 0 {
        println!("      bibliography: none");
    } else {
        let first = document
            .citations
            .bibliography
            .first_page
            .map(|page| format!("p{page}"))
            .unwrap_or_else(|| "p?".to_string());
        println!(
            "      bibliography: {} entries, {} list(s), first at {}",
            document.citations.bibliography.entries, document.citations.bibliography.lists, first
        );
    }
    println!(
        "      citations  {} detected → {} resolved ({} partial, {} unresolved)",
        document.citations.detected,
        document.citations.resolved,
        document.citations.partial,
        document.citations.unresolved
    );
    println!(
        "      captions   {} detected, {} multi-line, {} closing, {} open",
        document.captions.detected,
        document.captions.multi_line,
        document.captions.closing,
        document.captions.open.len()
    );
    println!(
        "      tables     {} captions, {} grid regions, {} fallback",
        document.tables.detected, document.tables.grid_regions, document.tables.fallbacks
    );
}

fn print_subtotal(label: &str, documents: &[&DocumentReport]) {
    let totals = recompute_totals(documents.iter().copied());
    println!("  {label} subtotal ({} document(s))", totals.documents);
    println!(
        "      citations  {}/{} resolved ({}) — {} unresolved, {} partial",
        totals.citations.resolved,
        totals.citations.detected,
        percentage(totals.citations.resolved, totals.citations.detected),
        totals.citations.unresolved,
        totals.citations.partial
    );
    println!(
        "      captions   {} detected, {} multi-line, {} closing, {} open",
        totals.captions.detected,
        totals.captions.multi_line,
        totals.captions.closing,
        totals.captions.detected - totals.captions.closing
    );
    println!(
        "      tables     {} captions, {} grid regions, {} fallback",
        totals.tables.detected, totals.tables.grid_regions, totals.tables.fallbacks
    );
}

fn print_totals(totals: &Totals) {
    println!(
        "  citations: {}/{} resolved ({}), {} fully resolved, {} partial, {} unresolved",
        totals.citations.resolved,
        totals.citations.detected,
        percentage(totals.citations.resolved, totals.citations.detected),
        totals.citations.fully_resolved,
        totals.citations.partial,
        totals.citations.unresolved
    );
    println!(
        "      labels: {}/{} resolved; bibliography: {} document(s) with, {} without, {} entries",
        totals.citations.labels_resolved,
        totals.citations.labels_attempted,
        totals.citations.documents_with_bibliography,
        totals.citations.documents_without_bibliography,
        totals.citations.bibliography_entries
    );
    if !totals.citations.missing_reasons.is_empty() {
        println!(
            "      unresolved labels by reason: {}",
            totals
                .citations
                .missing_reasons
                .iter()
                .map(|(reason, count)| format!("{reason} {count}"))
                .collect::<Vec<_>>()
                .join(", ")
        );
    }
    println!(
        "  captions: {} detected, {} multi-line ({}), {} closing ({}), {} open",
        totals.captions.detected,
        totals.captions.multi_line,
        percentage(totals.captions.multi_line, totals.captions.detected),
        totals.captions.closing,
        percentage(totals.captions.closing, totals.captions.detected),
        totals.captions.detected - totals.captions.closing
    );
    println!(
        "  tables: {} captions, {} grid regions ({}), {} fallback",
        totals.tables.detected,
        totals.tables.grid_regions,
        percentage(totals.tables.grid_regions, totals.tables.detected),
        totals.tables.fallbacks
    );
}

fn count_spans(documents: &[&DocumentReport], status: SpanStatus) -> usize {
    documents
        .iter()
        .flat_map(|document| &document.citations.spans)
        .filter(|span| span.status == status)
        .count()
}

fn print_span(document: &DocumentReport, span: &Span) {
    println!(
        "  {} p{} {:?} labels {:?}",
        document.id, span.page, span.text, span.labels
    );
    for missing in &span.missing_labels {
        println!("      - {}: {}", missing.label, missing.reason.label());
    }
}

fn print_diff(path: &Path, diff: &Diff) {
    println!();
    println!(
        "Baseline: {} (format {REPORT_FORMAT}, version {REPORT_VERSION})",
        path.display()
    );
    if diff.changes == 0 {
        println!("No differences: this run matches the baseline.");
        return;
    }
    println!("Differences: {}", diff.changes);
    for line in &diff.lines {
        println!("  {line}");
    }
}

fn percentage(part: usize, whole: usize) -> String {
    if whole == 0 {
        "n/a".to_string()
    } else {
        format!("{:.1}%", part as f64 * 100.0 / whole as f64)
    }
}

fn truncate(text: &str, limit: usize) -> String {
    if text.chars().count() <= limit {
        text.to_string()
    } else {
        let mut short: String = text.chars().take(limit.saturating_sub(1)).collect();
        short.push('…');
        short
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn span(page: u32, text: &str, labels: &[&str], resolved: bool) -> Span {
        let labels: Vec<String> = labels.iter().map(|label| (*label).to_string()).collect();
        let (status, resolved_labels, missing_labels) = if resolved {
            (SpanStatus::Resolved, labels.clone(), Vec::new())
        } else {
            (
                SpanStatus::Unresolved,
                Vec::new(),
                labels
                    .iter()
                    .map(|label| MissingLabel {
                        label: label.clone(),
                        reason: MissReason::LabelAbsent,
                    })
                    .collect(),
            )
        };
        Span {
            page,
            text: text.to_string(),
            labels,
            status,
            resolved_labels,
            missing_labels,
        }
    }

    fn document(id: &str, spans: Vec<Span>) -> DocumentReport {
        let detected = spans.len();
        let resolved = spans
            .iter()
            .filter(|span| span.status != SpanStatus::Unresolved)
            .count();
        let fully_resolved = spans
            .iter()
            .filter(|span| span.status == SpanStatus::Resolved)
            .count();
        let partial = spans
            .iter()
            .filter(|span| span.status == SpanStatus::Partial)
            .count();
        let labels_attempted = spans.iter().map(|span| span.labels.len()).sum();
        let labels_resolved = spans.iter().map(|span| span.resolved_labels.len()).sum();
        DocumentReport {
            id: id.to_string(),
            corpus: "pdf-samples".to_string(),
            file: id.rsplit('/').next().unwrap_or(id).to_string(),
            pages: 1,
            citations: CitationReport {
                detected,
                resolved,
                fully_resolved,
                partial,
                unresolved: detected - resolved,
                labels: LabelReport {
                    attempted: labels_attempted,
                    resolved: labels_resolved,
                },
                bibliography: BibliographyReport {
                    entries: 1,
                    lists: 1,
                    first_page: Some(2),
                },
                spans,
            },
            captions: CaptionReport {
                detected: 0,
                multi_line: 0,
                closing: 0,
                open: Vec::new(),
            },
            tables: TableReport {
                detected: 0,
                grid_regions: 0,
                fallbacks: 0,
                fallback_reasons: BTreeMap::new(),
                regions: Vec::new(),
            },
        }
    }

    fn report(documents: Vec<DocumentReport>) -> Report {
        let totals = recompute_totals(&documents);
        Report {
            format: REPORT_FORMAT.to_string(),
            version: REPORT_VERSION,
            citation_window: 3,
            corpora: vec![CorpusReport {
                id: "pdf-samples".to_string(),
                env: "LYRA_READER_PDF_SAMPLES".to_string(),
                documents: documents.len(),
            }],
            totals,
            documents,
        }
    }

    #[test]
    fn report_round_trips_through_json() {
        let report = report(vec![document(
            "pdf-samples/one.pdf",
            vec![span(1, "[1]", &["1"], true)],
        )]);
        let json = serde_json::to_string_pretty(&report).unwrap();
        assert!(json.contains("\"format\": \"lyra-reader-index-quality\""));
        assert!(json.contains("\"version\": 1"));
        let parsed: Report = serde_json::from_str(&json).unwrap();
        assert_eq!(report, parsed);
    }

    #[test]
    fn comparison_reports_a_span_that_stopped_resolving() {
        let baseline = report(vec![document(
            "pdf-samples/one.pdf",
            vec![span(4, "[1, 2]", &["1", "2"], true)],
        )]);
        let current = report(vec![document(
            "pdf-samples/one.pdf",
            vec![span(4, "[1, 2]", &["1", "2"], false)],
        )]);
        let diff = compare_reports(&baseline, &current).unwrap();
        assert!(diff.changes > 0);
        let text = diff.lines.join("\n");
        assert!(text.contains("resolved → unresolved"), "{text}");
        assert!(text.contains("label absent"), "{text}");
    }

    #[test]
    fn comparison_of_a_report_with_itself_is_empty() {
        let report = report(vec![document(
            "pdf-samples/one.pdf",
            vec![span(1, "[1]", &["1"], true)],
        )]);
        let diff = compare_reports(&report, &report).unwrap();
        assert_eq!(diff.changes, 0, "{:?}", diff.lines);
    }

    #[test]
    fn comparison_reports_added_and_removed_documents() {
        let baseline = report(vec![document(
            "pdf-samples/one.pdf",
            vec![span(1, "[1]", &["1"], true)],
        )]);
        let current = report(vec![
            document("pdf-samples/one.pdf", vec![span(1, "[1]", &["1"], true)]),
            document("pdf-samples/two.pdf", vec![span(1, "[2]", &["2"], true)]),
        ]);
        let diff = compare_reports(&baseline, &current).unwrap();
        let text = diff.lines.join("\n");
        assert!(
            text.contains("document added: pdf-samples/two.pdf"),
            "{text}"
        );
        assert!(diff.changes > 0);
    }

    #[test]
    fn repeated_span_texts_get_distinct_baseline_keys() {
        let spans = vec![span(1, "[1]", &["1"], true), span(1, "[1]", &["1"], false)];
        let keyed = keyed_spans(&spans);
        assert_eq!(keyed.len(), 2);
        assert!(keyed.contains_key("p1|1|[1]"));
        assert!(keyed.contains_key("p1|1|[1]#2"));
    }

    #[test]
    fn completeness_rule_accepts_a_finished_caption_only() {
        assert!(closes("A caption that ends."));
        assert!(closes("A caption that ends;"));
        assert!(!closes("A caption that stops mid"));
    }

    #[test]
    fn failure_reasons_distinguish_the_four_cases() {
        use lyra_reader_text::{AttributionReason, ReferenceList};

        fn entry(label: &str) -> ReferenceEntry {
            ReferenceEntry {
                label: label.to_string(),
                text: format!("{label} entry"),
                page: 0,
                start: 0,
                end: 0,
                fragments: Vec::new(),
            }
        }
        fn list(labels: &[&str]) -> ReferenceList {
            ReferenceList {
                entries: labels.iter().map(|label| entry(label)).collect(),
                numbered: true,
                heading: Some("References".to_string()),
                heading_page: Some(0),
                section: None,
                region_start: None,
            }
        }
        fn bibliography(lists: Vec<ReferenceList>) -> Bibliography {
            Bibliography {
                lists,
                document_wide: 0,
                sections: Vec::new(),
            }
        }
        fn attribution(list: usize) -> CitationAttribution {
            CitationAttribution {
                list,
                reason: AttributionReason::DocumentWide,
                ambiguous: false,
                alternatives: Vec::new(),
                region_list: None,
                label_matches: false,
            }
        }

        let two_lists = bibliography(vec![list(&["1", "2"]), list(&["3"])]);
        assert_eq!(
            missing_reason(&two_lists, Some(&attribution(0)), "3"),
            MissReason::ListNotFound
        );
        assert_eq!(
            missing_reason(&two_lists, Some(&attribution(0)), "9"),
            MissReason::LabelAbsent
        );

        let duplicated = bibliography(vec![list(&["1", "1"])]);
        assert_eq!(
            missing_reason(&duplicated, Some(&attribution(0)), "1"),
            MissReason::LabelAmbiguous
        );

        let empty = bibliography(Vec::new());
        assert_eq!(
            missing_reason(&empty, None, "1"),
            MissReason::NoBibliography
        );
    }

    #[test]
    fn comparison_refuses_a_different_citation_window() {
        let baseline = report(vec![document(
            "pdf-samples/one.pdf",
            vec![span(1, "[1]", &["1"], true)],
        )]);
        let mut current = baseline.clone();
        current.citation_window = 0;
        let error = compare_reports(&baseline, &current).unwrap_err();
        assert!(error.contains("citation window"), "{error}");
    }

    #[test]
    fn reason_names_are_part_of_the_format() {
        let span = Span {
            page: 1,
            text: "[1]".to_string(),
            labels: vec!["1".to_string()],
            status: SpanStatus::Unresolved,
            resolved_labels: Vec::new(),
            missing_labels: vec![
                MissingLabel {
                    label: "1".to_string(),
                    reason: MissReason::NoBibliography,
                },
                MissingLabel {
                    label: "2".to_string(),
                    reason: MissReason::ListNotFound,
                },
                MissingLabel {
                    label: "3".to_string(),
                    reason: MissReason::LabelAbsent,
                },
                MissingLabel {
                    label: "4".to_string(),
                    reason: MissReason::LabelAmbiguous,
                },
            ],
        };
        let json = serde_json::to_string(&span).unwrap();
        for reason in [
            "no_bibliography",
            "list_not_found",
            "label_absent",
            "label_ambiguous",
        ] {
            assert!(json.contains(reason), "{reason} missing from {json}");
        }
    }
}
