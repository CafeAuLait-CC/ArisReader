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
//!
//! # Rows, not pages
//!
//! Continuous layout puts one page in each row, which makes "page" and "row" easy to
//! confuse. Facing layout puts two pages side by side in one row, so anything that
//! binary-searches *pages* by `top_pt` (or assumes their bottom edges are monotonic) is
//! wrong there. The layout therefore keeps an explicit [`Row`] index and every vertical
//! query (`visible_pages`, `page_at`) goes through it. The pages in one facing row share a
//! top edge and may have different heights; their bottoms are **not** monotonic, which is
//! exactly the assumption a per-page binary search cannot survive.

/// How pages are arranged horizontally.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum LayoutMode {
    /// One page per row, centred in the content width (the original reader layout).
    #[default]
    Continuous,
    /// Two pages side by side: page 1 alone (the cover/recto convention), then 2–3,
    /// 4–5, … with odd pages on the right. This is a *facing* layout, not a single-page
    /// layout: there is no mode here that shows one arbitrary page without its partner.
    Facing,
}

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

/// One horizontal band of the layout: a single page in continuous mode, or a facing pair
/// (the first row has the standalone cover).
#[derive(Clone, Copy, Debug, PartialEq)]
struct Row {
    top_pt: f64,
    bottom_pt: f64,
    /// Index into `placements` of the row's first page, inclusive.
    start: usize,
    /// Index one past the row's last page.
    end: usize,
}

/// Layout of a whole document at a given zoom.
///
/// The layout is computed for a *zoom-independent* point space: the shell multiplies by
/// the zoom when drawing. Rebuilding on zoom would only waste work.
#[derive(Debug, Clone, PartialEq)]
pub struct DocumentLayout {
    placements: Vec<PagePlacement>,
    rows: Vec<Row>,
    mode: LayoutMode,
    gap_pt: f64,
    content_height_pt: f64,
    content_width_pt: f64,
}

impl DocumentLayout {
    /// Builds a continuous layout from page sizes in points, top to bottom.
    pub fn new(page_sizes: impl IntoIterator<Item = (f64, f64)>, gap_pt: f64) -> Self {
        Self::new_with_mode(page_sizes, gap_pt, LayoutMode::Continuous)
    }

    /// Builds a layout from page sizes in points in the requested mode.
    pub fn new_with_mode(
        page_sizes: impl IntoIterator<Item = (f64, f64)>,
        gap_pt: f64,
        mode: LayoutMode,
    ) -> Self {
        let gap = gap_pt.max(0.0);
        let sizes: Vec<(f64, f64)> = page_sizes.into_iter().collect();
        let max_width = sizes
            .iter()
            .map(|(width, _)| *width)
            .fold(0.0_f64, f64::max);

        match mode {
            LayoutMode::Continuous => build_continuous(sizes, gap, max_width),
            LayoutMode::Facing if sizes.len() == 1 => {
                // A one-page document has no spread to show. Centring it in the single
                // column keeps it on screen at any zoom, instead of centring it in the
                // empty space where its partner would be. The mode stays `Facing`: the
                // caller asked for it, and `mode()` describes the request, not the pixels.
                let mut layout = build_continuous(sizes, gap, max_width);
                layout.mode = LayoutMode::Facing;
                layout
            }
            LayoutMode::Facing => build_facing(sizes, gap, max_width),
        }
    }

    pub fn page_count(&self) -> usize {
        self.placements.len()
    }

    pub fn gap_pt(&self) -> f64 {
        self.gap_pt
    }

    pub fn mode(&self) -> LayoutMode {
        self.mode
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
    ///
    /// The search is over **rows**, not pages: a facing row's pages can have different
    /// heights, so their bottom edges are not monotonic and a per-page binary search can
    /// skip a row entirely (see `facing_rows_with_different_heights_keep_both_pages`).
    pub fn visible_pages(
        &self,
        viewport_top: f64,
        viewport_height: f64,
        margin_pt: f64,
    ) -> &[PagePlacement] {
        if self.rows.is_empty() {
            return &[];
        }

        let top = viewport_top - margin_pt;
        let bottom = viewport_top + viewport_height + margin_pt;

        // First row whose bottom edge is below the (expanded) viewport top.
        let mut low = 0usize;
        let mut high = self.rows.len();
        while low < high {
            let mid = (low + high) / 2;
            if self.rows[mid].bottom_pt <= top {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        let start_row = low;
        let Some(first_row) = self.rows.get(start_row) else {
            return &[];
        };

        let mut end = first_row.end;
        for row in &self.rows[start_row..] {
            if row.top_pt >= bottom {
                break;
            }
            end = row.end;
        }

        &self.placements[first_row.start..end]
    }

    /// The page occupying most of the viewport top — the "current page" for the HUD.
    ///
    /// Ties go to the earlier page, which is what readers expect when a page boundary
    /// sits exactly at the top of the viewport. In facing mode the earlier page of a row
    /// is its **left** page: the viewport top names the spread, not whichever page of the
    /// pair happens to be drawn second.
    pub fn page_at(&self, viewport_top: f64) -> u32 {
        if self.rows.is_empty() {
            return 0;
        }
        // Last row whose top is at or above the viewport top.
        let mut low = 0usize;
        let mut high = self.rows.len();
        while low < high {
            let mid = (low + high) / 2;
            if self.rows[mid].top_pt <= viewport_top {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        let row = &self.rows[low.saturating_sub(1)];
        self.placements[row.start].index
    }

    /// Clamps a scroll offset to the valid range for a viewport of `viewport_height`.
    pub fn clamp_scroll(&self, offset: f64, viewport_height: f64) -> f64 {
        let max = (self.content_height_pt - viewport_height).max(0.0);
        offset.clamp(0.0, max)
    }
}

/// One centred page per row — the original M1 layout.
fn build_continuous(sizes: Vec<(f64, f64)>, gap: f64, content_width: f64) -> DocumentLayout {
    let mut placements = Vec::with_capacity(sizes.len());
    let mut rows = Vec::with_capacity(sizes.len());
    let mut cursor = 0.0;

    for (index, (width, height)) in sizes.into_iter().enumerate() {
        let row_start = placements.len();
        placements.push(PagePlacement {
            index: index as u32,
            top_pt: cursor,
            left_pt: (content_width - width) / 2.0,
            width_pt: width,
            height_pt: height,
        });
        rows.push(Row {
            top_pt: cursor,
            bottom_pt: cursor + height,
            start: row_start,
            end: row_start + 1,
        });
        cursor += height + gap;
    }

    let content_height = rows.last().map_or(0.0, |row| row.bottom_pt);
    DocumentLayout {
        placements,
        rows,
        mode: LayoutMode::Continuous,
        gap_pt: gap,
        content_height_pt: content_height,
        content_width_pt: content_width,
    }
}

/// Page 1 alone, then 2–3, 4–5, … with odd (1-based) pages on the right.
///
/// The cover is centred across the spread rather than pinned to the right slot: it is a
/// one-page row, and centring keeps it visible when the window is narrower than a spread.
/// Every later row uses the two slots. A document ending on an even page leaves that last
/// page alone in the left slot, which is the usual verso.
fn build_facing(sizes: Vec<(f64, f64)>, gap: f64, max_width: f64) -> DocumentLayout {
    let spread_width = 2.0 * max_width + gap;
    let mut placements = Vec::with_capacity(sizes.len());
    let mut rows = Vec::new();
    let mut cursor = 0.0;
    let mut index = 0usize;
    let len = sizes.len();

    while index < len {
        let row_start = placements.len();
        if index == 0 {
            let (width, height) = sizes[index];
            placements.push(PagePlacement {
                index: 0,
                top_pt: cursor,
                left_pt: (spread_width - width) / 2.0,
                width_pt: width,
                height_pt: height,
            });
            rows.push(Row {
                top_pt: cursor,
                bottom_pt: cursor + height,
                start: row_start,
                end: row_start + 1,
            });
            cursor += height + gap;
            index = 1;
            continue;
        }

        // `index` is the 0-based page number of a 1-based even page: it belongs on the
        // left, and its odd successor is the right page of the same spread.
        let (left_width, left_height) = sizes[index];
        let right = (index + 1 < len).then(|| sizes[index + 1]);
        let row_height = right.map_or(left_height, |(_, height)| left_height.max(height));
        let left_slot = 0.0;
        let right_slot = max_width + gap;

        placements.push(PagePlacement {
            index: index as u32,
            top_pt: cursor,
            left_pt: left_slot + (max_width - left_width) / 2.0,
            width_pt: left_width,
            height_pt: left_height,
        });
        let mut row_end = row_start + 1;
        if let Some((right_width, right_height)) = right {
            placements.push(PagePlacement {
                index: (index + 1) as u32,
                top_pt: cursor,
                left_pt: right_slot + (max_width - right_width) / 2.0,
                width_pt: right_width,
                height_pt: right_height,
            });
            row_end += 1;
        }
        rows.push(Row {
            top_pt: cursor,
            bottom_pt: cursor + row_height,
            start: row_start,
            end: row_end,
        });
        cursor += row_height + gap;
        index += 2;
    }

    let content_height = rows.last().map_or(0.0, |row| row.bottom_pt);
    DocumentLayout {
        placements,
        rows,
        mode: LayoutMode::Facing,
        gap_pt: gap,
        content_height_pt: content_height,
        content_width_pt: if len <= 1 { max_width } else { spread_width },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Three A4 pages with the default 12 pt gap.
    fn three_pages() -> DocumentLayout {
        DocumentLayout::new([(595.0, 842.0); 3], 12.0)
    }

    fn three_facing_pages() -> DocumentLayout {
        DocumentLayout::new_with_mode([(595.0, 842.0); 3], 12.0, LayoutMode::Facing)
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
    fn facing_puts_the_cover_alone_and_pairs_the_rest() {
        let layout = three_facing_pages();
        assert_eq!(layout.mode(), LayoutMode::Facing);
        assert_eq!(layout.content_width_pt(), 2.0 * 595.0 + 12.0);

        let cover = layout.placement(0).expect("cover");
        assert_eq!(cover.top_pt, 0.0);
        assert_eq!(
            cover.left_pt,
            (layout.content_width_pt() - 595.0) / 2.0,
            "the standalone cover is centred across the spread"
        );

        let left = layout.placement(1).expect("left page of the spread");
        let right = layout.placement(2).expect("right page of the spread");
        assert_eq!(
            left.top_pt, 854.0,
            "the spread starts below the cover and its gap"
        );
        assert_eq!(right.top_pt, left.top_pt);
        assert_eq!(left.left_pt, 0.0);
        assert_eq!(
            right.left_pt,
            595.0 + 12.0,
            "the right page is one page width plus the gap to the right"
        );
        assert_eq!(layout.content_height_pt(), 854.0 + 842.0);
        assert_eq!(layout.page_top_pt(1), layout.page_top_pt(2));
    }

    #[test]
    fn facing_page_at_names_the_left_page_of_the_spread() {
        let layout = three_facing_pages();
        assert_eq!(layout.page_at(0.0), 0);
        assert_eq!(
            layout.page_at(853.0),
            0,
            "the gap after the cover belongs to it"
        );
        assert_eq!(layout.page_at(854.0), 1);
        assert_eq!(
            layout.page_at(900.0),
            1,
            "the viewport top names the spread's left page, not the page drawn second"
        );
        assert_eq!(layout.page_at(1695.0), 1);
    }

    #[test]
    fn facing_visible_pages_returns_both_pages_of_a_row() {
        let layout = three_facing_pages();
        let visible = layout.visible_pages(854.0, 200.0, 0.0);
        let indices: Vec<u32> = visible.iter().map(|page| page.index).collect();
        assert_eq!(indices, vec![1, 2]);

        let cover_only = layout.visible_pages(0.0, 200.0, 0.0);
        assert_eq!(
            cover_only.iter().map(|page| page.index).collect::<Vec<_>>(),
            vec![0]
        );
    }

    /// The regression the row index exists for: a short right page makes the page bottoms
    /// go 1696, 1054 while the next page's top is still 1708. A binary search over page
    /// bottoms would decide the row at 1600 is already past and return nothing.
    #[test]
    fn facing_rows_with_different_heights_keep_both_pages() {
        let layout = DocumentLayout::new_with_mode(
            [
                (595.0, 842.0),
                (595.0, 842.0),
                (595.0, 200.0),
                (595.0, 842.0),
            ],
            12.0,
            LayoutMode::Facing,
        );
        let visible = layout.visible_pages(1500.0, 100.0, 0.0);
        let indices: Vec<u32> = visible.iter().map(|page| page.index).collect();
        assert_eq!(indices, vec![1, 2]);
        assert_eq!(layout.page_at(1500.0), 1);

        // The next row starts after the row's tallest page, not after the short one.
        assert_eq!(layout.page_top_pt(3), Some(854.0 + 842.0 + 12.0));
    }

    #[test]
    fn gap_changes_immediately_in_both_axes() {
        let tight = DocumentLayout::new_with_mode([(595.0, 842.0); 3], 0.0, LayoutMode::Facing);
        let roomy = DocumentLayout::new_with_mode([(595.0, 842.0); 3], 24.0, LayoutMode::Facing);
        assert_eq!(tight.page_top_pt(1), Some(842.0));
        assert_eq!(roomy.page_top_pt(1), Some(866.0));
        assert_eq!(tight.placement(2).expect("right page").left_pt, 595.0);
        assert_eq!(
            roomy.placement(2).expect("right page").left_pt,
            595.0 + 24.0
        );
        assert_eq!(roomy.content_height_pt(), 866.0 + 842.0);
    }

    #[test]
    fn facing_gap_is_clamped_to_non_negative() {
        let layout = DocumentLayout::new_with_mode([(595.0, 842.0); 3], -10.0, LayoutMode::Facing);
        assert_eq!(layout.gap_pt(), 0.0);
        assert_eq!(layout.placement(2).expect("right page").left_pt, 595.0);
    }

    #[test]
    fn a_single_page_in_facing_mode_is_a_single_centred_column() {
        let layout = DocumentLayout::new_with_mode([(595.0, 842.0)], 12.0, LayoutMode::Facing);
        assert_eq!(layout.content_width_pt(), 595.0);
        assert_eq!(layout.placement(0).expect("page").left_pt, 0.0);
        assert_eq!(layout.visible_pages(0.0, 800.0, 0.0).len(), 1);
    }

    #[test]
    fn empty_document_is_harmless() {
        let layout = DocumentLayout::new([], 12.0);
        assert_eq!(layout.page_count(), 0);
        assert_eq!(layout.content_height_pt(), 0.0);
        assert!(layout.visible_pages(0.0, 800.0, 0.0).is_empty());
        assert_eq!(layout.page_at(100.0), 0);
        assert_eq!(layout.clamp_scroll(50.0, 800.0), 0.0);

        let facing = DocumentLayout::new_with_mode([], 12.0, LayoutMode::Facing);
        assert_eq!(facing.page_count(), 0);
        assert_eq!(facing.content_width_pt(), 0.0);
        assert!(facing.visible_pages(0.0, 800.0, 0.0).is_empty());
    }
}
