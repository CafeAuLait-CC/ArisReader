import AppKit
import LyraReaderKit
import CoreGraphics
import Foundation

extension ReaderChecks {
    /// T3.12 redaction through the real engine and the FFI boundary.
    ///
    /// The Rust unit tests prove the content-stream rewrite; this check proves the path the
    /// shell uses: view-space rectangles are converted by the FFI, the copy does not touch the
    /// source, the saved page has no extractable text under the mark and keeps the text outside
    /// it, the mark renders black, the vector path is gone beyond the mark, and the replace path
    /// writes a byte-identical backup first. It also checks the pending-mark model the canvas
    /// and the confirmation dialog are built on.
    @MainActor static func redactionChecks(root: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-reader-redaction-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("page.pdf")
        try fileManager.copyItem(
            at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: source)
        let originalBytes = try Data(contentsOf: source)

        let engine = try RustEngine()
        let loaded = try engine.openDocument(at: source)
        require(loaded.pageCount == 1, "the redaction fixture is one page")
        let page = try await engine.textPage(0)

        func range(of needle: String) -> ClosedRange<Int> {
            let pattern = Array(needle.unicodeScalars.map(\.value))
            outer: for start in 0...(page.chars.count - pattern.count) {
                for offset in 0..<pattern.count
                where page.chars[start + offset].unicode != pattern[offset] {
                    continue outer
                }
                return start...(start + pattern.count - 1)
            }
            fatalError("fixture text does not contain \(needle)")
        }

        // The rectangle the shell would send: the union of the glyph boxes, in page-local
        // top-left points (what `TextChar` reports), padded like a dragged mark.
        let brownRange = range(of: "brown")
        var brownRect = CGRect.zero
        for character in page.chars[brownRange] {
            let box = CGRect(x: character.xPt, y: character.yPt,
                             width: character.widthPt, height: character.heightPt)
            brownRect = brownRect.isEmpty ? box : brownRect.union(box)
        }
        let mark = brownRect.insetBy(dx: -1, dy: -1)
        let area = RedactionArea(page: 0, rect: mark)

        // ── The confirmation's preview says what will be lost ──────────────────────────────
        let preview = try await engine.previewRedactions([area])
        require(preview.removedCharacters >= 5,
                "the preview counts the covered characters (\(preview.removedCharacters))")
        require(preview.pages.first?.textPreview.contains("brown") == true,
                "the preview shows the covered text")

        // ── Copy: the original is untouched and the covered text is gone ──────────────────
        let copy = scratch.appendingPathComponent("redacted.pdf")
        let report = try await engine.redactToCopy(to: copy, areas: [area])
        require(report.verified, "the writer verified the saved copy")
        require(report.originalUnchanged, "the copy mode reports the original as unchanged")
        require(report.backupPath == nil, "a copy writes no backup beside the original")
        let sourceAfterCopy = try Data(contentsOf: source)
        require(sourceAfterCopy == originalBytes,
                "the original file is byte-identical after the copy")
        require(report.removedCharacters >= 5, "the report counts the removed characters")
        require(report.pages.first?.rasterized == false,
                "the text page is rewritten, not rasterised")

        let savedReader = try RustEngine()
        _ = try savedReader.openDocument(at: copy)
        let savedPage = try await savedReader.textPage(0)
        require(!savedPage.text.contains("brown"),
                "the covered word is not extractable from the saved file")
        require(savedPage.text.contains("quick") && savedPage.text.contains("jumps"),
                "text before and after the mark survives")
        require(savedPage.text.contains("LyraReader fixture") && savedPage.text.contains("Line 6:"),
                "text outside the mark on other lines survives")

        let scale: CGFloat = 2
        let savedImage = try await savedReader.renderPage(0, scale: scale)
        let markCentre = CGPoint(x: mark.midX, y: mark.midY)
        let markPixel = pixel(savedImage, atPagePoint: markCentre)
        require(markPixel.red < 40 && markPixel.green < 40 && markPixel.blue < 40,
                "the saved page shows the black mark (\(markPixel))")

        // ── A vector object under the mark is removed, not painted over ──────────────────
        // The fixture strokes a blue rectangle from PDF (72, 300) to (523, 420). Mark a small
        // area inside it; the stroke at the far right edge is outside the black mark, so a
        // paint-over would leave blue pixels there.
        let vectorSource = scratch.appendingPathComponent("vector.pdf")
        try fileManager.copyItem(
            at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: vectorSource)
        let vectorEngine = try RustEngine()
        _ = try vectorEngine.openDocument(at: vectorSource)
        let strokePoint = CGPoint(x: 450, y: 842 - 420)
        let before = try await vectorEngine.renderPage(0, scale: scale)
        let beforePixel = pixel(before, atPagePoint: strokePoint)
        require(beforePixel.blue > 150 && beforePixel.red < 110,
                "the fixture's vector stroke is visible before the redaction (\(beforePixel))")

        let vectorMark = CGRect(x: 200, y: 842 - 370, width: 20, height: 20)
        let vectorCopy = scratch.appendingPathComponent("vector-redacted.pdf")
        let vectorReport = try await vectorEngine.redactToCopy(
            to: vectorCopy, areas: [RedactionArea(page: 0, rect: vectorMark)])
        require(vectorReport.pages.first?.removedGraphics ?? 0 >= 1,
                "the intersecting vector path is reported as removed")
        let vectorReader = try RustEngine()
        _ = try vectorReader.openDocument(at: vectorCopy)
        let after = try await vectorReader.renderPage(0, scale: scale)
        let afterPixel = pixel(after, atPagePoint: strokePoint)
        require(afterPixel.red > 220 && afterPixel.green > 220 && afterPixel.blue > 220,
                "the vector stroke outside the mark is gone, not painted over (\(afterPixel))")

        // ── Replace: backup first, then the file loses the text ─────────────────────────
        let replaceSource = scratch.appendingPathComponent("replace.pdf")
        try fileManager.copyItem(
            at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: replaceSource)
        let replaceOriginal = try Data(contentsOf: replaceSource)
        let replaceEngine = try RustEngine()
        _ = try replaceEngine.openDocument(at: replaceSource)
        let replacePage = try await replaceEngine.textPage(0)
        var quickRect = CGRect.zero
        let quickRange = rangeWhile(in: replacePage, needle: "quick")
        for character in replacePage.chars[quickRange] {
            let box = CGRect(x: character.xPt, y: character.yPt,
                             width: character.widthPt, height: character.heightPt)
            quickRect = quickRect.isEmpty ? box : quickRect.union(box)
        }
        let replaceReport = try await replaceEngine.replaceWithRedactions(
            [RedactionArea(page: 0, rect: quickRect.insetBy(dx: -1, dy: -1))])
        require(!replaceReport.originalUnchanged, "the replace path reports the file changed")
        let backup = try requireUnwrap(replaceReport.backupPath, "the replace path writes a backup")
        let backupBytes = try Data(contentsOf: URL(fileURLWithPath: backup))
        require(backupBytes == replaceOriginal, "the backup is byte-identical to the original")
        let replacedBytes = try Data(contentsOf: replaceSource)
        require(replacedBytes != replaceOriginal,
                "the original file now carries the redacted content")
        _ = try replaceEngine.openDocument(at: replaceSource)
        let replacedText = try await replaceEngine.textPage(0)
        require(!replacedText.text.contains("quick"),
                "the replaced file no longer extracts the covered word")
        require(replacedText.text.contains("fox") && replacedText.text.contains("Line 6:"),
                "the rest of the replaced file still extracts")

        // ── The pending-mark model the canvas and the confirmation use ───────────────────
        let state = AppState(engine: try RustEngine())
        require(state.open(url: source), "the reader opens the fixture")
        require(!state.canApplyRedactions, "there is nothing to apply before a mark")
        state.addPendingRedaction(page: 0, rect: CGRect(x: 100, y: 100, width: 40, height: 20))
        require(state.pendingRedactions.count == 1, "the mark is pending")
        require(state.pendingRedactionPageCount == 1, "the pending page count is reported")
        require(state.pendingRedactionMarks.first?.page == 0,
                "the canvas receives the pending rectangle")
        require(state.pendingRedactionAreas.first?.rect == state.pendingRedactions[0].rect,
                "the engine request carries the same rectangle")
        require(state.canApplyRedactions, "a pending mark can be applied")
        state.clearPendingRedactions()
        require(state.pendingRedactions.isEmpty, "clearing removes every pending mark")

        print("Redaction checks passed")
    }

    /// The pixel at a page-local point in a rendered page, as sRGB bytes.
    @MainActor static func pixel(
        _ image: PageImage,
        atPagePoint point: CGPoint
    ) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let scale = CGFloat(image.pixelWidth) / max(image.pointSize.width, 1)
        let x = min(max(Int(point.x * scale), 0), image.pixelWidth - 1)
        let y = min(max(Int(point.y * scale), 0), image.pixelHeight - 1)
        let offset = (y * image.pixelWidth + x) * 4
        let pixels = [UInt8](image.bgra)
        return (pixels[offset + 2], pixels[offset + 1], pixels[offset])
    }

    @MainActor static func rangeWhile(
        in page: TextPage,
        needle: String
    ) -> ClosedRange<Int> {
        let pattern = Array(needle.unicodeScalars.map(\.value))
        outer: for start in 0...(page.chars.count - pattern.count) {
            for offset in 0..<pattern.count
            where page.chars[start + offset].unicode != pattern[offset] {
                continue outer
            }
            return start...(start + pattern.count - 1)
        }
        fatalError("text does not contain \(needle)")
    }

    @MainActor static func requireUnwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { fatalError("FAIL: \(message)") }
        return value
    }
}
