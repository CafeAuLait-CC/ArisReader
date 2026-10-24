import AppKit
import ImageIO

/// Rotate the actual placement data, so the preview and the PDF writer share an orientation.
package enum SignatureRotation {
    package static func pngData(_ data: Data, clockwise: Bool) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(
                data: nil, width: image.height, height: image.width,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.translateBy(x: CGFloat(image.height) / 2, y: CGFloat(image.width) / 2)
        context.rotate(by: clockwise ? -.pi / 2 : .pi / 2)
        context.draw(image, in: CGRect(
            x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
            width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let rotated = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: rotated).representation(using: .png, properties: [:])
    }

    package static func drawn(_ signature: DrawnSignature, clockwise: Bool) -> DrawnSignature {
        DrawnSignature(strokes: signature.strokes.map { stroke in
            stroke.map { point in
                clockwise ? CGPoint(x: 1 - point.y, y: point.x)
                    : CGPoint(x: point.y, y: 1 - point.x)
            }
        }, aspect: 1 / signature.aspect)
    }
}

extension AppState {
    package var canRotatePendingSignature: Bool {
        guard canPlaceFillSignAnnotation, armedFillSignTool == .signature else { return false }
        if case .drawnSignature(let signature) = pendingFillSignPlacement {
            return !signature.isEmpty
        }
        return pendingSignatureImageData != nil
    }

    @discardableResult
    package func rotatePendingSignature(clockwise: Bool) -> Bool {
        guard canRotatePendingSignature else { return false }
        if case .drawnSignature(let signature) = pendingFillSignPlacement {
            armDrawnSignature(SignatureRotation.drawn(signature, clockwise: clockwise))
        } else if let data = pendingSignatureImageData,
                  let rotated = SignatureRotation.pngData(data, clockwise: clockwise) {
            armSignatureTool(imageData: rotated)
        } else { return false }
        statusMessage = "Signature rotated · click the page to place it"
        return true
    }
}
