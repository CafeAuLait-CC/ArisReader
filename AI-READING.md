# AI reading workflow

The right sidebar has independent Summary, Translate and Chat tabs. Opening it overlays the reader canvas without changing the PDF viewport, raster scale or Metal view. AI and Edit inspectors are mutually exclusive; a text draft is committed before switching.

Summary offers Document or Selected text. Both build one independent request containing the complete extracted target, with no page-by-page requests or follow-up consolidation. Selected text uses the canvas character range exactly and adds no surrounding context. Documents above 240,000 extracted characters are refused locally rather than truncated. Images and figures are not sent; providers can also reject their own context limits.

The academic reading prompt asks for a short takeaway, research question, approach, contributions, evidence/results, limitations/assumptions and reading notes, using only available evidence with page citations. Missing information must be stated rather than invented. Translation preserves paragraph structure and technical terms.

Chat uses a warm question bubble and a separate answer surface with Copy. Source passages are collapsed by default and expand to page links. The composer stays at the bottom; streaming follows the answer while near the end and stops following when the reader scrolls up. Conversations remain bounded and isolated per document. Review builds the local passage/request preview; Send is the only action that starts a provider request. Tests use scripted streams and do not contact a provider.
