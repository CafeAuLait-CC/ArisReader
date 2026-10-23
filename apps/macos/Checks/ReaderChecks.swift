import AppKit
import LyraReaderKit
import Foundation

// Executable regressions run with Command Line Tools; no XCTest/Xcode dependency.
//
// Usage: LyraReaderChecks <repository-root> [--shard i/n]
//
// `--shard i/n` runs one deterministic slice of the registered suites (`index % n == i - 1`),
// prints the suites that slice owns, and exits non-zero if the slice is empty. CI uses it to run
// the suite on several runners in parallel. It partitions whole suites, never the assertions
// inside one, so a shard's log still names every check it was responsible for. Without
// `--shard`, every suite runs in the historical order.
@main
struct ReaderChecks {
    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
        print("PASS: \(message)")
    }

    @MainActor static func eventually(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { print("PASS: \(message)"); return }
            try await Task.sleep(for: .milliseconds(25))
        }
        fatalError("TIMEOUT: \(message)")
    }

    /// Like `eventually`, but a timeout carries the state that explains it. A bare
    /// "TIMEOUT: …" cannot say which window was occluded, whether its GPU surface was ever
    /// attached, or whether frames were submitted but not presented.
    @MainActor static func eventuallyExplaining(
        _ message: String,
        _ explanation: () -> String,
        _ condition: () -> Bool
    ) async throws {
        for _ in 0..<400 {
            if condition() { print("PASS: \(message)"); return }
            try await Task.sleep(for: .milliseconds(25))
        }
        fatalError("TIMEOUT: \(message)\n\(explanation())")
    }

    /// One registered native suite: a name for the shard log and the body that runs it.
    ///
    /// `--shard i/n` partitions the array of these, never the assertions inside one, so a
    /// shard's membership is a fact about the registry rather than a property of how far the
    /// run happened to get.
    typealias CheckSuite = (name: String, run: @MainActor () async throws -> Void)

    /// The repository root every check resolves its fixtures against.
    ///
    /// `URL(fileURLWithPath: ".")` keeps the `.` component, so a fixture opened from a relative
    /// root would compare unequal to the same file after `DocumentOpenCoordinator` standardizes
    /// it (new-window delivery does exactly that). The checks therefore normalize the root once,
    /// whether the test runner passes an absolute `$ROOT`, a relative `.`, or nothing.
    @MainActor static func checkRoot(_ argument: String?) -> URL {
        URL(fileURLWithPath: argument ?? FileManager.default.currentDirectoryPath)
            .standardizedFileURL
    }

    @MainActor static func main() async throws {
        // `--shard i/n` partitions the registered suites across n processes. Parse and validate
        // it before anything else so a typo fails loudly instead of silently running the whole
        // suite in every shard (which would be slow and would make the shard jobs meaningless).
        // Invocation: LyraReaderChecks <repository-root> --shard i/n
        var shardIndex = 0
        var shardCount = 0
        if let flag = CommandLine.arguments.firstIndex(of: "--shard") {
            let raw = flag + 1 < CommandLine.arguments.count ? CommandLine.arguments[flag + 1] : ""
            let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count == 2,
               let index = Int(parts[0]), let count = Int(parts[1]),
               count >= 1, index >= 1, index <= count {
                shardIndex = index
                shardCount = count
            } else {
                FileHandle.standardError.write(
                    Data("--shard expects i/n with 1 <= i <= n; got \"\(raw)\"\n".utf8))
                exit(2)
            }
        }
        let checkCache = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-native-cache-\(UUID())")
        DocumentEditCache.rootOverride = checkCache.appendingPathComponent("Documents")
        setenv("LYRA_READER_DOCUMENT_CACHE_DIR", DocumentEditCache.rootOverride!.path, 1)
        setenv("LYRA_READER_INDEX_CACHE_DIR", checkCache.appendingPathComponent("Indexes").path, 1)
        // Keep the local AI audit trail out of the person's cache during a check run, including
        // models that use the shared trail. Audit checks pass their own directories.
        setenv("LYRA_READER_AI_AUDIT_DIR", checkCache.appendingPathComponent("Audit").path, 1)
        defer { try? FileManager.default.removeItem(at: checkCache) }
        // The reader's layout preferences live in UserDefaults (so the app remembers facing
        // pages and the page gap). Checks must not inherit them from whatever the person
        // running the suite chose in the app: pin continuous/12 for this process. Setters still
        // exercise the real layout path, they just do not write the preference.
        AppState.usesDocumentKnowledge = false
        AppState.usesStoredReadingLayoutPreferences = false
        // Same rule for the sidebar's remembered tab and the right panel's width/visibility: a
        // check run must not move the person's app into the state the check exercises.
        AppState.usesStoredSidebarTab = false
        AppState.usesStoredSidePanelPreferences = false

        let fastRoot = checkRoot(CommandLine.arguments.dropFirst(2).first)
        if CommandLine.arguments.contains("--check-drawer-tiles") {
            try await drawerTileRetentionChecks(url: fastRoot.appendingPathComponent("tests/fixtures/multipage.pdf"))
            return
        }
        if CommandLine.arguments.contains("--check-feedback-editing") {
            try await feedbackEditingChecks(root: fastRoot)
            return
        }
        if CommandLine.arguments.contains("--check-document-cache") {
            try await documentCacheChecks(root: fastRoot)
            return
        }
        if CommandLine.arguments.contains("--check-annotated-copy-guard") {
            try await annotatedCopyGuardChecks(root: fastRoot)
            return
        }
        if CommandLine.arguments.contains("--check-extract-destination-guard") {
            try await extractDestinationGuardChecks(root: fastRoot)
            return
        }
        if CommandLine.arguments.contains("--check-xfa") {
            try await xfaChecks(root: fastRoot)
            return
        }
        if CommandLine.arguments.contains("--check-content-editing") {
            try await contentEditingChecks(root:fastRoot)
            return
        }
        if CommandLine.arguments.contains("--check-content-identity") {
            try await contentEditIdentityChecks(root: fastRoot)
            return
        }
        if CommandLine.arguments.contains("--check-rename") {
            try renameCompatibilityChecks(root: fastRoot)
            return
        }
        if CommandLine.arguments.contains("--check-sidebar-polish") {
            try await sidebarPolishChecks(root: fastRoot)
            return
        }
        if CommandLine.arguments.contains("--check-reading-polish") {
            try await readingPolishChecks(root: fastRoot)
            return
        }
        if CommandLine.arguments.contains("--check-bookmarks") {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("lyra-reader-bookmarks-\(UUID())")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let fixture = scratch.appendingPathComponent("a.pdf")
            try FileManager.default.copyItem(
                at: fastRoot.appendingPathComponent("tests/fixtures/text-page.pdf"), to: fixture)
            try await bookmarkChecks(url: fixture)
            print("Bookmark checks passed")
            return
        }
        if CommandLine.arguments.contains("--check-metadata") {
            try await metadataChecks(root: fastRoot)
            return
        }
        if CommandLine.arguments.contains("--check-annotation-editing") {
            try await annotationEditingChecks(root: fastRoot)
            return
        }
        if CommandLine.arguments.contains("--check-placed-text") {
            try await placedTextChecks(
                drawing: fastRoot.appendingPathComponent("tests/fixtures/text-page.pdf"),
                annotated: fastRoot.appendingPathComponent("tests/fixtures/annotated.pdf"),
                external: fastRoot.appendingPathComponent("tests/fixtures/annotated-notes.pdf"))
            return
        }
        if CommandLine.arguments.contains("--check-cross-reader") {
            try await crossReaderAnnotationChecks(
                replies: fastRoot.appendingPathComponent("tests/fixtures/annotated-replies.pdf"),
                notes: fastRoot.appendingPathComponent("tests/fixtures/annotated-notes.pdf"))
            return
        }
        if CommandLine.arguments.contains("--check-signatures") {
            try await signatureWriteChecks(root: fastRoot)
            return
        }
        if CommandLine.arguments.contains("--check-forms") {
            try await formChecks(root: fastRoot)
            return
        }
        if CommandLine.arguments.contains("--check-appearance") {
            await appearanceChecks()
            return
        }
        if CommandLine.arguments.contains("--check-chatgpt") {
            try await chatGPTChecks(root: fastRoot)
            return
        }
        if CommandLine.arguments.contains("--check-ai-assistant") {
            try await aiAssistantChecks(root: fastRoot)
            print("AI assistant checks passed")
            return
        }
        if CommandLine.arguments.contains("--check-inplace-translation") {
            try await inPlaceTranslationChecks(root: fastRoot)
            print("In-place translation checks passed")
            return
        }
        if CommandLine.arguments.contains("--preview-region-review") {
            try await regionReviewPreview(root: fastRoot)
            return
        }
        if CommandLine.arguments.contains("--check-reading-notes") {
            try await regionReadingNotesChecks(root: fastRoot)
            return
        }
        if CommandLine.arguments.contains("--check-region-questions") {
            try await regionQuestionChecks(root: fastRoot)
            print("Region question checks passed")
            return
        }
        if CommandLine.arguments.contains("--check-inside-page-tear") {
            try await insidePageTearChecks(root: fastRoot)
            print("Inside-page tear checks passed")
            return
        }
        if CommandLine.arguments.contains("--check-ai-audit") {
            try await aiAuditChecks(root: fastRoot)
            print("AI audit trail checks passed")
            return
        }
        if CommandLine.arguments.contains("--check-offline-hint") {
            try await offlineHintChecks(root: fastRoot)
            print("Offline hint checks passed")
            return
        }
        if CommandLine.arguments.contains("--check-facing-layout") {
            try await facingLayoutChecks(
                url: fastRoot.appendingPathComponent("tests/fixtures/multipage.pdf"))
            print("Facing-layout checks passed")
            return
        }
        if CommandLine.arguments.contains("--check-link-borders") {
            try await linkBorderCanvasChecks(url: fastRoot.appendingPathComponent("tests/fixtures/link-borders.pdf"))
            return
        }
        if CommandLine.arguments.contains("--check-hosted-preview") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await hostedPreviewChecks(root: root)
            return
        }
        if CommandLine.arguments.contains("--check-preview-history") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await previewHistoryChecks(
                url: root.appendingPathComponent("tests/fixtures/multipage.pdf"))
            print("Preview history checks passed")
            return
        }
        if CommandLine.arguments.contains("--check-preview-transparency") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await previewTransparencyChecks(root: root)
            print("Preview transparency checks passed")
            return
        }
        if CommandLine.arguments.contains("--check-section-preview") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await previewSectionChecks(root: root)
            print("Section preview checks passed")
            return
        }
        if CommandLine.arguments.contains("--check-linked-preview") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await linkedPreviewChecks(root: root)
            return
        }
        if CommandLine.arguments.contains("--check-preview-actions") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await previewActionChecks(root: root)
            return
        }
        // The right-hand AI panel on its own while it is being worked on
        // (`LyraReaderChecks --check-right-panel .`).
        if CommandLine.arguments.contains("--check-right-panel") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await rightPanelChecks(root: root)
            return
        }
        // The developer performance panel on its own
        // (`LyraReaderChecks --check-performance-panel .`).
        if CommandLine.arguments.contains("--check-performance-panel") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await performancePanelChecks(root: root)
            return
        }
        // The sidebar and secondary-row transitions on their own, while they are being worked on
        // (`LyraReaderChecks --check-transitions .`).
        if CommandLine.arguments.contains("--check-transitions") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await transitionChecks(root: root)
            return
        }
        // The calibrated zoom and its presets on their own
        // (`LyraReaderChecks --check-zoom .`).
        if CommandLine.arguments.contains("--check-zoom") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await zoomChecks(root: root)
            return
        }
        if CommandLine.arguments.contains("--measure-page-navigation") {
            try await measurePageNavigation()
            return
        }
        if CommandLine.arguments.contains("--check-selection-path") {
            try await checkSelectionPath()
            return
        }
        // The live text-markup preview on its own
        // (`LyraReaderChecks --check-live-markup .`).
        if CommandLine.arguments.contains("--check-live-markup") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await liveMarkupChecks(
                textPage: root.appendingPathComponent("tests/fixtures/text-page.pdf"),
                twoColumn: root.appendingPathComponent("tests/fixtures/two-column-references.pdf"))
            print("Live markup checks passed")
            return
        }
        if CommandLine.arguments.contains("--measure-page-rasters") {
            try await measurePageRasters()
            return
        }
        if CommandLine.arguments.contains("--measure-page-fallback") {
            try await measurePageFallback()
            return
        }
        if CommandLine.arguments.contains("--measure-scroll-trace") {
            try await measureScrollTrace()
            return
        }
        if CommandLine.arguments.contains("--check-inline-notes") {
            try await inlineNoteChecks(root: fastRoot)
            return
        }
        if CommandLine.arguments.contains("--check-note-overlay") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await noteOverlayChecks(url: root.appendingPathComponent("tests/fixtures/annotated-notes.pdf"))
            return
        }
        // The sticky markup tools and /StrikeOut write-back on their own.
        if CommandLine.arguments.contains("--check-sticky-markup") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await stickyMarkupChecks(
                fixture: root.appendingPathComponent("tests/fixtures/text-page.pdf"))
            try await strikeoutChecks(
                textPage: root.appendingPathComponent("tests/fixtures/text-page.pdf"),
                annotated: root.appendingPathComponent("tests/fixtures/annotated.pdf"))
            print("Sticky markup and strikeout checks passed")
            return
        }
        // The write-back suite on its own (`LyraReaderChecks --check-annotation-writeback .`).
        if CommandLine.arguments.contains("--check-annotation-writeback") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await annotationWritebackChecks(
                fixture: root.appendingPathComponent("tests/fixtures/text-page.pdf"))
            print("Annotation write-back checks passed")
            return
        }
        // Stamps and image signatures on their own (`LyraReaderChecks --check-stamps .`).
        if CommandLine.arguments.contains("--check-stamps") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await stampSignatureChecks(root: root)
            return
        }
        // Bookmark outline write-back on its own (`LyraReaderChecks --check-bookmark-writeback .`).
        if CommandLine.arguments.contains("--check-bookmark-writeback") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await bookmarkWritebackChecks(root: root)
            print("Bookmark write-back checks passed")
            return
        }
        // The eraser on its own (`LyraReaderChecks --check-eraser .`).
        if CommandLine.arguments.contains("--check-eraser") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await eraserChecks(
                drawing: root.appendingPathComponent("tests/fixtures/text-page.pdf"),
                strokes: root.appendingPathComponent("tests/fixtures/annotated-strokes.pdf"))
            try await partialEraseChecks(
                drawing: root.appendingPathComponent("tests/fixtures/text-page.pdf"),
                signed: root.appendingPathComponent("tests/fixtures/signed-signature.pdf"),
                inkReview: root.appendingPathComponent(
                    "tests/fixtures/annotated-ink-review.pdf"))
            return
        }
        // Partial stroke erase on its own (`LyraReaderChecks --check-partial-erase .`).
        if CommandLine.arguments.contains("--check-partial-erase") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await partialEraseChecks(
                drawing: root.appendingPathComponent("tests/fixtures/text-page.pdf"),
                signed: root.appendingPathComponent("tests/fixtures/signed-signature.pdf"),
                inkReview: root.appendingPathComponent(
                    "tests/fixtures/annotated-ink-review.pdf"))
            print("Partial erase checks passed")
            return
        }
        // Ink and shapes on their own (`LyraReaderChecks --check-ink-annotations .`).
        if CommandLine.arguments.contains("--check-ink-annotations") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await inkAnnotationChecks(
                drawing: root.appendingPathComponent("tests/fixtures/text-page.pdf"),
                annotated: root.appendingPathComponent("tests/fixtures/annotated.pdf"),
                strokes: root.appendingPathComponent("tests/fixtures/annotated-strokes.pdf"))
            print("Ink and shape checks passed")
            return
        }
        // Placeable notes and text boxes on their own
        // (`LyraReaderChecks --check-placed-text .`).
        if CommandLine.arguments.contains("--check-placed-text") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await placedTextChecks(
                drawing: root.appendingPathComponent("tests/fixtures/text-page.pdf"),
                annotated: root.appendingPathComponent("tests/fixtures/annotated.pdf"),
                external: root.appendingPathComponent("tests/fixtures/annotated-notes.pdf"))
            print("Placed-text checks passed")
            return
        }
        // The text-box creation flow on its own
        // (`LyraReaderChecks --check-textbox-placement .`).
        if CommandLine.arguments.contains("--check-textbox-placement") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await textBoxPlacementChecks(
                drawing: root.appendingPathComponent("tests/fixtures/text-page.pdf"),
                annotated: root.appendingPathComponent("tests/fixtures/annotated.pdf"))
            return
        }
        // Click-to-select for text markup and text boxes on its own
        // (`LyraReaderChecks --check-mark-selection .`).
        if CommandLine.arguments.contains("--check-mark-selection") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await markSelectionChecks(
                fixtures: root.appendingPathComponent("tests/fixtures/text-page.pdf"),
                annotated: root.appendingPathComponent("tests/fixtures/annotated.pdf"),
                multipage: root.appendingPathComponent("tests/fixtures/multipage.pdf"))
            print("Mark-selection checks passed")
            return
        }
        // The annotation text export on its own (`LyraReaderChecks --check-annotation-export .`).
        if CommandLine.arguments.contains("--check-annotation-export") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await annotationExportChecks(root: root)
            print("Annotation export checks passed")
            return
        }
        // The cold-click regression on its own (`LyraReaderChecks --check-cold-click .`).
        if CommandLine.arguments.contains("--check-cold-click") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await coldClickChecks(
                citationsURL: root.appendingPathComponent("tests/fixtures/two-column-references.pdf"),
                mentionsURL: root.appendingPathComponent("tests/fixtures/cross-references.pdf"))
            print("Cold-click checks passed")
            return
        }
        // The two interaction fixes, on their own, while they are being worked on
        // (`LyraReaderChecks --check-click-intent .`).
        if CommandLine.arguments.contains("--check-click-intent")
            || CommandLine.arguments.contains("--check-scroll-tail") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            if CommandLine.arguments.contains("--check-click-intent") {
                try await clickIntentChecks(
                    url: root.appendingPathComponent("tests/fixtures/two-column-references.pdf"))
                try await coldClickChecks(
                    citationsURL: root.appendingPathComponent("tests/fixtures/two-column-references.pdf"),
                    mentionsURL: root.appendingPathComponent("tests/fixtures/cross-references.pdf"))
            } else {
                scrollGlideTailChecks()
                try await scrollTailDriverChecks(
                    url: fastRoot.appendingPathComponent("tests/fixtures/multipage.pdf"))
            }
            print("Interaction checks passed")
            return
        }
        if CommandLine.arguments.contains("--check-redaction") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await redactionChecks(root: root)
            return
        }
        if CommandLine.arguments.contains("--check-printing") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await printingChecks(root: root)
            return
        }
        if CommandLine.arguments.contains("--check-page-operations") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await pageOperationChecks(root: root)
            print("Page-operation checks passed")
            return
        }
        // Lets the thumbnail drag/reorder checks run on their own
        // (`LyraReaderChecks --check-thumbnail-drag .`).
        if CommandLine.arguments.contains("--check-thumbnail-drag") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await thumbnailDragChecks(root: root)
            print("Thumbnail-drag checks passed")
            return
        }
        if CommandLine.arguments.contains("--measure-window-engine-cost") {
            try await measureWindowEngineCost()
            return
        }
        // Lets the titlebar's appearance/theme checks run on their own while they are being
        // worked on (`LyraReaderChecks --check-titlebar-theme .`).
        if CommandLine.arguments.contains("--check-titlebar-theme") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            try await titlebarThemeChecks(root: root)
            print("Titlebar theme checks passed")
            return
        }
        // Lets the tab-row and tab-switching checks be run on their own while they are being
        // worked on (`LyraReaderChecks --check-tab-row .`).
        if CommandLine.arguments.contains("--check-tab-row") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            tabRowLayoutChecks()
            titlebarResizeChecks()
            try await titlebarThemeChecks(root: root)
            try await tabRetentionChecks(root: root)
            print("Tab-row checks passed")
            return
        }
        // Lets the document-opening checks be run on their own while they are being worked on.
        if CommandLine.arguments.contains("--check-document-opening") {
            let root = checkRoot(CommandLine.arguments.dropFirst().first)
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("lyra-reader-open-\(UUID())")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let first = scratch.appendingPathComponent("a.pdf")
            let second = scratch.appendingPathComponent("b.pdf")
            try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: first)
            try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/multipage.pdf"), to: second)
            try await documentOpeningChecks(a: first, b: second)
            print("Document-opening checks passed")
            return
        }
        // Lets the context-menu/new-window checks be run on their own while they are being
        // worked on (`LyraReaderChecks --check-desktop-interaction .`).
        if CommandLine.arguments.contains("--check-desktop-interaction") {
            let root = checkRoot(CommandLine.arguments.dropFirst(2).first)
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("lyra-reader-desktop-\(UUID())")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let first = scratch.appendingPathComponent("a.pdf")
            let second = scratch.appendingPathComponent("b.pdf")
            try FileManager.default.copyItem(
                at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: first)
            try FileManager.default.copyItem(
                at: root.appendingPathComponent("tests/fixtures/multipage.pdf"), to: second)
            try await desktopInteractionChecks(
                a: first, b: second,
                linkFixture: root.appendingPathComponent("tests/fixtures/link-borders.pdf"))
            print("Desktop-interaction checks passed")
            return
        }
        // Lets the two-window independence checks be run on their own while they are being worked
        // on: they are the direct regression for "every window shares one state".
        if CommandLine.arguments.contains("--check-window-independence") {
            let root = checkRoot(CommandLine.arguments.dropFirst().first)
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("lyra-reader-windows-\(UUID())")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let first = scratch.appendingPathComponent("a.pdf")
            let second = scratch.appendingPathComponent("b.pdf")
            try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: first)
            try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/multipage.pdf"), to: second)
            try await windowIndependenceChecks(a: first, b: second)
            print("Window-independence checks passed")
            return
        }
        // The clear-on-close regression on its own while it is being worked on: it needs a
        // presentable surface, so it is kept runnable outside the full suite.
        if CommandLine.arguments.contains("--check-canvas-clear") {
            let root = checkRoot(CommandLine.arguments.dropFirst().first)
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("lyra-reader-canvas-clear-\(UUID())")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let first = scratch.appendingPathComponent("a.pdf")
            let second = scratch.appendingPathComponent("b.pdf")
            try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: first)
            try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/multipage.pdf"), to: second)
            try await canvasClearChecks(a: first, b: second)
            print("Canvas-clear checks passed")
            return
        }
        let root = checkRoot(CommandLine.arguments.dropFirst().first)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-reader-checks-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let a = temporary.appendingPathComponent("a.pdf")
        let b = temporary.appendingPathComponent("b.pdf")
        try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: a)
        try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/multipage.pdf"), to: b)

        // ── the registered native suites ─────────────────────────────────────────────
        // One entry per suite, in the order the full run has always used them. `--shard i/n`
        // partitions THIS LIST (not the assertions inside a suite) with `index % n`, so shard
        // membership is deterministic, every suite runs exactly once across all shards, and the
        // list is the auditable statement of what "the native regression suite" means.
        let suites: [CheckSuite] = [
            ("document-model-tabs-search", {
                let state = AppState(engine: try RustEngine())
                state.setViewportSize(CGSize(width: 700, height: 500))
                state.newTab(url: a)
                require(state.document?.pageCount == 1 && state.tabs.count == 1, "normal open initializes document/tab")
                try await eventually("normal open loads thumbnail", { state.thumbnails[0] != nil })
                state.searchQuery = "LyraReader"
                state.runSearch()
                try await eventually("normal open searches", { !state.isSearching && !state.searchHits.isEmpty })
                state.searchQuery = "fixture"
                state.runSearch()
                state.searchQuery = ""
                state.runSearch()
                try await Task.sleep(for: .milliseconds(150))
                require(!state.isSearching && state.searchHits.isEmpty, "cleared query rejects queued search")
                state.newTab(url: b)
                require(state.document?.pageCount == 3 && state.selection == nil && state.searchHits.isEmpty,
                        "switch clears selection and search")
                state.gotoPage(2)
                let beforeScroll = state.scrollYPt
                state.scroll(byScreenPoints: 64)
                require(state.scrollYPt > beforeScroll, "positive offset scrolls down")
                state.scroll(byScreenPoints: -64)
                require(abs(state.scrollYPt - beforeScroll) < 0.01, "negative offset scrolls up")
                var wheel = WheelMotion()
                let first = wheel.delta(scrollingDeltaY: -1, precise: false, timestamp: 1)
                let fast = wheel.delta(scrollingDeltaY: -1, precise: false, timestamp: 1.05)
                require(first == 40 && fast > first, "wheel has useful step and burst acceleration")
                require(wheel.delta(scrollingDeltaY: 1, precise: false, timestamp: 1.1) == -40,
                        "reversing wheel resets acceleration")
                require(wheel.delta(scrollingDeltaY: -1, precise: false, timestamp: 2) == 40,
                        "pausing wheel resets acceleration")
                require(wheel.delta(scrollingDeltaY: 2.5, precise: true, timestamp: 2.1) == -2.5,
                        "trackpad preserves system precision and direction")
                let textEngine = try RustEngine()
                _ = try textEngine.openDocument(at: a)
                let text = try await textEngine.textPage(0)
                let rects = text.selectionRects(in: 0...(text.chars.count - 1))
                require(!rects.isEmpty && rects.count < text.chars.count / 2,
                        "selection joins glyphs into line rectangles")
                if let space = text.chars.indices.first(where: {
                    text.chars[$0].unicode == 32 && $0 > 0 && $0 + 1 < text.chars.count
                }) {
                    let aroundSpace = text.selectionRects(in: (space - 1)...(space + 1))
                    require(aroundSpace.count == 1, "selection bridges interword whitespace")
                } else { fatalError("fixture needs an interword space") }
                state.gotoPage(2)
                let offset = state.scrollYPt
                state.selectTab(0)
                state.selectTab(1)
                require(state.scrollYPt == offset, "tabs restore their reading position")
                let activeID = state.document?.id
                state.closeTab(0)
                require(state.document?.id == activeID && state.activeTabIndex == 0, "closing inactive tab preserves active document")
                state.newTab(url: temporary.appendingPathComponent("missing.pdf"))
                require(state.tabs.count == 1 && state.document?.id == activeID, "failed open preserves active tab")
                state.newTab(url: a)
                state.newTab(url: b)
                state.closeTab(2)
                state.closeTab(1)
                state.closeTab(0)
                try await Task.sleep(for: .milliseconds(300))
                require(state.document == nil && state.canvasPages.isEmpty && state.thumbnails.isEmpty
                        && state.references.isEmpty && state.outline.isEmpty && state.annotations.isEmpty,
                        "closing last tab rejects pending work and clears document data")
            }),
            ("interaction", {
                try await interactionChecks(url: a)
            }),
            ("click-intent", {
                try await clickIntentChecks(
                    url: root.appendingPathComponent("tests/fixtures/two-column-references.pdf"))
            }),
            ("cold-click", {
                try await coldClickChecks(
                    citationsURL: root.appendingPathComponent("tests/fixtures/two-column-references.pdf"),
                    mentionsURL: root.appendingPathComponent("tests/fixtures/cross-references.pdf"))
            }),
            ("screen-page", {
                try await screenPageChecks(url: b)
            }),
            ("screen-page-degradation", {
                try await screenPageDegradationChecks(url: b)
            }),
            ("default-mode-render", {
                try await defaultModeRenderChecks(url: b)
            }),
            ("scrolling-quality", {
                try await scrollingQualityChecks(url: b)
            }),
            ("scrolling-render", {
                try await scrollingRenderChecks(url: b)
            }),
            ("thumbnails", {
                try await thumbnailChecks(url: root.appendingPathComponent("tests/fixtures/thin-lines.pdf"))
            }),
            ("link-border-canvas", {
                try await linkBorderCanvasChecks(url: root.appendingPathComponent("tests/fixtures/link-borders.pdf"))
            }),
            ("annotation-basics", {
                try await annotationChecks(a: a, b: b)
            }),
            ("sticky-markup", {
                try await stickyMarkupChecks(
                    fixture: root.appendingPathComponent("tests/fixtures/text-page.pdf"))
            }),
            ("live-markup", {
                try await liveMarkupChecks(
                    textPage: root.appendingPathComponent("tests/fixtures/text-page.pdf"),
                    twoColumn: root.appendingPathComponent("tests/fixtures/two-column-references.pdf"))
            }),
            ("strikeout", {
                try await strikeoutChecks(
                    textPage: root.appendingPathComponent("tests/fixtures/text-page.pdf"),
                    annotated: root.appendingPathComponent("tests/fixtures/annotated.pdf"))
            }),
            ("annotation-recovery", {
                try await annotationRecoveryChecks(a: a, b: b)
            }),
            ("annotation-colour", {
                try await annotationColourChecks(a: a)
            }),
            ("annotation-reading", {
                try await annotationReadingChecks(
                    url: root.appendingPathComponent("tests/fixtures/annotated.pdf"))
            }),
            ("annotation-appearance", {
                try await annotationAppearanceChecks(
                    url: root.appendingPathComponent("tests/fixtures/annotated-appearance.pdf"))
            }),
            ("annotation-canvas", {
                try await annotationCanvasChecks(
                    url: root.appendingPathComponent("tests/fixtures/annotated.pdf"))
            }),
            ("annotation-writeback", {
                try await annotationWritebackChecks(
                    fixture: root.appendingPathComponent("tests/fixtures/text-page.pdf"))
            }),
            ("stamp-signature", {
                try await stampSignatureChecks(root: root)
            }),
            ("content-editing", {
                try await contentEditingChecks(root: root)
            }),
            ("content-edit-identity", {
                try await contentEditIdentityChecks(root: root)
            }),
            ("document-cache", {
                try await documentCacheChecks(root: root)
            }),
            ("annotated-copy-guard", {
                try await annotatedCopyGuardChecks(root: root)
            }),
            ("extract-destination-guard", {
                try await extractDestinationGuardChecks(root: root)
            }),
            ("bookmark-writeback", {
                try await bookmarkWritebackChecks(root: root)
            }),
            ("cross-reader-annotations", {
                try await crossReaderAnnotationChecks(
                    replies: root.appendingPathComponent("tests/fixtures/annotated-replies.pdf"),
                    notes: root.appendingPathComponent("tests/fixtures/annotated-notes.pdf"))
            }),
            ("ink-annotations", {
                try await inkAnnotationChecks(
                    drawing: root.appendingPathComponent("tests/fixtures/text-page.pdf"),
                    annotated: root.appendingPathComponent("tests/fixtures/annotated.pdf"),
                    strokes: root.appendingPathComponent("tests/fixtures/annotated-strokes.pdf"))
            }),
            ("eraser", {
                try await eraserChecks(
                    drawing: root.appendingPathComponent("tests/fixtures/text-page.pdf"),
                    strokes: root.appendingPathComponent("tests/fixtures/annotated-strokes.pdf"))
            }),
            ("partial-erase", {
                try await partialEraseChecks(
                    drawing: root.appendingPathComponent("tests/fixtures/text-page.pdf"),
                    signed: root.appendingPathComponent("tests/fixtures/signed-signature.pdf"),
                    inkReview: root.appendingPathComponent(
                        "tests/fixtures/annotated-ink-review.pdf"))
            }),
            ("placed-text", {
                try await placedTextChecks(
                    drawing: root.appendingPathComponent("tests/fixtures/text-page.pdf"),
                    annotated: root.appendingPathComponent("tests/fixtures/annotated.pdf"),
                    external: root.appendingPathComponent("tests/fixtures/annotated-notes.pdf"))
            }),
            ("textbox-placement", {
                try await textBoxPlacementChecks(
                    drawing: root.appendingPathComponent("tests/fixtures/text-page.pdf"),
                    annotated: root.appendingPathComponent("tests/fixtures/annotated.pdf"))
            }),
            ("mark-selection", {
                try await markSelectionChecks(
                    fixtures: root.appendingPathComponent("tests/fixtures/text-page.pdf"),
                    annotated: root.appendingPathComponent("tests/fixtures/annotated.pdf"),
                    multipage: root.appendingPathComponent("tests/fixtures/multipage.pdf"))
            }),
            ("note-overlay", {
                try await noteOverlayChecks(url: root.appendingPathComponent("tests/fixtures/annotated-notes.pdf"))
            }),
            ("inline-notes", {
                try await inlineNoteChecks(root: root)
            }),
            ("annotation-notes", {
                try await annotationNoteChecks(
                    url: root.appendingPathComponent("tests/fixtures/annotated-notes.pdf"))
            }),
            ("annotation-replies", {
                try await annotationReplyChecks(
                    url: root.appendingPathComponent("tests/fixtures/annotated-replies.pdf"))
            }),
            ("annotation-export", {
                try await annotationExportChecks(root: root)
            }),
            ("thumbnail-annotations", {
                try await thumbnailAnnotationChecks(
                    url: root.appendingPathComponent("tests/fixtures/annotated-appearance.pdf"))
            }),
            ("outline-numbering", {
                try await outlineNumberingChecks(
                    url: root.appendingPathComponent("tests/fixtures/outlined.pdf"))
            }),
            ("bookmarks", {
                try await bookmarkChecks(url: a)
            }),
            ("metadata", {
                try await metadataChecks(root: root)
            }),
            ("signature-write", {
                try await signatureWriteChecks(root: root)
            }),
            ("forms", {
                try await formChecks(root: root)
            }),
            ("annotation-editing", {
                try await annotationEditingChecks(root: root)
            }),
            ("facing-layout", {
                try await facingLayoutChecks(url: b)
            }),
            ("placement-index", {
                placementIndexChecks()
            }),
            ("hosted-preview", {
                try await hostedPreviewChecks(root: root)
            }),
            ("transitions", {
                try await transitionChecks(root: root)
            }),
            ("right-panel", {
                try await rightPanelChecks(root: root)
            }),
            ("performance-panel", {
                try await performancePanelChecks(root: root)
            }),
            ("preview", {
                try await previewChecks(url: b)
            }),
            ("preview-history", {
                try await previewHistoryChecks(url: b)
            }),
            ("preview-transparency", {
                try await previewTransparencyChecks(root: root)
            }),
            ("preview-section", {
                try await previewSectionChecks(root: root)
            }),
            ("linked-preview", {
                try await linkedPreviewChecks(root: root)
            }),
            ("preview-actions", {
                try await previewActionChecks(root: root)
            }),
            ("pointer-zoom", {
                try await pointerZoomChecks(url: b)
            }),
            ("zoom", {
                try await zoomChecks(root: root)
            }),
            ("preview-panel", {
                try previewPanelChecks()
            }),
            ("preview-panel-session", {
                try await previewPanelSessionChecks(url: b)
            }),
            ("reference-entry-text", {
                try referenceEntryTextChecks()
            }),
            ("smooth-scroll", {
                try await smoothScrollChecks(url: b)
            }),
            ("scroll-glide", {
                try scrollGlideChecks()
            }),
            ("scroll-glide-tail", {
                scrollGlideTailChecks()
            }),
            ("scroll-tail-driver", {
                try await scrollTailDriverChecks(url: b)
            }),
            ("scroll-indicator", {
                try await scrollIndicatorChecks(scrollable: b, singlePage: a)
            }),
            ("tile-cache", {
                try await tileCacheChecks(url: b)
            }),
            ("prefetch-band", {
                try await prefetchBandChecks(url: b)
            }),
            ("rename-compatibility", {
                try renameCompatibilityChecks(root: root)
            }),
            ("ai-assistant", {
                try await aiAssistantChecks(root: root)
            }),
            ("inplace-translation", {
                try await inPlaceTranslationChecks(root: root)
            }),
            ("region-reading-notes", {
                try await regionReadingNotesChecks(root: root)
            }),
            ("region-questions", {
                try await regionQuestionChecks(root: root)
            }),
            ("inside-page-tear", {
                try await insidePageTearChecks(root: root)
            }),
            ("ai-audit", {
                try await aiAuditChecks(root: root)
            }),
            ("offline-hint", {
                try await offlineHintChecks(root: root)
            }),
            ("chatgpt", {
                try await chatGPTChecks(root: root)
            }),
            ("appearance", {
                await appearanceChecks()
            }),
            ("reading-polish", {
                try await readingPolishChecks(root: root)
            }),
            ("sidebar-polish", {
                try await sidebarPolishChecks(root: root)
            }),
            ("page-operations", {
                // Registered before the frame-scheduling checks: those need a presentable surface and
                // stop the run where the display is unavailable (an occluded window never presents).
                try await pageOperationChecks(root: root)
            }),
            ("redaction", {
                try await redactionChecks(root: root)
            }),
            ("printing", {
                try await printingChecks(root: root)
            }),
            ("thumbnail-drag", {
                try await thumbnailDragChecks(root: root)
            }),
            ("tab-row-layout", {
                tabRowLayoutChecks()
            }),
            ("titlebar-resize", {
                titlebarResizeChecks()
            }),
            ("titlebar-theme", {
                try await titlebarThemeChecks(root: root)
            }),
            ("tab-retention", {
                try await tabRetentionChecks(root: root)
            }),
            ("document-opening", {
                try await documentOpeningChecks(a: a, b: b)
            }),
            ("desktop-interaction", {
                try await desktopInteractionChecks(
                    a: a, b: b,
                    linkFixture: root.appendingPathComponent("tests/fixtures/link-borders.pdf"))
            }),
            ("window-independence", {
                try await windowIndependenceChecks(a: a, b: b)
            }),
            ("canvas-clear", {
                // Registered with the other surface checks: it asserts the frame presented after the
                // last tab closes, so it needs a window wgpu will actually present.
                try await canvasClearChecks(a: a, b: b)
            }),
            ("frame-scheduling", {
                try await frameSchedulingChecks()
            }),
            ("xfa", {
                // Last: this check opens the local XFA sample and leaves no window behind, but it is
                // kept after the long-lived surface/window checks so its raster timers cannot influence
                // their measurements.
                try await xfaChecks(root: root)
            }),
        ]

        let selected: [(index: Int, suite: CheckSuite)]
        if shardCount == 0 {
            selected = suites.enumerated().map { (index: $0.offset, suite: $0.element) }
        } else {
            selected = suites.enumerated()
                .filter { $0.offset % shardCount == shardIndex - 1 }
                .map { (index: $0.offset, suite: $0.element) }
            print("SHARD \(shardIndex)/\(shardCount): owns \(selected.count) of \(suites.count) suites")
            for entry in selected {
                print("SHARD \(shardIndex)/\(shardCount) suite: [\(entry.index)] \(entry.suite.name)")
            }
            if selected.isEmpty {
                FileHandle.standardError.write(Data("SHARD \(shardIndex)/\(shardCount): no registered suite belongs to this shard\n".utf8))
                exit(1)
            }
        }

        for entry in selected {
            let started = Date()
            print("SUITE START: \(entry.suite.name)")
            try await entry.suite.run()
            let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            print("SUITE PASS: \(entry.suite.name) (\(milliseconds) ms)")
        }
        if shardCount == 0 {
            print("All reader regression checks passed")
        } else {
            print("Shard \(shardIndex)/\(shardCount) passed \(selected.count) suites")
        }    }
}
