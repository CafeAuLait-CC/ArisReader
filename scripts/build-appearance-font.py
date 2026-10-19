#!/usr/bin/env python3
"""Build the CJK font LyraReader ships for PDF free-text appearance streams.

The shipped font is a **subset of Noto Sans SC**, not a system font. It is reduced to the
characters an annotation in this reader actually uses: common Simplified Chinese (the full
GB 2312 set), the JIS X 0208 repertoire so Japanese kanji in a Japanese sentence are covered,
kana, Greek, Latin and the mathematical/typographic symbols papers use. The full family is
never shipped.

The result is committed as `apps/macos/Resources/Fonts/LyraReaderSansSC-Regular.ttf` together with the
upstream `OFL.txt`. The writer then subsets this file again, per document, to the glyphs the
appearance actually contains (see `crates/lyra-reader-pdfium/src/appearance_font.rs`).

Usage (fontTools is only needed to regenerate the committed font, not to build or run LyraReader):

    python3 -m venv /tmp/lyra-reader-font-venv
    /tmp/lyra-reader-font-venv/bin/pip install fonttools
    /tmp/lyra-reader-font-venv/bin/python scripts/build-appearance-font.py

The script downloads the upstream variable font and its licence into a temporary directory when
they are not already present. The output is deterministic for a given upstream font.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

SOURCE_URL = "https://raw.githubusercontent.com/google/fonts/main/ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf"
LICENCE_URL = "https://raw.githubusercontent.com/google/fonts/main/ofl/notosanssc/OFL.txt"
OUTPUT_NAME = "LyraReaderSansSC-Regular.ttf"
FAMILY = "LyraReader Sans SC"

# Unicode ranges that are not part of GB 2312 or JIS X 0208 but matter in annotations:
# Latin (including the accented names papers cite), Greek, punctuation, arrows, mathematical
# operators, geometric symbols, CJK punctuation/full-width forms and kana.
EXTRA_RANGES = [
    (0x0020, 0x007E),  # Basic Latin
    (0x00A0, 0x024F),  # Latin-1 Supplement, Latin Extended-A/B
    (0x0250, 0x02FF),  # IPA, spacing modifiers
    (0x0300, 0x036F),  # combining diacritics
    (0x0370, 0x03FF),  # Greek and Coptic
    (0x0400, 0x04FF),  # Cyrillic (author names)
    (0x1E00, 0x1EFF),  # Latin Extended Additional
    (0x1F00, 0x1FFF),  # Greek Extended
    (0x2000, 0x206F),  # General Punctuation
    (0x2070, 0x209F),  # Superscripts and Subscripts
    (0x20A0, 0x20CF),  # Currency Symbols
    (0x2100, 0x218F),  # Letterlike Symbols, Number Forms
    (0x2190, 0x21FF),  # Arrows
    (0x2200, 0x22FF),  # Mathematical Operators
    (0x2300, 0x23FF),  # Miscellaneous Technical
    (0x2460, 0x24FF),  # Enclosed Alphanumerics
    (0x2500, 0x257F),  # Box Drawing
    (0x25A0, 0x25FF),  # Geometric Shapes
    (0x2600, 0x26FF),  # Miscellaneous Symbols
    (0x2700, 0x27BF),  # Dingbats
    (0x27C0, 0x27EF),  # Miscellaneous Mathematical Symbols-A
    (0x27F0, 0x27FF),  # Supplemental Arrows-A
    (0x2900, 0x297F),  # Supplemental Arrows-B
    (0x2980, 0x29FF),  # Miscellaneous Mathematical Symbols-B
    (0x2A00, 0x2AFF),  # Supplemental Mathematical Operators
    (0x2B00, 0x2BFF),  # Miscellaneous Symbols and Arrows
    (0x3000, 0x303F),  # CJK Symbols and Punctuation
    (0x3040, 0x30FF),  # Hiragana, Katakana
    (0x3100, 0x312F),  # Bopomofo
    (0x3190, 0x319F),  # Kanbun
    (0x31C0, 0x31EF),  # CJK Strokes, Katakana Phonetic Extensions
    (0x3200, 0x33FF),  # Enclosed CJK Letters and Months, CJK Compatibility
    (0xFE10, 0xFE1F),  # Vertical Forms
    (0xFE30, 0xFE4F),  # CJK Compatibility Forms
    (0xFF00, 0xFFEF),  # Halfwidth and Fullwidth Forms
]


def repertoire() -> str:
    """GB 2312 + JIS X 0208 + the explicit symbol ranges, as a sorted character string."""
    characters: set[str] = set()

    # GB 2312: 6763 simplified hanzi plus the 682 symbols (kana, Greek, Cyrillic, punctuation,
    # maths). This is the "common Simplified Chinese" coverage that matters for everyday text.
    for first in range(0xA1, 0xF8):
        for second in range(0xA1, 0xFF):
            try:
                character = bytes([first, second]).decode("gb2312")
            except UnicodeDecodeError:
                continue
            if len(character) == 1:
                characters.add(character)

    # JIS X 0208 adds the Japanese kanji that simplified Chinese does not include (語, 観, …)
    # while kana were already present in GB 2312.
    for first in range(0xA1, 0xFF):
        for second in range(0xA1, 0xFF):
            try:
                character = bytes([first, second]).decode("euc_jp")
            except UnicodeDecodeError:
                continue
            if len(character) == 1:
                characters.add(character)

    for first, last in EXTRA_RANGES:
        for codepoint in range(first, last + 1):
            characters.add(chr(codepoint))

    characters.discard("\x00")
    return "".join(sorted(characters))


def download(url: str, destination: Path) -> None:
    print(f"downloading {url}")
    urllib.request.urlretrieve(url, destination)


def run(command: list[str]) -> None:
    print("+", " ".join(command))
    subprocess.run(command, check=True)


def rename_and_embed(font_path: Path) -> None:
    from fontTools.ttLib import TTFont

    font = TTFont(font_path)
    name = font["name"]
    # Keep the copyright, licence and licence-URL records required by the OFL. Everything that
    # identifies the upstream family is replaced: the OFL reserves the name "Source", and this
    # subset is a Modified Version. It is still redistributed under the same licence.
    for record in list(name.names):
        if record.nameID not in (0, 13, 14):
            name.names.remove(record)

    values = {
        1: FAMILY,
        2: "Regular",
        3: "1.000;LYRA_READER;LyraReaderSansSC-Regular;2026",
        4: f"{FAMILY} Regular",
        5: "Version 1.000",
        6: "LyraReaderSansSC-Regular",
        16: FAMILY,
        17: "Regular",
    }
    for name_id, value in values.items():
        name.setName(value, name_id, 3, 1, 0x409)
        name.setName(value, name_id, 1, 0, 0)

    # fsType 0: installable embedding, which is what the OFL permits and what a PDF writer needs.
    font["OS/2"].usWeightClass = 400
    font["OS/2"].usWidthClass = 5
    font["OS/2"].fsType = 0
    font["head"].macStyle = 0
    font.save(font_path, reorderTables=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="optional path to NotoSansSC[wght].ttf")
    parser.add_argument("--licence", type=Path, help="optional path to the upstream OFL.txt")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "apps/macos/Resources/Fonts",
    )
    arguments = parser.parse_args()

    output_dir: Path = arguments.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="lyra-reader-appearance-font-") as temporary:
        temporary_dir = Path(temporary)
        source = arguments.source
        licence = arguments.licence
        if source is None:
            source = temporary_dir / "NotoSansSC-VF.ttf"
            download(SOURCE_URL, source)
        if licence is None:
            licence = temporary_dir / "OFL.txt"
            download(LICENCE_URL, licence)
        source = source.resolve()
        licence = licence.resolve()

        charset_path = temporary_dir / "charset.txt"
        text = repertoire()
        charset_path.write_text(text, encoding="utf-8")
        print(f"repertoire: {len(text)} characters")

        static_font = temporary_dir / "NotoSansSC-Regular.ttf"
        run(
            [
                sys.executable,
                "-m",
                "fontTools.varLib.instancer",
                str(source),
                "wght=400",
                "-o",
                str(static_font),
            ]
        )

        subset_font = temporary_dir / OUTPUT_NAME
        run(
            [
                sys.executable,
                "-m",
                "fontTools.subset",
                str(static_font),
                f"--text-file={charset_path}",
                f"--output-file={subset_font}",
                "--layout-features=",
                "--name-IDs=*",
                "--name-languages=*",
                "--notdef-glyph",
                "--notdef-outline",
            ]
        )

        rename_and_embed(subset_font)

        destination = output_dir / OUTPUT_NAME
        destination.write_bytes(subset_font.read_bytes())
        (output_dir / "OFL.txt").write_bytes(licence.read_bytes())

        from fontTools.ttLib import TTFont

        font = TTFont(destination)
        cmap = font.getBestCmap()
        print(f"wrote {destination} ({destination.stat().st_size} bytes)")
        print(f"glyphs: {font['maxp'].numGlyphs}; mapped characters: {len(cmap)}")
        print(f"wrote {output_dir / 'OFL.txt'}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
