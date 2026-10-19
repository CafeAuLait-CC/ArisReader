import AppKit
import SwiftUI

/// The form layer: AcroForm widgets drawn over the page, and edited in place when the form tool
/// is on.
///
/// Geometry comes from the engine in **page-local view space** (the widget's `/Rect` through the
/// page's crop box, `/Rotate` and `/UserUnit`), so a field stays on its widget at every zoom and
/// rotation. The overlay uses the same `AppState.anchorViewRect` the note and text-box layers
/// use; it draws its own chrome rather than burning pixels into the Metal raster, so the focus
/// ring and button marks stay crisp at any scale.
///
/// While the form tool is off the whole layer is transparent to the mouse and the keyboard: the
/// canvas keeps text selection, links and scrolling exactly as it had them. The form tool is a
/// mode like the ink and markup tools; leaving it restores reading without a second step.
struct FormOverlay: View {
    @ObservedObject var state: AppState

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                ForEach(state.formInfo.fields) { field in
                    if let rect = state.anchorViewRect(page: field.page, region: field.rect) {
                        fieldView(field, rect: rect)
                    }
                }
                if let id = state.formOpenChoiceFieldID,
                   let field = state.formField(id: id),
                   let rect = state.anchorViewRect(page: field.page, region: field.rect) {
                    comboMenu(field, anchor: rect)
                }
            }
        }
        .allowsHitTesting(state.formToolActive)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Form fields")
        .onChange(of: state.formFocusedFieldID) { old, new in
            // Escape leaves the field: hand the keyboard back to the page so arrow keys and
            // space scroll immediately instead of waiting for another click.
            if old != nil, new == nil { restoreCanvasFocus() }
        }
        .onChange(of: state.formToolActive) { _, active in
            if !active { restoreCanvasFocus() }
        }
    }

    /// The Metal canvas is the reader's keyboard surface (arrows, page keys, space, ⌘C). A text
    /// widget borrows it for as long as it has focus; when the field session ends this puts it
    /// back, without the reader having to click the page first.
    private func restoreCanvasFocus() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let content = window.contentView,
              let canvas = Self.firstCanvas(in: content) else { return }
        window.makeFirstResponder(canvas)
    }

    private static func firstCanvas(in view: NSView) -> MetalCanvasView? {
        if let canvas = view as? MetalCanvasView { return canvas }
        for subview in view.subviews {
            if let canvas = firstCanvas(in: subview) { return canvas }
        }
        return nil
    }

    @ViewBuilder
    private func fieldView(_ field: FormField, rect: CGRect) -> some View {
        switch field.kind {
        case .text:
            textField(field, rect: rect)
        case .checkBox:
            checkBox(field, rect: rect)
        case .radio:
            radioGroup(field)
        case .comboBox:
            comboBox(field, rect: rect)
        case .listBox:
            listBox(field, rect: rect)
        case .signature:
            signature(field, rect: rect)
        }
    }

    // MARK: - Chrome

    /// The reader's field surface: a light border at rest, an accent border and wash once a
    /// value is present, and a real focus ring on the field that owns the keyboard.
    private func chrome(
        _ field: FormField,
        rect: CGRect,
        focused: Bool,
        filled: Bool,
        dashed: Bool = false
    ) -> some View {
        let radius: CGFloat = 3
        let shape = RoundedRectangle(cornerRadius: radius)
        let border = filled ? LyraReaderTheme.accentBorder : LyraReaderTheme.controlBorder.opacity(0.62)
        return shape
            .fill(filled ? LyraReaderTheme.accentSoft.opacity(0.70) : LyraReaderTheme.fieldBg.opacity(0.78))
            .overlay {
                if dashed {
                    shape.strokeBorder(border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                } else {
                    shape.strokeBorder(border, lineWidth: filled ? 1.2 : 0.8)
                }
            }
            .overlay {
                if focused {
                    shape.strokeBorder(LyraReaderTheme.focusRing, lineWidth: 2)
                        .padding(-2)
                        .shadow(color: LyraReaderTheme.focusRing.opacity(0.35), radius: 3)
                }
            }
            .frame(width: rect.width, height: rect.height)
    }

    private func isFocused(_ field: FormField) -> Bool {
        state.formToolActive && state.formFocusedFieldID == field.id
    }

    private func filledDot() -> some View {
        Circle()
            .fill(LyraReaderTheme.accent)
            .frame(width: 5, height: 5)
            .padding(4)
    }

    private func scaledFont(_ field: FormField, minimum: CGFloat = 8) -> CGFloat {
        max(minimum, min(field.fontSizePt * state.zoomFactor, 32 * state.zoomFactor))
    }

    // MARK: - Text

    private func textField(_ field: FormField, rect: CGRect) -> some View {
        let filled = state.formValueIsFilled(field)
        let focused = isFocused(field)
        let text = state.formCurrentText(field)
        return ZStack(alignment: .topLeading) {
            chrome(field, rect: rect, focused: focused, filled: filled)
            if focused {
                Group {
                    if field.multiline {
                        InlineTextBoxEditor(text: Binding(
                            get: { state.formCurrentText(field) },
                            set: { state.updateFormText(field.id, text: $0) }),
                            fontSize: scaledFont(field), color: .labelColor,
                            onCommit: { state.blurFormField() }, onCancel: { state.blurFormField() },
                            onTab: { state.focusNextFormField(backwards: $0) }, accessibilityName: field.displayName, useAppearanceFont: false)
                    } else {
                        FormFieldTextEditor(
                            text: Binding(
                                get: { state.formCurrentText(field) },
                                set: { state.updateFormText(field.id, text: $0) }
                            ),
                            fontSize: scaledFont(field),
                            onTab: { backwards in state.focusNextFormField(backwards: backwards) },
                            onEscape: { state.blurFormField() }
                        )
                    }
                }
                .padding(.horizontal, 4)
                .frame(width: max(1, rect.width - 8), height: max(1, rect.height - 4), alignment: .leading)
                .offset(x: 4, y: 2)
            } else {
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: scaledFont(field)))
                    .foregroundStyle(text.isEmpty ? LyraReaderTheme.textPlaceholder : LyraReaderTheme.textPrimary)
                    .lineLimit(field.multiline ? Int.max : 1)
                    .truncationMode(.tail)
                    .frame(width: max(1, rect.width - 8), height: max(1, rect.height - 4),
                           alignment: .topLeading)
                    .offset(x: 4, y: 2)
                    .allowsHitTesting(false)
            }
            if filled && !focused {
                HStack { Spacer(); VStack { filledDot(); Spacer() } }
            }
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .contentShape(Rectangle())
        .onTapGesture { state.focusFormField(field.id) }
        .help("\(field.kind.title): \(field.displayName)")
        .accessibilityElement(children: focused ? .contain : .ignore)
        .accessibilityLabel("\(field.kind.title) \(field.displayName)")
        .accessibilityValue(text)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Check box

    private func checkBox(_ field: FormField, rect: CGRect) -> some View {
        let checked = state.formCurrentChecked(field)
        let focused = isFocused(field)
        return ZStack {
            chrome(field, rect: rect, focused: focused, filled: checked)
            if checked {
                CheckMark()
                    .stroke(LyraReaderTheme.accent,
                            style: StrokeStyle(lineWidth: max(1.6, rect.width * 0.14),
                                               lineCap: .round, lineJoin: .round))
                    .frame(width: rect.width * 0.62, height: rect.height * 0.62)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .contentShape(Rectangle())
        .onTapGesture { state.toggleFormCheckbox(field.id) }
        .help("\(field.displayName): \(checked ? "checked" : "unchecked")")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(field.displayName)
        .accessibilityValue(checked ? "Checked" : "Unchecked")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Radio

    private func radioGroup(_ field: FormField) -> some View {
        let selected = state.formCurrentSelection(field)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(field.widgets.enumerated()), id: \.offset) { index, widget in
                if let box = state.anchorViewRect(page: widget.page, region: widget.rect) {
                    let hitWidth = radioHitWidth(field: field, index: index, box: box)
                    Button {
                        state.selectFormRadioOption(field.id, index: index)
                    } label: {
                        HStack(spacing: 0) {
                            ZStack {
                                Circle()
                                    .fill(LyraReaderTheme.fieldBg.opacity(0.9))
                                Circle()
                                    .strokeBorder(selected == index
                                                  ? LyraReaderTheme.accentBorder
                                                  : LyraReaderTheme.controlBorder.opacity(0.7),
                                                  lineWidth: selected == index ? 1.4 : 1)
                                if selected == index {
                                    Circle()
                                        .fill(LyraReaderTheme.accent)
                                        .padding(max(2.5, box.width * 0.22))
                                }
                                // The focus ring marks the selected radio, not every circle in
                                // the group: a ring around all three reads as three selections.
                                if state.formFocusedFieldID == field.id && selected == index {
                                    Circle().strokeBorder(LyraReaderTheme.focusRing, lineWidth: 2)
                                        .padding(-2)
                                }
                            }
                            .frame(width: box.width, height: box.height)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: hitWidth, height: max(box.height, 18), alignment: .leading)
                    .position(x: box.minX + hitWidth / 2, y: box.midY)
                    .help("\(field.displayName): \(field.options.indices.contains(index) ? field.options[index].label : "option \(index + 1)")")
                    .accessibilityLabel("\(field.displayName), \(field.options.indices.contains(index) ? field.options[index].label : "option \(index + 1)")")
                    .accessibilityValue(selected == index ? "Selected" : "Not selected")
                }
            }
        }
    }

    /// The circle plus the page's own label. Labels are PDF text, so the hit area widens only to
    /// the next button; it never paints a second copy of the label.
    private func radioHitWidth(field: FormField, index: Int, box: CGRect) -> CGFloat {
        let sorted = field.widgets.sorted { $0.rect.minX < $1.rect.minX }
        if let position = sorted.firstIndex(where: { $0.rect.minX == box.minX }),
           position + 1 < sorted.count,
           let next = state.anchorViewRect(page: sorted[position + 1].page,
                                           region: sorted[position + 1].rect) {
            return max(box.width, next.minX - box.minX - 2)
        }
        return max(box.width, 70)
    }

    // MARK: - Combo box

    private func comboBox(_ field: FormField, rect: CGRect) -> some View {
        let focused = isFocused(field)
        let value = state.formCurrentValue(field)
        let label = value.selected.flatMap { field.options.indices.contains($0) ? field.options[$0].label : nil }
            ?? field.value ?? ""
        let filled = !label.isEmpty
        return ZStack(alignment: .trailing) {
            chrome(field, rect: rect, focused: focused, filled: filled)
            Text(label.isEmpty ? " " : label)
                .font(.system(size: scaledFont(field)))
                .foregroundStyle(label.isEmpty ? LyraReaderTheme.textPlaceholder : LyraReaderTheme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
                .padding(.trailing, 20)
                .allowsHitTesting(false)
            Image(systemName: "chevron.down")
                .font(.system(size: max(7, 8 * state.zoomFactor), weight: .semibold))
                .foregroundStyle(LyraReaderTheme.iconSecondary)
                .padding(.trailing, 5)
                .allowsHitTesting(false)
            if filled && !focused {
                VStack { filledDot(); Spacer() }
                    .padding(.trailing, 20)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .contentShape(Rectangle())
        .onTapGesture { state.toggleFormChoiceMenu(field.id) }
        .help("\(field.kind.title): \(field.displayName)")
        .accessibilityElement(children: focused ? .contain : .ignore)
        .accessibilityLabel("\(field.kind.title) \(field.displayName)")
        .accessibilityValue(label)
        .accessibilityAddTraits(.isButton)
    }

    /// The drop-down list, drawn below the combo. The rect is in the same view space as the
    /// field, so it follows zoom and scroll with it.
    private func comboMenu(_ field: FormField, anchor: CGRect) -> some View {
        let rowHeight = max(20, min(26, anchor.height * 1.05))
        let height = max(rowHeight, rowHeight * CGFloat(field.options.count))
        return VStack(spacing: 0) {
            ForEach(Array(field.options.enumerated()), id: \.offset) { index, option in
                Button {
                    state.selectFormChoice(field.id, index: index)
                } label: {
                    HStack {
                        Text(option.label)
                            .font(.system(size: max(9, min(12 * state.zoomFactor, rowHeight * 0.62))))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if state.formCurrentSelection(field) == index {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(width: anchor.width, height: rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(FormChoiceRowStyle())
            }
        }
        .frame(width: anchor.width, height: height)
        .background(LyraReaderTheme.raisedBg)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(LyraReaderTheme.controlBorder, lineWidth: 0.8))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .position(x: anchor.midX, y: anchor.maxY + height / 2 + 2)
        .zIndex(10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(field.displayName) options")
    }

    // MARK: - List box

    private func listBox(_ field: FormField, rect: CGRect) -> some View {
        let selected = state.formCurrentSelection(field)
        let focused = isFocused(field)
        let rows = max(field.options.count, 1)
        let rowHeight = rect.height / CGFloat(rows)
        return VStack(spacing: 0) {
            ForEach(Array(field.options.enumerated()), id: \.offset) { index, option in
                Button {
                    state.selectFormChoice(field.id, index: index)
                } label: {
                    HStack {
                        Text(option.label)
                            .font(.system(size: max(8, min(field.fontSizePt * state.zoomFactor,
                                                           rowHeight * 0.62))))
                            .foregroundStyle(selected == index ? LyraReaderTheme.selectedFg
                                                              : LyraReaderTheme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .background(selected == index ? LyraReaderTheme.selectedBg : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(FormChoiceRowStyle())
            }
        }
        .frame(width: rect.width, height: rect.height)
        .background(LyraReaderTheme.fieldBg.opacity(0.78))
        .overlay(RoundedRectangle(cornerRadius: 3)
            .strokeBorder(focused ? LyraReaderTheme.focusRing
                                  : (selected == nil ? LyraReaderTheme.controlBorder.opacity(0.62)
                                                     : LyraReaderTheme.accentBorder),
                          lineWidth: focused ? 2 : 0.8))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .position(x: rect.midX, y: rect.midY)
        .help("\(field.kind.title): \(field.displayName)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(field.kind.title) \(field.displayName)")
    }

    // MARK: - Signature

    private func signature(_ field: FormField, rect: CGRect) -> some View {
        ZStack {
            chrome(field, rect: rect, focused: false, filled: false, dashed: true)
                .background(Color.white.opacity(0.35))
            HStack(spacing: 5) {
                Image(systemName: "signature")
                    .font(.system(size: max(9, min(11 * state.zoomFactor, rect.height * 0.5))))
                Text("Signature")
                    .font(.system(size: max(8, min(10 * state.zoomFactor, rect.height * 0.42))))
            }
            .foregroundStyle(LyraReaderTheme.textTertiary)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
        .help("Signature field: \(field.displayName) — not editable in this reader")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signature field \(field.displayName), not editable")
    }
}

/// The check mark, drawn rather than typed so it scales with the widget.
private struct CheckMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// A full-row button with a hover wash, used by the drop-down and list options.
private struct FormChoiceRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? LyraReaderTheme.pressedBg
                                                : Color.clear)
    }
}

/// A borderless single-line editor over a text widget.
///
/// A real `NSTextField` is used instead of collecting keystrokes in the canvas, so typing,
/// selection, the caret, IME composition and the system spell checker are the platform's. Tab,
/// Shift-Tab, Return and Escape are routed back to the form model; the editor itself owns
/// nothing but the field's current text.
private struct FormFieldTextEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var onTab: (Bool) -> Void
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FormTextField {
        let field = FormTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = false
        field.lineBreakMode = .byClipping
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = NSColor.labelColor
        field.stringValue = text
        field.onTab = onTab
        field.onEscape = onEscape
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        DispatchQueue.main.async {
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
            if let editor = field.currentEditor() {
                editor.selectedRange = NSRange(location: (field.stringValue as NSString).length,
                                               length: 0)
            }
        }
        return field
    }

    func updateNSView(_ nsView: FormTextField, context: Context) {
        context.coordinator.parent = self
        nsView.onTab = onTab
        nsView.onEscape = onEscape
        nsView.font = .systemFont(ofSize: fontSize)
        if nsView.stringValue != text, nsView.currentEditor() == nil {
            nsView.stringValue = text
        } else if nsView.stringValue != text {
            // Keep the caret when the model echo arrives from `controlTextDidChange`.
            let selected = nsView.currentEditor()?.selectedRange
            nsView.stringValue = text
            if let selected, let editor = nsView.currentEditor() {
                editor.selectedRange = NSRange(location: min(selected.location,
                                                             (text as NSString).length),
                                               length: 0)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FormFieldTextEditor

        init(_ parent: FormFieldTextEditor) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertTab(_:)):
                parent.onTab(false)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                parent.onTab(true)
                return true
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                parent.onTab(false)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            default:
                return false
            }
        }
    }
}

private final class FormTextField: NSTextField {
    var onTab: ((Bool) -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // The field editor normally handles these; this is the fallback for a text field that
        // receives the raw event (for example before editing begins).
        switch event.keyCode {
        case 48: // Tab
            onTab?(event.modifierFlags.contains(.shift))
        case 53: // Escape
            onEscape?()
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
