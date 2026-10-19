import AppKit
import LyraReaderKit
import Foundation

/// A press that never moved is a **click**, not a selection.
///
/// Selection used to start in `mouseDown`, so a plain click selected the character under the
/// pointer — which then took priority over the click's real job: following a citation, a figure
/// mention or a link into the floating preview. These checks drive the real `MetalCanvasView`
/// events against a real document whose citations resolve, and pin both halves: a click selects
/// nothing and ends any selection it finds, while a drag beyond the slop still selects.
extension ReaderChecks {
    /// Builds the canvas the app builds, wired to `state` exactly as `ReaderWindow` wires it, so a
    /// click here travels the same path as a click in the window: `mouseDown`/`mouseUp` →
    /// `endPointerInteraction`.
    @MainActor static func clickCanvas(state: AppState, size: CGSize = CGSize(width: 700, height: 500)) -> MetalCanvasView {
        let view = MetalCanvasView(frame: CGRect(origin: .zero, size: size))
        view.onPointerDown = { point in state.beginSelection(at: point) }
        view.onPointerDragged = { point in state.extendSelection(to: point) }
        view.onPointerUp = { point, wasClick in
            state.endPointerInteraction(at: point, wasClick: wasClick)
        }
        view.interactionSnapshot = { (state.canvasPages, state.scrollYPt, state.zoomFactor) }
        return view
    }

    /// A click that beat the page's click targets still opens the preview they name.
    ///
    /// Every click target is fetched when its page becomes visible (`loadCitations`,
    /// `loadCaptionMentions`, `loadLinks`), and that fetch is queued behind the page's rasters and
    /// text layer on the engine's serial queue — the first citation read also pays the
    /// document-wide reference scan. So a click made while the page is still appearing is decided
    /// *before* the data it needs exists. These checks take the target's rectangle from a **second**
    /// engine instance (so the state under test stays cold) and click it in the same turn the
    /// document is opened or jumped to, which no fetch can have run in yet.
    @MainActor static func coldClickChecks(citationsURL: URL, mentionsURL: URL) async throws {
        let viewport = CGSize(width: 700, height: 500)

        /// One click, through the canvas' own event path, on a state that is still cold.
        @MainActor func click(_ state: AppState, at point: CGPoint) {
            let view = clickCanvas(state: state, size: viewport)
            let viewPoint = CGPoint(x: point.x, y: viewport.height - (point.y - state.scrollYPt))
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: viewPoint, modifierFlags: [], timestamp: 0,
                                   windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1,
                                   pressure: 1)!
            }
            view.mouseDown(with: event(.leftMouseDown))
            view.mouseUp(with: event(.leftMouseUp))
        }

        /// A fresh state, opened on `url` and scrolled to `page`, with nothing fetched yet.
        func coldState(_ url: URL, at page: Int) throws -> AppState {
            let state = AppState(engine: try RustEngine(), preferFullPageRasters: false)
            state.setViewportSize(viewport)
            require(state.open(url: url), "the click fixture opens")
            state.gotoPage(page)
            return state
        }

        /// The center of `box` (page-local points) in the content space the click is reported in.
        func contentPoint(_ box: CGRect, page: Int, in state: AppState, using probe: PDFEngine) throws -> CGPoint {
            guard let placement = probe.visiblePages(scrollYPt: state.scrollYPt,
                                                     viewportHeightPt: viewport.height,
                                                     gapPt: state.pageGapPt, marginPt: 0)
                .first(where: { $0.index == page }) else {
                fatalError("FAIL: page \(page + 1) is on screen after the jump")
            }
            return CGPoint(x: placement.leftPt + box.midX, y: placement.topPt + box.midY)
        }

        // ── A citation, clicked before its page's citations have been read ───────────────────
        do {
            let probe = try RustEngine()
            _ = try probe.openDocument(at: citationsURL)
            var page = 0
            var citations: [Citation] = []
            for candidate in 0..<4 {
                let found = try await probe.citations(candidate)
                if !found.isEmpty { page = candidate; citations = found; break }
            }
            guard let citation = citations.first else {
                fatalError("FAIL: the click fixture carries a citation to click")
            }
            let state = try coldState(citationsURL, at: page)
            click(state, at: try contentPoint(CGRect(x: citation.xPt, y: citation.yPt,
                                                     width: citation.widthPt, height: citation.heightPt),
                                              page: page, in: state, using: probe))
            try await eventually("a click that beats the citation fetch still opens its reference", {
                state.referencePreview?.kind == .reference
            })
            let written = citation.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            require(state.referencePreview?.title == written,
                    "and it previews the citation that was clicked (\"\(state.referencePreview?.title ?? "none")\")")
            state.closeReferencePreview()
        }

        // ── A figure mention and a table mention, clicked before their page's mentions land ──
        for kind in ["Figure", "Table"] {
            let probe = try RustEngine()
            _ = try probe.openDocument(at: mentionsURL)
            var page = 0
            var mention: CaptionMention?
            for candidate in 0..<8 where mention == nil {
                mention = (try await probe.captionMentions(page: candidate)).first { $0.kind == kind }
                if mention != nil { page = candidate }
            }
            guard let mention else {
                fatalError("FAIL: the mention fixture carries a \(kind) mention to click")
            }
            let state = try coldState(mentionsURL, at: page)
            click(state, at: try contentPoint(CGRect(x: mention.xPt, y: mention.yPt,
                                                     width: mention.widthPt, height: mention.heightPt),
                                              page: page, in: state, using: probe))
            try await eventually("a click that beats the \(kind.lowercased()) mention fetch opens its caption", {
                state.referencePreview != nil
            })
            require(state.referencePreview?.title == "\(kind) \(mention.label)",
                    "and it previews the caption the mention names (\"\(state.referencePreview?.title ?? "none")\")")
            require(state.referencePreview?.kind == .figure,
                    "the \(kind.lowercased()) preview shows the caption's region, not the citation body")
            state.closeReferencePreview()
        }
        print("PASS: a click made before a page's click targets have been fetched still opens "
              + "the citation, the figure or the table it landed on")
    }

    @MainActor static func clickIntentChecks(url: URL) async throws {
        let engine = try RustEngine()
        let state = AppState(engine: engine, preferFullPageRasters: false)
        state.setViewportSize(CGSize(width: 700, height: 500))
        require(state.open(url: url), "the click fixture opens")
        require(MetalCanvasView.clickSlopPt == 3,
                "the click slop is the 3 pt platform convention (\(MetalCanvasView.clickSlopPt) pt)")

        // The fixture's citations sit in its first text row, so this is where the reader is
        // looking when they click one. Scroll it into view rather than assuming where it is.
        let citations = try await engine.citations(0)
        guard let citation = citations.first else {
            fatalError("FAIL: the fixture carries a citation to click")
        }
        state.scroll(byScreenPoints: max(0, citation.yPt - 120))
        let placement = engine.visiblePages(scrollYPt: state.scrollYPt, viewportHeightPt: 500,
                                            gapPt: state.pageGapPt, marginPt: 0)[0]
        func viewPoint(_ xPt: CGFloat, _ yPt: CGFloat) -> CGPoint {
            // Content points → view coordinates (bottom-left origin): the canvas has no surface
            // here, so it is not horizontally offset and the zoom is 1.
            CGPoint(x: placement.leftPt + xPt,
                    y: 500 - (placement.topPt + yPt - state.scrollYPt))
        }
        let citationContent = CGPoint(x: placement.leftPt + citation.xPt + citation.widthPt / 2,
                                      y: placement.topPt + citation.yPt + citation.heightPt / 2)
        let citationPoint = viewPoint(citation.xPt + citation.widthPt / 2,
                                      citation.yPt + citation.heightPt / 2)
        require(citationPoint.y > 0 && citationPoint.y < 500,
                "the citation to click is inside the viewport (\(citationPoint))")

        let text = try await engine.textPage(0)
        func point(_ index: Int) -> CGPoint {
            let char = text.chars[index]
            return viewPoint(char.xPt + char.widthPt / 2, char.yPt + char.heightPt / 2)
        }
        /// A character inside the viewport that no citation box covers: the plain-text click.
        func isOnCitation(_ char: TextChar) -> Bool {
            citations.contains { citation in
                CGRect(x: citation.xPt, y: citation.yPt,
                       width: citation.widthPt, height: citation.heightPt)
                    .insetBy(dx: -1, dy: -1)
                    .contains(CGPoint(x: char.xPt + char.widthPt / 2, y: char.yPt + char.heightPt / 2))
            }
        }
        guard let plainIndex = text.chars.indices.first(where: { index in
            let char = text.chars[index]
            let y = placement.topPt + char.yPt
            return char.widthPt > 0 && char.heightPt > 0 && !isOnCitation(char)
                && y >= state.scrollYPt + 20 && y <= state.scrollYPt + 460
        }) else {
            fatalError("FAIL: the fixture has body text to click")
        }

        let view = MetalCanvasView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        var clicks: [(point: CGPoint, wasClick: Bool)] = []
        view.onPointerDown = { point in state.beginSelection(at: point) }
        view.onPointerDragged = { point in state.extendSelection(to: point) }
        view.onPointerUp = { point, wasClick in
            clicks.append((point, wasClick))
            state.endPointerInteraction(at: point, wasClick: wasClick)
        }
        view.interactionSnapshot = { (state.canvasPages, state.scrollYPt, state.zoomFactor) }

        func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: 1)!
        }
        func click(at point: CGPoint) {
            view.mouseDown(with: event(.leftMouseDown, at: point))
            view.mouseUp(with: event(.leftMouseUp, at: point))
        }

        // The citation index is filled from `reloadVisiblePages`, one turn behind the open; probe
        // the same public hit-test the click uses until it answers, then close what it opened.
        try await eventually("the citation hit-test is ready", { state.openCitation(at: citationContent) })
        state.closeReferencePreview()
        // Let whatever the probe resolved land (and be rejected by that close) before the click
        // this check is actually about.
        try await Task.sleep(for: .milliseconds(200))
        state.closeReferencePreview()
        require(state.referencePreview == nil, "the probe's preview is closed before the click test")

        // ── A click on a citation: nothing selected, preview opened ─────────────────────────
        click(at: citationPoint)
        require(clicks.last?.wasClick == true, "a press and release in place is reported as a click")
        require(state.selection == nil, "a click on a citation selects nothing")
        try await eventually("a click on a citation opens its preview", { state.referencePreview != nil })
        require(state.referencePreview?.kind == .reference,
                "and the preview is the reference the citation names")
        state.closeReferencePreview()

        // ── A click on plain text: nothing selected, no preview ─────────────────────────────
        click(at: point(plainIndex))
        require(state.selection == nil, "a click on plain text selects nothing")
        require(state.referencePreview == nil, "and opens no preview")
        // A little hand movement is still a click: below the slop, and still on the same reference.
        let nudged = CGPoint(x: citationPoint.x + 2, y: citationPoint.y + 1)
        view.mouseDown(with: event(.leftMouseDown, at: citationPoint))
        view.mouseDragged(with: event(.leftMouseDragged, at: nudged))
        view.mouseUp(with: event(.leftMouseUp, at: nudged))
        require(state.selection == nil, "2 pt of movement is still a click, not a selection")
        try await eventually("a nudged click still opens its preview", { state.referencePreview != nil })
        state.closeReferencePreview()

        // ── A drag past the slop still selects, from the character that was pressed ─────────
        let dragStart = plainIndex
        // A real glyph at least four characters on: far enough that the pointer is unmistakably
        // past the slop, and a box whose centre the hit-test resolves to that same character.
        guard let dragEnd = text.chars.indices.first(where: { index in
            index >= dragStart + 4 && text.chars[index].widthPt > 0 && text.chars[index].heightPt > 0
        }) else {
            fatalError("FAIL: the fixture has a second glyph to drag to")
        }
        view.mouseDown(with: event(.leftMouseDown, at: point(dragStart)))
        view.mouseDragged(with: event(.leftMouseDragged, at: point(dragEnd)))
        view.mouseUp(with: event(.leftMouseUp, at: point(dragEnd)))
        guard let dragged = state.selection else {
            fatalError("FAIL: dragging beyond the slop selects")
        }
        require(dragged.range == dragStart...dragEnd,
                "the selection is anchored where the press landed and reaches the pointer "
                + "(\(dragged.range))")
        require(clicks.last?.wasClick == false, "a drag is reported as a drag")

        // ── A click ends the selection: on a citation, on plain text, anywhere ───────────────
        // The reader selected something by dragging; the next click is a fresh start, and it must
        // not leave the old highlight behind — not even when it opens a preview of its own.
        click(at: citationPoint)
        require(state.selection == nil, "a click that opens a preview ends the selection with it")
        try await eventually("the click still opens its preview", { state.referencePreview != nil })
        state.closeReferencePreview()

        // The same click on ordinary text: the selection goes, nothing opens.
        view.mouseDown(with: event(.leftMouseDown, at: point(dragStart)))
        view.mouseDragged(with: event(.leftMouseDragged, at: point(dragEnd)))
        view.mouseUp(with: event(.leftMouseUp, at: point(dragEnd)))
        require(state.selection != nil, "a second drag selects again")
        click(at: point(plainIndex))
        require(state.selection == nil, "a click on plain text ends the selection")
        require(state.referencePreview == nil, "and opens no preview")

        // ── Clicking away from the text deselects too (the platform's click-away) ───────────
        view.mouseDown(with: event(.leftMouseDown, at: point(dragStart)))
        view.mouseDragged(with: event(.leftMouseDragged, at: point(dragEnd)))
        view.mouseUp(with: event(.leftMouseUp, at: point(dragEnd)))
        require(state.selection != nil, "the selection is back for the click-away")
        click(at: viewPoint(-30, 40))
        require(state.selection == nil, "a click on the page's background clears the selection")
        require(state.referencePreview == nil, "and opens nothing")
        print("PASS: a click selects nothing, ends any selection and still follows the reference "
              + "under it; a drag past \(MetalCanvasView.clickSlopPt) pt selects")
    }
}
