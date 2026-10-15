import ArisReaderKit
import Foundation

@MainActor private class SlowTileEngine: PreviewEngine {
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

/// Tiles complete only when a check releases them, so row-promotion assertions do not
/// depend on a sleep winning a race with a raster or a loaded CI runner.
@MainActor private final class GatedTileEngine: SlowTileEngine {
    private var waiting: [TileKey: (Int, CheckedContinuation<TileImage, Never>)] = [:]
    private var automatic = false
    var pendingKeys: [TileKey] { Array(waiting.keys) }

    override func rasterizeTile(page: Int, lod: UInt8, tileX: Int, tileY: Int, tileSize: Int) async throws -> TileImage {
        let key = TileKey(page: page, lod: lod, x: tileX, y: tileY)
        requests.append(page)
        active += 1
        maxActive = max(maxActive, active)
        defer { active -= 1 }
        if automatic { return image(key, size: tileSize) }
        return await withCheckedContinuation { waiting[key] = (tileSize, $0) }
    }

    private func image(_ key: TileKey, size: Int) -> TileImage {
        TileImage(page: key.page, lod: key.lod, tileX: key.x, tileY: key.y, sizePx: size,
                  bgra: Data(repeating: 255, count: size * size * 4),
                  generation: UInt64(10_000 + key.page * 10_000 + Int(key.lod) * 1000 + key.y * 10 + key.x))
    }

    func finish(where predicate: (TileKey) -> Bool) {
        for key in pendingKeys.filter(predicate) {
            let (size, continuation) = waiting.removeValue(forKey: key)!
            continuation.resume(returning: image(key, size: size))
        }
    }

    func holdFutureTiles() { automatic = false }

    func finishAll() {
        automatic = true
        finish { _ in true }
    }
}

extension ReaderChecks {
    /// Runs in both raster modes: the thumbnail pipeline is independent of which path draws the
    /// page, and before T4.38 the default (screen-resolution) configuration was never exercised
    /// here at all.
    @MainActor static func thumbnailChecks(url: URL) async throws {
        try await thumbnailChecks(url: url, preferFullPageRasters: false)
        try await thumbnailChecks(url: url, preferFullPageRasters: true)
    }

    @MainActor private static func thumbnailChecks(url: URL, preferFullPageRasters: Bool) async throws {
        let mode = preferFullPageRasters ? "default screen-page path" : "tile path"
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
        let state = AppState(engine: engine, preferFullPageRasters: preferFullPageRasters)
        state.open(url: url)
        try await eventually("\(mode): Retina thumbnail ready", { state.thumbnails[0] != nil })
        require(state.thumbnails[0]?.pixelWidth == 264, "\(mode): thumbnail has native Retina resolution")
        state.setDeviceScale(1)
        try await eventually("\(mode): thumbnail rebuilds for backing-scale change", { state.thumbnails[0]?.pixelWidth == 132 })
    }

    @MainActor static func scrollingQualityChecks(url: URL) async throws {
        let engine = GatedTileEngine()
        defer { engine.finishAll() }
        let state = AppState(engine: engine, preferFullPageRasters: false)
        state.setViewportSize(CGSize(width: 700, height: 500))
        state.open(url: url)
        state.gotoPage(0)
        func row(_ y: Int) -> [CanvasPage] {
            state.canvasPages.filter {
                $0.placement.index >= 0 && $0.placement.index >> 24 == 0
                    && ($0.placement.index >> 10) & 1023 == y
            }
        }
        func hasPreview() -> Bool { state.canvasPages.contains { $0.image.generation == 500 } }
        try await eventually("preview covers rows that have no sharp tiles yet", hasPreview)
        try await eventually("a completed row sharpens before the rest of the page", {
            engine.finish { $0.page == 0 && $0.y == 0 }
            return row(0).count == 3
        })
        require(hasPreview() && row(1).isEmpty, "only complete visible-width rows cover the preview")
        let generations = Set(row(0).map(\.image.generation))
        state.scroll(byScreenPoints: 48)
        require(state.isScrolling && Set(row(0).map(\.image.generation)) == generations && hasPreview(),
                "exposing an uncached row never blurs already sharp text")
        try await eventually("next row has a controllable pending tile", {
            engine.pendingKeys.contains { $0.page == 0 && $0.y == 1 }
        })
        let first = engine.pendingKeys.first { $0.page == 0 && $0.y == 1 }!
        engine.finish { $0 == first }
        try await eventually("one tile of the next row is cached", { state.isTileCached(first) })
        require(row(1).isEmpty && Set(row(0).map(\.image.generation)) == generations,
                "a partially completed new row does not create isolated sharp patches")
        try await eventually("next sharp row appears during ongoing scrolling", {
            state.scroll(byScreenPoints: 0.1)
            engine.finish { $0.page == 0 && $0.y == 1 }
            return row(1).count == 3
        })
        require(state.isScrolling && Set(row(0).map(\.image.generation)) == generations,
                "sharp content stays stable while subsequent rows load without waiting for scroll idle")
        let previewIndex = state.canvasPages.firstIndex { $0.image.generation == 500 }!
        let sharpIndex = state.canvasPages.firstIndex { $0.placement.index >= 0 }!
        require(previewIndex < sharpIndex, "low-resolution backdrop is drawn underneath sharp rows")
        require(engine.maxActive <= AppState.maxConcurrentTileRasters, "progressive rows preserve the raster concurrency bound")
        engine.finishAll()

        let zoomEngine = GatedTileEngine()
        defer { zoomEngine.finishAll() }
        let zoomed = AppState(engine: zoomEngine, preferFullPageRasters: false)
        zoomed.zoomPercent = 400
        zoomed.setViewportSize(CGSize(width: 768, height: 500))
        zoomed.open(url: url)
        zoomed.gotoPage(0)
        func zoomRow(_ y: Int) -> [CanvasPage] {
            zoomed.canvasPages.filter {
                $0.placement.index >= 0 && $0.placement.index >> 24 == 0
                    && ($0.placement.index >> 10) & 1023 == y
            }
        }
        try await eventually("400% visible rows sharpen without waiting for offscreen columns", {
            zoomEngine.finish { $0.page == 0 && $0.x <= 2 && $0.y <= 1 }
            return zoomRow(0).count == 3 && zoomRow(1).count == 3
        })
        require(zoomed.pinnedTiles.contains(TileKey(page: 0, lod: 3, x: 3, y: 0))
                && !zoomed.isTileCached(TileKey(page: 0, lod: 3, x: 3, y: 0))
                && !zoomed.canvasPages.contains { $0.image.generation == 500 },
                "an offscreen prefetch miss cannot keep the visible page blurry")
        let beforeResize = Set((zoomRow(0) + zoomRow(1)).map(\.image.generation))
        zoomed.setViewportSize(CGSize(width: 1000, height: 500))
        require(beforeResize.isSubset(of: Set(zoomed.canvasPages.map(\.image.generation))),
                "widening the viewport preserves its existing sharp columns")
        // At most two rasters from the old viewport may already be in flight.
        zoomEngine.finish { _ in true }
        try await eventually("newly exposed columns join the sharp rows", {
            zoomEngine.finish { $0.page == 0 && $0.x <= 3 && $0.y <= 1 }
            return zoomRow(0).count == 4 && zoomRow(1).count == 4
        })
        zoomEngine.finishAll()

        // A jump is different from slow scrolling: the destination may have no cached
        // rasters at all, whereas returning to the source should need no preview.
        try await eventually("source-page prefetch settles before the jump test", {
            state.pinnedTiles.allSatisfy { state.isTileCached($0) } && engine.active == 0
        })
        let sourceGenerations = Set((row(0) + row(1)).map(\.image.generation))
        engine.holdFutureTiles()
        state.gotoPage(2)
        try await eventually("jump to a cold page gets its own fallback", {
            state.canvasPages.contains { $0.image.generation == 502 }
        })
        try await eventually("destination raster slots are occupied", {
            engine.pendingKeys.count == AppState.maxConcurrentTileRasters
        })
        require(engine.pendingKeys.allSatisfy { $0.page == 2 && $0.y == 0 },
                "direct page jumps prioritize visible destination tiles (pending: \(engine.pendingKeys))")
        require(!state.canvasPages.contains { $0.placement.index >= 0 && $0.placement.index >> 24 == 0 },
                "a distant page jump cannot retain the source page's sharp tiles")
        try await eventually("a cold destination sharpens before all its visible rows finish", {
            engine.finish { $0.page == 2 && $0.y == 0 }
            return state.canvasPages.filter {
                $0.placement.index >= 0 && $0.placement.index >> 24 == 2
                    && ($0.placement.index >> 10) & 1023 == 0
            }.count == 3
        })
        try await eventually("destination rasters are in flight before returning", {
            engine.pendingKeys.filter { $0.page == 2 }.count == AppState.maxConcurrentTileRasters
        })
        state.gotoPage(0)
        require(sourceGenerations.isSubset(of: Set(state.canvasPages.map(\.image.generation)))
                && !state.canvasPages.contains { $0.image.generation == 500 },
                "returning to a cached page is immediately sharp without a preview downgrade")
        engine.finish { $0.page == 2 }
        try await eventually("old destination rasters finish after the return jump", { engine.active == 0 })
        require(sourceGenerations.isSubset(of: Set(state.canvasPages.map(\.image.generation)))
                && !state.canvasPages.contains { $0.placement.index >= 0 && $0.placement.index >> 24 == 2 },
                "late rasters from the abandoned destination do not flash over the cached page")
        engine.finishAll()
    }

    @MainActor static func scrollingRenderChecks(url: URL) async throws {
        let engine = SlowTileEngine()
        let state = AppState(engine: engine, preferFullPageRasters: false)
        state.setViewportSize(CGSize(width: 700, height: 500))
        state.open(url: url)
        state.gotoPage(0)
        try await eventually("whole-page fallback arrives before slow tiles", {
            state.canvasPages.contains { $0.image.generation == 500 }
        })
        let fallback = state.canvasPages.first { $0.image.generation == 500 }!
        require(fallback.placement.widthPt == 600 && fallback.placement.heightPt == 1200,
                "fallback covers the complete page instead of isolated tile patches")
        // A raster that has already started cannot be cancelled, so moving the viewport may
        // only leave the rasters that are running *at that moment* to finish: everything still
        // queued for the old viewport is dropped. `active == maxConcurrentTileRasters` is the
        // state where that is observable without depending on how fast this machine schedules
        // raster tasks -- the engine counts `active` inside the call, so once every slot the
        // scheduler may fill is occupied, no just-created raster can still be unrecorded.
        // The next raster must then be the new viewport's, independent of runner load.
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
