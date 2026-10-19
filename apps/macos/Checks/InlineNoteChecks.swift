import AppKit
import LyraReaderKit
import SwiftUI

extension ReaderChecks {
    @MainActor static func inlineNoteChecks(root: URL) async throws {
        _ = NSApplication.shared
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-reader-inline-notes-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var inputs = [root.appendingPathComponent("tests/fixtures/annotated-inline-notes.pdf")]
        let real = root.appendingPathComponent("pdf-samples/with_annotations/review_ashley_du_0904.pdf")
        if FileManager.default.fileExists(atPath: real.path) { inputs.append(real) }
        for input in inputs {
            let copy = scratch.appendingPathComponent(input.lastPathComponent)
            try FileManager.default.copyItem(at: input, to: copy)
            let engine = try RustEngine()
            let state = AppState(engine: engine)
            state.setViewportSize(CGSize(width: 1000, height: 900))
            require(state.open(url: copy), "inline-note PDF opens: \(input.lastPathComponent)")
            let text = try await engine.textPage(0)
            try await eventually("inline comments reach the canvas", {
                !state.inlineNoteMarkers.isEmpty && state.canvasPages.contains {
                    $0.placement.index == PlacementIndex.documentNote(state.inlineNoteMarkers[0].annotationIndex)
                }
            })
            let annotations = state.documentAnnotations
            let markers = InlineNoteMarker.layout(annotations: annotations, textPages: [0: text]).filter { $0.page == 0 }
            let comments = annotations.filter { $0.page == 0 && $0.hasInlineNote }
            require(markers.count == comments.count && markers.count >= 4,
                    "each visible markup comment gets exactly one label, including multiline markup")
            if input == real {
                require(markers.count == 10, "Ashley page 1 has ten markup comments and ten labels")
            } else {
                require(markers.count == 4, "empty, whitespace-only and hidden comments get no label")
            }
            for (offset, marker) in markers.enumerated() {
                require(!markers.dropFirst(offset + 1).contains { $0.rect.intersects(marker.rect) },
                        "same-line comment labels do not cover each other")
                let note = annotations[marker.annotationIndex]
                if let first = note.boxes.first,
                   let line = text.lineBounds(overlapping: CGRect(x: first.xPt, y: first.yPt,
                                                                  width: first.widthPt, height: first.heightPt)) {
                    require(marker.rect.maxX <= line.minX, "the label sits beside the line without covering its text")
                }
                guard let quad = state.canvasPages.first(where: {
                    $0.placement.index == PlacementIndex.documentNote(marker.annotationIndex)
                }) else { fatalError("FAIL: missing inline comment glyph") }
                require(quad.image.pixelWidth > 8 && quad.blend == .normal,
                        "an inline label is a normal-alpha glyph, separate from the highlight")
                if let color = note.color {
                    let bytes = [UInt8](quad.image.bgra)
                    require(stride(from: 0, to: bytes.count, by: 4).contains {
                        bytes[$0] == color.blue && bytes[$0 + 1] == color.green
                            && bytes[$0 + 2] == color.red && bytes[$0 + 3] == 255
                    }, "the label retains the markup's exact RGB colour")
                }
                let point = CGPoint(x: quad.placement.leftPt + quad.placement.widthPt / 2,
                                    y: quad.placement.topPt + quad.placement.heightPt / 2)
                state.endPointerInteraction(at: point, wasClick: true)
                require(state.openDocumentNote?.id == note.id && state.openDocumentNote?.contents == note.contents,
                        "clicking the label opens the complete comment attached to that highlight")
            }
            guard let first = markers.first else { fatalError("FAIL: missing first marker") }
            let note = annotations[first.annotationIndex]
            let host = NSHostingView(rootView: ReaderWindow(
                state: state, opener: DocumentOpenCoordinator(state: state),
                previewPanels: ReferencePreviewPanelController()))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 900),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            func canvas(in view: NSView) -> MetalCanvasView? {
                if let canvas = view as? MetalCanvasView { return canvas }
                return view.subviews.lazy.compactMap { canvas(in: $0) }.first
            }
            try await eventually("the inline note is hosted in the native reader", {
                host.layoutSubtreeIfNeeded()
                return canvas(in: host) != nil
            })
            state.closeDocumentNote()
            host.layoutSubtreeIfNeeded()
            guard let canvas = canvas(in: host) else { fatalError("FAIL: missing canvas") }
            // The toolbar and sidebar determine the real canvas viewport. Compute the click
            // anchor after hosting/layout, rather than using the provisional 1000pt viewport.
            guard let marker = state.inlineNoteMarkers.first(where: { $0.id == first.id }),
                  let anchor = state.anchorViewRect(page: marker.page, region: marker.rect) else {
                fatalError("FAIL: the label has a view-space anchor")
            }
            let location = CGPoint(x: anchor.midX, y: canvas.bounds.height - anchor.midY)
            let hit = host.hitTest(host.convert(location, from: canvas))
            require(hit === canvas, "the label remains clickable through SwiftUI hit testing")
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: canvas.convert(location, to: nil),
                                               modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                if type == .leftMouseDown { canvas.mouseDown(with: event) }
                else { canvas.mouseUp(with: event) }
            }
            func paper(in view: NSView) -> NSTextView? {
                if let text = view as? NSTextView, text.string == note.contents { return text }
                return view.subviews.lazy.compactMap { paper(in: $0) }.first
            }
            try await eventually("clicking the inline label displays its actual scrollable paper", {
                host.layoutSubtreeIfNeeded()
                return paper(in: host)?.enclosingScrollView?.hasVerticalScroller == true
            })
            state.closeDocumentNote()
            state.scroll(toFraction: 0)
            state.zoomActual()
            if let directory = ProcessInfo.processInfo.environment["LYRA_READER_CHECK_SNAPSHOT_DIR"] {
                try await eventually("the first page is sharp for the comment-label snapshot", {
                    state.canvasPages.contains { PlacementIndex.isPageRaster($0.placement.index) && $0.image.pixelWidth > 1000 }
                })
                let pages = state.canvasPages.filter { $0.placement.topPt < state.document!.firstPageSize.height }
                CanvasSnapshot(pages: pages, scale: 2)?.write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent(input.deletingPathExtension().lastPathComponent + "-inline-notes.png"))
            }
            state.zoomIn()
            require(state.documentNoteAnchor(note) != anchor, "the paper anchor follows document zoom")
        }
    }
}
