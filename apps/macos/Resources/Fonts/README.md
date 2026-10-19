# Bundled appearance font

`LyraReaderSansSC-Regular.ttf` is the font LyraReader embeds in `/FreeText` annotation appearance streams.
It is a **subset of Noto Sans SC** (SIL Open Font License 1.1), not a system font, and no glyph
outlines were copied out of a system font.

| | |
| --- | --- |
| Upstream | Noto Sans SC, variable font at `wght=400` (`google/fonts`, `ofl/notosanssc`) |
| Licence | SIL Open Font License 1.1 — see `OFL.txt` |
| Shipped file | 3,628,760 bytes |
| Glyphs | 11,973 (12,007 mapped characters) |
| Reserved name | The OFL copyright line reserves the name “Source”; this Modified Version is therefore renamed `LyraReader Sans SC` and keeps the upstream copyright/licence records in its name table. |
| Regenerate | `scripts/build-appearance-font.py` (needs `fonttools`; the app build does not) |

The shipped subset covers the complete GB 2312 repertoire (6,763 Simplified Chinese hanzi plus
its symbols), 6,878 of the 6,879 JIS X 0208 characters (so Japanese kanji such as 語 and 観 are
present; ≒ U+2252 is absent from Noto Sans SC and falls back), kana, Greek and Coptic, Latin-1 and
Latin Extended, and the punctuation, arrows, mathematical operators and geometric symbols papers
use (∑, ≤, ∈, √, ∞, ∂, ∇, ∫, ∏, ∪, ∩, ⇒, …).

The PDF writer subsets this file **again per document**, down to the glyphs an appearance actually
uses, and embeds it as a Type0/Identity-H CID font with `FontFile2`, `CIDToGIDMap`, `/W` widths and
a `/ToUnicode` CMap. A character the shipped subset does not contain is not replaced by `?`: it is
encoded through the `.notdef` glyph with its exact Unicode in `ToUnicode`, and the editor warns
that it will appear as a missing-glyph box in other viewers. `/Contents` always keeps the exact
string.

`make-app-bundle.sh` copies this directory to `LyraReader.app/Contents/Resources/Fonts/`.
