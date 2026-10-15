//! Figure, table, and algorithm cross-references, and the page region a preview should show.
//!
//! Two different questions live here, and they are easy to conflate:
//!
//! * **Where does the body mention `Figure 3`?** — a text question, answered by
//!   [`find_caption_mentions`]. The answer is a click target, so it needs character boxes and
//!   nothing else.
//! * **What should the floating preview show for it?** — a geometry question about the caption
//!   and the artwork around it, answered by [`caption_region_from`] (and by the narrower
//!   [`caption_region`], which is the same call with the page's rules withheld). The answer is a
//!   rectangle of the page, which the shell rasterizes.
//!
//! Keeping them apart is what lets the second one be measured: the corpus numbers reported for
//! `aris-reader-cli figures` are the regions the shell will actually show.

use aris_reader_core::{LineSegment, RawTextPage, Rect};
use std::collections::HashSet;

use crate::tables::table_region;
use crate::{Caption, TextLine, union_boxes, union_rect};

/// The page evidence a preview region can be derived from.
///
/// This is an input bundle rather than four arguments because the four travel together: a caller
/// that can read one of them can read all of them from the same open page, and a caller that
/// cannot read the rules (an older test, a synthetic page) simply passes an empty slice and gets
/// the pre-table behaviour.
#[derive(Clone, Copy, Debug, Default)]
pub struct PageEvidence<'a> {
    /// Image-object boxes, from `page_object_summary`.
    pub images: &'a [Rect],
    /// Axis-aligned rules of the page's vector geometry, from `page_line_segments`.
    ///
    /// Tables are drawn as lines and have no object of their own, so this is the only handle on
    /// them at all. Empty means "the caller could not read the geometry", which costs the table
    /// region but never changes a figure's.
    pub rules: &'a [LineSegment],
    /// The page's text layer grouped into lines, from [`crate::lines_from`].
    ///
    /// This confirms a candidate grid: rules alone cannot tell a table from a figure made of
    /// lines, and the text inside the cells is what separates them.
    pub lines: &'a [TextLine],
}

/// Distance above a caption (points) within which an image object can be its artwork.
///
/// Measured on the corpus rather than guessed. A caption set under its own figure is 0–25 pt below
/// it (SMooDi Figures 1 and 3–7, HumanMM Figures 1–2, InstructAvatar Figures 1–6), while the
/// objects a page-wide window drags in sit 137–180 pt up: with 400 pt, `Fig. 7` on page 13 of the
/// SMooDi paper received `Fig. 6`'s artwork, and `Figure 11` on page 18 of the Ye paper received a
/// region covering the top two thirds of the page, figure above included. 60 pt keeps every
/// measured true pair and drops those. The price is a figure whose raster insets sit further from
/// its caption: it falls back to the full visible page below.
const MAX_IMAGE_DISTANCE_PT: f64 = 60.0;

/// How close (points) another image object must be to join the figure being assembled.
///
/// About two body-text lines: the inset panels of SMooDi Figure 2 sit 21 pt apart, while the
/// artwork of a *different* figure is a caption line away (the 137 pt case above).
const PANEL_GAP_PT: f64 = 24.0;

/// Share of the narrower box that two boxes must overlap along an axis to count as related.
const MIN_OVERLAP_SHARE: f64 = 0.5;

/// White space left around a preview region, as a share of the region's shorter side.
///
/// A crop taken exactly along the detected border reads as a cut-off figure; the reader asked for
/// a little white around it. The share is what keeps the margin proportionate: measured over the
/// 185 regions of the corpus that are not the full-page fallback (2026-10-15), the median region is
/// 396 × 175 pt and the ninetieth percentile 504 × 328 pt, so 2 % of the shorter side is 3.5 pt
/// there and 6.6 pt on a full-column figure.
const PREVIEW_MARGIN_SHARE: f64 = 0.02;

/// The smallest margin worth leaving (points): [`PREVIEW_MARGIN_SHARE`] of a small region.
///
/// The captions of this corpus leave 0.9–3.5 pt of white between their own lines; a preview edge
/// narrower than that reads as a rounding error rather than as an edge, so the margin never drops
/// below it.
const PREVIEW_MARGIN_MIN_PT: f64 = 4.0;

/// The largest margin (points): [`PREVIEW_MARGIN_SHARE`] of a tall region.
///
/// One line of body text is 10.9–14.4 pt from baseline to baseline on this corpus; a white edge
/// wider than a line would show as much empty page as figure.
const PREVIEW_MARGIN_MAX_PT: f64 = 12.0;

/// A `Figure N` / `Fig. N` / `Table N` / `Algorithm N` reference in the running text.
///
/// This is the click target, not the caption: see [`find_caption_mentions`] for exactly what is
/// and is not reported.
#[derive(Clone, Debug, PartialEq)]
pub struct CaptionMention {
    /// `Figure`, `Table`, or `Algorithm` (the normalised spelling, as in [`Caption::kind`]).
    pub kind: String,
    /// The number as printed: `3`, `12`.
    pub label: String,
    /// Bounding box in **page space** (bottom-left origin).
    pub rect: Rect,
    /// Half-open character range inside the page's text layer.
    pub start: usize,
    pub end: usize,
}

/// Finds `Figure N` / `Fig. N` / `Table N` / `Algorithm N` references **anywhere** in a page's text.
///
/// This is the prose half of the figure index, and the counterpart of [`crate::find_captions`]:
/// a caption is found by its position and punctuation after the label, while a cross-reference in
/// the body has no such caption delimiter — `Figure 3 shows` and `(see Fig. 3)` must both be found.
///
/// # What is reported, and what is left to `find_captions`
///
/// The two scanners partition the same pattern instead of overlapping on it: an occurrence that
/// opens a line and uses a caption delimiter **is** the caption, so it is not reported here. That is what makes the result
/// directly usable as click targets — a reader clicking the caption printed under the figure is
/// already looking at the figure. A caller that wants every occurrence can union the two results,
/// because an occurrence is reported by exactly one of them. (An occurrence *inside* a caption
/// line — `Figure 3: comparison with Figure 2` — is a mention of the other figure and is reported
/// as such.)
///
/// The vocabulary deliberately matches `find_captions` — `Figure`, `Fig.`, `Table`, `Algorithm`,
/// `Alg.`, then a plain
/// number — so that a mention and a caption agree on what `Figure 3` names. Plural forms
/// (`Figures 3 and 4`) and sub-numbers (`Fig. 3.1`) are not reported, because no caption carries
/// those labels either; a `3` followed by a letter (`Figure 3a`) is reported as label `3`.
pub fn find_caption_mentions(text: &RawTextPage) -> Vec<CaptionMention> {
    let chars: Vec<char> = text
        .chars
        .iter()
        .map(|character| char::from_u32(character.unicode).unwrap_or(char::REPLACEMENT_CHARACTER))
        .collect();

    let caption_starts: HashSet<usize> = crate::find_captions(text)
        .into_iter()
        .map(|caption| caption.start)
        .collect();
    let mut mentions = Vec::new();

    for (index, character) in chars.iter().enumerate() {
        if matches!(character, '\n' | '\r') {
            continue;
        }
        // Only labels accepted as captions are suppressed; ordinary prose can begin a line with
        // `Figure 3 shows ...` and should remain a clickable mention.
        if caption_starts.contains(&index) {
            continue;
        }
        // `subfigure 3` and `config. 3` contain a keyword but do not start one.
        if index > 0 && chars[index - 1].is_alphanumeric() {
            continue;
        }

        let (kind, after_word) = if matches_word(&chars, index, "figure") {
            ("Figure", index + 6)
        } else if matches_word(&chars, index, "table") {
            ("Table", index + 5)
        } else if matches_word(&chars, index, "algorithm") {
            ("Algorithm", index + 9)
        } else if matches_word(&chars, index, "alg") && chars.get(index + 3) == Some(&'.') {
            ("Algorithm", index + 4)
        } else if matches_word(&chars, index, "fig") && chars.get(index + 3) == Some(&'.') {
            ("Figure", index + 4)
        } else {
            continue;
        };

        // `Figure 3`, `Figure3` and `Fig. 3` all place the number next; a line break between the
        // word and the number is not one reference but the end of a line.
        let mut digits = after_word;
        while chars
            .get(digits)
            .is_some_and(|character| character.is_whitespace() && !matches!(character, '\n' | '\r'))
        {
            digits += 1;
        }

        let mut label_end = digits;
        while chars
            .get(label_end)
            .is_some_and(|character| character.is_ascii_digit() || *character == '.')
        {
            label_end += 1;
        }
        // Same rule as `find_captions`: a plain number, so a sentence's full stop is not part of
        // the label (`Figure 3.`) and `Figure 3.1` is rejected rather than truncated to `3`.
        let label: String = chars[digits..label_end].iter().collect();
        let label = label.trim_end_matches('.').to_string();
        if label.is_empty() || !label.chars().all(|character| character.is_ascii_digit()) {
            continue;
        }

        let end = digits + label.chars().count();
        mentions.push(CaptionMention {
            kind: kind.to_string(),
            label,
            rect: union_boxes(&text.chars[index.min(text.chars.len())..end.min(text.chars.len())]),
            start: index,
            end,
        });
    }

    mentions
}

/// The region of a page a floating preview should show for `caption`.
///
/// # The heuristic
///
/// PDF has no figure object, so the artwork has to be inferred from what the page *does* expose.
/// The rule is the cheap one that fits how papers are laid out: the caption names the figure, and
/// the figure is the image object nearest **above** it (in page space, where y grows upwards, so
/// "above" means a bottom edge with a larger y than the caption's top edge). An image is a
/// candidate when
///
/// * its bottom edge is above the caption's top edge;
/// * the gap between them is at most [`MAX_IMAGE_DISTANCE_PT`] — an object further away belongs
///   to another figure, to a page-top banner or to nothing at all;
/// * the two overlap horizontally by at least half of the narrower box, which stops a caption in
///   one column from adopting the figure in the other.
///
/// Among the candidates the **nearest** one wins; a tie goes to the larger box, since a figure is
/// usually the biggest object in its own neighbourhood. That object names the figure but is not
/// always the whole of it: a figure drawn as several image objects (one per panel, or one per row
/// of a composite figure) arrives as several candidates, and stopping at the nearest one is
/// measured to cut real figures in half — on page 6 of the SMooDi paper the figure is two
/// 335×42 pt images and the nearest-only region covered the lower row alone. The region therefore
/// grows across candidates that touch what it already covers (within [`PANEL_GAP_PT`] along one
/// axis and overlapping along the other), which is the same "these objects belong together"
/// argument the caption itself uses. Growth is bounded by the candidate filters above, so it
/// cannot escape to another figure: only objects already within reach of *this* caption qualify.
///
/// The result is the union of the caption with everything found. When the artwork is uncertain,
/// the full visible page is returned instead of a misleading caption-only crop. This applies to
/// tables and algorithms, which are not represented by image objects, and to vector figures.
///
/// # Limits, stated plainly
///
/// * **Vector figures and tables have no image object at all.** Those previews use the full page,
///   preserving the artwork or grid in context instead of claiming the caption is the preview.
///   On the Ye paper, most figures are vector art. (A `Table` does better when the caller can
///   supply the page's rules: see [`caption_region_from`].)
/// * **An image object's reported box is often a form's, not the picture's**, because PDFium
///   reports the enclosing form XObject's bounds (the core documents this in
///   `page_object_summary`). On page 18 of the Ye paper one such box spans two figures at once, so
///   no threshold can pair it with the right caption — the full page is shown.
/// * Tables often have captions above them, and algorithms are typeset text; neither can be
///   reliably bounded from image objects, so they use the full page.
/// * A caption that is itself an image (scanned pages) has no character boxes to begin with, so
///   it is never found here.
///
/// `page_bounds` is the visible crop box in page space. The result is clamped to it so that an
/// image object reporting bounds larger than the page — form
/// XObjects routinely do — cannot push the preview off it.
pub fn caption_region(caption: &Caption, images: &[Rect], page_bounds: Rect) -> Rect {
    caption_region_from(
        caption,
        PageEvidence {
            images,
            ..PageEvidence::default()
        },
        page_bounds,
    )
}

/// [`caption_region`], with the whole page as evidence instead of only its image objects.
///
/// The extra inputs buy exactly one thing, and it is the one the task asked for: a `Table`
/// caption whose table is drawn as a grid can be bounded by that grid
/// ([`crate::tables::table_region`]) instead of falling back to the full page. Every other
/// decision is unchanged, so a caller that switches to this entry point cannot regress a figure.
///
/// The three sources are consulted in the order of how much they claim:
///
/// 1. a table grid, for `Table` captions only — geometry the page itself draws;
/// 2. an image object near a `Figure` caption — the historical rule;
/// 3. the full visible page.
///
/// A `Table` caption whose page yields no grid keeps the full page, which is the honest answer:
/// the reader asked for one table and the alternative is a crop of the caption alone.
pub fn caption_region_from(
    caption: &Caption,
    evidence: PageEvidence<'_>,
    page_bounds: Rect,
) -> Rect {
    let region = caption_region_without_margin(caption, evidence, page_bounds);
    with_preview_margin(region, evidence, page_bounds)
}

/// [`caption_region_from`] without the white edge: the region the page's own geometry gives.
///
/// The full-page fallback comes back as the page, and [`with_preview_margin`] then has nothing to
/// grow — which is what keeps "the shell shows the whole page" true for vector figures and for
/// tables whose grid the page does not draw.
///
/// The two steps are separate because they are decided differently: the geometry is measured
/// against what the page draws, and the edge is a presentation choice that is then held back by
/// that geometry. A caller that wants to know which part of a preview is the figure and which part
/// is the white around it asks here; the shell previews [`caption_region_from`].
pub fn caption_region_without_margin(
    caption: &Caption,
    evidence: PageEvidence<'_>,
    page_bounds: Rect,
) -> Rect {
    if caption.kind == "Table"
        && let Some(region) = table_region(caption, evidence.rules, evidence.lines, page_bounds)
    {
        return region;
    }
    let images = evidence.images;
    if caption.kind != "Figure" {
        return page_bounds;
    }
    let candidates: Vec<Rect> = images
        .iter()
        .copied()
        .filter(|image| image.size.width > 0.0 && image.size.height > 0.0)
        .filter(|image| {
            let gap = image.origin.y - caption.rect.max_y();
            (0.0..=MAX_IMAGE_DISTANCE_PT).contains(&gap)
        })
        .filter(|image| overlaps_horizontally(*image, caption.rect))
        .collect();

    // The nearest candidate names the figure; the rest of it is whatever touches the region that
    // caption and figure now cover. `candidates` is finite and each object is added at most once,
    // so the loop terminates.
    let mut included: Vec<Rect> = candidates
        .iter()
        .min_by(|left, right| {
            let gap = |image: &Rect| image.origin.y - caption.rect.max_y();
            gap(left)
                .total_cmp(&gap(right))
                .then(area(right).total_cmp(&area(left)))
        })
        .copied()
        .into_iter()
        .collect();

    loop {
        let region = included
            .iter()
            .fold(caption.rect, |region, image| union_rect(region, *image));
        let Some(next) = candidates
            .iter()
            .find(|image| !included.contains(image) && touches(**image, region))
        else {
            break;
        };
        included.push(*next);
    }

    let region = if included.is_empty() {
        return page_bounds;
    } else {
        included
            .iter()
            .fold(caption.rect, |region, image| union_rect(region, *image))
    };

    clamp_to_page(region, page_bounds)
}

/// Grows `region` by the preview's white edge, stopping short of the page's other content.
///
/// The margin is [`PREVIEW_MARGIN_SHARE`] of the region's shorter side, held between
/// [`PREVIEW_MARGIN_MIN_PT`] and [`PREVIEW_MARGIN_MAX_PT`], and each side is then cut back to the
/// nearest text line or image object that lies beyond it. That cut is what the corpus asks for
/// rather than a safety net bolted on: on the same 185 regions — measured before any margin was
/// applied — the nearest other content sits 1.2 pt away at the fifth percentile, 1.9 pt at the
/// tenth and 6.6 pt at the twenty-fifth, so between a tenth and a quarter of the regions have less
/// room around them than the edge asks for. The region itself is what stays inside the page: the
/// grown rectangle is clamped to `page_bounds` afterwards, which leaves a full-page fallback
/// exactly as it was.
fn with_preview_margin(region: Rect, evidence: PageEvidence<'_>, page_bounds: Rect) -> Rect {
    if region.size.width <= 0.0 || region.size.height <= 0.0 {
        return region;
    }
    let requested = (PREVIEW_MARGIN_SHARE * region.size.width.min(region.size.height))
        .clamp(PREVIEW_MARGIN_MIN_PT, PREVIEW_MARGIN_MAX_PT);
    let mut left = region.origin.x - requested;
    let mut right = region.max_x() + requested;
    let mut bottom = region.origin.y - requested;
    let mut top = region.max_y() + requested;

    for blocker in evidence
        .lines
        .iter()
        .map(|line| line.rect)
        .chain(evidence.images.iter().copied())
    {
        if blocker.size.width <= 0.0 || blocker.size.height <= 0.0 {
            continue;
        }
        // What the region already covers is part of the preview: the caption and the artwork are
        // inside it by construction. A box that covers the *region* is the artwork too — a form
        // XObject's bounds routinely take in the caption under it.
        let (inside, outside) = (contains(region, blocker), contains(blocker, region));
        if inside || outside {
            continue;
        }
        // Every other box is a neighbour, and it holds the edge back from whichever side it
        // reaches over. A box that straddles an edge cancels that side's margin outright
        // (`origin.y.max(region.max_y())` is the edge itself): a text line whose measured box
        // crosses the border — the rotated labels of a figure, or a line the extractor merged
        // out of two — is closer than the margin, whatever its box says.
        let side_by_side = blocker.origin.x < region.max_x() && region.origin.x < blocker.max_x();
        let stacked = blocker.origin.y < region.max_y() && region.origin.y < blocker.max_y();
        if side_by_side {
            if blocker.max_y() > region.max_y() {
                top = top.min(blocker.origin.y.max(region.max_y()));
            }
            if blocker.origin.y < region.origin.y {
                bottom = bottom.max(blocker.max_y().min(region.origin.y));
            }
        }
        if stacked {
            if blocker.max_x() > region.max_x() {
                right = right.min(blocker.origin.x.max(region.max_x()));
            }
            if blocker.origin.x < region.origin.x {
                left = left.max(blocker.max_x().min(region.origin.x));
            }
        }
    }

    let grown = Rect::new(left, bottom, right - left, top - bottom);
    clamp_to_page(grown, page_bounds)
}

/// Whether `word` occurs at `at`, ignoring ASCII case.
fn matches_word(chars: &[char], at: usize, word: &str) -> bool {
    word.chars().enumerate().all(|(offset, expected)| {
        chars
            .get(at + offset)
            .is_some_and(|actual| actual.eq_ignore_ascii_case(&expected))
    })
}

/// Whether the boxes overlap horizontally by at least [`MIN_OVERLAP_SHARE`] of the narrower.
///
/// Shared with the caption scanner, which asks the same question of a caption's line and the line
/// under it.
pub(crate) fn overlaps_horizontally(a: Rect, b: Rect) -> bool {
    overlaps(
        a.max_x().min(b.max_x()) - a.origin.x.max(b.origin.x),
        a.size.width,
        b.size.width,
    )
}

/// Whether the boxes overlap vertically by at least [`MIN_OVERLAP_SHARE`] of the shorter.
fn overlaps_vertically(a: Rect, b: Rect) -> bool {
    overlaps(
        a.max_y().min(b.max_y()) - a.origin.y.max(b.origin.y),
        a.size.height,
        b.size.height,
    )
}

fn overlaps(overlap: f64, a_extent: f64, b_extent: f64) -> bool {
    overlap > 0.0 && overlap >= MIN_OVERLAP_SHARE * a_extent.min(b_extent)
}

/// Whether `image` could be another panel of the figure `region` already covers.
///
/// Panels are laid out in a grid, so two of them are close along one axis and overlap along the
/// other: side by side, or stacked. The gap is only meaningful when the boxes are apart — boxes
/// that already overlap are trivially close.
fn touches(image: Rect, region: Rect) -> bool {
    let horizontal_gap = (image.origin.x - region.max_x()).max(region.origin.x - image.max_x());
    let vertical_gap = (image.origin.y - region.max_y()).max(region.origin.y - image.max_y());
    (horizontal_gap <= PANEL_GAP_PT && overlaps_vertically(image, region))
        || (vertical_gap <= PANEL_GAP_PT && overlaps_horizontally(image, region))
}

/// Whether `inner` lies inside `outer`, edges included.
fn contains(outer: Rect, inner: Rect) -> bool {
    inner.origin.x >= outer.origin.x - 0.01
        && inner.max_x() <= outer.max_x() + 0.01
        && inner.origin.y >= outer.origin.y - 0.01
        && inner.max_y() <= outer.max_y() + 0.01
}

fn area(rect: &Rect) -> f64 {
    rect.size.width * rect.size.height
}

/// Keeps a region inside `0..page_height` vertically; a no-op when the height is unknown.
fn clamp_to_page(region: Rect, page_bounds: Rect) -> Rect {
    if page_bounds.size.height.is_nan() || page_bounds.size.height <= 0.0 {
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
mod figure_tests {
    use super::*;

    /// Every region below carries the preview's white edge: on these 200 × 112 pt regions
    /// [`PREVIEW_MARGIN_SHARE`] would ask for 2.2 pt, so [`PREVIEW_MARGIN_MIN_PT`] gives 4 pt on
    /// each side. The numbers are written out rather than computed so that a change to either
    /// constant shows up as a failing assertion.
    fn caption(rect: Rect) -> Caption {
        Caption {
            kind: "Figure".to_string(),
            label: "3".to_string(),
            text: "Overview of the method.".to_string(),
            rect,
            start: 0,
            end: 0,
        }
    }

    fn page_bounds() -> Rect {
        Rect::new(0.0, 0.0, 612.0, 842.0)
    }

    /// The text the mention range selects, for asserting on what was matched.
    fn mentioned_text(page: &RawTextPage, mention: &CaptionMention) -> String {
        page.chars[mention.start..mention.end]
            .iter()
            .map(|character| {
                char::from_u32(character.unicode).unwrap_or(char::REPLACEMENT_CHARACTER)
            })
            .collect()
    }

    #[test]
    fn a_prose_cross_reference_is_a_mention_but_not_a_caption() {
        let page = crate::test_page("As Figure 3 shows, the method works.\n");
        let mentions = find_caption_mentions(&page);
        assert_eq!(mentions.len(), 1, "{mentions:?}");
        assert_eq!(mentions[0].kind, "Figure");
        assert_eq!(mentions[0].label, "3");
        assert_eq!(mentioned_text(&page, &mentions[0]), "Figure 3");
        // Eight characters of five points, on the one line `test_page` builds.
        assert_eq!(mentions[0].rect.size.width, 40.0);
        assert_eq!(mentions[0].rect.origin.y, 700.0);

        assert!(crate::find_captions(&page).is_empty());
    }

    #[test]
    fn a_caption_is_reported_by_find_captions_and_not_as_a_mention() {
        // The two scanners partition the pattern, so clicking a caption (already on screen) is
        // not offered as a cross-reference.
        let page = crate::test_page("Figure 3: Overview of the method.\n");
        assert!(find_caption_mentions(&page).is_empty());
        let captions = crate::find_captions(&page);
        assert_eq!(captions.len(), 1);
        assert_eq!(captions[0].start, 0);
    }

    #[test]
    fn a_line_starting_figure_reference_is_not_promoted_to_a_caption() {
        let page = crate::test_page("Figure 3 shows the result in the next section.\n");
        assert!(crate::find_captions(&page).is_empty());
        let mentions = find_caption_mentions(&page);
        assert_eq!(mentions.len(), 1, "{mentions:?}");
        assert_eq!(
            (mentions[0].kind.as_str(), mentions[0].label.as_str()),
            ("Figure", "3")
        );
    }

    #[test]
    fn table_caption_without_space_keeps_its_label() {
        let page = crate::test_page("Table2: Results\n");
        let captions = crate::find_captions(&page);
        assert_eq!(captions.len(), 1, "{captions:?}");
        assert_eq!(
            (captions[0].kind.as_str(), captions[0].label.as_str()),
            ("Table", "2")
        );
    }

    #[test]
    fn tables_abbreviations_and_sentence_ends_are_recognised() {
        let page = crate::test_page("We compare in Table 2 and in Fig. 4. See Figure 12 too.\n");
        let mentions = find_caption_mentions(&page);
        let found: Vec<(String, String)> = mentions
            .iter()
            .map(|mention| (mention.kind.clone(), mention.label.clone()))
            .collect();
        assert_eq!(
            found,
            vec![
                ("Table".to_string(), "2".to_string()),
                ("Figure".to_string(), "4".to_string()),
                ("Figure".to_string(), "12".to_string()),
            ],
            "{mentions:?}"
        );
        // The full stop after the label is not part of the click target.
        assert_eq!(mentioned_text(&page, &mentions[1]), "Fig. 4");
    }

    #[test]
    fn algorithm_captions_and_mentions_are_recognised() {
        let caption_page = crate::test_page("Algorithm 2: Greedy matching\nAlg. 3: Sampling\n");
        let captions = crate::find_captions(&caption_page);
        assert_eq!(captions.len(), 2, "{captions:?}");
        assert_eq!(
            (captions[0].kind.as_str(), captions[0].label.as_str()),
            ("Algorithm", "2")
        );
        assert_eq!(
            (captions[1].kind.as_str(), captions[1].label.as_str()),
            ("Algorithm", "3")
        );

        let prose = crate::test_page("See Algorithm 2 and Alg. 3 for details.\n");
        let mentions = find_caption_mentions(&prose);
        assert_eq!(mentions.len(), 2, "{mentions:?}");
        assert!(mentions.iter().all(|mention| mention.kind == "Algorithm"));
        assert_eq!(
            mentions
                .iter()
                .map(|mention| mention.label.as_str())
                .collect::<Vec<_>>(),
            ["2", "3"]
        );
    }

    #[test]
    fn words_that_merely_contain_a_keyword_are_not_mentions() {
        // `subfigure` and `config.` contain `figure`/`fig.`; `Figures 3 and 4` is plural.
        let page = crate::test_page(
            "The subfigure 3 and the config. 2 are set.\nFigures 3 and 4 differ.\n",
        );
        assert!(find_caption_mentions(&page).is_empty());
    }

    #[test]
    fn a_dotted_sub_number_is_not_truncated_into_a_mention() {
        // `Figure 3.1` must not be offered as `Figure 3`: no caption carries the dotted label.
        let page = crate::test_page("See Figure 3.1 for details.\n");
        assert!(find_caption_mentions(&page).is_empty());
    }

    #[test]
    fn the_region_is_the_caption_and_the_image_above_it() {
        let caption = caption(Rect::new(100.0, 100.0, 200.0, 12.0));
        // An image 38 pt above the caption and exactly as wide: this is its figure.
        let region = caption_region(
            &caption,
            &[Rect::new(100.0, 150.0, 200.0, 300.0)],
            page_bounds(),
        );
        assert_eq!(region, Rect::new(96.0, 96.0, 208.0, 358.0));
    }

    #[test]
    fn objects_beyond_the_caption_reach_are_not_its_figure() {
        let caption = caption(Rect::new(100.0, 100.0, 200.0, 12.0)); // top edge at 112
        // 61 pt above that edge: outside the measured caption-to-artwork distance.
        assert_eq!(
            caption_region(
                &caption,
                &[Rect::new(100.0, 173.0, 200.0, 40.0)],
                page_bounds()
            ),
            page_bounds()
        );
        // Exactly at the limit, and the image is this caption's artwork. The white edge stops at
        // that image's bottom edge: 4 pt below the caption would be 96, the image starts at 172
        // and the caption's own top is 112, so the region's top is the image's, 212, plus 4.
        assert_eq!(
            caption_region(
                &caption,
                &[Rect::new(100.0, 172.0, 200.0, 40.0)],
                page_bounds()
            ),
            Rect::new(96.0, 96.0, 208.0, 120.0)
        );
    }

    #[test]
    fn stacked_panels_of_one_figure_are_grown_from_the_nearest_image() {
        // Page 6 of the SMooDi paper: one figure built from two 335x42 pt rows 8 pt apart, the
        // upper row 52 pt above the caption's top edge — inside the caption's reach, but not the
        // nearest object. Both rows are the figure.
        let caption = caption(Rect::new(100.0, 100.0, 200.0, 12.0));
        let lower = Rect::new(100.0, 130.0, 200.0, 26.0);
        let upper = Rect::new(100.0, 164.0, 200.0, 26.0);
        assert_eq!(
            caption_region(&caption, &[lower, upper], page_bounds()),
            Rect::new(96.0, 96.0, 208.0, 98.0)
        );
    }

    #[test]
    fn a_candidate_far_above_the_anchor_is_not_glued_to_the_figure() {
        let caption = caption(Rect::new(100.0, 100.0, 200.0, 12.0));
        // Both are within the caption's reach, but 50 pt separates them, so the upper box is not
        // attached to the figure the lower one names.
        let images = [
            Rect::new(100.0, 115.0, 200.0, 5.0),
            Rect::new(100.0, 170.0, 200.0, 5.0),
        ];
        assert_eq!(
            caption_region(&caption, &images, page_bounds()),
            Rect::new(96.0, 96.0, 208.0, 28.0)
        );
    }

    #[test]
    fn an_image_across_the_gutter_is_never_a_candidate() {
        let caption = caption(Rect::new(100.0, 100.0, 200.0, 12.0));
        let anchor = Rect::new(100.0, 130.0, 200.0, 40.0);
        // Same height, but it does not overlap the caption at all, so it is never a candidate.
        let beside = Rect::new(330.0, 130.0, 200.0, 40.0);
        assert_eq!(
            caption_region(&caption, &[anchor, beside], page_bounds()),
            Rect::new(96.0, 96.0, 208.0, 78.0)
        );
    }

    #[test]
    fn a_far_or_sideways_image_is_not_the_figure() {
        let caption = caption(Rect::new(100.0, 100.0, 200.0, 12.0));
        let padded = page_bounds();

        // 500 pt above: another figure's artwork, not this one's.
        assert_eq!(
            caption_region(
                &caption,
                &[Rect::new(100.0, 620.0, 200.0, 100.0)],
                page_bounds()
            ),
            padded
        );
        // Directly above, but in the other column.
        assert_eq!(
            caption_region(
                &caption,
                &[Rect::new(400.0, 150.0, 200.0, 300.0)],
                page_bounds()
            ),
            padded
        );
        // Above and just overlapping (50 pt of a 200 pt caption): not the same figure.
        assert_eq!(
            caption_region(
                &caption,
                &[Rect::new(250.0, 150.0, 200.0, 300.0)],
                page_bounds()
            ),
            padded
        );
        // Degenerate boxes (whitespace glyphs, clipped objects) are not candidates either.
        assert_eq!(
            caption_region(
                &caption,
                &[Rect::new(100.0, 150.0, 0.0, 300.0)],
                page_bounds()
            ),
            padded
        );
    }

    #[test]
    fn no_image_uses_the_full_page_for_uncertain_vector_art() {
        let caption = caption(Rect::new(100.0, 100.0, 200.0, 12.0));
        assert_eq!(caption_region(&caption, &[], page_bounds()), page_bounds());
    }

    #[test]
    fn table_and_algorithm_regions_use_the_full_page_instead_of_a_nearby_image() {
        let mut caption = caption(Rect::new(100.0, 100.0, 200.0, 12.0));
        caption.kind = "Table".to_string();
        assert_eq!(
            caption_region(
                &caption,
                &[Rect::new(100.0, 150.0, 200.0, 300.0)],
                page_bounds()
            ),
            page_bounds()
        );
        caption.kind = "Algorithm".to_string();
        assert_eq!(caption_region(&caption, &[], page_bounds()), page_bounds());
    }

    #[test]
    fn the_region_stays_inside_the_page() {
        // A form XObject can report bounds taller than the page; the preview must not follow
        // the object off the page.
        let caption = caption(Rect::new(100.0, 700.0, 200.0, 12.0));
        let region = caption_region(
            &caption,
            &[Rect::new(100.0, 720.0, 200.0, 400.0)],
            page_bounds(),
        );
        assert_eq!(region.max_y(), 842.0);
        assert_eq!(region.origin.y, 696.0);
        assert_eq!(region.size.height, 146.0);

        // An invalid page bound leaves the object box untouched, white edge included.
        let unclamped = caption_region(
            &caption,
            &[Rect::new(100.0, 720.0, 200.0, 400.0)],
            Rect::new(0.0, 0.0, 0.0, 0.0),
        );
        assert_eq!(unclamped.max_y(), 1124.0);
    }

    #[test]
    fn the_white_edge_stops_at_the_text_next_to_the_region() {
        fn line(rect: Rect) -> TextLine {
            TextLine {
                rect,
                range: 0..0,
                text: String::new(),
                ink: Vec::new(),
            }
        }

        let caption = caption(Rect::new(100.0, 100.0, 200.0, 12.0));
        let images = [Rect::new(100.0, 150.0, 200.0, 300.0)];
        // A body-text line 2 pt above the artwork: the 4 pt edge has to stop at it.
        let above = [line(Rect::new(100.0, 452.0, 200.0, 10.0))];
        let region = caption_region_from(
            &caption,
            PageEvidence {
                images: &images,
                lines: &above,
                ..PageEvidence::default()
            },
            page_bounds(),
        );
        assert_eq!(
            region.max_y(),
            452.0,
            "the edge crossed a neighbouring line"
        );
        assert_eq!(region.origin.y, 96.0);

        // The same line inside the region does not hold it back: it is part of the figure.
        let inside = [line(Rect::new(100.0, 300.0, 200.0, 10.0))];
        let region = caption_region_from(
            &caption,
            PageEvidence {
                images: &images,
                lines: &inside,
                ..PageEvidence::default()
            },
            page_bounds(),
        );
        assert_eq!(region.max_y(), 454.0);
    }

    #[test]
    fn the_white_edge_grows_with_the_region_and_stops_at_the_cap() {
        let caption = caption(Rect::new(100.0, 100.0, 200.0, 12.0));
        // 400 × 500: 2 % of the shorter side is 8 pt.
        let big = [Rect::new(100.0, 150.0, 400.0, 450.0)];
        let region = caption_region(&caption, &big, page_bounds());
        assert_eq!(region.origin.x, 92.0);
        assert_eq!(region.origin.y, 92.0);
        // 600 × 720: 2 % of the shorter side is 12 pt, which is the cap.
        let huge = [Rect::new(6.0, 120.0, 600.0, 700.0)];
        let region = caption_region(&caption, &huge, page_bounds());
        assert_eq!(region.origin.y, 88.0);
        assert_eq!(region.max_y(), 832.0);
        assert_eq!(
            region.origin.x, 0.0,
            "the page's left edge holds the edge back"
        );
        // A full-page fallback has nothing to grow into.
        assert_eq!(caption_region(&caption, &[], page_bounds()), page_bounds());
    }

    #[test]
    fn the_white_edge_does_not_take_in_the_figure_beside_it() {
        let caption = caption(Rect::new(100.0, 100.0, 200.0, 12.0));
        let anchor = Rect::new(100.0, 150.0, 200.0, 300.0);
        // Another figure 3 pt to the right: the edge stops at its left border.
        let beside = Rect::new(303.0, 150.0, 200.0, 300.0);
        let region = caption_region(&caption, &[anchor, beside], page_bounds());
        assert_eq!(region.max_x(), 303.0);
        assert_eq!(region.origin.x, 96.0);
    }
}
