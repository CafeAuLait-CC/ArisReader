import AppKit
import LyraReaderKit
import Foundation

/// What a scripted scroll actually does to the model offset, event by event.
///
/// This is the evidence behind the smooth-scrolling work: it feeds the real `scrollWheel(with:)`
/// path the two kinds of scroll input macOS produces and prints the raw event fields next to the
/// delta the app derived from them, the offset that came out, and the offsets the glide passes
/// through between two events — the part a screenshot could never show.
///
/// It is a measurement, not a check: nothing here asserts, it reports.
///
/// Usage: LyraReaderChecks --measure-scroll-trace [root]
extension ReaderChecks {
    @MainActor static func measureScrollTrace() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst(2).first
            ?? FileManager.default.currentDirectoryPath)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-reader-scroll-trace-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let copy = temporary.appendingPathComponent("document.pdf")
        try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/multipage.pdf"),
                                         to: copy)

        let state = AppState(engine: try RustEngine(), preferFullPageRasters: false)
        state.setViewportSize(CGSize(width: 700, height: 500))
        guard state.open(url: copy) else {
            throw NSError(domain: "ScrollTrace", code: 1)
        }

        let view = MetalCanvasView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        view.onScroll = { delta in state.scroll(byScreenPoints: delta) }
        view.onScrollStep = { delta in state.scrollByWheelStep(delta) }
        view.onKeyboardStep = { delta in state.scrollByKeyboardStep(delta) }
        view.onZoomScroll = { delta, anchor in
            state.zoomByScroll(delta: delta, anchorViewY: anchor)
        }
        view.interactionSnapshot = { (state.canvasPages, state.scrollYPt, state.zoomFactor) }

        // The event location conversion depends on the display in the session; measure it rather
        // than assuming, so the pointer lands inside the canvas.
        let displayOffset = scrollDisplayOffset()
        func event(wheel: Int32, precise: Bool, timestamp: CGEventTimestamp) -> NSEvent {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil,
                                   units: precise ? .pixel : .line,
                                   wheelCount: 1, wheel1: wheel, wheel2: 0, wheel3: 0) else {
                fatalError("scroll event")
            }
            cg.location = CGPoint(x: 350, y: displayOffset - 250)
            cg.timestamp = timestamp
            guard let event = NSEvent(cgEvent: cg) else { fatalError("scroll event") }
            return event
        }

        /// Feeds `count` events and reports the offset around each one, then samples the offsets
        /// that follow — for a classic wheel that is the glide, and it is where the difference
        /// between a jump and a slide lives.
        ///
        /// `realTimeStrideMilliseconds` is what makes the tail honest: a physical wheel delivers
        /// its notches that far apart in wall-clock time, so the glide gets to work between them.
        /// Feeding the same events back to back (the default) measures the worst case instead —
        /// the whole burst still owed when the last event lands.
        func trace(_ label: String, wheel: Int32, precise: Bool, count: Int,
                   stride nanoseconds: CGEventTimestamp,
                   settleMilliseconds: Int,
                   realTimeStrideMilliseconds: Int = 0) async -> [String: Any] {
            state.scroll(toFraction: 0.35)
            let start = state.scrollYPt
            var records: [[String: Any]] = []
            var lastEventUptime: Double = 0
            for index in 0..<count {
                if index > 0, realTimeStrideMilliseconds > 0 {
                    try? await Task.sleep(for: .milliseconds(realTimeStrideMilliseconds))
                }
                // A real burst carries the wall clock in the event: `WheelMotion` reads the
                // timestamp to decide how fast the wheel is spinning.
                let timestamp = realTimeStrideMilliseconds > 0
                    ? CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
                    : CGEventTimestamp(index) * nanoseconds
                let event = event(wheel: wheel, precise: precise, timestamp: timestamp)
                let before = state.scrollYPt
                lastEventUptime = ProcessInfo.processInfo.systemUptime
                let destinationBefore = state.scrollDestinationYPt ?? before
                view.scrollWheel(with: event)
                records.append([
                    "index": index,
                    "scrolling_delta_y": event.scrollingDeltaY,
                    // What the notch aimed at after the lead bound: the driver publishes its
                    // offsets asynchronously, so this - not the offset - is what is known here.
                    "notch_aimed_pt": (state.scrollDestinationYPt ?? state.scrollYPt) - destinationBefore,
                    "precise": event.hasPreciseScrollingDeltas,
                    "phase": event.phase.rawValue,
                    "momentum_phase": event.momentumPhase.rawValue,
                    "uptime": lastEventUptime,
                    "offset_before": before,
                    "offset_immediately_after": state.scrollYPt,
                    "immediate_step": state.scrollYPt - before,
                    "owed_before_event": destinationBefore - before,
                    "destination": state.scrollDestinationYPt ?? state.scrollYPt,
                ])
            }
            let offsetAtLastEvent = state.scrollYPt
            let destinationAtLastEvent = state.scrollDestinationYPt ?? offsetAtLastEvent
            var sampled: [Double] = []
            var sampleUptimes: [Double] = []
            let interval = max(1, settleMilliseconds / 60)
            let samples = settleMilliseconds > 0 ? 60 : 0
            for _ in 0..<samples {
                sampled.append(Double(state.scrollYPt))
                sampleUptimes.append(ProcessInfo.processInfo.systemUptime)
                try? await Task.sleep(for: .milliseconds(interval))
            }
            sampled.append(Double(state.scrollYPt))
            sampleUptimes.append(ProcessInfo.processInfo.systemUptime)
            let steps = zip(sampled, sampled.dropFirst()).map { $1 - $0 }
            // The tail: everything the offset still does after the last wheel event. Distance is
            // measured from the offset the last event left behind, duration from that event to the
            // last sample that was still moving.
            let settled = sampled.last ?? Double(state.scrollYPt)
            let lastMoving = sampled.indices.last { abs(sampled[$0] - settled) > 0.001 }
            let tailDuration = lastMoving.map { (sampleUptimes[$0] - lastEventUptime) * 1000 } ?? 0
            return [
                "kind": label,
                "start": start,
                "events": records,
                "destination_after_events": state.scrollDestinationYPt ?? state.scrollYPt,
                "offset_at_last_event": offsetAtLastEvent,
                "owed_at_last_event": destinationAtLastEvent - offsetAtLastEvent,
                // What the notches aimed at, and what of it arrived. The two differ once the lead
                // bound drops a backlog that cannot be delivered before the wheel stops; the raw
                // wheel ask is in `scrolling_delta_y` next to each event's timestamp.
                "aimed_pt": records.reduce(0) { $0 + ($1["notch_aimed_pt"] as? CGFloat ?? 0) },
                "delivered_pt": state.scrollYPt - start,
                "settled": state.scrollYPt,
                "tail_pt": settled - offsetAtLastEvent,
                "tail_ms": tailDuration,
                "sample_ms": interval,
                "sample_uptimes": sampleUptimes,
                "samples": sampled,
                "distinct_offsets": Set(sampled.map { ($0 * 1000).rounded() / 1000 }).count,
                "largest_sample_step": steps.map { abs($0) }.max() ?? 0,
            ]
        }

        // A classic wheel: one line per notch, no precise deltas, no phases.
        let wheel = await trace("wheel-line", wheel: 1, precise: false, count: 6,
                                stride: 50_000_000, settleMilliseconds: 400)
        // The same notches, delivered the way a hand delivers them: 50 ms apart in wall clock,
        // so the glide is allowed to work between events. This is the tail the reader feels.
        let burst50 = await trace("wheel-burst-50ms", wheel: 1, precise: false, count: 6,
                                  stride: 50_000_000, settleMilliseconds: 500,
                                  realTimeStrideMilliseconds: 50)
        let burst25 = await trace("wheel-burst-25ms", wheel: 1, precise: false, count: 8,
                                  stride: 25_000_000, settleMilliseconds: 500,
                                  realTimeStrideMilliseconds: 25)
        // A spin: notches every 10 ms, faster than the glide's ceiling can deliver them. This is the
        // scenario the lead bound exists for - the backlog a wheel builds when it is spun hard, and
        // what is still owed when it stops.
        let spin = await trace("wheel-spin-10ms", wheel: 1, precise: false, count: 10,
                               stride: 10_000_000, settleMilliseconds: 500,
                               realTimeStrideMilliseconds: 10)
        let burst20 = await trace("wheel-burst-20ms", wheel: 1, precise: false, count: 5,
                                  stride: 20_000_000, settleMilliseconds: 500,
                                  realTimeStrideMilliseconds: 20)
        let single = await trace("wheel-single-notch", wheel: 1, precise: false, count: 1,
                                 stride: 50_000_000, settleMilliseconds: 500)
        // A trackpad: precise deltas a few points wide, as the system delivers them.
        let trackpad = await trace("trackpad-precise", wheel: 7, precise: true, count: 8,
                                   stride: 16_000_000, settleMilliseconds: 0)

        // Does the offset keep a fractional part, or is anything snapping it?
        state.scroll(toFraction: 0.35)
        var quantisation: [[String: Any]] = []
        for wheel in [Int32(3), Int32(4), Int32(5)] {
            let before = state.scrollYPt
            view.scrollWheel(with: event(wheel: wheel, precise: true, timestamp: 0))
            quantisation.append(["wheel": wheel, "offset_before": before,
                                 "offset_after": state.scrollYPt,
                                 "step": state.scrollYPt - before])
        }

        // The profile the app derives from a notch burst, without any event plumbing.
        var motion = WheelMotion()
        var profile: [[String: Any]] = []
        for index in 0..<8 {
            let timestamp = 1.0 + Double(index) * 0.05
            let delta = motion.delta(scrollingDeltaY: 1, precise: false, timestamp: timestamp)
            profile.append(["timestamp": timestamp, "delta": delta])
        }

        // Keyboard paging goes through the same stepped input as a wheel notch.
        state.scroll(toFraction: 0.35)
        let beforeKey = state.scrollYPt
        view.keyDown(with: keyEvent("\u{F72D}"))
        let afterKeyImmediately = state.scrollYPt
        let keyDestination = state.scrollDestinationYPt
        var keySamples: [Double] = []
        for _ in 0..<40 {
            keySamples.append(Double(state.scrollYPt))
            try? await Task.sleep(for: .milliseconds(10))
        }
        keySamples.append(Double(state.scrollYPt))

        let result: [String: Any] = [
            "scope": "model offsets from the real scrollWheel(with:) path; no display, no GPU timing",
            "zoom_percent": state.zoomPercent,
            "wheel_line": wheel,
            "wheel_burst_50ms": burst50,
            "wheel_burst_25ms": burst25,
            "wheel_burst_20ms": burst20,
            "wheel_spin_10ms": spin,
            "wheel_single_notch": single,
            "glide": [
                "time_constant_ms": ScrollGlide.timeConstant * 1000,
                "settle_distance_pt": ScrollGlide.settleDistance,
                "maximum_step_time_ms": ScrollGlide.maximumStepTime * 1000,
                "maximum_speed_pt_s": ScrollGlide.defaultMaximumSpeed,
                // The bound on what a glide may still owe when the input stops: the number behind
                // the tail this measurement reports.
                "maximum_lead_pt": ScrollGlide.maximumLead,
                "idle_window_ms": ScrollGlide.idleWindow * 1000,
            ],
            "trackpad_precise": trackpad,
            "quantisation_probe": quantisation,
            "wheel_motion_profile": profile,
            "keyboard_page_down": [
                "before": beforeKey,
                "immediately_after": afterKeyImmediately,
                "destination": keyDestination ?? beforeKey,
                "samples": keySamples,
                "settled": state.scrollYPt,
                "distinct_offsets": Set(keySamples.map { ($0 * 1000).rounded() / 1000 }).count,
            ],
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
                     as: UTF8.self))
    }

    @MainActor private static func scrollDisplayOffset() -> CGFloat {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                               wheel1: 1, wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: cg) else { return 900 }
        return event.locationInWindow.y
    }

    @MainActor private static func keyEvent(_ characters: String) -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           characters: characters,
                                           charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: 121) else {
            fatalError("key event")
        }
        return event
    }
}
