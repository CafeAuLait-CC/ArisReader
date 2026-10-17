import ArisReaderBindings
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
    @Published public private(set) var documentKey: String?
    /// The question for "Ask selection"; the view binds it.
    @Published public var question = ""
    /// The target language for "Translate selection"; the view binds it.
    @Published public var targetLanguage = "English"

    public let settings: AISettingsStore
    private var service: (any AIChatServicing)?
    private var handle: (any AIChatHandle)?
    private var pollTask: Task<Void, Never>?
    private var currentPartIndex: Int?
    private var merging = false

    public init(settings: AISettingsStore = .shared) {
        self.settings = settings
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

    /// Attach the current window's service and document. Switching documents cancels an in-flight
    /// request and clears the old answer: an answer about another paper must never look current.
    public func attach(service: (any AIChatServicing)?, context: AIReaderContext?) {
        self.service = service
        let key = context?.documentKey
        if documentKey != key {
            cancelWork()
            documentKey = key
            clearConversation()
            phase = .idle
            statusNote = nil
        }
    }

    /// Prepare a request preview. This reads document text locally and does not read the key.
    public func prepare(action: AIAssistantAction, context: AIReaderContext) async {
        if documentKey != context.documentKey {
            cancelWork()
            documentKey = context.documentKey
            clearConversation()
        }
        guard let service else {
            phase = .failed
            errorMessage = Self.noEngineMessage
            statusNote = Self.noEngineMessage
            return
        }
        guard settings.hasKey else {
            phase = .failed
            errorMessage = Self.noKeyMessage
            statusNote = Self.noKeyMessage
            return
        }
        let providerSettings: AIProviderSettings
        do {
            providerSettings = try settings.providerSettings()
        } catch {
            phase = .failed
            errorMessage = AIReadableError.message(error)
            statusNote = errorMessage
            return
        }

        cancelWork()
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
            let plan = try await service.prepare(request)
            guard documentKey == context.documentKey else { return }
            self.plan = plan
            phase = .preview
            statusNote = "Nothing has been sent yet. Review the request below, then press Send."
        } catch {
            guard documentKey == context.documentKey else { return }
            phase = .failed
            errorMessage = AIReadableError.message(error)
            statusNote = errorMessage
        }
    }

    /// Send the previewed plan. The key is read here, handed to the worker, and not retained.
    public func send() {
        guard let plan, let service else {
            phase = .failed
            errorMessage = plan == nil ? "There is no request to send." : Self.noEngineMessage
            return
        }
        guard !isSending else { return }
        let key: String
        do {
            guard let stored = try settings.readKey() else {
                phase = .failed
                errorMessage = Self.noKeyMessage
                statusNote = Self.noKeyMessage
                return
            }
            key = stored
        } catch {
            phase = .failed
            errorMessage = AIReadableError.message(error)
            statusNote = errorMessage
            return
        }

        let handle: any AIChatHandle
        do {
            handle = try service.start(plan, apiKey: key)
        } catch {
            phase = .failed
            errorMessage = AIReadableError.message(error)
            statusNote = errorMessage
            return
        }
        pollTask?.cancel()
        self.handle = handle
        resetMergeState()
        resetStreamOutput()
        errorMessage = nil
        phase = .streaming
        statusNote = plan.parts.count > 1
            ? "Streaming 1 of \(plan.parts.count)."
            : "Streaming…"
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
                self.phase = .cancelled
                self.statusNote = self.answer.isEmpty
                    ? "Cancelled before the first token."
                    : "Cancelled after \(self.answer.count) characters."
                self.handle = nil
                self.pollTask?.cancel()
            }
        }
    }

    /// Re-send the plan that was already shown and approved. This is not a hidden extra request:
    /// the reader is pressing Retry on the same preview.
    public func retry() {
        guard canRetry, plan != nil else { return }
        send()
    }

    /// Throw the preview or answer away and return to the action list.
    public func discard() {
        cancelWork()
        plan = nil
        resetMergeState()
        resetStreamOutput()
        errorMessage = nil
        statusNote = nil
        phase = .idle
    }

    /// Send the separately previewed consolidation request. The part summaries stay available;
    /// this is the only place the merge request is sent, and only after the reader presses it.
    public func sendMerge() {
        guard let mergePlan, let service, phase == .mergePreview else { return }
        let key: String
        do {
            guard let stored = try settings.readKey() else {
                phase = .failed
                errorMessage = Self.noKeyMessage
                statusNote = Self.noKeyMessage
                return
            }
            key = stored
        } catch {
            phase = .failed
            errorMessage = AIReadableError.message(error)
            statusNote = errorMessage
            return
        }
        let handle: any AIChatHandle
        do {
            handle = try service.start(mergePlan, apiKey: key)
        } catch {
            phase = .failed
            errorMessage = AIReadableError.message(error)
            statusNote = errorMessage
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
            case .error(let message, let cancelled):
                if cancelled {
                    phase = .cancelled
                    statusNote = answer.isEmpty
                        ? "Cancelled before the first token."
                        : "Cancelled after \(answer.count) characters. The partial answer is kept."
                } else {
                    phase = .failed
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

    private func handleDone() {
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
            self.mergePlan = mergePlan
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
        phase = .failed
        errorMessage = "The request ended without a final result. Nothing else was sent."
        statusNote = errorMessage
        handle = nil
    }

    private func cancelWork() {
        handle?.cancel()
        handle = nil
        pollTask?.cancel()
        pollTask = nil
    }

    private func clearConversation() {
        plan = nil
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
    }
}
