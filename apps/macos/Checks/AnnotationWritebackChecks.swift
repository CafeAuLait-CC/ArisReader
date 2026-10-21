import AppKit
import LyraReaderKit
import CoreGraphics
import Foundation
import PDFKit

extension ReaderChecks {
    /// PDF write-back: copy, replace, backup, duplicate avoidance and what another viewer sees.
    ///
    /// This runs the real engine end to end on a scratch copy of `tests/fixtures/text-page.pdf`:
    /// it seeds an annotation cache with two annotations, writes them into a PDF, reopens that PDF with the
    /// reader, and renders it with **PDFKit** — the engine Preview uses — to check that the
    /// highlight is visible and the glyphs stay black under it. The Rust tests cover the
    /// field-by-field round trip, the backup failure and the interrupted-save paths; this check
    /// covers the shell half: which entries disappear from the annotation cache, which do not, and that a
    /// reopen shows each annotation exactly once.
    @MainActor static func annotationWritebackChecks(fixture: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-reader-writeback-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        // ── The text ranges the two cached annotations cover ──────────────────────────
        let probe = try RustEngine()
        let loaded = try probe.openDocument(at: fixture)
        require(loaded.pageCount == 1, "write-back fixture is one page")
        let text = try await probe.textPage(0)
        func index(of needle: String) -> Int {
            let pattern = Array(needle.unicodeScalars.map(\.value))
            guard pattern.count > 0, text.chars.count >= pattern.count else {
                fatalError("fixture text does not contain \(needle)")
            }
            outer: for start in 0...(text.chars.count - pattern.count) {
                for offset in 0..<pattern.count
                where text.chars[start + offset].unicode != pattern[offset] {
                    continue outer
                }
                return start
            }
            fatalError("fixture text does not contain \(needle)")
        }
        let firstStart = index(of: "Line 1")
        let secondStart = index(of: "Line 2")
        let firstRange = firstStart...(firstStart + 5)
        let secondRange = secondStart...(secondStart + 5)
        let firstRects = text.selectionRects(in: firstRange)
        let secondRects = text.selectionRects(in: secondRange)
        require(!firstRects.isEmpty && !secondRects.isEmpty,
                "the two write-back ranges have text geometry")

        let firstID = UUID()
        let secondID = UUID()
        let first = AppState.Annotation(
            id: firstID,
            kind: .highlight,
            page: 0,
            start: firstRange.lowerBound,
            end: firstRange.upperBound,
            color: AppState.highlightPalette[0].color,
            note: "first saved note",
            createdAt: Date()
        )
        let second = AppState.Annotation(
            id: secondID,
            kind: .underline,
            page: 0,
            start: secondRange.lowerBound,
            end: secondRange.upperBound,
            color: AppState.highlightPalette[2].color,
            note: "second saved note",
            createdAt: Date()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        func entry<Value: Encodable>(_ value: Value) throws -> String {
            let encoded = String(decoding: try encoder.encode([value]), as: UTF8.self)
            return String(encoded.dropFirst(2).dropLast(2))
        }
        let foreignID = UUID()
        let foreignEntry = #"{"colorIndex":1,"id":"\#(foreignID.uuidString)","kind":"ink","page":0,"note":"from a newer LyraReader","start":0,"end":1,"strokes":[[1,2],[3,4]]}"#
        let bookmark = Bookmark(page: 0, title: "write-back bookmark", yPt: 12)

        func makeDocument(named name: String, withStaleTemporary: Bool) throws -> URL {
            let document = scratch.appendingPathComponent(name)
            try fileManager.copyItem(at: fixture, to: document)
            let records = DocumentEditCache.annotationsURL(for: document)
            let recordsText = "[\n"
                + [try entry(first), try entry(second), try entry(bookmark), foreignEntry]
                    .joined(separator: ",\n")
                + "\n]"
            try Data(recordsText.utf8).write(to: records)
            if withStaleTemporary {
                // A crashed save leaves this behind; the rename is the last step, so the
                // document itself is still the last good file.
                let temporary = scratch.appendingPathComponent(
                    "\(document.lastPathComponent).lyra-reader-save-999-1.tmp"
                )
                try Data("partial PDF".utf8).write(to: temporary)
            }
            return document
        }

        // ── 1. Save an annotated copy; the original and its annotation cache are untouched ──────
        let copySource = try makeDocument(named: "copy-source.pdf", withStaleTemporary: true)
        let copySourceRecords = DocumentEditCache.annotationsURL(for: copySource)
        let copyOriginalBytes = try Data(contentsOf: copySource)
        let copyRecordsBytes = try Data(contentsOf: copySourceRecords)
        let staleTemporary = scratch.appendingPathComponent(
            "\(copySource.lastPathComponent).lyra-reader-save-999-1.tmp"
        )

        let copyState = AppState(engine: try RustEngine())
        copyState.setViewportSize(CGSize(width: 700, height: 500))
        copyState.newTab(url: copySource)
        require(copyState.annotations.count == 2, "the seeded annotation cache loads two annotations")
        require(copyState.interruptedAnnotationSaveNotice != nil,
                "a leftover temporary is reported on open")
        require(copyState.canSaveAnnotationsToPDF, "the save commands are enabled with annotations")

        let copyURL = scratch.appendingPathComponent("annotated-copy.pdf")
        let copied = await copyState.saveAnnotatedCopy(to: copyURL)
        require(copied, "saving an annotated copy succeeds")
        require(fileManager.fileExists(atPath: copyURL.path), "the annotated copy exists")
        let copySourceAfter = try Data(contentsOf: copySource)
        let copyRecordsAfter = try Data(contentsOf: copySourceRecords)
        require(copySourceAfter == copyOriginalBytes,
                "the original PDF is byte-identical after a copy save")
        require(copyRecordsAfter == copyRecordsBytes,
                "the original annotation cache is untouched after a copy save")
        require(!fileManager.fileExists(atPath: staleTemporary.path),
                "the interrupted save's temporary file was cleaned up")
        if let report = copyState.lastAnnotationWriteReport {
            require(report.backupPath == nil, "a copy save writes no backup")
            require(report.writtenIDs.count == 2, "the report names the two written annotations")
            require(report.writtenBookmarkIDs == [bookmark.id.uuidString],
                    "the report names the written bookmark")
            require(report.bookmarkOutlineTitle == "My bookmarks",
                    "the bookmark subtree has the fixed title")
            require(report.preexistingOutlineEntryCount == 0,
                    "the one-page fixture had no outline before the write")
            require(report.preexistingAnnotationCount == 0,
                    "the one-page fixture had no annotations before the write")
            require(report.appendedBytes > 0 && report.sourceBytesPreserved,
                    "the copy is an append-only update of its source")
        } else {
            require(false, "a successful save publishes a report")
        }

        // ── 2. Reopening the copy: one copy of each annotation, from the PDF, no annotation cache ──
        let copyRecordsURL = DocumentEditCache.annotationsURL(for: copyURL)
        require(!fileManager.fileExists(atPath: copyRecordsURL.path),
                "a copy carries no cached annotations, so reopening it cannot duplicate entries")
        let copyReopen = AppState(engine: try RustEngine())
        copyReopen.setViewportSize(CGSize(width: 700, height: 500))
        copyReopen.newTab(url: copyURL)
        require(copyReopen.annotations.isEmpty, "the copy has no cached annotations")
        try await eventually("reopening the copy reads its PDF annotations", {
            copyReopen.documentAnnotations.count == 2
        })
        try await eventually("reopening the copy adopts its outline bookmarks", {
            copyReopen.bookmarks.map(\.id) == [bookmark.id]
        })
        require(copyReopen.bookmarks.first?.yPt == bookmark.yPt,
                "the adopted bookmark keeps its page-local position")
        require(copyReopen.outline.contains { $0.isBookmarkSubtree },
                "the copy's sidebar lists the bookmark subtree in its outline")

        let identities = Set(copyReopen.documentAnnotations.map(\.id))
        require(identities.contains("nm:\(firstID.uuidString)"),
                "the highlight is in the copy exactly once")
        require(identities.contains("nm:\(secondID.uuidString)"),
                "the underline is in the copy exactly once")
        require(copyReopen.documentAnnotations.count == 2,
                "the copy shows each written annotation once, not twice")

        let reopenedHighlight = copyReopen.documentAnnotations
            .first { $0.id == "nm:\(firstID.uuidString)" }!
        require(reopenedHighlight.contents == "first saved note",
                "the highlight's note round-trips as /Contents")
        require(reopenedHighlight.author == AppState.annotationAuthor,
                "the author is written and read back")
        require(reopenedHighlight.color?.red == first.color.red
                    && reopenedHighlight.color?.green == first.color.green
                    && reopenedHighlight.color?.blue == first.color.blue,
                "the colour round-trips")
        let expectedOpacity = Double(first.color.alpha) / 255.0
        require(abs((reopenedHighlight.opacity ?? -1) - expectedOpacity) < 0.002,
                "the opacity round-trips")
        require(reopenedHighlight.blend == "multiply",
                "a highlight with no /BM reads back as multiply")
        require(reopenedHighlight.quads.count == firstRects.count,
                "the highlight has one quad per selected line")
        for (quad, expected) in zip(reopenedHighlight.quads, firstRects) {
            require(abs(quad.xPt - expected.minX) < 0.02
                        && abs(quad.yPt - expected.minY) < 0.02
                        && abs(quad.widthPt - expected.width) < 0.02
                        && abs(quad.heightPt - expected.height) < 0.02,
                    "the saved highlight reloads at the place it was selected")
        }
        let reopenedUnderline = copyReopen.documentAnnotations
            .first { $0.id == "nm:\(secondID.uuidString)" }!
        require(reopenedUnderline.kind == "underline",
                "the annotation cache's underline is written as /Subtype /Underline")
        require(reopenedUnderline.blend == "multiply",
                "an underline with no /BM reads back as multiply")

        // ── 3. What another viewer sees: PDFKit is the engine Preview uses ─────────────
        let pixels = try pdfKitPixelCounts(
            url: copyURL,
            viewSpaceRect: firstRects[0],
            scale: 2
        )
        require(pixels.yellow > 100,
                "PDFKit shows the highlight without an appearance stream (\(pixels.yellow) yellow px)")
        require(pixels.dark > 20,
                "PDFKit keeps the glyphs black under the highlight (\(pixels.dark) dark px)")
        FileHandle.standardError.write(Data(
            "lyra-reader-writeback: PDFKit highlight pixels yellow=\(pixels.yellow) dark=\(pixels.dark)\n".utf8
        ))

        // ── 3b. A /Text note: the writer supports it, and Preview shows an icon ────────
        // The shell has no standalone note object (its `note` field belongs to a highlight),
        // so this exercises the engine's /Text path directly. It is still the same writer the
        // replace command uses.
        let noteURL = scratch.appendingPathComponent("note-copy.pdf")
        let noteColor = AnnotationColor.defaultNote
        let noteRequest = AnnotationWriteRequest(
            id: "44444444-4444-4444-4444-444444444444",
            page: 0,
            kind: .note,
            rect: CGRect(x: 500, y: 100, width: 26, height: 26),
            quads: [],
            color: noteColor,
            opacity: 1.0,
            contents: "A sticky note body.",
            author: AppState.annotationAuthor,
            modified: AppState.pdfDate(Date())
        )
        let noteReport = try await probe.saveAnnotatedCopy(
            to: noteURL,
            annotations: [noteRequest],
            bookmarks: [],
            zoom: 1.0
        )
        require(noteReport.writtenIDs == [noteRequest.id], "the note is written once")
        let noteReopen = AppState(engine: try RustEngine())
        noteReopen.setViewportSize(CGSize(width: 700, height: 500))
        noteReopen.newTab(url: noteURL)
        try await eventually("reopening the note copy reads the /Text annotation", {
            noteReopen.documentAnnotations.count == 1
        })
        let reopenedNote = noteReopen.documentAnnotations[0]
        require(reopenedNote.kind == "text", "the note keeps /Subtype /Text")
        require(reopenedNote.contents == "A sticky note body.", "the note contents round-trip")
        require(reopenedNote.author == AppState.annotationAuthor, "the note author round-trips")
        require(reopenedNote.drawing == .noteIcon, "the reader classifies it as a note icon")
        let notePixels = try pdfKitNonWhiteCount(
            url: noteURL,
            viewSpaceRect: CGRect(x: 500, y: 100, width: 26, height: 26),
            scale: 2
        )
        require(notePixels > 30,
                "PDFKit renders a note icon for the /Text annotation (\(notePixels) non-white px)")

        // ── 4. Replace the original: verified backup, exact annotation cache removal, no duplicates ──
        let replaceSource = try makeDocument(named: "replace-source.pdf", withStaleTemporary: false)
        let replaceRecords = DocumentEditCache.annotationsURL(for: replaceSource)
        let replaceOriginalBytes = try Data(contentsOf: replaceSource)
        let replaceState = AppState(engine: try RustEngine())
        replaceState.setViewportSize(CGSize(width: 700, height: 500))
        replaceState.newTab(url: replaceSource)
        require(replaceState.annotations.count == 2, "the replace fixture loads two annotations")

        let replaced = await replaceState.replaceOriginalWithSavedAnnotations()
        require(replaced, "replacing the original succeeds")
        let replacedBytes = try Data(contentsOf: replaceSource)
        require(replacedBytes != replaceOriginalBytes,
                "the chosen path now carries the annotations")
        guard let report = replaceState.lastAnnotationWriteReport else {
            require(false, "the replace publishes a report")
            return
        }
        guard let backupPath = report.backupPath else {
            require(false, "the replace names its backup")
            return
        }
        require(fileManager.fileExists(atPath: backupPath), "the backup exists on disk")
        let backupBytes = try Data(contentsOf: URL(fileURLWithPath: backupPath))
        require(backupBytes == replaceOriginalBytes,
                "the backup is byte-identical to the original")

        let recordsText = String(decoding: try Data(contentsOf: replaceRecords), as: UTF8.self)
        require(!recordsText.contains(firstID.uuidString)
                    && !recordsText.contains(secondID.uuidString),
                "exactly the saved entries are removed from the annotation cache")
        require(recordsText.contains(foreignEntry),
                "a foreign entry is preserved verbatim through the replace")
        require(!recordsText.contains(bookmark.id.uuidString),
                "the bookmark is saved into the PDF and removed from the annotation cache")
        try await eventually("the replaced document reopens with its PDF annotations", {
            replaceState.documentAnnotations.count == 2
        })
        try await eventually("the replaced document adopts its saved bookmark", {
            replaceState.bookmarks.map(\.id) == [bookmark.id]
        })
        require(replaceState.annotations.isEmpty,
                "the saved entries are gone from the annotation model")
        require(replaceState.documentAnnotations.count == 2,
                "reopening the replaced file shows each annotation once")
        try await eventually("the replaced page has one tint quad per annotation", {
            replaceState.canvasPages.filter {
                $0.image.pixelWidth == 1 && $0.image.pixelHeight == 1
            }.count == 2
        })

        // ── 5. Reconciliation when the annotation cache still has saved entries ────────────────
        // This is the failure mode a PDF-first save leaves: the PDF is written, the annotation cache
        // write is not. Reopening must show the PDF's copy once, not the PDF's copy plus the
        // annotation cache's.
        let staleText = "[\n" + [try entry(first), try entry(second)].joined(separator: ",\n") + "\n]"
        try Data(staleText.utf8).write(to: replaceRecords)
        let reconciled = AppState(engine: try RustEngine())
        reconciled.setViewportSize(CGSize(width: 700, height: 500))
        reconciled.newTab(url: replaceSource)
        require(reconciled.annotations.count == 2, "the stale annotation cache loads before reconciliation")
        try await eventually("the PDF annotations load for reconciliation", {
            reconciled.documentAnnotations.count == 2
        })
        try await eventually("saved annotation-cache entries are reconciled away", {
            reconciled.annotations.isEmpty
        })
        try await eventually("the canvas draws one quad per annotation after reconciliation", {
            reconciled.canvasPages.filter {
                $0.image.pixelWidth == 1 && $0.image.pixelHeight == 1
            }.count == 2
        })
        require(reconciled.documentAnnotations.count == 2,
                "the reopened file still shows each annotation once")

        // The next ordinary cache write drops the reconciled entries from the file too.
        reconciled.addBookmarkAtCurrentPage(name: "after reconciliation")
        let cleanedText = String(decoding: try Data(contentsOf: replaceRecords), as: UTF8.self)
        require(!cleanedText.contains(firstID.uuidString)
                    && !cleanedText.contains(secondID.uuidString),
                "a later cache write removes the reconciled entries")
        require(cleanedText.contains("after reconciliation"),
                "a later bookmark is still written to the same annotation cache")
    }

    /// Renders page 0 of `url` with PDFKit and counts highlight and glyph pixels inside
    /// `viewSpaceRect`.
    ///
    /// PDFKit applies the same Y flip the canvas does, so the bitmap row for a view-space Y is
    /// `y × scale`; the test itself would be meaningless if it guessed the other orientation,
    /// which is why the expected band comes from the reader's own text geometry.
    @MainActor
    private static func pdfKitPixelCounts(
        url: URL,
        viewSpaceRect: CGRect,
        scale: CGFloat
    ) throws -> (yellow: Int, dark: Int) {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else {
            throw NSError(
                domain: "LyraReader",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "PDFKit could not open the saved copy"]
            )
        }
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(ceil(bounds.width * scale))
        let height = Int(ceil(bounds.height * scale))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(
                domain: "LyraReader",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "could not create a PDFKit bitmap"]
            )
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)

        guard let data = context.data else {
            throw NSError(
                domain: "LyraReader",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "PDFKit produced no bitmap"]
            )
        }
        let bytesPerRow = context.bytesPerRow
        let png = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        // Inset by a few pixels so the annotation's own edge antialiasing is not counted.
        let minX = max(Int(viewSpaceRect.minX * scale) + 6, 0)
        let maxX = min(Int(viewSpaceRect.maxX * scale) - 6, width - 1)
        let minY = max(Int(viewSpaceRect.minY * scale) + 2, 0)
        let maxY = min(Int(viewSpaceRect.maxY * scale) - 2, height - 1)
        var yellow = 0
        var dark = 0
        guard minX < maxX, minY < maxY else { return (0, 0) }
        for y in minY...maxY {
            for x in minX...maxX {
                let offset = y * bytesPerRow + x * 4
                let red = UInt16(png[offset])
                let green = UInt16(png[offset + 1])
                let blue = UInt16(png[offset + 2])
                if red > 180 && green > 150 && blue < 120 {
                    yellow += 1
                }
                if red < 40 && green < 40 && blue < 40 {
                    dark += 1
                }
            }
        }
        return (yellow, dark)
    }
    /// Counts non-white pixels in `viewSpaceRect`, for "did another viewer draw the note icon?".
    @MainActor
    private static func pdfKitNonWhiteCount(
        url: URL,
        viewSpaceRect: CGRect,
        scale: CGFloat
    ) throws -> Int {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else {
            throw NSError(
                domain: "LyraReader",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "PDFKit could not open the saved note copy"]
            )
        }
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(ceil(bounds.width * scale))
        let height = Int(ceil(bounds.height * scale))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(
                domain: "LyraReader",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "could not create a PDFKit bitmap"]
            )
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        guard let data = context.data else { return 0 }
        let bytesPerRow = context.bytesPerRow
        let png = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        let minX = max(Int(viewSpaceRect.minX * scale) - 4, 0)
        let maxX = min(Int(viewSpaceRect.maxX * scale) + 4, width - 1)
        let minY = max(Int(viewSpaceRect.minY * scale) - 4, 0)
        let maxY = min(Int(viewSpaceRect.maxY * scale) + 4, height - 1)
        var count = 0
        guard minX < maxX, minY < maxY else { return 0 }
        for y in minY...maxY {
            for x in minX...maxX {
                let offset = y * bytesPerRow + x * 4
                if png[offset] < 240 || png[offset + 1] < 240 || png[offset + 2] < 240 {
                    count += 1
                }
            }
        }
        return count
    }

}
