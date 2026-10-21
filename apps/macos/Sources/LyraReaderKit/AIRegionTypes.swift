import AppKit
import CoreGraphics
import Foundation

/// One marquee-selected page region, captured exactly once.
///
/// The rectangle is page-local view space (`rasterize_region`'s space) in points. The PNG is the
/// capture the model receives, `text` is what the text layer reported inside the same rectangle,
/// and the pixel size is the capture's own, never re-derived from the rectangle after the fact.
public struct AIRegionAttachment: Equatable, Sendable {
    /// 0-based, as the engine's page indices are.
    public let page: Int
    public let rect: CGRect
    public let text: String
    public let png: Data
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// The scale the capture used: `max(2, zoom)` at the moment of selection.
    public let captureScale: CGFloat
    /// Whether the text layer had more than `AIRegionLimits.maximumTextCharacters` in the region.
    public let textTruncated: Bool

    public init(
        page: Int,
        rect: CGRect,
        text: String,
        png: Data,
        pixelWidth: Int,
        pixelHeight: Int,
        captureScale: CGFloat,
        textTruncated: Bool = false
    ) {
        self.page = page
        self.rect = rect
        self.text = text
        self.png = png
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.captureScale = captureScale
        self.textTruncated = textTruncated
    }

    public var characterCount: Int { text.count }
    public var pageLabel: String { "Page \(page + 1)" }
    public var sizeLabel: String {
        String(format: "%.0f × %.0f pt", Double(rect.width), Double(rect.height))
    }
    public var pixelLabel: String { "\(pixelWidth) × \(pixelHeight) px" }
    public var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var thumbnail: NSImage? { NSImage(data: png) }
}

/// The bounds the attachment path enforces. Stated in the card, in the refusal, and checked
/// again by the Rust builder so a stale caller cannot send more than the preview described.
public enum AIRegionLimits {
    /// The smallest scale a capture may use, whatever the reader's zoom is.
    public static let minimumCaptureScale: CGFloat = 2
    /// A capture larger than this is refused, not silently downsampled: the promise is "the
    /// reader's zoom, at least 2×", and downsampling would break it.
    public static let maximumPixels = 4_000_000
    public static let maximumEdgePixels = 4_096
    /// Text extracted from the region is capped here. The Rust builder applies the same cap.
    public static let maximumTextCharacters = 12_000
    /// The encoded PNG bound the request builder checks.
    public static let maximumPNGBytes = 8 * 1024 * 1024

    public static var boundDescription: String {
        "Regions up to 4 megapixels at 2× (for example 1,000 × 1,000 pt) and 12,000 text characters are accepted."
    }

    /// Why this rectangle cannot be captured at `scale`, or nil when it can.
    public static func refusal(
        for rect: CGRect,
        scale: CGFloat,
        zoom: CGFloat
    ) -> String? {
        guard rect.width.isFinite, rect.height.isFinite,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width > 0, rect.height > 0 else {
            return "The selected area is empty. Drag a rectangle over the page to ask about it."
        }
        let captureScale = max(minimumCaptureScale, zoom)
        let width = Int((rect.width * captureScale).rounded(.up))
        let height = Int((rect.height * captureScale).rounded(.up))
        guard width > 0, height > 0 else {
            return "The selected area is too small to capture. Drag a larger rectangle."
        }
        if width > maximumEdgePixels || height > maximumEdgePixels
            || width * height > maximumPixels {
            return "This selection is larger than the attachment bound. \(boundDescription)"
        }
        guard scale > 0 else { return "The region could not be captured at this zoom." }
        return nil
    }
}

/// Extract the text layer inside a page-local rectangle.
///
/// Lines are assembled in the order the text layer emits them, with each line's glyphs sorted by
/// x. This preserves column order for a region that spans two columns while still putting the
/// words of one line back together. Missing spaces are reconstructed from glyph gaps; the raw
/// text of the page is not used because it cannot be restricted to the rectangle.
public enum AIRegionText {
    public static func extract(
        from page: TextPage,
        in region: CGRect,
        limit: Int = AIRegionLimits.maximumTextCharacters
    ) -> (text: String, truncated: Bool) {
        struct Line {
            var minY: CGFloat
            var maxY: CGFloat
            var height: CGFloat
            var glyphs: [(x: CGFloat, maxX: CGFloat, text: String, isSpace: Bool)]
        }
        var lines: [Line] = []

        for char in page.chars {
            if char.unicode == 10 || char.unicode == 13 { continue }
            let rect = CGRect(x: char.xPt, y: char.yPt,
                              width: char.widthPt, height: char.heightPt)
            guard rect.width > 0, rect.height > 0 else { continue }
            let intersects = rect.intersects(region)
            let centre = CGPoint(x: rect.midX, y: rect.midY)
            let covered = intersects
                ? rect.intersection(region).width * rect.intersection(region).height
                    / max(rect.width * rect.height, 0.001)
                : 0
            guard region.contains(centre) || covered >= 0.45 else { continue }
            let scalar = Unicode.Scalar(char.unicode) ?? Unicode.Scalar(0xFFFD)!
            let isSpace = CharacterSet.whitespaces.contains(scalar)
            let glyph = (x: rect.minX, maxX: rect.maxX, text: String(Character(scalar)),
                         isSpace: isSpace)
            let tolerance = max(2.5, rect.height * 0.45)
            if let index = lines.indices.last(where: {
                abs((lines[$0].minY + lines[$0].maxY) / 2 - rect.midY) <= tolerance
            }) {
                lines[index].minY = min(lines[index].minY, rect.minY)
                lines[index].maxY = max(lines[index].maxY, rect.maxY)
                lines[index].height = max(lines[index].height, rect.height)
                lines[index].glyphs.append(glyph)
            } else {
                lines.append(Line(minY: rect.minY, maxY: rect.maxY, height: rect.height,
                                  glyphs: [glyph]))
            }
        }

        var result = ""
        var truncated = false
        for line in lines {
            let sorted = line.glyphs.sorted { $0.x < $1.x }
            var lineText = ""
            var previousMaxX: CGFloat?
            for glyph in sorted {
                if glyph.isSpace {
                    if !lineText.isEmpty, !lineText.hasSuffix(" ") { lineText.append(" ") }
                    previousMaxX = max(previousMaxX ?? glyph.maxX, glyph.maxX)
                    continue
                }
                if let previousMaxX, glyph.x - previousMaxX > max(1.2, line.height * 0.12),
                   !lineText.isEmpty, !lineText.hasSuffix(" ") {
                    lineText.append(" ")
                }
                lineText += glyph.text
                previousMaxX = max(previousMaxX ?? glyph.maxX, glyph.maxX)
            }
            lineText = lineText.trimmingCharacters(in: .whitespaces)
            guard !lineText.isEmpty else { continue }
            if !result.isEmpty { result.append("\n") }
            result += lineText
            if result.count > limit {
                result = String(result.prefix(limit))
                truncated = true
                break
            }
        }
        return (result.trimmingCharacters(in: .whitespacesAndNewlines), truncated)
    }

    /// Whether a captured page rectangle is only paper: no glyph, rule, picture edge or tint.
    ///
    /// Sampling keeps this cheap for a 4-megapixel capture. The threshold is deliberately below
    /// an anti-aliased white page's noise and above the lightest printed rule, so a selected
    /// blank margin refuses while a page number or a fitted curve does not.
    public static func isBlank(_ image: PageImage) -> Bool {
        guard image.pixelWidth > 0, image.pixelHeight > 0 else { return true }
        let pixelCount = image.pixelWidth * image.pixelHeight
        let totalBytes = pixelCount * 4
        guard image.bgra.count >= totalBytes else { return true }
        let targetSamples = 24_000
        let stride = max(1, pixelCount / targetSamples)
        var dark = 0
        var samples = 0
        image.bgra.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 0
            while index < pixelCount {
                let offset = index * 4
                let b = bytes[offset]
                let g = bytes[offset + 1]
                let r = bytes[offset + 2]
                let a = bytes[offset + 3]
                if a > 0, min(r, min(g, b)) < 232 || max(r, max(g, b)) - min(r, min(g, b)) > 12 {
                    dark += 1
                }
                samples += 1
                index += stride
            }
        }
        return dark < max(3, samples / 1_000)
    }
}

/// The state of a finished region conversation. Cancelled and failed turns are kept in history
/// (the question is knowledge too) but are omitted from the Markdown export.
public enum AIRegionAnswerState: String, Equatable, Sendable {
    case finished
    case cancelled
    case failed
    case empty
}

/// One finished conversation, kept in memory for this window's lifetime.
///
/// It is deliberately not a PDF annotation and not a sidecar: no file beside the PDF is created.
/// The PNG lives in memory only; it is written to disk only when the reader exports the
/// knowledge document and chooses a destination.
public struct AIRegionHistoryEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let documentKey: String
    public let attachment: AIRegionAttachment
    public let question: String
    public let answer: String
    public let state: AIRegionAnswerState
    public let error: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        documentKey: String,
        attachment: AIRegionAttachment,
        question: String,
        answer: String,
        state: AIRegionAnswerState,
        error: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.documentKey = documentKey
        self.attachment = attachment
        self.question = question
        self.answer = answer
        self.state = state
        self.error = error
        self.createdAt = createdAt
    }

    public var hasAnswer: Bool {
        !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `[p.N]` citations the answer made, in the order the answer first mentions them.
    public var citedPages: [Int] { AIAnswerMarkdown.allCitedPages(in: answer) }

    public var answerPreview: String {
        let collapsed = answer.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count <= 160 ? collapsed : String(collapsed.prefix(160)) + "…"
    }

    public var timeLabel: String {
        AIRegionDates.display.string(from: createdAt)
    }
}

enum AIRegionDates {
    nonisolated(unsafe) static let display: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

/// One open region conversation shown in the document gap.
///
/// The request state lives in its own `AIAssistantModel`, so the card's cancel/retry can never
/// disturb the right panel's chat and two cards can stream at once. The card owns the editable
/// question and reports its measured view height; `AppState` turns that into the gap height in
/// content points.
@MainActor
public final class AIRegionCard: ObservableObject, Identifiable {
    public let id: UUID
    public let documentKey: String
    public let attachment: AIRegionAttachment
    public let assistant: AIAssistantModel
    public let createdAt: Date
    /// The question field. Sending captures it in `assistant.regionAskedQuestion`; editing it
    /// afterwards cannot change the question the answer belongs to.
    @Published public var question: String = ""
    /// Measured height of the whole card in view points. It starts at a small estimate and is
    /// corrected after the first layout pass; the gap follows it exactly.
    @Published public private(set) var heightViewPt: CGFloat = 240

    public init(
        id: UUID = UUID(),
        documentKey: String,
        attachment: AIRegionAttachment,
        assistant: AIAssistantModel,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.documentKey = documentKey
        self.attachment = attachment
        self.assistant = assistant
        self.createdAt = createdAt
        self.question = ""
    }

    /// The question the current answer belongs to.
    public var askedQuestion: String? { assistant.regionAskedQuestion }

    public var answer: String { assistant.answer }
    public var isStreaming: Bool { assistant.phase == .streaming }
    public var hasPreview: Bool { assistant.plan != nil }

    public var answerState: AIRegionAnswerState {
        let trimmed = assistant.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch assistant.phase {
        case .failed:
            return trimmed.isEmpty ? .failed : .failed
        case .cancelled:
            return trimmed.isEmpty ? .cancelled : .cancelled
        case .finished:
            return trimmed.isEmpty ? .empty : .finished
        default:
            return trimmed.isEmpty ? .empty : .finished
        }
    }

    /// What "Done", "Collapse" or a document switch keeps. Nil when the card never got a
    /// question (closing an empty draft then discards it: there is nothing to remember).
    public var historyEntry: AIRegionHistoryEntry? {
        guard let question = askedQuestion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !question.isEmpty else { return nil }
        return AIRegionHistoryEntry(
            id: id,
            documentKey: documentKey,
            attachment: attachment,
            question: question,
            answer: assistant.answer,
            state: answerState,
            error: assistant.errorMessage,
            createdAt: createdAt
        )
    }

    public func updateHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0, abs(height - heightViewPt) > 0.5 else { return }
        heightViewPt = height
    }
}
