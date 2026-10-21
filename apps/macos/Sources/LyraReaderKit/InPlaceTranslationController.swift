import LyraReaderBindings
import Foundation

/// What the in-place translator needs from the reader window.
///
/// Kept as a protocol so the checks can drive a real `AppState` while the request state machine
/// stays in one file. Everything here is already true of `AppState`; the controller never reaches
/// into the canvas or the SwiftUI tree.
@MainActor
protocol InPlaceTranslationHost: AnyObject {
    /// The document whose cache directory owns translations. This is the original PDF even while
    /// a page-edit revision is on screen, so a staged edit never creates a second cache.
    var translationDocumentURL: URL? { get }
    var translationDocumentTitle: String { get }
    var translationPageCount: Int { get }
    var translationCurrentPage: Int { get }
    var translationLanguage: String { get }
    var translationService: (any AIChatServicing)? { get }
    var translationSettings: AISettingsStore? { get }
    var translationAudit: AIAuditTrail { get }
    var translationPaperAppearance: PaperAppearance { get }
    func translationTextPage(_ page: Int) async -> TextPage?
    func translationPaperColor(page: Int) -> TranslationPaperColor?
    func translationDidChangeOverlays(_ overlays: [TranslationOverlay])
    func translationDidChangeNotice(_ notice: String?)
}

/// Everything a completed or failed translation needs to survive a tab switch or a page edit.
/// Requests in flight do not survive: their partial text is never kept.
struct TranslationSessionSnapshot {
    var entries: [String: InPlaceTranslation] = [:]
    var originalKeys: Set<String> = []
    var failed: [String: FailedTranslation] = [:]
    var notice: String?

    struct FailedTranslation {
        let target: TranslationTarget
        let message: String
        let key: String
        let language: String
        let model: String
    }

    var isEmpty: Bool { entries.isEmpty && failed.isEmpty }
}

/// The in-place translation state machine: cache, request queue, cancel and presentation.
///
/// One explicit reader action starts at most one request per paragraph. Multi-paragraph
/// selections are a bounded batch: at most `maxConcurrentRequests` independent block requests in
/// flight, with the next block starting as soon as one finishes. Paragraphs are deliberately not
/// merged into one prompt — a provider can merge or split paragraphs, and one malformed answer
/// would then corrupt several blocks. Per-block requests keep cancellation, cache invalidation
/// and partial failure local to the block.
@MainActor
final class InPlaceTranslationController {
    static let maxConcurrentRequests = 3
    /// Model calls are made through the same plan/preview transport as the assistant; this
    /// version is part of every cache key. Bump it when the translate prompt changes.
    static let promptVersion = TranslationCacheKey.promptVersion

    weak var host: InPlaceTranslationHost?

    private(set) var entries: [String: InPlaceTranslation] = [:]
    private(set) var originalKeys: Set<String> = []
    private(set) var failed: [String: TranslationSessionSnapshot.FailedTranslation] = [:]
    private(set) var notice: String?
    /// Requests currently in flight, keyed by cache digest.
    private var active: [String: Active] = [:]
    private var queue: [Queued] = []
    private var documentURL: URL?
    private var pageCount = 0
    private(set) var startCount = 0
    private(set) var completedCount = 0
    private(set) var cancelledCount = 0
    private(set) var cacheWriteCount = 0
    private(set) var lastError: String?

    private struct Environment {
        let documentKey: String
        let documentURL: URL
        let service: (any AIChatServicing)?
        let settings: AISettingsStore
        let audit: AIAuditTrail
        let connectionMode: AIConnectionMode
        let accountID: UUID?
        let model: String
        let language: String
        let providerSettings: AIProviderSettings
        let apiKey: String?
    }

    private struct Queued {
        let target: TranslationTarget
        let key: String
        let environment: Environment
    }

    private struct Active {
        let target: TranslationTarget
        let key: String
        let environment: Environment
        var handle: (any AIChatHandle)?
        var cancelled = false
    }

    // MARK: - Document lifecycle

    func loadDocument(url: URL?, pageCount: Int) {
        cancelAllForDocumentChange()
        documentURL = url
        self.pageCount = pageCount
        entries = [:]
        originalKeys = []
        failed = [:]
        notice = nil
        lastError = nil
        guard let url, pageCount > 0 else { publish(); return }
        let cacheURL = DocumentEditCache.translationsURL(for: url)
        do {
            let loaded = try TranslationCacheStore.load(from: cacheURL)
            entries = Dictionary(uniqueKeysWithValues: loaded.filter { entry in
                entry.value.page >= 0 && entry.value.page < pageCount
                    && entry.value.promptVersion == Self.promptVersion
            }.map { ($0.key, $0.value) })
        } catch {
            // A damaged cache is kept on disk for recovery; it is never silently replaced.
            notice = "The cached translations could not be read; nothing was sent. "
                + "Open AI translation again to request them. (\(error.localizedDescription))"
        }
        publish()
        if !entries.isEmpty {
            Task { @MainActor [weak self] in await self?.validateRestoredEntries() }
        }
    }

    /// Stop everything belonging to the document being left. Partial text is discarded.
    func cancelAllForDocumentChange() {
        queue.removeAll()
        for (_, var item) in active {
            item.cancelled = true
            item.handle?.cancel()
        }
        active.removeAll()
        cancelledCount += 1
    }

    func suspend() {
        cancelAllForDocumentChange()
        publish()
    }

    /// Drop everything for a document that is being replaced or closed. The caller that is only
    /// opening an editing revision restores a snapshot after the reset.
    func reset() {
        cancelAllForDocumentChange()
        documentURL = nil
        pageCount = 0
        entries = [:]
        originalKeys = []
        failed = [:]
        notice = nil
        publish()
    }

    func snapshot() -> TranslationSessionSnapshot {
        TranslationSessionSnapshot(entries: entries, originalKeys: originalKeys,
                                   failed: failed, notice: notice)
    }

    func restore(_ snapshot: TranslationSessionSnapshot, url: URL?, pageCount: Int) {
        cancelAllForDocumentChange()
        documentURL = url
        self.pageCount = pageCount
        entries = snapshot.entries
        originalKeys = snapshot.originalKeys.intersection(snapshot.entries.keys)
        failed = snapshot.failed
        notice = snapshot.notice
        publish()
    }

    /// Filter a snapshot after a page edit. `pageMap` maps old page index to new (nil deleted),
    /// `rotatedPages` are old indices whose text layer changed orientation, and `editedPages`
    /// are pages whose text content changed in place.
    ///
    /// Deleted and rotated pages lose their overlays because their rectangles no longer describe
    /// the text they covered. Moved pages keep theirs, under a new page component in the key.
    func restoreAfterPageEdit(
        _ snapshot: TranslationSessionSnapshot,
        pageMap: [Int?]?,
        rotatedPages: Set<Int>,
        editedPages: Set<Int>,
        reason: String?
    ) async {
        cancelAllForDocumentChange()
        documentURL = host?.translationDocumentURL
        pageCount = host?.translationPageCount ?? pageCount
        entries = [:]
        failed = [:]
        originalKeys = []
        var dropped = 0
        for entry in snapshot.entries.values {
            if entry.page < 0 || entry.page >= pageCount {
                dropped += 1
                continue
            }
            if rotatedPages.contains(entry.page) {
                dropped += 1
                continue
            }
            let mappedPage: Int?
            if let pageMap, entry.page < pageMap.count {
                mappedPage = pageMap[entry.page]
            } else {
                mappedPage = entry.page
            }
            guard let mappedPage, mappedPage >= 0, mappedPage < pageCount else {
                dropped += 1
                continue
            }
            var moved = entry
            if mappedPage != entry.page {
                moved.key = TranslationCacheKey(
                    sourceText: entry.sourceText, page: mappedPage, rect: entry.rect,
                    language: entry.language, model: entry.model,
                    promptVersion: entry.promptVersion
                ).digest
            }
            entries[moved.key] = moved
            if snapshot.originalKeys.contains(entry.key) { originalKeys.insert(moved.key) }
        }
        for (_, item) in snapshot.failed {
            guard !rotatedPages.contains(item.target.page) else { dropped += 1; continue }
            let mappedPage: Int?
            if let pageMap, item.target.page < pageMap.count {
                mappedPage = pageMap[item.target.page]
            } else {
                mappedPage = item.target.page
            }
            guard let mappedPage, mappedPage >= 0, mappedPage < pageCount else {
                dropped += 1
                continue
            }
            var target = item.target
            if mappedPage != target.page {
                target = TranslationTarget(page: mappedPage, range: target.range,
                                           rect: target.rect, lineRects: target.lineRects,
                                           sourceText: target.sourceText,
                                           sourceFontPt: target.sourceFontPt,
                                           isBlock: target.isBlock)
            }
            let key = TranslationCacheKey(
                sourceText: target.sourceText, page: target.page, rect: target.rect,
                language: item.language, model: item.model,
                promptVersion: Self.promptVersion
            ).digest
            failed[key] = .init(target: target, message: item.message, key: key,
                                language: item.language, model: item.model)
        }
        // A content edit invalidates entries only on the edited page and only when the source no
        // longer matches. Other pages keep their overlays.
        if !editedPages.isEmpty {
            for (key, entry) in entries where editedPages.contains(entry.page) {
                if let page = await host?.translationTextPage(entry.page),
                   entryStillMatches(entry, page: page) {
                    continue
                }
                entries.removeValue(forKey: key)
                originalKeys.remove(key)
                dropped += 1
            }
        }
        saveCache()
        if let reason, dropped > 0 {
            notice = reason + " \(dropped) in-place translation"
                + (dropped == 1 ? " was" : "s were")
                + " removed. The PDF itself was not modified."
        } else {
            notice = snapshot.notice
        }
        publish()
        if !editedPages.isEmpty {
            Task { @MainActor [weak self] in await self?.validateRestoredEntries() }
        }
    }

    // MARK: - Reader actions

    /// Translate these targets. A cached target is shown without any request; the rest join the
    /// bounded queue.
    func translate(targets: [TranslationTarget]) {
        guard !targets.isEmpty else { return }
        guard let environment = makeEnvironment() else { publish(); return }
        var cacheHits = 0
        for target in targets {
            let key = TranslationCacheKey(
                sourceText: target.sourceText, page: target.page, rect: target.rect,
                language: environment.language, model: environment.model,
                promptVersion: Self.promptVersion
            ).digest
            if entries[key] != nil {
                originalKeys.remove(key)
                failed.removeValue(forKey: key)
                cacheHits += 1
                continue
            }
            failed.removeValue(forKey: key)
            if active[key] != nil || queue.contains(where: { $0.key == key }) { continue }
            queue.append(Queued(target: target, key: key, environment: environment))
        }
        if cacheHits > 0 {
            notice = cacheHits == 1
                ? "Cached translation reused. No request was sent."
                : "\(cacheHits) cached translations reused. No request was sent."
        } else if !queue.isEmpty {
            notice = nil
        }
        publish()
        pump()
    }

    func showOriginal(_ key: String) {
        guard entries[key] != nil else { return }
        originalKeys.insert(key)
        publish()
    }

    func showTranslation(_ key: String) {
        guard entries[key] != nil else { return }
        originalKeys.remove(key)
        publish()
    }

    func toggle(_ key: String) {
        if failed[key] != nil { retry(key); return }
        if originalKeys.contains(key) { showTranslation(key) } else { showOriginal(key) }
    }

    func cancel(_ key: String) {
        if let index = queue.firstIndex(where: { $0.key == key }) {
            queue.remove(at: index)
            failed.removeValue(forKey: key)
            notice = "Translation cancelled before it started. The block was left untranslated."
            publish()
            return
        }
        guard var item = active[key] else { return }
        item.cancelled = true
        item.handle?.cancel()
        active[key] = item
        // Remove the overlay immediately: a cancelled block is never left half-covered.
        failed.removeValue(forKey: key)
        notice = "Translation cancelled. The block was left untranslated and no text was cached."
        publish()
    }

    func retry(_ key: String) {
        guard let item = failed[key] else { return }
        failed.removeValue(forKey: key)
        translate(targets: [item.target])
    }

    /// Every cached entry whose range overlaps `range`. A multi-paragraph selection flips all
    /// of its blocks together, not just the first one.
    func entries(overlapping range: ClosedRange<Int>, page: Int) -> [InPlaceTranslation] {
        entries.values
            .filter { $0.page == page && $0.range?.overlaps(range) == true }
            .sorted {
                if let a = $0.range, let b = $1.range, a.lowerBound != b.lowerBound {
                    return a.lowerBound < b.lowerBound
                }
                return $0.createdAt < $1.createdAt
            }
    }

    /// The entry whose cached range overlaps `range`, for the context menu and toolbar.
    ///
    /// Several entries can share a rectangle when the reader changes language or model: the old
    /// one stays valid for the old setting. The current setting's entry wins; otherwise the
    /// newest entry is the one the reader last asked for.
    func entry(overlapping range: ClosedRange<Int>, page: Int) -> InPlaceTranslation? {
        let matches = entries(overlapping: range, page: page)
        let model = (try? currentModel()) ?? ""
        if let current = matches.first(where: {
            $0.language == currentLanguage && $0.model == model
                && $0.promptVersion == Self.promptVersion
        }) {
            return current
        }
        return matches.max { $0.createdAt < $1.createdAt }
    }

    /// The entries to draw: one per page rectangle. Older translations for the same block stay
    /// in the cache (they are still valid for their language/model) but only one can occupy the
    /// block at a time.
    private func displayedEntries() -> [InPlaceTranslation] {
        let model = (try? currentModel()) ?? ""
        var byPlace: [String: InPlaceTranslation] = [:]
        for entry in entries.values {
            let place = "\(entry.page):\(Int((entry.x * 100).rounded())):"
                + "\(Int((entry.y * 100).rounded())):\(Int((entry.width * 100).rounded())):"
                + "\(Int((entry.height * 100).rounded()))"
            let currentMatches = entry.language == currentLanguage && entry.model == model
                && entry.promptVersion == Self.promptVersion
            if let existing = byPlace[place] {
                let existingMatches = existing.language == currentLanguage && existing.model == model
                    && existing.promptVersion == Self.promptVersion
                if currentMatches && !existingMatches {
                    byPlace[place] = entry
                } else if currentMatches == existingMatches && entry.createdAt > existing.createdAt {
                    byPlace[place] = entry
                }
            } else {
                byPlace[place] = entry
            }
        }
        return Array(byPlace.values)
    }

    func translatedEntryIsShowing(_ key: String) -> Bool {
        entries[key] != nil && !originalKeys.contains(key)
    }

    /// The action the toolbar and context menu offer for this selection.
    ///
    /// A selection inside a translated block offers "Show original" and never sends. If the
    /// source is already showing, it offers "Translate": a flip when the cached entry matches the
    /// current language/model, a new request otherwise.
    func action(for range: ClosedRange<Int>, page: Int) -> TranslationSelectionAction {
        if active.values.contains(where: {
            !$0.cancelled && $0.target.page == page && $0.target.range.overlaps(range)
        }) {
            return .cancel
        }
        if failed.values.contains(where: { $0.target.page == page && $0.target.range.overlaps(range) }) {
            return .retry
        }
        let overlapping = entries(overlapping: range, page: page)
        if !overlapping.isEmpty {
            if overlapping.contains(where: { !originalKeys.contains($0.key) }) {
                return .showOriginal
            }
            let model = (try? currentModel()) ?? ""
            if overlapping.allSatisfy({
                $0.language == currentLanguage && $0.model == model
                    && $0.promptVersion == Self.promptVersion
            }) {
                return .showTranslation
            }
        }
        return .translate
    }

    /// The overlay the currently selected block would show, if any.
    func overlay(overlapping range: ClosedRange<Int>, page: Int) -> TranslationOverlay? {
        let key: String?
        if let entry = entry(overlapping: range, page: page) {
            key = entry.key
        } else if let failed = failed.values.first(where: {
            $0.target.page == page && $0.target.range.overlaps(range)
        }) {
            key = failed.key
        } else if let active = active.values.first(where: {
            $0.target.page == page && $0.target.range.overlaps(range)
        }) {
            key = active.key
        } else {
            key = nil
        }
        guard let key else { return nil }
        return overlays().first { $0.id == key }
    }

    func setNotice(_ message: String?) {
        notice = message
        publish()
    }

    // MARK: - Environment

    private var currentLanguage: String {
        let value = host?.translationLanguage.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "English" : value
    }

    private func currentModel() throws -> String {
        guard let settings = host?.translationSettings else {
            throw AISettingsError.invalid(AIAssistantModel.noEngineMessage)
        }
        return try settings.providerSettings().model
    }

    private func makeEnvironment() -> Environment? {
        guard let host, let url = host.translationDocumentURL else {
            failEnvironment("No document is open, so there is nothing to translate.")
            return nil
        }
        guard let settings = host.translationSettings else {
            failEnvironment(AIAssistantModel.noEngineMessage)
            return nil
        }
        guard settings.canUseAI else {
            failEnvironment(settings.connectionMode == .chatGPT
                ? "Sign in with ChatGPT in Settings > AI first. Nothing was sent."
                : AIAssistantModel.noKeyMessage)
            return nil
        }
        guard let service = host.translationService else {
            failEnvironment(AIAssistantModel.noEngineMessage)
            return nil
        }
        let providerSettings: AIProviderSettings
        do { providerSettings = try settings.providerSettings() }
        catch {
            failEnvironment(AIReadableError.message(error))
            return nil
        }
        var apiKey: String?
        var accountID: UUID?
        if settings.connectionMode == .chatGPT {
            guard let account = settings.chatGPT.selected, account.connected else {
                failEnvironment("Sign in with ChatGPT in Settings > AI first. Nothing was sent.")
                return nil
            }
            accountID = account.id
        } else {
            do {
                guard let key = try settings.readKey(), !key.isEmpty else {
                    failEnvironment(AIAssistantModel.noKeyMessage)
                    return nil
                }
                apiKey = key
            } catch {
                failEnvironment(AIReadableError.message(error))
                return nil
            }
        }
        let documentKey = url.standardizedFileURL.path
        return Environment(
            documentKey: documentKey,
            documentURL: url,
            service: service,
            settings: settings,
            audit: host.translationAudit,
            connectionMode: settings.connectionMode,
            accountID: accountID,
            model: providerSettings.model,
            language: currentLanguage,
            providerSettings: providerSettings,
            apiKey: apiKey
        )
    }

    private func failEnvironment(_ message: String) {
        lastError = message
        notice = message
        publish()
    }

    // MARK: - Requests

    private func pump() {
        while active.count < Self.maxConcurrentRequests, !queue.isEmpty {
            let item = queue.removeFirst()
            start(item)
        }
    }

    private func start(_ item: Queued) {
        var activeItem = Active(target: item.target, key: item.key,
                                environment: item.environment)
        activeItem.cancelled = false
        active[item.key] = activeItem
        publish()
        Task { @MainActor [weak self] in
            await self?.run(item)
        }
    }

    private func run(_ item: Queued) async {
        let key = item.key
        defer { finish(key) }
        do {
            let sourcePlan = try await preparePlan(item)
            guard let activeItem = active[key], !activeItem.cancelled,
                  documentMatches(item.environment) else { return }
            var plan = sourcePlan
            if item.environment.connectionMode == .chatGPT {
                plan = try ChatGPTResponses.plan(plan)
            }
            let handle = try AIAuditedRequestStart.start(
                plan: plan, kind: .translation, audit: item.environment.audit
            ) {
                if item.environment.connectionMode == .chatGPT {
                    guard let accountID = item.environment.accountID else {
                        throw AISettingsError.invalid("The ChatGPT account is no longer selected. Nothing was sent.")
                    }
                    startCount += 1
                    return ChatGPTResponsesHandle(plan: plan,
                                                  accounts: item.environment.settings.chatGPT,
                                                  accountID: accountID)
                }
                guard let service = item.environment.service else {
                    throw AISettingsError.invalid(AIAssistantModel.noEngineMessage)
                }
                guard let apiKey = item.environment.apiKey else {
                    throw AISettingsError.invalid(AIAssistantModel.noKeyMessage)
                }
                startCount += 1
                return try service.start(plan, apiKey: apiKey)
            }
            guard var activeItem = active[key], !activeItem.cancelled,
                  documentMatches(item.environment) else {
                handle.cancel()
                return
            }
            activeItem.handle = handle
            active[key] = activeItem

            var text = ""
            var done = false
            while !Task.isCancelled {
                if active[key]?.cancelled == true {
                    handle.cancel()
                    return
                }
                var events = handle.poll()
                if handle.isFinished {
                    events.append(contentsOf: handle.poll())
                }
                for event in events {
                    switch event {
                    case .delta(let delta):
                        text += delta
                    case .done:
                        done = true
                    case .error(let message, let cancelled):
                        if cancelled { return }
                        throw AISettingsError.invalid(message)
                    case .partStarted, .reasoningDelta, .usage, .diagnostics:
                        break
                    }
                }
                if handle.isFinished { break }
                try? await Task.sleep(for: .milliseconds(40))
            }
            guard done, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AISettingsError.invalid("The provider returned no translation text. Nothing was cached.")
            }
            guard active[key]?.cancelled != true, documentMatches(item.environment) else { return }
            commit(item, translatedText: text.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            guard active[key]?.cancelled != true, documentMatches(item.environment) else { return }
            failRequest(item, message: AIReadableError.message(error))
        }
    }

    private func preparePlan(_ item: Queued) async throws -> AiPlanRecord {
        guard let service = item.environment.service else {
            throw AISettingsError.invalid(AIAssistantModel.noEngineMessage)
        }
        let request = AIMakePlanRequest(
            action: .translateSelection,
            currentPage: item.target.page + 1,
            selection: AIReaderSelection(page: item.target.page + 1,
                                         start: item.target.range.lowerBound,
                                         end: item.target.range.upperBound),
            question: nil,
            language: item.environment.language,
            settings: item.environment.providerSettings
        )
        let plan = try await service.prepare(request)
        guard plan.action == .translateSelection else {
            throw AISettingsError.invalid("The prepared request was not a translation. Nothing was sent.")
        }
        guard plan.parts.count == 1 else {
            throw AISettingsError.invalid("A paragraph translation must be one request; "
                + "the prepared plan had \(plan.parts.count). Nothing was sent.")
        }
        return plan
    }

    private func commit(_ item: Queued, translatedText: String) {
        let entry = InPlaceTranslation(
            key: item.key, page: item.target.page, rect: item.target.rect,
            sourceText: item.target.sourceText, translatedText: translatedText,
            language: item.environment.language, model: item.environment.model,
            promptVersion: Self.promptVersion, range: item.target.range,
            isBlock: item.target.isBlock
        )
        entries[item.key] = entry
        originalKeys.remove(item.key)
        failed.removeValue(forKey: item.key)
        completedCount += 1
        saveCache()
        if notice?.hasPrefix("Translation cancelled") == true
            || notice?.hasPrefix("Translation failed") == true {
            notice = nil
        }
        publish()
    }

    private func failRequest(_ item: Queued, message: String) {
        failed[item.key] = .init(target: item.target, message: message, key: item.key,
                                  language: item.environment.language,
                                  model: item.environment.model)
        lastError = message
        notice = "Translation failed for this block: \(message) The block was left untranslated."
        publish()
    }

    private func finish(_ key: String) {
        active.removeValue(forKey: key)
        publish()
        pump()
    }

    private func documentMatches(_ environment: Environment) -> Bool {
        guard let host, let url = host.translationDocumentURL else { return false }
        return url.standardizedFileURL.path == environment.documentKey
    }

    // MARK: - Cache and invalidation

    private var cacheURL: URL? {
        guard let documentURL else { return nil }
        return DocumentEditCache.translationsURL(for: documentURL)
    }

    private func saveCache() {
        guard let cacheURL else { return }
        do {
            try TranslationCacheStore.save(entries, to: cacheURL)
            cacheWriteCount += 1
        } catch {
            notice = "The translation is on screen but could not be cached: \(error.localizedDescription)"
        }
    }

    /// Whether a cached entry still describes what is on the page now.
    ///
    /// It is not enough for the words to exist somewhere: a block whose rectangle moved is a
    /// reflow, and drawing its old translation over the old rectangle would be a lie. A block
    /// entry therefore needs a block at the same rectangle carrying the same source text. A free
    /// selection needs the same text under the same line rectangles.
    private func entryStillMatches(_ entry: InPlaceTranslation,
                                   page: TextPage) -> Bool {
        let blocks = TranslationBlockDetector.blocks(page: entry.page, textPage: page)
        if entry.isBlock {
            return blocks.contains { block in
                block.sourceText == entry.sourceText
                    && abs(block.rect.minX - entry.rect.minX) < 1.5
                    && abs(block.rect.minY - entry.rect.minY) < 1.5
                    && abs(block.rect.width - entry.rect.width) < 1.5
                    && abs(block.rect.height - entry.rect.height) < 1.5
            }
        }
        guard let range = entry.range,
              range.lowerBound >= 0, range.upperBound < page.chars.count,
              let trimmed = TranslationBlockDetector.trimmedRange(range, in: page),
              page.string(in: trimmed) == entry.sourceText else { return false }
        let rects = page.selectionRects(in: trimmed)
        guard let first = rects.first else { return false }
        let union = rects.dropFirst().reduce(first) { $0.union($1) }
        return abs(union.minX - entry.rect.minX) < 1.5
            && abs(union.minY - entry.rect.minY) < 1.5
            && abs(union.width - entry.rect.width) < 1.5
            && abs(union.height - entry.rect.height) < 1.5
    }

    /// Drop entries whose source text no longer matches the page. Used after a relaunch (the file
    /// may have changed outside the reader) and after a content edit. Only the entries whose own
    /// text changed are removed.
    func validateRestoredEntries() async {
        guard let host, let documentURL else { return }
        guard host.translationDocumentURL?.standardizedFileURL == documentURL.standardizedFileURL else {
            return
        }
        var removed = 0
        for (key, entry) in entries {
            guard entry.page >= 0, entry.page < pageCount else {
                entries.removeValue(forKey: key); originalKeys.remove(key); removed += 1; continue
            }
            guard let page = await host.translationTextPage(entry.page) else { continue }
            if entryStillMatches(entry, page: page) { continue }
            entries.removeValue(forKey: key)
            originalKeys.remove(key)
            removed += 1
        }
        if removed > 0 {
            saveCache()
            notice = "\(removed) cached translation"
                + (removed == 1 ? " was" : "s were")
                + " no longer matched the page and was removed. Nothing was requested."
            publish()
        }
    }

    // MARK: - Presentation

    func overlays() -> [TranslationOverlay] {
        var result: [TranslationOverlay] = []
        for (key, item) in active where !item.cancelled {
            result.append(overlay(key: key, target: item.target, translatedText: nil,
                                  phase: .translating))
        }
        for (key, item) in failed {
            result.append(overlay(key: key, target: item.target, translatedText: nil,
                                  phase: .failed(item.message)))
        }
        // While a block is being re-translated (a new model or language), its older cover is
        // suppressed so the block does not show two chips or a stale translation under a new
        // request. The old entry stays in the cache, ready if the reader returns to it.
        let busy = active.values.filter { !$0.cancelled }.map(\.target)
            + failed.values.map(\.target)
        func isBusy(_ entry: InPlaceTranslation) -> Bool {
            busy.contains { target in
                target.page == entry.page && (target.range.overlaps(entry.range ?? 0...0)
                    || target.rect.intersects(entry.rect))
            }
        }
        for entry in displayedEntries() where !isBusy(entry) {
            let key = entry.key
            let target = TranslationTarget(
                page: entry.page, range: entry.range ?? 0...0, rect: entry.rect,
                lineRects: [entry.rect], sourceText: entry.sourceText,
                sourceFontPt: 10, isBlock: entry.isBlock
            )
            result.append(overlay(key: key, target: target,
                                  translatedText: entry.translatedText,
                                  phase: originalKeys.contains(key) ? .original : .translated))
        }
        return result.sorted {
            if $0.page != $1.page { return $0.page < $1.page }
            if abs($0.rect.minY - $1.rect.minY) > 0.5 { return $0.rect.minY < $1.rect.minY }
            return $0.rect.minX < $1.rect.minX
        }
    }

    private func overlay(key: String, target: TranslationTarget, translatedText: String?,
                         phase: TranslationOverlayPhase) -> TranslationOverlay {
        let fit = translatedText.map {
            TranslationTextLayout.fit(text: $0, in: target.rect,
                                      sourceFontPt: target.sourceFontPt)
        }
        return TranslationOverlay(
            id: key, page: target.page, rect: target.rect,
            sourceText: target.sourceText, translatedText: translatedText, phase: phase,
            range: target.range, isBlock: target.isBlock,
            sourceFontPt: target.sourceFontPt, fit: fit,
            paperColor: host?.translationPaperColor(page: target.page)
        )
    }

    private func publish() {
        guard let host else { return }
        host.translationDidChangeOverlays(overlays())
        host.translationDidChangeNotice(notice)
    }
}

/// What the reader's Translate command should do for the current selection.
public enum TranslationSelectionAction: Equatable, Sendable {
    case translate
    case showOriginal
    case showTranslation
    case cancel
    case retry
}
