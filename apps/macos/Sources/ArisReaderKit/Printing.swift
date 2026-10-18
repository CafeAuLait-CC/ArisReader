import AppKit
import CoreGraphics

/// One mark the reader added, snapshotted for printing.
///
/// This is deliberately a value: a print job runs while the reader may keep editing, and the
/// sheet that comes out must be the document as it was when Print was chosen. The fields mirror
/// `AppState.Annotation`; only the fields the renderer needs are copied.
public struct PrintAnnotation: Sendable {
    public let kind: AppState.Annotation.Kind
    public let page: Int
    /// Character range for the three text-markup kinds.
    public let start: Int
    public let end: Int
    public let color: AnnotationColor
    public let note: String
    public let inkPaths: [[CGPoint]]
    public let shapeRect: CGRect?
    public let lineStart: CGPoint?
    public let lineEnd: CGPoint?
    public let strokeWidth: CGFloat
    public let fontSize: CGFloat

    public init(
        kind: AppState.Annotation.Kind,
        page: Int,
        start: Int = 0,
        end: Int = 0,
        color: AnnotationColor,
        note: String = "",
        inkPaths: [[CGPoint]] = [],
        shapeRect: CGRect? = nil,
        lineStart: CGPoint? = nil,
        lineEnd: CGPoint? = nil,
        strokeWidth: CGFloat = 0,
        fontSize: CGFloat = 0
    ) {
        self.kind = kind
        self.page = page
        self.start = start
        self.end = end
        self.color = color
        self.note = note
        self.inkPaths = inkPaths
        self.shapeRect = shapeRect
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.strokeWidth = strokeWidth
        self.fontSize = fontSize
    }

    public init(_ annotation: AppState.Annotation) {
        self.init(
            kind: annotation.kind,
            page: annotation.page,
            start: annotation.start,
            end: annotation.end,
            color: annotation.color,
            note: annotation.note,
            inkPaths: annotation.inkPaths,
            shapeRect: annotation.shapeRect,
            lineStart: annotation.lineStart,
            lineEnd: annotation.lineEnd,
            strokeWidth: annotation.strokeWidth,
            fontSize: annotation.fontSize
        )
    }
}

/// The view `NSPrintOperation` paginates: one page of the document per printed page.
///
/// # Resolution
///
/// Each page is rasterised at [`printDPI`] (300 dpi) and drawn into the page's point rectangle.
/// The print system then maps that to the printer's own resolution; the screen scale is never
/// involved. A page rendered at 2× for a Retina screen is 144 dpi; this is more than twice that.
///
/// # Memory
///
/// Only the page being drawn (and one recently drawn page, so a repeated dirty rect is cheap) is
/// held. A 900-page document never loads 900 rasters: [`cachedPageCount`] is at most
/// [`maximumCachedPages`] however many pages are printed. The page range and the copy count come
/// from the print panel (`NSPrintInfo`'s `firstPage` / `lastPage` / `copies` attributes); this
/// view supplies the total page count through `knowsPageRange`, which is what lets the panel show
/// a page range at all.
///
/// # Annotations
///
/// The page raster is requested with the PDF's own annotations burned in (the same path the
/// sidebar thumbnail uses), and the reader's own marks are drawn on top in page coordinates with
/// the same colours, line widths and multiply-blended text marks the canvas shows. Highlights are
/// drawn from the selected character rectangles, so the printed mark covers exactly the text the
/// reader selected, at print resolution.
@MainActor
public final class ReaderPrintView: NSView {
    /// 300 dpi: print resolution, not screen resolution.
    public static let printDPI: CGFloat = 300

    /// A page raster is large (a Letter page at 300 dpi is ~24 MB); keep only the page in the
    /// press and the one just drawn.
    public static let maximumCachedPages = 2

    public let pageCount: Int
    public let pageSizePt: CGSize
    private let annotations: [PrintAnnotation]
    private let pageImage: (Int, CGFloat) -> PageImage?
    private let textPage: (Int) -> TextPage?

    private var cache: [Int: CGImage] = [:]
    private var cacheOrder: [Int] = []
    /// The pages whose rasters were actually produced, in order, for the headless check.
    public private(set) var renderedPages: [Int] = []
    /// The pages the last print panel asked for, in order.
    public private(set) var printedPages: [Int] = []

    public init(
        pageCount: Int,
        pageSizePt: CGSize,
        annotations: [PrintAnnotation] = [],
        pageImage: @escaping (Int, CGFloat) -> PageImage?,
        textPage: @escaping (Int) -> TextPage? = { _ in nil }
    ) {
        self.pageCount = max(pageCount, 1)
        self.pageSizePt = pageSizePt.width > 1 && pageSizePt.height > 1
            ? pageSizePt
            : CGSize(width: 612, height: 792)
        self.annotations = annotations
        self.pageImage = pageImage
        self.textPage = textPage
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: self.pageSizePt.width,
            height: self.pageSizePt.height * CGFloat(self.pageCount)
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("ReaderPrintView is programmatic") }

    public override var isFlipped: Bool { false }

    /// What AppKit asks before showing the page range control. One-based, as `NSRange` expects.
    public override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: pageCount)
        return true
    }

    public override func rectForPage(_ page: Int) -> NSRect {
        NSRect(
            x: 0,
            y: CGFloat(page - 1) * pageSizePt.height,
            width: pageSizePt.width,
            height: pageSizePt.height
        )
    }

    /// The pages the print panel selected, as zero-based indices.
    ///
    /// `NSPrintInfo` stores the panel's choice in its dictionary (`NSPrintFirstPage`,
    /// `NSPrintLastPage`, `NSPrintAllPages`); the operation's `pageRange` is derived from it and
    /// is what AppKit uses to call `rectForPage` for selected pages only.
    public func selectedPages(from info: NSPrintInfo) -> [Int] {
        let dictionary = info.dictionary()
        let allPages = (dictionary[NSPrintInfo.AttributeKey.allPages] as? NSNumber)?.boolValue
            ?? true
        guard !allPages else { return Array(0..<pageCount) }
        let first = (dictionary[NSPrintInfo.AttributeKey.firstPage] as? NSNumber)?.intValue ?? 1
        let last = (dictionary[NSPrintInfo.AttributeKey.lastPage] as? NSNumber)?.intValue
            ?? pageCount
        let low = min(max(first, 1), pageCount)
        let high = min(max(last, low), pageCount)
        return Array((low - 1)..<high)
    }

    /// How many page rasters are alive right now. Never more than
    /// [`maximumCachedPages`], whatever the range.
    public var cachedPageCount: Int { cache.count }

    public override func draw(_ dirtyRect: NSRect) {
        let height = pageSizePt.height
        guard height > 0 else { return }
        let first = max(0, Int(floor(dirtyRect.minY / height)))
        let last = min(pageCount - 1, Int(floor((dirtyRect.maxY - 0.01) / height)))
        guard first <= last else { return }
        for page in first...last {
            let rect = CGRect(
                x: 0,
                y: CGFloat(page) * height,
                width: pageSizePt.width,
                height: height
            )
            if !printedPages.contains(page) { printedPages.append(page) }
            drawPage(page, in: rect)
        }
    }

    /// Renders one page to an `NSBitmapImageRep` at print resolution, for the headless check.
    ///
    /// This is the same `drawPage` the print operation calls, into an offscreen context, so the
    /// bitmap the check inspects is the bitmap the printer receives (before the print system's
    /// own scaling).
    public func renderPageBitmap(_ page: Int) -> NSBitmapImageRep? {
        guard page >= 0, page < pageCount else { return nil }
        let scale = Self.printDPI / 72.0
        let width = max(1, Int((pageSizePt.width * scale).rounded()))
        let height = max(1, Int((pageSizePt.height * scale).rounded()))
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        representation.size = NSSize(width: pageSizePt.width, height: pageSizePt.height)
        guard let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // `NSGraphicsContext(bitmapImageRep:)` already maps the rep's point size to its pixel
        // size (300/72 here), so drawing in page points is already at print resolution. Scaling
        // again would draw a quarter of the page off the bitmap.
        drawPage(page, in: CGRect(origin: .zero, size: pageSizePt))
        NSGraphicsContext.restoreGraphicsState()
        return representation
    }

    // MARK: - Drawing

    private func drawPage(_ page: Int, in rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // Page space is top-left in this app; printing is bottom-left. Flip once around the page
        // rectangle, then all page-local geometry can be used as stored.
        context.translateBy(x: rect.minX, y: rect.minY + rect.height)
        context.scaleBy(x: 1, y: -1)

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: rect.size))

        if let image = pageImageForPrint(page) {
            // CGImage draws in an unflipped coordinate space; flip locally so it comes out
            // upright inside the already-flipped page context.
            context.saveGState()
            context.translateBy(x: 0, y: rect.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        } else {
            drawMissingPage(page, in: CGRect(origin: .zero, size: rect.size), context: context)
        }

        for annotation in annotations where annotation.page == page {
            draw(annotation, in: rect, context: context)
        }
        context.restoreGState()
    }

    private func pageImageForPrint(_ page: Int) -> CGImage? {
        if let cached = cache[page] {
            cacheOrder.removeAll { $0 == page }
            cacheOrder.append(page)
            return cached
        }
        let scale = Self.printDPI / 72.0
        guard let image = pageImage(page, scale) else { return nil }
        let cgImage = image.makeCGImage()
        cache[page] = cgImage
        cacheOrder.append(page)
        renderedPages.append(page)
        while cacheOrder.count > Self.maximumCachedPages {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        return cgImage
    }

    private func drawMissingPage(_ page: Int, in rect: CGRect, context: CGContext) {
        let message = "Page \(page + 1) could not be rendered"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = (message as NSString).size(withAttributes: attributes)
        let point = CGPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2)
        // The page is already flipped top-left; the string draw expects bottom-left.
        context.saveGState()
        context.translateBy(x: 0, y: rect.height)
        context.scaleBy(x: 1, y: -1)
        (message as NSString).draw(at: point, withAttributes: attributes)
        context.restoreGState()
    }

    private func draw(_ annotation: PrintAnnotation, in rect: CGRect, context: CGContext) {
        let color = NSColor(
            srgbRed: CGFloat(annotation.color.red) / 255,
            green: CGFloat(annotation.color.green) / 255,
            blue: CGFloat(annotation.color.blue) / 255,
            alpha: CGFloat(annotation.color.alpha) / 255
        )
        switch annotation.kind {
        case .highlight, .underline, .strikeout:
            guard let text = textPage(annotation.page) else { return }
            let range = annotation.start...max(annotation.start, annotation.end)
            let boxes = text.selectionRects(in: range)
            guard !boxes.isEmpty else { return }
            context.saveGState()
            // Highlights are multiplied into the page on screen; the same blend here is what
            // keeps printed text readable under the tint.
            context.setBlendMode(annotation.kind == .highlight ? .multiply : .normal)
            for box in boxes {
                switch annotation.kind {
                case .highlight:
                    context.setFillColor(color.cgColor)
                    context.fill(box)
                case .underline:
                    context.setFillColor(color.cgColor)
                    context.fill(CGRect(x: box.minX, y: box.minY + box.height * 0.85,
                                        width: box.width, height: max(box.height * 0.12, 0.5)))
                case .strikeout:
                    context.setFillColor(color.cgColor)
                    context.fill(CGRect(x: box.minX, y: box.minY + box.height * 0.45,
                                        width: box.width, height: max(box.height * 0.12, 0.5)))
                default:
                    break
                }
            }
            context.restoreGState()
        case .ink, .square, .circle, .line, .arrow:
            let mark = CanvasAnnotationMark(
                id: "print",
                page: annotation.page,
                kind: annotation.kind,
                inkPaths: annotation.inkPaths,
                shapeRect: annotation.shapeRect,
                lineStart: annotation.lineStart,
                lineEnd: annotation.lineEnd,
                color: annotation.color,
                strokeWidth: annotation.strokeWidth,
                isSelected: false,
                isEditable: false
            )
            let path = AnnotationGeometry.path(for: mark)
            guard !path.isEmpty else { return }
            context.saveGState()
            context.setStrokeColor(color.withAlphaComponent(1).cgColor)
            context.setFillColor(color.withAlphaComponent(1).cgColor)
            context.setLineWidth(max(annotation.strokeWidth, 0.5))
            context.setLineJoin(.round)
            context.setLineCap(.round)
            context.addPath(path)
            // Ink is stroked; shapes are outlines; the arrowhead is filled too.
            context.strokePath()
            if annotation.kind == .arrow {
                context.addPath(path)
                context.fillPath()
            }
            context.restoreGState()
        case .stickyNote:
            guard let box = annotation.shapeRect else { return }
            let path = CGPath(
                roundedRect: box,
                cornerWidth: min(4, box.width / 4),
                cornerHeight: min(4, box.height / 4),
                transform: nil
            )
            context.saveGState()
            context.setFillColor(color.withAlphaComponent(1).cgColor)
            context.addPath(path)
            context.fillPath()
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.25).cgColor)
            context.setLineWidth(0.5)
            context.addPath(path)
            context.strokePath()
            context.restoreGState()
            drawNoteIcon(in: box)
        case .textBox:
            guard let box = annotation.shapeRect else { return }
            context.saveGState()
            context.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
            context.fill(box)
            context.setStrokeColor(color.withAlphaComponent(1).cgColor)
            context.setLineWidth(0.5)
            context.stroke(box)
            context.restoreGState()
            drawNoteText(annotation.note, in: box.insetBy(dx: 3, dy: 3),
                         fontSize: max(annotation.fontSize, 6), color: .black, context: context)
        }
    }

    /// The sticky-note icon the canvas shows, drawn white inside the note's colour.
    private func drawNoteIcon(in box: CGRect) {
        let inset = min(box.width, box.height) * 0.18
        let iconBox = box.insetBy(dx: inset, dy: inset)
        guard iconBox.width > 2, iconBox.height > 2,
              let symbol = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Note")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white]))
        else { return }
        symbol.draw(
            in: iconBox,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    private func drawNoteText(
        _ text: String,
        in box: CGRect,
        fontSize: CGFloat,
        color: NSColor,
        context: CGContext
    ) {
        guard !text.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        context.saveGState()
        // Flip locally for NSString drawing (bottom-left origin).
        context.translateBy(x: 0, y: box.maxY)
        context.scaleBy(x: 1, y: -1)
        (text as NSString).draw(
            in: CGRect(x: box.minX, y: 0, width: box.width, height: box.height),
            withAttributes: attributes
        )
        context.restoreGState()
    }
}

private extension PageImage {
    /// A `CGImage` over the BGRA buffer the engine produced.
    func makeCGImage() -> CGImage? {
        guard pixelWidth > 0, pixelHeight > 0,
              bgra.count >= pixelWidth * pixelHeight * 4 else { return nil }
        let data = bgra as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
            .union(.byteOrder32Little)
        return CGImage(
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
