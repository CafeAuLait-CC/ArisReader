import LyraReaderBindings
import Combine
import CoreGraphics
import Foundation
import Security

// MARK: - Actions and request inputs

public enum AIAssistantTab: String, CaseIterable, Identifiable, Sendable {
    case summary, translation, chat, regions
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .summary: "Summary"
        case .translation: "Translate"
        case .chat: "Chat"
        case .regions: "Regions"
        }
    }
    public var icon: String {
        switch self {
        case .summary: "doc.text"
        case .translation: "character.bubble"
        case .chat: "text.bubble"
        case .regions: "rectangle.dashed"
        }
    }
}

/// The actions the AI panel can request. Document chat is the conversational action; the other
/// four stay available alongside it.
public enum AIAssistantAction: String, CaseIterable, Identifiable, Sendable {
    case documentChat
    case summarizePage
    case summarizeDocument
    case summarizeSelection
    case askSelection
    case translateSelection
    /// Not a panel action: a question about a marquee-selected region, built by the inline card.
    case regionQuestion

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .documentChat: return "Ask the document"
        case .summarizePage: return "Summarise page"
        case .summarizeDocument: return "Summarise document"
        case .summarizeSelection: return "Summarise selection"
        case .askSelection: return "Ask selection"
        case .translateSelection: return "Translate selection"
        case .regionQuestion: return "Ask about a region"
        }
    }

    public var systemImage: String {
        switch self {
        case .documentChat: return "text.bubble"
        case .summarizePage: return "doc.text"
        case .summarizeDocument: return "doc.on.doc"
        case .summarizeSelection: return "text.quote"
        case .askSelection: return "questionmark.bubble"
        case .translateSelection: return "character.bubble"
        case .regionQuestion: return "rectangle.dashed"
        }
    }

    /// The Rust action this maps to.
    var generated: AiActionRecord {
        switch self {
        case .documentChat: return .documentChat
        case .summarizePage: return .summarizePage
        case .summarizeDocument: return .summarizeDocument
        case .summarizeSelection: return .summarizeSelection
        case .askSelection: return .askSelection
        case .translateSelection: return .translateSelection
        case .regionQuestion: return .regionQuestion
        }
    }

    /// Whether the panel must have a live selection before offering the action.
    public var requiresSelection: Bool {
        self == .askSelection || self == .translateSelection || self == .summarizeSelection
    }

    /// The conversational action keeps the panel's chat section, even while a different action
    /// is previewing: the two share the host but not their request state.
    public var isDocumentChat: Bool { self == .documentChat }
}

/// A selected character range in the reader's 0-based text layer. `page` is 1-based for display.
public struct AIReaderSelection: Equatable, Sendable {
    public let page: Int
    public let start: Int
    public let end: Int

    public init(page: Int, start: Int, end: Int) {
        self.page = page
        self.start = max(0, start)
        self.end = max(self.start, end)
    }

    public var characterCount: Int { end - start + 1 }
}

/// The local reading context at the moment an action is pressed. It is also what lets the model
/// notice a document switch and drop an answer that belongs to the previous paper.
public struct AIReaderContext: Equatable, Sendable {
    public let documentKey: String
    public let documentTitle: String
    public let pageCount: Int
    /// 1-based, as the page HUD shows it.
    public let currentPage: Int
    public let selection: AIReaderSelection?

    public init(
        documentKey: String,
        documentTitle: String,
        pageCount: Int,
        currentPage: Int,
        selection: AIReaderSelection?
    ) {
        self.documentKey = documentKey
        self.documentTitle = documentTitle
        self.pageCount = pageCount
        self.currentPage = currentPage
        self.selection = selection
    }
}

// MARK: - Document chat

/// One passage that was actually sent with a chat question: where it came from, a one-line
/// snippet, and the page-local line boxes used for the transient source highlight.
public struct AIChatSource: Equatable, Sendable {
    /// 1-based, matching `[p.N]`.
    public let page: Int
    public let snippet: String
    /// 100% page-local view-space boxes, top-left origin. Empty when the text layer had no
    /// geometry; the chip still jumps, but no rectangle is invented.
    public let rects: [CGRect]

    public init(page: Int, snippet: String, rects: [CGRect]) {
        self.page = page
        self.snippet = snippet
        self.rects = rects
    }

    public init(record: AiSourceRecord) {
        self.init(
            page: Int(record.page),
            snippet: record.snippet,
            rects: record.rects.map {
                CGRect(x: $0.xPt, y: $0.yPt, width: $0.widthPt, height: $0.heightPt)
            }
        )
    }
}

/// A verified citation: the model cited this page and the page was sent. Clicking the chip
/// jumps to it and flashes the passage's boxes.
public struct AIChatChip: Identifiable, Equatable, Sendable {
    public let page: Int
    public let snippet: String
    public let rects: [CGRect]

    public var id: Int { page }

    /// The chip's click action, kept next to the data so the panel and the checks exercise the
    /// same jump+highlight path rather than each spelling the page conversion themselves.
    @MainActor
    public func follow(in state: AppState) {
        state.revealAISource(page: page - 1, rects: rects)
    }
}

/// A citation the panel refuses to turn into a link or a chip, with the reason in plain words.
public struct AIUnverifiedCitation: Identifiable, Equatable, Sendable {
    public let page: Int
    public let reason: String

    public var id: Int { page }
}

public struct AIAnswerBacklinks: Equatable, Sendable {
    public let chips: [AIChatChip]
    public let unverified: [AIUnverifiedCitation]

    public init(chips: [AIChatChip], unverified: [AIUnverifiedCitation]) {
        self.chips = chips
        self.unverified = unverified
    }

    public var sentPages: Set<Int> { Set(chips.map(\.page)) }
}

/// One exchange in a document's chat. The question is stored when Send is pressed, so Cancel and
/// provider errors leave the reader's question on screen with whatever answer arrived.
public struct AIChatTurn: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case streaming
        case finished
        case cancelled
        case failed
        /// Retrieval found nothing relevant and no request was made.
        case nothingRelevant
    }

    public let id: UUID
    public let question: String
    public var answer: String
    public var reasoning: String
    public let sources: [AIChatSource]
    /// The document page count when this turn was sent, so citations in old turns are still
    /// verified against the right document after the current plan changes.
    public let pageCount: Int
    public var state: State
    public var error: String?
    public var usage: AIUsage?

    public init(
        id: UUID = UUID(),
        question: String,
        answer: String = "",
        reasoning: String = "",
        sources: [AIChatSource] = [],
        pageCount: Int = 0,
        state: State = .streaming,
        error: String? = nil,
        usage: AIUsage? = nil
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.reasoning = reasoning
        self.sources = sources
        self.pageCount = pageCount
        self.state = state
        self.error = error
        self.usage = usage
    }

    public var isStreaming: Bool { state == .streaming }
    public var sentPages: Set<Int> { Set(sources.map(\.page)) }

    /// Split the strict `[p.N]` citations into chips for pages that were sent and refusals for
    /// every other cited page. A citation outside the document is not made clickable either.
    public func backlinks(pageCount: Int) -> AIAnswerBacklinks {
        let sent = sentPages
        var chips: [AIChatChip] = []
        var unverified: [AIUnverifiedCitation] = []
        for page in AIAnswerMarkdown.allCitedPages(in: answer) {
            if page < 1 || page > pageCount {
                unverified.append(AIUnverifiedCitation(
                    page: page,
                    reason: "Page \(page) is not in this document, so the citation could not be verified."
                ))
                continue
            }
            guard sent.contains(page) else {
                unverified.append(AIUnverifiedCitation(
                    page: page,
                    reason: "Page \(page) was not sent with this question, so the citation could not be verified."
                ))
                continue
            }
            guard !chips.contains(where: { $0.page == page }) else { continue }
            // A page can contribute more than one retrieved passage. The chip is one per page;
            // its snippet and highlight cover every passage that was sent from that page.
            let pageSources = sources.filter { $0.page == page }
            let snippet = pageSources
                .map(\.snippet)
                .filter { !$0.isEmpty }
                .joined(separator: " … ")
            chips.append(AIChatChip(
                page: page,
                snippet: snippet,
                rects: pageSources.flatMap(\.rects)
            ))
        }
        return AIAnswerBacklinks(chips: chips, unverified: unverified)
    }
}

/// The provider's reasoning control. Plain OpenAI compatibility has no standard disable field;
/// this endpoint exposes documented request extensions instead, and the user chooses which one
/// is sent.
public enum AIReasoningMode: String, CaseIterable, Identifiable, Sendable {
    case providerDefault = "default"
    case off
    case low
    case high
    case max

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .providerDefault: return "Provider default (send nothing)"
        case .off: return "Off"
        case .low: return "Low effort"
        case .high: return "High effort"
        case .max: return "Max effort"
        }
    }
}

public enum AIReasoningEncoding: String, CaseIterable, Identifiable, Sendable {
    case none
    case thinking
    case reasoningEffort = "reasoning_effort"
    case outputConfig = "output_config"
    case reasoning = "reasoning.effort"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: return "None"
        case .thinking: return "thinking"
        case .reasoningEffort: return "reasoning_effort"
        case .outputConfig: return "output_config"
        case .reasoning: return "reasoning.effort"
        }
    }

    /// The one JSON field this encoding inserts, or `nil` for no encoding.
    public var wireField: String? {
        switch self {
        case .none: return nil
        case .thinking: return "thinking"
        case .reasoningEffort: return "reasoning_effort"
        case .outputConfig: return "output_config"
        case .reasoning: return "reasoning"
        }
    }
}

/// Provider settings that are not secret. The key is deliberately not part of this value.
public struct AIProviderSettings: Equatable, Sendable {
    public var baseURL: String
    public var model: String
    public var temperature: Double?
    public var maxTokens: Int?
    public var reasoningMode: AIReasoningMode
    public var reasoningEncoding: AIReasoningEncoding
    /// Whether the configured model accepts image input. When false, a region question sends
    /// the extracted text only and the preview says so; it never sends a picture to a text-only
    /// endpoint.
    public var vision: Bool

    public init(
        baseURL: String,
        model: String,
        temperature: Double?,
        maxTokens: Int?,
        reasoningMode: AIReasoningMode = .off,
        reasoningEncoding: AIReasoningEncoding = .thinking,
        vision: Bool = false
    ) {
        self.baseURL = baseURL
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.reasoningMode = reasoningMode
        self.reasoningEncoding = reasoningEncoding
        self.vision = vision
    }

    /// Plain words for the request preview. This is the part that changes cost and latency.
    public var reasoningSummary: String {
        switch reasoningMode {
        case .providerDefault:
            return "Reasoning: provider default — no reasoning field is sent."
        case .off:
            switch reasoningEncoding {
            case .thinking: return "Reasoning: off — thinking: disabled is sent."
            case .reasoning: return "Reasoning: off — reasoning.effort: none is sent."
            default: return "Reasoning: off (this encoding combination is not sendable)."
            }
        case .low, .high, .max:
            let effort = reasoningMode.rawValue
            switch reasoningEncoding {
            case .reasoningEffort: return "Reasoning effort: \(effort) — reasoning_effort: \(effort) is sent."
            case .outputConfig: return "Reasoning effort: \(effort) — output_config.effort: \(effort) is sent."
            case .reasoning: return "Reasoning effort: \(effort) — reasoning.effort: \(effort) is sent."
            default: return "Reasoning effort: \(effort) (this encoding combination is not sendable)."
            }
        }
    }

    public var reasoningFieldDescription: String {
        guard let field = reasoningEncoding.wireField, reasoningMode != .providerDefault else {
            return "No reasoning JSON field is sent."
        }
        return "Reasoning JSON field: \(field)."
    }
}

/// A preview request: exactly what the panel needs to ask Rust for a plan. No key.
public struct AIMakePlanRequest: Sendable {
    public let action: AIAssistantAction
    public let currentPage: Int
    public let selection: AIReaderSelection?
    public let question: String?
    public let language: String?
    /// Oldest first. Only document chat reads it; the Rust builder applies the bound again.
    public let history: [AIConversationTurn]
    /// Present only for `regionQuestion`. The capture travels with the preview, so the request
    /// body and the preview are built from the same bytes.
    public let region: AIRegionAttachment?
    /// Whether the region picture should be included. Mirrors `settings.vision` and is explicit
    /// in the record so a text-only preview says why the image is absent.
    public let sendRegionImage: Bool
    public let settings: AIProviderSettings

    public init(
        action: AIAssistantAction,
        currentPage: Int,
        selection: AIReaderSelection?,
        question: String?,
        language: String?,
        history: [AIConversationTurn] = [],
        region: AIRegionAttachment? = nil,
        sendRegionImage: Bool = false,
        settings: AIProviderSettings
    ) {
        self.action = action
        self.currentPage = currentPage
        self.selection = selection
        self.question = question
        self.language = language
        self.history = history
        self.region = region
        self.sendRegionImage = sendRegionImage
        self.settings = settings
    }
}

/// One previous chat exchange. This is the unit the panel bounds and the model receives.
public struct AIConversationTurn: Equatable, Sendable {
    public let question: String
    public let answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

/// A completed part summary, ready for the separate consolidation request.
public struct AIMergePart: Equatable, Sendable {
    public var index: Int
    public var total: Int
    public var pages: [Int]
    public var summary: String

    public init(index: Int, total: Int, pages: [Int], summary: String) {
        self.index = index
        self.total = total
        self.pages = pages
        self.summary = summary
    }
}

public struct AIMergePlanRequest: Sendable {
    public var documentTitle: String
    public var settings: AIProviderSettings
    public var parts: [AIMergePart]

    public init(documentTitle: String, settings: AIProviderSettings, parts: [AIMergePart]) {
        self.documentTitle = documentTitle
        self.settings = settings
        self.parts = parts
    }
}

// MARK: - Usage and stream events

public struct AIUsage: Equatable, Sendable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?
    /// A subset of completion tokens on providers that expose thinking-token details.
    public var reasoningTokens: Int?

    public init(
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        totalTokens: Int? = nil,
        reasoningTokens: Int? = nil
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.reasoningTokens = reasoningTokens
    }

    public var isEmpty: Bool {
        promptTokens == nil && completionTokens == nil && totalTokens == nil
            && reasoningTokens == nil
    }

    /// Sums the token counts reported by the parts of one plan.
    public func merged(with other: AIUsage) -> AIUsage {
        AIUsage(
            promptTokens: Self.add(promptTokens, other.promptTokens),
            completionTokens: Self.add(completionTokens, other.completionTokens),
            totalTokens: Self.add(totalTokens, other.totalTokens),
            reasoningTokens: Self.add(reasoningTokens, other.reasoningTokens)
        )
    }

    /// A line for the panel. Only what the provider actually reported is shown.
    public var summary: String {
        var pieces: [String] = []
        if let promptTokens { pieces.append("\(promptTokens) prompt") }
        if let completionTokens { pieces.append("\(completionTokens) completion") }
        if let reasoningTokens { pieces.append("\(reasoningTokens) reasoning (of completion)") }
        if let totalTokens { pieces.append("\(totalTokens) total") }
        if pieces.isEmpty { return "No token usage was reported by the provider." }
        return "Tokens: " + pieces.joined(separator: " + ")
    }

    private static func add(_ first: Int?, _ second: Int?) -> Int? {
        switch (first, second) {
        case (nil, nil): return nil
        case (let value?, nil): return value
        case (nil, let value?): return value
        case (let first?, let second?): return first + second
        }
    }
}

/// Counts only: what the HTTP/SSE request actually produced. Shown when the answer is empty.
public struct AIStreamDiagnostics: Equatable, Sendable {
    public var httpStatus: Int
    public var bytes: Int
    public var frames: Int
    public var dataFrames: Int
    public var contentFrames: Int
    public var reasoningFrames: Int
    public var roleOnlyFrames: Int
    public var emptyFrames: Int
    public var usageFrames: Int
    public var contentShape: String
    public var finishReason: String?
    public var usage: AIUsage

    public init(
        httpStatus: Int,
        bytes: Int,
        frames: Int,
        dataFrames: Int,
        contentFrames: Int,
        reasoningFrames: Int,
        roleOnlyFrames: Int,
        emptyFrames: Int,
        usageFrames: Int,
        contentShape: String,
        finishReason: String?,
        usage: AIUsage
    ) {
        self.httpStatus = httpStatus
        self.bytes = bytes
        self.frames = frames
        self.dataFrames = dataFrames
        self.contentFrames = contentFrames
        self.reasoningFrames = reasoningFrames
        self.roleOnlyFrames = roleOnlyFrames
        self.emptyFrames = emptyFrames
        self.usageFrames = usageFrames
        self.contentShape = contentShape
        self.finishReason = finishReason
        self.usage = usage
    }
}

public enum AIStreamEvent: Equatable, Sendable {
    case partStarted(index: Int, total: Int, label: String)
    case delta(String)
    /// The provider's reasoning/thinking channel. Kept separate from the answer by contract.
    case reasoningDelta(String)
    case usage(AIUsage)
    case diagnostics(AIStreamDiagnostics)
    case done
    case error(message: String, cancelled: Bool)
}

// MARK: - Service boundary

/// A running request. Poll-based because the Rust worker is a plain thread and the panel is
/// main-actor SwiftUI; polling every 40 ms is simpler and safer across UniFFI than a foreign
/// callback that would have to be `Sendable` and re-enter Swift on a Rust thread.
@MainActor
public protocol AIChatHandle: AnyObject {
    func poll() -> [AIStreamEvent]
    func cancel()
    var isFinished: Bool { get }
}

@MainActor
public protocol AIChatServicing: AnyObject {
    func prepare(_ request: AIMakePlanRequest) async throws -> AiPlanRecord
    func prepareMerge(_ request: AIMergePlanRequest) async throws -> AiPlanRecord
    func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle
}

public extension AIChatServicing {
    /// Older test doubles do not need to implement consolidation; the production service does.
    func prepareMerge(_ request: AIMergePlanRequest) async throws -> AiPlanRecord {
        throw AISettingsError.invalid("This service cannot prepare a consolidation request.")
    }
}

/// The production service: context, prompts and HTTP all live in Rust. This type only translates
/// UniFFI records into Swift values.
@MainActor
public final class RustAIChatService: AIChatServicing {
    private let engine: RustEngine
    /// The deterministic mock provider. Only the checks and previews set this; the app does not.
    public let useMockProvider: Bool

    public init(engine: RustEngine, useMockProvider: Bool = false) {
        self.engine = engine
        self.useMockProvider = useMockProvider
    }

    public func prepare(_ request: AIMakePlanRequest) async throws -> AiPlanRecord {
        let selection = request.selection.map {
            AiSelectionRecord(
                page: UInt32(max(0, $0.page - 1)),
                start: UInt32($0.start),
                end: UInt32($0.end)
            )
        }
        let region = request.region.map { attachment in
            AiRegionRecord(
                page: UInt32(max(0, attachment.page)),
                xPt: Double(attachment.rect.minX),
                yPt: Double(attachment.rect.minY),
                widthPt: Double(attachment.rect.width),
                heightPt: Double(attachment.rect.height),
                text: attachment.text,
                imagePng: attachment.png,
                imageWidthPx: UInt32(max(0, attachment.pixelWidth)),
                imageHeightPx: UInt32(max(0, attachment.pixelHeight)),
                sendImage: request.sendRegionImage && request.settings.vision
            )
        }
        let record = AiPlanRequestRecord(
            action: request.action.generated,
            currentPage: UInt32(max(0, request.currentPage - 1)),
            selection: selection,
            question: request.question,
            language: request.language,
            history: request.history.map {
                AiConversationTurnRecord(question: $0.question, answer: $0.answer)
            },
            region: region,
            baseUrl: request.settings.baseURL,
            model: request.settings.model,
            temperature: request.settings.temperature,
            maxTokens: request.settings.maxTokens.map { UInt32(max(0, $0)) },
            reasoningMode: request.settings.reasoningMode.rawValue,
            reasoningEncoding: request.settings.reasoningEncoding.rawValue
        )
        return try await engine.prepareAIPlan(record)
    }

    public func prepareMerge(_ request: AIMergePlanRequest) async throws -> AiPlanRecord {
        try buildAiMergePlan(
            request: AiMergePlanRequestRecord(
                documentTitle: request.documentTitle,
                parts: request.parts.map {
                    AiMergePartRecord(
                        index: UInt32(max(0, $0.index)),
                        total: UInt32(max(0, $0.total)),
                        pages: $0.pages.map { UInt32(max(0, $0)) },
                        summary: $0.summary
                    )
                },
                baseUrl: request.settings.baseURL,
                model: request.settings.model,
                temperature: request.settings.temperature,
                maxTokens: request.settings.maxTokens.map { UInt32(max(0, $0)) },
                reasoningMode: request.settings.reasoningMode.rawValue,
                reasoningEncoding: request.settings.reasoningEncoding.rawValue
            )
        )
    }

    public func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle {
        let handle = try startAiRequest(
            plan: plan,
            apiKey: apiKey,
            useMockProvider: useMockProvider
        )
        return RustAIChatHandle(handle: handle)
    }
}

@MainActor
private final class RustAIChatHandle: AIChatHandle {
    private let handle: LyraReaderAiRequest

    init(handle: LyraReaderAiRequest) {
        self.handle = handle
    }

    func poll() -> [AIStreamEvent] {
        handle.poll().map { event in
            switch event {
            case .partStarted(let index, let total, let label):
                return .partStarted(index: Int(index), total: Int(total), label: label)
            case .delta(let text):
                return .delta(text)
            case .reasoningDelta(let text):
                return .reasoningDelta(text)
            case .usage(let promptTokens, let completionTokens, let totalTokens, let reasoningTokens):
                return .usage(AIUsage(
                    promptTokens: promptTokens.map(Int.init),
                    completionTokens: completionTokens.map(Int.init),
                    totalTokens: totalTokens.map(Int.init),
                    reasoningTokens: reasoningTokens.map(Int.init)
                ))
            case .diagnostics(let diagnostics):
                return .diagnostics(AIStreamDiagnostics(
                    httpStatus: Int(diagnostics.httpStatus),
                    bytes: Int(diagnostics.bytes),
                    frames: Int(diagnostics.frames),
                    dataFrames: Int(diagnostics.dataFrames),
                    contentFrames: Int(diagnostics.contentFrames),
                    reasoningFrames: Int(diagnostics.reasoningFrames),
                    roleOnlyFrames: Int(diagnostics.roleOnlyFrames),
                    emptyFrames: Int(diagnostics.emptyFrames),
                    usageFrames: Int(diagnostics.usageFrames),
                    contentShape: diagnostics.contentShape,
                    finishReason: diagnostics.finishReason,
                    usage: AIUsage(
                        promptTokens: diagnostics.promptTokens.map(Int.init),
                        completionTokens: diagnostics.completionTokens.map(Int.init),
                        totalTokens: diagnostics.totalTokens.map(Int.init),
                        reasoningTokens: diagnostics.reasoningTokens.map(Int.init)
                    )
                ))
            case .done:
                return .done
            case .error(let message, let cancelled):
                return .error(message: message, cancelled: cancelled)
            }
        }
    }

    func cancel() {
        handle.cancel()
    }

    var isFinished: Bool {
        handle.isFinished()
    }
}

// MARK: - Settings and Keychain

public enum AIKeyStoreError: LocalizedError, Equatable {
    case keychain(OSStatus)
    case invalidKey

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "The macOS Keychain returned status \(status). The key was not changed."
        case .invalidKey:
            return "The API key contains a line break or control character."
        }
    }
}

/// Credential storage is the one genuinely platform-bound part of the AI feature. Each shell
/// implements these four operations with its own secret store; the request runner, SSE parser,
/// context builder and prompts are shared Rust code.
public protocol AIAPIKeyStore: AnyObject {
    func readKey() throws -> String?
    func saveKey(_ key: String) throws
    func deleteKey() throws
    func hasKey() throws -> Bool
}

/// macOS implementation: a generic password in the login Keychain.
///
/// The key is never written to `UserDefaults`, a file, the pasteboard, or a log line. The service
/// and account are constants so another platform can implement the same small protocol.
public final class KeychainAPIKeyStore: AIAPIKeyStore {
    public static let defaultService = "com.alex.lyrareader.ai"
    public static let defaultAccount = "openai-compatible-api-key"

    private let service: String
    private let account: String
    private let legacyService: String?

    public init(
        service: String = KeychainAPIKeyStore.defaultService,
        account: String = KeychainAPIKeyStore.defaultAccount,
        legacyService: String? = nil
    ) {
        self.service = service
        self.account = account
        self.legacyService = legacyService
            ?? (service == Self.defaultService ? "com.alex.lyra.ai" : nil)
    }

    private func baseQuery(service: String? = nil) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service ?? self.service,
            kSecAttrAccount as String: account,
        ]
    }

    private var readServices: [String] {
        [service] + (legacyService.flatMap { $0 == service ? nil : [$0] } ?? [])
    }

    public func hasKey() throws -> Bool {
        for service in readServices {
            var query = baseQuery(service: service)
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let status = SecItemCopyMatching(query as CFDictionary, nil)
            if status == errSecSuccess { return true }
            guard status == errSecItemNotFound else { throw AIKeyStoreError.keychain(status) }
        }
        return false
    }

    public func readKey() throws -> String? {
        for service in readServices {
            var query = baseQuery(service: service)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess else { throw AIKeyStoreError.keychain(status) }
            guard let data = result as? Data,
                  let key = String(data: data, encoding: .utf8), !key.isEmpty else {
                throw AIKeyStoreError.invalidKey
            }
            return key
        }
        return nil
    }

    public func saveKey(_ key: String) throws {
        guard !key.isEmpty,
              !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw AIKeyStoreError.invalidKey
        }
        let query = baseQuery()
        let attributes = [kSecValueData as String: Data(key.utf8)]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw AIKeyStoreError.keychain(updated) }
        var newItem = query
        newItem[kSecValueData as String] = Data(key.utf8)
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(newItem as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AIKeyStoreError.keychain(status)
        }
    }

    public func deleteKey() throws {
        // Remove the fallback first; a failed deletion must never resurrect a signed-out token.
        for service in readServices.reversed() {
            let status = SecItemDelete(baseQuery(service: service) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AIKeyStoreError.keychain(status)
            }
        }
    }
}

/// Test/preview store. Deliberately not persistent and clearly named: it must never be the
/// default for the app.
public final class InMemoryAPIKeyStore: AIAPIKeyStore {
    private var stored: String?

    public init(key: String? = nil) {
        self.stored = key
    }

    public var key: String? { stored }

    public func readKey() throws -> String? { stored }
    public func saveKey(_ key: String) throws { stored = key }
    public func deleteKey() throws { stored = nil }
    public func hasKey() throws -> Bool { stored?.isEmpty == false }
}

public enum AISettingsError: LocalizedError, Equatable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

/// The settings the panel and the Settings window share. Secrets go to `keyStore`; everything
/// else is a non-secret preference in `UserDefaults`.
@MainActor
public final class AISettingsStore: ObservableObject {
    public static let baseURLKey = "aiBaseURL"
    public static let modelKey = "aiModel"
    public static let temperatureKey = "aiTemperature"
    public static let maxTokensKey = "aiMaxTokens"
    public static let reasoningModeKey = "aiReasoningMode"
    public static let reasoningEncodingKey = "aiReasoningEncoding"
    public static let modelAcceptsImagesKey = "aiModelAcceptsImages"

    public static let defaultBaseURL = "https://api.openai.com/v1"
    public static let defaultModel = "gpt-4o-mini"
    public static let defaultTemperature = 0.2
    public static let defaultMaxTokens = 900
    public static let defaultReasoningMode = AIReasoningMode.off
    public static let defaultReasoningEncoding = AIReasoningEncoding.thinking
    public static let defaultModelAcceptsImages = false
    public static let temperatureRange = 0.0...2.0
    public static let maxTokensRange = 1...32_768

    public static let shared = AISettingsStore()

    @Published public private(set) var baseURL: String
    @Published public private(set) var model: String
    @Published public private(set) var temperature: Double
    @Published public private(set) var maxTokens: Int
    @Published public private(set) var reasoningMode: AIReasoningMode
    @Published public private(set) var reasoningEncoding: AIReasoningEncoding
    /// The reader's statement that this model accepts image input. It is not guessed from the
    /// model name: a wrong guess would either leak a picture to a text-only model or silently
    /// drop the picture the reader asked about.
    @Published public private(set) var modelAcceptsImages: Bool
    @Published public private(set) var hasKey: Bool
    @Published public var connectionMode: AIConnectionMode {
        didSet { defaults.set(connectionMode.rawValue, forKey: "aiConnectionMode") }
    }
    public let chatGPT: ChatGPTAccountStore
    public var canUseAI: Bool { connectionMode == .chatGPT ? chatGPT.isConnected : hasKey }
    @Published public private(set) var invalidSettingsMessage: String?
    /// The validated endpoint for the current base URL, from the Rust validator.
    @Published public private(set) var endpointInfo: AiEndpointRecord?

    public let keyStore: any AIAPIKeyStore
    public let defaults: UserDefaults

    public init(
        defaults: UserDefaults = .standard,
        keyStore: any AIAPIKeyStore = KeychainAPIKeyStore(),
        chatGPT: ChatGPTAccountStore? = nil
    ) {
        self.chatGPT = chatGPT ?? ChatGPTAccountStore(defaults: defaults)
        self.connectionMode = defaults.string(forKey: "aiConnectionMode").flatMap(AIConnectionMode.init(rawValue:)) ?? .apiKey
        self.defaults = defaults
        self.keyStore = keyStore
        self.baseURL = defaults.string(forKey: Self.baseURLKey) ?? Self.defaultBaseURL
        self.model = defaults.string(forKey: Self.modelKey) ?? Self.defaultModel
        self.temperature = defaults.object(forKey: Self.temperatureKey) == nil
            ? Self.defaultTemperature
            : defaults.double(forKey: Self.temperatureKey)
        self.maxTokens = defaults.object(forKey: Self.maxTokensKey) == nil
            ? Self.defaultMaxTokens
            : defaults.integer(forKey: Self.maxTokensKey)
        self.reasoningMode = defaults.string(forKey: Self.reasoningModeKey)
            .flatMap(AIReasoningMode.init(rawValue:)) ?? Self.defaultReasoningMode
        self.reasoningEncoding = defaults.string(forKey: Self.reasoningEncodingKey)
            .flatMap(AIReasoningEncoding.init(rawValue:)) ?? Self.defaultReasoningEncoding
        self.modelAcceptsImages = defaults.object(forKey: Self.modelAcceptsImagesKey) == nil
            ? Self.defaultModelAcceptsImages
            : defaults.bool(forKey: Self.modelAcceptsImagesKey)
        self.hasKey = (try? keyStore.hasKey()) ?? false
        self.endpointInfo = try? inspectAiBaseUrl(baseUrl: self.baseURL)
        self.invalidSettingsMessage = Self.validateBaseAndModel(
            baseURL: self.baseURL,
            model: self.model
        ).errorMessage ?? Self.reasoningValidationMessage(
            mode: self.reasoningMode,
            encoding: self.reasoningEncoding
        )
    }

    /// Validate and persist. A non-nil, non-empty `apiKey` replaces the stored key; an empty value
    /// leaves the existing key alone (use `clearKey` to remove it).
    @discardableResult
    public func save(
        baseURL rawBaseURL: String,
        model rawModel: String,
        temperature: Double,
        maxTokens: Int,
        apiKey: String?,
        reasoningMode: AIReasoningMode = .off,
        reasoningEncoding: AIReasoningEncoding = .thinking,
        modelAcceptsImages: Bool = false
    ) -> Bool {
        invalidSettingsMessage = nil
        let endpoint: AiEndpointRecord
        let model: String
        do {
            endpoint = try inspectAiBaseUrl(baseUrl: rawBaseURL)
            model = try validateAiModel(model: rawModel)
        } catch {
            invalidSettingsMessage = AIReadableError.message(error)
            return false
        }
        guard temperature.isFinite, Self.temperatureRange.contains(temperature) else {
            invalidSettingsMessage = "Temperature must be between 0 and 2."
            return false
        }
        guard Self.maxTokensRange.contains(maxTokens) else {
            invalidSettingsMessage = "Max tokens must be between 1 and 32,768."
            return false
        }
        if let message = Self.reasoningValidationMessage(mode: reasoningMode, encoding: reasoningEncoding) {
            invalidSettingsMessage = message
            return false
        }

        if let apiKey {
            let candidate = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                guard !candidate.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                }) else {
                    invalidSettingsMessage = "The API key contains a line break or control character."
                    return false
                }
                do {
                    try keyStore.saveKey(candidate)
                } catch {
                    invalidSettingsMessage = AIReadableError.message(error)
                    return false
                }
            }
        }

        defaults.set(endpoint.baseUrl, forKey: Self.baseURLKey)
        defaults.set(model, forKey: Self.modelKey)
        defaults.set(temperature, forKey: Self.temperatureKey)
        defaults.set(maxTokens, forKey: Self.maxTokensKey)
        defaults.set(reasoningMode.rawValue, forKey: Self.reasoningModeKey)
        defaults.set(reasoningEncoding.rawValue, forKey: Self.reasoningEncodingKey)
        defaults.set(modelAcceptsImages, forKey: Self.modelAcceptsImagesKey)
        baseURL = endpoint.baseUrl
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.reasoningMode = reasoningMode
        self.reasoningEncoding = reasoningEncoding
        self.modelAcceptsImages = modelAcceptsImages
        endpointInfo = endpoint
        hasKey = (try? keyStore.hasKey()) ?? false
        return true
    }

    @discardableResult
    public func clearKey() -> Bool {
        do {
            try keyStore.deleteKey()
            hasKey = false
            invalidSettingsMessage = nil
            return true
        } catch {
            invalidSettingsMessage = AIReadableError.message(error)
            return false
        }
    }

    /// Read the key only when a request is about to start. Callers must not retain it.
    public func readKey() throws -> String? {
        guard let key = try keyStore.readKey(), !key.isEmpty else { return nil }
        return key
    }

    /// The validated settings the request builder receives. Throws a reader-facing message when the
    /// stored values are no longer usable.
    public func providerSettings() throws -> AIProviderSettings {
        if connectionMode == .chatGPT {
            guard let account = chatGPT.selected, account.connected, !account.model.isEmpty else {
                throw AISettingsError.invalid("Connect ChatGPT and select a model in Settings > AI first.")
            }
            return AIProviderSettings(baseURL: "https://api.openai.com/v1", model: account.model,
                                      temperature: nil, maxTokens: nil,
                                      reasoningMode: .providerDefault, reasoningEncoding: .none,
                                      vision: true)
        }
        let endpoint = try inspectAiBaseUrl(baseUrl: baseURL)
        let model = try validateAiModel(model: model)
        guard temperature.isFinite, Self.temperatureRange.contains(temperature) else {
            throw AISettingsError.invalid("Temperature must be between 0 and 2.")
        }
        guard Self.maxTokensRange.contains(maxTokens) else {
            throw AISettingsError.invalid("Max tokens must be between 1 and 32,768.")
        }
        if let message = Self.reasoningValidationMessage(mode: reasoningMode, encoding: reasoningEncoding) {
            throw AISettingsError.invalid(message)
        }
        return AIProviderSettings(
            baseURL: endpoint.baseUrl,
            model: model,
            temperature: temperature,
            maxTokens: maxTokens,
            reasoningMode: reasoningMode,
            reasoningEncoding: reasoningEncoding,
            vision: modelAcceptsImages
        )
    }

    public var isLocalEndpoint: Bool {
        endpointInfo?.isLocal ?? false
    }

    public var reasoningSummary: String {
        AIProviderSettings(
            baseURL: baseURL,
            model: model,
            temperature: temperature,
            maxTokens: maxTokens,
            reasoningMode: reasoningMode,
            reasoningEncoding: reasoningEncoding
        ).reasoningSummary
    }

    public var reasoningFieldDescription: String {
        AIProviderSettings(
            baseURL: baseURL,
            model: model,
            temperature: temperature,
            maxTokens: maxTokens,
            reasoningMode: reasoningMode,
            reasoningEncoding: reasoningEncoding
        ).reasoningFieldDescription
    }

    /// The provider's extension table has no single "off"/intensity field; reject combinations
    /// that would silently send nothing or something different from the label.
    public static func reasoningValidationMessage(
        mode: AIReasoningMode,
        encoding: AIReasoningEncoding
    ) -> String? {
        if mode == .providerDefault { return nil }
        if encoding == .none {
            return "Choose a reasoning encoding, or set reasoning to provider default to send no reasoning field."
        }
        if mode == .off {
            if encoding == .thinking || encoding == .reasoning { return nil }
            return "That encoding has no documented off value. Use thinking or reasoning.effort for off, or choose provider default."
        }
        if encoding == .reasoningEffort || encoding == .outputConfig || encoding == .reasoning {
            return nil
        }
        return "The thinking encoding is a toggle: use off or provider default with it. For low, high or max choose reasoning_effort, output_config, or reasoning.effort."
    }

    private static func validateBaseAndModel(
        baseURL: String,
        model: String
    ) -> Result<Void, AISettingsError> {
        do {
            _ = try inspectAiBaseUrl(baseUrl: baseURL)
            _ = try validateAiModel(model: model)
            return .success(())
        } catch {
            return .failure(.invalid(AIReadableError.message(error)))
        }
    }
}

extension Result where Success == Void, Failure == AISettingsError {
    var errorMessage: String? {
        if case .failure(let error) = self { return error.errorDescription }
        return nil
    }
}

/// Pull a reader-facing string out of a UniFFI-generated error. The generated error enum's
/// `localizedDescription` is `String(reflecting:)` (`Ai(message: "...")`), which is not something
/// to show in a panel, so the associated message is read structurally instead.
public enum AIReadableError {
    public static func message(_ error: Error) -> String {
        // The generated UniFFI error enum carries its message as the single associated String.
        // `Mirror` reads it without depending on the generated case name or its reflection
        // formatting ("LyraReaderBindings.LyraReaderFfiError.Ai(message: ...)").
        let mirror = Mirror(reflecting: error)
        for child in mirror.children {
            if let text = child.value as? String, !text.isEmpty {
                return text
            }
            // A generated enum case with one associated value reflects as a tuple such as
            // `(message: "...")`, so look one level deeper for the labelled message.
            let nested = Mirror(reflecting: child.value)
            for associated in nested.children where associated.label == "message" {
                if let text = associated.value as? String, !text.isEmpty {
                    return text
                }
            }
        }
        if let localized = (error as? LocalizedError)?.errorDescription,
           !localized.isEmpty {
            return localized
        }
        return error.localizedDescription
    }
}

// MARK: - Reader wiring

extension AppState {
    /// The local context shown in a request preview and used to detect document switches.
    public var aiReaderContext: AIReaderContext? {
        guard let document else { return nil }
        let selection: AIReaderSelection? = selection.map {
            AIReaderSelection(
                page: $0.page + 1,
                start: $0.range.lowerBound,
                end: $0.range.upperBound
            )
        }
        return AIReaderContext(
            documentKey: document.url?.standardizedFileURL.path ?? document.id.uuidString,
            documentTitle: document.title,
            pageCount: document.pageCount,
            currentPage: currentPage,
            selection: selection
        )
    }

    /// A service backed by the real Rust engine. Nil when the fallback mock engine is active: the
    /// AI feature is honest about needing the Rust core instead of faking an answer.
    public var aiChatService: (any AIChatServicing)? {
        guard let engine = engine as? RustEngine else { return nil }
        return RustAIChatService(engine: engine)
    }
}

// MARK: - Plan formatting

extension AiPlanRecord {
    /// Compact 1-based page list for the preview header.
    public var sourcePageLabel: String {
        AIPlanFormatting.pageLabel(sourcePages.map(Int.init))
    }

    public var isMultiPart: Bool { parts.count > 1 }

    public var isDocumentChat: Bool { action == .documentChat }

    /// The passages that were sent, in the same form the chips and highlight use.
    public var chatSources: [AIChatSource] {
        sources.map(AIChatSource.init(record:))
    }
}

extension AiPlanPartRecord {
    public var pagesLabel: String {
        AIPlanFormatting.pageLabel(pages.map(Int.init))
    }

    public var characterLabel: String {
        "\(pageCharacters) page characters · \(requestCharacters) request characters"
    }
}

public enum AIPlanFormatting {
    /// "Page 3", "Pages 1-3", "Pages 1, 3, 5" for 1-based pages.
    public static func pageLabel(_ pages: [Int]) -> String {
        let pages = Array(Set(pages)).sorted()
        guard let first = pages.first else { return "No pages" }
        if pages.count == 1 { return "Page \(first)" }
        let contiguous = zip(pages, pages.dropFirst()).allSatisfy { $0 + 1 == $1 }
        if contiguous {
            return "Pages \(first)-\(pages.last!)"
        }
        return "Pages " + pages.map(String.init).joined(separator: ", ")
    }
}
