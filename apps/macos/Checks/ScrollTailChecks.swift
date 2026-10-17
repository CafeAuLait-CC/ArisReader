import AppKit
import ArisReaderKit
import Foundation

extension ReaderChecks {
    @MainActor static func scrollGlideTailChecks() {
        func distance(interval: TimeInterval) -> CGFloat {
            var wheel = WheelMotion()
            var sum: CGFloat = 0
            for index in 0..<10 {
                sum += wheel.delta(scrollingDeltaY: -1, precise: false,
                                   timestamp: 1 + Double(index) * interval)
            }
            return sum
        }
        let slow = distance(interval: 0.15)
        let medium = distance(interval: 0.05)
        let fast = distance(interval: 0.01)
        require(slow == 400 && medium > slow && fast > medium,
                "faster wheel rotation increases distance (slow \(slow), medium \(medium), fast \(fast) pt)")
        var wheel = WheelMotion()
        _ = wheel.delta(scrollingDeltaY: -1, precise: false, timestamp: 1)
        require(wheel.delta(scrollingDeltaY: -1, precise: false, timestamp: 1.01) == 120,
                "a fast wheel event reaches the bounded 3x gain")
        require(abs(wheel.delta(scrollingDeltaY: -1, precise: false, timestamp: 1.11) - 40) < 1e-6,
                "slowing the wheel lowers gain immediately rather than retaining a burst boost")
        require(wheel.delta(scrollingDeltaY: 1, precise: false, timestamp: 1.12) == -40,
                "direction reversal resets acceleration")
        require(wheel.delta(scrollingDeltaY: -1, precise: false, timestamp: 2) == 40,
                "a pause resets acceleration")
        require(wheel.delta(scrollingDeltaY: 2.5, precise: true, timestamp: 2.1) == -2.5,
                "precise input preserves its system distance")
        require(wheel.delta(scrollingDeltaY: -1, precise: false, timestamp: 2.11) == 40,
                "precise input resets the discrete wheel cadence")
    }

    @MainActor static func scrollTailDriverChecks(url: URL) async throws {
        let state = AppState(engine: try RustEngine(), preferFullPageRasters: false)
        state.setViewportSize(CGSize(width: 700, height: 500))
        require(state.open(url: url), "wheel fixture opens")
        let view = MetalCanvasView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        view.onScrollStep = { state.scrollByWheelStep($0) }
        view.onScroll = { state.scroll(byScreenPoints: $0) }
        func event(at seconds: TimeInterval, wheel: Int32 = -1) -> NSEvent {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                             wheel1: wheel, wheel2: 0, wheel3: 0)!
            cg.timestamp = UInt64(seconds * 1_000_000_000)
            return NSEvent(cgEvent: cg)!
        }
        for interval in [0.15, 0.05, 0.01] {
            state.scroll(toFraction: 0.1)
            let start = state.scrollYPt
            for index in 0..<8 {
                let before = state.scrollYPt
                view.scrollWheel(with: event(at: 10 + Double(index) * interval))
                require(state.scrollYPt > before && state.scrollDestinationYPt == nil,
                        "wheel event \(index + 1) at \(Int(interval * 1000)) ms moves immediately with no debt")
            }
            let parked = state.scrollYPt
            require(parked - start >= 320, "a burst keeps at least its unaccelerated distance")
            if interval == 0.01 {
                require(parked - start > 800,
                        "a fast spin keeps accelerated distance instead of losing it to the glide ceiling")
            }
            // Advance both the production arithmetic and the real driver's clock after input.
            for _ in 0..<20 { state.advanceScrollGlide(elapsed: 0.04) }
            try await Task.sleep(for: .milliseconds(160))
            require(state.scrollYPt == parked, "the document has zero motion after the final wheel event")
        }
        state.scroll(toFraction: 0.5)
        let beforeReverse = state.scrollYPt
        view.scrollWheel(with: event(at: 20, wheel: 1))
        require(state.scrollYPt < beforeReverse, "reversing the wheel reverses motion on the same event")
        state.scrollByWheelStep(-1_000_000)
        require(state.scrollYPt == 0 && state.scrollDestinationYPt == nil, "wheel motion clamps at the document top")
        state.scrollByWheelStep(1_000_000)
        let bottom = state.scrollYPt
        state.scrollByWheelStep(100)
        require(state.scrollYPt == bottom && state.scrollDestinationYPt == nil,
                "wheel motion clamps at the document bottom without animation")
        state.zoomIn()
        state.scroll(toFraction: 0.2)
        let zoomedStart = state.scrollYPt
        state.scrollByWheelStep(80)
        require(abs((state.scrollYPt - zoomedStart) * state.zoomFactor - 80) < 1e-6,
                "wheel distance remains in screen points after zooming")
    }
}
