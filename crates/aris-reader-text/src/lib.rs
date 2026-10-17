//! Text layer: turns the **neutral per-character boxes** from the core
//! ([`aris_reader_core::RawTextPage`]) into structures usable for selection, search,
//! citation detection and AI context.
//!
//! Task mapping: T2.1 (aggregation and reading order), T2.2 (selection), T2.3 (search).
//!
//! # About reading order
//!
//! PDFium yields characters in **content stream order**, which disagrees with the visual reading
//! order for multi-column layouts or out-of-order content streams. Reliable approaches, by priority:
//!
//! 1. Tagged document (`aris_reader_core::DocumentSnapshot::is_tagged`) → use the logical order of
//!    the **structure tree**;
//! 2. Otherwise geometric clustering: split columns by column boundaries (x histogram) → sort by y
//!    within a column → sort by x within a line.

mod alphanumeric;
mod bibliography;
#[cfg(test)]
mod bibliography_tests;
mod figures;
mod fragments;
mod superscript;
pub mod tables;

pub use figures::{
    CaptionMention, PageEvidence, caption_region, caption_region_from,
    caption_region_without_margin, find_caption_mentions,
};
pub use superscript::CitationStyle;
pub use tables::table_region;

use aris_reader_core::{Point, RawCharBox, RawTextPage, Rect};

/// Character index (an index into `TextPage::chars`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct CharIndex(pub u32);

/// Text position: page + character index.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct TextPosition {
    pub page: aris_reader_core::PageIndex,
    pub char: CharIndex,
}

/// A character together with its geometry.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CharBox {
    pub rect: Rect,
    pub origin: Point,
    pub unicode: u32,
    pub font_size: f64,
    /// Position in visual reading order (may differ from the array index; see the module docs).
    pub logical_order: u32,
}

impl From<RawCharBox> for CharBox {
    fn from(raw: RawCharBox) -> Self {
        Self {
            rect: raw.rect,
            origin: raw.origin,
            unicode: raw.unicode,
            font_size: raw.font_size,
            logical_order: 0, // TODO(T2.1): filled in by reading order inference
        }
    }
}

/// A run of characters inside a line: the smallest interval holding a group of character boxes
/// with no gap wider than [`INK_RUN_GAP_PT`] between them.
///
/// Runs are what tells a line that *is* one line of text from a line box that only looks like
/// one. PDFium happily reports a left-column line and its right-column neighbour as a single
/// line when their baselines agree and the gutter between them is narrower than the line-break
/// threshold, and the union box of that pair spans the whole page. The runs show the gap the box
/// hides, which is what the column-gutter test reads ([`crate::tables::column_gutter`]).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct InkRun {
    /// Left edge of the run (points).
    pub from: f64,
    /// Right edge of the run (points).
    pub to: f64,
}

/// Two character boxes closer than this are one run of ink (points).
///
/// Kerning and rounding move neighbouring character boxes by a fraction of a point; a word space
/// is several points wide and a column gutter some twenty, so a threshold well under a space
/// keeps words whole while leaving every real gap visible.
pub const INK_RUN_GAP_PT: f64 = 1.0;

/// One line of text (consecutive characters on the same baseline).
#[derive(Clone, Debug, PartialEq)]
pub struct TextLine {
    pub rect: Rect,
    pub range: std::ops::Range<u32>,
    pub text: String,
    /// Where this line's characters actually are, left to right; see [`InkRun`].
    pub ink: Vec<InkRun>,
}

/// A text block (paragraph level; used for retrieval and AI context chunking).
#[derive(Clone, Debug, PartialEq)]
pub struct TextBlock {
    pub rect: Rect,
    pub lines: Vec<TextLine>,
    pub text: String,
    /// Whether this is probably a heading (font size / weight heuristic; used for index building and outline completion).
    pub is_heading: bool,
}

/// Structured text of a single page.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct TextPage {
    pub page: aris_reader_core::PageIndex,
    pub chars: Vec<CharBox>,
    pub blocks: Vec<TextBlock>,
    pub text: String,
    /// Text trust issues reported by the core (scanned pages, Unicode mapping errors).
    pub is_generated: bool,
    pub has_unicode_map_error: bool,
}

impl TextPage {
    /// Build from the core's neutral DTO (aggregation and reading order are implemented in T2.1).
    pub fn from_raw(raw: &RawTextPage) -> Self {
        Self {
            page: raw.page,
            chars: raw.chars.iter().cloned().map(CharBox::from).collect(),
            blocks: Vec::new(), // TODO(T2.1)
            text: raw.text.clone(),
            is_generated: raw.is_generated,
            has_unicode_map_error: raw.has_unicode_map_error,
        }
    }

    /// Hit test: returns the index of the character that contains the point.
    ///
    /// Currently a linear scan (good enough for the ~2000–5000 characters of a single page);
    /// TODO(T2.2): if this becomes a hot spot, switch to a per-line bucketed R-tree / interval index.
    pub fn char_index_at(&self, p: Point) -> Option<CharIndex> {
        self.chars
            .iter()
            .position(|c| c.rect.contains(p))
            .map(|i| CharIndex(i as u32))
    }

    /// Selection rectangles (used to draw highlights); an empty selection returns an empty vec.
    pub fn selection_rects(&self, start: CharIndex, end: CharIndex) -> Vec<Rect> {
        let (lo, hi) = if start <= end {
            (start, end)
        } else {
            (end, start)
        };
        self.chars
            .iter()
            .skip(lo.0 as usize)
            .take((hi.0.saturating_sub(lo.0) + 1) as usize)
            .map(|c| c.rect)
            .collect()
    }
}

/// Text selection (may span pages; stored per page).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Selection {
    pub parts: Vec<SelectionPart>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SelectionPart {
    pub page: aris_reader_core::PageIndex,
    pub start: CharIndex,
    pub end: CharIndex,
}

impl Selection {
    pub fn is_empty(&self) -> bool {
        self.parts.is_empty()
    }
}

/// A search hit.
#[derive(Clone, Debug, PartialEq)]
pub struct SearchHit {
    pub page: aris_reader_core::PageIndex,
    pub rects: Vec<Rect>,
    /// Context snippet around the hit (a few characters before and after), used in the result list.
    pub context: String,
}

// ---------------------------------------------------------------------------
// Search (T2.2)
// ---------------------------------------------------------------------------

/// One match inside a page's character sequence.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Match {
    /// Index of the first matching character.
    pub start: usize,
    /// Index one past the last matching character.
    pub end: usize,
}

/// Finds every non-overlapping occurrence of `needle` in `haystack`.
///
/// Matching ignores ASCII case; callers pass the page text **built from the character
/// sequence itself**, so the returned indices address the same character array that
/// selection and highlighting use — no byte/character mapping anywhere else.
pub fn find_all(haystack: &str, needle: &str) -> Vec<Match> {
    if needle.is_empty() || haystack.is_empty() || needle.len() > haystack.len() {
        return Vec::new();
    }

    let haystack: Vec<char> = haystack.chars().collect();
    let needle: Vec<char> = needle.chars().collect();
    if needle.len() > haystack.len() {
        return Vec::new();
    }

    let mut matches = Vec::new();
    let mut index = 0;
    while index + needle.len() <= haystack.len() {
        let hit = (0..needle.len())
            .all(|offset| haystack[index + offset].eq_ignore_ascii_case(&needle[offset]));
        if hit {
            matches.push(Match {
                start: index,
                end: index + needle.len(),
            });
            index += needle.len();
        } else {
            index += 1;
        }
    }
    matches
}

#[cfg(test)]
mod search_tests {
    use super::*;

    #[test]
    fn finds_every_non_overlapping_match() {
        let matches = find_all("the quick brown fox, the lazy dog", "the");
        assert_eq!(matches.len(), 2);
        assert_eq!(matches[0], Match { start: 0, end: 3 });
        assert_eq!(matches[1].start, 21);
    }

    #[test]
    fn matching_ignores_ascii_case() {
        let matches = find_all("Page 3 of 3", "page");
        assert_eq!(matches.len(), 1);
        assert_eq!(
            &"Page 3 of 3".chars().collect::<Vec<_>>()[matches[0].start..matches[0].end]
                .iter()
                .collect::<String>(),
            "Page"
        );
    }

    #[test]
    fn indices_address_characters_not_bytes() {
        // Four two-byte characters before the match: a byte-based index would report 8.
        let matches = find_all("日本語版 PDF", "PDF");
        assert_eq!(matches.len(), 1);
        assert_eq!(matches[0].start, 5, "indices must count characters");
    }

    #[test]
    fn empty_and_oversized_needles_find_nothing() {
        assert!(find_all("abc", "").is_empty());
        assert!(find_all("", "abc").is_empty());
        assert!(find_all("abc", "abcd").is_empty());
    }
}

// ---------------------------------------------------------------------------
// Bibliography (M4)
// ---------------------------------------------------------------------------

/// One entry of the reference list.
#[derive(Clone, Debug, PartialEq)]
pub struct ReferenceEntry {
    /// The label a citation would use: `12` for `[12]`, or the author-year key text.
    pub label: String,
    /// Entry text with the label stripped.
    ///
    /// Text of the entry's first page, plus the opening lines of the following page when the
    /// entry continues there (see [`EntryFragment`] and [`fragments`](crate::fragments)).
    pub text: String,
    /// Page the entry starts on (the first fragment's page).
    pub page: u32,
    /// First character index of the entry inside its first page.
    pub start: usize,
    /// One past the last character of the entry **on its first page**; a continuation on the
    /// following page is a separate fragment, not part of this range.
    pub end: usize,
    /// The pieces the entry is drawn in, in reading order.
    ///
    /// One fragment for the common case — one column, one page — where the fragment's range is
    /// `start..end` and its box is the entry's rectangle as it has always been. Two or more when
    /// the entry crosses a column gutter or continues onto the following page, which is what a
    /// single rectangle cannot express. Empty means the geometry was never derived (an entry
    /// built by hand); callers then use `page`/`start`/`end` as before.
    pub fragments: Vec<EntryFragment>,
}

/// One piece of a reference entry: a contiguous glyph range on one page and the box it occupies
/// in **page space**.
///
/// An entry is split into fragments where the layout breaks it — at a column gutter, or at the
/// foot of a page. A fragment's box never spans a column gutter; see
/// [`fragments`](crate::fragments) for how the cut is derived and measured.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EntryFragment {
    /// Page the fragment is drawn on.
    pub page: u32,
    /// First character index of the fragment inside its page.
    pub start: usize,
    /// One past the last character of the fragment.
    pub end: usize,
    /// The box the fragment's glyphs occupy, in page space (bottom-left origin).
    pub rect: Rect,
}

impl EntryFragment {
    /// Characters the fragment's range covers.
    pub fn len(&self) -> usize {
        self.end.saturating_sub(self.start)
    }

    /// Whether the fragment's range is empty (it then carries no glyphs).
    pub fn is_empty(&self) -> bool {
        self.end <= self.start
    }
}

/// Whether a page looks like the start of the reference list.
///
/// Accept common heading spellings, including mid-page headings and a numeric
/// entry sharing the heading's line. A mention in running prose is not a heading.
pub fn looks_like_reference_heading(text: &str) -> bool {
    const HEADINGS: [&str; 6] = [
        "references",
        "bibliography",
        "literature cited",
        "参考文献",
        "referencias",
        "bibliographie",
    ];

    // Measured on real papers: the heading often starts mid-page (right after the conclusion),
    // and it often shares its line with the first entry -- PDFium's text extraction produces
    // `References [1] Aberman, K. …`, which a strict equality check rejects, after which a whole
    // paper looks like it has no bibliography. Requiring the line to *start* with a heading and
    // continue with nothing but the first entry is what keeps a body sentence out.
    text.lines().any(|line| {
        let trimmed = line.trim().trim_end_matches(':').trim();
        let lower = trimmed.to_ascii_lowercase();
        HEADINGS.iter().any(|heading| {
            if !lower.starts_with(heading) {
                return false;
            }
            let rest = trimmed[heading.len()..].trim_start_matches([':', ' ']);
            lower == *heading
                || rest.is_empty()
                || rest.starts_with('[')
                || rest.starts_with(|character: char| character.is_ascii_digit())
        })
    })
}

/// Parses numeric-style entries (`[12] Author, Title…`) out of one page's text.
///
/// Accept bracketed and dotted/parenthesized labels in sequence, retaining the
/// original character offsets used by the preview. Candidate selection happens later.
pub fn parse_numeric_references(page: u32, text: &RawTextPage) -> Vec<ReferenceEntry> {
    let chars: Vec<char> = text
        .chars
        .iter()
        .map(|c| char::from_u32(c.unicode).unwrap_or(char::REPLACEMENT_CHARACTER))
        .collect();
    let mut markers = Vec::new();
    let mut offset = 0;
    for line in chars.split_inclusive(|c| *c == '\n') {
        let mut start = offset;
        offset += line.len();
        while start < offset && chars[start].is_whitespace() {
            start += 1;
        }
        let line_text: String = chars[start..offset].iter().collect();
        // PDF extractors sometimes put the heading and first entry on one line.
        if looks_like_reference_heading(&line_text) {
            markers.clear();
            while start < offset && !chars[start].is_ascii_digit() && chars[start] != '[' {
                start += 1;
            }
        }
        let mut digit_start = start;
        let bracketed = chars.get(start) == Some(&'[');
        if bracketed {
            digit_start += 1;
        }
        let mut end = digit_start;
        while end < offset && chars[end].is_ascii_digit() {
            end += 1;
        }
        let digits: String = chars[digit_start.min(chars.len())..end.min(chars.len())]
            .iter()
            .collect();
        let Ok(number) = digits.parse::<u32>() else {
            continue;
        };
        let delimiter = chars.get(end);
        if number == 0
            || if bracketed {
                delimiter != Some(&']')
            } else {
                !matches!(delimiter, Some('.') | Some(')'))
            }
        {
            continue;
        }
        // A DOI such as `10.18653/...` or a decimal at the start of a wrapped
        // continuation is not a numbered entry.
        if !bracketed && chars.get(end + 1).is_some_and(char::is_ascii_digit) {
            continue;
        }
        markers.push((start, end + 1, number, bracketed));
    }
    // Keep the longest sequence of one numbering style. Wrapped DOI fragments
    // can resemble dotted labels before the first real `[n]`; they must neither
    // select the style nor suppress the rest of that page's bibliography.
    let mut starts = Vec::new();
    for bracketed in [true, false] {
        let mut chains: std::collections::BTreeMap<u32, Vec<(usize, usize, u32)>> =
            std::collections::BTreeMap::new();
        for &(start, body, number, style) in &markers {
            if style != bracketed {
                continue;
            }
            let mut chain = chains.get(&(number - 1)).cloned().unwrap_or_default();
            chain.push((start, body, number));
            if chain.len() > starts.len() {
                starts = chain.clone();
            }
            chains.insert(number, chain);
        }
    }
    starts
        .iter()
        .enumerate()
        .map(|(i, (start, body, number))| {
            let end = starts.get(i + 1).map(|s| s.0).unwrap_or(chars.len());
            ReferenceEntry {
                label: number.to_string(),
                text: chars[*body..end]
                    .iter()
                    .collect::<String>()
                    .trim()
                    .to_string(),
                page,
                start: *start,
                end,
                // Derived from the page's geometry once the entry list is selected.
                fragments: Vec::new(),
            }
        })
        .collect()
}

/// Parses author-year entries (`Baevski, A.; Zhou, Y.; … 2020. Title…`) out of one page.
///
/// Recognize inverted names, full names, and corporate authors. A name-like line
/// before the current entry's publication year continues its author list. This
/// operates on extraction order; it does not promise arbitrary layout recovery.
pub fn parse_author_year_references(page: u32, text: &RawTextPage) -> Vec<ReferenceEntry> {
    let chars: Vec<char> = text
        .chars
        .iter()
        .map(|character| char::from_u32(character.unicode).unwrap_or(char::REPLACEMENT_CHARACTER))
        .collect();

    // Line start offsets, so a candidate can be checked against its own line only.
    let mut line_starts = vec![0usize];
    for (index, character) in chars.iter().enumerate() {
        if *character == '\n' {
            line_starts.push(index + 1);
        }
    }

    let mut starts = Vec::new();
    for (position, start) in line_starts.iter().enumerate() {
        let end = line_starts
            .get(position + 1)
            .copied()
            .unwrap_or(chars.len());
        let line: String = chars[*start..end].iter().collect();
        if looks_like_reference_heading(&line) {
            starts.clear();
            continue;
        }
        if looks_like_author_year_start(&line) {
            // A wrapped author list can itself begin with `Surname, I.`. Until the
            // current entry has reached its publication year, this is a coauthor,
            // not a new entry (e.g. He ... / Tan ... 2024. GAIA).
            let continues_authors = starts.last().is_some_and(|previous: &usize| {
                let preceding: String = chars[*previous..*start].iter().collect();
                first_year(&preceding).is_none()
            });
            if !continues_authors {
                starts.push(*start);
            }
        }
    }

    let mut entries = Vec::new();
    for (position, start) in starts.iter().enumerate() {
        let end = starts.get(position + 1).copied().unwrap_or(chars.len());
        let body: String = chars[*start..end].iter().collect();
        let cleaned = body.split_whitespace().collect::<Vec<_>>().join(" ");
        let Some(year) = first_year(&cleaned) else {
            continue;
        };
        let Some(surname) = bibliography_surname(&cleaned) else {
            continue;
        };

        entries.push(ReferenceEntry {
            label: format!("{surname} {year}"),
            text: cleaned,
            page,
            start: *start,
            end,
            // Derived from the page's geometry once the entry list is selected.
            fragments: Vec::new(),
        });
    }

    entries
}

/// Whether a line has a supported bibliographic author prefix.
fn looks_like_author_year_start(line: &str) -> bool {
    bibliography_surname(line).is_some()
}

/// First author in either `Surname, I.` or `Given Surname, ...` form.
fn bibliography_surname(line: &str) -> Option<String> {
    let trimmed = line.trim_start();
    let mut characters = trimmed.chars().peekable();
    let first = characters.next()?;
    if !first.is_uppercase() {
        return None;
    }

    let mut surname_length = 1;
    while let Some(character) = characters.peek() {
        if character.is_alphabetic() || *character == '-' || *character == '\'' {
            surname_length += 1;
            characters.next();
        } else {
            break;
        }
    }
    let rest: String = characters.collect();
    let rest = rest.trim_start();
    if let Some(given) = rest.strip_prefix(',') {
        // Require an initial, not merely a comma: `Tan, Ji, and Pan 2023)`
        // is prose, while `Tan, S.; Ji, B.` begins a bibliography entry.
        let mut given = given.trim_start().chars();
        return (surname_length >= 2
            && given.next().is_some_and(char::is_uppercase)
            && given.next() == Some('.'))
        .then(|| trimmed.chars().take(surname_length).collect());
    }
    if let Some(tail) = rest.strip_prefix('.') {
        // Corporate author, for example `OpenAI. 2023. ...`.
        let tail = tail.trim_start();
        if surname_length >= 2 && first_year(tail).is_some_and(|year| tail.starts_with(&year)) {
            return Some(trimmed.chars().take(surname_length).collect());
        }
    }
    // Full names need an author-list delimiter, or a year immediately after a
    // single author's name. Capitalised title lines alone are not entry starts.
    let year = first_year(trimmed);
    let trimmed = year
        .as_ref()
        .and_then(|year| trimmed.split_once(year).map(|(before, _)| before))
        .unwrap_or(trimmed)
        .trim()
        .trim_end_matches('.');
    if let Some((_, following)) = trimmed.split_once(',') {
        let next = following.split_whitespace().next()?;
        if !next.chars().next().is_some_and(char::is_uppercase)
            || next.chars().any(char::is_numeric)
            || (next.chars().filter(|c| c.is_alphabetic()).count() > 1
                && !next.chars().any(char::is_lowercase))
        {
            return None;
        }
    } else if year.is_none() {
        return None;
    }
    let name = trimmed.split([',', ';']).next()?.split(" and ").next()?;
    // Single-author entries have no comma: stop before the publication year.
    let name = if let Some(year) = first_year(name) {
        name.split_once(&year)?.0.trim().trim_end_matches('.')
    } else {
        name.trim()
    };
    let words: Vec<&str> = name.split_whitespace().collect();
    if !(2..=5).contains(&words.len())
        || matches!(
            words[0],
            "In" | "The" | "A" | "An" | "On" | "Proceedings" | "ACM" | "IEEE"
        )
        || !words.iter().all(|word| {
            let word = word.trim_end_matches('.');
            word.chars().next().is_some_and(char::is_uppercase)
                && word
                    .chars()
                    .all(|c| c.is_alphabetic() || matches!(c, '-' | '\'' | '’'))
        })
    {
        return None;
    }
    Some(words.last()?.trim_end_matches('.').to_string())
}

/// First capitalised word of a span, with punctuation removed: `He et al. 2024` → `He`.
fn first_surname(text: &str) -> Option<String> {
    text.split_whitespace()
        .map(|word| word.trim_matches(|character: char| !character.is_alphanumeric()))
        .find(|word| {
            word.chars().next().map(char::is_uppercase).unwrap_or(false)
                && word
                    .chars()
                    .all(|character| character.is_alphabetic() || character == '-')
                && word.len() >= 2
                && !matches!(
                    *word,
                    "January"
                        | "February"
                        | "March"
                        | "April"
                        | "May"
                        | "June"
                        | "July"
                        | "August"
                        | "September"
                        | "October"
                        | "November"
                        | "December"
                )
        })
        .map(str::to_string)
}

/// A figure, table, or algorithm caption found in the text layer.
#[derive(Clone, Debug, PartialEq)]
pub struct Caption {
    /// `Figure`, `Table`, or `Algorithm`.
    pub kind: String,
    /// The number as printed: `3`, `3a`, `IV`.
    pub label: String,
    /// Caption text after the label.
    pub text: String,
    /// Bounding box of the caption line(s) in page space.
    pub rect: Rect,
    /// Half-open character range inside the page's text layer.
    pub start: usize,
    pub end: usize,
}

/// The most white space allowed between a caption's ink and the ink of the line under it that
/// continues the caption, as a share of the caption's own glyph height.
///
/// Caption lines are set solid: the white space between one line's ink and the next line's ink is
/// what is left of the leading, a third of the type size or so. The line that ends the caption and
/// the block that follows it are separated by a paragraph or float break, which is most of a line.
/// Measured over every caption of the twelve sample papers and the twenty evaluation papers (429
/// captions, 2026-10-15): a continuation line sits **0.10–0.39** glyph heights under the caption
/// (`Table 2` of the ResNet paper at 3.0 pt against 8.0 pt type, `Fig. 13` of the Dvorožňák paper
/// at 0.9 pt against 7.1 pt type), while the nearest line that does *not* continue a caption sits
/// at **0.79** (`Table 6` of the Ye paper, whose table header follows the caption at 7.1 pt against
/// 9.0 pt type). 0.6 is the middle of that empty band.
const CAPTION_LINE_GAP_SHARE: f64 = 0.6;

/// The widest gap *inside* a line that still reads as one line of a caption, as a share of the
/// caption's glyph height.
///
/// A word space is a third of the type size; a table's column gutter is several times that. When a
/// caption is set above its table the first rows follow at the caption's own leading and in its own
/// type size, so neither the leading nor the size tells them apart — the gutter between their cells
/// does. Measured on the same corpus: the widest gap inside a line that a caption really continues
/// is 1.55 glyph heights (`Fig. 35` of the Planck paper), while the first table row that is *not*
/// part of its caption measures 2.97 (`Table 4` of the Transformer paper, whose rows the caption
/// used to take in). 2.0 is the middle of that empty band.
const CAPTION_INK_GAP_SHARE: f64 = 2.0;

/// How much *larger* than the caption's own type a following line may measure (points) and still
/// belong to the caption. A line of a smaller size is never refused.
///
/// The asymmetry is what the corpus shows. Body text is set a size up from the caption on the
/// papers that separate them at all (`Table 2` of the ResNet paper: caption 8.0 pt, body 8.9 pt;
/// `Figure 6` of CLIP: 8.0 against 8.9), and that difference is the last guard behind
/// [`CAPTION_LINE_GAP_SHARE`] when a paragraph follows a caption at the caption's own leading.
/// Smaller lines are not neighbours but *parts* of a line: a subscript or superscript inside a
/// caption arrives as a line of its own in the text layer, 1.4–3.1 pt under the size of the text it
/// belongs to (`Fig. 5` of the Dvorožňák paper, `Fig. 44` of the Planck paper), and refusing those
/// would cut the caption at the first formula it contains.
const CAPTION_TYPE_TOLERANCE_PT: f64 = 0.75;

/// One line of the text layer, as the caption scanner needs it.
///
/// The scanner works on the extraction order of the character array (lines split at `\n`), because
/// that is the order the caption's own lines are printed in — a caption does not survive being
/// regrouped by baseline, which merges the two columns of a two-column page into one "line".
struct CaptionLine {
    /// Half-open character range, without the line's terminating newline.
    start: usize,
    end: usize,
    /// Box of the line's non-whitespace characters, in page space.
    rect: Rect,
    /// Median height of those characters: the crate's stand-in for the type size.
    height: f64,
    /// The line's characters with whitespace runs collapsed, for the caption's text.
    compact: String,
    /// The line as extracted, for the label grammar.
    raw: String,
    /// The widest gap between two runs of ink inside the line.
    gap: f64,
}

/// Splits the page's characters into lines and measures each one.
fn caption_lines(text: &RawTextPage, chars: &[char]) -> Vec<CaptionLine> {
    let mut lines = Vec::new();
    let mut start = 0usize;
    loop {
        let end = chars[start..]
            .iter()
            .position(|character| *character == '\n')
            .map(|offset| start + offset)
            .unwrap_or(chars.len());
        let raw: String = chars[start..end].iter().collect();

        let mut heights: Vec<f64> = Vec::new();
        let mut rect: Option<Rect> = None;
        for character in &text.chars[start.min(text.chars.len())..end.min(text.chars.len())] {
            let visible = char::from_u32(character.unicode)
                .map(|decoded| !decoded.is_whitespace())
                .unwrap_or(false);
            if !visible {
                continue;
            }
            heights.push(character.rect.size.height);
            rect = Some(match rect {
                None => character.rect,
                Some(current) => union_rect(current, character.rect),
            });
        }
        let median = |values: &mut Vec<f64>| {
            values.sort_by(f64::total_cmp);
            values.get(values.len() / 2).copied().unwrap_or(0.0)
        };
        let mut boxes: Vec<Rect> = text.chars
            [start.min(text.chars.len())..end.min(text.chars.len())]
            .iter()
            .filter(|character| {
                char::from_u32(character.unicode)
                    .map(|decoded| !decoded.is_whitespace())
                    .unwrap_or(false)
            })
            .map(|character| character.rect)
            .collect();
        boxes.sort_by(|left, right| left.origin.x.total_cmp(&right.origin.x));
        let mut right = f64::MIN;
        let mut gap: f64 = 0.0;
        for box_rect in boxes {
            if right > f64::MIN && box_rect.origin.x - right > gap {
                gap = box_rect.origin.x - right;
            }
            right = right.max(box_rect.max_x());
        }
        lines.push(CaptionLine {
            start,
            end,
            rect: rect.unwrap_or_default(),
            height: median(&mut heights),
            compact: raw.split_whitespace().collect::<Vec<_>>().join(" "),
            raw,
            gap,
        });

        if end >= chars.len() {
            break;
        }
        start = end + 1;
    }
    lines
}

/// The caption a line opens with: its kind and its numeric label.
///
/// A caption label must open a line and be followed by punctuation (`.`, `:`, en dash, or em dash)
/// before its title. That separator keeps a line-start sentence such as `Figure 3 shows ...` in
/// the mention stream.
fn caption_label(line: &str) -> Option<(&'static str, String)> {
    let trimmed = line.trim_start();
    let lower = trimmed.to_ascii_lowercase();
    let kind = if lower.starts_with("figure") || lower.starts_with("fig.") {
        "Figure"
    } else if lower.starts_with("table") {
        "Table"
    } else if lower.starts_with("algorithm") || lower.starts_with("alg.") {
        "Algorithm"
    } else {
        return None;
    };

    // After the caption keyword comes a plain numeric label and a punctuation separator.
    let label_start = if lower.starts_with("fig.") || lower.starts_with("alg.") {
        4
    } else if lower.starts_with("algorithm") {
        9
    } else if lower.starts_with("figure") {
        6
    } else {
        5
    };
    let after: String = trimmed.chars().skip(label_start).collect();
    let after = after.trim_start();
    let label: String = after.chars().take_while(char::is_ascii_digit).collect();
    if label.is_empty() {
        return None;
    }
    let suffix: String = after.chars().skip(label.chars().count()).collect();
    let suffix = suffix.trim_start();
    if suffix.starts_with(['.', ':', '\u{2013}', '\u{2014}']) {
        // A dot immediately followed by another digit is a sub-number, not a separator.
        if suffix.starts_with('.') && suffix[1..].starts_with(|c: char| c.is_ascii_digit()) {
            return None;
        }
    } else {
        return None;
    }

    Some((kind, label))
}

/// The lines a caption covers: the line its label opens, and every line under it that repeats the
/// caption's leading and its type size within the caption's own column.
///
/// This is what a caption *is* in a PDF text layer: the label line is the only line that can be
/// recognised, and the rest of the caption is the run of lines that continues it typographically.
/// Without the run, a caption that wraps — which is most of them, and every caption that reaches
/// past the artwork it labels — was stored as its first line alone, and both its text and its
/// region stopped there.
///
/// The walk stops at the first line that breaks the run, on any of:
///
/// * **another column** — a line that does not overlap the caption horizontally is the page's
///   other column (a two-column content stream prints both columns of a row together), and the
///   walk steps over it rather than treating it as the caption's end;
/// * **a paragraph break** — a line further below than [`CAPTION_LEADING_SHARE`] of the caption's
///   glyph height;
/// * **a different type size** — more than [`CAPTION_TYPE_TOLERANCE_PT`] away from the label
///   line's, which is what separates a caption from the body text or the table rows under it;
/// * **another caption** — a line that opens a `Figure`/`Table`/`Algorithm` label of its own.
fn caption_block(lines: &[CaptionLine], anchor: usize) -> (Vec<usize>, Rect) {
    let mut included = vec![anchor];
    let mut block = lines[anchor].rect;
    let reference = lines[anchor].height;

    loop {
        let last = *included.last().expect("the anchor line");
        // The first line after the block that shares its column. A line that does not overlap the
        // block at all is the page's other column (a two-column content stream prints both columns
        // of a row together) or a marginal note; it is stepped over rather than treated as the
        // caption's end. The block is what the caption covers so far, so a hanging-indent
        // continuation, and the sub- and superscripts that arrive as lines of their own, all line
        // up with it.
        let next = (last + 1..lines.len()).find(|index| {
            let line = &lines[*index];
            !line.compact.is_empty()
                && line.rect.size.width > 0.0
                && crate::figures::overlaps_horizontally(block, line.rect)
        });
        let Some(next) = next else { break };
        let line = &lines[next];

        // White space, not baseline distance: a line of the text layer is not always one printed
        // line. PDFium merges a wrapped line into its neighbour when a word is hyphenated across
        // the break (`Figure 2` of the Pan paper arrives as two printed lines under one `\n`), and
        // it splits one printed line into several when a formula interrupts it. Both are measured
        // from the block's lowest ink and the candidate's highest, which is the same quantity on
        // every one of them.
        let gap = block.origin.y - line.rect.max_y();
        if gap > CAPTION_LINE_GAP_SHARE * reference
            || line.height - reference > CAPTION_TYPE_TOLERANCE_PT
            || line.gap > CAPTION_INK_GAP_SHARE * reference
            || caption_label(&line.raw).is_some()
        {
            break;
        }

        included.push(next);
        block = union_rect(block, line.rect);
    }

    (included, block)
}

/// Finds `Figure N` / `Table N` / `Algorithm N` captions, each with the **whole** run of lines it
/// covers (see [`caption_block`]) rather than its label line alone.
///
/// A caption label must open a line and be followed by punctuation (`.`, `:`, en dash, or em dash)
/// before its title. That separator keeps a line-start sentence such as `Figure 3 shows ...` in
/// the mention stream. This text-layer cue is also our only handle on vector figures, tables, and
/// algorithms that lack image objects.
pub fn find_captions(text: &RawTextPage) -> Vec<Caption> {
    let chars: Vec<char> = text
        .chars
        .iter()
        .map(|character| char::from_u32(character.unicode).unwrap_or(char::REPLACEMENT_CHARACTER))
        .collect();
    let lines = caption_lines(text, &chars);

    let mut captions = Vec::new();
    for (position, line) in lines.iter().enumerate() {
        let Some((kind, label)) = caption_label(&line.raw) else {
            continue;
        };
        let trimmed = line.raw.trim_start();
        let offset = line.raw.chars().count() - trimmed.chars().count();
        let (block_lines, mut rect) = caption_block(&lines, position);
        let caption_start = line.start + offset;
        // The label line's box starts at its first printed character, not at its indentation, and
        // it reaches past the line's last character to the newline that ends it — the shape this
        // box has always had.
        rect = union_rect(
            rect,
            union_boxes(
                &text.chars[caption_start.min(text.chars.len())..line.end.min(text.chars.len())],
            ),
        );
        // The range keeps the shape it has always had: it runs to the end of the last line's own
        // characters, not past the newline that terminates them.
        let last = *block_lines.last().expect("the caption's own line");
        let caption_end = if lines[last].end < chars.len() {
            lines[last].end + 1
        } else {
            lines[last].end
        };
        let body = block_lines
            .iter()
            .map(|index| lines[*index].compact.as_str())
            .collect::<Vec<_>>()
            .join(" ");

        captions.push(Caption {
            kind: kind.to_string(),
            label,
            text: body
                .trim_start_matches(|character: char| !character.is_whitespace())
                .trim()
                .to_string(),
            // The caption's own lines, not the character range: in a two-column page the range can
            // step over the other column's line, and the box must not follow it.
            rect: block_lines
                .iter()
                .fold(rect, |_accumulated, _index| rect)
                .union(if caption_start > line.start {
                    // The label line's box is measured from its first non-space character.
                    union_boxes(
                        &text.chars
                            [caption_start.min(text.chars.len())..line.end.min(text.chars.len())],
                    )
                } else {
                    rect
                }),
            start: caption_start,
            end: caption_end,
        });
    }

    captions
}

/// Selects a bibliography run, then optionally refines it with link landings.
///
/// Landings are hints: they may be sparse, refer to other sections, or share a Y
/// coordinate across columns. Rebuilding must preserve the parsed entry labels
/// and produce contiguous source ranges. CLI and FFI share this implementation.
pub fn find_references_with_landings(
    pages: &[(u32, RawTextPage)],
    landings: &std::collections::BTreeMap<u32, Vec<f64>>,
    max_entries: usize,
) -> Vec<ReferenceEntry> {
    // The independent page-density locator remains a CLI diagnostic. Candidate
    // runs carry entry continuity and style evidence that page scores alone lack.
    let parsed = find_references(pages.iter().map(|(page, text)| (*page, text)), max_entries);
    if landings.is_empty() {
        return parsed;
    }

    let mut rebuilt = Vec::new();
    for (page, text) in pages {
        let on_page: Vec<_> = parsed.iter().filter(|entry| entry.page == *page).collect();
        if on_page.is_empty() {
            continue;
        }
        if let Some(tops) = landings.get(page) {
            let from_landings = entries_from_bands(*page, text, tops);
            // Links may target figures/appendices or only some bibliography entries.
            // They cannot replace a parsed page if that would lose entry identities.
            if from_landings.len() >= 2
                && on_page.iter().all(|parsed| {
                    from_landings
                        .iter()
                        .any(|entry| entry.label == parsed.label)
                })
            {
                rebuilt.extend(from_landings);
                continue;
            }
        }
        rebuilt.extend(parsed.iter().filter(|entry| entry.page == *page).cloned());
    }

    if rebuilt.is_empty() {
        return parsed;
    }
    rebuilt.truncate(max_entries);
    // Entries rebuilt from bands carry no geometry yet, and the ones cloned from `parsed` must
    // agree with them fragment for fragment; deriving both here keeps the two paths identical.
    let references: Vec<(u32, &RawTextPage)> =
        pages.iter().map(|(page, text)| (*page, text)).collect();
    // A page rebuilt from bands ends its entries at the bands' own edges, but a page that kept
    // its parsed entries still carries whatever the page printed after the list.
    bibliography::trim_trailing_section(&mut rebuilt, &references);
    fragments::assign(&mut rebuilt, &references);
    rebuilt
}

/// Derives a reference entry's label from its own text.
///
/// `[12] Author…` → `12`; `12. Author…` → `12`; otherwise the author-year key `Surname Year`.
pub fn entry_label(text: &str) -> String {
    let trimmed = text.trim_start();

    if let Some(rest) = trimmed.strip_prefix('[') {
        if let Some((key, _)) = rest.split_once(']')
            && let Some(label) = alphanumeric::label(key)
        {
            return label;
        }
        let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
        if !digits.is_empty() && rest[digits.len()..].starts_with(']') {
            return digits;
        }
    }

    let digits: String = trimmed.chars().take_while(char::is_ascii_digit).collect();
    if !digits.is_empty()
        && matches!(
            trimmed[digits.len()..].chars().next(),
            Some('.') | Some(')')
        )
    {
        return digits;
    }

    match (bibliography_surname(trimmed), first_year(trimmed)) {
        (Some(surname), Some(year)) => format!("{surname} {year}"),
        _ => String::new(),
    }
}

/// Splits a page's text layer into entries using the positions the document's own links land on.
///
/// `tops` are page-space top edges. Bands run downwards to the next landing.
/// Reject bands selecting noncontiguous characters, as happens on multi-column
/// pages. The caller must also validate that sparse links have not merged entries.
pub fn entries_from_bands(page: u32, text: &RawTextPage, tops: &[f64]) -> Vec<ReferenceEntry> {
    if tops.len() < 2 {
        return Vec::new();
    }

    // Descending: page-space y grows upwards, and an entry list reads from the top of the page
    // down, so the first band is the one with the largest y.
    let mut sorted: Vec<f64> = tops.to_vec();
    sorted.sort_by(|a, b| b.partial_cmp(a).unwrap_or(std::cmp::Ordering::Equal));
    // Two links to the same entry land within a couple of points of each other.
    sorted.dedup_by(|a, b| (*a - *b).abs() < 3.0);

    let mut entries = Vec::new();
    for (index, top) in sorted.iter().enumerate() {
        let next = sorted.get(index + 1).copied();

        let mut start = usize::MAX;
        let mut end = 0usize;
        let mut body = String::new();
        for (char_index, character) in text.chars.iter().enumerate() {
            let char_top = character.rect.origin.y + character.rect.size.height;
            let in_band =
                char_top <= top + 3.0 && next.map(|limit| char_top > limit + 3.0).unwrap_or(true);
            if !in_band {
                continue;
            }
            start = start.min(char_index);
            end = end.max(char_index + 1);
            if let Some(character) = char::from_u32(character.unicode) {
                body.push(character);
            }
        }

        if start == usize::MAX {
            continue;
        }

        // A Y-only band through two columns selects disjoint character ranges.
        // The preview ABI carries one contiguous range, so reject the reconstruction
        // instead of producing a box spanning unrelated entries in both columns.
        if text.chars[start..end].iter().any(|character| {
            let char_top = character.rect.origin.y + character.rect.size.height;
            char::from_u32(character.unicode).is_some_and(|c| !c.is_whitespace())
                && !(char_top <= top + 3.0
                    && next.map(|limit| char_top > limit + 3.0).unwrap_or(true))
        }) {
            return Vec::new();
        }

        let collapsed = body.split_whitespace().collect::<Vec<_>>().join(" ");
        let label = entry_label(&collapsed);
        if label.is_empty() {
            continue;
        }

        entries.push(ReferenceEntry {
            label,
            text: collapsed,
            page,
            start,
            end,
            // Derived from the page's geometry once the entry list is selected.
            fragments: Vec::new(),
        });
    }

    entries
}

/// Resolves a citation label against the reference list.
///
/// Exact label match first; then, for a numeric citation against an **unnumbered** list, the
/// position: `[12]` means the twelfth entry. That convention is real (ACM's `unsrt`-style lists
/// carry no numbers while the body cites numbers) and without it such a paper matches nothing.
pub fn resolve_reference<'a>(
    labels: &[String],
    references: &'a [ReferenceEntry],
) -> Option<&'a ReferenceEntry> {
    for label in labels {
        let mut matches = references
            .iter()
            .filter(|entry| label.eq_ignore_ascii_case(&entry.label));
        if let Some(entry) = matches.next() {
            // Same surname/year can identify several works. Do not silently pick
            // whichever happens to appear first in extraction order.
            if matches.next().is_none() {
                return Some(entry);
            }
        }
    }

    // Positional fallback, but only when the list itself is unnumbered: if the entries carry
    // labels, a numeric miss means "no such reference", not "the Nth one".
    let list_is_unnumbered = references.iter().all(|entry| {
        alphanumeric::label(&entry.label).is_none()
            && !entry
                .label
                .chars()
                .next()
                .map(|c| c.is_ascii_digit())
                .unwrap_or(false)
    });
    if !list_is_unnumbered {
        return None;
    }

    // Compound surnames may be shortened by the full-name parser. Match only a
    // suffix of the *first author's name*, with the same year, and only uniquely.
    for label in labels {
        let Some((surname, year)) = label.rsplit_once(' ') else {
            continue;
        };
        let mut matches = references.iter().filter(|entry| {
            let same_year = entry.label.rsplit_once(' ').is_some_and(|(_, y)| y == year);
            let first_author = entry
                .text
                .split(',')
                .next()
                .unwrap_or("")
                .split(" and ")
                .next()
                .unwrap_or("")
                .trim();
            same_year && first_author.ends_with(&format!(" {surname}"))
        });
        if let Some(entry) = matches.next()
            && matches.next().is_none()
        {
            return Some(entry);
        }
    }
    for label in labels {
        if let Ok(position) = label.parse::<usize>()
            && position >= 1
            && let Some(entry) = references.get(position - 1)
        {
            return Some(entry);
        }
    }

    None
}

/// Resolves **every** label of a citation against the reference list.
///
/// A citation often names several works at once — `[1,2]` or `(He et al. 2024; Kim 2023)` — and
/// the reader expects all of them, not whichever label the list happens to match first. Each
/// label is resolved on its own, so an unknown label never hides the labels next to it, and the
/// results keep label order. Entries are de-duplicated by `(label, page)`, so a citation that
/// repeats itself (`[3,3]`) or whose labels point at one work (a numeric label that falls back
/// to the same position as an author-year label) lists that work once.
pub fn resolve_references<'a>(
    labels: &[String],
    references: &'a [ReferenceEntry],
) -> Vec<&'a ReferenceEntry> {
    let mut resolved: Vec<&ReferenceEntry> = Vec::new();

    for label in labels {
        // One label at a time: the single-label helper owns the matching conventions, and
        // handing it the whole group would let the first match hide the rest.
        let Some(entry) = resolve_reference(std::slice::from_ref(label), references) else {
            continue;
        };
        let already_listed = resolved
            .iter()
            .any(|listed| listed.label == entry.label && listed.page == entry.page);
        if !already_listed {
            resolved.push(entry);
        }
    }

    resolved
}

/// Finds the reference list across a document's pages.
///
/// `pages` must be `(page index, raw text)` in reading order and may cover only part of the
/// document. All supplied pages are scored; `max_entries` caps the returned list.
/// Callers bound extraction separately (currently 120 pages in CLI and FFI).
pub fn find_references<'a>(
    pages: impl IntoIterator<Item = (u32, &'a RawTextPage)>,
    max_entries: usize,
) -> Vec<ReferenceEntry> {
    let pages: Vec<(u32, &RawTextPage)> = pages.into_iter().collect();
    let mut entries = bibliography::select_reference_run(
        pages.iter().map(|(page, text)| (*page, *text)),
        max_entries,
    );
    // The list's last entry ends where the page does, not where the reference does; see
    // `trim_trailing_section`. It runs before the geometry, so the preview box it derives covers
    // the entry's own glyphs and nothing after them.
    bibliography::trim_trailing_section(&mut entries, &pages);
    // Geometry comes after selection: which run of entries is the bibliography must not depend
    // on where the columns fall.
    fragments::assign(&mut entries, &pages);
    entries
}

#[cfg(test)]
mod caption_tests {
    use super::*;

    /// A page of lines given as `(x, baseline, glyph height, text)`, each character 5 pt wide.
    ///
    /// `test_page` stacks every line on one baseline, which is enough for the label grammar but
    /// says nothing about leading or type size — the two measurements a caption's continuation is
    /// decided by.
    fn page_of(lines: &[(f64, f64, f64, &str)]) -> RawTextPage {
        use aris_reader_core::{PageIndex, Point, RawCharBox};
        let mut chars = Vec::new();
        for (line, (x, baseline, height, text)) in lines.iter().enumerate() {
            if line > 0 {
                // The text layer separates lines with a character of its own; on a real page its
                // box is degenerate (4 of 10,020 newline boxes in the corpus measure above 0.01
                // pt), so a zero-sized box at the end of the previous line is what it looks like.
                let after = x + text.chars().count() as f64 * 5.0;
                chars.push(RawCharBox {
                    rect: Rect::new(after, *baseline + *height, 0.0, 0.0),
                    origin: Point::new(after, *baseline),
                    unicode: '\n' as u32,
                    font_size: *height,
                    angle: 0.0,
                    font_name: "Body".to_string(),
                });
            }
            for (column, character) in text.chars().enumerate() {
                chars.push(RawCharBox {
                    rect: Rect::new(x + column as f64 * 5.0, *baseline, 5.0, *height),
                    origin: Point::new(x + column as f64 * 5.0, *baseline),
                    unicode: character as u32,
                    font_size: *height,
                    angle: 0.0,
                    font_name: "Body".to_string(),
                });
            }
        }
        RawTextPage {
            page: PageIndex(0),
            chars,
            text: lines
                .iter()
                .map(|(_, _, _, text)| *text)
                .collect::<Vec<_>>()
                .join("\n"),
            is_generated: false,
            has_unicode_map_error: false,
        }
    }

    /// A caption of one 8 pt line, its continuation, and body text 36 pt under it.
    fn wrapped_caption_page() -> RawTextPage {
        page_of(&[
            (50.0, 700.0, 8.0, "Figure 3: Overview of the method."),
            (50.0, 688.0, 8.0, "It wraps onto a second line"),
            (50.0, 676.0, 8.0, "and a third."),
            (50.0, 640.0, 9.0, "Body text resumes here."),
        ])
    }

    #[test]
    fn figure_and_table_captions_are_found_with_labels() {
        let text = "Body text here.\nFigure 3: Overview of the method.\nmore text\nTable 2. Results on the test set.\n";
        let captions = find_captions(&crate::test_page(text));
        assert_eq!(captions.len(), 2, "{captions:?}");
        assert_eq!(captions[0].kind, "Figure");
        assert_eq!(captions[0].label, "3");
        assert!(captions[0].text.contains("Overview"));
        assert_eq!(captions[1].kind, "Table");
        assert_eq!(captions[1].label, "2");
    }

    #[test]
    fn a_sentence_mentioning_a_figure_is_not_a_caption() {
        // "as Figure 3 shows" is mid-line, not a caption: captions start their line.
        let captions = find_captions(&crate::test_page("As Figure 3 shows, the method works.\n"));
        assert!(captions.is_empty(), "{captions:?}");
    }

    #[test]
    fn figure_without_a_number_is_ignored() {
        assert!(find_captions(&crate::test_page("Figure: a sketch\n")).is_empty());
    }

    #[test]
    fn caption_indices_count_characters_after_unicode_indentation() {
        let page = crate::test_page("\u{2003}Figure 4: overview\n");
        let captions = find_captions(&page);
        assert_eq!(captions.len(), 1, "{captions:?}");
        assert_eq!(captions[0].start, 1);
        // The box covers the caption's printed characters only. It used to reach one character
        // further, to the newline that ends the line, because the range it was measured from ended
        // there; a line break is not ink, and on the corpus only 4 of 10,020 newline boxes measure
        // more than 0.01 pt across, so the crop moves by nothing measurable.
        assert_eq!(
            captions[0].rect,
            page.chars[1]
                .rect
                .union(page.chars[page.chars.len() - 2].rect)
        );
    }

    #[test]
    fn invalid_unicode_keeps_caption_ranges_aligned_with_raw_characters() {
        let mut page = crate::test_page("Figure 4: overview\n");
        let last = page.chars.len() - 2;
        page.chars[last].unicode = 0x11_0000;
        let captions = find_captions(&page);
        assert_eq!(captions.len(), 1, "{captions:?}");
        assert_eq!(captions[0].end, page.chars.len());
        assert!(captions[0].text.contains(char::REPLACEMENT_CHARACTER));
    }

    #[test]
    fn a_caption_takes_the_lines_that_continue_it() {
        let captions = find_captions(&wrapped_caption_page());
        assert_eq!(captions.len(), 1, "{captions:?}");
        assert_eq!(
            captions[0].text,
            "3: Overview of the method. It wraps onto a second line and a third."
        );
        // The range is the whole caption, not its first line: it ends past the last line's last
        // character, and the box covers all three lines (700 down to 676 of baselines, 8 pt tall).
        // 33 + 1 + 27 + 1 + 12 characters of the three lines, plus the newline that ends the
        // last of them: the range covers the caption and stops there.
        assert_eq!(captions[0].end, 75);
        assert_eq!(captions[0].rect.origin.y, 676.0);
        assert_eq!(captions[0].rect.max_y(), 708.0);
        assert_eq!(
            captions[0].rect.size.height, 32.0,
            "the caption's own box, not one line of it"
        );
    }

    #[test]
    fn a_caption_stops_at_the_body_text_under_it() {
        // The body line is 1 pt larger and 36 pt down: 4.5 glyph heights, well past the measured
        // 1.42 that a continuation can sit at. It must not join the caption.
        let captions = find_captions(&wrapped_caption_page());
        assert!(!captions[0].text.contains("Body text resumes"));
        // Same leading, but a line of a different size is the caption's neighbour, not its text.
        let bigger = page_of(&[
            (50.0, 700.0, 8.0, "Table 2: Results."),
            (50.0, 688.0, 9.0, "Table rows do not belong to the caption."),
        ]);
        let captions = find_captions(&bigger);
        assert_eq!(captions.len(), 1, "{captions:?}");
        assert_eq!(captions[0].text, "2: Results.");
    }

    #[test]
    fn a_caption_stops_at_the_next_caption() {
        let page = page_of(&[
            (50.0, 700.0, 8.0, "Figure 1: First."),
            (50.0, 688.0, 8.0, "Figure 2: Second, on its own."),
            (50.0, 676.0, 8.0, "Its own continuation."),
        ]);
        let captions = find_captions(&page);
        assert_eq!(captions.len(), 2, "{captions:?}");
        assert_eq!(captions[0].text, "1: First.");
        assert_eq!(
            captions[1].text,
            "2: Second, on its own. Its own continuation."
        );
        assert_eq!(captions[1].rect.origin.y, 676.0);
    }

    #[test]
    fn the_other_column_of_a_two_column_page_is_not_the_caption() {
        // A content stream prints both columns of a row together, so the line after a caption can
        // be the other column's. It has to be stepped over, not treated as the caption's end —
        // otherwise every caption in the left column of an interleaved page loses its tail.
        let page = page_of(&[
            (50.0, 700.0, 8.0, "Figure 3: Overview of the method."),
            (320.0, 700.0, 8.0, "The other column sits here."),
            (50.0, 688.0, 8.0, "The caption continues under it,"),
            (50.0, 676.0, 8.0, "and ends here."),
            (320.0, 688.0, 9.0, "More of the other column."),
        ]);
        let captions = find_captions(&page);
        assert_eq!(captions.len(), 1, "{captions:?}");
        assert_eq!(
            captions[0].text,
            "3: Overview of the method. The caption continues under it, and ends here."
        );
        // The box must not grow to the other column's right edge.
        assert!(
            captions[0].rect.max_x() < 300.0,
            "the box followed the other column: {:?}",
            captions[0].rect
        );
    }
}

#[cfg(test)]
mod band_tests {
    use super::*;

    /// Three stacked bands, each one line of 10 pt text, 30 pt apart.
    fn page_with_bands() -> RawTextPage {
        let lines = [
            "[1] Aberman, K.: First entry.",
            "[2] Barzel, R.: Second entry.",
            "[3] Chen, X.: Third entry.",
        ];
        let mut chars = Vec::new();
        for (line, text) in lines.iter().enumerate() {
            let baseline = 800.0 - (line as f64) * 30.0;
            for (column, character) in text.chars().enumerate() {
                chars.push(aris_reader_core::RawCharBox {
                    rect: aris_reader_core::Rect::new(
                        column as f64 * 5.0,
                        baseline - 10.0,
                        5.0,
                        10.0,
                    ),
                    origin: aris_reader_core::Point::new(column as f64 * 5.0, baseline - 10.0),
                    unicode: character as u32,
                    font_size: 10.0,
                    angle: 0.0,
                    font_name: "Body".to_string(),
                });
            }
        }
        RawTextPage {
            page: aris_reader_core::PageIndex(0),
            chars,
            text: lines.join("\n"),
            is_generated: false,
            has_unicode_map_error: false,
        }
    }

    #[test]
    fn bands_split_entries_where_the_links_land() {
        let page = page_with_bands();
        // The three links land on the top edges of the three lines (page space).
        let entries = entries_from_bands(0, &page, &[800.0, 770.0, 740.0]);
        assert_eq!(entries.len(), 3, "{entries:?}");
        assert_eq!(entries[0].label, "1");
        assert!(entries[0].text.contains("First entry"));
        assert_eq!(entries[2].label, "3");
        assert!(entries[2].text.contains("Third entry"));
    }

    #[test]
    fn duplicate_landings_collapse() {
        let page = page_with_bands();
        // Several citations to the same entry land within a point of each other.
        let entries = entries_from_bands(0, &page, &[800.0, 800.4, 770.0, 740.0]);
        assert_eq!(entries.len(), 3);
    }

    #[test]
    fn a_single_landing_is_not_enough_to_build_bands() {
        let page = page_with_bands();
        assert!(entries_from_bands(0, &page, &[800.0]).is_empty());
    }

    #[test]
    fn labels_come_from_the_entry_text() {
        assert_eq!(entry_label("[12] Author, A."), "12");
        assert_eq!(entry_label("21. Jones, M."), "21");
        assert_eq!(
            entry_label("Baevski, A.; Zhou, Y. 2020. wav2vec"),
            "Baevski 2020"
        );
        assert_eq!(entry_label("no label here"), "");
    }
}

#[cfg(test)]
mod reference_tests {
    use super::*;
    use aris_reader_core::RawTextPage;

    fn page_from(text: &str) -> RawTextPage {
        crate::test_page(text)
    }

    #[test]
    fn numeric_entries_are_split_on_their_labels() {
        let text = "[1] First entry about motion.\n[2] Second entry, with a comma.\n";
        let entries = parse_numeric_references(0, &page_from(text));
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].label, "1");
        assert!(entries[0].text.starts_with("First entry"));
        assert_eq!(entries[1].label, "2");
        assert!(entries[1].text.contains("with a comma"));
    }

    #[test]
    fn bracketed_citations_in_prose_are_not_entries() {
        // `[12]` mid-sentence is a citation, not a list entry: the label must start a line.
        let text = "As shown in [12] the method works.\n";
        assert!(parse_numeric_references(0, &page_from(text)).is_empty());
    }

    #[test]
    fn headings_are_recognised_near_the_top_only() {
        assert!(looks_like_reference_heading("References\n[1] A\n"));
        assert!(looks_like_reference_heading("REFERENCES:\n"));
        // A body paragraph that happens to contain the word must not trigger it.
        assert!(!looks_like_reference_heading(
            "1 Introduction\nWe discuss references in Section 5.\n"
        ));
    }

    #[test]
    fn springer_style_numbered_entries_are_parsed() {
        let text = "21. Jones, M., Wang, S.Y.: Customizing text-to-image models (2024)\n22. Song, J.: Denoising diffusion models (2020)\n";
        let entries = parse_numeric_references(0, &page_from(text));
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].label, "21");
        assert!(entries[0].text.starts_with("Jones"));
        assert_eq!(entries[1].label, "22");
    }

    #[test]
    fn author_year_entries_are_keyed_by_surname_and_year() {
        let text = "References\nBaevski, A.; Zhou, Y.; Mohamed, A.; and Auli, M. 2020.\nwav2vec 2.0: A framework.\nHe, L.; Wang, S.; and Liu, Y. 2024. InstructAvatar.\n";
        let entries = parse_author_year_references(0, &page_from(text));
        assert_eq!(entries.len(), 2, "two entries: {entries:?}");
        assert_eq!(entries[0].label, "Baevski 2020");
        assert_eq!(entries[1].label, "He 2024");
    }

    #[test]
    fn author_year_citations_carry_a_surname_year_key() {
        let found = find_citations(&page_from("Prior work (He et al. 2024) agrees"));
        assert_eq!(found.len(), 1);
        assert!(
            found[0].labels.contains(&"He 2024".to_string()),
            "{:?}",
            found[0].labels
        );
    }

    #[test]
    fn a_numeric_citation_resolves_by_position_in_an_unnumbered_list() {
        let references = vec![
            ReferenceEntry {
                label: "Bai 2016".to_string(),
                text: "Artist-directed dynamics".to_string(),
                page: 9,
                start: 0,
                end: 10,
                fragments: Vec::new(),
            },
            ReferenceEntry {
                label: "Barzel 1988".to_string(),
                text: "A modeling system".to_string(),
                page: 9,
                start: 11,
                end: 20,
                fragments: Vec::new(),
            },
        ];

        // `[2]` → the second entry, because the list carries no numbers of its own.
        let resolved = resolve_reference(&["2".to_string()], &references).expect("resolved");
        assert_eq!(resolved.label, "Barzel 1988");

        // An exact label still wins when one exists.
        let resolved = resolve_reference(&["Bai 2016".to_string()], &references).expect("label");
        assert_eq!(resolved.text, "Artist-directed dynamics");

        // A numbered list must not fall back to position.
        let numbered = vec![ReferenceEntry {
            label: "7".to_string(),
            text: "Seven".to_string(),
            page: 0,
            start: 0,
            end: 1,
            fragments: Vec::new(),
        }];
        assert!(resolve_reference(&["2".to_string()], &numbered).is_none());
    }

    #[test]
    fn a_coauthor_is_not_evidence_of_a_matching_work() {
        // A coauthor mention does not make this the work cited as `(He et al. 2024)`.
        let references = vec![ReferenceEntry {
            label: "Baevski 2024".to_string(),
            text: "Baevski, A.; He, L.; and Liu, Y. 2024. InstructAvatar.".to_string(),
            page: 0,
            start: 0,
            end: 0,
            fragments: Vec::new(),
        }];
        assert!(resolve_reference(&["He 2024".to_string()], &references).is_none());
    }

    #[test]
    fn prose_lines_are_not_entry_starts() {
        // Lower-case continuations and ordinary sentences must not split an entry.
        assert!(!looks_like_author_year_start("wav2vec 2.0: A framework."));
        assert!(!looks_like_author_year_start("the model was trained"));
        assert!(looks_like_author_year_start("Baevski, A.; Zhou, Y."));
    }

    #[test]
    fn a_wrapped_line_starting_with_a_number_does_not_end_an_entry() {
        // The bug this pins: "2024." at the start of a continuation line looked like entry 2024.
        let text = "12. Author, A.: A title that wraps\n2024. and continues here.\n13. Next, B.: Another\n";
        let entries = parse_numeric_references(0, &page_from(text));
        assert_eq!(entries.len(), 2, "{entries:?}");
        assert!(
            entries[0].text.contains("continues here"),
            "{}",
            entries[0].text
        );
        assert_eq!(entries[1].label, "13");
    }

    #[test]
    fn a_heading_sharing_its_line_with_the_first_entry_is_found() {
        assert!(looks_like_reference_heading(
            "References [1] Aberman, K. et al. Skeleton-aware networks.\n"
        ));
    }

    #[test]
    fn a_heading_is_found_mid_page() {
        // Real papers often start the list right after the conclusion, not at the page top.
        assert!(looks_like_reference_heading(
            "6 Conclusion\nWe presented a method.\nReferences\n[1] Someone et al.\n"
        ));
    }

    #[test]
    fn the_scan_stops_when_entries_run_out() {
        let first = page_from("References\n[1] One.\n[2] Two.\n");
        let second = page_from("Appendix\nSome unrelated text.\n");
        let entries = find_references([(0u32, &first), (1u32, &second)], 100);
        assert_eq!(
            entries.len(),
            2,
            "the appendix must not be parsed as references"
        );
    }
}

// ---------------------------------------------------------------------------
// Citations (M4)
// ---------------------------------------------------------------------------

/// A citation found in the body text.
#[derive(Clone, Debug, PartialEq)]
pub struct Citation {
    /// The text as it appears, e.g. `[12,13]` or `He et al. 2024`.
    pub text: String,
    /// Reference labels it names. Numeric styles give concrete numbers (`12`, `13`, and the
    /// expansion of ranges like `12-14`); author-year styles use surname + year,
    /// including a disambiguating suffix such as `Ma 2023b`.
    pub labels: Vec<String>,
    /// Bounding box in **page space** (the union of the character boxes).
    pub rect: Rect,
    /// Half-open character range inside the page's text layer.
    pub start: usize,
    pub end: usize,
}

/// Finds citations in a page's text layer.
///
/// Two styles are recognised because the corpus splits roughly evenly between them, and a
/// detector that knows only one silently reports nothing for half the papers:
///
/// * numeric — `[12]`, `[12,13]`, `[12-14]`
/// * author-year — `(He et al. 2024)`, `(Kim and Lee, 2023)`, `(A, 2024; B, 2022)`
///
/// A third style — superscript numerals, `winds5,6,23-26` — needs the bibliography to
/// corroborate a run, so it is only found by [`find_citations_with`]. This function is the two
/// styles that need nothing but the page, which is what the CLI's span *count* (`inspect`) and
/// the crate's own tests ask for.
pub fn find_citations(text: &RawTextPage) -> Vec<Citation> {
    find_citations_with(text, &CitationStyle::numeric_only())
}

/// Finds citations in a page's text layer, using what the document's bibliography says about the
/// citation style.
///
/// `style` is built once per document with [`CitationStyle::for_document`] from the same entry
/// list the resolver uses and the body pages being read. Beyond the bracket and author-year
/// styles of
/// [`find_citations`], it enables superscript numerals: a run of raised, smaller glyphs whose
/// labels all exist in the reference list, in a document whose list is numbered. See
/// [`superscript`](crate::superscript) for the thresholds and the measurements behind them.
pub fn find_citations_with(text: &RawTextPage, style: &CitationStyle) -> Vec<Citation> {
    let mut found = find_bracketed_citations(text);
    found.extend(superscript::find(text, style));
    if style.uses_alphanumeric_labels() {
        found.extend(alphanumeric::citations(text));
    }
    // Two detectors, one reading order: the CLI prints the spans in the order they appear, and a
    // superscript run inside a bracket group is impossible, so only the order needs merging.
    found.sort_by_key(|citation| (citation.start, citation.end));
    found
}

/// The bracket and author-year detectors: everything that needs nothing but the page.
fn find_bracketed_citations(text: &RawTextPage) -> Vec<Citation> {
    let chars: Vec<char> = text
        .chars
        .iter()
        .map(|character| char::from_u32(character.unicode).unwrap_or(char::REPLACEMENT_CHARACTER))
        .collect();

    let mut found = Vec::new();
    let mut index = 0;

    while index < chars.len() {
        // Author-year: a parenthesised span containing a plausible year and real words.
        if chars[index] == '(' {
            let mut close = index + 1;
            while close < chars.len()
                && close - index <= 90
                && chars[close] != ')'
                && chars[close] != '('
            {
                close += 1;
            }
            let inner: String = chars[index + 1..close.min(chars.len())]
                .iter()
                .copied()
                .filter(|c| !c.is_control() || c.is_whitespace())
                .collect();
            let letters = inner
                .chars()
                .filter(|character| character.is_alphabetic())
                .count();
            if close < chars.len()
                && chars[close] == ')'
                && letters >= 3
                && first_year(&inner).is_some()
            {
                // Author-year lists have no numbers, so the matching key is "first surname
                // + year" -- the same key `parse_author_year_references` builds for the
                // entries themselves. A group carries one key per work it names.
                let labels = citation_labels(&inner);
                if labels.is_empty() {
                    index = close + 1;
                    continue;
                }
                found.push(Citation {
                    text: inner.trim().to_string(),
                    labels,
                    rect: union_boxes(&text.chars[index..=close]),
                    start: index,
                    end: close + 1,
                });
                index = close + 1;
                continue;
            }
            index += 1;
            continue;
        }

        // Numeric: `[` digits and separators `]`.
        if chars[index] != '[' {
            index += 1;
            continue;
        }
        let mut end = index + 1;
        while end < chars.len()
            && end - index <= 12
            && (chars[end].is_ascii_digit()
                || chars[end] == ','
                || matches!(chars[end], '-' | '–' | '−')
                || chars[end] == ' ')
        {
            end += 1;
        }
        let has_digit = chars[index + 1..end].iter().any(char::is_ascii_digit);
        if end < chars.len() && chars[end] == ']' && has_digit {
            let inner: String = chars[index + 1..end].iter().collect();
            // ACM also uses narrative citations: `Lasseter [1987]` and
            // `Wang et al. [2006]`. A four-digit year is not an ordinal.
            let narrative = first_year(&inner)
                .filter(|year| year == &inner)
                .and_then(|year| {
                    preceding_author(&chars, index)
                        .map(|(start, author)| (start, format!("{author} {year}")))
                });
            let start = narrative.as_ref().map(|(start, _)| *start).unwrap_or(index);
            found.push(Citation {
                text: chars[start..=end].iter().collect(),
                labels: narrative
                    .map(|(_, label)| vec![label])
                    .unwrap_or_else(|| numeric_labels(&inner)),
                rect: union_boxes(&text.chars[start..=end]),
                start,
                end: end + 1,
            });
            index = end + 1;
        } else {
            index += 1;
        }
    }

    found
}

/// Every work a parenthesised citation names, as `surname year` keys.
///
/// Author-year groups list several works at once — `(He et al. 2024; Kim 2023)`,
/// `(Smith, 2020; Jones and Lee, 2021)` — and each `;`-separated part is a work of its own.
/// A part with no name-like word (a bare year, or a month like `(July 2017)`) contributes
/// nothing; when no part does, the caller records no citation at all.
fn citation_labels(inner: &str) -> Vec<String> {
    let mut labels = Vec::new();
    for part in inner.split(';') {
        let (Some(year), Some(surname)) = (first_year(part), citation_surname(part)) else {
            continue;
        };
        let label = format!("{surname} {year}");
        if !labels.contains(&label) {
            labels.push(label);
        }
    }
    labels
}

fn citation_surname(text: &str) -> Option<String> {
    let surname = first_surname(text)?;
    let prefix = text.split(" et al").next()?.trim();
    if prefix != text.trim()
        && !prefix.contains([',', ';'])
        && prefix
            .split_whitespace()
            .all(|word| first_surname(word).as_deref() == Some(word))
    {
        Some(prefix.split_whitespace().collect::<Vec<_>>().join(" "))
    } else {
        Some(surname)
    }
}

fn preceding_author(chars: &[char], bracket: usize) -> Option<(usize, String)> {
    let mut end = bracket;
    while end > 0 && chars[end - 1].is_whitespace() {
        end -= 1;
    }
    let mut start = end;
    let mut words = Vec::new();
    for _ in 0..3 {
        while start > 0 && !chars[start - 1].is_whitespace() {
            start -= 1;
        }
        words.push((start, chars[start..end].iter().collect::<String>()));
        end = start;
        while end > 0 && chars[end - 1].is_whitespace() {
            end -= 1;
        }
        start = end;
    }
    let (last_start, last) = words.first()?;
    let author = if matches!(last.as_str(), "al." | "al") && words.get(1)?.1 == "et"
        || words.get(1).is_some_and(|(_, word)| word == "and")
    {
        words.get(2)?
    } else {
        &(*last_start, last.clone())
    };
    let name = first_surname(&author.1)?;
    (name == author.1).then_some((author.0, name))
}

/// Expands `12,13` and `12-14` into the individual labels a reference list can be keyed by.
fn numeric_labels(inner: &str) -> Vec<String> {
    let mut labels = Vec::new();
    for part in inner.split(',') {
        let part = part.trim();
        if let Some((from, to)) = part.split_once(['-', '–', '−'])
            && let (Ok(from), Ok(to)) = (from.trim().parse::<u32>(), to.trim().parse::<u32>())
            && from <= to
            && to - from <= 40
        {
            labels.extend((from..=to).map(|number| number.to_string()));
            continue;
        }
        if !part.is_empty() && part.chars().all(|character| character.is_ascii_digit()) {
            labels.push(part.to_string());
        }
    }
    labels
}

/// First plausible four-digit year in a span.
fn first_year(text: &str) -> Option<String> {
    let chars: Vec<char> = text.chars().collect();
    chars.windows(4).enumerate().find_map(|(i, window)| {
        if !window.iter().all(char::is_ascii_digit)
            || i.checked_sub(1).is_some_and(|p| chars[p].is_alphanumeric())
            || chars.get(i + 4).is_some_and(char::is_ascii_digit)
            || (chars.get(i + 4) == Some(&'.')
                && chars.get(i + 5).is_some_and(char::is_ascii_digit))
        {
            return None;
        }
        let year: u32 = window.iter().collect::<String>().parse().ok()?;
        if !(1900..2100).contains(&year) {
            return None;
        }
        let suffix = chars.get(i + 4).is_some_and(char::is_ascii_lowercase)
            && !chars.get(i + 5).is_some_and(|c| c.is_alphanumeric());
        Some(chars[i..i + 4 + usize::from(suffix)].iter().collect())
    })
}

/// Union of a run of character boxes (page space).
fn union_boxes(chars: &[RawCharBox]) -> Rect {
    chars
        .iter()
        .fold(None::<Rect>, |accumulated, character| {
            let rect = character.rect;
            Some(match accumulated {
                None => rect,
                Some(current) => {
                    let min_x = current.origin.x.min(rect.origin.x);
                    let min_y = current.origin.y.min(rect.origin.y);
                    let max_x = (current.origin.x + current.size.width)
                        .max(rect.origin.x + rect.size.width);
                    let max_y = (current.origin.y + current.size.height)
                        .max(rect.origin.y + rect.size.height);
                    Rect::new(min_x, min_y, max_x - min_x, max_y - min_y)
                }
            })
        })
        .unwrap_or(Rect::new(0.0, 0.0, 0.0, 0.0))
}

#[cfg(test)]
pub(crate) fn test_page(text: &str) -> RawTextPage {
    use aris_reader_core::{PageIndex, RawCharBox, RawTextPage, Rect};
    RawTextPage {
        page: PageIndex(0),
        chars: text
            .chars()
            .enumerate()
            .map(|(index, character)| RawCharBox {
                rect: Rect::new(index as f64 * 5.0, 700.0, 5.0, 10.0),
                origin: aris_reader_core::Point::new(index as f64 * 5.0, 700.0),
                unicode: character as u32,
                font_size: 10.0,
                angle: 0.0,
                font_name: "Body".to_string(),
            })
            .collect(),
        text: text.to_string(),
        is_generated: false,
        has_unicode_map_error: false,
    }
}

#[cfg(test)]
mod citation_tests {
    use super::*;

    fn page(text: &str) -> RawTextPage {
        crate::test_page(text)
    }

    #[test]
    fn numeric_citations_expand_their_labels() {
        let found = find_citations(&page("As shown in [12,13] and [7-9] we see"));
        assert_eq!(found.len(), 2);
        assert_eq!(found[0].labels, vec!["12", "13"]);
        assert_eq!(found[1].labels, vec!["7", "8", "9"]);
        assert_eq!(found[0].text, "[12,13]");
    }

    #[test]
    fn author_year_citations_are_found() {
        let found = find_citations(&page("Prior work (He et al. 2024) agrees"));
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].labels, vec!["He 2024"]);
    }

    #[test]
    fn citations_carry_a_real_box() {
        let found = find_citations(&page("see [3] here"));
        assert_eq!(found.len(), 1);
        // Five points per character: the box spans `[3]` on the text's baseline band.
        assert!(found[0].rect.size.width >= 15.0);
        assert_eq!(found[0].rect.origin.y, 700.0);
    }

    #[test]
    fn parentheses_without_a_year_are_not_citations() {
        assert!(find_citations(&page("a (parenthetical aside) here")).is_empty());
    }
}

// ---------------------------------------------------------------------------
// Geometric block segmentation (M4)
// ---------------------------------------------------------------------------

/// Groups a page's characters into lines.
///
/// Geometry first, semantics later: lines are the one unit the text layer really supports —
/// characters sharing a baseline — and blocks, columns and entries are built from them.
///
/// Two data properties drove the rules here, both measured on the sample corpus:
///
/// * whitespace often arrives with no glyph box, so it must not take part in the adjacency test
///   (otherwise every space splits a line);
/// * a line break is whitespace too, but it must *end* a line rather than continue it.
pub fn lines_from(raw: &RawTextPage) -> Vec<TextLine> {
    if raw.chars.is_empty() {
        return Vec::new();
    }

    let mut order: Vec<usize> = (0..raw.chars.len()).collect();
    order.sort_by(|left, right| {
        let a = &raw.chars[*left];
        let b = &raw.chars[*right];
        // Sort by the *baseline* origin, not by the bottom of the ink box: a descender's box
        // reaches lower than a capital's, and grouping on that bottom split one printed line
        // into a dozen fragments. `RawCharBox::origin` is the text origin PDFium reports.
        b.origin
            .y
            .partial_cmp(&a.origin.y)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(
                a.origin
                    .x
                    .partial_cmp(&b.origin.x)
                    .unwrap_or(std::cmp::Ordering::Equal),
            )
    });

    let smallest = raw
        .chars
        .iter()
        .map(|character| character.rect.size.height)
        .filter(|height| *height > 0.0)
        .fold(f64::MAX, f64::min);
    let tolerance = (smallest / 2.0).max(1.0);

    let mut widths: Vec<f64> = raw
        .chars
        .iter()
        .map(|character| character.rect.size.width)
        .filter(|width| *width > 0.0)
        .collect();
    widths.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let median_width = widths.get(widths.len() / 2).copied().unwrap_or(5.0);

    // Wider than a space: a column gutter, a tab, or the jump between two text runs.
    let max_advance = (median_width * 3.0).max(15.0);

    let mut lines: Vec<TextLine> = Vec::new();
    // The baseline each line was started at. `TextLine::rect` is the union of ink boxes and
    // its bottom is not a baseline, so the two cannot share one field.
    let mut baselines: Vec<f64> = Vec::new();
    let mut visible_right: Vec<f64> = Vec::new();
    let mut pending_break = false;

    for index in order {
        let character = &raw.chars[index];
        let decoded = char::from_u32(character.unicode);
        let is_break = matches!(decoded, Some('\n') | Some('\r'));
        let is_space = decoded
            .map(|character| character.is_whitespace() && !is_break)
            .unwrap_or(false);

        if is_break {
            pending_break = true;
            continue;
        }

        if is_space {
            // A whitespace character never starts a line.
            //
            // PDFium reports the spaces of a line at the *space's own* y, which need not equal
            // the glyph baseline: on the twelve-paper corpus, several arXiv/LaTeX files place a
            // line's spaces a few points above it. Sorting by baseline then put every space in a
            // zero-height line of its own, and the real line lost its word breaks ("thequick").
            // Whitespace is therefore not copied into the text at all; the gap between adjacent
            // glyph boxes is the reliable evidence of a word break, and is turned into one space
            // below. `pending_break` deliberately survives a space, so a newline followed by
            // indentation still starts a new line at the next glyph.
            continue;
        }

        let starts_new_line = match lines.last() {
            None => true,
            Some(line) => {
                let reference = visible_right
                    .last()
                    .copied()
                    .unwrap_or(line.rect.origin.x + line.rect.size.width);
                let baseline = baselines.last().copied().unwrap_or(line.rect.origin.y);
                pending_break
                    || (baseline - character.origin.y).abs() > tolerance
                    || character.origin.x - reference > max_advance
            }
        };

        if starts_new_line {
            let mut line = TextLine {
                rect: character.rect,
                range: (index as u32)..(index as u32 + 1),
                text: decoded.map(|c| c.to_string()).unwrap_or_default(),
                ink: Vec::new(),
            };
            push_ink(&mut line, character.rect);
            lines.push(line);
            baselines.push(character.origin.y);
            visible_right.push(character.rect.origin.x + character.rect.size.width);
        } else if let Some(line) = lines.last_mut() {
            let reference = visible_right
                .last()
                .copied()
                .unwrap_or(line.rect.origin.x + line.rect.size.width);
            let gap = character.origin.x - reference;
            line.rect = union_rect(line.rect, character.rect);
            line.range.end = line.range.end.max(index as u32 + 1);
            if let Some(character) = decoded {
                // Wider than kerning: this is the space the producer did not draw as a glyph.
                if gap > INK_RUN_GAP_PT && !line.text.is_empty() && !line.text.ends_with(' ') {
                    line.text.push(' ');
                }
                line.text.push(character);
            }
            push_ink(line, character.rect);
            if let Some(right) = visible_right.last_mut() {
                *right = character.rect.origin.x + character.rect.size.width;
            }
        }

        pending_break = false;
    }

    // Characters reach a line in reading order, which is by baseline first: a superscript can
    // therefore arrive after the glyphs that sit to its right. Sorting and merging here gives
    // every consumer runs that are disjoint and left to right, whatever the extraction order was.
    for line in lines.iter_mut() {
        line.ink = merge_ink_runs(std::mem::take(&mut line.ink));
    }

    lines
}

/// Adds one character box to a line's runs, keeping them in the order the boxes arrive.
///
/// A box with no width is a character the extractor placed but did not measure — a soft hyphen,
/// a zero-advance mark — and drawing nothing is what it does.
fn push_ink(line: &mut TextLine, rect: Rect) {
    if rect.size.width <= 0.0 {
        return;
    }
    line.ink.push(InkRun {
        from: rect.origin.x,
        to: rect.max_x(),
    });
}

/// Sorts character runs left to right and fuses those that touch, so the result is disjoint.
fn merge_ink_runs(mut runs: Vec<InkRun>) -> Vec<InkRun> {
    runs.sort_by(|left, right| left.from.total_cmp(&right.from));
    let mut merged: Vec<InkRun> = Vec::with_capacity(runs.len());
    for run in runs {
        match merged.last_mut() {
            Some(last) if run.from <= last.to + INK_RUN_GAP_PT => last.to = last.to.max(run.to),
            _ => merged.push(run),
        }
    }
    merged
}

/// Buckets a left edge so lines from the same column compare equal.
fn column_index(rect: Rect) -> i64 {
    (rect.origin.x / 20.0).round() as i64
}

fn union_rect(a: Rect, b: Rect) -> Rect {
    let min_x = a.origin.x.min(b.origin.x);
    let min_y = a.origin.y.min(b.origin.y);
    let max_x = (a.origin.x + a.size.width).max(b.origin.x + b.size.width);
    let max_y = (a.origin.y + a.size.height).max(b.origin.y + b.size.height);
    Rect::new(min_x, min_y, max_x - min_x, max_y - min_y)
}

/// Groups lines into blocks: same column, vertically adjacent, no paragraph-sized gap.
///
/// `gap_factor` is the multiple of the median line height that still reads as "same paragraph";
/// 0.8 suits tight academic setting.
pub fn blocks_from(lines: &[TextLine], gap_factor: f64) -> Vec<TextBlock> {
    if lines.is_empty() {
        return Vec::new();
    }

    let mut heights: Vec<f64> = lines
        .iter()
        .map(|line| line.rect.size.height)
        .filter(|height| *height > 0.0)
        .collect();
    heights.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let median_height = heights.get(heights.len() / 2).copied().unwrap_or(10.0);
    let max_gap = median_height * gap_factor;

    let mut blocks: Vec<TextBlock> = Vec::new();
    for line in lines {
        // Match against *any* block, not just the previous line: with columns separated, line
        // order interleaves them (left-1, right-1, left-2, right-2), so the previous line is not
        // the one this line continues.
        let mut target: Option<usize> = None;
        for (index, block) in blocks.iter().enumerate() {
            let Some(previous) = block.lines.last() else {
                continue;
            };
            let gap = previous.rect.origin.y - (line.rect.origin.y + line.rect.size.height);
            let overlaps_horizontally = line.rect.origin.x
                < previous.rect.origin.x + previous.rect.size.width
                && previous.rect.origin.x < line.rect.origin.x + line.rect.size.width;

            if gap >= 0.0
                && gap <= max_gap
                && overlaps_horizontally
                && column_index(block.rect) == column_index(line.rect)
            {
                target = Some(index);
                break;
            }
        }

        match target {
            Some(index) => {
                let block = &mut blocks[index];
                block.rect = union_rect(block.rect, line.rect);
                block.text.push(' ');
                block.text.push_str(line.text.trim());
                block.lines.push(line.clone());
            }
            None => blocks.push(TextBlock {
                rect: line.rect,
                lines: vec![line.clone()],
                text: line.text.trim().to_string(),
                is_heading: false,
            }),
        }
    }

    for block in blocks.iter_mut() {
        block.text = block.text.split_whitespace().collect::<Vec<_>>().join(" ");
        block.is_heading = block.lines.len() == 1 && block.text.chars().count() <= 60;
    }

    blocks
}

#[cfg(test)]
mod block_tests {
    use super::*;
    use aris_reader_core::{PageIndex, Point, RawCharBox, RawTextPage, Rect};

    /// A page built from `(x, top, text)` runs, each character 5 pt wide and 10 pt tall.
    fn page_of_lines(lines: &[(f64, f64, &str)]) -> RawTextPage {
        let mut chars = Vec::new();
        for (x, top, text) in lines {
            for (column, character) in text.chars().enumerate() {
                chars.push(RawCharBox {
                    rect: Rect::new(x + column as f64 * 5.0, top - 10.0, 5.0, 10.0),
                    origin: Point::new(x + column as f64 * 5.0, top - 10.0),
                    unicode: character as u32,
                    font_size: 10.0,
                    angle: 0.0,
                    font_name: "Body".to_string(),
                });
            }
        }
        RawTextPage {
            page: PageIndex(0),
            chars,
            text: String::new(),
            is_generated: false,
            has_unicode_map_error: false,
        }
    }

    #[test]
    fn one_baseline_becomes_one_line() {
        let page = page_of_lines(&[(100.0, 800.0, "hello"), (130.0, 800.0, "world")]);
        let lines = lines_from(&page);
        assert_eq!(lines.len(), 1, "{lines:?}");
        assert!(lines[0].text.contains("hello") && lines[0].text.contains("world"));
    }

    #[test]
    fn a_space_with_no_box_does_not_split_a_line() {
        // Exactly what PDFium produces: the space has a degenerate box, sitting far from the next
        // glyph because the producer gave it no advance.
        let mut page = page_of_lines(&[(100.0, 800.0, "hello"), (130.0, 800.0, "world")]);
        page.chars.insert(
            5,
            RawCharBox {
                rect: Rect::new(126.0, 790.0, 0.0, 0.0),
                origin: Point::new(126.0, 790.0),
                unicode: ' ' as u32,
                font_size: 0.0,
                angle: 0.0,
                font_name: "Body".to_string(),
            },
        );
        let lines = lines_from(&page);
        assert_eq!(lines.len(), 1, "a space must not break the line: {lines:?}");
    }

    #[test]
    fn a_gap_splits_paragraphs() {
        let page = page_of_lines(&[
            (100.0, 800.0, "first line of the paragraph"),
            (100.0, 790.0, "second line of the paragraph"),
            (100.0, 780.0, "third line of the paragraph"),
            (100.0, 750.0, "a separate entry"),
        ]);
        let blocks = blocks_from(&lines_from(&page), 0.8);
        assert_eq!(blocks.len(), 2, "{blocks:?}");
        assert_eq!(blocks[0].lines.len(), 3);
    }

    #[test]
    fn columns_do_not_merge() {
        let page = page_of_lines(&[
            (50.0, 800.0, "left column line one"),
            (50.0, 790.0, "left column line two"),
            (320.0, 800.0, "right column line one"),
            (320.0, 790.0, "right column line two"),
        ]);
        let blocks = blocks_from(&lines_from(&page), 0.8);
        assert_eq!(blocks.len(), 2, "{blocks:?}");
        assert!(blocks.iter().all(|block| block.lines.len() == 2));
    }
}

// ---------------------------------------------------------------------------
// Locating the reference region (M4)
// ---------------------------------------------------------------------------

/// Where a document's reference list lives.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ReferenceRegion {
    pub from_page: u32,
    pub to_page: u32,
    /// Mean page score across the region; higher is more confident.
    pub score: f64,
}

/// How much a page looks like part of a reference list.
///
/// Deliberately a *combination of weak signals* rather than one strong rule, because no single
/// feature of this corpus is reliable: headings vary in wording and position, numbering styles
/// differ, and some bibliographies have no numbers at all. Density is what separates the two kinds
/// of page in practice — a body page is full of citation *mentions* in prose, a reference page is
/// full of entry *starts* — so that comparison carries the most weight.
pub fn reference_page_score(text: &RawTextPage) -> f64 {
    let lines = lines_from(text);
    if lines.is_empty() {
        return 0.0;
    }

    let page_text: String = text
        .chars
        .iter()
        .filter_map(|character| char::from_u32(character.unicode))
        .collect();
    let heading = if looks_like_reference_heading(&page_text) {
        1.0
    } else {
        0.0
    };

    let mut entry_starts = 0usize;
    let mut surnames: Vec<String> = Vec::new();
    for line in &lines {
        let trimmed = line.text.trim();
        if trimmed.chars().count() < 4 {
            continue;
        }
        let label = entry_label(trimmed);
        if label.is_empty() {
            continue;
        }
        entry_starts += 1;
        if let Some(surname) = label.split_whitespace().next() {
            surnames.push(surname.to_ascii_lowercase());
        }
    }

    // Mentions inside prose: bracketed numbers that are *not* at a line start.
    let brackets = page_text.matches('[').count();
    let prose_mentions = brackets.saturating_sub(entry_starts);

    let ordered = surnames
        .windows(2)
        .filter(|pair| pair[0] <= pair[1])
        .count();
    let alphabetical = if surnames.len() >= 4 {
        ordered as f64 / (surnames.len() - 1) as f64
    } else {
        0.0
    };

    let line_count = lines.len().max(1) as f64;
    let entry_density = (entry_starts as f64 / line_count / 0.5).min(1.0);
    let prose_density = (prose_mentions as f64 / line_count / 0.3).min(1.0);

    2.0 * heading + 2.0 * entry_density + 1.0 * alphabetical - 1.5 * prose_density
}

/// Finds the longest run of consecutive pages that look like a reference list.
///
/// `pages` must be in reading order. A single non-candidate page is allowed inside a run, because
/// a list can be interrupted (a figure, a page break artefact) without ending.
pub fn locate_reference_region(pages: &[(u32, RawTextPage)]) -> Option<ReferenceRegion> {
    // Measured: real reference pages in the sample corpus score 1.1-3.1 while body pages sit near
    // 0 (prose is full of citation mentions, which the score penalises), so 1.0 separates them with
    // margin. A stricter 1.5 cut a genuine list page out of the middle of one region and cost that
    // paper half its entries.
    const THRESHOLD: f64 = 1.0;

    let scored: Vec<(u32, f64)> = pages
        .iter()
        .map(|(page, text)| (*page, reference_page_score(text)))
        .collect();

    let mut best: Option<ReferenceRegion> = None;
    let mut start: Option<usize> = None;
    let mut gap = 0usize;
    let mut index = 0usize;

    while index <= scored.len() {
        let candidate = scored
            .get(index)
            .map(|(_, score)| *score >= THRESHOLD)
            .unwrap_or(false);

        if candidate {
            start.get_or_insert(index);
            gap = 0;
        } else if let Some(begin) = start {
            gap += 1;
            if gap > 1 || index == scored.len() {
                let end = index.saturating_sub(gap);
                if end >= begin {
                    let scores: Vec<f64> = scored[begin..=end].iter().map(|(_, s)| *s).collect();
                    let mean = scores.iter().sum::<f64>() / scores.len() as f64;
                    let region = ReferenceRegion {
                        from_page: scored[begin].0,
                        to_page: scored[end].0,
                        score: mean,
                    };
                    if best
                        .map(|current| region.score > current.score)
                        .unwrap_or(true)
                    {
                        best = Some(region);
                    }
                }
                start = None;
                gap = 0;
            }
        }

        index += 1;
    }

    best
}

#[cfg(test)]
mod region_tests {
    use super::*;
    use aris_reader_core::{PageIndex, Point, RawCharBox, RawTextPage, Rect};

    fn page_of(text: &str) -> RawTextPage {
        let mut chars = Vec::new();
        for (row, line) in text.lines().enumerate() {
            for (column, character) in line.chars().enumerate() {
                chars.push(RawCharBox {
                    rect: Rect::new(column as f64 * 5.0, 800.0 - row as f64 * 12.0, 5.0, 10.0),
                    origin: Point::new(column as f64 * 5.0, 800.0 - row as f64 * 12.0),
                    unicode: character as u32,
                    font_size: 10.0,
                    angle: 0.0,
                    font_name: "Body".to_string(),
                });
            }
        }
        RawTextPage {
            page: PageIndex(0),
            chars,
            text: text.to_string(),
            is_generated: false,
            has_unicode_map_error: false,
        }
    }

    #[test]
    fn a_body_page_scores_lower_than_a_reference_page() {
        let body = page_of(
            "1 Introduction\nAs shown in [12] and [15], the method works (Kim et al. 2023).\n\
             We compare against [3] and [22] on several benchmarks.\n",
        );
        let references = page_of(
            "References\n[1] Aberman, K.: First work on the topic.\n[2] Barzel, R.: Second work.\n\
             [3] Chen, X.: Third work.\n[4] Dhariwal, P.: Fourth work.\n",
        );
        assert!(
            reference_page_score(&references) > reference_page_score(&body),
            "reference {} vs body {}",
            reference_page_score(&references),
            reference_page_score(&body)
        );
    }

    #[test]
    fn the_region_is_the_run_of_reference_pages() {
        let pages = vec![
            (0u32, page_of("1 Introduction\nWe cite [1] and [2] here.\n")),
            (
                1u32,
                page_of("2 Method\nOur approach [3] improves on [4].\n"),
            ),
            (
                2u32,
                page_of(
                    "References\n[1] Aberman, K.: First.\n[2] Barzel, R.: Second.\n[3] Chen, X.: Third.\n",
                ),
            ),
            (
                3u32,
                page_of("[4] Dhariwal, P.: Fourth.\n[5] Evans, R.: Fifth.\n[6] Fox, T.: Sixth.\n"),
            ),
        ];
        let region = locate_reference_region(&pages).expect("a region");
        assert_eq!((region.from_page, region.to_page), (2, 3), "{region:?}");
    }

    #[test]
    fn a_document_without_references_has_no_region() {
        let pages = vec![
            (0u32, page_of("1 Introduction\nWe cite [1] and [2] here.\n")),
            (
                1u32,
                page_of("2 Method\nOur approach [3] improves on [4].\n"),
            ),
        ];
        assert!(locate_reference_region(&pages).is_none());
    }
}
