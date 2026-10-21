import AppKit
import LyraReaderBindings
import SwiftUI

/// The AI assistant, hosted in the reader window's right-hand panel. Everything visible here is
/// local state until the reader presses Send: the action buttons only build a preview, and the
/// preview is the exact plan Rust will execute. The view's public surface is the panel's:
/// `state` and `model` are supplied by the host, which owns the model for the window's lifetime.
public struct AIAssistantPanel: View {
    @ObservedObject private var state: AppState
    @ObservedObject private var model: AIAssistantModel
    @ObservedObject private var settings: AISettingsStore
    @ObservedObject private var chatGPT: ChatGPTAccountStore

    public init(state: AppState, model: AIAssistantModel) {
        self.state = state
        self.model = model
        _settings = ObservedObject(wrappedValue: model.settings)
        _chatGPT = ObservedObject(wrappedValue: model.settings.chatGPT)
    }

    public var body: some View {
        Group {
            if state.document == nil {
                noDocument
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        providerHeader
                        if !settings.canUseAI {
                            keyMissing
                        }
                        actions
                        if let note = model.statusNote, !note.isEmpty {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(
                                    model.phase == .failed
                                        ? LyraReaderTheme.errorFg
                                        : (model.phase == .finished && model.answer.isEmpty
                                            ? LyraReaderTheme.warningFg : Color.secondary)
                                )
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if model.isPreparing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Reading text and building the preview…")
                                    .font(.caption)
                                    .foregroundStyle(LyraReaderTheme.textSecondary)
                            }
                        }
                        if let plan = model.plan, model.phase != .preparing {
                            requestPreview(plan)
                        }
                        if let mergePlan = model.mergePlan {
                            requestPreview(mergePlan, isMerge: true)
                        } else if model.phase == .mergePreview {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Building the consolidation preview…")
                                    .font(.caption)
                                    .foregroundStyle(LyraReaderTheme.textSecondary)
                            }
                        }
                        if model.phase == .streaming || model.phase.isTerminal || model.phase == .mergePreview {
                            answerSection
                        }
                        controls
                    }
                    .padding(10)
                }
            }
        }
        // A zero-size AppKit marker is the stable way for the hosted-window checks to prove that
        // the right panel's content really is this view. SwiftUI's accessibility tree is lazy
        // and empty for a window no assistive client has queried, so asking it would be a check
        // that depends on the machine, not on the layout.
        .background(AIAssistantPanelMarkerHost())
        .onAppear(perform: sync)
        .onChange(of: state.document?.id) { _, _ in sync() }
    }

    private var noDocument: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(LyraReaderTheme.textTertiary)
            Text("No document")
                .font(.callout)
                .foregroundStyle(LyraReaderTheme.textSecondary)
            Text("Open a PDF to summarise a page, ask about a selection, or translate one.")
                .font(.caption)
                .foregroundStyle(LyraReaderTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var providerHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            if settings.connectionMode == .chatGPT {
                Label("ChatGPT plan", systemImage: "person.crop.circle")
                    .font(.caption.weight(.semibold)).foregroundStyle(LyraReaderTheme.accent)
                Text(chatGPT.selected.map { "\($0.label) · \($0.email)" } ?? "Not connected")
                    .font(.caption2).foregroundStyle(LyraReaderTheme.textSecondary)
                Text(chatGPT.selected?.model ?? "Choose a model in Settings > AI")
                    .font(.caption2).foregroundStyle(LyraReaderTheme.textTertiary)
                Link("Manage usage", destination: ChatGPTAccountStore.usageURL).font(.caption2)
                SettingsLink { Text("Connection settings…").font(.caption2) }
            } else {
            HStack(spacing: 6) {
                Image(systemName: settings.isLocalEndpoint ? "desktopcomputer" : "network")
                    .foregroundStyle(settings.isLocalEndpoint ? LyraReaderTheme.successFg : LyraReaderTheme.warningFg)
                Text(settings.isLocalEndpoint ? "Local endpoint" : "Remote endpoint")
                    .font(.caption.weight(.semibold))
                Spacer()
                if settings.hasKey {
                    Label("Key configured", systemImage: "key.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .foregroundStyle(LyraReaderTheme.textSecondary)
                }
            }
            Text(settings.endpointInfo?.host ?? settings.baseURL)
                .font(.caption2)
                .foregroundStyle(LyraReaderTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(settings.model)
                .font(.caption2)
                .foregroundStyle(LyraReaderTheme.textTertiary)
                .lineLimit(1)
            }
        }
    }

    private var keyMissing: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(settings.connectionMode == .chatGPT ? "Connect ChatGPT" : "Connect an AI provider", systemImage: "person.crop.circle")
                .font(.caption.weight(.semibold))
            Text("Continue with ChatGPT or add an API key in Settings > AI. Credentials are stored in the macOS Keychain; nothing is sent until you press Send.")
                .font(.caption2)
                .foregroundStyle(LyraReaderTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsLink {
                Text("Open Settings…")
                    .font(.caption)
            }
        }
        .padding(8)
        .background(LyraReaderTheme.panelBg, in: RoundedRectangle(cornerRadius: 6))
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Actions")
                .font(.caption.weight(.semibold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(AIAssistantAction.allCases) { action in
                    Button {
                        prepare(action)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                            .font(.caption2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .disabled(disabled(action))
                }
            }

            if let selection = state.selection {
                Text("Selection: \(selection.range.count) characters on page \(selection.page + 1)")
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.textSecondary)
            } else {
                Text("Select text in the page to ask about it or translate it.")
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.textTertiary)
            }

            TextField("Question about the selection", text: $model.question)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            TextField("Translate to", text: $model.targetLanguage)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
        }
    }

    private func disabled(_ action: AIAssistantAction) -> Bool {
        if model.isPreparing || model.isSending { return true }
        if action.requiresSelection, state.selection == nil { return true }
        if action == .askSelection,
           model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if action == .translateSelection,
           model.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return false
    }

    private func prepare(_ action: AIAssistantAction) {
        guard let context = state.aiReaderContext else { return }
        Task { await model.prepare(action: action, context: context) }
    }

    private func requestPreview(_ plan: AiPlanRecord, isMerge: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(isMerge ? "Consolidation request preview" : "Request preview")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(plan.estimatedTokens) est. tokens")
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.textTertiary)
            }
            Text(plan.isLocal
                 ? "This endpoint runs on this Mac; the page text does not leave it."
                 : "This is a remote endpoint: the page text below leaves this Mac when you press Send.")
                .font(.caption2)
                .foregroundStyle(plan.isLocal ? Color.secondary : LyraReaderTheme.warningFg)
                .fixedSize(horizontal: false, vertical: true)
            if isMerge {
                Text("This consolidation is a separate request and has its own cost. The part summaries are not re-sent as page text.")
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.phase == .preview {
                Text("Nothing has been sent yet.")
                    .font(.caption2.weight(.semibold))
            } else if model.phase == .mergePreview {
                Text("The part requests are complete. This consolidation has not been sent.")
                    .font(.caption2.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 3) {
                previewRow("Endpoint", plan.endpoint)
                previewRow("Model", plan.model)
                previewRow("Pages", plan.sourcePageLabel)
                previewRow("Prompt", "\(plan.estimatedTokens) estimated tokens")
                previewRow("Completion budget", plan.maxTokens.map { String($0) } ?? "provider default")
                previewRow("Connection", settings.connectionMode == .chatGPT ? "ChatGPT plan usage" : "API key")
                previewRow("Reasoning", settings.connectionMode == .chatGPT ? "Model default" : settings.reasoningSummary)
                Text(settings.connectionMode == .chatGPT ? "This request uses your shared ChatGPT plan allowance." : settings.reasoningFieldDescription)
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.textTertiary)
            }
            if let note = plan.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup("Request headers") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(plan.previewHeaders, id: \.name) { header in
                        Text("\(header.name): \(header.value)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(LyraReaderTheme.textSecondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("The transport also sends Content-Length and connection headers. The body below is sent byte for byte.")
                    .font(.system(size: 9))
                    .foregroundStyle(LyraReaderTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption2)

            ForEach(plan.parts, id: \.index) { part in
                partPreview(part)
            }
        }
        .padding(8)
        .background(LyraReaderTheme.panelBg, in: RoundedRectangle(cornerRadius: 6))
    }

    private func previewRow(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(name)
                .font(.caption2.weight(.medium))
                .foregroundStyle(LyraReaderTheme.textSecondary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.caption2)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func partPreview(_ part: AiPlanPartRecord) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let note = part.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text("System prompt")
                    .font(.caption2.weight(.semibold))
                promptBox(part.systemPrompt)
                Text("User prompt")
                    .font(.caption2.weight(.semibold))
                promptBox(part.userPrompt)
                DisclosureGroup("Exact JSON body") {
                    promptBox(part.wireBody)
                }
                .font(.caption2)
            }
            .padding(.top, 4)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(part.total > 1
                     ? "Part \(part.index + 1) of \(part.total) · \(part.label)"
                     : part.label)
                    .font(.caption2.weight(.medium))
                Text(part.characterLabel + " \u{00B7} \(part.wireBody.utf8.count) body bytes")
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.textTertiary)
            }
        }
        .font(.caption2)
    }

    private func promptBox(_ text: String) -> some View {
        ScrollView(.vertical) {
            Text(text)
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 140)
        .padding(4)
        .background(LyraReaderTheme.fieldBg, in: RoundedRectangle(cornerRadius: 4))
    }

    private var answerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(answerHeader)
                    .font(.caption.weight(.semibold))
                Spacer()
                if model.phase == .streaming {
                    ProgressView().controlSize(.small)
                }
            }

            if model.answer.isEmpty {
                if !model.reasoning.isEmpty {
                    reasoningBox(
                        title: model.phase == .finished
                            ? "The provider sent reasoning but no answer"
                            : "Provider reasoning (not the answer)",
                        prominent: true
                    )
                } else if model.phase == .streaming {
                    Text("Waiting for the first token…")
                        .font(.caption)
                        .foregroundStyle(LyraReaderTheme.textSecondary)
                } else if model.phase == .finished {
                    Label("The provider returned no answer text", systemImage: "exclamationmark.triangle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LyraReaderTheme.warningFg)
                }
            } else {
                // Page links are offered only for actions whose prompt asked for [p.N].
                // A translation was told not to cite, so its numbers stay plain text.
                AIAnswerView(
                    text: model.answer,
                    pageCount: model.plan?.action == .translateSelection
                        ? 0 : Int(model.plan?.pageCount ?? 0),
                    onJump: { page in state.gotoPage(page - 1) }
                )
                Text(model.plan?.action == .translateSelection
                     ? "Rendered as paragraphs, headings, bullet and numbered lists. This action did not ask for page citations, so no numbers are linkified; other Markdown is shown literally."
                     : "Rendered as paragraphs, headings, bullet and numbered lists. Only [p.N] citations are clickable; other Markdown is shown literally.")
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.reasoning.isEmpty {
                    DisclosureGroup("Provider reasoning (not the answer)") {
                        reasoningText
                    }
                    .font(.caption2)
                }
            }

            if (model.plan?.parts.count ?? 0) > 1 && !model.partAnswers.isEmpty {
                DisclosureGroup("Part summaries (\(model.partAnswers.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.partAnswers.keys.sorted(), id: \.self) { index in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Part \(index + 1) · \(model.partLabels[index] ?? "")")
                                    .font(.caption2.weight(.semibold))
                                Text(model.partAnswers[index] ?? "")
                                    .font(.caption)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .font(.caption2)
            }

            // The usage line follows the answer/diagnostic and is deliberately small and muted.
            // Under an empty answer it must never be the most prominent thing in the box.
            if let usage = model.usage {
                Text(usage.summary)
                    .font(.caption2)
                    .foregroundStyle(model.answer.isEmpty ? Color.secondary.opacity(0.7) : Color.secondary)
            } else if model.phase == .finished && !model.answer.isEmpty {
                Text("No token usage was reported by the provider.")
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.textTertiary)
            }
            if !model.answer.isEmpty && model.finishReason == "length" {
                Label("The provider stopped at its token limit; this answer may be truncated.", systemImage: "exclamationmark.triangle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LyraReaderTheme.warningFg)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.reasoningTokensIgnored {
                Label(
                    "The provider reported reasoning tokens even though thinking is off. It may have ignored the toggle.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(LyraReaderTheme.warningFg)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(LyraReaderTheme.raisedBg, in: RoundedRectangle(cornerRadius: 6))
    }

    private var answerHeader: String {
        if model.answer.isEmpty {
            return model.phase == .streaming ? "No answer text yet" : "No answer text"
        }
        return model.phase == .streaming ? "Answer (streaming)" : "Answer"
    }

    private func reasoningBox(title: String, prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "lightbulb")
                .font(.caption.weight(.semibold))
                .foregroundStyle(prominent ? LyraReaderTheme.warningFg : Color.secondary)
            reasoningText
            Text("This is the model's reasoning, not the answer. It was not concatenated into the answer.")
                .font(.caption2)
                .foregroundStyle(LyraReaderTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .background(
            (prominent ? LyraReaderTheme.warningFg : Color.secondary).opacity(prominent ? 0.08 : 0.05),
            in: RoundedRectangle(cornerRadius: 5)
        )
    }

    private var reasoningText: some View {
        Text(model.reasoning)
            .font(.callout)
            .foregroundStyle(LyraReaderTheme.textSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var controls: some View {
        switch model.phase {
        case .preview:
            HStack(spacing: 8) {
                Button(model.requestCount > 1 ? "Send \(model.requestCount) requests" : "Send") {
                    model.send()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Discard") { model.discard() }
                    .controlSize(.small)
            }
        case .mergePreview:
            HStack(spacing: 8) {
                if model.canSendMerge {
                    Button("Send consolidation") { model.sendMerge() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Button("Keep part summaries") { model.keepPartSummaries() }
                    .controlSize(.small)
            }
        case .streaming:
            HStack(spacing: 8) {
                Button("Cancel") { model.cancel() }
                    .controlSize(.small)
                Text(model.answer.isEmpty && !model.reasoning.isEmpty
                     ? "Reasoning received; no answer text yet"
                     : "\(model.answer.count) characters received")
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.textTertiary)
            }
        case .finished, .cancelled, .failed:
            HStack(spacing: 8) {
                if model.canRetry {
                    Button("Retry") { model.retry() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Button("New request") { model.discard() }
                    .controlSize(.small)
            }
        case .idle, .preparing:
            EmptyView()
        }
    }

    private func sync() {
        model.attach(service: state.aiChatService, context: state.aiReaderContext)
    }
}

/// Renders the streamed answer. Paragraphs, headings and lists are interpreted; citations are
/// clickable only when they are the exact `[p.N]` form and name a page in this document.
struct AIAnswerView: View {
    let text: String
    let pageCount: Int
    let onJump: (Int) -> Void

    var body: some View {
        let document = AIAnswerMarkdown.parse(text, pageCount: pageCount)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "lyra-reader-page",
                  let host = url.host,
                  let page = Int(host),
                  page >= 1, page <= pageCount else {
                return .systemAction
            }
            onJump(page)
            return .handled
        })
    }

    @ViewBuilder
    private func blockView(_ block: AIAnswerBlock) -> some View {
        switch block {
        case .paragraph(let runs):
            Text(attributed(runs))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .heading(let level, let runs):
            Text(attributed(runs))
                .font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, 2)
        case .bullet(let runs):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("•")
                Text(attributed(runs))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .font(.callout)
        case .numbered(let number, let runs):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(number).")
                    .monospacedDigit()
                Text(attributed(runs))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .font(.callout)
        }
    }

    private func attributed(_ runs: [AIInlineRun]) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            switch run {
            case .text(let text):
                result.append(AttributedString(text))
            case .citation(let page, let raw):
                var piece = AttributedString(raw)
                piece.link = URL(string: "lyra-reader-page://\(page)")
                piece.foregroundColor = .accentColor
                piece.underlineStyle = .single
                result.append(piece)
            }
        }
        return result
    }
}

/// A zero-size marker view for the hosted-window checks.
///
/// `NSHostingView` does not expose the SwiftUI view tree, and its accessibility children are not
/// built until an assistive client asks for them. A real, empty `NSView` in the hierarchy is the
/// same seam the canvas already provides: the checks can find the assistant content by type
/// without inspecting SwiftUI internals.
public final class AIAssistantPanelMarkerView: NSView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityLabel("AI assistant panel content")
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityLabel("AI assistant panel content")
    }
}

private struct AIAssistantPanelMarkerHost: NSViewRepresentable {
    func makeNSView(context: Context) -> AIAssistantPanelMarkerView {
        AIAssistantPanelMarkerView(frame: .zero)
    }

    func updateNSView(_ nsView: AIAssistantPanelMarkerView, context: Context) {}
}
