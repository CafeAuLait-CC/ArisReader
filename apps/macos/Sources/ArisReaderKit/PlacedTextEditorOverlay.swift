import ArisReaderBindings
import SwiftUI

/// The editor for an editable note or text box.
///
/// A PDF's own notes keep the read-only `DocumentNoteOverlay`; this is the editable counterpart
/// for entries in the sidecar. A sticky note opens a paper beside its icon, the way a reader
/// expects after clicking a note icon. A text box opens **over its own box**, at the size the
/// text is drawn at, so typing shows the line breaks and size the page will show.
///
/// The text reaches `AppState` on every keystroke so the canvas can lay it out live, but the
/// sidecar write is coalesced and the whole session becomes one undoable change. Notes have a
/// Done button; text boxes finish on a page click or Command-Return. Escape restores the session.
struct PlacedTextEditorOverlay: View {
    @ObservedObject var state: AppState
    @State private var text = ""
    @State private var loadedID: UUID?
    @State private var missingGlyphs: [String] = []
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geometry in
            if let annotation = state.editingAnnotation,
               let anchor = state.editingAnnotationAnchor {
                let isNote = annotation.kind != .textBox
                let frame = isNote
                    ? DocumentNoteLayout.frame(anchor: anchor, viewport: geometry.size)
                    : anchor
                Group {
                    if isNote {
                        VStack(spacing: 0) {
                            header(for: annotation)
                            Divider()
                            if !missingGlyphs.isEmpty { appearanceWarning }
                            TextEditor(text: $text)
                                .focused($focused).font(.system(size: 13))
                                .scrollContentBackground(.hidden)
                                .background(LyraTheme.noteBg).foregroundStyle(LyraTheme.noteFg)
                                .padding(6)
                                .onExitCommand { state.cancelTextEditing() }
                        }
                        .background(LyraTheme.noteBg)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(LyraTheme.border))
                        .shadow(color: .black.opacity(0.15), radius: 7, y: 3)
                    } else {
                        InlineTextBoxEditor(text: $text,
                            fontSize: annotation.fontSize * state.zoomFactor,
                            color: ReadingAppearanceStore.shared.mode.displayColor(annotation.color.nsColor),
                            onCommit: { state.commitTextEditing() }, onCancel: { state.cancelTextEditing() })
                            .padding(AnnotationTextFont.padding(size: annotation.fontSize) * state.zoomFactor)
                            .help("Click the page or press ⌘Return to finish; Esc cancels")
                            .overlay(alignment: .topLeading) {
                                if !missingGlyphs.isEmpty {
                                    appearanceWarning.frame(width: max(220, frame.width))
                                        .background(LyraTheme.panelBg).offset(y: frame.height + 4)
                                }
                            }
                            .overlay(Rectangle().stroke(LyraTheme.focusRing,
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3])).allowsHitTesting(false))
                    }
                }
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .id(annotation.id)
                .onAppear {
                    text = annotation.note
                    loadedID = annotation.id
                    refreshAppearanceCoverage(annotation.note)
                    DispatchQueue.main.async { focused = true }
                }
                .onChange(of: text) { _, newValue in
                    guard loadedID == annotation.id else { return }
                    state.updateEditingText(newValue)
                    refreshAppearanceCoverage(newValue)
                }
                .onChange(of: state.editingAnnotationID) { _, newValue in
                    // The editor is removed when the session ends; keep its local state from
                    // leaking into the next note if SwiftUI reuses this view.
                    if newValue == nil {
                        focused = false
                        loadedID = nil
                        text = ""
                        missingGlyphs = []
                    }
                }
            }
        }
    }

    /// A missing character is never `?` and never dropped from `/Contents`; the appearance uses
    /// the font's `.notdef` box and keeps the exact Unicode in its ToUnicode map. Say so while the
    /// reader is typing, not only when a viewer shows the box later.
    private var appearanceWarning: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(warningText)
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(LyraTheme.noteFg.opacity(0.85))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LyraTheme.noteFg.opacity(0.06))
    }

    private var warningText: String {
        let listed = missingGlyphs.prefix(8).joined(separator: " ")
        let more = missingGlyphs.count > 8 ? " ..." : ""
        let noun = missingGlyphs.count == 1 ? "character" : "characters"
        return "The bundled font can't draw \(missingGlyphs.count) \(noun): \(listed)\(more). "
            + "They stay in the annotation text but appear as a missing-glyph box in other viewers."
    }

    private func refreshAppearanceCoverage(_ value: String) {
        guard state.editingAnnotation?.kind.isPlacedText == true,
              !value.isEmpty, let coverage = try? appearanceFontCoverage(text: value) else {
            missingGlyphs = []
            return
        }
        missingGlyphs = coverage.missing
    }

    private func header(for annotation: AppState.Annotation) -> some View {
        HStack(spacing: 8) {
            Image(systemName: annotation.kind == .textBox ? "textbox" : "text.bubble")
                .font(.system(size: 11))
            Text(annotation.kind == .stickyNote ? "Sticky Note" : "Note")
                .font(.system(size: 11, weight: .semibold))
            Spacer()
            Button("Cancel") { state.cancelTextEditing() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .help("Discard this edit")
            Button("Done") { state.commitTextEditing() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .help("Keep this text")
        }
        .foregroundStyle(LyraTheme.noteFg)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}
