# PDF document saving

Save (Cmd-S) writes an unsigned document to its original path through the existing verified PDF
replacement transaction. Save As (Shift-Cmd-S) is explicit. A digitally signed original remains
protected; Save offers a copy. The same commands serve annotation and page-content editing.

User edits live in `Library/Caches/LyraReader/Documents/<path digest>` on macOS. Annotation records,
pending deletions and dirty state are atomic cache files. Content/page operations create cached PDF
revisions and a recovery manifest containing the current revision and undo/redo snapshots. Opening
the original restores an interrupted session only when its SHA-256 identity still matches. Touching
unchanged bytes is allowed; external content changes preserve recovery data and refuse replacement.
`LYRA_READER_DOCUMENT_CACHE_DIR` overrides the location for checks or managed deployments.

Before changing body text or rotating a marked page, the app embeds cached marks into PDF geometry
in an internal revision. This prevents stale character offsets and removes the earlier manual
annotation-export prerequisite. Undo restores the PDF and its cached annotations together. Save
publishes the combined body, annotation and bookmark revision, then retires its recovery data.
If post-save cache cleanup fails, the PDF stays saved and the remaining cache is reported.

Old `.lyra-reader-annotations.json` and `.aris-annotations.json` companions are imported once. The
record codec retains unknown fields/entries; a byte-identical backup is placed in the cache before
the old companion is removed. Invalid data is preserved for explicit recovery. New editing does not
create adjacent JSON files. Extract, merge and split embed marks in their output PDFs; split and
extract remap the reader's bookmarks into each output's outline.

Derived reference indexes also live in the platform cache (`LyraReader/Indexes`), with full PDF
content identity and their existing atomic format. They use XDG cache locations on Linux and local
application data on Windows. `LYRA_READER_INDEX_CACHE_DIR` overrides this disposable cache. Legacy
index companions are no longer read or written; their contents can be regenerated from the PDF.

Verification: native `--check-document-cache`, `--check-content-editing`, `--check-page-operations`,
annotation/writeback/signature regressions, and Rust index-cache/long-document tests. Native checks
isolate both caches from the user's data and remove their temporary cache on exit.
