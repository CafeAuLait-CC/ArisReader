//! Coordinate systems and affine transforms.
//!
//! Three coordinate spaces (see `docs/03-rendering.md` §1):
//!
//! | Space | Origin | Y direction | Unit |
//! | --- | --- | --- | --- |
//! | **Page Space** | `CropBox` bottom-left | up | 1/72 in |
//! | **View Space** | scrolled content top-left | down | pt |
//! | **Device Space** | viewport top-left | down | px = View × `backingScale` |
//!
//! **Hard rule: the only Y flip happens in [`PageGeometry::page_to_view`]**.
//! Flipping anywhere else produces "upside-down" or "hit-test offset" bugs.

/// 2D point. The semantics (Page/View/Device) are determined by the context of use.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

impl Point {
    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }
}

/// Size (width and height; always non-negative by convention).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Size {
    pub width: f64,
    pub height: f64,
}

impl Size {
    pub const fn new(width: f64, height: f64) -> Self {
        Self { width, height }
    }

    pub fn is_empty(self) -> bool {
        self.width <= 0.0 || self.height <= 0.0
    }
}

/// Axis-aligned rectangle (both View and Page space use a top-left + size representation).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub origin: Point,
    pub size: Size,
}

impl Rect {
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self {
            origin: Point::new(x, y),
            size: Size::new(width, height),
        }
    }

    /// Constructed from left/top/right/bottom (the order used by PDF's `FS_RECTF`).
    pub fn from_ltrb(left: f64, top: f64, right: f64, bottom: f64) -> Self {
        Self::new(left, top, right - left, bottom - top)
    }

    pub fn min_x(self) -> f64 {
        self.origin.x
    }

    pub fn min_y(self) -> f64 {
        self.origin.y
    }

    pub fn max_x(self) -> f64 {
        self.origin.x + self.size.width
    }

    pub fn max_y(self) -> f64 {
        self.origin.y + self.size.height
    }

    pub fn center(self) -> Point {
        Point::new(
            self.origin.x + self.size.width * 0.5,
            self.origin.y + self.size.height * 0.5,
        )
    }

    pub fn is_empty(self) -> bool {
        self.size.is_empty()
    }

    pub fn contains(self, p: Point) -> bool {
        p.x >= self.min_x() && p.x <= self.max_x() && p.y >= self.min_y() && p.y <= self.max_y()
    }

    pub fn translated(self, dx: f64, dy: f64) -> Self {
        Self::new(
            self.origin.x + dx,
            self.origin.y + dy,
            self.size.width,
            self.size.height,
        )
    }

    pub fn inset(self, dx: f64, dy: f64) -> Self {
        Self::new(
            self.origin.x + dx,
            self.origin.y + dy,
            (self.size.width - 2.0 * dx).max(0.0),
            (self.size.height - 2.0 * dy).max(0.0),
        )
    }

    /// Intersection; returns `None` when there is no overlap.
    pub fn intersection(self, other: Self) -> Option<Self> {
        let min_x = self.min_x().max(other.min_x());
        let min_y = self.min_y().max(other.min_y());
        let max_x = self.max_x().min(other.max_x());
        let max_y = self.max_y().min(other.max_y());
        if max_x <= min_x || max_y <= min_y {
            None
        } else {
            Some(Self::new(min_x, min_y, max_x - min_x, max_y - min_y))
        }
    }

    /// Smallest enclosing rectangle.
    pub fn union(self, other: Self) -> Self {
        let min_x = self.min_x().min(other.min_x());
        let min_y = self.min_y().min(other.min_y());
        let max_x = self.max_x().max(other.max_x());
        let max_y = self.max_y().max(other.max_y());
        Self::new(min_x, min_y, max_x - min_x, max_y - min_y)
    }
}

/// 2D affine transform; memory layout matches `CGAffineTransform` (column-major):
///
/// ```text
/// | a  c  tx |     x' = a·x + c·y + tx
/// | b  d  ty |     y' = b·x + d·y + ty
/// | 0  0  1  |
/// ```
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Transform2D {
    pub a: f64,
    pub b: f64,
    pub c: f64,
    pub d: f64,
    pub tx: f64,
    pub ty: f64,
}

impl Default for Transform2D {
    fn default() -> Self {
        Self::IDENTITY
    }
}

impl Transform2D {
    pub const IDENTITY: Self = Self {
        a: 1.0,
        b: 0.0,
        c: 0.0,
        d: 1.0,
        tx: 0.0,
        ty: 0.0,
    };

    pub const fn new(a: f64, b: f64, c: f64, d: f64, tx: f64, ty: f64) -> Self {
        Self { a, b, c, d, tx, ty }
    }

    pub const fn translate(tx: f64, ty: f64) -> Self {
        Self::new(1.0, 0.0, 0.0, 1.0, tx, ty)
    }

    pub const fn scale(sx: f64, sy: f64) -> Self {
        Self::new(sx, 0.0, 0.0, sy, 0.0, 0.0)
    }

    /// Counter-clockwise rotation (positive mathematical direction; PDF user space has Y up, so this matches the visual direction).
    pub fn rotate(radians: f64) -> Self {
        let (s, c) = radians.sin_cos();
        Self::new(c, s, -s, c, 0.0, 0.0)
    }

    /// Composition: **apply `self` first, then `other`** (equivalent to `CGAffineTransformConcat(self, other)`).
    pub fn then(self, other: Self) -> Self {
        Self {
            a: other.a * self.a + other.c * self.b,
            b: other.b * self.a + other.d * self.b,
            c: other.a * self.c + other.c * self.d,
            d: other.b * self.c + other.d * self.d,
            tx: other.a * self.tx + other.c * self.ty + other.tx,
            ty: other.b * self.tx + other.d * self.ty + other.ty,
        }
    }

    pub fn apply(self, p: Point) -> Point {
        Point::new(
            self.a * p.x + self.c * p.y + self.tx,
            self.b * p.x + self.d * p.y + self.ty,
        )
    }

    /// Bounding rectangle after the transform (a conservative bounding box for rotation/shear).
    pub fn apply_rect(self, r: Rect) -> Rect {
        let corners = [
            self.apply(Point::new(r.min_x(), r.min_y())),
            self.apply(Point::new(r.max_x(), r.min_y())),
            self.apply(Point::new(r.max_x(), r.max_y())),
            self.apply(Point::new(r.min_x(), r.max_y())),
        ];
        let mut min_x = corners[0].x;
        let mut max_x = corners[0].x;
        let mut min_y = corners[0].y;
        let mut max_y = corners[0].y;
        for p in &corners[1..] {
            min_x = min_x.min(p.x);
            max_x = max_x.max(p.x);
            min_y = min_y.min(p.y);
            max_y = max_y.max(p.y);
        }
        Rect::new(min_x, min_y, max_x - min_x, max_y - min_y)
    }

    pub fn determinant(self) -> f64 {
        self.a * self.d - self.b * self.c
    }

    /// Inverse transform; returns `None` for a degenerate matrix (determinant ≈ 0).
    pub fn inverse(self) -> Option<Self> {
        let det = self.determinant();
        if det.abs() < 1e-12 {
            return None;
        }
        Some(Self {
            a: self.d / det,
            b: -self.b / det,
            c: -self.c / det,
            d: self.a / det,
            tx: (self.c * self.ty - self.d * self.tx) / det,
            ty: (self.b * self.tx - self.a * self.ty) / det,
        })
    }
}

/// Page `/Rotate` value (PDF allows only 0/90/180/270, denoting a **clockwise** display rotation).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Rotation {
    #[default]
    None,
    Clockwise90,
    Clockwise180,
    Clockwise270,
}

impl Rotation {
    /// Normalizes any angle (including negative values) to a valid rotation.
    pub fn from_degrees(degrees: i32) -> Self {
        match degrees.rem_euclid(360) {
            90 => Self::Clockwise90,
            180 => Self::Clockwise180,
            270 => Self::Clockwise270,
            _ => Self::None,
        }
    }

    pub fn degrees(self) -> i32 {
        match self {
            Self::None => 0,
            Self::Clockwise90 => 90,
            Self::Clockwise180 => 180,
            Self::Clockwise270 => 270,
        }
    }

    /// Whether the rotation swaps width and height.
    pub fn swaps_axes(self) -> bool {
        matches!(self, Self::Clockwise90 | Self::Clockwise270)
    }

    /// Rotation matrix in Page Space (visual clockwise = the negative of the mathematical counter-clockwise angle).
    fn page_transform(self) -> Transform2D {
        Transform2D::rotate(-(self.degrees() as f64).to_radians())
    }
}

/// Page geometry: PDF page boxes, rotation, `UserUnit`, and the transform to View Space.
///
/// TODO(T1.1): add unit tests (corner mapping, axis swap under rotation, round-trip consistency).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PageGeometry {
    /// `/MediaBox` (PDF user space)
    pub media_box: Rect,
    /// `/CropBox` (visible area; the origin is often not 0,0)
    pub crop_box: Rect,
    pub rotation: Rotation,
    /// `/UserUnit` (default 1.0; greater than 1 means the page is defined in larger user units)
    pub user_unit: f64,
}

impl PageGeometry {
    pub fn new(media_box: Rect, crop_box: Rect, rotation: Rotation, user_unit: f64) -> Self {
        Self {
            media_box,
            crop_box,
            rotation,
            user_unit: if user_unit > 0.0 { user_unit } else { 1.0 },
        }
    }

    /// Transform from Page Space to View Space (already includes the **only Y flip**).
    ///
    /// `zoom` is the scale factor relative to 100% (1 PDF pt = 1 pt); `backing_scale` does not
    /// participate in this transform — it is handled separately by the View → Device scaling.
    ///
    /// Steps (in application order):
    /// 1. translate the `CropBox` origin to (0,0) (the CropBox origin is often not 0,0);
    /// 2. scale by `zoom × UserUnit`;
    /// 3. rotate by `/Rotate` (after rotation the bounding box origin may be negative and needs normalization);
    /// 4. normalize to (0,0);
    /// 5. flip Y (view height = rotated height), because PDF's Y axis points up while View Space points down.
    pub fn page_to_view(&self, zoom: f64) -> Transform2D {
        let b = self.crop_box;
        let s = zoom * self.user_unit;

        let translate = Transform2D::translate(-b.origin.x, -b.origin.y);
        let scale = Transform2D::scale(s, s);
        let rotate = self.rotation.page_transform();

        // Rotated bounding box (keeps the page top-left at the View Space origin)
        let rotated = rotate.apply_rect(Rect::new(0.0, 0.0, b.size.width * s, b.size.height * s));
        let normalize = Transform2D::translate(-rotated.min_x(), -rotated.min_y());
        // Mirror first, then translate: y' = height - y
        let flip =
            Transform2D::scale(1.0, -1.0).then(Transform2D::translate(0.0, rotated.size.height));

        translate
            .then(scale)
            .then(rotate)
            .then(normalize)
            .then(flip)
    }

    /// Page size in View Space (pt), accounting for rotation and `UserUnit`.
    pub fn view_size(&self, zoom: f64) -> Size {
        self.page_to_view(zoom).apply_rect(self.crop_box).size
    }

    pub fn view_to_page(&self, zoom: f64) -> Option<Transform2D> {
        self.page_to_view(zoom).inverse()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const EPS: f64 = 1e-6;

    fn approx(a: f64, b: f64) -> bool {
        (a - b).abs() < EPS
    }

    fn a4() -> PageGeometry {
        // A4: 595 × 842 pt, no rotation, no UserUnit
        PageGeometry::new(
            Rect::new(0.0, 0.0, 595.0, 842.0),
            Rect::new(0.0, 0.0, 595.0, 842.0),
            Rotation::None,
            1.0,
        )
    }

    #[test]
    fn identity_transform_roundtrip() {
        let t = Transform2D::translate(10.0, -4.0).then(Transform2D::scale(2.0, 3.0));
        let p = Point::new(1.5, -2.0);
        let back = t.inverse().expect("invertible").apply(t.apply(p));
        assert!(approx(back.x, p.x) && approx(back.y, p.y));
    }

    #[test]
    fn single_y_flip_page_to_view() {
        let g = a4();
        let t = g.page_to_view(1.0);
        // PDF bottom-left corner (0,0) → View Space bottom-left corner (0, height)
        let bl = t.apply(Point::new(0.0, 0.0));
        assert!(approx(bl.x, 0.0) && approx(bl.y, 842.0), "got {bl:?}");
        // PDF top-left corner (0,842) → View Space origin (0,0)
        let tl = t.apply(Point::new(0.0, 842.0));
        assert!(approx(tl.x, 0.0) && approx(tl.y, 0.0), "got {tl:?}");
    }

    #[test]
    fn zoom_scales_view_size() {
        let g = a4();
        assert_eq!(g.view_size(1.0), Size::new(595.0, 842.0));
        assert_eq!(g.view_size(2.0), Size::new(1190.0, 1684.0));
    }

    #[test]
    fn rotation_swaps_axes() {
        let mut g = a4();
        g.rotation = Rotation::Clockwise90;
        let s = g.view_size(1.0);
        assert!(
            approx(s.width, 842.0) && approx(s.height, 595.0),
            "got {s:?}"
        );

        // After rotation the page top-left is still at the View Space origin (no offset introduced)
        let tl = g.page_to_view(1.0).apply_rect(g.crop_box);
        assert!(
            approx(tl.min_x(), 0.0) && approx(tl.min_y(), 0.0),
            "got {tl:?}"
        );
    }

    #[test]
    fn crop_box_origin_is_absorbed() {
        let g = PageGeometry::new(
            Rect::new(0.0, 0.0, 612.0, 792.0),
            Rect::new(10.0, 20.0, 400.0, 500.0), // CropBox origin is non-zero
            Rotation::None,
            1.0,
        );
        let t = g.page_to_view(1.0);
        let bl = t.apply(Point::new(10.0, 20.0)); // CropBox bottom-left
        assert!(approx(bl.x, 0.0) && approx(bl.y, 500.0), "got {bl:?}");
        assert_eq!(g.view_size(1.0), Size::new(400.0, 500.0));
    }

    #[test]
    fn rotation_normalizes_arbitrary_degrees() {
        assert_eq!(Rotation::from_degrees(450), Rotation::Clockwise90);
        assert_eq!(Rotation::from_degrees(-90), Rotation::Clockwise270);
        assert_eq!(Rotation::from_degrees(360), Rotation::None);
    }
}
