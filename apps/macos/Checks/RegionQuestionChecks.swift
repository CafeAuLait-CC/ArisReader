import AppKit
import Foundation
import LyraReaderBindings
import LyraReaderKit
import SwiftUI

/// Region questions: the real gap in the page flow, the capture, the request body, anchoring,
/// failures, history, export and the shared Markdown/math renderer.
///
/// Everything here is local. The Rust planner is the production one; `start` is scripted where
/// a stream is needed, and the mock provider is never asked to open a socket.

@MainActor
private class RegionLayoutEngine: PreviewEngine {
    let pageSize = CGSize(width: 600, height: 1200)

    override func openDocument(at url: URL) throws -> LoadedDocument {
        LoadedDocument(title: "Region layout fixture", pageCount: 3, url: url,
                       firstPageSize: pageSize)
    }

    override func contentHeightPt(gapPt: CGFloat) -> CGFloat {
        3 * pageSize.height + 2 * max(0, gapPt)
    }

    override func contentWidthPt(gapPt: CGFloat) -> CGFloat { pageSize.width }

    override func pageTopPt(_ index: Int, gapPt: CGFloat) -> CGFloat {
        CGFloat(max(0, index)) * (pageSize.height + gapPt)
    }

    override func pageIndex(atScrollYPt y: CGFloat, gapPt: CGFloat) -> Int {
        let stride = pageSize.height + gapPt
        return min(2, max(0, Int(floor(y / stride))))
    }

    override func visiblePages(scrollYPt: CGFloat, viewportHeightPt: CGFloat,
                               gapPt: CGFloat, marginPt: CGFloat) -> [PagePlacement] {
        let stride = pageSize.height + gapPt
        return (0..<3).compactMap { index in
            let top = CGFloat(index) * stride
            guard top + pageSize.height >= scrollYPt - marginPt,
                  top <= scrollYPt + viewportHeightPt + marginPt else { return nil }
            return PagePlacement(index: index, topPt: top, leftPt: 0,
                                 widthPt: pageSize.width, heightPt: pageSize.height)
        }
    }

    override func rasterizeRegion(page: Int, scale: CGFloat, xPt: CGFloat, yPt: CGFloat,
                                  widthPt: CGFloat, heightPt: CGFloat,
                                  transparentBackground: Bool) async throws -> PageImage {
        let width = max(1, Int(ceil(widthPt * scale)))
        let height = max(1, Int(ceil(heightPt * scale)))
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        // A dark patch makes the region non-blank without any text layer.
        let patchX = min(width - 1, max(0, width / 4))
        let patchY = min(height - 1, max(0, height / 4))
        for y in patchY..<min(height, patchY + max(1, height / 8)) {
            for x in patchX..<min(width, patchX + max(1, width / 8)) {
                let offset = (y * width + x) * 4
                bytes[offset] = 20
                bytes[offset + 1] = 20
                bytes[offset + 2] = 20
            }
        }
        return PageImage(pixelWidth: width, pixelHeight: height,
                         pointSize: CGSize(width: widthPt, height: heightPt),
                         bgra: Data(bytes), generation: UInt64(page + 100))
    }

    override func textPage(_ page: Int) async throws -> LyraReaderKit.TextPage {
        let text = "Region text 42"
        var chars: [LyraReaderKit.TextChar] = []
        var x: CGFloat = 100
        for scalar in text.unicodeScalars {
            chars.append(LyraReaderKit.TextChar(unicode: scalar.value, xPt: x, yPt: 100,
                                  widthPt: 7, heightPt: 11))
            x += 7
        }
        return LyraReaderKit.TextPage(page: page, chars: chars, text: text, hasUnicodeMapError: false)
    }

    override func renderPage(_ page: Int, scale: CGFloat) async throws -> PageImage {
        PageImage(pixelWidth: 1, pixelHeight: 1, pointSize: pageSize,
                  bgra: Data([255, 255, 255, 255]), generation: UInt64(page + 200))
    }
}

@MainActor
private final class RegionScriptedService: AIChatServicing {
    let base: RustAIChatService
    private var scripts: [[AIStreamEvent]]
    private(set) var startCount = 0

    init(engine: RustEngine, scripts: [[AIStreamEvent]]) {
        self.base = RustAIChatService(engine: engine)
        self.scripts = scripts
    }

    func prepare(_ request: AIMakePlanRequest) async throws -> AiPlanRecord {
        try await base.prepare(request)
    }

    func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle {
        let index = min(startCount, max(0, scripts.count - 1))
        startCount += 1
        return RegionScriptedHandle(events: scripts[index])
    }
}

@MainActor
private final class RegionScriptedHandle: AIChatHandle {
    private var events: [AIStreamEvent]
    private var finished = false

    init(events: [AIStreamEvent]) {
        self.events = events
    }

    func poll() -> [AIStreamEvent] {
        let pending = events
        events = []
        return pending
    }

    func cancel() {
        events = [.error(message: "The request was cancelled.", cancelled: true)]
        finished = true
    }

    var isFinished: Bool { finished }
}

extension ReaderChecks {
    @MainActor
    static func regionQuestionChecks(root: URL) async throws {
        try await regionLayoutChecks()
        try await regionHostedCardChecks()
        try await regionArmingAndMarqueeChecks()
        try await regionCaptureAndRequestChecks(root: root)
        try await regionAnchoringChecks()
        try await regionFailureChecks(root: root)
        try await regionStreamingChecks(root: root)
        try await regionHistoryAndExportChecks(root: root)
        markdownAndMathChecks()
        try await regionNotWrittenChecks(root: root)
    }

    // MARK: - Gap

    @MainActor
    private static func regionLayoutChecks() async throws {
        let state = AppState(engine: RegionLayoutEngine())
        state.setViewportSize(CGSize(width: 900, height: 700))
        let url = URL(fileURLWithPath: "/tmp/lyra-region-layout.pdf")
        require(state.open(url: url), "region layout fixture opens")
        state.reloadVisiblePages()
        require(state.canvasPageFrames.contains(where: { $0.index == 1 }),
                "the layout check can see the page below the insertion row")

        let beforePage0 = state.canvasPageFrames.first { $0.index == 0 }!.topPt
        let beforePage1 = state.canvasPageFrames.first { $0.index == 1 }!.topPt
        let beforeHeight = state.contentHeightPt

        await state.createRegionCard(page: 0, rect: CGRect(x: 100, y: 100, width: 220, height: 90))
        guard let card = state.regionCards.first else {
            fatalError("FAIL: a valid region creates a card")
        }
        require(card.attachment.text.contains("Region text"),
                "the region's text layer was extracted: \(card.attachment.text.debugDescription)")
        require(card.attachment.pixelWidth == Int(ceil(220 * max(2, state.zoomFactor))),
                "the capture is at least 2x and uses the selected rectangle's pixels")
        require(card.attachment.png.starts(with: [0x89, 0x50, 0x4E, 0x47]),
                "the attachment is a PNG")

        state.updateRegionCardHeight(cardID: card.id, viewHeight: 300)
        let gapHeight = 300 / state.zoomFactor
        state.reloadVisiblePages()
        let afterPage0 = state.canvasPageFrames.first { $0.index == 0 }!.topPt
        let afterPage1 = state.canvasPageFrames.first { $0.index == 1 }!.topPt
        require(abs(afterPage0 - beforePage0) < 0.001,
                "the selected page does not move when its card opens")
        require(abs((afterPage1 - beforePage1) - gapHeight) < 0.01,
                "the page below is pushed down by exactly the card's gap: \(afterPage1 - beforePage1) vs \(gapHeight)")
        require(abs(state.contentHeightPt - (beforeHeight + gapHeight)) < 0.01,
                "content height grows by the gap")

        state.closeRegionCard(id: card.id, keepHistory: true)
        state.reloadVisiblePages()
        let restoredPage1 = state.canvasPageFrames.first { $0.index == 1 }!.topPt
        require(abs(restoredPage1 - beforePage1) < 0.001,
                "removing the card restores the page below to its previous offset")
        require(abs(state.contentHeightPt - beforeHeight) < 0.001,
                "removing the card restores the content height")
        require(state.currentRegionHistory.isEmpty,
                "a card with no asked question leaves no history entry when it closes")
    }

    // MARK: - The card geometry, measured in a hosted window

    @MainActor
    private static func regionHostedCardChecks() async throws {
        let state = AppState(engine: RegionLayoutEngine())
        state.setViewportSize(CGSize(width: 900, height: 700))
        require(state.open(url: URL(fileURLWithPath: "/tmp/lyra-region-hosted.pdf")),
                "the hosted card fixture opens")
        state.reloadVisiblePages()
        state.scroll(byScreenPoints: 900)
        state.reloadVisiblePages()
        await state.createRegionCard(page: 0, rect: CGRect(x: 100, y: 100, width: 220, height: 90))
        guard let card = state.regionCards.first else { fatalError("FAIL: hosted card") }

        let container = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.cgColor
        let host = AIRegionOverlayPassthroughView(frame: container.bounds)
        host.autoresizingMask = [.width, .height]
        host.configure(state: state, onOpenInPanel: { _ in }, onShowHistory: {})
        container.addSubview(host)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = container
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        try await Task.sleep(for: .milliseconds(180))
        host.layoutSubtreeIfNeeded()
        try await eventually("the hosted card reports its measured height") {
            card.heightViewPt > 120 && card.heightViewPt <= AIRegionCard.maximumHeight(in: 700)
        }
        try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()

        guard let marker = findView(AIRegionCardMarkerView.self, in: host) else {
            fatalError("FAIL: the hosted region card is missing")
        }
        let frame = host.convert(marker.bounds, from: marker)
        let topInHost = host.isFlipped ? frame.minY : host.bounds.height - frame.maxY
        let gapTop = state.regionGapTop(for: card.id)!
        let expectedTop = CanvasGeometry.viewY(
            contentY: gapTop, scrollYPt: state.scrollYPt, zoom: state.zoomFactor
        )
        require(abs(topInHost - expectedTop) < 1.5,
                "the card's top is placed in the gap at the page point: \(topInHost) vs \(expectedTop)")
        let zoom = state.zoomFactor
        let gap = card.heightViewPt / zoom
        require(frame.height > 120, "the hosted card has a real measured height: \(frame.height)")
        let outsideHit = container.hitTest(NSPoint(x: 24, y: 24))
        let insideHit = container.hitTest(NSPoint(x: frame.midX, y: frame.midY))
        require(outsideHit !== host,
                "the region overlay lets a click outside the card reach the canvas, got \(String(describing: outsideHit))")
        require(insideHit != nil && insideHit !== container,
                "the card itself receives a click, got \(String(describing: insideHit))")
        require(abs(frame.width - 576) < 1.5,
                "the card is page-width minus a margin (576 pt), got \(frame.width)")
        require(abs(frame.minX - 162) < 1.5,
                "the card is centred on the page column, got x=\(frame.minX)")
        // The card's height is measured asynchronously; wait until the layout has applied the
        // same measured gap before comparing page offsets. (A single read can catch the page
        // layout one SwiftUI pass behind the reported height.)
        var settledGap = gap
        try await eventually("the torn page's layout settles at the measured gap") {
            settledGap = card.heightViewPt / state.zoomFactor
            let page0 = state.canvasPageFrames.first { $0.index == 0 }
            let page1 = state.canvasPageFrames.first { $0.index == 1 }
            guard let page0, let page1 else { return false }
            return abs(page1.topPt
                        - (page0.topPt + page0.heightPt + state.pageGapPt + settledGap)) < 0.5
        }
        let page0 = state.canvasPageFrames.first { $0.index == 0 }!
        let page1 = state.canvasPageFrames.first { $0.index == 1 }!
        // The card is now inside page 0: the page's bottom segment and then the next page
        // start after the gap, not at the page row boundary.
        require(abs(page1.topPt - (page0.topPt + page0.heightPt + state.pageGapPt + settledGap)) < 0.6,
                "the page below starts after the torn page and the full measured gap, leaving no overlap (page0 \(page0.topPt)/\(page0.heightPt), page1 \(page1.topPt), gap \(settledGap), pageGap \(state.pageGapPt))")
        let cardBottomInContent = gapTop + settledGap
        require(cardBottomInContent <= page1.topPt,
                "the card ends before the next page starts; it covers no page content")
        require(gapTop > page0.topPt && gapTop < page0.topPt + page0.heightPt,
                "the card's gap is inside the selected page, not at its foot")
        if let directory = ProcessInfo.processInfo.environment["LYRA_REGION_EVIDENCE"] {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            // Page-coloured bands above and below the gap, so the evidence image shows the card
            // occupying a real break in the page flow rather than floating over a blank window.
            container.layer?.backgroundColor = NSColor(calibratedWhite: 0.90, alpha: 1).cgColor
            // The top segment runs to the card's top; the bottom segment starts immediately at
            // the card's bottom (the gap *is* the card, no page gap inside the tear).
            let pageAbove = NSView(frame: NSRect(
                x: 0, y: container.bounds.height - topInHost,
                width: container.bounds.width, height: max(1, topInHost)))
            pageAbove.wantsLayer = true
            pageAbove.layer?.backgroundColor = NSColor.white.cgColor
            container.addSubview(pageAbove, positioned: .below, relativeTo: host)
            let pageBelowTop = container.bounds.height - (topInHost + settledGap)
            let pageBelow = NSView(frame: NSRect(
                x: 0, y: 0, width: container.bounds.width, height: max(1, pageBelowTop)))
            pageBelow.wantsLayer = true
            pageBelow.layer?.backgroundColor = NSColor.white.cgColor
            container.addSubview(pageBelow, positioned: .below, relativeTo: host)
            container.layoutSubtreeIfNeeded()
            if let bitmap = container.bitmapImageRepForCachingDisplay(in: container.bounds) {
                container.cacheDisplay(in: container.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent("region-card.png")
                )
            }
        }
        state.closeRegionCard(id: card.id, keepHistory: false)
        try await eventually("removing the card removes it from the hosted overlay") {
            host.layoutSubtreeIfNeeded()
            return findView(AIRegionCardMarkerView.self, in: host) == nil
        }
    }

    @MainActor
    private static func findView<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = findView(type, in: subview) { return match }
        }
        return nil
    }

    // MARK: - Arming and marquee

    @MainActor
    private static func regionArmingAndMarqueeChecks() async throws {
        let state = AppState(engine: RegionLayoutEngine())
        state.setViewportSize(CGSize(width: 900, height: 700))
        _ = state.open(url: URL(fileURLWithPath: "/tmp/lyra-region-arm.pdf"))
        state.armRegionSelection()
        require(state.regionSelectionArmed, "the toolbar can arm a region selection")
        state.toggleRegionSelection()
        require(!state.regionSelectionArmed, "a second press disarms it")

        state.annotationTool = .pen
        require(!state.canArmRegionSelection, "a drawing tool makes the region tool unavailable")
        require(state.regionSelectionUnavailableReason?.contains("Select") == true,
                "the reason names the mode that must be left")
        state.annotationTool = .select
        state.contentEditEnabled = true
        require(!state.canArmRegionSelection, "Edit PDF makes the region tool unavailable")
        state.contentEditEnabled = false
        state.formToolActive = true
        require(!state.canArmRegionSelection, "Fill & Sign makes the region tool unavailable")
        state.formToolActive = false

        // The real canvas gesture, driven through the same methods the mouse events use.
        let canvas = MetalCanvasView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        canvas.zoom = 1
        canvas.scrollYPt = 0
        canvas.contentWidthPt = 600
        canvas.annotationPageFrames = [
            PagePlacement(index: 0, topPt: 0, leftPt: 150, widthPt: 600, heightPt: 1200)
        ]
        var selected: (Int, CGRect)?
        var cancelled: String?
        canvas.onRegionSelection = { selected = ($0, $1) }
        canvas.onRegionSelectionCancelled = { cancelled = $0 }
        canvas.regionSelectionArmed = true
        canvas.simulateRegionGesture(fromContent: CGPoint(x: 250, y: 100),
                                     toContent: CGPoint(x: 450, y: 250))
        require(selected?.0 == 0, "a drag selects the page it started on")
        require(abs((selected?.1.width ?? 0) - 200) < 0.01
                && abs((selected?.1.height ?? 0) - 150) < 0.01,
                "the marquee's page-local rectangle matches the drag: \(String(describing: selected?.1))")
        require(cancelled == nil, "a valid marquee is not cancelled")

        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53
        )!
        canvas.onRegionSelection = { (_: Int, _: CGRect) in fatalError("FAIL: Escape must not select") }
        canvas.onRegionSelectionCancelled = { cancelled = $0 }
        canvas.regionSelectionArmed = true
        canvas.keyDown(with: event)
        require(cancelled != nil, "Escape during selection cancels without creating a card")

        if let directory = ProcessInfo.processInfo.environment["LYRA_REGION_EVIDENCE"] {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let marqueeHost = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
            marqueeHost.wantsLayer = true
            marqueeHost.layer?.backgroundColor = NSColor.white.cgColor
            let marquee = AIRegionMarqueeOverlayView(frame: marqueeHost.bounds)
            marqueeHost.addSubview(marquee)
            marquee.update(CGRect(x: 70, y: 60, width: 260, height: 150))
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 500, height: 300),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.contentView = marqueeHost
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            marqueeHost.layoutSubtreeIfNeeded()
            if let bitmap = marqueeHost.bitmapImageRepForCachingDisplay(in: marqueeHost.bounds) {
                marqueeHost.cacheDisplay(in: marqueeHost.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent("region-marquee.png")
                )
            }
        }
    }

    // MARK: - Capture and request

    @MainActor
    private static func regionCaptureAndRequestChecks(root: URL) async throws {
        let suite = "lyra-region-ai-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AISettingsStore(
            defaults: defaults,
            keyStore: InMemoryAPIKeyStore(key: "sk-region-check")
        )
        require(settings.save(
            baseURL: "http://127.0.0.1:11434/v1", model: "mock-model",
            temperature: 0.2, maxTokens: 900, apiKey: nil,
            reasoningMode: .off, reasoningEncoding: .thinking,
            modelAcceptsImages: false
        ), "the region check's isolated settings are valid")

        let engine = try RustEngine()
        let state = AppState(engine: engine)
        state.setViewportSize(CGSize(width: 1000, height: 800))
        state.regionAssistantFactory = { AIAssistantModel(settings: settings) }
        state.regionChatServiceOverride = { RustAIChatService(engine: engine, useMockProvider: true) }
        let fixture = root.appendingPathComponent("tests/fixtures/text-page.pdf")
        require(state.open(url: fixture), "the text fixture opens for a region question")
        state.reloadVisiblePages()
        guard let placement = state.canvasPageFrames.first(where: { $0.index == 0 }) else {
            fatalError("FAIL: page one is visible")
        }
        let rect = CGRect(x: 60, y: 60,
                          width: min(360, placement.widthPt - 120),
                          height: min(180, placement.heightPt - 120))
        await state.createRegionCard(page: 0, rect: rect)
        guard let card = state.regionCards.first else {
            fatalError("FAIL: a real text region creates a card")
        }
        require(card.attachment.text.count > 5,
                "the request text comes from the text layer inside the rectangle: \(card.attachment.text.prefix(40))")
        let expectedScale = max(2, state.zoomFactor)
        require(card.attachment.pixelWidth == Int(ceil(rect.width * expectedScale))
                && card.attachment.pixelHeight == Int(ceil(rect.height * expectedScale)),
                "the captured PNG is the selected page rectangle at the expected pixel size")

        card.question = "What does this passage say?"
        await card.assistant.prepareRegion(
            question: card.question,
            attachment: card.attachment,
            context: state.aiReaderContext!
        )
        guard let textPlan = card.assistant.plan else {
            fatalError("FAIL: the text-only preview was built: \(card.assistant.errorMessage ?? "")")
        }
        require(textPlan.parts.first?.pageCharacters == UInt64(card.attachment.text.count),
                "the plan reports the region's extracted character count")
        require(textPlan.parts.first?.userPrompt.contains(card.attachment.text) == true,
                "the request prompt carries the extracted text of the selected region")
        require(textPlan.parts.first?.wireBody.contains("image_url") == false,
                "a text-only model configuration sends no image part")
        require(textPlan.note?.contains("text only") == true,
                "the preview states the text-only degradation: \(textPlan.note ?? "nil")")

        require(settings.save(
            baseURL: "http://127.0.0.1:11434/v1", model: "mock-model",
            temperature: 0.2, maxTokens: 900, apiKey: nil,
            reasoningMode: .off, reasoningEncoding: .thinking,
            modelAcceptsImages: true
        ), "the vision configuration saves")
        await card.assistant.prepareRegion(
            question: card.question,
            attachment: card.attachment,
            context: state.aiReaderContext!
        )
        guard let visionPlan = card.assistant.plan else {
            fatalError("FAIL: the vision preview was built: \(card.assistant.errorMessage ?? "")")
        }
        require(visionPlan.parts.first?.wireBody.contains("\"image_url\"") == true,
                "a vision configuration includes the image part in the exact request body")
        require(visionPlan.parts.first?.wireBody.contains("data:image/png;base64,") == true,
                "the image part is a PNG data URL")
        state.closeRegionCard(id: card.id, keepHistory: true)
        state.clearRegionHistory()
    }

    // MARK: - Anchoring

    @MainActor
    private static func regionAnchoringChecks() async throws {
        let state = AppState(engine: RegionLayoutEngine())
        state.setViewportSize(CGSize(width: 900, height: 700))
        _ = state.open(url: URL(fileURLWithPath: "/tmp/lyra-region-anchor.pdf"))
        state.reloadVisiblePages()
        await state.createRegionCard(page: 0, rect: CGRect(x: 100, y: 100, width: 220, height: 90))
        guard let card = state.regionCards.first else { fatalError("FAIL: anchor card") }
        state.updateRegionCardHeight(cardID: card.id, viewHeight: 260)
        let gapTop = state.regionGapTop(for: card.id)!
        let beforeZoom = state.zoomFactor
        let viewY100 = CanvasGeometry.viewY(contentY: gapTop, scrollYPt: state.scrollYPt,
                                            zoom: beforeZoom)
        state.scroll(byScreenPoints: 200)
        let viewYScrolled = CanvasGeometry.viewY(contentY: gapTop, scrollYPt: state.scrollYPt,
                                                 zoom: state.zoomFactor)
        require(abs((viewY100 - viewYScrolled) - 200) < 0.01,
                "scrolling keeps the card attached to its page point")
        require(abs(state.regionGapTop(for: card.id)! - gapTop) < 0.001,
                "the card's gap top does not move in content space when scrolling")

        for _ in 0..<5 { state.zoomIn() }
        let viewY150 = CanvasGeometry.viewY(contentY: gapTop, scrollYPt: state.scrollYPt,
                                            zoom: state.zoomFactor)
        require(state.zoomPercent == 150,
                "the anchoring check reaches 150%, got \(state.zoomPercent)%")
        require(abs(viewY150 - ((gapTop - state.scrollYPt) * state.zoomFactor)) < 0.01,
                "at 150% the card is still at its page point")
        let page0 = state.canvasPageFrames.first { $0.index == 0 }!
        let page1 = state.canvasPageFrames.first { $0.index == 1 }!
        let expectedGap = 260 / state.zoomFactor
        require(abs(page1.topPt - (page0.topPt + page0.heightPt + state.pageGapPt + expectedGap)) < 0.01,
                "at 150% the page below still starts after the torn page and the measured gap: \(page1.topPt) vs \(page0.topPt + page0.heightPt + state.pageGapPt + expectedGap)")
        state.closeRegionCard(id: card.id, keepHistory: false)
    }

    // MARK: - Failures

    @MainActor
    private static func regionFailureChecks(root: URL) async throws {
        let state = AppState(engine: RegionLayoutEngine())
        state.setViewportSize(CGSize(width: 900, height: 700))
        _ = state.open(url: URL(fileURLWithPath: "/tmp/lyra-region-failure.pdf"))
        await state.createRegionCard(page: 0, rect: .zero)
        require(state.regionRefusalMessage?.contains("empty") == true,
                "an empty selection refuses with a reason: \(state.regionRefusalMessage ?? "nil")")
        require(state.regionCards.isEmpty, "an empty selection creates no card")

        await state.createRegionCard(page: 0,
                                     rect: CGRect(x: 10, y: 10, width: 5000, height: 5000))
        require(state.regionRefusalMessage?.contains("attachment bound") == true,
                "an oversized selection refuses and states the bound: \(state.regionRefusalMessage ?? "nil")")
        require(state.regionCards.isEmpty, "an oversized selection creates no card")

        // An area with neither text nor ink refuses even though it has positive dimensions.
        let blank = AppState(engine: BlankRegionEngine())
        blank.setViewportSize(CGSize(width: 900, height: 700))
        _ = blank.open(url: root.appendingPathComponent("tests/fixtures/text-page.pdf"))
        await blank.createRegionCard(page: 0, rect: CGRect(x: 50, y: 50, width: 200, height: 100))
        require(blank.regionRefusalMessage?.contains("blank") == true,
                "a blank region refuses with a reason: \(blank.regionRefusalMessage ?? "nil")")

        // The request builder refuses an empty region again, so a stale caller cannot send it.
        require(AIRegionLimits.refusal(for: .zero, scale: 1, zoom: 1) != nil,
                "the attachment bound refuses a zero rectangle before capture")
        require(AIRegionLimits.refusal(
            for: CGRect(x: 0, y: 0, width: 2000, height: 2000), scale: 1, zoom: 2
        ) != nil, "the attachment bound refuses a region over 4 megapixels")
    }

    // MARK: - Streaming

    @MainActor
    private static func regionStreamingChecks(root: URL) async throws {
        let suite = "lyra-region-stream-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AISettingsStore(
            defaults: defaults,
            keyStore: InMemoryAPIKeyStore(key: "sk-region-stream")
        )
        _ = settings.save(
            baseURL: "http://127.0.0.1:11434/v1", model: "mock-model",
            temperature: 0.2, maxTokens: 900, apiKey: nil
        )
        let engine = try RustEngine()
        _ = try engine.openDocument(
            at: root.appendingPathComponent("tests/fixtures/text-page.pdf")
        )
        let attachment = syntheticAttachment()

        let cancelService = RegionScriptedService(
            engine: engine,
            scripts: [[.delta("Partial "), .delta("answer")]]
        )
        let cancelModel = AIAssistantModel(settings: settings)
        let cancelCard = AIRegionCard(
            documentKey: "stream-check", attachment: attachment, assistant: cancelModel
        )
        let context = AIReaderContext(
            documentKey: "stream-check", documentTitle: "Stream", pageCount: 3,
            currentPage: 1, selection: nil
        )
        cancelModel.attach(service: cancelService, context: context)
        await cancelModel.prepareRegion(
            question: "Explain this region", attachment: attachment, context: context
        )
        require(cancelModel.plan != nil,
                "the streaming check has a preview: phase=\(cancelModel.phase) error=\(cancelModel.errorMessage ?? "nil") status=\(cancelModel.statusNote ?? "nil")")
        cancelModel.send()
        try await eventually("the partial answer streams into the card") {
            cancelModel.answer.contains("Partial")
        }
        cancelModel.cancel()
        try await eventually("cancel ends the stream and keeps the partial answer") {
            cancelModel.phase == .cancelled && cancelModel.answer == "Partial answer"
        }
        require(cancelModel.answer == "Partial answer",
                "cancelling keeps exactly the partial answer that arrived")
        require(cancelModel.canRetry, "a cancelled answer can be retried")
        require(cancelCard.historyEntry?.answer == "Partial answer"
                && cancelCard.historyEntry?.state == .cancelled,
                "closing a cancelled card keeps the partial answer and says it was cancelled")
        let startsAfterCancel = cancelService.startCount
        cancelModel.retry()
        try await eventually("retry starts the same previewed request again") {
            cancelService.startCount == startsAfterCancel + 1
        }
        cancelModel.cancel()
        _ = cancelCard

        let failService = RegionScriptedService(
            engine: engine,
            scripts: [[.error(message: "Provider exploded", cancelled: false)]]
        )
        let failModel = AIAssistantModel(settings: settings)
        let failContext = AIReaderContext(
            documentKey: "fail-check", documentTitle: "Fail", pageCount: 3,
            currentPage: 1, selection: nil
        )
        failModel.attach(service: failService, context: failContext)
        await failModel.prepareRegion(
            question: "Explain this region", attachment: attachment, context: failContext
        )
        failModel.send()
        try await eventually("a provider error is shown in the answer cell") {
            failModel.phase == .failed && failModel.errorMessage == "Provider exploded"
        }
        require(failModel.answer.isEmpty, "a provider error with no tokens leaves the answer empty")
        require(failModel.canRetry, "a failed answer can be retried")
        failModel.retry()
        try await eventually("retry sends the failed request again") {
            failService.startCount == 2 && failModel.phase == .failed
        }

        let finishService = RegionScriptedService(
            engine: engine,
            scripts: [[.delta("Finished "), .delta("answer"), .done]]
        )
        let finishModel = AIAssistantModel(settings: settings)
        let finishCard = AIRegionCard(
            documentKey: "finish-check", attachment: attachment, assistant: finishModel
        )
        let finishContext = AIReaderContext(
            documentKey: "finish-check", documentTitle: "Finish", pageCount: 3,
            currentPage: 1, selection: nil
        )
        finishModel.attach(service: finishService, context: finishContext)
        await finishModel.prepareRegion(
            question: "Finish this", attachment: attachment, context: finishContext
        )
        finishModel.send()
        try await eventually("a finished answer completes in the card") {
            finishModel.phase == .finished && finishModel.answer == "Finished answer"
        }
        require(finishCard.historyEntry?.answer == "Finished answer"
                && finishCard.historyEntry?.state == .finished,
                "closing a finished card keeps the full answer")
    }

    private static func syntheticAttachment() -> AIRegionAttachment {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        return AIRegionAttachment(
            page: 0, rect: CGRect(x: 100, y: 100, width: 220, height: 90),
            text: "Sample region text", png: png, pixelWidth: 440, pixelHeight: 180,
            captureScale: 2
        )
    }

    // MARK: - History and export

    @MainActor
    private static func regionHistoryAndExportChecks(root: URL) async throws {
        let suite = "lyra-region-history-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AISettingsStore(
            defaults: defaults,
            keyStore: InMemoryAPIKeyStore(key: "sk-region-history")
        )
        _ = settings.save(
            baseURL: "http://127.0.0.1:11434/v1", model: "mock-model",
            temperature: 0.2, maxTokens: 900, apiKey: nil
        )
        let engine = try RustEngine()
        _ = try engine.openDocument(
            at: root.appendingPathComponent("tests/fixtures/text-page.pdf")
        )
        let state = AppState(engine: engine)
        state.setViewportSize(CGSize(width: 900, height: 700))
        state.regionAssistantFactory = { AIAssistantModel(settings: settings) }
        state.regionChatServiceOverride = {
            RustAIChatService(engine: engine, useMockProvider: true)
        }
        require(state.open(url: root.appendingPathComponent("tests/fixtures/text-page.pdf")),
                "the history fixture opens")
        await state.createRegionCard(page: 0, rect: CGRect(x: 60, y: 60, width: 300, height: 140))
        guard let card = state.regionCards.first else { fatalError("FAIL: history card") }
        card.question = "What is here?"
        await card.assistant.prepareRegion(
            question: card.question,
            attachment: card.attachment,
            context: state.aiReaderContext!
        )
        require(card.askedQuestion == "What is here?",
                "the card records the question it will keep")
        let key = state.regionDocumentKey!

        // Starting a new region question closes the previous card into history rather than
        // stacking a second gap.
        await state.createRegionCard(page: 0, rect: CGRect(x: 60, y: 200, width: 300, height: 140))
        guard let second = state.regionCards.first else { fatalError("FAIL: second history card") }
        require(state.regionCards.count == 1,
                "starting a new region question leaves one open card")
        var history = state.regionHistory[key] ?? []
        require(history.count == 1 && history[0].question == "What is here?",
                "the previous conversation was kept in history when the new one started")
        second.question = "Second question"
        await second.assistant.prepareRegion(
            question: second.question,
            attachment: second.attachment,
            context: state.aiReaderContext!
        )
        // A document switch closes the open card into history instead of losing it.
        state.finishRegionCardsForDocumentSwitch()
        history = state.regionHistory[key] ?? []
        require(state.regionCards.isEmpty, "a document switch closes the open card")
        require(history.count == 2, "a document switch keeps the conversation in history")
        require(history.contains(where: { $0.question == "Second question" }),
                "the switched card's question survived the close")

        // "Open in the AI panel" is an explicit copy into the panel's conversation; it does not
        // create an annotation or touch the PDF.
        let panelModel = AIAssistantModel(settings: settings)
        panelModel.importConversation(
            question: "What is here?",
            answer: "A region answer.",
            attachment: history[0].attachment,
            context: state.aiReaderContext!
        )
        require(panelModel.chatTurns.last?.question == "What is here?"
                && panelModel.chatTurns.last?.answer == "A region answer.",
                "the panel copy carries the question and answer verbatim")
        require(panelModel.selectedTab == .chat,
                "the panel copy opens the chat workspace")
        let exportEntries = [
            AIRegionHistoryEntry(
                id: history[0].id, documentKey: key, attachment: history[0].attachment,
                question: "What is $E=mc^2$ in this table?\n> quote stays\n<script>alert(1)</script>",
                answer: "It is **mass-energy**.\n\n$$\n\\frac{a}{b}\n$$",
                state: .finished, createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            AIRegionHistoryEntry(
                documentKey: key, attachment: history[0].attachment,
                question: "Unanswered", answer: "", state: .failed,
                createdAt: Date(timeIntervalSince1970: 1_700_000_100)
            ),
        ]

        let document = AIRegionMarkdownExport.render(
            documentTitle: "Region Paper",
            documentFileName: "region-paper.pdf",
            entries: exportEntries,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_200),
            imageFolderName: "region-paper-images"
        )
        require(document.markdown.contains("# Reading notes — Region Paper"),
                "the export has a document title")
        require(document.markdown.contains("## Contents"), "the export has a table of contents")
        require(document.markdown.contains("region-paper-images/region-01.png"),
                "images are linked relatively, never inlined as base64")
        require(!document.markdown.contains("base64,"), "the Markdown contains no base64 image data")
        require(document.markdown.contains("$E=mc^2$")
                && document.markdown.contains("$$"),
                "the answer's mathematics source is preserved unchanged")
        require(document.markdown.contains("&lt;script&gt;")
                && !document.markdown.contains("<script>"),
                "HTML in a question is escaped")
        require(document.markdown.contains("Omitted:** 1 conversation"),
                "unanswered conversations are counted in the export")
        require(document.omittedCount == 1, "one unanswered conversation was omitted")
        require(document.images.count == 1, "one answered conversation contributes one image")
        require(AIRegionMarkdownExport.refusalReason(for: []) != nil,
                "an empty history is refused before an empty file is written")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-region-export-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Region Notes.md")
        let outcome = try AIRegionMarkdownExport.write(
            entries: exportEntries, documentTitle: "Region Paper",
            documentFileName: "region-paper.pdf", to: url,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        require(FileManager.default.fileExists(atPath: url.path),
                "the Markdown file was written")
        require(FileManager.default.fileExists(
            atPath: outcome.imageFolderURL.appendingPathComponent("region-01.png").path),
                "the region picture was written into the sibling folder")
        require(outcome.imageCount == 1 && outcome.omittedCount == 1,
                "the export outcome reports the written pictures and omissions")
        require(outcome.imageFolderURL.lastPathComponent == "Region-Notes-images",
                "the image folder is derived from the Markdown file name")
    }

    // MARK: - Markdown and math

    @MainActor
    private static func markdownAndMathChecks() {
        let answer = #"""
        # Findings

        Inline math $E=mc^2$ and $\alpha_i$ (\(\beta_j\)), plus a [link](https://example.com) and <b>literal HTML</b>.

        ## Detail

        - first
          - nested
        - second

        > A quote with **bold**.

        ```swift
        let x = 1
        ```

        | Name | Value |
        | --- | ---: |
        | alpha | 1 |
        | beta | 2 |

        $$
        \frac{a}{b} + \sum_{i=1}^{n} i
        $$

        Unsupported:

        $$
        \foo{bar}
        $$
        """#
        let document = ReaderMarkdown.parse(answer, pageCount: 3)
        require(document.blocks.count >= 11,
                "the fixture renders as headings, lists, a table, code, maths and paragraphs: \(document.blocks.count)")
        var headingCount = 0
        var nestedBullet: Int?
        var tableRows = 0
        var tableHeaders = 0
        var codeLanguage: String?
        var quoteCount = 0
        var mathBlocks = 0
        for block in document.blocks {
            switch block {
            case .heading: headingCount += 1
            case .bullet(let depth, _): if depth > 0 { nestedBullet = depth }
            case .table(let headers, _, let rows):
                tableHeaders = headers.count
                tableRows = rows.count
            case .code(let language, _): codeLanguage = language
            case .quote: quoteCount += 1
            case .mathBlock: mathBlocks += 1
            default: break
            }
        }
        require(headingCount == 2, "headings render as headings")
        require(nestedBullet == 1, "a nested list keeps its depth")
        require(tableHeaders == 2 && tableRows == 2, "the table has two columns and two body rows")
        require(codeLanguage == "swift", "a fenced code block keeps its language")
        require(quoteCount == 1, "a block quote renders as a quote")
        require(mathBlocks == 2, "display math renders as display math (including the fallback)")
        let containsHTML = document.blocks.contains { block in
            if case .paragraph(let runs) = block {
                return runs.contains { inline in
                    if case .text(let text) = inline { return text.contains("<b>") }
                    return false
                }
            }
            return false
        }
        require(containsHTML, "inline HTML is escaped as literal text, not injected")
        require(document.containsMath, "the document reports that it contains mathematics")

        // Math subset and fallback.
        let expressions = [
            #"E=mc^2"#, #"\alpha_i"#, #"\frac{a}{b}"#,
            #"\sum_{i=1}^{n} i"#, #"\sqrt{x}"#,
            #"\begin{pmatrix}a&b\\c&d\end{pmatrix}"#,
            #"\begin{cases} x & x>0 \\ -x & x\le 0 \end{cases}"#,
            #"\left( \frac{a+b}{c} \right)"#,
            #"\int_0^1 x^2\,dx"#,
            #"\sqrt[3]{x}"#,
        ]
        for expression in expressions {
            switch ReaderMathRenderer.render(expression, fontSize: 13, display: true) {
            case .success(let rendered):
                require(rendered.size.width > 0 && rendered.size.height > 0,
                        "math renders with a positive size: \(expression)")
            case .failure(let error):
                fatalError("FAIL: supported math did not render: \(expression) (\(error))")
            }
        }
        if case .success = ReaderMathRenderer.render(#"\frac{1}{2}"#, fontSize: 13) {
            require(true, "a fraction renders")
        } else {
            fatalError("FAIL: a fraction must render")
        }
        require(ReaderMathRenderer.unsupportedReason(for: #"\foo{bar}"#) != nil,
                "an unsupported command reports its fallback reason")

        // Streaming: every prefix is a document, no prefix leaks display delimiters or fences,
        // and the trailing display-math block is stable once its opener has arrived.
        let characters = Array(answer)
        var lastMathWasStable = true
        for length in 1...characters.count {
            let prefix = String(characters.prefix(length))
            let parsed = ReaderMarkdown.parse(prefix, pageCount: 3)
            let flattened = flatten(parsed)
            if flattened.contains("$$") || flattened.contains("```") {
                fatalError("FAIL: a streaming prefix leaked a raw delimiter at \(length)")
            }
            if prefix.contains("\\foo{bar}") {
                lastMathWasStable = lastMathWasStable && parsed.blocks.contains {
                    if case .mathBlock = $0 { return true }
                    return false
                }
            }
        }
        require(lastMathWasStable,
                "an unclosed display-math construct stays a math block while streaming")
        require(ReaderMarkdown.parse(answer, pageCount: 3) == document,
                "the final streamed layout is stable")

        if let directory = ProcessInfo.processInfo.environment["LYRA_REGION_EVIDENCE"] {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let view = ReaderMarkdownView(document: document, pageCount: 3)
                .padding(16)
                .frame(width: 620, alignment: .leading)
                .background(Color.white)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 620, height: 760)
            let container = NSView(frame: host.frame)
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.white.cgColor
            container.addSubview(host)
            let window = NSWindow(
                contentRect: host.frame, styleMask: [.titled],
                backing: .buffered, defer: false
            )
            window.contentView = container
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            if let bitmap = container.bitmapImageRepForCachingDisplay(in: container.bounds) {
                container.cacheDisplay(in: container.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent("answer-typography.png")
                )
            }
        }
    }

    private static func flatten(_ document: ReaderMarkdownDocument) -> String {
        var result = ""
        func appendInline(_ inline: ReaderMarkdownInline) {
            switch inline {
            case .text(let text), .code(let text), .math(let text):
                result += text
            case .mathFallback(let source, _):
                result += source
            case .bold(let runs), .italic(let runs), .strikethrough(let runs):
                runs.forEach(appendInline)
            case .link(let runs, _):
                runs.forEach(appendInline)
            case .citation(_, let raw):
                result += raw
            }
        }
        func appendBlock(_ block: ReaderMarkdownBlock) {
            switch block {
            case .heading(_, let runs), .paragraph(let runs):
                runs.forEach(appendInline)
            case .bullet(_, let runs):
                runs.forEach(appendInline)
            case .numbered(_, _, let runs):
                runs.forEach(appendInline)
            case .quote(let blocks):
                blocks.forEach(appendBlock)
            case .code(_, let source):
                result += source
            case .table(let headers, _, let rows):
                headers.forEach { $0.forEach(appendInline) }
                rows.forEach { $0.forEach { $0.forEach(appendInline) } }
            case .mathBlock(let source, _):
                result += source
            case .divider:
                break
            }
        }
        document.blocks.forEach(appendBlock)
        return result
    }

    // MARK: - The PDF is untouched

    @MainActor
    private static func regionNotWrittenChecks(root: URL) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-region-untouched-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = scratch.appendingPathComponent("text-page.pdf")
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: fixture
        )
        let before = try Data(contentsOf: fixture)
        let filesBefore = try FileManager.default.contentsOfDirectory(
            atPath: scratch.path
        ).sorted()

        let engine = try RustEngine()
        let state = AppState(engine: engine)
        state.setViewportSize(CGSize(width: 1000, height: 800))
        require(state.open(url: fixture), "the untouched-PDF fixture opens")
        await state.createRegionCard(page: 0, rect: CGRect(x: 60, y: 60, width: 300, height: 150))
        guard let card = state.regionCards.first else { fatalError("FAIL: untouched card") }
        card.question = "Does this write?"
        state.closeRegionCard(id: card.id, keepHistory: true)
        let after = try Data(contentsOf: fixture)
        let filesAfter = try FileManager.default.contentsOfDirectory(
            atPath: scratch.path
        ).sorted()
        require(before == after, "the PDF bytes are unchanged by a region question")
        require(filesBefore == filesAfter,
                "no annotation or sidecar file appears beside the PDF: \(filesBefore) -> \(filesAfter)")
        require(state.annotations.isEmpty, "the reader's annotation model is unchanged")
        require(state.documentAnnotations.isEmpty, "no PDF annotation was added")
    }
}

/// An engine whose capture is pure white: it proves the "blank region" refusal without relying
/// on a particular fixture's whitespace.
@MainActor
private final class BlankRegionEngine: RegionLayoutEngine {
    override func rasterizeRegion(page: Int, scale: CGFloat, xPt: CGFloat, yPt: CGFloat,
                                  widthPt: CGFloat, heightPt: CGFloat,
                                  transparentBackground: Bool) async throws -> PageImage {
        let width = max(1, Int(ceil(widthPt * scale)))
        let height = max(1, Int(ceil(heightPt * scale)))
        return PageImage(pixelWidth: width, pixelHeight: height,
                         pointSize: CGSize(width: widthPt, height: heightPt),
                         bgra: Data(repeating: 255, count: width * height * 4),
                         generation: 7)
    }

    override func textPage(_ page: Int) async throws -> LyraReaderKit.TextPage {
        TextPage(page: page, chars: [], text: "", hasUnicodeMapError: false)
    }
}
