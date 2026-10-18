import AppKit
import SwiftUI

/// Native semantic colors from docs/Lyra-Palette (sRGB). PDF pixels keep their source colors.
@MainActor
public enum LyraTheme {
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { @Sendable appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
    }

    public static let windowBg = Color(nsColor: adaptive(0xFAFAFA, 0x201F1D))
    public static let titlebarBg = Color(nsColor: adaptive(0xF4F1EC, 0x24221F))
    public static let toolbarBg = Color(nsColor: adaptive(0xF7F4EF, 0x28251F))
    public static let tabbarBg = Color(nsColor: adaptive(0xF0EBE3, 0x211F1C))
    public static let sidebarBg = Color(nsColor: adaptive(0xF3EFE8, 0x24221E))
    public static let panelBg = Color(nsColor: adaptive(0xF8F6F2, 0x2B2823))
    public static let raisedBg = Color(nsColor: adaptive(0xFFFDFA, 0x343029))
    public static let menuBg = Color(nsColor: adaptive(0xFFFDFA, 0x343029))
    public static let fieldBg = Color(nsColor: adaptive(0xFFFDFA, 0x1F1D1A))
    public static let canvasBg = Color(nsColor: adaptive(0xE7E2D9, 0x171716))
    public static let emptyBg = Color(nsColor: adaptive(0xEEEAE3, 0x1B1A18))
    public static let statusbarBg = Color(nsColor: adaptive(0xF4F1EC, 0x24221F))
    public static let textPrimary = Color(nsColor: adaptive(0x302B25, 0xF1ECE3))
    public static let textSecondary = Color(nsColor: adaptive(0x655C50, 0xC8BFAF))
    public static let textTertiary = Color(nsColor: adaptive(0x675C50, 0xB4A995))
    public static let textPlaceholder = Color(nsColor: adaptive(0x786E62, 0xB0A38F))
    public static let textDisabled = Color(nsColor: adaptive(0xA79E90, 0x736D62))
    public static let iconPrimary = Color(nsColor: adaptive(0x5F564B, 0xD4C9B7))
    public static let iconSecondary = Color(nsColor: adaptive(0x7B7062, 0xADA18C))
    public static let border = Color(nsColor: adaptive(0xDDD6CA, 0x494237))
    public static let separator = Color(nsColor: adaptive(0xE5DFD5, 0x3C362E))
    public static let controlBorder = Color(nsColor: adaptive(0x8C8173, 0x9A8B73))
    public static let pageEdge = Color(nsColor: adaptive(0xC7BFAF, 0x5C5345))
    public static let scrollThumb = Color(nsColor: adaptive(0x837968, 0x8D806D))
    public static let scrollThumbHover = Color(nsColor: adaptive(0x746653, 0xAD9A7A))
    public static let accent = Color(nsColor: adaptive(0x88611B, 0xE7C07B))
    public static let accentHover = Color(nsColor: adaptive(0x6E4C10, 0xF2D49F))
    public static let accentPressed = Color(nsColor: adaptive(0x573B09, 0xD6A654))
    public static let onAccent = Color(nsColor: adaptive(0xFFFFFF, 0x2D2417))
    public static let accentSoft = Color(nsColor: adaptive(0xF8EDD6, 0x3B3122))
    public static let accentBorder = Color(nsColor: adaptive(0x9F752D, 0xC99B4F))
    public static let hoverBg = Color(nsColor: adaptive(0xEDE7DE, 0x3B3429))
    public static let pressedBg = Color(nsColor: adaptive(0xE1D7C7, 0x4B3C27))
    public static let selectedBg = Color(nsColor: adaptive(0xF5DEB3, 0x514022))
    public static let selectedFg = Color(nsColor: adaptive(0x5B4319, 0xF5DEB3))
    public static let inactiveSelectionBg = Color(nsColor: adaptive(0xE9E2D8, 0x38342D))
    public static let inactiveSelectionFg = Color(nsColor: adaptive(0x665C50, 0xC0B5A4))
    public static let focusRing = Color(nsColor: adaptive(0x9A6A19, 0xE7C07B))
    public static let menuSelectedBg = Color(nsColor: adaptive(0xF5DEB3, 0x514022))
    public static let menuSelectedFg = Color(nsColor: adaptive(0x4C391C, 0xF5DEB3))
    public static let textSelectionBg = Color(nsColor: adaptive(0xE8D9AF, 0x5B4828))
    public static let textSelectionFg = Color(nsColor: adaptive(0x302B25, 0xFFF4DE))
    public static let searchMatchBg = Color(nsColor: adaptive(0xF7E8A4, 0x4C4025))
    public static let searchMatchFg = Color(nsColor: adaptive(0x342710, 0xF6E5AC))
    public static let searchCurrentBg = Color(nsColor: adaptive(0xE6B764, 0x7A571F))
    public static let searchCurrentFg = Color(nsColor: adaptive(0x342710, 0xFFF8E7))
    public static let bookmark = Color(nsColor: adaptive(0x9A6A19, 0xE7C07B))
    public static let noteBg = Color(nsColor: adaptive(0xFFF0E6, 0x463126))
    public static let noteFg = Color(nsColor: adaptive(0x8A4C26, 0xF3BD94))
    public static let successBg = Color(nsColor: adaptive(0xE9F3ED, 0x243A2D))
    public static let successFg = Color(nsColor: adaptive(0x2F6F53, 0x96CBA9))
    public static let warningBg = Color(nsColor: adaptive(0xFFF2D4, 0x40351F))
    public static let warningFg = Color(nsColor: adaptive(0x845E16, 0xE7C477))
    public static let errorBg = Color(nsColor: adaptive(0xFCECE8, 0x472B29))
    public static let errorFg = Color(nsColor: adaptive(0xAA3D36, 0xF0A59E))
    public static let infoBg = Color(nsColor: adaptive(0xEAF1F5, 0x293841))
    public static let infoFg = Color(nsColor: adaptive(0x386783, 0xA6C8DE))

    public static let canvasColor = adaptive(0xE7E2D9, 0x171716)
    public static let noteTextColor = adaptive(0x8A4C26, 0xF3BD94)
    public static let titlebarColor = adaptive(0xF4F1EC, 0x24221F)

    /// GPU clears are linear; the palette and PDF texture bytes are sRGB.
    static func canvasClear(appearance: NSAppearance) -> [Double] {
        var color = NSColor.black
        appearance.performAsCurrentDrawingAppearance { color = canvasColor.usingColorSpace(.sRGB)! }
        return [color.redComponent, color.greenComponent, color.blueComponent].map {
            let value = Double($0)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
    }
}

/// Shared by toolbar buttons; native keyboard focus and disabled behavior are preserved.
struct LyraToolStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        ToolBody(configuration: configuration, selected: selected)
    }

    private struct ToolBody: View {
        let configuration: Configuration
        let selected: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .frame(minWidth: 30, minHeight: 32)
                .padding(.horizontal, 3)
                .foregroundStyle(!enabled ? LyraTheme.textDisabled :
                    (selected ? LyraTheme.selectedFg : LyraTheme.iconPrimary))
                .background(configuration.isPressed ? LyraTheme.pressedBg :
                    (selected ? LyraTheme.selectedBg : (hovered && enabled ? LyraTheme.hoverBg : .clear)),
                    in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onHover { hovered = $0 }
        }
    }
}
