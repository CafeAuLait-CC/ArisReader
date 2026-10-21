import AppKit
import Foundation
@testable import LyraReaderKit

extension ReaderChecks {
    /// The destination guard for `extractPages`, the page command that used to skip it.
    ///
    /// Extracting into a destination that already held annotation records wrote the file and
    /// left the stale records in place; opening the output later imported them next to the
    /// annotations the extracted pages carried, so every mark appeared twice. These checks pin
    /// the shared predicate's two distinct refusals, the clean-destination path, the explicit
    /// replacement that retires the records to a backup first, and the no-duplicate reopen.
    @MainActor static func extractDestinationGuardChecks(root: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-extract-guard-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        let oldRoot = DocumentEditCache.rootOverride
        DocumentEditCache.rootOverride = scratch.appendingPathComponent("cache")
        defer {
            DocumentEditCache.rootOverride = oldRoot
            try? fileManager.removeItem(at: scratch)
        }

        func fixture(_ name: String, as fileName: String) throws -> URL {
            let url = scratch.appendingPathComponent(fileName)
            try fileManager.copyItem(
                at: root.appendingPathComponent("tests/fixtures/\(name)"), to: url)
            return url
        }

        func staleRecords(_ note: String) throws -> Data {
            let stale = AppState.Annotation(
                id: UUID(),
                kind: .highlight,
                page: 0,
                start: 0,
                end: 5,
                color: AppState.highlightPalette[1].color,
                note: note,
                createdAt: Date()
            )
            return try AnnotationRecords.encode(
                annotations: [stale],
                bookmarks: [],
                slots: [.annotation(stale.id)])
        }

        let source = try fixture("annotated.pdf", as: "extract-source.pdf")
        let sourceBytes = try Data(contentsOf: source)
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        require(state.open(url: source), "the extract guard source opens")
        try await eventually("the extract guard source loads its embedded annotations", {
            state.documentAnnotations.count == 7
        })
        let pageZeroAnnotations = state.documentAnnotations.filter { $0.page == 0 }
        require(!pageZeroAnnotations.isEmpty,
                "the source's first page carries embedded annotations to extract")

        // ── 1. The same-file guard still wins over the records guard ─────────────────────
        let sameFileOK = await state.extractPages([0], to: source)
        require(!sameFileOK, "extracting over the source is still refused")
        require(state.lastError?.contains("cannot overwrite the document they came from") == true,
                "the same-file refusal keeps its message: \(state.lastError ?? "")")
        require((try? Data(contentsOf: source)) == sourceBytes,
                "the refused same-file extraction leaves the source byte-identical")

        // ── 2. A destination with only a document cache is refused, and says so ──────────
        let cachedDestination = try fixture("text-page.pdf", as: "cached-destination.pdf")
        let cachedDestinationBytes = try Data(contentsOf: cachedDestination)
        let cachedRecords = DocumentEditCache.annotationsURL(for: cachedDestination)
        let cachedStaleBytes = try staleRecords("stale cache mark")
        try cachedStaleBytes.write(to: cachedRecords)
        let cachedExtractOK = await state.extractPages([0], to: cachedDestination)
        require(!cachedExtractOK, "extracting onto a destination with a document cache is refused")
        let cacheMessage = state.lastError ?? ""
        require(cacheMessage.contains("document cache"),
                "the cache refusal names the document cache: \(cacheMessage)")
        require(cacheMessage.contains("already has annotations"),
                "the cache refusal says the destination already has annotations: \(cacheMessage)")
        require(!cacheMessage.contains("legacy annotation companion"),
                "the cache refusal does not misreport a legacy companion: \(cacheMessage)")
        require(cacheMessage.contains("Choose another destination"),
                "the cache refusal offers another destination: \(cacheMessage)")
        require(cacheMessage.contains("replace"),
                "the cache refusal offers the confirmed replacement: \(cacheMessage)")
        require((try? Data(contentsOf: cachedDestination)) == cachedDestinationBytes,
                "a refused cache destination is not overwritten")
        require((try? Data(contentsOf: cachedRecords)) == cachedStaleBytes,
                "a refused cache destination keeps its records byte-identical")

        // ── 3. A confirmed replacement retires the cache and the output has no duplicates ──
        let cachedReplaceOK = await state.extractPages(
            [0], to: cachedDestination, replaceExistingRecords: true)
        require(cachedReplaceOK,
                "a confirmed replacement extracts over a document cache: \(state.lastError ?? "")")
        require(!fileManager.fileExists(atPath: cachedRecords.path),
                "the confirmed replacement moves the destination cache out of the way")
        let cacheRoot = scratch.appendingPathComponent("cache")
        let cacheBackups = (try? fileManager.contentsOfDirectory(
            at: cacheRoot, includingPropertiesForKeys: nil)) ?? []
        require(cacheBackups.contains {
                    $0.lastPathComponent.hasPrefix("replaced-")
                        && (try? Data(contentsOf: $0.appendingPathComponent("annotations.json")))
                            == cachedStaleBytes
                },
                "the retired destination cache is kept as a byte-identical backup")

        let cachedReopen = AppState(engine: try RustEngine())
        cachedReopen.setViewportSize(CGSize(width: 700, height: 500))
        cachedReopen.newTab(url: cachedDestination)
        require(cachedReopen.annotations.isEmpty,
                "the replaced cache destination imports no stale reader records")
        try await eventually("the replaced cache destination loads the extracted page's marks", {
            cachedReopen.documentAnnotations.count == pageZeroAnnotations.count
        })
        require(Set(cachedReopen.documentAnnotations.map(\.id))
                    == Set(pageZeroAnnotations.map(\.id)),
                "the replaced cache destination carries exactly the source page's identities")
        require(cachedReopen.documentAnnotations.allSatisfy { $0.page == 0 },
                "the extracted file's annotations all belong to its only page")
        require((try? Data(contentsOf: source)) == sourceBytes,
                "the confirmed replacement leaves the source byte-identical")

        // ── 4. A destination with only a legacy companion is refused, and says so ─────────
        let legacyDestination = try fixture("text-page.pdf", as: "legacy-destination.pdf")
        let legacyDestinationBytes = try Data(contentsOf: legacyDestination)
        let legacyURL = DocumentEditCache.legacyURLs(for: legacyDestination)[0]
        let legacyStaleBytes = try staleRecords("stale legacy mark")
        try legacyStaleBytes.write(to: legacyURL)
        let legacyExtractOK = await state.extractPages([0], to: legacyDestination)
        require(!legacyExtractOK, "extracting onto a destination with only a legacy companion is refused")
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
        require((try? Data(contentsOf: legacyURL)) == legacyStaleBytes,
                "a refused legacy companion keeps its bytes")

        // ── 5. The confirmed replacement retires the legacy companion too ────────────────
        let legacyReplaceOK = await state.extractPages(
            [0], to: legacyDestination, replaceExistingRecords: true)
        require(legacyReplaceOK,
                "a confirmed replacement extracts over a legacy companion: \(state.lastError ?? "")")
        require(!fileManager.fileExists(atPath: legacyURL.path),
                "the confirmed replacement moves the legacy companion out of the way")
        let retiredFiles = fileManager.enumerator(
            at: cacheRoot, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        require(retiredFiles.contains {
                    $0.lastPathComponent.hasPrefix("replaced-")
                        && (try? Data(contentsOf: $0)) == legacyStaleBytes
                },
                "the retired legacy companion is kept as a byte-identical backup")

        let legacyReopen = AppState(engine: try RustEngine())
        legacyReopen.setViewportSize(CGSize(width: 700, height: 500))
        legacyReopen.newTab(url: legacyDestination)
        require(legacyReopen.annotations.isEmpty,
                "the replaced legacy destination imports no stale reader records")
        try await eventually("the replaced legacy destination loads the extracted page's marks", {
            legacyReopen.documentAnnotations.count == pageZeroAnnotations.count
        })
        require(Set(legacyReopen.documentAnnotations.map(\.id))
                    == Set(pageZeroAnnotations.map(\.id)),
                "the replaced legacy destination carries exactly the source page's identities")

        // ── 6. A clean destination still extracts, with the same marks and no records ─────
        let cleanDestination = scratch.appendingPathComponent("clean-extract.pdf")
        let cleanExtractOK = await state.extractPages([0], to: cleanDestination)
        require(cleanExtractOK, "a clean destination still extracts: \(state.lastError ?? "")")
        require(fileManager.fileExists(atPath: cleanDestination.path),
                "the clean extraction wrote its file")
        require(!fileManager.fileExists(
                    atPath: DocumentEditCache.annotationsURL(for: cleanDestination).path),
                "a clean extraction creates no destination cache")
        require(DocumentEditCache.legacyURLs(for: cleanDestination)
                    .allSatisfy { !fileManager.fileExists(atPath: $0.path) },
                "a clean extraction creates no legacy companion")
        let cleanProbe = try RustEngine()
        let cleanDocument = try cleanProbe.openDocument(at: cleanDestination)
        require(cleanDocument.pageCount == 1,
                "the clean extraction writes exactly the selected page")

        let cleanReopen = AppState(engine: try RustEngine())
        cleanReopen.setViewportSize(CGSize(width: 700, height: 500))
        cleanReopen.newTab(url: cleanDestination)
        require(cleanReopen.annotations.isEmpty,
                "the clean extracted file needs no reader records")
        try await eventually("the clean extracted file loads the source page's marks", {
            cleanReopen.documentAnnotations.count == pageZeroAnnotations.count
        })
        require(Set(cleanReopen.documentAnnotations.map(\.id))
                    == Set(pageZeroAnnotations.map(\.id)),
                "the clean extracted file carries exactly the source page's identities")
        require((try? Data(contentsOf: source)) == sourceBytes,
                "extracting to a clean destination leaves the source byte-identical")

        print("Extract destination guard checks passed")
    }
}
