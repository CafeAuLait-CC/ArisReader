# Lyra

> The application is called **Lyra**. The repository, the Rust crates (`aris-reader-*`), the Swift
> modules (`ArisReaderKit`, `ArisReaderFFI`), the C ABI symbols (`aris_reader_*`) and the developer
> environment variables (`ARIS_READER_*`) keep the original `aris` naming: it is the shared toolkit
> prefix, it is an explicit project constraint, and renaming it would touch the FFI header, the
> generated bindings and every test for no user-visible gain. Only what a reader sees — the app
> name, its icon, its window titles and the bundle — says Lyra.

A **native macOS PDF reader** for papers and technical documents: Rust engine + GPU-composited rendering + native SwiftUI/AppKit interface.
The goal is PDF Expert-level simplicity and fluidity, with two advanced capabilities layered on top of the reading experience: citation/figure popovers and an AI assistant.

> **Naming convention**: `Aris` is the shared prefix of the toolkit. This project is **ArisReader**, so every module uses
> the **`aris-reader-`** prefix (crate names `aris-reader-core` …, C ABI symbols `aris_reader_*`, environment variables
> `ARIS_READER_*`, Swift targets `ArisReaderKit` / `ArisReaderFFI`). Suite-level shared modules will claim the `aris-*`
> prefix later, to avoid ambiguity.

Current status: **M1–M4 have working core paths and remain under active development**. The reader
opens real PDFs, rasterizes tiled pages off the main thread, and supports selection/search,
tabs, sidecar highlights/underlines/notes, and citation/figure/table/algorithm previews.
At ordinary zoom, the reader presents one page raster at the screen's actual resolution and prepares
nearby pages on every scroll update. Page rasters and tiles share the configured byte budget, so lower
zoom keeps more neighbors; larger pages and deep zoom use tiles. Already sharp tile rows stay sharp as
new regions load. A cold page can still show a preview until its raster arrives; this does not promise
zero-latency arbitrary jumps.
Milestone acceptance criteria are not all met: the milestone table below names what is missing, and the
full review record (findings, evidence and follow-ups) is kept with the project's design notes rather than in
this repository. Concrete
fixes, validation evidence and outstanding work. PDFium remains serialized within a process;
background execution does not imply parallel PDFium rendering.

---

## Tech stack (decided)

| Dimension | Choice | Rationale / ADR |
| --- | --- | --- |
| Rendering & compositing | **wgpu 30** (macOS → Metal; future Windows → DX12, Linux → Vulkan) | One GPU layer reused across all three platforms · [ADR-0003](docs/adr/0003-gpu-wgpu-shared-device.md) |
| PDF engine | **Backend trait abstraction + PDFium as the first implementation** (BSD-3), with a slot reserved for a pure-Rust backend | The only engine that supports rendering, per-glyph text boxes, links, forms and incremental save at once · [ADR-0002](docs/adr/0002-pdf-engine-backend.md) |
| UI | **SwiftUI + AppKit** (native macOS), with UI logic pushed down into the platform-independent `aris-reader-session` | Native look and feel, input methods and accessibility; a future shell swap won't require rewriting the engine · [ADR-0001](docs/adr/0001-native-ui-stack.md) |
| Bridging | **UniFFI** (control plane) + hand-written C ABI (GPU surface/device handoff) | Generates Swift bindings automatically, supports async and callback streams · [ADR-0004](docs/adr/0004-rust-swift-ffi.md) |
| License | This project is **MIT**; all dependencies use permissive licenses | [ADR-0005](docs/adr/0005-licensing.md) |
| Build | Cargo workspace + SwiftPM (**Command Line Tools only**, CLT 26.3 on this machine) | Develop without a full Xcode install · [ADR-0006](docs/adr/0006-build-without-xcode.md) |

## Directory layout

```
ArisReader/
├── Cargo.toml                  # Rust workspace (10 crates)
├── rust-toolchain.toml         # Pinned toolchain
├── crates/
│   ├── aris-reader-core/              # Document model, geometry/coordinates, errors, backend traits (zero platform deps)
│   ├── aris-reader-pdfium/            # PDFium implementation of DocumentBackend (feature-gated)
│   ├── aris-reader-text/              # Text pages, per-glyph boxes, selection, search, reading order
│   ├── aris-reader-edit/              # Annotation model, page operations, forms, incremental save
│   ├── aris-reader-render/            # Tile pyramid, LOD, scheduling, cache, prefetch
│   ├── aris-reader-gpu/               # wgpu device/surface/compositor, shares MTLDevice with the native layer
│   ├── aris-reader-session/           # Session and viewport state machine, command/event bus (platform-independent)
│   ├── aris-reader-ai/                # LLM provider abstraction, context building, citation index
│   ├── aris-reader-ffi/               # UniFFI interface definitions + C ABI exports
│   └── aris-reader-cli/               # Headless CLI: render/text/benchmarks (also the golden test entry point)
├── apps/macos/                 # SwiftPM package: ArisReaderKit (UI library) + ArisReader (executable app)
├── scripts/                    # Build, packaging, PDFium fetch and check scripts
├── docs/                       # Design and planning documents (see below)
└── vendor/                     # Third-party binaries (pdfium, git-ignored)
```

> **Note**: `docs/` and `.gitignore` are intentionally **local-only** — they are not committed (both are listed in
> `.gitignore` itself). A fresh clone therefore contains code, scripts and this README, but no design documents and no
> default ignore rules, so build output (`target/`, `build/`, `apps/macos/.build/`, `vendor/`) shows up as untracked
> until you recreate a `.gitignore`.

## Quick start

```bash
# 1) Check the Rust side
cargo check --workspace

# 2) Build the Rust static library AND generate the UniFFI Swift bindings
#    (both are build artifacts and are not committed)
./scripts/build-rust.sh

# 3) Build and run the native macOS shell
cd apps/macos && swift build && swift run ArisReader
#    In a sandboxed shell (CI, agent runners) add --disable-sandbox: SwiftPM's nested
#    sandbox-exec is rejected there. scripts/check.sh retries automatically.
#    Tip: ARIS_READER_OPEN=/path/to.pdf swift run ArisReader opens a document at launch.
#    Dev hooks for headless checks (all optional, all logged on stderr):
#      ARIS_READER_ANNOTATE="x1,y1;x2,y2"  highlight the text between two content points
#      ARIS_READER_NOTE="text"             type into the first note, one keystroke at a time
#                                          (ARIS_READER_NOTE_INTERVAL_MS, ARIS_READER_NOTE_COMMIT=1)
#      ARIS_READER_RECOVER_SIDECAR=1       back up an unreadable sidecar and start fresh
#      ARIS_READER_QUIT_AFTER=<ms>         quit through the normal flush path
#    Sidecar writes are instrumented as `aris-annotate: saved N annotation(s) … write #K [trigger]`,
#    which is what makes note-write coalescing measurable (at most one write per ~500 ms of typing).

# 3) Package a .app bundle
./scripts/make-app-bundle.sh          # output: build/Lyra.app

# 4) Fetch and sign the PDFium dynamic library (needed for rendering)
./scripts/fetch-pdfium.sh

# 5) Generate the test fixtures (stdlib-only Python script)
python3 scripts/make-fixtures.py

# 6) Render a page and compare against a reference rasterizer
cargo run -p aris-reader-cli -- info tests/fixtures/text-page.pdf
cargo run -p aris-reader-cli -- render tests/fixtures/text-page.pdf --dpi 144 -o /tmp/page.png
pdftoppm -r 144 -png tests/fixtures/text-page.pdf /tmp/poppler
cargo run -p aris-reader-cli -- compare /tmp/page.png /tmp/poppler-1.png --max-mae 1.0
```

## Development workflow

This repository is trunk-based. A push to `master` runs CI; a **pull request** is used when a gate
before merging earns its ceremony, which is decided by what the change does rather than by who wrote
it:

**Straight to `master`** — additive, self-contained work that does not change the behaviour of an
existing code path: new modules or functions, tests, documentation, milestone and task lists, CI
configuration. Code produced by an automated agent lands this way too, once it has been verified.

**Through a pull request** — anything that changes existing behaviour: bug fixes, performance work,
refactors, model or FFI signature changes, and anything touching the rendering, annotation or
selection paths. Also use one for work that lands in pieces, for a new subsystem whose blast radius
is not yet known, and for **anything done while another session is working in this repository** —
that last case is what genuinely needs it, because a pull request is checked against the **merge
result**, and an integration regression between two in-flight branches is invisible to either
branch's own checks.

Prefer a **merge commit** for a pull request whose individual commits carry meaning; squash only when
the branch is a single commit or its history is noise.

## Reproducing measurements

Any requested benchmark phase failure returns a nonzero exit status, including with
`--skip-baseline`. The CLI benchmark models CPU raster work and a settled prefetch band. It finishes every
step's prefetch before advancing, so zero visible misses do **not** establish zero waiting
under continuous scrolling. It does not measure GPU time or presented frame rate.

**Presentation timestamps are unavailable on at least one machine tested here**: every drawable's Metal
`presentedTime` came back as zero (436 of 436 in the harness, 297 of 297 in a minimal `CAMetalLayer`
probe), so a trace reporting `presented_fps: 0.0` is not evidence of a frame-pacing problem — and not
evidence of anything else either. Treat an all-zero presentation trace as "not measured", never as 0 fps.
The application-side harness also drives the scroll model on a 16.67 ms cadence rather than delivering
real wheel or trackpad events, and reaches about 53 inputs per second, so it cannot demonstrate 60 fps
even where timestamps work. The project's "stable 60 fps" criterion therefore remains **unproven**, not
failed.

**Record the surface size and scale with any memory or frame figure**: earlier medians were taken on a
1918x1430 scale-2.0 surface and later runs on a 959x715 scale-1.0 one, and the two are not comparable;
a real-paper raster p95 of 13.7-14.5 ms likewise did not reproduce in either arm of a later A/B (20-40 ms). The default
48 MiB cache gives the prefetch band a 16 MiB target (one third, with an 8 MiB floor); the
minimum ring can still exceed that target. Record the commit, PDFium version, input PDF,
command, build profile and hardware with each result.

```bash
cargo run --release -p aris-reader-cli -- bench tests/fixtures/multipage.pdf
./scripts/fetch-eval-papers.sh
ARIS_READER_REQUIRE_FULL_EVAL=1 cargo test -p aris-reader-cli --test reference_eval -- --ignored --nocapture
```

`ARIS_READER_EVAL_PAPERS` can point at an existing corpus. Without strict mode, local evaluation
may use a partial corpus or explicitly skip an absent one; so does the GPT-3 gold check, which
needs one PDF rather than the corpus and announces its own absence with a `::notice::` instead of
failing. Every mode fails if a present PDF cannot be opened or a page's text cannot be extracted.
Manual CI with `fetch_eval_papers=true` requires all listed PDFs; PDFium download failure fails
the macOS gate. CI decides whether to evaluate by looking at whether `eval-papers/*.pdf` exists,
not by a step's outcome, so a corpus that is already on the workspace is measured rather than
reported as absent. CI preserves check and evaluation logs as `macos-check-logs` artifacts,
including on failure.

The evaluation's historical “recall” column is **resolution rate among detected spans**, not
citation-detection recall: undetected styles never enter its denominator, and a grouped span
counts as resolved if any label resolves (partial groups are reported separately). The table also
prints the body-page window each paper was measured over, because that window moves when the
bibliography parser selects the list differently — GPT-3's went from 69 pages to 67 — and recall is
a ratio over it, so two runs are comparable only when their windows match. It also prints the
longest bibliography entry each paper parsed and how many entries exceed a plausibility bound of
1800 characters, and fails a paper that goes past its pinned ceiling: that is the shape T4.17 had,
when GPT-3 parsed as six entries of 3000–7831 characters instead of 144, so a collapse comes back
as a failing evaluation rather than as a number that merely looks odd. The four measured entries
above the bound are pinned at their measured lengths instead of being cut, because they are the
last reference of a list absorbing the section printed after it on the same page, and the obvious
repair — ending an entry at a paragraph gap — truncates legitimate wrapped lines. The
heuristic precision audit is review evidence, not a measured false-positive rate. A small
independently annotated GPT-3 gold set checks complete detection on three full pages and proves
each of the 18 labels resolves to the entry that names the annotated first author: the surname must
be one of the entry's opening words, and the year encoded in the citation key must label the same
entry. Both are checks the resolver cannot satisfy by construction, and the predicate is
mutation-tested (set `ARIS_READER_GPT3_GOLD` to a scratch copy of the TSV to try it);
corpus-wide labelled examples are still needed for the acceptance criteria. The arXiv revisions
and SHA-256 hashes are locked in `tests/eval/arxiv-lock.tsv`;
`python3 scripts/verify-eval-papers.py /path/to/corpus` checks existing files. Downloads verify
the lock before replacing files. PDFium defaults to `chromium/8100` with published archive
checksums; `--tag` explicitly opts into a different engine baseline.

To measure the native release app with continuous scripted input:

```bash
./scripts/build-rust.sh
(cd apps/macos && swift build -c release)
python3 scripts/measure-native-scroll.py eval-papers/2005.14165.pdf --runs 3 --zoom 100 --output build/scroll-100
python3 scripts/measure-native-scroll.py eval-papers/2005.14165.pdf --runs 3 --zoom 400 --output build/scroll-400
```

Each run opens a temporary PDF copy, starts at the top, uses a 48 MiB cache, warms for two
seconds, then calls the wheel handler's model scroll method for eight seconds at 600 screen points/s.
It never waits for raster completion between inputs. It bypasses `NSEvent` delivery and the
canvas wheel handler's immediate draw, exercising queued redraws. Raw logs and `results.json` retain every
run's peak RSS in bytes, MB and MiB, input/submission/presentation interval tails, queue depth,
platform, commit and PDF/engine/executable hashes. Missing, stationary or wholly occluded traces fail.
The window is brought forward for measurement. Partial occlusion is reported explicitly.
With tracing enabled, a diagnostic `CAMetalLayer` observes the same drawable wgpu acquires
and registers a Metal presentation handler. FPS uses the drawable's `presentedTime` host
timestamp, as documented by [Apple](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime),
not the handler's arrival time or the CPU submission timestamp. Zero timestamps are reported
drops. Missing callbacks make FPS and presentation tails unavailable; they never count as
confirmed drops. Frames presented after the scrolling window are reported separately.
`presented_fps` counts frames over the full scrolling interval; frame gaps include both edges,
and `motion_presented_frames` separates frames whose scroll position changed. This records
system-reported drawable presentation, not physical scanout, display refresh rate or GPU
execution time. Scripted input is not a physical trackpad trace, and a finite run alone does
not certify the 60 fps criterion. Legacy logs remain readable but cannot supply presented FPS.
`--scheduling-diagnostics` additionally records frame-loop/model timing and adds logging overhead.

Keep memory units and the aggregation rule explicit: **400 MB = 381.47 MiB**. A 387.3 MiB
median is about 406.1 MB and does not meet a decimal 400 MB limit; a median below a limit also
does not prove that every run's peak is below it. The published debug-build measurements and
CLI raster timings alone do not establish the full M1 memory/60 fps acceptance criteria.

All-zero Metal presentation timestamps are reported as unavailable, with FPS and drop counts left
unset; they are not evidence of 0 FPS. The native scroll harness also accepts `--zoom 140` for the
ordinary-zoom page-cache path.

### Page cache and navigation measurements

After a release build, the native checks executable can measure CPU raster retention for any local PDF:

```bash
ARIS_READER_PDFIUM_PATH="$PWD/vendor/pdfium/lib/libpdfium.dylib" /usr/bin/time -l \
  apps/macos/.build/release/ArisReaderChecks --measure-page-rasters /path/to/paper.pdf 2.8 3
ARIS_READER_PDFIUM_PATH="$PWD/vendor/pdfium/lib/libpdfium.dylib" /usr/bin/time -l \
  apps/macos/.build/release/ArisReaderChecks --measure-page-navigation /path/to/paper.pdf 140
```

`2.8` represents 140% on a 2x display. The first command totals actual BGRA bytes across all pages
while retaining at most three; it reports raster median/p95 and `/usr/bin/time` reports process peak RSS.
The second uses a temporary document copy, a 959×715pt viewport at 2x, and measures model raster
readiness on cold, neighbor, return and distant jumps (PDFs longer than eight pages). It reports partial
sharp updates and immediate sharp cache hits. It excludes GPU upload and presentation, so it is not FPS
or end-to-end visual latency. `ARIS_READER_SHARP_PAGE_RASTERS=0` disables the screen-page path for a
feature-off comparison under the same pixel budget. Deep zoom remains on tiles.

## Documentation index

The design documents live in `docs/` in the working copy (not committed yet — see the note above), so the links below
resolve locally.

| Document | Contents |
| --- | --- |
| [01 Product definition](docs/01-product.md) | Positioning, user scenarios, feature tiers, non-goals, success criteria |
| [02 Architecture overview](docs/02-architecture.md) | Layers, crate responsibilities, threading model, data flow, portability design |
| [03 Rendering pipeline](docs/03-rendering.md) | Coordinate systems, tile pyramid, cache, PDFium parallelism, GPU compositing, performance budget |
| [04 UI/UX design](docs/04-ui-ux.md) | Window layout, sidebar, toolbar, shortcuts, gestures, dark mode, accessibility |
| [05 FFI contract](docs/05-ffi.md) | Object model, draft API, threading rules, GPU device/layer handoff protocol |
| [06 AI and advanced reading](docs/06-ai.md) | Citation/figure popovers, region-based discussion, summarization and translation, document chat, RAG, privacy |
| [07 Roadmap](docs/07-roadmap.md) | M0–M7 milestones: goals, deliverables, exit criteria, risks, effort |
| [08 Task list](docs/08-tasks.md) | Checkable task breakdown (ID / dependencies / size) |
| [09 Development setup](docs/09-dev-setup.md) | Local environment facts, build commands, signing/packaging, workarounds without Xcode |
| [ADR](docs/adr/) | 6 architecture decision records |

## Milestones at a glance

| Milestone | Theme | Status |
| --- | --- | --- |
| M0 | Skeleton, FFI path, GPU interop spike (a PDF page texture on screen) | ✅ Complete |
| M1 | Minimum readable loop | Core implemented; performance, memory/leak budgets and scheduling exit criteria remain unverified. PDFium lifecycle locking review: resolved in PR #6 |
| M2 | Reading experience | Core implemented; normal-open initialization, tab/cache isolation and stale search handling repaired. Cross-page selection, incremental search, navigation history, user bookmarks, split/facing views and full session restoration remain. |
| M3 | Annotation and editing | Partial: durable sidecar highlights/underlines/notes with undo/redo. A sidecar that cannot be read still refuses every write, but the reader can now back it up and start fresh from the alert (the original file is moved, never overwritten). Note edits coalesce their disk writes and flush on commit, document switch, tab close and quit. PDF annotation import/write-back, ink, page operations, AcroForm forms and export remain; the sidecar still lacks document-fingerprint validation and cross-process conflict detection. |
| M4 | Advanced reading | Partial: resizable, scrollable previews; complete resolved citation text with entry switching; Algorithm detection; full-page fallback for uncertain table/vector regions. A `Table` reference previews the grid its border lines form — 20 of the 41 table captions in the twelve sample papers, the rest falling back to the page. A grouped citation resolves to **every** work it names (`[1,11,19]` lists three entries), and bibliography entries are modelled as fragments (page and glyph range each), so a cross-page continuation is no longer a truncated rectangle. On the **twenty-paper arXiv corpus**, 94.7% of 1979 detected citation spans resolve — the evaluation set is links only, no PDF is committed. Alphanumeric labels and groups (`[HR18]`, `[MCCD13, PSM14]`, `[VSP+ 17]`) now resolve: GPT-3 has 203 spans and 144 bibliography entries. Superscripts on papers that bracket their citations and short parenthesised numerals remain unsupported. A column gutter is now detected from the character runs inside each line (52 of the corpus's 298 pages, all in its seven two-column papers; the five single-column papers acquire none). Unlinked equations, vector-figure segmentation, pinning, index persistence and bibliography metadata remain. |
| M5 | AI assistant: summarization, translation, document chat, region-based discussion, RAG, local models | ⬜ |
| M6 | Cross-platform: Windows / Linux shell and packaging | ⬜ |
| M7 | Polish: performance, accessibility, internationalization, auto-update, notarized distribution | ⬜ |

## License

This project is released under the MIT license (see [ADR-0005](docs/adr/0005-licensing.md)).
Third-party components: PDFium (BSD-3-Clause), wgpu (Apache-2.0), pdfium-render (MIT/Apache-2.0), UniFFI (MPL-2.0, build-time tooling only).
**No AGPL components** (MuPDF is excluded).
