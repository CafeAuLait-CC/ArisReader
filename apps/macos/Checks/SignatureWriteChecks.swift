import AppKit
import LyraReaderKit
import LyraReaderBindings
import Foundation

/// Signature-aware write policy.
///
/// A document that carries a digital signature is read-only **in place**: every command that
/// would rewrite the file is refused, while commands whose destination is a new file (extract,
/// merge, split, save edited copy, filled-form/properties copy, redaction to a copy, annotation
/// copy export) are allowed. Those copies are stripped of signature fields, because their bytes
/// are no longer covered by the signature. An unsigned document is written exactly as before,
/// except that a save which removes annotations prunes the file so the removed content cannot be
/// recovered from the bytes.
///
/// The checks run through the real `RustEngine`/`AppState`; the read-only refusal is asserted on
/// the engine itself (not only on the disabled buttons) so a UI regression cannot hide a write.
extension ReaderChecks {
    @MainActor static func signatureWriteChecks(root: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-reader-signatures-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        func copy(_ name: String, _ local: String) throws -> URL {
            let destination = scratch.appendingPathComponent(local)
            try fileManager.copyItem(
                at: root.appendingPathComponent("tests/fixtures/\(name)"), to: destination)
            return destination
        }
        func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }
        func contains(_ data: Data, _ needle: String) -> Bool {
            data.range(of: Data(needle.utf8)) != nil
        }
        func engine() throws -> RustEngine { try RustEngine() }

        // ── 1. Detection and its evidence ────────────────────────────────────────────────
        let signedURL = try copy("signed-signature.pdf", "signed-signature.pdf")
        let docMdpURL = try copy("signed-docmdp.pdf", "signed-docmdp.pdf")
        let unsignedURL = try copy("text-page.pdf", "unsigned.pdf")
        let formURL = try copy("form-fields.pdf", "unsigned-form.pdf")

        let signedDocument = try engine().openDocument(at: signedURL)
        require(signedDocument.signature.signed,
                "a /SigFlags + signed /FT /Sig field detects as signed")
        let signedKinds = signedDocument.signature.evidence.map(\.kind)
        require(signedKinds.contains("sigFlags"),
                "the evidence names the signature flags (got \(signedKinds))")
        require(signedKinds.contains("signatureField"),
                "the evidence names the signed signature field (got \(signedKinds))")
        let signedReason = signedDocument.signature.readOnlyReason ?? ""
        require(signedReason.contains("digitally signed") && signedReason.contains("read-only"),
                "the read-only reason is a sentence a person can read: \(signedReason)")
        require(signedReason.contains("signature flags"),
                "the reason carries the evidence: \(signedReason)")

        let docMdpDocument = try engine().openDocument(at: docMdpURL)
        require(docMdpDocument.signature.signed,
                "a /Perms /DocMDP catalog detects as signed")
        require(docMdpDocument.signature.evidence.map(\.kind) == ["docMdp"],
                "DocMDP is the evidence that made it signed (got \(docMdpDocument.signature.evidence.map(\.kind)))")

        let unsignedDocument = try engine().openDocument(at: unsignedURL)
        require(!unsignedDocument.signature.signed, "an ordinary document is not signed")
        require(unsignedDocument.signature.readOnlyReason == nil,
                "an unsigned document has no read-only reason")
        let formDocument = try engine().openDocument(at: formURL)
        require(!formDocument.signature.signed,
                "a form with an unsigned signature field (no /V, no /SigFlags) is not signed")

        // ── 2. In-place writes refuse; copies are allowed and carry no signature ─────────
        let gateEngine = try engine()
        let gateDocument = try gateEngine.openDocument(at: signedURL)
        let reason = gateDocument.signature.readOnlyReason ?? ""
        require(reason.contains("edits can be saved to a copy"),
                "the read-only reason says where edits can go: \(reason)")
        let originalBytes = try bytes(signedURL)

        func expectRefusal(_ label: String, _ body: () async throws -> Void) async {
            do {
                try await body()
                require(false, "\(label) must be refused for a signed document")
            } catch {
                // Read the associated value rather than `String(describing:)`: the debug
                // description escapes quotes inside the message, which would hide the exact
                // sentence the shell shows.
                let message: String
                if let ffi = error as? LyraReaderFfiError {
                    switch ffi {
                    case .Document(let value), .Backend(let value),
                         .InvalidArgument(let value), .Ai(let value):
                        message = value
                    }
                } else {
                    message = error.localizedDescription
                }
                require(message.contains(reason),
                        "\(label) refused with the shared explanation (got: \(message))")
            }
        }

        await expectRefusal("replaceWithAnnotations") {
            _ = try await gateEngine.replaceWithAnnotations([], bookmarks: [], zoom: 1)
        }
        await expectRefusal("replaceWithAnnotationChanges") {
            _ = try await gateEngine.replaceWithAnnotationChanges(
                [], bookmarks: [], updates: [], deletions: [], zoom: 1)
        }
        await expectRefusal("replaceWithFilledForm") {
            _ = try await gateEngine.replaceWithFilledForm([])
        }
        await expectRefusal("replaceWithDocumentProperties") {
            _ = try await gateEngine.replaceWithDocumentProperties(
                DocumentProperties(title: "x", author: "", subject: "", keywords: ""))
        }
        await expectRefusal("replaceWithRedactions") {
            _ = try await gateEngine.replaceWithRedactions(
                [RedactionArea(page: 0, rect: CGRect(x: 10, y: 10, width: 40, height: 20))])
        }
        await expectRefusal("replaceOriginalWithPageEdits") {
            _ = try await gateEngine.replaceOriginalWithPageEdits(original: signedURL)
        }
        // The policy must use the current file, even if it gained a signature after open.
        let staleURL = try copy("text-page.pdf", "signed-after-open.pdf")
        let staleEngine = try engine()
        _ = try staleEngine.openDocument(at: staleURL)
        try originalBytes.write(to: staleURL)
        await expectRefusal("properties replacement after external signing") {
            _ = try await staleEngine.replaceWithDocumentProperties(
                DocumentProperties(title: "must not write", author: "", subject: "", keywords: ""))
        }
        let externallySignedBytes = try bytes(staleURL)
        require(externallySignedBytes == originalBytes,
                "a signature added after open is protected by the save transaction")
        let afterRefusals = try bytes(signedURL)
        require(afterRefusals == originalBytes,
                "every refused in-place command left the signed original byte-identical")

        /// Opens a derived copy and asserts it carries no signature evidence at all.
        func requireUnsignedCopy(_ url: URL, _ label: String) throws {
            require(fileManager.fileExists(atPath: url.path), "\(label) wrote its output")
            let output = try engine().openDocument(at: url)
            require(!output.signature.signed, "\(label)'s output does not look signed")
            require(output.signature.evidence.isEmpty,
                    "\(label)'s output carries no signature evidence")
        }

        // Extract: a new file with the selected page.
        let extractCopy = scratch.appendingPathComponent("copy-extract.pdf")
        let extractReport = try await gateEngine.extractPages([0], to: extractCopy)
        require(extractReport.pageCount == 1, "extract writes the selected page to a copy")
        try requireUnsignedCopy(extractCopy, "extractPages")

        // Merge: the signed document is an input; the output is a new document.
        let mergeCopy = scratch.appendingPathComponent("copy-merge.pdf")
        let mergeReport = try await gateEngine.mergeDocuments(others: [unsignedURL], to: mergeCopy)
        require(mergeReport.pageCount == 2, "merge writes both documents into a new file")
        try requireUnsignedCopy(mergeCopy, "mergeDocuments")

        // Split: one verified output per part.
        let splitCopy = scratch.appendingPathComponent("copy-split.pdf")
        _ = try await gateEngine.splitPages([
            PageSplitPart(pages: [0], destination: splitCopy)
        ])
        try requireUnsignedCopy(splitCopy, "splitPages")

        // Save edited copy: publishing the page-edit revision never touches the source.
        let editedCopy = scratch.appendingPathComponent("copy-edited.pdf")
        let editedReport = try await gateEngine.saveEditedCopy(to: editedCopy)
        require(editedReport.pageCount == 1, "saveEditedCopy writes the revision")
        try requireUnsignedCopy(editedCopy, "saveEditedCopy")

        // Redaction to a copy.
        let redactedCopy = scratch.appendingPathComponent("copy-redacted.pdf")
        _ = try await gateEngine.redactToCopy(
            to: redactedCopy,
            areas: [RedactionArea(page: 0, rect: CGRect(x: 10, y: 10, width: 40, height: 20))])
        try requireUnsignedCopy(redactedCopy, "redactToCopy")

        // Annotation copy: the new mark is written, the signature fields are not.
        let annotatedCopy = scratch.appendingPathComponent("copy-annotated.pdf")
        let highlight = AnnotationWriteRequest(
            id: "a-signed-copy-highlight",
            page: 0,
            kind: .highlight,
            rect: CGRect(x: 80, y: 600, width: 200, height: 20),
            quads: [CGRect(x: 80, y: 600, width: 200, height: 20)],
            color: AnnotationColor(red: 255, green: 230, blue: 0, alpha: 255),
            opacity: 1.0,
            contents: "Written into a copy of a signed PDF.",
            author: "LyraReader",
            modified: "D:20240102030405Z",
            fontSizePt: 12,
            textAlignment: "left")
        let annotationReport = try await gateEngine.saveAnnotationChanges(
            to: annotatedCopy,
            additions: [highlight],
            bookmarks: [],
            updates: [],
            deletions: [],
            zoom: 1)
        require(annotationReport.writtenIDs == [highlight.id],
                "the annotated copy reports the annotation it wrote")
        try requireUnsignedCopy(annotatedCopy, "annotation copy")
        let annotatedBytes = try bytes(annotatedCopy)
        require(contains(annotatedBytes, "a-signed-copy-highlight"),
                "the annotated copy keeps the new annotation")
        require(annotationReport.sourceBytesPreserved == false,
                "a signature-stripped copy does not claim the source prefix")
        require(annotationReport.fullRewrite && annotationReport.appendedBytes == 0,
                "a signature-stripped annotation copy reports a full rewrite")

        // The signature field is gone, the non-signature form field survives, and the page text
        // is unchanged.
        let annotatedProbe = try engine()
        _ = try annotatedProbe.openDocument(at: annotatedCopy)
        let annotatedForm = try await annotatedProbe.formInfo()
        require(!annotatedForm.fields.contains(where: { $0.kind == .signature }),
                "the annotated copy carries no signature field")
        require(annotatedForm.fields.contains(where: { $0.name == "reviewerName" }),
                "the annotated copy keeps the ordinary form field")
        let signedText = try await gateEngine.textPage(0).text
        let copyText = try await annotatedProbe.textPage(0).text
        require(copyText == signedText, "the annotated copy's page text is unchanged")

        // Filled-form copy: the value is written, the signature is stripped.
        let formInfo = try await gateEngine.formInfo()
        guard let textField = formInfo.fields.first(where: { $0.kind == .text }) else {
            require(false, "the signed fixture carries a text form field")
            return
        }
        let formCopy = scratch.appendingPathComponent("copy-form.pdf")
        _ = try await gateEngine.saveFilledForm(
            to: formCopy,
            values: [FormFieldValue(fieldID: textField.id, text: "Edited on a copy")])
        try requireUnsignedCopy(formCopy, "saveFilledForm")
        let formProbe = try engine()
        _ = try formProbe.openDocument(at: formCopy)
        let copiedForm = try await formProbe.formInfo()
        require(!copiedForm.fields.contains(where: { $0.kind == .signature }),
                "the filled-form copy carries no signature field")
        require(copiedForm.fields.first(where: { $0.name == textField.name })?.value
                == "Edited on a copy",
                "the filled-form copy carries the new value")

        // Properties copy: the new title is written, the signature is stripped.
        let propertiesCopy = scratch.appendingPathComponent("copy-properties.pdf")
        _ = try await gateEngine.saveDocumentProperties(
            to: propertiesCopy,
            properties: DocumentProperties(title: "Derived Copy Title"))
        try requireUnsignedCopy(propertiesCopy, "saveDocumentProperties")
        let propertiesProbe = try engine()
        _ = try propertiesProbe.openDocument(at: propertiesCopy)
        let copiedInfo = try await propertiesProbe.documentInfo()
        require(copiedInfo.title == "Derived Copy Title",
                "the properties copy carries the new title")
        let copiedPropertiesForm = try await propertiesProbe.formInfo()
        require(!copiedPropertiesForm.fields.contains(where: { $0.kind == .signature }),
                "the properties copy carries no signature field")

        let afterCopies = try bytes(signedURL)
        require(afterCopies == originalBytes,
                "every copy command left the signed original byte-identical")

        // ── 3. The shell mirrors the same decision: edit to a copy, never in place ────────
        let state = AppState(engine: try engine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        state.newTab(url: signedURL)
        require(state.document != nil, "the signed fixture opens in the reader")
        require(state.isReadOnlyDocument, "the reader reports the document as read-only in place")
        require(state.readOnlyReason == reason,
                "the reader's reason is the engine's reason, verbatim")
        require(state.readOnlyBannerTitle == "Signed PDF · read-only in place",
                "the banner has a human title")
        require(!state.readOnlyBannerEvidence.isEmpty,
                "the banner names the evidence it found")
        require(state.readOnlyBannerNote.contains("signature fields"),
                "the banner says a copy leaves the signature fields out")
        require(state.canEditAnnotations && state.canUseEraserTool,
                "annotation tools stay usable: edits go to a copy")
        require(state.canPageEdit && state.canPageOperations,
                "page editing is staged and page copies are available")
        require(state.canMarkRedactions, "redaction can be staged")
        require(state.canSaveAnnotationsToPDF, "copy export is available")
        require(!state.canReplaceOriginalWithAnnotations,
                "in-place annotation writing is disabled")
        require(!state.canReplaceOriginalWithPageEdits,
                "applying a page revision to the signed original is disabled")
        require(!state.canReplaceOriginalWithRedactions,
                "replacing the signed original with a redaction is disabled")
        require(!state.canReplaceOriginalWithFilledForm,
                "writing form values into the signed original is disabled")
        require(!state.canReplaceOriginalWithDocumentProperties,
                "writing properties into the signed original is disabled")

        // Annotation and bookmark edits are sidecar work; the copy export carries them.
        let addedInk = state.addInkAnnotation(
            page: 0, points: [CGPoint(x: 40, y: 40), CGPoint(x: 140, y: 80)])
        require(addedInk, "an annotation can be added to the signed document's sidecar")
        guard let inkID = state.annotations.last?.id else {
            require(false, "the added ink stroke has an identity")
            return
        }
        require(state.addBookmarkAtCurrentPage(name: "Copy bookmark"),
                "a bookmark can be added to the signed document's sidecar")
        state.toggleEraserTool()
        require(state.annotationTool == .eraser, "the eraser can be armed")
        state.selectTool()

        // A redaction can be marked and applied to a copy; replacing is disabled.
        state.addPendingRedaction(page: 0, rect: CGRect(x: 20, y: 20, width: 60, height: 30))
        require(!state.pendingRedactions.isEmpty && state.canApplyRedactions,
                "a redaction can be marked for a copy")
        require(!state.canReplaceOriginalWithRedactions,
                "the marked redaction cannot be applied in place")
        state.clearPendingRedactions()

        // Form drafts and property drafts are allowed; only their in-place save is disabled.
        try await eventually("the signed fixture's form loads", {
            !state.formLoading && (state.formError != nil || !state.formInfo.fields.isEmpty)
        })
        require(state.canUseFormTool, "form filling can be staged")
        if let editable = state.formInfo.fields.first(where: { $0.editable && $0.kind == .text }) {
            state.updateFormText(editable.id, text: "Draft on a signed PDF")
            require(state.canSaveFilledForm,
                    "a form draft can be saved to a copy")
            require(!state.canReplaceOriginalWithFilledForm,
                    "a form draft cannot be written into the signed original")
        } else {
            require(false, "the signed fixture exposes an editable text field")
        }
        state.loadDocumentInfo(force: true)
        try await eventually("the signed fixture's information loads", {
            !state.documentInfoLoading
                && (state.documentInfoError != nil || state.documentInfo != nil)
        })
        state.updateDocumentProperty(.title, text: "Draft Title")
        require(state.canSaveDocumentProperties,
                "a properties draft can be saved to a copy")
        require(!state.canReplaceOriginalWithDocumentProperties,
                "a properties draft cannot be written into the signed original")

        // The shell's annotated-copy export writes the sidecar marks into a new, unsigned file.
        let shellCopy = scratch.appendingPathComponent("shell-annotated-copy.pdf")
        let exported = await state.saveAnnotatedCopy(to: shellCopy)
        require(exported, "the shell exports an annotated copy of the signed document")
        try requireUnsignedCopy(shellCopy, "shell annotated copy")
        let shellCopyBytes = try bytes(shellCopy)
        require(contains(shellCopyBytes, "a-signed-copy-highlight") == false,
                "the shell copy is a new file, not the engine test's copy")
        require(contains(shellCopyBytes, inkID.uuidString),
                "the shell copy carries the sidecar ink stroke")
        require(contains(shellCopyBytes, "Copy bookmark"),
                "the shell copy carries the sidecar bookmark")
        require(state.lastAnnotationWriteReport?.sourceBytesPreserved == false,
                "the shell reports that the signed copy was rewritten")

        // A staged page edit is allowed; applying it to the original is not.
        // An inserted blank page has no text-position conflict with the sidecar marks.
        let staged = await state.applyPageEditOperation(
            .insertBlank(index: 1), label: "insert blank page")
        require(staged, "a page edit can be staged on a signed document")
        require(state.canSavePageEditsCopy,
                "the staged page edit can be saved to a copy")
        require(!state.canReplaceOriginalWithPageEdits,
                "the staged page edit cannot be applied to the signed original")
        let stagedCopy = scratch.appendingPathComponent("shell-edited-copy.pdf")
        let savedStagedCopy = await state.savePageEditsCopy(to: stagedCopy)
        require(savedStagedCopy, "the staged page edit saves to a copy")
        try requireUnsignedCopy(stagedCopy, "shell edited copy")
        let afterShellCommands = try bytes(signedURL)
        require(afterShellCommands == originalBytes,
                "no shell command modified the signed original")

        // ── 4. A deletion on an unsigned document prunes the removed bytes ──────────────
        let deleteURL = try copy("annotated-replies.pdf", "delete-source.pdf")
        let deleteState = AppState(engine: try engine())
        deleteState.setViewportSize(CGSize(width: 700, height: 500))
        deleteState.newTab(url: deleteURL)
        try await eventually("the reply fixture's annotations load", {
            deleteState.documentAnnotations.count >= 11
                || deleteState.documentAnnotationsError != nil
        })
        require(deleteState.documentAnnotationsError == nil,
                "the reply fixture's annotations read without error")
        let deletionBytes = try bytes(deleteURL)
        let removedNames = [
            "parent-highlight", "reply-one", "reply-two", "reply-empty", "reply-cross-page",
        ]
        for name in removedNames {
            require(contains(deletionBytes, name),
                    "the source carries the annotation that will be deleted (\(name))")
        }
        require(deleteState.deleteDocumentAnnotation("nm:parent-highlight"),
                "the file-owned highlight is deleted in this session")
        let deletedCopy = scratch.appendingPathComponent("deleted-thread.pdf")
        let deleted = await deleteState.saveAnnotatedCopy(to: deletedCopy)
        require(deleted, "the deletion saves into a copy")
        let deletedBytes = try bytes(deletedCopy)
        for name in removedNames {
            require(!contains(deletedBytes, name),
                    "the saved copy contains no /NM for the removed annotation (\(name))")
        }
        require(!contains(deletedBytes, "A highlighted sentence with a review thread."),
                "the saved copy contains none of the removed annotation's contents")
        require(contains(deletedBytes, "parent-note"),
                "an annotation that was not removed is still in the saved copy")
        require(deleteState.lastAnnotationWriteReport?.fullRewrite == true,
                "the report says the save pruned the file")
        require(deleteState.lastAnnotationWriteReport?.sourceBytesPreserved == false,
                "a pruned save does not claim the source prefix")
        let deleteSourceAfter = try bytes(deleteURL)
        require(deleteSourceAfter == deletionBytes,
                "the deletion's source PDF was not modified")

        // ── 5. The eraser on a file-owned ink stroke also prunes ────────────────────────
        let eraseURL = try copy("annotated-strokes.pdf", "erase-source.pdf")
        let eraseState = AppState(engine: try engine())
        eraseState.setViewportSize(CGSize(width: 700, height: 500))
        eraseState.newTab(url: eraseURL)
        try await eventually("the ink fixture's annotations load", {
            eraseState.documentAnnotations.count == 5
                || eraseState.documentAnnotationsError != nil
        })
        require(eraseState.documentAnnotationsError == nil,
                "the ink fixture's annotations read without error")
        guard let ink = eraseState.documentAnnotations.first(where: { $0.kind == "ink" }),
              let path = ink.inkPaths.first, path.count >= 2,
              let frame = eraseState.canvasPageFrames.first(where: { $0.index == ink.page })
        else {
            require(false, "the ink fixture carries a file-owned ink stroke")
            return
        }
        func content(_ local: CGPoint) -> CGPoint {
            CGPoint(x: frame.leftPt + local.x, y: frame.topPt + local.y)
        }
        let eraseBytes = try bytes(eraseURL)
        eraseState.toggleEraserTool()
        // A partial eraser removes only the ink under its pointer path; trace the whole stroke to
        // remove the annotation as a whole.
        eraseState.beginEraserGesture(atContentPoint: content(path[0]))
        for index in 1..<path.count {
            eraseState.extendEraserGesture(
                fromContentPoint: content(path[index - 1]),
                toContentPoint: content(path[index]))
        }
        eraseState.endEraserGesture()
        require(!eraseState.documentAnnotations.contains(where: { $0.id == ink.id }),
                "the eraser removed the file-owned ink stroke")
        require(eraseState.pendingFileDeletions.contains(where: { $0.identity == ink.id }),
                "the erasure is pending a PDF write")
        let erasedCopy = scratch.appendingPathComponent("erased-ink.pdf")
        let erased = await eraseState.saveAnnotatedCopy(to: erasedCopy)
        require(erased, "the erasure saves into a copy")
        let erasedBytes = try bytes(erasedCopy)
        require(!contains(erasedBytes, "external-ink"),
                "the saved copy contains no /NM for the erased stroke")
        require(!contains(erasedBytes, "Ink written by another producer."),
                "the saved copy contains none of the erased stroke's contents")
        require(contains(erasedBytes, "external-square"),
                "the other file-owned annotations survive the erasure")
        require(eraseState.lastAnnotationWriteReport?.fullRewrite == true,
                "the eraser's save pruned the file")
        let eraseSourceAfter = try bytes(eraseURL)
        require(eraseSourceAfter == eraseBytes,
                "the eraser's source PDF was not modified")

        // ── 6. An ordinary append stays incremental ─────────────────────────────────────
        let appendURL = try copy("text-page.pdf", "append-source.pdf")
        let appendState = AppState(engine: try engine())
        appendState.setViewportSize(CGSize(width: 700, height: 500))
        appendState.newTab(url: appendURL)
        require(appendState.addGeometryAnnotation(
                    kind: .ink, page: 0,
                    inkPaths: [[CGPoint(x: 40, y: 40), CGPoint(x: 140, y: 80)]]),
                "an ink stroke is added to an unsigned document")
        let appendCopy = scratch.appendingPathComponent("append-copy.pdf")
        let appended = await appendState.saveAnnotatedCopy(to: appendCopy)
        require(appended, "the append saves")
        let appendReport = appendState.lastAnnotationWriteReport
        require(appendReport?.fullRewrite == false,
                "an append does not prune: incremental stays the default")
        require(appendReport?.sourceBytesPreserved == true,
                "an append keeps the source bytes as its prefix")
        let appendSourceBytes = try bytes(appendURL)
        let appendBytes = try bytes(appendCopy)
        require(appendBytes.starts(with: appendSourceBytes),
                "the appended copy really begins with the source bytes")

        print("Signature-aware write checks passed")
    }
}
