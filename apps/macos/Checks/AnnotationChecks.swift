import ArisReaderKit
import Foundation

extension ReaderChecks {
    @MainActor static func annotationChecks(a: URL, b: URL) async throws {
        let sidecar = a.appendingPathExtension("aris-annotations.json")
        let annotation = AppState.Annotation(id: UUID(), page: 0, start: 0, end: 3,
            color: AppState.highlightPalette[0].color, note: "old", createdAt: Date())
        let encoder = JSONEncoder()
        var legacy = try JSONSerialization.jsonObject(with: encoder.encode(annotation)) as! [String: Any]
        legacy.removeValue(forKey: "kind")
        try JSONSerialization.data(withJSONObject: [legacy]).write(to: sidecar)
        let state = AppState(engine: try RustEngine())
        state.open(url: a)
        require(state.annotations.first?.kind == .highlight, "legacy sidecar defaults to highlight")
        state.updateNote("n", for: annotation.id)
        state.updateNote("new", for: annotation.id)
        require(state.undoStack.count == 1, "note typing coalesces undo")
        state.undo()
        require(state.annotations.first?.note == "old", "note undo restores original")
        state.redo()
        let disk = try JSONDecoder().decode([AppState.Annotation].self, from: Data(contentsOf: sidecar))
        require(disk.first?.note == "new", "note redo persists to disk")
        state.jump(to: annotation)
        require(state.addAnnotationFromSelection(kind: .underline), "underline persists")
        state.undo()
        require(state.annotations.count == 1, "undo removes new annotation")
        state.redo()
        require(state.annotations.count == 2, "redo restores new annotation")
        let id = state.annotations.last!.id
        state.removeAnnotation(id)
        state.undo()
        require(state.annotations.contains(where: { $0.id == id }), "delete is undoable")
        state.open(url: b)
        require(state.annotations.isEmpty && !state.canUndo, "annotation state never crosses documents")
        state.open(url: a)
        require(state.annotations.count == 2, "ordinary reopen restores annotations")
        // A directory at the target path deterministically makes atomic persistence fail.
        try FileManager.default.removeItem(at: sidecar)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: false)
        let before = state.annotations
        state.updateNote("must not publish", for: annotation.id)
        require(state.annotations == before && state.lastError != nil, "failed save preserves state and reports error")
        try FileManager.default.removeItem(at: sidecar)
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: sidecar)
        state.open(url: a)
        state.jump(to: annotation)
        require(!state.addHighlightFromSelection(), "corrupt sidecar blocks writes")
        let preserved = try Data(contentsOf: sidecar)
        require(preserved == corrupt, "corrupt bytes remain untouched")
        try FileManager.default.removeItem(at: sidecar)
        state.open(url: a)
        state.jump(to: annotation)
        require(state.addHighlightFromSelection(), "missing sidecar is created on first annotation")
    }

    // MARK: - Sidecar recovery, forward compatibility, coalescing and flush

    /// The follow-ups an independent review raised: the blocked state needs a way out, a file
    /// written by a newer version must survive this one, typing must not write once per
    /// keystroke, and nothing pending may be lost on quit or on a document switch.
    @MainActor static func annotationRecoveryChecks(a: URL, b: URL) async throws {
        let directory = a.deletingLastPathComponent()
        // Same options the app writes with, so `knownEntry` reproduces the on-disk shape.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        func fixture(_ name: String) throws -> URL {
            let document = directory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: document)
            try? FileManager.default.removeItem(at: sidecar(of: document))
            try FileManager.default.copyItem(at: a, to: document)
            return document
        }
        func sidecar(of document: URL) -> URL {
            document.appendingPathExtension("aris-annotations.json")
        }
        func readSidecar(_ document: URL) throws -> String {
            try String(decoding: Data(contentsOf: sidecar(of: document)), as: UTF8.self)
        }
        func knownEntry(_ annotation: AppState.Annotation) throws -> String {
            // The inner text of a one-element array, i.e. exactly how `saveAnnotations` writes it.
            let text = String(decoding: try encoder.encode([annotation]), as: UTF8.self)
            return String(text.dropFirst(2).dropLast(2))
        }

        // ── 1. A sidecar that cannot be read fails closed, and the UI offers a way out ──
        let broken = try fixture("recovery.pdf")
        let brokenSidecar = sidecar(of: broken)
        let seedAnnotation = AppState.Annotation(id: UUID(), page: 0, start: 0, end: 3,
            color: AppState.highlightPalette[0].color, note: "kept", createdAt: Date())
        try encoder.encode([seedAnnotation]).write(to: brokenSidecar)

        let recoveryState = AppState(engine: try RustEngine())
        recoveryState.setViewportSize(CGSize(width: 700, height: 500))
        recoveryState.newTab(url: broken)
        require(recoveryState.annotations.count == 1, "a valid sidecar loads before it is damaged")

        try Data().write(to: brokenSidecar) // the reviewer's 0-byte reproducer
        recoveryState.open(url: broken)
        require(recoveryState.annotations.isEmpty, "a 0-byte sidecar shows no annotations")
        require(recoveryState.canRecoverUnreadableAnnotationSidecar && recoveryState.lastError != nil,
                "a 0-byte sidecar offers recovery in the alert and blocks silently otherwise")
        recoveryState.jump(to: seedAnnotation)
        require(!recoveryState.addHighlightFromSelection(), "a 0-byte sidecar refuses writes")
        let afterRefusal = try Data(contentsOf: brokenSidecar)
        require(afterRefusal.isEmpty, "a refused write leaves the sidecar untouched")

        let firstBackup = recoveryState.recoverUnreadableAnnotationSidecar()
        require(firstBackup != nil, "recovery reports where the unreadable sidecar went")
        require(FileManager.default.fileExists(atPath: firstBackup!.path),
                "the backup file exists on disk")
        let firstBackupBytes = try Data(contentsOf: firstBackup!)
        require(firstBackupBytes == Data(),
                "the backup holds the original bytes (0 bytes) and the sidecar path is free")
        let freshSidecar = try readSidecar(broken)
        require(freshSidecar.contains("["), "recovery writes a fresh, readable sidecar")
        recoveryState.jump(to: seedAnnotation)
        require(recoveryState.addHighlightFromSelection(), "writes work again after recovery")
        require(recoveryState.annotations.count == 1 && !recoveryState.canRecoverUnreadableAnnotationSidecar,
                "the blocked state is cleared after recovery")

        // A second, non-empty unreadable file: the backup must be byte-identical, and an
        // earlier backup must never be overwritten.
        let secondCorrupt = Data("{not json at all".utf8)
        try secondCorrupt.write(to: brokenSidecar)
        recoveryState.open(url: broken)
        require(recoveryState.canRecoverUnreadableAnnotationSidecar, "a truncated sidecar blocks writes again")
        let secondBackup = recoveryState.recoverUnreadableAnnotationSidecar()
        require(secondBackup != nil && secondBackup != firstBackup,
                "a second recovery writes a new backup file")
        let secondBackupBytes = try Data(contentsOf: secondBackup!)
        require(secondBackupBytes == secondCorrupt,
                "the second backup holds the original bytes exactly")
        require(FileManager.default.fileExists(atPath: firstBackup!.path),
                "the earlier backup is still there (never overwritten)")

        // ── 2. Forward compatibility: entries from a newer version survive, verbatim ──
        let future = try fixture("future.pdf")
        let futureSidecar = sidecar(of: future)
        let known = AppState.Annotation(id: UUID(), page: 0, start: 0, end: 3,
            color: AppState.highlightPalette[0].color, note: "known entry", createdAt: Date())
        // Foreign entries are compared as the exact JSON text of the entry (from its `{` to its
        // closing `}`), which is what "preserved verbatim" has to mean across a save.
        let inkEntry = """
{
  "id" : "\(UUID().uuidString)",
  "kind" : "ink",
  "page" : 0,
  "points" : [
    { "x" : 1, "y" : 2 },
    { "x" : 3, "y" : 4 }
  ],
  "strokeWidth" : 2.5
}
"""
        let colourEntry = """
{
  "colorIndex" : 9,
  "id" : "\(UUID().uuidString)",
  "kind" : "highlight",
  "note" : "from a bigger palette",
  "page" : 0,
  "start" : 0,
  "end" : 1
}
"""
        let extraFieldEntry = """
{
  "createdAt" : 804000000,
  "id" : "\(UUID().uuidString)",
  "kind" : "underline",
  "note" : "with a field this version does not know",
  "opacity" : 0.4,
  "page" : 0,
  "start" : 2,
  "end" : 3
}
"""
        // A newer version may also write compact entries, and an entry it understands but this
        // one cannot check (page outside this document) must still be preserved rather than
        // blocking the whole file.
        let compactEntry = #"{"colorIndex":2,"id":"\#(UUID().uuidString)","kind":"ink","page":99,"strokes":[[1,2],[3,4]]}"#
        let futureFile = "[\n" + [try knownEntry(known), inkEntry, colourEntry, extraFieldEntry, compactEntry]
            .joined(separator: ",\n") + "\n]"
        try Data(futureFile.utf8).write(to: futureSidecar)

        let futureEngine = try RustEngine()
        let futureState = AppState(engine: futureEngine)
        futureState.setViewportSize(CGSize(width: 700, height: 500))
        futureState.newTab(url: future)
        require(futureState.annotations.count == 1, "a newer sidecar still loads this version's entries")
        require(futureState.preservedAnnotationEntryCount == 4,
                "entries this version cannot draw are preserved, not rejected")
        let text = try await futureEngine.textPage(known.page)
        let expectedRects = text.selectionRects(in: known.start...known.end)
        let placement = futureEngine.visiblePages(scrollYPt: futureState.scrollYPt,
            viewportHeightPt: 500, gapPt: futureState.pageGapPt, marginPt: 0)
            .first { $0.index == known.page }!
        // The tint texture holds the stored colour straight (this annotation is drawn
        // alpha-over), so the bytes to look for are the annotation's own colour.
        let expectedColor = Data(known.color.bgra)
        require(!expectedRects.isEmpty, "known annotation has nonempty text geometry")
        // Texture-cache IDs are private allocation details. Assert that the actual
        // annotation-colored quads cover the expected text, not a numeric ID range
        // that can change or accidentally match a page tile / preview instead.
        @MainActor func knownAnnotationRenders() -> Bool {
            expectedRects.allSatisfy { rect in
                futureState.canvasPages.contains { canvas in
                    canvas.image.pixelWidth == 1 && canvas.image.pixelHeight == 1
                        && canvas.image.bgra == expectedColor
                        && canvas.placement.leftPt == placement.leftPt + rect.minX
                        && canvas.placement.topPt == placement.topPt + rect.minY
                        && canvas.placement.widthPt == rect.width
                        && canvas.placement.heightPt == max(rect.height, 1)
                }
            }
        }
        try await eventually("the known annotation still renders", knownAnnotationRenders)
        futureState.removeAnnotation(known.id)
        require(!knownAnnotationRenders(), "removing the annotation removes its rendered quads")
        futureState.undo()
        try await eventually("undo restores the known annotation's rendered quads", knownAnnotationRenders)

        futureState.jump(to: known)
        require(futureState.addHighlightFromSelection(), "an edit is still possible on a newer sidecar")
        let rewritten = try readSidecar(future)
        require(rewritten.contains(inkEntry), "the unknown-kind entry survives an edit byte-for-byte")
        require(rewritten.contains(colourEntry), "the out-of-palette entry survives an edit byte-for-byte")
        require(rewritten.contains(extraFieldEntry), "the entry with unknown fields survives an edit byte-for-byte")
        require(rewritten.contains(compactEntry), "a compact foreign entry survives an edit byte-for-byte")
        require(rewritten.contains("known entry"), "the known entry is still written")
        let reparsed = try? JSONSerialization.jsonObject(with: Data(rewritten.utf8)) as? [Any]
        require(reparsed != nil, "the rewritten sidecar is still valid JSON")

        // An empty array is a valid sidecar, and a document without one starts clean.
        let empty = try fixture("empty.pdf")
        try Data("[\n\n]".utf8).write(to: sidecar(of: empty))
        let emptyState = AppState(engine: try RustEngine())
        emptyState.newTab(url: empty)
        require(emptyState.annotations.isEmpty && !emptyState.canRecoverUnreadableAnnotationSidecar,
                "an empty array is a valid sidecar")

        // ── 3. Typing coalesces disk writes; memory and undo stay immediate ──
        let typing = try fixture("typing.pdf")
        let noteAnnotation = AppState.Annotation(id: UUID(), page: 0, start: 0, end: 3,
            color: AppState.highlightPalette[0].color, note: "", createdAt: Date())
        try encoder.encode([noteAnnotation]).write(to: sidecar(of: typing))
        let typingState = AppState(engine: try RustEngine())
        typingState.setViewportSize(CGSize(width: 700, height: 500))
        typingState.newTab(url: typing)
        require(typingState.annotations.first?.note == "", "the note sidecar loads")

        let writesBeforeBurst = typingState.annotationWriteCount
        var typed = ""
        for _ in 1...60 {
            typed += "x"
            typingState.updateNote(typed, for: noteAnnotation.id)
        }
        require(typingState.annotations.first?.note == typed,
                "memory shows every keystroke immediately")
        require(typingState.undoStack.count == 1, "a burst of 60 keystrokes is a single undo step")
        require(typingState.annotationWriteCount == writesBeforeBurst + 1,
                "a burst of 60 keystrokes costs one disk write, not sixty")

        try await Task.sleep(for: .milliseconds(800))
        require(typingState.annotationWriteCount == writesBeforeBurst + 2,
                "the coalescing window writes the pending text exactly once")
        require(!typingState.hasPendingAnnotationWrite, "nothing is pending once the window closed")
        let coalescedDisk = try JSONDecoder().decode([AppState.Annotation].self,
                                                     from: Data(contentsOf: sidecar(of: typing)))
        require(coalescedDisk.first?.note == typed, "the coalesced write carried the final text")

        // Committing the field (Return/blur) writes immediately instead of waiting.
        let writesBeforeCommit = typingState.annotationWriteCount
        typingState.updateNote(typed + "1", for: noteAnnotation.id)
        typingState.updateNote(typed + "12", for: noteAnnotation.id)
        require(typingState.hasPendingAnnotationWrite, "the keystrokes are pending before the commit")
        typingState.commitNoteEdits()
        require(typingState.annotationWriteCount == writesBeforeCommit + 1,
                "commit writes the pending text immediately")
        require(!typingState.hasPendingAnnotationWrite, "commit leaves nothing pending")

        // A realistic burst: 12 keystrokes 100 ms apart, so ~1.2 s of typing.
        let writesBeforeTimed = typingState.annotationWriteCount
        var timed = typed + "12"
        for _ in 1...12 {
            timed += "y"
            typingState.updateNote(timed, for: noteAnnotation.id)
            try await Task.sleep(for: .milliseconds(100))
        }
        typingState.commitNoteEdits()
        let timedWrites = typingState.annotationWriteCount - writesBeforeTimed
        print("INFO: 12 keystrokes over ~1.2 s produced \(timedWrites) sidecar write(s)")
        require(timedWrites <= 6 && timedWrites < 12,
                "typing throttles writes to about one per 500 ms (\(timedWrites) for 12 keystrokes)")
        require(typingState.annotations.first?.note == timed, "the throttled text is in memory")

        // ── 4. A document switch and a tab close flush what is pending ──
        let keyBeforeOpen = "readingPosition:" + typing.path
        UserDefaults.standard.removeObject(forKey: keyBeforeOpen)
        typingState.scroll(toFraction: 0.4) // debounced: only in memory until a flush point
        let switchPosition = typingState.scrollYPt
        require(switchPosition > 0, "the document scrolled before the switch")
        require(UserDefaults.standard.object(forKey: keyBeforeOpen) == nil,
                "the scrolled position is still only in memory")
        typingState.updateNote(timed + "!", for: noteAnnotation.id) // immediate write, opens a window
        typingState.updateNote(timed + "!!", for: noteAnnotation.id) // now only in memory
        require(typingState.hasPendingAnnotationWrite,
                "a keystroke right before the switch is still pending on disk")
        typingState.newTab(url: b)
        require(!typingState.hasPendingAnnotationWrite, "switching documents flushes the pending note")
        let flushedAtSwitch = try JSONDecoder().decode([AppState.Annotation].self,
                                                       from: Data(contentsOf: sidecar(of: typing)))
        require(flushedAtSwitch.first?.note == timed + "!!",
                "the switch wrote the pending text to its own sidecar before leaving it")
        require(typingState.annotationWriteCount == 0, "the write counter is per document")
        require(UserDefaults.standard.object(forKey: keyBeforeOpen) != nil,
                "switching documents flushes the pending reading position")
        typingState.newTab(url: typing)
        require(typingState.annotations.first?.note == timed + "!!",
                "the note flushed at the switch is on disk")
        require(abs(UserDefaults.standard.double(forKey: keyBeforeOpen) - Double(switchPosition)) < 0.5,
                "the flushed position is the one the document had")

        // Closing the (active) tab flushes too.
        typingState.updateNote(timed + "!!?", for: noteAnnotation.id)
        typingState.updateNote(timed + "!!??", for: noteAnnotation.id)
        require(typingState.hasPendingAnnotationWrite,
                "a keystroke right before the tab closes is still pending on disk")
        typingState.closeTab(2)
        require(!typingState.hasPendingAnnotationWrite, "closing a tab flushes the pending note")
        let flushedAtClose = try JSONDecoder().decode([AppState.Annotation].self,
                                                      from: Data(contentsOf: sidecar(of: typing)))
        require(flushedAtClose.first?.note == timed + "!!??",
                "the note typed just before the tab closed reached the sidecar")
        typingState.closeTab(1)
        typingState.closeTab(0)
        require(typingState.document == nil, "closing the last tab closes the document")

        // ── 5. A read-only directory still refuses to write and loses nothing ──
        let lockedDirectory = directory.appendingPathComponent("locked")
        try? FileManager.default.removeItem(at: lockedDirectory)
        try FileManager.default.createDirectory(at: lockedDirectory, withIntermediateDirectories: true)
        let locked = lockedDirectory.appendingPathComponent("locked.pdf")
        try FileManager.default.copyItem(at: a, to: locked)
        let lockedState = AppState(engine: try RustEngine())
        lockedState.setViewportSize(CGSize(width: 700, height: 500))
        lockedState.newTab(url: locked)
        let lockedAnnotation = AppState.Annotation(id: UUID(), page: 0, start: 0, end: 3,
            color: AppState.highlightPalette[0].color, note: "first", createdAt: Date())
        try encoder.encode([lockedAnnotation]).write(to: sidecar(of: locked))
        lockedState.open(url: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: lockedDirectory.path)
        }
        let lockedBefore = lockedState.annotations
        lockedState.updateNote("must not publish", for: lockedAnnotation.id)
        require(lockedState.annotations == lockedBefore,
                "a read-only directory keeps the failed write out of memory")
        require(lockedState.lastError != nil, "a read-only directory reports the failure")
        let lockedBytes = try Data(contentsOf: sidecar(of: locked))
        let lockedOnDisk = try JSONDecoder().decode([AppState.Annotation].self, from: lockedBytes)
        require(lockedOnDisk.first?.note == "first", "the sidecar bytes survive a refused write")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: lockedDirectory.path)
            .filter { $0 != "locked.pdf" && $0 != "locked.pdf.aris-annotations.json" }
        require(leftovers.isEmpty, "a failed write leaves no temporary files behind")
    }

    // MARK: - Reading the annotations a PDF already contains

    /// The whole path, from a PDF somebody else annotated to what the canvas draws.
    ///
    /// `tests/fixtures/annotated.pdf` is generated by `scripts/make-fixtures.py`: seven
    /// annotations written straight into the file's `/Annots` arrays, including a blue
    /// (`/C [0.2 0.6 1]`) that matches no palette entry, a `/BM /Multiply` highlight with
    /// `/CA 0.5`, a sticky note with no colour at all, and a highlight with no `/QuadPoints`.
    /// This is the check that answers the user's question in the shell rather than in Rust:
    /// the colour another viewer stored comes through as it is, and the highlight is drawn
    /// *multiplied* with its opacity baked in, exactly as Preview composites it.
    @MainActor static func annotationReadingChecks(url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("INFO: skipping PDF annotation reading (no annotated fixture at \(url.path))")
            return
        }

        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        state.open(url: url)
        try await eventually("the file's own annotations are read", {
            !state.documentAnnotations.isEmpty || state.documentAnnotationsError != nil
        })
        require(state.documentAnnotationsError == nil,
                "reading the fixture's annotations does not fail")
        require(state.documentAnnotations.count == 7, "all seven annotations in the file are read")

        let kinds = state.documentAnnotations.map(\.kind)
        require(kinds == ["highlight", "underline", "strikeout", "text", "freeText", "squiggly", "highlight"],
                "the subtype of every annotation arrives, in page order")

        let highlight = state.documentAnnotations[0]
        require(highlight.page == 0, "the highlight belongs to the first page")
        // View space: `/Rect [72 671 460 701]` on an 842 pt page starts 141 pt below the top.
        require(abs(highlight.yPt - (842 - 701)) < 0.001 && abs(highlight.xPt - 72) < 0.001
                && abs(highlight.widthPt - 388) < 0.001 && abs(highlight.heightPt - 30) < 0.001,
                "the rectangle arrives in view space (Y flipped once, not twice)")
        require(highlight.quads.count == 2, "a highlight spanning two lines keeps both quads")
        require(highlight.color == AnnotationColor(red: 51, green: 153, blue: 255, alpha: 128),
                "another viewer's colour arrives faithfully, with /CA 0.5 as its alpha")
        require(!AppState.highlightPalette.contains { $0.color == highlight.color },
                "that colour is outside the palette, which is exactly the case that used to be unreadable")
        require(highlight.blend == "multiply", "/BM /Multiply is read, not assumed")
        require(highlight.contents == "Highlight contents for the round trip."
                && highlight.author == "Reviewer A"
                && highlight.modified == "D:20240102030405Z",
                "contents, author and modification date all arrive")

        // The sticky note has no /C: reporting black would invent a colour the file never had.
        let sticky = state.documentAnnotations[3]
        require(sticky.kind == "text" && sticky.color == nil,
                "a sticky note with no /C reports no colour rather than black")
        require(sticky.contents == "A sticky note body.", "the note's text is readable")
        require(state.documentNotes.count == 2,
                "the sidebar lists the notes (sticky note and free text), which have no drawable mark")

        // ── What the canvas draws ──
        // The multiply pipeline needs the opacity *baked into the colour* (PDF mixes in the
        // stored colour space, the GPU in linear light), so the tint texture has to hold
        // `0.5·colour + 0.5·white` at alpha 255 rather than the raw colour at alpha 128.
        let baked = highlight.color!.baked(opacity: 0.5)
        require(baked == AnnotationColor(red: 153, green: 204, blue: 255, alpha: 255),
                "baking /CA 0.5 into #3399FF gives #99CCFF, which is what the GPU must multiply")
        try await eventually("the loaded highlight is drawn as a multiplied quad", {
            state.canvasPages.contains { page in
                page.blend == .multiply
                    && page.image.pixelWidth == 1
                    && page.image.bgra == Data(baked.bgra)
            }
        })

        // An underline in the same file carries no /BM at all. Every viewer multiplies an
        // underline, so that is what the reader reports here; the appearance-stream fixture below
        // is where "no /BM at all" is checked case by case.
        let underline = state.documentAnnotations[1]
        require(underline.blend == "multiply" && underline.quadBlend == .multiply,
                "an underline with no /BM is still composited with the multiply pipeline")
        let underlineQuad = underline.color!.baked(opacity: underline.opacity ?? 1.0)
        try await eventually("the underline is drawn multiplied", {
            state.canvasPages.contains { page in
                page.blend == .multiply && page.image.bgra == Data(underlineQuad.bgra)
            }
        })

        // ── Jumping to an entry from the sidebar brings its page on screen ──
        // The squiggly is on the second page, so this is a real scroll, not a no-op: it is what
        // a click in the "In this PDF" list does.
        let squiggly = state.documentAnnotations[5]
        require(squiggly.page == 1 && state.currentPage == 1, "the fixture starts on page one")
        state.jump(toDocumentAnnotation: squiggly)
        require(state.scrollYPt > 0,
                "jumping to an annotation on page two scrolls towards it (scroll \(state.scrollYPt) pt)")
        // "On screen" is the honest test, not "the viewport top is on that page": a page two
        // thirds of a viewport below the top is visible, and the annotation is drawn on it.
        let squigglyQuad = squiggly.color!.baked(opacity: squiggly.opacity ?? 1.0)
        try await eventually("the annotation's page is on screen and drawn", {
            state.canvasPages.contains { page in
                page.blend == .multiply && page.image.bgra == Data(squigglyQuad.bgra)
            }
        })
        // …and the text under it is selected, which is what makes the note point at something.
        try await eventually("the text under the annotation is selected", {
            state.selection?.page == squiggly.page
        })
    }

    /// The shape Preview writes: every annotation carries an appearance stream, and no annotation
    /// states `/BM`.
    ///
    /// This is the check that would have caught the reported defect end to end. `Preview` puts the
    /// colour behind `/AP` — PDFium's `FPDFAnnot_GetColor` refuses an annotation with an appearance
    /// stream, so the reader used to report no colour at all — and the multiply lives in that
    /// stream's `ExtGState`, so the annotation dictionary says nothing about the blend. Both had to
    /// be answered before a highlight from another viewer stopped painting over the text:
    ///
    /// * the yellow highlight arrives as `#FFFF00` with `/CA 0.968627`, and is drawn **multiplied**
    ///   with the opacity baked into the tint (`0.968627·c + 0.031373·white` → `#FFFF08`);
    /// * a highlight with no `/C` at all keeps the file's `/CA` in a neutral grey instead of the
    ///   opaque grey that used to cover the page;
    /// * a squiggly with no `/BM` stays alpha-over, because that is how a squiggly is drawn.
    @MainActor static func annotationAppearanceChecks(url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("INFO: skipping appearance-stream annotation checks (no fixture at \(url.path))")
            return
        }

        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        state.open(url: url)
        try await eventually("the file's annotations are read through their appearance streams", {
            !state.documentAnnotations.isEmpty || state.documentAnnotationsError != nil
        })
        require(state.documentAnnotationsError == nil,
                "reading annotations that carry /AP does not fail")
        require(state.documentAnnotations.count == 4,
                "all four markup annotations are read (\(state.documentAnnotations.count))")

        let highlight = state.documentAnnotations[0]
        require(highlight.color == AnnotationColor(red: 255, green: 255, blue: 0, alpha: 247),
                "the colour behind /AP is read, with /CA 0.968627 as its alpha, got "
                + "\(String(describing: highlight.color))")
        require(highlight.blend == "multiply",
                "a highlight with no /BM is still multiplied, got \(highlight.blend)")
        let bakedHighlight = highlight.color!.baked(opacity: highlight.opacity ?? 1.0)
        require(bakedHighlight == AnnotationColor(red: 255, green: 255, blue: 8, alpha: 255),
                "the opacity is baked into the tint before the multiply draw, got \(bakedHighlight)")
        try await eventually("the loaded highlight is drawn multiplied", {
            state.canvasPages.contains { page in
                page.blend == .multiply && page.image.bgra == Data(bakedHighlight.bgra)
            }
        })

        // No /C anywhere: the mark is a neutral grey, but the file's opacity still applies. An
        // opaque grey here is exactly what covered the text of the review PDFs.
        let colourless = state.documentAnnotations[2]
        require(colourless.color == nil, "a highlight with no /C reports no colour")
        require(colourless.opacity != nil && abs(colourless.opacity! - 0.35) < 1e-6,
                "…but its /CA is still the file's")
        let neutral = UInt8((colourless.opacity! * 255).rounded())
        let neutralColour = AnnotationColor(red: 0x80, green: 0x80, blue: 0x80, alpha: neutral)
        require(neutralColour.alpha == 89 && neutralColour.alpha != 255,
                "the neutral tint carries /CA rather than being opaque")
        let bakedNeutral = neutralColour.baked(opacity: colourless.opacity!)
        try await eventually("the colourless highlight is drawn translucent, not opaque", {
            state.canvasPages.contains { page in
                page.blend == .multiply && page.image.bgra == Data(bakedNeutral.bgra)
            }
        })

        // A squiggly drawn beside the text is not multiplied, even with an appearance stream.
        let squiggly = state.documentAnnotations[3]
        require(squiggly.kind == "squiggly" && squiggly.blend == "normal"
                && squiggly.quadBlend == .normal,
                "a squiggly with no /BM stays alpha-over, got \(squiggly.blend)")
        let squigglyColour = squiggly.color!
        require(squigglyColour.alpha == 191, "/CA 0.75 arrives as alpha 191")
        try await eventually("the squiggly is drawn alpha-over", {
            state.canvasPages.contains { page in
                page.blend == .normal && page.image.bgra == Data(squigglyColour.bgra)
            }
        })
    }

    // MARK: - Colour: anything the file carries, and a sidecar that keeps working either way
    /// The colour model, checked against both directions of the sidecar's compatibility story.
    ///
    /// The user-visible regression this pins down is the one that started the work: a colour the
    /// old four-entry palette could not name used to make the whole entry "unreadable", so a
    /// document somebody else annotated showed nothing. A colour is now a value.
    @MainActor static func annotationColourChecks(a: URL) async throws {
        let directory = a.deletingLastPathComponent()

        func fixture(_ name: String) throws -> URL {
            let document = directory.appendingPathComponent(name)
            let sidecar = document.appendingPathExtension("aris-annotations.json")
            try? FileManager.default.removeItem(at: document)
            try? FileManager.default.removeItem(at: sidecar)
            try FileManager.default.copyItem(at: a, to: document)
            return document
        }
        func sidecar(of document: URL) -> URL {
            document.appendingPathExtension("aris-annotations.json")
        }
        func text(of document: URL) throws -> String {
            try String(decoding: Data(contentsOf: sidecar(of: document)), as: UTF8.self)
        }

        // ── 1. A sidecar written by an older build: `colorIndex` still means its preset ──
        let legacy = try fixture("colour-legacy.pdf")
        let legacyID = UUID().uuidString
        try Data("""
[
  {
    "colorIndex" : 2,
    "createdAt" : 804000000,
    "end" : 3,
    "id" : "\(legacyID)",
    "kind" : "highlight",
    "note" : "from the old palette",
    "page" : 0,
    "start" : 0
  }
]
""".utf8).write(to: sidecar(of: legacy))

        let legacyState = AppState(engine: try RustEngine())
        legacyState.setViewportSize(CGSize(width: 700, height: 500))
        legacyState.open(url: legacy)
        require(legacyState.annotations.count == 1 && legacyState.preservedAnnotationEntryCount == 0,
                "an old colorIndex record is understood, not preserved as unreadable")
        require(legacyState.annotations.first?.color == AppState.highlightPalette[2].color,
                "colorIndex 2 still means the third palette colour")

        // ── 2. A colour outside every palette is read exactly, not rounded to a preset ──
        let foreign = try fixture("colour-foreign.pdf")
        let foreignID = UUID().uuidString
        try Data("""
[
  {
    "color" : "#12345678",
    "createdAt" : 804000000,
    "end" : 3,
    "id" : "\(foreignID)",
    "kind" : "highlight",
    "note" : "somebody else's blue",
    "page" : 0,
    "start" : 0
  }
]
""".utf8).write(to: sidecar(of: foreign))

        let foreignState = AppState(engine: try RustEngine())
        foreignState.setViewportSize(CGSize(width: 700, height: 500))
        foreignState.open(url: foreign)
        require(foreignState.annotations.count == 1 && foreignState.preservedAnnotationEntryCount == 0,
                "a colour outside the palette no longer makes an entry unreadable")
        let stored = foreignState.annotations.first?.color
        require(stored == AnnotationColor(red: 0x12, green: 0x34, blue: 0x56, alpha: 0x78),
                "every channel of #12345678 survives, including the opacity")

        // ── 3. What this build writes: a preset stays readable by an older build ──
        //
        // Each case seeds one annotation and creates a second one, then looks at the two entries
        // side by side: whether the *new* entry carries `colorIndex`, `color`, or both is the
        // whole compatibility contract, and a whole-file substring search could not tell which
        // entry a key came from.
        func entries(ofDocument document: URL) throws -> [[String: Any]] {
            let data = try Data(contentsOf: sidecar(of: document))
            guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw NSError(domain: "AnnotationChecks", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "the sidecar is not an array of objects",
                ])
            }
            return array
        }
        let seededColour = AnnotationColor(red: 0x12, green: 0x34, blue: 0x56, alpha: 0x78)
        let seeded = AppState.Annotation(
            id: UUID(), page: 0, start: 0, end: 3,
            color: seededColour, note: "seeded", createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let preset = try fixture("colour-preset.pdf")
        try encoder.encode([seeded]).write(to: sidecar(of: preset))
        let presetState = AppState(engine: try RustEngine())
        presetState.setViewportSize(CGSize(width: 700, height: 500))
        presetState.open(url: preset)
        require(presetState.annotations.count == 1, "the seeded annotation loads")
        presetState.jump(to: presetState.annotations[0])
        require(presetState.addHighlightFromSelection(color: AppState.highlightPalette[1].color),
                "a preset-coloured highlight is created")

        let presetEntries = try entries(ofDocument: preset)
        let presetCreated = presetEntries.first { ($0["note"] as? String) == "" }
        require(presetCreated?["colorIndex"] as? Int == 1,
                "a palette colour is written as colorIndex, the key an older build understands")
        require(presetCreated?["color"] == nil,
                "no new key is written for a colour the old model can express")
        let presetSeeded = presetEntries.first { ($0["note"] as? String) == "seeded" }
        require(presetSeeded?["color"] as? String == "#12345678",
                "the arbitrary colour of the seeded entry is still written as color")

        // ── 4. …and a colour the old model cannot express is written as `color`, only as that ──
        let custom = try fixture("colour-custom.pdf")
        let presetSeed = AppState.Annotation(
            id: UUID(), page: 0, start: 0, end: 3,
            color: AppState.highlightPalette[0].color, note: "seeded", createdAt: Date()
        )
        try encoder.encode([presetSeed]).write(to: sidecar(of: custom))
        let customState = AppState(engine: try RustEngine())
        customState.setViewportSize(CGSize(width: 700, height: 500))
        customState.open(url: custom)
        customState.jump(to: customState.annotations[0])
        let chosen = AnnotationColor(red: 0x11, green: 0x88, blue: 0xCC, alpha: 0xAA)
        require(customState.addHighlightFromSelection(color: chosen),
                "an arbitrary colour is created")

        let customEntries = try entries(ofDocument: custom)
        let customCreated = customEntries.first { ($0["note"] as? String) == "" }
        require(customCreated?["color"] as? String == "#1188CCAA",
                "an arbitrary colour is written as #RRGGBBAA")
        require(customCreated?["colorIndex"] == nil,
                "the nearest palette index is not written as a lie about the colour")

        // ── 5. It comes back unchanged after a save and a reopen, and is what gets drawn ──
        customState.open(url: custom)
        require(customState.annotations.count == 2, "both annotations reload")
        let reloaded = customState.annotations.first { $0.note.isEmpty }
        require(reloaded?.color == chosen, "the exact colour survives a save and a reopen")
        // …and the canvas quad carries those bytes: the colour is not just stored, it is drawn.
        let expected = Data(chosen.bgra)
        try await eventually("the custom colour is the one drawn on the canvas", {
            customState.canvasPages.contains { page in
                page.image.pixelWidth == 1 && page.image.bgra == expected
            }
        })
    }
}
