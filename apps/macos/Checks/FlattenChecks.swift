import AppKit
import CoreGraphics
import Foundation
import LyraReaderKit
import PDFKit

/// "Export as Flattened Copy": the appearance export, end to end.
///
/// The committed `tests/fixtures/flatten.pdf` carries one of each annotation kind the command
/// promises to bake — a highlight with an `/AP`, an ink stroke, a text box, a text stamp, an
/// image signature with a `/SMask`, a line with an arrowhead — plus a filled text widget. The
/// AP-less case (the shape PDFium writes for LyraReader's own markup) is exercised separately
/// against `annotated-inline-notes.pdf`. This check proves:
///
/// * the output reopens with no annotations, no widgets and no `/AcroForm`, at the same page
///   count, and the source is byte-identical;
/// * the output's rendering is the same picture as the input's annotated rendering within the
///   tolerance explained below;
/// * the text layer survives, and the baked text boxes/stamps/field values become extractable;
/// * PDFKit agrees: it reports no annotations and no widget annotations;
/// * a sticky note and a link are kept and reported instead of being silently destroyed;
/// * a signed document produces a copy with its signature fields stripped;
/// * an XFA document refuses with the XFA reason and writes no file;
/// * the save panel copy is honest about the limits (not tamper-proof, not signature detection).
extension ReaderChecks {
    @MainActor static func flattenChecks(root: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-reader-flatten-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Set LYRA_KEEP_FLATTEN_SCRATCH=1 to inspect the 200% signature crop this check writes.
        defer {
            if ProcessInfo.processInfo.environment["LYRA_KEEP_FLATTEN_SCRATCH"] == nil {
                try? fileManager.removeItem(at: scratch)
            } else {
                print("flatten scratch kept at \(scratch.path)")
            }
        }

        let fixture = root.appendingPathComponent("tests/fixtures/flatten.pdf")
        let source = scratch.appendingPathComponent("source.pdf")
        try fileManager.copyItem(at: fixture, to: source)
        let sourceBytes = try Data(contentsOf: source)

        // ── The "before" picture: the same page with its annotations burned in ──────────────
        let beforeEngine = try RustEngine()
        let beforeLoaded = try beforeEngine.openDocument(at: source)
        require(beforeLoaded.pageCount == 1, "the flatten fixture is one page")
        let scale: CGFloat = 2
        let beforeImage = try await beforeEngine.renderThumbnail(0, scale: scale)
        let beforeSignature = try signatureColouredPixels(beforeImage, scale: scale)
        require(beforeSignature > 40,
                "the fixture's image signature is visible before flattening (\(beforeSignature) px)")

        // ── Flatten the copy ─────────────────────────────────────────────────────────────────
        let destination = scratch.appendingPathComponent("flattened.pdf")
        let engine = try RustEngine()
        _ = try engine.openDocument(at: source)
        let report = try await engine.flattenToCopy(to: destination)

        require(report.pages == 1, "the flattened copy has one page, not \(report.pages)")
        require(report.flattenedAnnotations == 6,
                "all six annotations were baked (got \(report.flattenedAnnotations))")
        require(report.flattenedFields == 1,
                "the filled text field was baked (got \(report.flattenedFields))")
        let annotationKinds = Dictionary(
            uniqueKeysWithValues: report.flattenedAnnotationKinds.map { ($0.kind, $0.count) })
        require(annotationKinds["Highlight"] == 1, "the highlight was baked: \(annotationKinds)")
        require(annotationKinds["Ink"] == 1, "the ink stroke was baked: \(annotationKinds)")
        require(annotationKinds["FreeText"] == 1, "the text box was baked: \(annotationKinds)")
        require(annotationKinds["Stamp"] == 2, "the text stamp and image signature were baked")
        require(annotationKinds["Line"] == 1, "the line with its arrowhead was baked")
        require(report.flattenedFieldKinds.map(\.kind) == ["text"],
                "the field kind is reported as text")
        require(report.keptAnnotations.isEmpty && report.keptFields.isEmpty,
                "nothing had to be kept on the clean fixture")
        require(report.signatureFieldsRemoved == 0,
                "an ordinary form has no signature field to remove")
        require(report.commentsNotCarried == 3,
                "the three comments on flattened marks are counted, not silently lost "
                + "(got \(report.commentsNotCarried))")

        // ── The source is never touched ─────────────────────────────────────────────────────
        let sourceAfter = try Data(contentsOf: source)
        require(sourceAfter == sourceBytes,
                "the source file is byte-identical after the flattened copy")

        // ── No annotations, no widgets, no /AcroForm, same page count ───────────────────────
        let outputBytes = try Data(contentsOf: destination)
        require(outputBytes.count > 0, "the flattened copy has bytes")
        let outputText = String(decoding: outputBytes, as: UTF8.self)
        require(!outputText.contains("/AcroForm"),
                "the output has no /AcroForm entry")
        require(!outputText.contains("/Widget"),
                "the output has no form widget dictionaries")
        let reopened = try RustEngine()
        let reopenedLoaded = try reopened.openDocument(at: destination)
        require(reopenedLoaded.pageCount == 1, "reopening the output sees one page")
        let annotations = try await reopened.annotations()
        require(annotations.isEmpty,
                "reopening the output with the reader finds no annotations "
                + "(got \(annotations.count))")
        let form = try await reopened.formInfo()
        require(form.fields.isEmpty, "reopening the output finds no form fields")
        require(form.refusal == nil, "the output has no form refusal to report")

        // ── The text layer survived, and baked appearance text is extractable ───────────────
        let text = try await reopened.textPage(0).text
        require(text.contains("LyraReader flatten fixture"),
                "the fixture's title is still selectable")
        require(text.contains("The quick brown fox jumps over the lazy dog."),
                "the body line is still selectable and searchable")
        require(text.contains("APPROVED"),
                "the baked text stamp's words are extractable from the page")
        require(text.contains("Text box: baked into the page"),
                "the baked text box's words are extractable from the page")
        require(text.contains("Ada Lovelace"),
                "the baked form value is extractable from the page")

        // ── PDFKit: the viewer Preview uses sees no annotations and no widgets ─────────────
        guard let pdf = PDFDocument(url: destination) else {
            fatalError("FAIL: PDFKit could not open the flattened copy")
        }
        var pdfKitAnnotations = 0
        var pdfKitWidgets = 0
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            pdfKitAnnotations += page.annotations.count
            pdfKitWidgets += page.annotations.filter { $0.type == "Widget" }.count
        }
        require(pdfKitAnnotations == 0,
                "PDFKit reports no annotations (got \(pdfKitAnnotations))")
        require(pdfKitWidgets == 0, "PDFKit reports no form widgets (got \(pdfKitWidgets))")

        // ── The same picture, within the anti-aliasing tolerance ────────────────────────────
        //
        // PDFium renders the unflattened page in its annotation pass and the flattened page as
        // page content. Both paths use the same appearance streams and the same rasteriser, but
        // a form XObject's edge pixels and the transparency group's compositing can land on a
        // slightly different coverage than the annotation pass. The tolerance therefore allows
        // a per-channel delta of 8 in at most 0.5% of pixels and a mean per-channel delta of at
        // most 1.5 over the whole page. A lost highlight/stamp/signature moves far more than
        // that; a different anti-aliased edge does not.
        let afterImage = try await reopened.renderThumbnail(0, scale: scale)
        let difference = try pixelDifference(beforeImage, afterImage)
        print(String(
            format: "flatten render: %.3f%% pixels over delta 8, mean delta %.3f, max delta %d",
            difference.mismatchFraction * 100, difference.meanDelta, difference.maxDelta))

        if ProcessInfo.processInfo.environment["LYRA_KEEP_FLATTEN_SCRATCH"] != nil {
            try writePNG(beforeImage, to: scratch.appendingPathComponent("before-200.png"))
            try writePNG(afterImage, to: scratch.appendingPathComponent("after-200.png"))
            let crop = crop(afterImage, viewRect: CGRect(x: 300, y: 842 - 470, width: 250, height: 120))
            try writePNG(crop, to: scratch.appendingPathComponent("signature-200.png"))
            for (name, rect) in [
                ("highlight-ap", CGRect(x: 72, y: 842 - 701, width: 388, height: 15)),
                ("highlight-synth", CGRect(x: 72, y: 842 - 686, width: 388, height: 15)),
                ("ink", CGRect(x: 80, y: 842 - 500, width: 170, height: 80)),
                ("text-box", CGRect(x: 72, y: 842 - 350, width: 248, height: 50)),
                ("text-stamp", CGRect(x: 350, y: 842 - 350, width: 180, height: 50)),
                ("image-signature", CGRect(x: 330, y: 842 - 450, width: 200, height: 70)),
                ("line", CGRect(x: 70, y: 842 - 290, width: 190, height: 60)),
                ("field", CGRect(x: 72, y: 842 - 586, width: 228, height: 26)),
            ] {
                let region = try regionDifference(beforeImage, afterImage, scale: scale, viewRect: rect)
                print(String(format: "flatten region %@: %.3f%% over 8, mean %.3f",
                             name, region.mismatchFraction * 100, region.meanDelta))
            }
        }

        require(difference.mismatchFraction <= 0.005,
                "at most 0.5% of pixels differ by more than 8 "
                + "(got \(String(format: "%.3f%%", difference.mismatchFraction * 100)))")
        require(difference.meanDelta <= 1.5,
                "the mean per-channel delta is at most 1.5 "
                + "(got \(String(format: "%.3f", difference.meanDelta)))")

        // The signature itself still has its ink and colour in the flattened page.
        let afterSignature = try signatureColouredPixels(afterImage, scale: scale)
        require(afterSignature > 40,
                "the flattened signature still paints its coloured strokes "
                + "(\(afterSignature) px, before \(beforeSignature))")
        let fieldInk = try darkPixels(
            afterImage, scale: scale,
            viewRect: CGRect(x: 78, y: 842 - 583, width: 216, height: 20))
        require(fieldInk > 60,
                "the baked form value paints text inside the field (\(fieldInk) dark px)")

        // ── Every fillable field kind: text, check box, radio, combo and list ──────────────
        //
        // The dedicated fixture above only carries a text field. `form-fields.pdf` has all
        // five fillable kinds plus an unsigned signature field, and its widgets carry the
        // appearances another producer wrote. Flattening must bake the widgets and remove the
        // signature field; the same visual tolerance applies to the whole page.
        let formsSource = scratch.appendingPathComponent("forms.pdf")
        try fileManager.copyItem(
            at: root.appendingPathComponent("tests/fixtures/form-fields.pdf"), to: formsSource)
        let formsBefore = try RustEngine()
        _ = try formsBefore.openDocument(at: formsSource)
        let formsBeforeImage = try await formsBefore.renderThumbnail(0, scale: scale)
        let formsDestination = scratch.appendingPathComponent("forms-flattened.pdf")
        let formsEngine = try RustEngine()
        _ = try formsEngine.openDocument(at: formsSource)
        let formsReport = try await formsEngine.flattenToCopy(to: formsDestination)
        require(formsReport.flattenedFields == 7,
                "the seven fillable fields are baked (got \(formsReport.flattenedFields))")
        let formKinds = Dictionary(
            uniqueKeysWithValues: formsReport.flattenedFieldKinds.map { ($0.kind, $0.count) })
        require(formKinds["text"] == 3, "three text fields are baked: \(formKinds)")
        require(formKinds["checkBox"] == 1, "the check box is baked: \(formKinds)")
        require(formKinds["radio"] == 1, "the radio group is baked: \(formKinds)")
        require(formKinds["comboBox"] == 1, "the combo box is baked: \(formKinds)")
        require(formKinds["listBox"] == 1, "the list box is baked: \(formKinds)")
        require(formsReport.signatureFieldsRemoved == 1,
                "the unsigned signature field is removed and counted")
        let formsReader = try RustEngine()
        _ = try formsReader.openDocument(at: formsDestination)
        let formsInfo = try await formsReader.formInfo()
        require(formsInfo.fields.isEmpty, "the flattened form has no fillable fields")
        let formsAnnotations = try await formsReader.annotations()
        require(formsAnnotations.isEmpty,
                "the flattened form has no widgets left (got \(formsAnnotations.count))")
        let formsAfterImage = try await formsReader.renderThumbnail(0, scale: scale)
        let formsDifference = try pixelDifference(formsBeforeImage, formsAfterImage)
        print(String(
            format: "flatten form render: %.3f%% over delta 8, mean %.3f",
            formsDifference.mismatchFraction * 100, formsDifference.meanDelta))
        require(formsDifference.mismatchFraction <= 0.005,
                "the form page's widgets bake into an identical picture "
                + "(got \(formsDifference.mismatchFraction * 100)% over 8)")
        require(formsDifference.meanDelta <= 1.5,
                "the form page's mean delta is at most 1.5 "
                + "(got \(formsDifference.meanDelta))")

        // ── A sticky note is kept, with its text, and reported ──────────────────────────────
        let notesSource = scratch.appendingPathComponent("notes.pdf")
        try fileManager.copyItem(
            at: root.appendingPathComponent("tests/fixtures/annotated-inline-notes.pdf"),
            to: notesSource)
        let notesDestination = scratch.appendingPathComponent("notes-flattened.pdf")
        let notesEngine = try RustEngine()
        _ = try notesEngine.openDocument(at: notesSource)
        let notesReport = try await notesEngine.flattenToCopy(to: notesDestination)
        require(notesReport.stickyNotesKept == 1,
                "the sticky note is kept and counted (got \(notesReport.stickyNotesKept))")
        require(notesReport.keptAnnotations.contains {
            $0.kind == "Text" && $0.reason.contains("sticky note")
        }, "the report says why the sticky note stayed: \(notesReport.keptAnnotations)")
        require(notesReport.keptAnnotations.contains {
            $0.kind == "Highlight" && $0.reason.contains("hidden")
        }, "the report says why the Hidden highlight stayed: \(notesReport.keptAnnotations)")
        let notesReader = try RustEngine()
        _ = try notesReader.openDocument(at: notesDestination)
        let kept = try await notesReader.annotations()
        require(kept.count == 2,
                "the sticky note and the hidden highlight survive (got \(kept.map(\.kind)))")
        guard let keptNote = kept.first(where: { $0.kind == "text" }) else {
            fatalError("FAIL: the sticky note did not survive")
        }
        require(keptNote.contents == "A separate sticky note.",
                "the sticky note's text survives: \(keptNote.contents ?? "nil")")
        guard let notesPDF = PDFDocument(url: notesDestination),
              let notesPage = notesPDF.page(at: 0) else {
            fatalError("FAIL: PDFKit could not open the flattened notes fixture")
        }
        require(notesPage.annotations.count == 2,
                "PDFKit sees the kept sticky note and hidden highlight "
                + "(got \(notesPage.annotations.count))")
        require(notesPage.annotations.contains {
            $0.contents?.contains("separate sticky note") == true
        }, "PDFKit reads the sticky note's text from the kept annotation")

        // The fixture's markup annotations have no /AP; PDFium does not synthesise one when it
        // renders annotations. Flattening must still paint them from /QuadPoints and /C, not
        // drop them. Sample the first highlighted line in the output: it must carry tinted
        // pixels that are part of the page now.
        let notesAfterImage = try await notesReader.renderThumbnail(0, scale: scale)
        let tinted = try countPixels(
            notesAfterImage, scale: scale,
            viewRect: CGRect(x: 72, y: 842 - 701, width: 388, height: 15)
        ) { red, green, blue in
            max(red, green, blue) - min(red, green, blue) > 12
        }
        require(tinted > 500,
                "an /AP-less highlight is painted from its quads into the page "
                + "(\(tinted) tinted pixels)")

        // ── Links are navigation and are kept as annotations ───────────────────────────────
        let linksSource = scratch.appendingPathComponent("links.pdf")
        try fileManager.copyItem(
            at: root.appendingPathComponent("tests/fixtures/link-borders.pdf"), to: linksSource)
        let linksDestination = scratch.appendingPathComponent("links-flattened.pdf")
        let linksEngine = try RustEngine()
        _ = try linksEngine.openDocument(at: linksSource)
        let linksReport = try await linksEngine.flattenToCopy(to: linksDestination)
        require(linksReport.linksKept == 5,
                "all five links are kept (got \(linksReport.linksKept))")
        require(linksReport.flattenedAnnotations == 1,
                "the one highlight was baked")
        guard let linksPDF = PDFDocument(url: linksDestination),
              let linksPage = linksPDF.page(at: 0) else {
            fatalError("FAIL: PDFKit could not open the flattened link fixture")
        }
        require(linksPage.annotations.count == 5,
                "PDFKit sees the five kept links (got \(linksPage.annotations.count))")
        require(linksPage.annotations.allSatisfy { $0.type == "Link" },
                "every surviving annotation is a /Link")

        // ── A signed document: copy allowed, signature fields stripped ──────────────────────
        let signedSource = scratch.appendingPathComponent("signed.pdf")
        try fileManager.copyItem(
            at: root.appendingPathComponent("tests/fixtures/signed-signature.pdf"),
            to: signedSource)
        let signedBytes = try Data(contentsOf: signedSource)
        let signedDestination = scratch.appendingPathComponent("signed-flattened.pdf")
        let signedEngine = try RustEngine()
        let signedLoaded = try signedEngine.openDocument(at: signedSource)
        require(signedLoaded.signature.signed, "the signed fixture is detected as signed")
        let signedReport = try await signedEngine.flattenToCopy(to: signedDestination)
        require(signedReport.signatureFieldsRemoved >= 1,
                "the signature field is removed from the derived copy "
                + "(got \(signedReport.signatureFieldsRemoved))")
        let signedAfter = try Data(contentsOf: signedSource)
        require(signedAfter == signedBytes,
                "the signed original is byte-identical after the copy")
        let signedReader = try RustEngine()
        _ = try signedReader.openDocument(at: signedDestination)
        let signedForm = try await signedReader.formInfo()
        require(!signedForm.fields.contains { $0.kind == .signature },
                "the flattened copy has no signature field")
        let signedAnnotations = try await signedReader.annotations()
        require(signedAnnotations.isEmpty,
                "the flattened signed copy has no annotation left")

        // A certification (DocMDP) policy has no signature field but still makes the file
        // signed. The flattened copy is a derived copy: the policy must not come with it.
        let docMdpSource = scratch.appendingPathComponent("docmdp.pdf")
        try fileManager.copyItem(
            at: root.appendingPathComponent("tests/fixtures/signed-docmdp.pdf"),
            to: docMdpSource)
        let docMdpBytes = try Data(contentsOf: docMdpSource)
        let docMdpDestination = scratch.appendingPathComponent("docmdp-flattened.pdf")
        let docMdpEngine = try RustEngine()
        let docMdpLoaded = try docMdpEngine.openDocument(at: docMdpSource)
        require(docMdpLoaded.signature.signed, "the DocMDP fixture is detected as signed")
        _ = try await docMdpEngine.flattenToCopy(to: docMdpDestination)
        let docMdpAfter = try Data(contentsOf: docMdpSource)
        require(docMdpAfter == docMdpBytes,
                "the DocMDP original is byte-identical after the copy")
        let docMdpReader = try RustEngine()
        let docMdpReopened = try docMdpReader.openDocument(at: docMdpDestination)
        require(!docMdpReopened.signature.signed,
                "the flattened DocMDP copy is not signed")

        // ── XFA refuses with the existing reason and writes nothing ────────────────────────
        let xfaSource = scratch.appendingPathComponent("xfa.pdf")
        try fileManager.copyItem(
            at: root.appendingPathComponent("tests/fixtures/xfa-refusal.pdf"), to: xfaSource)
        let xfaDestination = scratch.appendingPathComponent("xfa-flattened.pdf")
        let xfaEngine = try RustEngine()
        let xfaLoaded = try xfaEngine.openDocument(at: xfaSource)
        require(xfaLoaded.xfa.isXfa, "the fixture is detected as XFA")
        var refused = false
        do {
            _ = try await xfaEngine.flattenToCopy(to: xfaDestination)
        } catch {
            refused = true
            let message = String(describing: error)
            require(message.localizedCaseInsensitiveContains("XFA"),
                    "the refusal carries the XFA reason: \(message)")
            require(message.localizedCaseInsensitiveContains("read-only"),
                    "the refusal says the document is read-only")
        }
        require(refused, "an XFA document is refused")
        require(!fileManager.fileExists(atPath: xfaDestination.path),
                "the refused XFA flatten wrote no partial file")

        // ── The shell's honest copy and the report ─────────────────────────────────────────
        require(AppState.flattenPanelMessage.contains("not tamper-proof"),
                "the save-panel explanation says the result is not tamper-proof")
        require(AppState.flattenPanelMessage.contains("still editable"),
                "the explanation says the painted content is still editable")
        require(AppState.flattenPanelMessage.contains("digital signature"),
                "the explanation names the only thing that detects later changes")
        require(AppState.flattenPanelMessage.contains("original is not modified"),
                "the explanation says the source is not modified")
        require(AppState.flattenPanelMessage.contains("sticky notes")
                && AppState.flattenPanelMessage.contains("Links"),
                "the explanation names the annotations that stay")

        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 900, height: 700))
        state.newTab(url: source)
        try await eventually("the flatten fixture opens in the shell") {
            state.document != nil && state.formLoadCompleted && !state.formLoading
        }
        require(state.canFlattenDocument, "the menu item is available for an ordinary PDF")
        let stateDestination = scratch.appendingPathComponent("state-flattened.pdf")
        let saved = await state.flattenToCopy(to: stateDestination)
        require(saved, "the shell's flatten command succeeds: \(state.lastError ?? "nil")")
        require(state.lastFlattenReport?.flattenedAnnotations == 6,
                "the shell keeps the report for its status line")
        require(state.statusMessage.contains("original is unchanged"),
                "the status line says the original is unchanged: \(state.statusMessage)")
        require(state.statusMessage.contains("not tamper-proof") == false,
                "the short status line does not overclaim protection")
    }

    // MARK: - Pixel helpers

    /// Per-channel differences between two annotated page renders.
    private static func pixelDifference(
        _ before: PageImage, _ after: PageImage
    ) throws -> (mismatchFraction: Double, meanDelta: Double, maxDelta: Int) {
        guard before.pixelWidth == after.pixelWidth,
              before.pixelHeight == after.pixelHeight else {
            throw NSError(domain: "LyraReaderChecks", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "before/after renders have different sizes",
            ])
        }
        let count = before.pixelWidth * before.pixelHeight
        guard count > 0 else {
            throw NSError(domain: "LyraReaderChecks", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "empty page render",
            ])
        }
        var mismatched = 0
        var total = 0
        var maximum = 0
        before.bgra.withUnsafeBytes { beforeRaw in
            after.bgra.withUnsafeBytes { afterRaw in
                let a = beforeRaw.bindMemory(to: UInt8.self)
                let b = afterRaw.bindMemory(to: UInt8.self)
                for pixel in 0..<count {
                    let offset = pixel * 4
                    var largest = 0
                    for channel in 0..<3 {
                        let delta = abs(Int(a[offset + channel]) - Int(b[offset + channel]))
                        largest = max(largest, delta)
                    }
                    total += largest
                    maximum = max(maximum, largest)
                    if largest > 8 { mismatched += 1 }
                }
            }
        }
        return (Double(mismatched) / Double(count), Double(total) / Double(count), maximum)
    }

    /// Per-channel differences inside one view-space rectangle.
    private static func regionDifference(
        _ before: PageImage, _ after: PageImage, scale: CGFloat, viewRect: CGRect
    ) throws -> (mismatchFraction: Double, meanDelta: Double) {
        let minX = max(0, Int(viewRect.minX * scale))
        let minY = max(0, Int(viewRect.minY * scale))
        let maxX = min(before.pixelWidth - 1, Int(viewRect.maxX * scale))
        let maxY = min(before.pixelHeight - 1, Int(viewRect.maxY * scale))
        guard minX < maxX, minY < maxY else { return (0, 0) }
        var mismatched = 0
        var total = 0
        var count = 0
        before.bgra.withUnsafeBytes { beforeRaw in
            after.bgra.withUnsafeBytes { afterRaw in
                let a = beforeRaw.bindMemory(to: UInt8.self)
                let b = afterRaw.bindMemory(to: UInt8.self)
                for y in minY...maxY {
                    for x in minX...maxX {
                        let offset = (y * before.pixelWidth + x) * 4
                        var largest = 0
                        for channel in 0..<3 {
                            let delta = abs(Int(a[offset + channel]) - Int(b[offset + channel]))
                            largest = max(largest, delta)
                        }
                        total += largest
                        count += 1
                        if largest > 8 { mismatched += 1 }
                    }
                }
            }
        }
        return (Double(mismatched) / Double(max(count, 1)), Double(total) / Double(max(count, 1)))
    }

    /// Coloured ink inside the image-signature rectangle, in view-space points.
    private static func signatureColouredPixels(_ image: PageImage, scale: CGFloat) throws -> Int {
        let rect = CGRect(x: 330, y: 842 - 450, width: 200, height: 70)
        return try countPixels(image, scale: scale, viewRect: rect) { red, green, blue in
            blue > 120 && blue - red > 50 && blue - green > 20
        }
    }

    private static func darkPixels(
        _ image: PageImage, scale: CGFloat, viewRect: CGRect
    ) throws -> Int {
        try countPixels(image, scale: scale, viewRect: viewRect) { red, green, blue in
            red < 90 && green < 90 && blue < 90
        }
    }

    private static func countPixels(
        _ image: PageImage,
        scale: CGFloat,
        viewRect: CGRect,
        predicate: (Int, Int, Int) -> Bool
    ) throws -> Int {
        let minX = max(0, Int(viewRect.minX * scale))
        let minY = max(0, Int(viewRect.minY * scale))
        let maxX = min(image.pixelWidth - 1, Int(viewRect.maxX * scale))
        let maxY = min(image.pixelHeight - 1, Int(viewRect.maxY * scale))
        guard minX < maxX, minY < maxY else { return 0 }
        var count = 0
        image.bgra.withUnsafeBytes { raw in
            let pixels = raw.bindMemory(to: UInt8.self)
            for y in minY...maxY {
                for x in minX...maxX {
                    let offset = (y * image.pixelWidth + x) * 4
                    let red = Int(pixels[offset + 2])
                    let green = Int(pixels[offset + 1])
                    let blue = Int(pixels[offset])
                    if predicate(red, green, blue) { count += 1 }
                }
            }
        }
        return count
    }

    private static func crop(_ image: PageImage, viewRect: CGRect) -> PageImage {
        let scale = CGFloat(image.pixelWidth) / image.pointSize.width
        let x = max(0, Int(viewRect.minX * scale))
        let y = max(0, Int(viewRect.minY * scale))
        let width = min(image.pixelWidth - x, Int(viewRect.width * scale))
        let height = min(image.pixelHeight - y, Int(viewRect.height * scale))
        guard width > 0, height > 0 else { return image }
        var bytes = Data(count: width * height * 4)
        bytes.withUnsafeMutableBytes { destinationRaw in
            image.bgra.withUnsafeBytes { sourceRaw in
                let source = sourceRaw.bindMemory(to: UInt8.self)
                let destination = destinationRaw.bindMemory(to: UInt8.self)
                for row in 0..<height {
                    let sourceOffset = ((y + row) * image.pixelWidth + x) * 4
                    let destinationOffset = row * width * 4
                    for index in 0..<(width * 4) {
                        destination[destinationOffset + index] = source[sourceOffset + index]
                    }
                }
            }
        }
        return PageImage(
            pixelWidth: width, pixelHeight: height,
            pointSize: CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale),
            bgra: bytes, generation: image.generation
        )
    }

    private static func writePNG(_ image: PageImage, to url: URL) throws {
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: image.bgra as CFData),
              let cgImage = CGImage(
                width: image.pixelWidth, height: image.pixelHeight,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.pixelWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        else {
            throw NSError(domain: "LyraReaderChecks", code: 22, userInfo: [
                NSLocalizedDescriptionKey: "could not build the evidence image",
            ])
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "LyraReaderChecks", code: 23, userInfo: [
                NSLocalizedDescriptionKey: "could not encode the evidence PNG",
            ])
        }
        try png.write(to: url)
    }
}
