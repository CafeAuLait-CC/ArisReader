import SwiftUI

struct SearchResultSidebar: View {
    @ObservedObject var state: AppState
    private var groups: [(page: Int, results: [Int])] {
        Dictionary(grouping: Array(state.searchHits.indices), by: { state.searchHits[$0].page })
            .map { (page: $0.key, results: $0.value) }.sorted { $0.page < $1.page }
    }

    var body: some View {
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
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                            ForEach(groups, id: \.page) { group in
                                let page = group.page
                                let results = group.results
                                Section {
                                    ForEach(results, id: \.self) { index in
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
                                        .buttonStyle(.plain).id(index)
                                        .accessibilityLabel("Page \(page + 1): \(hit.snippet)")
                                        Divider()
                                    }
                                } header: {
                                    HStack {
                                        Text("Page \(page + 1)")
                                        Spacer()
                                        Text("\(results.count) \(results.count == 1 ? "item" : "items")")
                                            .foregroundStyle(LyraTheme.textTertiary)
                                    }
                                    .font(.caption).padding(.horizontal, 12).padding(.vertical, 9)
                                    .background(LyraTheme.panelBg)
                                }
                            }
                        }
                    }
                    .onChange(of: state.currentHitIndex) { _, index in
                        if let index { scroll.scrollTo(index, anchor: .center) }
                    }
                }
            }
        }
        .background(LyraTheme.sidebarBg)
        .foregroundStyle(LyraTheme.textPrimary)
        .overlay(alignment: .leading) { LyraTheme.separator.frame(width: 1) }
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
