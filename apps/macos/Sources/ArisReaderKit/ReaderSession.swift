import AppKit
import Combine
import SwiftUI

/// One Lyra window's own document session: its tabs, its current document, its reading position,
/// its zoom and its own engine.
///
/// **Why this type exists.** Before it, the application made exactly one `AppState` — in
/// `ArisReaderAppDelegate.init` (`DocumentOpening.swift`) — and handed that same object to
/// *every* window the scene makes (`ArisReaderApp.swift`: `ReaderWindow(state: appDelegate.state,
/// opener: appDelegate.opener)`). Two windows were therefore two views of one session: one `tabs`
/// array, one `document`, one `scrollYPt`, one `zoomPercent`, and one `PDFEngine` holding one
/// open `ArisDocument` (`Engine.swift`, `RustEngine.document`). The reader's report — a PDF
/// dropped on the Dock icon opens a second window, and both windows then show the same tabs and
/// scroll together — is that ownership graph, not a rendering, sync or scroll bug. A test written
/// against the old graph fails on its first assertion: the scene's two windows are handed the
/// *identical* object (`delegate.state === delegate.state`).
///
/// The fix is ownership, not synchronisation. Everything a reader can change about "what this
/// window is showing" lives in this session and is reachable from no other window:
///
/// * `state` — `AppState`, which owns `document`, `tabs`, `activeTabIndex`, `scrollYPt`,
///   `zoomPercent`, the selection, search results, annotations, the tile cache, **and the
///   engine**;
/// * `opener` — the coordinator for documents that arrive from outside the window (the Dock,
///   Finder, `open -a`) and for files dropped on *this* window's canvas;
/// * `previewPanels` — the floating reference panel, which used to be a process-wide singleton
///   (`ReferencePreviewPanelController.shared`) that every window re-synced: with per-window state
///   the second window's update would close the first window's panel.
///
/// What stays process-wide is what *is* process-wide, and none of it is per-window state: the
/// PDFium library (a `OnceLock`, `crates/aris-reader-pdfium/src/backend.rs`), the wgpu device
/// (`static GPU`, `crates/aris-reader-ffi/src/lib.rs`), AppKit, and the window server. A second
/// engine therefore does **not** buy a second copy of that floor; what it costs is per-document
/// state, which a second independent window needs anyway (see the pull request's measurement).
@MainActor
public final class ReaderSession: ObservableObject, Identifiable {
    public let id = UUID()

    /// This window's view model: document, tabs, reading position, zoom, tile cache, engine.
    public let state: AppState

    /// Documents this window should open — from the system (routed here by
    /// ``ReaderWindowRegistry``) and from files dropped on its own canvas.
    public let opener: DocumentOpenCoordinator

    /// The floating reference panel belonging to this window (see the type comment).
    public let previewPanels: ReferencePreviewPanelController

    /// The window AppKit put this session's view hierarchy in, once it has one.
    ///
    /// Weak: the window owns the view hierarchy, the session must not keep a closed window alive.
    public private(set) weak var window: NSWindow?

    /// Where sessions register themselves and external documents are routed.
    ///
    /// Weak so that a session never keeps the registry (and through it every other session) alive;
    /// the delegate owns the registry for the life of the process.
    private weak var registry: ReaderWindowRegistry?

    /// The order in which this session joined the registry — its window's creation order.
    ///
    /// The registry uses it to tell a window AppKit has just made for an open request from the
    /// windows that were already there (`ReaderWindowRegistry.receive(_:)`). Written by the
    /// registry on registration; nothing else reads it.
    var registrationOrdinal = 0

    private var windowObservers: [NSObjectProtocol] = []

    /// `state` is injectable so the checks can drive a session against a known engine; the app
    /// leaves it out and gets a session with its own engine.
    public init(state: AppState? = nil, registry: ReaderWindowRegistry) {
        self.state = state ?? AppState()
        self.opener = DocumentOpenCoordinator(state: self.state, registry: registry)
        self.previewPanels = ReferencePreviewPanelController()
        self.registry = registry
    }

    /// Installs the app's "make another reader window" command into the registry.
    ///
    /// `ReaderWindowRoot` passes SwiftUI's `openWindow` here. The registry stays free of SwiftUI,
    /// and a check can substitute a closure that registers a session, so the new-window drop path
    /// is asserted against the real routing rule rather than against a screenshot.
    public func installNewWindowAction(_ action: @escaping () -> Void) {
        registry?.newWindow = action
    }

    // MARK: - Window lifecycle

    /// This session's window appeared (or changed). Called by the window's view host.
    ///
    /// Registration is idempotent on purpose: SwiftUI runs `onAppear` more than once for one
    /// window (measured: three times per window), so anything that counted appearances would
    /// create three sessions — three engines — per window.
    public func attach(window: NSWindow?) {
        register()
        guard let window else {
            // The view left its window. That is *not* a close: SwiftUI rebuilds a window's view
            // hierarchy (the same measurement: three passes for one window), so treating a nil
            // window as "the window is gone" would take a live window out of the registry — and
            // with it the place an external document should land — for the length of a rebuild.
            // `NSWindow.willCloseNotification`, below, is what says a window is really gone.
            return
        }
        if window !== self.window {
            removeWindowObservers()
            self.window = window
            let center = NotificationCenter.default
            windowObservers.append(center.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteFocused() }
            })
            windowObservers.append(center.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        }
        if window.isKeyWindow { noteFocused() }
        // The window a held delivery is waiting for has just been identified — this is what turns
        // "a document arrived while a window was being made" into "that window has the document".
        registry?.sessionAttached(self)
    }

    /// Joins the registry as a window the reader can be shown documents in. Idempotent.
    public func register() {
        registry?.register(self)
    }

    /// AppKit made this session's window key: documents arriving from outside the app land here.
    public func noteFocused() {
        registry?.noteFocused(self)
    }

    /// This window is gone: forget its place in the registry and let its panel go.
    public func close() {
        registry?.unregister(self)
        previewPanels.close()
        removeWindowObservers()
        window = nil
    }

    private func removeWindowObservers() {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
    }
}

/// The scene's per-window root: it makes one ``ReaderSession`` per window and nothing else.
///
/// `@StateObject` is the whole mechanism behind "one session per window": SwiftUI gives every
/// window of a `WindowGroup` its own state storage, so the object below is built once per window
/// and survives that window's re-renders. The app entry point therefore contains no per-window
/// state at all — it cannot leak one window's session into another, because it never holds one.
public struct ReaderWindowRoot: View {
    @StateObject private var session: ReaderSession
    /// SwiftUI's command for making another window in this scene. Handed to the registry once the
    /// window exists, so a drop on the sidebar can ask for one without the registry knowing SwiftUI.
    @Environment(\.openWindow) private var openWindow

    public init(registry: ReaderWindowRegistry) {
        _session = StateObject(wrappedValue: ReaderSession(registry: registry))
    }

    public var body: some View {
        ReaderWindow(state: session.state, opener: session.opener, previewPanels: session.previewPanels)
            // The reading commands (⌘O, ⌘←/→, ⌘G, zoom, sidebar) are app-wide menu items, so they
            // read the session of the *focused* window rather than a single global one.
            .focusedSceneValue(\.readerSession, session)
            .background(ReaderWindowAttachment { session.attach(window: $0) })
            .onAppear {
                session.register()
                // `openWindow(id:)` is what makes a second, independent `ReaderSession` (and so a
                // second window in the registry). Every window installs the same action; it is
                // idempotent and always refers to this scene's WindowGroup.
                session.installNewWindowAction { openWindow(id: ReaderWindowRegistry.readerWindowID) }
            }
    }
}

/// The `ReaderSession` of the focused window, for `Commands` (⌘O, ⌘+, ⌘G, …).
public struct ReaderSessionFocusedValueKey: FocusedValueKey {
    public typealias Value = ReaderSession
}

extension FocusedValues {
    /// Set by ``ReaderWindowRoot`` on the focused scene and read by the reading commands.
    public var readerSession: ReaderSession? {
        get { self[ReaderSessionFocusedValueKey.self] }
        set { self[ReaderSessionFocusedValueKey.self] = newValue }
    }
}

/// Reports the `NSWindow` this view hierarchy ended up in.
///
/// A session has to know its window to tell whether it is the one the reader is looking at (an
/// open request from the Dock goes to the focused window) and to notice the window closing. There
/// is no SwiftUI environment value for "my window" that a view can also observe closing, so the
/// window is read from AppKit where it is unambiguous.
private struct ReaderWindowAttachment: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowReportingView)?.onWindow = onWindow
    }
}

/// A zero-size view whose only job is to say which window it is in.
private final class WindowReportingView: NSView {
    var onWindow: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let window = self.window
        // AppKit is inside a view update here; telling the session now would publish changes from
        // within that update, so the report is handed to the next main-queue turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onWindow?(window)
        }
    }
}
