import CoreGraphics
import Foundation

/// The offset a **stepped** scroll is heading for, and the arithmetic that gets it there.
///
/// A classic wheel and the keyboard report "one notch", not a distance, and the app has to turn
/// that into motion. Applying the whole step at once is what makes a wheel feel like it moves the
/// page one grid line at a time; a burst makes it worse, because `WheelMotion` accelerates
/// (`-32, -43, -54, …`) and each of those lands as a single jump. The glide keeps the destination
/// instead and hands out the offsets in between, so a notch becomes a short slide and a burst
/// becomes one continuous motion that keeps up with the wheel.
///
/// It is deliberately not a physics simulation: no velocity accumulates and nothing is carried
/// over from one notch to the next. The input's own acceleration (`WheelMotion`) already decides
/// *how far* a notch goes; this only decides *how* it gets there. Trackpad input never comes
/// through here at all — a precise delta is applied 1:1, because the system already animated it,
/// and adding a glide on top would be applying the same gesture twice.
///
/// The arithmetic is a plain exponential approach, which is what makes it testable without a
/// display: the whole state is a target and the caller's clock.
///
/// The approach only runs **while the wheel is still turning**. A notch every 50 ms asks for more
/// distance per second than an exponential approach can deliver without falling behind, so the
/// offset ends up owing the document a slice of the burst; letting that slice decay on its own is
/// exactly the drift a reader feels as "it kept sliding after I stopped". So the glide watches its
/// own clock: once `idleWindow` has passed with no new aim, the input has stopped, and what is
/// still owed is delivered at `maximumSpeed` instead of exponentially - a few ticks at the very
/// most, and then the glide is over.
///
/// ## What the glide may still owe is bounded (`maximumLead`)
///
/// Finishing at the ceiling is not enough on its own, and that is what the reader then reported:
/// a spin accumulates distance faster than the ceiling can deliver it, so the destination runs away
/// from the offset, and when the wheel stops the glide still owes the whole backlog and pays it out
/// at 2000 pt/s anyway. Measured through the real event path: ten notches 10 ms apart ask for
/// 744 pt; the offset can deliver at most 200 pt during the 100 ms they take, so the glide owes
/// 531 pt when the last notch lands and scrolls for a further 313 ms after the wheel has stopped.
/// The reader's words for that were "it will not stop until it has smoothly scrolled all the way
/// there".
///
/// So the backlog itself is bounded. `aim(at:from:mostAhead:)` clamps the destination so it never
/// leads the offset by more than `maximumLead` points; the distance that would have gone beyond
/// that is **dropped rather than queued**. The clamp does not restart the approach - a burst still
/// accumulates as far as the lead allows and reads as one continuous motion - but when the wheel
/// stops, the distance still owed is at most `maximumLead`, and it is delivered at the ceiling:
/// 48 ms for the 96 pt lead, whatever the wheel was doing before. The motion ends `idleWindow`
/// later still - 48 ms, how long a gap in the aims means "the wheel stopped" - so the whole tail is
/// that window plus those 48 ms. Measured through the real event path: one notch still tails 32 pt
/// in 40 ms, a 50 ms burst 93 pt in 56 ms, and a 10 ms spin 96 pt in 58 ms - against 32 pt, 99 pt
/// and 531 pt before, the last of them spread over 313 ms. What `idleWindow` is and how the offset
/// gets there are unchanged.
///
/// The trade, stated because it is real: a fast enough spin now scrolls less far than the notches
/// nominally asked for. Measured on the same event path, ten notches 10 ms apart ask for 744 pt and
/// deliver 262 pt (35%); the dropped 482 pt is distance the ceiling could not have covered before
/// the wheel stopped anyway. That is the right way round. A notch the reader has already scrolled
/// past is stale: what has to track the wheel is the motion, 1:1 in time, not a destination
/// computed from the wheel's speed, and every point still owed after the input stops is the drift
/// the reader complained about. A single notch is never truncated and a 50 ms burst - the cadence a
/// hand actually produces - still delivers all 360 pt of its 360, so what the reader feels at
/// ordinary speeds is intact; the 25 ms burst keeps 64% and the 10 ms spin 35%.
///
/// `maximumLead` is derived rather than picked: `defaultMaximumSpeed * idleWindow`, 96 pt. That is
/// what the ceiling can deliver during the gap that means "the wheel stopped", so it is the widest
/// backlog whose delivery the reader has already waited out - and therefore the widest that does
/// not add tail. Measured against the alternatives: 64 pt truncated three back-to-back notches to
/// 64 of their 96 pt and cost a 50 ms burst 12% of its distance, while 128 pt bought 9% more
/// distance on a 10 ms spin and lengthened the worst tail from 58 ms to 64 ms. The tail the reader
/// feels is this lead plus the idle window that has to expire first, both bounded, so it does not
/// grow with the spin.
///
/// Keyboard paging is deliberately exempt (`AppState.scrollByKeyboardStep`): "next page" is a
/// destination, not a speed, so a Page Down still travels its whole 0.9 screen and keeps the tail it
/// had - one screen at 2000 pt/s, ~225 ms for a 450 pt page on a 500 pt viewport. A full page of
/// debt is exactly what must *not* be paid after a wheel has stopped, and exactly what a page key
/// is asking for.
public struct ScrollGlide {
    /// Time constant of the approach: the offset covers ~63% of what is left in this long.
    ///
    /// Short on purpose, and short relative to the old 55 ms: a wheel burst asks for more distance
    /// per second than a slow approach can deliver, so the offset fell further and further behind
    /// the destination, and that debt is what slid out after the last notch. 32 ms is also where
    /// the quarter-of-the-remainder cap below meets the driver's 8 ms tick: a tick that takes the
    /// nominal 8 ms moves the cap, a shorter one follows the exponential, and a longer one (a busy
    /// main thread) is still held to the cap.
    public static let timeConstant: TimeInterval = 0.032
    /// Distance at which the glide is over, in points. Below this the remaining motion cannot be
    /// seen, and the offset is placed exactly on the target instead of approaching it forever.
    public static let settleDistance: CGFloat = 0.5
    /// How long a gap in the aims means "the wheel stopped", in seconds.
    ///
    /// Longer than the gap between the notches of the fastest wheel spin (a classic wheel reports
    /// at 20-60 ms), so a burst stays one continuous glide, and short enough that the debt left
    /// when the reader stops is delivered within a frame or two of them letting go.
    public static let idleWindow: TimeInterval = 0.048
    /// Ceiling on how fast the offset may move, in points per second, measured on screen.
    ///
    /// An exponential approach alone starts at its fastest — for a burst of notches that is a
    /// large fraction of the whole distance in the first tick, which is the jump this type exists
    /// to remove. The cap turns the start of the motion into a fast-but-readable speed and lets
    /// the approach slow into the destination. It is also the only bound on the ticks that finish
    /// the distance once the wheel has stopped, so landing the last of a fast spin cannot become
    /// a jump either: it travels no faster than a fast scroll is already allowed to.
    public static let defaultMaximumSpeed: CGFloat = 2000

    /// How far the destination may lead the offset, in points: the largest backlog a glide may
    /// still owe when the input stops.
    ///
    /// The complaint this exists for, and the measurements behind the number, are in the type's
    /// documentation. In short: without it a fast spin owes the whole burst, and the wheel having
    /// stopped makes no difference to the glide - it delivers the backlog at the ceiling and the
    /// page keeps scrolling for as long as that takes (313 ms for ten notches 10 ms apart).
    ///
    /// 96 pt is not a taste: it is `defaultMaximumSpeed * idleWindow`, the distance the ceiling can
    /// *deliver* during the gap that means "the wheel stopped". A narrower lead would truncate
    /// notches the glide could still have delivered before the reader let go - three 32 pt notches
    /// fired back to back are 96 pt and are meant to arrive - and a wider one would only owe
    /// distance the ceiling had no way of delivering in time anyway. Measured on the real event
    /// path: a single notch is untouched, a 50 ms burst delivers all 360 pt of its 360, and the
    /// worst tail (a 10 ms spin) is 96 pt in 58 ms of wall clock, against 531 pt / 313 ms before.
    ///
    /// Like the ceiling, the lead is a *screen* distance: `AppState` divides it by the zoom, so the
    /// tail is the same 96 screen points of motion - 48 ms at 100% - at every zoom level. Zoomed to
    /// 400% that is 24 content points of a page rather than 96, which is why the tail does not grow
    /// on screen as the reader zooms in.
    public static let maximumLead: CGFloat = 96

    /// Where the glide is heading; nil when there is no glide in flight.
    public private(set) var destination: CGFloat?
    /// The current speed ceiling, in the same points per second the rest of the type uses.
    public private(set) var maximumSpeed: CGFloat = ScrollGlide.defaultMaximumSpeed
    /// How far the destination of the current glide may lead its offset, or nil for no bound.
    /// `aim` sets it from `mostAhead`; `step` reads it when the input stops.
    public private(set) var maximumLead: CGFloat? = ScrollGlide.maximumLead
    /// Where the offset is finishing, once the input has stopped: the destination capped to
    /// `maximumLead`. Nil until that tick, so "has the bound been applied" is not a guess.
    private var finishTarget: CGFloat?
    /// Seconds of caller time since the last aim: how long the wheel has been quiet.
    public private(set) var idleTime: TimeInterval = 0

    public init() {}

    public var isActive: Bool { destination != nil }

    /// True once the input has stopped and the rest of the distance is being finished rather than
    /// eased into. Read-only: the checks drive the arithmetic through it.
    public var isFinishing: Bool { destination != nil && idleTime > Self.idleWindow }

    /// Aims at an absolute offset. A new notch **moves the destination** rather than restarting
    /// the motion, which is what lets a burst of notches accumulate into one continuous scroll.
    ///
    /// `from` is where the offset is now, and `mostAhead` is how far the destination may lead it
    /// (nil for no bound, which is what the keyboard's page steps pass). Both are optional so the
    /// arithmetic stays callable without a document, but a caller that wants the backlog bounded
    /// - every wheel notch does - has to pass them: without them there is nothing to bound the
    /// destination against, and the glide goes back to owing the whole spin.
    ///
    /// `maximumSpeed` is passed per aim because the caller knows the zoom: 2000 content points per
    /// second is a fast scroll at 100% and a crawl at 400%, where one screen point is a quarter of
    /// a content point. The lead is in the same content points, so it is one notch of screen
    /// distance at every zoom.
    public mutating func aim(at offset: CGFloat, from current: CGFloat? = nil,
                             mostAhead lead: CGFloat? = ScrollGlide.maximumLead,
                             maximumSpeed: CGFloat = ScrollGlide.defaultMaximumSpeed) {
        var target = offset
        if let current, let lead {
            let limit = current + (offset >= current ? lead : -lead)
            target = offset >= current ? min(offset, limit) : max(offset, limit)
        }
        destination = target
        maximumLead = lead
        self.maximumSpeed = max(1, maximumSpeed)
        // A new notch is new intent: the finish bound is decided again from where the offset is now.
        finishTarget = nil
        idleTime = 0
    }

    /// Stops gliding: continuous input (a trackpad) has taken over, or the document changed.
    public mutating func cancel() {
        destination = nil
        maximumLead = Self.maximumLead
        finishTarget = nil
        idleTime = 0
    }

    /// The longest a tick may count as, in seconds: one 120 Hz frame of the speed ceiling, 16 pt at
    /// 100% zoom. It bounds the approach and the finish alike.
    ///
    /// A busy main thread is the case this exists for. The ceiling is a *speed*, so without a bound
    /// a tick that arrives 40 ms late would try to cover 40 ms of it in one go, which is the jump
    /// this type exists to remove - and it was measured on a loaded CI machine, where a 96-point
    /// glide was published as three offsets, one of them 72 pt. Counting a long tick as one frame
    /// makes a stall lengthen the glide instead of coarsening it, which is the right trade: a
    /// stalled main thread is not drawing frames anyway.
    ///
    /// The trade, stated: a machine whose ticks are longer than this catches its backlog up at the
    /// frame rate rather than at the ceiling rate, so 282 pt owed takes 18 ticks instead of 4. That
    /// is the right way round - those ticks are long precisely because no frames were drawn, and
    /// the alternative is one 80 pt jump in the first frame that does get drawn.
    public static let maximumStepTime: TimeInterval = 0.008

    /// The next offset toward the destination after `elapsed` seconds, and whether the glide is
    /// finished with it.
    ///
    /// While the notches keep coming the step is the exact exponential decay of what is left over
    /// the tick, so the motion slows into the target instead of stopping dead, it never overshoots,
    /// and - because the step is a function of *time* rather than of how often this is called -
    /// a burst is delivered at the ceiling rate rather than at a rate set by the driver's tick.
    /// That distinction is what a fast spin needs: `WheelMotion` asks for ~2000 pt/s, and an
    /// approach that re-derived its speed from each tick could only ever deliver ~780 pt/s, so the
    /// destination would run away from the offset even when the reader was merely spinning the
    /// wheel as fast as the ceiling allows. The step is capped at `maximumSpeed` all the same, so
    /// nothing moves faster than a fast scroll is allowed to.
    ///
    /// Once the notches stop, the distance still owed is delivered at that same ceiling - one
    /// `maximumStepTime` of it per tick, however late the tick is - and the glide is over. Nothing
    /// is left to decay, so there is no tail after the last wheel event, and what it delivers is at
    /// most the lead `aim` allowed, which is why that tail is short.
    public mutating func step(from current: CGFloat, elapsed: TimeInterval) -> (offset: CGFloat, finished: Bool) {
        guard let destination else { return (current, true) }
        idleTime += max(0, elapsed)
        // Finishing aims at `finishTarget` rather than at the destination: the two are the same
        // while `aim` keeps the backlog inside the lead, and where they differ - a destination that
        // escaped the bound - the difference is dropped instead of delivered. This is the one place
        // that decides what the offset still owes when the input stops, so it is where the bound
        // has to hold even if a caller aims without one.
        var target = finishTarget ?? destination
        let remaining: CGFloat
        if finishTarget == nil, idleTime > Self.idleWindow {
            let owed = maximumLead.map { max(-$0, min($0, destination - current)) } ?? (destination - current)
            finishTarget = current + owed
            target = current + owed
            remaining = owed
        } else {
            remaining = target - current
        }
        if abs(remaining) <= Self.settleDistance { return (target, true) }
        // A tick longer than one frame counts as one frame: see `maximumStepTime`. Both branches
        // use it, so a stalled main thread lengthens a glide instead of coarsening it.
        let counted = min(max(0, elapsed), Self.maximumStepTime)
        let travel: CGFloat
        if idleTime > Self.idleWindow {
            // The wheel has stopped: finish what it asked for, at the speed ceiling.
            travel = min(abs(remaining), maximumSpeed * CGFloat(counted))
        } else {
            // The exact exponential over the tick, not a fraction of what is left: at the driver's
            // 8 ms tick the two agree, and when a tick is long enough to matter the exponential has
            // already saturated - which is what keeps the delivery rate a property of the clock.
            let decayed = abs(remaining) * (1 - exp(-CGFloat(counted) / CGFloat(Self.timeConstant)))
            travel = min(abs(remaining), min(decayed, maximumSpeed * CGFloat(counted)))
        }
        let direction: CGFloat = remaining < 0 ? -1 : 1
        let next = current + direction * travel
        // Landing is reported on the tick that lands, not on the one after it: "finished" is what
        // stops the driver, and a driver that has to tick once more to hear it is a tick of tail.
        if abs(target - next) <= Self.settleDistance { return (target, true) }
        return (next, false)
    }
}
