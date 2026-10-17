//! Bare parenthesised numeric citations: `(12)`, `(3–5)`, `(7, 9)`, `(2; 11)`.
//!
//! A large part of the numeric literature cites without brackets: Nature and Science print a
//! raised numeral, but many IEEE, ACM and journal variants print `(12)` at body size on the
//! baseline. The bracket path in [`find_citations`](crate::find_citations) only accepts `[12]`,
//! and the author-year path requires words and a four-digit year, so those papers used to show no
//! clickable citation at all. This module is the third detector.
//!
//! # A parenthesised number is a citation only in a numeric bibliography
//!
//! The parentheses are ambiguous on their own: `(3)` is an equation number, `(b)` a figure
//! sub-label, `(2020)` a year, `(1)` an enumeration. What separates a citation is the document's
//! own bibliography. The style is read once per document by
//! [`CitationStyle::for_document`](crate::CitationStyle::for_document), and this detector runs
//! only when both of these are true:
//!
//! * **The bibliography is a numbered list.** Its entries carry integer labels the numeric
//!   parser recovered from `[12]` or `12.` at the start of an entry, and at least two entries
//!   (half the list) are labelled that way. An author-year list (`He, T. 2024.`, label
//!   `He 2024`) fails this test, so a parenthesised year in such a paper is never a citation.
//! * **The body does not bracket its numeric citations.** This is the same guard superscripts
//!   use, and the same measurement put it there: a paper that writes `[12]` uses parentheses for
//!   equation numbers, enumerations and figure sub-labels, not for citations. On the twelve
//!   sample papers and the seven review PDFs — every one of them a bracketing or author-year
//!   document — this guard is what keeps the detector at **zero new spans**.
//!
//! # The rule set, and why each non-citation form is rejected
//!
//! A candidate is a `(` … `)` span of at most [`MAX_INNER_CHARS`] characters whose inside parses
//! as a list of integers: a single number, a range (`3–5`, `3-5`), a comma or semicolon list
//! (`7, 9`, `2; 11`), or a mixture (`3–5, 9`). Every candidate is then put through the gates
//! below, in this order. [`inspect_parenthesised_citations`] returns every one of them — accepted
//! or rejected — with the reason, which is what the CLI prints.
//!
//! 1. **Document proof.** No numeric bibliography, or a bracketing body: rejected before any
//!    geometry is read.
//! 2. **Year-shaped.** A label in `1900..=2100` is a year (`(2020)`), not an entry label. The
//!    largest bibliography in the corpora has 382 entries, far below that range.
//! 3. **Inside the list.** Every expanded label must be positive, no larger than the number of
//!    entries, and one of the integer labels the bibliography actually prints. A number larger
//!    than the bibliography's entry count therefore cannot become a citation.
//! 4. **Not a figure/table/equation/section token.** The words immediately before the number
//!    are read; `Figure 3(4)`, `Table 2(3)`, `Equation (3)` and `Section 4(12)` are rejected as
//!    references to a numbered object, not to a work. (`Figure 3(b)` never even becomes a
//!    candidate: its inside is not a numeral.)
//! 5. **In prose, not in a formula.** The candidate must sit inside a line that has at least
//!    [`PROSE_MIN`] letters besides it; it must not touch the preceding token (`f(3)`), follow a
//!    formula operator (`x = (3)`), or be drawn in a mathematical face.
//! 6. **Not at the line's left edge.** A candidate with no text before it on its line is an
//!    enumeration (`(1) First item`, `(2) Second item`), not a citation to entry 1 or 2.
//! 7. **Not right-aligned at the margin.** A display equation's number is set apart at the right
//!    edge of a line that is mostly formula, so it either ends a line with too little prose or is
//!    separated from the preceding text by more than [`DETACHED_GAP_PT`]. A citation at the end
//!    of a prose line has ordinary word spacing before it and plenty of letters on the line.
//!
//! What survives is the shape the corpora show: `(12)` inside a sentence, in a paper whose
//! bibliography prints `12.` or `[12]`. The labels are the same integer strings the bracket path
//! produces, so [`resolve_reference`](crate::resolve_reference) and every caller of it — the
//! click, the preview, the CLI — need no change.

use crate::{Citation, CitationStyle, RawCharBox, RawTextPage, Rect, union_boxes};

/// Longest inside accepted as a list of numerals. Every documented form fits well inside this;
/// a longer parenthesised span is prose or a formula.
const MAX_INNER_CHARS: usize = 24;

/// Widest range a single candidate may expand. Matches the bracket detector's own bound
/// (`numeric_labels`), so both paths refuse a 1–1000 range the same way.
const MAX_RANGE: u32 = 40;

/// Fewest letters a line must carry, besides the candidate, before it counts as prose.
///
/// A display equation line is variables and operators (`x + y = z (3)`, a handful of letters);
/// a sentence that cites a work has dozens. Measured on the fixture and on `1712.01815`'s real
/// `(9)` citations, a body line carries 25–90 letters and an equation line under 10.
const PROSE_MIN: usize = 24;

/// A gap wider than this, between the candidate and the character before it, means the numeral
/// is set apart from the text rather than continuing it. A word space is 2–10 pt; a display
/// equation's number is pushed tens of points to the right.
const DETACHED_GAP_PT: f64 = 18.0;

/// A gap between two glyphs wider than this starts a new text run. It is above any word space
/// (2–10 pt at body sizes) and below a column gutter (measured 20–70 pt on the corpus), which is
/// what keeps a two-column equation number from borrowing prose from the other column.
const RUN_GAP_PT: f64 = 16.0;

/// How close to the page's left text edge a candidate at the start of a line must sit to be read
/// as an enumeration marker.
const LEFT_MARGIN_PT: f64 = 30.0;

/// Labels that name a numbered object, not a work. The token is matched after the last number
/// (`Figure 3(4)` → `figure`, `3`) and on its own (`Equation (3)`).
const STRUCTURAL_TOKENS: &[&str] = &[
    "fig",
    "figure",
    "figs",
    "figures",
    "tab",
    "table",
    "tabs",
    "tables",
    "eq",
    "eqn",
    "equation",
    "equations",
    "sec",
    "sect",
    "section",
    "sections",
    "app",
    "appendix",
    "algorithm",
    "algorithms",
    "alg",
    "lemma",
    "theorem",
    "corollary",
    "definition",
    "proposition",
    "step",
    "panel",
    "scheme",
];

/// One bare parenthesised numeral the detector considered, and what it decided.
///
/// This is the inspectable form of the detector: [`inspect_parenthesised_citations`] returns
/// every candidate, accepted or rejected, with an English reason. The detector's private
/// `find` filters this list to the accepted spans, so the CLI and the reader cannot disagree
/// about what was decided.
#[derive(Clone, Debug, PartialEq)]
pub struct ParenthesisedCandidate {
    /// The span as drawn, parentheses included: `(12)`, `(3–5, 9)`.
    pub text: String,
    /// The integer labels the span names, ranges expanded (`["3", "4", "5", "9"]`).
    pub labels: Vec<String>,
    /// Bounding box in **page space**.
    pub rect: Rect,
    /// Half-open character range inside the page's text layer.
    pub start: usize,
    pub end: usize,
    /// Whether the detector read this span as a citation.
    pub accepted: bool,
    /// Why it was accepted or rejected. Stable English text, printed by `aris-reader-cli cite`.
    pub reason: &'static str,
}

/// Finds the bare parenthesised numeric citations on one page.
///
/// `style` is the document style built by
/// [`CitationStyle::for_document`](crate::CitationStyle::for_document); this detector contributes
/// nothing unless that style proves a numbered, non-bracketing bibliography. The returned
/// citations carry the same integer label strings as the bracket path.
pub(crate) fn find(text: &RawTextPage, style: &CitationStyle) -> Vec<Citation> {
    if !style.accepts_parenthesised_numerals() {
        return Vec::new();
    }
    inspect_parenthesised_citations(text, style)
        .into_iter()
        .filter(|candidate| candidate.accepted)
        .map(|candidate| Citation {
            text: candidate.text,
            labels: candidate.labels,
            rect: candidate.rect,
            start: candidate.start,
            end: candidate.end,
        })
        .collect()
}

/// Every bare parenthesised numeral on the page, with the detector's decision.
///
/// Unlike the detector's private `find`, this runs even when the document style turns
/// parenthesised citations off, so
/// the CLI can show *why* a span was rejected (a year, an equation number, an author-year
/// bibliography) instead of silently reporting nothing.
pub fn inspect_parenthesised_citations(
    text: &RawTextPage,
    style: &CitationStyle,
) -> Vec<ParenthesisedCandidate> {
    let layout = Layout::new(text);
    scan(text)
        .into_iter()
        .map(|raw| {
            let (accepted, reason) = evaluate(text, &layout, &raw, style);
            ParenthesisedCandidate {
                text: raw.text,
                labels: raw.labels.iter().map(u32::to_string).collect(),
                rect: raw.rect,
                start: raw.start,
                end: raw.end,
                accepted,
                reason,
            }
        })
        .collect()
}

/// A numeric span before the document-level and geometric gates.
struct RawCandidate {
    text: String,
    labels: Vec<u32>,
    rect: Rect,
    start: usize,
    end: usize,
}

/// Every syntactically numeric parenthesised span on the page, in reading order.
///
/// The text scan is deliberately narrow: integers and separators only. Anything with a letter
/// (`(b)`, `(Figure 3)`) is not a numeral candidate at all, and is never reported or cited.
fn scan(text: &RawTextPage) -> Vec<RawCandidate> {
    let characters: Vec<char> = text
        .chars
        .iter()
        .map(|character| char::from_u32(character.unicode).unwrap_or(char::REPLACEMENT_CHARACTER))
        .collect();

    let mut found = Vec::new();
    let mut index = 0usize;
    while index < characters.len() {
        if characters[index] != '(' {
            index += 1;
            continue;
        }
        let mut close = index + 1;
        while close < characters.len()
            && close - index <= MAX_INNER_CHARS
            && characters[close] != ')'
            && characters[close] != '('
        {
            close += 1;
        }
        if close >= characters.len() || characters[close] != ')' {
            index += 1;
            continue;
        }
        let inner: String = characters[index + 1..close].iter().collect();
        let Some(labels) = parse_labels(&inner) else {
            index = close + 1;
            continue;
        };
        // A citation can be broken across a line in the text layer (`(2,` newline `14)`).
        // Keep it — the labels are what resolve — but present it on one line, collapsing the
        // control character to a space instead of printing a carriage return into the CLI/app.
        let shown = characters[index..=close]
            .iter()
            .map(|character| {
                if character.is_control() {
                    ' '
                } else {
                    *character
                }
            })
            .collect::<String>()
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        found.push(RawCandidate {
            text: shown,
            labels,
            rect: union_boxes(&text.chars[index..=close]),
            start: index,
            end: close + 1,
        });
        index = close + 1;
    }
    found
}

/// Parses the inside of a parenthesised span as a numeric citation list.
///
/// Accepted: `12`, `3–5`, `3-5`, `7, 9`, `2; 11`, `3–5, 9`. Spaces around separators are
/// allowed; anything else returns `None`, which is what keeps `(b)` and `(2020a)` out.
fn parse_labels(inner: &str) -> Option<Vec<u32>> {
    let trimmed = inner.trim();
    if trimmed.is_empty() || trimmed.chars().count() > MAX_INNER_CHARS {
        return None;
    }
    let mut labels = Vec::new();
    for part in trimmed.split([',', ';']) {
        let part = part.trim();
        if part.is_empty() {
            return None;
        }
        let dashes = part
            .chars()
            .filter(|character| matches!(character, '-' | '–' | '−'))
            .count();
        if dashes == 0 {
            labels.push(parse_number(part)?);
        } else if dashes == 1 {
            let (from, to) = part.split_once(['-', '–', '−'])?;
            let from = parse_number(from.trim())?;
            let to = parse_number(to.trim())?;
            if from > to || to - from > MAX_RANGE {
                return None;
            }
            labels.extend(from..=to);
        } else {
            return None;
        }
    }
    (!labels.is_empty()).then_some(labels)
}

fn parse_number(text: &str) -> Option<u32> {
    if text.is_empty() || text.chars().count() > 5 || !text.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    text.parse().ok()
}

/// Page-wide geometry a candidate is judged against.
struct Layout {
    /// Median glyph height on the page, used as the baseline tolerance.
    glyph_height: f64,
    /// The page's left text edge, taken as the 10th percentile of glyph left edges so one stray
    /// margin note cannot define it.
    left_margin: f64,
}

impl Layout {
    fn new(text: &RawTextPage) -> Self {
        let mut heights: Vec<f64> = text
            .chars
            .iter()
            .map(|character| character.rect.size.height)
            .filter(|height| *height > 0.0)
            .collect();
        heights.sort_by(|left, right| left.partial_cmp(right).unwrap_or(std::cmp::Ordering::Equal));
        let glyph_height = heights.get(heights.len() / 2).copied().unwrap_or(10.0);

        let mut lefts: Vec<f64> = text
            .chars
            .iter()
            .filter(|character| visible(character))
            .map(|character| character.rect.origin.x)
            .collect();
        lefts.sort_by(|left, right| left.partial_cmp(right).unwrap_or(std::cmp::Ordering::Equal));
        let left_margin = lefts.get(lefts.len() / 10).copied().unwrap_or(0.0);

        Self {
            glyph_height: if glyph_height > 0.0 {
                glyph_height
            } else {
                10.0
            },
            left_margin,
        }
    }

    /// The text run containing `candidate` on its baseline.
    ///
    /// Glyphs that share the candidate's baseline, split where the x gap is wider than
    /// [`RUN_GAP_PT`]. The split is what keeps a two-column equation number from borrowing the
    /// other column's prose, and what exposes a number pushed to the right of a display formula.
    fn run(&self, text: &RawTextPage, candidate: &RawCandidate) -> Vec<usize> {
        let Some(opening) = text.chars.get(candidate.start) else {
            return Vec::new();
        };
        let baseline = opening.origin.y;
        let tolerance = (self.glyph_height * 0.6).max(1.0);
        let mut members: Vec<usize> = (0..text.chars.len())
            .filter(|index| {
                let character = &text.chars[*index];
                visible(character) && (character.origin.y - baseline).abs() <= tolerance
            })
            .collect();
        members.sort_by(|left, right| {
            text.chars[*left]
                .rect
                .origin
                .x
                .partial_cmp(&text.chars[*right].rect.origin.x)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        let mut start = 0usize;
        for position in 1..=members.len() {
            let boundary = position == members.len()
                || gap(
                    &text.chars[members[position - 1]],
                    &text.chars[members[position]],
                ) > RUN_GAP_PT;
            if boundary {
                let run = &members[start..position];
                if run
                    .iter()
                    .any(|index| *index >= candidate.start && *index < candidate.end)
                {
                    return run.to_vec();
                }
                start = position;
            }
        }
        members
    }
}

/// Whether a glyph takes part in line context: anything but line breaks, nulls and whitespace.
fn visible(character: &RawCharBox) -> bool {
    char::from_u32(character.unicode).is_some_and(|character| {
        !character.is_whitespace() && character != '\u{0}' && character != '\u{feff}'
    })
}

fn decode(character: &RawCharBox) -> char {
    char::from_u32(character.unicode).unwrap_or(char::REPLACEMENT_CHARACTER)
}

fn gap(left: &RawCharBox, right: &RawCharBox) -> f64 {
    right.rect.origin.x - (left.rect.origin.x + left.rect.size.width)
}

/// The decision for one candidate, in the order documented at the top of this module.
fn evaluate(
    text: &RawTextPage,
    layout: &Layout,
    candidate: &RawCandidate,
    style: &CitationStyle,
) -> (bool, &'static str) {
    if !style.bibliography_is_numeric() {
        return (
            false,
            "the bibliography is author-year or unnumbered, not numeric",
        );
    }
    if style.uses_alphanumeric_labels() {
        return (
            false,
            "the bibliography uses alphanumeric keys, not integer labels",
        );
    }
    if style.brackets_its_citations() {
        return (
            false,
            "the body brackets its numeric citations, so a parenthesised number is not read as one",
        );
    }

    if candidate
        .labels
        .iter()
        .any(|number| (1900..=2100).contains(number))
    {
        return (false, "a year-shaped number, not a bibliography label");
    }

    if candidate
        .labels
        .iter()
        .any(|number| *number == 0 || *number as usize > style.reference_count())
    {
        return (false, "outside the bibliography's entry count");
    }
    if !candidate
        .labels
        .iter()
        .all(|number| style.carries_numeric_label(*number))
    {
        return (
            false,
            "not one of the integer labels the bibliography prints",
        );
    }

    let run = layout.run(text, candidate);
    if run.is_empty() {
        return (false, "not inside a readable line of text");
    }
    let opening = &text.chars[candidate.start];
    let closing = &text.chars[candidate.end - 1];
    let left = opening.rect.origin.x;
    let right = closing.rect.origin.x + closing.rect.size.width;

    let before: Vec<usize> = run
        .iter()
        .copied()
        .filter(|index| {
            text.chars[*index].rect.origin.x + text.chars[*index].rect.size.width <= left + 0.5
        })
        .collect();
    let after: Vec<usize> = run
        .iter()
        .copied()
        .filter(|index| text.chars[*index].rect.origin.x >= right - 0.5)
        .collect();
    let prose = run
        .iter()
        .filter(|index| **index < candidate.start || **index >= candidate.end)
        .filter(|index| decode(&text.chars[**index]).is_alphabetic())
        .count();

    if let Some(previous) = before.last().copied() {
        let previous = &text.chars[previous];
        let previous_char = decode(previous);
        let detached = gap(previous, opening);
        if detached <= 1.0
            && (previous_char.is_alphanumeric() || matches!(previous_char, ')' | ']' | '}'))
        {
            return (false, "touches the preceding token, like a function call");
        }
        if matches!(
            previous_char,
            '=' | '+' | '−' | '-' | '×' | '÷' | '/' | '^' | '_' | '<' | '>' | '≤' | '≥' | '≈' | '∼'
        ) {
            return (false, "follows a formula operator, not a word");
        }
        if crate::superscript::is_math_font(&previous.font_name)
            || candidate_font_is_math(text, candidate)
        {
            return (false, "drawn in a mathematical face, like a formula");
        }
        if prose < PROSE_MIN {
            return (
                false,
                "a line with too little prose, like a formula or a caption",
            );
        }
        if let Some(reason) = structural_reference(text, &before) {
            return (false, reason);
        }
        if after.is_empty() {
            if detached > DETACHED_GAP_PT {
                return (
                    false,
                    "set apart from the line, like a right-aligned equation number",
                );
            }
            return (
                true,
                "a numeral in a line of prose, and in the bibliography",
            );
        }
        return (
            true,
            "a numeral in a line of prose, and in the bibliography",
        );
    }

    // Nothing before it on its run: either the line starts here (an enumeration) or the numeral
    // was pushed to the right of a display line (an equation number).
    if left - layout.left_margin <= LEFT_MARGIN_PT {
        (false, "opens its line, like a list enumeration")
    } else {
        (
            false,
            "set apart at the right of its line, like an equation number",
        )
    }
}

fn candidate_font_is_math(text: &RawTextPage, candidate: &RawCandidate) -> bool {
    text.chars[candidate.start..candidate.end]
        .iter()
        .any(|character| crate::superscript::is_math_font(&character.font_name))
}

/// The structural-token guard: `Figure 3(4)`, `Table 2(3)`, `Equation (3)`, `Section 4(12)`.
fn structural_reference(text: &RawTextPage, before: &[usize]) -> Option<&'static str> {
    let mut words: Vec<String> = Vec::new();
    let mut current = String::new();
    let mut previous_right = None;
    for index in before {
        let character = &text.chars[*index];
        if let Some(previous_right) = previous_right
            && character.rect.origin.x - previous_right > 2.0
            && !current.is_empty()
        {
            words.push(std::mem::take(&mut current));
        }
        current.push(decode(character));
        previous_right = Some(character.rect.origin.x + character.rect.size.width);
    }
    if !current.is_empty() {
        words.push(current);
    }
    let words: Vec<String> = words
        .into_iter()
        .map(|word| {
            word.trim_matches(|character: char| !character.is_alphanumeric())
                .to_ascii_lowercase()
        })
        .filter(|word| !word.is_empty())
        .collect();

    let structural = |word: &str| STRUCTURAL_TOKENS.contains(&word.trim_end_matches('.'));
    let last = words.last().map(String::as_str);
    let second = words.iter().rev().nth(1).map(String::as_str);
    if last.is_some_and(structural) {
        return Some("names a figure, table, equation or section, not a work");
    }
    if let (Some(last), Some(second)) = (last, second)
        && structural(second)
        && last
            .chars()
            .next()
            .is_some_and(|character| character.is_ascii_digit())
    {
        return Some("names a figure, table, equation or section, not a work");
    }
    let third = words.iter().rev().nth(2).map(String::as_str);
    if let (Some(last), Some(second), Some(third)) = (last, second, third)
        && structural(third)
        && second
            .chars()
            .next()
            .is_some_and(|character| character.is_ascii_digit())
        && last.chars().all(|character| character.is_alphanumeric())
    {
        return Some("names a figure, table, equation or section, not a work");
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ReferenceEntry;
    use aris_reader_core::{PageIndex, Point, Rect};

    const BODY_HEIGHT: f64 = 10.0;
    const LINE_PITCH: f64 = 16.0;

    /// A page drawn one line at a time at a body face, so baseline geometry is real.
    fn page(lines: &[&str]) -> RawTextPage {
        let mut chars = Vec::new();
        let mut text = String::new();
        let mut y = 700.0;
        for line in lines {
            let mut x = 72.0;
            for character in line.chars() {
                let width = if character == ' ' { 3.0 } else { 5.0 };
                chars.push(RawCharBox {
                    rect: Rect::new(x, y, width, BODY_HEIGHT),
                    origin: Point::new(x, y),
                    unicode: character as u32,
                    font_size: BODY_HEIGHT,
                    angle: 0.0,
                    font_name: "Body".to_string(),
                });
                text.push(character);
                x += width;
            }
            chars.push(RawCharBox {
                rect: Rect::new(x, y, 0.0, 0.0),
                origin: Point::new(x, y),
                unicode: '\n' as u32,
                font_size: BODY_HEIGHT,
                angle: 0.0,
                font_name: "Body".to_string(),
            });
            text.push('\n');
            y -= LINE_PITCH;
        }
        RawTextPage {
            page: PageIndex(0),
            chars,
            text,
            is_generated: false,
            has_unicode_map_error: false,
        }
    }

    fn reference(label: &str) -> ReferenceEntry {
        ReferenceEntry {
            label: label.to_string(),
            text: format!("Entry {label}."),
            page: 1,
            start: 0,
            end: 0,
            fragments: Vec::new(),
        }
    }

    /// A numeric bibliography style over `1..=entries`.
    fn numeric_style(entries: u32, body: &str) -> CitationStyle {
        let references: Vec<ReferenceEntry> = (1..=entries)
            .map(|number| reference(&number.to_string()))
            .collect();
        let body = page(&[body]);
        CitationStyle::for_document(&[(0, body)], &references)
    }

    /// An author-year style: the labels are surnames and years, not integers.
    fn author_year_style() -> CitationStyle {
        let references = vec![
            reference("He 2024"),
            reference("Ma 2023"),
            reference("Tan 2022"),
        ];
        CitationStyle::for_document(&[(0, page(&["Body text without a bracket."]))], &references)
    }

    fn candidates(page: &RawTextPage, style: &CitationStyle) -> Vec<ParenthesisedCandidate> {
        inspect_parenthesised_citations(page, style)
    }

    fn by_text<'a>(
        candidates: &'a [ParenthesisedCandidate],
        text: &str,
    ) -> &'a ParenthesisedCandidate {
        candidates
            .iter()
            .find(|candidate| candidate.text == text)
            .unwrap_or_else(|| panic!("candidate {text}: {candidates:?}"))
    }

    #[test]
    fn both_printed_numbering_forms_prove_a_numeric_bibliography() {
        // The numeric parser recovers `[12]` and `12.` as integer labels; either printed form
        // is proof of a numeric bibliography, and either enables the detector.
        for (bibliography, labels) in [
            (
                "References\n[1] Alpha, A. 2020. A first work.\n[2] Beta, B. 2021. A second work.\n",
                ["1", "2"],
            ),
            (
                "References\n1. Alpha, A. 2020. A first work.\n2. Beta, B. 2021. A second work.\n",
                ["1", "2"],
            ),
        ] {
            let references_page = crate::test_page(bibliography);
            let references = crate::find_references([(1u32, &references_page)], 100);
            assert_eq!(
                references
                    .iter()
                    .map(|entry| entry.label.as_str())
                    .collect::<Vec<_>>(),
                labels,
                "{bibliography}"
            );
            let body = crate::test_page("Prior work established the baseline method (2).");
            let style = CitationStyle::for_document(&[(0u32, body)], &references);
            assert!(style.bibliography_is_numeric(), "{bibliography}");
            assert!(style.accepts_parenthesised_numerals(), "{bibliography}");
        }
    }

    #[test]
    fn a_single_number_is_a_citation() {
        let style = numeric_style(14, "Body text.");
        let page = page(&["Prior work established the baseline method (12)."]);
        let found = find(&page, &style);
        assert_eq!(found.len(), 1, "{found:?}");
        assert_eq!(found[0].text, "(12)");
        assert_eq!(found[0].labels, ["12"]);
        assert!(found[0].rect.size.width > 0.0);
    }

    #[test]
    fn a_range_expands_into_its_labels() {
        let style = numeric_style(14, "Body text.");
        let page = page(&["Related approaches extend that method (3–5)."]);
        let found = find(&page, &style);
        assert_eq!(found.len(), 1, "{found:?}");
        assert_eq!(found[0].labels, ["3", "4", "5"].map(String::from));
    }

    #[test]
    fn a_comma_list_names_every_work() {
        let style = numeric_style(14, "Body text.");
        let page = page(&["Two independent studies agree on this point (7, 9)."]);
        let found = find(&page, &style);
        assert_eq!(found.len(), 1, "{found:?}");
        assert_eq!(found[0].labels, ["7", "9"].map(String::from));
    }

    #[test]
    fn a_mixed_list_with_a_range_names_every_work() {
        let style = numeric_style(14, "Body text.");
        let page = page(&["A mixed group cites a span and one more work (3–5, 9)."]);
        let found = find(&page, &style);
        assert_eq!(found.len(), 1, "{found:?}");
        assert_eq!(found[0].labels, ["3", "4", "5", "9"].map(String::from));
    }

    #[test]
    fn a_semicolon_list_is_a_list() {
        let style = numeric_style(14, "Body text.");
        let page = page(&["The two lines of work were compared (2; 11)."]);
        let found = find(&page, &style);
        assert_eq!(found.len(), 1, "{found:?}");
        assert_eq!(found[0].labels, ["2", "11"].map(String::from));
    }

    #[test]
    fn an_equation_number_is_not_a_citation() {
        let style = numeric_style(14, "Body text.");
        let page = page(&[
            "The balance condition is",
            "x + y = z                                      (3)",
        ]);
        let found = find(&page, &style);
        assert!(found.is_empty(), "{found:?}");
        let candidates = candidates(&page, &style);
        assert!(
            by_text(&candidates, "(3)").reason.contains("equation"),
            "{candidates:?}"
        );
        assert!(!by_text(&candidates, "(3)").accepted);
    }

    #[test]
    fn a_formula_number_after_an_operator_is_not_a_citation() {
        let style = numeric_style(14, "Body text.");
        let page = page(&["The loss is f(x) = (3) in this notation, as before."]);
        assert!(find(&page, &style).is_empty());
    }

    #[test]
    fn a_year_is_not_a_citation() {
        let style = numeric_style(14, "Body text.");
        let page = page(&["The dataset was released to the public (2020)."]);
        assert!(find(&page, &style).is_empty());
        let candidates = candidates(&page, &style);
        assert!(by_text(&candidates, "(2020)").reason.contains("year"));
    }

    #[test]
    fn an_enumeration_is_not_a_citation() {
        let style = numeric_style(14, "Body text.");
        let page = page(&[
            "(1) First item of the enumeration, written as prose.",
            "(2) Second item of the same enumeration.",
        ]);
        assert!(find(&page, &style).is_empty());
        let candidates = candidates(&page, &style);
        assert!(by_text(&candidates, "(1)").reason.contains("enumeration"));
        assert!(by_text(&candidates, "(2)").reason.contains("enumeration"));
    }

    #[test]
    fn a_figure_sub_label_is_not_a_citation() {
        let style = numeric_style(14, "Body text.");
        // `Figure 3(b)` is not even a numeral candidate, and `Figure 3 (4)` is rejected by the
        // structural-token guard.
        let page = page(&[
            "Figure 3(b) shows the pipeline for one run.",
            "Figure 3 (4) shows the pipeline for another run.",
        ]);
        let found = find(&page, &style);
        assert!(found.is_empty(), "{found:?}");
        let candidates = candidates(&page, &style);
        assert!(
            candidates.iter().all(|candidate| candidate.text != "(b)"),
            "{candidates:?}"
        );
        assert!(
            by_text(&candidates, "(4)")
                .reason
                .contains("figure, table, equation or section"),
            "{candidates:?}"
        );
    }

    #[test]
    fn a_section_reference_is_not_a_citation() {
        let style = numeric_style(14, "Body text.");
        let section = page(&["Section 4 describes the setup in detail."]);
        assert!(find(&section, &style).is_empty());
        let numbered = page(&["The setup described in Section 4 (12) is not cited here."]);
        assert!(find(&numbered, &style).is_empty());
    }

    #[test]
    fn a_number_larger_than_the_bibliography_is_not_a_citation() {
        let style = numeric_style(14, "Body text.");
        let page = page(&["A later work is discussed elsewhere (25)."]);
        assert!(find(&page, &style).is_empty());
        assert!(
            by_text(&candidates(&page, &style), "(25)")
                .reason
                .contains("entry count")
        );
    }

    #[test]
    fn an_author_year_bibliography_turns_the_detector_off() {
        let style = author_year_style();
        assert!(!style.accepts_parenthesised_numerals());
        let page = page(&["Prior work established the baseline method (12)."]);
        assert!(find(&page, &style).is_empty());
        let candidates = candidates(&page, &style);
        assert!(
            candidates
                .iter()
                .all(|candidate| !candidate.accepted && candidate.reason.contains("author-year")),
            "{candidates:?}"
        );
    }

    #[test]
    fn a_bracketed_body_turns_the_detector_off() {
        let style = numeric_style(14, "As shown in [12], the method works.");
        assert!(!style.accepts_parenthesised_numerals());
        let page = page(&["Prior work established the baseline method (12)."]);
        assert!(find(&page, &style).is_empty());
        let candidates = candidates(&page, &style);
        assert!(
            candidates
                .iter()
                .all(|candidate| !candidate.accepted && candidate.reason.contains("brackets")),
            "{candidates:?}"
        );
    }

    #[test]
    fn a_function_call_is_not_a_citation() {
        let style = numeric_style(14, "Body text.");
        let page = page(&["The value f(3) is plotted for reference here."]);
        assert!(find(&page, &style).is_empty());
    }

    #[test]
    fn a_number_outside_a_line_of_prose_is_not_a_citation() {
        let style = numeric_style(14, "Body text.");
        let page = page(&["The expression above (12) is evaluated as written."]);
        // The line does carry prose, so this one is accepted: it is the positional form the
        // detector is meant to read. The rejection cases are the short lines above.
        assert_eq!(find(&page, &style).len(), 1);
    }
}
