import ArisReaderBindings
import ArisReaderKit
import Darwin
import Foundation

// AI checks run with the Rust mock provider. There is no network call anywhere in this file:
// `prepare` only reads the fixture's text layer locally, and `start` uses MockProvider::preset.

@MainActor
private final class RecordingAIService: AIChatServicing {
    let base: RustAIChatService
    private(set) var preparedRequests: [AIMakePlanRequest] = []
    private(set) var returnedPlans: [AiPlanRecord] = []
    private(set) var startedPlans: [AiPlanRecord] = []

    init(base: RustAIChatService) {
        self.base = base
    }

    func prepare(_ request: AIMakePlanRequest) async throws -> AiPlanRecord {
        preparedRequests.append(request)
        let plan = try await base.prepare(request)
        returnedPlans.append(plan)
        return plan
    }

    func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle {
        startedPlans.append(plan)
        return try base.start(plan, apiKey: apiKey)
    }
}

private struct AISettingsFixture {
    let suiteName: String
    let defaults: UserDefaults
    let keyStore: InMemoryAPIKeyStore
    let store: AISettingsStore

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

extension ReaderChecks {
    /// Settings validation, Keychain hygiene, citation rendering and the panel state machine.
    @MainActor
    static func aiAssistantChecks(root: URL) async throws {
        try aiSettingsChecks()
        try aiKeyHygieneChecks()
        try aiCitationChecks()
        try aiKeychainRoundTripCheck()
        try await aiPanelChecks(root: root)
    }

    @MainActor
    private static func makeSettings(key: String?) -> AISettingsFixture {
        let suiteName = "aris-ai-checks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let keyStore = InMemoryAPIKeyStore(key: key)
        let store = AISettingsStore(defaults: defaults, keyStore: keyStore)
        return AISettingsFixture(
            suiteName: suiteName,
            defaults: defaults,
            keyStore: keyStore,
            store: store
        )
    }

    @MainActor
    private static func aiSettingsChecks() throws {
        let fixture = makeSettings(key: nil)
        defer { fixture.cleanup() }
        let store = fixture.store
        let key = "sk-check-not-real-\(UUID().uuidString)"

        require(!store.hasKey, "an unconfigured store reports no key")
        require(store.save(baseURL: "", model: "x", temperature: 0.2, maxTokens: 100, apiKey: nil) == false,
                "an empty base URL is rejected")
        require(store.invalidSettingsMessage?.hasPrefix("Enter a base URL") == true,
                "the empty-URL message is reader-facing: \(store.invalidSettingsMessage ?? "nil")")
        require(store.invalidSettingsMessage?.contains("ArisFfiError") == false,
                "the settings message does not expose the generated error type")
        require(store.save(baseURL: "ftp://example.com/v1", model: "x", temperature: 0.2, maxTokens: 100, apiKey: nil) == false,
                "a non-HTTP base URL is rejected")
        require(store.save(baseURL: "https://api.openai.com/v1", model: "", temperature: 0.2, maxTokens: 100, apiKey: nil) == false,
                "an empty model is rejected")
        require(store.save(baseURL: "https://api.openai.com/v1/v1/chat/completions", model: "x", temperature: 0.2, maxTokens: 100, apiKey: nil) == false,
                "a full /chat/completions URL is rejected with a readable message")
        require(store.invalidSettingsMessage?.hasPrefix("Enter the base URL without /chat/completions") == true,
                "the endpoint-suffix message explains the shape: \(store.invalidSettingsMessage ?? "nil")")
        require(store.save(baseURL: "http://localhost:11434/v1/", model: "llama3.2", temperature: 0.2, maxTokens: 900, apiKey: key),
                "a valid local Ollama configuration is accepted")
        require(store.baseURL == "http://localhost:11434/v1",
                "the trailing slash is normalised away")
        require(store.endpointInfo?.endpoint == "http://localhost:11434/v1/chat/completions",
                "the endpoint appends /chat/completions once")
        require(store.endpointInfo?.isLocal == true, "localhost is classified as local")
        require(store.hasKey, "saving a key updates the key-configured state")
        require(fixture.keyStore.key == key, "the key went to the injected key store")
        require((try? store.readKey()) == key, "the key can be read back only through the key store")
        require(store.save(baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini", temperature: 0.2, maxTokens: 900, apiKey: nil),
                "the key can be kept while changing the provider")
        require(fixture.keyStore.key == key, "a blank key field does not clear the stored key")
        require(store.endpointInfo?.isLocal == false, "an OpenAI URL is classified as remote")

        let clear = store.clearKey()
        require(clear && !store.hasKey && fixture.keyStore.key == nil,
                "clearing the key removes it and updates the state")
    }

    /// The key must never reach UserDefaults and must never appear in the panel/log output.
    @MainActor
    private static func aiKeyHygieneChecks() throws {
        let fixture = makeSettings(key: nil)
        defer { fixture.cleanup() }
        let store = fixture.store
        let key = "sk-LEAK-CHECK-\(UUID().uuidString)"
        let baseURL = "http://localhost:11434/v1"

        require(store.save(baseURL: baseURL, model: "llama3.2", temperature: 0.2, maxTokens: 900, apiKey: key),
                "the hygiene fixture stores its key")

        let captured = captureStandardOutput {
            _ = try? store.readKey()
            _ = store.clearKey()
            _ = store.save(baseURL: "not-a-url", model: "llama3.2", temperature: 0.2, maxTokens: 900, apiKey: nil)
            _ = try? store.readKey()
        }
        require(!captured.contains(key), "the key does not appear in anything written to stdout or stderr")

        let defaultsText = describeDefaults(fixture.defaults)
        require(!defaultsText.contains(key), "the key does not appear in the isolated UserDefaults suite")
        require(!describeDefaults(UserDefaults.standard).contains(key), "the key does not appear in the standard UserDefaults domain")
        require(!(store.invalidSettingsMessage ?? "").contains(key),
                "a validation error does not echo the key")
        require(!captured.contains("LEAK-CHECK"), "neither does a diagnostic substring appear")
    }

    /// Every `[p.N]` citation the panel will link is one Lyra asked for; nothing else is linkified.
    @MainActor
    private static func aiCitationChecks() throws {
        let answer = """
        # Findings

        The method is local [p.2], and page 2 is not a citation.
        - A retrieved block [p.99]
        1. A numbered point [12]
        """
        let markdown = AIAnswerMarkdown.parse(answer, pageCount: 3)
        require(markdown.citedPages == [2], "only the in-range [p.2] becomes a citation")
        require(markdown.blocks.count == 4, "heading, paragraph, bullet and numbered block are parsed")
        if case .heading(let level, _) = markdown.blocks[0] {
            require(level == 1, "the heading level is preserved")
        } else {
            fatalError("expected a heading")
        }

        let runs = AIAnswerMarkdown.inlineRuns("[p. 2] [p.2] [p.0] [pp.1-2]", pageCount: 3)
        let pages: [Int] = runs.compactMap {
            if case .citation(let page, _) = $0 { return page }
            return nil
        }
        require(pages == [2], "spaced, zero and range forms are not linkified")
        require(AIAnswerMarkdown.parse("", pageCount: 3).blocks.isEmpty, "an empty answer has no blocks")
    }

    /// The real Keychain path is exercised where the login Keychain is available. The check is
    /// skipped (never failed) in a session without a usable Keychain, because that is an
    /// environment limitation rather than a product defect.
    @MainActor
    private static func aiKeychainRoundTripCheck() throws {
        let service = "com.alex.lyra.ai.checks.\(UUID().uuidString)"
        let account = "check-\(UUID().uuidString)"
        let keychain = KeychainAPIKeyStore(service: service, account: account)
        let key = "sk-keychain-check-\(UUID().uuidString)"
        do {
            try keychain.saveKey(key)
        } catch {
            print("INFO: skipping Keychain round-trip; the login Keychain is unavailable (\(AIReadableError.message(error)))")
            return
        }
        defer { try? keychain.deleteKey() }
        require((try? keychain.hasKey()) == true, "the Keychain reports the saved item")
        require((try? keychain.readKey()) == key, "the Keychain round-trips the key")
        try keychain.deleteKey()
        require((try? keychain.hasKey()) == false, "the Keychain item is gone after clearing")
    }

    @MainActor
    private static func aiPanelChecks(root: URL) async throws {
        let fixtureURL = root.appendingPathComponent("tests/fixtures/multipage.pdf")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            print("INFO: skipping AI panel checks (no multipage fixture)")
            return
        }
        let engine = try RustEngine()
        let document = try engine.openDocument(at: fixtureURL)
        let context = AIReaderContext(
            documentKey: fixtureURL.standardizedFileURL.path,
            documentTitle: document.title,
            pageCount: document.pageCount,
            currentPage: 1,
            selection: nil
        )
        let baseURL = "http://127.0.0.1:11434/v1"
        let fakeKey = "sk-check-not-real-\(UUID().uuidString)"

        // 1. No key: a clear message, and neither prepare nor start reaches the provider.
        let missingKeyFixture = makeSettings(key: nil)
        defer { missingKeyFixture.cleanup() }
        require(missingKeyFixture.store.save(baseURL: baseURL, model: "mock-model", temperature: 0.2, maxTokens: 900, apiKey: nil),
                "the model settings save without a key")
        let missingKeyRecording = RecordingAIService(
            base: RustAIChatService(engine: engine, useMockProvider: true)
        )
        let missingKeyModel = AIAssistantModel(settings: missingKeyFixture.store)
        missingKeyModel.attach(service: missingKeyRecording, context: context)
        await missingKeyModel.prepare(action: .summarizePage, context: context)
        require(missingKeyModel.phase == .failed, "an unconfigured key stops before preview")
        require((missingKeyModel.errorMessage ?? "").contains("No API key"),
                "the unconfigured-key message says what is missing")
        require(missingKeyRecording.preparedRequests.isEmpty,
                "nothing is prepared or sent when no key is configured")
        require(missingKeyRecording.startedPlans.isEmpty,
                "no request is started when no key is configured")
        print("PASS: unconfigured key sends nothing")

        // 2. The preview and the sent plan are the same request.
        let fixture = makeSettings(key: fakeKey)
        defer { fixture.cleanup() }
        require(fixture.store.save(baseURL: baseURL, model: "mock-model", temperature: 0.2, maxTokens: 900, apiKey: fakeKey),
                "the configured provider saves")
        let recording = RecordingAIService(
            base: RustAIChatService(engine: engine, useMockProvider: true)
        )
        let model = AIAssistantModel(settings: fixture.store)
        model.attach(service: recording, context: context)

        await model.prepare(action: .summarizePage, context: context)
        try await eventually("the AI preview is built locally", { model.phase == .preview })
        require(recording.startedPlans.isEmpty, "preparing a preview sends nothing")
        guard let preview = model.plan else { fatalError("expected a plan") }
        require(recording.returnedPlans.last == preview, "the model holds the exact plan the service built")
        require(preview.isLocal, "the local endpoint is shown as local")
        require(preview.pageCount == UInt32(document.pageCount), "the preview carries the document page count")
        require(preview.parts.count == 1, "a three-page summary needs one request")
        require(preview.parts[0].pages.contains(1), "the current page is in the request")
        require(preview.parts[0].pageCharacters > 0, "the preview reports how many page characters are sent")
        require(preview.parts[0].requestCharacters > 0, "the preview reports the request size")
        require(preview.parts[0].wireBody.contains("\"stream\":true"), "the previewed body is a streaming request")
        require(preview.parts[0].wireBody.contains("\"model\":\"mock-model\""), "the previewed body names the configured model")
        require(!preview.parts[0].wireBody.contains(fakeKey), "the previewed body never contains the key")
        let authorization = preview.previewHeaders.first { $0.name == "Authorization" }?.value ?? ""
        require(authorization.contains("redacted") && !authorization.contains(fakeKey),
                "the preview shows a redacted Authorization header")

        model.send()
        try await eventually("the mock answer streams to completion", {
            model.phase == .finished && !model.answer.isEmpty
        })
        require(model.answer.contains("This page explains the method"),
                "the preset answer appears in the panel")
        require(model.answer.contains("[p.1]"), "the mock answer carries a citation")
        require(model.usage?.totalTokens == 168, "the usage line shows the provider's token count")
        require(recording.startedPlans.count == 1, "pressing Send starts exactly one request")
        guard let sent = recording.startedPlans.last else { fatalError("expected a sent plan") }
        require(sent.parts.map(\.wireBody) == preview.parts.map(\.wireBody),
                "the request that ran has the exact previewed wire body")
        require(sent.parts.map(\.pageCharacters) == preview.parts.map(\.pageCharacters),
                "the sent request has the exact previewed page-character count")
        let rendered = AIAnswerMarkdown.parse(model.answer, pageCount: Int(preview.pageCount))
        require(rendered.citedPages == [1], "the [p.1] citation in the answer is clickable")

        // 3. Ask about a selection: the preview includes the question and selected page.
        let pageText = try await engine.textPage(0)
        let end = min(30, max(0, pageText.chars.count - 1))
        let selection = AIReaderSelection(page: 1, start: 0, end: end)
        let selectionContext = AIReaderContext(
            documentKey: context.documentKey,
            documentTitle: context.documentTitle,
            pageCount: context.pageCount,
            currentPage: 1,
            selection: selection
        )
        model.attach(service: recording, context: selectionContext)
        model.question = "What does this passage claim?"
        await model.prepare(action: .askSelection, context: selectionContext)
        try await eventually("the selection preview is built", { model.phase == .preview })
        guard let selectionPlan = model.plan else { fatalError("expected a selection plan") }
        require(selectionPlan.parts[0].userPrompt.contains("What does this passage claim?"),
                "the question is in the request preview")
        require(selectionPlan.parts[0].userPrompt.contains("Selected text"),
                "the selected text is in the request preview")
        require(selectionPlan.sourcePages.contains(1), "the selected page is cited in the plan")
        model.discard()

        // 4. Cancel stops the stream; Retry sends the same plan again.
        model.attach(service: recording, context: context)
        await model.prepare(action: .summarizePage, context: context)
        try await eventually("the cancel fixture has a preview", { model.phase == .preview })
        model.send()
        try await eventually("the stream has started producing text", {
            model.phase == .streaming && !model.answer.isEmpty
        })
        model.cancel()
        try await eventually("cancel reaches the cancelled state", { model.phase == .cancelled })
        let partial = model.answer
        require(!partial.isEmpty, "cancel keeps the partial answer")
        try await Task.sleep(for: .milliseconds(250))
        require(model.answer == partial, "the mock provider stops after cancellation")
        let callsBeforeRetry = recording.startedPlans.count
        model.retry()
        try await eventually("retry completes a second request", {
            model.phase == .finished && !model.answer.isEmpty
        })
        require(recording.startedPlans.count == callsBeforeRetry + 1,
                "retry starts one more request")
        require(model.answer.contains("This page explains the method"),
                "retry shows a fresh answer")
        require(model.usage?.totalTokens == 168, "retry reports usage again")
    }
}

// MARK: - Test helpers

/// Runs `body` with stdout and stderr captured, then returns everything written. Used to prove the
/// key is not logged. The body must not call `require` (its PASS line would be captured too).
@MainActor
private func captureStandardOutput(_ body: () -> Void) -> String {
    let pipe = Pipe()
    let readHandle = pipe.fileHandleForReading
    let writeHandle = pipe.fileHandleForWriting
    fflush(stdout)
    fflush(stderr)
    let savedOut = dup(STDOUT_FILENO)
    let savedErr = dup(STDERR_FILENO)
    dup2(writeHandle.fileDescriptor, STDOUT_FILENO)
    dup2(writeHandle.fileDescriptor, STDERR_FILENO)
    defer {
        fflush(stdout)
        fflush(stderr)
        if savedOut >= 0 { dup2(savedOut, STDOUT_FILENO); close(savedOut) }
        if savedErr >= 0 { dup2(savedErr, STDERR_FILENO); close(savedErr) }
        try? writeHandle.close()
    }
    body()
    fflush(stdout)
    fflush(stderr)
    if savedOut >= 0 { dup2(savedOut, STDOUT_FILENO) }
    if savedErr >= 0 { dup2(savedErr, STDERR_FILENO) }
    try? writeHandle.close()
    let data = readHandle.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

/// Flattens every value in a UserDefaults domain so a key hiding in any string or data value is
/// visible to the assertion.
private func describeDefaults(_ defaults: UserDefaults) -> String {
    var pieces: [String] = []
    func collect(_ value: Any) {
        switch value {
        case let string as String:
            pieces.append(string)
        case let data as Data:
            if let string = String(data: data, encoding: .utf8) { pieces.append(string) }
        case let dictionary as [String: Any]:
            for (key, nested) in dictionary {
                pieces.append(key)
                collect(nested)
            }
        case let array as [Any]:
            for nested in array { collect(nested) }
        default:
            pieces.append(String(describing: value))
        }
    }
    collect(defaults.dictionaryRepresentation())
    return pieces.joined(separator: "\n")
}
