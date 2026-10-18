import SwiftUI

/// Commands in an app-owned popover. Native menu-bar and document context menus remain AppKit
/// surfaces; toolbar menus use the same semantic colors, spacing, and states as the reader.
struct LyraMenuItem: Identifiable {
    let id: String
    let title: String
    let icon: String
    var shortcut: String? = nil
    var enabled = true
    var selected = false
    var color: Color? = nil
    var action: () -> Void = {}
    var isSeparator = false

    init(_ title: String, icon: String, shortcut: String? = nil, enabled: Bool = true,
         selected: Bool = false, color: Color? = nil, action: @escaping () -> Void) {
        id = title; self.title = title; self.icon = icon; self.shortcut = shortcut
        self.enabled = enabled; self.selected = selected; self.color = color; self.action = action
    }

    static func separator(_ id: String) -> Self {
        var item = Self(id, icon: "", enabled: false, action: {})
        item.isSeparator = true
        return item
    }
}

struct LyraMenu<Label: View>: View {
    let title: String
    let items: [LyraMenuItem]
    @ViewBuilder let label: () -> Label
    @State private var presented = false

    var body: some View {
        Button { presented.toggle() } label: { label() }
            .buttonStyle(LyraToolStyle(selected: presented))
            .help(title).accessibilityLabel(title)
            .accessibilityValue(presented ? "Expanded" : "Collapsed")
            .popover(isPresented: $presented, arrowEdge: .top) {
                LyraMenuContent(items: items, dismiss: { presented = false })
                    .presentationBackground(LyraTheme.menuBg)
            }
    }
}

private struct LyraMenuContent: View {
    let items: [LyraMenuItem]
    let dismiss: () -> Void
    @State private var activeID: String?
    @FocusState private var keyboardFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(items) { item in
                if item.isSeparator {
                    LyraTheme.separator.frame(height: 1).padding(.horizontal, 6).padding(.vertical, 4)
                } else {
                    Button { perform(item) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon)
                                .font(.system(size: 14))
                                .foregroundStyle(item.enabled ? (item.color ?? LyraTheme.iconPrimary) : LyraTheme.textDisabled)
                                .frame(width: 20)
                            Text(item.title).font(.system(size: 12))
                            Spacer(minLength: 18)
                            if let shortcut = item.shortcut {
                                Text(shortcut).font(.system(size: 11)).foregroundStyle(LyraTheme.textTertiary)
                            }
                            Image(systemName: "checkmark")
                                .opacity(item.selected ? 1 : 0).accessibilityHidden(true)
                                .font(.system(size: 10, weight: .semibold)).frame(width: 12)
                        }
                        .foregroundStyle(!item.enabled ? LyraTheme.textDisabled :
                            (activeID == item.id ? LyraTheme.menuSelectedFg : LyraTheme.textPrimary))
                        .padding(.horizontal, 10).frame(height: 33)
                        .background(activeID == item.id && item.enabled ? LyraTheme.menuSelectedBg : .clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain).disabled(!item.enabled).focusable(false)
                    .onHover { hovered in if hovered && item.enabled { activeID = item.id } }
                    .accessibilityValue(item.selected ? "Selected" : "")
                }
            }
        }
        .padding(7).frame(minWidth: 238)
        .background(LyraTheme.menuBg)
        .focusable().focused($keyboardFocused).focusEffectDisabled()
        .onAppear { activeID = items.first(where: { $0.enabled && !$0.isSeparator })?.id; keyboardFocused = true }
        .onMoveCommand { direction in
            if direction == .down { move(1) }
            if direction == .up { move(-1) }
        }
        .onKeyPress(.return) { activate(); return .handled }
        .onKeyPress(.space) { activate(); return .handled }
        .onExitCommand(perform: dismiss)
    }

    private func move(_ direction: Int) {
        let enabled = items.filter { $0.enabled && !$0.isSeparator }
        guard !enabled.isEmpty else { return }
        let current = enabled.firstIndex { $0.id == activeID } ?? 0
        activeID = enabled[(current + direction + enabled.count) % enabled.count].id
    }
    private func activate() {
        if let item = items.first(where: { $0.id == activeID }) { perform(item) }
    }
    private func perform(_ item: LyraMenuItem) {
        guard item.enabled else { return }
        dismiss()
        // Close the transient panel before presenting a save sheet, note prompt, or Settings.
        DispatchQueue.main.async { item.action() }
    }
}
