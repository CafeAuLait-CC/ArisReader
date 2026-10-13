import SwiftUI

/// Sidebar: tab switching plus the content of each tab (`docs/04-ui-ux.md` §2.2).
///
/// The skeleton phase provides only the structure and empty states; real content is filled in
/// tab by tab starting in M2 (thumbnails T2.5, outline T2.4, annotations T3.6, search T2.6, AI T5.4).
public struct SidebarView: View {
    @ObservedObject private var state: AppState

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
            emptyState("Thumbnails", "square.grid.2x2", task: "T2.5")
        case .outline:
            emptyState("Document outline", "list.bullet.indent", task: "T2.4")
        case .bookmarks:
            emptyState("Bookmarks", "bookmark", task: "T2.4")
        case .annotations:
            emptyState("Annotations", "highlighter", task: "T3.6")
        case .search:
            emptyState("Search results", "magnifyingglass", task: "T2.6")
        case .ai:
            emptyState("AI assistant", "sparkles", task: "T5.4")
        }
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
