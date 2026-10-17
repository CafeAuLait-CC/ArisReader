import AppKit
import ArisReaderKit
import Foundation

// Executable regressions run with Command Line Tools; no XCTest/Xcode dependency.
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

    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--check-hosted-preview") {
            let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst(2).first
                ?? FileManager.default.currentDirectoryPath)
            try await hostedPreviewChecks(root: root)
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
        // The cold-click regression on its own (`ArisReaderChecks --check-cold-click .`).
        if CommandLine.arguments.contains("--check-cold-click") {
            let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst(2).first
                ?? FileManager.default.currentDirectoryPath)
            try await coldClickChecks(
                citationsURL: root.appendingPathComponent("tests/fixtures/two-column-references.pdf"),
                mentionsURL: root.appendingPathComponent("tests/fixtures/cross-references.pdf"))
            print("Cold-click checks passed")
            return
        }
        // The two interaction fixes, on their own, while they are being worked on
        // (`ArisReaderChecks --check-click-intent .`).
        if CommandLine.arguments.contains("--check-click-intent")
            || CommandLine.arguments.contains("--check-scroll-tail") {
            let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst(2).first
                ?? FileManager.default.currentDirectoryPath)
            if CommandLine.arguments.contains("--check-click-intent") {
                try await clickIntentChecks(
                    url: root.appendingPathComponent("tests/fixtures/two-column-references.pdf"))
                try await coldClickChecks(
                    citationsURL: root.appendingPathComponent("tests/fixtures/two-column-references.pdf"),
                    mentionsURL: root.appendingPathComponent("tests/fixtures/cross-references.pdf"))
            } else {
                scrollGlideTailChecks()
                try await scrollTailDriverChecks(
                    url: root.appendingPathComponent("tests/fixtures/multipage.pdf"))
            }
            print("Interaction checks passed")
            return
        }
        if CommandLine.arguments.contains("--measure-window-engine-cost") {
            try await measureWindowEngineCost()
            return
        }
        // Lets the document-opening checks be run on their own while they are being worked on.
        if CommandLine.arguments.contains("--check-document-opening") {
            let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
                ?? FileManager.default.currentDirectoryPath)
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("aris-open-\(UUID())")
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
        // Lets the two-window independence checks be run on their own while they are being worked
        // on: they are the direct regression for "every window shares one state".
        if CommandLine.arguments.contains("--check-window-independence") {
            let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
                ?? FileManager.default.currentDirectoryPath)
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("aris-windows-\(UUID())")
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
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("aris-checks-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let a = temporary.appendingPathComponent("a.pdf")
        let b = temporary.appendingPathComponent("b.pdf")
        try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: a)
        try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/multipage.pdf"), to: b)
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        state.newTab(url: a)
        require(state.document?.pageCount == 1 && state.tabs.count == 1, "normal open initializes document/tab")
        try await eventually("normal open loads thumbnail", { state.thumbnails[0] != nil })
        state.searchQuery = "ArisReader"
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
        require(first == 32 && fast > first, "wheel has useful step and burst acceleration")
        require(wheel.delta(scrollingDeltaY: 1, precise: false, timestamp: 1.1) == -32,
                "reversing wheel resets acceleration")
        require(wheel.delta(scrollingDeltaY: -1, precise: false, timestamp: 2) == 32,
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
        try await interactionChecks(url: a)
        try await clickIntentChecks(
            url: root.appendingPathComponent("tests/fixtures/two-column-references.pdf"))
        try await coldClickChecks(
            citationsURL: root.appendingPathComponent("tests/fixtures/two-column-references.pdf"),
            mentionsURL: root.appendingPathComponent("tests/fixtures/cross-references.pdf"))
        try await screenPageChecks(url: b)
        try await screenPageDegradationChecks(url: b)
        try await defaultModeRenderChecks(url: b)
        try await scrollingQualityChecks(url: b)
        try await scrollingRenderChecks(url: b)
        try await thumbnailChecks(url: root.appendingPathComponent("tests/fixtures/thin-lines.pdf"))
        try await annotationChecks(a: a, b: b)
        try await annotationRecoveryChecks(a: a, b: b)
        try await annotationColourChecks(a: a)
        try await annotationReadingChecks(
            url: root.appendingPathComponent("tests/fixtures/annotated.pdf"))
        try await annotationAppearanceChecks(
            url: root.appendingPathComponent("tests/fixtures/annotated-appearance.pdf"))
        try await annotationCanvasChecks(
            url: root.appendingPathComponent("tests/fixtures/annotated.pdf"))
        try await annotationNoteChecks(
            url: root.appendingPathComponent("tests/fixtures/annotated-notes.pdf"))
        placementIndexChecks()
        try await hostedPreviewChecks(root: root)
        try await previewChecks(url: b)
        try await pointerZoomChecks(url: b)
        try previewPanelChecks()
        try await previewPanelSessionChecks(url: b)
        try referenceEntryTextChecks()
        try await smoothScrollChecks(url: b)
        try scrollGlideChecks()
        scrollGlideTailChecks()
        try await scrollTailDriverChecks(url: b)
        try await tileCacheChecks(url: b)
        try await prefetchBandChecks(url: b)
        // Registered before the frame-scheduling checks: those need a presentable surface and
        // stop the run where the display is unavailable (an occluded window never presents).
        try await documentOpeningChecks(a: a, b: b)
        try await windowIndependenceChecks(a: a, b: b)
        try await frameSchedulingChecks()
        print("All reader regression checks passed")
    }
}
