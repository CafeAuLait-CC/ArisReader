//! Select a coherent bibliography, independently of citation matching.
//!
//! Keep numeric and author-year candidates separate until the document-level
//! decision. A spurious numeric marker must not suppress an author-year page,
//! and candidates in different styles must not join into a run through the body.
//!
//! A document can carry more than one run of a single numbering: journal papers print the
//! references the main text cites first and a second run after the methods, numbered where the
//! first stopped (T4.20: `1710.05463` prints 1–33 on pages 7–10 and 34–68 on pages 24–27). The
//! score below picks *one* run, which is what the selection used to return. Which run wins is
//! not what a citation needs, so [`select_reference_run`] gives the losing runs a second chance
//! under two conditions a second numbered list in a paper — an appendix, a figure list, a table
//! of contents, numbered equations — does not meet: the run must continue the selected numbering
//! exactly, and the body must cite its labels.
//!
//! A document can also carry two reference lists that number *independently*, and there the score
//! is the wrong instrument: `2303.08774` prints the report's own references (85 entries, pages
//! 18–23) and the system card appendix's own references (105 entries, pages 71–78), each starting
//! at `[1]`, and the longer one wins on every layout measure while being the wrong list for the
//! report's main text. Both are real lists, so [`cited_run`] decides between them on evidence the
//! score does not read: which of them the text that precedes it cites.
//!
//! T4.42 goes one step further: selecting *one* list is still wrong for the citations of the other
//! section. [`find_reference_lists`] returns every list the document announced, and [`attribute`]
//! decides which one a citation belongs to from evidence it can state — the reading-order region a
//! list closes (a chapter's list owns its chapter, an appendix's owns the appendix), the label a
//! list prints, and which list is the document-wide one. A citation is only resolved against an
//! attributed list when the attribution carried some evidence, and an ambiguous choice is reported
//! (see [`CitationAttribution`]) rather than hidden.

use super::*;
use std::collections::BTreeSet;

// ---------------------------------------------------------------------------
// One document, several reference lists
// ---------------------------------------------------------------------------

/// The kind of section a reference list closes.
///
/// Only sections a document marks in its text are reported: an appendix heading, a chapter
/// heading, the title page of an embedded document (the GPT-4 report appends its system card as a
/// document of its own, with the card's title page and the card's references), or a numbered
/// section heading. A list whose section cannot be read from the text carries `None`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum SectionKind {
    Appendix,
    Chapter,
    /// A document part or an embedded document's title page.
    Part,
    /// A numbered or lettered section heading.
    Section,
}

impl SectionKind {
    /// The word a decision message uses for this kind of section.
    pub fn noun(self) -> &'static str {
        match self {
            SectionKind::Appendix => "appendix",
            SectionKind::Chapter => "chapter",
            SectionKind::Part => "part",
            SectionKind::Section => "section",
        }
    }
}

/// Where a section that carries its own reference list begins.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct SectionRef {
    /// The heading as it is printed, whitespace collapsed.
    pub title: String,
    /// Page the heading is on.
    pub page: u32,
    pub kind: SectionKind,
}

/// One reference list found in a document.
///
/// Entries are in reading order, trimmed the same way the document-wide list is (see
/// [`trim_trailing_section`]), and carry fragment geometry. A list is reported when the document
/// printed a reference heading above it, so an unheaded numbered paragraph cannot become one;
/// the document-wide list is reported even when its heading was missed, because the layout score
/// and the body's citations already admit it.
#[derive(Clone, Debug, PartialEq)]
pub struct ReferenceList {
    pub entries: Vec<ReferenceEntry>,
    /// Whether this list is numbered (`[12]`, `12.`), as opposed to author-year or alphanumeric.
    pub numbered: bool,
    /// The heading line that announced the list, when the document printed one.
    pub heading: Option<String>,
    /// Page the heading is on.
    pub heading_page: Option<u32>,
    /// The section this list closes, when the document shows where that section starts.
    pub section: Option<SectionRef>,
    /// First page of the reading-order region this list owns, for a list that is not the
    /// document-wide one. The region runs from here to the list's own first page: the text a
    /// list printed at its end belongs to is the text immediately before it.
    pub region_start: Option<u32>,
}

impl ReferenceList {
    /// First page an entry of the list starts on, if it has entries.
    pub fn first_page(&self) -> Option<u32> {
        self.entries.iter().map(|entry| entry.page).min()
    }

    /// Last page an entry of the list starts on, if it has entries.
    pub fn last_page(&self) -> Option<u32> {
        self.entries.iter().map(|entry| entry.page).max()
    }
}

/// Every reference list a document prints, and which one is its document-wide list.
///
/// The document-wide list is exactly the list [`find_references`](crate::find_references) returns:
/// the layout score's choice, overruled by the body's own citations when two independent
/// bibliographies compete (T4.41), with a second run of one numbering joined in (T4.20). Every
/// other list is one the document announced with a reference heading.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Bibliography {
    /// All lists, in reading order.
    pub lists: Vec<ReferenceList>,
    /// Index of the document-wide list in [`Bibliography::lists`].
    pub document_wide: usize,
    /// Section starts the document prints, in reading order. They are what bounds a list's
    /// region: a chapter's list owns its chapter, not the pages of the previous one.
    pub sections: Vec<SectionRef>,
}

impl Bibliography {
    /// The list a citation with no better evidence is attributed to.
    pub fn document_wide_list(&self) -> Option<&ReferenceList> {
        self.lists.get(self.document_wide)
    }
}

/// The evidence that attributed a citation to one list.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AttributionReason {
    /// The document prints one list; there is nothing to choose.
    OnlyList,
    /// The citation lies in the reading-order region that this list closes, and the list carries
    /// the citation's label. This is the appendix/chapter case: the list belongs to the section
    /// the citation is in.
    SectionList,
    /// Only one list carries the citation's label, so the numbering itself names the list.
    LabelOnly,
    /// No evidence separated the lists, so the document-wide list is used.
    DocumentWide,
    /// No region and no document-wide match, but one other list carries the label; the nearest
    /// such list in reading order is used.
    NearestList,
}

impl AttributionReason {
    /// The sentence the CLI prints for this reason.
    pub fn explanation(self) -> &'static str {
        match self {
            AttributionReason::OnlyList => "the document prints one reference list",
            AttributionReason::SectionList => {
                "the citation lies in the section this list closes, and the list carries its label"
            }
            AttributionReason::LabelOnly => "only this list carries the citation's label",
            AttributionReason::DocumentWide => "the document-wide list is the fallback",
            AttributionReason::NearestList => "this is the nearest list that carries the label",
        }
    }
}

/// The list a citation was attributed to, and why.
#[derive(Clone, Debug, PartialEq)]
pub struct CitationAttribution {
    /// Index into [`Bibliography::lists`].
    pub list: usize,
    pub reason: AttributionReason,
    /// True when another list carries the label and nothing in the document separates the two;
    /// the document-wide list is still used, as the documented rule requires.
    pub ambiguous: bool,
    /// Other lists whose labels include one the citation names.
    pub alternatives: Vec<usize>,
    /// The list that owns the reading-order region the citation sits in, if any. When it differs
    /// from `list`, the section's own list did not carry the citation's label.
    pub region_list: Option<usize>,
    /// Whether the attributed list prints any of the citation's labels exactly.
    pub label_matches: bool,
}

#[derive(Default, Clone)]
struct Run {
    entries: Vec<ReferenceEntry>,
    last_page: Option<u32>,
    headed: bool,
    /// The first reference heading seen inside the run: its page and its printed text.
    heading: Option<(u32, String)>,
}

impl Run {
    fn score(&self) -> f64 {
        if self.entries.len() < 2 {
            return 0.0;
        }
        let dated = self
            .entries
            .iter()
            .filter(|e| first_year(&e.text).is_some())
            .count();
        // Numbered paragraphs alone are not bibliographic evidence. A heading
        // admits short/undated entries, otherwise require publication years.
        if !self.headed && dated * 2 < self.entries.len() {
            return 0.0;
        }
        let ordered = self
            .entries
            .windows(2)
            .filter(
                |pair| match (pair[0].label.parse::<u32>(), pair[1].label.parse::<u32>()) {
                    (Ok(a), Ok(b)) => a.checked_add(1) == Some(b),
                    _ => pair[0].label.to_lowercase() <= pair[1].label.to_lowercase(),
                },
            )
            .count();
        self.entries.len() as f64
            + dated as f64
            + ordered as f64
            + if self.headed { 8.0 } else { 0.0 }
    }
}

/// The incumbent: the run the layout score chose, and where it sits in `candidates`.
///
/// The index is kept because the body's own citations get to overrule the score ([`cited_run`]),
/// and that comparison is between candidates, not between a candidate and a bare `Run`.
#[derive(Default)]
struct Best {
    run: Run,
    numbered: bool,
    index: Option<usize>,
}

impl Best {
    /// Offers `run` to the incumbent; reports whether it won, and clears the loser.
    fn finish(&mut self, run: &mut Run, numbered: bool, index: Option<usize>) -> bool {
        if run.score() > self.run.score() {
            self.run = std::mem::take(run);
            self.numbered = numbered;
            self.index = index;
            true
        } else {
            *run = Run::default();
            false
        }
    }
}

/// One run the walk closed, and whether it was numbered.
struct Candidate {
    run: Run,
    numbered: bool,
}

/// Closes `run`: records it as a candidate and lets it compete for the incumbent.
fn close(run: &mut Run, numbered: bool, best: &mut Best, candidates: &mut Vec<Candidate>) {
    let index = (!run.entries.is_empty()).then(|| {
        candidates.push(Candidate {
            run: run.clone(),
            numbered,
        });
        candidates.len() - 1
    });
    best.finish(run, numbered, index);
}

/// What the walk and the document-level choice decided, before trimming and geometry.
struct Selection {
    /// The document-wide list: the winner, plus any corroborated run of the same numbering.
    entries: Vec<ReferenceEntry>,
    /// Every run the walk closed, in the order it was closed.
    candidates: Vec<Candidate>,
    /// Index of the run the document-wide list came from.
    chosen: Option<usize>,
    /// Candidate indices joined into the document-wide list as further pieces of its numbering.
    joined: Vec<usize>,
    /// Whether the document-wide list is numbered.
    numbered: bool,
}

/// Selects the document-wide list and keeps every closed run, which is what the multi-list
/// attribution needs; [`select_reference_run`] throws the losers away.
fn select(pages: &[(u32, &RawTextPage)], max_entries: usize) -> Selection {
    let mut numeric = Run::default();
    let mut alpha = Run::default();
    let mut author_year = Run::default();
    let mut best = Best::default();
    // Every run the walk closes. The winner is still the winner; the losers are what T4.20's
    // second chance is for.
    let mut candidates: Vec<Candidate> = Vec::new();
    for (page, text) in pages.iter().copied() {
        // Work in character offsets, matching RawTextPage and the preview ABI.
        let mut offset = 0;
        let heading = text
            .chars
            .split_inclusive(|c| c.unicode == '\n' as u32)
            .find_map(|line| {
                let start = offset;
                offset += line.len();
                let line: String = line
                    .iter()
                    .filter_map(|c| char::from_u32(c.unicode))
                    .collect();
                looks_like_reference_heading(&line).then(|| (start, page, line.trim().to_string()))
            });
        for (run, mut entries, numbered) in [
            (&mut numeric, parse_numeric_references(page, text), true),
            (&mut alpha, alphanumeric::references(page, text), false),
            (
                &mut author_year,
                parse_author_year_references(page, text),
                false,
            ),
        ] {
            if let Some((start, _, _)) = &heading {
                entries.retain(|entry| entry.start >= *start);
            }
            let consecutive_page = run
                .last_page
                .is_some_and(|p| p.checked_add(1) == Some(page));
            let consecutive_label = !numbered
                || run
                    .entries
                    .last()
                    .zip(entries.first())
                    .is_some_and(|(a, b)| {
                        a.label.parse::<u32>().ok().and_then(|n| n.checked_add(1))
                            == b.label.parse::<u32>().ok()
                    });
            // Theses often repeat "Bibliography" as a running page header.
            // Continue an established, coherent list through those headers.
            if !consecutive_page || !consecutive_label || (heading.is_some() && !run.headed) {
                close(run, numbered, &mut best, &mut candidates);
            }
            // An isolated author-like line in prose must not bridge two runs.
            let viable = entries.len() >= 2 || (!run.entries.is_empty() && entries.len() == 1);
            if !viable {
                close(run, numbered, &mut best, &mut candidates);
                continue;
            }
            run.headed |= heading.is_some();
            if let Some((_, heading_page, printed)) = &heading {
                run.heading.get_or_insert((*heading_page, printed.clone()));
            }
            run.last_page = Some(page);
            run.entries.extend(entries);
        }
    }
    close(&mut numeric, true, &mut best, &mut candidates);
    close(&mut alpha, false, &mut best, &mut candidates);
    close(&mut author_year, false, &mut best, &mut candidates);
    // The layout score picks the run that reads most like a bibliography. When the document
    // prints two of them under independent numberings, that is not enough; see `cited_run`.
    let chosen = if best.numbered {
        cited_run(&candidates, best.index, pages).or(best.index)
    } else {
        best.index
    };
    let mut entries = match chosen {
        Some(index) => candidates[index].run.entries.clone(),
        None => std::mem::take(&mut best.run.entries),
    };
    let mut joined = Vec::new();
    // `cited_run` only ever returns a numbered candidate, and `Best` records the winner's own
    // flag, so the selection and this flag agree: the pass below is for a numbered selection.
    if best.numbered {
        let mut extra;
        (extra, joined) = extra_corroborated_runs(&candidates, &entries, pages);
        entries.append(&mut extra);
        entries.sort_by_key(|entry| (entry.page, entry.start));
    }
    entries.truncate(max_entries);
    Selection {
        entries,
        candidates,
        chosen,
        joined,
        numbered: best.numbered,
    }
}

pub(super) fn select_reference_run<'a>(
    pages: impl IntoIterator<Item = (u32, &'a RawTextPage)>,
    max_entries: usize,
) -> Vec<ReferenceEntry> {
    let pages: Vec<(u32, &RawTextPage)> = pages.into_iter().collect();
    select(&pages, max_entries).entries
}

/// Every reference list the document prints, in reading order, with the evidence a citation
/// attribution is decided on.
pub(super) fn find_reference_lists<'a>(
    pages: impl IntoIterator<Item = (u32, &'a RawTextPage)>,
    max_entries: usize,
) -> Bibliography {
    let pages: Vec<(u32, &RawTextPage)> = pages.into_iter().collect();
    if max_entries == 0 || pages.is_empty() {
        return Bibliography::default();
    }
    let selection = select(&pages, max_entries);
    let Some(chosen) = selection.chosen else {
        return Bibliography::default();
    };

    // The document-wide list first. Its heading is the winner's own; when the winner was an
    // unheaded run whose entry list the walk read across repeated headers, there is none.
    let document_wide_heading = selection.candidates[chosen].run.heading.clone();
    let document_wide_numbered = selection.numbered;
    let mut lists: Vec<ReferenceList> = vec![ReferenceList {
        entries: selection.entries.clone(),
        numbered: document_wide_numbered,
        heading: document_wide_heading.as_ref().map(|(_, text)| text.clone()),
        heading_page: document_wide_heading.as_ref().map(|(page, _)| *page),
        section: None,
        region_start: None,
    }];

    // A candidate that carries a reference heading is a list the document announced. The others
    // are competitors the layout score rejected, but no evidence says they are separate
    // bibliographies rather than noise, so they are not reported.
    let document_range = consecutive_range(&selection.entries);
    let mut others: Vec<&Candidate> = Vec::new();
    for (index, candidate) in selection.candidates.iter().enumerate() {
        if index == chosen || selection.joined.contains(&index) || !candidate.run.headed {
            continue;
        }
        if candidate.run.entries.len() < 2 {
            continue;
        }
        // A second run of the document-wide numbering is one bibliography printed in two
        // pieces (Nature's 1–33 + 34–68), not a second bibliography. The join above already
        // returns it when the body cites it; this keeps the uncited piece from becoming a
        // list of its own and re-attributing citations to half a bibliography. The test is
        // "contained in, or immediately continuous with": two independently numbered lists both
        // starting at 1 overlap without being one numbering, and the appendix list is exactly
        // that shape.
        if candidate.numbered
            && document_wide_numbered
            && document_range
                .as_deref()
                .zip(consecutive_range(&candidate.run.entries).as_deref())
                .is_some_and(|(document, run)| {
                    same_numbering(
                        document,
                        run,
                        page_span(&selection.entries),
                        page_span(&candidate.run.entries),
                    )
                })
        {
            continue;
        }
        others.push(candidate);
    }
    // Two parsers can describe the same physical list (a list with alphanumeric keys is read by
    // both the alphanumeric and the author-year parser). Lists do not share pages in practice, so
    // one whose page span overlaps a list already kept is the same list; the longer reading wins.
    others.sort_by_key(|candidate| {
        let first = candidate
            .run
            .entries
            .iter()
            .map(|entry| entry.page)
            .min()
            .unwrap_or(0);
        (
            first,
            candidate.run.entries.first().map(|e| e.start).unwrap_or(0),
        )
    });
    for candidate in others {
        let (Some(first), Some(last)) = (
            candidate.run.entries.iter().map(|e| e.page).min(),
            candidate.run.entries.iter().map(|e| e.page).max(),
        ) else {
            continue;
        };
        // The document-wide list is the selection's own answer and never replaced. Another
        // candidate overlapping it is the same physical list read by another parser.
        let overlap = lists
            .iter()
            .position(|list| match (list.first_page(), list.last_page()) {
                (Some(a), Some(b)) => first <= b && a <= last,
                _ => false,
            });
        if let Some(existing) = overlap {
            if existing > 0 && candidate.run.entries.len() > lists[existing].entries.len() {
                // Replace the smaller reading of the same list.
                lists[existing] = ReferenceList {
                    entries: candidate.run.entries.clone(),
                    numbered: candidate.numbered,
                    heading: candidate.run.heading.as_ref().map(|(_, text)| text.clone()),
                    heading_page: candidate.run.heading.as_ref().map(|(page, _)| *page),
                    section: None,
                    region_start: None,
                };
            }
            continue;
        }
        lists.push(ReferenceList {
            entries: candidate.run.entries.clone(),
            numbered: candidate.numbered,
            heading: candidate.run.heading.as_ref().map(|(_, text)| text.clone()),
            heading_page: candidate.run.heading.as_ref().map(|(page, _)| *page),
            section: None,
            region_start: None,
        });
    }

    // Reading order. The document-wide list is index 0 until here, so sorting an index vector is
    // what keeps `document_wide` pointing at it after the move.
    let mut order: Vec<usize> = (0..lists.len()).collect();
    order.sort_by_key(|index| {
        let list = &lists[*index];
        (
            list.first_page().unwrap_or(0),
            list.entries.first().map(|entry| entry.start).unwrap_or(0),
        )
    });
    let document_wide = order.iter().position(|index| *index == 0).unwrap_or(0);
    let sorted: Vec<ReferenceList> = order.iter().map(|index| lists[*index].clone()).collect();
    let mut lists = sorted;

    // A list closes a section: its own text is the text immediately before it, back to the end of
    // the previous list, or back to the section heading when the document prints one (GPT-4's
    // system card title page starts a part that contains the card's own references).
    let sections = detect_sections(&pages);
    let document_first = pages.iter().map(|(page, _)| *page).min().unwrap_or(0);
    let mut previous_end: Option<u32> = None;
    for (index, list) in lists.iter_mut().enumerate() {
        let Some(first) = list.first_page() else {
            continue;
        };
        list.section = None;
        if index != document_wide {
            let floor = previous_end.map(|end| end + 1).unwrap_or(document_first);
            // A section heading only narrows the region when it is printed after the previous
            // list; an older heading describes text that list already owns. A *container*
            // (appendix, chapter, embedded document's title page) wins over the numbered
            // subsections inside it: the system card's "1 Introduction" must not cut the card's
            // own list's region down to the page before the list.
            let candidates: Vec<&SectionRef> = sections
                .iter()
                .filter(|section| section.page < first && section.page >= floor)
                .collect();
            list.section = candidates
                .iter()
                .rev()
                .find(|section| {
                    matches!(
                        section.kind,
                        SectionKind::Appendix | SectionKind::Chapter | SectionKind::Part
                    )
                })
                .map(|section| (*section).clone())
                .or_else(|| candidates.last().map(|section| (*section).clone()));
            let start = list
                .section
                .as_ref()
                .map(|section| section.page.max(floor))
                .unwrap_or(floor)
                .min(first);
            list.region_start = Some(start);
        }
        // The document-wide list is the fallback everywhere, but the reading-order chain still
        // advances past it: the next list's region starts after this list's last page.
        previous_end = list.last_page().or(previous_end);
    }
    for list in &mut lists {
        list.entries.truncate(max_entries);
    }
    Bibliography {
        lists,
        document_wide,
        sections,
    }
}

/// The pages an entry list occupies, as a closed span.
fn page_span(entries: &[ReferenceEntry]) -> Option<(u32, u32)> {
    Some((
        entries.iter().map(|entry| entry.page).min()?,
        entries.iter().map(|entry| entry.page).max()?,
    ))
}

/// Whether a run is one piece of the document-wide numbering.
///
/// Three shapes are one bibliography:
///
/// * **Adjacent ranges** — the journal list split in two (`1–33` then `34–68`); the ranges do
///   not overlap, so a list numbering independently from 1 cannot be adjacent to the document's.
/// * **A contained range on pages the document list already occupies** — a piece of a run the
///   join in [`extra_corroborated_runs`] did not take, e.g. a split the body never cites. The page
///   overlap is what separates it from an appendix list that also numbers from 1: the appendix is
///   printed on pages *after* the document's list, so it is contained in the labels but disjoint
///   on the page.
/// * **The same range** — one physical list read twice (the alphanumeric and author-year parsers),
///   which the page-overlap dedup would also collapse.
fn same_numbering(
    document: &[u32],
    run: &[u32],
    document_pages: Option<(u32, u32)>,
    run_pages: Option<(u32, u32)>,
) -> bool {
    let (Some(&document_first), Some(&document_last), Some(&run_first), Some(&run_last)) =
        (document.first(), document.last(), run.first(), run.last())
    else {
        return false;
    };
    if run_last.checked_add(1) == Some(document_first)
        || document_last.checked_add(1) == Some(run_first)
    {
        return true;
    }
    let contained = document_first <= run_first && run_last <= document_last;
    let same_pages = document_pages
        .zip(run_pages)
        .is_some_and(|((a, b), (c, d))| a <= d && c <= b);
    contained && same_pages
}

// ---------------------------------------------------------------------------
// The second run of one numbering
// ---------------------------------------------------------------------------

/// The other numbered runs the body's own citations corroborate, in document order.
///
/// `incumbent` is the run the selection settled on — the score's choice, unless [`cited_run`]
/// overruled it — and it is always kept: this function only adds. Two
/// conditions admit a run, and neither is a threshold on how bibliographic a run looks:
///
/// * **The numbering continues.** The run's labels are a complete, consecutive integer range and
///   it is adjacent to the selected range — its last label is one below the selected range's
///   first, or its first label is one above the selected range's last. Adjacency is also what
///   makes a repeat impossible: a run that passes it lies entirely outside the selected range, so
///   a second list that numbers from its own 1 — an appendix's steps, a table of contents, a list
///   of figures, a numbered equation block — cannot join, because its labels are the ones the
///   bibliography already owns. What passes is the one shape the measurement showed: a journal
///   list split in two, where the second run picks up exactly where the first stopped.
/// * **The body cites it.** At least two distinct labels of the run, and at least a quarter of
///   them, appear among the numerals the body's citation shapes carry (see [`cited_numerals`]).
///   This is the corroboration the superscript detector already applies at label level, moved up
///   to run level: a list the body never cites is not this document's bibliography. The quarter
///   is slack for a supplementary list the main text names only in passing; the absolute floor of
///   two is what makes one chance agreement — a raised `2` in an equation, a stray bracket — not
///   enough.
///
/// Runs are added best-corroborated first and chained, so a list printed in three pieces joins
/// in three steps. Returns the entries to add and the candidates they came from.
fn extra_corroborated_runs(
    candidates: &[Candidate],
    incumbent: &[ReferenceEntry],
    pages: &[(u32, &RawTextPage)],
) -> (Vec<ReferenceEntry>, Vec<usize>) {
    // Nothing to corroborate against: one run is the whole document's numbering.
    let numbered: Vec<(usize, &Candidate)> = candidates
        .iter()
        .enumerate()
        .filter(|(_, candidate)| candidate.numbered)
        .collect();
    if numbered.len() < 2 {
        return (Vec::new(), Vec::new());
    }
    let mut selected: BTreeSet<u32> = BTreeSet::new();
    for entry in incumbent {
        match entry.label.parse::<u32>() {
            Ok(number) => {
                // A repeated label means this is not one numbering, and the adjacency test below
                // would be meaningless.
                if !selected.insert(number) {
                    return (Vec::new(), Vec::new());
                }
            }
            Err(_) => return (Vec::new(), Vec::new()),
        }
    }
    let (Some(body_end), Some(mut low), Some(mut high)) = (
        incumbent.iter().map(|entry| entry.page).min(),
        selected.iter().next().copied(),
        selected.iter().next_back().copied(),
    ) else {
        return (Vec::new(), Vec::new());
    };
    // Bibliography pages are not body: a raised numeral inside a reference must not corroborate
    // the list that carries it.
    let run_pages: BTreeSet<u32> = candidates
        .iter()
        .flat_map(|candidate| candidate.run.entries.iter().map(|entry| entry.page))
        .collect();
    let cited = cited_numerals(
        &pages
            .iter()
            .copied()
            .filter(|(page, _)| !run_pages.contains(page))
            .collect::<Vec<_>>(),
        body_end,
    );
    let mut extra: Vec<ReferenceEntry> = Vec::new();
    let mut extra_indices: Vec<usize> = Vec::new();
    // Each run joins at most once. The adjacency test below cannot admit one twice — the range it
    // must touch has moved by then — but this loop is a fixpoint, and a filter weakened by a
    // later edit would spin here instead of failing a test.
    let mut joined = vec![false; numbered.len()];
    loop {
        let mut choice: Option<(usize, usize, &Candidate)> = None;
        for (position, (_, candidate)) in numbered.iter().enumerate() {
            if joined[position] {
                continue;
            }
            let Some(range) = consecutive_range(&candidate.run.entries) else {
                continue;
            };
            let (first, last) = (range[0], range[range.len() - 1]);
            let continues = last.checked_add(1) == Some(low) || first == high + 1;
            if !continues {
                continue;
            }
            let corroborated = range.iter().filter(|number| cited.contains(number)).count();
            // Two labels at least, and a quarter of the run; see this function's docs.
            if corroborated < 2 || corroborated * 4 < range.len() {
                continue;
            }
            let better = choice.is_none_or(|(best, _, candidate_best)| {
                (corroborated, candidate.run.entries.len())
                    > (best, candidate_best.run.entries.len())
            });
            if better {
                choice = Some((corroborated, position, candidate));
            }
        }
        let Some((_, position, candidate)) = choice else {
            break;
        };
        let range = consecutive_range(&candidate.run.entries).unwrap_or_default();
        low = low.min(range[0]);
        high = high.max(range[range.len() - 1]);
        selected.extend(range);
        joined[position] = true;
        extra_indices.push(numbered[position].0);
        extra.extend(candidate.run.entries.iter().cloned());
    }
    (extra, extra_indices)
}

/// The run's labels as one consecutive range, or `None` when it is not a complete numbering.
fn consecutive_range(entries: &[ReferenceEntry]) -> Option<Vec<u32>> {
    if entries.len() < 2 {
        return None;
    }
    let numbers: Option<Vec<u32>> = entries
        .iter()
        .map(|entry| entry.label.parse::<u32>().ok())
        .collect();
    let mut numbers = numbers?;
    numbers.sort_unstable();
    let contiguous = numbers
        .windows(2)
        .all(|pair| pair[0].checked_add(1) == Some(pair[1]));
    contiguous.then_some(numbers)
}

/// The numerals the body cites, read without a bibliography.
///
/// Two shapes, both independent of which list was selected:
///
/// * **Bracket citations** — `[12]`, `[12,13]` — through the same detector the resolver uses.
/// * **Raised numerals** — `winds5,6,23-26` — through [`superscript::raised_runs`], which is the
///   superscript detector *before* its label guard. That guard is what makes this function
///   necessary: with `1710.05463`'s second run selected, the labels of its first run are exactly
///   the ones the guard drops, so a rule that read only corroborated superscripts could never
///   see them.
///
/// Raised numerals are read only when the body does not bracket its numeric citations — the
/// document-level guard [`CitationStyle::for_document`] already applies, for the reason recorded
/// there: in a bracketing paper the raised numerals are footnote markers, units and exponents.
fn cited_numerals(pages: &[(u32, &RawTextPage)], body_end: u32) -> BTreeSet<u32> {
    let body: Vec<(u32, &RawTextPage)> = pages
        .iter()
        .copied()
        .filter(|(page, _)| *page < body_end)
        .collect();
    page_numerals(&body)
        .into_iter()
        .flat_map(|(_, labels)| labels)
        .collect()
}

/// The numerals each page carries, in reading order, with the page they sit on.
///
/// One detector pass per page, and one decision per document about whether its numbers are
/// bracketed at all — the two callers ([`cited_numerals`] and [`cited_run`]) read the same list,
/// so a paper cannot be bracketed for one of them and superscript for the other.
fn page_numerals(pages: &[(u32, &RawTextPage)]) -> Vec<(u32, BTreeSet<u32>)> {
    // Whether the text brackets its citations is read off the same citations the loop below
    // harvests labels from, not from a second detector run.
    let on_page: Vec<Vec<Citation>> = pages
        .iter()
        .map(|(_, text)| find_bracketed_citations(text))
        .collect();
    let bracketed = on_page
        .iter()
        .flatten()
        .any(|citation| citation.text.starts_with('['));
    let mut numerals = Vec::new();
    for ((page, text), citations) in pages.iter().zip(&on_page) {
        let mut labels = BTreeSet::new();
        for citation in citations {
            if !citation.text.starts_with('[') {
                continue;
            }
            for label in &citation.labels {
                if let Ok(number) = label.parse::<u32>() {
                    labels.insert(number);
                }
            }
        }
        if !bracketed {
            for run in superscript::raised_runs(text) {
                for label in &run.labels {
                    if let Ok(number) = label.parse::<u32>() {
                        labels.insert(number);
                    }
                }
            }
        }
        if !labels.is_empty() {
            numerals.push((*page, labels));
        }
    }
    numerals
}

// ---------------------------------------------------------------------------
// Which of several numbered runs the citing text refers to
// ---------------------------------------------------------------------------

/// How many of a run's labels the text before it must cite before that run may be taken as the
/// document's bibliography over the run the layout score chose.
///
/// The score cannot separate two bibliographies: a 105-entry list with a heading scores higher
/// than an 85-entry list with a heading, and `2303.08774` prints exactly that pair — the report's
/// own references (pages 18–23) and the system card appendix's own, independently numbered
/// references (pages 71–78). Both are real lists, so no layout evidence makes one of them wrong;
/// what makes one of them *this document's* bibliography is that the report's own text cites it.
///
/// The floor is measured, on the thirty-two papers of the two corpora (2026-10-15), over the
/// quantity the rule compares — distinct labels of the run that the text before the run cites.
/// Every numbered list in those papers that is *not* a bibliography of its own reaches at most
/// **2** such labels (a two-entry numbered paragraph in `Zhang 2025`, two of whose labels the
/// introduction cites; `1807.06209`'s page-43 pair, likewise 2), while every genuine competing
/// bibliography reaches **33 or more** (`1710.05463`'s first run 33, `Zhang 2025`'s list 60,
/// `2303.08774`'s report list 68, its appendix list 97). Five sits two and a half times above
/// the largest coincidence and six times below the smallest real list: high enough that a
/// numbered paragraph cannot claim a document, low enough that a bibliography cited only in part
/// still can.
const CITED_LABELS_FLOOR: usize = 5;

/// The earliest numbered run that the text before it cites like a bibliography, when that is not
/// the run the layout score chose — the run this document's main text actually refers to.
///
/// Why "earliest" and not "most cited": in `2303.08774` the body cites the report's list at 68
/// labels and the appendix cites the system card's list at 97, so the *most* cited list is the
/// appendix's. Volume favours the appendix because the appendix is long; order favours the
/// report because its main text comes first, and a reader clicking a citation in the main text is
/// the case that must work. The document's own bibliography is the one its main text — the text
/// that precedes every appendix — cites.
///
/// Why a run that merely *continues* the winner is left alone: two runs of one numbering are one
/// bibliography printed in two pieces (`1710.05463`, tied at 33 cited labels each), the join in
/// [`extra_corroborated_runs`] already returns both, and re-picking between them would only move
/// the page the body window starts at. The rule is for two lists that number *independently*.
///
/// One limitation, stated rather than papered over: a document can genuinely carry two
/// bibliographies, and the parser returns one list. Here the appendix's own citations then
/// resolve into the report's list — the entries the reader of the *main text* needs, not the
/// ones the appendix's author cited. Without section structure there is no evidence that tells
/// the two citing regions apart beyond this rule, so the parser serves the main text and says so.
fn cited_run(
    candidates: &[Candidate],
    winner: Option<usize>,
    pages: &[(u32, &RawTextPage)],
) -> Option<usize> {
    let winner = winner?;
    let plausible: Vec<usize> = candidates
        .iter()
        .enumerate()
        .filter(|(_, candidate)| candidate.numbered && candidate.run.score() > 0.0)
        .map(|(index, _)| index)
        .collect();
    if plausible.len() < 2 {
        return None;
    }
    // Bibliography pages are not body: a numeral inside a reference must not count as the text
    // citing the list that carries it. The same exclusion `extra_corroborated_runs` applies.
    let run_pages: BTreeSet<u32> = candidates
        .iter()
        .flat_map(|candidate| candidate.run.entries.iter().map(|entry| entry.page))
        .collect();
    let citing: Vec<(u32, &RawTextPage)> = pages
        .iter()
        .copied()
        .filter(|(page, _)| !run_pages.contains(page))
        .collect();
    let numerals = page_numerals(&citing);
    for index in plausible {
        let run = &candidates[index].run;
        let Some(first) = run.entries.iter().map(|entry| entry.page).min() else {
            continue;
        };
        let cited = run
            .entries
            .iter()
            .filter_map(|entry| entry.label.parse::<u32>().ok())
            .collect::<BTreeSet<u32>>()
            .into_iter()
            .filter(|number| {
                numerals
                    .iter()
                    .any(|(page, labels)| *page < first && labels.contains(number))
            })
            .count();
        if cited < CITED_LABELS_FLOOR {
            continue;
        }
        if index == winner {
            // The score already chose the run the text cites; nothing to overrule.
            return None;
        }
        if continues(&run.entries, &candidates[winner].run.entries) {
            return None;
        }
        return Some(index);
    }
    None
}

/// Whether two runs are two pieces of one numbering: each a complete consecutive range, and
/// adjacent — one's last label immediately below the other's first.
fn continues(run: &[ReferenceEntry], other: &[ReferenceEntry]) -> bool {
    let (Some(run), Some(other)) = (consecutive_range(run), consecutive_range(other)) else {
        return false;
    };
    run[run.len() - 1].checked_add(1) == Some(other[0])
        || other[other.len() - 1].checked_add(1) == Some(run[0])
}

// ---------------------------------------------------------------------------
// Where the list stops
// ---------------------------------------------------------------------------

/// One line of an entry, as the text layer delivers it.
///
/// The lines here are the extractor's own: a run of characters between two line breaks. They are
/// not [`TextLine`]s — on a two-column page geometry merges the two columns' lines, while the
/// extractor emits one line per column, which is exactly the order an entry's own characters
/// arrive in.
struct EntryLine {
    /// First character of the line inside the page.
    start: usize,
    /// Dominant glyph size: the size most of the line's visible glyphs are set at.
    size: f64,
    /// Largest glyph size on the line.
    tallest: f64,
    /// Top of the line in page space.
    top: f64,
    /// Visible characters on the line.
    characters: usize,
}

/// How much taller than its body a block must be set to read as a section, not a reference.
///
/// Measured on the four papers that overrun, and on the 28 that do not (2026-10-15): the blocks
/// that swallow a bibliography's tail start at 1.20× the entry's body size or more (1.20 Zhu 2015,
/// 1.20 `Zhang 2024`, 1.25 `Zadrożny 2017`, 1.39 `Zumalacarregui 2014`), while the largest a
/// *reference* line ever shifts by is 1.14 (`1807.06209`'s folio, `Candidacy`'s math arrows 1.09).
const SECTION_SIZE_RATIO: f64 = 1.15;

/// How far below the previous line a new block starts, in line spacings.
///
/// Wrapped lines follow each other at one spacing; every one of the four overruns begins after a
/// real paragraph break (1.77 spacings in `1810.04805`, 2.76 in `manuscript_0925`, 3.70 in
/// `1710.05833`, and a column jump in `1807.06209`).
const SECTION_GAP_PITCHES: f64 = 1.5;

/// A line whose *tallest* glyph is over [`SECTION_SIZE_RATIO`] must be this short to count.
///
/// A block set in small caps — `manuscript_0925`'s `D Additional Implementation Details` — has a
/// dominant size at or below its body and only its initials larger, so the shift shows up in the
/// tallest glyph alone. A reference line can carry one oversized glyph too (a delimiter, a math
/// symbol), and those lines are full-width; the heading is 35 characters.
const SECTION_HEADING_CHARS: usize = 60;

/// Cuts the last entry of every numbered run back to where its own text ends.
///
/// Why only the last entries: the parser ends every other entry where the next entry's label
/// starts, and that label is evidence about the text between them. A run's last entry has no such
/// evidence — its range runs to the end of the page because that is where the page stops — so a
/// section that follows the list on the same page lands inside it (T4.29: four papers, 2209 to
/// 3601 characters of appendix or author list inside one reference).
///
/// Why every run and not only the selection's last entry: T4.20 joins `1710.05463`'s two runs
/// into one list, which makes its *first* run's last entry — `[33]`, on page 10 — an interior
/// entry. It carried the Acknowledgements section after it, 473 characters where the reference is
/// 245, and the evaluation's entry-length ceiling caught exactly that. The entry is still the last
/// of its run, so it is still a place a section can begin; see [`trailing_indices`] for how the
/// run ends are recognised. Before the join the list was one run, and the two definitions agree.
///
/// Why a size test and not the paragraph gap alone: a gap cannot tell a section from a wrapped
/// line that resumes after a display or a wide interline, and the measured alternative — cutting
/// at the largest gap — truncates real references (`Candidacy`'s entry `[60]` across its own
/// 28.8 pt paragraph break, and `manuscript_0925`'s `Zhang 2024` across a 21.9 pt one; both
/// resume at body size). A section that *follows* a bibliography is set in a larger type than the
/// bibliography; a reference's own continuation is not.
///
/// Measured over the twenty evaluation papers and the twelve samples (2026-10-15), this shortens
/// ten of 2680 entries: the four overruns it is for, and six more pieces of page furniture the
/// list's last entry was also carrying — five folio numbers (`6859`, `1811`, `5067`, `1983`,
/// `5161`) and `2104.08886`'s running footer. Every other entry keeps its text, range and box.
pub(super) fn trim_trailing_section(entries: &mut [ReferenceEntry], pages: &[(u32, &RawTextPage)]) {
    for index in trailing_indices(entries) {
        trim_entry(entries, index, pages);
    }
}

/// The entry indices a following section can begin after: one per run of consecutive numbering.
///
/// The runs here are the ones [`select_reference_run`] joined, recognised the way the walk built
/// them: an entry continues into the next when the next starts on its page or the page after it,
/// and when its label is the next integer. A list that is not numbered at all — an author-year
/// list, an alphanumeric one — has no such evidence, and then only the selection's last entry is a
/// run end, which is what the trim always used to see.
fn trailing_indices(entries: &[ReferenceEntry]) -> Vec<usize> {
    let Some(last) = entries.len().checked_sub(1) else {
        return Vec::new();
    };
    let numbered = entries
        .iter()
        .all(|entry| entry.label.parse::<u32>().is_ok());
    if !numbered {
        return vec![last];
    }
    (0..=last)
        .filter(|index| {
            let entry = &entries[*index];
            !entries.get(index + 1).is_some_and(|next| {
                (next.page == entry.page || next.page == entry.page + 1)
                    && entry
                        .label
                        .parse::<u32>()
                        .ok()
                        .and_then(|n| n.checked_add(1))
                        == next.label.parse::<u32>().ok()
            })
        })
        .collect()
}

/// Cuts one entry's tail back to where its own text ends; see [`trim_trailing_section`].
fn trim_entry(entries: &mut [ReferenceEntry], index: usize, pages: &[(u32, &RawTextPage)]) {
    let Some(entry) = entries.get_mut(index) else {
        return;
    };
    let Some(page) = pages
        .iter()
        .find(|(number, _)| *number == entry.page)
        .map(|(_, text)| *text)
    else {
        return;
    };
    let end = entry.end.min(page.chars.len());
    if entry.start >= end {
        return;
    }
    let Some(stop) = reference_end(page, entry.start, end) else {
        return;
    };

    // The entry's text and its range must keep describing the same glyphs, so both are shortened
    // together; when the tail cannot be matched inside the stored text the entry is left exactly
    // as it was rather than left half cut.
    let tail: String = page.chars[stop..end]
        .iter()
        .filter_map(|character| char::from_u32(character.unicode))
        .collect();
    let collapsed = tail.split_whitespace().collect::<Vec<_>>().join(" ");
    let Some(prefix) = entry
        .text
        .strip_suffix(&collapsed)
        .or_else(|| entry.text.strip_suffix(tail.trim_end()))
    else {
        return;
    };
    entry.text = prefix.trim_end().to_string();
    entry.end = stop;
}

/// Where the entry stops being a reference: the first line, after a paragraph break, that a
/// section would be set in. `None` when the entry carries no such line.
fn reference_end(page: &RawTextPage, start: usize, end: usize) -> Option<usize> {
    let lines = entry_lines(page, start, end);
    // Two lines cannot show a spacing, and one cannot show a break.
    if lines.len() < 3 {
        return None;
    }
    let body = lines[0].size;
    if body <= 0.0 {
        return None;
    }
    let pitch = line_pitch(&lines);
    if pitch <= 0.0 {
        return None;
    }
    for index in 1..lines.len() {
        let line = &lines[index];
        let gap = (lines[index - 1].top - line.top).abs();
        if gap <= SECTION_GAP_PITCHES * pitch {
            continue;
        }
        let larger = line.size >= SECTION_SIZE_RATIO * body;
        let heading =
            line.tallest >= SECTION_SIZE_RATIO * body && line.characters <= SECTION_HEADING_CHARS;
        let smaller = line.size * SECTION_SIZE_RATIO <= body
            && lines[index..]
                .iter()
                .all(|rest| rest.size * SECTION_SIZE_RATIO <= body);
        if larger || heading || smaller {
            return Some(line.start);
        }
    }
    None
}

/// Splits `start..end` into the extractor's own lines, with the style each is set in.
fn entry_lines(page: &RawTextPage, start: usize, end: usize) -> Vec<EntryLine> {
    let mut lines: Vec<EntryLine> = Vec::new();
    let mut line_start = start;
    let mut index = start;
    while index <= end {
        let is_break = index == end
            || char::from_u32(page.chars[index].unicode)
                .is_some_and(|character| character == '\n' || character == '\r');
        if is_break {
            if let Some(line) = measure_line(page, line_start, index) {
                lines.push(line);
            }
            line_start = index + 1;
        }
        index += 1;
    }
    lines
}

/// The style of one line, or `None` when it holds no measured glyph.
fn measure_line(page: &RawTextPage, start: usize, end: usize) -> Option<EntryLine> {
    let mut sizes: std::collections::BTreeMap<i64, usize> = std::collections::BTreeMap::new();
    let mut tallest = 0.0f64;
    let mut top = f64::MIN;
    let mut characters = 0usize;
    for character in &page.chars[start.min(page.chars.len())..end.min(page.chars.len())] {
        let Some(decoded) = char::from_u32(character.unicode) else {
            continue;
        };
        if decoded.is_whitespace() || character.rect.size.height <= 0.0 {
            continue;
        }
        *sizes
            .entry((character.font_size * 10.0).round() as i64)
            .or_default() += 1;
        tallest = tallest.max(character.font_size);
        top = top.max(character.rect.origin.y + character.rect.size.height);
        characters += 1;
    }
    if characters == 0 {
        return None;
    }
    let size = sizes
        .iter()
        .max_by_key(|(_, count)| **count)
        .map(|(size, _)| *size as f64 / 10.0)
        .unwrap_or(0.0);
    Some(EntryLine {
        start,
        size,
        tallest,
        top,
        characters,
    })
}

/// The entry's own line spacing: the median distance between lines that carry words.
///
/// Lines that hold a fragment — a superscript, a math delimiter, a page number — are ignored: on
/// a two-column page their spacing says nothing about the text's leading.
fn line_pitch(lines: &[EntryLine]) -> f64 {
    let mut gaps: Vec<f64> = lines
        .windows(2)
        .filter(|pair| pair[0].characters >= 8 && pair[1].characters >= 8)
        .map(|pair| pair[0].top - pair[1].top)
        .filter(|gap| *gap > 0.0)
        .collect();
    if gaps.is_empty() {
        return 0.0;
    }
    gaps.sort_by(f64::total_cmp);
    gaps[gaps.len() / 2]
}

// ---------------------------------------------------------------------------
// Sections, and which list a citation belongs to
// ---------------------------------------------------------------------------

/// How much taller than the page's body a line must be set to read as a section heading.
///
/// A numbered section heading in the corpora is set 1.2–1.6 times its body size; a running header
/// is at or below it, and a reference entry is at body size. The appendix and chapter headings
/// that decide section ownership in the fixture are 1.2× and 1.4×. This is a *layout* threshold,
/// not a bibliographic one: it only says where a section starts, and a wrong section start can
/// only move the page a list's region begins on.
const SECTION_HEADING_RATIO: f64 = 1.15;

/// A line a section heading could be read from.
struct SectionLine {
    text: String,
    /// Dominant glyph size of the line.
    size: f64,
    characters: usize,
    /// Horizontal extent of the line's ink, in page space.
    x0: f64,
    x1: f64,
}

/// A line of a page as the section detector reads it: the printed characters, its dominant type
/// size, and how many visible glyphs it carries.
fn section_lines(page: &RawTextPage) -> Vec<SectionLine> {
    let mut lines = Vec::new();
    let mut offset = 0;
    for line in page
        .chars
        .split_inclusive(|character| character.unicode == '\n' as u32)
    {
        let start = offset;
        offset += line.len();
        let mut sizes: std::collections::BTreeMap<i64, usize> = std::collections::BTreeMap::new();
        let mut characters = 0usize;
        let mut x0 = f64::MAX;
        let mut x1 = f64::MIN;
        for character in &page.chars[start..start + line.len()] {
            let Some(decoded) = char::from_u32(character.unicode) else {
                continue;
            };
            if decoded.is_whitespace() || character.rect.size.height <= 0.0 {
                continue;
            }
            *sizes
                .entry((character.font_size * 10.0).round() as i64)
                .or_default() += 1;
            characters += 1;
            x0 = x0.min(character.rect.origin.x);
            x1 = x1.max(character.rect.origin.x + character.rect.size.width);
        }
        if characters == 0 {
            continue;
        }
        let size = sizes
            .iter()
            .max_by_key(|(_, count)| **count)
            .map(|(size, _)| *size as f64 / 10.0)
            .unwrap_or(0.0);
        let text: String = page.chars[start..start + line.len()]
            .iter()
            .filter_map(|character| char::from_u32(character.unicode))
            .collect();
        let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
        if text.is_empty() {
            continue;
        }
        lines.push(SectionLine {
            text,
            size,
            characters,
            x0,
            x1,
        });
    }
    lines
}

/// The size most of a page's visible glyphs are set at: the page's body size.
fn page_body_size(page: &RawTextPage) -> f64 {
    let mut sizes: std::collections::BTreeMap<i64, usize> = std::collections::BTreeMap::new();
    for character in &page.chars {
        let Some(decoded) = char::from_u32(character.unicode) else {
            continue;
        };
        if decoded.is_whitespace() || character.rect.size.height <= 0.0 {
            continue;
        }
        *sizes
            .entry((character.font_size * 10.0).round() as i64)
            .or_default() += 1;
    }
    sizes
        .iter()
        .max_by_key(|(_, count)| **count)
        .map(|(size, _)| *size as f64 / 10.0)
        .unwrap_or(0.0)
}

/// Section starts the document prints, one per page, in reading order.
///
/// Only headings that say where a *container* begins are reported: `Appendix …`, `Chapter …`,
/// an embedded document's title page, and a top-level numbered or lettered heading. The point is
/// not to reconstruct a table of contents; it is to answer which pages a reference list at the
/// end of a section belongs to. A list's region therefore starts at the latest such heading before
/// it (GPT-4's system card begins with its own title page and its own larger type), and otherwise
/// directly after the previous list, which is what a per-chapter thesis shows.
fn detect_sections(pages: &[(u32, &RawTextPage)]) -> Vec<SectionRef> {
    let mut sections = Vec::new();
    for (page, text) in pages {
        let body = page_body_size(text);
        if body <= 0.0 {
            continue;
        }
        let lines = section_lines(text);
        let page_left = lines.iter().map(|line| line.x0).fold(f64::MAX, f64::min);
        let page_right = lines.iter().map(|line| line.x1).fold(f64::MIN, f64::max);
        let mut best: Option<(u8, SectionRef)> = None;
        for (index, line) in lines.iter().enumerate() {
            let Some(kind) = section_kind(line, body, index, page_left, page_right) else {
                continue;
            };
            let priority = match kind {
                SectionKind::Appendix | SectionKind::Chapter => 3,
                SectionKind::Part => 2,
                SectionKind::Section => 1,
            };
            if best.as_ref().is_none_or(|(best, _)| priority > *best) {
                best = Some((
                    priority,
                    SectionRef {
                        title: line.text.clone(),
                        page: *page,
                        kind,
                    },
                ));
            }
        }
        if let Some((_, section)) = best {
            sections.push(section);
        }
    }
    sections
}

/// What kind of section this line opens, if any.
fn section_kind(
    line: &SectionLine,
    body: f64,
    index: usize,
    page_left: f64,
    page_right: f64,
) -> Option<SectionKind> {
    let text = line.text.trim();
    if text.chars().count() > 90 || line.characters < 2 {
        return None;
    }
    let lower = text.to_lowercase();
    // A part or embedded document starts with a centred title, visibly larger than the page's
    // text. Centring is what separates it from a section heading set in the same larger type at
    // the left margin (GPT-4's "Authorship, Credit Attribution, and Acknowledgements" is one).
    let page_width = page_right - page_left;
    let centred = page_width > 0.0
        && ((line.x0 + line.x1) / 2.0 - (page_left + page_right) / 2.0).abs() <= page_width * 0.08;
    // A running header repeats on every page and is not a section start. An appendix or chapter
    // heading is set larger than the text, or — in GPT-4, where "Appendix" is barely taller than
    // its body — centred above it; the centring tells the two apart.
    let heading_sized = line.size >= body * 1.05 || (line.size >= body * 0.95 && centred);
    if (lower.starts_with("appendix") || lower.starts_with("附录") || lower.starts_with("附錄"))
        && heading_sized
    {
        return Some(SectionKind::Appendix);
    }
    if (lower.starts_with("chapter") || (lower.starts_with('第') && lower.contains('章')))
        && heading_sized
    {
        return Some(SectionKind::Chapter);
    }
    // An embedded document of its own starts with its title, set visibly larger than the text
    // below it — GPT-4's system card is such a document and its own references are its own.
    if index <= 2
        && line.size >= body * 1.5
        && centred
        && text
            .chars()
            .filter(|character| character.is_alphabetic())
            .count()
            >= 3
        && !starts_with_figure_or_table(&lower)
    {
        return Some(SectionKind::Part);
    }
    if line.size < body * SECTION_HEADING_RATIO
        || text.contains('[')
        || contains_publication_year(text)
        || text.ends_with(['.', ',', ';'])
    {
        return None;
    }
    if numbered_section_word(text) || lettered_section_word(text) {
        // A heading is words. This refuses a page number (`16`), a formula (`D − GC`) and a
        // table row that happens to begin with a number; a genuine section heading carries at
        // least six letters and reads in at most ten words.
        let alphabetic = text
            .chars()
            .filter(|character| character.is_alphabetic())
            .count();
        if alphabetic < 6 || text.split_whitespace().count() > 10 {
            return None;
        }
        return Some(SectionKind::Section);
    }
    None
}

/// Whether the line opens with a top-level number: `2`, `2.`, `A`, `A.` — but not `2.1`.
fn numbered_section_word(text: &str) -> bool {
    let mut words = text.split_whitespace();
    let Some(token) = words.next() else {
        return false;
    };
    // A bare page number is not a heading; a numbered section carries words after its number.
    if words.next().is_none() {
        return false;
    }
    let trimmed = token.trim_end_matches(['.', ')', ':']);
    if trimmed.is_empty() || !trimmed.chars().all(|character| character.is_ascii_digit()) {
        return false;
    }
    // Reject subsection numbers: `2.1` is a token that still carries a dot inside it.
    *token == *trimmed || token == format!("{trimmed}.")
}

/// Whether the line opens with a single capital letter: the appendix's `A Exam methodology`.
fn lettered_section_word(text: &str) -> bool {
    let mut words = text.split_whitespace();
    let Some(first) = words.next() else {
        return false;
    };
    let letter = first.trim_end_matches(['.', ')', ':']);
    letter.chars().count() == 1
        && letter
            .chars()
            .all(|character| character.is_ascii_uppercase())
        && words.next().is_some()
}

fn starts_with_figure_or_table(lower: &str) -> bool {
    ["figure", "fig.", "table", "algorithm", "listing"]
        .iter()
        .any(|prefix| lower.starts_with(prefix))
}

/// Whether the line carries a four-digit year in the publication range. A reference entry almost
/// always does; a section heading almost never does. It is the guard that keeps a numbered
/// bibliography's own entries from reading as section starts.
fn contains_publication_year(text: &str) -> bool {
    let characters: Vec<char> = text.chars().collect();
    characters.windows(4).any(|window| {
        window.iter().all(char::is_ascii_digit)
            && (window[0] == '1' || window[0] == '2')
            && matches!(window[1], '9' | '0')
    })
}

/// Whether the list prints any of the citation's labels exactly.
fn carries_label(list: &ReferenceList, labels: &[String]) -> bool {
    labels.iter().any(|label| {
        list.entries
            .iter()
            .any(|entry| entry.label.eq_ignore_ascii_case(label))
    })
}

/// Pages between `page` and the list, or zero when the page is inside the list's page span.
fn list_distance(list: &ReferenceList, page: u32) -> u32 {
    let (Some(first), Some(last)) = (list.first_page(), list.last_page()) else {
        return u32::MAX;
    };
    if page < first {
        first - page
    } else {
        page.saturating_sub(last)
    }
}

/// The list nearest to `page` in reading order among `candidates`.
fn nearest_list(bibliography: &Bibliography, candidates: &[usize], page: u32) -> Option<usize> {
    candidates
        .iter()
        .copied()
        .min_by_key(|index| list_distance(&bibliography.lists[*index], page))
}

/// Whether the nearest candidate is tied with another one, which is no evidence at all.
fn nearest_is_tied(bibliography: &Bibliography, candidates: &[usize], page: u32) -> bool {
    let Some(nearest) = nearest_list(bibliography, candidates, page) else {
        return false;
    };
    let distance = list_distance(&bibliography.lists[nearest], page);
    candidates
        .iter()
        .filter(|index| list_distance(&bibliography.lists[**index], page) == distance)
        .count()
        > 1
}

/// Decides which list owns a citation on `page` naming `labels`.
///
/// The evidence, in the order it is read:
///
/// 1. **One list.** Nothing to decide.
/// 2. **The section's own list.** A list closes a section: a per-chapter thesis list or an
///    appendix's list owns the pages from its section's start (or the end of the previous list)
///    to its own first page. A citation in those pages that the list can resolve belongs to it.
/// 3. **The numbering.** A label only one list prints names that list, wherever the citation is —
///    this is what makes a number that exists only in an appendix list resolve there instead of
///    failing against the main list.
/// 4. **The document-wide list.** With no region and several lists carrying the label, the
///    document-wide list is used; that is the T4.41 selection the main text already resolves
///    against.
/// 5. **Distance.** With no region and no document-wide match, the nearest list that carries the
///    label is used.
///
/// The ambiguity rule: when several lists carry the label and no region separates them, the
/// document-wide list wins and `ambiguous` is set unless that list is also uniquely nearest in
/// reading order. A nearer list is *reported*, never silently picked, because proximity alone does
/// not say which section the citation belongs to.
pub(super) fn attribute(
    bibliography: &Bibliography,
    page: u32,
    labels: &[String],
) -> CitationAttribution {
    debug_assert!(!bibliography.lists.is_empty());
    let document_wide = bibliography.document_wide;
    if bibliography.lists.len() == 1 {
        return CitationAttribution {
            list: 0,
            reason: AttributionReason::OnlyList,
            ambiguous: false,
            alternatives: Vec::new(),
            region_list: None,
            label_matches: carries_label(&bibliography.lists[0], labels),
        };
    }
    let matching: Vec<usize> = bibliography
        .lists
        .iter()
        .enumerate()
        .filter(|(_, list)| carries_label(list, labels))
        .map(|(index, _)| index)
        .collect();
    // A list owns its region *and its own pages*: a bracket inside the list is that list's own
    // label, not a body citation, and attributing it to the document-wide list is the mirror
    // error this task exists to remove. The region of the next list starts after this one.
    let region = bibliography.lists.iter().position(|list| {
        list.region_start
            .zip(list.last_page())
            .is_some_and(|(start, last)| start <= page && page <= last)
    });
    let build =
        |list: usize, reason, ambiguous: bool, region_list: Option<usize>| CitationAttribution {
            list,
            reason,
            ambiguous,
            alternatives: matching
                .iter()
                .copied()
                .filter(|index| *index != list)
                .collect(),
            region_list,
            label_matches: matching.contains(&list),
        };

    if let Some(region) = region {
        if matching.contains(&region) {
            return build(region, AttributionReason::SectionList, false, Some(region));
        }
        // The section's list does not carry the label. The numbering still decides: one list that
        // does carry it, then the document-wide fallback that the main text cites.
        if let [only] = matching.as_slice() {
            return build(*only, AttributionReason::LabelOnly, false, Some(region));
        }
        if matching.contains(&document_wide) {
            let ambiguous = matching.len() > 1;
            return build(
                document_wide,
                AttributionReason::DocumentWide,
                ambiguous,
                Some(region),
            );
        }
        if let Some(nearest) = nearest_list(bibliography, &matching, page) {
            let ambiguous = nearest_is_tied(bibliography, &matching, page);
            return build(
                nearest,
                AttributionReason::NearestList,
                ambiguous,
                Some(region),
            );
        }
        return build(
            document_wide,
            AttributionReason::DocumentWide,
            false,
            Some(region),
        );
    }

    match matching.as_slice() {
        [] => build(document_wide, AttributionReason::DocumentWide, false, None),
        [only] => build(*only, AttributionReason::LabelOnly, false, None),
        _ if matching.contains(&document_wide) => {
            // Prefer the document-wide list, and say so. Proximity only decides whether the
            // choice was genuinely ambiguous: if the document-wide list is not the unique nearest,
            // another list could own the citation and the reader is told.
            let document_distance = list_distance(&bibliography.lists[document_wide], page);
            let ambiguous = bibliography.lists.iter().enumerate().any(|(index, list)| {
                index != document_wide && list_distance(list, page) <= document_distance
            });
            build(
                document_wide,
                AttributionReason::DocumentWide,
                ambiguous,
                None,
            )
        }
        _ => {
            let nearest = nearest_list(bibliography, &matching, page).unwrap_or(document_wide);
            let ambiguous = nearest_is_tied(bibliography, &matching, page);
            build(nearest, AttributionReason::NearestList, ambiguous, None)
        }
    }
}
