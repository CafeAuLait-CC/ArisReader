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
    /// The app delegate is SwiftUI's AppKit delegate (`@NSApplicationDelegateAdaptor`), and it is
    /// where macOS delivers documents meant for Lyra: dropped on the Dock icon, opened through
    /// Finder's “Open With”, or passed to `open -a Lyra …` (T2.12).
    ///
    /// The document state therefore lives on the delegate rather than in a `@StateObject`: those
    /// requests can arrive *before* the window exists, and an open request that found no state
    /// would be lost.
    @NSApplicationDelegateAdaptor(ArisReaderAppDelegate.self) private var appDelegate
    /// Keeps the fallback timer alive until it fires (or the app is gone before that).
    private static var quitWatchdog: DispatchSourceTimer?

    init() {
        // Running the bare executable (swift run / swift build output) has no
        // LaunchServices activation, so the window can stay behind the terminal —
        // and a Metal surface reports itself as occluded while it is not on screen.
        // A packaged .app gets this for free; doing it here keeps dev runs usable.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Development aid: ARIS_READER_QUIT_AFTER=<ms> quits through the normal AppKit path
        // (applicationWillTerminate → flush), so "quit inside the debounce window" — and the
        // flush that must cover it — can be verified headlessly.
        if let raw = ProcessInfo.processInfo.environment["ARIS_READER_QUIT_AFTER"],
           let milliseconds = Int(raw), milliseconds >= 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                NSApplication.shared.terminate(nil)
                // An attached sheet (the "sidecar could not be read" alert) holds AppKit's
                // termination back until the reader answers it. Fall back to the signal path,
                // which flushes and exits, so a dev run cannot become an unkillable process.
                // A timer on a background queue, because the run loop may be in a modal mode.
                let watchdog = DispatchSource.makeTimerSource(queue: .global())
                watchdog.schedule(deadline: .now() + .milliseconds(1500))
                // Explicitly nonisolated: a closure written here would inherit this type's
                // main-actor isolation and trap when libdispatch runs it on its own queue.
                watchdog.setEventHandler(handler: Self.raiseTerminationSignal)
                watchdog.resume()
                Self.quitWatchdog = watchdog
            }
        }
    }

    private nonisolated static func raiseTerminationSignal() {
        raise(SIGTERM)
    }

    var body: some Scene {
        WindowGroup("Lyra") {
            ReaderWindow(state: appDelegate.state, opener: appDelegate.opener)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    appDelegate.state.showFileImporter = true
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            // The keymap lives on the Rust side (aris-reader-session::keymap, docs/04-ui-ux.md §4);
            // this is a minimal set consistent with it, to be generated from engine queries after M1 T1.9.
            CommandMenu("Reading") {
                Button("Previous Page") { appDelegate.state.previousPage() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Next Page") { appDelegate.state.nextPage() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)

                Button("Next Search Match") { appDelegate.state.findNext() }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Previous Search Match") { appDelegate.state.findPrevious() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Toggle Sidebar") { appDelegate.state.sidebarVisible.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .option])

                Divider()

                Button("Zoom In") { appDelegate.state.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") { appDelegate.state.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { appDelegate.state.zoomActual() }
                    .keyboardShortcut("0", modifiers: .command)

                Divider()

                // Recovery for a sidecar that could not be read. The file is moved aside, never
                // overwritten, and a fresh empty sidecar takes its place.
                Button("Back Up Unreadable Annotations and Start Fresh…") {
                    if let backup = appDelegate.state.recoverUnreadableAnnotationSidecar() {
                        appDelegate.state.revealSidecarBackupInFinder(backup)
                    }
                }
                .disabled(!appDelegate.state.canRecoverUnreadableAnnotationSidecar)

                Button("Reveal Annotation Backup in Finder") {
                    appDelegate.state.revealSidecarBackupInFinder()
                }
                .disabled(appDelegate.state.lastSidecarBackupURL == nil)
            }
        }

        Settings {
            SettingsView(state: appDelegate.state)
        }
    }
}
