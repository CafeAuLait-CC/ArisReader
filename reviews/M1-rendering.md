# M1 review — rendering and PDFium concurrency

Reviewed against local `docs/07-roadmap.md` and `docs/08-tasks.md`, 2026-10-13.

## Fixed

Document loading used a different lock from page operations, and automatic document
teardown escaped the process transaction lock. Loading, reading, rendering and
teardown now share `PDFIUM_LOCK`; immutable page counts are cached under that lock.
The concurrency regression repeatedly opens, extracts text/links/outline, renders
and destroys documents from four workers.

## T1.3 decision

Keep PDFium serialized. The public header requires that only one PDFium call runs
at a time, even across independent document copies:
https://pdfium.googlesource.com/pdfium/+/refs/heads/main/public/fpdfview.h
The pinned pdfium-render wrapper also has a per-call global mutex; removing the
outer lock does not create supported parallel rasterization and loses transaction
isolation. `reopen()` provides ownership isolation, not parallel PDFium execution.

Prefer visible-tile priority, dropping obsolete queued requests, and incremental
indexing over additional in-process workers. A process pool could provide real
parallelism, but requires an IPC protocol, worker crash recovery, duplicated document
memory and benchmarks proving the gain exceeds those costs. Do not enable it by
removing a lock.

## Remaining exit criteria

M1 is a usable core, not a completed milestone: the 300-page first-frame latency,
60 fps scroll budget, 400 MB memory ceiling and 20-page image baseline have not been
established by the current test suite. Horizontal navigation at deep zoom, viewport
anchoring, failed-tile retry/backoff, task cancellation and budget enforcement need
further work. The fixed 48-entry CPU cache can exceed its nominal limit when all
requested tiles are pinned. Configuration settings are not wired to that cache.

Validation: PDFium unit tests plus the lifecycle stress test; see the final review
report for workspace, corpus and native-shell checks. Passing stress tests does not
prove that unsupported concurrent PDFium calls would be safe.
