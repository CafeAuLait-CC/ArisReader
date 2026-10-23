import AppKit
import Foundation
import LyraReaderBindings
import LyraReaderKit
import SwiftUI

/// All generation in these checks uses the deterministic Rust mock, with no network access.
@MainActor
private final class ReadingNotesService: AIChatServicing {
    let base: RustAIChatService
    var requests: [AIMakePlanRequest] = []
    var starts = 0
    init(engine: RustEngine) { base = RustAIChatService(engine: engine, useMockProvider: true) }
    func prepare(_ request: AIMakePlanRequest) async throws -> AiPlanRecord {
        requests.append(request); return try await base.prepare(request)
    }
    func prepareMerge(_ request: AIMergePlanRequest) async throws -> AiPlanRecord { try await base.prepareMerge(request) }
    func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle {
        starts += 1; return try base.start(plan, apiKey: apiKey)
    }
}

extension ReaderChecks {
    @MainActor
    static func regionReadingNotesChecks(root: URL) async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-reading-notes-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("reading.pdf")
        try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: source)
        let suite = "lyra-reading-notes-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AISettingsStore(defaults: defaults, keyStore: InMemoryAPIKeyStore(key: "mock-key"))
        _ = settings.save(baseURL: "http://127.0.0.1:11434/v1", model: "mock-model",
                          temperature: 0.2, maxTokens: 900, apiKey: nil)
        let engine = try RustEngine()
        let state = AppState(engine: engine)
        require(state.open(url: source), "reading-notes fixture opens")
        state.setViewportSize(CGSize(width: 900, height: 700))
        let service = ReadingNotesService(engine: engine)
        state.regionChatServiceOverride = { service }
        state.regionAssistantFactory = { AIAssistantModel(settings: settings) }
        await state.createRegionCard(page: 0, rect: CGRect(x: 60, y: 60, width: 300, height: 140))
        guard let card = state.regionCards.first else { fatalError("FAIL: reading-notes card") }
        let context = state.aiReaderContext!
        card.question = "What is this region?"
        await card.send(context: context)
        require(service.starts == 1, "one Send starts the region request without a second preview click")
        try await eventually("the first mock region answer finishes") { card.assistant.phase == .finished }
        let firstAnswer = card.answer
        card.question = "How does that relate?"
        await card.send(context: context)
        try await eventually("the follow-up finishes") { card.assistant.phase == .finished }
        require(service.requests.last?.history == [AIConversationTurn(question: "What is this region?", answer: firstAnswer)],
                "follow-up carries the exact preceding question and answer")
        require(card.allTurns.count == 2 && card.question.isEmpty, "both turns survive while the composer clears")
        await card.distill(context: context)
        try await eventually("the reading note finishes") { card.notesAssistant.phase == .finished }
        card.keepGeneratedNote()
        require(!card.knowledgeNote.isEmpty && card.allTurns.count == 2,
                "distillation creates a note without replacing either conversation turn")
        card.knowledgeNote = "- Edited knowledge point [p.1]"
        // The shipped native child must agree with Metal's submitted scroll transform and
        // receive real pointer locations even though its parent uses the opposite Y direction.
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let canvas = MetalCanvasView(frame: container.bounds)
        container.addSubview(canvas)
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container; window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        func syncCanvas() {
            canvas.zoom = state.zoomFactor; canvas.scrollYPt = state.scrollYPt
            canvas.contentWidthPt = state.contentWidthPt; canvas.pages = state.canvasPages
            canvas.configureRegionCards(state: state)
            container.layoutSubtreeIfNeeded()
        }
        syncCanvas()
        try await eventually("the shipped native card has a measured frame") {
            syncCanvas()
            return canvas.hasAttachedSurface && canvas.regionCardFrames.count == 1 && card.heightViewPt > 120
        }
        let cardRect = canvas.regionCardFrames[0]
        let parentPoint = CGPoint(x: cardRect.midX, y: canvas.bounds.height - cardRect.midY)
        let hit = canvas.hitTest(parentPoint)
        require(hit != nil && hit !== canvas && hit!.isDescendant(of: canvas),
                "a pointer over the visible top-down card reaches its hosting view")
        require(canvas.hitTest(CGPoint(x: 5, y: 5)) === canvas,
                "an empty area of the native card host passes through to the PDF")
        for delta in [30.0, -15.0, 45.0] {
            state.scroll(byScreenPoints: delta); syncCanvas()
            try await eventually("paper and native card share the submitted scroll transform") {
                guard let frame = canvas.regionCardFrames.first, let gap = state.regionGapTop(for: card.id) else { return false }
                return abs(frame.minY - (gap - canvas.scrollYPt) * canvas.zoom) < 0.5
            }
        }

        state.closeRegionCard(id: card.id, keepHistory: true)
        require(state.pageSegments(forPage: 0).count == 1, "collapse restores the unsplit paper")
        let next = AppState(engine: try RustEngine())
        require(next.open(url: source), "a fresh session opens the same document")
        guard let entry = next.currentRegionHistory.first else { fatalError("FAIL: durable reading notes") }
        require(entry.id == card.id && entry.allTurns.count == 2 && entry.knowledgeNote.contains("Edited knowledge"),
                "relaunch restores the same conversation and edited note")
        next.regionAssistantFactory = { AIAssistantModel(settings: settings) }
        let reopened = next.reopenRegionCard(from: entry)!
        require(reopened.id == card.id && reopened.allTurns == entry.allTurns && reopened.question.isEmpty,
                "reopening resumes the same conversation instead of pre-filling an old question")
        let exported = AIRegionMarkdownExport.render(documentTitle: "Reading", documentFileName: "reading.pdf",
            entries: [entry], imageFolderName: "reading-assets")
        require(exported.markdown.contains("What is this region?") && exported.markdown.contains("How does that relate?")
                    && exported.markdown.contains("Edited knowledge point") && exported.images.count == 1,
                "Markdown export contains every turn, the edited note and the selected image")
        next.closeRegionCard(id: reopened.id, keepHistory: true)

        let knowledge = AIDocumentKnowledge()
        knowledge.settings = settings
        let before = service.starts
        let reading = Task { try await knowledge.ensure(service: service, context: context,
            sourceURL: source, cacheDocumentURL: source) }
        try await eventually("first AI use asks to read the document") { knowledge.phase == .consent }
        require(service.starts == before, "the first-use prompt sends nothing before Start Reading")
        knowledge.proceed()
        let prior = try await reading.value
        require(!prior.isEmpty && knowledge.record?.pages == [1], "a completed full reading records its source coverage")
        let count = service.starts
        let restored = AIDocumentKnowledge(); restored.settings = settings
        let cached = try await restored.ensure(service: service, context: context, sourceURL: source, cacheDocumentURL: source)
        require(cached == prior && service.starts == count && !restored.isPresented,
                "a new session reuses the content-matched prior without another request")
        let wrapped = DocumentKnowledgeService(base: service, knowledge: restored, context: context,
            sourceURL: source, cacheDocumentURL: source)
        let plan = try await wrapped.prepare(AIMakePlanRequest(action: .documentChat, currentPage: 1,
            selection: nil, question: card.attachment.text, language: nil, settings: try settings.providerSettings()))
        require(plan.parts[0].userPrompt.contains(prior), "document chat receives the shared prior as context")
        let body = try JSONSerialization.jsonObject(with: Data(plan.parts[0].wireBody.utf8)) as! [String: Any]
        let messages = body["messages"] as! [[String: Any]]
        require(messages[0]["content"] as? String == plan.parts[0].systemPrompt,
                "inspectable system context and actual outgoing JSON are identical")
        let noPrior = AIDocumentKnowledge(); noPrior.settings = settings
        let translator = DocumentKnowledgeService(base: service, knowledge: noPrior, context: context,
            sourceURL: source, cacheDocumentURL: source)
        _ = try await translator.prepare(AIMakePlanRequest(action: .translateSelection, currentPage: 1,
            selection: AIReaderSelection(page: 1, start: 0, end: 5), question: nil,
            language: "English", settings: try settings.providerSettings()))
        require(noPrior.phase == .idle && !noPrior.isPresented, "selection-only translation skips document reading")
        var bytes = try Data(contentsOf: source); bytes.append(Data("\n% changed source\n".utf8)); try bytes.write(to: source)
        let changed = Task { try await restored.ensure(service: service, context: context, sourceURL: source, cacheDocumentURL: source) }
        try await eventually("changed PDF invalidates the prior and asks again") { restored.phase == .consent }
        restored.cancel()
        do { _ = try await changed.value; require(false, "cancelled reading cannot succeed") } catch {}
        require(service.starts == count, "cancelling the changed-document prompt sends no request")
        let staleAttachment = AIRegionAttachment(page: state.document!.pageCount, rect: card.attachment.rect,
            text: card.attachment.text, png: card.attachment.png, pixelWidth: card.attachment.pixelWidth,
            pixelHeight: card.attachment.pixelHeight, captureScale: card.attachment.captureScale)
        let staleEntry = AIRegionHistoryEntry(documentKey: state.regionDocumentKey!, attachment: staleAttachment,
            question: "A removed page", answer: "This remains readable.", state: .finished)
        require(state.reopenRegionCard(from: staleEntry) == nil,
                "a historical page number outside the current PDF cannot reopen a region card")
        require(state.regionRefusalMessage?.contains("no longer in this PDF") == true,
                "an unavailable historical page explains why its conversation cannot continue")
        let markdownPreview = AIRegionHistoryEntry(documentKey: state.regionDocumentKey!, attachment: card.attachment,
            question: "Formatting", answer: "## Connecting ideas\n\n**Key concept** with _emphasis_ and [p.1].", state: .finished)
        require(markdownPreview.answerPreview == "Connecting ideas Key concept with emphasis and [p.1].",
                "history row preview removes heading and inline emphasis Markdown markers")
        let boundedPreview = AIRegionHistoryEntry(documentKey: state.regionDocumentKey!, attachment: card.attachment,
            question: "Long formatting", answer: "## Heading\n\n" + String(repeating: "**word** ", count: 80), state: .finished)
        require(boundedPreview.answerPreview.count == 161 && boundedPreview.answerPreview.hasSuffix("…"),
                "history row Markdown preview remains capped at 160 characters plus ellipsis")
        let longEntry = AIRegionHistoryEntry(documentKey: state.regionDocumentKey!, attachment: card.attachment,
            question: "A long answer", answer: String(repeating: "A source-grounded paragraph [p.1].\n\n", count: 100), state: .finished)
        let longCard = state.reopenRegionCard(from: longEntry)!
        syncCanvas()
        try await eventuallyExplaining("long transcripts stop growing at the viewport-based height limit", {
            "height=\(longCard.heightViewPt), limit=\(AIRegionCard.maximumHeight(in: canvas.visibleRect.height)), frame=\(canvas.regionCardFrames), viewport=\(canvas.visibleRect)"
        }, {
            syncCanvas()
            return longCard.heightViewPt > 250 && longCard.heightViewPt <= AIRegionCard.maximumHeight(in: canvas.visibleRect.height) + 0.5
        })
        longCard.question = "first line\nsecond line\nthird line\nfourth line"
        try await Task.sleep(for: .milliseconds(100))
        require(longCard.heightViewPt <= AIRegionCard.maximumHeight(in: canvas.visibleRect.height) + 0.5,
                "a multiline composer remains inside the total card height limit")
        state.closeRegionCard(id: longCard.id, keepHistory: false)
        print("Reading notes and document knowledge checks passed")
    }
}
