import CoreGraphics
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Sidebar: tab switching plus the content of each tab (`docs/04-ui-ux.md` §2.2).
///
/// Bookmarks, outline, annotations and thumbnails share the horizontal navigator.
/// The AI assistant is not a tab here: it lives in the window's right-hand panel, so the
/// sidebar and the assistant can be open at the same time. Search results and document
/// information have their own surfaces.
public struct SidebarView: View {
    @ObservedObject private var state: AppState
    @ObservedObject private var appearance = ReadingAppearanceStore.shared
    /// The window this sidebar belongs to. A file dropped on the sidebar opens in a **new**
    /// window through this coordinator; `nil` in previews/checks that only want the panel, in
    /// which case the sidebar is not a drop target.
    private let opener: DocumentOpenCoordinator?
    private let pageOverview: Bool
    private var thumbnailWidth: CGFloat { pageOverview ? 180 : state.thumbnailWidthPt }
    /// Shared by the drop delegate: it bumps a generation for every drag that enters or leaves,
    /// so a slow item-provider load that lands after the drag moved on cannot paint a stale hint
    /// or perform a stale drop.
    @State private var dropSession = SidebarDropSession()
    /// Which note field has focus, so losing it commits the pending write immediately instead
    /// of leaving the text to the coalescing window (`AppState.updateNote`).
    @FocusState private var focusedNote: UUID?
    /// Page groups the reader has collapsed. Empty means every group is expanded: the panel is
    /// opened to read annotations, and a review PDF's threads should not hide behind a second
    /// click. Disclosure is local view state, so switching tabs or documents resets it.
    @State private var collapsedAnnotationPages: Set<Int> = []
    /// The visible thumbnail cells, in the strip's coordinate space. The AppKit drag overlay
    /// uses these frames to decide which page a press is on and where an insertion line belongs;
    /// the values only change when cells appear or disappear, not while the strip scrolls.
    @State private var thumbnailFrames: [Int: CGRect] = [:]

    /// The coordinate space that makes the SwiftUI cell frames and the AppKit overlay agree.
    private static let thumbnailStripSpace = "LyraReaderThumbnailStrip"

    public init(state: AppState, opener: DocumentOpenCoordinator? = nil, pageOverview: Bool = false) {
        self.state = state
        self.opener = opener
        self.pageOverview = pageOverview
    }

    public var body: some View {
        Group {
            if pageOverview {
                thumbnailStrip
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(SidebarTab.sidebarPickerTabs) { tab in
                            Button { state.sidebarTab = tab } label: {
                                Image(systemName: tab.systemImage)
                                    .frame(maxWidth: .infinity, minHeight: 30)
                            }
                            .buttonStyle(LyraReaderSidebarTabStyle(selected: state.sidebarTab == tab))
                            .overlay(alignment: .trailing) {
                                if tab != SidebarTab.sidebarPickerTabs.last {
                                    LyraReaderTheme.border.frame(width: 1)
                                }
                            }
                            .accessibilityLabel(tab.title).help(tab.title)
                            .accessibilityValue(state.sidebarTab == tab ? "Selected" : "")
                        }
                    }
                    .overlay { Rectangle().strokeBorder(LyraReaderTheme.border, lineWidth: 1).allowsHitTesting(false) }
                    .padding(8)
                    HStack {
                        Text(state.sidebarTab.title).font(.headline)
                        Spacer(minLength: 0)
                        if state.sidebarTab == .bookmarks {
                            Button { state.addBookmarkAtCurrentPage() } label: { Image(systemName: "plus") }
                                .buttonStyle(LyraReaderToolStyle())
                                .disabled(state.document == nil)
                                .accessibilityLabel("Add Bookmark")
                                .help("Bookmark this page (⌘D)")
                        }
                    }.padding(.horizontal, 12).padding(.bottom, 7)
                    Divider()

                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 180)
        .scrollContentBackground(.hidden)
        .background(pageOverview ? LyraReaderTheme.canvasBg : LyraReaderTheme.sidebarBg)
        .background(SidebarScrollTheme().id(state.sidebarTab).id(state.document?.url)
            .id(state.annotationSidebarPages.isEmpty))
        .foregroundStyle(LyraReaderTheme.textPrimary)
        .tint(LyraReaderTheme.accent)
        // Dropping a file here opens a new window (the canvas keeps opening tabs in this one).
        // The whole panel is the target: thumbnails, the outline and the empty background all
        // answer the same way, because "on the sidebar" is one place to a reader holding a file.
        .onDrop(
            of: [.fileURL],
            delegate: SidebarFileDropDelegate(coordinator: pageOverview ? nil : opener, session: dropSession)
        )
        .overlay {
            if let hint = opener?.newWindowDropHint {
                FileDropOverlay(hint: hint)
            }
        }
        .animation(.easeOut(duration: 0.12), value: opener?.newWindowDropHint)
    }

    @ViewBuilder
    private var content: some View {
        switch state.sidebarTab {
        case .thumbnails:
            thumbnailStrip
        case .outline:
            outlineList
        case .search:
            SearchResultSidebar(state: state)
        case .bookmarks:
            bookmarkList
        case .annotations:
            annotationList
        case .metadata:
            DocumentInformationContent(state: state)
        }
    }

    // MARK: - Thumbnails

    private var thumbnailStrip: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailWidth + 16), spacing: pageOverview ? 28 : 10)], spacing: pageOverview ? 24 : 10) {
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
                            .fill(page + 1 == state.currentPage ? LyraReaderTheme.selectedBg : .clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                state.pageSelection.contains(page) ? LyraReaderTheme.accentBorder : .clear,
                                lineWidth: 2
                            )
                    )
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ThumbnailCellFramesKey.self,
                                value: [ThumbnailCellFrame(
                                    page: page,
                                    rect: proxy.frame(in: .named(Self.thumbnailStripSpace))
                                )]
                            )
                        }
                    )
                    .contextMenu {
                        pageContextMenu(for: page)
                    }
                }
            }
            .padding(pageOverview ? 28 : 10)
            .coordinateSpace(name: Self.thumbnailStripSpace)
            // One AppKit view owns the strip's pointer: it keeps a press under the drag
            // threshold a click (navigating exactly as the Button does), turns a longer press
            // into a native page drag, and draws the insertion line.
            .overlay {
                thumbnailDragOverlay
            }
            .onPreferenceChange(ThumbnailCellFramesKey.self) { cells in
                var next: [Int: CGRect] = [:]
                for cell in cells where next[cell.page] == nil {
                    next[cell.page] = cell.rect
                }
                if next != thumbnailFrames { thumbnailFrames = next }
            }
        }
        .onAppear { state.loadThumbnails() }
    }

    private var overviewDoubleClick: (@MainActor (Int) -> Void)? {
        guard pageOverview else { return nil }
        return { [weak state] page in
            state?.gotoPage(page)
            state?.pageOverviewVisible = false
        }
    }

    private var thumbnailDragOverlay: some View {
        ThumbnailDragOverlay(
            pageCount: state.document?.pageCount ?? 0,
            frames: thumbnailFrames,
            dragBlock: { [weak state] page in
                state?.thumbnailDragBlock(startingAt: page) ?? .refused(.noDocument)
            },
            payloadIdentity: { [weak state] in
                guard let state, let url = state.document?.url else { return nil }
                return ThumbnailDragIdentity(
                    path: url.standardizedFileURL.path,
                    pageCount: state.document?.pageCount ?? 0
                )
            },
            dragImage: { [weak state] page, count in
                guard let state else { return nil }
                return Self.dragImage(state: state, page: page, count: count)
            },
            onClick: { [weak state] page, modifiers in
                state?.handleThumbnailClick(page, modifiers: modifiers)
            },
            onDoubleClick: overviewDoubleClick,
            onDrop: { [weak state] request in
                Task { @MainActor [weak state] in
                    _ = await state?.performThumbnailDrop(request)
                }
            },
            onRefusal: { [weak state] refusal in
                state?.statusMessage = refusal.message
            },
            menu: { [weak state] page in
                guard let state else { return nil }
                return PageContextMenu.menu(
                    state: state,
                    page: page,
                    canOpenNewWindow: opener?.canOpenInNewWindow == true,
                    newWindow: { url, targetPage in
                        opener?.openInNewWindow([url], page: targetPage) ?? false
                    }
                )
            }
        )
    }

    /// The thumbnail's right-click menu, built from the same page/window commands the Pages menu
    /// and the window registry expose.
    ///
    /// The model decides which items exist and whether they are enabled
    /// (`PageContextMenu.sections`); this view only renders them, so a command's precondition and
    /// its menu entry cannot disagree.
    @ViewBuilder
    private func pageContextMenu(for page: Int) -> some View {
        let sections = PageContextMenu.sections(
            state: state,
            page: page,
            canOpenNewWindow: opener?.canOpenInNewWindow == true
        )
        ForEach(sections.indices, id: \.self) { sectionIndex in
            if sectionIndex > 0 { Divider() }
            ForEach(sections[sectionIndex].indices, id: \.self) { itemIndex in
                let item = sections[sectionIndex][itemIndex]
                Button(item.title) {
                    _ = PageContextMenu.perform(
                        item.action,
                        state: state,
                        newWindow: { url, targetPage in
                            opener?.openInNewWindow([url], page: targetPage) ?? false
                        }
                    )
                }
                .disabled(!item.isEnabled)
            }
        }
    }

    @ViewBuilder
    private func thumbnail(for page: Int) -> some View {
        if let image = state.thumbnails[page], let rendered = Self.image(from: image) {
            rendered
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: thumbnailWidth)
                .background(Color.white)
                .modifier(PaperImageAppearance(mode: appearance.mode))
                .overlay(Rectangle().stroke(LyraReaderTheme.pageEdge, lineWidth: 0.5))
        } else {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.primary.opacity(0.06))
                .frame(
                    width: thumbnailWidth,
                    height: thumbnailWidth * 1.414
                )
        }
    }

    /// Wraps a BGRA bitmap in a `CGImage`. The format matches what PDFium produced
    /// (premultiplied first, little endian), so no channel shuffling is needed.
    private static func cgImage(from page: PageImage) -> CGImage? {
        guard page.pixelWidth > 0, page.pixelHeight > 0 else { return nil }

        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
        guard let provider = CGDataProvider(data: page.bgra as CFData) else { return nil }
        return CGImage(
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
    }

    private static func image(from page: PageImage) -> Image? {
        guard let cgImage = cgImage(from: page) else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }

    /// The image the drag session carries: the grabbed page, with the cards behind it and a
    /// count badge when a multi-page selection is moving. It is a still of the page, not a
    /// snapshot of the live button, so the drag image looks the same whatever the reader's
    /// hover state was.
    @MainActor
    private static func dragImage(state: AppState, page: Int, count: Int) -> NSImage? {
        guard let pageImage = state.thumbnails[page],
              let cgImage = cgImage(from: pageImage) else { return nil }
        let width = max(48, state.thumbnailWidthPt)
        let aspect = CGFloat(pageImage.pixelHeight) / CGFloat(max(pageImage.pixelWidth, 1))
        let height = max(56, width * aspect)
        let depth: CGFloat = count > 1 ? 7 : 0
        let badgeHeight: CGFloat = count > 1 ? 21 : 0
        let size = NSSize(width: width + depth * 2, height: height + depth * 2 + badgeHeight)
        let pageCard = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        return NSImage(size: size, flipped: true) { rect in
            let sheets = count > 1 ? min(count, 3) : 0
            for index in stride(from: sheets - 1, through: 1, by: -1) {
                let offset = CGFloat(index) * depth
                let sheet = NSRect(x: offset, y: offset, width: width, height: height)
                let path = NSBezierPath(roundedRect: sheet, xRadius: 4, yRadius: 4)
                NSColor.windowBackgroundColor.setFill()
                path.fill()
                NSColor.separatorColor.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            let card = NSRect(x: 0, y: 0, width: width, height: height)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: card, xRadius: 4, yRadius: 4).fill()
            pageCard.draw(
                in: card.insetBy(dx: 1, dy: 1),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            let border = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            NSColor.separatorColor.setStroke()
            border.lineWidth = 1
            border.stroke()
            if count > 1 {
                let text = "\(count) pages" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.white,
                ]
                let textSize = text.size(withAttributes: attributes)
                let pill = NSRect(
                    x: (rect.width - textSize.width - 14) / 2,
                    y: height + depth + 1,
                    width: textSize.width + 14,
                    height: 18
                )
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: pill, xRadius: 9, yRadius: 9).fill()
                text.draw(
                    at: NSPoint(x: pill.minX + 7, y: pill.midY - textSize.height / 2),
                    withAttributes: attributes
                )
            }
            return true
        }
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
                        state.gotoOutlineEntry(row.entry)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(row.number)
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(LyraReaderTheme.textSecondary)
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
                                    .foregroundStyle(LyraReaderTheme.textSecondary)
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

    // MARK: - Bookmarks

    /// The reader's own bookmarks: one section per page, in the order the reader set.
    ///
    /// Renaming is committed on Return or blur (`BookmarkNameField`), not on every keystroke,
    /// so typing a title costs one sidecar write rather than one per character. Moving is
    /// explicit (↑/↓) instead of drag-only: the list is also reachable from the keyboard, and
    /// a drag in a grouped `List` cannot say whether the reader meant to reorder or to regroup.
    private var bookmarkList: some View {
        VStack(spacing: 0) {
            if state.bookmarks.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(LyraReaderTheme.textTertiary)
                    Text(state.document == nil ? "No document" : "No bookmarks")
                        .font(.callout)
                        .foregroundStyle(LyraReaderTheme.textSecondary)
                    if state.document != nil {
                        Text("⌘D or Add Bookmark puts the current page and position here.")
                            .font(.caption)
                            .foregroundStyle(LyraReaderTheme.textTertiary)
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
                        .foregroundStyle(LyraReaderTheme.textSecondary)
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
    /// PDF and sidecar markup share sentence excerpts; non-text annotations and threaded
    /// replies retain their individual rows. Only sidecar entries are editable here.
    private var annotationList: some View {
        Group {
            if state.annotations.isEmpty && state.documentAnnotations.isEmpty && !state.documentAnnotationsLoading {
                emptyState("No annotations yet", "highlighter", task: "T3.6")
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if state.documentAnnotationsLoading { ProgressView().padding(12) }
                            if let failure = state.documentAnnotationsError {
                                Text(failure).font(.caption).foregroundStyle(LyraReaderTheme.warningFg).padding(12)
                            }
                            ForEach(state.annotationSidebarPages) { page in
                                VStack(spacing: 0) {
                                    annotationPageHeader(page)
                                    if !collapsedAnnotationPages.contains(page.id) {
                                        ForEach(page.rows) { row in
                                            VStack(spacing: 0) {
                                                switch row {
                                                case .passage(let passage): passageRow(passage)
                                                case .document(let annotation): documentAnnotationRow(annotation)
                                                case .own(let annotation): ownAnnotationRow(annotation)
                                                }
                                                LyraReaderTheme.separator.frame(height: 1)
                                            }.id(row.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: state.editingAnnotationID) { _, id in
                        if let id { revealAnnotation(.own(id), scroll: scroll) }
                    }
                    .onChange(of: state.selectedDocumentAnnotationID) { _, id in
                        if let id { revealAnnotation(.document(id), scroll: scroll) }
                    }
                }
                .task(id: "\(state.document?.url?.absoluteString ?? ""):\(state.documentAnnotations.count):\(state.annotations.count)") {
                    await state.loadAnnotationPassages()
                }
                .onChange(of: focusedNote) { previous, current in
                    if previous != nil, previous != current { state.commitNoteEdits() }
                }
            }
        }
    }

    private func revealAnnotation(_ source: AnnotationSource, scroll: ScrollViewProxy) {
        for page in state.annotationSidebarPages {
            if let row = page.rows.first(where: { $0.contains(source) }) {
                collapsedAnnotationPages.remove(page.id)
                scroll.scrollTo(row.id)
                return
            }
        }
    }

    private func annotationPageHeader(_ page: AnnotationSidebarPage) -> some View {
        Button {
            if !collapsedAnnotationPages.insert(page.id).inserted { collapsedAnnotationPages.remove(page.id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsedAnnotationPages.contains(page.id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                Text("Page \(page.id + 1)").fontWeight(.semibold)
                Spacer(minLength: 2)
                Text("\(page.annotationCount)").foregroundStyle(LyraReaderTheme.textSecondary)
            }
            .font(.caption).padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LyraReaderTheme.panelBg).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(collapsedAnnotationPages.contains(page.id) ? "Collapsed" : "Expanded")
        .overlay(alignment: .bottom) { LyraReaderTheme.separator.frame(height: 1) }
    }

    private func passageRow(_ passage: AnnotationPassage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if let mark = passage.marks.first { state.jump(to: mark.source) }
            } label: {
                Text(passage.attributed(appearance: appearance.mode))
                    .font(.system(size: 12)).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(passage.text)
            ForEach(passage.marks.filter { !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { mark in
                Button { state.openPassageNote(mark.source) } label: {
                    Text(mark.note).font(.system(size: 12))
                        .foregroundStyle(LyraReaderTheme.noteFg)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(7)
                        .background(LyraReaderTheme.noteBg, in: RoundedRectangle(cornerRadius: 3))
                }.buttonStyle(.plain)
            }
            let authors = Array(Set(passage.marks.compactMap(\.author))).sorted().joined(separator: ", ")
            let date = passage.marks.compactMap(\.date).first ?? ""
            if !authors.isEmpty || !date.isEmpty {
                Text([authors, date].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(LyraReaderTheme.textTertiary)
            }
        }.padding(12)
    }

    /// One row, at its depth in the thread. A reply shows its author, date and its own text; an
    /// orphan says why it is not under a parent instead of disappearing into a silent gap.
    private func documentAnnotationRow(_ row: AnnotationPanelRow) -> some View {
        Button {
            // An editable annotation is adopted and selected, so its note, colour and geometry
            // can be edited here; a reply or an unsupported kind still jumps to the page.
            if state.selectDocumentAnnotation(row.annotation.id) {
                return
            }
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
                                .foregroundStyle(LyraReaderTheme.textSecondary)
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
                                .foregroundStyle(LyraReaderTheme.textSecondary)
                        }
                    } else {
                        Text(documentAnnotationTitle(row.annotation))
                            .font(.caption)
                            .lineLimit(3)
                        Text(documentAnnotationSubtitle(row.annotation))
                            .font(.caption2)
                            .foregroundStyle(LyraReaderTheme.textSecondary)
                    }

                    if !row.annotation.visible {
                        Label("Hidden on page", systemImage: "eye.slash")
                            .font(.caption2)
                            .foregroundStyle(LyraReaderTheme.textSecondary)
                    }
                    if row.showsPage {
                        Text("On page \(row.annotation.page + 1)")
                            .font(.caption2)
                            .foregroundStyle(LyraReaderTheme.textSecondary)
                    }
                    if let orphan = row.orphanReason {
                        Label(orphan.message, systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(LyraReaderTheme.warningFg)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .padding(.leading, CGFloat(row.depth) * 14)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A note clicked on the page opens its paper overlay and still marks this row (both go
        // through `selectedDocumentAnnotationID`); a click here jumps to the annotation's page.
        .background(state.selectedDocumentAnnotationID == row.annotation.id ? LyraReaderTheme.selectedBg : .clear)
        .contextMenu {
            if !row.annotation.isReply {
                Button("Delete Annotation", role: .destructive) {
                    _ = state.deleteDocumentAnnotation(row.annotation.id)
                }
                ForEach(Array(AppState.highlightPalette.enumerated()), id: \.offset) { _, entry in
                    Button(entry.name) {
                        _ = state.setDocumentAnnotationColor(
                            row.annotation.id, to: entry.color)
                    }
                }
            }
        }
    }

    private func replyBody(_ annotation: DocumentAnnotation) -> String {
        guard let contents = annotation.contents,
              !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return "No text" }
        return contents
    }

    /// Geometry annotations and text that could not be matched to an extracted passage.
    private func ownAnnotationRow(_ annotation: AppState.Annotation) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(red: Double(annotation.color.red) / 255,
                            green: Double(annotation.color.green) / 255,
                            blue: Double(annotation.color.blue) / 255))
                .frame(width: 8, height: 8)

            Button {
                state.jump(to: annotation)
                if annotation.kind.isPlacedText { state.beginEditingAnnotation(annotation.id) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    if annotation.kind == .signature {
                        Text("Signature image")
                            .font(.caption)
                    } else if annotation.kind.isPlacedText {
                        Text(annotation.note.isEmpty ? (annotation.kind == .textBox ? "Text Box" : "Sticky Note") : annotation.note)
                            .font(.caption)
                    } else {
                        TextField("Note", text: Binding(
                            get: { annotation.note },
                            set: { state.updateNote($0, for: annotation.id) }))
                            .textFieldStyle(.plain)
                            .font(.caption)
                            .focused($focusedNote, equals: annotation.id)
                            .onSubmit { state.commitNoteEdits() }
                    }
                    Text(ownAnnotationSubtitle(annotation))
                        .font(.caption2)
                        .foregroundStyle(LyraReaderTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { state.removeAnnotation(annotation.id) } label: {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.plain)
            .help("Delete annotation")
        }
        .padding(12)
        .contextMenu {
            ForEach(Array(AppState.highlightPalette.enumerated()), id: \.offset) { _, entry in
                Button(entry.name) {
                    _ = state.setAnnotationColor(annotation.id, to: entry.color)
                }
            }
        }
    }

    /// The one line under a sidecar annotation's note field.
    private func ownAnnotationSubtitle(_ annotation: AppState.Annotation) -> String {
        let kind = annotation.kind.rawValue
        let source = annotation.isFileOwned ? "PDF annotation · " : ""
        if annotation.kind.isPlacedText {
            let characters = annotation.note.count
            let detail = annotation.kind == .textBox
                ? "\(String(format: "%.0f", annotation.fontSize)) pt"
                : "icon"
            return "\(source)Page \(annotation.page + 1) · placed \(kind) · \(detail) · "
                + "\(characters) character\(characters == 1 ? "" : "s")"
        }
        if annotation.kind.isGeometry {
            let width = String(format: "%.1f pt", annotation.strokeWidth)
            return "\(source)Page \(annotation.page + 1) · \(kind) · \(width) stroke"
        }
        if annotation.kind.isStampArtwork {
            let detail = annotation.kind == .signature
                ? "picture"
                : "\(annotation.stampStyle ?? "custom") · \(annotation.note.count) character\(annotation.note.count == 1 ? "" : "s")"
            return "\(source)Page \(annotation.page + 1) · \(kind) · \(detail)"
        }
        if annotation.isFileOwned {
            return "\(source)Page \(annotation.page + 1) · \(kind)"
        }
        return "Page \(annotation.page + 1) · \(kind) · "
            + "\(annotation.end - annotation.start + 1) characters"
    }

    /// What an annotation found in the PDF is called in the list.
    private func documentAnnotationTitle(_ annotation: DocumentAnnotation) -> String {
        if let contents = annotation.contents, !contents.isEmpty { return contents }
        switch annotation.kind {
        case "highlight": return "Highlight"
        case "underline": return "Underline"
        case "strikeout": return "Strikethrough"
        case "squiggly": return "Squiggly underline"
        case "text": return "Sticky note (no text)"
        case "freeText": return "Free text (no text)"
        case "stamp":
            if let text = annotation.stampText, !text.isEmpty { return text }
            return "Stamp"
        default: return "\(annotation.kind) annotation"
        }
    }

    private func documentAnnotationSubtitle(_ annotation: DocumentAnnotation) -> String {
        var parts = ["Page \(annotation.page + 1)"]
        if let author = annotation.author, !author.isEmpty { parts.append(author) }
        if let date = annotation.displayDate { parts.append(date) }
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
                .foregroundStyle(LyraReaderTheme.textTertiary)
            Text(title)
                .font(.callout)
                .foregroundStyle(LyraReaderTheme.textSecondary)
            Text("Planned for \(task)")
                .font(.caption)
                .foregroundStyle(LyraReaderTheme.textTertiary)
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

// MARK: - Sidebar file drop (new window)

/// Mutable state shared with ``SidebarFileDropDelegate``: one drag generation.
///
/// SwiftUI constructs a `DropDelegate` value, so it cannot own the "a newer drag began" counter
/// itself. The class lives in `@State` for the lifetime of the sidebar and is what keeps a slow
/// `NSItemProvider` load from a previous drag from painting a highlight — or opening a file — over
/// the drag the reader is actually making.
@MainActor
final class SidebarDropSession {
    private(set) var generation = 0
    /// True once the reader let go: a late enter-load must not bring the hint back.
    private(set) var finished = false

    func begin() -> Int {
        generation += 1
        finished = false
        return generation
    }

    func cancel() -> Int {
        generation += 1
        finished = true
        return generation
    }

    func tokenIsCurrent(_ token: Int) -> Bool { token == generation }
}

/// Accepts file drags on the sidebar and routes them to ``DocumentOpenCoordinator``'s
/// new-window path.
///
/// The unchanged part of the drop story stays where it was: the canvas is an AppKit
/// `NSDraggingDestination` and opens a tab in this window. The sidebar is the one target whose
/// meaning differs, so it answers with a new window and says so while the drag hovers. A drag the
/// app would refuse still gets a sentence (the coordinator's `FileOpenPolicy` refusal), never a
/// silent no-op.
struct SidebarFileDropDelegate: DropDelegate {
    let coordinator: DocumentOpenCoordinator?
    let session: SidebarDropSession

    func validateDrop(info: DropInfo) -> Bool {
        coordinator != nil && info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        guard let coordinator else { return }
        let token = session.begin()
        Self.fileURLs(from: info) { urls in
            guard session.tokenIsCurrent(token), !session.finished else { return }
            _ = coordinator.previewNewWindowDrop(urls)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        _ = session.cancel()
        coordinator?.endNewWindowDropPreview()
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let coordinator, info.hasItemsConforming(to: [.fileURL]) else { return false }
        // Invalidate the enter-load first: it must not re-publish a hover hint after the drop.
        let token = session.cancel()
        coordinator.endNewWindowDropPreview()
        Self.fileURLs(from: info) { urls in
            guard session.tokenIsCurrent(token) else { return }
            _ = coordinator.acceptNewWindowDrop(urls)
        }
        return true
    }

    /// Reads the file URLs a drag is carrying from its item providers.
    ///
    /// `DropInfo` exposes providers rather than a pasteboard, so the URL arrives asynchronously.
    /// The load is per provider and ordered back into the drag order; duplicates are removed the
    /// same way the canvas removes them.
    private static func fileURLs(
        from info: DropInfo,
        completion: @escaping @MainActor ([URL]) -> Void
    ) {
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else {
            completion([])
            return
        }
        let collector = FileURLCollector(count: providers.count)
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            group.enter()
            provider.loadDataRepresentation(
                forTypeIdentifier: UTType.fileURL.identifier
            ) { data, _ in
                if let data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    collector.store(url, at: index)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                completion(collector.urls)
            }
        }
    }
}

/// Collects URLs from item-provider callbacks, which arrive on arbitrary queues.
private final class FileURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [URL?]

    init(count: Int) {
        slots = Array(repeating: nil, count: count)
    }

    func store(_ url: URL, at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard slots.indices.contains(index) else { return }
        slots[index] = url
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        var seen = Set<String>()
        return slots.compactMap { $0 }.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
