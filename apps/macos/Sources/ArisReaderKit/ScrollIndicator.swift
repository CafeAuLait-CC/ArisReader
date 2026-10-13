import SwiftUI

/// Overlay scroll indicator.
///
/// Scrolling is self-managed (decision T1.4), so AppKit draws no scroller for us — this is
/// the `NSScroller` replacement: a translucent capsule that fades out while idle and can be
/// dragged. It deliberately does not intercept clicks when the whole document already fits.
struct ScrollIndicator: View {
    @ObservedObject var state: AppState

    /// Thumb width in points.
    private let width: CGFloat = 9
    /// Shortest thumb, so a very long document still has something to grab.
    private let minimumThumbHeight: CGFloat = 44

    var body: some View {
        GeometryReader { geometry in
            let track = geometry.size.height
            let thumbHeight = max(minimumThumbHeight, track * state.viewportFraction)
            let travel = max(1, track - thumbHeight)

            Capsule()
                .fill(Color.primary.opacity(state.isScrolling ? 0.32 : 0.16))
                .frame(width: width, height: thumbHeight)
                .offset(y: travel * state.scrollFraction)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 2)
                .animation(.easeOut(duration: 0.15), value: state.scrollFraction)
                .animation(.easeOut(duration: 0.25), value: state.isScrolling)
                .contentShape(Rectangle().size(width: width + 8, height: thumbHeight))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = (value.location.y - thumbHeight / 2) / travel
                            state.scroll(toFraction: fraction)
                        }
                )
        }
        .frame(width: width + 4)
        .opacity(state.showsScrollIndicator ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: state.showsScrollIndicator)
        .allowsHitTesting(state.showsScrollIndicator)
    }
}
