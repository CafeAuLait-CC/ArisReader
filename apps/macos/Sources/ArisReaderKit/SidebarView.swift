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
    /// Page groups the reader has collapsed. Empty means every group is expanded: the panel is
    /// opened to read annotations, and a review PDF's threads should not hide behind a second
    /// click. Disclosure is local view state, so switching tabs or documents resets it.
    @State private var collapsedAnnotationPages: Set<Int> = []

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
            bookmarkList
        case .annotations:
            annotationList
        case .metadata:
            metadataPanel
        case .ai:
            emptyState("AI assistant", "sparkles", task: "T5.4")
        }
    }

    // MARK: - Metadata

    /// Title, authors, venue, year, DOI and arXiv id, each editable and each labelled with the
    /// source that produced it. An empty field stays empty; the note at the bottom says so, and
    /// the panel never fills a value from the filename or the file's creation date.
    private var metadataPanel: some View {
        Group {
            if state.document == nil {
                VStack(spacing: 10) {
                    Image(systemName: "text.badge.checkmark")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No document")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Open a PDF to read and correct its title, authors, venue, year, DOI and arXiv id.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else if state.metadataLoading {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading metadata…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure = state.metadataError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.orange)
                    Text("Metadata could not be read")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(failure)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(4)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                List {
                    Section {
                        ForEach(MetadataFieldKey.allCases, id: \.self) { key in
                            metadataRow(key)
                        }
                    } header: {
                        Text("Found in this PDF")
                    } footer: {
                        if state.metadataIsEmpty() {
                            Text(
                                "No metadata was found. An empty field stays empty rather than "
                                + "being filled with a plausible-looking guess."
                            )
                        } else {
                            Text(
                                "“Guessed” fields come from the page layout. Correct anything "
                                + "that is wrong; edits regenerate the entry below."
                            )
                        }
                    }

                    Section("Generated BibTeX") {
                        Text(state.metadataBibtex)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 10) {
                            Button {
                                state.copyMetadataBibtex()
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .disabled(!state.canCopyMetadataBibtex)
                            Button {
                                state.presentSaveBibtexPanel()
                            } label: {
                                Label("Save…", systemImage: "square.and.arrow.down")
                            }
                            .disabled(!state.canCopyMetadataBibtex)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func metadataRow(_ key: MetadataFieldKey) -> some View {
        let field = state.metadata?.field(key) ?? .empty
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(key.label)
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer(minLength: 0)
                metadataBadge(field)
            }
            TextField(key.prompt, text: metadataBinding(key))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .accessibilityLabel(key.label)
        }
        .padding(.vertical, 2)
    }

    private func metadataBinding(_ key: MetadataFieldKey) -> Binding<String> {
        Binding(
            get: { state.metadataDraft.text(for: key) },
            set: { state.updateMetadata(key, text: $0) }
        )
    }

    @ViewBuilder
    private func metadataBadge(_ field: MetadataField) -> some View {
        if field.source == .absent {
            Text("empty")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else if field.source == .edited {
            Text("Edited")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if field.guessed || field.source.isGuessed {
            Label(field.source.label, systemImage: "questionmark.circle")
                .font(.caption2)
                .foregroundStyle(.orange)
        } else {
            Text(field.source.label)
                .font(.caption2)
                .foregroundStyle(field.source.isEmbedded ? Color.secondary : Color.blue)
        }
    }

    // MARK: - Thumbnails

    private var thumbnailStrip: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: state.thumbnailWidthPt))], spacing: 10) {
                ForEach(0..<max(state.document?.pageCount ?? 0, 0), id: \.self) { page in
                    Button {
                        state.handleThumbnailClick(
                            page,
                            modifiers: NSApp.currentEvent?.modifierFlags ?? []
                        )
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
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                state.pageSelection.contains(page) ? Color.accentColor : .clear,
                                lineWidth: 2
                            )
                    )
                    .contextMenu {
                        Button("Select Page") {
                            state.selectPage(page, extending: false, toggling: false)
                        }
                        Button("Select Range to Here") {
                            state.selectPage(page, extending: true, toggling: false)
                        }
                        Divider()
                        Button("Rotate 90° Clockwise") {
                            state.selectPage(page, extending: false, toggling: false)
                            state.rotateSelectedPages(clockwise: true)
                        }
                        Button("Rotate 90° Anticlockwise") {
                            state.selectPage(page, extending: false, toggling: false)
                            state.rotateSelectedPages(clockwise: false)
                        }
                        Button("Reset Rotation to Original") {
                            state.selectPage(page, extending: false, toggling: false)
                            state.resetSelectedPageRotations()
                        }
                        Divider()
                        Button("Insert Blank Page Before") {
                            state.selectPage(page, extending: false, toggling: false)
                            state.insertBlankPage(before: true)
                        }
                        Button("Insert Blank Page After") {
                            state.selectPage(page, extending: false, toggling: false)
                            state.insertBlankPage(before: false)
                        }
                        Button("Delete Page…") {
                            state.selectPage(page, extending: false, toggling: false)
                            state.confirmDeleteSelectedPages()
                        }
                        Divider()
                        Button("Extract Selected Pages…") {
                            state.selectPage(page, extending: false, toggling: false)
                            state.presentExtractPagesPanel()
                        }
                    }
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
                let rows = OutlineNumbering.rows(for: state.outline)
                List(rows) { row in
                    Button {
                        if let page = row.entry.page {
                            state.gotoPage(page)
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(row.number)
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 18, alignment: .trailing)
                            Text(row.entry.title)
                                .lineLimit(2)
                                // One size at every level: the number already carries the
                                // hierarchy, and shrinking nested titles made deep sections hard
                                // to read in a narrow sidebar.
                                .font(.callout)
                            Spacer(minLength: 0)
                            if let page = row.entry.page {
                                Text("\(page + 1)")
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.leading, row.indentPt)
                        // The sidebar list inset plus a 24 pt number column left the outline
                        // about 35 pt from the edge; the user asked for it to sit closer.
                        .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 4))
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

    // MARK: - Bookmarks

    /// The reader's own bookmarks: one section per page, in the order the reader set.
    ///
    /// Renaming is committed on Return or blur (`BookmarkNameField`), not on every keystroke,
    /// so typing a title costs one sidecar write rather than one per character. Moving is
    /// explicit (↑/↓) instead of drag-only: the list is also reachable from the keyboard, and
    /// a drag in a grouped `List` cannot say whether the reader meant to reorder or to regroup.
    private var bookmarkList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    state.addBookmarkAtCurrentPage()
                } label: {
                    Label("Add Bookmark", systemImage: "bookmark.badge.plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(state.document == nil)
                .help("Bookmark the current page and position (⌘D)")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if state.bookmarks.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(state.document == nil ? "No document" : "No bookmarks")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if state.document != nil {
                        Text("⌘D or Add Bookmark puts the current page and position here.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                List {
                    ForEach(state.bookmarkGroups) { group in
                        Section(group.title) {
                            ForEach(group.bookmarks) { bookmark in
                                bookmarkRow(bookmark)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func bookmarkRow(_ bookmark: Bookmark) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "bookmark.fill")
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2) {
                BookmarkNameField(state: state, bookmark: bookmark)
                Button {
                    state.jump(to: bookmark)
                } label: {
                    Text("Page \(bookmark.page + 1) · \(Int(bookmark.yPt.rounded())) pt")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Jump to this bookmark")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                state.moveBookmark(bookmark.id, by: -1)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .help("Move bookmark up")

            Button {
                state.moveBookmark(bookmark.id, by: 1)
            } label: {
                Image(systemName: "arrow.down")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .help("Move bookmark down")

            Button {
                state.removeBookmark(bookmark.id)
            } label: {
                Image(systemName: "trash")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .help("Delete bookmark")
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

    /// The annotations the file itself carries, grouped by page and threaded by `/IRT`.
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
            let panel = AnnotationPanelModel.build(from: state.documentAnnotations)
            Section("In this PDF") {
                ForEach(panel.sections) { section in
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { !collapsedAnnotationPages.contains(section.page) },
                            set: { expanded in
                                if expanded {
                                    collapsedAnnotationPages.remove(section.page)
                                } else {
                                    collapsedAnnotationPages.insert(section.page)
                                }
                            }
                        )
                    ) {
                        ForEach(section.rows) { row in
                            documentAnnotationRow(row)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Page \(section.page + 1)")
                                .font(.caption)
                                .fontWeight(.semibold)
                            Text(
                                section.annotationCount == 1
                                    ? "1 annotation" : "\(section.annotationCount) annotations"
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// One row, at its depth in the thread. A reply shows its author, date and its own text; an
    /// orphan says why it is not under a parent instead of disappearing into a silent gap.
    private func documentAnnotationRow(_ row: AnnotationPanelRow) -> some View {
        Button {
            state.jump(toDocumentAnnotation: row.annotation)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                // The annotation's own colour, so a list entry is recognisable as the mark the
                // reader can see on the page. Replies usually carry no colour of their own.
                RoundedRectangle(cornerRadius: 2)
                    .fill(color(of: row.annotation))
                    .frame(width: 8, height: 8)
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: 2) {
                    if row.annotation.isReply {
                        HStack(spacing: 4) {
                            Image(systemName: "arrowshape.turn.up.left")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(row.replyAuthor ?? "Reply")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                        }
                        Text(replyBody(row.annotation))
                            .font(.caption)
                            .lineLimit(5)
                            .foregroundStyle(row.annotation.contents == nil ? .secondary : .primary)
                        if let date = row.replyDate {
                            Text(date)
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(documentAnnotationTitle(row.annotation))
                            .font(.caption)
                            .lineLimit(3)
                        Text(documentAnnotationSubtitle(row.annotation))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if !row.annotation.visible {
                        Label("Hidden on page", systemImage: "eye.slash")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if row.showsPage {
                        Text("On page \(row.annotation.page + 1)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let orphan = row.orphanReason {
                        Label(orphan.message, systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .padding(.leading, CGFloat(row.depth) * 14)
        }
        .buttonStyle(.plain)
        // A note clicked on the page opens its paper overlay and still marks this row (both go
        // through `selectedDocumentAnnotationID`); a click here jumps to the annotation's page.
        .listRowBackground(
            state.selectedDocumentAnnotationID == row.annotation.id
                ? Color.accentColor.opacity(0.22)
                : Color.clear
        )
    }

    private func replyBody(_ annotation: DocumentAnnotation) -> String {
        guard let contents = annotation.contents,
              !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return "No text" }
        return contents
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

/// A bookmark's name, edited locally and committed once.
///
/// The field is not bound straight to `AppState`: a `TextField` setter fires per keystroke, and
/// unlike note typing there is no coalescing window for bookmarks. A small draft keeps the
/// sidecar write count equal to the number of edits the reader actually finished.
private struct BookmarkNameField: View {
    let state: AppState
    let bookmark: Bookmark

    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.plain)
            .font(.caption)
            .focused($isFocused)
            .onAppear { draft = bookmark.title }
            .onChange(of: bookmark.title) { _, title in
                // Do not clobber what the reader is typing when another change lands.
                if !isFocused { draft = title }
            }
            .onSubmit { commit() }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
    }

    private func commit() {
        state.renameBookmark(bookmark.id, to: draft)
    }
}
