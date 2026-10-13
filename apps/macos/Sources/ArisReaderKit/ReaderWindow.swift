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
                    state.open(url: url)
                }
            case .failure(let error):
                state.lastError = String(describing: error)
            }
        }
    }

    // MARK: - Canvas

    private var canvas: some View {
        ZStack {
            PDFCanvasView()

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
                Text(state.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
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
