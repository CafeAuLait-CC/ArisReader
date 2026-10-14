# M2 review — document lifecycle and reading UI

The ordinary File → Open path did not initialize links, citations, references,
annotations or outline; initialization lived in the development launch hook.
Switching files retained caches keyed only by page number. Late async results could
repopulate those caches for the wrong document. Closing an inactive tab switched
documents, and a failed open could select a tab for a file that never opened.

The fix centralizes document setup/reset, rejects results and in-flight cleanup
from old generations, makes tab opens transactional, and invalidates superseded
search results. RustEngine's asynchronous figure cache is also document-scoped.
Canvas invalidation compares placements as well as image generations, so moving
an equal-length selection refreshes its highlight geometry.
The tab strip and scroll indicator are now mounted; sidebar and search shortcuts
are wired, and thumbnail placeholders past page 24 request images on appearance.

## Reproduce regression checks

Run `scripts/build-rust.sh --debug`, then `swift build --package-path apps/macos
--disable-sandbox`. Execute `apps/macos/.build/debug/ArisReaderChecks "$PWD"` from
repository root. These use disposable fixture copies and exercise real PDFium/FFI,
normal open, search clearing, tab restoration, failed open, inactive-tab closure,
and pending work after final-tab closure. No XCTest or full Xcode is required.

## Remaining M2 scope

M2 is partial: cross-page selection, reading order across columns, cancellable
incremental search, navigation history, bookmarks, split views, facing pages,
full window/session restore and dark-page/accessibility work remain. Document-wide
index scans and queued requests are still serialized; generation guards discard
stale results but do not cancel an already executing PDFium operation. Thumbnail
loading is demand-driven, but its cache still needs an independent memory budget.
