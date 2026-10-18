import AppKit
import ArisReaderKit
import Foundation
import SwiftUI

extension ReaderChecks {
    /// The traffic lights must not move when the reading theme or the system appearance changes.
    ///
    /// **The defect this pins.** Applying a reading theme makes SwiftUI set the window's
    /// appearance (Original inherits the system one, Warm Paper forces light, Night Reading forces
    /// dark). AppKit responds by laying the native titlebar out again at its standard 28 pt height,
    /// while the traffic lights keep the y origin they had in the 44 pt row. The group therefore
    /// sits 16 pt too high and stays there: a resize, a full-screen exit and becoming key were the
    /// only events that re-ran ``ReaderTitlebarLayout``, and none of them happens on a theme
    /// change. Clicking another application and back does, which is why the focus round trip
    /// corrected it.
    ///
    /// The frames are captured in the *window's* coordinate space, not in the button's parent:
    /// the parent is the titlebar view that AppKit shrinks, so its local frames look unchanged
    /// while the buttons visibly move. Each theme change is also compared with what a simulated
    /// focus round trip produces, which is the defect in one line.
    ///
    /// The theme is changed through ``ReadingAppearanceStore/shared`` — the same object the
    /// View > Paper Appearance menu binds to — and the system appearance through
    /// `NSApplication.appearance`, so neither path uses a private setter.
    @MainActor static func titlebarThemeChecks(root: URL) async throws {
        _ = NSApplication.shared
        let appearance = ReadingAppearanceStore.shared
        let savedMode = appearance.mode
        let savedApplicationAppearance = NSApp.appearance
        let savedReduceMotion = ReaderMotion.reduceMotionOverride
        defer {
            appearance.mode = savedMode
            NSApp.appearance = savedApplicationAppearance
            ReaderMotion.reduceMotionOverride = savedReduceMotion
        }
        // Pin the drawer animation on so "while the sidebar is animating" is a real animation,
        // even on a machine where Reduce Motion would otherwise remove it.
        ReaderMotion.reduceMotionOverride = false

        appearance.mode = .original
        NSApp.appearance = NSAppearance(named: .aqua)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let registry = ReaderWindowRegistry()
        let state = AppState(engine: PreviewEngine())
        let session = ReaderSession(state: state, registry: registry)
        window.contentView = NSHostingView(rootView: ReaderWindow(
            state: session.state,
            opener: session.opener,
            previewPanels: session.previewPanels,
            integratesTitlebar: true
        ))
        // The session is the real wiring: it installs the traffic-light layout and the resize,
        // full-screen and focus observers, and it puts the window into the same chrome the app
        // uses (transparent titlebar, hidden title, no separator).
        session.attach(window: window)
        defer {
            window.orderOut(nil)
            session.close()
        }

        // A real document, so the sidebar exists in its animated drawer form and the document
        // open path can be exercised below.
        require(session.state.newTab(url: root.appendingPathComponent("tests/fixtures/multipage.pdf")),
                "the theme change check opens a document")

        func buttons() -> [NSButton] {
            [.closeButton, .miniaturizeButton, .zoomButton].compactMap {
                window.standardWindowButton($0)
            }
        }
        /// The buttons' frames in the window coordinate space. This is deliberately not
        /// `button.frame`: that is relative to the titlebar view AppKit resets on an appearance
        /// change, and its height shrinking is exactly what moves the buttons on screen.
        func buttonFrames() -> [NSRect] {
            buttons().map { $0.convert($0.bounds, to: nil) }
        }
        func titlebarHeight() -> CGFloat {
            window.standardWindowButton(.closeButton)?.superview?.frame.height ?? -1
        }
        func systemAppearanceName() -> NSAppearance.Name {
            NSApp.appearance?.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
        }
        func expectedAppearance(for mode: PaperAppearance) -> NSAppearance.Name {
            switch mode {
            case .original: systemAppearanceName()
            case .warm: .aqua
            case .night: .darkAqua
            }
        }
        func effectiveAppearanceName() -> NSAppearance.Name {
            window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
        }

        // The initial alignment is queued for the next main-queue turn; wait for it to settle.
        try await eventually("the traffic lights are placed in the 44 pt tab row", {
            titlebarHeight() == TabRowLayout.height
        })
        try await Task.sleep(for: .milliseconds(200))
        let baseFrames = buttonFrames()
        require(baseFrames.map(\.origin.x) == TabRowLayout.trafficLightOriginsX,
                "the base theme puts the group at 20 / 40 / 60 pt")

        if let nativeTitlebar = window.standardWindowButton(.closeButton)?.superview {
            nativeTitlebar.setFrameSize(NSSize(width: nativeTitlebar.frame.width, height: 28))
            require(titlebarHeight() == TabRowLayout.height && buttonFrames() == baseFrames,
                    "an AppKit titlebar reset is corrected synchronously before the next displayed frame")
        }

        func requirePlacement(_ label: String, frames: [NSRect], base: [NSRect]) {
            require(frames.count == 3, "\(label): all three traffic lights are present")
            require(frames == base,
                    "\(label): the traffic lights did not move (base \(base), current \(frames))")
            require(titlebarHeight() == TabRowLayout.height,
                    "\(label): the native titlebar is back to the 44 pt row")
            require(frames.allSatisfy {
                abs((window.frame.height - $0.midY) - TabRowLayout.contentCenterY) < 0.001
            }, "\(label): each button is centred on the row's y = 22 line")
        }

        /// Changes the theme, lets the appearance transition and its layout settle, then compares
        /// the new frames with the base frames and with what a focus round trip produces.
        func checkTheme(_ mode: PaperAppearance, label: String) async throws {
            appearance.mode = mode
            let expected = expectedAppearance(for: mode)
            for _ in 0..<80 where effectiveAppearanceName() != expected {
                try await Task.sleep(for: .milliseconds(25))
            }
            require(effectiveAppearanceName() == expected,
                    "\(label): \(mode.title) reaches the window appearance \(expected.rawValue)")
            // One main-queue turn (and a little slack) for AppKit's appearance layout and the
            // alignment it schedules.
            try await Task.sleep(for: .milliseconds(200))

            let themeFrames = buttonFrames()
            // The same hook that a focus round trip uses: ReaderSession observes
            // `NSWindow.didBecomeKeyNotification` and asks the layout to place the buttons.
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            try await Task.sleep(for: .milliseconds(150))
            let focusedFrames = buttonFrames()

            require(themeFrames == focusedFrames,
                    "\(label): \(mode.title) leaves the buttons where a focus round trip puts them "
                    + "(theme \(themeFrames), focus \(focusedFrames))")
            requirePlacement("\(label): \(mode.title)", frames: themeFrames, base: baseFrames)
        }

        // All three themes under both system appearances, returning to Original each time.
        for system in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: system)
            try await Task.sleep(for: .milliseconds(250))
            requirePlacement("system appearance \(system.rawValue) with Original",
                             frames: buttonFrames(), base: baseFrames)
            for mode in [PaperAppearance.warm, .night, .original] {
                try await checkTheme(mode, label: "system \(system.rawValue)")
            }
        }

        // A theme change while a document is opening: PreviewEngine takes ~160 ms to render the
        // first page, so the change lands in the middle of the open.
        appearance.mode = .original
        try await Task.sleep(for: .milliseconds(250))
        require(session.state.newTab(url: root.appendingPathComponent("tests/fixtures/text-page.pdf")),
                "a second document starts opening")
        appearance.mode = .warm
        try await Task.sleep(for: .milliseconds(80))
        requirePlacement("theme change while a document is opening",
                         frames: buttonFrames(), base: baseFrames)
        try await Task.sleep(for: .milliseconds(400))
        requirePlacement("theme change finished while the document opened",
                         frames: buttonFrames(), base: baseFrames)

        // A theme change in the first 80 ms of the 220 ms sidebar drawer animation.
        session.state.sidebarVisible = false
        try await Task.sleep(for: .milliseconds(300))
        requirePlacement("sidebar closed", frames: buttonFrames(), base: baseFrames)
        session.state.sidebarVisible = true
        appearance.mode = .night
        try await Task.sleep(for: .milliseconds(80))
        requirePlacement("theme change while the sidebar is animating",
                         frames: buttonFrames(), base: baseFrames)
        try await Task.sleep(for: .milliseconds(300))
        requirePlacement("theme change after the sidebar animation settled",
                         frames: buttonFrames(), base: baseFrames)

        // The contextual row is the other animated transition (`annotationToolsVisible`). A theme
        // change during its 180 ms reveal must not move the buttons either.
        session.state.annotationToolsVisible = true
        appearance.mode = .warm
        try await Task.sleep(for: .milliseconds(60))
        requirePlacement("theme change while the secondary toolbar is animating",
                         frames: buttonFrames(), base: baseFrames)
        try await Task.sleep(for: .milliseconds(300))
        requirePlacement("theme change after the secondary toolbar settled",
                         frames: buttonFrames(), base: baseFrames)

        print("PASS: traffic lights hold their place across themes, appearances, opening and "
            + "sidebar/toolbar motion")
    }
}
