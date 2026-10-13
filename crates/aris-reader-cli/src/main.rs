//! `aris-reader-cli`: headless command-line tool.
//!
//! Value: **it validates the whole engine pipeline with no UI (and even without a Swift toolchain)** —
//! it is also the entry point for route P-C (Rust first) and the golden image regression tests (T1.12).
//!
//! Usage:
//!
//! ```text
//! aris-reader-cli version
//! aris-reader-cli config
//! aris-reader-cli info <file.pdf>
//! aris-reader-cli render <file.pdf> --page 0 --dpi 144 -o page0.png
//! aris-reader-cli text  <file.pdf> --page 0
//! aris-reader-cli bench <file.pdf> [--pages 20]
//! ```

use std::process::ExitCode;

const USAGE: &str = "\
aris-reader-cli — ArisReader headless tool

Usage:
  aris-reader-cli version                        print the engine version
  aris-reader-cli config                         print the default engine config
  aris-reader-cli info <file.pdf>                document info (page count/geometry/metadata)
  aris-reader-cli render <file.pdf>              render one page to PNG
                 [--page N] [--dpi D] [-o out.png]
  aris-reader-cli text <file.pdf> [--page N]     export the text of one page
  aris-reader-cli bench <file.pdf> [--pages N]   rasterization benchmark

Notes:
  Rendering-related subcommands depend on the PDFium backend (tasks T0.7 / T1.3).
  While unimplemented they exit with code 2 and print the corresponding task number.
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
                "aris-reader-cli {} (engine {}, git {})",
                env!("CARGO_PKG_VERSION"),
                aris_reader_core::ENGINE_VERSION,
                option_env!("VERGEN_GIT_SHA").unwrap_or("unknown")
            );
            ExitCode::SUCCESS
        }
        Some("config") => {
            let cfg = aris_reader_core::EngineConfig::default();
            println!("{cfg:#?}");
            println!(
                "effective raster threads: {}",
                cfg.effective_raster_threads()
            );
            ExitCode::SUCCESS
        }
        Some("info") => cmd_info(rest(&args)),
        Some("render") => cmd_render(rest(&args)),
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
    let mut i = 0;
    while i < args.len() {
        let arg = &args[i];
        if arg.starts_with('-') {
            let value = args.get(i + 1).cloned().unwrap_or_default();
            options.push((arg.clone(), value));
            i += 2;
        } else {
            positional.push(arg.clone());
            i += 1;
        }
    }
    (positional, options)
}

fn opt<'a>(options: &'a [(String, String)], names: &[&str]) -> Option<&'a str> {
    options
        .iter()
        .find(|(k, _)| names.contains(&k.as_str()))
        .map(|(_, v)| v.as_str())
}

fn opt_usize(options: &[(String, String)], names: &[&str], default: usize) -> usize {
    opt(options, names)
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn cmd_info(args: &[String]) -> ExitCode {
    let (positional, _) = parse(args);
    let Some(path) = positional.first() else {
        eprintln!("usage: aris-reader-cli info <file.pdf>");
        return ExitCode::from(64);
    };

    if !aris_reader_pdfium::is_available() {
        eprintln!("PDFium unavailable: run ./scripts/fetch-pdfium.sh first (task T0.6)");
        return ExitCode::from(2);
    }

    match aris_reader_pdfium::PdfiumBackend::open(std::path::Path::new(path), None) {
        Ok(_backend) => {
            // TODO(T1.3): print the page count, page geometry, metadata and outline entry count
            println!("{path}: opened (backend implementation pending, T1.3)");
            ExitCode::SUCCESS
        }
        Err(err) => {
            eprintln!("open failed: {err}");
            ExitCode::from(1)
        }
    }
}

fn cmd_render(args: &[String]) -> ExitCode {
    let (positional, options) = parse(args);
    let Some(path) = positional.first() else {
        eprintln!("usage: aris-reader-cli render <file.pdf> [--page N] [--dpi D] [-o out.png]");
        return ExitCode::from(64);
    };
    let page = opt_usize(&options, &["--page"], 0);
    let dpi = opt_usize(&options, &["--dpi"], 144);
    let scale = dpi as f64 / 72.0;

    // Tile geometry computation is already usable (aris-reader-render is implemented), so it can validate scheduling parameters:
    let request =
        aris_reader_core::RasterRequest::full_page(aris_reader_core::PageIndex(page as u32), scale);
    let _ = request;

    eprintln!(
        "TODO(T0.7/T1.3): rendering {path} page {page} @ {dpi} dpi (scale={scale:.3}) is not implemented yet;\n\
         once it is, this command will write a PNG and compare it against the poppler reference image as a golden test (T1.12)."
    );
    ExitCode::from(2)
}

fn cmd_text(args: &[String]) -> ExitCode {
    let (positional, options) = parse(args);
    let Some(path) = positional.first() else {
        eprintln!("usage: aris-reader-cli text <file.pdf> [--page N]");
        return ExitCode::from(64);
    };
    let page = opt_usize(&options, &["--page"], 0);
    eprintln!("TODO(T2.1): exporting text for {path} page {page} is not implemented yet.");
    ExitCode::from(2)
}

fn cmd_bench(args: &[String]) -> ExitCode {
    let (positional, options) = parse(args);
    let Some(path) = positional.first() else {
        eprintln!("usage: aris-reader-cli bench <file.pdf> [--pages N]");
        return ExitCode::from(64);
    };
    let pages = opt_usize(&options, &["--pages"], 20);
    let cfg = aris_reader_core::EngineConfig::default();
    println!(
        "benchmark plan: {path}, {pages} pages, tile {}px, max LOD {}",
        cfg.tile_size, cfg.max_lod
    );
    println!(
        "TODO(T1.13): measure per-page/per-tile raster time, throughput (MP/s) and peak memory."
    );
    ExitCode::from(2)
}
