import AppKit
import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import LyraReaderBindings
import LyraReaderKit

// Layered-summary checks. Everything here runs against `MockProvider::preset` through
// `RustAIChatService(useMockProvider: true)`: no key leaves the machine and no socket is opened.
// The counts printed at the end are the request-count evidence for the three layers, the cache
// and the language switch.

@MainActor
private final class LayeredSummaryRecordingService: AIChatServicing {
    let base: RustAIChatService
    private(set) var started: [AiPlanRecord] = []
    private(set) var inspected: [AiSummaryRequestRecord] = []
    private(set) var prepared: [AiSummaryPlanRecord] = []
    /// Fails the next request whose first part has exactly this label, then succeeds.
    var failLabelOnce: String?
    /// A test-only edit: mutate one fingerprint's hash so exactly that section looks changed.
    var fingerprintOverride: ((AiSummaryFingerprintRecord) -> AiSummaryFingerprintRecord)?
    /// When set, every start returns a handle that takes `ticks` polls to finish.
    var slowPollCount: Int?

    init(base: RustAIChatService) {
        self.base = base
    }

    func prepare(_ request: AIMakePlanRequest) async throws -> AiPlanRecord {
        try await base.prepare(request)
    }

    func prepareMerge(_ request: AIMergePlanRequest) async throws -> AiPlanRecord {
        try await base.prepareMerge(request)
    }

    func inspectSummary(
        _ request: AiSummaryRequestRecord
    ) async throws -> [AiSummaryFingerprintRecord] {
        inspected.append(request)
        let result = try await base.inspectSummary(request)
        guard let fingerprintOverride else { return result }
        return result.map(fingerprintOverride)
    }

    func prepareSummary(_ request: AiSummaryRequestRecord) async throws -> AiSummaryPlanRecord {
        let plan = try await base.prepareSummary(request)
        prepared.append(plan)
        return plan
    }

    func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle {
        if let label = failLabelOnce, plan.parts.first?.label == label {
            failLabelOnce = nil
            return FailingLayeredSummaryHandle(
                message: "The provider rejected \(label) on purpose."
            )
        }
        if let ticks = slowPollCount {
            started.append(plan)
            return TimedLayeredSummaryHandle(ticks: ticks)
        }
        started.append(plan)
        return try base.start(plan, apiKey: apiKey)
    }
}

@MainActor
private final class FailingLayeredSummaryHandle: AIChatHandle {
    private let message: String
    private var sent = false
    private var finished = false

    init(message: String) {
        self.message = message
    }

    func poll() -> [AIStreamEvent] {
        guard !sent else { return [] }
        sent = true
        finished = true
        return [.error(message: message, cancelled: false)]
    }

    func cancel() { finished = true }
    var isFinished: Bool { finished }
}

@MainActor
private final class TimedLayeredSummaryHandle: AIChatHandle {
    private var ticks = 0
    private let limit: Int
    private var finished = false

    init(ticks: Int) {
        self.limit = max(2, ticks)
    }

    func poll() -> [AIStreamEvent] {
        guard !finished else { return [] }
        ticks += 1
        if ticks < limit {
            return [.delta("chunk \(ticks) ")]
        }
        finished = true
        return [.delta("done."), .done]
    }

    func cancel() { finished = true }
    var isFinished: Bool { finished }
}

private struct LayeredSummaryFixture {
    let suiteName: String
    let defaults: UserDefaults
    let keyStore: InMemoryAPIKeyStore
    let store: AISettingsStore

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

extension ReaderChecks {
    /// The T5.5 layered-summary evidence. Runs after the existing AI panel and document-chat
    /// checks, against the same mock provider.
    @MainActor
    static func aiLayeredSummaryChecks(root: URL) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-reader-layered-summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let outlined = scratch.appendingPathComponent("outlined.pdf")
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("tests/fixtures/outlined.pdf"),
            to: outlined
        )
        let truncatedFixture = scratch.appendingPathComponent("long-abstract.pdf")
        try writeLayeredFixture(to: truncatedFixture, pageCount: 20)
        let failureFixture = scratch.appendingPathComponent("failure.pdf")
        try FileManager.default.copyItem(at: outlined, to: failureFixture)
        let cancelFixture = scratch.appendingPathComponent("cancel.pdf")
        try FileManager.default.copyItem(at: outlined, to: cancelFixture)

        let sourceHash = try pdfHash(outlined)
        let siblingNames = try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted()

        let engine = try RustEngine()
        let document = try engine.openDocument(at: outlined)
        let outline = try await engine.outline()
        require(outline.count == 8, "the layered fixture's outline has eight entries")
        let context = AIReaderContext(
            documentKey: outlined.standardizedFileURL.path,
            documentTitle: document.title,
            pageCount: document.pageCount,
            currentPage: 1,
            selection: nil
        )
        require(document.pageCount == 3, "the outlined fixture has three pages")

        let fixture = makeSettingsFixture(key: "sk-layered-not-real-\(UUID().uuidString)")
        defer { fixture.cleanup() }
        require(fixture.store.save(
            baseURL: "http://127.0.0.1:11434/v1",
            model: "mock-model",
            temperature: 0.2,
            maxTokens: 900,
            apiKey: "sk-layered-not-real"
        ), "the layered fixture saves its provider")

        let recording = LayeredSummaryRecordingService(
            base: RustAIChatService(engine: engine, useMockProvider: true)
        )
        let model = LayeredSummaryModel(settings: fixture.store)
        model.attach(
            service: recording,
            context: context,
            outline: outline,
            documentURL: outlined
        )
        try await eventually("the layered rows are built and inspected", {
            !model.isRefreshing && model.entries.count == 12
                && model.entries.allSatisfy { !$0.textHash.isEmpty }
        })
        require(recording.started.isEmpty, "opening the layered summary sends nothing")
        require(model.entries(for: .sections).count == 8,
                "one section row per outline entry")
        require(model.entries(for: .pages).count == 3,
                "one page row per document page")
        let expectedLinkPages = [0, 0, 1, 1, 1, 2, 2, 2]
        require(model.entries(for: .sections).map(\.linkPage) == expectedLinkPages,
                "each section row links to the outline destination page ("
                    + "\(model.entries(for: .sections).map(\.linkPage)))")
        require(model.entries(for: .sections).map(\.pageStart) == expectedLinkPages.map { $0 + 1 },
                "each section row starts on the outline destination page")
        require(model.entries(for: .sections).map(\.pageEnd) == [1, 1, 2, 2, 2, 3, 3, 3],
                "each section row's page range ends before the next section ("
                    + "\(model.entries(for: .sections).map(\.pageEnd)))")
        require(model.bounds.abstractMaxPages == 12,
                "the abstract bound is the documented twelve pages")
        require(model.bounds.maxRequestsPerBatch == 24 && model.bounds.maxConcurrentRequests == 2,
                "the batch bounds are 24 requests with 2 in flight")

        // 1. Abstract: exactly one request over the whole three-page fixture, and it names its
        // page span. Nothing summarises the sections or pages first.
        await model.prepare(.abstract)
        try await eventually("the abstract preview is built locally", {
            model.phase == .preview && model.preview != nil
        })
        require(recording.started.isEmpty, "building the abstract preview sends nothing")
        guard let abstractPreview = model.preview else { fatalError("expected an abstract preview") }
        require(abstractPreview.units.count == 1, "the abstract needs exactly one request")
        require(abstractPreview.units[0].plan != nil, "the abstract request is previewed")
        require(abstractPreview.units[0].note == "Covers all 3 pages.",
                "the abstract states how many pages it covers (\(abstractPreview.units[0].note ?? "nil"))")
        require(abstractPreview.note.contains("At most 24 requests per batch and 2 in flight"),
                "the preview states the batch bounds")
        require(abstractPreview.note.contains("at most 12 pages"),
                "the preview states the abstract page bound")
        let abstractPart = abstractPreview.units[0].plan?.parts.first
        require(abstractPart?.wireBody.contains("\"stream\":true") == true,
                "the previewed abstract is a streaming request body")
        require(abstractPart?.wireBody.contains("sk-layered-not-real") == false,
                "the previewed abstract body never contains the key")
        model.send()
        try await eventually("the abstract request finishes", {
            model.phase == .finished
                && model.entries(for: .abstract).first?.state == .ready
        })
        require(recording.started.count == 1,
                "the abstract layer sends exactly one request (got \(recording.started.count))")
        require(model.entries(for: .sections).allSatisfy { $0.state == .notGenerated },
                "generating the abstract does not summarise every section first")
        require(model.entries(for: .pages).allSatisfy { $0.state == .notGenerated },
                "generating the abstract does not summarise every page first")
        let abstractEntry = model.entries(for: .abstract)[0]
        require(abstractEntry.summary.contains("This page explains the method"),
                "the mock abstract appears in the row")
        require(abstractEntry.pageSpanLabel(pageCount: 3).contains("All 3 pages"),
                "the abstract row names its page span (\(abstractEntry.pageSpanLabel(pageCount: 3)))")

        // 2. Sections: eight requests, one per outline entry, each row linked to its page.
        await model.prepare(.sections)
        try await eventually("the section preview is built locally", {
            model.phase == .preview && model.previewLayer == .sections
        })
        require(model.preview?.units.count == 8, "the section layer previews eight requests")
        require(recording.started.count == 1, "the section preview sends nothing by itself")
        model.send()
        try await eventually("all section requests finish", {
            model.phase == .finished
                && model.entries(for: .sections).allSatisfy { $0.state == .ready }
        })
        require(recording.started.count == 9,
                "eight section requests follow the abstract (got \(recording.started.count) total)")
        require(model.entries(for: .sections).allSatisfy { !$0.summary.isEmpty },
                "every section row has its own summary")
        require(model.entries(for: .sections).map(\.linkPage) == expectedLinkPages,
                "section rows still link to the right page after generation")

        // 3. Pages: three requests, one per page, each row linked to that page.
        await model.prepare(.pages)
        try await eventually("the page preview is built locally", {
            model.phase == .preview && model.previewLayer == .pages
        })
        require(model.preview?.units.count == 3, "the page layer previews one request per page")
        model.send()
        try await eventually("all page requests finish", {
            model.phase == .finished
                && model.entries(for: .pages).allSatisfy { $0.state == .ready }
        })
        require(recording.started.count == 12,
                "three page requests follow the sections (got \(recording.started.count) total)")
        require(model.entries(for: .pages).map(\.linkPage) == [0, 1, 2],
                "each page row links to its own page")
        require(model.entries(for: .pages).allSatisfy { !$0.summary.isEmpty },
                "every page row has a one-liner")

        // 4. Cache: reopening sends zero requests and shows every row from summaries.json.
        let cacheFile = DocumentEditCache.directory(for: outlined)
            .appendingPathComponent(AISummaryCache.fileName)
        require(FileManager.default.fileExists(atPath: cacheFile.path),
                "the layered cache is summaries.json in the document cache")

        let reopened = LayeredSummaryModel(settings: fixture.store)
        reopened.attach(
            service: recording,
            context: context,
            outline: outline,
            documentURL: outlined
        )
        try await eventually("the reopened panel restores cached rows", {
            !reopened.isRefreshing && reopened.entries.count == 12
                && reopened.entries.allSatisfy { $0.state == .ready }
        })
        require(recording.started.count == 12,
                "reopening the panel sends zero requests (still \(recording.started.count))")
        require(reopened.entries(for: .abstract)[0].summary
                    == model.entries(for: .abstract)[0].summary,
                "the reopened abstract is the same cached text")

        // 5. Language: a different language is a cache miss and sends new requests. Switching
        // back restores the document-language cache without sending anything.
        reopened.setLanguage("French")
        try await eventually("the French cache is empty and rows reset", {
            !reopened.isRefreshing && reopened.language == "French"
                && reopened.entries.allSatisfy { $0.state != .ready }
        })
        require(recording.started.count == 12,
                "switching language alone sends nothing (still \(recording.started.count))")
        await reopened.prepare(.abstract)
        try await eventually("the French abstract is previewed", {
            reopened.phase == .preview && reopened.preview != nil
        })
        reopened.send()
        try await eventually("the French abstract finishes", {
            reopened.phase == .finished
                && reopened.entries(for: .abstract).first?.state == .ready
        })
        require(recording.started.count == 13,
                "the French abstract is a new request (got \(recording.started.count) total)")
        let frenchPrompt = recording.started.last?.parts.first?.systemPrompt ?? ""
        require(frenchPrompt.contains("Write the result in French."),
                "the French request asks for French")
        reopened.setLanguage("")
        try await eventually("the document-language cache is restored", {
            !reopened.isRefreshing && reopened.language.isEmpty
                && reopened.entries.count == 12
                && reopened.entries.allSatisfy { $0.state == .ready }
        })
        require(recording.started.count == 13,
                "switching back to the document language reuses its cache (still \(recording.started.count))")

        // 6. An edited section invalidates exactly its own entry.
        recording.fingerprintOverride = { fingerprint in
            guard fingerprint.kind == .section, fingerprint.index == 2 else { return fingerprint }
            var changed = fingerprint
            changed.textHash = "edited-" + fingerprint.textHash
            return changed
        }
        await reopened.refresh()
        try await eventually("only the edited section is stale", {
            !reopened.isRefreshing
                && reopened.entries.filter { $0.state == .stale }.count == 1
                && reopened.entries.filter { $0.state == .ready }.count == 11
        })
        let staleSections = reopened.entries(for: .sections).filter { $0.state == .stale }
        require(staleSections.count == 1 && staleSections[0].id == "section:2",
                "the edited section is the stale one (\(staleSections.map(\.id)))")
        require(recording.started.count == 13,
                "marking one section stale sends nothing")
        await reopened.prepare(.sections)
        try await eventually("the stale section preview contains one request", {
            reopened.phase == .preview && reopened.preview != nil
        })
        require(reopened.preview?.units.count == 1,
                "regenerating an edited section previews only that section")
        reopened.send()
        try await eventually("the edited section is ready again", {
            reopened.phase == .finished
                && reopened.entries(for: .sections).allSatisfy { $0.state == .ready }
        })
        require(recording.started.count == 14,
                "editing one section sends exactly one new request (got \(recording.started.count) total)")
        recording.fingerprintOverride = nil

        // 7. Truncation: a twenty-page document's abstract is cut at page 12 and says so with
        // the real range.
        let longDocument = try engine.openDocument(at: truncatedFixture)
        let longContext = AIReaderContext(
            documentKey: truncatedFixture.standardizedFileURL.path,
            documentTitle: longDocument.title,
            pageCount: longDocument.pageCount,
            currentPage: 1,
            selection: nil
        )
        require(longDocument.pageCount == 20, "the truncation fixture has twenty pages")
        let longService = LayeredSummaryRecordingService(
            base: RustAIChatService(engine: engine, useMockProvider: true)
        )
        let longModel = LayeredSummaryModel(settings: fixture.store)
        longModel.attach(
            service: longService,
            context: longContext,
            outline: [],
            documentURL: truncatedFixture
        )
        try await eventually("the long document's coverage is inspected", {
            !longModel.isRefreshing && longModel.entries.count == 23
                && (longModel.entries(for: .abstract).first?.textHash.isEmpty == false)
        })
        let abstractRow = longModel.entries(for: .abstract)[0]
        require(abstractRow.truncated, "the abstract coverage is marked truncated")
        require(abstractRow.coveredPageEnd == 12,
                "the abstract sampled pages 1-12 (got \(abstractRow.coveredPageEnd))")
        require(abstractRow.note == "Summarised from pages 1-12 of 20.",
                "the truncation note names the real page range (\(abstractRow.note ?? "nil"))")
        require(abstractRow.pageSpanLabel(pageCount: 20) == "Pages 1-12 of 20",
                "the row names its page span (\(abstractRow.pageSpanLabel(pageCount: 20)))")
        await longModel.prepare(.abstract)
        try await eventually("the truncated abstract is previewed", {
            longModel.phase == .preview && longModel.preview != nil
        })
        let longPreview = longModel.preview
        require(longPreview?.units.first?.truncated == true,
                "the preview's unit is marked truncated")
        require(longPreview?.units.first?.note == "Summarised from pages 1-12 of 20.",
                "the preview carries the truncation note")
        longModel.send()
        try await eventually("the truncated abstract finishes", {
            longModel.phase == .finished
                && longModel.entries(for: .abstract).first?.state == .ready
        })
        require(longService.started.count == 1,
                "the truncated abstract is still one request")
        require(longModel.entries(for: .abstract)[0].note == "Summarised from pages 1-12 of 20.",
                "the finished row keeps the truncation note")
        require(longModel.entries(for: .sections).map(\.pageStart) == [1, 11],
                "without an outline the section layer falls back to page ranges ("
                    + "\(longModel.entries(for: .sections).map(\.pageStart)))")
        require(longModel.entries(for: .sections).map(\.pageEnd) == [10, 20],
                "the fallback page ranges cover the document ("
                    + "\(longModel.entries(for: .sections).map(\.pageEnd)))")

        // 8. A failed page fails alone; the other pages stay ready, and Retry re-sends exactly
        // that page's previewed request.
        let failingDocument = try engine.openDocument(at: failureFixture)
        let failingOutline = try await engine.outline()
        let failingContext = AIReaderContext(
            documentKey: failureFixture.standardizedFileURL.path,
            documentTitle: failingDocument.title,
            pageCount: failingDocument.pageCount,
            currentPage: 1,
            selection: nil
        )
        let failingService = LayeredSummaryRecordingService(
            base: RustAIChatService(engine: engine, useMockProvider: true)
        )
        let failingModel = LayeredSummaryModel(settings: fixture.store)
        failingService.failLabelOnce = "Page 2"
        failingModel.attach(
            service: failingService,
            context: failingContext,
            outline: failingOutline,
            documentURL: failureFixture
        )
        try await eventually("the failure fixture's rows are inspected", {
            !failingModel.isRefreshing && failingModel.entries.count == 12
                && failingModel.entries.allSatisfy { !$0.textHash.isEmpty }
        })
        await failingModel.prepare(.pages)
        try await eventually("the failure fixture's page preview is built", {
            failingModel.phase == .preview && failingModel.preview != nil
        })
        failingModel.send()
        try await eventuallyExplaining(
            "the failed page settles while the others finish",
            {
                "phase=\(failingModel.phase) active=\(failingModel.activeRequests) "
                    + "finished=\(failingModel.finishedRequests)/\(failingModel.batchRequests) "
                    + "starts=\(failingService.started.count) pages="
                    + "\(failingModel.entries(for: .pages).map { "\($0.id):\($0.state)" }) "
                    + "note=\(failingModel.statusNote ?? "nil")"
            },
            {
                failingModel.phase == .finished
                    && failingModel.entries(for: .pages).filter { $0.state == .ready }.count == 2
                    && failingModel.entries(for: .pages).filter {
                        if case .failed = $0.state { return true }
                        return false
                    }.count == 1
            }
        )
        let failedPage = failingModel.entries(for: .pages).first {
            if case .failed = $0.state { return true }
            return false
        }!
        require(failedPage.id == "page:2",
                "the page named by the failing service is the failed row (\(failedPage.id))")
        require(failingModel.entries(for: .pages).filter { $0.state == .ready }.map(\.id)
                    == ["page:1", "page:3"],
                "the other pages stay ready")
        require(failingModel.entries(for: .pages).filter { $0.state.needsRetry }.count == 1,
                "the failed page shows its own Retry")
        let startsBeforeRetry = failingService.started.count
        failingModel.retry("page:2")
        try await eventually("the retried page finishes", {
            failingModel.phase == .finished
                && failingModel.entries(for: .pages).allSatisfy { $0.state == .ready }
        })
        require(failingService.started.count == startsBeforeRetry + 1,
                "Retry re-sends exactly the failed page (got \(failingService.started.count - startsBeforeRetry))")

        // 9. Cancel keeps completed rows and marks the running row cancelled.
        let cancelDocument = try engine.openDocument(at: cancelFixture)
        let cancelOutline = try await engine.outline()
        let cancelContext = AIReaderContext(
            documentKey: cancelFixture.standardizedFileURL.path,
            documentTitle: cancelDocument.title,
            pageCount: cancelDocument.pageCount,
            currentPage: 1,
            selection: nil
        )
        let cancelRecording = LayeredSummaryRecordingService(
            base: RustAIChatService(engine: engine, useMockProvider: true)
        )
        cancelRecording.slowPollCount = 8
        let cancelService: any AIChatServicing = cancelRecording
        let cancelModel = LayeredSummaryModel(settings: fixture.store)
        cancelModel.attach(
            service: cancelService,
            context: cancelContext,
            outline: cancelOutline,
            documentURL: cancelFixture
        )
        try await eventually("the cancel fixture's rows are inspected", {
            !cancelModel.isRefreshing && cancelModel.entries.count == 12
                && cancelModel.entries.allSatisfy { !$0.textHash.isEmpty }
        })
        await cancelModel.prepare(.pages)
        try await eventually("the cancel fixture's page preview is built", {
            cancelModel.phase == .preview && cancelModel.preview != nil
        })
        cancelModel.send()
        try await eventuallyExplaining(
            "two pages finish and the third is in flight",
            {
                "phase=\(cancelModel.phase) active=\(cancelModel.activeRequests) "
                    + "pages=\(cancelModel.entries(for: .pages).map { "\($0.id):\($0.state)" }) "
                    + "starts=\(cancelRecording.started.count)"
            },
            {
                cancelModel.entries(for: .pages).filter { $0.state == .ready }.count == 2
                    && cancelModel.activeRequests == 1
            }
        )
        cancelModel.cancel()
        try await eventually("the running page is cancelled", {
            cancelModel.phase == .cancelled
                && cancelModel.entries(for: .pages).filter { $0.state == .cancelled }.count == 1
        })
        require(cancelModel.entries(for: .pages).filter { $0.state == .ready }.count == 2,
                "cancel keeps the two completed page rows")
        require(cancelModel.entries(for: .pages).filter { $0.state == .cancelled }.count == 1,
                "cancel marks the running page row cancelled")
        require(cancelRecording.started.count == 3,
                "all three page requests had started (got \(cancelRecording.started.count))")

        // 10. Honesty: the PDF is byte-identical and no file appears beside it. The cache is in
        // the document-cache directory, not the PDF's folder.
        let finalHash = try pdfHash(outlined)
        require(finalHash == sourceHash,
                "the layered summary never writes into the PDF")
        let siblingsAfter = try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted()
        require(Set(siblingsAfter) == Set(siblingNames + ["long-abstract.pdf", "failure.pdf", "cancel.pdf"]),
                "no summary file appears beside the PDFs (\(siblingsAfter))")
        require(!siblingsAfter.contains { $0.hasSuffix(".json") },
                "the cache is not a sidecar next to the PDF")

        print("AI-LAYERED abstract_requests=1 section_requests=8 page_requests=3 "
            + "reopen_requests=0 language_requests=1 edited_section_requests=1 "
            + "truncated_pages=1-12/20 failed_rows=1 cancelled_rows=1 "
            + "cache=\(cacheFile.lastPathComponent)")
    }

    /// A fresh settings suite and key store for one check group.
    @MainActor
    private static func makeSettingsFixture(key: String?) -> LayeredSummaryFixture {
        let suiteName = "lyra-reader-layered-checks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keyStore = InMemoryAPIKeyStore(key: key)
        let store = AISettingsStore(defaults: defaults, keyStore: keyStore)
        return LayeredSummaryFixture(
            suiteName: suiteName,
            defaults: defaults,
            keyStore: keyStore,
            store: store
        )
    }

    /// A twenty-page PDF with a single text line per page. Long enough that the abstract page
    /// budget (12) cuts it.
    private static func writeLayeredFixture(to url: URL, pageCount: Int) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(
                domain: "LyraReaderChecks",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "could not create the layered fixture"]
            )
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.black,
        ]
        for page in 1...pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(mediaBox)
            context.setFillColor(NSColor.black.cgColor)
            let line = "Page \(page) studies a separate result. The evaluation improved for method \(page)."
            let attributed = NSAttributedString(string: line, attributes: attributes)
            context.textPosition = CGPoint(x: 72, y: 720)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    private static func pdfHash(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
