# M4 review — preview completeness and interaction

## Fixed

- Replace fixed 300×380 previews with compact/expanded widths constrained to the
  reader viewport and height matched to the selected region, independent scrolling,
  loading/error states and full-page access.
- Invalidate pending renders on close, document change and subsequent previews;
  invalidate deferred citation/figure lookups on newer pointer interactions.
- Remove the three-line citation text truncation, allow text selection, and let
  each resolved group entry select its own page/region while keeping the group.
- Prefer a resolved citation/figure over a generic internal page link. External
  HTTP/HTTPS/mail links retain their existing behavior.
- Detect Algorithm/Alg. captions and mentions, retain character indices around
  Unicode whitespace/invalid codepoints, and stop treating every line-start
  `Figure N shows ...` phrase as a caption.
- Tables, algorithms and figures without confident raster artwork use the whole
  CropBox. This deliberately shows surrounding content instead of a caption-only
  image that omits the actual table/vector artwork.
- Transform all four corners of figure/link/destination regions, including
  rotated pages and nonzero crop origins. Region rasterization now enforces the
  same pixel/edge limits as page previews and returns region point dimensions.
- Crop edge-tile pixels to actual page bounds instead of stretching a square tile
  or drawing white page content beyond its right/bottom edges.
- Native UI testing exposed inverted wheel scrolling; normalize AppKit deltas
  for both main and preview canvases. Keep the page HUD behind the preview.

## Validation

Rust unit tests cover caption/mention classification, algorithms, CropBox fallback,
rotation, link bounds and region validation/budgets. The 12-document reference
corpus passes its identity/coverage checks. Swift executable checks deliberately
complete an older preview after a newer one, close during rasterization, switch
entries/documents, exercise tall-preview scroll bounds and report render errors.
Native smoke checks exercise an actual paper and two GPU surfaces.

## Remaining work / limits

- **Unlinked equations:** no reliable equation-number-to-region index exists.
  Existing internal links can show their target page, including formulas. A text
  match such as `Eq. (3)` alone would not locate the equation. Build a labeled
  layout/anchor dataset before claiming support for unlinked equations.
- **Cross-column / cross-page bibliography entries:** the model still has one page
  and rectangle per entry. Text is no longer UI-truncated, but extraction can
  still omit continuation fragments. Full page is an escape hatch, not a complete
  fragment model. Next step: ordered `(page, rect, text)` fragments per entry.
- Caption grammar accepts numeric labels and punctuation-separated captions;
  Roman/sub-number/plural forms and scanned documents need separate work. A line
  beginning `Figure 3.` can still be ambiguous with prose.
- Raster artwork grouping can omit caption continuation lines or distant panels;
  full-page mode provides context. Tables/vector diagrams are not precisely
  segmented, and multi-page tables/algorithms still need fragment navigation.
- Index scans retain the 120-page limit. Index caching on disk, confidence scores,
  independent draggable/pinnable panels, keyboard citation navigation, and preview
  latency targets remain open. Whole-document scans can delay cold previews.
