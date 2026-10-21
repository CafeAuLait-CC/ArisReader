import AppKit
import LyraReaderKit
import SwiftUI

/// Application entry point.
///
/// Note: launching directly with `swift run LyraReader` provides no `.app` bundle, so the
/// `.regular` activation policy is set explicitly to guarantee a Dock icon and an activatable
/// window; release distribution is assembled into a `.app` by `scripts/make-app-bundle.sh`
/// (`docs/adr/0006`).
@main
struct LyraReaderApp: App {
    /// The app delegate is SwiftUI's AppKit delegate (`@NSApplicationDelegateAdaptor`), and it is
    /// where macOS delivers documents meant for LyraReader: dropped on the Dock icon, opened through
    /// Finder's “Open With”, or passed to `open -a LyraReader …` (T2.12).
    ///
    /// It owns the **registry**, not the reader's documents. Those requests can arrive *before* a
    /// window exists, which is why they need somewhere to wait; they are not why a document should
    /// live in one object for the whole app. The registry queues them until a window registers and
    /// then hands them to that window's own session, so each window has its own tabs, document,
    /// scroll position and zoom (``ReaderSession``, ``ReaderWindowRegistry``).
    @NSApplicationDelegateAdaptor(LyraReaderAppDelegate.self) private var appDelegate
    /// Keeps the fallback timer alive until it fires (or the app is gone before that).
    private static var quitWatchdog: DispatchSourceTimer?

    init() {
        ReaderDataCompatibility.migratePreferences()
        AppState.recordsRecentDocuments = true
        // A packaged app must use its own PDFium before the engine's development-directory
        // fallback. That fallback may point into a protected Documents checkout and block
        // dlopen on first open. Preserve an explicit, nonempty developer override.
        let pdfiumOverride = ProcessInfo.processInfo.environment["LYRA_READER_PDFIUM_PATH"]
        if pdfiumOverride?.isEmpty != false,
           let frameworks = Bundle.main.privateFrameworksURL {
            let bundled = frameworks.appendingPathComponent("libpdfium.dylib")
            if FileManager.default.fileExists(atPath: bundled.path) {
                setenv("LYRA_READER_PDFIUM_PATH", bundled.path, 1)
            }
        }

        // Running the bare executable (swift run / swift build output) has no
        // LaunchServices activation, so the window can stay behind the terminal —
        // and a Metal surface reports itself as occluded while it is not on screen.
        // A packaged .app gets this for free; doing it here keeps dev runs usable.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Development aid: LYRA_READER_QUIT_AFTER=<ms> quits through the normal AppKit path
        // (applicationWillTerminate → flush), so "quit inside the debounce window" — and the
        // flush that must cover it — can be verified headlessly.
        if let raw = ProcessInfo.processInfo.environment["LYRA_READER_QUIT_AFTER"],
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
        WindowGroup("LyraReader", id: ReaderWindowRegistry.readerWindowID) {
            // One session per window, made by the window's own `@StateObject` — the app holds no
            // per-window state, so it cannot hand one window's documents to another. The delegate
            // below is the delivery point for documents macOS opens *at* LyraReader; it routes each to
            // the reader's window (`ReaderWindowRegistry`).
            ReaderWindowRoot(registry: appDelegate.registry)
        }
        .windowStyle(.hiddenTitleBar)
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
/// The keymap lives on the Rust side (lyra-reader-session::keymap, docs/04-ui-ux.md §4);
/// this is a minimal set consistent with it, to be generated from engine queries after M1 T1.9.
struct ReaderCommands: Commands {
    @ObservedObject private var readingAppearance = ReadingAppearanceStore.shared
    @FocusedValue(\.readerSession) private var session
    @FocusedObject private var focusedState: AppState?

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
            Button("Save") {
                session?.state.saveDocument()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(session?.state.canSaveDocument != true)

            Button("Save As…") {
                session?.state.presentSaveDocumentCopyPanel()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(session?.state.canSaveDocument != true)

            Divider()

            // Exports that leave the reader as data rather than writing into the PDF: the
            // annotation text (Markdown or CSV, chosen in the save panel) and the BibTeX entry
            // for the paper. Both are grouped here because neither touches the document.
            Menu("Export") {
                Button("Annotations…") {
                    session?.state.presentExportAnnotationsPanel()
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(session?.state.canExportAnnotations != true)

                Button("BibTeX…") { session?.state.presentSaveBibtexPanel() }
                    .disabled(session?.state.canCopyMetadataBibtex != true)
            }
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") { session?.state.printDocument() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(session?.state.document == nil)
        }

        CommandGroup(after: .toolbar) {
            Divider()
            Picker("Paper Appearance", selection: $readingAppearance.mode) {
                ForEach(PaperAppearance.allCases) { mode in Text(mode.title).tag(mode) }
            }
            Button("Search Results") { focusedState?.searchSidebarVisible.toggle() }
                .disabled(focusedState?.document == nil)
            Button("Document Information…") { focusedState?.showDocumentInformation = true }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(focusedState?.document == nil)

            Divider()

            // The zoom presets. "Actual Size" is physical size on the current display: the
            // screen's own logical density calibrates the percentage (see DisplayCalibration).
            Button("Actual Size (100%)") { session?.state.zoomActual() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(session == nil)
            Button("Fit Width") { session?.state.zoomFitWidth() }
                .keyboardShortcut("9", modifiers: .command)
                .disabled(session == nil)
            Button("Fit Page") { session?.state.zoomFitPage() }
                .keyboardShortcut("9", modifiers: [.command, .shift])
                .disabled(session == nil)

            Divider()

            Button("Zoom In") { session?.state.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(session == nil)
            Button("Zoom Out") { session?.state.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(session == nil)
        }

        CommandMenu("Reading") {
            Button("Previous Page") { session?.state.previousPage() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(session == nil)
            Button("Next Page") { session?.state.nextPage() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(session == nil)

            Divider()

            // History for jumps the floating preview started (and the forward branch those
            // jumps truncate). ⌘[ / ⌘] are the window-navigation pair macOS readers share,
            // and they stay available after the preview is closed.
            Button("Back") { session?.state.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(session?.state.canGoBack != true)
            Button("Forward") { session?.state.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(session?.state.canGoForward != true)

            Divider()

            Button("Next Search Match") { session?.state.findNext() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(session == nil)
            Button("Previous Search Match") { session?.state.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(session == nil)
            Button("Toggle Sidebar") { session?.state.sidebarVisible.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(session == nil)
            // The assistant left the sidebar for its own right-hand panel. ⇧⌘A is the AI-panel
            // binding the Rust keymap already documents, and it was unused by the native menu
            // (⌥⌘I is Document Information and ⌥⌘S toggles the sidebar).
            Button(ReaderShortcuts.toggleAIPanelLabel) { session?.state.toggleRightPanel() }
                .keyboardShortcut(ReaderShortcuts.toggleAIPanelKey,
                                  modifiers: ReaderShortcuts.toggleAIPanelModifiers)
                .disabled(session == nil)

            Divider()

            Button("Add Bookmark") { session?.state.addBookmarkAtCurrentPage() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(focusedState?.document == nil)

            Divider()

            // The payload is the panel's generated entry, not a fresh extraction: edit the
            // fields in the Metadata sidebar section and both commands use the corrected values.
            Button("Copy BibTeX") { session?.state.copyMetadataBibtex() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
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

        // Redaction (T3.12). Marks are pending until one of the two explicit apply commands;
        // the confirmation says what will be lost, and neither command runs in the background.
        CommandMenu("Redaction") {
            Button("Redact Tool") { session?.state.toggleRedactionTool() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(session?.state.canMarkRedactions != true)
            Button("Mark Selection for Redaction") {
                _ = session?.state.markSelectionForRedaction()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(session == nil)
            Button("Remove Last Mark") { session?.state.removeLastPendingRedaction() }
                .disabled(session?.state.pendingRedactions.isEmpty != false)

            Divider()

            Button("Apply to Copy…") { session?.state.presentApplyRedactionsPanel() }
                .disabled(session?.state.canApplyRedactions != true)
            Button("Replace Original…") {
                session?.state.presentReplaceRedactionsConfirmation()
            }
            .disabled(session?.state.canApplyRedactions != true)
            Button("Clear Pending Redactions") { session?.state.clearPendingRedactions() }
                .disabled(session?.state.pendingRedactions.isEmpty != false)
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
            .disabled(focusedState?.document == nil)

            Divider()

            // Merge and split are immediate-to-a-new-file, like Extract: they never end the
            // staged page-edit session and are not undoable, because the source is only read.
            Button("Append Pages from PDFs…") {
                session?.state.presentMergeDocumentsPanel()
            }
            .disabled(focusedState?.document == nil)
            Button("Split Pages…") {
                session?.state.presentSplitPagesPanel()
            }
            .disabled(focusedState?.document == nil)

            Divider()

            Button("Undo Page Change") { session?.state.undoPageEdit() }
                .disabled(session?.state.canUndoPageEdit != true)
            Button("Redo Page Change") { session?.state.redoPageEdit() }
                .disabled(session?.state.canRedoPageEdit != true)

            Divider()

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
