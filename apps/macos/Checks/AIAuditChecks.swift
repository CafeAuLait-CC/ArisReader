import AppKit
import Foundation
import LyraReaderKit
import LyraReaderBindings
import SwiftUI

// AI audit-trail checks. Every request uses the Rust mock provider: no check in this file opens
// a socket. The audit trail is always redirected to a per-check temporary directory, so a run
// never reads or writes the person's application cache.

@MainActor
private final class AuditRecordingService: AIChatServicing {
    let base: RustAIChatService
    private(set) var prepareCount = 0
    private(set) var startCount = 0

    init(engine: RustEngine) {
        self.base = RustAIChatService(engine: engine, useMockProvider: true)
    }

    func prepare(_ request: AIMakePlanRequest) async throws -> AiPlanRecord {
        prepareCount += 1
        return try await base.prepare(request)
    }

    func prepareMerge(_ request: AIMergePlanRequest) async throws -> AiPlanRecord {
        try await base.prepareMerge(request)
    }

    func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle {
        startCount += 1
        return try base.start(plan, apiKey: apiKey)
    }
}

@MainActor
private final class AuditFailingHandle: AIChatHandle {
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

/// Uses the production planner, then scripts the stream. This is how the failed outcome is
/// exercised without inventing a plan the preview did not build.
@MainActor
private final class AuditFailingService: AIChatServicing {
    let base: RustAIChatService
    private let events: [AIStreamEvent]

    init(engine: RustEngine, events: [AIStreamEvent]) {
        self.base = RustAIChatService(engine: engine, useMockProvider: true)
        self.events = events
    }

    func prepare(_ request: AIMakePlanRequest) async throws -> AiPlanRecord {
        try await base.prepare(request)
    }

    func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle {
        AuditFailingHandle(events: events)
    }
}

@MainActor
private final class AuditScriptedService: AIChatServicing {
    let plan: AiPlanRecord
    let events: [AIStreamEvent]
    private(set) var startedPlans: [AiPlanRecord] = []

    init(plan: AiPlanRecord, events: [AIStreamEvent]) {
        self.plan = plan
        self.events = events
    }

    func prepare(_ request: AIMakePlanRequest) async throws -> AiPlanRecord { plan }

    func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle {
        startedPlans.append(plan)
        return AuditScriptedHandle(events: events)
    }
}

@MainActor
private final class AuditScriptedHandle: AIChatHandle {
    private var events: [AIStreamEvent]
    private var finished = false

    init(events: [AIStreamEvent]) { self.events = events }

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

private struct AuditSettingsFixture {
    let suiteName: String
    let defaults: UserDefaults
    let store: AISettingsStore

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

extension ReaderChecks {
    /// Audit-trail regressions. Called with the mock provider only.
    @MainActor
    static func aiAuditChecks(root: URL) async throws {
        try await auditSummaryAndRegionChecks(root: root)
        try await auditRefusalChecks(root: root)
        try await auditCancelledAndFailedChecks(root: root)
        try await auditTornPageRegionChecks(root: root)
        try await auditMultiPartPlanChecks(root: root)
        try await auditLayeredSummaryBatchChecks(root: root)
        try await auditStorageChecks()
        try await auditClearChecks()
        try await auditPanelMinimumWidthCheck(root: root)
        try await auditInventoryChecks(root: root)
    }

    // MARK: - Fixtures

    @MainActor
    private static func makeAuditSettings(
        key: String? = "sk-audit-check-not-real",
        baseURL: String = "http://127.0.0.1:11434/v1",
        storedBaseURL: String? = nil,
        vision: Bool = false
    ) -> AuditSettingsFixture {
        let suiteName = "lyra-reader-audit-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        if let storedBaseURL {
            defaults.set(storedBaseURL, forKey: AISettingsStore.baseURLKey)
        }
        let keyStore = InMemoryAPIKeyStore(key: key)
        let store = AISettingsStore(defaults: defaults, keyStore: keyStore)
        if storedBaseURL == nil {
            _ = store.save(
                baseURL: baseURL,
                model: "mock-model",
                temperature: 0.2,
                maxTokens: 900,
                apiKey: key,
                reasoningMode: .off,
                reasoningEncoding: .thinking,
                modelAcceptsImages: vision
            )
        }
        return AuditSettingsFixture(suiteName: suiteName, defaults: defaults, store: store)
    }

    @MainActor
    private static func makeAuditDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-audit-\(UUID().uuidString)", isDirectory: true)
    }

    @MainActor
    private static func removeAuditDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Opens the multi-page text fixture and returns its local AI context.
    @MainActor
    private static func openAuditDocument(root: URL) throws -> (RustEngine, AppState, AIReaderContext) {
        let engine = try RustEngine()
        let state = AppState(engine: engine)
        state.setViewportSize(CGSize(width: 1000, height: 800))
        let fixture = root.appendingPathComponent("tests/fixtures/text-page.pdf")
        require(state.open(url: fixture), "the audit fixture opens")
        state.reloadVisiblePages()
        guard let context = state.aiReaderContext else {
            fatalError("FAIL: the audit fixture has an AI reader context")
        }
        return (engine, state, context)
    }

    private static func uniquePages(_ plan: AiPlanRecord) -> [Int] {
        Array(Set(plan.parts.flatMap { $0.pages.map(Int.init) })).sorted()
    }

    private static func planCharacters(_ plan: AiPlanRecord) -> Int {
        plan.parts.reduce(0) { $0 + Int($1.requestCharacters) }
    }

    @MainActor
    private static func writeAuditFile(_ trail: AIAuditTrail) -> Data {
        (try? Data(contentsOf: trail.fileURL)) ?? Data()
    }

    private static func dataContains(_ data: Data, _ string: String) -> Bool {
        data.range(of: Data(string.utf8)) != nil
    }

    // MARK: - One record per attempt

    @MainActor
    private static func auditSummaryAndRegionChecks(root: URL) async throws {
        let settingsFixture = makeAuditSettings(vision: false)
        defer { settingsFixture.cleanup() }
        let directory = makeAuditDirectory()
        defer { removeAuditDirectory(directory) }
        let trail = AIAuditTrail(directory: directory)
        let (engine, _, context) = try openAuditDocument(root: root)
        let service = AuditRecordingService(engine: engine)
        let model = AIAssistantModel(settings: settingsFixture.store, audit: trail)
        model.attach(service: service, context: context)

        // 1. One page-summary request.
        await model.prepare(action: .summarizePage, context: context)
        guard model.phase == .preview, let summaryPlan = model.plan else {
            fatalError("FAIL: the summary preview was built: \(model.errorMessage ?? "nil")")
        }
        let expectedSummaryCharacters = planCharacters(summaryPlan)
        let expectedSummaryPages = uniquePages(summaryPlan)
        let summaryPrompt = summaryPlan.parts.first?.userPrompt ?? ""
        require(expectedSummaryPages == [1], "the page summary is about page 1")
        model.send()
        try await eventually("the summary attempt records exactly one entry", {
            trail.records.count == 1 && model.phase == .finished
        })
        guard trail.records.count == 1 else {
            fatalError("FAIL: expected one audit record, got \(trail.records.count)")
        }
        let summary = trail.records[0]
        require(summary.action == .summarise, "the summary entry has the summarise kind")
        require(summary.outcome == .sent, "the summary entry says it was sent")
        require(summary.pages == expectedSummaryPages,
                "the summary entry names the pages: \(summary.pages) vs \(expectedSummaryPages)")
        require(summary.characters == expectedSummaryCharacters,
                "the summary entry counts the request characters: \(summary.characters) vs \(expectedSummaryCharacters)")
        require(summary.image == nil, "a page summary records no image")
        require(summary.host == "127.0.0.1", "the entry records the endpoint host only: \(summary.host)")
        require(summary.model == "mock-model", "the entry records the model name")
        require(summary.code == nil, "a sent request has no error code")
        require(summary.durationMilliseconds >= 0, "a sent request records a duration")

        // 2. One region question with a picture.
        require(settingsFixture.store.save(
            baseURL: "http://127.0.0.1:11434/v1",
            model: "mock-model",
            temperature: 0.2,
            maxTokens: 900,
            apiKey: nil,
            reasoningMode: .off,
            reasoningEncoding: .thinking,
            modelAcceptsImages: true
        ), "the vision configuration saves for the audit check")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lK3V0wAAAABJRU5ErkJggg==")!
        let attachment = AIRegionAttachment(
            page: 0,
            rect: CGRect(x: 10, y: 10, width: 40, height: 30),
            text: "Region text for the audit check.",
            png: png,
            pixelWidth: 1,
            pixelHeight: 1,
            captureScale: 2
        )
        let question = "What does this region show?"
        await model.prepareRegion(question: question, attachment: attachment, context: context)
        guard model.phase == .preview, let regionPlan = model.plan else {
            fatalError("FAIL: the region preview was built: \(model.errorMessage ?? "nil")")
        }
        require(regionPlan.parts.first?.wireBody.contains("image_url") == true,
                "the region request carries the picture")
        require(planCharacters(regionPlan) > 0, "the region request has characters")
        model.send()
        try await eventually("the region attempt records exactly one entry", {
            trail.records.count == 2 && model.phase == .finished
        })
        guard trail.records.count == 2 else {
            fatalError("FAIL: expected two audit records, got \(trail.records.count)")
        }
        let region = trail.records[0]
        require(region.action == .regionQuestion, "the region entry has the region-question kind")
        require(region.outcome == .sent, "the region entry says it was sent")
        require(region.pages == [1], "the region entry names its page")
        require(region.characters == planCharacters(regionPlan),
                "the region entry counts the request characters")
        require(region.image == AIAuditImage(widthPixels: 1, heightPixels: 1),
                "the region entry records the picture's pixel size: \(String(describing: region.image))")

        // 3. The file contains counts and identifiers, never the fixture's content.
        let raw = writeAuditFile(trail)
        require(!raw.isEmpty, "the audit file has bytes to inspect")
        let fixturePath = root.appendingPathComponent("tests/fixtures/text-page.pdf").path
        let forbidden = [
            fixturePath,
            "text-page",
            question,
            "Region text for the audit check.",
            "Nothing is sent before the reader confirms the preview.",
            "Retrieval runs on this machine.",
        ]
        for string in forbidden {
            require(!dataContains(raw, string),
                    "the audit file contains no trace of \"\(string.prefix(48))\"")
        }
        // Distinctive words from the document's own extracted text, taken from the summary
        // request the preview showed. The audit file must not contain them either.
        if let marker = summaryPrompt.range(of: "[Page 1]") {
            let pageText = summaryPrompt[marker.upperBound...]
            let documentWords = pageText.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= 6 }
            require(!documentWords.isEmpty, "the fixture page has words to search for")
            for word in documentWords.prefix(6) {
                require(!dataContains(raw, word),
                        "the audit file contains no document word (\"\(word)\")")
            }
        }
        require(dataContains(raw, "region_question"), "the audit file names the action kind")

        // Both connections carry the same capture. The ChatGPT plan transport rebuilds the
        // wire body as the documented Responses content parts; the inventory and the audit
        // record must agree with that, so both are asserted against the converted plan.
        let convertedForChatGPT = try ChatGPTResponses.plan(regionPlan)
        require(convertedForChatGPT.parts.first?.image != nil,
                "the ChatGPT plan carries the exact picture record")
        require(convertedForChatGPT.parts.first?.wireBody.contains("input_image") == true,
                "the ChatGPT wire body carries the picture as an input_image part")
        let convertedBody = convertedForChatGPT.parts.first?.wireBody ?? ""
        require(convertedBody.contains("base64,") && convertedBody.contains("input_image"),
                "the ChatGPT picture is an inline base64 image part")
        require(convertedBody.contains(String(png.base64EncodedString().prefix(16))),
                "the ChatGPT body carries the exact captured PNG bytes, not a re-encoding")
        require(AIAuditPanelCopy.whatIsSent.contains(where: { $0.contains("both connections") }),
                "the inventory says both connections carry the same picture")
        require(!AIAuditPanelCopy.neverSent.contains(where: { $0.contains("text-only") }),
                "the inventory no longer calls any connection text-only")
    }

    // MARK: - Refusals

    @MainActor
    private static func auditRefusalChecks(root: URL) async throws {
        let (engine, _, context) = try openAuditDocument(root: root)

        // No configured endpoint: the local settings validator refuses before any preview.
        let missingEndpoint = makeAuditSettings(storedBaseURL: "")
        defer { missingEndpoint.cleanup() }
        let noEndpointDirectory = makeAuditDirectory()
        defer { removeAuditDirectory(noEndpointDirectory) }
        let noEndpointTrail = AIAuditTrail(directory: noEndpointDirectory)
        let noEndpointService = AuditRecordingService(engine: engine)
        let noEndpointModel = AIAssistantModel(settings: missingEndpoint.store, audit: noEndpointTrail)
        noEndpointModel.attach(service: noEndpointService, context: context)
        require(missingEndpoint.store.endpointInfo == nil, "the no-endpoint fixture has no valid endpoint")
        await noEndpointModel.prepare(action: .summarizePage, context: context)
        require(noEndpointModel.phase == .failed, "the no-endpoint request stops before preview")
        require(noEndpointService.startCount == 0, "the no-endpoint refusal starts no request")
        require(noEndpointTrail.records.count == 1,
                "the no-endpoint refusal records exactly one entry")
        let refused = noEndpointTrail.records[0]
        require(refused.outcome == .refused, "the no-endpoint entry is refused")
        require(refused.code == .noEndpoint, "the no-endpoint entry says why: \(String(describing: refused.code))")
        require(refused.characters == 0 && refused.pages.isEmpty,
                "a refusal records no characters and no pages")
        require(refused.action == .summarise, "the refusal keeps the action kind")

        // Unsigned in: ChatGPT mode with no connected account.
        let signedOut = makeAuditSettings()
        defer { signedOut.cleanup() }
        signedOut.store.connectionMode = .chatGPT
        let signedOutDirectory = makeAuditDirectory()
        defer { removeAuditDirectory(signedOutDirectory) }
        let signedOutTrail = AIAuditTrail(directory: signedOutDirectory)
        let signedOutService = AuditRecordingService(engine: engine)
        let signedOutModel = AIAssistantModel(settings: signedOut.store, audit: signedOutTrail)
        signedOutModel.attach(service: signedOutService, context: context)
        await signedOutModel.prepare(action: .summarizeDocument, context: context)
        require(signedOutModel.phase == .failed, "the signed-out request stops before preview")
        require(signedOutService.startCount == 0, "the signed-out refusal starts no request")
        require(signedOutTrail.records.count == 1, "the signed-out refusal records exactly one entry")
        require(signedOutTrail.records[0].outcome == .refused, "the signed-out entry is refused")
        require(signedOutTrail.records[0].code == .signedOut,
                "the signed-out entry says why: \(String(describing: signedOutTrail.records[0].code))")

        // Vision unsupported: a picture-only region with image input off refuses locally.
        let noVision = makeAuditSettings(vision: false)
        defer { noVision.cleanup() }
        let noVisionDirectory = makeAuditDirectory()
        defer { removeAuditDirectory(noVisionDirectory) }
        let noVisionTrail = AIAuditTrail(directory: noVisionDirectory)
        let noVisionService = AuditRecordingService(engine: engine)
        let noVisionModel = AIAssistantModel(settings: noVision.store, audit: noVisionTrail)
        noVisionModel.attach(service: noVisionService, context: context)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lK3V0wAAAABJRU5ErkJggg==")!
        let pictureOnly = AIRegionAttachment(
            page: 0,
            rect: CGRect(x: 10, y: 10, width: 40, height: 30),
            text: "",
            png: png,
            pixelWidth: 1,
            pixelHeight: 1,
            captureScale: 2
        )
        await noVisionModel.prepareRegion(
            question: "What is in this picture?",
            attachment: pictureOnly,
            context: context
        )
        require(noVisionModel.phase == .failed, "the vision-unsupported region stops before preview")
        require(noVisionService.startCount == 0, "the vision-unsupported refusal starts no request")
        require(noVisionTrail.records.count == 1,
                "the vision-unsupported refusal records exactly one entry")
        require(noVisionTrail.records[0].outcome == .refused, "the vision-unsupported entry is refused")
        require(noVisionTrail.records[0].code == .visionUnsupported,
                "the vision-unsupported entry says why: \(String(describing: noVisionTrail.records[0].code))")

        // The key disappears between preview and Send: the start hook refuses and still records.
        let deletedKey = makeAuditSettings()
        defer { deletedKey.cleanup() }
        let deletedKeyDirectory = makeAuditDirectory()
        defer { removeAuditDirectory(deletedKeyDirectory) }
        let deletedKeyTrail = AIAuditTrail(directory: deletedKeyDirectory)
        let deletedKeyService = AuditRecordingService(engine: engine)
        let deletedKeyModel = AIAssistantModel(settings: deletedKey.store, audit: deletedKeyTrail)
        deletedKeyModel.attach(service: deletedKeyService, context: context)
        await deletedKeyModel.prepare(action: .summarizePage, context: context)
        require(deletedKeyModel.phase == .preview, "the deleted-key preview is built first")
        require(deletedKey.store.clearKey(), "the key is cleared after the preview")
        deletedKeyModel.send()
        require(deletedKeyModel.phase == .failed, "the send refuses without a key")
        require(deletedKeyService.startCount == 0, "the refused send reaches no transport")
        require(deletedKeyTrail.records.count == 1, "the refused send records exactly one entry")
        require(deletedKeyTrail.records[0].outcome == .refused, "the refused send is marked refused")
        require(deletedKeyTrail.records[0].code == .noApiKey,
                "the refused send names the missing key: \(String(describing: deletedKeyTrail.records[0].code))")
    }

    // MARK: - Cancelled and failed

    @MainActor
    private static func auditCancelledAndFailedChecks(root: URL) async throws {
        let (engine, _, context) = try openAuditDocument(root: root)

        // Cancel while the mock stream is running.
        let cancelFixture = makeAuditSettings()
        defer { cancelFixture.cleanup() }
        let cancelDirectory = makeAuditDirectory()
        defer { removeAuditDirectory(cancelDirectory) }
        let cancelTrail = AIAuditTrail(directory: cancelDirectory)
        let cancelService = AuditRecordingService(engine: engine)
        let cancelModel = AIAssistantModel(settings: cancelFixture.store, audit: cancelTrail)
        cancelModel.attach(service: cancelService, context: context)
        await cancelModel.prepare(action: .summarizePage, context: context)
        require(cancelModel.phase == .preview, "the cancelled request has a preview")
        cancelModel.send()
        try await Task.sleep(for: .milliseconds(120))
        cancelModel.cancel()
        try await eventually("the cancelled request reaches a terminal state", {
            cancelModel.phase == .cancelled && cancelTrail.records.count == 1
        })
        let cancelled = cancelTrail.records[0]
        require(cancelled.outcome == .cancelled, "the cancelled entry says cancelled")
        require(cancelled.code == nil, "a cancellation carries no error code")
        require(cancelled.durationMilliseconds >= 80,
                "the cancelled entry keeps its duration: \(cancelled.durationMilliseconds) ms")
        require(cancelled.characters > 0, "a started request records the characters it began to send")

        // A transport error after the first part started.
        let failFixture = makeAuditSettings()
        defer { failFixture.cleanup() }
        let failDirectory = makeAuditDirectory()
        defer { removeAuditDirectory(failDirectory) }
        let failTrail = AIAuditTrail(directory: failDirectory)
        let failService = AuditFailingService(engine: engine, events: [
            .partStarted(index: 0, total: 1, label: "Page 1"),
            .error(message: "HTTP 500 from the provider.", cancelled: false),
        ])
        let failModel = AIAssistantModel(settings: failFixture.store, audit: failTrail)
        failModel.attach(service: failService, context: context)
        await failModel.prepare(action: .summarizePage, context: context)
        require(failModel.phase == .preview, "the failed request has a preview")
        let failedPlan = failModel.plan
        failModel.send()
        try await eventually("the failed request reaches a terminal state", {
            failModel.phase == .failed && failTrail.records.count == 1
        })
        let failed = failTrail.records[0]
        require(failed.outcome == .failed, "the failed entry says failed")
        require(failed.code == .httpError, "the failed entry keeps the error category: \(String(describing: failed.code))")
        require(failed.characters == (failedPlan.map(planCharacters) ?? -1),
                "the failed entry counts the part that had started")
        require(failed.durationMilliseconds >= 0, "the failed entry records a duration")
        require(!dataContains(writeAuditFile(failTrail), "HTTP 500 from the provider."),
                "the failed entry never stores the provider's message")
    }

    // MARK: - A torn page still audits page numbers, not display segments

    /// The inside-page tear (#133) lays one document page out as two display segments. An AI
    /// plan is still built from the document page, so the audit record must name the page once,
    /// and a region question opened against the torn page must produce exactly one entry when
    /// the reader sends it once.
    @MainActor
    private static func auditTornPageRegionChecks(root: URL) async throws {
        let settingsFixture = makeAuditSettings(vision: false)
        defer { settingsFixture.cleanup() }
        let directory = makeAuditDirectory()
        defer { removeAuditDirectory(directory) }
        let trail = AIAuditTrail(directory: directory)
        let engine = try RustEngine()
        let state = AppState(engine: engine)
        state.setViewportSize(CGSize(width: 1000, height: 800))
        let fixture = root.appendingPathComponent("tests/fixtures/text-page.pdf")
        require(state.open(url: fixture), "the torn-page audit fixture opens")
        state.reloadVisiblePages()
        state.regionAssistantFactory = {
            AIAssistantModel(settings: settingsFixture.store, audit: trail)
        }
        state.regionChatServiceOverride = {
            RustAIChatService(engine: engine, useMockProvider: true)
        }
        let rect = CGRect(x: 60, y: 60, width: 360, height: 180)
        await state.createRegionCard(page: 0, rect: rect)
        guard let card = state.regionCards.first, let context = state.aiReaderContext else {
            fatalError("FAIL: the torn-page region card was created: \(state.regionRefusalMessage ?? "no reason")")
        }
        require(card.attachment.page == 0, "the region attachment names the document page, not a segment")
        require(card.tearSplitPt != nil,
                "the region card really tears the page: \(String(describing: card.tearSplitPt))")
        require(state.pageSegments(forPage: 0).count == 2,
                "the torn page really is two display segments")
        let tear = state.pageTear(forPage: 0)
        require(tear?.page == 0, "the tear itself is identified by page index")

        card.question = "What does the torn region say?"
        await card.assistant.prepareRegion(
            question: card.question,
            attachment: card.attachment,
            context: context
        )
        guard card.assistant.phase == .preview, let plan = card.assistant.plan else {
            fatalError("FAIL: the torn-page region preview was built: \(card.assistant.errorMessage ?? "nil")")
        }
        require(plan.parts.count == 1, "the torn page still plans one request part")
        require(plan.parts.first?.pages == [1],
                "the plan names the document page once, not the two display segments: \(String(describing: plan.parts.first?.pages))")
        require(plan.sourcePages == [1],
                "the plan's source pages are the document page: \(plan.sourcePages)")
        require(card.assistant.requestCount == 1,
                "the panel offers one Send for the torn-page region")
        card.assistant.send()
        try await eventually("the torn-page region records exactly one entry", {
            trail.records.count == 1 && card.assistant.phase == .finished
        })
        guard trail.records.count == 1 else {
            fatalError("FAIL: expected one torn-page audit record, got \(trail.records.count)")
        }
        let record = trail.records[0]
        require(record.action == .regionQuestion, "the torn-page entry is a region question")
        require(record.pages == [1],
                "the audit entry names page 1 once, not a display segment: \(record.pages)")
        require(record.outcome == .sent, "the torn-page region entry says it was sent")
        require(dataContains(writeAuditFile(trail), "region_question"),
                "the torn-page record carries the action kind, not display geometry")
    }

    // MARK: - One record per outgoing request, not per plan or batch

    /// A multi-part plan is several outgoing requests. The audit must write one record per part
    /// (with that part's pages and characters), not one aggregate line for the plan.
    @MainActor
    private static func auditMultiPartPlanChecks(root: URL) async throws {
        let fixture = makeAuditSettings()
        defer { fixture.cleanup() }
        let directory = makeAuditDirectory()
        defer { removeAuditDirectory(directory) }
        let trail = AIAuditTrail(directory: directory)
        let baseURL = "http://127.0.0.1:11434/v1"
        func part(_ index: UInt32, label: String, primary: UInt32, pages: [UInt32],
                  characters: UInt64) -> AiPlanPartRecord {
            AiPlanPartRecord(
                index: index,
                total: 2,
                label: label,
                primaryPage: primary,
                pages: pages,
                pageCharacters: characters,
                requestCharacters: characters,
                systemPrompt: "system",
                userPrompt: "part \(index + 1)",
                wireBody: "{\"stream\":true}",
                note: nil,
                image: nil
            )
        }
        let plan = AiPlanRecord(
            action: .summarizePage,
            actionLabel: "Summarise page",
            documentTitle: "Synthetic multi-part plan",
            pageCount: 3,
            baseUrl: baseURL,
            endpoint: baseURL + "/chat/completions",
            host: "127.0.0.1",
            isLocal: true,
            model: "mock-model",
            temperature: 0.2,
            maxTokens: 900,
            parts: [
                part(0, label: "Pages 1-2", primary: 1, pages: [1, 2], characters: 200),
                part(1, label: "Page 3", primary: 3, pages: [3], characters: 50),
            ],
            sourcePages: [1, 2, 3],
            note: "split into two parts",
            sources: [],
            historyTurns: 0,
            previewHeaders: [],
            estimatedTokens: 100
        )
        let service = AuditScriptedService(plan: plan, events: [
            .partStarted(index: 0, total: 2, label: "Pages 1-2"),
            .delta("Part one."),
            .partStarted(index: 1, total: 2, label: "Page 3"),
            .delta("Part two."),
            .done,
        ])
        let model = AIAssistantModel(settings: fixture.store, audit: trail)
        let context = AIReaderContext(
            documentKey: "audit-multi-part",
            documentTitle: "Synthetic multi-part plan",
            pageCount: 3,
            currentPage: 1,
            selection: nil
        )
        model.attach(service: service, context: context)
        await model.prepare(action: .summarizePage, context: context)
        require(model.phase == .preview, "the multi-part plan has a preview")
        model.send()
        try await eventually("the multi-part plan writes one record per part", {
            trail.records.count == 2 && model.phase == .finished
        })
        require(trail.records.count == 2,
                "a two-part plan writes two audit records, not one: \(trail.records.count)")
        let ordered = trail.records.sorted { ($0.pages.first ?? 0) < ($1.pages.first ?? 0) }
        require(ordered.map(\.pages) == [[1, 2], [3]],
                "each record names only its own part's pages: \(ordered.map(\.pages))")
        require(ordered.map(\.characters) == [200, 50],
                "each record keeps its own part's character count: \(ordered.map(\.characters))")
        require(ordered.allSatisfy { $0.action == .summarise && $0.outcome == .sent },
                "each part record has the action kind and its own sent outcome")
    }

    /// The layered-summary Generate batch previews up to 24 independent requests and sends at
    /// most two in flight. Each is a separate outgoing request, so the audit must write one
    /// record per row request — not one line for the batch and not one line per outline section
    /// group. This check uses the pages layer of the three-page outlined fixture: 3 requests.
    @MainActor
    private static func auditLayeredSummaryBatchChecks(root: URL) async throws {
        let fixture = makeAuditSettings()
        defer { fixture.cleanup() }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-audit-layered-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let documentURL = scratch.appendingPathComponent("outlined.pdf")
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("tests/fixtures/outlined.pdf"),
            to: documentURL
        )
        let directory = makeAuditDirectory()
        defer { removeAuditDirectory(directory) }
        let trail = AIAuditTrail(directory: directory)
        let engine = try RustEngine()
        let document = try engine.openDocument(at: documentURL)
        let outline = try await engine.outline()
        let context = AIReaderContext(
            documentKey: documentURL.standardizedFileURL.path,
            documentTitle: document.title,
            pageCount: document.pageCount,
            currentPage: 1,
            selection: nil
        )
        let model = LayeredSummaryModel(settings: fixture.store, audit: trail)
        model.attach(
            service: RustAIChatService(engine: engine, useMockProvider: true),
            context: context,
            outline: outline,
            documentURL: documentURL
        )
        try await eventually("the layered summary rows are inspected", {
            !model.isRefreshing && !model.entries(for: .pages).isEmpty
                && model.entries(for: .pages).allSatisfy { !$0.textHash.isEmpty }
        })
        await model.prepare(.pages)
        try await eventually("the page-layer batch is previewed", {
            model.phase == .preview && model.batchRequests == 3
        })
        require(trail.records.isEmpty, "building the layered preview records nothing")
        model.send()
        try await eventually("the layered batch writes one record per request", {
            model.phase == .finished && trail.records.count == 3
        })
        require(trail.records.count == 3,
                "a three-request batch writes three audit records, not one: \(trail.records.count)")
        let ordered = trail.records.sorted { ($0.pages.first ?? 0) < ($1.pages.first ?? 0) }
        require(ordered.map(\.pages) == [[1], [2], [3]],
                "each layered batch record names its own page: \(ordered.map(\.pages))")
        require(trail.records.allSatisfy { $0.action == .summaryLayer },
                "layered-summary requests use the summary-layer action kind")
        require(trail.records.allSatisfy { $0.outcome == .sent && $0.characters > 0 },
                "each layered batch record is sent with its own character count")
        require(trail.records.allSatisfy { $0.host == "127.0.0.1" && $0.model == "mock-model" },
                "each layered batch record names the endpoint and model")
    }

    // MARK: - Storage bounds

    @MainActor
    private static func auditStorageChecks() async throws {
        // Count bound at the production constants.
        let directory = makeAuditDirectory()
        defer { removeAuditDirectory(directory) }
        let trail = AIAuditTrail(directory: directory)
        require(AIAuditTrail.maximumRecords == 500, "the stated record bound is 500")
        let total = AIAuditTrail.maximumRecords + 5
        for index in 0..<total {
            trail.append(AIAuditRecord(
                at: Date(timeIntervalSince1970: Double(index)),
                action: .summarise,
                host: "audit.example",
                model: "mock-model",
                characters: index,
                pages: [index + 1],
                image: nil,
                outcome: .sent,
                code: nil,
                durationMilliseconds: 1
            ))
        }
        require(trail.records.count == AIAuditTrail.maximumRecords,
                "rotation keeps exactly the stated number of records: \(trail.records.count)")
        require(trail.records.first?.characters == total - 1, "rotation keeps the newest record")
        require(trail.records.last?.characters == total - AIAuditTrail.maximumRecords,
                "rotation drops the oldest records first")
        let fileLines = writeAuditFile(trail).split(separator: 0x0A).count
        require(fileLines == AIAuditTrail.maximumRecords,
                "the file after rotation has the kept record count: \(fileLines)")

        // Byte bound with a small explicit limit: the newest records that fit are kept.
        let byteDirectory = makeAuditDirectory()
        defer { removeAuditDirectory(byteDirectory) }
        let byteBound = 900
        let byteTrail = AIAuditTrail(directory: byteDirectory, maxRecords: 1_000, maxBytes: byteBound)
        for index in 0..<10 {
            byteTrail.append(AIAuditRecord(
                at: Date(timeIntervalSince1970: Double(index)),
                action: .translation,
                host: "audit.example",
                model: "mock-model",
                characters: 10_000 + index,
                pages: [index + 1],
                image: nil,
                outcome: .sent,
                code: nil,
                durationMilliseconds: 2
            ))
        }
        let byteCount = writeAuditFile(byteTrail).count
        require(byteCount <= byteBound, "the byte bound is respected: \(byteCount) <= \(byteBound)")
        require(byteTrail.records.count < 10, "the byte bound drops older records")
        require(byteTrail.records.first?.characters == 10_009, "the byte bound keeps the newest record")
        require(byteTrail.records.last != nil, "the byte bound keeps at least the newest record")

        // The newest record is never dropped, even if one line alone exceeds a tiny bound.
        let tinyDirectory = makeAuditDirectory()
        defer { removeAuditDirectory(tinyDirectory) }
        let tinyTrail = AIAuditTrail(directory: tinyDirectory, maxRecords: 10, maxBytes: 1)
        tinyTrail.append(AIAuditRecord(
            at: Date(), action: .regionQuestion, host: "audit.example", model: "mock-model",
            characters: 7, pages: [2], image: nil, outcome: .cancelled, code: nil,
            durationMilliseconds: 3
        ))
        require(tinyTrail.records.count == 1, "the newest record survives an impossible byte bound")
    }

    // MARK: - Clearing

    @MainActor
    private static func auditClearChecks() async throws {
        let directory = makeAuditDirectory()
        defer { removeAuditDirectory(directory) }
        let trail = AIAuditTrail(directory: directory)
        trail.append(AIAuditRecord(
            at: Date(), action: .documentChat, host: "audit.example", model: "mock-model",
            characters: 42, pages: [2, 3], image: nil, outcome: .sent, code: nil,
            durationMilliseconds: 5
        ))
        require(!trail.isEmpty, "the trail has an entry before clearing")
        require(trail.fileURL.path.hasPrefix(directory.path),
                "the trail writes only under the application-cache audit directory")
        trail.clear()
        require(trail.records.isEmpty, "clearing empties the in-memory list")
        require(trail.isEmpty, "the cleared trail reports empty")
        require(FileManager.default.fileExists(atPath: trail.fileURL.path),
                "clearing keeps the file in place")
        require(writeAuditFile(trail).isEmpty, "clearing truncates the file to zero bytes")
        trail.reload()
        require(trail.records.isEmpty, "reloading a cleared trail finds no records")
        require(!AIAuditPanelCopy.empty.isEmpty, "the panel has an explicit empty-state sentence")
        require(AIAuditPanelCopy.empty.contains("No requests"),
                "the empty state says the trail is empty")
    }

    // MARK: - Panel layout at the minimum width

    @MainActor
    private static func findAuditMarker(in view: NSView) -> AIAuditSectionMarkerView? {
        if let found = view as? AIAuditSectionMarkerView { return found }
        return view.subviews.lazy.compactMap { findAuditMarker(in: $0) }.first
    }

    /// Host the real panel at the right panel's 240 pt minimum content width. This proves the
    /// audit section is part of that panel and takes no more than the available width; whether
    /// the copy reads well at that density is a human review item, not a pixel assertion.
    @MainActor
    private static func auditPanelMinimumWidthCheck(root: URL) async throws {
        _ = NSApplication.shared
        let settingsFixture = makeAuditSettings()
        defer { settingsFixture.cleanup() }
        let directory = makeAuditDirectory()
        defer { removeAuditDirectory(directory) }
        let trail = AIAuditTrail(directory: directory)
        trail.append(AIAuditRecord(
            at: Date(),
            action: .summarise,
            host: "api.openai.com",
            model: "gpt-4o-mini",
            characters: 1_234,
            pages: [1, 2],
            image: AIAuditImage(widthPixels: 640, heightPixels: 480),
            outcome: .sent,
            code: nil,
            durationMilliseconds: 1_200
        ))
        let (engine, state, context) = try openAuditDocument(root: root)
        let model = AIAssistantModel(settings: settingsFixture.store, audit: trail)
        model.attach(service: AuditRecordingService(engine: engine), context: context)

        let width = ReaderSidePanelMetrics.minimumContentWidthPt
        require(width == 240, "the assistant panel's minimum content width is 240 pt")
        let host = NSHostingView(rootView: AIAssistantPanel(state: state, model: model))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 900)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: width, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        try await eventually("the audit section lays out at the panel's minimum width", {
            host.layoutSubtreeIfNeeded()
            return findAuditMarker(in: host) != nil
        })
        host.layoutSubtreeIfNeeded()
        guard let marker = findAuditMarker(in: host) else {
            fatalError("FAIL: the audit section marker is in the hosted panel")
        }
        require(marker.bounds.width > 0,
                "the audit section receives a width at the panel's minimum: \(marker.bounds.width) pt")
        require(marker.bounds.width <= width + 0.5,
                "the audit section fits the panel's minimum width: \(marker.bounds.width) pt")
    }

    // MARK: - The what-is-sent inventory

    @MainActor
    private static func auditInventoryChecks(root: URL) async throws {
        let (engine, _, context) = try openAuditDocument(root: root)
        let settingsFixture = makeAuditSettings()
        defer { settingsFixture.cleanup() }
        let trail = AIAuditTrail(directory: makeAuditDirectory())
        defer { removeAuditDirectory(trail.fileURL.deletingLastPathComponent()) }
        let service = AuditRecordingService(engine: engine)
        let model = AIAssistantModel(settings: settingsFixture.store, audit: trail)
        model.attach(service: service, context: context)
        await model.prepare(action: .summarizePage, context: context)
        guard let plan = model.plan else {
            fatalError("FAIL: the inventory check has a real plan: \(model.errorMessage ?? "nil")")
        }

        // The inventory says the display name travels inside the prompt. Prove it with the real
        // plan the preview showed, so the copy cannot drift from the builder.
        let prompt = plan.parts.first?.userPrompt ?? ""
        require(prompt.contains(plan.documentTitle),
                "the prompt really contains the document display name the inventory names")
        require(AIAuditPanelCopy.whatIsSent.contains(where: { $0.contains("display name") }),
                "the inventory tells the reader the display name is sent")
        require(AIAuditPanelCopy.whatIsSent.contains(where: { $0.contains("every page") }),
                "the inventory tells the reader a whole-document summary sends every page's text")
        require(AIAuditPanelCopy.whatIsSent.contains(where: { $0.localizedCaseInsensitiveContains("selected text") }),
                "the inventory names the selected text")
        require(AIAuditPanelCopy.whatIsSent.contains(where: { $0.localizedCaseInsensitiveContains("picture") }),
                "the inventory names region pictures")
        require(AIAuditPanelCopy.whatIsSent.contains(where: { $0.localizedCaseInsensitiveContains("question") }),
                "the inventory names questions")
        require(AIAuditPanelCopy.whatIsSent.contains(where: { $0.localizedCaseInsensitiveContains("turns") }),
                "the inventory names the document-chat conversation history")
        require(AIAuditPanelCopy.whatIsSent.contains(where: { $0.contains("instruction prompts") }),
                "the inventory names the instruction prompts")
        require(AIAuditPanelCopy.whatIsSent.contains(where: { $0.contains("part summaries") }),
                "the inventory says the consolidation sends the part summaries")
        require(AIAuditPanelCopy.whatIsSent.contains(where: { $0.contains("layered summary") }),
                "the inventory says the layered summary sends one bounded request per entry")
        require(AIAuditPanelCopy.note.contains("one outgoing request"),
                "the audit note states that one entry is one outgoing request")
        require(AIAuditPanelCopy.neverSent.contains(where: { $0.contains("PD") || $0.contains("PDF") }),
                "the inventory says the PDF file is never sent")
        require(AIAuditPanelCopy.neverSent.contains(where: { $0.localizedCaseInsensitiveContains("path") }),
                "the inventory says the file path is never sent")
        require(AIAuditPanelCopy.neverSent.contains(where: { $0.localizedCaseInsensitiveContains("annotation") }),
                "the inventory says annotation contents are never sent")
        require(AIAuditPanelCopy.neverSent.contains(where: { $0.localizedCaseInsensitiveContains("reading history") }),
                "the inventory says reading history is never sent")
        require(!AIAuditPanelCopy.neverSent.contains(where: {
            $0.localizedCaseInsensitiveContains("document name")
                || $0.localizedCaseInsensitiveContains("document's name")
        }), "the never-sent list does not claim document names are withheld, because the prompt carries one")
        require(AIAuditPanelCopy.wholeDocumentNote.contains("extracted text"),
                "the inventory explains that a document summary sends the extracted text")
        require(AIAuditPanelCopy.note.contains("never")
                    && AIAuditPanelCopy.note.contains("application cache"),
                "the audit note says what is stored and where")
        require(AIAuditPanelCopy.note.contains("file paths")
                    && AIAuditPanelCopy.note.contains("document names"),
                "the audit note says the trail does not store paths or names")
    }
}
