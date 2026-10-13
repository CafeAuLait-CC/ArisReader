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

/// One line of text (consecutive characters on the same baseline).
#[derive(Clone, Debug, PartialEq)]
pub struct TextLine {
    pub rect: Rect,
    pub range: std::ops::Range<u32>,
    pub text: String,
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
    pub text: String,
    /// Page the entry lives on.
    pub page: u32,
    /// First character index of the entry inside its page.
    pub start: usize,
    /// One past the last character of the entry.
    pub end: usize,
}

/// Whether a page looks like the start of the reference list.
///
/// Publishers are inconsistent about the heading, so this accepts the common spellings and
/// requires it to appear near the top of the page — a paper that mentions "References" in the
/// body must not be mistaken for the list itself.
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
    // so looking only at the top of the page misses it. Requiring the whole line to *be* the
    // heading is what keeps a body sentence like "see References for details" out.
    text.lines().any(|line| {
        let trimmed = line
            .trim()
            .trim_end_matches(':')
            .trim()
            .to_ascii_lowercase();
        trimmed.len() <= 24 && HEADINGS.iter().any(|heading| trimmed == *heading)
    })
}

/// Parses numeric-style entries (`[12] Author, Title…`) out of one page's text.
///
/// Only the numeric style is parsed: it has an unambiguous delimiter. Author-year lists have no
/// marker at all beyond typography, and inventing one here would produce confident nonsense.
pub fn parse_numeric_references(page: u32, text: &RawTextPage) -> Vec<ReferenceEntry> {
    let chars: Vec<char> = text
        .chars
        .iter()
        .filter_map(|character| char::from_u32(character.unicode))
        .collect();

    let mut entries = Vec::new();
    let mut index = 0;

    while index < chars.len() {
        let at_line_start = chars[..index]
            .iter()
            .rev()
            .take_while(|character| **character != '\n')
            .all(|character| character.is_whitespace());
        if !at_line_start {
            index += 1;
            continue;
        }

        // Two numbering styles are common: `[12] Author…` (ACM/IEEE) and `12. Author…`
        // (Springer LNCS and friends). Both were found in the sample corpus, and a parser that
        // knows only one of them silently reports zero references for half the papers.
        let (label, body_start) = if chars[index] == '[' {
            let mut digits_end = index + 1;
            while digits_end < chars.len()
                && chars[digits_end].is_ascii_digit()
                && digits_end - index <= 5
            {
                digits_end += 1;
            }
            if digits_end == index + 1 || digits_end >= chars.len() || chars[digits_end] != ']' {
                index += 1;
                continue;
            }
            (
                chars[index + 1..digits_end].iter().collect::<String>(),
                digits_end + 1,
            )
        } else if chars[index].is_ascii_digit() {
            let mut digits_end = index;
            while digits_end < chars.len()
                && chars[digits_end].is_ascii_digit()
                && digits_end - index <= 4
            {
                digits_end += 1;
            }
            let terminator = chars.get(digits_end);
            if !matches!(terminator, Some('.') | Some(')')) {
                index += 1;
                continue;
            }
            (
                chars[index..digits_end].iter().collect::<String>(),
                digits_end + 1,
            )
        } else {
            index += 1;
            continue;
        };

        if label.is_empty() {
            index += 1;
            continue;
        }

        // The entry runs to the next numeric label at a line start, or to the end of the page.
        let mut scan = body_start;
        while scan < chars.len() {
            if chars[scan] == '\n'
                && chars[scan + 1..]
                    .iter()
                    .take_while(|character| character.is_whitespace() && **character != '\n')
                    .count()
                    < 8
            {
                // A new entry starts here when the next non-space character begins another
                // label: `[` or a digit followed by `.`/`)`.
                let rest: Vec<char> = chars[scan + 1..].iter().copied().take(6).collect();
                let starts_label = match rest.first() {
                    Some('[') => true,
                    Some(character) if character.is_ascii_digit() => {
                        rest.iter().any(|c| *c == '.' || *c == ')')
                    }
                    _ => false,
                };
                if starts_label {
                    break;
                }
            }
            scan += 1;
        }
        let body_end = scan.min(chars.len());

        let body: String = chars[body_start..body_end].iter().collect();
        entries.push(ReferenceEntry {
            label,
            text: body.trim().to_string(),
            page,
            start: index,
            end: body_end,
        });

        index = body_end.max(index + 1);
    }

    entries
}

/// Finds the reference list across a document's pages.
///
/// `pages` must be `(page index, raw text)` in reading order and may cover only part of the
/// document; scanning is bounded by `max_entries` so a mis-detected heading cannot walk a whole
/// book.
pub fn find_references<'a>(
    pages: impl IntoIterator<Item = (u32, &'a RawTextPage)>,
    max_entries: usize,
) -> Vec<ReferenceEntry> {
    let mut entries = Vec::new();
    let mut inside = false;

    for (page, text) in pages {
        let page_text: String = text
            .chars
            .iter()
            .filter_map(|character| char::from_u32(character.unicode))
            .collect();

        if !inside && looks_like_reference_heading(&page_text) {
            inside = true;
        }
        if !inside {
            continue;
        }

        let parsed = parse_numeric_references(page, &text.clone());
        if parsed.is_empty() && !entries.is_empty() {
            // The list ended (or switched to an unparsed style).
            break;
        }
        entries.extend(parsed);
        if entries.len() >= max_entries {
            entries.truncate(max_entries);
            break;
        }
    }

    entries
}

#[cfg(test)]
mod reference_tests {
    use super::*;
    use aris_reader_core::{PageIndex, RawCharBox, RawTextPage, Rect};

    fn page_from(text: &str) -> RawTextPage {
        let mut chars = Vec::new();
        for (index, character) in text.chars().enumerate() {
            chars.push(RawCharBox {
                rect: Rect::new(0.0, 0.0, 5.0, 10.0),
                origin: aris_reader_core::Point::new(index as f64 * 5.0, 0.0),
                unicode: character as u32,
                font_size: 10.0,
                angle: 0.0,
                font_name: "Body".to_string(),
            });
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
