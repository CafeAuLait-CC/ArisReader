import LyraReaderKit
import Foundation

/// Hold index reads at an explicit gate so a fast machine cannot hide a cold-click race.
@MainActor private final class PreviewIndexGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor private final class ControlledIndexEngine: PreviewEngine {
    let base: RustEngine
    let citationsGate = PreviewIndexGate()
    let mentionsGate = PreviewIndexGate()
    let figuresGate = PreviewIndexGate()
    var mentionsReturned = 0

    init(base: RustEngine) { self.base = base }
    func releaseAll() {
        citationsGate.release()
        mentionsGate.release()
        figuresGate.release()
    }
    override func openDocument(at url: URL) throws -> LoadedDocument { try base.openDocument(at: url) }
    override func renderPage(_ page: Int, scale: CGFloat) async throws -> PageImage {
        try await base.renderPage(page, scale: scale)
    }
    override func rasterizeRegion(page: Int, scale: CGFloat, xPt: CGFloat, yPt: CGFloat,
                                  widthPt: CGFloat, heightPt: CGFloat,
                                  transparentBackground: Bool) async throws -> PageImage {
        try await base.rasterizeRegion(page: page, scale: scale, xPt: xPt, yPt: yPt,
                                       widthPt: widthPt, heightPt: heightPt,
                                       transparentBackground: transparentBackground)
    }
    override func textPage(_ page: Int) async throws -> TextPage { try await base.textPage(page) }
    override func links(_ page: Int) async throws -> [DocumentLink] { try await base.links(page) }
    override func citations(_ page: Int) async throws -> [Citation] {
        await citationsGate.wait()
        return try await base.citations(page)
    }
    override func captionMentions(page: Int) async throws -> [CaptionMention] {
        await mentionsGate.wait()
        let found = try await base.captionMentions(page: page)
        mentionsReturned += 1
        return found
    }
    override func figures() async throws -> [Figure] {
        await figuresGate.wait()
        return try await base.figures()
    }
    override func resolveCitations(labels: [String], page: Int) async throws -> [Reference] {
        try await base.resolveCitations(labels: labels, page: page)
    }
    override func contentHeightPt(gapPt: CGFloat) -> CGFloat { base.contentHeightPt(gapPt: gapPt) }
    override func contentWidthPt(gapPt: CGFloat) -> CGFloat { base.contentWidthPt(gapPt: gapPt) }
    override func visiblePages(scrollYPt: CGFloat, viewportHeightPt: CGFloat, gapPt: CGFloat,
                               marginPt: CGFloat) -> [PagePlacement] {
        base.visiblePages(scrollYPt: scrollYPt, viewportHeightPt: viewportHeightPt,
                          gapPt: gapPt, marginPt: marginPt)
    }
    override func pageIndex(atScrollYPt scrollYPt: CGFloat, gapPt: CGFloat) -> Int {
        base.pageIndex(atScrollYPt: scrollYPt, gapPt: gapPt)
    }
    override func pageTopPt(_ index: Int, gapPt: CGFloat) -> CGFloat { base.pageTopPt(index, gapPt: gapPt) }
}

extension ReaderChecks {
    @MainActor static func linkedPreviewChecks(root: URL) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-linked-preview-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for name in ["narrative-citation.pdf", "booktabs-bounds.pdf"] {
            try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/" + name),
                                             to: scratch.appendingPathComponent(name))
        }

        // Both index orderings matter: the mention may already be cached while the document's
        // captions are still loading, or the click may beat both of them.
        for scenario in ["citation", "citation-resized", "table-cold", "table6-cold", "table-mentions-ready", "newer-link", "closed", "switched"] {
            let engine = ControlledIndexEngine(base: try RustEngine())
            defer { engine.releaseAll() }
            let table = scenario.hasPrefix("table")
            let url = scratch.appendingPathComponent(table ? "booktabs-bounds.pdf" : "narrative-citation.pdf")
            let state = AppState(engine: engine)
            state.setViewportSize(CGSize(width: 700, height: 500))
            require(state.open(url: url), "\(scenario): fixture opens")
            let links = try await engine.base.links(0).sorted { $0.yPt < $1.yPt }
            require(links.count >= 2, "the fixture includes a plain link as well as indexed targets")
            func point(_ link: DocumentLink) -> CGPoint {
                let placement = engine.visiblePages(scrollYPt: state.scrollYPt, viewportHeightPt: 500,
                                                     gapPt: state.pageGapPt, marginPt: 0).first!
                return CGPoint(x: placement.leftPt + link.xPt + link.widthPt / 2,
                               y: placement.topPt + link.yPt + link.heightPt / 2)
            }
            // Use the mention centre inside the link: a whole-line link also contains plain
            // words, whereas only the printed `Table N` is an indexed target.
            var target = point(links[0])
            if table {
                let label = scenario.hasPrefix("table6") ? "6" : "1"
                let mention = try await engine.base.captionMentions(page: 0).first { $0.label == label }!
                let placement = engine.visiblePages(scrollYPt: 0, viewportHeightPt: 500,
                                                     gapPt: state.pageGapPt, marginPt: 0).first!
                target = CGPoint(x: placement.leftPt + mention.xPt + mention.widthPt / 2,
                                 y: placement.topPt + mention.yPt + mention.heightPt / 2)
            }
            try await eventually("\(scenario): links load before indexes", { state.link(at: target) != nil })
            if scenario == "table-mentions-ready" {
                engine.mentionsGate.release()
                try await eventually("mentions arrive before captions", { engine.mentionsReturned > 0 })
                await Task.yield()
            }
            require(state.followLink(at: target), "the first click follows the internal link")
            require(state.referencePreview?.kind == .page, "the cold click initially has a page fallback")
            if scenario == "citation-resized" || table {
                state.setReferencePreviewViewport(CGSize(width: 420, height: 300))
            }
            let fallback = state.referencePreview
            if scenario == "newer-link" {
                let other = point(links[1])
                try await eventually("the newer link is available", { state.link(at: other) != nil })
                require(state.followLink(at: other), "a second, plain link supersedes the lookup")
            } else if scenario == "closed" {
                state.closeReferencePreview()
            } else if scenario == "switched" {
                require(state.open(url: scratch.appendingPathComponent("booktabs-bounds.pdf")),
                        "a document switch supersedes the lookup")
            }
            engine.releaseAll()
            if scenario.hasPrefix("citation") {
                try await eventually("the first click becomes entry text without another click", {
                    state.referencePreview?.kind == .reference
                })
                require(state.referencePreview?.title == "Guo et al. (2022)", "the full narrative is the title")
                require(state.referencePreview?.entries.count == 1
                        && state.referencePreview?.entries.first?.text.contains("Synthetic motion baseline") == true,
                        "the complete Guo entry is the preview body")
                require(state.referencePreviewPages.isEmpty && !state.referencePreviewLoading,
                        "entry text leaves no screenshot behind")
            } else if table {
                try await eventually("the first click becomes the indexed table crop", {
                    state.referencePreview?.title == (scenario.hasPrefix("table6") ? "Table 6" : "Table 1")
                        && state.referencePreview?.kind == .figure
                        && !state.referencePreviewPages.isEmpty && !state.referencePreviewLoading
                })
                require((state.referencePreview?.region?.height ?? 1000) < 130,
                        "the table preview excludes following prose and the fraction bar")
                let alpha = [UInt8](state.referencePreviewPages[0].image.bgra)
                    .enumerated().filter { $0.offset % 4 == 3 }.map(\.element)
                require(alpha.contains(0) && alpha.contains(255), "the upgraded crop has transparent paper and visible ink")
            } else {
                // Let both the index continuation and any old fallback raster finish.
                try await Task.sleep(for: .milliseconds(250))
                if scenario == "newer-link" {
                    require(state.referencePreview?.kind == .page && state.referencePreview != fallback,
                            "the old citation cannot replace a newer plain link")
                } else {
                    require(state.referencePreview == nil, "a closed or switched preview stays closed")
                }
            }
            state.closeReferencePreview()
        }
        print("PASS: cold linked previews upgrade to entry text or transparent table crops; newer clicks, closes and document switches win")
    }
}
