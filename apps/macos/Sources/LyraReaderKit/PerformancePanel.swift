import AppKit
import SwiftUI

/// The keyboard binding the performance panel introduces.
///
/// ⌥⌘P was chosen because it is free on both sides of the shortcut map: the native menu uses
/// ⌘P for Print, and the Rust keymap in `crates/lyra-reader-session/src/keymap.rs` binds ⇧⌘P
/// (PreviewCitation), ⌥⌘F (full screen) and ⌥⌘H (chrome) but nothing with Option-Command-P.
/// The rest of the native menu uses o / s / ⇧s / e / ⌥i / 0 / 9 / ⇧9 / + / − / ← / → / [ / ] /
/// g / ⇧g / ⌥s / ⇧a / ⇧l / d / ⇧b / 1 / 3 / ⇧r / ⌥r / , — none of them ⌥⌘P. The checks in
/// `PerformancePanelChecks` pin the collision test so a future binding cannot quietly take it.
public enum PerformancePanelShortcut {
    public static let label = "Performance Panel"
    public static let key: KeyEquivalent = "p"
    public static let modifiers: EventModifiers = [.command, .option]
    /// Every chord the native menu already uses, as the check's collision list.
    public static let reservedNativeChords: [(KeyEquivalent, EventModifiers)] = [
        ("o", [.command]), ("s", [.command]), ("s", [.command, .shift]),
        ("e", [.command]), ("p", [.command]),
        ("i", [.command, .option]), ("0", [.command]), ("9", [.command]),
        ("9", [.command, .shift]), ("+", [.command]), ("-", [.command]),
        (.leftArrow, [.command]), (.rightArrow, [.command]),
        ("[", [.command]), ("]", [.command]),
        ("g", [.command]), ("g", [.command, .shift]),
        ("s", [.command, .option]), ("a", [.command, .shift]),
        ("l", [.command, .shift]), ("d", [.command]), ("b", [.command, .shift]),
        ("1", [.command]), ("3", [.command]),
        ("r", [.command, .shift]), ("r", [.command, .option]),
        (",", [.command]),
    ]
}

/// One frame observation from the canvas, delivered only while something is sampling.
public struct CanvasFrameSample: Sendable {
    public var presented: Bool
    /// CPU microseconds the engine reports for producing and presenting this frame.
    public var elapsedMicroseconds: UInt32
    /// Pyramid-tile quads that were submitted in the frame.
    public var tileQuadCount: Int
    public var quadCount: Int
    /// Engine counter: frames this surface has presented since the surface was attached.
    public var surfaceFrameIndex: UInt64
}

/// The stable seam between the Metal canvas and the performance panel.
///
/// The canvas holds this object weakly and calls ``record(_:)`` only when ``wantsFrameSamples``
/// is true, so a closed panel costs one nil/bool check per frame and no allocation, no timer and
/// no retained sample. The panel's controller owns the sampling window; the one-shot
/// open-to-first-frame measurement is the only other reason samples are taken.
@MainActor
public final class CanvasPerformanceProbe {
    /// The panel is open and a frame-time window is wanted.
    public var isSampling = false
    /// The first *presented* frame after a document-open request is still wanted.
    private var awaitingOpenFrame = false
    private var openStartedAt: TimeInterval?
    /// Measured once per document open; nil means no presented frame has been seen yet.
    public private(set) var openToFirstFrameMilliseconds: Double?

    /// Present frame times, oldest first. Bounded so a long session cannot grow it.
    private var presentedMillis: [Double] = []
    /// Wall-clock intervals between *consecutive presented* samples, oldest first. A skipped
    /// sample clears the anchor, so an occlusion gap is not reported as one enormous interval.
    private var intervalMillis: [Double] = []
    private var lastPresentedAt: TimeInterval?
    /// The engine's CPU time for the last presented frame.
    public private(set) var lastPresentedMilliseconds: Double?
    /// Wall-clock time between the last two consecutive presented frames.
    public private(set) var lastIntervalMilliseconds: Double?
    public private(set) var lastPresentedTileQuads: Int?
    public private(set) var lastPresentedQuadCount: Int?
    public private(set) var lastPresentedSurfaceFrameIndex: UInt64?
    public private(set) var lastSamplePresented: Bool?
    private(set) var presentedSamples = 0
    private(set) var skippedSamples = 0
    private(set) var recordNanoseconds: UInt64 = 0
    private(set) var recordCalls: UInt64 = 0

    /// How many frame times make the percentile window. At 60 Hz this is two seconds; on a
    /// slower renderer it spans proportionally longer, and the panel states the count.
    public static let frameWindowCapacity = 120

    public init() {}

    /// The nil check is the whole closed-panel cost: the canvas asks this before doing any work.
    public var wantsFrameSamples: Bool { isSampling || awaitingOpenFrame }

    /// Starts the one-shot "how long until the document's first presented frame" measurement.
    ///
    /// Called by `AppState.loadDocument` before the engine opens the file. This is not a timer:
    /// it is a flag plus a start timestamp, cleared by the first presented frame.
    public func beginOpenToFirstFrameMeasurement() {
        openStartedAt = ProcessInfo.processInfo.systemUptime
        openToFirstFrameMilliseconds = nil
        awaitingOpenFrame = true
    }

    /// Called from `MetalCanvasView.renderFrame` for every attempted frame while sampling or
    /// while the open measurement is pending. Cheap by design: a bounded append and one clock
    /// reading; the panel reports the measured cost of this call.
    public func record(_ sample: CanvasFrameSample) {
        let started = DispatchTime.now().uptimeNanoseconds

        if awaitingOpenFrame, sample.presented {
            awaitingOpenFrame = false
            if let openStartedAt {
                openToFirstFrameMilliseconds = max(
                    0, (ProcessInfo.processInfo.systemUptime - openStartedAt) * 1000
                )
            }
        }

        // Sampling cost is measured only while open: a closed panel does not pay for the timing.
        guard isSampling else { return }

        lastSamplePresented = sample.presented
        if sample.presented {
            presentedSamples += 1
            let millis = Double(sample.elapsedMicroseconds) / 1000
            lastPresentedMilliseconds = millis
            lastPresentedTileQuads = sample.tileQuadCount
            lastPresentedQuadCount = sample.quadCount
            lastPresentedSurfaceFrameIndex = sample.surfaceFrameIndex
            presentedMillis.append(millis)
            if presentedMillis.count > Self.frameWindowCapacity {
                presentedMillis.removeFirst(presentedMillis.count - Self.frameWindowCapacity)
            }
            // Wall-clock interval between consecutive presented frames. This is the number a
            // pacing regression shows up in; the engine's elapsed_us above is CPU submit time.
            let now = ProcessInfo.processInfo.systemUptime
            if let lastPresentedAt {
                let interval = max(0, (now - lastPresentedAt) * 1000)
                lastIntervalMilliseconds = interval
                intervalMillis.append(interval)
                if intervalMillis.count > Self.frameWindowCapacity {
                    intervalMillis.removeFirst(intervalMillis.count - Self.frameWindowCapacity)
                }
            } else {
                lastIntervalMilliseconds = nil
            }
            self.lastPresentedAt = now
        } else {
            skippedSamples += 1
            // A gap that includes a skipped attempt is not one frame interval.
            lastPresentedAt = nil
            lastIntervalMilliseconds = nil
        }

        recordNanoseconds &+= DispatchTime.now().uptimeNanoseconds - started
        recordCalls &+= 1
    }

    /// Resets the sampling window. Called when the panel opens, so two opens do not mix.
    public func beginSamplingWindow() {
        presentedMillis.removeAll(keepingCapacity: true)
        intervalMillis.removeAll(keepingCapacity: true)
        lastPresentedAt = nil
        lastPresentedMilliseconds = nil
        lastIntervalMilliseconds = nil
        lastPresentedTileQuads = nil
        lastPresentedQuadCount = nil
        lastPresentedSurfaceFrameIndex = nil
        lastSamplePresented = nil
        presentedSamples = 0
        skippedSamples = 0
        recordNanoseconds = 0
        recordCalls = 0
    }

    /// Frame statistics over the present sampling window. `nil` fields mean "no sample yet",
    /// which the panel shows as absent rather than as zero.
    public var frameMetrics: FrameMetrics {
        let sorted = presentedMillis.sorted()
        let sortedIntervals = intervalMillis.sorted()
        return FrameMetrics(
            lastMillis: lastPresentedMilliseconds,
            p50Millis: FrameMetrics.percentile(0.50, of: sorted),
            p95Millis: FrameMetrics.percentile(0.95, of: sorted),
            sampleCount: presentedMillis.isEmpty ? nil : presentedMillis.count,
            presentedSamples: presentedSamples + skippedSamples == 0 ? nil : presentedSamples,
            skippedSamples: presentedSamples + skippedSamples == 0 ? nil : skippedSamples,
            lastSamplePresented: lastSamplePresented,
            lastTileQuadCount: lastPresentedTileQuads,
            lastQuadCount: lastPresentedQuadCount,
            surfaceFrameIndex: lastPresentedSurfaceFrameIndex,
            lastIntervalMillis: lastIntervalMilliseconds,
            intervalP50Millis: FrameMetrics.percentile(0.50, of: sortedIntervals),
            intervalP95Millis: FrameMetrics.percentile(0.95, of: sortedIntervals),
            intervalSampleCount: intervalMillis.isEmpty ? nil : intervalMillis.count,
            meanRecordMicroseconds: recordCalls == 0
                ? nil
                : Double(recordNanoseconds) / Double(recordCalls) / 1000
        )
    }
}

/// Frame statistics, with the exact definition of every number the panel shows.
public struct FrameMetrics: Sendable, Equatable {
    public var lastMillis: Double?
    public var p50Millis: Double?
    public var p95Millis: Double?
    public var sampleCount: Int?
    public var presentedSamples: Int?
    public var skippedSamples: Int?
    public var lastSamplePresented: Bool?
    public var lastTileQuadCount: Int?
    public var lastQuadCount: Int?
    public var surfaceFrameIndex: UInt64?
    /// Wall-clock gap between consecutive presented frames, and its nearest-rank percentiles.
    public var lastIntervalMillis: Double?
    public var intervalP50Millis: Double?
    public var intervalP95Millis: Double?
    public var intervalSampleCount: Int?
    public var meanRecordMicroseconds: Double?

    /// Nearest-rank percentile. This is deliberately *not* a moving average: the value is the
    /// element at rank `ceil(p × n)` in the sorted window, so p95 is a real observed frame time.
    public static func percentile(_ p: Double, of sortedValues: [Double]) -> Double? {
        guard !sortedValues.isEmpty else { return nil }
        let clamped = min(max(p, 0), 1)
        let rank = max(1, Int(ceil(clamped * Double(sortedValues.count))))
        return sortedValues[min(rank, sortedValues.count) - 1]
    }
}

/// Everything the panel displays, read in one place at one moment.
///
/// Optional fields are absent measurements. The view renders them as an em dash; it never
/// substitutes zero, because "not measured" and "measured as zero" are different claims.
public struct PerformanceSnapshot: Sendable, Equatable {
    // Frames — engine reported CPU time, presented frames only for the percentiles.
    public var frameLastMs: Double?
    public var frameP50Ms: Double?
    public var frameP95Ms: Double?
    public var frameSampleCount: Int?
    public var framesPresented: Int?
    public var framesSkipped: Int?
    public var lastFramePresented: Bool?
    public var lastFrameTileQuads: Int?
    public var lastFrameQuads: Int?
    /// Wall-clock intervals between consecutive presented frames (what pacing regressions show).
    public var frameIntervalLastMs: Double?
    public var frameIntervalP50Ms: Double?
    public var frameIntervalP95Ms: Double?
    public var frameIntervalSampleCount: Int?
    /// Engine's own counter for this surface, since it was attached. Unlike the sampled counts
    /// above, this one does not reset when the panel opens.
    public var surfaceFrameIndex: UInt64?
    // Page / tile path.
    /// Nil until a viewport update has chosen a path (`screenPagePathSummary == "pending"`).
    public var usingScreenPageRasters: Bool?
    public var pagePathSummary: String
    public var pagePathNote: String?
    public var rasterLOD: UInt8
    public var tileRequests: Int?
    public var tileInsertions: Int?
    public var tileHits: Int?
    public var tileMisses: Int?
    public var tileEvictions: Int?
    // Raster self-reports.
    public var pageRasterCount: Int?
    public var pageRasterMilliseconds: Double?
    public var tileRasterCount: Int?
    public var tileRasterMilliseconds: Double?
    // Memory, exact bytes.
    public var cacheUsedBytes: Int?
    public var cacheBudgetBytes: Int?
    public var cachePeakBytes: Int?
    public var pageRasterBytes: Int?
    public var pageRastersResident: Int?
    public var thumbnailBytes: Int?
    public var thumbnailCount: Int?
    // Document / window.
    public var openToFirstFrameMilliseconds: Double?
    public var zoomPercent: Int?
    public var calibrationFactor: CGFloat?
    public var effectiveZoom: CGFloat?
    public var samplingCostMilliseconds: Double?
    public var frameTapMicroseconds: Double?
}

/// Samples the reader at 4 Hz while, and only while, the panel is open.
///
/// The interval is deliberately tens of frames rather than one: the panel is a diagnostic, not a
/// display link. Nothing is scheduled when the panel closes — `samplingTask` is nil and the
/// canvas probe's `isSampling` is false, which the checks assert. The work per sample is a
/// bounded set of counter reads plus one sort of at most 120 doubles; the controller measures
/// its own wall time and publishes it so the cost is visible, not asserted.
@MainActor
public final class PerformancePanelController: ObservableObject {
    /// 250 ms = 4 Hz. Stated in the panel footer and pinned by the checks.
    public static let samplingIntervalMilliseconds = 250

    @Published public private(set) var snapshot: PerformanceSnapshot?
    /// The measured wall time of the most recent sample, in milliseconds.
    @Published public private(set) var lastSamplingCostMilliseconds: Double?
    public private(set) var isSampling = false
    /// Whether the 4 Hz sampling task exists. The closed-panel checks assert this is false; it is
    /// also the honest statement of "no timer is running" (there is no Timer, only this task).
    public var isSamplingTaskRunning: Bool { samplingTask != nil }

    private var samplingTask: Task<Void, Never>?
    private weak var state: AppState?

    public init() {}

    deinit { samplingTask?.cancel() }

    /// Starts or stops sampling. Idempotent: opening a panel twice does not create two tasks.
    public func setRunning(_ running: Bool, state: AppState) {
        self.state = state
        if running {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard !isSampling else { return }
        isSampling = true
        state?.performanceProbe.isSampling = true
        state?.performanceProbe.beginSamplingWindow()
        // Sample once immediately so opening the panel shows numbers in the same run loop turn,
        // then settle into the 4 Hz cadence. `Task.sleep` is used instead of a Timer so closing
        // the panel cancels the only scheduled work.
        sample()
        samplingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(Self.samplingIntervalMilliseconds))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.sample()
            }
        }
    }

    /// Stops sampling and drops the last snapshot. Closed means closed: no task, no probe work.
    public func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        isSampling = false
        state?.performanceProbe.isSampling = false
        snapshot = nil
        lastSamplingCostMilliseconds = nil
    }

    /// One bounded read of the reader's counters. Main-actor only because the state is.
    private func sample() {
        guard let state else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        var snapshot = state.makePerformanceSnapshot()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        snapshot.samplingCostMilliseconds = elapsed
        lastSamplingCostMilliseconds = elapsed
        self.snapshot = snapshot
    }
}

/// The panel itself. It follows the assistant panel's header/typography rules: a
/// 13 pt semibold title, tertiary section labels and monospaced, trailing-aligned values.
///
/// Layout rules that make it readable at the right panel's 240 pt minimum:
/// * every value is one line in a trailing-aligned frame with monospaced digits, so a value
///   changing from `9.9` to `10.1` cannot reflow the row;
/// * section labels have a fixed 92 pt column and long path strings truncate in the middle;
/// * the whole content is a vertical scroll, so row count never forces a minimum width.
///
/// It observes only the controller, not `AppState`: numbers move at the stated 4 Hz sampling
/// rate rather than at the reader's publishing rate, and scrolling cannot re-render this view
/// once per state change.
public struct PerformancePanelView: View {
    @ObservedObject private var controller: PerformancePanelController
    private let onClose: () -> Void

    public init(controller: PerformancePanelController, onClose: @escaping () -> Void) {
        self.controller = controller
        self.onClose = onClose
    }

    private var snapshot: PerformanceSnapshot? { controller.snapshot }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(LyraReaderTheme.separator)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    framesSection
                    pathSection
                    rasterSection
                    memorySection
                    documentSection
                    legend
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            Divider().overlay(LyraReaderTheme.separator)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LyraReaderTheme.panelBg)
        .background(PerformancePanelMarkerHost())
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LyraReaderTheme.accent)
            Text("Performance")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LyraReaderTheme.textPrimary)
            Spacer(minLength: 0)
            if controller.isSampling {
                Circle()
                    .fill(LyraReaderTheme.successFg)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
            }
            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(LyraReaderToolStyle())
            .help("Close performance panel")
            .accessibilityLabel("Close performance panel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Sections

    private var framesSection: some View {
        section("FRAMES") {
            row("Frame interval", milliseconds(snapshot?.frameIntervalLastMs))
            row("Interval p50/p95", "\(milliseconds(snapshot?.frameIntervalP50Ms)) / \(milliseconds(snapshot?.frameIntervalP95Ms))")
            row("Engine CPU", milliseconds(snapshot?.frameLastMs))
            row("CPU p50/p95", "\(milliseconds(snapshot?.frameP50Ms)) / \(milliseconds(snapshot?.frameP95Ms))")
            row("Window", snapshot?.frameSampleCount.map { "\($0) presented" } ?? absent)
            row("Presented", snapshot?.framesPresented.map(String.init) ?? absent)
            row("Surface frames", snapshot?.surfaceFrameIndex.map(String.init) ?? absent)
            row("Skipped", snapshot?.framesSkipped.map(String.init) ?? absent)
            row("State", frameState, tint: frameStateTint)
            row("Tiles/frame", snapshot?.lastFrameTileQuads.map(String.init) ?? absent)
            row("All quads", snapshot?.lastFrameQuads.map(String.init) ?? absent)
            Text("CPU = engine self-report; interval = wall-clock between presented frames (idle time between on-demand frames counts). p50/p95 are nearest-rank percentiles.")
                .font(.system(size: 10))
                .foregroundStyle(LyraReaderTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pathSection: some View {
        section("PAGE / TILE PATH") {
            row("Path", pagePathLabel)
            row("Screen path", snapshot?.pagePathSummary ?? absent)
            row("LOD", snapshot.map { "\($0.rasterLOD)" } ?? absent)
            row("Tiles asked", snapshot?.tileRequests.map(String.init) ?? absent)
            row("Tiles ready", snapshot?.tileInsertions.map(String.init) ?? absent)
            row("Tile hits", snapshot?.tileHits.map(String.init) ?? absent)
            row("Tile misses", snapshot?.tileMisses.map(String.init) ?? absent)
            row("Evictions", snapshot?.tileEvictions.map(String.init) ?? absent)
            if let note = snapshot?.pagePathNote {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(LyraReaderTheme.textTertiary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var rasterSection: some View {
        section("RASTER TIME") {
            row("Page rasters", rasterSummary(
                count: snapshot?.pageRasterCount, milliseconds: snapshot?.pageRasterMilliseconds))
            row("Tile rasters", rasterSummary(
                count: snapshot?.tileRasterCount, milliseconds: snapshot?.tileRasterMilliseconds))
            Text("Engine self-reports: count · total wall time, not GPU time.")
                .font(.system(size: 10))
                .foregroundStyle(LyraReaderTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var memorySection: some View {
        section("MEMORY") {
            row("Tiles", "\(bytes(snapshot?.cacheUsedBytes)) / \(bytes(snapshot?.cacheBudgetBytes))")
            row("Tile peak", bytes(snapshot?.cachePeakBytes))
            row("Page rasters", "\(bytes(snapshot?.pageRasterBytes)) · \(count(snapshot?.pageRastersResident))")
            row("Thumbnails", "\(bytes(snapshot?.thumbnailBytes)) · \(count(snapshot?.thumbnailCount))")
        }
    }

    private var documentSection: some View {
        section("DOCUMENT") {
            row("Open → frame", milliseconds(snapshot?.openToFirstFrameMilliseconds))
            row("Zoom", snapshot?.zoomPercent.map { "\($0)%" } ?? absent)
            row("Calibration", factor(snapshot?.calibrationFactor))
            row("Effective zoom", factor(snapshot?.effectiveZoom, percent: true))
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(LyraReaderTheme.separator)
            Text("— means not measured yet, not zero. Counts cover this document since it opened; frame counters cover this panel's sampling window (last up to 120 presented frames). Open → frame runs from the open request to the first presented frame.")
                .font(.system(size: 10))
                .foregroundStyle(LyraReaderTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Hit = a tile found in the tile cache, not a reused draw. Tiles asked counts queued raster requests (a cache hit is never asked); tiles ready = rasterized and inserted.")
                .font(.system(size: 10))
                .foregroundStyle(LyraReaderTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text("p50/p95 are nearest-rank percentiles, not moving averages. Nothing here is estimated; every value is a counter read or a single measurement.")
                .font(.system(size: 10))
                .foregroundStyle(LyraReaderTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Samples every \(PerformancePanelController.samplingIntervalMilliseconds) ms (4 Hz)")
                .font(.system(size: 10))
                .foregroundStyle(LyraReaderTheme.textSecondary)
            HStack(spacing: 6) {
                Text("sample \(milliseconds(snapshot?.samplingCostMilliseconds))")
                Text("·")
                Text("tap \(microseconds(snapshot?.frameTapMicroseconds))")
            }
            .font(.system(size: 10))
            .monospacedDigit()
            .foregroundStyle(LyraReaderTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: - Rows and formatting

    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(LyraReaderTheme.textTertiary)
            content()
        }
    }

    /// One label/value row with a fixed label column and a trailing, monospaced value.
    private func row(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(LyraReaderTheme.textSecondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(tint ?? LyraReaderTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private var frameState: String {
        guard let presented = snapshot?.lastFramePresented else { return absent }
        return presented ? "presenting" : "skipped · occluded"
    }

    private var pagePathLabel: String {
        guard let screenRasters = snapshot?.usingScreenPageRasters else { return absent }
        return screenRasters ? "Page rasters" : "Pyramid tiles"
    }

    private var frameStateTint: Color? {
        guard let presented = snapshot?.lastFramePresented else { return nil }
        return presented ? LyraReaderTheme.successFg : LyraReaderTheme.warningFg
    }

    private static let absent = "—"
    private var absent: String { Self.absent }

    private func milliseconds(_ value: Double?) -> String {
        guard let value else { return absent }
        return String(format: value < 10 ? "%.2f ms" : "%.1f ms", value)
    }

    private func microseconds(_ value: Double?) -> String {
        guard let value else { return absent }
        return String(format: "%.3f ms/frame", value / 1000)
    }

    private func bytes(_ value: Int?) -> String {
        guard let value else { return absent }
        return String(format: "%.1f MiB", Double(value) / (1024.0 * 1024.0))
    }

    private func count(_ value: Int?) -> String {
        guard let value else { return absent }
        return "\(value)"
    }

    private func factor(_ value: CGFloat?, percent: Bool = false) -> String {
        guard let value else { return absent }
        return String(format: percent ? "%.2f×" : "%.3f×", Double(value))
    }

    private func rasterSummary(count: Int?, milliseconds: Double?) -> String {
        guard let count else { return absent }
        guard let milliseconds else { return "\(count) · \(absent)" }
        // Count plus the total wall time. A mean is derivable and would just truncate at the
        // panel's 240 pt minimum, which is the width this row has to stay readable at.
        return String(format: "%d · %.1f ms", count, milliseconds)
    }
}

/// The rendering above is intentionally data-driven: `makePerformanceSnapshot()` is the one
/// place that reads the reader, so the checks can exercise the same numbers the panel shows.
extension AppState {
    /// Reads the live counters into the panel's snapshot. Bounded work: no raster, no reload,
    /// no allocation beyond the snapshot value; it is cheap enough to run on the main actor at
    /// 4 Hz and the controller measures it.
    public func makePerformanceSnapshot() -> PerformanceSnapshot {
        let metrics = performanceProbe.frameMetrics
        let tileStats = tileCacheSnapshot
        return PerformanceSnapshot(
            frameLastMs: metrics.lastMillis,
            frameP50Ms: metrics.p50Millis,
            frameP95Ms: metrics.p95Millis,
            frameSampleCount: metrics.sampleCount,
            framesPresented: metrics.presentedSamples,
            framesSkipped: metrics.skippedSamples,
            lastFramePresented: metrics.lastSamplePresented,
            lastFrameTileQuads: metrics.lastTileQuadCount,
            lastFrameQuads: metrics.lastQuadCount,
            frameIntervalLastMs: metrics.lastIntervalMillis,
            frameIntervalP50Ms: metrics.intervalP50Millis,
            frameIntervalP95Ms: metrics.intervalP95Millis,
            frameIntervalSampleCount: metrics.intervalSampleCount,
            surfaceFrameIndex: metrics.surfaceFrameIndex,
            usingScreenPageRasters: screenPagePathSummary == "pending" ? nil : usesScreenPageRasters,
            pagePathSummary: screenPagePathSummary,
            pagePathNote: screenPagePathNote,
            rasterLOD: currentRasterLOD,
            tileRequests: tileRequestCount,
            tileInsertions: tileStats.insertions,
            tileHits: tileStats.hits,
            tileMisses: tileStats.misses,
            tileEvictions: tileStats.evictions,
            pageRasterCount: pageRasterCount,
            pageRasterMilliseconds: pageRasterCount == 0 ? nil : pageRasterMilliseconds,
            tileRasterCount: tileRasterCount,
            tileRasterMilliseconds: tileRasterCount == 0 ? nil : tileRasterMilliseconds,
            cacheUsedBytes: tileCacheUsedBytes,
            cacheBudgetBytes: tileCacheBudgetBytes,
            cachePeakBytes: tileCachePeakBytes,
            pageRasterBytes: pageRasterCacheUsedBytes,
            pageRastersResident: pageRasterCacheCount,
            thumbnailBytes: thumbnailCacheBytes,
            thumbnailCount: thumbnailCacheCount,
            openToFirstFrameMilliseconds: performanceProbe.openToFirstFrameMilliseconds,
            zoomPercent: zoomPercent,
            calibrationFactor: displayCalibration.factor,
            effectiveZoom: zoomFactor,
            samplingCostMilliseconds: nil,
            frameTapMicroseconds: metrics.meanRecordMicroseconds
        )
    }
}

/// A zero-size marker so the hosted checks can find the shipped panel without inspecting
/// SwiftUI's lazy view tree (the same seam `AIAssistantPanelMarkerView` provides).
public final class PerformancePanelMarkerView: NSView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityLabel("Performance panel")
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityLabel("Performance panel")
    }
}

private struct PerformancePanelMarkerHost: NSViewRepresentable {
    func makeNSView(context: Context) -> PerformancePanelMarkerView {
        PerformancePanelMarkerView(frame: .zero)
    }

    func updateNSView(_ nsView: PerformancePanelMarkerView, context: Context) {}
}
