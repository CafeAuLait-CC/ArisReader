import ArisReaderKit
import Foundation

extension ReaderChecks {
    @MainActor static func annotationChecks(a: URL, b: URL) async throws {
        let sidecar = a.appendingPathExtension("aris-annotations.json")
        let annotation = AppState.Annotation(id: UUID(), page: 0, start: 0, end: 3,
            colorIndex: 0, note: "old", createdAt: Date())
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
            colorIndex: 0, note: "kept", createdAt: Date())
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
            colorIndex: 0, note: "known entry", createdAt: Date())
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
        let expectedColor = Data(AppState.highlightPalette[known.colorIndex].bgra)
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
            colorIndex: 0, note: "", createdAt: Date())
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
            colorIndex: 0, note: "first", createdAt: Date())
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
}
