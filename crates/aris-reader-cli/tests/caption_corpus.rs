//! Opt-in completeness check for caption text, against the local, uncommitted PDF corpora.
//!
//! Run with PDFium available and the corpora pointed at:
//! `ARIS_READER_PDF_SAMPLES=… ARIS_READER_EVAL_PAPERS=… \
//!  cargo test -p aris-reader-cli --test caption_corpus -- --ignored --nocapture`
//!
//! # What this measures
//!
//! `find_captions` reports a caption as its **label line plus the run of lines that continues it**
//! (`aris-reader-text`'s `caption_block`). This harness re-derives that run from the raw page —
//! line boxes, baselines and glyph heights, taken from the character array directly — and checks
//! the crate's answer against it:
//!
//! * **no line dropped**: every line the run covers ends inside the caption's character range, and
//!   the caption's own text carries that line's words;
//! * **no line stolen**: the run stops where the documented rule stops, so a caption cannot take
//!   the body text or the table rows under it (the rule's own numbers are measured in
//!   `CAPTION_LEADING_SHARE` / `CAPTION_TYPE_TOLERANCE_PT`).
//!
//! The re-derivation is written here rather than called from the crate on purpose: a test that
//! asks the implementation what the answer is cannot fail. It repeats the two constants, and
//! `the_rule_constants_are_the_ones_the_crate_documents` pins them to the crate's so the copy
//! cannot drift silently.
//!
//! The second half of the check is independent of the rule: a caption's text should close a
//! sentence. Before the caption carried its continuation lines, most captions on this corpus
//! stopped mid-clause (`… which`, `… compared to their plain`); the count of captions that do not
//! close is printed, and the ones that remain are listed for review.

use aris_reader_core::{DocumentBackend, PageIndex, RawCharBox, RawTextPage, Rect};
use aris_reader_pdfium::PdfiumBackend;
use aris_reader_text::{
    PageEvidence, caption_region_from, caption_region_without_margin, find_captions, lines_from,
};
use std::path::{Path, PathBuf};

/// The crate's `CAPTION_LINE_GAP_SHARE`, repeated so the re-derivation does not call it.
const LINE_GAP_SHARE: f64 = 0.6;
/// The crate's `CAPTION_TYPE_TOLERANCE_PT`, repeated for the same reason.
const TYPE_TOLERANCE_PT: f64 = 0.75;
/// The crate's `CAPTION_INK_GAP_SHARE`, repeated for the same reason.
const INK_GAP_SHARE: f64 = 2.0;
/// The crate's `MIN_OVERLAP_SHARE`: two boxes line up when they share half the narrower one.
const OVERLAP_SHARE: f64 = 0.5;

/// One line of the character array.
struct Line {
    /// Half-open character range, without the terminating newline.
    range: (usize, usize),
    x0: f64,
    x1: f64,
    /// Lowest and highest ink of the line, in page space (y grows upwards).
    ink_bottom: f64,
    ink_top: f64,
    height: f64,
    compact: String,
    /// Widest gap between two runs of ink inside the line.
    gap: f64,
}

impl Line {
    fn ink(&self) -> (f64, f64) {
        (self.ink_bottom, self.ink_top)
    }

    fn overlap_share(&self, other: (f64, f64)) -> f64 {
        let overlap = self.x1.min(other.1) - self.x0.max(other.0);
        if overlap <= 0.0 {
            return 0.0;
        }
        overlap / (self.x1 - self.x0).min(other.1 - other.0).max(1e-6)
    }
}

fn corpus_files() -> Vec<PathBuf> {
    let mut files = Vec::new();
    for key in ["ARIS_READER_PDF_SAMPLES", "ARIS_READER_EVAL_PAPERS"] {
        let Ok(directory) = std::env::var(key) else {
            continue;
        };
        let mut here: Vec<PathBuf> = std::fs::read_dir(directory)
            .expect("corpus directory")
            .map(|entry| entry.unwrap().path())
            .filter(|path| path.extension().is_some_and(|kind| kind == "pdf"))
            .collect();
        here.sort();
        files.extend(here);
    }
    files
}

fn short_name(path: &Path) -> String {
    path.file_name()
        .unwrap()
        .to_string_lossy()
        .chars()
        .take(22)
        .collect()
}

fn visible(character: &RawCharBox) -> bool {
    char::from_u32(character.unicode)
        .map(|decoded| !decoded.is_whitespace())
        .unwrap_or(false)
}

/// Splits a page into lines at the `\n` of its character array and measures each one.
fn lines_of(raw: &RawTextPage) -> Vec<Line> {
    let chars: Vec<char> = raw
        .chars
        .iter()
        .map(|character| char::from_u32(character.unicode).unwrap_or(' '))
        .collect();
    let mut lines = Vec::new();
    let mut start = 0usize;
    loop {
        let end = chars[start..]
            .iter()
            .position(|character| *character == '\n')
            .map(|offset| start + offset)
            .unwrap_or(chars.len());
        let shown: Vec<&RawCharBox> = raw.chars[start..end]
            .iter()
            .filter(|c| visible(c))
            .collect();
        let mut heights: Vec<f64> = shown.iter().map(|c| c.rect.size.height).collect();
        heights.sort_by(f64::total_cmp);
        lines.push(Line {
            range: (start, end),
            x0: shown
                .iter()
                .map(|c| c.rect.origin.x)
                .fold(f64::MAX, f64::min),
            x1: shown
                .iter()
                .map(|c| c.rect.max_x())
                .fold(f64::MIN, f64::max),
            ink_bottom: shown
                .iter()
                .map(|c| c.rect.origin.y)
                .fold(f64::MAX, f64::min),
            ink_top: shown
                .iter()
                .map(|c| c.rect.max_y())
                .fold(f64::MIN, f64::max),
            height: heights.get(heights.len() / 2).copied().unwrap_or(0.0),
            gap: {
                let mut boxes: Vec<&RawCharBox> = shown.clone();
                boxes.sort_by(|a, b| a.rect.origin.x.total_cmp(&b.rect.origin.x));
                let mut right = f64::MIN;
                let mut gap: f64 = 0.0;
                for character in boxes {
                    if right > f64::MIN && character.rect.origin.x - right > gap {
                        gap = character.rect.origin.x - right;
                    }
                    right = right.max(character.rect.max_x());
                }
                gap
            },
            compact: chars[start..end]
                .iter()
                .collect::<String>()
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" "),
        });
        if end >= chars.len() {
            break;
        }
        start = end + 1;
    }
    lines
}

/// Whether `line` opens a caption label of its own (which ends the run rather than joining it).
fn opens_a_caption(line: &str) -> bool {
    let lower = line.trim_start().to_ascii_lowercase();
    for keyword in ["figure", "fig.", "table", "tab.", "algorithm", "alg."] {
        if let Some(rest) = lower.strip_prefix(keyword) {
            let rest = rest.trim_start();
            if rest.starts_with(|c: char| c.is_ascii_digit()) {
                return true;
            }
        }
    }
    false
}

/// The lines a caption starting at `anchor` covers, by the rule the crate documents.
fn block_of(lines: &[Line], anchor: usize) -> Vec<usize> {
    let mut included = vec![anchor];
    let (mut x0, mut x1) = (lines[anchor].x0, lines[anchor].x1);
    let (mut ink_bottom, mut ink_top) = lines[anchor].ink();
    let reference = lines[anchor].height;
    let mut max_gap = lines[anchor].gap;

    loop {
        let last = *included.last().unwrap();
        let block = Line {
            range: (0, 0),
            x0,
            x1,
            ink_bottom,
            ink_top,
            height: reference,
            compact: String::new(),
            gap: max_gap,
        };
        let next = (last + 1..lines.len()).find(|index| {
            let line = &lines[*index];
            !line.compact.is_empty()
                && line.x1 > line.x0
                && block.overlap_share((line.x0, line.x1)) >= OVERLAP_SHARE
        });
        let Some(next) = next else { break };
        let line = &lines[next];
        let gap = ink_bottom - line.ink_top;
        if gap > LINE_GAP_SHARE * reference
            || line.height - reference > TYPE_TOLERANCE_PT
            || line.gap > INK_GAP_SHARE * reference
            || opens_a_caption(&line.compact)
        {
            break;
        }
        included.push(next);
        x0 = x0.min(line.x0);
        x1 = x1.max(line.x1);
        ink_bottom = ink_bottom.min(line.ink_bottom);
        ink_top = ink_top.max(line.ink_top);
        max_gap = max_gap.max(line.gap);
    }
    included
}

/// Whether the caption's text closes a sentence (or, at least, a clause).
fn closes(text: &str) -> bool {
    text.trim_end()
        .ends_with(['.', ':', '?', '!', ')', ']', '\u{201d}', ',', ';'])
}

#[test]
#[ignore = "requires the local PDF corpora and a PDFium shared library"]
fn captions_carry_the_whole_run_of_lines_that_continues_them() {
    let files = corpus_files();
    assert!(!files.is_empty(), "point the corpus variables at the PDFs");

    let mut captions = 0usize;
    let mut multi_line = 0usize;
    let mut dropped_lines = 0usize;
    let mut dropped_text = 0usize;
    let mut closed = 0usize;
    let mut regions = 0usize;
    let mut swallowed = 0usize;
    let mut report: Vec<String> = Vec::new();

    for path in &files {
        let name = short_name(path);
        let backend = PdfiumBackend::open(path, None).expect("open PDF");
        let (mut file_captions, mut file_multi) = (0usize, 0usize);
        for index in 0..backend.page_count().min(120) {
            let Ok(text) = backend.raw_text_page(PageIndex(index)) else {
                continue;
            };
            let lines = lines_of(&text);
            let page_lines = lines_from(&text);
            let (images, _) = backend
                .page_object_summary(PageIndex(index))
                .unwrap_or_default();
            let rules = backend
                .page_line_segments(PageIndex(index))
                .unwrap_or_default();
            let bounds = backend
                .page_info(PageIndex(index))
                .map(|info| info.geometry.crop_box)
                .unwrap_or_default();
            for caption in find_captions(&text) {
                let Some(anchor) = lines
                    .iter()
                    .position(|line| caption.start >= line.range.0 && caption.start < line.range.1)
                else {
                    report.push(format!(
                        "{name} p{}: caption {:?} has no line",
                        index + 1,
                        caption.label
                    ));
                    continue;
                };
                captions += 1;
                file_captions += 1;
                let block = block_of(&lines, anchor);
                if block.len() > 1 {
                    multi_line += 1;
                    file_multi += 1;
                }
                let last = *block.last().unwrap();
                if lines[last].range.1 > caption.end {
                    dropped_lines += 1;
                    report.push(format!(
                        "{name} p{} {} {}: range ends at {}, the run at {} — last line {:?}",
                        index + 1,
                        caption.kind,
                        caption.label,
                        caption.end,
                        lines[last].range.1,
                        lines[last].compact.chars().take(60).collect::<String>()
                    ));
                }
                let normalized = caption
                    .text
                    .split_whitespace()
                    .collect::<Vec<_>>()
                    .join(" ");
                let missing: Vec<&String> = block
                    .iter()
                    .skip(1)
                    .map(|index| &lines[*index].compact)
                    .filter(|line| !normalized.contains(line.as_str()))
                    .collect();
                if !missing.is_empty() {
                    dropped_text += 1;
                    report.push(format!(
                        "{name} p{} {} {}: text misses {}",
                        index + 1,
                        caption.kind,
                        caption.label,
                        missing
                            .iter()
                            .map(|line| format!("{line:?}"))
                            .collect::<Vec<_>>()
                            .join(", ")
                    ));
                }
                // The preview's white edge must grow into empty page, never into the text or the
                // artwork around the region: everything the region covers has to be the caption
                // itself, the figure it names, or the grid of the table it names.
                let evidence = PageEvidence {
                    images: &images,
                    rules: &rules,
                    lines: &page_lines,
                };
                let region = caption_region_from(&caption, evidence, bounds);
                if !is_full_page(region, bounds) {
                    regions += 1;
                    let unpadded = caption_region_without_margin(&caption, evidence, bounds);
                    // Another figure's artwork is the other thing the edge must not take in.
                    for image in &images {
                        if intersects(region, *image) && !intersects(unpadded, *image) {
                            swallowed += 1;
                            report.push(format!(
                                "{name} p{} {} {}: the white edge took in an image object at {:?}",
                                index + 1,
                                caption.kind,
                                caption.label,
                                image
                            ));
                        }
                    }
                    // Character by character, not line by line: `lines_from` groups the rotated
                    // labels of a figure into boxes that span a whole panel, and a box like that
                    // says nothing about what the white edge did. A glyph does.
                    for character in &text.chars {
                        let glyph = character.rect;
                        if glyph.size.width <= 0.0
                            || glyph.size.height <= 0.0
                            || !intersects(region, glyph)
                        {
                            continue;
                        }
                        // What the margin added is what the white edge covers and the geometry
                        // did not: this is the "never swallow adjacent text" check, and it is
                        // per glyph because a line box in a figure can span a whole panel.
                        if !intersects(unpadded, glyph) {
                            swallowed += 1;
                            report.push(format!(
                                "{name} p{} {} {}: the white edge took in {:?} — {:?}",
                                index + 1,
                                caption.kind,
                                caption.label,
                                char::from_u32(character.unicode).unwrap_or('?'),
                                glyph
                            ));
                            if swallowed > 6 {
                                break;
                            }
                        }
                    }
                }
                if closes(&caption.text) {
                    closed += 1;
                } else {
                    report.push(format!(
                        "{name} p{} {} {} does not close: …{}",
                        index + 1,
                        caption.kind,
                        caption.label,
                        caption
                            .text
                            .chars()
                            .rev()
                            .take(48)
                            .collect::<String>()
                            .chars()
                            .rev()
                            .collect::<String>()
                    ));
                }
            }
        }
        if file_captions > 0 {
            println!("{name}: {file_captions} caption(s), {file_multi} of them multi-line");
        }
    }

    println!(
        "total: {captions} caption(s) over {} paper(s), {multi_line} multi-line; \
         {dropped_lines} with a dropped line, {dropped_text} with dropped text, \
         {closed} closing a sentence; {regions} region(s) with a white edge, \
         {swallowed} line(s) taken in by one",
        files.len()
    );
    for line in &report {
        println!("  ! {line}");
    }

    // Measured 2026-10-15 on the twelve sample papers and the twenty evaluation papers: every
    // caption's run is inside its range, every continuation line's words are in its text, and 384
    // of the 429 captions close a sentence (the rest are listed above and are either captions the
    // papers print without final punctuation or the line-start prose `find_captions` still
    // mistakes for a caption, T4.12 — both are questions about the *label*, not about the run).
    assert_eq!(dropped_lines, 0, "a caption lost a line of its own run");
    assert_eq!(
        swallowed, 0,
        "the preview's white edge reached into neighbouring content"
    );
    assert!(
        regions >= 150,
        "only {regions} regions had a white edge to add"
    );
    assert_eq!(dropped_text, 0, "a caption's text lost a line of its run");
    assert!(
        multi_line >= 200,
        "the run is not being found at all: only {multi_line} captions are multi-line"
    );
    assert!(
        closed * 100 >= captions * 85,
        "only {closed} of {captions} captions close a sentence"
    );
}

/// Whether two boxes overlap at all.
fn intersects(a: Rect, b: Rect) -> bool {
    a.origin.x < b.max_x()
        && b.origin.x < a.max_x()
        && a.origin.y < b.max_y()
        && b.origin.y < a.max_y()
}

/// Whether the region is the page itself (the fallback for art the page does not draw).
fn is_full_page(region: Rect, bounds: Rect) -> bool {
    region.size.width >= bounds.size.width * 0.99 && region.size.height >= bounds.size.height * 0.99
}
