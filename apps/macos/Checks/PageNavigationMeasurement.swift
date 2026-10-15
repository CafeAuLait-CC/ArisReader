import ArisReaderKit
import Combine
import Foundation

extension ReaderChecks {
    /// Model/raster readiness, not display presentation/FPS. Uses real PDFium/FFI.
    /// Usage: ArisReaderChecks --measure-page-navigation PDF zoom-percent
    @MainActor static func measurePageNavigation() async throws {
        let args = CommandLine.arguments
        guard args.count == 4, let zoom = Int(args[3]), (10...800).contains(zoom) else {
            throw NSError(domain: "PageNavigationMeasurement", code: 1)
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-navigation-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let copy = temporary.appendingPathComponent("document.pdf")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: args[2]), to: copy)
        let engine = try RustEngine()
        let state = AppState(engine: engine, tileCacheBudgetBytes: 48 * 1024 * 1024)
        let size = CGSize(width: 959, height: 715)
        state.zoomPercent = zoom
        state.setViewportSize(size)
        state.setDeviceScale(2)
        guard state.open(url: copy), let doc = state.document, doc.pageCount > 8 else {
            throw NSError(domain: "PageNavigationMeasurement", code: 2)
        }
        let scale = CGFloat(zoom) / 100
        func sharpCoverage(_ pages: [CanvasPage]) -> Double {
            let center = max(0, (size.width - state.contentWidthPt * scale) / 2)
            let viewport = CGRect(x: -center / scale, y: state.scrollYPt,
                                  width: size.width / scale, height: size.height / scale)
            let placements = engine.visiblePages(scrollYPt: state.scrollYPt,
                viewportHeightPt: viewport.height, gapPt: state.pageGapPt, marginPt: 0)
            let area = placements.reduce(CGFloat(0)) { sum, p in
                let r = viewport.intersection(CGRect(x: p.leftPt, y: p.topPt, width: p.widthPt, height: p.heightPt))
                return sum + (r.isNull ? 0 : r.width * r.height)
            }
            guard area > 0 else { return 0 }
            let sharp = pages.filter {
                $0.image.pixelWidth >= Int(floor($0.placement.widthPt * scale * 2))
                    && $0.image.pixelHeight >= Int(floor($0.placement.heightPt * scale * 2))
            }.reduce(CGFloat(0)) { sum, p in
                let r = viewport.intersection(CGRect(x: p.placement.leftPt, y: p.placement.topPt,
                    width: p.placement.widthPt, height: p.placement.heightPt))
                return sum + (r.isNull ? 0 : r.width * r.height)
            }
            return min(1, Double(sharp / area))
        }
        state.gotoPage(0)
        try await Task.sleep(for: .seconds(2))
        let middle = min(10, doc.pageCount / 2)
        let destinations = [("cold", middle), ("neighbor", middle + 1),
                            ("return", middle), ("distant", doc.pageCount - 2)]
        var results: [[String: Any]] = []
        for (name, page) in destinations {
            var updates: [Double] = []
            var firstSharp: Double?
            let start = ProcessInfo.processInfo.systemUptime
            let observer = state.$canvasPages.sink { pages in
                let coverage = sharpCoverage(pages)
                updates.append(coverage)
                if coverage >= 0.999999, firstSharp == nil {
                    firstSharp = (ProcessInfo.processInfo.systemUptime - start) * 1000
                }
            }
            // Ignore Combine's immediate delivery of the source page.
            updates = []
            firstSharp = nil
            state.gotoPage(page)
            for _ in 0..<10_000 {
                if firstSharp != nil { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            observer.cancel()
            guard let firstSharp else { throw NSError(domain: "PageNavigationMeasurement", code: 3) }
            results.append(["name": name, "page": page + 1, "sharp_ready_ms": firstSharp,
                "partial_sharp_updates": updates.filter { $0 > 0 && $0 < 0.999999 }.count,
                "updates": updates.count, "immediate_sharp": updates.first.map { $0 >= 0.999999 } ?? false,
                "page_cache_bytes": state.pageRasterCacheUsedBytes,
                "tile_cache_bytes": state.tileCacheUsedBytes])
            try await Task.sleep(for: .seconds(2))
        }
        let result: [String: Any] = ["zoom": zoom, "backing_scale": 2, "viewport_pt": [959, 715],
            "pages": doc.pageCount, "screen_page_path": state.usesScreenPageRasters,
            "scope": "model raster readiness; excludes GPU upload and presentation", "jumps": results]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }

}
