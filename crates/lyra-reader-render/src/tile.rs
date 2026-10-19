//! Tile pyramid: LOD selection, tile keys, visible tile enumeration.

use lyra_reader_core::{DocId, PageIndex, Rect, Size};

/// Tile pyramid level: level n rasterizes at `2^n` (relative to the PDF 72 dpi baseline).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Lod(pub u8);

impl Lod {
    pub const ZERO: Self = Self(0);

    /// Rasterization scale of this level (1.0 = 72 dpi).
    pub fn scale(self) -> f64 {
        // The LOD cap of 16 is far beyond any practical need (2^16 = 65536x) and keeps the shift from overflowing.
        (1u64 << self.0.min(16)) as f64
    }

    /// Lowest level that covers the given scale: `ceil(log2(scale))`, with a floor of 0.
    pub fn for_scale(required_scale: f64) -> Self {
        if required_scale.is_nan() || required_scale <= 0.0 {
            return Self::ZERO;
        }
        let l = required_scale.log2().ceil();
        if l <= 0.0 {
            Self::ZERO
        } else {
            Self((l as u32).min(16) as u8)
        }
    }

    pub fn next(self) -> Self {
        Self(self.0.saturating_add(1).min(16))
    }

    pub fn prev(self) -> Self {
        Self(self.0.saturating_sub(1))
    }
}

/// Upgrade threshold: raise the LOD only when the required scale exceeds the current level's scale by 15% (avoids oscillation at the boundary).
pub const LOD_UPGRADE_FACTOR: f64 = 1.15;
/// Downgrade threshold: lower the LOD only when the required scale falls below 60% of the current level's scale.
pub const LOD_DOWNGRADE_FACTOR: f64 = 0.6;

/// LOD selection with hysteresis (`docs/03-rendering.md` §3).
pub fn select_lod(required_scale: f64, current: Lod, max_lod: Lod) -> Lod {
    let target = Lod::for_scale(required_scale).min(max_lod);
    if target > current {
        if required_scale > current.scale() * LOD_UPGRADE_FACTOR {
            target
        } else {
            current
        }
    } else if target < current {
        if required_scale < current.scale() * LOD_DOWNGRADE_FACTOR {
            target
        } else {
            current
        }
    } else {
        current
    }
}

/// Temporary downgrade during gestures (pinch/fast scroll): one level normally, two levels when fast.
pub fn gesture_lod(target: Lod, fast: bool) -> Lod {
    let steps = if fast { 2 } else { 1 };
    Lod(target.0.saturating_sub(steps))
}

/// Unique key of a tile cache entry.
///
/// `content_epoch` is incremented after the document is edited (annotations/page operations), which naturally invalidates stale tiles.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct TileKey {
    pub doc: DocId,
    pub page: PageIndex,
    pub lod: Lod,
    pub col: u32,
    pub row: u32,
    pub content_epoch: u32,
}

impl TileKey {
    pub fn new(
        doc: DocId,
        page: PageIndex,
        lod: Lod,
        col: u32,
        row: u32,
        content_epoch: u32,
    ) -> Self {
        Self {
            doc,
            page,
            lod,
            col,
            row,
            content_epoch,
        }
    }
}

/// Task priority (lower values run first, `docs/03-rendering.md` §4).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum RenderPriority {
    /// Currently visible tiles at the target LOD.
    Visible = 0,
    /// Currently visible tiles one LOD lower (scroll preview).
    VisibleLowerLod = 1,
    /// Prefetch one screen beyond the viewport, and floating-preview target regions.
    Prefetch = 2,
    /// Thumbnails.
    Thumbnail = 3,
    /// Background full-page prerendering.
    Background = 4,
}

/// A single rasterization task.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RenderRequest {
    pub key: TileKey,
    pub priority: RenderPriority,
    /// Target region (Page Space); `None` means the whole page (full-page rendering mode).
    pub region: Option<Rect>,
    pub scale: f64,
}

/// Tile column and row counts needed for the page at the given scale.
pub fn tile_dims(page_px: Size, tile_size: u32) -> (u32, u32) {
    let t = tile_size.max(1) as f64;
    let cols = (page_px.width / t).ceil().max(1.0) as u32;
    let rows = (page_px.height / t).ceil().max(1.0) as u32;
    (cols, rows)
}

/// Tile coordinates intersecting the given viewport (the viewport is a rectangle in Device Space relative to the page's top-left corner).
pub fn visible_tiles(page_px: Size, tile_size: u32, viewport: Rect) -> Vec<(u32, u32)> {
    let (cols, rows) = tile_dims(page_px, tile_size);
    let t = tile_size.max(1) as f64;

    let c0 = (viewport.min_x() / t).floor().clamp(0.0, cols as f64) as u32;
    let c1 = (viewport.max_x() / t).ceil().clamp(0.0, cols as f64) as u32;
    let r0 = (viewport.min_y() / t).floor().clamp(0.0, rows as f64) as u32;
    let r1 = (viewport.max_y() / t).ceil().clamp(0.0, rows as f64) as u32;

    let mut out = Vec::new();
    for row in r0..r1 {
        for col in c0..c1 {
            out.push((col, row));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lod_for_scale_rounds_up() {
        assert_eq!(Lod::for_scale(0.5), Lod::ZERO);
        assert_eq!(Lod::for_scale(1.0), Lod::ZERO);
        assert_eq!(Lod::for_scale(1.5), Lod(1));
        assert_eq!(Lod::for_scale(2.0), Lod(1));
        assert_eq!(Lod::for_scale(2.5), Lod(2));
        assert_eq!(Lod::for_scale(0.0), Lod::ZERO);
        assert_eq!(Lod(2).scale(), 4.0);
    }

    #[test]
    fn lod_selection_has_hysteresis() {
        let max = Lod(4);
        // current LOD 0 (scale 1.0); a required scale of 1.1 is not enough to upgrade (threshold 1.15)
        assert_eq!(select_lod(1.1, Lod::ZERO, max), Lod::ZERO);
        // a required scale of 1.2 exceeds the threshold → upgrade to LOD 1
        assert_eq!(select_lod(1.2, Lod::ZERO, max), Lod(1));
        // current LOD 2 (scale 4.0); a required scale of 2.6 is above the downgrade threshold (4.0*0.6 = 2.4) → keep
        assert_eq!(select_lod(2.6, Lod(2), max), Lod(2));
        // a required scale of 2.0 is below the threshold → downgrade
        assert_eq!(select_lod(2.0, Lod(2), max), Lod(1));
        // max_lod clamp
        assert_eq!(select_lod(64.0, Lod(2), Lod(3)), Lod(3));
    }

    #[test]
    fn gesture_lowers_lod() {
        assert_eq!(gesture_lod(Lod(3), false), Lod(2));
        assert_eq!(gesture_lod(Lod(3), true), Lod(1));
        assert_eq!(gesture_lod(Lod::ZERO, true), Lod::ZERO);
    }

    #[test]
    fn tile_dims_covers_page() {
        // A4 @2x ≈ 1190×1684 px, 512 px tiles → 3 columns × 4 rows
        assert_eq!(tile_dims(Size::new(1190.0, 1684.0), 512), (3, 4));
        assert_eq!(tile_dims(Size::new(0.0, 0.0), 512), (1, 1));
    }

    #[test]
    fn visible_tiles_clamps_to_page() {
        let page = Size::new(1190.0, 1684.0);
        let all = visible_tiles(page, 512, Rect::new(0.0, 0.0, 1190.0, 1684.0));
        assert_eq!(all.len(), 12);
        // only the top-left tile is visible
        let one = visible_tiles(page, 512, Rect::new(0.0, 0.0, 10.0, 10.0));
        assert_eq!(one, vec![(0, 0)]);
        // a viewport beyond the page produces no out-of-range tiles
        let overflow = visible_tiles(page, 512, Rect::new(-500.0, -500.0, 3000.0, 3000.0));
        assert_eq!(overflow.len(), 12);
    }
}
