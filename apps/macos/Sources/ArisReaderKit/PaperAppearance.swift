import AppKit
import SwiftUI

public enum PaperAppearance: String, CaseIterable, Identifiable, Sendable {
    case original, warm, night
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .original: "Original Colours"
        case .warm: "Warm Paper"
        case .night: "Night Reading"
        }
    }
    var code: UInt8 { switch self { case .original: 0; case .warm: 1; case .night: 2 } }
    var colorScheme: ColorScheme? { switch self { case .original: nil; case .warm: .light; case .night: .dark } }

    /// Vector annotations follow the same display conversion as GPU page pixels. No model
    /// colour is edited; switching back to Original restores the exact source colour.
    package func displayColor(_ color: NSColor) -> NSColor {
        guard self != .original, let rgb = color.usingColorSpace(.sRGB) else { return color }
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func srgb(_ c: CGFloat) -> CGFloat { c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map(linear)
        let paper = (self == .warm ? [252.0, 247.0, 237.0] : [36.0, 34.0, 30.0]).map { linear($0 / 255) }
        let ink = (self == .warm ? [48.0, 43.0, 37.0] : [201.0, 197.0, 189.0]).map { linear($0 / 255) }
        let lightness = channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        let values = (0..<3).map { i in srgb(ink[i] + (paper[i] - ink[i]) * (self == .night ? lightness : channels[i])) }
        return NSColor(srgbRed: values[0], green: values[1], blue: values[2], alpha: rgb.alphaComponent)
    }
}

@MainActor public final class ReadingAppearanceStore: ObservableObject {
    public static let shared = ReadingAppearanceStore()
    private let defaults: UserDefaults
    public static let preferenceKey = "lyra.paperAppearance"
    @Published public var mode: PaperAppearance {
        didSet { defaults.set(mode.rawValue, forKey: Self.preferenceKey) }
    }
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = PaperAppearance(rawValue: defaults.string(forKey: Self.preferenceKey) ?? "") ?? .original
    }
}

/// Small cached thumbnails use the same paper intent without changing their cached source PNG.
struct PaperImageAppearance: ViewModifier {
    let mode: PaperAppearance
    @ViewBuilder func body(content: Content) -> some View {
        switch mode {
        case .original: content
        case .warm: content.colorMultiply(Color(red: 252/255, green: 247/255, blue: 237/255))
        case .night: content.grayscale(1).colorInvert().contrast(0.6).brightness(-0.05)
        }
    }
}
