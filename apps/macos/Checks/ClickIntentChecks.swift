import AppKit
import ArisReaderKit
import Foundation

/// A press that never moved is a **click**, not a selection.
///
/// Selection used to start in `mouseDown`, so a plain click selected the character under the
/// pointer — which then took priority over the click's real job: following a citation, a figure
/// mention or a link into the floating preview. These checks drive the real `MetalCanvasView`
/// events against a real document whose citations resolve, and pin both halves: a click inside
/// the slop changes nothing and still reaches the preview, a drag beyond it still selects.
extension ReaderChecks {
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

        // ── A click with a selection already made leaves it alone ───────────────────────────
        click(at: citationPoint)
        require(state.selection == dragged,
                "a click that opens a preview leaves the selection untouched")
        try await eventually("the click still opens its preview", { state.referencePreview != nil })
        state.closeReferencePreview()
        click(at: point(plainIndex))
        require(state.selection == dragged, "so does a click on plain text")

        // ── Clicking away from the text still deselects (the platform's click-away) ─────────
        click(at: viewPoint(-30, 40))
        require(state.selection == nil, "a click on the page's background clears the selection")
        require(state.referencePreview == nil, "and opens nothing")
        print("PASS: a click selects nothing and still follows the reference under it; "
              + "a drag past \(MetalCanvasView.clickSlopPt) pt selects")
    }
}
