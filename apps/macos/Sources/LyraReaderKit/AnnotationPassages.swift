import AppKit
import NaturalLanguage
import SwiftUI

/// Text offsets belong to normalized Unicode, while source ranges keep PDF character indices.
/// Keeping that mapping avoids guessing with substring searches (especially repeated words).
package struct AnnotationSentenceMap {
    package let text: String
    package let offsets: [Int: Range<Int>]
    package let sentences: [Range<Int>]
    private var documentRanges: [String: Range<Int>] = [:]
    private var resolvedDocumentRanges: Set<String> = []

    package init(_ page: TextPage) {
        var text = ""
        var offsets: [Int: Range<Int>] = [:]
        var position = 0
        var previousWasSpace = true
        var lineBounds: CGRect?
        var previousLine: CGRect?
        for (index, character) in page.chars.enumerated() {
            guard let scalar = Unicode.Scalar(character.unicode), scalar.value != 0 else { continue }
            if scalar.properties.isWhitespace {
                if scalar.value == 10 || scalar.value == 13 {
                    if let lineBounds { previousLine = lineBounds }
                    lineBounds = nil
                }
                if !previousWasSpace {
                    text.append(" "); offsets[index] = position..<(position + 1); position += 1
                }
                previousWasSpace = true
            } else {
                let box = CGRect(x: character.xPt, y: character.yPt,
                                 width: character.widthPt, height: character.heightPt)
                if let previous = previousLine, box.height > 0 {
                    let threshold = max(3, min(previous.height, box.height) * 0.7)
                    // Join wrapped body lines, but keep headings, paragraph gaps and column
                    // restarts out of a sentence's context.
                    if box.minY - previous.maxY > threshold || box.maxY < previous.minY - threshold {
                        if text.hasSuffix(" ") { text.removeLast(); position -= 1 }
                        text.append("\n\n"); position += 2
                    } else if box.minY < previous.maxY { lineBounds = previous }
                }
                previousLine = nil
                if box.height > 0 { lineBounds = lineBounds.map { $0.union(box) } ?? box }
                let string = String(scalar)
                text.append(string)
                offsets[index] = position..<(position + string.utf16.count)
                position += string.utf16.count
                previousWasSpace = false
            }
        }
        let tokenizer = NLTokenizer(unit: .sentence)
        var sentences: [Range<Int>] = []
        var paragraphOffset = 0
        for paragraph in text.components(separatedBy: "\n\n") {
            tokenizer.string = paragraph
            tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
                let ns = NSRange(range, in: paragraph)
                sentences.append((paragraphOffset + ns.location)..<(paragraphOffset + ns.location + ns.length))
                return true
            }
            paragraphOffset += paragraph.utf16.count + 2
        }
        self.text = text
        self.offsets = offsets
        self.sentences = sentences.isEmpty && !text.isEmpty ? [0..<position] : sentences
    }

    mutating func range(for annotation: DocumentAnnotation, page: TextPage) -> Range<Int>? {
        if resolvedDocumentRanges.contains(annotation.id) { return documentRanges[annotation.id] }
        resolvedDocumentRanges.insert(annotation.id)
        let indices = page.chars.indices.filter { index in
            let char = page.chars[index]
            let rect = CGRect(x: char.xPt, y: char.yPt, width: char.widthPt, height: char.heightPt)
            guard rect.width > 0, rect.height > 0 else { return false }
            return annotation.boxes.contains { box in
                let region = CGRect(x: box.xPt, y: box.yPt, width: box.widthPt, height: box.heightPt)
                let overlap = rect.intersection(region)
                return !overlap.isNull && overlap.width * overlap.height > rect.width * rect.height * 0.35
            }
        }
        let range = span(indices: indices)
        documentRanges[annotation.id] = range
        return range
    }

    package func span(indices: [Int]) -> Range<Int>? {
        let ranges = indices.compactMap { offsets[$0] }
        guard let start = ranges.map(\.lowerBound).min(), let end = ranges.map(\.upperBound).max() else { return nil }
        return start..<end
    }
    package func sentence(containing mark: Range<Int>) -> Range<Int> {
        let touched = sentences.filter { $0.overlaps(mark) }
        let start = min(mark.lowerBound, touched.first?.lowerBound ?? mark.lowerBound)
        let end = max(mark.upperBound, touched.last?.upperBound ?? mark.upperBound)
        return start..<end
    }
}

package enum AnnotationSource: Hashable {
    case document(String), own(UUID)
    var key: String {
        switch self { case .document(let id): "pdf-\(id)"; case .own(let id): "own-\(id)" }
    }
}

package struct PassageMark: Identifiable {
    package var id: String { source.key }
    package let source: AnnotationSource
    package let range: Range<Int>
    package let kind: AppState.Annotation.Kind
    package let color: AnnotationColor
    package let opacity: Double
    package let note: String
    package let author: String?
    package let date: String?
}

package struct AnnotationPassage: Identifiable {
    package let id: String
    package let page: Int
    package let text: String
    package let start: Int
    package let marks: [PassageMark]

    @MainActor package func attributed(appearance: PaperAppearance) -> AttributedString {
        var result = AttributedString(text)
        for mark in marks {
            let range = NSRange(location: max(0, mark.range.lowerBound - start), length: mark.range.count)
            guard let swiftRange = Range(range, in: text),
                  let lower = AttributedString.Index(swiftRange.lowerBound, within: result),
                  let upper = AttributedString.Index(swiftRange.upperBound, within: result) else { continue }
            let span = lower..<upper
            let color = Color(nsColor: appearance.displayColor(mark.color.nsColor.withAlphaComponent(mark.opacity)))
            switch mark.kind {
            case .highlight: result[span].backgroundColor = color
            case .underline: result[span].swiftUI.underlineStyle = Text.LineStyle(color: color)
            case .strikeout: result[span].swiftUI.strikethroughStyle = Text.LineStyle(color: color)
            default: break
            }
        }
        return result
    }

    @MainActor package static func build(document: [DocumentAnnotation], own: [AppState.Annotation],
                                 pages: [Int: TextPage], maps: inout [Int: AnnotationSentenceMap]) -> [Self] {
        var grouped: [Int: [(range: Range<Int>, mark: PassageMark)]] = [:]
        for annotation in document where annotation.visible && !annotation.isReply && annotation.drawing == .markup {
            guard let page = pages[annotation.page], maps[annotation.page] != nil else { continue }
            guard let range = maps[annotation.page]?.range(for: annotation, page: page),
                  let map = maps[annotation.page] else { continue }
            let kind: AppState.Annotation.Kind = ["underline", "squiggly"].contains(annotation.kind) ? .underline
                : (annotation.kind == "strikeout" ? .strikeout : .highlight)
            let mark = PassageMark(source: .document(annotation.id), range: range, kind: kind,
                color: annotation.color ?? .init(red: 255, green: 221, blue: 90, alpha: 255),
                opacity: annotation.opacity ?? 1, note: annotation.contents ?? "",
                author: annotation.author, date: annotation.displayDate)
            grouped[annotation.page, default: []].append((map.sentence(containing: range), mark))
        }
        for annotation in own where annotation.kind.isTextMarkup {
            guard let map = maps[annotation.page], let page = pages[annotation.page],
                  annotation.start >= 0, annotation.start < page.chars.count, annotation.start <= annotation.end,
                  let range = map.span(indices: Array(annotation.start...min(annotation.end, page.chars.count - 1))) else { continue }
            let mark = PassageMark(source: .own(annotation.id), range: range, kind: annotation.kind,
                color: annotation.color, opacity: Double(annotation.color.alpha) / 255,
                note: annotation.note, author: nil,
                date: annotation.createdAt.formatted(date: .abbreviated, time: .shortened))
            grouped[annotation.page, default: []].append((map.sentence(containing: range), mark))
        }
        var result: [Self] = []
        for page in grouped.keys.sorted() {
            guard let map = maps[page] else { continue }
            let entries = grouped[page]!.sorted { $0.range.lowerBound < $1.range.lowerBound }
            var clusters: [(range: Range<Int>, marks: [PassageMark])] = []
            for entry in entries {
                if let last = clusters.last, last.range.overlaps(entry.range) {
                    let start = min(last.range.lowerBound, entry.range.lowerBound)
                    let end = max(last.range.upperBound, entry.range.upperBound)
                    clusters[clusters.count - 1] = (start..<end, last.marks + [entry.mark])
                } else { clusters.append((entry.range, [entry.mark])) }
            }
            for cluster in clusters {
                let range = NSRange(location: cluster.range.lowerBound, length: cluster.range.count)
                result.append(Self(id: "\(page):\(range.location)", page: page,
                    text: (map.text as NSString).substring(with: range), start: range.location, marks: cluster.marks))
            }
        }
        return result
    }
}

package struct AnnotationSidebarPage: Identifiable {
    package let id: Int
    package let rows: [Row]
    package let annotationCount: Int
    package enum Row: Identifiable {
        case passage(AnnotationPassage), document(AnnotationPanelRow), own(AppState.Annotation)
        package var id: String {
            switch self {
            case .passage(let value): "passage-\(value.id)"
            case .document(let value): "document-\(value.id)"
            case .own(let value): "own-\(value.id)"
            }
        }
        package func contains(_ source: AnnotationSource) -> Bool {
            switch self {
            case .passage(let value): value.marks.contains { $0.source == source }
            case .document(let value): source == .document(value.id)
            case .own(let value): source == .own(value.id)
            }
        }
    }

    @MainActor package static func build(passages: [AnnotationPassage], document: [DocumentAnnotation],
                                 own: [AppState.Annotation]) -> [Self] {
        var bySource: [AnnotationSource: AnnotationPassage] = [:]
        for passage in passages { for mark in passage.marks { bySource[mark.source] = passage } }
        var emitted: Set<String> = []
        var rows: [Int: [Row]] = [:]
        var counts: [Int: Int] = [:]
        func append(source: AnnotationSource, page: Int, fallback: Row) {
            counts[page, default: 0] += 1
            if let passage = bySource[source] {
                if emitted.insert(passage.id).inserted { rows[page, default: []].append(.passage(passage)) }
            } else { rows[page, default: []].append(fallback) }
        }
        for section in AnnotationPanelModel.build(from: document).sections {
            for row in section.rows {
                append(source: .document(row.id), page: section.page, fallback: .document(row))
            }
        }
        for annotation in own {
            append(source: .own(annotation.id), page: annotation.page, fallback: .own(annotation))
        }
        return rows.keys.sorted().map { Self(id: $0, rows: rows[$0]!, annotationCount: counts[$0] ?? 0) }
    }
}
