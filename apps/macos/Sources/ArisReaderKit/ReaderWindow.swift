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
    @State private var sidebarVisible = true

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarView(state: state)
                    .frame(width: 240)
                    .background(Color(nsColor: .windowBackgroundColor))
                Divider()
            }
            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 600)
        .toolbar { toolbarContent }
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
                onCopy: { state.copySelection() }
            )
            secondSurface

            if state.document == nil {
                emptyState
            }

            VStack {
                Spacer()
                pageHUD
                    .padding(.bottom, 16)
            }
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

    /// A second, independent render surface in the same window.
    ///
    /// This is the T0.5 multi-surface proof: two `CAMetalLayer`s attached to one wgpu
    /// device, each with its own frame loop and surface id. The same shape will host
    /// the citation/figure floating preview in M4.
    @ViewBuilder
    private var secondSurface: some View {
        if state.showSecondSurface {
            VStack {
                HStack {
                    Spacer()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Second surface (T0.5)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        PDFCanvasView(
                            onFrame: { stats in state.updateGpuStatus(stats, label: "surface 2") },
                            onFailure: { message in state.reportGpuFailure(message) }
                        )
                        .frame(width: 220, height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                Spacer()
            }
            .padding(16)
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
                state.showSecondSurface.toggle()
            } label: {
                Image(systemName: "rectangle.on.rectangle")
            }
            .help("Show/hide the second render surface (multi-surface check)")

            Button {
                sidebarVisible.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Show/hide sidebar (⌘⌥S)")
        }
    }
}

/// Settings window (`⌘,`). During the skeleton phase it exposes only two performance toggles;
/// the real configuration is held by the Rust side (`docs/02-architecture.md` §9).
public struct SettingsView: View {
    @ObservedObject private var state: AppState
    @AppStorage("cacheBudgetMB") private var cacheBudgetMB = 512
    @AppStorage("tileSize") private var tileSize = 512

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        TabView {
            Form {
                Text("Engine: \(state.engine.version)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Stepper("Texture cache budget: \(cacheBudgetMB) MB",
                        value: $cacheBudgetMB, in: 128...4096, step: 128)
                Stepper("Tile size: \(tileSize) px",
                        value: $tileSize, in: 256...1024, step: 256)
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
