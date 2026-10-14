//! `bench`: the measurement tool behind T1.13 — first frame, scroll raster times, peak RSS,
//! first search results and a per-page render checksum baseline.
//!
//! # What this measures, and what it deliberately does not
//!
//! Every number this module prints comes from a timer or from the kernel; there are no
//! estimates and no proxies dressed up as the real metric. The one thing it cannot reach is
//! the GPU: `aris-reader-cli` never creates a wgpu surface, so **upload, composite and
//! present are not measured here**. What it measures instead is stated next to each number:
//!
//! * **first frame** — `open` + `page_info` + rasterizing the tiles that cover the initial
//!   viewport at a chosen scale. The first run inside the process is cold (it includes
//!   loading the PDFium dylib and the first page decode); later runs are warm. Across
//!   processes, run the command twice: the first invocation is the cold one. The unified
//!   buffer cache itself cannot be flushed without root (`purge` needs privileges), so "cold"
//!   means a fresh process, not a cold disk — measured honestly rather than implied away, and
//!   the difference is small because `open` is CPU-bound.
//! * **scroll** — for each step, the wall time to rasterize the tiles that step newly needs
//!   (tiles already in the cache cost ~0). This is *raster* work per scroll step, not a
//!   presented frame: the compositor and the display link live in the shell, not here.
//! * **RSS peak** — `getrusage(RUSAGE_SELF).ru_maxrss`, the kernel's own peak resident set
//!   size for the whole process (bytes on macOS). It is the run's peak, so it covers every
//!   phase; `--skip-*` exists to attribute it to one phase.
//! * **first search results** — the same page-by-page loop as the FFI `search` (text layer
//!   plus `aris_reader_text::find_all`), timed until the result list is complete. Both the
//!   first hit and the full call are reported.
//! * **baseline** — the first `--pages` pages rendered at a fixed DPI, with one FNV-1a 64
//!   checksum per page over the raw BGRA rows (dimensions included in the hash). It can be
//!   written with `--save-baseline` and re-checked with `--check-baseline`.
//!
//! The scroll phase reproduces the shell's cache policy instead of the render crate's: the
//! shell's `tileCacheLimit = 96` counts *tiles*, `aris-reader-render::TileCache` is budgeted in
//! bytes, and the app calls neither that cache nor `RenderScheduler` today. The bench's cache
//! therefore evicts least-recently-used tiles once the count exceeds `--cache-tiles`, and it
//! keeps the pixel buffers so peak RSS covers the memory a real reader holds. What it measures
//! is the raster cost the shell pays while scrolling, under the shell's own cache policy.

use aris_reader_core::{DocId, DocumentBackend, EngineConfig, PageIndex, RasterRequest, Rect};
use aris_reader_pdfium::PdfiumBackend;
use aris_reader_render::{Lod, TileKey, visible_tiles};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, Instant};

/// First line of a `--save-baseline` file; parsed back by `--check-baseline`.
const BASELINE_HEADER: &str = "aris-baseline-v1";
/// Gap between pages, in points, mirroring `AppState.pageGapPt` in the shell.
const PAGE_GAP_PT: f64 = 12.0;
/// Default byte budget of the modeled tile cache, mirroring
/// `AppState.defaultTileCacheBudgetMB` in the shell. The two must agree or the bench would
/// report memory for a reader that does not exist (ADR 0007).
const DEFAULT_CACHE_BUDGET_MIB: usize = 48;

/// The resolved measurement plan (all defaults are printed in the header, so an output line
/// can always be traced back to the settings that produced it).
struct Plan {
    path: PathBuf,
    pages: usize,
    dpi: usize,
    viewport: (f64, f64),
    first_frame_scale: f64,
    runs: usize,
    scroll_steps: usize,
    scroll_step_pt: f64,
    /// Byte budget of the modeled tile cache (the shell's ADR 0007 policy).
    cache_bytes: u64,
    /// Optional count ceiling on top of the byte budget; `0` disables it. `96` reproduces the
    /// pre-ADR 0007 shell policy (`tileCacheLimit`), which is what the M1/M2 baseline numbers
    /// were measured under.
    cache_tiles: u64,
    /// Prefetch ring in viewport heights. `None` keeps the shell's adaptive choice — the
    /// longest rung of `PREFETCH_RING_LADDER` whose band fits `band_budget_bytes`;
    /// `--prefetch-ring 2.5` with `--prefetch-all-columns` reproduces ADR 0007's fixed band.
    prefetch_ring: Option<f64>,
    /// Want every column of a page instead of the columns the viewport can reveal (the
    /// pre-change rule; see `band_columns`).
    prefetch_all_columns: bool,
    search: String,
    search_limit: usize,
    skip_first_frame: bool,
    skip_scroll: bool,
    skip_search: bool,
    skip_baseline: bool,
    save_baseline: Option<PathBuf>,
    check_baseline: Option<PathBuf>,
}

impl Plan {
    fn from_args(args: &[String]) -> Result<Self, ExitCode> {
        let (positional, options) = crate::parse(args);
        let Some(path) = positional.first() else {
            eprintln!(
                "usage: aris-reader-cli bench <file.pdf> [--pages N] [--dpi D] [--viewport WxH]\n\
                 \x20      [--first-frame-scale S] [--repeat N] [--scroll-steps N]\n\
                 \x20      [--scroll-step-pt P] [--cache-bytes MiB] [--cache-tiles N]\n\
                 \x20      [--prefetch-ring V] [--prefetch-all-columns]\n\
                 \x20      [--search TERM] [--search-limit N]\n\
                 \x20      [--skip-first-frame] [--skip-scroll] [--skip-search] [--skip-baseline]\n\
                 \x20      [--save-baseline FILE] [--check-baseline FILE]\n\
                 run `aris-reader-cli --help` for the method behind every number"
            );
            return Err(ExitCode::from(64));
        };

        let flag = |name: &str| options.iter().any(|(key, _)| key == name);
        let viewport = match crate::opt(&options, &["--viewport"]) {
            Some(value) => parse_viewport(value).ok_or_else(|| {
                eprintln!("error: --viewport wants WxH in points, e.g. --viewport 959x748");
                ExitCode::from(64)
            })?,
            None => (959.0, 748.0),
        };

        Ok(Self {
            path: PathBuf::from(path),
            pages: crate::opt_usize(&options, &["--pages"], 20),
            dpi: crate::opt_usize(&options, &["--dpi"], 144),
            viewport,
            first_frame_scale: crate::opt(&options, &["--first-frame-scale"])
                .and_then(|value| value.parse().ok())
                .unwrap_or(2.0),
            runs: crate::opt_usize(&options, &["--repeat"], 3).max(1),
            scroll_steps: crate::opt_usize(&options, &["--scroll-steps"], 120),
            scroll_step_pt: crate::opt(&options, &["--scroll-step-pt"])
                .and_then(|value| value.parse().ok())
                .unwrap_or(viewport.1 / 2.0),
            cache_bytes: crate::opt_usize(&options, &["--cache-bytes"], DEFAULT_CACHE_BUDGET_MIB)
                as u64
                * 1024
                * 1024,
            cache_tiles: crate::opt_usize(&options, &["--cache-tiles"], 0) as u64,
            prefetch_ring: match crate::opt(&options, &["--prefetch-ring"]) {
                Some(value) => match value.parse::<f64>() {
                    Ok(ring) if (0.0..=4.0).contains(&ring) => Some(ring),
                    _ => {
                        eprintln!(
                            "error: --prefetch-ring wants viewport heights in [0, 4], e.g. 2.5"
                        );
                        return Err(ExitCode::from(64));
                    }
                },
                None => None,
            },
            prefetch_all_columns: flag("--prefetch-all-columns"),
            search: crate::opt(&options, &["--search"])
                .unwrap_or("the")
                .to_string(),
            search_limit: crate::opt_usize(&options, &["--search-limit"], 500),
            skip_first_frame: flag("--skip-first-frame"),
            skip_scroll: flag("--skip-scroll"),
            skip_search: flag("--skip-search"),
            skip_baseline: flag("--skip-baseline"),
            save_baseline: crate::opt(&options, &["--save-baseline"]).map(PathBuf::from),
            check_baseline: crate::opt(&options, &["--check-baseline"]).map(PathBuf::from),
        })
    }
}

pub(crate) fn run(args: &[String]) -> ExitCode {
    let plan = match Plan::from_args(args) {
        Ok(plan) => plan,
        Err(code) => return code,
    };

    // Timed from before the first PDFium call: the cold first frame includes loading the
    // dylib and opening the document, which is exactly the cost the shell pays once.
    let process_start = Instant::now();
    let backend = match PdfiumBackend::open(Path::new(&plan.path), None) {
        Ok(backend) => backend,
        Err(error) => {
            eprintln!("error: {error}");
            return ExitCode::from(1);
        }
    };
    let open_ms = ms(process_start.elapsed());

    print_header(&plan, &backend);

    if !plan.skip_first_frame {
        phase_first_frame(&plan, &backend, open_ms);
    }
    if !plan.skip_scroll {
        phase_scroll(&plan, &backend);
    }
    if !plan.skip_search {
        phase_search(&plan, &backend);
    }
    let baseline_ok = if plan.skip_baseline {
        true
    } else {
        phase_baseline(&plan, &backend)
    };

    println!(
        "rss-peak: {:.1} MiB (getrusage ru_maxrss, whole process, covers every phase above)",
        peak_rss_bytes() as f64 / (1024.0 * 1024.0)
    );
    if stats_enabled() {
        print_stats_footer(&plan);
    }

    if baseline_ok {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    }
}

// ── The phases ────────────────────────────────────────────────────────────────

/// First frame: open + page info + the tiles that cover the initial viewport.
///
/// Run 0 is cold inside the process (its total includes the open that loaded the PDFium dylib
/// and read the file header); the remaining runs re-rasterize the same tiles and are the warm
/// case. A cold *process* (no OS file cache) is measured by invoking the command twice — see
/// the module docs.
fn phase_first_frame(plan: &Plan, backend: &PdfiumBackend, open_ms: f64) {
    let config = EngineConfig::default();
    let scale = plan.first_frame_scale;
    let lod = Lod::for_scale(scale).min(Lod(config.max_lod));

    let info_started = Instant::now();
    let info = match backend.page_info(PageIndex(0)) {
        Ok(info) => info,
        Err(error) => {
            eprintln!("error: first-frame page info failed: {error}");
            return;
        }
    };
    let info_ms = ms(info_started.elapsed());

    let page_pt = info.geometry.view_size(1.0);
    let page_px = info.geometry.view_size(scale);
    let viewport_px = Rect::new(0.0, 0.0, plan.viewport.0 * scale, plan.viewport.1 * scale);
    let tiles = visible_tiles(page_px, config.tile_size, viewport_px);
    let tile_pt = f64::from(config.tile_size) / scale;

    println!();
    println!(
        "first-frame: viewport {:.0}x{:.0} pt at {scale:.2}x (LOD {}, {} px tiles) -> {} tile(s), {:.2} MP",
        plan.viewport.0,
        plan.viewport.1,
        lod.0,
        config.tile_size,
        tiles.len(),
        megapixels(page_px.width * page_px.height * viewport_fraction(page_px, viewport_px))
    );

    for run in 0..plan.runs {
        let run_started = Instant::now();
        let mut raster_ms = 0.0;
        let mut rastered_mp = 0.0;
        for (col, row) in &tiles {
            let origin = (f64::from(*col) * tile_pt, f64::from(*row) * tile_pt);
            let size = (
                tile_pt.min(page_pt.width - origin.0),
                tile_pt.min(page_pt.height - origin.1),
            );
            if size.0 <= 0.0 || size.1 <= 0.0 {
                continue;
            }
            let request = RasterRequest::tile(PageIndex(0), scale, origin, size);
            let tile_started = Instant::now();
            match backend.rasterize(&request) {
                Ok(tile) => {
                    raster_ms += ms(tile_started.elapsed());
                    rastered_mp += tile.size.width * tile.size.height / 1e6;
                }
                Err(error) => {
                    eprintln!("error: first-frame tile ({col},{row}) failed: {error}");
                    return;
                }
            }
        }
        let total_ms = ms(run_started.elapsed());
        if run == 0 {
            let cold_total_ms = open_ms + info_ms + total_ms;
            println!(
                "  run 0 cold in this process: {cold_total_ms:.1} ms = open {open_ms:.1} + page info {info_ms:.1} + raster {total_ms:.1} ({rastered_mp:.2} MP, {:.0} MP/s)",
                throughput(rastered_mp, raster_ms),
            );
        } else {
            println!(
                "  run {run} warm: {total_ms:.1} ms (raster {raster_ms:.1}, {rastered_mp:.2} MP, {:.0} MP/s)",
                throughput(rastered_mp, raster_ms),
            );
        }
    }
    println!(
        "  note: open covers loading the PDFium dylib and the document; GPU upload/composite/present is not measured (the CLI has no surface)"
    );
}

/// One tile the band wants, with everything the raster loop and the ordering need.
struct WantedTile {
    key: TileKey,
    page: u32,
    origin: (f64, f64),
    size: (f64, f64),
    /// True when the tile intersects the viewport itself (not just the ring): these are the
    /// tiles the reader is actually waiting for.
    visible: bool,
    /// Distance in points from the viewport, the shell's `pumpTiles` ordering.
    distance: f64,
}

/// Longest prefetch ring, in viewport heights: ADR 0007's band, and the ceiling the adaptive
/// ring is allowed to reach. Mirrors `AppState.maxPrefetchRingVh`.
const MAX_PREFETCH_RING_VH: f64 = 2.5;
/// Shortest ring the shell shortens to (`AppState.minPrefetchRingVh`). Measured here: at 0.5 the
/// viewport waits for tiles (p95 8.1 ms, 141 misses over 120 steps); at 1.0 it does not.
const MIN_PREFETCH_RING_VH: f64 = 0.75;
/// Rungs the adaptive ring is chosen from, longest first, ending at the floor
/// (`AppState.prefetchRingLadder`).
const PREFETCH_RING_LADDER: [f64; 6] = [2.5, 2.0, 1.5, 1.25, 1.0, MIN_PREFETCH_RING_VH];
/// Extra columns kept ready to the right of the ones on screen (`AppState`): none, because the
/// canvas left-aligns a page wider than the viewport and there is no horizontal scrolling, so
/// only a widening window can reveal them.
const PREFETCH_COLUMNS_TO_THE_RIGHT: u32 = 0;

/// The byte target for the whole wanted band, mirroring `AppState.prefetchBandBudgetBytes`:
/// half the cache budget, with an 8 MiB floor. The band is the *pinned* set, so a band measured
/// in viewport heights alone is an unbounded commitment in bytes.
fn band_budget_bytes(cache_bytes: u64) -> u64 {
    (cache_bytes / 2).max(8 * 1024 * 1024)
}

/// The ring above and below the viewport, in viewport heights, as distances from the viewport's
/// top edge. Mirrors `AppState.ringSplit`: the viewport is the interval [0, 1] and a ring of `R`
/// viewports is `above + below = 1 + R`, never less than 1 — the band always contains the
/// viewport, whatever the budget says. `down` keeps ADR 0007's 0.5-above / 2.0-below shape.
fn ring_split(ring: f64, down: bool) -> (f64, f64) {
    if down {
        (
            ring * 0.5 / MAX_PREFETCH_RING_VH,
            1.0 + ring * 2.0 / MAX_PREFETCH_RING_VH,
        )
    } else {
        (
            ring * 2.0 / MAX_PREFETCH_RING_VH,
            1.0 + ring * 0.5 / MAX_PREFETCH_RING_VH,
        )
    }
}

/// The columns the band covers on a page: exactly what the viewport can reveal.
/// `--prefetch-all-columns` restores the pre-change rule, which at 400% zoom wanted seven
/// unreachable columns of a ten-column page (24 of 110 tiles).
fn band_columns(
    plan: &Plan,
    cols: u32,
    scale: f64,
    tile_px: u32,
    page_width_pt: f64,
) -> (u32, u32) {
    if plan.prefetch_all_columns {
        return (0, cols);
    }
    let tile_pt = f64::from(tile_px) / scale;
    let visible = ((plan.viewport.0 * scale / f64::from(tile_px)).ceil() as u32).min(cols);
    let last = (visible + PREFETCH_COLUMNS_TO_THE_RIGHT).min(cols).min(
        // Never want a column that does not exist: the page's own width bounds the page.
        ((page_width_pt / tile_pt).ceil() as u32).max(1),
    );
    (0, last.max(1))
}

/// The tiles a band covers, in content points: `[band_top, band_bottom]` vertically, the
/// viewport's columns horizontally.
#[allow(clippy::too_many_arguments)]
fn band_tiles(
    plan: &Plan,
    layouts: &[(u32, f64, f64, f64)],
    band_top: f64,
    band_bottom: f64,
    scroll_y: f64,
    scale: f64,
    tile_px: u32,
    tile_pt: f64,
) -> Vec<WantedTile> {
    let mut out = Vec::new();
    for (page, top, width_pt, height_pt) in layouts {
        // Page-local band, clipped to the page.
        let page_band_top = (band_top - top).max(0.0);
        let page_band_bottom = (band_bottom - top).min(*height_pt);
        if page_band_bottom <= page_band_top {
            continue;
        }
        let rows = (height_pt * scale / f64::from(tile_px)).ceil().max(1.0) as u32;
        let cols = (width_pt * scale / f64::from(tile_px)).ceil().max(1.0) as u32;
        let row0 = (page_band_top * scale / f64::from(tile_px)).floor() as u32;
        let row1 = ((page_band_bottom * scale / f64::from(tile_px)).ceil() as u32).min(rows);
        let (col0, col1) = band_columns(plan, cols, scale, tile_px, *width_pt);
        for row in row0.min(rows)..row1 {
            for col in col0..col1 {
                let origin = (f64::from(col) * tile_pt, f64::from(row) * tile_pt);
                let size = (
                    tile_pt.min(width_pt - origin.0),
                    tile_pt.min(height_pt - origin.1),
                );
                if size.0 <= 0.0 || size.1 <= 0.0 {
                    continue;
                }
                let tile_top = top + origin.1;
                let tile_bottom = tile_top + size.1;
                let tile_left = origin.0;
                let tile_right = tile_left + size.0;
                // A real rectangle intersection: the tile is on screen vertically *and*
                // horizontally (the bench models the shell's left-aligned content, so the
                // viewport starts at x = 0).
                let visible = tile_bottom > scroll_y
                    && tile_top < scroll_y + plan.viewport.1
                    && tile_right > 0.0
                    && tile_left < plan.viewport.0;
                let distance = (scroll_y - tile_bottom)
                    .max(tile_top - (scroll_y + plan.viewport.1))
                    .max(0.0);
                out.push(WantedTile {
                    key: TileKey::new(DocId(1), PageIndex(*page), Lod(1), col, row, 0),
                    page: *page,
                    origin,
                    size,
                    visible,
                    distance,
                });
            }
        }
    }
    out
}

/// The shell's adaptive ring: the longest rung whose band fits `band_budget_bytes`, estimated
/// from the geometry this bench is about to rasterize (full tiles, so the estimate is an upper
/// bound — the shell uses the real, often cropped, cached sizes where it has them).
fn choose_prefetch_ring(
    plan: &Plan,
    layouts: &[(u32, f64, f64, f64)],
    scroll_y: f64,
    scale: f64,
    tile_px: u32,
    tile_pt: f64,
) -> f64 {
    let budget = band_budget_bytes(plan.cache_bytes);
    let full_tile_bytes = u64::from(tile_px) * u64::from(tile_px) * 4;
    for rung in PREFETCH_RING_LADDER {
        let (above, below) = ring_split(rung, true);
        let tiles = band_tiles(
            plan,
            layouts,
            scroll_y - plan.viewport.1 * above,
            scroll_y + plan.viewport.1 * below,
            scroll_y,
            scale,
            tile_px,
            tile_pt,
        );
        if tiles.len() as u64 * full_tile_bytes <= budget {
            return rung;
        }
    }
    *PREFETCH_RING_LADDER.last().unwrap()
}

/// Scroll: per step, rasterize exactly the tiles that step newly needs.
fn phase_scroll(plan: &Plan, backend: &PdfiumBackend) {
    let config = EngineConfig::default();
    // The shell rasterizes at LOD 1 for 100% zoom on a 2x display (`ceil(log2(zoom * scale))`),
    // which is the case the M1/M2 criteria are about; the header prints the resulting scale.
    let lod = Lod(1);
    let scale = lod.scale();
    let tile_px = config.tile_size;
    let tile_pt = f64::from(tile_px) / scale;

    let page_count = backend.page_count();
    let mut layouts = Vec::new();
    let mut content_height = 0.0;
    // Only the pages the scroll can reach are laid out, so a 300-page document does not pay
    // 300 page-info calls when the scroll stops after a few pages.
    for index in 0..page_count {
        let info = match backend.page_info(PageIndex(index)) {
            Ok(info) => info,
            Err(_) => break,
        };
        let view = info.geometry.view_size(1.0);
        layouts.push((index, content_height, view.width, view.height));
        content_height += view.height + PAGE_GAP_PT;
        let reach = plan.scroll_steps as f64 * plan.scroll_step_pt + plan.viewport.1;
        if content_height >= reach {
            break;
        }
    }

    println!();
    println!(
        "scroll: {} step(s) x {:.0} pt over {} page(s) laid out ({} in the document) - viewport {:.0}x{:.0} pt, LOD {} (scale {scale:.0}), {} px tiles, cache {} MiB{}{}",
        plan.scroll_steps,
        plan.scroll_step_pt,
        layouts.len(),
        page_count,
        plan.viewport.0,
        plan.viewport.1,
        lod.0,
        tile_px,
        plan.cache_bytes as f64 / (1024.0 * 1024.0),
        if plan.cache_tiles > 0 {
            format!(" + {} tiles (pre-ADR 0007 policy)", plan.cache_tiles)
        } else {
            String::new()
        },
        match plan.prefetch_ring {
            Some(ring) => format!(
                ", prefetch ring {ring:.2} viewport(s){}",
                if plan.prefetch_all_columns {
                    ", all columns"
                } else {
                    ""
                }
            ),
            None => format!(
                ", prefetch ring adaptive (band <= {:.0} MiB{})",
                band_budget_bytes(plan.cache_bytes) as f64 / (1024.0 * 1024.0),
                if plan.prefetch_all_columns {
                    ", all columns"
                } else {
                    ""
                }
            ),
        },
    );

    let mut cache = PixelCache::new(plan.cache_bytes, plan.cache_tiles as usize);
    let mut frames_ms = Vec::new();
    let mut visible_ms = Vec::new();
    let mut visible_misses = 0u64;
    let mut tiles_rasterized = 0u64;
    let mut rastered_mp = 0.0;
    let mut raster_s = 0.0f64;
    let mut peak_tiles = 0usize;
    let mut peak_band_bytes = 0u64;
    let mut ring_used = plan.prefetch_ring.unwrap_or(0.0);
    let mut skipped_steps = 0usize;

    for step in 0..plan.scroll_steps {
        let scroll_y = step as f64 * plan.scroll_step_pt;
        if scroll_y + plan.viewport.1 > content_height {
            skipped_steps = plan.scroll_steps - step;
            break;
        }

        // The band this step wants, exactly as the shell draws it: the viewport plus a
        // prefetch ring, over the columns the viewport can reveal. `ring` is chosen per step
        // (the shell re-chooses it on every viewport update).
        let ring = match plan.prefetch_ring {
            Some(ring) => ring,
            None => choose_prefetch_ring(plan, &layouts, scroll_y, scale, tile_px, tile_pt),
        };
        ring_used = ring;
        let (above, below) = ring_split(ring, true);
        let band_top = scroll_y - plan.viewport.1 * above;
        let band_bottom = scroll_y + plan.viewport.1 * below;
        let mut wanted = band_tiles(
            plan,
            &layouts,
            band_top,
            band_bottom,
            scroll_y,
            scale,
            tile_px,
            tile_pt,
        );
        // Nearest to the viewport first: `pumpTiles` sorts its queue by distance from the
        // viewport, so the tiles the reader is waiting for are rasterized before the prefetch.
        wanted.sort_by(|a, b| {
            a.distance
                .partial_cmp(&b.distance)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        let step_started = Instant::now();
        let mut hits = 0u64;
        let mut misses = 0u64;
        let mut visible_raster_s = 0.0f64;
        // The whole wanted band is pinned, not just what is on screen: pinning only the visible
        // tiles costs 150-200 MiB of churn at 400% zoom (ADR 0007's measurement, reproduced by
        // `TileCacheChecks`). Everything cached from earlier steps is fair game.
        let pinned: HashSet<TileKey> = wanted.iter().map(|tile| tile.key).collect();

        for tile in &wanted {
            if cache.get(&tile.key) {
                hits += 1;
                continue;
            }
            cache.record_miss();
            misses += 1;
            if tile.visible {
                visible_misses += 1;
            }
            let request = RasterRequest::tile(
                PageIndex(tile.page),
                scale,
                (tile.origin.0, tile.origin.1),
                (tile.size.0, tile.size.1),
            );
            let tile_started = Instant::now();
            match backend.rasterize(&request) {
                Ok(rasterized) => {
                    let elapsed = tile_started.elapsed();
                    raster_s += elapsed.as_secs_f64();
                    if tile.visible {
                        visible_raster_s += elapsed.as_secs_f64();
                    }
                    rastered_mp += rasterized.size.width * rasterized.size.height / 1e6;
                    tiles_rasterized += 1;
                    // The pixels are kept, not just accounted for: peak RSS must
                    // include what a reader that caches tiles actually holds.
                    cache.insert(tile.key, rasterized.pixels);
                }
                Err(error) => {
                    eprintln!("error: scroll tile failed: {error}");
                    return;
                }
            }
        }
        cache.evict_to_fit(&pinned);

        let frame_ms = ms(step_started.elapsed());
        frames_ms.push(frame_ms);
        visible_ms.push(visible_raster_s * 1000.0);
        peak_tiles = peak_tiles.max(cache.len());
        peak_band_bytes = peak_band_bytes.max(cache.bytes_of(&pinned));
        if stats_enabled() {
            println!(
                "  stats frame {step:>4}: {frame_ms:>8.3} ms raster ({:.3} ms of it visible) · {misses} new tile(s) · {hits} cached · ring {ring:.2}",
                visible_raster_s * 1000.0
            );
        }
    }

    if frames_ms.is_empty() {
        println!("  no step fitted in the document; nothing measured");
        return;
    }
    let mut sorted = frames_ms.clone();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let budget = 1000.0 / 60.0;
    let within_budget = sorted.iter().filter(|value| **value <= budget).count();
    let mut visible_sorted = visible_ms.clone();
    visible_sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let visible_within = visible_sorted
        .iter()
        .filter(|value| **value <= budget)
        .count();

    println!(
        "  raster ms per step: p50 {:.3} · p95 {:.3} · max {:.3} · mean {:.3} (n={})",
        percentile(&sorted, 0.50),
        percentile(&sorted, 0.95),
        sorted.last().copied().unwrap_or(0.0),
        sorted.iter().sum::<f64>() / sorted.len() as f64,
        sorted.len(),
    );
    println!(
        "  ... of which the viewport was waiting for (tiles on screen that were not ready): p50 {:.3} · p95 {:.3} · max {:.3} · {visible_misses} visible miss(es), {visible_within}/{} step(s) inside the frame budget",
        percentile(&visible_sorted, 0.50),
        percentile(&visible_sorted, 0.95),
        visible_sorted.last().copied().unwrap_or(0.0),
        visible_sorted.len(),
    );
    println!(
        "  band: ring {ring_used:.2} viewport(s), peak pinned {:.1} MiB / {peak_tiles} tile(s) (whole cache) · stale after eviction {:.1} MiB",
        peak_band_bytes as f64 / (1024.0 * 1024.0),
        cache.used_bytes() as f64 / (1024.0 * 1024.0),
    );
    println!(
        "  steps whose raster work fits one 60 fps frame (<= {budget:.1} ms): {within_budget}/{} ({:.1}%)",
        sorted.len(),
        100.0 * within_budget as f64 / sorted.len() as f64
    );
    println!(
        "  tiles rasterized {tiles_rasterized} · cache hits {} · misses {} · hit rate {:.1}% · evictions {} ({:.1} MiB) · peak occupancy {} tile(s) / {:.1} MiB of a {:.0} MiB budget",
        cache.hits,
        cache.misses,
        cache.hit_rate() * 100.0,
        cache.evictions,
        cache.evicted_bytes() as f64 / (1024.0 * 1024.0),
        peak_tiles,
        cache.peak_bytes() as f64 / (1024.0 * 1024.0),
        cache.budget_bytes() as f64 / (1024.0 * 1024.0),
    );
    println!(
        "  cache holds {:.1} MiB in {} tile(s) when the scroll ends",
        cache.used_bytes() as f64 / (1024.0 * 1024.0),
        cache.len(),
    );
    println!(
        "  rasterized {rastered_mp:.1} MP in {raster_s:.2} s of raster time -> {:.0} MP/s",
        throughput(rastered_mp, raster_s * 1000.0)
    );
    if skipped_steps > 0 {
        println!(
            "  note: {skipped_steps} step(s) skipped at the end of the laid-out content ({content_height:.0} pt)"
        );
    }
    println!(
        "  note: these are raster times, not presented frames - no GPU upload/composite/present happens in the CLI"
    );
}

/// First search results: the FFI's own loop, timed.
fn phase_search(plan: &Plan, backend: &PdfiumBackend) {
    if plan.search.trim().is_empty() {
        println!("\nsearch: skipped (empty term)");
        return;
    }

    println!();
    println!(
        "search: \"{}\" limit {} - same loop as the FFI: per page, text layer + find_all",
        plan.search, plan.search_limit
    );
    let started = Instant::now();
    let mut first_hit_ms = None;
    let mut hits = 0usize;
    let mut pages_scanned = 0u32;
    let page_count = backend.page_count();

    'pages: for page in 0..page_count {
        let raw = match backend.raw_text_page(PageIndex(page)) {
            Ok(raw) => raw,
            Err(error) => {
                eprintln!("  page {page}: text layer failed: {error}");
                continue;
            }
        };
        pages_scanned += 1;
        let haystack: String = raw
            .chars
            .iter()
            .map(|character| {
                char::from_u32(character.unicode).unwrap_or(char::REPLACEMENT_CHARACTER)
            })
            .collect();
        for _hit in aris_reader_text::find_all(&haystack, &plan.search) {
            if first_hit_ms.is_none() {
                first_hit_ms = Some(ms(started.elapsed()));
            }
            hits += 1;
            if hits >= plan.search_limit {
                break 'pages;
            }
        }
    }
    let total_ms = ms(started.elapsed());

    let first = first_hit_ms
        .map(|value| format!("{value:.1} ms"))
        .unwrap_or_else(|| "no hit".to_string());
    println!(
        "  results in {total_ms:.1} ms (first hit at {first}) - scanned {pages_scanned}/{page_count} page(s), {hits} hit(s)"
    );
    println!(
        "  note: this is the engine path only; the shell's UI work on top of it is not measured here"
    );
}

/// The per-page render checksum baseline; returns false when a `--check-baseline` fails.
fn phase_baseline(plan: &Plan, backend: &PdfiumBackend) -> bool {
    let scale = plan.dpi as f64 / 72.0;
    let page_count = backend.page_count().min(plan.pages as u32);

    println!();
    println!(
        "baseline: {page_count} page(s) at {} dpi (scale {scale:.2}) - FNV-1a 64 over each page's BGRA rows (dimensions included)",
        plan.dpi
    );

    let mut records = Vec::new();
    let mut total_ms = 0.0;
    let mut total_mp = 0.0;
    for page in 0..page_count {
        let request = RasterRequest::full_page(PageIndex(page), scale);
        let started = Instant::now();
        let tile = match backend.rasterize(&request) {
            Ok(tile) => tile,
            Err(error) => {
                eprintln!("error: page {page} failed: {error}");
                return false;
            }
        };
        let elapsed_ms = ms(started.elapsed());
        let width = tile.size.width.round() as u32;
        let height = tile.size.height.round() as u32;
        let checksum = checksum_bgra(&tile.pixels, tile.stride, width, height);
        let mean = mean_rgb(&tile.pixels, tile.stride, width, height);
        let mp = f64::from(width) * f64::from(height) / 1e6;
        total_ms += elapsed_ms;
        total_mp += mp;

        println!(
            "  page {page:>3}  {width}x{height} px  {elapsed_ms:>8.2} ms  {mp:>5.2} MP  {:>7.1} MP/s  mean {mean:>6.1}  {checksum:016x}",
            throughput(mp, elapsed_ms),
        );
        records.push(BaselineRecord {
            page,
            width,
            height,
            mean,
            checksum,
        });
    }
    println!(
        "  {page_count} page(s): {total_ms:.1} ms · {total_mp:.1} MP · {:.0} MP/s",
        throughput(total_mp, total_ms)
    );

    if let Some(path) = &plan.save_baseline {
        match write_baseline(path, plan, &records) {
            Ok(()) => println!("  wrote {}", path.display()),
            Err(error) => {
                eprintln!("error: could not write {}: {error}", path.display());
                return false;
            }
        }
    }

    if let Some(path) = &plan.check_baseline {
        match check_baseline(path, &records) {
            Ok(mismatches) => {
                for line in &mismatches {
                    eprintln!("  MISMATCH {line}");
                }
                if mismatches.is_empty() {
                    println!(
                        "  baseline check OK against {} ({} page(s))",
                        path.display(),
                        records.len()
                    );
                } else {
                    eprintln!(
                        "  baseline check FAILED against {}: {} mismatch(es)",
                        path.display(),
                        mismatches.len()
                    );
                    return false;
                }
            }
            Err(error) => {
                eprintln!("error: could not read {}: {error}", path.display());
                return false;
            }
        }
    }
    true
}

// ── Baseline files ────────────────────────────────────────────────────────────

struct BaselineRecord {
    page: u32,
    width: u32,
    height: u32,
    mean: f64,
    checksum: u64,
}

fn write_baseline(path: &Path, plan: &Plan, records: &[BaselineRecord]) -> std::io::Result<()> {
    let mut out = String::new();
    out.push_str(&format!(
        "{BASELINE_HEADER} file={} dpi={} scale={:.2} pdfium={}\n",
        plan.path.display(),
        plan.dpi,
        plan.dpi as f64 / 72.0,
        pdfium_version(),
    ));
    for record in records {
        out.push_str(&format!(
            "page {} {}x{} mean={:.1} fnv1a64={:016x}\n",
            record.page, record.width, record.height, record.mean, record.checksum
        ));
    }
    std::fs::write(path, out)
}

/// Compares a recorded baseline against this run, returning one line per difference.
fn check_baseline(path: &Path, records: &[BaselineRecord]) -> std::io::Result<Vec<String>> {
    let text = std::fs::read_to_string(path)?;
    let mut mismatches = Vec::new();
    let mut seen = 0usize;

    for line in text.lines() {
        if line.starts_with(BASELINE_HEADER) || line.trim().is_empty() {
            continue;
        }
        let fields: Vec<&str> = line.split_whitespace().collect();
        // page <n> <w>x<h> mean=<m> fnv1a64=<hex>
        if fields.len() < 5 || fields[0] != "page" {
            mismatches.push(format!("unrecognised line: {line}"));
            continue;
        }
        let Ok(page) = fields[1].parse::<u32>() else {
            mismatches.push(format!("unrecognised page number: {line}"));
            continue;
        };
        let Some(record) = records.iter().find(|record| record.page == page) else {
            mismatches.push(format!(
                "page {page} is in the baseline but not in this run"
            ));
            continue;
        };
        seen += 1;
        let expected_size = fields[2];
        let actual_size = format!("{}x{}", record.width, record.height);
        if expected_size != actual_size {
            mismatches.push(format!(
                "page {page}: size {actual_size}, baseline {expected_size}"
            ));
            continue;
        }
        let expected = fields
            .iter()
            .find_map(|field| field.strip_prefix("fnv1a64="))
            .unwrap_or("")
            .to_string();
        let actual = format!("{:016x}", record.checksum);
        if expected != actual {
            mismatches.push(format!(
                "page {page}: checksum {actual}, baseline {expected}"
            ));
        }
    }

    if seen < records.len() {
        for record in records.iter().skip(seen) {
            mismatches.push(format!(
                "page {} is in this run but not in the baseline",
                record.page
            ));
        }
    }
    Ok(mismatches)
}

// ── The scroll phase's cache ─────────────────────────────────────────────────

/// The scroll phase's cache: **byte budget + LRU + pinned set**, the shell's policy (ADR 0007).
///
/// Deliberately not `aris-reader-render::TileCache` — ADR 0007 puts the hot-path cache in the
/// shell, and this is the *policy* model, not the production cache. What it must not do is
/// describe a reader that no longer exists: the bench used to mirror the shell's
/// `tileCacheLimit = 96` **tile count**, and a count is not a memory bound (measured: the shell
/// held 110 tiles / 94 MiB at 400% zoom). So the budget is in bytes, spent from the real pixel
/// buffers the bench keeps, and the tiles the current step shows are pinned.
///
/// `--cache-tiles N` remains as an extra count ceiling for reproducing pre-ADR numbers
/// (`--cache-tiles 96`); `0` (the default) leaves the byte budget alone. The bench scrolls at
/// one fixed LOD, so the shell's LOD-aware eviction order has nothing to choose between here.
struct PixelCache {
    budget_bytes: u64,
    /// Optional count ceiling on top of the byte budget; `0` disables it.
    count_limit: usize,
    /// key → (pixels, last-used tick)
    pixels: HashMap<TileKey, (Vec<u8>, u64)>,
    tick: u64,
    /// The tile inserted most recently, protected in the eviction pass that follows it.
    newest: Option<TileKey>,
    hits: u64,
    misses: u64,
    evictions: u64,
    evicted_bytes: u64,
    peak_bytes: u64,
}

impl PixelCache {
    fn new(budget_bytes: u64, count_limit: usize) -> Self {
        Self {
            budget_bytes,
            count_limit,
            pixels: HashMap::new(),
            tick: 0,
            newest: None,
            hits: 0,
            misses: 0,
            evictions: 0,
            evicted_bytes: 0,
            peak_bytes: 0,
        }
    }

    /// Cache lookup; a hit refreshes the entry's position in the LRU order.
    fn get(&mut self, key: &TileKey) -> bool {
        self.tick += 1;
        let tick = self.tick;
        match self.pixels.get_mut(key) {
            Some((_, last_used)) => {
                *last_used = tick;
                self.hits += 1;
                true
            }
            None => false,
        }
    }

    fn record_miss(&mut self) {
        self.misses += 1;
    }

    fn insert(&mut self, key: TileKey, pixels: Vec<u8>) {
        // Replacing a tile must not double-count its bytes: the old buffer is dropped here.
        self.pixels.remove(&key);
        self.tick += 1;
        self.pixels.insert(key, (pixels, self.tick));
        self.newest = Some(key);
        self.peak_bytes = self.peak_bytes.max(self.used_bytes_inner());
    }

    /// Evicts until the budget and any count ceiling are met, skipping pinned tiles and the
    /// newest insert. The caller passes the tiles the current step shows as `pinned`.
    fn evict_to_fit(&mut self, pinned: &HashSet<TileKey>) {
        while self.used_bytes_inner() > self.budget_bytes
            || (self.count_limit > 0 && self.pixels.len() > self.count_limit)
        {
            let victim = self
                .pixels
                .iter()
                .filter(|(key, _)| !pinned.contains(*key) && Some(**key) != self.newest)
                .min_by_key(|(_, (_, last_used))| *last_used)
                .map(|(key, _)| *key);
            let Some(key) = victim else {
                // Everything left is pinned (or is the newest insert): the budget yields rather
                // than dropping something the reader is looking at.
                break;
            };
            if let Some((pixels, _)) = self.pixels.remove(&key) {
                self.evicted_bytes += pixels.len() as u64;
            }
            self.evictions += 1;
        }
    }

    fn len(&self) -> usize {
        self.pixels.len()
    }

    fn used_bytes(&self) -> u64 {
        self.used_bytes_inner()
    }

    /// Bytes held for a set of keys — the pinned band's share of the cache, which is what the
    /// band's byte target is about.
    fn bytes_of(&self, keys: &HashSet<TileKey>) -> u64 {
        keys.iter()
            .filter_map(|key| self.pixels.get(key))
            .map(|(pixels, _)| pixels.len() as u64)
            .sum()
    }

    fn used_bytes_inner(&self) -> u64 {
        self.pixels
            .values()
            .map(|(pixels, _)| pixels.len() as u64)
            .sum()
    }

    fn budget_bytes(&self) -> u64 {
        self.budget_bytes
    }

    fn peak_bytes(&self) -> u64 {
        self.peak_bytes
    }

    fn evicted_bytes(&self) -> u64 {
        self.evicted_bytes
    }

    fn hit_rate(&self) -> f64 {
        let total = self.hits + self.misses;
        if total == 0 {
            0.0
        } else {
            self.hits as f64 / total as f64
        }
    }
}

// ── Header, stats, helpers ────────────────────────────────────────────────────

fn print_header(plan: &Plan, backend: &PdfiumBackend) {
    let config = EngineConfig::default();
    let size = std::fs::metadata(&plan.path)
        .map(|metadata| metadata.len())
        .unwrap_or(0);

    println!("bench: {}", plan.path.display());
    println!(
        "machine    : {} {} · {} logical core(s) · effective raster threads {} (EngineConfig default)",
        std::env::consts::OS,
        std::env::consts::ARCH,
        std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(0),
        config.effective_raster_threads(),
    );
    println!("pdfium     : {}", pdfium_version());
    println!(
        "engine cfg : tile {} px · max LOD {} · gpu cache {} MiB · cpu bitmap {} MiB · disk cache {} · rasterize is serialized process-wide (see docs/09 §4)",
        config.tile_size,
        config.max_lod,
        config.cache.gpu_texture_bytes / (1024 * 1024),
        config.cache.cpu_bitmap_bytes / (1024 * 1024),
        match config.cache.disk_bytes {
            0 => "disabled",
            _ => "enabled",
        },
    );
    println!(
        "document   : {} page(s) · {:.2} MiB · tagged {} · encrypted {}",
        backend.page_count(),
        size as f64 / (1024.0 * 1024.0),
        backend.is_tagged(),
        backend.is_encrypted(),
    );
    println!(
        "plan       : baseline {} page(s) @ {} dpi · viewport {:.0}x{:.0} pt · first-frame scale {:.2} · {} run(s) · scroll {} x {:.0} pt",
        plan.pages,
        plan.dpi,
        plan.viewport.0,
        plan.viewport.1,
        plan.first_frame_scale,
        plan.runs,
        plan.scroll_steps,
        plan.scroll_step_pt,
    );
}

/// The headless half of the documented `ARIS_READER_RENDER_STATS=1` switch: per-frame and
/// per-cache detail on top of the aggregate report. The app honours the same variable — the
/// FFI logs every frame and the shell reports its tile-cache hit rate — so one switch covers
/// both sides of the measurement. See docs/09 §9.
fn print_stats_footer(plan: &Plan) {
    println!(
        "stats: ARIS_READER_RENDER_STATS=1 · per-frame lines above are raster ms per scroll step · tile cache budget {} MiB{} (mirrors the shell's ADR 0007 policy) · the in-app HUD (Metal frame times, Swift tile cache) is not part of this CLI",
        plan.cache_bytes / (1024 * 1024),
        if plan.cache_tiles > 0 {
            format!(" capped at {} tiles", plan.cache_tiles)
        } else {
            String::new()
        },
    );
}

fn stats_enabled() -> bool {
    std::env::var("ARIS_READER_RENDER_STATS")
        .map(|value| value == "1" || value.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

/// Extra `render` output under `ARIS_READER_RENDER_STATS=1` — the same switch the bench
/// honours, so a single-page render can be attributed to memory and throughput without
/// running the whole benchmark.
pub(crate) fn print_render_stats(width: u32, height: u32, stride: usize, elapsed: Duration) {
    if !stats_enabled() {
        return;
    }
    let mp = f64::from(width) * f64::from(height) / 1e6;
    println!(
        "stats: ARIS_READER_RENDER_STATS=1 · {}x{} px · {mp:.2} MP · {:.1} ms · {:.0} MP/s · {} tile byte(s) · rss-peak {:.1} MiB · pdfium {}",
        width,
        height,
        ms(elapsed),
        throughput(mp, ms(elapsed)),
        stride * height as usize,
        peak_rss_bytes() as f64 / (1024.0 * 1024.0),
        pdfium_version(),
    );
}

/// Peak resident set size of this process, in bytes.
///
/// `ru_maxrss` is the kernel's own high-water mark, so this is a real peak and not a sample:
/// nothing has to be sampled fast enough to catch it. The unit differs by platform (bytes on
/// macOS, kibibytes on Linux), which is handled here rather than left to the caller.
#[allow(unsafe_code)]
fn peak_rss_bytes() -> u64 {
    let mut usage = std::mem::MaybeUninit::<libc::rusage>::uninit();
    // SAFETY: `getrusage` only writes the `rusage` struct whose pointer it is given, and
    // RUSAGE_SELF is always a valid `who` argument; the return code is checked below.
    let code = unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) };
    if code != 0 {
        return 0;
    }
    // SAFETY: the call succeeded, so `getrusage` initialised the whole struct.
    let usage = unsafe { usage.assume_init() };
    let raw = usage.ru_maxrss.max(0) as u64;
    if cfg!(target_os = "macos") {
        raw
    } else {
        raw * 1024
    }
}

/// FNV-1a 64 over the pixel rows, with the dimensions folded in first.
///
/// The hash covers exactly the bytes PDFium produced (rows trimmed to `width * 4`, so a
/// padded stride cannot leak uninitialised bytes into the checksum) plus the dimensions, so a
/// resolution change can never pass the check by coincidence. FNV is used instead of a
/// cryptographic digest because the point is change detection, not collision resistance.
fn checksum_bgra(pixels: &[u8], stride: usize, width: u32, height: u32) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    let mut mix = |bytes: &[u8]| {
        for byte in bytes {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
    };
    mix(&width.to_le_bytes());
    mix(&height.to_le_bytes());
    let row_bytes = (width as usize).saturating_mul(4);
    for row in 0..height as usize {
        let start = row.saturating_mul(stride);
        let end = (start + row_bytes).min(pixels.len());
        if start >= end {
            break;
        }
        mix(&pixels[start..end]);
    }
    hash
}

/// Mean of the colour channels over the page (alpha excluded), for a quick "is it blank?" read.
fn mean_rgb(pixels: &[u8], stride: usize, width: u32, height: u32) -> f64 {
    let row_bytes = (width as usize).saturating_mul(4);
    let mut sum = 0u64;
    let mut samples = 0u64;
    for row in 0..height as usize {
        let start = row.saturating_mul(stride);
        let end = (start + row_bytes).min(pixels.len());
        if start >= end {
            break;
        }
        for pixel in pixels[start..end].as_chunks::<4>().0 {
            sum += u64::from(pixel[0]) + u64::from(pixel[1]) + u64::from(pixel[2]);
            samples += 3;
        }
    }
    if samples == 0 {
        return 0.0;
    }
    sum as f64 / samples as f64
}

/// The PDFium build the bench ran against: the `VERSION` file shipped next to the dylib,
/// falling back to the development layout. "unknown" is reported rather than guessed.
fn pdfium_version() -> String {
    let mut candidates = Vec::new();
    if let Ok(explicit) = std::env::var("ARIS_READER_PDFIUM_PATH") {
        let path = PathBuf::from(explicit);
        if let Some(lib_dir) = path.parent() {
            candidates.push(lib_dir.join("../VERSION"));
            candidates.push(lib_dir.join("VERSION"));
        }
    }
    candidates.push(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../vendor/pdfium/VERSION"));
    for candidate in candidates {
        let Ok(text) = std::fs::read_to_string(&candidate) else {
            continue;
        };
        let shown = std::fs::canonicalize(&candidate).unwrap_or_else(|_| candidate.clone());
        let value = |key: &str| {
            text.lines()
                .find_map(|line| line.strip_prefix(key))
                .map(|value| value.trim().to_string())
        };
        if let (Some(major), Some(minor), Some(build)) =
            (value("MAJOR="), value("MINOR="), value("BUILD="))
        {
            let patch = value("PATCH=").unwrap_or_else(|| "0".to_string());
            return format!("{major}.{minor}.{build}.{patch} ({})", shown.display());
        }
    }
    "unknown (no VERSION file next to the dylib)".to_string()
}

fn parse_viewport(value: &str) -> Option<(f64, f64)> {
    let (width, height) = value.split_once(['x', 'X', ','])?;
    let width: f64 = width.trim().parse().ok()?;
    let height: f64 = height.trim().parse().ok()?;
    (width > 0.0 && height > 0.0).then_some((width, height))
}

fn ms(duration: Duration) -> f64 {
    duration.as_secs_f64() * 1000.0
}

/// Throughput in megapixels per second; a zero duration reports 0 instead of infinity.
fn throughput(megapixels: f64, milliseconds: f64) -> f64 {
    if milliseconds <= 0.0 {
        0.0
    } else {
        megapixels / (milliseconds / 1000.0)
    }
}

fn megapixels(value: f64) -> f64 {
    value / 1e6
}

fn viewport_fraction(page_px: aris_reader_core::Size, viewport_px: Rect) -> f64 {
    let page_area = page_px.width * page_px.height;
    if page_area <= 0.0 {
        return 0.0;
    }
    let visible = viewport_px
        .intersection(Rect::new(0.0, 0.0, page_px.width, page_px.height))
        .map(|rect| rect.size.width * rect.size.height)
        .unwrap_or(0.0);
    (visible / page_area).clamp(0.0, 1.0)
}

/// Nearest-rank percentile over an ascending slice (`p95` = the value at rank `ceil(0.95 n)`).
fn percentile(sorted: &[f64], fraction: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let rank = ((fraction * sorted.len() as f64).ceil() as usize).max(1);
    sorted[rank.min(sorted.len()) - 1]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checksum_is_stable_and_covers_dimensions() {
        let pixels = vec![0u8; 8 * 4 * 2];
        let a = checksum_bgra(&pixels, 16, 4, 2);
        assert_eq!(a, checksum_bgra(&pixels, 16, 4, 2));
        // A different size must not hash the same even though the bytes are identical.
        assert_ne!(a, checksum_bgra(&pixels, 16, 2, 4));
        // A padded stride must not pull uninitialised bytes into the hash.
        let padded = vec![0u8; 16 * 2];
        assert_eq!(checksum_bgra(&padded, 16, 4, 2), a);
    }

    #[test]
    fn checksum_notices_one_changed_pixel() {
        let mut pixels = vec![7u8; 4 * 4];
        let before = checksum_bgra(&pixels, 16, 2, 2);
        pixels[1] = 8;
        assert_ne!(before, checksum_bgra(&pixels, 16, 2, 2));
    }

    #[test]
    fn percentile_uses_nearest_rank() {
        let values: Vec<f64> = (1..=100).map(f64::from).collect();
        assert_eq!(percentile(&values, 0.50), 50.0);
        assert_eq!(percentile(&values, 0.95), 95.0);
        assert_eq!(percentile(&[], 0.95), 0.0);
        assert_eq!(percentile(&[3.0], 0.95), 3.0);
    }

    #[test]
    fn viewport_parsing_accepts_x_and_comma() {
        assert_eq!(parse_viewport("959x748"), Some((959.0, 748.0)));
        assert_eq!(parse_viewport("1200X800"), Some((1200.0, 800.0)));
        assert_eq!(parse_viewport("800,600"), Some((800.0, 600.0)));
        assert_eq!(parse_viewport("0x600"), None);
        assert_eq!(parse_viewport("nonsense"), None);
    }

    #[test]
    fn mean_rgb_ignores_alpha_and_stride_padding() {
        let pixels = vec![10, 20, 30, 255, 20, 30, 40, 255];
        assert!(
            (mean_rgb(&pixels, 8, 2, 1) - (10.0 + 20.0 + 30.0 + 20.0 + 30.0 + 40.0) / 6.0).abs()
                < 1e-9
        );
        // Wider stride than the row: the padding byte must not be averaged in.
        let mut padded = pixels.clone();
        padded.extend_from_slice(&[255, 255, 255, 255]);
        assert!((mean_rgb(&padded, 12, 2, 1) - mean_rgb(&pixels, 8, 2, 1)).abs() < 1e-9);
    }

    #[test]
    fn pixel_cache_frees_evicted_pixels() {
        let mut cache = PixelCache::new(8, 0);
        let key = |x: u32| TileKey::new(DocId(1), PageIndex(0), Lod(1), x, 0, 0);
        cache.insert(key(0), vec![0u8; 4]);
        cache.insert(key(1), vec![0u8; 4]);
        assert_eq!(cache.len(), 2);
        // The third tile exceeds the 8-byte budget, so the oldest tile's pixels must go too.
        cache.insert(key(2), vec![0u8; 4]);
        cache.evict_to_fit(&HashSet::new());
        assert!(cache.len() < 3);
        assert_eq!(cache.evictions, 1);
        assert!(cache.used_bytes() <= cache.budget_bytes());
        assert_eq!(
            cache.used_bytes(),
            cache
                .pixels
                .values()
                .map(|(pixels, _)| pixels.len() as u64)
                .sum::<u64>()
        );
    }

    #[test]
    fn pixel_cache_never_evicts_the_newest_or_a_pinned_tile() {
        let mut cache = PixelCache::new(4, 0);
        let key = |x: u32| TileKey::new(DocId(1), PageIndex(0), Lod(1), x, 0, 0);
        cache.insert(key(0), vec![0u8; 4]);
        cache.insert(key(1), vec![0u8; 4]);
        // Both tiles are on screen: the budget yields instead of dropping visible content.
        let pinned: HashSet<TileKey> = [key(0), key(1)].into_iter().collect();
        cache.evict_to_fit(&pinned);
        assert_eq!(cache.len(), 2);
        assert_eq!(cache.evictions, 0);
        assert!(cache.used_bytes() > cache.budget_bytes());

        // One of them scrolls off: it becomes evictable, the visible one still does not.
        let pinned: HashSet<TileKey> = [key(1)].into_iter().collect();
        cache.evict_to_fit(&pinned);
        assert_eq!(cache.len(), 1);
        assert!(cache.pixels.contains_key(&key(1)));
    }

    #[test]
    fn pixel_cache_count_ceiling_reproduces_the_pre_adr_policy() {
        // `--cache-tiles 96` is what the M1/M2 baseline was measured under; the ceiling still
        // works alongside a byte budget that the tiny tiles here never reach.
        let mut cache = PixelCache::new(1 << 30, 2);
        let key = |x: u32| TileKey::new(DocId(1), PageIndex(0), Lod(1), x, 0, 0);
        for x in 0..4 {
            cache.insert(key(x), vec![0u8; 4]);
            cache.evict_to_fit(&HashSet::new());
        }
        assert_eq!(cache.len(), 2);
        assert_eq!(cache.evictions, 2);
    }
}
