import AppKit
import LyraReaderBindings
import SwiftUI

/// The Summary tab's layered summary workspace.
///
/// The three levels are separate because they cost different things: the abstract is one
/// bounded request, a section is one request per section, a page is one request per page. A
/// layer's Generate press previews at most the batch bound, then Send runs that batch with the
/// concurrency bound. Completed rows are cached immediately, so Cancel never throws them away.
public struct AISummaryPanelView: View {
    @ObservedObject private var state: AppState
    @ObservedObject private var model: LayeredSummaryModel
    @ObservedObject private var settings: AISettingsStore
    @State private var languageDraft = ""
    @State private var showsPages = false
    @State private var expandedRequests: Set<String> = []

    public init(state: AppState, model: LayeredSummaryModel) {
        self.state = state
        self.model = model
        _settings = ObservedObject(wrappedValue: model.settings)
    }

    private var boundsText: String {
        "Each Generate sends at most \(model.bounds.maxRequestsPerBatch) requests, "
            + "\(model.bounds.maxConcurrentRequests) at a time. The abstract reads at most "
            + "\(model.bounds.abstractMaxPages) pages / "
            + "\(model.bounds.abstractMaxChars.formatted()) characters; a section at most "
            + "\(model.bounds.sectionMaxChars.formatted()) characters; a page at most "
            + "\(model.bounds.pageMaxChars.formatted()) characters."
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            layerSection(.abstract)
            layerSection(.sections)
            pagesSection
            languageSection
            previewSection
            if let note = model.statusNote, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(model.phase == .failed ? LyraReaderTheme.errorFg : LyraReaderTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.errorMessage, !error.isEmpty, model.statusNote != error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.errorFg)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Layered summaries are generated text, not annotations: they are saved in this document's cache, never written into the PDF.")
                .font(.system(size: 9))
                .foregroundStyle(LyraReaderTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text(boundsText)
                .font(.system(size: 9))
                .foregroundStyle(LyraReaderTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            AISummaryPanelMarkerHost()
                .frame(width: 0, height: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            languageDraft = model.language
            syncLanguage()
        }
        .onChange(of: model.language) { _, newValue in
            if languageDraft != newValue { languageDraft = newValue }
        }
        .onChange(of: settings.model) { _, _ in model.settingsDidChange() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Label("Layered summary", systemImage: "list.bullet.rectangle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LyraReaderTheme.textPrimary)
            Spacer(minLength: 4)
            if model.isRefreshing {
                ProgressView().controlSize(.mini)
            }
            Button("Refresh") { Task { await model.refresh() } }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(LyraReaderTheme.accent)
                .disabled(model.isBusy)
        }
    }

    private func layerSection(_ layer: AISummaryLayer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Label(layer.title, systemImage: layer.icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LyraReaderTheme.textSecondary)
                Spacer(minLength: 4)
                Text(model.coverageLabel(for: layer))
                    .font(.system(size: 9))
                    .foregroundStyle(LyraReaderTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if layer == .pages && !showsPages {
                HStack(spacing: 6) {
                    Text("Expand to see one line per page.")
                        .font(.system(size: 9))
                        .foregroundStyle(LyraReaderTheme.textTertiary)
                    Spacer(minLength: 2)
                    Button("Show") { showsPages = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LyraReaderTheme.accent)
                }
            } else {
                ForEach(model.entries(for: layer)) { entry in
                    AISummaryRowView(
                        state: state,
                        model: model,
                        entry: entry,
                        compact: layer == .pages
                    )
                }
            }
            HStack(spacing: 6) {
                Button(generateTitle(layer)) {
                    Task { await model.prepare(layer) }
                }
                .buttonStyle(ReaderPanelButtonStyle())
                .controlSize(.small)
                .disabled(model.isBusy || model.entries(for: layer).allSatisfy(\.state.isReady))
                if layer == .pages && showsPages {
                    Button("Hide") { showsPages = false }
                        .buttonStyle(.plain)
                        .font(.system(size: 9))
                        .foregroundStyle(LyraReaderTheme.textSecondary)
                }
            }
        }
        .padding(8)
        .background(LyraReaderTheme.panelBg, in: RoundedRectangle(cornerRadius: 6))
    }

    private func generateTitle(_ layer: AISummaryLayer) -> String {
        let rows = model.entries(for: layer)
        if rows.isEmpty { return "Generate" }
        if rows.allSatisfy(\.state.isReady) { return "Cached" }
        if rows.contains(where: { $0.state == .stale }) { return "Regenerate changed rows" }
        return layer == .abstract ? "Generate abstract" : "Generate next batch"
    }

    private var pagesSection: some View {
        layerSection(.pages)
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Summary language")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LyraReaderTheme.textSecondary)
            HStack(spacing: 6) {
                TextField(model.documentLanguageLabel, text: $languageDraft)
                    .textFieldStyle(ReaderPanelFieldStyle())
                    .font(.system(size: 11))
                Button("Apply") {
                    model.setLanguage(languageDraft)
                    syncLanguage()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LyraReaderTheme.accent)
                .disabled(model.isBusy)
            }
            Text("Blank means the document's own language. The cache is per language; switching language never reuses another language's rows.")
                .font(.system(size: 9))
                .foregroundStyle(LyraReaderTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        if let preview = model.preview, model.phase == .preview || model.phase == .generating {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(model.phase == .preview ? "Request preview" : "Sending the batch")
                        .font(.system(size: 10, weight: .semibold))
                    Spacer(minLength: 2)
                    Text("\(preview.units.filter { $0.plan != nil }.count) request\(preview.units.filter { $0.plan != nil }.count == 1 ? "" : "s")")
                        .font(.system(size: 9))
                        .foregroundStyle(LyraReaderTheme.textTertiary)
                }
                Text(preview.note)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if model.phase == .generating {
                    ProgressView(
                        value: Double(model.finishedRequests),
                        total: Double(max(1, model.batchRequests))
                    )
                    .controlSize(.small)
                    Text("\(model.finishedRequests) of \(model.batchRequests) finished · \(model.activeRequests) in flight")
                        .font(.system(size: 9))
                        .foregroundStyle(LyraReaderTheme.textSecondary)
                }
                ForEach(preview.units, id: \.index) { unit in
                    previewRow(unit)
                }
                HStack(spacing: 6) {
                    if model.phase == .preview {
                        Button("Send \(preview.units.filter { $0.plan != nil }.count) request\(preview.units.filter { $0.plan != nil }.count == 1 ? "" : "s")") {
                            model.send()
                        }
                        .buttonStyle(ReaderPanelButtonStyle(prominent: true))
                        .controlSize(.small)
                        Button("Discard") { model.discardPreview() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundStyle(LyraReaderTheme.textSecondary)
                    } else {
                        Button("Cancel") { model.cancel() }
                            .buttonStyle(ReaderPanelButtonStyle())
                            .controlSize(.small)
                    }
                }
            }
            .padding(8)
            .background(LyraReaderTheme.panelBg, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private func previewRow(_ unit: AiSummaryUnitRecord) -> some View {
        let expanded = expandedRequests.contains(requestKey(unit))
        VStack(alignment: .leading, spacing: 3) {
            Button {
                if expanded { expandedRequests.remove(requestKey(unit)) }
                else { expandedRequests.insert(requestKey(unit)) }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(unit.title)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text(unit.note ?? "\(unit.pages.count) page\(unit.pages.count == 1 ? "" : "s")")
                            .font(.system(size: 9))
                            .foregroundStyle(LyraReaderTheme.textTertiary)
                            .lineLimit(1)
                    }
                    if unit.plan == nil {
                        Text(unit.error ?? "No request can be sent for this entry.")
                            .font(.system(size: 9))
                            .foregroundStyle(LyraReaderTheme.errorFg)
                    } else {
                        Text("\(unit.characters.formatted()) chars · page span \(unit.pageStart)-\(unit.coveredPageEnd)")
                            .font(.system(size: 9))
                            .foregroundStyle(LyraReaderTheme.textTertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            if expanded, let plan = unit.plan, let part = plan.parts.first {
                Text(part.userPrompt)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(LyraReaderTheme.textSecondary)
                    .lineLimit(12)
                    .textSelection(.enabled)
                Text("Body: \(part.wireBody.utf8.count) bytes. The previewed body is sent byte for byte; the key is added only on Send.")
                    .font(.system(size: 8))
                    .foregroundStyle(LyraReaderTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Exact JSON body") {
                    ScrollView(.vertical) {
                        Text(part.wireBody)
                            .font(.system(size: 8, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 110)
                }
                .font(.system(size: 9))
            }
        }
    }

    private func requestKey(_ unit: AiSummaryUnitRecord) -> String {
        "\(unit.kind)-\(unit.index)-\(unit.title)"
    }

    private func syncLanguage() {
        if languageDraft != model.language {
            languageDraft = model.language
        }
    }
}

/// One row of a layer. The title and summary are the navigation target; Retry is its own
/// control so a failed row cannot be lost behind the link.
private struct AISummaryRowView: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: LayeredSummaryModel
    let entry: AISummaryEntry
    let compact: Bool

    private var tint: Color {
        switch entry.state {
        case .ready: return LyraReaderTheme.successFg
        case .generating: return LyraReaderTheme.accent
        case .stale: return LyraReaderTheme.warningFg
        case .failed: return LyraReaderTheme.errorFg
        case .cancelled: return LyraReaderTheme.warningFg
        case .notGenerated: return LyraReaderTheme.textTertiary
        }
    }

    private var stateText: String {
        if case .failed(let message) = entry.state {
            return message.isEmpty ? "Failed" : "Failed"
        }
        return entry.state.label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                guard entry.isLinkable else { return }
                state.gotoPage(entry.linkPage)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Circle()
                            .fill(tint)
                            .frame(width: 5, height: 5)
                        Text(entry.title)
                            .font(.system(size: compact ? 10 : 11, weight: .medium))
                            .foregroundStyle(entry.isLinkable ? LyraReaderTheme.textPrimary : LyraReaderTheme.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 2)
                        Text(stateText)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(entry.pageSpanLabel(pageCount: model.pageCount))
                            .font(.system(size: 9))
                            .foregroundStyle(LyraReaderTheme.textTertiary)
                        Spacer(minLength: 2)
                        Text(entry.pageCountLabel(documentPageCount: model.pageCount))
                            .font(.system(size: 8))
                            .foregroundStyle(LyraReaderTheme.textTertiary)
                            .lineLimit(1)
                    }
                    if !entry.summary.isEmpty {
                        Text(entry.summary)
                            .font(.system(size: compact ? 9 : 10))
                            .foregroundStyle(entry.state == .stale ? LyraReaderTheme.textTertiary : LyraReaderTheme.textSecondary)
                            .lineLimit(compact ? 2 : 5)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let note = entry.note, entry.state != .stale {
                        Text(note)
                            .font(.system(size: 8))
                            .foregroundStyle(entry.truncated ? .orange : LyraReaderTheme.textTertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(entry.isLinkable ? "Jump to page \(entry.linkPage + 1)" : "")
            if entry.state.needsRetry {
                HStack(spacing: 4) {
                    if case .failed(let message) = entry.state, !message.isEmpty {
                        Text(message)
                            .font(.system(size: 8))
                            .foregroundStyle(LyraReaderTheme.errorFg)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 2)
                    Button("Retry") { model.retry(entry.id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LyraReaderTheme.accent)
                        .disabled(model.isBusy)
                }
            }
        }
        .padding(.vertical, compact ? 2 : 3)
        .padding(.leading, CGFloat(min(entry.depth, 3)) * 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LyraReaderTheme.separator).frame(height: 0.5)
        }
    }
}

/// A zero-size AppKit marker so the hosted-window checks can find the layered summary content
/// without inspecting SwiftUI internals.
public final class AISummaryPanelMarkerView: NSView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("ai-summary-panel")
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct AISummaryPanelMarkerHost: NSViewRepresentable {
    func makeNSView(context: Context) -> AISummaryPanelMarkerView {
        AISummaryPanelMarkerView(frame: .zero)
    }

    func updateNSView(_ nsView: AISummaryPanelMarkerView, context: Context) {}
}
