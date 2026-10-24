import AppKit
import LyraReaderKit
import Foundation

/// The annotation row's three-group structure and the implicit pointer state.
///
/// The layout checks measure the real SwiftUI row through `ReaderToolbarProbe`, not a mirror of
/// the numbers: they assert the group frames, the one-button-width gaps, the order inside each
/// group, and that the trailing chrome still fits at the minimum window width. The state checks
/// drive the same `AppState` transitions the buttons and the canvas call.
extension ReaderChecks {
    @MainActor static func annotationToolbarChecks(root: URL) async throws {
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 1200, height: 800))
        state.newTab(url: root.appendingPathComponent("tests/fixtures/form-fields.pdf"))
        try await eventually("the toolbar fixture opens", { state.document != nil })

        // ── The declared row: three groups, no Select, no annotation Redact ───────────
        require(AnnotationToolbarLayout.groupOrder == [.markup, .pointer, .placement],
                "the annotation row declares exactly three groups, in order")
        require(AnnotationToolbarLayout.Group.markup.itemIDs
                    == ["Highlight", "Underline", "Strikethrough"],
                "group 1 is Highlight, Underline, Strikethrough")
        require(AnnotationToolbarLayout.Group.pointer.itemIDs
                    == ["Pen", "Eraser", "Text box", "Shapes"],
                "group 2 is Pen, Eraser, Text box, Shapes")
        require(AnnotationToolbarLayout.Group.placement.itemIDs
                    == ["Note", "Stamp", "Signature"],
                "group 3 is Note, Stamp, Signature")
        let toolIDs = AnnotationToolbarLayout.annotationToolIDs
        require(!toolIDs.contains(where: { $0.caseInsensitiveCompare("Select") == .orderedSame }),
                "the annotation row has no Select tool: no tool is the pointer state")
        require(!toolIDs.contains("Redact"),
                "the duplicate annotation-row Redact control is gone; redaction lives in Edit")
        require(AnnotationToolbarLayout.contentEditItemIDs == ["Text", "Image", "Link", "Redact"],
                "the Edit row has no Select tool either")

        // ── The Fill & Sign icon and label are not the Signature tool's ──────────────
        require(AnnotationToolbarLayout.fillAndSignIcon != "signature",
                "Fill & Sign does not use the signature symbol")
        require(NSImage(systemSymbolName: AnnotationToolbarLayout.fillAndSignIcon,
                        accessibilityDescription: nil) != nil,
                "the Fill & Sign form glyph exists on this macOS")
        require(AnnotationToolbarLayout.fillAndSignLabel
                    .caseInsensitiveCompare("Signature") != .orderedSame,
                "the Fill & Sign accessible name is not 'Signature'")
        require(state.fillAndSignMenuHelp.contains("Signature tool"),
                "the Fill & Sign tooltip points a signature at the Signature tool")
        require(state.canOpenFillAndSignMenu,
                "Fill & Sign is available on a document")

        // ── Frames at the 1200 pt window and at the 900 pt minimum ──────────────────
        let wideRowWidth = 1200 - ReaderChrome.sidebarTotalWidthPt
            - ReaderChrome.scrollIndicatorLaneWidthPt
        let minimumRowWidth = 900 - ReaderChrome.sidebarTotalWidthPt
            - ReaderChrome.scrollIndicatorLaneWidthPt

        func frame(_ id: String, _ frames: [String: CGRect], _ label: String) -> CGRect {
            guard let frame = frames[id] else {
                fatalError("FAIL: \(label) reports no frame for \(id)")
            }
            return frame
        }

        func assertGroups(width: CGFloat, label: String) -> [String: CGRect] {
            let frames = ReaderToolbarProbe.annotationRowFrames(state: state, width: width)
            require(!frames.isEmpty, "the hosted annotation row reports frames at \(label)")
            for id in toolIDs {
                _ = frame(id, frames, label)
            }
            let markup = frame("group.markup", frames, label)
            let pointer = frame("group.pointer", frames, label)
            let placement = frame("group.placement", frames, label)
            print("TOOLBAR FRAMES \(label): markup \(markup) pointer \(pointer) placement \(placement)")
            require(markup.minX < pointer.minX && pointer.maxX < placement.minX,
                    "at \(label) the three group frames run left to right")
            let firstGap = pointer.minX - markup.maxX
            let secondGap = placement.minX - pointer.maxX
            require(abs(firstGap - AnnotationToolbarLayout.buttonWidth) < 0.01,
                    "at \(label) the gap before group 2 is one button width (\(firstGap) pt)")
            require(abs(secondGap - AnnotationToolbarLayout.buttonWidth) < 0.01,
                    "at \(label) the gap before group 3 is one button width (\(secondGap) pt)")
            require(abs(markup.width - (3 * 34 + 2 * 2)) < 0.01
                        && abs(pointer.width - (4 * 34 + 3 * 2)) < 0.01
                        && abs(placement.width - (3 * 34 + 2 * 2)) < 0.01,
                    "at \(label) each group is exactly its buttons plus the 2 pt inner spacing")
            require(abs(markup.minX - AnnotationToolbarLayout.horizontalPadding) < 0.01,
                    "at \(label) group 1 starts at the row's leading padding")
            for id in AnnotationToolbarLayout.Group.markup.itemIDs {
                require(markup.insetBy(dx: -0.5, dy: -0.5)
                            .contains(frame(id, frames, label)),
                        "at \(label) \(id) is inside group 1")
            }
            for id in AnnotationToolbarLayout.Group.pointer.itemIDs {
                require(pointer.insetBy(dx: -0.5, dy: -0.5)
                            .contains(frame(id, frames, label)),
                        "at \(label) \(id) is inside group 2")
            }
            for id in AnnotationToolbarLayout.Group.placement.itemIDs {
                require(placement.insetBy(dx: -0.5, dy: -0.5)
                            .contains(frame(id, frames, label)),
                        "at \(label) \(id) is inside group 3")
            }
            let ordered = AnnotationToolbarLayout.annotationToolIDs.map {
                frame($0, frames, label).minX
            }
            require(ordered == ordered.sorted(),
                    "at \(label) the tools are laid out in their declared group order")
            require(frames.keys.allSatisfy {
                $0.caseInsensitiveCompare("Select") != .orderedSame && $0 != "Redact"
            }, "at \(label) the built row contains no Select or annotation Redact control")
            let color = frame("Annotation color", frames, label)
            let close = frame("Hide annotation tools", frames, label)
            require(placement.maxX < color.minX && color.maxX <= close.minX,
                    "at \(label) the colour picker and close button are trailing chrome")
            require(close.maxX <= width - AnnotationToolbarLayout.horizontalPadding + 0.01,
                    "at \(label) the trailing chrome fits inside the row (\(close.maxX) of \(width) pt)")
            return frames
        }

        let wide = assertGroups(width: wideRowWidth, label: "1200 pt window")
        let minimum = assertGroups(width: minimumRowWidth, label: "900 pt minimum window")
        for id in ["group.markup", "group.pointer", "group.placement"]
            + AnnotationToolbarLayout.annotationToolIDs {
            require(abs(wide[id]!.minX - minimum[id]!.minX) < 0.01,
                    "\(id) does not move when the window narrows from 1200 to 900 pt")
        }

        // ── The Edit row has no Select button ───────────────────────────────────────
        let contentFrames = ReaderToolbarProbe.contentEditRowFrames(
            state: state, width: minimumRowWidth)
        require(Set(contentFrames.keys) == Set(AnnotationToolbarLayout.contentEditItemIDs),
                "the Edit row contains exactly Text, Image, Link and Redact")
        let contentOrder = AnnotationToolbarLayout.contentEditItemIDs.map {
            frame($0, contentFrames, "Edit row").minX
        }
        require(contentOrder == contentOrder.sorted(),
                "the Edit row lays its tools out left to right")

        // ── Clicking the active tool again returns to selection ─────────────────────
        require(state.annotationTool == .select, "the row starts in the implicit pointer state")
        state.toggleAnnotationTool(.pen)
        require(state.annotationTool == .pen, "the Pen button arms the pen")
        state.toggleAnnotationTool(.pen)
        require(state.annotationTool == .select,
                "clicking the active Pen again returns to the implicit pointer state")
        state.toggleAnnotationTool(.pen)
        state.toggleAnnotationTool(.note)
        require(state.annotationTool == .note,
                "choosing another tool switches directly, without passing through a Select tool")
        state.toggleAnnotationTool(.note)
        require(state.annotationTool == .select, "clicking the active Note again returns to selection")

        // ── Escape returns every armed tool to selection ────────────────────────────
        let canvas = MetalCanvasView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        canvas.onCancelTool = { state.cancelActiveAnnotationTool() }
        guard let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ) else {
            require(false, "an Escape key event can be built")
            return
        }
        func pressEscape() { canvas.keyDown(with: escape) }

        for tool in [AnnotationTool.pen, .rectangle, .note, .textBox] {
            state.toggleAnnotationTool(tool)
            require(state.annotationTool == tool, "\(tool.rawValue) can be armed")
            pressEscape()
            require(state.annotationTool == .select,
                    "Escape leaves the \(tool.rawValue) tool and returns to selection")
        }
        state.toggleTextMarkupTool(.highlight)
        require(state.annotationTool == .highlight, "the highlight tool arms")
        pressEscape()
        require(state.annotationTool == .select, "Escape leaves the highlight tool")
        state.toggleEraserTool()
        require(state.annotationTool == .eraser, "the eraser arms")
        pressEscape()
        require(state.annotationTool == .select, "Escape leaves the eraser")
        state.armStampTool(.approved)
        require(state.annotationTool == .stamp, "a stamp style arms the stamp tool")
        pressEscape()
        require(state.annotationTool == .select, "Escape leaves stamp placement")
        state.armSignatureTool(imageData: Data([0x89, 0x50, 0x4E, 0x47]))
        require(state.annotationTool == .signature, "a signature image arms the signature tool")
        pressEscape()
        require(state.annotationTool == .select, "Escape leaves signature placement")

        // ── The Edit row's tools use the same toggle rule ───────────────────────────
        state.contentEditEnabled = true
        require(!state.formFieldsAcceptPointer,
                "Edit PDF takes the pointer from form fields")
        state.selectContentTool("text")
        require(state.contentEditTool == "text", "the Text content tool arms")
        state.selectContentTool("text")
        require(state.contentEditTool == "select",
                "clicking the active content tool again returns to the pointer state")
        state.selectContentTool("image")
        state.selectContentTool("link")
        require(state.contentEditTool == "link",
                "choosing another content tool switches directly")
        state.selectContentTool("link")
        require(state.contentEditTool == "select",
                "clicking the active content tool again clears it")
        state.selectContentTool("image")
        require(state.cancelContentTool(),
                "Escape first leaves the armed content tool")
        require(state.contentEditTool == "select",
                "the content tool's Escape lands on the implicit pointer state")
        require(!state.cancelContentTool(),
                "with no content tool armed, Escape falls through to leaving Edit")
        state.contentEditEnabled = false
        require(state.formFieldsAcceptPointer,
                "leaving Edit restores the implicit pointer state for form fields")

        // ── There is no annotation-row redaction mode at all ────────────────────────
        require(!AnnotationTool.allCases.contains(where: { $0.rawValue == "redact" }),
                "the canvas has no redaction tool: redaction is an Edit-workspace content command")
        state.openRedactionWorkspace()
        require(state.contentEditEnabled && state.contentEditTool == "blackout",
                "the menu's Redact… entry opens Edit with Blackout armed")
        print("Annotation toolbar checks passed")
    }
}
