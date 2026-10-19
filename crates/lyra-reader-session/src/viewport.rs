//! Viewport and zoom math.
//!
//! Zoom anchoring rules (`docs/04-ui-ux.md` §3):
//!
//! 1. Pinch zoom: **the page point under the cursor stays fixed**;
//! 2. Keyboard zoom: the viewport center stays fixed;
//! 3. Fit width + window resize: the topmost visible page and the relative position within that page stay fixed.

use crate::command::{Layout, Zoom};
use lyra_reader_core::{Point, Rect, Size};

/// Zoom limits (prevent division by zero and pointlessly huge textures).
pub const MIN_ZOOM: f64 = 0.05;
pub const MAX_ZOOM: f64 = 20.0;

/// Viewport state (the source of truth is the engine; the host is only a controlled view).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Viewport {
    /// Position of the scrolled content's top-left corner in View Space.
    pub scroll: Point,
    /// Viewport size (pt).
    pub view_size: Size,
    /// Zoom mode requested by the user.
    pub zoom: Zoom,
    /// Resolved effective zoom factor (computed by [`resolve_zoom`]).
    pub zoom_factor: f64,
    pub layout: Layout,
    /// Screen scale (Retina = 2.0).
    pub backing_scale: f64,
    /// Page gap (pt).
    pub page_gap: f64,
}

impl Default for Viewport {
    fn default() -> Self {
        Self {
            scroll: Point::new(0.0, 0.0),
            view_size: Size::new(1024.0, 768.0),
            zoom: Zoom::default(),
            zoom_factor: 1.0,
            layout: Layout::default(),
            backing_scale: 2.0,
            page_gap: 12.0,
        }
    }
}

impl Viewport {
    /// Viewport rectangle (View Space).
    pub fn visible_rect(&self) -> Rect {
        Rect::new(
            self.scroll.x,
            self.scroll.y,
            self.view_size.width,
            self.view_size.height,
        )
    }

    /// Scale required for rasterization: device pixels / PDF pt (= zoom × backingScale).
    pub fn device_scale(&self) -> f64 {
        self.zoom_factor * self.backing_scale
    }
}

/// Resolve [`Zoom`] into a concrete factor.
///
/// `page` is the page size in View Space (at zoom 1.0), `viewport` is the viewport size.
pub fn resolve_zoom(zoom: Zoom, page: Size, viewport: Size, gap: f64) -> f64 {
    let raw = match zoom {
        Zoom::Factor(f) => f,
        Zoom::Actual => 1.0,
        Zoom::FitWidth => {
            if page.width > 0.0 {
                (viewport.width - 2.0 * gap) / page.width
            } else {
                1.0
            }
        }
        Zoom::FitHeight => {
            if page.height > 0.0 {
                (viewport.height - 2.0 * gap) / page.height
            } else {
                1.0
            }
        }
        Zoom::FitPage => {
            let by_w = if page.width > 0.0 {
                (viewport.width - 2.0 * gap) / page.width
            } else {
                1.0
            };
            let by_h = if page.height > 0.0 {
                (viewport.height - 2.0 * gap) / page.height
            } else {
                1.0
            };
            by_w.min(by_h)
        }
    };
    raw.clamp(MIN_ZOOM, MAX_ZOOM)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn a4() -> Size {
        Size::new(595.0, 842.0)
    }

    #[test]
    fn factor_and_actual_are_identity() {
        assert!(
            (resolve_zoom(Zoom::Factor(1.75), a4(), Size::new(1000.0, 800.0), 12.0) - 1.75).abs()
                < 1e-9
        );
        assert!(
            (resolve_zoom(Zoom::Actual, a4(), Size::new(1000.0, 800.0), 12.0) - 1.0).abs() < 1e-9
        );
    }

    #[test]
    fn fit_width_uses_viewport_width() {
        let z = resolve_zoom(Zoom::FitWidth, a4(), Size::new(1000.0, 800.0), 12.0);
        assert!((z - (1000.0 - 24.0) / 595.0).abs() < 1e-9);
    }

    #[test]
    fn fit_page_takes_the_smaller_axis() {
        let z = resolve_zoom(Zoom::FitPage, a4(), Size::new(1000.0, 800.0), 12.0);
        let by_w = (1000.0f64 - 24.0) / 595.0;
        let by_h = (800.0f64 - 24.0) / 842.0;
        assert!((z - by_w.min(by_h)).abs() < 1e-9);
    }

    #[test]
    fn zoom_is_clamped() {
        assert_eq!(
            resolve_zoom(Zoom::Factor(1000.0), a4(), Size::new(1000.0, 800.0), 12.0),
            MAX_ZOOM
        );
        assert_eq!(
            resolve_zoom(Zoom::Factor(0.0), a4(), Size::new(1000.0, 800.0), 12.0),
            MIN_ZOOM
        );
    }

    #[test]
    fn device_scale_multiplies_backing_scale() {
        let v = Viewport {
            zoom_factor: 1.5,
            backing_scale: 2.0,
            ..Viewport::default()
        };
        assert!((v.device_scale() - 3.0).abs() < 1e-9);
    }
}
