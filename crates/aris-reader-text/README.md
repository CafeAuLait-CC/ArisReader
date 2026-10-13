# Citation/reference parsing audit

The citation preview uses this crate through both the CLI and `DocumentHandle` in
`aris-reader-ffi`. The types in `aris-reader-ai::citation` are not the parser used
by the current UI. This change keeps the Swift/UniFFI interface unchanged.

## Why the previous fixes regressed other papers

The old selector ran numeric parsing first and tried author-year parsing only if
the numeric result was empty. It then selected the largest consecutive run of
pages producing *anything*. Body citations, numbered instructions and bracketed
years could join that run, while one numeric false positive hid an entire page's
author-year bibliography. Picking whichever parser returned more entries on each
page did not solve the document-level problem.

There were independent downstream failures too:

- A wrapped author list split `He, ... / Tan, ... 2024. GAIA` into the wrong entry.
- Dropping `2023a/b/c` merged different works under the same key.
- Searching any entry text for a surname/year matched coauthors and titles.
- Link landings retained only Y. Horizontal bands merged two columns and sparse
  links dropped uncited entries. Pan's correctly parsed 35 entries could be
  overwritten by an incomplete reconstruction.
- `Lasseter [1987]` was treated as numeric entry 1987; full-name bibliographies
  were not keyed by the author's surname.
- Repeated bibliography page headers and wrapped DOI fragments interrupted long
  reference lists. Citation hit counts on the first three pages cannot catch this.

## Implemented approach

Keep numeric and author-year candidate runs independent until document-level
selection. Score the run using entry count, publication-year evidence, label order
and a heading bonus. Numeric labels must continue across adjacent pages; missing
pages and style changes cannot bridge a run. A heading starts a fresh run, while
repeated headers continue an established list. The separate page-density score is
still diagnostic, not a gate on this decision.

Within a page, keep the longest sequence of a single numeric delimiter style.
Recognize inverted, full-name and corporate author prefixes; continue a wrapped
author list until its year. Preserve year suffixes, exclude arXiv numeric IDs from
year extraction, and retain source character offsets for preview rectangles.
Full names remain a conservative heuristic, not a general personal-name parser.

Only unique labels resolve. Compound surnames may match a suffix of the first
author's name with the same year, uniquely. An arbitrary coauthor/title/year
substring is no longer a fallback. Numeric ordinal fallback for unnumbered lists
is retained for compatibility; it remains unsafe if extraction misses entries.

Link bands can refine only selected bibliography pages, must retain every parsed
label, and must select contiguous source characters. Otherwise keep the parsed
entries. A Y-only destination is not enough to reconstruct arbitrary columns.

## Reproducible checks

Ordinary tests need no PDFium library or sample PDFs:

```sh
cargo test -p aris-reader-text
cargo clippy -p aris-reader-text -p aris-reader-cli --all-targets -- -D warnings
```

For real PDFs, set `ARIS_READER_PDFIUM_PATH` to a compatible shared library and
optionally `ARIS_READER_PDF_SAMPLES` to the sample directory (default: `pdf-samples`).
The opt-in test fails if samples are missing; the PDFs are never committed.

```sh
cargo test -p aris-reader-cli --test reference_corpus -- --ignored --nocapture
cargo run -p aris-reader-cli -- cite paper.pdf --show-entries --show-misses
cargo run -p aris-reader-cli -- cite paper.pdf --no-landings --show-entries
```

The corpus test checks hit-count floors, actual entry identities/titles, original
character ranges, InstructAvatar's bibliography pages, Pan's 35 numbered entries,
and Candidacy's complete 1–185 sequence. Synthetic tests cover the failure modes
above, ambiguous identities, Unicode offsets and unsupported link geometry.

## Measured comparison

Compared with `9ce142e`, using the same PDFium 157.0.8100.0 Linux library and the
first three pages of each local sample. Values are **resolved detected spans**,
not precision or recall against a fully annotated ground truth. Grouped citations
still return one preview, so a resolved group does not establish coverage of every
work named in it.

| Sample | Before | After |
| --- | ---: | ---: |
| InstructAvatar | 9/25 | 25/25 |
| manuscript | 21/30 | 30/30 |
| Dvorožňák | 0/10 | 9/9 |
| Pan | 25/25 | 25/25 |
| HumanML3D | 31/31 | 31/31 |
| Yin | 38/38 | 38/38 |
| Zhang / HumanMM | 18/18 | 27/27 |
| SMooDi | 13/13 | 13/13 |
| Ye | 27/28 | 27/28 |
| Leader | 1/2 | 1/1 |
| QualifyExam / Candidacy | no detections in first 3 pages | same |

The changed denominators matter: Dvorožňák and Leader exclude a publication-date
parenthesis; HumanMM gains Unicode-dash numeric ranges. Ye's remaining detected
miss is `(NeurIPS 2024)`, illustrating why this metric is not recall. InstructAvatar
now indexes 49 entries on pages 8–9; `Ma 2023a/b/c` resolve to distinct titles and
the duplicate `Tan 2024` intentionally remains ambiguous. Candidacy now indexes
the printed 185 entries on pages 55–82, rather than 239 mixed candidates.

Linux validation: 51 text tests, the opt-in 12-PDF test, portable workspace tests
(excluding GPU/FFI), formatting and targeted strict Clippy passed. This host's
Rust 1.99 compiler crashed with SIGSEGV building untouched dependencies: initially
image dependencies at optimization level 3, then UniFFI/wgpu during full-workspace
attempts. Portable checks used command-line profile overrides, without changing
the repository's profiles:

```sh
--config 'profile.dev.package."*".opt-level=0' --config profile.dev.opt-level=0
```

The macOS Swift UI and full GPU/FFI build were not validated here.

## Next steps

1. Represent bibliography entries as page/column fragments with explicit glyph
   ranges, and retain X as well as Y for link destinations. That enables safe
   multi-column/cross-page previews and footer removal. The current single
   `page,start,end` range cannot express an entry continuing on another page.
2. Use bibliography evidence to constrain citation detection, then resolve every
   member of grouped citations into a list of stable entry IDs. Extend narrative
   parentheses, superscripts, multilingual styles and hyphenated/compound names
   using annotated fixtures rather than expanding a global regex.
3. Add an annotated corpus with expected source spans, entry boundaries and target
   rectangles. Report detection precision, entry completeness and resolution
   accuracy separately; abstention on ambiguity is preferable to a wrong popover.
4. Keep layout recovery and optional bibliographic metadata parsing separate.
   A metadata model cannot repair a preview rectangle that already mixes columns.
