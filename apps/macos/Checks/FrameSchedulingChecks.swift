import AppKit
import ArisReaderKit

extension ReaderChecks {
    @MainActor static func frameSchedulingChecks() async throws {
        _ = NSApplication.shared
        let frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        var canvas: MetalCanvasView? = MetalCanvasView(frame: frame)
        let image = PageImage(pixelWidth: 1, pixelHeight: 1, pointSize: frame.size,
                              bgra: Data([255, 255, 255, 255]), generation: 1)
        canvas!.pages = [CanvasPage(placement: PagePlacement(index: 0, topPt: 0, leftPt: 0,
                                      widthPt: 320, heightPt: 240), image: image)]
        canvas!.onFailure = { fatalError("canvas regression: \($0)") }
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        try await eventually("attached canvas submits a real GPU frame", { canvas!.submittedFrameCount > 0 })
        try await Task.sleep(for: .milliseconds(200))
        let before = canvas!.submittedFrameCount
        for offset in 1...100 { canvas!.scrollYPt = CGFloat(offset) }
        require(canvas!.submittedFrameCount == before, "a burst of model changes waits for one coalesced frame")
        try await eventually("queued model changes reach the GPU", { canvas!.submittedFrameCount > before })
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
