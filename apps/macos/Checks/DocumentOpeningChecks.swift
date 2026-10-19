import AppKit
import LyraReaderKit
import Foundation

extension ReaderChecks {
    // MARK: - Documents macOS hands to LyraReader (T2.12)

    /// The entry points the app was missing: a PDF dropped on the Dock icon, Finder's “Open
    /// With”, `open -a LyraReader …`, the reopen request, and a file dropped on the window canvas.
    ///
    /// The delegate methods are called directly with real file URLs — the only way to reach them
    /// without a display — and every assertion is about state a reader can also see: which
    /// document is open, how many tabs exist, and what error is on screen.
    @MainActor static func documentOpeningChecks(a: URL, b: URL) async throws {
        let directory = a.deletingLastPathComponent()

        /// Fixtures for the dangling and wrong-file cases.
        let notes = directory.appendingPathComponent("notes.txt")
        try Data("Just some notes, not a PDF.\n".utf8).write(to: notes)
        let brokenPDF = directory.appendingPathComponent("broken.pdf")
        try Data("This file claims to be a PDF by name, but has no PDF in it.\n".utf8)
            .write(to: brokenPDF)
        let folder = directory.appendingPathComponent("a-folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let missing = directory.appendingPathComponent("vanished.pdf")
        // A real PDF that does not carry the extension: the header is what makes it openable.
        let headerOnly = directory.appendingPathComponent("paper-without-extension")
        try FileManager.default.copyItem(at: a, to: headerOnly)

        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        let registry = ReaderWindowRegistry()
        let session = ReaderSession(state: state, registry: registry)
        let delegate = LyraReaderAppDelegate(registry: registry)
        let app = NSApplication.shared

        // 0. The instance SwiftUI creates at launch. `@NSApplicationDelegateAdaptor` calls
        //    `init()` through the Objective-C runtime, so a delegate that only offers
        //    `init(registry:)` traps before the first window — with no check able to see it unless
        //    this one asks for exactly that initializer. It must own no document state either:
        //    the registry starts empty, and the first *window* is what makes a session.
        let swiftUIInstance = LyraReaderAppDelegate()
        require(swiftUIInstance.registry.sessions.isEmpty && swiftUIInstance.registry.pendingCount == 0,
                "the delegate SwiftUI instantiates with init() owns an empty registry, not a document")

        // 1. A launch that arrives *with* documents: the delegate callbacks run before the app is
        //    ready, and there are two of them (macOS sends one request per document). The window
        //    exists by then (its session is registered), the app has not finished launching.
        registry.register(session)
        delegate.application(app, open: [a])
        delegate.application(app, open: [b])
        require(state.document == nil && state.tabs.isEmpty && session.opener.queuedCount == 2,
                "documents delivered before the app is ready are queued, not lost")
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification, object: app)
        )
        require(session.opener.queuedCount == 0 && state.tabs.count == 2,
                "both queued documents survive the launch")
        require(state.document?.url?.path == b.path && state.document?.pageCount == 3,
                "the last document delivered is the one on screen")
        state.selectTab(0)
        require(state.document?.url?.path == a.path && state.document?.pageCount == 1,
                "the first queued document is still open and loads its own pages")

        // 2. A document opened while the app is running (`open -a LyraReader file.pdf` again).
        let openRequests = state.openRequestCount
        delegate.application(app, open: [a])
        require(state.tabs.count == 3 && state.document?.url?.path == a.path,
                "an open request to a running app opens the document")
        require(state.openRequestCount == openRequests + 1,
                "the delegate path loads through AppState.open(url:)")

        // 3. Several documents in one delivery. One window keeps a tab each, in arrival order, with
        //    the last on screen; *which* window they land in is the registry's decision, checked in
        //    `windowIndependenceChecks`.
        delegate.application(app, open: [a, b])
        require(state.tabs.count == 5 && state.document?.url?.path == b.path,
                "each document in a plural request gets a tab; the last is on screen")
        state.selectTab(2)
        require(state.document?.url?.path == a.path && state.document?.pageCount == 1,
                "an earlier document from a plural request is still reachable")

        // 4. The reopen request (clicking the Dock icon). It must keep AppKit's default answer:
        //    answering `false` is what would make the Dock icon do nothing.
        let openDocument = state.document?.id
        require(delegate.applicationShouldHandleReopen(app, hasVisibleWindows: true),
                "the reopen request is answered with AppKit's default (true)")
        require(state.document?.id == openDocument, "a reopen request leaves the document alone")

        // 5. A URL that is not a local file is refused out loud, not ignored.
        delegate.application(app, open: [URL(string: "https://example.com/paper.pdf")!])
        require(state.document?.id == openDocument && state.lastError != nil,
                "a web URL is refused with a visible error and does not disturb the document")
        state.lastError = nil

        // 6. Dangling cases on the delegate path: a file that no longer exists, a directory, and a
        //    `.pdf` name that is not a PDF. Each reports and leaves the open document untouched.
        for (url, name) in [(missing, "missing file"), (folder, "folder"), (brokenPDF, "corrupt PDF")] {
            let before = state.document?.id
            delegate.application(app, open: [url])
            require(state.document?.id == before && state.lastError != nil,
                    "the \(name) is refused through the delegate and reported")
            state.lastError = nil
        }

        // MARK: Drop on the canvas

        let dropState = AppState(engine: try RustEngine())
        dropState.setViewportSize(CGSize(width: 700, height: 500))
        let opener = DocumentOpenCoordinator(state: dropState)
        let canvas = MetalCanvasView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        opener.connect(canvas)  // exactly the wiring PDFCanvasView gives the real window

        func dragging(_ urls: [URL]) -> CheckDraggingInfo {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("lyra-reader-checks-drop-\(UUID().uuidString)"))
            pasteboard.clearContents()
            pasteboard.writeObjects(urls.map { $0 as NSURL })
            return CheckDraggingInfo(pasteboard: pasteboard)
        }

        require(canvas.registeredDraggedTypes.contains(.fileURL),
                "the canvas is registered for dragged file URLs")

        // 7. A dropped PDF goes through the shell's open entry point, like the Dock and Finder do.
        let pdfDrag = dragging([a])
        require(canvas.draggingEntered(pdfDrag) == .copy, "a PDF drag is accepted while it hovers")
        require(opener.dropHint?.kind == .acceptable,
                "hovering a PDF shows an accept hint: \(opener.dropHint?.message ?? "none")")
        require(canvas.prepareForDragOperation(pdfDrag), "the drop is prepared")
        let dropRequests = dropState.openRequestCount
        require(canvas.performDragOperation(pdfDrag), "dropping a PDF is handled")
        require(dropState.document?.url?.path == a.path
                && dropState.openRequestCount == dropRequests + 1,
                "the drop opens through the same AppState.open(url:) entry point")
        require(dropState.tabs.count == 1, "a dropped document opens in a tab")
        require(opener.dropHint == nil, "the hover hint clears once the drop lands")

        // 8. A drag that carries no file at all is not our business: no highlight, no drop.
        let textPasteboard = NSPasteboard(name: NSPasteboard.Name("lyra-reader-checks-drop-text-\(UUID().uuidString)"))
        textPasteboard.clearContents()
        textPasteboard.setString("just some text", forType: .string)
        require(canvas.draggingEntered(CheckDraggingInfo(pasteboard: textPasteboard)).isEmpty,
                "a drag with no file behind it is not a drop target")
        require(opener.dropHint == nil, "a drag with no file behind it shows no hint")

        // 9. A non-PDF file: the drag is accepted so the refusal can be *explained*, warns while it
        //    hovers, and changes nothing on drop.
        let notesDrag = dragging([notes])
        require(canvas.draggingEntered(notesDrag) == .copy,
                "a non-PDF file drag is accepted so the refusal can be shown")
        require(opener.dropHint?.kind == .refused,
                "hovering a non-PDF warns before the drop: \(opener.dropHint?.message ?? "none")")
        let openDocumentID = dropState.document?.id
        let requestsBeforeRefusal = dropState.openRequestCount
        require(!canvas.performDragOperation(notesDrag), "a non-PDF drop is refused")
        require(dropState.document?.id == openDocumentID
                && dropState.openRequestCount == requestsBeforeRefusal,
                "a refused drop never reaches the engine and leaves the document unchanged")
        require(dropState.lastError?.contains("PDF") == true,
                "the non-PDF refusal says why: \(dropState.lastError ?? "no error")")
        require(opener.dropHint == nil, "a refused drop clears the hover hint")
        dropState.lastError = nil

        // 10. A `.pdf` name that is not a PDF: accepted by the pre-flight (PDFium keeps the last
        //     word), then refused by the engine with a visible error.
        require(canvas.performDragOperation(dragging([brokenPDF])) == false,
                "a file named .pdf that is not a PDF is refused")
        require(dropState.document?.id == openDocumentID && dropState.lastError != nil,
                "the corrupt PDF is reported and the open document is untouched")
        require(dropState.tabs.count == 1, "a failed drop adds no tab")
        dropState.lastError = nil

        // 11. A missing file and a folder are refused before the engine is even asked.
        require(!canvas.performDragOperation(dragging([missing])), "a missing file is refused")
        require(dropState.document?.id == openDocumentID
                && dropState.lastError?.contains("no longer exists") == true,
                "the missing file is reported: \(dropState.lastError ?? "no error")")
        dropState.lastError = nil
        require(!canvas.performDragOperation(dragging([folder])), "a folder is refused")
        require(dropState.document?.id == openDocumentID
                && dropState.lastError?.contains("folder") == true,
                "the folder is reported: \(dropState.lastError ?? "no error")")
        dropState.lastError = nil

        // 12. Leaving the canvas without dropping clears the hover feedback.
        _ = canvas.draggingEntered(pdfDrag)
        require(opener.dropHint != nil, "a hovering drag has a hint to clear")
        canvas.draggingExited(nil)
        require(opener.dropHint == nil, "the hint clears when the drag leaves the canvas")

        // 13. A PDF without the `.pdf` extension is still opened (the header is what counts), and
        //     the app still works after every refusal above — a rejected drop breaks nothing.
        require(canvas.performDragOperation(dragging([headerOnly])),
                "a PDF with no .pdf extension is opened by its header")
        require(dropState.document?.url?.path == headerOnly.path,
                "the header-recognised PDF is the document on screen")
        require(canvas.performDragOperation(dragging([a, b])),
                "a drop carrying several documents opens them")
        require(dropState.tabs.count == 4 && dropState.document?.url?.path == b.path,
                "each dropped document gets a tab; the last is on screen")
        require(dropState.lastError == nil, "a successful drop reports no error")

        // 14. A mixed drag opens what it can and says what it skipped.
        let mixed = DocumentOpenCoordinator.preview(of: [a, notes])
        require(mixed.kind == .acceptable && mixed.message.contains("1 of 2"),
                "a mixed drag warns about the file it will skip: \(mixed.message)")
    }
}

/// A minimal `NSDraggingInfo` for the checks.
///
/// AppKit builds the real one only during a live drag, which a headless run cannot start, so the
/// drop path is fed the one thing it reads from the drag — the pasteboard — through the real
/// protocol. Everything else is inert. Internal rather than file-private: the window-independence
/// checks drive two windows' canvases with the same fake drag.
///
/// `@preconcurrency` on the conformance: AppKit's drag protocols are usable only on the main
/// thread, which is where the checks call them from.
@MainActor
final class CheckDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var numberOfValidItemsForDrop: Int = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
