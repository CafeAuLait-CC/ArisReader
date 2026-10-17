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
    @Published public private(set) var answer = ""
    @Published public private(set) var usage: AIUsage?
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

    public init(settings: AISettingsStore = .shared) {
        self.settings = settings
    }

    public var isSending: Bool { phase == .streaming }
    public var isPreparing: Bool { phase == .preparing }
    public var hasPreview: Bool { plan != nil && (phase == .preview || phase == .streaming || phase.isTerminal) }
    public var canRetry: Bool { plan != nil && (phase == .failed || phase == .cancelled || phase == .finished) }
    public var canCancel: Bool { phase == .streaming }

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
        answer = ""
        usage = nil
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
        answer = ""
        usage = nil
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
        answer = ""
        usage = nil
        errorMessage = nil
        statusNote = nil
        phase = .idle
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
            case .usage(let reported):
                if let existing = usage {
                    usage = existing.merged(with: reported)
                } else {
                    usage = reported
                }
            case .done:
                phase = .finished
                statusNote = answer.isEmpty
                    ? "The provider returned an empty answer."
                    : "Finished. The answer is complete."
                handle = nil
                pollTask?.cancel()
            case .error(let message, let cancelled):
                if cancelled {
                    phase = .cancelled
                    statusNote = answer.isEmpty
                        ? "Cancelled before the first token."
                        : "Cancelled after \(answer.count) characters. The partial answer is kept."
                } else {
                    phase = .failed
                    errorMessage = message
                    statusNote = message
                }
                handle = nil
                pollTask?.cancel()
            }
        }
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
        answer = ""
        usage = nil
        errorMessage = nil
    }
}
