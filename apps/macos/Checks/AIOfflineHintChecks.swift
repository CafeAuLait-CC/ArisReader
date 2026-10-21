import Foundation
import LyraReaderKit
import LyraReaderBindings

// Offline-hint checks. Every request in this file uses a scripted stub handle: no check opens a
// socket, and the Rust planner only reads the committed fixture locally. The transport failure
// categories exercised here are the same fixed categories `AiFailureRecord` carries, so the panel
// path is tested without a real network.

@MainActor
private final class OfflineStubHandle: AIChatHandle {
    private var events: [AIStreamEvent]
    private var finished = false

    init(events: [AIStreamEvent]) {
        self.events = events
    }

    func poll() -> [AIStreamEvent] {
        let pending = events
        events = []
        if pending.contains(where: { event in
            switch event {
            case .done, .error: return true
            default: return false
            }
        }) {
            finished = true
        }
        return pending
    }

    func cancel() {
        events = []
        finished = true
    }

    var isFinished: Bool { finished }
}

/// Uses the production Rust planner so the preview is the real one, then scripts the transport.
/// `answering` is the stub "the network came back" switch the retry check flips.
@MainActor
private final class OfflineStubService: AIChatServicing {
    let base: RustAIChatService
    private let failure: AIStreamEvent
    private let success: [AIStreamEvent]
    private(set) var startCount = 0
    var answering = false

    init(engine: RustEngine, failure: AIStreamEvent) {
        self.base = RustAIChatService(engine: engine, useMockProvider: true)
        self.failure = failure
        self.success = [
            .partStarted(index: 0, total: 1, label: "Summary"),
            .delta("A stub answer after the network returned."),
            .done,
        ]
    }

    func prepare(_ request: AIMakePlanRequest) async throws -> AiPlanRecord {
        try await base.prepare(request)
    }

    func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle {
        startCount += 1
        if answering {
            return OfflineStubHandle(events: success)
        }
        return OfflineStubHandle(events: [
            .partStarted(index: 0, total: 1, label: plan.parts.first?.label ?? "Summary"),
            failure,
        ])
    }
}

private struct OfflineSettingsFixture {
    let suiteName: String
    let defaults: UserDefaults
    let keyStore: InMemoryAPIKeyStore
    let store: AISettingsStore

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

extension ReaderChecks {
    /// The five offline-hint checks requested for this change. They fail without the shared
    /// transport category, the hint copy/control and the fixed audit code.
    @MainActor
    static func offlineHintChecks(root: URL) async throws {
        try await offlineHintShowsForNoNetwork(root: root)
        try await localServerFailureUsesItsOwnSentence(root: root)
        try await retryAfterTheHintSucceeds(root: root)
        try await httpErrorsKeepTheirOwnDisplay(root: root)
        try await offlineAuditRecordHasTheFixedCode(root: root)
        settingsRouteOpensTheAIBaseURLField()
    }

    @MainActor
    private static func offlineSettings(
        baseURL: String,
        key: String
    ) throws -> OfflineSettingsFixture {
        let suiteName = "lyra-reader-offline-checks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let keyStore = InMemoryAPIKeyStore(key: key)
        let store = AISettingsStore(defaults: defaults, keyStore: keyStore)
        guard store.save(
            baseURL: baseURL,
            model: "offline-check-model",
            temperature: 0.2,
            maxTokens: 900,
            apiKey: key
        ) else {
            fatalError("FAIL: the offline-check provider settings did not save")
        }
        return OfflineSettingsFixture(
            suiteName: suiteName,
            defaults: defaults,
            keyStore: keyStore,
            store: store
        )
    }

    @MainActor
    private static func offlineContext(root: URL) throws -> (RustEngine, AIReaderContext) {
        let fixtureURL = root.appendingPathComponent("tests/fixtures/multipage.pdf")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            fatalError("FAIL: the multipage fixture is missing")
        }
        let engine = try RustEngine()
        let document = try engine.openDocument(at: fixtureURL)
        return (
            engine,
            AIReaderContext(
                documentKey: fixtureURL.standardizedFileURL.path,
                documentTitle: document.title,
                pageCount: document.pageCount,
                currentPage: 1,
                selection: nil
            )
        )
    }

    @MainActor
    private static func waitForFailure(_ model: AIAssistantModel) async throws {
        try await eventually("the scripted transport failure reaches the panel", {
            model.phase == .failed
        })
    }

    @MainActor
    private static func offlineHintShowsForNoNetwork(root: URL) async throws {
        let (engine, context) = try offlineContext(root: root)
        let fixture = try offlineSettings(baseURL: "https://api.example.com/v1",
                                          key: "sk-offline-check")
        defer { fixture.cleanup() }
        let audit = AIAuditTrail(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-offline-hint-\(UUID())"))
        let stub = OfflineStubService(
            engine: engine,
            failure: .error(
                message: "provider unreachable: no network route: No route to host",
                cancelled: false,
                failure: .offline
            )
        )
        let model = AIAssistantModel(settings: fixture.store, audit: audit)
        model.attach(service: stub, context: context)
        await model.prepare(action: .summarizePage, context: context)
        try await eventually("the no-network preview is ready", { model.phase == .preview })
        model.send()
        try await waitForFailure(model)

        require(model.errorMessage != nil, "the raw transport error is still shown beside the hint")
        guard let hint = model.offlineHint else {
            fatalError("FAIL: a network-unreachable transport error shows the offline hint")
        }
        require(hint.kind == .noNetwork, "the no-network failure uses the no-network hint")
        require(hint.sentence == AIOfflineHint.noNetworkSentence,
                "the hint says the request did not go out because this Mac has no network connection")
        require(hint.advice == AIOfflineHint.localModelSentence,
                "the hint says a local model can be used offline")
        require(hint.controlTitle == AIOfflineHint.controlTitle,
                "the hint carries a control that opens the AI base-URL setting")
        require(model.canRetry, "the failed answer cell stays retryable")
        print("PASS: a network-unreachable error shows the offline hint with the settings control")
    }

    @MainActor
    private static func localServerFailureUsesItsOwnSentence(root: URL) async throws {
        let (engine, context) = try offlineContext(root: root)
        let fixture = try offlineSettings(baseURL: "http://127.0.0.1:11434/v1",
                                          key: "sk-offline-check")
        defer { fixture.cleanup() }
        let stub = OfflineStubService(
            engine: engine,
            failure: .error(
                message: "provider unreachable: the local server did not accept the connection: Connection refused",
                cancelled: false,
                failure: .localServer
            )
        )
        let model = AIAssistantModel(settings: fixture.store)
        model.attach(service: stub, context: context)
        await model.prepare(action: .summarizePage, context: context)
        try await eventually("the local-server preview is ready", { model.phase == .preview })
        model.send()
        try await waitForFailure(model)

        guard let hint = model.offlineHint else {
            fatalError("FAIL: a refused localhost connection shows the local-server hint")
        }
        require(hint.kind == .localServer, "a refused localhost connection is not a no-network hint")
        require(hint.sentence == AIOfflineHint.localServerSentence,
                "the local-server hint says the local AI server is not running")
        require(hint.sentence != AIOfflineHint.noNetworkSentence,
                "a local connection failure never claims this Mac has no network")
        require(hint.advice == AIOfflineHint.localServerAdvice,
                "the local-server hint says to start the server and retry")
        require(hint.controlTitle == AIOfflineHint.controlTitle,
                "the local-server hint keeps the settings control")
        print("PASS: a refused connection to a localhost endpoint shows the local-server sentence")
    }

    @MainActor
    private static func retryAfterTheHintSucceeds(root: URL) async throws {
        let (engine, context) = try offlineContext(root: root)
        let fixture = try offlineSettings(baseURL: "https://api.example.com/v1",
                                          key: "sk-offline-check")
        defer { fixture.cleanup() }
        let stub = OfflineStubService(
            engine: engine,
            failure: .error(
                message: "provider unreachable: no network route",
                cancelled: false,
                failure: .offline
            )
        )
        let model = AIAssistantModel(settings: fixture.store)
        model.attach(service: stub, context: context)
        await model.prepare(action: .summarizePage, context: context)
        try await eventually("the retry preview is ready", { model.phase == .preview })
        model.send()
        try await waitForFailure(model)
        require(model.offlineHint != nil, "the initial failure shows the hint before retry")
        let startsBeforeRetry = stub.startCount

        stub.answering = true
        model.retry()
        try await eventually("Retry re-sends the same preview and finishes", {
            model.phase == .finished && !model.answer.isEmpty
        })
        require(stub.startCount == startsBeforeRetry + 1,
                "Retry re-sends one request after the stub starts answering")
        require(model.answer.contains("A stub answer after the network returned."),
                "Retry shows the answer that arrives once the network is back")
        require(model.offlineHint == nil, "the hint disappears after the retried request succeeds")
        print("PASS: Retry after the hint succeeds when the stub starts answering")
    }

    @MainActor
    private static func httpErrorsKeepTheirOwnDisplay(root: URL) async throws {
        let (engine, context) = try offlineContext(root: root)
        let cases: [(String, String)] = [
            ("HTTP 401", "Authentication failed (HTTP 401 Unauthorized). Check the API key in Settings > AI."),
            ("HTTP 429", "The provider is rate limiting this key (HTTP 429 Too Many Requests). Wait a moment and try again."),
            ("HTTP 500", "The provider failed (HTTP 500 Internal Server Error)."),
        ]
        for (label, message) in cases {
            let fixture = try offlineSettings(baseURL: "https://api.example.com/v1",
                                              key: "sk-offline-check")
            defer { fixture.cleanup() }
            let stub = OfflineStubService(
                engine: engine,
                failure: .error(message: message, cancelled: false, failure: .other)
            )
            let model = AIAssistantModel(settings: fixture.store)
            model.attach(service: stub, context: context)
            await model.prepare(action: .summarizePage, context: context)
            try await eventually("the \(label) preview is ready", { model.phase == .preview })
            model.send()
            try await waitForFailure(model)
            require(model.offlineHint == nil,
                    "an \(label) error keeps its own display and shows no offline hint")
            require((model.errorMessage ?? "").contains(label),
                    "the \(label) error text is unchanged")
        }
        print("PASS: the hint does not appear for an HTTP 401, 429 or 500")
    }

    @MainActor
    private static func offlineAuditRecordHasTheFixedCode(root: URL) async throws {
        let (engine, context) = try offlineContext(root: root)
        let fixture = try offlineSettings(baseURL: "https://api.example.com/v1",
                                          key: "sk-offline-check")
        defer { fixture.cleanup() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-offline-audit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audit = AIAuditTrail(directory: directory)
        let stub = OfflineStubService(
            engine: engine,
            failure: .error(
                message: "provider unreachable: no network route: No route to host",
                cancelled: false,
                failure: .offline
            )
        )
        let model = AIAssistantModel(settings: fixture.store, audit: audit)
        model.attach(service: stub, context: context)
        await model.prepare(action: .summarizePage, context: context)
        try await eventually("the audited preview is ready", { model.phase == .preview })
        model.send()
        try await waitForFailure(model)
        try await eventually("the offline failure is recorded", { audit.records.count == 1 })
        guard let record = audit.records.first else {
            fatalError("FAIL: the offline failure produced an audit record")
        }
        require(record.code == .offline, "the offline failure records the fixed code `offline`")
        require(record.outcome == .failed, "the offline record is a failed attempt")
        require(record.characters > 0, "the record keeps counts only, not the request text")
        let contents = (try? String(contentsOf: audit.fileURL, encoding: .utf8)) ?? ""
        require(!contents.contains("No route to host"),
                "the audit file never stores the transport message")
        require(!contents.contains("\"message\""), "the audit record has no message field")
        require(!contents.contains("\"error\""), "the audit record has no error field")
        print("PASS: the audit record for the offline failure has the fixed code and no content")
    }

    @MainActor
    private static func settingsRouteOpensTheAIBaseURLField() {
        let route = AISettingsRoute()
        route.selectedTab = .performance
        route.revealBaseURL()
        require(route.selectedTab == .ai, "the hint's control selects the AI settings tab")
        require(route.pendingBaseURLFocus, "the hint's control asks the base-URL field to focus")
        route.consumeBaseURLFocus()
        require(!route.pendingBaseURLFocus, "the focus request is consumed once, not repeated")
        print("PASS: the hint's control opens AI settings at the base-URL field")
    }
}
