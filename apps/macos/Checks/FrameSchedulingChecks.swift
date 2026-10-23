import AppKit
import LyraReaderKit

extension ReaderChecks {
    @MainActor static func frameSchedulingChecks() async throws {
        let segments = [
            PagePlacement(index: 0, topPt: 0, leftPt: 10, widthPt: 300, heightPt: 80),
            PagePlacement(index: 0, topPt: 160, leftPt: 10, widthPt: 300, heightPt: 100,
                          sourceTopPt: 80)]
        let viewport = CGSize(width: 400, height: 700)
        let cuts = PageChromeGeometry.tornEdges(frames: segments, viewport: viewport,
            contentWidthPt: 400, zoom: 1, scrollYPt: 0)
        require(cuts.count == 2 && cuts[0].points.count > 20,
                "a split page has two finely irregular paper edges")
        require(cuts[0].points.allSatisfy { $0.y >= 80 && $0.y <= 81.6 }
                    && cuts[1].points.allSatisfy { $0.y <= 160 && $0.y >= 158.4 },
                "tear decorations extend only into the gap, never over PDF pixels")
        let moved = PageChromeGeometry.tornEdges(frames: segments, viewport: viewport,
            contentWidthPt: 400, zoom: 1, scrollYPt: 10)
        require(zip(cuts[0].points, moved[0].points).allSatisfy { abs($0.y - $1.y - 10) < 0.001 && $0.x == $1.x },
                "scrolling translates the same tear pattern without regenerated noise")
        require(PageChromeGeometry.tornEdges(frames: [segments[0]], viewport: viewport,
            contentWidthPt: 400, zoom: 1, scrollYPt: 0).isEmpty,
                "ordinary and restored paper edges have no tear decoration")
        for zoom in [0.5, 1.8, 4] {
            let scaled = PageChromeGeometry.tornEdges(frames: segments, viewport: viewport,
                contentWidthPt: 400, zoom: zoom, scrollYPt: 0)
            require(scaled.count == 2 && scaled.allSatisfy { cut in
                cut.points.allSatisfy { abs($0.y - cut.baseline) <= 1.61 }
            }, "tear teeth remain subtle at zoom \(zoom)")
        }
        _ = NSApplication.shared
        let frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        var canvas: MetalCanvasView? = MetalCanvasView(frame: frame)
        let image = PageImage(pixelWidth: 1, pixelHeight: 1, pointSize: frame.size,
                              bgra: Data([255, 255, 255, 255]), generation: 1)
        canvas!.pages = [CanvasPage(placement: PagePlacement(index: 0, topPt: 0, leftPt: 0,
                                      widthPt: 320, heightPt: 240), image: image)]
        canvas!.annotationPageFrames = [PagePlacement(index: 0, topPt: 0, leftPt: 0,
                                                     widthPt: 320, heightPt: 240)]
        canvas!.onFailure = { fatalError("canvas regression: \($0)") }
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        try await eventually("attached canvas submits a real GPU frame", { canvas!.submittedFrameCount > 0 })
        try await Task.sleep(for: .milliseconds(200))
        let before = canvas!.submittedFrameCount
        let edgesBefore = canvas!.pageChromeRectangles
        for offset in 1...100 { canvas!.scrollYPt = CGFloat(offset) }
        require(canvas!.submittedFrameCount == before, "a burst of model changes waits for one coalesced frame")
        require(canvas!.pageChromeRectangles == edgesBefore,
                "scrollbar updates cannot move paper edges before the corresponding Metal frame")
        try await eventually("queued model changes reach the GPU", { canvas!.submittedFrameCount > before })
        require(abs((canvas!.pageChromeRectangles.first?.minY ?? 0) + 100) < 0.01,
                "the submitted paper and page gap use the same final scroll position")
        try await Task.sleep(for: .milliseconds(200))
        require(canvas!.submittedFrameCount == before + 1, "a burst draws once and an idle canvas submits nothing")

        // Queue a frame, detach and reattach before it runs. The old job must not consume
        // the new surface's request or retain the detached view.
        canvas!.scrollYPt += 1
        window.contentView = NSView(frame: frame)
        window.contentView = canvas
        try await eventually("reattached canvas survives an obsolete queued frame", {
            canvas!.submittedFrameCount > before + 1
        })
        weak let released = canvas
        canvas!.scrollYPt += 1
        window.contentView = NSView(frame: frame)
        canvas = nil
        try await eventually("queued frames do not retain a detached canvas", { released == nil })
    }
}
