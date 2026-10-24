import AppKit
import SwiftUI

/// Styles only scroll views inside this panel, without changing the user's scrollbar preference.
struct SidebarScrollTheme: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.scheduleUpdate() }

    final class Probe: NSView {
        private var updatePending = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleUpdate() }
        override func layout() { super.layout(); scheduleUpdate() }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance(); scheduleUpdate()
        }

        func scheduleUpdate() {
            guard !updatePending else { return }
            updatePending = true
            // SwiftUI installs/reconfigures its HostingScrollView after the representable's
            // update. Apply once that layout transaction has committed, so its native scroller
            // configuration cannot immediately replace our themed scroller.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                guard let self else { return }
                self.updatePending = false
                guard let root = self.window?.contentView, !self.bounds.isEmpty else { return }
                root.layoutSubtreeIfNeeded()
                self.styleScrollViews(in: root)
            }
        }

        private func styleScrollViews(in view: NSView) {
            if let scroll = view as? NSScrollView {
                let frame = convert(scroll.bounds, from: scroll)
                if bounds.insetBy(dx: -1, dy: -1).contains(CGPoint(x: frame.midX, y: frame.midY)) {
                    LyraReaderSidebarScroller.install(on: scroll)
                }
            }
            for child in view.subviews { styleScrollViews(in: child) }
        }
    }
}

/// Native scrolling, tracking and accessibility, with the palette's track and thumb colors.
package final class LyraReaderSidebarScroller: NSScroller {
    package var transparentTrack = false { didSet { needsDisplay = true } }
    private var hovered = false
    private var hoverTracking: NSTrackingArea?
    override package class var isCompatibleWithOverlayScrollers: Bool { true }

    package static func install(on scroll: NSScrollView) {
        if !(scroll.verticalScroller is LyraReaderSidebarScroller) {
            let old = scroll.verticalScroller
            let replacement = LyraReaderSidebarScroller(frame: old?.frame
                ?? CGRect(x: 0, y: 0, width: 16, height: max(17, scroll.bounds.height)))
            if let old {
                replacement.controlSize = old.controlSize
                replacement.floatValue = old.floatValue
                replacement.knobProportion = old.knobProportion
                replacement.isEnabled = old.isEnabled
                replacement.scrollerStyle = old.scrollerStyle
                replacement.target = old.target
                replacement.action = old.action
            }
            scroll.verticalScroller = replacement
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        scroll.verticalScroller?.needsDisplay = true
    }

    override package func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // Overlay tracks reveal the panel underneath; legacy tracks occupy their own gutter.
        if scrollerStyle == .legacy && !transparentTrack {
            LyraReaderTheme.sidebarColor.setFill()
            bounds.fill()
        }
    }

    override package func drawKnob() {
        let knob = rect(for: .knob).insetBy(dx: 3, dy: 1)
        guard !knob.isEmpty else { return }
        (hovered ? LyraReaderTheme.scrollThumbHoverColor : LyraReaderTheme.scrollThumbColor).setFill()
        NSBezierPath(roundedRect: knob, xRadius: knob.width / 2, yRadius: knob.width / 2).fill()
    }

    override package func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }
    override package func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hovered = true; needsDisplay = true
    }
    override package func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hovered = false; needsDisplay = true
    }
}
