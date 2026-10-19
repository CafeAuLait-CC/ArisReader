import AppKit
import Foundation
import LyraReaderKit

// T4.8: the three actions a preview panel can carry — pin, open in a second reader window and
// copy the cited entry's BibTeX. The checks drive the model and the real window registry; the
// panel's SwiftUI buttons are thin wrappers over these entry points.

extension ReaderChecks {
    @MainActor static func previewActionChecks(root: URL) async throws {
        try previewPinChecks()
        try await previewSplitChecks(root: root)
        try await previewCopyChecks(root: root)
        print("Preview action checks passed")
    }

    // MARK: - Pin

    /// A pinned panel keeps the preview it was pinned to; the interaction that would normally
    /// replace it is refused rather than silently replacing it. Unpinning re-arms the update.
    @MainActor static func previewPinChecks() throws {
        let state = AppState(engine: PreviewEngine())
        require(state.open(url: URL(fileURLWithPath: "/tmp/lyra-reader-pin-check.pdf")),
                "the pin fixture opens")
        let controller = ReferencePreviewPanelController()
        defer { controller.close() }
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let firstEntries = [
            AppState.CitationEntry(label: "1", text: "The first work's complete entry.", page: 0),
        ]
        state.openReferencePreview(page: 0, title: "[1]", from: "page 1",
                                   kind: .reference, entries: firstEntries)
        controller.sync(state: state, screen: screen)
        guard let panel = controller.panel else { fatalError("FAIL: the preview opens a panel") }
        let pinnedFrame = panel.frame
        let pinnedPreview = state.referencePreview
        require(pinnedPreview != nil, "the preview is open before pinning")
        require(state.canPinReferencePreview, "the pin action is available for a reference preview")

        state.toggleReferencePreviewPin()
        require(state.referencePreviewPinned, "the pin control pins the preview")
        state.toggleReferencePreviewPin()
        require(!state.referencePreviewPinned, "the same control unpins it")
        state.toggleReferencePreviewPin()
        require(state.referencePreviewPinned, "the preview is pinned again for the replacement")

        let secondEntries = [
            AppState.CitationEntry(label: "2", text: "A different work that should not replace it.",
                                   page: 1),
        ]
        let replaced = state.openReferencePreview(page: 1, title: "[2]", from: "page 1",
                                                  kind: .reference, entries: secondEntries)
        require(!replaced, "a pinned preview refuses the interaction that would replace it")
        require(state.referencePreview == pinnedPreview,
                "the pinned preview keeps its original page, title and entries")
        controller.sync(state: state, screen: screen)
        require(controller.model.entries.map(\.text) == firstEntries.map(\.text),
                "the pinned panel still shows its original entry text")
        require(controller.panel?.frame == pinnedFrame,
                "the pinned panel stays anchored where it was")
        require(state.statusMessage.contains("pinned"),
                "the refused replacement says why the panel did not change")

        state.toggleReferencePreviewPin()
        require(!state.referencePreviewPinned, "the preview unpins")
        let updated = state.openReferencePreview(page: 1, title: "[2]", from: "page 1",
                                                 kind: .reference, entries: secondEntries)
        require(updated, "unpinning restores the update behaviour")
        require(state.referencePreview?.title == "[2]",
                "the next interaction replaces the preview after unpinning")
        controller.sync(state: state, screen: screen)
        require(controller.model.entries.map(\.text) == secondEntries.map(\.text),
                "the panel shows the new entry after unpinning")

        // Every preview kind can be pinned; the control is not specific to citations.
        for kind in [AppState.ReferencePreviewKind.page, .figure, .section] {
            state.openReferencePreview(
                page: 0,
                title: "\(kind)",
                from: "page 1",
                kind: kind,
                region: kind == .figure
                    ? CGRect(x: 0, y: 0, width: 120, height: 80) : nil,
                sectionTitle: kind == .section ? "1 Introduction" : nil,
                sectionReference: kind == .section ? "Section 1" : nil
            )
            require(state.canPinReferencePreview, "the pin action is available for a \(kind) preview")
            state.toggleReferencePreviewPin()
            require(state.referencePreviewPinned, "a \(kind) preview can be pinned")
            state.toggleReferencePreviewPin()
        }
        state.closeReferencePreview()
        require(!state.referencePreviewPinned && state.referencePreview == nil,
                "closing the preview releases the pin too")
        print("PASS: pin freezes the panel, unpin restores updates, and every kind can be pinned")
    }

    // MARK: - Open in a second reader window

    /// The action opens the preview target in a second independent reader window through the
    /// registry, landing on the right page and position, while the source window keeps its page,
    /// its scroll offset and its tabs.
    @MainActor static func previewSplitChecks(root: URL) async throws {
        _ = NSApplication.shared
        try await splitRigCheck(root: root,
                                kind: .figure,
                                region: CGRect(x: 20, y: 40, width: 200, height: 80),
                                label: "figure region")
        try await splitRigCheck(root: root, kind: .page, region: nil, label: "page")
        try await splitRigCheck(root: root,
                                kind: .reference,
                                region: CGRect(x: 12, y: 60, width: 240, height: 36),
                                label: "citation entry")
        try await splitRigCheck(root: root, kind: .section, region: nil, label: "section")
        print("PASS: open in a new window lands on the preview target and leaves the source window alone")
    }

    @MainActor private static func splitRigCheck(
        root: URL,
        kind: AppState.ReferencePreviewKind,
        region: CGRect?,
        label: String
    ) async throws {
        let registry = ReaderWindowRegistry()
        registry.markReady()
        let sourceState = AppState(engine: try RustEngine())
        sourceState.setViewportSize(CGSize(width: 700, height: 500))
        require(sourceState.open(url: root.appendingPathComponent("tests/fixtures/multipage.pdf")),
                "the split fixture opens in the source window")
        let source = ReaderSession(state: sourceState, registry: registry)
        source.register()

        var targets: [AppState] = []
        var targetSessions: [ReaderSession] = []
        registry.newWindow = {
            let target = AppState(engine: try! RustEngine())
            target.setViewportSize(CGSize(width: 700, height: 500))
            targets.append(target)
            let session = ReaderSession(state: target, registry: registry)
            targetSessions.append(session)
            registry.register(session)
        }
        require(source.previewPanels.openInNewWindow != nil,
                "the reader window installs the panel's new-window action")

        sourceState.gotoPage(0)
        sourceState.scroll(byScreenPoints: 123)
        let sourcePage = sourceState.currentPage
        let sourceScroll = sourceState.scrollYPt
        let sourceTabs = sourceState.tabs.count

        let targetPage = min(2, (sourceState.document?.pageCount ?? 1) - 1)
        sourceState.openReferencePreview(
            page: targetPage,
            title: label,
            from: "page 1",
            kind: kind,
            region: region,
            entries: [AppState.CitationEntry(label: label, text: "A previewed target.")]
        )
        require(source.previewPanels.openInNewWindow?() == true,
                "the panel's action asks the registry for a \(label) window")
        require(registry.newWindowRequestCount == 1,
                "the registry served exactly one new-window request for \(label)")
        require(targets.count == 1, "a second reader window was created for \(label)")
        guard let target = targets.first else { fatalError("FAIL: missing target window") }
        guard let targetDocument = target.document else {
            fatalError("FAIL: the new window has no document")
        }
        require(targetDocument.url == sourceState.document?.url,
                "the new window opens the same document")
        require(target.currentPage == targetPage + 1,
                "the new window arrives on page \(targetPage + 1) for \(label)")

        let pageTop = target.engine.pageTopPt(targetPage, gapPt: target.pageGapPt,
                                              layout: target.layoutMode)
        let expected = region.map { pageTop + $0.minY - 24 } ?? pageTop
        require(abs(target.scrollYPt - expected) < 0.5,
                "the new window scrolls to the preview's position for \(label) "
                + "(\(target.scrollYPt) pt, expected \(expected))")
        if region != nil {
            require(target.scrollYPt > pageTop,
                    "a figure/citation region lands below the page top for \(label)")
        } else {
            require(abs(target.scrollYPt - pageTop) < 0.5,
                    "a page target lands at the page top for \(label)")
        }

        // The source window is untouched: same page, same offset, same tab, same preview.
        require(sourceState.currentPage == sourcePage && sourceState.scrollYPt == sourceScroll,
                "the source window keeps its page and scroll offset for \(label)")
        require(sourceState.tabs.count == sourceTabs, "the source window keeps its tabs")
        require(sourceState.referencePreview != nil,
                "the source window keeps its preview open for \(label)")
        require(sourceState.backHistory.isEmpty,
                "opening a second window records no jump in the source window")
        _ = targetSessions
    }

    // MARK: - Copy the entry

    /// Copy BibTeX from a citation preview is the metadata panel's exact payload; when metadata
    /// is unavailable the action is absent/disabled and leaves the clipboard alone. Entry-text
    /// copy always works.
    @MainActor static func previewCopyChecks(root: URL) async throws {
        let pasteboard = NSPasteboard.general
        let savedItems = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            pasteboard.clearContents()
            let items = savedItems.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            pasteboard.writeObjects(items)
        }

        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 900, height: 650))
        state.newTab(url: root.appendingPathComponent("tests/fixtures/metadata-embedded.pdf"))
        try await eventually("the copy fixture's metadata loads", {
            !state.metadataLoading && state.metadata != nil
        })

        let entry = AppState.CitationEntry(label: "[1]",
                                           text: "Lovelace, A. Embedded Metadata. 2024.",
                                           page: 0)
        state.openReferencePreview(page: 0, title: "[1]", from: "page 1",
                                   kind: .reference, entries: [entry])
        require(state.canCopyPreviewBibtex,
                "a citation preview offers BibTeX when the document has metadata")
        require(state.copyPreviewBibtex(), "copying the citation's BibTeX succeeds")
        let fromPreview = pasteboard.string(forType: .string)
        require(fromPreview == state.metadataBibtex,
                "the preview's BibTeX is exactly the metadata panel's string")

        // The metadata panel's own action produces the same bytes; neither regenerates.
        pasteboard.clearContents()
        state.copyMetadataBibtex()
        let fromMetadataPanel = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        require(state.copyPreviewBibtex(), "the preview copies BibTeX again")
        require(pasteboard.string(forType: .string) == fromMetadataPanel,
                "the preview and the metadata panel put the same entry on the clipboard")

        require(state.copyPreviewEntryText(entry), "a citation entry's text can be copied")
        require(pasteboard.string(forType: .string) == entry.text,
                "copying the entry text puts exactly that text on the clipboard")

        // The action does not apply to page, figure or section previews: absent, and refused if
        // something calls it anyway.
        for kind in [AppState.ReferencePreviewKind.page, .figure, .section] {
            state.openReferencePreview(
                page: 0,
                title: "\(kind)",
                from: "page 1",
                kind: kind,
                region: kind == .figure
                    ? CGRect(x: 0, y: 0, width: 120, height: 80) : nil,
                sectionTitle: kind == .section ? "1 Introduction" : nil,
                sectionReference: kind == .section ? "Section 1" : nil
            )
            require(!state.canCopyPreviewBibtex,
                    "\(kind) previews have no BibTeX action")
            pasteboard.clearContents()
            pasteboard.setString("untouched", forType: .string)
            require(!state.copyPreviewBibtex(),
                    "\(kind) previews refuse to copy BibTeX")
            require(!state.copyPreviewEntryText(entry),
                    "\(kind) previews refuse to copy entry text")
            require(pasteboard.string(forType: .string) == "untouched",
                    "the \(kind) refusal leaves the clipboard alone")
        }

        // No metadata: the action is disabled and its absence is reported, not papered over with
        // an invented entry.
        let bare = AppState(engine: PreviewEngine())
        require(bare.open(url: root.appendingPathComponent("tests/fixtures/text-page.pdf")),
                "the no-metadata fixture opens")
        bare.openReferencePreview(page: 0, title: "[1]", from: "page 1",
                                  kind: .reference, entries: [entry])
        require(bare.metadataBibtex.isEmpty, "the no-metadata engine generates no entry")
        require(!bare.canCopyPreviewBibtex, "no metadata means no BibTeX action")
        pasteboard.clearContents()
        pasteboard.setString("untouched", forType: .string)
        require(!bare.copyPreviewBibtex(), "copying BibTeX without metadata is refused")
        require(pasteboard.string(forType: .string) == "untouched",
                "the refusal without metadata leaves the clipboard alone")
        require(bare.statusMessage.contains("No BibTeX"),
                "the refusal without metadata says so")
        print("PASS: citation BibTeX copies the metadata panel's string; absent metadata and "
              + "non-citation kinds are handled")
    }
}
