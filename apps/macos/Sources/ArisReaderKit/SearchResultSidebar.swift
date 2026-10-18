import SwiftUI

package struct SearchResultSidebar: View {
    @ObservedObject var state: AppState
    private let reportRowFrames: (([String: CGRect]) -> Void)?

    package init(state: AppState, reportRowFrames: (([String: CGRect]) -> Void)? = nil) {
        self.state = state
        self.reportRowFrames = reportRowFrames
    }

    private enum Row: Identifiable {
        case page(Int, Int), hit(Int)
        var id: String {
            switch self {
            case .page(let page, _): "page-\(page)"
            case .hit(let index): "hit-\(index)"
            }
        }
    }

    private var rows: [Row] {
        let groups = Dictionary(grouping: Array(state.searchHits.indices), by: { state.searchHits[$0].page })
        return groups.keys.sorted().flatMap { page in
            let hits = groups[page]!
            return [Row.page(page, hits.count)] + hits.map(Row.hit)
        }
    }

    package var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { state.findPrevious() } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous search result").disabled(state.searchHits.isEmpty)
                Button { state.findNext() } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next search result").disabled(state.searchHits.isEmpty)
                Spacer(minLength: 4)
                if state.isSearching { ProgressView().controlSize(.small) }
                else { Text("Found: \(state.searchHits.count)").font(.system(size: 12, weight: .medium)) }
                Spacer(minLength: 4)
                Button { state.searchSidebarVisible = false } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close search results")
            }
            .buttonStyle(LyraToolStyle())
            .padding(8)
            Divider()
            if state.searchHits.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 25, weight: .light))
                    Text(state.isSearching ? "Searching…" : "No matches")
                    Text(state.searchQuery).font(.caption).lineLimit(3)
                }
                .foregroundStyle(LyraTheme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                        // Each identity owns exactly one row. Nested Sections with multiple
                        // children per result give the lazy stack unstable height estimates;
                        // page numbers and hit indices must also have distinct scroll IDs.
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { row in
                                VStack(spacing: 0) {
                                    switch row {
                                    case .page(let page, let count):
                                        HStack {
                                            Text("Page \(page + 1)")
                                            Spacer()
                                            Text("\(count) \(count == 1 ? "item" : "items")")
                                                .foregroundStyle(LyraTheme.textTertiary)
                                        }
                                        .font(.caption).padding(.horizontal, 12).padding(.vertical, 9)
                                        .background(LyraTheme.panelBg)
                                    case .hit(let index):
                                        let hit = state.searchHits[index]
                                        Button { state.showSearchHit(index) } label: {
                                            Text(highlighted(hit.snippet.split(whereSeparator: \.isWhitespace).joined(separator: " ")))
                                                .font(.system(size: 12)).lineSpacing(3).lineLimit(4)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .multilineTextAlignment(.leading)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(12)
                                                .background(index == state.currentHitIndex ? LyraTheme.selectedBg : .clear)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Page \(hit.page + 1): \(hit.snippet)")
                                    }
                                    LyraTheme.separator.frame(height: 1)
                                }
                                .id(row.id)
                                .background {
                                    if reportRowFrames != nil {
                                        GeometryReader { geometry in
                                            Color.clear.preference(key: SearchRowFrameKey.self,
                                                value: [row.id: geometry.frame(in: .named("search-results"))])
                                        }
                                    }
                                }
                            }
                        }
                        .onPreferenceChange(SearchRowFrameKey.self) { reportRowFrames?($0) }
                    }
                    .coordinateSpace(name: "search-results")
                    .onChange(of: state.currentHitIndex) { _, index in
                        if let index { scroll.scrollTo("hit-\(index)") }
                    }
                }
            }
        }
        .background(LyraTheme.sidebarBg)
        .foregroundStyle(LyraTheme.textPrimary)
        .background(SidebarScrollTheme().id(state.searchHits.count))
        .overlay(alignment: .leading) { LyraTheme.border.frame(width: 1).allowsHitTesting(false) }
        .accessibilityElement(children: .contain).accessibilityLabel("Search results")
    }

    private func highlighted(_ snippet: String) -> AttributedString {
        var text = AttributedString(snippet)
        let query = state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return text }
        var remaining = text.startIndex..<text.endIndex
        while let range = text[remaining].range(of: query, options: .caseInsensitive) {
            text[range].backgroundColor = LyraTheme.searchMatchBg
            text[range].foregroundColor = LyraTheme.searchMatchFg
            remaining = range.upperBound..<text.endIndex
        }
        return text
    }
}

private struct SearchRowFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
