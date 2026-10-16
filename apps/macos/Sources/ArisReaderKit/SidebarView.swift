import CoreGraphics
import SwiftUI

/// Sidebar: tab switching plus the content of each tab (`docs/04-ui-ux.md` §2.2).
///
/// Thumbnails, outline and search results are real as of M2; the remaining tabs
/// (bookmarks, annotations, AI) keep their empty state until their milestone.
public struct SidebarView: View {
    @ObservedObject private var state: AppState
    /// Which note field has focus, so losing it commits the pending write immediately instead
    /// of leaving the text to the coalescing window (`AppState.updateNote`).
    @FocusState private var focusedNote: UUID?

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $state.sidebarTab) {
                ForEach(SidebarTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 180)
    }

    @ViewBuilder
    private var content: some View {
        switch state.sidebarTab {
        case .thumbnails:
            thumbnailStrip
        case .outline:
            outlineList
        case .search:
            searchResults
        case .bookmarks:
            emptyState("Bookmarks", "bookmark", task: "T2.4")
        case .annotations:
            annotationList
        case .ai:
            emptyState("AI assistant", "sparkles", task: "T5.4")
        }
    }

    // MARK: - Thumbnails

    private var thumbnailStrip: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: state.thumbnailWidthPt))], spacing: 10) {
                ForEach(0..<max(state.document?.pageCount ?? 0, 0), id: \.self) { page in
                    Button {
                        state.gotoPage(page)
                    } label: {
                        VStack(spacing: 4) {
                            thumbnail(for: page)
                            Text("\(page + 1)")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(page + 1 == state.currentPage ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .onAppear { state.loadThumbnails(page: page) }
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(page + 1 == state.currentPage ? Color.accentColor.opacity(0.18) : .clear)
                    )
                }
            }
            .padding(10)
        }
        .onAppear { state.loadThumbnails() }
    }

    @ViewBuilder
    private func thumbnail(for page: Int) -> some View {
        if let image = state.thumbnails[page], let rendered = Self.image(from: image) {
            rendered
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: state.thumbnailWidthPt)
                .background(Color.white)
                .overlay(Rectangle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
        } else {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.primary.opacity(0.06))
                .frame(
                    width: state.thumbnailWidthPt,
                    height: state.thumbnailWidthPt * 1.414
                )
        }
    }

    /// Wraps a BGRA bitmap in a `CGImage`. The format matches what PDFium produced
    /// (premultiplied first, little endian), so no channel shuffling is needed.
    private static func image(from page: PageImage) -> Image? {
        guard page.pixelWidth > 0, page.pixelHeight > 0 else { return nil }

        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
        guard let provider = CGDataProvider(data: page.bgra as CFData),
              let cgImage = CGImage(
                  width: page.pixelWidth,
                  height: page.pixelHeight,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: page.pixelWidth * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: bitmapInfo,
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else { return nil }

        return Image(decorative: cgImage, scale: 1)
    }

    // MARK: - Outline

    private var outlineList: some View {
        Group {
            if state.outline.isEmpty {
                emptyState("No outline", "list.bullet.indent", task: "T2.4")
            } else {
                List(state.outline) { entry in
                    Button {
                        if let page = entry.page {
                            state.gotoPage(page)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(entry.title)
                                .lineLimit(2)
                                .font(entry.depth == 0 ? .callout : .caption)
                            Spacer(minLength: 0)
                            if let page = entry.page {
                                Text("\(page + 1)")
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.leading, CGFloat(entry.depth) * 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
            }
        }
    }

    // MARK: - Search

    private var searchResults: some View {
        Group {
            if state.searchHits.isEmpty {
                emptyState("Search results", "magnifyingglass", task: "T2.6")
            } else {
                List(Array(state.searchHits.enumerated()), id: \.offset) { index, hit in
                    Button {
                        state.showSearchHit(index)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Page \(hit.page + 1)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(hit.snippet)
                                .font(.caption)
                                .lineLimit(3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        index == state.currentHitIndex ? Color.accentColor.opacity(0.15) : .clear
                    )
                }
                .listStyle(.sidebar)
            }
        }
    }

    // MARK: - Annotations

    /// Everything annotation-shaped about this document, in one list.
    ///
    /// Two sources, deliberately kept apart: the notes and highlights **inside the PDF** (read
    /// from the file, not editable here) and the reader's **own** highlights (kept in the sidecar).
    /// Sticky notes are why this list exists at all — a `/Text` annotation has no geometry worth
    /// drawing on the canvas, so without a list it stays invisible and the reader never learns
    /// that somebody left a comment on the page.
    private var annotationList: some View {
        Group {
            if state.annotations.isEmpty && state.documentAnnotations.isEmpty
                && !state.documentAnnotationsLoading {
                emptyState("No highlights yet", "highlighter", task: "T3.6")
            } else {
                List {
                    documentAnnotationSection
                    ownAnnotationSection
                }
                .listStyle(.sidebar)
                .onChange(of: focusedNote) { previous, current in
                    // Blur (or moving to another note) commits what was typed.
                    if previous != nil, previous != current { state.commitNoteEdits() }
                }
            }
        }
    }

    /// The annotations the file itself carries.
    @ViewBuilder
    private var documentAnnotationSection: some View {
        if state.documentAnnotationsLoading {
            Section("In this PDF") {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading annotations…").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else if let failure = state.documentAnnotationsError {
            Section("In this PDF") {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if !state.documentAnnotations.isEmpty {
            Section("In this PDF") {
                ForEach(state.documentAnnotations.filter { $0.visible }) { annotation in
                    Button {
                        state.jump(toDocumentAnnotation: annotation)
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            // The annotation's own colour, so a list entry is recognisable as the
                            // mark the reader can see on the page.
                            RoundedRectangle(cornerRadius: 2)
                                .fill(color(of: annotation))
                                .frame(width: 8, height: 8)
                                .padding(.top, 3)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(documentAnnotationTitle(annotation))
                                    .font(.caption)
                                    .lineLimit(3)
                                Text(documentAnnotationSubtitle(annotation))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                    }
                    .buttonStyle(.plain)
                    // A note clicked on the page lands here (see `openDocumentNote`): the row is
                    // the one place the whole of its text is readable, so a drawn note has to be
                    // able to put the reader in front of it.
                    .listRowBackground(
                        state.selectedDocumentAnnotationID == annotation.id
                            ? Color.accentColor.opacity(0.22)
                            : Color.clear
                    )
                }
            }
        }
    }

    /// The highlights this reader added, with their editable notes.
    @ViewBuilder
    private var ownAnnotationSection: some View {
        if !state.annotations.isEmpty {
            Section("My highlights") {
                ForEach(state.annotations) { annotation in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(
                                red: Double(annotation.color.red) / 255,
                                green: Double(annotation.color.green) / 255,
                                blue: Double(annotation.color.blue) / 255
                            ))
                            .frame(width: 8, height: 8)

                        Button {
                            state.jump(to: annotation)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                TextField(
                                    "Note",
                                    text: Binding(
                                        get: { annotation.note },
                                        set: { state.updateNote($0, for: annotation.id) }
                                    )
                                )
                                .textFieldStyle(.plain)
                                .font(.caption)
                                .focused($focusedNote, equals: annotation.id)
                                .onSubmit { state.commitNoteEdits() }

                                Text(
                                    "Page \(annotation.page + 1) · \(annotation.kind.rawValue) · "
                                        + "\(annotation.end - annotation.start + 1) characters"
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            state.removeAnnotation(annotation.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("Delete highlight")
                    }
                }
            }
        }
    }

    /// What an annotation found in the PDF is called in the list.
    private func documentAnnotationTitle(_ annotation: DocumentAnnotation) -> String {
        if let contents = annotation.contents, !contents.isEmpty { return contents }
        switch annotation.kind {
        case "highlight": return "Highlight"
        case "underline": return "Underline"
        case "strikeout": return "Strikeout"
        case "squiggly": return "Squiggly underline"
        case "text": return "Sticky note (no text)"
        case "freeText": return "Free text (no text)"
        default: return "\(annotation.kind) annotation"
        }
    }

    private func documentAnnotationSubtitle(_ annotation: DocumentAnnotation) -> String {
        var parts = ["Page \(annotation.page + 1)"]
        if let author = annotation.author, !author.isEmpty { parts.append(author) }
        if annotation.blend == "multiply" { parts.append("multiplied") }
        return parts.joined(separator: " · ")
    }

    /// A loaded annotation's colour, or a neutral grey when the file states none.
    private func color(of annotation: DocumentAnnotation) -> Color {
        let color = annotation.color ?? AnnotationColor(red: 0x80, green: 0x80, blue: 0x80, alpha: 0xFF)
        return Color(
            red: Double(color.red) / 255,
            green: Double(color.green) / 255,
            blue: Double(color.blue) / 255
        )
    }

    private func emptyState(_ title: String, _ symbol: String, task: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Planned for \(task)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}
