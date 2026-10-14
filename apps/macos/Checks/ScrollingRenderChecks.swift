import ArisReaderKit
import Foundation

@MainActor private final class SlowTileEngine: PreviewEngine {
    var requests: [Int] = []
    var active = 0
    var maxActive = 0

    override func renderPage(_ page: Int, scale: CGFloat) async throws -> PageImage {
        try await Task.sleep(for: .milliseconds(5))
        return PageImage(pixelWidth: 1, pixelHeight: 1, pointSize: CGSize(width: 600, height: 1200),
                         bgra: Data([255, 255, 255, 255]), generation: UInt64(500 + page))
    }

    override func rasterizeTile(page: Int, lod: UInt8, tileX: Int, tileY: Int, tileSize: Int) async throws -> TileImage {
        requests.append(page)
        active += 1
        maxActive = max(maxActive, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(120))
        return TileImage(page: page, lod: lod, tileX: tileX, tileY: tileY, sizePx: tileSize,
                         bgra: Data(repeating: 255, count: tileSize * tileSize * 4),
                         generation: UInt64(1000 + page * 100 + tileY * 10 + tileX))
    }

    override func visiblePages(scrollYPt: CGFloat, viewportHeightPt: CGFloat, gapPt: CGFloat, marginPt: CGFloat) -> [PagePlacement] {
        (0..<3).compactMap { page in
            let top = CGFloat(page) * 1200
            guard top + 1200 >= scrollYPt - marginPt,
                  top <= scrollYPt + viewportHeightPt + marginPt else { return nil }
            return PagePlacement(index: page, topPt: top, leftPt: 0, widthPt: 600, heightPt: 1200)
        }
    }
}

extension ReaderChecks {
    @MainActor static func thumbnailChecks(url: URL) async throws {
        let engine = try RustEngine()
        _ = try engine.openDocument(at: url)
        let scale: CGFloat = 264.0 / 595.0
        let direct = try await engine.renderPage(0, scale: scale)
        let large = try await engine.renderPage(0, scale: scale * 4)
        let reduced = large.downsampled(toWidth: 264)
        func coverage(_ image: PageImage, pdfY: CGFloat) -> Double {
            let centerY = Int(((842 - pdfY) * scale).rounded())
            return ((centerY - 4)...(centerY + 4)).reduce(0) { total, y in
                total + (1 - Double(image.bgra[(y * image.pixelWidth + image.pixelWidth / 2) * 4]) / 255)
            }
        }
        for y: CGFloat in [760, 500, 485] {
            let before = coverage(direct, pdfY: y), after = coverage(reduced, pdfY: y)
            require(after > 0 && after < before * 0.8,
                    "supersampling preserves a thin PDF rule without making it an opaque pixel")
        }
        let state = AppState(engine: engine)
        state.open(url: url)
        try await eventually("Retina thumbnail ready", { state.thumbnails[0] != nil })
        require(state.thumbnails[0]?.pixelWidth == 264, "thumbnail has native Retina resolution")
        state.setDeviceScale(1)
        try await eventually("thumbnail rebuilds for backing-scale change", { state.thumbnails[0]?.pixelWidth == 132 })
    }

    @MainActor static func scrollingRenderChecks(url: URL) async throws {
        let engine = SlowTileEngine()
        let state = AppState(engine: engine)
        state.setViewportSize(CGSize(width: 700, height: 500))
        state.open(url: url)
        state.gotoPage(0)
        try await eventually("whole-page fallback arrives before slow tiles", {
            state.canvasPages.contains { $0.image.generation == 500 }
        })
        let fallback = state.canvasPages.first { $0.image.generation == 500 }!
        require(fallback.placement.widthPt == 600 && fallback.placement.heightPt == 1200,
                "fallback covers the complete page instead of isolated tile patches")
        try await Task.sleep(for: .milliseconds(160))
        require(state.canvasPages.filter { $0.placement.index >= 0 && $0.placement.index >> 24 == 0 }.isEmpty,
                "partial tile completion does not paint a checkerboard over the fallback")
        // A raster that has already started cannot be cancelled, so moving the viewport may
        // only leave the rasters that are running *at that moment* to finish: everything still
        // queued for the old viewport is dropped. `active == maxConcurrentTileRasters` is the
        // state where that is observable without depending on how fast this machine schedules
        // raster tasks -- the engine counts `active` inside the call, so once every slot the
        // scheduler may fill is occupied, no just-created raster can still be unrecorded.
        // The next raster the scheduler starts must then be the new viewport's, on a loaded
        // 3-vCPU runner exactly as on an idle workstation. (Asserting "within one request" of
        // the count taken before the move instead made this a race between the 160 ms wait
        // above and a tile completion waking up its replacement: red on CI, green locally.)
        try await eventually("both raster slots are busy before the viewport moves", {
            engine.active == AppState.maxConcurrentTileRasters
        })
        state.scroll(toFraction: 1)
        let requestsBeforeNavigation = engine.requests.count
        try await eventually("fast navigation reprioritizes the new viewport", { engine.requests.contains(2) })
        let firstNewViewportRaster = engine.requests.firstIndex(of: 2)!
        require(firstNewViewportRaster == requestsBeforeNavigation,
                "offscreen work cannot leave an unbounded raster backlog (the new viewport's first raster was request #\(firstNewViewportRaster), \(requestsBeforeNavigation) were issued before the viewport moved; requests \(engine.requests))")
        require(engine.maxActive <= AppState.maxConcurrentTileRasters,
                "at most two tile requests are in flight")
        try await eventually("new viewport gets a full-page fallback", {
            state.canvasPages.contains { $0.image.generation == 502 }
        })
        try await eventually("new viewport promotes complete sharp tiles", {
            state.canvasPages.contains { $0.placement.index >= 0 && $0.placement.index >> 24 == 2 }
                && !state.canvasPages.contains { $0.image.generation == 502 }
        })

        // A one-pixel black hairline at 4x should reduce to fractional gray coverage,
        // rather than a solid one-pixel line enlarged by the thumbnail view.
        var pixels = Data(repeating: 255, count: 16 * 16 * 4)
        for x in 0..<16 {
            for channel in 0..<3 { pixels[(8 * 16 + x) * 4 + channel] = 0 }
        }
        let source = PageImage(pixelWidth: 16, pixelHeight: 16, pointSize: CGSize(width: 16, height: 16),
                               bgra: pixels, generation: 700)
        let reduced = source.downsampled(toWidth: 4)
        let darkest = (0..<16).map { reduced.bgra[$0 * 4] }.min()!
        require(reduced.pixelWidth == 4 && reduced.pixelHeight == 4 && darkest > 100 && darkest < 250,
                "thumbnail reduction preserves fractional hairline coverage")
    }
}
