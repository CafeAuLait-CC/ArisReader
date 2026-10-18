//! Opt-in regression checks against the local, uncommitted review PDFs.
//!
//! The user handed over seven PDFs they had annotated in Preview
//! (`pdf-samples/with_annotations/`, git-ignored and never committed). Every one of them is the
//! shape that broke the reader:
//!
//! * all 242 text-markup annotations carry an appearance stream, and `FPDFAnnot_GetColor` refuses
//!   **every** annotation that has one — so the reader used to report no colour at all, and the
//!   canvas painted an opaque grey bar over the text;
//! * not one of them states `/BM` on the annotation: Preview puts `/BM /Multiply` in the
//!   appearance stream's `ExtGState`, which PDFium's C ABI does not expose. Reported as
//!   `/Normal`, a yellow highlight at `/CA 0.97` paints over the glyphs instead of tinting them.
//!
//! Two checks per file, both over the markup the canvas actually draws:
//!
//! 1. **What is read**: every markup annotation has a colour (except where the file states no
//!    `/C`), an opacity when it states `/CA`, and the blend it is drawn with.
//! 2. **What is drawn**, pixel by pixel: PDFium renders each page twice — with and without
//!    annotations burned in (`FPDF_ANNOT`, which composites the appearance streams and is the
//!    picture Preview shows) — and the pixel our canvas would produce from the read values is
//!    compared with it. Only pixels that discriminate multiply from alpha-over are sampled, so a
//!    match is evidence about the blend mode and not about white paper.
//!
//! Run with PDFium available and ARIS_READER_PDF_SAMPLES pointing at pdf-samples:
//! `cargo test -p aris-reader-cli --test annotation_corpus -- --ignored --nocapture`
//!
//! The folder is local-only, so the test **announces** that it did not run when it is absent: a
//! green run on a machine without the corpus says nothing about real review PDFs, and the
//! project's rule is that an absent corpus is never a silent pass and never a failure
//! (`tests/reference_eval.rs` follows the same convention).

use aris_reader_core::{
    AnnotationBlend, DocumentBackend, RasterRequest, RasterTile, RawAnnotation, RawAnnotationKind,
    RawTextPage,
};
use aris_reader_pdfium::PdfiumBackend;
use std::path::{Path, PathBuf};

mod common;

/// How far a drawn pixel may sit from the prediction. PDFium writes the appearance stream at the
/// page's own scale and our sample lands on a glyph edge now and then; the measured deviation on
/// a clean sample is ≤2/255, and the alpha-over prediction is off by 20-160/255, so a small
/// tolerance separates "our parameters are the file's" from "they are not" without being loose
/// enough to accept the wrong blend.
const TOLERANCE: f64 = 6.0;

/// A sample only counts when the two predictions differ by at least this much. Over white paper
/// `page × (a·c + 1 − a)` and `a·c + (1 − a)·page` are the same number, and a sample that cannot
/// tell the blends apart must not be counted as evidence for either.
const DISCRIMINATING: f64 = 24.0;

/// Where the seven review PDFs live, unless `ARIS_READER_PDF_SAMPLES` says otherwise.
fn corpus_directory() -> PathBuf {
    common::samples_dir().join("with_annotations")
}

/// The review PDFs, sorted by name, or an announced skip.
fn review_files(directory: &Path) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = match std::fs::read_dir(directory) {
        Ok(entries) => entries
            .filter_map(|entry| entry.ok().map(|entry| entry.path()))
            .filter(|path| path.extension().is_some_and(|extension| extension == "pdf"))
            .collect(),
        Err(_) => Vec::new(),
    };
    files.sort();
    if files.is_empty() {
        println!(
            "skipping the annotate-in-another-viewer checks: no PDFs in {}",
            directory.display()
        );
        println!(
            "  the review PDFs are local-only and never committed; this check is a no-op without \
             them"
        );
        if std::env::var_os("CI").is_some() {
            println!(
                "::notice title=Annotation corpus NOT run::No review PDFs in {} — what a file \
                 annotated in Preview looks like was NOT measured here. The seven PDFs are \
                 git-ignored; put them in pdf-samples/with_annotations/ to run this check.",
                directory.display()
            );
        }
    }
    files
}

/// The colour and opacity an annotation is drawn with, as the canvas computes them.
///
/// Mirrors `AnnotationColor.baked(opacity:)` in `apps/macos`: a multiplied tint is
/// `a·c + (1 − a)·255` at alpha 255, an alpha-over tint is `c` at `a·255`. A markup annotation
/// with no `/C` is drawn in the shell's neutral grey, which carries the file's `/CA`.
struct Tint {
    channels: [f64; 3],
    alpha: f64,
}

impl Tint {
    fn of(annotation: &RawAnnotation) -> Self {
        let opacity = annotation.opacity.unwrap_or(1.0);
        let channels = annotation.color.map_or([0x80, 0x80, 0x80], |color| {
            [color.red, color.green, color.blue]
        });
        let channels = channels.map(f64::from);
        if annotation.blend == AnnotationBlend::Multiply {
            Self {
                channels: channels.map(|channel| opacity * channel + (1.0 - opacity) * 255.0),
                alpha: 1.0,
            }
        } else {
            Self {
                channels,
                alpha: opacity,
            }
        }
    }
}

/// One page rendered by PDFium, with annotations off and on.
struct Renders {
    plain: RasterTile,
    burned: RasterTile,
    scale: f64,
    page_height_pt: f64,
}

impl Renders {
    /// The pixel at a point in **page space** (bottom-left origin), as RGB.
    fn sample(&self, tile: &RasterTile, x_pt: f64, y_pt: f64) -> [f64; 3] {
        let x = (x_pt * self.scale).round().max(0.0) as usize;
        let y = ((self.page_height_pt - y_pt) * self.scale).round().max(0.0) as usize;
        let offset = y.min(tile.size.height as usize - 1) * tile.stride + x * 4;
        // BGRA, the format the whole engine uploads (`RasterFormat::Bgra8Premultiplied`).
        [
            f64::from(tile.pixels[offset + 2]),
            f64::from(tile.pixels[offset + 1]),
            f64::from(tile.pixels[offset]),
        ]
    }

    fn plain_at(&self, x_pt: f64, y_pt: f64) -> [f64; 3] {
        self.sample(&self.plain, x_pt, y_pt)
    }

    fn burned_at(&self, x_pt: f64, y_pt: f64) -> [f64; 3] {
        self.sample(&self.burned, x_pt, y_pt)
    }
}

/// Every markup annotation of a page, with the text layer used to find glyph pixels.
fn markup_of(backend: &PdfiumBackend, page: u32) -> Vec<RawAnnotation> {
    backend
        .annotations(aris_reader_core::PageIndex(page))
        .expect("annotations")
        .into_iter()
        .filter(|annotation| annotation.kind.is_markup())
        .collect()
}

/// Whether the page's text actually covers `(x, y)`, so a sample can be aimed at a glyph.
fn text_covers(text: &RawTextPage, x: f64, y: f64) -> bool {
    text.chars.iter().any(|character| {
        let rect = character.rect;
        rect.size.width > 0.0
            && rect.size.height > 0.0
            && x >= rect.origin.x
            && x <= rect.origin.x + rect.size.width
            && y >= rect.origin.y
            && y <= rect.origin.y + rect.size.height
    })
}

#[test]
#[ignore = "requires the local review PDFs (pdf-samples/with_annotations/) and a PDFium shared library"]
fn review_annotations_are_drawn_with_the_files_own_alpha_and_blend() {
    let directory = corpus_directory();
    let files = review_files(&directory);
    if files.is_empty() {
        return;
    }
    if !aris_reader_pdfium::is_available() {
        println!(
            "skipping the annotate-in-another-viewer checks: PDFium is not available \
             (set ARIS_READER_PDFIUM_PATH)"
        );
        return;
    }

    let mut total_markup = 0usize;
    let mut total_samples = 0usize;
    for path in &files {
        let name = path.file_name().unwrap().to_string_lossy().to_string();
        let backend = PdfiumBackend::open(path, None).expect("open review PDF");
        let mut file_markup = 0usize;
        let mut file_highlights = 0usize;
        let mut file_samples = 0usize;
        let mut file_multiply = 0usize;
        let mut file_alpha_over = 0usize;
        let mut deviations = Vec::new();
        let mut blends = std::collections::BTreeMap::new();
        let mut with_colour = 0usize;
        let mut with_opacity = 0usize;

        for page in 0..backend.page_count() {
            let markup = markup_of(&backend, page);
            if markup.is_empty() {
                continue;
            }
            file_markup += markup.len();
            let text = backend
                .raw_text_page(aris_reader_core::PageIndex(page))
                .unwrap_or_default();
            let page_height_pt = backend
                .page_info(aris_reader_core::PageIndex(page))
                .map(|info| info.geometry.view_size(1.0).height)
                .unwrap_or(842.0);

            let scale = 2.0;
            let plain = backend
                .rasterize(&RasterRequest::full_page(
                    aris_reader_core::PageIndex(page),
                    scale,
                ))
                .expect("page raster");
            let burned = backend
                .rasterize(&{
                    let mut request =
                        RasterRequest::full_page(aris_reader_core::PageIndex(page), scale);
                    request.flags.annotations = true;
                    request
                })
                .expect("page raster with annotations");
            let renders = Renders {
                plain,
                burned,
                scale,
                page_height_pt,
            };

            // Every markup annotation's boxes, for the "is this pixel unambiguous?" filter: a
            // sample painted by two annotations composites two colours and says nothing about
            // either of them.
            let cover: Vec<_> = markup
                .iter()
                .flat_map(|other| {
                    if other.quads.is_empty() {
                        vec![other.rect]
                    } else {
                        other.quads.clone()
                    }
                })
                .collect();

            for annotation in &markup {
                // ── What was read ──
                if annotation.color.is_some() {
                    with_colour += 1;
                }
                if annotation.opacity.is_some() {
                    with_opacity += 1;
                }
                *blends
                    .entry(format!(
                        "{}/{}",
                        annotation.kind.as_str(),
                        annotation.blend.as_str()
                    ))
                    .or_insert(0usize) += 1;
                // Every one of these files was annotated in Preview, which multiplies the three
                // kinds that are drawn through the text. A `normal` here is the defect.
                if matches!(
                    annotation.kind,
                    RawAnnotationKind::Highlight
                        | RawAnnotationKind::Underline
                        | RawAnnotationKind::Strikeout
                ) {
                    assert_eq!(
                        annotation.blend,
                        AnnotationBlend::Multiply,
                        "{name} page {}: a {} must be multiplied, not painted over the text",
                        page + 1,
                        annotation.kind.as_str()
                    );
                }

                // ── What would be drawn ──
                // Highlights only, and that is a measured boundary rather than a convenience.
                // A highlight's appearance fills exactly the rectangle its `/C` and `/CA` describe,
                // so a tint quad is the same picture. An underline's or strikeout's appearance
                // sometimes paints at an alpha its dictionary does not state (measured on
                // `review_ashley_0826.pdf`: `/C [1 0 0]` with no `/CA`, painted at ~15%), and
                // PDFium's C ABI exposes no way to read that alpha out of the appearance — a limit
                // of the dictionary-driven model, recorded here and in the report, not a blend
                // question. The blend and the alpha of *every* markup kind are asserted above.
                if annotation.kind != RawAnnotationKind::Highlight {
                    continue;
                }
                file_highlights += 1;
                let tint = Tint::of(annotation);
                let boxes: Vec<_> = if annotation.quads.is_empty() {
                    vec![annotation.rect]
                } else {
                    annotation.quads.clone()
                };
                for box_rect in boxes {
                    if box_rect.size.width < 8.0 || box_rect.size.height < 5.0 {
                        continue;
                    }
                    for step in 0..12 {
                        let x = box_rect.origin.x
                            + 2.0
                            + (box_rect.size.width - 4.0) * f64::from(step) / 11.0;
                        for fraction in [0.25, 0.45, 0.65] {
                            let y = box_rect.origin.y + box_rect.size.height * fraction;
                            // Aim at the glyphs: over blank paper the two blends agree and the
                            // sample would prove nothing about either.
                            if !text_covers(&text, x, y) {
                                continue;
                            }
                            // …and only where exactly one markup annotation paints, so the
                            // sample is about that annotation's colour and not about a stack.
                            let covering = cover
                                .iter()
                                .filter(|box_rect| {
                                    x >= box_rect.origin.x
                                        && x <= box_rect.origin.x + box_rect.size.width
                                        && y >= box_rect.origin.y
                                        && y <= box_rect.origin.y + box_rect.size.height
                                })
                                .count();
                            if covering != 1 {
                                continue;
                            }
                            let page_pixel = renders.plain_at(x, y);
                            let drawn = renders.burned_at(x, y);
                            let multiply = std::array::from_fn(|channel| {
                                page_pixel[channel]
                                    * (tint.alpha * tint.channels[channel]
                                        + (1.0 - tint.alpha) * 255.0)
                                    / 255.0
                            });
                            let alpha_over = std::array::from_fn(|channel| {
                                tint.alpha * tint.channels[channel]
                                    + (1.0 - tint.alpha) * page_pixel[channel]
                            });
                            let spread = (0..3)
                                .map(|channel| (multiply[channel] - alpha_over[channel]).abs())
                                .fold(0.0, f64::max);
                            if spread < DISCRIMINATING {
                                continue;
                            }
                            let deviation = |prediction: [f64; 3]| {
                                (0..3)
                                    .map(|channel| (drawn[channel] - prediction[channel]).abs())
                                    .fold(0.0, f64::max)
                            };
                            file_samples += 1;
                            if deviation(multiply) <= TOLERANCE {
                                file_multiply += 1;
                            }
                            if deviation(alpha_over) <= TOLERANCE {
                                file_alpha_over += 1;
                            }
                            deviations.push(deviation(multiply));
                        }
                    }
                }
            }
        }

        deviations.sort_by(f64::total_cmp);
        let median = deviations
            .get(deviations.len() / 2)
            .copied()
            .unwrap_or(f64::INFINITY);
        total_markup += file_markup;
        total_samples += file_samples;
        println!("{name}:");
        println!(
            "  {file_markup} markup annotation(s): {with_colour} with a colour, {with_opacity} \
             with an opacity; drawn as {blends:?}"
        );
        if file_highlights == 0 {
            // `review_tang_0905.pdf` is sticky notes only: there is no markup to composite, and
            // the read assertions above are the whole check for it.
            println!("  no highlight to draw on any page — nothing to compare pixel for pixel");
            continue;
        }
        println!(
            "  {file_samples} discriminating glyph pixel(s): {file_multiply} match the gamma-space \
             multiply (median deviation {median:.1}, worst {:.1}), {file_alpha_over} match alpha-over",
            deviations.last().copied().unwrap_or(0.0)
        );
        assert!(
            file_samples >= 4,
            "{name}: too few discriminating glyph pixels ({file_samples}) to say anything about \
             how the file's highlights are composited"
        );
        // The median is the robust half: a handful of annotations whose appearance stream
        // contradicts their own dictionary (measured: 10 samples of 1085 across the corpus, where
        // the stream paints a different colour, or the same one opaquely) cannot move it.
        assert!(
            median <= TOLERANCE,
            "{name}: the typical drawn pixel must be the pixel the file renders              (median deviation {median:.1})"
        );
        assert!(
            file_multiply * 4 >= file_samples * 3,
            "{name}: the canvas's parameters must reproduce the file's own rendering \
             ({file_multiply} of {file_samples} samples matched)"
        );
        assert!(
            file_alpha_over * 10 < file_samples,
            "{name}: alpha-over must not explain the file ({file_alpha_over} of {file_samples} \
             samples matched it)"
        );
    }

    println!(
        "→ {} review PDF(s): {total_markup} markup annotation(s), {total_samples} discriminating \
         pixel(s) compared with PDFium's own rendering of the same files",
        files.len()
    );
    assert!(
        total_samples >= 100,
        "the corpus must offer enough discriminating pixels ({total_samples}) to be evidence"
    );
}
