import SwiftUI

/// The geometry of the overlay scroll indicator, separated from the view that draws it.
///
/// The view used to do this arithmetic inline, around a visual `.offset`: the capsule moved but
/// the gesture's `contentShape` stayed on the un-offset frame at the top of the lane, so the only
/// strip a drag could start in was the first `thumbHeight` points of the track, wherever the thumb
/// actually was. Keeping the mapping in one type also lets the checks drive a whole drag without
/// a window or a mouse (`apps/macos/Checks/ScrollIndicatorChecks.swift`).
public struct ScrollIndicatorGeometry: Equatable, Sendable {
    /// Height of the track the thumb travels in, in points.
    public let trackHeight: CGFloat
    /// Height of the thumb in points.
    public let thumbHeight: CGFloat
    /// How far the thumb's top may move from the top of the track, in points.
    public let travel: CGFloat

    /// Shortest thumb, so a very long document still has something to grab.
    public static let minimumThumbHeight: CGFloat = 44

    public init(trackHeight: CGFloat, viewportFraction: Double) {
        let track = max(0, trackHeight)
        let fraction = Self.clamp01(CGFloat(viewportFraction))
        let thumb = min(track, max(Self.minimumThumbHeight, track * fraction))
        self.trackHeight = track
        self.thumbHeight = thumb
        self.travel = track - thumb
    }

    /// Whether the thumb has anywhere to go. A document that fits leaves it no travel, which is
    /// also what keeps that case from having a hit area.
    public var isScrollable: Bool { travel > 0 }

    /// Top of the thumb for a 0…1 scroll fraction.
    public func thumbTop(forFraction fraction: Double) -> CGFloat {
        Self.clamp01(CGFloat(fraction)) * travel
    }

    /// Fraction the thumb would be at if its top were `top`; clamped, so a drag that leaves the
    /// track stops at the end of the document instead of overshooting it.
    public func fraction(forThumbTop top: CGFloat) -> Double {
        guard travel > 0 else { return 0 }
        return Double(Self.clamp01(top / travel))
    }

    /// Where the pointer sits inside the thumb. Subtracting this from every later pointer
    /// position is what stops a press anywhere but the very top of the thumb from making it jump
    /// under the hand.
    public func grabOffset(pointerY: CGFloat, at fraction: Double) -> CGFloat {
        let top = thumbTop(forFraction: fraction)
        return min(max(pointerY - top, 0), thumbHeight)
    }

    /// The scroll fraction a drag reaches when the pointer is at `pointerY` and grabbed the thumb
    /// `grabOffset` points below its top.
    public func fraction(draggingTo pointerY: CGFloat, grabOffset: CGFloat) -> Double {
        fraction(forThumbTop: pointerY - grabOffset)
    }

    /// Whether a press at `pointerY` is on the thumb. The drag uses this to choose between moving
    /// the thumb and paging the track.
    public func hitsThumb(pointerY: CGFloat, at fraction: Double) -> Bool {
        let top = thumbTop(forFraction: fraction)
        return thumbHeight > 0 && pointerY >= top && pointerY <= top + thumbHeight
    }

    /// -1 above the thumb, +1 below it, 0 on it. A track press jumps one screen in this direction.
    public func trackPageDirection(pointerY: CGFloat, at fraction: Double) -> Int {
        guard isScrollable else { return 0 }
        let top = thumbTop(forFraction: fraction)
        if pointerY < top { return -1 }
        if pointerY > top + thumbHeight { return 1 }
        return 0
    }

    private static func clamp01(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}

/// Overlay scroll indicator.
///
/// Scrolling is self-managed (decision T1.4), so AppKit draws no scroller for us — this is the
/// `NSScroller` replacement: a translucent capsule that fades out while idle and can be dragged.
///
/// Visible and interactive are two different facts. The old view folded them together: the
/// indicator was both drawn and hit-testable only while `isScrolling` was true, so it vanished
/// (and took its mouse target with it) the moment a scroll ended. Now a scrollable document always
/// has a hit-testable lane, the pointer in that lane brings the capsule back, and only the fade
/// follows use. The lane is the scroller's own narrow strip on the trailing edge; outside it the
/// page keeps every click, and a document that fits has neither a lane nor an indicator.
struct ScrollIndicator: View {
    @ObservedObject var state: AppState

    /// Thumb width in points.
    private let width: CGFloat = 9
    /// The hit-testable lane: the thumb plus room to aim at a 9 pt bar. It is real layout
    /// (`ReaderChrome.scrollIndicatorLaneWidthPt`), not an overlay, so the page column ends
    /// before it and the right-hand panel starts after it.
    private var laneWidth: CGFloat { ReaderChrome.scrollIndicatorLaneWidthPt }
    /// Distance from the lane's trailing edge to the thumb.
    private var trailingInset: CGFloat { (laneWidth - width) / 2 }

    /// The drag in flight, if any. Cleared when the document changes, so a cancelled gesture
    /// cannot leave the next press thinking it is a continuation.
    @State private var drag: DragSession?

    private struct DragSession {
        let isThumb: Bool
        let grabOffset: CGFloat
    }

    var body: some View {
        GeometryReader { proxy in
            let geometry = ScrollIndicatorGeometry(
                trackHeight: proxy.size.height,
                viewportFraction: state.viewportFraction
            )
            ZStack(alignment: .topTrailing) {
                // One gesture for the whole lane: the first event decides whether the press landed
                // on the thumb (drag it) or on the track (page toward the click). A single hit
                // area means no invisible sibling can cover the track, as the old separate thumb
                // gesture could.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { state.setScrollIndicatorHovered($0) }
                    .gesture(laneGesture(geometry: geometry))

                Capsule()
                    .fill(active ? LyraReaderTheme.scrollThumbHover : LyraReaderTheme.scrollThumb)
                    .frame(width: width, height: geometry.thumbHeight)
                    .padding(.trailing, trailingInset)
                    // Visual only: the gesture above owns the hit area, so the thumb's position
                    // can be animated without moving where the mouse grabs.
                    .offset(y: geometry.thumbTop(forFraction: state.scrollFraction))
                    .animation(
                        state.isDraggingScrollIndicator ? nil : .easeOut(duration: 0.15),
                        value: state.scrollFraction
                    )
                    .animation(.easeOut(duration: 0.25), value: active)
                    .allowsHitTesting(false)
                    .opacity(state.showsScrollIndicator ? 1 : 0)
                    .animation(.easeOut(duration: 0.25), value: state.showsScrollIndicator)
            }
            .frame(width: laneWidth, height: proxy.size.height, alignment: .topTrailing)
        }
        .frame(width: laneWidth)
        // Interaction is the document's fact, not the fade's: a scrollable document is grabbable
        // even while the capsule is transparent, and a document that fits is not grabbable at all.
        .allowsHitTesting(state.scrollIndicatorIsInteractive)
        .onChange(of: state.document?.id) { _, _ in drag = nil }
    }

    private var active: Bool {
        state.isScrolling || state.isDraggingScrollIndicator
    }

    private func laneGesture(geometry: ScrollIndicatorGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard geometry.isScrollable else { return }
                if drag == nil {
                    let fraction = state.scrollFraction
                    if geometry.hitsThumb(pointerY: value.startLocation.y, at: fraction) {
                        drag = DragSession(
                            isThumb: true,
                            grabOffset: geometry.grabOffset(
                                pointerY: value.startLocation.y, at: fraction
                            )
                        )
                        state.beginScrollIndicatorDrag()
                    } else {
                        drag = DragSession(isThumb: false, grabOffset: 0)
                        // A press on the track pages one screen toward the click, the platform
                        // convention: it is reversible, never skips content the way a teleport
                        // would, and repeated clicks keep moving. Page Down is the same
                        // destination, so it goes through the same entry point
                        // (`AppState.scrollByKeyboardStep`), which owns the short glide and the
                        // tile/prefetch rebuild. A thumb drag is different: it is continuous
                        // input, so it uses `AppState.scroll(toFraction:)`, the immediate path
                        // that cancels any glide and rebuilds the band at the pointer's fraction.
                        let direction = geometry.trackPageDirection(
                            pointerY: value.startLocation.y, at: fraction
                        )
                        if direction != 0 {
                            state.scrollByKeyboardStep(CGFloat(direction) * geometry.trackHeight * 0.9)
                        }
                    }
                }
                // While the thumb is held the capsule follows the pointer with the animation
                // switched off, and the document is set to the same fraction on every event.
                if let drag, drag.isThumb {
                    state.scroll(toFraction: geometry.fraction(
                        draggingTo: value.location.y, grabOffset: drag.grabOffset
                    ))
                }
            }
            .onEnded { _ in
                if let drag, drag.isThumb {
                    state.endScrollIndicatorDrag()
                }
                drag = nil
            }
    }
}
