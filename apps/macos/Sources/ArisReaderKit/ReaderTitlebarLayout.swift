import AppKit

/// Positions the existing AppKit window buttons in the custom tab row. Keeping them in their
/// native view hierarchy preserves their targets, accessibility and full-screen behaviour.
@MainActor final class ReaderTitlebarLayout {
    private weak var window: NSWindow?
    private var alignmentPending = false

    init(window: NSWindow) {
        self.window = window
        scheduleAlignment()
    }

    func scheduleAlignment() {
        guard !alignmentPending else { return }
        alignmentPending = true
        // AppKit also lays out the standard controls during resize/full-screen transitions.
        // Apply the placement after that layout rather than racing it.
        DispatchQueue.main.async { [weak self] in
            self?.alignmentPending = false
            self?.alignButtons()
        }
    }

    private func alignButtons() {
        guard let window, !window.styleMask.contains(.fullScreen),
              let content = window.contentView,
              let titlebar = window.standardWindowButton(.closeButton)?.superview,
              let container = titlebar.superview, let frameView = container.superview else { return }

        // Extend the native hit area to include the whole tab row. Moving only the buttons
        // would leave their lower edges outside the original, shorter native titlebar.
        let contentRect = frameView.convert(content.bounds, from: content)
        let containerRect = NSRect(x: container.frame.minX,
                                   y: contentRect.maxY - TabStrip.height,
                                   width: container.frame.width, height: TabStrip.height)
        if container.frame != containerRect { container.frame = containerRect }
        if titlebar.frame.height != TabStrip.height {
            titlebar.setFrameSize(NSSize(width: titlebar.frame.width, height: TabStrip.height))
        }
        let centerY = content.isFlipped
            ? content.bounds.minY + TabStrip.height / 2
            : content.bounds.maxY - TabStrip.height / 2
        let center = NSPoint(x: 0, y: centerY)
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind), let parent = button.superview else { continue }
            let y = parent.convert(center, from: content).y - button.frame.height / 2
            let origin = NSPoint(x: button.frame.minX, y: y)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }
}
