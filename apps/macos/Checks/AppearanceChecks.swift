import AppKit
import LyraReaderKit

extension ReaderChecks {
    /// SwiftUI resolves dynamic NSColors on its display-link queue as well as the main thread.
    /// An actor-inheriting provider traps there even though launch and main-thread drawing work.
    @MainActor static func appearanceChecks() async {
        let colors = [LyraReaderTheme.canvasColor, LyraReaderTheme.titlebarColor, LyraReaderTheme.noteTextColor]
        let samples = await Task.detached {
            [NSAppearance.Name.aqua, .darkAqua].map { name in
                var result: [Double] = []
                NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                    result = colors.flatMap { color in
                        let rgb = color.usingColorSpace(.sRGB)!
                        return [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)]
                    }
                }
                return result
            }
        }.value
        require(samples.count == 2 && samples[0].count == 9 && samples[1].count == 9,
                "LyraReader colors resolve safely on a background rendering thread")
        require(samples[0][0] > 0.8 && samples[1][0] < 0.2,
                "canvas switches between warm light and dark surfaces")
        require(samples[0][6] < samples[1][6], "note text adapts for readable light and dark paper")
    }
}
