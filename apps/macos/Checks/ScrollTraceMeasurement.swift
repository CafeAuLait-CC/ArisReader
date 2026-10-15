import AppKit
import ArisReaderKit
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
/// Usage: ArisReaderChecks --measure-scroll-trace [root]
extension ReaderChecks {
    @MainActor static func measureScrollTrace() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst(2).first
            ?? FileManager.default.currentDirectoryPath)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-scroll-trace-\(UUID())")
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
        func trace(_ label: String, wheel: Int32, precise: Bool, count: Int,
                   stride nanoseconds: CGEventTimestamp,
                   settleMilliseconds: Int) async -> [String: Any] {
            state.scroll(toFraction: 0.35)
            let start = state.scrollYPt
            var records: [[String: Any]] = []
            for index in 0..<count {
                let event = event(wheel: wheel, precise: precise,
                                  timestamp: CGEventTimestamp(index) * nanoseconds)
                let before = state.scrollYPt
                view.scrollWheel(with: event)
                records.append([
                    "index": index,
                    "scrolling_delta_y": event.scrollingDeltaY,
                    "precise": event.hasPreciseScrollingDeltas,
                    "phase": event.phase.rawValue,
                    "momentum_phase": event.momentumPhase.rawValue,
                    "offset_before": before,
                    "offset_immediately_after": state.scrollYPt,
                    "immediate_step": state.scrollYPt - before,
                    "destination": state.scrollDestinationYPt ?? state.scrollYPt,
                ])
            }
            var sampled: [Double] = []
            let interval = max(1, settleMilliseconds / 60)
            let samples = settleMilliseconds > 0 ? 60 : 0
            for _ in 0..<samples {
                sampled.append(Double(state.scrollYPt))
                try? await Task.sleep(for: .milliseconds(interval))
            }
            sampled.append(Double(state.scrollYPt))
            let steps = zip(sampled, sampled.dropFirst()).map { $1 - $0 }
            return [
                "kind": label,
                "start": start,
                "events": records,
                "destination_after_events": state.scrollDestinationYPt ?? state.scrollYPt,
                "settled": state.scrollYPt,
                "sample_ms": interval,
                "samples": sampled,
                "distinct_offsets": Set(sampled.map { ($0 * 1000).rounded() / 1000 }).count,
                "largest_sample_step": steps.map { abs($0) }.max() ?? 0,
            ]
        }

        // A classic wheel: one line per notch, no precise deltas, no phases.
        let wheel = await trace("wheel-line", wheel: 1, precise: false, count: 6,
                                stride: 50_000_000, settleMilliseconds: 400)
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
