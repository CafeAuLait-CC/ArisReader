import AppKit
import ArisReaderKit
import Combine
import Foundation

/// The wheel stops; the page stops with it.
///
/// The glide eases the offset toward the distance the notches asked for, so when the last notch
/// lands there is still a little of it owed. That debt used to decay out with a 55 ms time
/// constant, which is the drift the reader reported as "it keeps sliding after I let go of the
/// wheel". The fix has two halves, and both are pinned here:
///
/// * the approach is short enough (32 ms, capped at a quarter of what is left per tick) that a
///   burst no longer falls a whole notch behind, and
/// * once no notch has arrived for `ScrollGlide.idleWindow`, the wheel has stopped, so the rest is
///   delivered at the speed ceiling and the glide ends — nothing is left to decay.
///
/// The arithmetic half runs on a simulated clock, so its numbers do not depend on this machine;
/// the driver half feeds the real `scrollWheel(with:)` path the events a hand produces.
extension ReaderChecks {
    /// The tick the production driver sleeps for; the same number makes the arithmetic exact.
    private static let glideTickSeconds = 0.008

    /// Deterministic: what one notch, and a burst of them, does after the wheel stops.
    @MainActor static func scrollGlideTailChecks() {
        let tick = glideTickSeconds

        // ── One notch: a short slide, never one jump, over in a few frames ──────────────────
        var glide = ScrollGlide()
        let notch: CGFloat = -32
        glide.aim(at: notch)
        var offset: CGFloat = 0
        var increments: [CGFloat] = []
        var milliseconds = 0.0
        var easingTicks = 0
        while milliseconds < 1000 {
            let (next, finished) = glide.step(from: offset, elapsed: tick)
            milliseconds += tick * 1000
            increments.append(next - offset)
            offset = next
            if !glide.isFinishing { easingTicks += 1 }
            if finished { break }
        }
        require(offset == notch, "a wheel notch lands exactly on the offset it asked for")
        require(milliseconds <= 88,
                "a lone notch is over within 88 ms of the wheel (\(Int(milliseconds)) ms; it was "
                + "216 ms with the 55 ms time constant)")
        require(Double(easingTicks) * tick <= ScrollGlide.idleWindow + tick,
                "it eases for exactly the idle window (\(easingTicks) ticks) before the wheel is "
                + "declared stopped")
        let largest = increments.map { abs($0) }.max() ?? 0
        require(largest <= 32 * ScrollGlide.maximumTickFraction + 1e-9,
                "no offset moves more than a quarter of the notch (\(largest) pt of 32), so the "
                + "notch still reads as motion rather than as a jump")
        require(increments.count >= 6,
                "it is covered in \(increments.count) increments, not one")
        let after = glide.step(from: offset, elapsed: tick)
        require(after.finished && after.offset == offset, "and nothing is left to decay afterwards")

        // ── A stalled main thread lengthens the glide instead of coarsening it ───────────────
        // The driver's tick is 8 ms, but a loaded machine hands it 40 ms at a time. The arithmetic
        // has to publish the same glide in more offsets rather than in one jump: a CI runner
        // published a 96 pt glide as three offsets before `maximumStepTime` capped the finish.
        var stalled = ScrollGlide()
        stalled.aim(at: -96)
        var stalledOffset: CGFloat = 0
        var stalledIncrements: [CGFloat] = []
        for _ in 0..<400 {
            let (next, finished) = stalled.step(from: stalledOffset, elapsed: 0.04)
            stalledIncrements.append(next - stalledOffset)
            stalledOffset = next
            if finished { break }
        }
        require(stalledOffset == -96, "a stalled tick still lands the glide exactly")
        require(stalledIncrements.count >= 6,
                "40 ms ticks publish the same 96 pt glide in \(stalledIncrements.count) offsets, "
                + "not one jump")
        let stalledLargest = stalledIncrements.map { abs($0) }.max() ?? 0
        let frameCeiling = ScrollGlide.defaultMaximumSpeed * CGFloat(ScrollGlide.maximumStepTime)
        require(stalledLargest <= max(frameCeiling, 96 * ScrollGlide.maximumTickFraction) + 1e-6,
                "and no offset moves further than a frame of the speed ceiling, or a quarter of "
                + "what was left (\(stalledLargest) pt)")

        // ── A burst that stops: what is owed is the last notch, not the whole spin ──────────
        var burst = ScrollGlide()
        var position: CGFloat = 0
        var destination: CGFloat = 0
        // `WheelMotion`'s ramp for a spin at 50 ms per notch: the notches get bigger as it goes.
        let notches: [CGFloat] = [32, 43.2, 54.4, 65.6, 76.8, 88]
        for notch in notches.dropLast() {
            destination += notch
            burst.aim(at: destination)
            for _ in 0..<6 { // the 50 ms until the next notch
                let (next, _) = burst.step(from: position, elapsed: tick)
                position = next
            }
        }
        destination += notches.last!
        burst.aim(at: destination)
        let owed = destination - position
        require(owed <= notches.last! * 1.25,
                "when the wheel stops the glide owes one notch, not the whole spin "
                + "(\(String(format: "%.1f", owed)) pt of the last \(notches.last!) pt notch)")
        var tailIncrements: [CGFloat] = []
        var tailTicks = 0
        while tailTicks < 200 {
            let (next, finished) = burst.step(from: position, elapsed: tick)
            tailIncrements.append(next - position)
            position = next
            tailTicks += 1
            if finished { break }
        }
        require(position == destination, "the burst lands exactly on what its notches accumulated")
        let tailMilliseconds = Double(tailTicks) * tick * 1000
        require(tailMilliseconds <= 96,
                "and is over within 96 ms of the last notch (\(Int(tailMilliseconds)) ms; "
                + "the same spin used to drift for 288 ms)")
        let burstLargest = tailIncrements.map { abs($0) }.max() ?? 0
        let tailCeiling = ScrollGlide.defaultMaximumSpeed * CGFloat(tick)
        require(burstLargest <= tailCeiling + 1e-6,
                "nothing in the tail moves faster than the speed ceiling the rest of the glide "
                + "obeys (\(burstLargest) pt in one tick, ceiling \(tailCeiling) pt)")
        // The tail is the debt being finished, not an exponential whisper: its first tick already
        // moves at the ceiling rather than at a quarter of what is left.
        let firstTail = tailIncrements.first.map { abs($0) } ?? 0
        let lastTail = tailIncrements.last.map { abs($0) } ?? 0
        require(firstTail > lastTail, "the tail is front-loaded and lands on the destination")
        print("PASS: one notch is over in \(Int(milliseconds)) ms; a 50 ms burst leaves "
              + "\(String(format: "%.1f", owed)) pt owed and finishes it in \(tailTicks) ticks "
              + "(\(Int(tailMilliseconds)) ms)")
    }

    /// The real driver, fed the events a classic wheel produces: 50 ms apart, accelerating.
    @MainActor static func scrollTailDriverChecks(url: URL) async throws {
        let state = AppState(engine: try RustEngine(), preferFullPageRasters: false)
        state.setViewportSize(CGSize(width: 700, height: 500))
        require(state.open(url: url), "the tail fixture opens")

        let view = MetalCanvasView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        view.onScroll = { delta in state.scroll(byScreenPoints: delta) }
        view.onScrollStep = { delta in state.scrollByWheelStep(delta) }
        view.interactionSnapshot = { (state.canvasPages, state.scrollYPt, state.zoomFactor) }
        func wheelEvent() -> NSEvent {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                   wheel1: 1, wheel2: 0, wheel3: 0) else {
                fatalError("FAIL: a wheel event can be built")
            }
            // A real wheel carries the wall clock, and `WheelMotion` reads it to decide how fast
            // the wheel is spinning.
            cg.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
            return NSEvent(cgEvent: cg)!
        }

        // ── One notch ──────────────────────────────────────────────────────────────────────
        state.scroll(toFraction: 0.35)
        let singleStart = state.scrollYPt
        // The series starts where the notch did, so a glide that moved the whole distance on the
        // spot would be *in* it rather than invisible between two samples.
        var published: [CGFloat] = [state.scrollYPt]
        var observer = state.$scrollYPt.sink { published.append($0) }
        var clock = ProcessInfo.processInfo.systemUptime
        view.scrollWheel(with: wheelEvent())
        let singleOwed = (state.scrollDestinationYPt ?? state.scrollYPt) - state.scrollYPt
        try await eventually("the lone notch settles", { state.scrollDestinationYPt == nil })
        let singleWallClock = (ProcessInfo.processInfo.systemUptime - clock) * 1000
        observer.cancel()
        published.append(state.scrollYPt)
        require(abs(state.scrollYPt - (singleStart - 32)) < 1e-6,
                "the driver lands a lone notch exactly (\(state.scrollYPt - singleStart) pt)")
        var parked = state.scrollYPt
        require(abs(parked - (singleStart + singleOwed)) < 1e-6,
                "the distance delivered is the distance the notch asked for")
        // The number of *ticks* a timer-driven glide takes is a property of the machine, not of
        // the glide - a loaded runner hands the driver two 40 ms slots where an idle one hands it
        // seven 8 ms ones - so what is asserted here is what does not move with the tick density:
        // the tail is a handful of offsets rather than a drift, and no single one of them moves
        // further than a frame of the speed ceiling (or a quarter of what was left). The wall-clock
        // tail itself is pinned by the simulated-clock check above, where it is exact.
        require(published.count <= 11,
                "a lone notch is finished in \(published.count) published offsets, not a drift")
        requireTailShape(published, destination: singleStart + singleOwed, label: "a lone notch")
        require(singleWallClock < 500,
                "and the glide ends, rather than asymptotically creeping (\(Int(singleWallClock)) ms)")
        try await Task.sleep(for: .milliseconds(150))
        require(state.scrollYPt == parked, "nothing keeps sliding after the glide has landed")

        // ── A burst at 50 ms per notch, the way a hand spins a wheel ───────────────────────
        state.scroll(toFraction: 0.35)
        var lastNotch: CGFloat = 0
        for index in 0..<6 {
            let before = state.scrollDestinationYPt ?? state.scrollYPt
            if index == 5 {
                // From the last notch on, watch every offset the driver publishes - starting with
                // the one it started from, so a jump would be measured rather than missed.
                published = [state.scrollYPt]
                observer = state.$scrollYPt.sink { published.append($0) }
            }
            view.scrollWheel(with: wheelEvent())
            lastNotch = (state.scrollDestinationYPt ?? state.scrollYPt) - before
            if index < 5 { try await Task.sleep(for: .milliseconds(50)) }
        }
        clock = ProcessInfo.processInfo.systemUptime
        let owedAtStop = (state.scrollDestinationYPt ?? state.scrollYPt) - state.scrollYPt
        let destination = state.scrollDestinationYPt
        require(abs(owedAtStop) <= abs(lastNotch) * 1.35 + 0.5,
                "a burst that stops owes one notch, not the whole spin "
                + "(\(String(format: "%.1f", abs(owedAtStop))) pt of the last "
                + "\(String(format: "%.1f", abs(lastNotch))) pt notch; the 55 ms constant owed "
                + "124.6 pt of an 88 pt notch)")
        try await eventually("the burst settles", { state.scrollDestinationYPt == nil })
        let burstWallClock = (ProcessInfo.processInfo.systemUptime - clock) * 1000
        observer.cancel()
        published.append(state.scrollYPt)
        guard let destination else { fatalError("FAIL: the burst aimed somewhere") }
        require(abs(state.scrollYPt - destination) < 1e-6,
                "the burst lands exactly on the offset its notches accumulated")
        require(published.count <= 15,
                "the tail after the last notch is \(published.count) published offsets, not the "
                + "\(27) a decaying glide took")
        requireTailShape(published, destination: destination, label: "a burst")
        require(burstWallClock < 500,
                "and it ends rather than asymptotically creeping (\(Int(burstWallClock)) ms)")
        parked = state.scrollYPt
        try await Task.sleep(for: .milliseconds(150))
        require(state.scrollYPt == parked, "nothing keeps sliding after that either")

        // ── Trackpad deltas still bypass all of it ─────────────────────────────────────────
        let beforePrecise = state.scrollYPt
        state.scroll(byScreenPoints: 7.25)
        require(abs(state.scrollYPt - (beforePrecise + 7.25)) < 1e-9,
                "a precise delta is still applied 1:1, with no glide and no tail")
        print("PASS: a wheel burst leaves at most one notch owed, lands exactly on the "
              + "accumulated offset and stops (lone notch \(Int(singleWallClock)) ms, "
              + "burst \(Int(burstWallClock)) ms on this machine)")
    }

    /// What every published offset of a glide must satisfy, whatever the tick density was.
    ///
    /// Derived from the offsets themselves and the destination they were aimed at, so it holds on
    /// a machine that gave the driver 8 ms ticks and on one that gave it 40 ms ones.
    @MainActor private static func requireTailShape(_ published: [CGFloat], destination: CGFloat,
                                                    label: String) {
        let frameCeiling = ScrollGlide.defaultMaximumSpeed * CGFloat(ScrollGlide.maximumStepTime)
        // A step is at most a frame of the speed ceiling, or a quarter of what was left; on top of
        // that the glide snaps the last sub-half-point remainder onto the destination (its
        // `settleDistance`), which is why the bound carries that much slack and no more.
        let snap = ScrollGlide.settleDistance + 0.001
        var worst = 0.0
        for (before, after) in zip(published, published.dropFirst()) {
            let remaining = abs(destination - before)
            let allowed = max(frameCeiling, remaining * ScrollGlide.maximumTickFraction) + snap
            worst = max(worst, Double(abs(after - before) - allowed))
        }
        require(worst <= 0,
                "\(label) never moves further in one offset than a frame of the speed ceiling or a "
                + "quarter of what was left (\(String(format: "%.2f", worst)) pt over)")
        let monotonic = zip(published, published.dropFirst()).allSatisfy { $1 <= $0 + 1e-6 }
        require(monotonic, "\(label) only ever moves toward its destination")
    }
}
