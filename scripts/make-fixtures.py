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

import hashlib
import struct
import sys
import zlib
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
    outline: list[dict] | None = None,
    info: dict[str, str] | None = None,
    xmp: bytes | None = None,
) -> bytes:
    """Assemble a PDF from (content_stream, rotation_degrees) pairs.

    `annotations` maps a page index to the annotation dictionaries to attach to it.
    Annotation objects are numbered after every page, so a file with no annotations is
    byte-for-byte what this generator has always written.

    `extra_objects` are appended last, for the streams an annotation can point at (an
    `/AP` appearance stream and its `/ExtGState`). Their object numbers follow the
    annotations and are returned by `first_extra_object_id`, which is the only way a
    caller can write the reference without duplicating the numbering rules.

    `outline` is a nested tree of `{"title", "page", "children"}` dictionaries. Its objects
    come after every extra object, and only a file that passes it gains an `/Outlines` entry
    in the catalog, so the existing fixtures stay byte-identical.

    `info` writes the document information dictionary and `xmp` an XMP metadata stream
    (compressed with `/FlateDecode`, as real producers write it). Both are optional and come
    after every other object, so a file that passes neither is unchanged.
    """
    annotations = annotations or {}
    extra_objects = extra_objects or []
    outline = outline or []
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

    # The outline root follows the annotations and the extras. Its item ids follow it.
    outline_root_id = next_annot_id + len(extra_objects)
    catalog = b"<< /Type /Catalog /Pages 2 0 R"
    if outline:
        catalog += f" /Outlines {outline_root_id} 0 R /PageMode /UseOutlines".encode("ascii")
    catalog += b" >>"
    objects.append(catalog)
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
    if outline:
        objects.extend(outline_objects(outline, outline_root_id, page_object_ids))

    info_id = None
    if info:
        info_id = len(objects) + 1
        entries = []
        for key in (
            "Title",
            "Author",
            "Subject",
            "Keywords",
            "Creator",
            "Producer",
            "CreationDate",
        ):
            if info.get(key):
                entries.append(f"/{key} ({escape_pdf_string(info[key])})")
        objects.append(("<< " + " ".join(entries) + " >>").encode("cp1252"))

    xmp_id = None
    if xmp:
        xmp_id = len(objects) + 1
        compressed = zlib.compress(xmp)
        objects.append(
            b"<< /Type /Metadata /Subtype /XML /Filter /FlateDecode /Length "
            + str(len(compressed)).encode("ascii")
            + b" >>\nstream\n"
            + compressed
            + b"\nendstream"
        )
        # The catalog was assembled before the object count was known; the `/Metadata`
        # reference is added now.
        if objects[0].endswith(b" >>"):
            objects[0] = (
                objects[0][:-3] + f" /Metadata {xmp_id} 0 R >>".encode("ascii")
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
    trailer = f"trailer\n<< /Size {count} /Root 1 0 R"
    if info_id is not None:
        trailer += f" /Info {info_id} 0 R"
    trailer += f" >>\nstartxref\n{xref_offset}\n%%EOF\n"
    out += trailer.encode("ascii")
    return bytes(out)


def outline_objects(
    nodes: list[dict], root_id: int, page_object_ids: list[int]
) -> list[bytes]:
    """The `/Outlines` root and its bookmark dictionaries, in object-number order.

    A bookmark's `/Count` is the number of descendants that should be displayed when its
    subtree is open; this generator writes the full descendant count, so PDFium sees the
    same hierarchy the fixture documents. Items without a `page` get no `/Dest`, which is
    the "section heading with no destination but with children" case the sidebar must number
    and indent.
    """
    next_id = root_id + 1

    def assign(items: list[dict]) -> int:
        nonlocal next_id
        total = 0
        for item in items:
            item["_id"] = next_id
            next_id += 1
            total += 1 + assign(item.get("children", []))
        return total

    total = assign(nodes)

    def descendants(items: list[dict]) -> int:
        return sum(1 + descendants(item.get("children", [])) for item in items)

    root = f"<< /Type /Outlines /First {nodes[0]['_id']} 0 R /Last {nodes[-1]['_id']} 0 R /Count {total} >>"

    bodies: list[bytes] = []

    def emit(items: list[dict], parent_id: int) -> None:
        for index, item in enumerate(items):
            node_id = item["_id"]
            children = item.get("children", [])
            body = (
                f"<< /Title ({escape_pdf_string(item['title'])}) "
                f"/Parent {parent_id} 0 R"
            )
            if index > 0:
                body += f" /Prev {items[index - 1]['_id']} 0 R"
            if index + 1 < len(items):
                body += f" /Next {items[index + 1]['_id']} 0 R"
            if children:
                body += (
                    f" /First {children[0]['_id']} 0 R "
                    f"/Last {children[-1]['_id']} 0 R /Count {descendants(children)}"
                )
            page = item.get("page")
            if page is not None:
                body += f" /Dest [{page_object_ids[page]} 0 R /Fit]"
            body += " >>"
            bodies.append(body.encode("ascii"))
            emit(children, node_id)

    emit(nodes, root_id)
    return [root.encode("ascii")] + bodies


# ── Form fixtures ────────────────────────────────────────────────────────────
#
# A form filled by another writer, and the document-properties fixture. The fields live in
# AcroForm and every widget is a real page annotation, so PDFium, PDFKit, Poppler and
# Ghostscript all see the same file. The appearance streams are generated here for the same
# reason: a viewer that ignores `/V` still has a picture to draw (the reader asserts all four
# viewers show the prefilled values).

FORM_TEXT_FONT_SIZE = 11


def form_ap_stream(width: float, height: float, content: str) -> bytes:
    data = content.encode("cp1252")
    return (
        b"<< /Type /XObject /Subtype /Form "
        + f"/BBox [0 0 {width:g} {height:g}] ".encode("ascii")
        + b"/Resources << /Font << /Helv 3 0 R >> >> /Length "
        + str(len(data)).encode("ascii")
        + b" >>\nstream\n"
        + data
        + b"\nendstream"
    )


def form_ap_text(
    width: float,
    height: float,
    text: str | None,
    *,
    combo: bool = False,
    options: list[str] | None = None,
    selected: int | None = None,
) -> bytes:
    """A widget appearance: a white field box with its value, or a list of options.

    A list box draws every option with the selected row tinted; a combo draws the selected
    value and a chevron. The reader draws its own chrome over the page, so these streams are
    what the *other* viewers show, and the two have to agree about the value.
    """
    parts = [
        "q 1 1 1 rg 0.45 0.45 0.45 RG 0.6 w",
        f"0.3 0.3 {width - 0.6:g} {height - 0.6:g} re B",
    ]
    if options:
        row = min(22.0, height / max(len(options), 1))
        for index, label in enumerate(options):
            top = height - row * (index + 1)
            if index == selected:
                parts.append("0.80 0.88 0.98 rg")
                parts.append(f"1 1 {width - 2:g} {row:g} re f")
            parts.append("0 0 0 rg")
            parts.append(
                f"BT /Helv {FORM_TEXT_FONT_SIZE:g} Tf {4:g} {top + 5.5:g} Td "
                f"({escape_pdf_string(label)}) Tj ET"
            )
    elif text:
        parts.append("0 0 0 rg")
        parts.append(
            f"BT /Helv {FORM_TEXT_FONT_SIZE:g} Tf 4 {max(3.0, height / 2 - 4):g} Td "
            f"({escape_pdf_string(text)}) Tj ET"
        )
    if combo:
        # A small downward chevron near the right edge, in the reader's control grey.
        x = width - 15
        y = height / 2 + 2
        parts.append("0.35 0.35 0.35 RG 1.2 w")
        parts.append(f"{x:g} {y:g} m {x + 4:g} {y - 4:g} l {x + 8:g} {y:g} l S")
    parts.append("Q")
    return form_ap_stream(width, height, "\n".join(parts))


def form_ap_box(width: float, height: float, on: bool, round_mark: bool) -> bytes:
    """A checkbox or radio appearance. `on` draws the mark that belongs to the kind."""
    parts = ["q 1 1 1 rg 0.35 0.35 0.35 RG 0.8 w"]
    if round_mark:
        radius = min(width, height) / 2 - 1
        cx, cy = width / 2, height / 2
        k = 0.5523 * radius
        parts.append(
            f"{cx + radius:g} {cy:g} m "
            f"{cx + radius:g} {cy + k:g} {cx + k:g} {cy + radius:g} {cx:g} {cy + radius:g} c "
            f"{cx - k:g} {cy + radius:g} {cx - radius:g} {cy + k:g} {cx - radius:g} {cy:g} c "
            f"{cx - radius:g} {cy - k:g} {cx - k:g} {cy - radius:g} {cx:g} {cy - radius:g} c "
            f"{cx + k:g} {cy - radius:g} {cx + radius:g} {cy - k:g} {cx + radius:g} {cy:g} c S"
        )
        if on:
            inner = max(2.0, radius - 4)
            parts.append(f"0 0 0 rg {cx:g} {cy:g} {inner:g} {inner:g} re f")
    else:
        parts.append(f"0.8 0.8 {width - 1.6:g} {height - 1.6:g} re S")
        if on:
            parts.append(
                "0 0 0 RG 1.6 w "
                f"{width * 0.22:g} {height * 0.52:g} m "
                f"{width * 0.42:g} {height * 0.30:g} l "
                f"{width * 0.78:g} {height * 0.72:g} l S"
            )
    parts.append("Q")
    return form_ap_stream(width, height, "\n".join(parts))


# The fields the reader has to understand. The second page proves page-relative geometry: a
# rectangle that is only correct on its own page must not be drawn on page one.
FORM_FIELDS: list[dict] = [
    {"name": "fullName", "kind": "text", "page": 0, "rect": (72, 638, 300, 664),
     "label": "Full name", "value": None, "max_len": 80},
    {"name": "email", "kind": "text", "page": 0, "rect": (72, 598, 300, 624),
     "label": "Email", "value": "prefilled@example.com"},
    {"name": "agree", "kind": "checkbox", "page": 0, "rect": (72, 563, 90, 581),
     "label": "I agree to the terms", "value": False},
    {"name": "color", "kind": "radio", "page": 0, "rect": (72, 523, 186, 541),
     "label": "Favourite colour", "value": "Green",
     "options": [("Red", (72, 523, 90, 541)),
                 ("Green", (120, 523, 138, 541)),
                 ("Blue", (168, 523, 186, 541))]},
    {"name": "country", "kind": "combo", "page": 0, "rect": (72, 478, 300, 504),
     "label": "Country", "value": "Canada",
     "options": ["Canada", "Japan", "Germany"]},
    {"name": "interests", "kind": "list", "page": 0, "rect": (72, 378, 300, 454),
     "label": "Interests", "value": "Reading",
     "options": ["Reading", "Running", "Cooking"]},
    {"name": "signature", "kind": "signature", "page": 0, "rect": (72, 318, 300, 358),
     "label": "Signature"},
    {"name": "notes", "kind": "text", "page": 1, "rect": (72, 638, 500, 760),
     "label": "Notes (page 2)", "value": None, "multiline": True},
]


def form_page_content(page: int) -> str:
    """Page text around the widgets. Field labels sit above their controls."""
    parts = [
        "0 0 0 rg",
        f"BT /F1 20 Tf 72 {790 - page * 4} Td (LyraReader form fixture{'' if page == 0 else ' — page 2'}) Tj ET",
        "BT /F1 9 Tf 72 774 Td (Generated by scripts/make-fixtures.py; values written by another tool.) Tj ET",
    ]
    for field in FORM_FIELDS:
        if field["page"] != page:
            continue
        label = field["label"]
        if field["kind"] == "radio":
            left, bottom, _, top = field["rect"]
            parts.append(
                f"BT /F1 9 Tf {left} {top + 5} Td ({escape_pdf_string(label)}) Tj ET"
            )
            for name, (rx, ry, _, rtop) in field["options"]:
                parts.append(
                    f"BT /F1 9 Tf {rx + 24} {ry + 4} Td ({escape_pdf_string(name)}) Tj ET"
                )
        elif field["kind"] == "checkbox":
            left, bottom, _, top = field["rect"]
            parts.append(
                f"BT /F1 9 Tf {left + 24} {bottom + 4} Td ({escape_pdf_string(label)}) Tj ET"
            )
        else:
            left, bottom, _, top = field["rect"]
            parts.append(
                f"BT /F1 9 Tf {left} {top + 5} Td ({escape_pdf_string(label)}) Tj ET"
            )
    if page == 0:
        parts.append("0.75 0.75 0.75 RG 0.5 w 72 300 m 523 300 l S")
    return "\n".join(parts)


PDF_PASSWORD_PAD = bytes([
    0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA,
    0x01, 0x08, 0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE,
    0x64, 0x53, 0x69, 0x7A,
])


def _rc4(key: bytes, data: bytes) -> bytes:
    state = list(range(256))
    j = 0
    for i in range(256):
        j = (j + state[i] + key[i % len(key)]) & 0xFF
        state[i], state[j] = state[j], state[i]
    out = bytearray()
    i = j = 0
    for byte in data:
        i = (i + 1) & 0xFF
        j = (j + state[i]) & 0xFF
        state[i], state[j] = state[j], state[i]
        out.append(byte ^ state[(state[i] + state[j]) & 0xFF])
    return bytes(out)


def _literal_escape(data: bytes) -> bytes:
    out = bytearray()
    for byte in data:
        if byte in (0x28, 0x29, 0x5C):
            out += b"\\" + bytes([byte])
        elif 32 <= byte <= 126:
            out.append(byte)
        else:
            out += ("\\%03o" % byte).encode("ascii")
    return bytes(out)


def _encrypt_literals(body: bytes, key: bytes) -> bytes:
    """RC4-encrypt every PDF literal string in an object body (not a stream's bytes)."""
    out = bytearray()
    index = 0
    while index < len(body):
        if body[index] != 0x28:  # '('
            out.append(body[index])
            index += 1
            continue
        start = index + 1
        depth = 1
        cursor = start
        while cursor < len(body) and depth:
            byte = body[cursor]
            if byte == 0x5C:  # backslash: the next byte is literal
                cursor += 2
                continue
            if byte == 0x28:
                depth += 1
            elif byte == 0x29:
                depth -= 1
            cursor += 1
        if depth:
            out += body[index:]
            break
        inner = body[start:cursor - 1]
        out += b"(" + _literal_escape(_rc4(key, inner)) + b")"
        index = cursor
    return bytes(out)


def _encrypt_body(body: bytes, key: bytes, object_number: int) -> bytes:
    object_key = _md5(
        key + object_number.to_bytes(3, "little") + b"\x00\x00"
    )[: min(len(key) + 5, 16)]
    marker = b"stream\n"
    if marker not in body:
        return _encrypt_literals(body, object_key)
    head, rest = body.split(marker, 1)
    data, tail = rest.rsplit(b"\nendstream", 1)
    return (
        _encrypt_literals(head, object_key)
        + marker
        + _rc4(object_key, data)
        + b"\nendstream"
        + tail
    )


def _md5(data: bytes) -> bytes:
    return hashlib.md5(data).digest()


def build_form_pdf(
    pages: list[tuple[str, int]],
    fields: list[dict],
    info: dict[str, str] | None = None,
    encrypt: bool = False,
) -> bytes:
    """Assemble the form fixture: pages, AcroForm fields, their widget appearances and `/Info`.

    Object numbering is fixed before any body is written, because a widget, its `/Parent` and
    its appearance streams refer to each other. The layout matches `build_pdf`'s first four
    objects (catalog, page tree, Helvetica) so the fixture stays easy to read with the other
    generators; everything after the page/content pairs is specific to this builder.
    """
    page_count = len(pages)
    page_ids = [4 + 2 * index for index in range(page_count)]
    content_ids = [page_id + 1 for page_id in page_ids]
    next_id = 4 + 2 * page_count

    plans: list[dict] = []
    for field in fields:
        plan: dict = {"field": field, "field_id": next_id, "widgets": []}
        next_id += 1
        kind = field["kind"]
        if kind == "checkbox":
            plan["on_ap"] = next_id
            plan["off_ap"] = next_id + 1
            next_id += 2
        elif kind == "radio":
            for label, rect in field["options"]:
                plan["widgets"].append({
                    "label": label,
                    "rect": rect,
                    "id": next_id,
                    "on_ap": next_id + 1,
                    "off_ap": next_id + 2,
                })
                next_id += 3
        elif kind in ("text", "combo", "list"):
            plan["ap"] = next_id
            next_id += 1
        plans.append(plan)

    acroform_id = next_id
    next_id += 1
    info_id = next_id if info else None
    if info:
        next_id += 1

    objects: dict[int, bytes] = {}
    objects[1] = (
        f"<< /Type /Catalog /Pages 2 0 R /AcroForm {acroform_id} 0 R >>"
    ).encode("ascii")
    kids = " ".join(f"{page_id} 0 R" for page_id in page_ids)
    objects[2] = f"<< /Type /Pages /Kids [{kids}] /Count {page_count} >>".encode("ascii")
    objects[3] = (
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
    )

    # Widgets belong to a page's /Annots; merged field+widget objects are listed by their own
    # object number, and a radio group lists each of its widget children.
    annots_by_page: dict[int, list[int]] = {index: [] for index in range(page_count)}
    for plan in plans:
        field = plan["field"]
        if plan["widgets"]:
            annots_by_page[field["page"]].extend(w["id"] for w in plan["widgets"])
        else:
            annots_by_page[field["page"]].append(plan["field_id"])

    for index, (content, rotation) in enumerate(pages):
        annots = annots_by_page[index]
        annots_entry = (
            " /Annots [" + " ".join(f"{object_id} 0 R" for object_id in annots) + "]"
            if annots else ""
        )
        rotate = f" /Rotate {rotation}" if rotation else ""
        objects[page_ids[index]] = (
            f"<< /Type /Page /Parent 2 0 R "
            f"/MediaBox [0 0 {A4_WIDTH} {A4_HEIGHT}] "
            f"/Resources << /Font << /F1 3 0 R >> >> "
            f"/Contents {content_ids[index]} 0 R{rotate}{annots_entry} >>"
        ).encode("ascii")
        stream = content.encode("cp1252")
        objects[content_ids[index]] = (
            b"<< /Length " + str(len(stream)).encode("ascii") + b" >>\nstream\n"
            + stream + b"\nendstream"
        )

    def widget_rect(field: dict) -> tuple[float, float, float, float]:
        return field["rect"]

    def rect_array(rect: tuple[float, float, float, float]) -> str:
        return "[" + " ".join(f"{value:g}" for value in rect) + "]"

    def text_string(value: str) -> str:
        return "(" + escape_pdf_string(value) + ")"

    def name(value: str) -> str:
        # Field values and appearance state names are simple ASCII in this fixture.
        return "/" + value

    def text_ap(field: dict, plan: dict) -> None:
        left, bottom, right, top = widget_rect(field)
        width, height = right - left, top - bottom
        selected = None
        options = None
        if field["kind"] in ("combo", "list"):
            options = field["options"]
            if field.get("value") in options:
                selected = options.index(field["value"])
        objects[plan["ap"]] = form_ap_text(
            width,
            height,
            field.get("value"),
            combo=field["kind"] == "combo",
            options=options,
            selected=selected,
        )
        return

    for plan in plans:
        field = plan["field"]
        kind = field["kind"]
        name_byte = text_string(field["name"])
        page_ref = f"{page_ids[field['page']]} 0 R"
        common = (
            f"/Type /Annot /Subtype /Widget /T {name_byte} /P {page_ref} /F 4 "
            f"/BS << /W 1 /S /S >> /MK << /BC [0.35 0.35 0.35] /BG [1 1 1] >> "
        )
        if kind == "text":
            text_ap(field, plan)
            flags = " /Ff 4096" if field.get("multiline") else ""
            max_len = f" /MaxLen {field['max_len']}" if field.get("max_len") else ""
            value = (
                f" /V {text_string(field['value'])}" if field.get("value") else ""
            )
            objects[plan["field_id"]] = (
                f"<< {common}/FT /Tx /Rect {rect_array(widget_rect(field))} "
                f"/DA (/Helv {FORM_TEXT_FONT_SIZE} Tf 0 g){flags}{max_len}{value} "
                f"/AP << /N {plan['ap']} 0 R >> >>"
            ).encode("ascii")
        elif kind == "combo" or kind == "list":
            text_ap(field, plan)
            options = field["options"]
            opt_array = " ".join(text_string(option) for option in options)
            flags = " /Ff 131072" if kind == "combo" else ""
            value = ""
            if field.get("value") in options:
                index = options.index(field["value"])
                value = f" /V {text_string(field['value'])} /I [{index}]"
            objects[plan["field_id"]] = (
                f"<< {common}/FT /Ch /Rect {rect_array(widget_rect(field))} "
                f"/DA (/Helv {FORM_TEXT_FONT_SIZE} Tf 0 g){flags} /Opt [{opt_array}]{value} "
                f"/AP << /N {plan['ap']} 0 R >> >>"
            ).encode("ascii")
        elif kind == "signature":
            objects[plan["field_id"]] = (
                f"<< {common}/FT /Sig /Ff 1 /Rect {rect_array(widget_rect(field))} >>"
            ).encode("ascii")
        elif kind == "checkbox":
            checked = bool(field.get("value"))
            left, bottom, right, top = widget_rect(field)
            width, height = right - left, top - bottom
            objects[plan["on_ap"]] = form_ap_box(width, height, True, False)
            objects[plan["off_ap"]] = form_ap_box(width, height, False, False)
            state = "/Yes" if checked else "/Off"
            objects[plan["field_id"]] = (
                f"<< {common}/FT /Btn /Rect {rect_array(widget_rect(field))} "
                f"/V {state} /AS {state} "
                f"/AP << /N << /Yes {plan['on_ap']} 0 R /Off {plan['off_ap']} 0 R >> >> >>"
            ).encode("ascii")
        elif kind == "radio":
            left, bottom, right, top = widget_rect(field)
            selected = field.get("value")
            field_id = plan["field_id"]
            objects[field_id] = (
                f"<< /FT /Btn /Ff 32768 /T {name_byte} /Opt "
                f"[{' '.join(text_string(label) for label, _ in field['options'])}] "
                f"/Kids [{' '.join(f'{widget['id']} 0 R' for widget in plan['widgets'])}] "
                f"/V {name(selected) if selected else '/Off'} >>"
            ).encode("ascii")
            for widget in plan["widgets"]:
                wleft, wbottom, wright, wtop = widget["rect"]
                width, height = wright - wleft, wtop - wbottom
                objects[widget["on_ap"]] = form_ap_box(width, height, True, True)
                objects[widget["off_ap"]] = form_ap_box(width, height, False, True)
                state = name(widget["label"]) if widget["label"] == selected else "/Off"
                objects[widget["id"]] = (
                    f"<< /Type /Annot /Subtype /Widget /Parent {field_id} 0 R "
                    f"/Rect {rect_array(widget['rect'])} /P {page_ref} /F 4 "
                    f"/MK << /BC [0.35 0.35 0.35] /BG [1 1 1] >> "
                    f"/AS {state} /AP << /N << "
                    f"/{widget['label']} {widget['on_ap']} 0 R /Off {widget['off_ap']} 0 R >> >> >>"
                ).encode("ascii")

    field_refs = " ".join(f"{plan['field_id']} 0 R" for plan in plans)
    objects[acroform_id] = (
        f"<< /Fields [{field_refs}] "
        f"/DA (/Helv {FORM_TEXT_FONT_SIZE} Tf 0 g) "
        f"/DR << /Font << /Helv 3 0 R >> >> "
        f"/NeedAppearances false /SigFlags 3 >>"
    ).encode("ascii")

    if info:
        entries = []
        for key in ("Title", "Author", "Subject", "Keywords", "Creator", "Producer"):
            if info.get(key):
                entries.append(f"/{key} {text_string(info[key])}")
        objects[info_id] = ("<< " + " ".join(entries) + " >>").encode("cp1252")

    file_id = _md5(b"lyra-reader-form-fixture")
    encrypt_id = None
    if encrypt:
        owner = b"lyra-reader-fixture-owner"
        owner_key = _md5(owner)[:5]
        o_value = _rc4(owner_key, PDF_PASSWORD_PAD)
        key = _md5(PDF_PASSWORD_PAD + o_value + struct.pack("<i", -1) + file_id)[:5]
        u_value = _rc4(key, PDF_PASSWORD_PAD)
        encrypt_object = len(objects) + 1
        objects = {
            number: _encrypt_body(body, key, number)
            for number, body in objects.items()
        }
        objects[encrypt_object] = (
            f"<< /Filter /Standard /V 1 /R 2 /Length 40 /P -1 "
            f"/O <{o_value.hex()}> /U <{u_value.hex()}> >>"
        ).encode("ascii")
        encrypt_id = encrypt_object

    out = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
    offsets: list[int] = []
    max_object = max(objects)
    for number in range(1, max_object + 1):
        body = objects.get(number)
        if body is None:
            raise ValueError(f"form fixture object {number} is missing")
        offsets.append(len(out))
        out += f"{number} 0 obj\n".encode("ascii") + body + b"\nendobj\n"

    xref_offset = len(out)
    count = max_object + 1
    out += f"xref\n0 {count}\n".encode("ascii")
    out += b"0000000000 65535 f \n"
    for offset in offsets:
        out += f"{offset:010d} 00000 n \n".encode("ascii")
    trailer = f"trailer\n<< /Size {count} /Root 1 0 R"
    if info_id is not None:
        trailer += f" /Info {info_id} 0 R"
    if encrypt_id is not None:
        trailer += f" /Encrypt {encrypt_id} 0 R /ID [<{file_id.hex()}> <{file_id.hex()}>]"
    trailer += f" >>\nstartxref\n{xref_offset}\n%%EOF\n"
    out += trailer.encode("ascii")
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
    annotation that has an appearance stream at all (see `lyra-reader-pdfium::annotations`).
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
    flags: int = 4,
    name: str | None = None,
) -> bytes:
    """One annotation dictionary. `/F 4` is the Print flag, the value every producer writes.

    `flags` is `/F` verbatim: 4 (Print) unless a fixture needs to say something else about
    visibility. PDF 32000-1 table 165: 1 Invisible, 2 Hidden, 4 Print, 8 NoZoom, 16 NoRotate,
    32 NoView. The review corpus is full of notes flagged 26 and 30 — "completed" markers an
    Acrobat review workflow hides — which a reader must leave off the page.
    """
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
    if name is not None:
        body += f" /NM ({escape_pdf_string(name)})"
    body += f" /F {flags} >>"
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
    * a colour (`/C [0.2 0.6 1]` — a blue no LyraReader palette entry matches, which is the
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


def stroke_appearance(bbox: tuple[float, float, float, float], content: str) -> bytes:
    """A `/AP /N` Form XObject that strokes `content` in page coordinates.

    The content is written in page space and the `/Matrix` moves the page origin to the
    annotation's bottom-left, so the form's `/BBox` is its annotation's `/Rect` — the same
    construction a PDF editor uses for a pen stroke or a shape. There is no `/ExtGState`:
    these kinds have no blend-mode problem, and a viewer that synthesises from the geometry
    draws the same thing.
    """
    left, bottom, _, _ = bbox
    stream = content.encode("ascii") + b"\n"
    body = (
        f"<< /Type /XObject /Subtype /Form /FormType 1 "
        f"/BBox [{bbox[0]:g} {bbox[1]:g} {bbox[2]:g} {bbox[3]:g}] "
        f"/Matrix [1 0 0 1 {-left:g} {-bottom:g}] "
        f"/Resources << >> "
        f"/Length {len(stream)} >>\nstream\n"
    ).encode("ascii") + stream + b"endstream"
    return body


def annotated_strokes_fixture() -> tuple[dict[int, list[bytes]], list[bytes]]:
    """Ink and shape annotations written by another producer, not by LyraReader.

    This is the reader-side half of T3.4: a file whose `/InkList`, `/L`, `/LE`, `/BS` and
    `/C` were written by something else. The ink is a real path list (not the malformed flat
    form `annotated-notes.pdf` carries), the square and circle are stroked, one line has
    `/LE [/None /ClosedArrow]`, and every annotation carries an `/AP`. The reader must report
    the geometry and draw it from the dictionary even though the appearance stream is there.

    Object numbering: one A4 page, five annotations (ids 6–10), and their appearance streams
    are the five objects `first_extra_object_id(1, 5) …`.
    """
    boxes = {
        "ink": (80, 620, 260, 710),
        "square": (300, 620, 480, 700),
        "circle": (80, 480, 240, 580),
        "arrow": (300, 480, 480, 580),
        "line": (80, 380, 280, 440),
    }
    base = first_extra_object_id(1, len(boxes))
    ref = lambda index: base + index  # noqa: E731
    # The five ids follow the five annotations in page order.
    annotations = {
        0: [
            annotation(
                "Ink",
                boxes["ink"],
                extra=f"/C [0.85 0.15 0.1] /CA 0.8 "
                f"/BS << /W 3 /S /S >> "
                f"/InkList [[90 650 120 680 160 640 240 700]] "
                f"/AP << /N {ref(0)} 0 R >>",
                contents="Ink written by another producer.",
                author="Another Writer",
                modified="D:20240202020202Z",
                name="external-ink",
            ),
            annotation(
                "Square",
                boxes["square"],
                extra=f"/C [0.1 0.4 0.9] /CA 1 "
                f"/BS << /W 2 /S /S >> /AP << /N {ref(1)} 0 R >>",
                contents="A stroked rectangle.",
                author="Another Writer",
                modified="D:20240202020202Z",
                name="external-square",
            ),
            annotation(
                "Circle",
                boxes["circle"],
                extra=f"/C [0.15 0.6 0.2] /CA 1 "
                f"/BS << /W 1.5 /S /S >> /AP << /N {ref(2)} 0 R >>",
                contents="A stroked ellipse.",
                author="Another Writer",
                modified="D:20240202020202Z",
                name="external-circle",
            ),
            annotation(
                "Line",
                boxes["arrow"],
                extra=f"/C [0.6 0.2 0.7] /CA 1 /L [310 490 470 570] "
                f"/LE [/None /ClosedArrow] /Subj (Arrow) "
                f"/BS << /W 2.5 /S /S >> /AP << /N {ref(3)} 0 R >>",
                contents="An arrow.",
                author="Another Writer",
                modified="D:20240202020202Z",
                name="external-arrow",
            ),
            annotation(
                "Line",
                boxes["line"],
                extra=f"/C [0.2 0.2 0.2] /CA 1 /L [90 390 270 430] "
                f"/LE [/None /None] /BS << /W 1 /S /S >> /AP << /N {ref(4)} 0 R >>",
                contents="A plain line.",
                author="Another Writer",
                modified="D:20240202020202Z",
                name="external-line",
            ),
        ]
    }
    extras = [
        stroke_appearance(
            boxes["ink"],
            "0.85 0.15 0.1 RG 3 w 1 J 1 j 90 650 m 120 680 l 160 640 l 240 700 l S",
        ),
        stroke_appearance(
            boxes["square"],
            "0.1 0.4 0.9 RG 2 w 301 621 178 78 re S",
        ),
        stroke_appearance(
            boxes["circle"],
            "0.15 0.6 0.2 RG 1.5 w 160 579 m 203.6 579 239 557.1 239 530 c "
            "239 502.9 203.6 481 160 481 c 116.4 481 81 502.9 81 530 c "
            "81 557.1 116.4 579 160 579 c S",
        ),
        stroke_appearance(
            boxes["arrow"],
            "0.6 0.2 0.7 RG 2.5 w 310 490 m 470 570 l S "
            "0.6 0.2 0.7 rg 470 570 m 456 560 l 462 574 l f",
        ),
        stroke_appearance(
            boxes["line"],
            "0.2 0.2 0.2 RG 1 w 90 390 m 270 430 l S",
        ),
    ]
    return annotations, extras


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


def annotated_notes_fixture(pages: int) -> tuple[dict[int, list[bytes]], list[bytes]]:
    """Notes and nothing else, the shape of `review_tang_0905.pdf`.

    One of the user's seven review PDFs carries **22 content annotations and no markup at all**
    (11 sticky notes and 11 hidden "completed" markers), so a reader that only draws the four
    text-markup kinds shows that document as if nobody had ever touched it. This fixture is that
    file in miniature, and it is the one the "every content annotation is either drawn or
    explicitly classified as skipped" check runs against:

    * a sticky note with `/C [1 0.85 0.2]` and an `/AP` (every note in the review corpus has
      one, which is why `FPDFAnnot_GetColor` has to have the appearance dictionary cleared
      before it will report the dictionary's own colour);
    * a sticky note with **no** `/C` at all — the case the shell draws in its default note
      colour rather than inventing a hue from a missing key;
    * a free-text annotation with `/DA (/Helv 14 Tf 0 g) /Q 1 /C [...]`: 14 pt, centred, blue,
      which is where `/DA` and `/Q` are read from — PDF 32000-1 table 174;
    * a free-text annotation with no `/C`, drawn in the shell's neutral grey;
    * a free-text annotation with no `/Contents`, which has no text to lay out and is therefore
      *classified* as skipped rather than silently dropped (the review corpus has one: an empty
      2×12 pt box);
    * a sticky note flagged `/F 6` (Hidden|Print) at `/Rect [0 0 1 1]`, which is what 49 of the
      corpus's 99 notes are — an Acrobat review workflow's "completed" marker;
    * an `/Ink` annotation, a subtype this build has no drawing rule for and therefore reports
      as skipped-with-a-reason instead of leaving the reader to guess.

    Every one of them is a *content* annotation, so the reader reports all seven and the
    accounting has to add up: drawn + skipped == 7.

    Object numbering matches `annotated_appearance_fixture`: `base` is the first free id
    (`build_pdf` gives the extras the ids after the annotations), and the one appearance stream
    and its `/ExtGState` are the two objects at `base` and `base + 1`.
    """
    # A sticky note's box is its icon, 20-26 pt square in the corpus; free text is a wide box.
    note_box = (500, 690, 526, 716)
    plain_note_box = (500, 640, 526, 666)
    hidden_note_box = (0, 0, 1, 1)
    free_text_box = (72, 560, 400, 600)
    grey_text_box = (72, 500, 400, 528)
    empty_text_box = (72, 460, 160, 480)
    ink_box = (72, 400, 220, 440)

    annotation_count = 7
    base = first_extra_object_id(pages, annotation_count)
    annotations = {
        0: [
            annotation(
                "Text",
                note_box,
                extra=f"/Name /Comment /C [1 0.85 0.2] /AP << /N {base + 1} 0 R >>",
                contents="A sticky note with a colour of its own.",
                author="Reviewer A",
                modified="D:20240102030405Z",
            ),
            annotation(
                "Text",
                plain_note_box,
                extra="/Name /Comment",
                contents="A sticky note the file gives no colour.",
                author="Reviewer B",
                modified="D:20240102030405Z",
            ),
            annotation(
                "FreeText",
                free_text_box,
                extra="/DA (/Helv 14 Tf 0 g) /Q 1 /C [0.1 0.45 0.9]",
                contents="Free text: 14 pt from /DA, centred by /Q, in its own colour.",
                author="Reviewer C",
                modified="D:20240102030405Z",
            ),
            annotation(
                "FreeText",
                grey_text_box,
                extra="/DA (/Helv 9 Tf 0 g) /Q 0",
                contents="Free text with no colour of its own.",
                author="Reviewer D",
                modified="D:20240102030405Z",
            ),
            annotation(
                "FreeText",
                empty_text_box,
                extra="/DA (/Helv 12 Tf 0 g)",
                author="Reviewer E",
                modified="D:20240102030405Z",
            ),
            annotation(
                "Text",
                hidden_note_box,
                extra="/Name /Comment /C [1 1 0]",
                contents="A note the file marks hidden.",
                author="Reviewer F",
                modified="D:20240102030405Z",
                flags=6,  # Hidden | Print: 49 of the review corpus's 99 notes are flagged this way.
            ),
            annotation(
                "Ink",
                ink_box,
                extra="/C [0.2 0.2 0.2] /InkList [72 400 100 430 140 405 180 440 220 400]",
                contents="Ink, a subtype this build does not draw.",
                author="Reviewer G",
                modified="D:20240102030405Z",
            ),
        ],
    }
    extras = [
        extgstate("Multiply", 0.968627),
        appearance_stream(note_box, [note_box], colour=(1, 0.85, 0.2), extgstate_id=base),
    ]
    return annotations, extras


def annotated_replies_fixture(pages: int) -> dict[int, list[bytes]]:
    """Adobe-style `/IRT` reply threads, including every awkward shape the sidebar must handle.

    The review PDFs in `pdf-samples/with_annotations/` carry exact Adobe review replies: a
    `/Text` annotation with `/IRT` pointing at another annotation's object. The shell cannot
    see object numbers, so the reader identifies annotations by `/NM` and follows `/IRT` with
    `FPDFAnnot_GetLinkedAnnot`. This fixture pins the shapes that are easy to get wrong:

    * two replies under one visible highlight, and a reply to a reply (depth 2);
    * a hidden reply, and a hidden reply with no `/Contents` — both are still part of the
      conversation and must be listed, not silently dropped;
    * a reply on page 2 whose parent is on page 1;
    * a reply whose parent is a hidden note (the reader skips it on the page, so the reply is
      an orphan and must say why);
    * two annotations pointing at each other — a malformed file must not make the sidebar hang;
    * a reply whose `/IRT` targets a `/Link` annotation, which the reader does not list at all.

    The `/NM` values double as the fixture's readable identities: `parent-highlight`,
    `reply-one`, `reply-two`, `reply-empty`, `parent-note`, `reply-cross-page`, `hidden-parent`,
    `reply-to-hidden`, `cycle-a`, `cycle-b`, `structural-parent` and `reply-to-link`.
    """
    base = 4 + 2 * pages
    highlight_box = body_line_box(0, 460)
    note_box = (500, 690, 526, 716)
    second_note_box = (500, 650, 526, 676)
    reply_box = (500, 610, 526, 636)
    empty_reply_box = (500, 570, 526, 596)
    hidden_parent_box = (0, 0, 1, 1)
    cross_reply_box = (500, 500, 526, 526)
    cycle_a_box = (72, 450, 96, 474)
    cycle_b_box = (72, 410, 96, 434)
    link_box = body_line_box(2, 280)
    link_reply_box = (500, 370, 526, 396)

    return {
        0: [
            annotation(
                "Highlight",
                highlight_box,
                extra=f"/QuadPoints {quad_points([highlight_box])} /C [0.2 0.6 1] /CA 0.5",
                contents="A highlighted sentence with a review thread.",
                author="Reviewer A",
                modified="D:20240102030405Z",
                name="parent-highlight",
            ),
            annotation(
                "Text",
                note_box,
                extra=f"/IRT {base} 0 R",
                contents="First reply, in a thread on the highlight.",
                author="Reviewer B",
                modified="D:20240102031000Z",
                flags=26,  # Hidden | NoZoom | NoRotate: the review workflow's "completed" shape.
                name="reply-one",
            ),
            annotation(
                "Text",
                second_note_box,
                extra=f"/IRT {base + 1} 0 R",
                contents="Second-level reply, answering the first reply.",
                author="Reviewer C",
                modified="D:20240102032000Z",
                flags=26,
                name="reply-two",
            ),
            annotation(
                "Text",
                empty_reply_box,
                extra=f"/IRT {base} 0 R",
                author="Reviewer D",
                modified="D:20240102033000Z",
                flags=26,
                name="reply-empty",
            ),
        ],
        1: [
            annotation(
                "Text",
                note_box,
                extra="/Name /Comment",
                contents="A visible note on page two.",
                author="Reviewer E",
                modified="D:20240103040506Z",
                name="parent-note",
            ),
            annotation(
                "Text",
                cross_reply_box,
                extra=f"/IRT {base} 0 R",
                contents="Reply written on page two to the page-one highlight.",
                author="Reviewer F",
                modified="D:20240103041000Z",
                flags=26,
                name="reply-cross-page",
            ),
            annotation(
                "Text",
                hidden_parent_box,
                extra="/Name /Comment",
                contents="A note the file hides; its reply is still in the conversation.",
                author="Reviewer G",
                modified="D:20240103042000Z",
                flags=26,
                name="hidden-parent",
            ),
            annotation(
                "Text",
                reply_box,
                extra=f"/IRT {base + 6} 0 R",
                contents="Reply under a hidden parent note.",
                author="Reviewer H",
                modified="D:20240103043000Z",
                flags=26,
                name="reply-to-hidden",
            ),
            annotation(
                "Text",
                cycle_a_box,
                extra=f"/IRT {base + 9} 0 R",
                contents="Malformed cycle A points at B, and B points back.",
                author="Reviewer I",
                modified="D:20240103044000Z",
                name="cycle-a",
            ),
            annotation(
                "Text",
                cycle_b_box,
                extra=f"/IRT {base + 8} 0 R",
                contents="Malformed cycle B points at A.",
                author="Reviewer J",
                modified="D:20240103045000Z",
                name="cycle-b",
            ),
            annotation(
                "Link",
                link_box,
                extra="/A << /S /URI /URI (https://example.org/replies) >> /Border [0 0 0]",
                name="structural-parent",
            ),
            annotation(
                "Text",
                link_reply_box,
                extra=f"/IRT {base + 10} 0 R",
                contents="Reply to a link, which the annotation reader does not list.",
                author="Reviewer K",
                modified="D:20240103046000Z",
                flags=26,
                name="reply-to-link",
            ),
        ],
    }


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


def numbered_margin_page() -> str:
    """A page with a real line-number gutter and body text that wraps.

    The numbers are drawn as a separate text run before the body, matching the live manuscript
    that exposed the selection-index bug: the page text layer starts with the gutter run, so a
    selection in the body is at a non-zero character offset. The body lines carry trailing
    spaces and the page has blank lines; the AI prompt must still slice with raw selection
    indices rather than a normalised version of this text.
    """
    lines = [
        ("001", "ABSTRACT"),
        ("002", "Existing 3D motion generators face a trade-off between convenient but coarse   "),
        ("003", "text-based control and precise but manually specified pose guidance. Moreover,   "),
        ("004", "diffusion-based methods further incur substantial iterative sampling costs.   "),
        ("005", "The next line exists so a selection can end inside a later word.   "),
    ]
    parts: list[str] = []
    y = 760
    for number, _ in lines:
        parts.append(f"BT /F1 8 Tf 40 {y} Td ({number}) Tj ET")
        y -= 18
    y = 760
    for _, line in lines:
        parts.append(f"BT /F1 9 Tf 72 {y} Td ({escape_pdf_string(line)}) Tj ET")
        y -= 18
    # A trailing blank-line run, so the text layer has whitespace the normaliser would remove.
    parts.append("BT /F1 9 Tf 72 650 Td ( ) Tj ET")
    return "\n".join(parts)


def metadata_page(
    title: str,
    authors: str,
    affiliation: str,
    abstract_lines: list[str],
    footer_lines: list[str],
    *,
    title_size: int = 26,
) -> str:
    """A page laid out like the first page of a paper, for metadata recognition.

    The title is the largest text near the top, the author line sits directly below it and the
    ability to tell them apart is what the test is for. The footer carries the venue/identifier
    line; the abstract gives the recogniser a body size to compare the title against.
    """
    parts = [
        "0 0 0 rg",
        f"BT /F1 {title_size} Tf 72 760 Td ({escape_pdf_string(title)}) Tj ET",
        f"BT /F1 12 Tf 72 722 Td ({escape_pdf_string(authors)}) Tj ET",
        f"BT /F1 9 Tf 72 702 Td ({escape_pdf_string(affiliation)}) Tj ET",
        "BT /F1 10 Tf 72 662 Td (Abstract) Tj ET",
    ]
    y = 642
    for line in abstract_lines:
        parts.append(f"BT /F1 10 Tf 72 {y} Td ({escape_pdf_string(line)}) Tj ET")
        y -= 13
    y = 70
    for line in footer_lines:
        parts.append(f"BT /F1 8 Tf 72 {y} Td ({escape_pdf_string(line)}) Tj ET")
        y -= 12
    return "\n".join(parts)


def xmp_packet(
    title: str | None = None,
    authors: list[str] | None = None,
    doi: str | None = None,
    venue: str | None = None,
    year: str | None = None,
) -> bytes:
    """An XMP packet with the properties the recogniser reads, XML-escaped."""
    def escaped(value: str) -> str:
        return (
            value.replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace('"', "&quot;")
        )

    parts = [
        '<?xpacket begin="\ufeff" id="W5M0MpCehiHzreSzNTczkc9d"?>',
        '<x:xmpmeta xmlns:x="adobe:ns:meta/">',
        ' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">',
        '  <rdf:Description rdf:about=""',
        '    xmlns:dc="http://purl.org/dc/elements/1.1/"',
        '    xmlns:prism="http://prismstandard.org/namespaces/basic/2.0/">',
    ]
    if title is not None:
        parts.append(
            "   <dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">"
            + escaped(title)
            + "</rdf:li></rdf:Alt></dc:title>"
        )
    if authors:
        items = "".join(f"<rdf:li>{escaped(author)}</rdf:li>" for author in authors)
        parts.append(f"   <dc:creator><rdf:Seq>{items}</rdf:Seq></dc:creator>")
    if doi is not None:
        parts.append(f"   <prism:doi>{escaped(doi)}</prism:doi>")
    if venue is not None:
        parts.append(
            f"   <prism:publicationName>{escaped(venue)}</prism:publicationName>"
        )
    if year is not None:
        parts.append(f"   <prism:coverDate>{escaped(year)}-01-01</prism:coverDate>")
    parts += [
        "  </rdf:Description>",
        " </rdf:RDF>",
        "</x:xmpmeta>",
        '<?xpacket end="w"?>',
    ]
    return "\n".join(parts).encode("utf-8")


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


def numeric_citation_page() -> str:
    """The body page of the parenthesised-numeral fixture.

    Every shape the detector has to classify is on this one page, so a test can assert one
    result per line:

    * the accepted forms — a single number, a range, a comma list, a mixed list with a range;
    * a year in parentheses, an equation number pushed to the right margin, a function call
      `f(3)`, two enumerations opening their lines, a figure sub-label, a section reference,
      and a number beyond the bibliography's entry count.

    The equation number is placed at x=500 on its formula's baseline, independent of the
    formula text: that is the right-aligned shape a display equation really has, and it is
    position, not a character class, that separates it from a citation.
    """
    lines = [
        "Prior work established the baseline method (12).",
        "Related approaches extend that method (3\u20135).",
        "Two independent studies agree on this point (7, 9).",
        "A mixed group cites a span and one more work (3\u20135, 9).",
        "The dataset was released to the public (2020).",
        "The balance condition is stated below.",
        "The function f(3) is evaluated in the appendix.",
        "(1) First enumerated item, written as running prose.",
        "(2) Second enumerated item of the same list.",
        "Figure 3(b) shows the pipeline for a single run.",
        "Section 4 describes the setup in detail.",
        "A later work is discussed elsewhere (25).",
        "The page ends before the bibliography begins.",
    ]
    parts = [
        "0 0 0 rg",
        "BT /F1 20 Tf 72 790 Td (Numeric citation fixture) Tj ET",
        "BT /F1 10 Tf 72 766 Td (a numbered bibliography and the parenthesised citation shapes) Tj ET",
    ]
    y = 730
    for line in lines:
        parts.append(f"BT /F1 10 Tf 72 {y} Td ({escape_pdf_string(line)}) Tj ET")
        if line == "The balance condition is stated below.":
            # A display equation and its right-aligned number: the formula is at the left
            # edge, the number is at the right margin of the same baseline.
            parts.append(f"BT /F1 10 Tf 72 {y - 16} Td (x + y = z) Tj ET")
            parts.append(f"BT /F1 10 Tf 500 {y - 16} Td ((3)) Tj ET")
            y -= 16
        y -= 18
    return "\n".join(parts)


def numeric_references_page() -> str:
    """A Nature-like numbered bibliography: `1.` … `14.` at the start of each entry.

    Entry 12 is the work the single-number citation names; the range and list forms name
    entries 3–5, 7, 9 and 9 again. Fourteen entries are enough for every accepted form and
    for `(25)` to fall outside the count.
    """
    entries = [
        "1. Alpha, A. 2019. A first work on motion.",
        "2. Beta, B. 2020. A second work on shape.",
        "3. Gamma, C. 2021. A third work on light.",
        "4. Delta, D. 2022. A fourth work on sound.",
        "5. Epsilon, E. 2023. A fifth work on colour.",
        "6. Zeta, F. 2024. A sixth work on texture.",
        "7. Eta, G. 2019. A seventh work on flow.",
        "8. Theta, H. 2020. An eighth work on depth.",
        "9. Iota, I. 2021. A ninth work on edges.",
        "10. Kappa, J. 2022. A tenth work on style.",
        "11. Lambda, K. 2023. An eleventh work on shape.",
        "12. Mu, L. 2024. The cited baseline method.",
        "13. Nu, M. 2025. A thirteenth work on pose.",
        "14. Xi, N. 2026. A final work on motion.",
    ]
    parts = ["0 0 0 rg", "BT /F1 12 Tf 72 790 Td (References) Tj ET"]
    y = 760
    for entry in entries:
        parts.append(f"BT /F1 10 Tf 72 {y} Td ({escape_pdf_string(entry)}) Tj ET")
        y -= 15
    return "\n".join(parts)


def multi_bibliography_pages() -> list[tuple[str, int]]:
    """Two reference lists in one document, both numbered from 1 (T4.42).

    Page 1 is the main text; it cites the labels the main list prints (six of them, so the
    document-wide selection stays on the main list even though the appendix list is longer)
    and one label only the appendix list prints. Page 2 is the main bibliography. Page 3 opens
    an appendix and cites `[3]` — a number both lists print, naming different works. Page 4 is
    the appendix's own bibliography. Page 5 is a closing note after both lists, where nothing
    separates the two lists: the attribution must prefer the document-wide list and record the
    ambiguity.

    The test (`multi_bibliography_fixture.rs`) asserts the body's `[3]` lands on the main
    list's entry and the appendix's `[3]` on the appendix's, which is the defect the fixture
    exists for: before T4.42 both resolved against the main list.
    """
    body = "\n".join(
        [
            "0 0 0 rg",
            "BT /F1 18 Tf 72 790 Td (Two reference lists) Tj ET",
            "BT /F1 10 Tf 72 750 Td (The main text cites [1], [2], [3], [4], [5], [6] and also [7].) Tj ET",
            "BT /F1 10 Tf 72 734 Td (The appendix has its own list and cites [3] there.) Tj ET",
        ]
    )

    def list_page(heading_size: float, entries: list[str]) -> str:
        parts = [
            "0 0 0 rg",
            f"BT /F1 {heading_size:g} Tf 72 790 Td (References) Tj ET",
        ]
        y = 760
        for entry in entries:
            parts.append(
                f"BT /F1 10 Tf 72 {y} Td ({escape_pdf_string(entry)}) Tj ET"
            )
            y -= 15
        return "\n".join(parts)

    main = list_page(
        12,
        [
            "[1] One 2019. Report work one.",
            "[2] Two 2020. Report work two.",
            "[3] Three 2021. Report work three.",
            "[4] Four 2022. Report work four.",
            "[5] Five 2023. Report work five.",
            "[6] Six 2024. Report work six.",
        ],
    )
    appendix_body = "\n".join(
        [
            "0 0 0 rg",
            "BT /F1 14 Tf 72 790 Td (Appendix A \u2014 Extra results) Tj ET",
            "BT /F1 10 Tf 72 750 Td (The appendix relies on [3] and on [7].) Tj ET",
        ]
    )
    appendix = list_page(
        12,
        [
            "[1] Alpha 2017. Card work one.",
            "[2] Beta 2017. Card work two.",
            "[3] Gamma 2017. Card work three.",
            "[4] Delta 2017. Card work four.",
            "[5] Epsilon 2017. Card work five.",
            "[6] Zeta 2017. Card work six.",
            "[7] Eta 2017. Card work seven.",
            "[8] Theta 2017. Card work eight.",
        ],
    )
    closing = "\n".join(
        [
            "0 0 0 rg",
            "BT /F1 10 Tf 72 760 Td (A closing note cites [3] once more.) Tj ET",
        ]
    )
    return [(body, 0), (main, 0), (appendix_body, 0), (appendix, 0), (closing, 0)]


def caption_false_positive_pages() -> list[tuple[str, int]]:
    """The T4.12 shape: a label that only *ends* a sentence at the start of a printed line.

    Page 1 is running prose. The extractor breaks the paragraph at the printer's line end, so the
    second line begins `Table 3. We observe ...` — the label is the tail of the sentence above,
    not a caption. The real `Figure 1` caption sits lower on the same page, after a paragraph
    break, and the real `Table 3` caption is on page 2. A detector that only looks at line-start
    punctuation reports three captions here; the right answer is two, with the page-1 `Table 3`
    occurrence left in the mention stream.
    """
    body = [
        (742, "The previous section established the baseline method and"),
        (727, "Table 3. We observe that the correction halves the error."),
        (712, "This paragraph continues with more observations."),
    ]
    caption = [
        (640, "Figure 1: Overview of the pipeline in three stages."),
        (629, "The stages share one encoder."),
    ]
    parts = ["0 0 0 rg"]
    for y, text in body:
        parts.append(f"BT /F1 11 Tf 72 {y} Td ({escape_pdf_string(text)}) Tj ET")
    for y, text in caption:
        parts.append(f"BT /F1 8 Tf 72 {y} Td ({escape_pdf_string(text)}) Tj ET")
    page_one = "\n".join(parts)

    page_two = "\n".join(
        [
            "0 0 0 rg",
            "BT /F1 11 Tf 72 742 Td (Every run used the same schedule and settings.) Tj ET",
            "BT /F1 8 Tf 72 700 Td (Table 3: Settings used by every run.) Tj ET",
        ]
    )
    return [(page_one, 0), (page_two, 0)]


def index_past_120_pages(page_count: int = 130) -> list[tuple[str, int]]:
    """A 130-page document with a caption and a citation past the old 120-page window.

    The reference list is on page 2 (inside the old window, so the citation style is known) and
    page 1 already cites it. Everything after that is filler until page 121, which carries a real
    `Figure 1` caption, and page 125, which carries a real `Table 1` caption and a `[1]` citation.
    Before T4.13 the figure index stopped at page 120, so neither late caption was in it, and the
    citation map stopped there too, so page 125 was not cached. The filler is deliberate: the
    point of the fixture is the page number, not the content.
    """
    pages: list[tuple[str, int]] = []

    page_one = "\n".join(
        [
            "0 0 0 rg",
            "BT /F1 20 Tf 72 790 Td (Long index fixture) Tj ET",
            "BT /F1 11 Tf 72 740 Td (Prior work established the baseline method [1].) Tj ET",
            "BT /F1 11 Tf 72 715 Td (This document exists to carry content past page 120.) Tj ET",
        ]
    )
    pages.append((page_one, 0))

    references = "\n".join(
        [
            "0 0 0 rg",
            "BT /F1 14 Tf 72 790 Td (References) Tj ET",
            "BT /F1 10 Tf 72 760 Td (1. Alpha, A. 2019. A first work on motion.) Tj ET",
            "BT /F1 10 Tf 72 745 Td (2. Beta, B. 2020. A second work on shape.) Tj ET",
        ]
    )
    pages.append((references, 0))

    for number in range(3, page_count + 1):
        parts = [
            "0 0 0 rg",
            f"BT /F1 16 Tf 72 790 Td (Long fixture page {number} of {page_count}) Tj ET",
            f"BT /F1 10 Tf 72 750 Td (Filler line {number}: the page number is the content.) Tj ET",
            f"BT /F1 10 Tf 72 735 Td (Nothing here is a caption, a table or a citation.) Tj ET",
        ]
        if number == 121:
            parts += [
                "BT /F1 10 Tf 72 700 Td (The result below is stated on a page past the old window.) Tj ET",
                f"BT /F1 8 Tf 72 660 Td (Figure 1: Late figure on page {number}.) Tj ET",
                f"BT /F1 8 Tf 72 649 Td (It exists only to be found past page 120.) Tj ET",
            ]
        if number == 125:
            parts += [
                "BT /F1 10 Tf 72 700 Td (A later result extends the first work [1].) Tj ET",
                f"BT /F1 8 Tf 72 660 Td (Table 1: Late table on page {number}.) Tj ET",
            ]
        pages.append(("\n".join(parts), 0))

    return pages


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
                    "LyraReader fixture",
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
        # Selection indices versus prompt extraction: real line-number gutter characters,
        # trailing spaces and CRLF line breaks. The AI prompt must slice the raw text layer.
        "selection-numbered-margin.pdf": [(numbered_margin_page(), 0)],
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
        # 7) Cross-references: the body names a figure and a table, and their captions are on the
        #    pages after it. The mentions are the click targets (`find_caption_mentions`) and the
        #    captions are what a click has to find in the document-wide index (`find_captions`);
        #    a fixture with only one of the two cannot tell a working click from one that opens
        #    nothing. The mentions sit mid-line on purpose: an occurrence that opens a line and is
        #    followed by `:` is the caption itself, and is deliberately not a mention of it.
        "cross-references.pdf": [
            (
                text_page(
                    "Cross references",
                    "a figure and a table named in the running text",
                    [
                        "The pipeline has three stages (Figure 1).",
                        "Table 1 lists the settings every run used.",
                    ],
                ),
                0,
            ),
            (
                text_page(
                    "Results",
                    "the figure the body points at",
                    [
                        "The three stages share one encoder.",
                        "Figure 1: the pipeline in three stages.",
                    ],
                ),
                0,
            ),
            (
                text_page(
                    "Settings",
                    "the table the body points at",
                    [
                        "Every run used the same schedule.",
                        "Table 1: settings used in every run.",
                    ],
                ),
                0,
            ),
        ],
        # 8) T4.12: a wrapped prose line that starts with a label must stay a mention, while the
        #    real label of the same number on another page is still a caption.
        "caption-false-positive.pdf": caption_false_positive_pages(),
        # 9) T4.13: captions and citations on pages 121 and 125 of a 130-page document, past the
        #    120-page window the index used to stop at.
        "index-past-120.pdf": index_past_120_pages(),
        # 10) A parenthesised-numeral paper: a Nature-like `1.` … `14.` bibliography and one body
        #    page holding every accepted form and every non-citation form the detector must
        #    classify. The test (`paren_fixture.rs`) asserts one decision per case.
        "numeric-citations.pdf": [
            (numeric_citation_page(), 0),
            (numeric_references_page(), 0),
        ],
        # 11) T4.42: a main bibliography and an appendix bibliography, both numbered from 1, so
        #     the same bracket number means different works. The body citation must land on the
        #     main list and the appendix citation on the appendix list.
        "multi-bibliography.pdf": multi_bibliography_pages(),
    }

    for name, pages in fixtures.items():
        path = out_dir / name
        path.write_bytes(build_pdf(pages))
        print(f"  {path}  ({path.stat().st_size} bytes, {len(pages)} page(s))")

    # 12) T4.52: section references in running text. Page 1 points at "Section 2" and page 2 at
    #     "Appendix A"; the destination of the first is in the outline (so the preview title comes
    #     from there) and the second is deliberately not (so the reference's own text is used).
    #     The link boxes cover the whole line, which is how a producer that links only the
    #     numeral is modelled: the classifier reads the line, not just the box.
    section_pages = [
        (
            text_page(
                "Linking",
                "section references in running text",
                ["See Section 2 for the method.", "Appendix A lists the parameters."],
            ),
            0,
        ),
        (
            text_page(
                "2 Method",
                "the section the body points at",
                ["The method has three steps."],
            ),
            0,
        ),
        (
            text_page(
                "Appendix A Parameters",
                "the appendix the body points at",
                ["Every parameter is listed here."],
            ),
            0,
        ),
    ]
    section_annotations = {
        0: [
            # Page object numbers are 4 + 2 * index: page 0 = 4, page 1 = 6, page 2 = 8.
            annotation("Link", body_line_box(0, 523), extra="/Border [0 0 0] /Dest [6 0 R /Fit]"),
            annotation("Link", body_line_box(1, 523), extra="/Border [0 0 0] /Dest [8 0 R /Fit]"),
        ]
    }
    section_outline = [{"title": "2 Method", "page": 1, "children": []}]
    path = out_dir / "section-references.pdf"
    path.write_bytes(build_pdf(section_pages, section_annotations, outline=section_outline))
    print(f"  {path}  ({path.stat().st_size} bytes, 3 page(s), 2 section links, 1 outline entry)")

    # 13) T4.51: a page with no text and four known tones, so the alpha profile of a transparent
    #     region can be measured at exact pixels: unpainted paper (clear), a near-white patch, a
    #     light-grey patch, a mid-grey patch, a black patch, and a 0.5 pt light-grey table rule.
    alpha_content = "\n".join([
        "0.95 0.95 0.95 rg 72 700 120 60 re f",
        "0.8 0.8 0.8 rg 72 600 120 60 re f",
        "0.5 0.5 0.5 rg 240 600 120 60 re f",
        "0 0 0 rg 408 600 120 60 re f",
        "0.8 0.8 0.8 RG 0.5 w 72 500 m 523 500 l S",
    ])
    path = out_dir / "alpha-crop.pdf"
    path.write_bytes(build_pdf([(alpha_content, 0)]))
    print(f"  {path}  ({path.stat().st_size} bytes, 1 page, tone patches + light-grey rule)")

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

    # Inline comments are /Contents on markup, rather than standalone /Text notes.
    inline_annotations = [
        annotation("Highlight", highlight_box(),
                   extra=f"/QuadPoints {quad_points([body_line_box(0, 460), body_line_box(1, 360)])} /C [0.95 0.8 0.8] /NM (inline-multiline)",
                   contents="A comment on two highlighted lines.", author="Reviewer A"),
        annotation("Highlight", body_line_box(0, 60),
                   extra=f"/QuadPoints {quad_points([body_line_box(0, 60)])} /C [1 0.5 0] /CA 0.4 /NM (inline-overlapping)",
                   contents="Another comment on the same line.", author="Reviewer B"),
        annotation("Underline", body_line_box(2, 460),
                   extra=f"/QuadPoints {quad_points([body_line_box(2, 460)])} /C [0.2 0.6 1]",
                   contents="An underline comment."),
        annotation("Highlight", body_line_box(3, 200), extra="/C [1 1 0]"),
        annotation("Highlight", body_line_box(4, 200), extra="/C [1 1 0]", contents="   "),
        annotation("Highlight", body_line_box(5, 200), extra="/C [1 1 0]", flags=2, contents="Hidden comment."),
        annotation("Highlight", body_line_box(6, 200), contents="A comment without quads or colour."),
        annotation("Text", (500, 700, 520, 720), contents="A separate sticky note."),
    ]
    path = out_dir / "annotated-inline-notes.pdf"
    path.write_bytes(build_pdf(annotated_pages[:1], {0: inline_annotations}))
    print(f"  {path}  ({path.stat().st_size} bytes, 1 page)")

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

    # Ink and shapes written by another producer: the reading half of T3.4. Kept separate from
    # annotated.pdf so the existing annotation corpus' counts and fixture bytes do not move.
    stroke_pages = [
        (
            text_page(
                "Annotated with ink and shapes",
                "strokes and shapes written by another producer",
                [f"Line {number}: another writer's ink and shapes." for number in range(1, 9)],
            ),
            0,
        ),
    ]
    stroke_annotations, stroke_extras = annotated_strokes_fixture()
    path = out_dir / "annotated-strokes.pdf"
    path.write_bytes(build_pdf(stroke_pages, stroke_annotations, stroke_extras))
    print(f"  {path}  ({path.stat().st_size} bytes, {len(stroke_pages)} page(s))")

    # Navigation borders must render even when content annotations are drawn by the shell.
    link_borders = [
        annotation("Link", (72, 650, 220, 670), extra="/Border [0 0 1] /C [0 1 0] /A << /S /URI /URI (https://example.org/green) >>"),
        annotation("Link", (260, 650, 300, 670), extra="/Border [0 0 1] /C [1 0 0] /Dest [4 0 R /Fit]"),
        annotation("Link", (350, 650, 390, 670), flags=2, extra="/Border [0 0 1] /C [0 0 1] /A << /S /URI /URI (https://example.org/hidden) >>"),
        annotation("Link", (72, 600, 220, 620), extra="/Border [0 0 0] /C [0 0 1] /A << /S /URI /URI (https://example.org/invisible) >>"),
        annotation("Link", (260, 600, 390, 620), extra="/BS << /W 2 /S /D /D [4 4] >> /C [1 0 0] /A << /S /URI /URI (https://example.org/dashed) >>"),
        annotation("Highlight", (420, 700, 500, 720), extra="/C [0 0 1] /QuadPoints [420 720 500 720 420 700 500 700]", contents="Shell-rendered content annotation."),
    ]
    path = out_dir / "link-borders.pdf"
    path.write_bytes(build_pdf(annotated_pages[:1], {0: link_borders}))
    print(f"  {path}  ({path.stat().st_size} bytes, 1 page)")

    # 7) Notes and no markup, which is one of the user's review PDFs exactly: 22 content
    #    annotations, every one of them a sticky note or a free-text annotation, and not a single
    #    highlight to draw. A reader that only knows the text-markup kinds shows it as untouched.
    #    Between them the four annotations below cover everything a note can be asked to do —
    #    icon in its own colour, icon with no colour, text laid out from /DA and /Q, text in the
    #    default ink — and the three reasons an annotation is deliberately not drawn.
    notes_pages = [
        (
            text_page(
                "Annotated with notes",
                "sticky notes and free text, and no markup at all",
                [f"Line {number}: commented on rather than marked up." for number in range(1, 9)],
            ),
            0,
        ),
    ]
    notes_annotations, notes_extras = annotated_notes_fixture(len(notes_pages))
    path = out_dir / "annotated-notes.pdf"
    path.write_bytes(build_pdf(notes_pages, notes_annotations, notes_extras))
    print(f"  {path}  ({path.stat().st_size} bytes, {len(notes_pages)} page(s))")

    # 8) Replies: `/IRT` threads across two pages, including a second-level reply, a cross-page
    #    reply, a hidden parent, and a malformed cycle. This is the evidence the sidebar's
    #    nesting and orphan accounting run against.
    replies_pages = [
        (
            text_page(
                "Annotated with replies",
                "a review thread whose replies are ordinary /IRT annotations",
                [f"Line {number}: the highlighted sentence and its replies." for number in range(1, 9)],
            ),
            0,
        ),
        (
            text_page(
                "Replies continued",
                "a reply on this page answers one on the previous page",
                [f"Line {number}: a second page of conversation." for number in range(1, 9)],
            ),
            0,
        ),
    ]
    replies_annotations = annotated_replies_fixture(len(replies_pages))
    path = out_dir / "annotated-replies.pdf"
    path.write_bytes(build_pdf(replies_pages, replies_annotations))
    print(f"  {path}  ({path.stat().st_size} bytes, {len(replies_pages)} page(s))")

    # 9) An outline three levels deep, with a top-level section that has children but no page of
    #    its own. The sidebar numbers the hierarchy (`1`, `1.1`, `1.1.1`) and indents by depth;
    #    the nesting is only testable if the fixture's /Outlines tree survives PDFium intact.
    outline_pages = [
        (
            text_page(
                "Chapter One",
                "a three-level outline fixture",
                ["1 Introduction", "1.1 Background", "1.1.1 Prior work"],
            ),
            0,
        ),
        (
            text_page(
                "Chapter Two",
                "the section without a destination still has children",
                ["2 Methods", "2.1 Method", "2.1.1 Detail"],
            ),
            0,
        ),
        (
            text_page(
                "Chapter Three",
                "the last leaf of the outline",
                ["3 Results"],
            ),
            0,
        ),
    ]
    outline = [
        {
            "title": "Chapter One",
            "page": 0,
            "children": [
                {
                    "title": "Background",
                    "page": 0,
                    "children": [{"title": "Prior work", "page": 1, "children": []}],
                }
            ],
        },
        {
            "title": "Chapter Two",
            "page": None,
            "children": [
                {
                    "title": "Method",
                    "page": 1,
                    "children": [{"title": "Detail", "page": 2, "children": []}],
                },
                {"title": "Setup", "page": 2, "children": []},
            ],
        },
        {"title": "Chapter Three", "page": 2, "children": []},
    ]
    path = out_dir / "outlined.pdf"
    path.write_bytes(build_pdf(outline_pages, outline=outline))
    print(f"  {path}  ({path.stat().st_size} bytes, {len(outline_pages)} page(s), 8 outline entries)")

    # 10) Metadata fixtures. `metadata-embedded.pdf` has both `/Info` and XMP (XMP wins);
    #     `metadata-info.pdf` has only `/Info` (the first-page title must not win);
    #     `metadata-text-layer.pdf` has no embedded metadata at all, so title, authors, venue,
    #     year and DOI have to come from page one; `metadata-arxiv.pdf` adds an arXiv id and
    #     no venue, which must produce a `misc` entry, not an invented journal.
    embedded_metadata = xmp_packet(
        title="Embedded Metadata: A Study of {Braces} & Percent 100%",
        authors=["Ada Lovelace", "Alan Turing"],
        doi="10.1234/embedded.2024.001",
        venue="Journal of Embedded Testing",
        year="2024",
    )
    embedded_page = metadata_page(
        "Page One Text Title",
        "Grace Hopper",
        "Department of Testing, Example University",
        [
            "This body paragraph is long enough to establish the page's body text size.",
            "It is deliberately not the metadata the reader should see in the panel.",
        ],
        [
            "Proceedings of the Wrong Venue 1999",
            "https://doi.org/10.9999/page.one",
        ],
    )
    path = out_dir / "metadata-embedded.pdf"
    path.write_bytes(
        build_pdf(
            [(embedded_page, 0)],
            info={
                "Title": "Wrong Information Dictionary Title",
                "Author": "Wrong Information Dictionary Author",
                "Producer": "make-fixtures.py",
            },
            xmp=embedded_metadata,
        )
    )
    print(f"  {path}  ({path.stat().st_size} bytes, 1 page, /Info + XMP)")

    info_page = metadata_page(
        "Page One Text Title",
        "Grace Hopper",
        "Department of Testing, Example University",
        [
            "This body paragraph is long enough to establish the page's body text size.",
            "The embedded dictionary below is the only source of a title and authors.",
        ],
        [],
    )
    path = out_dir / "metadata-info.pdf"
    path.write_bytes(
        build_pdf(
            [(info_page, 0)],
            info={
                "Title": "Information Dictionary Title",
                "Author": "Info Author; Second Author",
                "Subject": "A subject with no identifier in it",
            },
        )
    )
    print(f"  {path}  ({path.stat().st_size} bytes, 1 page, /Info only)")

    text_layer_page = metadata_page(
        "Page One Title: 100% & Under_Score",
        "Marek Müller, Ada Lovelace",
        "Department of Testing, Example University",
        [
            "The abstract begins here and has enough words to look like ordinary body text.",
            "A second line keeps the median line height stable for the layout heuristics.",
        ],
        [
            "Proceedings of the 2024 Testing Conference",
            "https://doi.org/10.5555/2024.12345",
        ],
    )
    path = out_dir / "metadata-text-layer.pdf"
    path.write_bytes(build_pdf([(text_layer_page, 0)]))
    print(f"  {path}  ({path.stat().st_size} bytes, 1 page, text layer only)")

    arxiv_page = metadata_page(
        "An arXiv Paper Without a Venue",
        "Grace Hopper",
        "Department of Testing, Example University",
        [
            "This paper is a preprint and its venue is deliberately absent from page one.",
            "Only the arXiv identifier and its date can be found on the page.",
        ],
        ["arXiv:2303.08774v2 [cs.CL]"],
    )
    path = out_dir / "metadata-arxiv.pdf"
    path.write_bytes(build_pdf([(arxiv_page, 0)]))
    print(f"  {path}  ({path.stat().st_size} bytes, 1 page, arXiv id only)")

    # 10b) Form fixtures. Every field kind the reader models, on two pages, with values a
    #      different writer put there (the appearance streams are generated here). The
    #      encrypted copy carries the same fields behind the standard security handler with
    #      an empty user password, so PDFium opens it without a prompt; filling it must still
    #      be refused. `/Info` gives the properties editor something to correct.
    form_pages = [(form_page_content(0), 0), (form_page_content(1), 0)]
    form_info = {
        "Title": "LyraReader Form Fixture",
        "Author": "Fixture Author",
        "Subject": "AcroForm fields for the reader's form tool",
        "Keywords": "forms, fixture, lyrareader",
        "Creator": "make-fixtures.py",
        "Producer": "make-fixtures.py",
    }
    path = out_dir / "form-fields.pdf"
    path.write_bytes(build_form_pdf(form_pages, FORM_FIELDS, info=form_info))
    print(f"  {path}  ({path.stat().st_size} bytes, 2 page(s), {len(FORM_FIELDS)} form fields)")

    path = out_dir / "form-fields-encrypted.pdf"
    path.write_bytes(build_form_pdf(form_pages, FORM_FIELDS, info=form_info, encrypt=True))
    print(f"  {path}  ({path.stat().st_size} bytes, encrypted with an empty user password)")

    if long_pages > 0:
        pages = long_document(long_pages)
        path = out_dir / (long_name or f"long-{long_pages}.pdf")
        path.write_bytes(build_pdf(pages))
        print(f"  {path}  ({path.stat().st_size} bytes, {len(pages)} page(s))")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
