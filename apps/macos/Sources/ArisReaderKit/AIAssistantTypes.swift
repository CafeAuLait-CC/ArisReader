import ArisReaderBindings
import Combine
import Foundation
import Security

// MARK: - Actions and request inputs

/// The four actions the AI panel can request. Deliberately small: no free-form document chat yet.
public enum AIAssistantAction: String, CaseIterable, Identifiable, Sendable {
    case summarizePage
    case summarizeDocument
    case askSelection
    case translateSelection

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .summarizePage: return "Summarise page"
        case .summarizeDocument: return "Summarise document"
        case .askSelection: return "Ask selection"
        case .translateSelection: return "Translate selection"
        }
    }

    public var systemImage: String {
        switch self {
        case .summarizePage: return "doc.text"
        case .summarizeDocument: return "doc.on.doc"
        case .askSelection: return "questionmark.bubble"
        case .translateSelection: return "character.bubble"
        }
    }

    /// The Rust action this maps to.
    var generated: AiActionRecord {
        switch self {
        case .summarizePage: return .summarizePage
        case .summarizeDocument: return .summarizeDocument
        case .askSelection: return .askSelection
        case .translateSelection: return .translateSelection
        }
    }

    /// Whether the panel must have a live selection before offering the action.
    public var requiresSelection: Bool {
        self == .askSelection || self == .translateSelection
    }
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

/// Provider settings that are not secret. The key is deliberately not part of this value.
public struct AIProviderSettings: Equatable, Sendable {
    public var baseURL: String
    public var model: String
    public var temperature: Double?
    public var maxTokens: Int?

    public init(baseURL: String, model: String, temperature: Double?, maxTokens: Int?) {
        self.baseURL = baseURL
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

/// A preview request: exactly what the panel needs to ask Rust for a plan. No key.
public struct AIMakePlanRequest: Sendable {
    public let action: AIAssistantAction
    public let currentPage: Int
    public let selection: AIReaderSelection?
    public let question: String?
    public let language: String?
    public let settings: AIProviderSettings

    public init(
        action: AIAssistantAction,
        currentPage: Int,
        selection: AIReaderSelection?,
        question: String?,
        language: String?,
        settings: AIProviderSettings
    ) {
        self.action = action
        self.currentPage = currentPage
        self.selection = selection
        self.question = question
        self.language = language
        self.settings = settings
    }
}

// MARK: - Usage and stream events

public struct AIUsage: Equatable, Sendable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?

    public init(promptTokens: Int? = nil, completionTokens: Int? = nil, totalTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }

    public var isEmpty: Bool {
        promptTokens == nil && completionTokens == nil && totalTokens == nil
    }

    /// Sums the token counts reported by the parts of one plan.
    public func merged(with other: AIUsage) -> AIUsage {
        AIUsage(
            promptTokens: Self.add(promptTokens, other.promptTokens),
            completionTokens: Self.add(completionTokens, other.completionTokens),
            totalTokens: Self.add(totalTokens, other.totalTokens)
        )
    }

    /// A line for the panel. Only what the provider actually reported is shown.
    public var summary: String {
        var pieces: [String] = []
        if let promptTokens { pieces.append("\(promptTokens) prompt") }
        if let completionTokens { pieces.append("\(completionTokens) completion") }
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

public enum AIStreamEvent: Equatable, Sendable {
    case partStarted(index: Int, total: Int, label: String)
    case delta(String)
    case usage(AIUsage)
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
    func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle
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
        let record = AiPlanRequestRecord(
            action: request.action.generated,
            currentPage: UInt32(max(0, request.currentPage - 1)),
            selection: selection,
            question: request.question,
            language: request.language,
            baseUrl: request.settings.baseURL,
            model: request.settings.model,
            temperature: request.settings.temperature,
            maxTokens: request.settings.maxTokens.map { UInt32(max(0, $0)) }
        )
        return try await engine.prepareAIPlan(record)
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
    private let handle: ArisAiRequest

    init(handle: ArisAiRequest) {
        self.handle = handle
    }

    func poll() -> [AIStreamEvent] {
        handle.poll().map { event in
            switch event {
            case .partStarted(let index, let total, let label):
                return .partStarted(index: Int(index), total: Int(total), label: label)
            case .delta(let text):
                return .delta(text)
            case .usage(let promptTokens, let completionTokens, let totalTokens):
                return .usage(AIUsage(
                    promptTokens: promptTokens.map(Int.init),
                    completionTokens: completionTokens.map(Int.init),
                    totalTokens: totalTokens.map(Int.init)
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
    public static let defaultService = "com.alex.lyra.ai"
    public static let defaultAccount = "openai-compatible-api-key"

    private let service: String
    private let account: String

    public init(
        service: String = KeychainAPIKeyStore.defaultService,
        account: String = KeychainAPIKeyStore.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func hasKey() throws -> Bool {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw AIKeyStoreError.keychain(status)
        }
    }

    public func readKey() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecItemNotFound:
            return nil
        case errSecSuccess:
            guard let data = result as? Data,
                  let key = String(data: data, encoding: .utf8),
                  !key.isEmpty else {
                throw AIKeyStoreError.invalidKey
            }
            return key
        default:
            throw AIKeyStoreError.keychain(status)
        }
    }

    public func saveKey(_ key: String) throws {
        guard !key.isEmpty,
              !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw AIKeyStoreError.invalidKey
        }
        // Delete first rather than update: an update query has to match every attribute, and a
        // missing item must become a create rather than a silently dropped save.
        try? deleteKey()
        var query = baseQuery()
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AIKeyStoreError.keychain(status)
        }
    }

    public func deleteKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIKeyStoreError.keychain(status)
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

    public static let defaultBaseURL = "https://api.openai.com/v1"
    public static let defaultModel = "gpt-4o-mini"
    public static let defaultTemperature = 0.2
    public static let defaultMaxTokens = 900
    public static let temperatureRange = 0.0...2.0
    public static let maxTokensRange = 1...32_768

    public static let shared = AISettingsStore()

    @Published public private(set) var baseURL: String
    @Published public private(set) var model: String
    @Published public private(set) var temperature: Double
    @Published public private(set) var maxTokens: Int
    @Published public private(set) var hasKey: Bool
    @Published public private(set) var invalidSettingsMessage: String?
    /// The validated endpoint for the current base URL, from the Rust validator.
    @Published public private(set) var endpointInfo: AiEndpointRecord?

    public let keyStore: any AIAPIKeyStore
    public let defaults: UserDefaults

    public init(
        defaults: UserDefaults = .standard,
        keyStore: any AIAPIKeyStore = KeychainAPIKeyStore()
    ) {
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
        self.hasKey = (try? keyStore.hasKey()) ?? false
        self.endpointInfo = try? inspectAiBaseUrl(baseUrl: self.baseURL)
        self.invalidSettingsMessage = Self.validateBaseAndModel(
            baseURL: self.baseURL,
            model: self.model
        ).errorMessage
    }

    /// Validate and persist. A non-nil, non-empty `apiKey` replaces the stored key; an empty value
    /// leaves the existing key alone (use `clearKey` to remove it).
    @discardableResult
    public func save(
        baseURL rawBaseURL: String,
        model rawModel: String,
        temperature: Double,
        maxTokens: Int,
        apiKey: String?
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
        baseURL = endpoint.baseUrl
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
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
        let endpoint = try inspectAiBaseUrl(baseUrl: baseURL)
        let model = try validateAiModel(model: model)
        guard temperature.isFinite, Self.temperatureRange.contains(temperature) else {
            throw AISettingsError.invalid("Temperature must be between 0 and 2.")
        }
        guard Self.maxTokensRange.contains(maxTokens) else {
            throw AISettingsError.invalid("Max tokens must be between 1 and 32,768.")
        }
        return AIProviderSettings(
            baseURL: endpoint.baseUrl,
            model: model,
            temperature: temperature,
            maxTokens: maxTokens
        )
    }

    public var isLocalEndpoint: Bool {
        endpointInfo?.isLocal ?? false
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
        // formatting ("ArisReaderBindings.ArisFfiError.Ai(message: ...)").
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
