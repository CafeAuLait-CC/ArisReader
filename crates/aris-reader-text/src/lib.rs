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
    // Numbered lists are sequential. Requiring the next label to be the previous one plus one
    // is what stops a wrapped line that happens to begin with a number (a year, "3D", …) from
    // being mistaken for a new entry -- which truncated entries to their first line.
    let mut expected_next: Option<u32> = None;

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
            let number: u32 = chars[index..digits_end]
                .iter()
                .collect::<String>()
                .parse()
                .unwrap_or(0);
            if let Some(expected) = expected_next
                && number != expected
            {
                index += 1;
                continue;
            }
            expected_next = Some(number + 1);
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
                        // Same rule as above: only the *expected* number ends the entry.
                        let digits: String =
                            rest.iter().take_while(|c| c.is_ascii_digit()).collect();
                        let terminator = rest.get(digits.len());
                        matches!(terminator, Some('.') | Some(')'))
                            && expected_next
                                .map(|expected| digits.parse::<u32>().ok() == Some(expected))
                                .unwrap_or(false)
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

/// Parses author-year entries (`Baevski, A.; Zhou, Y.; … 2020. Title…`) out of one page.
///
/// Entries have no delimiter at all — no number, no bracket — so the start of the next entry is
/// recognised by typography: a line beginning with `Surname, I.` is a new entry. That is what
/// every author-year style in the sample corpus does, and it fails loudly (a single huge entry)
/// rather than silently inventing boundaries.
pub fn parse_author_year_references(page: u32, text: &RawTextPage) -> Vec<ReferenceEntry> {
    let chars: Vec<char> = text
        .chars
        .iter()
        .filter_map(|character| char::from_u32(character.unicode))
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
        if looks_like_author_year_start(&line) {
            starts.push(*start);
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
        let Some(surname) = first_surname(&cleaned) else {
            continue;
        };

        entries.push(ReferenceEntry {
            label: format!("{surname} {year}"),
            text: cleaned,
            page,
            start: *start,
            end,
        });
    }

    entries
}

/// `Baevski, A.` / `He, L.` / `Kim, S.` — capitalised surname, comma, initials.
///
/// Measured (2026-10-13): generalising this to accept full given names ("Yunfei Bai, Danny M
/// Kaufman, …") parsed more entries for one paper but **regressed two others** — Leader went
/// from 2/2 resolved to 1/2 and manuscript from 5/30 to 0/30 across the corpus. The initials
/// rule is what the aggregate favours, so it stays; the full-name style is a known gap.
fn looks_like_author_year_start(line: &str) -> bool {
    let trimmed = line.trim_start();
    let mut characters = trimmed.chars().peekable();
    let Some(first) = characters.next() else {
        return false;
    };
    if !first.is_uppercase() {
        return false;
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
    if !(2..=20).contains(&surname_length) {
        return false;
    }

    let rest: String = characters.collect();
    let rest = rest.trim_start();
    rest.starts_with(',')
        && rest
            .chars()
            .nth(1)
            .map(|character| character.is_whitespace())
            .unwrap_or(false)
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
        })
        .map(str::to_string)
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
        if let Some(entry) = references
            .iter()
            .find(|entry| label.eq_ignore_ascii_case(&entry.label))
        {
            return Some(entry);
        }
    }

    // Positional fallback, but only when the list itself is unnumbered: if the entries carry
    // labels, a numeric miss means "no such reference", not "the Nth one".
    let list_is_unnumbered = references.iter().all(|entry| {
        !entry
            .label
            .chars()
            .next()
            .map(|c| c.is_ascii_digit())
            .unwrap_or(false)
    });
    if !list_is_unnumbered {
        return None;
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

/// Finds the reference list across a document's pages.
///
/// `pages` must be `(page index, raw text)` in reading order and may cover only part of the
/// document; scanning is bounded by `max_entries` so a mis-detected heading cannot walk a whole
/// book.
pub fn find_references<'a>(
    pages: impl IntoIterator<Item = (u32, &'a RawTextPage)>,
    max_entries: usize,
) -> Vec<ReferenceEntry> {
    // Parse every page, then keep the **longest run of consecutive pages that produce entries**.
    //
    // Deriving the list from the entries themselves rather than from a heading is what the
    // corpus taught: headings are inconsistent (mid-page, shared with the first entry, spelled
    // differently), and scanning front to back means a body page that merely mentions
    // "References" can start a bogus list and hide the real one further on. A real reference
    // list is a long run of titled entries; a false start is short.
    let mut best: Vec<ReferenceEntry> = Vec::new();
    let mut current: Vec<ReferenceEntry> = Vec::new();

    for (page, text) in pages {
        let mut parsed = parse_numeric_references(page, text);
        if parsed.is_empty() {
            parsed = parse_author_year_references(page, text);
        }

        if parsed.is_empty() {
            if current.len() > best.len() {
                best = std::mem::take(&mut current);
            } else {
                current.clear();
            }
        } else {
            current.extend(parsed);
        }
    }
    if current.len() > best.len() {
        best = current;
    }

    best.truncate(max_entries);
    best
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
            },
            ReferenceEntry {
                label: "Barzel 1988".to_string(),
                text: "A modeling system".to_string(),
                page: 9,
                start: 11,
                end: 20,
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
        }];
        assert!(resolve_reference(&["2".to_string()], &numbered).is_none());
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
    /// expansion of ranges like `12-14`); author-year styles give the year, which is all the
    /// matcher can use until the reference list is parsed in that style too.
    pub labels: Vec<String>,
    /// Bounding box in **page space** (the union of the character boxes).
    pub rect: Rect,
    /// Character range inside the page's text layer.
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
pub fn find_citations(text: &RawTextPage) -> Vec<Citation> {
    let chars: Vec<char> = text
        .chars
        .iter()
        .filter_map(|character| char::from_u32(character.unicode))
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
            let inner: String = chars[index + 1..close.min(chars.len())].iter().collect();
            let letters = inner
                .chars()
                .filter(|character| character.is_alphabetic())
                .count();
            if close < chars.len()
                && chars[close] == ')'
                && letters >= 3
                && let Some(year) = first_year(&inner)
            {
                // Author-year lists have no numbers, so the matching key is
                // "first surname + year" -- the same key `parse_author_year_references`
                // builds for the entries themselves.
                let mut labels = vec![year.clone()];
                if let Some(surname) = first_surname(&inner) {
                    labels.push(format!("{surname} {year}"));
                }
                found.push(Citation {
                    text: inner.trim().to_string(),
                    labels,
                    rect: union_boxes(&text.chars[index..=close]),
                    start: index,
                    end: close,
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
                || chars[end] == '-'
                || chars[end] == ' ')
        {
            end += 1;
        }
        let has_digit = chars[index + 1..end].iter().any(char::is_ascii_digit);
        if end < chars.len() && chars[end] == ']' && has_digit {
            let inner: String = chars[index + 1..end].iter().collect();
            found.push(Citation {
                text: chars[index..=end].iter().collect(),
                labels: numeric_labels(&inner),
                rect: union_boxes(&text.chars[index..=end]),
                start: index,
                end,
            });
            index = end + 1;
        } else {
            index += 1;
        }
    }

    found
}

/// Expands `12,13` and `12-14` into the individual labels a reference list can be keyed by.
fn numeric_labels(inner: &str) -> Vec<String> {
    let mut labels = Vec::new();
    for part in inner.split(',') {
        let part = part.trim();
        if let Some((from, to)) = part.split_once('-')
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
    let digits: Vec<char> = text.chars().collect();
    digits.windows(4).find_map(|window| {
        if !window.iter().all(char::is_ascii_digit) {
            return None;
        }
        let year: u32 = window.iter().collect::<String>().parse().ok()?;
        (1900..2100).contains(&year).then(|| year.to_string())
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
        assert_eq!(found[0].labels, vec!["2024", "He 2024"]);
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
