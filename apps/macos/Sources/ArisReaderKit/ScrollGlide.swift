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
public struct ScrollGlide {
    /// Time constant of the approach: the offset covers ~63% of what is left in this long, so a
    /// one-notch step is visually over in about 0.15 s and is untouched by frame rate.
    public static let timeConstant: TimeInterval = 0.055
    /// Distance at which the glide is over, in points. Below this the remaining motion cannot be
    /// seen, and the offset is placed exactly on the target instead of approaching it forever.
    public static let settleDistance: CGFloat = 0.5
    /// Ceiling on how fast the offset may move, in points per second, measured on screen.
    ///
    /// An exponential approach alone starts at its fastest — for a burst of notches that is a
    /// large fraction of the whole distance in the first tick, which is the jump this type exists
    /// to remove. The cap turns the start of the motion into a fast-but-readable speed and lets
    /// the approach slow into the destination.
    public static let defaultMaximumSpeed: CGFloat = 2000

    /// Where the glide is heading; nil when there is no glide in flight.
    public private(set) var destination: CGFloat?
    /// The current speed ceiling, in the same points per second the rest of the type uses.
    public private(set) var maximumSpeed: CGFloat = ScrollGlide.defaultMaximumSpeed

    public init() {}

    public var isActive: Bool { destination != nil }

    /// Aims at an absolute offset. A new notch **moves the destination** rather than restarting
    /// the motion, which is what lets a burst of notches accumulate into one continuous scroll.
    ///
    /// `maximumSpeed` is passed per aim because the caller knows the zoom: 2000 content points per
    /// second is a fast scroll at 100% and a crawl at 400%, where one screen point is a quarter of
    /// a content point.
    public mutating func aim(at offset: CGFloat, maximumSpeed: CGFloat = ScrollGlide.defaultMaximumSpeed) {
        destination = offset
        self.maximumSpeed = max(1, maximumSpeed)
    }

    /// Stops gliding: continuous input (a trackpad) has taken over, or the document changed.
    public mutating func cancel() {
        destination = nil
    }

    /// Largest share of the remaining distance one tick may cover.
    ///
    /// A tick that arrives late (a busy main thread) would otherwise take a proportionally larger
    /// step, and the glide would look exactly like the jump it replaced - measured on a loaded CI
    /// machine, where a 96-point glide reached its destination in seven published offsets. Capping
    /// the share makes a stall lengthen the glide instead of coarsening it, which is the right
    /// trade: a stalled main thread is not drawing frames anyway.
    public static let maximumTickFraction: CGFloat = 0.25

    /// The next offset toward the destination after `elapsed` seconds, and whether the glide is
    /// finished with it.
    ///
    /// The step is proportional to the distance that is left, so the motion slows into the target
    /// instead of stopping dead, and it never overshoots.
    public func step(from current: CGFloat, elapsed: TimeInterval) -> (offset: CGFloat, finished: Bool) {
        guard let destination else { return (current, true) }
        let remaining = destination - current
        if abs(remaining) <= Self.settleDistance { return (destination, true) }
        let fraction = min(Self.maximumTickFraction, min(1, max(0, elapsed / Self.timeConstant)))
        let approach = min(abs(remaining) * fraction, maximumSpeed * CGFloat(max(0, elapsed)))
        let direction: CGFloat = remaining < 0 ? -1 : 1
        return (current + direction * min(approach, abs(remaining)), false)
    }
}
