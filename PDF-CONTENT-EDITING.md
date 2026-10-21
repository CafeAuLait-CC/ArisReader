# PDF content editing

The macOS **Edit PDF** workspace edits actual PDF page objects through a separate working copy.
The original is untouched until an explicit save or verified replacement. Saving a copy opens that
copy. A digitally signed original stays protected from replacement; changing its content produces
an edited copy, not a newly valid digital signature.

## Interaction

Edit PDF opens the same secondary toolbar slot used by annotation tools: Select, Text, Image,
Link and Redact. Redact's inspector chooses Erase or Blackout. The right inspector contains
properties for the selected tool/object, with opaque light/dark semantic surfaces and controls
from the Lyra palette. Switching back to Annotate commits any active text draft first.

- Select: solid paragraph hover, dashed first-click selection, hand drag, second-click text caret.
  Esc cancels the active caret draft. Cmd-Return commits it. Clicking elsewhere or saving commits
  it too. Ordinary typing uses the native text editor's undo; committed changes use document undo.
- The inspector changes text font, size, alignment and colour. Dragging a text frame's corner
  reflows editable text at its current font size. Text inserts new page text, with the same body
  editing controls; this is distinct from a PDF annotation text box.
- Images and isolated vector figures can move, resize, rotate, be replaced, exported as PNG, or
  cropped. Embedded bitmaps export their original pixels; vector groups export the selected
  region's rendered appearance. Cropping a vector figure preserves vectors and fonts. Cropping
  hides content; use Redact to actually remove sensitive content.
- Nested vector labels can move with alignment guides while keeping their exact drawing. The
  inspector explains when their words cannot be replaced. To manipulate the entire graphic,
  select its open area rather than its smaller text or picture children.
- Link highlights every link annotation on the current page and labels its destination. Drag an
  empty area to create a link; the inspector chooses a page or URL and edits existing links.
- Erase and Blackout remove covered characters and intersecting graphic objects, then rebuild
  text regions. The content workspace refuses operations that would require rasterizing a whole
  page. The separate existing redaction workflow retains its explicit raster fallback.

An overflowing or unsupported text write preserves the previous revision and the typed draft.
The inspector lets the reader copy, change the font and retry, or discard that draft. Tab changes
wait for a pending write; closing an edited tab offers Save, Discard and Cancel.

## Why the earlier narrow text replacement was insufficient

PDFs generally encode positioned drawing instructions rather than paragraph models. A visible
line may span many Tj/TJ operations and fonts; TJ arrays encode kerning and spacing. The earlier
simple-run path rejected these layouts and could only replace a small subset of paper text.
The new path groups objects spatially into lines and paragraphs, and replaces eligible top-level,
uniform-font text objects. It measures and wraps new text, then writes normal PDF text objects.
A private page entry stores frame geometry and a text digest, never an old plaintext copy, so a
short edit does not shrink the next editable frame to its ink bounds.

PDFium does not persist edits to a Form's children when regenerating the page. Regenerating a Form
as a temporary page can also reencode subset font text incorrectly. Nested moves therefore preserve
raw operators and copy only the selected Form occurrence and its ancestors. Complete isolated q/Q
graphic scopes can be wrapped in a Form for whole-figure operations. Operator counts must agree
with native object counts; ambiguous scopes are not guessed.

Redaction associates native characters with their actual text objects. Unrelated formulae or
ligatures elsewhere on the page therefore cannot shift all later encoded-glyph indices. Only
selected text operations need exact CMap and origin correspondence. Surviving TJ segments become
separate text objects, allowing a remaining half paragraph to form its own region.

## Limits

This is local block editing, not a word processor: it does not reflow surrounding paragraphs or
pages. Mixed fonts, formula layouts, Type3 fonts and text nested inside graphics are move-only.
A subset font may lack new characters; the writer rejects failed Unicode round trips and preserves
the draft. The inspector offers standard PDF fonts and the bundled LyraReader Sans SC font; its
coverage is checked before writing. Scanned text needs OCR before it can be edited as text.

Nested picture replacement/cropping/deletion requires selecting its complete graphic. Detection
of an arbitrary collection of flat paths as one semantic figure is conservative. Crop controls use
retained-edge percentages. Existing PDF links are supported; arbitrary producer-specific actions
remain labelled as other destinations until replaced with a supported page or URL.

Pages carrying LyraReader sidecar text-position marks/bookmarks currently require saving those
marks into a PDF copy before body editing. The editor refuses to silently leave stale text anchors.
Unsupported nested redaction is refused in this workspace rather than flattening surviving text.

## Verification

Commands carry a SHA-256 source revision and object paths. Writes use atomic working revisions;
failures leave source and destination unchanged. Every successful edit reopens the PDF, checks
structural preservation, and compares every other page's pixels. On the edited page, changed pixels
must stay within the old/new object region. Text writes also verify the requested Unicode content.
Crop/rotation use the same page/view geometry transforms as the reader. Committed revisions share
the existing page-edit undo, redo, save-copy and signature-aware original replacement transaction.

Run `cargo test -p lyra-reader-pdfium --test content_edit` for focused engine tests. Set
`LYRA_READER_PDF_SAMPLES` to the local sample directory to additionally test `manuscript_0925.pdf`:
actual embedded-font body replacement, the green Time-Aware Pose Encoder label, chart cropping,
and page 7 partial erasure. Synthetic coverage includes TJ kerning, shared Form isolation, flat
vector groups, image insert/crop/replace/export, links, Chinese, unsupported glyphs, stale revisions,
and 0/90/180/270-degree cropped-page insertion and reediting.

After rebuilding Rust bindings and Swift, run
`apps/macos/.build/debug/LyraReaderChecks --check-content-editing "$PWD"` for native mouse/caret,
undo/redo, save-active-draft, failure recovery, link/erase drags, signed-file protection, tab lifecycle
and full ReaderWindow hit-testing checks. `LYRA_CONTENT_EVIDENCE` optionally writes a chrome
snapshot (AppKit's cache does not include the Metal page layer). `scripts/check.sh` runs the full
workspace checks and macOS regression suite.
