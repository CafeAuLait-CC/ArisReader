import CoreGraphics
import Foundation

/// Animation arithmetic for keyboard navigation. Wheel input is applied immediately by
/// `AppState.scrollByWheelStep` and never enters this destination-based animation.
/// The optional lead bound remains available to callers of the standalone arithmetic.
public struct ScrollGlide {
    /// Exponential approach time constant in seconds.
    public static let timeConstant: TimeInterval = 0.032
    /// Snap the final subpixel remainder to the destination.
    public static let settleDistance: CGFloat = 0.5
    /// After this gap between aims, finish at the speed ceiling.
    public static let idleWindow: TimeInterval = 0.048
    /// Maximum travel speed in screen points per second.
    public static let defaultMaximumSpeed: CGFloat = 2000

    /// Optional lead bound for standalone callers; keyboard navigation passes nil.
    public static let maximumLead: CGFloat = 96

    public private(set) var destination: CGFloat?
    public private(set) var maximumSpeed: CGFloat = ScrollGlide.defaultMaximumSpeed
    public private(set) var maximumLead: CGFloat? = ScrollGlide.maximumLead
    private var finishTarget: CGFloat?
    public private(set) var idleTime: TimeInterval = 0

    public init() {}

    public var isActive: Bool { destination != nil }

    public var isFinishing: Bool { destination != nil && idleTime > Self.idleWindow }

    /// Move the destination, optionally bounding its distance from the current offset.
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

    public mutating func cancel() {
        destination = nil
        maximumLead = Self.maximumLead
        finishTarget = nil
        idleTime = 0
    }

    /// Count a delayed tick as at most one frame to avoid a large jump.
    public static let maximumStepTime: TimeInterval = 0.008

    /// Advance the animation on the caller’s clock.
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
