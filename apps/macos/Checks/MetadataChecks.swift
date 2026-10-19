import AppKit
import LyraReaderKit
import Foundation

extension ReaderChecks {
    /// Doc-based metadata regressions (T4.9): recognition sources, editing, and the exact
    /// clipboard/file payload the panel shows.
    ///
    /// The fixture answers are known (they are written by `scripts/make-fixtures.py`), so this is
    /// a real end-to-end check through PDFium, UniFFI and `AppState` — not a mock.
    @MainActor
    static func metadataChecks(root: URL) async throws {
        let embedded = root.appendingPathComponent("tests/fixtures/metadata-embedded.pdf")
        let textLayer = root.appendingPathComponent("tests/fixtures/metadata-text-layer.pdf")
        let info = root.appendingPathComponent("tests/fixtures/metadata-info.pdf")
        let empty = root.appendingPathComponent("tests/fixtures/thin-lines.pdf")

        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 900, height: 650))
        state.newTab(url: embedded)
        try await eventually("metadata loads for an embedded-metadata document", {
            !state.metadataLoading && state.metadata != nil
        })

        require(state.metadata?.title.first == "Embedded Metadata: A Study of {Braces} & Percent 100%",
                "XMP title is the one shown")
        require(state.metadata?.title.source == .xmp, "XMP title says XMP")
        require(state.metadata?.authors.values == ["Ada Lovelace", "Alan Turing"],
                "XMP creator list is split into authors")
        require(state.metadata?.authors.source == .xmp, "XMP authors say XMP")
        require(state.metadata?.venue.first == "Journal of Embedded Testing",
                "XMP publicationName is the venue")
        require(state.metadata?.venue.source == .xmp, "XMP venue says XMP")
        require(state.metadata?.year.first == "2024" && state.metadata?.year.source == .xmp,
                "XMP coverDate is the year")
        require(state.metadata?.doi.source == .xmp, "XMP prism:doi is the DOI")
        require(state.metadata?.title.guessed == false, "an XMP value is not marked guessed")
        require(state.metadataBibtex.hasPrefix("@article{lovelace2024embedded,"),
                "the embedded fixture generates an article entry")
        require(state.suggestedBibtexFilename == "lovelace2024embedded.bib",
                "the Save panel starts from the entry key")

        // A correction is the reader's value: the source says Edited, not XMP, and the entry is
        // regenerated from the panel's values.
        state.updateMetadata(.title, text: "Corrected & 100% Title")
        require(state.metadata?.title.source == .edited, "an edited field says Edited")
        require(state.metadata?.title.guessed == false, "an edited field is not guessed")
        require(state.metadataBibtex.contains(#"title = {Corrected \& 100\% Title}"#),
                "editing the title regenerates the escaped entry")
        require(state.metadataSource(for: .title) == .edited,
                "the panel's source badge follows the edit")

        // The clipboard payload is the string the panel shows; copy must not re-extract.
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
        state.copyMetadataBibtex()
        let copied = NSPasteboard.general.string(forType: .string)
        require(copied == state.metadataBibtex,
                "Copy BibTeX puts exactly the panel's string on the clipboard")
        require(copied?.contains("Corrected") == true,
                "the clipboard carries the corrected value, not the original XMP one")

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-reader-bibtex-\(UUID()).bib")
        defer { try? FileManager.default.removeItem(at: scratch) }
        require(state.saveMetadataBibtex(to: scratch), "Save BibTeX writes a .bib file")
        let written = try String(contentsOf: scratch, encoding: .utf8)
        require(written == state.metadataBibtex,
                "the saved file is byte-for-byte the panel's string")

        // The text-layer fixture has no embedded metadata: every field has to come from the page,
        // and its sources have to say which kind of evidence produced each one.
        state.open(url: textLayer)
        try await eventually("metadata reloads for the text-layer document", {
            state.document?.url == textLayer && !state.metadataLoading && state.metadata != nil
        })
        require(state.metadata?.title.first == "Page One Title: 100% & Under_Score",
                "the largest page-one text becomes the title")
        require(state.metadata?.title.source == .firstPage && state.metadata?.title.guessed == true,
                "the title is marked as a page-one guess")
        require(state.metadata?.authors.values == ["Marek Müller", "Ada Lovelace"],
                "the author line is split into two authors")
        require(state.metadata?.venue.source == .pageFurniture,
                "the footer venue is marked as page furniture")
        require(state.metadata?.year.source == .pageFurniture, "the footer year is marked as a guess")
        require(state.metadata?.doi.source == .text && state.metadata?.doi.guessed == false,
                "a DOI found in the text is identified, not guessed")
        require(state.metadataBibtex.contains("@inproceedings{muller2024page,"),
                "the text-layer fixture generates an inproceedings entry")
        require(state.metadataBibtex.contains(#"author = {Marek M\"uller and Ada Lovelace}"#),
                "non-ASCII author names are LaTeX-escaped")

        // Info-only: the dictionary is used even though the page shows a different title.
        state.open(url: info)
        try await eventually("metadata reloads for the /Info document", {
            state.document?.url == info && !state.metadataLoading && state.metadata != nil
        })
        require(state.metadata?.title.first == "Information Dictionary Title",
                "/Info title is used when XMP is absent")
        require(state.metadata?.title.source == .info && state.metadata?.authors.source == .info,
                "/Info is reported as the source")

        // No text layer, no metadata: nothing is invented, and the clipboard still matches the
        // panel (the panel shows the structural entry, with no fields).
        state.open(url: empty)
        try await eventually("metadata loads for a document with no text layer", {
            state.document?.url == empty && !state.metadataLoading && state.metadata != nil
        })
        require(state.metadataIsEmpty(), "a page with no text and no metadata has no fields")
        require(state.metadata?.title.source == .absent, "an empty title has no source")
        require(state.metadataBibtex == "@misc{untitled\n}\n",
                "an empty document produces an entry with no invented fields")
        state.copyMetadataBibtex()
        require(NSPasteboard.general.string(forType: .string) == state.metadataBibtex,
                "the empty document's clipboard payload is still the panel's string")

        print("Metadata checks passed")
    }
}
