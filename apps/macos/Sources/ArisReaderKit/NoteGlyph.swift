import AppKit
import CoreGraphics
import CoreText
import Foundation

/// The two glyphs a PDF annotation can need that are not a tinted box: a sticky note's icon and a
/// free-text annotation's own text.
///
/// The canvas draws textured quads and nothing else (see `MetalCanvasView`), so both are rendered
/// here into a bitmap that the existing pipeline can upload. Two rules follow from that pipeline
/// and are the reason this file exists rather than a call to `NSImage` at the draw site:
///
/// * **Straight alpha.** CoreGraphics hands back premultiplied bytes, and the quad pipeline blends
///   straight alpha (`src·a + dst·(1 − a)`), so a premultiplied bitmap is composited with its alpha
///   applied twice — which shows up as dark fringes along every antialiased edge. The buffer is
///   divided back out by its own alpha before it is uploaded.
/// * **A resolution, not a size.** The bitmap is rasterized at `zoom × deviceScale` pixels per
///   point, rounded up to a power of two, because the canvas scales it by the same zoom the page
///   under it is rasterized at. Without that, a note icon is crisp at 100% and mush at 400%.
///
/// Nothing here reads the file's font: a free-text annotation names a face this process does not
/// have (`/DFWaWaSC-W5`, a Chinese face, in 22 of the 23 free-text annotations in the local review
/// corpus), so the text is drawn in the system font at the size `/DA` states.
enum NoteGlyph {
    /// The default size of a free-text annotation whose `/DA` states none, in points.
    ///
    /// `/DA` is required on a `/FreeText` by PDF 32000-1 table 174, so this is the malformed-file
    /// case only. 12 pt is the size Acrobat writes in its own default appearance string and about
    /// the size of the body text these annotations sit next to.
    static let defaultFreeTextSizePt: CGFloat = 12

    /// The largest glyph either renderer will produce, on its longest side, in pixels.
    ///
    /// A guard against a malformed annotation rather than a rendering choice. A `/Rect` the size
    /// of a poster at 800% zoom would otherwise ask for a texture larger than the GPU will take,
    /// and the failure would be an allocation, not a picture. 2048 is ~4 MP (16 MB), which is more
    /// than a normal annotation box needs at any zoom: the 26 pt sticky notes in the review corpus
    /// are 208 px square at 8 px/pt, and its 328 pt free-text boxes are 2624 px wide, which this
    /// brings back to 2048 — still six pixels per point, three times what a 2× display shows at
    /// 100%. Beyond it the canvas's linear sampler stretches the glyph instead.
    static let maximumGlyphPixels = 2_048

    /// Pixels per point to rasterize a glyph at, for the current zoom and display.
    ///
    /// Rounded **up** to a power of two and capped, which is what keeps the texture cache small:
    /// a pinch from 100% to 800% walks through four entries rather than one per event, and each of
    /// them is at worst twice the pixels the display can show.
    static func scale(zoom: CGFloat, deviceScale: CGFloat) -> CGFloat {
        let wanted = max(zoom, 0.05) * max(deviceScale, 1)
        var scale: CGFloat = 1
        while scale < wanted && scale < 8 {
            scale *= 2
        }
        return scale
    }

    /// A sticky note's icon: a page with its top-right corner folded over, in the note's colour.
    ///
    /// Returns `nil` for a box with no area, which is the one case the caller has to decide about
    /// (`AnnotationSkipReason.EmptyRect`).
    ///
    /// `generation` is the caller's monotonic texture id. It must be different for every call: the
    /// canvas skips re-uploading a quad whose generation it has already seen, so two bitmaps that
    /// share one would leave the second drawn with the first's pixels — the same trap the page
    /// raster and the loaded annotations fell into.
    static func noteIcon(
        color: AnnotationColor,
        boxPt: CGSize,
        scale: CGFloat,
        generation: UInt64
    ) -> PageImage? {
        let size = pixelSize(boxPt, scale: scale)
        guard let (width, height) = size, let context = context(width: width, height: height)
        else { return nil }

        // The icon is square and centred in the box: a `/Text` annotation's `/Rect` is its icon
        // box and is square in every real file (20-26 pt in the review corpus), but a file that
        // wrote a wide box should still get a recognisable note rather than a stretched one.
        let side = min(CGFloat(width), CGFloat(height))
        let inset = side * 0.06
        let body = CGRect(
            x: (CGFloat(width) - side) / 2 + inset,
            y: (CGFloat(height) - side) / 2 + inset,
            width: side - 2 * inset,
            height: side - 2 * inset
        )
        drawNoteIcon(in: context, body: body, color: color, scale: scale)
        return finish(
            context,
            width: width,
            height: height,
            pointSize: boxPt,
            generation: generation
        )
    }

    /// A small comment label, tinted with the markup's colour and pointing toward its line.
    static func inlineComment(color: AnnotationColor, boxPt: CGSize, scale: CGFloat,
                              generation: UInt64) -> PageImage? {
        guard let (width, height) = pixelSize(boxPt, scale: scale),
              let context = context(width: width, height: height) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        let inset = max(1, scale * 0.5)
        let tip = w * 0.17
        let rect = CGRect(x: inset, y: inset, width: w - tip - inset * 2, height: h - inset * 2)
        let path = CGMutablePath()
        path.addRoundedRect(in: rect, cornerWidth: h * 0.15, cornerHeight: h * 0.15)
        path.move(to: CGPoint(x: rect.maxX - 1, y: h * 0.27))
        path.addLine(to: CGPoint(x: w - inset, y: h / 2))
        path.addLine(to: CGPoint(x: rect.maxX - 1, y: h * 0.73))
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(CGColor(srgbRed: CGFloat(color.red) / 255,
                                     green: CGFloat(color.green) / 255,
                                     blue: CGFloat(color.blue) / 255, alpha: 1))
        context.fillPath()
        context.setFillColor(CGColor(gray: 0.15, alpha: 0.65))
        let dot = h * 0.14
        for fraction: CGFloat in [0.28, 0.5, 0.72] {
            context.fillEllipse(in: CGRect(x: rect.minX + rect.width * fraction - dot / 2,
                                           y: h / 2 - dot / 2, width: dot, height: dot))
        }
        return finish(context, width: width, height: height, pointSize: boxPt, generation: generation)
    }

    /// A free-text annotation's text, laid out in its own rectangle.
    ///
    /// `alignment` is `/Q` as the reader reports it (`left`, `center`, `right`); the text is
    /// wrapped to the box, which is what a free-text annotation's own appearance stream does.
    static func freeText(
        _ text: String,
        color: AnnotationColor,
        fontSizePt: CGFloat,
        alignment: String,
        boxPt: CGSize,
        scale: CGFloat,
        generation: UInt64
    ) -> PageImage? {
        guard let (width, height) = pixelSize(boxPt, scale: scale),
              let context = context(width: width, height: height)
        else { return nil }

        // Only the size comes from the file; the face is the system's (see the type's comment).
        let size = max(fontSizePt, 1) * scale
        let font = NSFont.systemFont(ofSize: size)
        var quadding: CTTextAlignment = switch alignment {
        case "center": .center
        case "right": .right
        default: .left
        }
        let paragraph = withUnsafePointer(to: &quadding) { pointer in
            CTParagraphStyleCreate(
                [CTParagraphStyleSetting(
                    spec: .alignment,
                    valueSize: MemoryLayout<CTTextAlignment>.size,
                    value: pointer
                )],
                1
            )
        }
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor(
                    srgbRed: CGFloat(color.red) / 255,
                    green: CGFloat(color.green) / 255,
                    blue: CGFloat(color.blue) / 255,
                    alpha: CGFloat(color.alpha) / 255
                ),
                .paragraphStyle: paragraph,
            ]
        )

        // A hair of padding, so a descender or an accent is not clipped by the box: a real
        // free-text appearance stream has the same problem and solves it the same way.
        let padding = min(size * 0.12, CGFloat(min(width, height)) * 0.1)
        let frame = CGRect(
            x: padding,
            y: padding,
            width: max(CGFloat(width) - 2 * padding, 1),
            height: max(CGFloat(height) - 2 * padding, 1)
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let textFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            CGPath(rect: frame, transform: nil),
            nil
        )
        CTFrameDraw(textFrame, context)
        return finish(
            context,
            width: width,
            height: height,
            pointSize: boxPt,
            generation: generation
        )
    }

    // MARK: - Drawing

    /// The icon itself, in a bottom-left-origin context: a filled page, a folded corner, three
    /// ruled lines and an outline dark enough to read against a white page.
    private static func drawNoteIcon(
        in context: CGContext,
        body: CGRect,
        color: AnnotationColor,
        scale: CGFloat
    ) {
        let fill = nsColor(color)
        let shade = fill.blended(withFraction: 0.45, of: .white) ?? fill
        let ink = fill.blended(withFraction: 0.68, of: .black) ?? .black
        let fold = body.width * 0.32
        let radius = body.width * 0.08
        let stroke = max(1, body.width * 0.055)

        // The page outline, with the top-right corner cut off where the fold is. Drawn in a
        // bottom-left-origin context (CoreGraphics), so `maxY` is the top of the icon: the fold
        // is at the top-right of the picture the canvas shows.
        let page = CGMutablePath()
        page.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        page.addLine(to: CGPoint(x: body.maxX - fold, y: body.minY))
        page.addLine(to: CGPoint(x: body.maxX, y: body.minY + fold))
        page.addLine(to: CGPoint(x: body.maxX, y: body.maxY - radius))
        page.addQuadCurve(
            to: CGPoint(x: body.maxX - radius, y: body.maxY),
            control: CGPoint(x: body.maxX, y: body.maxY)
        )
        page.addLine(to: CGPoint(x: body.minX + radius, y: body.maxY))
        page.addQuadCurve(
            to: CGPoint(x: body.minX, y: body.maxY - radius),
            control: CGPoint(x: body.minX, y: body.maxY)
        )
        page.addLine(to: CGPoint(x: body.minX, y: body.minY + radius))
        page.addQuadCurve(
            to: CGPoint(x: body.minX + radius, y: body.minY),
            control: CGPoint(x: body.minX, y: body.minY)
        )
        page.closeSubpath()

        context.saveGState()
        context.addPath(page)
        context.setFillColor(fill.cgColor)
        context.fillPath()

        // The turned-over corner: the same triangle, in the lighter shade.
        let corner = CGMutablePath()
        corner.move(to: CGPoint(x: body.maxX - fold, y: body.minY))
        corner.addLine(to: CGPoint(x: body.maxX, y: body.minY + fold))
        corner.addLine(to: CGPoint(x: body.maxX - fold, y: body.minY + fold))
        corner.closeSubpath()
        context.addPath(corner)
        context.setFillColor(shade.cgColor)
        context.fillPath()

        // Ruled lines, the way every note icon has them: what makes the glyph readable as "text
        // on a page" at 20 pt rather than as a blank square.
        context.setStrokeColor(ink.cgColor)
        context.setLineWidth(max(stroke * 0.75, scale * 0.5))
        context.setLineCap(.round)
        let widths: [CGFloat] = [0.62, 0.62, 0.34]
        for (index, fraction) in widths.enumerated() {
            let y = body.maxY - fold - body.height * (0.18 + 0.19 * CGFloat(index))
            guard y > body.minY + body.height * 0.1 else { continue }
            context.move(to: CGPoint(x: body.minX + body.width * 0.17, y: y))
            context.addLine(
                to: CGPoint(x: body.minX + body.width * (0.17 + 0.66 * fraction), y: y)
            )
        }
        context.strokePath()

        // The outline goes on last so it also covers the fold's edges.
        context.addPath(page)
        context.setStrokeColor(ink.cgColor)
        context.setLineWidth(stroke)
        context.strokePath()
        context.restoreGState()
    }

    // MARK: - Bitmap plumbing

    /// `boxPt` at `scale`, in whole pixels, or `nil` when the box has no area.
    private static func pixelSize(_ boxPt: CGSize, scale: CGFloat) -> (Int, Int)? {
        guard boxPt.width > 0, boxPt.height > 0, boxPt.width.isFinite, boxPt.height.isFinite
        else { return nil }
        let wanted = CGSize(width: boxPt.width * scale, height: boxPt.height * scale)
        let longest = max(wanted.width, wanted.height)
        let shrink = longest > CGFloat(maximumGlyphPixels) ? CGFloat(maximumGlyphPixels) / longest : 1
        let width = max(1, Int((wanted.width * shrink).rounded()))
        let height = max(1, Int((wanted.height * shrink).rounded()))
        return (width, height)
    }

    /// A bitmap context in the byte order every texture in this engine is uploaded in: BGRA,
    /// little-endian, premultiplied while drawing (see `straightAlpha` for the conversion).
    private static func context(width: Int, height: Int) -> CGContext? {
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: info
        )
    }

    private static func finish(
        _ context: CGContext,
        width: Int,
        height: Int,
        pointSize: CGSize,
        generation: UInt64
    ) -> PageImage? {
        guard let data = context.data else { return nil }
        var bgra = Data(bytes: data, count: width * height * 4)
        straightAlpha(&bgra)
        return PageImage(
            pixelWidth: width,
            pixelHeight: height,
            pointSize: CGSize(
                width: pointSize.width,
                height: pointSize.height
            ),
            bgra: bgra,
            generation: generation
        )
    }

    /// Divides CoreGraphics' premultiplied bytes back out by their own alpha.
    ///
    /// `PageImage.bgra` is documented as premultiplied because that is what PDFium hands over, but
    /// the quad pipeline's alpha-over state is `src·a + dst·(1 − a)`, i.e. **straight** alpha;
    /// uploaded premultiplied, a translucent edge is darkened twice. The icon and the text are the
    /// first textures in this engine that are mostly transparent, which is why this exists here
    /// and not on the page path (a page raster is opaque, and `a = 255` is the identity).
    private static func straightAlpha(_ bgra: inout Data) {
        bgra.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for pixel in stride(from: 0, to: bytes.count - 3, by: 4) {
                let alpha = Int(bytes[pixel + 3])
                if alpha == 255 { continue }
                if alpha == 0 {
                    bytes[pixel] = 0
                    bytes[pixel + 1] = 0
                    bytes[pixel + 2] = 0
                    continue
                }
                for channel in 0..<3 {
                    let value = (Int(bytes[pixel + channel]) * 255 + alpha / 2) / alpha
                    bytes[pixel + channel] = UInt8(min(value, 255))
                }
            }
        }
    }

    private static func nsColor(_ color: AnnotationColor) -> NSColor {
        NSColor(
            srgbRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: CGFloat(color.alpha) / 255
        )
    }
}
