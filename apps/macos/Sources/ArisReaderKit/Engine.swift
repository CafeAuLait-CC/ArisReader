import ArisReaderBindings
import CoreGraphics
import Foundation

/// Snapshot of a document the shell has opened.
///
/// Deliberately *not* called `DocumentSummary`: the UniFFI-generated control plane
/// already exports a record with that name, and this type carries the extra UI state
/// (stable identity, display title) on top of it.
public struct LoadedDocument: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var pageCount: Int
    public var url: URL?
    /// First page size in points, already accounting for `/Rotate`.
    public var firstPageSize: CGSize
    /// Which PDF backend produced this snapshot (shown in diagnostics).
    public var backend: String

    public init(
        id: UUID = UUID(),
        title: String,
        pageCount: Int,
        url: URL? = nil,
        firstPageSize: CGSize = .zero,
        backend: String = "unknown"
    ) {
        self.id = id
        self.title = title
        self.pageCount = pageCount
        self.url = url
        self.firstPageSize = firstPageSize
        self.backend = backend
    }
}

/// A rasterized page on its way to the GPU.
///
/// `bgra` is exactly what PDFium produced and exactly what the GPU layer expects, so
/// nothing converts it on the way (`docs/03-rendering.md` §5).
public struct PageImage: Sendable {
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Page size in points (already rotated); the canvas scales it by the zoom factor.
    public let pointSize: CGSize
    public let bgra: Data
    /// Monotonic id, so the canvas can tell a new rasterization from a repeated one.
    public let generation: UInt64

    public init(
        pixelWidth: Int,
        pixelHeight: Int,
        pointSize: CGSize,
        bgra: Data,
        generation: UInt64
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pointSize = pointSize
        self.bgra = bgra
        self.generation = generation
    }
}

extension PageImage {
    /// High-quality reduction preserves fractional coverage of hairlines. Rendering
    /// directly at thumbnail resolution instead rounds those strokes up to dark pixels.
    public func downsampled(toWidth width: Int) -> PageImage {
        guard width > 0, width < pixelWidth, pixelHeight > 0 else { return self }
        let height = max(1, Int((CGFloat(pixelHeight) * CGFloat(width) / CGFloat(pixelWidth)).rounded()))
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: bgra as CFData),
              let source = CGImage(width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue)
        else { return self }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let bytes = context.data else { return self }
        return PageImage(pixelWidth: width, pixelHeight: height, pointSize: pointSize,
                         bgra: Data(bytes: bytes, count: width * height * 4), generation: generation)
    }
}

/// Where one page sits in the scrolling content.
///
/// Content space uses PDF points with the origin at the top-left of the first page and Y
/// growing downwards (view space). The canvas multiplies by zoom × backing scale when it
/// draws, so nothing here depends on the display.
public struct PagePlacement: Equatable, Sendable {
    public let index: Int
    public let topPt: CGFloat
    public let leftPt: CGFloat
    public let widthPt: CGFloat
    public let heightPt: CGFloat

    public init(index: Int, topPt: CGFloat, leftPt: CGFloat, widthPt: CGFloat, heightPt: CGFloat) {
        self.index = index
        self.topPt = topPt
        self.leftPt = leftPt
        self.widthPt = widthPt
        self.heightPt = heightPt
    }
}

/// One character of a page's text layer, boxed in view space (points, top-left origin).
public struct TextChar: Sendable {
    public let unicode: UInt32
    public let xPt: CGFloat
    public let yPt: CGFloat
    public let widthPt: CGFloat
    public let heightPt: CGFloat

    public init(unicode: UInt32, xPt: CGFloat, yPt: CGFloat, widthPt: CGFloat, heightPt: CGFloat) {
        self.unicode = unicode
        self.xPt = xPt
        self.yPt = yPt
        self.widthPt = widthPt
        self.heightPt = heightPt
    }
}

/// A page's text layer.
public struct TextPage: Sendable {
    public let page: Int
    public let chars: [TextChar]
    public let text: String
    public let hasUnicodeMapError: Bool
    private let selectionLines: [SelectionLine]

    public init(page: Int, chars: [TextChar], text: String, hasUnicodeMapError: Bool) {
        self.page = page
        self.chars = chars
        self.text = text
        self.hasUnicodeMapError = hasUnicodeMapError
        self.selectionLines = SelectionLine.build(chars)
    }

    /// The text line touched by an annotation, excluding a separate line-number gutter.
    public func lineBounds(overlapping region: CGRect) -> CGRect? {
        selectionLines.map(\.bounds).filter { $0.intersects(region) }.max {
            let a = $0.intersection(region)
            let b = $1.intersection(region)
            return a.width * a.height < b.width * b.height
        }
    }

    /// Resolve the visual line before resolving x. Ink-free spaces must never make
    /// a character on a neighbouring line win merely because its x is closer.
    public func characterIndex(at point: CGPoint, extendingSelection: Bool = false) -> Int? {
        func distance(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            max(low - value, value - high, 0)
        }
        // Find the horizontal text column first. A loose box in a distant
        // line-number gutter may extend into the body's interline gap; its exact
        // y hit must not beat the body only a fraction of a point away.
        guard let column = selectionLines.min(by: { a, b in
            func squaredDistance(_ rect: CGRect) -> CGFloat {
                let x = distance(point.x, rect.minX, rect.maxX)
                let y = distance(point.y, rect.minY, rect.maxY)
                return x * x + y * y
            }
            return squaredDistance(a.bounds) < squaredDistance(b.bounds)
        }) else { return nil }
        let columnLines = selectionLines.filter {
            min($0.bounds.maxX, column.bounds.maxX) > max($0.bounds.minX, column.bounds.minX)
        }
        guard let line = columnLines.min(by: { a, b in
            let ay = distance(point.y, a.bounds.minY, a.bounds.maxY)
            let by = distance(point.y, b.bounds.minY, b.bounds.maxY)
            if ay != by { return ay < by }
            let ax = distance(point.x, a.bounds.minX, a.bounds.maxX)
            let bx = distance(point.x, b.bounds.minX, b.bounds.maxX)
            if ax != bx { return ax < bx }
            return abs(a.bounds.midY - point.y) < abs(b.bounds.midY - point.y)
        }) else { return nil }
        if extendingSelection, point.y < line.bounds.minY || point.y > line.bounds.maxY {
            // Use visual neighbors within the column, independent of the order in
            // which the PDF producer emitted its text objects.
            let upper = columnLines.filter { $0.bounds.maxY < point.y }
                .max { $0.bounds.maxY < $1.bounds.maxY }
            let lower = columnLines.filter { $0.bounds.minY > point.y }
                .min { $0.bounds.minY < $1.bounds.minY }
            if let upper, let lower,
               min(upper.bounds.maxX, lower.bounds.maxX) > max(upper.bounds.minX, lower.bounds.minX),
               let last = upper.stops.last, let first = lower.stops.first,
               last.index < first.index {
                return max(last.index, first.index - 1)
            }
        }
        guard abs(line.bounds.midY - point.y) < max(line.bounds.height * 1.5, 14) else { return nil }
        return line.stops.min { a, b in
            let ad = distance(point.x, a.rect.minX, a.rect.maxX)
            let bd = distance(point.x, b.rect.minX, b.rect.maxX)
            if ad != bd { return ad < bd }
            return abs(a.rect.midX - point.x) < abs(b.rect.midX - point.x)
        }?.index
    }
}

private struct SelectionLine: Sendable {
    var bounds: CGRect
    var stops: [(index: Int, rect: CGRect)]

    static func build(_ chars: [TextChar]) -> [SelectionLine] {
        var lines: [SelectionLine] = []
        var current: SelectionLine?
        for (index, char) in chars.enumerated() {
            if char.unicode == 10 || char.unicode == 13 {
                if let current { lines.append(current) }
                current = nil
                continue
            }
            // PDFium may give whitespace a zero box or an unrelated y coordinate.
            if Unicode.Scalar(char.unicode).map({ CharacterSet.whitespaces.contains($0) }) == true { continue }
            let rect = CGRect(x: char.xPt, y: char.yPt, width: char.widthPt, height: char.heightPt)
            guard rect.width > 0, rect.height > 0 else { continue }
            if var line = current {
                let overlap = min(line.bounds.maxY, rect.maxY) - max(line.bounds.minY, rect.minY)
                if overlap >= min(line.bounds.height, rect.height) * 0.35 {
                    // Interpolate missing space boxes between neighbouring ink boxes.
                    if let previous = line.stops.last, previous.index + 1 < index {
                        let gaps = (previous.index + 1)..<index
                        let width = max(0, rect.minX - previous.rect.maxX) / CGFloat(gaps.count)
                        for (offset, gapIndex) in gaps.enumerated() where Unicode.Scalar(chars[gapIndex].unicode).map({ CharacterSet.whitespaces.contains($0) }) == true {
                            line.stops.append((gapIndex, CGRect(x: previous.rect.maxX + CGFloat(offset) * width,
                                y: line.bounds.minY, width: width, height: line.bounds.height)))
                        }
                    }
                    line.bounds = line.bounds.union(rect)
                    line.stops.append((index, rect))
                    current = line
                    continue
                }
                lines.append(line)
            }
            current = SelectionLine(bounds: rect, stops: [(index, rect)])
        }
        if let current { lines.append(current) }
        return lines
    }
}

/// One link: a clickable box in view space plus where it leads.
public struct DocumentLink: Sendable {
    public let xPt: CGFloat
    public let yPt: CGFloat
    public let widthPt: CGFloat
    public let heightPt: CGFloat
    /// External URL, when this is a URI link.
    public let uri: String?
    /// Internal target page (0-based), when this is a document jump.
    public let page: Int?
    /// Region of the target page the citation points at (`/FitR`), in view space.
    public let region: CGRect?
}

/// A citation in the body text, boxed in view space.
public struct Citation: Sendable {
    public let page: Int
    public let text: String
    public let labels: [String]
    public let xPt: CGFloat
    public let yPt: CGFloat
    public let widthPt: CGFloat
    public let heightPt: CGFloat
}

/// One entry of the reference list, with the box it occupies on its page.
public struct Reference: Sendable {
    public let label: String
    public let text: String
    public let page: Int
    public let xPt: CGFloat
    public let yPt: CGFloat
    public let widthPt: CGFloat
    public let heightPt: CGFloat
}

/// Where one metadata field came from.
public enum MetadataFieldSource: Equatable, Sendable {
    /// No value; nothing produced it.
    case absent
    /// The document's XMP metadata stream.
    case xmp
    /// The PDF information dictionary (`/Title`, `/Author`, …).
    case info
    /// A layout guess on page one (title block, author block).
    case firstPage
    /// Page-one header/footer furniture (venue, copyright year).
    case pageFurniture
    /// An identifier found in page-one text (DOI, arXiv id). Found, not guessed.
    case text
    /// The year encoded in an arXiv identifier's `YYMM` prefix.
    case arxivDerived
    /// The reader corrected the value in the panel.
    case edited

    public init(_ kind: MetadataSourceKind) {
        switch kind {
        case .absent: self = .absent
        case .xmp: self = .xmp
        case .info: self = .info
        case .firstPage: self = .firstPage
        case .pageFurniture: self = .pageFurniture
        case .text: self = .text
        case .arxivDerived: self = .arxivDerived
        case .edited: self = .edited
        }
    }

    /// Human label for the badge next to a field.
    public var label: String {
        switch self {
        case .absent: return "no source"
        case .xmp: return "XMP"
        case .info: return "PDF info"
        case .firstPage: return "Page 1 guess"
        case .pageFurniture: return "Page 1 furniture guess"
        case .text: return "Found on page 1"
        case .arxivDerived: return "From arXiv id"
        case .edited: return "Edited"
        }
    }

    /// Whether the value is a guess the reader should check.
    public var isGuessed: Bool {
        switch self {
        case .firstPage, .pageFurniture, .arxivDerived: return true
        case .absent, .xmp, .info, .text, .edited: return false
        }
    }

    /// Whether the value came from the document's own description of itself.
    public var isEmbedded: Bool {
        switch self {
        case .xmp, .info: return true
        case .absent, .firstPage, .pageFurniture, .text, .arxivDerived, .edited: return false
        }
    }
}

/// One metadata field: its values and the source that produced them.
public struct MetadataField: Equatable, Sendable {
    public var values: [String]
    public var source: MetadataFieldSource
    /// The source as the engine worded it; for an edited field the shell says "Edited".
    public var sourceLabel: String
    public var guessed: Bool

    public init(
        values: [String] = [],
        source: MetadataFieldSource = .absent,
        sourceLabel: String = "no source",
        guessed: Bool = false
    ) {
        self.values = values
        self.source = source
        self.sourceLabel = sourceLabel
        self.guessed = guessed
    }

    public static let empty = MetadataField()

    public var isEmpty: Bool { values.isEmpty }
    public var first: String { values.first ?? "" }
    /// Authors are one field in the panel but several values in the model.
    public var text: String { values.joined(separator: "; ") }

    public mutating func markEdited(value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        values = trimmed.isEmpty ? [] : [trimmed]
        source = .edited
        sourceLabel = "Edited"
        guessed = false
    }

    public mutating func markEdited(values: [String]) {
        let cleaned = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.values = cleaned
        source = .edited
        sourceLabel = "Edited"
        guessed = false
    }
}

/// What the metadata panel shows for the open document.
public struct DocumentMetadata: Equatable, Sendable {
    public var title: MetadataField
    public var authors: MetadataField
    public var venue: MetadataField
    public var year: MetadataField
    public var doi: MetadataField
    public var arxivID: MetadataField
    /// The BibTeX the engine generated from exactly these values when the document opened.
    public var bibtex: String

    public static let empty = DocumentMetadata(
        title: .empty,
        authors: .empty,
        venue: .empty,
        year: .empty,
        doi: .empty,
        arxivID: .empty,
        bibtex: ""
    )

    public func field(_ key: MetadataFieldKey) -> MetadataField {
        switch key {
        case .title: return title
        case .authors: return authors
        case .venue: return venue
        case .year: return year
        case .doi: return doi
        case .arxivID: return arxivID
        }
    }

    public var isEmpty: Bool {
        [title, authors, venue, year, doi, arxivID].allSatisfy(\.isEmpty)
    }
}

/// The fields the panel lets the reader edit, in display order.
public enum MetadataFieldKey: String, CaseIterable, Sendable {
    case title
    case authors
    case venue
    case year
    case doi
    case arxivID

    public var label: String {
        switch self {
        case .title: return "Title"
        case .authors: return "Authors"
        case .venue: return "Venue"
        case .year: return "Year"
        case .doi: return "DOI"
        case .arxivID: return "arXiv ID"
        }
    }

    public var prompt: String {
        switch self {
        case .authors: return "One author per “;”"
        default: return "Not in this file"
        }
    }
}

/// Editable values sent back to the Rust BibTeX generator.
///
/// The draft is the single source of truth for the panel's text fields; `bibtex` is regenerated
/// by the engine after every edit, so the preview, the clipboard payload and the saved file are
/// the same string.
public struct MetadataDraft: Equatable, Sendable {
    public var title: String
    public var authors: [String]
    public var venue: String
    public var year: String
    public var doi: String
    public var arxivID: String
    public var bibtex: String

    public static let empty = MetadataDraft(
        title: "", authors: [], venue: "", year: "", doi: "", arxivID: "", bibtex: ""
    )

    public init(
        title: String,
        authors: [String],
        venue: String,
        year: String,
        doi: String,
        arxivID: String,
        bibtex: String
    ) {
        self.title = title
        self.authors = authors
        self.venue = venue
        self.year = year
        self.doi = doi
        self.arxivID = arxivID
        self.bibtex = bibtex
    }

    public init(metadata: DocumentMetadata) {
        self.init(
            title: metadata.title.first,
            authors: metadata.authors.values,
            venue: metadata.venue.first,
            year: metadata.year.first,
            doi: metadata.doi.first,
            arxivID: metadata.arxivID.first,
            bibtex: metadata.bibtex
        )
    }

    public func text(for key: MetadataFieldKey) -> String {
        switch key {
        case .title: return title
        case .authors: return authors.joined(separator: "; ")
        case .venue: return venue
        case .year: return year
        case .doi: return doi
        case .arxivID: return arxivID
        }
    }

    public func values(for key: MetadataFieldKey) -> [String] {
        switch key {
        case .title: return title.isEmpty ? [] : [title]
        case .authors: return authors
        case .venue: return venue.isEmpty ? [] : [venue]
        case .year: return year.isEmpty ? [] : [year]
        case .doi: return doi.isEmpty ? [] : [doi]
        case .arxivID: return arxivID.isEmpty ? [] : [arxivID]
        }
    }

    public mutating func setText(_ text: String, for key: MetadataFieldKey) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch key {
        case .title: title = trimmed
        case .authors:
            authors = text
                .split(whereSeparator: { $0 == ";" || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        case .venue: venue = trimmed
        case .year: year = trimmed
        case .doi: doi = trimmed
        case .arxivID: arxivID = trimmed
        }
    }
}

/// One figure or table caption, with the region of its page to preview.
///
/// The region is the caption box unioned with the artwork above it, or the caption box alone
/// when the figure is vector art — already the rectangle a click on `Figure 3` should show,
/// so the shell never derives it.
public struct Figure: Sendable {
    /// `Figure` or `Table`.
    public let kind: String
    /// The number as printed: `"3"`, `"12"`.
    public let label: String
    /// Page the caption lives on (0-based); the region is on that same page.
    public let page: Int
    /// Caption text after the label, shown in the preview panel.
    public let captionText: String
    public let xPt: CGFloat
    public let yPt: CGFloat
    public let widthPt: CGFloat
    public let heightPt: CGFloat

    /// `"Figure 3"` — how the caption is named in the text and in the panel's title bar.
    public var title: String { "\(kind) \(label)" }
}

/// What the reader decided to put on the page for one annotation.
///
/// Stated by the engine (`RawAnnotation::drawing` in Rust) and carried across the FFI, so the
/// canvas, the sidebar and the `aris-reader-cli annotations` dump all read one answer. The only
/// way an annotation the reader reports draws nothing is `.skipped`, and that case always carries
/// an `AnnotationSkipReason` — "in the sidebar but not on the page" is otherwise indistinguishable
/// from "we could not read it", which is the failure this whole classification exists to prevent.
public enum AnnotationDrawing: String, Sendable {
    /// One of the four text-markup kinds: a tinted box per `/QuadPoints` entry.
    case markup
    /// A `/Text` sticky note: its icon, filling `/Rect`.
    case noteIcon
    /// A `/FreeText` annotation: its own text, laid out in `/Rect`.
    case freeText
    /// Nothing, for the reason in `DocumentAnnotation.skipReason`.
    case skipped
}

/// Why a reported annotation is not drawn.
public enum AnnotationSkipReason: String, Sendable {
    /// The file's `/F` sets Hidden, Invisible or `/NoView`.
    case hidden
    /// `/Rect` has no area to draw in.
    case emptyRect = "empty-rect"
    /// A free-text annotation with no `/Contents`: there is no text to lay out.
    case emptyContents = "no-text"
    /// A subtype this build has no drawing rule for (`Ink`, `Stamp`, …).
    case unmodelled
}

/// An annotation that was **already inside the PDF**, in view space (points, top-left origin).
///
/// The counterpart of `AppState.Annotation`: that one is what this reader wrote and keeps in a
/// sidecar, this one is what the file itself carries — a highlight made in Preview, a colleague's
/// sticky note. `quads` is what markup annotations are really drawn from; `xPt`/`yPt`/`widthPt`/
/// `heightPt` is the `/Rect` and the fallback when a file has no quad points.
public struct DocumentAnnotation: Sendable, Identifiable, Equatable {
    /// The file's own identity for this annotation, carried from Rust: `nm:<NM>` when the
    /// annotation is named, otherwise a stable fingerprint. Two replies in a review PDF often
    /// share a page and a 1×1 pt `/Rect`, so this cannot be re-derived from the visible fields.
    public let id: String
    /// The [`id`] of the annotation this one answers through `/IRT`, when readable.
    public let parentID: String?
    /// Whether the file carries an `/IRT` entry. True even when `parentID` is nil because the
    /// parent could not be read; that is the orphan case, not "not a reply".
    public let isReply: Bool
    /// `highlight`, `underline`, `strikeout`, `squiggly`, `text`, `freeText`, or the PDF subtype
    /// name for anything this build does not model (`Ink`, `Stamp`, …).
    public let kind: String
    public let page: Int
    public let xPt: CGFloat
    public let yPt: CGFloat
    public let widthPt: CGFloat
    public let heightPt: CGFloat
    public let quads: [AnnotationQuadBox]
    /// `nil` when the file carries no `/C` (sticky notes usually do not).
    public let color: AnnotationColor?
    /// `/CA`; `nil` means the file did not state one, which reads as opaque.
    public let opacity: Double?
    /// `/BM`: `normal`, `multiply`, or the blend mode's own PDF name.
    public let blend: String
    public let contents: String?
    public let author: String?
    public let modified: String?
    /// The font size `/DA` states for this annotation's text, in points; `nil` when the file
    /// states none. Only free text has one in practice, and it is the size its text is drawn at.
    public let fontSizePt: CGFloat?
    /// `/Q`: `left`, `center` or `right`. Never anything else — the reader substitutes the PDF's
    /// own default (left) for an absent or unreadable value.
    public let alignment: String
    /// What to put on the page, as the **reader** classified it: `markup`, `noteIcon`, `freeText`
    /// or `skipped`. Read from the engine rather than re-derived here, so the sidebar, the canvas
    /// and the CLI dump cannot disagree about which annotations are supposed to appear.
    public let drawing: AnnotationDrawing
    /// Why nothing is drawn, when `drawing` is `.skipped`; `nil` for everything that is drawn.
    public let skipReason: AnnotationSkipReason?
    /// False when the file marks the annotation hidden/invisible/`/NoView`.
    public let visible: Bool

    /// True when this is one of the four text-markup kinds, i.e. what the reader draws a tinted
    /// box per quad for. A statement about *what the annotation is*; what is actually drawn is
    /// `drawing`, which is `markup` for exactly these four when the file does not hide them.
    public var isMarkup: Bool {
        ["highlight", "underline", "strikeout", "squiggly"].contains(kind)
    }

    /// True when the annotation is a note rather than markup: something to *read*, listed in the
    /// sidebar. `/Text` (a sticky note) and `/FreeText` are the two kinds whose `/Contents` is
    /// the whole point of the annotation.
    public var isNote: Bool {
        kind == "text" || kind == "freeText"
    }

    /// A text-markup comment needs a label as well as its highlight/underline geometry.
    public var hasInlineNote: Bool {
        visible && drawing == .markup
            && !(contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the annotation is composited with: the file's `/BM`, or — when the file states none,
    /// which is what Preview's highlights do — the blend that kind is drawn with (multiply for a
    /// highlight, underline or strikeout; PDFium composites them the same way). The reader decides
    /// it, because only it can see the file; this carries the answer to the canvas.
    public var quadBlend: QuadBlend { blend == "multiply" ? .multiply : .normal }

    /// The boxes to draw: the quad points when the file has them, its `/Rect` otherwise.
    public var boxes: [AnnotationQuadBox] {
        quads.isEmpty ? [AnnotationQuadBox(xPt: xPt, yPt: yPt, widthPt: widthPt, heightPt: heightPt)]
            : quads
    }
}

/// One box of an annotation in view space (a `/QuadPoints` quadrilateral, or its `/Rect`).
public struct AnnotationQuadBox: Sendable, Equatable {
    public let xPt: CGFloat
    public let yPt: CGFloat
    public let widthPt: CGFloat
    public let heightPt: CGFloat

    public init(xPt: CGFloat, yPt: CGFloat, widthPt: CGFloat, heightPt: CGFloat) {
        self.xPt = xPt
        self.yPt = yPt
        self.widthPt = widthPt
        self.heightPt = heightPt
    }
}

/// One annotation the shell asks the engine to write into a PDF.
///
/// Geometry is **view space at `zoom`** — exactly what the canvas draws — because that is the
/// shell's coordinate space. The engine converts it to page space once, using the page's own
/// crop box and rotation, so a highlight saved at 100% and one saved at 300% land in the same
/// place.
public struct AnnotationWriteRequest: Sendable, Equatable {
    /// What the annotation becomes in the PDF.
    public enum Kind: Sendable, Equatable {
        /// `/Subtype /Highlight`.
        case highlight
        /// `/Subtype /Underline`.
        case underline
        /// `/Subtype /Text`: a sticky note icon carrying the contents.
        case note
    }

    /// Written as `/NM`; the sidecar's UUID string, so a saved annotation can be recognised.
    public let id: String
    public let page: Int
    public let kind: Kind
    /// View-space box at `zoom`; for markup the union of `quads` is what is written as `/Rect`.
    public let rect: CGRect
    /// View-space `/QuadPoints` at `zoom`; empty only for a `.note`.
    public let quads: [CGRect]
    public let color: AnnotationColor
    /// `/CA`, 0…1. The shell's colour alpha carries it.
    public let opacity: Double
    public let contents: String
    public let author: String
    /// `/M`, already in PDF date form.
    public let modified: String

    public init(
        id: String,
        page: Int,
        kind: Kind,
        rect: CGRect,
        quads: [CGRect],
        color: AnnotationColor,
        opacity: Double,
        contents: String,
        author: String,
        modified: String
    ) {
        self.id = id
        self.page = page
        self.kind = kind
        self.rect = rect
        self.quads = quads
        self.color = color
        self.opacity = opacity
        self.contents = contents
        self.author = author
        self.modified = modified
    }
}

/// What a successful PDF write did.
public struct AnnotationWriteReport: Sendable, Equatable {
    public let destinationPath: String
    /// The `/NM` values written, so the sidecar can remove exactly those entries.
    public let writtenIDs: [String]
    public let appendedBytes: UInt64
    /// Present only for a replacement; the backup is verified byte-identical.
    public let backupPath: String?
    public let preexistingAnnotationCount: Int
    public let cleanedTemporaryFiles: Int
    public let sourceBytesPreserved: Bool
}

/// One page operation the reader asked for, in 0-based page numbers.
///
/// Every case is applied to a **copy**: the file on disk changes only through the explicit
/// `replaceOriginalWithPageEdits` command, which backs the original up first.
public enum PageEditOperation: Sendable, Equatable {
    /// Add `quarterTurns` × 90° clockwise.
    case rotate(pages: [Int], quarterTurns: Int)
    /// Set the rotation explicitly, one value per page (used to reset to the file's original).
    case setRotation(pages: [Int], quarterTurns: [Int])
    case delete(pages: [Int])
    /// Move the pages (as a block) to `destination`, an index in the list after removal.
    case move(pages: [Int], destination: Int)
    /// Insert a blank page at `index`, sized like its neighbour.
    case insertBlank(index: Int)
}

/// What a page operation wrote. The engine reopens its own output before returning, so a
/// successful report means the file was verified, not merely produced.
public struct PageOperationReport: Sendable, Equatable {
    public let destination: URL
    public let pageCount: Int
    /// `pageMap[old] = new` for pages that survived; `nil` for deleted/not-extracted pages.
    public let pageMap: [Int?]
    public let rotations: [Int]
    public let insertedPage: Int?
    public let backupPath: URL?
    public let outputBytes: UInt64
    public let cleanedTemporaryFiles: Int

    public init(
        destination: URL,
        pageCount: Int,
        pageMap: [Int?],
        rotations: [Int],
        insertedPage: Int?,
        backupPath: URL?,
        outputBytes: UInt64,
        cleanedTemporaryFiles: Int
    ) {
        self.destination = destination
        self.pageCount = pageCount
        self.pageMap = pageMap
        self.rotations = rotations
        self.insertedPage = insertedPage
        self.backupPath = backupPath
        self.outputBytes = outputBytes
        self.cleanedTemporaryFiles = cleanedTemporaryFiles
    }
}

/// A `Figure 3` / `Table 2` reference in a page's body text, boxed in view space.
public struct CaptionMention: Sendable {
    public let page: Int
    public let kind: String
    public let label: String
    /// First character of the mention inside its page's text layer.
    public let start: Int
    /// One past the last character of the mention.
    public let end: Int
    public let xPt: CGFloat
    public let yPt: CGFloat
    public let widthPt: CGFloat
    public let heightPt: CGFloat

    /// `"Figure 3"` — the key into `figures()`.
    public var title: String { "\(kind) \(label)" }
}

/// One outline entry, already flattened (nesting travels as `depth`).
public struct OutlineEntry: Sendable, Identifiable {
    public let title: String
    public let page: Int?
    public let depth: Int
    public var id: String { "\(depth):\(page ?? -1):\(title)" }
}

/// One search hit: a character range in a page's text layer.
public struct SearchHit: Sendable {
    public let page: Int
    public let start: Int
    public let end: Int
    public let snippet: String
}

/// One rasterized tile: what `rasterizeTile` hands back.
///
/// Tiles are the unit the shell thinks in once zoom passes what a single page texture can
/// hold; the canvas never learns the difference, because a tile is just another placement
/// with a bitmap.
public struct TileImage: Sendable {
    public let page: Int
    public let lod: UInt8
    public let tileX: Int
    public let tileY: Int
    public let sizePx: Int
    public let bgra: Data
    public let generation: UInt64

    public init(
        page: Int,
        lod: UInt8,
        tileX: Int,
        tileY: Int,
        sizePx: Int,
        bgra: Data,
        generation: UInt64
    ) {
        self.page = page
        self.lod = lod
        self.tileX = tileX
        self.tileY = tileY
        self.sizePx = sizePx
        self.bgra = bgra
        self.generation = generation
    }
    /// Edge tiles carry a square raster but must not paint past the PDF page bounds.
    /// Crop pixels rather than squeezing the entire square into a narrower placement.
    public func pageImage(pointSize: CGSize) -> PageImage {
        let scale = CGFloat(1 << Int(lod))
        let width = min(sizePx, max(1, Int(ceil(pointSize.width * scale))))
        let height = min(sizePx, max(1, Int(ceil(pointSize.height * scale))))
        var pixels = Data(capacity: width * height * 4)
        for row in 0..<height {
            let start = row * sizePx * 4
            pixels.append(bgra[start..<(start + width * 4)])
        }
        return PageImage(pixelWidth: width, pixelHeight: height, pointSize: pointSize,
                         bgra: pixels, generation: generation)
    }

}

/// How a quad is composited with what is already in the frame.
///
/// Mirrors Rust's `QuadBlend` and the `ARIS_BLEND_*` constants in the C ABI. A page is painted
/// over the background; a PDF highlight is normally stored with `/BM /Multiply` and has to be
/// multiplied into the page under it, or the same colour looks different from Preview.
public enum QuadBlend: UInt8, Sendable {
    case normal = 0
    case multiply = 1
}

/// How the reader arranges pages horizontally (T2.10).
///
/// A shell-level name for the two layouts the engine can compute. `facing` is the book
/// convention the Rust layout implements: page 1 alone, then 2–3, 4–5, … with odd (1-based)
/// pages on the right. It is deliberately not `single`: the reader's existing canvas is the
/// continuous one, and a facing pair changes what "visible pages" means.
public enum ReaderLayoutMode: String, CaseIterable, Identifiable, Sendable {
    case continuous
    case facing

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .continuous: return "Continuous"
        case .facing: return "Facing Pages"
        }
    }

    var rust: ReaderLayout {
        switch self {
        case .continuous: return .continuous
        case .facing: return .facing
        }
    }
}

/// One page ready to be drawn: where it goes and the bitmap that goes there.
public struct CanvasPage: Sendable {
    public let placement: PagePlacement
    public let image: PageImage
    /// How this quad composites with what is already in the frame.
    public let blend: QuadBlend

    public init(placement: PagePlacement, image: PageImage, blend: QuadBlend = .normal) {
        self.placement = placement
        self.image = image
        self.blend = blend
    }
}

/// Engine interface.
///
/// The UI depends only on this protocol, so the real engine (`RustEngine`, backed by the
/// UniFFI control plane) and the fallback (`MockEngine`) are interchangeable.
@MainActor
public protocol PDFEngine: AnyObject {
    func openDocument(at url: URL) throws -> LoadedDocument
    /// Rasterizes a page at `scale` (1.0 = 72 dpi, so pass zoom × backing scale).
    ///
    /// Asynchronous because it runs off the main thread: PDFium is not thread-safe, so
    /// implementations serialise calls, but the UI must never wait for them.
    func renderPage(_ page: Int, scale: CGFloat) async throws -> PageImage
    /// Rasterizes a sidebar thumbnail, with the file's own annotations burned in.
    ///
    /// Implementations that cannot do the annotated raster fall back to the plain page; the
    /// real engine overrides this so marks from another viewer appear in the strip.
    func renderThumbnail(_ page: Int, scale: CGFloat) async throws -> PageImage
    /// Rasterizes one tile of a page at a discrete LOD (`scale = 2^lod`).
    func rasterizeTile(
        page: Int,
        lod: UInt8,
        tileX: Int,
        tileY: Int,
        tileSize: Int
    ) async throws -> TileImage
    /// Extracts the text layer of a page (character boxes in view space).
    func textPage(_ page: Int) async throws -> TextPage
    /// Rasterizes one rectangle of a page, in view-space points.
    func rasterizeRegion(
        page: Int,
        scale: CGFloat,
        xPt: CGFloat,
        yPt: CGFloat,
        widthPt: CGFloat,
        heightPt: CGFloat
    ) async throws -> PageImage
    /// Links on a page, in view space (empty when the page has none).
    func links(_ page: Int) async throws -> [DocumentLink]
    /// Annotations the document **already carries** (highlights, notes, free text), from every
    /// page, in view space. Document-wide, so implementations cache it.
    func annotations() async throws -> [DocumentAnnotation]
    /// Writes `annotations` into a new PDF at `url`. Never touches the open document.
    func saveAnnotatedCopy(
        to url: URL,
        annotations: [AnnotationWriteRequest],
        zoom: CGFloat
    ) async throws -> AnnotationWriteReport
    /// Replaces the open document with one carrying `annotations`; the engine writes and verifies
    /// a backup first and refuses the replacement if the backup cannot be written.
    func replaceWithAnnotations(
        _ annotations: [AnnotationWriteRequest],
        zoom: CGFloat
    ) async throws -> AnnotationWriteReport
    /// The `/Rotate` of every page, in quarter turns (0–3).
    func pageRotations() async throws -> [Int]
    /// Applies a page operation to a copy of the open document and writes it to `destination`.
    /// The open document is not modified.
    func applyPageOperation(_ operation: PageEditOperation, to destination: URL) async throws -> PageOperationReport
    /// Extracts `pages` (0-based) from the open document into a new PDF.
    func extractPages(_ pages: [Int], to destination: URL) async throws -> PageOperationReport
    /// Publishes the current page-edit revision as a new file; the open document is untouched.
    func saveEditedCopy(to destination: URL) async throws -> PageOperationReport
    /// Replaces `original` with the current page-edit revision. Backup first, atomic rename.
    func replaceOriginalWithPageEdits(original: URL) async throws -> PageOperationReport
    /// Whether a previous save of `url` was interrupted, for the next open to report.
    func interruptedSaveNote(at url: URL) -> String?
    /// The name to offer for an annotated copy of `url`.
    func suggestedAnnotatedCopyURL(for url: URL) -> URL
    /// Citations in the body text of a page.
    func citations(_ page: Int) async throws -> [Citation]
    /// `Figure 3` / `Table 2` references in the body text of a page (the click targets).
    func captionMentions(page: Int) async throws -> [CaptionMention]
    /// Every figure and table caption in the document, each carrying the region to preview
    /// (empty when none can be found). Document-wide, so implementations cache it.
    func figures() async throws -> [Figure]
    /// The document's reference list (empty when none can be parsed).
    func references() async throws -> [Reference]
    /// Resolves a citation's labels to **every** reference entry they name, in label order
    /// (one implementation, in Rust; empty when nothing resolves).
    func resolveCitations(labels: [String]) async throws -> [Reference]
    /// Document outline (empty when the PDF has no bookmarks).
    func outline() async throws -> [OutlineEntry]
    /// Recognised metadata for the open document, with the source of every field.
    func metadata() async throws -> DocumentMetadata
    /// Generates the BibTeX entry from the values currently in the panel. One function in Rust
    /// backs the preview, the clipboard and the saved `.bib`, so they cannot disagree.
    func generateBibtex(_ draft: MetadataDraft) -> String
    /// Searches every page for `pattern` (ASCII case-insensitive), in reading order.
    func search(_ pattern: String, limit: Int) async throws -> [SearchHit]
    /// Total height of the scrolling content, in points.
    func contentHeightPt(gapPt: CGFloat) -> CGFloat
    /// Width of the widest page, in points (the canvas centres the content with it).
    func contentWidthPt(gapPt: CGFloat) -> CGFloat
    /// Pages overlapping the viewport, in reading order.
    func visiblePages(
        scrollYPt: CGFloat,
        viewportHeightPt: CGFloat,
        gapPt: CGFloat,
        marginPt: CGFloat
    ) -> [PagePlacement]
    /// Page under the viewport top (the "current page" for the HUD).
    func pageIndex(atScrollYPt scrollYPt: CGFloat, gapPt: CGFloat) -> Int
    /// Top edge of a page in content space (used by "go to page").
    func pageTopPt(_ index: Int, gapPt: CGFloat) -> CGFloat

    // Layout-aware variants (T2.10). Every one of them has a default below that forwards to
    // the continuous implementation, so the existing test doubles stay valid; only an engine
    // that can actually compute a facing layout overrides them.
    /// Total height of the scrolling content for `layout`.
    func contentHeightPt(gapPt: CGFloat, layout: ReaderLayoutMode) -> CGFloat
    /// Width of the content for `layout`: the widest page, or the whole spread.
    func contentWidthPt(gapPt: CGFloat, layout: ReaderLayoutMode) -> CGFloat
    /// Pages overlapping the viewport, in reading order, for `layout`.
    func visiblePages(
        scrollYPt: CGFloat,
        viewportHeightPt: CGFloat,
        gapPt: CGFloat,
        marginPt: CGFloat,
        layout: ReaderLayoutMode
    ) -> [PagePlacement]
    /// Page under the viewport top for `layout` (a spread names its left page).
    func pageIndex(atScrollYPt scrollYPt: CGFloat, gapPt: CGFloat, layout: ReaderLayoutMode) -> Int
    /// Top edge of a page in content space for `layout`.
    func pageTopPt(_ index: Int, gapPt: CGFloat, layout: ReaderLayoutMode) -> CGFloat
    /// Engine version plus backend description (About panel, diagnostics).
    var version: String { get }
}

public extension PDFEngine {
    /// A plain page raster for engines that have no annotation-burn-in path.
    ///
    /// Every test double keeps working through this default; only `RustEngine` overrides it,
    /// because only it can ask PDFium for `FPDF_ANNOT`.
    func renderThumbnail(_ page: Int, scale: CGFloat) async throws -> PageImage {
        try await renderPage(page, scale: scale)
    }

    /// Engines without a PDF writer refuse the operation instead of pretending to save.
    func saveAnnotatedCopy(
        to url: URL,
        annotations: [AnnotationWriteRequest],
        zoom: CGFloat
    ) async throws -> AnnotationWriteReport {
        throw NSError(
            domain: "Lyra",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "This engine cannot write annotations into a PDF"]
        )
    }

    func replaceWithAnnotations(
        _ annotations: [AnnotationWriteRequest],
        zoom: CGFloat
    ) async throws -> AnnotationWriteReport {
        throw NSError(
            domain: "Lyra",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "This engine cannot write annotations into a PDF"]
        )
    }

    func pageRotations() async throws -> [Int] {
        throw NSError(
            domain: "Lyra",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "This engine cannot edit pages"]
        )
    }

    func applyPageOperation(
        _ operation: PageEditOperation,
        to destination: URL
    ) async throws -> PageOperationReport {
        throw NSError(
            domain: "Lyra",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "This engine cannot edit pages"]
        )
    }

    func extractPages(_ pages: [Int], to destination: URL) async throws -> PageOperationReport {
        throw NSError(
            domain: "Lyra",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "This engine cannot extract pages"]
        )
    }

    func saveEditedCopy(to destination: URL) async throws -> PageOperationReport {
        throw NSError(
            domain: "Lyra",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "This engine cannot edit pages"]
        )
    }

    func replaceOriginalWithPageEdits(original: URL) async throws -> PageOperationReport {
        throw NSError(
            domain: "Lyra",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "This engine cannot edit pages"]
        )
    }

    func interruptedSaveNote(at url: URL) -> String? { nil }

    func suggestedAnnotatedCopyURL(for url: URL) -> URL {
        let stem = url.deletingPathExtension().lastPathComponent
        let extensionName = url.pathExtension.isEmpty ? "pdf" : url.pathExtension
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(stem) (annotated).\(extensionName)")
    }

    func contentHeightPt(gapPt: CGFloat, layout: ReaderLayoutMode) -> CGFloat {
        contentHeightPt(gapPt: gapPt)
    }

    func contentWidthPt(gapPt: CGFloat, layout: ReaderLayoutMode) -> CGFloat {
        contentWidthPt(gapPt: gapPt)
    }

    func visiblePages(
        scrollYPt: CGFloat,
        viewportHeightPt: CGFloat,
        gapPt: CGFloat,
        marginPt: CGFloat,
        layout: ReaderLayoutMode
    ) -> [PagePlacement] {
        visiblePages(
            scrollYPt: scrollYPt,
            viewportHeightPt: viewportHeightPt,
            gapPt: gapPt,
            marginPt: marginPt
        )
    }

    func pageIndex(atScrollYPt scrollYPt: CGFloat, gapPt: CGFloat, layout: ReaderLayoutMode) -> Int {
        pageIndex(atScrollYPt: scrollYPt, gapPt: gapPt)
    }

    func pageTopPt(_ index: Int, gapPt: CGFloat, layout: ReaderLayoutMode) -> CGFloat {
        pageTopPt(index, gapPt: gapPt)
    }
}

/// The real engine: the UniFFI control plane described in `docs/05-ffi.md`.
@MainActor
public final class RustEngine: PDFEngine {
    private let engine: ArisEngine
    /// The open document. One document per engine for now; the full document/session
    /// graph (several windows, shared documents, event streams) is M1 work.
    private var document: ArisDocument?
    private var generation: UInt64 = 0
    /// Serialises PDFium: the library is not thread-safe, so rasterizations run one at a
    /// time on a dedicated queue and never on the main thread.
    private let rasterQueue = DispatchQueue(label: "com.arisreader.raster", qos: .userInitiated)
    /// The document's caption index. `figures()` walks up to 120 pages, so it is fetched
    /// once per open document (the caption set cannot change while the file is open) and
    /// dropped by `openDocument` — the same lifetime the Rust side gives its own cache.
    private var figuresCache: [Figure]?
    private var documentEpoch: UInt64 = 0

    public init() throws {
        self.engine = try ArisEngine()
    }

    public var version: String {
        "\(engine.version()) · \(engine.backend()) · \(engine.rasterThreads()) raster threads"
    }

    public func openDocument(at url: URL) throws -> LoadedDocument {
        let opened = try engine.openDocument(path: url.path, password: nil)
        // A new document means a new caption index; keeping the old one would resolve a
        // `Figure 3` click to the previous paper's artwork.
        let firstPage = opened.pageCount() > 0 ? try opened.pageSizePt(page: 0) : nil

        document = opened
        documentEpoch &+= 1
        figuresCache = nil

        return LoadedDocument(
            title: url.deletingPathExtension().lastPathComponent,
            pageCount: Int(opened.pageCount()),
            url: url,
            firstPageSize: CGSize(
                width: firstPage?.widthPt ?? 0,
                height: firstPage?.heightPt ?? 0
            ),
            backend: engine.backend()
        )
    }

    public func renderPage(_ page: Int, scale: CGFloat) async throws -> PageImage {
        try await renderPage(page, scale: scale, withAnnotations: false)
    }

    /// A sidebar thumbnail: the same page raster, with the file's own annotations burned in.
    ///
    /// Only the thumbnail path asks for this. The canvas keeps `renderPage`'s plain raster and
    /// draws the marks itself, because those can be edited, filtered, and composited with the
    /// multiply pipeline; a thumbnail is a preview of where the file's marks are.
    public func renderThumbnail(_ page: Int, scale: CGFloat) async throws -> PageImage {
        try await renderPage(page, scale: scale, withAnnotations: true)
    }

    private func renderPage(
        _ page: Int,
        scale: CGFloat,
        withAnnotations: Bool
    ) async throws -> PageImage {
        guard let document else {
            throw NSError(
                domain: "Lyra",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No document is open"]
            )
        }

        generation += 1
        let generation = self.generation
        let requestedScale = Double(scale)

        return try await withCheckedThrowingContinuation { continuation in
            rasterQueue.async {
                let started = DispatchTime.now()
                do {
                    let bitmap = try withAnnotations
                        ? document.rasterizePageWithAnnotations(
                            page: UInt32(page),
                            scale: requestedScale
                        )
                        : document.rasterizePage(
                            page: UInt32(page),
                            scale: requestedScale
                        )
                    let milliseconds =
                        Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                    // Written to stderr (unbuffered) on purpose: it is how the
                    // "rasterisation really happens off the main thread" claim stays
                    // verifiable, including when the process is killed mid-run.
                    let line = String(
                        format: "aris-raster: page %d at %.2fx → %dx%d px in %.1f ms (main thread: %@)\n",
                        page,
                        bitmap.scaleUsed,
                        bitmap.widthPx,
                        bitmap.heightPx,
                        milliseconds,
                        Thread.isMainThread ? "yes" : "no"
                    )
                    FileHandle.standardError.write(Data(line.utf8))
                    continuation.resume(
                        returning: PageImage(
                            pixelWidth: Int(bitmap.widthPx),
                            pixelHeight: Int(bitmap.heightPx),
                            pointSize: CGSize(width: bitmap.widthPt, height: bitmap.heightPt),
                            bgra: bitmap.pixels,
                            generation: generation
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func rasterizeTile(
        page: Int,
        lod: UInt8,
        tileX: Int,
        tileY: Int,
        tileSize: Int
    ) async throws -> TileImage {
        guard let document else {
            throw NSError(
                domain: "Lyra",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No document is open"]
            )
        }

        generation += 1
        let generation = self.generation

        return try await withCheckedThrowingContinuation { continuation in
            rasterQueue.async {
                do {
                    let tile = try document.rasterizeTile(
                        page: UInt32(page),
                        lod: lod,
                        tileX: UInt32(tileX),
                        tileY: UInt32(tileY),
                        tileSize: UInt32(tileSize)
                    )
                    continuation.resume(
                        returning: TileImage(
                            page: page,
                            lod: lod,
                            tileX: tileX,
                            tileY: tileY,
                            sizePx: Int(tile.sizePx),
                            bgra: tile.pixels,
                            generation: generation
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func textPage(_ page: Int) async throws -> TextPage {
        guard let document else {
            throw NSError(
                domain: "Lyra",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No document is open"]
            )
        }

        return try await withCheckedThrowingContinuation { continuation in
            rasterQueue.async {
                do {
                    let extracted = try document.textPage(page: UInt32(page))
                    continuation.resume(
                        returning: TextPage(
                            page: page,
                            chars: extracted.chars.map { character in
                                TextChar(
                                    unicode: character.unicode,
                                    xPt: CGFloat(character.xPt),
                                    yPt: CGFloat(character.yPt),
                                    widthPt: CGFloat(character.widthPt),
                                    heightPt: CGFloat(character.heightPt)
                                )
                            },
                            text: extracted.text,
                            hasUnicodeMapError: extracted.hasUnicodeMapError
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func rasterizeRegion(
        page: Int,
        scale: CGFloat,
        xPt: CGFloat,
        yPt: CGFloat,
        widthPt: CGFloat,
        heightPt: CGFloat
    ) async throws -> PageImage {
        guard let document else {
            throw NSError(
                domain: "Lyra",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No document is open"]
            )
        }

        generation += 1
        let generation = self.generation

        return try await withCheckedThrowingContinuation { continuation in
            rasterQueue.async {
                do {
                    let bitmap = try document.rasterizeRegion(
                        page: UInt32(page),
                        scale: Double(scale),
                        xPt: Double(xPt),
                        yPt: Double(yPt),
                        widthPt: Double(widthPt),
                        heightPt: Double(heightPt)
                    )
                    continuation.resume(
                        returning: PageImage(
                            pixelWidth: Int(bitmap.widthPx),
                            pixelHeight: Int(bitmap.heightPx),
                            pointSize: CGSize(width: widthPt, height: heightPt),
                            bgra: bitmap.pixels,
                            generation: generation
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func links(_ page: Int) async throws -> [DocumentLink] {
        guard let document else { return [] }

        return try await withCheckedThrowingContinuation { continuation in
            rasterQueue.async {
                do {
                    let links = try document.links(page: UInt32(page))
                    continuation.resume(
                        returning: links.map { link in
                            DocumentLink(
                                xPt: CGFloat(link.xPt),
                                yPt: CGFloat(link.yPt),
                                widthPt: CGFloat(link.widthPt),
                                heightPt: CGFloat(link.heightPt),
                                uri: link.uri,
                                page: link.page.map { Int($0) },
                                region: link.region.map { region in
                                    CGRect(
                                        x: region.xPt,
                                        y: region.yPt,
                                        width: region.widthPt,
                                        height: region.heightPt
                                    )
                                }
                            )
                        }
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func citations(_ page: Int) async throws -> [Citation] {
        guard let document else { return [] }

        return try await withCheckedThrowingContinuation { continuation in
            rasterQueue.async {
                do {
                    let found = try document.citations(page: UInt32(page))
                    continuation.resume(
                        returning: found.map { citation in
                            Citation(
                                page: page,
                                text: citation.text,
                                labels: citation.labels,
                                xPt: CGFloat(citation.xPt),
                                yPt: CGFloat(citation.yPt),
                                widthPt: CGFloat(citation.widthPt),
                                heightPt: CGFloat(citation.heightPt)
                            )
                        }
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func captionMentions(page: Int) async throws -> [CaptionMention] {
        guard let document else { return [] }

        return try await withCheckedThrowingContinuation { continuation in
            rasterQueue.async {
                do {
                    let found = try document.captionMentions(page: UInt32(page))
                    continuation.resume(
                        returning: found.map { mention in
                            CaptionMention(
                                page: page,
                                kind: mention.kind,
                                label: mention.label,
                                start: Int(mention.start),
                                end: Int(mention.end),
                                xPt: CGFloat(mention.xPt),
                                yPt: CGFloat(mention.yPt),
                                widthPt: CGFloat(mention.widthPt),
                                heightPt: CGFloat(mention.heightPt)
                            )
                        }
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func annotations() async throws -> [DocumentAnnotation] {
        // Document-wide and cached in Rust for the lifetime of the open document, so the shell
        // fetches it once per document and only converts it here.
        guard let document else { return [] }

        let records: [AnnotationRecord] = try await withCheckedThrowingContinuation { continuation in
            rasterQueue.async {
                do {
                    continuation.resume(returning: try document.annotations())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        return records.map(Self.documentAnnotation(from:))
    }

    public func saveAnnotatedCopy(
        to url: URL,
        annotations: [AnnotationWriteRequest],
        zoom: CGFloat
    ) async throws -> AnnotationWriteReport {
        guard let document else {
            throw NSError(
                domain: "Lyra",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No document is open"]
            )
        }
        let records = Self.writeRecords(from: annotations)
        let report: AnnotationSaveReport = try await withCheckedThrowingContinuation { continuation in
            // Off the main thread: PDFium writes and reopens the whole document, and the UI must
            // not wait for it. `rasterQueue` is also what keeps this engine's PDFium calls
            // serialised with its raster calls.
            rasterQueue.async {
                do {
                    continuation.resume(returning: try document.saveAnnotationsCopy(
                        destination: url.path,
                        annotations: records,
                        zoom: Double(zoom)
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return Self.writeReport(from: report)
    }

    public func replaceWithAnnotations(
        _ annotations: [AnnotationWriteRequest],
        zoom: CGFloat
    ) async throws -> AnnotationWriteReport {
        guard let document else {
            throw NSError(
                domain: "Lyra",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No document is open"]
            )
        }
        let records = Self.writeRecords(from: annotations)
        let report: AnnotationSaveReport = try await withCheckedThrowingContinuation { continuation in
            rasterQueue.async {
                do {
                    continuation.resume(returning: try document.replaceWithAnnotations(
                        annotations: records,
                        zoom: Double(zoom)
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return Self.writeReport(from: report)
    }

    public func pageRotations() async throws -> [Int] {
        guard let document else {
            throw NSError(
                domain: "Lyra",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No document is open"]
            )
        }
        let rotations: [UInt32] = try await withCheckedThrowingContinuation { continuation in
            rasterQueue.async {
                do {
                    continuation.resume(returning: try document.pageRotations())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return rotations.map(Int.init)
    }

    public func applyPageOperation(
        _ operation: PageEditOperation,
        to destination: URL
    ) async throws -> PageOperationReport {
        guard let document else {
            throw NSError(
                domain: "Lyra",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No document is open"]
            )
        }
        let record = Self.pageOperationRecord(operation)
        let report: PageEditReport = try await withCheckedThrowingContinuation { continuation in
            rasterQueue.async {
                do {
                    continuation.resume(
                        returning: try document.applyPageOperation(
                            destination: destination.path,
                            operation: record
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        // The whole engine is main-actor isolated, so the UniFFI record is converted here rather
        // than on `rasterQueue` (a main-actor assertion would trap there).
        return Self.pageEditReport(report, destination: destination)
    }

    public func extractPages(_ pages: [Int], to destination: URL) async throws -> PageOperationReport {
        guard let document else {
            throw NSError(
                domain: "Lyra",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No document is open"]
            )
        }
        let indices = pages.map { UInt32(max(0, $0)) }
        let report: PageEditReport = try await withCheckedThrowingContinuation { continuation in
            rasterQueue.async {
                do {
                    continuation.resume(
                        returning: try document.extractPages(
                            destination: destination.path,
                            pages: indices
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return Self.pageEditReport(report, destination: destination)
    }

    public func saveEditedCopy(to destination: URL) async throws -> PageOperationReport {
        guard let document else {
            throw NSError(
                domain: "Lyra",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No document is open"]
            )
        }
        let report: PageEditReport = try await withCheckedThrowingContinuation { continuation in
            rasterQueue.async {
                do {
                    continuation.resume(
                        returning: try document.saveEditedCopy(destination: destination.path)
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return Self.pageEditReport(report, destination: destination)
    }

    public func replaceOriginalWithPageEdits(original: URL) async throws -> PageOperationReport {
        guard let document else {
            throw NSError(
                domain: "Lyra",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No document is open"]
            )
        }
        let report: PageEditReport = try await withCheckedThrowingContinuation { continuation in
            rasterQueue.async {
                do {
                    continuation.resume(
                        returning: try document.replaceWithEditedPages(originalPath: original.path)
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return Self.pageEditReport(report, destination: original)
    }

    private static func pageOperationRecord(_ operation: PageEditOperation) -> PageOperationRecord {
        switch operation {
        case .rotate(let pages, let quarterTurns):
            return .rotate(
                pages: pages.map { UInt32(max(0, $0)) },
                quarterTurns: Int32(clamping: quarterTurns)
            )
        case .setRotation(let pages, let quarterTurns):
            return .setRotation(
                pages: pages.map { UInt32(max(0, $0)) },
                quarterTurns: quarterTurns.map { UInt32(clamping: max(0, $0)) }
            )
        case .delete(let pages):
            return .delete(pages: pages.map { UInt32(max(0, $0)) })
        case .move(let pages, let destination):
            return .move(
                pages: pages.map { UInt32(max(0, $0)) },
                destination: UInt32(max(0, destination))
            )
        case .insertBlank(let index):
            return .insertBlank(index: UInt32(max(0, index)))
        }
    }

    private static func pageEditReport(
        _ report: PageEditReport,
        destination: URL
    ) -> PageOperationReport {
        PageOperationReport(
            destination: URL(fileURLWithPath: report.destinationPath),
            pageCount: Int(report.pageCount),
            pageMap: report.pageMap.map { $0.map(Int.init) },
            rotations: report.rotations.map(Int.init),
            insertedPage: report.insertedPage.map(Int.init),
            backupPath: report.backupPath.map { URL(fileURLWithPath: $0) },
            outputBytes: report.outputBytes,
            cleanedTemporaryFiles: Int(report.cleanedTemporaryFiles)
        )
    }

    public func interruptedSaveNote(at url: URL) -> String? {
        guard let document, document.path() == url.path else { return nil }
        return document.interruptedSaveNote()
    }

    public func suggestedAnnotatedCopyURL(for url: URL) -> URL {
        guard let document else {
            let stem = url.deletingPathExtension().lastPathComponent
            return url.deletingLastPathComponent()
                .appendingPathComponent("\(stem) (annotated).pdf")
        }
        return URL(fileURLWithPath: document.suggestedCopyPath())
    }

    /// One shell request, as the FFI record.
    private static func writeRecords(from requests: [AnnotationWriteRequest]) -> [WriteAnnotationRecord] {
        requests.map { request in
            let quad = { (rect: CGRect) in
                AnnotationQuad(
                    xPt: Double(rect.origin.x),
                    yPt: Double(rect.origin.y),
                    widthPt: Double(rect.width),
                    heightPt: Double(rect.height)
                )
            }
            let kind: AnnotationWriteKind = switch request.kind {
            case .highlight: .highlight
            case .underline: .underline
            case .note: .note
            }
            return WriteAnnotationRecord(
                id: request.id,
                page: UInt32(request.page),
                kind: kind,
                rect: quad(request.rect),
                quads: request.quads.map(quad),
                color: AnnotationColorRecord(
                    red: request.color.red,
                    green: request.color.green,
                    blue: request.color.blue
                ),
                opacity: request.opacity,
                contents: request.contents,
                author: request.author,
                modified: request.modified
            )
        }
    }

    private static func writeReport(from report: AnnotationSaveReport) -> AnnotationWriteReport {
        AnnotationWriteReport(
            destinationPath: report.destinationPath,
            writtenIDs: report.writtenIds,
            appendedBytes: report.appendedBytes,
            backupPath: report.backupPath,
            preexistingAnnotationCount: Int(report.preexistingAnnotationCount),
            cleanedTemporaryFiles: Int(report.cleanedTemporaryFiles),
            sourceBytesPreserved: report.sourceBytesPreserved
        )
    }

    /// One FFI record, as the shell models it.
    ///
    /// Split out of the mapping above because a single closure with this many conversions makes
    /// the Swift type checker give up ("unable to type-check this expression in reasonable time").
    private static func documentAnnotation(from record: AnnotationRecord) -> DocumentAnnotation {
        let quads = record.quads.map { quad in
            AnnotationQuadBox(
                xPt: CGFloat(quad.xPt),
                yPt: CGFloat(quad.yPt),
                widthPt: CGFloat(quad.widthPt),
                heightPt: CGFloat(quad.heightPt)
            )
        }

        // The FFI reports "no colour" as an absent record, and the shell keeps that distinction:
        // black is a colour somebody may have chosen, and a sticky note carries no colour at all.
        var color: AnnotationColor?
        if let channels = record.color {
            // `/CA` is the annotation's opacity (0…1 by definition; clamped anyway so a malformed
            // file cannot trap here), and an absent `/CA` reads as opaque.
            let alpha = min(max(((record.opacity ?? 1.0) * 255.0).rounded(), 0), 255)
            color = AnnotationColor(
                red: channels.red,
                green: channels.green,
                blue: channels.blue,
                alpha: UInt8(alpha)
            )
        }

        return DocumentAnnotation(
            id: record.id,
            parentID: record.parentId,
            isReply: record.isReply,
            kind: record.kind,
            page: Int(record.page),
            xPt: CGFloat(record.xPt),
            yPt: CGFloat(record.yPt),
            widthPt: CGFloat(record.widthPt),
            heightPt: CGFloat(record.heightPt),
            quads: quads,
            color: color,
            opacity: record.opacity,
            blend: record.blend,
            contents: record.contents,
            author: record.author,
            modified: record.modified,
            fontSizePt: record.fontSizePt.map { CGFloat($0) },
            alignment: record.alignment,
            // An unknown classification from a newer engine reads as "not drawn" rather than as
            // a guess: drawing the wrong thing over a page is worse than drawing nothing, and the
            // sidebar still lists it.
            drawing: AnnotationDrawing(rawValue: record.drawing) ?? .skipped,
            skipReason: record.skipReason.flatMap(AnnotationSkipReason.init(rawValue:)),
            visible: record.visible
        )
    }

    public func figures() async throws -> [Figure] {
        // The index is document-wide and the Rust call walks up to 120 pages, so a second
        // click must not pay for the scan again.
        if let figuresCache { return figuresCache }
        let epoch = documentEpoch
        guard let document else { return [] }

        let records: [FigureRecord] = try await withCheckedThrowingContinuation { continuation in
            rasterQueue.async {
                do {
                    continuation.resume(returning: try document.figures())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        let figures = records.map { record in
            Figure(
                kind: record.kind,
                label: record.label,
                page: Int(record.page),
                captionText: record.captionText,
                xPt: CGFloat(record.xPt),
                yPt: CGFloat(record.yPt),
                widthPt: CGFloat(record.widthPt),
                heightPt: CGFloat(record.heightPt)
            )
        }
        if epoch == documentEpoch { figuresCache = figures }
        return figures
    }

    public func references() async throws -> [Reference] {
        guard let document else { return [] }

        return try await withCheckedThrowingContinuation { continuation in
            rasterQueue.async {
                do {
                    let entries = try document.references()
                    continuation.resume(
                        returning: entries.map { entry in
                            Reference(
                                label: entry.label,
                                text: entry.text,
                                page: Int(entry.page),
                                xPt: CGFloat(entry.xPt),
                                yPt: CGFloat(entry.yPt),
                                widthPt: CGFloat(entry.widthPt),
                                heightPt: CGFloat(entry.heightPt)
                            )
                        }
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func resolveCitations(labels: [String]) async throws -> [Reference] {
        guard let document else { return [] }

        return try await withCheckedThrowingContinuation { continuation in
            rasterQueue.async {
                do {
                    let records = try document.resolveCitations(labels: labels)
                    continuation.resume(
                        returning: records.map { record in
                            Reference(
                                label: record.label,
                                text: record.text,
                                page: Int(record.page),
                                xPt: CGFloat(record.xPt),
                                yPt: CGFloat(record.yPt),
                                widthPt: CGFloat(record.widthPt),
                                heightPt: CGFloat(record.heightPt)
                            )
                        }
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func outline() async throws -> [OutlineEntry] {
        guard let document else { return [] }

        return try await withCheckedThrowingContinuation { continuation in
            rasterQueue.async {
                do {
                    let entries = try document.outline()
                    continuation.resume(
                        returning: entries.map { entry in
                            OutlineEntry(
                                title: entry.title,
                                page: entry.page.map { Int($0) },
                                depth: Int(entry.depth)
                            )
                        }
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func metadata() async throws -> DocumentMetadata {
        guard let document else { return .empty }

        let record: DocumentMetadataRecord = try await withCheckedThrowingContinuation { continuation in
            // Metadata reads a page of text and the XMP stream; keep it off the main thread and
            // serialised with the other PDFium calls.
            rasterQueue.async {
                do {
                    continuation.resume(returning: try document.metadata())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return Self.documentMetadata(from: record)
    }

    public func generateBibtex(_ draft: MetadataDraft) -> String {
        generateBibtexEntry(
            draft: MetadataDraftRecord(
                title: draft.title,
                authors: draft.authors,
                venue: draft.venue,
                year: draft.year,
                doi: draft.doi,
                arxivId: draft.arxivID
            )
        )
    }

    private static func metadataField(from record: MetadataFieldRecord) -> MetadataField {
        let source = MetadataFieldSource(record.source)
        return MetadataField(
            values: record.values,
            source: source,
            sourceLabel: record.sourceLabel,
            guessed: record.guessed
        )
    }

    private static func documentMetadata(from record: DocumentMetadataRecord) -> DocumentMetadata {
        DocumentMetadata(
            title: metadataField(from: record.title),
            authors: metadataField(from: record.authors),
            venue: metadataField(from: record.venue),
            year: metadataField(from: record.year),
            doi: metadataField(from: record.doi),
            arxivID: metadataField(from: record.arxivId),
            bibtex: record.bibtex
        )
    }

    public func search(_ pattern: String, limit: Int) async throws -> [SearchHit] {
        guard let document else { return [] }

        return try await withCheckedThrowingContinuation { continuation in
            rasterQueue.async {
                do {
                    let hits = try document.search(pattern: pattern, limit: UInt32(limit))
                    continuation.resume(
                        returning: hits.map { hit in
                            SearchHit(
                                page: Int(hit.page),
                                start: Int(hit.start),
                                end: Int(hit.end),
                                snippet: hit.snippet
                            )
                        }
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func contentHeightPt(gapPt: CGFloat) -> CGFloat {
        contentHeightPt(gapPt: gapPt, layout: .continuous)
    }

    public func contentHeightPt(gapPt: CGFloat, layout: ReaderLayoutMode) -> CGFloat {
        guard let document else { return 0 }
        return CGFloat(document.contentHeightPtFor(layout: layout.rust, gapPt: Double(gapPt)))
    }

    public func contentWidthPt(gapPt: CGFloat) -> CGFloat {
        contentWidthPt(gapPt: gapPt, layout: .continuous)
    }

    public func contentWidthPt(gapPt: CGFloat, layout: ReaderLayoutMode) -> CGFloat {
        guard let document else { return 0 }
        return CGFloat(document.contentWidthPtFor(layout: layout.rust, gapPt: Double(gapPt)))
    }

    public func visiblePages(
        scrollYPt: CGFloat,
        viewportHeightPt: CGFloat,
        gapPt: CGFloat,
        marginPt: CGFloat
    ) -> [PagePlacement] {
        visiblePages(
            scrollYPt: scrollYPt,
            viewportHeightPt: viewportHeightPt,
            gapPt: gapPt,
            marginPt: marginPt,
            layout: .continuous
        )
    }

    public func visiblePages(
        scrollYPt: CGFloat,
        viewportHeightPt: CGFloat,
        gapPt: CGFloat,
        marginPt: CGFloat,
        layout: ReaderLayoutMode
    ) -> [PagePlacement] {
        guard let document else { return [] }
        return document
            .visiblePagesFor(
                scrollYPt: Double(scrollYPt),
                viewportHeightPt: Double(viewportHeightPt),
                layout: layout.rust,
                gapPt: Double(gapPt),
                marginPt: Double(marginPt)
            )
            .map { record in
                PagePlacement(
                    index: Int(record.index),
                    topPt: CGFloat(record.topPt),
                    leftPt: CGFloat(record.leftPt),
                    widthPt: CGFloat(record.widthPt),
                    heightPt: CGFloat(record.heightPt)
                )
            }
    }

    public func pageIndex(atScrollYPt scrollYPt: CGFloat, gapPt: CGFloat) -> Int {
        pageIndex(atScrollYPt: scrollYPt, gapPt: gapPt, layout: .continuous)
    }

    public func pageIndex(
        atScrollYPt scrollYPt: CGFloat,
        gapPt: CGFloat,
        layout: ReaderLayoutMode
    ) -> Int {
        guard let document else { return 0 }
        return Int(document.pageIndexAtFor(
            scrollYPt: Double(scrollYPt),
            layout: layout.rust,
            gapPt: Double(gapPt)
        ))
    }

    public func pageTopPt(_ index: Int, gapPt: CGFloat) -> CGFloat {
        pageTopPt(index, gapPt: gapPt, layout: .continuous)
    }

    public func pageTopPt(_ index: Int, gapPt: CGFloat, layout: ReaderLayoutMode) -> CGFloat {
        guard let document else { return 0 }
        return CGFloat(document.pageTopPtFor(
            page: UInt32(index),
            layout: layout.rust,
            gapPt: Double(gapPt)
        ))
    }

}

/// Fallback engine for builds where the Rust backend cannot start (for example a build
/// without PDFium): the UI stays usable and says what happened.
@MainActor
public final class MockEngine: PDFEngine {
    public init() {}

    public var version: String { "mock engine (the Rust backend did not start)" }

    public func openDocument(at url: URL) throws -> LoadedDocument {
        LoadedDocument(
            title: url.deletingPathExtension().lastPathComponent,
            pageCount: 0,
            url: url
        )
    }

    public func renderPage(_ page: Int, scale: CGFloat) async throws -> PageImage {
        throw NSError(
            domain: "Lyra",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "The mock engine cannot rasterize pages"]
        )
    }

    public func rasterizeTile(
        page: Int,
        lod: UInt8,
        tileX: Int,
        tileY: Int,
        tileSize: Int
    ) async throws -> TileImage {
        throw NSError(
            domain: "Lyra",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "The mock engine cannot rasterize tiles"]
        )
    }

    public func textPage(_ page: Int) async throws -> TextPage {
        throw NSError(
            domain: "Lyra",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "The mock engine has no text layer"]
        )
    }

    public func rasterizeRegion(
        page: Int,
        scale: CGFloat,
        xPt: CGFloat,
        yPt: CGFloat,
        widthPt: CGFloat,
        heightPt: CGFloat
    ) async throws -> PageImage {
        throw NSError(
            domain: "Lyra",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "The mock engine cannot rasterize regions"]
        )
    }

    public func links(_ page: Int) async throws -> [DocumentLink] { [] }

    public func citations(_ page: Int) async throws -> [Citation] { [] }

    public func captionMentions(page: Int) async throws -> [CaptionMention] { [] }

    public func annotations() async throws -> [DocumentAnnotation] { [] }

    public func figures() async throws -> [Figure] { [] }

    public func references() async throws -> [Reference] { [] }

    public func resolveCitations(labels: [String]) async throws -> [Reference] { [] }

    public func outline() async throws -> [OutlineEntry] { [] }

    public func metadata() async throws -> DocumentMetadata { .empty }

    public func generateBibtex(_ draft: MetadataDraft) -> String {
        generateBibtexEntry(
            draft: MetadataDraftRecord(
                title: draft.title,
                authors: draft.authors,
                venue: draft.venue,
                year: draft.year,
                doi: draft.doi,
                arxivId: draft.arxivID
            )
        )
    }

    public func search(_ pattern: String, limit: Int) async throws -> [SearchHit] { [] }

    public func contentHeightPt(gapPt: CGFloat) -> CGFloat { 0 }
    public func contentWidthPt(gapPt: CGFloat) -> CGFloat { 0 }
    public func visiblePages(
        scrollYPt: CGFloat,
        viewportHeightPt: CGFloat,
        gapPt: CGFloat,
        marginPt: CGFloat
    ) -> [PagePlacement] { [] }
    public func pageIndex(atScrollYPt scrollYPt: CGFloat, gapPt: CGFloat) -> Int { 0 }
    public func pageTopPt(_ index: Int, gapPt: CGFloat) -> CGFloat { 0 }
}

// PDF glyph boxes describe ink, not a text selection. Join adjacent glyphs on each
// line so spaces and the gaps between letters are included, without bridging columns.
extension TextPage {
    /// The character range whose glyphs a box on the page covers — the inverse of
    /// [`selectionRects(in:)`], used to select the text under an annotation the PDF carries.
    ///
    /// Returns `nil` when no glyph overlaps, which is the honest answer for a box over a figure
    /// or over a page whose text layer could not be read.
    public func characterRange(in rect: CGRect) -> ClosedRange<Int>? {
        var first: Int?
        var last: Int?
        for line in selectionLines {
            for stop in line.stops where stop.rect.intersects(rect) {
                first = first ?? stop.index
                last = stop.index
            }
        }
        guard let first, let last, first <= last else { return nil }
        return first...last
    }

    public func selectionRects(in range: ClosedRange<Int>) -> [CGRect] {
        var result: [CGRect] = []
        for line in selectionLines {
            var run: CGRect?
            for stop in line.stops where range.contains(stop.index) {
                // Use one stable line height, including spaces with no PDF ink box.
                let rect = CGRect(x: stop.rect.minX, y: line.bounds.minY,
                                  width: stop.rect.width, height: line.bounds.height)
                if let current = run {
                    let gap = max(rect.minX - current.maxX, current.minX - rect.maxX)
                    if gap <= line.bounds.height * 1.5 {
                        run = current.union(rect)
                    } else {
                        result.append(current)
                        run = rect
                    }
                } else {
                    run = rect
                }
            }
            if let run { result.append(run) }
        }
        return result
    }
}
