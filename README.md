# ArisReader

A **native macOS PDF reader** for papers and technical documents: Rust engine + GPU-composited rendering + native SwiftUI/AppKit interface.
The goal is PDF Expert-level simplicity and fluidity, with two advanced capabilities layered on top of the reading experience: citation/figure popovers and an AI assistant.

> **Naming convention**: `Aris` is the shared prefix of the toolkit. This project is **ArisReader**, so every module uses
> the **`aris-reader-`** prefix (crate names `aris-reader-core` …, C ABI symbols `aris_reader_*`, environment variables
> `ARIS_READER_*`, Swift targets `ArisReaderKit` / `ArisReaderFFI`). Suite-level shared modules will claim the `aris-*`
> prefix later, to avoid ambiguity.

Current status: **M1 in progress — the reader opens real PDFs**. M0 is complete (GPU interop verified on device, PDFium
rasterization cross-checked against poppler, UniFFI control plane generated into Swift). The first M1 slice works end to
end: open a document, rasterize pages through PDFium on a background queue, upload them as GPU textures, scroll
continuously, turn pages and zoom — with a pixel budget that keeps a single page texture inside 32 MB even at deep zoom.
Still missing: tiles with an LOD pyramid and a raster thread pool (so very large pages render progressively), the text
layer (selection, search, citations), and annotations. Every crate carries `TODO(Tx.y)` anchors pointing at the
[task list](docs/08-tasks.md).

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

# 3) Package a .app bundle
./scripts/make-app-bundle.sh          # output: build/ArisReader.app

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
| M1 | Minimum readable loop: open / page turn / zoom / continuous scroll / tile cache | ✅ Complete — pages render as 512 px tiles at a discrete LOD chosen from the zoom, continuous scrolling and the overlay scroll indicator work, deep zoom stays sharp while memory stays bounded by what is visible (400% needs 140 tiles for the page and touches 45), and rasterization runs off the main thread under a memory budget. Region rasterization is verified pixel-for-pixel against whole-page renders |
| M2 | Full reading experience: outline, thumbnails, search, text selection, links, tabs, reading position | ✅ Complete — text layer with drag-selection and ⌘C, cross-page search, thumbnail strip, outline list, clickable search results, link following (URLs open in the system browser, internal links jump), tab strip with per-tab position, and reading-position restore |
| M3 | Annotation and editing: highlight/underline/ink/sticky notes, page operations, undo/redo | 🚧 In progress — highlights and underlines from a selection, editable notes, sidebar list with jump and delete, ⌘Z/⇧⌘Z undo/redo, all persisted to a sidecar JSON (round trip verified). Ink, page operations and PDF write-back remain |
| M4 | Citations and figures: click a reference and see it in a floating window | 🚧 In progress — internal links open a floating preview on a second render surface instead of jumping (verified with two surfaces live at once), and the panel can show an arbitrary rectangle of the target page, which is what a figure or table needs. Extracting the destination rectangle from the PDF, citation recognition and a draggable panel remain |
| M5 | AI assistant: summarization, translation, document chat, region-based discussion, RAG, local models | ⬜ |
| M6 | Cross-platform: Windows / Linux shell and packaging | ⬜ |
| M7 | Polish: performance, accessibility, internationalization, auto-update, notarized distribution | ⬜ |

## License

This project is released under the MIT license (see [ADR-0005](docs/adr/0005-licensing.md)).
Third-party components: PDFium (BSD-3-Clause), wgpu (Apache-2.0), pdfium-render (MIT/Apache-2.0), UniFFI (MPL-2.0, build-time tooling only).
**No AGPL components** (MuPDF is excluded).
