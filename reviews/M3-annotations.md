# M3 review — durable sidecar annotations

Fixed three data-integrity problems: synthesized Codable decoding rejected older
sidecars without `kind`; `try?` hid read/write failures and permitted replacing an
unreadable sidecar; note edits were not part of undo/redo.

Legacy entries now default to highlight. Invalid sidecars (including invalid
page/range/color or duplicate IDs) report an error and block writes until reopened
after repair. Each edit is atomically persisted before publishing its in-memory
state or advancing the undo stack. Save failures are visible in the reader's error
alert. Consecutive note edits coalesce into one undo step.

`ArisReaderChecks` covers legacy decode, highlight/underline persistence, note
undo/redo, deletion undo, document isolation and reopen, failed atomic writes,
corrupt-file protection, and first-time sidecar creation, using temporary files.

## Remaining milestone work

These are application sidecars, not PDF annotations: other readers do not see them.
M3 remains incomplete until PDFium annotation import/write-back, external-reader
round trips, safe PDF saving, ink/shapes, page operations, export, forms and the
other roadmap items ship. Sidecars still identify ranges by character offsets and
path; edits to the underlying PDF need fingerprint/version validation. Concurrent
editing of one sidecar from another process still needs conflict detection.
