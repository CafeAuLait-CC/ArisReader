import AppKit
import ArisReaderKit
import SwiftUI

extension ReaderChecks {
    /// Exercise the actual SwiftUI-to-AppKit bridge; model-only checks never show a window.
    @MainActor static func hostedPreviewChecks(root: URL) async throws {
        _ = NSApplication.shared
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("aris-hosted-preview-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for name in ["two-column-references.pdf", "cross-references.pdf"] {
            try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/" + name),
                                             to: scratch.appendingPathComponent(name))
        }
        let engine = try RustEngine()
        let state = AppState(engine: engine)
        let panels = ReferencePreviewPanelController()
        let host = NSHostingView(rootView: ReaderWindow(
            state: state, opener: DocumentOpenCoordinator(state: state), previewPanels: panels))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 750),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { panels.close(); window.orderOut(nil) }
        func canvas(in view: NSView) -> MetalCanvasView? {
            if let found = view as? MetalCanvasView { return found }
            return view.subviews.lazy.compactMap { canvas(in: $0) }.first
        }
        try await eventually("the real reader hosts its canvas", {
            host.layoutSubtreeIfNeeded()
            return canvas(in: host) != nil
        })
        guard let canvas = canvas(in: host) else { fatalError("FAIL: missing canvas") }
        for kind in ["Citation", "Figure", "Table"] {
            let file = kind == "Citation" ? "two-column-references.pdf" : "cross-references.pdf"
            require(state.open(url: scratch.appendingPathComponent(file)),
                    "the hosted \(kind) fixture opens")
            let page = 0
            let box: CGRect
            if kind == "Citation" {
                guard let target = try await engine.citations(page).first else {
                    fatalError("FAIL: fixture has a citation")
                }
                box = CGRect(x: target.xPt, y: target.yPt, width: target.widthPt, height: target.heightPt)
            } else {
                guard let target = try await engine.captionMentions(page: page).first(where: { $0.kind == kind }) else {
                    fatalError("FAIL: fixture has a \(kind) mention")
                }
                box = CGRect(x: target.xPt, y: target.yPt, width: target.widthPt, height: target.heightPt)
            }
            state.scroll(byScreenPoints: max(0, box.minY - 100))
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            guard let rect = state.anchorViewRect(page: page, region: box) else {
                fatalError("FAIL: target is on the canvas")
            }
            let local = CGPoint(x: rect.midX, y: canvas.bounds.height - rect.midY)
            let hit = host.hitTest(host.convert(local, from: canvas))
            require(hit === canvas, "a \(kind) click reaches the canvas through SwiftUI hit testing")
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: canvas.convert(local, to: nil),
                                   modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            hit?.mouseDown(with: event(.leftMouseDown))
            hit?.mouseUp(with: event(.leftMouseUp))
            try await eventually("the hosted \(kind) click resolves preview content", {
                state.referencePreview != nil
            })
            try await eventually("the hosted \(kind) click displays its floating window", {
                panels.panel?.isVisible == true
            })
            state.closeReferencePreview()
            try await eventually("closing preview state hides the floating window", { panels.panel == nil })
        }
    }
}
