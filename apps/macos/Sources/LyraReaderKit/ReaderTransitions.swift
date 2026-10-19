import AppKit
import SwiftUI

/// Fixed chrome sizes shared by the transition views and the hosted-window checks.
public enum ReaderChrome {
    /// Content width of the sidebar, before its edge separator.
    public static let sidebarWidthPt: CGFloat = 250
    /// The 1 pt line that marks the sidebar's edge against the canvas.
    public static let sidebarSeparatorWidthPt: CGFloat = 1
    /// Width the layout gives the sidebar while it is fully open.
    public static var sidebarTotalWidthPt: CGFloat { sidebarWidthPt + sidebarSeparatorWidthPt }
    /// The annotation / page-overview row: 32 pt controls plus 7 pt padding above and below.
    public static let secondaryToolbarHeightPt: CGFloat = 46
}

/// Timings and the system motion preference for the reader's two show/hide transitions.
///
/// Both transitions use a cubic ease-out and stay inside the requested 0.18-0.25 s:
///
/// * the sidebar takes `sidebarDuration` (0.22 s). Ease-out starts at its fastest and settles
///   without overshooting, so the panel does not jump past its 251 pt resting width and then
///   come back - an overshoot here shows as a flicker at the canvas edge rather than as spring.
/// * the secondary row takes `secondaryRowDuration` (0.18 s). It is a short reveal of a row
///   whose content is already laid out, so it can be slightly quicker than the sidebar without
///   looking abrupt.
///
/// SwiftUI drives both animations from its display link. A frame of either animation costs a
/// layout pass of the transition views and a canvas resize; it deliberately does **not** ask the
/// engine for a page raster. `AppState.setViewportSize` recognises width-only viewport changes
/// that cannot move the visible page band and skips the band rebuild for them, and coalesces the
/// ones that can, so a slide cannot schedule a raster or a tile per frame.
@MainActor
public enum ReaderMotion {
    public static let sidebarDuration: TimeInterval = 0.22
    public static let secondaryRowDuration: TimeInterval = 0.18

    /// Test seam: `nil` asks the system. The checks pin the setting instead of changing the
    /// reader's accessibility preferences, which belong to the person using the app.
    public static var reduceMotionOverride: Bool?

    public static var reduceMotionEnabled: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public static var sidebarAnimation: Animation? {
        reduceMotionEnabled ? nil : .easeOut(duration: sidebarDuration)
    }

    public static var secondaryRowAnimation: Animation? {
        reduceMotionEnabled ? nil : .easeOut(duration: secondaryRowDuration)
    }
}

/// The sidebar as a sliding drawer whose width also changes the canvas.
///
/// The panel keeps its 250 pt content width for the whole transition. The fixed content (the
/// panel plus its 1 pt separator) is aligned to the trailing edge of a frame whose width animates
/// between 251 and 0, and the overflow is clipped. That gives three properties the naive
/// `if visible { Sidebar }` does not have:
///
/// * the sidebar's own layout does not run at intermediate widths - thumbnails, lists and the
///   tab picker keep their geometry while only the cut edge moves, so nothing reflows per frame;
/// * the separator travels with the content's trailing edge while the panel is partly open;
/// * the canvas gets the remaining width as it changes, so the document's vertical position is
///   untouched and the page simply re-centres horizontally frame by frame.
///
/// The caller owns the animation transaction (`.animation(_, value:)` on the `HStack` that
/// contains this view and the canvas): an animation attached to this child would let the parent
/// allocate the target width on the first frame while only the panel's drawing animated, which
/// makes the canvas jump. Reduce Motion, and a toggle made while the window is resized live,
/// remove the animation at that call site.
struct ReaderSidebarTransition<Content: View>: View {
    let isVisible: Bool
    private let content: Content

    init(isVisible: Bool, @ViewBuilder content: () -> Content) {
        self.isVisible = isVisible
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            content
                .frame(width: ReaderChrome.sidebarWidthPt)
            Rectangle()
                .fill(LyraReaderTheme.separator)
                .frame(width: ReaderChrome.sidebarSeparatorWidthPt)
        }
        .frame(width: ReaderChrome.sidebarTotalWidthPt)
        // Trailing alignment makes the panel slide behind the window's leading edge as the
        // frame closes, instead of being squeezed or re-laid out.
        .frame(width: isVisible ? ReaderChrome.sidebarTotalWidthPt : 0, alignment: .trailing)
        .clipped()
        // A closing panel must not keep the pointer: the width already disables its area, but
        // its content is still in the hierarchy until the animation ends.
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
    }
}

/// The annotation / page-overview row as an overlay on the content.
///
/// The row is laid out once at its full height and the container's height animates from 46 to 0
/// with the content top-aligned and clipped. The controls therefore never see a shorter proposal:
/// they do not squash, reflow or change their labels while the row expands.
///
/// The background and the row itself are inside the clipped container, so the overlay covers
/// exactly the revealed height. `contentShape` makes that whole rectangle hit-testable, which is
/// what keeps a click on the overlay from reaching the canvas underneath; outside the rectangle
/// the canvas still receives the click.
struct ReaderSecondaryToolbarTransition<Content: View>: View {
    let isVisible: Bool
    private let content: Content

    init(isVisible: Bool, @ViewBuilder content: () -> Content) {
        self.isVisible = isVisible
        self.content = content()
    }

    var body: some View {
        content
            .frame(height: ReaderChrome.secondaryToolbarHeightPt)
            .frame(maxWidth: .infinity)
            .frame(height: isVisible ? ReaderChrome.secondaryToolbarHeightPt : 0, alignment: .top)
            .clipped()
            .contentShape(Rectangle())
            .allowsHitTesting(isVisible)
            // A collapsed row is still in the hierarchy at zero height; keep its controls out of
            // the accessibility tree for the same reason its hit area is off.
            .accessibilityHidden(!isVisible)
    }
}

/// Reports whether the window is being resized live.
///
/// A zero-size, hit-test-transparent probe; it only observes. The notification handlers hand the
/// value to the next main-queue turn because they can run while SwiftUI is updating the view that
/// owns the binding.
struct WindowLiveResizeReporter: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ReporterView {
        let view = ReporterView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReporterView, context: Context) {
        view.onChange = onChange
    }

    static func dismantleNSView(_ view: ReporterView, coordinator: ()) {
        view.stopObserving()
    }

    final class ReporterView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            let center = NotificationCenter.default
            let events: [(NSNotification.Name, Bool)] = [
                (NSWindow.willStartLiveResizeNotification, true),
                (NSWindow.didEndLiveResizeNotification, false),
            ]
            for (name, value) in events {
                observers.append(center.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report(value) }
                })
            }
            report(window.inLiveResize)
        }

        func stopObserving() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
        }

        private func report(_ value: Bool) {
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(value)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
