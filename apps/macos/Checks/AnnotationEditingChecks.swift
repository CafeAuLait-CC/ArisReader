import AppKit
import LyraReaderKit
import SwiftUI

extension ReaderChecks {
    @MainActor static func annotationEditingChecks(root: URL) async throws {
        let source = "🙂 Generating human motion with diffusion\nmodels poses several challenges. We compare diffusion models again."
        let scalars = Array(source.unicodeScalars)
        let chars = scalars.enumerated().map { index, scalar in
            TextChar(unicode: scalar.value, xPt: CGFloat(index) * 6 + 50, yPt: 50, widthPt: 6, heightPt: 12)
        }
        let page = TextPage(page: 0, chars: chars, text: source, hasUnicodeMapError: false)
        func mark(_ needle: String, color: AnnotationColor, last: Bool = false) -> AppState.Annotation {
            let range = source.range(of: needle, options: last ? .backwards : [])!
            let lower = source.unicodeScalars.distance(from: source.startIndex, to: range.lowerBound)
            let upper = source.unicodeScalars.distance(from: source.startIndex, to: range.upperBound)
            return .init(id: UUID(), page: 0, start: lower, end: upper - 1,
                         color: color, note: "", createdAt: Date())
        }
        let yellow = AnnotationColor(red: 255, green: 225, blue: 90, alpha: 102)
        let pink = AnnotationColor(red: 255, green: 100, blue: 130, alpha: 102)
        let marks = [mark("diffusion\nmodels", color: yellow), mark("several challenges", color: pink),
                     mark("diffusion models", color: yellow, last: true)]
        var maps = [0: AnnotationSentenceMap(page)]
        let passages = AnnotationPassage.build(document: [], own: marks, pages: [0: page], maps: &maps)
        require(passages.count == 2 && passages[0].marks.count == 2,
                "same-sentence highlights merge while repeated words in another sentence stay separate")
        require(passages[0].text.contains("Generating human motion with diffusion models poses several challenges."),
                "annotation excerpts retain the full sentence and join wrapped lines")
        let attributed = passages[0].attributed(appearance: .original)
        require(attributed.runs.filter { $0.backgroundColor != nil }.count == 2,
                "both original highlight colors survive Unicode offset mapping")
        require(passages[1].marks[0].range.lowerBound > passages[0].marks[0].range.lowerBound,
                "repeated text is matched by source indices rather than the first substring")
        var underlined = marks[0]
        underlined.kind = .underline
        var struck = marks[1]
        struck.kind = .strikeout
        let linePassage = AnnotationPassage.build(document: [], own: [underlined, struck], pages: [0: page], maps: &maps)[0]
        let styledLines = linePassage.attributed(appearance: .original)
        func displayedColor(_ color: AnnotationColor) -> Color {
            Color(nsColor: NSColor(calibratedRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255,
                                   blue: CGFloat(color.blue) / 255, alpha: CGFloat(color.alpha) / 255))
        }
        require(styledLines.runs.contains { $0.swiftUI.underlineStyle == Text.LineStyle(color: displayedColor(yellow)) }
                    && styledLines.runs.contains { $0.swiftUI.strikethroughStyle == Text.LineStyle(color: displayedColor(pink)) },
                "excerpt underlines and strikeouts carry their original colors in SwiftUI")

        let headedText = "A heading\nThis is the marked sentence."
        var headingX: CGFloat = 50
        var headingY: CGFloat = 40
        let headedChars = headedText.unicodeScalars.map { scalar -> TextChar in
            let char = TextChar(unicode: scalar.value, xPt: headingX, yPt: headingY, widthPt: 6, heightPt: 12)
            if scalar == "\n" { headingX = 50; headingY = 100 } else { headingX += 6 }
            return char
        }
        let headedPage = TextPage(page: 0, chars: headedChars, text: headedText, hasUnicodeMapError: false)
        let headedMap = AnnotationSentenceMap(headedPage)
        let markStart = Array("A heading\n".unicodeScalars).count
        let markedSpan = headedMap.span(indices: Array(markStart..<headedChars.count))!
        let sentence = headedMap.sentence(containing: markedSpan)
        require((headedMap.text as NSString).substring(with: NSRange(location: sentence.lowerBound, length: sentence.count))
                    == "This is the marked sentence.",
                "geometric paragraph gaps keep preceding headings out of annotation excerpts")

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-reader-editing-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("notes.pdf")
        try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: file)
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 900, height: 800))
        require(state.open(url: file), "annotation editing fixture opens")
        let text = try await state.engine.textPage(0)
        let pattern = Array("quick".unicodeScalars.map(\.value))
        let start = text.chars.indices.first { index in
            index + pattern.count <= text.chars.count && pattern.indices.allSatisfy { text.chars[index + $0].unicode == pattern[$0] }
        }!
        let selected = text.selectionRects(in: start...(start + pattern.count - 1))[0]
        try await eventually("the note has a real text selection", {
            guard let placement = state.canvasPageFrames.first(where: { $0.index == 0 }) else { return false }
            state.beginSelection(at: CGPoint(x: placement.leftPt + selected.minX + 0.2, y: selected.midY))
            state.extendSelection(to: CGPoint(x: placement.leftPt + selected.maxX - 0.2, y: selected.midY))
            return state.selection != nil
        })
        state.beginNoteFromSelection()
        let id = state.editingAnnotationID!
        require(state.sidebarTab == .annotations && state.sidebarVisible && state.editingAnnotationAnchor != nil,
                "Add Note opens the themed editor beside its line and reveals the annotation list")
        state.updateEditingText("A useful comment.")
        require(state.commitTextEditing(), "the text-linked note commits")
        require(state.ownInlineNoteMarkers.count == 1,
                "the saved selection note has a clickable margin label")
        require(state.annotationPassages.contains { $0.marks.contains { $0.source == .own(id) && $0.note == "A useful comment." } },
                "the sentence entry includes its note content")
        let index = state.annotations.firstIndex { $0.id == id }!
        require(state.canvasPages.contains { $0.placement.index == PlacementIndex.ownAnnotation(index) && $0.blend == .multiply },
                "own highlights use Multiply, preserving black source glyphs")
        let marker = state.ownInlineNoteMarkers[0]
        let placement = state.canvasPageFrames.first { $0.index == 0 }!
        require(state.openInlineNote(at: CGPoint(x: placement.leftPt + marker.rect.midX,
                                                 y: placement.topPt + marker.rect.midY))
                    && state.editingAnnotationID == id,
                "clicking the selection note label reopens its editable paper")
        state.cancelTextEditing()
        let copy = scratch.appendingPathComponent("saved.pdf")
        let savedNote = await state.saveAnnotatedCopy(to: copy)
        require(savedNote, "a text-linked note saves into the PDF")
        let reader = try RustEngine()
        _ = try reader.openDocument(at: copy)
        let saved = try await reader.annotations()
        require(saved.contains { $0.contents == "A useful comment." && $0.hasInlineNote },
                "the note reopens as standard commented text markup")

        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1000, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        defer { window.orderOut(nil); window.contentView = nil }
        let host = NSHostingView(rootView: ReaderWindow(state: state, opener: DocumentOpenCoordinator(state: state),
                                                       previewPanels: ReferencePreviewPanelController()))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        state.annotationTool = .textBox
        require(state.addTextBox(page: 0, rect: CGRect(x: 100, y: 350, width: 220, height: 140)),
                "a new text box enters editing on the page")
        require(state.annotationTool == .select,
                "text-box creation returns to selection so a page click can finish editing")
        func editor(in view: NSView, name: String) -> NSTextView? {
            if let view = view as? NSTextView, view.accessibilityLabel() == name { return view }
            return view.subviews.lazy.compactMap { editor(in: $0, name: name) }.first
        }
        try await eventually("the transparent inline text box editor is hosted", {
            host.layoutSubtreeIfNeeded()
            return editor(in: host, name: "Text box content") != nil
        })
        let field = editor(in: host, name: "Text box content")!
        require(!field.drawsBackground && !field.isRichText,
                "text box editing has a transparent plain-text surface")
        let boxID = state.editingAnnotationID!
        field.insertText("Hello\nworld", replacementRange: NSRange(location: 0, length: 0))
        try await eventually("native text edits fit the saved text-box geometry", {
            guard let annotation = state.annotations.first(where: { $0.id == boxID }), let box = annotation.shapeRect else { return false }
            return annotation.note == "Hello\nworld" && box.height < 140 && box.width < 220 && annotation.hasValidGeometry
        })
        state.commitTextEditing()
        require(state.selectedAnnotationID == nil, "finishing inline text hides the dashed editing outline")
        let committedBox = state.annotations.first { $0.id == boxID }!
        state.beginEditingAnnotation(boxID)
        state.updateEditingText("A longer edit changes both text and its frame")
        state.beginEditingAnnotation(boxID)
        state.cancelTextEditing()
        require(state.annotations.first { $0.id == boxID } == committedBox,
                "reopening an active editor preserves cancellation of both text and geometry")
        let formFile = scratch.appendingPathComponent("form.pdf")
        try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/form-fields.pdf"), to: formFile)
        require(state.open(url: formFile), "the native form editor fixture opens")
        try await eventually("multiline form fields load", { state.formLoadCompleted && !state.formLoading })
        let notes = state.formFields.first { $0.multiline }!
        state.gotoPage(notes.page + 1)
        state.toggleFormTool()
        state.focusFormField(notes.id)
        try await eventually("a multiline form uses the native multiline editor", {
            host.layoutSubtreeIfNeeded()
            return editor(in: host, name: notes.displayName) != nil
        })
        let formEditor = editor(in: host, name: notes.displayName)!
        formEditor.insertText("First line", replacementRange: NSRange(location: 0, length: (formEditor.string as NSString).length))
        formEditor.insertNewline(nil)
        formEditor.insertText("Second line", replacementRange: formEditor.selectedRange())
        try await eventually("Return inserts a newline instead of leaving a multiline form field", {
            state.formCurrentText(notes) == "First line\nSecond line" && state.formFocusedFieldID == notes.id
        })
        print("Annotation editing checks passed")
    }
}
