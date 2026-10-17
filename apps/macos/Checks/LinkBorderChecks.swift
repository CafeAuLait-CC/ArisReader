import ArisReaderKit
import Foundation

extension ReaderChecks {
    @MainActor static func linkBorderCanvasChecks(url: URL) async throws {
        let engine = try RustEngine()
        let state = AppState(engine: engine)
        state.setViewportSize(CGSize(width: 700, height: 800))
        state.setDeviceScale(2)
        require(state.open(url: url), "link-border fixture opens in the reader")
        func hasGreenBorder(_ page: CanvasPage) -> Bool {
            guard PlacementIndex.isPageRaster(page.placement.index), page.image.pixelWidth > 1000 else { return false }
            let pixels = [UInt8](page.image.bgra)
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                let green = Int(pixels[offset + 1])
                let blue = Int(pixels[offset])
                let red = Int(pixels[offset + 2])
                if green - blue > 60 && green - red > 60 { return true }
            }
            return false
        }
        try await eventually("the sharp page raster contains the PDF's green link border", {
            state.canvasPages.contains(where: hasGreenBorder)
        })
        // The red frame is a genuine /Dest link; the frame must not replace its hit target.
        guard let target = try await engine.links(0).first(where: { $0.page == 0 }),
              let placement = engine.visiblePages(scrollYPt: state.scrollYPt, viewportHeightPt: 800,
                                                  gapPt: state.pageGapPt, marginPt: 0).first else {
            fatalError("FAIL: the framed internal link retains its destination")
        }
        let point = CGPoint(x: placement.leftPt + target.xPt + target.widthPt / 2,
                            y: placement.topPt + target.yPt + target.heightPt / 2)
        try await eventually("the coloured frame's link still opens a reference preview", {
            state.followLink(at: point) && state.referencePreview?.page == 0
        })
        state.closeReferencePreview()
    }
}
