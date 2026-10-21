import AppKit
import CoreText
import LyraReaderBindings
import LyraReaderKit
import SwiftUI
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

/// A service that uses the real Rust planner for the preview but scripts the stream. This is how
/// the checks exercise provider shapes the Rust MockProvider does not produce (reasoning-only,
/// usage-only) while still using the production plan/validation path.
@MainActor
private final class ScriptedAIChatService: AIChatServicing {
    private let base: RustAIChatService
    private let scriptedEvents: [AIStreamEvent]
    private(set) var startCount = 0

    init(engine: RustEngine, events: [AIStreamEvent]) {
        self.base = RustAIChatService(engine: engine)
        self.scriptedEvents = events
    }

    func prepare(_ request: AIMakePlanRequest) async throws -> AiPlanRecord {
        try await base.prepare(request)
    }

    func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle {
        startCount += 1
        return ScriptedAIChatHandle(events: scriptedEvents)
    }
}

@MainActor
private final class ScriptedAIChatHandle: AIChatHandle {
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

/// Scripts a two-part document summary plus the separately previewed consolidation. The original
/// plan is synthetic because producing a real multi-part plan needs a large document; the merge
/// plan itself is built by the production Rust code.
@MainActor
private final class MergeScriptedService: AIChatServicing {
    let base: RustAIChatService
    let originalPlan: AiPlanRecord
    let partEvents: [AIStreamEvent]
    let mergeEvents: [AIStreamEvent]
    private(set) var startedPlans: [AiPlanRecord] = []

    init(
        engine: RustEngine,
        originalPlan: AiPlanRecord,
        partEvents: [AIStreamEvent],
        mergeEvents: [AIStreamEvent]
    ) {
        self.base = RustAIChatService(engine: engine)
        self.originalPlan = originalPlan
        self.partEvents = partEvents
        self.mergeEvents = mergeEvents
    }

    func prepare(_ request: AIMakePlanRequest) async throws -> AiPlanRecord {
        originalPlan
    }

    func prepareMerge(_ request: AIMergePlanRequest) async throws -> AiPlanRecord {
        try await base.prepareMerge(request)
    }

    func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle {
        startedPlans.append(plan)
        if plan.parts.count == 1 && plan.parts[0].label.hasPrefix("Consolidated summary") {
            return ScriptedAIChatHandle(events: mergeEvents)
        }
        return ScriptedAIChatHandle(events: partEvents)
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
        try await aiSelectionChecks(root: root)
        try await aiPanelChecks(root: root)
        try await aiMergeChecks()
        try await aiDocumentChatChecks(root: root)
        try await aiDocumentChatLayoutChecks(root: root)
    }

    @MainActor
    private static func makeSettings(key: String?) -> AISettingsFixture {
        let suiteName = "lyra-reader-ai-checks-\(UUID().uuidString)"
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
        require(store.invalidSettingsMessage?.contains("LyraReaderFfiError") == false,
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
        require(store.reasoningMode == .off && store.reasoningEncoding == .thinking,
                "reasoning defaults to off via the thinking encoding")
        let offSettings = try store.providerSettings()
        require(offSettings.reasoningSummary.contains("thinking: disabled"),
                "the off setting is stated in plain words: \(offSettings.reasoningSummary)")
        require(AISettingsStore.reasoningValidationMessage(mode: .high, encoding: .thinking) != nil,
                "the thinking toggle rejects an intensity mode")
        require(store.save(
            baseURL: "http://localhost:11434/v1",
            model: "llama3.2",
            temperature: 0.2,
            maxTokens: 900,
            apiKey: nil,
            reasoningMode: .high,
            reasoningEncoding: .reasoningEffort
        ), "high effort via reasoning_effort is accepted")
        let highSettings = try store.providerSettings()
        require(highSettings.reasoningSummary.contains("reasoning_effort: high"),
                "the high-effort field is stated: \(highSettings.reasoningSummary)")
        require(store.save(
            baseURL: "http://localhost:11434/v1",
            model: "llama3.2",
            temperature: 0.2,
            maxTokens: 900,
            apiKey: nil,
            reasoningMode: .off,
            reasoningEncoding: .reasoningEffort
        ) == false, "off via reasoning_effort is rejected rather than sending an invented value")
        require(store.reasoningMode == .high, "a rejected combination does not overwrite the saved setting")
        require(store.save(
            baseURL: "http://localhost:11434/v1",
            model: "llama3.2",
            temperature: 0.2,
            maxTokens: 900,
            apiKey: nil,
            reasoningMode: .providerDefault,
            reasoningEncoding: .thinking
        ), "provider-default mode is accepted")
        let defaultSettings = try store.providerSettings()
        require(defaultSettings.reasoningSummary.contains("provider default"),
                "provider default is stated in plain words")
        require(store.save(
            baseURL: "http://localhost:11434/v1",
            model: "llama3.2",
            temperature: 0.2,
            maxTokens: 900,
            apiKey: nil,
            reasoningMode: .off,
            reasoningEncoding: .thinking
        ), "the default off/thinking setting restores")
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

    /// Every `[p.N]` citation the panel will link is one LyraReader asked for; nothing else is linkified.
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
        require(AIAnswerMarkdown.allCitedPages(in: "One [p.7], again [p.2], duplicate [p.2], zero [p.0].") == [7, 2, 0],
                "the chat verification scan sees every strict citation, including out-of-range pages")
        require(AIAnswerMarkdown.allCitedPages(in: "[p. 3] [pp.1-2] [12]").isEmpty,
                "the verification scan does not invent citations from other forms")
        require(AIAnswerMarkdown.parse("", pageCount: 3).blocks.isEmpty, "an empty answer has no blocks")
    }

    /// The real Keychain path is exercised where the login Keychain is available. The check is
    /// skipped (never failed) in a session without a usable Keychain, because that is an
    /// environment limitation rather than a product defect.
    @MainActor
    private static func aiKeychainRoundTripCheck() throws {
        let service = "com.alex.lyrareader.ai.checks.\(UUID().uuidString)"
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
        let legacy = KeychainAPIKeyStore(service: service + ".old", account: account)
        let upgraded = KeychainAPIKeyStore(service: service, account: account, legacyService: service + ".old")
        defer { try? upgraded.deleteKey() }
        try legacy.saveKey(key)
        require((try? upgraded.hasKey()) == true && (try? upgraded.readKey()) == key,
                "rename finds an API key or ChatGPT token in the legacy Keychain service")
        try upgraded.saveKey("new-key")
        require((try? upgraded.readKey()) == "new-key", "a newly saved credential wins over the old service")
        try upgraded.deleteKey()
        require((try? legacy.hasKey()) == false && (try? upgraded.readKey()) == nil,
                "signing out after rename removes both services without resurrecting an old token")

    }

    /// Compare the four action paths on the same settings. This is evidence, not inference: it
    /// prints the wire controls (max_tokens, temperature, model, stream, reasoning field), and it
    /// drives each action through the same content event to prove the panel accumulator is shared.
    @MainActor
    private static func aiActionPathChecks(
        engine: RustEngine,
        settings: AISettingsStore,
        pageContext: AIReaderContext,
        selectionContext: AIReaderContext
    ) async throws {
        func bodyValue(_ body: String, _ key: String) -> Any? {
            guard let data = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return object[key]
        }

        var profiles: [(AIAssistantAction, String)] = []
        for action in AIAssistantAction.allCases where !action.isDocumentChat && action != .regionQuestion {
            let context = action.requiresSelection ? selectionContext : pageContext
            let service = ScriptedAIChatService(
                engine: engine,
                events: [
                    .partStarted(index: 0, total: 1, label: "Page 1"),
                    .delta("Visible answer from \(action.rawValue)"),
                    .done,
                ]
            )
            let model = AIAssistantModel(settings: settings)
            model.attach(service: service, context: context)
            await model.prepare(action: action, context: context)
            try await eventually("the \(action.rawValue) profile has a preview", { model.phase == .preview })
            guard let plan = model.plan, let part = plan.parts.first else {
                fatalError("no plan for \(action.rawValue)")
            }
            let body = part.wireBody
            let maxTokens = (bodyValue(body, "max_tokens") as? NSNumber)?.intValue
            let temperature = (bodyValue(body, "temperature") as? NSNumber)?.doubleValue
            let modelName = bodyValue(body, "model") as? String
            let stream = (bodyValue(body, "stream") as? NSNumber)?.boolValue
            let reasoning = bodyValue(body, "thinking") as? [String: Any]
            let wireReasoning = reasoning?["type"] as? String
            let maxText = maxTokens.map { String($0) } ?? "nil"
            let temperatureText = temperature.map { String($0) } ?? "nil"
            let streamText = stream.map { String($0) } ?? "nil"
            print("AI-REQUEST action=\(action.rawValue) parts=\(plan.parts.count) max_tokens=\(maxText) temperature=\(temperatureText) model=\(modelName ?? "nil") stream=\(streamText) reasoning_field=thinking type=\(wireReasoning ?? "nil") system_chars=\(part.systemPrompt.count) user_chars=\(part.userPrompt.count)")
            print("AI-REQUEST \(action.rawValue) system=\(part.systemPrompt.debugDescription)")
            print("AI-REQUEST \(action.rawValue) wire=\(body)")
            profiles.append((action, body))
            require(maxTokens == 900, "\(action.rawValue) uses the configured max_tokens")
            require(abs((temperature ?? -1) - 0.2) < 0.0001,
                    "\(action.rawValue) uses the configured temperature")
            require(modelName == "mock-model", "\(action.rawValue) uses the configured model")
            require(stream == true, "\(action.rawValue) is a streaming request")
            require(wireReasoning == "disabled", "\(action.rawValue) sends the selected reasoning field")
            require(!body.contains("reasoning_effort"), "\(action.rawValue) sends only one reasoning field")

            model.send()
            try await eventually("the \(action.rawValue) content reaches the shared answer accumulator", {
                model.phase == .finished && model.answer.contains("Visible answer from")
            })
            require(model.answer.contains(action.rawValue),
                    "\(action.rawValue) feeds the same answer accumulator")
            model.discard()
        }
        require(profiles.count == AIAssistantAction.allCases.filter { !$0.isDocumentChat && $0 != .regionQuestion }.count,
                "all four single-shot action paths were profiled")
        for (action, body) in profiles {
            require(body.contains("\"thinking\":{\"type\":\"disabled\"}"),
                    "\(action.rawValue) carries exactly thinking:disabled")
        }
    }

    /// Reproduces the live selection with the canvas's own hit testing    /// Reproduces the live selection with the canvas's own hit testing, then compares the
    /// selection model, the copy path and the AI prompt extraction on the same range.
    ///
    /// The committed numbered-margin fixture runs in CI. The local manuscript is the real-paper
    /// reproduction and is skipped when the copyright corpus is absent.
    @MainActor
    private static func aiSelectionChecks(root: URL) async throws {
        let fixture = root.appendingPathComponent("tests/fixtures/selection-numbered-margin.pdf")
        if FileManager.default.fileExists(atPath: fixture.path) {
            try await selectionRoundTrip(
                url: fixture,
                label: "numbered-margin fixture",
                startPhrase: "motion",
                endPhrase: "sampling",
                endOffset: 3,
                expectedPageText: "001",
                gutterDigits: ["001", "002", "003", "004", "005"]
            )
        } else {
            print("INFO: skipping numbered-margin selection fixture (missing)")
        }

        let samples = ProcessInfo.processInfo.environment["LYRA_READER_PDF_SAMPLES"]
            .map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("pdf-samples")
        let manuscript = samples.appendingPathComponent("manuscript_0925.pdf")
        if FileManager.default.fileExists(atPath: manuscript.path) {
            try await selectionRoundTrip(
                url: manuscript,
                label: "manuscript_0925",
                startPhrase: "Existing 3D motion generators",
                endPhrase: "pose guidance.",
                endOffset: "pose guidance.".count - 1,
                expectedPageText: "000",
                gutterDigits: (0...53).map { String(format: "%03d", $0) }
            )
        } else {
            print("INFO: skipping live numbered-margin reproduction (no manuscript_0925.pdf)")
        }
    }

    /// Open `url`, build the intended character range by scanning the text layer, then drive
    /// `AppState.beginSelection`/`extendSelection` with points inside the first and last
    /// character boxes. The text the model receives must equal the canvas/copy text exactly.
    @MainActor
    private static func selectionRoundTrip(
        url: URL,
        label: String,
        startPhrase: String,
        endPhrase: String,
        endOffset: Int,
        expectedPageText: String,
        gutterDigits: [String]
    ) async throws {
        let pasteboard = NSPasteboard.general
        let savedClipboard = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let savedClipboard {
                pasteboard.setString(savedClipboard, forType: .string)
            }
        }

        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        state.newTab(url: url)
        state.gotoPage(0)
        guard let engine = state.engine as? RustEngine else {
            fatalError("the selection round-trip needs the Rust engine")
        }
        let text = try await engine.textPage(0)
        let characters = text.chars
        // Search the TextChar array, not a Swift String: CRLF is one grapheme but two text
        // characters here, and the layer contains U+0002 position markers. String distances
        // would not be selection indices.
        func find(_ phrase: String, from: Int) -> Int? {
            let needle = Array(phrase.unicodeScalars).map(\.value)
            guard !needle.isEmpty, from >= 0, characters.count >= needle.count else {
                return nil
            }
            for start in from...(characters.count - needle.count) {
                var matches = true
                for offset in 0..<needle.count where characters[start + offset].unicode != needle[offset] {
                    matches = false
                    break
                }
                if matches { return start }
            }
            return nil
        }
        func selectedText(_ range: ClosedRange<Int>) -> String {
            String(characters[range].map {
                Character(UnicodeScalar($0.unicode) ?? "?")
            })
        }
        guard let startIndex = find(startPhrase, from: 0),
              let endPhraseIndex = find(endPhrase, from: startIndex) else {
            fatalError("\(label): selection phrases were not found in the text layer")
        }
        let endIndex = endPhraseIndex + endOffset
        let intendedRange = startIndex...endIndex
        let intendedText = selectedText(intendedRange)
        require(text.text.contains(expectedPageText),
                "\(label): the raw text layer carries the numbered margin")
        for digit in gutterDigits {
            require(!intendedText.contains(digit),
                    "\(label): a gutter run outside the selection is not in the selected text")
        }

        guard let placement = engine.visiblePages(
            scrollYPt: state.scrollYPt,
            viewportHeightPt: 500,
            gapPt: state.pageGapPt,
            marginPt: 0,
            layout: state.layoutMode
        ).first(where: { $0.index == 0 }) else {
            fatalError("\(label): page 1 is not visible for the selection reproduction")
        }
        func point(at index: Int) -> CGPoint {
            let character = characters[index]
            return CGPoint(
                x: placement.leftPt + character.xPt + min(1, character.widthPt / 2),
                y: placement.topPt + character.yPt + max(1, character.heightPt / 2)
            )
        }

        var attempts = 0
        while state.selection == nil && attempts < 100 {
            state.beginSelection(at: point(at: startIndex))
            attempts += 1
            if state.selection == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        state.extendSelection(to: point(at: endIndex))
        guard let selection = state.selection else {
            fatalError("\(label): canvas hit testing produced no selection")
        }
        let selectedByCanvas = selectedText(
            selection.range.clamped(to: 0...(characters.count - 1))
        )

        state.copySelection()
        let copied = pasteboard.string(forType: .string) ?? ""

        func promptSelection(for range: ClosedRange<Int>) async throws -> String {
            let record = AiPlanRequestRecord(
                action: .translateSelection,
                currentPage: 0,
                selection: AiSelectionRecord(
                    page: 0,
                    start: UInt32(range.lowerBound),
                    end: UInt32(range.upperBound)
                ),
                question: nil,
                language: "English",
                history: [],
                region: nil,
                baseUrl: "http://127.0.0.1:11434/v1",
                model: "mock-model",
                temperature: 0.2,
                maxTokens: 900,
                reasoningMode: "off",
                reasoningEncoding: "thinking"
            )
            let plan = try await engine.prepareAIPlan(record)
            let prompt = plan.parts[0].userPrompt
            let marker = "[Selected text - page 1]\n"
            guard let markerRange = prompt.range(of: marker) else {
                return "<missing selection marker>"
            }
            return String(prompt[markerRange.upperBound...])
                .trimmingCharacters(in: .newlines)
        }

        let promptFromIntendedRange = try await promptSelection(for: intendedRange)
        let promptFromCanvas = try await promptSelection(
            for: selection.range.clamped(to: 0...(characters.count - 1))
        )

        let summaryPlan = try await engine.prepareAIPlan(
            AiPlanRequestRecord(
                action: .summarizePage,
                currentPage: 0,
                selection: nil,
                question: nil,
                language: "English",
                history: [],
                region: nil,
                baseUrl: "http://127.0.0.1:11434/v1",
                model: "mock-model",
                temperature: 0.2,
                maxTokens: 4096,
                reasoningMode: "off",
                reasoningEncoding: "thinking"
            )
        )
        let summaryPrompt = summaryPlan.parts[0].userPrompt
        let summaryLines = Set(
            summaryPrompt.split(separator: "\n").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        )
        for digit in gutterDigits {
            require(!summaryLines.contains(digit),
                    "\(label): page context does not send a standalone margin line \(digit)")
        }
        require(summaryPrompt.contains("Existing 3D motion generators")
                    && summaryPrompt.contains("diffusion-based methods further incur substantial iterative sampling costs"),
                "\(label): page context keeps the abstract intact after gutter removal")

        if label == "manuscript_0925" {
            let documentPlan = try await engine.prepareAIPlan(
                AiPlanRequestRecord(
                    action: .summarizeDocument,
                    currentPage: 0,
                    selection: nil,
                    question: nil,
                    language: nil,
                    history: [],
                    region: nil,
                    baseUrl: "http://127.0.0.1:11434/v1",
                    model: "mock-model",
                    temperature: 0.2,
                    maxTokens: 900,
                    reasoningMode: "off",
                    reasoningEncoding: "thinking"
                )
            )
            let totalPageCharacters = documentPlan.parts.reduce(UInt64(0)) {
                $0 + $1.pageCharacters
            }
            let largestPart = documentPlan.parts.map(\.pageCharacters).max() ?? 0
            print("AI-DOCUMENT-SUMMARY pages=\(documentPlan.pageCount) parts=\(documentPlan.parts.count) total_page_chars=\(totalPageCharacters) largest_part_page_chars=\(largestPart)")
            require(documentPlan.parts.count == 1 && largestPart == totalPageCharacters,
                    "the complete paper uses one independent summary request")
            require(documentPlan.parts[0].systemPrompt.contains("Evidence and results"),
                    "the summary prompt supports critical academic reading")
        }

        print("AI-SELECTION \(label) range intended=\(intendedRange) canvas=\(selection.range) charCount=\(characters.count) textCount=\(text.text.count)")
        print("AI-SELECTION \(label) intended=\(intendedText.debugDescription)")
        print("AI-SELECTION \(label) canvas=\(selectedByCanvas.debugDescription)")
        print("AI-SELECTION \(label) copied=\(copied.debugDescription)")
        print("AI-SELECTION \(label) prompt(intended)=\(promptFromIntendedRange.debugDescription)")
        print("AI-SELECTION \(label) prompt(canvas)=\(promptFromCanvas.debugDescription)")
        print("AI-SELECTION \(label) textLayerPrefix=\(String(text.text.prefix(120)).debugDescription)")
        print("AI-SELECTION \(label) summaryPromptPrefix=\(String(summaryPrompt.prefix(240)).debugDescription)")
        require(selection.range == intendedRange,
                "\(label): canvas hit testing selects the intended character range")
        require(selectedByCanvas == intendedText,
                "\(label): the canvas selection model text matches the intended range")
        require(copied == intendedText,
                "\(label): the copy path sends the same characters as the selection model")
        require(promptFromIntendedRange == intendedText,
                "\(label): an index-built selection sends exactly the canvas text")
        require(promptFromCanvas == intendedText,
                "\(label): a hit-tested selection sends exactly the canvas text")
    }

    /// A two-part synthetic summary proves the consolidation is a separate previewed request,
    /// that the per-part answers survive, and that a missing part stops the merge by name.
    @MainActor
    private static func aiMergeChecks() async throws {
        let fixture = makeSettings(key: "sk-merge-check")
        defer { fixture.cleanup() }
        require(fixture.store.save(
            baseURL: "http://127.0.0.1:11434/v1",
            model: "mock-model",
            temperature: 0.2,
            maxTokens: 900,
            apiKey: "sk-merge-check"
        ), "the merge fixture saves its provider")

        let baseURL = "http://127.0.0.1:11434/v1"
        let planPart: (UInt32, String, UInt32, [UInt32]) -> AiPlanPartRecord = { index, label, primary, pages in
            AiPlanPartRecord(
                index: index,
                total: 2,
                label: label,
                primaryPage: primary,
                pages: pages,
                pageCharacters: 100,
                requestCharacters: 200,
                systemPrompt: "system",
                userPrompt: "part \(index + 1)",
                wireBody: "{\"stream\":true,\"max_tokens\":900}",
                note: nil
            )
        }
        let originalPlan = AiPlanRecord(
            action: .summarizeDocument,
            actionLabel: "Summarise document",
            documentTitle: "Synthetic long paper",
            pageCount: 3,
            baseUrl: baseURL,
            endpoint: baseURL + "/chat/completions",
            host: "127.0.0.1",
            isLocal: true,
            model: "mock-model",
            temperature: 0.2,
            maxTokens: 900,
            parts: [
                planPart(0, "Pages 1-2", 1, [1, 2]),
                planPart(1, "Page 3", 3, [3]),
            ],
            sourcePages: [1, 2, 3],
            note: "split into 2 parts",
            sources: [],
            historyTurns: 0,
            previewHeaders: [],
            estimatedTokens: 400
        )
        let partEvents: [AIStreamEvent] = [
            .partStarted(index: 0, total: 2, label: "Pages 1-2"),
            .delta("Part one summary [p.1]. "),
            .partStarted(index: 1, total: 2, label: "Page 3"),
            .delta("Part two summary [p.3]."),
            .done,
        ]
        let mergeEvents: [AIStreamEvent] = [
            .partStarted(index: 0, total: 1, label: "Consolidated summary · Pages 1-3"),
            .delta("Consolidated answer [p.1]."),
            .done,
        ]
        let engine = try RustEngine()
        let service = MergeScriptedService(
            engine: engine,
            originalPlan: originalPlan,
            partEvents: partEvents,
            mergeEvents: mergeEvents
        )
        let model = AIAssistantModel(settings: fixture.store)
        let context = AIReaderContext(
            documentKey: "merge-check",
            documentTitle: "Synthetic long paper",
            pageCount: 3,
            currentPage: 1,
            selection: nil
        )
        model.attach(service: service, context: context)
        await model.prepare(action: .summarizeDocument, context: context)
        try await eventually("the synthetic long summary has a preview", { model.phase == .preview })
        model.send()
        try await eventually("all part summaries finish and the merge is previewed", {
            model.phase == .mergePreview && model.mergePlan != nil
        })
        require(service.startedPlans.count == 1, "the merge is not sent automatically")
        require(model.partAnswers.count == 2, "both per-part answers are retained")
        require(model.partAnswers[0]?.contains("Part one") == true, "part 1 is available")
        require(model.partAnswers[1]?.contains("Part two") == true, "part 2 is available")
        guard let mergePlan = model.mergePlan else { fatalError("expected a merge plan") }
        require(mergePlan.parts.count == 1, "the consolidation is one request")
        require(mergePlan.parts[0].userPrompt.contains("Part one summary"), "the merge carries part 1")
        require(mergePlan.parts[0].userPrompt.contains("Part two summary"), "the merge carries part 2")
        require(mergePlan.parts[0].userPrompt.contains("[Part 1 of 2"), "the merge names the part range")
        require(model.statusNote?.contains("Consolidation request") == true
                    || model.statusNote?.contains("consolidation request") == true,
                "the merge is shown as its own previewable step")
        require(model.phase == .mergePreview, "the merge waits for a separate Send")

        model.sendMerge()
        try await eventually("the consolidation finishes", {
            model.phase == .finished && model.answer.contains("Consolidated answer")
        })
        require(service.startedPlans.count == 2, "the merge is the second request")
        require(model.answer.contains("[p.1]"), "the consolidated answer keeps citations")
        require(model.partAnswers.count == 2, "per-part answers survive the consolidation")
        require(model.answer.contains("Part one") == false, "the consolidated answer is the main answer")

        // A missing part stops the merge and names it; the panel never silently summarises 8/9.
        let missingFixture = makeSettings(key: "sk-merge-missing")
        defer { missingFixture.cleanup() }
        require(missingFixture.store.save(
            baseURL: baseURL,
            model: "mock-model",
            temperature: 0.2,
            maxTokens: 900,
            apiKey: "sk-merge-missing"
        ), "the missing-part fixture saves its provider")
        let missingService = MergeScriptedService(
            engine: engine,
            originalPlan: originalPlan,
            partEvents: [
                .partStarted(index: 0, total: 2, label: "Pages 1-2"),
                .delta("Part one summary [p.1]."),
                .done,
            ],
            mergeEvents: mergeEvents
        )
        let missingModel = AIAssistantModel(settings: missingFixture.store)
        missingModel.attach(service: missingService, context: context)
        await missingModel.prepare(action: .summarizeDocument, context: context)
        try await eventually("the incomplete summary has a preview", { missingModel.phase == .preview })
        missingModel.send()
        try await eventually("the missing part is handled", {
            missingModel.phase == .finished && missingModel.mergePlan == nil
        })
        require(missingModel.statusNote?.contains("Part 2") == true,
                "the panel names the missing part")
        require(missingModel.statusNote?.contains("no consolidation") == true,
                "the panel says no consolidation was sent")
        require(missingModel.partAnswers.count == 1, "the successful part is kept")
        require(missingService.startedPlans.count == 1, "no merge request is sent with a missing part")
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

        try await aiActionPathChecks(
            engine: engine,
            settings: fixture.store,
            pageContext: context,
            selectionContext: selectionContext
        )

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
        require(model.reasoning.isEmpty, "a content-only answer does not invent reasoning")

        // 5. Reasoning-only stream: the answer stays empty, the reasoning is shown separately,
        // and the empty-answer diagnostic names what arrived and the completion tokens.
        let reasoningFixture = makeSettings(key: fakeKey)
        defer { reasoningFixture.cleanup() }
        require(reasoningFixture.store.save(
            baseURL: baseURL,
            model: "deepseek-flash",
            temperature: 0.2,
            maxTokens: 900,
            apiKey: fakeKey
        ), "the reasoning fixture saves its provider")
        let reasoningService = ScriptedAIChatService(
            engine: engine,
            events: [
                .partStarted(index: 0, total: 1, label: "Page 1"),
                .reasoningDelta("I need to translate the selected passage. "),
                .reasoningDelta("The answer would follow, but the budget ran out."),
                .usage(AIUsage(promptTokens: 300, completionTokens: 900, totalTokens: 1200)),
                .done,
            ]
        )
        let reasoningModel = AIAssistantModel(settings: reasoningFixture.store)
        reasoningModel.attach(service: reasoningService, context: selectionContext)
        await reasoningModel.prepare(action: .translateSelection, context: selectionContext)
        try await eventually("the reasoning fixture has a preview", { reasoningModel.phase == .preview })
        reasoningModel.send()
        try await eventually("the reasoning-only stream finishes", { reasoningModel.phase == .finished })
        require(reasoningService.startCount == 1, "the reasoning fixture starts one request")
        require(reasoningModel.answer.isEmpty, "reasoning is never concatenated into the answer")
        require(reasoningModel.reasoning.contains("I need to translate the selected passage"),
                "the reasoning text is retained separately")
        require(reasoningModel.reasoningDeltaCount == 2 && reasoningModel.contentDeltaCount == 0,
                "the panel counts reasoning and content deltas separately")
        require(reasoningModel.usage?.totalTokens == 1200, "reasoning usage is retained")
        let reasoningStatus = reasoningModel.statusNote ?? ""
        require(reasoningStatus.contains("The provider sent reasoning but no answer"),
                "the status line says reasoning arrived without an answer: \(reasoningStatus)")
        require(reasoningStatus.contains("no `content` deltas"),
                "the empty-answer diagnostic names the missing content deltas: \(reasoningStatus)")
        require(reasoningStatus.contains("900 completion tokens"),
                "the empty-answer diagnostic reports completion tokens: \(reasoningStatus)")

        // 5b. A length stop with reasoning and usage: the panel names the token limit and the
        // frame/byte counts instead of saying only "empty answer".
        let truncatedUsage = AIUsage(
            promptTokens: 300,
            completionTokens: 900,
            totalTokens: 1200,
            reasoningTokens: 900
        )
        let truncatedService = ScriptedAIChatService(
            engine: engine,
            events: [
                .partStarted(index: 0, total: 1, label: "Page 1"),
                .reasoningDelta("The passage needs a careful translation. "),
                .usage(truncatedUsage),
                .diagnostics(AIStreamDiagnostics(
                    httpStatus: 200,
                    bytes: 1234,
                    frames: 4,
                    dataFrames: 3,
                    contentFrames: 0,
                    reasoningFrames: 1,
                    roleOnlyFrames: 1,
                    emptyFrames: 1,
                    usageFrames: 1,
                    contentShape: "none",
                    finishReason: "length",
                    usage: truncatedUsage
                )),
                .done,
            ]
        )
        let truncatedModel = AIAssistantModel(settings: reasoningFixture.store)
        truncatedModel.attach(service: truncatedService, context: selectionContext)
        await truncatedModel.prepare(action: .translateSelection, context: selectionContext)
        try await eventually("the truncated fixture has a preview", { truncatedModel.phase == .preview })
        truncatedModel.send()
        try await eventually("the truncated fixture finishes", { truncatedModel.phase == .finished })
        require(truncatedModel.answer.isEmpty && truncatedModel.reasoning.contains("careful translation"),
                "the truncated fixture separates reasoning from the empty answer")
        require(truncatedModel.finishReason == "length", "the panel retains finish_reason=length")
        let truncatedStatus = truncatedModel.statusNote ?? ""
        require(truncatedStatus.contains("stopped at its token limit"),
                "the panel says the provider stopped at its token limit: \(truncatedStatus)")
        require(truncatedStatus.contains("finish_reason length"),
                "the panel reports finish_reason explicitly: \(truncatedStatus)")
        require(truncatedStatus.contains("0 content") && truncatedStatus.contains("1 reasoning"),
                "the panel reports delta-kind counts: \(truncatedStatus)")
        require(truncatedStatus.contains("4 frame") && truncatedStatus.contains("1234 bytes"),
                "the panel reports frame and byte counts: \(truncatedStatus)")
        require(truncatedModel.reasoningTokensIgnored,
                "the panel notices reasoning tokens while thinking is off")

        // 6. Usage-only stream: same diagnostic, with no reasoning section.
        let usageOnlyService = ScriptedAIChatService(
            engine: engine,
            events: [
                .partStarted(index: 0, total: 1, label: "Page 1"),
                .usage(AIUsage(promptTokens: 300, completionTokens: 900, totalTokens: 1200)),
                .done,
            ]
        )
        let usageOnlyModel = AIAssistantModel(settings: reasoningFixture.store)
        usageOnlyModel.attach(service: usageOnlyService, context: selectionContext)
        await usageOnlyModel.prepare(action: .translateSelection, context: selectionContext)
        try await eventually("the usage-only fixture has a preview", { usageOnlyModel.phase == .preview })
        usageOnlyModel.send()
        try await eventually("the usage-only stream finishes", { usageOnlyModel.phase == .finished })
        require(usageOnlyModel.answer.isEmpty && usageOnlyModel.reasoning.isEmpty,
                "a usage-only stream produces neither answer nor reasoning")
        let usageOnlyStatus = usageOnlyModel.statusNote ?? ""
        require(usageOnlyStatus.contains("The provider returned no answer"),
                "a usage-only stream says there is no answer: \(usageOnlyStatus)")
        require(usageOnlyStatus.contains("no `content` deltas")
                    && usageOnlyStatus.contains("900 completion tokens"),
                "a usage-only stream names the delta counts and completion tokens: \(usageOnlyStatus)")
    }
}

// MARK: - Test helpers

// MARK: - Document chat (T5.6)

extension ReaderChecks {
    /// A deterministic eight-page PDF generated at check time. The repository carries no such
    /// sample: the text is chosen so pages 2, 4 and 6 answer the question and the other five are
    /// plausible decoys. The engine reads it through the same PDFium path as any opened paper.
    private static func writeDocumentChatFixture(to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(
                domain: "LyraReaderChecks",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "could not create the document-chat fixture"]
            )
        }
        let pages: [[String]] = [
            ["Introduction. This paper studies reading interfaces and their long term use."],
            ["The spectral absorbance experiment measured light across every sample."],
            ["Administrative scheduling details describe the team calendar and room booking."],
            ["The retrieval baseline improved recall on each evaluation query by a wide margin."],
            ["Appendix notes cover typography, margins and page layout conventions."],
            ["The evaluation query set was replayed against the retrieval baseline for comparison."],
            ["Acknowledgements thank the library staff for their patient help."],
            ["References point to prior work on reading interfaces and typography."],
        ]
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.black,
        ]
        for lines in pages {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(mediaBox)
            context.setFillColor(NSColor.black.cgColor)
            for (index, line) in lines.enumerated() {
                let attributed = NSAttributedString(string: line, attributes: attributes)
                let ctLine = CTLineCreateWithAttributedString(attributed)
                context.textPosition = CGPoint(x: 72, y: 720 - CGFloat(index) * 18)
                CTLineDraw(ctLine, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    @MainActor
    private static func aiDocumentChatChecks(root: URL) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-reader-docchat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let url = scratch.appendingPathComponent("long-paper.pdf")
        try writeDocumentChatFixture(to: url)

        let engine = try RustEngine()
        let document = try engine.openDocument(at: url)
        guard document.pageCount == 8 else {
            fatalError("the document-chat fixture did not produce 8 pages (got \(document.pageCount))")
        }
        let context = AIReaderContext(
            documentKey: url.standardizedFileURL.path,
            documentTitle: document.title,
            pageCount: document.pageCount,
            currentPage: 1,
            selection: nil
        )
        let baseURL = "http://127.0.0.1:11434/v1"
        let fakeKey = "sk-docchat-not-real-\(UUID().uuidString)"
        let fixture = makeSettings(key: fakeKey)
        defer { fixture.cleanup() }
        require(fixture.store.save(
            baseURL: baseURL,
            model: "mock-model",
            temperature: 0.2,
            maxTokens: 900,
            apiKey: fakeKey
        ), "the document-chat fixture saves its provider")

        let recording = RecordingAIService(
            base: RustAIChatService(engine: engine, useMockProvider: true)
        )
        let model = AIAssistantModel(settings: fixture.store)
        model.attach(service: recording, context: context)
        let question = "How did the spectral absorbance experiment and the retrieval baseline change the evaluation query results?"
        model.chatQuestion = question
        await model.prepareDocumentChat(context: context)
        try await eventually("the document-chat preview is built locally", {
            model.phase == .preview && model.plan != nil
        })
        require(recording.startedPlans.isEmpty,
                "document chat sends nothing while the preview is built")
        guard let preview = model.plan else { fatalError("expected a chat preview") }
        require(preview.action == .documentChat, "the preview is the document-chat action")
        require(preview.historyTurns == 0, "the first question has no earlier turns")
        let sentPages = Set(preview.parts[0].pages.map(Int.init))
        require(sentPages.count >= 2,
                "retrieval selected several pages from the whole document: \(sentPages)")
        require(sentPages.count < 8,
                "retrieval did not send the whole document: \(sentPages)")
        require(preview.parts.count == 1, "a chat question is one request")
        let body = preview.parts[0].wireBody
        for page in sentPages.sorted() {
            require(body.contains("[Page \(page)]"),
                    "the exact request body carries the page \(page) label")
        }
        for page in Set(1...8).subtracting(sentPages) {
            require(!body.contains("[Page \(page)]"),
                    "a page that retrieval did not select is not in the request: page \(page)")
        }
        require(body.contains("[Retrieved context]"), "retrieved passages are labelled in the body")
        require(preview.parts[0].pageCharacters > 0
                    && preview.parts[0].pageCharacters < 8_000,
                "the preview reports the retrieved character count, not the whole document")
        require(preview.parts[0].requestCharacters > preview.parts[0].pageCharacters,
                "the preview reports the request size separately")
        require(preview.sources.count == sentPages.count,
                "every sent page has a snippet source")
        for source in preview.sources {
            require(sentPages.contains(Int(source.page)),
                    "source page \(source.page) was sent")
            require(!source.snippet.isEmpty, "the source has a snippet")
            require(!source.rects.isEmpty,
                    "the source carries page geometry for the transient highlight")
        }

        // 1. Send the exact previewed body and build backlinks from the answer.
        model.send()
        try await eventually("the chat answer streams to completion", {
            model.phase == .finished && model.chatTurns.last?.state == .finished
        })
        require(recording.startedPlans.count == 1,
                "pressing Send starts exactly one chat request")
        guard let sent = recording.startedPlans.last else { fatalError("expected a sent chat plan") }
        require(sent.parts.map(\.wireBody) == preview.parts.map(\.wireBody),
                "the request that ran has the exact previewed body")
        guard let firstTurn = model.chatTurns.last else { fatalError("expected a chat turn") }
        require(firstTurn.question == question, "the question is kept with the answer")
        require(firstTurn.answer.contains("Sources:"),
                "the mock answer cites the sent pages: \(firstTurn.answer)")
        let links = firstTurn.backlinks(pageCount: 8)
        require(links.chips.count == sentPages.count,
                "every sent page the answer cites has a chip: \(links.chips.map(\.page))")
        require(links.unverified.isEmpty,
                "the mock provider cites only pages that were sent")
        require(links.chips.allSatisfy { !$0.snippet.isEmpty },
                "each chip carries a snippet of the passage that was sent")
        require(links.chips.allSatisfy { !$0.rects.isEmpty },
                "each chip carries the source geometry")

        // 2. Clicking a chip jumps to the page and flashes the source; nothing is saved.
        let chip = links.chips[0]
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        state.open(url: url)
        require(state.currentPage == 1, "the reader starts on page 1")
        let annotationsBefore = state.annotations
        let records = DocumentEditCache.annotationsURL(for: url)
        try? FileManager.default.removeItem(at: records)
        chip.follow(in: state)
        require(state.currentPage == chip.page,
                "the chip jumped to page \(chip.page) (current \(state.currentPage))")
        guard let highlight = state.aiSourceHighlight else {
            fatalError("clicking a chip did not set the transient source highlight")
        }
        require(highlight.page == chip.page - 1, "the highlight is on the cited page")
        require(!highlight.rects.isEmpty, "the highlight has the passage's line boxes")
        require(state.canvasPages.contains { PlacementIndex.isAISource($0.placement.index) },
                "the source boxes are drawn as transient canvas quads")
        require(state.annotations == annotationsBefore,
                "following a citation creates no annotation")
        require(!FileManager.default.fileExists(atPath: records.path),
                "following a citation writes no cached annotation")
        try await eventually("the source highlight disappears after the fade") {
            state.aiSourceHighlight == nil
        }
        require(!state.canvasPages.contains { PlacementIndex.isAISource($0.placement.index) },
                "the transient quads are removed with the highlight")
        require(state.annotations == annotationsBefore && !FileManager.default.fileExists(atPath: records.path),
                "the fade leaves no annotation or cached record behind")

        // 3. A second question carries the first exchange and its own retrieval.
        model.chatQuestion = "Which evaluation query set was replayed against the retrieval baseline?"
        await model.prepareDocumentChat(context: context)
        try await eventually("the second chat preview is built", {
            model.phase == .preview && model.plan?.historyTurns == 1
        })
        guard let secondPlan = model.plan else { fatalError("expected a second chat plan") }
        require(secondPlan.historyTurns == 1, "the second question includes one earlier turn")
        require(secondPlan.parts[0].userPrompt.contains(question),
                "the first question is in the second request's history")
        require(secondPlan.parts[0].userPrompt.contains(firstTurn.answer),
                "the first answer is in the second request's history")
        require(secondPlan.parts[0].userPrompt.contains("[Earlier conversation]"),
                "the preview labels the earlier conversation")
        let secondBodyObject = try JSONSerialization.jsonObject(
            with: Data(secondPlan.parts[0].wireBody.utf8)
        ) as? [String: Any]
        let secondMessages = secondBodyObject?["messages"] as? [[String: Any]]
        let secondUserContent = secondMessages?.last?["content"] as? String
        require(secondUserContent?.contains(firstTurn.answer) == true,
                "the exact body carries the earlier answer")
        model.send()
        try await eventually("the second chat answer finishes", {
            model.chatTurns.count == 2 && model.chatTurns.last?.state == .finished
        })
        require(model.chatTurns.first?.answer == firstTurn.answer,
                "the first answer stays visible after the second turn")

        // 4. A citation to a page that was not sent gets no chip and a stated reason.
        let unverifiedService = ScriptedAIChatService(
            engine: engine,
            events: [
                .partStarted(index: 0, total: 1, label: "Retrieved passages"),
                .delta("This is supported by [p.2] but also by [p.7]."),
                .done,
            ]
        )
        let unverifiedModel = AIAssistantModel(settings: fixture.store)
        unverifiedModel.attach(service: unverifiedService, context: context)
        unverifiedModel.chatQuestion = question
        await unverifiedModel.prepareDocumentChat(context: context)
        try await eventually("the unverified-citation preview is built", {
            unverifiedModel.phase == .preview && unverifiedModel.plan != nil
        })
        unverifiedModel.send()
        try await eventually("the unverified-citation answer finishes", {
            unverifiedModel.phase == .finished && unverifiedModel.chatTurns.last?.state == .finished
        })
        guard let unverifiedTurn = unverifiedModel.chatTurns.last,
              let unverifiedPlan = unverifiedModel.plan else {
            fatalError("expected the unverified-citation turn")
        }
        let unverifiedLinks = unverifiedTurn.backlinks(pageCount: 8)
        require(!unverifiedLinks.chips.contains(where: { $0.page == 7 }),
                "a citation to a page that was not sent produces no chip")
        require(unverifiedLinks.unverified.contains(where: {
            $0.page == 7 && $0.reason.contains("was not sent")
        }), "the panel states why [p.7] could not be verified: \(unverifiedLinks.unverified)")
        let renderedUnverified = AIAnswerMarkdown.parse(
            unverifiedTurn.answer,
            pageCount: 8,
            verifiedPages: unverifiedTurn.sentPages
        )
        require(!renderedUnverified.citedPages.contains(7),
                "an unverified citation is not linkified to a plausible page")
        require(renderedUnverified.citedPages.contains(2),
                "the verified citation in the same answer remains clickable")
        require(Set(unverifiedPlan.parts[0].pages.map(Int.init)).contains(2),
                "page 2 was actually sent")

        // 5. Empty retrieval answers honestly without building or starting a request.
        let requestsBeforeEmpty = recording.startedPlans.count
        let emptyModel = AIAssistantModel(settings: fixture.store)
        emptyModel.attach(service: recording, context: context)
        emptyModel.chatQuestion = "zzzz-quasar-xylophone"
        await emptyModel.prepareDocumentChat(context: context)
        try await eventually("the empty retrieval settles without a plan", {
            emptyModel.phase == .idle && emptyModel.chatTurns.count == 1
        })
        guard let emptyTurn = emptyModel.chatTurns.last else { fatalError("expected an empty-retrieval turn") }
        require(emptyTurn.state == .nothingRelevant, "the empty retrieval is a local answer")
        require(emptyTurn.answer.contains("Nothing in this document is relevant"),
                "the panel says nothing relevant was found: \(emptyTurn.answer)")
        require(emptyTurn.sources.isEmpty, "no passages were sent for the empty retrieval")
        require(emptyModel.plan == nil, "no request plan was built for the empty retrieval")
        require(recording.startedPlans.count == requestsBeforeEmpty,
                "the provider was not called for the empty retrieval")
        require((emptyModel.statusNote ?? "").contains("No request was sent"),
                "the status says no request was sent")

        // 6. Cancel keeps the partial answer and the question; Retry works on the same preview.
        let cancelModel = AIAssistantModel(settings: fixture.store)
        cancelModel.attach(service: recording, context: context)
        cancelModel.chatQuestion = question
        await cancelModel.prepareDocumentChat(context: context)
        try await eventually("the cancel fixture has a chat preview", {
            cancelModel.phase == .preview && cancelModel.plan != nil
        })
        cancelModel.send()
        try await eventually("the chat answer has started", {
            cancelModel.phase == .streaming
                && (cancelModel.chatTurns.last?.answer.isEmpty == false)
        })
        cancelModel.cancel()
        try await eventually("cancel settles the chat turn", {
            cancelModel.phase == .cancelled
                && cancelModel.chatTurns.last?.state == .cancelled
        })
        let partial = cancelModel.chatTurns.last?.answer ?? ""
        require(!partial.isEmpty, "cancel keeps the partial answer")
        require(cancelModel.chatTurns.last?.question == question,
                "cancel keeps the question with the partial answer")
        let startsBeforeRetry = recording.startedPlans.count
        cancelModel.retry()
        try await eventually("retry completes the cancelled chat answer", {
            cancelModel.phase == .finished
                && cancelModel.chatTurns.last?.state == .finished
                && (cancelModel.chatTurns.last?.answer.isEmpty == false)
        })
        require(recording.startedPlans.count == startsBeforeRetry + 1,
                "retry starts one more request for the same question")
        require(cancelModel.chatTurns.count == 1,
                "retry reuses the cancelled turn instead of duplicating the question")

        // 7. A provider error keeps the conversation readable and the next question works.
        let errorService = ScriptedAIChatService(
            engine: engine,
            events: [
                .partStarted(index: 0, total: 1, label: "Retrieved passages"),
                .delta("A partial answer [p.2]. "),
                .error(message: "The provider dropped the connection.", cancelled: false),
            ]
        )
        let errorModel = AIAssistantModel(settings: fixture.store)
        errorModel.attach(service: errorService, context: context)
        errorModel.chatQuestion = "What did the introduction say?"
        await errorModel.prepareDocumentChat(context: context)
        try await eventually("the error fixture has a preview", {
            errorModel.phase == .preview && errorModel.plan != nil
        })
        errorModel.send()
        try await eventually("the provider error settles the turn", {
            errorModel.phase == .failed && errorModel.chatTurns.last?.state == .failed
        })
        guard let failedTurn = errorModel.chatTurns.last else { fatalError("expected the failed turn") }
        require(failedTurn.question == "What did the introduction say?",
                "the failed turn keeps its question")
        require(failedTurn.answer.contains("A partial answer"),
                "the failed turn keeps its partial answer")
        require((failedTurn.error ?? "").contains("dropped the connection"),
                "the failed turn states the provider error")
        let failedTurnCount = errorModel.chatTurns.count
        let recovery = RecordingAIService(
            base: RustAIChatService(engine: engine, useMockProvider: true)
        )
        errorModel.attach(service: recovery, context: context)
        errorModel.chatQuestion = question
        await errorModel.prepareDocumentChat(context: context)
        try await eventually("the next question after an error has a preview", {
            errorModel.phase == .preview && errorModel.plan != nil
        })
        errorModel.send()
        try await eventually("the next question after an error finishes", {
            errorModel.chatTurns.count == failedTurnCount + 1
                && errorModel.chatTurns.last?.state == .finished
        })
        require(errorModel.chatTurns.first?.state == .failed,
                "the failed turn is still readable after the next answer")
        require(recovery.startedPlans.count == 1,
                "the next question after an error makes one request")

        // 8. The visible history is bounded, and switching documents swaps conversations.
        let boundedService = ScriptedAIChatService(
            engine: engine,
            events: [
                .partStarted(index: 0, total: 1, label: "Retrieved passages"),
                .delta("A short answer [p.2]."),
                .done,
            ]
        )
        let boundedModel = AIAssistantModel(settings: fixture.store)
        boundedModel.attach(service: boundedService, context: context)
        for index in 1...7 {
            boundedModel.chatQuestion = "\(question) vari\(index)"
            await boundedModel.prepareDocumentChat(context: context)
            try await eventually("bounded-history preview \(index)", {
                boundedModel.phase == .preview && boundedModel.plan != nil
            })
            boundedModel.send()
            try await eventually("bounded-history answer \(index)", {
                boundedModel.chatTurns.last?.state == .finished
            })
        }
        require(boundedModel.chatTurns.count == AIAssistantModel.chatTurnLimit,
                "the visible chat keeps exactly \(AIAssistantModel.chatTurnLimit) turns")
        require(boundedModel.chatTurns.first?.question.contains("vari2") == true,
                "the oldest turn was dropped")
        require(boundedModel.chatTurns.last?.question.contains("vari7") == true,
                "the newest turn is present")
        let otherContext = AIReaderContext(
            documentKey: "another-document-key",
            documentTitle: "Another paper",
            pageCount: 3,
            currentPage: 1,
            selection: nil
        )
        boundedModel.attach(service: boundedService, context: otherContext)
        require(boundedModel.chatTurns.isEmpty,
                "switching documents shows the other document's (empty) conversation")
        boundedModel.attach(service: boundedService, context: context)
        require(boundedModel.chatTurns.count == AIAssistantModel.chatTurnLimit,
                "switching back restores the first document's bounded conversation")

        print("AI-DOCCHAT pages=\(sentPages.sorted()) document_chars=\(preview.parts[0].pageCharacters) request_chars=\(preview.parts[0].requestCharacters) chips=\(links.chips.map(\.page))")
    }
}

// MARK: - Document chat layout at the panel's width limits

private struct DocumentChatPanelMeasurements {
    let hostBounds: CGRect
    let chat: CGRect
    let composer: CGRect
    let actions: CGRect
    let composerField: CGRect?
    let askButton: CGRect?
    let historyContentHeight: CGFloat
    let historyViewportHeight: CGFloat
    /// Page → chip frame, sorted top-to-bottom; the first occurrence of each page is kept.
    let chipFrames: [(page: Int, frame: CGRect)]
}

extension ReaderChecks {
    /// Host the real right-panel content at the panel's minimum and maximum content widths and
    /// measure the chat's AppKit frames. This is the narrow/wide acceptance evidence: the chat
    /// fills the remaining height, the composer stays usable, chips wrap (their height grows at
    /// 240 pt rather than their width clipping), and the history remains a scroll view whose
    /// content is taller than its viewport.
    @MainActor
    private static func aiDocumentChatLayoutChecks(root: URL) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-reader-docchat-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let url = scratch.appendingPathComponent("long-paper.pdf")
        try writeDocumentChatFixture(to: url)

        let engine = try RustEngine()
        _ = try engine.openDocument(at: url)
        let context = AIReaderContext(
            documentKey: url.standardizedFileURL.path,
            documentTitle: "Long paper",
            pageCount: 8,
            currentPage: 1,
            selection: nil
        )
        let fixture = makeSettings(key: "sk-docchat-layout")
        defer { fixture.cleanup() }
        require(fixture.store.save(
            baseURL: "http://127.0.0.1:11434/v1",
            model: "mock-model",
            temperature: 0.2,
            maxTokens: 900,
            apiKey: "sk-docchat-layout"
        ), "the layout fixture saves its provider")

        // Long answers with several short citations give the history enough content to scroll
        // and the chips a snippet that must wrap at 240 pt but not at 520 pt.
        let answer = "The spectral absorbance experiment measured every sample, and the retrieval "
            + "baseline improved recall on the evaluation query. "
            + String(repeating: "The result was checked against the baseline. ", count: 6)
            + " [p.2] [p.4] [p.6]"
        let service = ScriptedAIChatService(
            engine: engine,
            events: [
                .partStarted(index: 0, total: 1, label: "Retrieved passages"),
                .delta(answer),
                .done,
            ]
        )
        let model = AIAssistantModel(settings: fixture.store)
        model.attach(service: service, context: context)
        for index in 1...6 {
            model.chatQuestion = "How did the spectral absorbance experiment and the retrieval baseline change the evaluation query results? (\(index))"
            await model.prepareDocumentChat(context: context)
            try await eventually("layout chat preview \(index)", {
                model.phase == .preview && model.plan != nil
            })
            model.send()
            try await eventually("layout chat answer \(index)", {
                model.chatTurns.last?.state == .finished
            })
        }
        require(model.chatTurns.count == 6, "the layout fixture has six chat turns")

        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        require(state.open(url: url), "the layout fixture opens in the reader state")

        let narrow = try await measureDocumentChatPanel(
            state: state, model: model, width: ReaderSidePanelMetrics.minimumContentWidthPt
        )
        let wide = try await measureDocumentChatPanel(
            state: state, model: model, width: ReaderSidePanelMetrics.maximumContentWidthPt
        )

        for (label, measurement, expectedWidth) in [
            ("240 pt", narrow, ReaderSidePanelMetrics.minimumContentWidthPt),
            ("520 pt", wide, ReaderSidePanelMetrics.maximumContentWidthPt),
        ] {
            require(abs(measurement.chat.width - expectedWidth) < 1,
                    "\(label): the chat fills the panel width (\(measurement.chat.width) pt)")
            require(measurement.chat.height > 650,
                    "\(label): chat uses the full tab beneath the header (\(measurement.chat.height) pt)")
            require(measurement.actions == .zero,
                    "\(label): summary actions are absent from the Chat tab")
            require(measurement.chat.minX >= -0.5
                        && measurement.chat.maxX <= measurement.hostBounds.maxX + 0.5,
                    "\(label): the chat is not clipped horizontally")
            require(measurement.composer.width > 180 && measurement.composer.width <= expectedWidth + 0.5,
                    "\(label): the composer keeps a usable width (\(measurement.composer.width) pt)")
            require(measurement.composerField != nil,
                    "\(label): the composer has an editable text field")
            if let field = measurement.composerField {
                require(field.width > 120 && field.height > 0,
                        "\(label): the question field is usable (\(field.width)×\(field.height) pt)")
            }
            require(measurement.askButton != nil,
                    "\(label): the Ask button is present")
            require(measurement.historyViewportHeight > 0,
                    "\(label): the history has a scroll viewport")
            require(measurement.historyContentHeight > measurement.historyViewportHeight + 40,
                    "\(label): the history is scrollable when it overflows "
                        + "(\(measurement.historyContentHeight) content vs "
                        + "\(measurement.historyViewportHeight) viewport)")
            require(measurement.chipFrames.count >= 3,
                    "\(label): the answer shows citation chips")
            for (page, frame) in measurement.chipFrames {
                require(frame.width > 0 && frame.height > 0,
                        "\(label): chip p.\(page) has a laid-out frame")
                require(frame.maxX <= measurement.chat.maxX + 0.5,
                        "\(label): chip p.\(page) wraps inside the panel rather than crossing its edge "
                            + "(maxX \(frame.maxX) vs \(measurement.chat.maxX))")
            }
            let sorted = measurement.chipFrames.sorted { $0.frame.minY < $1.frame.minY }
            for pair in zip(sorted, sorted.dropFirst()) {
                require(pair.1.frame.minY >= pair.0.frame.maxY - 0.5,
                        "\(label): citation chips stack without clipping each other")
            }
        }

        let narrowChips = Dictionary(
            narrow.chipFrames.map { ($0.page, $0.frame.height) },
            uniquingKeysWith: { first, _ in first }
        )
        let wideChips = Dictionary(
            wide.chipFrames.map { ($0.page, $0.frame.height) },
            uniquingKeysWith: { first, _ in first }
        )
        for page in narrowChips.keys.sorted() {
            guard let narrowHeight = narrowChips[page], let wideHeight = wideChips[page] else { continue }
            require(narrowHeight >= wideHeight - 0.5,
                    "chip p.\(page) gets taller at 240 pt (\(narrowHeight)) than at 520 pt (\(wideHeight)) "
                        + "because its snippet wraps")
        }
        require(narrowChips.values.max() ?? 0 > (wideChips.values.max() ?? 0) + 4,
                "at least one snippet visibly wraps to more lines at 240 pt")

        print("AI-DOCCHAT-LAYOUT narrow=240 chat=\(narrow.chat.size) composer=\(narrow.composer.size) "
            + "chips=\(narrow.chipFrames.map { "\($0.page):\($0.frame.height)" }) "
            + "history=\(narrow.historyContentHeight)/\(narrow.historyViewportHeight) "
            + "wide=520 chat=\(wide.chat.size) composer=\(wide.composer.size) "
            + "chips=\(wide.chipFrames.map { "\($0.page):\($0.frame.height)" }) "
            + "history=\(wide.historyContentHeight)/\(wide.historyViewportHeight)")
    }

    @MainActor
    private static func measureDocumentChatPanel(
        state: AppState,
        model: AIAssistantModel,
        width: CGFloat
    ) async throws -> DocumentChatPanelMeasurements {
        model.selectedTab = .chat
        model.expandedChatSources = Set(model.chatTurns.map(\.id))
        let host = NSHostingView(rootView: AIAssistantRightPanelContent(state: state, model: model))
        let container = NSView(frame: CGRect(x: 0, y: 0, width: width, height: 800))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: width, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = container
        window.setContentSize(NSSize(width: width, height: 800))
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()
        require(abs(host.bounds.height - 800) < 1,
                "the layout host keeps the requested 800 pt height (got \(host.bounds.height))")

        guard let chatMarker = findView(AIDocumentChatMarkerView.self, in: host),
              let composerMarker = findView(AIDocumentChatComposerMarkerView.self, in: host) else {
            fatalError("FAIL: the hosted Chat tab is missing its chat or composer")
        }
        let chat = host.convert(chatMarker.bounds, from: chatMarker)
        let composer = host.convert(composerMarker.bounds, from: composerMarker)
        let actions = findView(AIAssistantPanelMarkerView.self, in: host)
            .map { host.convert($0.bounds, from: $0) } ?? .zero
        let composerFrame = host.convert(composerMarker.bounds, from: composerMarker)
        let fields = findViews(NSTextField.self, in: host)
            .filter {
                !$0.isHidden && $0.frame.width > 1
                    && host.convert($0.bounds, from: $0).intersects(composerFrame)
            }
        let buttons = findViews(NSButton.self, in: host)
            .filter {
                !$0.isHidden && host.convert($0.bounds, from: $0).intersects(composerFrame)
            }
        let history = findViews(NSScrollView.self, in: host)
            .filter { host.convert($0.bounds, from: $0).intersects(chat.insetBy(dx: -1, dy: -1)) }
            .max { lhs, rhs in
                host.convert(lhs.bounds, from: lhs).height
                    < host.convert(rhs.bounds, from: rhs).height
            }
        let chipMarkers = findViews(AIDocumentChatChipMarkerView.self, in: host)
            .map { ($0.page, host.convert($0.bounds, from: $0)) }
            .filter { $0.1.intersects(chat.insetBy(dx: -1, dy: -1)) }
            .sorted { $0.1.minY < $1.1.minY }
        var seenPages: Set<Int> = []
        let firstChipPerPage = chipMarkers.filter { seenPages.insert($0.0).inserted }
        let measurement = DocumentChatPanelMeasurements(
            hostBounds: host.bounds,
            chat: chat,
            composer: composer,
            actions: actions,
            composerField: fields.first.map { host.convert($0.bounds, from: $0) },
            askButton: findView(AIDocumentChatAskMarkerView.self, in: host)
                .map { host.convert($0.bounds, from: $0) }
                ?? buttons.first.map { host.convert($0.bounds, from: $0) },
            historyContentHeight: history?.documentView?.frame.height ?? 0,
            historyViewportHeight: history?.contentView.bounds.height ?? 0,
            chipFrames: firstChipPerPage.map { (page: $0.0, frame: $0.1) }
        )
        model.expandedChatSources = []
        let turnsBefore = model.chatTurns.count
        let languageBefore = model.targetLanguage
        for tab in AIAssistantTab.allCases {
            model.selectedTab = tab
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            if tab == .regions {
                require(findView(AIDocumentChatMarkerView.self, in: host) == nil,
                        "Regions has its own workspace without a stacked chat")
            } else if tab != .chat {
                require(findView(AIDocumentChatMarkerView.self, in: host) == nil,
                        "\(tab.title) has its own workspace without a stacked chat")
                require(findView(AIAssistantPanelMarkerView.self, in: host) != nil,
                        "\(tab.title) hosts the task controls")
            }
            if let directory = ProcessInfo.processInfo.environment["LYRA_AI_EVIDENCE"],
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent("ai-\(tab.rawValue)-\(Int(width)).png"))
            }
        }
        require(model.chatTurns.count == turnsBefore && model.targetLanguage == languageBefore,
                "switching AI tabs preserves conversation and translation inputs")
        return measurement
    }

    @MainActor
    private static func findView<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let found = view as? T { return found }
        for subview in view.subviews {
            if let found = findView(type, in: subview) { return found }
        }
        return nil
    }

    @MainActor
    private static func findViews<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        if let value = view as? T { found.append(value) }
        for subview in view.subviews {
            found.append(contentsOf: findViews(type, in: subview))
        }
        return found
    }
}

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
