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
    /// It owns the **registry**, not the reader's documents. Those requests can arrive *before* a
    /// window exists, which is why they need somewhere to wait; they are not why a document should
    /// live in one object for the whole app. The registry queues them until a window registers and
    /// then hands them to that window's own session, so each window has its own tabs, document,
    /// scroll position and zoom (``ReaderSession``, ``ReaderWindowRegistry``).
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
        // A named scene so the app can ask for another window by id: a drop on the sidebar, and a
        // thumbnail's "Open in New Window", create an independent `ReaderSession` here
        // (`openWindow(id: ReaderWindowRegistry.readerWindowID)`). The id is the only thing that
        // makes a *second* reader window possible; without it `openWindow` would have nothing to
        // open.
        WindowGroup("Lyra", id: ReaderWindowRegistry.readerWindowID) {
            // One session per window, made by the window's own `@StateObject` — the app holds no
            // per-window state, so it cannot hand one window's documents to another. The delegate
            // below is the delivery point for documents macOS opens *at* Lyra; it routes each to
            // the reader's window (`ReaderWindowRegistry`).
            ReaderWindowRoot(registry: appDelegate.registry)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            ReaderCommands()
        }

        Settings {
            SettingsView(registry: appDelegate.registry)
        }
    }
}

/// The Reading menu and ⌘O, acting on the focused window's session.
///
/// These used to close over `appDelegate.state`, one object for the whole app, which is the same
/// shared-state bug the sessions fix in a place a reader reaches without a mouse: with two windows
/// open, ⌘+ zoomed "the" document — both of them — and ⌘W-less tab switching in one window moved
/// the other. A focused value gives each menu item the session of the window the reader is looking
/// at, and disables the item when no reader window is focused (the Settings window, say).
///
/// The keymap lives on the Rust side (aris-reader-session::keymap, docs/04-ui-ux.md §4);
/// this is a minimal set consistent with it, to be generated from engine queries after M1 T1.9.
struct ReaderCommands: Commands {
    @FocusedValue(\.readerSession) private var session

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { session?.state.showFileImporter = true }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(session == nil)
        }

        // The only two ways this application writes into a PDF. Both are explicit commands,
        // and the second one is deliberately labelled with what it replaces: it is not a save
        // key that silently overwrites the document the reader opened.
        CommandGroup(replacing: .saveItem) {
            Button("Save Annotated Copy…") {
                session?.state.presentSaveAnnotatedCopyPanel()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(session?.state.canSaveAnnotationsToPDF != true)

            Button("Save and Replace Original…") {
                session?.state.presentReplaceOriginalConfirmation()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(session?.state.canSaveAnnotationsToPDF != true)
        }

        CommandMenu("Reading") {
            Button("Previous Page") { session?.state.previousPage() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(session == nil)
            Button("Next Page") { session?.state.nextPage() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(session == nil)

            Button("Next Search Match") { session?.state.findNext() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(session == nil)
            Button("Previous Search Match") { session?.state.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(session == nil)
            Button("Toggle Sidebar") { session?.state.sidebarVisible.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(session == nil)

            Divider()

            Button("Add Bookmark") { session?.state.addBookmarkAtCurrentPage() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(session?.state.document == nil)

            Divider()

            // The payload is the panel's generated entry, not a fresh extraction: edit the
            // fields in the Metadata sidebar section and both commands use the corrected values.
            Button("Copy BibTeX") { session?.state.copyMetadataBibtex() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(session?.state.canCopyMetadataBibtex != true)
            Button("Save BibTeX…") { session?.state.presentSaveBibtexPanel() }
                .disabled(session?.state.canCopyMetadataBibtex != true)

            Menu("Page Layout") {
                Button("Continuous") { session?.state.setLayoutMode(.continuous) }
                    .keyboardShortcut("1", modifiers: .command)
                    .disabled(session == nil)
                Button("Facing Pages") { session?.state.setLayoutMode(.facing) }
                    .keyboardShortcut("3", modifiers: .command)
                    .disabled(session == nil)
                Divider()
                Button("Increase Page Gap") {
                    guard let state = session?.state else { return }
                    state.setPageGap(state.pageGapPt + 4)
                }
                .disabled(session == nil)
                Button("Decrease Page Gap") {
                    guard let state = session?.state else { return }
                    state.setPageGap(state.pageGapPt - 4)
                }
                .disabled(session == nil)
            }

            Divider()

            Button("Zoom In") { session?.state.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(session == nil)
            Button("Zoom Out") { session?.state.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(session == nil)
            Button("Actual Size") { session?.state.zoomActual() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(session == nil)

            Divider()

            // Recovery for a sidecar that could not be read. The file is moved aside, never
            // overwritten, and a fresh empty sidecar takes its place.
            Button("Back Up Unreadable Annotations and Start Fresh…") {
                if let backup = session?.state.recoverUnreadableAnnotationSidecar() {
                    session?.state.revealSidecarBackupInFinder(backup)
                }
            }
            .disabled(session?.state.canRecoverUnreadableAnnotationSidecar != true)

            Button("Reveal Annotation Backup in Finder") {
                session?.state.revealSidecarBackupInFinder()
            }
            .disabled(session?.state.lastSidecarBackupURL == nil)
        }

        // Page operations (T3.9). Everything here is staged in a working copy until one of the
        // two explicit save commands; "Discard" throws the staging away and leaves the file alone.
        CommandMenu("Pages") {
            Button("Rotate Selected Pages Clockwise") {
                session?.state.rotateSelectedPages(clockwise: true)
            }
            .disabled(session?.state.canPageEdit != true)
            Button("Rotate Selected Pages Anticlockwise") {
                session?.state.rotateSelectedPages(clockwise: false)
            }
            .disabled(session?.state.canPageEdit != true)
            Button("Reset Rotation to the File's Original") {
                session?.state.resetSelectedPageRotations()
            }
            .disabled(session?.state.canPageEdit != true)

            Divider()

            Button("Delete Selected Pages…") {
                session?.state.confirmDeleteSelectedPages()
            }
            .disabled(session?.state.canPageEdit != true)

            Button("Move Selected Pages Up") {
                session?.state.moveSelectedPagesUp()
            }
            .disabled(session?.state.canPageEdit != true)
            Button("Move Selected Pages Down") {
                session?.state.moveSelectedPagesDown()
            }
            .disabled(session?.state.canPageEdit != true)

            Divider()

            Button("Insert Blank Page Before") {
                session?.state.insertBlankPage(before: true)
            }
            .disabled(session?.state.canPageEdit != true)
            Button("Insert Blank Page After") {
                session?.state.insertBlankPage(before: false)
            }
            .disabled(session?.state.canPageEdit != true)
            Button("Extract Selected Pages…") {
                session?.state.presentExtractPagesPanel()
            }
            .disabled(session?.state.document == nil)

            Divider()

            Button("Undo Page Change") { session?.state.undoPageEdit() }
                .disabled(session?.state.canUndoPageEdit != true)
            Button("Redo Page Change") { session?.state.redoPageEdit() }
                .disabled(session?.state.canRedoPageEdit != true)

            Divider()

            Button("Save Edited Copy…") {
                session?.state.presentSavePageEditsCopyPanel()
            }
            .disabled(session?.state.canApplyPageEdits != true)
            Button("Replace Original with Page Changes…") {
                session?.state.presentReplaceOriginalWithPageEditsConfirmation()
            }
            .disabled(session?.state.canApplyPageEdits != true)
            Button("Discard Page Changes…") {
                session?.state.presentDiscardPageEditsConfirmation()
            }
            .disabled(session?.state.pageEditSessionActive != true)

            Divider()

            Button("Clear Page Selection") { session?.state.clearPageSelection() }
                .disabled(session?.state.pageSelection.isEmpty != false)
        }
    }
}
