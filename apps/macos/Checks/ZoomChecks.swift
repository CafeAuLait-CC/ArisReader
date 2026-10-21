import AppKit
import LyraReaderKit
import Foundation

/// A deterministic page geometry for the zoom checks.
///
/// The real fixtures are A4; the acceptance measurement also names a US Letter page, and the
/// formula should be exercised at exact page sizes rather than inferred from a raster. This
/// engine only provides layout and cheap images; the zoom arithmetic never looks at a bitmap.
@MainActor private final class ZoomPageEngine: PreviewEngine {
    let pageSize: CGSize
    let pageCount: Int
    var tileRequests = 0

    init(pageSize: CGSize, pageCount: Int) {
        self.pageSize = pageSize
        self.pageCount = pageCount
        super.init()
    }

    override func openDocument(at url: URL) throws -> LoadedDocument {
        LoadedDocument(title: "Zoom fixture", pageCount: pageCount, url: url,
                       firstPageSize: pageSize)
    }

    override func renderPage(_ page: Int, scale: CGFloat) async throws -> PageImage {
        let width = max(1, Int(ceil(pageSize.width * scale)))
        let height = max(1, Int(ceil(pageSize.height * scale)))
        return PageImage(
            pixelWidth: width, pixelHeight: height, pointSize: pageSize,
            bgra: Data(repeating: 255, count: width * height * 4),
            generation: UInt64(page + 1))
    }

    override func rasterizeTile(page: Int, lod: UInt8, tileX: Int, tileY: Int,
                                tileSize: Int) async throws -> TileImage {
        tileRequests += 1
        throw NSError(domain: "ZoomChecks", code: 1)
    }

    override func contentHeightPt(gapPt: CGFloat) -> CGFloat {
        CGFloat(pageCount) * pageSize.height + CGFloat(max(0, pageCount - 1)) * gapPt
    }

    override func contentWidthPt(gapPt: CGFloat) -> CGFloat { pageSize.width }

    override func pageTopPt(_ index: Int, gapPt: CGFloat) -> CGFloat {
        CGFloat(max(0, index)) * (pageSize.height + gapPt)
    }

    override func pageIndex(atScrollYPt y: CGFloat, gapPt: CGFloat) -> Int {
        let stride = pageSize.height + gapPt
        guard stride > 0 else { return 0 }
        return min(pageCount - 1, max(0, Int(floor(y / stride))))
    }

    override func visiblePages(scrollYPt: CGFloat, viewportHeightPt: CGFloat,
                               gapPt: CGFloat, marginPt: CGFloat) -> [PagePlacement] {
        let stride = pageSize.height + gapPt
        return (0..<pageCount).compactMap { index in
            let top = CGFloat(index) * stride
            guard top + pageSize.height >= scrollYPt - marginPt,
                  top <= scrollYPt + viewportHeightPt + marginPt
            else { return nil }
            return PagePlacement(index: index, topPt: top, leftPt: 0,
                                 widthPt: pageSize.width, heightPt: pageSize.height)
        }
    }
}

extension ReaderChecks {
    /// The calibration formula, independent of any attached display.
    @MainActor private static func displayCalibrationFormulaChecks() {
        // Three synthetic screens, chosen to span logical densities above and below 72 dpi.
        // (1202 × 842pt A4 is not used here; the formula only needs width, physical width and
        // the backing scale of the drawing surface.)
        let displays: [(name: String, logicalWidthPt: CGFloat, physicalWidthMm: CGFloat,
                        backing: CGFloat)] = [
            ("5K 27-inch (2560 pt wide, 599.29953 mm)",
             2560, 599.29953, 2),
            ("scaled 24-inch (1440 pt wide, 24 inches)",
             1440, 609.6, 2),
            ("14-inch laptop (1512 pt wide, 302.6 mm)",
             1512, 302.6, 2),
        ]
        for display in displays {
            let inches = display.physicalWidthMm / 25.4
            let expectedPPI = display.logicalWidthPt / inches
            let expectedFactor = expectedPPI / 72
            let calibration = DisplayCalibration.resolve(
                logicalWidthPt: display.logicalWidthPt,
                physicalWidthMm: display.physicalWidthMm)
            require(calibration.fallbackReason == nil,
                    "\(display.name) has a usable physical description")
            require(abs(calibration.factor - expectedFactor) < 1e-9,
                    "\(display.name): factor = (W / D) / 72 = \(expectedFactor), got \(calibration.factor)")
            require(abs((calibration.logicalPPI ?? 0) - expectedPPI) < 1e-9,
                    "\(display.name): logical ppi is \(expectedPPI)")
            // 100% of the calibrated scale must put a Letter page at its physical width in
            // device pixels. Compute it through the renderer's own geometry function.
            let letterWidthPx = CanvasGeometry.pageRectInDevicePixels(
                pageTopPt: 0, pageLeftPt: 0, widthPt: 612, heightPt: 792,
                scrollYPt: 0, zoom: calibration.factor, backingScale: display.backing,
                contentOffsetXPx: 0).width
            let expectedLetterWidthPx = 612 * expectedFactor * display.backing
            require(abs(letterWidthPx - expectedLetterWidthPx) / expectedLetterWidthPx < 0.01,
                    "\(display.name): Letter at 100% is \(letterWidthPx) px, formula says "
                        + "\(expectedLetterWidthPx) px")
        }

        // Displays whose description cannot be trusted fall back to the uncalibrated 72 dpi
        // convention rather than dividing by zero or producing a wild zoom.
        let unusable: [(name: String, widthPt: CGFloat, widthMm: CGFloat)] = [
            ("no physical width", 2560, 0),
            ("zero logical width", 0, 599.3),
            ("physically tiny", 2560, 5),
            ("physically enormous", 2560, 10_000),
            ("not-a-number width", 2560, .nan),
            ("absurd density", 100_000, 100),
        ]
        for display in unusable {
            let calibration = DisplayCalibration.resolve(
                logicalWidthPt: display.widthPt, physicalWidthMm: display.widthMm)
            require(calibration.factor == 1,
                    "\(display.name): falls back to factor 1, got \(calibration.factor)")
            require(calibration.fallbackReason != nil,
                    "\(display.name): the fallback is explained, not silent")
        }
    }

    /// 100% must produce the measured formula result on the machine and on known synthetic
    /// screens: `pageWidthPt × calibration × backingScale` device pixels.
    @MainActor private static func actualSizeChecks(url: URL) throws {
        let fiveK = DisplayCalibration.resolve(logicalWidthPt: 2560, physicalWidthMm: 599.29953)
        let letter = ZoomPageEngine(pageSize: CGSize(width: 612, height: 792), pageCount: 1)
        let letterState = AppState(engine: letter, tileCacheBudgetBytes: 48 * 1024 * 1024,
                                   preferFullPageRasters: false)
        letterState.setViewportSize(CGSize(width: 900, height: 700))
        letterState.setDeviceScale(2)
        letterState.setDisplayCalibration(fiveK)
        require(letterState.open(url: url), "the Letter zoom fixture opens")
        letterState.zoomActual()
        require(letterState.zoomPercent == 100, "Actual Size sets the percentage to exactly 100")
        require(abs(letterState.zoomFactor - fiveK.factor) < 1e-9,
                "Actual Size at 100% uses the calibrated factor \(fiveK.factor), not 1.0")
        guard let letterPlacement = letterState.canvasPageFrames.first(where: { $0.index == 0 }) else {
            require(false, "the Letter page has a placement")
            return
        }
        let letterQuad = CanvasGeometry.pageRectInDevicePixels(
            pageTopPt: letterPlacement.topPt,
            pageLeftPt: letterPlacement.leftPt,
            widthPt: letterPlacement.widthPt,
            heightPt: letterPlacement.heightPt,
            scrollYPt: letterState.scrollYPt,
            zoom: letterState.zoomFactor,
            backingScale: 2,
            contentOffsetXPx: 0)
        let letterFormula = 612 * fiveK.factor * 2
        require(abs(letterQuad.width - letterFormula) / letterFormula < 0.001,
                "Letter at Actual Size is \(letterQuad.width) px, formula says \(letterFormula) px")
        require(letterQuad.width > 612 * 2,
                "Actual Size is larger than the old 72 dpi logical-point convention (calibration is applied once)")

        let a4 = ZoomPageEngine(
            pageSize: CGSize(width: 595.276, height: 841.89), pageCount: 1)
        let a4State = AppState(engine: a4, tileCacheBudgetBytes: 48 * 1024 * 1024,
                               preferFullPageRasters: false)
        a4State.setViewportSize(CGSize(width: 900, height: 700))
        a4State.setDeviceScale(2)
        a4State.setDisplayCalibration(fiveK)
        require(a4State.open(url: url), "the A4 zoom fixture opens")
        a4State.zoomActual()
        guard let a4Placement = a4State.canvasPageFrames.first(where: { $0.index == 0 }) else {
            require(false, "the A4 page has a placement")
            return
        }
        let a4Quad = CanvasGeometry.pageRectInDevicePixels(
            pageTopPt: a4Placement.topPt, pageLeftPt: a4Placement.leftPt,
            widthPt: a4Placement.widthPt, heightPt: a4Placement.heightPt,
            scrollYPt: a4State.scrollYPt, zoom: a4State.zoomFactor, backingScale: 2,
            contentOffsetXPx: 0)
        let a4Formula = 595.276 * fiveK.factor * 2
        require(abs(a4Quad.width - a4Formula) / a4Formula < 0.001,
                "A4 at Actual Size is \(a4Quad.width) px, formula says \(a4Formula) px")

        // The screenshot measurement on the machine this was written on: 1845 physical pixels
        // for a Letter page in a 5120-wide capture. It is a **sanity band**, not the definition:
        // a capture carries error, and the formula above is what the code and the checks use.
        if let screen = NSScreen.main, abs(screen.frame.width - 2560) < 1,
           abs(screen.backingScaleFactor - 2) < 0.01 {
            let deviation = abs(letterQuad.width - 1845) / 1845
            require(deviation < 0.05,
                    "sanity only (±5%): the observed 1845 px Letter width on this 5K screen; "
                        + "the check computed \(letterQuad.width) px (this band is not the definition)")
        }

        // This machine's real display, read through the same path the app uses.
        if let screen = NSScreen.main {
            let real = DisplayCalibration.forScreen(screen)
            if real.fallbackReason == nil, let widthMm = real.physicalWidthMm {
                let expected = (screen.frame.width / (widthMm / 25.4)) / 72
                require(abs(real.factor - expected) < 1e-9,
                        "the attached display's factor is its measured (W / D) / 72: "
                            + "\(real.factor) vs \(expected)")
                let realState = AppState(engine: ZoomPageEngine(
                    pageSize: CGSize(width: 612, height: 792), pageCount: 1),
                    tileCacheBudgetBytes: 48 * 1024 * 1024, preferFullPageRasters: false)
                realState.setViewportSize(CGSize(width: 900, height: 700))
                realState.setDeviceScale(screen.backingScaleFactor)
                realState.setDisplayCalibration(real)
                realState.open(url: url)
                realState.zoomActual()
                let expectedPx = 612 * real.factor * screen.backingScaleFactor
                require(abs(612 * realState.zoomFactor * screen.backingScaleFactor - expectedPx)
                            / expectedPx < 0.01,
                        "on the attached display, Actual Size computes the formula width "
                            + "(\(expectedPx) px)")
            }
        }
    }

    /// Fit Width fills the viewport's width, leaves the stated inset, keeps the current page and
    /// is idempotent. Fit Page does the same for the page height and centres neither edge.
    @MainActor private static func fitPresetChecks(url: URL, calibration: DisplayCalibration) {
        let inset = AppState.zoomPresetInsetPt
        let viewport = CGSize(width: 900, height: 700)
        let engine = ZoomPageEngine(pageSize: CGSize(width: 612, height: 792), pageCount: 4)
        let state = AppState(engine: engine, tileCacheBudgetBytes: 48 * 1024 * 1024,
                             preferFullPageRasters: false)
        state.setViewportSize(viewport)
        state.setDeviceScale(2)
        state.setDisplayCalibration(calibration)
        require(state.open(url: url), "the fit-preset fixture opens")
        state.gotoPage(1)
        require(state.currentPage == 2, "the fit preset starts on page 2")

        state.zoomFitWidth()
        let availableWidth = viewport.width - 2 * inset
        let fittedWidth = 612 * state.zoomFactor
        require(fittedWidth <= availableWidth + 0.5,
                "Fit Width does not overflow the viewport (page \(fittedWidth) pt of "
                    + "\(availableWidth) pt available)")
        require(fittedWidth >= availableWidth * 0.99,
                "Fit Width fills the available width within 1% (\(fittedWidth) of \(availableWidth))")
        require(state.statusMessage.contains("Fit width · \(state.zoomPercent)%"),
                "the status line shows the percentage Fit Width produced "
                    + "(\(state.statusMessage))")
        require(state.contentHeightPt * state.zoomFactor > viewport.height,
                "Fit Width leaves the document vertically scrollable")
        require(state.currentPage == 2, "Fit Width keeps the current page")
        let widthPercent = state.zoomPercent
        let widthScroll = state.scrollYPt
        state.zoomFitWidth()
        require(state.zoomPercent == widthPercent && abs(state.scrollYPt - widthScroll) < 0.01,
                "Fit Width is idempotent (same \(widthPercent)% and scroll offset)")

        state.zoomFitPage()
        let availableHeight = viewport.height - 2 * inset
        let fittedHeight = 792 * state.zoomFactor
        require(fittedHeight <= availableHeight + 0.5,
                "Fit Page keeps the page height inside the available height "
                    + "(\(fittedHeight) of \(availableHeight) pt)")
        require(fittedHeight >= availableHeight * 0.98,
                "Fit Page fills the available height within 2% (\(fittedHeight) of \(availableHeight))")
        require(state.statusMessage.contains("Fit page · \(state.zoomPercent)%"),
                "the status line shows the percentage Fit Page produced "
                    + "(\(state.statusMessage))")
        // The page is taller than the viewport when measured in content points, and the preset
        // intentionally keeps the document scrollable; what must not happen is a need to scroll
        // to see *this* page when it is the only one.
        require(state.contentHeightPt * state.zoomFactor > viewport.height,
                "Fit Page leaves other pages reachable by scrolling")
        require(state.currentPage == 2, "Fit Page keeps the current page")
        let pagePercent = state.zoomPercent
        let pageScroll = state.scrollYPt
        state.zoomFitPage()
        require(state.zoomPercent == pagePercent && abs(state.scrollYPt - pageScroll) < 0.01,
                "Fit Page is idempotent (same \(pagePercent)% and scroll offset)")

        state.zoomActual()
        require(state.zoomPercent == 100 && abs(state.zoomFactor - calibration.factor) < 1e-9,
                "Actual Size returns to exactly 100% of the calibrated scale after a preset")

        let singleEngine = ZoomPageEngine(pageSize: CGSize(width: 612, height: 792), pageCount: 1)
        let single = AppState(engine: singleEngine, tileCacheBudgetBytes: 48 * 1024 * 1024,
                              preferFullPageRasters: false)
        single.setViewportSize(viewport)
        single.setDeviceScale(2)
        single.setDisplayCalibration(calibration)
        single.open(url: url)
        single.zoomFitPage()
        let singleHeight = 792 * single.zoomFactor
        require(singleHeight <= viewport.height,
                "on a single-page document Fit Page leaves nothing to scroll (\(singleHeight) pt)")
        require(single.scrollYPt == 0, "a single page fitted to the height starts at its top")
    }

    /// Moving the window to another screen or changing the display mode keeps the percentage and
    /// re-derives the factor; the reading position is the same content point, clamped only at
    /// the document end.
    @MainActor private static func recalibrationChecks(url: URL) {
        let fiveK = DisplayCalibration.resolve(logicalWidthPt: 2560, physicalWidthMm: 599.29953)
        let twentyFour = DisplayCalibration.resolve(logicalWidthPt: 1440, physicalWidthMm: 609.6)
        let state = AppState(
            engine: ZoomPageEngine(pageSize: CGSize(width: 612, height: 792), pageCount: 4),
            tileCacheBudgetBytes: 48 * 1024 * 1024, preferFullPageRasters: false)
        state.setViewportSize(CGSize(width: 900, height: 700))
        state.setDeviceScale(2)
        state.setDisplayCalibration(fiveK)
        state.open(url: url)
        state.gotoPage(2)
        state.zoomPercent = 150
        state.reloadVisiblePages()
        let factorBefore = state.zoomFactor
        let scrollBefore = state.scrollYPt
        let pageBefore = state.currentPage
        require(abs(factorBefore - 1.5 * fiveK.factor) < 1e-9,
                "150% on the 5K screen is 1.5 × its calibration")

        state.setDisplayCalibration(twentyFour)
        require(state.zoomPercent == 150,
                "moving to another screen keeps the percentage at 150, not the pixel size")
        require(abs(state.zoomFactor - 1.5 * twentyFour.factor) < 1e-9,
                "moving to another screen re-derives the factor from the new calibration")
        require(state.currentPage == pageBefore,
                "recalibration keeps the current page (the top content point is unchanged)")
        require(abs(state.scrollYPt - scrollBefore) < 0.01,
                "recalibration keeps the scroll position in content points")

        state.setDisplayCalibration(fiveK)
        require(abs(state.zoomFactor - factorBefore) < 1e-9,
                "moving back restores exactly the first factor at the same percentage")

        // Pointer-anchored zoom must still hold the content point under the pointer when the
        // factor includes calibration: the arithmetic uses `zoomFactor`, not the percentage.
        let anchorViewY: CGFloat = 180
        let contentBefore = CanvasGeometry.contentY(
            viewY: anchorViewY, scrollYPt: state.scrollYPt, zoom: state.zoomFactor)
        let zoomBefore = state.zoomPercent
        require(state.zoomByPinch(0.1, anchorViewY: anchorViewY), "a pinch zooms on a calibrated screen")
        require(state.zoomPercent == zoomBefore + 10, "the pinch still moves the percentage by 10")
        let contentAfter = CanvasGeometry.contentY(
            viewY: anchorViewY, scrollYPt: state.scrollYPt, zoom: state.zoomFactor)
        require(abs(contentAfter - contentBefore) < 0.5,
                "the content point under the pointer is preserved with calibration applied "
                    + "(\(contentBefore) → \(contentAfter) pt)")
    }

    /// Facing mode: Fit Width uses the spread's width, Fit Page uses one page row's height, and
    /// both keep the current page (and show their percentage).
    @MainActor private static func facingSpreadFitChecks(
        fixtures: URL,
        calibration: DisplayCalibration
    ) throws {
        // A long document: with only one spread, zooming out clamps the scroll at the content
        // end and the viewport top necessarily names the row above the one being fitted. Work on
        // a scratch copy so a restored reading position or an annotation cache cannot leak into the check.
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-reader-facing-zoom-\(UUID())")
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        let longURL = scratchDirectory.appendingPathComponent("long.pdf")
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("index-past-120.pdf"), to: longURL)
        let viewport = CGSize(width: 900, height: 700)
        let state = AppState(engine: try RustEngine(), tileCacheBudgetBytes: 48 * 1024 * 1024,
                             preferFullPageRasters: false)
        state.setViewportSize(viewport)
        state.setDeviceScale(2)
        state.setDisplayCalibration(calibration)
        require(state.open(url: longURL), "the facing-spread fixture opens")
        state.setLayoutMode(.facing)
        // The automatic spread fit anchors the viewport centre; put the row under test back at
        // the top so the preset assertions start from a known current page.
        state.gotoPage(1)
        require(state.currentPage == 2, "the facing spread starts on page 2")

        state.zoomFitWidth()
        let availableWidth = viewport.width - 2 * AppState.zoomPresetInsetPt
        let spreadWidth = state.contentWidthPt * state.zoomFactor
        require(spreadWidth <= availableWidth + 0.5,
                "Fit Width keeps the whole facing spread inside the viewport "
                    + "(\(spreadWidth) of \(availableWidth) pt)")
        require(spreadWidth >= availableWidth * 0.98,
                "Fit Width fills the viewport with the spread within the integer-percent step "
                    + "(\(spreadWidth) of \(availableWidth) pt)")
        require(state.currentPage == 2, "facing Fit Width keeps the current page")
        require(state.statusMessage.contains("Fit width · \(state.zoomPercent)%"),
                "facing Fit Width shows its percentage (\(state.statusMessage))")
        if let left = state.canvasPageFrames.first(where: { $0.index == 1 }) {
            let row = state.canvasPageFrames.filter { abs($0.topPt - left.topPt) < 0.5 }
            require(row.count == 2 && row.contains { $0.index == 2 },
                    "both pages of the facing row are laid out")
        } else {
            require(false, "the left page of the facing row has a placement")
        }

        state.zoomFitPage()
        let availableHeight = viewport.height - 2 * AppState.zoomPresetInsetPt
        let pageHeight = 842 * state.zoomFactor
        require(pageHeight <= availableHeight + 0.5,
                "facing Fit Page fits one row's height (\(pageHeight) of \(availableHeight) pt)")
        require(pageHeight >= availableHeight * 0.98,
                "facing Fit Page fills the height within 2%")
        require(state.currentPage == 2, "facing Fit Page keeps the current page")
        require(state.statusMessage.contains("Fit page · \(state.zoomPercent)%"),
                "facing Fit Page shows its percentage (\(state.statusMessage))")

        // The cover is a one-page row centred in the spread's width: Fit Width fills with the
        // cover rather than with the empty partner slot.
        state.gotoPage(0)
        state.zoomFitWidth()
        let coverWidth = 595 * state.zoomFactor
        require(coverWidth <= availableWidth + 0.5 && coverWidth >= availableWidth * 0.98,
                "facing Fit Width fits a lone cover to the viewport (\(coverWidth) of "
                    + "\(availableWidth) pt)")
        require(state.currentPage == 1, "the cover fit keeps the cover current")
    }

    /// A view point for a page coordinate must invert to that same page coordinate at any
    /// calibrated zoom, which is what annotation placement depends on.
    @MainActor private static func annotationPlacementChecks(calibration: DisplayCalibration) {
        // The marks below are persisted to the application cache, so use a scratch
        // URL instead of a committed fixture (this engine never reads the file itself).
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-reader-zoom-\(UUID()).pdf")
        let records = DocumentEditCache.annotationsURL(for: scratch)
        defer {
            try? FileManager.default.removeItem(at: scratch)
            try? FileManager.default.removeItem(at: records)
        }
        let viewport = CGSize(width: 900, height: 700)
        let state = AppState(
            engine: ZoomPageEngine(pageSize: CGSize(width: 612, height: 792), pageCount: 1),
            tileCacheBudgetBytes: 48 * 1024 * 1024, preferFullPageRasters: false)
        state.setViewportSize(viewport)
        state.setDeviceScale(2)
        state.setDisplayCalibration(calibration)
        state.open(url: scratch)
        state.gotoPage(0)
        guard let placement = state.canvasPageFrames.first(where: { $0.index == 0 }) else {
            require(false, "the annotation fixture page has a placement")
            return
        }
        let aim = CGPoint(x: 120, y: 240)
        var stored: [CGPoint] = []
        for percent in [100, 150] {
            state.zoomPercent = percent
            state.reloadVisiblePages()
            let zoom = state.zoomFactor
            let offsetX = CanvasGeometry.contentOffsetX(
                viewportWidthPt: viewport.width,
                contentWidthPt: state.contentWidthPt,
                zoom: zoom)
            let viewPoint = CanvasGeometry.viewRect(
                pageTopPt: placement.topPt, pageLeftPt: placement.leftPt,
                region: CGRect(origin: aim, size: .zero),
                scrollYPt: state.scrollYPt, zoom: zoom, contentOffsetX: offsetX).origin
            let content = CanvasGeometry.contentPoint(
                viewX: viewPoint.x, viewYTop: viewPoint.y,
                scrollYPt: state.scrollYPt, zoom: zoom, contentOffsetX: offsetX)
            guard let converted = state.pagePoint(atContentPoint: content) else {
                require(false, "\(percent)% maps the view point to a page")
                return
            }
            require(converted.page == 0, "\(percent)% maps to page one")
            require(abs(converted.point.x - aim.x) < 0.01 && abs(converted.point.y - aim.y) < 0.01,
                    "\(percent)% lands on the same page coordinate (\(converted.point) vs \(aim))")
            require(state.addInkAnnotation(page: 0, points: [aim, CGPoint(x: aim.x + 40, y: aim.y + 40)],
                                           color: AnnotationColor(red: 0xE8, green: 0xBC, blue: 0x55, alpha: 255),
                                           strokeWidth: 2),
                    "\(percent)% stores a mark")
            if let ink = state.annotations.last(where: { $0.kind == .ink })?.inkPaths.first?.first {
                stored.append(ink)
            }
        }
        require(stored.count == 2 && abs(stored[0].x - stored[1].x) < 0.01
                    && abs(stored[0].y - stored[1].y) < 0.01,
                "a mark placed at 100% and at 150% stores the same page coordinates")
    }

    /// Low (actual-size) zoom uses the screen-resolution page path; deep zoom keeps the tile
    /// path. The decision is taken on the calibrated screen scale, so this also proves the
    /// calibration reaches the raster scale exactly once.
    @MainActor private static func rasterPathChecks(url: URL, calibration: DisplayCalibration) async throws {
        let engine = ZoomPageEngine(pageSize: CGSize(width: 600, height: 800), pageCount: 8)
        let state = AppState(engine: engine, tileCacheBudgetBytes: 48 * 1024 * 1024,
                             preferFullPageRasters: true)
        state.setViewportSize(CGSize(width: 900, height: 700))
        state.setDeviceScale(2)
        state.setDisplayCalibration(calibration)
        state.open(url: url)
        state.gotoPage(0)
        state.zoomPercent = 100
        state.reloadVisiblePages()
        require(state.usesScreenPageRasters,
                "Actual Size on a calibratable screen keeps the screen-resolution page path")
        require(engine.tileRequests == 0,
                "the screen-resolution path does not duplicate its page with tile work")

        state.zoomPercent = 300
        state.reloadVisiblePages()
        require(!state.usesScreenPageRasters,
                "deep zoom falls back to the bounded tile path instead of oversized page rasters")
        try await eventually("deep zoom queues tile work", { engine.tileRequests > 0 })
    }

    /// The suite entry point (`LyraReaderChecks --check-zoom .`).
    @MainActor static func zoomChecks(root: URL) async throws {
        displayCalibrationFormulaChecks()
        let fiveK = DisplayCalibration.resolve(logicalWidthPt: 2560, physicalWidthMm: 599.29953)
        let fixtures = root.appendingPathComponent("tests/fixtures")
        let url = fixtures.appendingPathComponent("multipage.pdf")
        try actualSizeChecks(url: url)
        fitPresetChecks(url: url, calibration: fiveK)
        recalibrationChecks(url: url)
        try facingSpreadFitChecks(fixtures: fixtures, calibration: fiveK)
        annotationPlacementChecks(calibration: fiveK)
        try await rasterPathChecks(url: url, calibration: fiveK)
        print("Zoom checks passed")
    }
}
