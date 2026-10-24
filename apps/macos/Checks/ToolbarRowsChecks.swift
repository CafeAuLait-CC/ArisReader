import AppKit
import Foundation
import LyraReaderKit
import SwiftUI

/// The secondary toolbar's rows: Annotate, Edit, Fill & Sign and Export share one slot, each
/// reveals with the pinned-progress slide, and the right-hand inspector follows the armed tool.
///
/// The checks measure the real reader window through hit testing and the chrome markers the
/// transition views already expose, not a private layout mirror. The measurement rows host the
/// real SwiftUI rows through `ReaderToolbarProbe`, so the item order is the order a reader sees.
extension ReaderChecks {
    @MainActor static func toolbarRowsChecks(root: URL) async throws {
        _ = NSApplication.shared
        // Use a scratch copy, not the checked-in fixture: this suite places and undoes
        // annotations, and the reader's process-wide annotation cache is keyed by path. Writing
        // to the repository fixture would leave a dirty cache for every later suite that opens
        // it (the titlebar discard check's "clean second tab" is the one that caught this).
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-reader-toolbar-rows-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = scratch.appendingPathComponent("toolbar-rows.pdf")
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: fixture)

        // ── 1. The rows and their one-at-a-time state machine ────────────────────────────
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 1200, height: 800))
        state.newTab(url: fixture)
        try await eventually("the toolbar-rows fixture opens", { state.document != nil })
        require(state.openSecondaryRows.isEmpty, "no secondary row is open at launch")

        state.toggleFillAndSign()
        require(state.openSecondaryRows == [.fillAndSign],
                "the Fill & Sign button opens exactly its row")
        state.toggleContentEditing()
        require(state.openSecondaryRows == [.contentEdit],
                "opening Edit closes Fill & Sign")
        state.toggleAnnotationTools()
        require(state.openSecondaryRows == [.annotations],
                "opening Annotate closes Edit")
        state.toggleExport()
        require(state.openSecondaryRows == [.export],
                "opening Export closes Annotate")
        state.toggleFillAndSign()
        require(state.openSecondaryRows == [.fillAndSign],
                "opening Fill & Sign closes Export")
        state.toggleFillAndSign()
        require(state.openSecondaryRows.isEmpty, "clicking the selected row's button closes it")

        // Direct assignments take the same path: no caller can open a second row.
        state.contentEditEnabled = true
        state.fillAndSignVisible = true
        require(state.openSecondaryRows == [.fillAndSign],
                "assigning a row's boolean directly still closes the others")
        state.annotationToolsVisible = true
        require(state.openSecondaryRows == [.annotations],
                "the annotation row's direct assignment closes Fill & Sign")
        state.exportVisible = true
        require(state.openSecondaryRows == [.export],
                "the Export row's direct assignment closes Annotate")
        state.pageOverviewVisible = true
        require(state.openSecondaryRows == [.export],
                "page overview leaves the row's state alone so closing it restores the row")
        state.pageOverviewVisible = false
        state.exportVisible = false
        require(state.openSecondaryRows.isEmpty, "the row slot is empty after closing page overview")

        // ── 2. Fill & Sign row geometry and order ────────────────────────────────────────
        require(FillSignTool.rowOrder.map(\.title)
                    == ["Text", "Signature", "Date", "Checkmark", "Cross", "Stamp", "Image"],
                "the Fill & Sign row declares the seven requested items in order")
        require(state.fillSignRowCommands.map(\.title) == FillSignTool.rowOrder.map(\.title),
                "the state's row commands follow the declared order")
        require(state.fillSignRowCommands.allSatisfy(\.enabled),
                "every Fill & Sign item is enabled on a plain document")
        require(state.fillSignRowCommands.allSatisfy {
                    NSImage(systemSymbolName: $0.icon, accessibilityDescription: nil) != nil
                }, "every Fill & Sign row icon exists on this macOS")

        let rowWidth = 1200 - ReaderChrome.sidebarTotalWidthPt
            - ReaderChrome.scrollIndicatorLaneWidthPt
        let minimumRowWidth = 900 - ReaderChrome.sidebarTotalWidthPt
            - ReaderChrome.scrollIndicatorLaneWidthPt
        func frame(_ id: String, _ frames: [String: CGRect], _ label: String) -> CGRect {
            guard let frame = frames[id] else {
                fatalError("FAIL: \(label) reports no frame for \(id)")
            }
            return frame
        }
        func assertFillSignFrames(width: CGFloat, label: String) -> [String: CGRect] {
            let frames = ReaderToolbarProbe.fillSignRowFrames(state: state, width: width)
            let ordered = FillSignTool.rowOrder.map { frame($0.title, frames, label) }
            print("FILL & SIGN \(label): "
                  + zip(FillSignTool.rowOrder, ordered)
                    .map { "\($0.title)=\(Int($1.minX))..\(Int($1.maxX))" }
                    .joined(separator: " "))
            require(ordered.count == 7, "\(label): the Fill & Sign row hosts all seven items")
            require(zip(ordered, ordered.dropFirst()).allSatisfy { $0.maxX <= $1.minX },
                    "\(label): the seven Fill & Sign items do not overlap")
            require(ordered.allSatisfy { $0.width > 1 && $0.height > 1 },
                    "\(label): every Fill & Sign item has a measurable control")
            require(ordered[0].minX >= AnnotationToolbarLayout.horizontalPadding - 0.01,
                    "\(label): the Text item starts at the row's leading padding")
            let close = frame("Clear Fill & Sign tool", frames, label)
            require(ordered.last!.maxX <= close.minX + 0.01,
                    "\(label): the clear button is trailing chrome, after Image")
            require(close.maxX <= width - AnnotationToolbarLayout.horizontalPadding + 0.01,
                    "\(label): the row fits inside the canvas width (\(close.maxX) of \(width))")
            return frames
        }
        _ = assertFillSignFrames(width: rowWidth, label: "1200 pt window")
        _ = assertFillSignFrames(width: minimumRowWidth, label: "900 pt minimum")

        // ── 3. Each Fill & Sign item arms its tool and its inspector ─────────────────────
        require(!state.fillSignInspectorVisible,
                "the Fill & Sign inspector is absent while no tool is armed")
        for tool in FillSignTool.rowOrder {
            state.selectFillSignTool(tool)
            require(state.armedFillSignTool == tool, "\(tool.title) becomes the armed row item")
            require(state.fillAndSignVisible, "\(tool.title) keeps the Fill & Sign row open")
            require(state.fillSignInspectorVisible,
                    "\(tool.title) opens the Fill & Sign inspector")
            switch tool {
            case .text:
                require(state.pendingFillSignPlacement == .text
                            && state.annotationTool == .textBox,
                        "Text arms the text-box placement")
            case .signature:
                require(state.pendingFillSignPlacement == nil && state.annotationTool == .select,
                        "Signature waits in the inspector for a method")
                require(state.fillSignSignatureMethods.map(\.title)
                            == ["Type", "Draw", "Image…", "From iPhone or iPad"],
                        "the Signature inspector offers the four methods in order")
            case .date:
                require(state.pendingFillSignPlacement == .date,
                        "Date arms its one-click placement")
                require(FillSignDateFormat.allCases.map(\.title)
                            == ["Medium", "Long", "Short", "ISO"],
                        "the Date inspector offers four formats")
                require(FillSignDateRotation.allCases.map(\.rawValue) == [0, 90, 180, 270],
                        "the Date inspector offers four rotations")
            case .checkmark:
                require(state.pendingFillSignPlacement == .checkmark,
                        "Checkmark arms its one-click placement")
            case .cross:
                require(state.pendingFillSignPlacement == .cross,
                        "Cross arms its one-click placement")
            case .stamp:
                require(state.annotationTool == .stamp && state.pendingStampStyle != nil,
                        "Stamp arms the stamp tool with a style")
                require(AppState.StampStyle.allCases.count >= 5,
                        "the Stamp inspector has the existing five styles")
            case .image:
                require(state.pendingFillSignPlacement == nil && state.annotationTool == .select,
                        "Image waits in the inspector for a picture")
                require(FillSignImageSize.allCases.map(\.title) == ["Small", "Medium", "Large"],
                        "the Image inspector offers three sizes")
                require(FillSignImageSize.medium.height == AppState.Annotation.defaultPictureHeight,
                        "the Image inspector's default keeps the historical picture height")
            }
            // Clicking the active item again clears it and closes the inspector.
            state.selectFillSignTool(tool)
            require(state.armedFillSignTool == nil,
                    "clicking \(tool.title) again clears it")
            require(!state.fillSignInspectorVisible,
                    "\(tool.title)'s inspector disappears when it is cleared")
            require(state.pendingFillSignPlacement == nil,
                    "\(tool.title)'s placement is dropped with the tool")
        }

        // Signature and Image wait for a choice in the inspector, so they have no pending
        // placement yet; Escape must still clear them and close the inspector.
        state.selectFillSignTool(.signature)
        require(state.cancelActiveAnnotationTool()
                    && state.armedFillSignTool == nil && !state.fillSignInspectorVisible,
                "Escape clears the Signature item before a method is chosen")
        state.selectFillSignTool(.image)
        require(state.cancelActiveAnnotationTool()
                    && state.armedFillSignTool == nil && !state.fillSignInspectorVisible,
                "Escape clears the Image item before a picture is chosen")

        // Date format and rotation, and the picture size, are real options rather than a
        // decorative picker: each changes the annotation the next click places.
        guard let pageFrame = state.canvasPageFrames.first(where: { $0.index == 0 }) else {
            require(false, "the Fill & Sign option checks need a laid-out first page")
            return
        }
        func contentPoint(_ point: CGPoint) -> CGPoint {
            CGPoint(x: pageFrame.leftPt + point.x, y: pageFrame.topPt + point.y)
        }
        let dateClick = CGPoint(x: 240, y: 260)
        state.fillSignDateFormat = .iso
        state.fillSignDateRotation = .none
        state.selectFillSignTool(.date)
        require(state.placePendingFillSign(atContentPoint: contentPoint(dateClick)),
                "the ISO date option places a date")
        guard let isoDate = state.annotations.last else {
            require(false, "the ISO date placed an annotation")
            return
        }
        require(isoDate.kind == .textBox
                    && isoDate.note.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$",
                                          options: .regularExpression) != nil,
                "the Date inspector's ISO format changes the placed text (\(isoDate.note))")
        state.undo()
        state.fillSignDateFormat = .medium

        state.fillSignDateRotation = .quarter
        state.selectFillSignTool(.date)
        require(state.placePendingFillSign(atContentPoint: contentPoint(dateClick)),
                "a rotated date places through the image path")
        guard let rotatedDate = state.annotations.last else {
            require(false, "the rotated date placed an annotation")
            return
        }
        require(rotatedDate.kind == .signature && rotatedDate.imageData != nil,
                "a rotated date is an image annotation so the PDF keeps its orientation")
        require((rotatedDate.shapeRect?.height ?? 0) > (rotatedDate.shapeRect?.width ?? 0),
                "a 90° date is placed taller than it is wide")
        state.undo()
        state.fillSignDateRotation = .none

        state.fillSignImageSize = .small
        let picture = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 32, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: picture)
        NSColor.systemGreen.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 32).fill()
        NSGraphicsContext.restoreGraphicsState()
        let pictureData = picture.representation(using: .png, properties: [:])!
        state.selectFillSignTool(.image)
        state.armPicturePlacement(imageData: pictureData)
        require(state.placeSignature(atContentPoint: contentPoint(CGPoint(x: 360, y: 420))),
                "the Image inspector's size option places a picture")
        guard let smallPicture = state.annotations.last else {
            require(false, "the small picture placed an annotation")
            return
        }
        require(abs((smallPicture.shapeRect?.height ?? 0) - FillSignImageSize.small.height) < 0.6,
                "the Image inspector's Small size sets the placed picture's height")
        state.undo()
        state.fillSignImageSize = .medium

        // ── 4. The Edit inspector follows an armed content tool, not the row ────────────
        state.contentEditEnabled = true
        state.contentEditTool = "select"
        state.contentEditSelection = nil
        require(!state.contentEditInspectorVisible,
                "Edit's row with no tool armed does not open the right inspector")
        state.selectContentTool("text")
        require(state.contentEditInspectorVisible,
                "arming the Text content tool opens the Edit inspector")
        state.selectContentTool("text")
        require(state.contentEditTool == "select" && !state.contentEditInspectorVisible,
                "clearing the content tool closes the Edit inspector")
        state.contentEditEnabled = false
        require(!state.contentEditInspectorVisible,
                "closing Edit also leaves the inspector closed")

        // The inspector is real chrome in the window, so its absence is measured too.
        let harness = try await ToolbarRowHarness.make(state: state)
        defer { harness.close() }
        harness.host.layoutSubtreeIfNeeded()
        let canvasWithRowOnly = harness.canvasRect
        require(canvasWithRowOnly.width > 100, "the hosted canvas has a measurable width")
        func waitForInspector(_ visible: Bool, _ message: String) async throws {
            try await eventually(message, {
                let width = harness.host.bounds.width - harness.canvasRect.maxX
                    - ReaderChrome.scrollIndicatorLaneWidthPt
                let expected: CGFloat = visible
                    ? ReaderChrome.editingPanelWidthPt : 0
                return abs(width - expected) < 1
            })
        }

        state.contentEditEnabled = true
        try await Task.sleep(for: .milliseconds(80))
        harness.host.layoutSubtreeIfNeeded()
        let editRowOnlyWidth = harness.canvasRect.width
        require(abs(editRowOnlyWidth - canvasWithRowOnly.width) < 0.5,
                "opening Edit with no tool armed does not take inspector width "
                    + "(\(editRowOnlyWidth) vs \(canvasWithRowOnly.width))")
        state.selectContentTool("text")
        try await waitForInspector(true, "arming a content tool opens the Edit inspector column")
        require(abs(harness.canvasRect.width
                    - (canvasWithRowOnly.width - ReaderChrome.editingPanelWidthPt)) < 1,
                "the Edit inspector takes its 292 pt from the canvas")
        state.selectContentTool("text")
        try await waitForInspector(false, "clearing the content tool closes the Edit inspector")

        state.contentEditEnabled = false
        state.fillAndSignVisible = true
        state.selectFillSignTool(.signature)
        try await waitForInspector(true, "arming a Fill & Sign tool opens its inspector column")
        require(abs(harness.canvasRect.width
                    - (canvasWithRowOnly.width - ReaderChrome.editingPanelWidthPt)) < 1,
                "the Fill & Sign inspector takes the same 292 pt from the canvas")
        try await eventually("the Fill & Sign inspector slot settles at 292 pt", {
            abs((harness.chromeRect(.fillSignInspectorSlot)?.width ?? 0)
                - ReaderChrome.editingPanelWidthPt) < 0.5
        })
        if let rowRect = harness.chromeRect(.secondaryToolbar),
           let slot = harness.chromeRect(.fillSignInspectorSlot) {
            require(abs(rowRect.maxX - slot.minX) < 1,
                    "the Fill & Sign row ends flush against its inspector column")
            require(abs(slot.width - ReaderChrome.editingPanelWidthPt) < 0.5,
                    "the Fill & Sign inspector column is the full 292 pt")
            require(abs(slot.minX - (harness.canvasRect.maxX
                                     + ReaderChrome.scrollIndicatorLaneWidthPt)) < 0.5,
                    "the Fill & Sign inspector begins after the canvas and its scroll lane")
            require(abs(slot.maxY - harness.canvasRect.maxY) < 0.5,
                    "the Fill & Sign inspector begins at the content top")
        } else {
            require(false, "the Fill & Sign row and inspector slot have measurable chrome frames")
        }
        state.clearFillSignTool()
        try await waitForInspector(false, "clearing the Fill & Sign tool closes its inspector")
        state.fillAndSignVisible = false

        // ── 5. The rows slide with the pinned progress ──────────────────────────────────
        // One harness, one document, three rows: the canvas frame and the page top must be
        // identical while each row reveals. The pinned progress is the test seam the sidebar
        // and annotation row already use, so this never races the display link.
        state.transitionProgressOverride = ReaderTransitionProgress(row: 0)
        let frameBefore = harness.canvasRect
        let pageTopBefore = harness.pageTopInHost(page: 0) ?? .nan
        func assertSlide(row: SecondaryRow, open: @escaping () -> Void,
                         close: @escaping () -> Void) async throws {
            state.transitionProgressOverride = ReaderTransitionProgress(row: 0)
            open()
            try await eventually("\(row.title) is pinned collapsed", {
                harness.rowHeight == 0
            })
            var samples: [CGFloat] = []
            for progress in [0.25, 0.5, 0.75, 1.0] {
                state.transitionProgressOverride = ReaderTransitionProgress(row: progress)
                let expected = ReaderChrome.secondaryToolbarHeightPt * CGFloat(progress)
                try await eventually("\(row.title) lays out at progress \(progress)", {
                    abs(harness.rowHeight - expected) <= 2
                })
                samples.append(harness.rowHeight)
                require(abs(harness.canvasRect.height - frameBefore.height) < 0.01
                            && abs(harness.canvasRect.minY - frameBefore.minY) < 0.01,
                        "\(row.title) at progress \(progress) leaves the canvas frame unchanged")
                let pageTop = harness.pageTopInHost(page: 0) ?? .nan
                require(abs(pageTop - pageTopBefore) < 0.01,
                        "\(row.title) at progress \(progress) leaves the page top unchanged")
            }
            print("ROW SLIDE \(row.title): \(samples.map { Int($0) }) pt")
            require(samples.contains { $0 > 2 && $0 < 44 },
                    "\(row.title) reveals its content over time instead of appearing whole "
                        + "(\(samples.map { Int($0) }))")
            require(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 },
                    "\(row.title)'s pinned reveal is monotonic (\(samples.map { Int($0) }))")
            state.transitionProgressOverride = nil
            try await eventually("\(row.title) reaches its full 46 pt", {
                harness.rowHeight >= 44
            })
            require(harness.rowHeight <= 46,
                    "\(row.title) stops at the full 46 pt row")
            state.transitionProgressOverride = ReaderTransitionProgress(row: 1)
            close()
            for progress in stride(from: 1.0, through: 0.0, by: -0.25) {
                state.transitionProgressOverride = ReaderTransitionProgress(row: progress)
                let expected = ReaderChrome.secondaryToolbarHeightPt * CGFloat(progress)
                try await eventually("\(row.title) collapses at progress \(progress)", {
                    abs(harness.rowHeight - expected) <= 2
                })
                require(abs(harness.canvasRect.height - frameBefore.height) < 0.01,
                        "\(row.title) closing at progress \(progress) leaves the canvas unchanged")
            }
            state.transitionProgressOverride = nil
            try await eventually("\(row.title) is closed", {
                harness.rowHeight == 0
            })
            require(state.openSecondaryRows.isEmpty, "\(row.title) closes the row slot")
        }

        try await assertSlide(row: .annotations, open: {
            state.annotationToolsVisible = true
        }, close: {
            state.annotationToolsVisible = false
        })
        try await assertSlide(row: .contentEdit, open: {
            state.contentEditEnabled = true
        }, close: {
            state.contentEditEnabled = false
        })
        try await assertSlide(row: .fillAndSign, open: {
            state.fillAndSignVisible = true
        }, close: {
            state.fillAndSignVisible = false
        })
        try await assertSlide(row: .export, open: {
            state.exportVisible = true
        }, close: {
            state.exportVisible = false
        })

        // ── 6. No animation on first layout, during a live resize, or with Reduce Motion ─
        let firstLayoutState = AppState(engine: try RustEngine())
        firstLayoutState.setViewportSize(CGSize(width: 1100, height: 750))
        firstLayoutState.newTab(url: fixture)
        try await eventually("the first-layout fixture opens", {
            firstLayoutState.document != nil && !firstLayoutState.canvasPageFrames.isEmpty
        })
        firstLayoutState.contentEditEnabled = true
        let firstLayout = try await ToolbarRowHarness.make(
            state: firstLayoutState, mountWait: false)
        defer { firstLayout.close() }
        // Give the first layout one short run-loop turn, well inside the 180 ms animation. A
        // row that animated its initial value would still be part-way open here.
        try await Task.sleep(for: .milliseconds(20))
        firstLayout.host.layoutSubtreeIfNeeded()
        let firstBottom = firstLayout.rowHeight
        require(firstBottom >= 44,
                "a row that is open at first layout is at full height immediately "
                    + "(\(firstBottom) pt after 20 ms)")

        // The same first-layout rule for Fill & Sign, whose first layout also opens the
        // inspector: neither may animate from zero on the window's first frame.
        let fillFirstState = AppState(engine: try RustEngine())
        fillFirstState.setViewportSize(CGSize(width: 1100, height: 750))
        fillFirstState.newTab(url: fixture)
        try await eventually("the Fill & Sign first-layout fixture opens", {
            fillFirstState.document != nil && !fillFirstState.canvasPageFrames.isEmpty
        })
        fillFirstState.fillAndSignVisible = true
        fillFirstState.selectFillSignTool(.signature)
        let fillFirst = try await ToolbarRowHarness.make(
            state: fillFirstState, mountWait: false)
        defer { fillFirst.close() }
        try await Task.sleep(for: .milliseconds(20))
        fillFirst.host.layoutSubtreeIfNeeded()
        require(fillFirst.rowHeight >= 44,
                "the Fill & Sign row is at full height on its first layout "
                    + "(\(fillFirst.rowHeight) pt after 20 ms)")
        require(fillFirstState.fillSignInspectorVisible,
                "the Fill & Sign inspector is present on that first layout")

        state.transitionProgressOverride = nil
        if state.fillAndSignVisible { state.fillAndSignVisible = false }
        if state.exportVisible { state.exportVisible = false }
        if state.contentEditEnabled { state.contentEditEnabled = false }
        state.annotationToolsVisible = false
        // The live-resize rule is about the *window*, not about the machine's Reduce Motion
        // preference. Pin the preference off for this block (CI runners sometimes have it on)
        // and restore whatever the process had afterwards.
        let savedReduceMotion = ReaderMotion.reduceMotionOverride
        defer { ReaderMotion.reduceMotionOverride = savedReduceMotion }
        ReaderMotion.reduceMotionOverride = false
        NotificationCenter.default.post(
            name: NSWindow.willStartLiveResizeNotification, object: harness.window)
        try await Task.sleep(for: .milliseconds(80))
        state.contentEditEnabled = true
        try await Task.sleep(for: .milliseconds(120))
        require(harness.rowHeight >= 44,
                "a row toggled during a live window resize is open after 120 ms "
                    + "(\(harness.rowHeight) pt; an animated one would be part-way)")
        NotificationCenter.default.post(
            name: NSWindow.didEndLiveResizeNotification, object: harness.window)
        try await Task.sleep(for: .milliseconds(80))
        require(ReaderMotion.secondaryRowAnimation != nil,
                "the row animation is available again after the live resize")
        state.contentEditEnabled = false
        try await Task.sleep(for: .milliseconds(120))

        ReaderMotion.reduceMotionOverride = true
        require(ReaderMotion.secondaryRowAnimation == nil,
                "Reduce Motion removes the row animation")
        state.fillAndSignVisible = true
        try await Task.sleep(for: .milliseconds(80))
        require(harness.rowHeight >= 44,
                "with Reduce Motion on, the Fill & Sign row is at full height after 80 ms")
        state.fillAndSignVisible = false
        try await Task.sleep(for: .milliseconds(120))
        ReaderMotion.reduceMotionOverride = false

        // ── 7. The primary toolbar's Fill & Sign label hides at the minimum width ───────
        let wideToolbar = ReaderToolbarProbe.toolbarFrames(state: state, width: 1400)
        let defaultToolbar = ReaderToolbarProbe.toolbarFrames(state: state, width: 1200)
        let minimumToolbar = ReaderToolbarProbe.toolbarFrames(state: state, width: 900)
        print("TOOLBAR LABELS wide: \(wideToolbar.keys.sorted().filter { $0.contains("label") })")
        print("TOOLBAR LABELS 900: \(minimumToolbar.keys.sorted().filter { $0.contains("label") })")
        require(wideToolbar["toolbar.fillSign.label"] != nil,
                "the Fill & Sign label is present at a wide window")
        require(defaultToolbar["toolbar.fillSign.label"] != nil,
                "the Fill & Sign label is present at the 1200 pt default window")
        require(minimumToolbar["toolbar.fillSign.label"] == nil,
                "the Fill & Sign label is hidden at the 900 pt minimum width")
        require((wideToolbar["toolbar.annotate.label"] != nil)
                    == (wideToolbar["toolbar.fillSign.label"] != nil),
                "the Fill & Sign label follows Annotate at wide widths")
        require((minimumToolbar["toolbar.annotate.label"] != nil)
                    == (minimumToolbar["toolbar.fillSign.label"] != nil),
                "the Fill & Sign label follows Annotate at the minimum width")
        require((wideToolbar["toolbar.edit.label"] != nil)
                    == (wideToolbar["toolbar.fillSign.label"] != nil),
                "the Fill & Sign label follows Edit at wide widths")
        require((minimumToolbar["toolbar.edit.label"] != nil)
                    == (minimumToolbar["toolbar.fillSign.label"] != nil),
                "the Fill & Sign label follows Edit at the minimum width")
        require(wideToolbar["toolbar.fillSign"] != nil,
                "the Fill & Sign toolbar button is measurable")
        require(wideToolbar["toolbar.fillSign"]!.width
                    >= (minimumToolbar["toolbar.fillSign"]?.width ?? 0),
                "hiding the label does not make the button wider at the minimum window")

        // ── 8. Organise pages is gone; every command has a menu-bar home ───────────────
        let toolbarSource = try String(
            contentsOf: root.appendingPathComponent(
                "apps/macos/Sources/LyraReaderKit/ReaderToolbar.swift"),
            encoding: .utf8)
        for retired in ["Organise pages", "FillSignMenuButton",
                        "LyraReaderMenu(title: \"Organise pages\"",
                        "LyraReaderMenu(title: \"Export and save\""] {
            require(!toolbarSource.contains(retired),
                    "the toolbar source no longer contains \(retired)")
        }
        require(toolbarSource.contains("AnnotationToolbarLayout.exportIcon"),
                "the Export button uses the row's own glyph constant")
        require(toolbarSource.contains("toggleFillAndSign()")
                    && toolbarSource.contains("toggleExport()"),
                "the primary toolbar has buttons for both new rows")

        let appMenuSource = try String(
            contentsOf: root.appendingPathComponent(
                "apps/macos/Sources/LyraReader/LyraReaderApp.swift"),
            encoding: .utf8)
        require(appMenuSource.contains("Menu(PageOperationsMenu.title)"),
                "the system Edit menu has a Page Operations submenu")
        require(appMenuSource.contains("ForEach(PageOperationsMenu.commands)"),
                "the Edit submenu is built from the same command list the checks hold")
        let expectedPageOperations = ["rotateClockwise", "rotateAnticlockwise",
                                      "insertBlankPageAfter", "extractSelectedPages",
                                      "appendPagesFromPDFs", "splitPages"]
        require(PageOperationsMenu.commands.map(\.id) == expectedPageOperations,
                "the six Organise pages commands all have a Page Operations entry")
        require(PageOperationsMenu.commands.map(\.title)
                    == ["Rotate Clockwise", "Rotate Anticlockwise", "Insert Blank Page After",
                        "Extract Selected Pages…", "Append Pages from PDFs…", "Split Pages…"],
                "the Page Operations submenu keeps the toolbar menu's command names")
        // And the full Pages menu still carries the same operations for reading workflows.
        for method in ["rotateSelectedPages(clockwise: true)",
                       "rotateSelectedPages(clockwise: false)",
                       "insertBlankPage(before: false)",
                       "presentExtractPagesPanel()",
                       "presentMergeDocumentsPanel()",
                       "presentSplitPagesPanel()"] {
            require(appMenuSource.contains(method),
                    "the menu bar still reaches Page Operations' \(method)")
        }

        // ── 9. The Export row carries every old command and its new icon ───────────────
        require(AnnotationToolbarLayout.exportIcon == "arrow.down.doc",
                "Export uses the document-download glyph")
        require(AnnotationToolbarLayout.exportIcon != "square.and.arrow.up",
                "Export's glyph is not the system Share glyph")
        require(NSImage(systemSymbolName: AnnotationToolbarLayout.exportIcon,
                        accessibilityDescription: nil) != nil,
                "the Export glyph exists on this macOS")
        require(ExportCommand.all.map(\.action) == ExportCommand.Action.allCases,
                "the Export row declares all eight commands")
        require(ExportCommand.all.map(\.fullTitle)
                    == ["Save", "Save As…", "Save Annotated Copy…",
                        "Export as Flattened Copy…", "Save Filled Form Copy…",
                        "Write Form Values to Original…", "Export Annotations…", "Print…"],
                "the Export row's items are the requested commands in order")
        require(ExportCommand.all.map(\.title)
                    == ["Save", "Save As…", "Annotated…", "Flattened…", "Filled Form…",
                        "Form Values…", "Annotations…", "Print…"],
                "the Export row's short labels fit the row in order")
        require(ExportCommand.all.allSatisfy {
                    NSImage(systemSymbolName: $0.icon, accessibilityDescription: nil) != nil
                }, "every Export item's glyph exists on this macOS")
        let enabledByAction: [ExportCommand.Action: Bool] = [
            .save: state.canSaveDocument,
            .saveAs: state.canSaveDocument,
            .saveAnnotatedCopy: state.document != nil && !state.annotationSaveInProgress,
            .exportFlattenedCopy: state.canFlattenDocument,
            .saveFilledFormCopy: state.canSaveFilledForm,
            .writeFormValuesToOriginal: state.canReplaceOriginalWithFilledForm,
            .exportAnnotations: state.canExportAnnotations,
            .print: state.document != nil,
        ]
        for command in ExportCommand.all {
            require(command.isEnabled(state) == enabledByAction[command.action],
                    "Export's \(command.title) uses the reader's own enabled rule")
            require(command.helpText(state).contains(command.help),
                    "Export's \(command.title) keeps its help sentence")
        }
        let wideExport = ReaderToolbarProbe.exportRowFrames(state: state, width: rowWidth)
        let minimumExport = ReaderToolbarProbe.exportRowFrames(
            state: state, width: minimumRowWidth)
        for (frames, label, width) in [(wideExport, "1200 pt window", rowWidth),
                                       (minimumExport, "900 pt minimum", minimumRowWidth)] {
            let ordered = ExportCommand.all.map {
                frame("export.\($0.id)", frames, label)
            }
            print("EXPORT \(label): "
                  + zip(ExportCommand.all, ordered)
                    .map { "\($0.title)=\(Int($1.minX))..\(Int($1.maxX))" }
                    .joined(separator: " "))
            require(zip(ordered, ordered.dropFirst()).allSatisfy { $0.maxX <= $1.minX },
                    "\(label): the Export items do not overlap")
            require(ordered.allSatisfy { $0.width > 1 },
                    "\(label): every Export item has a measurable control")
            require(ordered.last!.maxX <= width - AnnotationToolbarLayout.horizontalPadding + 0.01,
                    "\(label): the Export row fits inside the canvas width "
                        + "(\(ordered.last!.maxX) of \(width))")
        }

        // Every command that used to be in a toolbar menu still has a named home.
        let exportSource = try String(
            contentsOf: root.appendingPathComponent(
                "apps/macos/Sources/LyraReaderKit/ExportCommands.swift"),
            encoding: .utf8)
        for method in ["state.saveDocument()", "state.presentSaveDocumentCopyPanel()",
                       "state.presentSaveAnnotatedCopyPanel()", "state.presentFlattenCopyPanel()",
                       "state.presentSaveFilledFormPanel()",
                       "state.presentReplaceOriginalWithFilledFormConfirmation()",
                       "state.presentExportAnnotationsPanel()", "state.printDocument()"] {
            require(exportSource.contains(method),
                    "the Export row keeps \(method)")
        }
        require(toolbarSource.contains("ExportToolRow(state: state)"),
                "the primary toolbar hosts the Export row")
        require(appMenuSource.contains("presentSaveFilledFormPanel")
                    && appMenuSource.contains("presentReplaceOriginalWithFilledFormConfirmation"),
                "the File menu carries both Fill & Sign form writes")
        let fillInspectorSource = try String(
            contentsOf: root.appendingPathComponent(
                "apps/macos/Sources/LyraReaderKit/FillSignInspector.swift"),
            encoding: .utf8)
        require(fillInspectorSource.contains("state.fillSignFormCommands")
                    && fillInspectorSource.contains("performFillAndSignCommand"),
                "the Fill & Sign inspector carries both form writes too")

        // ── 10. Continuity is hosted in the inspector and still wired ────────────────────
        let controller = FillSignCommandController(state: state)
        let requestor = ContinuitySignatureRequestor(controller: controller)
        require(requestor.title == "From iPhone or iPad",
                "the Signature inspector retains its device entry")
        let inspectorSource = try String(
            contentsOf: root.appendingPathComponent(
                "apps/macos/Sources/LyraReaderKit/FillSignInspector.swift"),
            encoding: .utf8)
        require(inspectorSource.contains("SignatureContinuityButton"),
                "the inspector hosts the continuity button")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("lyra-toolbar-rows-\(UUID())"))
        pasteboard.clearContents()
        let png = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: png)
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        NSGraphicsContext.restoreGraphicsState()
        pasteboard.setData(png.representation(using: .png, properties: [:])!, forType: .png)
        state.selectFillSignTool(.signature)
        let requestorWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        requestorWindow.isReleasedWhenClosed = false
        requestorWindow.contentView = requestor
        defer { requestorWindow.close(); pasteboard.releaseGlobally() }
        require(requestor.beginRequest(), "the inspector's device button becomes the requestor")
        require(requestor.readSelection(from: pasteboard),
                "the continuity requestor accepts a sketch from the pasteboard")
        require(state.pendingSignatureImageData != nil,
                "the received sketch becomes the armed signature image")
        state.clearFillSignTool()

        print("Toolbar row checks passed")
    }
}

/// The hosted reader a row's slide and inspector are measured on.
@MainActor
private final class ToolbarRowHarness {
    let state: AppState
    let host: NSHostingView<ReaderWindow>
    let window: NSWindow
    private(set) var canvas: MetalCanvasView!

    private init(state: AppState) {
        self.state = state
        self.host = NSHostingView(rootView: ReaderWindow(
            state: state, opener: DocumentOpenCoordinator(state: state)))
        self.window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1100, height: 750),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
    }

    /// Builds a harness around a state that already has a document, and (by default) waits for
    /// the canvas to lay out. `mountWait: false` is for the first-layout check: it returns after
    /// ordering the window so the caller can measure the initial layout.
    static func make(state: AppState, mountWait: Bool = true) async throws
        -> ToolbarRowHarness {
        let harness = ToolbarRowHarness(state: state)
        harness.window.orderFrontRegardless()
        if mountWait {
            try await ReaderChecks.eventually("the row harness lays out its canvas", {
                harness.host.layoutSubtreeIfNeeded()
                harness.canvas = harness.findCanvas(in: harness.host)
                return harness.canvas != nil
            })
            harness.host.layoutSubtreeIfNeeded()
        } else {
            harness.host.layoutSubtreeIfNeeded()
            harness.canvas = harness.findCanvas(in: harness.host)
        }
        return harness
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }

    private func findCanvas(in view: NSView) -> MetalCanvasView? {
        if let found = view as? MetalCanvasView { return found }
        return view.subviews.lazy.compactMap { self.findCanvas(in: $0) }.first
    }

    var canvasRect: CGRect {
        host.layoutSubtreeIfNeeded()
        guard let canvas else { return .zero }
        if let clip = canvas.enclosingScrollView?.contentView {
            return host.convert(clip.bounds, from: clip)
        }
        return host.convert(canvas.bounds, from: canvas)
    }

    func pageTopInHost(page: Int) -> CGFloat? {
        guard let placement = state.canvasPageFrames.first(where: { $0.index == page }) else {
            return nil
        }
        let fromCanvasTop = (placement.topPt - state.scrollYPt) * state.zoomFactor
        return canvasRect.maxY - fromCanvasTop
    }

    func hit(fromCanvasTop offset: CGFloat, xFraction: CGFloat = 0.5) -> NSView? {
        host.layoutSubtreeIfNeeded()
        guard let canvas else { return nil }
        let local = CGPoint(x: canvas.bounds.width * xFraction,
                            y: canvas.bounds.height - offset)
        let inHost = host.convert(local, from: canvas)
        return host.hitTest(host.convert(inHost, to: host.superview))
    }

    /// The animated height of the one secondary-row slot, measured from the marker the
    /// transition hosts around the row. Hit testing cannot be used here: when Edit is open its
    /// content editor covers the canvas below the row, and a click below the row would still
    /// miss the Metal canvas.
    var rowHeight: CGFloat {
        chromeRect(.secondaryRowSlot)?.height ?? 0
    }

    /// Any of the chrome markers by kind, in host coordinates.
    func chromeRect(_ kind: ReaderChromeMarkerView.Kind) -> CGRect? {
        func find(_ view: NSView) -> ReaderChromeMarkerView? {
            if let found = view as? ReaderChromeMarkerView, found.kind == kind { return found }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        host.layoutSubtreeIfNeeded()
        guard let marker = find(host) else { return nil }
        return host.convert(marker.bounds, from: marker)
    }
}
