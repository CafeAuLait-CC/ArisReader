import AppKit
import SwiftUI

// MARK: - Placement and limits

/// Where the floating preview goes, how far it may be moved, and how big it may become.
///
/// Pure arithmetic on purpose. The panel's placement rules — open next to the thing that was
/// clicked, flip when there is no room below, never leave the screen, never go under the minimum
/// or over the maximum — are exactly the part that is easy to get subtly wrong and exactly the
/// part a native check can assert without a display.
public enum PreviewPanelGeometry {
    /// A readable citation column; the height is fitted to each preview.
    public static let defaultSize = CGSize(width: 520, height: 360)
    /// 320×240 pt: small enough to tuck into a corner, large enough for a reference to stay
    /// readable.
    public static let minimumSize = CGSize(width: 320, height: 240)
    /// The documented ceiling: 80% of the screen it opens on.
    public static let maximumScreenFraction: CGFloat = 0.8
    /// Inset from the screen edge, and the horizontal inset the spec asks for.
    public static let edgeMargin: CGFloat = 12
    /// Distance between the anchor and the panel when it opens below it.
    public static let anchorGap: CGFloat = 8

    /// The largest the panel may be on `visible`.
    ///
    /// A tiny screen must not produce a maximum smaller than the minimum, or the two rules fight
    /// and every resize ends up clamped by whichever ran last.
    public static func maximumSize(onScreen visible: CGRect) -> CGSize {
        CGSize(
            width: max(minimumSize.width, visible.width * maximumScreenFraction),
            height: max(minimumSize.height, visible.height * maximumScreenFraction)
        )
    }

    /// The size a drag or a content fit may ask for, inside the panel's own limits.
    public static func clampSize(_ size: CGSize, onScreen visible: CGRect) -> CGSize {
        let maximum = maximumSize(onScreen: visible)
        return CGSize(
            width: min(max(size.width, minimumSize.width), maximum.width),
            height: min(max(size.height, minimumSize.height), maximum.height)
        )
    }

    /// A frame pulled back inside `visible`, keeping its size where the screen has room for it.
    ///
    /// This is what keeps a panel the reader dragged to a screen edge reachable: the whole panel
    /// stays inside the visible frame with the standard inset, so its close button never ends up
    /// under the menu bar or past the dock.
    public static func confinedFrame(_ frame: CGRect, onScreen visible: CGRect) -> CGRect {
        var result = frame
        result.size = clampSize(result.size, onScreen: visible)
        let minX = visible.minX + edgeMargin
        let maxX = max(minX, visible.maxX - edgeMargin - result.width)
        result.origin.x = min(max(result.origin.x, minX), maxX)
        let minY = visible.minY + edgeMargin
        let maxY = max(minY, visible.maxY - edgeMargin - result.height)
        result.origin.y = min(max(result.origin.y, minY), maxY)
        return result
    }

    /// The frame a new panel opens with: below the anchor when there is room, above it when
    /// there is not, and inside the screen either way.
    public static func anchoredFrame(size: CGSize, anchor: CGRect, onScreen visible: CGRect) -> CGRect {
        let size = clampSize(size, onScreen: visible)
        // Screen space is bottom-left origin, so "below the anchor" subtracts the height.
        var y = anchor.minY - anchorGap - size.height
        if y < visible.minY + edgeMargin {
            y = anchor.maxY + anchorGap
        }
        return confinedFrame(CGRect(origin: CGPoint(x: anchor.minX, y: y), size: size),
                            onScreen: visible)
    }

    /// Resize from the bottom-right corner: the top-left stays where it is, and the size is
    /// clamped to the panel's limits and to the screen.
    public static func resizedByBottomRight(
        _ frame: CGRect,
        by delta: CGVector,
        onScreen visible: CGRect
    ) -> CGRect {
        let requested = CGSize(width: frame.width + delta.dx, height: frame.height - delta.dy)
        let size = clampSize(requested, onScreen: visible)
        let topLeft = CGPoint(x: frame.minX, y: frame.maxY)
        return confinedFrame(
            CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height),
            onScreen: visible
        )
    }

    /// A canvas view-space rectangle (top-left origin) in screen coordinates.
    ///
    /// The canvas reports the anchor in the same space it draws in; the panel has to open in the
    /// one AppKit positions windows with.
    public static func screenRect(
        canvasViewRect: CGRect,
        canvasHeightPt: CGFloat,
        canvasOnScreen: CGRect
    ) -> CGRect {
        CGRect(
            x: canvasOnScreen.minX + canvasViewRect.minX,
            y: canvasOnScreen.minY + (canvasHeightPt - canvasViewRect.maxY),
            width: canvasViewRect.width,
            height: canvasViewRect.height
        )
    }
}

// MARK: - Entry text

/// Citation title extraction and text measurement shared by the preview model and view.
public enum ReferencePreviewLayout {
    public static let textFontSize: CGFloat = 12
    public static let entrySpacingPt: CGFloat = 12
    /// Card padding plus the scroll indicator's lane.
    public static let textInsetPt: CGFloat = 30

    public static func textColumnWidth(panelWidthPt: CGFloat) -> CGFloat {
        max(80, panelWidthPt - textInsetPt)
    }

    /// Extracts a title only when the entry has a clear author/title sentence boundary.
    /// Initials and common author suffixes do not split a sentence. Unstructured entries keep
    /// a neutral heading instead of inventing bibliographic metadata.
    public static func citationTitle(from raw: String) -> String? {
        let text = raw.replacingOccurrences(of: #"^\s*\[?\d+\]?\.?\s+"#,
                                           with: "", options: .regularExpression)
        guard let regex = try? NSRegularExpression(pattern: #"[.!?](?=\s+\S|$)"#) else { return nil }
        let ns = text as NSString
        let boundaries = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).filter { match in
            let prefix = ns.substring(to: match.range.location)
            let token = prefix.components(separatedBy: .whitespacesAndNewlines).last ?? ""
            if ["Jr", "Sr", "Dr", "Prof", "vs", "e.g", "i.e"].contains(token) { return false }
            if token.range(of: #"^(?:[A-Z]\.)*[A-Z]$"#, options: .regularExpression) != nil { return false }
            return true
        }
        guard boundaries.count >= 2 else { return nil }
        let start = boundaries[0].range.location + 1
        let end = boundaries[1].range.location + 1
        let title = ns.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.split(whereSeparator: \.isWhitespace).count >= 3, title.count <= 400,
              !title.lowercased().hasPrefix("in "), !title.lowercased().hasPrefix("proceedings ") else { return nil }
        return title
    }

    /// Height of `text` wrapped to `widthPt`, in points.
    public static func textHeight(_ text: String, widthPt: CGFloat) -> CGFloat {
        guard widthPt > 1, !text.isEmpty else { return 0 }
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: textFontSize)]
        )
        let bounds = attributed.boundingRect(
            with: CGSize(width: widthPt, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(bounds.height)
    }
}

// MARK: - Model

/// Complete bibliography entries and their title headings for the current preview.
@MainActor
public final class ReferencePreviewModel: ObservableObject {
    /// One resolved bibliography entry, as the panel shows it.
    public struct Entry: Identifiable, Equatable {
        public let id: Int
        public let label: String
        public let text: String
        public var heading: String { ReferencePreviewLayout.citationTitle(from: text) ?? "Reference" }
        /// Page the entry is on, when clicking its label should preview that page.
        public let page: Int?
        public let region: CGRect?

        public var citationEntry: AppState.CitationEntry {
            AppState.CitationEntry(label: label, text: text, page: page, region: region)
        }
    }

    @Published public private(set) var entries: [Entry] = []
    public init() {}

    public func update(entries citationEntries: [AppState.CitationEntry]) {
        entries = citationEntries.enumerated().map { index, entry in
            Entry(id: index, label: entry.label, text: entry.text,
                  page: entry.page, region: entry.region)
        }
    }

    /// Full citation text, with a title heading; large bibliographies scroll at the screen limit.
    public func fullContentHeight(panelWidthPt: CGFloat) -> CGFloat {
        let width = ReferencePreviewLayout.textColumnWidth(panelWidthPt: panelWidthPt)
        return 80 + entries.reduce(CGFloat(0)) { total, entry in
            total + ReferencePreviewLayout.textHeight(entry.heading, widthPt: width)
                + ReferencePreviewLayout.textHeight(entry.text, widthPt: width) + 16
        }
    }
}

// MARK: - Panel

/// The floating preview window: borderless, movable by its background, resizable within limits.
///
/// A real `NSPanel` rather than an overlay inside the reader's window (`docs/04-ui-ux.md` §5.1):
/// a preview has to be movable and resizable on its own, and AppKit's background dragging and
/// resize machinery only exist for windows. `isMovableByWindowBackground` is the whole of the
/// drag support — the SwiftUI card that fills the panel reports `mouseDownCanMoveWindow == true`
/// for its non-interactive areas, so a drag on the background moves the window while a drag on a
/// button or on selectable text still reaches the control.
public final class ReferencePreviewPanel: NSPanel, NSWindowDelegate {
    /// Called when the *reader* moved or resized the panel (never for the placements the
    /// controller applies itself).
    package var onUserFrameChange: ((CGRect) -> Void)?
    package var onCancel: (() -> Void)?

    /// The screen area the panel must stay inside. Injectable so the check harness can assert the
    /// limits without depending on the displays of the machine running it.
    package var visibleFrameOverride: CGRect?

    /// The last frame this class applied itself. A move or resize notification that reports
    /// exactly this frame is our own placement coming back, not the reader's hand.
    private var programmaticFrame: CGRect?
    /// Guards the re-entrant notification a confinement can post.
    private var isConfining = false

    static let gripSize: CGFloat = 16

    public init(screen: CGRect) {
        super.init(
            contentRect: CGRect(origin: .zero, size: PreviewPanelGeometry.defaultSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        visibleFrameOverride = screen
        isFloatingPanel = false
        level = .normal
        // The SwiftUI card draws the rounded material background; the window is only its frame.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = true
        animationBehavior = .utilityWindow
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        minSize = PreviewPanelGeometry.minimumSize
        maxSize = PreviewPanelGeometry.maximumSize(onScreen: screen)
        delegate = self
        applyProgrammaticFrame(
            PreviewPanelGeometry.confinedFrame(
                CGRect(origin: .zero, size: PreviewPanelGeometry.defaultSize), onScreen: screen
            )
        )
    }

    /// A preview is an accessory: it can take key focus (so Esc closes it and its text can be
    /// selected) without ever becoming the document window.
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        else { super.keyDown(with: event) }
    }

    /// The area the panel is kept inside: the screen its own visible frame, or the injected one
    /// the checks use.
    var screenArea: CGRect {
        visibleFrameOverride ?? screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? CGRect(origin: .zero, size: PreviewPanelGeometry.defaultSize)
    }

    /// Applies a frame the controller chose, and records it so the delegate does not mistake it
    /// for a drag.
    package func applyProgrammaticFrame(_ frame: CGRect) {
        programmaticFrame = frame
        setFrame(frame, display: true)
    }

    /// Applies a frame the reader produced (a background drag or the resize grip), keeps it on
    /// screen, then reports it once.
    package func applyUserFrame(_ frame: CGRect) {
        let confined = PreviewPanelGeometry.confinedFrame(frame, onScreen: screenArea)
        applyProgrammaticFrame(confined)
        onUserFrameChange?(confined)
    }

    /// Enforces the panel's size limits on every interactive resize, not only on the ones that
    /// start from the grip: a borderless and resizable window still answers to AppKit's own edge
    /// tracking, and that path never goes through `PreviewPanelGeometry` otherwise.
    public func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        PreviewPanelGeometry.clampSize(frameSize, onScreen: screenArea)
    }

    /// Keeps a dragged panel on screen, and remembers where the reader put it.
    public func windowDidMove(_ notification: Notification) {
        userFrameChanged()
    }

    /// Same for a resize.
    public func windowDidResize(_ notification: Notification) {
        userFrameChanged()
    }

    /// Re-pins the maximum to the screen the panel actually ended up on.
    public func windowDidChangeScreen(_ notification: Notification) {
        visibleFrameOverride = nil
        maxSize = PreviewPanelGeometry.maximumSize(onScreen: screenArea)
    }

    private func userFrameChanged() {
        guard !isConfining else { return }
        if let programmaticFrame, programmaticFrame.equalTo(frame) { return }
        let confined = PreviewPanelGeometry.confinedFrame(frame, onScreen: screenArea)
        isConfining = true
        if confined != frame { applyProgrammaticFrame(confined) }
        isConfining = false
        onUserFrameChange?(confined)
    }
}

// MARK: - Resize grip

/// The bottom-right resize affordance.
///
/// AppKit only grows one for titled windows, so a borderless panel provides its own. The drag is
/// resolved by `PreviewPanelGeometry.resizedByBottomRight`, which is where the minimum and the
/// maximum are enforced.
final class PreviewResizeGrip: NSView {
    private var initialFrame: CGRect = .zero
    private var initialPointer: CGPoint = .zero

    override func resetCursorRects() {
        // The system's own diagonal resize cursor where it exists; before macOS 15 there is no
        // public one, and a crosshair still says "this corner drags".
        if #available(macOS 15.0, *) {
            addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
        } else {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        for offset in stride(from: CGFloat(0), to: 10, by: 4) {
            path.move(to: CGPoint(x: bounds.maxX - 3 - offset, y: 3))
            path.line(to: CGPoint(x: bounds.maxX - 3, y: 3 + offset))
        }
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        initialFrame = window.frame
        initialPointer = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panel = window as? ReferencePreviewPanel else { return }
        let pointer = NSEvent.mouseLocation
        let delta = CGVector(dx: pointer.x - initialPointer.x, dy: pointer.y - initialPointer.y)
        panel.applyUserFrame(
            PreviewPanelGeometry.resizedByBottomRight(initialFrame, by: delta,
                                                      onScreen: panel.screenArea)
        )
    }
}

// MARK: - Controller

/// Owns one child preview per reader window. Each new preview fits its own content; a manual
/// resize is respected only while that preview remains open. No geometry is persisted.
///
/// **One controller per reader window** (`ReaderSession.previewPanels`). It used to be a
/// process-wide singleton (`shared`) that each window's `ReferencePreviewHost` re-synced with its
/// own `AppState`; with one state per window, the window that updated last would win — opening a
/// preview in one window and scrolling the other would close it. `shared` stays as the default for
/// callers that have no window of their own (a check, a preview harness).
@MainActor
public final class ReferencePreviewPanelController {
    public static let shared = ReferencePreviewPanelController()

    public private(set) var panel: ReferencePreviewPanel?
    public let model = ReferencePreviewModel()

    /// Where the reader last put the panel, and whether they are the reason it is there.
    public private(set) var rememberedFrame: CGRect?
    public private(set) var userAdjustedFrame = false

    private var hosting: NSHostingView<ReferencePreviewPanelContent>?
    private var grip: PreviewResizeGrip?
    private var escapeMonitor: Any?

    /// What the current frame was fitted to. A change here is what re-fits an untouched panel;
    /// ordinary state changes (a raster arriving, a status line) do not.
    private struct FitKey: Equatable {
        let preview: AppState.ReferencePreview?
        /// The raster's own point size, which is what decides an image preview's height.
        let imageSize: CGSize?
    }

    private var fittedKey: FitKey?

    /// A fresh panel owner. The app makes one per reader window; ``shared`` remains for callers
    /// without a window.
    public init() {}

    /// Creates, moves, re-fits or closes the panel to match the state.
    ///
    /// `canvasOnScreen` and `canvasHeightPt` describe where the reader's canvas is; they are
    /// optional so a caller without a window (the checks) can still drive the panel.
    public func sync(
        state: AppState,
        canvasOnScreen: CGRect? = nil,
        canvasHeightPt: CGFloat = 0,
        screen: CGRect? = nil,
        parentWindow: NSWindow? = nil
    ) {
        guard let preview = state.referencePreview else {
            close()
            return
        }
        let area = screen ?? panel?.screenArea ?? NSScreen.main?.visibleFrame
            ?? CGRect(origin: .zero, size: PreviewPanelGeometry.defaultSize)

        let existed = panel != nil
        let panel = self.panel ?? makePanel(state: state, screen: area)
        if let parentWindow, panel.parent !== parentWindow {
            panel.parent?.removeChildWindow(panel)
            panel.level = parentWindow.level
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        panel.appearance = parentWindow?.effectiveAppearance
        let isNewPreview = !existed || fittedKey?.preview != preview
        if isNewPreview {
            userAdjustedFrame = false
            rememberedFrame = nil
        }
        let key = FitKey(preview: preview,
                         imageSize: state.referencePreviewPages.first?.image.pointSize)
        if key != fittedKey {
            model.update(entries: preview.entries)
            fittedKey = key
            let size = desiredSize(preview: preview, key: key, area: area)
            if isNewPreview {
                // Each new preview opens next to the rectangle that was clicked.
                applyGeometry(initialFrame(state: state, size: size, preview: preview,
                                           canvasOnScreen: canvasOnScreen,
                                           canvasHeightPt: canvasHeightPt, area: area),
                              to: panel)
            } else if !userAdjustedFrame {
                // A raster arrived for this preview; fit its aspect ratio without moving the top edge.
                refit(size: size, of: panel, area: area)
            }
        }
        if !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Closes the panel and releases its child-window relationship and keyboard monitor.
    public func close() {
        guard let panel else { return }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.delegate = nil
        panel.onUserFrameChange = nil
        panel.onCancel = nil
        self.panel = nil
        hosting = nil
        grip = nil
        fittedKey = nil
        rememberedFrame = nil
        userAdjustedFrame = false
    }

    // MARK: - Private

    private func makePanel(state: AppState, screen: CGRect) -> ReferencePreviewPanel {
        let panel = ReferencePreviewPanel(screen: screen)
        panel.onCancel = { [weak state, weak self] in
            state?.closeReferencePreview()
            self?.close()
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak state, weak panel, weak self] event in
            let handled = MainActor.assumeIsolated {
                guard event.keyCode == 53, let panel, panel.isVisible,
                      event.window === panel || (panel.parent != nil && event.window === panel.parent) else { return false }
                state?.closeReferencePreview()
                self?.close()
                return true
            }
            return handled ? nil : event
        }
        panel.onUserFrameChange = { [weak self] frame in
            self?.userAdjustedFrame = true
            self?.rememberedFrame = frame
        }
        let hosting = NSHostingView(rootView: ReferencePreviewPanelContent(state: state, model: model))
        hosting.autoresizingMask = [.width, .height]
        let container = NSView(frame: CGRect(origin: .zero, size: PreviewPanelGeometry.defaultSize))
        hosting.frame = container.bounds
        container.addSubview(hosting)
        // The grip sits in the bottom-right corner over the card's own padding, so it never
        // covers text or a button.
        let grip = PreviewResizeGrip(frame: CGRect(x: container.bounds.maxX - ReferencePreviewPanel.gripSize,
                                                   y: container.bounds.minY,
                                                   width: ReferencePreviewPanel.gripSize,
                                                   height: ReferencePreviewPanel.gripSize))
        grip.autoresizingMask = [.minXMargin, .maxYMargin]
        container.addSubview(grip)
        panel.contentView = container
        self.hosting = hosting
        self.grip = grip
        self.panel = panel
        return panel
    }

    /// Places a new preview against its source anchor.
    private func initialFrame(
        state: AppState,
        size: CGSize,
        preview: AppState.ReferencePreview,
        canvasOnScreen: CGRect?,
        canvasHeightPt: CGFloat,
        area: CGRect
    ) -> CGRect {
        if let anchor = anchorRect(state: state, preview: preview,
                                   canvasOnScreen: canvasOnScreen, canvasHeightPt: canvasHeightPt) {
            return PreviewPanelGeometry.anchoredFrame(size: size, anchor: anchor, onScreen: area)
        }
        // No anchor on screen (a citation in the body can point at a bibliography page the reader
        // is nowhere near): the bottom-right corner, where the overlay this replaced used to sit.
        return PreviewPanelGeometry.confinedFrame(
            CGRect(x: area.maxX - PreviewPanelGeometry.edgeMargin - size.width,
                   y: area.minY + PreviewPanelGeometry.edgeMargin,
                   width: size.width, height: size.height),
            onScreen: area
        )
    }

    /// The anchor's rectangle in screen coordinates: the clicked rectangle when the shell has one
    /// (a citation, a `Figure 3` mention, a link), otherwise the target region if its page is in
    /// the band the shell holds placements for.
    private func anchorRect(
        state: AppState,
        preview: AppState.ReferencePreview,
        canvasOnScreen: CGRect?,
        canvasHeightPt: CGFloat
    ) -> CGRect? {
        guard let canvasOnScreen, canvasHeightPt > 0 else { return nil }
        let viewRect = preview.anchor ?? state.anchorViewRect(page: preview.page, region: preview.region)
        guard let viewRect else { return nil }
        return PreviewPanelGeometry.screenRect(
            canvasViewRect: viewRect, canvasHeightPt: canvasHeightPt, canvasOnScreen: canvasOnScreen
        )
    }

    /// The size a preview asks for before the reader takes over: the entry text for a reference,
    /// the image's own aspect ratio for a figure or a page.
    private func desiredSize(
        preview: AppState.ReferencePreview,
        key: FitKey,
        area: CGRect
    ) -> CGSize {
        let preferredWidth: CGFloat = preview.kind == .reference ? 520 : 560
        let width = userAdjustedFrame ? (panel?.frame.width ?? preferredWidth)
            : min(preferredWidth, PreviewPanelGeometry.maximumSize(onScreen: area).width)
        let height: CGFloat
        switch preview.kind {
        case .reference:
            // Measure the full citation and its title using the same column as the view.
            height = model.fullContentHeight(panelWidthPt: width)
        case .figure, .page:
            let imageHeight: CGFloat
            if let region = preview.region {
                imageHeight = width * region.height / max(region.width, 1)
            } else if let imageSize = key.imageSize, imageSize.width > 0 {
                imageHeight = width * imageSize.height / imageSize.width
            } else {
                imageHeight = 320
            }
            // The raster crop already includes the figure/table caption.
            height = 80 + min(max(120, imageHeight), 600)
        }
        return PreviewPanelGeometry.clampSize(CGSize(width: width, height: height), onScreen: area)
    }

    /// Re-fits the height to what the body now wants, keeping the top edge where it is.
    private func refit(size requestedSize: CGSize, of panel: ReferencePreviewPanel, area: CGRect) {
        let size = PreviewPanelGeometry.clampSize(requestedSize, onScreen: area)
        var frame = panel.frame
        // Growing downward would push the panel off the bottom of the screen, so the top edge
        // stays put and the panel grows upward from it instead.
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        applyGeometry(PreviewPanelGeometry.confinedFrame(frame, onScreen: area), to: panel)
    }

    private func applyGeometry(_ frame: CGRect, to panel: ReferencePreviewPanel) {
        panel.applyProgrammaticFrame(frame)
    }
}

// MARK: - Content

/// The preview card: the same material, corner radius and shadow the in-window overlay had. What
/// changed is that it lives in its own window, and that a reference shows its entry text instead
/// of a picture of the bibliography page.
struct ReferencePreviewPanelContent: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: ReferencePreviewModel
    @ObservedObject private var appearance = ReadingAppearanceStore.shared

    var body: some View {
        if let preview = state.referencePreview {
            VStack(alignment: .leading, spacing: 8) {
                header(preview)
                switch preview.kind {
                case .reference: referenceBody(preview)
                case .figure, .page: imageBody(preview)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(LyraTheme.raisedBg, in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(LyraTheme.textPrimary)
            .tint(LyraTheme.accent)
            .onExitCommand { state.closeReferencePreview() }
        }
    }

    private func header(_ preview: AppState.ReferencePreview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(preview.title).font(.headline).lineLimit(1)
                Spacer(minLength: 0)
                Button { state.closeReferencePreview() } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close preview")
            }
            HStack {
                Text("From \(preview.source) · page \(preview.page + 1)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Full page") { state.showFullPreviewPage() }
                Button("Go to page") {
                    state.gotoPage(preview.page)
                    state.closeReferencePreview()
                }
            }
            .font(.caption)
        }
    }

    /// Complete citation entries, with title headings; the body scrolls at the screen limit.
    private func referenceBody(_ preview: AppState.ReferencePreview) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ReferencePreviewLayout.entrySpacingPt) {
                ForEach(model.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        if entry.page != nil {
                            Button(entry.heading) { state.selectPreviewEntry(entry.citationEntry) }
                                .buttonStyle(.link)
                        } else {
                            Text(entry.heading).bold()
                        }
                        Text(entry.text)
                            .font(.system(size: ReferencePreviewLayout.textFontSize))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.trailing, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A figure, table or plain page destination: the rendered region, because the picture is the
    /// point.
    private func imageBody(_ preview: AppState.ReferencePreview) -> some View {
        ZStack {
            PDFCanvasView(
                pages: state.referencePreviewPages,
                scrollYPt: state.referencePreviewScrollYPt,
                zoom: state.referencePreviewZoom,
                contentWidthPt: state.referencePreviewPages.first?.placement.widthPt ?? 0,
                paperAppearance: appearance.mode,
                onFrame: { stats in state.updateGpuStatus(stats, label: "preview") },
                onFailure: { message in state.reportGpuFailure(message) },
                onViewportSize: { size in state.setReferencePreviewViewport(size) },
                onScroll: { delta in state.scrollReferencePreview(by: delta) },
                interactionSnapshot: {
                    (state.referencePreviewPages, state.referencePreviewScrollYPt,
                     state.referencePreviewZoom)
                }
            )
            if state.referencePreviewLoading { ProgressView("Loading preview…") }
            if let error = state.referencePreviewError {
                Text(error).font(.callout).padding().background(.regularMaterial)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LyraTheme.canvasBg)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

}

// MARK: - Host

/// A non-hit-testable view whose only job is to tell the panel controller where the canvas is and
/// when the preview changed.
///
/// It sits behind the canvas, so it can never take a scroll or a click away from the reader, and
/// it reports the canvas rect in screen coordinates — the space the panel has to open in.
struct ReferencePreviewHost: NSViewRepresentable {
    // The state object's identity stays the same when a click opens/closes a preview. Observe
    // its publications here: otherwise SwiftUI can skip updateNSView for this unchanged value,
    // leaving parsed preview content in AppState with no AppKit panel to display it.
    @ObservedObject var state: AppState
    @ObservedObject private var appearance = ReadingAppearanceStore.shared
    /// The controller of the window this host is in (`ReaderSession.previewPanels`); `shared` for
    /// a caller that has no window of its own.
    var panels: ReferencePreviewPanelController = .shared

    func makeNSView(context: Context) -> NSView {
        NonBlockingView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let canvasOnScreen = nsView.window.map {
            $0.convertToScreen(nsView.convert(nsView.bounds, to: nil))
        }
        panels.sync(
            state: state,
            canvasOnScreen: canvasOnScreen,
            canvasHeightPt: nsView.bounds.height,
            screen: nsView.window?.screen?.visibleFrame,
            parentWindow: nsView.window
        )
    }
}

/// A view that never participates in hit testing: the canvas keeps every event it had.
final class NonBlockingView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
