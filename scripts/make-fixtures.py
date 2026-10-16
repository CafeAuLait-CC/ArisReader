#!/usr/bin/env python3
"""Generate small, deterministic PDF fixtures for tests and benchmarks.

Why a generator instead of committed binaries:
  * the fixtures are tiny, reproducible and license-clean (no third-party content);
  * they double as a specification of what the renderer must handle
    (text, vector graphics, multiple pages, page rotation).

Usage:
    python3 scripts/make-fixtures.py [output-dir]      # default: tests/fixtures
    python3 scripts/make-fixtures.py [output-dir] --long-pages 300 [--long-name NAME]

`--long-pages` additionally writes a synthetic long document (default `long-<N>.pdf`)
for the T1.13 first-frame measurement: no license-clean ~300-page PDF exists in this
repository, so the long fixture repeats a six-page cycle with the page number woven into
the text. Repetition is the artifact to remember when reading its numbers: after the
first cycle the engine's glyph cache is warm, so per-page raster cost there is a lower
bound for a real paper of the same length.

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


def build_pdf(
    pages: list[tuple[str, int]],
    annotations: dict[int, list[bytes]] | None = None,
    extra_objects: list[bytes] | None = None,
) -> bytes:
    """Assemble a PDF from (content_stream, rotation_degrees) pairs.

    `annotations` maps a page index to the annotation dictionaries to attach to it.
    Annotation objects are numbered after every page, so a file with no annotations is
    byte-for-byte what this generator has always written.

    `extra_objects` are appended last, for the streams an annotation can point at (an
    `/AP` appearance stream and its `/ExtGState`). Their object numbers follow the
    annotations and are returned by `first_extra_object_id`, which is the only way a
    caller can write the reference without duplicating the numbering rules.
    """
    annotations = annotations or {}
    extra_objects = extra_objects or []
    objects: list[bytes] = []

    # Object numbering: 1 = catalog, 2 = page tree, 3 = font, then per page
    # (page object, content stream), then the annotations page by page.
    page_object_ids = [4 + 2 * i for i in range(len(pages))]
    first_annot_id = 4 + 2 * len(pages)
    annot_ids: dict[int, list[int]] = {}
    next_annot_id = first_annot_id
    for index in range(len(pages)):
        ids = list(range(next_annot_id, next_annot_id + len(annotations.get(index, []))))
        annot_ids[index] = ids
        next_annot_id += len(ids)

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
        annots = ""
        if annot_ids[index]:
            refs = " ".join(f"{aid} 0 R" for aid in annot_ids[index])
            annots = f" /Annots [{refs}]"
        objects.append(
            (
                f"<< /Type /Page /Parent 2 0 R "
                f"/MediaBox [0 0 {A4_WIDTH} {A4_HEIGHT}] "
                f"/Resources << /Font << /F1 3 0 R >> >> "
                f"/Contents {content_id} 0 R{rotate}{annots} >>"
            ).encode("ascii")
        )
        stream = content.encode("cp1252")
        objects.append(
            b"<< /Length " + str(len(stream)).encode("ascii") + b" >>\nstream\n"
            + stream
            + b"\nendstream"
        )

    for index in range(len(pages)):
        objects.extend(annotations.get(index, []))

    objects.extend(extra_objects)

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


def first_extra_object_id(page_count: int, annotation_count: int) -> int:
    """The object number `build_pdf` gives the first `extra_objects` entry.

    Object numbering: 1 = catalog, 2 = page tree, 3 = font, then two per page (page object,
    content stream), then every annotation, then the extras.
    """
    return 4 + 2 * page_count + annotation_count


def appearance_stream(
    bbox: tuple[float, float, float, float],
    rects: list[tuple[float, float, float, float]],
    *,
    colour: tuple[float, float, float],
    extgstate_id: int,
    resource_name: str = "X",
    fill_operator: str = "f",
) -> bytes:
    """A `/AP /N` form XObject that fills `rects` in `colour`, as Preview writes highlights.

    The graphical state — blend mode and constant alpha — lives in the referenced
    `/ExtGState`, which is exactly the shape the reader has to cope with: the annotation
    dictionary itself carries no `/BM`, and PDFium's `FPDFAnnot_GetColor` refuses an
    annotation that has an appearance stream at all (see `aris-reader-pdfium::annotations`).
    """
    parts = [f"/{resource_name} gs", f"{colour[0]:g} {colour[1]:g} {colour[2]:g} rg"]
    for left, bottom, right, top in rects:
        parts.append(
            f"{left:g} {bottom:g} m {right:g} {bottom:g} l {right:g} {top:g} l "
            f"{left:g} {top:g} l h {fill_operator}"
        )
    stream = ("\n".join(parts) + "\n").encode("ascii")
    body = (
        f"<< /Type /XObject /Subtype /Form /FormType 1 "
        f"/BBox [{bbox[0]:g} {bbox[1]:g} {bbox[2]:g} {bbox[3]:g}] "
        f"/Matrix [1 0 0 1 {-bbox[0]:g} {-bbox[1]:g}] "
        f"/Group << /S /Transparency /Type /Group >> "
        f"/Resources << /ExtGState << /{resource_name} {extgstate_id} 0 R >> >> "
        f"/Length {len(stream)} >>\nstream\n"
    ).encode("ascii") + stream + b"\nendstream"
    return body


def extgstate(blend: str | None, alpha: float | None) -> bytes:
    """One `/ExtGState` dictionary: the blend mode and constant alpha of an appearance.

    `blend=None` and `alpha=None` mean "the key is absent", which is what most producers
    write for the uninteresting entries.
    """
    entries = ["/Type /ExtGState"]
    if blend is not None:
        entries.append(f"/BM /{blend}")
    if alpha is not None:
        entries += [f"/ca {alpha:g}", f"/CA {alpha:g}"]
    entries.append("/AIS false")
    return ("<< " + " ".join(entries) + " >>").encode("ascii")


def quad_points(rects: list[tuple[float, float, float, float]]) -> str:
    """The `/QuadPoints` array for a list of (left, bottom, right, top) rectangles.

    Order matters and is easy to get wrong: PDF 32000-1 table 179 wants each
    quadrilateral's four vertices in counterclockwise order, which is the order
    `pdfium-render` itself writes when it builds quads from a rectangle
    (lower-left, lower-right, upper-right, upper-left).
    """
    parts: list[str] = []
    for left, bottom, right, top in rects:
        parts += [
            f"{left:g}",
            f"{bottom:g}",
            f"{right:g}",
            f"{bottom:g}",
            f"{right:g}",
            f"{top:g}",
            f"{left:g}",
            f"{top:g}",
        ]
    return "[" + " ".join(parts) + "]"


def annotation(
    subtype: str,
    rect: tuple[float, float, float, float],
    *,
    extra: str = "",
    contents: str | None = None,
    author: str | None = None,
    modified: str | None = None,
) -> bytes:
    """One annotation dictionary. `/F 4` is the Print flag, the value every producer writes."""
    left, bottom, right, top = rect
    body = f"<< /Type /Annot /Subtype /{subtype} /Rect [{left:g} {bottom:g} {right:g} {top:g}]"
    if extra:
        body += f" {extra}"
    if contents is not None:
        body += f" /Contents ({escape_pdf_string(contents)})"
    if author is not None:
        body += f" /T ({escape_pdf_string(author)})"
    if modified is not None:
        body += f" /M ({modified})"
    body += " /F 4 >>"
    return body.encode("cp1252")


def body_line_box(index: int, right: float) -> tuple[float, float, float, float]:
    """The box of body line `index` on a `text_page`, in PDF user space.

    `text_page` sets the first body line 690 pt up with 15 pt leading and an 11 pt face, so a
    line's box is `y - 4 … y + 11`. Deriving the annotation geometry from that (instead of
    picking round numbers that happen to sit nowhere near the text) is what makes the fixture a
    realistic "somebody highlighted this line" file: the markup really does cover the glyphs,
    which is also what lets a reader select the text under a loaded highlight.
    """
    y = 690 - 15 * index
    return (72, y - 4, right, y + 11)


def highlight_box() -> tuple[float, float, float, float]:
    """The union of the two body-line boxes the fixture's highlight covers."""
    first = body_line_box(0, 460)
    second = body_line_box(1, 360)
    return (first[0], second[1], first[2], first[3])


def annotated_page_fixture() -> dict[int, list[bytes]]:
    """Annotations attached to the two pages of `annotated.pdf`.

    The file has to stay license-clean and hand-written like every other fixture, so the
    annotations are written straight into the page's `/Annots` array. Between them they
    cover what a reader has to survive in the wild:

    * all four text-markup subtypes, each with quad points;
    * `/BM /Multiply` with `/CA 0.5` on the highlight, i.e. the pair that decides how a
      highlight has to be composited, and a markup annotation with neither key;
    * a colour (`/C [0.2 0.6 1]` — a blue no Lyra palette entry matches, which is the
      user's actual question: does somebody else's colour come through?);
    * a sticky note with **no** `/C` at all, which PDFium reports as black unless the
      reader checks `HasKey("C")` first;
    * a `/Link`, which the reader has to leave out of the annotation list while the link
      path still reports it;
    * a free-text annotation;
    * a highlight with no `/QuadPoints`, whose `/Rect` is the only geometry it has.
    """
    return {
        0: [
            # The one that carries everything: colour, opacity, blend mode, author, date.
            annotation(
                "Highlight",
                # Two consecutive body lines, so the reader has to keep both quads; the /Rect is
                # their union, as a producer would write it.
                highlight_box(),
                extra=f"/QuadPoints {quad_points([body_line_box(0, 460), body_line_box(1, 360)])} "
                f"/C [0.2 0.6 1] /CA 0.5 /BM /Multiply",
                contents="Highlight contents for the round trip.",
                author="Reviewer A",
                modified="D:20240102030405Z",
            ),
            annotation(
                "Underline",
                body_line_box(2, 460),
                extra=f"/QuadPoints {quad_points([body_line_box(2, 460)])} /C [0.9 0.1 0.1] /CA 1",
                contents="Underline contents.",
                author="Reviewer B",
                modified="D:20240102030405Z",
            ),
            # The PDF name is `/StrikeOut` (capital O, PDF 32000-1 table 170); PDFium
            # matches it exactly and reports an unknown subtype for any other spelling.
            annotation(
                "StrikeOut",
                body_line_box(3, 400),
                extra=f"/QuadPoints {quad_points([body_line_box(3, 400)])} /C [0.1 0.6 0.2]",
                contents="Strikeout contents.",
                author="Reviewer C",
                modified="D:20240102030405Z",
            ),
            # No /C anywhere: the colour key is absent, not black.
            annotation(
                "Text",
                (500, 700, 520, 720),
                extra="/Name /Comment",
                contents="A sticky note body.",
                author="Reviewer D",
                modified="D:20240102030405Z",
            ),
            annotation(
                "FreeText",
                (72, 620, 320, 660),
                extra="/DA (/Helv 10 Tf 0 g) /C [1 0 0]",
                contents="Free text annotation body.",
                author="Reviewer E",
                modified="D:20240102030405Z",
            ),
            # A link is *not* content: it is navigation, and this backend already answers it
            # through the link path. It is here so the boundary is tested — a real paper can
            # carry thousands of these (2751 of the 2767 annotations in the local corpus), and
            # none of them belongs in a list of a reader's highlights.
            annotation(
                "Link",
                body_line_box(4, 460),
                extra="/A << /S /URI /URI (https://example.org/annotated) >> /Border [0 0 0]",
            ),
        ],
        1: [
            annotation(
                "Squiggly",
                body_line_box(0, 460),
                extra=f"/QuadPoints {quad_points([body_line_box(0, 460)])} "
                f"/C [0.5 0.2 0.8] /CA 0.75 /BM /Multiply",
                contents="Squiggly contents.",
                author="Reviewer F",
                modified="D:20240102030405Z",
            ),
            # Malformed but real: markup geometry is the /Rect alone.
            annotation(
                "Highlight",
                body_line_box(2, 300),
                extra="/C [0.2 0.6 1]",
                contents="Highlight without quad points.",
                author="Reviewer G",
                modified="D:20240102030405Z",
            ),
        ],
    }


def annotated_appearance_fixture(pages: int) -> tuple[dict[int, list[bytes]], list[bytes]]:
    """Annotations that carry an `/AP`, the shape Preview and Acrobat actually write.

    `annotated.pdf` writes its annotations straight into a dictionary, which is the easy
    case: `/C` and `/BM` are both readable there. A real review PDF is the hard case, and
    this file is it (measured on the user's seven annotated PDFs, 2026-10-15: all 242 markup
    annotations have an `/AP`, none of them states `/BM`, and `FPDFAnnot_GetColor` refuses
    every single one):

    * a yellow highlight whose `/BM /Multiply` and `/ca 0.968627` live in the appearance
      stream's `/ExtGState`, with only `/C` and `/CA` on the annotation — Preview's exact
      highlight, and the pair that decided how the canvas has to composite it;
    * a highlight with **no `/C` at all** but a `/CA`: the one case where the reader has no
      colour to report, and the canvas must still honour the file's opacity instead of
      painting an opaque grey over the text;
    * an underline whose appearance paints it at 40% while the dictionary states no `/CA`,
      so a reader that trusts only the dictionary overstates it;
    * a squiggly with an appearance stream and no `/BM`, which stays alpha-over.

    Object numbering: `base` is the first free id (`build_pdf` gives the extras the ids
    after the annotations), and each annotation's `/ExtGState` and `/AP` stream are the two
    objects at `base + 2i` and `base + 2i + 1`.
    """
    highlight_box = body_line_box(0, 460)
    underline_box = body_line_box(2, 460)
    squiggly_box = body_line_box(4, 460)
    no_colour_box = body_line_box(6, 460)
    annotation_count = 4
    base = first_extra_object_id(pages, annotation_count)
    state = lambda index: base + 2 * index  # noqa: E731
    stream = lambda index: base + 2 * index + 1  # noqa: E731
    annotations = {
        0: [
            annotation(
                "Highlight",
                highlight_box,
                extra=f"/QuadPoints {quad_points([highlight_box])} "
                f"/C [1 1 0] /CA 0.968627 /AP << /N {stream(0)} 0 R >>",
                contents="Preview's highlight: multiply in the appearance stream.",
                author="Reviewer A",
                modified="D:20240102030405Z",
            ),
            annotation(
                "Underline",
                underline_box,
                extra=f"/QuadPoints {quad_points([underline_box])} "
                f"/C [0.9 0.1 0.1] /AP << /N {stream(1)} 0 R >>",
                contents="Underline painted by its appearance stream.",
                author="Reviewer B",
                modified="D:20240102030405Z",
            ),
            annotation(
                "Highlight",
                no_colour_box,
                extra=f"/QuadPoints {quad_points([no_colour_box])} "
                f"/CA 0.35 /AP << /N {stream(2)} 0 R >>",
                contents="A highlight whose colour only the appearance stream has.",
                author="Reviewer C",
                modified="D:20240102030405Z",
            ),
            annotation(
                "Squiggly",
                squiggly_box,
                extra=f"/QuadPoints {quad_points([squiggly_box])} "
                f"/C [0.5 0.2 0.8] /CA 0.75 /AP << /N {stream(3)} 0 R >>",
                contents="Squiggly with an appearance stream.",
                author="Reviewer D",
                modified="D:20240102030405Z",
            ),
        ]
    }
    extras = [
        extgstate("Multiply", 0.968627),
        appearance_stream(highlight_box, [highlight_box], colour=(1, 1, 0),
                          extgstate_id=state(0)),
        extgstate("Multiply", 0.4),
        appearance_stream(underline_box, [underline_box], colour=(0.9, 0.1, 0.1),
                          extgstate_id=state(1)),
        extgstate(None, 0.35),
        appearance_stream(no_colour_box, [no_colour_box], colour=(0.2, 0.6, 1),
                          extgstate_id=state(2)),
        extgstate(None, 0.75),
        appearance_stream(squiggly_box, [squiggly_box], colour=(0.5, 0.2, 0.8),
                          extgstate_id=state(3)),
    ]
    return annotations, extras


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


def long_document(page_count: int) -> list[tuple[str, int]]:
    """A synthetic long document for the T1.13 measurement (~300 pages).

    Six page layouts repeat in a cycle, with the page number woven into both the heading
    and the body so no two pages are byte-identical. The repetition is deliberate: the
    fixtures have to stay license-clean and small, and repeating pages is the only way to
    reach 300 pages here. It also means the engine's glyph cache is warm after the first
    cycle, so any per-page cost measured on this file is a lower bound for a real paper.
    """
    variants = 6
    return [
        (
            text_page(
                f"Bench fixture {index + 1} of {page_count}",
                f"cycle variant {index % variants + 1} of {variants} - synthetic long document",
                [
                    f"Page {index + 1}: this line differs on every page.",
                    f"Variant {index % variants + 1}: the cycle repeats every {variants} pages.",
                    "Body text gives the rasterizer glyphs, rules and a filled path to draw.",
                    "The file exists to measure open, first frame and scroll cost at 300 pages.",
                    "Generated, never committed: scripts/make-fixtures.py --long-pages 300",
                ],
            ),
            0,
        )
        for index in range(page_count)
    ]


def main() -> int:
    args = sys.argv[1:]
    out_dir = Path("tests/fixtures")
    long_pages = 0
    long_name: str | None = None

    index = 0
    while index < len(args):
        argument = args[index]
        if argument in ("-h", "--help"):
            print(__doc__)
            return 0
        if argument == "--long-pages":
            long_pages = int(args[index + 1])
            index += 2
            continue
        if argument == "--long-name":
            long_name = args[index + 1]
            index += 2
            continue
        out_dir = Path(argument)
        index += 1

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

    # 5) Annotations written into the file: the reader has to find them without this
    #    application ever having written them. Kept as its own entry because it is the only
    #    fixture with an `/Annots` array, and because the widths above are what the existing
    #    corpus pins depend on.
    annotated_pages = [
        (
            text_page(
                "Annotated page 1",
                "someone else's highlights, notes and free text",
                [f"Line {number}: marked up by another viewer." for number in range(1, 9)],
            ),
            0,
        ),
        (
            text_page(
                "Annotated page 2",
                "annotations on a second page",
                [f"Line {number}: a different page's markup." for number in range(1, 9)],
            ),
            0,
        ),
    ]
    path = out_dir / "annotated.pdf"
    path.write_bytes(build_pdf(annotated_pages, annotated_page_fixture()))
    print(f"  {path}  ({path.stat().st_size} bytes, {len(annotated_pages)} page(s))")

    # 6) The same idea, but with appearance streams: the annotations carry `/AP`, PDFium refuses
    #    `FPDFAnnot_GetColor` for them, and the blend mode lives in the stream's `/ExtGState`.
    #    This is what a file annotated in Preview looks like.
    appearance_pages = [
        (
            text_page(
                "Annotated with appearances",
                "the shape Preview writes: /AP, and no /BM on the annotation",
                [f"Line {number}: marked up through an appearance stream." for number in range(1, 9)],
            ),
            0,
        ),
    ]
    appearance_annotations, appearance_extras = annotated_appearance_fixture(len(appearance_pages))
    path = out_dir / "annotated-appearance.pdf"
    path.write_bytes(build_pdf(appearance_pages, appearance_annotations, appearance_extras))
    print(f"  {path}  ({path.stat().st_size} bytes, {len(appearance_pages)} page(s))")

    if long_pages > 0:
        pages = long_document(long_pages)
        path = out_dir / (long_name or f"long-{long_pages}.pdf")
        path.write_bytes(build_pdf(pages))
        print(f"  {path}  ({path.stat().st_size} bytes, {len(pages)} page(s))")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
