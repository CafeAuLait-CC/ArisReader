import AppKit
import Foundation

/// What the shell would do with the files a drag is carrying, decided while the drag hovers.
///
/// The canvas asks for this when a drag enters it and draws it, so the reader learns whether the
/// file will open *before* letting go of it.
public struct FileDropPreview: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// At least one file in the drag can be opened; letting go opens those files.
        case acceptable
        /// Nothing in this drag can be opened; letting go reports why.
        case refused
    }

    public let kind: Kind
    /// One line for the overlay. Never empty: a refusal that says nothing is the bug this
    /// feature exists to fix.
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

/// Where a drop would put the document. The same files mean different things depending on the
/// target: the canvas opens a tab in *this* window, the sidebar opens a *new* window. Keeping this
/// beside the preview is what makes the highlight say which one the reader will get.
public enum DropDestination: Equatable, Sendable {
    case currentWindow
    case newWindow
}

/// Why a file cannot be opened, decided without touching the engine.
///
/// These are the cases a reader hits by dragging the wrong thing: a folder, a text file, a file
/// that has been moved or trashed since the drag started. The engine keeps the last word on
/// whether a PDF really parses; this only filters out what it cannot possibly open, so that the
/// refusal arrives with a sentence a person can read.
public enum FileOpenRefusal: Equatable, Sendable {
    /// Not a local file at all (a web URL, a promised drag item with no file behind it).
    case notAFile
    case vanished
    case isDirectory
    case unreadable
    case notPDF

    public func message(for url: URL) -> String {
        let name = url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent
        switch self {
        case .notAFile:
            return "LyraReader can only open documents stored on this Mac."
        case .vanished:
            return "“\(name)” no longer exists, so there is nothing to open."
        case .isDirectory:
            return "“\(name)” is a folder. LyraReader opens PDF files."
        case .unreadable:
            return "“\(name)” can’t be read. Check its permissions and try again."
        case .notPDF:
            return "“\(name)” is not a PDF, so LyraReader can't open it."
        }
    }
}

/// Cheap, engine-free checks on a file the reader asked to open.
public enum FileOpenPolicy {
    /// How much of the head of a file is searched for `%PDF-`, in bytes.
    ///
    /// The PDF specification allows the header to sit behind up to 1024 bytes of leading junk
    /// (PDF 1.7 §7.5.2) and PDFium applies the same rule, so this pre-flight can never refuse a
    /// file the engine would have opened.
    public static let pdfHeaderScanLimit = 1024

    /// Why `url` cannot be opened, or `nil` when the engine should be given the file.
    ///
    /// A `.pdf` name is enough to hand the file over even when the header is missing: PDFium
    /// then produces the authoritative "this is not a PDF" error, which is reported to the
    /// reader. The reverse is also allowed — a file with no `.pdf` extension is accepted when it
    /// starts with the PDF header.
    public static func refusal(for url: URL, fileManager: FileManager = .default) -> FileOpenRefusal? {
        guard url.isFileURL else { return .notAFile }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .vanished
        }
        if isDirectory.boolValue { return .isDirectory }
        guard fileManager.isReadableFile(atPath: url.path) else { return .unreadable }
        if url.pathExtension.lowercased() == "pdf" { return nil }
        return hasPDFHeader(url) ? nil : .notPDF
    }

    /// Whether the file starts with the PDF header (within ``pdfHeaderScanLimit`` bytes).
    public static func hasPDFHeader(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: pdfHeaderScanLimit) else { return false }
        return head.range(of: Data("%PDF-".utf8)) != nil
    }
}

/// The one place where documents arriving at *one window* become open tabs: a PDF opened from
/// outside the app (routed here by ``ReaderWindowRegistry``) and files dropped on the canvas.
///
/// It is scoped to a single window's session (``ReaderSession``), and that is what makes the
/// reader's tabs independent: the coordinator's `state` is that window's `AppState`, so a tab it
/// adds exists in that window and nowhere else. It used to be one object for the whole app — the
/// delegate owned it, and every window was handed the same one — which is why a drop on either
/// window showed up in both.
///
/// It is a separate object rather than more `AppState` for two reasons:
///
/// * **An open request can arrive before the window exists.** macOS delivers a launch-with-a-
///   document before `applicationDidFinishLaunching`; ``ReaderWindowRegistry`` holds the URLs
///   until a window registers, and if that window's session arrives before the app is ready this
///   coordinator queues them and flushes them at ``markReady()``. Opening a document needs only
///   the engine and `AppState` — never a window — so nothing is lost.
/// * **The drop path needs a hover state.** The canvas asks for a preview while the drag is
///   still in the air; that preview lives here so the window can draw it.
///
/// **Several documents**: each one becomes its own tab, in arrival order, and the last one
/// delivered is the one on screen. That is what one window can show — it has tabs
/// (`AppState.OpenTab`, the tab strip, per-tab scroll restoration) — and several documents
/// delivered in one event stay together in the window that received them. “Last one wins” would
/// be strictly worse: the reader who dropped five files would silently lose four of them.
@MainActor
public final class DocumentOpenCoordinator: ObservableObject {
    public let state: AppState

    /// Who owns the windows, when this coordinator belongs to one of them. `nil` in the checks
    /// that only exercise the single-window open path; the app always supplies it through
    /// ``ReaderSession``.
    private weak var registry: ReaderWindowRegistry?

    /// What the canvas should show while a drag hovers over it (`nil` when no drag is over us).
    @Published public private(set) var dropHint: FileDropPreview?

    /// What the sidebar should show while a drag hovers over it, where letting go opens a **new
    /// window** rather than a tab in this one.
    @Published public private(set) var newWindowDropHint: FileDropPreview?

    /// URLs delivered before the app was ready, in arrival order.
    private var queued: [URL] = []
    /// The page a queued delivery should show once it opens (a thumbnail's "Open in New Window").
    private var queuedStartPage: Int?
    /// The page-local rectangle a queued delivery should scroll to. Carried next to the page so a
    /// preview's "open in a new window" arrives at the cited entry or figure, not only at its page.
    private var queuedStartRegion: CGRect?
    /// Set by ``markReady()``; until then, deliveries are queued rather than opened.
    private var isReady = false

    public init(state: AppState, registry: ReaderWindowRegistry? = nil) {
        self.state = state
        self.registry = registry
    }

    // MARK: - System open requests

    /// Opens everything that is queued and lets later deliveries through. Idempotent, so it can
    /// be called from both `applicationDidFinishLaunching` and the first activation.
    public func markReady() {
        isReady = true
        flushQueue()
    }

    /// How many URLs are still waiting for the app to be ready (the checks read this).
    public var queuedCount: Int { queued.count }

    /// A document request from the system: `application(_:open:)`, `openFile(s)`, or a drop on
    /// the Dock icon. Non-file URLs are refused out loud instead of being ignored.
    ///
    /// `startingAt` is for a request that also names a page — a thumbnail's “Open in New Window”.
    /// It is kept with the queued batch, so a delivery that waits for its window still lands on
    /// the page the reader asked for.
    public func receive(_ urls: [URL], startingAt page: Int? = nil, revealing region: CGRect? = nil) {
        guard !urls.isEmpty else { return }
        var files: [URL] = []
        for url in urls {
            guard let file = Self.normalizedFileURL(url) else {
                report(FileOpenRefusal.notAFile.message(for: url))
                continue
            }
            files.append(file)
        }
        guard !files.isEmpty else { return }
        if let page {
            // A new page target replaces both parts of the old target; otherwise a region from a
            // previous queued request could be applied to a page it does not belong to.
            queuedStartPage = page
            queuedStartRegion = region
        } else if let region {
            queuedStartRegion = region
        }
        queued.append(contentsOf: files)
        flushQueue()
    }

    private func flushQueue() {
        guard isReady, !queued.isEmpty else { return }
        let batch = queued
        let startPage = queuedStartPage
        let startRegion = queuedStartRegion
        queued.removeAll()
        queuedStartPage = nil
        queuedStartRegion = nil
        let opened = openDocuments(batch)
        // Only after a document actually opened: jumping a page in whatever was already on screen
        // would be a side effect the reader never asked for.
        if opened > 0, let startPage, startPage >= 0 {
            state.reveal(page: startPage, region: startRegion)
        }
    }

    /// Opens documents — one tab each — and reports every one that failed. This is the shared
    /// funnel behind the system entry points and the drop path; each file goes through
    /// `AppState.openDocumentInTab`, which in turn is `AppState.open(url:)` plus a tab.
    @discardableResult
    public func openDocuments(_ urls: [URL]) -> Int {
        var opened = 0
        for url in urls {
            if let refusal = FileOpenPolicy.refusal(for: url) {
                report(refusal.message(for: url))
                continue
            }
            if state.openDocumentInTab(url) {
                opened += 1
            } else {
                let name = url.lastPathComponent
                let detail = state.lastError.map { " \($0)" } ?? ""
                report("Couldn’t open “\(name)”.\(detail)")
            }
        }
        trace(urls: urls, opened: opened)
        return opened
    }

    // MARK: - Drag and drop on the canvas

    /// Called while a drag hovers: what the canvas should show, and what letting go would do.
    @discardableResult
    public func previewDrop(_ urls: [URL]) -> FileDropPreview {
        let preview = Self.preview(of: urls, destination: .currentWindow)
        // Publishing only a change keeps the window from redrawing on every mouse move AppKit
        // reports during one drag.
        if dropHint != preview { dropHint = preview }
        return preview
    }

    /// The drag left the canvas or was cancelled: stop showing the hint.
    public func endDropPreview() {
        dropHint = nil
    }

    /// The reader let go of the drag. Returns whether any document was opened; a refusal has
    /// already been reported by then, so the reader always sees what happened.
    @discardableResult
    public func acceptDrop(_ urls: [URL]) -> Bool {
        dropHint = nil
        guard !urls.isEmpty else { return false }
        let opened = openDocuments(urls)
        if opened == 0, state.lastError == nil {
            // Defensive: every refusal above reports, but a drop may never be silent.
            report("Nothing was opened. LyraReader needs a PDF file.")
        }
        return opened > 0
    }

    // MARK: - Drag and drop on the sidebar (new window)

    /// Called while a drag hovers over the sidebar: it will open in a **new window**.
    ///
    /// The preview is built by the same policy the canvas uses, with the destination in the
    /// wording. A drag the app would refuse shows the refusal it will produce, never an invitation
    /// to drop.
    @discardableResult
    public func previewNewWindowDrop(_ urls: [URL]) -> FileDropPreview {
        let preview = Self.preview(of: urls, destination: .newWindow)
        if newWindowDropHint != preview { newWindowDropHint = preview }
        return preview
    }

    /// The drag left the sidebar (or was cancelled): cancel the new-window highlight.
    public func endNewWindowDropPreview() {
        newWindowDropHint = nil
    }

    /// The reader let go over the sidebar: open the files in a new window, through the window
    /// registry. Returns whether a new window was asked for; every refusal has been reported.
    @discardableResult
    public func acceptNewWindowDrop(_ urls: [URL]) -> Bool {
        newWindowDropHint = nil
        guard !urls.isEmpty else {
            report("Nothing was opened. LyraReader needs a PDF file.")
            return false
        }
        return openInNewWindow(urls)
    }

    /// Opens documents in a **new** reader window, leaving this one exactly as it is.
    ///
    /// This is the sidebar's drop path and the thumbnail menu's “Open in New Window”. The files
    /// are validated here (the same `FileOpenPolicy` the canvas uses), then handed to
    /// ``ReaderWindowRegistry`` — the app-wide machinery that owns windows — which asks SwiftUI
    /// for one and delivers the URLs to the session that registers for it. Validation happens
    /// before the window is requested so a drag of the wrong file produces a sentence, not an
    /// empty window.
    ///
    /// `page` and `revealing` are the thumbnail action's target: the new window opens the same
    /// document and then moves to the page and the page-local rectangle the thumbnail points at.
    @discardableResult
    public func openInNewWindow(_ urls: [URL], page: Int? = nil, revealing region: CGRect? = nil) -> Bool {
        let files = urls.compactMap(Self.normalizedFileURL)
        guard !files.isEmpty else {
            report(FileOpenRefusal.notAFile.message(for: urls.first ?? URL(fileURLWithPath: "/")))
            return false
        }
        var openable: [URL] = []
        for url in files {
            if let refusal = FileOpenPolicy.refusal(for: url) {
                report(refusal.message(for: url))
            } else {
                openable.append(url)
            }
        }
        guard !openable.isEmpty else { return false }
        guard let registry, registry.canOpenNewWindow else {
            report("LyraReader can’t open a new window right now, so nothing was opened.")
            return false
        }
        guard registry.requestNewWindow(opening: openable, page: page, reveal: region) else {
            report("LyraReader can’t open a new window right now, so nothing was opened.")
            return false
        }
        state.statusMessage = openable.count == 1
            ? "Opening “\(openable[0].lastPathComponent)” in a new window"
            : "Opening \(openable.count) documents in a new window"
        traceNewWindowRequest(openable, page: page)
        return true
    }

    /// Whether a drop on the sidebar can actually create a window. The sidebar omits “Open in New
    /// Window” when it cannot, rather than offering a command that reports failure.
    public var canOpenInNewWindow: Bool { registry?.canOpenNewWindow == true }

    /// Connects a canvas so drags on it go through this coordinator. The window and the checks
    /// call the same method, so what the checks exercise is the wiring the app runs.
    public func connect(_ canvas: MetalCanvasView) {
        canvas.onFileDragEntered = { [weak self] urls in self?.previewDrop(urls) }
        canvas.onFileDragExited = { [weak self] in self?.endDropPreview() }
        canvas.onFileDrop = { [weak self] urls in self?.acceptDrop(urls) ?? false }
    }

    /// The hover hint for a set of dragged URLs: one line, saying either what will open or why
    /// nothing will, and — when the destination is the sidebar — that it opens a new window.
    public static func preview(
        of urls: [URL],
        destination: DropDestination = .currentWindow
    ) -> FileDropPreview {
        let files = urls.compactMap(normalizedFileURL)
        guard !files.isEmpty else {
            return FileDropPreview(
                kind: .refused,
                message: "Nothing to open here — drag a PDF file onto the window."
            )
        }
        let refusals = files.compactMap { url in
            FileOpenPolicy.refusal(for: url).map { (url, $0) }
        }
        let openable = files.count - refusals.count
        let destinationText = destination == .newWindow ? " in a new window" : " here"
        if openable == 0, let (url, refusal) = refusals.first {
            return FileDropPreview(kind: .refused, message: refusal.message(for: url))
        }
        if let (url, refusal) = refusals.first {
            return FileDropPreview(
                kind: .acceptable,
                message: "Drop to open \(openable) of \(files.count) files\(destinationText) — "
                    + refusal.message(for: url)
            )
        }
        if files.count == 1 {
            return FileDropPreview(
                kind: .acceptable,
                message: "Drop to open “\(files[0].lastPathComponent)”\(destinationText)"
            )
        }
        return FileDropPreview(
            kind: .acceptable,
            message: "Drop to open \(files.count) documents\(destinationText)"
        )
    }

    /// A file URL reduced to a plain, standardised path, or `nil` for anything that is not a
    /// local file (a web URL, a promise with no file behind it).
    public static func normalizedFileURL(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        return URL(fileURLWithPath: url.path).standardizedFileURL
    }

    // MARK: - Reporting

    /// Reports a refusal the way the shell already reports failures: the status line and the
    /// alert both carry it, and neither path returns without saying something.
    private func report(_ message: String) {
        state.statusMessage = message
        state.lastError = message
    }

    /// Development aid, next to the shell's other `lyra-reader-…` trace lines: one line per delivery, so
    /// a headless run can see what macOS handed over even though it cannot show the window.
    private func trace(urls: [URL], opened: Int) {
        let line = "lyra-reader-open: \(urls.count) url(s) → \(opened) opened, \(state.tabs.count) tab(s)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// Development aid for the sidebar drop: says a new window was asked for, before the window
    /// exists. The registry's own `lyra-reader-window:` line then says which session received it.
    private func traceNewWindowRequest(_ urls: [URL], page: Int?) {
        let pageNote = page.map { ", page \($0 + 1)" } ?? ""
        let line = "lyra-reader-drop: \(urls.count) url(s) → new window\(pageNote)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

/// Receives the documents macOS hands to LyraReader, and routes each one to a window.
///
/// The app had no `NSApplicationDelegate` at all before this: a PDF dropped on the Dock icon,
/// opened through Finder's “Open With”, or passed to `open -a LyraReader` started the process and then
/// did nothing with the file. SwiftUI installs this object as `NSApp.delegate`
/// (`@NSApplicationDelegateAdaptor`), which is where AppKit delivers those requests.
///
/// **The delegate owns no document state.** It used to own the app's single `AppState` — on the
/// argument that open requests can arrive before a window exists — and that is exactly what made
/// every window show the same tabs: the scene handed `delegate.state` to each of them
/// (`LyraReaderApp.swift`). What a request needs is somewhere to *wait*, not somewhere to live, so
/// the delegate owns a ``ReaderWindowRegistry`` instead: it queues URLs until a window exists and
/// then hands them to that window's own session. The reader's documents, tabs, scroll positions
/// and zoom live in ``ReaderSession``, one per window.
///
/// Main-actor isolated, like every other part of the shell: the delegate methods arrive on the
/// main thread and the registry they touch is `@MainActor`.
@MainActor
public final class LyraReaderAppDelegate: NSObject, NSApplicationDelegate {
    /// The open windows and the delivery point for documents that arrive from outside the app.
    public let registry: ReaderWindowRegistry

    /// The initializer SwiftUI itself calls. `@NSApplicationDelegateAdaptor` instantiates the
    /// delegate through `init()` at launch, so this must exist: without it the app traps before
    /// the first window (`Use of unimplemented initializer 'init()'`).
    ///
    /// It builds only the registry: no engine, no document, no window state. The first window's
    /// session is what makes an engine, and a launch that arrives with a document waits for it.
    public override init() {
        registry = ReaderWindowRegistry()
        super.init()
    }

    /// `registry` is injectable so the checks can drive the delegate with sessions they hold. This
    /// is a separate initializer rather than a default argument on `init()`, which SwiftUI cannot
    /// reach through the Objective-C runtime (see above).
    public init(registry: ReaderWindowRegistry) {
        self.registry = registry
        super.init()
    }

    // MARK: - Documents from the system

    /// The modern entry point: a drop on the Dock icon, Finder's “Open With”, `open -a LyraReader …`
    /// and the reopen Apple event all arrive here, sometimes with several documents at once.
    ///
    /// AppKit calls this *instead of* `openFile:`/`openFiles:` when the delegate implements it
    /// (NSApplicationDelegate); the singular forms are kept below for older senders.
    public func application(_ application: NSApplication, open urls: [URL]) {
        registry.receive(urls)
    }

    public func application(_ sender: NSApplication, openFiles filenames: [String]) {
        registry.receive(filenames.map { URL(fileURLWithPath: $0) })
    }

    public func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        registry.receive([URL(fileURLWithPath: filename)])
        return true
    }

    // MARK: - Launch and reopen

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // A launch that arrived *with* a document: those requests were queued, and they are
        // opened here, in order, in the first window that exists.
        registry.markReady()
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        // Safety net for a launch path that never reaches `didFinishLaunching` (a delegate
        // installed late, or a scene that activates first): the queue drains on first activation.
        registry.markReady()
    }

    /// Clicking the Dock icon with nothing on screen is the “reopen” request.
    ///
    /// The answer stays AppKit's default (`true`) so SwiftUI keeps restoring its own window —
    /// answering `false` is what turns the Dock icon into a no-op. What this adds is bringing
    /// back a window that still exists but is not on screen.
    public func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            sender.activate(ignoringOtherApps: true)
            sender.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

