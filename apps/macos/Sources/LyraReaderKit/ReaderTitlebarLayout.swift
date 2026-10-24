import AppKit

/// The geometry shared by the custom tab row and the native window buttons.
///
/// The traffic lights keep their native views and therefore their native behaviour, but the row
/// owns their position. The values are public because they are asserted directly by the checks:
/// a screenshot can show that a button *looks* close to the edge, only the numbers can show that
/// the distance is the intended one.
public enum TabRowLayout {
    /// Height of the whole tab row. The native titlebar is extended to this height, so the row
    /// and the buttons it contains are the same 44 pt strip.
    public static let height: CGFloat = 44
    /// Distance from the window's left edge to the close button. macOS's own windows put the
    /// button group close to the edge (about 7 pt); PDF Expert gives it room to breathe. 20 pt
    /// restores the proportion the reader asked for and matches the platform's standard 20 pt
    /// content inset, while the 6 pt between buttons still reads as a group.
    public static let trafficLightsLeadingInset: CGFloat = 20
    /// The standard window button's frame on the macOS this was measured on: 14 × 16 pt. The
    /// buttons are native views, so these are documentation for the geometry checks, not
    /// something the layout forces: the leading inset and the 20 pt origin pitch are what the
    /// row owns.
    public static let trafficLightButtonWidth: CGFloat = 14
    public static let trafficLightButtonHeight: CGFloat = 16
    /// Distance between two consecutive button origins. It is deliberately larger than the
    /// visible gap (pitch minus the button's own width), so the group reads as a group.
    public static let trafficLightOriginPitch: CGFloat = 20
    /// Visible gap between two traffic-light buttons (20 pt pitch − 14 pt button width).
    public static var trafficLightSpacing: CGFloat {
        trafficLightOriginPitch - trafficLightButtonWidth
    }
    /// The native buttons are centred in the row, i.e. on y = 22 from the row's top.
    public static let contentCenterY: CGFloat = height / 2
    /// Every interactive part of the row — title, close affordance and plus — is 32 pt high and
    /// centred in the 44 pt row, leaving 6 pt above and below.
    public static let contentHeight: CGFloat = 32
    /// Leading edge of the tab strip when the native titlebar is integrated. This is unchanged
    /// from before the fix: the tabs must not become a narrower strip just because the traffic
    /// lights moved right. 78 pt is the strip inset; the strip itself adds its own 10 pt padding.
    public static let tabStripLeadingInset: CGFloat = 78
    /// Padding inside the tab strip at its left and right edges.
    public static let tabStripHorizontalPadding: CGFloat = 10
    /// Spacing between the tabs.
    public static let tabSpacing: CGFloat = 4
    /// The plus button.
    public static let plusButtonSize: CGFloat = 32
    /// Width of a tab's close button. The 4 pt to its right stays part of the tab's selection
    /// target.
    public static let closeButtonWidth: CGFloat = 24
    /// Right-hand padding that belongs to the tab, not to the close button.
    public static let closeButtonTrailingInset: CGFloat = 4
    /// Minimum and maximum tab widths; a title never participates in a tab's width.
    public static let minimumTabWidth: CGFloat = 96
    public static let maximumTabWidth: CGFloat = 250

    /// Right edge of the last traffic light: 20 + 2 × 20 + 14 = 74 pt.
    public static var trafficLightsTrailingEdge: CGFloat {
        trafficLightsLeadingInset + 2 * trafficLightOriginPitch + trafficLightButtonWidth
    }

    /// Origins of the three traffic-light buttons from the window's left edge: 20 / 40 / 60.
    public static var trafficLightOriginsX: [CGFloat] {
        (0..<3).map { trafficLightsLeadingInset + CGFloat($0) * trafficLightOriginPitch }
    }

    /// A button's y origin inside a 44 pt titlebar, for its own height: (44 − 16) / 2 = 14,
    /// giving a centre at y = 22.
    public static func trafficLightOriginY(
        buttonHeight: CGFloat = trafficLightButtonHeight
    ) -> CGFloat {
        (height - buttonHeight) / 2
    }

    /// Width of the selection part of a tab: everything except the close affordance.
    public static func selectionHitWidth(tabWidth: CGFloat) -> CGFloat {
        max(0, tabWidth - closeButtonWidth - closeButtonTrailingInset)
    }

    /// The close button's rectangle inside a tab, in the tab's local (top-left origin) space.
    public static func closeHitRect(tabWidth: CGFloat) -> CGRect {
        CGRect(x: tabWidth - closeButtonWidth - closeButtonTrailingInset,
               y: 0, width: closeButtonWidth, height: contentHeight)
    }

    /// Whether a point in a tab's local space selects the tab. The 4 pt to the right of the close
    /// button, the 12 pt before the title and the vertical padding are all part of the target.
    public static func isSelectionHit(x: CGFloat, tabWidth: CGFloat) -> Bool {
        x >= 0 && x < tabWidth && !isCloseHit(x: x, tabWidth: tabWidth)
    }

    /// Whether a point in a tab's local space belongs to the close affordance.
    public static func isCloseHit(x: CGFloat, tabWidth: CGFloat) -> Bool {
        let rect = closeHitRect(tabWidth: tabWidth)
        return x >= rect.minX && x < rect.maxX
    }
}

/// Positions the existing AppKit window buttons in the custom tab row. Keeping them in their
/// native view hierarchy preserves their targets, accessibility and full-screen behaviour.
///
/// The placement is deliberately computed from the *frame view's* top edge and the fixed 44 pt
/// row height, never from SwiftUI geometry and never from the content view's bounds. During a
/// live resize those two can be a layout pass apart: deriving the row's top from a content rect
/// whose height is still the previous one, then correcting on the next pass, is exactly what made
/// the buttons visibly jump. The frame view's bounds are settled when the window frame is, and the
/// row height is a constant, so each button's vertical origin is constant ((row height − button
/// height) / 2, currently 14 pt for the 16 pt standard button) while the window's *width* changes.
///
/// AppKit also re-runs its own titlebar layout when the window's effective appearance changes — a
/// system light/dark switch, or SwiftUI applying a reading theme through `preferredColorScheme`.
/// That pass restores the standard 28 pt titlebar and leaves the buttons' local origins where they
/// were, so the group jumps up 16 pt and stays there until something asks for another placement.
/// The effective-appearance observation installed in ``init(window:)`` is what asks.
@MainActor public final class ReaderTitlebarLayout {
    private weak var window: NSWindow?
    private var alignmentPending = false
    private var aligning = false
    private var frameObservers: [NSObjectProtocol] = []
    private var observedViews: [NSView] = []
    private var appearanceObservation: NSKeyValueObservation?

    public init(window: NSWindow) {
        self.window = window
        // AppKit re-runs the native titlebar layout when the window's effective appearance
        // changes: a system light/dark switch, or SwiftUI applying a reading theme through
        // `preferredColorScheme`. That pass restores the standard 28 pt titlebar while the
        // buttons keep the local y they had in our 44 pt row, so the group jumps up and stays
        // there. KVO on `effectiveAppearance` is the public hook for exactly this change (the
        // AppKit headers recommend it for appearance observation); it fires for a per-window
        // appearance and for the inherited application/system one, including a theme change that
        // leaves the resolved appearance the same (it is a new `NSAppearance` either way). The
        // frame observers keep the controls aligned during the appearance transaction, with
        // a queued pass covering AppKit hierarchy replacements after that transaction.
        appearanceObservation = window.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            // KVO delivers on the thread that changed the appearance, and a window's
            // appearance is changed on the main thread.
            MainActor.assumeIsolated {
                self?.alignButtons()
                self?.scheduleAlignment()
            }
        }
        scheduleAlignment()
    }

    isolated deinit {
        appearanceObservation?.invalidate()
        frameObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// AppKit may restore its native frames whenever it lays the titlebar out again (an
    /// appearance transaction, a change to the window's document-edited state, a resize).
    /// Correct those writes synchronously, before the compositor can display the intermediate
    /// 28 pt row, and queue a pass as well: the synchronous correction runs inside AppKit's own
    /// layout, so AppKit can overwrite it for any button it lays out after the notification.
    /// AppKit lays the buttons out in close → miniaturize → zoom order, which is why the last
    /// one (green) was the one left at the native 7 / 27 / 47 pt origins and 6 pt top inset when
    /// the last tab was closed. The queued pass runs after AppKit's layout transaction and
    /// reasserts all three.
    private func observeFrames(_ views: [NSView]) {
        guard observedViews.count != views.count || !zip(observedViews, views).allSatisfy({ $0 === $1 }) else { return }
        frameObservers.forEach(NotificationCenter.default.removeObserver)
        frameObservers = []
        observedViews = views
        for view in views {
            view.postsFrameChangedNotifications = true
            frameObservers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: view, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.alignButtons()
                    self?.scheduleAlignment()
                }
            })
        }
    }

    public func scheduleAlignment() {
        guard !alignmentPending else { return }
        alignmentPending = true
        // AppKit also lays out the standard controls during resize/full-screen transitions.
        // Apply the placement after that layout rather than racing it. The work itself is
        // idempotent and cheap, and it writes only values that actually differ.
        DispatchQueue.main.async { [weak self] in
            self?.alignmentPending = false
            self?.alignButtons()
        }
    }

    /// Applies the placement now. Public so a check can drive the real AppKit hierarchy without
    /// a display; the window's own notifications use `scheduleAlignment`.
    public func alignNow() { alignButtons() }

    private func alignButtons() {
        guard !aligning else { return }
        aligning = true
        defer { aligning = false }
        guard let window, !window.styleMask.contains(.fullScreen),
              let titlebar = window.standardWindowButton(.closeButton)?.superview,
              let container = titlebar.superview, let frameView = container.superview else { return }

        observeFrames([container, titlebar] + [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) })

        // Extend the native hit area to include the whole tab row. Moving only the buttons
        // would leave their lower edges outside the original, shorter native titlebar. The top
        // edge comes from the frame view, not from the content view: during a live resize the
        // content view's bounds and the frame can be one layout pass apart.
        let top = frameView.isFlipped ? frameView.bounds.minY : frameView.bounds.maxY
        let rowY = frameView.isFlipped ? top : top - TabRowLayout.height
        let containerRect = NSRect(x: container.frame.minX,
                                   y: rowY,
                                   width: container.frame.width,
                                   height: TabRowLayout.height)
        if container.frame != containerRect { container.frame = containerRect }
        if titlebar.frame.height != TabRowLayout.height {
            titlebar.setFrameSize(NSSize(width: titlebar.frame.width,
                                         height: TabRowLayout.height))
        }

        // Each button is placed from the fixed row height, not from a parent height that may
        // still be mid-layout. A 44 pt titlebar and a 16 pt button therefore always give y = 14,
        // whether or not a resize or an appearance transition is in flight.
        let originsX = TabRowLayout.trafficLightOriginsX
        for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = window.standardWindowButton(kind), button.superview != nil else { continue }
            let y = TabRowLayout.trafficLightOriginY(buttonHeight: button.frame.height)
            let origin = NSPoint(x: originsX[index], y: y)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }
}
