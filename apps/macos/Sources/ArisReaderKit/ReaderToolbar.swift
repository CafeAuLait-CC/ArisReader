import AppKit
import SwiftUI

/// Full-width document tabs sit above all commands, independently of the sidebar.
struct TabStrip: View {
    static let height: CGFloat = 44

    @ObservedObject var state: AppState

    var body: some View {
        GeometryReader { geometry in
            // Reserve the add button and a small draggable gap before dividing the remaining
            // space equally. Filename length never participates in a tab's width.
            let count = CGFloat(max(1, state.tabs.count))
            let available = max(0, geometry.size.width - 20 - 24 - 6)
            let tabWidth = min(250, max(96, (available - 32 - CGFloat(state.tabs.count) * 4) / count))
            let stripWidth = min(available, CGFloat(state.tabs.count) * (tabWidth + 4) + 32)
            HStack(spacing: 6) {
                ScrollViewReader { scroll in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(state.tabs.enumerated()), id: \.element.id) { index, tab in
                                HStack(spacing: 4) {
                                    Button { state.selectTab(index) } label: {
                                        Label(tab.title, systemImage: "doc.text")
                                            .lineLimit(1).truncationMode(.tail)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.leading, 12).padding(.vertical, 10)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityValue(index == state.activeTabIndex ? "Selected" : "")
                                    Button { state.closeTab(index) } label: {
                                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                                            .frame(width: 24, height: 28)
                                    }
                                    .buttonStyle(.plain).help("Close \(tab.title)")
                                    .accessibilityLabel("Close \(tab.title)")
                                    .padding(.trailing, 4)
                                }
                                .frame(width: tabWidth)
                                .font(.system(size: 12, weight: index == state.activeTabIndex ? .medium : .regular))
                                .foregroundStyle(index == state.activeTabIndex ? LyraTheme.textPrimary : LyraTheme.textSecondary)
                                .background(index == state.activeTabIndex ? LyraTheme.raisedBg : .clear,
                                            in: UnevenRoundedRectangle(topLeadingRadius: 7, topTrailingRadius: 7))
                                .overlay(alignment: .bottom) {
                                    if index == state.activeTabIndex { LyraTheme.accent.frame(height: 2) }
                                }
                                .id(tab.id)
                                .help(tab.title)
                            }
                            Button { state.showFileImporter = true } label: { Image(systemName: "plus") }
                                .buttonStyle(LyraToolStyle()).frame(width: 32, height: 32)
                                .help("Open a PDF in a new tab (⌘O)")
                                .accessibilityLabel("Open PDF").id("new-tab")
                        }
                    }
                    .onChange(of: state.activeTabIndex) { _, index in
                        guard let index, state.tabs.indices.contains(index) else { return }
                        if index == state.tabs.count - 1 { scroll.scrollTo("new-tab", anchor: .trailing) }
                        else { scroll.scrollTo(state.tabs[index].id) }
                    }
                }
                .frame(width: stripWidth)
                ReaderWindowDragArea().frame(minWidth: 24, maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10).padding(.top, 6)
        }
        .frame(height: Self.height)
        .background(LyraTheme.tabbarBg)
        .overlay(alignment: .bottom) { LyraTheme.separator.frame(height: 1) }
    }
}

/// Reader controls and tool categories. Unimplemented commands have reserved, disabled
/// positions; existing annotation commands still act on the current selection.
///
/// The contextual second row (annotation tools, page overview) is no longer part of this
/// `VStack`: it is drawn over the canvas by ``ReaderSecondaryToolbar`` so that opening it does not
/// move the document. The primary row keeps its position and height.
struct ReaderToolbar: View {
    @ObservedObject var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ViewThatFits(in: .horizontal) {
            primaryRow(compact: false)
            primaryRow(compact: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(LyraTheme.toolbarBg)
        .overlay(alignment: .bottom) { LyraTheme.separator.frame(height: 1) }
        .buttonStyle(LyraToolStyle())
        .fixedSize(horizontal: false, vertical: true)
    }

    private func primaryRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 3 : 7) {
            tool("Toggle sidebar", "sidebar.left", selected: state.sidebarVisible) {
                if state.pageOverviewVisible {
                    state.pageOverviewVisible = false
                    state.sidebarVisible = true
                } else { state.sidebarVisible.toggle() }
            }
            tool("Page overview", "square.grid.2x2", selected: state.pageOverviewVisible) {
                state.pageOverviewVisible.toggle()
            }.disabled(state.document == nil)
            LyraMenu(title: "View settings", items: ReaderLayoutMode.allCases.map { mode in
                LyraMenuItem(mode.title, icon: mode == .facing ? "book" : "rectangle",
                             selected: state.layoutMode == mode) { state.setLayoutMode(mode) }
            }) { menuLabel("book") }.disabled(state.pageOverviewVisible)
            separator
            HStack(spacing: 0) {
                tool("Zoom out (⌘−)", "minus") { state.zoomOut() }
                LyraMenu(title: "Zoom", items: [
                    LyraMenuItem("Actual Size (100%)", icon: "1.magnifyingglass", shortcut: "⌘0") { state.zoomActual() },
                    LyraMenuItem("Zoom In", icon: "plus.magnifyingglass", shortcut: "⌘+") { state.zoomIn() },
                    LyraMenuItem("Zoom Out", icon: "minus.magnifyingglass", shortcut: "⌘−") { state.zoomOut() },
                ]) {
                    HStack(spacing: 4) {
                        Text("\(state.zoomPercent)%").monospacedDigit().fixedSize()
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }.font(.system(size: 12)).frame(minWidth: 60, minHeight: 32)
                }
                tool("Zoom in (⌘+)", "plus") { state.zoomIn() }
            }.disabled(state.pageOverviewVisible)
            separator
            Button { state.pageOverviewVisible = false; state.annotationToolsVisible.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "highlighter")
                    if !compact { Text("Annotate").font(.system(size: 12, weight: .medium)) }
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }.padding(.horizontal, 6)
            }
            .buttonStyle(LyraToolStyle(selected: state.annotationToolsVisible && !state.pageOverviewVisible))
            .help("Show annotation tools").accessibilityLabel("Annotation tools")
            .accessibilityValue(state.annotationToolsVisible ? "Expanded" : "Collapsed")
            pending("Edit PDF", "character.cursor.ibeam")
            LyraMenu(title: "Organise pages", items: [
                LyraMenuItem("Rotate Clockwise", icon: "rotate.right", enabled: state.canPageEdit) { state.rotateSelectedPages(clockwise: true) },
                LyraMenuItem("Rotate Anticlockwise", icon: "rotate.left", enabled: state.canPageEdit) { state.rotateSelectedPages(clockwise: false) },
                .separator("page-operations"),
                LyraMenuItem("Insert Blank Page After", icon: "doc.badge.plus", enabled: state.canPageEdit) { state.insertBlankPage(before: false) },
                LyraMenuItem("Extract Selected Pages…", icon: "doc.on.doc", enabled: state.document != nil) { state.presentExtractPagesPanel() },
            ]) { menuLabel("doc.on.doc") }
            LyraMenu(title: "Export and save", items: [
                LyraMenuItem("Save Annotated Copy…", icon: "square.and.arrow.up", shortcut: "⌘S", enabled: state.canSaveAnnotationsToPDF) { state.presentSaveAnnotatedCopyPanel() },
                LyraMenuItem("Save and Replace Original…", icon: "doc.badge.arrow.up", shortcut: "⇧⌘S", enabled: state.canSaveAnnotationsToPDF) { state.presentReplaceOriginalConfirmation() },
                .separator("export"),
                LyraMenuItem("Save Edited Copy…", icon: "doc.on.doc", enabled: state.canApplyPageEdits) { state.presentSavePageEditsCopyPanel() },
            ]) { menuLabel("square.and.arrow.up") }
            pending("Fill & Sign", "signature")
            separator
            tool("AI assistant", "sparkles", selected: state.sidebarVisible && state.sidebarTab == .ai) {
                state.pageOverviewVisible = false
                state.sidebarTab = .ai; state.sidebarVisible = true
            }
            LyraMenu(title: "More commands", items: [
                LyraMenuItem("Open PDF…", icon: "folder", shortcut: "⌘O") { state.showFileImporter = true },
                LyraMenuItem("Add Bookmark", icon: "bookmark.badge.plus", shortcut: "⌘D", enabled: state.document != nil) { state.addBookmarkAtCurrentPage() },
                LyraMenuItem("Previous Page", icon: "chevron.up", enabled: state.document != nil) { state.previousPage() },
                LyraMenuItem("Next Page", icon: "chevron.down", enabled: state.document != nil) { state.nextPage() },
                .separator("more"),
                LyraMenuItem("Undo", icon: "arrow.uturn.backward", shortcut: "⌘Z", enabled: state.canUndo) { state.undo() },
                LyraMenuItem("Close Reference Preview", icon: "rectangle.on.rectangle", enabled: state.referencePreview != nil) { state.closeReferencePreview() },
                LyraMenuItem("Settings…", icon: "gearshape", shortcut: "⌘,") { openSettings() },
            ]) { Image(systemName: "ellipsis.circle") }
            Spacer(minLength: 4)
            search(compact: compact)
        }
    }

    private func menuLabel(_ icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }.padding(.horizontal, 4)
    }

    private func search(compact: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(LyraTheme.iconSecondary)
            TextField("Search document", text: $state.searchQuery)
                .textFieldStyle(.plain).font(.system(size: 12))
                .frame(width: compact ? 100 : 150)
                .onSubmit { state.pageOverviewVisible = false; state.runSearch() }
            if !state.searchHits.isEmpty {
                Text(state.currentHitIndex.map { "\($0 + 1)/\(state.searchHits.count)" } ?? "")
                    .font(.caption2).monospacedDigit().foregroundStyle(LyraTheme.textSecondary)
                tool("Previous match (⇧⌘G)", "chevron.up") { state.findPrevious() }
                tool("Next match (⌘G)", "chevron.down") { state.findNext() }
            }
        }
        .padding(.leading, 9).padding(.trailing, 5).frame(height: 32)
        .background(LyraTheme.fieldBg, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(LyraTheme.controlBorder, lineWidth: 0.5))
    }

    private var separator: some View { LyraTheme.separator.frame(width: 1, height: 22).padding(.horizontal, 4) }

    private func tool(_ title: String, _ icon: String, selected: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }
            .buttonStyle(LyraToolStyle(selected: selected))
            .help(title).accessibilityLabel(title)
            .accessibilityValue(selected ? "Selected" : "")
    }

    private func pending(_ title: String, _ icon: String) -> some View {
        Button {} label: { Image(systemName: icon) }
            .disabled(true).help("\(title) · Coming soon").accessibilityLabel("\(title), coming soon")
    }
}

/// The contextual second row, drawn **over** the canvas instead of above it.
///
/// It is one view with one selection rule, exactly like the row that used to sit in
/// ``ReaderToolbar``'s `VStack`: page overview wins over the annotation tools. Because both states
/// feed the same view, turning page overview on while the annotation row is open swaps the
/// content in place - it cannot stack a second overlay or leave the row's height empty.
///
/// The row is always laid out at `ReaderChrome.secondaryToolbarHeightPt` with an opaque panel
/// background and a bottom separator, so it reads as a floating row over the page and catches
/// clicks for its whole rectangle.
struct ReaderSecondaryToolbar: View {
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            if state.pageOverviewVisible {
                overviewRow
            } else {
                annotationRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(height: ReaderChrome.secondaryToolbarHeightPt)
        .background(LyraTheme.panelBg)
        .overlay(alignment: .bottom) { LyraTheme.separator.frame(height: 1) }
        .buttonStyle(LyraToolStyle())
    }

    private var overviewRow: some View {
        HStack(spacing: 10) {
            Button { state.insertBlankPage(before: false) } label: {
                Label("Insert Page", systemImage: "doc.badge.plus")
            }.disabled(!state.canPageEdit)
            Button { state.rotateSelectedPages(clockwise: true) } label: {
                Label("Rotate", systemImage: "rotate.right")
            }.disabled(!state.canPageEdit)
            Button { state.presentExtractPagesPanel() } label: {
                Label("Extract", systemImage: "square.and.arrow.up")
            }.disabled(state.document == nil)
            Button { state.confirmDeleteSelectedPages() } label: {
                Label("Delete", systemImage: "trash")
            }.disabled(!state.canPageEdit || state.selectedPageIndices.count >= (state.document?.pageCount ?? 0))
            Spacer(minLength: 0)
            Text("\(state.selectedPageIndices.count) selected")
                .foregroundStyle(LyraTheme.textSecondary)
            Button { state.pageOverviewVisible = false } label: {
                Label("Done", systemImage: "checkmark")
            }.accessibilityLabel("Close page overview")
        }.font(.system(size: 12))
    }

    private var annotationRow: some View {
        HStack(spacing: 5) {
            tool("Highlight selected text", "highlighter") {
                state.addAnnotationFromSelection(kind: .highlight, color: annotationColor)
            }.disabled(state.selection == nil)
            tool("Underline selected text", "underline") {
                state.addAnnotationFromSelection(kind: .underline, color: annotationColor)
            }.disabled(state.selection == nil)
            pending("Strikethrough", "strikethrough")
            separator
            tool("Select a mark", "arrow.up.left",
                 selected: state.annotationTool == .select) {
                state.annotationTool = .select
            }.disabled(state.document == nil)
            tool("Draw with the pen", "pencil.tip",
                 selected: state.annotationTool == .pen) {
                state.annotationTool = state.annotationTool == .pen ? .select : .pen
            }.disabled(state.document == nil)
            LyraMenu(title: "Shapes", items: [
                LyraMenuItem("Line", icon: "line.diagonal",
                             selected: state.annotationTool == .line) {
                    state.annotationTool = state.annotationTool == .line ? .select : .line
                },
                LyraMenuItem("Arrow", icon: "arrow.up.right",
                             selected: state.annotationTool == .arrow) {
                    state.annotationTool = state.annotationTool == .arrow ? .select : .arrow
                },
                LyraMenuItem("Rectangle", icon: "rectangle",
                             selected: state.annotationTool == .rectangle) {
                    state.annotationTool = state.annotationTool == .rectangle ? .select : .rectangle
                },
                LyraMenuItem("Ellipse", icon: "circle",
                             selected: state.annotationTool == .ellipse) {
                    state.annotationTool = state.annotationTool == .ellipse ? .select : .ellipse
                },
            ]) {
                Image(systemName: "square.on.circle")
            }.disabled(state.document == nil)
            pending("Eraser", "eraser")
            pending("Text box", "textbox")
            tool("Add a note to selected text", "text.bubble") {
                if let note = ReaderWindow.promptForNote() {
                    state.addAnnotationFromSelection(kind: .highlight, color: annotationColor, note: note)
                }
            }.disabled(state.selection == nil)
            pending("Stamps", "seal")
            pending("Signature", "signature")
            separator
            LyraMenu(title: "Annotation color", items: AppState.annotationPalette.enumerated().map { _, item in
                LyraMenuItem(item.name, icon: "circle.fill", selected: state.annotationColor == item.color,
                             color: Color(red: Double(item.color.red) / 255,
                                          green: Double(item.color.green) / 255,
                                          blue: Double(item.color.blue) / 255)) {
                    state.annotationColor = item.color
                }
            }) {
                Image(systemName: "circle.fill")
                    .foregroundStyle(Color(red: Double(annotationColor.red) / 255,
                                           green: Double(annotationColor.green) / 255,
                                           blue: Double(annotationColor.blue) / 255))
                    .font(.system(size: 17)).frame(width: 32, height: 32)
            }
            Spacer(minLength: 0)
            Button { state.annotationToolsVisible = false } label: {
                Image(systemName: "xmark").font(.system(size: 11))
            }.help("Hide annotation tools").accessibilityLabel("Hide annotation tools")
        }
    }

    private var annotationColor: AnnotationColor { state.annotationColor }

    private var separator: some View {
        LyraTheme.separator.frame(width: 1, height: 22).padding(.horizontal, 4)
    }

    private func tool(_ title: String, _ icon: String, selected: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }
            .buttonStyle(LyraToolStyle(selected: selected))
            .help(title).accessibilityLabel(title)
            .accessibilityValue(selected ? "Selected" : "")
    }

    private func pending(_ title: String, _ icon: String) -> some View {
        Button {} label: { Image(systemName: icon) }
            .disabled(true).help("\(title) · Coming soon").accessibilityLabel("\(title), coming soon")
    }
}

/// An explicit empty tab-bar region owns window dragging; tab/close/open buttons keep their
/// own pointer handling, and document drags continue to select text in the Metal canvas.
private struct ReaderWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
