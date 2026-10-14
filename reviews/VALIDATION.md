# M1–M4 validation and remaining acceptance work

Review started 2026-10-13. Changes are split into four PRs, without modifying master.
M1 is independent. M2 → M3 → M4 are stacked to keep each review focused.

## Automated and native checks

- Integrated Rust workspace: 142 unit/integration tests pass; formatting and
  strict Clippy (`--workspace --all-targets -- -D warnings`) pass.
- PDFium lifecycle stress: 50 rounds of four workers, eight cycles each (1,600
  open/text/link/outline/render/drop cycles) pass with one process-wide lock.
  All 11 PDFium tests pass, including a tile-background regression that failed
  before the fix with transparent pixels outside the unscaled clear region.
- Explicit opt-in corpus test across 12 local papers: all encoded coverage and
  identity assertions pass, 226/227 sampled citation spans resolve. This is the
  existing regression contract, not an independent precision/recall benchmark.
- Native Swift build with regenerated Rust bindings and a CLT-compatible executable
  regression harness: 32 checks pass. Checks cover normal open, thumbnails/search, stale searches,
  tab restoration/closure, failed opens, sidecar compatibility/failure/undo, and
  deliberately reordered preview responses, scroll bounds, group selection and
  preview close/document-switch/error paths.
- Actual native window: both GPU surfaces render, compact/expanded previews show
  a real figure and a full target page with a table, independent preview scrolling
  reaches the bottom, and clicking `[1,11,19]` shows all three entries. Selecting
  entry 19 switches its preview while retaining the group. This caught a native
  wheel-direction bug that pure state tests did not expose.
- The final integrated app also removes visible gray tile bands and clips edge
  tiles to the page boundary. A clean Swift build links the Rust archive explicitly;
  `otool -L` confirms the app no longer loads Rust from an absolute Cargo build path.

These results use a local integration branch containing all four PRs. M1 is
independent of the M2–M4 stack; both rendering fixes are needed for the final
native result. No changes have been merged into master.

## Independent raster comparison

First and last page of each of 12 local PDFs: 24 PDFium/Poppler pairs at 144 dpi.
Two Poppler images were one pixel taller; those pairs were cropped to the common
upper-left dimensions before metric comparison. Original images stay local in
`build/review-render/`; no sample PDF assets are committed.

| Metric (unweighted across page pairs) | Result |
| --- | ---: |
| Mean absolute error, mean | 3.3051 / 255 |
| Mean absolute error, median | 3.7155 / 255 |
| Mean absolute error, range | 0.4196–5.1549 / 255 |
| PSNR, mean | 23.90 dB |
| MAE < 1 / < 3 / < 6 | 6 / 7 / 24 pairs |

Control fixtures: text-page MAE 0.4681, rotated MAE 0.2152. These measurements
characterize renderer differences; they do **not** establish a new passing quality
threshold. Whole-page comparisons alone do not validate GPU tile composition.

## Follow-up acceptance matrix

| Area | Still required |
| --- | --- |
| M1 performance | 300-page first frame, sustained 60 fps, memory <400 MB, leak audit, queue cancellation and cache budgets |
| M2 search | Incremental results/cancellation, >500 matches, Unicode behavior, 1000-page latency target; scroll directly to a deep-page match |
| M2 selection/navigation | Cross-page/column selection, rotated selection, navigation history, bookmarks, split/facing pages, window restore |
| M2 position | Persist search/scrollbar positions and pending position on app termination; current debounce can lose recent movement |
| M3 editing | PDF annotation import/write-back and external-reader round trips, ink/shapes, page operations/export/forms; sidecar fingerprints/conflicts |
| M4 content | Unlinked equation anchors, ordered cross-page/column reference fragments, precise vector/table regions, multi-page algorithms/tables |
| M4 interaction | Independent draggable/pinnable panels, keyboard citation focus, index persistence and cold-preview latency |

Build tip for restricted environments: set `CLANG_MODULE_CACHE_PATH` and
`SWIFTPM_MODULECACHE_OVERRIDE` to `$PWD/build/module-cache`, and pass
`--cache-path "$PWD/build/swift-cache" --disable-sandbox` to SwiftPM. Without a
writable module cache, Swift can misleadingly report an SDK/compiler mismatch.
