//! `aris-reader-cli`: the headless tool.
//!
//! Why it exists: it validates the whole engine path **without a UI** (and without a
//! Swift toolchain), and it is the entry point for golden-image regression tests.
//!
//! ```text
//! aris-reader-cli version
//! aris-reader-cli config
//! aris-reader-cli info <file.pdf>
//! aris-reader-cli render <file.pdf> [--page N] [--dpi D] [-o out.png]
//! aris-reader-cli compare <a.png> <b.png> [--max-mae F]
//! aris-reader-cli text <file.pdf> [--page N]
//! aris-reader-cli annotations <file.pdf>... [--pages N] [--all]
//! aris-reader-cli bench <file.pdf> [--pages N] [--dpi D] [--search TERM]
//! aris-reader-cli corpus <dir|files...> [--search TERM] [--pages N]
//! aris-reader-cli analyze <file.pdf> [--pages N]
//! aris-reader-cli cite <file.pdf> [--body-pages N]
//! aris-reader-cli figures <file.pdf> [--pages N]
//! aris-reader-cli tables <file.pdf>... [--pages N] [--all]
//! aris-reader-cli metadata <file.pdf> [--bibtex]
//! ```

use aris_reader_core::{DocumentBackend, EngineConfig, PageIndex, RasterRequest};
use aris_reader_pdfium::{PdfiumBackend, backend_description};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Instant;

mod bench;

const USAGE: &str = "\
aris-reader-cli — ArisReader headless tool

Usage:
  aris-reader-cli version                        print the engine version
  aris-reader-cli config                         print the default engine config
  aris-reader-cli info <file.pdf>                document info (pages, page boxes, rotation)
  aris-reader-cli analyze <file.pdf>             citations, figures, tables, formulas on a page
  aris-reader-cli cite <file.pdf>                match body citations against the reference list; print
                                                 the detected style and every parenthesised-numeral
                                                 candidate with its accept/reject reason
  aris-reader-cli figures <file.pdf>...          figure/table captions and the region to preview
                 [--pages N]                    (grid / image / page per caption)
  aris-reader-cli tables <file.pdf>...           table previews: grid-derived or full-page fallback
                 [--pages N] [--all]
  aris-reader-cli metadata <file.pdf>            recognised metadata (title, authors, venue, year,
                 [--bibtex]                      DOI, arXiv id) with the source of every field, and
                                                 the BibTeX entry those values generate; --bibtex
                                                 prints only the entry
  aris-reader-cli corpus <dir|files...>          what the engine sees in real PDFs
                 [--search TERM] [--pages N]
  aris-reader-cli render <file.pdf>              render one page to PNG
                 [--page N] [--dpi D] [-o out.png]
  aris-reader-cli compare <a.png> <b.png>        compare two renders (mean abs diff, PSNR)
                 [--max-mae F]                   exit non-zero when MAE exceeds F
  aris-reader-cli text <file.pdf> [--page N]     export the text of one page
  aris-reader-cli annotations <file.pdf>...      dump what the annotation reader found, per page:
                 [--page N] [--pages N] [--all]  subtype, /Rect, /C, /CA, /BM, quad count,
                                                 /NM identity, /IRT parent, /Contents, and the
                                                 draw the canvas would make, plus a reply summary
  aris-reader-cli bench <file.pdf>               measure the engine: first frame, scroll raster
                 [--pages N] [--dpi D]           times, RSS peak, first search results and a
                 [--viewport WxH]                per-page render checksum baseline
                 [--first-frame-scale S] [--repeat N]
                 [--scroll-steps N] [--scroll-step-pt P] [--cache-tiles N]
                 [--search TERM] [--search-limit N]
                 [--skip-first-frame] [--skip-scroll] [--skip-search] [--skip-baseline]
                 [--save-baseline FILE] [--check-baseline FILE]

Bench method — what each number is, and what it is not:
  first frame   open + page info + rasterizing the tiles that cover the initial viewport at
                --first-frame-scale. Run 0 is cold inside the process (it includes loading
                the PDFium dylib and opening the document); later runs are warm. For a cold
                process, invoke the command twice: the first invocation is the cold one.
                GPU upload / composite / present are NOT measured — the CLI has no surface.
  scroll        each step advances the viewport by --scroll-step-pt; the reported time is the
                wall time to rasterize the tiles that step newly needs (cached tiles cost ~0).
                That is raster work per step, not a presented frame: the compositor and the
                display link live in the shell, not here. The cache mirrors the shell's policy
                (tileCacheLimit = 96, counted in tiles, not bytes) and keeps the tile pixels, so
                the RSS number below covers what a scrolling reader actually holds.
  rss-peak      getrusage(RUSAGE_SELF).ru_maxrss, the kernel's own peak resident set size for
                the whole process (bytes on macOS). It covers every phase; use --skip-* to
                attribute it to one phase.
  search        the same page-by-page loop as the FFI search (text layer + find_all), timed
                until the result list is complete; both the first hit and the full call are
                reported. It is the engine path only, without the shell's UI work.
  baseline      the first --pages pages at --dpi, one FNV-1a 64 checksum per page over the raw
                BGRA rows (dimensions included). --save-baseline writes it, --check-baseline
                re-renders and compares, exiting non-zero on any mismatch.
  ARIS_READER_RENDER_STATS=1 adds per-frame and per-cache detail here; the app honours the same
                variable (per-frame log in the FFI, tile-cache counters in the shell).

Notes:
  `render`, `info` and `bench` need the PDFium dynamic library (see scripts/fetch-pdfium.sh).
";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        None | Some("-h" | "--help" | "help") => {
            println!("{USAGE}");
            ExitCode::SUCCESS
        }
        Some("version") => {
            println!(
                "aris-reader-cli {} (engine {}, backend: {})",
                env!("CARGO_PKG_VERSION"),
                aris_reader_core::ENGINE_VERSION,
                backend_description()
            );
            ExitCode::SUCCESS
        }
        Some("config") => {
            let config = EngineConfig::default();
            println!("{config:#?}");
            println!(
                "effective raster threads: {}",
                config.effective_raster_threads()
            );
            ExitCode::SUCCESS
        }
        Some("info") => cmd_info(rest(&args)),
        Some("render") => cmd_render(rest(&args)),
        Some("compare") => cmd_compare(rest(&args)),
        Some("text") => cmd_text(rest(&args)),
        Some("annotations") => cmd_annotations(rest(&args)),
        Some("bench") => cmd_bench(rest(&args)),
        Some("corpus") => cmd_corpus(rest(&args)),
        Some("analyze") => cmd_analyze(rest(&args)),
        Some("cite") => cmd_cite(rest(&args)),
        Some("figures") => cmd_figures(rest(&args)),
        Some("blocks") => cmd_blocks(rest(&args)),
        Some("region") => cmd_region(rest(&args)),
        Some("tables") => cmd_tables(rest(&args)),
        Some("metadata") => cmd_metadata(rest(&args)),
        Some(other) => {
            eprintln!("unknown subcommand: {other}\n");
            println!("{USAGE}");
            ExitCode::from(64)
        }
    }
}

fn rest(args: &[String]) -> &[String] {
    args.get(1..).unwrap_or(&[])
}

/// Minimal argument parsing: `--key value` and `-o value`; everything else is positional.
pub(crate) fn parse(args: &[String]) -> (Vec<String>, Vec<(String, String)>) {
    let mut positional = Vec::new();
    let mut options = Vec::new();
    let mut index = 0;
    while index < args.len() {
        let arg = &args[index];
        if matches!(
            arg.as_str(),
            "--show-misses"
                | "--show-entries"
                | "--no-landings"
                | "--skip-first-frame"
                | "--skip-scroll"
                | "--skip-search"
                | "--skip-baseline"
                | "--prefetch-all-columns"
                | "--bibtex"
        ) {
            options.push((arg.clone(), String::new()));
            index += 1;
            continue;
        }
        if arg.starts_with('-') {
            let value = args.get(index + 1).cloned().unwrap_or_default();
            options.push((arg.clone(), value));
            index += 2;
        } else {
            positional.push(arg.clone());
            index += 1;
        }
    }
    (positional, options)
}

pub(crate) fn opt<'a>(options: &'a [(String, String)], names: &[&str]) -> Option<&'a str> {
    options
        .iter()
        .find(|(key, _)| names.contains(&key.as_str()))
        .map(|(_, value)| value.as_str())
}

pub(crate) fn opt_usize(options: &[(String, String)], names: &[&str], default: usize) -> usize {
    opt(options, names)
        .and_then(|value| value.parse().ok())
        .unwrap_or(default)
}

/// Opens a document, reporting the engine error (with its detail) on failure.
fn open_document(path: &str) -> Result<PdfiumBackend, ExitCode> {
    match PdfiumBackend::open(Path::new(path), None) {
        Ok(backend) => Ok(backend),
        Err(error) => {
            eprintln!("error: {error}");
            Err(ExitCode::from(1))
        }
    }
}

fn cmd_metadata(args: &[String]) -> ExitCode {
    let (positional, options) = parse(args);
    let Some(path) = positional.first() else {
        eprintln!("usage: aris-reader-cli metadata <file.pdf> [--bibtex]");
        return ExitCode::from(64);
    };
    let backend = match open_document(path) {
        Ok(backend) => backend,
        Err(code) => return code,
    };

    let embedded = match backend.embedded_metadata() {
        Ok(metadata) => metadata,
        Err(error) => {
            eprintln!("cannot read embedded metadata from {path}: {error}");
            return ExitCode::FAILURE;
        }
    };
    let first_page = backend.raw_text_page(PageIndex(0)).ok();
    // Text boxes are in unrotated PDF user space, so the recogniser's 20% footer band must be
    // measured against the unrotated crop box, not the rotated view size.
    let page_height = backend
        .page_info(PageIndex(0))
        .map(|info| info.geometry.crop_box.size.height)
        .unwrap_or(842.0);
    let metadata = aris_reader_metadata::recognize(&embedded, first_page.as_ref(), page_height);

    if options.iter().any(|(key, _)| key == "--bibtex") {
        print!("{}", metadata.bibtex());
        return ExitCode::SUCCESS;
    }

    println!("{path}");
    println!("  {:<10} {:<11} value", "field", "source");
    for (name, field) in [
        ("title", &metadata.title),
        ("authors", &metadata.authors),
        ("venue", &metadata.venue),
        ("year", &metadata.year),
        ("doi", &metadata.doi),
        ("arxiv", &metadata.arxiv_id),
    ] {
        let value = if field.is_empty() {
            "(empty)".to_string()
        } else {
            field.text()
        };
        println!(
            "  {:<10} {:<11} {}",
            name,
            field.source_code(),
            preview(&value, 160)
        );
        println!(
            "  {:<10} {:<11} {}{}",
            "",
            field.trust(),
            field.source_label(),
            if field.is_guessed() {
                " · guessed"
            } else {
                ""
            }
        );
    }

    let entry = metadata.bib_entry();
    println!(
        "\n  bibtex     @{} {{{}}}",
        entry.kind().as_str(),
        entry.key()
    );
    print!("{}", metadata.bibtex());
    ExitCode::SUCCESS
}

fn cmd_info(args: &[String]) -> ExitCode {
    let (positional, options) = parse(args);
    let Some(path) = positional.first() else {
        eprintln!("usage: aris-reader-cli info <file.pdf>");
        return ExitCode::from(64);
    };
    let limit = opt_usize(&options, &["--pages"], 8);

    let backend = match open_document(path) {
        Ok(backend) => backend,
        Err(code) => return code,
    };

    let page_count = backend.page_count();
    println!("file      : {path}");
    println!("pages     : {page_count}");
    println!("encrypted : {}", backend.is_encrypted());
    println!("tagged    : {}", backend.is_tagged());
    println!("backend   : {}", backend_description());

    for index in 0..page_count.min(limit as u32) {
        let page_index = PageIndex(index);
        match backend.page_info(page_index) {
            Ok(info) => {
                let geometry = info.geometry;
                let view = geometry.view_size(1.0);
                println!(
                    "  page {index:<4} media {:.0}×{:.0} pt   crop {:.0}×{:.0} @({:.0},{:.0})   /Rotate {}   view {:.0}×{:.0} pt",
                    geometry.media_box.size.width,
                    geometry.media_box.size.height,
                    geometry.crop_box.size.width,
                    geometry.crop_box.size.height,
                    geometry.crop_box.origin.x,
                    geometry.crop_box.origin.y,
                    geometry.rotation.degrees(),
                    view.width,
                    view.height,
                );
            }
            Err(error) => println!("  page {index:<4} error: {error}"),
        }
    }
    ExitCode::SUCCESS
}

/// Dumps what the annotation reader found, page by page, plus the draw the canvas would make.
///
/// This is the measuring instrument for "a highlight from another viewer looks wrong here":
/// every input the canvas uses (`/Subtype`, `/Rect`, `/QuadPoints`, `/C`, `/CA`, `/BM`,
/// visibility) is printed next to the decision it drives, so a wrong picture can be attributed
/// to the read or to the draw instead of guessed at.
///
/// `/BM` is the **effective** blend: the annotation's own when the file states one, and otherwise
/// the mode that kind is composited with (a highlight, underline or strikeout is multiplied by
/// every viewer, including PDFium; see `RawAnnotationKind::default_blend`). Files written by
/// Preview state no `/BM` at all — the multiply lives in the appearance stream — so a dump that
/// printed only the dictionary would say `normal` for a highlight that is drawn multiplied.
///
/// The last line of each annotation is the **effective draw**, in the same terms the shell uses:
///
/// * `multiply` — the tint is `a·c + (1 − a)` over white with alpha 255, which mirrors
///   `AnnotationColor.baked(opacity:)` in `apps/macos` and the GPU's
///   `multiply_with_baked_opacity_matches_pdf` test. PDF composites a `/BM /Multiply`
///   annotation as `page × (a·c + 1 − a)`.
/// * `alpha-over` — the tint carries `c` with the annotation's alpha, which is what
///   `QuadBlend::Normal` blends.
///
/// `--page N` prints one page; `--pages N` caps the scan; `--all` also lists pages with nothing
/// on them (and annotations the reader drops as structural).
fn cmd_annotations(args: &[String]) -> ExitCode {
    let (positional, options) = parse(args);
    if positional.is_empty() {
        eprintln!(
            "usage: aris-reader-cli annotations <file.pdf>... [--page N] [--pages N] [--all]"
        );
        return ExitCode::from(64);
    }
    let only_page = opt(&options, &["--page"]).and_then(|value| value.parse::<u32>().ok());
    let page_cap = opt_usize(&options, &["--pages"], 2000) as u32;
    let show_all = options.iter().any(|(key, _)| key == "--all");

    for path in &positional {
        let backend = match open_document(path) {
            Ok(backend) => backend,
            Err(code) => return code,
        };
        let total = backend.page_count();
        let scan_end = match only_page {
            Some(page) => (page + 1).min(total),
            None => total.min(page_cap),
        };
        let scan_start = only_page.unwrap_or(0);
        if only_page.is_some_and(|page| page >= total) {
            eprintln!("{path}: no page {}", only_page.unwrap_or(0));
            return ExitCode::FAILURE;
        }

        println!("{path}: {total} page(s)");
        let mut account = DrawAccount::default();
        // Kept for the reply summary: a parent can sit on a page printed before or after the
        // reply, so the relationship cannot be resolved one page at a time.
        let mut scanned = Vec::new();
        for index in scan_start..scan_end {
            let annotations = match backend.annotations(PageIndex(index)) {
                Ok(annotations) => annotations,
                Err(error) => {
                    // A page that cannot be read is reported, never silently empty: this dump
                    // exists to tell "nothing there" from "we could not look".
                    println!("  page {}: read failed: {error}", index + 1);
                    return ExitCode::FAILURE;
                }
            };
            scanned.extend(annotations.iter().cloned());
            if annotations.is_empty() && !show_all {
                continue;
            }
            println!(
                "  page {}: {} content annotation(s)",
                index + 1,
                annotations.len()
            );
            for (slot, annotation) in annotations.iter().enumerate() {
                account.count(annotation);
                let rect = annotation.rect;
                println!(
                    "    [{slot}] {:<9} /Rect ({:.1},{:.1} {:.1}×{:.1})  quads={}  /C={}  /CA={}  \
                     /BM={}{}",
                    annotation.kind.as_str(),
                    rect.origin.x,
                    rect.origin.y,
                    rect.size.width,
                    rect.size.height,
                    annotation.quads.len(),
                    annotation.color.map_or_else(
                        || "none".to_string(),
                        |c| format!("#{:02X}{:02X}{:02X}", c.red, c.green, c.blue)
                    ),
                    annotation
                        .opacity
                        .map_or_else(|| "absent".to_string(), |value| format!("{value:.3}")),
                    annotation.blend.as_str(),
                    if annotation.visible { "" } else { "  HIDDEN" },
                );
                // The two keys a note is drawn from, printed next to the draw that uses them —
                // `/DA` is the only place a free-text annotation's size lives, and `/Q` its
                // alignment. Printed for every kind, like the reader reads them.
                println!(
                    "         /DA {}  /Q {}",
                    annotation
                        .font_size_pt
                        .map_or_else(|| "none".to_string(), |size| format!("{size:.1} pt")),
                    annotation.alignment.as_str()
                );
                if let Some(contents) = &annotation.contents {
                    println!("         /Contents: {}", preview(contents, 96));
                }
                if let Some(author) = &annotation.author {
                    println!("         /T: {}", preview(author, 48));
                }
                if annotation.is_reply {
                    println!(
                        "         /IRT -> {}",
                        annotation
                            .parent_id
                            .as_deref()
                            .unwrap_or("unreadable (PDFium could not follow /IRT)")
                    );
                }
                println!("         draw: {}", describe_draw(annotation));
            }
        }
        let replies = ReplyAccount::of(&scanned);
        println!("  → {} · {}", account.summary(), replies.summary());
    }
    ExitCode::SUCCESS
}

/// What a dump accounted for, so "122 annotations the user could not see" has a number that
/// adds up: every content annotation lands in exactly one of these buckets.
#[derive(Default)]
struct DrawAccount {
    markup: usize,
    notes: usize,
    free_text: usize,
    skipped: usize,
    /// How many skips each reason accounts for, in the order the reasons are first seen.
    reasons: Vec<(&'static str, usize)>,
}

impl DrawAccount {
    fn count(&mut self, annotation: &aris_reader_core::RawAnnotation) {
        match annotation.drawing() {
            aris_reader_core::AnnotationDrawing::Markup => self.markup += 1,
            aris_reader_core::AnnotationDrawing::NoteIcon => self.notes += 1,
            aris_reader_core::AnnotationDrawing::FreeText => self.free_text += 1,
            aris_reader_core::AnnotationDrawing::Skipped(reason) => {
                self.skipped += 1;
                let name = reason.as_str();
                match self.reasons.iter_mut().find(|(seen, _)| *seen == name) {
                    Some((_, count)) => *count += 1,
                    None => self.reasons.push((name, 1)),
                }
            }
        }
    }

    /// The file's accounting on one line: what is drawn, and every annotation that is not.
    fn summary(&self) -> String {
        let mut line = format!(
            "{} content annotation(s): {} markup + {} note icon(s) + {} free text drawn, \
             {} skipped",
            self.total(),
            self.markup,
            self.notes,
            self.free_text,
            self.skipped
        );
        if !self.reasons.is_empty() {
            let reasons = self
                .reasons
                .iter()
                .map(|(reason, count)| format!("{count} {reason}"))
                .collect::<Vec<_>>()
                .join(", ");
            line.push_str(&format!(" ({reasons})"));
        }
        line
    }

    fn total(&self) -> usize {
        self.markup + self.notes + self.free_text + self.skipped
    }
}

/// What the dump found out about `/IRT`, separately from what it draws.
///
/// The three numbers answer different questions and are kept apart on purpose:
///
/// * **tied** — the reply's parent identity exists in the scanned annotations, whatever page it
///   is on and whether or not the reader shows it;
/// * **nested** — the whole parent chain is displayable, so the sidebar can indent the reply;
/// * **orphaned** — the reply was read but cannot be nested, with the reason.
///
/// A hidden parent is therefore tied but not nested. Replies themselves are always included in
/// the display set, even when the file hides them: `/F` says what to paint on the page, not
/// whether a review conversation may be read. That is the same rule the Swift sidebar uses.
#[derive(Default)]
struct ReplyAccount {
    replies: usize,
    tied: usize,
    nested: usize,
    orphans: Vec<(&'static str, usize)>,
}

impl ReplyAccount {
    fn of(annotations: &[aris_reader_core::RawAnnotation]) -> Self {
        use std::collections::{HashMap, HashSet};

        let by_id: HashMap<&str, &aris_reader_core::RawAnnotation> = annotations
            .iter()
            .map(|annotation| (annotation.id.as_str(), annotation))
            .collect();
        let displayed: HashSet<&str> = annotations
            .iter()
            .filter(|annotation| annotation.visible || annotation.is_reply)
            .map(|annotation| annotation.id.as_str())
            .collect();

        let mut account = Self::default();
        for annotation in annotations.iter().filter(|annotation| annotation.is_reply) {
            account.replies += 1;
            if annotation
                .parent_id
                .as_deref()
                .is_some_and(|parent| by_id.contains_key(parent))
            {
                account.tied += 1;
            }

            let mut seen = HashSet::new();
            seen.insert(annotation.id.as_str());
            let mut current = annotation;
            let outcome = loop {
                let Some(parent_id) = current.parent_id.as_deref() else {
                    break "unreadable /IRT";
                };
                if !seen.insert(parent_id) {
                    break "reply cycle";
                }
                let Some(parent) = by_id.get(parent_id) else {
                    break "parent not in the reader's list";
                };
                if !displayed.contains(parent_id) {
                    break "parent hidden on the page";
                }
                if !parent.is_reply {
                    break "";
                }
                current = parent;
            };

            if outcome.is_empty() {
                account.nested += 1;
            } else {
                match account
                    .orphans
                    .iter_mut()
                    .find(|(reason, _)| *reason == outcome)
                {
                    Some((_, count)) => *count += 1,
                    None => account.orphans.push((outcome, 1)),
                }
            }
        }
        account
    }

    fn summary(&self) -> String {
        let noun = if self.replies == 1 {
            "reply"
        } else {
            "replies"
        };
        let mut line = format!(
            "{} {noun} ({} tied to a parent in the file, {} shown nested",
            self.replies, self.tied, self.nested
        );
        let orphaned = self.replies - self.nested;
        if orphaned == 0 {
            line.push_str(", 0 orphaned)");
            return line;
        }
        let reasons = self
            .orphans
            .iter()
            .map(|(reason, count)| format!("{count} {reason}"))
            .collect::<Vec<_>>()
            .join(", ");
        line.push_str(&format!(", {orphaned} orphaned: {reasons})"));
        line
    }
}

/// The draw the shell would make for one annotation, in the shell's own terms.
///
/// Reads the reader's own classification ([`RawAnnotation::drawing`]) instead of deciding again,
/// so this dump and the canvas cannot disagree about which annotations are drawn: the only way
/// this prints "skipped" for something the canvas draws is if the canvas stopped reading it.
fn describe_draw(annotation: &aris_reader_core::RawAnnotation) -> String {
    use aris_reader_core::{AnnotationDrawing, AnnotationSkipReason};

    let opacity = annotation.opacity.unwrap_or(1.0);
    let ink = |red: u8, green: u8, blue: u8, alpha: u8| {
        format!("#{red:02X}{green:02X}{blue:02X} at alpha {alpha}")
    };

    match annotation.drawing() {
        AnnotationDrawing::Skipped(reason) => {
            let because = match reason {
                AnnotationSkipReason::Hidden => {
                    "the file sets /F's Hidden, Invisible or NoView bit"
                }
                AnnotationSkipReason::EmptyRect => "its /Rect has no area to draw in",
                AnnotationSkipReason::EmptyContents => "it carries no /Contents to draw",
                AnnotationSkipReason::Unmodelled => {
                    "this build has no drawing rule for that /Subtype"
                }
            };
            format!(
                "skipped ({}: {because}) — the sidebar still lists it",
                reason.as_str()
            )
        }
        // A sticky note is an icon in its own colour: `/C` when the file states one, and the
        // canvas's default note yellow when it does not (see `NoteGlyph` in `apps/macos`).
        AnnotationDrawing::NoteIcon => {
            let colour = annotation
                .color
                .map_or("the default note colour".to_string(), |c| {
                    format!("#{:02X}{:02X}{:02X}", c.red, c.green, c.blue)
                });
            format!("note icon, {colour}, filling /Rect")
        }
        AnnotationDrawing::FreeText => {
            let (red, green, blue) = annotation
                .color
                .map_or((0x80, 0x80, 0x80), |c| (c.red, c.green, c.blue));
            let text = annotation.contents.as_deref().unwrap_or("");
            let size = annotation.font_size_pt.map_or_else(
                || "the shell's default size (the file states no /DA size)".to_string(),
                |size| format!("{size:.1} pt from /DA"),
            );
            format!(
                "free text, {} character(s) at {size}, {}-aligned, in {}",
                text.chars().count(),
                annotation.alignment.as_str(),
                ink(
                    red,
                    green,
                    blue,
                    (opacity * 255.0).round().clamp(0.0, 255.0) as u8
                )
            )
        }
        AnnotationDrawing::Markup => {
            // A missing `/C` is not black: the shell substitutes a neutral grey so the mark is
            // still visible (see `appendDocumentAnnotations` in `apps/macos`).
            let (red, green, blue) = annotation
                .color
                .map_or((0x80, 0x80, 0x80), |c| (c.red, c.green, c.blue));
            match &annotation.blend {
                aris_reader_core::AnnotationBlend::Multiply => {
                    let bake = |channel: u8| {
                        (opacity * f64::from(channel) + (1.0 - opacity) * 255.0).round() as u8
                    };
                    format!(
                        "multiply, /CA {opacity:.3} baked into tint #{:02X}{:02X}{:02X} at alpha \
                         255 (PDF: page × (a·c + 1 − a))",
                        bake(red),
                        bake(green),
                        bake(blue)
                    )
                }
                aris_reader_core::AnnotationBlend::Normal => {
                    let alpha = (opacity * 255.0).round().clamp(0.0, 255.0) as u8;
                    format!(
                        "alpha-over, tint {}, {}",
                        ink(red, green, blue, alpha),
                        if annotation.opacity.is_none() {
                            "the file states no /CA, so this is fully opaque"
                        } else {
                            "the file's own /CA"
                        }
                    )
                }
                aris_reader_core::AnnotationBlend::Other(name) => format!(
                    "alpha-over (the canvas does not implement /BM /{name}), tint {}",
                    ink(
                        red,
                        green,
                        blue,
                        (opacity * 255.0).round().clamp(0.0, 255.0) as u8
                    )
                ),
            }
        }
    }
}

/// One line's worth of a `/Contents` string: newlines folded, long text ellipsised.
fn preview(text: &str, limit: usize) -> String {
    let folded: String = text
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    let trimmed = folded.trim();
    if trimmed.chars().count() <= limit {
        return format!("\"{trimmed}\"");
    }
    let head: String = trimmed.chars().take(limit).collect();
    format!("\"{head}…\"")
}

fn cmd_render(args: &[String]) -> ExitCode {
    let (positional, options) = parse(args);
    let Some(path) = positional.first() else {
        eprintln!("usage: aris-reader-cli render <file.pdf> [--page N] [--dpi D] [-o out.png]");
        return ExitCode::from(64);
    };
    let page = opt_usize(&options, &["--page"], 0);
    let dpi = opt_usize(&options, &["--dpi"], 144);
    let output = opt(&options, &["-o", "--out"])
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(format!("page-{page}.png")));

    let backend = match open_document(path) {
        Ok(backend) => backend,
        Err(code) => return code,
    };

    // 1 PDF point is 1/72 inch, so the raster scale follows directly from the DPI.
    let scale = dpi as f64 / 72.0;
    let page_index = PageIndex(page as u32);

    match backend.page_info(page_index) {
        Ok(info) => {
            let view = info.geometry.view_size(1.0);
            println!(
                "page {page}: view {:.0}×{:.0} pt, /Rotate {} → {:.0}×{:.0} px @ {dpi} dpi",
                view.width,
                view.height,
                info.geometry.rotation.degrees(),
                view.width * scale,
                view.height * scale
            );
        }
        Err(error) => {
            eprintln!("error: {error}");
            return ExitCode::from(1);
        }
    }

    let request = RasterRequest::full_page(page_index, scale);
    let started = Instant::now();
    let tile = match backend.rasterize(&request) {
        Ok(tile) => tile,
        Err(error) => {
            eprintln!("error: {error}");
            return ExitCode::from(1);
        }
    };
    let elapsed = started.elapsed();

    let width = tile.size.width.round() as u32;
    let height = tile.size.height.round() as u32;

    // PDFium hands us BGRA (matching wgpu); PNG wants RGBA.
    let mut rgba = tile.pixels;
    for pixel in rgba.as_chunks_mut::<4>().0 {
        pixel.swap(0, 2);
    }

    if let Err(error) = image::save_buffer(
        &output,
        &rgba,
        width,
        height,
        image::ExtendedColorType::Rgba8,
    ) {
        eprintln!("error: could not write {}: {error}", output.display());
        return ExitCode::from(1);
    }

    let megapixels = (f64::from(width) * f64::from(height)) / 1_000_000.0;
    let seconds = elapsed.as_secs_f64().max(f64::MIN_POSITIVE);
    println!(
        "wrote {} ({}×{} px, {:.2} MP, {:.0} ms, {:.1} MP/s)",
        output.display(),
        width,
        height,
        megapixels,
        elapsed.as_millis(),
        megapixels / seconds
    );
    bench::print_render_stats(width, height, tile.stride, elapsed);
    ExitCode::SUCCESS
}

fn cmd_compare(args: &[String]) -> ExitCode {
    let (positional, options) = parse(args);
    if positional.len() < 2 {
        eprintln!("usage: aris-reader-cli compare <a.png> <b.png> [--max-mae F]");
        return ExitCode::from(64);
    }

    let load = |path: &str| -> Result<image::RgbaImage, ExitCode> {
        match image::open(path) {
            Ok(image) => Ok(image.to_rgba8()),
            Err(error) => {
                eprintln!("error: could not read {path}: {error}");
                Err(ExitCode::from(1))
            }
        }
    };
    let left = match load(&positional[0]) {
        Ok(image) => image,
        Err(code) => return code,
    };
    let right = match load(&positional[1]) {
        Ok(image) => image,
        Err(code) => return code,
    };

    if left.dimensions() != right.dimensions() {
        eprintln!(
            "error: dimension mismatch: {}×{} vs {}×{}",
            left.width(),
            left.height(),
            right.width(),
            right.height()
        );
        return ExitCode::from(2);
    }

    let left_bytes = left.as_raw();
    let right_bytes = right.as_raw();
    let mut sum = 0u64;
    let mut sum_squares = 0u64;
    let mut max_diff = 0u8;
    let mut above_noise = 0u64;

    for (a, b) in left_bytes.iter().zip(right_bytes.iter()) {
        let diff = a.abs_diff(*b);
        sum += u64::from(diff);
        sum_squares += u64::from(diff) * u64::from(diff);
        max_diff = max_diff.max(diff);
        if diff > 8 {
            // Small differences are expected between rasterizers (hinting, AA).
            above_noise += 1;
        }
    }

    let samples = left_bytes.len().max(1) as f64;
    let mean_abs = sum as f64 / samples;
    let mean_square = sum_squares as f64 / samples;
    let psnr = if mean_square > 0.0 {
        10.0 * (255.0f64 * 255.0 / mean_square).log10()
    } else {
        f64::INFINITY
    };

    println!("{}: {}×{}", positional[0], left.width(), left.height());
    println!("{}: {}×{}", positional[1], right.width(), right.height());
    println!("mean abs diff : {mean_abs:.4} / 255");
    println!("PSNR          : {psnr:.2} dB");
    println!("max diff      : {max_diff}");
    println!(
        "samples >8    : {above_noise} ({:.3}% of subpixels)",
        100.0 * above_noise as f64 / samples
    );

    if let Some(threshold) =
        opt(&options, &["--max-mae"]).and_then(|value| value.parse::<f64>().ok())
    {
        if mean_abs > threshold {
            eprintln!("FAIL: mean abs diff {mean_abs:.4} exceeds --max-mae {threshold:.4}");
            return ExitCode::from(1);
        }
        println!("OK: within --max-mae {threshold:.4}");
    }
    ExitCode::SUCCESS
}

fn cmd_text(args: &[String]) -> ExitCode {
    let (positional, options) = parse(args);
    let Some(path) = positional.first() else {
        eprintln!("usage: aris-reader-cli text <file.pdf> [--page N]");
        return ExitCode::from(64);
    };
    let page = opt_usize(&options, &["--page"], 0);

    let backend = match PdfiumBackend::open(Path::new(path), None) {
        Ok(backend) => backend,
        Err(error) => {
            eprintln!("cannot open {path}: {error}");
            return ExitCode::FAILURE;
        }
    };

    match backend.raw_text_page(PageIndex(page as u32)) {
        Ok(text) => {
            // The page string plus a summary on stderr, so `text … > out.txt` stays clean
            // while a human still sees what happened.
            print!("{}", text.text);
            if !text.text.ends_with('\n') {
                println!();
            }
            eprintln!(
                "{} character(s) with boxes, {} text character(s)",
                text.chars.len(),
                text.text.chars().count()
            );
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("cannot read the text layer of {path} page {page}: {error}");
            ExitCode::FAILURE
        }
    }
}

/// `bench`: the T1.13 measurement tool.
///
/// The placeholder this replaces printed a plan and exited 2; every number the milestone
/// criteria ask for (300-page first frame, scroll frame times, RSS peak, first search
/// results, a 20-page checksum baseline) is now measured. The method behind each number —
/// including what the CLI cannot see, which is the GPU — is documented in [`bench`] and
/// summarised in `USAGE`, so a result can be reproduced from `--help` alone.
fn cmd_bench(args: &[String]) -> ExitCode {
    bench::run(args)
}

/// What the engine can actually see in a folder of real PDFs.
///
/// Built for the M4 corpus check: it reports, per file, the numbers that matter for citation
/// and figure work — text coverage, how many link annotations exist versus how many resolved
/// to something actionable, the outline size, search hits, and the cost of a tile and a
/// region render. Synthetic fixtures hid every one of these gaps.
fn cmd_corpus(args: &[String]) -> ExitCode {
    let (positional, options) = parse(args);
    if positional.is_empty() {
        eprintln!("usage: aris-reader-cli corpus <dir-or-files...> [--search TERM] [--pages N]");
        return ExitCode::from(64);
    }

    let search_term = options
        .iter()
        .find(|(key, _)| key == "--search")
        .map(|(_, value)| value.clone())
        .unwrap_or_else(|| "the".to_string());
    let page_cap: u32 = options
        .iter()
        .find(|(key, _)| key == "--pages")
        .and_then(|(_, value)| value.parse().ok())
        .unwrap_or(6);

    let mut paths = Vec::new();
    for entry in &positional {
        let path = PathBuf::from(entry);
        if path.is_dir() {
            if let Ok(entries) = std::fs::read_dir(&path) {
                for entry in entries.flatten() {
                    let candidate = entry.path();
                    let is_pdf = candidate
                        .extension()
                        .map(|extension| extension.eq_ignore_ascii_case("pdf"))
                        .unwrap_or(false);
                    if is_pdf {
                        paths.push(candidate);
                    }
                }
            }
        } else {
            paths.push(path);
        }
    }
    paths.sort();

    println!(
        "{:<46} {:>5} {:>9} {:>7} {:>7} {:>11} {:>7} {:>7} {:>8}",
        "file", "pages", "chars", "links", "resolved", "unresolved", "outline", "hits", "tile+reg"
    );

    let mut unresolved_total = 0usize;
    let mut links_total = 0usize;

    for path in &paths {
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();
        let short: String = name.chars().take(44).collect();

        let backend = match PdfiumBackend::open(path, None) {
            Ok(backend) => backend,
            Err(error) => {
                println!("{short:<46}  open failed: {error}");
                continue;
            }
        };

        let pages = backend.page_count();
        let inspected = pages.min(page_cap);

        let mut chars = 0usize;
        let mut links = 0usize;
        let mut resolved = 0usize;
        let mut hits = 0usize;

        for index in 0..inspected {
            let page = PageIndex(index);
            if let Ok(text) = backend.raw_text_page(page) {
                chars += text.chars.len();
                let haystack: String = text
                    .chars
                    .iter()
                    .filter_map(|character| char::from_u32(character.unicode))
                    .collect();
                hits += aris_reader_text::find_all(&haystack, &search_term).len();
            }
            if let Ok(total) = backend.link_annotation_count(page) {
                links += total;
                if let Ok(targets) = backend.link_targets(page) {
                    resolved += targets.len();
                }
            }
        }

        let outline = backend.outline().map(|nodes| nodes.len()).unwrap_or(0);

        // One tile and one region, timed: the two render paths the preview uses.
        let started = std::time::Instant::now();
        let _ = backend.rasterize(&RasterRequest::tile(
            PageIndex(0),
            2.0,
            (0.0, 0.0),
            (256.0, 256.0),
        ));
        let _ = backend.rasterize(&RasterRequest::tile(
            PageIndex(0),
            2.0,
            (100.0, 100.0),
            (300.0, 200.0),
        ));
        let render_ms = started.elapsed().as_secs_f64() * 1000.0;

        if options.iter().any(|(key, _)| key == "--verbose") {
            let mut histogram: std::collections::BTreeMap<String, usize> =
                std::collections::BTreeMap::new();
            for index in 0..inspected {
                if let Ok(labels) = backend.unresolved_link_actions(PageIndex(index)) {
                    for label in labels {
                        *histogram.entry(label).or_default() += 1;
                    }
                }
            }
            if !histogram.is_empty() {
                println!("    unresolved action types: {histogram:?}");
            }
        }

        let unresolved = links.saturating_sub(resolved);
        unresolved_total += unresolved;
        links_total += links;

        println!(
            "{short:<46} {pages:>5} {chars:>9} {links:>7} {resolved:>7} {unresolved:>11} {outline:>7} {hits:>7} {render_ms:>7.1}ms"
        );
    }

    println!();
    println!(
        "inspected first {page_cap} page(s) per file · search term \"{search_term}\" · \
         {links_total} link annotation(s), {unresolved_total} unresolved"
    );
    if unresolved_total > 0 {
        println!(
            "unresolved links are the capability gap to close next (named /Dest destinations, \
             remote destinations, unsupported actions)"
        );
    }
    ExitCode::SUCCESS
}

/// M4 capability check: can the engine locate the four things a reader wants to follow?
///
/// Reports, per page: image objects (figures) with their boxes, path objects (rules — the only
/// handle on tables and vector figures), citation-like text patterns with their boxes, and how
/// much of the text is set in a mathematical face (formula candidates). Nothing here guesses:
/// each number is something PDFium actually exposes, and the report says plainly where a
/// category has no direct representation in the format.
fn cmd_analyze(args: &[String]) -> ExitCode {
    let (positional, options) = parse(args);
    let Some(path) = positional.first() else {
        eprintln!("usage: aris-reader-cli analyze <file.pdf> [--pages N]");
        return ExitCode::from(64);
    };
    let page_cap: u32 = options
        .iter()
        .find(|(key, _)| key == "--pages")
        .and_then(|(_, value)| value.parse().ok())
        .unwrap_or(4);

    let backend = match PdfiumBackend::open(Path::new(path), None) {
        Ok(backend) => backend,
        Err(error) => {
            eprintln!("cannot open {path}: {error}");
            return ExitCode::FAILURE;
        }
    };

    let pages = backend.page_count().min(page_cap);
    println!(
        "{path}: {} page(s), inspecting {pages}",
        backend.page_count()
    );

    let mut citations_total = 0usize;
    let mut figures_total = 0usize;
    let mut math_chars_total = 0usize;
    let mut chars_total = 0usize;

    for index in 0..pages {
        let page_index = PageIndex(index);

        // Figures and rules come from the page's own object list.
        let (images, paths) = backend
            .page_object_summary(page_index)
            .unwrap_or((Vec::new(), 0));

        // Citations and formulas come from the text layer.
        let text = match backend.raw_text_page(page_index) {
            Ok(text) => text,
            Err(_) => continue,
        };
        let citations = find_citations(&text);
        let math_chars = text
            .chars
            .iter()
            .filter(|character| is_math_font(&character.font_name))
            .count();

        chars_total += text.chars.len();
        math_chars_total += math_chars;
        citations_total += citations.len();
        figures_total += images.len();

        let regions = backend
            .link_targets(page_index)
            .map(|links| links.iter().filter(|link| link.dest_rect.is_some()).count())
            .unwrap_or(0);

        if options.iter().any(|(key, _)| key == "--fonts") {
            let mut fonts: std::collections::BTreeMap<String, usize> =
                std::collections::BTreeMap::new();
            for character in &text.chars {
                *fonts.entry(character.font_name.clone()).or_default() += 1;
            }
            let mut ranked: Vec<(String, usize)> = fonts.into_iter().collect();
            ranked.sort_by_key(|(_, count)| std::cmp::Reverse(*count));
            let top: Vec<String> = ranked
                .iter()
                .take(6)
                .map(|(name, count)| format!("{name}×{count}"))
                .collect();
            println!("        fonts: {}", top.join(", "));
        }

        let captions = aris_reader_text::find_captions(&text);
        let (horizontal, vertical) = backend.page_rules(page_index).unwrap_or_default();
        if !captions.is_empty() || !horizontal.is_empty() {
            println!(
                "        captions {} ({}), rules {}h/{}v, table candidates {}",
                captions.len(),
                captions
                    .iter()
                    .take(3)
                    .map(|caption| format!("{} {}", caption.kind, caption.label))
                    .collect::<Vec<_>>()
                    .join(", "),
                horizontal.len(),
                vertical.len(),
                table_candidates(&horizontal, &vertical)
            );
        }

        println!(
            "  p{:<3} figures {:<3} rules {:<4} citations {:<3} math-chars {:<5}/{:<5} link-regions {}",
            index + 1,
            images.len(),
            paths,
            citations.len(),
            math_chars,
            text.chars.len(),
            regions
        );
        let clickable = citations
            .iter()
            .filter(|(_, rect)| {
                let target = backend.link_targets(page_index).unwrap_or_default();
                target.iter().any(|link| overlaps(link.rect, *rect))
            })
            .count();
        println!(
            "        {clickable} of {} citations sit on a link annotation",
            citations.len()
        );

        for (text, rect) in citations.iter().take(6) {
            println!(
                "        citation {:<16} at ({:.0},{:.0}) {:.0}x{:.0}",
                text, rect.origin.x, rect.origin.y, rect.size.width, rect.size.height
            );
        }
        for image in images.iter().take(4) {
            println!(
                "        figure   at ({:.0},{:.0}) {:.0}x{:.0}",
                image.origin.x, image.origin.y, image.size.width, image.size.height
            );
        }
    }

    let math_share = if chars_total == 0 {
        0.0
    } else {
        math_chars_total as f64 / chars_total as f64 * 100.0
    };
    println!(
        "  → {figures_total} figure object(s), {citations_total} citation pattern(s), {math_share:.2}% of characters in a math face"
    );
    println!(
        "  note: tables have no object type in PDF — only rules plus text alignment suggest them"
    );
    ExitCode::SUCCESS
}

/// Citation-looking spans: `[12]`, `[12,13]`, `[12-14]` and `(Author, 2024)`-style years.
///
/// Returns the text and its box (page space), built from the character boxes so a caller can
/// put a highlight or a preview where the citation actually is.
fn find_citations(text: &aris_reader_core::RawTextPage) -> Vec<(String, aris_reader_core::Rect)> {
    let chars: Vec<char> = text
        .chars
        .iter()
        .filter_map(|character| char::from_u32(character.unicode))
        .collect();
    let mut found = Vec::new();
    let mut index = 0;

    while index < chars.len() {
        // Author-year style: `(He et al. 2024)`, `(Kim and Lee, 2023)`, `(A, 2024; B, 2022)`.
        // Measured on the sample corpus: publishers split roughly evenly between this and the
        // numeric style, and a detector that only knows `[12]` sees nothing at all in half of
        // the papers.
        if chars[index] == '(' {
            let mut close = index + 1;
            while close < chars.len()
                && close - index <= 90
                && chars[close] != ')'
                && chars[close] != '('
            {
                close += 1;
            }
            let inner: String = chars[index + 1..close.min(chars.len())].iter().collect();
            let letters = inner.chars().filter(|c| c.is_alphabetic()).count();
            if close < chars.len() && chars[close] == ')' && letters >= 3 && has_year(&inner) {
                found.push((inner.clone(), union_box(&text.chars[index..=close])));
                index = close + 1;
                continue;
            }
            index += 1;
            continue;
        }

        if chars[index] != '[' {
            index += 1;
            continue;
        }
        // `[` followed by digits, commas, hyphens and spaces, then `]`, capped in length.
        let mut end = index + 1;
        while end < chars.len()
            && end - index <= 12
            && (chars[end].is_ascii_digit()
                || chars[end] == ','
                || chars[end] == '-'
                || chars[end] == ' ')
        {
            end += 1;
        }
        let has_digit = chars[index + 1..end].iter().any(char::is_ascii_digit);
        if end < chars.len() && chars[end] == ']' && has_digit {
            let label: String = chars[index..=end].iter().collect();

            found.push((label, union_box(&text.chars[index..=end])));
            index = end + 1;
        } else {
            index += 1;
        }
    }

    found
}

/// Union of a run of character boxes, in page space — what a highlight or preview needs.
fn union_box(chars: &[aris_reader_core::RawCharBox]) -> aris_reader_core::Rect {
    chars
        .iter()
        .fold(None::<aris_reader_core::Rect>, |acc, character| {
            let rect = character.rect;
            Some(match acc {
                None => rect,
                Some(current) => {
                    let min_x = current.origin.x.min(rect.origin.x);
                    let min_y = current.origin.y.min(rect.origin.y);
                    let max_x = (current.origin.x + current.size.width)
                        .max(rect.origin.x + rect.size.width);
                    let max_y = (current.origin.y + current.size.height)
                        .max(rect.origin.y + rect.size.height);
                    aris_reader_core::Rect::new(min_x, min_y, max_x - min_x, max_y - min_y)
                }
            })
        })
        .unwrap_or(aris_reader_core::Rect::new(0.0, 0.0, 0.0, 0.0))
}

/// Whether a span contains a plausible four-digit year.
fn has_year(text: &str) -> bool {
    let digits: Vec<char> = text.chars().collect();
    digits.windows(4).any(|window| {
        window.iter().all(char::is_ascii_digit) && (window[0] == '1' || window[0] == '2') && {
            let year: u32 = window.iter().collect::<String>().parse().unwrap_or(0);
            (1900..2100).contains(&year)
        }
    })
}

/// Counts table-like grids: horizontal rule pairs bridged by at least two vertical rules.
///
/// Returns the number of **distinct regions**, not of rule pairs: a table with 12 horizontal and
/// 8 vertical rules describes dozens of pairs but is one table. Counting pairs produced a
/// nonsense figure (tens of thousands) the first time this ran, which is why the candidate boxes
/// are merged before being counted.
fn table_candidates(
    horizontal: &[aris_reader_core::Rect],
    vertical: &[aris_reader_core::Rect],
) -> usize {
    let mut regions: Vec<aris_reader_core::Rect> = Vec::new();

    for (index, first) in horizontal.iter().enumerate() {
        for second in horizontal.iter().skip(index + 1) {
            let (upper, lower) = if first.origin.y >= second.origin.y {
                (first, second)
            } else {
                (second, first)
            };
            let gap = upper.origin.y - (lower.origin.y + lower.size.height);
            if !(6.0..=400.0).contains(&gap) {
                continue;
            }

            let left = upper.origin.x.max(lower.origin.x);
            let right = (upper.origin.x + upper.size.width).min(lower.origin.x + lower.size.width);
            if right - left < 40.0 {
                continue;
            }

            let bridging = vertical
                .iter()
                .filter(|rule| {
                    let x = rule.origin.x;
                    x >= left - 2.0
                        && x <= right + 2.0
                        && rule.origin.y <= lower.origin.y + 2.0
                        && rule.origin.y + rule.size.height >= upper.origin.y - 2.0
                })
                .count();
            if bridging < 2 {
                continue;
            }

            // Merge into an existing region when they overlap, so a grid counts once.
            let candidate = aris_reader_core::Rect::new(
                left,
                lower.origin.y,
                right - left,
                upper.origin.y + upper.size.height - lower.origin.y,
            );
            match regions
                .iter_mut()
                .find(|region| overlaps_rect(**region, candidate))
            {
                Some(region) => {
                    let min_x = region.origin.x.min(candidate.origin.x);
                    let min_y = region.origin.y.min(candidate.origin.y);
                    let max_x = (region.origin.x + region.size.width)
                        .max(candidate.origin.x + candidate.size.width);
                    let max_y = (region.origin.y + region.size.height)
                        .max(candidate.origin.y + candidate.size.height);
                    *region =
                        aris_reader_core::Rect::new(min_x, min_y, max_x - min_x, max_y - min_y);
                }
                None => regions.push(candidate),
            }
        }
    }

    regions.len()
}

fn overlaps_rect(a: aris_reader_core::Rect, b: aris_reader_core::Rect) -> bool {
    a.origin.x < b.origin.x + b.size.width
        && b.origin.x < a.origin.x + a.size.width
        && a.origin.y < b.origin.y + b.size.height
        && b.origin.y < a.origin.y + a.size.height
}

/// Whether two page-space boxes overlap (the citation's box and a link's box).
fn overlaps(a: aris_reader_core::Rect, b: aris_reader_core::Rect) -> bool {
    let a_right = a.origin.x + a.size.width;
    let a_top = a.origin.y + a.size.height;
    let b_right = b.origin.x + b.size.width;
    let b_top = b.origin.y + b.size.height;
    a.origin.x < b_right && b.origin.x < a_right && a.origin.y < b_top && b.origin.y < a_top
}

/// Whether a font name belongs to a mathematical face.
fn is_math_font(name: &str) -> bool {
    let upper = name.to_ascii_uppercase();
    [
        "CMMI", "CMSY", "CMEX", "MSAM", "MSBM", "STIX", "MATH", "EUSM", "EUFM", "RSFS",
    ]
    .iter()
    .any(|marker| upper.contains(marker))
}

/// Citation → bibliography matching (M4): does a `[12]` in the body land on a reference entry?
///
/// This is the step that lets a citation be shown *in a floating window* even when the PDF has
/// no link annotation for it: find the number, find the entry, preview the entry.
fn cmd_cite(args: &[String]) -> ExitCode {
    let (positional, options) = parse(args);
    let Some(path) = positional.first() else {
        eprintln!(
            "usage: aris-reader-cli cite <file.pdf> [--body-pages N] [--show-misses] [--show-entries] [--no-landings]"
        );
        return ExitCode::from(64);
    };
    let body_pages: u32 = options
        .iter()
        .find(|(key, _)| key == "--body-pages")
        .and_then(|(_, value)| value.parse().ok())
        .unwrap_or(3);

    let backend = match PdfiumBackend::open(Path::new(path), None) {
        Ok(backend) => backend,
        Err(error) => {
            eprintln!("cannot open {path}: {error}");
            return ExitCode::FAILURE;
        }
    };

    let total = backend.page_count();
    println!("{path}: {total} page(s)");

    // Scan from the front: a reference list can sit a third of the way in, with appendices
    // after it, so a "last N pages" window misses it. The page cap bounds extraction.
    let scan_end = total.min(120);
    let mut texts = Vec::new();
    for index in 0..scan_end {
        if let Ok(text) = backend.raw_text_page(PageIndex(index)) {
            texts.push(text);
        }
    }
    let pages = texts
        .into_iter()
        .map(|text| (text.page.get(), text))
        .collect::<Vec<_>>();

    // Collect candidate link landings; the shared builder validates them against
    // the selected bibliography and rejects sparse/multi-column reconstructions.
    let mut landings: std::collections::BTreeMap<u32, Vec<f64>> = std::collections::BTreeMap::new();
    let provisional =
        aris_reader_text::find_references(pages.iter().map(|(page, text)| (*page, text)), 2000);
    if let Some(first_list_page) = provisional.iter().map(|entry| entry.page).min() {
        for body_page in 0..first_list_page {
            let Ok(links) = backend.link_targets(PageIndex(body_page)) else {
                continue;
            };
            for link in links {
                if let (Some(target), Some(top)) = (link.page, link.dest_top_y)
                    && target.get() >= first_list_page
                {
                    landings.entry(target.get()).or_default().push(top);
                }
            }
        }
    }

    let region = aris_reader_text::locate_reference_region(&pages);
    match region {
        Some(region) => println!(
            "  page-score diagnostic: pages {}..{} (score {:.2}; not the selected bibliography)",
            region.from_page + 1,
            region.to_page + 1,
            region.score
        ),
        None => println!("  page-score diagnostic: no region"),
    }

    let references = if options.iter().any(|(key, _)| key == "--no-landings") {
        provisional
    } else {
        aris_reader_text::find_references_with_landings(&pages, &landings, 2000)
    };
    if let (Some(first), Some(last)) = (references.first(), references.last()) {
        println!(
            "  selected bibliography: pages {}..{}",
            first.page + 1,
            last.page + 1
        );
    }
    println!("  reference entries parsed: {}", references.len());
    // Fragments are the pieces an entry is really drawn in: one for an entry inside a single
    // column on a single page, more when it crosses the gutter or continues on the next page.
    // The preview draws one rectangle per fragment, so this is what it will show.
    let column_splits = references
        .iter()
        .filter(|entry| {
            entry.fragments.len() > 1 && entry.fragments.iter().all(|f| f.page == entry.page)
        })
        .count();
    let cross_page = references
        .iter()
        .filter(|entry| entry.fragments.iter().any(|f| f.page != entry.page))
        .count();
    println!(
        "  entries with more than one fragment: {} (column splits: {column_splits}, cross-page: {cross_page})",
        references
            .iter()
            .filter(|entry| entry.fragments.len() > 1)
            .count()
    );
    let show_all = options.iter().any(|(key, _)| key == "--show-entries");
    for entry in references
        .iter()
        .take(if show_all { usize::MAX } else { 3 })
    {
        println!(
            "    p{} [{}] {}{}",
            entry.page + 1,
            entry.label,
            if show_all {
                entry.text.clone()
            } else {
                entry.text.chars().take(70).collect::<String>()
            },
            fragment_mark(entry)
        );
    }
    // Print the pieces of every split entry, even when the entry list itself is truncated:
    // this is the part of the report the change exists for.
    for entry in references.iter().filter(|entry| entry.fragments.len() > 1) {
        println!(
            "    p{} [{}] → {} fragments",
            entry.page + 1,
            entry.label,
            entry.fragments.len()
        );
        for (index, fragment) in entry.fragments.iter().enumerate() {
            println!(
                "      fragment {}: p{} box {:.1},{:.1} {:.1}×{:.1} pt (page space)",
                index + 1,
                fragment.page + 1,
                fragment.rect.origin.x,
                fragment.rect.origin.y,
                fragment.rect.size.width,
                fragment.rect.size.height
            );
        }
    }

    // One style for the whole document: superscript and bare parenthesised numerals are only
    // reported when the bibliography above carries their labels and the body does not bracket
    // its citations.
    let style = aris_reader_text::CitationStyle::for_document(&pages, &references);
    println!(
        "  citation style: {}",
        citation_style_summary(&style, references.len())
    );

    let mut resolved = 0usize;
    let mut attempted = 0usize;
    for index in 0..total.min(body_pages) {
        let Ok(text) = backend.raw_text_page(PageIndex(index)) else {
            continue;
        };

        // Every bare parenthesised numeral the detector considered, with its decision. This is
        // the inspectable form of the rule set: a reader can see an equation number rejected as
        // right-aligned, or a year rejected as year-shaped, instead of guessing why a span is
        // missing. Candidates are printed even when the document style turns them off — the
        // reason then names the document-level fact that did it.
        for candidate in aris_reader_text::inspect_parenthesised_citations(&text, &style) {
            let labels = if candidate.labels.is_empty() {
                String::new()
            } else {
                format!(" → labels {}", candidate.labels.join(", "))
            };
            println!(
                "    p{} {} {}{} — {}",
                index + 1,
                candidate.text,
                if candidate.accepted {
                    "ACCEPT"
                } else {
                    "REJECT"
                },
                labels,
                candidate.reason
            );
        }

        // One detector for the whole project: the crate produces the labels (including the
        // surname-year keys author-year lists are matched by). The CLI used to re-extract
        // numbers itself, which silently ignored every citation that was not numeric.
        for citation in aris_reader_text::find_citations_with(&text, &style) {
            if citation.labels.is_empty() {
                continue;
            }
            attempted += 1;

            // One resolver for the whole project: exact label first, then position for a
            // numeric citation against an unnumbered list.
            let hit = aris_reader_text::resolve_reference(&citation.labels, &references);

            if options.iter().any(|(key, _)| key == "--show-misses") && hit.is_none() {
                println!(
                    "    p{} MISS {:?} → labels {:?}",
                    index + 1,
                    citation.text.chars().take(28).collect::<String>(),
                    citation.labels
                );
            }

            if let Some(entry) = hit {
                resolved += 1;
                if resolved <= 5 {
                    println!(
                        "    p{} {} → [{}] {}{} (at {:.0},{:.0})",
                        index + 1,
                        citation.text,
                        entry.label,
                        entry.text.chars().take(50).collect::<String>(),
                        fragment_mark(entry),
                        citation.rect.origin.x,
                        citation.rect.origin.y
                    );
                }
            }
        }
    }

    let share = if attempted == 0 {
        0.0
    } else {
        resolved as f64 / attempted as f64 * 100.0
    };
    println!("  → {resolved}/{attempted} citation(s) resolved to an entry ({share:.0}%)");
    ExitCode::SUCCESS
}

/// The detected citation style, in the terms the reader acts on.
///
/// Printed by `cite` so a run is self-describing: whether the bibliography is numeric or
/// author-year, whether the body brackets its numeric citations, and therefore whether bare
/// parenthesised numerals are being read at all.
fn citation_style_summary(style: &aris_reader_text::CitationStyle, entries: usize) -> String {
    let bibliography = if style.bibliography_is_numeric() {
        format!(
            "numeric bibliography ({entries} entries, {} integer labels)",
            style.numeric_label_count()
        )
    } else if style.uses_alphanumeric_labels() {
        format!("alphanumeric-key bibliography ({entries} entries)")
    } else if entries == 0 {
        "no bibliography found".to_string()
    } else {
        format!("author-year bibliography ({entries} entries)")
    };
    let body = if !style.bibliography_is_numeric() {
        "no numeric citation style in the body"
    } else if style.brackets_its_citations() {
        "body cites as [n], so parenthesised numerals are not read as citations"
    } else {
        "body does not bracket its numeric citations"
    };
    let paren = if style.accepts_parenthesised_numerals() {
        "parenthesised numerals ON"
    } else {
        "parenthesised numerals OFF"
    };
    format!("{bibliography}; {body}; {paren}")
}

/// Marks an entry that is drawn in more than one piece, so `cite` output shows which
/// rectangles a preview would draw.
fn fragment_mark(entry: &aris_reader_text::ReferenceEntry) -> String {
    match entry.fragments.len() {
        0 | 1 => String::new(),
        count => format!(" [{count} fragments]"),
    }
}

/// Figure/table index (M4): every caption in the document and the region a floating preview
/// should show for it.
///
/// The point of printing this is that the shell derives the same region through the same crate
/// function ([`aris_reader_text::caption_region`]), called with the same two inputs — the page's
/// image objects and its height — so these numbers describe what a click on `Figure 3` will
/// actually show, not a copy of the rule that drifts from it.
///
/// The region is in **page space** here (bottom-left origin), like every other CLI report; the
/// FFI converts it to view space for the shell.
fn cmd_figures(args: &[String]) -> ExitCode {
    let (positional, options) = parse(args);
    if positional.is_empty() {
        eprintln!("usage: aris-reader-cli figures <file.pdf>... [--pages N]");
        return ExitCode::from(64);
    }
    // A figure index is wanted for the whole readable body, so the cap is flat; the same 120
    // pages bound the reference scan in `cite` and in the FFI.
    let page_cap = opt_usize(&options, &["--pages"], 120) as u32;

    let mut found = 0usize;
    let mut with_image = 0usize;
    let mut with_grid = 0usize;
    for path in &positional {
        match figures_of_file(path, page_cap) {
            Ok((captions, images, grids)) => {
                found += captions;
                with_image += images;
                with_grid += grids;
            }
            Err(code) => return code,
        }
    }

    println!(
        "  → {found} caption(s): {with_grid} table(s) from a grid, {with_image} figure(s) from a \
         raster object, the rest preview the full page"
    );
    ExitCode::SUCCESS
}

/// Prints one line per caption of one file, and returns
/// `(captions, figures paired with a raster object, tables bounded by a grid)`.
fn figures_of_file(path: &str, page_cap: u32) -> Result<(usize, usize, usize), ExitCode> {
    let backend = match PdfiumBackend::open(Path::new(path), None) {
        Ok(backend) => backend,
        Err(error) => {
            eprintln!("cannot open {path}: {error}");
            return Err(ExitCode::FAILURE);
        }
    };

    let total = backend.page_count();
    let scan_end = total.min(page_cap);
    println!("{path}: {total} page(s), scanning {scan_end}");

    let mut found = 0usize;
    let mut with_image = 0usize;
    let mut with_grid = 0usize;
    for index in 0..scan_end {
        let Ok(text) = backend.raw_text_page(PageIndex(index)) else {
            continue;
        };
        // The same inputs the FFI's `figures()` uses, read the same way.
        let (images, _rule_count) = backend
            .page_object_summary(PageIndex(index))
            .unwrap_or_default();
        let page_bounds = backend
            .page_info(PageIndex(index))
            .map(|info| info.geometry.crop_box)
            .unwrap_or_default();
        // Tables are drawn, not placed, so they need the page's vector geometry and its text:
        // a grid is only believed when the cells inside it hold text.
        let rules = backend
            .page_line_segments(PageIndex(index))
            .unwrap_or_default();
        let lines = aris_reader_text::lines_from(&text);
        let evidence = aris_reader_text::PageEvidence {
            images: &images,
            rules: &rules,
            lines: &lines,
        };

        for caption in aris_reader_text::find_captions(&text) {
            found += 1;
            let region = aris_reader_text::caption_region_from(&caption, evidence, page_bounds);
            // Comparing with the no-evidence fallback counts figures whose raster artwork was
            // confidently paired and tables whose grid was found; vector figures and algorithms
            // still preview the full page.
            let fallback = aris_reader_text::caption_region(&caption, &[], page_bounds);
            if region != fallback {
                if caption.kind == "Table" {
                    with_grid += 1;
                } else {
                    with_image += 1;
                }
            }
            let source = if region == fallback {
                "page"
            } else if caption.kind == "Table" {
                "grid"
            } else {
                "image"
            };
            println!(
                "  p{:<3} {:<10} {:<4} {:<5} region ({:>6.1},{:>6.1}) {:>6.1}x{:<6.1}  {}",
                index + 1,
                caption.kind,
                caption.label,
                source,
                region.origin.x,
                region.origin.y,
                region.size.width,
                region.size.height,
                caption.text.chars().take(46).collect::<String>()
            );
        }
    }

    Ok((found, with_image, with_grid))
}

/// Dumps the geometric segmentation of one page: lines, then blocks.
///
/// This is the layer that answers layout questions without semantics — where a column starts and
/// ends, where a paragraph breaks, and (for a bibliography) whether one block really is one entry.
fn cmd_blocks(args: &[String]) -> ExitCode {
    let (positional, options) = parse(args);
    let Some(path) = positional.first() else {
        eprintln!("usage: aris-reader-cli blocks <file.pdf> [--page N] [--gap F]");
        return ExitCode::from(64);
    };
    let page = opt_usize(&options, &["--page"], 0);
    let gap: f64 = options
        .iter()
        .find(|(key, _)| key == "--gap")
        .and_then(|(_, value)| value.parse().ok())
        .unwrap_or(0.8);

    let backend = match PdfiumBackend::open(Path::new(path), None) {
        Ok(backend) => backend,
        Err(error) => {
            eprintln!("cannot open {path}: {error}");
            return ExitCode::FAILURE;
        }
    };
    let Ok(text) = backend.raw_text_page(PageIndex(page as u32)) else {
        eprintln!("cannot read page {page}");
        return ExitCode::FAILURE;
    };

    let degenerate = text
        .chars
        .iter()
        .filter(|character| character.rect.size.width <= 0.0 || character.rect.size.height <= 0.0)
        .count();
    let lines = aris_reader_text::lines_from(&text);
    let blocks = aris_reader_text::blocks_from(&lines, gap);
    println!(
        "page {page}: {} characters ({} degenerate), {} lines, {} blocks (gap {gap})",
        text.chars.len(),
        degenerate,
        lines.len(),
        blocks.len()
    );

    for (index, block) in blocks.iter().enumerate().take(120) {
        println!(
            "  #{:<3} y {:>6.1}..{:<6.1} x {:>6.1}..{:<6.1} lines {:<2} {}",
            index,
            block.rect.origin.y,
            block.rect.origin.y + block.rect.size.height,
            block.rect.origin.x,
            block.rect.origin.x + block.rect.size.width,
            block.lines.len(),
            block.text.chars().take(54).collect::<String>()
        );
    }
    ExitCode::SUCCESS
}

/// The table-preview report: every `Table` caption, and whether its preview is the table.
///
/// This exists because "the fallback is the full page" is a claim that needs a denominator. The
/// numbers it prints — how many captions there are, how many got a grid, and how large those
/// regions are — are the ones quoted in `aris-reader-text::tables`' module docs.
fn cmd_tables(args: &[String]) -> ExitCode {
    let (positional, options) = parse(args);
    if positional.is_empty() {
        eprintln!("usage: aris-reader-cli tables <file.pdf>... [--pages N] [--all]");
        return ExitCode::from(64);
    }
    let page_cap = opt_usize(&options, &["--pages"], 120) as u32;
    let show_all = options.iter().any(|(key, _)| key == "--all");

    let mut caption_total = 0usize;
    let mut grid_total = 0usize;
    let mut widths: Vec<f64> = Vec::new();
    let mut heights: Vec<f64> = Vec::new();

    for path in &positional {
        let backend = match PdfiumBackend::open(Path::new(path), None) {
            Ok(backend) => backend,
            Err(error) => {
                eprintln!("cannot open {path}: {error}");
                return ExitCode::FAILURE;
            }
        };
        let name = Path::new(path)
            .file_name()
            .unwrap()
            .to_string_lossy()
            .to_string();
        let short: String = name.chars().take(26).collect();
        let mut file_captions = 0usize;
        let mut file_grids = 0usize;

        for index in 0..backend.page_count().min(page_cap) {
            let Ok(text) = backend.raw_text_page(PageIndex(index)) else {
                continue;
            };
            let tables: Vec<_> = aris_reader_text::find_captions(&text)
                .into_iter()
                .filter(|caption| caption.kind == "Table")
                .collect();
            if tables.is_empty() {
                continue;
            }
            let rules = backend
                .page_line_segments(PageIndex(index))
                .unwrap_or_default();
            let lines = aris_reader_text::lines_from(&text);
            let (images, _) = backend
                .page_object_summary(PageIndex(index))
                .unwrap_or_default();
            let bounds = backend
                .page_info(PageIndex(index))
                .map(|info| info.geometry.crop_box)
                .unwrap_or_default();

            for caption in tables {
                file_captions += 1;
                let (outcome, grid) =
                    aris_reader_text::tables::table_outcome(&caption, &rules, &lines);
                // The preview the shell shows is the grid plus the caption that labels it.
                let region = aris_reader_text::caption_region_from(
                    &caption,
                    aris_reader_text::PageEvidence {
                        images: &images,
                        rules: &rules,
                        lines: &lines,
                    },
                    bounds,
                );
                if grid.is_some() {
                    file_grids += 1;
                    widths.push(region.size.width);
                    heights.push(region.size.height);
                }
                if show_all || grid.is_none() {
                    match grid {
                        Some(_) => println!(
                            "{short} p{:<3} Table {:<3} {:<9} region ({:>6.1},{:>6.1}) {:>6.1}x{:<6.1}",
                            index + 1,
                            caption.label,
                            outcome.label(),
                            region.origin.x,
                            region.origin.y,
                            region.size.width,
                            region.size.height
                        ),
                        None => println!(
                            "{short} p{:<3} Table {:<3} FALLBACK  [{}] caption ({:>6.1},{:>6.1}) {:>6.1}x{:<6.1}  {}",
                            index + 1,
                            caption.label,
                            outcome.label(),
                            caption.rect.origin.x,
                            caption.rect.origin.y,
                            caption.rect.size.width,
                            caption.rect.size.height,
                            caption.text.chars().take(40).collect::<String>()
                        ),
                    }
                }
            }
        }
        caption_total += file_captions;
        grid_total += file_grids;
        println!("{short}: {file_captions} table caption(s), {file_grids} with a grid region");
    }

    widths.sort_by(f64::total_cmp);
    heights.sort_by(f64::total_cmp);
    let median = |values: &[f64]| values.get(values.len() / 2).copied().unwrap_or(0.0);
    println!(
        "  -> {caption_total} table caption(s), {grid_total} grid-derived, {} fallback to the page",
        caption_total - grid_total
    );
    println!(
        "  -> region width  min {:.0} median {:.0} max {:.0} pt",
        widths.first().copied().unwrap_or(0.0),
        median(&widths),
        widths.last().copied().unwrap_or(0.0)
    );
    println!(
        "  -> region height min {:.0} median {:.0} max {:.0} pt",
        heights.first().copied().unwrap_or(0.0),
        median(&heights),
        heights.last().copied().unwrap_or(0.0)
    );
    ExitCode::SUCCESS
}

/// Prints the reference-list score of every page, so a mis-located region can be explained.
fn cmd_region(args: &[String]) -> ExitCode {
    let (positional, _) = parse(args);
    let Some(path) = positional.first() else {
        eprintln!("usage: aris-reader-cli region <file.pdf>");
        return ExitCode::from(64);
    };

    let backend = match PdfiumBackend::open(Path::new(path), None) {
        Ok(backend) => backend,
        Err(error) => {
            eprintln!("cannot open {path}: {error}");
            return ExitCode::FAILURE;
        }
    };

    let total = backend.page_count();
    let mut pages = Vec::new();
    for index in 0..total.min(120) {
        if let Ok(text) = backend.raw_text_page(PageIndex(index)) {
            pages.push((index, text));
        }
    }

    match aris_reader_text::locate_reference_region(&pages) {
        Some(region) => println!(
            "region: pages {}..{} (score {:.2})",
            region.from_page + 1,
            region.to_page + 1,
            region.score
        ),
        None => println!("region: not found"),
    }

    for (page, text) in &pages {
        let score = aris_reader_text::reference_page_score(text);
        let lines = aris_reader_text::lines_from(text);
        let first = lines
            .first()
            .map(|line| line.text.chars().take(40).collect::<String>())
            .unwrap_or_default();
        let marker = if score >= 1.5 { "REF " } else { "    " };
        println!("  {marker}p{:<3} score {:>6.2}  {first}", page + 1, score);
    }
    ExitCode::SUCCESS
}
