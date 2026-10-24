import SwiftUI

/// Faithful vector paths from Support/LyraReader-Interleaf.svg, supplied by the reader.
struct InterleafIcon: View {
    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width, proxy.size.height) / 24
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 8.5, y: 3.5)); p.addLine(to: CGPoint(x: 5.5, y: 3.5))
                    p.addCurve(to: CGPoint(x: 3.5, y: 5.5), control1: CGPoint(x: 4.39543, y: 3.5), control2: CGPoint(x: 3.5, y: 4.39543))
                    p.addLine(to: CGPoint(x: 3.5, y: 8.5))
                    p.move(to: CGPoint(x: 14.5, y: 3.5)); p.addLine(to: CGPoint(x: 17.5, y: 3.5))
                    p.addCurve(to: CGPoint(x: 19.5, y: 5.5), control1: CGPoint(x: 18.60457, y: 3.5), control2: CGPoint(x: 19.5, y: 4.39543))
                    p.addLine(to: CGPoint(x: 19.5, y: 8.5))
                    p.move(to: CGPoint(x: 3.5, y: 14.5)); p.addLine(to: CGPoint(x: 3.5, y: 17.5))
                    p.addCurve(to: CGPoint(x: 5.5, y: 19.5), control1: CGPoint(x: 3.5, y: 18.60457), control2: CGPoint(x: 4.39543, y: 19.5))
                    p.addLine(to: CGPoint(x: 8.5, y: 19.5))
                }.stroke(style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                Path { p in
                    p.move(to: CGPoint(x: 17.5, y: 12.9))
                    p.addCurve(to: CGPoint(x: 22.1, y: 17.5), control1: CGPoint(x: 18.03, y: 15.72), control2: CGPoint(x: 19.28, y: 16.97))
                    p.addCurve(to: CGPoint(x: 17.5, y: 22.1), control1: CGPoint(x: 19.28, y: 18.03), control2: CGPoint(x: 18.03, y: 19.28))
                    p.addCurve(to: CGPoint(x: 12.9, y: 17.5), control1: CGPoint(x: 16.97, y: 19.28), control2: CGPoint(x: 15.72, y: 18.03))
                    p.addCurve(to: CGPoint(x: 17.5, y: 12.9), control1: CGPoint(x: 15.72, y: 16.97), control2: CGPoint(x: 16.97, y: 15.72))
                    p.closeSubpath()
                }.fill()
            }.frame(width: 24, height: 24).scaleEffect(scale, anchor: .topLeading)
        }.aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
    }
}

/// Familiar A / 文 translation mark, independent of installed fonts or OS symbol additions.
struct TranslationIcon: View {
    var body: some View {
        GeometryReader { proxy in
            Path { p in
                p.move(to: CGPoint(x: 2, y: 15)); p.addLine(to: CGPoint(x: 6, y: 4)); p.addLine(to: CGPoint(x: 10, y: 15))
                p.move(to: CGPoint(x: 3.5, y: 11)); p.addLine(to: CGPoint(x: 8.5, y: 11))
                p.move(to: CGPoint(x: 17, y: 8)); p.addLine(to: CGPoint(x: 17, y: 10))
                p.move(to: CGPoint(x: 12, y: 11)); p.addLine(to: CGPoint(x: 22, y: 11))
                p.move(to: CGPoint(x: 20, y: 11)); p.addCurve(to: CGPoint(x: 12, y: 22), control1: CGPoint(x: 19, y: 16), control2: CGPoint(x: 16, y: 20))
                p.move(to: CGPoint(x: 14, y: 13)); p.addCurve(to: CGPoint(x: 22, y: 22), control1: CGPoint(x: 15, y: 17), control2: CGPoint(x: 18, y: 20))
            }.applying(CGAffineTransform(scaleX: proxy.size.width / 24, y: proxy.size.height / 24))
                .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }.aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
    }
}
