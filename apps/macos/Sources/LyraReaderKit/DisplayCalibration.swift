import AppKit
import CoreGraphics

/// The zoom calibration of one display: the factor that turns a reader percentage into a
/// physical size.
///
/// **Why it exists.** The reader draws a PDF point at `zoomFactor × backingScale` device pixels.
/// With `zoomFactor = zoomPercent / 100`, 100% means "one PDF point per macOS logical point",
/// and a logical point is not a fixed physical length: macOS scales the logical resolution of a
/// Retina panel, so on a 5120×2880 display that "looks like 2560×1440" one logical point is
/// 1/108.5 inch rather than 1/72. A Letter page at 100% then measures about two thirds of its
/// physical width.
///
/// The convention the reader adopts, and the one Preview's and PDF Expert's *Actual Size* use,
/// is that **100% means actual physical size**:
///
/// ```
/// logicalPPI   = logical width in points / physical width in inches
/// calibration  = logicalPPI / 72
/// zoomFactor   = zoomPercent / 100 × calibration
/// ```
///
/// The physical width comes from the display itself (`CGDisplayScreenSize`, in millimetres), not
/// from a nominal 96/72 dpi or a hard-coded panel. Moving the window to a display with a different
/// logical density therefore changes `calibration` while the reader's percentage stays put: 100%
/// is actual size on whichever screen the window is on.
///
/// **Fallback.** A virtual or headless display may report no physical size at all (or an absurd
/// one). Dividing by that would produce a zero, infinite or wildly wrong zoom, so such a display
/// falls back to `factor = 1` — the uncalibrated 72 dpi convention — and the reason is kept for the
/// diagnostic log. The fallback is never silent in the log, and it is the only path that keeps
/// the old "logical point" meaning.
public struct DisplayCalibration: Equatable, Sendable {
    /// The dpi at which one PDF point is one physical 1/72 inch.
    public static let referenceDPI: CGFloat = 72

    /// The physical widths this code is willing to trust, in millimetres.
    ///
    /// 25 mm is about a 1.5-inch display; 3000 mm is a 118-inch wall panel. A virtual display
    /// commonly reports 0, and a corrupt EDID can report an enormous value; both are rejected
    /// rather than turned into a zoom no reader asked for.
    public static let plausiblePhysicalWidthMm: ClosedRange<CGFloat> = 25...3000

    /// The calibration factor is also bounded: 0.25 would be 18 logical dpi and 4 would be
    /// 288 logical dpi. A display outside that range is treated as a bad description.
    public static let plausibleFactor: ClosedRange<CGFloat> = 0.25...4

    /// The factor that multiplies the reader's percentage (`zoomFactor = percent/100 × factor`).
    public let factor: CGFloat
    /// The screen width in logical points, when one was available.
    public let logicalWidthPt: CGFloat?
    /// The physical screen width in millimetres, when one was available.
    public let physicalWidthMm: CGFloat?
    /// Why the fallback applies, or nil when the calibration came from a real display.
    public let fallbackReason: String?

    public init(
        factor: CGFloat,
        logicalWidthPt: CGFloat? = nil,
        physicalWidthMm: CGFloat? = nil,
        fallbackReason: String? = nil
    ) {
        self.factor = factor
        self.logicalWidthPt = logicalWidthPt
        self.physicalWidthMm = physicalWidthMm
        self.fallbackReason = fallbackReason
    }

    /// The uncalibrated 72 dpi convention, used until a screen is known and for displays whose
    /// physical size cannot be trusted.
    public static func uncalibrated(reason: String? = nil) -> DisplayCalibration {
        DisplayCalibration(factor: 1, fallbackReason: reason ?? "no calibrated display")
    }

    /// The 1.0 factor used before a window has reported its screen.
    public static let uncalibratedDefault = DisplayCalibration(factor: 1, fallbackReason: nil)

    /// Logical dpi of the described display, or nil for a fallback calibration.
    public var logicalPPI: CGFloat? {
        guard let logicalWidthPt, let physicalWidthMm, physicalWidthMm > 0 else { return nil }
        return logicalWidthPt / (physicalWidthMm / 25.4)
    }

    /// The formula, with every input validated.
    ///
    /// `logicalWidthPt` is `NSScreen.frame.width`; `physicalWidthMm` is
    /// `CGDisplayScreenSize(displayID).width`, the panel's own width from its description.
    public static func resolve(
        logicalWidthPt: CGFloat,
        physicalWidthMm: CGFloat
    ) -> DisplayCalibration {
        guard logicalWidthPt.isFinite, logicalWidthPt > 0 else {
            return DisplayCalibration(
                factor: 1, logicalWidthPt: logicalWidthPt, physicalWidthMm: physicalWidthMm,
                fallbackReason: "the display reports no usable logical width")
        }
        guard physicalWidthMm.isFinite, physicalWidthMm > 0 else {
            return DisplayCalibration(
                factor: 1, logicalWidthPt: logicalWidthPt, physicalWidthMm: physicalWidthMm,
                fallbackReason: "the display reports no usable physical width")
        }
        guard plausiblePhysicalWidthMm.contains(physicalWidthMm) else {
            return DisplayCalibration(
                factor: 1, logicalWidthPt: logicalWidthPt, physicalWidthMm: physicalWidthMm,
                fallbackReason: String(
                    format: "the display's physical width %.1f mm is outside the plausible %.0f...%.0f mm",
                    Double(physicalWidthMm), Double(plausiblePhysicalWidthMm.lowerBound),
                    Double(plausiblePhysicalWidthMm.upperBound)))
        }
        let pointsPerInch = logicalWidthPt / (physicalWidthMm / 25.4)
        guard pointsPerInch.isFinite, pointsPerInch > 0 else {
            return DisplayCalibration(
                factor: 1, logicalWidthPt: logicalWidthPt, physicalWidthMm: physicalWidthMm,
                fallbackReason: "the display's logical density is not a finite positive number")
        }
        let factor = pointsPerInch / referenceDPI
        guard factor.isFinite, plausibleFactor.contains(factor) else {
            return DisplayCalibration(
                factor: 1, logicalWidthPt: logicalWidthPt, physicalWidthMm: physicalWidthMm,
                fallbackReason: String(
                    format: "the derived calibration %.2f is outside the plausible %.2f...%.2f",
                    Double(factor), Double(plausibleFactor.lowerBound),
                    Double(plausibleFactor.upperBound)))
        }
        return DisplayCalibration(
            factor: factor, logicalWidthPt: logicalWidthPt, physicalWidthMm: physicalWidthMm)
    }

    /// The panel's physical width in millimetres, from the display description.
    ///
    /// AppKit exposes the display size through `NSScreenNumber`; `CGDisplayScreenSize` is the
    /// only public source of the *physical* size (`CGDisplayPixelsWide` is pixels, and
    /// `NSScreen.frame` is logical points). Returns nil rather than zero when the display has no
    /// description.
    public static func physicalWidthMm(of screen: NSScreen) -> CGFloat? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        let display = CGDirectDisplayID(number.uint32Value)
        let size = CGDisplayScreenSize(display)
        guard size.width.isFinite, size.width > 0 else { return nil }
        return size.width
    }

    /// Reads the calibration for a screen. `nil` (no window yet, or a headless check host) is the
    /// uncalibrated fallback, so a test never depends on the display attached to the machine.
    public static func forScreen(_ screen: NSScreen?) -> DisplayCalibration {
        guard let screen else { return .uncalibrated(reason: "no screen is attached to the window") }
        let widthPt = screen.frame.width
        guard let widthMm = physicalWidthMm(of: screen) else {
            return DisplayCalibration(
                factor: 1, logicalWidthPt: widthPt, physicalWidthMm: nil,
                fallbackReason: "the display description has no physical size")
        }
        return resolve(logicalWidthPt: widthPt, physicalWidthMm: widthMm)
    }

    /// One line for the diagnostic log: the formula's inputs, or why it was not used.
    public var diagnosticLine: String {
        let width = logicalWidthPt.map { String(format: "%.1f pt", Double($0)) } ?? "? pt"
        let physical = physicalWidthMm.map { String(format: "%.1f mm", Double($0)) } ?? "? mm"
        let ppi = logicalPPI.map { String(format: ", %.2f logical ppi", Double($0)) } ?? ""
        if let fallbackReason {
            return String(
                format: "lyra-reader-calibration: uncalibrated (72 dpi), factor 1.00 · screen %@ / %@%@ · %@\n",
                width, physical, ppi, fallbackReason)
        }
        return String(
            format: "lyra-reader-calibration: factor %.4f = (%@ / %@) / 72%@\n",
            Double(factor), width, physical, ppi)
    }
}
