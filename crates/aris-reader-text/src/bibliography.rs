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

use super::*;
use std::collections::BTreeSet;

#[derive(Default, Clone)]
struct Run {
    entries: Vec<ReferenceEntry>,
    last_page: Option<u32>,
    headed: bool,
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

    /// Offers this run to `best`; reports whether it won, and clears the loser.
    fn finish(&mut self, best: &mut Run) -> bool {
        if self.score() > best.score() {
            *best = std::mem::take(self);
            true
        } else {
            *self = Self::default();
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
fn close(
    run: &mut Run,
    numbered: bool,
    best: &mut Run,
    best_numbered: &mut bool,
    candidates: &mut Vec<Candidate>,
) {
    if !run.entries.is_empty() {
        candidates.push(Candidate {
            run: run.clone(),
            numbered,
        });
    }
    if run.finish(best) {
        *best_numbered = numbered;
    }
}

pub(super) fn select_reference_run<'a>(
    pages: impl IntoIterator<Item = (u32, &'a RawTextPage)>,
    max_entries: usize,
) -> Vec<ReferenceEntry> {
    if max_entries == 0 {
        return Vec::new();
    }
    let pages: Vec<(u32, &RawTextPage)> = pages.into_iter().collect();
    let mut numeric = Run::default();
    let mut alpha = Run::default();
    let mut author_year = Run::default();
    let mut best = Run::default();
    let mut best_numbered = false;
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
                looks_like_reference_heading(&line).then_some(start)
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
            if let Some(start) = heading {
                entries.retain(|entry| entry.start >= start);
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
                close(
                    run,
                    numbered,
                    &mut best,
                    &mut best_numbered,
                    &mut candidates,
                );
            }
            // An isolated author-like line in prose must not bridge two runs.
            let viable = entries.len() >= 2 || (!run.entries.is_empty() && entries.len() == 1);
            if !viable {
                close(
                    run,
                    numbered,
                    &mut best,
                    &mut best_numbered,
                    &mut candidates,
                );
                continue;
            }
            run.headed |= heading.is_some();
            run.last_page = Some(page);
            run.entries.extend(entries);
        }
    }
    close(
        &mut numeric,
        true,
        &mut best,
        &mut best_numbered,
        &mut candidates,
    );
    close(
        &mut alpha,
        false,
        &mut best,
        &mut best_numbered,
        &mut candidates,
    );
    close(
        &mut author_year,
        false,
        &mut best,
        &mut best_numbered,
        &mut candidates,
    );
    let mut entries = std::mem::take(&mut best.entries);
    if best_numbered {
        entries.extend(extra_corroborated_runs(&candidates, &entries, &pages));
        entries.sort_by_key(|entry| (entry.page, entry.start));
    }
    entries.truncate(max_entries);
    entries
}

// ---------------------------------------------------------------------------
// The second run of one numbering
// ---------------------------------------------------------------------------

/// The other numbered runs the body's own citations corroborate, in document order.
///
/// `incumbent` is the run the score chose, and it is always kept: this function only adds. Two
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
/// in three steps.
fn extra_corroborated_runs(
    candidates: &[Candidate],
    incumbent: &[ReferenceEntry],
    pages: &[(u32, &RawTextPage)],
) -> Vec<ReferenceEntry> {
    // Nothing to corroborate against: one run is the whole document's numbering.
    let numbered: Vec<&Candidate> = candidates.iter().filter(|c| c.numbered).collect();
    if numbered.len() < 2 {
        return Vec::new();
    }
    let mut selected: BTreeSet<u32> = BTreeSet::new();
    for entry in incumbent {
        match entry.label.parse::<u32>() {
            Ok(number) => {
                // A repeated label means this is not one numbering, and the adjacency test below
                // would be meaningless.
                if !selected.insert(number) {
                    return Vec::new();
                }
            }
            Err(_) => return Vec::new(),
        }
    }
    let (Some(body_end), Some(mut low), Some(mut high)) = (
        incumbent.iter().map(|entry| entry.page).min(),
        selected.iter().next().copied(),
        selected.iter().next_back().copied(),
    ) else {
        return Vec::new();
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
    // Each run joins at most once. The adjacency test below cannot admit one twice — the range it
    // must touch has moved by then — but this loop is a fixpoint, and a filter weakened by a
    // later edit would spin here instead of failing a test.
    let mut joined = vec![false; numbered.len()];
    loop {
        let mut choice: Option<(usize, usize, &Candidate)> = None;
        for (index, candidate) in numbered.iter().enumerate() {
            if joined[index] {
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
                choice = Some((corroborated, index, candidate));
            }
        }
        let Some((_, index, candidate)) = choice else {
            break;
        };
        let range = consecutive_range(&candidate.run.entries).unwrap_or_default();
        low = low.min(range[0]);
        high = high.max(range[range.len() - 1]);
        selected.extend(range);
        joined[index] = true;
        extra.extend(candidate.run.entries.iter().cloned());
    }
    extra
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
    let body: Vec<&RawTextPage> = pages
        .iter()
        .filter(|(page, _)| *page < body_end)
        .map(|(_, text)| *text)
        .collect();
    // One detector pass per page, not two: whether the body brackets its citations is read off
    // the same citations the loop below harvests labels from.
    let on_page: Vec<Vec<Citation>> = body
        .iter()
        .map(|text| find_bracketed_citations(text))
        .collect();
    let bracketed = on_page
        .iter()
        .flatten()
        .any(|citation| citation.text.starts_with('['));
    let mut cited = BTreeSet::new();
    for (text, citations) in body.iter().zip(&on_page) {
        for citation in citations {
            if !citation.text.starts_with('[') {
                continue;
            }
            for label in &citation.labels {
                if let Ok(number) = label.parse::<u32>() {
                    cited.insert(number);
                }
            }
        }
        if !bracketed {
            for run in superscript::raised_runs(text) {
                for label in &run.labels {
                    if let Ok(number) = label.parse::<u32>() {
                        cited.insert(number);
                    }
                }
            }
        }
    }
    cited
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
