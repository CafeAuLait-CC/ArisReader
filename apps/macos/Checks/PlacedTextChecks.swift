import AppKit
import ArisReaderKit
import CoreGraphics
import Foundation

extension ReaderChecks {
    /// Placeable sticky notes and text boxes: creation, page-space persistence, selection, move,
    /// resize, edit, delete, undo, write-back and read-back in both directions.
    ///
    /// Everything runs through the real `AppState` and the real engine. The zoom check uses the
    /// same content↔view arithmetic the canvas uses, and the PDF checks reopen the written file
    /// with Lyra and with PDFKit, so "the note came back" is about the file, not about memory.
    @MainActor static func placedTextChecks(drawing: URL, annotated: URL, external: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("aris-placed-text-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        func copy(_ source: URL, _ name: String) throws -> URL {
            let destination = scratch.appendingPathComponent(name)
            try fileManager.copyItem(at: source, to: destination)
            try? fileManager.removeItem(at: sidecar(for: destination))
            return destination
        }
        func sidecar(for document: URL) -> URL {
            document.appendingPathExtension("aris-annotations.json")
        }
        func sidecarText(_ document: URL) throws -> String {
            String(decoding: try Data(contentsOf: sidecar(for: document)), as: UTF8.self)
        }
        func placement(_ state: AppState, _ page: Int) -> PagePlacement {
            guard let frame = state.canvasPageFrames.first(where: { $0.index == page }) else {
                fatalError("FAIL: page \(page + 1) has no canvas frame")
            }
            return frame
        }
        func contentPoint(_ state: AppState, page: Int, point: CGPoint) -> CGPoint {
            let frame = placement(state, page)
            return CGPoint(x: frame.leftPt + point.x, y: frame.topPt + point.y)
        }
        func close(_ left: CGPoint, _ right: CGPoint, _ message: String,
                   tolerance: CGFloat = 0.01) {
            require(abs(left.x - right.x) <= tolerance && abs(left.y - right.y) <= tolerance,
                    "\(message) (got \(left), expected \(right))")
        }

        // ── 0. The tools classify as gestures, not as strokes ─────────────────────────────
        require(AnnotationTool.note.placesNote && !AnnotationTool.note.draws,
                "the sticky-note tool is a click, not a stroke")
        require(AnnotationTool.textBox.placesTextBox && !AnnotationTool.textBox.draws,
                "the text-box tool is a drag, not a freehand stroke")
        require(AnnotationTool.select.kind == nil && AnnotationTool.pen.kind == .ink,
                "the existing tools keep their kinds")

        let document = try copy(drawing, "placed-text.pdf")
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        state.newTab(url: document)
        require(state.document != nil, "the drawing fixture opens for placed text")

        let aim = CGPoint(x: 120, y: 320)
        require(state.placeStickyNote(page: 0, at: aim), "a sticky note is placed at a page point")
        guard let noteID = state.editingAnnotationID,
              let note = state.annotations.first(where: { $0.id == noteID }) else {
            require(false, "the new note is in the model and open for editing")
            return
        }
        require(note.kind == .stickyNote && note.note.isEmpty,
                "the new note starts empty and is a stickyNote")
        close(CGPoint(x: note.shapeRect?.midX ?? -1, y: note.shapeRect?.midY ?? -1), aim,
              "the icon is centred on the page point that was clicked")
        require(state.noteWriteWindowIsOpen == false,
                "placing a note writes the sidecar once before typing")

        let firstText = "Remember the figure on page 2."
        state.updateEditingText(firstText)
        require(state.commitTextEditing(), "typing a note commits it")
        require(state.annotations.first(where: { $0.id == noteID })?.note == firstText,
                "the note keeps the typed text in memory")
        let noteSidecar = try sidecarText(document)
        require(noteSidecar.contains("\"kind\" : \"stickyNote\""),
                "the sidecar stores the sticky-note kind")
        require(noteSidecar.contains("\"version\" : \(AppState.Annotation.placedTextVersion)"),
                "a placed note is versioned in the sidecar")
        require(noteSidecar.contains("\"rect\""), "the note's page-space box is stored")
        require(!noteSidecar.contains("\"start\""),
                "a placed note has no character range, so no start key is written")

        // ── 1. A placed note survives a save/reopen, and the icon carries its text ────────
        let reopened = AppState(engine: try RustEngine())
        reopened.setViewportSize(CGSize(width: 700, height: 500))
        reopened.newTab(url: document)
        guard let reloadedNote = reopened.annotations.first(where: { $0.id == noteID }) else {
            require(false, "the sticky note reloads from the sidecar")
            return
        }
        require(reloadedNote.kind == .stickyNote && reloadedNote.note == firstText,
                "the reloaded note keeps its kind and every word")
        require(reloadedNote.geometryBounds == note.shapeRect,
                "the reloaded note keeps its page-space box")
        require(reopened.canvasAnnotationMarks.contains(where: {
            $0.id == noteID.uuidString && $0.kind == .stickyNote && $0.isEditable
        }), "the note reaches the canvas overlay as an editable mark")
        require(reopened.canvasPages.contains(where: { PlacementIndex.isOwnNote($0.placement.index) }),
                "the note icon is handed to the canvas as its own glyph")
        require(reopened.documentAnnotations.isEmpty,
                "a sidecar note is not also read as an annotation from the PDF")
        require(reopened.openDocumentNoteID == nil,
                "opening the document does not pop the read-only note paper over our own note")

        // ── 2. Zoom does not move the note: the stored point is page space ───────────────
        let zoomed = AppState(engine: try RustEngine())
        zoomed.setViewportSize(CGSize(width: 700, height: 500))
        zoomed.newTab(url: document)
        zoomed.zoomPercent = 300
        let frame = placement(zoomed, 0)
        let contentAtZoom = CGPoint(
            x: frame.leftPt + aim.x,
            y: CanvasGeometry.contentY(
                viewY: CanvasGeometry.viewY(contentY: frame.topPt + aim.y,
                                            scrollYPt: zoomed.scrollYPt,
                                            zoom: zoomed.zoomFactor),
                scrollYPt: zoomed.scrollYPt,
                zoom: zoomed.zoomFactor)
        )
        require(zoomed.pagePoint(atContentPoint: contentAtZoom)?.point == aim,
                "the note's page point is the same at 300% as at 100%")
        require(zoomed.placeStickyNote(page: 0, at: aim), "a second note at the same page point")
        if let second = zoomed.annotations.last {
            close(CGPoint(x: second.shapeRect?.midX ?? -1, y: second.shapeRect?.midY ?? -1), aim,
                  "placing at 300% stores the same page point")
            require(second.shapeRect == note.shapeRect,
                    "two notes placed at the same page point have the same page-space box")
        }
        zoomed.cancelTextEditing()
        zoomed.zoomPercent = 100

        // ── 3. Select, drag, delete and undo the note ────────────────────────────────────
        let noteHit = contentPoint(state, page: 0,
                                   point: CGPoint(x: note.shapeRect?.midX ?? 0,
                                                  y: note.shapeRect?.midY ?? 0))
        state.beginSelection(at: noteHit)
        require(state.selectedAnnotationID == noteID, "clicking the icon selects the note")
        let beforeMove = state.annotations.first { $0.id == noteID }
        let writesBeforeMove = state.annotationWriteCount
        let delta = CGPoint(x: 18, y: 12)
        state.extendSelection(to: CGPoint(x: noteHit.x + delta.x, y: noteHit.y + delta.y))
        state.endPointerInteraction(at: CGPoint(x: noteHit.x + delta.x, y: noteHit.y + delta.y),
                                    wasClick: false)
        require(state.annotationWriteCount == writesBeforeMove + 1,
                "dragging a note writes the sidecar once on mouse-up, not per event")
        if let moved = state.annotations.first(where: { $0.id == noteID }) {
            close(CGPoint(x: moved.shapeRect?.minX ?? -1, y: moved.shapeRect?.minY ?? -1),
                  CGPoint(x: (beforeMove?.shapeRect?.minX ?? 0) + delta.x,
                          y: (beforeMove?.shapeRect?.minY ?? 0) + delta.y),
                  "the note moved by the drag")
        } else {
            require(false, "the moved note is still in the model")
        }
        state.undo()
        require(state.annotations.first(where: { $0.id == noteID })?.shapeRect == beforeMove?.shapeRect,
                "undo restores the note's position")
        state.redo()
        state.selectAnnotation(noteID)
        require(state.deleteSelectedAnnotation(), "the note can be deleted")
        require(!state.annotations.contains(where: { $0.id == noteID }), "the deleted note is gone")
        state.undo()
        require(state.annotations.contains(where: { $0.id == noteID }), "deleting a note is undoable")

        // Clicking a note icon opens the editable paper, not the PDF's read-only note overlay.
        state.beginEditingAnnotation(noteID)
        require(state.editingAnnotationID == noteID && state.openDocumentNoteID == nil,
                "the note opens in the editable editor, not the read-only paper")
        state.updateEditingText("Edited note text.")
        state.commitTextEditing()
        state.undo()
        require(state.annotations.first(where: { $0.id == noteID })?.note == firstText,
                "editing a note's text is an undoable step")

        // ── 4. A text box: drag a box, type into it, move, resize and edit it ─────────────
        let textPage = try await state.engine.textPage(0)
        guard let bodyLine = textPage.selectionRects(in: 0...min(24, textPage.chars.count - 1)).first
        else {
            require(false, "the fixture has a text line for the box to cover")
            return
        }
        var box = CGRect(x: 120, y: 430, width: 230, height: 70)
        require(state.addTextBox(page: 0, rect: box), "a text box is created")
        guard let boxID = state.editingAnnotationID,
              let textBox = state.annotations.first(where: { $0.id == boxID }) else {
            require(false, "the new text box is in the model and open for editing")
            return
        }
        require(textBox.shapeRect == box.standardized, "the text box keeps the dragged rect")
        require(textBox.fontSize == AppState.Annotation.defaultTextBoxFontSize,
                "the text box starts at the default readable size")
        let boxText = "A placed text box.\nIt wraps in the box."
        state.updateEditingText(boxText)
        state.commitTextEditing()
        box = state.annotations.first(where: { $0.id == boxID })!.shapeRect!
        require(box.width <= 230 && box.height <= 70 && state.selectedAnnotationID == nil,
                "finishing a text box fits its contents and removes its editing outline")
        let textSidecar = try sidecarText(document)
        require(textSidecar.contains("\"kind\" : \"textBox\""),
                "the sidecar stores the text-box kind")
        require(textSidecar.contains("\"fontSize\""),
                "the text box's font size is part of the entry")
        require(textSidecar.contains("\"version\" : \(AppState.Annotation.placedTextVersion)"),
                "the text box is versioned like the note")

        let boxReader = AppState(engine: try RustEngine())
        boxReader.setViewportSize(CGSize(width: 700, height: 500))
        boxReader.newTab(url: document)
        guard let reloadedBox = boxReader.annotations.first(where: { $0.id == boxID }) else {
            require(false, "the text box reloads")
            return
        }
        require(reloadedBox.shapeRect == box.standardized,
                "the reloaded text box keeps its rect")
        require(reloadedBox.fontSize == AppState.Annotation.defaultTextBoxFontSize,
                "the reloaded text box keeps its font size")
        require(reloadedBox.note == boxText, "the reloaded text box keeps its text")

        // A plain click inside an unselected box selects the box: the box is a mark the reader
        // can click once. A drag that starts there still selects the text underneath.
        let textHit = contentPoint(state, page: 0,
                                   point: CGPoint(x: bodyLine.minX + 10, y: bodyLine.midY))
        var coverRect = CGRect(x: bodyLine.minX - 4, y: bodyLine.minY - 4,
                               width: max(bodyLine.width + 8, 120), height: 60)
        require(state.addTextBox(page: 0, rect: coverRect), "a text box is placed over body text")
        guard let coverID = state.editingAnnotationID else {
            require(false, "the covering box opens for editing")
            return
        }
        state.updateEditingText("Covering text.")
        state.commitTextEditing()
        coverRect = state.annotations.first(where: { $0.id == coverID })!.shapeRect!
        state.clearSelection()
        state.clearAnnotationSelection()
        state.beginSelection(at: textHit)
        state.endPointerInteraction(at: textHit, wasClick: true)
        require(state.selectedAnnotationID == coverID,
                "a plain click inside an unselected text box selects it")
        state.clearAnnotationSelection()
        state.clearSelection()
        // A drag inside the unselected box is a text selection, even though the press landed on
        // the box. The page's text layer arrives asynchronously, so retry the real gesture until
        // it can resolve a character instead of sleeping.
        let dragEnd = CGPoint(x: textHit.x + 40, y: textHit.y)
        try await eventually("a drag inside an unselected text box still selects the text under it", {
            state.clearSelection()
            state.clearAnnotationSelection()
            state.beginSelection(at: textHit)
            state.extendSelection(to: dragEnd)
            state.endPointerInteraction(at: dragEnd, wasClick: false)
            return state.selection != nil && state.selectedAnnotationID == nil
        })
        state.clearSelection()

        // Its frame is the way in: click the edge to select, then resize by a handle.
        let edgeHit = contentPoint(state, page: 0,
                                   point: CGPoint(x: coverRect.minX + 0.5,
                                                  y: coverRect.midY))
        state.beginSelection(at: edgeHit)
        state.endPointerInteraction(at: edgeHit, wasClick: true)
        require(state.selectedAnnotationID == coverID,
                "clicking a text box's frame selects it")
        let writesBeforeResize = state.annotationWriteCount
        let beforeResize = state.annotations.first { $0.id == coverID }
        let corner = contentPoint(state, page: 0,
                                  point: CGPoint(x: coverRect.maxX, y: coverRect.maxY))
        state.beginSelection(at: corner)
        state.extendSelection(to: CGPoint(x: corner.x + 40, y: corner.y + 25))
        state.endPointerInteraction(at: CGPoint(x: corner.x + 40, y: corner.y + 25),
                                    wasClick: false)
        require(state.annotationWriteCount == writesBeforeResize + 1,
                "resizing a text box writes the sidecar once on mouse-up")
        guard let resized = state.annotations.first(where: { $0.id == coverID }) else {
            require(false, "the resized text box survives")
            return
        }
        close(CGPoint(x: resized.shapeRect?.maxX ?? 0, y: resized.shapeRect?.maxY ?? 0),
              CGPoint(x: (beforeResize?.shapeRect?.maxX ?? 0) + 40,
                      y: (beforeResize?.shapeRect?.maxY ?? 0) + 25),
              "the text box resized by its bottom-right handle")
        state.undo()
        require(state.annotations.first(where: { $0.id == coverID })?.shapeRect ==
                    beforeResize?.shapeRect, "undo restores the text box's rect")

        // Moving the selected box is by its inside; double-click opens the editor.
        state.beginSelection(at: contentPoint(state, page: 0,
                                              point: CGPoint(x: coverRect.midX,
                                                             y: coverRect.midY)))
        require(state.selectedAnnotationID == coverID,
                "a selected text box is draggable by its interior")
        let inside = contentPoint(state, page: 0,
                                  point: CGPoint(x: coverRect.midX, y: coverRect.midY))
        state.extendSelection(to: CGPoint(x: inside.x + 15, y: inside.y + 9))
        state.endPointerInteraction(at: CGPoint(x: inside.x + 15, y: inside.y + 9),
                                    wasClick: false)
        require(state.annotations.first(where: { $0.id == coverID })?.shapeRect?.minX ==
                    (beforeResize?.shapeRect?.minX ?? 0) + 15,
                "the selected text box moved by its interior")
        state.undo()
        require(state.beginEditingTextBox(atContentPoint: inside),
                "a double-click on a text box opens its editor")
        state.updateEditingText("Edited inside the box.")
        state.commitTextEditing()
        state.undo()
        require(state.annotations.first(where: { $0.id == coverID })?.note == "Covering text.",
                "editing the text box is undoable")

        state.selectAnnotation(coverID)
        require(state.deleteSelectedAnnotation(), "the text box can be deleted")
        state.undo()
        require(state.annotations.contains(where: { $0.id == coverID }),
                "deleting a text box is undoable")

        // ── 5. Write both kinds into a PDF and read them back as themselves ──────────────
        let annotatedSource = try copy(annotated, "annotated-source.pdf")
        let writer = AppState(engine: try RustEngine())
        writer.setViewportSize(CGSize(width: 700, height: 500))
        writer.newTab(url: annotatedSource)
        try await eventually("the annotated fixture's seven annotations are readable", {
            writer.documentAnnotations.count == 7 || writer.documentAnnotationsError != nil
        })
        require(writer.documentAnnotationsError == nil,
                "the write-back fixture's annotations are readable")
        let writeNotePoint = CGPoint(x: 520, y: 700)
        require(writer.placeStickyNote(page: 0, at: writeNotePoint), "a note is placed for writing")
        let writeNoteID = writer.editingAnnotationID
        writer.updateEditingText("A note written by Lyra.")
        writer.commitTextEditing()
        let writeBox = CGRect(x: 310, y: 620, width: 220, height: 55)
        require(writer.addTextBox(page: 0, rect: writeBox), "a text box is created for writing")
        let writeBoxID = writer.editingAnnotationID
        writer.updateEditingText("Free text written by Lyra.")
        writer.commitTextEditing()
        guard let writeNoteID, let writeBoxID else {
            require(false, "both written annotations have identities")
            return
        }
        let originalBytes = try Data(contentsOf: annotatedSource)
        let copyURL = scratch.appendingPathComponent("written-notes.pdf")
        let wrote = await writer.saveAnnotatedCopy(to: copyURL)
        if !wrote { FileHandle.standardError.write(Data(
            "aris-placed-text: write failed: \(writer.lastError ?? "no error")\n".utf8)) }
        require(wrote, "the note and text box are written into a copy")
        let writtenBytes = try Data(contentsOf: copyURL)
        require(writtenBytes.count > originalBytes.count &&
                    writtenBytes.prefix(originalBytes.count) == originalBytes,
                "the written file keeps the original bytes as its prefix")
        let sourceAfter = try Data(contentsOf: annotatedSource)
        require(sourceAfter == originalBytes,
                "a copy save leaves the source PDF untouched")
        do {
            guard let report = writer.lastAnnotationWriteReport else {
                require(false, "the write publishes a report")
                return
            }
            require(report.writtenIDs.count == 2, "the report names both written annotations")
            require(report.preexistingAnnotationCount == 7,
                    "the seven pre-existing annotations were verified unchanged")
            require(report.sourceBytesPreserved, "the append-only save was verified")
        }
        for needle in [
            "/Text".data(using: .utf8)!, "/FreeText".data(using: .utf8)!,
            "/Name /Comment".data(using: .utf8)!, "/DA".data(using: .utf8)!,
            "/Q".data(using: .utf8)!, "/AP".data(using: .utf8)!,
            "/NM".data(using: .utf8)!,
        ] {
            require(writtenBytes.range(of: needle) != nil,
                    "the written file carries \(String(decoding: needle, as: UTF8.self))")
        }
        require(writtenBytes.range(of: Data(writeNoteID.uuidString.utf8)) != nil,
                "the sticky note's stable /NM is its sidecar identity")
        require(writtenBytes.range(of: Data(writeBoxID.uuidString.utf8)) != nil,
                "the text box's stable /NM is its sidecar identity")

        let reader = AppState(engine: try RustEngine())
        reader.setViewportSize(CGSize(width: 700, height: 500))
        reader.newTab(url: copyURL)
        try await eventually("the written annotations are read back from the PDF", {
            reader.documentAnnotations.count == 9 || reader.documentAnnotationsError != nil
        })
        require(reader.documentAnnotationsError == nil,
                "reading the written copy does not fail")
        require(reader.documentAnnotations.count == 9,
                "seven pre-existing plus the note and text box, exactly once each")
        guard let readNote = reader.documentAnnotations.first(where: {
            $0.id == "nm:\(writeNoteID.uuidString)"
        }) else {
            require(false, "the written note comes back under its /NM")
            return
        }
        require(readNote.kind == "text" && readNote.drawing == .noteIcon,
                "the written sticky note reads as a /Text note icon")
        require(readNote.contents == "A note written by Lyra.", "the note's text survives")
        require(readNote.author == AppState.annotationAuthor, "the note's author survives")
        require(readNote.color?.red == 0xE8 && readNote.color?.green == 0xBC
                    && readNote.color?.blue == 0x55,
                "the note's colour survives exactly")
        guard let readBox = reader.documentAnnotations.first(where: {
            $0.id == "nm:\(writeBoxID.uuidString)"
        }) else {
            require(false, "the written text box comes back under its /NM")
            return
        }
        require(readBox.kind == "freeText" && readBox.drawing == .freeText,
                "the written text box reads as a /FreeText annotation")
        require(readBox.contents == "Free text written by Lyra.", "the text box's text survives")
        require(abs((readBox.fontSizePt ?? 0) - AppState.Annotation.defaultTextBoxFontSize) < 0.01,
                "the text box's /DA font size survives")
        require(readBox.alignment == "left", "the text box's /Q is read back")
        require(readBox.color != nil, "the text box's colour survives")
        require(reader.canvasPages.contains(where: { PlacementIndex.isDocumentNote($0.placement.index) }),
                "the reopened note and text box are drawn on the page")

        // PDFKit is the engine Preview uses. A viewer that honours /AP must show the text even
        // though it does not synthesise a free-text appearance.
        let textRect = writeBox.insetBy(dx: -2, dy: -2)
        let beforePixels = try pdfKitPixels(url: annotatedSource, viewSpaceRect: textRect,
                                            scale: 2, predicate: { red, green, blue in
                                                red < 110 && green < 110 && blue < 110
                                            })
        let afterPixels = try pdfKitPixels(url: copyURL, viewSpaceRect: textRect,
                                           scale: 2, predicate: { red, green, blue in
                                               red < 110 && green < 110 && blue < 110
                                           })
        require(afterPixels > beforePixels + 40,
                "PDFKit draws the written text box from its appearance stream "
                    + "(\(beforePixels) → \(afterPixels) dark px)")
        let noteRect = CGRect(x: writeNotePoint.x - 16, y: writeNotePoint.y - 16,
                              width: 32, height: 32)
        let notePixels = try pdfKitPixels(url: copyURL, viewSpaceRect: noteRect, scale: 2,
                                          predicate: { red, green, blue in
                                              // Any non-white pixel: the icon's outline and fold.
                                              !(red > 245 && green > 245 && blue > 245)
                                          })
        require(notePixels > 40,
                "PDFKit draws the written sticky note icon (\(notePixels) non-white px)")

        // ── 6. A replace comes back as the file's own annotation, never twice ───────────
        let replaceDocument = try copy(drawing, "replace-placed.pdf")
        let replacer = AppState(engine: try RustEngine())
        replacer.setViewportSize(CGSize(width: 700, height: 500))
        replacer.newTab(url: replaceDocument)
        require(replacer.placeStickyNote(page: 0, at: CGPoint(x: 200, y: 200)),
                "a note is placed before the replace")
        let replacedNoteID = replacer.editingAnnotationID
        replacer.updateEditingText("Survives the replace.")
        replacer.commitTextEditing()
        require(replacer.addTextBox(page: 0, rect: CGRect(x: 100, y: 500, width: 220, height: 60)),
                "a text box is created before the replace")
        let replacedBoxID = replacer.editingAnnotationID
        replacer.updateEditingText("A replaced text box.")
        replacer.commitTextEditing()
        let replaced = await replacer.replaceOriginalWithSavedAnnotations()
        require(replaced, "the placed annotations are written into the original")
        require(replacer.annotations.isEmpty,
                "the saved entries are removed from the sidecar, so they cannot appear twice")
        try await eventually("the replaced file's annotations are reloaded", {
            replacer.documentAnnotations.count == 2 || replacer.documentAnnotationsError != nil
        })
        require(replacer.documentAnnotationsError == nil,
                "reading the replaced file does not fail")
        require(replacer.documentAnnotations.count == 2,
                "the replaced file carries exactly the note and the text box")
        if let replacedNoteID, let replacedBoxID {
            require(replacer.documentAnnotations.contains(where: {
                $0.id == "nm:\(replacedNoteID.uuidString)" && $0.kind == "text"
            }), "the replaced note comes back as the file's /Text note")
            require(replacer.documentAnnotations.contains(where: {
                $0.id == "nm:\(replacedBoxID.uuidString)" && $0.kind == "freeText"
            }), "the replaced text box comes back as the file's /FreeText annotation")
        }
        require(replacer.openDocumentNoteID == nil,
                "the replaced note is not opened as a read-only paper behind its icon")
        require(replacer.canvasAnnotationMarks.isEmpty,
                "a PDF's own placed text is not offered as an editable sidecar mark")

        // ── 7. Another producer's notes and free text are read, drawn and clearly not editable
        let externalState = AppState(engine: try RustEngine())
        externalState.setViewportSize(CGSize(width: 700, height: 500))
        externalState.newTab(url: external)
        try await eventually("the external notes fixture is read", {
            externalState.documentAnnotations.count == 7 || externalState.documentAnnotationsError != nil
        })
        require(externalState.documentAnnotationsError == nil,
                "reading another writer's notes does not fail")
        let externalKinds = externalState.documentAnnotations.map(\.drawing)
        require(externalKinds.filter { $0 == .noteIcon }.count == 2,
                "the external /Text notes are classified as note icons")
        require(externalKinds.filter { $0 == .freeText }.count == 2,
                "the external /FreeText annotations with text are classified as free text")
        require(externalState.documentAnnotations.filter(\.isNote).count == 6,
                "the external /Text and /FreeText annotations are listed as notes")
        let externalNote = externalState.documentAnnotations.first { $0.drawing == .noteIcon }
        if let externalNote, let box = externalNote.boxes.first {
            let point = contentPoint(externalState, page: externalNote.page,
                                     point: CGPoint(x: box.xPt + box.widthPt / 2,
                                                    y: box.yPt + box.heightPt / 2))
            externalState.beginSelection(at: point)
            require(externalState.selectedAnnotationID == nil,
                    "another writer's note is not offered as an editable sidecar annotation")
            require(externalState.openDocumentNote(at: point),
                    "clicking another writer's note opens the read-only note paper")
            require(externalState.openDocumentNoteID != nil &&
                        externalState.editingAnnotationID == nil,
                    "the external note is read-only and clearly not an editable placed note")
            externalState.closeDocumentNote()
        }

        // ── 8. A newer placed-text entry is preserved, not half-read ─────────────────────
        let futureDocument = try copy(drawing, "future-placed.pdf")
        let futureID = UUID()
        let futureEntry = """
{
  "id" : "\(futureID.uuidString)",
  "kind" : "stickyNote",
  "page" : 0,
  "note" : "from a newer Lyra",
  "rect" : { "x" : 20, "y" : 30, "width" : 22, "height" : 22 },
  "fontSize" : 0,
  "createdAt" : 804000000,
  "version" : 2
}
"""
        try Data("[\n\(futureEntry)\n]".utf8).write(to: sidecar(for: futureDocument))
        let future = AppState(engine: try RustEngine())
        future.setViewportSize(CGSize(width: 700, height: 500))
        future.newTab(url: futureDocument)
        require(future.annotations.isEmpty,
                "a placed-text schema this build does not know is not decoded")
        require(future.preservedAnnotationEntryCount == 1,
                "the future placed-text entry is preserved verbatim")
        require(future.placeStickyNote(page: 0, at: CGPoint(x: 80, y: 80)),
                "an older build can still add its own note around the future entry")
        future.cancelTextEditing()
        let futureSidecar = try sidecarText(futureDocument)
        require(futureSidecar.contains("\"version\" : 2"),
                "the future entry survives a save byte-for-byte")

        // An unknown field on a version this build does know is also preserved, not dropped.
        let unknownFieldDocument = try copy(drawing, "unknown-field-placed.pdf")
        let unknownFieldEntry = """
{
  "id" : "\(UUID().uuidString)",
  "kind" : "textBox",
  "page" : 0,
  "note" : "has a field from the future",
  "rect" : { "x" : 10, "y" : 10, "width" : 120, "height" : 40 },
  "fontSize" : 14,
  "createdAt" : 804000000,
  "version" : 1,
  "futureField" : true
}
"""
        try Data("[\n\(unknownFieldEntry)\n]".utf8).write(to: sidecar(for: unknownFieldDocument))
        let unknownField = AppState(engine: try RustEngine())
        unknownField.setViewportSize(CGSize(width: 700, height: 500))
        unknownField.newTab(url: unknownFieldDocument)
        require(unknownField.annotations.isEmpty && unknownField.preservedAnnotationEntryCount == 1,
                "a placed-text entry with an unknown field is preserved, not half-read")
        require(unknownField.addTextBox(page: 0, rect: CGRect(x: 200, y: 200, width: 100, height: 50)),
                "this build can still add a text box beside an unknown-field entry")
        unknownField.updateEditingText("mine")
        unknownField.commitTextEditing()
        let unknownFieldAfter = try sidecarText(unknownFieldDocument)
        require(unknownFieldAfter.contains("\"futureField\" : true"),
                "the unknown field survives an ordinary save")
    }
}

