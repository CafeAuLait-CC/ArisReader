import AppKit
import Foundation
import LyraReaderKit

// T4.8: the citation preview's copy actions. The pin and "Open in New Window" controls were
// removed from the preview card; this suite keeps the BibTeX and entry-text actions those checks
// used to share a file with. The card's header itself is asserted in `PreviewCitationCardChecks`.

extension ReaderChecks {
    @MainActor static func previewActionChecks(root: URL) async throws {
        try await previewCopyChecks(root: root)
        print("Preview action checks passed")
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
