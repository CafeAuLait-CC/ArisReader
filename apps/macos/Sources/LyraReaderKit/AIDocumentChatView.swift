import LyraReaderBindings
import SwiftUI

/// Document chat: a self-contained conversation surface for a narrow right-hand panel.
///
/// It owns its scroll view and its composer, so a host only has to give it a frame. History is
/// per document (see `AIAssistantModel`); each answer carries the pages that were actually sent,
/// their snippet chips and the transient source highlight. There is no background request: Ask
/// builds the local preview, and only Send starts the request that preview describes.
public struct AIDocumentChatView: View {
    @ObservedObject private var state: AppState
    @ObservedObject private var model: AIAssistantModel

    public init(state: AppState, model: AIAssistantModel) {
        self.state = state
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
            Divider()
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LyraReaderTheme.panelBg.opacity(0.35))
        .onAppear(perform: sync)
        .onChange(of: state.document?.id) { _, _ in sync() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Label("Document chat", systemImage: "text.bubble")
                    .font(.caption.weight(.semibold))
                Spacer()
                if model.hasChatConversation {
                    Button("Clear") { model.clearChat() }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(LyraReaderTheme.textSecondary)
                        .help("Clear this document's chat. Nothing is sent and no annotation is created.")
                }
            }
            Text(model.chatHistoryLimitDescription + " Switching documents keeps each document's own chat.")
                .font(.caption2)
                .foregroundStyle(LyraReaderTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.chatTurns.isEmpty {
                        emptyState
                    }
                    ForEach(model.chatTurns) { turn in
                        chatTurn(turn).id(turn.id)
                    }
                    if model.phase == .preparing, model.pendingChatQuestion != nil {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Finding relevant passages in the whole document…")
                                .font(.caption2)
                                .foregroundStyle(LyraReaderTheme.textSecondary)
                        }
                    } else if model.isDocumentChatPlan, let plan = model.plan,
                              model.phase == .preview {
                        requestPreview(plan)
                    }
                    if let note = model.statusNote, !note.isEmpty, showsChatStatus {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(
                                model.phase == .failed ? LyraReaderTheme.errorFg
                                    : (model.phase == .cancelled ? LyraReaderTheme.warningFg
                                        : LyraReaderTheme.textSecondary)
                            )
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .onChange(of: model.chatTurns.count) { _, _ in
                scrollToLatest(proxy)
            }
            .onChange(of: model.chatTurns.last?.answer) { _, _ in
                scrollToLatest(proxy)
            }
            .onChange(of: model.phase) { _, _ in
                scrollToLatest(proxy)
            }
        }
    }

    private var showsChatStatus: Bool {
        model.isDocumentChatPlan || model.isChatStreaming
            || model.pendingChatQuestion != nil
            || model.chatTurns.last?.state == .nothingRelevant
            || model.chatTurns.last?.state == .failed
            || model.chatTurns.last?.state == .cancelled
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard let id = model.chatTurns.last?.id else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask the whole document")
                .font(.callout.weight(.semibold))
            Text("Answers cite pages as [p.N]. Press Send on the preview to ask; nothing is sent while you type.")
                .font(.caption)
                .foregroundStyle(LyraReaderTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.settings.canUseAI {
                Text("Connect an AI provider in Settings > AI first. The key stays in the macOS Keychain.")
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.warningFg)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    // MARK: - Turns

    private func chatTurn(_ turn: AIChatTurn) -> some View {
        let backlinks = turn.backlinks(pageCount: turn.pageCount)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "person.crop.circle")
                    .font(.caption)
                    .foregroundStyle(LyraReaderTheme.textTertiary)
                Text(turn.question)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if turn.state == .nothingRelevant {
                Label("Nothing relevant was found. No request was sent.", systemImage: "exclamationmark.magnifyingglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LyraReaderTheme.warningFg)
                Text(turn.answer)
                    .font(.caption)
                    .foregroundStyle(LyraReaderTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !turn.answer.isEmpty {
                AIAnswerView(
                    text: turn.answer,
                    pageCount: turn.pageCount,
                    verifiedPages: turn.sentPages,
                    onJump: { page in state.gotoPage(page - 1) }
                )
            }

            if turn.isStreaming {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text(turn.answer.isEmpty ? "Waiting for the first token…" : "\(turn.answer.count) characters received")
                        .font(.caption2)
                        .foregroundStyle(LyraReaderTheme.textTertiary)
                }
            }

            if !backlinks.chips.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sources sent with this answer")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(LyraReaderTheme.textSecondary)
                    ForEach(backlinks.chips) { chip in
                        sourceChip(chip)
                    }
                }
            }
            ForEach(backlinks.unverified) { refusal in
                VStack(alignment: .leading, spacing: 1) {
                    Label("Could not verify [p.\(refusal.page)]", systemImage: "questionmark.circle")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(LyraReaderTheme.warningFg)
                    Text(refusal.reason)
                        .font(.caption2)
                        .foregroundStyle(LyraReaderTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let error = turn.error, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.errorFg)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if turn.state == .cancelled || turn.state == .failed {
                HStack(spacing: 6) {
                    Button("Retry") { model.retry() }
                        .controlSize(.small)
                        .disabled(!model.canRetry)
                    Text("Sends the same previewed question again.")
                        .font(.caption2)
                        .foregroundStyle(LyraReaderTheme.textTertiary)
                }
            }
            if !turn.reasoning.isEmpty {
                DisclosureGroup("Provider reasoning (not the answer)") {
                    Text(turn.reasoning)
                        .font(.caption2)
                        .foregroundStyle(LyraReaderTheme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption2)
            }
            if let usage = turn.usage, !usage.isEmpty {
                Text(usage.summary)
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.textTertiary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LyraReaderTheme.raisedBg, in: RoundedRectangle(cornerRadius: 6))
    }

    private func sourceChip(_ chip: AIChatChip) -> some View {
        Button {
            chip.follow(in: state)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Text("p.\(chip.page)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(LyraReaderTheme.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(LyraReaderTheme.accent.opacity(0.12), in: Capsule())
                Text(chip.snippet.isEmpty ? "Passage sent from page \(chip.page)" : chip.snippet)
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(5)
            .background(LyraReaderTheme.fieldBg, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help("Jump to page \(chip.page) and briefly highlight the passage that was sent")
        .accessibilityLabel("Source page \(chip.page)")
        .accessibilityHint("Jumps to the page and highlights the passage briefly. It is not saved as an annotation.")
    }

    // MARK: - Preview

    private func requestPreview(_ plan: AiPlanRecord) -> some View {
        let pageCharacters = plan.parts.reduce(UInt64(0)) { $0 + $1.pageCharacters }
        let requestCharacters = plan.parts.reduce(UInt64(0)) { $0 + $1.requestCharacters }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Request preview")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(plan.estimatedTokens) est. tokens")
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.textTertiary)
            }
            Text("Nothing has been sent yet. Send is the only action that starts a request.")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(LyraReaderTheme.warningFg)
                .fixedSize(horizontal: false, vertical: true)
            previewRow("Pages", plan.sourcePageLabel)
            previewRow("Document", "\(pageCharacters) characters from the retrieved passages")
            previewRow("History", "\(plan.historyTurns) earlier turn(s) · \(requestCharacters) request characters")
            if let note = plan.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.warningFg)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(plan.parts, id: \.index) { part in
                DisclosureGroup("Exact JSON body") {
                    ScrollView(.vertical) {
                        Text(part.wireBody)
                            .font(.system(size: 9, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .padding(4)
                    .background(LyraReaderTheme.fieldBg, in: RoundedRectangle(cornerRadius: 4))
                }
                .font(.caption2)
                DisclosureGroup("User prompt") {
                    ScrollView(.vertical) {
                        Text(part.userPrompt)
                            .font(.system(size: 9, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .padding(4)
                    .background(LyraReaderTheme.fieldBg, in: RoundedRectangle(cornerRadius: 4))
                }
                .font(.caption2)
            }
            HStack(spacing: 8) {
                Button("Send question") { model.send() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!model.canSendChatPreview)
                Button("Discard") { model.discard() }
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(LyraReaderTheme.panelBg, in: RoundedRectangle(cornerRadius: 6))
    }

    private func previewRow(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(name)
                .font(.caption2.weight(.medium))
                .foregroundStyle(LyraReaderTheme.textSecondary)
                .frame(width: 54, alignment: .leading)
            Text(value)
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField("Ask about this document…", text: $model.chatQuestion, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .lineLimit(1...4)
                .onSubmit(ask)
            HStack(spacing: 6) {
                Text("Ask builds the preview locally.")
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.textTertiary)
                Spacer()
                Button("Ask") { ask() }
                    .controlSize(.small)
                    .disabled(!model.canAskDocument)
                    .help("Find passages across the document and show the exact request before sending")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func ask() {
        guard let context = state.aiReaderContext else { return }
        Task { await model.prepareDocumentChat(context: context) }
    }

    private func sync() {
        model.attach(service: state.aiChatService, context: state.aiReaderContext)
    }
}
