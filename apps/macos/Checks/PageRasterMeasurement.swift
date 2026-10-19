import LyraReaderKit
import Foundation

extension ReaderChecks {
    /// Opt-in CPU-raster measurement, never part of CI's normal regression run.
    /// Usage: LyraReaderChecks --measure-page-rasters PDF scale retained-page-count
    /// Run under /usr/bin/time -l to measure process peak RSS; this excludes GPU textures.
    @MainActor static func measurePageRasters() async throws {
        let args = CommandLine.arguments
        guard args.count == 5, let scale = Double(args[3]), scale.isFinite, scale > 0,
              let keep = Int(args[4]), keep > 0 else {
            throw NSError(domain: "PageRasterMeasurement", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Expected PDF, positive scale and retained page count"])
        }
        let engine = try RustEngine()
        let document = try engine.openDocument(at: URL(fileURLWithPath: args[2]))
        var images: [PageImage] = []
        var totalBytes = 0
        var peakRetainedBytes = 0
        var samples: [Double] = []
        for page in 0..<document.pageCount {
            // Release the oldest allocation before asking the engine for the next one.
            if images.count >= keep { images.removeFirst() }
            let start = ProcessInfo.processInfo.systemUptime
            let image = try await engine.renderPage(page, scale: scale)
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            totalBytes += image.bgra.count
            images.append(image)
            peakRetainedBytes = max(peakRetainedBytes, images.reduce(0) { $0 + $1.bgra.count })
        }
        let sorted = samples.sorted()
        let result: [String: Any] = [
            "pages": document.pageCount, "scale": scale, "retained_pages": keep,
            "all_pages_bgra_bytes": totalBytes, "peak_retained_bgra_bytes": peakRetainedBytes,
            "render_median_ms": sorted[sorted.count / 2],
            "render_p95_ms": sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)],
            "scope": "CPU PageImage + PDFium + FFI; excludes GPU and AppState"
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
