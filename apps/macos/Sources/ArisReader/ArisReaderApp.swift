import AppKit
import ArisReaderKit
import SwiftUI

/// Application entry point.
///
/// Note: launching directly with `swift run ArisReader` provides no `.app` bundle, so the
/// `.regular` activation policy is set explicitly to guarantee a Dock icon and an activatable
/// window; release distribution is assembled into a `.app` by `scripts/make-app-bundle.sh`
/// (`docs/adr/0006`).
@main
struct ArisReaderApp: App {
    @StateObject private var state = AppState()

    init() {
        // Running the bare executable (swift run / swift build output) has no
        // LaunchServices activation, so the window can stay behind the terminal —
        // and a Metal surface reports itself as occluded while it is not on screen.
        // A packaged .app gets this for free; doing it here keeps dev runs usable.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("ArisReader") {
            ReaderWindow(state: state)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    state.showFileImporter = true
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            // The keymap lives on the Rust side (aris-reader-session::keymap, docs/04-ui-ux.md §4);
            // this is a minimal set consistent with it, to be generated from engine queries after M1 T1.9.
            CommandMenu("Reading") {
                Button("Previous Page") { state.previousPage() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Next Page") { state.nextPage() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)

                Button("Next Search Match") { state.findNext() }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Previous Search Match") { state.findPrevious() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Toggle Sidebar") { state.sidebarVisible.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .option])

                Divider()

                Button("Zoom In") { state.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") { state.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { state.zoomActual() }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }

        Settings {
            SettingsView(state: state)
        }
    }
}
