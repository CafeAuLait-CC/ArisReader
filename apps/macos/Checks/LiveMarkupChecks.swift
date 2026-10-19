import AppKit
import LyraReaderKit
import CoreGraphics
import Foundation

/// One tinted quad handed to the canvas, reduced to what the live preview and the committed
/// mark must agree on. The placement index is deliberately not part of it: the preview owns a
/// slot in the selection block and the committed annotation one in its own block, which is a
/// texture-caching concern, not a visual one.
private struct LiveMarkupQuad: Equatable {
    let topPt: CGFloat
    let leftPt: CGFloat
    let widthPt: CGFloat
    let heightPt: CGFloat
    let bgra: Data
    let blend: QuadBlend

    init(_ page: CanvasPage) {
        topPt = page.placement.topPt
        leftPt = page.placement.leftPt
        widthPt = page.placement.widthPt
        heightPt = page.placement.heightPt
        bgra = page.image.bgra
        blend = page.blend
    }

    init(topPt: CGFloat, leftPt: CGFloat, widthPt: CGFloat, heightPt: CGFloat,
         bgra: Data, blend: QuadBlend) {
        self.topPt = topPt
        self.leftPt = leftPt
        self.widthPt = widthPt
        self.heightPt = heightPt
        self.bgra = bgra
        self.blend = blend
    }
}

extension ReaderChecks {
    /// The live feedback of the sticky text-markup tools.
    ///
    /// While Highlight, Underline or Strikethrough is armed, the drag that selects text must
    /// already look like the mark it is about to commit: the same quads, colour and blend as the
    /// annotation written on release, never the ordinary blue text selection. The checks drive
    /// the same three `AppState` calls the canvas makes on press / drag / release, so the
    /// comparison is between the real mid-gesture canvas state and the real committed state.
    ///
    /// The fixtures are scratch copies: the committed PDF and its sidecar are never touched.
    @MainActor static func liveMarkupChecks(textPage: URL, twoColumn: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-reader-live-markup-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let document = scratch.appendingPathComponent("live-markup.pdf")
        try fileManager.copyItem(at: textPage, to: document)

        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 900, height: 700))
        state.newTab(url: document)
        require(state.document != nil, "the live-markup fixture opens")
        try await eventually("the live-markup page has a canvas frame", {
            !state.canvasPageFrames.isEmpty
        })

        let probe = try RustEngine()
        _ = try probe.openDocument(at: document)
        let text = try await probe.textPage(0)
        guard !text.chars.isEmpty else {
            require(false, "the live-markup fixture has a text layer")
            return
        }

        func index(of needle: String) -> Int {
            let pattern = Array(needle.unicodeScalars.map(\.value))
            guard !pattern.isEmpty, text.chars.count >= pattern.count else {
                fatalError("FAIL: fixture text does not contain \(needle)")
            }
            outer: for start in 0...(text.chars.count - pattern.count) {
                for offset in 0..<pattern.count
                where text.chars[start + offset].unicode != pattern[offset] {
                    continue outer
                }
                return start
            }
            fatalError("FAIL: fixture text does not contain \(needle)")
        }

        func frame() -> PagePlacement {
            guard let frame = state.canvasPageFrames.first(where: { $0.index == 0 }) else {
                fatalError("FAIL: page one has no canvas frame")
            }
            return frame
        }

        /// The centre of one character's own glyph box, in content space: exactly where a
        /// pointer would sit to start or end a drag on that character.
        func point(at index: Int) -> CGPoint {
            let character = text.chars[index]
            let frame = frame()
            return CGPoint(
                x: frame.leftPt + character.xPt + max(1, character.widthPt / 2),
                y: frame.topPt + character.yPt + max(1, character.heightPt / 2)
            )
        }

        func style(_ kind: AppState.Annotation.Kind) -> (scale: CGFloat, offset: CGFloat) {
            switch kind {
            case .underline: return (0.1, 0.9)
            case .strikeout: return (0.12, 0.45)
            default: return (1.0, 0.0)
            }
        }

        /// What the canvas must show for `range` while `kind` is armed — built from the same
        /// text-layer rectangles every committed mark is built from, at the style the committed
        /// own-annotation pass uses.
        func expectedMarkup(_ range: ClosedRange<Int>, kind: AppState.Annotation.Kind,
                            color: AnnotationColor) -> [LiveMarkupQuad] {
            let frame = frame()
            let bar = style(kind)
            let baked = color.baked(opacity: 1.0)
            return text.selectionRects(in: range).map { rect in
                LiveMarkupQuad(
                    topPt: frame.topPt + rect.minY + rect.height * bar.offset,
                    leftPt: frame.leftPt + rect.minX,
                    widthPt: rect.width,
                    heightPt: max(rect.height * bar.scale, 1),
                    bgra: Data(baked.bgra),
                    blend: .multiply
                )
            }
        }

        /// The ordinary selection the reader has always drawn: one translucent blue box per
        /// selected line.
        func expectedSelection(_ range: ClosedRange<Int>) -> [LiveMarkupQuad] {
            let frame = frame()
            return text.selectionRects(in: range).map { rect in
                LiveMarkupQuad(
                    topPt: frame.topPt + rect.minY,
                    leftPt: frame.leftPt + rect.minX,
                    widthPt: rect.width,
                    heightPt: rect.height,
                    bgra: Data([0xFF, 0x80, 0x00, 0x55]),
                    blend: .normal
                )
            }
        }

        func overlayQuads() -> [LiveMarkupQuad] {
            state.canvasPages
                .filter { PlacementIndex.isSelection($0.placement.index) }
                .map { LiveMarkupQuad($0) }
        }

        func committedQuads(annotationIndex: Int) -> [LiveMarkupQuad] {
            let base = PlacementIndex.ownAnnotation(annotationIndex)
            return state.canvasPages
                .filter { $0.placement.index >= base && $0.placement.index < base + 4_096 }
                .map { LiveMarkupQuad($0) }
        }

        /// Press on the first character, drag to the last, and stop **before** the release, so
        /// the check can inspect exactly what the reader sees mid-gesture.
        func dragToPreview(_ range: ClosedRange<Int>) {
            state.beginSelection(at: point(at: range.lowerBound))
            state.extendSelection(to: point(at: range.upperBound))
        }

        func release(at range: ClosedRange<Int>) {
            state.endPointerInteraction(at: point(at: range.upperBound), wasClick: false)
        }

        // ── 0. The text layer is fetched asynchronously on open; wait until a press resolves a
        // character rather than sleeping for an arbitrary interval.
        do {
            let range = index(of: "Line 1")...(index(of: "Line 1") + 5)
            try await eventually("the live-markup text layer is ready for a selection", {
                state.beginSelection(at: point(at: range.lowerBound))
                return state.selection != nil
            })
            state.clearSelection()
        }

        let colorA = AnnotationColor(red: 30, green: 120, blue: 220, alpha: 150)
        let colorB = AnnotationColor(red: 200, green: 40, blue: 60, alpha: 190)
        let colorC = AnnotationColor(red: 40, green: 150, blue: 90, alpha: 170)
        state.annotationColor = colorA

        // ── 1. With no tool armed, the selection is the ordinary blue one and still copies.
        let line1 = index(of: "Line 1")
        let line2 = index(of: "Line 2")
        let line3 = index(of: "Line 3")
        let line4 = index(of: "Line 4")
        let line5 = index(of: "Line 5")
        let line6 = index(of: "Line 6")
        let plainRange = line4...(line4 + 5)
        dragToPreview(plainRange)
        guard let plainSelection = state.selection else {
            require(false, "a drag with Select armed produces a text selection")
            return
        }
        require(state.annotationTool == .select, "reading opens in Select mode")
        require(state.annotations.isEmpty, "a plain selection creates no annotation")
        let plainExpected = expectedSelection(plainSelection.range)
        require(!plainExpected.isEmpty && overlayQuads() == plainExpected,
                "with no tool armed the overlay is the ordinary blue selection")
        require(overlayQuads().allSatisfy { $0.blend == .normal },
                "the ordinary selection is not multiplied like a markup preview")
        release(at: plainRange)
        require(state.selection != nil, "releasing a plain selection keeps it for copying")
        require(state.annotations.isEmpty, "releasing a plain selection creates nothing")

        let pasteboard = NSPasteboard.general
        let savedClipboard = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let savedClipboard { pasteboard.setString(savedClipboard, forType: .string) }
        }
        state.copySelection()
        let copied = pasteboard.string(forType: .string) ?? ""
        require(copied == text.string(in: plainSelection.range),
                "copying an ordinary selection still copies its text")
        require(!copied.isEmpty, "the copied ordinary selection is not empty")
        state.clearSelection()

        // ── 2. Highlight: the mark is visible during the drag, in the active colour.
        let highlightRange = line1...(line1 + 5)
        state.toggleTextMarkupTool(.highlight)
        require(state.annotationTool == .highlight, "the highlight tool arms")
        let beforeHighlight = state.annotations.count
        dragToPreview(highlightRange)
        guard let highlightSelection = state.selection else {
            require(false, "a markup drag produces the selection it is previewing")
            return
        }
        require(state.annotations.count == beforeHighlight,
                "nothing is committed while the markup drag is still in flight")
        let highlightExpected = expectedMarkup(highlightSelection.range, kind: .highlight,
                                               color: colorA)
        let highlightPreview = overlayQuads()
        require(!highlightExpected.isEmpty, "the highlight selection has line geometry")
        require(highlightPreview == highlightExpected,
                "during a highlight drag the overlay is the highlight quads in the active colour")
        require(highlightPreview != expectedSelection(highlightSelection.range),
                "the highlight preview is not the ordinary blue selection")
        require(highlightPreview.allSatisfy { $0.blend == .multiply },
                "the highlight preview multiplies like the committed highlight")
        release(at: highlightRange)
        require(state.annotations.count == beforeHighlight + 1,
                "releasing the highlight drag commits one annotation")
        guard let highlight = state.annotations.last else {
            require(false, "the committed highlight is in the model")
            return
        }
        require(highlight.kind == .highlight && highlight.color == colorA,
                "the committed highlight has the previewed kind and colour")
        require(highlight.start == highlightSelection.range.lowerBound
                    && highlight.end == highlightSelection.range.upperBound,
                "the committed highlight covers the previewed range")
        require(state.selection == nil, "committing the highlight consumes the preview")
        require(overlayQuads().isEmpty, "no preview is left after the highlight is committed")
        require(committedQuads(annotationIndex: state.annotations.count - 1) == highlightPreview,
                "release produces exactly the same highlight quads as the preview")

        // ── 3. Underline: a thin bar under every selected line, previewed during the drag.
        state.annotationColor = colorB
        state.toggleTextMarkupTool(.underline)
        require(state.annotationTool == .underline, "the underline tool arms")
        let underlineRange = line2...(line2 + 5)
        let beforeUnderline = state.annotations.count
        dragToPreview(underlineRange)
        guard let underlineSelection = state.selection else {
            require(false, "an underline drag produces the selection it is previewing")
            return
        }
        let underlineExpected = expectedMarkup(underlineSelection.range, kind: .underline,
                                               color: colorB)
        let underlinePreview = overlayQuads()
        require(underlinePreview == underlineExpected,
                "during an underline drag the overlay is underline quads in the active colour")
        require(underlinePreview != expectedSelection(underlineSelection.range),
                "the underline preview is not the ordinary blue selection")
        let underlineHeight = underlineExpected.first?.heightPt ?? 0
        require(underlineExpected.allSatisfy { abs($0.heightPt - underlineHeight) < 0.001
                    && $0.heightPt > 0 },
                "the underline preview uses one bar style for every line")
        release(at: underlineRange)
        require(state.annotations.count == beforeUnderline + 1,
                "releasing the underline drag commits one annotation")
        require(state.annotations.last?.kind == .underline,
                "the committed underline has the previewed kind")
        require(committedQuads(annotationIndex: state.annotations.count - 1) == underlinePreview,
                "release produces exactly the same underline quads as the preview")

        // ── 4. Strikethrough: a bar through every selected line, previewed during the drag.
        state.annotationColor = colorC
        state.toggleTextMarkupTool(.strikeout)
        require(state.annotationTool == .strikeout, "the strikethrough tool arms")
        let strikeRange = line3...(line3 + 5)
        let beforeStrike = state.annotations.count
        dragToPreview(strikeRange)
        guard let strikeSelection = state.selection else {
            require(false, "a strikethrough drag produces the selection it is previewing")
            return
        }
        let strikeExpected = expectedMarkup(strikeSelection.range, kind: .strikeout,
                                            color: colorC)
        let strikePreview = overlayQuads()
        require(strikePreview == strikeExpected,
                "during a strikethrough drag the overlay is strikethrough quads in the active colour")
        require(strikePreview != expectedSelection(strikeSelection.range),
                "the strikethrough preview is not the ordinary blue selection")
        release(at: strikeRange)
        require(state.annotations.count == beforeStrike + 1,
                "releasing the strikethrough drag commits one annotation")
        require(state.annotations.last?.kind == .strikeout,
                "the committed strikethrough has the previewed kind")
        require(committedQuads(annotationIndex: state.annotations.count - 1) == strikePreview,
                "release produces exactly the same strikethrough quads as the preview")

        // ── 5. A multi-line selection previews every line's quad, not only the first, and
        // repaints as each pointer sample extends the sweep.
        state.annotationColor = colorA
        state.toggleTextMarkupTool(.highlight)
        require(state.annotationTool == .highlight, "the highlight tool arms again")
        let multiRange = line1...(line6 + 5)
        let beforeMulti = state.annotations.count
        state.beginSelection(at: point(at: line1))
        for (step, line) in [line1, line2, line3, line4, line5, line6].enumerated() {
            let swept = line1...(line + 5)
            state.extendSelection(to: point(at: line + 5))
            guard let sample = state.selection else {
                require(false, "pointer sample \(step + 1) produces a selection")
                return
            }
            require(sample.range == swept,
                    "pointer sample \(step + 1) selects through line \(step + 1)")
            require(overlayQuads() == expectedMarkup(sample.range, kind: .highlight, color: colorA),
                    "pointer sample \(step + 1) repaints the live highlight immediately")
        }
        guard let multiSelection = state.selection else {
            require(false, "the multi-line drag produces a selection")
            return
        }
        let multiRects = text.selectionRects(in: multiSelection.range)
        let multiExpected = expectedMarkup(multiSelection.range, kind: .highlight, color: colorA)
        let multiPreview = overlayQuads()
        require(multiRects.count >= 6,
                "the multi-line selection has one quad per swept line (\(multiRects.count))")
        require(multiPreview == multiExpected,
                "the multi-line preview covers every selected line's quad")
        require(Set(multiPreview.map { $0.topPt }).count >= 6,
                "the multi-line preview is not collapsed to one line")
        release(at: multiRange)
        require(state.annotations.count == beforeMulti + 1
                    && state.annotations.last?.kind == .highlight,
                "releasing the multi-line drag commits one highlight")
        require(committedQuads(annotationIndex: state.annotations.count - 1) == multiPreview,
                "release produces exactly the same multi-line quads as the preview")

        // ── 6. Escape during the drag drops the live mark and commits nothing.
        let escapeRange = line1...(line1 + 5)
        let beforeEscape = state.annotations.count
        dragToPreview(escapeRange)
        require(state.selection != nil && !overlayQuads().isEmpty,
                "the escape gesture has a live preview to cancel")
        let canvas = MetalCanvasView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        canvas.onCancelTool = { state.cancelActiveAnnotationTool() }
        guard let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ) else {
            require(false, "an Escape key event can be built")
            return
        }
        canvas.keyDown(with: escape)
        require(state.annotationTool == .select, "Escape leaves the markup tool")
        require(state.selection == nil, "Escape drops the in-flight selection")
        require(overlayQuads().isEmpty, "Escape leaves no live mark behind")
        state.endPointerInteraction(at: point(at: escapeRange.upperBound), wasClick: false)
        require(state.annotations.count == beforeEscape,
                "Escape and the following mouse-up commit nothing")

        // ── 7. A drag that leaves the page abandons the gesture instead of clamping it.
        state.toggleTextMarkupTool(.highlight)
        let outsideRange = line2...(line2 + 5)
        let beforeOutside = state.annotations.count
        state.beginSelection(at: point(at: outsideRange.lowerBound))
        state.extendSelection(to: point(at: outsideRange.upperBound))
        require(!overlayQuads().isEmpty, "the outside-drag gesture starts with a live preview")
        let frame = frame()
        let outside = CGPoint(x: frame.leftPt - 40, y: frame.topPt + 100)
        state.extendSelection(to: outside)
        require(state.selection == nil, "dragging off the page cancels the selection")
        require(overlayQuads().isEmpty, "dragging off the page removes the live mark")
        state.endPointerInteraction(at: outside, wasClick: false)
        require(state.annotations.count == beforeOutside,
                "releasing off the page commits nothing")

        // ── 8. Leaving the tool mid-drag restores the ordinary blue selection, still uncommitted.
        require(state.annotationTool == .highlight,
                "the highlight tool is still armed after the cancelled drag")
        let leaveRange = line5...(line5 + 5)
        let beforeLeave = state.annotations.count
        dragToPreview(leaveRange)
        require(!overlayQuads().isEmpty, "the tool-leaving gesture starts with a live preview")
        state.selectTool()
        require(state.annotationTool == .select, "Select leaves the markup tool")
        guard let leaveSelection = state.selection else {
            require(false, "leaving the tool keeps the selection in progress")
            return
        }
        require(overlayQuads() == expectedSelection(leaveSelection.range),
                "leaving the tool restores the ordinary blue selection")
        release(at: leaveRange)
        require(state.annotations.count == beforeLeave,
                "releasing the restored ordinary selection commits nothing")
        require(state.selection != nil, "the restored ordinary selection remains for copying")
        state.clearSelection()

        // ── 9. A two-column drag previews every quad in both columns, and release matches it.
        let twoColumnDocument = scratch.appendingPathComponent("live-markup-columns.pdf")
        try fileManager.copyItem(at: twoColumn, to: twoColumnDocument)
        let columns = AppState(engine: try RustEngine())
        columns.setViewportSize(CGSize(width: 900, height: 700))
        columns.newTab(url: twoColumnDocument)
        require(columns.document != nil, "the two-column fixture opens")
        try await eventually("the two-column page has a canvas frame and text layer", {
            !columns.canvasPageFrames.isEmpty
        })
        let columnsProbe = try RustEngine()
        _ = try columnsProbe.openDocument(at: twoColumnDocument)
        let columnText = try await columnsProbe.textPage(0)
        guard !columnText.chars.isEmpty,
              let columnsFrame = columns.canvasPageFrames.first(where: { $0.index == 0 })
        else {
            require(false, "the two-column fixture has a frame and text layer")
            return
        }
        func columnPoint(_ index: Int) -> CGPoint {
            let character = columnText.chars[index]
            return CGPoint(
                x: columnsFrame.leftPt + character.xPt + max(1, character.widthPt / 2),
                y: columnsFrame.topPt + character.yPt + max(1, character.heightPt / 2)
            )
        }
        // First and last real glyphs: the range in between crosses the column break by
        // construction, whatever order the producer emitted its text in.
        let printable = columnText.chars.indices.filter {
            columnText.chars[$0].widthPt > 0 && columnText.chars[$0].heightPt > 0
        }
        guard let firstGlyph = printable.first, let lastGlyph = printable.last else {
            require(false, "the two-column fixture has printable glyphs")
            return
        }
        try await eventually("the two-column text layer is ready for a selection", {
            columns.beginSelection(at: columnPoint(firstGlyph))
            return columns.selection != nil
        })
        columns.clearSelection()
        columns.toggleTextMarkupTool(.highlight)
        columns.annotationColor = colorA
        columns.beginSelection(at: columnPoint(firstGlyph))
        columns.extendSelection(to: columnPoint(lastGlyph))
        guard let columnSelection = columns.selection else {
            require(false, "the two-column drag produces a selection")
            return
        }
        let columnRects = columnText.selectionRects(in: columnSelection.range)
        let midpoint = columnsFrame.widthPt / 2
        require(columnRects.contains { $0.midX < midpoint },
                "the two-column selection has quads in the left column")
        require(columnRects.contains { $0.midX > midpoint },
                "the two-column selection has quads in the right column")
        require(columnRects.count >= 4,
                "the two-column selection covers several lines (\(columnRects.count))")
        let columnBaked = colorA.baked(opacity: 1.0)
        let columnExpected = columnRects.map { rect in
            LiveMarkupQuad(
                topPt: columnsFrame.topPt + rect.minY,
                leftPt: columnsFrame.leftPt + rect.minX,
                widthPt: rect.width,
                heightPt: max(rect.height, 1),
                bgra: Data(columnBaked.bgra),
                blend: .multiply
            )
        }
        let columnPreview = columns.canvasPages
            .filter { PlacementIndex.isSelection($0.placement.index) }
            .map { LiveMarkupQuad($0) }
        require(columnPreview == columnExpected,
                "the two-column preview covers every quad in both columns")
        columns.endPointerInteraction(at: columnPoint(lastGlyph), wasClick: false)
        require(columns.annotations.count == 1
                    && columns.annotations.last?.kind == .highlight,
                "the two-column drag commits one highlight")
        let columnCommitted = columns.canvasPages
            .filter {
                $0.placement.index >= PlacementIndex.ownAnnotation(0)
                    && $0.placement.index < PlacementIndex.ownAnnotation(0) + 4_096
            }
            .map { LiveMarkupQuad($0) }
        require(columnCommitted == columnPreview,
                "release produces exactly the same two-column quads as the preview")
        require(columnCommitted.contains { $0.leftPt < columnsFrame.leftPt + midpoint }
                    && columnCommitted.contains {
                        $0.leftPt + $0.widthPt > columnsFrame.leftPt + midpoint
                    },
                "the committed two-column mark is present in both columns")
    }
}
