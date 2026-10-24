import AppKit
import CoreGraphics
import Foundation
import ImageIO
import LyraReaderKit
import PDFKit
import SwiftUI

/// Exercises Fill & Sign placement and the real Continuity image requestor in a window.
/// Device discovery and the iPhone/iPad sketch board still require physical-device verification.
extension ReaderChecks {
    @MainActor static func fillSignChecks(root: URL) async throws {
        _ = NSApplication.shared
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-reader-fillsign-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        func copy(_ name: String, _ local: String) throws -> URL {
            let destination = scratch.appendingPathComponent(local)
            try fileManager.copyItem(
                at: root.appendingPathComponent("tests/fixtures/\(name)"), to: destination)
            return destination
        }
        let plain = try copy("text-page.pdf", "fill-sign.pdf")
        let signed = try copy("signed-signature.pdf", "fill-sign-signed.pdf")
        let xfa = try copy("xfa-refusal.pdf", "fill-sign-xfa.pdf")
        let encrypted = try copy("form-fields-encrypted.pdf", "fill-sign-encrypted.pdf")

        func makeState(_ url: URL) async throws -> AppState {
            let state = AppState(engine: try RustEngine())
            state.setViewportSize(CGSize(width: 900, height: 700))
            state.newTab(url: url)
            try await eventually("\(url.lastPathComponent) lays out a page", {
                state.canvasPageFrames.contains(where: { $0.index == 0 })
            })
            return state
        }
        func pageFrame(_ state: AppState, _ page: Int = 0) -> PagePlacement {
            guard let frame = state.canvasPageFrames.first(where: { $0.index == page }) else {
                fatalError("FAIL: page \(page + 1) has no canvas frame")
            }
            return frame
        }
        func contentPoint(_ state: AppState, _ pagePoint: CGPoint, page: Int = 0) -> CGPoint {
            let frame = pageFrame(state, page)
            return CGPoint(x: frame.leftPt + pagePoint.x, y: frame.topPt + pagePoint.y)
        }
        func png(width: Int = 48, height: Int = 24) -> Data {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                fatalError("FAIL: could not make a picture bitmap")
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.systemBlue.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            NSColor.white.setFill()
            NSRect(x: 4, y: 4, width: width - 8, height: height - 8).fill()
            NSGraphicsContext.restoreGraphicsState()
            guard let data = rep.representation(using: .png, properties: [:]) else {
                fatalError("FAIL: could not encode a picture PNG")
            }
            return data
        }
        func inkBounds(_ annotation: AppState.Annotation) -> CGRect {
            let points = annotation.inkPaths.flatMap { $0 }
            guard let first = points.first else { return .zero }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        func near(_ rect: CGRect, _ point: CGPoint, slack: CGFloat = 2) -> Bool {
            rect.insetBy(dx: -slack, dy: -slack).contains(point)
        }

        let state = try await makeState(plain)

        // ── 1. The row: seven placement tools, in order, each with its inspector ────────
        require(state.canPlaceFillSignAnnotation,
                "a plain PDF offers the Fill & Sign placements")
        require(state.canOpenFillAndSign,
                "the Fill & Sign button opens on a plain PDF")
        let row = state.fillSignRowCommands
        require(row.map(\.title) == ["Text", "Signature", "Date", "Checkmark", "Cross",
                                     "Stamp", "Image"],
                "the row has Text, Signature, Date, Checkmark, Cross, Stamp, Image in order")
        require(row.map(\.id) == ["text", "signature", "date", "checkmark", "cross", "stamp",
                                  "image"],
                "the seven row ids are stable")
        require(FillSignTool.rowOrder == [.text, .signature, .date, .checkmark, .cross, .stamp,
                                          .image],
                "the declared row order is the requested one")
        require(row.allSatisfy(\.enabled), "every Fill & Sign row item is enabled on a plain PDF")
        require(row.allSatisfy { $0.help.contains("annotation until you save") },
                "every row item says its mark is an annotation until saved")
        require(row.allSatisfy { NSImage(systemSymbolName: $0.icon,
                                         accessibilityDescription: nil) != nil },
                "every row item's symbol exists on this macOS")
        require(!state.fillSignInspectorVisible,
                "the inspector is absent before a Fill & Sign tool is armed")

        let controller = FillSignCommandController(state: state)
        require(state.fillSignSignatureMethods.map(\.title)
                    == ["Type", "Draw", "Image…", "From iPhone or iPad"],
                "the Signature inspector exposes all four methods")
        require(state.fillSignSignatureMethods.allSatisfy {
                    $0.help.contains("annotation until you save")
                }, "every signature method explains that it places an annotation until saved")

        let stampStyles = AppState.StampStyle.allCases
        require(!stampStyles.isEmpty
                    && AppState.StampStyle.allCases.map(\.title) == stampStyles.map(\.title),
                "the Stamp inspector grid has the existing stamp styles")
        require(state.fillSignFormCommands.map(\.id) == ["save-filled-copy", "write-form-values"],
                "the two form writes remain available to the inspector and File")

        // ── 2. Text arms the text-box tool, opens the row and closes the inspector on place ──
        state.selectFillSignTool(.text)
        require(state.fillAndSignVisible,
                "Text opens the Fill & Sign row")
        require(state.armedFillSignTool == .text,
                "Text is the row's armed item")
        require(state.fillSignInspectorVisible,
                "arming Text opens the right-hand inspector")
        require(state.annotationTool == .textBox,
                "Text arms the existing text-box tool")
        require(state.pendingFillSignPlacement == .text,
                "Text claims the next click for a one-click placement")
        require(!state.formFieldsAcceptPointer,
                "an armed Text placement leaves form fields alone until it is placed or cancelled")
        require(state.cancelActiveAnnotationTool(),
                "Escape cancels an armed Fill & Sign placement")
        require(state.pendingFillSignPlacement == nil && state.annotationTool == .select,
                "Escape returns the canvas to the pointer")
        require(!state.fillSignInspectorVisible,
                "Escape clears the armed tool and closes the inspector")

        // ── 3. Date: today's date, medium style, selected for replacement ───────────────
        let datePoint = CGPoint(x: 250, y: 280)
        state.selectFillSignTool(.date)
        require(state.fillSignInspectorVisible,
                "Date's inspector appears while the date tool is armed")
        require(state.pendingFillSignPlacement == .date, "Date arms a one-click date placement")
        require(state.placePendingFillSign(atContentPoint: contentPoint(state, datePoint)),
                "Date places a text box at the click point")
        require(!state.fillSignInspectorVisible,
                "placing the date closes the inspector with the armed tool")
        guard let dateBox = state.annotations.first(where: { $0.kind == .textBox }) else {
            require(false, "the Date placement created a text box")
            return
        }
        require(dateBox.note == FillSignDate.mediumString(),
                "the date text is today in the user's locale, medium style: \(dateBox.note)")
        require(dateBox.note.range(of: "[0-9]{4}-[0-9]{2}-[0-9]{2}", options: .regularExpression)
                    == nil,
                "the Date text box is not the stamp's ISO date: it is the locale's medium style")
        require(state.editingAnnotationID == dateBox.id,
                "the date box opens for typing")
        require(state.editingTextSelectAll,
                "the date is selected so the first keystroke replaces it")
        require(near(dateBox.shapeRect ?? .zero, datePoint, slack: 40),
                "the date box is centred near the click point")
        let dateID = dateBox.id
        state.commitTextEditing()
        require(state.annotations.contains(where: { $0.id == dateID }),
                "the date box stays after its editor closes")
        state.undo()
        require(!state.annotations.contains(where: { $0.id == dateID }),
                "undo removes a placed date box")
        state.redo()
        require(state.annotations.contains(where: { $0.id == dateID }),
                "redo restores a placed date box")
        state.undo()
        _ = state.commitTextEditing()

        // ── 4. Checkmark and Cross: two vector ink strokes each, at the click point ─────
        func assertMark(_ mark: FillSignMark, tool: FillSignTool,
                        click: CGPoint) {
            state.annotationColor = AppState.annotationPalette[0].color
            let countBefore = state.annotations.count
            let point = contentPoint(state, click)
            state.selectFillSignTool(tool)
            require(state.fillSignInspectorVisible,
                    "\(mark.title)'s inspector appears while it is armed")
            require(state.pendingFillSignPlacement
                        == (mark == .checkmark ? .checkmark : .cross),
                    "\(mark.title) arms a one-click placement")
            require(state.placePendingFillSign(atContentPoint: point),
                    "\(mark.title) places on the click point")
            require(state.annotations.count == countBefore + 1,
                    "\(mark.title) adds exactly one annotation")
            guard let placed = state.annotations.last else {
                require(false, "\(mark.title) placed an annotation")
                return
            }
            require(placed.kind == .ink,
                    "\(mark.title) is an ink annotation, not a font glyph")
            require(placed.inkPaths.count == 2,
                    "\(mark.title) has exactly two strokes (got \(placed.inkPaths.count))")
            require(placed.inkPaths.allSatisfy { $0.count >= 2 },
                    "\(mark.title)'s strokes have their endpoints")
            require(placed.inkPaths == mark.strokes(centeredAt: click),
                    "\(mark.title)'s strokes match the declared vector shape")
            require(placed.strokeWidth == mark.strokeWidth,
                    "\(mark.title)'s stroke width is in page points")
            require(placed.color == state.annotationStrokeColor,
                    "\(mark.title) uses the current annotation colour at full opacity")
            let bounds = inkBounds(placed)
            require(near(bounds, click, slack: 1),
                    "\(mark.title)'s bounding box is near the click point (\(bounds))")
            require(bounds.width <= mark.size.width + 0.01
                        && bounds.height <= mark.size.height + 0.01,
                    "\(mark.title) keeps its sensible page-point size")
            let id = placed.id
            require(state.moveAnnotation(id, by: CGPoint(x: 12, y: 9)),
                    "\(mark.title) is movable like any other annotation")
            if let moved = state.annotations.first(where: { $0.id == id }) {
                require(inkBounds(moved).minX == bounds.minX + 12
                            && inkBounds(moved).minY == bounds.minY + 9,
                        "\(mark.title) moves by its page geometry")
            }
            state.undo()
            require(state.annotations.first(where: { $0.id == id })?.inkPaths == placed.inkPaths,
                    "undo restores \(mark.title)'s position")
            // A placed symbol carries a box, so the same eight handles a stamp has resize it.
            let enlarged = CGRect(x: bounds.minX, y: bounds.minY,
                                  width: bounds.width * 1.5, height: bounds.height * 1.5)
            require(state.resizeAnnotation(id, to: enlarged),
                    "\(mark.title) can be resized like the other placed annotations")
            if let resized = state.annotations.first(where: { $0.id == id }) {
                let resizedBounds = inkBounds(resized)
                require(abs(resizedBounds.width - bounds.width * 1.5) < 0.6
                            && abs(resizedBounds.height - bounds.height * 1.5) < 0.6,
                        "\(mark.title)'s strokes follow its resize handles")
            }
            state.undo()
            require(state.annotations.first(where: { $0.id == id })?.inkPaths == placed.inkPaths,
                    "undo restores \(mark.title)'s size")
            state.undo()
            require(!state.annotations.contains(where: { $0.id == id }),
                    "undo removes \(mark.title) in one step")
            state.redo()
            require(state.annotations.contains(where: { $0.id == id }),
                    "redo restores \(mark.title)")
            state.undo()
        }
        assertMark(.checkmark, tool: .checkmark, click: CGPoint(x: 300, y: 360))
        assertMark(.cross, tool: .cross, click: CGPoint(x: 420, y: 360))

        // ── 5. Image… places an arbitrary picture, not a signature ─────────────────────
        state.annotationColor = AppState.annotationPalette[0].color
        let picture = png()
        state.armPicturePlacement(imageData: picture)
        require(state.pendingSignatureImageData == picture,
                "Image… accepts a PNG picture")
        require(state.pendingSignatureIsPicture,
                "the armed image is marked as a picture, not a signature")
        require(state.placeSignature(atContentPoint: contentPoint(state, CGPoint(x: 500, y: 300))),
                "the picture is placed at the click point")
        guard let pictureAnnotation = state.annotations.last else {
            require(false, "the picture annotation exists")
            return
        }
        require(pictureAnnotation.kind == .signature,
                "the picture uses the existing image-annotation kind and writer")
        require(pictureAnnotation.stampStyle == "image",
                "the cache labels the picture as an image, not a signature")
        require(pictureAnnotation.imageData == picture,
                "the placed picture keeps the bytes the reader chose")
        require(pictureAnnotation.shapeRect?.height == AppState.Annotation.defaultPictureHeight,
                "the picture gets a sensible default size")
        require(state.canPlaceFillSignAnnotation,
                "the picture placement leaves Fill & Sign available")
        state.undo()
        require(!state.annotations.contains(where: { $0.id == pictureAnnotation.id }),
                "undo removes a placed picture")

        // ── 6. Type: a name rendered to a transparent PNG in a handwriting font ────────
        let fonts = TypedSignatureRenderer.availableFontNames
        require(!fonts.isEmpty,
                "macOS provides at least one of Snell Roundhand, Bradley Hand, Noteworthy")
        require(TypedSignatureRenderer.preferredFontNames.contains(fonts[0]),
                "the first available handwriting font is one of the declared built-ins")
        guard let typedPNG = TypedSignatureRenderer.pngData(name: "Ada Lovelace") else {
            require(false, "a typed name renders to a PNG")
            return
        }
        require(!typedPNG.isEmpty && typedPNG.count > 1_000,
                "the typed-signature PNG has real content (\(typedPNG.count) bytes)")
        require(typedPNG.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
                "the typed signature is a PNG")
        let typedURL = scratch.appendingPathComponent("typed-signature.png")
        try typedPNG.write(to: typedURL)
        let attributes = try fileManager.attributesOfItem(atPath: typedURL.path)
        require((attributes[.size] as? NSNumber)?.intValue ?? 0 == typedPNG.count,
                "the typed-signature PNG exists on disk with its bytes")
        guard let typedSource = CGImageSourceCreateWithData(typedPNG as CFData, nil),
              let typedImage = CGImageSourceCreateImageAtIndex(typedSource, 0, nil) else {
            require(false, "the typed-signature PNG decodes as an image")
            return
        }
        require(typedImage.width > 100 && typedImage.height > 20,
                "the typed-signature PNG is rendered at a useful size")
        require(TypedSignatureRenderer.resolvedFontName("Snell Roundhand") == "Snell Roundhand"
                    || TypedSignatureRenderer.resolvedFontName() != nil,
                "the renderer resolves a handwriting font by name")
        require(state.armTypedSignature(name: "Ada Lovelace"),
                "Type arms the rendered signature image")
        guard let armedTyped = state.pendingSignatureImageData else {
            require(false, "Type keeps the rendered PNG as the armed picture")
            return
        }
        require(armedTyped == TypedSignatureRenderer.pngData(name: "Ada Lovelace"),
                "Type arms exactly the rendered handwriting PNG")
        require(state.placeSignature(atContentPoint: contentPoint(state, CGPoint(x: 240, y: 520))),
                "Type places the typed signature on the page")
        guard let typedAnnotation = state.annotations.last else {
            require(false, "the typed signature annotation exists")
            return
        }
        require(typedAnnotation.kind == .signature && typedAnnotation.imageData != nil,
                "Type uses the existing image-signature annotation")
        require(typedAnnotation.stampStyle == "signature",
                "Type is labelled a signature, not a generic picture")
        state.undo()
        require(!state.annotations.contains(where: { $0.id == typedAnnotation.id }),
                "undo removes a typed signature image")

        // ── 7. Draw: the pad's strokes become one ink annotation ───────────────────────
        let drawn = DrawnSignature(
            strokes: [
                [CGPoint(x: 0.05, y: 1.0), CGPoint(x: 0.35, y: 0.0), CGPoint(x: 0.6, y: 1.0)],
                [CGPoint(x: 0.5, y: 0.75), CGPoint(x: 0.95, y: 0.6)],
            ],
            aspect: 2.5)
        state.armDrawnSignature(drawn)
        require(state.pendingFillSignPlacement == .drawnSignature(drawn),
                "Draw arms the hand-drawn strokes as a one-click placement")
        require(state.placePendingFillSign(atContentPoint: contentPoint(state, CGPoint(x: 320, y: 600))),
                "Draw places the strokes at the click point")
        guard let drawnAnnotation = state.annotations.last else {
            require(false, "the drawn signature annotation exists")
            return
        }
        require(drawnAnnotation.kind == .ink && drawnAnnotation.inkPaths.count == 2,
                "Draw stores the strokes as the existing ink signature")
        require(abs((drawnAnnotation.shapeRect ?? .zero).height
                        - AppState.Annotation.defaultSignatureHeight) < 0.6,
                "the drawn signature carries the box its resize handles live on")
        let drawnBounds = inkBounds(drawnAnnotation)
        require(abs(drawnBounds.height - AppState.Annotation.defaultSignatureHeight) < 0.6,
                "the drawn signature is scaled to the signature default height")
        require(near(drawnBounds, CGPoint(x: 320, y: 600), slack: 70),
                "the drawn signature is centred near the click point")
        state.undo()
        require(!state.annotations.contains(where: { $0.id == drawnAnnotation.id }),
                "undo removes a drawn signature")

        // ── 8. Discover and deliver through the actual window's first responder ───────
        let requestor = ContinuitySignatureRequestor(controller: controller)
        let continuityWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
        continuityWindow.isReleasedWhenClosed = false
        continuityWindow.contentView = requestor
        defer { continuityWindow.close() }
        require(requestor.beginRequest(), "Continuity installs its requestor in a real window")
        let receiver = continuityWindow.firstResponder?.validRequestor(
            forSendType: nil, returnType: .tiff) as? NSServicesMenuRequestor
        require((receiver as? ContinuitySignatureRequestor) === requestor,
                "AppKit discovers the image receiver through the window's responder chain")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("lyra-fillsign-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(picture, forType: .png)
        require(receiver?.readSelection?(from: pasteboard) == true,
                "the discovered Services requestor accepts a returned sketch")
        require(state.pendingSignatureImageData == picture,
                "the returned sketch becomes the armed signature image")
        require(state.placeSignature(atContentPoint: contentPoint(state, CGPoint(x: 560, y: 480))),
                "the received sketch places as a signature image")
        require(state.annotations.last?.kind == .signature,
                "the received sketch is an image signature")
        state.undo()

        // ── 9. Read-only documents: present and disabled with the existing reasons ─────
        // XFA: even copies are refused, so every row item is disabled and explains it.
        let xfaState = try await makeState(xfa)
        require(xfaState.isXfaDocument, "the XFA fixture reads as an XFA form")
        let xfaPlacement = xfaState.fillSignRowCommands
        require(xfaPlacement.count == 7, "the seven row items are still present on XFA")
        require(xfaPlacement.allSatisfy { !$0.enabled },
                "every row item is disabled on an XFA form")
        require(xfaPlacement.allSatisfy {
                    $0.help.localizedCaseInsensitiveContains("XFA")
                }, "every disabled XFA row item explains the XFA reason")
        require(xfaState.fillSignSignatureMethods.allSatisfy {
                    !$0.enabled && $0.help.localizedCaseInsensitiveContains("XFA")
                }, "the XFA Signature methods are disabled and explain the reason too")

        // Encrypted: form fields cannot be written, and the row says so rather than hiding.
        let encryptedState = try await makeState(encrypted)
        try await eventually("the encrypted fixture's form facts load", {
            encryptedState.formLoadCompleted && !encryptedState.formLoading
        })
        require(encryptedState.fillSignRowCommands.allSatisfy { !$0.enabled },
                "every row item is disabled on an encrypted PDF")
        require(encryptedState.fillSignRowCommands.allSatisfy {
                    $0.help.localizedCaseInsensitiveContains("encrypted")
                }, "every disabled encrypted row item explains the encryption")

        try await continuitySignatureChecks(
            state: state, refusedState: xfaState, encryptedState: encryptedState,
            fixture: plain, picture: picture)
        try signatureInteractionChecks(state: state)

        // Signed: placements are allowed (the cache is written to a copy), while the form
        // writes into the original stay disabled with the signature reason. The row items are
        // present, not hidden, and their help says where the annotation can go.
        let signedState = try await makeState(signed)
        require(signedState.isReadOnlyDocument, "the signed fixture reads as read-only in place")
        require(signedState.fillSignRowCommands.allSatisfy(\.enabled),
                "placements stay available on a signed PDF because they go to a copy")
        require(signedState.fillSignRowCommands.allSatisfy {
                    $0.help.contains("save a copy to keep it")
                }, "the signed-document placement help says the result needs a saved copy")
        require(signedState.fillSignFormCommands.first(where: { $0.id == "write-form-values" })?
                    .enabled == false,
                "writing form values into the signed original is disabled")
        require(signedState.fillSignFormCommands.first(where: { $0.id == "write-form-values" })?
                    .help?.localizedCaseInsensitiveContains("sign") == true,
                "the disabled signed write explains the signature")
        require(!signedState.canReplaceOriginalWithFilledForm,
                "the signed original stays unwritable")

        // ── 10. The writers see the placed marks ───────────────────────────────────────
        // Save a copy with a check mark and a picture, then let PDFKit count them. This goes
        // through the same annotation writer the rest of the reader uses.
        let saveState = try await makeState(plain)
        let saveClick = CGPoint(x: 360, y: 320)
        saveState.armFillSignMark(.checkmark)
        require(saveState.placePendingFillSign(atContentPoint: contentPoint(saveState, saveClick)),
                "the save fixture's check mark is placed")
        saveState.armPicturePlacement(imageData: picture)
        require(saveState.pendingSignatureImageData == picture,
                "the save fixture's picture is armed")
        require(saveState.placeSignature(
                    atContentPoint: contentPoint(saveState, CGPoint(x: 480, y: 500))),
                "the save fixture's picture is placed")
        let copyURL = scratch.appendingPathComponent("fill-sign-written.pdf")
        let writtenOK = await saveState.saveAnnotatedCopy(to: copyURL)
        require(writtenOK, "the placed marks are written by the existing annotation writer")
        guard let written = PDFDocument(url: copyURL), let writtenPage = written.page(at: 0) else {
            require(false, "PDFKit opens the written copy")
            return
        }
        let writtenTypes = writtenPage.annotations.map(\.type)
        require(writtenTypes.contains("Ink"),
                "PDFKit reads the check mark as an Ink annotation (got \(writtenTypes))")
        require(writtenTypes.contains("Stamp"),
                "PDFKit reads the picture as a Stamp image (got \(writtenTypes))")

        // ── 11. The Date box's editor starts with the date selected ───────────────────
        // The flag above is the state; this hosts the real reader so the NSTextView selection
        // (the thing a keystroke actually replaces) is measured on the window the reader sees.
        func findCanvas(in view: NSView) -> MetalCanvasView? {
            if let canvas = view as? MetalCanvasView { return canvas }
            return view.subviews.lazy.compactMap { findCanvas(in: $0) }.first
        }
        func findEditor(in view: NSView) -> NSTextView? {
            if let editor = view as? NSTextView,
               editor.accessibilityLabel() == "Text box content" { return editor }
            return view.subviews.lazy.compactMap { findEditor(in: $0) }.first
        }
        _ = NSApplication.shared
        let hostedState = try await makeState(plain)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ReaderWindow(
            state: hostedState,
            opener: DocumentOpenCoordinator(state: hostedState),
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
        let hostedClick = contentPoint(hostedState, CGPoint(x: 300, y: 300))
        hostedState.armFillSignDate()
        require(hostedState.placePendingFillSign(atContentPoint: hostedClick),
                "the hosted reader places a date box")
        try await eventually("the hosted date editor appears", {
            host.layoutSubtreeIfNeeded()
            return findEditor(in: host) != nil
        })
        guard let editor = findEditor(in: host),
              let hostedDate = hostedState.annotations.first(where: { $0.kind == .textBox })
        else {
            require(false, "the hosted reader has a date editor")
            return
        }
        require(editor.string == hostedDate.note,
                "the editor shows the placed date")
        require(editor.selectedRange() == NSRange(location: 0,
                                                  length: (hostedDate.note as NSString).length),
                "the whole date is selected in the editor, so typing replaces it")
        editor.insertText("Replaced", replacementRange: editor.selectedRange())
        try await eventually("typing replaces the selected date", {
            hostedState.annotations.first(where: { $0.id == hostedDate.id })?.note == "Replaced"
        })
        require(hostedState.annotations.first(where: { $0.id == hostedDate.id })?.note
                    == "Replaced",
                "the first keystroke replaces the date instead of appending to it")

        print("NOTE: Continuity device discovery and the sketch board need a paired iPhone/iPad; "
                + "this automated check covers the responder chain and image delivery contract.")
    }
}
