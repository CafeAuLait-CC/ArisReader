import AppKit
import LyraReaderKit
import Foundation
import PDFKit

/// The eraser: a mode that removes **ink strokes**, not annotations.
///
/// Every check runs through the real `AppState`, the real `MetalCanvasView` event path and the
/// real engine, on scratch copies of the committed fixtures. The canvas is wired exactly as
/// `ReaderWindow` wires it, so a press/drag here takes the same route a hand does: `mouseDown` →
/// `beginEraserGesture`, `mouseDragged` → `extendEraserGesture`, `mouseUp` → `endEraserGesture`.
extension ReaderChecks {
    @MainActor static func eraserChecks(drawing: URL, strokes: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-reader-eraser-\(UUID())")
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
        func placement(_ state: AppState, page: Int) -> PagePlacement {
            guard let frame = state.canvasPageFrames.first(where: { $0.index == page }) else {
                fatalError("FAIL: page \(page + 1) has no canvas frame")
            }
            return frame
        }
        /// A page-local point in the content space the canvas reports.
        func content(_ state: AppState, page: Int, _ point: CGPoint) -> CGPoint {
            let frame = placement(state, page: page)
            return CGPoint(x: frame.leftPt + point.x, y: frame.topPt + point.y)
        }
        func ids(_ state: AppState) -> [UUID] { state.annotations.map(\.id) }
        func requireTargetIsDocument(_ target: AppState.EraserTarget?, _ message: String) {
            guard case .document = target else {
                require(false, "\(message) (got \(String(describing: target)))")
                return
            }
            require(true, message)
        }

        let viewport = CGSize(width: 700, height: 500)
        func makeState(_ url: URL) throws -> AppState {
            let state = AppState(engine: try RustEngine())
            state.setViewportSize(viewport)
            state.newTab(url: url)
            require(state.document != nil, "\(url.lastPathComponent) opens")
            return state
        }

        /// The canvas wired to `state` exactly as `ReaderWindow` wires it.
        func makeCanvas(_ state: AppState) -> MetalCanvasView {
            let view = MetalCanvasView(frame: CGRect(origin: .zero, size: viewport))
            view.annotationTool = .eraser
            view.annotationPageFrames = state.canvasPageFrames
            view.onEraseGestureBegan = { point in
                state.beginEraserGesture(atContentPoint: point)
            }
            view.onEraseGestureDragged = { previous, point in
                state.extendEraserGesture(fromContentPoint: previous, toContentPoint: point)
            }
            view.onEraseGestureEnded = { state.endEraserGesture() }
            view.onEraserHover = { point in state.updateEraserHover(atContentPoint: point) }
            return view
        }
        /// One press-drag-release through that canvas, in content points.
        func drag(_ view: MetalCanvasView, from start: CGPoint, through path: [CGPoint],
                  to end: CGPoint) {
            func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(
                    with: type,
                    location: CGPoint(x: point.x, y: viewport.height - point.y),
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            view.mouseDown(with: event(.leftMouseDown, start))
            for point in path { view.mouseDragged(with: event(.leftMouseDragged, point)) }
            view.mouseDragged(with: event(.leftMouseDragged, end))
            view.mouseUp(with: event(.leftMouseUp, end))
        }
        func escapeEvent() -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        }

        // ── 1. The mode arms and disarms like the other tools ──────────────────────────────
        let document = try copy(drawing, "eraser.pdf")
        let originalPDFBytes = try Data(contentsOf: document)
        let state = try makeState(document)
        require(state.annotationTool == .select, "the reader opens in selection mode")
        require(state.canUseEraserTool,
                "the toolbar's eraser button is enabled while a document is open")
        require(!state.annotationTool.draws && state.annotationTool.kind == nil,
                "the eraser is a mode, not a drawing tool")
        require(AnnotationTool.eraser.erasesInk, "the tool reports that it erases ink")

        state.toggleEraserTool()
        require(state.annotationTool == .eraser, "the eraser button arms the mode")
        state.toggleEraserTool()
        require(state.annotationTool == .select, "clicking the armed eraser again leaves the mode")

        state.annotationTool = .pen
        state.toggleEraserTool()
        require(state.annotationTool == .eraser,
                "arming the eraser replaces another tool: the canvas has one mode")
        state.selectTool()
        require(state.annotationTool == .select, "choosing Select leaves the eraser")

        state.toggleEraserTool()
        require(state.cancelActiveAnnotationTool(), "Escape leaves the eraser")
        require(state.annotationTool == .select, "Escape restores reading mode")
        require(!state.cancelActiveAnnotationTool(),
                "Escape in selection mode is not consumed by the eraser")

        // The same through the canvas' Escape path, which is what the window actually calls.
        let escapeCanvas = makeCanvas(state)
        escapeCanvas.onCancelTool = { state.cancelActiveAnnotationTool() }
        state.toggleEraserTool()
        escapeCanvas.keyDown(with: escapeEvent())
        require(state.annotationTool == .select, "Escape on the canvas leaves the eraser")

        let noDocument = AppState(engine: try RustEngine())
        require(!noDocument.canUseEraserTool,
                "the eraser button has nothing to act on without a document")

        // ── 2. Eraser geometry: whole strokes, a stated tolerance, no partial erase ──────
        // Reach = half the stroke's width + 8 view points at the current zoom. At 100% a 2 pt
        // stroke is therefore removed within 9 page points of its centreline.
        let red = AnnotationColor(red: 200, green: 30, blue: 40, alpha: 255)
        let twoPointReach = AnnotationGeometry.eraserReach(strokeWidth: 2, zoom: 1)
        require(abs(twoPointReach - 9) < 0.001,
                "at 100% a 2 pt stroke's eraser reach is 9 page pt (8 view pt + half the width)")
        let wideReach = AnnotationGeometry.eraserReach(strokeWidth: 12, zoom: 1)
        require(abs(wideReach - 14) < 0.001,
                "a wider stroke is easier to catch: reach adds half the stroke width")
        // Crossing segments must count as distance zero even when neither segment's endpoints
        // are near the other line; this is what lets one fast drag sample erase a stroke.
        require(AnnotationGeometry.distance(
                    fromSegment: CGPoint(x: 0, y: 50), to: CGPoint(x: 100, y: 50),
                    andPolyline: [CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 100)]) == 0,
                "a pointer segment crossing a stroke has distance 0, not endpoint distance")
        require(abs(AnnotationGeometry.distance(
                        fromSegment: CGPoint(x: 0, y: 50), to: CGPoint(x: 100, y: 50),
                        andPolyline: [CGPoint(x: 50, y: 59), CGPoint(x: 50, y: 100)]) - 9) < 0.001,
                "distance to a stroke segment is the segment distance")

        // ── 3. Hover indicates the stroke a press would remove, before it removes it ────
        require(state.addInkAnnotation(page: 0,
                                       points: [CGPoint(x: 100, y: 200), CGPoint(x: 300, y: 200)],
                                       color: red, strokeWidth: 2),
                "stroke A is created")
        guard let strokeA = state.annotations.last else {
            require(false, "stroke A is in the model")
            return
        }
        require(state.addInkAnnotation(page: 0,
                                       points: [CGPoint(x: 100, y: 240), CGPoint(x: 300, y: 240)],
                                       color: red, strokeWidth: 2),
                "stroke B is created")
        guard let strokeB = state.annotations.last else {
            require(false, "stroke B is in the model")
            return
        }
        state.toggleEraserTool()
        state.updateEraserHover(atContentPoint: content(state, page: 0, CGPoint(x: 200, y: 204)))
        require(state.eraserHoverMarkID == strokeA.id.uuidString,
                "hovering within the tolerance marks stroke A as the erase target")
        require(state.canvasAnnotationMarks.first(where: { $0.id == strokeA.id.uuidString })?
                    .isEraseTarget == true,
                "the canvas mark carries the target flag the overlay draws the halo for")
        require(state.canvasAnnotationMarks.first(where: { $0.id == strokeB.id.uuidString })?
                    .isEraseTarget == false,
                "a stroke outside the tolerance is not marked")
        state.updateEraserHover(atContentPoint: content(state, page: 0, CGPoint(x: 200, y: 220)))
        require(state.eraserHoverMarkID == nil,
                "moving 20 pt away removes the pre-erase indication")
        state.selectTool()
        require(state.eraserHoverMarkID == nil,
                "leaving the eraser drops its hover indication")

        // ── 4. One drag across one stroke removes exactly that stroke ─────────────────────
        // A copy saved *before* erasing is the control for the one saved after it: both strokes
        // are in it, so the later copy's missing /NM is the erasure and not a write-path quirk.
        let beforeCopyURL = scratch.appendingPathComponent("before-erase.pdf")
        let savedBefore = await state.saveAnnotatedCopy(to: beforeCopyURL)
        require(savedBefore, "a copy saved before erasing holds both strokes")
        let beforeCopyBytes = try Data(contentsOf: beforeCopyURL)
        require(beforeCopyBytes.range(of: Data(strokeA.id.uuidString.utf8)) != nil,
                "the pre-erase copy contains stroke A's /NM")
        require(beforeCopyBytes.range(of: Data(strokeB.id.uuidString.utf8)) != nil,
                "the pre-erase copy contains stroke B's /NM")

        let sidecarBeforeFirstErase = try Data(contentsOf: sidecar(for: document))
        state.toggleEraserTool()
        let undoBeforeFirstErase = state.undoStack.count
        let writesBeforeFirstErase = state.annotationWriteCount
        let canvas = makeCanvas(state)
        drag(canvas, from: content(state, page: 0, CGPoint(x: 90, y: 205)),
             through: [content(state, page: 0, CGPoint(x: 160, y: 205)),
                       content(state, page: 0, CGPoint(x: 240, y: 205))],
             to: content(state, page: 0, CGPoint(x: 310, y: 205)))
        require(!state.annotations.contains(where: { $0.id == strokeA.id }),
                "the drag removed stroke A")
        require(state.annotations.contains(where: { $0.id == strokeB.id }),
                "the parallel stroke B, 40 pt away, is untouched")
        require(state.undoStack.count == undoBeforeFirstErase + 1,
                "the whole gesture is one undo step")
        require(state.annotationWriteCount == writesBeforeFirstErase + 1,
                "the gesture wrote the sidecar once, on release")

        // ── 5. The pending banner says the PDF on disk is unchanged ──────────────────────
        require(state.hasPendingInkErasure, "the erased stroke is pending a PDF write")
        require(state.eraserPendingSummary?.contains("the PDF on disk is unchanged") == true,
                "the pending banner's summary says the PDF on disk is unchanged")
        let pdfAfterFirstErase = try Data(contentsOf: document)
        require(pdfAfterFirstErase == originalPDFBytes,
                "erasing changed the reader's state, not the PDF on disk")
        let sidecarAfterFirstErase = try Data(contentsOf: sidecar(for: document))
        require(sidecarAfterFirstErase != sidecarBeforeFirstErase,
                "the sidecar is the pending store and did change")
        let pendingSidecar = String(decoding: try Data(contentsOf: sidecar(for: document)),
                                    as: UTF8.self)
        require(!pendingSidecar.contains(strokeA.id.uuidString),
                "the erased stroke is gone from the sidecar")
        require(pendingSidecar.contains(strokeB.id.uuidString),
                "the untouched stroke is still in the sidecar")

        // ── 6. A drag across two strokes removes both as one undo step ───────────────────
        require(state.addInkAnnotation(page: 0,
                                       points: [CGPoint(x: 100, y: 340), CGPoint(x: 300, y: 340)],
                                       color: red, strokeWidth: 2),
                "stroke C is created for the two-stroke sweep")
        guard let strokeC = state.annotations.last else {
            require(false, "stroke C is in the model")
            return
        }
        let orderBeforeSweep = ids(state)
        let undoBeforeSweep = state.undoStack.count
        require(state.annotationTool == .eraser, "the eraser is still armed after the first drag")
        state.updateEraserHover(atContentPoint: nil)
        drag(canvas, from: content(state, page: 0, CGPoint(x: 200, y: 230)),
             through: [content(state, page: 0, CGPoint(x: 200, y: 290))],
             to: content(state, page: 0, CGPoint(x: 200, y: 350)))
        require(!state.annotations.contains(where: { $0.id == strokeB.id }),
                "the sweep crossed and removed stroke B")
        require(!state.annotations.contains(where: { $0.id == strokeC.id }),
                "the same sweep crossed and removed stroke C")
        require(state.undoStack.count == undoBeforeSweep + 1,
                "two strokes erased by one drag are ONE undo step, not two")

        state.undo()
        require(state.annotations.contains(where: { $0.id == strokeB.id })
                    && state.annotations.contains(where: { $0.id == strokeC.id }),
                "one undo restores both erased strokes")
        require(ids(state) == orderBeforeSweep,
                "undo restores the strokes at their original positions in drawing order")
        require(state.annotationWriteCount == writesBeforeFirstErase + 4,
                "undo wrote the restored sidecar once (erase A, add C, erase sweep, undo sweep)")
        state.redo()
        require(!state.annotations.contains(where: { $0.id == strokeB.id })
                    && !state.annotations.contains(where: { $0.id == strokeC.id }),
                "one redo removes both again")
        state.undo() // leave them on the page for the saved-copy check
        require(state.annotations.contains(where: { $0.id == strokeB.id })
                    && state.annotations.contains(where: { $0.id == strokeC.id }),
                "the two strokes are back for the remaining checks")

        // ── 7. A drag that hits nothing changes nothing ─────────────────────────────────
        let idsBeforeNoOp = ids(state)
        let writesBeforeNoOp = state.annotationWriteCount
        let undoBeforeNoOp = state.undoStack.count
        let sidecarBeforeNoOp = try Data(contentsOf: sidecar(for: document))
        drag(canvas, from: content(state, page: 0, CGPoint(x: 500, y: 600)),
             through: [content(state, page: 0, CGPoint(x: 540, y: 620))],
             to: content(state, page: 0, CGPoint(x: 580, y: 640)))
        require(ids(state) == idsBeforeNoOp, "a drag over empty page erases nothing")
        require(state.annotationWriteCount == writesBeforeNoOp,
                "a gesture that erased nothing does not write the sidecar")
        require(state.undoStack.count == undoBeforeNoOp,
                "a gesture that erased nothing adds no undo step")
        let sidecarAfterNoOp = try Data(contentsOf: sidecar(for: document))
        require(sidecarAfterNoOp == sidecarBeforeNoOp,
                "a gesture that erased nothing leaves the sidecar byte-identical")

        // ── 8. A stroke outside the tolerance survives; one inside is erased ───────────
        require(state.addInkAnnotation(page: 0,
                                       points: [CGPoint(x: 100, y: 450), CGPoint(x: 300, y: 450)],
                                       color: red, strokeWidth: 2),
                "stroke D is created for the tolerance check")
        guard let strokeD = state.annotations.last else {
            require(false, "stroke D is in the model")
            return
        }
        drag(canvas, from: content(state, page: 0, CGPoint(x: 90, y: 470)),
             through: [content(state, page: 0, CGPoint(x: 200, y: 470))],
             to: content(state, page: 0, CGPoint(x: 310, y: 470)))
        require(state.annotations.contains(where: { $0.id == strokeD.id }),
                "a drag 20 pt from the stroke is outside the 9 pt reach and erases nothing")
        drag(canvas, from: content(state, page: 0, CGPoint(x: 90, y: 457)),
             through: [content(state, page: 0, CGPoint(x: 200, y: 457))],
             to: content(state, page: 0, CGPoint(x: 310, y: 457)))
        require(!state.annotations.contains(where: { $0.id == strokeD.id }),
                "a drag 7 pt from the stroke is inside the 9 pt reach and erases it")

        // ── 9. Only ink is erased: a highlight and a shape survive the same mode ────────
        // Create the non-ink marks with the tools that normally create them, then re-arm the
        // eraser: the mode change must not disturb them.
        state.selectTool()
        let text = try await state.engine.textPage(0)
        let textRects = text.selectionRects(in: 0...min(24, text.chars.count - 1))
        guard let textRect = textRects.first else {
            require(false, "the fixture has text to highlight")
            return
        }
        let textPoint = content(state, page: 0,
                                CGPoint(x: textRect.midX, y: textRect.midY))
        // The text layer is fetched asynchronously on open; a press only resolves a character
        // once it has arrived, so wait for one instead of sleeping.
        try await eventually("the text layer is ready for the highlight selection", {
            state.beginSelection(at: textPoint)
            return state.selection != nil
        })
        require(state.selection != nil, "a text selection exists for the highlight")
        require(state.addAnnotationFromSelection(kind: .highlight, color: red),
                "a highlight is created for the eraser-mode check")
        state.clearSelection()
        require(state.addShapeAnnotation(kind: .square, page: 0,
                                         start: CGPoint(x: 380, y: 300),
                                         end: CGPoint(x: 480, y: 380),
                                         color: red, strokeWidth: 2),
                "a square is created for the eraser-mode check")
        state.toggleEraserTool()
        require(state.annotationTool == .eraser,
                "the eraser can be re-armed after other tools were used")
        guard let highlightID = state.annotations.first(where: { $0.kind == .highlight })?.id,
              let squareID = state.annotations.first(where: { $0.kind == .square })?.id else {
            require(false, "the highlight and square are in the model")
            return
        }
        require(state.addInkAnnotation(page: 0,
                                       points: [CGPoint(x: 380, y: 500), CGPoint(x: 520, y: 500)],
                                       color: red, strokeWidth: 2),
                "a stroke is created next to the non-ink marks")
        guard let inkNearMarks = state.annotations.last else {
            require(false, "the non-ink check's stroke is in the model")
            return
        }
        drag(canvas, from: content(state, page: 0, CGPoint(x: 370, y: 500)),
             through: [content(state, page: 0, CGPoint(x: 450, y: 500))],
             to: content(state, page: 0, CGPoint(x: 530, y: 500)))
        require(!state.annotations.contains(where: { $0.id == inkNearMarks.id }),
                "the eraser removed the stroke")
        require(state.annotations.contains(where: { $0.id == highlightID }),
                "the highlight is not an ink stroke and survives the eraser")
        require(state.annotations.contains(where: { $0.id == squareID }),
                "the square is not an ink stroke and survives the eraser")

        // ── 10. A saved copy has no annotation for the erased stroke ───────────────────
        // The copy is written from the reader's current list: the erased stroke is absent, so
        // its /Ink (and /NM) never reach the file. Reopening the copy proves it from the PDF
        // side; the raw bytes prove the erased identity is nowhere in the file.
        let copyURL = scratch.appendingPathComponent("erased-copy.pdf")
        let savedCopy = await state.saveAnnotatedCopy(to: copyURL)
        require(savedCopy, "a copy is saved after erasing")
        require(!state.hasPendingInkErasure,
                "saving the copy clears the pending-erasure banner")
        let pdfAfterSave = try Data(contentsOf: document)
        require(pdfAfterSave == originalPDFBytes,
                "saving a copy still leaves the original PDF untouched")
        let copyBytes = try Data(contentsOf: copyURL)
        require(copyBytes.range(of: Data(strokeA.id.uuidString.utf8)) == nil,
                "the saved copy contains no /NM for the erased stroke")
        require(copyBytes.range(of: Data(strokeB.id.uuidString.utf8)) != nil,
                "the saved copy keeps the stroke that was not erased")
        require(copyBytes.range(of: Data("/InkList".utf8)) != nil,
                "the saved copy still carries the kept ink")
        let reopened = try makeState(copyURL)
        try await eventually("the saved copy's annotations are read from the PDF", {
            let loaded = reopened.documentAnnotations.filter { $0.kind == "ink" }
            return loaded.count >= 2 || reopened.documentAnnotationsError != nil
        })
        require(reopened.documentAnnotationsError == nil,
                "the saved copy's annotations read without error")
        let reopenedInkIDs = Set(reopened.documentAnnotations
            .filter { $0.kind == "ink" }
            .map(\.id))
        require(!reopenedInkIDs.contains("nm:\(strokeA.id.uuidString)"),
                "reopening the copy finds no annotation for the erased stroke")
        require(reopenedInkIDs.contains("nm:\(strokeB.id.uuidString)"),
                "reopening the copy finds the kept stroke's annotation")

        // ── 11. A PDF's own ink is refused, with an explanation ───────────────────────
        let external = try makeState(try copy(strokes, "external-ink.pdf"))
        try await eventually("the external ink fixture is read", {
            external.documentAnnotations.count == 5 || external.documentAnnotationsError != nil
        })
        require(external.documentAnnotationsError == nil,
                "the external ink fixture reads without error")
        guard let externalInk = external.documentAnnotations.first(where: { $0.kind == "ink" }),
              let externalPath = externalInk.inkPaths.first, externalPath.count >= 2 else {
            require(false, "the external fixture carries an ink stroke")
            return
        }
        external.toggleEraserTool()
        let externalPoint = CGPoint(x: (externalPath[0].x + externalPath[1].x) / 2,
                                    y: (externalPath[0].y + externalPath[1].y) / 2)
        let externalContent = content(external, page: externalInk.page, externalPoint)
        let hoverTarget = external.eraserTarget(atContentPoint: externalContent)
        requireTargetIsDocument(hoverTarget,
                                "the eraser recognizes a stroke that belongs to the PDF")
        external.updateEraserHover(atContentPoint: externalContent)
        require(external.eraserHoverMarkID == nil,
                "a file-owned stroke gets no erase halo because it cannot be erased")
        let externalCanvas = makeCanvas(external)
        let externalUndo = external.undoStack.count
        let externalWrites = external.annotationWriteCount
        drag(externalCanvas,
             from: content(external, page: externalInk.page, externalPath[0]),
             through: [content(external, page: externalInk.page, externalPath[0])],
             to: content(external, page: externalInk.page, externalPath[externalPath.count - 1]))
        require(external.eraserRefusalNotice == AppState.eraserFileOwnedMessage,
                "erasing a PDF-owned stroke is refused, not silently ignored")
        require(external.eraserRefusalNotice?.contains("belongs to the PDF") == true,
                "the refusal says the ink belongs to the PDF")
        require(external.annotations.isEmpty,
                "the refused gesture did not change the reader's annotation list")
        require(external.documentAnnotations.count == 5,
                "the PDF's own annotation is still there after the refused gesture")
        require(external.canvasAnnotationMarks.contains(where: { $0.id == "pdf:" + externalInk.id }),
                "the refused file-owned stroke is still drawn on the canvas")
        require(external.undoStack.count == externalUndo,
                "a refused erasure adds no undo step")
        require(external.annotationWriteCount == externalWrites,
                "a refused erasure writes no sidecar")
        external.dismissEraserRefusal()
        require(external.eraserRefusalNotice == nil, "the refusal banner can be dismissed")

        // ── 12. Erasing did not disturb the geometry the select tool relies on ─────────
        // (The full suite's selection, click and form checks run on a state that never armed
        // the eraser; this pins the one interaction the mode could plausibly break: a click on
        // a kept stroke still selects it after an erase gesture.)
        state.selectTool()
        guard let keptInk = state.annotations.first(where: { $0.kind == .ink }) else {
            require(false, "a kept ink stroke remains for the selection check")
            return
        }
        let keptBounds = keptInk.geometryBounds ?? .zero
        let keptContent = content(state, page: keptInk.page,
                                  CGPoint(x: keptBounds.midX, y: keptBounds.midY))
        if let hit = state.geometryAnnotationHit(atContentPoint: keptContent) {
            require(hit.id == keptInk.id,
                    "after erasing, clicking a kept stroke still selects it")
        } else {
            require(false, "a kept stroke is still selectable after erasing")
        }

        // ── 13. Erasing the last annotation still produces a saveable copy ────────────────
        // The pending banner's "Save Copy…" must not become a disabled promise when the last
        // stroke was the last annotation: the copy is the source bytes, without any /Ink.
        let loneDocument = try copy(drawing, "lone-stroke.pdf")
        let lone = try makeState(loneDocument)
        require(lone.addInkAnnotation(page: 0,
                                      points: [CGPoint(x: 120, y: 220), CGPoint(x: 260, y: 220)],
                                      color: red, strokeWidth: 2),
                "the lone stroke is created")
        lone.toggleEraserTool()
        let loneCanvas = makeCanvas(lone)
        drag(loneCanvas, from: content(lone, page: 0, CGPoint(x: 110, y: 220)),
             through: [content(lone, page: 0, CGPoint(x: 190, y: 220))],
             to: content(lone, page: 0, CGPoint(x: 270, y: 220)))
        require(lone.annotations.isEmpty, "the lone stroke was the last annotation")
        require(lone.hasPendingInkErasure, "the erasure is pending even with no annotations left")
        require(lone.canSaveAnnotationsToPDF,
                "the pending banner's Save Copy is enabled after the last stroke is erased")
        require(!lone.canReplaceOriginalWithAnnotations,
                "replacing the original is not offered when there is nothing to append")
        let loneCopyURL = scratch.appendingPathComponent("lone-stroke-copy.pdf")
        let savedLone = await lone.saveAnnotatedCopy(to: loneCopyURL)
        require(savedLone, "a copy can be saved with no annotations left")
        require(!lone.hasPendingInkErasure, "the successful copy clears the pending-erasure state")
        let loneBytes = try Data(contentsOf: loneDocument)
        let loneCopyBytes = try Data(contentsOf: loneCopyURL)
        require(loneCopyBytes == loneBytes,
                "with nothing to append, the copy is the original PDF byte for byte (no /Ink)")
        require(lone.lastAnnotationWriteReport?.writtenIDs.isEmpty == true,
                "the report says nothing was appended")
        require(lone.lastAnnotationWriteReport?.sourceBytesPreserved == true,
                "the report says the source bytes were preserved")

        print("Eraser checks passed")
    }
}
