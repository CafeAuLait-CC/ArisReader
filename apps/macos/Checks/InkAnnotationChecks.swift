import AppKit
import LyraReaderKit
import CoreGraphics
import Foundation
import PDFKit

extension ReaderChecks {
    /// T3.4: ink and shapes — creation, page-space persistence, hit testing, movement, undo,
    /// write-back, and reading a file another producer wrote.
    ///
    /// Every check here runs through the real `AppState` and the real engine on scratch copies
    /// of committed fixtures. The zoom check uses the same `CanvasGeometry` functions the canvas
    /// uses to convert a pointer to content points, so "drawn at 100% and 300%" is the same
    /// arithmetic the event path performs, not a second implementation that happens to agree.
    @MainActor static func inkAnnotationChecks(
        drawing: URL,
        annotated: URL,
        strokes: URL
    ) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-reader-ink-\(UUID())")
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
        func json(_ document: URL) throws -> String {
            String(decoding: try Data(contentsOf: records(for: document)), as: UTF8.self)
        }
        func placement(_ state: AppState, page: Int) -> PagePlacement {
            guard let frame = state.canvasPageFrames.first(where: { $0.index == page }) else {
                fatalError("FAIL: page \(page + 1) has no canvas frame")
            }
            return frame
        }
        func contentPoint(_ state: AppState, page: Int, point: CGPoint) -> CGPoint {
            let frame = placement(state, page: page)
            return CGPoint(x: frame.leftPt + point.x, y: frame.topPt + point.y)
        }
        func pageBounds(_ annotation: AppState.Annotation) -> CGRect {
            annotation.geometryBounds ?? .zero
        }
        func requireClose(_ left: CGPoint, _ right: CGPoint, _ message: String,
                          tolerance: CGFloat = 0.01) {
            require(abs(left.x - right.x) <= tolerance && abs(left.y - right.y) <= tolerance,
                    "\(message) (got \(left), expected \(right))")
        }

        // ── 1. Stroke parameters survive a save/reopen ──────────────────────────────────
        let document = try copy(drawing, "ink-parameters.pdf")
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        state.newTab(url: document)
        require(state.document != nil, "the drawing fixture opens")
        let red = AnnotationColor(red: 200, green: 30, blue: 40, alpha: 255)
        let stroke = [
            CGPoint(x: 90, y: 140), CGPoint(x: 130, y: 180), CGPoint(x: 170, y: 150),
            CGPoint(x: 220, y: 210), CGPoint(x: 260, y: 160),
        ]
        require(state.addInkAnnotation(page: 0, points: stroke, color: red, strokeWidth: 2.5),
                "a pen stroke is created")
        guard let savedInk = state.annotations.last else {
            require(false, "the stroke is in the model")
            return
        }
        require(savedInk.kind == .ink && savedInk.strokeWidth == 2.5,
                "the stroke keeps its kind and a constant 2.5 pt width")
        require(savedInk.inkPaths.count == 1 && savedInk.inkPaths[0].count == stroke.count,
                "every sampled point is stored (\(savedInk.inkPaths.first?.count ?? 0))")
        let recordsText = try json(document)
        require(recordsText.contains("\"version\" : 1"),
                "a geometry entry is versioned in the annotation cache")
        require(recordsText.contains("\"paths\""),
                "the stroke's points are stored under the documented key")
        require(recordsText.contains("\"strokeWidth\""),
                "the stroke width is part of the entry")

        let reopened = AppState(engine: try RustEngine())
        reopened.setViewportSize(CGSize(width: 700, height: 500))
        reopened.newTab(url: document)
        guard let restored = reopened.annotations.first(where: { $0.id == savedInk.id }) else {
            require(false, "the stroke reloads")
            return
        }
        require(restored.kind == .ink && restored.strokeWidth == 2.5,
                "the reloaded stroke keeps its width")
        require(restored.inkPaths == savedInk.inkPaths,
                "the reloaded stroke keeps every point exactly")
        require(restored.color == red, "the reloaded stroke keeps its colour")

        // ── 2. A mark drawn at 100% and at 300% lands on the same page coordinates ─────
        // The page point the reader aims at is the same. What changes is the view-space point
        // that lands on it, and CanvasGeometry is the one mapping between the two.
        let aim = CGPoint(x: 300, y: 300)
        let frame = placement(state, page: 0)
        for zoom in [CGFloat(1), CGFloat(3)] {
            let contentY = aim.y + frame.topPt
            let viewY = CanvasGeometry.viewY(contentY: contentY, scrollYPt: state.scrollYPt,
                                             zoom: zoom)
            let backY = CanvasGeometry.contentY(viewY: viewY, scrollYPt: state.scrollYPt,
                                                zoom: zoom)
            let content = CGPoint(x: frame.leftPt + aim.x, y: backY)
            guard let converted = state.pagePoint(atContentPoint: content) else {
                require(false, "zoom \(zoom * 100)% maps the view point to a page")
                return
            }
            require(converted.page == 0, "zoom \(zoom * 100)% maps to page one")
            requireClose(converted.point, aim,
                         "zoom \(zoom * 100)% lands on the same page coordinate")
        }
        let atOne = state.addInkAnnotation(page: 0, points: [aim, CGPoint(x: 340, y: 340)],
                                           color: red, strokeWidth: 2)
        state.zoomPercent = 300
        let atThree = state.addInkAnnotation(page: 0, points: [aim, CGPoint(x: 340, y: 340)],
                                             color: red, strokeWidth: 2)
        require(atOne && atThree, "the same gesture draws at 100% and 300%")
        let inks = state.annotations.filter { $0.kind == .ink }
        require(inks.count >= 3, "the two zoom strokes are separate annotations")
        let zoomInk = inks.suffix(2)
        require(zoomInk[zoomInk.startIndex].inkPaths == zoomInk[zoomInk.startIndex + 1].inkPaths,
                "the stored page coordinates do not depend on the zoom the mark was drawn at")
        state.zoomPercent = 100

        // ── 3. All four shapes, and their annotation cache round trip ───────────────────────────
        let shapes: [(AppState.Annotation.Kind, CGPoint, CGPoint, CGPoint, CGFloat)] = [
            (.square, CGPoint(x: 90, y: 300), CGPoint(x: 220, y: 380),
             CGPoint(x: 155, y: 300), 2),
            (.circle, CGPoint(x: 260, y: 300), CGPoint(x: 380, y: 380),
             CGPoint(x: 380, y: 340), 1.5),
            (.line, CGPoint(x: 90, y: 430), CGPoint(x: 260, y: 480),
             CGPoint(x: 175, y: 455), 2),
            (.arrow, CGPoint(x: 300, y: 430), CGPoint(x: 470, y: 480),
             CGPoint(x: 385, y: 455), 2.5),
        ]
        var shapeIDs: [AppState.Annotation.Kind: UUID] = [:]
        for (kind, start, end, hit, width) in shapes {
            require(state.addShapeAnnotation(kind: kind, page: 0, start: start, end: end,
                                             color: red, strokeWidth: width),
                    "\(kind.rawValue) is created")
            guard let shape = state.annotations.last else {
                require(false, "\(kind.rawValue) is in the model")
                return
            }
            shapeIDs[kind] = shape.id
            require(shape.kind == kind && shape.strokeWidth == width,
                    "\(kind.rawValue) keeps its kind and width")
            let content = contentPoint(state, page: 0, point: hit)
            guard let found = state.geometryAnnotationHit(atContentPoint: content) else {
                require(false, "a click on \(kind.rawValue) finds it")
                return
            }
            require(found.id == shape.id, "the click finds the \(kind.rawValue) it landed on")
        }
        let shapeRecords = try json(document)
        require(shapeRecords.contains("\"kind\" : \"square\"")
                    && shapeRecords.contains("\"kind\" : \"circle\"")
                    && shapeRecords.contains("\"kind\" : \"line\"")
                    && shapeRecords.contains("\"kind\" : \"arrow\""),
                "all four shape kinds are in the annotation cache")
        let reopenedShapes = AppState(engine: try RustEngine())
        reopenedShapes.setViewportSize(CGSize(width: 700, height: 500))
        reopenedShapes.newTab(url: document)
        for (kind, _, _, _, width) in shapes {
            guard let id = shapeIDs[kind],
                  let reloaded = reopenedShapes.annotations.first(where: { $0.id == id }) else {
                require(false, "the \(kind.rawValue) reloads")
                return
            }
            require(reloaded.kind == kind && reloaded.strokeWidth == width,
                    "the reloaded \(kind.rawValue) keeps its width")
            require(reloaded.geometryBounds != nil,
                    "the reloaded \(kind.rawValue) has geometry")
        }

        // ── 4. A thin stroke is hit within tolerance and not outside it ────────────────
        let thin = AppState.Annotation(
            id: UUID(), kind: .ink, page: 0, start: 0, end: 0,
            color: red, note: "", createdAt: Date(),
            inkPaths: [[CGPoint(x: 100, y: 600), CGPoint(x: 400, y: 600)]],
            strokeWidth: 1.5
        )
        require(thin.hasValidGeometry, "the thin stroke is valid geometry")
        let near = CGPoint(x: 250, y: 603.5)
        let far = CGPoint(x: 250, y: 612)
        let thinMark = CanvasAnnotationMark(
            id: thin.id.uuidString, page: 0, kind: .ink, inkPaths: thin.inkPaths,
            color: thin.color, strokeWidth: thin.strokeWidth, isSelected: false, isEditable: true)
        require(AnnotationGeometry.hitTest(thinMark, at: near,
                                           tolerance: AnnotationGeometry.hitTolerancePt),
                "a point 3.5 pt from a 1.5 pt stroke is inside the 4 pt allowance")
        require(!AnnotationGeometry.hitTest(thinMark, at: far,
                                            tolerance: AnnotationGeometry.hitTolerancePt),
                "a point 12 pt from the same stroke is outside it")

        // A click beside the stroke still selects text: the hit test must not claim a box.
        let probeText = try await state.engine.textPage(0)
        let textRect = probeText.selectionRects(in: 0...min(20, probeText.chars.count - 1)).first
        guard let textRect else {
            require(false, "the drawing fixture has text to select behind the mark")
            return
        }
        let textPointPage = CGPoint(x: textRect.midX, y: textRect.midY)
        let textContent = contentPoint(state, page: 0, point: textPointPage)
        print("INFO ink text point \(textContent) frame \(placement(state, page: 0)) rect \(textRect)")
        require(state.geometryAnnotationHit(atContentPoint: textContent) == nil,
                "the mark's hit test does not reach text behind it")
        try await eventually("a click off the stroke starts a text selection", {
            state.beginSelection(at: textContent)
            return state.selection != nil
        })
        state.clearSelection()

        // ── 5. Select, move, delete and undo/redo cover every new kind ─────────────────
        // The pen stroke first. A thin freehand path is the hardest case: there is no box to
        // click, so this exercises the same distance-to-segment hit test the tolerance check did.
        if let inkID = state.annotations.first(where: { $0.kind == .ink })?.id,
           let inkIndex = state.annotations.firstIndex(where: { $0.id == inkID }) {
            let before = state.annotations[inkIndex]
            let hitPage = CGPoint(x: 130, y: 180)
            let hitContent = contentPoint(state, page: 0, point: hitPage)
            state.beginSelection(at: hitContent)
            require(state.selectedAnnotationID == inkID, "clicking the pen stroke selects it")
            let delta = CGPoint(x: 10, y: 6)
            state.extendSelection(to: CGPoint(x: hitContent.x + delta.x,
                                              y: hitContent.y + delta.y))
            state.endPointerInteraction(at: CGPoint(x: hitContent.x + delta.x,
                                                    y: hitContent.y + delta.y),
                                        wasClick: false)
            if let moved = state.annotations.first(where: { $0.id == inkID }) {
                requireClose(CGPoint(x: pageBounds(moved).minX, y: pageBounds(moved).minY),
                             CGPoint(x: pageBounds(before).minX + delta.x,
                                     y: pageBounds(before).minY + delta.y),
                             "ink moved by the drag")
            } else {
                require(false, "ink is still in the model after the move")
            }
            state.undo()
            if let undone = state.annotations.first(where: { $0.id == inkID }) {
                requireClose(CGPoint(x: pageBounds(undone).minX, y: pageBounds(undone).minY),
                             CGPoint(x: pageBounds(before).minX, y: pageBounds(before).minY),
                             "undo restores ink's position")
            }
            state.redo()
            state.selectAnnotation(inkID)
            require(state.deleteSelectedAnnotation(), "ink can be deleted")
            require(!state.annotations.contains(where: { $0.id == inkID }), "the deleted ink is gone")
            state.undo()
            require(state.annotations.contains(where: { $0.id == inkID }), "deleting ink is undoable")
        }

        for (kind, start, end, hit, _) in shapes {
            guard let id = shapeIDs[kind],
                  let index = state.annotations.firstIndex(where: { $0.id == id }) else { continue }
            let before = state.annotations[index]
            let hitContent = contentPoint(state, page: 0, point: hit)
            state.beginSelection(at: hitContent)
            require(state.selectedAnnotationID == id,
                    "clicking \(kind.rawValue) selects it")
            let delta = CGPoint(x: 12, y: 8)
            state.extendSelection(to: CGPoint(x: hitContent.x + delta.x,
                                              y: hitContent.y + delta.y))
            state.endPointerInteraction(at: CGPoint(x: hitContent.x + delta.x,
                                                    y: hitContent.y + delta.y),
                                        wasClick: false)
            guard let moved = state.annotations.first(where: { $0.id == id }) else {
                require(false, "\(kind.rawValue) is still in the model after the move")
                continue
            }
            requireClose(CGPoint(x: pageBounds(moved).minX, y: pageBounds(moved).minY),
                         CGPoint(x: pageBounds(before).minX + delta.x,
                                 y: pageBounds(before).minY + delta.y),
                         "\(kind.rawValue) moved by the drag")
            let writesAfterMove = state.annotationWriteCount
            state.undo()
            guard let undone = state.annotations.first(where: { $0.id == id }) else {
                require(false, "\(kind.rawValue) survives undo")
                continue
            }
            requireClose(CGPoint(x: pageBounds(undone).minX, y: pageBounds(undone).minY),
                         CGPoint(x: pageBounds(before).minX, y: pageBounds(before).minY),
                         "undo restores \(kind.rawValue)'s position")
            require(state.annotationWriteCount == writesAfterMove + 1,
                    "undo wrote the restored position to the annotation cache")
            state.redo()
            guard let redone = state.annotations.first(where: { $0.id == id }) else { continue }
            requireClose(CGPoint(x: pageBounds(redone).minX, y: pageBounds(redone).minY),
                         CGPoint(x: pageBounds(moved).minX, y: pageBounds(moved).minY),
                         "redo reapplies \(kind.rawValue)'s move")
            state.selectAnnotation(id)
            require(state.deleteSelectedAnnotation(), "\(kind.rawValue) can be deleted")
            require(!state.annotations.contains(where: { $0.id == id }),
                    "the deleted \(kind.rawValue) is gone")
            state.undo()
            require(state.annotations.contains(where: { $0.id == id }),
                    "deleting \(kind.rawValue) is undoable")
        }

        // ── 6. Write ink and a square into a PDF, then read them back ──────────────────
        let annotatedCopy = try copy(annotated, "written.pdf")
        let writer = AppState(engine: try RustEngine())
        writer.setViewportSize(CGSize(width: 700, height: 500))
        writer.newTab(url: annotatedCopy)
        try await eventually("the pre-existing annotations are readable", {
            writer.documentAnnotations.count == 7 || writer.documentAnnotationsError != nil
        })
        require(writer.documentAnnotationsError == nil,
                "the annotated fixture's seven annotations are readable")
        let inkColor = AnnotationColor(red: 220, green: 20, blue: 30, alpha: 255)
        let blue = AnnotationColor(red: 20, green: 80, blue: 220, alpha: 255)
        let inkBox = CGRect(x: 80, y: 500, width: 140, height: 70)
        let squareBox = CGRect(x: 300, y: 500, width: 150, height: 60)
        require(writer.addInkAnnotation(
                    page: 0,
                    points: [CGPoint(x: 90, y: 550), CGPoint(x: 130, y: 510),
                             CGPoint(x: 180, y: 555), CGPoint(x: 215, y: 515)],
                    color: inkColor, strokeWidth: 3),
                "a written ink stroke is created")
        require(writer.addShapeAnnotation(kind: .square, page: 0,
                                          start: CGPoint(x: squareBox.minX, y: squareBox.minY),
                                          end: CGPoint(x: squareBox.maxX, y: squareBox.maxY),
                                          color: blue, strokeWidth: 2),
                "a written square is created")
        let originalBytes = try Data(contentsOf: annotatedCopy)
        let copyURL = scratch.appendingPathComponent("annotated-ink-copy.pdf")
        let wrote = await writer.saveAnnotatedCopy(to: copyURL)
        if !wrote {
            FileHandle.standardError.write(Data(
                "lyra-reader-ink: write failed: \(writer.lastError ?? "no error")\n".utf8))
        }
        require(wrote, "the ink and square are written into a copy")
        let writtenBytes = try Data(contentsOf: copyURL)
        require(writtenBytes.count > originalBytes.count && writtenBytes.prefix(originalBytes.count) == originalBytes,
                "the written file keeps the original bytes as its prefix")
        let sourceAfter = try Data(contentsOf: annotatedCopy)
        require(sourceAfter == originalBytes, "the source PDF is untouched by a copy save")
        if let report = writer.lastAnnotationWriteReport {
            require(report.writtenIDs.count == 2, "the report names the ink and the square")
            require(report.preexistingAnnotationCount == 7,
                    "the seven pre-existing annotations were verified unchanged")
            require(report.sourceBytesPreserved, "an append-only save was verified")
        } else {
            require(false, "the write publishes a report")
        }

        // The write carries the two dictionary facts this task added: `/BS` for the stroke
        // width and `/AP` for viewers that do not synthesise from geometry. The Rust verifier
        // checks them object by object; this is the shell-level "they are in the bytes".
        require(writtenBytes.range(of: Data("/BS".utf8)) != nil,
                "the written file carries /BS")
        require(writtenBytes.range(of: Data("/AP".utf8)) != nil,
                "the written file carries an appearance stream reference")
        require(writtenBytes.range(of: Data("/InkList".utf8)) != nil,
                "the written file carries /InkList")
        // /L and /LE are covered by the Rust write-back test, which writes a line as well.
        let reader = AppState(engine: try RustEngine())
        reader.setViewportSize(CGSize(width: 700, height: 500))
        reader.newTab(url: copyURL)
        try await eventually("the written annotations are read back from the PDF", {
            reader.documentAnnotations.count == 9 || reader.documentAnnotationsError != nil
        })
        require(reader.documentAnnotationsError == nil,
                "reading the written copy does not fail")
        require(reader.documentAnnotations.count == 9,
                "seven pre-existing plus the two written annotations, no duplicates "
                    + "(\(reader.documentAnnotations.count))")
        let ownKinds = reader.documentAnnotations.map(\.kind)
        require(ownKinds.filter { $0 == "ink" }.count == 1,
                "the written ink opens as ink")
        require(ownKinds.filter { $0 == "square" }.count == 1,
                "the written square opens as a square")
        if let readInk = reader.documentAnnotations.first(where: { $0.kind == "ink" }) {
            require(readInk.inkPaths.first?.count == 4, "the ink's four points survive")
            require(abs((readInk.borderWidthPt ?? 0) - 3) < 0.01,
                    "the ink's 3 pt /BS width survives")
            require(readInk.color?.red == 220 && readInk.color?.green == 20,
                    "the ink's stroke colour survives")
        } else {
            require(false, "the written ink is found")
        }
        if let readSquare = reader.documentAnnotations.first(where: { $0.kind == "square" }) {
            require(abs(readSquare.widthPt - (squareBox.width + 2)) < 1.5,
                    "the square's outer /Rect covers the stroke")
            require(abs((readSquare.borderWidthPt ?? 0) - 2) < 0.01,
                    "the square's /BS width survives")
        } else {
            require(false, "the written square is found")
        }

        // PDFKit is the engine Preview uses. It renders the saved file from the appearance
        // stream this writer puts on the annotation (or, for a viewer that ignores geometry,
        // from the stream alone); either way the pixels must be where the mark is.
        let redPixels = try pdfKitPixels(url: copyURL, viewSpaceRect: inkBox.insetBy(dx: -4, dy: -4),
                                          scale: 2, predicate: { red, green, blue in
                                              red > 150 && green < 110 && blue < 110
                                          })
        let bluePixels = try pdfKitPixels(url: copyURL, viewSpaceRect: squareBox.insetBy(dx: -4, dy: -4),
                                           scale: 2, predicate: { red, green, blue in
                                               blue > 150 && red < 120 && green < 150
                                           })
        let emptyPixels = try pdfKitPixels(url: copyURL,
                                            viewSpaceRect: CGRect(x: 470, y: 600, width: 80, height: 80),
                                            scale: 2, predicate: { red, green, blue in
                                                red > 150 && green < 110 && blue < 110
                                            })
        require(redPixels > 40, "PDFKit draws the ink stroke (\(redPixels) red px)")
        require(bluePixels > 40, "PDFKit draws the square (\(bluePixels) blue px)")
        require(emptyPixels == 0, "nothing is drawn away from the marks (\(emptyPixels) px)")
        FileHandle.standardError.write(Data(
            "lyra-reader-ink: PDFKit pixels ink=\(redPixels) square=\(bluePixels) empty=\(emptyPixels)\n".utf8))

        // ── 7. Read a fixture written by another producer ─────────────────────────────
        let external = AppState(engine: try RustEngine())
        external.setViewportSize(CGSize(width: 700, height: 500))
        external.newTab(url: strokes)
        try await eventually("the external ink fixture is read", {
            external.documentAnnotations.count == 5 || external.documentAnnotationsError != nil
        })
        require(external.documentAnnotationsError == nil,
                "reading another writer's ink and shapes does not fail")
        let externalKinds = external.documentAnnotations.map(\.kind)
        // PDFium's annotation enumeration is by object position, which its parser may reorder;
        // the contract is "one of each kind", not the order a writer happened to lay them out.
        require(externalKinds.sorted() == ["arrow", "circle", "ink", "line", "square"],
                "the external kinds arrive exactly once each, got \(externalKinds)")
        require(external.documentAnnotations.allSatisfy { $0.drawing == .geometry },
                "every external stroked annotation is classified as drawable geometry")
        let externalInk = external.documentAnnotations[0]
        require(externalInk.inkPaths.count == 1 && externalInk.inkPaths[0].count == 4,
                "the external /InkList is read as one four-point stroke")
        // Page space (90, 650) on an 842 pt page is view space y = 192.
        require(abs(externalInk.inkPaths[0][0].x - 90) < 0.001
                    && abs(externalInk.inkPaths[0][0].y - 192) < 0.001,
                "the external ink point is Y-flipped exactly once")
        require(abs((externalInk.borderWidthPt ?? 0) - 3) < 0.01,
                "the external /BS /W 3 is read")
        require(external.documentAnnotations[3].lineArrow,
                "the external /LE [/None /ClosedArrow] is an arrow")
        require(!external.documentAnnotations[4].lineArrow,
                "an external /LE [/None /None] is a plain line")
        require(external.canvasAnnotationMarks.count == 5,
                "all five external marks reach the canvas overlay")
        require(external.canvasAnnotationMarks.allSatisfy { $0.isEditable },
                "a PDF's own ink is drawn and offered as editable through the one policy")
        require(!external.canvasPages.contains { page in
            page.placement.index == PlacementIndex.documentAnnotation(0, box: 0)
        }, "a geometry annotation is not also drawn as a quad")

        // ── 8. A future geometry entry is preserved, not misread ──────────────────────
        let futureDocument = try copy(drawing, "future-ink.pdf")
        let futureID = UUID()
        let futureEntry = """
{
  "id" : "\(futureID.uuidString)",
  "kind" : "ink",
  "page" : 0,
  "paths" : [ [ { "x" : 1, "y" : 2 }, { "x" : 3, "y" : 4 } ] ],
  "strokeWidth" : 2,
  "createdAt" : 804000000,
  "version" : 2
}
"""
        try Data("[\n\(futureEntry)\n]".utf8).write(to: records(for: futureDocument))
        let future = AppState(engine: try RustEngine())
        future.setViewportSize(CGSize(width: 700, height: 500))
        future.newTab(url: futureDocument)
        require(future.annotations.isEmpty, "a geometry schema this build does not know is not decoded")
        require(future.preservedAnnotationEntryCount == 1,
                "the future entry is preserved verbatim instead of rejected")
        require(future.addShapeAnnotation(kind: .line, page: 0,
                                          start: CGPoint(x: 10, y: 10),
                                          end: CGPoint(x: 100, y: 100),
                                          color: red, strokeWidth: 2),
                "an older build can still edit the annotation cache around the future entry")
        let futureRecords = try json(futureDocument)
        require(futureRecords.contains("\"version\" : 2"),
                "the future entry survives a save byte-for-byte")
    }

    /// Counts pixels matching `predicate` inside a page's top-left view-space rectangle.
    ///
    /// The page is drawn with PDFKit at `scale`; row 0 of the bitmap is view-space y 0, the same
    /// orientation the canvas uses. This helper is deliberately about pixels, not about which
    /// half of the PDFKit pipeline drew them: if a viewer synthesises from `/L` or `/InkList`,
    /// or uses the `/AP` this writer now supplies, the stroke is there either way.
    @MainActor
    static func pdfKitPixels(
        url: URL,
        viewSpaceRect: CGRect,
        scale: CGFloat,
        predicate: (Int, Int, Int) -> Bool
    ) throws -> Int {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else {
            throw NSError(domain: "LyraReader", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "PDFKit could not open the saved copy",
            ])
        }
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(ceil(bounds.width * scale))
        let height = Int(ceil(bounds.height * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "LyraReader", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "could not create a PDFKit bitmap",
            ])
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        guard let data = context.data else { return 0 }
        let rowBytes = context.bytesPerRow
        let pixels = data.bindMemory(to: UInt8.self, capacity: rowBytes * height)
        let minX = max(Int(viewSpaceRect.minX * scale), 0)
        let maxX = min(Int(viewSpaceRect.maxX * scale), width - 1)
        let minY = max(Int(viewSpaceRect.minY * scale), 0)
        let maxY = min(Int(viewSpaceRect.maxY * scale), height - 1)
        guard minX < maxX, minY < maxY else { return 0 }
        var count = 0
        for y in minY...maxY {
            for x in minX...maxX {
                let offset = y * rowBytes + x * 4
                if predicate(Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2])) {
                    count += 1
                }
            }
        }
        return count
    }
}
