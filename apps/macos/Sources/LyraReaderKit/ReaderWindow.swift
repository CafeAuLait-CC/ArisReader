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
    @ObservedObject private var appearance = ReadingAppearanceStore.shared
    /// Documents arriving at *this* window: its own coordinator, so a drop on its canvas becomes a
    /// tab here and nowhere else. Files dropped on the canvas also drive its hover hint.
    @ObservedObject private var opener: DocumentOpenCoordinator
    /// The floating reference panel of this window. Defaulted to the process-wide controller so a
    /// test or preview that only has an `AppState` still works; the app passes the session's own
    /// (see `ReaderSession`).
    private let previewPanels: ReferencePreviewPanelController
    private let integratesTitlebar: Bool
    /// Tracked so a toggle made while the window edge is being dragged changes layout at once
    /// instead of animating against the pointer (see ``WindowLiveResizeReporter``).
    @State private var isLiveResizing = false

    public init(
        state: AppState,
        opener: DocumentOpenCoordinator,
        previewPanels: ReferencePreviewPanelController = .shared,
        integratesTitlebar: Bool = false
    ) {
        self.state = state
        self.opener = opener
        self.previewPanels = previewPanels
        self.integratesTitlebar = integratesTitlebar
    }

    public var body: some View {
        VStack(spacing: 0) {
            TabStrip(state: state)
                .padding(.leading, integratesTitlebar ? TabRowLayout.tabStripLeadingInset : 0)
                .background(LyraReaderTheme.tabbarBg)
            ReaderToolbar(state: state)
            ZStack {
                HStack(spacing: 0) {
                    // A sliding drawer, not a conditional: the panel keeps its content width
                    // while the frame around it closes, so the canvas gets the freed width frame
                    // by frame and the document's vertical position never changes.
                    ReaderSidebarTransition(isVisible: state.sidebarVisible && state.document != nil) {
                        SidebarView(state: state, opener: opener)
                    }
                    .accessibilityHidden(state.document == nil || !state.sidebarVisible)
                    canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if state.searchSidebarVisible && state.document != nil {
                        SearchResultSidebar(state: state).frame(width: ReaderChrome.sidebarTotalWidthPt)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                // The animation belongs to the row, not to the sidebar view: it is this
                // HStack's layout that must interpolate, so the canvas width moves with the
                // panel instead of jumping to the final width on the first frame.
                .animation(sidebarAnimation, value: state.sidebarVisible)
                .animation(sidebarAnimation, value: state.searchSidebarVisible)
                .opacity(state.pageOverviewVisible ? 0 : 1)
                .allowsHitTesting(!state.pageOverviewVisible)
                .accessibilityHidden(state.pageOverviewVisible)
                if state.pageOverviewVisible, state.document != nil {
                    SidebarView(state: state, opener: opener, pageOverview: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // An overlay, not a ZStack child: it takes its own height at the top and can never
            // participate in (or be centred by) the content's layout.
            .overlay(alignment: .top) { secondaryToolbarLayer }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(LyraReaderTheme.windowBg)
        .background(WindowLiveResizeReporter { isLiveResizing = $0 })
        .foregroundStyle(LyraReaderTheme.textPrimary)
        .tint(LyraReaderTheme.accent)
        .preferredColorScheme(appearance.mode.colorScheme)
        .sheet(isPresented: $state.showDocumentInformation) { DocumentInformationView(state: state) }
        .onAppear { state.installTerminationHandling() }
        .onChange(of: activeDocumentURL, initial: true) { _, url in
            guard AppState.recordsRecentDocuments, let url else { return }
            RecentDocumentStore.shared.record(url)
            if let cover = state.thumbnails[0] { RecentDocumentStore.shared.saveCover(cover, for: url) }
        }
        .onChange(of: state.thumbnails[0]?.generation) { _, _ in
            guard AppState.recordsRecentDocuments, let url = activeDocumentURL,
                  let cover = state.thumbnails[0] else { return }
            RecentDocumentStore.shared.saveCover(cover, for: url)
        }
        .onChange(of: state.document?.url) { _, url in
            if url == nil { state.pageOverviewVisible = false }
        }
        .alert("LyraReader", isPresented: Binding(
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

    private var activeDocumentURL: URL? {
        guard state.document != nil, let index = state.activeTabIndex, state.tabs.indices.contains(index) else { return nil }
        return state.tabs[index].url
    }

    // MARK: - Canvas

    private var canvas: some View {
        ZStack {
            PDFCanvasView(
                pages: state.canvasPages,
                scrollYPt: state.scrollYPt,
                zoom: state.zoomFactor,
                contentWidthPt: state.contentWidthPt,
                paperAppearance: appearance.mode,
                annotationMarks: state.canvasAnnotationMarks,
                annotationPageFrames: state.canvasPageFrames,
                redactionMarks: state.pendingRedactionMarks,
                annotationTool: state.annotationTool,
                annotationColor: state.annotationStrokeColor,
                annotationStrokeWidth: AppState.defaultAnnotationStrokeWidth,
                onAnnotationDraft: { draft in
                    if draft.kind == .textBox {
                        _ = state.addTextBox(page: draft.page,
                                             rect: draft.shapeRect ?? .zero)
                    } else {
                        _ = state.addGeometryAnnotation(
                            kind: draft.kind,
                            page: draft.page,
                            inkPaths: draft.inkPaths,
                            shapeRect: draft.shapeRect,
                            lineStart: draft.lineStart,
                            lineEnd: draft.lineEnd
                        )
                    }
                },
                onRedactionDraft: { page, rect in
                    state.addPendingRedaction(page: page, rect: rect)
                },
                // The eraser's mode owns the pointer, but all of its geometry and undo live in
                // AppState like every other edit. Hover drives the pre-erase halo only.
                onEraseGestureBegan: { point in
                    state.beginEraserGesture(atContentPoint: point)
                },
                onEraseGestureDragged: { previous, point in
                    state.extendEraserGesture(fromContentPoint: previous, toContentPoint: point)
                },
                onEraseGestureEnded: { state.endEraserGesture() },
                onEraserHover: { point in
                    state.updateEraserHover(atContentPoint: point)
                },
                onDeleteAnnotation: { state.deleteSelectedAnnotation() },
                onPlaceStickyNote: { point in state.placeOrOpenStickyNote(atContentPoint: point) },
                onAnnotationDoubleClick: { point in
                    state.beginEditingTextBox(atContentPoint: point)
                },
                onPlaceTextBox: { point in
                    state.placeOrOpenTextBox(atContentPoint: point)
                },
                onPlaceStamp: { point in state.placeStamp(atContentPoint: point) },
                onPlaceSignature: { point in state.placeSignature(atContentPoint: point) },
                // Escape leaves the sticky markup mode or the eraser. It is consumed only when a
                // mode was active; the canvas keeps its existing Escape handling for a live draft.
                onCancelTool: { state.cancelActiveAnnotationTool() || state.cancelFormTool() },
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
                    CanvasContextMenu.menu(state: state, at: point)
                }
            )
            .background(ReferencePreviewHost(state: state, panels: previewPanels))
            HStack { Spacer(); ScrollIndicator(state: state) }

            if state.document == nil {
                LyraReaderTheme.emptyBg
                emptyState
            }

            // A tab whose document was evicted by the keep-limit reloads in the background of
            // this overlay. It covers the canvas only until the first page raster is ready; the
            // tab's saved scroll offset has already been applied, so the page does not jump.
            if state.isRestoringDocument, let document = state.document {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reopening \(document.title)…")
                        .font(.system(size: 12))
                        .foregroundStyle(LyraReaderTheme.textSecondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(LyraReaderTheme.panelBg,
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(LyraReaderTheme.separator, lineWidth: 0.5))
                .accessibilityLabel("Reopening \(document.title)")
            }

            if state.isReadOnlyDocument || state.pageEditSessionActive
                || state.formHasPendingChanges
                || state.hasPendingInkErasure || state.hasPendingFileDeletions
                || !state.pendingRedactions.isEmpty
                || state.markSelectionRefusalNotice != nil {
                VStack(spacing: 8) {
                    if state.isReadOnlyDocument { readOnlyBanner }
                    if !state.pendingRedactions.isEmpty { redactionBanner }
                    if state.pageEditSessionActive { pageEditBanner }
                    if state.formHasPendingChanges { formBanner }
                    if state.markSelectionRefusalNotice != nil {
                        annotationRefusalBanner
                    }
                    if state.hasPendingInkErasure || state.hasPendingFileDeletions {
                        eraserPendingBanner
                    }
                    Spacer()
                }
                .padding(.top, 12)
            }

            VStack {
                Spacer()
                pageHUD
                    .padding(.bottom, 16)
            }

            FormOverlay(state: state)
            DocumentNoteOverlay(state: state)
            PlacedTextEditorOverlay(state: state)

            if let hint = opener.dropHint {
                FileDropOverlay(hint: hint)
            }
        }
        .animation(.easeOut(duration: 0.12), value: opener.dropHint)
    }

    // MARK: - Secondary toolbar row

    /// The contextual row (annotation tools or page overview) drawn over the content.
    ///
    /// It is a sibling of the content, not a row inside the `VStack` above it, so its height never
    /// participates in the canvas's layout: showing it cannot push the document down, and the
    /// canvas frame and page position are identical before, during and after the reveal.
    ///
    /// While the sidebar is open the row starts at the sidebar's width and spans only the canvas,
    /// so it never covers the sidebar's tab picker. Page overview draws its grid over the sidebar,
    /// so there the row spans the full content area like the grid does. The inset uses the
    /// sidebar's target width rather than its animated width, which keeps the row's own contents
    /// from reflowing on every frame if the sidebar is toggled while the row is open.
    private var secondaryToolbarLayer: some View {
        let inset = secondaryToolbarInset
        // Top alignment matters while the row is only partly revealed: a centred HStack would
        // grow the row from its middle instead of down from the toolbar's edge.
        return HStack(alignment: .top, spacing: 0) {
            if inset > 0 {
                // Fixed height, or the flexible colour would stretch the overlay HStack to the
                // full content height and centre the row vertically instead of top-aligning it.
                Color.clear
                    .frame(width: inset, height: ReaderChrome.secondaryToolbarHeightPt)
                    .allowsHitTesting(false)
            }
            ReaderSecondaryToolbarTransition(isVisible: secondaryToolbarVisible) {
                ReaderSecondaryToolbar(state: state)
            }
        }
        // Same rule as the sidebar: the animation has to own the layout that changes.
        .padding(.trailing, state.searchSidebarVisible && !state.pageOverviewVisible ? ReaderChrome.sidebarTotalWidthPt : 0)
        .animation(secondaryRowAnimation, value: secondaryToolbarVisible)
    }

    /// A toggle made while the window edge is being dragged changes layout without animating:
    /// animating against the pointer would make the layout chase two sizes at once.
    private var sidebarAnimation: Animation? {
        isLiveResizing ? nil : ReaderMotion.sidebarAnimation
    }

    private var secondaryRowAnimation: Animation? {
        isLiveResizing ? nil : ReaderMotion.secondaryRowAnimation
    }

    /// One row slot, selected exactly like the old `if pageOverviewVisible … else if
    /// annotationToolsVisible` chain: page overview wins and the two can never be shown twice.
    private var secondaryToolbarVisible: Bool {
        state.pageOverviewVisible || state.annotationToolsVisible
    }

    private var secondaryToolbarInset: CGFloat {
        guard !state.pageOverviewVisible, state.sidebarVisible else { return 0 }
        return ReaderChrome.sidebarTotalWidthPt
    }

    /// The read-only explanation for a digitally signed document.
    ///
    /// This is a *permanent* banner, not a pending-state one: the restriction belongs to the
    /// file, so it stays visible for as long as the document is open. It names the evidence the
    /// engine found and says what still works (copying/exporting), because a banner that only
    /// said "read-only" would leave the reader guessing whether reading is affected too.
    private var readOnlyBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.doc")
                .foregroundStyle(LyraReaderTheme.warningFg)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.readOnlyBannerTitle)
                    .font(.callout.weight(.semibold))
                Text(state.readOnlyReason ?? "This PDF is digitally signed, so it is read-only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 640, alignment: .leading)
                if !state.readOnlyBannerEvidence.isEmpty {
                    Text(state.readOnlyBannerEvidence)
                        .font(.caption2)
                        .foregroundStyle(LyraReaderTheme.textTertiary)
                        .frame(maxWidth: 640, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            Text(state.readOnlyBannerNote)
                .font(.caption2)
                .foregroundStyle(LyraReaderTheme.textSecondary)
                .frame(maxWidth: 220, alignment: .trailing)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(LyraReaderTheme.raisedBg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(LyraReaderTheme.warningFg.opacity(0.55), lineWidth: 1)
        )
        .shadow(radius: 3, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Signed PDF, read-only. \(state.readOnlyReason ?? "") Saving a copy still works."
        )
    }

    /// The one place the interface states, without qualification, that the file on disk is not
    /// what is on screen. It stays visible for the whole staged session, not just after an action.
    private var pageEditBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(LyraReaderTheme.warningFg)
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
            .disabled(!state.canReplaceOriginalWithPageEdits)
            .help(state.isReadOnlyDocument
                  ? (state.readOnlyReason ?? "Signed PDF · read-only in place")
                  : "Replace the original file with the staged page changes")
            Button("Save Copy…") { state.presentSavePageEditsCopyPanel() }
                .disabled(!state.canSavePageEditsCopy)
            Button("Discard…") { state.presentDiscardPageEditsConfirmation() }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(LyraReaderTheme.raisedBg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(LyraReaderTheme.warningFg.opacity(0.5), lineWidth: 1)
        )
        .shadow(radius: 3, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Page changes pending. The file on disk is unchanged.")
    }

    /// The form session's version of the page-edit banner: the same raised panel, the same
    /// warning icon and the same sentence about the file on disk. It says exactly which fields
    /// changed and never calls the file saved.
    private var redactionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.dashed")
                .foregroundStyle(Color.red)
            VStack(alignment: .leading, spacing: 1) {
                Text("Redactions pending")
                    .font(.callout.weight(.semibold))
                Text(
                    "\(state.pendingRedactions.count) area(s) on \(state.pendingRedactionPageCount) page(s)"
                        + " · nothing has been removed yet; the file on disk is unchanged"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Divider().frame(height: 24)
            Button("Apply to Copy…") { state.presentApplyRedactionsPanel() }
                .disabled(!state.canApplyRedactions)
            Button("Replace Original…") { state.presentReplaceRedactionsConfirmation() }
                .disabled(!state.canReplaceOriginalWithRedactions)
                .help(state.isReadOnlyDocument
                      ? (state.readOnlyReason ?? "Signed PDF · read-only in place")
                      : "Replace the original file with the redacted version")
            Button("Clear") { state.clearPendingRedactions() }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(LyraReaderTheme.raisedBg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.red.opacity(0.5), lineWidth: 1)
        )
        .shadow(radius: 3, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Redactions pending. Nothing has been removed from the file yet.")
    }

    private var formBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "signature")
                .foregroundStyle(LyraReaderTheme.warningFg)
            VStack(alignment: .leading, spacing: 1) {
                Text("Form changes pending")
                    .font(.callout.weight(.semibold))
                Text(state.formPendingSummary ?? "The file on disk is unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider().frame(height: 24)
            Button("Save Copy…") { state.presentSaveFilledFormPanel() }
                .disabled(!state.canSaveFilledForm)
            Button("Apply to Original…") {
                state.presentReplaceOriginalWithFilledFormConfirmation()
            }
            .disabled(!state.canReplaceOriginalWithFilledForm)
            .help(state.isReadOnlyDocument
                  ? (state.readOnlyReason ?? "Signed PDF · read-only in place")
                  : "Write the form values into the original file")
            Button("Discard") { state.discardFormChanges() }
                .disabled(!state.formHasPendingChanges)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(LyraReaderTheme.raisedBg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(LyraReaderTheme.warningFg.opacity(0.5), lineWidth: 1)
        )
        .shadow(radius: 3, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Form changes pending. \(state.formChangedFields.count) field(s) differ from the file on disk."
        )
    }

    /// The eraser's pending state: the strokes are gone from the reader's view and from its
    /// sidecar, but the PDF on disk is untouched until an explicit save. Same panel, icon and
    /// sentence as the other pending banners; the only difference is that this one has no
    /// "Apply to Original" pair because it is a deletion, not a value.
    private var eraserPendingBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "eraser")
                .foregroundStyle(LyraReaderTheme.warningFg)
            VStack(alignment: .leading, spacing: 1) {
                Text("Annotation changes pending")
                    .font(.callout.weight(.semibold))
                Text(state.eraserPendingSummary ?? "The PDF on disk is unchanged until you save a copy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider().frame(height: 24)
            Button("Save Copy…") { state.presentSaveAnnotatedCopyPanel() }
                .disabled(!state.canSaveAnnotationsToPDF)
            Button("Undo") { state.undo() }
                .disabled(!state.canUndo)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(LyraReaderTheme.raisedBg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(LyraReaderTheme.warningFg.opacity(0.5), lineWidth: 1)
        )
        .shadow(radius: 3, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Annotation deletions pending. The PDF on disk is unchanged until you save a copy."
        )
    }

    /// The single remaining refusal: a file annotation whose kind has no editable model (a
    /// reply, `/Squiggly`, `/Stamp`, …). It comes from the same policy the canvas, sidebar and
    /// writer use, so the message cannot disagree with what a click actually does.
    private var annotationRefusalBanner: some View {
        let title = "This annotation cannot be edited here"
        let message = state.markSelectionRefusalNotice
            ?? "LyraReader has no editable model for this annotation's kind."
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(LyraReaderTheme.warningFg)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520, alignment: .leading)
            }
            Divider().frame(height: 24)
            Button("Dismiss") { state.dismissMarkSelectionRefusal() }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(LyraReaderTheme.raisedBg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(LyraReaderTheme.warningFg.opacity(0.5), lineWidth: 1)
        )
        .shadow(radius: 3, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }

    private var emptyState: some View {
        ReaderHomeView(state: state, opener: opener)
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
            .background(LyraReaderTheme.raisedBg, in: Capsule())
            .opacity(state.document == nil ? 0 : 1)
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
        hint.kind == .acceptable ? LyraReaderTheme.accent : LyraReaderTheme.warningFg
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
            .background(LyraReaderTheme.raisedBg,
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
