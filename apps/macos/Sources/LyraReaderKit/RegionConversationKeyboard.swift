import AppKit
import SwiftUI

/// Window-scoped shortcuts; text editors retain Delete and input-method composition.
struct RegionConversationKeyboard: NSViewRepresentable {
    var collapse: () -> Void
    var delete: () -> Void
    var regionID: UUID
    var enabled: Bool
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.collapse = collapse; view.delete = delete; view.enabled = enabled; view.regionID = regionID
    }
    final class Probe: NSView {
        var collapse: () -> Void = {}
        var delete: () -> Void = {}
        var enabled = true
        var regionID: UUID?
        nonisolated(unsafe) private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.enabled, let window = self.window,
                      event.window === window, window.attachedSheet == nil,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                else { return event }
                let editor = window.firstResponder as? NSTextView
                if event.keyCode == 53 {
                    guard editor?.hasMarkedText() != true else { return event }
                    self.collapse(); return nil
                }
                if event.keyCode == 51 || event.keyCode == 117 {
                    guard editor == nil, !(window.firstResponder is NSTextField) else { return event }
                    guard let focused = window.firstResponder as? NSView else { return event }
                    let cardHost = self.superview?.firstAncestorRegionCardHost()
                    let ownsFocus = cardHost.map { focused === $0 || focused.isDescendant(of: $0) } ?? false
                    let ownsMarker = (focused as? AIRegionMarkerButton)?.regionID == self.regionID
                    guard ownsFocus || ownsMarker else { return event }
                    self.delete(); return nil
                }
                return event
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

private extension NSView {
    func firstAncestorRegionCardHost() -> NSView? {
        var view: NSView? = self
        while let current = view {
            if current is NSHostingView<AIRegionCardView> { return current }
            view = current.superview
        }
        return nil
    }
}
