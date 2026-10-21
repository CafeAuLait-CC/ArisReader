import AppKit
import SwiftUI

/// Renders a parsed answer with the app's normal reading typography.
///
/// Paragraphs, headings, list items and table cells go through a small `NSTextView` so inline
/// mathematics can be a real text attachment: it wraps, sits on the baseline and scrolls with
/// the text instead of forcing every paragraph into a row of fixed-size views. Code blocks keep
/// their whitespace; tables use a `Grid`; display mathematics is a centred image with a
/// monospace fallback. Nothing here interprets HTML.
public struct ReaderMarkdownView: View {
    public let document: ReaderMarkdownDocument
    public let pageCount: Int
    public let onJump: (Int) -> Void

    public init(
        document: ReaderMarkdownDocument,
        pageCount: Int,
        onJump: @escaping (Int) -> Void = { _ in }
    ) {
        self.document = document
        self.pageCount = pageCount
        self.onJump = onJump
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: ReaderMarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let inlines):
            ReaderMarkdownInlineText(
                inlines: inlines,
                pageCount: pageCount,
                fontSize: level == 1 ? 17 : (level == 2 ? 14.5 : 13),
                weight: level <= 2 ? .bold : .semibold,
                onJump: onJump
            )
            .padding(.top, level == 1 ? 4 : 2)

        case .paragraph(let inlines):
            ReaderMarkdownInlineText(
                inlines: inlines,
                pageCount: pageCount,
                fontSize: 13,
                onJump: onJump
            )

        case .bullet(let depth, let inlines):
            HStack(alignment: .top, spacing: 5) {
                Text(depth == 0 ? "•" : "◦")
                    .font(.system(size: 13))
                    .foregroundStyle(LyraReaderTheme.textSecondary)
                    .frame(width: 10, alignment: .leading)
                    .padding(.top, 1)
                ReaderMarkdownInlineText(
                    inlines: inlines,
                    pageCount: pageCount,
                    fontSize: 13,
                    onJump: onJump
                )
            }
            .padding(.leading, CGFloat(depth) * 14)

        case .numbered(let depth, let number, let inlines):
            HStack(alignment: .top, spacing: 5) {
                Text("\(number).")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(LyraReaderTheme.textSecondary)
                    .frame(width: 22, alignment: .trailing)
                    .padding(.top, 0.5)
                ReaderMarkdownInlineText(
                    inlines: inlines,
                    pageCount: pageCount,
                    fontSize: 13,
                    onJump: onJump
                )
            }
            .padding(.leading, CGFloat(depth) * 14)

        case .quote(let blocks):
            ReaderMarkdownView(document: ReaderMarkdownDocument(blocks: blocks),
                               pageCount: pageCount, onJump: onJump)
                .foregroundStyle(LyraReaderTheme.textSecondary)
                .padding(.leading, 10)
                .padding(.vertical, 1)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(LyraReaderTheme.separator)
                        .frame(width: 2)
                }

        case .code(let language, let source):
            VStack(alignment: .leading, spacing: 4) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(LyraReaderTheme.textTertiary)
                }
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(source.isEmpty ? " " : source)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(LyraReaderTheme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(7)
                }
                .background(LyraReaderTheme.raisedBg,
                            in: RoundedRectangle(cornerRadius: 4))
            }

        case .table(let headers, let alignments, let rows):
            ReaderMarkdownTable(headers: headers, alignments: alignments, rows: rows,
                                pageCount: pageCount, onJump: onJump)

        case .mathBlock(let source, let reason):
            ReaderMathBlockView(source: source, reason: reason)

        case .divider:
            Divider().overlay(LyraReaderTheme.separator)
        }
    }
}

/// The panel's answer view, now backed by the shared renderer. Its public signature is unchanged
/// so the document chat and the single-shot actions get the same Markdown and mathematics.
public struct AIAnswerView: View {
    public let text: String
    public let pageCount: Int
    public var verifiedPages: Set<Int>? = nil
    public let onJump: (Int) -> Void

    public init(
        text: String,
        pageCount: Int,
        verifiedPages: Set<Int>? = nil,
        onJump: @escaping (Int) -> Void
    ) {
        self.text = text
        self.pageCount = pageCount
        self.verifiedPages = verifiedPages
        self.onJump = onJump
    }

    public var body: some View {
        ReaderMarkdownView(
            document: ReaderMarkdown.parse(
                text, pageCount: pageCount, verifiedPages: verifiedPages
            ),
            pageCount: pageCount,
            onJump: onJump
        )
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "lyra-reader-page",
                  let host = url.host,
                  let page = Int(host),
                  page >= 1, page <= pageCount else {
                return .systemAction
            }
            onJump(page)
            return .handled
        })
    }
}

// MARK: - Inline text

/// A selectable, wrapping attributed paragraph with inline-math attachments.
public struct ReaderMarkdownInlineText: NSViewRepresentable {
    let inlines: [ReaderMarkdownInline]
    let pageCount: Int
    let fontSize: CGFloat
    var weight: NSFont.Weight = .regular
    let onJump: (Int) -> Void

    public func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isRichText = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        textView.delegate = context.coordinator
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    public func updateNSView(_ nsView: NSTextView, context: Context) {
        context.coordinator.onJump = onJump
        let attributed = ReaderMarkdownAttributed.build(
            inlines: inlines,
            pageCount: pageCount,
            fontSize: fontSize,
            weight: weight
        )
        if !nsView.attributedString().isEqual(to: attributed) {
            nsView.textStorage?.setAttributedString(attributed)
        }
    }

    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSTextView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        guard width.isFinite, width > 1 else { return nil }
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else {
            return nil
        }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: width, height: max(1, ceil(used.height)))
    }

    public func makeCoordinator() -> Coordinator { Coordinator(onJump: onJump) }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var onJump: (Int) -> Void

        init(onJump: @escaping (Int) -> Void) {
            self.onJump = onJump
        }

        public func textView(
            _ textView: NSTextView,
            clickedOnLink link: Any,
            at charIndex: Int
        ) -> Bool {
            guard let url = link as? URL else { return false }
            if url.scheme == "lyra-reader-page", let host = url.host, let page = Int(host) {
                onJump(page)
                return true
            }
            guard let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme) else {
                return true
            }
            NSWorkspace.shared.open(url)
            return true
        }
    }
}

enum ReaderMarkdownAttributed {
    static func build(
        inlines: [ReaderMarkdownInline],
        pageCount: Int,
        fontSize: CGFloat,
        weight: NSFont.Weight = .regular
    ) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: fontSize, weight: weight)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 0
        let output = NSMutableAttributedString()
        append(inlines, to: output, base: base, paragraph: paragraph, color: .labelColor)
        return output
    }

    private static func append(
        _ inlines: [ReaderMarkdownInline],
        to output: NSMutableAttributedString,
        base: NSFont,
        paragraph: NSParagraphStyle,
        color: NSColor
    ) {
        for inline in inlines {
            switch inline {
            case .text(let text):
                output.append(NSAttributedString(string: text, attributes: [
                    .font: base, .foregroundColor: color, .paragraphStyle: paragraph,
                ]))
            case .bold(let runs):
                append(runs, to: output, base: FontTrait.bold(base), paragraph: paragraph,
                       color: color)
            case .italic(let runs):
                append(runs, to: output, base: FontTrait.italic(base), paragraph: paragraph,
                       color: color)
            case .strikethrough(let runs):
                let start = output.length
                append(runs, to: output, base: base, paragraph: paragraph, color: color)
                output.addAttribute(.strikethroughStyle,
                                    value: NSUnderlineStyle.single.rawValue,
                                    range: NSRange(location: start, length: output.length - start))
            case .code(let text):
                let codeFont = NSFont.monospacedSystemFont(ofSize: max(9, base.pointSize - 1),
                                                           weight: .regular)
                output.append(NSAttributedString(string: text, attributes: [
                    .font: codeFont,
                    .foregroundColor: color,
                    .backgroundColor: NSColor.textBackgroundColor.withAlphaComponent(0.55),
                    .paragraphStyle: paragraph,
                ]))
            case .link(let runs, let destination):
                let start = output.length
                append(runs, to: output, base: base, paragraph: paragraph, color: color)
                guard let url = URL(string: destination) else { continue }
                let range = NSRange(location: start, length: output.length - start)
                output.addAttributes([
                    .link: url,
                    .foregroundColor: NSColor.controlAccentColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ], range: range)
            case .citation(let page, let raw):
                output.append(NSAttributedString(string: raw, attributes: [
                    .font: base,
                    .link: URL(string: "lyra-reader-page://\(page)")!,
                    .foregroundColor: NSColor.controlAccentColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .paragraphStyle: paragraph,
                ]))
            case .math(let source):
                appendMath(source, to: output, base: base, paragraph: paragraph)
            case .mathFallback(let source, let reason):
                appendMathFallback(source, reason: reason, to: output, base: base,
                                   paragraph: paragraph)
            }
        }
    }

    private static func appendMath(
        _ source: String,
        to output: NSMutableAttributedString,
        base: NSFont,
        paragraph: NSParagraphStyle
    ) {
        switch ReaderMathRenderer.render(source, fontSize: base.pointSize * 0.96) {
        case .success(let rendered):
            let attachment = NSTextAttachment()
            attachment.image = rendered.image
            attachment.bounds = CGRect(
                x: 0,
                y: -rendered.descent,
                width: rendered.size.width,
                height: rendered.size.height
            )
            let string = NSMutableAttributedString(attachment: attachment)
            string.addAttribute(.paragraphStyle, value: paragraph,
                                range: NSRange(location: 0, length: string.length))
            output.append(string)
        case .failure(let error):
            appendMathFallback(source, reason: error.localizedDescription, to: output,
                               base: base, paragraph: paragraph)
        }
    }

    private static func appendMathFallback(
        _ source: String,
        reason: String,
        to output: NSMutableAttributedString,
        base: NSFont,
        paragraph: NSParagraphStyle
    ) {
        let mono = NSFont.monospacedSystemFont(ofSize: max(9, base.pointSize - 1),
                                               weight: .regular)
        output.append(NSAttributedString(string: source, attributes: [
            .font: mono,
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.textBackgroundColor.withAlphaComponent(0.55),
            .paragraphStyle: paragraph,
            .toolTip: reason,
        ]))
    }
}

private enum FontTrait {
    static func bold(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    static func italic(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }
}

// MARK: - Tables and display math

private struct ReaderMarkdownTable: View {
    let headers: [[ReaderMarkdownInline]]
    let alignments: [ReaderMarkdownAlignment]
    let rows: [[[ReaderMarkdownInline]]]
    let pageCount: Int
    let onJump: (Int) -> Void

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { column, cell in
                    cellView(cell, column: column, header: true)
                }
            }
            GridRow {
                Divider()
                    .gridCellUnsizedAxes(.horizontal)
                    .gridCellColumns(max(1, headers.count))
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        cellView(cell, column: column, header: false)
                    }
                }
            }
        }
        .padding(8)
        .background(LyraReaderTheme.raisedBg, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .strokeBorder(LyraReaderTheme.separator, lineWidth: 0.5))
    }

    private func cellView(
        _ cell: [ReaderMarkdownInline],
        column: Int,
        header: Bool
    ) -> some View {
        ReaderMarkdownInlineText(
            inlines: cell,
            pageCount: pageCount,
            fontSize: header ? 11.5 : 11.5,
            weight: header ? .semibold : .regular,
            onJump: onJump
        )
        .frame(minWidth: 24, alignment: alignment(column))
    }

    private func alignment(_ column: Int) -> Alignment {
        let value = column < alignments.count ? alignments[column] : .leading
        switch value {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

private struct ReaderMathBlockView: View {
    let source: String
    let reason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let reason {
                Text("Could not render this expression: \(reason)")
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.warningFg)
                    .fixedSize(horizontal: false, vertical: true)
                Text(source)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LyraReaderTheme.raisedBg,
                                in: RoundedRectangle(cornerRadius: 4))
            } else {
                switch ReaderMathRenderer.render(source, fontSize: 17, display: true) {
                case .success(let rendered):
                    HStack {
                        Spacer(minLength: 0)
                        Image(nsImage: rendered.image)
                            .accessibilityLabel("Mathematics: \(source)")
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                case .failure(let error):
                    Text("Could not render this expression: \(error.localizedDescription)")
                        .font(.caption2)
                        .foregroundStyle(LyraReaderTheme.warningFg)
                    Text(source)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LyraReaderTheme.raisedBg,
                                    in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .contextMenu {
            Button("Copy LaTeX source") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source, forType: .string)
            }
        }
    }
}
