//! Cutting a reference entry into the pieces it is really drawn in.
//!
//! # Why an entry is not one rectangle
//!
//! A bibliography entry is a run of glyphs, and the reader previews it by boxing those glyphs.
//! Two layouts make a single box wrong:
//!
//! * **A column break.** An entry that starts at the foot of the left column and continues at
//!   the head of the right one occupies two disjoint areas. The smallest rectangle containing
//!   both spans the whole gutter, so a preview drawn from it shows the neighbouring column as
//!   well — and on a page whose two columns hold different entries, that is the wrong text.
//! * **A page break.** The entry's last lines sit at the head of the next page. A box on the
//!   first page cannot show them at all.
//!
//! So an entry carries [`EntryFragment`]s: one page, one contiguous glyph range on that page,
//! and the box those glyphs occupy. The common case — one entry, one column, one page — is a
//! single fragment whose range and box are exactly what `start..end` described before.
//!
//! # How the pieces are found
//!
//! Nothing here invents geometry. The page's lines come from [`lines_from`], the entry's
//! paragraphs from [`blocks_from`], and the column boundary from
//! [`column_gutter`](crate::tables::column_gutter) — the same gutter test the table finder uses
//! to refuse a region that spans two columns. Every line is placed on one side of that gutter
//! (by construction no line crosses it, or `column_gutter` would not have reported it), and the
//! entry's glyphs are cut where that placement changes. A page that shows no gutter keeps its
//! entries as single fragments, exactly as before.
//!
//! Fragment ranges are a contiguous cover of the entry's own range, so each fragment can be
//! highlighted on its own: a fragment never names characters that belong to another fragment.
//!
//! # What it does to `text`
//!
//! When an entry continues on the following page, that page's opening lines are appended to
//! [`ReferenceEntry::text`] as well, so the entry's words and its fragments describe the same
//! content. The run that *selects* the bibliography has already been scored by then, so no
//! selection depends on text this pass adds.
//!
//! # What is measured
//!
//! `cargo test -p aris-reader-cli --test entry_fragments_corpus -- --ignored --nocapture`,
//! on the twelve sample papers (2026-10-14): **769 entries, 789 fragments, 20 of them
//! multi-fragment — no column split at all, 20 page continuations — and 0 fragment boxes
//! crossing a gutter.**
//!
//! That zero is honest but weak, and the test says so out loud: these samples are single-column
//! layouts, and the gutter test finds no boundary on **any** of their 298 pages, so the corpus
//! offers nothing for the column rule to refuse. The layout is covered instead by
//! `an_entry_split_across_two_columns_becomes_two_fragments` below and, through PDFium, by
//! `entry_fragments_fixture.rs` in the CLI crate, which reads a generated two-column page.
//!
//! Of the 20 page continuations, 17 are the entry's own words and 3 are page furniture the
//! geometric guard cannot tell from prose (`Dvorožňák 2017`, whose second fragment is a running
//! head and a figure caption, and `SMooDi` twice, running heads). The guard does throw away the
//! two `manuscript_0925` cases (margin line numbers and the running head) and one in `Leader`
//! (a running head sharing the next label's line), which is why it is there.

use crate::tables::column_gutter;
use crate::{EntryFragment, ReferenceEntry, TextLine, blocks_from, lines_from};
use aris_reader_core::{RawCharBox, RawTextPage, Rect};
use std::collections::HashMap;

/// Multiple of the median line height that still reads as one paragraph.
///
/// The value the CLI and the figure code already use for tightly set academic text.
const BLOCK_GAP_FACTOR: f64 = 0.8;

/// How far outside the gutter a line may still end and count as being on its side (points).
const SIDE_TOLERANCE_PT: f64 = 0.5;

/// Page line spacings a continuation's lines may reach below the next entry's own line.
///
/// One spacing absorbs the gap between the last line of an entry and the label that follows it.
const FLOW_SLACK_PITCHES: f64 = 1.0;

/// Which side of the page's gutter a box sits on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Side {
    Left,
    Right,
    /// The box straddles the gutter, so it cannot be assigned to one column.
    Crossing,
}

/// Fills in the fragments of every entry the supplied pages can explain.
///
/// Entries whose page is missing from `pages` keep the fragments they already have; an entry
/// built by hand has none, and its callers fall back to `page`/`start`/`end` as before.
///
/// Besides the entry's own page this resolves **page continuations**: an entry that runs to the
/// end of its page and is followed, on the next page, by another entry of the same list absorbs
/// that page's opening lines. The following entry is the evidence — without a later label there
/// is nothing to say where the continuation stops and the next section begins, so the last
/// entry of a list is never extended past its own page.
pub(crate) fn assign(entries: &mut [ReferenceEntry], pages: &[(u32, &RawTextPage)]) {
    let mut by_page: HashMap<u32, &RawTextPage> = HashMap::new();
    for (page, text) in pages {
        by_page.insert(*page, *text);
    }
    let mut geometry: HashMap<u32, PageGeometry> = HashMap::new();

    for entry in entries.iter_mut() {
        let Some(text) = by_page.get(&entry.page).copied() else {
            continue;
        };
        let shapes = geometry
            .entry(entry.page)
            .or_insert_with(|| PageGeometry::new(text));
        entry.fragments = shapes.split(entry.page, text, entry.start, entry.end);
    }

    for index in 0..entries.len().saturating_sub(1) {
        let (head, tail) = entries.split_at_mut(index + 1);
        let entry = &mut head[index];
        let next = &tail[0];
        if next.page != entry.page + 1 || entry.fragments.is_empty() {
            continue;
        }
        let (Some(text), Some(next_text)) = (
            by_page.get(&entry.page).copied(),
            by_page.get(&next.page).copied(),
        ) else {
            continue;
        };
        // The parser ends an entry where the next label starts, so an entry can only continue on
        // the following page when its own page carries nothing after it.
        if !ends_at_page_end(text, entry.end) {
            continue;
        }
        let Some((start, end)) = continuation_range(next_text, next.start) else {
            continue;
        };
        let shapes = geometry
            .entry(next.page)
            .or_insert_with(|| PageGeometry::new(next_text));
        // The page before can say where a running head stands, but not whether the lines under
        // it belong to the entry; what the entry's own page says is that its text stops where
        // the next label begins. Anything the range still covers below that label — a margin
        // line number, a figure caption, a head above the body — is not the entry's words.
        if !stays_in_flow(shapes, next_text, start, end, next.start) {
            continue;
        }
        let mut pieces = shapes.split(next.page, next_text, start, end);
        if pieces.is_empty() {
            continue;
        }
        let continuation = collapse(next_text, start, end);
        if !continuation.is_empty() {
            if !entry.text.is_empty() {
                entry.text.push(' ');
            }
            entry.text.push_str(&continuation);
        }
        entry.fragments.append(&mut pieces);
    }
}

/// The page's line structure and column boundary, computed once and then reused by every entry.
struct PageGeometry {
    lines: Vec<TextLine>,
    gutter: Option<f64>,
}

impl PageGeometry {
    fn new(text: &RawTextPage) -> Self {
        let lines = lines_from(text);
        let gutter = column_gutter(&lines, None);
        Self { lines, gutter }
    }

    /// Median vertical distance between neighbouring lines: the page's own line spacing.
    fn pitch(&self) -> f64 {
        let smallest = median_line_height(&self.lines);
        let mut gaps: Vec<f64> = self
            .lines
            .windows(2)
            .map(|pair| pair[0].rect.origin.y - pair[1].rect.origin.y)
            // Same-row lines of two columns have no distance; a jump larger than a few lines is
            // not spacing but a new block (or a second column).
            .filter(|gap| *gap > 0.0 && *gap <= 3.0 * smallest)
            .collect();
        if gaps.is_empty() {
            return smallest;
        }
        gaps.sort_by(f64::total_cmp);
        gaps[gaps.len() / 2]
    }

    /// Whether two boxes belong to the same column of this page.
    ///
    /// A page the gutter test cannot read (one column, or a full-width line across every
    /// boundary) is one column, so everything on it is in the same one.
    fn same_column(&self, left: Rect, right: Rect) -> bool {
        match self.gutter {
            Some(gutter) => side_of(left, gutter) == side_of(right, gutter),
            None => true,
        }
    }

    /// The pieces the glyph range `start..end` is drawn in, in character order.
    ///
    /// One piece when the range stays inside one column, or the page shows no gutter: its range
    /// is `start..end` and its box is the union of the range's own character boxes — exactly the
    /// rectangle this entry had before fragments existed. Several pieces when the range changes
    /// column, each boxed from the glyphs it holds.
    fn split(&self, page: u32, text: &RawTextPage, start: usize, end: usize) -> Vec<EntryFragment> {
        let start = start.min(text.chars.len());
        let end = end.min(text.chars.len());
        if start >= end {
            return Vec::new();
        }
        let whole = EntryFragment {
            page,
            start,
            end,
            rect: union_of(&text.chars[start..end])
                .unwrap_or_else(|| Rect::new(0.0, 0.0, 0.0, 0.0)),
        };
        let Some(gutter) = self.gutter else {
            return vec![whole];
        };

        // Which side of the gutter each visible character sits on, taken from the paragraph it
        // belongs to. The paragraph decides, not the glyph: a glyph box can be degenerate (a
        // space PDFium gives no advance), while a line box is what the gutter test measured.
        let entry_lines: Vec<TextLine> = self
            .lines
            .iter()
            .filter(|line| holds_visible(line, text, start, end))
            .cloned()
            .collect();
        if entry_lines.is_empty() {
            return vec![whole];
        }
        let mut sides: Vec<Option<Side>> = vec![None; end - start];
        for block in blocks_from(&entry_lines, BLOCK_GAP_FACTOR) {
            let side = match side_of(block.rect, gutter) {
                // A block crossing the gutter means the gutter test and the blocks disagree;
                // then no cut is trustworthy and the entry keeps the single box it had before.
                Side::Crossing => return vec![whole],
                side => side,
            };
            for line in &block.lines {
                let from = (line.range.start as usize).max(start);
                let to = (line.range.end as usize).min(end);
                for (offset, slot) in sides
                    .iter_mut()
                    .enumerate()
                    .take(to - start)
                    .skip(from - start)
                {
                    if is_visible(text, start + offset) {
                        *slot = Some(side);
                    }
                }
            }
        }

        // Cut the range where the side changes. Runs, not blocks: a run is what one fragment can
        // name with a contiguous glyph range.
        let mut runs: Vec<(usize, usize, Side)> = Vec::new();
        for index in start..end {
            let Some(side) = sides[index - start] else {
                continue;
            };
            match runs.last_mut() {
                Some((_, run_end, run_side)) if *run_side == side => *run_end = index + 1,
                _ => runs.push((index, index + 1, side)),
            }
        }
        if runs.len() < 2 {
            return vec![whole];
        }

        let mut fragments = Vec::with_capacity(runs.len());
        for (position, run) in runs.iter().enumerate() {
            let from = if position == 0 { start } else { run.0 };
            let to = runs.get(position + 1).map(|next| next.0).unwrap_or(end);
            let Some(rect) = union_of_visible(&text.chars[from..to]) else {
                return vec![whole];
            };
            // A fragment that crossed the gutter would be the very bug fragments exist to
            // remove; hand the entry back as a single box instead of inventing a wrong cut.
            if side_of(rect, gutter) != run.2 {
                return vec![whole];
            }
            fragments.push(EntryFragment {
                page,
                start: from,
                end: to,
                rect,
            });
        }
        fragments
    }
}

/// Whether the page carries nothing but whitespace after `end`.
fn ends_at_page_end(text: &RawTextPage, end: usize) -> bool {
    text.chars
        .get(end..)
        .is_some_and(|rest| rest.iter().all(|character| !visible(character)))
}

/// Whether the candidate continuation ends where the next entry's label begins.
///
/// Running heads, page numbers and margin line numbers pass the tests a continuation has to pass
/// — they stand at the head of the page, and their glyphs come first in the content stream — but
/// they do not stop at the next entry's label: a line number runs down the whole page beside it,
/// a running head sits above the body, a figure caption belongs to the figure. The label's own
/// line is where the entry's words end, so no line of the entry may start below it. The page's own
/// line spacing is the unit of slack, so a bibliography that leaves a line between entries is not
/// mistaken for one that carries a head.
fn stays_in_flow(
    shapes: &PageGeometry,
    text: &RawTextPage,
    start: usize,
    end: usize,
    next_start: usize,
) -> bool {
    let Some(next_line) = shapes.lines.iter().find(|line| {
        (line.range.start as usize) <= next_start && next_start < (line.range.end as usize)
    }) else {
        return true;
    };
    let limit = next_line.rect.origin.y - FLOW_SLACK_PITCHES * shapes.pitch();
    shapes
        .lines
        .iter()
        .filter(|line| holds_visible(line, text, start, end))
        .filter(|line| shapes.same_column(line.rect, next_line.rect))
        .all(|line| line.rect.origin.y >= limit)
}

/// Median height of the visible lines, the page's unit of vertical distance.
fn median_line_height(lines: &[TextLine]) -> f64 {
    let mut heights: Vec<f64> = lines
        .iter()
        .map(|line| line.rect.size.height)
        .filter(|height| *height > 0.0)
        .collect();
    if heights.is_empty() {
        return 10.0;
    }
    heights.sort_by(f64::total_cmp);
    heights[heights.len() / 2]
}

/// Whether the line holds at least one visible character inside `start..end`.
fn holds_visible(line: &TextLine, text: &RawTextPage, start: usize, end: usize) -> bool {
    let from = (line.range.start as usize).max(start);
    let to = (line.range.end as usize).min(end);
    (from..to).any(|index| is_visible(text, index))
}

/// The characters before `limit` that continue an entry from the previous page.
///
/// Leading whitespace is skipped, and a repeated bibliography heading (`References`,
/// `Bibliography`, …) is not part of an entry. `None` when nothing but page furniture stands
/// before `limit`.
fn continuation_range(text: &RawTextPage, limit: usize) -> Option<(usize, usize)> {
    let limit = limit.min(text.chars.len());
    let mut position = 0usize;
    loop {
        position = (position..limit).find(|index| is_visible(text, *index))?;
        let line_end = (position..limit)
            .find(|index| is_line_break(text, *index))
            .unwrap_or(limit);
        let line = decode(text, position, line_end);
        if crate::looks_like_reference_heading(&line) {
            position = line_end + 1;
            continue;
        }
        return Some((position, limit));
    }
}

/// The text of `from..to`, collapsed the way the parsers collapse an entry's body.
fn collapse(text: &RawTextPage, from: usize, to: usize) -> String {
    decode(text, from, to)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn decode(text: &RawTextPage, from: usize, to: usize) -> String {
    text.chars
        .get(from.min(text.chars.len())..to.min(text.chars.len()))
        .unwrap_or_default()
        .iter()
        .filter_map(|character| char::from_u32(character.unicode))
        .collect()
}

fn is_line_break(text: &RawTextPage, index: usize) -> bool {
    text.chars
        .get(index)
        .and_then(|character| char::from_u32(character.unicode))
        .is_some_and(|character| matches!(character, '\n' | '\r'))
}

fn is_visible(text: &RawTextPage, index: usize) -> bool {
    text.chars.get(index).is_some_and(visible)
}

fn visible(character: &RawCharBox) -> bool {
    char::from_u32(character.unicode).is_some_and(|character| !character.is_whitespace())
}

fn union_of(chars: &[RawCharBox]) -> Option<Rect> {
    chars
        .iter()
        .map(|character| character.rect)
        .reduce(Rect::union)
}

fn union_of_visible(chars: &[RawCharBox]) -> Option<Rect> {
    chars
        .iter()
        .filter(|character| visible(character))
        .map(|character| character.rect)
        .reduce(Rect::union)
}

fn side_of(rect: Rect, gutter: f64) -> Side {
    if rect.max_x() <= gutter + SIDE_TOLERANCE_PT {
        Side::Left
    } else if rect.origin.x >= gutter - SIDE_TOLERANCE_PT {
        Side::Right
    } else {
        Side::Crossing
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use aris_reader_core::{PageIndex, Point};

    /// A page built from `(x, top, text)` lines, in content-stream order.
    ///
    /// Every glyph is 5 pt wide and 10 pt tall, so a line's box is `x … x + 5 × length` with its
    /// top edge at `top`; each line ends with a newline character, which is what the parsers
    /// split entries on.
    fn page(number: u32, lines: &[(f64, f64, &str)]) -> RawTextPage {
        let mut chars = Vec::new();
        let mut text = String::new();
        for (x, top, line) in lines {
            let mut push = |x: f64, character: char| {
                chars.push(RawCharBox {
                    rect: Rect::new(x, top - 10.0, 5.0, 10.0),
                    origin: Point::new(x, top - 10.0),
                    unicode: character as u32,
                    font_size: 10.0,
                    angle: 0.0,
                    font_name: "Body".to_string(),
                });
            };
            for (column, character) in line.chars().enumerate() {
                push(x + column as f64 * 5.0, character);
            }
            push(x + line.chars().count() as f64 * 5.0, '\n');
            text.push_str(line);
            text.push('\n');
        }
        RawTextPage {
            page: PageIndex(number),
            chars,
            text,
            is_generated: false,
            has_unicode_map_error: false,
        }
    }

    fn gutter_of(page: &RawTextPage) -> f64 {
        crate::tables::column_gutter(&lines_from(page), None).expect("the fixture shows a gutter")
    }

    /// A two-column bibliography page: entries 1–4, 5 pt glyphs, columns at x=50 and x=320.
    fn two_columns() -> RawTextPage {
        page(
            0,
            &[
                (50.0, 700.0, "[1] Alpha 2020. A study that"),
                (50.0, 688.0, "begins in the left column and"),
                (50.0, 676.0, "then carries on into the right"),
                (50.0, 664.0, "column, ending on its first line."),
                (320.0, 700.0, "which is this one right here."),
                (320.0, 688.0, "[2] Beta 2021. Second work."),
                (320.0, 676.0, "[3] Gamma 2019. Third work."),
                (320.0, 664.0, "[4] Delta 2018. Fourth work."),
            ],
        )
    }

    fn references(pages: &[(u32, &RawTextPage)]) -> Vec<ReferenceEntry> {
        crate::find_references(pages.iter().map(|(number, text)| (*number, *text)), 100)
    }

    #[test]
    fn an_entry_inside_one_column_stays_one_fragment() {
        // Entry 1 lives entirely in the left column; the right column starts with entry 2.
        let text = page(
            0,
            &[
                (50.0, 700.0, "[1] Alpha 2020. First work that"),
                (50.0, 688.0, "fits inside the left column."),
                (320.0, 700.0, "[2] Beta 2021. Second work."),
                (320.0, 688.0, "[3] Gamma 2019. Third work."),
                (320.0, 676.0, "[4] Delta 2018. Fourth work."),
                (320.0, 664.0, "[5] Epsilon 2017. Fifth work."),
            ],
        );
        let entries = references(&[(0, &text)]);
        assert_eq!(entries.len(), 5, "{entries:?}");

        let entry = &entries[0];
        assert_eq!(entry.label, "1");
        assert_eq!(entry.fragments.len(), 1, "{:?}", entry.fragments);
        // One fragment covers the entry exactly as `start..end` always did.
        assert_eq!(entry.fragments[0].page, 0);
        assert_eq!(entry.fragments[0].start, entry.start);
        assert_eq!(entry.fragments[0].end, entry.end);
        assert_eq!(
            entry.fragments[0].rect,
            union_of(&text.chars[entry.start..entry.end]).unwrap()
        );
        // And it stays on its own side of the gutter.
        assert!(entry.fragments[0].rect.max_x() <= gutter_of(&text) + SIDE_TOLERANCE_PT);
    }

    #[test]
    fn an_entry_split_across_two_columns_becomes_two_fragments() {
        let text = two_columns();
        let entries = references(&[(0, &text)]);
        assert_eq!(entries.len(), 4, "{entries:?}");

        let entry = &entries[0];
        assert_eq!(entry.label, "1");
        assert!(
            entry.text.contains("ending on its first line"),
            "{}",
            entry.text
        );
        assert_eq!(entry.fragments.len(), 2, "{:?}", entry.fragments);

        let gutter = gutter_of(&text);
        let [left, right] = [entry.fragments[0], entry.fragments[1]];
        // The cut is between the columns, in reading order, and covers the entry once.
        assert_eq!(left.page, 0);
        assert_eq!(right.page, 0);
        assert_eq!(left.start, entry.start);
        assert_eq!(right.end, entry.end);
        assert_eq!(left.end, right.start);
        assert!(left.rect.max_x() <= gutter + SIDE_TOLERANCE_PT, "{left:?}");
        assert!(
            right.rect.origin.x >= gutter - SIDE_TOLERANCE_PT,
            "{right:?}"
        );
        // The left piece ends at the foot of the left column, the right piece starts at the top
        // of the right one — a box drawn for either never spans the gutter.
        assert!(
            left.rect.origin.y < right.rect.origin.y,
            "{left:?} {right:?}"
        );
        assert!(left.rect.size.width > 0.0 && right.rect.size.width > 0.0);
    }

    #[test]
    fn an_entry_continuing_on_the_next_page_gets_a_fragment_there() {
        let first = page(
            0,
            &[
                (50.0, 700.0, "[1] Alpha 2020. First work here."),
                (50.0, 688.0, "[2] Beta 2021. Second work whose"),
                (50.0, 676.0, "text runs off the bottom of it."),
            ],
        );
        let second = page(
            1,
            &[
                (50.0, 700.0, "and finishes at the top of this one."),
                (50.0, 688.0, "[3] Gamma 2019. Third work here."),
                (50.0, 676.0, "[4] Delta 2018. Fourth work here."),
            ],
        );
        let entries = references(&[(0, &first), (1, &second)]);
        assert_eq!(entries.len(), 4, "{entries:?}");

        let entry = &entries[1];
        assert_eq!(entry.label, "2");
        // The text now says what the entry actually says, and where it says it.
        assert!(
            entry.text.ends_with("and finishes at the top of this one."),
            "{}",
            entry.text
        );
        assert_eq!(entry.fragments.len(), 2, "{:?}", entry.fragments);
        assert_eq!(entry.fragments[0].page, 0);
        assert_eq!(entry.fragments[1].page, 1);
        assert_eq!(entry.fragments[0].start, entry.start);
        assert_eq!(entry.fragments[0].end, entry.end);
        assert_eq!(entry.fragments[1].start, 0);
        // The continuation stops where entry 3 starts, not at the end of the page.
        assert_eq!(
            entry.fragments[1].end, entries[2].start,
            "the continuation must stop at the next entry's label"
        );
        assert!(entry.fragments[1].rect.origin.y > 680.0);
    }

    #[test]
    fn a_repeated_heading_is_not_a_continuation() {
        // Both pages repeat the list's heading, as a thesis whose bibliography runs over pages
        // with a running header does; the header is furniture, not the previous entry's text.
        let first = page(
            0,
            &[
                (50.0, 700.0, "References"),
                (50.0, 688.0, "[1] Alpha 2020. First work here."),
                (50.0, 676.0, "[2] Beta 2021. Second work whose"),
                (50.0, 664.0, "text runs off the bottom of it."),
            ],
        );
        let second = page(
            1,
            &[
                (50.0, 700.0, "References"),
                (50.0, 688.0, "[3] Gamma 2019. Third work here."),
                (50.0, 676.0, "[4] Delta 2018. Fourth work here."),
            ],
        );
        let entries = references(&[(0, &first), (1, &second)]);
        assert_eq!(entries.len(), 4, "{entries:?}");
        let entry = entries
            .iter()
            .find(|entry| entry.label == "2")
            .expect("entry");
        assert_eq!(entry.fragments.len(), 1, "{:?}", entry.fragments);
        assert!(entry.fragments[0].page == 0);
        assert!(!entry.text.contains("References"), "{}", entry.text);
    }

    #[test]
    fn an_entry_that_ends_mid_page_does_not_reach_the_next_page() {
        // Entry 2 is followed by entry 3 on its own page, so the unlabelled line at the head of
        // page 1 belongs to nobody it can prove: it is not part of entry 2.
        let first = page(
            0,
            &[
                (50.0, 700.0, "[1] Alpha 2020. First work here."),
                (50.0, 688.0, "[2] Beta 2021. Second work here."),
                (50.0, 676.0, "[3] Gamma 2019. Third work here."),
            ],
        );
        let second = page(
            1,
            &[
                (50.0, 700.0, "a stray line of body text."),
                (50.0, 688.0, "[4] Delta 2018. Fourth work here."),
                (50.0, 676.0, "[5] Epsilon 2017. Fifth work here."),
            ],
        );
        let entries = references(&[(0, &first), (1, &second)]);
        let entry = entries
            .iter()
            .find(|entry| entry.label == "2")
            .expect("entry");
        assert_eq!(entry.fragments.len(), 1, "{:?}", entry.fragments);
        assert!(entry.fragments[0].page == 0);
        assert!(!entry.text.contains("stray line"), "{}", entry.text);
    }
}
