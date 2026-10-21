# AI reading workflow

The right sidebar has independent Summary, Translate and Chat tabs. Opening it overlays the reader canvas without changing the PDF viewport, raster scale or Metal view. AI and Edit inspectors are mutually exclusive; a text draft is committed before switching.

Summary offers Document or Selected text. Both build one independent request containing the complete extracted target, with no page-by-page requests or follow-up consolidation. Selected text uses the canvas character range exactly and adds no surrounding context. Documents above 240,000 extracted characters are refused locally rather than truncated. Images and figures are not sent; providers can also reject their own context limits.

Above the one-shot actions, Summary also shows a layered summary the reader can navigate. The abstract is one paragraph from a bounded prefix of the document (at most 12 pages / 48,000 characters); sections match the outline, or page ranges of ten when the document has no outline, and send at most 64,000 characters each; pages are one line each, from at most 8,000 characters. Each row is one independently previewed request, so the abstract never requires summarising every page first. A Generate press previews at most 24 requests and sends at most 2 at a time; progress is shown per row, Cancel keeps completed rows, and a failed row retries its own request. Clicking a section or page row jumps to that page. Rows state their page span and a truncation line such as "Summarised from pages 1-12 of 20." Summaries are cached per document by model, language and a SHA-256 hash of exactly the covered text, in `summaries.json` inside the annotation cache directory (never beside or inside the PDF); reopening shows cached rows without a request, and an edited section invalidates only its own row. A blank language means the document's own language.

The academic reading prompt asks for a short takeaway, research question, approach, contributions, evidence/results, limitations/assumptions and reading notes, using only available evidence with page citations. Missing information must be stated rather than invented. Translation preserves paragraph structure and technical terms.

Chat uses a warm question bubble and a separate answer surface with Copy. Source passages are collapsed by default and expand to page links. The composer stays at the bottom; streaming follows the answer while near the end and stops following when the reader scrolls up. Conversations remain bounded and isolated per document. Review builds the local passage/request preview; Send is the only action that starts a provider request. Tests use scripted streams and do not contact a provider.

## Local audit trail

Every outgoing AI request appends one record to a local audit file in the application cache
(`LyraReader/Audit/ai-requests.jsonl` for the current macOS user): a multi-part plan writes one
record per part, and a layered-summary Generate batch writes one record per previewed unit (up to
24), not one line for the batch. The record holds the time, the
action kind, the endpoint host, the model, the number of characters sent, the page numbers, the
attached picture's pixel size, the outcome and the duration. Its shape has no field for document
text, questions, answers, file paths, document names or image bytes. The newest 500 records or
256 KiB are kept; older entries are dropped. Clear in the AI panel truncates the file.

The panel's "What AI requests send" list is the live inventory: selected text and page text,
retrieved passages, region text and (when image input is on) the region picture, questions and the
last six chat exchanges, the layered summary's per-entry text, the part summaries for a
consolidation, the document's display name, and the instruction prompts. The PDF file,
its embedded files, the file path, annotations, reading history and other documents are not sent;
a whole-document summary does send every page's extracted text. A Rust guard
(`crates/lyra-reader-ai/tests/network_guard.rs`) fails if the AI layer gains an unlisted network
call or an analytics identifier without an explicit opt-in gate.
