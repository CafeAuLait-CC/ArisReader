import AppKit
import ArisReaderKit
import Combine
import Foundation

/// The wheel stops; the page stops with it.
///
/// Three properties stand between the reader and "it will not stop until it has scrolled all the way
/// there", and this file pins all three:
///
/// * the approach is an exact exponential over the tick (32 ms time constant), so a burst is
///   delivered at the speed ceiling rather than at a rate set by how often the driver wakes up,
/// * once no notch has arrived for `ScrollGlide.idleWindow` the wheel has stopped, so the rest is
///   delivered at the speed ceiling and the glide ends — nothing is left to decay, and
/// * what the glide may still owe at that moment is bounded by `ScrollGlide.maximumLead`; the
///   distance beyond it is dropped rather than queued, which is what makes the tail short after a
///   spin that outran the ceiling.
///
/// The arithmetic half runs on a simulated clock, so its numbers are the same on an idle machine
/// and on a loaded one. The driver half feeds the real `scrollWheel(with:)` path the events a hand
/// produces, and asserts only what cannot move with the load: the distance that was asked for was
/// delivered (within the cap's terms), every offset obeys the step bound and the tail bound, the
/// sequence is monotone, the landing is exact, and it ends rather than hanging.
extension ReaderChecks {
    /// The tick the production driver sleeps for; the same number makes the arithmetic exact.
    private static let glideTickSeconds = 0.008

    /// Deterministic: one notch, a burst, and the spin that made the reader complain.
    @MainActor static func scrollGlideTailChecks() {
        let tick = glideTickSeconds

        // ── One notch: a short slide, never one jump, over in a few frames ──────────────────
        var glide = ScrollGlide()
        let notch: CGFloat = -32
        glide.aim(at: notch, from: 0)
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
        let notchFrame = ScrollGlide.defaultMaximumSpeed * CGFloat(tick)
        require(largest <= notchFrame + 1e-9 && largest < 32,
                "no offset moves more than one frame of the ceiling (\(largest) pt of a "
                + "\(notchFrame) pt frame), so the notch still reads as motion rather than as a "
                + "jump")
        require(increments.count >= 6,
                "it is covered in \(increments.count) increments, not one")
        let after = glide.step(from: offset, elapsed: tick)
        require(after.finished && after.offset == offset, "and nothing is left to decay afterwards")
        require(abs(notch) <= ScrollGlide.maximumLead,
                "the lead is wide enough that a single notch is never truncated "
                + "(\(ScrollGlide.maximumLead) pt cap vs a \(notch) pt notch)")

        // ── A stalled main thread lengthens the glide instead of coarsening it ───────────────
        // The driver's tick is 8 ms, but a loaded machine hands it 40 ms at a time. The arithmetic
        // has to publish the same glide in more offsets rather than in one jump: a CI runner
        // published a 96 pt glide as three offsets before `maximumStepTime` capped the finish.
        // Aimed without a lead, so the whole 96 pt is owed and the bound has to come from the
        // arithmetic rather than from the cap.
        var stalled = ScrollGlide()
        stalled.aim(at: -96, from: 0, mostAhead: nil)
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
        require(stalledLargest <= frameCeiling + 1e-6,
                "and no offset moves further than one frame of the speed ceiling "
                + "(\(stalledLargest) pt of \(frameCeiling))")

        // ── A burst that stops: what is owed is the last notch, not the whole spin ──────────
        var burst = ScrollGlide()
        var position: CGFloat = 0
        var destination: CGFloat = 0
        // `WheelMotion`'s ramp for a spin at 50 ms per notch: the notches get bigger as it goes.
        let notches: [CGFloat] = [32, 43.2, 54.4, 65.6, 76.8, 88]
        var easingIncrements: [CGFloat] = []
        for notch in notches.dropLast() {
            destination += notch
            burst.aim(at: destination, from: position)
            for _ in 0..<6 { // the 50 ms until the next notch
                let (next, _) = burst.step(from: position, elapsed: tick)
                easingIncrements.append(next - position)
                position = next
            }
        }
        destination += notches.last!
        burst.aim(at: destination, from: position)
        // What is *aimed at* is what the glide will deliver: in the middle of the burst that is
        // already less than the summed notches, because the lead bound drops what cannot be
        // delivered in time. The tail is measured against the destination the glide actually has.
        let goal = burst.destination ?? destination
        let owed = goal - position
        require(owed <= ScrollGlide.maximumLead + 1e-9,
                "when the wheel stops the glide owes one notch at most, not the whole spin "
                + "(\(String(format: "%.1f", owed)) pt of the last \(notches.last!) pt notch, "
                + "against \(String(format: "%.1f", destination - position)) pt of notches)")
        var tailIncrements: [CGFloat] = []
        var tailTicks = 0
        while tailTicks < 200 {
            let (next, finished) = burst.step(from: position, elapsed: tick)
            tailIncrements.append(next - position)
            position = next
            tailTicks += 1
            if finished { break }
        }
        require(position == goal, "the burst lands exactly on the destination it kept")
        let tailMilliseconds = Double(tailTicks) * tick * 1000
        require(tailMilliseconds <= 96,
                "and is over within 96 ms of the last notch (\(Int(tailMilliseconds)) ms; "
                + "the same spin used to drift for 288 ms)")
        let burstLargest = tailIncrements.map { abs($0) }.max() ?? 0
        let tailCeiling = ScrollGlide.defaultMaximumSpeed * CGFloat(tick)
        require(burstLargest <= tailCeiling + 1e-6,
                "nothing in the tail moves faster than the speed ceiling the rest of the glide "
                + "obeys (\(burstLargest) pt in one tick, ceiling \(tailCeiling) pt)")
        // The tail is the debt being finished rather than an exponential whisper: it takes over at
        // least as fast as the approach left off, so the last thing the reader sees is not a slower
        // crawl out of a debt they thought was over.
        let firstTail = tailIncrements.first.map { abs($0) } ?? 0
        let lastEasing = easingIncrements.last.map { abs($0) } ?? 0
        require(firstTail >= lastEasing,
                "the tail takes over at least as fast as the approach left off "
                + "(\(firstTail) pt against \(lastEasing) pt)")

        // ── A spin that outruns the ceiling stops within one lead, not one burst ────────────
        // This is the reader's report, in arithmetic: notches every 10 ms ask for more distance
        // than 2000 pt/s can deliver, so without a bound on what the glide may owe, the wheel
        // stopping changes nothing - the backlog is paid out afterwards, for as long as it takes.
        // `WheelMotion` ramps a 10 ms spin the same way it ramps a 50 ms one, only faster.
        let spin = ScrollGlide.spinNotches(count: 10)
        let spinRequested = spin.reduce(0, +)
        func spinTrace(mostAhead lead: CGFloat?) -> (delivered: CGFloat, owedAtStop: CGFloat,
                                                     tail: [CGFloat], milliseconds: Double) {
            var glide = ScrollGlide()
            var position: CGFloat = 0
            var destination: CGFloat = 0
            for notch in spin {
                destination += notch
                glide.aim(at: destination, from: position, mostAhead: lead)
                var elapsed = 0.0
                while elapsed < 0.010 - 1e-12 { // the 10 ms until the next notch
                    let step = min(tick, 0.010 - elapsed)
                    position = glide.step(from: position, elapsed: step).offset
                    elapsed += step
                }
            }
            let owed = (glide.destination ?? position) - position
            var tail: [CGFloat] = []
            var milliseconds = 0.0
            while tail.count < 500 {
                let (next, finished) = glide.step(from: position, elapsed: tick)
                tail.append(next - position)
                position = next
                milliseconds += tick * 1000
                if finished { break }
            }
            return (position, owed, tail, milliseconds)
        }
        let tailBound = ScrollGlide.maximumLead
        let bounded = spinTrace(mostAhead: tailBound)
        let unbounded = spinTrace(mostAhead: nil)
        let unboundedTail = unbounded.tail.reduce(0) { $0 + abs($1) }
        require(unboundedTail > tailBound * 4,
                "without the lead the spin owes the whole burst: \(Int(unboundedTail)) pt of tail "
                + "and \(Int(unbounded.milliseconds)) ms of it, against a \(Int(tailBound)) pt cap")
        require(abs(unbounded.delivered - spinRequested) < 1e-9,
                "without the lead every requested point is eventually delivered "
                + "(\(String(format: "%.1f", unbounded.delivered)) pt of "
                + "\(String(format: "%.1f", spinRequested)) pt) - which is exactly the drift")
        let boundedTail = bounded.tail.reduce(0) { $0 + abs($1) }
        let oneTick = tick * ScrollGlide.defaultMaximumSpeed
        require(bounded.owedAtStop <= tailBound + 1e-9,
                "after the last notch of the spin the glide owes at most the lead "
                + "(\(String(format: "%.1f", bounded.owedAtStop)) pt of \(Int(tailBound)) pt)")
        require(boundedTail <= tailBound + oneTick + 1e-9,
                "so the whole tail is one lead plus one tick of ceiling "
                + "(\(String(format: "%.1f", boundedTail)) pt) and not the burst")
        require(bounded.milliseconds <= tailBound / ScrollGlide.defaultMaximumSpeed * 1000 + 20,
                "and it lasts one lead at the ceiling, not more "
                + "(\(Int(bounded.milliseconds)) ms for \(Int(tailBound)) pt; "
                + "\(Int(unbounded.milliseconds)) ms without the lead)")
        // The bound is not a property of the number happening to be 64: the tail has to scale with
        // whatever the lead is. This is what rules out a cap so wide that it cannot help, and the
        // reason the assertions above are written in terms of the lead rather than a literal.
        let doubled = spinTrace(mostAhead: tailBound * 2)
        require(doubled.owedAtStop <= tailBound * 2 + 1e-9 && doubled.owedAtStop > tailBound,
                "a lead twice as wide is owed in full (\(String(format: "%.1f", doubled.owedAtStop))"
                + " pt), so what bounds the tail is the lead and not a constant hidden in the "
                + "arithmetic")
        require(doubled.milliseconds > bounded.milliseconds,
                "and that buys distance with time, as it must "
                + "(\(Int(doubled.milliseconds)) ms against \(Int(bounded.milliseconds)) ms)")
        let boundedLargest = bounded.tail.map { abs($0) }.max() ?? 0
        require(boundedLargest <= ScrollGlide.defaultMaximumSpeed * CGFloat(tick) + 1e-6,
                "no tail offset moves faster than the ceiling (\(boundedLargest) pt)")
        require(bounded.delivered > 0 && bounded.delivered < spinRequested,
                "the trade is real and bounded: the spin delivers "
                + "\(String(format: "%.0f", bounded.delivered)) pt of the "
                + "\(String(format: "%.0f", spinRequested)) pt it asked for, so the wheel can "
                + "outrun the ceiling but the page stops with it")
        require(boundedTail < unboundedTail,
                "the lead is what bounds it (\(Int(boundedTail)) pt against \(Int(unboundedTail)) pt)")

        print("PASS: one notch is over in \(Int(milliseconds)) ms; a 50 ms burst leaves "
              + "\(String(format: "%.1f", owed)) pt owed and finishes it in \(tailTicks) ticks "
              + "(\(Int(tailMilliseconds)) ms); a 10 ms spin owes "
              + "\(String(format: "%.0f", bounded.owedAtStop)) pt and tails "
              + "\(Int(bounded.milliseconds)) ms / \(String(format: "%.0f", boundedTail)) pt "
              + "against \(Int(unbounded.milliseconds)) ms / \(String(format: "%.0f", unboundedTail))"
              + " pt unbounded")
    }

    /// The real driver, fed the events a classic wheel produces: 50 ms apart, accelerating.
    @MainActor static func scrollTailDriverChecks(url: URL) async throws {
        let state = AppState(engine: try RustEngine(), preferFullPageRasters: false)
        state.setViewportSize(CGSize(width: 700, height: 500))
        require(state.open(url: url), "the tail fixture opens")

        let view = MetalCanvasView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        view.onScroll = { delta in state.scroll(byScreenPoints: delta) }
        view.onScrollStep = { delta in state.scrollByWheelStep(delta) }
        view.onKeyboardStep = { delta in state.scrollByKeyboardStep(delta) }
        view.onKeyboardStep = { delta in state.scrollByKeyboardStep(delta) }
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
        // How many *ticks* a timer-driven glide takes, how much it still owes when the input stops,
        // and how long it takes in wall clock are all properties of the machine - a loaded runner
        // hands the driver two 40 ms slots where an idle one hands it seven 8 ms ones, and it
        // published a sixth of a burst before the wheel stopped. Those are asserted on the simulated
        // clock above. What is asserted here is what does not move with the load: the distance that
        // was asked for is the distance delivered, every offset obeys the step bound, the sequence
        // only moves toward the destination, the landing is exact, and the whole thing is over.
        requireTailShape(published, destination: singleStart + singleOwed, label: "a lone notch")
        require(singleWallClock < 5000,
                "a lone notch is over rather than hanging (\(Int(singleWallClock)) ms)")
        try await Task.sleep(for: .milliseconds(150))
        require(state.scrollYPt == parked, "nothing keeps sliding after the glide has landed")

        // ── A burst at 50 ms per notch, the way a hand spins a wheel ───────────────────────
        state.scroll(toFraction: 0.35)
        let burstStart = state.scrollYPt
        var requested: CGFloat = 0
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
            requested += lastNotch
            if index < 5 { try await Task.sleep(for: .milliseconds(50)) }
        }
        clock = ProcessInfo.processInfo.systemUptime
        let owedAtStop = (state.scrollDestinationYPt ?? state.scrollYPt) - state.scrollYPt
        let destination = state.scrollDestinationYPt
        try await eventually("the burst settles", { state.scrollDestinationYPt == nil })
        let burstWallClock = (ProcessInfo.processInfo.systemUptime - clock) * 1000
        observer.cancel()
        published.append(state.scrollYPt)
        guard let destination else { fatalError("FAIL: the burst aimed somewhere") }
        require(abs(state.scrollYPt - destination) < 1e-6,
                "the burst lands exactly on the offset its notches accumulated")
        require(abs((state.scrollYPt - burstStart) - requested) < 1e-6,
                "the distance delivered is exactly the distance the notches aimed at "
                + "(\(String(format: "%.2f", state.scrollYPt - burstStart)) pt of "
                + "\(String(format: "%.2f", requested)) pt): none lost, none invented")
        // The user-visible bound, on the real driver: after the last wheel event the offset owes at
        // most one lead. Both sides of the subtraction are read in the same synchronous stretch as
        // the last event - the driver cannot interleave a tick with it - so this is exact rather
        // than a tolerance on the machine's tick density.
        require(abs(owedAtStop) <= ScrollGlide.maximumLead + 1e-9,
                "after the last wheel event the glide owes at most the \(Int(ScrollGlide.maximumLead))"
                + " pt lead (\(String(format: "%.1f", owedAtStop)) pt), so the tail cannot outlast "
                + "one notch whatever the wheel was doing")
        requireTailShape(published, destination: destination, label: "a burst")
        require(burstWallClock < 5000,
                "a burst is over rather than hanging (\(Int(burstWallClock)) ms)")
        parked = state.scrollYPt
        try await Task.sleep(for: .milliseconds(150))
        require(state.scrollYPt == parked, "nothing keeps sliding after that either")

        // ── A spin: the notches arrive faster than the ceiling can deliver them ────────────
        // Same load-invariant contract as the burst, on the input that used to leave the longest
        // tail. What the *rate* costs the reader is measured on the simulated clock above; here the
        // claim is only that whatever was aimed at is delivered, that the debt at the stop is
        // bounded, and that it ends.
        state.scroll(toFraction: 0.35)
        let spinStart = state.scrollYPt
        var spinRequested: CGFloat = 0
        var spinOwed: CGFloat = 0
        published = [state.scrollYPt]
        observer = state.$scrollYPt.sink { published.append($0) }
        for index in 0..<8 {
            let before = state.scrollDestinationYPt ?? state.scrollYPt
            view.scrollWheel(with: wheelEvent())
            spinRequested += (state.scrollDestinationYPt ?? state.scrollYPt) - before
            spinOwed = (state.scrollDestinationYPt ?? state.scrollYPt) - state.scrollYPt
            require(abs(spinOwed) <= ScrollGlide.maximumLead + 1e-9,
                    "notch \(index + 1) of the spin still owes at most the lead "
                    + "(\(String(format: "%.1f", spinOwed)) pt)")
            if index < 7 { try await Task.sleep(for: .milliseconds(5)) }
        }
        clock = ProcessInfo.processInfo.systemUptime
        try await eventually("the spin settles", { state.scrollDestinationYPt == nil })
        let spinWallClock = (ProcessInfo.processInfo.systemUptime - clock) * 1000
        observer.cancel()
        published.append(state.scrollYPt)
        let spinDelivered = state.scrollYPt - spinStart
        requireTailShape(published, destination: state.scrollYPt, label: "a spin")
        require(spinWallClock < 5000, "a spin is over rather than hanging (\(Int(spinWallClock)) ms)")
        print("PASS: the real driver lands every notch, one frame of the ceiling at a time, and "
              + "never owes more than the \(Int(ScrollGlide.maximumLead)) pt lead (lone notch "
              + "\(Int(singleWallClock)) ms, burst \(Int(burstWallClock)) ms, spin "
              + "\(Int(spinWallClock)) ms on this machine; the spin asked for "
              + "\(String(format: "%.0f", abs(spinRequested))) pt and got "
              + "\(String(format: "%.0f", abs(spinDelivered))) pt - the rate cost is pinned on "
              + "simulated clock above)")

        // ── Keyboard paging is not a wheel: it keeps its whole destination ────────────────
        // A page key names a place, not a speed, so the lead does not truncate it and its tail is
        // the page distance at the ceiling - exactly what it was before the bound existed. Checked
        // on the model, where the arithmetic is exact: the same 200 pt is capped to one lead when a
        // wheel asks for it and delivered in full when a page key does.
        state.scroll(toFraction: 0.35)
        let request: CGFloat = 200
        let wheelFrom = state.scrollYPt
        state.scrollByWheelStep(request)
        let wheelOwed = (state.scrollDestinationYPt ?? state.scrollYPt) - state.scrollYPt
        require(abs(wheelOwed) <= ScrollGlide.maximumLead + 1e-9,
                "a wheel step of \(Int(request)) pt is capped to the lead "
                + "(\(String(format: "%.1f", wheelOwed)) pt of \(Int(ScrollGlide.maximumLead)))")
        for _ in 0..<800 where state.scrollDestinationYPt != nil {
            state.advanceScrollGlide(elapsed: glideTickSeconds)
        }
        let wheelDelivered = state.scrollYPt - wheelFrom
        state.scroll(toFraction: 0.35)
        let keyFrom = state.scrollYPt
        state.scrollByKeyboardStep(request)
        let keyOwed = (state.scrollDestinationYPt ?? state.scrollYPt) - state.scrollYPt
        require(keyOwed > ScrollGlide.maximumLead,
                "the same \(Int(request)) pt from a page key is a whole screen "
                + "(\(String(format: "%.0f", keyOwed)) pt), not one lead")
        for _ in 0..<800 where state.scrollDestinationYPt != nil {
            state.advanceScrollGlide(elapsed: glideTickSeconds)
        }
        let keyDelivered = state.scrollYPt - keyFrom
        require(abs(keyDelivered - min(request, state.contentHeightPt)) < 1.0,
                "and the page key lands on it exactly (\(String(format: "%.1f", keyDelivered)) pt)")
        let pageMilliseconds = keyOwed / ScrollGlide.defaultMaximumSpeed * 1000
        print("PASS: a \(Int(request)) pt wheel step delivers "
              + "\(String(format: "%.1f", wheelDelivered)) pt (one lead, old backlog dropped); the "
              + "same distance from a page key delivers "
              + "\(String(format: "%.1f", keyDelivered)) pt (~\(Int(pageMilliseconds)) ms of tail "
              + "at the ceiling)")

        // ── Trackpad deltas still bypass all of it ─────────────────────────────────────────
        let beforePrecise = state.scrollYPt
        state.scroll(byScreenPoints: 7.25)
        require(abs(state.scrollYPt - (beforePrecise + 7.25)) < 1e-9,
                "a precise delta is still applied 1:1, with no glide and no tail")
    }

    /// What every published offset of a glide must satisfy, whatever the tick density was.
    ///
    /// Derived from the offsets themselves and the destination they were aimed at, so it holds on
    /// a machine that gave the driver 8 ms ticks and on one that gave it 40 ms ones.
    @MainActor private static func requireTailShape(_ published: [CGFloat], destination: CGFloat,
                                                    label: String) {
        let frameCeiling = ScrollGlide.defaultMaximumSpeed * CGFloat(ScrollGlide.maximumStepTime)
        // A step is at most one frame of the speed ceiling - the driver's tick counted as at most
        // `maximumStepTime`, and the ceiling a speed - so the bound is the same on a machine that
        // gave the driver 8 ms ticks and on one that gave it 40 ms ones. On top of it the glide
        // snaps the last sub-half-point remainder onto the destination (`settleDistance`), which is
        // why the bound carries that much slack and no more.
        let snap = ScrollGlide.settleDistance + 0.001
        var worst = 0.0
        for (before, after) in zip(published, published.dropFirst()) {
            worst = max(worst, Double(abs(after - before) - (frameCeiling + snap)))
        }
        require(worst <= 0,
                "\(label) never moves further in one offset than a frame of the speed ceiling "
                + "(\(String(format: "%.2f", worst)) pt over)")
        let monotonic = zip(published, published.dropFirst()).allSatisfy { $1 <= $0 + 1e-6 }
        require(monotonic, "\(label) only ever moves toward its destination")
    }
}

private extension ScrollGlide {
    /// `WheelMotion`'s ramp for a spin: the notches one gesture produces, gap and all.
    ///
    /// `WheelMotion` boosts a notch by 0.35 for every notch that follows the previous one within
    /// 120 ms, up to 3x, so the notches of a spin grow exactly like this - the same ramp the 50 ms
    /// burst above uses, only delivered faster.
    static func spinNotches(count: Int) -> [CGFloat] {
        var boost: CGFloat = 1
        var deltas: [CGFloat] = []
        for _ in 0..<count {
            deltas.append(32 * boost)
            boost = min(3, boost + 0.35)
        }
        return deltas
    }
}
