import AppKit
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
    @State private var followsLatest = true

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
        .background(LyraReaderTheme.panelBg)
        .buttonStyle(ReaderPanelButtonStyle())
        .background(AIDocumentChatMarkerHost())
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
            Text(model.chatHistoryLimitDescription)
                .font(.caption2)
                .foregroundStyle(LyraReaderTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
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
                .background(ChatScrollPositionHost { followsLatest = $0 })
            }
            .onChange(of: model.chatTurns.count) { _, _ in
                followsLatest = true
                scrollToLatest(proxy)
            }
            .onChange(of: model.chatTurns.last?.answer) { _, _ in
                if followsLatest { scrollToLatest(proxy) }
            }
            .onChange(of: model.phase) { _, _ in
                if followsLatest { scrollToLatest(proxy) }
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
        proxy.scrollTo(id, anchor: .bottom)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "text.bubble").font(.system(size: 26, weight: .light))
                .foregroundStyle(LyraReaderTheme.accent).padding(.bottom, 8)
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
        .padding(14)
        .background(LyraReaderTheme.raisedBg, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Turns

    private func chatTurn(_ turn: AIChatTurn) -> some View {
        let backlinks = turn.backlinks(pageCount: turn.pageCount)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 18)
                Text(turn.question)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(10)
                    .foregroundStyle(LyraReaderTheme.selectedFg)
                    .background(LyraReaderTheme.selectedBg, in: RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label { Text("Lyra") } icon: {
                        LyraAIIcon(isActive: turn.isStreaming).frame(width: 16, height: 16)
                    }
                        .font(.caption.weight(.semibold)).foregroundStyle(LyraReaderTheme.accent)
                    Spacer()
                    if !turn.answer.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(turn.answer, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain).help("Copy Markdown source").accessibilityLabel("Copy answer as Markdown")
                    }
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
                DisclosureGroup(isExpanded: Binding(
                    get: { model.expandedChatSources.contains(turn.id) },
                    set: { expanded in
                        if expanded { model.expandedChatSources.insert(turn.id) }
                        else { model.expandedChatSources.remove(turn.id) }
                    }
                )) {
                    ForEach(backlinks.chips) { chip in sourceChip(chip) }
                } label: {
                    Text("Sources · " + backlinks.chips.map { "p.\($0.page)" }.joined(separator: ", "))
                        .font(.caption2).foregroundStyle(LyraReaderTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
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
            if turn.id == model.chatTurns.last?.id,
               model.phase == .failed,
               let hint = turn.failure.flatMap(AIOfflineHint.forFailure) {
                AIOfflineHintView(hint: hint)
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
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LyraReaderTheme.raisedBg, in: RoundedRectangle(cornerRadius: 10))
        }
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
                    // No line clamp: at the panel's narrow width the snippet wraps to as many
                    // lines as it needs instead of being clipped or forcing the row wider.
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(5)
            .background(LyraReaderTheme.fieldBg, in: RoundedRectangle(cornerRadius: 5))
            .background(AIDocumentChatChipMarkerHost(page: chip.page))
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
                    .buttonStyle(ReaderPanelButtonStyle(prominent: true))
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
                .textFieldStyle(ReaderPanelFieldStyle())
                .lineLimit(2...5)
                .onSubmit(ask)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Text("Review sources before sending.")
                        .font(.caption2)
                        .foregroundStyle(LyraReaderTheme.textTertiary)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 4)
                    askButton
                }
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    askButton
                }
            }
        }
        .padding(14)
        .background(LyraReaderTheme.panelBg)
        .background(AIDocumentChatComposerMarkerHost())
    }

    private var askButton: some View {
        Button { ask() } label: { Label("Review", systemImage: "arrow.up") }
            .buttonStyle(ReaderPanelButtonStyle(prominent: true))
            .background(AIDocumentChatAskMarkerHost())
            .disabled(!model.canAskDocument)
            .help("Find passages across the document and show the exact request before sending")
    }

    private func ask() {
        guard let context = state.aiReaderContext else { return }
        followsLatest = true
        Task { await model.prepareDocumentChat(context: context) }
    }

    private func sync() {
        model.attach(service: state.aiChatService, context: state.aiReaderContext)
    }
}


// MARK: - Check markers

/// Real AppKit views make the SwiftUI layout measurable from the native checks, exactly as the
/// right panel's assistant marker does. They are zero-content backgrounds, never visible.
public final class AIDocumentChatMarkerView: NSView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityLabel("Document chat content")
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityLabel("Document chat content")
    }
}

private struct AIDocumentChatMarkerHost: NSViewRepresentable {
    func makeNSView(context: Context) -> AIDocumentChatMarkerView {
        AIDocumentChatMarkerView(frame: .zero)
    }

    func updateNSView(_ nsView: AIDocumentChatMarkerView, context: Context) {}
}

public final class AIDocumentChatComposerMarkerView: NSView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityLabel("Document chat composer")
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityLabel("Document chat composer")
    }
}

private struct AIDocumentChatComposerMarkerHost: NSViewRepresentable {
    func makeNSView(context: Context) -> AIDocumentChatComposerMarkerView {
        AIDocumentChatComposerMarkerView(frame: .zero)
    }

    func updateNSView(_ nsView: AIDocumentChatComposerMarkerView, context: Context) {}
}

public final class AIDocumentChatAskMarkerView: NSView {}
private struct AIDocumentChatAskMarkerHost: NSViewRepresentable {
    func makeNSView(context: Context) -> AIDocumentChatAskMarkerView { AIDocumentChatAskMarkerView() }
    func updateNSView(_ nsView: AIDocumentChatAskMarkerView, context: Context) {}
}

/// One marker per citation chip, carrying the page number so a check can compare how that chip's
/// snippet wraps at the panel's minimum and maximum widths.
public final class AIDocumentChatChipMarkerView: NSView {
    public let page: Int

    public init(page: Int, frame frameRect: NSRect) {
        self.page = page
        super.init(frame: frameRect)
        setAccessibilityLabel("Citation chip page \(page)")
    }

    public required init?(coder: NSCoder) {
        fatalError("AIDocumentChatChipMarkerView is programmatic")
    }
}

private struct AIDocumentChatChipMarkerHost: NSViewRepresentable {
    let page: Int

    func makeNSView(context: Context) -> AIDocumentChatChipMarkerView {
        AIDocumentChatChipMarkerView(page: page, frame: .zero)
    }

    func updateNSView(_ nsView: AIDocumentChatChipMarkerView, context: Context) {}
}

/// Follow streaming output only while the reader stays near the end. Live-scroll events come
/// from user input; layout and programmatic scroll changes must not reset this preference.
private struct ChatScrollPositionHost: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> ChatScrollPositionView {
        let view = ChatScrollPositionView()
        view.changed = changed
        return view
    }
    func updateNSView(_ view: ChatScrollPositionView, context: Context) { view.changed = changed }
}

private final class ChatScrollPositionView: NSView {
    var changed: ((Bool) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll(_:)),
            name: NSScrollView.didLiveScrollNotification, object: nil)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("programmatic") }
    @objc private func didScroll(_ notification: Notification) {
        guard let scroll = enclosingScrollView,
              notification.object as? NSScrollView === scroll,
              let document = scroll.documentView else { return }
        let visible = scroll.contentView.bounds
        let distance = document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY
        changed?(distance <= 80)
    }
}
