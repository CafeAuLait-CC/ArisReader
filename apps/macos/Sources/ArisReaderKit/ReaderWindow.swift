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
    /// Documents arriving at *this* window: its own coordinator, so a drop on its canvas becomes a
    /// tab here and nowhere else. Files dropped on the canvas also drive its hover hint.
    @ObservedObject private var opener: DocumentOpenCoordinator
    /// The floating reference panel of this window. Defaulted to the process-wide controller so a
    /// test or preview that only has an `AppState` still works; the app passes the session's own
    /// (see `ReaderSession`).
    private let previewPanels: ReferencePreviewPanelController

    public init(
        state: AppState,
        opener: DocumentOpenCoordinator,
        previewPanels: ReferencePreviewPanelController = .shared
    ) {
        self.state = state
        self.opener = opener
        self.previewPanels = previewPanels
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
                // Precise input preserves system deltas; wheel input applies its accelerated
                // distance immediately, with no queued motion after the wheel stops.
                onScroll: { delta in state.scroll(byScreenPoints: delta) },
                onScrollStep: { delta in state.scrollByWheelStep(delta) },
                // Keyboard paging keeps its animation to the requested destination.
                onKeyboardStep: { delta in state.scrollByKeyboardStep(delta) },
                // Ctrl+scroll and ⌘+scroll zoom instead of scrolling (docs/04-ui-ux.md §3). Ctrl
                // is the binding the request asked for; ⌘ is the documented convention and the
                // fallback when macOS Accessibility zoom has taken Ctrl over. Pinch works in
                // either case because it is not a scroll gesture at all.
                onZoomScroll: { delta, anchorViewY in
                    state.zoomByScroll(delta: delta, anchorViewY: anchorViewY)
                },
                onMagnify: { magnification, anchorViewY in
                    state.zoomByPinch(magnification, anchorViewY: anchorViewY)
                },
                onPointerDown: { point in state.beginSelection(at: point) },
                onPointerDragged: { point in state.extendSelection(to: point) },
                onPointerUp: { point, wasClick in
                    state.endPointerInteraction(at: point, wasClick: wasClick)
                },
                onCopy: { state.copySelection() },
                onUndo: { state.undo() },
                onRedo: { state.redo() },
                interactionSnapshot: { (state.canvasPages, state.scrollYPt, state.zoomFactor) },
                fileDrop: opener
            )
            .background(ReferencePreviewHost(state: state, panels: previewPanels))
            HStack { Spacer(); ScrollIndicator(state: state) }

            if state.document == nil {
                emptyState
            }

            if state.pageEditSessionActive {
                VStack {
                    pageEditBanner
                    Spacer()
                }
                .padding(.top, 12)
            }

            VStack {
                Spacer()
                pageHUD
                    .padding(.bottom, 16)
            }

            DocumentNoteOverlay(state: state)

            if let hint = opener.dropHint {
                FileDropOverlay(hint: hint)
            }
        }
        .animation(.easeOut(duration: 0.12), value: opener.dropHint)
    }

    /// The one place the interface states, without qualification, that the file on disk is not
    /// what is on screen. It stays visible for the whole staged session, not just after an action.
    private var pageEditBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Page changes pending")
                    .font(.callout.weight(.semibold))
                Text(
                    [state.pageEditPendingSummary, state.pageEditLastAction]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Divider().frame(height: 24)
            Button("Undo") { state.undoPageEdit() }
                .disabled(!state.canUndoPageEdit)
            Button("Redo") { state.redoPageEdit() }
                .disabled(!state.canRedoPageEdit)
            Button("Apply to Original…") {
                state.presentReplaceOriginalWithPageEditsConfirmation()
            }
            .disabled(!state.canApplyPageEdits)
            Button("Save Copy…") { state.presentSavePageEditsCopyPanel() }
                .disabled(!state.canApplyPageEdits)
            Button("Discard…") { state.presentDiscardPageEditsConfirmation() }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.5), lineWidth: 1)
        )
        .shadow(radius: 3, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Page changes pending. The file on disk is unchanged.")
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Open a paper to start reading")
                .font(.title3)
            Text("⌘O to open a file, or drop one anywhere on the page")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open PDF…") {
                state.showFileImporter = true
            }
            .controlSize(.large)
        }
        .padding(40)
    }

    /// The floating preview lives in its own panel (`ReferencePreviewPanelController`): it has to
    /// be movable and resizable independently of this window, which an overlay cannot be. The
    /// zero-size host below only tells the controller where the canvas is.

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
                state.addBookmarkAtCurrentPage()
            } label: {
                Image(systemName: "bookmark.badge.plus")
            }
            .disabled(state.document == nil)
            .help("Add bookmark (⌘D)")

            Button {
                state.toggleFacingPages()
            } label: {
                Image(systemName: state.layoutMode == .facing
                    ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
            }
            .disabled(state.document == nil)
            .help(state.layoutMode == .facing ? "Continuous pages (⌘1)" : "Facing pages (⌘3)")

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
///
/// It reads the `ReaderWindowRegistry` rather than one `AppState`: there is no longer a single
/// state to show, and the budget it changes is one process-wide setting that *every* window has to
/// adopt — a reader who raises it while two windows are open means both of them.
public struct SettingsView: View {
    @ObservedObject private var registry: ReaderWindowRegistry
    @AppStorage(AppState.cacheBudgetSettingKey) private var cacheBudgetMB = AppState.defaultTileCacheBudgetMB
    @AppStorage(ReadingLayoutPreferences.layoutKey) private var layoutRaw = ReaderLayoutMode.continuous.rawValue
    @AppStorage(ReadingLayoutPreferences.gapKey) private var pageGapPt = Double(ReadingLayoutPreferences.defaultGapPt)

    public init(registry: ReaderWindowRegistry) {
        self.registry = registry
    }

    public var body: some View {
        TabView {
            Form {
                Text("Engine: \(registry.settingsState.engine.version)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Stepper("Page cache budget: \(cacheBudgetMB) MB",
                        value: $cacheBudgetMB, in: 16...1024, step: 16)
                    .onChange(of: cacheBudgetMB) { _, _ in registry.applyCacheBudgetSetting() }
                Text("Keeps nearby pages ready for scrolling. A larger budget retains more clear pages. "
                     + "Content currently on screen is preserved even if it exceeds this budget.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .tabItem { Label("Performance", systemImage: "speedometer") }

            Form {
                Picker("Page layout", selection: layoutBinding) {
                    ForEach(ReaderLayoutMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Page gap")
                    Slider(value: $pageGapPt, in: pageGapRange, step: 1)
                        .onChange(of: pageGapPt) { _, _ in registry.applyReadingLayoutSetting() }
                    Text("\(Int(pageGapPt.rounded())) pt")
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }

                Text("Facing pages show page 1 alone, then pages 2–3 side by side. "
                     + "Both settings are remembered for the reader and apply to every window immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .tabItem { Label("Reading", systemImage: "book") }

            Form {
                Text("AI provider configuration, keys (Keychain), and privacy toggles arrive in M5 (T5.1 / T5.2).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 480, height: 300)
    }

    private var layoutBinding: Binding<ReaderLayoutMode> {
        Binding(
            get: { ReaderLayoutMode(rawValue: layoutRaw) ?? .continuous },
            set: { mode in
                layoutRaw = mode.rawValue
                registry.applyReadingLayoutSetting()
            }
        )
    }

    private var pageGapRange: ClosedRange<Double> {
        Double(ReadingLayoutPreferences.gapRange.lowerBound)...Double(ReadingLayoutPreferences.gapRange.upperBound)
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

/// Feedback for a file being dragged over the canvas (T2.12): a tinted border around the drop
/// area plus one line saying what letting go would do — including *not* opening the file, which
/// is why a refusal is drawn in the warning colour rather than simply swallowed.
///
/// Only plain shapes and colours: the overlay must stay inside SwiftUI's drawing layers, because
/// an AppKit view placed here would sit above the canvas and take the drop away from it.
/// `allowsHitTesting(false)` keeps the mouse paths (selection, scrolling) untouched as well.
struct FileDropOverlay: View {
    let hint: FileDropPreview

    private var tint: Color {
        hint.kind == .acceptable ? .accentColor : .orange
    }

    var body: some View {
        ZStack {
            tint.opacity(0.10)
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(tint, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                .padding(10)
            VStack(spacing: 8) {
                Image(systemName: hint.kind == .acceptable
                    ? "arrow.down.doc"
                    : "exclamationmark.triangle")
                    .font(.system(size: 34, weight: .light))
                Text(hint.message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.92),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.5))
            )
            .foregroundStyle(tint)
            .padding(40)
        }
        .allowsHitTesting(false)
    }
}
