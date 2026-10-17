import AppKit
import ArisReaderKit
import Foundation

/// The overlay scroll indicator, checked where it can be checked without a hand on the mouse.
///
/// Two halves:
///
/// * the pointer geometry is a pure type (`ScrollIndicatorGeometry`), so a whole drag can be
///   driven here — top of the track to the bottom and back, a drag that leaves the track, grab
///   offsets, and the cases where a thumb could otherwise invert or a fitting document could
///   still claim an indicator;
/// * the state that decides whether the indicator may be grabbed at all is asserted against a
///   real `AppState`. This is the half that would have caught the original defect: the old
///   indicator was hit-testable only while `isScrolling` was true, so it was ungrabbable exactly
///   when a reader reached for it.
///
/// What is *not* asserted here: that AppKit routes a real mouse press to the lane, that hovering
/// the lane fires, that the capsule's visible position matches the geometry, or that the preview
/// panel / note overlay stay in front. Those need a hand on the mouse.
extension ReaderChecks {
    @MainActor static func scrollIndicatorChecks(scrollable: URL, singlePage: URL) async throws {
        scrollIndicatorGeometryChecks()
        try await scrollIndicatorStateChecks(scrollable: scrollable, singlePage: singlePage)
    }

    @MainActor private static func scrollIndicatorGeometryChecks() {
        let track: CGFloat = 500
        let geometry = ScrollIndicatorGeometry(trackHeight: track, viewportFraction: 0.2)
        require(geometry.thumbHeight == 100 && geometry.travel == 400,
                "a viewport covering a fifth of a 500 pt track is a 100 pt thumb with 400 pt of travel")

        // A press at the very top of the track is on the top edge of the thumb at fraction 0.
        // Dragging to the bottom of the track must land at the end of the document.
        let topGrab = geometry.grabOffset(pointerY: 0, at: 0)
        require(topGrab == 0, "a press at the top of the track grabs the thumb's top edge, not an offset")
        require(geometry.fraction(draggingTo: track, grabOffset: topGrab) == 1,
                "a drag from the top of the track to the bottom lands at the end of the document")

        // The other way: at the end of the document the thumb's top is at `travel`, so the bottom
        // of the track is exactly one thumb below it.
        let bottomGrab = geometry.grabOffset(pointerY: track, at: 1)
        require(bottomGrab == geometry.thumbHeight,
                "at the end of the document the thumb's bottom edge is at the bottom of the track")
        require(geometry.fraction(draggingTo: 0, grabOffset: bottomGrab) == 0,
                "a drag from the bottom of the track to the top lands at the start of the document")

        require(geometry.fraction(draggingTo: -1_000, grabOffset: 0) == 0,
                "a drag above the track clamps at the start instead of scrolling past it")
        require(geometry.fraction(draggingTo: track + 1_000, grabOffset: 0) == 1,
                "a drag below the track clamps at the end instead of overshooting the document")

        // Grabbing the thumb away from its top edge must not make it jump under the pointer.
        let middleGrab = geometry.grabOffset(pointerY: 220, at: 0.5)
        require(middleGrab == 20, "a press 20 pt below the thumb's top remembers that 20 pt")
        require(abs(geometry.fraction(draggingTo: 220, grabOffset: middleGrab) - 0.5) < 1e-9,
                "a press that does not move the pointer does not move the thumb")
        require(abs(geometry.fraction(draggingTo: 260, grabOffset: middleGrab) - 0.6) < 1e-9,
                "moving a grabbed thumb 40 pt of a 400 pt travel moves the document by a tenth")

        require(geometry.hitsThumb(pointerY: 10, at: 0) && !geometry.hitsThumb(pointerY: 450, at: 0),
                "a press is a thumb grab only when it is inside the thumb")

        // A press on the track pages toward the click, one screen per press.
        require(geometry.trackPageDirection(pointerY: 450, at: 0) == 1,
                "a press below the thumb pages down")
        require(geometry.trackPageDirection(pointerY: 50, at: 1) == -1,
                "a press above the thumb pages up")
        require(geometry.trackPageDirection(pointerY: 50, at: 0) == 0,
                "a press on the thumb is a drag, not a page")

        // Geometry must never produce a thumb taller than its track (an inverted indicator) for
        // any size or fraction, including a track shorter than the 44 pt minimum.
        var thumbFitsTrack = true
        var travelIsExact = true
        var thumbStaysInTrack = true
        var fractionsClamp = true
        for height in [CGFloat(0), 1, 20, 44, 500, 2_000] {
            for coverage in [0.0, 0.0001, 0.02, 0.5, 0.9999, 1.0] {
                let g = ScrollIndicatorGeometry(trackHeight: height, viewportFraction: coverage)
                thumbFitsTrack = thumbFitsTrack && g.thumbHeight >= 0 && g.thumbHeight <= height
                travelIsExact = travelIsExact
                    && g.travel >= 0 && g.travel == height - g.thumbHeight
                thumbStaysInTrack = thumbStaysInTrack
                    && g.thumbTop(forFraction: 0) == 0
                    && g.thumbTop(forFraction: 1) == g.travel
                fractionsClamp = fractionsClamp
                    && g.thumbTop(forFraction: -5) == 0
                    && g.thumbTop(forFraction: 5) == g.travel
                    && g.fraction(draggingTo: -1_000, grabOffset: 0) == 0
                    // A fitting document has no thumb to move, so it stays at fraction 0 for
                    // every pointer position rather than claiming a non-existent end.
                    && (g.isScrollable
                        ? g.fraction(draggingTo: height + 1_000, grabOffset: 0) == 1
                        : g.fraction(draggingTo: height + 1_000, grabOffset: 0) == 0)
            }
        }
        require(thumbFitsTrack, "the thumb never inverts: it is never taller than its track")
        require(travelIsExact, "travel is exactly the track minus the thumb, and never negative")
        require(thumbStaysInTrack, "the thumb starts at the top and ends exactly at the end of its travel")
        require(fractionsClamp, "every fraction and pointer position outside the track clamps")

        let long = ScrollIndicatorGeometry(trackHeight: track, viewportFraction: 0.001)
        require(long.thumbHeight == ScrollIndicatorGeometry.minimumThumbHeight,
                "a very long document keeps at least a 44 pt thumb to grab")

        let fits = ScrollIndicatorGeometry(trackHeight: track, viewportFraction: 1)
        require(!fits.isScrollable && fits.travel == 0 && fits.thumbHeight == track,
                "a document that fits has no travel, so it has no indicator and no hit area")
        let shorterThanThumb = ScrollIndicatorGeometry(trackHeight: 20, viewportFraction: 0.1)
        require(!shorterThanThumb.isScrollable && shorterThanThumb.thumbHeight == 20,
                "a track shorter than the minimum thumb does not invert it either")
    }

    /// The state assertion that fails on the old code: idle must still be grabbable.
    @MainActor private static func scrollIndicatorStateChecks(scrollable: URL, singlePage: URL) async throws {
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 300))
        require(state.open(url: scrollable), "the scroll-indicator fixture opens")

        require(state.hasScrollableContent && !state.isScrolling,
                "a three-page document in a 300 pt viewport has something to scroll and is idle")
        // The old view's gate was `contentHeightPt > viewportHeightContentPt && isScrolling`.
        // At this point `isScrolling` is false, so that gate — and therefore any mouse target —
        // was closed. Interaction must not follow the animation.
        require(state.scrollIndicatorIsInteractive,
                "a scrollable document is grabbable while no scroll is in flight")
        require(!state.showsScrollIndicator,
                "the idle indicator is still faded out, so the reading surface stays clean")

        state.setScrollIndicatorHovered(true)
        require(state.showsScrollIndicator,
                "moving the pointer into the lane brings the indicator back without a scroll")
        state.setScrollIndicatorHovered(false)
        require(!state.showsScrollIndicator, "leaving the lane fades it out again")

        state.beginScrollIndicatorDrag()
        require(state.isDraggingScrollIndicator && state.showsScrollIndicator,
                "a press on the thumb holds the indicator visible before the pointer moves")
        state.scroll(toFraction: 1)
        require(abs(state.scrollFraction - 1) < 1e-9,
                "a drag to the foot of the track reaches the end of the document")
        require(state.scrollIndicatorIsInteractive,
                "the indicator stays grabbable while a drag is in flight")
        state.scroll(toFraction: 0)
        require(state.scrollFraction == 0, "a drag back to the top returns to the start of the document")
        state.endScrollIndicatorDrag()
        require(!state.isDraggingScrollIndicator && state.isScrolling,
                "releasing the thumb ends the drag and starts the idle fade")

        try await eventually("the indicator goes idle after the fade window", { !state.isScrolling })
        require(state.scrollIndicatorIsInteractive,
                "the faded indicator is still grabbable: interaction does not follow the animation")
        require(!state.showsScrollIndicator, "and it is still not drawn while idle")

        state.setViewportSize(CGSize(width: 700, height: 3_000))
        require(!state.hasScrollableContent && !state.scrollIndicatorIsInteractive
                && !state.showsScrollIndicator,
                "a viewport tall enough for the whole document has no indicator and no hit area")
        state.beginScrollIndicatorDrag()
        require(!state.isDraggingScrollIndicator,
                "a press cannot start a drag when the document fits")

        require(state.open(url: singlePage), "the single-page fixture opens")
        require(!state.scrollIndicatorIsInteractive,
                "a one-page document in the tall viewport has no indicator")
        state.setViewportSize(CGSize(width: 700, height: 300))
        require(state.hasScrollableContent && state.scrollIndicatorIsInteractive && !state.isScrolling,
                "shrinking the window makes the same document scrollable, and its idle indicator grabbable")
        require(!state.showsScrollIndicator,
                "the new document starts faded out rather than inheriting the old one's activity")
    }
}
