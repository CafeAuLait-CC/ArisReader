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
    eprintln!("TODO(T2.1): exporting the text of {path} page {page} is not implemented yet.");
    ExitCode::from(2)
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
