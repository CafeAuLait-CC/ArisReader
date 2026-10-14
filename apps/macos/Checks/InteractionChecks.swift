import AppKit
import ArisReaderKit

extension ReaderChecks {
    @MainActor static func interactionChecks(url: URL) async throws {
        let engine = try RustEngine()
        let state = AppState(engine: engine)
        state.setViewportSize(CGSize(width: 700, height: 500))
        require(state.open(url: url), "interaction fixture opens")
        state.gotoPage(0)
        // 595pt page, 256pt tiles at 2x, and 750pt viewport plus prefetch.
        try await eventually("initial tiles complete", { state.canvasPages.count == 9 })
        let initial = state.canvasPages.map(\.image.generation)
        state.zoomIn() // 2x -> 4x raster LOD
        require(state.canvasPages.map(\.image.generation) == initial,
                "zoom immediately retains the old page raster")
        try await eventually("zoom replaces a complete LOD together", {
            let tiles = state.canvasPages.filter { $0.placement.index >= 0 }
            let levels = Set(tiles.map { ($0.placement.index >> 20) & 15 })
            require(levels.count == 1, "zoom never mixes partially ready LODs")
            return levels == [2]
        })
        let sharp = state.canvasPages.map(\.image.generation)
        state.zoomIn() // Still 4x: no rasterization or texture churn.
        require(state.canvasPages.allSatisfy { sharp.contains($0.image.generation) },
                "zoom within a LOD reuses existing tiles")
        state.zoomActual()
        require(state.canvasPages.map(\.image.generation) == initial,
                "zooming back reuses the previous cached LOD")

        let text = try await engine.textPage(0)
        let placement = engine.visiblePages(scrollYPt: 0, viewportHeightPt: 500,
                                            gapPt: state.pageGapPt, marginPt: 0)[0]
        func point(_ index: Int) -> CGPoint {
            let char = text.chars[index]
            return CGPoint(x: placement.leftPt + char.xPt + char.widthPt / 2,
                           y: placement.topPt + char.yPt + char.heightPt / 2)
        }
        try await eventually("selection text layer ready", {
            state.beginSelection(at: point(0))
            return state.selection != nil
        })
        let view = MetalCanvasView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        view.onPointerDown = { state.beginSelection(at: $0) }
        view.onPointerDragged = { state.extendSelection(to: $0) }
        view.interactionSnapshot = { (state.canvasPages, state.scrollYPt) }
        func event(_ type: NSEvent.EventType, _ index: Int) -> NSEvent {
            let position = point(index)
            return NSEvent.mouseEvent(with: type,
                location: CGPoint(x: position.x, y: 500 - position.y),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, 0))
        view.mouseDragged(with: event(.leftMouseDragged, 4))
        require(state.selection?.range == 0...4, "drag selects its intermediate range immediately")
        let firstWidth = view.pages.filter { $0.placement.index < 0 }.first!.placement.widthPt
        view.mouseDragged(with: event(.leftMouseDragged, 12))
        require(state.selection?.range == 0...12, "drag extends before mouse-up or an async turn")
        let overlays = view.pages.filter { $0.placement.index < 0 }
        require(overlays.count == 1 && overlays[0].placement.widthPt > firstWidth,
                "canvas receives a continuous growing selection synchronously")
        let color = Array(overlays[0].image.bgra)
        require(color[0] > color[2], "ordinary selection is blue")
        let pasteboard = NSPasteboard.general
        let savedItems = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            pasteboard.clearContents()
            let items = savedItems.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            pasteboard.writeObjects(items)
        }
        state.copySelection()
        let expected = String(String.UnicodeScalarView(text.chars[0...12].compactMap { Unicode.Scalar($0.unicode) }))
        require(NSPasteboard.general.string(forType: .string) == expected,
                "copy preserves selected text including spaces")
        state.extendSelection(to: point(2))
        require(state.selection?.range == 0...2, "reversing drag shrinks from the original anchor")
        state.clearSelection()
        require(state.canvasPages.allSatisfy { $0.placement.index >= 0 },
                "clearing selection preserves tiles and removes overlays")
    }
}
