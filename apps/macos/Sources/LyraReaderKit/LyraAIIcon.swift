import AppKit
import SwiftUI

/// The supplied quill and four-point star, kept as independent monochrome vector paths.
/// Coordinates come from Support/LyraAIIcon.svg (32 × 32); no bitmap or SF Symbol fallback.
struct LyraAIIcon: View {
    var isActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// NSToolbar-backed tab items extract an Image; arbitrary Shape content is omitted.
    /// A drawing representation keeps the same vectors sharp at either backing scale.
    @MainActor static let templateImage: NSImage = {
        let image = NSImage(size: CGSize(width: 28, height: 28), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: rect.width / 32, y: rect.height / 32)
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(LyraAIPath.quill.cgPath)
            context.addPath(LyraAIPath.sparkle.cgPath)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }()

    var body: some View {
        ZStack {
            LyraAIPath(part: .quill)
            if isActive && !reduceMotion {
                // Only this layer ticks. The feather never scales, fades or moves.
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let breath = (1 - cos(context.date.timeIntervalSinceReferenceDate * .pi / 1.4)) / 2
                    LyraAIPath(part: .sparkle)
                        .opacity(0.65 + 0.35 * breath)
                        .scaleEffect(0.97 + 0.06 * breath,
                                     anchor: UnitPoint(x: 8.0 / 32, y: 6.25 / 32))
                }
            } else {
                LyraAIPath(part: .sparkle)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// Observes the independent summary worker as well as chat/translation request state.
struct LyraAIActivityIcon: View {
    @ObservedObject var model: AIAssistantModel
    @ObservedObject private var summary: LayeredSummaryModel

    init(model: AIAssistantModel) {
        self.model = model
        _summary = ObservedObject(wrappedValue: model.layeredSummary)
    }

    var body: some View {
        LyraAIIcon(isActive: model.isPreparing || model.isSending
                   || summary.isPreparing || summary.isRefreshing || summary.isGenerating)
    }
}

private struct LyraAIPath: Shape {
    enum Part { case quill, sparkle }
    var part: Part

    func path(in rect: CGRect) -> Path {
        let source = part == .quill ? Self.quill : Self.sparkle
        return source.applying(CGAffineTransform(scaleX: rect.width / 32, y: rect.height / 32)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }

    fileprivate static let quill: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 25.921875, y: 3.0729167))
        p.addCurve(to: CGPoint(x: 25.526042, y: 3.1770833), control1: CGPoint(x: 25.790435, y: 3.0705827), control2: CGPoint(x: 25.654185, y: 3.1071582))
        p.addLine(to: CGPoint(x: 25.541667, y: 3.1666667))
        p.addCurve(to: CGPoint(x: 18.635417, y: 5.0364583), control1: CGPoint(x: 23.683805, y: 3.9883946), control2: CGPoint(x: 20.811718, y: 4.2865713))
        p.addCurve(to: CGPoint(x: 18.635417, y: 5.0390625), control1: CGPoint(x: 18.6354119, y: 5.03732636), control2: CGPoint(x: 18.6354119, y: 5.03819444))
        p.addCurve(to: CGPoint(x: 12.692708, y: 8.8489583), control1: CGPoint(x: 16.50469, y: 5.7872056), control2: CGPoint(x: 14.447417, y: 7.056744))
        p.addCurve(to: CGPoint(x: 9.4036458, y: 14.424479), control1: CGPoint(x: 11.067181, y: 10.47506), control2: CGPoint(x: 9.8451863, y: 12.40609))
        p.addCurve(to: CGPoint(x: 9.2786458, y: 14.380208), control1: CGPoint(x: 9.36752354, y: 14.397218), control2: CGPoint(x: 9.32387382, y: 14.3817587))
        p.addCurve(to: CGPoint(x: 8.9895833, y: 14.502604), control1: CGPoint(x: 9.1326371, y: 14.380208), control2: CGPoint(x: 9.0730329, y: 14.44153))
        p.addCurve(to: CGPoint(x: 8.7239583, y: 14.734375), control1: CGPoint(x: 8.9080524, y: 14.562274), control2: CGPoint(x: 8.8185568, y: 14.640185))
        p.addLine(to: CGPoint(x: 8.7239583, y: 14.736979))
        p.addCurve(to: CGPoint(x: 8.71875, y: 14.739583), control1: CGPoint(x: 8.7224683, y: 14.738479), control2: CGPoint(x: 8.72024, y: 14.738083))
        p.addCurve(to: CGPoint(x: 6.59375, y: 18.994792), control1: CGPoint(x: 7.6071038, y: 15.778269), control2: CGPoint(x: 6.7845144, y: 17.429279))
        p.addCurve(to: CGPoint(x: 7.2682292, y: 23.075521), control1: CGPoint(x: 6.4031704, y: 20.293813), control2: CGPoint(x: 6.6725666, y: 21.587177))
        p.addCurve(to: CGPoint(x: 7.3229167, y: 23.583333), control1: CGPoint(x: 7.3713045, y: 23.35195), control2: CGPoint(x: 7.3825006, y: 23.484564))
        p.addCurve(to: CGPoint(x: 7.3125, y: 23.604167), control1: CGPoint(x: 7.31907904, y: 23.5900889), control2: CGPoint(x: 7.31560194, y: 23.5970433))
        p.addCurve(to: CGPoint(x: 5.5052083, y: 28.028646), control1: CGPoint(x: 6.6503287, y: 25.001417), control2: CGPoint(x: 6.0585035, y: 26.371316))
        p.addCurve(to: CGPoint(x: 5.40625, y: 28.552083), control1: CGPoint(x: 5.4222784, y: 28.214677), control2: CGPoint(x: 5.3750632, y: 28.380241))
        p.addCurve(to: CGPoint(x: 5.7109375, y: 28.929688), control1: CGPoint(x: 5.436654, y: 28.719618), control2: CGPoint(x: 5.5657643, y: 28.853716))
        p.addCurve(to: CGPoint(x: 6.2994792, y: 29.013021), control1: CGPoint(x: 5.8974666, y: 29.042899), control2: CGPoint(x: 6.1122636, y: 29.087828))
        p.addCurve(to: CGPoint(x: 6.6875, y: 28.557292), control1: CGPoint(x: 6.4884963, y: 28.937461), control2: CGPoint(x: 6.6182601, y: 28.763206))
        p.addLine(to: CGPoint(x: 6.6901042, y: 28.552083))
        p.addCurve(to: CGPoint(x: 7.6354167, y: 26.260417), control1: CGPoint(x: 6.9456286, y: 27.823507), control2: CGPoint(x: 7.2346112, y: 27.098644))
        p.addCurve(to: CGPoint(x: 9.9322917, y: 23.929688), control1: CGPoint(x: 8.1685243, y: 25.158468), control2: CGPoint(x: 8.8967847, y: 24.464894))
        p.addCurve(to: CGPoint(x: 9.9348958, y: 23.927083), control1: CGPoint(x: 9.93316699, y: 23.9288269), control2: CGPoint(x: 9.93403505, y: 23.9279586))
        p.addCurve(to: CGPoint(x: 14.460938, y: 22.619792), control1: CGPoint(x: 11.318977, y: 23.181626), control2: CGPoint(x: 12.844905, y: 23.108478))
        p.addCurve(to: CGPoint(x: 14.466146, y: 22.617188), control1: CGPoint(x: 14.4626854, y: 22.618947), control2: CGPoint(x: 14.4644216, y: 22.6180789))
        p.addCurve(to: CGPoint(x: 18.895833, y: 19.28125), control1: CGPoint(x: 16.304466, y: 22.017315), control2: CGPoint(x: 17.835604, y: 21.023275))
        p.addCurve(to: CGPoint(x: 18.895833, y: 19.276042), control1: CGPoint(x: 18.8958535, y: 19.2795141), control2: CGPoint(x: 18.8958535, y: 19.2777779))
        p.addCurve(to: CGPoint(x: 18.984375, y: 18.575521), control1: CGPoint(x: 19.043074, y: 19.023792), control2: CGPoint(x: 19.105038, y: 18.779138))
        p.addCurve(to: CGPoint(x: 18.442708, y: 18.333333), control1: CGPoint(x: 18.869935, y: 18.382404), control2: CGPoint(x: 18.652626, y: 18.338623))
        p.addCurve(to: CGPoint(x: 23.333333, y: 13.236979), control1: CGPoint(x: 20.906981, y: 17.314193), control2: CGPoint(x: 22.559323, y: 15.586655))
        p.addCurve(to: CGPoint(x: 23.257812, y: 12.59375), control1: CGPoint(x: 23.421813, y: 12.993219), control2: CGPoint(x: 23.424812, y: 12.750258))
        p.addCurve(to: CGPoint(x: 22.661458, y: 12.5625), control1: CGPoint(x: 23.090815, y: 12.437242), control2: CGPoint(x: 22.854417, y: 12.466021))
        p.addCurve(to: CGPoint(x: 22.21875, y: 12.664062), control1: CGPoint(x: 22.536227, y: 12.62512), control2: CGPoint(x: 22.362063, y: 12.61016))
        p.addCurve(to: CGPoint(x: 25.127604, y: 9.5052083), control1: CGPoint(x: 23.407761, y: 11.906791), control2: CGPoint(x: 24.424518, y: 10.911382))
        p.addCurve(to: CGPoint(x: 25.130208, y: 9.5026042), control1: CGPoint(x: 25.1284792, y: 9.50434755), control2: CGPoint(x: 25.1293473, y: 9.50347948))
        p.addCurve(to: CGPoint(x: 26.549479, y: 3.9375), control1: CGPoint(x: 25.956562, y: 7.8119169), control2: CGPoint(x: 26.509174, y: 5.495486))
        p.addCurve(to: CGPoint(x: 26.28125, y: 3.1953125), control1: CGPoint(x: 26.571524, y: 3.6300697), control2: CGPoint(x: 26.485158, y: 3.3555537))
        p.addCurve(to: CGPoint(x: 25.921875, y: 3.0729167), control1: CGPoint(x: 26.179296, y: 3.1151919), control2: CGPoint(x: 26.053315, y: 3.0752506))
        p.closeSubpath()
        p.move(to: CGPoint(x: 25.002604, y: 4.9713542))
        p.addCurve(to: CGPoint(x: 24.320312, y: 7.9296875), control1: CGPoint(x: 24.857181, y: 5.9651349), control2: CGPoint(x: 24.675572, y: 6.9960384))
        p.addCurve(to: CGPoint(x: 19.200521, y: 12.731771), control1: CGPoint(x: 23.417858, y: 10.205434), control2: CGPoint(x: 21.855153, y: 12.014777))
        p.addCurve(to: CGPoint(x: 18.994792, y: 12.817708), control1: CGPoint(x: 19.123441, y: 12.753881), control2: CGPoint(x: 19.055987, y: 12.780738))
        p.addCurve(to: CGPoint(x: 18.830729, y: 13.010417), control1: CGPoint(x: 18.933602, y: 12.854688), control2: CGPoint(x: 18.862464, y: 12.903277))
        p.addCurve(to: CGPoint(x: 18.919271, y: 13.302083), control1: CGPoint(x: 18.798999, y: 13.117557), control2: CGPoint(x: 18.857641, y: 13.245136))
        p.addCurve(to: CGPoint(x: 19.114583, y: 13.411458), control1: CGPoint(x: 18.980891, y: 13.359033), control2: CGPoint(x: 19.042067, y: 13.387173))
        p.addCurve(to: CGPoint(x: 19.117188, y: 13.411458), control1: CGPoint(x: 19.1154513, y: 13.4114631), control2: CGPoint(x: 19.1163197, y: 13.4114631))
        p.addCurve(to: CGPoint(x: 21.476562, y: 13.901042), control1: CGPoint(x: 19.80231, y: 13.640128), control2: CGPoint(x: 20.614589, y: 13.803212))
        p.addCurve(to: CGPoint(x: 15.020833, y: 18.216146), control1: CGPoint(x: 20.15843, y: 16.343216), control2: CGPoint(x: 17.893595, y: 17.65491))
        p.addCurve(to: CGPoint(x: 15.018229, y: 18.216146), control1: CGPoint(x: 15.019965, y: 18.2161409), control2: CGPoint(x: 15.019097, y: 18.2161409))
        p.addCurve(to: CGPoint(x: 14.739583, y: 18.317708), control1: CGPoint(x: 14.908927, y: 18.237826), control2: CGPoint(x: 14.819777, y: 18.268346))
        p.addCurve(to: CGPoint(x: 14.559896, y: 18.580729), control1: CGPoint(x: 14.659393, y: 18.367068), control2: CGPoint(x: 14.569305, y: 18.449763))
        p.addCurve(to: CGPoint(x: 14.710938, y: 18.869792), control1: CGPoint(x: 14.550496, y: 18.711695), control2: CGPoint(x: 14.634007, y: 18.815489))
        p.addCurve(to: CGPoint(x: 14.973958, y: 18.976562), control1: CGPoint(x: 14.787377, y: 18.923752), control2: CGPoint(x: 14.873105, y: 18.953872))
        p.addCurve(to: CGPoint(x: 17.106771, y: 19.276042), control1: CGPoint(x: 15.639177, y: 19.157422), control2: CGPoint(x: 16.372192, y: 19.221485))
        p.addCurve(to: CGPoint(x: 12.434896, y: 21.640625), control1: CGPoint(x: 15.57635, y: 20.972148), control2: CGPoint(x: 13.853291, y: 21.328765))
        p.addCurve(to: CGPoint(x: 9.4270833, y: 22.84375), control1: CGPoint(x: 11.293436, y: 21.897124), control2: CGPoint(x: 10.33547, y: 22.295284))
        p.addCurve(to: CGPoint(x: 12.877604, y: 17.572917), control1: CGPoint(x: 10.499445, y: 20.956102), control2: CGPoint(x: 11.599324, y: 19.202658))
        p.addCurve(to: CGPoint(x: 19.145833, y: 10.901042), control1: CGPoint(x: 14.823331, y: 15.113845), control2: CGPoint(x: 16.8378, y: 12.915597))
        p.addCurve(to: CGPoint(x: 19.145833, y: 10.898438), control1: CGPoint(x: 19.1458381, y: 10.900174), control2: CGPoint(x: 19.1458381, y: 10.899306))
        p.addCurve(to: CGPoint(x: 20.757812, y: 9.5052083), control1: CGPoint(x: 19.757989, y: 10.357668), control2: CGPoint(x: 20.444287, y: 9.9086603))
        p.addCurve(to: CGPoint(x: 20.760417, y: 9.5026042), control1: CGPoint(x: 20.7586876, y: 9.50434755), control2: CGPoint(x: 20.7595559, y: 9.50347949))
        p.addCurve(to: CGPoint(x: 20.880208, y: 9.1901042), control1: CGPoint(x: 20.831037, y: 9.4083403), control2: CGPoint(x: 20.885647, y: 9.3205866))
        p.addCurve(to: CGPoint(x: 20.802083, y: 8.9947917), control1: CGPoint(x: 20.877508, y: 9.1248632), control2: CGPoint(x: 20.849893, y: 9.0463535))
        p.addCurve(to: CGPoint(x: 20.643229, y: 8.9036458), control1: CGPoint(x: 20.754273, y: 8.9432297), control2: CGPoint(x: 20.694671, y: 8.9170938))
        p.addCurve(to: CGPoint(x: 20.075521, y: 9.0286458), control1: CGPoint(x: 20.438948, y: 8.8502409), control2: CGPoint(x: 20.268855, y: 8.9215109))
        p.addCurve(to: CGPoint(x: 13.385417, y: 14.934896), control1: CGPoint(x: 18.040929, y: 10.121126), control2: CGPoint(x: 15.606858, y: 12.343548))
        p.addCurve(to: CGPoint(x: 13.382812, y: 14.934896), control1: CGPoint(x: 13.3845487, y: 14.9348909), control2: CGPoint(x: 13.3836803, y: 14.9348909))
        p.addCurve(to: CGPoint(x: 8.1875, y: 22.075521), control1: CGPoint(x: 11.410726, y: 17.253744), control2: CGPoint(x: 9.6578303, y: 19.650266))
        p.addCurve(to: CGPoint(x: 8.7083333, y: 16.533854), control1: CGPoint(x: 7.7967771, y: 20.175908), control2: CGPoint(x: 7.8860756, y: 18.34175))
        p.addCurve(to: CGPoint(x: 8.7083333, y: 16.53125), control1: CGPoint(x: 8.70833844, y: 16.532986), control2: CGPoint(x: 8.70833844, y: 16.532118))
        p.addCurve(to: CGPoint(x: 9.265625, y: 15.283854), control1: CGPoint(x: 8.9175883, y: 16.065356), control2: CGPoint(x: 9.109929, y: 15.660028))
        p.addCurve(to: CGPoint(x: 9.2447917, y: 15.466146), control1: CGPoint(x: 9.2592992, y: 15.344599), control2: CGPoint(x: 9.2496169, y: 15.405306))
        p.addCurve(to: CGPoint(x: 9.2760417, y: 17.351562), control1: CGPoint(x: 9.1520498, y: 16.181385), control2: CGPoint(x: 9.1691558, y: 16.827279))
        p.addCurve(to: CGPoint(x: 9.8828125, y: 18.53125), control1: CGPoint(x: 9.3835925, y: 17.879105), control2: CGPoint(x: 9.5740855, y: 18.294065))
        p.addCurve(to: CGPoint(x: 10.0724396, y: 18.569153), control1: CGPoint(x: 9.93678423, y: 18.5724732), control2: CGPoint(x: 10.0067684, y: 18.5864618))
        p.addCurve(to: CGPoint(x: 10.21875, y: 18.442708), control1: CGPoint(x: 10.1381108, y: 18.5518443), control2: CGPoint(x: 10.1921084, y: 18.5051782))
        p.addCurve(to: CGPoint(x: 10.346354, y: 17.382812), control1: CGPoint(x: 10.362355, y: 18.105891), control2: CGPoint(x: 10.311551, y: 17.763764))
        p.addCurve(to: CGPoint(x: 10.346354, y: 17.380208), control1: CGPoint(x: 10.3463591, y: 17.381944), control2: CGPoint(x: 10.3463591, y: 17.381076))
        p.addCurve(to: CGPoint(x: 10.346354, y: 17.377604), control1: CGPoint(x: 10.3463591, y: 17.37934), control2: CGPoint(x: 10.3463591, y: 17.378472))
        p.addCurve(to: CGPoint(x: 10.346354, y: 17.375), control1: CGPoint(x: 10.3463591, y: 17.376736), control2: CGPoint(x: 10.3463591, y: 17.375868))
        p.addCurve(to: CGPoint(x: 10.346354, y: 17.372396), control1: CGPoint(x: 10.3463591, y: 17.374132), control2: CGPoint(x: 10.3463591, y: 17.373264))
        p.addCurve(to: CGPoint(x: 10.346354, y: 17.369792), control1: CGPoint(x: 10.3463591, y: 17.371528), control2: CGPoint(x: 10.3463591, y: 17.37066))
        p.addCurve(to: CGPoint(x: 13.882812, y: 9.9010417), control1: CGPoint(x: 10.455696, y: 14.249119), control2: CGPoint(x: 11.520676, y: 12.04512))
        p.addCurve(to: CGPoint(x: 13.885417, y: 9.9010417), control1: CGPoint(x: 13.8836803, y: 9.90104684), control2: CGPoint(x: 13.8845487, y: 9.90104684))
        p.addCurve(to: CGPoint(x: 19.736979, y: 6.4869792), control1: CGPoint(x: 15.406321, y: 8.4892641), control2: CGPoint(x: 17.443322, y: 7.2877819))
        p.addCurve(to: CGPoint(x: 25.002604, y: 4.9713542), control1: CGPoint(x: 21.465028, y: 5.8769172), control2: CGPoint(x: 23.451154, y: 5.5070175))
        p.closeSubpath()
        return p
    }()

    fileprivate static let sparkle: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 8, y: 3.05))
        p.addCurve(to: CGPoint(x: 8.24, y: 3.48), control1: CGPoint(x: 8.15, y: 3.05), control2: CGPoint(x: 8.2, y: 3.2))
        p.addCurve(to: CGPoint(x: 10.28, y: 6.02), control1: CGPoint(x: 8.48, y: 5.25), control2: CGPoint(x: 8.92, y: 5.75))
        p.addCurve(to: CGPoint(x: 10.65, y: 6.25), control1: CGPoint(x: 10.54, y: 6.07), control2: CGPoint(x: 10.65, y: 6.12))
        p.addCurve(to: CGPoint(x: 10.28, y: 6.48), control1: CGPoint(x: 10.65, y: 6.38), control2: CGPoint(x: 10.54, y: 6.43))
        p.addCurve(to: CGPoint(x: 8.24, y: 9.02), control1: CGPoint(x: 8.92, y: 6.75), control2: CGPoint(x: 8.48, y: 7.25))
        p.addCurve(to: CGPoint(x: 8, y: 9.45), control1: CGPoint(x: 8.2, y: 9.3), control2: CGPoint(x: 8.15, y: 9.45))
        p.addCurve(to: CGPoint(x: 7.76, y: 9.02), control1: CGPoint(x: 7.85, y: 9.45), control2: CGPoint(x: 7.8, y: 9.3))
        p.addCurve(to: CGPoint(x: 5.72, y: 6.48), control1: CGPoint(x: 7.52, y: 7.25), control2: CGPoint(x: 7.08, y: 6.75))
        p.addCurve(to: CGPoint(x: 5.35, y: 6.25), control1: CGPoint(x: 5.46, y: 6.43), control2: CGPoint(x: 5.35, y: 6.38))
        p.addCurve(to: CGPoint(x: 5.72, y: 6.02), control1: CGPoint(x: 5.35, y: 6.12), control2: CGPoint(x: 5.46, y: 6.07))
        p.addCurve(to: CGPoint(x: 7.76, y: 3.48), control1: CGPoint(x: 7.08, y: 5.75), control2: CGPoint(x: 7.52, y: 5.25))
        p.addCurve(to: CGPoint(x: 8, y: 3.05), control1: CGPoint(x: 7.8, y: 3.2), control2: CGPoint(x: 7.85, y: 3.05))
        p.closeSubpath()
        return p
    }()
}
