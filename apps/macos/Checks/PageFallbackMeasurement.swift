import ArisReaderKit
import Combine
import Foundation

extension ReaderChecks {
    /// What the canvas shows *before* a sharp raster arrives, and for how long.
    ///
    /// This is the T4.36 measurement. A cold 140% destination briefly shows the 264x342 sidebar
    /// thumbnail, which is blurrier than the base's 1x whole-page preview, so the fallback needs
    /// numbers rather than an impression. The mode records the canvas-update timeline (the same
    /// granularity as the verification's instrument) for a cold, a neighbour, a return and a
    /// distant jump, and separates "the canvas shows the sharp raster" from "the raster is
    /// cached", so a late canvas update cannot be mistaken for a slow raster. It drives the
    /// model with a real PDFium engine and opens no window, so it runs while the display is
    /// locked.
    ///
    /// Usage: ArisReaderChecks --measure-page-fallback PDF zoom-percent
    @MainActor static func measurePageFallback() async throws {
        let args = CommandLine.arguments
        guard args.count == 4, let zoom = Int(args[3]), (10...800).contains(zoom) else {
            throw NSError(domain: "PageFallbackMeasurement", code: 1)
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-fallback-\(UUID())")
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
            throw NSError(domain: "PageFallbackMeasurement", code: 2)
        }

        let zoomFactor = CGFloat(zoom) / 100
        let screenScale = zoomFactor * 2

        /// The viewport in content points, the way the navigation measurement builds it.
        func viewportRect() -> CGRect {
            let center = max(0, (size.width - state.contentWidthPt * zoomFactor) / 2)
            return CGRect(x: -center / zoomFactor, y: state.scrollYPt,
                          width: size.width / zoomFactor, height: size.height / zoomFactor)
        }

        /// The class that covers most of the viewport, with the pixels it is drawn from.
        func composition(_ pages: [CanvasPage]) -> (dominant: String, sharpCoverage: Double, detail: String) {
            let viewport = viewportRect()
            var area: [String: Double] = [:]
            var detail = ""
            var sharpArea: CGFloat = 0
            var visibleArea: CGFloat = 0
            for page in pages {
                let rect = CGRect(x: page.placement.leftPt, y: page.placement.topPt,
                                  width: page.placement.widthPt, height: page.placement.heightPt)
                let hit = viewport.intersection(rect)
                guard !hit.isNull, hit.width > 0, hit.height > 0 else { continue }
                visibleArea += hit.width * hit.height
                let effective = CGFloat(page.image.pixelWidth) / max(page.placement.widthPt, 1)
                let label: String
                if page.placement.index >= 0 {
                    // A tile is always sharp for the LOD it was rendered at.
                    label = "tile"
                    sharpArea += hit.width * hit.height
                } else if effective >= screenScale * 0.98 {
                    label = "sharp"
                    sharpArea += hit.width * hit.height
                } else if effective >= 0.95 {
                    label = "preview1x"
                } else {
                    label = "thumbnail"
                }
                area[label, default: 0] += hit.width * hit.height
                detail = "\(page.image.pixelWidth)x\(page.image.pixelHeight)px \(label)"
            }
            let dominant = area.max { $0.value < $1.value }?.key ?? "none"
            let sharpCoverage = visibleArea > 0 ? Double(sharpArea / visibleArea) : 0
            return (dominant, sharpCoverage, "\(detail) sharp=\(String(format: "%.2f", sharpCoverage))")
        }

        state.gotoPage(0)
        try await Task.sleep(for: .seconds(3))

        let middle = min(10, doc.pageCount / 2)
        let destinations = [("cold", middle), ("neighbor", middle + 1), ("return", middle),
                            ("distant", doc.pageCount - 2)]
        var jumps: [[String: Any]] = []
        for (name, page) in destinations {
            // Every canvas update that changes what dominates the viewport closes the previous
            // phase and opens a new one, so `phases` is the on-screen quality timeline.
            var phases: [[String: Any]] = []
            var currentLabel: String?
            var currentDetail = ""
            var phaseStart = ProcessInfo.processInfo.systemUptime
            var updateCount = 0
            var sharpMs: Double?
            var thumbnailMs: Double = 0
            var previewMs: Double = 0
            var ignoreNext = true
            let start = ProcessInfo.processInfo.systemUptime
            let observer = state.$canvasPages.sink { pages in
                // `@Published` delivers the current value on subscription; that is the source
                // page, not the jump, so it is not part of the timeline.
                if ignoreNext { ignoreNext = false; return }
                let now = ProcessInfo.processInfo.systemUptime
                updateCount += 1
                let comp = composition(pages)
                if currentLabel != comp.dominant {
                    if let label = currentLabel {
                        phases.append(["label": label, "px": currentDetail,
                                       "start_ms": (phaseStart - start) * 1000,
                                       "end_ms": (now - start) * 1000])
                        let duration = (now - phaseStart) * 1000
                        if label == "thumbnail" { thumbnailMs += duration }
                        if label == "preview1x" { previewMs += duration }
                    }
                    currentLabel = comp.dominant
                    currentDetail = comp.detail
                    phaseStart = now
                }
                if sharpMs == nil, comp.sharpCoverage >= 0.9999 {
                    sharpMs = (now - start) * 1000
                }
            }
            state.gotoPage(page)
            var rasterReadyMs: Double?
            for _ in 0..<2_000 {
                if rasterReadyMs == nil, state.isScreenPageCached(page) {
                    rasterReadyMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
                }
                if sharpMs != nil { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            let now = ProcessInfo.processInfo.systemUptime
            if let label = currentLabel {
                phases.append(["label": label, "px": currentDetail,
                               "start_ms": (phaseStart - start) * 1000, "end_ms": (now - start) * 1000])
                let duration = (now - phaseStart) * 1000
                if label == "thumbnail" { thumbnailMs += duration }
                if label == "preview1x" { previewMs += duration }
            }
            observer.cancel()
            jumps.append([
                "name": name, "page": page + 1,
                "thumbnail_shown_ms": (thumbnailMs * 10).rounded() / 10,
                "preview1x_shown_ms": (previewMs * 10).rounded() / 10,
                "sharp_ms": sharpMs.map { ($0 * 10).rounded() / 10 } ?? NSNull(),
                "raster_ready_ms": rasterReadyMs.map { ($0 * 10).rounded() / 10 } ?? NSNull(),
                "canvas_updates": updateCount,
                "phases": phases,
            ])
            try await Task.sleep(for: .seconds(2))
        }
        let result: [String: Any] = [
            "zoom": zoom, "backing_scale": 2, "viewport_pt": [size.width, size.height],
            "pages": doc.pageCount, "screen_page_path": state.usesScreenPageRasters,
            "screen_scale": screenScale,
            "thumbnail_px": [state.thumbnails[0]?.pixelWidth ?? 0, state.thumbnails[0]?.pixelHeight ?? 0],
            "scope": "canvas-update timeline; excludes GPU upload and presentation",
            "jumps": jumps,
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
