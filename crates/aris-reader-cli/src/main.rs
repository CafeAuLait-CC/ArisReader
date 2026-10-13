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
//! aris-reader-cli bench <file.pdf> [--pages N]
//! aris-reader-cli corpus <dir|files...> [--search TERM] [--pages N]
//! aris-reader-cli analyze <file.pdf> [--pages N]
//! aris-reader-cli cite <file.pdf> [--body-pages N]
//! ```

use aris_reader_core::{DocumentBackend, EngineConfig, PageIndex, RasterRequest};
use aris_reader_pdfium::{PdfiumBackend, backend_description};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Instant;

const USAGE: &str = "\
aris-reader-cli — ArisReader headless tool

Usage:
  aris-reader-cli version                        print the engine version
  aris-reader-cli config                         print the default engine config
  aris-reader-cli info <file.pdf>                document info (pages, page boxes, rotation)
  aris-reader-cli analyze <file.pdf>             citations, figures, tables, formulas on a page
  aris-reader-cli cite <file.pdf>                match body citations against the reference list
  aris-reader-cli corpus <dir|files...>          what the engine sees in real PDFs
                 [--search TERM] [--pages N]
  aris-reader-cli render <file.pdf>              render one page to PNG
                 [--page N] [--dpi D] [-o out.png]
  aris-reader-cli compare <a.png> <b.png>        compare two renders (mean abs diff, PSNR)
                 [--max-mae F]                   exit non-zero when MAE exceeds F
  aris-reader-cli text <file.pdf> [--page N]     export the text of one page
  aris-reader-cli bench <file.pdf> [--pages N]   rasterization benchmark

Notes:
  `render` and `info` need the PDFium dynamic library (see scripts/fetch-pdfium.sh).
  `text` is implemented in T2.1 and `bench` in T1.13; until then they exit with code 2.
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
        Some("bench") => cmd_bench(rest(&args)),
        Some("corpus") => cmd_corpus(rest(&args)),
        Some("analyze") => cmd_analyze(rest(&args)),
        Some("cite") => cmd_cite(rest(&args)),
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
fn parse(args: &[String]) -> (Vec<String>, Vec<(String, String)>) {
    let mut positional = Vec::new();
    let mut options = Vec::new();
    let mut index = 0;
    while index < args.len() {
        let arg = &args[index];
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

fn opt<'a>(options: &'a [(String, String)], names: &[&str]) -> Option<&'a str> {
    options
        .iter()
        .find(|(key, _)| names.contains(&key.as_str()))
        .map(|(_, value)| value.as_str())
}

fn opt_usize(options: &[(String, String)], names: &[&str], default: usize) -> usize {
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

fn cmd_bench(args: &[String]) -> ExitCode {
    let (positional, options) = parse(args);
    let Some(path) = positional.first() else {
        eprintln!("usage: aris-reader-cli bench <file.pdf> [--pages N]");
        return ExitCode::from(64);
    };
    let pages = opt_usize(&options, &["--pages"], 20);
    let config = EngineConfig::default();
    println!(
        "benchmark plan: {path}, {pages} pages, tile {}px, max LOD {}",
        config.tile_size, config.max_lod
    );
    println!(
        "TODO(T1.13): report per-page/per-tile raster time, throughput (MP/s) and peak memory."
    );
    ExitCode::from(2)
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
        eprintln!("usage: aris-reader-cli cite <file.pdf> [--body-pages N]");
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
    // after it, so a "last N pages" window misses it. The scan stops when the list ends.
    let scan_end = total.min(120);
    let mut texts = Vec::new();
    for index in 0..scan_end {
        if let Ok(text) = backend.raw_text_page(PageIndex(index)) {
            texts.push(text);
        }
    }
    let tail = texts
        .iter()
        .enumerate()
        .map(|(index, text)| (index as u32, text))
        .collect::<Vec<_>>();
    let references = aris_reader_text::find_references(tail, 2000);
    println!("  reference entries parsed: {}", references.len());
    for entry in references.iter().take(3) {
        println!(
            "    [{}] {}",
            entry.label,
            entry.text.chars().take(70).collect::<String>()
        );
    }

    let mut resolved = 0usize;
    let mut attempted = 0usize;
    for index in 0..total.min(body_pages) {
        let Ok(text) = backend.raw_text_page(PageIndex(index)) else {
            continue;
        };

        // One detector for the whole project: the crate produces the labels (including the
        // surname-year keys author-year lists are matched by). The CLI used to re-extract
        // numbers itself, which silently ignored every citation that was not numeric.
        for citation in aris_reader_text::find_citations(&text) {
            if citation.labels.is_empty() {
                continue;
            }
            attempted += 1;

            // One resolver for the whole project: exact label first, then position for a
            // numeric citation against an unnumbered list.
            let hit = aris_reader_text::resolve_reference(&citation.labels, &references);

            if let Some(entry) = hit {
                resolved += 1;
                if resolved <= 5 {
                    println!(
                        "    p{} {} → [{}] {} (at {:.0},{:.0})",
                        index + 1,
                        citation.text,
                        entry.label,
                        entry.text.chars().take(50).collect::<String>(),
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
