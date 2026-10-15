//! Select a coherent bibliography, independently of citation matching.
//!
//! Keep numeric and author-year candidates separate until the document-level
//! decision. A spurious numeric marker must not suppress an author-year page,
//! and candidates in different styles must not join into a run through the body.

use super::*;

#[derive(Default)]
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

    fn finish(&mut self, best: &mut Run) {
        if self.score() > best.score() {
            *best = std::mem::take(self);
        } else {
            *self = Self::default();
        }
    }
}

pub(super) fn select_reference_run<'a>(
    pages: impl IntoIterator<Item = (u32, &'a RawTextPage)>,
    max_entries: usize,
) -> Vec<ReferenceEntry> {
    if max_entries == 0 {
        return Vec::new();
    }
    let mut numeric = Run::default();
    let mut alpha = Run::default();
    let mut author_year = Run::default();
    let mut best = Run::default();
    for (page, text) in pages {
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
                run.finish(&mut best);
            }
            // An isolated author-like line in prose must not bridge two runs.
            let viable = entries.len() >= 2 || (!run.entries.is_empty() && entries.len() == 1);
            if !viable {
                run.finish(&mut best);
                continue;
            }
            run.headed |= heading.is_some();
            run.last_page = Some(page);
            run.entries.extend(entries);
        }
    }
    numeric.finish(&mut best);
    alpha.finish(&mut best);
    author_year.finish(&mut best);
    best.entries.truncate(max_entries);
    best.entries
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

/// Cuts the bibliography's last entry back to where its own text ends.
///
/// Why only the last entry: the parser ends every other entry where the next entry's label
/// starts, and that label is evidence about the text between them. The last entry has no such
/// evidence — its range runs to the end of the page because that is where the page stops — so a
/// section that follows the list on the same page lands inside it (T4.29: four papers, 2209 to
/// 3601 characters of appendix or author list inside one reference).
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
    let Some(entry) = entries.last_mut() else {
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
        if larger || heading {
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
