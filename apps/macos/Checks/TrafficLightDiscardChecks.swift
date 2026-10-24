import AppKit
import LyraReaderKit
import Foundation
import SwiftUI

extension ReaderChecks {
    /// The three traffic lights must keep the geometry of the 44 pt tab row when the last
    /// document leaves the window — including through the Save / Discard decision — and must
    /// come back to it when the window gains a document again.
    ///
    /// **The defect this pins.** Closing the last dirty tab and choosing Discard closes the
    /// document, but AppKit's own titlebar layout then puts the standard window buttons back at
    /// its native origins (7 / 27 / 47 pt with a 6 pt top inset, i.e. 8 pt above the row's centre
    /// line in a 44 pt titlebar). Red and yellow end up back where the row wants them; green, the
    /// last button AppKit lays out, keeps the native frame: it sits 8 pt too high and only 7 pt
    /// to the right of yellow instead of the row's 20 pt pitch. The same displacement appears
    /// when the document becomes dirty (AppKit re-lays the titlebar for the edited dot) and is
    /// only corrected by an unrelated event that happens to re-run the alignment.
    ///
    /// The frames are asserted in the *window's* coordinate space, not in the button's parent:
    /// the parent is the titlebar view AppKit resizes and reconfigures, so local frames can look
    /// unchanged while the buttons visibly move.
    ///
    /// The assertion is the invariant, not the defect's pixel offset: the buttons stay in
    /// red / yellow / green order, the two consecutive origin gaps are equal, and all three share
    /// one y origin. That is what "the group is where a normal window puts it" means, and it
    /// stays true if the row's insets change.
    @MainActor static func titlebarLastTabChecks(root: URL) async throws {
        _ = NSApplication.shared
        let appearance = ReadingAppearanceStore.shared
        let savedMode = appearance.mode
        defer { appearance.mode = savedMode }
        appearance.mode = .original

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let registry = ReaderWindowRegistry()
        let session = ReaderSession(state: AppState(engine: try RustEngine()), registry: registry)
        let state = session.state
        state.setViewportSize(CGSize(width: 700, height: 500))
        window.contentView = NSHostingView(rootView: ReaderWindow(
            state: state,
            opener: session.opener,
            previewPanels: session.previewPanels,
            integratesTitlebar: true
        ))
        // The session is the real wiring: it installs the traffic-light layout and the resize,
        // full-screen and focus observers, and puts the window into the chrome the app uses.
        session.attach(window: window)
        defer {
            window.orderOut(nil)
            session.close()
        }

        let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        func frames() -> [NSRect] {
            kinds.compactMap { window.standardWindowButton($0) }
                .map { $0.convert($0.bounds, to: nil) }
        }
        func titlebarHeight() -> CGFloat {
            window.standardWindowButton(.closeButton)?.superview?.frame.height ?? -1
        }

        /// Red, yellow, green in that order, equal origin pitch, one shared centre line.
        func requireGroup(_ label: String) {
            let group = frames()
            require(group.count == 3, "\(label): all three traffic lights are present")
            require(group[0].minX < group[1].minX && group[1].minX < group[2].minX,
                    "\(label): the lights stay in red / yellow / green order (frames \(group))")
            let firstPitch = group[1].minX - group[0].minX
            let secondPitch = group[2].minX - group[1].minX
            require(abs(firstPitch - secondPitch) < 0.5,
                    "\(label): the origin pitch is equal for both gaps "
                    + "(red→yellow \(firstPitch), yellow→green \(secondPitch), frames \(group))")
            require(abs(group[2].minY - group[1].minY) < 0.001
                        && abs(group[1].minY - group[0].minY) < 0.001,
                    "\(label): all three lights share one y origin (frames \(group))")
            require(titlebarHeight() == TabRowLayout.height,
                    "\(label): the native titlebar is the 44 pt row (got \(titlebarHeight()))")
            require(group.allSatisfy {
                abs((window.frame.height - $0.midY) - TabRowLayout.contentCenterY) < 0.001
            }, "\(label): each light is centred on the row's y = 22 line (frames \(group))")
            let design = TabRowLayout.trafficLightOriginsX
            require(abs(group[0].minX - design[0]) < 0.5
                        && abs(group[1].minX - design[1]) < 0.5
                        && abs(group[2].minX - design[2]) < 0.5,
                    "\(label): the group sits at the row's 20 / 40 / 60 pt origins (frames \(group))")
        }

        /// One main-queue turn for the queued alignment and a little slack for AppKit's
        /// asynchronous titlebar layout, then the invariant.
        func waitForLayout(_ label: String) async throws {
            try await Task.sleep(for: .milliseconds(400))
            requireGroup(label)
        }

        try await waitForLayout("initial 44 pt row")
        require(state.newTab(url: root.appendingPathComponent("tests/fixtures/multipage.pdf")),
                "the check opens a document (lastError: \(state.lastError ?? "nil"))")
        try await eventually("the document is open", { state.document != nil })
        try await waitForLayout("document open")

        // Marking a document dirty makes AppKit re-lay out the titlebar (the edited dot), which
        // is the same native layout pass that Discard triggers when the dot goes away.
        require(state.addGeometryAnnotation(kind: .square, page: 0,
                                            shapeRect: CGRect(x: 40, y: 60, width: 30, height: 30)),
                "an unsaved annotation marks the document dirty")
        require(state.hasUnsavedDocumentChanges, "the document has unsaved changes")
        try await waitForLayout("document dirty")

        state.closeTab(0)
        require(state.contentCloseRequested && state.tabs.count == 1,
                "closing the dirty tab asks Save / Discard / Cancel")
        state.discardContentAndClose()
        require(state.tabs.isEmpty && state.document == nil,
                "Discard closes the last document and its tab")
        try await waitForLayout("last tab closed through Discard")

        // The appearance path shares the layout, and the empty window is the state in which the
        // reader saw the displaced button: a theme change must not move the group.
        for mode in [PaperAppearance.warm, .night, .original] {
            appearance.mode = mode
            try await waitForLayout("theme \(mode.title) with no document")
        }

        // Gaining a document again must restore the same group, so a stale frame from the close
        // cannot hide until the next event.
        require(state.newTab(url: root.appendingPathComponent("tests/fixtures/multipage.pdf")),
                "the window gains a document again (lastError: \(state.lastError ?? "nil"))")
        try await eventually("the second document is open", { state.document != nil })
        try await waitForLayout("document open again")

        // A tab add / close that never asks a save question: open a second tab, close it while
        // the first document is still live, then close the last, clean tab. AppKit re-lays the
        // titlebar on each content change, so these are the paths that do not go through the
        // Save / Discard decision but share its layout.
        require(state.newTab(url: root.appendingPathComponent("tests/fixtures/text-page.pdf")),
                "a second tab opens (lastError: \(state.lastError ?? "nil"))")
        try await eventually("the second tab is live", {
            state.tabs.count == 2 && state.document?.pageCount == 1
        })
        try await waitForLayout("second tab open")
        state.closeTab(1)
        require(state.tabs.count == 1 && state.document != nil,
                "closing the clean second tab keeps the first document")
        try await waitForLayout("second tab closed")
        state.closeTab(0)
        require(state.tabs.isEmpty && state.document == nil,
                "closing the clean last tab needs no save decision")
        try await waitForLayout("clean last tab closed")
        require(state.newTab(url: root.appendingPathComponent("tests/fixtures/multipage.pdf")),
                "the window gains a third document (lastError: \(state.lastError ?? "nil"))")
        try await eventually("the third document is open", { state.document != nil })
        try await waitForLayout("third document open")

        print("PASS: all three traffic lights keep the tab row's geometry through Discard, themes, "
            + "a reloaded document and a clean tab add/close")
    }
}
