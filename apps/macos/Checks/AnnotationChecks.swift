import LyraReaderKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension ReaderChecks {
    @MainActor static func annotationChecks(a: URL, b: URL) async throws {
        let records = DocumentEditCache.annotationsURL(for: a)
        let annotation = AppState.Annotation(id: UUID(), page: 0, start: 0, end: 3,
            color: AppState.highlightPalette[0].color, note: "old", createdAt: Date())
        let encoder = JSONEncoder()
        var legacy = try JSONSerialization.jsonObject(with: encoder.encode(annotation)) as! [String: Any]
        legacy.removeValue(forKey: "kind")
        try JSONSerialization.data(withJSONObject: [legacy]).write(to: records)
        let state = AppState(engine: try RustEngine())
        state.open(url: a)
        require(state.annotations.first?.kind == .highlight, "legacy annotation file defaults to highlight")
        state.updateNote("n", for: annotation.id)
        state.updateNote("new", for: annotation.id)
        require(state.undoStack.count == 1, "note typing coalesces undo")
        state.undo()
        require(state.annotations.first?.note == "old", "note undo restores original")
        state.redo()
        let disk = try JSONDecoder().decode([AppState.Annotation].self, from: Data(contentsOf: records))
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
        try FileManager.default.removeItem(at: records)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: false)
        let before = state.annotations
        state.updateNote("must not publish", for: annotation.id)
        require(state.annotations == before && state.lastError != nil, "failed save preserves state and reports error")
        try FileManager.default.removeItem(at: records)
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: records)
        state.open(url: a)
        state.jump(to: annotation)
        require(!state.addHighlightFromSelection(), "corrupt annotation cache blocks writes")
        let preserved = try Data(contentsOf: records)
        require(preserved == corrupt, "corrupt bytes remain untouched")
        try FileManager.default.removeItem(at: records)
        state.open(url: a)
        state.jump(to: annotation)
        require(state.addHighlightFromSelection(), "missing annotation cache is created on first annotation")
    }

    // MARK: - Annotation-cache recovery, forward compatibility, coalescing and flush

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
            try? FileManager.default.removeItem(at: records(of: document))
            try FileManager.default.copyItem(at: a, to: document)
            return document
        }
        func records(of document: URL) -> URL {
            DocumentEditCache.annotationsURL(for: document)
        }
        func readRecords(_ document: URL) throws -> String {
            try String(decoding: Data(contentsOf: records(of: document)), as: UTF8.self)
        }
        func knownEntry(_ annotation: AppState.Annotation) throws -> String {
            // The inner text of a one-element array, i.e. exactly how `saveAnnotations` writes it.
            let text = String(decoding: try encoder.encode([annotation]), as: UTF8.self)
            return String(text.dropFirst(2).dropLast(2))
        }

        // ── 1. An annotation cache that cannot be read fails closed, and the UI offers a way out ──
        let broken = try fixture("recovery.pdf")
        let brokenRecords = records(of: broken)
        let seedAnnotation = AppState.Annotation(id: UUID(), page: 0, start: 0, end: 3,
            color: AppState.highlightPalette[0].color, note: "kept", createdAt: Date())
        try encoder.encode([seedAnnotation]).write(to: brokenRecords)

        let recoveryState = AppState(engine: try RustEngine())
        recoveryState.setViewportSize(CGSize(width: 700, height: 500))
        recoveryState.newTab(url: broken)
        require(recoveryState.annotations.count == 1, "a valid annotation cache loads before it is damaged")

        try Data().write(to: brokenRecords) // the reviewer's 0-byte reproducer
        recoveryState.open(url: broken)
        require(recoveryState.annotations.isEmpty, "a 0-byte annotation cache shows no annotations")
        require(recoveryState.canRecoverUnreadableAnnotationRecords && recoveryState.lastError != nil,
                "a 0-byte annotation cache offers recovery in the alert and blocks silently otherwise")
        recoveryState.jump(to: seedAnnotation)
        require(!recoveryState.addHighlightFromSelection(), "a 0-byte annotation cache refuses writes")
        let afterRefusal = try Data(contentsOf: brokenRecords)
        require(afterRefusal.isEmpty, "a refused write leaves the annotation cache untouched")

        let firstBackup = recoveryState.recoverUnreadableAnnotationRecords()
        require(firstBackup != nil, "recovery reports where the unreadable annotation cache went")
        require(FileManager.default.fileExists(atPath: firstBackup!.path),
                "the backup file exists on disk")
        let firstBackupBytes = try Data(contentsOf: firstBackup!)
        require(firstBackupBytes == Data(),
                "the backup holds the original bytes (0 bytes) and the annotation cache path is free")
        let freshRecords = try readRecords(broken)
        require(freshRecords.contains("["), "recovery writes a fresh, readable annotation cache")
        recoveryState.jump(to: seedAnnotation)
        require(recoveryState.addHighlightFromSelection(), "writes work again after recovery")
        require(recoveryState.annotations.count == 1 && !recoveryState.canRecoverUnreadableAnnotationRecords,
                "the blocked state is cleared after recovery")

        // A second, non-empty unreadable file: the backup must be byte-identical, and an
        // earlier backup must never be overwritten.
        let secondCorrupt = Data("{not json at all".utf8)
        try secondCorrupt.write(to: brokenRecords)
        recoveryState.open(url: broken)
        require(recoveryState.canRecoverUnreadableAnnotationRecords, "a truncated annotation cache blocks writes again")
        let secondBackup = recoveryState.recoverUnreadableAnnotationRecords()
        require(secondBackup != nil && secondBackup != firstBackup,
                "a second recovery writes a new backup file")
        let secondBackupBytes = try Data(contentsOf: secondBackup!)
        require(secondBackupBytes == secondCorrupt,
                "the second backup holds the original bytes exactly")
        require(FileManager.default.fileExists(atPath: firstBackup!.path),
                "the earlier backup is still there (never overwritten)")

        // ── 2. Forward compatibility: entries from a newer version survive, verbatim ──
        let future = try fixture("future.pdf")
        let futureRecords = records(of: future)
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
        try Data(futureFile.utf8).write(to: futureRecords)

        let futureEngine = try RustEngine()
        let futureState = AppState(engine: futureEngine)
        futureState.setViewportSize(CGSize(width: 700, height: 500))
        futureState.newTab(url: future)
        require(futureState.annotations.count == 1, "a newer annotation cache still loads this version's entries")
        require(futureState.preservedAnnotationEntryCount == 4,
                "entries this version cannot draw are preserved, not rejected")
        let text = try await futureEngine.textPage(known.page)
        let expectedRects = text.selectionRects(in: known.start...known.end)
        let placement = futureEngine.visiblePages(scrollYPt: futureState.scrollYPt,
            viewportHeightPt: 500, gapPt: futureState.pageGapPt, marginPt: 0)
            .first { $0.index == known.page }!
        // Multiply folds opacity into the tint rather than replacing the source glyphs.
        let expectedColor = Data(known.color.baked(opacity: 1).bgra)
        require(!expectedRects.isEmpty, "known annotation has nonempty text geometry")
        // Texture-cache IDs are private allocation details. Assert that the actual
        // annotation-colored quads cover the expected text, not a numeric ID range
        // that can change or accidentally match a page tile / preview instead.
        @MainActor func knownAnnotationRenders() -> Bool {
            expectedRects.allSatisfy { rect in
                futureState.canvasPages.contains { canvas in
                    canvas.image.pixelWidth == 1 && canvas.image.pixelHeight == 1
                        && canvas.image.bgra == expectedColor && canvas.blend == .multiply
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
        require(futureState.addHighlightFromSelection(), "an edit is still possible on a newer annotation cache")
        let rewritten = try readRecords(future)
        require(rewritten.contains(inkEntry), "the unknown-kind entry survives an edit byte-for-byte")
        require(rewritten.contains(colourEntry), "the out-of-palette entry survives an edit byte-for-byte")
        require(rewritten.contains(extraFieldEntry), "the entry with unknown fields survives an edit byte-for-byte")
        require(rewritten.contains(compactEntry), "a compact foreign entry survives an edit byte-for-byte")
        require(rewritten.contains("known entry"), "the known entry is still written")
        let reparsed = try? JSONSerialization.jsonObject(with: Data(rewritten.utf8)) as? [Any]
        require(reparsed != nil, "the rewritten annotation cache is still valid JSON")

        // An empty array is a valid annotation cache, and a document without one starts clean.
        let empty = try fixture("empty.pdf")
        try Data("[\n\n]".utf8).write(to: records(of: empty))
        let emptyState = AppState(engine: try RustEngine())
        emptyState.newTab(url: empty)
        require(emptyState.annotations.isEmpty && !emptyState.canRecoverUnreadableAnnotationRecords,
                "an empty array is a valid annotation cache")

        // ── 3. Typing coalesces disk writes; memory and undo stay immediate ──
        let typing = try fixture("typing.pdf")
        let noteAnnotation = AppState.Annotation(id: UUID(), page: 0, start: 0, end: 3,
            color: AppState.highlightPalette[0].color, note: "", createdAt: Date())
        try encoder.encode([noteAnnotation]).write(to: records(of: typing))
        let typingState = AppState(engine: try RustEngine())
        typingState.setViewportSize(CGSize(width: 700, height: 500))
        typingState.newTab(url: typing)
        require(typingState.annotations.first?.note == "", "the annotation cache holding the note loads")

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
                                                     from: Data(contentsOf: records(of: typing)))
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
        print("INFO: 12 keystrokes over ~1.2 s produced \(timedWrites) cache write(s)")
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
                                                       from: Data(contentsOf: records(of: typing)))
        require(flushedAtSwitch.first?.note == timed + "!!",
                "the switch wrote the pending text to its own annotation cache before leaving it")
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
                                                      from: Data(contentsOf: records(of: typing)))
        require(flushedAtClose.first?.note == timed + "!!??",
                "the note typed just before the tab closed reached the annotation cache")
        require(typingState.contentCloseRequested, "closing the dirty note waits for the save decision")
        typingState.discardContentAndClose()
        typingState.closeTab(1)
        if typingState.contentCloseRequested { typingState.discardContentAndClose() }
        typingState.closeTab(0)
        if typingState.contentCloseRequested { typingState.discardContentAndClose() }
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
        try encoder.encode([lockedAnnotation]).write(to: records(of: locked))
        lockedState.open(url: locked)
        let lockedCacheDirectory = records(of: locked).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedCacheDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: lockedCacheDirectory.path)
        }
        let lockedBefore = lockedState.annotations
        lockedState.updateNote("must not publish", for: lockedAnnotation.id)
        require(lockedState.annotations == lockedBefore,
                "a read-only directory keeps the failed write out of memory")
        require(lockedState.lastError != nil, "a read-only directory reports the failure")
        let lockedBytes = try Data(contentsOf: records(of: locked))
        let lockedOnDisk = try JSONDecoder().decode([AppState.Annotation].self, from: lockedBytes)
        require(lockedOnDisk.first?.note == "first", "the cache bytes survive a refused write")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: lockedDirectory.path)
            .filter { $0 != "locked.pdf" && $0 != "locked.pdf.lyra-reader-annotations.json" }
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

    /// What the canvas is handed for a page that carries both a page raster and loaded highlights.
    ///
    /// The defect this check exists for is not in the renderer and not in the reader: it is in the
    /// **handover**. A quad's `placement.index` is the key `MetalCanvasView` caches its GPU texture
    /// under, so two quads sharing one index means one of them draws the other's bitmap. With the
    /// two full-page raster indices (`-3·10⁹ - page`) and the loaded-annotation indices sharing a
    /// base, page 0's raster and the *first* loaded highlight box were the same index: the
    /// page-sized quad was drawn with the highlight's 1x1 tint through the alpha-over pipeline, so
    /// the whole page came out as a wash of the highlight's colour and the text under it vanished.
    /// The Rust rasterisers cannot see this — they never build a `CanvasPage` — and the Swift
    /// checks that only look at the annotation quads cannot see it either, because the annotation
    /// quads are drawn correctly. What is asserted here is the handover itself: the indices in one
    /// frame are unique, the page-sized quad is a page-sized bitmap, and the highlight boxes are
    /// 1x1 tints.
    @MainActor static func annotationCanvasChecks(url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("INFO: skipping the canvas handover check (no annotated fixture at \(url.path))")
            return
        }

        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 900, height: 700))
        state.open(url: url)
        // Wait for the frame that carries both halves: the page's own raster (a bitmap far wider
        // than a 1x1 tint) and at least one loaded highlight box.
        try await eventually("page 1's raster and its loaded highlights are in one frame", {
            let rasters = state.canvasPages.filter {
                $0.placement.index < 0 && $0.image.pixelWidth > 64
            }
            let tints = state.canvasPages.filter {
                $0.image.pixelWidth == 1 && $0.image.pixelHeight == 1
            }
            return !rasters.isEmpty && !tints.isEmpty
        })

        // An index is the key the canvas caches a quad's texture under, so what matters is that
        // each one names exactly one quad. The failure message names the offenders: an index
        // shared by a page-sized bitmap and a 1x1 tint is the wash this check exists for.
        var owners: [Int: [String]] = [:]
        for page in state.canvasPages {
            let what = page.image.pixelWidth == 1
                ? "a 1x1 tint"
                : "a \(page.image.pixelWidth)x\(page.image.pixelHeight) bitmap"
            owners[page.placement.index, default: []].append(what)
        }
        let shared = owners.filter { $0.value.count > 1 }
        require(shared.isEmpty,
                "no two quads in one frame share a placement index (the canvas keys each quad's "
                    + "texture by it, so a shared index draws one quad with the other's bitmap); "
                    + "shared: "
                    + shared.sorted { $0.key < $1.key }.prefix(3)
                        .map { "\($0.key) by \($0.value.joined(separator: " and "))" }
                        .joined(separator: ", "))

        // The page-sized quad really is a page: at the 900x700-point viewport the page raster is
        // the whole page at the backing scale, and it must not have been replaced by a 1x1 tint.
        // Selected by its index block, not by its bitmap size — `annotated.pdf` also carries a
        // free-text annotation whose text raster is wider than a page raster's minimum.
        let pageRasters = state.canvasPages.filter {
            PlacementIndex.isPageRaster($0.placement.index)
        }
        require(!pageRasters.isEmpty && pageRasters.allSatisfy {
            $0.image.pixelWidth > 64 && $0.image.pixelHeight > 64
        }, "every page quad still carries a page-sized bitmap")
        // Every markup box of a loaded annotation is a 1x1 tint, and it is multiplied.
        let markupBoxes = state.canvasPages.filter { page in
            PlacementIndex.isDocumentAnnotationBox(page.placement.index)
        }
        require(!markupBoxes.isEmpty && markupBoxes.allSatisfy {
            $0.image.pixelWidth == 1 && $0.image.pixelHeight == 1
        }, "every loaded markup box is handed over as a 1x1 tint")
        require(markupBoxes.allSatisfy { $0.blend == .multiply },
                "every loaded highlight box is handed to the canvas as a multiplied quad "
                    + "(\(markupBoxes.filter { $0.blend != .multiply }.count) of "
                    + "\(markupBoxes.count) are not)")
    }

    /// The placement-index blocks the shell draws from must stay disjoint.
    ///
    /// This is the invariant behind the check above, stated once for all four blocks: `pageRaster`
    /// grows downwards from its base, `selection`, `ownAnnotation` and `documentAnnotation` grow
    /// upwards in their own, and the ranges cannot meet. It fails the moment someone reuses a base
    /// — which is exactly what had happened, with page 0's raster and the first loaded highlight
    /// box on the same index.
    @MainActor static func placementIndexChecks() {
        var owner: [Int: String] = [:]
        func claim(_ index: Int, _ what: String) {
            if let previous = owner[index] {
                fatalError("FAIL: \(what) and \(previous) share placement index \(index) — the "
                    + "canvas caches a quad's texture under this index, so one quad would be drawn "
                    + "with the other's bitmap")
            }
            owner[index] = what
        }

        // Enough of each block to cover any real document: 4096 pages, 4096 selection boxes,
        // 4096 cached annotations, 4096 loaded annotations with up to 64 quad boxes each, and
        // 4096 note glyphs.
        for page in 0..<4_096 { claim(PlacementIndex.pageRaster(page), "page \(page)'s raster") }
        for index in 0..<4_096 { claim(PlacementIndex.selection(index), "selection box \(index)") }
        for index in 0..<4_096 {
            claim(PlacementIndex.ownAnnotation(index), "cached annotation \(index)")
        }
        for annotation in 0..<4_096 {
            for box in 0..<64 {
                claim(PlacementIndex.documentAnnotation(annotation, box: box),
                      "loaded annotation \(annotation) box \(box)")
            }
        }
        for index in 0..<4_096 {
            claim(PlacementIndex.documentNote(index), "note glyph \(index)")
        }
        for index in 0..<4_096 {
            claim(PlacementIndex.ownNote(index), "reader placed-text glyph \(index)")
        }
        for index in 0..<4_096 {
            claim(PlacementIndex.aiSource(index), "AI source-highlight box \(index)")
        }

        // …and the ends of every block, which is where two blocks would meet if a capacity grew
        // past what the layout allows: the last page raster, the last selection box, the last
        // cached annotation, the last loaded annotation's last box, and the last note glyph. The
        // capacities are the ones `PlacementIndex` documents (2^28 pages, boxes, record slots and
        // note glyphs; 2^18 loaded annotations of 2^10 boxes each).
        claim(PlacementIndex.pageRaster(PlacementIndex.block - 1), "the last page's raster")
        claim(PlacementIndex.selection(PlacementIndex.block - 1), "the last selection box")
        claim(PlacementIndex.ownAnnotation(65_535), "the last cached annotation")
        claim(PlacementIndex.documentAnnotation(262_143, box: 1_023),
              "the last loaded annotation's last box")
        claim(PlacementIndex.documentNote(PlacementIndex.block - 1), "the last note glyph")
        claim(PlacementIndex.ownNote(PlacementIndex.block - 1), "the last reader placed-text glyph")
        claim(PlacementIndex.aiSource(PlacementIndex.block - 1), "the last AI source-highlight box")

        require(owner.count == 4_096 * 6 + 4_096 * 64 + 7,
                "page rasters, the selection, this reader's annotations, loaded annotations, "
                    + "reader placed-text glyphs, note glyphs and the AI source highlight never share a placement index (\(owner.count) distinct indices, "
                    + "including the ends of each block)")
    }

    // MARK: - Colour: anything the file carries, and an annotation cache that keeps working either way
    /// The colour model, checked against both directions of the annotation records' compatibility story.
    ///
    /// The user-visible regression this pins down is the one that started the work: a colour the
    /// old four-entry palette could not name used to make the whole entry "unreadable", so a
    /// document somebody else annotated showed nothing. A colour is now a value.
    @MainActor static func annotationColourChecks(a: URL) async throws {
        let directory = a.deletingLastPathComponent()

        func fixture(_ name: String) throws -> URL {
            let document = directory.appendingPathComponent(name)
            let records = DocumentEditCache.annotationsURL(for: document)
            try? FileManager.default.removeItem(at: document)
            try? FileManager.default.removeItem(at: records)
            try FileManager.default.copyItem(at: a, to: document)
            return document
        }
        func records(of document: URL) -> URL {
            DocumentEditCache.annotationsURL(for: document)
        }
        func text(of document: URL) throws -> String {
            try String(decoding: Data(contentsOf: records(of: document)), as: UTF8.self)
        }

        // ── 1. An annotation cache written by an older build: `colorIndex` still means its preset ──
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
""".utf8).write(to: records(of: legacy))

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
""".utf8).write(to: records(of: foreign))

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
            let data = try Data(contentsOf: records(of: document))
            guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw NSError(domain: "AnnotationChecks", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "the annotation cache is not an array of objects",
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
        try encoder.encode([seeded]).write(to: records(of: preset))
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
        try encoder.encode([presetSeed]).write(to: records(of: custom))
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
        // The stored hue/opacity is folded into the Multiply tint used on the canvas.
        let expected = Data(chosen.baked(opacity: 1).bgra)
        try await eventually("the custom colour is the one drawn on the canvas", {
            customState.canvasPages.contains { page in
                page.image.pixelWidth == 1 && page.image.bgra == expected && page.blend == .multiply
            }
        })
    }

    // MARK: - The annotations that used to be listed but never drawn

    /// The user's report, end to end in the shell: a file of nothing but notes now *shows* them.
    ///
    /// This is the check that fails on the build before the fix. `annotated-notes.pdf` is
    /// `review_tang_0905.pdf` in miniature — sticky notes and free text, no markup at all — and on
    /// that build the canvas skipped every one of its seven annotations, so an annotated page
    /// looked like a blank one. Everything asserted here is user-visible:
    ///
    /// * every content annotation the engine reports is either **drawn** or **classified as
    ///   skipped with a reason** — the accounting has to add up, and an annotation in neither
    ///   bucket is the bug;
    /// * a sticky note's quad reaches `canvasPages`, in the note index block, at its own `/Rect`,
    ///   alpha-over, carrying a bitmap that is not a 1×1 tint (i.e. a real icon);
    /// * a free-text annotation's quad does too, laid out at the size `/DA` states;
    /// * the hidden marker and the `/Ink` annotation get no quad at all;
    /// * clicking a drawn note expands its text on the canvas;
    /// * and the composite of those quads — the same quads, the same blend modes, composited by
    ///   CoreGraphics instead of by Metal — has the note's colour where the note is and page white
    ///   where it is not. That is the pixel evidence a headless run can produce; it is written to
    ///   `LYRA_READER_CHECK_SNAPSHOT_DIR` when that variable names a directory.
    @MainActor static func annotationNoteChecks(url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("INFO: skipping note annotation checks (no notes fixture at \(url.path))")
            return
        }

        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 900, height: 700))
        state.open(url: url)
        try await eventually("the notes-only file's annotations are read", {
            !state.documentAnnotations.isEmpty || state.documentAnnotationsError != nil
        })
        require(state.documentAnnotationsError == nil, "reading the notes fixture does not fail")
        require(state.documentAnnotations.count == 7, "all seven content annotations are read")

        // ── 1. Every annotation is drawn or explicitly skipped, and the counts add up ──
        var drawnNotes = 0
        var drawnText = 0
        var drawnMarkup = 0
        var drawnGeometry = 0
        var drawnStamps = 0
        var skipReasons: [String] = []
        for annotation in state.documentAnnotations {
            switch annotation.drawing {
            case .markup:
                drawnMarkup += 1
            case .noteIcon:
                drawnNotes += 1
            case .freeText:
                drawnText += 1
            case .geometry:
                drawnGeometry += 1
            case .stamp:
                drawnStamps += 1
            case .skipped:
                require(annotation.skipReason != nil,
                        "a skipped annotation says why (\(annotation.kind))")
                skipReasons.append(annotation.skipReason?.rawValue ?? "?")
            }
        }
        require(drawnMarkup + drawnNotes + drawnText + drawnGeometry + drawnStamps
                    + skipReasons.count == state.documentAnnotations.count,
                "every content annotation is accounted for exactly once")
        require(drawnMarkup == 0, "this fixture carries no text markup at all")
        require(drawnNotes == 2, "both sticky notes are classified as drawn")
        require(drawnText == 2, "both readable free texts are classified as drawn")
        require(drawnGeometry == 0,
                "the fixture's /InkList is the malformed flat form, so no stroke is drawn")
        require(skipReasons == ["no-text", "hidden", "empty-geometry"],
                "the three undrawn annotations say why, got \(skipReasons)")

        // A note that is classified as drawn has to *reach the canvas*, in the note index block.
        let colouredNote = state.documentAnnotations[0]
        let plainNote = state.documentAnnotations[1]
        let freeText = state.documentAnnotations[2]
        let hiddenNote = state.documentAnnotations[5]
        let ink = state.documentAnnotations[6]
        try await eventually("the sticky note's icon reaches the canvas", {
            state.canvasPages.contains { $0.placement.index == PlacementIndex.documentNote(0) }
        })
        try await eventually("the free-text annotation's text reaches the canvas", {
            state.canvasPages.contains { $0.placement.index == PlacementIndex.documentNote(2) }
        })
        guard let iconQuad = state.canvasPages.first(where: {
            $0.placement.index == PlacementIndex.documentNote(0)
        }), let textQuad = state.canvasPages.first(where: {
            $0.placement.index == PlacementIndex.documentNote(2)
        }) else {
            fatalError("FAIL: the note quads left the frame they were just seen in")
        }

        // The icon is a bitmap, not a tint, and it is placed exactly on the annotation's /Rect.
        require(iconQuad.image.pixelWidth > 8 && iconQuad.image.pixelHeight > 8,
                "a sticky note is drawn as an icon, not as a 1x1 tint "
                    + "(\(iconQuad.image.pixelWidth)x\(iconQuad.image.pixelHeight) px)")
        require(iconQuad.blend == .normal, "a note icon is composited alpha-over, not multiplied")
        require(abs(iconQuad.placement.widthPt - colouredNote.widthPt) < 0.001
                    && abs(iconQuad.placement.heightPt - colouredNote.heightPt) < 0.001,
                "the icon fills the /Rect the file gives the note")

        // The free text is laid out at the size the file's /DA states.
        require(freeText.fontSizePt == 14, "the 14 pt /DA size arrives, got "
                    + "\(String(describing: freeText.fontSizePt))")
        require(freeText.alignment == "center", "/Q 1 arrives as center")
        require(textQuad.image.pixelWidth > 64 && textQuad.image.pixelHeight > 8,
                "free text is drawn as a text raster (\(textQuad.image.pixelWidth)"
                    + "x\(textQuad.image.pixelHeight) px)")
        require(textQuad.blend == .normal, "free text is composited alpha-over")

        // Nothing is drawn for what the file hides or for what this build has no rule for.
        require(!state.canvasPages.contains { $0.placement.index == PlacementIndex.documentNote(5) },
                "a hidden note gets no quad, so the page cannot contradict the file")
        require(!state.canvasPages.contains { $0.placement.index == PlacementIndex.documentNote(6) },
                "a malformed /Ink annotation gets no quad — it is reported, not invented")
        require(ink.kind == "ink" && ink.drawing == .skipped
                    && ink.skipReason == .emptyGeometry,
                "the /Ink is still named, with the reason it has no path to draw")
        // Five, not four: the sidebar lists what a note *is*, so the empty free-text annotation
        // (undrawn, `no-text`) is in the list even though it puts nothing on the page.
        require(state.documentNotes.count == 5,
                "the sidebar still lists every visible note, drawn or not "
                    + "(\(state.documentNotes.count))")
        require(hiddenNote.visible == false && ink.isNote == false,
                "the two undrawn annotations are still classified as what they are")

        // ── 2. Clicking a drawn note shows its contents ──
        // The click point is in content space, which is where the canvas reports pointer events.
        let iconCentre = CGPoint(
            x: iconQuad.placement.leftPt + iconQuad.placement.widthPt / 2,
            y: iconQuad.placement.topPt + iconQuad.placement.heightPt / 2
        )
        require(state.openDocumentNote(at: iconCentre), "a click on the note icon finds the note")
        require(state.selectedDocumentAnnotationID == colouredNote.id,
                "the clicked note is the one the sidebar highlights")
        require(state.openDocumentNote?.contents == colouredNote.contents,
                "the clicked note expands its complete text on the canvas")
        state.closeDocumentNote()
        require(state.openDocumentNote == nil, "the note paper can be closed")
        require(state.openDocumentNote(at: iconCentre), "the note can be reopened")
        require(state.statusMessage.contains("sticky note with a colour"),
                "the note's own text is shown, got \"\(state.statusMessage)\"")
        require(!state.openDocumentNote(at: CGPoint(x: iconCentre.x - 200, y: iconCentre.y)),
                "a click on the page background opens no note")
        // …and the sidebar's own jump selects the same row, so the two directions agree.
        state.jump(toDocumentAnnotation: plainNote)
        require(state.selectedDocumentAnnotationID == plainNote.id,
                "jumping from the sidebar selects that row too")

        // Through the real click path, which ends the selection *first* and only then resolves a
        // target (#55). A click on a note has to do both halves, so this pins the merge: drop the
        // first and the note opens with the old selection still highlighted behind it; drop the
        // second and a drawn note is not clickable at all.
        let seed = AppState.Annotation(
            id: UUID(),
            page: 0,
            start: 0,
            end: 3,
            color: AppState.highlightPalette[0].color,
            note: "",
            createdAt: Date()
        )
        state.jump(to: seed)
        require(state.selection != nil, "something is selected before the click")
        state.endPointerInteraction(at: iconCentre, wasClick: true)
        require(state.selection == nil, "a click still ends the selection, wherever it lands")
        require(state.selectedDocumentAnnotationID == colouredNote.id,
                "…and a click on a drawn note still opens that note")
        require(state.statusMessage.contains("sticky note with a colour"),
                "the clicked note's text is what the status line shows, got \"\(state.statusMessage)\"")

        // ── 3. The pixels: the quads the canvas was handed, composited ──
        guard let snapshot = CanvasSnapshot(pages: state.canvasPages, scale: 2) else {
            fatalError("FAIL: the canvas quads could not be composited for a pixel check")
        }
        let noteBox = CGRect(
            x: iconQuad.placement.leftPt,
            y: iconQuad.placement.topPt,
            width: iconQuad.placement.widthPt,
            height: iconQuad.placement.heightPt
        )
        let noteColour = colouredNote.color ?? AnnotationColor.defaultNote
        let fill = snapshot.fraction(ofColor: noteColour, inContentRect: noteBox)
        require(fill > 0.25,
                "the sticky note is drawn in its own colour over the page (\(Int(fill * 100))% of "
                    + "its box is \(noteColour.hex) \(snapshot.describe(noteBox)))")
        let textBox = CGRect(
            x: textQuad.placement.leftPt,
            y: textQuad.placement.topPt,
            width: textQuad.placement.widthPt,
            height: textQuad.placement.heightPt
        )
        let textInk = snapshot.fractionOfInk(inContentRect: textBox)
        require(textInk > 0.01,
                "the free-text annotation's text is on the page (\(Int(textInk * 100))% of its "
                    + "box is ink \(snapshot.describe(textBox)))")
        // …and the second note, which the file gives no colour, is drawn in the default one.
        let plainQuad = state.canvasPages.first {
            $0.placement.index == PlacementIndex.documentNote(1)
        }
        if let plainQuad {
            let plainBox = CGRect(
                x: plainQuad.placement.leftPt,
                y: plainQuad.placement.topPt,
                width: plainQuad.placement.widthPt,
                height: plainQuad.placement.heightPt
            )
            let plainFill = snapshot.fraction(
                ofColor: AnnotationColor.defaultNote,
                inContentRect: plainBox
            )
            require(plainFill > 0.25,
                    "a note with no /C is still visible, in the default note colour "
                        + "(\(Int(plainFill * 100))% of its box)")
        } else {
            fatalError("FAIL: the colourless note reached no quad")
        }
        if let directory = ProcessInfo.processInfo.environment["LYRA_READER_CHECK_SNAPSHOT_DIR"] {
            snapshot.write(to: URL(fileURLWithPath: directory)
                .appendingPathComponent("annotated-notes.png"))
        }
    }

    /// The quads `MetalCanvasView` was handed, composited into one bitmap.
    ///
    /// **This is not a screenshot.** It is a CPU composite of the same placements and the same
    /// blend modes the GPU is given, which is the most a headless run can produce: the Metal path
    /// needs a presentable surface, and an occluded window never presents (see
    /// `frameSchedulingChecks`). What it does prove is that the *handover* is right — that a note
    /// glyph is a real bitmap, in the right place, in the right colour — which is where both of
    /// this area's defects have actually lived.
    ///
    /// Blend modes mirror `lyra-reader-gpu`'s shaders: alpha-over for `normal`, and CoreGraphics'
    /// `multiply` for a tint whose `/CA` is already baked into its colour, which reproduces the
    /// GPU's `dst × (a·c + 1 − a)` exactly at alpha 255.
    struct CanvasSnapshot {
        private let width: Int
        private let height: Int
        private let pixels: [UInt8]
        private let origin: CGPoint
        private let scale: CGFloat

        @MainActor init?(pages: [CanvasPage], scale: CGFloat) {
            guard !pages.isEmpty else { return nil }
            let originX = pages.map(\.placement.leftPt).min() ?? 0
            let originY = pages.map(\.placement.topPt).min() ?? 0
            let widthPt = (pages.map { $0.placement.leftPt + $0.placement.widthPt }.max() ?? 0) - originX
            let heightPt = (pages.map { $0.placement.topPt + $0.placement.heightPt }.max() ?? 0) - originY
            let width = max(1, Int((widthPt * scale).rounded()))
            let height = max(1, Int((heightPt * scale).rounded()))
            let info = CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: info
            ) else { return nil }

            // The page is white paper under everything: an unpainted pixel is page, not hole.
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))

            for page in pages {
                // Content space is top-down and CoreGraphics is bottom-up, so the rectangle is
                // placed by its top edge. The image itself is not flipped: `CGContext.draw` maps
                // an image's first row to the maximum-Y edge of the destination rectangle.
                let rect = CGRect(
                    x: (page.placement.leftPt - originX) * scale,
                    y: (CGFloat(height))
                        - (page.placement.topPt - originY + page.placement.heightPt) * scale,
                    width: page.placement.widthPt * scale,
                    height: page.placement.heightPt * scale
                )
                guard let image = Self.cgImage(for: page) else { continue }
                context.setBlendMode(page.blend == .multiply ? .multiply : .normal)
                context.draw(image, in: rect)
            }
            context.setBlendMode(.normal)

            guard let data = context.data else { return nil }
            self.width = width
            self.height = height
            self.pixels = Array(UnsafeBufferPointer(
                start: data.bindMemory(to: UInt8.self, capacity: width * height * 4),
                count: width * height * 4
            ))
            self.origin = CGPoint(x: originX, y: originY)
            self.scale = scale
        }

        /// A `PageImage` as a `CGImage`, with the alpha convention it was built with.
        ///
        /// Page rasters come from PDFium premultiplied; every overlay this application builds —
        /// the 1×1 tints and both note glyphs — is straight alpha, which is what the quad
        /// pipeline's blend state expects. Whole-page rasters are opaque and the overlays are
        /// not, so the two conventions are the ones the bytes were written in.
        private static func cgImage(for page: CanvasPage) -> CGImage? {
            let alpha: CGImageAlphaInfo = PlacementIndex.isPageRaster(page.placement.index)
                ? .premultipliedFirst
                : .first
            let info = CGBitmapInfo(rawValue: alpha.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            guard let provider = CGDataProvider(data: page.image.bgra as CFData) else { return nil }
            return CGImage(
                width: page.image.pixelWidth,
                height: page.image.pixelHeight,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: page.image.pixelWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: info,
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        }

        /// The pixel at a point in **content space** (top-left origin, points), or `nil` outside.
        func pixel(atContentPoint point: CGPoint) -> (red: UInt8, green: UInt8, blue: UInt8)? {
            let x = Int(((point.x - origin.x) * scale).rounded(.down))
            let y = Int(((point.y - origin.y) * scale).rounded(.down))
            guard x >= 0, y >= 0, x < width, y < height else { return nil }
            let offset = (y * width + x) * 4
            return (pixels[offset + 2], pixels[offset + 1], pixels[offset])
        }

        /// How much of a content-space rectangle is a given colour, by area.
        func fraction(ofColor color: AnnotationColor, inContentRect rect: CGRect) -> Double {
            scan(rect) { red, green, blue in
                abs(Int(red) - Int(color.red)) <= 2
                    && abs(Int(green) - Int(color.green)) <= 2
                    && abs(Int(blue) - Int(color.blue)) <= 2
            }
        }

        /// How much of a content-space rectangle is *not* the white page — i.e. ink.
        func fractionOfInk(inContentRect rect: CGRect) -> Double {
            scan(rect) { red, green, blue in
                Int(red) + Int(green) + Int(blue) < 3 * 240
            }
        }

        /// The colours found in a rectangle, for a failure message that says what was drawn.
        func describe(_ rect: CGRect) -> String {
            let corners = [
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.midX, y: rect.midY),
                CGPoint(x: rect.maxX - 1, y: rect.maxY - 1),
            ].compactMap { point -> String? in
                guard let colour = pixel(atContentPoint: point) else { return nil }
                return String(format: "#%02X%02X%02X", colour.red, colour.green, colour.blue)
            }
            return "at \(corners.joined(separator: "/"))"
        }

        private func scan(
            _ rect: CGRect,
            _ matches: (UInt8, UInt8, UInt8) -> Bool
        ) -> Double {
            let minX = max(0, Int(((rect.minX - origin.x) * scale).rounded(.down)))
            let minY = max(0, Int(((rect.minY - origin.y) * scale).rounded(.down)))
            let maxX = min(width, Int(((rect.maxX - origin.x) * scale).rounded(.up)))
            let maxY = min(height, Int(((rect.maxY - origin.y) * scale).rounded(.up)))
            guard maxX > minX, maxY > minY else { return 0 }
            var hits = 0
            var total = 0
            for y in minY..<maxY {
                for x in minX..<maxX {
                    let offset = (y * width + x) * 4
                    total += 1
                    if matches(pixels[offset + 2], pixels[offset + 1], pixels[offset]) {
                        hits += 1
                    }
                }
            }
            return total == 0 ? 0 : Double(hits) / Double(total)
        }

        /// Writes the composite as a PNG, for a human to look at afterwards.
        func write(to url: URL) {
            let info = CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
            guard let provider = CGDataProvider(data: Data(pixels) as CFData),
                  let image = CGImage(
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bitsPerPixel: 32,
                      bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGBitmapInfo(rawValue: info),
                      provider: provider,
                      decode: nil,
                      shouldInterpolate: false,
                      intent: .defaultIntent
                  ),
                  let destination = CGImageDestinationCreateWithURL(
                      url as CFURL,
                      "public.png" as CFString,
                      1,
                      nil
                  )
            else { return }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            print("INFO: wrote \(url.path)")
        }
    }
}
