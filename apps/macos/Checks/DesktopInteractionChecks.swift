import AppKit
import ArisReaderKit
import Foundation

extension ReaderChecks {
    // MARK: - Desktop interaction: context menus and the sidebar's new-window drop (T2.12)

    /// The parts of T2.12 that were still missing after the document-open work landed:
    ///
    /// * a right-click menu on the page canvas,
    /// * a right-click menu on a sidebar thumbnail (open in this/new window, page commands),
    /// * a file dropped on the **sidebar** opening a new window through `ReaderWindowRegistry`,
    ///   while the canvas keeps opening a tab in the current window.
    ///
    /// The existing drop and Dock paths are asserted too, at the level that matters: the file
    /// list becomes tabs, a refused file changes nothing and says why, and the sidebar's drop
    /// routes through the registry rather than through pixels.
    @MainActor static func desktopInteractionChecks(a: URL, b: URL, linkFixture: URL) async throws {
        try await canvasContextMenuChecks(a: a)
        try await linkContextMenuChecks(path: linkFixture)
        try await thumbnailContextMenuChecks(b: b)
        try await sidebarNewWindowDropChecks(a: a, b: b)
        try await existingDropHardeningChecks(a: a, b: b)
    }

    // MARK: Canvas context menu

    @MainActor private static func canvasContextMenuChecks(a: URL) async throws {
        let engine = try RustEngine()
        let state = AppState(engine: engine)
        state.setViewportSize(CGSize(width: 700, height: 800))
        require(state.open(url: a), "the canvas-menu fixture opens")

        guard let text = try? await engine.textPage(0),
              let placement = engine.visiblePages(
                scrollYPt: 0, viewportHeightPt: 800, gapPt: state.pageGapPt,
                marginPt: 0, layout: state.layoutMode
              ).first(where: { $0.index == 0 })
        else { fatalError("FAIL: the canvas-menu fixture has no first page") }
        guard let index = text.chars.firstIndex(where: {
            $0.unicode != 32 && $0.widthPt > 1 && $0.heightPt > 1
        }) else { fatalError("FAIL: the canvas-menu fixture has no visible character") }
        let character = text.chars[index]
        let point = CGPoint(
            x: placement.leftPt + character.xPt + character.widthPt / 2,
            y: placement.topPt + character.yPt + character.heightPt / 2
        )

        // The app's layout pass is asynchronous; the menu is built from its result.
        try await eventually("the page layout is ready for a context menu", {
            state.pageIndex(at: point) != nil
        })

        // 1. No selection: the text commands are *absent*, not disabled. A page command is
        //    present because the pointer is over a page.
        let noSelection = CanvasContextMenu.items(state: state, at: point)
        let textActions: [CanvasContextMenuAction] = [
            .copySelection, .highlightSelection, .addNoteToSelection,
        ]
        require(!noSelection.contains { textActions.contains($0.action) },
                "a canvas menu with no selection offers no copy/highlight/note item")
        require(!noSelection.isEmpty && noSelection.allSatisfy(\.isEnabled),
                "the canvas menu still offers the page commands, and none are dead")
        require(noSelection.contains { item in
            if case .rotatePage(0, _) = item.action { return true }
            return false
        }, "a right-click on a page offers the page rotation command")
        require(noSelection.contains { item in
            if case .extractPage(0) = item.action { return true }
            return false
        }, "a right-click on a page offers page extraction")

        // 2. A selection: the three text commands are there and enabled.
        //
        // A drag, not a bare press: the first character of the fixture may sit under a mark
        // left by an earlier check in the full suite, and a plain press on a mark is a pending
        // mark click now. Extending once is exactly what a hand does when it means to select
        // text, and it is what makes the selection independent of what is drawn over it.
        var attempts = 0
        let dragEnd = CGPoint(x: point.x + 1, y: point.y)
        while state.selection == nil && attempts < 100 {
            state.beginSelection(at: point)
            state.extendSelection(to: dragEnd)
            attempts += 1
            if state.selection == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        guard state.selection != nil else {
            fatalError("FAIL: the canvas-menu check could not select the fixture's text")
        }
        let withSelection = CanvasContextMenu.items(state: state, at: point)
        for action in textActions {
            guard let item = withSelection.first(where: { $0.action == action }) else {
                fatalError("FAIL: a canvas menu with a selection is missing \(action)")
            }
            require(item.isEnabled, "\(item.title) is enabled when there is a selection")
        }

        // 3. The commands are the existing ones: a highlight and a note land in the same
        //    `AppState.annotations` the toolbar writes, with the reader's note text.
        let highlightsBefore = state.annotations.count
        require(CanvasContextMenu.perform(.highlightSelection, state: state, at: point),
                "the menu's highlight command runs")
        require(state.annotations.count == highlightsBefore + 1,
                "highlighting from the menu adds one annotation")
        require(CanvasContextMenu.perform(
            .addNoteToSelection, state: state, at: point, note: "menu note"),
                "the menu's note command runs")
        require(state.annotations.count == highlightsBefore + 2
                && state.annotations.last?.note == "menu note",
                "the menu's note is attached to the selection and editable like any other")
        let copiedBefore = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let copiedBefore { NSPasteboard.general.setString(copiedBefore, forType: .string) }
        }
        require(CanvasContextMenu.perform(.copySelection, state: state, at: point),
                "the menu's copy command runs")
        require(NSPasteboard.general.string(forType: .string)?.isEmpty == false,
                "the menu's copy command puts the selected text on the pasteboard")

        // 4. The AppKit menu is built from the same items, disables AppKit's auto-enabling, and
        //    has no dead entries; a point outside every page has no menu at all.
        guard let menu = CanvasContextMenu.menu(
            state: state, at: point
        ) else { fatalError("FAIL: the canvas menu is missing where the page is") }
        require(!menu.autoenablesItems, "the canvas menu keeps the states it built")
        require(menu.items.filter { !$0.isSeparatorItem }.allSatisfy(\.isEnabled),
                "every item in the canvas menu is usable")
        require(menu.items.contains { $0.title == "Copy Selection" },
                "the built menu carries the selection commands")
        state.clearSelection()
        require(CanvasContextMenu.menu(
            state: state, at: CGPoint(x: -500, y: -500)
        ) == nil, "a right-click away from every page offers no menu")

        // 5. No document: no page command at all.
        let emptyState = AppState(engine: try RustEngine())
        require(CanvasContextMenu.items(state: emptyState, at: point).isEmpty,
                "a canvas with no document offers no context menu items")
    }

    // MARK: Link item

    @MainActor private static func linkContextMenuChecks(path: URL) async throws {
        let engine = try RustEngine()
        let state = AppState(engine: engine)
        state.setViewportSize(CGSize(width: 700, height: 800))
        require(state.open(url: path), "the link fixture opens")

        let links = try await engine.links(0)
        guard let placement = engine.visiblePages(
                scrollYPt: 0, viewportHeightPt: 800, gapPt: state.pageGapPt,
                marginPt: 0, layout: state.layoutMode
            ).first(where: { $0.index == 0 }),
            let link = links.first
        else { fatalError("FAIL: the link fixture has no link on page 1") }

        let linkBox = CGRect(x: link.xPt, y: link.yPt, width: link.widthPt, height: link.heightPt)
        let linkPoint = CGPoint(
            x: placement.leftPt + linkBox.midX,
            y: placement.topPt + linkBox.midY
        )
        // Links are fetched per visible page in the background, so the menu must not be asked
        // before the same cache a click uses has them.
        try await eventually("the link under the pointer is known", {
            state.link(at: linkPoint) != nil
        })

        let overLink = CanvasContextMenu.items(state: state, at: linkPoint)
        require(overLink.contains { $0.action == .openLink && $0.isEnabled },
                "the link item appears when the pointer is over a link")

        // Find a point on the same page outside every link box.
        var freePoint: CGPoint?
        let pageBox = CGRect(
            x: placement.leftPt, y: placement.topPt,
            width: placement.widthPt, height: placement.heightPt
        )
        outer: for y in stride(from: 4.0, to: placement.heightPt - 4, by: 8) {
            for x in stride(from: 4.0, to: placement.widthPt - 4, by: 8) {
                let local = CGPoint(x: x, y: y)
                let insideALink = links.contains { candidate in
                    CGRect(
                        x: candidate.xPt, y: candidate.yPt,
                        width: candidate.widthPt, height: candidate.heightPt
                    ).contains(local)
                }
                if !insideALink {
                    freePoint = CGPoint(x: placement.leftPt + x, y: placement.topPt + y)
                    break outer
                }
            }
        }
        guard let freePoint, state.pageIndex(at: freePoint) != nil else {
            fatalError("FAIL: the link fixture has no point outside its links")
        }
        let awayFromLinks = CanvasContextMenu.items(state: state, at: freePoint)
        require(!awayFromLinks.contains { $0.action == .openLink },
                "no link item is offered where the pointer is not over a link")
    }

    // MARK: Thumbnail context menu

    @MainActor private static func thumbnailContextMenuChecks(b: URL) async throws {
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        require(state.open(url: b), "the thumbnail-menu fixture opens")
        require(state.document?.pageCount == 3, "the thumbnail-menu fixture has three pages")

        let sections = PageContextMenu.sections(state: state, page: 0, canOpenNewWindow: true)
        let items = sections.flatMap { $0 }
        let expected: [PageContextMenuAction] = [
            .openInCurrentWindow(0), .openInNewWindow(0),
            .rotate(0, clockwise: true), .deletePage(0), .extractPage(0),
        ]
        for action in expected {
            require(items.contains { $0.action == action },
                    "a thumbnail menu offers \(action)")
        }
        require(items.allSatisfy(\.isEnabled),
                "every thumbnail command is enabled for a normal three-page document")

        // Open in this window is the existing page command.
        require(PageContextMenu.perform(
            .openInCurrentWindow(1), state: state, newWindow: { _, _ in false }
        ), "the thumbnail's 'Open in Current Window' runs")
        require(state.currentPage == 2 && state.scrollYPt > 0,
                "it navigates this window to the clicked thumbnail's page")

        // Open in a new window is the registry path; the thumbnail passes the document and page.
        var requested: (url: URL, page: Int)?
        require(PageContextMenu.perform(
            .openInNewWindow(2), state: state,
            newWindow: { url, page in requested = (url, page); return true }
        ), "the thumbnail's 'Open in New Window' runs")
        require(requested?.url.path == b.path && requested?.page == 2,
                "it asks the window path for this document at the thumbnail's page")

        // Rotate is staged in the page-edit session, not written to the file.
        let bytesBefore = try Data(contentsOf: b)
        require(PageContextMenu.perform(
            .rotate(0, clockwise: true), state: state, newWindow: { _, _ in false }
        ), "the thumbnail's rotate command runs")
        try await eventually("the thumbnail rotation is staged", {
            state.pageEditSessionActive
        })
        require(state.pageEditPendingSummary?.contains("file on disk is unchanged") == true,
                "the rotation is pending, and the interface says the file is unchanged")
        let bytesAfter = try Data(contentsOf: b)
        require(bytesAfter == bytesBefore,
                "a context-menu rotation leaves the original file byte-identical")

        // A document-less state offers nothing: the menu never appears dead.
        let empty = AppState(engine: try RustEngine())
        require(PageContextMenu.sections(state: empty, page: 0, canOpenNewWindow: true).isEmpty,
                "a thumbnail menu with no document offers nothing")
    }

    // MARK: Sidebar drop -> new window

    @MainActor private static func sidebarNewWindowDropChecks(a: URL, b: URL) async throws {
        let registry = ReaderWindowRegistry()
        registry.markReady()
        let sourceState = AppState(engine: try RustEngine())
        sourceState.setViewportSize(CGSize(width: 700, height: 500))
        let source = ReaderSession(state: sourceState, registry: registry)
        registry.register(source)
        source.noteFocused()
        require(source.opener.openDocuments([a]) == 1, "the source window has one document")

        // The real app installs `openWindow`; the check substitutes a closure that registers a
        // session, which is exactly what SwiftUI does for the new window's `ReaderWindowRoot`.
        let created = CreatedReaderSessions()
        registry.newWindow = {
            let state = AppState(engine: try! RustEngine())
            state.setViewportSize(CGSize(width: 700, height: 500))
            let session = ReaderSession(state: state, registry: registry)
            created.sessions.append(session)
            registry.register(session)
        }

        require(source.opener.canOpenInNewWindow,
                "the sidebar target can create a reader window when the registry can")
        let preview = source.opener.previewNewWindowDrop([b])
        require(preview.kind == .acceptable && preview.message.contains("new window"),
                "a drag over the sidebar says it opens a new window: \(preview.message)")
        require(source.opener.newWindowDropHint != nil && source.opener.dropHint == nil,
                "the sidebar highlight is the sidebar's, not the canvas's")
        source.opener.endNewWindowDropPreview()
        require(source.opener.newWindowDropHint == nil,
                "leaving the sidebar cancels the new-window highlight")

        // The report's evidence: the drop is routed by the registry, and the new session has the
        // document while the window it was dropped on keeps exactly what it had.
        let tabsBefore = source.state.tabs.count
        require(source.opener.acceptNewWindowDrop([b]),
                "a file dropped on the sidebar opens in a new window")
        require(registry.newWindowRequestCount == 1,
                "the drop asked the registry for exactly one new window")
        require(registry.sessions.count == 2 && created.sessions.count == 1,
                "the registry holds the new window's session")
        guard let opened = created.sessions.first else {
            fatalError("FAIL: the sidebar drop created no session")
        }
        require(opened.state.tabs.count == 1 && opened.state.document?.url?.path == b.path,
                "the new window opens the dropped document")
        require(source.state.tabs.count == tabsBefore
                && source.state.document?.url?.path == a.path,
                "the window the file was dropped on is not replaced by the drop")
        require(source.opener.newWindowDropHint == nil,
                "the drop cancels the sidebar highlight")
        require(registry.pendingNewWindowCount == 0 && registry.pendingCount == 0,
                "nothing is left waiting for a window")

        // Several files in one drop all arrive, in order.
        let second = CreatedReaderSessions()
        registry.newWindow = {
            let state = AppState(engine: try! RustEngine())
            state.setViewportSize(CGSize(width: 700, height: 500))
            let session = ReaderSession(state: state, registry: registry)
            second.sessions.append(session)
            registry.register(session)
        }
        require(source.opener.acceptNewWindowDrop([a, b]),
                "a plural sidebar drop asks for a new window")
        guard let plural = second.sessions.first else {
            fatalError("FAIL: the plural sidebar drop created no session")
        }
        require(plural.state.tabs.count == 2 && plural.state.document?.url?.path == b.path,
                "each file in a plural sidebar drop gets a tab in the new window")

        // A non-PDF is refused with a reason, no window is made, and the source is untouched.
        let notes = a.deletingLastPathComponent().appendingPathComponent("sidebar-notes.txt")
        try Data("Just some notes, not a PDF.\n".utf8).write(to: notes)
        let windowsBefore = registry.sessions.count
        let tabsOnSource = source.state.tabs.count
        require(!source.opener.acceptNewWindowDrop([notes]),
                "a non-PDF dropped on the sidebar is refused")
        require(registry.sessions.count == windowsBefore && source.state.tabs.count == tabsOnSource,
                "a refused sidebar drop creates no window and changes nothing")
        require(source.state.lastError?.contains("PDF") == true,
                "the sidebar refusal says why: \(source.state.lastError ?? "no error")")
        source.state.lastError = nil

        // The canvas keeps its old meaning: the same drag on the canvas opens a tab here.
        let canvasState = AppState(engine: try RustEngine())
        canvasState.setViewportSize(CGSize(width: 700, height: 500))
        let canvasOpener = DocumentOpenCoordinator(state: canvasState)
        let canvas = MetalCanvasView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        canvasOpener.connect(canvas)
        let drag = CheckDraggingInfo(pasteboard: CheckPasteboard.files([a, b]))
        require(canvas.draggingEntered(drag) == .copy, "the canvas still accepts a file drag")
        require(canvas.performDragOperation(drag), "the canvas still handles the drop")
        require(canvasState.tabs.count == 2 && canvasState.document?.url?.path == b.path,
                "a canvas drop still opens one tab per document in the current window")
        require(canvasOpener.dropHint == nil && canvasOpener.newWindowDropHint == nil,
                "the canvas drop leaves no highlight behind")
    }

    // MARK: Existing drop hardening (kept, not reimplemented)

    @MainActor private static func existingDropHardeningChecks(a: URL, b: URL) async throws {
        // The checks that already covered this path live in `DocumentOpeningChecks`; these two
        // assert the properties the task calls out, so a regression is caught even if the older
        // suite is edited.
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        let opener = DocumentOpenCoordinator(state: state)
        let canvas = MetalCanvasView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        opener.connect(canvas)

        let twoPDFs = CheckDraggingInfo(pasteboard: CheckPasteboard.files([a, b]))
        require(canvas.draggingEntered(twoPDFs) == .copy,
                "a drag carrying two PDFs hovers as acceptable")
        require(opener.dropHint?.kind == .acceptable,
                "the hover hint promises the two documents")
        require(canvas.performDragOperation(twoPDFs), "the two-file drop is handled")
        require(state.tabs.count == 2 && state.document?.url?.path == b.path,
                "a dropped file list of two PDFs opens two tabs; the last is on screen")

        let notes = a.deletingLastPathComponent().appendingPathComponent("drop-notes.txt")
        try Data("Not a PDF.\n".utf8).write(to: notes)
        let tabsBefore = state.tabs.count
        let documentBefore = state.document?.id
        let openRequestsBefore = state.openRequestCount
        require(!canvas.performDragOperation(
            CheckDraggingInfo(pasteboard: CheckPasteboard.files([notes]))
        ), "a dropped non-PDF is refused")
        require(state.tabs.count == tabsBefore && state.document?.id == documentBefore,
                "a refused drop changes nothing")
        require(state.lastError?.contains("PDF") == true,
                "the refusal is readable: \(state.lastError ?? "no error")")
        require(state.openRequestCount == openRequestsBefore,
                "a refused drop never reaches the engine")
    }
}

/// Collects sessions a check's injected `newWindow` closure registers.
@MainActor
private final class CreatedReaderSessions {
    var sessions: [ReaderSession] = []
}
