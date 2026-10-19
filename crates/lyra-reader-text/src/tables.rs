//! Locating a table's **grid**, so a `Table N` preview shows the table instead of the page.
//!
//! # Why this is not [`crate::caption_region`]'s image search
//!
//! A figure is usually an image XObject, and `caption_region` finds it by looking just above the
//! caption. A table has no object of any kind — PDF models no table and no cell — and its caption
//! conventionally sits *above* the artwork, so the look-upward rule finds nothing and the preview
//! falls back to the full page. The table is nonetheless drawn: its borders are lines, and lines
//! are in the page's vector geometry. This module reads them.
//!
//! # What counts as a table
//!
//! Three independent things have to agree, and each one rejects a different kind of false
//! positive:
//!
//! 1. **Rules form a grid.** Segments are merged into distinct *levels* (two collinear rules
//!    within [`LEVEL_TOLERANCE_PT`] are one line), and a grid needs at least
//!    [`MIN_HORIZONTAL_LEVELS`] horizontal levels; the strong tier additionally needs
//!    [`MIN_VERTICAL_LEVELS`] vertical rules that **span** them. Rules piled at one y, or a lone
//!    rectangle, are not a grid.
//! 2. **The grid is regularly spaced.** Consecutive levels are rows: closer than
//!    [`MIN_LEVEL_GAP_PT`] and they are one line drawn twice, further than [`MAX_ROW_PITCH_PT`]
//!    and they belong to another block. This is what stops a page's unrelated rules from being
//!    chained into one enormous band.
//! 3. **Its cells contain text.** This is the check that separates a table from a figure made of
//!    lines — a chart's gridlines and a diagram's frame are also regular horizontal rules, but
//!    their captions do not sit above a block of text arranged in rows and columns.
//!
//! # Measured false-positive pressure
//!
//! The sample corpus is what forced the shape above, and two simpler rules failed on it:
//!
//! * *Counting rules* says nothing: pages carry 0–112 horizontal rules, and by count alone a
//!   border and a piece of vector art are the same thing.
//! * *Counting rule pairs* produced 35,766 candidates for one paper; merging them into regions
//!   before counting is what makes the number mean anything, so a grid here is a region, never a
//!   pair.
//! * *Clustering the page into bands and taking the band nearest the caption* merged one wide
//!   table with three narrow ones underneath it on `Zhang et al. 2025` page 7, and gave `Table 3`
//!   a 455 pt-wide region covering its two neighbours. The fix is to start from the border rule
//!   the caption touches and grow only through rules contained in the extent already found.
//!
//! # What it finds, measured
//!
//! `lyra-reader-cli tables <the 12 sample papers>`, 2026-10-13: **41 `Table` captions, 20 of them
//! with a grid region, 21 falling back to the full page**. T4.12 removed one of the 41 on
//! 2026-10-17 — page 9 of the Leader paper prints `… before and after correction in / Table 3.
//! Our correction …`, and that label is the end of a prose sentence — so the count is now **40
//! captions, the same 20 with a grid region, 20 fallbacks**. Region sizes: width min 241 / median
//! 396 / max 504 pt, height min 67 / median 121 / max 234 pt — a table-sized rectangle, not a
//! page (612 × 792 pt).
//!
//! | Paper | `Table` captions | grid regions |
//! | --- | --- | --- |
//! | `manuscript_0925.pdf` | 13 | 8 |
//! | `Zhang et al. 2025` (HumanMM) | 7 | 1 |
//! | `Ye et al. 2024` | 6 | 4 |
//! | `[HumanML3D] Guo …` | 4 | 3 |
//! | `Wang et al. 2025` (Leader) | 3 | 0 |
//! | `Wang et al. 2025` (InstructAvatar) | 3 | 1 |
//! | `Zhong et al. 2025` (SMooDi) | 3 | 3 |
//! | `Yin et al. 2023` | 1 | 0 |
//! | the other four papers | 0 | 0 |
//!
//! Nineteen of the twenty regions were checked by rendering the page and cropping to the
//! rectangle: each is one table together with its caption, with no neighbouring table and no
//! figure. The twentieth, `Zhang et al. 2025` page 7 `Table 2`, was fixed by the anchor rule
//! above and is now a fallback like its two neighbours.
//!
//! The 20 fallbacks are **not** 20 failures of the detector: the CLI prints the reason for each.
//! They split into tables with too few rules to be a grid (a two-rule `booktabs` table has one
//! row), three small tables that share full-width rules as their borders (`Zhang`, pages 7–8),
//! and pages where the caption is narrower than its table by more than half again.
//!
//! # Honest limits
//!
//! * **Tables with no vertical rules.** `booktabs`-style tables have three horizontal rules and
//!   no verticals at all; on this corpus that is the largest single group, and 8 of the 13 in
//!   `manuscript_0925.pdf` are found through the text tier. The other five have rules that do not
//!   stack into rows at all (two-rule tables), and no rule-based method can see a table that is
//!   not drawn.
//! * **A caption much narrower than its table.** The border rule is required to be no wider than
//!   the caption plus half again, which is what stops a full-width rule from being taken for a
//!   small table's border. A one-line centred caption under a wide table is therefore lost.
//! * **A caption on the far side of a column gutter** is not accepted: a grid in one column under
//!   a caption in the other would show the wrong column's table. A full-width table — which covers
//!   the gutter, as its caption does — is *not* that case and is returned.
//! * **A grid is not a table.** A ruled box holding text — a framed algorithm, a sidebar —
//!   satisfies every test here. The region is still a better preview than the whole page, but the
//!   word `Table` on it comes from the caption, not from this code.
//! * **Nothing is invented.** When no grid is found the answer is `None` and the caller keeps
//!   today's fallback; there is no synthetic box around the caption.

use lyra_reader_core::{LineSegment, Rect};

use crate::{Caption, InkRun, TextLine};

/// How far off an axis a segment may lie and still be read as a rule (points).
pub const AXIS_TOLERANCE_PT: f64 = 1.0;

/// Shortest segment that can take part in a grid (points).
///
/// Below this a "rule" is a glyph-sized mark — an underline, a fraction bar, a tick. Cell
/// separators on this corpus measure ≥ 17 pt; the floor is set well under that.
pub const MIN_RULE_LENGTH_PT: f64 = 8.0;

/// Two collinear rules closer than this are the same grid line (points).
pub const LEVEL_TOLERANCE_PT: f64 = 2.0;

/// Two rules on one level with a gap this small join into a single rule (points).
///
/// A table's border is routinely emitted as several collinear segments, one per cell.
pub const RULE_JOIN_GAP_PT: f64 = 6.0;

/// Closer than this and two levels are one line drawn twice, not two rows (points).
pub const MIN_LEVEL_GAP_PT: f64 = 4.0;

/// Further apart than this and two horizontal rules are not rows of the same table (points).
///
/// Measured, not guessed. A rule in a `booktabs` table is a **group separator**, not a row
/// separator: on page 7 of `manuscript_0925.pdf` the rule under the header is 15 pt below the top
/// rule, and the next rule is 69 pt below that because six data rows sit between them. With a
/// 60 pt bound the band stopped after three rules, the grid came out 41 pt tall, and the table
/// was rejected for holding too little text — the caption fell back to the full page while its
/// table was plainly drawn. 100 pt also admits a row that holds a small piece of artwork, while
/// refusing the 121 pt jump from `SMooDi` page 13's `Table 3` into the artwork of `Fig. 6`.
pub const MAX_ROW_PITCH_PT: f64 = 100.0;

/// A gap wider than this between two rules only counts as a row when it holds text (points).
///
/// Two body lines: a table row taller than this is holding something other than one line of type.
pub const WIDE_GAP_PT: f64 = 30.0;

/// Share of the narrower rule that two horizontal rules must overlap to be rows of one table.
pub const ROW_OVERLAP_SHARE: f64 = 0.5;

/// How far a rule may stick out of the extent found so far and still join the same table
/// (points). This is the tolerance for stroke ends and rounding, not for a wider table.
pub const CONTAIN_TOLERANCE_PT: f64 = 10.0;

/// A grid needs three horizontal rules: two rows is the smallest thing anyone calls a table.
pub const MIN_HORIZONTAL_LEVELS: usize = 3;

/// The strong tier needs two vertical rules: the borders of one column of cells.
pub const MIN_VERTICAL_LEVELS: usize = 2;

/// Shortest grid worth previewing (points).
pub const MIN_GRID_WIDTH_PT: f64 = 60.0;

/// How far a vertical rule may sit beyond the horizontal rules' span and still belong to the
/// grid (points).
pub const VERTICAL_REACH_PT: f64 = 8.0;

/// How far the caption's first line may sit from the border rule it labels (points).
///
/// The window is wide because what the text layer marks as a caption is its **first line**: a
/// four-line caption paragraph already puts the table 60 pt away. Containment in [`grow_band`] is
/// what actually keeps a distant rule from being adopted, not this bound.
pub const MAX_CAPTION_GAP_PT: f64 = 200.0;

/// A rule wider than the caption by more than this share of the caption is not its table's
/// border, and is only tried when nothing narrower works.
///
/// A caption is set to the width of the table it labels, or narrower; a rule that overshoots it
/// by half again belongs to something else. On `Zhang et al. 2025` pages 7 and 8 the three small
/// tables at the foot of the page share full-width rules as their top border, and the rule
/// *nearest* each caption is that shared one — taking it made `Table 2` a 493 pt-wide region
/// covering the wide table above and both of its neighbours.
pub const ANCHOR_OVERHANG_SHARE: f64 = 0.5;

/// Fixed part of the same allowance, so a very short caption is not held to its own width
/// (points).
pub const ANCHOR_OVERHANG_PT: f64 = 20.0;

/// How much further than the closest one a rule may be and still be tried as the caption's
/// border (points).
///
/// The table's border rule is the nearest rule on the far side of the caption, so once one is in
/// reach the alternatives are only rounding differences — two rules a hair apart, or a doubled
/// border. Without this bound the search walks on to the *next* table's border: on
/// `Zhang et al. 2025` page 7 that gave `Table 2` — whose own table has two rules, not three — a
/// 493 pt-wide region belonging to the wide table above it.
pub const MAX_ANCHOR_SLACK_PT: f64 = 12.0;

/// Share of the narrower box that caption and grid must overlap horizontally.
pub const CAPTION_OVERLAP_SHARE: f64 = 0.3;

/// Fewest text lines inside a grid for it to be a table rather than a frame.
pub const MIN_CELL_LINES: usize = 3;

/// Row bands that must hold text before a grid without vertical rules is believed.
///
/// A ruled frame around a diagram holds one or two labels; a table holds a line of data per row.
/// Three is the smallest count that is a pattern rather than a coincidence.
pub const MIN_OCCUPIED_ROWS_WITHOUT_VERTICALS: usize = 3;

/// Columns of text that must appear when the grid has no vertical rules to show them.
pub const MIN_TEXT_COLUMNS_WITHOUT_VERTICALS: usize = 2;

/// Lines a single text column must hold to count as one.
pub const MIN_LINES_PER_TEXT_COLUMN: usize = 2;

/// Tolerance when clustering text left edges into columns (points).
pub const TEXT_COLUMN_TOLERANCE_PT: f64 = 6.0;

/// A gutter narrower than this is a wide space, not a column boundary (points).
pub const GUTTER_MIN_WIDTH_PT: f64 = 14.0;

/// Fewest lines a page must show before its column structure is read at all.
///
/// Below this there is not enough text to tell a column from a caption, and the answer that costs
/// nothing — "no gutter" — is the right one.
pub const MIN_GUTTER_LINES: usize = 6;

/// How far from the middle of the body a column boundary may sit, as a share of the body width.
///
/// A two-column page is set with two balanced columns, so its gutter straddles the middle of the
/// text block: measured on the twelve sample papers, every gutter found sits within 1% of the
/// body's centre. Anything further out is a ragged right margin, a gap beside a figure, or the
/// edge of a table — not a boundary between columns of body text.
pub const GUTTER_CENTRE_SHARE: f64 = 0.05;

/// A line at least this share of the body wide is a full-width element, not column text.
///
/// A figure caption, a paper title, a wide equation and a table rule all cross a gutter. They are
/// why the detector may not simply require that *no* line crosses the boundary.
pub const SPANNER_WIDTH_SHARE: f64 = 0.8;

/// A line narrower than this is a mark, not text (points).
///
/// Superscripts, formula fragments and stray glyphs of a broken text layer sit in the gutter
/// without being a column of text; a line this short carries no words.
pub const STRAY_WIDTH_PT: f64 = 12.0;

/// Share of the page's lines that may be *ordinary text* inside the boundary.
///
/// Deliberately near zero: two columns of text do not overlap each other, so any line of body
/// text lying in the strip means the strip is not a gutter between columns. What the share
/// absorbs is extraction noise — a line whose box runs a few points past its column edge.
pub const MAX_TEXT_LINES_IN_GUTTER_SHARE: f64 = 0.02;

/// Share of the page's lines that must stop at the boundary's left edge, and start after its
/// right edge, for the boundary to be a column edge rather than a hole in the page.
///
/// A fifth each side is the guard the previous version of this function used; it survives every
/// measurement below unchanged.
pub const MIN_GUTTER_SIDE_SHARE: f64 = 0.2;

/// Share of the page's lines that may reach into the boundary *at all*, spanners included.
///
/// This is the "the lines that respect it clearly dominate" half of the test. Without it a
/// single-column page of full-width prose passes every other guard, because on such a page every
/// line is "wide enough to be a spanner" and a strip through the middle of the text still has a
/// fifth of the lines ending before it and a fifth starting after it. Measured on the corpus:
/// capping the crossings at a tenth keeps all 52 gutter pages and drops the 21 single-column
/// pages a looser cap produced.
pub const MAX_CROSSING_LINES_SHARE: f64 = 0.1;

/// How far outside the boundary a line may end or start and still count as being on that side
/// (points).
pub const GUTTER_EDGE_TOLERANCE_PT: f64 = 0.5;

/// What a grid region rests on.
///
/// Reported rather than hidden because the two tiers have different failure modes, and a reader
/// (or the CLI) is entitled to know which one produced a preview.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GridBasis {
    /// Vertical rules span the rows: the grid is drawn, not inferred.
    Ruled,
    /// No vertical rules (`booktabs` style). The grid is accepted because the text inside it is
    /// itself arranged in rows and columns, which is the only evidence such a table offers.
    TextOnly,
}

/// What the grid search found for a caption — the region when there is one, and otherwise the
/// check that stopped it.
///
/// This is how "the preview fell back to the page" becomes a number instead of a shrug: the CLI
/// counts these, and the corpus report is a breakdown of them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GridOutcome {
    /// A ruled grid: vertical rules span the rows.
    Ruled,
    /// A grid with no vertical rules, believed because its cells hold rows and columns of text.
    TextOnly,
    /// The page draws no horizontal rule near the caption, or too few to make rows.
    NoRules,
    /// Rules are near the caption, but they do not stack into [`MIN_HORIZONTAL_LEVELS`] levels
    /// within [`MAX_ROW_PITCH_PT`] of one another.
    NotEnoughRows,
    /// A grid-shaped candidate whose cells hold too little text to be a table.
    NoTextInCells,
    /// A grid-shaped candidate on the far side of the page's gutter from its caption.
    CrossesColumn,
    /// A grid-shaped candidate narrower than [`MIN_GRID_WIDTH_PT`].
    TooNarrow,
}

impl GridOutcome {
    /// Whether this outcome produced a region.
    pub fn is_grid(self) -> bool {
        matches!(self, Self::Ruled | Self::TextOnly)
    }

    /// Which evidence the region rested on, when there is one.
    pub fn basis(self) -> Option<GridBasis> {
        match self {
            Self::Ruled => Some(GridBasis::Ruled),
            Self::TextOnly => Some(GridBasis::TextOnly),
            _ => None,
        }
    }

    /// A stable, printable name (used by the CLI report).
    pub fn label(self) -> &'static str {
        match self {
            Self::Ruled => "ruled",
            Self::TextOnly => "text-only",
            Self::NoRules => "no rules near the caption",
            Self::NotEnoughRows => "rules do not stack into rows",
            Self::NoTextInCells => "candidate grid holds no text",
            Self::CrossesColumn => "candidate grid crosses the column gutter",
            Self::TooNarrow => "candidate grid too narrow",
        }
    }
}

/// A run of collinear axis-aligned rules merged into one line.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Rule {
    /// Where the rule sits across its own axis: `y` for a horizontal rule, `x` for a vertical.
    position: f64,
    /// Extent along its own axis, `start <= end`.
    start: f64,
    end: f64,
}

impl Rule {
    fn length(&self) -> f64 {
        self.end - self.start
    }

    fn overlaps(&self, other: &Rule) -> f64 {
        self.end.min(other.end) - self.start.max(other.start)
    }
}

/// The region of a page a `Table` caption's floating preview should show.
///
/// `segments` is the page's axis-aligned vector geometry
/// ([`lyra_reader_core::LineSegment`]s, as `PdfiumBackend::page_line_segments` returns them) and
/// `lines` is the page's text layer grouped into lines ([`crate::lines_from`]).
///
/// Returns `Some(region)` only when a grid was found *and* the text inside it confirms it. The
/// region is the union of that grid with the caption, so the preview carries the label the reader
/// clicked; it is clamped to `page_bounds`.
///
/// Returns `None` when there is no grid — the caller keeps whatever fallback it uses today (the
/// full visible page), because a caption-only crop would claim the caption is the table.
pub fn table_region(
    caption: &Caption,
    segments: &[LineSegment],
    lines: &[TextLine],
    page_bounds: Rect,
) -> Option<Rect> {
    table_region_with_basis(caption, segments, lines, page_bounds).map(|(region, _)| region)
}

/// [`table_region`], plus which evidence the grid rested on.
pub fn table_region_with_basis(
    caption: &Caption,
    segments: &[LineSegment],
    lines: &[TextLine],
    page_bounds: Rect,
) -> Option<(Rect, GridBasis)> {
    if caption.kind != "Table" {
        return None;
    }
    let (grid, outcome) = nearest_grid(caption, segments, lines);
    let (grid, basis) = grid.zip(outcome.basis())?;
    Some((clamp_to_page(grid.union(caption.rect), page_bounds), basis))
}

/// What the grid search found for a caption, region included.
///
/// The same search [`table_region`] runs, with the reason it stopped made explicit. A caller
/// that only wants the region should not use this; a caller that reports *how often* table
/// previews fall back — the CLI — should, because "no rules at all" and "rules that are not a
/// grid" are different problems.
pub fn table_outcome(
    caption: &Caption,
    segments: &[LineSegment],
    lines: &[TextLine],
) -> (GridOutcome, Option<Rect>) {
    if caption.kind != "Table" {
        return (GridOutcome::NoRules, None);
    }
    let (grid, outcome) = nearest_grid(caption, segments, lines);
    (outcome, grid)
}

/// The grid a caption labels, and how that search went.
///
/// # Why this anchors on the caption instead of clustering the page
///
/// The first version of this clustered every rule on the page into bands and then took the band
/// nearest the caption. On `Zhang et al. 2025` page 7 — one wide ruled table above three narrow
/// ones — it merged all four into a single band and gave `Table 3` a 455 pt-wide region covering
/// its two neighbours. Rules that merely *line up* are not one table.
///
/// The anchored version starts from the rule the caption touches (its own border) and grows only
/// through rules **contained in the extent already found**, so a wider table above or a
/// side-by-side table beside it cannot be absorbed. Only rules within
/// [`MAX_ANCHOR_SLACK_PT`] of the nearest one are tried: the border rule is the closest rule on
/// the far side of the caption, and a rule much further away belongs to something else. Without
/// that bound the search walks on to the next table's border and answers with the wrong table.
fn nearest_grid(
    caption: &Caption,
    segments: &[LineSegment],
    lines: &[TextLine],
) -> (Option<Rect>, GridOutcome) {
    let (horizontal, vertical) = rules_from(segments);
    if horizontal.len() < MIN_HORIZONTAL_LEVELS {
        return (None, GridOutcome::NoRules);
    }

    // A caption is set to the width of the table it labels, or narrower. A rule that overshoots
    // it by half again is some other table's border or the page's own furniture, and taking it is
    // how the three small tables at the foot of `Zhang et al. 2025` pages 7 and 8 — which share
    // full-width rules as their top and bottom borders — each got a 493 pt-wide region covering
    // the wide table above them and both of their neighbours.
    let allowance = caption.rect.size.width * (1.0 + ANCHOR_OVERHANG_SHARE) + ANCHOR_OVERHANG_PT;
    let mut anchors: Vec<(f64, &Rule)> = horizontal
        .iter()
        .filter(|rule| rule.length() <= allowance)
        .filter_map(|rule| caption_border_gap(caption, rule).map(|gap| (gap, rule)))
        .collect();
    if anchors.is_empty() {
        return (None, GridOutcome::NoRules);
    }
    anchors.sort_by(|left, right| left.0.total_cmp(&right.0));
    let nearest = anchors[0].0;

    let barriers = caption_barriers(lines, caption);
    let rows: Vec<f64> = lines.iter().map(|line| line.rect.center().y).collect();
    let mut outcome = GridOutcome::NotEnoughRows;

    for (gap, anchor) in anchors {
        if gap > nearest + MAX_ANCHOR_SLACK_PT {
            continue;
        }
        // The table is on the far side of its caption, so that is the way the band grows.
        let grow = if anchor.position <= caption.rect.origin.y {
            Direction::Down
        } else {
            Direction::Up
        };
        // A border rule on the far side of another caption is that caption's table, not this one.
        if caption_between(&barriers, anchor.position, caption.rect.center().y) {
            continue;
        }
        let band = grow_band(anchor, grow, &horizontal, &barriers, &rows);
        if band.len() < MIN_HORIZONTAL_LEVELS {
            continue;
        }
        let (grid, basis) = match grid_from_band(&band, &vertical, lines, caption) {
            Ok(found) => found,
            Err(reason) => {
                outcome = reason;
                continue;
            }
        };
        if grid.size.width < MIN_GRID_WIDTH_PT {
            outcome = GridOutcome::TooNarrow;
            continue;
        }
        // A grid on one side of the page's gutter with its caption on the other is not that
        // caption's table: the anchor rule followed a rule across the column boundary, and the
        // preview would show one column's table under the other column's caption. What matters is
        // a *disagreement*, not spanning: a full-width table (a spanner) legitimately covers both
        // columns, and so does its caption, so such a region is the table itself and stays.
        //
        // The gutter is measured without this grid's own cells: they are short lines with gaps
        // between them, which is what a gutter looks like.
        if let Some(gutter) = column_gutter(lines, Some(grid)) {
            let grid_at = side_of_gutter(grid, gutter);
            let caption_at = side_of_gutter(caption.rect, gutter);
            if grid_at != Side::Spanning && caption_at != Side::Spanning && grid_at != caption_at {
                outcome = GridOutcome::CrossesColumn;
                continue;
            }
        }
        return (
            Some(grid),
            match basis {
                GridBasis::Ruled => GridOutcome::Ruled,
                GridBasis::TextOnly => GridOutcome::TextOnly,
            },
        );
    }

    (None, outcome)
}

/// Which way a table grows from the border rule its caption touches.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Direction {
    Up,
    Down,
}

/// Distance from `caption` to a horizontal rule that could be its table's border.
///
/// A table's caption is directly above it or directly below it, so only a rule on the far side of
/// the caption counts, and only within [`MAX_CAPTION_GAP_PT`].
fn caption_border_gap(caption: &Caption, rule: &Rule) -> Option<f64> {
    let overlap = caption.rect.max_x().min(rule.end) - caption.rect.origin.x.max(rule.start);
    if overlap <= 0.0
        || overlap < CAPTION_OVERLAP_SHARE * caption.rect.size.width.min(rule.length())
    {
        return None;
    }
    let below = caption.rect.origin.y - rule.position;
    let above = rule.position - caption.rect.max_y();
    if (0.0..=MAX_CAPTION_GAP_PT).contains(&below) {
        Some(below)
    } else if (0.0..=MAX_CAPTION_GAP_PT).contains(&above) {
        Some(above)
    } else {
        None
    }
}

/// Grows a table's rows from the border rule the caption touches.
///
/// Rules join one at a time, each the next one in `grow`'s direction, and each has to be
/// **contained in the extent found so far** (within [`CONTAIN_TOLERANCE_PT`]) and to overlap the
/// neighbour it attaches to by [`ROW_OVERLAP_SHARE`] of the narrower. Two passes: the first takes
/// the border rule's own extent, the second re-runs with the extent those rules actually span, so
/// a table whose border rule is one column short still collects its full width.
fn grow_band(
    anchor: &Rule,
    grow: Direction,
    horizontals: &[Rule],
    barriers: &[f64],
    rows: &[f64],
) -> Vec<Rule> {
    let first = grow_once(
        anchor,
        grow,
        horizontals,
        (anchor.start, anchor.end),
        barriers,
        rows,
    );
    let span = first.iter().fold((anchor.start, anchor.end), |span, rule| {
        (span.0.min(rule.start), span.1.max(rule.end))
    });
    // Top of the page first: `grid_from_band` reads the band as rows from its top down.
    let mut band = grow_once(anchor, grow, horizontals, span, barriers, rows);
    band.sort_by(|left, right| right.position.total_cmp(&left.position));
    band
}

/// One pass of [`grow_band`] against a fixed `span`.
fn grow_once(
    anchor: &Rule,
    grow: Direction,
    horizontals: &[Rule],
    span: (f64, f64),
    barriers: &[f64],
    rows: &[f64],
) -> Vec<Rule> {
    let mut band = vec![*anchor];
    loop {
        let edge = match grow {
            Direction::Down => band.last().expect("non-empty"),
            Direction::Up => band.first().expect("non-empty"),
        };
        let candidate = horizontals
            .iter()
            .filter(|rule| rule.position != edge.position)
            // Another float's caption ends this table: the rules beyond it are that float's.
            .filter(|rule| !caption_between(barriers, rule.position, edge.position))
            .filter(|rule| {
                let gap = match grow {
                    Direction::Down => edge.position - rule.position,
                    Direction::Up => rule.position - edge.position,
                };
                (MIN_LEVEL_GAP_PT..=MAX_ROW_PITCH_PT).contains(&gap)
            })
            // A gap much taller than a row is only a row if something is written in it. The
            // rules of a figure below a table are within the pitch bound — on `SMooDi` page 13
            // the next rule after the table is 121 pt down, inside the artwork of `Fig. 6` — and
            // nothing is written between them, which is exactly what distinguishes the two.
            .filter(|rule| {
                let gap = (rule.position - edge.position).abs();
                gap <= WIDE_GAP_PT
                    || rows.iter().any(|y| {
                        *y > rule.position.min(edge.position) + 1.0
                            && *y < rule.position.max(edge.position) - 1.0
                    })
            })
            .filter(|rule| rule.start >= span.0 - CONTAIN_TOLERANCE_PT)
            .filter(|rule| rule.end <= span.1 + CONTAIN_TOLERANCE_PT)
            .filter(|rule| {
                let overlap = rule.overlaps(edge);
                overlap > 0.0 && overlap >= ROW_OVERLAP_SHARE * rule.length().min(edge.length())
            })
            .min_by(|left, right| {
                let gap = |rule: &Rule| match grow {
                    Direction::Down => edge.position - rule.position,
                    Direction::Up => rule.position - edge.position,
                };
                gap(left).total_cmp(&gap(right))
            });

        match candidate {
            Some(rule) => {
                if grow == Direction::Down {
                    band.push(*rule);
                } else {
                    band.insert(0, *rule);
                }
            }
            None => break,
        }
    }
    band
}

/// Turns segments into merged horizontal and vertical rules.
fn rules_from(segments: &[LineSegment]) -> (Vec<Rule>, Vec<Rule>) {
    let mut horizontal = Vec::new();
    let mut vertical = Vec::new();

    for segment in segments {
        if segment.length() < MIN_RULE_LENGTH_PT {
            continue;
        }
        if segment.is_horizontal(AXIS_TOLERANCE_PT) {
            horizontal.push(Rule {
                position: segment.from.y,
                start: segment.from.x.min(segment.to.x),
                end: segment.from.x.max(segment.to.x),
            });
        } else if segment.is_vertical(AXIS_TOLERANCE_PT) {
            vertical.push(Rule {
                position: segment.from.x,
                start: segment.from.y.min(segment.to.y),
                end: segment.from.y.max(segment.to.y),
            });
        }
    }

    (merge_rules(horizontal), merge_rules(vertical))
}

/// Merges near-collinear, touching rules into one rule per grid line.
///
/// Two tables side by side on one baseline share a level but not an interval; the merge keeps
/// them apart because the gap between them is larger than [`RULE_JOIN_GAP_PT`].
fn merge_rules(mut rules: Vec<Rule>) -> Vec<Rule> {
    rules.sort_by(|left, right| {
        left.position
            .total_cmp(&right.position)
            .then(left.start.total_cmp(&right.start))
    });

    let mut merged: Vec<Rule> = Vec::new();
    for rule in rules {
        match merged.last_mut() {
            Some(last)
                if (rule.position - last.position).abs() <= LEVEL_TOLERANCE_PT
                    && rule.start <= last.end + RULE_JOIN_GAP_PT =>
            {
                last.end = last.end.max(rule.end);
                last.start = last.start.min(rule.start);
            }
            _ => merged.push(rule),
        }
    }
    merged
}

/// The grid one band describes, or `None` when the band is not a table.
///
/// `lines` and `caption` are the text evidence: the grid's cells must contain text, and a band
/// whose "cells" are empty — or hold a single stray label — is a figure's frame, not a table.
#[allow(clippy::type_complexity)]
fn grid_from_band(
    band: &[Rule],
    verticals: &[Rule],
    lines: &[TextLine],
    caption: &Caption,
) -> Result<(Rect, GridBasis), GridOutcome> {
    let (top, bottom) = band_ends(band)?;
    let (mut left, mut right) = median_span(band);

    // Vertical rules that span the band from its lowest to its highest row line. A vertical that
    // stops half way belongs to another table, or to a figure.
    let spanning: Vec<f64> = verticals
        .iter()
        .filter(|rule| rule.start <= bottom + LEVEL_TOLERANCE_PT)
        .filter(|rule| rule.end >= top - LEVEL_TOLERANCE_PT)
        .filter(|rule| {
            rule.position >= left - VERTICAL_REACH_PT && rule.position <= right + VERTICAL_REACH_PT
        })
        .map(|rule| rule.position)
        .collect();
    let ruled = spanning.len() >= MIN_VERTICAL_LEVELS;
    if ruled {
        left = left.min(spanning.iter().copied().fold(f64::MAX, f64::min));
        right = right.max(spanning.iter().copied().fold(f64::MIN, f64::max));
    }

    let grid = Rect::new(left, bottom, right - left, top - bottom);
    let inside = text_inside(grid, lines, caption);
    if inside.len() < MIN_CELL_LINES {
        return Err(GridOutcome::NoTextInCells);
    }

    let occupied = occupied_rows(&inside, band);
    if ruled {
        // The vertical rules already show that this is a grid of cells; the text only has to be
        // in more than one row of it.
        if occupied < 2 {
            return Err(GridOutcome::NoTextInCells);
        }
        return Ok((grid, GridBasis::Ruled));
    }

    // No vertical rules to show the columns, so the text itself has to: several rows, and more
    // than one column of them. This is the `booktabs` case and the strictest test in the module,
    // because nothing else distinguishes it from a framed diagram.
    if occupied < MIN_OCCUPIED_ROWS_WITHOUT_VERTICALS
        || text_columns(&inside) < MIN_TEXT_COLUMNS_WITHOUT_VERTICALS
    {
        return Err(GridOutcome::NoTextInCells);
    }
    Ok((grid, GridBasis::TextOnly))
}

/// The top and bottom y of a band that can be a grid at all.
fn band_ends(band: &[Rule]) -> Result<(f64, f64), GridOutcome> {
    let Some(first) = band.first() else {
        return Err(GridOutcome::NotEnoughRows);
    };
    let top = first.position;
    let bottom = band.last().expect("non-empty band").position;
    if top - bottom < MIN_LEVEL_GAP_PT * (MIN_HORIZONTAL_LEVELS - 1) as f64 {
        return Err(GridOutcome::NotEnoughRows);
    }
    Ok((top, bottom))
}

/// The median left and right edges of a band's rules.
///
/// The median, not the union: a rule that is one column short (`\cmidrule`) must not widen the
/// grid, and a stray longer rule must not either.
fn median_span(band: &[Rule]) -> (f64, f64) {
    let mut starts: Vec<f64> = band.iter().map(|rule| rule.start).collect();
    let mut ends: Vec<f64> = band.iter().map(|rule| rule.end).collect();
    starts.sort_by(f64::total_cmp);
    ends.sort_by(f64::total_cmp);
    (starts[starts.len() / 2], ends[ends.len() / 2])
}

/// Text lines that lie **inside** `grid`, excluding the caption's own line.
///
/// "Inside" is strict on purpose: a line poking out of the grid means the rectangle cuts through
/// running text, which is a figure's frame around a paragraph or a mis-measured band.
fn text_inside<'a>(grid: Rect, lines: &'a [TextLine], caption: &Caption) -> Vec<&'a TextLine> {
    lines
        .iter()
        .filter(|line| {
            line.range.end as usize <= caption.start || line.range.start as usize >= caption.end
        })
        .filter(|line| {
            line.rect.origin.x >= grid.origin.x - LEVEL_TOLERANCE_PT
                && line.rect.max_x() <= grid.max_x() + LEVEL_TOLERANCE_PT
                && line.rect.origin.y >= grid.origin.y - LEVEL_TOLERANCE_PT
                && line.rect.max_y() <= grid.max_y() + LEVEL_TOLERANCE_PT
        })
        .collect()
}

/// The y centres of text lines that open a caption of their own.
///
/// A float's caption separates it from the next float, so a grid may not grow past one: the
/// rules beyond another caption belong to another table or figure. Without this, on
/// `HumanML3D` page 6 `Table 3`'s grid grew up through `Table 2`'s table (the two are 495 pt wide
/// and stacked), and on `SMooDi` page 13 `Table 3`'s grid grew down into the artwork of `Fig. 6`
/// — 313 pt and 278 pt regions that each held two captions.
fn caption_barriers(lines: &[TextLine], caption: &Caption) -> Vec<f64> {
    lines
        .iter()
        // The caption being resolved is not a barrier to itself: its own line box is taller than
        // the character boxes `Caption::rect` covers, so it would otherwise sit "between" the
        // caption and the border rule it touches and veto every anchor.
        .filter(|line| {
            line.range.end as usize <= caption.start || line.range.start as usize >= caption.end
        })
        .filter(|line| opens_a_caption(&line.text))
        .map(|line| line.rect.center().y)
        .collect()
}

/// Whether a caption line lies strictly between two y positions.
fn caption_between(barriers: &[f64], first: f64, second: f64) -> bool {
    let low = first.min(second);
    let high = first.max(second);
    barriers
        .iter()
        .any(|centre| *centre > low + 1.0 && *centre < high - 1.0)
}

/// Whether a line opens with a caption label: `Table 3`, `Figure 2`, `Fig. 4`, `Algorithm 1`.
///
/// The same vocabulary and the same punctuation-after-the-number rule as
/// [`crate::find_captions`], reduced to a yes/no: this is a separator between floats, not an
/// index of them, so the label itself does not matter.
pub fn opens_a_caption(text: &str) -> bool {
    let trimmed = text.trim_start();
    let lower = trimmed.to_ascii_lowercase();
    // Geometric line grouping is not reading order, so a label can arrive with the tail of the
    // previous word in front of it: the HumanML3D paper gives `gTable 2. ...` and the Ye paper
    // `MeshRetTable4:Penetration ratios of ...`. The label is therefore looked for at any offset,
    // which over-detects on purpose — a line wrongly called a caption only stops a grid from
    // growing further, while a missed one lets a region swallow the next float.
    lower
        .char_indices()
        .any(|(at, _)| caption_label_prefix(&lower[at..]))
}

/// Whether `lower` (already lowercase) opens with a caption label and its punctuation.
fn caption_label_prefix(lower: &str) -> bool {
    let Some(after) = ["figure", "fig.", "table", "algorithm", "alg."]
        .iter()
        .find_map(|word| lower.strip_prefix(word))
    else {
        return false;
    };
    let digits: String = after
        .trim_start()
        .chars()
        .take_while(char::is_ascii_digit)
        .collect();
    if digits.is_empty() {
        return false;
    }
    let rest = after.trim_start().chars().skip(digits.chars().count());
    matches!(
        rest.clone().next(),
        Some('.') | Some(':') | Some('\u{2013}') | Some('\u{2014}')
    )
}

/// How many row bands of the grid hold at least one text line.
fn occupied_rows(inside: &[&TextLine], band: &[Rule]) -> usize {
    band.windows(2)
        .filter(|pair| {
            let (upper, lower) = (pair[0].position, pair[1].position);
            inside.iter().any(|line| {
                let y = line.rect.center().y;
                y > lower && y < upper
            })
        })
        .count()
}

/// How many columns the text's own left edges form.
///
/// Left edges, not centres: a column is a column because its entries start at the same x.
fn text_columns(inside: &[&TextLine]) -> usize {
    let mut edges: Vec<f64> = inside.iter().map(|line| line.rect.origin.x).collect();
    edges.sort_by(f64::total_cmp);

    let mut columns = 0usize;
    let mut index = 0usize;
    while index < edges.len() {
        let anchor = edges[index];
        let mut count = 0usize;
        while index < edges.len() && edges[index] - anchor <= TEXT_COLUMN_TOLERANCE_PT {
            count += 1;
            index += 1;
        }
        if count >= MIN_LINES_PER_TEXT_COLUMN {
            columns += 1;
        }
    }
    columns
}

/// The x position of the gutter between two text columns, when the page has two.
///
/// # The rule
///
/// A gutter is a strip of the **middle of the body** that no ordinary text enters, with text
/// stopping on one side of it and starting on the other. Each part of that sentence is a
/// measured guard:
///
/// 1. the strip is at least [`GUTTER_MIN_WIDTH_PT`] wide;
/// 2. its own centre lies within [`GUTTER_CENTRE_SHARE`] of the body's centre — two columns are
///    balanced, so their boundary straddles the middle of the text block;
/// 3. the lines that respect it dominate: at least [`MIN_GUTTER_SIDE_SHARE`] of the page's lines
///    stop at or before its left edge, and as many start at or after its right edge. A line drawn
///    on *both* sides of the strip — a pair of column lines that arrived as one box — is evidence
///    for both sides at once;
/// 4. the lines that cross it are explained: at most [`MAX_CROSSING_LINES_SHARE`] of the page's
///    lines may reach into the strip at all, and of those at most
///    [`MAX_TEXT_LINES_IN_GUTTER_SHARE`] may be ordinary text. A full-width element
///    ([`SPANNER_WIDTH_SHARE`] of the body or wider: a caption, a title, a wide equation) is not
///    ordinary column text, and neither is a mark narrower than [`STRAY_WIDTH_PT`].
///
/// A page whose body is one column returns `None`; a page with three columns returns one of its
/// gutters, which is enough to keep a region out of the neighbouring column — the whole point of
/// asking.
///
/// # Why the test reads characters and not line boxes
///
/// The first version of this function required that *no line cross* the strip. Every two-column
/// paper contains full-width elements, so one caption disqualified the whole page: on the sample
/// corpus it reported **0 of 298 pages** as having a gutter, and that zero was then read as "these
/// papers are all single-column". They are not — seven of the twelve are two-column.
///
/// Reading the runs of characters inside each line ([`crate::InkRun`]) rather than the line boxes
/// is what makes the difference, and it cuts both ways:
///
/// * a **spanner** — a caption, a heading, a wide table row — really does cross the boundary, and
///   is allowed by (4);
/// * a **merged pair** — a left-column line and its right-column neighbour that `lines_from`
///   reported as one box because their baselines agree — does *not* cross the boundary, however
///   wide its box is, because the gutter between the two runs is empty. Counting its box would
///   have made the busiest part of a two-column page look like a page-wide paragraph.
///
/// Lines centred inside `ignore` are left out. A table's own cells are short lines separated by
/// gaps that look exactly like a gutter, and taking them for the page's column structure would
/// make a table incapable of clearing its own column check.
pub fn column_gutter(lines: &[TextLine], ignore: Option<Rect>) -> Option<f64> {
    let visible: Vec<&TextLine> = lines
        .iter()
        .filter(|line| line.rect.size.width > 0.0 && line.rect.size.height > 0.0)
        .filter(|line| match ignore {
            Some(rect) => !rect.contains(line.rect.center()),
            None => true,
        })
        .collect();
    if visible.len() < MIN_GUTTER_LINES {
        return None;
    }

    let body = visible
        .iter()
        .fold(visible[0].rect, |body, line| body.union(line.rect));
    if body.size.width < 4.0 * GUTTER_MIN_WIDTH_PT {
        return None;
    }

    // Candidate boundaries: a strip can start where some run of characters ends and end where
    // another starts. Its own centre must sit near the middle of the body — a balanced two-column
    // page puts its gutter there, and a "boundary" at the edge of the body is a margin. The widest
    // strip that survives the guards below is the answer; its centre is what callers place a
    // region against.
    let body_centre = body.origin.x + body.size.width * 0.5;
    let reach = body.size.width * GUTTER_CENTRE_SHARE;
    let mut left_edges: Vec<f64> = Vec::new();
    let mut right_edges: Vec<f64> = Vec::new();
    for line in &visible {
        for run in text_runs(line).iter() {
            left_edges.push(run.to);
            right_edges.push(run.from);
        }
    }
    left_edges.sort_by(f64::total_cmp);
    left_edges.dedup_by(|left, right| (*left - *right).abs() < GUTTER_EDGE_TOLERANCE_PT);
    right_edges.sort_by(f64::total_cmp);
    right_edges.dedup_by(|left, right| (*left - *right).abs() < GUTTER_EDGE_TOLERANCE_PT);

    let lines_f = visible.len() as f64;
    let side_need = (lines_f * MIN_GUTTER_SIDE_SHARE).ceil() as usize;
    let text_allowance = (lines_f * MAX_TEXT_LINES_IN_GUTTER_SHARE) as usize;
    let crossing_allowance = (lines_f * MAX_CROSSING_LINES_SHARE) as usize;

    let mut best: Option<(f64, f64)> = None;
    for left_edge in &left_edges {
        // `|left + right - 2 * centre| <= 2 * reach`, the widest strip first.
        let band_from =
            (2.0 * body_centre - 2.0 * reach - left_edge).max(left_edge + GUTTER_MIN_WIDTH_PT);
        let band_to = 2.0 * body_centre + 2.0 * reach - left_edge;
        if band_from > band_to {
            continue;
        }
        let first = right_edges.partition_point(|edge| *edge < band_from);
        let last = right_edges.partition_point(|edge| *edge <= band_to);
        for right_edge in &right_edges[first..last] {
            let width = right_edge - left_edge;
            if width < GUTTER_MIN_WIDTH_PT {
                continue;
            }
            let mut stops_before = 0usize;
            let mut starts_after = 0usize;
            let mut drawn_across = 0usize;
            let mut crossing = 0usize;
            let mut text_inside = 0usize;
            for line in &visible {
                let runs = text_runs(line);
                let ink_from = runs.iter().fold(f64::MAX, |min, run| min.min(run.from));
                let ink_to = runs.iter().fold(f64::MIN, |max, run| max.max(run.to));
                let inside = runs.iter().any(|run| {
                    run.from < right_edge - GUTTER_EDGE_TOLERANCE_PT
                        && run.to > left_edge + GUTTER_EDGE_TOLERANCE_PT
                });
                if inside {
                    crossing += 1;
                    // A spanner and a stray mark are not column text; only the rest counts.
                    let width = line.rect.size.width;
                    if width < body.size.width * SPANNER_WIDTH_SHARE && width > STRAY_WIDTH_PT {
                        text_inside += 1;
                    }
                    if crossing > crossing_allowance || text_inside > text_allowance {
                        break;
                    }
                } else if ink_to <= left_edge + GUTTER_EDGE_TOLERANCE_PT {
                    stops_before += 1;
                } else if ink_from >= right_edge - GUTTER_EDGE_TOLERANCE_PT {
                    starts_after += 1;
                } else {
                    drawn_across += 1;
                }
            }
            if text_inside > text_allowance || crossing > crossing_allowance {
                continue;
            }
            if stops_before + drawn_across < side_need || starts_after + drawn_across < side_need {
                continue;
            }
            if best.is_none_or(|(best_width, _)| width > best_width) {
                best = Some((width, (left_edge + right_edge) * 0.5));
            }
        }
    }

    best.map(|(_, centre)| centre)
}

/// Where a line's characters are: the runs it carries, or its own box when it carries none.
///
/// A line built by hand — a fixture, a caller that grouped characters itself — has no runs, and
/// then its box is the only honest reading of where its text is.
fn text_runs(line: &TextLine) -> std::borrow::Cow<'_, [InkRun]> {
    if line.ink.is_empty() {
        std::borrow::Cow::Owned(vec![InkRun {
            from: line.rect.origin.x,
            to: line.rect.max_x(),
        }])
    } else {
        std::borrow::Cow::Borrowed(&line.ink)
    }
}

/// Which side of the page's gutter a box sits on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Side {
    Left,
    Right,
    /// The boundary cuts the box: a full-width element, or a box that straddles two columns.
    Spanning,
}

/// Which side of `gutter` a box is on, with [`GUTTER_EDGE_TOLERANCE_PT`] of slack.
fn side_of_gutter(rect: Rect, gutter: f64) -> Side {
    if rect.max_x() <= gutter + GUTTER_EDGE_TOLERANCE_PT {
        Side::Left
    } else if rect.origin.x >= gutter - GUTTER_EDGE_TOLERANCE_PT {
        Side::Right
    } else {
        Side::Spanning
    }
}

/// Keeps a region inside the page box; a no-op when the box is degenerate.
fn clamp_to_page(region: Rect, page_bounds: Rect) -> Rect {
    if page_bounds.size.width <= 0.0 || page_bounds.size.height <= 0.0 {
        return region;
    }
    let left = region.origin.x.max(page_bounds.origin.x);
    let right = region.max_x().min(page_bounds.max_x());
    let bottom = region.origin.y.max(page_bounds.origin.y);
    let top = region.max_y().min(page_bounds.max_y());
    if top <= bottom || right <= left {
        return region;
    }
    Rect::new(left, bottom, right - left, top - bottom)
}

#[cfg(test)]
mod table_tests {
    use super::*;
    use lyra_reader_core::Point;

    /// A page 612 × 792 pt, the sample corpus's geometry.
    fn page() -> Rect {
        Rect::new(0.0, 0.0, 612.0, 792.0)
    }

    fn caption_at(x: f64, y: f64, width: f64) -> Caption {
        Caption {
            kind: "Table".to_string(),
            label: "1".to_string(),
            text: "Results.".to_string(),
            rect: Rect::new(x, y, width, 10.0),
            start: 0,
            end: 0,
        }
    }

    fn horizontal(y: f64, x0: f64, x1: f64) -> LineSegment {
        LineSegment::new(Point::new(x0, y), Point::new(x1, y))
    }

    fn vertical(x: f64, y0: f64, y1: f64) -> LineSegment {
        LineSegment::new(Point::new(x, y0), Point::new(x, y1))
    }

    /// A line whose glyphs fill its box: the ordinary case a fixture wants.
    fn text_line(x: f64, y: f64, width: f64, text: &str) -> TextLine {
        TextLine {
            rect: Rect::new(x, y, width, 9.0),
            range: 0..0,
            text: text.to_string(),
            ink: vec![InkRun {
                from: x,
                to: x + width,
            }],
        }
    }

    /// A line whose glyphs sit in the given runs, the way `lines_from` reports a left-column line
    /// and its right-column neighbour when their baselines agree and it hands both back as one box.
    fn runs_text_line(y: f64, runs: &[(f64, f64)], text: &str) -> TextLine {
        let from = runs.iter().fold(f64::MAX, |from, run| from.min(run.0));
        let to = runs.iter().fold(f64::MIN, |to, run| to.max(run.1));
        TextLine {
            rect: Rect::new(from, y, to - from, 9.0),
            range: 0..0,
            text: text.to_string(),
            ink: runs
                .iter()
                .map(|(from, to)| InkRun {
                    from: *from,
                    to: *to,
                })
                .collect(),
        }
    }

    /// A 4-row × 3-column grid: five horizontal rules, four vertical ones.
    fn clean_grid() -> Vec<LineSegment> {
        let mut segments = Vec::new();
        for y in [100.0, 120.0, 140.0, 160.0, 180.0] {
            segments.push(horizontal(y, 200.0, 350.0));
        }
        for x in [200.0, 250.0, 300.0, 350.0] {
            segments.push(vertical(x, 100.0, 180.0));
        }
        segments
    }

    /// One line of text per row of [`clean_grid`], spanning the cells.
    fn clean_grid_text() -> Vec<TextLine> {
        [106.0, 126.0, 146.0, 166.0]
            .into_iter()
            .map(|y| text_line(206.0, y, 138.0, "method 1.0 2.0"))
            .collect()
    }

    #[test]
    fn a_clean_grid_is_the_region_and_includes_the_caption() {
        let caption = caption_at(200.0, 190.0, 150.0);
        let region = table_region(&caption, &clean_grid(), &clean_grid_text(), page())
            .expect("a drawn grid is found");
        // The rules span x 200..350 and y 100..180; the caption sits 10 pt above the top rule.
        assert_eq!(region, Rect::new(200.0, 100.0, 150.0, 100.0));
        let (outcome, _) = table_outcome(&caption, &clean_grid(), &clean_grid_text());
        assert_eq!(outcome, GridOutcome::Ruled);
    }

    #[test]
    fn a_grid_missing_its_top_border_is_still_found() {
        // Four rules instead of five: the caption still touches the nearest one and the band
        // grows downwards through the rest.
        let segments: Vec<LineSegment> = clean_grid()
            .into_iter()
            .filter(|segment| !(segment.is_horizontal(0.1) && segment.from.y == 180.0))
            .collect();
        let caption = caption_at(200.0, 190.0, 150.0);
        let region = table_region(&caption, &segments, &clean_grid_text(), page())
            .expect("a grid without its top border is still a grid");
        assert_eq!(region, Rect::new(200.0, 100.0, 150.0, 100.0));
    }

    #[test]
    fn a_grid_without_text_in_its_cells_is_a_frame_not_a_table() {
        let caption = caption_at(200.0, 190.0, 150.0);
        assert_eq!(
            table_region(&caption, &clean_grid(), &[], page()),
            None,
            "a ruled box with nothing written in it must not claim to be a table"
        );
        let (outcome, _) = table_outcome(&caption, &clean_grid(), &[]);
        assert_eq!(outcome, GridOutcome::NoTextInCells);
    }

    #[test]
    fn a_cluster_of_decorative_lines_is_rejected() {
        // A bar chart: five horizontal rules close together, four short "bars" between them, and
        // a few labels below the plot rather than inside it. This is the shape that a rule count
        // cannot tell from a table.
        let mut segments = Vec::new();
        for y in [300.0, 320.0, 340.0, 360.0, 380.0] {
            segments.push(horizontal(y, 100.0, 400.0));
        }
        for (x, top) in [
            (140.0, 380.0),
            (200.0, 360.0),
            (260.0, 340.0),
            (320.0, 320.0),
        ] {
            segments.push(vertical(x, 300.0, top));
            segments.push(vertical(x + 30.0, 300.0, top));
            segments.push(horizontal(top, x, x + 30.0));
        }
        let caption = caption_at(100.0, 390.0, 200.0);
        let labels = vec![text_line(100.0, 286.0, 40.0, "Q1")];

        assert_eq!(
            table_region(&caption, &segments, &labels, page()),
            None,
            "a chart's gridlines and bars are not a table"
        );
    }

    #[test]
    fn rules_that_do_not_stack_are_not_a_table() {
        // Two rules are a box, not a grid: one row is not a table.
        let segments = vec![
            horizontal(100.0, 200.0, 350.0),
            horizontal(180.0, 200.0, 350.0),
        ];
        let caption = caption_at(200.0, 190.0, 150.0);
        assert_eq!(
            table_region(&caption, &segments, &clean_grid_text(), page()),
            None
        );
    }

    #[test]
    fn a_caption_far_from_every_rule_gets_no_region() {
        let caption = caption_at(200.0, 700.0, 150.0);
        assert_eq!(
            table_region(&caption, &clean_grid(), &clean_grid_text(), page()),
            None,
            "a grid on the other side of the page is not this caption's table"
        );
    }

    #[test]
    fn a_grid_on_the_far_side_of_the_gutter_is_not_this_captions_table() {
        // Two columns of body text with a gutter at x ≈ 295, and a grid drawn inside the right
        // one. A caption in the left column therefore labels something else: the anchor rule
        // followed a rule across the column boundary, and its preview would show one column's
        // table under the other column's caption.
        let mut lines = Vec::new();
        for row in 0..14 {
            let y = 600.0 - row as f64 * 14.0;
            lines.push(text_line(60.0, y, 200.0, "left column text"));
            lines.push(text_line(330.0, y, 200.0, "right column text"));
        }
        // The table's own cells, inside the right column where its rules are.
        lines.extend(
            [106.0, 126.0, 146.0, 166.0].map(|y| text_line(336.0, y, 138.0, "method 1.0 2.0")),
        );
        let mut right_column = Vec::new();
        for y in [100.0, 120.0, 140.0, 160.0, 180.0] {
            right_column.push(horizontal(y, 330.0, 530.0));
        }
        for x in [380.0, 430.0] {
            right_column.push(vertical(x, 100.0, 180.0));
        }

        let caption = caption_at(60.0, 190.0, 150.0);
        assert_eq!(
            table_region(&caption, &right_column, &lines, page()),
            None,
            "a grid on the far side of the gutter is not this caption's table"
        );
        // The same grid with its caption in its own column is accepted.
        let caption = caption_at(330.0, 190.0, 150.0);
        assert!(table_region(&caption, &right_column, &lines, page()).is_some());
    }

    #[test]
    fn a_full_width_table_is_not_refused_for_covering_the_gutter() {
        // A table wider than one column covers the gutter, and so does its caption. Spanning the
        // boundary is what a spanner does, not evidence that the grid strayed out of its column.
        let mut lines = Vec::new();
        for row in 0..14 {
            let y = 600.0 - row as f64 * 14.0;
            lines.push(text_line(60.0, y, 200.0, "left column text"));
            lines.push(text_line(330.0, y, 200.0, "right column text"));
        }
        lines.extend(clean_grid_text());
        let wide: Vec<LineSegment> = clean_grid()
            .into_iter()
            .map(|segment| match segment.is_horizontal(0.1) {
                true => horizontal(segment.from.y, 60.0, 540.0),
                false => segment,
            })
            .collect();

        let caption = caption_at(60.0, 190.0, 400.0);
        assert!(table_region(&caption, &wide, &lines, page()).is_some());
    }

    #[test]
    fn only_table_captions_get_a_grid_region() {
        let mut caption = caption_at(200.0, 190.0, 150.0);
        caption.kind = "Figure".to_string();
        assert_eq!(
            table_region(&caption, &clean_grid(), &clean_grid_text(), page()),
            None
        );
    }

    #[test]
    fn a_grid_without_vertical_rules_needs_rows_and_columns_of_text() {
        // A `booktabs` table: four horizontal rules, three rows, no verticals at all.
        let segments = vec![
            horizontal(100.0, 200.0, 350.0),
            horizontal(140.0, 200.0, 350.0),
            horizontal(180.0, 200.0, 350.0),
            horizontal(220.0, 200.0, 350.0),
        ];
        let caption = caption_at(200.0, 230.0, 150.0);

        // Two columns of text, every row filled: believed.
        let mut lines = Vec::new();
        for y in [110.0, 150.0, 190.0] {
            lines.push(text_line(206.0, y, 40.0, "method"));
            lines.push(text_line(300.0, y, 30.0, "1.0"));
        }
        assert!(table_region(&caption, &segments, &lines, page()).is_some());

        // The same rules with a single column of prose through them: not a table.
        let prose: Vec<TextLine> = (0..7)
            .map(|row| text_line(206.0, 108.0 + row as f64 * 16.0, 140.0, "one line of prose"))
            .collect();
        assert_eq!(table_region(&caption, &segments, &prose, page()), None);
    }

    #[test]
    fn a_caption_line_inside_the_band_stops_it_at_the_next_float() {
        // Two 495 pt-wide tables stacked, with `Table 1` — the upper table's caption — between
        // them. Without that caption acting as a barrier the upper table's rules join the lower
        // one's band and the region grows to 169 pt.
        let mut segments = Vec::new();
        for y in [400.0, 420.0, 440.0, 460.0, 500.0, 520.0, 540.0, 560.0] {
            segments.push(horizontal(y, 100.0, 595.0));
        }
        let mut lines = Vec::new();
        for y in [405.0, 425.0, 445.0, 505.0, 525.0, 545.0] {
            // Two entries per row: without vertical rules the text itself has to show the columns.
            lines.push(text_line(106.0, y, 300.0, "row of results"));
            lines.push(text_line(450.0, y, 40.0, "1.0"));
        }
        lines.push(text_line(
            100.0,
            470.0,
            300.0,
            "Table 1. Results of the first experiment.",
        ));

        let caption = caption_at(100.0, 390.0, 495.0);
        let region = table_region(&caption, &segments, &lines, page()).expect("a grid");
        // The grid is y 400..460 and the caption sits directly under it, so the preview is the
        // pair; what matters is that it stops there instead of growing to the upper table at 560.
        assert_eq!(
            region,
            Rect::new(100.0, 390.0, 495.0, 70.0),
            "the region must stop at the other caption"
        );
    }

    #[test]
    fn caption_labels_are_recognised_wherever_they_start() {
        for text in [
            "Table 2. Quantitative evaluation",
            "gTable2. Quantitative evaluation",
            "MeshRetTable4:Penetration ratios",
            "Figure 12: Overview",
        ] {
            assert!(opens_a_caption(text), "{text:?}");
        }
        for text in [
            "the table 2 shows that",
            "subfigure 3 is drawn",
            "Tables 2 and 3 differ",
            "Table of contents",
            "Fig. 4 shows the method",
        ] {
            assert!(!opens_a_caption(text), "{text:?}");
        }
    }

    #[test]
    fn the_gutter_is_found_only_between_two_real_columns() {
        let mut two_columns = Vec::new();
        for row in 0..14 {
            let y = 600.0 - row as f64 * 14.0;
            two_columns.push(text_line(60.0, y, 200.0, "left"));
            two_columns.push(text_line(330.0, y, 200.0, "right"));
        }
        let gutter = column_gutter(&two_columns, None).expect("a gutter between the columns");
        assert!((290.0..=340.0).contains(&gutter), "gutter at {gutter}");

        let one_column: Vec<TextLine> = (0..14)
            .map(|row| text_line(60.0, 600.0 - row as f64 * 14.0, 490.0, "body text"))
            .collect();
        assert_eq!(column_gutter(&one_column, None), None);
    }

    /// Two columns of body text at x 60 and x 330, on a 612 pt page.
    fn two_column_body() -> Vec<TextLine> {
        let mut lines = Vec::new();
        for row in 0..16 {
            let y = 600.0 - row as f64 * 14.0;
            lines.push(text_line(60.0, y, 200.0, "left column text"));
            lines.push(text_line(330.0, y, 200.0, "right column text"));
        }
        lines
    }

    #[test]
    fn a_full_width_caption_does_not_disqualify_a_two_column_page() {
        // The bug this rule replaced: one full-width element — a caption, a title, a wide
        // equation — meant "a line crosses the boundary", so the page reported no gutter at all,
        // and 0 of the corpus' 298 pages were read as two-column.
        let mut lines = two_column_body();
        lines.push(text_line(
            60.0,
            620.0,
            470.0,
            "Figure 2. Approach overview. (a) A preprocessing step, (b) the pipeline.",
        ));
        let gutter = column_gutter(&lines, None).expect("the caption is a spanner, not a column");
        assert!((280.0..=320.0).contains(&gutter), "gutter at {gutter}");
    }

    #[test]
    fn lines_that_merge_two_columns_do_not_hide_their_gutter() {
        // `lines_from` returns a left-column line and its right-column neighbour as one box when
        // their baselines agree. Reading boxes alone, every one of these lines "crosses" the
        // gutter; reading the runs of glyphs inside them shows the gutter is empty.
        let mut lines = Vec::new();
        for row in 0..16 {
            let y = 600.0 - row as f64 * 14.0;
            if row % 2 == 0 {
                lines.push(text_line(60.0, y, 200.0, "left column text"));
                lines.push(text_line(330.0, y, 200.0, "right column text"));
            } else {
                lines.push(runs_text_line(
                    y,
                    &[(60.0, 260.0), (330.0, 530.0)],
                    "left column text right column text",
                ));
            }
        }
        let gutter = column_gutter(&lines, None).expect("the runs show a gutter");
        assert!((280.0..=320.0).contains(&gutter), "gutter at {gutter}");
    }

    #[test]
    fn a_single_column_page_with_a_wide_heading_has_no_gutter() {
        // Body text every line of which spans the body: whatever gap a heading leaves in the
        // middle, the body is inside it, so no boundary there separates two columns.
        let mut lines: Vec<TextLine> = (0..20)
            .map(|row| {
                text_line(
                    60.0,
                    600.0 - row as f64 * 14.0,
                    460.0,
                    "a line of body text",
                )
            })
            .collect();
        lines.push(runs_text_line(
            620.0,
            &[(100.0, 288.0), (302.0, 480.0)],
            "2 Experiments and Evaluation",
        ));
        assert_eq!(column_gutter(&lines, None), None);
    }
}
