import AppKit
import QuartzCore

/// The in-place translation layer.
///
/// It sits above the page raster and the annotation layer, and below the region marquee. The
/// drawing is deliberately plain AppKit: a paper-coloured rectangle and the translated text for
/// every visible block, plus one small control chip per block. Nothing here touches the page
/// bitmap, so removing an overlay reveals exactly the pixels that were under it.
final class TranslationOverlayView: NSView {
    var onToggle: ((String) -> Void)?
    var onCancel: ((String) -> Void)?

    private var overlays: [TranslationOverlay] = []
    private var frames: [Int: PagePlacement] = [:]
    private var zoom: CGFloat = 1
    private var scrollYPt: CGFloat = 0
    private var contentWidthPt: CGFloat = 0
    private var paperAppearance: PaperAppearance = .original
    private var paperColors: [Int: TranslationPaperColor] = [:]
    private var chips: [String: TranslationChipView] = [:]
    /// Chips that had no room outside their block and were placed in its top-right corner.
    /// Their height is reserved out of the text rectangle, so the chip never covers the
    /// translated words it belongs to even at extreme zoom.
    private var insideChips: Set<String> = []

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("TranslationOverlayView is programmatic") }

    /// Consume a click only on a chip. Everywhere else the canvas keeps its pointer events.
    override func hitTest(_ point: NSPoint) -> NSView? {
        for chip in chips.values where !chip.isHidden && chip.frame.contains(point) {
            return chip.hitTest(convert(point, to: chip))
        }
        return nil
    }

    func update(overlays: [TranslationOverlay], frames: [PagePlacement], zoom: CGFloat,
                scrollYPt: CGFloat, contentWidthPt: CGFloat,
                paperAppearance: PaperAppearance,
                paperColors: [Int: TranslationPaperColor] = [:]) {
        let framesChanged = frames != self.frames.values.sorted { $0.index < $1.index }
        let overlaysChanged = overlays != self.overlays
        let viewChanged = zoom != self.zoom || scrollYPt != self.scrollYPt
            || contentWidthPt != self.contentWidthPt || framesChanged
            || paperAppearance != self.paperAppearance
            || paperColors != self.paperColors
        self.overlays = overlays
        self.frames = Dictionary(uniqueKeysWithValues: frames.map { ($0.index, $0) })
        self.zoom = zoom
        self.scrollYPt = scrollYPt
        self.contentWidthPt = contentWidthPt
        self.paperAppearance = paperAppearance
        self.paperColors = paperColors
        if overlaysChanged || viewChanged {
            rebuildChips()
            needsDisplay = true
        }
    }

    /// Page-local (100%) rectangle → this view's coordinates. Content is centred exactly as the
    /// canvas centres it, and the scroll offset is applied before the zoom, matching
    /// `PageChromeGeometry` and the annotation overlay.
    func viewRect(page: Int, rect: CGRect) -> CGRect? {
        guard let frame = frames[page] else { return nil }
        let offsetX = max(0, (bounds.width - contentWidthPt * zoom) / 2)
        return CGRect(
            x: offsetX + (frame.leftPt + rect.minX) * zoom,
            y: (frame.topPt + rect.minY - scrollYPt) * zoom,
            width: rect.width * zoom,
            height: rect.height * zoom
        )
    }

    // MARK: - Check accessors

    /// Number of controls currently shown. A block scrolled off screen contributes zero.
    var visibleChipCount: Int { chips.values.filter { !$0.isHidden }.count }

    /// The chip rectangle for one overlay, in this view's coordinates. Nil when hidden.
    func chipFrameForCheck(_ id: String) -> CGRect? {
        guard let chip = chips[id], !chip.isHidden else { return nil }
        return chip.frame
    }

    /// The block rectangle for one overlay, in this view's coordinates.
    func blockFrameForCheck(_ id: String) -> CGRect? {
        guard let overlay = overlays.first(where: { $0.id == id }) else { return nil }
        return viewRect(page: overlay.page, rect: overlay.rect)
    }

    private func rebuildChips() {
        var live: Set<String> = []
        for overlay in overlays {
            guard let block = viewRect(page: overlay.page, rect: overlay.rect),
                  block.intersects(bounds.insetBy(dx: -1, dy: -1)) else {
                continue
            }
            live.insert(overlay.id)
            let overlayID = overlay.id
            let chip = chips[overlayID] ?? {
                let chip = TranslationChipView()
                chip.onPrimary = { [weak self] in self?.onToggle?(overlayID) }
                chip.onCancel = { [weak self] in self?.onCancel?(overlayID) }
                chip.onDisclose = { [weak self, weak chip] in
                    guard let self, let chip,
                          let current = self.overlays.first(where: { $0.id == overlayID }) else {
                        return
                    }
                    self.presentDisclosure(current, from: chip)
                }
                chips[overlayID] = chip
                addSubview(chip)
                return chip
            }()
            chip.configure(overlay)
            let size = chip.preferredSize()
            let placement = chipFrame(block: block, size: size)
            chip.frame = placement.frame
            insideChips.remove(overlay.id)
            if placement.inside { insideChips.insert(overlay.id) }
            chip.isHidden = false
        }
        for (id, chip) in chips where !live.contains(id) {
            chip.removeFromSuperview()
            chips.removeValue(forKey: id)
            insideChips.remove(id)
        }
    }

    /// Candidate positions, in order: to the right of the block, above it, below it, to the
    /// left. A candidate must be fully inside the canvas and must not intersect the block.
    /// When no such candidate exists (a paragraph wider than the viewport at deep zoom), the
    /// chip goes into the block's top-right corner and the text drawing reserves the chip's
    /// height, so it still does not cover the translation.
    private func chipFrame(block: CGRect, size: CGSize) -> (frame: CGRect, inside: Bool) {
        let gap: CGFloat = 4
        let margin: CGFloat = 4
        let viewport = bounds.insetBy(dx: margin, dy: margin)
        let candidates = [
            CGRect(x: block.maxX + gap, y: block.minY, width: size.width, height: size.height),
            CGRect(x: block.maxX - size.width, y: block.minY - size.height - gap,
                   width: size.width, height: size.height),
            CGRect(x: block.maxX - size.width, y: block.maxY + gap,
                   width: size.width, height: size.height),
            CGRect(x: block.minX - size.width - gap, y: block.minY,
                   width: size.width, height: size.height),
        ]
        let blockHit = block.insetBy(dx: -1, dy: -1)
        for candidate in candidates {
            let clamped = clamp(candidate, to: viewport)
            if viewport.contains(clamped) && !clamped.intersects(blockHit) {
                return (clamped, false)
            }
        }
        // The reader still needs the control. Put it in the cover's own top-right corner and
        // reserve that strip out of the text layout (see `reservedTop`).
        let inside = clamp(
            CGRect(x: block.maxX - size.width - 2, y: block.minY + 2,
                   width: size.width, height: size.height),
            to: viewport
        )
        return (inside, true)
    }

    private func clamp(_ rect: CGRect, to viewport: CGRect) -> CGRect {
        var result = rect
        result.origin.x = min(max(result.minX, viewport.minX), max(viewport.minX, viewport.maxX - result.width))
        result.origin.y = min(max(result.minY, viewport.minY), max(viewport.minY, viewport.maxY - result.height))
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setShouldAntialias(true)
        for overlay in overlays {
            guard overlay.phase == .translated,
                  let block = viewRect(page: overlay.page, rect: overlay.rect),
                  block.intersects(bounds.insetBy(dx: -1, dy: -1)) else { continue }
            let paper = paperColors[overlay.page] ?? overlay.paperColor
                ?? .forAppearance(paperAppearance)
            context.setFillColor(paper.nsColor.cgColor)
            context.fill(block)

            guard let translated = overlay.translatedText, !translated.isEmpty else { continue }
            let fit = overlay.fit ?? TranslationTextLayout.fit(
                text: translated, in: overlay.rect, sourceFontPt: overlay.sourceFontPt)
            let insetX = TranslationTextLayout.horizontalInsetPt * zoom
            let insetY = TranslationTextLayout.verticalInsetPt * zoom
            var textRect = block.insetBy(dx: insetX, dy: insetY)
            if insideChips.contains(overlay.id), let chip = chips[overlay.id] {
                let top = chip.frame.maxY + 2
                if top > textRect.minY {
                    textRect = CGRect(x: textRect.minX, y: top, width: textRect.width,
                                      height: max(0, textRect.maxY - top))
                }
            }
            guard textRect.width > 1, textRect.height > 0.5 else { continue }

            let font = NSFont.systemFont(ofSize: max(0.5, fit.fontSizePt * zoom))
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineSpacing = 0
            paragraph.paragraphSpacing = 0
            let attributed = NSAttributedString(
                string: translated,
                attributes: [
                    .font: font,
                    .foregroundColor: paper.inkColor,
                    .paragraphStyle: paragraph,
                ]
            )
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: textRect).addClip()
            attributed.draw(
                with: textRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading,
                          .truncatesLastVisibleLine]
            )
            NSGraphicsContext.restoreGraphicsState()
        }
        context.restoreGState()
    }

    // MARK: - Disclosure

    private var disclosurePopover: NSPopover?

    private func presentDisclosure(_ overlay: TranslationOverlay, from chip: TranslationChipView) {
        guard let text = overlay.translatedText, !text.isEmpty else { return }
        disclosurePopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let controller = TranslationDisclosureController(
            title: overlay.isBlock ? "Full translation" : "Full translation of the selection",
            text: text,
            source: overlay.sourceText
        )
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 440, height: 260)
        popover.show(relativeTo: chip.bounds, of: chip, preferredEdge: .maxY)
        disclosurePopover = popover
    }
}

/// The small control next to a translated block: Show original / Translate, plus Cancel while a
/// request is in flight and a disclosure when the fitted text was clipped.
final class TranslationChipView: NSView {
    var onPrimary: (() -> Void)?
    var onCancel: (() -> Void)?
    var onDisclose: (() -> Void)?

    private let primary = NSButton()
    private let cancel = NSButton()
    private let disclose = NSButton()
    private var primaryAction: (() -> Void)?
    private var cancelAction: (() -> Void)?
    private var discloseAction: (() -> Void)?

    static let height: CGFloat = 20
    static let font = NSFont.systemFont(ofSize: 10, weight: .medium)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 0.5
        layer?.masksToBounds = false
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.97).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.8).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 2
        layer?.shadowOffset = CGSize(width: 0, height: 1)
        configure(primary, size: 10, weight: .medium)
        configure(cancel, size: 11, weight: .semibold)
        configure(disclose, size: 11, weight: .semibold)
        cancel.title = "×"
        disclose.title = "⋯"
        cancel.target = self
        cancel.action = #selector(cancelPressed)
        disclose.target = self
        disclose.action = #selector(disclosePressed)
        primary.target = self
        primary.action = #selector(primaryPressed)
        addSubview(primary)
        addSubview(cancel)
        addSubview(disclose)
        cancel.toolTip = "Cancel this translation"
        cancel.setAccessibilityLabel("Cancel translation")
        disclose.toolTip = "Show the full translation that did not fit"
        disclose.setAccessibilityLabel("Show full translation")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("TranslationChipView is programmatic") }

    private func configure(_ button: NSButton, size: CGFloat, weight: NSFont.Weight) {
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = NSFont.systemFont(ofSize: size, weight: weight)
        button.contentTintColor = .labelColor
        button.focusRingType = .none
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.97).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.8).cgColor
        for button in [primary, cancel, disclose] {
            button.contentTintColor = .labelColor
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.withAlphaComponent(0.97).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        NSColor.separatorColor.withAlphaComponent(0.8).setStroke()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25),
                                   xRadius: 5, yRadius: 5)
        outline.lineWidth = 0.5
        outline.stroke()
    }

    func configure(_ overlay: TranslationOverlay) {
        let title: String
        var showCancel = false
        var showDisclose = false
        var primaryEnabled = true
        switch overlay.phase {
        case .translating:
            title = "Translating…"
            primaryEnabled = false
            showCancel = true
            primary.setAccessibilityLabel("Translating")
        case .translated:
            title = "Show original"
            showDisclose = overlay.isClipped
            primary.setAccessibilityLabel("Show original text")
        case .original:
            title = "Translate"
            primary.setAccessibilityLabel("Show the cached translation")
        case .failed(let message):
            title = "Retry translation"
            primary.toolTip = message
            primary.setAccessibilityLabel("Retry translation")
        }
        primary.title = title
        primary.isEnabled = primaryEnabled
        primaryAction = onPrimary
        cancelAction = onCancel
        discloseAction = onDisclose
        cancel.isHidden = !showCancel
        disclose.isHidden = !showDisclose
        toolTip = title
        setAccessibilityLabel(title)
        needsLayout = true
    }

    func preferredSize() -> CGSize {
        let labelWidth = ceil((primary.title as NSString).size(
            withAttributes: [.font: Self.font]).width)
        var width: CGFloat = 14 + labelWidth
        if !cancel.isHidden { width += 4 + 14 }
        if !disclose.isHidden { width += 4 + 14 }
        return CGSize(width: max(48, width), height: Self.height)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 7
        let labelWidth = ceil((primary.title as NSString).size(
            withAttributes: [.font: Self.font]).width)
        primary.frame = CGRect(x: x, y: 1, width: labelWidth + 2, height: Self.height - 2)
        x += labelWidth + 2 + 3
        if !disclose.isHidden {
            disclose.frame = CGRect(x: x, y: 1, width: 16, height: Self.height - 2)
            x += 16 + 2
        }
        if !cancel.isHidden {
            cancel.frame = CGRect(x: x, y: 0, width: 16, height: Self.height)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        for button in [primary, cancel, disclose]
            where !button.isHidden && button.frame.contains(point) {
            return button
        }
        return bounds.contains(point) ? self : nil
    }

    @objc private func primaryPressed() { primaryAction?() }
    @objc private func cancelPressed() { cancelAction?() }
    @objc private func disclosePressed() { discloseAction?() }
}

/// A selectable full-text view for a clipped translation. The popover is a disclosure, not a
/// second presentation of the translation: it opens on demand and never changes the page layout.
final class TranslationDisclosureController: NSViewController {
    private let headline: String
    private let text: String
    private let source: String

    init(title: String, text: String, source: String) {
        self.headline = title
        self.text = text
        self.source = source
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("TranslationDisclosureController is programmatic") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 260))
        let scroll = NSScrollView(frame: root.bounds.insetBy(dx: 12, dy: 12))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        let body = NSMutableAttributedString()
        body.append(NSAttributedString(
            string: headline + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                         .foregroundColor: NSColor.labelColor]))
        body.append(NSAttributedString(
            string: "The full translation, including the part the fitted overlay clipped:\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        body.append(NSAttributedString(
            string: text + "\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 12),
                         .foregroundColor: NSColor.labelColor]))
        body.append(NSAttributedString(
            string: "Source\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        body.append(NSAttributedString(
            string: source,
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        textView.textStorage?.setAttributedString(body)
        scroll.documentView = textView
        root.addSubview(scroll)
        view = root
    }
}
