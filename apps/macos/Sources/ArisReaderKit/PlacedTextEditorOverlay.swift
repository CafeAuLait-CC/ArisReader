import ArisReaderBindings
import SwiftUI

/// The editor for a sticky note or text box this reader placed.
///
/// A PDF's own notes keep the read-only `DocumentNoteOverlay`; this is the editable counterpart
/// for entries in the sidecar. A sticky note opens a paper beside its icon, the way a reader
/// expects after clicking a note icon. A text box opens **over its own box**, at the size the
/// text is drawn at, so typing shows the line breaks and size the page will show.
///
/// The text reaches `AppState` on every keystroke so the canvas can lay it out live, but the
/// sidecar write is coalesced and the whole session becomes one undoable change. `Done` commits,
/// `Escape` cancels (restoring the text the editor started with).
struct PlacedTextEditorOverlay: View {
    @ObservedObject var state: AppState
    @State private var text = ""
    @State private var loadedID: UUID?
    @State private var missingGlyphs: [String] = []
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geometry in
            if let annotation = state.editingAnnotation,
               let anchor = state.anchorViewRect(page: annotation.page, region: annotation.shapeRect) {
                let isNote = annotation.kind == .stickyNote
                let frame = isNote
                    ? DocumentNoteLayout.frame(anchor: anchor, viewport: geometry.size)
                    : textBoxEditorFrame(anchor: anchor, viewport: geometry.size)
                VStack(spacing: 0) {
                    header(for: annotation)
                    Divider()
                    TextEditor(text: $text)
                        .focused($focused)
                        .font(.system(size: isNote ? 13 : max(annotation.fontSize * state.zoomFactor, 9)))
                        .scrollContentBackground(.hidden)
                        .background(LyraTheme.noteBg)
                        .foregroundStyle(LyraTheme.noteFg)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .onExitCommand { state.cancelTextEditing() }
                    if !isNote, !missingGlyphs.isEmpty {
                        Divider()
                        appearanceWarning
                    }
                }
                .frame(width: frame.width, height: frame.height)
                .background(LyraTheme.noteBg)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(LyraTheme.border))
                .shadow(color: .black.opacity(0.22), radius: 7, y: 3)
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
        guard !value.isEmpty, let coverage = try? appearanceFontCoverage(text: value) else {
            missingGlyphs = []
            return
        }
        missingGlyphs = coverage.missing
    }

    private func header(for annotation: AppState.Annotation) -> some View {
        HStack(spacing: 8) {
            Image(systemName: annotation.kind == .stickyNote ? "note.text" : "textbox")
                .font(.system(size: 11))
            Text(annotation.kind == .stickyNote ? "Sticky Note" : "Text Box")
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

    /// A text box's editor sits on the box, but is never smaller than a usable field: a reader
    /// may create a two-line box and still needs to see what they type.
    private func textBoxEditorFrame(anchor: CGRect, viewport: CGSize) -> CGRect {
        let width = max(anchor.width, 120)
        let height = max(anchor.height, 64)
        let margin: CGFloat = 6
        let x = min(max(margin, anchor.minX), max(margin, viewport.width - width - margin))
        let y = min(max(margin, anchor.minY), max(margin, viewport.height - height - margin))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
