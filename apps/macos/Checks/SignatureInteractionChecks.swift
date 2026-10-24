import AppKit
import Foundation
import LyraReaderKit

extension ReaderChecks {
    @MainActor static func signatureInteractionChecks(state: AppState) throws {
        // NSAlert's draggable background must not claim a pen gesture in its accessory view.
        let pad = SignaturePadView(frame: NSRect(x: 0, y: 0, width: 420, height: 170))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 170),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.contentView = pad
        defer { window.close() }
        require(!pad.mouseDownCanMoveWindow && pad.isOpaque,
                "the signature pad owns drags inside a movable alert")
        require(pad.acceptsFirstMouse(for: nil), "the first pen gesture can also activate the pad")
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: pad.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1)!
        }
        pad.mouseUp(with: event(.leftMouseUp, CGPoint(x: 10, y: 10)))
        require(pad.drawnSignature == nil, "an unmatched mouse-up cannot create a signature or crash")
        pad.mouseDown(with: event(.leftMouseDown, CGPoint(x: 30, y: 30)))
        pad.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 130, y: 80)))
        pad.mouseUp(with: event(.leftMouseUp, CGPoint(x: 230, y: 40)))
        require(pad.drawnSignature?.strokes.first?.count == 3,
                "a down-drag-up gesture records the complete signature stroke")
        require(window.firstResponder === pad, "drawing makes the pad the input responder")

        let typed = TypedSignatureDialog()
        let name = typed.accessory.subviews.compactMap { $0 as? NSTextField }
            .first { $0.isEditable }!
        let fonts = typed.accessory.subviews.compactMap { $0 as? NSPopUpButton }.first!
        let titleWidth = fonts.itemTitles.map {
            ($0 as NSString).size(withAttributes: [.font: fonts.font ?? NSFont.systemFont(ofSize: 13)]).width
        }.max() ?? 0
        require(fonts.frame.width >= titleWidth + 35,
                "every installed handwriting font fits with room for the pop-up arrow")
        require(fonts.frame.width > name.frame.width,
                "the font choice receives more width than the signature name")
        require(!fonts.frame.intersects(name.frame)
                    && typed.accessory.bounds.contains(fonts.frame),
                "the name and font fields do not overlap or extend beyond the accessory")

        // Six asymmetric pixels make a reversed rotation or an accidental mirror visible.
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 3, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        let colors: [NSColor] = [.red, .green, .blue, .yellow, .clear, .black]
        for (index, color) in colors.enumerated() {
            bitmap.setColor(color, atX: index % 2, y: index / 2)
        }
        let data = bitmap.representation(using: .png, properties: [:])!
        let clockwise = SignatureRotation.pngData(data, clockwise: true)!
        let rotated = NSBitmapImageRep(data: clockwise)!
        require(rotated.pixelsWide == 3 && rotated.pixelsHigh == 2,
                "a portrait signature becomes landscape after a quarter turn")
        let expected = [4, 2, 0, 5, 3, 1]
        for (index, originalIndex) in expected.enumerated() {
            let actual = rotated.colorAt(x: index % 3, y: index / 3)!.usingColorSpace(.deviceRGB)!
            let original = bitmap.colorAt(x: originalIndex % 2, y: originalIndex / 2)!
                .usingColorSpace(.deviceRGB)!
            require(abs(actual.alphaComponent - original.alphaComponent) < 0.01
                        && (original.alphaComponent == 0
                            || (abs(actual.redComponent - original.redComponent) < 0.01
                                && abs(actual.greenComponent - original.greenComponent) < 0.01
                                && abs(actual.blueComponent - original.blueComponent) < 0.01)),
                    "clockwise pixel \(index) retains its color and transparency")
        }
        let restored = NSBitmapImageRep(data: SignatureRotation.pngData(clockwise, clockwise: false)!)!
        require(restored.pixelsWide == 2 && restored.pixelsHigh == 3,
                "the inverse turn restores the original dimensions")
        require(SignatureRotation.pngData(Data("bad image".utf8), clockwise: true) == nil,
                "rotation refuses undecodable image data")

        state.selectFillSignTool(.signature)
        state.armSignatureTool(imageData: data)
        require(state.rotatePendingSignature(clockwise: true),
                "received signature pixels can be rotated before placement")
        require(NSBitmapImageRep(data: state.pendingSignatureImageData!)?.pixelsWide == 3,
                "the placement bytes rotate along with the preview")
        let placement = state.canvasPageFrames.first(where: { $0.index == 0 })!
        require(state.placeSignature(atContentPoint: CGPoint(
            x: placement.leftPt + 250, y: placement.topPt + 300)),
                "a rotated signature still places on the page")
        let box = state.annotations.last!.shapeRect!
        require(abs(box.width / box.height - 1.5) < 0.01,
                "the placed signature uses the rotated landscape aspect ratio")
        state.undo()

        let drawn = DrawnSignature(strokes: [[.zero, CGPoint(x: 1, y: 0.5)]], aspect: 4)
        state.selectFillSignTool(.signature)
        state.armDrawnSignature(drawn)
        require(state.rotatePendingSignature(clockwise: true), "ink signatures can rotate too")
        if case .drawnSignature(let result) = state.pendingFillSignPlacement {
            require(result.aspect == 0.25 && result.strokes[0][0] == CGPoint(x: 1, y: 0),
                    "ink rotation updates the aspect and normalized stroke coordinates")
            let preview = DrawnSignaturePreview.image(result)!
            require(abs(preview.size.width / preview.size.height - result.aspect) < 0.01,
                    "the ink preview preserves the rotated aspect ratio without stretching")
        } else { require(false, "rotating an ink signature preserves vector placement") }
        state.clearFillSignTool()
        require(!state.rotatePendingSignature(clockwise: true), "rotation requires an armed signature")

    }
}
