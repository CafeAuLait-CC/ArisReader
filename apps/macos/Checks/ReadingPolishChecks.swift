import AppKit
import ArisReaderKit
import Foundation
import SwiftUI

extension ReaderChecks {
    @MainActor static func readingPolishChecks(root: URL) async throws {
        let suite = "lyra-reading-polish-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: cache)
        }
        let appearance = ReadingAppearanceStore(defaults: defaults)
        require(appearance.mode == .original, "new reading preferences preserve source colours")
        appearance.mode = .night
        require(ReadingAppearanceStore(defaults: defaults).mode == .night, "night reading persists across launches")
        defaults.set("unknown-future-mode", forKey: ReadingAppearanceStore.preferenceKey)
        require(ReadingAppearanceStore(defaults: defaults).mode == .original, "unknown paper preferences safely use original colours")
        let ink = PaperAppearance.night.displayColor(.black).usingColorSpace(.sRGB)!
        let paper = PaperAppearance.night.displayColor(.white).usingColorSpace(.sRGB)!
        require(ink.redComponent > 0.7 && ink.redComponent < 0.85 && paper.redComponent < 0.2,
                "night annotations use subdued light ink and dark paper")
        require(PaperAppearance.warm.displayColor(.white).redComponent > 0.97,
                "warm paper follows the palette cream")
        let source = NSColor(srgbRed: 0.7, green: 0.2, blue: 0.1, alpha: 0.4)
        require(PaperAppearance.night.displayColor(source).alphaComponent == source.alphaComponent,
                "display conversion retains annotation opacity")
        require(PaperAppearance.original.displayColor(source) === source,
                "original reading returns the exact source colour object")

        let history = RecentDocumentStore(defaults: defaults, cacheDirectory: cache, systemDocuments: nil)
        let first = cache.appendingPathComponent("unread-source.pdf")
        let second = cache.appendingPathComponent("second.pdf")
        history.record(first, at: Date(timeIntervalSince1970: 10))
        history.record(second, at: Date(timeIntervalSince1970: 20))
        history.record(first, at: Date(timeIntervalSince1970: 30))
        require(history.entries.count == 2 && history.entries[0].url == first,
                "Recents deduplicates and puts the reopened file first")
        require(!FileManager.default.fileExists(atPath: first.path),
                "recording Recents does not require reading or creating a source PDF")
        let restored = RecentDocumentStore(defaults: defaults, cacheDirectory: cache, systemDocuments: nil)
        require(restored.entries == history.entries, "Recents restores titles and order without opening source files")
        restored.clear()
        require(RecentDocumentStore(defaults: defaults, cacheDirectory: cache, systemDocuments: nil).entries.isEmpty,
                "Clear persists an empty history instead of reimporting old entries")

        let citation = "Yaron Lipman, Ricky T. Q. Chen, Heli Ben-Hamu, Maximilian Nickel, and Matt Le. Flow matching for generative modeling. In International Conference on Learning Representations, 2023."
        require(ReferencePreviewLayout.citationTitle(from: citation) == "Flow matching for generative modeling.",
                "citation headings use the paper title and skip author initials")
        require(ReferencePreviewLayout.citationTitle(from: "[12] A. Author and B. Writer. A useful research title. Journal, 2024.") == "A useful research title.",
                "numbered citations extract titles without repeating the label")
        require(ReferencePreviewLayout.citationTitle(from: "Unstructured citation") == nil,
                "unstructured references keep a neutral heading")

        let state = AppState(engine: PreviewEngine())
        require(state.open(url: root.appendingPathComponent("tests/fixtures/multipage.pdf")),
                "reading-polish fixture opens")
        state.sidebarTab = .bookmarks
        state.sidebarVisible = true
        state.searchQuery = "page"
        state.runSearch()
        require(state.searchSidebarVisible && state.sidebarTab == .bookmarks && state.sidebarVisible,
                "search opens its right sidebar while preserving the left navigation tab")
        try await eventually("search completes in its separate sidebar", { !state.isSearching })
        let controller = ReferencePreviewPanelController()
        let parent = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 900, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        defer { controller.close(); parent.orderOut(nil) }
        state.openReferencePreview(page: 0, title: "Lipman et al., 2023", from: "page 1", kind: .reference,
                                   entries: [.init(label: "Lipman 2023", text: citation)])
        controller.sync(state: state, parentWindow: parent)
        guard let panel = controller.panel else { fatalError("FAIL: child preview opens") }
        require(panel.parent === parent && parent.childWindows?.contains(panel) == true,
                "preview is attached above its owning reader as a native child window")
        require(panel.level == parent.level,
                "preview stays at its reader level (panel \(panel.level.rawValue), parent \(parent.level.rawValue))")
        require(!panel.isFloatingPanel, "preview is not an independent floating panel")
        require(controller.model.entries.first?.heading == "Flow matching for generative modeling.",
                "reference model preserves the clicked header and uses a title heading")
        panel.applyUserFrame(CGRect(x: 100, y: 100, width: 700, height: 600))
        state.openReferencePreview(page: 1, title: "[2]", from: "page 2", kind: .reference,
                                   entries: [.init(label: "2", text: "A short citation.")])
        controller.sync(state: state, parentWindow: parent)
        require(panel.frame.width == PreviewPanelGeometry.defaultSize.width
                    && panel.frame.height == PreviewPanelGeometry.minimumSize.height,
                "a different preview refits both dimensions after a manual resize")
        let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                  windowNumber: parent.windowNumber, context: nil, characters: "\u{1b}",
                                  charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        NSApplication.shared.sendEvent(esc)
        require(state.referencePreview == nil && controller.panel == nil,
                "Esc from the reader closes its child preview without clicking the preview")
        require(parent.childWindows?.isEmpty != false, "closing detaches the preview from its reader")
        let sharedAppearance = ReadingAppearanceStore.shared
        let savedMode = sharedAppearance.mode
        defer { sharedAppearance.mode = savedMode }
        let host = NSHostingView(rootView: ReaderWindow(
            state: state, opener: DocumentOpenCoordinator(state: state), previewPanels: controller))
        parent.contentView = host
        parent.makeKeyAndOrderFront(nil)
        func canvas(in view: NSView) -> MetalCanvasView? {
            if let found = view as? MetalCanvasView { return found }
            return view.subviews.lazy.compactMap { canvas(in: $0) }.first
        }
        sharedAppearance.mode = .night
        try await eventually("night mode reaches the hosted GPU canvas and window appearance", {
            host.layoutSubtreeIfNeeded()
            return canvas(in: host)?.paperAppearance == .night
                && parent.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        })
        sharedAppearance.mode = .warm
        try await eventually("warm paper restores a light window and updates the hosted canvas", {
            host.layoutSubtreeIfNeeded()
            return canvas(in: host)?.paperAppearance == .warm
                && parent.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        })
        sharedAppearance.mode = .original
        try await eventually("Original Colours resets the live canvas profile", {
            host.layoutSubtreeIfNeeded()
            return canvas(in: host)?.paperAppearance == .original
        })
        print("Reading polish checks passed")
    }
}
