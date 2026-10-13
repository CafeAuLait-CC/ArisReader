//! Document layout: where every page sits in the scrolling content.
//!
//! This is deliberately platform-independent (`docs/adr/0001`'s anti-corruption layers):
//! the shell only ever asks "which pages are visible at this scroll offset" and draws
//! what it gets back. Page offsets are computed once, kept sorted, and queried with a
//! binary search, so a 2000-page manual costs the same as a two-page note
//! (`docs/02-architecture.md` §4.3).
//!
//! # Coordinate conventions
//!
//! Content space has its origin at the **top-left** of the first page, Y growing
//! downwards (view space, like AppKit). Pages are stacked vertically and centred
//! horizontally; [`DocumentLayout::content_width_pt`] is the widest page, so a document
//! that mixes A4 and A3 does not shift pages around as you scroll.

/// Where one page sits inside the scrolling content.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PagePlacement {
    pub index: u32,
    /// Y of the page's top edge in content space (points).
    pub top_pt: f64,
    /// X of the page's left edge, so different page widths stay centred.
    pub left_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
}

impl PagePlacement {
    pub fn bottom_pt(&self) -> f64 {
        self.top_pt + self.height_pt
    }

    /// Whether the page overlaps a viewport, with an optional margin (for prefetching).
    pub fn intersects(&self, viewport_top: f64, viewport_height: f64, margin_pt: f64) -> bool {
        let top = viewport_top - margin_pt;
        let bottom = viewport_top + viewport_height + margin_pt;
        self.bottom_pt() > top && self.top_pt < bottom
    }
}

/// Layout of a whole document at a given zoom.
///
/// The layout is computed for a *zoom-independent* point space: the shell multiplies by
/// the zoom when drawing. Rebuilding on zoom would only waste work.
#[derive(Debug, Clone, PartialEq)]
pub struct DocumentLayout {
    placements: Vec<PagePlacement>,
    gap_pt: f64,
    content_height_pt: f64,
    content_width_pt: f64,
}

impl DocumentLayout {
    /// Builds a layout from page sizes in points, top to bottom.
    pub fn new(page_sizes: impl IntoIterator<Item = (f64, f64)>, gap_pt: f64) -> Self {
        let gap = gap_pt.max(0.0);
        let sizes: Vec<(f64, f64)> = page_sizes.into_iter().collect();
        let content_width = sizes
            .iter()
            .map(|(width, _)| *width)
            .fold(0.0_f64, f64::max);

        let mut placements = Vec::with_capacity(sizes.len());
        let mut cursor = 0.0;
        for (index, (width, height)) in sizes.into_iter().enumerate() {
            placements.push(PagePlacement {
                index: index as u32,
                top_pt: cursor,
                left_pt: (content_width - width) / 2.0,
                width_pt: width,
                height_pt: height,
            });
            cursor += height + gap;
        }

        // The trailing gap is not part of the content.
        let content_height = if placements.is_empty() {
            0.0
        } else {
            (cursor - gap).max(0.0)
        };

        Self {
            placements,
            gap_pt: gap,
            content_height_pt: content_height,
            content_width_pt: content_width,
        }
    }

    pub fn page_count(&self) -> usize {
        self.placements.len()
    }

    pub fn gap_pt(&self) -> f64 {
        self.gap_pt
    }

    pub fn content_height_pt(&self) -> f64 {
        self.content_height_pt
    }

    pub fn content_width_pt(&self) -> f64 {
        self.content_width_pt
    }

    pub fn placement(&self, index: u32) -> Option<&PagePlacement> {
        self.placements.get(index as usize)
    }

    pub fn placements(&self) -> &[PagePlacement] {
        &self.placements
    }

    /// Top edge of a page (for "go to page" and for scroll anchoring).
    pub fn page_top_pt(&self, index: u32) -> Option<f64> {
        self.placement(index).map(|page| page.top_pt)
    }

    /// Pages overlapping the viewport, in reading order.
    ///
    /// `margin_pt` widens the window so callers can prefetch the next page; pass `0.0`
    /// for an exact answer.
    pub fn visible_pages(
        &self,
        viewport_top: f64,
        viewport_height: f64,
        margin_pt: f64,
    ) -> &[PagePlacement] {
        if self.placements.is_empty() {
            return &[];
        }

        // First page whose bottom edge is below the (expanded) viewport top. Placements
        // are sorted by `top_pt`, so a binary search replaces a linear scan.
        let top = viewport_top - margin_pt;
        let bottom = viewport_top + viewport_height + margin_pt;

        let mut low = 0usize;
        let mut high = self.placements.len();
        while low < high {
            let mid = (low + high) / 2;
            if self.placements[mid].bottom_pt() <= top {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        let start = low;

        let mut end = start;
        while end < self.placements.len() && self.placements[end].top_pt < bottom {
            end += 1;
        }

        &self.placements[start..end]
    }

    /// The page occupying most of the viewport top — the "current page" for the HUD.
    ///
    /// Ties go to the earlier page, which is what readers expect when a page boundary
    /// sits exactly at the top of the viewport.
    pub fn page_at(&self, viewport_top: f64) -> u32 {
        let mut current = 0;
        for page in &self.placements {
            if page.top_pt <= viewport_top {
                current = page.index;
            } else {
                break;
            }
        }
        current
    }

    /// Clamps a scroll offset to the valid range for a viewport of `viewport_height`.
    pub fn clamp_scroll(&self, offset: f64, viewport_height: f64) -> f64 {
        let max = (self.content_height_pt - viewport_height).max(0.0);
        offset.clamp(0.0, max)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Three A4 pages with the default 12 pt gap.
    fn three_pages() -> DocumentLayout {
        DocumentLayout::new([(595.0, 842.0); 3], 12.0)
    }

    #[test]
    fn pages_stack_with_a_gap_and_no_trailing_gap() {
        let layout = three_pages();
        assert_eq!(layout.page_count(), 3);
        assert_eq!(layout.page_top_pt(0), Some(0.0));
        assert_eq!(layout.page_top_pt(1), Some(854.0));
        assert_eq!(layout.page_top_pt(2), Some(1708.0));
        // 3 × 842 + 2 × 12
        assert_eq!(layout.content_height_pt(), 2550.0);
        assert_eq!(layout.content_width_pt(), 595.0);
        // max scroll keeps the last page's bottom at the viewport bottom
        assert_eq!(layout.clamp_scroll(9999.0, 800.0), 1750.0);
    }

    #[test]
    fn pages_of_different_widths_are_centred() {
        let layout = DocumentLayout::new([(595.0, 842.0), (842.0, 595.0)], 0.0);
        let wide = layout.placement(1).expect("second page");
        assert_eq!(layout.content_width_pt(), 842.0);
        assert_eq!(wide.left_pt, 0.0);
        let narrow = layout.placement(0).expect("first page");
        assert_eq!(narrow.left_pt, (842.0 - 595.0) / 2.0);
    }

    #[test]
    fn visible_pages_follows_the_scroll_offset() {
        let layout = three_pages();

        // Top of the document: only page 0.
        let visible = layout.visible_pages(0.0, 800.0, 0.0);
        assert_eq!(visible.len(), 1);
        assert_eq!(visible[0].index, 0);

        // Around the first gap: pages 0 and 1.
        let visible = layout.visible_pages(800.0, 200.0, 0.0);
        let indices: Vec<u32> = visible.iter().map(|page| page.index).collect();
        assert_eq!(indices, vec![0, 1]);

        // The margin widens the window for prefetching.
        let with_margin = layout.visible_pages(800.0, 200.0, 600.0);
        assert!(with_margin.len() >= 2);

        // Past the end: empty.
        assert!(layout.visible_pages(3000.0, 800.0, 0.0).is_empty());
    }

    #[test]
    fn page_at_reports_the_page_under_the_viewport_top() {
        let layout = three_pages();
        assert_eq!(layout.page_at(0.0), 0);
        assert_eq!(layout.page_at(841.0), 0);
        assert_eq!(
            layout.page_at(854.0),
            1,
            "the gap belongs to the page above"
        );
        assert_eq!(layout.page_at(1700.0), 1);
        assert_eq!(layout.page_at(1708.0), 2);
        assert_eq!(layout.page_at(9999.0), 2);
    }

    #[test]
    fn empty_document_is_harmless() {
        let layout = DocumentLayout::new([], 12.0);
        assert_eq!(layout.page_count(), 0);
        assert_eq!(layout.content_height_pt(), 0.0);
        assert!(layout.visible_pages(0.0, 800.0, 0.0).is_empty());
        assert_eq!(layout.page_at(100.0), 0);
        assert_eq!(layout.clamp_scroll(50.0, 800.0), 0.0);
    }
}
