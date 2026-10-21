import AppKit
import LyraReaderKit
import Foundation
import PDFKit

/// Partial stroke erase: an eraser drag cuts only the ink under its pointer path, the surviving
/// pieces become ink annotations in their own right, one undo puts the original back exactly,
/// and a saved copy carries the pieces but none of the removed geometry.
///
/// Every model check runs through the real `AppState` and `MetalCanvasView` event path on scratch
/// copies of the committed fixtures, exactly as `EraserChecks` does. The pure geometry checks use
/// `InkStrokeSplitter` directly so the tolerance and boundary numbers can be asserted without a
/// document in the way.
extension ReaderChecks {
    @MainActor static func partialEraseChecks(drawing: URL, signed: URL,
                                    inkReview: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-reader-partial-erase-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        func copy(_ source: URL, _ name: String) throws -> URL {
            let destination = scratch.appendingPathComponent(name)
            try fileManager.copyItem(at: source, to: destination)
            try? fileManager.removeItem(at: records(for: destination))
            return destination
        }
        func records(for document: URL) -> URL {
            DocumentEditCache.annotationsURL(for: document)
        }
        func recordsBytes(_ document: URL) throws -> Data {
            try Data(contentsOf: records(for: document))
        }
        func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }
        func contains(_ data: Data, _ text: String) -> Bool {
            data.range(of: Data(text.utf8)) != nil
        }
        func placement(_ state: AppState, page: Int) -> PagePlacement {
            guard let frame = state.canvasPageFrames.first(where: { $0.index == page }) else {
                fatalError("FAIL: page \(page + 1) has no canvas frame")
            }
            return frame
        }
        func content(_ state: AppState, page: Int, _ point: CGPoint) -> CGPoint {
            let frame = placement(state, page: page)
            return CGPoint(x: frame.leftPt + point.x, y: frame.topPt + point.y)
        }
        func makeState(_ url: URL) throws -> AppState {
            let state = AppState(engine: try RustEngine())
            state.setViewportSize(CGSize(width: 700, height: 500))
            state.newTab(url: url)
            require(state.document != nil, "\(url.lastPathComponent) opens")
            return state
        }
        func makeCanvas(_ state: AppState) -> MetalCanvasView {
            let view = MetalCanvasView(frame: CGRect(origin: .zero, size: CGSize(width: 700, height: 500)))
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
        func drag(_ view: MetalCanvasView, from start: CGPoint, through path: [CGPoint],
                  to end: CGPoint) {
            func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(
                    with: type,
                    location: CGPoint(x: point.x, y: 500 - point.y),
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            view.mouseDown(with: event(.leftMouseDown, start))
            for point in path { view.mouseDragged(with: event(.leftMouseDragged, point)) }
            view.mouseDragged(with: event(.leftMouseDragged, end))
            view.mouseUp(with: event(.leftMouseUp, end))
        }
        @discardableResult
        func addStroke(_ state: AppState, _ points: [CGPoint],
                       width: CGFloat = 2,
                       color: AnnotationColor = AnnotationColor(red: 200, green: 30,
                                                               blue: 40, alpha: 255))
            -> AppState.Annotation {
            require(state.addInkAnnotation(page: 0, points: points, color: color,
                                           strokeWidth: width),
                    "a \(points.count)-point ink stroke is created")
            guard let annotation = state.annotations.last else {
                fatalError("FAIL: the stroke is in the model")
            }
            require(annotation.inkPaths == [points], "the stroke stores its points unchanged")
            return annotation
        }
        func y(_ annotation: AppState.Annotation) -> CGFloat {
            annotation.inkPaths.first?.first?.y ?? -1
        }
        func requirePath(_ actual: [CGPoint], _ expected: [CGPoint], _ message: String) {
            require(actual.count == expected.count
                        && zip(actual, expected).allSatisfy { $0 == $1 },
                    "\(message) (got \(actual), expected \(expected))")
        }
        func requireClose(_ actual: CGFloat, _ expected: CGFloat,
                          _ message: String, tolerance: CGFloat = 0.05) {
            require(abs(actual - expected) <= tolerance,
                    "\(message) (got \(actual), expected \(expected))")
        }
        func requireGap(_ points: [CGPoint], low: CGFloat, high: CGFloat,
                        _ message: String) {
            require(points.allSatisfy { $0.x <= low + 0.05 || $0.x >= high - 0.05 },
                    "\(message) (points: \(points.map(\.x)))")
        }
        func requireGap(_ annotation: AppState.Annotation, low: CGFloat, high: CGFloat,
                        _ message: String) {
            requireGap(annotation.inkPaths.flatMap { $0 }, low: low, high: high, message)
        }

        // ── 1. The splitting rule: original points stay, only the reached span goes ────────
        // Reach is the whole-stroke hit tolerance, unchanged: half the stroke's width plus the
        // 8 view-point eraser allowance converted to page points.
        let reach = AnnotationGeometry.eraserReach(strokeWidth: 2, zoom: 1)
        requireClose(reach, 9, "a 2 pt stroke at 100% is reached within 9 page pt")
        let straight = [
            CGPoint(x: 100, y: 300), CGPoint(x: 200, y: 300),
            CGPoint(x: 300, y: 300), CGPoint(x: 400, y: 300),
            CGPoint(x: 500, y: 300),
        ]
        var splitter = InkStrokeSplitter(points: straight, reach: reach)
        require(splitter.remove(pointerFrom: CGPoint(x: 300, y: 250),
                                to: CGPoint(x: 300, y: 350)),
                "the pure splitter removes the middle of a straight stroke")
        let middlePieces = splitter.survivingPaths
        require(middlePieces.count == 2, "the middle of a stroke becomes two pieces")
        requirePath(middlePieces[0].dropLast().map { $0 },
                    [straight[0], straight[1]],
                    "the first piece keeps the original's untouched vertices bit for bit")
        requirePath(middlePieces[1].dropFirst().map { $0 },
                    [straight[3], straight[4]],
                    "the second piece keeps the original's untouched vertices bit for bit")
        requireClose(middlePieces[0].last!.x, 291,
                     "the first cut sits one reach before the pointer centreline")
        requireClose(middlePieces[1].first!.x, 309,
                     "the second cut sits one reach after the pointer centreline")
        requireGap(middlePieces.flatMap { $0 }, low: 292, high: 308,
                   "nothing survives inside the erased gap")
        // Both ends are in reach, so the band around a stroke and its round caps change nothing
        // outside the capsule: a point exactly one reach away is a graze, not a cut.
        var tangent = InkStrokeSplitter(
            points: [CGPoint(x: 0, y: 400), CGPoint(x: 300, y: 309),
                     CGPoint(x: 600, y: 400)], reach: reach)
        require(!tangent.remove(pointerFrom: CGPoint(x: 0, y: 300),
                                to: CGPoint(x: 600, y: 300)),
                "a tangent pointer path is ignored: it would only add an invisible seam")
        require(tangent.survivingPaths.count == 1,
                "a tangent pointer path leaves the stroke as one piece")
        // 8.99 pt away is inside 9 pt; 9.01 pt away is outside. The reach includes half the
        // 2 pt stroke width, and neither vertex is moved or reshaped by the check.
        let justInside = [CGPoint(x: 100, y: 400), CGPoint(x: 300, y: 308.99),
                          CGPoint(x: 500, y: 400)]
        var insideSplitter = InkStrokeSplitter(points: justInside, reach: reach)
        require(insideSplitter.remove(pointerFrom: CGPoint(x: 0, y: 300),
                                      to: CGPoint(x: 600, y: 300)),
                "a vertex 8.99 pt from the pointer is inside the 9 pt reach")
        require(!insideSplitter.survivingPaths.flatMap { $0 }.contains(justInside[1]),
                "the inside vertex is removed")
        let justOutside = [CGPoint(x: 100, y: 400), CGPoint(x: 300, y: 309.01),
                           CGPoint(x: 500, y: 400)]
        var outsideSplitter = InkStrokeSplitter(points: justOutside, reach: reach)
        require(!outsideSplitter.remove(pointerFrom: CGPoint(x: 0, y: 300),
                                        to: CGPoint(x: 600, y: 300)),
                "a vertex 9.01 pt from the pointer is outside the 9 pt reach")
        requirePath(outsideSplitter.survivingPaths[0], justOutside,
                    "a stroke entirely outside the reach keeps every point exactly")

        // ── 2. Middle split through the real gesture: two selectable, movable ink marks ─────
        let middleDocument = try copy(drawing, "middle.pdf")
        let middle = try makeState(middleDocument)
        let middleStroke = addStroke(middle, straight)
        let untouchedPDF = try bytes(middleDocument)
        let untouchedRecords = try recordsBytes(middleDocument)
        middle.toggleEraserTool()
        let middleCanvas = makeCanvas(middle)
        let middleUndo = middle.undoStack.count
        drag(middleCanvas, from: content(middle, page: 0, CGPoint(x: 300, y: 250)),
             through: [], to: content(middle, page: 0, CGPoint(x: 300, y: 350)))
        require(middle.undoStack.count == middleUndo + 1,
                "one middle cut is one undo step")
        let middlePDF = try bytes(middleDocument)
        require(middlePDF == untouchedPDF,
                "the eraser still leaves the PDF on disk byte-identical")
        var pieces = middle.annotations
        require(pieces.count == 2, "the middle cut leaves exactly two annotations")
        require(pieces.allSatisfy { $0.kind == .ink },
                "both pieces are ink annotations in their own right")
        require(pieces.allSatisfy { $0.id != middleStroke.id },
                "neither piece reuses the original stroke's identity")
        require(Set(pieces.map(\.id)).count == 2, "the pieces have distinct identities")
        require(pieces.allSatisfy { $0.color == middleStroke.color
                    && $0.strokeWidth == middleStroke.strokeWidth },
                "the pieces keep the original's colour and stroke width")
        requirePath(pieces[0].inkPaths[0].dropLast().map { $0 },
                    [straight[0], straight[1]],
                    "the first piece keeps the original's untouched points")
        requirePath(pieces[1].inkPaths[0].dropFirst().map { $0 },
                    [straight[3], straight[4]],
                    "the second piece keeps the original's untouched points")
        requireGap(pieces[0], low: 292, high: 308, "the first piece ends outside the gap")
        requireGap(pieces[1], low: 292, high: 308, "the second piece starts outside the gap")
        let pendingCutRecords = String(decoding: try recordsBytes(middleDocument), as: UTF8.self)
        require(!pendingCutRecords.contains(middleStroke.id.uuidString),
                "the original stroke is gone from the annotation cache")
        for piece in pieces {
            require(pendingCutRecords.contains(piece.id.uuidString),
                    "each piece is in the annotation cache under its own identity")
        }
        // Selectable and movable: both are ordinary geometry annotations, not a special case.
        middle.selectTool()
        let pieceMidpoint = CGPoint(x: pieces[0].inkPaths[0].dropLast().last!.x - 5,
                                    y: pieces[0].inkPaths[0][0].y)
        guard let hit = middle.geometryAnnotationHit(
            atContentPoint: content(middle, page: 0, pieceMidpoint), toleranceViewPt: 6)
        else {
            fatalError("FAIL: the first piece is selectable")
        }
        require(hit.id == pieces[0].id, "a piece is selectable by distance to its geometry")
        let movedFrom = pieces[0]
        require(middle.moveAnnotation(pieces[0].id, by: CGPoint(x: 10, y: 5)),
                "a piece can be moved")
        guard let moved = middle.annotations.first(where: { $0.id == movedFrom.id }) else {
            fatalError("FAIL: the moved piece is still in the model")
        }
        require(moved.inkPaths[0] == movedFrom.inkPaths[0].map {
            CGPoint(x: $0.x + 10, y: $0.y + 5)
        }, "moving a piece translates its geometry and keeps its identity")
        // One undo of the move, then one undo of the cut restores the untouched cache bytes.
        middle.undo()
        require(middle.annotations == pieces,
                "undoing the move returns to the split pieces exactly")
        let middleSplitRecords = try recordsBytes(middleDocument)
        middle.undo()
        require(middle.annotations == [middleStroke],
                "one undo restores the original stroke's identity and geometry exactly")
        let middleRestoredRecords = try recordsBytes(middleDocument)
        require(middleRestoredRecords == untouchedRecords,
                "undoing the cut restores the cache byte for byte")
        middle.redo()
        require(middle.annotations == pieces,
                "redo re-applies the same two pieces with the same identities")
        let middleRedoneRecords = try recordsBytes(middleDocument)
        require(middleRedoneRecords == middleSplitRecords,
                "redo rewrites the same annotation cache it wrote after the cut")

        // ── 2b. Annotation cache entry order survives a split of a stroke loaded from the annotation cache ─
        // An annotation restored from the annotation cache has a slot that fixes its place among other
        // entries. The pieces must take that place, not jump to the end of the file.
        let orderDocument = try copy(drawing, "order.pdf")
        let orderWriter = try makeState(orderDocument)
        let orderStroke = addStroke(orderWriter, straight)
        let laterStroke = addStroke(orderWriter, [CGPoint(x: 100, y: 500),
                                                  CGPoint(x: 500, y: 500)])
        let order = try makeState(orderDocument)
        require(order.annotations.map(\.id) == [orderStroke.id, laterStroke.id],
                "reopening the annotation cache restores the strokes in drawing order")
        let orderRecordsBefore = try recordsBytes(orderDocument)
        order.toggleEraserTool()
        let orderCanvas = makeCanvas(order)
        drag(orderCanvas, from: content(order, page: 0, CGPoint(x: 300, y: 250)),
             through: [], to: content(order, page: 0, CGPoint(x: 300, y: 350)))
        let orderPieces = order.annotations.filter { y($0) == 300 }
        require(orderPieces.count == 2, "the loaded stroke splits into two pieces")
        let orderRecordsText = String(decoding: try recordsBytes(orderDocument), as: UTF8.self)
        guard let laterRange = orderRecordsText.range(of: laterStroke.id.uuidString) else {
            fatalError("FAIL: the later stroke is in the annotation cache")
        }
        for piece in orderPieces {
            guard let pieceRange = orderRecordsText.range(of: piece.id.uuidString) else {
                fatalError("FAIL: a piece is in the annotation cache")
            }
            require(pieceRange.lowerBound < laterRange.lowerBound,
                    "a piece's annotation-cache entry stays before the later stroke's entry")
        }
        let reopenedOrder = try makeState(orderDocument)
        require(reopenedOrder.annotations.map(\.id)
                    == [orderPieces[0].id, orderPieces[1].id, laterStroke.id],
                "reopening puts the pieces where the original stroke was, before later ink")
        let orderSplitBytes = try recordsBytes(orderDocument)
        order.undo()
        let orderRestoredBytes = try recordsBytes(orderDocument)
        require(orderRestoredBytes == orderRecordsBefore,
                "a loaded stroke's undo restores the cache byte for byte")
        order.redo()
        let orderRedoneBytes = try recordsBytes(orderDocument)
        require(orderRedoneBytes == orderSplitBytes,
                "a loaded stroke's redo restores the split cache byte for byte")

        // ── 3. An end cut shortens the stroke; the other end can be cut too ───────────────
        let endDocument = try copy(drawing, "end.pdf")
        let endState = try makeState(endDocument)
        let endStroke = addStroke(endState, [CGPoint(x: 100, y: 300), CGPoint(x: 500, y: 300)])
        let endCanvas = makeCanvas(endState)
        endState.toggleEraserTool()
        drag(endCanvas, from: content(endState, page: 0, CGPoint(x: 500, y: 300)),
             through: [], to: content(endState, page: 0, CGPoint(x: 500, y: 300)))
        require(endState.annotations.count == 1,
                "erasing an end leaves one shortened stroke, not two")
        var shortened = endState.annotations[0]
        require(shortened.id != endStroke.id, "the shortened stroke has a new identity")
        requirePath([shortened.inkPaths[0].first!], [CGPoint(x: 100, y: 300)],
                    "the untouched end keeps its exact point")
        requireClose(shortened.inkPaths[0].last!.x, 491,
                     "the cut end sits one reach inside the old end")
        require(shortened.inkPaths[0].allSatisfy { $0.x <= 491.001 },
                "no part of the shortened stroke reaches past the cut")
        endState.undo()
        require(endState.annotations == [endStroke], "undo restores the full end stroke")
        drag(endCanvas, from: content(endState, page: 0, CGPoint(x: 100, y: 300)),
             through: [], to: content(endState, page: 0, CGPoint(x: 100, y: 300)))
        require(endState.annotations.count == 1, "erasing the other end also leaves one stroke")
        shortened = endState.annotations[0]
        requirePath([shortened.inkPaths[0].last!], [CGPoint(x: 500, y: 300)],
                    "the far end keeps its exact point")
        requireClose(shortened.inkPaths[0].first!.x, 109,
                     "the start cut sits one reach inside the old start")
        require(shortened.inkPaths[0].allSatisfy { $0.x >= 108.999 },
                "no part of the shortened stroke reaches before the cut")
        endState.undo()
        require(endState.annotations == [endStroke], "undo restores the start end too")

        // ── 4. Two gaps in one drag produce three pieces in original order ───────────────
        let gapsDocument = try copy(drawing, "gaps.pdf")
        let gaps = try makeState(gapsDocument)
        let gapsStroke = addStroke(gaps, straight)
        let gapsRecordsBefore = try recordsBytes(gapsDocument)
        let gapsCanvas = makeCanvas(gaps)
        gaps.toggleEraserTool()
        drag(gapsCanvas, from: content(gaps, page: 0, CGPoint(x: 200, y: 250)),
             through: [content(gaps, page: 0, CGPoint(x: 200, y: 350)),
                       content(gaps, page: 0, CGPoint(x: 400, y: 350))],
             to: content(gaps, page: 0, CGPoint(x: 400, y: 250)))
        require(gaps.annotations.count == 3, "two gaps leave three pieces")
        let gapStarts = gaps.annotations.map { $0.inkPaths[0].first!.x }
        require(abs(gapStarts[0] - 100) < 0.05
                    && abs(gapStarts[1] - 209) < 0.05
                    && abs(gapStarts[2] - 409) < 0.05,
                "the three pieces stay in original order (starts: \(gapStarts))")
        requireClose(gaps.annotations[0].inkPaths[0].last!.x, 191,
                     "the first gap starts one reach before x=200")
        requireClose(gaps.annotations[1].inkPaths[0].last!.x, 391,
                     "the second gap starts one reach before x=400")
        requireClose(gaps.annotations[1].inkPaths[0].first!.x, 209,
                     "the first gap ends one reach after x=200")
        requireClose(gaps.annotations[2].inkPaths[0].first!.x, 409,
                     "the second gap ends one reach after x=400")
        requireGap(gaps.annotations[0], low: 192, high: 208,
                   "the first piece stops outside the first gap")
        requireGap(gaps.annotations[1], low: 192, high: 208,
                   "the middle piece survives after the first gap")
        requireGap(gaps.annotations[1], low: 392, high: 408,
                   "the middle piece survives before the second gap")
        require(gaps.annotations[2].inkPaths[0].last!.x == 500,
                "the last piece keeps the original end point")
        gaps.undo()
        require(gaps.annotations == [gapsStroke], "one undo restores both gaps at once")
        let gapsRestoredRecords = try recordsBytes(gapsDocument)
        require(gapsRestoredRecords == gapsRecordsBefore,
                "undoing two gaps restores the cache byte for byte")

        // ── 5. One drag across two strokes produces four pieces and one undo step ────────
        let pairDocument = try copy(drawing, "pair.pdf")
        let pair = try makeState(pairDocument)
        let upper = addStroke(pair, [CGPoint(x: 100, y: 300), CGPoint(x: 500, y: 300)])
        let lower = addStroke(pair, [CGPoint(x: 100, y: 360), CGPoint(x: 500, y: 360)])
        let pairCanvas = makeCanvas(pair)
        pair.toggleEraserTool()
        let pairUndo = pair.undoStack.count
        drag(pairCanvas, from: content(pair, page: 0, CGPoint(x: 300, y: 250)),
             through: [], to: content(pair, page: 0, CGPoint(x: 300, y: 410)))
        require(pair.annotations.count == 4,
                "one drag across two strokes leaves four pieces")
        require(pair.undoStack.count == pairUndo + 1, "the two-stroke cut is one undo step")
        let upperPieces = pair.annotations.filter { y($0) == 300 }
        let lowerPieces = pair.annotations.filter { y($0) == 360 }
        require(upperPieces.count == 2 && lowerPieces.count == 2,
                "each stroke contributes two pieces")
        requireGap(upperPieces[0], low: 292, high: 308, "the upper stroke's left piece stops")
        requireGap(lowerPieces[1], low: 292, high: 308, "the lower stroke's right piece starts")
        pair.undo()
        require(pair.annotations == [upper, lower],
                "one undo restores both original strokes in drawing order")
        pair.redo()
        require(pair.annotations.count == 4, "redo re-applies both splits")

        // ── 6. The stated worst case: five strokes become twelve pieces in one undo step ──
        let fiveDocument = try copy(drawing, "five.pdf")
        let five = try makeState(fiveDocument)
        let originals = [120, 180, 240, 300, 360].map { yValue in
            addStroke(five, [CGPoint(x: 80, y: CGFloat(yValue)),
                             CGPoint(x: 300, y: CGFloat(yValue)),
                             CGPoint(x: 520, y: CGFloat(yValue))])
        }
        let fiveRecordsBefore = try recordsBytes(fiveDocument)
        let fiveCanvas = makeCanvas(five)
        five.toggleEraserTool()
        let fiveUndo = five.undoStack.count
        let fivePath: [CGPoint] = [
            CGPoint(x: 200, y: 90), CGPoint(x: 200, y: 150),
            CGPoint(x: 440, y: 150), CGPoint(x: 440, y: 210),
            CGPoint(x: 160, y: 210), CGPoint(x: 160, y: 150),
            CGPoint(x: 160, y: 270), CGPoint(x: 300, y: 270),
            CGPoint(x: 300, y: 330), CGPoint(x: 460, y: 330),
            CGPoint(x: 460, y: 270), CGPoint(x: 460, y: 390),
        ].map { content(five, page: 0, $0) }
        drag(fiveCanvas, from: fivePath[0],
             through: Array(fivePath.dropFirst().dropLast()), to: fivePath.last!)
        require(five.annotations.count == 12,
                "five strokes cut seven times become twelve pieces")
        require(five.undoStack.count == fiveUndo + 1,
                "twelve pieces from one drag are still ONE undo step")
        let expectedCounts = [2, 3, 2, 3, 2]
        var expectedY: [CGFloat] = []
        for (index, count) in expectedCounts.enumerated() {
            expectedY.append(contentsOf: Array(repeating: CGFloat(originals[index].inkPaths[0][0].y),
                                               count: count))
        }
        require(five.annotations.map { y($0) } == expectedY,
                "the pieces are in original stroke order, and inside a stroke in path order")
        for (index, original) in originals.enumerated() {
            let group = five.annotations.filter { y($0) == y(original) }
            require(group.count == expectedCounts[index],
                    "stroke \(index + 1) produced \(expectedCounts[index]) pieces")
            let xs = group.compactMap { $0.inkPaths[0].first?.x }
            require(xs == xs.sorted(), "a stroke's pieces stay in along-path order")
            require(!five.annotations.contains(where: { $0.id == original.id }),
                    "the original stroke \(index + 1) is gone from the model")
        }
        let fiveRecords = String(decoding: try recordsBytes(fiveDocument), as: UTF8.self)
        for original in originals {
            require(!fiveRecords.contains(original.id.uuidString),
                    "the original stroke is gone from the annotation cache")
        }
        for piece in five.annotations {
            require(fiveRecords.contains(piece.id.uuidString),
                    "every one of the twelve pieces has its own annotation-cache entry")
        }
        let twelve = five.annotations
        let fiveRecordsAfter = try recordsBytes(fiveDocument)
        five.undo()
        require(five.annotations == originals,
                "one undo restores all five original strokes, identities and order exactly")
        let fiveRestoredRecords = try recordsBytes(fiveDocument)
        require(fiveRestoredRecords == fiveRecordsBefore,
                "the restored cache is byte-for-byte the untouched cache")
        five.redo()
        require(five.annotations == twelve,
                "one redo re-applies all twelve pieces exactly")
        let fiveRedoneRecords = try recordsBytes(fiveDocument)
        require(fiveRedoneRecords == fiveRecordsAfter,
                "the redone cache is byte-for-byte the split cache")

        // ── 7. Splitting the same stroke twice, undoing twice: byte-for-byte proof ───────
        // This is the undo contract in its strictest form: a second split must start from the
        // first split's undone state, and each undo must reproduce the untouched cache bytes.
        let twiceDocument = try copy(drawing, "twice.pdf")
        let twice = try makeState(twiceDocument)
        let twiceStroke = addStroke(twice, straight)
        let twicePDF = try bytes(twiceDocument)
        let twiceRecords = try recordsBytes(twiceDocument)
        let twiceCanvas = makeCanvas(twice)
        twice.toggleEraserTool()
        func cutMiddleOfTwiceStroke() {
            drag(twiceCanvas, from: content(twice, page: 0, CGPoint(x: 300, y: 250)),
                 through: [], to: content(twice, page: 0, CGPoint(x: 300, y: 350)))
        }
        cutMiddleOfTwiceStroke()
        require(twice.annotations.count == 2, "the first split produces two pieces")
        let firstSplit = twice.annotations
        let firstSplitIDs = Set(firstSplit.map(\.id))
        let firstSplitRecords = try recordsBytes(twiceDocument)
        twice.undo()
        require(twice.annotations == [twiceStroke],
                "after the first split, undo restores the untouched stroke exactly")
        let firstUndoRecords = try recordsBytes(twiceDocument)
        require(firstUndoRecords == twiceRecords,
                "the first undo restores the untouched cache byte for byte")
        cutMiddleOfTwiceStroke()
        require(twice.annotations.count == 2, "the same stroke splits again after undo")
        let secondSplit = twice.annotations
        let secondSplitIDs = Set(secondSplit.map(\.id))
        require(secondSplitIDs.isDisjoint(with: firstSplitIDs),
                "the second split names its pieces anew; no identity leaks through undo")
        require(firstSplit.map(\.inkPaths) == secondSplit.map(\.inkPaths),
                "both splits produce exactly the same surviving geometry")
        let secondSplitRecords = try recordsBytes(twiceDocument)
        twice.undo()
        require(twice.annotations == [twiceStroke],
                "after the second split, undo restores the untouched stroke exactly")
        let secondUndoRecords = try recordsBytes(twiceDocument)
        require(secondUndoRecords == twiceRecords,
                "the second undo also restores the untouched cache byte for byte")
        let finalPDF = try bytes(twiceDocument)
        require(finalPDF == twicePDF, "neither split wrote the PDF on disk")
        twice.redo()
        require(twice.annotations == secondSplit,
                "redo re-applies the second split with the same identities and geometry")
        let redoneRecords = try recordsBytes(twiceDocument)
        require(redoneRecords == secondSplitRecords,
                "redo reproduces the split cache byte for byte")
        twice.undo()
        let finalUndoRecords = try recordsBytes(twiceDocument)
        require(finalUndoRecords == twiceRecords,
                "a third undo (through redo) still restores the untouched cache byte for byte")

        // ── 8. A saved copy carries the pieces and none of the removed geometry ──────────
        // The distinct x of the vertex in the gap is a token the writer emits as text in
        // `/InkList` and in the appearance stream, so its absence is a real scan of the file,
        // not a model-level assertion. The surviving vertices have distinct binary-fraction
        // coordinates too, so none of them can accidentally spell the removed value.
        let art: [CGPoint] = [
            CGPoint(x: 100.125, y: 300.25),
            CGPoint(x: 180.25, y: 310.5),
            CGPoint(x: 213.375, y: 317.625),
            CGPoint(x: 260.5, y: 305.75),
            CGPoint(x: 340.75, y: 320.125),
            CGPoint(x: 420.875, y: 312.5),
        ]
        let saveDocument = try copy(drawing, "save-split.pdf")
        let saveState = try makeState(saveDocument)
        let savePDFBefore = try bytes(saveDocument)
        let saveStroke = addStroke(saveState, art, width: 3)
        let saveCanvas = makeCanvas(saveState)
        saveState.toggleEraserTool()
        drag(saveCanvas, from: content(saveState, page: 0, CGPoint(x: 213.375, y: 250)),
             through: [], to: content(saveState, page: 0, CGPoint(x: 213.375, y: 390)))
        let savePieces = saveState.annotations
        require(savePieces.count == 2, "the saved-copy stroke splits into two pieces")
        let saveCopyURL = scratch.appendingPathComponent("save-split-copy.pdf")
        let saved = await saveState.saveAnnotatedCopy(to: saveCopyURL)
        require(saved, "a copy is saved after the split")
        let saveReport = saveState.lastAnnotationWriteReport
        require(saveReport?.sourceBytesPreserved == true,
                "a reader-only split is an incremental append: the source bytes are preserved")
        require((saveReport?.appendedBytes ?? 0) > 0, "the split copy appends its /Ink entries")
        require(Set(saveReport?.writtenIDs ?? []) == Set(savePieces.map(\.id.uuidString)),
                "the write report names exactly the two pieces")
        let saveSourceBytes = try bytes(saveDocument)
        require(saveSourceBytes == savePDFBefore,
                "splitting a cached stroke leaves the source PDF byte-identical")
        let saveCopyBytes = try bytes(saveCopyURL)
        require(contains(saveCopyBytes, "/InkList"),
                "the copy carries the pieces as /InkList")
        for piece in savePieces {
            require(contains(saveCopyBytes, piece.id.uuidString),
                    "the copy carries a piece's own /NM")
        }
        require(!contains(saveCopyBytes, saveStroke.id.uuidString),
                "the copy carries no /NM for the removed original")
        require(!contains(saveCopyBytes, "213.375"),
                "scanning the copy finds none of the removed vertex's x coordinate")
        let pageHeight = saveState.document?.firstPageSize.height ?? 842
        let removedPDFY = String(format: "%.6g", Double(pageHeight) - 317.625)
        let removedPDFY4 = String(format: "%.4f", Double(pageHeight) - 317.625)
        require(!contains(saveCopyBytes, removedPDFY) && !contains(saveCopyBytes, removedPDFY4),
                "scanning the copy finds none of the removed vertex's PDF-space y coordinate"
                + " (\(removedPDFY))")
        require(contains(saveCopyBytes, "100.125") && contains(saveCopyBytes, "420.875"),
                "the surviving vertices' coordinates are present in the copy")

        let reopened = try makeState(saveCopyURL)
        try await eventually("the split copy's ink annotations are read", {
            let count = reopened.documentAnnotations.filter { $0.kind == "ink" }.count
            return count >= 2 || reopened.documentAnnotationsError != nil
        })
        require(reopened.documentAnnotationsError == nil,
                "the split copy's annotations read without error")
        let reopenedInk = reopened.documentAnnotations.filter { $0.kind == "ink" }
        require(reopenedInk.count == 2, "the split copy reopens with exactly two ink annotations")
        let reopenedIDs = Set(reopenedInk.map(\.id))
        for piece in savePieces {
            require(reopenedIDs.contains("nm:\(piece.id.uuidString)"),
                    "reopening finds a piece by its own name")
            require(!reopenedIDs.contains("nm:\(saveStroke.id.uuidString)"),
                    "reopening finds no annotation for the removed original")
        }
        require(reopenedInk.allSatisfy { $0.inkPaths.count == 1 },
                "each reopened piece carries its own single /InkList path")
        require(reopenedInk.allSatisfy { abs(($0.borderWidthPt ?? 0) - 3) < 0.01 },
                "each reopened piece carries the original 3 pt stroke width")
        require(reopenedInk.allSatisfy { ink in
            guard let color = ink.color else { return false }
            return color.red == saveStroke.color.red && color.green == saveStroke.color.green
                && color.blue == saveStroke.color.blue
        }, "each reopened piece carries the original colour")
        let reopenedPoints = reopenedInk.flatMap { $0.inkPaths.flatMap { $0 } }
        require(!reopenedPoints.contains { $0.x > 205 && $0.x < 221 },
                "the reopened pieces have no point inside the erased gap")
        for x in [100.125, 180.25, 260.5, 340.75, 420.875] {
            require(reopenedPoints.contains { abs($0.x - x) < 0.01 },
                    "the reopened pieces keep the surviving vertex x=\(x)")
        }

        // ── 9. A stroke the PDF owns follows the cross-reader path ──────────────────────
        // First make a real file-owned ink annotation by saving the stroke into a copy without
        // splitting it. Reopening that copy reads the ink from the PDF, not from an annotation cache.
        let singleSource = try copy(drawing, "file-source.pdf")
        let singleState = try makeState(singleSource)
        let fileStroke = addStroke(singleState, art, width: 3)
        let singleCopyURL = scratch.appendingPathComponent("file-source-copy.pdf")
        let savedSingleCopy = await singleState.saveAnnotatedCopy(to: singleCopyURL)
        require(savedSingleCopy,
                "a copy with the unsplit stroke is saved")
        let fileOwned = try makeState(singleCopyURL)
        try await eventually("the file-owned stroke is read from the copy", {
            fileOwned.documentAnnotations.contains { $0.kind == "ink" }
                || fileOwned.documentAnnotationsError != nil
        })
        require(fileOwned.documentAnnotationsError == nil,
                "the file-owned ink reads without error")
        guard let fileInk = fileOwned.documentAnnotations.first(where: { $0.kind == "ink" }) else {
            fatalError("FAIL: the copy carries a file-owned ink annotation")
        }
        require(fileInk.id == "nm:\(fileStroke.id.uuidString)",
                "the file-owned stroke keeps the /NM it was written with")
        require(fileInk.inkPaths.first?.count == art.count,
                "the file-owned stroke has the original point count")
        let fileBytesBefore = try bytes(singleCopyURL)
        fileOwned.toggleEraserTool()
        let fileCanvas = makeCanvas(fileOwned)
        let fileUndo = fileOwned.undoStack.count
        drag(fileCanvas, from: content(fileOwned, page: 0, CGPoint(x: 213.375, y: 250)),
             through: [], to: content(fileOwned, page: 0, CGPoint(x: 213.375, y: 390)))
        require(fileOwned.undoStack.count == fileUndo + 1,
                "a file-owned partial erase is one undo step")
        require(!fileOwned.documentAnnotations.contains(where: { $0.id == fileInk.id }),
                "the file-owned original is gone from the page")
        require(fileOwned.pendingFileDeletions.contains(where: { $0.identity == fileInk.id }),
                "the file-owned original is staged for deletion by identity")
        require(fileOwned.annotations.count == 2,
                "the file-owned stroke's pieces are reader ink annotations")
        require(fileOwned.annotations.allSatisfy { $0.id != fileStroke.id },
                "the pieces do not reuse the file-owned annotation's identity")
        let filePieces = fileOwned.annotations
        let fileRecords = String(decoding: try recordsBytes(singleCopyURL), as: UTF8.self)
        for piece in filePieces {
            require(fileRecords.contains(piece.id.uuidString),
                    "the piece is in the annotation cache while the original is pending deletion")
        }
        // One undo puts the file-owned annotation back and cancels the deletion; redo reapplies.
        fileOwned.undo()
        require(fileOwned.documentAnnotations.contains(where: { $0.id == fileInk.id }),
                "undo restores the file-owned annotation")
        require(fileOwned.pendingFileDeletions.isEmpty,
                "undo cancels the pending file-annotation deletion")
        require(fileOwned.annotations.isEmpty,
                "undo removes the pieces the split introduced")
        fileOwned.redo()
        require(!fileOwned.documentAnnotations.contains(where: { $0.id == fileInk.id })
                    && fileOwned.pendingFileDeletions.contains(where: {
                        $0.identity == fileInk.id
                    }),
                "redo removes the file-owned annotation and restages the deletion")
        require(fileOwned.annotations == filePieces,
                "redo re-applies the same pieces with the same identities")
        let fileSplitCopyURL = scratch.appendingPathComponent("file-split-copy.pdf")
        let savedFileSplitCopy = await fileOwned.saveAnnotatedCopy(to: fileSplitCopyURL)
        require(savedFileSplitCopy,
                "the file-owned partial erase saves into a copy")
        let fileReport = fileOwned.lastAnnotationWriteReport
        require(fileReport?.fullRewrite == true,
                "deleting the file-owned original prunes the copy: it is a full rewrite")
        require(fileReport?.sourceBytesPreserved == false,
                "a pruned copy does not claim the source bytes")
        require(fileReport?.deletedFileIDs == [fileInk.id],
                "the report names the deleted file-owned annotation")
        require(Set(fileReport?.writtenIDs ?? []) == Set(filePieces.map(\.id.uuidString)),
                "the report names the pieces appended to the copy")
        let fileBytesAfter = try bytes(singleCopyURL)
        require(fileBytesAfter == fileBytesBefore,
                "the source copy is byte-identical after saving the split copy")
        let fileSplitBytes = try bytes(fileSplitCopyURL)
        require(!contains(fileSplitBytes, fileStroke.id.uuidString),
                "the saved copy contains no /NM for the removed file-owned annotation")
        require(!contains(fileSplitBytes, "213.375"),
                "the saved copy contains none of the removed file-owned geometry")
        require(contains(fileSplitBytes, "/InkList"),
                "the saved copy carries the pieces as new /Ink entries")
        for piece in filePieces {
            require(contains(fileSplitBytes, piece.id.uuidString),
                    "the saved copy carries the piece's own name")
        }
        let fileReopened = try makeState(fileSplitCopyURL)
        try await eventually("the file-split copy's ink is read", {
            fileReopened.documentAnnotations.contains { $0.kind == "ink" }
                || fileReopened.documentAnnotationsError != nil
        })
        require(fileReopened.documentAnnotationsError == nil,
                "the file-split copy's annotations read without error")
        let fileReopenedInk = fileReopened.documentAnnotations.filter { $0.kind == "ink" }
        require(fileReopenedInk.count == 2,
                "the file-split copy reopens with the two pieces only")
        require(!fileReopenedInk.contains { $0.id == fileInk.id },
                "the file-split copy carries no annotation for the deleted original")
        require(fileReopenedInk.flatMap { $0.inkPaths.flatMap { $0 } }
                    .allSatisfy { !($0.x > 205 && $0.x < 221) },
                "the reopened file-split copy has no point inside the erased gap")

        // ── 9b. A bare file-owned stroke can still be erased as a whole ────────────────
        // The no-attachment case keeps the old cross-reader contract: tracing the stroke stages
        // the annotation's deletion, writes no reader ink (there are no pieces), and a saved
        // copy prunes the original.
        let fullEraseURL = try copy(singleCopyURL, "file-full-erase.pdf")
        let fullErase = try makeState(fullEraseURL)
        try await eventually("the whole-erase source's ink is read", {
            fullErase.documentAnnotations.contains { $0.kind == "ink" }
                || fullErase.documentAnnotationsError != nil
        })
        require(fullErase.documentAnnotationsError == nil,
                "the whole-erase source's annotations read without error")
        guard let fullInk = fullErase.documentAnnotations.first(where: { $0.kind == "ink" }),
              let fullPath = fullInk.inkPaths.first, fullPath.count >= 2 else {
            fatalError("FAIL: the whole-erase source carries a bare ink stroke")
        }
        let fullBytesBefore = try bytes(fullEraseURL)
        let fullWrites = fullErase.annotationWriteCount
        fullErase.toggleEraserTool()
        let fullCanvas = makeCanvas(fullErase)
        let fullContentPath = fullPath.map { content(fullErase, page: fullInk.page, $0) }
        drag(fullCanvas, from: fullContentPath[0],
             through: Array(fullContentPath.dropFirst().dropLast()),
             to: fullContentPath[fullContentPath.count - 1])
        require(!fullErase.documentAnnotations.contains(where: { $0.id == fullInk.id }),
                "tracing a bare file-owned stroke removes the annotation as a whole")
        require(fullErase.pendingFileDeletions.map { $0.identity } == [fullInk.id],
                "the whole removal is staged as one file-annotation deletion")
        require(fullErase.annotations.isEmpty,
                "a fully erased file-owned stroke leaves no cached pieces")
        require(fullErase.annotationWriteCount == fullWrites,
                "a fully erased file-owned stroke writes nothing to the annotation cache")
        fullErase.undo()
        require(fullErase.documentAnnotations.contains(where: { $0.id == fullInk.id }),
                "undo restores the fully erased file-owned stroke")
        require(fullErase.pendingFileDeletions.isEmpty,
                "undo cancels the fully erased file-owned stroke's deletion")
        fullErase.redo()
        require(!fullErase.documentAnnotations.contains(where: { $0.id == fullInk.id })
                    && fullErase.pendingFileDeletions.map { $0.identity } == [fullInk.id],
                "redo removes the file-owned stroke and restages its deletion")
        let fullEraseCopyURL = scratch.appendingPathComponent("file-full-erase-copy.pdf")
        let fullEraseSaved = await fullErase.saveAnnotatedCopy(to: fullEraseCopyURL)
        require(fullEraseSaved, "the fully erased file-owned stroke saves into a copy")
        let fullReport = fullErase.lastAnnotationWriteReport
        require(fullReport?.fullRewrite == true,
                "the fully erased file-owned stroke prunes the copy")
        require(fullReport?.deletedFileIDs == [fullInk.id],
                "the whole-erase report names the deleted annotation")
        require(fullReport?.writtenIDs.isEmpty == true,
                "the whole erase appends no ink")
        let fullCopyBytes = try bytes(fullEraseCopyURL)
        require(!contains(fullCopyBytes, fullInk.id.hasPrefix("nm:")
                    ? String(fullInk.id.dropFirst(3)) : fullInk.id),
                "the whole-erase copy contains no /NM for the removed stroke")
        let fullBytesAfter = try bytes(fullEraseURL)
        require(fullBytesAfter == fullBytesBefore,
                "the whole-erase source PDF is byte-identical")

        // ── 10. An adopted file-owned stroke: the original leaves the annotation cache too ────────
        let adoptedURL = try copy(singleCopyURL, "adopted-source.pdf")
        let adopted = try makeState(adoptedURL)
        try await eventually("the adopted stroke's source loads", {
            !adopted.documentAnnotations.isEmpty || adopted.documentAnnotationsError != nil
        })
        require(adopted.documentAnnotationsError == nil,
                "the adopted stroke's source reads its annotations")
        guard let adoptedInk = adopted.documentAnnotations.first(where: { $0.kind == "ink" }) else {
            fatalError("FAIL: the adopted source carries ink")
        }
        guard let adoptedID = adopted.adoptDocumentAnnotation(adoptedInk.id),
              let adoptedAnnotation = adopted.annotations.first(where: { $0.id == adoptedID })
        else {
            fatalError("FAIL: the file-owned ink can be adopted")
        }
        require(adoptedAnnotation.fileIdentity == adoptedInk.id,
                "the adopted stroke carries the file's identity")
        let adoptedRecordsBeforeCut = try recordsBytes(adoptedURL)
        adopted.toggleEraserTool()
        let adoptedCanvas = makeCanvas(adopted)
        drag(adoptedCanvas, from: content(adopted, page: 0, CGPoint(x: 213.375, y: 250)),
             through: [], to: content(adopted, page: 0, CGPoint(x: 213.375, y: 390)))
        require(adopted.annotations.count == 2,
                "splitting an adopted stroke leaves two ordinary cached pieces")
        require(adopted.annotations.allSatisfy { $0.fileIdentity == nil },
                "the pieces are new ink, not edits of the PDF annotation")
        require(!adopted.annotations.contains(where: { $0.id == adoptedID }),
                "the adopted original is removed from the annotation cache")
        require(adopted.pendingFileDeletions.contains(where: { $0.identity == adoptedInk.id }),
                "removing the adopted original stages its file annotation for deletion")
        let adoptedPieces = adopted.annotations
        let adoptedRecordsAfterCut = try recordsBytes(adoptedURL)
        adopted.undo()
        require(adopted.annotations == [adoptedAnnotation],
                "undo restores the adopted annotation's identity and file link exactly")
        require(adopted.pendingFileDeletions.isEmpty,
                "undo cancels the adopted original's pending deletion")
        let adoptedRecordsAfterUndo = try recordsBytes(adoptedURL)
        require(adoptedRecordsAfterUndo == adoptedRecordsBeforeCut,
                "undoing the adopted split restores its cache byte for byte")
        adopted.redo()
        require(adopted.annotations == adoptedPieces,
                "redo re-applies the adopted split exactly")
        require(adopted.pendingFileDeletions.contains(where: { $0.identity == adoptedInk.id }),
                "redo restages the adopted original's deletion")
        let adoptedCopyURL = scratch.appendingPathComponent("adopted-split-copy.pdf")
        let savedAdoptedCopy = await adopted.saveAnnotatedCopy(to: adoptedCopyURL)
        require(savedAdoptedCopy,
                "the adopted split saves into a copy")
        let adoptedReport = adopted.lastAnnotationWriteReport
        require(adoptedReport?.deletedFileIDs == [adoptedInk.id],
                "the adopted split prunes the original file annotation from the copy")
        require(Set(adoptedReport?.writtenIDs ?? []) == Set(adoptedPieces.map(\.id.uuidString)),
                "the adopted split writes the pieces under their own names")
        let adoptedCopyBytes = try bytes(adoptedCopyURL)
        require(!contains(adoptedCopyBytes, adoptedInk.id.hasPrefix("nm:")
                    ? String(adoptedInk.id.dropFirst(3)) : adoptedInk.id),
                "the adopted copy contains no /NM for the removed original")
        for piece in adoptedPieces {
            require(contains(adoptedCopyBytes, piece.id.uuidString),
                    "the adopted copy carries the piece's own name")
        }

        // ── 11. A long, fast signature splits without a visible pause ───────────────────
        // Six hundred samples is what a quickly written signature produces. The splitter is
        // linear in the stroke's points per pointer sample and does not decimate: every point
        // that is not under the eraser is still there, plus one cut point per boundary.
        let signatureCount = 600
        var signature: [CGPoint] = []
        for index in 0..<signatureCount {
            let t = Double(index) / Double(signatureCount - 1)
            signature.append(CGPoint(
                x: 80 + 440 * t,
                y: 360 + 26 * sin(t * 9) + 5 * cos(t * 31)))
        }
        var signatureSplitter = InkStrokeSplitter(points: signature, reach: 9)
        let pureStart = DispatchTime.now().uptimeNanoseconds
        for sample in 0..<60 {
            let y0 = 220 + 4 * Double(sample)
            signatureSplitter.remove(pointerFrom: CGPoint(x: 300, y: y0),
                                     to: CGPoint(x: 300, y: y0 + 4))
        }
        let pureMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - pureStart) / 1_000_000
        let signaturePieces = signatureSplitter.survivingPaths
        let survivingPointCount = signaturePieces.reduce(0) { $0 + $1.count }
        print(String(format: "partial erase: 600-point stroke / 60 pointer samples split in %.2f ms, %d surviving points", pureMilliseconds, survivingPointCount))
        require(pureMilliseconds < 50,
                "a 600-point signature splits within 50 ms (measured \(pureMilliseconds) ms)")
        require(signaturePieces.count == 2, "the long signature splits where the pointer crossed")
        require(survivingPointCount > 500,
                "the split does not decimate: \(survivingPointCount) of 600 points survive")
        require(signaturePieces.flatMap { $0 }.count == survivingPointCount,
                "the surviving point count is the sum of the pieces")

        let performanceDocument = try copy(drawing, "performance.pdf")
        let performance = try makeState(performanceDocument)
        addStroke(performance, signature)
        performance.toggleEraserTool()
        let gestureStart = DispatchTime.now().uptimeNanoseconds
        var previous = content(performance, page: 0, CGPoint(x: 300, y: 220))
        performance.beginEraserGesture(atContentPoint: previous)
        for sample in 0..<60 {
            let point = content(performance, page: 0,
                                CGPoint(x: 300, y: 220 + 4 * Double(sample + 1)))
            performance.extendEraserGesture(fromContentPoint: previous, toContentPoint: point)
            previous = point
        }
        performance.endEraserGesture()
        let gestureMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - gestureStart) / 1_000_000
        print(String(format: "partial erase: full gesture on the 600-point stroke, including the cache write, %.2f ms", gestureMilliseconds))
        require(performance.annotations.count == 2,
                "the real gesture path also splits the long signature into two pieces")
        require(gestureMilliseconds < 250,
                "the gesture including the cache write stays under 250 ms (measured \(gestureMilliseconds) ms)")

        // ── 11b. A PDF-owned stroke with review text is refused, not orphaned ──────────
        // Splitting a file-owned stroke deletes its annotation identity. When that annotation
        // carries a comment, a popup or `/IRT` replies, deleting it would destroy somebody's
        // review thread, so the eraser must leave it whole and say why. A bare file-owned
        // stroke in the same drag may still split.
        let reviewSource = try copy(inkReview, "ink-review.pdf")
        let review = try makeState(reviewSource)
        try await eventually("the review-ink fixture's annotations load", {
            review.documentAnnotations.count >= 4 || review.documentAnnotationsError != nil
        })
        require(review.documentAnnotationsError == nil,
                "the review-ink fixture reads without error")
        guard let commented = review.documentAnnotations.first(where: {
            $0.id == "nm:review-ink-commented"
        }), let bare = review.documentAnnotations.first(where: {
            $0.id == "nm:review-ink-bare"
        }) else {
            fatalError("FAIL: the review-ink fixture carries both ink strokes")
        }
        require(commented.hasPopup, "the commented stroke reports its /Popup")
        let replyIDs = Set(review.documentAnnotations.filter {
            $0.isReply && $0.parentID == commented.id
        }.map(\.id))
        require(replyIDs == Set(["nm:review-reply-one", "nm:review-reply-two"]),
                "both /IRT replies name the commented stroke as their parent")
        let commentedContents = commented.contents ?? ""
        let firstReplyText = review.documentAnnotations
            .first(where: { $0.id == "nm:review-reply-one" })?.contents ?? ""
        let secondReplyText = review.documentAnnotations
            .first(where: { $0.id == "nm:review-reply-two" })?.contents ?? ""
        require(!commentedContents.isEmpty && !firstReplyText.isEmpty && !secondReplyText.isEmpty,
                "the fixture carries a comment and two reply bodies")
        review.toggleEraserTool()
        let reviewCanvas = makeCanvas(review)
        let commentedPoint = commented.inkPaths.first?.first(where: { $0.x == 300 })
            ?? commented.inkPaths[0][0]
        let barePoint = bare.inkPaths.first?.first(where: { $0.x == 300 })
            ?? bare.inkPaths[0][0]
        // 1) The commented stroke alone: no halo, no cut, no cache write, no undo step.
        require(review.eraserTarget(atContentPoint: content(review, page: 0, commentedPoint))
                    == nil,
                "the eraser does not promise a cut on a stroke whose thread would be orphaned")
        let refusedUndo = review.undoStack.count
        let refusedWrites = review.annotationWriteCount
        let refusedPending = review.pendingFileDeletions.count
        let refusedAnnotations = review.annotations
        drag(reviewCanvas,
             from: content(review, page: 0,
                           CGPoint(x: commentedPoint.x, y: commentedPoint.y - 30)),
             through: [], to: content(review, page: 0,
                                       CGPoint(x: commentedPoint.x, y: commentedPoint.y + 30)))
        require(review.documentAnnotations.contains(where: { $0.id == commented.id }),
                "the commented file-owned stroke is left intact")
        require(review.pendingFileDeletions.count == refusedPending,
                "a refused stroke stages no file deletion")
        require(review.annotations == refusedAnnotations,
                "a refused stroke writes no cached pieces")
        require(review.undoStack.count == refusedUndo,
                "a refused stroke adds no undo step")
        require(review.annotationWriteCount == refusedWrites,
                "a refused stroke writes nothing to the annotation cache")
        let refusal = review.eraserRefusalNotice ?? ""
        require(refusal == "This stroke belongs to the PDF and carries a comment, a popup and "
                    + "2 replies; splitting it would delete them.",
                "the refusal names the comment, the popup and the two replies (got \"\(refusal)\")")
        require(review.statusMessage == refusal,
                "the status line repeats the same refusal sentence")
        review.dismissEraserRefusal()
        require(review.eraserRefusalNotice == nil, "the refusal banner can be dismissed")

        // 2) The same drag also crosses the bare file-owned stroke, which must still split.
        let reviewUndo = review.undoStack.count
        drag(reviewCanvas,
             from: content(review, page: 0,
                           CGPoint(x: commentedPoint.x, y: commentedPoint.y - 60)),
             through: [], to: content(review, page: 0,
                                       CGPoint(x: barePoint.x, y: barePoint.y + 60)))
        require(review.documentAnnotations.contains(where: { $0.id == commented.id }),
                "the commented stroke survives a drag that also crosses bare ink")
        require(review.documentAnnotations.contains(where: { $0.id == bare.id }) == false,
                "the bare file-owned stroke is removed through the cross-reader path")
        let pendingAfterReviewDrag = review.pendingFileDeletions.map { $0.identity }
        require(pendingAfterReviewDrag == [bare.id],
                "only the bare stroke is staged for deletion")
        for replyID in replyIDs {
            require(review.documentAnnotations.contains(where: { $0.id == replyID }),
                    "reply \(replyID) still exists after the gesture")
        }
        let survivingComment = review.documentAnnotations
            .first(where: { $0.id == commented.id })?.contents
        require(survivingComment == commentedContents,
                "the commented stroke's /Contents is untouched")
        let survivingFirstReply = review.documentAnnotations
            .first(where: { $0.id == "nm:review-reply-one" })?.contents
        let survivingSecondReply = review.documentAnnotations
            .first(where: { $0.id == "nm:review-reply-two" })?.contents
        require(survivingFirstReply == firstReplyText && survivingSecondReply == secondReplyText,
                "both reply bodies are untouched")
        require(review.undoStack.count == reviewUndo + 1,
                "the part of the drag that did apply is one undo step")
        require(review.annotations.count == 2,
                "the bare stroke splits into two cached pieces")
        let reviewPieces = review.annotations
        require(reviewPieces.allSatisfy { $0.fileIdentity == nil },
                "the pieces are new ink, not edits of the bare annotation")
        let reviewNotice = review.eraserRefusalNotice ?? ""
        require(reviewNotice.contains("comment") && reviewNotice.contains("popup")
                    && reviewNotice.contains("2 replies"),
                "the refusal survives until dismissed and still names what would be lost")
        // Undo the applied part; the refused stroke was never touched, so it stays as it was.
        review.undo()
        require(review.documentAnnotations.contains(where: { $0.id == bare.id }),
                "undo restores the bare file-owned stroke")
        require(review.pendingFileDeletions.isEmpty,
                "undo cancels the bare stroke's pending deletion")
        let survivingIDs = Set(review.documentAnnotations.map { $0.id })
        require(survivingIDs.contains(commented.id) && replyIDs.isSubset(of: survivingIDs),
                "undo leaves the commented stroke and its replies intact")
        review.redo()
        require(review.annotations == reviewPieces,
                "redo re-applies the bare stroke's split pieces")
        let pendingAfterRedo = review.pendingFileDeletions.map { $0.identity }
        require(pendingAfterRedo == [bare.id],
                "redo restages only the bare stroke's deletion")

        // 3) Saving the copy keeps the whole thread and prunes only the bare stroke.
        let reviewCopyURL = scratch.appendingPathComponent("ink-review-split-copy.pdf")
        let reviewSaved = await review.saveAnnotatedCopy(to: reviewCopyURL)
        require(reviewSaved, "the mixed refusal/split copy saves")
        let reviewReport = review.lastAnnotationWriteReport
        require(reviewReport?.fullRewrite == true,
                "deleting the bare file-owned stroke prunes the copy")
        require(reviewReport?.deletedFileIDs == [bare.id],
                "only the bare stroke is named as deleted")
        require(Set(reviewReport?.writtenIDs ?? []) == Set(reviewPieces.map(\.id.uuidString)),
                "the saved copy writes the bare stroke's pieces")
        let reviewCopyBytes = try bytes(reviewCopyURL)
        require(contains(reviewCopyBytes, "review-ink-commented"),
                "the saved copy keeps the commented stroke's /NM")
        require(contains(reviewCopyBytes, commentedContents),
                "the saved copy keeps the commented stroke's /Contents")
        for replyID in replyIDs {
            require(contains(reviewCopyBytes, String(replyID.dropFirst(3))),
                    "the saved copy keeps reply \(replyID)")
        }
        require(contains(reviewCopyBytes, firstReplyText)
                    && contains(reviewCopyBytes, secondReplyText),
                "the saved copy keeps both reply bodies")
        require(!contains(reviewCopyBytes, "review-ink-bare"),
                "the saved copy has no /NM for the pruned bare stroke")
        for piece in reviewPieces {
            require(contains(reviewCopyBytes, piece.id.uuidString),
                    "the saved copy carries the bare stroke's piece \(piece.id)")
        }
        let reviewReopened = try makeState(reviewCopyURL)
        try await eventually("the mixed review copy reopens its annotations", {
            reviewReopened.documentAnnotations.count >= 3
                || reviewReopened.documentAnnotationsError != nil
        })
        require(reviewReopened.documentAnnotationsError == nil,
                "the mixed review copy's annotations read without error")
        let reopenedReviewIDs = Set(reviewReopened.documentAnnotations.map { $0.id })
        let reviewThreadIDs = Set([
            "nm:review-ink-commented", "nm:review-reply-one", "nm:review-reply-two",
        ])
        require(reviewThreadIDs.isSubset(of: reopenedReviewIDs),
                "reopening the copy still finds the comment thread")
        require(!reopenedReviewIDs.contains("nm:review-ink-bare"),
                "reopening the copy finds no bare stroke")
        let reopenedComment = reviewReopened.documentAnnotations
            .first(where: { $0.id == "nm:review-ink-commented" })
        require(reopenedComment?.hasPopup == true,
                "the reopened copy still links the popup")

        // ── 11c. The same rule holds after the stroke was adopted into the annotation cache ──────
        // Adoption moves the file-owned annotation into the editable model but it remains an
        // edit of the PDF's annotation by identity. Its popup is no longer in
        // `documentAnnotations`, so the guard remembers it from the file's annotation list.
        let adoptedReviewURL = try copy(inkReview, "ink-review-adopted.pdf")
        let adoptedReview = try makeState(adoptedReviewURL)
        try await eventually("the adopted review stroke's annotations load", {
            adoptedReview.documentAnnotations.count >= 4
                || adoptedReview.documentAnnotationsError != nil
        })
        require(adoptedReview.documentAnnotationsError == nil,
                "the adopted review stroke's annotations read")
        guard let adoptedCommented = adoptedReview.documentAnnotations
            .first(where: { $0.id == "nm:review-ink-commented" }),
              let adoptedCommentedID = adoptedReview.adoptDocumentAnnotation(adoptedCommented.id),
              let adoptedEntry = adoptedReview.annotations.first(where: {
                  $0.id == adoptedCommentedID
              })
        else {
            fatalError("FAIL: the commented file-owned stroke can be adopted")
        }
        require(adoptedEntry.fileIdentity == adoptedCommented.id,
                "the adopted stroke edits the file's own annotation by identity")
        require(!(adoptedEntry.note.isEmpty), "the adopted stroke keeps the file's comment")
        let adoptedPoint = adoptedEntry.inkPaths.first?.first(where: { $0.x == 300 })
            ?? adoptedEntry.inkPaths[0][0]
        require(adoptedReview.eraserTarget(atContentPoint: content(adoptedReview, page: 0,
                                                                  adoptedPoint)) == nil,
                "the eraser refuses the adopted commented stroke before it is pressed")
        let adoptedEntries = adoptedReview.annotations
        let adoptedPending = adoptedReview.pendingFileDeletions
        let adoptedUndo = adoptedReview.undoStack.count
        let adoptedWrites = adoptedReview.annotationWriteCount
        adoptedReview.toggleEraserTool()
        let adoptedReviewCanvas = makeCanvas(adoptedReview)
        drag(adoptedReviewCanvas,
             from: content(adoptedReview, page: 0,
                           CGPoint(x: adoptedPoint.x, y: adoptedPoint.y - 30)),
             through: [], to: content(adoptedReview, page: 0,
                                       CGPoint(x: adoptedPoint.x, y: adoptedPoint.y + 30)))
        require(adoptedReview.annotations == adoptedEntries,
                "an adopted commented stroke is not split")
        require(adoptedReview.pendingFileDeletions == adoptedPending,
                "an adopted commented stroke stages no deletion")
        require(adoptedReview.undoStack.count == adoptedUndo,
                "an adopted commented stroke adds no undo step")
        require(adoptedReview.annotationWriteCount == adoptedWrites,
                "an adopted commented stroke writes nothing to the annotation cache")
        let adoptedRefusal = adoptedReview.eraserRefusalNotice ?? ""
        require(adoptedRefusal.contains("comment") && adoptedRefusal.contains("popup")
                    && adoptedRefusal.contains("2 replies"),
                "the adopted refusal still names the comment, popup and replies")

        // ── 12. Signed documents keep the existing read-only-in-place policy ─────────────
        // reader ink can still be cut and a copy exported; replacing the signed original is
        // refused by the same gate as every other in-place write.
        let signedDocument = try copy(signed, "signed-split.pdf")
        let signedState = try makeState(signedDocument)
        require(signedState.isReadOnlyDocument, "the signed fixture is read-only in place")
        addStroke(signedState, [CGPoint(x: 120, y: 260), CGPoint(x: 480, y: 260)])
        signedState.toggleEraserTool()
        let signedCanvas = makeCanvas(signedState)
        drag(signedCanvas, from: content(signedState, page: 0, CGPoint(x: 300, y: 230)),
             through: [], to: content(signedState, page: 0, CGPoint(x: 300, y: 290)))
        require(signedState.annotations.count == 2,
                "a signed document's reader ink can still be split")
        require(!signedState.canReplaceOriginalWithAnnotations,
                "the split cannot replace the signed original in place")
        require(signedState.canSaveAnnotationsToPDF,
                "the split can still be exported to a copy")
        let signedCopyURL = scratch.appendingPathComponent("signed-split-copy.pdf")
        let savedSignedCopy = await signedState.saveAnnotatedCopy(to: signedCopyURL)
        require(savedSignedCopy,
                "the signed document's split exports to a copy")
        let signedCopyBytes = try bytes(signedCopyURL)
        for piece in signedState.annotations {
            require(contains(signedCopyBytes, piece.id.uuidString),
                    "the signed document's copy carries each piece")
        }
    }
}
