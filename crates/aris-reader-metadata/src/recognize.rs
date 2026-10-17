//! Offline document metadata recognition.
//!
//! Three sources, in priority order, and every field remembers which one produced it:
//!
//! 1. **XMP** — `dc:title`, `dc:creator`, `prism:doi`, `prism:publicationName`,
//!    `prism:coverDate`. The only source that can state a DOI and a venue outright.
//! 2. **The `/Info` dictionary** — `/Title`, `/Author`, plus `/Subject` and `/Keywords` as a
//!    place a DOI is sometimes parked. Values that are producer placeholders ("Microsoft Word
//!    - paper.doc", "untitled") are not treated as metadata.
//! 3. **The first page's text layer** — a title block (the largest text above the abstract),
//!    the author line below it, and the identifiers/venue/year that the page furniture carries.
//!    These are marked as guesses, because a layout heuristic can be wrong.
//!
//! The rule the sources share: **empty stays empty**. `recognize` has no filename, no creation
//! date fallback and no placeholder list of authors, so a document with nothing to say produces
//! no metadata rather than plausible-looking metadata.

use aris_reader_core::{EmbeddedMetadata, RawTextPage, Rect};
use aris_reader_text::{TextLine, lines_from};

use crate::bibtex::BibEntry;

/// Where one field came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MetadataSource {
    /// XMP metadata stream (`dc:title`, `dc:creator`, `prism:doi`, …).
    Xmp,
    /// The PDF information dictionary (`/Title`, `/Author`, `/Subject`, `/Keywords`).
    Info,
    /// A layout heuristic on page 1 (title block, author block).
    FirstPage,
    /// Page-1 header/footer furniture (venue, copyright year).
    PageFurniture,
    /// An identifier read out of page-1 text (DOI, arXiv id). Found, not guessed.
    Text,
    /// A year derived from the arXiv identifier's YYMM prefix.
    ArxivDerived,
    /// The reader corrected the value in the metadata panel.
    Edited,
}

impl MetadataSource {
    /// Stable machine-readable name, used by the CLI and by the FFI.
    pub fn code(self) -> &'static str {
        match self {
            Self::Xmp => "xmp",
            Self::Info => "info",
            Self::FirstPage => "first-page",
            Self::PageFurniture => "page-furniture",
            Self::Text => "page-text",
            Self::ArxivDerived => "arxiv-id",
            Self::Edited => "edited",
        }
    }

    /// Short human label for the panel and the CLI.
    pub fn label(self) -> &'static str {
        match self {
            Self::Xmp => "XMP",
            Self::Info => "PDF info",
            Self::FirstPage => "page 1 guess",
            Self::PageFurniture => "page 1 furniture guess",
            Self::Text => "found on page 1",
            Self::ArxivDerived => "derived from arXiv id",
            Self::Edited => "edited",
        }
    }

    /// How much trust the source deserves, in one word.
    pub fn trust(self) -> &'static str {
        match self {
            Self::Xmp | Self::Info => "embedded",
            Self::Text => "identified",
            Self::FirstPage | Self::PageFurniture | Self::ArxivDerived => "guessed",
            Self::Edited => "edited",
        }
    }

    /// Whether the panel must mark this value as a guess.
    pub fn is_guessed(self) -> bool {
        matches!(
            self,
            Self::FirstPage | Self::PageFurniture | Self::ArxivDerived
        )
    }

    /// Whether the value came from the document's own description of itself.
    pub fn is_embedded(self) -> bool {
        matches!(self, Self::Xmp | Self::Info)
    }
}

/// One metadata field: zero or more values and the source that produced them.
///
/// The invariant is that an empty field has **no source**: a value that does not exist was not
/// "guessed by the first page", and saying so would be misleading.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct MetadataField {
    pub values: Vec<String>,
    pub source: Option<MetadataSource>,
}

impl MetadataField {
    pub fn none() -> Self {
        Self::default()
    }

    /// One value, trimmed; blank input becomes an empty field.
    pub fn single(value: impl Into<String>, source: MetadataSource) -> Self {
        let value = value.into();
        let value = value.trim();
        if value.is_empty() {
            Self::none()
        } else {
            Self {
                values: vec![value.to_string()],
                source: Some(source),
            }
        }
    }

    /// Several values (authors), each trimmed; empty entries are dropped.
    pub fn list(values: impl IntoIterator<Item = String>, source: MetadataSource) -> Self {
        let mut normalised = Vec::new();
        for value in values {
            let value = value.trim();
            if !value.is_empty() && !normalised.iter().any(|existing: &String| existing == value) {
                normalised.push(value.to_string());
            }
        }
        if normalised.is_empty() {
            Self::none()
        } else {
            Self {
                values: normalised,
                source: Some(source),
            }
        }
    }

    pub fn is_empty(&self) -> bool {
        self.values.is_empty()
    }

    pub fn value(&self) -> Option<&str> {
        self.values.first().map(String::as_str)
    }

    /// All values joined for a single-line editor (`Ada; Alan`).
    pub fn text(&self) -> String {
        self.values.join("; ")
    }

    pub fn is_guessed(&self) -> bool {
        self.source.is_some_and(MetadataSource::is_guessed)
    }

    pub fn source_code(&self) -> &'static str {
        self.source.map(MetadataSource::code).unwrap_or("none")
    }

    pub fn source_label(&self) -> &'static str {
        self.source.map(MetadataSource::label).unwrap_or("none")
    }

    pub fn trust(&self) -> &'static str {
        self.source.map(MetadataSource::trust).unwrap_or("none")
    }
}

/// Every field the reader shows, with its provenance.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RecognizedMetadata {
    pub title: MetadataField,
    pub authors: MetadataField,
    pub venue: MetadataField,
    pub year: MetadataField,
    pub doi: MetadataField,
    pub arxiv_id: MetadataField,
}

impl RecognizedMetadata {
    /// The values the BibTeX generator consumes; provenance stays in the fields.
    pub fn bib_entry(&self) -> BibEntry {
        BibEntry {
            title: self.title.value().unwrap_or_default().to_string(),
            authors: self.authors.values.clone(),
            venue: self.venue.value().unwrap_or_default().to_string(),
            year: self.year.value().unwrap_or_default().to_string(),
            doi: self.doi.value().unwrap_or_default().to_string(),
            arxiv_id: self.arxiv_id.value().unwrap_or_default().to_string(),
        }
    }

    pub fn bibtex(&self) -> String {
        self.bib_entry().to_bibtex()
    }
}

/// Minimum ratio between the title block and body text before a title is claimed.
const TITLE_TO_BODY_RATIO: f64 = 1.15;

/// Recognises metadata for the open document.
///
/// `first_page` is the raw text layer of page 1; `page_height_pt` is the unrotated page height
/// (`crop_box` height in PDF user space, the same space as the character boxes). A page with no
/// characters is treated exactly like a scanned document: sources 1 and 2 still apply, the text
/// layer contributes nothing, and no field is invented to fill the gap.
pub fn recognize(
    embedded: &EmbeddedMetadata,
    first_page: Option<&RawTextPage>,
    page_height_pt: f64,
) -> RecognizedMetadata {
    let lines = first_page
        .filter(|page| !page.chars.is_empty())
        .map(lines_from)
        .unwrap_or_default();
    let page_height = if page_height_pt.is_finite() && page_height_pt > 0.0 {
        page_height_pt
    } else {
        inferred_page_height(&lines)
    };

    let mut result = RecognizedMetadata::default();

    // ── Title ────────────────────────────────────────────────────────────────
    let text_title = first_page_title(&lines, page_height);
    if let Some(title) = embedded
        .xmp
        .title
        .as_deref()
        .and_then(usable_title)
        .map(|value| MetadataField::single(value, MetadataSource::Xmp))
    {
        result.title = title;
    } else if let Some(title) = embedded
        .info
        .title
        .as_deref()
        .and_then(usable_title)
        .map(|value| MetadataField::single(value, MetadataSource::Info))
    {
        result.title = title;
    } else if let Some((title, _)) = &text_title {
        result.title = MetadataField::single(title.clone(), MetadataSource::FirstPage);
    }

    // ── Authors ──────────────────────────────────────────────────────────────
    let text_authors = text_title
        .as_ref()
        .map(|(_, range)| first_page_authors(&lines, range, page_height))
        .unwrap_or_default();
    if let Some(authors) = xmp_authors(&embedded.xmp.authors)
        .map(|values| MetadataField::list(values, MetadataSource::Xmp))
        .filter(|field| !field.is_empty())
    {
        result.authors = authors;
    } else if let Some(authors) = embedded
        .info
        .author
        .as_deref()
        .map(split_embedded_authors)
        .filter(|values| !values.is_empty())
        .map(|values| MetadataField::list(values, MetadataSource::Info))
    {
        result.authors = authors;
    } else if !text_authors.is_empty() {
        result.authors = MetadataField::list(text_authors, MetadataSource::FirstPage);
    }

    // ── DOI ──────────────────────────────────────────────────────────────────
    let info_text = [
        embedded.info.subject.as_deref(),
        embedded.info.keywords.as_deref(),
    ]
    .into_iter()
    .flatten()
    .collect::<Vec<_>>()
    .join("\n");
    let page_text = page_text(&lines);

    if let Some(doi) = embedded.xmp.doi.as_deref().and_then(usable_doi) {
        result.doi = MetadataField::single(doi, MetadataSource::Xmp);
    } else if let Some(doi) = find_doi(&info_text) {
        result.doi = MetadataField::single(doi, MetadataSource::Info);
    } else if let Some(doi) = footer_text(&lines, page_height)
        .and_then(|footer| find_doi(&footer))
        .or_else(|| find_doi(&page_text))
    {
        result.doi = MetadataField::single(doi, MetadataSource::Text);
    }

    // ── arXiv id ─────────────────────────────────────────────────────────────
    // XMP's arXiv DOI (`10.48550/arXiv.…`) is the most reliable statement; the text layer's
    // margin stamp and body references are next. If neither exists, an arXiv DOI found above
    // still determines the id.
    let arxiv = embedded
        .xmp
        .doi
        .as_deref()
        .and_then(arxiv_from_doi)
        .map(|id| (id, MetadataSource::Xmp))
        .or_else(|| arxiv_from_doi(&info_text).map(|id| (id, MetadataSource::Info)))
        .or_else(|| find_arxiv(&page_text).map(|id| (id, MetadataSource::Text)))
        .or_else(|| {
            result
                .doi
                .value()
                .and_then(|value| arxiv_from_doi(value).zip(result.doi.source))
        });
    if let Some((id, source)) = arxiv {
        result.arxiv_id = MetadataField::single(id, source);
    }

    // ── Venue and year ───────────────────────────────────────────────────────
    //
    // The line-based footer scan can read a printed venue out of the page's geometry, but the
    // text layer's line boxes are sometimes fragmented in a running footer. The page's own text
    // string has clean words but no coordinates, so it is used only for the venue: a line that
    // states "Proceedings of …" on page one is a venue wherever it sits. It cannot place a
    // title or an author.
    let (mut footer_venue, footer_year, venue_source) = page_venue_and_year(&lines, page_height);
    let mut venue_year = None;
    if let Some(raw_venue) = first_page.and_then(|page| venue_from_raw_text(&page.text)) {
        venue_year = four_digit_year(&raw_venue);
        footer_venue = Some(raw_venue);
    } else if let Some(venue) = footer_venue.as_deref() {
        venue_year = four_digit_year(venue);
    }
    // A copyright line or a printed publication date is evidence of the year even when the
    // venue line itself carries no four-digit year.
    let raw_year = first_page.and_then(|page| year_from_raw_text(&page.text));

    if let Some(venue) = embedded
        .xmp
        .venue
        .as_deref()
        .and_then(usable_venue)
        .map(|value| MetadataField::single(value, MetadataSource::Xmp))
    {
        result.venue = venue;
    } else if let Some(venue) = footer_venue {
        result.venue =
            MetadataField::single(venue, venue_source.unwrap_or(MetadataSource::PageFurniture));
    }

    if let Some(year) = embedded
        .xmp
        .year
        .as_deref()
        .and_then(four_digit_year)
        .map(|value| MetadataField::single(value, MetadataSource::Xmp))
    {
        result.year = year;
    } else if let Some(year) = venue_year.or(raw_year).or(footer_year) {
        result.year = MetadataField::single(year, MetadataSource::PageFurniture);
    } else if let Some(id) = result.arxiv_id.value()
        && let Some(year) = arxiv_year(id)
    {
        result.year = MetadataField::single(year, MetadataSource::ArxivDerived);
    }

    result
}

fn inferred_page_height(lines: &[TextLine]) -> f64 {
    lines
        .iter()
        .map(|line| line.rect.origin.y + line.rect.size.height)
        .fold(0.0, f64::max)
}

fn page_text(lines: &[TextLine]) -> String {
    lines
        .iter()
        .map(|line| line.text.trim())
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

fn footer_text(lines: &[TextLine], page_height: f64) -> Option<String> {
    let footer = lines
        .iter()
        .filter(|line| line.rect.origin.y + line.rect.size.height < page_height * 0.20)
        .map(|line| line.text.trim())
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>()
        .join("\n");
    if footer.is_empty() {
        None
    } else {
        Some(footer)
    }
}

// ── Title and author block ───────────────────────────────────────────────────

/// The title block and its line range, when the page has one.
fn first_page_title(
    lines: &[TextLine],
    page_height: f64,
) -> Option<(String, std::ops::Range<usize>)> {
    let abstract_index = abstract_line(lines);
    let body_size = body_line_height(lines, page_height);
    if body_size <= 0.0 {
        return None;
    }

    let candidates: Vec<usize> = (0..lines.len())
        .filter(|index| abstract_index.is_none_or(|abstract_index| *index < abstract_index))
        .filter(|index| {
            let line = &lines[*index];
            if page_height > 0.0
                && abstract_index.is_none()
                && line.rect.origin.y < page_height * 0.40
            {
                return false;
            }
            is_title_candidate(line)
        })
        .collect();
    if candidates.is_empty() {
        return None;
    }

    let largest = candidates.iter().copied().max_by(|left, right| {
        lines[*left]
            .rect
            .size
            .height
            .total_cmp(&lines[*right].rect.size.height)
            .then(
                lines[*right]
                    .rect
                    .origin
                    .y
                    .total_cmp(&lines[*left].rect.origin.y),
            )
    })?;
    let title_height = lines[largest].rect.size.height;
    // A body page's title stands out from the running text. A title page (a thesis cover, a
    // report title page) has no running text at all: almost every line is display-sized, and
    // comparing the title with that "body" size would reject the one line the page is about.
    let has_body_text = lines
        .iter()
        .filter(|line| line.text.chars().count() >= 60)
        .count()
        >= 2;
    // A title page has no running text to compare with, but its title is still larger than the
    // page's other display lines; a page of uniform body text has no title block at all.
    let minimum_ratio = if has_body_text {
        TITLE_TO_BODY_RATIO
    } else {
        1.05
    };
    if title_height < body_size * minimum_ratio {
        return None;
    }

    // Expand to the wrapped lines of the same title. The gap is what separates a wrapped title
    // (roughly one line spacing, i.e. a few points) from the author block below it; the height
    // ratio alone is not enough because an all-caps line and a mixed-case one report ink boxes
    // of different heights at the same point size.
    //
    // The expansion skips page furniture that is interleaved with the title in `lines`: line
    // numbers, superscript affiliation markers and the arXiv margin stamp all sit on other
    // baselines between a title's two printed lines, and stopping at the first one would make
    // the recogniser claim only the first half of a wrapped title.
    let mut accepted = vec![largest];

    let mut cursor = largest;
    while cursor > 0 {
        cursor -= 1;
        if Some(cursor) == abstract_index {
            break;
        }
        let line = &lines[cursor];
        if is_margin_noise(line, body_size)
            || is_furniture(&line.text)
            || looks_like_venue(&line.text)
        {
            continue;
        }
        if !is_title_candidate(line) {
            break;
        }
        let below = *accepted.first().unwrap_or(&largest);
        if !continues_block(&lines[below], line, title_height) {
            break;
        }
        accepted.insert(0, cursor);
    }

    let mut cursor = *accepted.last().unwrap_or(&largest);
    while cursor + 1 < lines.len() {
        cursor += 1;
        if Some(cursor) == abstract_index {
            break;
        }
        let line = &lines[cursor];
        if is_margin_noise(line, body_size)
            || is_furniture(&line.text)
            || looks_like_venue(&line.text)
        {
            continue;
        }
        if !is_title_candidate(line) {
            break;
        }
        let above = *accepted.last().unwrap_or(&largest);
        if !continues_block(line, &lines[above], title_height) {
            break;
        }
        accepted.push(cursor);
    }

    let parts = accepted
        .iter()
        .map(|index| lines[*index].text.trim().to_string())
        .filter(|part| !part.is_empty() && part.chars().any(char::is_alphabetic))
        .collect::<Vec<_>>();
    let title = join_wrapped(&parts);
    if !looks_like_title(&title) {
        return None;
    }
    let first = *accepted.first().unwrap_or(&largest);
    let last = *accepted.last().unwrap_or(&largest);
    Some((title, first..last + 1))
}

/// Lines that sit between a title's printed lines but are not part of it.
///
/// Review PDFs put line numbers in the margin of every line, superscript affiliation markers
/// sit above the author line, and an arXiv stamp sits in the margin of page one. None of them
/// may end a title block.
fn is_margin_noise(line: &TextLine, body_size: f64) -> bool {
    let text = line.text.trim();
    if text.is_empty() {
        return true;
    }
    if text.chars().all(|character| {
        character.is_ascii_digit()
            || character.is_whitespace()
            || matches!(
                character,
                ',' | '.' | '*' | '∗' | '†' | '‡' | '§' | '¶' | '#'
            )
    }) {
        return true;
    }
    if text.starts_with("arXiv:") || text.starts_with("doi:") {
        return true;
    }
    // A short mark in the margin: no word, and smaller than the body.
    text.chars().count() <= 3 && line.rect.size.height < body_size * 0.9
}

fn abstract_line(lines: &[TextLine]) -> Option<usize> {
    lines
        .iter()
        .position(|line| is_abstract_heading(&line.text))
}

fn is_abstract_heading(text: &str) -> bool {
    let lower = text.trim().to_lowercase();
    if lower.starts_with("abstract") {
        return true;
    }
    // Small-caps or letter-spaced headings.
    let squeezed = lower.split_whitespace().collect::<String>();
    squeezed.starts_with("abstract")
}

fn is_title_candidate(line: &TextLine) -> bool {
    let text = line.text.trim();
    if text.chars().count() < 2 || !text.chars().any(char::is_alphabetic) {
        return false;
    }
    if is_furniture(text) || is_abstract_heading(text) {
        return false;
    }
    if looks_like_affiliation(text) {
        return false;
    }
    // A full sentence ending in a period is body text, not a title line; a dotted abbreviation
    // in the middle is fine, so only the end is inspected.
    !(text.ends_with('.') && text.split_whitespace().count() > 16)
}

fn continues_block(next: &TextLine, current: &TextLine, title_height: f64) -> bool {
    let next_height = next.rect.size.height;
    // Ink-box heights differ by a few points between an all-caps line and one with a
    // descender even when both are set in the same size; 0.70 keeps a wrapped title together
    // while still excluding the smaller author line (typically 0.5–0.65 of the title).
    if next_height < title_height * 0.70 || next_height > title_height * 1.25 {
        return false;
    }
    if !is_title_candidate(next) {
        return false;
    }
    let gap = current.rect.origin.y - (next.rect.origin.y + next.rect.size.height);
    if gap < -title_height * 0.5 || gap > title_height * 1.4 {
        return false;
    }
    horizontal_overlap(next.rect, current.rect)
}

fn horizontal_overlap(left: Rect, right: Rect) -> bool {
    let left_start = left.origin.x;
    let left_end = left.origin.x + left.size.width;
    let right_start = right.origin.x;
    let right_end = right.origin.x + right.size.width;
    left_end.min(right_end) > left_start.max(right_start)
}

fn join_wrapped(parts: &[String]) -> String {
    let mut output = String::new();
    for part in parts {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        if output.is_empty() {
            output.push_str(part);
            continue;
        }
        let previous = output.chars().last();
        let next = part.chars().next();
        if previous == Some('-') {
            // A line break after a hyphen. Join the halves while the continuation starts in
            // lowercase; `Self-{Supervised}` should keep the hyphen.
            if next.is_some_and(char::is_lowercase) {
                output.pop();
                output.push_str(part);
                continue;
            }
        }
        output.push(' ');
        output.push_str(part);
    }
    output.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn looks_like_title(title: &str) -> bool {
    let title = title.trim();
    let words = title.split_whitespace().count();
    if title.chars().count() < 3 || words == 0 || !title.chars().any(char::is_alphabetic) {
        return false;
    }
    if is_furniture(title) || looks_like_affiliation(title) {
        return false;
    }
    let lower = title.to_lowercase();
    let single_word = words == 1;
    if single_word
        && matches!(
            lower.as_str(),
            "ieee" | "acm" | "springer" | "elsevier" | "arxiv" | "preprint" | "abstract"
        )
    {
        return false;
    }
    title.chars().count() <= 400
}

/// Median height of the lines that read as body text.
///
/// Lines in the top quarter of the page are display text (the title, a journal banner, a thesis
/// page's institution line), not the running body. Including them made the title equal to the
/// "body" on a page whose only long lines are the title and one sentence, and the title was then
/// rejected as "body-sized".
fn body_line_height(lines: &[TextLine], page_height: f64) -> f64 {
    let below_top_band = |line: &&TextLine| {
        page_height <= 0.0 || line.rect.origin.y + line.rect.size.height < page_height * 0.72
    };
    let mut heights: Vec<f64> = lines
        .iter()
        .filter(below_top_band)
        .filter(|line| line.text.chars().count() >= 40)
        .map(|line| line.rect.size.height)
        .filter(|height| *height > 0.0)
        .collect();
    if heights.len() < 2 {
        heights = lines
            .iter()
            .filter(below_top_band)
            .map(|line| line.rect.size.height)
            .filter(|height| *height > 0.0)
            .collect();
    }
    if heights.is_empty() {
        heights = lines
            .iter()
            .map(|line| line.rect.size.height)
            .filter(|height| *height > 0.0)
            .collect();
    }
    if heights.is_empty() {
        return 0.0;
    }
    heights.sort_by(f64::total_cmp);
    heights[heights.len() / 2]
}

/// The author block below the title, split into names.
fn first_page_authors(
    lines: &[TextLine],
    title_range: &std::ops::Range<usize>,
    page_height: f64,
) -> Vec<String> {
    let Some(title_block) = title_range
        .clone()
        .next_back()
        .and_then(|index| lines.get(index))
    else {
        return Vec::new();
    };
    let title_bottom = title_block.rect.origin.y;
    let title_height = title_block.rect.size.height.max(1.0);
    let body_size = body_line_height(lines, page_height).max(1.0);
    let abstract_index = abstract_line(lines).unwrap_or(lines.len());
    let last_gap = title_height.max(body_size) * 4.0;

    let mut collected = Vec::new();
    let mut previous_bottom = title_bottom;
    for line in &lines[title_range.end..abstract_index] {
        let top = line.rect.origin.y + line.rect.size.height;
        if top > title_bottom + last_gap {
            break;
        }
        if line.rect.origin.y < page_height * 0.05 {
            break;
        }
        let gap = previous_bottom - top;
        if gap > title_height.max(body_size) * 5.0 {
            break;
        }
        // Superscript affiliation markers, line numbers and the arXiv stamp can sit between the
        // title and the author line; they are not a reason to give up on the authors.
        if is_margin_noise(line, body_size) {
            continue;
        }
        let height = line.rect.size.height;
        if height < body_size * 0.80 {
            break;
        }
        let text = line.text.trim();
        if text.is_empty() {
            continue;
        }
        if is_abstract_heading(text) {
            break;
        }
        if is_furniture(text) || looks_like_venue(text) {
            continue;
        }
        // "by" on its own line introduces the authors; it is punctuation, not a name.
        if text.eq_ignore_ascii_case("by") {
            previous_bottom = line.rect.origin.y;
            continue;
        }
        if looks_like_affiliation(text) {
            // ACM's landing pages print "RUNQI WANG, Wuhan University, Wuhan, China": the
            // name is before the first comma and the affiliation after it. Extract the name
            // and keep scanning, because the next author line looks the same. A line like
            // "B.Eng., Concordia University, 2024" has no name before the comma and ends the
            // author block.
            let prefix = text.split(',').next().unwrap_or_default().trim();
            if prefix.split_whitespace().count() >= 2 && looks_like_person_name(prefix) {
                collected.push(prefix.to_string());
                previous_bottom = line.rect.origin.y;
                if collected.len() == 12 {
                    break;
                }
                continue;
            }
            break;
        }
        if !looks_like_author_line(text) {
            break;
        }
        collected.push(text.to_string());
        previous_bottom = line.rect.origin.y;
        if collected.len() == 12 {
            break;
        }
    }

    split_authors(&collected.join(" "))
}

fn looks_like_author_line(text: &str) -> bool {
    if text.chars().count() < 2 || !text.chars().any(char::is_alphabetic) {
        return false;
    }
    if text.contains('@') || text.contains("http") || is_under_review(text) {
        return false;
    }
    let lower = text.to_lowercase();
    const NOT_AUTHORS: &[&str] = &[
        "abstract",
        "introduction",
        "keywords",
        "accepted",
        "published",
        "preprint",
        "under review",
        "equal contribution",
        "corresponding author",
        "view all",
        "open access",
        "research-article",
        "latest updates",
        "download",
        "support provided by",
    ];
    !NOT_AUTHORS.iter().any(|word| lower.contains(word))
}

fn split_authors(text: &str) -> Vec<String> {
    let text = text.trim().trim_start_matches("by ").trim();
    let mut names = Vec::new();
    for group in split_on_any(text, &[";", "·", "•"]) {
        let lower = group.to_lowercase();
        let groups = if lower.contains(" and ") {
            split_case_insensitive(&group, " and ")
        } else {
            vec![group.clone()]
        };
        for group in groups {
            let comma_parts = split_on_any(&group, &[","]);
            let use_commas = comma_parts.len() >= 2
                && comma_parts
                    .iter()
                    .all(|part| part.split_whitespace().count() >= 2);
            if use_commas {
                names.extend(comma_parts);
            } else {
                names.push(group);
            }
        }
    }

    let mut result = Vec::new();
    for name in names {
        let name = clean_person_name(&name);
        if name.is_empty() || !looks_like_person_name(&name) {
            continue;
        }
        if !result.iter().any(|existing: &String| existing == &name) {
            result.push(name);
        }
    }
    result.truncate(30);
    result
}

fn clean_person_name(name: &str) -> String {
    let mut name = name.trim();
    name = name.trim_matches(|character: char| {
        character.is_whitespace()
            || matches!(
                character,
                '*' | '†' | '‡' | '§' | '¶' | '#' | '&' | ',' | ';' | '·' | '•' | '(' | ')'
            )
    });
    name = name.trim_end_matches(|character: char| character.is_ascii_digit());
    name = name.trim_end_matches(['*', '†', '‡', '§', '¶', '#']);
    name = name.trim();
    name.trim_start_matches("and ").trim().to_string()
}

fn looks_like_person_name(name: &str) -> bool {
    let words = name.split_whitespace().count();
    if name.chars().count() < 2
        || name.chars().count() > 90
        || words == 0
        || words > 8
        || name
            .chars()
            .next()
            .is_some_and(|character| character.is_ascii_digit())
        || !name.chars().any(char::is_alphabetic)
    {
        return false;
    }
    let lower = name.to_lowercase();
    const NOT_PEOPLE: &[&str] = &[
        "university",
        "université",
        "institute",
        "institut",
        "department",
        "dept.",
        "school of",
        "faculty",
        "laboratory",
        "laboratories",
        "college",
        "academy",
        "research center",
        "research centre",
        "google brain",
        "google research",
        " lab",
        " labs",
        " group",
        " center",
        " centre",
        " research",
        " inc.",
        " ltd.",
        " corporation",
        "http",
        "www.",
        "doi",
        "arxiv",
        "email",
        "@",
    ];
    if NOT_PEOPLE.iter().any(|word| lower.contains(word)) {
        return false;
    }
    // A footnote marker with no name after it.
    if name
        .chars()
        .all(|character| character.is_ascii_digit() || character.is_whitespace())
    {
        return false;
    }
    true
}

fn split_on_any(text: &str, separators: &[&str]) -> Vec<String> {
    let mut parts = vec![text.to_string()];
    for separator in separators {
        let mut next = Vec::new();
        for part in parts {
            next.extend(part.split(separator).map(str::to_string));
        }
        parts = next;
    }
    parts
        .into_iter()
        .map(|part| part.trim().to_string())
        .filter(|part| !part.is_empty())
        .collect()
}

fn split_case_insensitive(text: &str, separator: &str) -> Vec<String> {
    let lower = text.to_ascii_lowercase();
    let mut parts = Vec::new();
    let mut cursor = 0usize;
    while let Some(found) = lower[cursor..].find(separator) {
        let start = cursor + found;
        parts.push(text[cursor..start].to_string());
        cursor = start + separator.len();
    }
    parts.push(text[cursor..].to_string());
    parts
        .into_iter()
        .map(|part| part.trim().to_string())
        .filter(|part| !part.is_empty())
        .collect()
}

/// `/Author` strings are one field, not one name; split on the conventional separators.
fn split_embedded_authors(value: &str) -> Vec<String> {
    split_authors(value)
        .into_iter()
        .filter(|name| !is_placeholder_person(name))
        .collect()
}

fn is_placeholder_person(value: &str) -> bool {
    let lower = value.trim().to_lowercase();
    if lower.is_empty() {
        return true;
    }
    const PLACEHOLDERS: &[&str] = &[
        "administrator",
        "user",
        "owner",
        "unknown",
        "anonymous",
        "author",
        "authors",
        "windows user",
        "python",
        "latex",
        "microsoft",
        "adobe",
    ];
    PLACEHOLDERS.iter().any(|placeholder| lower == *placeholder)
        || lower.starts_with("microsoft word")
        || lower.ends_with(".pdf")
        || lower.ends_with(".doc")
        || lower.ends_with(".docx")
}

fn xmp_authors(authors: &[String]) -> Option<Vec<String>> {
    let authors = authors
        .iter()
        .flat_map(|author| split_authors(author))
        .filter(|author| !is_placeholder_person(author))
        .collect::<Vec<_>>();
    if authors.is_empty() {
        None
    } else {
        Some(authors)
    }
}

// ── Embedded values ──────────────────────────────────────────────────────────

fn usable_title(value: &str) -> Option<String> {
    let title = value.trim();
    if title.chars().count() < 3 || !title.chars().any(char::is_alphabetic) {
        return None;
    }
    if is_furniture(title) || looks_like_affiliation(title) {
        return None;
    }
    let lower = title.to_lowercase();
    const PLACEHOLDERS: &[&str] = &[
        "untitled",
        "no title",
        "title",
        "document",
        "unknown",
        "pdf file",
        "microsoft word",
        "microsoft powerpoint",
        "powerpoint presentation",
        "main.pdf",
        "paper.pdf",
    ];
    if PLACEHOLDERS.iter().any(|placeholder| lower == *placeholder)
        || lower.contains("untitled")
        || lower.starts_with("microsoft word -")
        || lower.starts_with("microsoft powerpoint -")
        || lower.starts_with("microsoft publisher -")
        || lower.ends_with(".pdf")
        || lower.ends_with(".doc")
        || lower.ends_with(".docx")
        || lower.ends_with(".tex")
        || lower.ends_with(".dvi")
    {
        return None;
    }
    // "arXiv:2303.08774v2 [cs.CL]" is page furniture some producers put in /Title.
    if lower.starts_with("arxiv:") || lower.starts_with("doi:") {
        return None;
    }
    Some(title.to_string())
}

fn usable_venue(value: &str) -> Option<String> {
    let venue = value.trim();
    if venue.chars().count() < 3 || !venue.chars().any(char::is_alphabetic) {
        return None;
    }
    let lower = venue.to_lowercase();
    if lower.starts_with("arxiv") || lower.contains("preprint") {
        // An arXiv identifier is not a venue; the entry type is `misc` instead.
        return None;
    }
    if lower.starts_with("doi:") || lower.starts_with("http") || lower.contains('@') {
        return None;
    }
    Some(venue.chars().take(180).collect())
}

fn usable_doi(value: &str) -> Option<String> {
    normalise_doi(value)
}

fn normalise_doi(value: &str) -> Option<String> {
    let mut doi = value.trim().trim_matches(|character: char| {
        character.is_whitespace()
            || matches!(character, '<' | '>' | '"' | '\'' | '(' | ')' | '[' | ']')
    });
    for prefix in [
        "https://doi.org/",
        "http://doi.org/",
        "https://dx.doi.org/",
        "http://dx.doi.org/",
        "doi:",
        "DOI:",
    ] {
        if let Some(rest) = doi.strip_prefix(prefix) {
            doi = rest.trim();
            break;
        }
    }
    // Trim sentence punctuation that the scanner may have swallowed; balanced parentheses at
    // the end are part of some DOIs and are kept.
    loop {
        let trimmed = doi.trim_end_matches(['.', ',', ';', ':', '!', '?']);
        if trimmed.len() == doi.len() {
            break;
        }
        doi = trimmed;
    }
    while doi.ends_with(')') && doi.matches(')').count() > doi.matches('(').count() {
        doi = doi[..doi.len() - 1].trim_end();
    }
    while doi.ends_with(']') && doi.matches(']').count() > doi.matches('[').count() {
        doi = doi[..doi.len() - 1].trim_end();
    }
    let bytes = doi.as_bytes();
    if bytes.len() < 8 || !doi.starts_with("10.") {
        return None;
    }
    let digits = bytes[3..]
        .iter()
        .take_while(|byte| byte.is_ascii_digit())
        .count();
    if !(4..=9).contains(&digits) {
        return None;
    }
    if bytes.get(3 + digits) != Some(&b'/') {
        return None;
    }
    let suffix = &doi[4 + digits..];
    if suffix.chars().count() < 2 || !suffix.chars().any(char::is_alphanumeric) {
        return None;
    }
    Some(doi.to_string())
}

/// A DOI anywhere in `text`, with `10.\d{4,9}/…` as the shape.
fn find_doi(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut cursor = 0usize;
    while cursor + 3 < bytes.len() {
        let offset = text[cursor..].find("10.")?;
        let start = cursor + offset;
        if start > 0 && bytes[start - 1].is_ascii_alphanumeric() {
            cursor = start + 3;
            continue;
        }
        let digits = bytes[start + 3..]
            .iter()
            .take_while(|byte| byte.is_ascii_digit())
            .count();
        if (4..=9).contains(&digits) && bytes.get(start + 3 + digits) == Some(&b'/') {
            let suffix_start = start + 4 + digits;
            let mut end = suffix_start;
            while end < bytes.len() && is_doi_character(bytes[end]) {
                end += 1;
            }
            let candidate = &text[start..end];
            if let Some(doi) = normalise_doi(candidate) {
                return Some(doi);
            }
        }
        cursor = start + 3;
    }
    None
}

fn is_doi_character(byte: u8) -> bool {
    byte.is_ascii_alphanumeric()
        || matches!(
            byte,
            b'.' | b'-' | b'_' | b'/' | b':' | b';' | b'(' | b')' | b'[' | b']' | b'<' | b'>'
        )
}

fn four_digit_year(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    for window in bytes.windows(4) {
        if window.iter().all(u8::is_ascii_digit) {
            let text = std::str::from_utf8(window).ok()?;
            let year = text.parse::<u32>().ok()?;
            if (1900..=2099).contains(&year) {
                return Some(text.to_string());
            }
        }
    }
    None
}

// ── arXiv ────────────────────────────────────────────────────────────────────

fn find_arxiv(text: &str) -> Option<String> {
    // The identifier is only an identifier when the text says it is arXiv: a bare
    // `2303.08774` in body prose is a number, not an arXiv id. ASCII lowercasing keeps the
    // match offset aligned with `text` for the slice below.
    let lower = text.to_ascii_lowercase();
    let mut cursor = 0usize;
    while let Some(offset) = lower[cursor..].find("arxiv") {
        let start = cursor + offset + "arxiv".len();
        let tail = &text[start..];
        let tail = tail.trim_start();
        let tail = tail.strip_prefix(':').unwrap_or(tail).trim_start();
        if let Some(id) = parse_arxiv_at(tail) {
            return Some(id);
        }
        cursor = start;
        if cursor >= lower.len() {
            break;
        }
    }
    arxiv_from_doi(text)
}

fn parse_arxiv_at(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    if bytes.len() < 10 {
        return None;
    }
    let digits = bytes
        .iter()
        .take_while(|byte| byte.is_ascii_digit())
        .count();
    if !(4..=5).contains(&digits) || bytes.get(digits) != Some(&b'.') {
        return None;
    }
    let suffix = bytes[digits + 1..]
        .iter()
        .take_while(|byte| byte.is_ascii_digit())
        .count();
    if !(4..=5).contains(&suffix) {
        return None;
    }
    let end = digits + 1 + suffix;
    let mut length = end;
    if bytes.get(end) == Some(&b'v') {
        let version = bytes[end + 1..]
            .iter()
            .take_while(|byte| byte.is_ascii_digit())
            .count();
        if version > 0 {
            length = end + 1 + version;
        }
    }
    let id = &text[..length];
    let (year, month) = arxiv_year_month(id)?;
    if !(1991..=2099).contains(&year) || !(1..=12).contains(&month) {
        return None;
    }
    Some(id.to_string())
}

fn arxiv_from_doi(value: &str) -> Option<String> {
    let lower = value.to_lowercase();
    let marker = "10.48550/arxiv.";
    let position = lower.find(marker)?;
    let tail = &value[position + marker.len()..];
    parse_arxiv_at(tail)
}

fn arxiv_year_month(id: &str) -> Option<(u32, u32)> {
    if let Some((prefix, number)) = id.split_once('/') {
        // Old identifier: `hep-th/9901001`.
        if prefix.is_empty() || number.len() < 7 {
            return None;
        }
        let year = number.get(0..2)?.parse::<u32>().ok()?;
        let year = if year >= 91 { 1900 + year } else { 2000 + year };
        let month = number.get(2..4)?.parse::<u32>().ok()?;
        return Some((year, month));
    }
    let body = id.split('v').next().unwrap_or(id);
    let (yy, mm) = body.split_once('.')?;
    if yy.len() != 4 || mm.len() < 4 {
        return None;
    }
    let year = yy[0..2].parse::<u32>().ok()?;
    let year = if year >= 91 { 1900 + year } else { 2000 + year };
    let month = yy[2..4].parse::<u32>().ok()?;
    Some((year, month))
}

fn arxiv_year(id: &str) -> Option<String> {
    arxiv_year_month(id).map(|(year, _)| year.to_string())
}

// ── Page furniture: venue and year ──────────────────────────────────────────

fn page_venue_and_year(
    lines: &[TextLine],
    page_height: f64,
) -> (Option<String>, Option<String>, Option<MetadataSource>) {
    let furniture = lines.iter().filter(|line| {
        let top = line.rect.origin.y + line.rect.size.height;
        top < page_height * 0.20 || line.rect.origin.y > page_height * 0.90
    });

    let mut venue = None;
    let mut venue_year = None;
    let mut years = Vec::new();
    let mut copyright_year = None;
    for line in furniture {
        let text = line.text.trim();
        if is_under_review(text) {
            // "Under review as a conference paper at ICLR 2027" names a submission venue and a
            // review-cycle year, not a publication. Reporting it as this paper's venue would
            // be a plausible-looking guess, which is exactly what this feature refuses to do.
            continue;
        }
        if text.is_empty() || is_furniture_without_venue(text) {
            if let Some(year) = four_digit_year(text)
                && (is_copyright_line(text) || has_month_name(text))
            {
                years.push(year);
            }
            continue;
        }
        if let Some(year) = four_digit_year(text)
            && (is_copyright_line(text) || has_month_name(text) || is_bare_year(text))
        {
            years.push(year.clone());
            if venue.is_none() && copyright_year.is_none() && is_copyright_line(text) {
                copyright_year = Some(year);
            }
        }
        if venue.is_none()
            && let Some(found) = venue_from_line(text)
        {
            venue_year = four_digit_year(&found);
            venue = Some(found);
        }
    }

    let venue_year = match venue.as_ref() {
        Some(found) => venue_year.or_else(|| four_digit_year(found)),
        None => None,
    };
    let year = venue_year
        .or(copyright_year)
        .or_else(|| most_common_year(&years));
    let source = venue.as_ref().map(|_| MetadataSource::PageFurniture);
    (venue, year, source)
}

/// The strongest venue statement in the page's own text string.
///
/// Used only when the line-based footer scan found nothing (or found a fragmented one). The
/// raw string has no positions, so this is deliberately venue-only.
fn venue_from_raw_text(text: &str) -> Option<String> {
    let mut best: Option<(u32, String)> = None;
    for line in text.split(['\n', '\r']) {
        let line = line.trim();
        if line.is_empty() || line.chars().count() > 300 || is_under_review(line) {
            continue;
        }
        let Some(venue) = venue_from_line(line) else {
            continue;
        };
        if venue.chars().next().is_some_and(char::is_lowercase)
            || venue.split_whitespace().count() > 30
        {
            continue;
        }
        let score = venue_score(&venue);
        if best
            .as_ref()
            .is_none_or(|(best_score, _)| score > *best_score)
        {
            best = Some((score, venue));
        }
    }
    best.map(|(_, venue)| venue)
}

fn venue_score(venue: &str) -> u32 {
    let lower = venue.to_lowercase();
    let mut score = 0u32;
    for (needle, weight) in [
        ("proceedings of", 6),
        ("conference", 4),
        ("workshop", 3),
        ("symposium", 3),
        ("journal", 4),
        ("transactions", 4),
        ("published as", 3),
        ("accepted at", 2),
        ("accepted to", 2),
        ("to appear in", 2),
    ] {
        if lower.contains(needle) {
            score += weight;
        }
    }
    if four_digit_year(venue).is_some() {
        score += 1;
    }
    if lower.len() > 180 {
        score = score.saturating_sub(2);
    }
    score
}

/// Lines that can carry a venue: proceedings/journal lines, known venue names, and the common
/// "Published as a conference paper at X" header.
fn venue_from_line(text: &str) -> Option<String> {
    let lower = text.to_lowercase();
    if is_under_review(text)
        || lower.contains("arxiv:")
        || lower.contains("doi:")
        || lower.contains('@')
    {
        return None;
    }
    if lower.contains("abstract") || lower.contains("introduction") {
        return None;
    }
    let venue_prefixes = [
        "proceedings of",
        "proc.",
        "conference on",
        "workshop on",
        "symposium on",
        "journal of",
        "transactions on",
        "published as",
        "to appear in",
        "accepted at",
        "accepted to",
        "findings of",
        "advances in neural",
        "ieee transactions",
        "acm transactions",
        "international conference",
    ];
    if venue_prefixes.iter().any(|prefix| lower.contains(prefix)) {
        return Some(normalise_venue(text));
    }
    if looks_like_venue(text) {
        return Some(normalise_venue(text));
    }
    None
}

fn looks_like_venue(text: &str) -> bool {
    let lower = text.to_lowercase();
    const ACRONYMS: &[&str] = &[
        "cvpr",
        "iccv",
        "eccv",
        "wacv",
        "bmvc",
        "accv",
        "neurips",
        "nips",
        "icml",
        "iclr",
        "aaai",
        "ijcai",
        "acl",
        "emnlp",
        "naacl",
        "coling",
        "siggraph",
        "chi",
        "uist",
        "kdd",
        "icra",
        "iros",
        "miccai",
        "interspeech",
        "corl",
        "usenix",
    ];
    let words = lower
        .split(|character: char| !character.is_alphanumeric())
        .filter(|word| !word.is_empty());
    let has_acronym = words.clone().any(|word| ACRONYMS.contains(&word));
    if has_acronym {
        return four_digit_year(text).is_some() || text.split_whitespace().count() <= 12;
    }
    lower.ends_with("conference")
        || lower.ends_with("workshop")
        || lower.ends_with("symposium")
        || lower.ends_with("journal")
}

/// Cuts a page line down to the venue phrase itself.
///
/// The line a venue appears on is not the venue: an ACM reference-format paragraph reads
/// "Title. In Proceedings of the …, October 29-November 3, 2023, Ottawa, ON, Canada. ACM, …",
/// and a journal header continues ", Vol. 36, No. 4, Article 127". Claiming the whole line as a
/// `booktitle` would be a plausible-looking but wrong value.
fn normalise_venue(text: &str) -> String {
    let mut venue = text.trim();
    venue = venue.trim_matches(['.', ',', ';', ':', '-']).trim();

    // Start at the first phrase that can begin a venue name. ASCII lowercasing keeps every
    // byte offset aligned with `venue`, which matters because the match positions slice it.
    let lower = venue.to_ascii_lowercase();
    let mut start = None;
    for marker in [
        "in proceedings of",
        "proceedings of",
        "published as a conference paper at",
        "journal of",
        "acm transactions",
        "ieee transactions",
        "transactions on",
        "findings of",
        "advances in neural",
        "accepted at",
        "accepted to",
        "to appear in",
    ] {
        if let Some(position) = lower.find(marker) {
            let position = if marker == "in proceedings of" {
                position + "in ".len()
            } else {
                position
            };
            start = Some(start.map_or(position, |current: usize| current.min(position)));
        }
    }
    // "The Thirty-Ninth AAAI Conference on Artificial Intelligence" has no phrase above.
    if let Some(position) = lower.find("the ") {
        let tail = &lower[position..];
        let tail = &tail[..tail.len().min(120)];
        if tail.contains("conference") || tail.contains("workshop") || tail.contains("symposium") {
            start = Some(start.map_or(position, |current: usize| current.min(position)));
        }
    }
    if let Some(position) = start {
        venue = venue[position..].trim();
    }
    if let Some(rest) = venue.strip_prefix("In ") {
        venue = rest.trim();
    } else if let Some(rest) = venue.strip_prefix("in ") {
        venue = rest.trim();
    }
    // Edited volumes are printed as "A. Leonardis et al. (Eds.): ECCV 2024, LNCS 15059";
    // what the reader needs is the conference after the editor list.
    let lower = venue.to_ascii_lowercase();
    for marker in ["(eds.):", "(eds):", "eds.:", "eds:"] {
        if let Some(position) = lower.find(marker) {
            venue = venue[position + marker.len()..].trim();
            break;
        }
    }

    // End at the first piece of publication apparatus after the name.
    let lower = venue.to_ascii_lowercase();
    let mut end = venue.len();
    for marker in [
        ", vol.",
        ", vol",
        ", no.",
        ", article",
        ", publication date",
        ", lncs",
        ", lecture notes",
        ", pp.",
        ", pages",
        ", october",
        ", november",
        ", december",
        ", january",
        ", february",
        ", march",
        ", april",
        ", may",
        ", june",
        ", july",
        ", august",
        ", september",
        ". acm",
        ". ieee",
        " acm, new york",
        " ieee, new york",
        ", ottawa",
        ", new york",
        ", usa",
        ", canada",
        ", china",
        ", germany",
        ", uk",
    ] {
        if let Some(position) = lower.find(marker) {
            end = end.min(position);
        }
    }
    venue = venue[..end].trim();
    venue = venue.trim_matches(['.', ',', ';', ':', '-']).trim();
    venue.chars().take(180).collect()
}

fn is_under_review(text: &str) -> bool {
    let lower = text.to_lowercase();
    lower.contains("under review")
        || lower.contains("submitted to")
        || lower.contains("double-blind")
        || lower.contains("anonymous authors")
        || lower.contains("paper under review")
}

fn is_copyright_line(text: &str) -> bool {
    let lower = text.to_lowercase();
    lower.contains('©')
        || lower.contains("copyright")
        || lower.contains("(c)")
        || lower.contains("all rights reserved")
        || lower.contains("acm isbn")
        || lower.contains("publication rights")
        || lower.contains("personal use")
}

fn has_month_name(text: &str) -> bool {
    const MONTHS: &[&str] = &[
        "january",
        "february",
        "march",
        "april",
        "may",
        "june",
        "july",
        "august",
        "september",
        "october",
        "november",
        "december",
        "jan",
        "feb",
        "mar",
        "apr",
        "jun",
        "jul",
        "aug",
        "sep",
        "sept",
        "oct",
        "nov",
        "dec",
    ];
    // A capitalised month name, not the modal "may": review PDFs put body citations such as
    // "(Wang et al., 2025)" in the bottom band, and a lowercase prose word must not turn one
    // into a publication year.
    text.split(|character: char| !character.is_alphabetic())
        .filter(|word| word.chars().next().is_some_and(char::is_uppercase))
        .any(|word| MONTHS.contains(&word.to_lowercase().as_str()))
}

/// A footer that is only a year (possibly with punctuation) is a copyright year, not a page
/// number; "IEEE Xplore. 1973" is neither and is rejected by the callers.
fn is_bare_year(text: &str) -> bool {
    let trimmed = text.trim_matches(|character: char| {
        character.is_whitespace() || matches!(character, '.' | ',' | '-' | '(' | ')' | '©')
    });
    trimmed.len() == 4 && trimmed.chars().all(|character| character.is_ascii_digit())
}

/// A copyright line, or a line carrying a month and a year, anywhere on page one.
fn year_from_raw_text(text: &str) -> Option<String> {
    let mut best = None;
    for line in text.split(['\n', '\r']) {
        let line = line.trim();
        if line.is_empty() || is_under_review(line) {
            continue;
        }
        let Some(year) = four_digit_year(line) else {
            continue;
        };
        if is_copyright_line(line) || has_month_name(line) {
            // Prefer a copyright statement over an incidental date; within one kind the last
            // printed date wins (a revision date follows a submission date).
            if is_copyright_line(line) {
                return Some(year);
            }
            best = Some(year);
        }
    }
    best
}

fn is_furniture_without_venue(text: &str) -> bool {
    let lower = text.trim().to_lowercase();
    lower.is_empty()
        || lower.chars().all(|character| character.is_ascii_digit())
        || lower.starts_with("page ")
        || lower.starts_with("doi:")
        || lower.starts_with("https://doi.org")
        || lower.starts_with("http")
        || lower.contains("arxiv:")
        || lower.contains("all rights reserved")
}

fn most_common_year(years: &[String]) -> Option<String> {
    if years.is_empty() {
        return None;
    }
    let mut counts: std::collections::BTreeMap<&str, usize> = std::collections::BTreeMap::new();
    for year in years {
        *counts.entry(year.as_str()).or_default() += 1;
    }
    counts
        .into_iter()
        .max_by(|(left_year, left_count), (right_year, right_count)| {
            left_count.cmp(right_count).then(left_year.cmp(right_year))
        })
        .map(|(year, _)| year.to_string())
}

fn is_furniture(text: &str) -> bool {
    let lower = text.trim().to_lowercase();
    lower.starts_with("arxiv:")
        || lower.starts_with("doi:")
        || lower.starts_with("http://")
        || lower.starts_with("https://")
        || lower.starts_with("www.")
        || lower.contains("arxiv.org/abs")
        || lower.contains("creative commons")
        || lower.starts_with("copyright")
        || lower.starts_with('©')
        || lower.starts_with("(c)")
        || lower.chars().all(|character| character.is_ascii_digit())
}

fn looks_like_affiliation(text: &str) -> bool {
    let lower = text.to_lowercase();
    const AFFILIATION_WORDS: &[&str] = &[
        "university",
        "université",
        "institute",
        "institut",
        "department",
        "dept.",
        "school of",
        "faculty",
        "laboratory",
        "laboratories",
        "college",
        "academy",
        "research center",
        "research centre",
        "google brain",
        "google research",
        " lab",
        " labs",
        " group",
        " center",
        " centre",
        " research",
        " inc.",
        " ltd.",
        " corporation",
    ];
    lower.contains('@') || AFFILIATION_WORDS.iter().any(|word| lower.contains(word))
}

#[cfg(test)]
mod tests {
    use super::*;
    use aris_reader_core::{DocMetadata, PageIndex, Point, RawCharBox, Rect, XmpMetadata};

    /// A page built from `(x, baseline, font_size, text)` runs, in PDF user space.
    fn page(lines: &[(f64, f64, f64, &str)]) -> RawTextPage {
        let mut chars: Vec<RawCharBox> = Vec::new();
        let mut text = String::new();
        for (x, y, size, content) in lines {
            let mut cursor = *x;
            for character in content.chars() {
                chars.push(RawCharBox {
                    rect: Rect::new(cursor, *y, size * 0.5, *size),
                    origin: Point::new(cursor, *y),
                    unicode: u32::from(character),
                    font_size: *size,
                    angle: 0.0,
                    font_name: "Helvetica".to_string(),
                });
                cursor += size * 0.5;
            }
            text.push_str(content);
            text.push('\n');
        }
        RawTextPage {
            page: PageIndex(0),
            chars,
            text,
            is_generated: false,
            has_unicode_map_error: false,
        }
    }

    fn title_page() -> RawTextPage {
        page(&[
            (72.0, 770.0, 24.0, "Attention Is All You Need"),
            (72.0, 735.0, 11.0, "Ashish Vaswani, Noam Shazeer"),
            (72.0, 715.0, 9.0, "Google Brain, Google Research"),
            (72.0, 560.0, 10.0, "Abstract"),
            (
                72.0,
                540.0,
                10.0,
                "The dominant sequence transduction models are based on complex recurrent networks.",
            ),
            (
                72.0,
                45.0,
                8.0,
                "Proceedings of the 2017 Conference on Neural Information Processing Systems",
            ),
            (72.0, 30.0, 8.0, "https://doi.org/10.5555/3295222.3295349"),
        ])
    }

    #[test]
    fn a_title_block_and_author_line_are_recognised_from_page_one() {
        let recognized = recognize(&EmbeddedMetadata::default(), Some(&title_page()), 842.0);
        assert_eq!(recognized.title.value(), Some("Attention Is All You Need"));
        assert_eq!(recognized.title.source, Some(MetadataSource::FirstPage));
        assert!(recognized.title.is_guessed());
        assert_eq!(
            recognized.authors.values,
            vec!["Ashish Vaswani", "Noam Shazeer"]
        );
        assert_eq!(recognized.authors.source, Some(MetadataSource::FirstPage));
        assert_eq!(recognized.doi.value(), Some("10.5555/3295222.3295349"));
        assert_eq!(recognized.doi.source, Some(MetadataSource::Text));
        assert!(!recognized.doi.is_guessed());
        assert_eq!(
            recognized.venue.value(),
            Some("Proceedings of the 2017 Conference on Neural Information Processing Systems")
        );
        assert_eq!(recognized.year.value(), Some("2017"));
        assert_eq!(recognized.year.source, Some(MetadataSource::PageFurniture));
    }

    #[test]
    fn embedded_metadata_wins_and_keeps_its_own_source() {
        let embedded = EmbeddedMetadata {
            info: DocMetadata {
                title: Some("Info title".into()),
                author: Some("Grace Hopper; Alan Turing".into()),
                ..DocMetadata::default()
            },
            xmp: XmpMetadata {
                title: Some("XMP title".into()),
                authors: vec!["Ada Lovelace".into()],
                doi: Some("10.1145/1234567.8901234".into()),
                venue: Some("Journal of Testing".into()),
                year: Some("2024".into()),
            },
        };
        let recognized = recognize(&embedded, Some(&title_page()), 842.0);
        assert_eq!(recognized.title.value(), Some("XMP title"));
        assert_eq!(recognized.title.source, Some(MetadataSource::Xmp));
        assert_eq!(recognized.authors.values, vec!["Ada Lovelace"]);
        assert_eq!(recognized.authors.source, Some(MetadataSource::Xmp));
        assert_eq!(recognized.venue.value(), Some("Journal of Testing"));
        assert_eq!(recognized.year.value(), Some("2024"));
        assert_eq!(recognized.doi.value(), Some("10.1145/1234567.8901234"));
        assert!(!recognized.title.is_guessed());
    }

    #[test]
    fn a_garbage_info_title_falls_back_to_the_text_layer() {
        let embedded = EmbeddedMetadata {
            info: DocMetadata {
                title: Some("Microsoft Word - paper.doc".into()),
                author: Some("Administrator".into()),
                ..DocMetadata::default()
            },
            ..EmbeddedMetadata::default()
        };
        let recognized = recognize(&embedded, Some(&title_page()), 842.0);
        assert_eq!(recognized.title.value(), Some("Attention Is All You Need"));
        assert_eq!(recognized.title.source, Some(MetadataSource::FirstPage));
        assert_eq!(
            recognized.authors.values,
            vec!["Ashish Vaswani", "Noam Shazeer"]
        );
    }

    #[test]
    fn an_arxiv_id_gives_a_year_and_a_misc_entry() {
        let page = page(&[
            (72.0, 770.0, 24.0, "A Paper Without a Venue"),
            (72.0, 735.0, 11.0, "Ada Lovelace"),
            (72.0, 560.0, 10.0, "Abstract"),
            (
                72.0,
                540.0,
                10.0,
                "Body text that is long enough to establish the median line height.",
            ),
            (72.0, 40.0, 8.0, "arXiv:2303.08774v2 [cs.CL] 2 Mar 2023"),
        ]);
        let recognized = recognize(&EmbeddedMetadata::default(), Some(&page), 842.0);
        assert_eq!(recognized.arxiv_id.value(), Some("2303.08774v2"));
        assert_eq!(recognized.arxiv_id.source, Some(MetadataSource::Text));
        assert_eq!(recognized.year.value(), Some("2023"));
        // The footer date is page furniture, which is a guess either way; the arXiv prefix is
        // the fallback when the page does not print one.
        assert_eq!(recognized.year.source, Some(MetadataSource::PageFurniture));
        assert!(recognized.venue.is_empty());
        let bibtex = recognized.bibtex();
        assert!(bibtex.starts_with("@misc{lovelace2023paper,"), "{bibtex}");
        assert!(bibtex.contains("eprint = {2303.08774v2}"), "{bibtex}");
        assert!(!bibtex.contains("journal"), "{bibtex}");
    }

    #[test]
    fn an_arxiv_id_without_a_printed_date_provides_the_year() {
        let page = page(&[
            (72.0, 770.0, 24.0, "A Paper With Only an Identifier"),
            (72.0, 735.0, 11.0, "Ada Lovelace"),
            (72.0, 560.0, 10.0, "Abstract"),
            (
                72.0,
                540.0,
                10.0,
                "Body text that is long enough to establish the median line height.",
            ),
            (72.0, 40.0, 8.0, "arXiv:2303.08774v2"),
        ]);
        let recognized = recognize(&EmbeddedMetadata::default(), Some(&page), 842.0);
        assert_eq!(recognized.year.value(), Some("2023"));
        assert_eq!(recognized.year.source, Some(MetadataSource::ArxivDerived));
    }

    #[test]
    fn a_scanned_page_with_empty_embedded_metadata_stays_empty() {
        let empty_page = RawTextPage::default();
        let recognized = recognize(&EmbeddedMetadata::default(), Some(&empty_page), 842.0);
        assert!(recognized.title.is_empty());
        assert!(recognized.authors.is_empty());
        assert!(recognized.venue.is_empty());
        assert!(recognized.year.is_empty());
        assert!(recognized.doi.is_empty());
        assert!(recognized.arxiv_id.is_empty());
        assert!(recognized.title.source.is_none());
        let bibtex = recognized.bibtex();
        assert_eq!(bibtex, "@misc{untitled\n}\n");
    }

    #[test]
    fn body_text_at_one_size_is_not_promoted_to_a_title() {
        let body = page(&[
            (
                72.0,
                700.0,
                10.0,
                "This is the first line of an ordinary page of body text.",
            ),
            (
                72.0,
                680.0,
                10.0,
                "This is the second line of an ordinary page of body text.",
            ),
            (
                72.0,
                660.0,
                10.0,
                "This is the third line of an ordinary page of body text.",
            ),
        ]);
        let recognized = recognize(&EmbeddedMetadata::default(), Some(&body), 842.0);
        assert!(recognized.title.is_empty());
        assert!(recognized.authors.is_empty());
    }

    #[test]
    fn affiliations_are_not_reported_as_authors() {
        let page = page(&[
            (72.0, 770.0, 24.0, "A Real Title"),
            (
                72.0,
                735.0,
                10.0,
                "Department of Computer Science, Example University",
            ),
            (72.0, 560.0, 10.0, "Abstract"),
            (
                72.0,
                540.0,
                10.0,
                "Body text that is long enough to establish the median line height.",
            ),
        ]);
        let recognized = recognize(&EmbeddedMetadata::default(), Some(&page), 842.0);
        assert_eq!(recognized.title.value(), Some("A Real Title"));
        assert!(recognized.authors.is_empty(), "{:?}", recognized.authors);
    }

    #[test]
    fn dois_are_trimmed_and_arxiv_dois_imply_the_id() {
        assert_eq!(
            find_doi("see https://doi.org/10.1145/1234.5678.").as_deref(),
            Some("10.1145/1234.5678")
        );
        assert_eq!(find_doi("not a doi: 10.12/abc"), None);
        assert_eq!(find_doi("12310.1145/1234.5678"), None);
        let embedded = EmbeddedMetadata {
            xmp: XmpMetadata {
                doi: Some("10.48550/arXiv.2303.08774".into()),
                ..XmpMetadata::default()
            },
            ..EmbeddedMetadata::default()
        };
        let recognized = recognize(&embedded, None, 842.0);
        assert_eq!(recognized.arxiv_id.value(), Some("2303.08774"));
        assert_eq!(recognized.arxiv_id.source, Some(MetadataSource::Xmp));
    }

    #[test]
    fn a_title_above_no_abstract_is_still_found_by_size() {
        let page = page(&[
            (120.0, 780.0, 22.0, "A Title Without an Abstract"),
            (120.0, 745.0, 11.0, "Ada Lovelace"),
            (
                72.0,
                500.0,
                10.0,
                "The paper starts with body text that is long enough to be measured.",
            ),
            (
                72.0,
                480.0,
                10.0,
                "More body text on the same page, also long enough to be measured.",
            ),
        ]);
        let recognized = recognize(&EmbeddedMetadata::default(), Some(&page), 842.0);
        assert_eq!(
            recognized.title.value(),
            Some("A Title Without an Abstract")
        );
        assert_eq!(recognized.authors.values, vec!["Ada Lovelace"]);
    }

    #[test]
    fn empty_publication_facts_are_not_invented_from_creation_dates_or_filenames() {
        let embedded = EmbeddedMetadata {
            info: DocMetadata {
                creation_date: Some("D:20200101000000Z".into()),
                creator: Some("LaTeX with hyperref".into()),
                producer: Some("pdfTeX-1.40.21".into()),
                subject: Some("Some topic".into()),
                keywords: Some("machine learning; testing".into()),
                ..DocMetadata::default()
            },
            ..EmbeddedMetadata::default()
        };
        let recognized = recognize(&embedded, None, 842.0);
        assert!(recognized.title.is_empty());
        assert!(recognized.authors.is_empty());
        assert!(recognized.venue.is_empty());
        assert!(recognized.year.is_empty());
        assert!(recognized.doi.is_empty());
    }

    #[test]
    fn source_metadata_is_honest_about_which_fields_are_guesses() {
        assert!(MetadataSource::FirstPage.is_guessed());
        assert!(MetadataSource::PageFurniture.is_guessed());
        assert!(MetadataSource::ArxivDerived.is_guessed());
        assert!(!MetadataSource::Xmp.is_guessed());
        assert!(!MetadataSource::Info.is_guessed());
        assert!(!MetadataSource::Text.is_guessed());
        assert_eq!(MetadataSource::Xmp.trust(), "embedded");
        assert_eq!(MetadataSource::Text.trust(), "identified");
        assert_eq!(MetadataSource::FirstPage.trust(), "guessed");
    }
}
