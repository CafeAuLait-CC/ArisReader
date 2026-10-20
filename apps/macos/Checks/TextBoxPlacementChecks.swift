import AppKit
import LyraReaderKit
import SwiftUI

extension ReaderChecks {
    /// The text box the reader places today: double-click creates a one-line box, the caret
    /// starts at its top-left, and the box grows with the text as it is typed.
    ///
    /// The checks run through the real `MetalCanvasView` event path (a double-click is two
    /// press/release pairs exactly as AppKit delivers them) and the real hosted
    /// `ReaderWindow`, so the caret and the field's geometry are measured on the surface the
    /// reader sees, not on a second layout implementation.
    @MainActor static func textBoxPlacementChecks(drawing: URL, annotated: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-reader-textbox-placement-\(UUID())")
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
        func contentPoint(_ state: AppState, page: Int, _ point: CGPoint) -> CGPoint {
            let frame = placement(state, page: page)
            return CGPoint(x: frame.leftPt + point.x, y: frame.topPt + point.y)
        }
        /// A page-local point in the canvas's own view coordinates (top-left origin). Using the
        /// same mapping the canvas itself uses keeps the event path honest at any scroll offset
        /// or zoom, rather than assuming the page starts at the view's origin.
        func viewPoint(_ state: AppState, page: Int, _ point: CGPoint,
                       canvasHeight: CGFloat) -> CGPoint {
            guard let anchor = state.anchorViewRect(
                page: page, region: CGRect(origin: point, size: CGSize(width: 1, height: 1)))
            else { fatalError("FAIL: page \(page + 1) has no view anchor") }
            return CGPoint(x: anchor.midX, y: canvasHeight - anchor.midY)
        }
        func close(_ left: CGFloat, _ right: CGFloat, _ message: String,
                   tolerance: CGFloat = 0.6) {
            require(abs(left - right) <= tolerance,
                    "\(message) (got \(left), expected \(right))")
        }
        let viewport = CGSize(width: 900, height: 700)
        func makeState(_ url: URL) throws -> AppState {
            let state = AppState(engine: try RustEngine())
            state.setViewportSize(viewport)
            state.newTab(url: url)
            require(state.document != nil, "\(url.lastPathComponent) opens")
            return state
        }
        func findCanvas(in view: NSView) -> MetalCanvasView? {
            if let canvas = view as? MetalCanvasView { return canvas }
            return view.subviews.lazy.compactMap { findCanvas(in: $0) }.first
        }
        func findEditor(in view: NSView) -> NSTextView? {
            if let editor = view as? NSTextView,
               editor.accessibilityLabel() == "Text box content" { return editor }
            return view.subviews.lazy.compactMap { findEditor(in: $0) }.first
        }
        /// Waits for SwiftUI to tear the previous editor down. Without this, a check that opens a
        /// second box immediately can still find the old text view and type into a detached one.
        @MainActor func waitForNoEditor(_ host: NSView) async throws {
            try await eventually("the previous text box editor is gone", {
                host.layoutSubtreeIfNeeded()
                return findEditor(in: host) == nil
            })
        }
        func key(_ code: UInt16, _ characters: String,
                 modifiers: NSEvent.ModifierFlags = [], windowNumber: Int) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }

        // ── 1. The hosted canvas: a drag is inert, a double-click places a one-line box ──
        //
        // The window is hosted first, so the canvas has reported its real viewport and centred
        // the page before any event is built. The event coordinates then use the same
        // content↔view mapping the canvas uses (`anchorViewRect`), not an assumption that the
        // page starts at the view's top-left.
        _ = NSApplication.shared
        let document = try copy(drawing, "textbox-placement.pdf")
        let state = try makeState(document)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ReaderWindow(
            state: state,
            opener: DocumentOpenCoordinator(state: state),
            previewPanels: ReferencePreviewPanelController()))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        try await eventually("the hosted reader shows its Metal canvas", {
            host.layoutSubtreeIfNeeded()
            return findCanvas(in: host)?.bounds.width ?? 0 > 100
        })
        guard let hostCanvas = findCanvas(in: host) else {
            require(false, "the hosted reader has a canvas")
            return
        }
        try await eventually("the canvas has laid out and drawn its first frame", {
            hostCanvas.submittedFrameCount > 0
        })
        state.annotationTool = .textBox
        try await eventually("the toolbar's text-box tool reaches the canvas", {
            hostCanvas.annotationTool == .textBox
        })

        /// Page-local point → the hosted canvas's event point in window coordinates.
        func windowPoint(_ point: CGPoint) -> CGPoint {
            guard let anchor = state.anchorViewRect(
                page: 0, region: CGRect(origin: point, size: CGSize(width: 1, height: 1)))
            else { fatalError("FAIL: page one has no view anchor") }
            let view = CGPoint(x: anchor.midX, y: hostCanvas.bounds.height - anchor.midY)
            return hostCanvas.convert(view, to: nil)
        }
        func send(_ type: NSEvent.EventType, at windowPoint: CGPoint, clickCount: Int) {
            let event = NSEvent.mouseEvent(
                with: type, location: windowPoint, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: clickCount, pressure: 1)!
            switch type {
            case .leftMouseDown: hostCanvas.mouseDown(with: event)
            case .leftMouseDragged: hostCanvas.mouseDragged(with: event)
            case .leftMouseUp: hostCanvas.mouseUp(with: event)
            default: break
            }
        }
        func doubleClick(at windowPoint: CGPoint) {
            for clickCount in [1, 2] {
                send(.leftMouseDown, at: windowPoint, clickCount: clickCount)
                send(.leftMouseUp, at: windowPoint, clickCount: clickCount)
            }
        }

        let aim = CGPoint(x: 150, y: 300)
        let start = windowPoint(aim)
        let dragEnd = windowPoint(CGPoint(x: aim.x + 130, y: aim.y + 70))
        send(.leftMouseDown, at: start, clickCount: 1)
        send(.leftMouseDragged, at: dragEnd, clickCount: 1)
        send(.leftMouseUp, at: dragEnd, clickCount: 1)
        require(state.annotations.isEmpty && state.editingAnnotationID == nil,
                "dragging with the text-box tool armed creates neither a rectangle nor a box")

        doubleClick(at: start)
        guard let boxID = state.editingAnnotationID,
              let created = state.annotations.first(where: { $0.id == boxID }),
              let creationBox = created.shapeRect else {
            require(false, "a double-click creates a text box and opens its editor")
            return
        }
        let expectedSize = TextBoxLayout.creationSize(
            fontSize: AppState.Annotation.defaultTextBoxFontSize)
        close(creationBox.minX, aim.x, "the box's top-left is the click's x")
        close(creationBox.minY, aim.y, "the box's top-left is the click's y")
        close(creationBox.width, expectedSize.width, "the new box is about three characters wide")
        close(creationBox.height, expectedSize.height,
              "the new box is exactly one line plus padding high")
        require(creationBox.width > 16 && creationBox.height > 16,
                "the double-click box is a real, hit-testable rectangle")
        require(state.annotationTool == .select,
                "placing a box returns to selection, so a page click can finish it")
        require(created.note.isEmpty && created.fontSize == AppState.Annotation.defaultTextBoxFontSize,
                "the new box starts empty at the default font size")

        let font = AnnotationTextFont.font(size: AppState.Annotation.defaultTextBoxFontSize)
        let padding = AnnotationTextFont.padding(
            size: AppState.Annotation.defaultTextBoxFontSize) * 2
        let wideCharacter = ("M" as NSString).size(withAttributes: [.font: font, .kern: 0]).width
        let textArea = creationBox.width - padding
        require(textArea >= 2 * wideCharacter - 0.01,
                "the new box is at least two wide characters wide")
        require(textArea <= 3 * wideCharacter + 0.01,
                "the new box is no wider than three wide characters")
        let lineHeight = TextBoxLayout.lineHeight(
            fontSize: AppState.Annotation.defaultTextBoxFontSize)
        close(creationBox.height, ceil(lineHeight + padding),
              "the height is one line box plus padding")

        // ── 2. The hosted overlay: caret at the top-left, growth while typing ────────────
        try await eventually("the hosted reader shows the text box editor", {
            host.layoutSubtreeIfNeeded()
            return findEditor(in: host) != nil
        })
        guard let field = findEditor(in: host) else {
            require(false, "the hosted reader has the text box editor")
            return
        }
        // The overlay frame and its padding both track the live calibrated zoom. Read it through
        // a function rather than capturing it once: a screen-calibration report can arrive while
        // this check is running, and the check must follow the same factor the overlay uses.
        func editorPadding() -> CGFloat {
            AnnotationTextFont.padding(
                size: AppState.Annotation.defaultTextBoxFontSize) * state.zoomFactor
        }
        guard let anchor = state.editingAnnotationAnchor else {
            require(false, "the editing box has a view-space anchor")
            return
        }
        // The overlay's frame is the box's view-space anchor, already scaled by the calibrated
        // zoom, and the padding is scaled by the same factor. Compare in view points.
        require(abs(field.bounds.height - (anchor.height - 2 * editorPadding())) <= 2,
                "the transparent editor fills the box instead of hugging one line")
        require(abs(field.bounds.width - (anchor.width - 2 * editorPadding())) <= 2,
                "the editor fills the box's width")
        try await eventually("the text box editor takes keyboard focus", {
            field.window?.firstResponder === field
        })

        // The reported bug: the caret used to sit at the bottom-left until the first keystroke.
        // Both the layout origin and the field's place inside the box are asserted, so a text
        // view that is merely top-aligned inside itself cannot pass while floating low.
        guard let layoutManager = field.layoutManager,
              let textContainer = field.textContainer else {
            require(false, "the text box editor has a layout manager")
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let emptyUsed = layoutManager.usedRect(for: textContainer)
        require(abs(emptyUsed.minX) <= 0.5 && abs(emptyUsed.minY) <= 0.5,
                "the insertion point starts at the editor's top-left")
        require(field.selectedRange() == NSRange(location: 0, length: 0),
                "the caret is at the start of the empty box")
        let canvasRect = host.convert(hostCanvas.bounds, from: hostCanvas)
        let fieldRect = host.convert(field.bounds, from: field)
        guard let currentAnchor = state.editingAnnotationAnchor else {
            require(false, "the editing box has a live view-space anchor")
            return
        }
        require(abs(fieldRect.minY - (canvasRect.minY + currentAnchor.minY + editorPadding())) <= 3,
                "the editor's top edge is the box's top edge plus padding")
        require(abs(fieldRect.minX - (canvasRect.minX + currentAnchor.minX + editorPadding())) <= 3,
                "the editor's left edge is the box's left edge plus padding")

        // Typing reaches `AppState` through the real text view delegate and the box grows.
        let longLine = "A line of typed text long enough that the box has to grow wider."
        field.insertText(longLine, replacementRange: NSRange(location: 0, length: 0))
        try await eventually("typing updates the text box model", {
            state.editingAnnotation?.note == longLine
        })
        guard let grownOnce = state.editingAnnotation?.shapeRect else {
            require(false, "the typed box has a rectangle")
            return
        }
        require(grownOnce.width > creationBox.width + 20,
                "typing a long line widens the box")
        let measuredLine = (longLine as NSString).size(withAttributes: [.font: font, .kern: 0]).width
        close(grownOnce.width, ceil(measuredLine + padding + 1),
              "the width is the longest line plus the box padding")
        try await eventually("the editor grows with the box", {
            host.layoutSubtreeIfNeeded()
            guard let current = findEditor(in: host),
                  let box = state.editingAnnotation?.shapeRect else { return false }
            return abs(current.bounds.width
                        - (box.width * state.zoomFactor - 2 * editorPadding())) <= 2
        })
        guard let grownField = findEditor(in: host),
              let grownLayout = grownField.layoutManager,
              let grownContainer = grownField.textContainer else {
            require(false, "the grown editor still has a layout manager")
            return
        }
        grownLayout.ensureLayout(for: grownContainer)
        let longUsed = grownLayout.usedRect(for: grownContainer)
        require(longUsed.width <= grownField.bounds.width + 0.5,
                "the whole long line is visible, not clipped horizontally")

        // Return is a newline, not Done: every line adds one line box of height.
        grownField.insertNewline(nil)
        grownField.insertText("Second line", replacementRange: grownField.selectedRange())
        grownField.insertNewline(nil)
        grownField.insertText("Third line", replacementRange: grownField.selectedRange())
        let threeLines = longLine + "\nSecond line\nThird line"
        try await eventually("Return adds lines and the box follows", {
            state.editingAnnotation?.note == threeLines
        })
        guard let grownTwice = state.editingAnnotation?.shapeRect else {
            require(false, "the multi-line box has a rectangle")
            return
        }
        require(grownTwice.height > grownOnce.height + 20,
                "two more lines make the box taller")
        let expectedHeight = ceil(3 * lineHeight + padding)
        close(grownTwice.height, expectedHeight,
              "three lines are exactly three line boxes plus padding")
        require(abs(grownTwice.width - grownOnce.width) <= 0.01,
                "adding shorter lines does not change the width")
        try await eventually("the editor is tall enough for every line", {
            host.layoutSubtreeIfNeeded()
            guard let current = findEditor(in: host),
                  let box = state.editingAnnotation?.shapeRect,
                  let manager = current.layoutManager,
                  let container = current.textContainer else { return false }
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container)
            return abs(current.bounds.height
                        - (box.height * state.zoomFactor - 2 * editorPadding())) <= 2
                // TextKit rounds glyph line heights at fractional (scaled) font sizes; 1.5 pt is
                // below one visible line and keeps this about clipping, not rounding.
                && used.height <= current.bounds.height + 1.5
        })
        guard let tallField = findEditor(in: host),
              let tallLayout = tallField.layoutManager,
              let tallContainer = tallField.textContainer else {
            require(false, "the multi-line editor has a layout manager")
            return
        }
        tallLayout.ensureLayout(for: tallContainer)
        let tallUsed = tallLayout.usedRect(for: tallContainer)
        require(tallUsed.height <= tallField.bounds.height + 1.5,
                "every line is visible, not clipped vertically")
        require(tallUsed.width <= tallField.bounds.width + 0.5,
                "the longest line is visible after the height growth")
        require(tallUsed.height >= 2 * lineHeight * state.zoomFactor,
                "the editor is really laying out all three lines")

        // Command-Return is Done: the box stays, at the size its text produced.
        let grownText = threeLines
        let grownRect = grownTwice
        tallField.keyDown(with: key(36, "\r", modifiers: .command,
                                    windowNumber: window.windowNumber))
        try await eventually("Command-Return finishes the text box", {
            state.editingAnnotationID == nil
        })
        require(state.annotations.first(where: { $0.id == boxID })?.note == grownText,
                "Done keeps the typed text")
        require(state.annotations.first(where: { $0.id == boxID })?.shapeRect == grownRect,
                "Done keeps the size the text produced")
        require(state.selectedAnnotationID == nil,
                "Done removes the editing outline and the selection")

        // The whole session is one undo step: text and geometry come back together.
        state.undo()
        guard let undone = state.annotations.first(where: { $0.id == boxID }) else {
            require(false, "undo leaves the created box in place")
            return
        }
        require(undone.note.isEmpty && undone.shapeRect == creationBox,
                "undo restores the empty box at the size the double-click created")
        state.redo()
        require(state.annotations.first(where: { $0.id == boxID })?.note == grownText,
                "redo restores the grown text")
        require(state.annotations.first(where: { $0.id == boxID })?.shapeRect == grownRect,
                "redo restores the grown geometry")
        let reopenedHit = contentPoint(state, page: 0,
                                       CGPoint(x: grownRect.midX, y: grownRect.midY))
        require(state.beginEditingTextBox(atContentPoint: reopenedHit),
                "a grown box is re-editable by double-click")
        require(state.editingAnnotationID == boxID, "the grown box reopens its editor")
        // Editing an existing box is its own undo step, and the step carries the rectangle as
        // well as the text: undo puts the previous size back, not just the previous string.
        state.updateEditingText("An edit long enough to widen the grown box again.")
        require(state.commitTextEditing(), "a second edit commits")
        guard let editedBox = state.annotations.first(where: { $0.id == boxID }) else {
            require(false, "the edited box survives")
            return
        }
        require(editedBox.note == "An edit long enough to widen the grown box again.",
                "the second edit keeps its text")
        require(editedBox.shapeRect != grownRect, "the second edit changes the box's size")
        state.undo()
        guard let undoneEdit = state.annotations.first(where: { $0.id == boxID }) else {
            require(false, "undoing the edit keeps the box")
            return
        }
        require(undoneEdit.note == grownText,
                "undoing an edit restores the previous text")
        require(undoneEdit.shapeRect == grownRect,
                "undoing an edit restores the previous size")
        state.redo()
        require(state.annotations.first(where: { $0.id == boxID })?.note
                    == "An edit long enough to widen the grown box again.",
                "redoing an edit restores its text")
        state.undo()
        require(state.annotations.first(where: { $0.id == boxID })?.shapeRect == grownRect,
                "redoing and undoing again leaves the box at the grown size")
        try await waitForNoEditor(host)

        // ── 3. Escape and a page click finish consistently ──────────────────────────────
        let escapeAim = CGPoint(x: 430, y: 300)
        require(state.placeTextBox(page: 0, at: escapeAim), "a second box is placed for Escape")
        let escapeID = state.editingAnnotationID
        try await eventually("the Escape box's editor is hosted", {
            host.layoutSubtreeIfNeeded()
            return findEditor(in: host) != nil
        })
        guard let escapeField = findEditor(in: host), let escapeID else {
            require(false, "the Escape box has an editor")
            return
        }
        escapeField.insertText("This text must be discarded.", replacementRange: NSRange(location: 0, length: 0))
        try await eventually("Escape, typing first", {
            state.editingAnnotation?.note == "This text must be discarded."
        })
        escapeField.keyDown(with: key(53, "\u{1b}", windowNumber: window.windowNumber))
        try await eventually("Escape cancels the new text box", {
            state.editingAnnotationID == nil
        })
        require(!state.annotations.contains(where: { $0.id == escapeID }),
                "Escape removes the box it created")
        try await waitForNoEditor(host)

        let outsideAim = CGPoint(x: 430, y: 430)
        require(state.placeTextBox(page: 0, at: outsideAim), "a third box is placed for a page click")
        guard let outsideID = state.editingAnnotationID else {
            require(false, "the third box is open for editing")
            return
        }
        try await eventually("the page-click box's editor is hosted", {
            host.layoutSubtreeIfNeeded()
            return findEditor(in: host) != nil
        })
        guard let outsideField = findEditor(in: host) else {
            require(false, "the page-click box has an editor")
            return
        }
        outsideField.insertText("Clicking the page keeps this.", replacementRange: NSRange(location: 0, length: 0))
        try await eventually("page-click typing reaches the model", {
            state.editingAnnotation?.note == "Clicking the page keeps this."
        })
        let clickAim = CGPoint(x: 300, y: 650)
        let clickView = viewPoint(state, page: 0, clickAim,
                                  canvasHeight: hostCanvas.bounds.height)
        let clickWindow = hostCanvas.convert(clickView, to: nil)
        let clickDown = NSEvent.mouseEvent(
            with: .leftMouseDown, location: clickWindow, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1)!
        let clickUp = NSEvent.mouseEvent(
            with: .leftMouseUp, location: clickWindow, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1)!
        hostCanvas.mouseDown(with: clickDown)
        hostCanvas.mouseUp(with: clickUp)
        try await eventually("a click on the page finishes the text box", {
            state.editingAnnotationID == nil
        })
        require(state.annotations.first(where: { $0.id == outsideID })?.note
                    == "Clicking the page keeps this.",
                "clicking outside keeps the text box and its text")

        // ── 4. A pre-change sidecar entry still opens, edits and keeps its shape ─────────
        let legacyDocument = try copy(drawing, "legacy-textbox.pdf")
        let legacyID = UUID()
        let legacyEntry = """
{
  "id" : "\(legacyID.uuidString)",
  "kind" : "textBox",
  "page" : 0,
  "note" : "A box from an older build.",
  "color" : "#2B2B2EFF",
  "rect" : { "x" : 180, "y" : 220, "width" : 180, "height" : 60 },
  "fontSize" : 14,
  "createdAt" : 804000000,
  "version" : 1
}
"""
        try Data("[\n\(legacyEntry)\n]".utf8).write(to: sidecar(for: legacyDocument))
        let legacy = try makeState(legacyDocument)
        guard let loadedLegacy = legacy.annotations.first(where: { $0.id == legacyID }) else {
            require(false, "a pre-change text box decodes from the sidecar")
            return
        }
        require(loadedLegacy.note == "A box from an older build."
                    && loadedLegacy.shapeRect == CGRect(x: 180, y: 220, width: 180, height: 60),
                "the pre-change box keeps its text and rectangle")
        let legacyHit = contentPoint(legacy, page: 0, CGPoint(x: 220, y: 240))
        require(legacy.beginEditingTextBox(atContentPoint: legacyHit),
                "the pre-change box opens its editor")
        legacy.updateEditingText("A box from an older build, edited today.")
        require(legacy.commitTextEditing(), "the pre-change box commits an edit")
        guard let editedLegacy = legacy.annotations.first(where: { $0.id == legacyID }) else {
            require(false, "the edited pre-change box survives")
            return
        }
        require(editedLegacy.note == "A box from an older build, edited today.",
                "the pre-change box keeps its edited text")
        require(editedLegacy.hasValidGeometry && editedLegacy.fontSize == 14,
                "the pre-change box keeps a valid rectangle and its font size")
        let legacyReopened = try makeState(legacyDocument)
        require(legacyReopened.annotations.first(where: { $0.id == legacyID })?.note
                    == "A box from an older build, edited today.",
                "the edited pre-change box reloads from the unchanged sidecar shape")
        let legacySidecar = String(decoding: try Data(contentsOf: sidecar(for: legacyDocument)),
                                   as: UTF8.self)
        require(legacySidecar.contains("\"kind\" : \"textBox\"")
                    && legacySidecar.contains("\"rect\"")
                    && legacySidecar.contains("\"fontSize\"")
                    && legacySidecar.contains("\"version\" : 1"),
                "the pre-change sidecar shape is still what is written")

        // ── 5. Save Annotated Copy writes the grown rectangle as /FreeText ──────────────
        let writerDocument = try copy(annotated, "textbox-write.pdf")
        let writer = try makeState(writerDocument)
        try await eventually("the write-back fixture's own annotations load", {
            writer.documentAnnotations.count == 7 || writer.documentAnnotationsError != nil
        })
        require(writer.documentAnnotationsError == nil,
                "the write-back fixture's annotations are readable")
        let writeAim = CGPoint(x: 240, y: 620)
        require(writer.placeTextBox(page: 0, at: writeAim), "a grown box is placed for writing")
        guard let writeID = writer.editingAnnotationID else {
            require(false, "the box for writing is open")
            return
        }
        let writtenText = "A grown text box.\nThe file stores this exact rectangle."
        writer.updateEditingText(writtenText)
        require(writer.commitTextEditing(), "the grown box commits before writing")
        guard let writtenRect = writer.annotations.first(where: { $0.id == writeID })?.shapeRect
        else {
            require(false, "the grown box has a rectangle to write")
            return
        }
        let copyURL = scratch.appendingPathComponent("written-textbox.pdf")
        let saved = await writer.saveAnnotatedCopy(to: copyURL)
        require(saved, "Save Annotated Copy writes the grown text box")
        let reader = try makeState(copyURL)
        try await eventually("the written /FreeText annotation reads back", {
            reader.documentAnnotations.count == 8 || reader.documentAnnotationsError != nil
        })
        require(reader.documentAnnotationsError == nil,
                "reading the written copy does not fail")
        guard let written = reader.documentAnnotations.first(where: {
            $0.id == "nm:\(writeID.uuidString)"
        }), let writtenBox = written.boxes.first else {
            require(false, "the written text box comes back under its /NM")
            return
        }
        require(written.kind == "freeText" && written.drawing == .freeText,
                "the written box is a /FreeText annotation")
        require(written.contents == writtenText, "the written box keeps every line of text")
        close(writtenBox.xPt, writtenRect.minX, "the written /Rect x matches the grown box")
        close(writtenBox.yPt, writtenRect.minY, "the written /Rect y matches the grown box")
        close(writtenBox.widthPt, writtenRect.width, "the written /Rect width matches the grown box")
        close(writtenBox.heightPt, writtenRect.height, "the written /Rect height matches the grown box")
        require(writtenBox.heightPt >= 2 * lineHeight,
                "the written /Rect is tall enough for both lines")
        print("Text box placement checks passed")
    }
}
