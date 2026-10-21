import AppKit
import SwiftUI

/// The geometry and the resize arithmetic of the reader's right-hand side panel.
///
/// The panel is chrome, not a document surface: its width is a view preference, so the numbers
/// and the clamp live here, away from the view, where the checks can exercise them without a
/// window. The panel's content width is what the reader is remembering; the resize handle and
/// the 1 pt separator are added on top, exactly like the left sidebar's separator.
public enum ReaderSidePanelMetrics {
    /// Content width a fresh install opens with.
    public static let defaultContentWidthPt: CGFloat = 320
    /// Narrow enough to leave a usable canvas at the window's minimum width, wide enough for the
    /// assistant's action grid and request preview without squeezing them.
    public static let minimumContentWidthPt: CGFloat = 240
    /// Wide enough for the request preview's prompt body and the answer's tables. The panel is
    /// not a primary document surface, so it does not grow past this and take the page with it.
    public static let maximumContentWidthPt: CGFloat = 520
    /// The invisible drag target on the panel's inner edge. The separator is drawn separately;
    /// this is the grab area in front of it.
    public static let resizeHandleWidthPt: CGFloat = 6
    /// The line that marks the panel's edge against the canvas.
    public static let separatorWidthPt: CGFloat = 1

    public static var defaultTotalWidthPt: CGFloat {
        totalWidth(contentWidth: defaultContentWidthPt)
    }

    /// Width the layout gives the panel for a content width: handle + separator + content.
    public static func totalWidth(contentWidth: CGFloat) -> CGFloat {
        resizeHandleWidthPt + separatorWidthPt + clampedContentWidth(contentWidth)
    }

    /// A stored, dragged or restored width is never trusted: a corrupt preference or an
    /// out-of-range drag still produces a panel the canvas can live with.
    public static func clampedContentWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return defaultContentWidthPt }
        return min(max(width, minimumContentWidthPt), maximumContentWidthPt)
    }

    /// The width during a drag of the inner edge, from the width at the start of the gesture.
    ///
    /// The handle is the panel's leading edge, so dragging left (a negative translation) makes
    /// the panel wider. The clamp is applied on every sample, which is what stops a fast drag
    /// from storing a width outside the range.
    public static func contentWidth(base: CGFloat, dragTranslationX: CGFloat) -> CGFloat {
        guard dragTranslationX.isFinite else { return clampedContentWidth(base) }
        return clampedContentWidth(base - dragTranslationX)
    }
}

/// The persisted half of the right panel: its width and whether it is open.
///
/// These are reader preferences, not document state, so they live in `UserDefaults`. The app
/// reads and writes the standard domain; the checks pass an isolated suite so a run can prove
/// "remembered across launches" without touching the person's own window.
public enum ReaderSidePanelPreferences {
    public static let widthKey = "rightPanelWidthPt"
    public static let visibleKey = "rightPanelVisible"

    public static func width(defaults: UserDefaults = .standard) -> CGFloat {
        guard let stored = defaults.object(forKey: widthKey) as? NSNumber else {
            return ReaderSidePanelMetrics.defaultContentWidthPt
        }
        return ReaderSidePanelMetrics.clampedContentWidth(CGFloat(stored.doubleValue))
    }

    public static func isVisible(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: visibleKey)
    }

    public static func store(width: CGFloat, defaults: UserDefaults = .standard) {
        defaults.set(Double(ReaderSidePanelMetrics.clampedContentWidth(width)), forKey: widthKey)
    }

    public static func store(visible: Bool, defaults: UserDefaults = .standard) {
        defaults.set(visible, forKey: visibleKey)
    }
}

/// Keyboard shortcuts the right panel introduces. The keymap on the Rust side already reserves
/// ⇧⌘A for `CommandId::AiPanel`; the native command uses the same chord so the two agree.
///
/// The other two-panel chords were checked before choosing it: ⌥⌘I is Document Information,
/// ⌥⌘S is Toggle Sidebar, and the app's ⌘-number / ⌘[⌘] / ⌘⇧R / ⌥⌘R bindings are taken. ⇧⌘A is
/// unused by the native menu and is the documented AI-panel binding in `lyra-reader-session`.
public enum ReaderShortcuts {
    public static let toggleAIPanelLabel = "Toggle AI Assistant"
    public static let toggleAIPanelKey: KeyEquivalent = "a"
    public static let toggleAIPanelModifiers: EventModifiers = [.command, .shift]
}

/// The right-hand panel as a sliding drawer whose width also changes the canvas.
///
/// It is deliberately generic: the AI assistant is its first tenant, but the host knows nothing
/// about the assistant's model, its settings or its request state. The content is laid out once
/// at `contentWidth` and the *frame around it* animates between zero and the full width, exactly
/// like ``ReaderSidebarTransition``:
///
/// * the panel's own content keeps its geometry for the whole transition (no per-frame reflow of
///   the action grid, preview or answer);
/// * the separator travels with the content's leading edge while the panel is partly open;
/// * the canvas gets the freed width frame by frame, so the page's vertical position never
///   changes;
/// * at zero width the panel is still in the hierarchy (an answer is not lost by closing it), but
///   it is clipped out and takes no pointer or accessibility input.
///
/// The caller owns the animation transaction (`.animation(_, value:)` on the `HStack`) for the
/// same reason as the sidebar: a child animation would let the parent allocate the final width on
/// the first frame while only the drawing interpolated.
public struct ReaderSidePanel<Content: View>: View {
    private let isVisible: Bool
    private let contentWidth: CGFloat
    private let progressOverride: Double?
    private let accessibilityLabel: String
    private let onResizeBegan: () -> Void
    private let onResize: (CGFloat) -> Void
    private let onResizeEnded: () -> Void
    private let content: Content

    @State private var dragStartWidth: CGFloat?
    @State private var isHoveringHandle = false

    public init(
        isVisible: Bool,
        contentWidth: CGFloat,
        progressOverride: Double? = nil,
        accessibilityLabel: String = "Side panel",
        onResizeBegan: @escaping () -> Void = {},
        onResize: @escaping (CGFloat) -> Void,
        onResizeEnded: @escaping () -> Void = {},
        @ViewBuilder content: () -> Content
    ) {
        self.isVisible = isVisible
        self.contentWidth = ReaderSidePanelMetrics.clampedContentWidth(contentWidth)
        self.progressOverride = progressOverride
        self.accessibilityLabel = accessibilityLabel
        self.onResizeBegan = onResizeBegan
        self.onResize = onResize
        self.onResizeEnded = onResizeEnded
        self.content = content()
    }

    private var progress: CGFloat {
        if let progressOverride {
            return CGFloat(min(max(progressOverride, 0), 1))
        }
        return isVisible ? 1 : 0
    }

    private var totalWidth: CGFloat {
        ReaderSidePanelMetrics.totalWidth(contentWidth: contentWidth)
    }

    public var body: some View {
        HStack(spacing: 0) {
            resizeHandle
            Rectangle()
                .fill(LyraReaderTheme.separator)
                .frame(width: ReaderSidePanelMetrics.separatorWidthPt)
            content
                .frame(width: contentWidth)
        }
        .frame(width: totalWidth)
        // Leading alignment is the mirror of the left drawer: as the frame closes, the content
        // stays anchored to the inner edge and slides out past the window's trailing edge.
        .frame(width: totalWidth * progress, alignment: .leading)
        .clipped()
        .allowsHitTesting(isVisible || progressOverride != nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHidden(!isVisible)
    }

    /// The panel's inner edge. A transparent strip in front of the separator gives the pointer a
    /// real target; the hover tint and the resize cursor are the only affordances the panel has
    /// for a gesture that is otherwise invisible until it is used.
    private var resizeHandle: some View {
        Rectangle()
            .fill(isHoveringHandle ? LyraReaderTheme.accent.opacity(0.55) : Color.clear)
            .frame(width: ReaderSidePanelMetrics.resizeHandleWidthPt)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != isHoveringHandle else { return }
                isHoveringHandle = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                if isHoveringHandle {
                    NSCursor.pop()
                    isHoveringHandle = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let base = dragStartWidth ?? contentWidth
                        if dragStartWidth == nil {
                            dragStartWidth = base
                            onResizeBegan()
                        }
                        onResize(ReaderSidePanelMetrics.contentWidth(
                            base: base, dragTranslationX: value.translation.width))
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                        onResizeEnded()
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Resize assistant panel")
            .accessibilityValue("\(Int(contentWidth.rounded())) points")
            .accessibilityAdjustableAction { direction in
                onResizeBegan()
                switch direction {
                case .increment:
                    onResize(ReaderSidePanelMetrics.clampedContentWidth(contentWidth + 16))
                case .decrement:
                    onResize(ReaderSidePanelMetrics.clampedContentWidth(contentWidth - 16))
                @unknown default:
                    onResizeEnded()
                    return
                }
                onResizeEnded()
            }
    }
}
