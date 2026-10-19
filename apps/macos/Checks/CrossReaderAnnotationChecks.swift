import AppKit
import LyraReaderKit
import CoreGraphics
import Foundation
import PDFKit

extension ReaderChecks {
    /// Cross-reader editing, proved with **PDFKit** — the engine Preview uses.
    ///
    /// This is the end-to-end check the feature exists for: an annotation another application
    /// wrote is adopted, edited and saved into a copy; PDFKit then reads the new colour and
    /// contents, and the reply thread is still attached. Deletion is checked the same way (both
    /// by PDFKit and by this reader), undo restores it before a save, and the file's untouched
    /// annotations keep their identity, contents and colour.
    @MainActor static func crossReaderAnnotationChecks(
        replies: URL,
        notes: URL
    ) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-reader-cross-reader-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        func copy(_ source: URL, _ name: String) throws -> URL {
            let destination = scratch.appendingPathComponent(name)
            try fileManager.copyItem(at: source, to: destination)
            return destination
        }

        func open(_ url: URL) async throws -> AppState {
            let state = AppState(engine: try RustEngine())
            state.setViewportSize(CGSize(width: 700, height: 500))
            state.newTab(url: url)
            try await eventually("cross-reader: \(url.lastPathComponent) annotations load", {
                !state.documentAnnotations.isEmpty || state.documentAnnotationsError != nil
            })
            require(state.documentAnnotationsError == nil,
                    "the annotations of \(url.lastPathComponent) read without error")
            return state
        }

        // ── 1. Adopt a foreign highlight, change colour and comment, save a copy ──────
        let editSource = try copy(replies, "thread-source.pdf")
        let editState = try await open(editSource)
        let before = editState.documentAnnotations
        guard let parent = before.first(where: { $0.id == "nm:parent-highlight" }),
              let reply = before.first(where: { $0.id == "nm:reply-one" }) else {
            require(false, "the reply fixture carries the threaded highlight")
            return
        }
        require(reply.parentID == "nm:parent-highlight",
                "the fixture's reply points at the highlight")
        require(AppState.documentAnnotationEditability(parent) == .editable,
                "a foreign highlight is editable under the one policy")

        guard let entryID = editState.adoptDocumentAnnotation(parent.id) else {
            require(false, "the foreign highlight is adopted into the editable model")
            return
        }
        let editedColour = AnnotationColor(red: 30, green: 120, blue: 220, alpha: 128)
        editState.updateNote("Edited by LyraReader across readers.", for: entryID)
        require(editState.setAnnotationColor(entryID, to: editedColour),
                "the adopted highlight's colour is changed")
        editState.flushPendingWrites()
        require(!editState.documentAnnotations.contains(where: { $0.id == parent.id }),
                "the PDF copy is hidden while the adopted entry is open")

        let editedCopy = scratch.appendingPathComponent("thread-edited.pdf")
        let editedSaved = await editState.saveAnnotatedCopy(to: editedCopy)
        require(editedSaved, "the edited foreign highlight saves into a copy")

        // PDFKit: the new colour and contents are what Preview's engine sees.
        guard let editedPDF = PDFDocument(url: editedCopy) else {
            require(false, "PDFKit opens the edited copy")
            return
        }
        guard let pdfParent = pdfKitAnnotation(in: editedPDF, named: "parent-highlight") else {
            require(false, "PDFKit still finds the highlight by /NM after the edit")
            return
        }
        require(pdfParent.contents == "Edited by LyraReader across readers.",
                "PDFKit reads the edited /Contents")
        guard let pdfColour = pdfKitColour(pdfParent) else {
            require(false, "PDFKit reports the edited highlight colour")
            return
        }
        require(abs(pdfColour.red - 30) <= 2 && abs(pdfColour.green - 120) <= 2
                    && abs(pdfColour.blue - 220) <= 2,
                "PDFKit reads the edited /C (\(pdfColour.red), \(pdfColour.green), \(pdfColour.blue))")
        guard let pdfReply = pdfKitAnnotation(in: editedPDF, named: "reply-one") else {
            require(false, "PDFKit still finds the reply after the parent's edit")
            return
        }
        // PDFKit exposes annotations but not the `/IRT` link itself. It proves the reply exists
        // and is unchanged; the link is checked against the saved bytes, and the reader check
        // below proves the same link through PDFium.
        require(pdfReply.contents == reply.contents,
                "PDFKit reads the reply's contents unchanged after the parent's edit")
        let rawReplyParent = rawReplyTarget(in: editedCopy, replyName: "reply-one")
        require(rawReplyParent == "parent-highlight",
                "the saved bytes still carry /IRT from reply-one to parent-highlight")
        FileHandle.standardError.write(Data(
            "lyra-reader-cross-reader: PDFKit colour=\(pdfColour.red),\(pdfColour.green),\(pdfColour.blue) contents=\(pdfParent.contents ?? "nil") reply=\(rawReplyParent ?? "nil")\n".utf8
        ))

        // Our own reader: the edited values and the untouched thread around them.
        let editedReopen = try await open(editedCopy)
        guard let reopenedParent = editedReopen.documentAnnotations.first(where: {
            $0.id == "nm:parent-highlight"
        }) else {
            require(false, "the reader finds the edited highlight in the copy")
            return
        }
        require(reopenedParent.contents == "Edited by LyraReader across readers.",
                "the reader reads the edited highlight comment back")
        require(reopenedParent.color.map { [$0.red, $0.green, $0.blue] } == [30, 120, 220],
                "the reader reads the edited highlight colour back")
        require(editedReopen.documentAnnotations.contains(where: {
            $0.id == "nm:reply-one" && $0.parentID == "nm:parent-highlight"
        }), "the reply survives the parent's edit and still points at it")

        // ── 2. Deleting a foreign parent: replies go with it, undo restores it ────────
        let deleteSource = try copy(replies, "delete-source.pdf")
        let deleteState = try await open(deleteSource)
        let removalNames: Set<String> = [
            "parent-highlight", "reply-one", "reply-two", "reply-empty", "reply-cross-page",
        ]
        require(deleteState.deleteDocumentAnnotation("nm:parent-highlight"),
                "a foreign highlight is deleted in this session")
        require(deleteState.pendingFileDeletions.contains(where: {
            $0.identity == "nm:parent-highlight"
        }), "the removal is pending, not written")
        require(!deleteState.documentAnnotations.contains(where: {
            $0.id == "nm:parent-highlight"
        }), "the deleted annotation is gone from the page before the save")
        deleteState.undo()
        require(deleteState.documentAnnotations.contains(where: {
            $0.id == "nm:parent-highlight"
        }), "undo restores the deletion before it is saved")
        require(!deleteState.pendingFileDeletions.contains(where: {
            $0.identity == "nm:parent-highlight"
        }), "undo cancels the pending deletion")

        require(deleteState.deleteDocumentAnnotation("nm:parent-highlight"),
                "the highlight is deleted again for the save")
        let deletedCopy = scratch.appendingPathComponent("thread-deleted.pdf")
        let deletedSaved = await deleteState.saveAnnotatedCopy(to: deletedCopy)
        require(deletedSaved, "the deletion saves into a copy")
        require(deleteState.lastAnnotationWriteReport?.deletedReplyCount == 4,
                "the save reports the four replies it removed with their parent")

        guard let deletedPDF = PDFDocument(url: deletedCopy) else {
            require(false, "PDFKit opens the copy with the deleted thread")
            return
        }
        for name in removalNames {
            require(pdfKitAnnotation(in: deletedPDF, named: name) == nil,
                    "PDFKit finds no annotation named \(name) after the deletion")
        }
        let deletedReopen = try await open(deletedCopy)
        for name in removalNames {
            require(!deletedReopen.documentAnnotations.contains(where: { $0.id == "nm:\(name)" }),
                    "the reader finds no \(name) after the deletion")
        }
        for annotation in deletedReopen.documentAnnotations where annotation.isReply {
            if let parentID = annotation.parentID {
                require(!removalNames.contains(parentID),
                        "no remaining reply points at an annotation the deletion removed")
            }
        }
        // The fixture already carries one reply to a `/Link` (not a content annotation). The
        // deletion must not add to that count: only the removed thread may disappear.
        let orphansBefore = AnnotationPanelModel.build(from: before).orphanedReplyCount
        let orphansAfter = AnnotationPanelModel.build(
            from: deletedReopen.documentAnnotations).orphanedReplyCount
        require(orphansAfter == orphansBefore,
                "the deletion leaves no new orphaned reply (before \(orphansBefore), after \(orphansAfter))")

        // ── 3. A text box written by another producer: edit it and save again ────────
        let notesSource = try copy(notes, "producer-notes.pdf")
        let notesState = try await open(notesSource)
        let notesBefore = notesState.documentAnnotations
        guard let foreignText = notesBefore.first(where: {
            $0.kind == "freeText" && $0.drawing == .freeText
        }) else {
            require(false, "the notes fixture carries a free-text box")
            return
        }
        require(foreignText.id.hasPrefix("fp:"),
                "this producer wrote no /NM, so the reader uses its stable fallback identity")
        guard let textEntry = notesState.adoptDocumentAnnotation(foreignText.id) else {
            require(false, "a foreign text box is adopted")
            return
        }
        notesState.updateNote("Rewritten by LyraReader in another reader's text box.", for: textEntry)
        notesState.flushPendingWrites()
        let notesCopy = scratch.appendingPathComponent("producer-notes-edited.pdf")
        let notesSaved = await notesState.saveAnnotatedCopy(to: notesCopy)
        require(notesSaved, "the edited foreign text box saves into a copy")
        require(notesState.lastAnnotationWriteReport?.assignedNames.isEmpty == false,
                "the writer reports the /NM it assigned to the nameless text box")

        let assignedName = notesState.annotations.first(where: { $0.id == textEntry })?
            .id.uuidString ?? ""
        guard let notesPDF = PDFDocument(url: notesCopy),
              let pdfText = pdfKitAnnotation(in: notesPDF, named: assignedName) else {
            require(false, "PDFKit finds the edited text box by its assigned /NM")
            return
        }
        require(pdfText.contents == "Rewritten by LyraReader in another reader's text box.",
                "PDFKit reads the edited text box contents")
        require(pdfText.type == "FreeText", "the edit keeps /Subtype /FreeText")
        let notesReopen = try await open(notesCopy)
        require(notesReopen.documentAnnotations.contains(where: {
            $0.id == "nm:\(assignedName)"
                && $0.contents == "Rewritten by LyraReader in another reader's text box."
        }), "the reader reads the edited text box back with its new /NM")
        // Untouched notes keep their meaning.
        for original in notesBefore where original.id != foreignText.id {
            guard let after = notesReopen.documentAnnotations.first(where: {
                $0.id == original.id
            }) else {
                require(false, "the untouched note \(original.id) survives")
                return
            }
            require(after.contents == original.contents && after.color == original.color,
                    "the untouched note \(original.id) keeps its contents and colour")
        }

        // ── 4. The file's untouched annotations keep identity, contents and colour ───
        for original in before where original.id != parent.id {
            guard let after = editedReopen.documentAnnotations.first(where: {
                $0.id == original.id
            }) else {
                require(false, "the untouched annotation \(original.id) survives the edit")
                return
            }
            require(after.contents == original.contents,
                    "untouched annotation \(original.id) keeps its /Contents")
            require(after.color?.red == original.color?.red
                        && after.color?.green == original.color?.green
                        && after.color?.blue == original.color?.blue,
                    "untouched annotation \(original.id) keeps its /C")
            require(after.modified == original.modified,
                    "untouched annotation \(original.id) keeps its /M")
        }
        require(pdfKitAnnotations(in: editedPDF).count
                    == pdfKitAnnotations(in: PDFDocument(url: editSource)!).count,
                "the edit neither adds nor removes an annotation")
    }

    // MARK: - PDFKit helpers

    @MainActor
    private static func pdfKitAnnotations(in document: PDFDocument) -> [PDFAnnotation] {
        var annotations: [PDFAnnotation] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            annotations.append(contentsOf: page.annotations)
        }
        return annotations
    }

    @MainActor
    private static func pdfKitAnnotation(
        in document: PDFDocument,
        named name: String
    ) -> PDFAnnotation? {
        pdfKitAnnotations(in: document).first {
            ($0.value(forAnnotationKey: PDFAnnotationKey(rawValue: "NM")) as? String) == name
        }
    }

    /// The `/NM` of the annotation a reply points at through `/IRT`, read from the saved bytes.
    ///
    /// PDFKit deliberately does not expose the `/IRT` key (its `annotationKeyValues` omits it and
    /// `value(forAnnotationKey:)` returns nil even for a fixture it opens), so the link itself is
    /// read from the file while PDFKit proves the reply object and its contents.
    private static func rawReplyTarget(in url: URL, replyName: String) -> String? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1) else { return nil }
        let pattern = #"(\d+)\s+0\s+obj\s*<<(.*?)>>"#
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var namesByObject: [String: String] = [:]
        var replyLink: String?
        for match in regex.matches(in: text, options: [], range: range) {
            guard let numberRange = Range(match.range(at: 1), in: text),
                  let bodyRange = Range(match.range(at: 2), in: text) else { continue }
            let number = String(text[numberRange])
            let body = String(text[bodyRange])
            if let name = firstCapture(#"/NM\s*\(([^)]*)\)"#, in: body) {
                namesByObject[number] = name
            }
            if firstCapture(#"/NM\s*\(([^)]*)\)"#, in: body) == replyName,
               let reference = firstCapture(#"/IRT\s+(\d+)\s+0\s+R"#, in: body) {
                replyLink = reference
            }
        }
        guard let replyLink else { return nil }
        return namesByObject[replyLink]
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    @MainActor
    private static func pdfKitColour(_ annotation: PDFAnnotation) -> (red: Int, green: Int, blue: Int)? {
        guard let colour = annotation.color.usingColorSpace(.deviceRGB) else { return nil }
        return (
            Int((colour.redComponent * 255).rounded()),
            Int((colour.greenComponent * 255).rounded()),
            Int((colour.blueComponent * 255).rounded())
        )
    }
}
