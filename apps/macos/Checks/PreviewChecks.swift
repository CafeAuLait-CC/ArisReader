import ArisReaderKit
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
                         widthPt: CGFloat, heightPt: CGFloat) async throws -> PageImage {
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
    func resolveCitations(labels: [String]) async throws -> [Reference] { [] }
    func outline() async throws -> [OutlineEntry] { [] }
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
    }
}
