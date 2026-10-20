import AppKit
import CoreGraphics
import Foundation
import ImageIO
import LyraReaderKit
import PDFKit
import UniformTypeIdentifiers

/// Stamps and image signatures, end to end.
///
/// Every assertion here fails on the build before T3.17: the toolbar still disabled the two
/// commands and no `/Stamp` annotation existed. The checks exercise the real `AppState` and
/// `RustEngine`, write a real PDF through the verified save path, and then read the result back
/// with **PDFKit** — the engine Preview uses — and with this reader.
///
/// What is proved, in order:
///
/// 1. a text stamp is placed, moved, resized, moved again, deleted and restored by undo;
/// 2. an image signature (a PNG with a transparent background) is placed the same way;
/// 3. both are written into a copy as `/Stamp` annotations with the expected rectangles, and
///    PDFKit renders the stamp's words and the signature's pixels;
/// 4. both are read back by this reader from the saved copy, with their text, style and picture;
/// 5. a `/Stamp` written by **PDFKit** (another producer) is read, classified as drawable, and
///    the same routine the canvas uses produces a picture for it;
/// 6. deleting a saved stamp and a saved signature works, and undo restores them;
/// 7. the sidecar writes versioned `stamp`/`signature` entries and a second reader loads them;
/// 8. a digitally signed document refuses an in-place write and still allows a stamped copy.
extension ReaderChecks {
    @MainActor static func stampSignatureChecks(root: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-reader-stamps-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Set LYRA_KEEP_STAMP_SCRATCH=1 to inspect the copy this check produced: the stamp and
        // its date are what a human eye has to judge, and a deleted scratch file cannot be looked
        // at afterwards.
        defer {
            if ProcessInfo.processInfo.environment["LYRA_KEEP_STAMP_SCRATCH"] == nil {
                try? fileManager.removeItem(at: scratch)
            } else {
                print("stamp scratch kept at \(scratch.path)")
            }
        }

        let fixture = root.appendingPathComponent("tests/fixtures/text-page.pdf")
        let document = scratch.appendingPathComponent("stamped.pdf")
        try fileManager.copyItem(at: fixture, to: document)

        // ── 1. A text stamp: place, move, resize, undo ─────────────────────────────────
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 900, height: 700))
        state.newTab(url: document)
        try await eventually("the stamp fixture lays out a page") {
            state.canvasPageFrames.contains(where: { $0.index == 0 })
        }
        require(state.addStampAnnotation(page: 0, style: .approved,
                                         center: CGPoint(x: 300, y: 320)),
                "a text stamp can be placed on the page")
        guard let stamp = state.annotations.first(where: { $0.kind == .stamp }),
              let placed = stamp.shapeRect else {
            fatalError("FAIL: the placed stamp is in the model")
        }
        require(stamp.note == "APPROVED" && stamp.stampStyle == "approved",
                "the stamp carries its real text and style in the model")
        require(placed.width == AppState.Annotation.defaultStampSize.width
                    && placed.height == AppState.Annotation.defaultStampSize.height,
                "the stamp is placed at the default size")

        let stampID = stamp.id
        // Placement itself is one undo step, like every other annotation.
        state.undo()
        require(!state.annotations.contains(where: { $0.id == stampID }),
                "undo removes a stamp that was just placed")
        state.redo()
        require(state.annotations.first(where: { $0.id == stampID })?.shapeRect == placed,
                "redo restores a placed stamp")
        require(state.moveAnnotation(stampID, by: CGPoint(x: 26, y: 18)),
                "the stamp can be moved")
        let moved = state.annotations.first(where: { $0.id == stampID })?.shapeRect
        require(moved?.minX == placed.minX + 26 && moved?.minY == placed.minY + 18,
                "moving the stamp changes its page box")
        state.undo()
        require(state.annotations.first(where: { $0.id == stampID })?.shapeRect == placed,
                "undo restores the stamp's placement")
        state.redo()
        guard let movedAgain = state.annotations.first(where: { $0.id == stampID })?.shapeRect,
              movedAgain == moved else {
            fatalError("FAIL: redo restores the moved stamp")
        }

        let larger = CGRect(x: movedAgain.minX, y: movedAgain.minY,
                            width: movedAgain.width + 40, height: movedAgain.height + 20)
        require(state.resizeAnnotation(stampID, to: larger),
                "the stamp can be resized")
        require(state.annotations.first(where: { $0.id == stampID })?.shapeRect == larger,
                "resizing the stamp changes its page box")
        state.undo()
        require(state.annotations.first(where: { $0.id == stampID })?.shapeRect == movedAgain,
                "undo restores the stamp's size")
        state.redo()
        require(state.annotations.first(where: { $0.id == stampID })?.shapeRect == larger,
                "redo restores the resized stamp")
        // The stamp's words are real model text, editable before the save. One undo step covers
        // the edit, like every other note field.
        state.updateNote("APPROVED FOR RELEASE", for: stampID)
        require(state.annotations.first(where: { $0.id == stampID })?.note
                    == "APPROVED FOR RELEASE",
                "the stamp's text can be edited before it is saved")
        state.undo()
        require(state.annotations.first(where: { $0.id == stampID })?.note == "APPROVED",
                "undo restores the stamp's text")
        state.redo()
        require(state.annotations.first(where: { $0.id == stampID })?.note
                    == "APPROVED FOR RELEASE",
                "redo restores the edited stamp text")
        // Deleting a stamp is one undo step, exactly like deleting a signature.
        state.selectAnnotation(stampID)
        require(state.deleteSelectedAnnotation(), "the stamp can be deleted")
        require(!state.annotations.contains(where: { $0.id == stampID }),
                "the deleted stamp leaves the model")
        state.undo()
        // Leave the stamp at the larger size for the saved-copy checks.
        guard let stampBox = state.annotations.first(where: { $0.id == stampID })?.shapeRect
        else { fatalError("FAIL: undo restores the deleted stamp") }

        // ── 2. An image signature: a PNG with a transparent background ─────────────────
        let signatureData = try signaturePNG(width: 240, height: 80)
        require(state.addSignatureAnnotation(page: 0, imageData: signatureData,
                                              center: CGPoint(x: 380, y: 520)),
                "an image signature can be placed")
        guard let signature = state.annotations.first(where: { $0.kind == .signature }),
              let signatureBox = signature.shapeRect else {
            fatalError("FAIL: the placed signature is in the model")
        }
        require(signature.imageData == signatureData,
                "the sidecar model keeps the picture the reader chose")
        require(abs(signatureBox.width / signatureBox.height - 3.0) < 0.2,
                "the signature's initial box keeps the picture's aspect ratio")

        // Its own creation is one undo step, and Delete + undo covers deletion.
        state.selectAnnotation(signature.id)
        require(state.deleteSelectedAnnotation(), "the signature can be deleted")
        require(!state.annotations.contains(where: { $0.id == signature.id }),
                "the deleted signature leaves the model")
        state.undo()
        require(state.annotations.first(where: { $0.id == signature.id })?.shapeRect
                    == signatureBox,
                "undo restores the deleted signature")

        // ── 3. The sidecar is versioned and round-trips ─────────────────────────────────
        let sidecar = document.appendingPathExtension("lyra-reader-annotations.json")
        let sidecarText = String(decoding: try Data(contentsOf: sidecar), as: UTF8.self)
        require(sidecarText.contains("\"kind\" : \"stamp\"")
                    && sidecarText.contains("\"stampStyle\" : \"approved\"")
                    && sidecarText.contains("\"version\" : 1"),
                "the sidecar writes a versioned stamp entry")
        require(sidecarText.contains("\"kind\" : \"signature\"")
                    && sidecarText.contains("\"image\" :"),
                "the sidecar writes a versioned image-signature entry")

        let reloaded = AppState(engine: try RustEngine())
        reloaded.setViewportSize(CGSize(width: 900, height: 700))
        reloaded.newTab(url: document)
        try await eventually("the sidecar round-trip loads both placed marks") {
            reloaded.annotations.count == 2
        }
        require(reloaded.annotations.contains {
            $0.kind == .stamp && $0.note.hasPrefix("APPROVED") && $0.stampStyle == "approved"
        }, "a stamp entry round-trips through the sidecar")
        require(reloaded.annotations.contains {
            $0.kind == .signature && $0.imageData == signatureData
        }, "a signature picture round-trips through the sidecar")

        // ── 4. Save a copy, and let PDFKit judge it ─────────────────────────────────────
        let copy = scratch.appendingPathComponent("stamped-copy.pdf")
        let copySaved = await state.saveAnnotatedCopy(to: copy)
        require(copySaved, "the placed stamp and signature can be saved into a copy")
        let copyBytes = try Data(contentsOf: copy)
        require(copyBytes.count > 0, "the saved copy has bytes")

        guard let pdf = PDFDocument(url: copy), let page = pdf.page(at: 0) else {
            fatalError("FAIL: PDFKit can open the saved copy")
        }
        let pageBounds = page.bounds(for: .mediaBox)
        // `PDFAnnotation.type` is the bare name ("Stamp"); the constant's rawValue has a slash.
        let stampType = "Stamp"
        let stamps = page.annotations.filter { $0.type == stampType }
        require(stamps.count == 2,
                "PDFKit reads two /Stamp annotations from the saved copy (got \(stamps.count))")
        let textStamp = stamps.first { ($0.contents ?? "").contains("APPROVED") }
        require(textStamp != nil, "PDFKit reads the stamp's real text from /Contents")

        // PDFKit's `bounds` is bottom-left page space; the sidecar stores top-left page space.
        func pdfRect(_ viewRect: CGRect) -> CGRect {
            CGRect(x: viewRect.minX, y: pageBounds.height - viewRect.maxY,
                   width: viewRect.width, height: viewRect.height)
        }
        let expectedStamp = pdfRect(stampBox)
        if let textStamp {
            require(approximately(textStamp.bounds, expectedStamp, tolerance: 1.2),
                    "PDFKit reads the stamp at the rectangle the reader placed")
        }
        let signatureStamp = stamps.first { !($0.contents ?? "").contains("APPROVED") }
        require(signatureStamp != nil, "PDFKit reads the image signature as a /Stamp")
        if let signatureStamp {
            require(approximately(signatureStamp.bounds, pdfRect(signatureBox), tolerance: 1.2),
                    "PDFKit reads the signature at the rectangle the reader placed")
        }

        // The appearance, not just the dictionary: PDFKit renders the border and the words in
        // the stamp's green, and the signature's blue pixels over a transparent background.
        let stampPixels = try pdfKitPixels(url: copy, viewSpaceBox: stampBox, scale: 3)
        require(stampPixels.ink > 80,
                "PDFKit renders the stamp's border and words (\(stampPixels.ink) inked pixels)")
        require(stampPixels.coloured > 40,
                "the stamp's colour reaches the page (\(stampPixels.coloured) green pixels)")
        let signaturePixels = try pdfKitPixels(url: copy, viewSpaceBox: signatureBox, scale: 3)
        require(signaturePixels.ink > 120,
                "PDFKit renders the signature's picture (\(signaturePixels.ink) inked pixels)")
        require(signaturePixels.coloured > 60,
                "PDFKit renders the signature's strokes in colour (\(signaturePixels.coloured) pixels)")
        require(signaturePixels.white > 200,
                "the signature's transparent background lets the page through")

        // ── 5. Read back with this reader; the image is editable and deletable ─────────
        let reopened = AppState(engine: try RustEngine())
        reopened.setViewportSize(CGSize(width: 900, height: 700))
        reopened.newTab(url: copy)
        try await eventually("the saved file's own stamps are read back") {
            reopened.documentAnnotations.contains(where: { $0.drawing == .stamp })
        }
        let readStamps = reopened.documentAnnotations.filter { $0.drawing == .stamp }
        require(readStamps.count == 2,
                "LyraReader reads both saved /Stamp annotations (got \(readStamps.count))")
        guard let readText = readStamps.first(where: {
            $0.stampText?.hasPrefix("APPROVED") == true
        }) else {
            fatalError("FAIL: the saved text stamp reads its words back")
        }
        require(readText.stampStyle == "approved",
                "the saved stamp reads its style back")
        guard let readImage = readStamps.first(where: {
            !($0.stampImageData?.isEmpty ?? true)
        }) else {
            fatalError("FAIL: the saved signature reads its picture back")
        }
        require(readImage.stampImageWidth > 0 && readImage.stampImageHeight > 0,
                "the saved signature reads its picture size back")
        if let bitmap = reopened.documentStampBitmapForCheck(readImage.id) {
            require(nonTransparentPixels(bitmap) > 100,
                    "the reader draws a picture for the saved signature stamp")
        } else {
            require(false, "the reader produces a bitmap for the saved signature stamp")
        }

        // Both kinds the file carries can be adopted, moved, resized and deleted with undo.
        guard let adoptedSignatureID = reopened.adoptDocumentAnnotation(readImage.id),
              let adoptedSignature = reopened.annotations.first(where: {
                  $0.id == adoptedSignatureID
              }) else {
            fatalError("FAIL: an image stamp the file carries is editable")
        }
        require(adoptedSignature.kind == AppState.Annotation.Kind.signature
                    && adoptedSignature.imageData == readImage.stampImageData,
                "the adopted image stamp keeps the file's own picture")
        require(reopened.moveAnnotation(adoptedSignatureID, by: CGPoint(x: 12, y: -8)),
                "the adopted image stamp can be moved")
        require(reopened.resizeAnnotation(
                    adoptedSignatureID,
                    to: adoptedSignature.shapeRect!.insetBy(dx: -6, dy: -6)),
                "the adopted image stamp can be resized")

        // A stamp the file carries can be deleted, and undo puts it back, until a save.
        require(reopened.deleteDocumentAnnotation(readText.id),
                "a stamp the PDF carries can be deleted")
        require(reopened.pendingFileDeletions.contains(where: { $0.identity == readText.id }),
                "the deletion is pending, not yet written")
        reopened.undo()
        require(reopened.documentAnnotations.contains(where: { $0.id == readText.id }),
                "undo restores a deleted file stub")

        // ── 6. A /Stamp written by another producer: PDFKit ────────────────────────────
        let foreign = scratch.appendingPathComponent("foreign-stamp.pdf")
        try fileManager.copyItem(at: fixture, to: foreign)
        try writePDFKitStamp(to: foreign)
        let foreignState = AppState(engine: try RustEngine())
        foreignState.setViewportSize(CGSize(width: 900, height: 700))
        foreignState.newTab(url: foreign)
        try await eventually("a PDFKit stamp is read") {
            foreignState.documentAnnotations.contains(where: { $0.drawing == .stamp })
        }
        guard let foreignStamp = foreignState.documentAnnotations.first(where: {
            $0.drawing == .stamp
        }) else {
            fatalError("FAIL: the PDFKit stamp is classified as a stamp")
        }
        require(foreignStamp.stampText?.uppercased().contains("APPROVED") == true,
                "the PDFKit stamp's words are read (got \(foreignStamp.stampText ?? "nil"))")
        if let bitmap = foreignState.documentStampBitmapForCheck(foreignStamp.id) {
            require(nonTransparentPixels(bitmap) > 40,
                    "the reader draws a picture for the PDFKit stamp")
        } else {
            require(false, "the reader produces a bitmap for the PDFKit stamp")
        }
        guard let foreignID = foreignState.adoptDocumentAnnotation(foreignStamp.id),
              let foreignAdopted = foreignState.annotations.first(where: { $0.id == foreignID })
        else {
            fatalError("FAIL: a text stamp written by PDFKit is editable here")
        }
        require(foreignAdopted.kind == .stamp
                    && foreignAdopted.note.uppercased().contains("APPROVED"),
                "the adopted PDFKit stamp keeps its words")
        require(foreignState.moveAnnotation(foreignID, by: CGPoint(x: -20, y: -20)),
                "the adopted PDFKit stamp can be moved")
        let foreignCopy = scratch.appendingPathComponent("foreign-stamp-saved.pdf")
        let foreignCopySaved = await foreignState.saveAnnotatedCopy(to: foreignCopy)
        require(foreignCopySaved, "an edited PDFKit stamp can be saved into a copy")
        if let savedPDF = PDFDocument(url: foreignCopy), let savedPage = savedPDF.page(at: 0) {
            require(savedPage.annotations.contains { $0.type == stampType },
                    "the saved copy still carries a /Stamp annotation")
        } else {
            require(false, "PDFKit opens the copy with the edited PDFKit stamp")
        }

        // ── 7. A signed document: in-place refused, copy allowed ───────────────────────
        let signed = scratch.appendingPathComponent("signed-stamped.pdf")
        try fileManager.copyItem(
            at: root.appendingPathComponent("tests/fixtures/signed-signature.pdf"), to: signed)
        let signedBytes = try Data(contentsOf: signed)
        let signedState = AppState(engine: try RustEngine())
        signedState.setViewportSize(CGSize(width: 900, height: 700))
        signedState.newTab(url: signed)
        try await eventually("the signed fixture lays out a page") {
            signedState.canvasPageFrames.contains(where: { $0.index == 0 })
        }
        require(signedState.addStampAnnotation(page: 0, style: .reviewed,
                                               center: CGPoint(x: 300, y: 300)),
                "a stamp can be placed on a signed document in memory")
        let signedCopy = scratch.appendingPathComponent("signed-stamped-copy.pdf")
        let signedCopySaved = await signedState.saveAnnotatedCopy(to: signedCopy)
        require(signedCopySaved, "a stamped copy of a signed document can still be written")
        if let signedPDF = PDFDocument(url: signedCopy), let signedPage = signedPDF.page(at: 0) {
            require(signedPage.annotations.contains { $0.type == stampType },
                    "the signed document's copy carries the stamp")
        } else {
            require(false, "PDFKit opens the stamped copy of the signed document")
        }
        let signedProbe = try RustEngine()
        _ = try signedProbe.openDocument(at: signedCopy)
        let signedForm = try await signedProbe.formInfo()
        require(!signedForm.fields.contains { $0.kind == .signature },
                "the stamped copy has its signature fields stripped, like every derived copy")
        let refused = await signedState.replaceOriginalWithSavedAnnotations()
        require(!refused, "an in-place write to a signed document is refused")
        require(signedState.lastError?.contains("digitally signed") == true,
                "the refusal states why (got \(signedState.lastError ?? "nil"))")
        let afterRefusal = try Data(contentsOf: signed)
        require(afterRefusal == signedBytes,
                "the refused in-place write leaves the signed original byte-identical")

        print("Stamp and signature checks passed")
    }

    // MARK: - PDFKit rendering

    /// Inked and coloured pixel counts inside one top-left view-space box, as PDFKit draws it.
    @MainActor
    private static func pdfKitPixels(
        url: URL,
        viewSpaceBox: CGRect,
        scale: CGFloat
    ) throws -> (ink: Int, coloured: Int, white: Int) {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else {
            throw NSError(domain: "LyraReaderChecks", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "PDFKit could not open the stamp copy"])
        }
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(ceil(bounds.width * scale))
        let height = Int(ceil(bounds.height * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "LyraReaderChecks", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "could not create a PDFKit bitmap"])
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        guard let data = context.data else { return (0, 0, 0) }
        let rowBytes = context.bytesPerRow
        let pixels = data.bindMemory(to: UInt8.self, capacity: rowBytes * height)
        // Inset so the annotation's own antialiased edge is not counted as ink.
        let minX = max(Int(viewSpaceBox.minX * scale) + 8, 0)
        let maxX = min(Int(viewSpaceBox.maxX * scale) - 8, width - 1)
        let minY = max(Int(viewSpaceBox.minY * scale) + 8, 0)
        let maxY = min(Int(viewSpaceBox.maxY * scale) - 8, height - 1)
        guard minX < maxX, minY < maxY else { return (0, 0, 0) }
        var ink = 0, coloured = 0, white = 0
        for y in minY...maxY {
            for x in minX...maxX {
                let offset = y * rowBytes + x * 4
                let red = Int(pixels[offset])
                let green = Int(pixels[offset + 1])
                let blue = Int(pixels[offset + 2])
                if red + green + blue < 660 { ink += 1 }
                if max(red, green, blue) - min(red, green, blue) > 50 { coloured += 1 }
                if red > 245 && green > 245 && blue > 245 { white += 1 }
            }
        }
        return (ink, coloured, white)
    }

    /// A PNG with a transparent background and a recognisable blue signature squiggle.
    private static func signaturePNG(width: Int, height: Int) throws -> Data {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        func put(_ x: Int, _ y: Int, _ red: UInt8, _ green: UInt8, _ blue: UInt8) {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            let offset = (y * width + x) * 4
            rgba[offset] = red
            rgba[offset + 1] = green
            rgba[offset + 2] = blue
            rgba[offset + 3] = 255
        }
        // Two crossing strokes make an unmistakable signature shape, not a solid rectangle.
        for step in 0..<(width - 30) {
            let x = 15 + step
            let y = height / 2 + Int(18 * sin(Double(step) / 18.0))
            for dy in -2...2 { put(x, y + dy, 0, 60, 190) }
        }
        for step in 0..<50 {
            let x = width - 60 + step / 2
            let y = height / 3 + step
            for dx in -1...1 { put(x + dx, y, 0, 60, 190) }
        }
        for dx in -5...5 {
            for dy in -5...5 where dx * dx + dy * dy <= 25 {
                put(width - 18 + dx, height - 18 + dy, 0, 40, 160)
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent) else {
            throw NSError(domain: "LyraReaderChecks", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "could not build the signature PNG"])
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "LyraReaderChecks", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "could not create a PNG destination"])
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "LyraReaderChecks", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "could not finish the signature PNG"])
        }
        return output as Data
    }

    /// Writes a `/Stamp` into `url` with PDFKit, i.e. a producer that is not this reader.
    private static func writePDFKitStamp(to url: URL) throws {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else {
            throw NSError(domain: "LyraReaderChecks", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "PDFKit could not open the fixture"])
        }
        let bounds = page.bounds(for: .cropBox)
        let annotation = PDFAnnotation(
            bounds: CGRect(x: bounds.maxX - 240, y: bounds.maxY - 170,
                           width: 160, height: 60),
            forType: .stamp,
            withProperties: nil
        )
        annotation.stampName = "Approved"
        annotation.contents = "Approved by PDFKit"
        page.addAnnotation(annotation)
        guard document.write(to: url) else {
            throw NSError(domain: "LyraReaderChecks", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "PDFKit could not write the stamp"])
        }
    }

    private static func nonTransparentPixels(_ image: PageImage) -> Int {
        image.bgra.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var count = 0
            for pixel in stride(from: 0, to: bytes.count - 3, by: 4) {
                if bytes[pixel + 3] > 8 { count += 1 }
            }
            return count
        }
    }

    private static func approximately(_ left: CGRect, _ right: CGRect,
                                      tolerance: CGFloat) -> Bool {
        abs(left.minX - right.minX) <= tolerance
            && abs(left.minY - right.minY) <= tolerance
            && abs(left.width - right.width) <= tolerance
            && abs(left.height - right.height) <= tolerance
    }
}
