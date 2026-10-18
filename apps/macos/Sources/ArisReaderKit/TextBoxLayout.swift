import AppKit

/// The editing field and the saved glyph share PDF-point metrics and a transparent background.
@MainActor package enum TextBoxLayout {
    package static func fittedRect(text: String, fontSize: CGFloat, origin: CGPoint,
                                   maximumWidth: CGFloat, maximumHeight: CGFloat) -> CGRect {
        let font = AnnotationTextFont.font(size: fontSize)
        let padding = AnnotationTextFont.padding(size: fontSize) * 2
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: 0]
        let natural = (text.isEmpty ? " " : text) as NSString
        let width = min(maximumWidth, max(AppState.Annotation.minimumTextBoxSize.width, ceil(natural.size(withAttributes: attributes).width + padding + 1)))
        let measured = natural.boundingRect(with: CGSize(width: max(1, width - padding), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
        let height = min(maximumHeight, max(AppState.Annotation.minimumTextBoxSize.height, ceil(measured.height + padding)))
        return CGRect(origin: origin, size: CGSize(width: max(1, width), height: max(1, height)))
    }
}
