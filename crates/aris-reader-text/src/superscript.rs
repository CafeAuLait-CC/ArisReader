//! Superscript numeric citations: the Science and Nature style.
//!
//! `winds5,6,23-26` and `r-process1-3,10` carry no brackets at all, so the bracket path in
//! [`find_citations`](crate::find_citations) never sees them. What identifies them is geometry:
//! the numerals are set **smaller than the text they follow and raised above its baseline**, and
//! the text layer keeps the per-character boxes that say so ([`RawCharBox`]).
//!
//! # The rule, and where its numbers come from
//!
//! Measured over the two papers that exposed this style (arXiv `1710.05463`, Nature, and
//! `1712.01815`, Science) from [`RawCharBox`] geometry, the true superscript citations in
//! `1710.05463` agree on:
//!
//! * **height** 0.52–0.79 of the median height of the glyphs on their line — the boxes are
//!   font-metric boxes, so a superscript run is the whole smaller face, not a tight glyph box;
//! * **rise** +0.40 to +0.68 of that same median height above the line's median box bottom
//!   (4.1–7.7 pt on a 13.3 pt body);
//! * **font** always a text face (`TimesNewRomanPSMT`, `NimbusRomNo9L-Regu`), never a math or
//!   symbol face.
//!
//! The thresholds below sit outside that range on the permissive side, because a run's fate is
//! decided by corroboration, not by geometry: `SIZE_RATIO = 0.85` and `RAISE_RATIO = 0.30` also
//! admit mathematics, units and footnote markers — see the guards below.
//!
//! `1712.01815` contributes a negative result worth recording: its arXiv text layer renders the
//! citations as ordinary `(9)` / `(2, 14)` at body size on the baseline (height ratio 0.97, rise
//! +0.27 pt), so no geometric rule can see them there. The shape it does have is the short
//! parenthesised numeral, which is a body-size detector of its own: see
//! [`inspect_parenthesised_citations`](crate::inspect_parenthesised_citations), which reads it when the bibliography is a numbered list.
//!
//! # Why geometry alone is not enough
//!
//! The same geometry occurs in `x2`, `10-3`, `m2`, `cm2 g-1`, equation exponents and
//! author-affiliation markers, and in a numbered paper their numerals are *also* labels the
//! bibliography carries. Four guards therefore decide, in order of how much they cost:
//!
//! 1. **A numbered bibliography must exist.** A superscript numeral cites a numbered list; an
//!    author-year paper (labels are surnames and years) has nothing to corroborate against, so
//!    [`CitationStyle::for_document`] turns the whole detector off for it.
//! 2. **The body must not bracket its numeric citations.** `[12]` and a raised numeral are
//!    alternative ways to cite the same list, and the paper that brackets is the paper full of
//!    footnote markers and unit exponents. Measured: this one bit is the difference between 0
//!    and 69 spurious spans over the two corpora — 54 across the twenty evaluation papers and
//!    15 across the twelve regression samples, every one of them a footnote marker or an author
//!    affiliation (see the `reference_eval` module docs and this module's tests).
//! 3. **Every label of the run must exist in that list's label set.** A year, `cm3` and any
//!    paper whose list the parser read only in part are rejected here; `cm2` is not, which is
//!    why the next guard exists.
//! 4. **The run must read as an attachment to a word**: at least three letters touching it on
//!    the left within half a line height, and on the right whitespace, terminal punctuation or
//!    the end of the line. That is what rejects `x2` and `m2` (a symbol, not a word), `R2/c`,
//!    `1013Hz`, `1/2M¤`, and the affiliation number that opens a line.
//!
//! What survives all four is a citation except for one measured class: a superscript numeral
//! attached to a capitalised name in an author block (`Daniel Kasen1,2`) is geometrically and
//! bibliographically indistinguishable from a citation. The corpus measurement prints every run
//! this module accepts, so that class stays visible instead of being assumed away.

use crate::{Citation, ReferenceEntry, numeric_labels, union_boxes};
use aris_reader_core::{RawCharBox, RawTextPage, Rect};
use std::collections::BTreeSet;

/// Largest multiple of its line's median glyph height a superscript glyph may have.
///
/// Measured true superscript citations: 0.52–0.79. The slack admits a face whose font-metric box
/// is close to the body size; the guards below, not this number, remove what it lets through.
const SIZE_RATIO: f64 = 0.85;

/// Smallest rise, as a multiple of the line's median glyph height, above the line's median box
/// bottom (the text layer reports box bottoms, not baselines — see [`RawCharBox::origin`]).
///
/// Measured true superscript citations: +0.40 to +0.68. Mathematics reaches +0.73, so this
/// threshold deliberately does **not** try to separate the two.
const RAISE_RATIO: f64 = 0.30;

/// Baseline tolerance for grouping glyphs into a line, as a multiple of the median glyph height.
///
/// It must be larger than a superscript's rise (0.68 measured) and smaller than the leading
/// (1.5–2.0 median heights in the two papers), so that a superscript joins the line it annotates
/// instead of becoming a line of its own.
const LINE_TOLERANCE: f64 = 0.9;

/// Largest gap inside one run, as a multiple of the line's median glyph height. A space inside
/// `5, 6` is well under it; the jump to the next column or to a following word is far over it.
const RUN_GAP_RATIO: f64 = 0.34;

/// Largest gap, as a multiple of the line's median glyph height, at which the glyph before or
/// after a run still counts as touching it. Half a line height is about one space.
const TOUCH_RATIO: f64 = 0.5;

/// Longest accepted run, in characters. The bracket path caps a group at 12; a superscript run
/// that long is not a citation but a formula.
const MAX_RUN: usize = 16;

/// Letters the word a run is attached to must have.
///
/// A citation marker is attached to a *word* (`winds5,6,23-26`, `profile37`); a unit or a
/// variable is a *symbol* (`m2`, `cm3`, `x2`, `R3`), and every superscript citation measured in
/// `1710.05463` is attached to a word of four letters or more. Three is that measurement with a
/// letter of slack. Measured cost on the two corpora: none; what it cannot promise is stated in
/// the module header — a citation attached to `in`, `it` or `us` would be dropped, and no such
/// case occurs in the forty papers measured.
const WORD_MIN: usize = 3;

/// What the selected bibliography says about the document's citation style.
///
/// Built with [`CitationStyle::for_document`] from the same entry list the resolver uses and the
/// body pages the detector will read, so the detector and the resolver agree on which labels
/// exist. [`CitationStyle::numeric_only`] is what a caller with no bibliography gets: it detects
/// the bracket and author-year styles exactly as before and never invents a superscript or
/// parenthesised citation.
#[derive(Clone, Debug, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CitationStyle {
    /// Every numeric label the bibliography carries.
    labels: BTreeSet<u32>,
    /// Whether the bibliography is a numbered list at all.
    numbered: bool,
    /// Whether the body brackets its numeric citations.
    bracketed: bool,
    alphanumeric: bool,
    /// How many entries the selected bibliography has. A bare parenthesised numeral may only
    /// name a label inside this count (see [`crate::inspect_parenthesised_citations`]).
    reference_count: usize,
}

impl CitationStyle {
    /// The style of a caller that has no bibliography: brackets and author-year only.
    pub fn numeric_only() -> Self {
        Self::default()
    }

    /// Reads the style off a whole document: its reference list and its body pages.
    ///
    /// `pages` is the extraction window in reading order, bibliography included — the body is
    /// derived here from the first page an entry starts on, which is the same boundary the
    /// evaluation harness measures recall over.
    ///
    /// Two document-level facts are read, and both are needed before a raised numeral counts:
    ///
    /// * **Is the list numbered?** At least two entries labelled with plain integers, and at
    ///   least half the list labelled that way. A Science or Nature list (`1. `, `34. `) passes;
    ///   an author-year list (`He 2024`) does not, and superscript detection stays off.
    /// * **Does the body bracket its citations?** A paper that writes `[12]` is not a
    ///   superscript-citing paper: the raised numerals in it are footnote markers, units and
    ///   exponents, and each of those classes was measured on the corpus (see this module's
    ///   header and `reference_eval`). Measured on the twenty-paper evaluation corpus: the one
    ///   paper with real superscript citations has no bracket citation in its body at all, while
    ///   every paper where the geometric rule produced a footnote or exponent false positive has
    ///   dozens. This single bit is what keeps the false positives off the twelve-paper
    ///   regression corpus, whose papers all cite as `[n]`.
    pub fn for_document(pages: &[(u32, RawTextPage)], references: &[ReferenceEntry]) -> Self {
        let labels: BTreeSet<u32> = references
            .iter()
            .filter_map(|entry| entry.label.trim().parse::<u32>().ok())
            .collect();
        let alpha_count = references
            .iter()
            .filter(|e| crate::alphanumeric::label(&e.label).is_some())
            .count();
        let alphanumeric = alpha_count >= 2 && alpha_count * 2 >= references.len();
        let numbered = labels.len() >= 2 && labels.len() * 2 >= references.len();
        let body_end = references
            .iter()
            .map(|entry| entry.page)
            .min()
            .unwrap_or(u32::MAX);
        let bracketed = pages
            .iter()
            .filter(|(page, _)| *page < body_end)
            .any(|(_, text)| {
                crate::find_citations(text)
                    .iter()
                    .any(|citation| citation.text.starts_with('['))
            });
        Self {
            labels,
            numbered,
            bracketed,
            alphanumeric,
            reference_count: references.len(),
        }
    }

    /// Explicit alpha-style bibliography, allowing bracketed keys without treating codes
    /// in an unrelated document as citations.
    pub fn uses_alphanumeric_labels(&self) -> bool {
        self.alphanumeric
    }

    /// Whether this document cites by number at all.
    pub fn is_numbered(&self) -> bool {
        self.numbered
    }

    /// How many entries the selected bibliography has.
    ///
    /// This is the bound a bare parenthesised numeral is checked against: a number larger than
    /// the list cannot label one of its entries, whatever else the line looks like.
    pub fn reference_count(&self) -> usize {
        self.reference_count
    }

    /// How many distinct integer labels the bibliography prints.
    pub fn numeric_label_count(&self) -> usize {
        self.labels.len()
    }

    /// Whether the bibliography itself is a numbered list.
    ///
    /// A parenthesised numeral is a citation only in such a document: an author-year list has no
    /// integer labels to resolve it against, so the same parentheses mean a year, an equation
    /// number or an enumeration instead.
    pub fn bibliography_is_numeric(&self) -> bool {
        self.numbered
    }

    /// Whether a bare parenthesised numeral (`(12)`, `(3–5)`) may be read as a citation here.
    ///
    /// Two document-level facts must both hold: the bibliography is a numbered list (so the
    /// number can resolve to an entry), and the body does not bracket its numeric citations.
    /// The second is the same guard superscripts use, and for the same measured reason: in a
    /// `[12]` paper the parenthesised numbers are overwhelmingly equation numbers, enumerations
    /// and figure sub-labels, not citations.
    pub fn accepts_parenthesised_numerals(&self) -> bool {
        self.numbered && !self.bracketed && !self.alphanumeric
    }

    /// Whether the document brackets its numeric citations, which rules superscripts out.
    pub fn brackets_its_citations(&self) -> bool {
        self.bracketed
    }

    /// Whether every label of a run is one the bibliography carries.
    ///
    /// All of them, not any: a run is one citation, and half a citation pointing at a different
    /// work than the other half is exactly the false positive this guard exists to refuse. A run
    /// that names an entry the parser missed is dropped whole — a budget decision, not a claim
    /// that the run is not a citation.
    fn corroborates(&self, labels: &[String]) -> bool {
        self.numbered
            && !self.bracketed
            && !labels.is_empty()
            && labels
                .iter()
                .all(|label| label.parse::<u32>().is_ok_and(|n| self.labels.contains(&n)))
    }

    /// Whether one integer label is printed by the bibliography.
    ///
    /// The bare parenthesised detector checks every expanded label against this, separately from
    /// the entry-count bound: a list numbered `34..68` prints label 60, and the two checks answer
    /// different questions ("is it a label at all?" and "is it inside the list's size?").
    pub(crate) fn carries_numeric_label(&self, label: u32) -> bool {
        self.labels.contains(&label)
    }
}

/// Whether a font name belongs to a mathematical or symbol face.
///
/// A citation numeral is never set in one, so a run drawn in these faces is an exponent or a
/// symbol. `CMR` is deliberately absent: Computer Modern Roman is a *text* face, and it is the
/// body font of exactly the LaTeX papers that use this citation style.
pub(crate) fn is_math_font(name: &str) -> bool {
    let upper = name.to_ascii_uppercase();
    [
        "CMMI", "CMSY", "CMEX", "MSAM", "MSBM", "STIX", "MATH", "EUSM", "EUFM", "RSFS", "SYMBOL",
    ]
    .iter()
    .any(|marker| upper.contains(marker))
}

/// Glyphs of one line, with the statistics a superscript test needs.
struct Line {
    /// Indices into `text.chars`, in x order.
    members: Vec<usize>,
    median_height: f64,
    median_bottom: f64,
}

fn median(values: &mut [f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    values.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    values[values.len() / 2]
}

fn decode(character: &RawCharBox) -> char {
    char::from_u32(character.unicode).unwrap_or(char::REPLACEMENT_CHARACTER)
}

/// Groups a page's glyphs into lines, allowing for the raise the detector is looking for.
///
/// [`lines_from`](crate::lines_from) cannot be reused: its tolerance is half the *smallest* glyph
/// height on the page, so a raised superscript starts a line of its own and the median it would
/// then be compared against is its own size. Here the tolerance comes from the page's median
/// height, which is a body-text property, and every glyph within it of the line's first glyph
/// joins that line.
fn lines(text: &RawTextPage) -> Vec<Line> {
    let mut heights: Vec<f64> = text
        .chars
        .iter()
        .map(|character| character.rect.size.height)
        .filter(|height| *height > 0.0)
        .collect();
    let page_height = {
        let page = median(&mut heights);
        if page > 0.0 { page } else { 10.0 }
    };
    let tolerance = (page_height * LINE_TOLERANCE).max(0.5);

    let mut order: Vec<usize> = (0..text.chars.len())
        .filter(|index| {
            !matches!(
                char::from_u32(text.chars[*index].unicode),
                Some('\n') | Some('\r') | Some('\u{0}') | None
            )
        })
        .collect();
    order.sort_by(|left, right| {
        let a = &text.chars[*left];
        let b = &text.chars[*right];
        b.rect
            .origin
            .y
            .partial_cmp(&a.rect.origin.y)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(
                a.rect
                    .origin
                    .x
                    .partial_cmp(&b.rect.origin.x)
                    .unwrap_or(std::cmp::Ordering::Equal),
            )
    });

    let mut grouped: Vec<(f64, Vec<usize>)> = Vec::new();
    for index in order {
        let bottom = text.chars[index].rect.origin.y;
        match grouped.last_mut() {
            Some((anchor, members)) if (bottom - *anchor).abs() <= tolerance => members.push(index),
            _ => grouped.push((bottom, vec![index])),
        }
    }

    grouped
        .into_iter()
        .map(|(_, mut members)| {
            members.sort_by(|left, right| {
                text.chars[*left]
                    .rect
                    .origin
                    .x
                    .partial_cmp(&text.chars[*right].rect.origin.x)
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
            let mut member_heights: Vec<f64> = members
                .iter()
                .map(|index| text.chars[*index].rect.size.height)
                .filter(|height| *height > 0.0)
                .collect();
            let mut bottoms: Vec<f64> = members
                .iter()
                .map(|index| text.chars[*index].rect.origin.y)
                .collect();
            let median_height = median(&mut member_heights);
            Line {
                median_height: if median_height > 0.0 {
                    median_height
                } else {
                    page_height
                },
                median_bottom: median(&mut bottoms),
                members,
            }
        })
        .collect()
}

/// Whether a glyph is small and raised enough to be superscript-like on its line.
fn is_raised(character: &RawCharBox, line: &Line) -> bool {
    character.rect.size.height > 0.0
        && character.rect.size.height <= line.median_height * SIZE_RATIO
        && character.rect.origin.y - line.median_bottom >= line.median_height * RAISE_RATIO
}

/// Whether a glyph can carry a citation on its left.
///
/// Only a word character. A digit is excluded because `10-3`, `1013` and `103–104` are exponents
/// continuing a mantissa; a closing delimiter is excluded because the raised numeral after it is
/// the exponent of a formula (`(z − v)2`, measured on `1712.01815`), and none of the true
/// superscript citations in the two papers that exposed this style follows one.
fn opens_a_citation(character: char) -> bool {
    character.is_alphabetic()
}

/// Whether a glyph can end the text a citation annotates: whitespace, terminal punctuation, or
/// a closing delimiter. A letter, a digit or an operator after the run means the run continues a
/// word or a formula (`R2/c`, `cm2` followed by a unit, `1/2`).
fn closes_a_citation(character: char) -> bool {
    character.is_whitespace()
        || matches!(
            character,
            '.' | ',' | ';' | ':' | ')' | ']' | '}' | '"' | '\'' | '”' | '’' | '?' | '!'
        )
}

/// Distance, in x, between two glyphs of the same line.
fn gap(left: &RawCharBox, right: &RawCharBox) -> f64 {
    right.rect.origin.x - (left.rect.origin.x + left.rect.size.width)
}

/// Letters in the word a run is attached to: the unbroken alphabetic run that ends where the run
/// begins, or zero when the glyph before the run is not a letter.
fn attached_word_len(text: &RawTextPage, line: &Line, run_start: usize) -> usize {
    line.members[..run_start]
        .iter()
        .rev()
        .map(|index| decode(&text.chars[*index]))
        .take_while(|character| character.is_alphabetic())
        .count()
}

/// Finds superscript numeric citations on one page.
///
/// `style` decides which of them are kept; see [`CitationStyle`]. The returned citations carry
/// the run's text as it is drawn (`5,6,23-26`) and the same label strings the bracket path
/// produces, so resolution is shared.
pub(crate) fn find(text: &RawTextPage, style: &CitationStyle) -> Vec<Citation> {
    if !style.is_numbered() || style.brackets_its_citations() {
        return Vec::new();
    }

    raised_runs(text)
        .into_iter()
        .filter(|run| style.corroborates(&run.labels))
        .map(|run| Citation {
            text: run.text,
            labels: run.labels,
            rect: run.rect,
            start: run.start,
            end: run.end,
        })
        .collect()
}

/// One raised numeral run, as drawn, with the labels it names.
///
/// The geometry of [`find`], without its bibliography. [`raised_runs`] returns runs whose labels
/// need not exist in any list; [`find`] keeps the subset the document's bibliography corroborates.
pub(crate) struct RaisedRun {
    pub(crate) text: String,
    pub(crate) labels: Vec<String>,
    pub(crate) rect: Rect,
    pub(crate) start: usize,
    pub(crate) end: usize,
}

/// Every raised numeral run on the page that passes the geometric guards.
///
/// This is [`find`] before its last guard. The label guard is deliberately absent because the
/// caller may be asking the opposite question: *which* numerals does the body cite, when the
/// bibliography that would name them has not been chosen yet. T4.20's second numbered list is
/// exactly that case — its labels are dropped by the label guard, so a rule that only reads
/// corroborated runs can never learn that the body cites them.
///
/// The other guards stay: a run must be smaller and raised relative to its line, drawn in a text
/// face, attached to a word of at least [`WORD_MIN`] letters, close on the right, and no longer
/// than [`MAX_RUN`] characters.
pub(crate) fn raised_runs(text: &RawTextPage) -> Vec<RaisedRun> {
    let mut found = Vec::new();
    for line in lines(text) {
        let touch = line.median_height * TOUCH_RATIO;
        let run_gap = line.median_height * RUN_GAP_RATIO;
        let mut position = 0usize;
        while position < line.members.len() {
            let opening = position;
            let first = line.members[position];
            if !is_raised(&text.chars[first], &line) || is_math_font(&text.chars[first].font_name) {
                position += 1;
                continue;
            }

            // Extend over the superscript glyphs that follow, allowing a space between them
            // (`5, 6`) but not a word.
            let mut last = position;
            let mut end = position + 1;
            while end < line.members.len() {
                let candidate = line.members[end];
                let previous = line.members[last];
                let across = gap(&text.chars[previous], &text.chars[candidate]);
                if across > touch.max(run_gap) {
                    break;
                }
                let next = &text.chars[candidate];
                if is_raised(next, &line) && !is_math_font(&next.font_name) {
                    last = end;
                    end += 1;
                    continue;
                }
                if decode(next).is_whitespace() {
                    end += 1;
                    continue;
                }
                break;
            }

            let run: Vec<usize> = line.members[position..end]
                .iter()
                .copied()
                .filter(|index| !decode(&text.chars[*index]).is_whitespace())
                .collect();
            let run_text: String = line.members[position..end]
                .iter()
                .map(|index| decode(&text.chars[*index]))
                .collect();
            position = end;

            if run.is_empty() || run_text.chars().count() > MAX_RUN {
                continue;
            }

            // Left: the run must touch a word. Right: it must end at whitespace, punctuation or
            // the end of the line.
            let Some(left) = opening.checked_sub(1).map(|before| line.members[before]) else {
                continue;
            };
            if gap(&text.chars[left], &text.chars[run[0]]) > touch
                || !opens_a_citation(decode(&text.chars[left]))
                || attached_word_len(text, &line, opening) < WORD_MIN
            {
                continue;
            }
            if let Some(right) = line.members.get(last + 1).copied()
                && gap(&text.chars[*run.last().unwrap()], &text.chars[right]) <= touch
                && !closes_a_citation(decode(&text.chars[right]))
            {
                continue;
            }

            let labels = numeric_labels(&run_text);

            let boxes: Vec<RawCharBox> =
                run.iter().map(|index| text.chars[*index].clone()).collect();
            found.push(RaisedRun {
                text: run_text.trim().to_string(),
                labels,
                rect: union_boxes(&boxes),
                start: run[0].min(*run.last().unwrap()),
                end: run[0].max(*run.last().unwrap()) + 1,
            });
        }
    }

    found.sort_by_key(|run| (run.start, run.end));
    found
}

#[cfg(test)]
mod tests {
    use super::*;
    use aris_reader_core::{PageIndex, Point, Rect};

    /// A synthetic line: each segment is body text, or a run drawn as a superscript.
    ///
    /// The superscript segments use the proportions measured on `1710.05463` — 0.66 of the body
    /// height, raised 0.48 of it — so a threshold change that stops recognising the real paper
    /// also fails here.
    fn line(segments: &[(&str, bool)]) -> RawTextPage {
        const BODY_HEIGHT: f64 = 10.0;
        const SUPER_HEIGHT: f64 = 6.6;
        const SUPER_RISE: f64 = 4.8;
        const BASELINE: f64 = 700.0;

        let mut chars = Vec::new();
        let mut x = 0.0;
        for (text, superscript) in segments {
            let (height, bottom, advance) = if *superscript {
                (SUPER_HEIGHT, BASELINE + SUPER_RISE, 3.3)
            } else {
                (BODY_HEIGHT, BASELINE, 5.0)
            };
            for character in text.chars() {
                chars.push(RawCharBox {
                    rect: Rect::new(x, bottom, advance, height),
                    origin: Point::new(x, bottom),
                    unicode: character as u32,
                    font_size: height,
                    angle: 0.0,
                    font_name: "Body".to_string(),
                });
                x += advance;
            }
        }
        RawTextPage {
            page: PageIndex(0),
            chars,
            text: segments.iter().map(|(text, _)| *text).collect::<String>(),
            is_generated: false,
            has_unicode_map_error: false,
        }
    }

    /// The style of a numbered paper that does not bracket its citations.
    fn style(labels: std::ops::RangeInclusive<u32>) -> CitationStyle {
        CitationStyle {
            labels: labels.collect(),
            numbered: true,
            bracketed: false,
            alphanumeric: false,
            reference_count: 40,
        }
    }

    #[test]
    fn a_superscript_cluster_is_one_citation_with_every_label() {
        let page = line(&[
            ("partially blown away in winds", false),
            ("5,6,23-26", true),
            (" with lower velocities", false),
        ]);
        let found = find(&page, &style(1..=40));
        assert_eq!(found.len(), 1, "{found:?}");
        assert_eq!(found[0].text, "5,6,23-26");
        assert_eq!(
            found[0].labels,
            ["5", "6", "23", "24", "25", "26"].map(String::from)
        );
    }

    #[test]
    fn a_superscript_range_expands_into_its_labels() {
        let page = line(&[
            ("multi-dimensional dynamical models", false),
            ("33–36", true),
            (". We", false),
        ]);
        let found = find(&page, &style(1..=40));
        assert_eq!(found.len(), 1, "{found:?}");
        assert_eq!(found[0].labels, ["33", "34", "35", "36"].map(String::from));
    }

    #[test]
    fn a_superscript_citation_carries_the_box_of_its_own_glyphs() {
        let page = line(&[("profile", false), ("37", true), (". The", false)]);
        let found = find(&page, &style(1..=40));
        assert_eq!(found.len(), 1, "{found:?}");
        assert_eq!(found[0].start, 7);
        assert_eq!(found[0].end, 9);
        // The box is the raised run, not the whole line: the superscript origin is above the
        // body baseline by the measured rise.
        assert!((found[0].rect.origin.y - 704.8).abs() < 1e-6);
        assert!((found[0].rect.size.height - 6.6).abs() < 1e-6);
    }

    #[test]
    fn a_raised_year_is_not_a_citation() {
        // A four-digit numeral is a year, not a label: no numbered list runs into the thousands,
        // so the bibliography never corroborates it.
        let page = line(&[
            ("the models were released", false),
            ("2017", true),
            (" and then", false),
        ]);
        assert!(find(&page, &style(1..=40)).is_empty());
    }

    #[test]
    fn a_variable_exponent_is_not_a_citation() {
        // `x2` and `R3` are symbols with an exponent, not words with a citation.
        let page = line(&[
            ("the term x", false),
            ("2", true),
            (" is small and R", false),
            ("3", true),
            (" is large", false),
        ]);
        assert!(find(&page, &style(1..=40)).is_empty());
    }

    #[test]
    fn a_unit_exponent_is_not_a_citation() {
        // `m2`, `cm3` and `g-1` attach to unit symbols; the exponent after a digit (`10-3`) is
        // not even a label.
        let page = line(&[
            ("an area of 5m", false),
            ("2", true),
            (" and a volume of 2cm", false),
            ("3", true),
            (" at 10", false),
            ("-3", true),
            (" kg", false),
        ]);
        assert!(find(&page, &style(1..=40)).is_empty());
    }

    #[test]
    fn a_footnote_marker_is_not_a_citation() {
        // A marker that opens a line annotates nothing; the footnote it belongs to is not the
        // text it follows.
        let page = line(&[
            ("1", true),
            (" Department of Physics, University of Somewhere", false),
        ]);
        assert!(find(&page, &style(1..=40)).is_empty());
    }

    #[test]
    fn a_run_whose_label_the_bibliography_lacks_is_dropped() {
        let page = line(&[
            ("blown away in winds", false),
            ("5,6", true),
            (" with", false),
        ]);
        assert!(find(&page, &style(1..=4)).is_empty());
        // One missing label drops the whole run: half a citation is not a citation.
        assert!(find(&page, &style(1..=5)).is_empty());
        assert_eq!(find(&page, &style(1..=6)).len(), 1);
    }

    #[test]
    fn a_bracketed_paper_reports_no_superscript_citations() {
        let page = line(&[
            ("blown away in winds", false),
            ("5,6", true),
            (" with", false),
        ]);
        let bracketed = CitationStyle {
            bracketed: true,
            ..style(1..=40)
        };
        assert!(find(&page, &bracketed).is_empty());
    }

    #[test]
    fn an_author_year_paper_reports_no_superscript_citations() {
        let page = line(&[
            ("blown away in winds", false),
            ("5,6", true),
            (" with", false),
        ]);
        let unnumbered = CitationStyle {
            numbered: false,
            ..style(1..=40)
        };
        assert!(find(&page, &unnumbered).is_empty());
    }
}
