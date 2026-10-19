import AppKit
import LyraReaderKit
import Foundation

extension ReaderChecks {
    // MARK: - Two windows are two sessions (the reader's report)

    /// What the reader saw: a PDF dropped on the Dock icon opens a second window, the two windows
    /// show the same tabs, opening a document shows it in both, scrolling one scrolls the other,
    /// and switching tabs in one switches the other.
    ///
    /// Every one of those is a statement about *ownership*, so that is what these checks assert:
    /// two window sessions built the way the app builds them (one `ReaderSession` each, in one
    /// `ReaderWindowRegistry`) must share nothing a reader can change — no tab list, no current
    /// document, no scroll position, no zoom, no drag-hover hint — while what the app *does* share
    /// (the one PDFium library, the one GPU device, one routing rule for documents from outside)
    /// keeps working.
    ///
    /// These checks fail on the old ownership graph on their first assertion, and that is by
    /// design: the old scene handed `appDelegate.state` to every window, so `left.state` and
    /// `right.state` were the *same object* — `left.state !== right.state` is exactly the bug.
    @MainActor static func windowIndependenceChecks(a: URL, b: URL) async throws {
        let registry = ReaderWindowRegistry()
        // The app is up (this is the running-app case); the launch case is check 8.
        registry.markReady()

        /// One window each, built the way `ReaderWindowRoot` builds them (a fresh engine per
        /// session, because the engine is where the open document lives).
        func window(_ label: String) -> ReaderSession {
            let state = AppState(engine: try! RustEngine())
            state.setViewportSize(CGSize(width: 700, height: 500))
            let session = ReaderSession(state: state, registry: registry)
            registry.register(session)
            return session
        }

        let left = window("left")
        let right = window("right")
        left.noteFocused()

        // 0. Nothing at all is shared between two windows.
        require(left.state !== right.state,
                "two windows are handed two state objects, not one")
        require(left.opener !== right.opener,
                "two windows have their own document coordinator")
        require(left.previewPanels !== right.previewPanels,
                "two windows have their own floating preview panel")
        require(registry.sessions.count == 2, "both windows are registered")

        // 1. Tab lists. Opening a document in one window must not add a tab to the other.
        require(left.opener.openDocuments([a]) == 1, "the first window opens a document")
        require(left.state.tabs.count == 1 && right.state.tabs.isEmpty,
                "a tab opened in one window is not in the other")
        require(left.state.document?.url?.path == a.path && right.state.document == nil,
                "the other window still shows no document")

        require(right.opener.openDocuments([b]) == 1, "the second window opens its own document")
        require(left.state.tabs.count == 1 && right.state.tabs.count == 1,
                "each window has exactly the tab it opened")
        require(left.state.document?.url?.path == a.path && right.state.document?.url?.path == b.path,
                "each window keeps its own current document")

        // 2. Adding a tab to one window changes nothing in the other — not the tab list, not the
        //    document on screen, not the active tab.
        let leftActive = left.state.activeTabIndex
        require(left.opener.openDocuments([b]) == 1, "the first window opens a second document")
        require(left.state.tabs.count == 2 && left.state.activeTabIndex == 1,
                "the first window switched to the document it just opened")
        require(right.state.tabs.count == 1 && right.state.document?.url?.path == b.path,
                "the second window's tabs and document are untouched by the first window's tab")
        require(right.state.activeTabIndex == 0 && leftActive == 0,
                "each window has its own active tab")

        // 3. Scroll: both windows have the same multi-page document open, then one of them moves.
        left.state.selectTab(1)
        left.state.gotoPage(1)
        let leftBefore = left.state.scrollYPt
        require(leftBefore > 0, "the first window is scrolled down")
        let rightBefore = right.state.scrollYPt
        left.state.scroll(byScreenPoints: 96)
        require(left.state.scrollYPt > leftBefore, "scrolling the first window moves it")
        require(right.state.scrollYPt == rightBefore,
                "scrolling the first window leaves the second window's position alone")

        // 4. Zoom.
        let rightZoom = right.state.zoomPercent
        left.state.zoomIn()
        require(left.state.zoomPercent == min(AppState.maximumZoomPercent, rightZoom + 10)
                && right.state.zoomPercent == rightZoom,
                "zooming one window leaves the other window's zoom alone")

        // 5. Immediate wheel input and keyboard animation both belong to one window.
        let beforeWheel = left.state.scrollYPt
        let otherBeforeWheel = right.state.scrollYPt
        left.state.scrollByWheelStep(96)
        require(left.state.scrollYPt > beforeWheel && left.state.scrollDestinationYPt == nil,
                "wheel input moves only its window immediately without a glide")
        require(right.state.scrollYPt == otherBeforeWheel && right.state.scrollDestinationYPt == nil,
                "wheel input leaves the other window stationary")
        left.state.scrollByKeyboardStep(96)
        require(left.state.scrollDestinationYPt != nil,
                "keyboard input starts an animation in its own window")
        let leftBeforeGlide = left.state.scrollYPt
        let rightBeforeGlide = right.state.scrollYPt
        var glideFinished = false
        for _ in 0..<400 where !glideFinished {
            glideFinished = left.state.advanceScrollGlide(elapsed: 0.008)
        }
        require(left.state.scrollYPt != leftBeforeGlide, "the gliding window moves with its glide")
        require(right.state.scrollYPt == rightBeforeGlide && right.state.scrollDestinationYPt == nil,
                "…and the glide never moves the other window")
        require(glideFinished && left.state.scrollDestinationYPt == nil,
                "driving the glide to its destination ends it (nothing left animating)")

        // 6. A drag over one window's canvas belongs to that window: its own hover hint, and a drop
        //    that adds a tab there and nowhere else. This is the wiring `PDFCanvasView` gets.
        let leftCanvas = MetalCanvasView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let rightCanvas = MetalCanvasView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        left.opener.connect(leftCanvas)
        right.opener.connect(rightCanvas)

        let drag = CheckDraggingInfo(pasteboard: CheckPasteboard.files([a]))
        require(leftCanvas.draggingEntered(drag) == .copy, "the first window accepts a PDF drag")
        require(left.opener.dropHint?.kind == .acceptable && right.opener.dropHint == nil,
                "a drag hovering one window shows a hint in that window only")
        let rightTabs = right.state.tabs.count
        require(leftCanvas.performDragOperation(drag), "the drop on the first window is handled")
        require(left.state.tabs.count == 3 && right.state.tabs.count == rightTabs,
                "a drop on one window's canvas opens a tab in that window alone")
        require(right.state.document?.url?.path == b.path,
                "the other window still shows the document it had")
        require(left.opener.dropHint == nil && right.opener.dropHint == nil,
                "the hint clears in the window it belonged to")
        rightCanvas.draggingExited(nil)

        // 7. Where a document opened from *outside* the app goes, in the two orderings the real
        //    bundle has been measured in.
        //
        //    7a. macOS made a window for this request: its session registers before (or while)
        //        AppKit delivers the URLs, and that window may not be key yet — measured:
        //        `lyra-reader-window: 1 url(s) → session 2 of 3` with the key window still the second one.
        //        The document must go to the new window, not to the one the reader was using.
        let beforeRequest = (left: left.state.tabs.count, right: right.state.tabs.count)
        let requestWindow = window("request window")
        registry.receive([b])
        require(requestWindow.state.tabs.count == 1,
                "a document macOS opened a window for goes to that window")
        require(left.state.tabs.count == beforeRequest.left && right.state.tabs.count == beforeRequest.right,
                "…and leaves the windows that were already open alone")

        //    7b. No window was made for the request: it belongs to the window the reader is looking
        //        at, and not to the other one. (The real app decides this from `NSApp.keyWindow`,
        //        which no check can hold without putting a window on the reader's screen; the
        //        recorded focus is the same decision without a window, and the key-window half is
        //        what the real-bundle launch check exercises.)
        right.noteFocused()
        let rightTabsBeforeRequest = right.state.tabs.count
        let leftTabsBeforeRequest = left.state.tabs.count
        registry.receive([b])
        require(right.state.tabs.count == rightTabsBeforeRequest + 1,
                "a document with no window made for it lands in the window the reader is looking at")
        require(left.state.tabs.count == leftTabsBeforeRequest,
                "…and not in the window the reader is not looking at")

        // 8. Closing a window disturbs nothing in the other one, and the closed window's session
        //    stops receiving documents.
        let leftTabs = left.state.tabs.count
        let leftDocument = left.state.document?.url?.path
        let leftScroll = left.state.scrollYPt
        let leftZoom = left.state.zoomPercent
        let rightTabsOnClose = right.state.tabs.count
        let rightDocument = right.state.document?.url?.path
        registry.unregister(right)
        require(right.state.tabs.count == rightTabsOnClose && right.state.document?.url?.path == rightDocument,
                "the closing window's own session is left as it was")
        require(left.state.tabs.count == leftTabs && left.state.document?.url?.path == leftDocument
                && left.state.scrollYPt == leftScroll && left.state.zoomPercent == leftZoom,
                "closing one window leaves the other's tabs, document, scroll and zoom alone")
        require(!registry.sessions.contains(where: { $0 === right }),
                "the closed window leaves the registry")

        // The reader is looking at the window that is left, so new documents belong there — and
        // never in the session that closed.
        left.noteFocused()
        require(registry.activeSession === left, "the remaining window receives new documents")

        let leftTabsAfterClose = left.state.tabs.count
        registry.receive([a])
        require(left.state.tabs.count == leftTabsAfterClose + 1,
                "an external open request goes to the window that is still open")
        require(right.state.tabs.count == rightTabsOnClose, "…and never to the window that closed")

        // 9. A window that appeared since the last delivery wins even when another window is
        //    focused — that is the 7a case without the focus bookkeeping, and it is the rule that
        //    keeps a Dock drop landing in the window macOS opened for it.
        let newcomer = window("newest")
        let newcomerTabsBefore = newcomer.state.tabs.count
        let leftTabsBeforeNewest = left.state.tabs.count
        registry.receive([a])
        require(newcomer.state.tabs.count == newcomerTabsBefore + 1,
                "a new window receives the document delivered with it")
        require(left.state.tabs.count == leftTabsBeforeNewest,
                "…and the windows behind it are untouched")

        // 10. A launch that arrives with documents, before any window exists: the URLs wait in the
        //    registry (never dropped) and the first window that appears opens them.
        let launchRegistry = ReaderWindowRegistry()
        let launchDelegate = LyraReaderAppDelegate(registry: launchRegistry)
        launchDelegate.application(NSApplication.shared, open: [a, b])
        require(launchRegistry.pendingCount == 2 && launchRegistry.sessions.isEmpty,
                "documents delivered before any window exists wait instead of being lost")
        launchRegistry.markReady()
        require(launchRegistry.pendingCount == 2,
                "the app finishing its launch does not open them into a window that is not there")
        let firstWindow = ReaderSession(
            state: AppState(engine: try RustEngine()), registry: launchRegistry
        )
        firstWindow.state.setViewportSize(CGSize(width: 700, height: 500))
        launchRegistry.register(firstWindow)
        require(launchRegistry.pendingCount == 0 && firstWindow.state.tabs.count == 2,
                "the first window opens everything that waited for it")
        require(firstWindow.state.document?.url?.path == b.path,
                "the last document delivered is the one on screen, as before")

        // 11. A window still restores the reading position its document was left at, and the window
        //     that saved it does not move. (The position is stored per document, as it always was —
        //     two windows on the *same* file share that saved position, not their live one.)
        UserDefaults.standard.removeObject(forKey: "readingPosition:" + b.path)
        right.state.scroll(toFraction: 0.5)
        let savedPosition = right.state.scrollYPt
        require(savedPosition > 0, "the window scrolled to a position worth restoring")
        right.state.flushPendingPositionSave()
        let reopened = window("reopened")
        reopened.opener.openDocuments([b])
        require(abs(reopened.state.scrollYPt - savedPosition) < 1,
                "a window reopens its document where it was left "
                    + "(\(Int(reopened.state.scrollYPt)) pt of \(Int(savedPosition)) pt)")
        require(right.state.scrollYPt == savedPosition,
                "…and the window that saved the position stays where it was")

        // 12. The routing rule the real app depends on, with windows of its own so it needs no
        //     screen: a delivery that arrives while AppKit is making a window for it waits for that
        //     window instead of going to whichever window happened to be focused.
        //
        //     Measured in the real bundle: SwiftUI makes the window for an `odoc` event and makes it
        //     key *before* the delegate is handed the event, but the window's session only learns
        //     its window when SwiftUI attaches the view — after the delivery. Routing on focus alone
        //     sent the document to the previous window and left the new one empty.
        let holdRegistry = ReaderWindowRegistry()
        holdRegistry.markReady()
        let existing = ReaderSession(state: AppState(engine: try RustEngine()), registry: holdRegistry)
        let existingWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        existing.attach(window: existingWindow)
        holdRegistry.keyWindow = { existingWindow }
        // One document the reader opened while their window was key: it is also what puts the
        // rule's "a window appeared since the last delivery" bookkeeping in its steady state.
        holdRegistry.receive([a])
        require(existing.state.tabs.count == 1, "the reader's open window has its own document")

        // Now macOS makes a window for the next request and makes it key; no session owns it yet,
        // and the window's session has not learned its window either.
        let arrivingWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        holdRegistry.keyWindow = { arrivingWindow }
        holdRegistry.receive([b])
        require(existing.state.tabs.count == 1 && holdRegistry.pendingCount == 1,
                "a document that arrives while a window is being made does not go to the old window")
        let arriving = ReaderSession(state: AppState(engine: try RustEngine()), registry: holdRegistry)
        arriving.attach(window: arrivingWindow)
        require(arriving.state.tabs.count == 1 && holdRegistry.pendingCount == 0,
                "…it opens in the window AppKit made for it")
        require(existing.state.tabs.count == 1 && existing.state.document?.url?.path == a.path,
                "…and the window the reader already had is untouched")

        // 13. The bounded wait: a key window that never becomes a reader window (Settings, a panel)
        //     cannot swallow a document — after one turn it goes to the reader's own window.
        holdRegistry.keyWindow = { existingWindow }
        holdRegistry.receive([a])
        require(arriving.state.tabs.count == 2,
                "the newest window takes the next delivery too, and the bookkeeping moves on")
        let strayWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        holdRegistry.keyWindow = { strayWindow }
        // The reader's window is still the one they last used, even though AppKit's key window is
        // something else (the Settings window, say).
        existing.noteFocused()
        let tabsBeforeStray = existing.state.tabs.count
        holdRegistry.receive([b])
        require(holdRegistry.pendingCount == 1 && existing.state.tabs.count == tabsBeforeStray,
                "a document waits for the key window it was delivered against")
        try await Task.sleep(for: .milliseconds(50))
        require(holdRegistry.pendingCount == 0 && existing.state.tabs.count == tabsBeforeStray + 1,
                "…and opens in the reader's window when the key window is not a reader window")

        // The windows these checks made are never ordered on screen; forget their sessions so their
        // observers do not outlive the check.
        arriving.close()
        existing.close()
        require(holdRegistry.sessions.isEmpty, "closed check windows leave the registry")
    }
}

/// A pasteboard holding file URLs for a check drag.
enum CheckPasteboard {
    @MainActor static func files(_ urls: [URL]) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("lyra-reader-checks-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        return pasteboard
    }
}
