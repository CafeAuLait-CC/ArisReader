import AppKit
import LyraReaderKit
import Foundation
import PDFKit

extension ReaderChecks {
    /// T3.12 printing: page count, page ranges and rendered bitmaps, headlessly.
    ///
    /// `NSPrintOperation` itself would put a panel on screen, so the check drives the same
    /// `ReaderPrintView` the operation paginates: `knowsPageRange` supplies the document's page
    /// count, the print panel's page range is turned into zero-based pages by `selectedPages`,
    /// and `renderPageBitmap` runs the same `drawPage` a printer would receive into an offscreen
    /// context at 300 dpi. A one-page range and a five-page range of a 130-page document are
    /// both exercised; the cache assertion is the memory contract (only two page rasters at
    /// once, however long the range).
    @MainActor static func printingChecks(root: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-reader-printing-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let shortURL = root.appendingPathComponent("tests/fixtures/multipage.pdf")
        let longURL = root.appendingPathComponent("tests/fixtures/index-past-120.pdf")

        let engine = try RustEngine()
        let shortLoaded = try engine.openDocument(at: shortURL)
        require(shortLoaded.pageCount == 3, "the short print fixture has three pages")
        let textPage = try await engine.textPage(0)

        var annotations: [PrintAnnotation] = []
        let pageText = textPage.chars
        // A highlight over real text, and a deliberately wide ink stroke in a blank margin.
        annotations.append(PrintAnnotation(
            kind: .highlight,
            page: 0,
            start: 0,
            end: min(20, max(pageText.count - 1, 0)),
            color: AppState.highlightPalette[0].color
        ))
        let inkY = max(shortLoaded.firstPageSize.height - 120, 40)
        annotations.append(PrintAnnotation(
            kind: .ink,
            page: 0,
            color: AnnotationColor(red: 220, green: 20, blue: 30, alpha: 255),
            inkPaths: [[CGPoint(x: 40, y: inkY), CGPoint(x: 40, y: inkY + 80)]],
            strokeWidth: 8
        ))

        let shortView = ReaderPrintView(
            pageCount: shortLoaded.pageCount,
            pageSizePt: shortLoaded.firstPageSize,
            annotations: annotations,
            pageImage: { page, scale in
                engine.renderPageForPrint(page, scale: scale)
            },
            textPage: { page in page == 0 ? textPage : nil }
        )

        // ── The view supplies the page count the print panel needs ─────────────────────────
        var range = NSRange()
        require(shortView.knowsPageRange(&range), "the print view reports a page range")
        require(range.location == 1 && range.length == 3,
                "the page range is 1…3 in print terms ({\(range.location), \(range.length)})")
        require(shortView.pageCount == 3, "the view's page count matches the document")

        // ── One-page range ─────────────────────────────────────────────────────────────────
        let single = NSPrintInfo.shared.copy() as! NSPrintInfo
        single.dictionary()[NSPrintInfo.AttributeKey.allPages] = false
        single.dictionary()[NSPrintInfo.AttributeKey.firstPage] = 1
        single.dictionary()[NSPrintInfo.AttributeKey.lastPage] = 1
        single.dictionary()[NSPrintInfo.AttributeKey.copies] = 2
        require(shortView.selectedPages(from: single) == [0],
                "a one-page range selects exactly one page")
        let onePage = try requireUnwrap(
            shortView.renderPageBitmap(0), "the selected page renders a bitmap")
        let expectedWidth = Int((shortLoaded.firstPageSize.width * ReaderPrintView.printDPI / 72).rounded())
        require(abs(onePage.pixelsWide - expectedWidth) <= 2,
                "the printed page is at 300 dpi (\(onePage.pixelsWide) px wide, expected \(expectedWidth))")
        require(onePage.pixelsHigh > 0, "the printed page has height")
        var nonWhite = 0
        if let data = onePage.bitmapData {
            let bytesPerRow = onePage.bytesPerRow
            for topY in stride(from: 0, to: onePage.pixelsHigh, by: 17) {
                let y = onePage.pixelsHigh - 1 - topY
                for x in stride(from: 0, to: onePage.pixelsWide, by: 17) {
                    let offset = y * bytesPerRow + x * 4
                    if data[offset] < 250 || data[offset + 1] < 250 || data[offset + 2] < 250 {
                        nonWhite += 1
                    }
                }
            }
        }
        require(nonWhite > 20, "the printed page has visible content (\(nonWhite) samples)")

        var redCount = 0
        var redBounds = (minX: Int.max, maxX: Int.min, minY: Int.max, maxY: Int.min)
        if let data = onePage.bitmapData {
            let row = onePage.bytesPerRow
            for topY in 0..<onePage.pixelsHigh {
                let y = onePage.pixelsHigh - 1 - topY
                for x in 0..<onePage.pixelsWide {
                    let offset = y * row + x * 4
                    if data[offset] > 170 && data[offset + 1] < 90 && data[offset + 2] < 90 {
                        redCount += 1
                        redBounds.minX = min(redBounds.minX, x)
                        redBounds.maxX = max(redBounds.maxX, x)
                        redBounds.minY = min(redBounds.minY, topY)
                        redBounds.maxY = max(redBounds.maxY, topY)
                    }
                }
            }
        }
        let highlightBoxes = textPage.selectionRects(in: 0...min(20, max(pageText.count - 1, 0)))
        if let box = highlightBoxes.first {
            let highlightPixel = printPixel(
                onePage, atPagePoint: CGPoint(x: box.maxX - 1, y: box.minY + 1))
            require(highlightPixel.2 < 245,
                    "the reader's highlight is tinted into the printed bitmap (\(highlightPixel))")
        } else {
            require(false, "the highlight range has printed geometry")
        }

        let inkPixel = printPixel(onePage, atPagePoint: CGPoint(x: 40, y: inkY + 40))
        require(redCount > 100,
                "the reader's ink annotation is in the printed bitmap (\(inkPixel), red pixels \(redCount))")
        require(redBounds.minX < Int(40.0 * CGFloat(onePage.pixelsWide) / 595.0) + 40,
                "the printed ink is at the page position it was drawn at (x \(redBounds.minX))")

        // ── Five-page range of a 130-page document ────────────────────────────────────────
        let longEngine = try RustEngine()
        let longLoaded = try longEngine.openDocument(at: longURL)
        require(longLoaded.pageCount == 130, "the long print fixture has 130 pages")
        let longView = ReaderPrintView(
            pageCount: longLoaded.pageCount,
            pageSizePt: longLoaded.firstPageSize,
            pageImage: { page, scale in
                longEngine.renderPageForPrint(page, scale: scale)
            }
        )
        var longRange = NSRange()
        require(longView.knowsPageRange(&longRange), "the long document reports a page range")
        require(longRange.length == 130, "the long document's page count reaches the print view")
        let many = NSPrintInfo.shared.copy() as! NSPrintInfo
        many.dictionary()[NSPrintInfo.AttributeKey.allPages] = false
        many.dictionary()[NSPrintInfo.AttributeKey.firstPage] = 10
        many.dictionary()[NSPrintInfo.AttributeKey.lastPage] = 14
        many.dictionary()[NSPrintInfo.AttributeKey.copies] = 3
        let selected = longView.selectedPages(from: many)
        require(selected == [9, 10, 11, 12, 13],
                "a five-page range selects exactly five pages (\(selected))")

        var rendered = 0
        for page in selected {
            let bitmap = try requireUnwrap(
                longView.renderPageBitmap(page), "page \(page + 1) renders for printing")
            require(bitmap.pixelsWide > 100 && bitmap.pixelsHigh > 100,
                    "page \(page + 1) printed at print resolution")
            require(longView.cachedPageCount <= ReaderPrintView.maximumCachedPages,
                    "printing a long range never caches more than \(ReaderPrintView.maximumCachedPages) pages")
            rendered += 1
        }
        require(rendered == 5, "the five-page range produced five bitmaps")
        require(longView.renderedPages == selected,
                "the rendered pages are exactly the selected pages, in order")

        // ── A real NSPrintOperation, saved to PDF instead of a printer ────────────────────
        // The print panel's page range is what `NSPrintSaveJob` honours; running the operation
        // headlessly proves that the view's pagination and `draw` produce the selected pages,
        // not merely that `selectedPages` does the arithmetic.
        func savedJob(firstPage: Int, lastPage: Int, name: String) throws -> URL {
            let savedURL = scratch.appendingPathComponent(name)
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.paperSize = longLoaded.firstPageSize
            info.topMargin = 0
            info.bottomMargin = 0
            info.leftMargin = 0
            info.rightMargin = 0
            info.horizontalPagination = .fit
            info.verticalPagination = .fit
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = savedURL
            info.dictionary()[NSPrintInfo.AttributeKey.allPages] = false
            info.dictionary()[NSPrintInfo.AttributeKey.firstPage] = firstPage
            info.dictionary()[NSPrintInfo.AttributeKey.lastPage] = lastPage
            info.dictionary()[NSPrintInfo.AttributeKey.copies] = 1
            let view = ReaderPrintView(
                pageCount: longLoaded.pageCount,
                pageSizePt: longLoaded.firstPageSize,
                pageImage: { page, scale in
                    longEngine.renderPageForPrint(page, scale: scale)
                }
            )
            let operation = NSPrintOperation(view: view, printInfo: info)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            require(operation.run(), "the headless print operation ran (\(name))")
            return savedURL
        }

        let manyJob = try savedJob(firstPage: 10, lastPage: 12, name: "many-pages.pdf")
        let manyDocument = PDFDocument(url: manyJob)
        require(manyDocument?.pageCount == 3,
                "a three-page print range produces a three-page job (\(manyDocument?.pageCount ?? -1))")
        if let manyDocument, manyDocument.pageCount == 3 {
            func signature(_ index: Int) -> Data? {
                manyDocument.page(at: index)?.thumbnail(
                    of: NSSize(width: 120, height: 170), for: .mediaBox).tiffRepresentation
            }
            let first = signature(0)
            let second = signature(1)
            let third = signature(2)
            require(first != nil && second != nil && third != nil,
                    "every page of the print job has a rendered page")
            require(first != second && second != third && first != third,
                    "the print range printed three different pages, not one page three times")
        }
        let oneJob = try savedJob(firstPage: 2, lastPage: 2, name: "one-page.pdf")
        let oneDocument = PDFDocument(url: oneJob)
        require(oneDocument?.pageCount == 1,
                "a one-page print range produces a one-page job (\(oneDocument?.pageCount ?? -1))")

        // ── The print panel's attributes reach the operation ──────────────────────────────
        let operation = NSPrintOperation(view: longView, printInfo: many)
        require((operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.copies] as? NSNumber)?.intValue == 3,
                "the operation carries the print panel's copies attribute")
        require((many.dictionary()[NSPrintInfo.AttributeKey.firstPage] as? NSNumber)?.intValue == 10,
                "the print panel's first page is carried")

        print("Printing checks passed")
    }

    /// One pixel of an `NSBitmapImageRep`, using page-local top-left points.
    @MainActor static func printPixel(
        _ bitmap: NSBitmapImageRep,
        atPagePoint point: CGPoint
    ) -> (UInt8, UInt8, UInt8) {
        let scale = CGFloat(bitmap.pixelsWide) / max(CGFloat(bitmap.size.width), 1)
        let x = min(max(Int(point.x * scale), 0), bitmap.pixelsWide - 1)
        let y = min(max(Int(point.y * scale), 0), bitmap.pixelsHigh - 1)
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
            return (0, 0, 0)
        }
        return (
            UInt8(min(max(color.redComponent * 255, 0), 255)),
            UInt8(min(max(color.greenComponent * 255, 0), 255)),
            UInt8(min(max(color.blueComponent * 255, 0), 255))
        )
    }
}
