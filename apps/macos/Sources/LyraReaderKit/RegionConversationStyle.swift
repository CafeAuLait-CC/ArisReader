import AppKit
import SwiftUI

public enum RegionConversationStyle: String, CaseIterable, Identifiable {
    case window, parchment
    public static let preferenceKey = "lyra.regionConversationStyle"
    public var id: String { rawValue }
    public var title: String { self == .window ? "Window" : "Parchment" }
}

/// Finds only the containing transcript scroll view. Horizontal code blocks keep their own
/// native scrolling; this does not walk or recolour unrelated reader panels.
struct RegionTranscriptScrollTheme: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.schedule() }
    final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }
        override func layout() { super.layout(); schedule() }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); schedule() }
        private var pending = false
        func schedule() {
            guard !pending else { return }; pending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.pending = false
                var parent = self.superview
                while let view = parent {
                    if let scroll = view as? NSScrollView {
                        scroll.drawsBackground = false
                        scroll.contentView.drawsBackground = false
                        LyraReaderSidebarScroller.install(on: scroll)
                        (scroll.verticalScroller as? LyraReaderSidebarScroller)?.transparentTrack = true
                        return
                    }
                    parent = view.superview
                }
            }
        }
    }
}
