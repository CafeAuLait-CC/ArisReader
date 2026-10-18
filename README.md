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

Current status: **M1–M5 have working core paths and remain under active development**. The reader
opens real PDFs, rasterizes tiled pages off the main thread, and supports selection/search,
tabs, sidecar highlights/underlines/notes, citation/figure/table/algorithm previews, and document
metadata recognition with per-field provenance plus BibTeX export.
Those annotations can be written back into a PDF: saving an annotated copy, or replacing the
original after a verified backup, appends real PDF annotations with quads, colour, opacity, author
and date through an incremental save that leaves every pre-existing annotation byte-identical.
Replacing the original also removes exactly the sidecar entries it saved, so nothing appears twice;
a saved copy carries no sidecar and shows each annotation once, from the file. Pages can be rotated,
deleted, reordered, inserted and extracted through a staged session whose undo covers the whole
session; the file on disk stays untouched until the reader applies the changes, and applying writes
a verified backup before replacing anything. An optional AI assistant speaks the OpenAI-compatible
chat API, so a hosted service or a local Ollama works with nothing but a base URL, a model and a
key: it summarises a page or a long document, answers about a selection and translates one, previews
exactly what will be sent before anything leaves the machine, streams, cancels and retries, and keeps
the key in the Keychain rather than in any file or log.
At ordinary zoom, the reader presents one page raster at the screen's actual resolution and prepares
nearby pages on every scroll update; a facing-page mode shows page 1 alone and 2–3/4–5 spreads with a
configurable gap, and named user bookmarks ride in the same sidecar as the reader's annotations. Page rasters and tiles share the configured byte budget, so lower
zoom keeps more neighbors; larger pages and deep zoom use tiles. Already sharp tile rows stay sharp as
new regions load. A cold page can still show a preview until its raster arrives; this does not promise
zero-latency arbitrary jumps. What this replaced was measured rather than assumed: at 140% on a 2x
display the base held a blurry 1x raster for up to 26 consecutive canvas updates and took 84-88 ms per
page jump, and it never mixed a preview with pyramid tiles in one frame (0 mixed frames in 230 canvas
updates). Mixed sharp and blurry frames belong to the deep-zoom tile path here, which deliberately
paints complete sharp rows over a soft backdrop; that is the one present this reader still refines in
place.
Milestone acceptance criteria are not all met: the milestone table below names what is missing, and the
full review record (findings, evidence and follow-ups) is kept with the project's design notes rather than in
this repository. Concrete
fixes, validation evidence and outstanding work. PDFium remains serialized within a process;
background execution does not imply parallel PDFium rendering.

Capabilities, each backed by a check rather than a claim: selection and click-precise text, search,
tabs and independent windows, outline with section numbers and levels, page and annotation sidebars
with reply threads, highlight/underline/note creation with a colour and blend, saved annotations
inside the PDF, staged page editing, facing pages and bookmarks, citation/figure/table/algorithm
previews with draggable panels, paper metadata and BibTeX export, and the AI assistant described
above. Known gaps are listed in the project's design notes: ink and shape annotations, standalone
sticky notes and text boxes, form filling, redaction and printing, an index cache, thumbnail drag
reordering, and cross-platform shells.

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
├── Cargo.toml                  # Rust workspace (11 crates)
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
│   ├── aris-reader-metadata/          # Info/XMP/first-page metadata recognition and BibTeX generation
│   ├── aris-reader-ffi/               # UniFFI interface definitions + C ABI exports
│   └── aris-reader-cli/               # Headless CLI: render/text/metadata/benchmarks (also the golden test entry point)
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
#    PDF write-back is instrumented as `aris-annotate: saved … to … (append N bytes)` and
#    `aris-annotate: replaced … , backup …`; the checks can run it alone with
#    `ArisReaderChecks --check-annotation-writeback .

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

# 7) See what a PDF somebody else annotated carries, page by page: subtype, /Rect, /QuadPoints
#    count, /C, /CA, the blend mode it is drawn with, /Contents, and the tint the canvas uploads
cargo run -p aris-reader-cli -- annotations tests/fixtures/annotated-appearance.pdf

# 8) Recognise title/authors/venue/year/DOI/arXiv and print each field with its source
cargo run -p aris-reader-cli -- metadata tests/fixtures/metadata-text-layer.pdf
```

## Annotation write-back

The reader's highlights, underlines and notes can be written into the PDF itself, so another
viewer sees them. This is deliberately the only code path that writes to a user's document, and
it is always an explicit command:

* **File ▸ Save Annotated Copy… (⌘S)** writes a new PDF (suggested name `<name> (annotated).pdf`).
  The open document and its sidecar are not touched. The copy has no sidecar, so reopening it
  shows each annotation once, from the file.
* **File ▸ Save and Replace Original… (⇧⌘S)** replaces the document. It first writes
  `<name>.lyra-backup-<unix>-<n>.pdf`, verifies that the backup is byte-identical, and refuses to
  run if the backup cannot be written. The replacement itself is an atomic rename of a verified
  temporary file, so a crash leaves the original readable.

Both paths save **incrementally**: every original byte stays at its original offset and the new
objects are appended. Before the temporary file is renamed into place it is reopened and checked:
each written annotation must read back exactly once with its geometry, colour, opacity, contents,
author and date, and every annotation the file already carried must read back unchanged. The
sidecar's per-entry compatibility rules are untouched; a replace removes exactly the entries it
saved and preserves foreign entries, bookmarks and their order. If the sidecar update fails after
the PDF was written, reopening reconciles by `/NM` and shows the PDF's copy only.

**Appearance streams, and what to expect in Preview.** The highlight/underline writer does not
write `/AP`. PDFium's C ABI has only one way to attach one (`FPDFAnnot_SetAP`), and its generated
`/ExtGState` is hard-coded to `/BM /Normal`; writing that for a translucent highlight would tint
the glyphs instead of multiplying into the page, which is visibly worse than letting viewers
synthesize the appearance. PDFKit — the engine Preview uses — does synthesize it from
`/QuadPoints` and `/C`: the regression suite renders a saved copy with PDFKit and asserts that the
band is painted while the glyph pixels stay black. PDFium (and therefore Chrome) does the same.
A viewer that requires an explicit appearance stream (some older readers) will not show the
highlight; that is the honest cost of not writing a knowingly wrong blend mode. `/Text` notes are
written with `/Subtype /Text`, contents, author, date and colour, but PDFium exposes no setter for
the `/Name` icon, so viewers show their default note icon rather than `/Comment`. An opaque `/CA`
(1.0) is omitted by PDFium because absence already means fully opaque.

**Crash recovery.** A save writes `<destination>.lyra-save-<pid>-<n>.tmp` in the destination's
directory and removes the temporary on every error. On the next open, the reader reports any
leftover temporary in the status line; the document is intact because only the final rename makes
a save take effect. The next save removes the leftovers (the engine's
`interruptedSaveNote(at:)` is the detection point).

## Annotation text export

**File ▸ Export Annotations… (⌘E)** writes the annotations to a separate Markdown (`.md`) or CSV
(`.csv`) file chosen in the save panel; the suggested name is `<name> (annotations).md`/`.csv`.
Both the reader's own annotations (from the sidecar) and the annotations the PDF already carries
are included, each labelled with its source. The export is in document order — page, then vertical
position, then creation time — with `/IRT` replies nested under their parent, and the file's own
date (its `/M`) is used because a PDF annotation has no creation date. Markdown quotes are full
blockquotes rather than truncated lines; CSV uses RFC 4180 quoting and keeps embedded commas,
double quotes and newlines. This is a local file write with the same atomic discipline as the
sidecar (a temporary file renamed into place), and a document with no annotations produces no file
and says so.

## Document metadata and BibTeX

The Metadata sidebar section (and `aris-reader-cli metadata <file.pdf>`) reads the open document
offline, in this priority order:

1. **XMP** — `dc:title`, `dc:creator`, `prism:doi`, `prism:publicationName`, `prism:coverDate`;
2. **the `/Info` dictionary** — `/Title`, `/Author`, and `/Subject`/`/Keywords` as a place a DOI is
   sometimes parked;
3. **page one's text layer** — the largest text above the abstract (title block), the author line
   below it, and identifiers/venue/year from the page furniture.

Every field carries its source, and the panel marks layout-derived values as **Guessed**. An empty
field stays empty: the recogniser has no filename, creation-date or "Anonymous" fallback, so a
scanned page or a paper with no text layer produces no metadata rather than plausible-looking
metadata. The DOI (`10.\d{4,9}/…`) and arXiv id (`arXiv:2303.08774`, `2303.08774v2`) are found in
page-one text and reported as identified, not guessed.

The same values generate the BibTeX entry: `@article` for a journal venue, `@inproceedings` for a
conference/proceedings venue, `@misc` when there is no venue (including arXiv preprints, with
`eprint`/`archivePrefix`). The key is author/year/title, field values are brace-wrapped and LaTeX
escaped (`& % _ # $ ~ ^ \`, balanced `{…}` groups preserved, common Latin diacritics translated to
accent commands), and URLs in `url`/`doi` are not text-escaped. **Copy BibTeX (⇧⌘B)** and
**Save BibTeX…** both use exactly the string the panel shows, including any corrections the reader
made; a correction changes the field's source to `Edited`.

The accuracy of the recognition is measured in the pull request that introduced it: the title,
author, venue, year and DOI of the twelve sample papers and seven review PDFs were compared by hand
with the produced fields, and the fixtures `metadata-embedded.pdf`, `metadata-info.pdf`,
`metadata-text-layer.pdf` and `metadata-arxiv.pdf` pin the known answers (XMP priority, `/Info`
fallback, page-one fallback, arXiv-only) in `crates/aris-reader-cli/tests/metadata_fixtures.rs` and
`apps/macos/Checks/MetadataChecks.swift`.

## Reader interface

Lyra follows the system appearance with a warm cream/gold light palette and warm charcoal dark
palette. Document tabs share the top window row with the native window controls; the separate
native title strip is hidden and the empty tab-bar area moves the window. The native window
buttons are centred vertically in that row, with the new-tab button following the document tabs.
Tabs start at a fixed 250pt width and share the available space equally when the row fills;
very large tab sets scroll horizontally at a readable minimum width.
Toolbar drop-downs open below their controls in compact Lyra panels; document and thumbnail
context menus use the same styling. Icons, grouped commands, hover states, and
arrow-key/Return/Escape navigation are supported. The second toolbar button opens a full-window
page overview with adaptive thumbnails, selection, reordering and page operations. Double-click
a page to return to reading, or choose Done; the sidebar remains a separate control.
The tab row is followed by grouped view/zoom controls,
annotation tools, page operations, export, AI, and search. **Annotate** expands a second row for
highlights, underlines, selection notes, and six Lyra color presets. Existing indexed sidecar
colors retain their original values. Tools that are not implemented yet are disabled in their
reserved positions. PDF pages and existing PDF annotation colors stay faithful to the document.
Settings > Performance uses a grouped, wrapping layout for engine information and cache controls.

## AI assistant (ChatGPT plan or API key)

In **Settings > AI > Use AI with**, choose one connection:

- **ChatGPT plan:** press **Continue with ChatGPT**, finish the browser sign-in, and authorize
  Lyra to use your eligible ChatGPT plan. Choose a model from your account's catalog. Each saved
  connection keeps its own client registration and validated identity; **Add Account** creates
  another connection. **Manage usage in ChatGPT** opens the page for reviewing shared plan usage
  and app limits. Availability and remaining allowance depend on the account and plan.
- **API key:** the existing OpenAI-compatible endpoint, model, reasoning settings, and Keychain
  API key continue to work for hosted providers and local services.

ChatGPT connections use OpenAI's official [open-source Sign in with ChatGPT flow](https://developers.openai.com/siwc/token-sharing-open-source/sign-in):
loopback callback, PKCE, state/nonce validation, and RS256 identity signature verification against
OpenAI's published keys. Credentials stay in the macOS Keychain and refresh tokens rotate atomically.
Sign Out cancels active requests, attempts remote revocation, and clears credentials; if remote
revocation cannot be confirmed, Lyra points to ChatGPT Settings to disconnect the app.

ChatGPT inference uses the public Responses API with `store: false` and `stream: true`, as required
by the [official inference contract](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference).
It uses no Codex credentials, private ChatGPT endpoints, or API key fallback. Requests retain the
existing local context preview and explicit Send step. Changing the connection after preparing a
preview requires a fresh preview. Streamed usage-limit errors, incomplete answers, and interrupted
connections are failures with the partial answer preserved. Only `response.completed` completes a
request. The initial account/model discovery happens when connecting or refreshing the catalog;
PDF text is sent only after Send. Browser sign-in and a live eligible account are still required
to validate real subscription access; automated tests use synthetic credentials and mocked HTTP.

### API key connection

The API key connection in the AI sidebar speaks the
OpenAI-compatible `chat/completions` protocol — a base URL, a model name, and an API key — so the
same code works with OpenAI, DeepSeek, and a local Ollama
(`http://localhost:11434/v1`, any non-empty key). No vendor SDK is used.

**What it does.** Summarise the current page, summarise the whole document (split into parts for
long documents), ask a question about the current selection, and translate the selection. For a
long document, the per-part answers are kept, and a **separate consolidation request** is
previewed after the parts with its own page/character/token cost. Sending it produces the single
summary shown as the answer; it is never sent automatically, and if a part is missing the panel
names that part instead of silently consolidating the rest. Every answer streams. While streaming,
Cancel aborts the HTTP request and keeps the partial answer; Retry re-sends the plan that was
already previewed. Token usage is shown when the provider reports it. Answers are rendered as paragraphs, headings,
bullet lists and numbered lists; the model is instructed to cite sources as `[p.N]`, and only
that exact form with an in-range page becomes a clickable page jump. Bare numbers, `[12]`,
`[p.12–14]` and out-of-range pages stay plain text.

**Reasoning control.** Plain OpenAI compatibility has no standard reasoning switch, but the
provider exposes several request extensions. Settings > AI has two controls: a **mode**
(`provider default`, `off`, `low`, `high`, `max`) and an **encoding** (`none`, `thinking`,
`reasoning_effort`, `output_config`, `reasoning.effort`). The default is **off via thinking**
(`{"thinking":{"type":"disabled"}}`), because reasoning changes cost and latency. Lyra sends
exactly one chosen field and nothing else; unsupported combinations (such as an intensity with
the thinking toggle, or `off` via `output_config`) are rejected in Settings rather than silently
sending a different value. The request preview states in plain words what is sent
("Thinking: disabled" / "Reasoning effort: high") and shows the exact JSON body. If a provider
returns a 4xx naming an unknown or unsupported parameter, the error quotes it and points back at
the reasoning setting. The completion budget (`max_tokens`) is shown in the same preview and
remains user-editable; it is not silently raised.

`usage.completion_tokens_details.reasoning_tokens` (or a top-level `reasoning_tokens`) is
displayed as a subset of completion tokens. If the provider reports reasoning tokens when the
mode is `off`, the answer footer says so: the provider may have ignored the toggle.

**Reasoning is not the answer.** DeepSeek's thinking-mode models stream their analysis in
`choices[0].delta.reasoning_content` (the [DeepSeek streaming guide](https://api-docs.deepseek.com/guides/thinking_mode_api_example_streaming/)
shows a chunk carrying either `reasoning_content` or `content`). Lyra accumulates that channel
separately and never concatenates it into the answer, the translation, or the page linkifier.
If a stream ends with no content but the provider reported usage, the panel says so explicitly,
names `finish_reason` and the frame/delta counts, shows the HTTP status, content shape, byte
count and usage, and puts the reasoning in a labelled, obviously-not-the-answer section. A
`finish_reason: "length"` with no content says "The provider stopped at its token limit before
answering." A usage-only stream gets the same diagnostic; the usage line is deliberately small
and muted below it, never the headline. The reasoning text is not linkified.

**Other response shapes.** A streaming delta may carry `content` as an array of text parts
(`[{"type":"text","text":…}]`); those are concatenated in order. If a gateway ignores
`stream: true` and returns one ordinary JSON response, it is parsed as
`choices[0].message.content` (plus optional usage) rather than failing for a missing `[DONE]`.
A 200 response whose body is an `error` object is surfaced as the provider's `error.message`,
not as an empty success. `stream_options` is never sent, and the model name is passed through
exactly as typed (no catalogue validation or remapping); an endpoint error is shown to the
reader.

**Selection exactness and the line-number gutter.** The AI prompt slices the raw page text with
the same `TextChar` indices the canvas uses for drawing and copy. Page text is normalised only
for the surrounding page context and retrieval, never before extracting a selection: CRLF→LF and
whitespace changes would shift the range (the manuscript's `000`–`053` margin made that shift
very visible). Whatever the reader highlights is what the model receives, including partial words
at either edge and any internal whitespace; no word-boundary trimming is applied.

For page and document context, a **leading margin line-number block** is removed by a geometric
rule, not by stripping digits: the text layer must begin with at least five consecutive lines
that contain only digits, share an aligned equal-width column whose values increase by exactly
one, sit within 40 pt of the page's left text edge, and have a visible gap before the body.
Numbered list items and table rows carry other text on the same line, so they are left alone.
The committed `selection-numbered-margin.pdf` fixture and the local `manuscript_0925.pdf` prove
the page context has no `000`–`053` run while the abstract and the exact selected characters
survive.

**What it does not do, and says so.** No document chat, no region screenshots/vision, no
auto-retry, no background requests, and no automatic consolidation. A scanned PDF with no text
layer gets a clear message rather than a fabricated answer. The panel renders only the small
Markdown subset above; other Markdown is shown literally.

**Where the code lives.** The platform-independent half is Rust (`crates/aris-reader-ai`):
settings validation, page/block selection and BM25-style retrieval, prompt assembly, the exact
request body, the HTTP request, incremental SSE parsing, timeouts, cancellation and HTTP
status/API-error-body parsing. It is tested with a real loopback mock HTTP server. A
deterministic mock provider (preset strings, no socket) lets the Swift panel checks run without a
network. The Swift shell (`apps/macos`) owns the panel, the settings form, the request preview,
the Keychain, the answer renderer, and a polling handle over UniFFI (`startAiRequest` returns an
`ArisAiRequest`; `poll()` returns delta/usage/done/error events and `cancel()` stops the worker).

**Credential storage is the one per-platform piece.** The macOS shell implements this four-method
protocol (`AIAPIKeyStore` in `AIAssistantTypes.swift`):

```swift
readKey() -> String?
saveKey(_ key: String)
deleteKey()
hasKey() -> Bool
```

macOS uses a generic-password item in the login Keychain (service `com.alex.lyra.ai`, account
`openai-compatible-api-key`). A Windows shell should implement the same four methods with
Credential Manager/DPAPI; a Linux shell with the Secret Service. The key is read from the store
only when the reader presses Send, passed across the FFI for that one request, moved into the
worker thread, and dropped when the request ends. Rust does not store, persist, or log it, and
the plan/record types cannot carry it. Error bodies and debug output redact the key. The request
preview shows every system/user message and the exact JSON body (plus a redacted
`Authorization: Bearer <redacted until you press Send>`), so the reader can see what would leave
the machine before anything is sent.

**Transport and trust roots.** One in-process client (`ureq` 3.4.2 over `rustls` 0.23) handles
both `http://` and `https://`; there is no shell-out and no external program is required.
The loopback tests and the app therefore exercise the same connection, TLS, timeout, body-reader
and SSE code. Root certificates come from the operating system through `rustls-native-certs`
(Security.framework on macOS, schannel on Windows, the platform OpenSSL paths on Linux), so
OS-managed corporate roots work. The standard `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY`
environment variables are honoured by ureq's default connector; the macOS Network-pane proxy
settings are not read. If the platform store yields no certificates, the
client falls back to ureq's bundled Mozilla roots (`webpki-roots`, CDLA-Permissive-2.0); if
neither is usable the TLS handshake fails and the provider's certificate error is shown. Roots
are cached for the process.

Because ureq is synchronous, cancellation is handled below it: a small transport adapter passed
to ureq's connector wraps the real connection and bounds every blocking read to 100 ms or the
remaining idle budget. Between those short reads it checks the request's cancel flag and the
real idle (60 s) and total (300 s) deadlines. Cancel therefore returns promptly even when a
provider has stopped sending; the connection is dropped and the reader sees `Cancelled` rather
than waiting for the next token. The same adapter enforces the idle timeout for response headers
and for the SSE body.

**Protocol.** `POST {base}/chat/completions` with
`Content-Type: application/json`, `Accept: text/event-stream`,
`Authorization: Bearer <key>` and `User-Agent: Lyra/0.0`. The body contains `model`, `messages`
(system + user), `stream: true`, and optionally `temperature`, `max_tokens` and exactly one
reasoning extension. The response is parsed as SSE: each `data:` line is JSON,
`choices[0].delta.content` and `delta.reasoning_content` are accumulated in separate channels,
`choices[0].finish_reason` is recorded, an optional `usage` object (including reasoning-token
details) is shown, `[DONE]` ends the request, and EOF without `[DONE]` is an error. Every request
also produces a diagnostics record: HTTP status, bytes, frame/data counts, content/reasoning/
role-only/empty frame counts, content shape (string, array, complete JSON or none), finish reason
and usage. HTTP status and the provider's JSON error message are surfaced as readable text; 401
points at the Keychain setting and an unsupported reasoning parameter points at Settings > AI.
`stream_options` is not sent, so token usage appears only when a provider reports it in its
stream.

**Raw-stream trace.** Set `ARIS_READER_AI_TRACE=1` (any non-empty value except `0`) to print one
`aris-ai-trace:` line per response frame and one `request summary` line per request to stderr.
Each frame line names the frame type (`data` or `done`), the JSON keys it carried, and character
counts for content/reasoning. The summary has HTTP status, bytes, frame/data counts, delta-kind
counts, content shape, `finish_reason`, usage (including reasoning tokens) and no content
values. It never prints header values, the Authorization header, document text, answer text or
reasoning text; it is safe to send the log when asking why a provider produced no answer. The
environment variable is read once per process.

**Tests.** `cargo test -p aris-reader-ai` covers split JSON across SSE chunks, `[DONE]`, HTTP
401 with an error body, a mid-stream disconnect, cancellation (the loopback server observes the
connection closing), idle timeouts, and that the wire body equals the previewed body. The TLS
path is tested with a loopback `rustls` server and a generated CA: a full streaming round trip
with the CA injected into the client's roots, and a refusal when the server's certificate is
signed by a different CA. Stream fixtures cover content-only, reasoning-then-content, content
array, usage-only, a `finish_reason: "length"` stop with no content, non-SSE complete JSON and a
200 error body. The raw-selection and gutter regressions are checked against a committed
numbered-margin fixture (and the live manuscript when the local corpus is mounted): canvas hit
testing, copy and both prompt paths must produce identical characters, while page context loses
the margin run and keeps the abstract. Consolidation tests cover the one-request merge, its
prompt/cost, and a missing part naming the gap.
`ArisReaderChecks --check-ai-assistant .` covers settings validation, Keychain-hygiene (the key
never appears in UserDefaults or captured stdout/stderr; a real Keychain round-trip runs when the
login Keychain is available and is skipped, not faked, when it is not), the citation rules, the
reasoning settings, reasoning/empty-answer panel state, the truncated-at-limit message, the
four-action request profile (same model/temperature/max_tokens/stream/reasoning field, only
prompts differ), and the part-summary consolidation flow with the Rust mock provider. No check
makes a real API call.

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

**Presentation timestamps depend on the display being awake and the window unoccluded.** With the display
awake the harness measures real presented frames (46.81 and 43.11 fps on a real paper during a scripted
scroll); with the display asleep or the window occluded every drawable's Metal `presentedTime` comes back
as zero (436 of 436 in the harness, 297 of 297 in a minimal `CAMetalLayer`
probe), so a trace reporting `presented_fps: 0.0` is not evidence of a frame-pacing problem — and not
evidence of anything else either. Treat an all-zero presentation trace as "not measured", never as 0 fps:
the harness reports it as `presentation_measurement: "unavailable"` with a `presentation_measurement_reason`
and `presented_fps: null`, never as an fps together with a status of `"complete"`.
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

**The cache figure names what it covers.** The 48 MiB budget is shared by tiles and whole-page rasters;
sidebar thumbnails and text layers are held outside it. `aris-stats:` therefore prints
`tiles X/Y MiB`, `pageRasters Z MiB` and `shared X+Z/Y MiB` — the number the budget actually bounds —
followed by `thumbnails`, `text` and `rasters total` for what it does not, and `aris-band:` uses the
same names. On the real 115-page paper at 140% the line used to read `cache 0 tiles · 0.0/48.0 MiB`
while three 14.5 MiB page rasters were resident: 43.5 MiB of page rasters + 8.3 MiB of thumbnails +
0.5 MiB of text = 52.3 MiB held, of which the budget covered the 43.5 MiB of page rasters and none of
the rest. The verification's own accounting on its 140% run was 48 MiB of budgeted rasters + 7.2 MiB of
thumbnails + 1.4 MiB of text = 52.1 MiB. Peak RSS is unaffected by the wording; it stayed in the same
460-499 MiB band across three runs before and three runs after.

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

**The screen-resolution page path is not always available, and says so when it is not.** It needs one
page raster of at most `min(cache budget / 2, 32 MiB)`, at most 8192 px on the page's longest side, at
most seven pages on screen, and the on-screen pages' rasters together inside the whole budget. A US
Letter page at 140% on a 2x display is 1714x2218 px = 14.5 MiB, so a cache budget below 29.0 MiB
(30 MiB as the first whole-MiB setting that fits) turns the path off and falls back to tiles. That is
announced rather than silent: stderr gets one `aris-screen-page: off: ...` line per change naming the
limit that failed and the budget it needs, `ARIS_READER_RENDER_STATS=1` carries
`screenPages off(page 14.5>8.0 MiB; budget <29.0 MiB)` (or `on`, or `off(feature-off)` for
`ARIS_READER_SHARP_PAGE_RASTERS=0`), and `AppState.screenPagePathNote` exposes the same reason to the
UI. The four thresholds are stated in `screenPagePathDecision`.

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
not the handler's arrival time or the CPU submission timestamp. A zero timestamp counts as a reported
drop only when other callbacks in the same trace carry a real host time. When no callback carries a
positive timestamp, `presentation_measurement` is `"unavailable"` with a `presentation_measurement_reason`
and `presented_fps`, the presentation gap tails, `presented_frames` and `motion_presented_frames` are all
`null`: the session reported no presentation time (a sleeping display or an occluded window), so the trace
never claims 0 fps and never claims `"complete"`. The raw evidence stays: `presentation_callbacks`,
`presentation_callbacks_missing`, `presentation_zero_timestamps` and `presentations_outside_window` are
counts.
Missing callbacks make FPS and presentation tails unavailable; they never count as
confirmed drops. Frames presented after the scrolling window are reported separately.
`presented_fps` counts frames over the full scrolling interval; frame gaps include both edges,
and `motion_presented_frames` separates frames whose scroll position changed. This records
system-reported drawable presentation, not physical scanout, display refresh rate or GPU
execution time. Scripted input is not a physical trackpad trace, and a finite run alone does
not certify the 60 fps criterion. Legacy logs remain readable but cannot supply presented FPS.
Peak RSS (`wait4`), CPU submission pacing (`submission_gap_*`, `input_gap_*`) and draw-CPU
timings (`draw_cpu_p95_ms`) are unaffected by presentation availability and stay real.
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
ARIS_READER_PDFIUM_PATH="$PWD/vendor/pdfium/lib/libpdfium.dylib" \
  apps/macos/.build/release/ArisReaderChecks --measure-page-fallback /path/to/paper.pdf 140
```

`2.8` represents 140% on a 2x display. The first command totals actual BGRA bytes across all pages
while retaining at most three; it reports raster median/p95 and `/usr/bin/time` reports process peak RSS.
The second uses a temporary document copy, a 959×715pt viewport at 2x, and measures model raster
readiness on cold, neighbor, return and distant jumps (PDFs longer than eight pages). It reports partial
sharp updates and immediate sharp cache hits. It excludes GPU upload and presentation, so it is not FPS
or end-to-end visual latency. `ARIS_READER_SHARP_PAGE_RASTERS=0` disables the screen-page path for a
feature-off comparison under the same pixel budget. Deep zoom remains on tiles.

What a cold page shows *before* its sharp raster is measured, not assumed. The third command records the
canvas-update quality timeline for cold, neighbor, return and distant jumps; on a real 115-page paper
(959×715pt viewport, 2x backing scale, 48 MiB budget, medians of five runs in one interleaved A/B) it
shows: at 100% the 264×342 sidebar thumbnail for 20.1 ms, then a sharp 1224×1584 raster at 20.8 ms; at
140% the same thumbnail for 28.3 ms, then 1714×2218 at 28.8 ms (the verification measured 39-51 ms on
its machine); at 400%, where the tiled path is used, the thumbnail for 7-14 ms, then a 1x 612×792
preview for 35-55 ms, then sharp tiles. A destination past the first 24 pages and outside the prepared
neighborhood has no thumbnail at all and shows nothing for 16-28 ms instead. Rendering a half-scale
raster first was measured and rejected: it halves the blurry window (28.3 → 13.7 ms at 140%, 20.1 →
11.1 ms at 100%) but adds a whole extra render before the sharp one (28.8 → 49.6 ms and 20.8 → 59.4 ms
to a sharp page), which is the property this path exists to protect.

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
| M2 | Reading experience | Core implemented; normal-open initialization, tab/cache isolation and stale search handling repaired. Named, reorderable user bookmarks (sidecar-persisted) and facing pages with a configurable page gap are implemented. Cross-page selection, incremental search, navigation history, split view and full session restoration remain. |
| M3 | Annotation and editing | Partial: durable sidecar highlights/underlines/notes with undo/redo, and PDF write-back (Save Annotated Copy / Save and Replace Original) for highlights, underlines and `/Text` notes with verified atomic writes, a byte-identical backup on replace, append-only saves and sidecar deduplication. Highlight appearance streams are not written because PDFium's C ABI cannot express the multiply blend (see the write-back section; PDFKit synthesizes the mark correctly). A sidecar that cannot be read still refuses every write, but the reader can back it up and start fresh from the alert (the original file is moved, never overwritten). Note edits coalesce their disk writes and flush on commit, document switch, tab close and quit. Annotations are exported as Markdown or CSV, labelled with their source and threaded by reply. Ink, free text, page operations and AcroForm forms remain; the sidecar still lacks document-fingerprint validation and cross-process conflict detection. |
| M4 | Advanced reading | Partial: resizable, scrollable previews; complete resolved citation text with entry switching; Algorithm detection; full-page fallback for uncertain table/vector regions. A `Table` reference previews the grid its border lines form — 20 of the 41 table captions in the twelve sample papers, the rest falling back to the page. A grouped citation resolves to **every** work it names (`[1,11,19]` lists three entries), and bibliography entries are modelled as fragments (page and glyph range each), so a cross-page continuation is no longer a truncated rectangle. On the **twenty-paper arXiv corpus**, 94.7% of 1979 detected citation spans resolve — the evaluation set is links only, no PDF is committed. Alphanumeric labels and groups (`[HR18]`, `[MCCD13, PSM14]`, `[VSP+ 17]`) now resolve: GPT-3 has 203 spans and 144 bibliography entries. Superscripts on papers that bracket their citations remain unsupported. Bare parenthesised numerals - (12), (3-5), (7, 9) - are detected when the document proves its bibliography is numeric and its body does not already bracket those citations, with equation numbers, function calls, years, enumerations, figure sub-labels and out-of-range labels rejected by position and context; a Science paper in the evaluation set went from no spans to twenty resolved ones while every other row stayed identical. A column gutter is now detected from the character runs inside each line (52 of the corpus's 298 pages, all in its seven two-column papers; the five single-column papers acquire none). Unlinked equations, vector-figure segmentation, pinning and index persistence remain. Document metadata (title, authors, venue, year, DOI, arXiv id) is recognised from XMP, `/Info` and page one, shown with per-field provenance in a sidebar section, editable, and exported as BibTeX with an offline generator. |
| M5 | AI assistant: summarization, translation, document chat, region-based discussion, RAG, local models | Partial: OpenAI-compatible streaming page/document summaries, selection Q&A and translation, local/remote visibility, request preview, Keychain, cancel/retry, usage and `[p.N]` page links. Document chat, vision/region discussion, summary merging and cross-platform credential stores remain. |
| M6 | Cross-platform: Windows / Linux shell and packaging | ⬜ |
| M7 | Polish: performance, accessibility, internationalization, auto-update, notarized distribution | ⬜ |

## License

This project is released under the MIT license (see [ADR-0005](docs/adr/0005-licensing.md)).
Third-party components: PDFium (BSD-3-Clause), wgpu (Apache-2.0), pdfium-render (MIT/Apache-2.0), UniFFI (MPL-2.0, build-time tooling only), ureq (MIT OR Apache-2.0), rustls (Apache-2.0 OR ISC OR MIT), ring (Apache-2.0 AND ISC), rustls-native-certs (Apache-2.0 OR ISC OR MIT), webpki-roots (CDLA-Permissive-2.0), rcgen (MIT OR Apache-2.0, tests only).
**No AGPL components** (MuPDF is excluded).
