import SwiftUI
import UniformTypeIdentifiers

/// Main window: toolbar + collapsible sidebar + canvas (`docs/04-ui-ux.md` §2).
///
/// The skeleton phase uses a hand-rolled `HStack` split instead of `NavigationSplitView`:
/// the latter would bring the system sidebar material and automatic collapsing, but its
/// `columnVisibility` binding adds risk in an environment without compile verification.
/// **M1 T1.10 will make the A/B decision with a runnable version**
/// (evaluated together with the scrolling approach in T1.4).
public struct ReaderWindow: View {
    @ObservedObject private var state: AppState
    @State private var previewExpanded = false

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 0) {
            if state.sidebarVisible {
                SidebarView(state: state)
                    .frame(width: 240)
                    .background(Color(nsColor: .windowBackgroundColor))
                Divider()
            }
            VStack(spacing: 0) {
                if !state.tabs.isEmpty { TabStrip(state: state) }
                canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            // Flush hooks for the shell: normal quit and SIGTERM/SIGINT (see AppState). Installed
            // here rather than in `AppState.init` so the check harness never takes over signals.
            state.installTerminationHandling()
        }
        .toolbar { toolbarContent }
        .alert("Lyra", isPresented: Binding(
            get: { state.lastError != nil },
            set: { if !$0 { state.lastError = nil } }
        )) {
            // The way out of a sidecar that failed to load: an explicit action that moves the
            // unreadable file aside (never overwrites it) and starts a fresh one.
            if state.canRecoverUnreadableAnnotationSidecar {
                Button("Back Up Sidecar and Start Fresh") {
                    if let backup = state.recoverUnreadableAnnotationSidecar() {
                        state.revealSidecarBackupInFinder(backup)
                    }
                }
            }
            Button("OK", role: .cancel) { state.lastError = nil }
        } message: {
            Text(state.lastError ?? "")
        }
        .fileImporter(
            isPresented: $state.showFileImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    state.newTab(url: url)
                }
            case .failure(let error):
                state.lastError = String(describing: error)
            }
        }
    }

    // MARK: - Canvas

    private var canvas: some View {
        ZStack {
            PDFCanvasView(
                pages: state.canvasPages,
                scrollYPt: state.scrollYPt,
                zoom: state.zoomFactor,
                contentWidthPt: state.contentWidthPt,
                onFrame: { stats in state.updateGpuStatus(stats, label: "GPU") },
                onFailure: { message in state.reportGpuFailure(message) },
                onDeviceScale: { scale in state.setDeviceScale(scale) },
                onViewportSize: { size in state.setViewportSize(size) },
                onScroll: { delta in state.scroll(byScreenPoints: delta) },
                onPointerDown: { point in state.beginSelection(at: point) },
                onPointerDragged: { point in state.extendSelection(to: point) },
                onPointerUp: { point, wasClick in
                    state.endPointerInteraction(at: point, wasClick: wasClick)
                },
                onCopy: { state.copySelection() },
                onUndo: { state.undo() },
                onRedo: { state.redo() },
                interactionSnapshot: { (state.canvasPages, state.scrollYPt) }
            )
            HStack { Spacer(); ScrollIndicator(state: state) }

            if state.document == nil {
                emptyState
            }

            VStack {
                Spacer()
                pageHUD
                    .padding(.bottom, 16)
            }
            secondSurface
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Open a paper to start reading")
                .font(.title3)
            Text("⌘O to open a file · drag & drop arrives in T2.12")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open PDF…") {
                state.showFileImporter = true
            }
            .controlSize(.large)
        }
        .padding(40)
    }

    /// The reference preview card (M4): page image, provenance, and the explicit jump.
    ///
    /// This is the T0.5 multi-surface proof put to work: a second `CAMetalLayer` on the same
    /// wgpu device, with its own surface id and frame loop, showing the referenced page while
    /// the reader keeps their place in the text.
    @ViewBuilder
    private func referencePanel(available: CGSize) -> some View {
        if let preview = state.referencePreview {
            let width = min(previewExpanded ? 720.0 : 480.0, max(240, available.width - 32))
            let entriesHeight = preview.entries.isEmpty ? 0.0 : min(160, available.height * 0.25)
            let desiredHeight = preview.region.map { width * $0.height / max($0.width, 1) }
                ?? state.referencePreviewPages.first.map { $0.placement.heightPt * state.referencePreviewZoom }
                ?? 400
            let imageHeight = min(max(80, desiredHeight), max(120, min(available.height - entriesHeight - 134, 600)))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(preview.title).font(.headline).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { previewExpanded.toggle() } label: {
                        Image(systemName: previewExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }.help("Resize preview")
                    Button { state.closeReferencePreview() } label: {
                        Image(systemName: "xmark")
                    }.help("Close preview")
                }.buttonStyle(.plain)
                HStack {
                    Text("From \(preview.source) · page \(preview.page + 1)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Full page") { state.showFullPreviewPage() }
                    Button("Go to page") {
                        state.gotoPage(preview.page)
                        state.closeReferencePreview()
                    }
                }.font(.caption)
                ZStack {
                    PDFCanvasView(
                        pages: state.referencePreviewPages,
                        scrollYPt: state.referencePreviewScrollYPt,
                        zoom: state.referencePreviewZoom,
                        contentWidthPt: state.referencePreviewPages.first?.placement.widthPt ?? 0,
                        onFrame: { stats in state.updateGpuStatus(stats, label: "preview") },
                        onFailure: { message in state.reportGpuFailure(message) },
                        onViewportSize: { size in state.setReferencePreviewViewport(size) },
                        onScroll: { delta in state.scrollReferencePreview(by: delta) },
                        interactionSnapshot: { (state.referencePreviewPages, state.referencePreviewScrollYPt) }
                    )
                    if state.referencePreviewLoading { ProgressView("Loading preview…") }
                    if let error = state.referencePreviewError {
                        Text(error).font(.callout).padding().background(.regularMaterial)
                    }
                }
                .frame(width: width, height: imageHeight)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                if !preview.entries.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(preview.entries.indices, id: \.self) { index in
                                let entry = preview.entries[index]
                                VStack(alignment: .leading, spacing: 4) {
                                    if entry.page != nil {
                                        Button(entry.label) { state.selectPreviewEntry(entry) }
                                            .buttonStyle(.link)
                                    } else {
                                        Text(entry.label).bold()
                                    }
                                    Text(entry.text)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.font(.callout)
                    }.frame(height: entriesHeight)
                }
                Text("Scroll inside the preview to read more. Full page shows surrounding content.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: width)
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 14)
            .onExitCommand { state.closeReferencePreview() }
        }
    }

    @ViewBuilder
    private var secondSurface: some View {
        if state.referencePreview != nil {
            GeometryReader { geometry in
                VStack {
                    Spacer(minLength: 0)
                    HStack {
                        Spacer(minLength: 0)
                        referencePanel(available: geometry.size)
                    }
                }.padding(12)
            }
        }
    }

    private var pageHUD: some View {
        Text(state.pageLabel)
            .font(.callout)
            .monospacedDigit()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .opacity(state.document == nil ? 0 : 1)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                state.showFileImporter = true
            } label: {
                Image(systemName: "folder")
            }
            .help("Open document (⌘O)")

            Button {
                state.previousPage()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(state.document == nil)
            .help("Previous page (⌘←)")

            Button {
                state.nextPage()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(state.document == nil)
            .help("Next page (⌘→)")
        }

        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(state.windowTitle)
                    .font(.headline)
                Text(state.gpuStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: Binding(
                    get: { state.searchQuery },
                    set: { state.searchQuery = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .onSubmit { state.runSearch() }

                if !state.searchHits.isEmpty {
                    Text(state.currentHitIndex.map { "\($0 + 1)/\(state.searchHits.count)" } ?? "")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button {
                    state.findPrevious()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(state.searchHits.isEmpty)
                .help("Previous match (⇧⌘G)")

                Button {
                    state.findNext()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(state.searchHits.isEmpty)
                .help("Next match (⌘G)")
            }

            Button {
                state.addAnnotationFromSelection(kind: .highlight)
            } label: {
                Image(systemName: "highlighter")
            }
            .disabled(state.selection == nil)
            .help("Highlight the selection")

            Button {
                state.addAnnotationFromSelection(kind: .underline)
            } label: {
                Image(systemName: "underline")
            }
            .disabled(state.selection == nil)
            .help("Underline the selection")

            Button {
                state.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!state.canUndo)
            .help("Undo (⌘Z)")

            Button {
                state.zoomOut()
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out (⌘−)")

            Text("\(state.zoomPercent)%")
                .font(.caption)
                .monospacedDigit()
                .frame(width: 44)

            Button {
                state.zoomIn()
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in (⌘+)")

            Button {
                state.closeReferencePreview()
            } label: {
                Image(systemName: "rectangle.on.rectangle")
            }
            .disabled(state.referencePreview == nil)
            .help("Close reference preview")

            Button {
                state.sidebarVisible.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Show/hide sidebar (⌘⌥S)")
        }
    }
}

/// Settings window (`⌘,`). During the skeleton phase it exposes one performance setting —
/// the tile-cache byte budget, which `AppState` adopts live (ADR 0007). The tile size is *not*
/// a setting: it is fixed at 512 px because changing it moves the LOD math and the cache
/// semantics with it, and no measurement supports that trade. The rest of the configuration is
/// held by the Rust side (`docs/02-architecture.md` §9).
public struct SettingsView: View {
    @ObservedObject private var state: AppState
    @AppStorage(AppState.cacheBudgetSettingKey) private var cacheBudgetMB = AppState.defaultTileCacheBudgetMB

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        TabView {
            Form {
                Text("Engine: \(state.engine.version)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Stepper("Tile cache budget: \(cacheBudgetMB) MB",
                        value: $cacheBudgetMB, in: 16...1024, step: 16)
                    .onChange(of: cacheBudgetMB) { _, _ in state.applyCacheBudgetSetting() }
                Text("Rasterized tiles are cached up to this many bytes; tiles the current view still "
                     + "needs are never evicted. The tile size is fixed at 512 px. Budgets below ~40 MB "
                     + "make zooming back re-rasterize instead of reusing cached tiles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .tabItem { Label("Performance", systemImage: "speedometer") }

            Form {
                Text("AI provider configuration, keys (Keychain), and privacy toggles arrive in M5 (T5.1 / T5.2).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 460, height: 260)
    }
}


/// Tab strip: one chip per open document (`docs/04-ui-ux.md` §2.3).
///
/// The engine holds a single document today, so switching tabs reopens the file and
/// reapplies that tab's scroll offset; per-tab offsets live in `AppState.OpenTab`.
struct TabStrip: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(state.tabs.enumerated()), id: \.element.id) { index, tab in
                HStack(spacing: 6) {
                    Text(tab.title)
                        .font(.caption)
                        .lineLimit(1)
                    Button {
                        state.closeTab(index)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help("Close tab")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            index == state.activeTabIndex
                                ? Color.accentColor.opacity(0.22)
                                : Color.primary.opacity(0.06)
                        )
                )
                .contentShape(Rectangle())
                .onTapGesture { state.selectTab(index) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
