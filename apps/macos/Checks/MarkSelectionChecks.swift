import AppKit
import LyraReaderKit
import CoreGraphics
import Foundation

/// Click-to-select for text markup (highlight, underline, strikeout) and text boxes.
///
/// The distinction under test is **click versus drag**, not position: a press on a highlight or
/// inside a text box is only a candidate, and it selects the mark only when the release stays
/// inside the canvas' click slop. A drag from the same point still selects text, because reading
/// and copying take precedence. Every gesture here goes through the real `MetalCanvasView` event
/// path wired the way `ReaderWindow` wires it, on scratch copies of the committed fixtures.
extension ReaderChecks {
    @MainActor static func markSelectionChecks(fixtures: URL, annotated: URL, multipage: URL)
        async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-reader-mark-select-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        func copy(_ source: URL, _ name: String) throws -> URL {
            let destination = scratch.appendingPathComponent(name)
            try fileManager.copyItem(at: source, to: destination)
            try? fileManager.removeItem(at: sidecar(for: destination))
            return destination
        }
        func sidecar(for document: URL) -> URL {
            document.appendingPathExtension("lyra-reader-annotations.json")
        }
        func sidecarText(_ document: URL) throws -> String {
            String(decoding: try Data(contentsOf: sidecar(for: document)), as: UTF8.self)
        }

        let viewport = CGSize(width: 700, height: 500)
        let document = try copy(fixtures, "mark-selection.pdf")
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(viewport)
        state.newTab(url: document)
        require(state.document != nil, "the text fixture opens for click-selection")

        func placement(_ page: Int) -> PagePlacement {
            guard let frame = state.canvasPageFrames.first(where: { $0.index == page }) else {
                fatalError("FAIL: page \(page + 1) has no canvas frame")
            }
            return frame
        }
        func content(_ page: Int, _ point: CGPoint) -> CGPoint {
            let frame = placement(page)
            return CGPoint(x: frame.leftPt + point.x, y: frame.topPt + point.y)
        }
        func content(rect: CGRect, page: Int) -> CGPoint {
            content(page, CGPoint(x: rect.midX, y: rect.midY))
        }

        // The canvas, wired exactly as ReaderWindow wires it.
        let canvas = MetalCanvasView(frame: CGRect(origin: .zero, size: viewport))
        canvas.annotationPageFrames = state.canvasPageFrames
        canvas.annotationMarks = state.canvasAnnotationMarks
        canvas.annotationTool = .select
        canvas.onAnnotationDraft = { _ in }
        canvas.onDeleteAnnotation = { state.deleteSelectedAnnotation() }
        canvas.onAnnotationDoubleClick = { state.beginEditingTextBox(atContentPoint: $0) }
        canvas.onCancelTool = { state.cancelActiveAnnotationTool() }
        canvas.onPointerDown = { state.beginSelection(at: $0) }
        canvas.onPointerDragged = { state.extendSelection(to: $0) }
        canvas.onPointerUp = { point, wasClick in
            state.endPointerInteraction(at: point, wasClick: wasClick)
        }
        canvas.onCopy = { state.copySelection() }
        canvas.onUndo = { state.undo() }
        canvas.onRedo = { state.redo() }

        func syncCanvas() {
            canvas.scrollYPt = state.scrollYPt
            canvas.zoom = state.zoomFactor
            canvas.contentWidthPt = state.contentWidthPt
            canvas.annotationPageFrames = state.canvasPageFrames
            canvas.annotationMarks = state.canvasAnnotationMarks
            canvas.annotationTool = .select
        }
        func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type,
                location: CGPoint(x: point.x, y: viewport.height - point.y),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func click(at point: CGPoint) {
            syncCanvas()
            canvas.mouseDown(with: event(.leftMouseDown, at: point))
            canvas.mouseUp(with: event(.leftMouseUp, at: point))
        }
        func drag(from start: CGPoint, to end: CGPoint) {
            syncCanvas()
            canvas.mouseDown(with: event(.leftMouseDown, at: start))
            canvas.mouseDragged(with: event(.leftMouseDragged, at: end))
            canvas.mouseUp(with: event(.leftMouseUp, at: end))
        }
        func deleteEvent() -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "\u{7F}",
                charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51)!
        }
        func escapeEvent() -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        }

        // ── 1. The fixture's text layer and a selection that creates real marks ────────
        let engine = try RustEngine()
        _ = try engine.openDocument(at: document)
        let text = try await engine.textPage(0)
        func index(of needle: String) -> Int {
            let pattern = Array(needle.unicodeScalars.map(\.value))
            outer: for start in 0...(text.chars.count - pattern.count) {
                for offset in 0..<pattern.count
                where text.chars[start + offset].unicode != pattern[offset] { continue outer }
                return start
            }
            fatalError("FAIL: fixture text does not contain \(needle)")
        }
        func selectRange(_ range: ClosedRange<Int>) {
            let rects = text.selectionRects(in: range)
            guard let first = rects.first, let last = rects.last else {
                fatalError("FAIL: range \(range) has no text geometry")
            }
            let start = content(0, CGPoint(x: first.minX + 1, y: first.midY))
            let end = content(0, CGPoint(x: last.maxX - 1, y: last.midY))
            state.beginSelection(at: start)
            state.extendSelection(to: end)
            state.endPointerInteraction(at: end, wasClick: false)
        }

        let line1 = index(of: "Line 1")
        let line2 = index(of: "Line 2")
        let line3 = index(of: "Line 3")
        let line4 = index(of: "Line 4")
        let line5 = index(of: "Line 5")
        let line6 = index(of: "Line 6")
        try await eventually("the text layer is ready for a real selection", {
            selectRange(line1...(line1 + 5))
            let ready = state.selection != nil
            state.clearSelection()
            return ready
        })

        let color = AnnotationColor(red: 40, green: 120, blue: 220, alpha: 170)
        var created: [(kind: AppState.Annotation.Kind, id: UUID)] = []
        for (offset, kind) in [AppState.Annotation.Kind.highlight, .underline, .strikeout]
            .enumerated() {
            let start = [line1, line2, line3][offset]
            selectRange(start...(start + 5))
            require(state.addAnnotationFromSelection(kind: kind, color: color),
                    "a \(kind.rawValue) is created for click-selection")
            guard let annotation = state.annotations.last, annotation.kind == kind else {
                require(false, "the \(kind.rawValue) is in the model")
                return
            }
            created.append((kind, annotation.id))
            state.clearSelection()
        }

        // A text box over the fourth line, with text long enough that its fitted box still
        // covers body text for the drag check.
        let boxProbe = text.selectionRects(in: line4...(line4 + 10))
        guard let line4Rect = boxProbe.first else {
            require(false, "the fixture has a fourth line")
            return
        }
        let initialBox = CGRect(x: line4Rect.minX - 4, y: line4Rect.minY - 4,
                                width: max(line4Rect.width + 8, 200), height: 44)
        require(state.addTextBox(page: 0, rect: initialBox), "a text box is created")
        guard let boxID = state.editingAnnotationID else {
            require(false, "the text box enters editing")
            return
        }
        state.updateEditingText("Covering text underneath the box.")
        state.commitTextEditing()
        guard state.annotations.contains(where: { $0.id == boxID }) else {
            require(false, "the text box is in the model")
            return
        }
        created.append((.textBox, boxID))
        require(state.selectedAnnotationID == nil,
                "finishing the text box leaves it unselected, ready for its first click")

        // Every mark carries its real geometry to the overlay: quads for text marks, a rect for
        // the box. Quads arrive with the page's text layer, so wait for that rather than for a
        // fixed interval.
        try await eventually("the text marks reach the overlay with their quads", {
            let marks = state.canvasAnnotationMarks
            return created.allSatisfy { entry in
                guard let mark = marks.first(where: { $0.id == entry.id.uuidString }) else {
                    return false
                }
                return entry.kind == .textBox ? mark.shapeRect != nil : !mark.textQuads.isEmpty
            }
        })

        // ── 2. A plain click on each of the four kinds selects it and reports it ───────
        func clickPoint(for entry: (kind: AppState.Annotation.Kind, id: UUID)) -> CGPoint {
            guard let annotation = state.annotations.first(where: { $0.id == entry.id }) else {
                fatalError("FAIL: mark \(entry.kind.rawValue) is missing")
            }
            if entry.kind == .textBox {
                guard let box = annotation.shapeRect else {
                    fatalError("FAIL: text box has no rect")
                }
                return content(0, CGPoint(x: box.midX, y: box.midY))
            }
            let quads = state.textQuads(for: annotation)
            guard let quad = quads.first else {
                fatalError("FAIL: \(entry.kind.rawValue) has no quads")
            }
            return content(rect: quad, page: 0)
        }
        for entry in created {
            state.clearSelection()
            state.clearAnnotationSelection()
            click(at: clickPoint(for: entry))
            require(state.selectedAnnotationID == entry.id,
                    "a plain click selects the \(entry.kind.rawValue)")
            require(state.statusMessage.contains("Selected a"),
                    "the click reports the \(entry.kind.rawValue) selection "
                        + "(got \"\(state.statusMessage)\")")
        }

        // ── 3. The halo follows the mark's actual quads, not a paragraph box ──────────
        guard let highlighted = state.annotations.first(where: { $0.id == created[0].id }) else {
            require(false, "the highlight is still in the model")
            return
        }
        let highlightQuads = state.textQuads(for: highlighted)
        require(highlightQuads.count >= 1, "the highlight has text geometry")
        state.clearSelection()
        state.clearAnnotationSelection()
        selectRange(line5...(line6 + 5))
        require(state.addAnnotationFromSelection(kind: .highlight, color: color),
                "a multi-line highlight is created for the halo check")
        guard let multi = state.annotations.last else {
            require(false, "the multi-line highlight is in the model")
            return
        }
        state.clearSelection()
        try await eventually("the multi-line highlight has quads", {
            state.textQuads(for: multi).count > 1
        })
        state.selectAnnotation(multi.id)
        syncCanvas()
        guard let multiMark = state.canvasAnnotationMarks.first(where: {
            $0.id == multi.id.uuidString
        }) else {
            require(false, "the multi-line highlight reaches the overlay")
            return
        }
        let multiQuads = state.textQuads(for: multi)
        require(multiQuads.count > 1,
                "a multi-line highlight has one quad per line (\(multiQuads.count))")
        let haloRects = AnnotationGeometry.haloRects(for: multiMark)
        require(haloRects.count == multiQuads.count,
                "the dashed halo has one outline per line, not one paragraph box")
        for (quad, halo) in zip(multiQuads, haloRects) {
            let expected = quad.insetBy(dx: -AnnotationGeometry.markupHaloPaddingPt,
                                        dy: -AnnotationGeometry.markupHaloPaddingPt)
            require(abs(halo.minX - expected.minX) < 0.001
                        && abs(halo.minY - expected.minY) < 0.001
                        && abs(halo.width - expected.width) < 0.001
                        && abs(halo.height - expected.height) < 0.001,
                    "each dashed outline follows its line's quad")
        }
        let paragraphBox = CGRect(
            x: multiQuads.map(\.minX).min() ?? 0,
            y: multiQuads.map(\.minY).min() ?? 0,
            width: (multiQuads.map(\.maxX).max() ?? 0) - (multiQuads.map(\.minX).min() ?? 0),
            height: (multiQuads.map(\.maxY).max() ?? 0) - (multiQuads.map(\.minY).min() ?? 0))
        require(haloRects.first != paragraphBox.insetBy(
                    dx: -AnnotationGeometry.markupHaloPaddingPt,
                    dy: -AnnotationGeometry.markupHaloPaddingPt),
                "the halo is not the bounding box around the paragraph")
        if let first = multiQuads.first, let last = multiQuads.last, multiQuads.count > 1 {
            let gapPoint = CGPoint(x: first.midX, y: (first.maxY + last.minY) / 2)
            require(!AnnotationGeometry.hitTest(multiMark, at: gapPoint, tolerance: 0),
                    "the gap between two highlighted lines is not part of the mark")
        }
        state.clearAnnotationSelection()

        // ── 4. Delete removes each kind with one undo step and one sidecar write ──────
        for entry in created {
            click(at: clickPoint(for: entry))
            require(state.selectedAnnotationID == entry.id,
                    "the \(entry.kind.rawValue) can be selected for deletion")
            let writesBefore = state.annotationWriteCount
            let undoBefore = state.undoStack.count
            syncCanvas()
            canvas.keyDown(with: deleteEvent())
            require(!state.annotations.contains(where: { $0.id == entry.id }),
                    "Delete removes the selected \(entry.kind.rawValue)")
            require(state.selectedAnnotationID == nil,
                    "deleting the \(entry.kind.rawValue) clears its selection")
            require(state.annotationWriteCount == writesBefore + 1,
                    "one Delete writes the sidecar once for the \(entry.kind.rawValue) "
                        + "(\(state.annotationWriteCount - writesBefore) writes)")
            require(state.undoStack.count == undoBefore + 1,
                    "one Delete is one undo step for the \(entry.kind.rawValue)")
            let savedAfterDelete = try sidecarText(document)
            require(!savedAfterDelete.contains(entry.id.uuidString),
                    "the deleted \(entry.kind.rawValue) is gone from the sidecar")
            state.undo()
            require(state.annotations.contains(where: { $0.id == entry.id }),
                    "undo restores the deleted \(entry.kind.rawValue)")
        }
        state.clearSelection()
        state.clearAnnotationSelection()

        // ── 5. A drag from a highlight selects text, not the mark ─────────────────────
        guard let highlight = state.annotations.first(where: { $0.id == created[0].id }),
              let firstQuad = state.textQuads(for: highlight).first,
              let lastQuad = state.textQuads(for: highlight).last else {
            require(false, "the highlight is back for the drag check")
            return
        }
        let dragStart = content(0, CGPoint(x: firstQuad.minX + 1, y: firstQuad.midY))
        let dragEnd = content(0, CGPoint(x: lastQuad.maxX - 1, y: lastQuad.midY))
        let writesBeforeDrag = state.annotationWriteCount
        state.clearSelection()
        state.clearAnnotationSelection()
        drag(from: dragStart, to: dragEnd)
        require(state.selection != nil,
                "a drag starting on a highlight still selects text")
        require(state.selectedAnnotationID == nil,
                "the drag does not select the highlight")
        require(state.annotationWriteCount == writesBeforeDrag,
                "selecting text over a mark does not write the sidecar")
        state.clearSelection()

        // ── 6. A drag inside an unselected text box selects text; the box stays put ────
        guard let box = state.annotations.first(where: { $0.id == boxID }),
              let boxRect = box.shapeRect else {
            require(false, "the text box is back for the drag check")
            return
        }
        let overlap = boxRect.intersection(CGRect(x: line4Rect.minX, y: line4Rect.minY,
                                                  width: line4Rect.width,
                                                  height: line4Rect.height))
        guard overlap.width > 4, overlap.height > 4 else {
            require(false, "the text box covers body text for the interior drag")
            return
        }
        let insideStart = content(0, CGPoint(x: overlap.minX + 1, y: overlap.midY))
        let insideEnd = content(0, CGPoint(x: overlap.maxX - 1, y: overlap.midY))
        state.clearSelection()
        state.clearAnnotationSelection()
        let boxBefore = state.annotations.first(where: { $0.id == boxID })?.shapeRect
        drag(from: insideStart, to: insideEnd)
        require(state.selection != nil, "a drag inside a text box selects the text underneath")
        require(state.selectedAnnotationID == nil,
                "the drag inside an unselected text box does not select the box")
        require(state.annotations.first(where: { $0.id == boxID })?.shapeRect == boxBefore,
                "the unselected text box did not move during a text drag")
        state.clearSelection()

        // Once selected, a drag by the interior moves the box, as before.
        click(at: content(0, CGPoint(x: boxRect.midX, y: boxRect.midY)))
        require(state.selectedAnnotationID == boxID, "the text box is selected again")
        let movedFrom = state.annotations.first(where: { $0.id == boxID })?.shapeRect
        drag(from: content(0, CGPoint(x: boxRect.midX, y: boxRect.midY)),
             to: content(0, CGPoint(x: boxRect.midX + 12, y: boxRect.midY + 7)))
        require(state.annotations.first(where: { $0.id == boxID })?.shapeRect?.minX
                    == (movedFrom?.minX ?? 0) + 12,
                "a selected text box moves when dragged by its interior")
        state.undo()
        state.clearAnnotationSelection()

        // ── 7. Empty space and another mark change the selection ─────────────────────
        let highlightID = created[0].id
        let underlineID = created[1].id
        click(at: clickPoint(for: created[0]))
        require(state.selectedAnnotationID == highlightID, "the highlight is selected first")
        click(at: clickPoint(for: created[1]))
        require(state.selectedAnnotationID == underlineID,
                "a click on another mark moves the selection to it")
        let empty = CGPoint(x: placement(0).leftPt + 3, y: placement(0).topPt + 3)
        click(at: empty)
        require(state.selectedAnnotationID == nil, "a click on empty space deselects the mark")

        // ── 8. Escape and a tool switch deselect ─────────────────────────────────────
        click(at: clickPoint(for: created[0]))
        require(state.selectedAnnotationID == highlightID, "the highlight is selected again")
        syncCanvas()
        canvas.keyDown(with: escapeEvent())
        require(state.selectedAnnotationID == nil, "Escape deselects the mark")
        require(state.annotationTool == .select, "Escape leaves the reader in Select mode")

        click(at: clickPoint(for: created[0]))
        require(state.selectedAnnotationID == highlightID, "the highlight is selected for a tool switch")
        state.annotationTool = .pen
        require(state.selectedAnnotationID == nil, "switching tools deselects the mark")
        state.annotationTool = .select

        // ── 9. A file-owned markup is adopted and selected by a plain click ───────────
        let external = try copy(annotated, "file-owned-markup.pdf")
        let externalState = AppState(engine: try RustEngine())
        externalState.setViewportSize(viewport)
        externalState.newTab(url: external)
        try await eventually("the file's own markup is readable", {
            let loaded = !externalState.documentAnnotations.isEmpty
                || externalState.documentAnnotationsError != nil
            return loaded && !externalState.canvasPageFrames.isEmpty
        })
        guard let fileMarkup = externalState.documentAnnotations.first(where: {
            $0.visible && $0.drawing == .markup && !$0.boxes.isEmpty
        }) else {
            require(false, "the fixture carries a file-owned markup")
            return
        }
        guard let fileFrame = externalState.canvasPageFrames.first(where: {
            $0.index == fileMarkup.page
        }) else {
            require(false, "the file-owned markup has a visible page frame")
            return
        }
        let fileBox = fileMarkup.boxes[0]
        let filePoint = CGPoint(x: fileFrame.leftPt + fileBox.xPt + fileBox.widthPt / 2,
                                y: fileFrame.topPt + fileBox.yPt + fileBox.heightPt / 2)
        let externalCanvas = MetalCanvasView(frame: CGRect(origin: .zero, size: viewport))
        externalCanvas.annotationPageFrames = externalState.canvasPageFrames
        externalCanvas.annotationMarks = externalState.canvasAnnotationMarks
        externalCanvas.annotationTool = .select
        externalCanvas.onPointerDown = { externalState.beginSelection(at: $0) }
        externalCanvas.onPointerDragged = { externalState.extendSelection(to: $0) }
        externalCanvas.onPointerUp = { point, wasClick in
            externalState.endPointerInteraction(at: point, wasClick: wasClick)
        }
        externalCanvas.onDeleteAnnotation = { externalState.deleteSelectedAnnotation() }
        externalCanvas.mouseDown(with: event(.leftMouseDown, at: filePoint))
        externalCanvas.mouseUp(with: event(.leftMouseUp, at: filePoint))
        guard let selectedID = externalState.selectedAnnotationID,
              let adopted = externalState.annotations.first(where: { $0.id == selectedID }) else {
            require(false, "a click adopts the file-owned markup into the editable model")
            return
        }
        require(adopted.fileIdentity == fileMarkup.id,
                "the adopted entry names the file's annotation by its stable identity")
        require(adopted.kind.isTextMarkup,
                "the adopted entry is a text mark, like the file's own")
        require(externalState.markSelectionRefusalNotice == nil,
                "an editable file-owned mark is no longer refused")
        require(!externalState.documentAnnotations.contains(where: { $0.id == fileMarkup.id }),
                "the PDF's copy is hidden while the adopted entry is open, so it is drawn once")
        require(externalState.deleteSelectedAnnotation(),
                "Delete removes the adopted file-owned markup")
        require(externalState.pendingFileDeletions.contains(where: {
            $0.identity == fileMarkup.id
        }), "the deletion is pending until the explicit save")
        require(!externalState.documentAnnotations.contains(where: { $0.id == fileMarkup.id }),
                "the deleted file-owned markup is gone from the page")
        externalState.undo()
        require(externalState.annotations.first(where: { $0.id == adopted.id })?.fileIdentity
                    == fileMarkup.id,
                "undo restores the adopted entry as the editable representation")
        require(!externalState.pendingFileDeletions.contains(where: {
            $0.identity == fileMarkup.id
        }), "undo cancels the pending file deletion")

        // ── 10. Changing page or document drops the selected mark ─────────────────────
        let multipageDocument = try copy(multipage, "multipage-mark-selection.pdf")
        externalState.newTab(url: multipageDocument)
        require(externalState.document?.pageCount ?? 0 > 1,
                "the multipage fixture has more than one page")
        require(externalState.addTextBox(page: 0, rect: CGRect(x: 60, y: 60,
                                                               width: 160, height: 40)),
                "a text box is created for the page-change check")
        guard let pageBoxID = externalState.editingAnnotationID else {
            require(false, "the page-change text box is in the model")
            return
        }
        externalState.updateEditingText("Page one.")
        externalState.commitTextEditing()
        externalState.selectAnnotation(pageBoxID)
        require(externalState.selectedAnnotationID == pageBoxID,
                "the page-change mark starts selected")
        externalState.gotoPage(1)
        require(externalState.currentPage == 2, "the reader turned to page two")
        require(externalState.selectedAnnotationID == nil,
                "changing page deselects the mark")

        externalState.selectAnnotation(pageBoxID)
        externalState.newTab(url: external)
        require(externalState.selectedAnnotationID == nil,
                "changing document deselects the mark")
    }
}
