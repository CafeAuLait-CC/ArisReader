import AppKit
import CoreText

/// Text-box editing, sizing and its page glyph use the same face embedded by the PDF writer.
@MainActor package enum AnnotationTextFont {
    private static let descriptor: CTFontDescriptor? = {
        let bundled = Bundle.main.url(forResource: "LyraReaderSansSC-Regular", withExtension: "ttf", subdirectory: "Fonts")
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Fonts/LyraReaderSansSC-Regular.ttf")
        guard let url = bundled ?? (FileManager.default.fileExists(atPath: development.path) ? development : nil),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
        else { return nil }
        return descriptors.first
    }()

    package static func font(size: CGFloat) -> NSFont {
        guard let descriptor else { return .systemFont(ofSize: size) }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
    }
    package static func padding(size: CGFloat) -> CGFloat { min(6, max(1, size * 0.15)) }

    /// The advance width of one line in the bundled font, with kerning off.
    ///
    /// The PDF appearance uses the same font's advances; keeping kerning at zero is what makes
    /// the canvas badge and the written stamp agree about where the words end.
    package static func measure(_ text: String, size: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: font(size: size), .kern: 0]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// The font size a stamp's one line is drawn at, shared by the canvas and the PDF writer.
    ///
    /// The words fill at most 42% of the medal's height and always fit inside its inner border;
    /// a long word is shrunk rather than clipped. `width` and `height` are page points.
    package static func stampFontSize(_ text: String, width: CGFloat, height: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 2 }
        let available = width - 12
        guard available > 1 else { return 2 }
        var size = min(max(height * 0.42, 2), 200)
        let measured = measure(text, size: size)
        if measured > available {
            size *= available / measured
        }
        return max(size, 2)
    }
}
