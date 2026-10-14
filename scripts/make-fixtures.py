#!/usr/bin/env python3
"""Generate small, deterministic PDF fixtures for tests and benchmarks.

Why a generator instead of committed binaries:
  * the fixtures are tiny, reproducible and license-clean (no third-party content);
  * they double as a specification of what the renderer must handle
    (text, vector graphics, multiple pages, page rotation).

Usage:
    python3 scripts/make-fixtures.py [output-dir]      # default: tests/fixtures

Requires Python 3 only (no third-party packages). Standard library is enough:
PDF objects and a correct cross-reference table are emitted by hand.
"""

from __future__ import annotations

import sys
from pathlib import Path

A4_WIDTH = 595
A4_HEIGHT = 842


def escape_pdf_string(text: str) -> str:
    """Escape the three characters that are special inside a PDF string literal.

    The fixtures declare `/Encoding /WinAnsiEncoding`; the actual byte encoding
    (cp1252) happens once, when the content stream is serialised in `build_pdf`.
    """
    return text.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)")


def build_pdf(pages: list[tuple[str, int]]) -> bytes:
    """Assemble a PDF from (content_stream, rotation_degrees) pairs."""
    objects: list[bytes] = []

    # Object numbering: 1 = catalog, 2 = page tree, 3 = font, then per page
    # (page object, content stream).
    page_object_ids = [4 + 2 * i for i in range(len(pages))]
    objects.append(b"<< /Type /Catalog /Pages 2 0 R >>")
    kids = " ".join(f"{pid} 0 R" for pid in page_object_ids)
    objects.append(
        f"<< /Type /Pages /Kids [{kids}] /Count {len(pages)} >>".encode("ascii")
    )
    objects.append(
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica "
        b"/Encoding /WinAnsiEncoding >>"
    )

    for index, (content, rotation) in enumerate(pages):
        content_id = page_object_ids[index] + 1
        rotate = f" /Rotate {rotation}" if rotation else ""
        objects.append(
            (
                f"<< /Type /Page /Parent 2 0 R "
                f"/MediaBox [0 0 {A4_WIDTH} {A4_HEIGHT}] "
                f"/Resources << /Font << /F1 3 0 R >> >> "
                f"/Contents {content_id} 0 R{rotate} >>"
            ).encode("ascii")
        )
        stream = content.encode("cp1252")
        objects.append(
            b"<< /Length " + str(len(stream)).encode("ascii") + b" >>\nstream\n"
            + stream
            + b"\nendstream"
        )

    # Serialize with a correct cross-reference table: every offset is measured
    # from the start of the file, so build the body first and then measure.
    out = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
    offsets: list[int] = []
    for number, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{number} 0 obj\n".encode("ascii") + body + b"\nendobj\n"

    xref_offset = len(out)
    count = len(objects) + 1
    out += f"xref\n0 {count}\n".encode("ascii")
    out += b"0000000000 65535 f \n"
    for offset in offsets:
        out += f"{offset:010d} 00000 n \n".encode("ascii")
    out += (
        f"trailer\n<< /Size {count} /Root 1 0 R >>\nstartxref\n{xref_offset}\n%%EOF\n"
    ).encode("ascii")
    return bytes(out)


def text_page(title: str, subtitle: str, body_lines: list[str]) -> str:
    """A page with a heading, body text measured in points, and a vector box.

    The layout is deliberately simple but exercises the parts that matter for a
    first rasterization check: glyph rasterization at several sizes, a stroked
    path, a filled path with transparency, and exact placement.
    """
    parts = [
        # Heading
        "BT /F1 28 Tf 72 760 Td (" + escape_pdf_string(title) + ") Tj ET",
        # Subtitle
        "0.35 0.35 0.35 rg",
        "BT /F1 13 Tf 72 730 Td (" + escape_pdf_string(subtitle) + ") Tj ET",
        # Body
        "0 0 0 rg",
        "BT /F1 11 Tf 15 TL 72 690 Td",
    ]
    parts += [f"({escape_pdf_string(line)}) Tj T*" for line in body_lines]
    parts.append("ET")
    # Vector graphics: stroked rectangle + filled semi-transparent square + line
    parts += [
        "0.10 0.35 0.75 RG 2 w 72 300 451 120 re S",
        "0.90 0.30 0.20 rg 0.55 0.30 0.20 rg",
        "360 480 120 120 re f",
        "0.2 0.2 0.2 RG 1 w 72 200 m 523 260 l S",
        # Diagonal hairlines: a good antialiasing check at any zoom level
        "0.6 0.6 0.6 RG 0.5 w",
    ]
    parts += [f"{72 + i * 30} 150 m {102 + i * 30} 110 l S" for i in range(15)]
    return "\n".join(parts)


def references_page(left: list[str], right: list[str]) -> str:
    """A two-column bibliography page, left column first in the content stream.

    Text is placed one line at a time at an explicit position, because the columns
    have to be exact: the gutter between them is what `column_gutter` has to find,
    and entry 2 is meant to start in the left column and end in the right one, which
    is the layout the fragment model exists for. The columns are far enough apart
    (70 pt) that no line can be mistaken for spanning both.
    """
    parts = ["0 0 0 rg"]
    for x, lines in ((60, left), (330, right)):
        for index, line in enumerate(lines):
            y = 760 - index * 15
            parts.append(
                f"BT /F1 10 Tf {x} {y} Td ({escape_pdf_string(line)}) Tj ET"
            )
    return "\n".join(parts)


def main() -> int:
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("tests/fixtures")
    out_dir.mkdir(parents=True, exist_ok=True)

    fixtures: dict[str, list[tuple[str, int]]] = {
        # 1) Single text page: the primary rendering smoke test.
        "text-page.pdf": [
            (
                text_page(
                    "ArisReader fixture",
                    "text, vector strokes, fills and hairlines on one A4 page",
                    [
                        "Line 1: The quick brown fox jumps over the lazy dog.",
                        "Line 2: 0123456789 !@#$%^&*() []{} <> /\\|;:'\",.?",
                        "Line 3: Mixed CASE and lowercase — typographic dash.",
                        "Line 4: Kerning pairs: AV WA To Ta Yo LT 1234567890.",
                        "Line 5: This paragraph exists to make the page look real.",
                        "Line 6: Compare the render against poppler at the same DPI.",
                    ],
                ),
                0,
            )
        ],
        # 2) Three pages: page navigation, tile cache and prefetch behaviour.
        "multipage.pdf": [
            (
                text_page(
                    f"Page {number} of 3",
                    "multi-page fixture for navigation and caching",
                    [
                        f"Body text on page {number}.",
                        "Each page has a different fill colour below,",
                        "so a stale tile from another page is obvious.",
                    ],
                ),
                0,
            )
            for number in (1, 2, 3)
        ],
        # Fine header and table rules: thumbnail supersampling must retain subpixel coverage.
        "thin-lines.pdf": [("0 G 0.25 w 72 760 m 523 760 l S\n"
                            "0.5 w 72 500 m 523 500 l S\n"
                            "0.25 w 72 485 m 523 485 l S\n", 0)],
        # 3) Rotated page: exercises /Rotate handling and the page geometry code.
        "rotated.pdf": [
            (text_page("Rotated 90°", "this page uses /Rotate 90", ["Rotated body line."]), 90),
            (text_page("Rotated 180°", "this page uses /Rotate 180", ["Rotated body line."]), 180),
        ],
        # 4) Two-column bibliography: entry 2 starts at the foot of the left column and
        #    ends at the head of the right one, so it is drawn in two pieces. The other
        #    entries stay inside one column each.
        "two-column-references.pdf": [
            (
                references_page(
                    [
                        "[1] Alpha, A.: A first work on motion. 2020.",
                        "[2] Beta, B.: A second work whose title is",
                        "long enough to wrap twice in the left",
                        "column and then carry on to the right",
                        "hand column of the very same page.",
                    ],
                    [
                        "It ends here, on the first line.",
                        "[3] Gamma, C.: A third work on style. 2018.",
                        "[4] Delta, D.: A fourth work on shape. 2017.",
                        "[5] Epsilon, E.: A fifth work on light. 2016.",
                        "[6] Zeta, F.: A sixth work on sound. 2015.",
                    ],
                ),
                0,
            )
        ],
    }

    for name, pages in fixtures.items():
        path = out_dir / name
        path.write_bytes(build_pdf(pages))
        print(f"  {path}  ({path.stat().st_size} bytes, {len(pages)} page(s))")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
