import AppKit
import Foundation
@testable import LyraReaderKit

extension ReaderChecks {
    /// The destination guard shared by every immediate-to-a-new-file command.
    ///
    /// `saveAnnotatedCopy` used to look only at the destination's document cache, while the
    /// other copy commands already looked at the cache **and** a legacy companion beside the
    /// destination. Saving over a stale companion was therefore allowed, and opening the saved
    /// file later imported that companion next to the annotations the PDF already carried:
    /// every annotation appeared twice. These checks pin the shared predicate, the two distinct
    /// refusals, the clean-save path and the explicitly confirmed replacement.
    @MainActor static func annotatedCopyGuardChecks(root: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-annotated-copy-guard-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        let oldRoot = DocumentEditCache.rootOverride
        DocumentEditCache.rootOverride = scratch.appendingPathComponent("cache")
        defer {
            DocumentEditCache.rootOverride = oldRoot
            try? fileManager.removeItem(at: scratch)
        }

        func fixture(_ name: String) throws -> URL {
            let url = scratch.appendingPathComponent(name)
            try fileManager.copyItem(
                at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: url)
            return url
        }

        // ── Two real text annotations so the saved identities can be compared exactly ─────
        let probe = try RustEngine()
        _ = try probe.openDocument(at: root.appendingPathComponent("tests/fixtures/text-page.pdf"))
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
        let firstID = UUID()
        let secondID = UUID()
        let first = AppState.Annotation(
            id: firstID,
            kind: .highlight,
            page: 0,
            start: firstStart,
            end: firstStart + 5,
            color: AppState.highlightPalette[0].color,
            note: "guard highlight",
            createdAt: Date()
        )
        let second = AppState.Annotation(
            id: secondID,
            kind: .underline,
            page: 0,
            start: secondStart,
            end: secondStart + 5,
            color: AppState.highlightPalette[2].color,
            note: "guard underline",
            createdAt: Date()
        )
        let bookmark = Bookmark(page: 0, title: "guard bookmark", yPt: 12)
        let staleID = UUID()
        let stale = AppState.Annotation(
            id: staleID,
            kind: .highlight,
            page: 0,
            start: firstStart,
            end: firstStart + 5,
            color: AppState.highlightPalette[1].color,
            note: "stale destination mark",
            createdAt: Date()
        )
        func records(_ annotations: [AppState.Annotation], bookmarks: [Bookmark] = []) throws -> Data {
            try AnnotationRecords.encode(
                annotations: annotations,
                bookmarks: bookmarks,
                slots: annotations.map { .annotation($0.id) } + bookmarks.map { .bookmark($0.id) })
        }

        let source = try fixture("guard-source.pdf")
        try records([first, second], bookmarks: [bookmark])
            .write(to: DocumentEditCache.annotationsURL(for: source))
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        require(state.open(url: source), "annotated-copy guard source opens")
        require(state.annotations.count == 2 && state.bookmarks.count == 1,
                "the annotated-copy guard source carries its seeded marks")

        // ── 1. A destination with only a document cache is refused, and says so ──────────
        let cachedDestination = try fixture("cached-destination.pdf")
        let cachedDestinationBytes = try Data(contentsOf: cachedDestination)
        let cachedRecords = DocumentEditCache.annotationsURL(for: cachedDestination)
        let staleBytes = try records([stale])
        try staleBytes.write(to: cachedRecords)
        let cachedSaved = await state.saveAnnotatedCopy(to: cachedDestination)
        require(!cachedSaved, "a destination with a document cache is refused")
        let cachedMessage = state.lastError ?? ""
        require(cachedMessage.contains("document cache"),
                "the cache refusal names the document cache: \(cachedMessage)")
        require(cachedMessage.contains("already has annotations"),
                "the cache refusal says the destination already has annotations: \(cachedMessage)")
        require(cachedMessage.contains("Choose another destination"),
                "the cache refusal offers another destination: \(cachedMessage)")
        require(cachedMessage.contains("replace"),
                "the cache refusal offers the confirmed replacement: \(cachedMessage)")
        require((try? Data(contentsOf: cachedDestination)) == cachedDestinationBytes,
                "a refused cache destination is not overwritten")
        require((try? Data(contentsOf: cachedRecords)) == staleBytes,
                "a refused cache destination keeps its records byte-identical")

        // ── 2. A destination with only a legacy companion is refused the same way ────────
        let legacyDestination = try fixture("legacy-destination.pdf")
        let legacyDestinationBytes = try Data(contentsOf: legacyDestination)
        let legacyURL = DocumentEditCache.legacyURLs(for: legacyDestination)[0]
        let legacyBytes = try records([stale])
        try legacyBytes.write(to: legacyURL)
        let legacySaved = await state.saveAnnotatedCopy(to: legacyDestination)
        require(!legacySaved, "a destination with only a legacy companion is refused")
        let legacyMessage = state.lastError ?? ""
        require(legacyMessage.contains("legacy annotation companion"),
                "the legacy refusal names the legacy companion: \(legacyMessage)")
        require(legacyMessage.contains("older copy"),
                "the legacy refusal says the annotations belong to an older copy: \(legacyMessage)")
        require(!legacyMessage.contains("document cache"),
                "the legacy refusal does not misreport a destination cache: \(legacyMessage)")
        require(!legacyMessage.contains("already has annotations"),
                "the legacy refusal uses the companion remedy, not the cache one: \(legacyMessage)")
        require(legacyMessage.contains("Choose another destination"),
                "the legacy refusal offers another destination: \(legacyMessage)")
        require(legacyMessage.contains("replace"),
                "the legacy refusal offers the confirmed replacement: \(legacyMessage)")
        require((try? Data(contentsOf: legacyDestination)) == legacyDestinationBytes,
                "a refused legacy destination is not overwritten")
        require((try? Data(contentsOf: legacyURL)) == legacyBytes,
                "a refused legacy companion keeps its bytes")

        // The sibling commands share the same predicate: merge and split must still refuse the
        // same companion-only destination.
        let other = try fixture("append-me.pdf")
        let cleanMerge = scratch.appendingPathComponent("merge-clean.pdf")
        let cleanMergeSaved = await state.mergeDocuments([other], to: cleanMerge)
        require(cleanMergeSaved, "merge still writes a clean destination")
        let mergedOntoLegacy = scratch.appendingPathComponent("merged-onto-legacy.pdf")
        try records([stale]).write(to: DocumentEditCache.legacyURLs(for: mergedOntoLegacy)[0])
        let mergeRefused = await state.mergeDocuments([other], to: mergedOntoLegacy)
        require(!mergeRefused, "merge still refuses a legacy companion destination")
        require(state.lastError?.contains("annotation records") == true,
                "merge reports the destination's annotation records")
        let splitOntoLegacy = scratch.appendingPathComponent("split-onto-legacy.pdf")
        try records([stale]).write(to: DocumentEditCache.legacyURLs(for: splitOntoLegacy)[0])
        let splitRefused = await state.splitPages([[0]], to: [splitOntoLegacy])
        require(!splitRefused, "split still refuses a legacy companion destination")

        // ── 3. A clean destination saves, and reopening it shows each annotation once ─────
        let cleanDestination = scratch.appendingPathComponent("clean-copy.pdf")
        let cleanSaved = await state.saveAnnotatedCopy(to: cleanDestination)
        require(cleanSaved, "a clean destination still saves: \(state.lastError ?? "")")
        require(!fileManager.fileExists(atPath: DocumentEditCache.annotationsURL(for: cleanDestination).path),
                "a saved copy carries no destination cache")
        require(DocumentEditCache.legacyURLs(for: cleanDestination)
                    .allSatisfy { !fileManager.fileExists(atPath: $0.path) },
                "a saved copy recreates no legacy companion")

        let cleanReopen = AppState(engine: try RustEngine())
        cleanReopen.setViewportSize(CGSize(width: 700, height: 500))
        cleanReopen.newTab(url: cleanDestination)
        require(cleanReopen.annotations.isEmpty, "reopening the saved copy imports no cache")
        try await eventually("the saved copy exposes exactly the two saved annotations", {
            cleanReopen.documentAnnotations.count == 2
        })
        let expectedIDs = Set(["nm:\(firstID.uuidString)", "nm:\(secondID.uuidString)"])
        let reopenedIDs = Set(cleanReopen.documentAnnotations.map(\.id))
        require(reopenedIDs == expectedIDs,
                "the saved copy carries exactly the saved identities: \(reopenedIDs.sorted())")
        require(cleanReopen.documentAnnotations.count == 2,
                "the saved copy shows each annotation once, not twice")
        try await eventually("the saved copy adopts its bookmark once", {
            cleanReopen.bookmarks.map(\.id) == [bookmark.id]
        })

        // ── 4. The confirmed replacement retires each kind of stale record, then saves ────
        let replacedLegacy = await state.saveAnnotatedCopy(
            to: legacyDestination, replaceExistingRecords: true)
        require(replacedLegacy,
                "a confirmed replacement can save over a legacy companion: \(state.lastError ?? "")")
        require(!fileManager.fileExists(atPath: legacyURL.path),
                "the confirmed replacement moves the legacy companion out of the way")
        let legacyReopen = AppState(engine: try RustEngine())
        legacyReopen.setViewportSize(CGSize(width: 700, height: 500))
        legacyReopen.newTab(url: legacyDestination)
        try await eventually("the replaced legacy destination exposes only the saved annotations", {
            legacyReopen.documentAnnotations.count == 2
        })
        require(Set(legacyReopen.documentAnnotations.map(\.id)) == expectedIDs,
                "the replaced legacy destination has no duplicate identities")

        let replacedCache = await state.saveAnnotatedCopy(
            to: cachedDestination, replaceExistingRecords: true)
        require(replacedCache,
                "a confirmed replacement can save over a document cache: \(state.lastError ?? "")")
        require(!fileManager.fileExists(atPath: cachedRecords.path),
                "the confirmed replacement moves the destination cache out of the way")
        let cacheReopen = AppState(engine: try RustEngine())
        cacheReopen.setViewportSize(CGSize(width: 700, height: 500))
        cacheReopen.newTab(url: cachedDestination)
        try await eventually("the replaced cache destination exposes only the saved annotations", {
            cacheReopen.documentAnnotations.count == 2
        })
        require(Set(cacheReopen.documentAnnotations.map(\.id)) == expectedIDs,
                "the replaced cache destination has no duplicate identities")

        print("Annotated-copy guard checks passed")
    }
}
