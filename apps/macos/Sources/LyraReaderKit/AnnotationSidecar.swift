import Foundation

/// Reading and writing the annotation sidecar (`<doc>.pdf.lyra-reader-annotations.json`).
///
/// The sidecar is a JSON array of `AppState.Annotation` entries **and user bookmarks**.
/// Both live in one file because they are the reader's marks on one document, and the
/// array's per-entry compatibility rule keeps them safe together:
///
/// * **Forward compatibility.** A sidecar written by a newer LyraReader can hold entries this
///   version cannot draw: an `ink` kind, a `color` value in a shape this version does not
///   know, a field that did not exist yet. Treating those as "the file is invalid" would make
///   an older version refuse the file and, if the reader forced a reset, destroy entries the
///   newer version still needs. Instead the *raw text* of such an entry is kept and written
///   back untouched, so the file round-trips through this version unchanged.
/// * **Bookmarks and older builds.** A bookmark is written with `"kind": "bookmark"`, which
///   no annotation-only build understands. Such a build classifies it as an entry it cannot
///   interpret — before it ever looks at `page` or `title` — and preserves its exact JSON
///   text. That is why bookmarks can share this file without an older build misreading one as
///   a broken highlight: the tag comes first. This build reads those entries back as
///   `Bookmark`; a *newer* build may add bookmark fields, which this version then preserves
///   verbatim in the same way. The compatibility machinery is per entry, so neither direction
///   has to know the other's schema.
/// * **Colour, and why the two encodings exist.** An annotation's colour used to be an index
///   into a four-entry palette (`colorIndex`); it is now an `AnnotationColor` written as
///   `"color": "#RRGGBBAA"`, because a PDF annotated by somebody else carries colours no
///   four-entry palette can express. Both keys are read. Only one is written, and which one is
///   decided by the colour itself (see `AppState.Annotation.encode(to:)`):
///
///   | sidecar | this build | the build that only knows `colorIndex` |
///   | --- | --- | --- |
///   | `colorIndex: 2` | reads it as palette colour 2 — exactly as before | reads it as before |
///   | `color` = a palette colour | writes `colorIndex`, no `color` key | reads and draws it normally |
///   | `color` = any other colour | writes `color`, no `colorIndex` | keeps the entry verbatim |
///
///   The last row is the honest limit: a colour outside that palette cannot be *drawn* by a
///   build whose model has no way to name it. What such a build must not do is lose it or
///   reinterpret it, and it does not — the entry comes back out of an older build unchanged,
///   while its own annotations keep working.
/// * **Fail closed, precisely.** Structural damage — not JSON at all, not an array, an entry
///   without id/page/range, a page outside the document, a duplicate id — is still an error.
///   The caller blocks writes rather than replacing a file it does not understand; the UI
///   then offers the explicit "back up and start fresh" recovery.
enum AnnotationSidecar {
    /// Where an entry came from, so the file can be reproduced in its original order.
    enum Slot {
        /// An entry this version understands; looking it up by id in the current array keeps
        /// edits, undo and redo working without a second copy of the data.
        case annotation(UUID)
        /// A bookmark this version understands; its array order is the reader's order.
        case bookmark(UUID)
        /// Verbatim JSON text of an entry this version does not understand.
        case opaque(String)
    }

    struct Contents {
        var annotations: [AppState.Annotation]
        var bookmarks: [Bookmark]
        var slots: [Slot]

        var preservedCount: Int {
            slots.reduce(0) { count, slot in
                if case .opaque = slot { return count + 1 }
                return count
            }
        }
    }

    enum SidecarError: LocalizedError {
        case structure(String)

        var errorDescription: String? {
            switch self {
            case .structure(let detail): return "Invalid annotation sidecar: \(detail)"
            }
        }
    }

    /// Keys this version knows how to interpret on an annotation entry. An entry carrying
    /// anything else is preserved rather than parsed: guessing at a newer schema risks writing
    /// back a half-understood entry.
    private static let knownAnnotationKeys: Set<String> = [
        "id", "kind", "page", "start", "end", "color", "colorIndex", "note", "createdAt",
        // Geometry entries (`ink`, `square`, `circle`, `line`, `arrow`) carry a schema version
        // and page-space geometry. A build that does not know those keys — or that knows the
        // kind but not this version — preserves the entry verbatim instead of guessing.
        "version", "paths", "rect", "lineStart", "lineEnd", "strokeWidth",
        // Placed text (`stickyNote`, `textBox`) carries its box, its font size (text box only)
        // and the same versioning rule.
        "fontSize",
        // An entry that edits an annotation already in the PDF: its file identity, the fixed
        // quads of a foreign text mark, and a free text box's `/Q`.
        "fileIdentity", "quads", "textAlignment",
    ]

    /// The same rule for bookmark entries. `kind` is the discriminator and is required by the
    /// encoder; a newer build's additional key makes this build preserve the whole entry.
    private static let knownBookmarkKeys: Set<String> = [
        "id", "kind", "page", "title", "yPt", "createdAt",
    ]

    // MARK: - Loading

    static func decode(_ data: Data, pageCount: Int, paletteCount: Int) throws -> Contents {
        let elements = try JSONArrayElements.parse(data)

        var annotations: [AppState.Annotation] = []
        var bookmarks: [Bookmark] = []
        var slots: [Slot] = []
        var seenIDs = Set<UUID>()
        var seenBookmarkIDs = Set<UUID>()

        for element in elements {
            let elementData = Data(element.utf8)
            guard let object = try? JSONSerialization.jsonObject(with: elementData) as? [String: Any] else {
                throw SidecarError.structure("an entry is not a JSON object")
            }

            let kindText = object["kind"] as? String

            // A bookmark is classified before the annotation rules are applied. The `kind`
            // tag is what an annotation-only build sees first too, and it preserves the
            // entry because "bookmark" is a kind it cannot draw.
            if kindText == Bookmark.sidecarKind {
                let unknownKeys = Set(object.keys).subtracting(knownBookmarkKeys)
                guard unknownKeys.isEmpty else {
                    slots.append(.opaque(element))
                    continue
                }
                guard let bookmark = try? JSONDecoder().decode(Bookmark.self, from: elementData) else {
                    throw SidecarError.structure("a bookmark is missing a required field")
                }
                guard bookmark.page >= 0, bookmark.page < pageCount else {
                    throw SidecarError.structure("bookmark page \(bookmark.page + 1) is outside the document")
                }
                guard bookmark.yPt.isFinite, bookmark.yPt >= 0 else {
                    throw SidecarError.structure("bookmark position \(bookmark.yPt) is invalid")
                }
                guard seenBookmarkIDs.insert(bookmark.id).inserted else {
                    throw SidecarError.structure("duplicate bookmark identity")
                }
                bookmarks.append(bookmark)
                slots.append(.bookmark(bookmark.id))
                continue
            }

            // Decide whether this version can interpret the entry at all. Anything it cannot
            // interpret is kept verbatim and skipped while rendering — never dropped, and
            // never a reason to reject the whole file.
            let unknownKeys = Set(object.keys).subtracting(knownAnnotationKeys)
            let kind = kindText.flatMap(AppState.Annotation.Kind.init(rawValue:))
            let kindUnderstood = kindText == nil || kind != nil
            // Either colour shape counts as understood: this version's `color`, or the older
            // `colorIndex` when it names a palette entry. An entry with neither, or with an
            // index outside the palette, is preserved rather than guessed at.
            let colorUnderstood = (object["color"] as? String).map { AnnotationColor(hex: $0) != nil }
                ?? (object["colorIndex"] as? Int).map { $0 >= 0 && $0 < paletteCount }
                ?? false
            // A geometry entry is versioned. Text entries are the shape every older build
            // knows and carry no version; if one appears, a newer build wrote it and this one
            // must preserve it rather than interpret fields it does not know.
            let versionUnderstood: Bool = if let kind, kind.isGeometry {
                (object["version"] as? Int) == AppState.Annotation.geometryVersion
            } else if let kind, kind.isPlacedText {
                (object["version"] as? Int) == AppState.Annotation.placedTextVersion
            } else {
                object["version"] == nil
            }

            guard unknownKeys.isEmpty, kindUnderstood, colorUnderstood, versionUnderstood else {
                slots.append(.opaque(element))
                continue
            }

            // From here on the entry claims to be one this version understands, so it has to
            // hold together: a structurally broken entry still fails the load (and therefore
            // blocks writes) instead of being silently reinterpreted.
            guard let annotation = try? JSONDecoder().decode(AppState.Annotation.self, from: elementData) else {
                throw SidecarError.structure("an entry is missing a required field")
            }
            guard annotation.page >= 0, annotation.page < pageCount else {
                throw SidecarError.structure("page \(annotation.page + 1) is outside the document")
            }
            if annotation.kind.isGeometry || annotation.kind.isPlacedText {
                guard annotation.hasValidGeometry else {
                    throw SidecarError.structure(
                        "an \(annotation.kind.rawValue) entry has incomplete or non-finite geometry")
                }
            } else {
                guard annotation.start >= 0, annotation.end >= annotation.start else {
                    throw SidecarError.structure("invalid character range \(annotation.start)…\(annotation.end)")
                }
            }
            guard seenIDs.insert(annotation.id).inserted else {
                throw SidecarError.structure("duplicate annotation identity")
            }

            annotations.append(annotation)
            slots.append(.annotation(annotation.id))
        }

        return Contents(annotations: annotations, bookmarks: bookmarks, slots: slots)
    }

    // MARK: - Saving

    /// The bytes to write for `annotations` and `bookmarks`, in the sidecar's original entry
    /// order, with the preserved entries reproduced verbatim.
    ///
    /// Note the shape of the output: entries this version understands go through `JSONEncoder`
    /// (`.prettyPrinted, .sortedKeys`, as before this change), so a file with no foreign
    /// entries is byte-identical to what the previous implementation wrote. Foreign entries are
    /// spliced in as the exact text they had in the file they came from.
    static func encode(
        annotations: [AppState.Annotation],
        bookmarks: [Bookmark],
        slots: [Slot]
    ) throws -> Data {
        var pieces: [Piece] = []
        var pendingAnnotations: [AppState.Annotation] = []
        var pendingBookmarks: [Bookmark] = []
        var emittedAnnotations = Set<UUID>()
        var emittedBookmarks = Set<UUID>()

        func closePendingRuns() {
            if !pendingAnnotations.isEmpty {
                pieces.append(.annotations(pendingAnnotations))
                pendingAnnotations = []
            }
            if !pendingBookmarks.isEmpty {
                pieces.append(.bookmarks(pendingBookmarks))
                pendingBookmarks = []
            }
        }

        for slot in slots {
            switch slot {
            case .opaque(let raw):
                closePendingRuns()
                pieces.append(.foreign(raw))
            case .annotation(let id):
                // Leaving a bookmark run flushes it, so an interleaved file keeps its order.
                if !pendingBookmarks.isEmpty { closePendingRuns() }
                // Absent means the entry was deleted; a second slot for the same id (only
                // possible in a hand-edited file) is ignored.
                guard !emittedAnnotations.contains(id),
                      let annotation = annotations.first(where: { $0.id == id }) else { continue }
                emittedAnnotations.insert(id)
                pendingAnnotations.append(annotation)
            case .bookmark(let id):
                if !pendingAnnotations.isEmpty { closePendingRuns() }
                guard !emittedBookmarks.contains(id),
                      let bookmark = bookmarks.first(where: { $0.id == id }) else { continue }
                emittedBookmarks.insert(id)
                pendingBookmarks.append(bookmark)
            }
        }
        for annotation in annotations where !emittedAnnotations.contains(annotation.id) {
            if !pendingBookmarks.isEmpty { closePendingRuns() }
            pendingAnnotations.append(annotation)
        }
        closePendingRuns()
        for bookmark in bookmarks where !emittedBookmarks.contains(bookmark.id) {
            pendingBookmarks.append(bookmark)
        }
        closePendingRuns()

        guard !pieces.isEmpty else {
            return try encoder().encode([AppState.Annotation]())
        }

        var lines: [String] = []
        for piece in pieces {
            switch piece {
            case .foreign(let raw):
                // `raw` starts at the entry's first byte (`{`); the two spaces put it back at
                // the array's indentation level. Its own interior text is untouched.
                lines.append("  " + raw)
            case .annotations(let run):
                lines.append(try entriesBody(of: try encoder().encode(run)))
            case .bookmarks(let run):
                lines.append(try entriesBody(of: try encoder().encode(run)))
            }
        }
        let file = "[\n" + lines.joined(separator: ",\n") + "\n]"
        return Data(file.utf8)
    }

    private enum Piece {
        case annotations([AppState.Annotation])
        case bookmarks([Bookmark])
        case foreign(String)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// `JSONEncoder` writes an array as `"[\n" + entries + "\n]"`, with each entry already
    /// indented by two spaces; that inner text is exactly what belongs in the assembled file.
    private static func entriesBody(of data: Data) throws -> String {
        let text = String(decoding: data, as: UTF8.self)
        guard text.hasPrefix("[\n"), text.hasSuffix("\n]") else {
            throw SidecarError.structure("unexpected encoder output")
        }
        return String(text.dropFirst(2).dropLast(2))
    }
}

/// Scanner for the top-level array of a sidecar.
///
/// `JSONDecoder` cannot hand back the bytes of an element it does not understand, and a
/// `JSONSerialization` round trip is *not* byte-faithful (`\/` escaping, number and date
/// formatting, key order), so the only way to preserve a foreign entry exactly is to slice the
/// original text. This scanner finds those slices; it validates enough structure to find them
/// and leaves full JSON validation to `JSONSerialization`, which every retained entry goes
/// through.
enum JSONArrayElements {
    enum ParseError: LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let detail): return "Invalid annotation sidecar: \(detail)"
            }
        }
    }

    static func parse(_ data: Data) throws -> [String] {
        let bytes = [UInt8](data)
        var index = 0
        let count = bytes.count

        func skipWhitespace() {
            while index < count, isWhitespace(bytes[index]) { index += 1 }
        }

        func skipString() throws {
            index += 1 // opening quote
            while index < count {
                switch bytes[index] {
                case UInt8(ascii: "\\"):
                    index += 2 // an escape can never end the string
                case UInt8(ascii: "\""):
                    index += 1
                    return
                default:
                    index += 1
                }
            }
            throw ParseError.message("unterminated string")
        }

        func skipComposite() throws {
            var depth = 0
            while index < count {
                switch bytes[index] {
                case UInt8(ascii: "\""):
                    try skipString()
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 {
                        index += 1
                        return
                    }
                default:
                    break
                }
                index += 1
            }
            throw ParseError.message("unterminated entry")
        }

        func skipValue() throws {
            switch bytes[index] {
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                try skipComposite()
            case UInt8(ascii: "\""):
                try skipString()
            default:
                let start = index
                while index < count, !isWhitespace(bytes[index]),
                      bytes[index] != UInt8(ascii: ","), bytes[index] != UInt8(ascii: "]"),
                      bytes[index] != UInt8(ascii: "}") {
                    index += 1
                }
                guard index > start else { throw ParseError.message("unexpected character") }
            }
        }

        skipWhitespace()
        guard index < count, bytes[index] == UInt8(ascii: "[") else {
            throw ParseError.message("the sidecar must be a JSON array")
        }
        index += 1

        var elements: [String] = []
        skipWhitespace()
        if index < count, bytes[index] == UInt8(ascii: "]") {
            index += 1
        } else {
            while true {
                skipWhitespace()
                guard index < count else { throw ParseError.message("unexpected end of file") }
                guard bytes[index] != UInt8(ascii: ","), bytes[index] != UInt8(ascii: "]") else {
                    throw ParseError.message("empty array element")
                }
                let start = index
                try skipValue()
                elements.append(String(decoding: bytes[start..<index], as: UTF8.self))
                skipWhitespace()
                guard index < count else { throw ParseError.message("unexpected end of file") }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                guard bytes[index] == UInt8(ascii: "]") else {
                    throw ParseError.message("unexpected character after an entry")
                }
                index += 1
                break
            }
        }

        skipWhitespace()
        guard index == count else { throw ParseError.message("unexpected trailing content") }
        return elements
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
