import AppKit
import Combine
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Region conversations live in the document cache, never in the source PDF.
extension AppState {
    // MARK: - Identity and availability

    public var regionDocumentKey: String? {
        guard let document else { return nil }
        return (translationDocumentURL ?? document.url)?.standardizedFileURL.path ?? document.id.uuidString
    }

    public var currentRegionHistory: [AIRegionHistoryEntry] {
        guard let key = regionDocumentKey else { return [] }
        var entries = regionHistory[key] ?? []
        for card in regionCards where card.documentKey == key {
            if let entry = card.historyEntry {
                entries.removeAll { $0.id == entry.id }; entries.append(entry)
            }
        }
        return entries
    }

    /// Why the toolbar's region button is unavailable, or nil when it can arm.
    public var regionSelectionUnavailableReason: String? {
        guard document != nil else { return "Open a PDF first." }
        if pageOverviewVisible { return "Close page overview first." }
        if contentEditEnabled { return "Region questions are unavailable while Edit PDF is on. Leave page editing first." }
        if annotationTool != .select {
            return "Region questions need the pointer. Leave the annotation or drawing tool first."
        }
        if pageEditBusy || contentCommandInFlight {
            return "A document change is in progress. Try again when it finishes."
        }
        if isRestoringDocument { return "The document is still opening." }
        if editingAnnotationID != nil {
            return "Finish editing the note or text box first."
        }
        if contentTextEditing {
            return "Finish editing the page text first."
        }
        if regionCaptureInFlight { return "A region is already being captured." }
        return nil
    }

    public var canArmRegionSelection: Bool {
        regionSelectionUnavailableReason == nil
    }

    public var canAskAboutRegion: Bool {
        document != nil && !contentEditEnabled && !pageOverviewVisible
    }

    // MARK: - Arming

    public func toggleRegionSelection() {
        if regionSelectionArmed {
            cancelRegionSelection()
        } else {
            armRegionSelection()
        }
    }

    /// Entry point from the panel: arm the same one-shot tool the toolbar button arms.
    public func bringRegionSelectionForward() {
        armRegionSelection()
    }

    public func armRegionSelection() {
        if let reason = regionSelectionUnavailableReason {
            regionRefusalMessage = reason
            statusMessage = reason
            return
        }
        regionRefusalMessage = nil
        regionSelectionArmed = true
        installRegionEscapeMonitor()
        statusMessage = "Drag a rectangle over the page to ask about it · Esc cancels"
    }

    /// Escape must cancel the armed tool even when the toolbar button, not the canvas, holds
    /// first responder. The local monitor is removed the moment the tool disarms.
    private func installRegionEscapeMonitor() {
        guard regionEscapeMonitor == nil else { return }
        regionEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, event.keyCode == 53 else { return event }
            var consumed = false
            MainActor.assumeIsolated {
                if self.regionSelectionArmed {
                    self.cancelRegionSelection(
                        reason: "Region selection cancelled. Nothing was created."
                    )
                    consumed = true
                }
            }
            return consumed ? nil : event
        }
    }

    private func removeRegionEscapeMonitor() {
        if let regionEscapeMonitor {
            NSEvent.removeMonitor(regionEscapeMonitor)
            self.regionEscapeMonitor = nil
        }
    }

    public func cancelRegionSelection(reason: String? = nil) {
        removeRegionEscapeMonitor()
        guard regionSelectionArmed else { return }
        regionSelectionArmed = false
        regionStatusMessage = reason
        statusMessage = reason ?? "Region selection cancelled. Nothing was created."
    }

    /// The canvas finished a drag. The selection disarms immediately; capture runs off the main
    /// thread and opens the card only if it produced a real attachment.
    public func handleRegionSelection(page: Int, rect: CGRect) {
        guard regionSelectionArmed else { return }
        removeRegionEscapeMonitor()
        regionSelectionArmed = false
        regionRefusalMessage = nil
        Task { @MainActor [weak self] in
            await self?.createRegionCard(page: page, rect: rect)
        }
    }

    // MARK: - Capture

    /// Capture and open a card. Public so the native checks can drive the same code path the
    /// canvas does, without synthesising an AppKit mouse event.
    public func createRegionCard(page: Int, rect: CGRect) async {
        guard document != nil, let key = regionDocumentKey else {
            regionRefusalMessage = "Open a PDF first."
            return
        }
        let pageCount = document?.pageCount ?? 0
        guard page >= 0, page < pageCount else {
            regionRefusalMessage = "The selected page is outside this document; nothing was created."
            return
        }
        guard rect.width >= 3, rect.height >= 3 else {
            regionRefusalMessage = "The selected area is empty. Drag a rectangle over the page to ask about it."
            return
        }
        if let refusal = AIRegionLimits.refusal(for: rect, scale: 1, zoom: zoomFactor) {
            regionRefusalMessage = refusal
            statusMessage = refusal
            return
        }
        if let placement = visiblePagePlacements.first(where: { $0.index == page }) {
            let pageRect = CGRect(x: placement.leftPt, y: placement.topPt,
                                  width: placement.widthPt, height: placement.heightPt)
            let clipped = rect.intersection(CGRect(x: 0, y: 0,
                                                   width: placement.widthPt,
                                                   height: placement.heightPt))
            if clipped.isNull || clipped.width < 3 || clipped.height < 3 {
                regionRefusalMessage = "The selection is outside page \(page + 1); nothing was created."
                return
            }
            _ = pageRect
        }
        let captureScale = max(AIRegionLimits.minimumCaptureScale, zoomFactor)
        regionCaptureInFlight = true
        defer { regionCaptureInFlight = false }

        let image: PageImage
        do {
            image = try await engine.rasterizeRegion(
                page: page,
                scale: captureScale,
                xPt: rect.minX,
                yPt: rect.minY,
                widthPt: rect.width,
                heightPt: rect.height,
                transparentBackground: false
            )
        } catch {
            guard regionDocumentKey == key else { return }
            let message = "The region could not be captured: \(error.localizedDescription)"
            regionRefusalMessage = message
            statusMessage = message
            return
        }
        guard regionDocumentKey == key, (document?.pageCount ?? 0) > page else { return }

        let extracted: (text: String, truncated: Bool)
        var textPage: TextPage?
        do {
            let page = try await engine.textPage(page)
            textPage = page
            extracted = AIRegionText.extract(from: page, in: rect)
        } catch {
            // A page with no text layer still has a picture. The request builder refuses only
            // if both are empty or the model is text-only.
            extracted = ("", false)
        }
        guard regionDocumentKey == key else { return }

        if extracted.text.isEmpty, AIRegionText.isBlank(image) {
            let message = "That area is blank: it contains no text, picture or rule. Select a region with content."
            regionRefusalMessage = message
            statusMessage = message
            return
        }
        guard let png = image.contentPNGData() else {
            let message = "The region was captured but could not be encoded as PNG."
            regionRefusalMessage = message
            statusMessage = message
            return
        }
        guard png.count <= AIRegionLimits.maximumPNGBytes else {
            let message = "The region picture is larger than the 8 MiB attachment bound. Select a smaller region."
            regionRefusalMessage = message
            statusMessage = message
            return
        }

        // The tear must not cut a figure or table. Wait for the caption index if it is still on
        // its way, then re-check the document in case the wait spanned a tab switch.
        await awaitFiguresForPlacement()
        guard regionDocumentKey == key else { return }

        let attachment = AIRegionAttachment(
            page: page,
            rect: rect,
            text: extracted.text,
            png: png,
            pixelWidth: image.pixelWidth,
            pixelHeight: image.pixelHeight,
            captureScale: captureScale,
            textTruncated: extracted.truncated
        )
        // Decide where the tear goes while the text layer is in hand. The card starts at its
        // estimate height; if the measured card is taller than the space below the selection,
        // `updateRegionCardHeight` falls back to the page foot explicitly.
        regionRefusalMessage = nil
        addRegionCard(attachment: attachment, tearPlan: tearPlan(for: attachment, textPage: textPage))
    }

    /// The placement rule's answer for one attachment, with the card's starting gap.
    private func tearPlan(for attachment: AIRegionAttachment, textPage: TextPage?) -> PageTearPlan {
        let size = pageSizePt(forPage: attachment.page)
        guard size.height > 1 else { return PageTearPlan(anchor: .pageFoot) }
        let pageBox = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let selection = attachment.rect.intersection(pageBox)
        let clipped = selection.isNull ? attachment.rect : selection
        let figuresOnPage = figures.filter { $0.page == attachment.page }
        return PageTearPlacement.plan(
            pageHeightPt: size.height,
            selection: clipped,
            gapPt: AIRegionCard.initialHeightViewPt / max(zoomFactor, 0.01),
            textPage: textPage,
            figures: figuresOnPage,
            selectionHasText: !attachment.text
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    /// Add a card for an attachment that already exists (the capture, or "ask again here").
    @discardableResult
    private func addRegionCard(
        attachment: AIRegionAttachment,
        tearPlan: PageTearPlan = PageTearPlan(anchor: .pageFoot),
        restoring entry: AIRegionHistoryEntry? = nil
    ) -> AIRegionCard? {
        guard let key = regionDocumentKey, let context = aiReaderContext else { return nil }
        // One card at a time: starting a new region question closes the previous gap and keeps
        // that conversation in history, exactly like the card's own Done button.
        if !regionCards.isEmpty {
            closeAllRegionCards(
                reason: "A new region question started. The previous conversation moved to Region questions.",
                keepHistory: true
            )
        }
        let assistant = regionAssistantFactory?() ?? AIAssistantModel()
        assistant.attach(
            service: regionChatServiceOverride?() ?? aiChatService,
            context: context
        )
        let card = AIRegionCard(
            id: entry?.id ?? UUID(),
            documentKey: key,
            attachment: attachment,
            assistant: assistant,
            tearSplitPt: tearPlan.splitPt,
            tearFallbackReason: tearPlan.fallbackReason
        )
        if let entry { card.restore(entry) }
        card.updateHeight(card.heightViewPt)
        regionCards.append(card)
        regionContentObservers[card.id] = card.objectWillChange
            .throttle(for: .milliseconds(750), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in
                Task { @MainActor in self?.persistRegionHistory() }
            }
        refreshRegionLayout(preservingScroll: true)
        scrollToRegionCard(card)
        let fallback = card.tearFallbackReason.map { " · \($0)" } ?? ""
        if attachment.textTruncated {
            regionStatusMessage = "Region question opened · page \(attachment.page + 1) · text truncated to \(attachment.text.count) characters.\(fallback)"
        } else {
            regionStatusMessage = "Region question opened · page \(attachment.page + 1) · \(attachment.pixelLabel) · \(attachment.characterCount) characters.\(fallback)"
        }
        statusMessage = regionStatusMessage ?? "Region question opened"
        return card
    }

    /// Ask again at a stored region without re-capturing it. The previous question is prefilled
    /// so it can be edited and re-sent.
    @discardableResult
    public func reopenRegionCard(from entry: AIRegionHistoryEntry) -> AIRegionCard? {
        guard regionDocumentKey == entry.documentKey else {
            regionRefusalMessage = "That region belongs to another document; open it first."
            return nil
        }
        guard entry.attachment.page >= 0, entry.attachment.page < (document?.pageCount ?? 0) else {
            regionRefusalMessage = "That saved region refers to a page that is no longer in this PDF. Its conversation is still available in Reading notes."
            return nil
        }
        let plan = tearPlan(for: entry.attachment, textPage: cachedTextPage(entry.attachment.page))
        guard let card = addRegionCard(attachment: entry.attachment, tearPlan: plan, restoring: entry) else { return nil }
        return card
    }

    // MARK: - Card lifecycle

    /// Close one card. `keepHistory` is what separates Done/Collapse from Delete: Done keeps the
    /// question and answer in Region questions, Delete does not.
    public func closeRegionCard(
        id: UUID,
        keepHistory: Bool,
        reason: String? = nil
    ) {
        guard let index = regionCards.firstIndex(where: { $0.id == id }) else { return }
        let card = regionCards[index]
        card.assistant.cancelRegionWork()
        card.notesAssistant.cancelRegionWork()
        card.keepGeneratedNote()
        let gapTop = regionGapTop(for: card) ?? 0
        let gapHeight = regionGapHeightPt(card)
        if let entry = card.historyEntry, keepHistory {
            appendRegionHistory(entry)
        }
        if scrollYPt > gapTop {
            scrollYPt = max(gapTop, scrollYPt - gapHeight)
        }
        regionCards.remove(at: index)
        regionContentObservers[id] = nil
        if !keepHistory, let key = regionDocumentKey {
            regionHistory[key]?.removeAll { $0.id == id }
        }
        persistRegionHistory()
        refreshRegionLayout(preservingScroll: false)
        if keepHistory, card.historyEntry != nil {
            regionStatusMessage = reason ?? "Region conversation moved to Region questions. The page layout returned to normal."
        } else if keepHistory {
            regionStatusMessage = "Empty region draft closed. Nothing was kept."
        } else {
            regionStatusMessage = reason ?? "Region conversation deleted. The page layout returned to normal."
        }
        statusMessage = regionStatusMessage ?? "Region conversation closed"
    }

    /// Close every open card, optionally keeping them in this document's history.
    public func closeAllRegionCards(reason: String? = nil, keepHistory: Bool = true) {
        guard !regionCards.isEmpty else {
            if let reason { regionStatusMessage = reason }
            return
        }
        let cards = regionCards
        for card in cards {
            card.assistant.cancelRegionWork(); card.notesAssistant.cancelRegionWork(); card.keepGeneratedNote()
        }
        if keepHistory {
            for card in cards {
                if let entry = card.historyEntry { appendRegionHistory(entry) }
            }
        }
        let removedShift = cards.reduce(CGFloat(0)) { total, card in
            guard let top = regionGapTop(for: card), scrollYPt > top else { return total }
            return total + min(regionGapHeightPt(card), scrollYPt - top)
        }
        if removedShift > 0 { scrollYPt = max(0, scrollYPt - removedShift) }
        regionCards.removeAll()
        regionContentObservers.removeAll()
        persistRegionHistory()
        refreshRegionLayout(preservingScroll: false)
        regionStatusMessage = reason ?? (keepHistory
            ? "Region conversations moved to Region questions."
            : "Region conversations deleted.")
        statusMessage = regionStatusMessage ?? ""
    }

    /// Called before switching tabs or replacing the document. The conversation is not lost:
    /// it becomes a history entry for the document that owned it.
    public func finishRegionCardsForDocumentSwitch(reason: String? = nil) {
        if regionSelectionArmed {
            cancelRegionSelection(reason: "The document changed; the region tool was disarmed.")
        }
        guard !regionCards.isEmpty else { return }
        closeAllRegionCards(
            reason: reason ?? "Document switched. The region conversation was moved to Region questions.",
            keepHistory: true
        )
    }

    public func updateRegionCardHeight(cardID: UUID, viewHeight: CGFloat) {
        guard let card = regionCards.first(where: { $0.id == cardID }) else { return }
        let previousGap = regionGapTotalPt
        let previousTop = regionGapTop(for: card) ?? 0
        card.updateHeight(viewHeight)

        // Growing a conversation opens more space at the same paper cut. The remaining
        // paper need not be taller than the inserted gap; it must never jump to the page foot.
        let nextGap = regionGapTotalPt
        let nextTop = regionGapTop(for: card) ?? 0
        let delta = nextGap - previousGap
        let anchorMove = nextTop - previousTop
        guard abs(delta) > 0.01 || abs(anchorMove) > 0.01 else { return }
        if scrollYPt >= previousTop + previousGap {
            scrollYPt = max(0, scrollYPt + delta + max(0, anchorMove))
        }
        refreshRegionLayout(preservingScroll: false)
    }

    // MARK: - History

    private func appendRegionHistory(_ entry: AIRegionHistoryEntry) {
        guard !entry.question.isEmpty else { return }
        var list = regionHistory[entry.documentKey] ?? []
        list.removeAll { $0.id == entry.id }
        list.append(entry)
        regionHistory[entry.documentKey] = list
    }

    /// Atomic local storage includes open conversations, so quitting does not lose an answer.
    func persistRegionHistory() {
        guard let key = regionDocumentKey, !regionHistoryLoadFailures.contains(key),
              let url = translationDocumentURL ?? document?.url else { return }
        do {
            let data = try JSONEncoder().encode(currentRegionHistory)
            try data.write(to: DocumentEditCache.directory(for: url)
                .appendingPathComponent("region-conversations-v1.json"), options: .atomic)
        } catch {
            regionRefusalMessage = "Could not save reading notes locally: \(error.localizedDescription)"
        }
    }

    func loadRegionHistory(for url: URL) {
        let key = url.standardizedFileURL.path
        guard regionHistory[key] == nil else { return }
        let file = DocumentEditCache.directory(for: url).appendingPathComponent("region-conversations-v1.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let entries = try JSONDecoder().decode([AIRegionHistoryEntry].self, from: Data(contentsOf: file))
            regionHistory[key] = entries.filter { $0.documentKey == key }
        } catch {
            regionHistoryLoadFailures.insert(key)
            regionRefusalMessage = "Saved reading notes could not be opened. The original records were kept: \(error.localizedDescription)"
        }
    }

    public func deleteRegionHistoryEntry(id: UUID) {
        if regionCards.contains(where: { $0.id == id }) {
            closeRegionCard(id: id, keepHistory: false)
            return
        }
        guard let key = regionDocumentKey, var list = regionHistory[key] else { return }
        list.removeAll { $0.id == id }
        regionHistory[key] = list
        persistRegionHistory()
        regionStatusMessage = "Region conversation deleted from history."
        statusMessage = regionStatusMessage ?? ""
    }

    public func clearRegionHistory() {
        guard let key = regionDocumentKey else { return }
        regionHistory[key] = []
        persistRegionHistory()
        regionStatusMessage = "Region history cleared for this document."
    }

    public var hasExportableRegionHistory: Bool {
        currentRegionHistory.contains(where: \.hasAnswer)
    }

    /// The one markdown knowledge-document command. It asks for a destination, writes the `.md`
    /// and a sibling image folder, and reports where both went. With no answered conversation it
    /// refuses before opening a panel, so it can never produce an empty file.
    public func presentRegionHistoryExportPanel() {
        let entries = currentRegionHistory
        if let reason = AIRegionMarkdownExport.refusalReason(for: entries) {
            regionRefusalMessage = reason
            statusMessage = reason
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Reading Notes"
        panel.message = "One Markdown document plus a folder of region pictures beside it."
        panel.nameFieldStringValue = "\(document?.title ?? "Document") — Reading Notes.md"
        if let markdown = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [markdown]
        }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let title = document?.title ?? "Document"
        let fileName = document?.url?.lastPathComponent ?? "\(title).pdf"
        do {
            let outcome = try AIRegionMarkdownExport.write(
                entries: entries,
                documentTitle: title,
                documentFileName: fileName,
                to: url
            )
            let omitted = outcome.omittedCount
            let suffix = omitted > 0
                ? " \(omitted) conversation\(omitted == 1 ? "" : "s") with no answer were omitted."
                : ""
            regionStatusMessage = "Exported \(outcome.imageCount) region picture\(outcome.imageCount == 1 ? "" : "s") to \(outcome.imageFolderURL.lastPathComponent) beside \(url.lastPathComponent).\(suffix)"
            statusMessage = regionStatusMessage ?? "Region questions exported"
        } catch {
            lastError = "The region questions could not be exported: \(error.localizedDescription)"
        }
    }

    // MARK: - The gap geometry

    /// Height of the gap this card opens, in content points. The card is laid out in view points
    /// (so its typography does not scale with the document), which is why the measured height is
    /// divided by the reader's current zoom.
    package func regionGapHeightPt(_ card: AIRegionCard) -> CGFloat {
        max(44, card.heightViewPt) / max(zoomFactor, 0.01)
    }

    var regionGapTotalPt: CGFloat {
        regionCards.reduce(0) { $0 + regionGapHeightPt($1) }
    }

    /// Which page row a card is inserted after. Continuous layout is one page per row; facing
    /// layout pairs pages 2–3, 4–5, … after the cover.
    func regionRow(forPage page: Int) -> Int {
        guard layoutMode == .facing else { return max(0, page) }
        if page <= 0 { return 0 }
        return 1 + (page - 1) / 2
    }

    func regionFirstPage(inRow row: Int) -> Int {
        guard layoutMode == .facing else { return row }
        return row <= 0 ? 0 : 2 * row - 1
    }

    /// Bottom of a layout row in the engine's unshifted content space.
    private func regionEngineRowBottom(row: Int) -> CGFloat {
        let next = regionFirstPage(inRow: row + 1)
        if let document, next >= 0, next < document.pageCount {
            return engine.pageTopPt(next, gapPt: pageGapPt, layout: layoutMode) - pageGapPt
        }
        return engine.contentHeightPt(gapPt: pageGapPt, layout: layoutMode)
    }

    /// Height of every card inserted in an earlier row.
    private func regionShift(beforeRow row: Int) -> CGFloat {
        regionCards
            .filter { regionRow(forPage: $0.attachment.page) < row }
            .reduce(0) { $0 + regionGapHeightPt($1) }
    }

    /// Page top with the region gaps applied. With no cards this is exactly the engine's value.
    func displayPageTop(_ page: Int) -> CGFloat {
        let engineTop = engine.pageTopPt(page, gapPt: pageGapPt, layout: layoutMode)
        guard !regionCards.isEmpty else { return engineTop }
        return engineTop + regionShift(beforeRow: regionRow(forPage: page))
    }

    /// Content Y where a card's gap starts.
    public func regionGapTop(for cardID: UUID) -> CGFloat? {
        guard let card = regionCards.first(where: { $0.id == cardID }) else { return nil }
        return regionGapTop(for: card)
    }

    func regionGapTop(for card: AIRegionCard) -> CGFloat? {
        guard document != nil else { return nil }
        // An inside-page tear: the gap starts at the page point itself, not at the page's foot.
        // `displayPageTop` already includes every gap from earlier rows; a facing partner in the
        // same row is independent of this page's tear, so no same-row addition belongs here.
        if let split = card.tearSplitPt {
            return displayPageTop(card.attachment.page) + split
        }
        let row = regionRow(forPage: card.attachment.page)
        var top = regionEngineRowBottom(row: row) + regionShift(beforeRow: row)
        for earlier in regionCards {
            guard earlier.id != card.id else { break }
            guard regionRow(forPage: earlier.attachment.page) == row else { continue }
            top += regionGapHeightPt(earlier)
        }
        return top
    }

    /// The visible pages with the gap shifts applied.
    ///
    /// The engine is asked for a window widened by the total gap, then each placement is moved
    /// by the gaps above it. This is a superset of what the shifted viewport needs, and the
    /// filter below hands on exactly the pages that touch the viewport plus its prefetch margin.
    func regionVisiblePages(
        scrollYPt scroll: CGFloat,
        viewportHeightPt height: CGFloat,
        marginPt margin: CGFloat
    ) -> [PagePlacement] {
        guard !regionCards.isEmpty else {
            return engine.visiblePages(
                scrollYPt: scroll,
                viewportHeightPt: height,
                gapPt: pageGapPt,
                marginPt: margin,
                layout: layoutMode
            )
        }
        let totalGap = regionGapTotalPt
        let raw = engine.visiblePages(
            scrollYPt: max(0, scroll - totalGap),
            viewportHeightPt: height + totalGap,
            gapPt: pageGapPt,
            marginPt: margin,
            layout: layoutMode
        )
        let top = scroll - margin
        let bottom = scroll + height + margin
        return raw.compactMap { placement in
            let shift = regionShift(beforeRow: regionRow(forPage: placement.index))
            let shifted = PagePlacement(
                index: placement.index,
                topPt: placement.topPt + shift,
                leftPt: placement.leftPt,
                widthPt: placement.widthPt,
                heightPt: placement.heightPt
            )
            // A torn page's display extends past its paper height by the gap: scrolled into the
            // last card-height of its bottom segment, the page is still on screen even though its
            // paper rect ends above the viewport.
            let displayHeight = shifted.heightPt + (activePageTears[placement.index]?.gapPt ?? 0)
            return shifted.topPt < bottom && shifted.topPt + displayHeight > top
                ? shifted
                : nil
        }
    }

    var regionViewportHeightContentPt: CGFloat {
        max(viewportSizePt.height / max(zoomFactor, 0.01), 1)
    }

    /// The page the viewport top names, with gaps treated as part of the card's page.
    func regionCurrentPage(at scroll: CGFloat) -> Int {
        for card in regionCards {
            guard let top = regionGapTop(for: card) else { continue }
            let bottom = top + regionGapHeightPt(card)
            if scroll >= top && scroll < bottom {
                return card.attachment.page
            }
        }
        let placements = regionVisiblePages(
            scrollYPt: scroll,
            viewportHeightPt: 1,
            marginPt: 0
        )
        guard !placements.isEmpty else { return max(0, currentPage - 1) }
        let above = placements.filter { $0.topPt <= scroll + 0.5 }
        if let best = above.max(by: { $0.topPt < $1.topPt }) { return best.index }
        return placements.first?.index ?? 0
    }

    /// The scroll offset a document would have if no card gap existed below it. Persisted reading
    /// positions use this, so quitting with a card open does not make the next launch jump down
    /// by the card's height (history is session-only and the gap will not be there).
    func regionUnshiftedScrollYPt(_ y: CGFloat) -> CGFloat {
        guard !regionCards.isEmpty else { return y }
        var result = y
        for card in regionCards {
            guard let top = regionGapTop(for: card) else { continue }
            if y >= top { result -= min(regionGapHeightPt(card), y - top) }
        }
        return max(0, result)
    }

    private func regionClampScroll(_ value: CGFloat) -> CGFloat {
        min(max(0, value), max(0, contentHeightPt - regionViewportHeightContentPt))
    }

    /// Recompute content height, scroll clamp and visible pages after cards or their heights
    /// changed. Keeping this in one place is what makes "remove the card and the layout returns
    /// exactly" true: the engine's layout never changed at all.
    func refreshRegionLayout(preservingScroll: Bool) {
        guard document != nil else {
            contentHeightPt = 0
            reloadVisiblePages()
            return
        }
        let base = engine.contentHeightPt(gapPt: pageGapPt, layout: layoutMode)
        contentHeightPt = base + regionGapTotalPt
        if !preservingScroll {
            scrollYPt = regionClampScroll(scrollYPt)
        }
        reloadVisiblePages()
    }

    private func scrollToRegionCard(_ card: AIRegionCard) {
        guard let top = regionGapTop(for: card) else { return }
        let height = regionGapHeightPt(card)
        let viewport = regionViewportHeightContentPt
        if top < scrollYPt || top + height > scrollYPt + viewport {
            scrollYPt = regionClampScroll(max(0, top - min(100 / max(zoomFactor, 0.01), viewport * 0.18)))
            reloadVisiblePages()
        }
    }
}
