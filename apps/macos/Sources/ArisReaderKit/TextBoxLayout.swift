import AppKit

/// The editing field and the saved glyph share PDF-point metrics and a transparent background.
///
/// A text box is **auto-sized to its text** and does not wrap: its width follows the longest
/// line and its height follows the number of lines. The only exception is the page edge — a line
/// that would run off the page is wrapped at the available width rather than clipped, so even a
/// pathological single line stays readable.
///
/// A box is created by a double-click at a point: the point is the box's **top-left corner**, so
/// the caret is exactly where the click landed and the box grows to the right and down, into the
/// empty space beside the text the reader clicked next to. Centring the box on the click would
/// put half of it over that text.
@MainActor package enum TextBoxLayout {
    /// The text whose width a new box starts with: three average Latin characters.
    ///
    /// The user report asks for "about two to three characters wide"; measuring a real string in
    /// the box's own font (rather than hard-coding points) keeps that promise if the font or the
    /// size changes.
    package static let creationSample = "abc"

    /// One line box of `fontSize`, in points.
    ///
    /// `ascender - descender + leading` is the line box CoreText lays the glyphs out in. Using it
    /// (rather than the integer `NSLayoutManager.defaultLineHeight`) is what keeps a multi-line
    /// appearance from clipping its last line as the line count grows.
    package static func lineHeight(fontSize: CGFloat) -> CGFloat {
        let font = AnnotationTextFont.font(size: max(1, fontSize))
        return font.ascender - font.descender + font.leading
    }

    /// The width a freshly placed box starts with, in points.
    package static func creationWidth(fontSize: CGFloat) -> CGFloat {
        let font = AnnotationTextFont.font(size: max(1, fontSize))
        let padding = AnnotationTextFont.padding(size: fontSize) * 2
        let sample = creationSample as NSString
        let textWidth = sample.size(withAttributes: [.font: font, .kern: 0]).width
        return max(1, ceil(textWidth + padding + 1))
    }

    /// The height a freshly placed box starts with: one line plus padding.
    package static func creationHeight(fontSize: CGFloat) -> CGFloat {
        ceil(lineHeight(fontSize: fontSize) + AnnotationTextFont.padding(size: fontSize) * 2)
    }

    package static func creationSize(fontSize: CGFloat) -> CGSize {
        CGSize(width: creationWidth(fontSize: fontSize),
               height: creationHeight(fontSize: fontSize))
    }

    /// The rectangle a box with `text` needs.
    ///
    /// The width floor is the same three-character width a new box starts with, so the first
    /// keystrokes never shrink or grow the box; after that the longest line wins and deleting
    /// characters brings the box back down. `maximumWidth`/`maximumHeight` are the room left on
    /// the page: a line that cannot fit is wrapped at the available width, every other line
    /// keeps one line per paragraph.
    package static func fittedRect(text: String, fontSize: CGFloat, origin: CGPoint,
                                   maximumWidth: CGFloat, maximumHeight: CGFloat) -> CGRect {
        let font = AnnotationTextFont.font(size: max(1, fontSize))
        let padding = AnnotationTextFont.padding(size: fontSize) * 2
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: 0]
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Width follows the longest line. Measuring each paragraph separately avoids relying on
        // what `NSString.size` does with embedded newlines, and keeps an empty box at its floor.
        var longest: CGFloat = 0
        for paragraph in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(paragraph)
            guard !line.isEmpty else { continue }
            let width = (line as NSString).size(withAttributes: attributes).width
            longest = max(longest, width)
        }
        let naturalWidth = ceil(longest + padding + 1)
        let widthFloor = max(AppState.Annotation.minimumTextBoxSize.width,
                             creationWidth(fontSize: fontSize))
        let width = max(1, min(maximumWidth, max(widthFloor, naturalWidth)))

        // Height follows the number of laid-out lines. `boundingRect` reports the line count the
        // same way for explicit Returns and for the page-edge wrap; one CoreText line box per
        // fragment is then added to the padding. An empty box still needs one line's height.
        let measuredText = (normalized.isEmpty ? " " : normalized) as NSString
        let measured = measuredText.boundingRect(
            with: CGSize(width: max(1, width - padding), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes)
        let fragmentLineHeight = max(1, NSLayoutManager().defaultLineHeight(for: font))
        let fragments = max(1, Int(ceil(measured.height / fragmentLineHeight)))
        let neededHeight = ceil(CGFloat(fragments) * lineHeight(fontSize: fontSize) + padding)
        let height = max(1, min(maximumHeight, max(creationHeight(fontSize: fontSize), neededHeight)))

        return CGRect(origin: origin, size: CGSize(width: max(1, width), height: height))
    }
}
