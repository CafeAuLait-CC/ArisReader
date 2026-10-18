import AppKit
import CoreText

/// Text-box editing, sizing and its page glyph use the same face embedded by the PDF writer.
@MainActor enum AnnotationTextFont {
    private static let descriptor: CTFontDescriptor? = {
        let bundled = Bundle.main.url(forResource: "LyraSansSC-Regular", withExtension: "ttf", subdirectory: "Fonts")
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Fonts/LyraSansSC-Regular.ttf")
        guard let url = bundled ?? (FileManager.default.fileExists(atPath: development.path) ? development : nil),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
        else { return nil }
        return descriptors.first
    }()

    static func font(size: CGFloat) -> NSFont {
        guard let descriptor else { return .systemFont(ofSize: size) }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
    }
    static func padding(size: CGFloat) -> CGFloat { min(6, max(1, size * 0.15)) }
}
