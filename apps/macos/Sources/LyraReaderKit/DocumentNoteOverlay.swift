import AppKit
import SwiftUI

/// A screen-sized piece of paper that stays attached to the note as the document moves.
struct DocumentNoteOverlay: View {
    @ObservedObject var state: AppState

    var body: some View {
        GeometryReader { geometry in
            if let note = state.openDocumentNote,
               let anchor = state.documentNoteAnchor(note),
               anchor.intersects(CGRect(origin: .zero, size: geometry.size)) {
                let frame = DocumentNoteLayout.frame(anchor: anchor, viewport: geometry.size)
                VStack(spacing: 0) {
                    HStack {
                        Text(note.author.flatMap { $0.isEmpty ? nil : $0 } ?? "Note")
                            .font(.headline).lineLimit(1)
                        Spacer()
                        Button { state.closeDocumentNote() } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close note")
                    }
                    .padding(12)
                    Divider()
                    NotePaperText(text: note.contents ?? "")
                        .padding(8)
                }
                .foregroundStyle(LyraReaderTheme.noteFg)
                .frame(width: frame.width, height: frame.height)
                .background(LyraReaderTheme.noteBg)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(LyraReaderTheme.border))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                .position(x: frame.midX, y: frame.midY)
                .id(note.id)
            }
        }
    }
}

public enum DocumentNoteLayout {
    public static let size = CGSize(width: 280, height: 220)

    public static func frame(anchor: CGRect, viewport: CGSize) -> CGRect {
        let margin: CGFloat = 8
        let x = anchor.maxX + margin + size.width <= viewport.width - margin
            ? anchor.maxX + margin : anchor.minX - margin - size.width
        return CGRect(x: max(margin, min(x, viewport.width - size.width - margin)),
                      y: max(margin, min(anchor.minY, viewport.height - size.height - margin)),
                      width: size.width, height: size.height)
    }
}

/// Always show a vertical scrollbar, including when macOS normally hides overlay scrollers.
/// This native scroll view consumes wheel input over the paper without scrolling the PDF.
struct NotePaperText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .legacy
        scroll.drawsBackground = false
        let body = NSTextView(frame: scroll.contentView.bounds)
        body.isEditable = false
        body.isSelectable = true
        body.drawsBackground = false
        body.font = .systemFont(ofSize: 13)
        body.textColor = LyraReaderTheme.noteTextColor
        body.textContainerInset = CGSize(width: 4, height: 6)
        body.isVerticallyResizable = true
        body.isHorizontallyResizable = false
        body.autoresizingMask = [.width]
        body.textContainer?.widthTracksTextView = true
        body.textContainer?.containerSize = CGSize(width: scroll.contentSize.width,
                                                  height: .greatestFiniteMagnitude)
        scroll.documentView = body
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let body = scroll.documentView as? NSTextView, body.string != text else { return }
        body.string = text
        body.scrollToBeginningOfDocument(nil)
    }
}
