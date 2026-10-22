import AppKit
import Foundation
@testable import LyraReaderKit
import LyraReaderBindings

/// In-place translation, checked without a network: the production Rust plan builder and the
/// deterministic mock provider, with request counts read from the service wrapper.
///
/// The checks cover the camera-translation contract: the cover is exactly the block, toggling
/// restores the page pixels and never sends, the cache survives tabs and relaunch, changing the
/// model or language is a new request, editing one block invalidates only that block, the
/// multi-block bound sends the stated number of requests, cancel leaves the page clean, and a
/// rotation/deletion removes the overlay with an explanation.
@MainActor
private final class CountingTranslationService: AIChatServicing {
    let base: RustAIChatService
    private(set) var startCount = 0
    private(set) var preparedSelections: [AIReaderSelection] = []

    init(engine: RustEngine) {
        // `useMockProvider` is the checks' deterministic, socket-free transport. The app never
        // sets it; every count below is therefore a request the reader's action would have made.
        base = RustAIChatService(engine: engine, useMockProvider: true)
    }

    func prepare(_ request: AIMakePlanRequest) async throws -> AiPlanRecord {
        if let selection = request.selection { preparedSelections.append(selection) }
        return try await base.prepare(request)
    }

    func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle {
        startCount += 1
        return try base.start(plan, apiKey: apiKey)
    }
}

@MainActor
private final class TranslationPixelPage: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        NSColor(calibratedWhite: 0.2, alpha: 1).setFill()
        NSRect(x: 10, y: 20, width: 60, height: 2).fill()
        NSRect(x: 400, y: 300, width: 120, height: 2).fill()
    }
}

/// A torn page drawn as two paper pieces with the card's gap between them. The overlay must
/// never paint into that gap, and Show original must leave all three bands byte-identical.
@MainActor
private final class TranslationTornPage: NSView {
    static let pageLeft: CGFloat = 50
    static let pageWidth: CGFloat = 400
    static let splitPt: CGFloat = 300
    static let gapPt: CGFloat = 200
    static let pageHeight: CGFloat = 700

    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        // Canvas surround.
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        bounds.fill()
        // The paper above and below the tear.
        NSColor.white.setFill()
        NSRect(x: Self.pageLeft, y: 0, width: Self.pageWidth, height: Self.splitPt).fill()
        NSRect(x: Self.pageLeft, y: Self.splitPt + Self.gapPt,
               width: Self.pageWidth, height: Self.pageHeight - Self.splitPt).fill()
        // The card's gap.
        NSColor(calibratedRed: 0.86, green: 0.93, blue: 0.98, alpha: 1).setFill()
        NSRect(x: Self.pageLeft, y: Self.splitPt,
               width: Self.pageWidth, height: Self.gapPt).fill()
    }
}

extension ReaderChecks {
    @MainActor
    static func inPlaceTranslationChecks(root: URL) async throws {
        try await inPlaceTranslationCacheAndToggleChecks(root: root)
        try await inPlaceTranslationTabAndRelaunchChecks(root: root)
        try await inPlaceTranslationKeyAndEditChecks(root: root)
        try await inPlaceTranslationBatchCancelAndPageEditChecks(root: root)
        try await inPlaceTranslationAuditChecks(root: root)
        try await inPlaceTranslationRegionTearChecks(root: root)
        try inPlaceTranslationTearGeometryChecks()
        try inPlaceTranslationLayoutAndChipChecks()
    }

    // MARK: - Fixtures

    @MainActor
    private static func translationSettings(model: String = "mock-model-a") -> (AISettingsStore, UserDefaults, String) {
        let suite = "lyra-reader-translation-checks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let key = "sk-check-not-a-real-key"
        let store = AISettingsStore(defaults: defaults, keyStore: InMemoryAPIKeyStore(key: key))
        require(store.save(baseURL: "http://127.0.0.1:1/v1", model: model,
                           temperature: 0.2, maxTokens: 900, apiKey: key),
                "translation checks configure the deterministic provider")
        return (store, defaults, suite)
    }

    @MainActor
    private static func translationFixture(root: URL, named name: String) throws -> URL {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-inplace-translation-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let destination = scratch.appendingPathComponent(name)
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("tests/fixtures/\(name)"), to: destination)
        return destination
    }

    @MainActor
    private static func makeTranslationState(
        engine: RustEngine, settings: AISettingsStore, service: CountingTranslationService,
        url: URL
    ) async throws -> AppState {
        let state = AppState(engine: engine)
        state.setViewportSize(CGSize(width: 1000, height: 800))
        state.inPlaceTranslationSettingsOverride = settings
        state.inPlaceTranslationServiceOverride = { service }
        state.inPlaceTranslationTargetLanguage = "English"
        require(state.newTab(url: url), "translation fixture opens in a tab")
        try await eventually("translation fixture lays out") {
            state.document?.url == url && !state.canvasPageFrames.isEmpty
        }
        return state
    }

    @MainActor
    private static func blockContaining(_ needle: String, textPage: LyraReaderKit.TextPage) -> TranslationBlock {
        let blocks = TranslationBlockDetector.blocks(page: 0, textPage: textPage)
        guard let block = blocks.first(where: { $0.sourceText.contains(needle) }) else {
            fatalError("No translation block contains \(needle). Blocks: \(blocks.map(\.sourceText))")
        }
        return block
    }

    @MainActor
    private static func waitForTranslation(_ state: AppState, count: Int = 1) async throws {
        try await eventually("translation overlay settles") {
            state.translationOverlays.filter { $0.isTranslated }.count >= count
        }
    }

    // MARK: - Toggle, pixels and the cache key

    @MainActor
    private static func inPlaceTranslationCacheAndToggleChecks(root: URL) async throws {
        let paper = try translationFixture(root: root, named: "text-page.pdf")
        let (settings, defaults, suite) = translationSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = try RustEngine()
        let service = CountingTranslationService(engine: engine)
        let state = try await makeTranslationState(engine: engine, settings: settings,
                                                   service: service, url: paper)
        guard let textPage = await state.translationTextPage(0) else {
            fatalError("translation fixture has no text layer")
        }
        let block = blockContaining("Line 1", textPage: textPage)

        guard let placement = state.canvasPageFrames.first(where: { $0.index == 0 }) else {
            fatalError("The translation fixture has no page placement")
        }
        let menuPoint = CGPoint(x: placement.leftPt + block.rect.midX,
                                y: placement.topPt + block.rect.midY)
        let noSelectionItems = CanvasContextMenu.items(state: state, at: menuPoint)
        require(!noSelectionItems.contains { $0.action == .translateSelection },
                "a right-click with no selection offers no Translate item")
        state.selectTranslationRange(page: 0, range: block.range)
        let selectedItems = CanvasContextMenu.items(state: state, at: menuPoint)
        require(selectedItems.contains { $0.action == .translateSelection && $0.title == "Translate" },
                "a right-click with a selection offers Translate")
        require(state.canTranslateSelection, "a selection offers the translation action")
        require(state.translationSelectionTitle == "Translate", "an untranslated selection offers Translate")
        require(state.performTranslationAction(), "Translate is accepted")
        try await waitForTranslation(state)
        require(service.startCount == 1, "one block sends exactly one request, not one per sentence")
        guard let overlay = state.translationOverlays.first(where: { $0.isTranslated }) else {
            fatalError("No translated overlay")
        }
        require(abs(overlay.rect.minX - block.rect.minX) < 0.01
                    && abs(overlay.rect.minY - block.rect.minY) < 0.01
                    && abs(overlay.rect.width - block.rect.width) < 0.01
                    && abs(overlay.rect.height - block.rect.height) < 0.01,
                "the cover rectangle is exactly the selected block's rectangle")
        require(overlay.isBlock, "a whole paragraph is translated as a block")
        require(!overlay.translatedText!.isEmpty, "the provider's translation is on screen")
        require(service.preparedSelections.count == 1
                    && service.preparedSelections[0].page == 1
                    && service.preparedSelections[0].start == block.range.lowerBound
                    && service.preparedSelections[0].end == block.range.upperBound,
                "the request's selection is exactly the block's character range")
        let pdfBytesBefore = try Data(contentsOf: paper)

        // Ten flips: five Show original / Translate pairs. No request may be sent.
        for _ in 0..<10 {
            require(state.performTranslationAction(), "the flip action is accepted")
            if let latest = state.translationOverlays.first(where: { $0.id == overlay.id }) {
                require(latest.isTranslated || latest.isOriginal, "the flip is a display change")
            }
        }
        require(service.startCount == 1,
                "ten Show original / Translate toggles send exactly one request in total")
        let pinned = state.translationOverlays
        state.scroll(byScreenPoints: 300)
        state.scroll(byScreenPoints: -300)
        require(state.translationOverlays == pinned,
                "scrolling away and back keeps the translation without a request")
        require(service.startCount == 1, "scrolling never sends a request")
        require((try? Data(contentsOf: paper)) == pdfBytesBefore,
                "the translation writes nothing into the PDF")
        require(service.preparedSelections.count == 1,
                "the toggles do not even prepare another plan")

        // The overlay is in the document edit cache, never beside the PDF.
        let cacheURL = DocumentEditCache.translationsURL(for: paper)
        require(cacheURL.path.hasPrefix(DocumentEditCache.directory(for: paper).path + "/"),
                "translations are stored inside the document edit cache")
        require(!FileManager.default.fileExists(atPath: paper.appendingPathExtension("translations.json").path),
                "no translation file is written beside the PDF")
        require(FileManager.default.fileExists(atPath: cacheURL.path),
                "the translation cache file exists after the first request")

        // Page pixels: a cover is drawn; Show original restores the same bytes exactly.
        try pixelExactRestoreCheck()
        state.selectTranslationRange(page: 0, range: block.range)
        require(state.translationSelectionTitle == "Show original",
                "the same selection now offers Show original")
        state.selectTranslationRange(page: 0, range: (block.range.lowerBound + 1)...block.range.upperBound)
        require(state.translationSelectionAction == .showOriginal,
                "selecting inside a translated block offers Show original")
        let translatedItems = CanvasContextMenu.items(state: state, at: menuPoint)
        require(translatedItems.contains {
            $0.action == .translateSelection && $0.title == "Show original"
        }, "the context menu reflects the translated block")
        state.selectTranslationRange(page: 0, range: block.range)
        require(state.performTranslationAction(), "Show original is accepted")
        require(state.translationOverlays.first(where: { $0.id == overlay.id })?.isOriginal == true,
                "Show original hides the cover")
        require(service.startCount == 1, "Show original sends nothing")
    }

    @MainActor
    private static func pixelExactRestoreCheck() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        host.wantsLayer = true
        let page = TranslationPixelPage(frame: host.bounds)
        page.autoresizingMask = [.width, .height]
        host.addSubview(page)
        let overlay = TranslationOverlayView(frame: host.bounds)
        overlay.autoresizingMask = [.width, .height]
        host.addSubview(overlay)
        let frames = [PagePlacement(index: 0, topPt: 0, leftPt: 0, widthPt: 600, heightPt: 400)]
        overlay.update(overlays: [], frames: frames, zoom: 1, scrollYPt: 0,
                       contentWidthPt: 600, paperAppearance: .original)
        host.layoutSubtreeIfNeeded()
        let beforeRep = bitmapRep(host)
        let before = bitmapBytes(host)
        let block = CGRect(x: 100, y: 80, width: 220, height: 60)
        let cover = TranslationOverlay(
            id: "pixel-check", page: 0, rect: block, sourceText: "source",
            translatedText: nil, phase: .translated, range: nil, isBlock: true,
            sourceFontPt: 10, fit: nil,
            paperColor: TranslationPaperColor(red: 255, green: 0, blue: 0))
        overlay.update(overlays: [cover], frames: frames, zoom: 1, scrollYPt: 0,
                       contentWidthPt: 600, paperAppearance: .original)
        host.layoutSubtreeIfNeeded()
        let coveredRep = bitmapRep(host)
        let covered = bitmapBytes(host)
        guard let before, let covered, let coveredRep, let beforeRep else {
            fatalError("The pixel check could not rasterize its host view")
        }
        require(before != covered, "the translated block changes the page pixels")
        let red = redPixelCount(coveredRep)
        // The cached bitmap is in device pixels, so on a 2× display the block covers 4× its
        // point area. Compare against the bitmap's own scale rather than assuming 1×: the
        // drawing itself is correct at either scale, and this check must not fail on a Retina
        // host.
        let bitmapScaleX = CGFloat(coveredRep.pixelsWide) / host.bounds.width
        let bitmapScaleY = CGFloat(coveredRep.pixelsHigh) / host.bounds.height
        let expected = Int((block.width * bitmapScaleX) * (block.height * bitmapScaleY))
        require(red > expected * 8 / 10 && red < expected * 12 / 10,
                "the cover paints the block and nothing else (\(red) red pixels vs \(expected) bitmap pixels)")
        // Show original removes the cover. The control chip deliberately remains (it is the
        // way back), so the pixel check hides the whole layer for the exact-restore comparison
        // and separately proves that the original-state layer paints no cover.
        overlay.update(overlays: [TranslationOverlay(
            id: "pixel-check", page: 0, rect: block, sourceText: "source",
            translatedText: nil, phase: .original, range: nil, isBlock: true,
            sourceFontPt: 10, fit: nil,
            paperColor: TranslationPaperColor(red: 255, green: 0, blue: 0))],
            frames: frames, zoom: 1, scrollYPt: 0, contentWidthPt: 600,
            paperAppearance: .original)
        host.layoutSubtreeIfNeeded()
        let originalRep = bitmapRep(host)
        require(originalRep != nil && redPixelCount(originalRep!) == 0,
                "Show original paints no cover pixel over the block")
        require(originalRep != nil && regionMatches(beforeRep, originalRep!, in: block),
                "under the cover, Show original restores the block's page pixels exactly")
        overlay.update(overlays: [], frames: frames, zoom: 1, scrollYPt: 0,
                       contentWidthPt: 600, paperAppearance: .original)
        host.layoutSubtreeIfNeeded()
        let restored = bitmapBytes(host)
        require(restored == before,
                "Show original restores every page pixel exactly, with no residual cover")
    }

    @MainActor
    private static func bitmapRep(_ view: NSView) -> NSBitmapImageRep? {
        // Cache at 1× so rectangles given in points address the same pixels on every display.
        // `bitmapImageRepForCachingDisplay` follows the host's backing scale, which made the
        // pixel counts 4× too large on a Retina machine.
        let width = max(1, Int(view.bounds.width.rounded()))
        let height = max(1, Int(view.bounds.height.rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    @MainActor
    private static func bitmapBytes(_ view: NSView) -> Data? {
        guard let rep = bitmapRep(view), let bytes = rep.bitmapData else { return nil }
        return Data(bytes: bytes, count: rep.bytesPerRow * rep.pixelsHigh)
    }

    @MainActor
    private static func redPixelCount(_ rep: NSBitmapImageRep) -> Int {
        var count = 0
        // `colorAt` uses a top-left origin for a view-cached bitmap, which is also the page's
        // coordinate origin; the check does not have to guess at a channel order.
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > 0.8 && color.greenComponent < 0.15
                    && color.blueComponent < 0.15 {
                    count += 1
                }
            }
        }
        return count
    }

    // MARK: - Tabs and relaunch

    @MainActor
    private static func inPlaceTranslationTabAndRelaunchChecks(root: URL) async throws {
        let paper = try translationFixture(root: root, named: "text-page.pdf")
        let second = try translationFixture(root: root, named: "multipage.pdf")
        let (settings, defaults, suite) = translationSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = try RustEngine()
        let service = CountingTranslationService(engine: engine)
        let state = try await makeTranslationState(engine: engine, settings: settings,
                                                   service: service, url: paper)
        guard let textPage = await state.translationTextPage(0) else {
            fatalError("translation fixture has no text layer")
        }
        let block = blockContaining("Line 1", textPage: textPage)
        state.selectTranslationRange(page: 0, range: block.range)
        _ = state.performTranslationAction()
        try await waitForTranslation(state)
        require(service.startCount == 1, "the tab fixture sends one request")
        guard let translated = state.translationOverlays.first else {
            fatalError("No translation before the tab switch")
        }
        require(state.openDocumentInTab(second), "a second tab opens")
        try await eventually("the second tab is active") {
            state.document?.url == second
        }
        state.selectTab(0)
        try await eventually("the first tab is active again") {
            state.document?.url == paper && !state.canvasPageFrames.isEmpty
        }
        try await waitForTranslation(state)
        require(state.translationOverlays.contains(where: { $0.id == translated.id && $0.isTranslated }),
                "switching away and back keeps the translation")
        require(service.startCount == 1, "switching tabs sends nothing")

        // The restored tab must still write to the *first* document's cache, not the tab that
        // was on screen a moment ago. Translating another block proves which file was updated.
        let tabBlocks = TranslationBlockDetector.blocks(page: 0, textPage: textPage)
        guard let other = tabBlocks.first(where: { $0.range != block.range }) else {
            fatalError("The tab fixture has no second block")
        }
        state.selectTranslationRange(page: 0, range: other.range)
        _ = state.performTranslationAction()
        try await waitForTranslation(state, count: 2)
        require(service.startCount == 2, "the explicit post-switch translation is one request")
        if let cache = try? Data(contentsOf: DocumentEditCache.translationsURL(for: paper)),
           let text = String(data: cache, encoding: .utf8) {
            require(text.contains(other.sourceText),
                    "after a tab switch, new translations still land in this document's cache")
        } else {
            fatalError("The first tab's translation cache was not written after the switch")
        }

        // Relaunch: a fresh state, fresh service, same document and cache.
        let relaunchEngine = try RustEngine()
        let relaunchService = CountingTranslationService(engine: relaunchEngine)
        let relaunched = try await makeTranslationState(
            engine: relaunchEngine, settings: settings, service: relaunchService, url: paper)
        try await eventually("the relaunched reader restores the cached translation") {
            relaunched.translationOverlays.contains { $0.isTranslated && $0.id == translated.id }
        }
        require(relaunchService.startCount == 0,
                "a relaunch reuses the cached translation and sends nothing")
        require(relaunchService.preparedSelections.isEmpty,
                "a relaunch does not even prepare a request for a cached block")
        guard let relaunchedText = await relaunched.translationTextPage(0) else {
            fatalError("relaunched fixture has no text layer")
        }
        let relaunchedBlock = blockContaining("Line 1", textPage: relaunchedText)
        relaunched.selectTranslationRange(page: 0, range: relaunchedBlock.range)
        require(relaunched.translationSelectionTitle == "Show original",
                "the restored block offers Show original")
    }

    // MARK: - Model/language and localized invalidation

    @MainActor
    private static func inPlaceTranslationKeyAndEditChecks(root: URL) async throws {
        let paper = try translationFixture(root: root, named: "text-page.pdf")
        let (settings, defaults, suite) = translationSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = try RustEngine()
        let service = CountingTranslationService(engine: engine)
        let state = try await makeTranslationState(engine: engine, settings: settings,
                                                   service: service, url: paper)
        guard let textPage = await state.translationTextPage(0) else {
            fatalError("translation fixture has no text layer")
        }
        let block = blockContaining("Line 1", textPage: textPage)
        state.selectTranslationRange(page: 0, range: block.range)
        _ = state.performTranslationAction()
        try await waitForTranslation(state)
        require(service.startCount == 1, "the key fixture sends one request")
        guard let first = state.translationOverlays.first(where: { $0.isTranslated }) else {
            fatalError("No first translation")
        }
        let firstKey = first.id

        // Change the model, flip to the original, then Translate: exactly one new request.
        require(settings.save(baseURL: "http://127.0.0.1:1/v1", model: "mock-model-b",
                              temperature: 0.2, maxTokens: 900, apiKey: nil),
                "the model change is accepted")
        state.toggleTranslation(id: firstKey)
        state.selectTranslationRange(page: 0, range: block.range)
        require(state.translationSelectionTitle == "Translate",
                "with a different model the old entry no longer answers Translate")
        _ = state.performTranslationAction()
        try await eventually("the new model's translation arrives") {
            state.translationOverlays.contains { $0.isTranslated && $0.id != firstKey }
        }
        require(service.startCount == 2, "changing the model sends exactly one new request")
        require(state.inPlaceTranslation.snapshot().entries[firstKey] != nil,
                "the old entry is kept for the old model")
        guard let second = state.translationOverlays.first(where: { $0.isTranslated && $0.id != firstKey })
        else { fatalError("No second translation") }

        // Change the target language, flip, request: one new request. The old entry stays.
        state.inPlaceTranslationTargetLanguage = "French"
        state.toggleTranslation(id: second.id)
        state.selectTranslationRange(page: 0, range: block.range)
        _ = state.performTranslationAction()
        try await eventually("the French translation arrives") {
            state.translationOverlays.contains { $0.isTranslated && $0.id != firstKey && $0.id != second.id }
        }
        require(service.startCount == 3, "changing the language sends exactly one new request")
        guard let french = state.translationOverlays.first(where: {
            $0.isTranslated && $0.id != firstKey && $0.id != second.id
        }) else { fatalError("No French translation") }

        // Back to the original language/model: the old entry is still valid, so no request.
        state.inPlaceTranslationTargetLanguage = "English"
        require(settings.save(baseURL: "http://127.0.0.1:1/v1", model: "mock-model-a",
                              temperature: 0.2, maxTokens: 900, apiKey: nil),
                "the original model is restored")
        state.toggleTranslation(id: french.id)
        state.selectTranslationRange(page: 0, range: block.range)
        _ = state.performTranslationAction()
        try await eventually("the old entry is displayed again") {
            state.translationOverlays.contains { $0.id == firstKey && $0.isTranslated }
        }
        require(service.startCount == 3,
                "the old model/language still reuses its cached entry with no request")

        // Edit the block's text: only that block's entry is removed. The reader's content edit
        // is the real PDF path (text-page.pdf has an editable run), not a cache poke.
        state.toggleContentEditing()
        await state.reloadContentObjects()
        guard let item = state.contentEditPage?.items.first(where: { $0.can_edit_text }) else {
            fatalError("the translation fixture has no editable text run: \(state.lastError ?? "")")
        }
        // Translate two blocks first: the edited one and a different one on the same page.
        let blocks = TranslationBlockDetector.blocks(page: 0, textPage: textPage)
        guard let editedBlock = blocks.first(where: {
            $0.rect.intersects(CGRect(x: item.bounds.x, y: item.bounds.y,
                                      width: item.bounds.width, height: item.bounds.height))
        }), let otherBlock = blocks.first(where: { $0.range != editedBlock.range }) else {
            fatalError("The fixture does not have two translation blocks")
        }
        state.selectTranslationRange(page: 0, range: editedBlock.range)
        _ = state.performTranslationAction()
        try await eventually("the edited block's first translation arrives") {
            state.translationOverlays.contains { $0.isTranslated && $0.range == editedBlock.range }
        }
        state.selectTranslationRange(page: 0, range: otherBlock.range)
        _ = state.performTranslationAction()
        try await eventually("the other block's translation arrives") {
            state.translationOverlays.contains { $0.isTranslated && $0.range == otherBlock.range }
        }
        let beforeEditCount = state.translationOverlays.filter { $0.isTranslated }.count
        state.replaceContentText(item, text: "Edited")
        try await eventuallyExplaining("the content edit completes", {
            "lastError=\(state.lastError ?? "nil") recovery=\(state.contentTextRecovery ?? "nil") "
                + "inFlight=\(state.contentCommandInFlight) busy=\(state.pageEditBusy) "
                + "ops=\(state.pageEditPendingOperations) canEdit=\(state.contentEditPage?.items.filter { $0.can_edit_text }.count ?? -1)"
        }) {
            state.pageEditPendingOperations.count >= 1 && !state.contentCommandInFlight
                && !state.pageEditBusy
        }
        try await eventually("the edited block's translation is invalidated") {
            !state.translationOverlays.contains { $0.range == editedBlock.range && $0.isTranslated }
        }
        require(state.translationOverlays.contains {
            $0.range == otherBlock.range && $0.isTranslated
        }, "editing one block leaves the other block's translation in place")
        require(state.translationOverlays.filter { $0.isTranslated }.count < beforeEditCount,
                "the edited block's entry alone was removed")
        require(state.translationNotice?.contains("removed") == true,
                "the reader is told why the edited block's overlay disappeared")

        // The next Translate sends again for the edited block.
        let beforeRetranslate = service.startCount
        state.selectTranslationRange(page: 0, range: editedBlock.range)
        _ = state.performTranslationAction()
        try await eventually("the edited block translates again") {
            service.startCount == beforeRetranslate + 1
                && state.translationOverlays.contains {
                    $0.isTranslated && $0.range?.overlaps(editedBlock.range) == true
                }
        }
        guard let retranslated = state.translationOverlays.first(where: {
            $0.isTranslated && $0.range?.overlaps(editedBlock.range) == true
        }) else { fatalError("No re-translated overlay") }
        if let cache = try? Data(contentsOf: DocumentEditCache.translationsURL(for: paper)),
           let text = String(data: cache, encoding: .utf8) {
            require(text.contains(retranslated.sourceText),
                    "the re-translated edited block is cached under the original document")
        }
    }

    // MARK: - Batching, cancel and page edits

    @MainActor
    private static func inPlaceTranslationBatchCancelAndPageEditChecks(root: URL) async throws {
        let paper = try translationFixture(root: root, named: "text-page.pdf")
        let (settings, defaults, suite) = translationSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = try RustEngine()
        let service = CountingTranslationService(engine: engine)
        let state = try await makeTranslationState(engine: engine, settings: settings,
                                                   service: service, url: paper)
        guard let textPage = await state.translationTextPage(0) else {
            fatalError("translation fixture has no text layer")
        }
        let blocks = TranslationBlockDetector.blocks(page: 0, textPage: textPage)
        require(blocks.count >= 2, "the batch check needs at least two paragraph blocks")
        let chosen = Array(blocks.prefix(2))
        let range = chosen[0].range.lowerBound...chosen[1].range.upperBound
        state.selectTranslationRange(page: 0, range: range)
        _ = state.performTranslationAction()
        try await waitForTranslation(state, count: 2)
        require(service.startCount == 2,
                "two paragraph blocks are a bounded batch of two independent requests")
        require(service.preparedSelections.count == 2,
                "each block's request carries only that block's selection")

        // Cancel on a fresh document: a request in flight is cancelled before its first
        // completed answer, leaving the page untouched and the block untranslated.
        let cancelPaper = try translationFixture(root: root, named: "text-page.pdf")
        let cancelState = try await makeTranslationState(
            engine: engine, settings: settings, service: service, url: cancelPaper)
        guard let cancelText = await cancelState.translationTextPage(0) else {
            fatalError("cancel fixture has no text layer")
        }
        let cancelBlock = blockContaining("Line 1", textPage: cancelText)
        cancelState.selectTranslationRange(page: 0, range: cancelBlock.range)
        _ = cancelState.performTranslationAction()
        try await eventually("a translating overlay appears") {
            cancelState.translationOverlays.contains { $0.isTranslating }
        }
        guard let translating = cancelState.translationOverlays.first(where: { $0.isTranslating })
        else { fatalError("No translating overlay") }
        cancelState.cancelTranslation(id: translating.id)
        try await eventually("cancel clears the translating overlay") {
            !cancelState.translationOverlays.contains { $0.id == translating.id }
        }
        require(!cancelState.translationOverlays.contains { $0.isTranslating },
                "cancel leaves no translating chip or half-covered block")
        require(!cancelState.translationOverlays.contains(where: { $0.isTranslated }),
                "cancel leaves the block untranslated, not half-covered")
        require(cancelState.translationNotice?.lowercased().contains("cancel") == true,
                "the reader is told the block was left untranslated")
        let cacheAfterCancel = DocumentEditCache.translationsURL(for: cancelPaper)
        if let data = try? Data(contentsOf: cacheAfterCancel),
           let text = String(data: data, encoding: .utf8) {
            require(!text.contains(cancelBlock.sourceText),
                    "a cancelled request caches no translation for the block")
        }

        // Rotation removes overlays and explains; no translation state survives.
        let rotationPaper = try translationFixture(root: root, named: "text-page.pdf")
        let rotationState = try await makeTranslationState(
            engine: engine, settings: settings, service: service, url: rotationPaper)
        guard let rotationText = await rotationState.translationTextPage(0) else {
            fatalError("rotation fixture has no text layer")
        }
        let rotationBlock = blockContaining("Line 1", textPage: rotationText)
        rotationState.selectTranslationRange(page: 0, range: rotationBlock.range)
        _ = rotationState.performTranslationAction()
        try await waitForTranslation(rotationState)
        let rotated = await rotationState.applyPageEditOperation(
            .rotate(pages: [0], quarterTurns: 1), label: "Rotate page 1")
        require(rotated, "the page rotation is staged")
        try await eventually("rotation removes the overlay") {
            rotationState.translationOverlays.isEmpty
        }
        require(rotationState.translationNotice?.contains("removed") == true
                    && rotationState.translationNotice?.contains("PDF") == true,
                "rotation explains that the overlay was removed and the PDF was not modified")

        // Deletion of the page that carries the translation: same contract, on a fixture with
        // more than one page so the document remains valid.
        let multipage = try translationFixture(root: root, named: "multipage.pdf")
        let deleteState = try await makeTranslationState(
            engine: engine, settings: settings, service: service, url: multipage)
        guard let deleteText = await deleteState.translationTextPage(0) else {
            fatalError("delete fixture has no text layer")
        }
        let deleteBlock = blockContaining("Body text", textPage: deleteText)
        deleteState.selectTranslationRange(page: 0, range: deleteBlock.range)
        _ = deleteState.performTranslationAction()
        try await waitForTranslation(deleteState)
        deleteState.selectPage(0, extending: false, toggling: false)
        let deleted = await deleteState.applyPageEditOperation(
            .delete(pages: [0]), label: "Delete page 1")
        require(deleted, "the page deletion is staged")
        try await eventually("the deleted page's overlay is gone") {
            deleteState.translationOverlays.isEmpty
        }
        require(deleteState.translationNotice?.contains("removed") == true,
                "deletion explains why the overlay disappeared")
        if let cache = try? Data(contentsOf: DocumentEditCache.translationsURL(for: multipage)),
           let text = String(data: cache, encoding: .utf8) {
            require(!text.contains(deleteBlock.sourceText),
                    "the deleted page's cached translation is pruned, not left behind")
        }
    }

    // MARK: - Audit trail

    /// Every outgoing block translation is one audited start; cache hits and flips add nothing.
    @MainActor
    private static func inPlaceTranslationAuditChecks(root: URL) async throws {
        let paper = try translationFixture(root: root, named: "text-page.pdf")
        let (settings, defaults, suite) = translationSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = try RustEngine()
        let service = CountingTranslationService(engine: engine)
        let state = try await makeTranslationState(engine: engine, settings: settings,
                                                   service: service, url: paper)
        let auditDirectory = paper.deletingLastPathComponent()
            .appendingPathComponent("translation-audit-\(UUID().uuidString)", isDirectory: true)
        let audit = AIAuditTrail(directory: auditDirectory)
        state.inPlaceTranslationAuditOverride = audit
        guard let textPage = await state.translationTextPage(0) else {
            fatalError("the audit fixture has no text layer")
        }
        let blocks = TranslationBlockDetector.blocks(page: 0, textPage: textPage)
        require(blocks.count >= 2, "the audit fixture needs two blocks")
        let first = blocks[0], second = blocks[1]

        state.selectTranslationRange(page: 0, range: first.range)
        _ = state.performTranslationAction()
        try await waitForTranslation(state)
        require(service.startCount == 1, "the audit fixture sends one block request")
        require(audit.records.count == 1,
                "one translation request produces exactly one audit record")
        if let record = audit.records.first {
            require(record.action == .translation, "the record names the translation action")
            require(record.outcome == .sent, "the record says the request was sent")
            require(record.pages == [1], "the record carries the page without document text")
            require(record.characters > 0, "the record counts the characters sent")
            require(record.image == nil, "a translation carries no image")
        }

        // Flip ten times: these are cache reads, not requests, so the audit count is unchanged.
        for _ in 0..<10 {
            _ = state.performTranslationAction()
        }
        require(audit.records.count == 1,
                "Show original / Translate cache flips add no audit record")
        require(service.startCount == 1, "the flips sent no request")

        state.selectTranslationRange(page: 0, range: second.range)
        _ = state.performTranslationAction()
        try await waitForTranslation(state, count: 2)
        require(service.startCount == 2, "a second block is a second request")
        require(audit.records.count == 2,
                "the second outgoing block has its own audit record")
        require(audit.records.allSatisfy { $0.action == .translation && $0.outcome == .sent },
                "both audit records describe sent translations")

        // A relaunch with the same cache and audit trail reuses the translations silently.
        let relaunchService = CountingTranslationService(engine: try RustEngine())
        let relaunch = try await makeTranslationState(
            engine: try RustEngine(), settings: settings, service: relaunchService, url: paper)
        relaunch.inPlaceTranslationAuditOverride = audit
        try await eventually("the relaunch restores the cached translations") {
            relaunch.translationOverlays.filter { $0.isTranslated }.count >= 2
        }
        require(relaunchService.startCount == 0, "the relaunch sends no request")
        require(audit.records.count == 2, "reusing the cache adds no audit record")
    }

    // MARK: - Torn pages

    @MainActor
    private static func tearOverlay(_ id: String, _ rect: CGRect,
                                    phase: TranslationOverlayPhase = .translated,
                                    text: String) -> TranslationOverlay {
        TranslationOverlay(
            id: id, page: 0, rect: rect, sourceText: "source " + id,
            translatedText: phase == .original ? nil : text, phase: phase,
            range: nil, isBlock: true, sourceFontPt: 10,
            fit: TranslationTextLayout.fit(text: text, in: rect, sourceFontPt: 10),
            paperColor: TranslationPaperColor(red: 255, green: 0, blue: 0))
    }

    /// The piecewise mapping on a synthetic torn page: a block above, below and across the tear;
    /// chip reachability; and Show original leaving the page and the gap byte-identical.
    @MainActor
    private static func inPlaceTranslationTearGeometryChecks() throws {
        let host = TranslationTornPage(frame: NSRect(x: 0, y: 0, width: 500, height: 900))
        let overlay = TranslationOverlayView(frame: host.bounds)
        host.addSubview(overlay)
        let top = PagePlacement(index: 0, topPt: 0, leftPt: 0, widthPt: 400, heightPt: 300,
                                sourceTopPt: 0, sourceHeightPt: 300)
        let bottom = PagePlacement(index: 0, topPt: 500, leftPt: 0, widthPt: 400, heightPt: 400,
                                   sourceTopPt: 300, sourceHeightPt: 400)
        let tornFrames = [top, bottom]
        let aboveRect = CGRect(x: 20, y: 40, width: 160, height: 40)
        let straddleRect = CGRect(x: 20, y: 250, width: 180, height: 100)
        let belowRect = CGRect(x: 20, y: 430, width: 160, height: 40)
        let overlays = [
            tearOverlay("above", aboveRect, text: "Above the tear translation"),
            tearOverlay("straddle", straddleRect, text: "A translation that crosses the tear"),
            tearOverlay("below", belowRect, text: "Below the tear translation"),
        ]
        overlay.update(overlays: overlays, frames: tornFrames, zoom: 1, scrollYPt: 0,
                       contentWidthPt: 400, paperAppearance: .original)
        host.layoutSubtreeIfNeeded()
        require(overlay.blockRectsForCheck("above").count == 1,
                "a block above the tear maps to one piece")
        require(overlay.blockRectsForCheck("below").count == 1,
                "a block below the tear maps to one piece below the gap")
        let straddlePieces = overlay.blockRectsForCheck("straddle")
        require(straddlePieces.count == 2,
                "a block crossing the tear maps to two pieces, not one rectangle over the card")
        guard let gap = overlay.gapFrameForCheck(page: 0),
              let above = overlay.blockRectsForCheck("above").first,
              let below = overlay.blockRectsForCheck("below").first else {
            fatalError("The torn mapping did not produce its pieces")
        }
        require(above.maxY <= gap.minY + 0.5, "the above block stays in the top paper piece")
        require(below.minY >= gap.maxY - 0.5, "the below block is shifted below the gap")
        require(straddlePieces[0].maxY <= gap.minY + 0.5
                    && straddlePieces[1].minY >= gap.maxY - 0.5,
                "the straddling pieces are separated by the exact tear gap")
        require(overlay.visibleChipCount == 3, "each torn/page block keeps one chip")

        for id in ["above", "straddle", "below"] {
            guard let chip = overlay.chipFrameForCheck(id) else {
                fatalError("The \(id) block lost its chip on a torn page")
            }
            require(host.bounds.contains(chip), "the \(id) chip stays reachable inside the canvas")
            for piece in overlay.blockRectsForCheck(id) {
                require(!chip.intersects(piece),
                        "the \(id) chip does not cover its own translated text")
            }
            require(!chip.intersects(gap), "the \(id) chip does not sit in the card's gap")
        }

        // Show original restores the torn page, gap included.
        overlay.update(overlays: [], frames: tornFrames, zoom: 1, scrollYPt: 0,
                       contentWidthPt: 400, paperAppearance: .original)
        host.layoutSubtreeIfNeeded()
        let beforeRep = bitmapRep(host)
        let before = bitmapBytes(host)
        overlay.update(overlays: overlays, frames: tornFrames, zoom: 1, scrollYPt: 0,
                       contentWidthPt: 400, paperAppearance: .original)
        host.layoutSubtreeIfNeeded()
        let coveredRep = bitmapRep(host)
        guard let before, let coveredRep, let beforeRep else {
            fatalError("The torn pixel check could not rasterize its host")
        }
        require(redPixelCount(coveredRep) > 0, "the torn translation paints a cover")
        let original = overlays.map {
            tearOverlay($0.id, $0.rect, phase: .original, text: "unused")
        }
        overlay.update(overlays: original, frames: tornFrames, zoom: 1, scrollYPt: 0,
                       contentWidthPt: 400, paperAppearance: .original)
        host.layoutSubtreeIfNeeded()
        let originalRep = bitmapRep(host)
        require(originalRep != nil && redPixelCount(originalRep!) == 0,
                "Show original paints no cover into either paper piece")
        overlay.update(overlays: [], frames: tornFrames, zoom: 1, scrollYPt: 0,
                       contentWidthPt: 400, paperAppearance: .original)
        host.layoutSubtreeIfNeeded()
        let restored = bitmapBytes(host)
        require(restored == before,
                "Show original restores the torn page exactly, including the gap")
        if let restoredRep = bitmapRep(host) {
            require(regionMatches(beforeRep, restoredRep, in: gap),
                    "the card's gap is unchanged by the overlay")
        }

        // Toggling the tear itself keeps the same overlays and re-maps every block.
        let untorn = PagePlacement(index: 0, topPt: 0, leftPt: 0, widthPt: 400, heightPt: 700,
                                   sourceTopPt: 0, sourceHeightPt: 700)
        overlay.update(overlays: overlays, frames: [untorn], zoom: 1, scrollYPt: 0,
                       contentWidthPt: 400, paperAppearance: .original)
        require(overlay.gapFrameForCheck(page: 0) == nil, "an untorn page has no tear gap")
        for id in ["above", "straddle", "below"] {
            require(overlay.blockRectsForCheck(id).count == 1,
                    "an untorn \(id) block maps to one rectangle")
        }
        overlay.update(overlays: overlays, frames: tornFrames, zoom: 1, scrollYPt: 0,
                       contentWidthPt: 400, paperAppearance: .original)
        require(overlay.blockRectsForCheck("straddle").count == 2,
                "re-tearing the page re-maps the same overlay without touching it")
    }

    /// The real region-card tear: a translated block above and a block crossing the split,
    /// opening and closing the card while the translation is shown, with zero requests.
    @MainActor
    private static func inPlaceTranslationRegionTearChecks(root: URL) async throws {
        let paper = try translationFixture(root: root, named: "text-page.pdf")
        let (settings, defaults, suite) = translationSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = try RustEngine()
        let service = CountingTranslationService(engine: engine)
        let state = try await makeTranslationState(engine: engine, settings: settings,
                                                   service: service, url: paper)
        guard let textPage = await state.translationTextPage(0) else {
            fatalError("the tear fixture has no text layer")
        }
        let blocks = TranslationBlockDetector.blocks(page: 0, textPage: textPage)
        guard let straddleBlock = blocks.first(where: { $0.lineRects.count >= 2 }),
              let aboveBlock = blocks.last(where: { $0.rect.maxY < straddleBlock.rect.minY - 1 })
        else { fatalError("the tear fixture needs an above block and a multi-line block") }
        let firstLine = straddleBlock.lineRects[0]
        let secondLine = straddleBlock.lineRects[1]
        let gapY = (firstLine.maxY + secondLine.minY) / 2
        let tearSelection = CGRect(
            x: firstLine.minX + 2, y: firstLine.minY + 1,
            width: min(160, max(8, ((straddleBlock.rect.maxX - firstLine.minX) - 4))),
            height: max(6, gapY - firstLine.minY - 2)
        )

        state.selectTranslationRange(page: 0, range: aboveBlock.range)
        _ = state.performTranslationAction()
        try await eventually("the above block translates") {
            state.translationOverlays.contains { $0.isTranslated && $0.range == aboveBlock.range }
        }
        state.selectTranslationRange(page: 0, range: straddleBlock.range)
        _ = state.performTranslationAction()
        try await eventually("the straddling block translates") {
            state.translationOverlays.contains { $0.isTranslated && $0.range == straddleBlock.range }
        }
        require(service.startCount == 2, "the tear fixture starts with two block requests")
        let aboveID = state.translationOverlays.first {
            $0.isTranslated && $0.range == aboveBlock.range
        }!.id
        let straddleID = state.translationOverlays.first {
            $0.isTranslated && $0.range == straddleBlock.range
        }!.id
        let beforeTear = state.inPlaceTranslation.snapshot()

        await state.createRegionCard(page: 0, rect: tearSelection)
        guard let card = state.regionCards.first else {
            fatalError("the region card did not open: \(state.lastError ?? "no error")")
        }
        try await eventually("the region card tears page 1") {
            state.pageTear(forPage: 0) != nil
                && state.canvasPageSegments.filter { $0.index == 0 }.count == 2
        }
        let split = state.pageTear(forPage: 0)!.splitPt
        require(split > straddleBlock.rect.minY + 1 && split < straddleBlock.rect.maxY - 1,
                "the card's tear crosses the selected block (split \(split), block \(straddleBlock.rect))")
        require(aboveBlock.rect.maxY <= split, "the other block is entirely above the tear")
        require(service.startCount == 2, "opening the region card sends no request")
        let afterOpen = state.inPlaceTranslation.snapshot()
        require(afterOpen.entries.count == beforeTear.entries.count
                    && Set(afterOpen.entries.keys) == Set(beforeTear.entries.keys),
                "the tear does not change any cache key or create a second entry")

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 900))
        let overlayView = TranslationOverlayView(frame: host.bounds)
        host.addSubview(overlayView)
        overlayView.update(overlays: state.translationOverlays,
                           frames: state.canvasPageSegments,
                           zoom: state.zoomFactor, scrollYPt: 0,
                           contentWidthPt: state.contentWidthPt,
                           paperAppearance: .original,
                           paperColors: state.translationPaperColors)
        require(overlayView.blockRectsForCheck(aboveID).count == 1,
                "the above translation maps to one piece after the tear")
        require(overlayView.blockRectsForCheck(straddleID).count == 2,
                "the straddling translation maps to both pieces after the tear")
        guard let gap = overlayView.gapFrameForCheck(page: 0) else {
            fatalError("the torn page has no gap rectangle")
        }
        let straddlePieces = overlayView.blockRectsForCheck(straddleID)
        require(straddlePieces[0].maxY <= gap.minY + 0.5
                    && straddlePieces[1].minY >= gap.maxY - 0.5,
                "the straddling translation is clipped at the tear, not drawn through the card")
        require(overlayView.visibleChipCount >= 1, "the torn translation keeps a reachable chip")
        for id in [aboveID, straddleID] {
            guard let chip = overlayView.chipFrameForCheck(id) else {
                fatalError("the torn translation lost a chip")
            }
            require(host.bounds.contains(chip), "the torn chip stays inside the canvas")
            require(!chip.intersects(gap), "the torn chip is not placed in the card's gap")
            for piece in overlayView.blockRectsForCheck(id) {
                require(!chip.intersects(piece), "the torn chip does not cover its translation")
            }
        }

        // Show original / Translate on the torn page, still with zero requests.
        state.selectTranslationRange(page: 0, range: straddleBlock.range)
        _ = state.performTranslationAction()
        try await eventually("Show original works on the torn page") {
            state.translationOverlays.first { $0.id == straddleID }?.isOriginal == true
        }
        require(service.startCount == 2, "Show original on a torn page sends nothing")
        _ = state.performTranslationAction()
        try await eventually("Translate restores the torn cover") {
            state.translationOverlays.first { $0.id == straddleID }?.isTranslated == true
        }
        require(service.startCount == 2, "flipping a torn translation sends nothing")

        // Closing the card restores the untorn layout and the same translation entries.
        state.closeRegionCard(id: card.id, keepHistory: false)
        try await eventually("closing the card removes the tear") {
            state.pageTear(forPage: 0) == nil
                && state.canvasPageSegments.filter { $0.index == 0 }.count == 1
        }
        overlayView.update(overlays: state.translationOverlays,
                           frames: state.canvasPageSegments,
                           zoom: state.zoomFactor, scrollYPt: 0,
                           contentWidthPt: state.contentWidthPt,
                           paperAppearance: .original,
                           paperColors: state.translationPaperColors)
        require(overlayView.gapFrameForCheck(page: 0) == nil, "the untorn layout has no gap")
        require(overlayView.blockRectsForCheck(straddleID).count == 1,
                "the same translation is one rectangle again after the tear closes")
        let afterClose = state.inPlaceTranslation.snapshot()
        require(afterClose.entries.count == beforeTear.entries.count
                    && Set(afterClose.entries.keys) == Set(beforeTear.entries.keys),
                "closing the tear leaves the cached translation under the same key")
        require(service.startCount == 2, "closing the region card sends no request")
        if let cached = try? TranslationCacheStore.load(
            from: DocumentEditCache.translationsURL(for: paper)) {
            require(cached.count == beforeTear.entries.count
                        && Set(cached.keys) == Set(beforeTear.entries.keys),
                    "the tear and its removal never altered the cached entries")
        } else {
            fatalError("The translation cache could not be read after closing the tear")
        }
    }

    // MARK: - Layout and chip geometry

    @MainActor
    private static func inPlaceTranslationLayoutAndChipChecks() throws {
        let tiny = TranslationTextLayout.fit(
            text: String(repeating: "A translation that cannot possibly fit. ", count: 20),
            in: CGRect(x: 0, y: 0, width: 40, height: 18),
            sourceFontPt: 11)
        require(tiny.fontSizePt == TranslationTextLayout.minimumFontSizePt,
                "the fit shrinks to the stated 7 pt minimum")
        require(tiny.clipped, "text that still does not fit is clipped at the minimum size")
        let roomy = TranslationTextLayout.fit(
            text: "A short translation.", in: CGRect(x: 0, y: 0, width: 300, height: 120),
            sourceFontPt: 11)
        require(!roomy.clipped, "a translation that fits at the source size is not clipped")
        require(roomy.fontSizePt <= 11, "the fit never grows past the source font size")

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let overlay = TranslationOverlayView(frame: host.bounds)
        host.addSubview(overlay)
        let rect = CGRect(x: 100, y: 100, width: 120, height: 40)
        let translated = TranslationOverlay(
            id: "chip-check", page: 0, rect: rect, sourceText: "source",
            translatedText: "Translated text", phase: .translated, range: nil,
            isBlock: true, sourceFontPt: 10,
            fit: TranslationTextLayout.fit(text: "Translated text", in: rect, sourceFontPt: 10),
            paperColor: .lightPaper)
        let onScreen = [PagePlacement(index: 0, topPt: 0, leftPt: 0, widthPt: 500, heightPt: 400)]
        overlay.update(overlays: [translated], frames: onScreen, zoom: 1, scrollYPt: 0,
                       contentWidthPt: 500, paperAppearance: .original)
        require(overlay.visibleChipCount == 1, "a visible block has one control chip")
        if let chip = overlay.chipFrameForCheck("chip-check"),
           let block = overlay.blockFrameForCheck("chip-check") {
            require(!chip.intersects(block), "the chip does not cover the text it belongs to")
            require(host.bounds.contains(chip), "the chip is reachable inside the canvas")
        } else {
            fatalError("The visible block has no chip frame")
        }

        // The fitted text itself is drawn inside the cover, not just a coloured rectangle.
        let textHost = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        textHost.wantsLayer = true
        let textPage = TranslationPixelPage(frame: textHost.bounds)
        textHost.addSubview(textPage)
        let textOverlay = TranslationOverlayView(frame: textHost.bounds)
        textHost.addSubview(textOverlay)
        let textRect = CGRect(x: 80, y: 80, width: 240, height: 80)
        let textCover = TranslationOverlay(
            id: "text-check", page: 0, rect: textRect, sourceText: "source",
            translatedText: "A short translated sentence that must be visible.",
            phase: .translated, range: nil, isBlock: true, sourceFontPt: 11,
            fit: TranslationTextLayout.fit(
                text: "A short translated sentence that must be visible.",
                in: textRect, sourceFontPt: 11),
            paperColor: .lightPaper)
        textOverlay.update(overlays: [textCover], frames: onScreen, zoom: 1, scrollYPt: 0,
                           contentWidthPt: 500, paperAppearance: .original)
        textHost.layoutSubtreeIfNeeded()
        if let rep = bitmapRep(textHost) {
            require(darkPixelCount(rep, in: textRect) > 20,
                    "the translated words are drawn inside the block, not only a cover")
        } else {
            fatalError("The text render check could not rasterize its host view")
        }

        // Off screen: the block has no chip at all.
        let offScreen = [PagePlacement(index: 0, topPt: 1200, leftPt: 0, widthPt: 500, heightPt: 400)]
        overlay.update(overlays: [translated], frames: offScreen, zoom: 1, scrollYPt: 0,
                       contentWidthPt: 500, paperAppearance: .original)
        require(overlay.visibleChipCount == 0, "a block off screen has no chip")

        // Deep zoom: the block fills the viewport. The chip stays inside the canvas and the
        // overlay reserves its strip out of the text (the chip is still reachable).
        overlay.update(overlays: [translated], frames: onScreen, zoom: 4, scrollYPt: 0,
                       contentWidthPt: 500, paperAppearance: .original)
        if let chip = overlay.chipFrameForCheck("chip-check") {
            require(host.bounds.contains(chip), "the chip remains reachable at 400% zoom")
        } else {
            fatalError("The deeply zoomed block lost its chip")
        }
        overlay.update(overlays: [], frames: onScreen, zoom: 1, scrollYPt: 0,
                       contentWidthPt: 500, paperAppearance: .original)
        require(overlay.visibleChipCount == 0, "clearing the overlays removes every chip")
    }

    @MainActor
    private static func regionMatches(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep,
                                      in rect: CGRect) -> Bool {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return false }
        let x0 = max(0, Int(rect.minX))
        let x1 = min(a.pixelsWide, Int(rect.maxX))
        let y0 = max(0, Int(rect.minY))
        let y1 = min(a.pixelsHigh, Int(rect.maxY))
        for y in y0..<y1 {
            for x in x0..<x1 {
                guard let left = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let right = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    return false
                }
                if abs(left.redComponent - right.redComponent) > 0.0001
                    || abs(left.greenComponent - right.greenComponent) > 0.0001
                    || abs(left.blueComponent - right.blueComponent) > 0.0001
                    || abs(left.alphaComponent - right.alphaComponent) > 0.0001 {
                    return false
                }
            }
        }
        return true
    }

    @MainActor
    private static func darkPixelCount(_ rep: NSBitmapImageRep, in rect: CGRect) -> Int {
        var count = 0
        let x0 = max(0, Int(rect.minX))
        let x1 = min(rep.pixelsWide, Int(rect.maxX))
        let y0 = max(0, Int(rect.minY))
        let y1 = min(rep.pixelsHigh, Int(rect.maxY))
        for y in y0..<y1 {
            for x in x0..<x1 {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent < 0.35 && color.greenComponent < 0.35
                    && color.blueComponent < 0.35 {
                    count += 1
                }
            }
        }
        return count
    }
}
