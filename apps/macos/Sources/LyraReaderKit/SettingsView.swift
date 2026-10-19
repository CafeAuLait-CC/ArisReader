import SwiftUI

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
                Section("Rendering engine") {
                    Text(registry.settingsState.engine.version)
                        .font(.callout)
                        .foregroundStyle(LyraReaderTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                Section("Page cache") {
                    Stepper(value: $cacheBudgetMB, in: 16...1024, step: 16) {
                        HStack {
                            Text("Cache budget")
                            Spacer()
                            Text("\(cacheBudgetMB) MB").monospacedDigit()
                                .foregroundStyle(LyraReaderTheme.textSecondary)
                        }
                    }
                    .onChange(of: cacheBudgetMB) { _, _ in registry.applyCacheBudgetSetting() }
                    Text("Keeps nearby pages ready for scrolling. A larger budget retains more clear pages. "
                         + "Content currently on screen is preserved even if it exceeds this budget.")
                        .font(.caption)
                        .foregroundStyle(LyraReaderTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
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
            .formStyle(.grouped)
            .tabItem { Label("Reading", systemImage: "book") }

            AISettingsView(store: AISettingsStore.shared)
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 580, height: 520)
        .tint(LyraReaderTheme.accent)
        .foregroundStyle(LyraReaderTheme.textPrimary)
        .background(LyraReaderTheme.panelBg)
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
