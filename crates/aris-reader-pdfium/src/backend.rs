//! The real PDFium-backed [`DocumentBackend`] implementation.
//!
//! See the crate-level docs for the task map, threading rules and library search
//! order. Everything in this module is compiled only with `feature = "pdfium"`.

use crate::annotations::AnnotationReader;
use aris_reader_core::{
    ArisError, DocMetadata, DocumentBackend, EmbeddedMetadata, ErrorCode, LineSegment, LinkInfo,
    OutlineNode, PageGeometry, PageIndex, PageInfo, Point, RasterFormat, RasterRequest, RasterTile,
    RawAnnotation, RawCharBox, RawTextPage, Rect, Result, Rotation, Size,
};
use pdfium_render::prelude::*;
use std::collections::HashMap;
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
pub(crate) static PDFIUM_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

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
    /// Top edge of the destination in page space, when the PDF says where to land.
    ///
    /// A `/XYZ` or `/FitH` destination carries a y coordinate — the only thing most papers
    /// give us. It is enough to know **where an entry starts**, which is what lets entry
    /// boundaries be derived from the document's own links instead of from numbering patterns.
    pub dest_top_y: Option<f64>,
    /// Left edge of the destination in page space, when the PDF says where to land.
    ///
    /// The y alone is not enough to rebuild an entry in a two-column bibliography: horizontal
    /// bands cut across both columns and merge them. Keeping x is what makes a column-aware
    /// reconstruction (and a preview rectangle that stays inside one column) possible.
    pub dest_left_x: Option<f64>,
}

/// Extracts where a destination lands, from its view settings (page space).
///
/// Returns the rectangle when the destination is a `/FitR`, and the top edge for the two
/// coordinate-carrying forms. `/Fit` and `/FitB` say nothing about position.
fn destination_landing(settings: &PdfDestinationViewSettings) -> DestinationLanding {
    match settings {
        PdfDestinationViewSettings::FitPageToRectangle(rect) => {
            let rect = rect_from_pdf(*rect);
            DestinationLanding {
                rect: Some(rect),
                top_y: Some(rect.origin.y + rect.size.height),
                left_x: Some(rect.origin.x),
            }
        }
        PdfDestinationViewSettings::SpecificCoordinatesAndZoom(Some(x), Some(y), _) => {
            DestinationLanding {
                rect: None,
                top_y: Some(f64::from(y.value)),
                left_x: Some(f64::from(x.value)),
            }
        }
        PdfDestinationViewSettings::SpecificCoordinatesAndZoom(None, Some(y), _) => {
            DestinationLanding {
                rect: None,
                top_y: Some(f64::from(y.value)),
                left_x: None,
            }
        }
        PdfDestinationViewSettings::FitPageHorizontallyToWindow(Some(y)) => DestinationLanding {
            rect: None,
            top_y: Some(f64::from(y.value)),
            left_x: None,
        },
        PdfDestinationViewSettings::FitBoundsHorizontallyToWindow(Some(y)) => DestinationLanding {
            rect: None,
            top_y: Some(f64::from(y.value)),
            left_x: None,
        },
        _ => DestinationLanding::default(),
    }
}

/// Where a destination lands: a rectangle, a top edge, a left edge, or nothing.
///
/// `/Fit` and `/FitB` say nothing about position; `/FitH` carries only y; `/XYZ` may carry x and
/// y; `/FitR` carries both through its rectangle.
#[derive(Clone, Copy, Debug, Default)]
struct DestinationLanding {
    rect: Option<Rect>,
    top_y: Option<f64>,
    left_x: Option<f64>,
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
    document: Option<PdfDocument<'static>>,
    page_count: u32,
    path: PathBuf,
    /// Kept so [`PdfiumBackend::reopen`] can hand another thread its own copy.
    password: Option<String>,
    /// Whether the document was opened with a password (see `is_encrypted`).
    password_protected: bool,
    /// Additional per-document guard; all PDFium operations also take PDFIUM_LOCK.
    raster_lock: std::sync::Mutex<()>,
    /// Second document handle, used for annotation reads only (`FPDFAnnot_*`).
    ///
    /// Opened on the first annotation query, so a document nobody asks about pays nothing; the
    /// failure is cached too, because it cannot change while the file is open. See
    /// [`crate::annotations`] for why the annotation API needs its own handle.
    annotation_reader: std::sync::OnceLock<std::result::Result<AnnotationReader, String>>,
    /// Rendering keeps navigation borders native while the shell draws content annotations.
    /// Only the raster document is changed in memory; annotation reads and saves use other handles.
    annotation_rendering: std::sync::Mutex<HashMap<PageIndex, AnnotationRenderState>>,
    link_borders: OnceLock<HashMap<PageIndex, Vec<crate::link_borders::LinkBorder>>>,
}

struct AnnotationRenderState {
    visible_non_links: Vec<usize>,
    all_annotations: bool,
}

impl PdfiumBackend {
    /// Opens `path`, optionally with a `password`.
    ///
    /// Returns [`ErrorCode::Encrypted`] when the document needs a password and
    /// none (or a wrong one) was supplied, so the shell can prompt for it.
    pub fn open(path: &Path, password: Option<&str>) -> Result<Self> {
        let pdfium = pdfium_instance()?;

        // Loading, page operations and destruction share one transaction lock. The
        // wrapper's per-call mutex does not protect a multi-call page operation.
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let document = pdfium.load_pdf_from_file(path, password);

        match document {
            Ok(document) => Ok(Self {
                page_count: document.pages().len().max(0) as u32,
                document: Some(document),
                path: path.to_path_buf(),
                password: password.map(str::to_string),
                password_protected: password.is_some(),
                raster_lock: std::sync::Mutex::new(()),
                annotation_reader: std::sync::OnceLock::new(),
                annotation_rendering: std::sync::Mutex::new(HashMap::new()),
                link_borders: OnceLock::new(),
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
    /// PDF has no "figure" object: an image XObject is as close as the format comes, and rules
    /// — stroked paths — are the only handle on tables and vector figures.
    ///
    /// Forms are descended into, because figures are routinely wrapped in one: stopping at the
    /// top level was why several real papers reported no images at all. A nested image's own
    /// bounds live in the form's coordinate system, so the **form's** bounds (which are in page
    /// space) are what gets reported — geometrically right, and enough to place a preview.
    pub fn page_object_summary(&self, page: PageIndex) -> Result<(Vec<Rect>, usize)> {
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let pdf_page = self.page(page)?;

        let mut images = Vec::new();
        let mut paths = 0usize;
        collect_page_objects(pdf_page.objects().iter(), &mut images, &mut paths, 0);

        Ok((images, paths))
    }

    /// Axis-aligned rules on a page, split into horizontal and vertical.
    ///
    /// PDF has no table object, so table borders have to be recognised geometrically. A border is
    /// a path whose bounding box is a long thin rectangle; separating the two orientations is what
    /// makes a grid detectable instead of a pile of vector art.
    pub fn page_rules(&self, page: PageIndex) -> Result<(Vec<Rect>, Vec<Rect>)> {
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let pdf_page = self.page(page)?;

        let mut horizontal = Vec::new();
        let mut vertical = Vec::new();
        collect_rules(pdf_page.objects().iter(), &mut horizontal, &mut vertical, 0);

        Ok((horizontal, vertical))
    }

    /// The axis-aligned line segments of a page's vector geometry, in page space.
    ///
    /// This is the raw material a table region is built from. A table border *is* a line, and the
    /// only way to see one is per segment: a path object's bounds are the whole drawing, and
    /// `page_rules` already showed that counting objects says nothing about grids.
    ///
    /// Accessors used, and why each one matters (`pdfium-render` 0.9.4):
    ///
    /// * `PdfPagePathObject::segments()` — there is no start-point accessor, only
    ///   `PdfPathSegment::point()`, which is a segment's **end** point. A line is therefore the
    ///   step from the previous point to this one.
    /// * `PdfPathSegment::segment_type()` — `MoveTo` *starts* a subpath, so it is a point to
    ///   remember and not a segment to emit. Walking endpoints without this check invents a
    ///   segment from the end of one subpath to the start of the next; where those happen to be
    ///   collinear, that phantom is a long thin rule, which is precisely the shape a table
    ///   detector looks for.
    /// * `PdfPathSegmentType::BezierTo` — a curve is artwork. Its chord can be long and
    ///   axis-aligned (a wide arc's ends share a y), so it is dropped rather than measured.
    /// * `PdfPagePathObject::matrix()` — `segments()` documents its points as the *untransformed*
    ///   values supplied when the segment was created, so the object's matrix is applied to land
    ///   in page space.
    ///
    /// Forms are descended into, like [`PdfiumBackend::page_object_summary`]. A path inside a
    /// form reports coordinates in the form's space; the form's own matrix is not composed here,
    /// which is a known limit (measured on the sample corpus: tables are drawn in the page
    /// content stream, so this does not bite — see the module notes on `table_region`).
    pub fn page_line_segments(&self, page: PageIndex) -> Result<Vec<LineSegment>> {
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let pdf_page = self.page(page)?;

        let mut segments = Vec::new();
        collect_line_segments(pdf_page.objects().iter(), &mut segments, 0);
        Ok(segments)
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
            let mut dest_top_y = None;
            let mut dest_left_x = None;

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

                    if let Ok(settings) = destination.view_settings() {
                        let landing = destination_landing(&settings);
                        dest_rect = landing.rect;
                        dest_top_y = landing.top_y;
                        dest_left_x = landing.left_x;
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
                if let Ok(settings) = destination.view_settings() {
                    let landing = destination_landing(&settings);
                    dest_rect = landing.rect;
                    dest_top_y = landing.top_y;
                    dest_left_x = landing.left_x;
                }
            }

            // A link that leads nowhere is not worth handing to the shell.
            if uri.is_some() || target.is_some() {
                let candidate = RawLink {
                    rect,
                    uri,
                    page: target,
                    dest_rect,
                    dest_top_y,
                    dest_left_x,
                };
                // Exactly-once, because `pdfium-render`'s `PdfPageLinks` treats PDFium's
                // enumeration *cursor* as a link index: `FPDFLink_Enumerate` advances a position
                // in the page's annotation array ("start_pos … is updated with the next start
                // position on return", fpdf_doc.h), so a link that is not the page's first
                // annotation is handed back once per preceding annotation. Measured on
                // `tests/fixtures/annotated.pdf`: one `/Link` behind five markup annotations
                // came back six times. The accessor is not ours to fix, and a caller that draws
                // a clickable box or collects destination landings wants each link once.
                if !links.iter().any(|existing| existing == &candidate) {
                    links.push(candidate);
                }
            }
        }

        Ok(links)
    }

    /// Annotations the document already carries on `page`, in page space.
    ///
    /// Reads through [`crate::annotations::AnnotationReader`], which owns a second document
    /// handle: PDFium's annotation dictionary accessors (`/BM`, `/CA`) are not reachable through
    /// the `pdfium-render` facade, and the facade does not hand out its own handle.
    ///
    /// The reader is opened on the first call, under the process-wide lock, and its failure is
    /// cached — a document whose annotations cannot be read reports the same error every time
    /// instead of retrying a file that is not going to change.
    pub fn annotation_page(&self, page: PageIndex) -> Result<Vec<RawAnnotation>> {
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

        if page.get() >= self.page_count() {
            return Err(ArisError::new(
                ErrorCode::InvalidArgument,
                format!(
                    "page {} is out of range (document has {} pages)",
                    page.get(),
                    self.page_count()
                ),
            ));
        }

        let reader = self.annotation_reader.get_or_init(|| {
            AnnotationReader::open(&self.path, self.password.as_deref())
                .map_err(|error| format!("{error:?}"))
        });

        match reader {
            Ok(reader) => reader.page(page),
            Err(detail) => Err(ArisError::new(
                ErrorCode::BackendUnavailable,
                "could not read the document's annotations",
            )
            .with_detail(detail.clone())),
        }
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

        self.document
            .as_ref()
            .expect("live document")
            .pages()
            .get(raw_index)
            .map_err(|error| {
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
    fn paint_link_borders(
        &self,
        page: &PdfPage<'_>,
        request: &RasterRequest,
        tile: &mut RasterTile,
    ) {
        let borders = self
            .link_borders
            .get_or_init(|| crate::link_borders::read(&self.path, self.password.as_deref()));
        if let Some(borders) = borders.get(&request.page) {
            crate::link_borders::paint(borders, page_geometry(page), request, tile);
        }
    }

    /// Let PDFium paint link borders with their original /Border, /BS, colour and appearance.
    /// Hide the other annotations when the shell will draw them itself. The first call records
    /// only originally visible non-link slots; subsequent tiles in the same mode cost one lookup.
    /// Call only while both PDFIUM_LOCK and raster_lock are held.
    fn prepare_annotation_rendering(
        &self,
        page: &PdfPage<'_>,
        index: PageIndex,
        include_content: bool,
    ) -> Result<()> {
        let mut modes = self
            .annotation_rendering
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        let state = modes.entry(index).or_insert_with(|| AnnotationRenderState {
            visible_non_links: page
                .annotations()
                .iter()
                .enumerate()
                .filter(|(_, annotation)| {
                    annotation.annotation_type() != PdfPageAnnotationType::Link
                        && !annotation.is_hidden()
                })
                .map(|(slot, _)| slot)
                .collect(),
            all_annotations: true,
        });
        if state.all_annotations == include_content {
            return Ok(());
        }
        for (changed, &slot) in state.visible_non_links.iter().enumerate() {
            let result = page
                .annotations()
                .get(slot as PdfPageAnnotationIndex)
                .and_then(|mut annotation| annotation.set_is_hidden(!include_content));
            if let Err(error) = result {
                // Restore the prior mode if a malformed annotation cannot be updated.
                for &previous in state.visible_non_links.iter().take(changed) {
                    if let Ok(mut annotation) =
                        page.annotations().get(previous as PdfPageAnnotationIndex)
                    {
                        let _ = annotation.set_is_hidden(include_content);
                    }
                }
                return Err(ArisError::new(
                    ErrorCode::RenderFailed,
                    "could not prepare annotation rendering",
                )
                .with_detail(error.to_string()));
            }
        }
        state.all_annotations = include_content;
        Ok(())
    }

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
            // PDFium's implicit clear uses the unscaled page dimensions. For tiles
            // larger than the page (common at low zoom), that leaves the rest of the
            // bitmap transparent. Initialize the entire bitmap below instead.
            .clear_before_rendering(false)
            .clip(0, 0, width_px, height_px)
            .reset_matrix(matrix)
            .map_err(|error| {
                ArisError::new(ErrorCode::Internal, "PDFium rejected the tile transform")
                    .with_detail(format!("{error}"))
            })?;

        let [red, green, blue, alpha] = request.background;
        let premultiply = |channel: u8| ((u16::from(channel) * u16::from(alpha) + 127) / 255) as u8;
        let background = [
            premultiply(blue),
            premultiply(green),
            premultiply(red),
            alpha,
        ];
        let byte_count = usize::try_from(width_px)
            .ok()
            .and_then(|width| {
                usize::try_from(height_px)
                    .ok()
                    .and_then(|height| width.checked_mul(height))
            })
            .and_then(|pixels| pixels.checked_mul(4))
            .ok_or_else(|| {
                ArisError::new(ErrorCode::RenderFailed, "tile bitmap size is too large")
            })?;
        let mut pixels = vec![0; byte_count];
        for pixel in pixels.as_chunks_mut::<4>().0 {
            pixel.copy_from_slice(&background);
        }
        let mut bitmap =
            PdfBitmap::from_bytes(width_px, height_px, PdfBitmapFormat::BGRA, &mut pixels)
                .map_err(|error| {
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

impl Drop for PdfiumBackend {
    fn drop(&mut self) {
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        // Explicitly destroy the handle while the guard is alive. Automatic field
        // destruction would run after this method releases the lock.
        drop(self.document.take());
    }
}

impl DocumentBackend for PdfiumBackend {
    fn page_count(&self) -> u32 {
        // Immutable until page editing is implemented; no FFI call or nested lock.
        self.page_count
    }

    fn page_info(&self, index: PageIndex) -> Result<PageInfo> {
        // See `PDFIUM_LOCK`: loading a page handle is document state, exactly like rendering.
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

        let page = self.page(index)?;

        Ok(PageInfo {
            index,
            // TODO(T1.1): `/UserUnit` is not exposed by pdfium-render; read it from
            // the page dictionary once we have a raw-bindings escape hatch.
            geometry: page_geometry(&page),
            label: page.label().map(str::to_string),
        })
    }

    fn outline(&self) -> Result<Vec<OutlineNode>> {
        // Bookmarks live in the document's own state (see `PDFIUM_LOCK`).
        let _guard = PDFIUM_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

        let bookmarks = self.document.as_ref().expect("live document").bookmarks();
        let mut visited = std::collections::HashSet::new();
        let mut nodes = Vec::new();
        let mut sibling = bookmarks.root();
        let mut level_seen = std::collections::HashSet::new();
        while let Some(bookmark) = sibling {
            // A malformed outline can make `next_sibling` loop back to a bookmark already
            // visited at this level. Stop the level rather than walking it forever.
            if !level_seen.insert(bookmark.clone()) {
                break;
            }
            if let Some(node) = outline_node(&bookmark, &mut visited) {
                nodes.push(node);
            }
            sibling = bookmark.next_sibling();
        }

        Ok(nodes)
    }

    fn links(&self, _page: PageIndex) -> Result<Vec<LinkInfo>> {
        Err(ArisError::not_implemented("PdfiumBackend::links (T4.1)"))
    }

    fn annotations(&self, page: PageIndex) -> Result<Vec<RawAnnotation>> {
        self.annotation_page(page)
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
            // The baseline origin, not the bottom of the ink box. `loose_bounds().bottom()` is
            // the bottom of the glyph's ink, which sits at a different height for a descender
            // (`g`) than for a capital (`H`); grouping characters into lines by it split one
            // printed line into several, and a page of text came out as fragments like
            // "ENERATION FROM3D H EMONSTRATIONSV". PDFium's own text origin is the baseline.
            let (origin_x, origin_y) = character.origin().map_err(|error| {
                ArisError::new(
                    ErrorCode::RenderFailed,
                    "PDFium reported no character origin",
                )
                .with_detail(format!("page {} → {error}", page.get()))
            })?;
            let unicode = character
                .unicode_char()
                .map(u32::from)
                .unwrap_or(u32::from(char::REPLACEMENT_CHARACTER));

            chars.push(RawCharBox {
                rect: rect_from_pdf(bounds),
                origin: Point::new(f64::from(origin_x.value), f64::from(origin_y.value)),
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

        // Repair degenerate boxes at the source.
        //
        // PDFium reports a zero-width, zero-height box for a sizeable minority of characters --
        // measured at 15-20% on every paper in the sample corpus. Consumers cope very differently:
        // a union over many characters shrugs it off, but anything that walks characters in order
        // (lines, blocks, columns) breaks, because a zero-width box looks like a huge gap to the
        // next glyph. Repairing it here keeps that assumption in one place.
        let mut heights: Vec<f64> = chars
            .iter()
            .map(|character| character.rect.size.height)
            .filter(|height| *height > 0.0)
            .collect();
        heights.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let median_height = heights.get(heights.len() / 2).copied().unwrap_or(10.0);

        let mut widths: Vec<f64> = chars
            .iter()
            .map(|character| character.rect.size.width)
            .filter(|width| *width > 0.0)
            .collect();
        widths.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let median_width = widths
            .get(widths.len() / 2)
            .copied()
            .unwrap_or(median_height * 0.5);

        for index in 0..chars.len() {
            let rect = chars[index].rect;
            if rect.size.width > 0.0 && rect.size.height > 0.0 {
                continue;
            }

            // Whitespace is left alone. Producers commonly emit a space with no glyph box at all,
            // and inventing vertical geometry for it is not a repair but a fabrication: the
            // vertical band-splitting that entries rely on then moves, which cost one paper six
            // matched citations when this repair covered spaces too. Consumers that walk
            // characters in order skip whitespace instead (see `lines_from`).
            if char::from_u32(chars[index].unicode)
                .map(|character| character.is_whitespace())
                .unwrap_or(false)
            {
                continue;
            }

            // Width from the distance to the next glyph, but only when that distance is plausible
            // for one character: across a line break it would stretch the box across the page.
            let inferred = chars
                .get(index + 1)
                .map(|next| next.rect.origin.x - rect.origin.x)
                .filter(|width| *width > 0.0 && *width <= median_height * 3.0)
                .unwrap_or(median_width);

            let height = if rect.size.height > 0.0 {
                rect.size.height
            } else {
                median_height
            };

            chars[index].rect = Rect::new(
                rect.origin.x,
                rect.origin.y,
                inferred.max(1.0),
                height.max(1.0),
            );
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

    fn embedded_metadata(&self) -> Result<EmbeddedMetadata> {
        // `FPDF_GetMetaText` reads document state, exactly like the text layer.
        let info = {
            let _guard = PDFIUM_LOCK
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            let document = self.document.as_ref().expect("live document");
            let metadata = document.metadata();
            let tag = |kind: PdfDocumentMetadataTagType| {
                metadata
                    .get(kind)
                    .map(|tag| tag.value().to_string())
                    .and_then(|value| trimmed_metadata(&value))
            };

            DocMetadata {
                title: tag(PdfDocumentMetadataTagType::Title),
                author: tag(PdfDocumentMetadataTagType::Author),
                subject: tag(PdfDocumentMetadataTagType::Subject),
                keywords: tag(PdfDocumentMetadataTagType::Keywords),
                creator: tag(PdfDocumentMetadataTagType::Creator),
                producer: tag(PdfDocumentMetadataTagType::Producer),
                creation_date: tag(PdfDocumentMetadataTagType::CreationDate),
            }
        };

        // XMP has no PDFium C accessor; the packet is read from the file's own bytes.
        Ok(EmbeddedMetadata {
            info,
            xmp: crate::xmp::read_xmp(&self.path),
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
        self.prepare_annotation_rendering(&page, request.page, request.flags.annotations)?;

        if let Some(region) = request.region {
            let mut tile = self.rasterize_region(&page, request, region)?;
            self.paint_link_borders(&page, request, &mut tile);
            return Ok(tile);
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

        let mut tile = tile_from_bitmap(&bitmap);
        self.paint_link_borders(&page, request, &mut tile);
        Ok(tile)
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

fn page_geometry(page: &PdfPage<'_>) -> PageGeometry {
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

    PageGeometry::new(media, crop, rotation, 1.0)
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
        .render_annotations(true)
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

/// Walks page objects and reports every axis-aligned line segment, in page space.
///
/// See [`PdfiumBackend::page_line_segments`] for why `MoveTo` points are remembered rather than
/// emitted, why curves are dropped, and why the object matrix is applied.
fn collect_line_segments<'a>(
    objects: impl Iterator<Item = PdfPageObject<'a>>,
    segments: &mut Vec<LineSegment>,
    depth: u32,
) {
    if depth > 4 {
        return;
    }

    for object in objects {
        if object.object_type() == PdfPageObjectType::XObjectForm {
            let PdfPageObject::XObjectForm(form) = &object else {
                continue;
            };
            collect_line_segments(form.iter(), segments, depth + 1);
            continue;
        }

        if object.object_type() != PdfPageObjectType::Path {
            continue;
        }
        let PdfPageObject::Path(path) = &object else {
            continue;
        };

        // The object's own placement. Without it a path that was created and then transformed
        // reports the coordinates it was built with, not where it is on the page.
        let matrix = path.matrix().ok();
        let segments_iter = match matrix {
            Some(matrix) => path.segments().transform(matrix),
            None => path.segments().raw(),
        };

        // `previous` is a subpath position, kept across `MoveTo` so the step from it to the next
        // `LineTo` is a real segment; a `MoveTo` itself is a new subpath and emits nothing.
        let mut previous: Option<(f64, f64)> = None;
        for segment in segments_iter.iter() {
            if segment.segment_type() == PdfPathSegmentType::MoveTo {
                let point = segment.point();
                previous = Some((f64::from(point.0.value), f64::from(point.1.value)));
                continue;
            }

            let current = segment.point();
            let here = (f64::from(current.0.value), f64::from(current.1.value));

            let Some((x1, y1)) = previous.replace(here) else {
                continue;
            };
            if segment.segment_type() == PdfPathSegmentType::BezierTo {
                continue;
            }

            let (x2, y2) = here;
            let line = LineSegment::new(Point::new(x1, y1), Point::new(x2, y2));
            if line.length() < MIN_SEGMENT_LENGTH_PT {
                continue;
            }
            if line.is_horizontal(SEGMENT_AXIS_TOLERANCE_PT)
                || line.is_vertical(SEGMENT_AXIS_TOLERANCE_PT)
            {
                segments.push(line);
            }
        }
    }
}

/// Shortest segment worth reporting from [`collect_line_segments`] (points).
///
/// Two points is the floor at which a "line" is still a line; anything shorter is a degenerate
/// path or a rounding artifact, and the grid detector discards it again by length anyway.
const MIN_SEGMENT_LENGTH_PT: f64 = 2.0;

/// How far off an axis a segment may lie and still be a candidate rule (points).
///
/// Table borders are exactly axis-aligned; this exists for the hair of floating-point error and
/// for a page whose content stream rotates a table by a fraction of a degree.
const SEGMENT_AXIS_TOLERANCE_PT: f64 = 1.0;

/// Collects long thin objects as rules (the geometry tables and bordered boxes leave behind).
fn collect_rules<'a>(
    objects: impl Iterator<Item = PdfPageObject<'a>>,
    horizontal: &mut Vec<Rect>,
    vertical: &mut Vec<Rect>,
    depth: u32,
) {
    if depth > 4 {
        return;
    }

    for object in objects {
        if object.object_type() == PdfPageObjectType::XObjectForm {
            let PdfPageObject::XObjectForm(form) = &object else {
                continue;
            };
            collect_rules(form.iter(), horizontal, vertical, depth + 1);
            continue;
        }

        if object.object_type() != PdfPageObjectType::Path {
            continue;
        }
        let PdfPageObject::Path(path) = &object else {
            continue;
        };

        // Segments, not the object's bounding box: a table's grid is usually **one** path object
        // containing many lines, so its bounds are the whole table and no thin rectangle ever
        // appears. Per-segment geometry is what makes a border visible.
        // The segment API exposes each segment's end point, so a line is the step from the
        // previous point to this one. Curves connect their endpoints too; the resulting box is
        // simply not thin, and the filter below drops it.
        let mut previous: Option<(PdfPoints, PdfPoints)> = None;
        for segment in path.segments().iter() {
            let current = segment.point();
            let Some(from) = previous.replace(current) else {
                continue;
            };

            let (x1, y1) = (f64::from(from.0.value), f64::from(from.1.value));
            let (x2, y2) = (f64::from(current.0.value), f64::from(current.1.value));

            let rect = Rect::new(x1.min(x2), y1.min(y2), (x2 - x1).abs(), (y2 - y1).abs());

            // Thresholds in points: a rule is at least 20 pt long and at most 3 pt thick.
            if rect.size.height <= 3.0 && rect.size.width >= 20.0 {
                horizontal.push(rect);
            } else if rect.size.width <= 3.0 && rect.size.height >= 20.0 {
                vertical.push(rect);
            }
        }
    }
}

/// Walks page objects, descending into form XObjects.
///
/// Figures are routinely wrapped in a form, so stopping at the top level reported no images at
/// all for several real papers. A nested image's own bounds live in the form's coordinate
/// system; the **form's** bounds are in page space, so that is what gets reported.
fn collect_page_objects<'a>(
    objects: impl Iterator<Item = PdfPageObject<'a>>,
    images: &mut Vec<Rect>,
    paths: &mut usize,
    depth: u32,
) {
    if depth > 4 {
        // Bounded so a pathological file cannot recurse forever.
        return;
    }

    for object in objects {
        match object.object_type() {
            PdfPageObjectType::Image => {
                if let Ok(quad) = object.bounds() {
                    images.push(rect_from_quad(quad));
                }
            }
            PdfPageObjectType::Path => *paths += 1,
            PdfPageObjectType::XObjectForm => {
                let Ok(bounds) = object.bounds() else {
                    continue;
                };
                let form_box = rect_from_quad(bounds);

                let PdfPageObject::XObjectForm(form) = &object else {
                    continue;
                };

                let mut nested_images = Vec::new();
                let mut nested_paths = 0usize;
                collect_page_objects(
                    form.iter(),
                    &mut nested_images,
                    &mut nested_paths,
                    depth + 1,
                );
                *paths += nested_paths;

                if !nested_images.is_empty() {
                    images.push(form_box);
                }
            }
            _ => {}
        }
    }
}

/// An axis-aligned box from PDFium's quadrilateral bounds.
fn rect_from_quad(quad: PdfQuadPoints) -> Rect {
    Rect::new(
        f64::from(quad.left().value),
        f64::from(quad.bottom().value),
        f64::from(quad.right().value - quad.left().value),
        f64::from(quad.top().value - quad.bottom().value),
    )
}

/// One outline bookmark and its descendants.
///
/// `pdfium-render`'s bookmark iterator walks the tree depth-first but does not say at which
/// depth it is, and a flat list cannot be numbered (`1`, `1.1`, `1.1.1`). Recursing over
/// `first_child`/`next_sibling` recovers the hierarchy. `visited` guards a malformed file whose
/// bookmark graph loops; a duplicate node is skipped rather than repeated forever.
fn outline_node<'a>(
    bookmark: &PdfBookmark<'a>,
    visited: &mut std::collections::HashSet<PdfBookmark<'a>>,
) -> Option<OutlineNode> {
    if !visited.insert(bookmark.clone()) {
        return None;
    }

    // A bookmark without a resolvable page is still shown (its title is useful in the sidebar)
    // but cannot be navigated to. Its children still get their own pages and nesting.
    let page = bookmark
        .destination()
        .and_then(|destination| destination.page_index().ok())
        .map(|index| PageIndex(index.max(0) as u32));

    let mut children = Vec::new();
    let mut child = bookmark.first_child();
    let mut level_seen = std::collections::HashSet::new();
    while let Some(node) = child {
        if !level_seen.insert(node.clone()) {
            break;
        }
        if let Some(outline) = outline_node(&node, visited) {
            children.push(outline);
        }
        child = node.next_sibling();
    }

    Some(OutlineNode {
        title: bookmark.title().unwrap_or_default(),
        // TODO(T2.3): resolve the destination view mode (`FPDFDest_GetView`) so the
        // sidebar can restore the exact scroll position, not just the page.
        dest: None,
        page,
        children,
    })
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

/// A metadata string without surrounding whitespace or NUL padding, or `None` when it is empty.
///
/// `/Info` values are PDF text strings and are not normalised by producers: trailing NULs and
/// stray newlines are common, and an empty string must mean "absent" rather than "a value that
/// happens to be blank" so recognition can fall through to the text layer.
fn trimmed_metadata(value: &str) -> Option<String> {
    let trimmed = value
        .trim_matches(|character: char| character.is_whitespace() || character == '\0')
        .trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
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
    use aris_reader_core::{AnnotationBlend, RawAnnotationColor, RawAnnotationKind};

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
    fn concurrent_workers_serialize_document_lifecycles() {
        let fixture = crate::test_support::fixture("text-page.pdf");
        if !crate::is_available() {
            return;
        }

        let base = PdfiumBackend::open(&fixture, None).expect("open fixture");

        // Exercise opening and destruction while other workers read and rasterize.
        // Workers overlap, but PDFium transactions must remain serialized.
        std::thread::scope(|scope| {
            for worker in 0..4u32 {
                let base = &base;
                scope.spawn(move || {
                    let scale = 2f64.powi(worker as i32);
                    for _ in 0..8 {
                        let copy = base.reopen().expect("reopen while rendering");
                        assert_eq!(copy.page_count(), 1);
                        copy.raw_text_page(PageIndex(0)).expect("text");
                        copy.link_targets(PageIndex(0)).expect("links");
                        copy.outline().expect("outline");
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

    /// Opens the committed annotated fixture, or `None` when the machine cannot run PDFium.
    ///
    /// The fixture is generated by `scripts/make-fixtures.py` — a hand-written PDF, so no real
    /// (copyrighted) document has to be committed to test reading someone else's markup.
    fn annotated_fixture() -> Option<PdfiumBackend> {
        let fixture = crate::test_support::fixture("annotated.pdf");
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return None;
        }
        Some(PdfiumBackend::open(&fixture, None).expect("open annotated fixture"))
    }

    /// The same, for the fixture whose annotations carry appearance streams.
    ///
    /// `annotated-appearance.pdf` is the shape Preview writes: every annotation has an `/AP`, the
    /// blend mode lives in that stream's `/ExtGState`, and `FPDFAnnot_GetColor` refuses all of
    /// them. The seven review PDFs in `pdf-samples/with_annotations/` are all of this shape (242
    /// markup annotations, none of which had a readable colour before this was fixed).
    fn annotated_appearance_fixture() -> Option<PdfiumBackend> {
        let fixture = crate::test_support::fixture("annotated-appearance.pdf");
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return None;
        }
        Some(PdfiumBackend::open(&fixture, None).expect("open appearance fixture"))
    }

    /// The same, for the notes-only fixture `annotated-notes.pdf`.
    ///
    /// One of the user's seven review PDFs (`review_tang_0905.pdf`) carries 22 content
    /// annotations and **no markup at all**: 11 sticky notes and 11 hidden "completed" markers.
    /// This is that file in miniature, and it is what the classification test below runs on.
    fn annotated_notes_fixture() -> Option<PdfiumBackend> {
        let fixture = crate::test_support::fixture("annotated-notes.pdf");
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return None;
        }
        Some(PdfiumBackend::open(&fixture, None).expect("open notes fixture"))
    }

    /// Any committed fixture, opened through PDFium, or `None` when the machine cannot.
    fn backend_for_fixture(name: &str) -> Option<PdfiumBackend> {
        let fixture = crate::test_support::fixture(name);
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return None;
        }
        Some(PdfiumBackend::open(&fixture, None).expect("open fixture"))
    }

    /// Every field the reader promises, against the values the fixture was written with.
    /// The expected bytes are the ones PDFium produced for `/C [0.2 0.6 1]` when this test was
    /// written (measured with a ctypes harness against the same library). PDFium truncates
    /// `channel × 255` in `f32`, so the values are asserted exactly: a silent change in that
    /// conversion is something this project wants to hear about, not a tolerance to hide behind.
    #[test]
    fn annotations_in_the_fixture_survive_the_read() {
        let Some(backend) = annotated_fixture() else {
            return;
        };

        let first_page = backend.annotations(PageIndex(0)).expect("annotations");
        let kinds: Vec<&str> = first_page
            .iter()
            .map(|annotation| annotation.kind.as_str())
            .collect();
        assert_eq!(
            kinds,
            vec!["highlight", "underline", "strikeout", "text", "freeText"],
            "the fixture's five content annotations, in document order"
        );

        // The sixth annotation on that page is a `/Link`: navigation, not something to draw or
        // list. It has to be invisible here and visible through the link path, in the same file.
        let links = backend.link_targets(PageIndex(0)).expect("links");
        assert_eq!(
            links.len(),
            1,
            "the fixture's link is reported by the link path"
        );
        assert_eq!(
            links[0].uri.as_deref(),
            Some("https://example.org/annotated")
        );
        assert!(
            !kinds.contains(&"Link") && !kinds.iter().any(|kind| kind.starts_with("Subtype")),
            "a link annotation must not be reported as an annotation"
        );

        let highlight = &first_page[0];
        assert_eq!(highlight.page, PageIndex(0));
        // Page space: bottom-left origin, exactly how the generator writes it: `/Rect` is the
        // union of two 15 pt body-line boxes, `671 … 701` up from the page bottom.
        assert_eq!(highlight.rect, Rect::new(72.0, 671.0, 388.0, 30.0));
        assert_eq!(
            highlight.quads,
            vec![
                Rect::new(72.0, 686.0, 388.0, 15.0),
                Rect::new(72.0, 671.0, 288.0, 15.0),
            ],
            "one rectangle per /QuadPoints entry, in file order"
        );
        assert_eq!(
            highlight.color,
            Some(RawAnnotationColor {
                red: 51,
                green: 153,
                blue: 255,
            }),
            "/C [0.2 0.6 1] as 8-bit sRGB"
        );
        assert_eq!(highlight.opacity, Some(0.5), "/CA 0.5");
        assert_eq!(highlight.blend, AnnotationBlend::Multiply, "/BM /Multiply");
        assert_eq!(
            highlight.contents.as_deref(),
            Some("Highlight contents for the round trip.")
        );
        assert_eq!(highlight.author.as_deref(), Some("Reviewer A"));
        assert_eq!(highlight.modified.as_deref(), Some("D:20240102030405Z"));
        assert!(highlight.visible);

        // The sticky note carries no /C, and PDFium answers black for it unless the key is
        // checked first; reporting "black" here would invent a colour the file never had.
        let sticky = &first_page[3];
        assert_eq!(sticky.kind, RawAnnotationKind::Text);
        assert_eq!(sticky.color, None, "a note without /C has no colour");
        assert_eq!(sticky.opacity, None);
        assert_eq!(sticky.blend, AnnotationBlend::Normal);
        assert_eq!(sticky.contents.as_deref(), Some("A sticky note body."));
        assert!(sticky.quads.is_empty(), "a sticky note has no quad points");

        // A second page keeps its own annotations: the page is part of the answer.
        let second_page = backend.annotations(PageIndex(1)).expect("annotations");
        assert_eq!(second_page.len(), 2);
        assert_eq!(second_page[0].kind, RawAnnotationKind::Squiggly);
        assert_eq!(second_page[0].page, PageIndex(1));
        assert_eq!(second_page[0].opacity, Some(0.75));
        assert_eq!(second_page[0].blend, AnnotationBlend::Multiply);

        // Markup without /QuadPoints still has its /Rect, which is the only geometry it has.
        let without_quads = &second_page[1];
        assert_eq!(without_quads.kind, RawAnnotationKind::Highlight);
        assert!(without_quads.quads.is_empty());
        assert_eq!(without_quads.rect, Rect::new(72.0, 656.0, 228.0, 15.0));
    }

    /// Nothing the reader reports is invisible without an answer: every content annotation is
    /// either drawn or *classified* as skipped, with the reason.
    ///
    /// This is the check for the user's report — "文件里有非常多的批注没能显示" — reduced to
    /// something a test can hold: on `annotated-notes.pdf` (a notes-only file, the shape of
    /// `review_tang_0905.pdf`), master's reader drew *nothing at all*, because the only drawing
    /// rule it had was for the four text-markup kinds and this file has none of them. A reader
    /// whose answer is "not drawn, and here is why" for a hidden "completed" marker and "drawn as
    /// an icon in #FFD833" for a note is one whose page matches its sidebar.
    ///
    /// The four skips are the whole point of the second half: an unclassified annotation would be
    /// indistinguishable from one this build cannot read, which is the failure mode being fixed.
    #[test]
    fn every_content_annotation_is_drawn_or_skipped_with_a_reason() {
        use aris_reader_core::{AnnotationAlignment, AnnotationDrawing, AnnotationSkipReason};

        let Some(backend) = annotated_notes_fixture() else {
            return;
        };
        let annotations = backend.annotations(PageIndex(0)).expect("annotations");
        assert_eq!(
            annotations.len(),
            7,
            "the fixture's seven content annotations"
        );

        let mut drawn_notes = 0;
        let mut drawn_text = 0;
        let mut drawn_markup = 0;
        let mut drawn_geometry = 0;
        let mut skips: Vec<AnnotationSkipReason> = Vec::new();
        for annotation in &annotations {
            match annotation.drawing() {
                AnnotationDrawing::Markup => drawn_markup += 1,
                AnnotationDrawing::NoteIcon => drawn_notes += 1,
                AnnotationDrawing::FreeText => drawn_text += 1,
                AnnotationDrawing::Geometry => drawn_geometry += 1,
                AnnotationDrawing::Skipped(reason) => skips.push(reason),
            }
        }
        // A notes-only file: nothing here is markup, which is exactly why it used to look blank.
        assert_eq!(drawn_markup, 0, "this fixture carries no text markup");
        assert_eq!(drawn_notes, 2, "both of its sticky notes are drawn");
        assert_eq!(drawn_text, 2, "both of its readable free texts are drawn");
        assert_eq!(
            drawn_geometry, 0,
            "the fixture's /InkList is the malformed flat form, so there is no stroke to draw"
        );
        assert_eq!(
            skips,
            vec![
                // In file order: the empty free text, the hidden "completed" marker, the ink
                // whose /InkList is not a list of paths.
                AnnotationSkipReason::EmptyContents,
                AnnotationSkipReason::Hidden,
                AnnotationSkipReason::EmptyGeometry,
            ],
            "each of the three undrawn annotations says why"
        );

        // A note with a stated colour is drawn in it; a note without one still has a colour to
        // draw with (the shell's default), and its `/Rect` is what the icon fills.
        let coloured = &annotations[0];
        assert_eq!(coloured.drawing(), AnnotationDrawing::NoteIcon);
        assert_eq!(
            coloured.color,
            Some(RawAnnotationColor {
                red: 255,
                // 0.85 × 255 is 216.75, which PDFium truncates in f32 rather than rounding —
                // the same conversion the markup colours go through.
                green: 216,
                blue: 51
            }),
            "/C [1 0.85 0.2] survives the appearance stream, which every corpus note carries"
        );
        assert_eq!(coloured.rect, Rect::new(500.0, 690.0, 26.0, 26.0));
        let plain = &annotations[1];
        assert_eq!(plain.drawing(), AnnotationDrawing::NoteIcon);
        assert_eq!(
            plain.color, None,
            "a note with no /C has no colour to report"
        );

        // Free text carries the two keys its layout needs, and a file that states neither is
        // still readable: `/DA` is where the size lives, `/Q` where the alignment does.
        let free_text = &annotations[2];
        assert_eq!(free_text.drawing(), AnnotationDrawing::FreeText);
        assert_eq!(free_text.font_size_pt, Some(14.0), "/DA (/Helv 14 Tf 0 g)");
        assert_eq!(free_text.alignment, AnnotationAlignment::Center, "/Q 1");
        assert_eq!(
            free_text.color,
            Some(RawAnnotationColor {
                // `/C [0.1 0.45 0.9]`, truncated in f32 by PDFium: 25.5 → 25, 114.75 → 114.
                red: 25,
                green: 114,
                blue: 229
            })
        );
        let plain_text = &annotations[3];
        assert_eq!(plain_text.drawing(), AnnotationDrawing::FreeText);
        assert_eq!(plain_text.font_size_pt, Some(9.0));
        assert_eq!(plain_text.alignment, AnnotationAlignment::Left, "/Q 0");
        assert_eq!(plain_text.color, None);

        // The hidden marker keeps its text and its colour and is still not drawn: the file said
        // so. It is the shape of 49 of the 99 sticky notes in the review corpus.
        let hidden = &annotations[5];
        assert!(!hidden.visible);
        assert_eq!(
            hidden.contents.as_deref(),
            Some("A note the file marks hidden.")
        );
        assert_eq!(
            hidden.drawing(),
            AnnotationDrawing::Skipped(AnnotationSkipReason::Hidden)
        );
        // …and an ink annotation whose /InkList is malformed is still reported as ink, with the
        // reason it has no path to draw, so the sidebar can name it and the dump can explain it.
        let ink = &annotations[6];
        assert_eq!(ink.kind, RawAnnotationKind::Ink);
        assert!(ink.ink_paths.is_empty());
        assert_eq!(
            ink.drawing(),
            AnnotationDrawing::Skipped(AnnotationSkipReason::EmptyGeometry)
        );
    }

    /// The reading half of T3.4, against ink and shapes written by another producer.
    ///
    /// `tests/fixtures/annotated-strokes.pdf` is generated by `scripts/make-fixtures.py` and
    /// hand-writes its `/InkList`, `/L`, `/LE`, `/BS` and `/AP`. Nothing about it came from
    /// Lyra: the test therefore proves the reader handles the dictionary a different editor
    /// writes, not only the one this writer produces (the write-back round trip covers that).
    #[test]
    fn ink_and_shapes_from_another_writer_are_read_as_geometry() {
        use aris_reader_core::{AnnotationDrawing, RawAnnotationKind};

        let Some(backend) = backend_for_fixture("annotated-strokes.pdf") else {
            return;
        };
        let annotations = backend.annotations(PageIndex(0)).expect("annotations");
        assert_eq!(annotations.len(), 5);
        let kinds: Vec<RawAnnotationKind> = annotations
            .iter()
            .map(|annotation| annotation.kind.clone())
            .collect();
        assert_eq!(
            kinds,
            vec![
                RawAnnotationKind::Ink,
                RawAnnotationKind::Square,
                RawAnnotationKind::Circle,
                RawAnnotationKind::Line,
                RawAnnotationKind::Line,
            ]
        );
        assert!(
            annotations
                .iter()
                .all(|annotation| annotation.drawing() == AnnotationDrawing::Geometry)
        );

        let ink = &annotations[0];
        assert_eq!(ink.ink_paths.len(), 1);
        assert_eq!(
            ink.ink_paths[0],
            vec![
                aris_reader_core::Point::new(90.0, 650.0),
                aris_reader_core::Point::new(120.0, 680.0),
                aris_reader_core::Point::new(160.0, 640.0),
                aris_reader_core::Point::new(240.0, 700.0),
            ]
        );
        assert_eq!(ink.border_width, Some(3.0), "/BS /W 3 is read as 3 pt");
        assert_eq!(
            ink.color,
            Some(RawAnnotationColor {
                red: 216,
                green: 38,
                blue: 25
            }),
            "/C survives behind the appearance stream"
        );
        assert!((ink.opacity.expect("opacity") - 0.8).abs() < 0.01);

        assert_eq!(annotations[1].rect, Rect::new(300.0, 620.0, 180.0, 80.0));
        assert_eq!(annotations[1].border_width, Some(2.0));
        assert_eq!(annotations[2].border_width, Some(1.5));
        let arrow = &annotations[3];
        assert!(arrow.line_arrow, "/LE [/None /ClosedArrow] is an arrow");
        assert_eq!(
            arrow.line,
            Some(aris_reader_core::RawAnnotationLine {
                start: aris_reader_core::Point::new(310.0, 490.0),
                end: aris_reader_core::Point::new(470.0, 570.0),
            })
        );
        assert!(
            !annotations[4].line_arrow,
            "/LE [/None /None] is a plain line"
        );
    }

    /// The user's question, as a test: a colour that is not one of ours comes through unchanged.
    ///
    /// `/C [0.2 0.6 1]` is a blue that matches no entry of `AppState.highlightPalette`. The old
    /// model could only name four colours, so a file like this was unreadable by construction;
    /// the reader now reports the channel values the file carries.
    #[test]
    fn a_colour_outside_our_palette_is_reported_faithfully() {
        let Some(backend) = annotated_fixture() else {
            return;
        };
        let annotations = backend.annotations(PageIndex(0)).expect("annotations");
        let color = annotations[0]
            .color
            .expect("the fixture's highlight has a /C entry");
        assert_eq!((color.red, color.green, color.blue), (51, 153, 255));

        // The four colours this application once could express, as they appear in
        // `AppState.highlightPalette` (BGRA there, RGB here): none of them is this blue.
        let old_palette = [
            (255, 216, 64),
            (112, 208, 96),
            (96, 160, 240),
            (224, 112, 176),
        ];
        assert!(
            !old_palette.contains(&(color.red, color.green, color.blue)),
            "the fixture colour must not be one of the old palette's"
        );
    }

    /// `/BM` is the difference between "looks like Preview" and "looks like a different colour".
    #[test]
    fn blend_mode_is_read_from_the_file_not_assumed() {
        let Some(backend) = annotated_fixture() else {
            return;
        };
        let annotations = backend.annotations(PageIndex(0)).expect("annotations");
        assert_eq!(annotations[0].blend, AnnotationBlend::Multiply);
        // The underline in the same file has no /BM at all. It is still multiplied — that is what
        // every renderer does with an underline, and what `default_blend` documents — but it must
        // not simply inherit its neighbour's *stated* mode: a squiggly, which PDFium composites
        // alpha-over, keeps Normal.
        assert_eq!(annotations[1].blend, AnnotationBlend::Multiply);
        let squiggly = &backend.annotations(PageIndex(1)).expect("second page")[0];
        assert_eq!(squiggly.kind, RawAnnotationKind::Squiggly);
        assert_eq!(
            squiggly.blend,
            AnnotationBlend::Multiply,
            "/BM is on this one"
        );
        let without_quads = &backend.annotations(PageIndex(1)).expect("second page")[1];
        assert_eq!(
            without_quads.blend,
            AnnotationBlend::Multiply,
            "a highlight with no /BM is multiplied, because that is how a highlight is drawn"
        );
    }

    /// The user's actual files: an annotation whose only colour lives behind an appearance stream.
    ///
    /// `annotated-appearance.pdf` is Preview's shape — `/AP` on every annotation, `/BM` on none of
    /// them. Before this was fixed, `FPDFAnnot_GetColor` refused all four (measured: it refuses
    /// *any* annotation with an appearance stream), so the reader reported "no colour" and the
    /// canvas painted an opaque grey bar over the text.
    #[test]
    fn colour_is_read_through_the_appearance_stream() {
        let Some(backend) = annotated_appearance_fixture() else {
            return;
        };
        let annotations = backend.annotations(PageIndex(0)).expect("annotations");
        assert_eq!(
            annotations.len(),
            4,
            "the fixture's four markup annotations"
        );

        let highlight = &annotations[0];
        assert_eq!(highlight.kind, RawAnnotationKind::Highlight);
        assert_eq!(
            highlight.color,
            Some(RawAnnotationColor {
                red: 255,
                green: 255,
                blue: 0,
            }),
            "/C [1 1 0] read through the /AP, not reported as absent"
        );
        assert!(
            (highlight.opacity.expect("/CA 0.968627") - 0.968627).abs() < 1e-6,
            "/CA 0.968627 is the file's own number, not a rounded byte: {:?}",
            highlight.opacity
        );
        assert_eq!(
            highlight.blend,
            AnnotationBlend::Multiply,
            "/BM /Multiply lives in the appearance stream's ExtGState; with no /BM on the \
             annotation, the highlight is still multiplied"
        );

        // The underline's dictionary states no /CA (its appearance paints at 40%, which PDFium's
        // C ABI does not expose) — the reader reports what the file states, and the kind default.
        let underline = &annotations[1];
        assert_eq!(
            underline.color.map(|c| (c.red, c.green, c.blue)),
            Some((229, 25, 25))
        );
        assert_eq!(underline.opacity, None);
        assert_eq!(underline.blend, AnnotationBlend::Multiply);

        // No /C at all: "the file did not say", which is not the same answer as black.
        let colourless = &annotations[2];
        assert_eq!(colourless.kind, RawAnnotationKind::Highlight);
        assert_eq!(colourless.color, None);
        assert!(
            (colourless.opacity.expect("/CA 0.35") - 0.35).abs() < 1e-6,
            "/CA is still read for an annotation with no /C: {:?}",
            colourless.opacity
        );
        assert_eq!(colourless.blend, AnnotationBlend::Multiply);

        // A squiggly with an appearance stream and no /BM keeps the alpha-over PDFium uses.
        let squiggly = &annotations[3];
        assert_eq!(squiggly.kind, RawAnnotationKind::Squiggly);
        assert_eq!(squiggly.blend, AnnotationBlend::Normal);
        assert!((squiggly.opacity.expect("/CA 0.75") - 0.75).abs() < 1e-6);

        // Reading is repeatable: the colour comes from the same place on a second call, and
        // clearing the appearance stream is confined to this reader's own document handle.
        let again = backend
            .annotations(PageIndex(0))
            .expect("annotations again");
        assert_eq!(again[0].color, highlight.color);
        assert_eq!(again[0].blend, highlight.blend);
    }

    /// The pixel-level half: what the canvas draws reproduces the file's own rendering.
    ///
    /// PDFium renders this fixture's annotations with `FPDF_ANNOT` — appearance streams, blend
    /// modes and all — which is the picture Preview shows. Our canvas draws a tint quad instead,
    /// so the test predicts the pixel it would produce from the *read* values
    /// (`page × (a·c + 1 − a)` for a multiplied highlight, in the stored colour space) and compares
    /// it with what PDFium drew. The alpha-over prediction is asserted at the same time: it is the
    /// bug this fix removed, and on dark glyph pixels it differs by far more than the tolerance.
    #[test]
    fn a_multiplied_highlight_draws_the_pixel_the_file_renders() {
        let Some(backend) = annotated_appearance_fixture() else {
            return;
        };
        let Some(highlight) = backend
            .annotations(PageIndex(0))
            .expect("annotations")
            .into_iter()
            .next()
        else {
            return;
        };
        let Some(color) = highlight.color else {
            panic!("the fixture's highlight carries /C");
        };
        let opacity = highlight.opacity.expect("/CA 0.968627");
        assert_eq!(highlight.blend, AnnotationBlend::Multiply);

        // A whole page at 2x, so a point sample lands on a real glyph pixel rather than between
        // them. `scale` is in PDF points, `RasterTile::pixels` is BGRA with a top-left origin.
        let scale = 2.0;
        let plain = backend
            .rasterize(&RasterRequest::full_page(PageIndex(0), scale))
            .expect("page without annotations");
        let burned = backend
            .rasterize(&{
                let mut request = RasterRequest::full_page(PageIndex(0), scale);
                request.flags.annotations = true;
                request
            })
            .expect("page with annotations");

        let sample = |tile: &RasterTile, x_pt: f64, y_pt: f64| -> [f64; 3] {
            let x = (x_pt * scale).round() as usize;
            let y = (y_pt * scale).round() as usize;
            let offset = y * tile.stride + x * 4;
            // BGRA, and the tile's origin is the page's top-left corner.
            [
                f64::from(tile.pixels[offset + 2]),
                f64::from(tile.pixels[offset + 1]),
                f64::from(tile.pixels[offset]),
            ]
        };

        let rect = highlight.rect;
        let canvas = [
            f64::from(color.red),
            f64::from(color.green),
            f64::from(color.blue),
        ];
        let mut compared = 0usize;
        let mut multiply_matches = 0usize;
        let mut alpha_over_matches = 0usize;
        let mut worst_multiply = 0.0f64;
        for step in 0..40 {
            // Interior samples only: 4 pt inside the quad, spread across its width, on the two
            // rows a body line's glyphs occupy.
            let x = rect.origin.x + 4.0 + (rect.size.width - 8.0) * f64::from(step) / 39.0;
            for y in [
                rect.origin.y + rect.size.height * 0.35,
                rect.origin.y + rect.size.height * 0.5,
            ] {
                // Page space is bottom-left; the tile is top-left.
                let view_y = 842.0 - y;
                let page_pixel = sample(&plain, x, view_y);
                let drawn = sample(&burned, x, view_y);
                let multiply: [f64; 3] = std::array::from_fn(|channel| {
                    page_pixel[channel] * (opacity * canvas[channel] + (1.0 - opacity) * 255.0)
                        / 255.0
                });
                let alpha_over: [f64; 3] = std::array::from_fn(|channel| {
                    opacity * canvas[channel] + (1.0 - opacity) * page_pixel[channel]
                });
                let multiply_deviation = (0..3)
                    .map(|c| (drawn[c] - multiply[c]).abs())
                    .fold(0.0, f64::max);
                let alpha_over_deviation = (0..3)
                    .map(|c| (drawn[c] - alpha_over[c]).abs())
                    .fold(0.0, f64::max);
                // Only the pixels where the two disagree: over white paper they are the same
                // number and the sample says nothing about the blend mode.
                if (multiply[0] - alpha_over[0]).abs() < 8.0
                    && (multiply[1] - alpha_over[1]).abs() < 8.0
                    && (multiply[2] - alpha_over[2]).abs() < 8.0
                {
                    continue;
                }
                compared += 1;
                worst_multiply = worst_multiply.max(multiply_deviation);
                if multiply_deviation <= 4.0 {
                    multiply_matches += 1;
                }
                if alpha_over_deviation <= 4.0 {
                    alpha_over_matches += 1;
                }
            }
        }

        assert!(
            compared >= 8,
            "the fixture's highlight must cover glyph pixels to discriminate the two blends \
             (compared {compared})"
        );
        assert_eq!(
            multiply_matches, compared,
            "every discriminating pixel must match PDF's gamma-space multiply \
             (worst deviation {worst_multiply:.1}/255 over {compared} samples)"
        );
        assert!(
            alpha_over_matches * 2 < compared,
            "painting the same highlight alpha-over must *not* reproduce the file: \
             {alpha_over_matches} of {compared} samples matched it"
        );
    }

    /// A page with no annotations is an empty answer, not an error and not a stale one.
    #[test]
    fn a_page_without_annotations_reports_nothing() {
        let fixture = crate::test_support::fixture("text-page.pdf");
        if !crate::is_available() {
            eprintln!("skipping: fixture or PDFium unavailable");
            return;
        }
        let backend = PdfiumBackend::open(&fixture, None).expect("open fixture");
        assert!(
            backend
                .annotations(PageIndex(0))
                .expect("annotations")
                .is_empty()
        );
        assert!(matches!(
            backend.annotations(PageIndex(7)),
            Err(error) if error.code == ErrorCode::InvalidArgument
        ));
    }

    #[test]
    fn glyph_boxes_are_never_degenerate() {
        // PDFium reports a zero-size box for 15-20% of characters in the sample corpus (mostly
        // spaces, but also real glyphs). Everything that walks characters in order -- lines,
        // blocks, columns -- breaks on those, so `raw_text_page` repairs them and this pins that.
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../pdf-samples");
        if !dir.is_dir() || !crate::is_available() {
            eprintln!("skipping: sample corpus or PDFium unavailable");
            return;
        }

        let mut checked = 0usize;
        for entry in std::fs::read_dir(&dir)
            .expect("read corpus")
            .flatten()
            .take(3)
        {
            let path = entry.path();
            if path.extension().map(|e| e != "pdf").unwrap_or(true) {
                continue;
            }
            let Ok(backend) = PdfiumBackend::open(&path, None) else {
                continue;
            };
            let Ok(text) = backend.raw_text_page(PageIndex(0)) else {
                continue;
            };

            for character in &text.chars {
                let is_whitespace = char::from_u32(character.unicode)
                    .map(|c| c.is_whitespace())
                    .unwrap_or(false);
                if is_whitespace {
                    // Whitespace is deliberately left as the producer emitted it.
                    continue;
                }
                assert!(
                    character.rect.size.width > 0.0 && character.rect.size.height > 0.0,
                    "degenerate box for {:?} in {}",
                    char::from_u32(character.unicode),
                    path.display()
                );
            }
            checked += 1;
        }
        eprintln!("checked {checked} sample document(s)");
    }

    #[test]
    fn a_tile_matches_the_same_region_of_the_full_page_render() {
        let fixture = crate::test_support::fixture("text-page.pdf");
        if !crate::is_available() {
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
    fn oversized_tile_background_is_opaque_and_matches_full_page_alpha() {
        let fixture = crate::test_support::fixture("text-page.pdf");
        if !crate::is_available() {
            eprintln!("skipping: fixture or PDFium unavailable");
            return;
        }

        let backend = PdfiumBackend::open(&fixture, None).expect("open fixture");
        let full = backend
            .rasterize(&RasterRequest::full_page(PageIndex(0), 1.0))
            .expect("full page");
        let mut request = RasterRequest::full_page(PageIndex(0), 1.0);
        request.region = Some(Rect::new(0.0, 0.0, 1024.0, 1024.0));
        let tile = backend.rasterize(&request).expect("oversized tile");

        assert_eq!(tile.size.width, 1024.0);
        assert_eq!(tile.size.height, 1024.0);
        for (index, pixel) in tile.pixels.as_chunks::<4>().0.iter().enumerate() {
            assert_eq!(pixel[3], 0xFF, "tile pixel {index} is not opaque");
        }

        let overlap_width = (full.size.width as usize).min(tile.size.width as usize);
        let overlap_height = (full.size.height as usize).min(tile.size.height as usize);
        for y in 0..overlap_height {
            for x in 0..overlap_width {
                let tile_alpha = tile.pixels[y * tile.stride + x * 4 + 3];
                let full_alpha = full.pixels[y * full.stride + x * 4 + 3];
                assert_eq!(tile_alpha, full_alpha, "alpha differs at ({x}, {y})");
            }
        }
    }

    #[test]
    fn tiles_are_sharp_when_the_zoom_exceeds_one_texture() {
        let fixture = crate::test_support::fixture("text-page.pdf");
        if !crate::is_available() {
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
        let fixture = crate::test_support::fixture("text-page.pdf");
        if !crate::is_available() {
            eprintln!("skipping: PDFium unavailable");
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
