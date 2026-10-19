import LyraReaderKit
import Foundation

// Deliberately completes the earlier request last to exercise the actual race.
@MainActor class PreviewEngine: PDFEngine {
    let version = "controlled preview test engine"
    func openDocument(at url: URL) throws -> LoadedDocument {
        LoadedDocument(title: "Preview fixture", pageCount: 3, url: url,
                       firstPageSize: CGSize(width: 600, height: 1200))
    }
    func renderPage(_ page: Int, scale: CGFloat) async throws -> PageImage {
        try await Task.sleep(for: .milliseconds(page == 0 ? 160 : 15))
        if page == 2 { throw NSError(domain: "PreviewChecks", code: 1) }
        return PageImage(pixelWidth: 1, pixelHeight: 1,
                         pointSize: CGSize(width: 600, height: 1200),
                         bgra: Data([255, 255, 255, 255]), generation: UInt64(page + 10))
    }
    func rasterizeRegion(page: Int, scale: CGFloat, xPt: CGFloat, yPt: CGFloat,
                         widthPt: CGFloat, heightPt: CGFloat,
                         transparentBackground: Bool) async throws -> PageImage {
        try await renderPage(page, scale: scale)
    }
    func rasterizeTile(page: Int, lod: UInt8, tileX: Int, tileY: Int, tileSize: Int) async throws -> TileImage {
        throw NSError(domain: "PreviewChecks", code: 2)
    }
    func textPage(_ page: Int) async throws -> TextPage { throw NSError(domain: "PreviewChecks", code: 3) }
    func links(_ page: Int) async throws -> [DocumentLink] { [] }
    func citations(_ page: Int) async throws -> [Citation] { [] }
    func captionMentions(page: Int) async throws -> [CaptionMention] { [] }
    func annotations() async throws -> [DocumentAnnotation] { [] }
    func figures() async throws -> [Figure] { [] }
    func references() async throws -> [Reference] { [] }
    func resolveCitations(labels: [String], page: Int) async throws -> [Reference] { [] }
    func outline() async throws -> [OutlineEntry] { [] }
    func metadata() async throws -> DocumentMetadata { .empty }
    func generateBibtex(_ draft: MetadataDraft) -> String { draft.bibtex }
    func search(_ pattern: String, limit: Int) async throws -> [SearchHit] { [] }
    func contentHeightPt(gapPt: CGFloat) -> CGFloat { 3600 }
    func contentWidthPt(gapPt: CGFloat) -> CGFloat { 600 }
    func visiblePages(scrollYPt: CGFloat, viewportHeightPt: CGFloat, gapPt: CGFloat, marginPt: CGFloat) -> [PagePlacement] { [] }
    func pageIndex(atScrollYPt scrollYPt: CGFloat, gapPt: CGFloat) -> Int { 0 }
    func pageTopPt(_ index: Int, gapPt: CGFloat) -> CGFloat { CGFloat(index) * 1200 }
}

extension ReaderChecks {
    @MainActor static func previewChecks(url: URL) async throws {
        let tile = TileImage(page: 0, lod: 0, tileX: 0, tileY: 0, sizePx: 4,
                             bgra: Data((0..<64).map(UInt8.init)), generation: 99)
        let edge = tile.pageImage(pointSize: CGSize(width: 2, height: 3))
        let expectedBytes: [UInt8] = [0,1,2,3,4,5,6,7,16,17,18,19,20,21,22,23,32,33,34,35,36,37,38,39]
        require(edge.pixelWidth == 2 && edge.pixelHeight == 3
                && edge.bgra == Data(expectedBytes),
                "edge tile crops rows without stretching or painting outside page")
        let state = AppState(engine: PreviewEngine())
        state.open(url: url)
        state.openReferencePreview(page: 0, title: "slow", from: "test", kind: .page)
        try await Task.sleep(for: .milliseconds(25))
        state.openReferencePreview(page: 1, title: "latest", from: "test", kind: .page)
        try await Task.sleep(for: .milliseconds(220))
        require(state.referencePreview?.title == "latest"
                && state.referencePreviewPages.first?.image.generation == 11,
                "older preview cannot overwrite newer preview")
        state.setReferencePreviewViewport(CGSize(width: 480, height: 200))
        state.scrollReferencePreview(by: 10000)
        require(state.referencePreviewScrollYPt == 950, "tall preview scrolls to its bottom")
        state.scrollReferencePreview(by: -10000)
        require(state.referencePreviewScrollYPt == 0, "preview scrolling clamps at top")
        let entry = AppState.CitationEntry(label: "second work", text: "Complete reference text", page: 0)
        state.openReferencePreview(page: 1, title: "group", from: "test", kind: .page, entries: [entry])
        state.selectPreviewEntry(entry)
        require(state.referencePreview?.page == 0 && state.referencePreview?.entries.count == 1,
                "grouped entry selects its own page and keeps group")
        state.closeReferencePreview()
        try await Task.sleep(for: .milliseconds(220))
        require(state.referencePreview == nil && state.referencePreviewPages.isEmpty,
                "closing preview rejects in-flight raster")
        state.openReferencePreview(page: 2, title: "failure", from: "test", kind: .page)
        try await eventually("render failure is visible", { state.referencePreviewError != nil && !state.referencePreviewLoading })
        require(state.referencePreviewPages.isEmpty, "failed preview does not retain previous image")
        state.openReferencePreview(page: 0, title: "before switch", from: "test", kind: .page)
        state.open(url: url)
        try await Task.sleep(for: .milliseconds(220))
        require(state.referencePreview == nil && state.referencePreviewPages.isEmpty,
                "document switch invalidates preview")

        // Pure recognition rules: the click path hands the classifier a whole line, so the
        // printed word and its designation both come from text rather than from a link.
        require(SectionReferenceText.reference(in: "See Section 2 for the method.")
                    == SectionReference(printed: "Section 2", designation: "2"),
                "Section N is recognised with its designation")
        require(SectionReferenceText.reference(in: "as shown in §3.2")?.printed == "§3.2",
                "§N.N is recognised")
        require(SectionReferenceText.reference(in: "Chapter IV begins here")?.designation == "IV",
                "Chapter IV is recognised")
        require(SectionReferenceText.reference(in: "Appendix A lists the parameters.")?.printed == "Appendix A",
                "Appendix A is recognised")
        require(SectionReferenceText.reference(in: "Figure 3 shows the pipeline") == nil
                    && SectionReferenceText.reference(in: "Table 2 lists settings") == nil,
                "figure and table references keep their own click paths")
        let outline = [
            OutlineEntry(title: "1 Introduction", page: 0, depth: 0),
            OutlineEntry(title: "2 Method", page: 1, depth: 0),
            OutlineEntry(title: "2.1 Detail", page: 1, depth: 1),
            OutlineEntry(title: "Appendix A", page: 2, depth: 0),
        ]
        require(SectionReferenceText.title(from: outline, page: 1, designation: "2.1") == "2.1 Detail",
                "the outline entry naming the reference's designation wins over a parent")
        require(SectionReferenceText.title(from: outline, page: 1, designation: "2") == "2 Method",
                "a designation match picks the page's own heading")
        require(SectionReferenceText.title(from: outline, page: 3, designation: "B") == nil,
                "a page with no outline entry has no title to offer")
    }

    // MARK: - Preview Back

    /// A preview jump remembers the **exact** reader position and Back restores it.
    ///
    /// Runs against the real engine so `pageTopPt` and `pageIndex` are the production layout,
    /// not a mock's. The fixture is the three-page `multipage.pdf`; the first page starts at 0,
    /// so "somewhere inside page 2, 123 pt down" is a nonzero offset that a page-only model
    /// would lose.
    @MainActor static func previewHistoryChecks(url: URL) async throws {
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        require(state.open(url: url), "history fixture opens")
        // Put a real text selection in the history entry too. Search is the public path that
        // sets one, and `gotoPage` deliberately does not clear it.
        state.searchQuery = "Body text"
        state.runSearch()
        try await eventually("the history fixture searches", {
            !state.isSearching && !state.searchHits.isEmpty
        })
        state.showSearchHit(0)
        guard let startSelection = state.selection else {
            fatalError("FAIL: search did not select text")
        }
        state.gotoPage(1)
        state.scroll(byScreenPoints: 123)
        let startOffset = state.scrollYPt
        let startPage = state.currentPage
        require(startOffset > 0 && startPage == 2,
                "the reader starts partway down the second page")

        let target = min(2, (state.document?.pageCount ?? 1) - 1)
        state.openReferencePreview(page: target, title: "Page \(target + 1)",
                                   from: "page \(startPage)", kind: .page)
        require(state.referencePreview != nil, "a page preview opens before the jump")
        require(state.backHistory.isEmpty && !state.canGoBack,
                "opening a preview records no history")

        state.jumpFromPreview(to: target)
        require(state.backHistory.count == 1 && state.canGoBack,
                "a jump from the preview records one history entry")
        guard let first = state.backHistory.last else { fatalError("FAIL: missing history entry") }
        require(first.scrollYPt == startOffset && first.page == startPage - 1,
                "the entry holds the exact previous scroll position (\(first.scrollYPt) pt)")
        require(first.preview?.title == "Page \(target + 1)",
                "the entry keeps the preview the jump came from")
        require(first.selection == startSelection, "the entry keeps the selection")
        require(state.scrollYPt != startOffset, "the jump actually moved the reader")

        state.scroll(byScreenPoints: 50)
        let secondOffset = state.scrollYPt
        state.jumpFromPreview(to: 0)
        require(state.backHistory.count == 2, "a second jump records a second entry")

        require(state.goBack(), "Back returns from the second jump")
        require(state.scrollYPt == secondOffset, "the first Back restores the exact intermediate offset")
        require(state.currentPage == target + 1, "the first Back restores its page")
        require(state.forwardHistory.count == 1, "Back leaves a forward branch")
        require(state.goBack(), "a second Back walks further back")
        require(state.scrollYPt == startOffset && state.currentPage == startPage,
                "the second Back restores the exact original offset and page")
        require(state.selection == startSelection, "Back restores the selection")
        require(state.backHistory.isEmpty && state.forwardHistory.count == 2,
                "repeated Backs walk the history and keep the forward branch")

        // A new jump has a new future: the branch the reader had backed out of is stale.
        require(!state.forwardHistory.isEmpty, "the forward branch exists before the new jump")
        state.jumpFromPreview(to: 1)
        require(state.forwardHistory.isEmpty, "a new jump truncates the forward branch")

        // Bound: more jumps than the documented cap keep exactly the most recent entries.
        require(AppState.navigationHistoryLimit == 20, "the documented history cap is 20")
        for index in 0..<(AppState.navigationHistoryLimit + 5) {
            state.jumpFromPreview(to: index % 2 == 0 ? 0 : 1)
        }
        require(state.backHistory.count == AppState.navigationHistoryLimit,
                "history is capped at \(AppState.navigationHistoryLimit) entries (found \(state.backHistory.count))")

        // Leaving the document is not a jump: it throws the whole history away.
        require(state.open(url: url), "the next document opens")
        require(state.backHistory.isEmpty && state.forwardHistory.isEmpty && !state.canGoBack,
                "leaving the document clears the history")
        print("PASS: preview history records exact offsets, caps at \(AppState.navigationHistoryLimit), "
              + "clears on document leave")
    }

    // MARK: - Transparent figure crops

    /// Pixel layout of the transparent-crop fixture (`alpha-crop.pdf`), in view points.
    ///
    /// The fixture draws known tones on an unpainted page: a near-white patch, a light-grey
    /// patch, a mid-grey patch, a black patch and a 0.5 pt light-grey table rule. Sampling their
    /// interiors is what turns "the canvas carries alpha" into a profile a person can read.
    private struct AlphaSample {
        let name: String
        let xPt: CGFloat
        let yPt: CGFloat
        let expectedRGB: Int?
        let expectedAlpha: Int
    }

    @MainActor static func previewTransparencyChecks(root: URL) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-reader-alpha-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = scratch.appendingPathComponent("alpha-crop.pdf")
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("tests/fixtures/alpha-crop.pdf"), to: fixture)

        let engine = try RustEngine()
        let loaded = try engine.openDocument(at: fixture)
        require(loaded.pageCount == 1, "alpha fixture opens")
        // The page is A4 (595×842 pt). At 4× the rule is two device rows, so its interior alpha
        // can be sampled without antialiasing ambiguity.
        let scale: CGFloat = 4
        let image = try await engine.rasterizeRegion(
            page: 0, scale: scale, xPt: 0, yPt: 0, widthPt: 595, heightPt: 842,
            transparentBackground: true
        )
        require(image.pixelWidth == 2380 && image.pixelHeight == 3368,
                "the transparent crop keeps the region's pixel dimensions")

        func pixel(_ xPt: CGFloat, _ yPt: CGFloat) -> (r: Int, g: Int, b: Int, a: Int) {
            let x = min(image.pixelWidth - 1, max(0, Int((xPt * scale).rounded(.down))))
            let y = min(image.pixelHeight - 1, max(0, Int((yPt * scale).rounded(.down))))
            let offset = (y * image.pixelWidth + x) * 4
            return image.bgra.withUnsafeBytes { raw -> (r: Int, g: Int, b: Int, a: Int) in
                let bytes = raw.bindMemory(to: UInt8.self)
                return (Int(bytes[offset + 2]), Int(bytes[offset + 1]),
                        Int(bytes[offset]), Int(bytes[offset + 3]))
            }
        }

        // PDF user-space y is bottom-up; the fixture's patches are at y=600..660 and the rule at
        // y=500, so their view-space tops are 842−660 = 182 and 842−500 = 342.
        let samples = [
            AlphaSample(name: "unpainted paper", xPt: 560, yPt: 100,
                        expectedRGB: nil, expectedAlpha: 0),
            AlphaSample(name: "drawn near-white", xPt: 132, yPt: 112,
                        expectedRGB: 242, expectedAlpha: 255),
            AlphaSample(name: "light-grey block", xPt: 132, yPt: 212,
                        expectedRGB: 204, expectedAlpha: 255),
            AlphaSample(name: "light-grey rule", xPt: 300, yPt: 342,
                        expectedRGB: 204, expectedAlpha: 255),
            AlphaSample(name: "mid-grey block", xPt: 300, yPt: 212,
                        expectedRGB: 128, expectedAlpha: 255),
            AlphaSample(name: "black block", xPt: 468, yPt: 212,
                        expectedRGB: 0, expectedAlpha: 255),
        ]
        var profile: [String] = []
        let opaque = try await engine.rasterizeRegion(
            page: 0, scale: scale, xPt: 0, yPt: 0, widthPt: 595, heightPt: 842,
            transparentBackground: false
        )
        for sample in samples {
            let value = pixel(sample.xPt, sample.yPt)
            require(value.a == sample.expectedAlpha,
                    "\(sample.name) has alpha \(value.a), expected \(sample.expectedAlpha)")
            if let expected = sample.expectedRGB {
                require(abs(value.r - expected) <= 3 && abs(value.g - expected) <= 3
                            && abs(value.b - expected) <= 3,
                        "\(sample.name) keeps its tone (\(value.r),\(value.g),\(value.b)), "
                            + "expected ~\(expected)")
            }
            // The crop must not wash out: straight alpha over white reproduces the opaque render
            // at the same point. This is the property that makes grey rules survive.
            let opaqueValue = opaque.bgra.withUnsafeBytes { raw -> (r: Int, g: Int, b: Int, a: Int) in
                let x = min(opaque.pixelWidth - 1, max(0, Int((sample.xPt * scale).rounded(.down))))
                let y = min(opaque.pixelHeight - 1, max(0, Int((sample.yPt * scale).rounded(.down))))
                let offset = (y * opaque.pixelWidth + x) * 4
                let bytes = raw.bindMemory(to: UInt8.self)
                return (Int(bytes[offset + 2]), Int(bytes[offset + 1]),
                        Int(bytes[offset]), Int(bytes[offset + 3]))
            }
            let composite = (value.r * value.a + 255 * (255 - value.a) + 127) / 255
            let compositeG = (value.g * value.a + 255 * (255 - value.a) + 127) / 255
            let compositeB = (value.b * value.a + 255 * (255 - value.a) + 127) / 255
            require(abs(composite - opaqueValue.r) <= 2
                        && abs(compositeG - opaqueValue.g) <= 2
                        && abs(compositeB - opaqueValue.b) <= 2,
                    "\(sample.name) composited over white matches the opaque render")
            profile.append("\(sample.name) \(sample.expectedRGB.map { "rgb \($0)" } ?? "rgb —") a=\(value.a)")
        }
        let cleared = image.bgra.withUnsafeBytes { raw -> Int in
            let bytes = raw.bindMemory(to: UInt8.self)
            return stride(from: 3, to: bytes.count, by: 4).reduce(0) { $0 + (bytes[$1] == 0 ? 1 : 0) }
        }
        require(cleared > image.pixelWidth * image.pixelHeight / 2,
                "most of a text-sparse crop really is clear (\(cleared) transparent pixels)")
        print("PASS: transparent crop alpha profile: " + profile.joined(separator: "; "))
    }

    // MARK: - Section previews

    /// A section link opens a text-only preview; a figure link still opens an image.
    @MainActor static func previewSectionChecks(root: URL) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-reader-section-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for name in ["section-references.pdf", "cross-references.pdf"] {
            try FileManager.default.copyItem(
                at: root.appendingPathComponent("tests/fixtures/" + name),
                to: scratch.appendingPathComponent(name))
        }

        let engine = try RustEngine()
        let state = AppState(engine: engine)
        state.setViewportSize(CGSize(width: 700, height: 500))
        require(state.open(url: scratch.appendingPathComponent("section-references.pdf")),
                "section fixture opens")

        // Body line 0 is `See Section 2 for the method.`; its link annotation covers the whole
        // line, so the click point is the middle of the line's view-space box.
        let line0 = CGRect(x: 72, y: 141, width: 451, height: 15)
        let line1 = CGRect(x: 72, y: 156, width: 451, height: 15)
        guard let sectionBox = state.anchorViewRect(page: 0, region: line0),
              let appendixBox = state.anchorViewRect(page: 0, region: line1) else {
            fatalError("FAIL: the section fixture's page is on the canvas")
        }
        // `anchorViewRect` is canvas-view space (it includes the horizontal centring); the click
        // paths take content space, where the page starts at x = 0.
        let offsetX = max(0, (700 - state.contentWidthPt * state.zoomFactor) / 2)
        let sectionPoint = CGPoint(x: sectionBox.midX - offsetX, y: sectionBox.midY)
        let appendixPoint = CGPoint(x: appendixBox.midX - offsetX, y: appendixBox.midY)
        try await eventually("the section fixture's links load", {
            state.link(at: sectionPoint) != nil && state.link(at: appendixPoint) != nil
        })
        try await eventually("the section fixture's text layer loads", {
            state.hasTextLayer(0)
        })
        try await eventually("the section fixture's outline loads", {
            !state.outline.isEmpty
        })

        require(state.followLink(at: sectionPoint), "the Section 2 link is followed")
        require(state.referencePreview?.kind == .section,
                "a Section link opens the text-only kind")
        require(state.referencePreview?.sectionReference == "Section 2",
                "the section preview keeps the printed reference")
        require(state.referencePreview?.sectionTitle == "2 Method",
                "the section title comes from the document outline")
        require(state.referencePreview?.title == "2 Method",
                "the panel heading is the resolved section title")
        require(state.referencePreviewPages.isEmpty && !state.referencePreviewLoading,
                "a section preview renders no image at all")
        state.closeReferencePreview()

        require(state.followLink(at: appendixPoint), "the Appendix A link is followed")
        require(state.referencePreview?.kind == .section,
                "an Appendix link opens the text-only kind")
        require(state.referencePreview?.sectionReference == "Appendix A",
                "the appendix preview keeps the printed reference")
        require(state.referencePreview?.sectionTitle == nil,
                "the appendix page has no outline entry")
        require(state.referencePreview?.title == "Appendix A",
                "without an outline the reference's own text is the title")
        require(state.referencePreviewPages.isEmpty,
                "an outline-less section preview still renders no image")
        state.closeReferencePreview()

        // The same click path must keep showing the picture for a figure reference.
        require(state.open(url: scratch.appendingPathComponent("cross-references.pdf")),
                "figure fixture opens")
        let mentions = try await engine.captionMentions(page: 0)
        guard let figure = mentions.first(where: { $0.kind == "Figure" }) else {
            fatalError("FAIL: the figure fixture has a Figure mention")
        }
        guard let figureBox = state.anchorViewRect(
            page: 0, region: CGRect(x: figure.xPt, y: figure.yPt,
                                    width: figure.widthPt, height: figure.heightPt)
        ) else { fatalError("FAIL: the figure mention is on the canvas") }
        let figurePoint = CGPoint(x: figureBox.midX - offsetX, y: figureBox.midY)
        try await eventually("the figure fixture's captions load", {
            state.openFigureMention(at: figurePoint)
        })
        require(state.referencePreview?.kind == .figure,
                "a figure mention keeps its image preview")
        try await eventually("the figure preview rasterizes", {
            !state.referencePreviewPages.isEmpty && !state.referencePreviewLoading
        })
        guard let crop = state.referencePreviewPages.first?.image else {
            fatalError("FAIL: the figure crop is missing")
        }
        let cropAlpha = crop.bgra.withUnsafeBytes { raw -> (clear: Int, solid: Int) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var clear = 0
            var solid = 0
            for index in stride(from: 3, to: bytes.count, by: 4) {
                if bytes[index] == 0 { clear += 1 }
                if bytes[index] == 255 { solid += 1 }
            }
            return (clear, solid)
        }
        require(cropAlpha.clear > 0 && cropAlpha.solid > 0,
                "the figure crop carries both clear paper and opaque content")
        print("PASS: section previews are text-only, figure previews keep a transparent image "
              + "(\(cropAlpha.clear) clear / \(cropAlpha.solid) opaque pixels)")
    }
}
