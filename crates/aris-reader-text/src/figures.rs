//! Figure and table cross-references, and the page region a preview of one should show.
//!
//! Two different questions live here, and they are easy to conflate:
//!
//! * **Where does the body mention `Figure 3`?** — a text question, answered by
//!   [`find_caption_mentions`]. The answer is a click target, so it needs character boxes and
//!   nothing else.
//! * **What should the floating preview show for it?** — a geometry question about the caption
//!   and the artwork around it, answered by [`caption_region`]. The answer is a rectangle of the
//!   page, which the shell rasterizes.
//!
//! Keeping them apart is what lets the second one be measured: the corpus numbers reported for
//! `aris-reader-cli figures` are the regions the shell will actually show.

use aris_reader_core::{RawTextPage, Rect};

use crate::{Caption, union_boxes, union_rect};

/// Distance above a caption (points) within which an image object can be its artwork.
///
/// Measured on the corpus rather than guessed. A caption set under its own figure is 0–25 pt below
/// it (SMooDi Figures 1 and 3–7, HumanMM Figures 1–2, InstructAvatar Figures 1–6), while the
/// objects a page-wide window drags in sit 137–180 pt up: with 400 pt, `Fig. 7` on page 13 of the
/// SMooDi paper received `Fig. 6`'s artwork, and `Figure 11` on page 18 of the Ye paper received a
/// region covering the top two thirds of the page, figure above included. 60 pt keeps every
/// measured true pair and drops those. The price is a figure whose raster insets sit further from
/// its caption: it falls back to the caption-only region below.
const MAX_IMAGE_DISTANCE_PT: f64 = 60.0;

/// Padding added around a caption that has no image object to pair with.
const CAPTION_PADDING_PT: f64 = 6.0;

/// How close (points) another image object must be to join the figure being assembled.
///
/// About two body-text lines: the inset panels of SMooDi Figure 2 sit 21 pt apart, while the
/// artwork of a *different* figure is a caption line away (the 137 pt case above).
const PANEL_GAP_PT: f64 = 24.0;

/// Share of the narrower box that two boxes must overlap along an axis to count as related.
const MIN_OVERLAP_SHARE: f64 = 0.5;

/// A `Figure N` / `Fig. N` / `Table N` reference in the running text.
///
/// This is the click target, not the caption: see [`find_caption_mentions`] for exactly what is
/// and is not reported.
#[derive(Clone, Debug, PartialEq)]
pub struct CaptionMention {
    /// `Figure` or `Table` (the normalised spelling, as in [`Caption::kind`]).
    pub kind: String,
    /// The number as printed: `3`, `12`.
    pub label: String,
    /// Bounding box in **page space** (bottom-left origin).
    pub rect: Rect,
    /// Half-open character range inside the page's text layer.
    pub start: usize,
    pub end: usize,
}

/// Finds `Figure N` / `Fig. N` / `Table N` references **anywhere** in a page's text.
///
/// This is the prose half of the figure index, and the counterpart of [`crate::find_captions`]:
/// a caption is found by its *position* (the label opens a line), while a cross-reference in the
/// body has no position at all — `as Figure 3 shows` and `(see Fig. 3)` must both be found.
///
/// # What is reported, and what is left to `find_captions`
///
/// The two scanners partition the same pattern instead of overlapping on it: an occurrence that
/// opens a line **is** the caption, so it is not reported here. That is what makes the result
/// directly usable as click targets — a reader clicking the caption printed under the figure is
/// already looking at the figure. A caller that wants every occurrence can union the two results,
/// because an occurrence is reported by exactly one of them. (An occurrence *inside* a caption
/// line — `Figure 3: comparison with Figure 2` — is a mention of the other figure and is reported
/// as such.)
///
/// The vocabulary deliberately matches `find_captions` — `Figure`, `Fig.`, `Table`, then a plain
/// number — so that a mention and a caption agree on what `Figure 3` names. Plural forms
/// (`Figures 3 and 4`) and sub-numbers (`Fig. 3.1`) are not reported, because no caption carries
/// those labels either; a `3` followed by a letter (`Figure 3a`) is reported as label `3`.
pub fn find_caption_mentions(text: &RawTextPage) -> Vec<CaptionMention> {
    let chars: Vec<char> = text
        .chars
        .iter()
        .map(|character| char::from_u32(character.unicode).unwrap_or(char::REPLACEMENT_CHARACTER))
        .collect();

    let mut mentions = Vec::new();
    let mut line_start = 0usize;

    for (index, character) in chars.iter().enumerate() {
        if matches!(character, '\n' | '\r') {
            line_start = index + 1;
            continue;
        }
        // Whatever opens a line is a caption; see the doc comment.
        if chars[line_start..index]
            .iter()
            .all(|character| character.is_whitespace())
        {
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
/// The result is the union of the caption with everything found; with nothing found it is the
/// caption's box padded by [`CAPTION_PADDING_PT`], so a preview is still a readable snippet
/// rather than an empty rectangle.
///
/// # Limits, stated plainly
///
/// * **Vector figures and tables have no image object at all**, and the corpus contains plenty of
///   both: for them the result is the padded caption box, so the preview shows the caption rather
///   than the artwork. On the Ye paper, most figures are vector art and come back that way.
/// * **An image object's reported box is often a form's, not the picture's**, because PDFium
///   reports the enclosing form XObject's bounds (the core documents this in
///   `page_object_summary`). On page 18 of the Ye paper one such box spans two figures at once, so
///   no threshold can pair it with the right caption — the region falls back to the caption.
/// * **A table caption usually sits *above* its table**, the opposite of a figure caption, so the
///   same "look up" rule finds nothing in that style and the fallback applies. Where something
///   *does* sit just above such a caption it is the bottom of the figure above, and the table's
///   preview is that much wrong; growing a region *downwards* into a rule grid is the separate
///   table work.
/// * A caption that is itself an image (scanned pages) has no character boxes to begin with, so
///   it is never found here.
///
/// `page_height` is the page's vertical extent in page space (the crop box height). The result is
/// clamped to the page so that an image object reporting bounds larger than the page — form
/// XObjects routinely do — cannot push the preview off it.
pub fn caption_region(caption: &Caption, images: &[Rect], page_height: f64) -> Rect {
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
        Rect::new(
            caption.rect.origin.x - CAPTION_PADDING_PT,
            caption.rect.origin.y - CAPTION_PADDING_PT,
            caption.rect.size.width + 2.0 * CAPTION_PADDING_PT,
            caption.rect.size.height + 2.0 * CAPTION_PADDING_PT,
        )
    } else {
        included
            .iter()
            .fold(caption.rect, |region, image| union_rect(region, *image))
    };

    clamp_to_page(region, page_height)
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
fn overlaps_horizontally(a: Rect, b: Rect) -> bool {
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

fn area(rect: &Rect) -> f64 {
    rect.size.width * rect.size.height
}

/// Keeps a region inside `0..page_height` vertically; a no-op when the height is unknown.
fn clamp_to_page(region: Rect, page_height: f64) -> Rect {
    if page_height.is_nan() || page_height <= 0.0 {
        return region;
    }
    let bottom = region.origin.y.max(0.0);
    let top = region.max_y().min(page_height);
    if top <= bottom {
        return region;
    }
    Rect::new(region.origin.x, bottom, region.size.width, top - bottom)
}

#[cfg(test)]
mod figure_tests {
    use super::*;

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
        let region = caption_region(&caption, &[Rect::new(100.0, 150.0, 200.0, 300.0)], 842.0);
        assert_eq!(region, Rect::new(100.0, 100.0, 200.0, 350.0));
    }

    #[test]
    fn objects_beyond_the_caption_reach_are_not_its_figure() {
        let caption = caption(Rect::new(100.0, 100.0, 200.0, 12.0)); // top edge at 112
        // 61 pt above that edge: outside the measured caption-to-artwork distance.
        assert_eq!(
            caption_region(&caption, &[Rect::new(100.0, 173.0, 200.0, 40.0)], 842.0),
            Rect::new(94.0, 94.0, 212.0, 24.0)
        );
        // Exactly at the limit, and the image is this caption's artwork.
        assert_eq!(
            caption_region(&caption, &[Rect::new(100.0, 172.0, 200.0, 40.0)], 842.0),
            Rect::new(100.0, 100.0, 200.0, 112.0)
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
            caption_region(&caption, &[lower, upper], 842.0),
            Rect::new(100.0, 100.0, 200.0, 90.0)
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
            caption_region(&caption, &images, 842.0),
            Rect::new(100.0, 100.0, 200.0, 20.0)
        );
    }

    #[test]
    fn an_image_across_the_gutter_is_never_a_candidate() {
        let caption = caption(Rect::new(100.0, 100.0, 200.0, 12.0));
        let anchor = Rect::new(100.0, 130.0, 200.0, 40.0);
        // Same height, but it does not overlap the caption at all, so it is never a candidate.
        let beside = Rect::new(330.0, 130.0, 200.0, 40.0);
        assert_eq!(
            caption_region(&caption, &[anchor, beside], 842.0),
            Rect::new(100.0, 100.0, 200.0, 70.0)
        );
    }

    #[test]
    fn a_far_or_sideways_image_is_not_the_figure() {
        let caption = caption(Rect::new(100.0, 100.0, 200.0, 12.0));
        let padded = Rect::new(94.0, 94.0, 212.0, 24.0);

        // 500 pt above: another figure's artwork, not this one's.
        assert_eq!(
            caption_region(&caption, &[Rect::new(100.0, 620.0, 200.0, 100.0)], 842.0),
            padded
        );
        // Directly above, but in the other column.
        assert_eq!(
            caption_region(&caption, &[Rect::new(400.0, 150.0, 200.0, 300.0)], 842.0),
            padded
        );
        // Above and just overlapping (50 pt of a 200 pt caption): not the same figure.
        assert_eq!(
            caption_region(&caption, &[Rect::new(250.0, 150.0, 200.0, 300.0)], 842.0),
            padded
        );
        // Degenerate boxes (whitespace glyphs, clipped objects) are not candidates either.
        assert_eq!(
            caption_region(&caption, &[Rect::new(100.0, 150.0, 0.0, 300.0)], 842.0),
            padded
        );
    }

    #[test]
    fn no_image_leaves_the_caption_padded_and_not_empty() {
        let caption = caption(Rect::new(100.0, 100.0, 200.0, 12.0));
        let region = caption_region(&caption, &[], 842.0);
        assert_eq!(region, Rect::new(94.0, 94.0, 212.0, 24.0));
        assert!(region.size.width > caption.rect.size.width);
        assert!(region.size.height > caption.rect.size.height);
    }

    #[test]
    fn the_region_stays_inside_the_page() {
        // A form XObject can report bounds taller than the page; the preview must not follow
        // the object off the page.
        let caption = caption(Rect::new(100.0, 700.0, 200.0, 12.0));
        let region = caption_region(&caption, &[Rect::new(100.0, 720.0, 200.0, 400.0)], 842.0);
        assert_eq!(region.max_y(), 842.0);
        assert_eq!(region.origin.y, 700.0);
        assert_eq!(region.size.height, 142.0);

        // Without a known page height the region is passed through untouched.
        let unclamped = caption_region(&caption, &[Rect::new(100.0, 720.0, 200.0, 400.0)], 0.0);
        assert_eq!(unclamped.max_y(), 1120.0);
    }
}
