//! The real PDFium-backed [`DocumentBackend`] implementation.
//!
//! See the crate-level docs for the task map, threading rules and library search
//! order. Everything in this module is compiled only with `feature = "pdfium"`.

use aris_reader_core::{
    ArisError, DocumentBackend, ErrorCode, LinkInfo, OutlineNode, PageGeometry, PageIndex,
    PageInfo, RasterFormat, RasterRequest, RasterTile, RawTextPage, Rect, Result, Rotation, Size,
};
use pdfium_render::prelude::*;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// Process-wide PDFium facade.
///
/// PDFium's library initialisation is process-global. Keeping the facade in a
/// `OnceLock` gives document handles a `'static` borrow, which lets
/// [`PdfiumBackend`] own its `PdfDocument<'static>` without self-referential
/// lifetime tricks.
static PDFIUM: OnceLock<Pdfium> = OnceLock::new();

/// Candidate locations for the PDFium dynamic library, in priority order.
pub fn library_candidates() -> Vec<PathBuf> {
    let explicit = std::env::var(crate::PDFIUM_PATH_ENV).ok();
    library_candidates_with(explicit.as_deref())
}

/// Testable core of [`library_candidates`]: the environment override is a parameter
/// so that tests never have to mutate the process environment.
fn library_candidates_with(env_override: Option<&str>) -> Vec<PathBuf> {
    let mut candidates = Vec::new();

    if let Some(explicit) = env_override.filter(|value| !value.is_empty()) {
        candidates.push(PathBuf::from(explicit));
    }

    // Development layout: <repo>/vendor/pdfium/lib (see scripts/fetch-pdfium.sh).
    let dev_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../vendor/pdfium/lib");
    candidates.push(Pdfium::pdfium_platform_library_name_at_path(&dev_dir));

    // Bundled layout: resolved by the OS loader through the executable's rpath.
    candidates.push(PathBuf::from(Pdfium::pdfium_platform_library_name()));

    candidates
}

/// Loads (once) and returns the process-wide PDFium facade.
pub(crate) fn pdfium_instance() -> Result<&'static Pdfium> {
    if let Some(pdfium) = PDFIUM.get() {
        return Ok(pdfium);
    }

    let mut attempts = Vec::new();
    for candidate in library_candidates() {
        match Pdfium::bind_to_library(&candidate) {
            Ok(bindings) => {
                // Another thread may have won the race; either way the facade is
                // equivalent because the bindings are process-global.
                let _ = PDFIUM.set(Pdfium::new(bindings));
                if let Some(pdfium) = PDFIUM.get() {
                    return Ok(pdfium);
                }
            }
            Err(error) => attempts.push(format!("{} → {error}", candidate.display())),
        }
    }

    Err(ArisError::new(
        ErrorCode::BackendUnavailable,
        "could not load the PDFium library",
    )
    .with_detail(format!(
        "tried:\n  {}\nhint: run ./scripts/fetch-pdfium.sh or set {}",
        attempts.join("\n  "),
        crate::PDFIUM_PATH_ENV
    )))
}

/// A document opened through PDFium.
pub struct PdfiumBackend {
    /// Borrows from the process-wide [`Pdfium`], hence `'static`.
    document: PdfDocument<'static>,
    path: PathBuf,
    /// Whether the document was opened with a password (see `is_encrypted`).
    password_protected: bool,
}

impl PdfiumBackend {
    /// Opens `path`, optionally with a `password`.
    ///
    /// Returns [`ErrorCode::Encrypted`] when the document needs a password and
    /// none (or a wrong one) was supplied, so the shell can prompt for it.
    pub fn open(path: &Path, password: Option<&str>) -> Result<Self> {
        let pdfium = pdfium_instance()?;

        match pdfium.load_pdf_from_file(path, password) {
            Ok(document) => Ok(Self {
                document,
                path: path.to_path_buf(),
                password_protected: password.is_some(),
            }),
            Err(PdfiumError::PdfiumLibraryInternalError(PdfiumInternalError::PasswordError)) => {
                Err(
                    ArisError::new(ErrorCode::Encrypted, "the document is password protected")
                        .with_detail(format!("path: {}", path.display())),
                )
            }
            Err(PdfiumError::IoError(error)) => {
                // Distinguish "no such file" from "unreadable/corrupt bytes": the
                // shell shows a different message for each.
                let code = match error.kind() {
                    std::io::ErrorKind::NotFound => ErrorCode::NotFound,
                    std::io::ErrorKind::PermissionDenied => ErrorCode::Io,
                    _ => ErrorCode::Io,
                };
                Err(ArisError::new(code, "could not read the document")
                    .with_detail(format!("path: {} → {error}", path.display())))
            }
            Err(error) => Err(ArisError::new(
                ErrorCode::CorruptDocument,
                "PDFium could not open the document",
            )
            .with_detail(format!("path: {} → {error}", path.display()))),
        }
    }

    /// The path this document was opened from.
    pub fn path(&self) -> &Path {
        &self.path
    }

    fn page(&self, index: PageIndex) -> Result<PdfPage<'_>> {
        let count = self.page_count();
        if index.get() >= count {
            return Err(ArisError::new(
                ErrorCode::InvalidArgument,
                format!(
                    "page {} is out of range (document has {count} pages)",
                    index.get()
                ),
            ));
        }
        // `PdfPageIndex` is pdfium-render's own alias for the page index type; the
        // range check above guarantees the cast is lossless.
        let raw_index = index.get() as PdfPageIndex;

        self.document.pages().get(raw_index).map_err(|error| {
            ArisError::new(ErrorCode::RenderFailed, "could not load the page")
                .with_detail(error.to_string())
        })
    }
}

impl DocumentBackend for PdfiumBackend {
    fn page_count(&self) -> u32 {
        // PDFium reports a signed count; it is never negative for a loaded document.
        self.document.pages().len().max(0) as u32
    }

    fn page_info(&self, index: PageIndex) -> Result<PageInfo> {
        let page = self.page(index)?;

        // Boundary boxes are returned in unrotated PDF user space, which is
        // exactly what `PageGeometry` expects: it applies `/Rotate` itself.
        let media = page
            .boundaries()
            .media()
            .map(|boundary| rect_from_pdf(boundary.bounds))
            .unwrap_or_else(|_| rect_from_pdf(page.page_size()));
        let crop = page
            .boundaries()
            .get(PdfPageBoundaryBoxType::Crop)
            .map(|boundary| rect_from_pdf(boundary.bounds))
            .unwrap_or(media);

        let rotation = rotation_from_pdf(page.rotation().unwrap_or(PdfPageRenderRotation::None));

        Ok(PageInfo {
            index,
            // TODO(T1.1): `/UserUnit` is not exposed by pdfium-render; read it from
            // the page dictionary once we have a raw-bindings escape hatch.
            geometry: PageGeometry::new(media, crop, rotation, 1.0),
            label: page.label().map(str::to_string),
        })
    }

    fn outline(&self) -> Result<Vec<OutlineNode>> {
        Err(ArisError::not_implemented("PdfiumBackend::outline (T2.4)"))
    }

    fn links(&self, _page: PageIndex) -> Result<Vec<LinkInfo>> {
        Err(ArisError::not_implemented("PdfiumBackend::links (T4.1)"))
    }

    fn raw_text_page(&self, _page: PageIndex) -> Result<RawTextPage> {
        Err(ArisError::not_implemented(
            "PdfiumBackend::raw_text_page (T2.1)",
        ))
    }

    fn rasterize(&self, request: &RasterRequest) -> Result<RasterTile> {
        if request.region.is_some() {
            // Region rendering needs `FPDF_RenderPageBitmapWithMatrix`, which
            // pdfium-render does not expose; it lands with the tile pipeline in T1.3.
            return Err(ArisError::not_implemented("region rasterization (T1.3)"));
        }

        let page = self.page(request.page)?;

        // `FPDF_GetPageWidthF/HeightF` already account for `/Rotate`, and
        // `render_with_config` renders the rotated page, so the two agree.
        let width_px = (f64::from(page.width().value) * request.scale)
            .round()
            .max(1.0) as i32;
        let height_px = (f64::from(page.height().value) * request.scale)
            .round()
            .max(1.0) as i32;

        let [r, g, b, a] = request.background;
        let config = PdfRenderConfig::new()
            .set_target_size(width_px, height_px)
            // BGRA matches `wgpu::TextureFormat::Bgra8UnormSrgb`, so uploads need no
            // conversion. `pdfium-render` defaults to `FPDF_REVERSE_BYTE_ORDER`, which
            // would hand us RGBA instead — hence the explicit `false`. The byte order is
            // pinned by the `rasterize_keeps_native_bgra_channel_order` test below.
            .set_format(PdfBitmapFormat::BGRA)
            .set_reverse_byte_order(false)
            .render_annotations(request.flags.annotations)
            .render_form_data(request.flags.annotations)
            .use_lcd_text_rendering(request.flags.lcd_text)
            .limit_render_image_cache_size(request.flags.limit_image_cache)
            .clear_before_rendering(true)
            .set_clear_color(PdfColor::new(r, g, b, a));

        let bitmap = page.render_with_config(&config).map_err(|error| {
            ArisError::new(ErrorCode::RenderFailed, "PDFium failed to render the page").with_detail(
                format!(
                    "page {} @ {:.3}x → {error}",
                    request.page.get(),
                    request.scale
                ),
            )
        })?;

        let width = bitmap.width();
        let height = bitmap.height();
        let stride = usize::try_from(width).unwrap_or(0) * 4;

        let mut pixels = bitmap.as_raw_bytes();
        let expected = stride * usize::try_from(height).unwrap_or(0);
        if pixels.len() < expected {
            // Defensive: a short buffer would otherwise be interpreted as a
            // partially transparent tile further down the pipeline.
            pixels.resize(expected, 0);
        }

        Ok(RasterTile {
            size: Size::new(f64::from(width), f64::from(height)),
            stride,
            pixels,
            format: RasterFormat::Bgra8Premultiplied,
        })
    }

    fn is_encrypted(&self) -> bool {
        self.password_protected
    }

    fn is_tagged(&self) -> bool {
        // TODO(T2.1): `FPDFCatalog_IsTagged` decides whether the structure tree can
        // be used for a reliable reading order; pdfium-render does not expose it yet.
        false
    }
}

/// Converts a PDFium rectangle (PDF user space, origin bottom-left) into our [`Rect`].
///
/// Convention for page boxes: `origin` is the **bottom-left** corner and `size` is
/// positive. The single Y-flip into view space happens later, in
/// [`PageGeometry::page_to_view`]; `Rect::from_ltrb` is *not* the right helper here
/// because it assumes a top-left origin.
fn rect_from_pdf(rect: PdfRect) -> Rect {
    let left = f64::from(rect.left().value);
    let bottom = f64::from(rect.bottom().value);
    let right = f64::from(rect.right().value);
    let top = f64::from(rect.top().value);
    Rect::new(left, bottom, right - left, top - bottom)
}

fn rotation_from_pdf(rotation: PdfPageRenderRotation) -> Rotation {
    match rotation {
        PdfPageRenderRotation::None => Rotation::None,
        PdfPageRenderRotation::Degrees90 => Rotation::Clockwise90,
        PdfPageRenderRotation::Degrees180 => Rotation::Clockwise180,
        PdfPageRenderRotation::Degrees270 => Rotation::Clockwise270,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn library_candidates_are_ordered_and_non_empty() {
        let candidates = library_candidates();
        assert!(
            !candidates.is_empty(),
            "at least the bundled path is always offered"
        );
        assert!(
            candidates.iter().all(|path| !path.as_os_str().is_empty()),
            "no candidate may be empty"
        );
    }

    #[test]
    fn explicit_env_override_comes_first() {
        let candidates = library_candidates_with(Some("/tmp/libpdfium-custom.dylib"));
        assert_eq!(candidates[0], PathBuf::from("/tmp/libpdfium-custom.dylib"));
    }

    #[test]
    fn empty_env_override_is_ignored() {
        assert_eq!(
            library_candidates_with(Some("")).len(),
            library_candidates_with(None).len(),
            "an empty override must not add a candidate"
        );
    }

    #[test]
    fn rotation_mapping_matches_pdf_semantics() {
        assert_eq!(
            rotation_from_pdf(PdfPageRenderRotation::None),
            Rotation::None
        );
        assert_eq!(
            rotation_from_pdf(PdfPageRenderRotation::Degrees90),
            Rotation::Clockwise90
        );
        assert_eq!(
            rotation_from_pdf(PdfPageRenderRotation::Degrees270),
            Rotation::Clockwise270
        );
    }

    /// Pins the channel order of [`RasterTile`] bytes to **native BGRA**.
    ///
    /// This is the regression test for a real bug found during the T0.7 spike:
    /// `PdfRenderConfig` defaults to `FPDF_REVERSE_BYTE_ORDER`, so the buffer came
    /// back as RGBA while the engine contract (and wgpu's `Bgra8UnormSrgb`) expects
    /// BGRA — a silent red/blue swap that only shows up on coloured artwork.
    ///
    /// The fixture is generated by `scripts/make-fixtures.py`; it draws a brown
    /// square (RGB 140,76,51) at PDF rect `360 480 120 120`.
    #[test]
    fn rasterize_keeps_native_bgra_channel_order() {
        let fixture =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/text-page.pdf");
        if !fixture.exists() || !crate::is_available() {
            eprintln!(
                "skipping: fixture or PDFium unavailable ({})",
                fixture.display()
            );
            return;
        }

        let backend = PdfiumBackend::open(&fixture, None).expect("open fixture");
        // 144 dpi => 2 device pixels per PDF point.
        let tile = backend
            .rasterize(&RasterRequest::full_page(PageIndex(0), 2.0))
            .expect("rasterize page 0");

        // Centre of the brown square in image space: page height is 842 pt.
        let x = 840usize;
        let y = 604usize;
        let offset = y * tile.stride + x * 4;
        let pixel = &tile.pixels[offset..offset + 4];

        assert_eq!(tile.format, RasterFormat::Bgra8Premultiplied);

        // BGRA byte order for RGB(140, 76, 51). Values carry a ±2 tolerance because
        // rasterizers round the 0.55/0.30/0.20 colour components differently
        // (PDFium: 140,77,51; poppler: 140,76,51).
        let (blue, green, red, alpha) = (pixel[0], pixel[1], pixel[2], pixel[3]);
        assert_eq!(alpha, 0xFF, "the fixture background is opaque");
        for (name, actual, expected) in [
            ("red", red, 140u8),
            ("green", green, 77),
            ("blue", blue, 51),
        ] {
            let delta = i32::from(actual) - i32::from(expected);
            assert!(
                delta.abs() <= 2,
                "{name} channel out of tolerance: expected ~{expected}, got {actual} ({pixel:?})"
            );
        }
        // The decisive check: a channel-order regression makes blue the largest
        // channel instead of red.
        assert!(
            red > blue + 50,
            "channels look swapped (red={red}, blue={blue}); expected native BGRA"
        );
    }
}
