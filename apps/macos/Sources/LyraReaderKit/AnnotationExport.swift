import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// The two text formats the reader can export annotations in.
///
/// The format is a property of the *file being written*, not of the reader's state: nothing is
/// sent anywhere and no network code is involved, so the only thing the choice changes is the
/// bytes that land beside the PDF.
public enum AnnotationExportFormat: String, CaseIterable, Identifiable, Sendable {
    case markdown
    case csv

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .markdown: return "Markdown"
        case .csv: return "CSV"
        }
    }

    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .csv: return "csv"
        }
    }

    public var contentType: UTType {
        switch self {
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        case .csv: return UTType.commaSeparatedText
        }
    }

    /// The save panel's format popup entry.
    public var menuTitle: String { "\(displayName) (.\(fileExtension))" }
}

/// One annotation in an export, before replies are threaded under their parents.
///
/// A single shape covers both sources the reader knows: the sidecar annotations it created
/// (`source == .sidecar`) and the annotations the PDF itself carries (`source == .pdf`). The
/// source is part of the exported document so a reader can tell the two apart — the PDF's
/// annotations are not the reader's work, and the sidecar's are not in the PDF.
public struct AnnotationExportEntry: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        case sidecar
        case pdf

        /// How the Markdown export names the source.
        public var markdownDescription: String {
            switch self {
            case .sidecar: return "LyraReader annotation sidecar (saved beside the PDF)"
            case .pdf: return "PDF annotation (read from the file)"
            }
        }
    }

    /// Stable identity: the sidecar UUID, or the PDF annotation's own id (`nm:<NM>` or a
    /// fingerprint). It is what the CSV's `id` column carries and what replies name.
    public let id: String
    /// Zero-based page index.
    public let page: Int
    /// The raw kind: `highlight`, `underline`, `strikeout`, `squiggly`, `text`, `freeText`, …
    public let kind: String
    /// `#RRGGBBAA`, or `nil` when the file carries no colour.
    public let colorHex: String?
    /// The author the source names, or `nil` when it names none.
    public let author: String?
    /// Creation time for a sidecar entry; the file's `/M` for a PDF annotation (the closest
    /// thing a PDF has to a creation time — it stores no `/CreationDate` for annotations).
    public let date: Date?
    /// The text the annotation covers, when the source has one.
    public let quote: String?
    /// The annotation's own text (a sidecar note, `/Contents` for a PDF annotation).
    public let comment: String?
    public let source: Source
    /// The parent this annotation answers through `/IRT`, when it is a reply.
    public let parentID: String?
    /// Page-local vertical position (points, 0 at the top), used only for document order.
    public let yPt: CGFloat

    public init(
        id: String,
        page: Int,
        kind: String,
        colorHex: String? = nil,
        author: String? = nil,
        date: Date? = nil,
        quote: String? = nil,
        comment: String? = nil,
        source: Source,
        parentID: String? = nil,
        yPt: CGFloat = 0
    ) {
        self.id = id
        self.page = page
        self.kind = kind
        self.colorHex = colorHex
        self.author = author
        self.date = date
        self.quote = quote
        self.comment = comment
        self.source = source
        self.parentID = parentID
        self.yPt = yPt
    }
}

/// One annotation in export order, with the reply depth and the page section it belongs to.
public struct AnnotationExportRow: Equatable, Sendable {
    public let entry: AnnotationExportEntry
    /// 0 for a top-level annotation, 1 for its reply, 2 for a reply to that reply, …
    public let depth: Int
    /// The page of the thread's root. A cross-page reply keeps its own page in
    /// `entry.page` but stays with its parent's section, exactly as the sidebar shows it.
    public let sectionPage: Int
}

/// A complete, ordered export: the document facts for the heading plus every annotation row.
///
/// The initializer is where document order is applied, so both renderers share one ordering:
/// top-level annotations by **page, then vertical position, then creation time**; replies
/// immediately under their parent, recursively, ordered by creation time. A page with no
/// annotations contributes no row.
public struct AnnotationExportDocument: Equatable {
    public let fileName: String
    public let pageCount: Int
    public let exportedAt: Date
    public let timeZone: TimeZone
    public let rows: [AnnotationExportRow]

    public init(
        fileName: String,
        pageCount: Int,
        exportedAt: Date = Date(),
        timeZone: TimeZone = .current,
        entries: [AnnotationExportEntry]
    ) {
        self.fileName = fileName
        self.pageCount = max(0, pageCount)
        self.exportedAt = exportedAt
        self.timeZone = timeZone
        self.rows = Self.threadedRows(entries)
    }

    private struct IndexedEntry {
        let entry: AnnotationExportEntry
        /// Position in the caller's array, used as the final, stable tie-break.
        let sequence: Int
    }

    private static func threadedRows(_ entries: [AnnotationExportEntry]) -> [AnnotationExportRow] {
        let nodes = entries.enumerated().map {
            IndexedEntry(entry: $0.element, sequence: $0.offset)
        }
        guard !nodes.isEmpty else { return [] }

        var indexByID: [String: Int] = [:]
        for (index, node) in nodes.enumerated() where indexByID[node.entry.id] == nil {
            indexByID[node.entry.id] = index
        }

        // A parent link counts only when the parent is present and the chain cannot loop back
        // on itself. Missing parents (a `/IRT` that names an annotation the reader does not
        // list, such as a `/Link`) and malformed cycles leave the annotation at the top level
        // rather than dropping it: losing an annotation would be worse than losing its
        // indentation.
        var parentOf: [Int: Int] = [:]
        for index in nodes.indices {
            guard let parentID = nodes[index].entry.parentID,
                  let parent = indexByID[parentID],
                  parent != index
            else { continue }

            var seen: Set<Int> = [index]
            var current: Int? = parent
            var valid = true
            while let candidate = current {
                guard seen.insert(candidate).inserted else {
                    valid = false
                    break
                }
                if let nextID = nodes[candidate].entry.parentID,
                   let next = indexByID[nextID] {
                    current = next
                } else {
                    current = nil
                }
            }
            if valid { parentOf[index] = parent }
        }

        var children: [Int: [Int]] = [:]
        for (child, parent) in parentOf {
            children[parent, default: []].append(child)
        }
        for parent in Array(children.keys) {
            children[parent]?.sort { creationOrder(nodes[$0], nodes[$1]) }
        }

        let roots = nodes.indices
            .filter { parentOf[$0] == nil }
            .sorted { documentOrder(nodes[$0], nodes[$1]) }

        var rows: [AnnotationExportRow] = []
        var visited: Set<Int> = []

        func append(_ index: Int, depth: Int, sectionPage: Int) {
            guard visited.insert(index).inserted else { return }
            rows.append(AnnotationExportRow(
                entry: nodes[index].entry,
                depth: depth,
                sectionPage: sectionPage
            ))
            for child in children[index] ?? [] {
                append(child, depth: depth + 1, sectionPage: sectionPage)
            }
        }

        for root in roots {
            append(root, depth: 0, sectionPage: nodes[root].entry.page)
        }
        return rows
    }

    private static func verticalPosition(_ entry: AnnotationExportEntry) -> CGFloat {
        entry.yPt.isFinite ? entry.yPt : .greatestFiniteMagnitude
    }

    private static func creationOrder(_ first: IndexedEntry, _ second: IndexedEntry) -> Bool {
        let firstDate = first.entry.date ?? .distantFuture
        let secondDate = second.entry.date ?? .distantFuture
        if firstDate != secondDate { return firstDate < secondDate }
        return first.sequence < second.sequence
    }

    private static func documentOrder(_ first: IndexedEntry, _ second: IndexedEntry) -> Bool {
        if first.entry.page != second.entry.page { return first.entry.page < second.entry.page }
        let firstY = verticalPosition(first.entry)
        let secondY = verticalPosition(second.entry)
        if firstY != secondY { return firstY < secondY }
        return creationOrder(first, second)
    }
}

/// Rendering, file naming and the small pieces of text recovery the export needs.
public enum AnnotationExport {
    /// RFC 4180's column order. Values are 1-based pages; `reply_to` is empty for a top-level
    /// annotation and names the immediate parent for a reply.
    public static let csvHeader = [
        "page", "type", "author", "date", "colour", "quote", "comment", "reply_to", "id", "source",
    ]

    public static func render(_ document: AnnotationExportDocument, format: AnnotationExportFormat) -> String {
        switch format {
        case .markdown: return markdown(document)
        case .csv: return csv(document)
        }
    }

    /// The Markdown document: one heading for the export, then one section per page that has
    /// annotations. Every annotation carries type, colour, author, date and source, then its
    /// quote and comment when it has them. Replies are headings one level deeper than their
    /// parent, so the document's outline is the review thread.
    public static func markdown(_ document: AnnotationExportDocument) -> String {
        var blocks: [String] = [
            """
            # Annotations — \(document.fileName)

            - **Pages:** \(document.pageCount)
            - **Annotations:** \(document.rows.count)
            - **Exported:** \(timestamp(document.exportedAt, timeZone: document.timeZone))
            """,
        ]

        var currentPage: Int?
        for row in document.rows {
            if row.sectionPage != currentPage {
                currentPage = row.sectionPage
                blocks.append("## Page \(row.sectionPage + 1)")
            }
            blocks.append(markdownBlock(row, document: document))
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// The CSV document: one header row and one row per annotation, in the same order as the
    /// Markdown. Fields use RFC 4180 quoting and rows are separated by CRLF.
    public static func csv(_ document: AnnotationExportDocument) -> String {
        var lines = [csvHeader.map(csvField).joined(separator: ",")]
        for row in document.rows {
            let entry = row.entry
            let fields = [
                String(entry.page + 1),
                entry.kind,
                entry.author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                entry.date.map { timestamp($0, timeZone: document.timeZone) } ?? "",
                entry.colorHex ?? "",
                normalized(entry.quote) ?? "",
                normalized(entry.comment) ?? "",
                entry.parentID ?? "",
                entry.id,
                entry.source.rawValue,
            ]
            lines.append(fields.map(csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// The name offered in the save panel: `<name> (annotations).md` or `.csv`.
    ///
    /// The extension is removed from the document name, not appended to it, so `paper.v2.pdf`
    /// keeps the version in the stem rather than becoming a file called `paper.v2.pdf.md`.
    public static func suggestedFilename(documentURL: URL?, format: AnnotationExportFormat) -> String {
        let stem = documentURL?.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = stem.isEmpty ? "Document" : stem
        return "\(base) (annotations).\(format.fileExtension)"
    }

    /// `D:YYYYMMDDHHmmSSOHH'mm'` as a `Date`.
    ///
    /// A PDF annotation stores only `/M` (modified), not a creation date, so this is the closest
    /// ordering key the file offers. An absent or unreadable value returns `nil` and sorts after
    /// dated annotations, without inventing a time. A date with no zone is read as UTC, which is
    /// the same convention `DocumentAnnotation.displayDate` already uses.
    public static func date(fromPDFDate value: String?) -> Date? {
        guard var text = value else { return nil }
        if text.hasPrefix("D:") { text.removeFirst(2) }
        guard text.count >= 14 else { return nil }
        let stamp = String(text.prefix(14))
        guard stamp.allSatisfy(\.isNumber) else { return nil }

        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyyMMddHHmmss"
        guard let base = parser.date(from: stamp) else { return nil }

        let remainder = text.dropFirst(14)
        guard let sign = remainder.first, sign == "+" || sign == "-" else { return base }
        let digits = remainder.dropFirst().filter(\.isNumber)
        guard digits.count >= 2, let hours = Int(digits.prefix(2)) else { return base }
        let minutes = digits.count >= 4 ? Int(digits.dropFirst(2).prefix(2)) ?? 0 : 0
        // `+02'00'` means the clock reads UTC+2, so the instant is two hours earlier than the
        // same digits read as UTC. A negative offset is the other way round.
        let offset = TimeInterval(hours * 3600 + minutes * 60) * (sign == "+" ? -1 : 1)
        return base.addingTimeInterval(offset)
    }

    /// A quote recovered from the page's text layer for a box on that page.
    ///
    /// This is used for annotations that came from the file: a PDF highlight stores geometry,
    /// not the text it covers, so the selection is recovered from the glyphs under its quads.
    /// Only markup annotations qualify; a sticky note's `/Rect` is its icon in the margin, and
    /// treating the nearest word as "quoted text" would invent a relationship the file does not
    /// state.
    public static func quote(for annotation: DocumentAnnotation, in page: TextPage?) -> String? {
        guard annotation.isMarkup, let page else { return nil }
        var lowerBound: Int?
        var upperBound: Int?
        for box in annotation.boxes {
            let rect = CGRect(x: box.xPt, y: box.yPt, width: box.widthPt, height: box.heightPt)
            guard rect.width > 0, rect.height > 0,
                  let range = page.characterRange(in: rect) else { continue }
            lowerBound = min(lowerBound ?? range.lowerBound, range.lowerBound)
            upperBound = max(upperBound ?? range.upperBound, range.upperBound)
        }
        guard let lowerBound, let upperBound, lowerBound <= upperBound,
              let raw = text(in: page, range: lowerBound...upperBound)
        else { return nil }
        return normalized(raw)
    }

    /// The characters in `range`, decoded the same way the reader's copy command decodes them.
    public static func text(in page: TextPage, range: ClosedRange<Int>) -> String? {
        guard range.lowerBound >= 0, range.upperBound < page.chars.count else { return nil }
        let scalars = page.chars[range].compactMap { Unicode.Scalar($0.unicode) }
        guard !scalars.isEmpty else { return nil }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Normalizes line endings and trims surrounding blank space; whitespace-only becomes nil.
    ///
    /// Internal newlines are kept: a quote that spans several selected lines is one blockquote
    /// with one line per source line, not a single truncated line.
    public static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let newlines = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmed = newlines.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// ISO 8601 in the export's time zone: `2026-10-17T17:40:00Z`, or an offset when local.
    public static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: - Markdown blocks

    private static func markdownBlock(
        _ row: AnnotationExportRow,
        document: AnnotationExportDocument
    ) -> String {
        let entry = row.entry
        let headingLevel = min(6, 3 + row.depth)
        let heading = String(repeating: "#", count: headingLevel)
        let replyLabel = entry.parentID == nil ? "" : "Reply · "

        var metadata = [
            "- **Colour:** \(entry.colorHex ?? "not set in the file")",
            "- **Author:** \(markdownAuthor(entry.author))",
            "- **Date:** \(entry.date.map { timestamp($0, timeZone: document.timeZone) } ?? "not recorded")",
            "- **Source:** \(entry.source.markdownDescription)",
        ]
        if let parentID = entry.parentID {
            metadata.append("- **In reply to:** `\(parentID)`")
        }
        if entry.page != row.sectionPage {
            metadata.append("- **Page:** \(entry.page + 1) (the reply is on a different page)")
        }

        var blocks = [
            "\(heading) \(replyLabel)\(markdownKind(entry.kind))",
            metadata.joined(separator: "\n"),
        ]
        if let quote = normalized(entry.quote) {
            blocks.append("**Quote**\n\n" + blockquote(quote))
        }
        if let comment = normalized(entry.comment) {
            blocks.append("**Comment**\n\n" + comment)
        }
        return blocks.joined(separator: "\n\n")
    }

    /// The reader's name for a kind, for Markdown headings. CSV keeps the raw kind instead.
    private static func markdownKind(_ kind: String) -> String {
        switch kind {
        case "highlight": return "Highlight"
        case "underline": return "Underline"
        case "strikeout": return "Strikethrough"
        case "squiggly": return "Squiggly"
        case "text": return "Sticky note"
        case "freeText": return "Free text"
        default:
            guard let first = kind.first else { return "Annotation" }
            return first.uppercased() + String(kind.dropFirst())
        }
    }

    private static func markdownAuthor(_ author: String?) -> String {
        guard let trimmed = author?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return "Unknown" }
        return trimmed
    }

    /// Every line prefixed with `>`, including blank ones, so a long quote stays one blockquote.
    private static func blockquote(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
    }

    // MARK: - CSV

    private static func csvField(_ value: String) -> String {
        let needsQuoting = value.contains { character in
            character == "," || character == "\"" || character == "\n" || character == "\r"
        }
        guard needsQuoting else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// The save panel's "Format:" popup.
///
/// Kept as an object because `NSPopUpButton` reports through a target/action, and the panel's
/// suggested file name has to change with the format. The controller is retained by the caller
/// for as long as `runModal()` is on screen; the panel itself retains only its accessory view.
@MainActor
final class AnnotationExportSavePanelAccessory: NSObject {
    let view: NSView
    private let panel: NSSavePanel
    private let documentURL: URL?
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var previousSuggestion: String?
    private(set) var format: AnnotationExportFormat = .markdown

    init(panel: NSSavePanel, documentURL: URL?) {
        self.panel = panel
        self.documentURL = documentURL
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 34))

        let label = NSTextField(labelWithString: "Format:")
        label.frame = NSRect(x: 20, y: 9, width: 56, height: 17)
        self.popup.frame = NSRect(x: 80, y: 4, width: 250, height: 26)
        self.view.addSubview(label)
        self.view.addSubview(self.popup)

        super.init()

        for format in AnnotationExportFormat.allCases {
            self.popup.addItem(withTitle: format.menuTitle)
        }
        self.popup.target = self
        self.popup.action = #selector(formatChanged(_:))
    }

    /// Applies `format` to the panel and keeps the suggested name in step with it.
    ///
    /// A name the reader has edited keeps its stem and only has its extension changed; a name
    /// that is still the previous suggestion is replaced wholesale, so the recommendation for
    /// the new format is visible.
    func apply(format newFormat: AnnotationExportFormat) {
        format = newFormat
        popup.selectItem(at: AnnotationExportFormat.allCases.firstIndex(of: newFormat) ?? 0)
        panel.allowedContentTypes = [newFormat.contentType]

        let suggestion = AnnotationExport.suggestedFilename(
            documentURL: documentURL,
            format: newFormat
        )
        let current = panel.nameFieldStringValue
        if current.isEmpty || current == previousSuggestion {
            panel.nameFieldStringValue = suggestion
        } else {
            let editedStem = (current as NSString).deletingPathExtension
            panel.nameFieldStringValue = editedStem.isEmpty
                ? suggestion
                : "\(editedStem).\(newFormat.fileExtension)"
        }
        previousSuggestion = suggestion
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard AnnotationExportFormat.allCases.indices.contains(index) else { return }
        apply(format: AnnotationExportFormat.allCases[index])
    }
}
