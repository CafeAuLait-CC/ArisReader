import AppKit
import LyraReaderKit

extension ReaderChecks {
    /// The citation card's type scale and its reduced header, asserted without a screenshot.
    ///
    /// The card is SwiftUI: its internals are not introspectable from the check process. What can
    /// be asserted is the data the view is built from — the type roles and the header row arrays
    /// — plus the model actions behind the buttons. The view derives every title/body style and
    /// every header button from these values, so a regression that reintroduces a removed
    /// control or flattens the hierarchy fails here.
    @MainActor static func previewCitationCardChecks(root: URL) async throws {
        previewCitationTypographyChecks()
        previewCitationHeaderChecks()
        try await previewCitationHeaderActionChecks(root: root)
        print("PASS: citation card typography and reduced header")
    }

    // MARK: - Typography

    /// The title is the body's largest, heaviest line; the citation paragraph uses the palette's
    /// secondary text token and stays readable on the card's raised-bg in both appearances.
    @MainActor static func previewCitationTypographyChecks() {
        let titleSize = ReferencePreviewTypography.titleFontSize
        let bodySize = ReferencePreviewTypography.bodyFontSize
        require(titleSize > bodySize,
                "the paper title (\(titleSize) pt) is larger than the citation body (\(bodySize) pt)")
        require(titleSize - bodySize >= 1 && titleSize - bodySize <= 2,
                "the title grows by 1-2 pt, not by a display-heading jump")
        require(ReferencePreviewTypography.titleWeight >= .semibold,
                "the paper title is semibold or heavier (\(ReferencePreviewTypography.titleWeight))")

        typealias Components = (r: Double, g: Double, b: Double)
        func resolved(_ color: NSColor, under name: NSAppearance.Name) -> Components {
            var result: Components = (0, 0, 0)
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let rgb = color.usingColorSpace(.sRGB)!
                result = (Double(rgb.redComponent), Double(rgb.greenComponent),
                          Double(rgb.blueComponent))
            }
            return result
        }
        func luminance(_ c: Components) -> Double {
            func linear(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
        }
        func contrast(_ a: Components, _ b: Components) -> Double {
            let high = max(luminance(a), luminance(b))
            let low = min(luminance(a), luminance(b))
            return (high + 0.05) / (low + 0.05)
        }
        func hex(_ c: Components) -> String {
            String(format: "#%02X%02X%02X",
                   Int((c.r * 255).rounded()), Int((c.g * 255).rounded()),
                   Int((c.b * 255).rounded()))
        }

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let label = appearance == .aqua ? "light" : "dark"
            let body = resolved(ReferencePreviewTypography.bodyColor, under: appearance)
            let primary = resolved(ReferencePreviewTypography.plainTitleColor, under: appearance)
            let accent = resolved(ReferencePreviewTypography.linkedTitleColor, under: appearance)
            let raised = resolved(LyraReaderTheme.raisedBgColor, under: appearance)
            require(body != primary,
                    "\(label): the citation body differs from the primary/title colour "
                        + "(\(hex(body)) vs \(hex(primary)))")
            require(body != accent,
                    "\(label): the citation body differs from the link title's accent "
                        + "(\(hex(body)) vs \(hex(accent)))")
            let bodyContrast = contrast(body, raised)
            require(bodyContrast >= 4.5,
                    "\(label): the citation body keeps 4.5:1 on the card "
                        + "(\(String(format: "%.2f", bodyContrast)):1)")
            print("PASS: \(label) citation body \(hex(body)) on raised "
                  + "\(hex(raised)) = \(String(format: "%.2f", bodyContrast)):1; "
                  + "primary \(hex(primary)); accent \(hex(accent))")
        }
    }

    // MARK: - Header contents

    /// Exactly the controls the card still offers, in order. There is no pin, new-window or
    /// "Full page" case, so none of the rows can reserve a slot for one.
    @MainActor static func previewCitationHeaderChecks() {
        let expected: [ReferencePreviewHeaderControl] =
            [.back, .pageLink, .bibtex, .goToPage, .close]
        require(ReferencePreviewHeaderControl.allCases == expected,
                "the preview header contains exactly Back, page link, BibTeX, Go to page and Close")
        let names = expected.map(\.rawValue).map { $0.lowercased() }
        require(!names.contains { $0.contains("pin") },
                "the header contains no pin control")
        require(!names.contains { $0.contains("window") },
                "the header contains no open-in-new-window control")
        require(!names.contains { $0.contains("full") },
                "the header contains no Full page control")

        require(ReferencePreviewHeaderLayout.titleRowLeading == [.back],
                "the title row leads with Back")
        require(ReferencePreviewHeaderLayout.titleRowTrailing == [.close],
                "the title row trails with Close alone; the pin/new-window gap is closed")
        require(ReferencePreviewHeaderLayout.detailRowLeading == [.pageLink],
                "the detail row leads with the page link")
        require(ReferencePreviewHeaderLayout.detailRowTrailing(for: .reference) == [.bibtex, .goToPage],
                "a citation's trailing row is packed as BibTeX then Go to page, with no Full page slot")
        for kind in [AppState.ReferencePreviewKind.section, .figure, .page] {
            require(ReferencePreviewHeaderLayout.detailRowTrailing(for: kind) == [.goToPage],
                    "a \(kind) preview offers Go to page only")
        }
    }

    // MARK: - The remaining controls do their jobs

    /// Drive the model actions the five buttons call: jump + Back, close, and BibTeX. The buttons
    /// are thin wrappers, so this is the same code path their actions take.
    @MainActor static func previewCitationHeaderActionChecks(root: URL) async throws {
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

        // BibTeX is still the citation card's copy affordance.
        let copyState = AppState(engine: try RustEngine())
        copyState.setViewportSize(CGSize(width: 900, height: 650))
        copyState.newTab(url: root.appendingPathComponent("tests/fixtures/metadata-embedded.pdf"))
        try await eventually("the citation card's metadata loads", {
            !copyState.metadataLoading && copyState.metadata != nil
        })
        let entry = AppState.CitationEntry(
            label: "[1]",
            text: "Lovelace, A. Embedded Metadata. 2024.",
            page: 0
        )
        copyState.openReferencePreview(page: 0, title: "[1]", from: "page 1",
                                       kind: .reference, entries: [entry])
        require(ReferencePreviewHeaderLayout.detailRowTrailing(for: .reference).contains(.bibtex),
                "the citation card still offers BibTeX")
        require(copyState.canCopyPreviewBibtex, "BibTeX is enabled when metadata exists")
        require(copyState.copyPreviewBibtex(), "the BibTeX control's action copies the entry")
        require(pasteboard.string(forType: .string) == copyState.metadataBibtex,
                "BibTeX on the clipboard is the document's generated entry")

        // Go to page / the page link jump, and Back returns.
        let jumpState = AppState(engine: try RustEngine())
        jumpState.setViewportSize(CGSize(width: 700, height: 500))
        require(jumpState.open(url: root.appendingPathComponent("tests/fixtures/multipage.pdf")),
                "the jump fixture opens")
        jumpState.gotoPage(0)
        let startPage = jumpState.currentPage
        jumpState.openReferencePreview(page: 2, title: "[1]", from: "page 1",
                                       kind: .reference, entries: [entry])
        require(ReferencePreviewHeaderLayout.detailRowTrailing(for: .reference).contains(.goToPage),
                "the citation card still offers Go to page")
        jumpState.jumpFromPreview(to: 2)
        require(jumpState.currentPage == 3,
                "Go to page still jumps to the preview's target page")
        require(jumpState.canGoBack, "the jump is recorded for Back")
        require(jumpState.goBack() && jumpState.currentPage == startPage,
                "Back still returns to the reader's page")
        jumpState.openReferencePreview(page: 2, title: "[1]", from: "page 1",
                                       kind: .reference, entries: [entry])
        jumpState.closeReferencePreview()
        require(jumpState.referencePreview == nil,
                "Close still dismisses the preview")
    }
}
