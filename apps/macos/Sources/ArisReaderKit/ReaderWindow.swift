import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Main window: toolbar + collapsible sidebar + canvas (`docs/04-ui-ux.md` §2).
///
/// The skeleton phase uses a hand-rolled `HStack` split instead of `NavigationSplitView`:
/// the latter would bring the system sidebar material and automatic collapsing, but its
/// `columnVisibility` binding adds risk in an environment without compile verification.
/// **M1 T1.10 will make the A/B decision with a runnable version**
/// (evaluated together with the scrolling approach in T1.4).
public struct ReaderWindow: View {
    @ObservedObject private var state: AppState
    /// Documents arriving at *this* window: its own coordinator, so a drop on its canvas becomes a
    /// tab here and nowhere else. Files dropped on the canvas also drive its hover hint.
    @ObservedObject private var opener: DocumentOpenCoordinator
    /// The floating reference panel of this window. Defaulted to the process-wide controller so a
    /// test or preview that only has an `AppState` still works; the app passes the session's own
    /// (see `ReaderSession`).
    private let previewPanels: ReferencePreviewPanelController

    public init(
        state: AppState,
        opener: DocumentOpenCoordinator,
        previewPanels: ReferencePreviewPanelController = .shared
    ) {
        self.state = state
        self.opener = opener
        self.previewPanels = previewPanels
    }

    public var body: some View {
        VStack(spacing: 0) {
            TabStrip(state: state)
            ReaderToolbar(state: state)
            HStack(spacing: 0) {
                if state.sidebarVisible {
                    SidebarView(state: state, opener: opener)
                        .frame(width: 250)
                    Rectangle().fill(LyraTheme.separator).frame(width: 1)
                }
                canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(LyraTheme.windowBg)
        .foregroundStyle(LyraTheme.textPrimary)
        .tint(LyraTheme.accent)
        .onAppear { state.installTerminationHandling() }
        .alert("Lyra", isPresented: Binding(
            get: { state.lastError != nil },
            set: { if !$0 { state.lastError = nil } }
        )) {
            // The way out of a sidecar that failed to load: an explicit action that moves the
            // unreadable file aside (never overwrites it) and starts a fresh one.
            if state.canRecoverUnreadableAnnotationSidecar {
                Button("Back Up Sidecar and Start Fresh") {
                    if let backup = state.recoverUnreadableAnnotationSidecar() {
                        state.revealSidecarBackupInFinder(backup)
                    }
                }
            }
            Button("OK", role: .cancel) { state.lastError = nil }
        } message: {
            Text(state.lastError ?? "")
        }
        .fileImporter(
            isPresented: $state.showFileImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    state.newTab(url: url)
                }
            case .failure(let error):
                state.lastError = String(describing: error)
            }
        }
    }

    // MARK: - Canvas

    private var canvas: some View {
        ZStack {
            PDFCanvasView(
                pages: state.canvasPages,
                scrollYPt: state.scrollYPt,
                zoom: state.zoomFactor,
                contentWidthPt: state.contentWidthPt,
                onFrame: { stats in state.updateGpuStatus(stats, label: "GPU") },
                onFailure: { message in state.reportGpuFailure(message) },
                onDeviceScale: { scale in state.setDeviceScale(scale) },
                onViewportSize: { size in state.setViewportSize(size) },
                // Precise input preserves system deltas; wheel input applies its accelerated
                // distance immediately, with no queued motion after the wheel stops.
                onScroll: { delta in state.scroll(byScreenPoints: delta) },
                onScrollStep: { delta in state.scrollByWheelStep(delta) },
                // Keyboard paging keeps its animation to the requested destination.
                onKeyboardStep: { delta in state.scrollByKeyboardStep(delta) },
                // Ctrl+scroll and ⌘+scroll zoom instead of scrolling (docs/04-ui-ux.md §3). Ctrl
                // is the binding the request asked for; ⌘ is the documented convention and the
                // fallback when macOS Accessibility zoom has taken Ctrl over. Pinch works in
                // either case because it is not a scroll gesture at all.
                onZoomScroll: { delta, anchorViewY in
                    state.zoomByScroll(delta: delta, anchorViewY: anchorViewY)
                },
                onMagnify: { magnification, anchorViewY in
                    state.zoomByPinch(magnification, anchorViewY: anchorViewY)
                },
                onPointerDown: { point in state.beginSelection(at: point) },
                onPointerDragged: { point in state.extendSelection(to: point) },
                onPointerUp: { point, wasClick in
                    state.endPointerInteraction(at: point, wasClick: wasClick)
                },
                onCopy: { state.copySelection() },
                onUndo: { state.undo() },
                onRedo: { state.redo() },
                interactionSnapshot: { (state.canvasPages, state.scrollYPt, state.zoomFactor) },
                fileDrop: opener,
                // A right-click is a command surface on the page: copy, highlight, note, follow
                // the link under the pointer, or stage a page command. The items are built from
                // the reader's state (`CanvasContextMenu`), so no item is shown dead.
                onContextMenu: { point in
                    CanvasContextMenu.menu(state: state, at: point) {
                        ReaderWindow.promptForNote()
                    }
                }
            )
            .background(ReferencePreviewHost(state: state, panels: previewPanels))
            HStack { Spacer(); ScrollIndicator(state: state) }

            if state.document == nil {
                LyraTheme.emptyBg
                emptyState
            }

            if state.pageEditSessionActive {
                VStack {
                    pageEditBanner
                    Spacer()
                }
                .padding(.top, 12)
            }

            VStack {
                Spacer()
                pageHUD
                    .padding(.bottom, 16)
            }

            DocumentNoteOverlay(state: state)

            if let hint = opener.dropHint {
                FileDropOverlay(hint: hint)
            }
        }
        .animation(.easeOut(duration: 0.12), value: opener.dropHint)
    }

    /// The one place the interface states, without qualification, that the file on disk is not
    /// what is on screen. It stays visible for the whole staged session, not just after an action.
    private var pageEditBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(LyraTheme.warningFg)
            VStack(alignment: .leading, spacing: 1) {
                Text("Page changes pending")
                    .font(.callout.weight(.semibold))
                Text(
                    [state.pageEditPendingSummary, state.pageEditLastAction]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Divider().frame(height: 24)
            Button("Undo") { state.undoPageEdit() }
                .disabled(!state.canUndoPageEdit)
            Button("Redo") { state.redoPageEdit() }
                .disabled(!state.canRedoPageEdit)
            Button("Apply to Original…") {
                state.presentReplaceOriginalWithPageEditsConfirmation()
            }
            .disabled(!state.canApplyPageEdits)
            Button("Save Copy…") { state.presentSavePageEditsCopyPanel() }
                .disabled(!state.canApplyPageEdits)
            Button("Discard…") { state.presentDiscardPageEditsConfirmation() }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(LyraTheme.raisedBg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(LyraTheme.warningFg.opacity(0.5), lineWidth: 1)
        )
        .shadow(radius: 3, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Page changes pending. The file on disk is unchanged.")
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Open a paper to start reading")
                .font(.title3)
            Text("⌘O to open a file, or drop one anywhere on the page")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open PDF…") {
                state.showFileImporter = true
            }
            .controlSize(.large)
        }
        .padding(40)
    }

    /// The floating preview lives in its own panel (`ReferencePreviewPanelController`): it has to
    /// be movable and resizable independently of this window, which an overlay cannot be. The
    /// zero-size host below only tells the controller where the canvas is.

    private var pageHUD: some View {
        Text(state.pageLabel)
            .font(.callout)
            .monospacedDigit()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(LyraTheme.raisedBg, in: Capsule())
            .opacity(state.document == nil ? 0 : 1)
    }

    /// Asks for the text of a note attached to the current selection.
    ///
    /// This is the context menu's only piece of UI: the note itself is stored by
    /// ``AppState/addNoteFromSelection(note:)``, exactly like a highlight added from the toolbar,
    /// so the menu item is a prompt in front of an existing command and not a second annotation
    /// path. An empty note is not stored: a highlight with no note is what "Highlight Selection"
    /// already does.
    @MainActor
    static func promptForNote() -> String? {
        let alert = NSAlert()
        alert.messageText = "Add a Note"
        alert.informativeText =
            "The note is attached to the selected text and can be edited in the Annotations sidebar."
        alert.addButton(withTitle: "Add Note")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Note"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// Feedback for a file being dragged over the canvas (T2.12): a tinted border around the drop
/// area plus one line saying what letting go would do — including *not* opening the file, which
/// is why a refusal is drawn in the warning colour rather than simply swallowed.
///
/// Only plain shapes and colours: the overlay must stay inside SwiftUI's drawing layers, because
/// an AppKit view placed here would sit above the canvas and take the drop away from it.
/// `allowsHitTesting(false)` keeps the mouse paths (selection, scrolling) untouched as well.
struct FileDropOverlay: View {
    let hint: FileDropPreview

    private var tint: Color {
        hint.kind == .acceptable ? LyraTheme.accent : LyraTheme.warningFg
    }

    var body: some View {
        ZStack {
            tint.opacity(0.10)
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(tint, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                .padding(10)
            VStack(spacing: 8) {
                Image(systemName: hint.kind == .acceptable
                    ? "arrow.down.doc"
                    : "exclamationmark.triangle")
                    .font(.system(size: 34, weight: .light))
                Text(hint.message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
            .background(LyraTheme.raisedBg,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.5))
            )
            .foregroundStyle(tint)
            .padding(40)
        }
        .allowsHitTesting(false)
    }
}
