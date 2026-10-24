import AppKit
import CoreText
import Foundation
import LyraReaderBindings
import LyraReaderKit
import SwiftUI

/// Opt-in computer-use harness. Uses generated paper and a scripted stream; never a provider.
@MainActor private final class RegionReviewService: AIChatServicing {
    let base: RustAIChatService
    init(engine: RustEngine) { base = RustAIChatService(engine: engine, useMockProvider: true) }
    func prepare(_ request: AIMakePlanRequest) async throws -> AiPlanRecord { try await base.prepare(request) }
    func prepareMerge(_ request: AIMergePlanRequest) async throws -> AiPlanRecord { try await base.prepareMerge(request) }
    func inspectSummary(_ request: AiSummaryRequestRecord) async throws -> [AiSummaryFingerprintRecord] { try await base.inspectSummary(request) }
    func prepareSummary(_ request: AiSummaryRequestRecord) async throws -> AiSummaryPlanRecord { try await base.prepareSummary(request) }
    func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle {
        let text: String
        if plan.action == .summarizeDocument {
            text = "## Document understanding\nThis synthetic paper connects sparse visual observations, latent motion tokens and conditional flow matching. Its method preserves local motion while sharing global context. The evaluation measures generation quality and temporal coherence. [p.1] [p.2] [p.3]"
        } else {
            text = "## Connecting this region to the paper\nThe selected passage describes how local observations guide a shared motion representation. The document's central idea is to keep the global trajectory coherent while allowing sparse constraints. [p.1]\n\n"
                + "- **Shared context** connects the selected region.\n- _Original sources_ remain the evidence.\n\n> A local mock response for visual verification.\n\n| Scope | Evidence |\n| --- | --- |\n| Region | [p.1] |\n\n```swift\nlet context = \"document\"\n```\n\nInline math $E=mc^2$.\n\n"
                + (1...12).map { "### \($0). A closer look\nThe region provides a local constraint. Shared document understanding connects it to the method, while original passages provide the evidence. The result can be discussed in follow-up questions without losing the original selection. [p.1]\n\n" }.joined()
        }
        return RegionReviewHandle(text: text)
    }
}
@MainActor private final class RegionReviewHandle: AIChatHandle {
    var fragments: [String]
    var finished = false
    init(text: String) {
        let chars = Array(text)
        fragments = stride(from: 0, to: chars.count, by: 30).map { String(chars[$0..<min($0 + 30, chars.count)]) }
    }
    func poll() -> [AIStreamEvent] {
        if finished { return [] }
        if !fragments.isEmpty { return [.delta(fragments.removeFirst())] }
        finished = true; return [.done]
    }
    func cancel() { fragments = []; finished = true }
    var isFinished: Bool { finished }
}

@MainActor private final class RegionReviewPreferences: NSObject {
    static let shared = RegionReviewPreferences()
    private var window: NSWindow?
    @objc func showPreferences() {
        if window == nil {
            let host = NSHostingView(rootView: SettingsView(registry: ReaderWindowRegistry()))
            let value = NSWindow(contentRect: CGRect(x: 220, y: 180, width: 650, height: 540),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            value.title = "Review Preferences"; value.isReleasedWhenClosed = false
            value.contentView = host; window = value
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

extension ReaderChecks {
    @MainActor private static func runReviewEventLoop() { NSApplication.shared.run() }

    @MainActor static func regionReviewPreview(root: URL) async throws {
        NSApplication.shared.setActivationPolicy(.regular)
        // Only this isolated review app's defaults; never change the system preference.
        UserDefaults.standard.set("Always", forKey: "AppleShowScrollBars")
        let menu = NSMenu()
        let appItem = NSMenuItem(); let submenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(RegionReviewPreferences.showPreferences), keyEquivalent: ",")
        settingsItem.target = RegionReviewPreferences.shared
        submenu.addItem(settingsItem); appItem.submenu = submenu; menu.addItem(appItem)
        NSApplication.shared.mainMenu = menu
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-region-review-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let pdf = scratch.appendingPathComponent("Shared context — local review.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = CGDataConsumer(url: pdf as CFURL)!
        let cg = CGContext(consumer: consumer, mediaBox: &box, nil)!
        func line(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, bold: Bool = false) {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont(name: bold ? "TimesNewRomanPS-BoldMT" : "TimesNewRomanPSMT", size: size)!]
            let value = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            cg.textPosition = CGPoint(x: x, y: y); CTLineDraw(value, cg)
        }
        let sentences = [
            "Sparse observations can describe a motion without specifying every frame.",
            "A shared latent representation connects local constraints to global structure.",
            "The model learns a conditional flow between noise and coherent motion tokens.",
            "Visual evidence remains the source for each claim and its page reference.",
            "Local region questions can therefore connect to the argument of the paper.",
            "The evaluation compares generation quality, controllability and temporal fit."]
        for page in 0..<3 {
            cg.beginPDFPage(nil); cg.setFillColor(NSColor.white.cgColor); cg.fill(box)
            cg.setFillColor(NSColor.black.cgColor)
            line("SHARED CONTEXT FOR READING", x: 50, y: 784, size: 19, bold: true)
            line("A synthetic document for local interaction review", x: 50, y: 760, size: 12)
            line(page == 0 ? "1  Overview and motivation" : page == 1 ? "2  Method and representation" : "3  Evaluation and conclusions",
                 x: 50, y: 714, size: 15, bold: true)
            for index in 0..<42 {
                line(sentences[(index + page) % sentences.count], x: 50, y: 683 - CGFloat(index) * 14, size: 11)
                if index % 7 == 5 { line("", x: 50, y: 0, size: 11) }
            }
            line("\(page + 1)", x: 294, y: 28, size: 11)
            cg.endPDFPage()
        }
        cg.closePDF()
        let defaults = UserDefaults(suiteName: "lyra-region-review-\(UUID())")!
        let settings = AISettingsStore(defaults: defaults, keyStore: InMemoryAPIKeyStore(key: "mock-local-review"))
        let localModel = ProcessInfo.processInfo.environment["LYRA_READER_REVIEW_LOCAL"] == "1"
        _ = settings.save(baseURL: localModel ? "http://127.0.0.1:8080/v1" : "http://127.0.0.1:11434/v1",
            model: localModel ? "mlx-community/Qwen3.8-27B-8bit" : "local-ui-review",
            temperature: 0.2, maxTokens: localModel ? 1024 : 3000, apiKey: nil)
        let engine = try RustEngine()
        let state = AppState(engine: engine)
        state.sidebarVisible = false; state.rightPanelVisible = false
        require(state.open(url: pdf), "generated review paper opens")
        let base: any AIChatServicing = localModel ? RustAIChatService(engine: engine) : RegionReviewService(engine: engine)
        state.documentKnowledge.settings = settings
        let context = state.aiReaderContext!
        let service = DocumentKnowledgeService(base: base, knowledge: state.documentKnowledge,
            context: context, sourceURL: pdf, cacheDocumentURL: pdf)
        state.regionChatServiceOverride = { service }
        state.regionAssistantFactory = { AIAssistantModel(settings: settings) }
        let assistant = AIAssistantModel(settings: settings)
        let host = NSHostingView(rootView: ReaderWindow(state: state,
            opener: DocumentOpenCoordinator(state: state), aiAssistant: assistant))
        let window = NSWindow(contentRect: CGRect(x: 150, y: 120, width: ProcessInfo.processInfo.environment["LYRA_READER_REVIEW_NARROW"] == "1" ? 760 : 1180, height: 860),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        // Appearance override is confined to this opt-in local review window.
        if ProcessInfo.processInfo.environment["LYRA_READER_REVIEW_DARK"] == "1" {
            window.appearance = NSAppearance(named: .darkAqua)
        }
        window.title = localModel ? "Lyra Interleaf — Local Qwen" : "Lyra Region Review — Local Mock"
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        runReviewEventLoop()
    }
}
