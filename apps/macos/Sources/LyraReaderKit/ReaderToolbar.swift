import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Full-width document tabs sit above all commands, independently of the sidebar.
///
/// The row uses one set of numbers, ``TabRowLayout``: the traffic lights (positioned by
/// ``ReaderTitlebarLayout``), the tab titles, their close affordances and the plus button all
/// share the 44 pt row's centre line. The tab's *whole* rectangle selects it; only the 24 pt
/// close affordance on the right closes it, and its 4 pt right-hand padding still selects.
public struct TabStrip: View {
    public static let height: CGFloat = TabRowLayout.height

    @ObservedObject public var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        GeometryReader { geometry in
            // Reserve the add button and a small draggable gap before dividing the remaining
            // space equally. Filename length never participates in a tab's width.
            let count = CGFloat(max(1, state.tabs.count))
            let available = max(0, geometry.size.width - 20 - 24 - 6)
            let tabWidth = min(TabRowLayout.maximumTabWidth,
                               max(TabRowLayout.minimumTabWidth,
                                   (available - 32 - CGFloat(state.tabs.count) * 4) / count))
            let stripWidth = min(available, CGFloat(state.tabs.count) * (tabWidth + 4) + 32)
            HStack(spacing: 6) {
                ScrollViewReader { scroll in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: TabRowLayout.tabSpacing) {
                            ForEach(Array(state.tabs.enumerated()), id: \.element.id) { index, tab in
                                tabItem(tab, index: index, width: tabWidth)
                                    .id(tab.id)
                            }
                            Button { state.showFileImporter = true } label: { Image(systemName: "plus") }
                                .buttonStyle(LyraReaderToolStyle())
                                .frame(width: TabRowLayout.plusButtonSize,
                                       height: TabRowLayout.plusButtonSize)
                                .help("Open a PDF in a new tab (⌘O)")
                                .accessibilityLabel("Open PDF").id("new-tab")
                        }
                        .frame(height: TabRowLayout.height)
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
            .frame(height: TabRowLayout.height)
            .padding(.horizontal, TabRowLayout.tabStripHorizontalPadding)
        }
        .frame(height: Self.height)
        .background(LyraReaderTheme.tabbarBg)
        .overlay(alignment: .bottom) { LyraReaderTheme.separator.frame(height: 1) }
    }

    /// One tab. The selection surface covers the whole rectangle; the close button is drawn on
    /// top of its right-hand end and takes only its own 24 pt. A drag wins over the tap gesture
    /// at 3 pt, so a drag that starts on a tab never half-switches: it is ignored here, while
    /// the empty part of the row is still an AppKit window-drag area.
    private func tabItem(_ tab: AppState.OpenTab, index: Int, width: CGFloat) -> some View {
        let active = index == state.activeTabIndex
        return ZStack(alignment: .trailing) {
            HStack(spacing: 4) {
                Image(systemName: active && state.isReadOnlyDocument ? "lock.doc" : "doc.text")
                Text(tab.title)
                    .lineLimit(1).truncationMode(.tail)
                if active && state.isReadOnlyDocument {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(LyraReaderTheme.warningFg)
                        .help(state.readOnlyReason ?? state.readOnlyBannerTitle)
                        .accessibilityLabel(state.isXfaDocument
                                            ? "XFA form, read-only"
                                            : "Signed PDF, read-only")
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: active ? .medium : .regular))
            .padding(.leading, 12)
            .padding(.trailing, TabRowLayout.closeButtonWidth
                     + TabRowLayout.closeButtonTrailingInset + 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { state.selectTab(index) }
            .highPriorityGesture(DragGesture(minimumDistance: 3))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(active ? "Selected" : "")
            .accessibilityAction { state.selectTab(index) }

            Button { state.closeTab(index) } label: {
                Image(systemName: state.tabHasUnsavedChanges(index) ? "circle.fill" : "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: TabRowLayout.closeButtonWidth,
                           height: TabRowLayout.contentHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, TabRowLayout.closeButtonTrailingInset)
            .help(state.tabHasUnsavedChanges(index) ? "Unsaved changes · Close \(tab.title)" : "Close \(tab.title)")
            .accessibilityLabel("Close \(tab.title)")
        }
        .frame(width: width, height: TabRowLayout.height)
        .foregroundStyle(active ? LyraReaderTheme.textPrimary : LyraReaderTheme.textSecondary)
        .background {
            if active {
                UnevenRoundedRectangle(topLeadingRadius: 7, topTrailingRadius: 7)
                    .fill(LyraReaderTheme.raisedBg)
                    .padding(.top, (TabRowLayout.height - TabRowLayout.contentHeight) / 2)
            }
        }
        .overlay(alignment: .bottom) {
            if active { LyraReaderTheme.accent.frame(height: 2) }
        }
        .overlay(alignment: .trailing) {
            if !active {
                LyraReaderTheme.controlBorder.opacity(0.45)
                    .frame(width: 1, height: 22).padding(.trailing, -2)
            }
        }
        .help(tab.title)
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
        .background(LyraReaderTheme.toolbarBg)
        .overlay(alignment: .bottom) { LyraReaderTheme.separator.frame(height: 1) }
        .buttonStyle(LyraReaderToolStyle())
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
            LyraReaderMenu(title: "View settings", items: ReaderLayoutMode.allCases.map { mode in
                LyraReaderMenuItem(mode.title, icon: mode == .facing ? "book" : "rectangle",
                             selected: state.layoutMode == mode) { state.setLayoutMode(mode) }
            }) { menuLabel("book") }.disabled(state.pageOverviewVisible)
            separator
            HStack(spacing: 0) {
                tool("Zoom out (⌘−)", "minus") { state.zoomOut() }
                LyraReaderMenu(title: "Zoom", items: [
                    LyraReaderMenuItem("Actual Size (100%)", icon: "1.magnifyingglass", shortcut: "⌘0") { state.zoomActual() },
                    LyraReaderMenuItem("Fit Width", icon: "arrow.left.and.right", shortcut: "⌘9") { state.zoomFitWidth() },
                    LyraReaderMenuItem("Fit Page", icon: "arrow.up.left.and.arrow.down.right", shortcut: "⇧⌘9") { state.zoomFitPage() },
                    LyraReaderMenuItem("Zoom In", icon: "plus.magnifyingglass", shortcut: "⌘+") { state.zoomIn() },
                    LyraReaderMenuItem("Zoom Out", icon: "minus.magnifyingglass", shortcut: "⌘−") { state.zoomOut() },
                ]) {
                    HStack(spacing: 4) {
                        Text("\(state.zoomPercent)%").monospacedDigit().fixedSize()
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }.font(.system(size: 12)).frame(minWidth: 60, minHeight: 32)
                }
                tool("Zoom in (⌘+)", "plus") { state.zoomIn() }
            }.disabled(state.pageOverviewVisible)
            separator
            Button { state.toggleAnnotationTools() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "highlighter")
                    if !compact { Text("Annotate").font(.system(size: 12, weight: .medium)) }
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }.padding(.horizontal, 6)
            }
            .buttonStyle(LyraReaderToolStyle(selected: state.annotationToolsVisible && !state.pageOverviewVisible))
            .help("Show annotation tools").accessibilityLabel("Annotation tools")
            .accessibilityValue(state.annotationToolsVisible ? "Expanded" : "Collapsed")
            Button { state.toggleContentEditing() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "character.cursor.ibeam")
                    if !compact { Text("Edit").font(.system(size: 12, weight: .medium)) }
                }.padding(.horizontal, 6)
            }.buttonStyle(LyraReaderToolStyle(selected:state.contentEditEnabled))
                .disabled(!state.canPageEdit)
                .help("Show PDF editing tools").accessibilityLabel("Edit")
                .accessibilityValue(state.contentEditEnabled ? "Expanded" : "Collapsed")
            LyraReaderMenu(title: "Organise pages", items: [
                LyraReaderMenuItem("Rotate Clockwise", icon: "rotate.right", enabled: state.canPageEdit) { state.rotateSelectedPages(clockwise: true) },
                LyraReaderMenuItem("Rotate Anticlockwise", icon: "rotate.left", enabled: state.canPageEdit) { state.rotateSelectedPages(clockwise: false) },
                .separator("page-operations"),
                LyraReaderMenuItem("Insert Blank Page After", icon: "doc.badge.plus", enabled: state.canPageEdit) { state.insertBlankPage(before: false) },
                LyraReaderMenuItem("Extract Selected Pages…", icon: "doc.on.doc", enabled: state.canPageOperations,
                                   help: state.canPageOperations ? nil : state.readOnlyReason) { state.presentExtractPagesPanel() },
                .separator("merge-split"),
                LyraReaderMenuItem("Append Pages from PDFs…", icon: "doc.badge.plus", enabled: state.canPageOperations,
                                   help: state.canPageOperations ? nil : state.readOnlyReason) { state.presentMergeDocumentsPanel() },
                LyraReaderMenuItem("Split Pages…", icon: "scissors", enabled: state.canPageOperations,
                                   help: state.canPageOperations ? nil : state.readOnlyReason) { state.presentSplitPagesPanel() },
            ]) { menuLabel("doc.on.doc") }
            LyraReaderMenu(title: "Export and save", items: [
                LyraReaderMenuItem("Save", icon: "square.and.arrow.down", shortcut: "⌘S", enabled: state.canSaveDocument) { state.saveDocument() },
                LyraReaderMenuItem("Save As…", icon: "doc.on.doc", shortcut: "⇧⌘S", enabled: state.canSaveDocument) { state.presentSaveDocumentCopyPanel() },
                .separator("forms"),
                LyraReaderMenuItem("Save Filled Form Copy…", icon: "signature", enabled: state.canSaveFilledForm,
                                   help: state.isReadOnlyDocument ? state.readOnlyReason : nil) {
                    state.presentSaveFilledFormPanel()
                },
                LyraReaderMenuItem("Write Form Values to Original…", icon: "doc.badge.arrow.up", enabled: state.canReplaceOriginalWithFilledForm,
                                   help: state.isReadOnlyDocument ? state.readOnlyReason : nil) {
                    state.presentReplaceOriginalWithFilledFormConfirmation()
                },
            ]) { menuLabel("square.and.arrow.up") }
            // Fill & Sign is a menu, not a mode. Form fields fill by clicking whenever no
            // annotation/content tool owns the pointer, so there is no "form tool" to arm and
            // nothing to grey out when a document has no fields: the menu opens and explains.
            // Its placement contents are a separate change; this stub exposes the form commands
            // that exist today.
            LyraReaderMenu(title: AnnotationToolbarLayout.fillAndSignLabel, items: state.fillAndSignMenuCommands.map { command in
                LyraReaderMenuItem(
                    command.title,
                    icon: command.id == "save-filled-copy" ? "square.and.arrow.down" : "doc.badge.arrow.up",
                    enabled: command.enabled,
                    help: command.help
                ) {
                    state.performFillAndSignCommand(command.id)
                }
            }) {
                // A form/field glyph, not the `signature` symbol: the Signature tool below is
                // what places a signature picture.
                Image(systemName: AnnotationToolbarLayout.fillAndSignIcon)
            }
            .disabled(!state.canOpenFillAndSignMenu)
            .help(state.fillAndSignMenuHelp)
            .accessibilityLabel(AnnotationToolbarLayout.fillAndSignLabel)
            .accessibilityValue(state.canOpenFillAndSignMenu ? "" : "No document")
            separator
            Button { state.toggleRegionSelection() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "rectangle.dashed")
                    if !compact { Text("Ask Region").font(.system(size: 12, weight: .medium)) }
                }
            }
            .buttonStyle(LyraReaderToolStyle(selected: state.regionSelectionArmed))
            .disabled(!state.canArmRegionSelection)
            .help(state.regionSelectionUnavailableReason
                  ?? "Drag a rectangle over the page; the question opens in a gap below it")
            .accessibilityLabel("Ask about a region")
            .accessibilityValue(state.regionSelectionArmed ? "Armed" : "")
            tool(state.translationSelectionTitle, "character.bubble",
                 selected: state.translationSelectionAction == .showOriginal) {
                state.performTranslationAction()
            }
            .disabled(!state.canTranslateSelection)
            .help(state.selection == nil
                  ? "Select text on the page to translate it in place"
                  : "\(state.translationSelectionTitle) (⇧⌘L)")
            .accessibilityLabel(state.translationSelectionTitle)
            .accessibilityValue(state.selection == nil ? "No selection" : "Selection on page \(state.selection!.page + 1)")
            Button {
                state.toggleRightPanel()
            } label: { LyraAIIcon().frame(width: 20, height: 20) }
            .buttonStyle(LyraReaderToolStyle(selected: state.rightPanelVisible))
            .help("AI assistant (⇧⌘A)")
            .accessibilityLabel("AI assistant panel")
            .accessibilityValue(state.rightPanelVisible ? "Open" : "Closed")
            .keyboardShortcut("a", modifiers: [.command, .shift])
            LyraReaderMenu(title: "More commands", items: [
                LyraReaderMenuItem("Open PDF…", icon: "folder", shortcut: "⌘O") { state.showFileImporter = true },
                LyraReaderMenuItem("Add Bookmark", icon: "bookmark.badge.plus", shortcut: "⌘D",
                                   enabled: state.document != nil) { state.addBookmarkAtCurrentPage() },
                LyraReaderMenuItem("Previous Page", icon: "chevron.up", enabled: state.document != nil) { state.previousPage() },
                LyraReaderMenuItem("Next Page", icon: "chevron.down", enabled: state.document != nil) { state.nextPage() },
                .separator("more"),
                LyraReaderMenuItem("Undo", icon: "arrow.uturn.backward", shortcut: "⌘Z", enabled: state.canUndo) { state.undo() },
                LyraReaderMenuItem("Close Reference Preview", icon: "rectangle.on.rectangle", enabled: state.referencePreview != nil) { state.closeReferencePreview() },
                LyraReaderMenuItem("Ask about a Region", icon: "rectangle.dashed",
                                   enabled: state.canArmRegionSelection) {
                    state.toggleRegionSelection()
                },
                LyraReaderMenuItem("Export Region Questions…", icon: "square.and.arrow.up",
                                   enabled: state.hasExportableRegionHistory) {
                    state.presentRegionHistoryExportPanel()
                },
                LyraReaderMenuItem("Document Information…", icon: "info.circle", shortcut: "⌥⌘I", enabled: state.document != nil) {
                    state.showDocumentInformation = true
                },
                LyraReaderMenuItem("Settings…", icon: "gearshape", shortcut: "⌘,") { openSettings() },
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
            Image(systemName: "magnifyingglass").foregroundStyle(LyraReaderTheme.iconSecondary)
            TextField("Search", text: $state.searchQuery)
                .textFieldStyle(.plain).font(.system(size: 12))
                .frame(maxWidth: .infinity)
                .onSubmit { state.pageOverviewVisible = false; state.runSearch() }
            if !state.searchQuery.isEmpty {
                Button { state.clearSearch() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(LyraReaderTheme.iconSecondary)
                        .frame(width: 20, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search").help("Clear search")
            }
        }
        .padding(.leading, 9).padding(.trailing, 5)
        .frame(width: compact ? 140 : 190, height: 32)
        .background(LyraReaderTheme.fieldBg, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(LyraReaderTheme.controlBorder, lineWidth: 0.5))
    }

    private var separator: some View { LyraReaderTheme.separator.frame(width: 1, height: 22).padding(.horizontal, 4) }

    private func tool(_ title: String, _ icon: String, selected: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }
            .buttonStyle(LyraReaderToolStyle(selected: selected))
            .help(title).accessibilityLabel(title)
            .accessibilityValue(selected ? "Selected" : "")
    }

    private func pending(_ title: String, _ icon: String) -> some View {
        Button {} label: { Image(systemName: icon) }
            .disabled(true).help("\(title) · Coming soon").accessibilityLabel("\(title), coming soon")
    }

    /// Asks for the PNG (or JPEG) a reader signs with, then arms the signature tool.
    ///
    /// PNG with transparency is the normal case: the picture's alpha is carried into the PDF as
    /// an image `/SMask`, so the page shows through around the strokes exactly as it does here.
    @MainActor
    fileprivate static func chooseSignatureImage(for state: AppState) {
        let panel = NSOpenPanel()
        panel.title = "Choose a Signature Image"
        panel.message = "Choose a PNG with a transparent background (or a JPEG). "
            + "To draw a signature instead, use the pen."
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        state.armSignatureTool(imageData: data)
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
            } else if state.contentEditEnabled {
                contentEditRow
            } else {
                annotationRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(height: ReaderChrome.secondaryToolbarHeightPt)
        .background(ReaderChromeMarkerHost(kind: .secondaryToolbar))
        .background(LyraReaderTheme.panelBg)
        .overlay(alignment: .bottom) { LyraReaderTheme.separator.frame(height: 1) }
        .buttonStyle(LyraReaderToolStyle())
    }

    /// Help for a tool that changes the document: a signed file says where the edit can go.
    private func writeHelp(_ normal: String) -> String {
        if state.isXfaDocument {
            return normal + " · not available: this XFA form is rendered read-only from its XML"
        }
        return state.isReadOnlyDocument ? normal + " · edits are saved to a copy" : normal
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
            }.disabled(!state.canPageOperations)
             .help(writeHelp("Write the selected pages to a new PDF"))
            Button { state.confirmDeleteSelectedPages() } label: {
                Label("Delete", systemImage: "trash")
            }.disabled(!state.canPageEdit || state.selectedPageIndices.count >= (state.document?.pageCount ?? 0))
            Spacer(minLength: 0)
            Text("\(state.selectedPageIndices.count) selected")
                .foregroundStyle(LyraReaderTheme.textSecondary)
            Button { state.pageOverviewVisible = false } label: {
                Label("Done", systemImage: "checkmark")
            }.accessibilityLabel("Close page overview")
        }.font(.system(size: 12))
    }

    private var contentEditRow: some View {
        ContentEditToolRow(state: state)
    }

    private var annotationRow: some View {
        AnnotationToolRow(state: state)
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
