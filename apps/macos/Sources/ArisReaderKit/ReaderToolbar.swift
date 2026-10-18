import SwiftUI

/// Full-width document tabs sit above all commands, independently of the sidebar.
struct TabStrip: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .font(.system(size: 17)).foregroundStyle(LyraTheme.accent)
                .frame(width: 34)
                .accessibilityHidden(true)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(state.tabs.enumerated()), id: \.element.id) { index, tab in
                        HStack(spacing: 4) {
                            Button { state.selectTab(index) } label: {
                                Label(tab.title, systemImage: "doc.text")
                                    .lineLimit(1).frame(minWidth: 80, maxWidth: 180, alignment: .leading)
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
                        .font(.system(size: 12, weight: index == state.activeTabIndex ? .medium : .regular))
                        .foregroundStyle(index == state.activeTabIndex ? LyraTheme.textPrimary : LyraTheme.textSecondary)
                        .background(index == state.activeTabIndex ? LyraTheme.raisedBg : .clear,
                                    in: UnevenRoundedRectangle(topLeadingRadius: 7, topTrailingRadius: 7))
                        .overlay(alignment: .bottom) {
                            if index == state.activeTabIndex { LyraTheme.accent.frame(height: 2) }
                        }
                        .help(tab.title)
                    }
                }
            }
            Button { state.showFileImporter = true } label: { Image(systemName: "plus") }
                .buttonStyle(LyraToolStyle()).help("Open a PDF in a new tab (⌘O)")
                .accessibilityLabel("Open PDF")
        }
        .padding(.horizontal, 10).padding(.top, 6)
        .frame(height: 44)
        .background(LyraTheme.tabbarBg)
        .overlay(alignment: .bottom) { LyraTheme.separator.frame(height: 1) }
    }
}

/// Reader controls, tool categories, then a contextual second row. Unimplemented commands have
/// reserved, disabled positions; existing annotation commands still act on the current selection.
struct ReaderToolbar: View {
    @ObservedObject var state: AppState
    @State private var annotationsExpanded = false
    @State private var annotationColorIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                primaryRow(compact: false)
                primaryRow(compact: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(LyraTheme.toolbarBg)
            if annotationsExpanded {
                annotationRow
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(LyraTheme.panelBg)
                    .overlay(alignment: .top) { LyraTheme.separator.frame(height: 1) }
            }
        }
        .overlay(alignment: .bottom) { LyraTheme.separator.frame(height: 1) }
        .buttonStyle(LyraToolStyle())
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func primaryRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 3 : 7) {
            tool("Toggle sidebar", "sidebar.left", selected: state.sidebarVisible) {
                state.sidebarVisible.toggle()
            }
            tool("Page thumbnails", "square.grid.2x2", selected: state.sidebarVisible && state.sidebarTab == .thumbnails) {
                if state.sidebarVisible && state.sidebarTab == .thumbnails { state.sidebarVisible = false }
                else { state.sidebarTab = .thumbnails; state.sidebarVisible = true }
            }
            Menu {
                ForEach(ReaderLayoutMode.allCases) { mode in
                    Button { state.setLayoutMode(mode) } label: {
                        Label(mode.title, systemImage: state.layoutMode == mode ? "checkmark" : "rectangle")
                    }
                }
            } label: { Image(systemName: "book") .frame(width: 30, height: 32) }
            .fixedSize().menuIndicator(.hidden)
            .help("View settings · continuous or facing pages").accessibilityLabel("View settings")
            separator
            HStack(spacing: 0) {
                tool("Zoom out (⌘−)", "minus") { state.zoomOut() }
                Menu {
                    Button("Actual Size (100%)") { state.zoomActual() }
                    Button("Zoom In") { state.zoomIn() }
                    Button("Zoom Out") { state.zoomOut() }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(state.zoomPercent)%").monospacedDigit().fixedSize()
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }.font(.system(size: 12)).frame(minWidth: 60, minHeight: 32)
                }
                .fixedSize().menuIndicator(.hidden)
                .help("Zoom").accessibilityLabel("Zoom")
                tool("Zoom in (⌘+)", "plus") { state.zoomIn() }
            }
            separator
            Button { annotationsExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "highlighter")
                    if !compact { Text("Annotate").font(.system(size: 12, weight: .medium)) }
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }.padding(.horizontal, 6)
            }
            .buttonStyle(LyraToolStyle(selected: annotationsExpanded))
            .help("Show annotation tools").accessibilityLabel("Annotation tools")
            .accessibilityValue(annotationsExpanded ? "Expanded" : "Collapsed")
            pending("Edit PDF", "character.cursor.ibeam")
            Menu {
                Button("Rotate Selected Pages Clockwise") { state.rotateSelectedPages(clockwise: true) }
                    .disabled(!state.canPageEdit)
                Button("Rotate Selected Pages Anticlockwise") { state.rotateSelectedPages(clockwise: false) }
                    .disabled(!state.canPageEdit)
                Button("Insert Blank Page After") { state.insertBlankPage(before: false) }
                    .disabled(!state.canPageEdit)
                Button("Extract Selected Pages…") { state.presentExtractPagesPanel() }
                    .disabled(state.document == nil)
            } label: { Image(systemName: "doc.on.doc").frame(width: 30, height: 32) }
            .fixedSize().menuIndicator(.hidden)
            .help("Organise pages").accessibilityLabel("Organise pages")
            Menu {
                Button("Save Annotated Copy…") { state.presentSaveAnnotatedCopyPanel() }
                    .disabled(!state.canSaveAnnotationsToPDF)
                Button("Save and Replace Original…") { state.presentReplaceOriginalConfirmation() }
                    .disabled(!state.canSaveAnnotationsToPDF)
                Divider()
                Button("Save Edited Copy…") { state.presentSavePageEditsCopyPanel() }
                    .disabled(!state.canApplyPageEdits)
            } label: { Image(systemName: "square.and.arrow.up").frame(width: 30, height: 32) }
            .fixedSize().menuIndicator(.hidden)
            .help("Export and save").accessibilityLabel("Export and save")
            pending("Fill & Sign", "signature")
            separator
            tool("AI assistant", "sparkles", selected: state.sidebarVisible && state.sidebarTab == .ai) {
                state.sidebarTab = .ai; state.sidebarVisible = true
            }
            Menu {
                Button("Open PDF…") { state.showFileImporter = true }
                Button("Add Bookmark (⌘D)") { state.addBookmarkAtCurrentPage() }
                    .disabled(state.document == nil)
                Button("Previous Page") { state.previousPage() }.disabled(state.document == nil)
                Button("Next Page") { state.nextPage() }.disabled(state.document == nil)
                Divider()
                Button("Undo") { state.undo() }.disabled(!state.canUndo)
                Button("Close Reference Preview") { state.closeReferencePreview() }
                    .disabled(state.referencePreview == nil)
                SettingsLink { Text("Settings…") }
            } label: { Image(systemName: "ellipsis.circle").frame(width: 30, height: 32) }
            .fixedSize().menuIndicator(.hidden)
            .help("More commands").accessibilityLabel("More commands")
            Spacer(minLength: 4)
            search(compact: compact)
        }
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
            pending("Draw", "pencil.tip")
            pending("Eraser", "eraser")
            pending("Text box", "textbox")
            pending("Shapes", "square.on.circle")
            tool("Add a note to selected text", "text.bubble") {
                if let note = ReaderWindow.promptForNote() {
                    state.addAnnotationFromSelection(kind: .highlight, color: annotationColor, note: note)
                }
            }.disabled(state.selection == nil)
            pending("Stamps", "seal")
            pending("Signature", "signature")
            separator
            Menu {
                ForEach(Array(AppState.annotationPalette.enumerated()), id: \.offset) { index, item in
                    Button { annotationColorIndex = index } label: {
                        Label(item.name, systemImage: annotationColorIndex == index ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
            } label: {
                Image(systemName: "circle.fill")
                    .foregroundStyle(Color(red: Double(annotationColor.red) / 255,
                                           green: Double(annotationColor.green) / 255,
                                           blue: Double(annotationColor.blue) / 255))
                    .font(.system(size: 17)).frame(width: 32, height: 32)
            }
            .fixedSize().menuIndicator(.hidden)
            .help("Annotation color: \(AppState.annotationPalette[annotationColorIndex].name)")
            .accessibilityLabel("Annotation color")
            .accessibilityValue(AppState.annotationPalette[annotationColorIndex].name)
            Spacer(minLength: 0)
            Button { annotationsExpanded = false } label: {
                Image(systemName: "xmark").font(.system(size: 11))
            }.help("Hide annotation tools").accessibilityLabel("Hide annotation tools")
        }
    }

    private var annotationColor: AnnotationColor { AppState.annotationPalette[annotationColorIndex].color }

    private func search(compact: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(LyraTheme.iconSecondary)
            TextField("Search document", text: $state.searchQuery)
                .textFieldStyle(.plain).font(.system(size: 12))
                .frame(width: compact ? 100 : 150)
                .onSubmit { state.runSearch() }
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
