import Foundation

/// Reading and writing the annotation sidecar (`<doc>.pdf.aris-annotations.json`).
///
/// The sidecar is a JSON array of `AppState.Annotation`. Two properties shape this code:
///
/// * **Forward compatibility.** A sidecar written by a newer Lyra can hold entries this
///   version cannot draw: an `ink` kind, a colour outside `AppState.highlightPalette`, a
///   field that did not exist yet. Treating those as "the file is invalid" would make an
///   older version refuse the file and, if the reader forced a reset, destroy entries the
///   newer version still needs. Instead the *raw text* of such an entry is kept and written
///   back untouched, so the file round-trips through this version unchanged.
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
        /// Verbatim JSON text of an entry this version does not understand.
        case opaque(String)
    }

    struct Contents {
        var annotations: [AppState.Annotation]
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

    /// Keys this version knows how to interpret. An entry carrying anything else is preserved
    /// rather than parsed: guessing at a newer schema risks writing back a half-understood entry.
    private static let knownKeys: Set<String> = [
        "id", "kind", "page", "start", "end", "colorIndex", "note", "createdAt",
    ]

    // MARK: - Loading

    static func decode(_ data: Data, pageCount: Int, paletteCount: Int) throws -> Contents {
        let elements = try JSONArrayElements.parse(data)

        var annotations: [AppState.Annotation] = []
        var slots: [Slot] = []
        var seenIDs = Set<UUID>()

        for element in elements {
            let elementData = Data(element.utf8)
            guard let object = try? JSONSerialization.jsonObject(with: elementData) as? [String: Any] else {
                throw SidecarError.structure("an entry is not a JSON object")
            }

            // Decide whether this version can interpret the entry at all. Anything it cannot
            // interpret is kept verbatim and skipped while rendering — never dropped, and
            // never a reason to reject the whole file.
            let unknownKeys = Set(object.keys).subtracting(knownKeys)
            let kindText = object["kind"] as? String
            let kindUnderstood = kindText == nil
                || AppState.Annotation.Kind(rawValue: kindText ?? "") != nil
            let colorUnderstood = (object["colorIndex"] as? Int)
                .map { $0 >= 0 && $0 < paletteCount } ?? false

            guard unknownKeys.isEmpty, kindUnderstood, colorUnderstood else {
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
            guard annotation.start >= 0, annotation.end >= annotation.start else {
                throw SidecarError.structure("invalid character range \(annotation.start)…\(annotation.end)")
            }
            guard seenIDs.insert(annotation.id).inserted else {
                throw SidecarError.structure("duplicate annotation identity")
            }

            annotations.append(annotation)
            slots.append(.annotation(annotation.id))
        }

        return Contents(annotations: annotations, slots: slots)
    }

    // MARK: - Saving

    /// The bytes to write for `annotations`, in the sidecar's original entry order, with the
    /// preserved entries reproduced verbatim.
    ///
    /// Note the shape of the output: entries this version understands go through `JSONEncoder`
    /// (`.prettyPrinted, .sortedKeys`, as before this change), so a file with no foreign
    /// entries is byte-identical to what the previous implementation wrote. Foreign entries are
    /// spliced in as the exact text they had in the file they came from.
    static func encode(annotations: [AppState.Annotation], slots: [Slot]) throws -> Data {
        var pieces: [Piece] = []
        var pending: [AppState.Annotation] = []
        var emitted = Set<UUID>()

        func closePendingRun() {
            guard !pending.isEmpty else { return }
            pieces.append(.understood(pending))
            pending = []
        }

        for slot in slots {
            switch slot {
            case .opaque(let raw):
                closePendingRun()
                pieces.append(.foreign(raw))
            case .annotation(let id):
                // Absent means the entry was deleted; a second slot for the same id (only
                // possible in a hand-edited file) is ignored.
                guard !emitted.contains(id),
                      let annotation = annotations.first(where: { $0.id == id }) else { continue }
                emitted.insert(id)
                pending.append(annotation)
            }
        }
        for annotation in annotations where !emitted.contains(annotation.id) {
            pending.append(annotation)
        }
        closePendingRun()

        guard !pieces.isEmpty else { return try encoder().encode([AppState.Annotation]()) }

        var lines: [String] = []
        for piece in pieces {
            switch piece {
            case .foreign(let raw):
                // `raw` starts at the entry's first byte (`{`); the two spaces put it back at
                // the array's indentation level. Its own interior text is untouched.
                lines.append("  " + raw)
            case .understood(let run):
                lines.append(try entriesBody(of: try encoder().encode(run)))
            }
        }
        let file = "[\n" + lines.joined(separator: ",\n") + "\n]"
        return Data(file.utf8)
    }

    private enum Piece {
        case understood([AppState.Annotation])
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
