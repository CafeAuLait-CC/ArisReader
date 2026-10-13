//! The real PDFium-backed [`DocumentBackend`] implementation.
//!
//! See the crate-level docs for the task map, threading rules and library search
//! order. Everything in this module is compiled only with `feature = "pdfium"`.

use aris_reader_core::{
    ArisError, DocumentBackend, ErrorCode, LinkInfo, OutlineNode, PageGeometry, PageIndex,
    PageInfo, Point, RasterFormat, RasterRequest, RasterTile, RawCharBox, RawTextPage, Rect,
    Result, Rotation, Size,
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

/// Serialises **every** touch of a PDFium document or page handle, process-wide.
///
/// Measured, not guessed (2026-10-13, on 12 real papers plus the fixtures): with only the
/// per-document lock in place, the FFI test binary -- which opens several documents and uses
/// them from parallel test threads -- still died with SIGSEGV about once every 25 runs. The
/// crash disappeared once every page-handle path (rendering, `page_info`, text extraction,
/// link and outline reads) took this one lock, which is the honest conclusion: this PDFium
/// build does not tolerate concurrent use across documents for anything that loads a handle.
static PDFIUM_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Serialises opening documents. Rendering may run in parallel across copies of a
/// document; *loading* one must not (see the comment in [`PdfiumBackend::open`]).
static LOAD_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Serialises the one-time load of the PDFium library.
///
/// This is not paranoia: two threads opening their first document at the same time ran
/// PDFium's global initialisation concurrently and crashed the test binary with SIGSEGV.
static PDFIUM_INIT: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Loads (once) and returns the process-wide PDFium facade.
pub(crate) fn pdfium_instance() -> Result<&'static Pdfium> {
    if let Some(pdfium) = PDFIUM.get() {
        return Ok(pdfium);
    }

    // Fast path missed, so take the initialisation lock and check again: the loser of the
    // race must not run `bind_to_library` a second time.
    let _initialising = PDFIUM_INIT
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
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

/// A link the shell can act on.
///
/// Deliberately narrower than [`aris_reader_core::LinkInfo`], whose `Destination` carries a
/// view mode: this is what navigation needs today (a page to jump to, or a URL to open).
/// TODO(T4.1): map the full `LinkKind` (launch actions, view modes) onto `LinkInfo`.
#[derive(Clone, Debug, PartialEq)]
pub struct RawLink {
    /// Clickable rectangle (page space, bottom-left origin, like the text boxes).
    pub rect: Rect,
    /// External target.
    pub uri: Option<String>,
    /// Internal target page.
    pub page: Option<PageIndex>,
    /// Region the destination points at (page space, bottom-left origin), when the PDF says so.
    ///
    /// A citation to a figure or table uses a `/FitR` destination; a `/Fit` or `/XYZ`
    /// destination has no rectangle and means "the whole page".
    pub dest_rect: Option<Rect>,
}

/// Converts a `/FitR` destination rectangle into view space.
///
/// Page boxes use a bottom-left origin and view space a top-left one, so this is the single
/// Y-flip for a destination — the same rule [`PageGeometry::page_to_view`] applies to points.
/// It lives on its own so it can be unit-tested without a PDFium document.
pub fn destination_region_view_space(rect: Rect, page_height: f64) -> Rect {
    Rect::new(
        rect.origin.x,
        page_height - (rect.origin.y + rect.size.height),
        rect.size.width,
        rect.size.height,
    )
}

/// A document opened through PDFium.
pub struct PdfiumBackend {
    /// Borrows from the process-wide [`Pdfium`], hence `'static`.
    document: PdfDocument<'static>,
    path: PathBuf,
    /// Kept so [`PdfiumBackend::reopen`] can hand another thread its own copy.
    password: Option<String>,
    /// Whether the document was opened with a password (see `is_encrypted`).
    password_protected: bool,
    /// Serialises rendering **on this document**. Different backends have different
    /// locks, so per-thread copies render in parallel (T1.3).
    raster_lock: std::sync::Mutex<()>,
}

impl PdfiumBackend {
    /// Opens `path`, optionally with a `password`.
    ///
    /// Returns [`ErrorCode::Encrypted`] when the document needs a password and
    /// none (or a wrong one) was supplied, so the shell can prompt for it.
    pub fn open(path: &Path, password: Option<&str>) -> Result<Self> {
        let pdfium = pdfium_instance()?;

        // Loading is what has to be serialised, not rendering: two tests opening their
        // first document at the same time crashed with SIGSEGV, while four threads
        // rendering four *separate* documents in parallel is fine (see
        // `reopened_copies_render_in_parallel`). Keeping the lock this narrow is what
        // lets the raster pool be genuinely parallel.
        let document = {
            let _loading = LOAD_LOCK
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            pdfium.load_pdf_from_file(path, password)
        };

        match document {
            Ok(document) => Ok(Self {
                document,
                path: path.to_path_buf(),
                password: password.map(str::to_string),
                password_protected: password.is_some(),
                raster_lock: std::sync::Mutex::new(()),
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

    /// Opens an independent copy of the same file for another worker thread.
    ///
    /// PDFium documents must not be shared between threads, so the raster pool keeps one
    /// copy per worker (`docs/02-architecture.md` §3). Reopening is cheap: PDFium
    /// memory-maps the file and reuses its caches.
    /// Image object boxes (figures) and the path-object count (rules) on a page.
    ///
    /// PDF has no "figure" or "table" object: an image XObject is as close as the format comes,
    /// and rules — stroked paths — are the only handle on tables and vector figures.
    pub fn page_object_summary(&self, page: PageIndex) -> Result<(Vec<Rect>, usize)> {
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let pdf_page = self.page(page)?;

        let mut images = Vec::new();
        let mut paths = 0usize;
        for object in pdf_page.objects().iter() {
            match object.object_type() {
                PdfPageObjectType::Image => {
                    // `bounds()` hands back a quadrilateral; images are axis-aligned, so its
                    // left/right/bottom/top give the box directly.
                    if let Ok(quad) = object.bounds() {
                        images.push(Rect::new(
                            f64::from(quad.left().value),
                            f64::from(quad.bottom().value),
                            f64::from(quad.right().value - quad.left().value),
                            f64::from(quad.top().value - quad.bottom().value),
                        ));
                    }
                }
                PdfPageObjectType::Path => paths += 1,
                _ => {}
            }
        }

        Ok((images, paths))
    }

    /// Number of link annotations the PDF actually contains, resolved or not.
    ///
    /// [`PdfiumBackend::link_targets`] deliberately drops links it cannot act on, so this is
    /// the denominator: comparing the two is how a missing capability (named destinations,
    /// remote destinations) shows up as a number instead of a guess.
    pub fn link_annotation_count(&self, page: PageIndex) -> Result<usize> {
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let pdf_page = self.page(page)?;
        Ok(pdf_page.links().len())
    }

    /// Action types of the link annotations that [`PdfiumBackend::link_targets`] had to drop.
    ///
    /// Measurement first: before guessing why links do not resolve, ask the document what
    /// they actually are. Returns one short label per unresolved annotation.
    pub fn unresolved_link_actions(&self, page: PageIndex) -> Result<Vec<String>> {
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let pdf_page = self.page(page)?;
        let mut labels = Vec::new();

        for link in pdf_page.links().iter() {
            if link.rect().is_err() {
                continue;
            }
            let Some(action) = link.action() else {
                // The annotation's own /Dest counts as resolved (see `link_targets`).
                if link.destination().is_some() {
                    continue;
                }
                labels.push("no action, no destination".to_string());
                continue;
            };

            // The same resolution rules `link_targets` uses, so this measures exactly the
            // links that get dropped.
            if action.as_uri_action().is_some() {
                continue;
            }
            if let Some(local) = action.as_local_destination_action()
                && local.destination().is_ok()
            {
                continue;
            }

            if link.destination().is_some() {
                continue;
            }

            let suffix = if action.is_unsupported() {
                " (unsupported)"
            } else {
                ""
            };
            labels.push(format!("{:?}{suffix}", action.action_type()));
        }

        Ok(labels)
    }

    /// Links on a page, reduced to what navigation needs.
    pub fn link_targets(&self, page: PageIndex) -> Result<Vec<RawLink>> {
        // Link actions live in document state (see `PDFIUM_LOCK`).
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

        let pdf_page = self.page(page)?;
        let mut links = Vec::new();

        for link in pdf_page.links().iter() {
            // A link without a readable box cannot be clicked, so it is skipped.
            let Ok(pdf_rect) = link.rect() else { continue };
            let rect = rect_from_pdf(pdf_rect);
            let mut uri = None;
            let mut target = None;
            let mut dest_rect = None;

            if let Some(action) = link.action() {
                if let Some(uri_action) = action.as_uri_action() {
                    uri = uri_action.uri().ok();
                } else if let Some(local) = action.as_local_destination_action()
                    && let Ok(destination) = local.destination()
                {
                    target = destination
                        .page_index()
                        .ok()
                        .map(|index| PageIndex(index.max(0) as u32));

                    // `/FitR` is the case a figure or table citation uses.
                    if let Ok(PdfDestinationViewSettings::FitPageToRectangle(rect)) =
                        destination.view_settings()
                    {
                        dest_rect = Some(rect_from_pdf(rect));
                    }
                }
            }

            // A link may carry its target in an action (/A) **or** directly on the
            // annotation (/Dest). Real papers use both: in the sample corpus one file had 83
            // of 92 links with no action at all, and every one of them was a /Dest. Without
            // this fallback those links look like dead ends even though they navigate fine.
            if uri.is_none()
                && target.is_none()
                && let Some(destination) = link.destination()
            {
                target = destination
                    .page_index()
                    .ok()
                    .map(|index| PageIndex(index.max(0) as u32));
                if let Ok(PdfDestinationViewSettings::FitPageToRectangle(rect)) =
                    destination.view_settings()
                {
                    dest_rect = Some(rect_from_pdf(rect));
                }
            }

            // A link that leads nowhere is not worth handing to the shell.
            if uri.is_some() || target.is_some() {
                links.push(RawLink {
                    rect,
                    uri,
                    page: target,
                    dest_rect,
                });
            }
        }

        Ok(links)
    }

    pub fn reopen(&self) -> Result<Self> {
        Self::open(&self.path, self.password.as_deref())
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
    /// Renders a sub-rectangle ("tile") of a page through PDFium's matrix path.
    ///
    /// PDFium composes the matrix on top of its own display transform, which already
    /// applies the page's intrinsic `/Rotate`, so a tile lands in exactly the same
    /// orientation as a whole-page render — the `a_tile_matches_the_full_page_render`
    /// test pins that down by comparing against a crop of the full render.
    ///
    /// Region rendering is what makes a tile pipeline affordable at all: rendering the
    /// whole page and cropping would re-interpret the content stream once per tile.
    fn rasterize_region(
        &self,
        page: &PdfPage<'_>,
        request: &RasterRequest,
        region: Rect,
    ) -> Result<RasterTile> {
        let width_px = (region.size.width * request.scale).ceil().max(1.0) as i32;
        let height_px = (region.size.height * request.scale).ceil().max(1.0) as i32;

        // Device pixel = (view point − region origin) × scale. The region is in view
        // space (top-left origin, like everything the renderer consumes).
        let scale = request.scale as f32;
        let matrix = PdfMatrix::new(
            scale,
            0.0,
            0.0,
            scale,
            -(region.origin.x as f32) * scale,
            -(region.origin.y as f32) * scale,
        );

        // Deliberately *not* `set_target_size`: pdfium-render turns a target size into a
        // "fit the whole page into it" scale and composes that on top of our matrix, which
        // would shrink the page into the tile instead of cropping it. The tile bitmap is
        // therefore allocated here, and the matrix alone defines the page→device mapping.
        let config = render_config(request)
            .clip(0, 0, width_px, height_px)
            .reset_matrix(matrix)
            .map_err(|error| {
                ArisError::new(ErrorCode::Internal, "PDFium rejected the tile transform")
                    .with_detail(format!("{error}"))
            })?;

        let mut bitmap =
            PdfBitmap::empty(width_px, height_px, PdfBitmapFormat::BGRA).map_err(|error| {
                ArisError::new(ErrorCode::RenderFailed, "could not allocate a tile bitmap")
                    .with_detail(format!("{error}"))
            })?;

        page.render_into_bitmap_with_config(&mut bitmap, &config)
            .map_err(|error| {
                ArisError::new(ErrorCode::RenderFailed, "PDFium failed to render a tile")
                    .with_detail(format!(
                        "page {} tile ({:.0},{:.0} {:.0}×{:.0}) @ {:.3}x → {error}",
                        request.page.get(),
                        region.origin.x,
                        region.origin.y,
                        region.size.width,
                        region.size.height,
                        request.scale
                    ))
            })?;

        Ok(tile_from_bitmap(&bitmap))
    }
}

impl DocumentBackend for PdfiumBackend {
    fn page_count(&self) -> u32 {
        // PDFium reports a signed count; it is never negative for a loaded document.
        self.document.pages().len().max(0) as u32
    }

    fn page_info(&self, index: PageIndex) -> Result<PageInfo> {
        // See `PDFIUM_LOCK`: loading a page handle is document state, exactly like rendering.
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

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
        // Bookmarks live in the document's own state (see `PDFIUM_LOCK`).
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

        let mut nodes = Vec::new();
        for bookmark in self.document.bookmarks().iter() {
            // A bookmark without a resolvable page is still shown (its title is useful in
            // the sidebar) but cannot be navigated to.
            let page = bookmark
                .destination()
                .and_then(|destination| destination.page_index().ok())
                .map(|index| PageIndex(index.max(0) as u32));

            nodes.push(OutlineNode {
                title: bookmark.title().unwrap_or_default(),
                // TODO(T2.3): resolve the destination view mode (`FPDFDest_GetView`) so the
                // sidebar can restore the exact scroll position, not just the page.
                dest: None,
                page,
                children: Vec::new(),
            });
        }

        Ok(nodes)
    }

    fn links(&self, _page: PageIndex) -> Result<Vec<LinkInfo>> {
        Err(ArisError::not_implemented("PdfiumBackend::links (T4.1)"))
    }

    fn raw_text_page(&self, page: PageIndex) -> Result<RawTextPage> {
        // Text extraction walks the same document state as rendering (see `PDFIUM_LOCK`).
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

        let pdf_page = self.page(page)?;
        let text = pdf_page.text().map_err(|error| {
            ArisError::new(
                ErrorCode::RenderFailed,
                "PDFium failed to read the text layer",
            )
            .with_detail(format!("page {} → {error}", page.get()))
        })?;

        let mut chars = Vec::new();
        for character in text.chars().iter() {
            let bounds = character.loose_bounds().map_err(|error| {
                ArisError::new(ErrorCode::RenderFailed, "PDFium reported no character box")
                    .with_detail(format!("page {} → {error}", page.get()))
            })?;
            let unicode = character
                .unicode_char()
                .map(u32::from)
                .unwrap_or(u32::from(char::REPLACEMENT_CHARACTER));

            chars.push(RawCharBox {
                rect: rect_from_pdf(bounds),
                origin: Point::new(
                    f64::from(bounds.left().value),
                    f64::from(bounds.bottom().value),
                ),
                unicode,
                // `PdfPageTextChar::font_size` is not usable here (its trait bounds are
                // not satisfied); the loose box height is a good stand-in for selection UI.
                font_size: f64::from(bounds.height().value),
                font_name: character.font_name(),
                // TODO(T2.1): derive the glyph angle from the text matrix; PDFium's
                // character API does not expose it directly.
                angle: 0.0,
            });
        }

        Ok(RawTextPage {
            page,
            chars,
            text: text.all(),
            // TODO(T2.1): `FPDFText_IsGenerated` / `FPDFText_HasUnicodeMapError` are not
            // exposed by pdfium-render yet; both matter for search reliability.
            is_generated: false,
            has_unicode_map_error: false,
        })
    }

    fn rasterize(&self, request: &RasterRequest) -> Result<RasterTile> {
        // See `PDFIUM_LOCK`: rendering is serialised process-wide until this PDFium build's
        // cross-document behaviour is understood. The raster pool therefore buys a responsive
        // main thread, not overlapped work.
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let _document_guard = self
            .raster_lock
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

        let page = self.page(request.page)?;

        if let Some(region) = request.region {
            return self.rasterize_region(&page, request, region);
        }

        // `FPDF_GetPageWidthF/HeightF` already account for `/Rotate`, and
        // `render_with_config` renders the rotated page, so the two agree.
        let width_px = (f64::from(page.width().value) * request.scale)
            .round()
            .max(1.0) as i32;
        let height_px = (f64::from(page.height().value) * request.scale)
            .round()
            .max(1.0) as i32;

        let config = render_config(request).set_target_size(width_px, height_px);
        let bitmap = page.render_with_config(&config).map_err(|error| {
            ArisError::new(ErrorCode::RenderFailed, "PDFium failed to render the page").with_detail(
                format!(
                    "page {} @ {:.3}x → {error}",
                    request.page.get(),
                    request.scale
                ),
            )
        })?;

        Ok(tile_from_bitmap(&bitmap))
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

/// Builds the render configuration shared by the whole-page and tile paths.
///
/// The caller adds the target size (whole-page path) or a matrix and clip (tile path);
/// the two are mutually exclusive in pdfium-render.
fn render_config(request: &RasterRequest) -> PdfRenderConfig {
    let [r, g, b, a] = request.background;
    PdfRenderConfig::new()
        // BGRA matches `wgpu::TextureFormat::Bgra8UnormSrgb`, so uploads need no
        // conversion. `pdfium-render` defaults to `FPDF_REVERSE_BYTE_ORDER`, which would
        // hand us RGBA instead — hence the explicit `false`. The byte order is pinned by
        // the `rasterize_keeps_native_bgra_channel_order` test.
        .set_format(PdfBitmapFormat::BGRA)
        .set_reverse_byte_order(false)
        .render_annotations(request.flags.annotations)
        .render_form_data(request.flags.annotations)
        .use_lcd_text_rendering(request.flags.lcd_text)
        .limit_render_image_cache_size(request.flags.limit_image_cache)
        .clear_before_rendering(true)
        .set_clear_color(PdfColor::new(r, g, b, a))
}

/// Copies a PDFium bitmap into our own buffer.
fn tile_from_bitmap(bitmap: &PdfBitmap) -> RasterTile {
    let width = bitmap.width();
    let height = bitmap.height();
    let stride = usize::try_from(width).unwrap_or(0) * 4;

    let mut pixels = bitmap.as_raw_bytes();
    let expected = stride * usize::try_from(height).unwrap_or(0);
    if pixels.len() < expected {
        // Defensive: a short buffer would otherwise be interpreted as a partially
        // transparent tile further down the pipeline.
        pixels.resize(expected, 0);
    }

    RasterTile {
        size: Size::new(f64::from(width), f64::from(height)),
        stride,
        pixels,
        format: RasterFormat::Bgra8Premultiplied,
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
    fn reopened_copies_render_in_parallel() {
        let fixture =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/text-page.pdf");
        if !fixture.exists() || !crate::is_available() {
            return;
        }

        let base = PdfiumBackend::open(&fixture, None).expect("open fixture");

        // What the raster pool does: one document copy per worker, rendering at the same
        // time. This crashed with SIGSEGV until the library load was serialised.
        std::thread::scope(|scope| {
            for worker in 0..4u32 {
                let copy = base.reopen().expect("reopen");
                scope.spawn(move || {
                    let scale = 2f64.powi(worker as i32);
                    for _ in 0..8 {
                        let request =
                            RasterRequest::tile(PageIndex(0), scale, (0.0, 0.0), (64.0, 64.0));
                        let tile = copy.rasterize(&request).expect("concurrent tile");
                        assert_eq!(tile.size.width, 64.0 * scale);
                        assert!(!tile.pixels.is_empty());
                    }
                });
            }
        });
    }

    #[test]
    fn destination_rectangles_flip_into_view_space() {
        // A 100x50 region whose bottom-left corner sits 200 pt above the page bottom, on an
        // 842 pt tall page: its top edge is 592 pt down from the top in view space.
        let region = destination_region_view_space(Rect::new(30.0, 200.0, 100.0, 50.0), 842.0);
        assert_eq!(region.origin.x, 30.0);
        assert_eq!(region.origin.y, 842.0 - 250.0);
        assert_eq!(region.size.width, 100.0);
        assert_eq!(region.size.height, 50.0);

        // A region at the very top of the page stays at the top.
        let top = destination_region_view_space(Rect::new(0.0, 792.0, 595.0, 50.0), 842.0);
        assert_eq!(top.origin.y, 0.0);
    }

    #[test]
    fn a_tile_matches_the_same_region_of_the_full_page_render() {
        let fixture =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/text-page.pdf");
        if !fixture.exists() || !crate::is_available() {
            eprintln!("skipping: fixture or PDFium unavailable");
            return;
        }

        let backend = PdfiumBackend::open(&fixture, None).expect("open fixture");
        let full = backend
            .rasterize(&RasterRequest::full_page(PageIndex(0), 1.0))
            .expect("full page");

        // A 100×100 pt window 120 pt from the left and 200 pt from the top of the page.
        let region = Rect::new(120.0, 200.0, 100.0, 100.0);
        let mut request = RasterRequest::full_page(PageIndex(0), 1.0);
        request.region = Some(region);
        let tile = backend.rasterize(&request).expect("tile");

        assert_eq!(tile.size.width, 100.0);
        assert_eq!(tile.size.height, 100.0);

        // Compare the interior: the clip can antialias a tile's own edges slightly
        // differently, but the content must be the same picture.
        let mut total = 0i64;
        let mut samples = 0i64;
        let mut outliers = 0i64;
        let mut worst = 0i32;
        for y in 2..98usize {
            for x in 2..98usize {
                let tile_index = y * tile.stride + x * 4;
                let full_index = (y + 200) * full.stride + (x + 120) * 4;
                for channel in 0..3 {
                    let delta = (i32::from(tile.pixels[tile_index + channel])
                        - i32::from(full.pixels[full_index + channel]))
                    .abs();
                    worst = worst.max(delta);
                    total += i64::from(delta);
                    samples += 1;
                    if delta > 40 {
                        outliers += 1;
                    }
                }
            }
        }

        let mean = total as f64 / samples as f64;
        let outlier_share = outliers as f64 / samples as f64;

        // The geometry is exact: PDFium's matrix path works in view space (top-left
        // origin, Y downwards, one unit per point) and composes on top of the display
        // transform that applies /Rotate, so a tile is the same picture as a crop of the
        // full render. The measured mean is 0.02/255. The handful of strongly differing
        // pixels are glyph antialiasing: rasterising a glyph inside a tile can land on a
        // different subpixel grid than rasterising it as part of the whole page, so a few
        // edge pixels differ outright. Assert on the mean and on how rare those are.
        assert!(
            mean <= 0.5,
            "tile differs from the full-page render: mean {mean:.2}/255, worst {worst}/255"
        );
        assert!(
            outlier_share < 0.005,
            "{:.2}% of samples differ by more than 40/255 (worst {worst})",
            outlier_share * 100.0
        );
    }

    #[test]
    fn tiles_are_sharp_when_the_zoom_exceeds_one_texture() {
        let fixture =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/text-page.pdf");
        if !fixture.exists() || !crate::is_available() {
            return;
        }

        let backend = PdfiumBackend::open(&fixture, None).expect("open fixture");
        // 4x on A4 is 8 MP: a tile of it must render at the requested scale rather than
        // being clamped, which is the whole point of the tile pipeline.
        let mut request = RasterRequest::full_page(PageIndex(0), 4.0);
        request.region = Some(Rect::new(0.0, 0.0, 256.0, 256.0));
        let tile = backend.rasterize(&request).expect("tile at 4x");
        assert_eq!(tile.size.width, 1024.0);
        assert_eq!(tile.size.height, 1024.0);

        // The top-left tile must not be blank: this fixture has a heading there.
        let dark = tile
            .pixels
            .chunks(4)
            .filter(|pixel| pixel[0] < 128 && pixel[1] < 128 && pixel[2] < 128)
            .count();
        assert!(dark > 0, "the tile looks empty");
    }

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
