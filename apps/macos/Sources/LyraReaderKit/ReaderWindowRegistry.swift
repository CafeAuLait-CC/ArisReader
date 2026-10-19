import AppKit
import Combine
import Foundation

/// The windows LyraReader has open, and the one place a document from outside the app is delivered.
///
/// The registry exists because "which window does this document belong to?" is a question only the
/// app — not a window — can answer. macOS hands LyraReader documents through
/// `LyraReaderAppDelegate.application(_:open:)` (a drop on the Dock icon, Finder's “Open With”,
/// `open -a LyraReader …`), and that request has to be turned into *one* window's new tab. Before this
/// type existed there was nothing to choose between: one `AppState` served every window, so the
/// request landed in all of them at once.
///
/// **The routing rule, and the two measurements behind it.** A document from outside goes to the
/// window AppKit made key for the request. Two traces of the real bundle shaped that:
///
/// * SwiftUI's `WindowGroup` creates a window for an `odoc` Apple event and makes it key *before*
///   AppKit delivers the event to the delegate — so by the time the request exists, `NSApp.keyWindow`
///   is already the window the document belongs to;
/// * but that window's *session* only learns which window it has when SwiftUI attaches the view,
///   which happens **after** the delivery (`application(open:) 1 url(s); windows=2` printed while
///   every session still reported `window = nil`). Routing on "which session is focused" therefore
///   sent the document to the window the reader already had and left the new one empty — measured,
///   not hypothetical.
///
/// So a key window that no session owns yet is the window being made for this very request, and the
/// delivery is held until that window's session attaches (``sessionAttached(_:)``), with a
/// main-queue turn as the bound so a stray key window can never swallow a document. The reader sees
/// a PDF dropped on the Dock icon open in the window macOS opened for it, and their other window is
/// left exactly as it was.
///
/// **Documents that arrive before any window exists.** A launch *with* a document is the normal
/// case: the Apple event arrives before SwiftUI has made the first window. Those URLs wait in
/// `pending` — they are never dropped — and are handed to the first session that registers, or, if
/// a window already exists when the app becomes ready, to the active one. The launch smoke test
/// (`scripts/smoke-launch-app.sh`) reads the `lyra-reader-open:` line this eventually produces.
@MainActor
public final class ReaderWindowRegistry: ObservableObject {
    /// Live windows, oldest first. A window leaves this list when it closes.
    @Published public private(set) var sessions: [ReaderSession] = []

    /// URLs delivered while there was no window to open them in, in arrival order.
    private var pending: [URL] = []

    /// Documents that asked for a **new** window (a drop on the sidebar, a thumbnail's "Open in
    /// New Window"), waiting for that window's session to register.
    ///
    /// They are deliberately not in `pending`: `pending` is drained into whichever window exists,
    /// and the whole point of these URLs is that they must *not* land in the window they were
    /// dropped on. The next session that registers is the window SwiftUI made for them.
    private var pendingNewWindow: [URL] = []
    /// The page the new window should show after opening, for a thumbnail menu request.
    private var pendingNewWindowPage: Int?
    /// The page-local rectangle the new window should scroll to. A preview's "open in a new
    /// window" carries one so a cited entry or a figure region arrives in view, not merely its
    /// page.
    private var pendingNewWindowRegion: CGRect?

    /// How the app asks SwiftUI for another reader window.
    ///
    /// Injected by ``ReaderWindowRoot`` (`@Environment(\.openWindow)`), so the registry itself
    /// knows nothing about SwiftUI scenes. The checks substitute a closure that registers a
    /// session of their own, which is what lets them assert routing on the registry rather than
    /// on pixels. `nil` means this build cannot make a window, and callers report that instead of
    /// pretending the document opened.
    public var newWindow: (() -> Void)?

    /// How many new-window requests the registry has served (the checks read this).
    public private(set) var newWindowRequestCount = 0

    /// How many documents are waiting for the window they asked for (the checks read this).
    public var pendingNewWindowCount: Int { pendingNewWindow.count }

    /// Whether this registry can make another reader window.
    public var canOpenNewWindow: Bool { newWindow != nil }

    /// Splits a delivery: the URLs are kept here, a new window is asked for, and ``register(_:)``
    /// hands them to that window's own session. Nothing is opened in the window that asked.
    ///
    /// Returns `false` when there is no way to make a window; the caller then reports that, so a
    /// drop is never silently swallowed.
    @discardableResult
    public func requestNewWindow(opening urls: [URL], page: Int? = nil, reveal region: CGRect? = nil) -> Bool {
        guard !urls.isEmpty else { return false }
        guard let newWindow else { return false }
        pendingNewWindow.append(contentsOf: urls)
        // The newest request is the one the next window serves, so page and region move together.
        pendingNewWindowPage = page
        pendingNewWindowRegion = region
        newWindowRequestCount += 1
        // Last, so a closure that registers its session synchronously finds the URLs waiting.
        newWindow()
        return true
    }

    /// How many sessions have ever registered, and what that count was when the last document from
    /// outside the app was delivered.
    ///
    /// Their difference is the signal a key-window check cannot give: SwiftUI registers the window
    /// it makes for an open request *before* AppKit delivers the request (measured on the real
    /// bundle: `lyra-reader-window: 1 url(s) → session 2 of 3`, i.e. the third window's session already
    /// existed when the document was routed, while the key window was still the second one). A
    /// session that registered since the last delivery is the window *this* document was delivered
    /// for; when nothing registered since then, AppKit made no window for it and the reader's own
    /// window is the answer.
    private var registrations = 0
    private var registrationsAtLastDelivery = 0

    /// The window number a held delivery is waiting for, or `nil` when nothing is held.
    ///
    /// A delivery is held when AppKit has made a window key that no session owns yet: that is the
    /// window SwiftUI is making for this very request (see ``receive(_:)``).
    private var holdUntilWindowNumber: Int?

    /// Set by ``markReady()`` (the app finished launching / became active). A session created
    /// before that point keeps its documents queued, exactly as a single-window app did.
    private var isReady = false

    /// The session whose window AppKit last made key.
    private weak var focusedSession: ReaderSession?

    /// Whether the bounded wait for a held delivery is already scheduled.
    private var heldFallbackScheduled = false

    /// The state the Settings window reads when no reader window is open. Made on demand: opening
    /// Settings on a machine whose PDFium cannot start must not fail at launch (`AppState` falls
    /// back to the mock engine).
    private var settingsStateStorage: AppState?

    public init() {}

    /// The id of the reader's `WindowGroup` in `LyraReaderApp`.
    ///
    /// `openWindow(id:)` needs it to make another *reader* window (not a Settings window). It
    /// lives here so the scene declaration and the drop path name the same string once.
    public static let readerWindowID = "reader"

    /// The window AppKit currently treats as key — the reader's window, as far as a document
    /// arriving from outside is concerned.
    ///
    /// Injectable for exactly one reason: the hold in ``receive(_:)`` covers a case no headless
    /// check can otherwise reach — a key window that belongs to no session *yet*, which is what
    /// SwiftUI's window for an open event looks like at delivery time. A check can hand the
    /// registry a window of its own (never ordered on screen), watch a delivery be held for it, and
    /// watch it land in the session that attaches to that window. The app never replaces this.
    public var keyWindow: () -> NSWindow? = { NSApp?.keyWindow }

    // MARK: - Registration

    /// How many documents are waiting for a window (the checks read this).
    public var pendingCount: Int { pending.count + pendingNewWindow.count }

    /// Whether the queued documents are waiting for a specific window to be identified, rather
    /// than for *any* window to exist. Everything that would otherwise flush the queue on the spot
    /// must leave a held delivery alone.
    private var isHoldingDelivery: Bool { holdUntilWindowNumber != nil }

    /// The window a document from outside the app belongs to: the key window, else the one that
    /// last was, else the newest.
    ///
    /// **Why the key window is asked first.** AppKit makes the window SwiftUI creates for an open
    /// event key *before* it hands the event to the delegate, so the key window is the reader's
    /// answer to "where did that document go" from the moment the request exists — measured on the
    /// real bundle, where at delivery time `NSApp.keyWindow` was already the new window while the
    /// registry's recorded focus was still the previous session.
    ///
    /// The remaining two steps cover the cases AppKit cannot answer: no key window at all (the
    /// document goes to the window the reader last used), and every window gone or not yet made
    /// (the newest session, or the `pending` queue).
    public var activeSession: ReaderSession? {
        if let keyWindow = keyWindow(),
           let session = sessions.first(where: { $0.window === keyWindow }) {
            return session
        }
        if let focusedSession, sessions.contains(where: { $0 === focusedSession }) {
            return focusedSession
        }
        return sessions.last
    }

    /// Adds a window's session. Idempotent: SwiftUI reports one window more than once.
    public func register(_ session: ReaderSession) {
        guard !sessions.contains(where: { $0 === session }) else { return }
        registrations += 1
        session.registrationOrdinal = registrations
        sessions.append(session)
        if isReady { session.opener.markReady() }
        // A window that was asked for by a drop on the sidebar (or a thumbnail's "Open in New
        // Window") is this one: its session is the next to register, and the documents that
        // asked for it go here — never into the window the reader dropped them on.
        if !pendingNewWindow.isEmpty {
            let batch = pendingNewWindow
            let page = pendingNewWindowPage
            let region = pendingNewWindowRegion
            pendingNewWindow.removeAll()
            pendingNewWindowPage = nil
            pendingNewWindowRegion = nil
            traceNewWindow(batch, to: session, page: page)
            session.opener.receive(batch, startingAt: page, revealing: region)
            return
        }
        // A held delivery belongs to a window that is not identified yet; `sessionAttached` is what
        // releases it, so registering must not race ahead and hand it to whichever session happened
        // to register first.
        guard !isHoldingDelivery else { return }
        flushPending(into: session)
    }

    /// Removes a window's session — the window closed, or this is a check's teardown.
    ///
    /// Nothing here touches another window: the remaining sessions keep their documents, tabs,
    /// scroll positions and zoom, and the reader can carry on in them.
    public func unregister(_ session: ReaderSession) {
        sessions.removeAll { $0 === session }
        if focusedSession === session { focusedSession = nil }
        guard !isHoldingDelivery, let next = activeSession else { return }
        flushPending(into: next)
    }

    /// The reader's window changed. Ignored for a session that is no longer registered.
    public func noteFocused(_ session: ReaderSession) {
        guard sessions.contains(where: { $0 === session }) else { return }
        focusedSession = session
    }

    /// The app is up: queued documents may be opened, and sessions created from now on are ready
    /// immediately. Idempotent, like ``DocumentOpenCoordinator/markReady()``.
    public func markReady() {
        isReady = true
        for session in sessions { session.opener.markReady() }
        guard !isHoldingDelivery, let session = activeSession else { return }
        flushPending(into: session)
    }

    // MARK: - Documents from the system

    /// A document request from macOS: a drop on the Dock icon, Finder's “Open With”, `open -a LyraReader`.
    ///
    /// The URLs end up in one session's coordinator, which normalizes them, refuses what it cannot
    /// open *out loud*, and opens the rest as tabs. The decision, in order:
    ///
    /// 1. **A window appeared since the last delivery** — it is the window AppKit made for this
    ///    request, and the document goes there. This is the case that has to come first: measured
    ///    on the real bundle, that window can be registered while the key window is still the
    ///    previous one, so a key-window test alone sent the document to the older window and left
    ///    the new one empty.
    /// 2. **The key window belongs to a session** — the reader already has the window this document
    ///    belongs to; it opens there.
    /// 3. **The key window belongs to nobody yet** — hold the delivery until a session attaches to
    ///    exactly that window (or the bounded turn passes).
    /// 4. **Otherwise** the focused window, else the newest.
    ///
    /// With no window at all the URLs wait in `pending`, and the first session that registers opens
    /// them (a launch *with* a document). The hold in step 3 is bounded by one main-queue turn, so a
    /// key window that is not a reader window at all (Settings, a panel) cannot swallow a delivery:
    /// SwiftUI can make the window for an open request key before AppKit delivers it while the
    /// *session* only learns its window when SwiftUI attaches the view, and both orderings have been
    /// measured on the real bundle.
    public func receive(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard !sessions.isEmpty else {
            trace(urls, to: nil)
            pending.append(contentsOf: urls)
            return
        }
        // A window that appeared since the last delivery is the one AppKit made for this document.
        let fresh = sessions.last.flatMap {
            $0.registrationOrdinal > registrationsAtLastDelivery ? $0 : nil
        }
        registrationsAtLastDelivery = registrations
        if let fresh {
            trace(urls, to: fresh)
            fresh.opener.receive(urls)
            return
        }
        // Only a running *window* makes the hold meaningful: with no attached windows at all (the
        // checks, a headless run) there is nothing to wait for, and waiting would only delay the
        // delivery the caller is about to assert on.
        if let keyWindow = keyWindow(),
           !sessions.contains(where: { $0.window === keyWindow }),
           sessions.contains(where: { $0.window != nil }) {
            trace(urls, to: nil, held: keyWindow.windowNumber)
            pending.append(contentsOf: urls)
            holdUntilWindowNumber = keyWindow.windowNumber
            scheduleHeldFallback()
            return
        }
        if let session = activeSession {
            trace(urls, to: session)
            session.opener.receive(urls)
        } else {
            trace(urls, to: nil)
            pending.append(contentsOf: urls)
        }
    }

    /// A session's view reached its window: a delivery held for that window can go through.
    ///
    /// Called by ``ReaderSession/attach(window:)`` — the moment the registry stops having to guess.
    public func sessionAttached(_ session: ReaderSession) {
        guard let held = holdUntilWindowNumber, let window = session.window,
              window.windowNumber == held else { return }
        holdUntilWindowNumber = nil
        flushPending(into: session)
    }

    /// The bounded wait for a held delivery: one main-queue turn, then whoever is active.
    ///
    /// The fallback exists so a document can never be lost to a key window that never becomes a
    /// reader window. It never fires in the measured open flow, where the window attaches during
    /// the same event.
    private func scheduleHeldFallback() {
        guard !heldFallbackScheduled else { return }
        heldFallbackScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.heldFallbackScheduled = false
                guard self.holdUntilWindowNumber != nil else { return }
                self.holdUntilWindowNumber = nil
                if let session = self.activeSession {
                    self.flushPending(into: session)
                }
            }
        }
    }

    private func flushPending(into session: ReaderSession) {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        trace(batch, to: session)
        session.opener.receive(batch)
    }

    /// Development aid: one line per new-window delivery, so a headless run can tell "the drop
    /// made a second window and opened there" from "the drop landed in the old window" without
    /// looking at pixels.
    private func traceNewWindow(_ urls: [URL], to session: ReaderSession, page: Int?) {
        let index = sessions.firstIndex { $0 === session }.map { $0 + 1 } ?? sessions.count
        let pageNote = page.map { ", page \($0 + 1)" } ?? ""
        let line = "lyra-reader-window: \(urls.count) url(s) → new window session \(index) of "
            + "\(sessions.count)\(pageNote)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// Development aid, next to the shell's other `lyra-reader-…` trace lines: one line per delivery
    /// saying *which* window the document went to, so a headless launch can tell a Dock drop that
    /// landed in the window macOS opened for it (session 2 of 2) from one that landed in an older
    /// window. Without it, routing is only visible on screen — and this is precisely the part of
    /// the multi-window behaviour that no in-process check can see.
    private func trace(_ urls: [URL], to session: ReaderSession?, held: Int? = nil) {
        let target = session.flatMap { target in sessions.firstIndex { $0 === target } }
            .map { "session \($0 + 1) of \(sessions.count)" }
            ?? (held.map { "held for window \($0)" } ?? "queued (no window)")
        let line = "lyra-reader-window: \(urls.count) url(s) → \(target)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    // MARK: - Settings

    /// The state the Settings window shows: the reader's window when there is one, so “Engine:” and
    /// the cache budget describe the window they are looking at.
    public var settingsState: AppState {
        if let active = activeSession { return active.state }
        if let settingsStateStorage { return settingsStateStorage }
        let state = AppState()
        settingsStateStorage = state
        return state
    }

    /// Adopts the `cacheBudgetMB` setting in *every* window, not just the focused one: it is one
    /// process-wide budget (ADR 0007), and a reader who raises it expects all their windows to use
    /// it. Called by the Settings window when the stepper moves.
    public func applyCacheBudgetSetting() {
        for session in sessions { session.state.applyCacheBudgetSetting() }
        settingsStateStorage?.applyCacheBudgetSetting()
    }

    /// Adopts the stored facing/gap preferences in *every* window.
    ///
    /// The layout is a reading preference, not document content: a reader who switches to
    /// facing pages in one window expects the others to follow (and the next launch to remember
    /// it). The `@AppStorage` slider already wrote the value; this is what makes existing
    /// states rebuild their geometry from it.
    public func applyReadingLayoutSetting() {
        for session in sessions { session.state.adoptStoredReadingLayoutPreferences() }
        settingsStateStorage?.adoptStoredReadingLayoutPreferences()
    }
}
