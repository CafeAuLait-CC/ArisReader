import AppKit
import CoreGraphics
import CoreText
import CryptoKit
import Foundation

// MARK: - Cache identity

/// The colour a translation's cover is painted in, sampled from the page's own paper.
///
/// Stored as 8-bit sRGB because it travels from the page raster (BGRA) to an overlay drawn by
/// AppKit; a colour object would make the overlay model non-`Sendable` for no benefit.
public struct TranslationPaperColor: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(nsColor: NSColor) {
        let rgb = nsColor.usingColorSpace(.sRGB) ?? .white
        func byte(_ value: CGFloat) -> UInt8 {
            UInt8(max(0, min(255, (value * 255).rounded())))
        }
        self.init(red: byte(rgb.redComponent), green: byte(rgb.greenComponent),
                  blue: byte(rgb.blueComponent))
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255, alpha: 1)
    }

    /// Perceived lightness. Paper below this is treated as dark and gets light text.
    public var luminance: CGFloat {
        let channels = [CGFloat(red), CGFloat(green), CGFloat(blue)].map { value -> CGFloat in
            let c = value / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
    }

    public var inkColor: NSColor {
        luminance < 0.42
            ? NSColor(srgbRed: 0.90, green: 0.89, blue: 0.86, alpha: 1)
            : NSColor(srgbRed: 0.14, green: 0.13, blue: 0.12, alpha: 1)
    }

    public static let lightPaper = TranslationPaperColor(red: 250, green: 248, blue: 244)

    public static func forAppearance(_ appearance: PaperAppearance) -> TranslationPaperColor {
        switch appearance {
        case .original: return TranslationPaperColor(red: 255, green: 255, blue: 255)
        case .warm: return TranslationPaperColor(red: 252, green: 247, blue: 237)
        case .night: return TranslationPaperColor(red: 36, green: 34, blue: 30)
        }
    }
}

/// The identity of one cached translation.
///
/// The key is the digest of exactly these six facts: the source text hash, the page, the
/// block rectangle in page-local 100% coordinates, the target language, the model and the prompt
/// version. Rectangles are rounded to 1/100 pt before hashing, so a floating-point re-read of the
/// same PDF cannot produce a different key. The page is included because the same sentence at the
/// same coordinates on two pages is still two translations.
public struct TranslationCacheKey: Hashable, Sendable {
    public static let promptVersion = "inplace-translation-v1"

    public let sourceHash: String
    public let page: Int
    public let rectXHundredths: Int
    public let rectYHundredths: Int
    public let rectWidthHundredths: Int
    public let rectHeightHundredths: Int
    public let language: String
    public let model: String
    public let promptVersion: String

    public init(sourceText: String, page: Int, rect: CGRect, language: String, model: String,
                promptVersion: String = TranslationCacheKey.promptVersion) {
        let digest = SHA256.hash(data: Data(sourceText.utf8))
            .map { String(format: "%02x", $0) }.joined()
        self.sourceHash = digest
        self.page = page
        self.rectXHundredths = Self.hundredths(rect.minX)
        self.rectYHundredths = Self.hundredths(rect.minY)
        self.rectWidthHundredths = Self.hundredths(rect.width)
        self.rectHeightHundredths = Self.hundredths(rect.height)
        self.language = language
        self.model = model
        self.promptVersion = promptVersion
    }

    public init(entry: InPlaceTranslation, language: String, model: String,
                promptVersion: String = TranslationCacheKey.promptVersion) {
        self.init(sourceText: entry.sourceText, page: entry.page, rect: entry.rect,
                  language: language, model: model, promptVersion: promptVersion)
    }

    private static func hundredths(_ value: CGFloat) -> Int {
        Int((value * 100).rounded())
    }

    /// The stable cache filename/dictionary key. SHA-256 of a canonical, locale-free string.
    public var digest: String {
        let canonical = [
            sourceHash,
            String(page),
            String(rectXHundredths),
            String(rectYHundredths),
            String(rectWidthHundredths),
            String(rectHeightHundredths),
            language,
            model,
            promptVersion,
        ].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// One cached translation. This is what lives in the document edit cache and survives relaunch.
public struct InPlaceTranslation: Codable, Equatable, Identifiable, Sendable {
    public var key: String
    public let page: Int
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let sourceText: String
    public var translatedText: String
    public let language: String
    public let model: String
    public let promptVersion: String
    public let rangeStart: Int?
    public let rangeEnd: Int?
    public let isBlock: Bool
    public let createdAt: Date

    public var id: String { key }
    public var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
    public var range: ClosedRange<Int>? {
        guard let rangeStart, let rangeEnd, rangeStart <= rangeEnd else { return nil }
        return rangeStart...rangeEnd
    }

    public init(key: String, page: Int, rect: CGRect, sourceText: String,
                translatedText: String, language: String, model: String,
                promptVersion: String, range: ClosedRange<Int>?, isBlock: Bool,
                createdAt: Date = Date()) {
        self.key = key
        self.page = page
        self.x = rect.minX
        self.y = rect.minY
        self.width = rect.width
        self.height = rect.height
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.language = language
        self.model = model
        self.promptVersion = promptVersion
        self.rangeStart = range?.lowerBound
        self.rangeEnd = range?.upperBound
        self.isBlock = isBlock
        self.createdAt = createdAt
    }

    public func matches(selection: ClosedRange<Int>) -> Bool {
        guard let range else { return false }
        return range.overlaps(selection)
    }
}

/// The on-disk form. Entries are keyed by digest; a newer app can add fields without reading
/// older files wrong because the version is checked before anything is used.
struct TranslationCacheFile: Codable {
    var version: Int = 1
    var entries: [String: InPlaceTranslation] = [:]

    static let currentVersion = 1
}

enum TranslationCacheStore {
    static func load(from url: URL) throws -> [String: InPlaceTranslation] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(TranslationCacheFile.self, from: data)
        guard file.version == TranslationCacheFile.currentVersion else { return [:] }
        return file.entries
    }

    static func save(_ entries: [String: InPlaceTranslation], to url: URL) throws {
        // Keep the file bounded. The cap is per document, and pruning is oldest-first so a
        // long-lived paper does not grow the cache without limit. A pruned entry is simply
        // translated again on demand; no annotation or PDF data is touched.
        let bounded: [String: InPlaceTranslation]
        if entries.count > 2_000 {
            let kept = entries.values.sorted { $0.createdAt > $1.createdAt }.prefix(2_000)
            bounded = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0) })
        } else {
            bounded = entries
        }
        let file = TranslationCacheFile(version: TranslationCacheFile.currentVersion,
                                        entries: bounded)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Blocks and targets

/// One paragraph block found in a page's text layer.
///
/// The blocks are derived from the same line rectangles the canvas draws for a selection
/// (`TextPage.selectionRects`), not from a second line parser: a block boundary that did not
/// agree with the selection the reader sees would make the cover miss the words it translates.
public struct TranslationBlock: Equatable, Sendable {
    public let page: Int
    public let range: ClosedRange<Int>
    public let rect: CGRect
    public let lineRects: [CGRect]
    public let sourceText: String
    public let sourceFontPt: CGFloat

    public init(page: Int, range: ClosedRange<Int>, rect: CGRect, lineRects: [CGRect],
                sourceText: String, sourceFontPt: CGFloat) {
        self.page = page
        self.range = range
        self.rect = rect
        self.lineRects = lineRects
        self.sourceText = sourceText
        self.sourceFontPt = sourceFontPt
    }
}

public enum TranslationBlockDetector {
    /// The largest vertical gap, as a multiple of the median line height, that still reads as
    /// the same paragraph. Same value as the Rust block builder (`blocks_from`: 0.8), so the
    /// paragraph the translator sees and the paragraph the AI context sees agree.
    public static let gapFactor: CGFloat = 0.8

    public static func blocks(page: Int, textPage: TextPage) -> [TranslationBlock] {
        guard !textPage.chars.isEmpty else { return [] }
        let all = 0...(textPage.chars.count - 1)
        let lineRects = textPage.selectionRects(in: all)
        var lines: [(rect: CGRect, range: ClosedRange<Int>)] = []
        for rect in lineRects where rect.width > 0.5 && rect.height > 0.5 {
            guard let range = textPage.characterRange(in: rect) else { continue }
            lines.append((rect, range))
        }
        guard !lines.isEmpty else { return [] }
        let heights = lines.map(\.rect.height).filter { $0 > 0 }.sorted()
        let medianHeight = heights.isEmpty ? 10 : heights[heights.count / 2]
        let maxGap = medianHeight * gapFactor
        let medianFont = max(7, min(18, medianHeight))

        struct Group {
            var rect: CGRect
            var lines: [(rect: CGRect, range: ClosedRange<Int>)]
        }
        var groups: [Group] = []
        let sorted = lines.sorted {
            if abs($0.rect.minY - $1.rect.minY) > 0.5 { return $0.rect.minY < $1.rect.minY }
            return $0.rect.minX < $1.rect.minX
        }
        func column(_ rect: CGRect) -> Int { Int((rect.minX / 20).rounded()) }

        for line in sorted {
            var target: Int?
            for (index, group) in groups.enumerated() {
                guard let previous = group.lines.last?.rect else { continue }
                let gap = line.rect.minY - previous.maxY
                let overlaps = line.rect.minX < previous.maxX && previous.minX < line.rect.maxX
                if gap >= -0.5 && gap <= maxGap && overlaps
                    && column(previous) == column(line.rect) {
                    target = index
                    break
                }
            }
            if let target {
                groups[target].rect = groups[target].rect.union(line.rect)
                groups[target].lines.append(line)
            } else {
                groups.append(Group(rect: line.rect, lines: [line]))
            }
        }

        return groups.compactMap { group in
            let lower = group.lines.map(\.range.lowerBound).min() ?? 0
            let upper = group.lines.map(\.range.upperBound).max() ?? lower
            guard lower <= upper, lower >= 0, upper < textPage.chars.count else { return nil }
            let trimmed = trimmedRange(lower...upper, in: textPage)
            guard let trimmed else { return nil }
            let source = textPage.string(in: trimmed)
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TranslationBlock(page: page, range: trimmed, rect: group.rect,
                                    lineRects: group.lines.map(\.rect), sourceText: source,
                                    sourceFontPt: medianFont)
        }
        .sorted { lhs, rhs in
            if abs(lhs.rect.minY - rhs.rect.minY) > 0.5 { return lhs.rect.minY < rhs.rect.minY }
            return lhs.rect.minX < rhs.rect.minX
        }
    }

    /// Strip leading and trailing whitespace from a character range without changing the
    /// characters in between. The page string and the selection indices stay aligned: nothing is
    /// normalised, so the hash is a hash of the text the provider would receive.
    public static func trimmedRange(_ range: ClosedRange<Int>,
                                    in textPage: TextPage) -> ClosedRange<Int>? {
        let clamped = range.clamped(to: 0...(max(0, textPage.chars.count - 1)))
        guard !clamped.isEmpty else { return nil }
        func isWhitespace(_ index: Int) -> Bool {
            guard let scalar = Unicode.Scalar(textPage.chars[index].unicode) else { return true }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        var lower = clamped.lowerBound
        while lower <= clamped.upperBound && isWhitespace(lower) { lower += 1 }
        guard lower <= clamped.upperBound else { return nil }
        var upper = clamped.upperBound
        while upper >= lower && isWhitespace(upper) { upper -= 1 }
        guard upper >= lower else { return nil }
        return lower...upper
    }
}

/// What one explicit Translate command will translate. A paragraph block is one target; a free
/// selection is one target covering the selected lines.
public struct TranslationTarget: Equatable, Sendable {
    public let page: Int
    public let range: ClosedRange<Int>
    public let rect: CGRect
    public let lineRects: [CGRect]
    public let sourceText: String
    public let sourceFontPt: CGFloat
    public let isBlock: Bool

    public init(page: Int, range: ClosedRange<Int>, rect: CGRect, lineRects: [CGRect],
                sourceText: String, sourceFontPt: CGFloat, isBlock: Bool) {
        self.page = page
        self.range = range
        self.rect = rect
        self.lineRects = lineRects
        self.sourceText = sourceText
        self.sourceFontPt = sourceFontPt
        self.isBlock = isBlock
    }
}

public enum TranslationTargetResolver {
    /// Turn the reader's selection into one or more translation targets.
    ///
    /// If the selection's non-whitespace characters are exactly the union of one or more whole
    /// paragraph blocks, each block becomes a target (a multi-paragraph selection is a batch of
    /// block requests). Anything else — part of a paragraph, a table row, a line crossing a
    /// gutter — is a free selection and becomes one target over the selected line rectangles.
    public static func targets(page: Int, range: ClosedRange<Int>,
                               textPage: TextPage) -> [TranslationTarget] {
        guard let trimmed = TranslationBlockDetector.trimmedRange(range, in: textPage) else {
            return []
        }
        let blocks = TranslationBlockDetector.blocks(page: page, textPage: textPage)
        let selected = contentIndices(trimmed, textPage: textPage)
        var covered = Set<Int>()
        var whole: [TranslationBlock] = []
        for block in blocks where trimmed.lowerBound <= block.range.lowerBound
            && block.range.upperBound <= trimmed.upperBound {
            let indices = contentIndices(block.range, textPage: textPage)
            guard !indices.isEmpty, indices.isSubset(of: selected) else { continue }
            covered.formUnion(indices)
            whole.append(block)
        }
        if !whole.isEmpty && covered == selected {
            return whole.map { block in
                TranslationTarget(page: page, range: block.range, rect: block.rect,
                                  lineRects: block.lineRects, sourceText: block.sourceText,
                                  sourceFontPt: block.sourceFontPt, isBlock: true)
            }
        }

        let lineRects = textPage.selectionRects(in: trimmed)
        guard let first = lineRects.first else { return [] }
        let union = lineRects.dropFirst().reduce(first) { $0.union($1) }
        guard union.width > 0.5, union.height > 0.5 else { return [] }
        let source = textPage.string(in: trimmed)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let heights = lineRects.map(\.height).filter { $0 > 0 }.sorted()
        let font = heights.isEmpty ? 10 : max(7, min(18, heights[heights.count / 2]))
        return [TranslationTarget(page: page, range: trimmed, rect: union, lineRects: lineRects,
                                  sourceText: source, sourceFontPt: font, isBlock: false)]
    }

    private static func contentIndices(_ range: ClosedRange<Int>, textPage: TextPage) -> Set<Int> {
        var result = Set<Int>()
        for index in range where index >= 0 && index < textPage.chars.count {
            guard let scalar = Unicode.Scalar(textPage.chars[index].unicode) else { continue }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            if textPage.chars[index].widthPt <= 0 || textPage.chars[index].heightPt <= 0 {
                continue
            }
            result.insert(index)
        }
        return result
    }
}

// MARK: - Fit

/// The result of fitting a translation into a block.
public struct TranslationTextFit: Equatable, Sendable {
    /// The font size used, in page points at 100% zoom.
    public let fontSizePt: CGFloat
    /// Whether even the minimum size overflows; the last visible line is then ellipsised and the
    /// chip offers a disclosure with the full text.
    public let clipped: Bool
    /// Whether the fit had to search below the source font size.
    public let shrunk: Bool
    public let availableWidthPt: CGFloat
    public let availableHeightPt: CGFloat
}

public enum TranslationTextLayout {
    /// The smallest size the overlay will draw. Below 7 pt at 100% a translation is no longer
    /// readable on a printed page; at 200% zoom it is 14 pt on screen. If the text still does
    /// not fit at 7 pt it is clipped at the minimum size and the chip offers a disclosure with
    /// the full translation — chosen over a card because a card reflows the page, and over a
    /// refusal because the reader asked for this text and deserves to see as much as fits in
    /// place without changing the reading position.
    public static let minimumFontSizePt: CGFloat = 7
    public static let maximumFontSizePt: CGFloat = 18
    public static let horizontalInsetPt: CGFloat = 2
    public static let verticalInsetPt: CGFloat = 1

    public static func fit(text: String, in rect: CGRect,
                           sourceFontPt: CGFloat) -> TranslationTextFit {
        let width = max(1, rect.width - horizontalInsetPt * 2)
        let height = max(1, rect.height - verticalInsetPt * 2)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let maximum = max(minimumFontSizePt,
                          min(maximumFontSizePt, max(sourceFontPt, minimumFontSizePt)))
        guard !trimmed.isEmpty else {
            return TranslationTextFit(fontSizePt: minimumFontSizePt, clipped: false,
                                      shrunk: false, availableWidthPt: width,
                                      availableHeightPt: height)
        }

        func measuredHeight(_ size: CGFloat) -> CGFloat {
            let font = NSFont.systemFont(ofSize: size)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineSpacing = 0
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .paragraphStyle: paragraph,
            ]
            let attributed = NSAttributedString(string: trimmed, attributes: attributes)
            return attributed.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height
        }

        let maximumHeight = measuredHeight(maximum)
        if maximumHeight <= height + 0.01 {
            return TranslationTextFit(fontSizePt: maximum, clipped: false,
                                      shrunk: maximum < sourceFontPt,
                                      availableWidthPt: width, availableHeightPt: height)
        }
        let minimumHeight = measuredHeight(minimumFontSizePt)
        if minimumHeight > height + 0.01 {
            return TranslationTextFit(fontSizePt: minimumFontSizePt, clipped: true,
                                      shrunk: minimumFontSizePt < sourceFontPt,
                                      availableWidthPt: width, availableHeightPt: height)
        }
        var low = minimumFontSizePt
        var high = maximum
        for _ in 0..<18 {
            let middle = (low + high) / 2
            if measuredHeight(middle) <= height + 0.01 { low = middle } else { high = middle }
        }
        // Whole quarter-points are stable across a re-layout and avoid a size like 9.8734 pt
        // appearing in the overlay diagnostics.
        let size = (floor(low * 4) / 4)
        return TranslationTextFit(fontSizePt: size, clipped: false, shrunk: true,
                                  availableWidthPt: width, availableHeightPt: height)
    }
}

// MARK: - Runtime presentation

/// What the canvas draws for one translated block.
public enum TranslationOverlayPhase: Equatable, Sendable {
    /// A request is in flight. No cover is drawn, so cancelling leaves the page clean.
    case translating
    /// The translation covers the source block.
    case translated
    /// The source is visible again; the cached translation remains one click away.
    case original
    /// The request failed. No cover is drawn; the chip offers a retry.
    case failed(String)
}

public struct TranslationOverlay: Identifiable, Equatable, Sendable {
    public let id: String
    public let page: Int
    public let rect: CGRect
    public let sourceText: String
    public let translatedText: String?
    public let phase: TranslationOverlayPhase
    public let range: ClosedRange<Int>?
    public let isBlock: Bool
    public let sourceFontPt: CGFloat
    public let fit: TranslationTextFit?
    public let isClipped: Bool
    public let paperColor: TranslationPaperColor?

    public var isTranslating: Bool { phase == .translating }
    public var isTranslated: Bool { phase == .translated }
    public var isOriginal: Bool { phase == .original }

    public init(id: String, page: Int, rect: CGRect, sourceText: String,
                translatedText: String?, phase: TranslationOverlayPhase,
                range: ClosedRange<Int>?, isBlock: Bool, sourceFontPt: CGFloat,
                fit: TranslationTextFit?, paperColor: TranslationPaperColor?) {
        self.id = id
        self.page = page
        self.rect = rect
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.phase = phase
        self.range = range
        self.isBlock = isBlock
        self.sourceFontPt = sourceFontPt
        self.fit = fit
        self.isClipped = fit?.clipped == true
        self.paperColor = paperColor
    }

    public func intersects(selection: ClosedRange<Int>) -> Bool {
        guard let range else { return false }
        return range.overlaps(selection)
    }
}

// MARK: - Paper sampling

public enum TranslationPaperSampler {
    /// Sample the paper of a whole-page raster.
    ///
    /// Four corner patches and the centre of the top margin are sampled; the most common
    /// quantised colour wins. Taking the *mode* rather than an average keeps a stray stamp or a
    /// coloured header from tinting the whole cover. Transparency (outside the crop) is ignored.
    public static func paperColor(from image: PageImage) -> TranslationPaperColor? {
        guard image.pixelWidth > 1, image.pixelHeight > 1, image.bgra.count >= 4 else { return nil }
        let width = image.pixelWidth
        let height = image.pixelHeight
        let stride = width * 4
        var counts: [UInt32: Int] = [:]
        func sample(x: Int, y: Int) {
            let px = min(max(0, x), width - 1)
            let py = min(max(0, y), height - 1)
            let offset = py * stride + px * 4
            guard offset + 3 < image.bgra.count else { return }
            let b = UInt32(image.bgra[offset])
            let g = UInt32(image.bgra[offset + 1])
            let r = UInt32(image.bgra[offset + 2])
            let a = UInt32(image.bgra[offset + 3])
            guard a > 16 else { return }
            // 8-level quantisation: paper colours differ by a few counts across a raster, and
            // exact byte equality would make the mode unstable.
            let key = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)
            counts[key, default: 0] += 1
        }
        let patch = max(2, min(width, height) / 80)
        for (x, y) in [(patch, patch), (width - patch, patch),
                       (patch, height - patch), (width - patch, height - patch),
                       (width / 2, patch), (width / 2, height / 2)] {
            for dx in -patch...patch {
                for dy in -patch...patch {
                    sample(x: x + dx, y: y + dy)
                }
            }
        }
        guard let key = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let r = UInt8(((key >> 10) & 0x1F) << 3)
        let g = UInt8(((key >> 5) & 0x1F) << 3)
        let b = UInt8((key & 0x1F) << 3)
        // Restore the middle of the quantisation bucket rather than its floor.
        func midpoint(_ value: UInt8) -> UInt8 { value == 0 ? 0 : min(255, value + 4) }
        return TranslationPaperColor(red: midpoint(r), green: midpoint(g), blue: midpoint(b))
    }
}
