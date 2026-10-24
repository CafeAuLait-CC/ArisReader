import AppKit
import SwiftUI

/// Native frame probes let regression checks measure the chrome SwiftUI actually lays out.
package final class ReaderChromeMarkerView: NSView {
    package enum Kind {
        case secondaryToolbar
        case secondaryRowSlot
        case editingInspector
        case editingInspectorSlot
        case fillSignInspector
        case fillSignInspectorSlot
    }
    package let kind: Kind
    init(kind: Kind) { self.kind = kind; super.init(frame: .zero) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

struct ReaderChromeMarkerHost: NSViewRepresentable {
    let kind: ReaderChromeMarkerView.Kind
    func makeNSView(context: Context) -> ReaderChromeMarkerView { ReaderChromeMarkerView(kind: kind) }
    func updateNSView(_ view: ReaderChromeMarkerView, context: Context) {}
}

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
    public static let editingPanelWidthPt: CGFloat = 292
    /// Width of the scroll indicator's lane at the canvas's trailing edge.
    ///
    /// The indicator is a sibling of the canvas rather than an overlay, so this strip is real
    /// layout: the page, Fit Width and the pointer anchor all use the canvas width *without* it,
    /// and the right panel starts after it. The lane is only present while a document is open.
    public static let scrollIndicatorLaneWidthPt: CGFloat = 13

    /// Trailing panels the secondary toolbar must avoid.
    ///
    /// The secondary toolbar covers the scroll lane and stops flush against search results or
    /// the right panel. Page overview covers the whole
    /// content area, so it has no trailing chrome to avoid. Kept as a pure function so the
    /// checks can assert the overlay's arithmetic without a screenshot.
    public static func trailingChromeWidth(
        documentOpen: Bool,
        pageOverviewVisible: Bool,
        searchVisible: Bool,
        rightPanelVisible: Bool,
        rightPanelContentWidth: CGFloat
    ) -> CGFloat {
        guard documentOpen, !pageOverviewVisible else { return 0 }
        var width: CGFloat = 0
        if searchVisible { width += sidebarTotalWidthPt }
        if rightPanelVisible {
            width += ReaderSidePanelMetrics.totalWidth(contentWidth: rightPanelContentWidth)
        }
        return width
    }
}

/// A deterministic progress override for the drawer and row transitions, used only by the native
/// checks.
///
/// SwiftUI's animation is driven by the display link: a check that samples a real animation on a
/// wall clock can miss every intermediate frame on a loaded runner, which is exactly how the
/// sidebar close check once failed in CI. The app never sets this; the checks pin a progress and
/// step it, so "the panel is partly open" is an observed layout at a known value instead of a
/// race with the display link.
public struct ReaderTransitionProgress: Equatable, Sendable {
    /// 0 is closed, 1 is fully open. `nil` means "use `isVisible` and animate normally".
    public var sidebar: Double?
    /// 0 is collapsed, 1 is the full 46 pt row.
    public var row: Double?
    /// 0 is closed, 1 is the full right panel. `nil` means "use `isVisible` and animate normally".
    public var panel: Double?
    public var editingPanel: Double?

    public init(sidebar: Double? = nil, row: Double? = nil, panel: Double? = nil, editingPanel: Double? = nil) {
        self.sidebar = sidebar
        self.row = row
        self.panel = panel
        self.editingPanel = editingPanel
    }
}

/// Timings and the system motion preference for the reader's show/hide transitions.
///
/// All of them use a cubic ease-out and stay inside the requested 0.18-0.25 s:
///
/// * the sidebar takes `sidebarDuration` (0.22 s). Ease-out starts at its fastest and settles
///   without overshooting, so the panel does not jump past its 251 pt resting width and then
///   come back - an overshoot here shows as a flicker at the canvas edge rather than as spring.
/// * the secondary row takes `secondaryRowDuration` (0.18 s). It is a short reveal of a row
///   whose content is already laid out, so it can be slightly quicker than the sidebar without
///   looking abrupt.
/// * the right panel takes `panelDuration`, which is the sidebar's duration: the two drawers can
///   be toggled together and must not read as different pieces of furniture.
///
/// SwiftUI drives the animations from its display link. A frame of any animation costs a layout
/// pass of the transition views and a canvas resize; it deliberately does **not** ask the engine
/// for a page raster. `AppState.setViewportSize` recognises width-only viewport changes that
/// cannot move the visible page band and skips the band rebuild for them, coalesces the ones
/// that can, and holds a moving right panel's updates until it settles, so a slide cannot
/// schedule a raster or a tile per frame.
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

    /// The right panel uses the sidebar's duration and curve, not a second timing language: the
    /// two drawers can be toggled together and must not look like different pieces of furniture.
    public static var panelDuration: TimeInterval { sidebarDuration }

    public static var panelAnimation: Animation? {
        reduceMotionEnabled ? nil : .easeOut(duration: panelDuration)
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
    private let progressOverride: Double?
    private let content: Content

    init(isVisible: Bool, progressOverride: Double? = nil,
         @ViewBuilder content: () -> Content) {
        self.isVisible = isVisible
        self.progressOverride = progressOverride
        self.content = content()
    }

    /// The width the drawer should occupy. A test override wins over the boolean so the checks
    /// can lay out and measure a known intermediate state without waiting for a display link.
    private var progress: CGFloat {
        if let progressOverride {
            return CGFloat(min(max(progressOverride, 0), 1))
        }
        return isVisible ? 1 : 0
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
        .frame(width: ReaderChrome.sidebarTotalWidthPt * progress, alignment: .trailing)
        .clipped()
        // A closing panel must not keep the pointer: the width already disables its area, but
        // its content is still in the hierarchy until the animation ends.
        .allowsHitTesting(isVisible || progressOverride != nil)
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
    private let progressOverride: Double?
    private let content: Content

    init(isVisible: Bool, progressOverride: Double? = nil,
         @ViewBuilder content: () -> Content) {
        self.isVisible = isVisible
        self.progressOverride = progressOverride
        self.content = content()
    }

    private var progress: CGFloat {
        if let progressOverride {
            return CGFloat(min(max(progressOverride, 0), 1))
        }
        return isVisible ? 1 : 0
    }

    var body: some View {
        content
            .offset(y: -ReaderChrome.secondaryToolbarHeightPt * (1 - progress))
            .frame(height: ReaderChrome.secondaryToolbarHeightPt)
            .frame(maxWidth: .infinity)
            .frame(height: ReaderChrome.secondaryToolbarHeightPt * progress, alignment: .top)
            .clipped()
            .contentShape(Rectangle())
            .allowsHitTesting(isVisible || progressOverride != nil)
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
