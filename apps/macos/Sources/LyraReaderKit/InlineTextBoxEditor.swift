import AppKit
import SwiftUI

/// A transparent native text surface on the PDF, without a note card or a separate dialog.
///
/// The text view lives in a flipped container that pins it to the container's full bounds. That
/// is what puts the insertion point at the **top-left** of the box from the first frame: an
/// `NSTextView` given the text box's size directly can shrink to its one-line content and settle
/// at the bottom of the SwiftUI frame (the reported bottom-left caret). The container owns the
/// geometry; the text view only lays out glyphs from its own top-left.
struct InlineTextBoxEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let color: NSColor
    let onCommit: () -> Void
    let onCancel: () -> Void
    var onTab: ((Bool) -> Void)? = nil
    var accessibilityName = "Text box content"
    var useAppearanceFont = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> EditorContainer {
        let container = EditorContainer()
        let view = container.editor
        view.isRichText = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false
        // The editor is as tall as the box, not as tall as its text: the caret and the first
        // line sit at the top and the box itself is what grows when lines are added.
        view.isVerticallyResizable = false
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        view.string = text
        view.setAccessibilityLabel(accessibilityName)
        updateNSView(container, context: context)
        DispatchQueue.main.async { [weak container] in
            guard let container, let window = container.window else { return }
            window.makeFirstResponder(container.editor)
            container.editor.setSelectedRange(
                NSRange(location: (container.editor.string as NSString).length, length: 0))
        }
        return container
    }
    func updateNSView(_ container: EditorContainer, context: Context) {
        context.coordinator.parent = self
        let view = container.editor
        view.font = useAppearanceFont ? AnnotationTextFont.font(size: max(1, fontSize)) : .systemFont(ofSize: max(1, fontSize))
        if useAppearanceFont {
            view.typingAttributes[.kern] = 0
            view.textStorage?.addAttribute(.kern, value: 0, range: NSRange(location: 0, length: (view.string as NSString).length))
        }
        view.textColor = color
        view.insertionPointColor = color
        view.onCommit = onCommit
        view.onCancel = onCancel
        view.onTab = onTab
        if view.string != text { view.string = text }
        // SwiftUI can hand the container a new size without asking the text view to lay out
        // again; doing it here keeps the insertion point at the top-left on the very first pass.
        container.needsLayout = true
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InlineTextBoxEditor
        init(_ parent: InlineTextBoxEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
    /// A flipped host that gives the text view the whole box. `NSViewRepresentable` proposes the
    /// overlay's size to this view; the text view never influences its own height.
    final class EditorContainer: NSView {
        let editor = Editor(frame: .zero)
        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            editor.autoresizingMask = [.width, .height]
            addSubview(editor)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("InlineTextBoxEditor is programmatic") }

        override func layout() {
            super.layout()
            editor.frame = bounds
        }
    }
    final class Editor: NSTextView {
        var onCommit: (() -> Void)?
        var onCancel: (() -> Void)?
        var onTab: ((Bool) -> Void)?
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 48, let onTab { onTab(event.modifierFlags.contains(.shift)); return }
            if event.keyCode == 53 { onCancel?(); return }
            if event.keyCode == 36 && event.modifierFlags.contains(.command) { onCommit?(); return }
            super.keyDown(with: event)
        }
    }
}
