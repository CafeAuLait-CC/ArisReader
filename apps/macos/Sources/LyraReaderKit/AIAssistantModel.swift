import LyraReaderBindings
import Combine
import Foundation

/// The AI panel's state machine.
///
/// The important privacy property lives here: pressing an action only *prepares* a plan locally.
/// Nothing reaches a provider until the reader presses Send, and the key is read from the
/// Keychain inside `send()` only. There are no background requests and no automatic retries.
@MainActor
public final class AIAssistantModel: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case preparing
        case preview
        case mergePreview
        case streaming
        case finished
        case cancelled
        case failed

        public var isTerminal: Bool {
            self == .finished || self == .cancelled || self == .failed
        }
    }

    public static let noKeyMessage =
        "No API key is configured. Open Settings > AI and add one. Nothing was sent."
    public static let noEngineMessage =
        "The Rust engine is not available, so the AI request cannot run. Nothing was sent."

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var plan: AiPlanRecord?
    /// The second, explicit request that consolidates part summaries. It is previewed on its own.
    @Published public private(set) var mergePlan: AiPlanRecord?
    @Published public private(set) var partAnswers: [Int: String] = [:]
    @Published public private(set) var partLabels: [Int: String] = [:]
    @Published public private(set) var answer = ""
    /// The provider's reasoning/thinking channel, shown separately and never appended to
    /// `answer`. DeepSeek's reasoner streams this as `delta.reasoning_content`.
    @Published public private(set) var reasoning = ""
    @Published public private(set) var usage: AIUsage?
    @Published public private(set) var diagnostics: [AIStreamDiagnostics] = []
    @Published public private(set) var contentDeltaCount = 0
    @Published public private(set) var reasoningDeltaCount = 0
    @Published public private(set) var usageUpdateCount = 0
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var statusNote: String?
    /// The fixed transport category of the current failure. `.other` unless the last request
    /// failed with a recognized offline or local-server transport error.
    @Published public private(set) var requestFailure: AIRequestFailure = .other
    @Published public private(set) var documentKey: String?
    @Published public var selectedTab: AIAssistantTab = .summary
    @Published public var summaryUsesSelection = false
    @Published public var expandedChatSources: Set<UUID> = []
    /// The question for "Ask selection"; the view binds it.
    @Published public var question = ""
    /// The composer for document chat; the view binds it.
    @Published public var chatQuestion = ""
    /// The target language for "Translate selection"; the view binds it.
    @Published public var targetLanguage = "English"

    /// The conversation for the document currently attached. Turns are kept newest-last and
    /// the list is bounded by `chatTurnLimit`.
    @Published public private(set) var chatTurns: [AIChatTurn] = []
    /// The exact question the current chat preview/send belongs to. Captured when Ask is
    /// pressed, so editing the composer afterwards cannot change what Send will do.
    @Published public private(set) var pendingChatQuestion: String?
    /// The question the current region preview/send belongs to. The card keeps its editable
    /// field; this snapshot is what history and the panel import record.
    @Published public private(set) var regionAskedQuestion: String?

    /// Most recent exchanges kept per document, in the panel and in the request. The Rust
    /// builder applies the same bound again.
    public static let chatTurnLimit = 6
    public static let chatLimitDescription =
        "Keeps the most recent \(chatTurnLimit) questions and answers per document; older turns are dropped."

    public let settings: AISettingsStore
    /// The Summary tab's three-layer summary. It shares the window and settings with the panel
    /// but owns its own request state, so a failed page one-liner never disturbs a chat answer.
    public let layeredSummary: LayeredSummaryModel
    /// The local audit trail every request attempt is recorded in. The panel observes it too,
    /// so a new record or a clear is visible without a refresh.
    public let audit: AIAuditTrail
    private var service: (any AIChatServicing)?
    private var handle: (any AIChatHandle)?
    private var pollTask: Task<Void, Never>?
    private var currentPartIndex: Int?
    private var merging = false
    private var preparedConnection: AIConnectionMode = .apiKey
    private var preparedAccountID: UUID?
    /// Per-document conversations. The model is per window (the side panel owns it), so a
    /// document keeps its chat while it is open in this window and loses it when the window closes.
    private var conversations: [String: [AIChatTurn]] = [:]
    private var streamingChatTurnID: UUID?
    private var retryingChatTurnID: UUID?

    public init(settings: AISettingsStore = .shared, audit: AIAuditTrail = .shared) {
        self.settings = settings
        self.audit = audit
        self.layeredSummary = LayeredSummaryModel(settings: settings, audit: audit)
    }

    /// Host the current configuration would contact. The audit never stores a full URL.
    private var configuredAuditHost: String {
        if settings.connectionMode == .chatGPT { return "api.openai.com" }
        return settings.endpointInfo?.host ?? ""
    }

    private var configuredAuditModel: String {
        if settings.connectionMode == .chatGPT {
            return settings.chatGPT.selected?.model ?? ""
        }
        return settings.model
    }

    /// The base URL a preparation refusal is reported against. The ChatGPT plan always uses the
    /// fixed official endpoint, whatever the (unused) API-key field holds.
    private var auditBaseURL: String {
        settings.connectionMode == .chatGPT ? "https://api.openai.com/v1" : settings.baseURL
    }

    /// Record a refusal that happened before a plan existed. Nothing was sent.
    private func recordRefusal(_ kind: AIAuditAction, code: AIAuditCode, startedAt: Date) {
        audit.refuse(
            kind: kind,
            host: configuredAuditHost,
            model: configuredAuditModel,
            code: code,
            startedAt: startedAt
        )
    }


    public var isSending: Bool { phase == .streaming }
    public var isPreparing: Bool { phase == .preparing }
    public var hasPreview: Bool {
        plan != nil && (phase == .preview || phase == .mergePreview || phase == .streaming || phase.isTerminal)
    }
    public var canRetry: Bool { plan != nil && (phase == .failed || phase == .cancelled || phase == .finished) }
    public var isMerging: Bool { merging }
    public var canSendMerge: Bool { mergePlan != nil && phase == .mergePreview }
    public var canCancel: Bool { phase == .streaming }

    /// The calm hint that belongs beside the current transport error. Nil for every
    /// non-transport failure and for HTTP status errors (401/429/500), which keep their own text.
    public var offlineHint: AIOfflineHint? {
        guard phase == .failed else { return nil }
        return AIOfflineHint.forFailure(requestFailure)
    }

    /// The current plan is a document-chat question (as opposed to one of the four single-shot
    /// actions). The chat section stays visible alongside the action UI either way.
    public var isDocumentChatPlan: Bool { plan?.isDocumentChat == true }
    public var canAskDocument: Bool {
        !chatQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isPreparing && !isSending
    }
    public var canSendChatPreview: Bool { isDocumentChatPlan && phase == .preview }
    public var isChatStreaming: Bool { streamingChatTurnID != nil }
    public var hasChatConversation: Bool { !chatTurns.isEmpty }
    public var chatHistoryLimitDescription: String { Self.chatLimitDescription }

    /// The merged instrumentation for this plan. Counts only; never content.
    public var streamDiagnostics: AIStreamDiagnostics? {
        guard var merged = diagnostics.first else { return nil }
        for next in diagnostics.dropFirst() {
            merged.httpStatus = next.httpStatus
            merged.bytes += next.bytes
            merged.frames += next.frames
            merged.dataFrames += next.dataFrames
            merged.contentFrames += next.contentFrames
            merged.reasoningFrames += next.reasoningFrames
            merged.roleOnlyFrames += next.roleOnlyFrames
            merged.emptyFrames += next.emptyFrames
            merged.usageFrames += next.usageFrames
            if merged.contentShape == "none" {
                merged.contentShape = next.contentShape
            }
            if let reason = next.finishReason { merged.finishReason = reason }
            merged.usage = merged.usage.merged(with: next.usage)
        }
        return merged
    }

    public var finishReason: String? { streamDiagnostics?.finishReason }

    public var reasoningTokensIgnored: Bool {
        settings.reasoningMode == .off && (usage?.reasoningTokens ?? 0) > 0
    }

    /// How many requests Send will make. The preview lists each one.
    public var requestCount: Int { plan?.parts.count ?? 0 }

    /// Attach the current window's service and document. Switching documents cancels an
    /// in-flight request and swaps to that document's own conversation: a chat about another
    /// paper must never look current, and switching back must restore what was said.
    public func attach(service: (any AIChatServicing)?, context: AIReaderContext?) {
        self.service = service
        let key = context?.documentKey
        if documentKey != key {
            cancelWork()
            saveCurrentConversation()
            documentKey = key
            chatTurns = key.flatMap { conversations[$0] } ?? []
            expandedChatSources = []
            clearChatTransientState()
            regionAskedQuestion = nil
            phase = .idle
            statusNote = nil
        }
    }

    /// Prepare a request preview. This reads document text locally and does not read the key.
    public func prepare(action: AIAssistantAction, context: AIReaderContext) async {
        if documentKey != context.documentKey {
            attach(service: service, context: context)
        }
        let auditStart = Date()
        let auditKind = AIAuditAction(action)
        requestFailure = .other
        guard let service else {
            recordRefusal(auditKind, code: .notConfigured, startedAt: auditStart)
            phase = .failed
            errorMessage = Self.noEngineMessage
            statusNote = Self.noEngineMessage
            return
        }
        guard settings.canUseAI else {
            recordRefusal(auditKind,
                          code: settings.connectionMode == .chatGPT ? .signedOut : .noApiKey,
                          startedAt: auditStart)
            phase = .failed
            errorMessage = settings.connectionMode == .chatGPT
                ? "Sign in with ChatGPT in Settings > AI first. Nothing was sent." : Self.noKeyMessage
            statusNote = errorMessage
            return
        }
        let providerSettings: AIProviderSettings
        do {
            providerSettings = try settings.providerSettings()
        } catch {
            recordRefusal(auditKind,
                          code: AIAuditCode.classifyPreparationFailure(
                            error,
                            baseURL: auditBaseURL),
                          startedAt: auditStart)
            phase = .failed
            errorMessage = AIReadableError.message(error)
            statusNote = errorMessage
            return
        }

        cancelWork()
        preparedConnection = settings.connectionMode
        preparedAccountID = settings.connectionMode == .chatGPT ? settings.chatGPT.selectedID : nil
        phase = .preparing
        plan = nil
        resetMergeState()
        resetStreamOutput()
        errorMessage = nil
        statusNote = "Preparing the context preview. Nothing has been sent."

        let question = action == .askSelection
            ? question.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let language = action == .translateSelection
            ? targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let request = AIMakePlanRequest(
            action: action,
            currentPage: context.currentPage,
            selection: context.selection,
            question: (question?.isEmpty == false) ? question : nil,
            language: (language?.isEmpty == false) ? language : nil,
            settings: providerSettings
        )

        do {
            let source = try await service.prepare(request)
            let plan = try preparedConnection == .chatGPT ? ChatGPTResponses.plan(source) : source
            guard documentKey == context.documentKey else { return }
            self.plan = plan
            phase = .preview
            statusNote = "Nothing has been sent yet. Review the request below, then press Send."
        } catch {
            guard documentKey == context.documentKey else { return }
            recordRefusal(auditKind,
                          code: AIAuditCode.classifyPreparationFailure(
                            error,
                            baseURL: auditBaseURL),
                          startedAt: auditStart)
            phase = .failed
            errorMessage = AIReadableError.message(error)
            statusNote = errorMessage
        }
    }

    /// Build the preview for a document-chat question. Retrieval runs locally over the whole
    /// document; nothing is sent until the reader presses Send.
    ///
    /// An empty retrieval is not a provider error: no plan is built, the question is kept as a
    /// local exchange with the "nothing relevant" answer, and no request is started.
    public func prepareDocumentChat(context: AIReaderContext) async {
        if documentKey != context.documentKey {
            attach(service: service, context: context)
        }
        let question = chatQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            statusNote = "Type a question about the document first; nothing was sent."
            return
        }
        let auditStart = Date()
        guard let service else {
            recordRefusal(.documentChat, code: .notConfigured, startedAt: auditStart)
            phase = .failed
            errorMessage = Self.noEngineMessage
            statusNote = Self.noEngineMessage
            return
        }
        guard settings.canUseAI else {
            recordRefusal(.documentChat,
                          code: settings.connectionMode == .chatGPT ? .signedOut : .noApiKey,
                          startedAt: auditStart)
            phase = .failed
            errorMessage = settings.connectionMode == .chatGPT
                ? "Sign in with ChatGPT in Settings > AI first. Nothing was sent." : Self.noKeyMessage
            statusNote = errorMessage
            return
        }
        let providerSettings: AIProviderSettings
        do {
            providerSettings = try settings.providerSettings()
        } catch {
            recordRefusal(.documentChat,
                          code: AIAuditCode.classifyPreparationFailure(
                            error,
                            baseURL: auditBaseURL),
                          startedAt: auditStart)
            phase = .failed
            errorMessage = AIReadableError.message(error)
            statusNote = errorMessage
            return
        }

        cancelWork()
        preparedConnection = settings.connectionMode
        preparedAccountID = settings.connectionMode == .chatGPT ? settings.chatGPT.selectedID : nil
        phase = .preparing
        plan = nil
        resetMergeState()
        resetStreamOutput()
        errorMessage = nil
        retryingChatTurnID = nil
        pendingChatQuestion = question
        statusNote = "Finding relevant passages in the whole document. Nothing has been sent."

        let request = AIMakePlanRequest(
            action: .documentChat,
            currentPage: context.currentPage,
            selection: nil,
            question: question,
            language: nil,
            history: chatHistoryForRequest(),
            settings: providerSettings
        )
        do {
            let source = try await service.prepare(request)
            let plan = try preparedConnection == .chatGPT ? ChatGPTResponses.plan(source) : source
            guard documentKey == context.documentKey, pendingChatQuestion == question else { return }
            self.plan = plan
            phase = .preview
            statusNote = "Nothing has been sent yet. The preview lists the pages and characters that will go out; press Send to ask."
        } catch {
            guard documentKey == context.documentKey, pendingChatQuestion == question else { return }
            let message = AIReadableError.message(error)
            if message.contains("Nothing in this document is relevant") {
                recordRefusal(.documentChat, code: .nothingRelevant, startedAt: auditStart)
                // Honest local answer: the provider is not called with an empty context.
                appendChatTurn(AIChatTurn(
                    question: question,
                    answer: message,
                    pageCount: Int(context.pageCount),
                    state: .nothingRelevant
                ))
                chatQuestion = ""
                plan = nil
                pendingChatQuestion = nil
                phase = .idle
                errorMessage = nil
                statusNote = "Nothing relevant was found. No request was sent."
            } else {
                recordRefusal(.documentChat,
                              code: AIAuditCode.classifyPreparationFailure(
                                error,
                                baseURL: auditBaseURL),
                              startedAt: auditStart)
                phase = .failed
                errorMessage = message
                statusNote = message
            }
        }
    }

    /// Prepare a question about a marquee-selected region.
    ///
    /// Unlike `prepare(action:context:)` this is not retrieval: the request carries the reader's
    /// exact rectangle, its extracted text and (when the model accepts images) the PNG capture.
    /// The preview is the same `AiPlanRecord` every other action shows, so nothing can be sent
    /// that the card did not display.
    public func prepareRegion(
        question rawQuestion: String,
        attachment: AIRegionAttachment,
        context: AIReaderContext
    ) async {
        if documentKey != context.documentKey {
            attach(service: service, context: context)
        }
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            phase = .idle
            statusNote = "Type a question about the selected region first; nothing was sent."
            errorMessage = nil
            return
        }
        let auditStart = Date()
        guard let service else {
            recordRefusal(.regionQuestion, code: .notConfigured, startedAt: auditStart)
            phase = .failed
            errorMessage = Self.noEngineMessage
            statusNote = Self.noEngineMessage
            return
        }
        guard settings.canUseAI else {
            recordRefusal(.regionQuestion,
                          code: settings.connectionMode == .chatGPT ? .signedOut : .noApiKey,
                          startedAt: auditStart)
            phase = .failed
            errorMessage = settings.connectionMode == .chatGPT
                ? "Sign in with ChatGPT in Settings > AI first. Nothing was sent." : Self.noKeyMessage
            statusNote = errorMessage
            return
        }
        let providerSettings: AIProviderSettings
        do {
            providerSettings = try settings.providerSettings()
        } catch {
            recordRefusal(.regionQuestion,
                          code: AIAuditCode.classifyPreparationFailure(
                            error,
                            baseURL: auditBaseURL),
                          startedAt: auditStart)
            phase = .failed
            errorMessage = AIReadableError.message(error)
            statusNote = errorMessage
            return
        }

        cancelWork()
        preparedConnection = settings.connectionMode
        preparedAccountID = settings.connectionMode == .chatGPT ? settings.chatGPT.selectedID : nil
        phase = .preparing
        plan = nil
        resetMergeState()
        resetStreamOutput()
        errorMessage = nil
        retryingChatTurnID = nil
        regionAskedQuestion = question
        pendingChatQuestion = nil
        statusNote = "Building the request preview for this region. Nothing has been sent."

        let request = AIMakePlanRequest(
            action: .regionQuestion,
            currentPage: context.currentPage,
            selection: nil,
            question: question,
            language: nil,
            history: [],
            region: attachment,
            sendRegionImage: providerSettings.vision,
            settings: providerSettings
        )
        do {
            let source = try await service.prepare(request)
            let plan = try preparedConnection == .chatGPT ? ChatGPTResponses.plan(source) : source
            guard documentKey == context.documentKey, regionAskedQuestion == question else { return }
            self.plan = plan
            phase = .preview
            let imageNote = plan.parts.first?.includesRegionImage == true
                ? "The image part is included." : "Text only: the image part is not included."
            statusNote = "Nothing has been sent yet. \(imageNote) Review the exact request below, then press Ask."
        } catch {
            guard documentKey == context.documentKey, regionAskedQuestion == question else { return }
            let message = AIReadableError.message(error)
            recordRefusal(.regionQuestion,
                          code: AIAuditCode.classifyPreparationFailure(
                            error,
                            baseURL: auditBaseURL),
                          startedAt: auditStart)
            phase = .failed
            errorMessage = message
            statusNote = message
        }
    }

    /// Copy a finished region conversation into this document's panel chat. It is an explicit
    /// save action: nothing is written to the PDF, and the card remains.
    public func importConversation(
        question: String,
        answer: String,
        attachment: AIRegionAttachment,
        context: AIReaderContext
    ) {
        if documentKey != context.documentKey {
            attach(service: service, context: context)
        }
        let source = AIChatSource(
            page: attachment.page + 1,
            snippet: attachment.text.isEmpty
                ? "Region image · \(attachment.pixelWidth)×\(attachment.pixelHeight) px"
                : String(attachment.text.prefix(160)),
            rects: [attachment.rect]
        )
        let turn = AIChatTurn(
            question: question,
            answer: answer,
            sources: [source],
            pageCount: context.pageCount,
            state: .finished
        )
        appendChatTurn(turn)
        selectedTab = .chat
        statusNote = "Region conversation copied into the panel chat. It is still not a PDF annotation."
    }

    /// Send the previewed plan. The key is read here, handed to the worker, and not retained.
    public func send() {
        guard let plan, let service else {
            phase = .failed
            errorMessage = plan == nil ? "There is no request to send." : Self.noEngineMessage
            return
        }
        guard !isSending else { return }
        requestFailure = .other
        if plan.isDocumentChat {
            sendDocumentChat(plan, service: service)
            return
        }
        let handle: any AIChatHandle
        do { handle = try startPrepared(plan, service: service) }
        catch {
            phase = .failed; errorMessage = AIReadableError.message(error); statusNote = errorMessage
            return
        }
        pollTask?.cancel()
        self.handle = handle
        resetMergeState()
        resetStreamOutput()
        errorMessage = nil
        phase = .streaming
        statusNote = plan.action == .regionQuestion
            ? "Asking about the region…"
            : (plan.parts.count > 1
                ? "Streaming 1 of \(plan.parts.count)."
                : "Streaming…")
        startPolling(handle)
    }

    /// Start the already-previewed chat request. The question is recorded as a turn before the
    /// first token so Cancel, a provider error and a stream that dies all keep it on screen.
    private func sendDocumentChat(_ plan: AiPlanRecord, service: any AIChatServicing) {
        guard let question = pendingChatQuestion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !question.isEmpty else {
            phase = .failed
            errorMessage = "There is no chat question to send."
            statusNote = errorMessage
            return
        }
        let handle: any AIChatHandle
        do { handle = try startPrepared(plan, service: service) }
        catch {
            phase = .failed
            errorMessage = AIReadableError.message(error)
            statusNote = errorMessage
            return
        }
        let turnID: UUID
        if let retrying = retryingChatTurnID,
           let index = chatTurns.firstIndex(where: { $0.id == retrying }) {
            chatTurns[index].answer = ""
            chatTurns[index].reasoning = ""
            chatTurns[index].error = nil
            chatTurns[index].failure = nil
            chatTurns[index].usage = nil
            chatTurns[index].state = .streaming
            turnID = chatTurns[index].id
        } else {
            let turn = AIChatTurn(
                question: question,
                sources: plan.chatSources,
                pageCount: Int(plan.pageCount)
            )
            appendChatTurn(turn)
            turnID = turn.id
        }
        retryingChatTurnID = nil
        streamingChatTurnID = turnID
        chatQuestion = ""
        pollTask?.cancel()
        self.handle = handle
        resetMergeState()
        resetStreamOutput()
        errorMessage = nil
        phase = .streaming
        statusNote = "Asking the document…"
        startPolling(handle)
    }

    /// Ask the worker to stop. The partial answer stays on screen and Retry can send the same
    /// already-previewed request again.
    public func cancel() {
        guard phase == .streaming else { return }
        handle?.cancel()
        statusNote = "Cancelling…"
        let currentHandle = handle
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.phase == .streaming else { return }
            // The transport should report cancellation well before this. If a provider never
            // closes its stream, do not leave the panel stuck in "Cancelling" forever.
            self.handle?.cancel()
            if self.handle === currentHandle {
                if self.streamingChatTurnID != nil {
                    self.finishChatTurn(.cancelled)
                } else {
                    self.phase = .cancelled
                    self.statusNote = self.answer.isEmpty
                        ? "Cancelled before the first token."
                        : "Cancelled after \(self.answer.count) characters."
                    self.handle = nil
                    self.pollTask?.cancel()
                }
            }
        }
    }

    /// Re-send the plan that was already shown and approved. This is not a hidden extra request:
    /// the reader is pressing Retry on the same preview.
    public func retry() {
        guard canRetry, let plan else { return }
        if plan.isDocumentChat {
            guard let last = chatTurns.last,
                  last.question == pendingChatQuestion,
                  last.state == .cancelled || last.state == .failed else { return }
            retryingChatTurnID = last.id
        }
        send()
    }

    /// Throw the preview or answer away and return to the action list. For a chat preview this
    /// keeps the conversation; `clearChat()` is the explicit way to delete it.
    public func discard() {
        let wasChat = plan?.isDocumentChat == true || pendingChatQuestion != nil
        cancelWork()
        plan = nil
        resetMergeState()
        resetStreamOutput()
        errorMessage = nil
        if wasChat {
            pendingChatQuestion = nil
            retryingChatTurnID = nil
            statusNote = "Chat preview discarded. Nothing was sent; the conversation is kept."
        } else {
            statusNote = nil
        }
        phase = .idle
    }

    /// Drop the current document's conversation and any pending chat preview. Nothing is sent
    /// and no annotation or cached entry is touched. Conversations for other documents remain.
    public func clearChat() {
        let chatPlan = plan?.isDocumentChat == true
        let hadChat = !chatTurns.isEmpty || chatPlan
            || pendingChatQuestion != nil || streamingChatTurnID != nil
        if streamingChatTurnID != nil {
            cancelWork()
        }
        chatTurns = []
        expandedChatSources = []
        chatQuestion = ""
        if let key = documentKey { conversations[key] = [] }
        if chatPlan {
            plan = nil
        }
        pendingChatQuestion = nil
        retryingChatTurnID = nil
        if chatPlan {
            resetStreamOutput()
            errorMessage = nil
            phase = .idle
        }
        statusNote = hadChat
            ? "Chat cleared for this document. No request was sent and nothing was annotated."
            : "There is no chat to clear for this document."
    }

    /// Send the separately previewed consolidation request. The part summaries stay available;
    /// this is the only place the merge request is sent, and only after the reader presses it.
    public func sendMerge() {
        guard let mergePlan, let service, phase == .mergePreview else { return }
        requestFailure = .other
        let handle: any AIChatHandle
        do { handle = try startPrepared(mergePlan, service: service, kind: .summaryLayer) }
        catch {
            phase = .failed; errorMessage = AIReadableError.message(error); statusNote = errorMessage
            return
        }
        pollTask?.cancel()
        self.handle = handle
        merging = true
        resetStreamOutput()
        errorMessage = nil
        phase = .streaming
        statusNote = "Streaming the consolidated summary…"
        startPolling(handle)
    }

    /// Dismiss the consolidation preview without sending it; the part summaries stay available.
    public func keepPartSummaries() {
        guard phase == .mergePreview else { return }
        mergePlan = nil
        phase = .finished
        statusNote = "Part summaries kept. No consolidation was sent."
    }

    /// The one place both transports start: the API-key path hands the plan to the Rust worker,
    /// the ChatGPT path hands it to `ChatGPTResponsesHandle`. Every request therefore passes this
    /// hook exactly once, and the audit handle observes the same terminal events as the panel.
    private func startPrepared(_ plan: AiPlanRecord, service: any AIChatServicing,
                               kind: AIAuditAction? = nil) throws -> any AIChatHandle {
        try AIAuditedRequestStart.start(
            plan: plan, kind: kind ?? AIAuditAction(plan.action), audit: audit
        ) {
            if preparedConnection == .chatGPT {
                guard settings.connectionMode == preparedConnection else {
                    throw AISettingsError.invalid("The AI connection changed. Prepare a new request before sending.")
                }
                guard let id = preparedAccountID, settings.chatGPT.selectedID == id,
                      settings.chatGPT.isConnected else {
                    throw AISettingsError.invalid("The ChatGPT account changed or signed out. Prepare a new request.")
                }
                return ChatGPTResponsesHandle(plan: plan, accounts: settings.chatGPT, accountID: id)
            }
            guard settings.connectionMode == preparedConnection else {
                throw AISettingsError.invalid("The AI connection changed. Prepare a new request before sending.")
            }
            guard let key = try settings.readKey() else {
                throw AISettingsError.invalid(Self.noKeyMessage)
            }
            return try service.start(plan, apiKey: key)
        }
    }

    // MARK: - Polling

    private func startPolling(_ handle: any AIChatHandle) {
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let events = handle.poll()
                if !events.isEmpty {
                    self.apply(events)
                }
                if handle.isFinished {
                    let remaining = handle.poll()
                    if !remaining.isEmpty {
                        self.apply(remaining)
                    }
                    break
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
            self.finishPolling()
        }
    }

    private func apply(_ events: [AIStreamEvent]) {
        if streamingChatTurnID != nil {
            applyChat(events)
            return
        }
        for event in events {
            switch event {
            case .partStarted(let index, let total, let label):
                currentPartIndex = index
                partLabels[index] = label
                if !merging && partAnswers[index] == nil {
                    partAnswers[index] = ""
                }
                if total > 1 {
                    let header = "Part \(index + 1) of \(total) · \(label)"
                    if answer.isEmpty {
                        answer = header + "\n\n"
                    } else {
                        answer += "\n\n" + header + "\n\n"
                    }
                }
                statusNote = total > 1
                    ? "Streaming part \(index + 1) of \(total) — \(label)."
                    : "Streaming…"
            case .delta(let text):
                answer += text
                contentDeltaCount += 1
                if !merging {
                    let index = currentPartIndex ?? 0
                    partAnswers[index, default: ""] += text
                }
            case .reasoningDelta(let text):
                reasoning += text
                reasoningDeltaCount += 1
                if answer.isEmpty {
                    statusNote = "The provider is sending reasoning (not the answer)…"
                }
            case .usage(let reported):
                usageUpdateCount += 1
                if let existing = usage {
                    usage = existing.merged(with: reported)
                } else {
                    usage = reported
                }
            case .diagnostics(let reported):
                diagnostics.append(reported)
            case .done:
                handleDone()
            case .error(let message, let cancelled, let failure):
                if cancelled {
                    phase = .cancelled
                    statusNote = answer.isEmpty
                        ? "Cancelled before the first token."
                        : "Cancelled after \(answer.count) characters. The partial answer is kept."
                } else {
                    phase = .failed
                    requestFailure = failure
                    errorMessage = message
                    var note = message
                    if !merging,
                       let plan,
                       plan.action == .summarizeDocument,
                       plan.parts.count > 1
                    {
                        let failed = (currentPartIndex ?? 0) + 1
                        note += " Part \(failed) of \(plan.parts.count) failed, so no consolidation was attempted; the part summaries are kept."
                    }
                    statusNote = note
                }
                handle = nil
                pollTask?.cancel()
            }
        }
    }

    /// Events for the one chat turn that is streaming. The previous turns are untouched, so a
    /// provider error can never erase the conversation.
    private func applyChat(_ events: [AIStreamEvent]) {
        for event in events {
            switch event {
            case .partStarted(let index, let total, let label):
                currentPartIndex = index
                guard total > 1 else {
                    statusNote = "Asking the document…"
                    continue
                }
                statusNote = "Answering part \(index + 1) of \(total) — \(label)."
            case .delta(let text):
                contentDeltaCount += 1
                updateStreamingChatTurn { turn in
                    turn.answer += text
                    turn.state = .streaming
                }
                statusNote = "Streaming the answer… \(streamingChatCharacterCount) characters received."
            case .reasoningDelta(let text):
                reasoningDeltaCount += 1
                reasoning += text
                updateStreamingChatTurn { $0.reasoning += text }
                if streamingChatTurnAnswerIsEmpty {
                    statusNote = "The provider is sending reasoning (not the answer)…"
                }
            case .usage(let reported):
                usageUpdateCount += 1
                if let existing = usage {
                    usage = existing.merged(with: reported)
                } else {
                    usage = reported
                }
                updateStreamingChatTurn { $0.usage = usage }
            case .diagnostics(let reported):
                diagnostics.append(reported)
            case .done:
                finishChatTurn(.finished)
            case .error(let message, let cancelled, let failure):
                if cancelled {
                    finishChatTurn(.cancelled)
                } else {
                    failChatTurn(message, failure: failure)
                }
            }
        }
    }

    private var streamingChatCharacterCount: Int {
        guard let id = streamingChatTurnID,
              let turn = chatTurns.first(where: { $0.id == id }) else { return 0 }
        return turn.answer.count
    }

    private var streamingChatTurnAnswerIsEmpty: Bool {
        guard let id = streamingChatTurnID,
              let turn = chatTurns.first(where: { $0.id == id }) else { return true }
        return turn.answer.isEmpty
    }

    private func updateStreamingChatTurn(_ body: (inout AIChatTurn) -> Void) {
        guard let id = streamingChatTurnID,
              let index = chatTurns.firstIndex(where: { $0.id == id }) else { return }
        body(&chatTurns[index])
    }

    private func finishChatTurn(_ state: AIChatTurn.State) {
        guard let id = streamingChatTurnID else { return }
        streamingChatTurnID = nil
        if let index = chatTurns.firstIndex(where: { $0.id == id }) {
            chatTurns[index].state = state
            chatTurns[index].usage = usage
            if state == .finished, !chatTurns[index].answer.isEmpty {
                chatTurns[index].error = nil
                chatTurns[index].failure = nil
            }
        }
        let final = chatTurns.first(where: { $0.id == id })
        switch state {
        case .finished:
            phase = .finished
            if let final, final.answer.isEmpty {
                errorMessage = nil
                statusNote = emptyChatAnswerMessage(for: final)
            } else if let final, !final.backlinks(pageCount: final.pageCount).unverified.isEmpty {
                let count = final.backlinks(pageCount: final.pageCount).unverified.count
                statusNote = "Finished. \(count) citation(s) could not be verified; the answer says which pages were not sent."
            } else {
                statusNote = "Finished. The answer is complete."
            }
        case .cancelled:
            phase = .cancelled
            let count = final?.answer.count ?? 0
            statusNote = count == 0
                ? "Cancelled before the first token. The question is kept."
                : "Cancelled after \(count) characters. The partial answer and the question are kept."
        case .failed:
            phase = .failed
            statusNote = errorMessage ?? "The request failed. The conversation is kept; the next question can still be asked."
        case .nothingRelevant:
            phase = .idle
        case .streaming:
            break
        }
        handle = nil
        pollTask?.cancel()
        saveCurrentConversation()
    }

    private func failChatTurn(_ message: String, failure: AIRequestFailure = .other) {
        guard let id = streamingChatTurnID else {
            phase = .failed
            requestFailure = failure
            errorMessage = message
            statusNote = message
            return
        }
        streamingChatTurnID = nil
        if let index = chatTurns.firstIndex(where: { $0.id == id }) {
            chatTurns[index].state = .failed
            chatTurns[index].error = message
            chatTurns[index].failure = failure
            chatTurns[index].usage = usage
        }
        requestFailure = failure
        handle = nil
        pollTask?.cancel()
        errorMessage = message
        phase = .failed
        statusNote = message + " The conversation is kept; the next question can still be asked."
        saveCurrentConversation()
    }

    private func emptyChatAnswerMessage(for turn: AIChatTurn) -> String {
        var text = "The provider returned no answer text. The question is kept; you can retry or ask another."
        if !turn.reasoning.isEmpty {
            text = "The provider sent reasoning but no answer. The question is kept; you can retry or ask another."
        }
        if finishReason == "length" {
            text = "The provider stopped at its token limit before answering. The question is kept; you can retry or ask another."
        }
        return text
    }

    private func handleDone() {
        if streamingChatTurnID != nil {
            finishChatTurn(.finished)
            return
        }
        if merging {
            finishAnswer()
            return
        }
        guard let plan else {
            finishAnswer()
            return
        }
        if plan.action == .summarizeDocument && plan.parts.count > 1 {
            let missing = (0..<plan.parts.count).filter {
                (partAnswers[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if missing.isEmpty {
                // Leave the polling phase synchronously: finishPolling() runs as soon as this
                // event batch ends and would otherwise call a completed request a failure.
                phase = .mergePreview
                mergePlan = nil
                statusNote = "Part summaries complete. Building the consolidation preview locally; nothing else has been sent."
                handle = nil
                pollTask?.cancel()
                Task { @MainActor [weak self] in
                    await self?.prepareMergePreview(for: plan)
                }
                return
            }
            phase = .finished
            let labels = missing.map { "Part \($0 + 1) of \(plan.parts.count)" }
            let subject = labels.count == 1 ? labels[0] : labels.joined(separator: ", ")
            statusNote = "\(subject) is missing, so no consolidation was attempted. The per-part summaries are kept."
            handle = nil
            pollTask?.cancel()
            return
        }
        finishAnswer()
    }

    private func prepareMergePreview(for plan: AiPlanRecord) async {
        guard let service else {
            phase = .finished
            statusNote = "The Rust engine is not available, so no consolidation preview could be built."
            return
        }
        phase = .mergePreview
        mergePlan = nil
        statusNote = "Part summaries complete. Building the consolidation preview locally; nothing else has been sent."
        let parts = plan.parts.map { part in
            AIMergePart(
                index: Int(part.index) + 1,
                total: Int(part.total),
                pages: part.pages.map(Int.init),
                summary: partAnswers[Int(part.index)] ?? ""
            )
        }
        let providerSettings: AIProviderSettings
        do {
            providerSettings = try settings.providerSettings()
        } catch {
            phase = .finished
            errorMessage = AIReadableError.message(error)
            statusNote = "No consolidation: \(AIReadableError.message(error)) The per-part summaries are kept."
            return
        }
        do {
            let mergePlan = try await service.prepareMerge(
                AIMergePlanRequest(
                    documentTitle: plan.documentTitle,
                    settings: providerSettings,
                    parts: parts
                )
            )
            self.mergePlan = try preparedConnection == .chatGPT ? ChatGPTResponses.plan(mergePlan) : mergePlan
            phase = .mergePreview
            statusNote = "Part summaries complete. Review the consolidation request below; sending it is a separate request."
        } catch {
            phase = .finished
            mergePlan = nil
            errorMessage = AIReadableError.message(error)
            statusNote = "No consolidation: \(AIReadableError.message(error)) The per-part summaries are kept."
            handle = nil
            pollTask?.cancel()
        }
    }

    private func finishAnswer() {
        phase = .finished
        if answer.isEmpty {
            statusNote = emptyAnswerMessage()
        } else if finishReason == "length" {
            statusNote = "Finished at the provider's token limit; the answer may be truncated."
        } else {
            statusNote = "Finished. The answer is complete."
        }
        handle = nil
        pollTask?.cancel()
    }

    /// A completed stream with no `content` deltas is not a success story. Name what arrived so a
    /// reader (or a developer) does not have to infer it from a usage line under a blank pane.
    private func emptyAnswerMessage() -> String {
        var prefix = "The provider returned no answer."
        if finishReason == "length" {
            prefix = "The provider stopped at its token limit before answering."
        } else if !reasoning.isEmpty {
            prefix = "The provider sent reasoning but no answer."
        }

        var observations: [String] = []
        let stats = streamDiagnostics
        if let stats {
            observations.append("HTTP \(stats.httpStatus)")
            observations.append("\(stats.frames) frame(s), \(stats.dataFrames) data")
            observations.append("\(stats.contentFrames) content, \(stats.reasoningFrames) reasoning, \(stats.roleOnlyFrames) role-only, \(stats.emptyFrames) empty")
            observations.append("content shape \(stats.contentShape)")
            observations.append("finish_reason \(stats.finishReason ?? "not reported")")
            observations.append("\(stats.bytes) bytes")
            if !stats.usage.isEmpty {
                observations.append("usage \(stats.usage.summary)")
            }
        } else {
            observations.append("no `content` deltas")
            if reasoningDeltaCount > 0 {
                observations.append("\(reasoningDeltaCount) reasoning delta(s)")
            }
            if usageUpdateCount > 0 {
                observations.append("\(usageUpdateCount) usage update(s)")
            }
        }
        if let completion = stats?.usage.completionTokens ?? usage?.completionTokens {
            if stats?.usage.completionTokens == nil {
                observations.append("usage reports \(completion) completion tokens")
            }
            if let budget = plan?.maxTokens.map({ Int($0) }), completion >= budget {
                observations.append("the request's max_tokens was \(budget)")
            }
        }
        if reasoningTokensIgnored {
            observations.append("the provider reported reasoning tokens even though thinking is off")
        }
        return prefix + " " + observations.joined(separator: "; ") + "."
    }

    private func finishPolling() {
        guard phase == .streaming else { return }
        // A worker that ended without a terminal event is a bug, not a successful answer.
        if let handle, handle.isFinished {
            let remaining = handle.poll()
            if !remaining.isEmpty {
                apply(remaining)
            }
        }
        guard phase == .streaming else { return }
        if streamingChatTurnID != nil {
            failChatTurn("The request ended without a final result. The conversation is kept.")
            return
        }
        phase = .failed
        errorMessage = "The request ended without a final result. Nothing else was sent."
        statusNote = errorMessage
        handle = nil
    }

    private func cancelWork() {
        if streamingChatTurnID != nil {
            finishChatTurn(.cancelled)
        }
        handle?.cancel()
        handle = nil
        pollTask?.cancel()
        pollTask = nil
    }

    /// Persist the current turns under the document they belong to. The dictionary is what makes
    /// switching documents restore a chat instead of silently carrying another paper's answers.
    private func saveCurrentConversation() {
        guard let key = documentKey else { return }
        trimChatTurns()
        conversations[key] = chatTurns
    }

    private func appendChatTurn(_ turn: AIChatTurn) {
        chatTurns.append(turn)
        trimChatTurns()
        saveCurrentConversation()
    }

    /// Bound the visible conversation to the most recent exchanges. The Rust planner applies the
    /// same bound to the request, so the preview cannot include something the panel dropped.
    private func trimChatTurns() {
        if chatTurns.count > Self.chatTurnLimit {
            chatTurns.removeFirst(chatTurns.count - Self.chatTurnLimit)
        }
    }

    /// The previous turns that go to the model: finished answers and cancelled partials, newest
    /// last, at most the bound. Failed and "nothing relevant" turns stay visible but are not fed
    /// back as if they were model answers.
    private func chatHistoryForRequest() -> [AIConversationTurn] {
        chatTurns
            .filter {
                ($0.state == .finished || $0.state == .cancelled)
                    && !$0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .suffix(Self.chatTurnLimit)
            .map { AIConversationTurn(question: $0.question, answer: $0.answer) }
    }

    private func clearChatTransientState() {
        plan = nil
        pendingChatQuestion = nil
        retryingChatTurnID = nil
        streamingChatTurnID = nil
        resetMergeState()
        resetStreamOutput()
        errorMessage = nil
    }

    private func resetMergeState() {
        mergePlan = nil
        partAnswers = [:]
        partLabels = [:]
        currentPartIndex = nil
        merging = false
    }

    private func resetStreamOutput() {
        answer = ""
        reasoning = ""
        usage = nil
        diagnostics = []
        contentDeltaCount = 0
        reasoningDeltaCount = 0
        usageUpdateCount = 0
        requestFailure = .other
    }
}
