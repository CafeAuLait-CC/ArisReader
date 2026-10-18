import AppKit
import ArisReaderKit
import CoreGraphics
import Foundation
import PDFKit

extension ReaderChecks {
    /// Sticky text-markup tools: activate once, then every finished selection is marked.
    ///
    /// Every selection here is produced by the same three `AppState` calls the canvas makes on
    /// press / drag / release, so the check exercises the real mouse-up path rather than a
    /// testing-only shortcut. The fixture is a scratch copy: the committed PDF and its sidecar
    /// are never written.
    @MainActor static func stickyMarkupChecks(fixture: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("aris-sticky-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let document = scratch.appendingPathComponent("sticky.pdf")
        try fileManager.copyItem(at: fixture, to: document)
        let sidecar = document.appendingPathExtension("aris-annotations.json")

        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        state.newTab(url: document)
        require(state.document != nil, "the sticky-tools fixture opens")
        try await eventually("the page has a canvas frame", {
            !state.canvasPageFrames.isEmpty
        })

        let probe = try RustEngine()
        _ = try probe.openDocument(at: document)
        let text = try await probe.textPage(0)
        func index(of needle: String) -> Int {
            let pattern = Array(needle.unicodeScalars.map(\.value))
            guard pattern.count > 0, text.chars.count >= pattern.count else {
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

        /// The two content points a real pointer drag would use for this character range.
        func dragPoints(_ range: ClosedRange<Int>) -> (start: CGPoint, end: CGPoint) {
            let rects = text.selectionRects(in: range)
            guard let first = rects.first, let last = rects.last else {
                fatalError("FAIL: range \(range) has no text geometry")
            }
            let frame = frame()
            return (
                CGPoint(x: frame.leftPt + first.minX + 1, y: frame.topPt + first.midY),
                CGPoint(x: frame.leftPt + last.maxX - 1, y: frame.topPt + last.midY)
            )
        }

        /// Press on the first character, drag to the last, release: exactly the canvas gestures.
        func drag(_ range: ClosedRange<Int>) {
            let points = dragPoints(range)
            state.beginSelection(at: points.start)
            state.extendSelection(to: points.end)
            state.endPointerInteraction(at: points.end, wasClick: false)
        }

        // The text layer is fetched asynchronously on open; wait until a real press resolves a
        // character instead of sleeping for an arbitrary interval.
        do {
            let points = dragPoints(index(of: "Line 1")...(index(of: "Line 1") + 5))
            try await eventually("the text layer is ready for a selection", {
                state.beginSelection(at: points.start)
                return state.selection != nil
            })
            state.clearSelection()
        }

        let colorA = AnnotationColor(red: 30, green: 120, blue: 220, alpha: 150)
        let colorB = AnnotationColor(red: 200, green: 40, blue: 60, alpha: 190)
        let colorC = AnnotationColor(red: 40, green: 150, blue: 90, alpha: 170)
        state.annotationColor = colorA

        let line1 = index(of: "Line 1")
        let line2 = index(of: "Line 2")
        let line3 = index(of: "Line 3")
        let line4 = index(of: "Line 4")
        let line5 = index(of: "Line 5")
        let line6 = index(of: "Line 6")
        let range1 = line1...(line1 + 5)
        let range2 = line2...(line2 + 5)
        let range3 = line3...(line3 + 5)
        let range4 = line4...(line4 + 5)
        let range5 = line5...(line5 + 5)
        let range6 = line6...(line6 + 5)

        // ── 1. Highlight: activating the tool is enough; no second click ──────────────
        state.toggleTextMarkupTool(.highlight)
        require(state.annotationTool == .highlight, "clicking Highlight arms the highlight tool")
        require(state.annotations.isEmpty, "arming a tool without a selection creates nothing")
        drag(range1)
        require(state.annotations.count == 1,
                "a selection made while the highlight tool is active produces a highlight")
        guard let highlighted = state.annotations.last else {
            require(false, "the highlight is in the model")
            return
        }
        require(highlighted.kind == .highlight, "the automatic mark is a highlight")
        require(highlighted.start == range1.lowerBound && highlighted.end == range1.upperBound,
                "the automatic highlight covers the selection that made it")
        require(highlighted.color == colorA, "the automatic mark uses the chosen colour")
        require(state.selection == nil, "creating the mark consumes the selection")
        require(state.undoStack.count == 1, "one selection is one undoable step")
        state.undo()
        require(state.annotations.isEmpty,
                "undo removes a highlight created by the sticky tool")
        state.redo()
        require(state.annotations.count == 1 && state.annotations.last?.kind == .highlight,
                "redo restores it as the same highlight")

        // ── 2. The same selection path creates an underline and a strikeout ──────────
        state.annotationColor = colorB
        state.toggleTextMarkupTool(.underline)
        require(state.annotationTool == .underline, "clicking Underline switches the markup kind")
        require(state.annotationTool != .highlight, "activating Underline deactivates Highlight")
        drag(range2)
        require(state.annotations.count == 2, "a selection made with Underline active is marked")
        require(state.annotations.last?.kind == .underline, "the second mark is an underline")
        require(state.annotations.last?.color == colorB, "the underline takes the active colour")

        state.annotationColor = colorC
        state.toggleTextMarkupTool(.strikeout)
        require(state.annotationTool == .strikeout, "clicking Strikethrough switches the markup kind")
        drag(range3)
        require(state.annotations.count == 3, "a selection made with Strikethrough active is marked")
        require(state.annotations.last?.kind == .strikeout, "the third mark is a strikeout")
        require(state.annotations.last?.color == colorC, "the strikeout takes the active colour")

        // ── 3. Toggling the active tool off stops the automatic marking ───────────────
        state.toggleTextMarkupTool(.strikeout)
        require(state.annotationTool == .select, "clicking the active tool again leaves the mode")
        let beforeOff = state.annotations.count
        drag(range4)
        require(state.annotations.count == beforeOff,
                "toggling the tool off stops selections from being marked")
        require(state.selection != nil, "with no tool active the selection stays for ⌘C")
        state.clearSelection()

        // ── 4. Switching tools switches the kind, with exactly one active ─────────────
        state.toggleTextMarkupTool(.highlight)
        state.toggleTextMarkupTool(.underline)
        drag(range5)
        require(state.annotationTool == .underline
                    && state.annotations.last?.kind == .underline,
                "switching from Highlight to Underline marks the next selection as an underline")
        require(state.annotations.filter { $0.kind == .highlight }.count == 1,
                "the earlier highlight is not re-marked by the switch")

        // ── 5. A selection that already exists is marked when a tool is clicked ───────
        state.selectTool()
        drag(range6)
        require(state.selection != nil && state.annotations.count == 4,
                "with Select active a drag leaves a plain selection and creates nothing")
        state.annotationColor = colorA
        state.toggleTextMarkupTool(.strikeout)
        require(state.annotations.count == 5,
                "clicking a markup tool marks the selection that already exists")
        require(state.annotations.last?.kind == .strikeout
                    && state.annotations.last?.start == range6.lowerBound,
                "the existing selection becomes the chosen kind")
        require(state.selection == nil, "the activation-created mark consumes the selection")

        // ── 6. Escape leaves the mode; Select leaves it too ───────────────────────────
        state.toggleTextMarkupTool(.underline)
        require(state.annotationTool == .underline, "another tool can be armed after a mark")
        let canvas = MetalCanvasView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        canvas.onCancelTextMarkup = { state.cancelTextMarkupTool() }
        guard let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ) else {
            require(false, "an Escape key event can be built")
            return
        }
        canvas.keyDown(with: escape)
        require(state.annotationTool == .select, "Escape leaves the sticky markup mode")

        state.toggleTextMarkupTool(.highlight)
        state.selectTool()
        require(state.annotationTool == .select, "choosing Select leaves the sticky markup mode")

        // ── 7. A press on empty space clears instead of starting a selection ──────────
        state.toggleTextMarkupTool(.highlight)
        state.jump(to: highlighted)
        require(state.selection != nil, "jumping to a mark selects its text")
        let beforeEmpty = state.annotations.count
        let empty = CGPoint(x: frame().leftPt + 20, y: frame().topPt + 8)
        state.beginSelection(at: empty)
        require(state.selection == nil,
                "a press on empty space clears the selection instead of starting a drag")
        state.endPointerInteraction(at: empty, wasClick: false)
        require(state.annotations.count == beforeEmpty,
                "the empty gesture does not mark anything")

        // ── 8. Two selections in a row are two marks, never one interleaved annotation ─
        let beforeRapid = state.annotations.count
        let undoBeforeRapid = state.undoStack.count
        drag(range1)
        drag(range2)
        require(state.annotations.count == beforeRapid + 2,
                "two rapid selections produce two annotations")
        let rapid = state.annotations.suffix(2)
        require(rapid.first?.id != rapid.last?.id, "the two rapid marks are distinct entries")
        require(rapid.first?.start != rapid.last?.start
                    || rapid.first?.end != rapid.last?.end,
                "the two rapid marks cover the two different selections")
        require(state.undoStack.count == undoBeforeRapid + 2,
                "each rapid mark is its own undo step")

        // ── 9. The kind is part of the sidecar, not only of memory ────────────────────
        let sidecarText = String(decoding: try Data(contentsOf: sidecar), as: UTF8.self)
        require(sidecarText.contains("\"kind\" : \"strikeout\""),
                "the strikeout is stored under its own sidecar kind")
        let reopened = AppState(engine: try RustEngine())
        reopened.setViewportSize(CGSize(width: 700, height: 500))
        reopened.newTab(url: document)
        require(reopened.annotations.contains { $0.kind == .strikeout },
                "a reopened sidecar restores the strikeout kind")
        require(reopened.annotations.filter { $0.kind == .strikeout }.count == 2,
                "both strikeouts survive the reopen")

        // Document changes behave like the ink tools: the next document starts in Select. A
        // page change inside one document leaves the active tool alone (the document reset is
        // the only place that assigns Select).
        let secondDocument = scratch.appendingPathComponent("sticky-second.pdf")
        try fileManager.copyItem(at: fixture, to: secondDocument)
        state.newTab(url: secondDocument)
        require(state.annotationTool == .select,
                "opening another document clears the sticky tool, as it clears the ink tool")
    }

    /// `/StrikeOut` end to end: Lyra writes it, Lyra reads it back, another viewer draws it, and
    /// a file annotated by another application is the reading fixture.
    @MainActor static func strikeoutChecks(textPage: URL, annotated: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("aris-strikeout-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        func sidecar(for document: URL) -> URL {
            document.appendingPathExtension("aris-annotations.json")
        }
        func copy(_ source: URL, _ name: String) throws -> URL {
            let destination = scratch.appendingPathComponent(name)
            try fileManager.copyItem(at: source, to: destination)
            try? fileManager.removeItem(at: sidecar(for: destination))
            return destination
        }
        func index(of needle: String, in text: TextPage) -> Int {
            let pattern = Array(needle.unicodeScalars.map(\.value))
            guard pattern.count > 0, text.chars.count >= pattern.count else {
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

        let red = AnnotationColor(red: 200, green: 30, blue: 40, alpha: 255)
        let strikeoutID = UUID()

        // ── 1. Lyra's own write: a real gesture creates the sidecar entry, save writes it ──
        let source = try copy(textPage, "strikeout-source.pdf")
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        state.newTab(url: source)
        try await eventually("the strikeout source has a page", {
            !state.canvasPageFrames.isEmpty
        })
        let probe = try RustEngine()
        _ = try probe.openDocument(at: source)
        let text = try await probe.textPage(0)
        let line1 = index(of: "Line 1", in: text)
        let range = line1...(line1 + 5)
        let rects = text.selectionRects(in: range)
        require(!rects.isEmpty, "the strikeout range has text geometry")
        guard let frame = state.canvasPageFrames.first(where: { $0.index == 0 }),
              let firstRect = rects.first, let lastRect = rects.last else {
            require(false, "the strikeout page has a canvas frame")
            return
        }
        state.annotationColor = red
        state.toggleTextMarkupTool(.strikeout)
        let start = CGPoint(x: frame.leftPt + firstRect.minX + 1,
                            y: frame.topPt + firstRect.midY)
        let end = CGPoint(x: frame.leftPt + lastRect.maxX - 1,
                          y: frame.topPt + lastRect.midY)
        try await eventually("the strikeout text layer is ready", {
            state.beginSelection(at: start)
            return state.selection != nil
        })
        state.clearSelection()
        state.beginSelection(at: start)
        state.extendSelection(to: end)
        state.endPointerInteraction(at: end, wasClick: false)
        require(state.annotations.count == 1 && state.annotations.first?.kind == .strikeout,
                "a strikeout gesture creates a strikeout sidecar entry")
        guard let created = state.annotations.first else {
            require(false, "the strikeout is in the model")
            return
        }

        let copyURL = scratch.appendingPathComponent("strikeout-copy.pdf")
        let saved = await state.saveAnnotatedCopy(to: copyURL)
        require(saved, "saving a copy with a strikeout succeeds")
        if let report = state.lastAnnotationWriteReport {
            require(report.writtenIDs == [created.id.uuidString],
                    "the report names the strikeout that was written")
            require(report.preexistingAnnotationCount == 0,
                    "the text-page fixture had no annotations to preserve")
            require(report.sourceBytesPreserved && report.appendedBytes > 0,
                    "the strikeout save is append-only")
        } else {
            require(false, "a successful strikeout save publishes a report")
        }

        let copySidecar = copyURL.appendingPathExtension("aris-annotations.json")
        require(!fileManager.fileExists(atPath: copySidecar.path),
                "an annotated copy carries no sidecar")

        // ── 2. Lyra reads its own /StrikeOut back as a strikeout ──────────────────────
        let reopened = AppState(engine: try RustEngine())
        reopened.setViewportSize(CGSize(width: 700, height: 500))
        reopened.newTab(url: copyURL)
        try await eventually("reopening the copy reads the written strikeout", {
            reopened.documentAnnotations.count == 1
        })
        let written = reopened.documentAnnotations[0]
        require(written.kind == "strikeout", "Lyra's own /StrikeOut reads back as strikeout")
        require(written.drawing == .markup, "the written strikeout is classified as text markup")
        require(written.quads.count == rects.count, "the written strikeout keeps its quads")
        require(written.color?.red == red.red && written.color?.green == red.green
                    && written.color?.blue == red.blue,
                "the written strikeout keeps its colour")
        require(written.blend == "multiply",
                "a /StrikeOut with no /BM is composited as multiply")
        try await eventually("the strikeout quad is handed to the canvas as a line", {
            guard let quad = written.quads.first else { return false }
            let lineHeight = max(quad.heightPt * 0.12, 1)
            return reopened.canvasPages.contains { page in
                abs(page.placement.widthPt - quad.widthPt) < 0.01
                    && abs(page.placement.heightPt - lineHeight) < 0.01
            }
        })

        // ── 3. Another viewer draws it: PDFKit is Preview's engine ────────────────────
        let band = try pdfKitMarkBand(
            url: copyURL,
            viewSpaceRect: rects[0],
            color: red,
            scale: 2
        )
        require(band.middle > 40,
                "PDFKit draws the strikeout line through the middle (\(band.middle) px)")
        require(band.top + band.bottom < max(8, band.middle / 3),
                "PDFKit does not fill the quad: the mark is a line, not a highlight (top \(band.top), bottom \(band.bottom))")
        FileHandle.standardError.write(Data(
            "aris-strikeout: PDFKit middle=\(band.middle) top=\(band.top) bottom=\(band.bottom)\n".utf8
        ))

        // ── 4. Write-back over a file another producer annotated ──────────────────────
        // The committed fixture is hand-written by `scripts/make-fixtures.py`, not by Lyra, and
        // carries seven annotations (including its own `/StrikeOut`). Replacing it must add the
        // new mark once, leave every pre-existing annotation unchanged and produce a verified
        // byte-identical backup.
        let externalBefore = AppState(engine: try RustEngine())
        externalBefore.setViewportSize(CGSize(width: 700, height: 500))
        externalBefore.newTab(url: annotated)
        try await eventually("the external fixture's annotations load", {
            externalBefore.documentAnnotations.count == 7
                || externalBefore.documentAnnotationsError != nil
        })
        require(externalBefore.documentAnnotationsError == nil,
                "the external fixture's annotations read without error")
        let nested = externalBefore.documentAnnotations[2]
        require(nested.kind == "strikeout",
                "the external fixture's /StrikeOut reads back as a strikeout")
        let originalExternal = externalBefore.documentAnnotations

        let replaceSource = try copy(annotated, "strikeout-replace.pdf")
        let replaceEngine = try RustEngine()
        _ = try replaceEngine.openDocument(at: replaceSource)
        let replaceText = try await replaceEngine.textPage(0)
        let replaceLine1 = index(of: "Line 1", in: replaceText)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let entry = AppState.Annotation(
            id: strikeoutID,
            kind: .strikeout,
            page: 0,
            start: replaceLine1,
            end: replaceLine1 + 5,
            color: red,
            note: "written by Lyra",
            createdAt: Date()
        )
        let encoded = String(decoding: try encoder.encode([entry]), as: UTF8.self)
        let entryText = String(encoded.dropFirst(2).dropLast(2))
        try Data("[\n\(entryText)\n]".utf8).write(to: sidecar(for: replaceSource))
        let originalBytes = try Data(contentsOf: replaceSource)

        let replaceState = AppState(engine: try RustEngine())
        replaceState.setViewportSize(CGSize(width: 700, height: 500))
        replaceState.newTab(url: replaceSource)
        require(replaceState.annotations.count == 1,
                "the seeded sidecar loads the strikeout to write")
        let replaced = await replaceState.replaceOriginalWithSavedAnnotations()
        require(replaced, "replacing a file that already has annotations succeeds")
        guard let report = replaceState.lastAnnotationWriteReport else {
            require(false, "the replace publishes a report")
            return
        }
        require(report.preexistingAnnotationCount == 7,
                "all seven pre-existing annotations were counted")
        require(report.sourceBytesPreserved, "the replaced file keeps the source as its prefix")
        guard let backupPath = report.backupPath else {
            require(false, "the replace names its backup")
            return
        }
        let backupBytes = try Data(contentsOf: URL(fileURLWithPath: backupPath))
        require(backupBytes == originalBytes,
                "the backup is byte-identical to the pre-save file")
        let replaceSidecarText = String(decoding: try Data(contentsOf: sidecar(for: replaceSource)),
                                        as: UTF8.self)
        require(!replaceSidecarText.contains(strikeoutID.uuidString),
                "the saved strikeout is removed from the sidecar, so a reopen cannot duplicate it")

        let afterExternal = AppState(engine: try RustEngine())
        afterExternal.setViewportSize(CGSize(width: 700, height: 500))
        afterExternal.newTab(url: replaceSource)
        try await eventually("the replaced file reads eight annotations", {
            afterExternal.documentAnnotations.count == 8
        })
        require(afterExternal.documentAnnotations.count == 8,
                "the replaced file carries seven existing annotations plus the strikeout")
        let found = afterExternal.documentAnnotations.filter {
            $0.id == "nm:\(strikeoutID.uuidString)"
        }
        require(found.count == 1 && found[0].kind == "strikeout",
                "the strikeout written by Lyra is present exactly once")
        for original in originalExternal {
            guard let current = afterExternal.documentAnnotations.first(where: {
                $0.id == original.id
            }) else {
                require(false, "pre-existing annotation \(original.id) was lost")
                return
            }
            require(current == original,
                    "pre-existing annotation \(original.id) is unchanged")
        }
    }

    /// Counts pixels close to `color` in the middle, top and bottom thirds of a markup band.
    @MainActor
    private static func pdfKitMarkBand(
        url: URL,
        viewSpaceRect: CGRect,
        color: AnnotationColor,
        scale: CGFloat
    ) throws -> (middle: Int, top: Int, bottom: Int) {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else {
            throw NSError(
                domain: "Lyra",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "PDFKit could not open the saved strikeout"]
            )
        }
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(ceil(bounds.width * scale))
        let height = Int(ceil(bounds.height * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "Lyra", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "no PDFKit bitmap"])
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        guard let data = context.data else { return (0, 0, 0) }
        let bytesPerRow = context.bytesPerRow
        let pixels = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)

        let minX = max(Int(viewSpaceRect.minX * scale) + 4, 0)
        let maxX = min(Int(viewSpaceRect.maxX * scale) - 4, width - 1)
        let minY = max(Int(viewSpaceRect.minY * scale) + 2, 0)
        let maxY = min(Int(viewSpaceRect.maxY * scale) - 2, height - 1)
        guard minX < maxX, minY < maxY else { return (0, 0, 0) }
        let bandHeight = maxY - minY
        func isMarkPixel(_ offset: Int) -> Bool {
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            // The fixture's text is black and the paper is white; the strikeout is red. Count
            // pixels whose red channel clearly dominates, so glyph antialiasing is not evidence.
            return red > 120 && red > green + 50 && red > blue + 40
                && abs(red - Int(color.red)) < 90
        }
        var middle = 0
        var top = 0
        var bottom = 0
        for y in minY...maxY {
            let relative = Double(y - minY) / Double(max(bandHeight, 1))
            for x in minX...maxX {
                guard isMarkPixel(y * bytesPerRow + x * 4) else { continue }
                if relative > 0.35 && relative < 0.65 {
                    middle += 1
                } else if relative <= 0.2 {
                    top += 1
                } else if relative >= 0.8 {
                    bottom += 1
                }
            }
        }
        return (middle, top, bottom)
    }
}
