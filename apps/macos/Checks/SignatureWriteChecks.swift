import AppKit
import LyraReaderKit
import Foundation

/// Signature-aware write policy.
///
/// A document that carries a digital signature is read-only: the engine refuses every command
/// that would write into the file, and the shell disables those commands and states the same
/// reason in a permanent banner. An unsigned document is written exactly as before, except that
/// a save which removes annotations prunes the file so the removed content cannot be recovered
/// from the bytes.
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

        // ── 2. The engine gate: every write command refuses, the copy save does not ───────
        let gateEngine = try engine()
        let gateDocument = try gateEngine.openDocument(at: signedURL)
        let reason = gateDocument.signature.readOnlyReason ?? ""
        let originalBytes = try bytes(signedURL)

        func expectRefusal(_ label: String, _ body: () async throws -> Void) async {
            do {
                try await body()
                require(false, "\(label) must be refused for a signed document")
            } catch {
                let message = String(describing: error)
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
        await expectRefusal("applyPageOperation") {
            _ = try await gateEngine.applyPageOperation(
                .rotate(pages: [0], quarterTurns: 1),
                to: scratch.appendingPathComponent("never-page-op.pdf"))
        }
        await expectRefusal("extractPages") {
            _ = try await gateEngine.extractPages(
                [0], to: scratch.appendingPathComponent("never-extract.pdf"))
        }
        await expectRefusal("mergeDocuments") {
            _ = try await gateEngine.mergeDocuments(
                others: [unsignedURL],
                to: scratch.appendingPathComponent("never-merge.pdf"))
        }
        await expectRefusal("splitPages") {
            _ = try await gateEngine.splitPages([
                PageSplitPart(pages: [0], destination: scratch.appendingPathComponent("never-split.pdf"))
            ])
        }
        await expectRefusal("saveEditedCopy") {
            _ = try await gateEngine.saveEditedCopy(
                to: scratch.appendingPathComponent("never-edited.pdf"))
        }
        await expectRefusal("replaceOriginalWithPageEdits") {
            _ = try await gateEngine.replaceOriginalWithPageEdits(original: signedURL)
        }
        await expectRefusal("redactToCopy") {
            _ = try await gateEngine.redactToCopy(
                to: scratch.appendingPathComponent("never-redacted.pdf"),
                areas: [RedactionArea(page: 0, rect: CGRect(x: 10, y: 10, width: 40, height: 20))])
        }
        await expectRefusal("replaceWithRedactions") {
            _ = try await gateEngine.replaceWithRedactions(
                [RedactionArea(page: 0, rect: CGRect(x: 10, y: 10, width: 40, height: 20))])
        }
        await expectRefusal("saveFilledForm") {
            _ = try await gateEngine.saveFilledForm(
                to: scratch.appendingPathComponent("never-filled.pdf"), values: [])
        }
        await expectRefusal("replaceWithFilledForm") {
            _ = try await gateEngine.replaceWithFilledForm([])
        }
        await expectRefusal("saveDocumentProperties") {
            _ = try await gateEngine.saveDocumentProperties(
                to: scratch.appendingPathComponent("never-properties.pdf"),
                properties: DocumentProperties(title: "x", author: "", subject: "", keywords: ""))
        }
        await expectRefusal("replaceWithDocumentProperties") {
            _ = try await gateEngine.replaceWithDocumentProperties(
                DocumentProperties(title: "x", author: "", subject: "", keywords: ""))
        }
        let afterRefusals = try bytes(signedURL)
        require(afterRefusals == originalBytes,
                "every refused command left the signed original byte-identical")
        for name in ["never-page-op", "never-extract", "never-merge", "never-split",
                     "never-edited", "never-redacted", "never-filled", "never-properties"] {
            require(!fileManager.fileExists(
                atPath: scratch.appendingPathComponent("\(name).pdf").path),
                "the refused \(name) command wrote no output")
        }

        // Saving an annotated copy is the exception: it writes a new file and never touches the
        // signed original.
        let annotatedCopy = scratch.appendingPathComponent("signed-annotated-copy.pdf")
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
        let copyReport = try await gateEngine.saveAnnotationChanges(
            to: annotatedCopy,
            additions: [highlight],
            bookmarks: [],
            updates: [],
            deletions: [],
            zoom: 1)
        require(fileManager.fileExists(atPath: annotatedCopy.path),
                "saving an annotated copy of a signed document is still allowed")
        require(copyReport.writtenIDs == [highlight.id],
                "the copy reports the annotation it wrote")
        let afterAnnotatedCopy = try bytes(signedURL)
        require(afterAnnotatedCopy == originalBytes,
                "saving the annotated copy left the signed original byte-identical")
        let annotatedBytes = try bytes(annotatedCopy)
        require(contains(annotatedBytes, "a-signed-copy-highlight"),
                "the annotated copy carries the new annotation")

        // ── 3. The shell mirrors the same decision, with the same sentence ───────────────
        let state = AppState(engine: try engine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        state.newTab(url: signedURL)
        require(state.document != nil, "the signed fixture opens in the reader")
        require(state.isReadOnlyDocument, "the reader reports the document as read-only")
        require(state.readOnlyReason == reason,
                "the reader's reason is the engine's reason, verbatim")
        require(state.readOnlyBannerTitle == "Signed PDF · read-only",
                "the banner has a human title")
        require(!state.readOnlyBannerEvidence.isEmpty,
                "the banner names the evidence it found")
        require(!state.canEditAnnotations, "annotation tools are disabled on a signed document")
        require(!state.canPageEdit && !state.canPageOperations,
                "page editing and page operations are disabled")
        require(!state.canMarkRedactions, "redaction is disabled")
        require(!state.canUseEraserTool, "the eraser is disabled")
        require(!state.canUseFormTool && !state.canSaveFilledForm, "forms are disabled")
        require(!state.canReplaceOriginalWithAnnotations,
                "replacing the signed original is disabled")

        state.toggleEraserTool()
        require(state.annotationTool == .select && state.lastError == reason,
                "the eraser command reports the read-only reason")
        state.lastError = nil
        state.toggleRedactionTool()
        require(state.annotationTool != .redact && state.lastError == reason,
                "the redaction command reports the read-only reason")
        state.lastError = nil
        state.toggleFormTool()
        require(!state.formToolActive && state.lastError == reason,
                "the form command reports the read-only reason")
        state.lastError = nil
        state.toggleTextMarkupTool(.highlight)
        require(state.annotationTool == .select && state.lastError == reason,
                "a markup tool reports the read-only reason")
        state.lastError = nil
        require(!state.addGeometryAnnotation(
                    kind: .ink, page: 0,
                    inkPaths: [[CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 60)]]),
                "annotation creation is refused on a signed document")
        require(state.lastError == reason,
                "annotation creation reports the read-only reason")
        state.lastError = nil
        require(!state.addBookmarkAtCurrentPage(),
                "adding a bookmark is refused on a signed document")
        require(state.lastError == reason,
                "the bookmark command reports the read-only reason")

        // The one write-shaped command the shell keeps: exporting a copy. With no sidecar
        // annotations it is a byte copy of the signed file, which is exactly what "export a
        // copy" means and why it cannot invalidate the signature.
        require(state.canSaveAnnotationsToPDF,
                "the signed document still offers a copy export")
        let signedExport = scratch.appendingPathComponent("signed-export.pdf")
        let exported = await state.saveAnnotatedCopy(to: signedExport)
        require(exported, "exporting a copy of the signed PDF succeeds")
        let exportedBytes = try bytes(signedExport)
        require(exportedBytes == originalBytes,
                "the exported copy of the signed PDF is byte-identical")

        let afterShellCommands = try bytes(signedURL)
        require(afterShellCommands == originalBytes,
                "no shell command modified the signed original")
        require(state.documentAnnotations.isEmpty,
                "the signed fixture's annotation list did not gain anything")

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
        eraseState.beginEraserGesture(atContentPoint: content(path[0]))
        eraseState.extendEraserGesture(
            fromContentPoint: content(path[0]), toContentPoint: content(path[path.count - 1]))
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
