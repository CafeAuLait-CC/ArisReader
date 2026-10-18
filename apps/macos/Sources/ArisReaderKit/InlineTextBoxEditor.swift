import AppKit
import SwiftUI

/// A transparent native text surface on the PDF, without a note card or a separate dialog.
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
    func makeNSView(context: Context) -> Editor {
        let view = Editor(frame: .zero)
        view.isRichText = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        view.string = text
        view.setAccessibilityLabel(accessibilityName)
        updateNSView(view, context: context)
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        }
        return view
    }
    func updateNSView(_ view: Editor, context: Context) {
        context.coordinator.parent = self
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
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InlineTextBoxEditor
        init(_ parent: InlineTextBoxEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
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
