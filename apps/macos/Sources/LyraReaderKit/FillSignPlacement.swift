import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// What the Fill & Sign row arms: one placement that the next click on the page commits.
///
/// Everything here is a *placement*, not a tool: the row item does not change what a drag
/// means. The canvas reads one of these, places the mark centred on the click, and returns to
/// the pointer. Text is the exception that still arms the text-box tool: its click is a
/// double-click everywhere else in the reader, and Fill & Sign keeps that edit surface.
public enum FillSignPlacement: Equatable, Sendable {
    /// A text box. Arming this also arms the text-box tool; the click commit opens its editor.
    case text
    /// A text box pre-filled with today's date in the user's medium date style.
    case date
    /// A vector check mark drawn as two ink strokes.
    case checkmark
    /// A vector cross drawn as two ink strokes.
    case cross
    /// Hand-drawn signature strokes, normalised to a 0…1 box with a known aspect ratio.
    case drawnSignature(DrawnSignature)
}

/// A date rendered the way the reader's locale writes a date: `.medium` style, no time.
///
/// The style is chosen in the Fill & Sign inspector; ``FillSignDateFormat`` carries the four
/// styles. This type stays the historical medium-style entry point because the checks and the
/// app's date copy already use it.
public enum FillSignDate {
    /// Today's date in the current locale, medium style (for example "Oct 24, 2026").
    public static func mediumString(
        for date: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        FillSignDateFormat.medium.string(for: date, locale: locale, timeZone: timeZone)
    }
}

/// Renders the Date tool's text into a transparent PNG at a chosen rotation.
///
/// A rotated date is placed through the reader's existing image `/Stamp` path: the appearance
/// stream is the picture, so every viewer paints the same orientation. A 0° date keeps the
/// editable text box instead (see ``AppState/placeDateTextBox(atContentPoint:date:)``).
public enum FillSignDatePictureRenderer {
    /// The page-point font size the picture is rendered for.
    public static let fontSizePt: CGFloat = 14

    /// The page-point height a rotated date picture is placed at.
    ///
    /// The picture's pixel height is the measured text's width for a quarter turn and its
    /// height for a half turn, so scaling by the pixel aspect reproduces the real text size
    /// instead of shrinking a landscape date into a few points.
    public static func placementHeight(
        text: String,
        rotation: FillSignDateRotation,
        fontSize: CGFloat = fontSizePt
    ) -> CGFloat {
        let measured = (text as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)])
        let padding: CGFloat = 4
        switch rotation {
        case .quarter, .threeQuarters: return ceil(measured.width) + padding
        case .none, .half: return ceil(measured.height) + padding
        }
    }

    /// A transparent PNG of `text`, rotated clockwise by `rotation` degrees.
    public static func pngData(
        text: String,
        rotation: FillSignDateRotation,
        fontSize: CGFloat = fontSizePt,
        scale: CGFloat = 2
    ) -> Data? {
        guard !text.isEmpty, scale > 0 else { return nil }
        let font = NSFont.systemFont(ofSize: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]
        let string = text as NSString
        let measured = string.size(withAttributes: attributes)
        let padding: CGFloat = 2
        let width = ceil(measured.width) + padding * 2
        let height = ceil(measured.height) + padding * 2
        let quarterTurn = rotation == .quarter || rotation == .threeQuarters
        let canvas = CGSize(width: quarterTurn ? height : width,
                            height: quarterTurn ? width : height)
        let pixelWidth = max(1, Int((canvas.width * scale).rounded()))
        let pixelHeight = max(1, Int((canvas.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = canvas
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        guard let context = NSGraphicsContext.current?.cgContext else { return nil }
        context.clear(CGRect(origin: .zero, size: canvas))
        context.saveGState()
        context.translateBy(x: canvas.width / 2, y: canvas.height / 2)
        context.rotate(by: -CGFloat(rotation.rawValue) * .pi / 180)
        string.draw(at: CGPoint(x: -measured.width / 2, y: -measured.height / 2),
                    withAttributes: attributes)
        context.restoreGState()
        return rep.representation(using: .png, properties: [:])
    }
}

/// A preview of hand-drawn signature strokes for the Fill & Sign inspector.
public enum DrawnSignaturePreview {
    /// The strokes drawn into a transparent image with the same y-down orientation they have in
    /// the annotation cache.
    public static func image(
        _ signature: DrawnSignature,
        size: CGSize = CGSize(width: 240, height: 90)
    ) -> NSImage? {
        guard !signature.isEmpty, size.width > 1, size.height > 1 else { return nil }
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.black.setStroke()
        for stroke in signature.strokes where stroke.count >= 2 {
            let path = NSBezierPath()
            path.lineWidth = 2
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: CGPoint(x: stroke[0].x * size.width,
                                  y: (1 - stroke[0].y) * size.height))
            for point in stroke.dropFirst() {
                path.line(to: CGPoint(x: point.x * size.width,
                                      y: (1 - point.y) * size.height))
            }
            path.stroke()
        }
        return image
    }
}

/// A vector mark placed by Fill & Sign, in page points around the click point.
///
/// These are deliberately **ink strokes**, not text glyphs: the reader does not need a font that
/// carries U+2713 or U+2717, every viewer can draw `/Ink`, and the mark keeps the annotation
/// colour the reader chose. Each mark is one annotation with two strokes, so undo removes the
/// whole mark in one step.
public enum FillSignMark: String, CaseIterable, Sendable {
    case checkmark
    case cross

    public var title: String {
        switch self {
        case .checkmark: return "Checkmark"
        case .cross: return "Cross"
        }
    }

    /// The stroke width in page points. Three points reads at 100% on a page whose body text is
    /// around ten points without competing with it.
    public var strokeWidth: CGFloat { 3 }

    /// The marks' page-space extent at 100%, in points.
    public var size: CGSize {
        switch self {
        case .checkmark: return CGSize(width: 20, height: 15)
        case .cross: return CGSize(width: 16, height: 16)
        }
    }

    /// The two strokes, relative to a centre at `(0, 0)`, in the cache's top-left page space
    /// (y grows down). The elbow of the check is shared by both strokes, so the mark reads as
    /// one pen gesture even though it is stored as two.
    public var unitStrokes: [[CGPoint]] {
        switch self {
        case .checkmark:
            return [
                [CGPoint(x: -10, y: 0), CGPoint(x: -3.5, y: 6.5)],
                [CGPoint(x: -3.5, y: 6.5), CGPoint(x: 10, y: -7.5)],
            ]
        case .cross:
            return [
                [CGPoint(x: -8, y: -8), CGPoint(x: 8, y: 8)],
                [CGPoint(x: -8, y: 8), CGPoint(x: 8, y: -8)],
            ]
        }
    }

    /// The two strokes around `center` in page space.
    public func strokes(centeredAt center: CGPoint) -> [[CGPoint]] {
        unitStrokes.map { stroke in
            stroke.map { CGPoint(x: center.x + $0.x, y: center.y + $0.y) }
        }
    }
}

/// Hand-drawn signature strokes, normalised so the mark can be placed at any size.
///
/// `strokes` live in a 0…1 box: x runs left to right, y runs **down** (the same top-left space
/// the annotation cache uses). `aspect` is the width divided by the height of the drawn box, so
/// a wide signature is not squashed into a square when it is placed.
public struct DrawnSignature: Equatable, Sendable {
    public var strokes: [[CGPoint]]
    public var aspect: CGFloat

    public init(strokes: [[CGPoint]], aspect: CGFloat) {
        self.strokes = strokes
        self.aspect = aspect
    }

    public var isEmpty: Bool { strokes.allSatisfy { $0.count < 2 } }
}

/// Renders a typed name into a transparent PNG in a built-in macOS handwriting font.
///
/// No font asset is added: the names below are system fonts, checked at runtime. The picture is
/// only a picture of a signature — the dialog and the menu both say so.
public enum TypedSignatureRenderer {
    /// In order of preference. All three ship with macOS; the first available wins.
    public static let preferredFontNames = ["Snell Roundhand", "Bradley Hand", "Noteworthy"]

    /// The font names that exist on this Mac, in preference order. Never empty in practice;
    /// `resolveFontName` still has a fallback.
    public static var availableFontNames: [String] {
        preferredFontNames.filter { NSFont(name: $0, size: 24) != nil }
    }

    /// The first available handwriting font at `size`, preferring `requested` when it exists.
    public static func resolveFont(_ requested: String? = nil, size: CGFloat = 24) -> NSFont? {
        if let requested, let font = NSFont(name: requested, size: size) { return font }
        for name in availableFontNames {
            if let font = NSFont(name: name, size: size) { return font }
        }
        return nil
    }

    /// The name of the font `resolveFont` would use, for the dialog's popup and for checks.
    public static func resolvedFontName(_ requested: String? = nil) -> String? {
        if let requested, NSFont(name: requested, size: 24) != nil { return requested }
        return availableFontNames.first
    }

    /// A PNG with a transparent background and the name in black handwriting.
    ///
    /// The glyphs are drawn through Core Text at `scale` times the logical size: 2× keeps the
    /// strokes crisp when the annotation is zoomed and is still a small file. Only the glyph
    /// bounds are cropped, with a small padding so the ink is not touched by the image edge.
    public static func pngData(
        name: String,
        fontName: String? = nil,
        pointSize: CGFloat = 72,
        scale: CGFloat = 2
    ) -> Data? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let font = resolveFont(fontName, size: pointSize) else { return nil }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.black.cgColor,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: trimmed, attributes: attributes))
        let glyphBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        guard glyphBounds.width > 0, glyphBounds.height > 0 else { return nil }
        let padding: CGFloat = 14
        let logicalWidth = ceil(glyphBounds.width + padding * 2)
        let logicalHeight = ceil(glyphBounds.height + padding * 2)
        let safeScale = max(1, scale)
        let width = max(1, Int((logicalWidth * safeScale).rounded()))
        let height = max(1, Int((logicalHeight * safeScale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: safeScale, y: safeScale)
        context.textPosition = CGPoint(x: padding - glyphBounds.minX,
                                       y: padding - glyphBounds.minY)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
