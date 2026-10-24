import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Main window: toolbar + collapsible sidebar + canvas + optional right-hand side panel
/// (`docs/04-ui-ux.md` §2). The right panel is the AI assistant's home; the left sidebar keeps
/// thumbnails, outline, annotations and bookmarks, so both can be open at once.
///
/// The skeleton phase uses a hand-rolled `HStack` split instead of `NavigationSplitView`:
/// the latter would bring the system sidebar material and automatic collapsing, but its
/// `columnVisibility` binding adds risk in an environment without compile verification.
/// **M1 T1.10 will make the A/B decision with a runnable version**
/// (evaluated together with the scrolling approach in T1.4).
public struct ReaderWindow: View {
    @ObservedObject private var state: AppState
    @ObservedObject private var documentKnowledge: AIDocumentKnowledge
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
    /// One assistant per window. It moves out of the sidebar but not out of the window's
    /// ownership: closing and reopening the right panel must not discard an answer, and a second
    /// window must not share the first window's request state. Injectable so the checks can
    /// point it at an isolated settings suite.
    @StateObject private var aiAssistant: AIAssistantModel

    public init(
        state: AppState,
        opener: DocumentOpenCoordinator,
        previewPanels: ReferencePreviewPanelController = .shared,
        integratesTitlebar: Bool = false,
        aiAssistant: AIAssistantModel? = nil
    ) {
        self.state = state
        _documentKnowledge = ObservedObject(wrappedValue: state.documentKnowledge)
        self.opener = opener
        self.previewPanels = previewPanels
        self.integratesTitlebar = integratesTitlebar
        _aiAssistant = StateObject(wrappedValue: aiAssistant ?? AIAssistantModel())
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
                    ReaderSidebarTransition(
                        isVisible: state.sidebarVisible && state.document != nil,
                        progressOverride: state.transitionProgressOverride?.sidebar
                    ) {
                        SidebarView(state: state, opener: opener)
                    }
                    .accessibilityHidden(state.document == nil || !state.sidebarVisible)
                    HorizontalDocumentViewport(
                        contentWidth: state.contentWidthPt * state.zoomFactor,
                        onViewport: { state.setViewportSize($0) },
                        onHorizontalScroll: { state.setHorizontalViewportOrigin($0) }
                    ) { canvas }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The scroll indicator is a real lane, not an overlay: the canvas viewport
                    // and the page column end before it, and the right panel starts after it.
                    if state.document != nil {
                        ScrollIndicator(state: state)
                            .frame(width: ReaderChrome.scrollIndicatorLaneWidthPt)
                            .background(LyraReaderTheme.canvasBg)
                    }
                    if state.searchSidebarVisible && state.document != nil {
                        SearchResultSidebar(state: state).frame(width: ReaderChrome.sidebarTotalWidthPt)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    assistantDrawer
                    if state.performancePanelVisible { performanceDrawer }
                    // The two inspectors share the right-hand slot, so they also share the
                    // test seam that pins the panel's progress. The override applies only to
                    // the inspector that is actually visible: an editing-panel pin must not
                    // force the Fill & Sign inspector open (or the other way round).
                    ReaderEditingPanelTransition(
                        isVisible: state.contentEditInspectorVisible,
                        progressOverride: state.contentEditInspectorVisible
                            ? state.transitionProgressOverride?.editingPanel : nil
                    ) {
                        ContentEditInspector(state: state)
                    }
                    .background(ReaderChromeMarkerHost(kind: .editingInspectorSlot))
                    ReaderEditingPanelTransition(
                        isVisible: state.fillSignInspectorVisible,
                        progressOverride: state.fillSignInspectorVisible
                            ? state.transitionProgressOverride?.editingPanel : nil
                    ) {
                        FillSignInspector(state: state)
                    }
                    .background(ReaderChromeMarkerHost(kind: .fillSignInspectorSlot))
                }
                // The animation belongs to the row, not to the sidebar view: it is this
                // HStack's layout that must interpolate, so the canvas width moves with the
                // panel instead of jumping to the final width on the first frame.
                .animation(sidebarAnimation, value: state.sidebarVisible)
                .animation(sidebarAnimation, value: state.searchSidebarVisible)
                .animation(panelAnimation, value: state.rightPanelVisible)
                .animation(panelAnimation, value: state.performancePanelVisible)
                .animation(panelAnimation, value: state.contentEditInspectorVisible)
                .animation(panelAnimation, value: state.fillSignInspectorVisible)
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
        .background(DocumentEditedReporter(isEdited: state.tabs.indices.contains { state.tabHasUnsavedChanges($0) }))
        .foregroundStyle(LyraReaderTheme.textPrimary)
        .tint(LyraReaderTheme.accent)
        .preferredColorScheme(appearance.mode.colorScheme)
        .sheet(isPresented: $documentKnowledge.isPresented) {
            AIDocumentKnowledgeSheet(knowledge: documentKnowledge)
        }
        .sheet(isPresented: $state.showDocumentInformation) { DocumentInformationView(state: state) }
        .confirmationDialog("Save PDF changes before closing?",isPresented:$state.contentCloseRequested,titleVisibility:.visible) {
            if state.closeRequiresReview {
                Button("Review Changes") { state.reviewChangesBeforeClosing() }
            } else {
                Button(state.isReadOnlyDocument ? "Save a Copy…" : "Save") {state.saveContentAndClose()}
            }
            Button("Discard Changes",role:.destructive) {state.discardContentAndClose()}
            Button("Cancel",role:.cancel) {state.cancelContentClose()}
        } message: { Text(state.closeChangesMessage) }
        .onAppear {
            state.installTerminationHandling()
            documentKnowledge.settings = aiAssistant.settings
            // The in-place action uses the same provider settings and target language as the
            // assistant panel; there is exactly one AI configuration in a window.
            state.inPlaceTranslationSettingsOverride = aiAssistant.settings
            state.inPlaceTranslationAuditOverride = aiAssistant.audit
            state.inPlaceTranslationTargetLanguage = aiAssistant.targetLanguage
        }
        .onChange(of: state.document?.url) { _, _ in documentKnowledge.invalidate() }
        .onChange(of: aiAssistant.targetLanguage) { _, language in
            state.inPlaceTranslationTargetLanguage = language
        }
        // Tell the state whether this toggle is a real animation. The state holds the width-only
        // viewport updates (and releases one rebuild) for the slide, because a loaded machine can
        // take longer per frame than the ordinary coalescing window.
        .onChange(of: state.rightPanelVisible) { _, _ in
            state.noteRightPanelVisibilityChange(animated: panelAnimation != nil)
        }
        .onChange(of: state.contentEditInspectorVisible) { _, _ in
            state.noteRightPanelVisibilityChange(animated: panelAnimation != nil)
        }
        .onChange(of: state.fillSignInspectorVisible) { _, _ in
            state.noteRightPanelVisibilityChange(animated: panelAnimation != nil)
        }
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
        .onChange(of: state.document?.id) { _, _ in
            // Covers direct open/close paths that do not go through a tab switch. Switching
            // tabs already closes the card in AppState; this call is then a no-op.
            state.finishRegionCardsForDocumentSwitch(
                reason: "Document switched. The region conversation was moved to Region questions."
            )
        }
        .alert("LyraReader", isPresented: Binding(
            get: { state.lastError != nil },
            set: { if !$0 { state.lastError = nil } }
        )) {
            // The way out of an annotation cache that failed to load: an explicit action that moves the
            // unreadable file aside (never overwrites it) and starts a fresh one.
            if state.canRecoverUnreadableAnnotationRecords {
                Button("Back Up Recovery Data and Start Fresh") {
                    if let backup = state.recoverUnreadableAnnotationRecords() {
                        state.revealAnnotationBackupInFinder(backup)
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

    /// The drawer reserves a column beside the document viewport. Width changes recenter the
    /// page horizontally while preserving its vertical scroll position.
    private var assistantDrawer: some View {
        ReaderSidePanel(
            isVisible: state.rightPanelVisible && state.document != nil,
            contentWidth: state.rightPanelWidthPt,
            progressOverride: state.transitionProgressOverride?.panel,
            accessibilityLabel: "AI assistant panel",
            onResizeBegan: { state.beginRightPanelResize() },
            onResize: { state.resizeRightPanel(to: $0) },
            onResizeEnded: { state.endRightPanelResize(); state.commitRightPanelWidth() }
        ) {
            AIAssistantRightPanelContent(state: state, model: aiAssistant)
        }
        .animation(panelAnimation, value: state.rightPanelVisible)
    }

    /// The developer-facing performance panel, in the same right-hand drawer host as the
    /// assistant. It shares the persisted right-panel width, so the two tenants cannot end up
    /// with different geometry and the resize handle keeps working. Only one is open at a time
    /// (`AppState.togglePerformancePanel`).
    private var performanceDrawer: some View {
        ReaderSidePanel(
            isVisible: state.performancePanelVisible && state.document != nil,
            contentWidth: state.rightPanelWidthPt,
            progressOverride: state.transitionProgressOverride?.panel,
            accessibilityLabel: "Performance panel",
            resizeAccessibilityLabel: "Resize performance panel",
            onResizeBegan: { state.beginRightPanelResize() },
            onResize: { state.resizeRightPanel(to: $0) },
            onResizeEnded: { state.endRightPanelResize(); state.commitRightPanelWidth() }
        ) {
            PerformancePanelView(controller: state.performancePanel) {
                state.togglePerformancePanel()
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
                paperAppearance: appearance.mode,
                annotationMarks: state.canvasAnnotationMarks,
                annotationPageFrames: state.canvasPageSegments,
                translationOverlays: state.translationOverlays,
                translationPaperColors: state.translationPaperColors,
                annotationTool: state.annotationTool,
                regionSelectionArmed: state.regionSelectionArmed,
                onRegionSelection: { page, rect in
                    state.handleRegionSelection(page: page, rect: rect)
                },
                onRegionSelectionCancelled: { reason in
                    state.cancelRegionSelection(reason: reason)
                },
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
                fillSignPlacementPending: state.hasPendingFillSignPlacement,
                onPlaceFillSign: { point in state.placePendingFillSign(atContentPoint: point) },
                // Escape leaves whichever annotation tool is armed; the canvas cancels a live
                // draft first. Escape inside a form field is the field editor's own key path.
                onCancelTool: { state.cancelActiveAnnotationTool() },
                onFrame: { stats in state.updateGpuStatus(stats, label: "GPU") },
                onFailure: { message in state.reportGpuFailure(message) },
                performanceProbe: state.performanceProbe,
                onDeviceScale: { scale in state.setDeviceScale(scale) },
                // The screen's physical density: 100% means actual size on it, so moving the
                // window to another display keeps the percentage and changes the factor.
                onDisplayCalibration: { calibration in
                    state.setDisplayCalibration(calibration)
                },
                onViewportSize: { _ in },
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
                },
                onTranslationToggle: { id in state.toggleTranslation(id: id) },
                onTranslationCancel: { id in state.cancelTranslation(id: id) },
                regionState: state,
                onOpenRegionInPanel: { entry in
                    guard let context = state.aiReaderContext else { return }
                    aiAssistant.importConversation(question: entry.question, answer: entry.answer,
                        attachment: entry.attachment, context: context)
                    state.rightPanelVisible = true
                },
                onShowRegionHistory: {
                    state.rightPanelVisible = true
                    aiAssistant.selectedTab = .regions
                }
            )
            .background(ReferencePreviewHost(state: state, panels: previewPanels))


            if state.contentEditEnabled {
                PDFContentEditor(state:state)
                    .task(id:"\(state.document?.url?.path ?? "")-\(state.currentPage)-\(state.activeTabIndex)") {
                        if !state.contentEditLoading, state.contentEditPage?.page != state.currentPage - 1 {
                            await state.reloadContentObjects()
                        }
                    }
            }

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

            if state.isReadOnlyDocument
                || state.formHasPendingChanges
                || state.hasPendingInkErasure || state.hasPendingFileDeletions
                || state.markSelectionRefusalNotice != nil
                || state.eraserRefusalNotice != nil
                || state.regionRefusalMessage != nil
                || state.translationNotice != nil {
                VStack(spacing: 8) {
                    if state.isReadOnlyDocument { readOnlyBanner }
                    if state.formHasPendingChanges { formBanner }
                    if state.markSelectionRefusalNotice != nil {
                        annotationRefusalBanner
                    }
                    if state.eraserRefusalNotice != nil {
                        eraserRefusalBanner
                    }
                    if state.regionRefusalMessage != nil {
                        regionRefusalBanner
                    }
                    if state.translationNotice != nil {
                        translationBanner
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
            ReaderSecondaryToolbarTransition(
                isVisible: secondaryToolbarVisible,
                progressOverride: state.transitionProgressOverride?.row
            ) {
                if state.aiToolsVisible && !state.pageOverviewVisible {
                    ReaderAIToolbar(state: state, model: aiAssistant)
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else {
                    ReaderSecondaryToolbar(state: state)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            // The slot's animated height, not its 46 pt content: the checks read this instead
            // of hit-testing, because the Edit workspace's content editor covers the canvas
            // below the row and would look like row chrome.
            .background(ReaderChromeMarkerHost(kind: .secondaryRowSlot))
        }
        // Same rule as the sidebar: the animation has to own the layout that changes. The row
        // covers the scroll lane and ends flush against the right panel; the
        // trailing inset uses their settled widths (like the leading sidebar inset) so the row's
        // own controls do not reflow on every animation frame.
        .padding(.trailing, secondaryToolbarTrailingInset)
        .animation(secondaryRowAnimation, value: secondaryToolbarVisible)
        .animation(secondaryRowAnimation, value: state.aiToolsVisible)
    }

    /// A toggle made while the window edge is being dragged changes layout without animating:
    /// animating against the pointer would make the layout chase two sizes at once.
    private var sidebarAnimation: Animation? {
        if state.transitionProgressOverride != nil { return nil }
        return isLiveResizing ? nil : ReaderMotion.sidebarAnimation
    }

    private var secondaryRowAnimation: Animation? {
        if state.transitionProgressOverride != nil { return nil }
        return isLiveResizing ? nil : ReaderMotion.secondaryRowAnimation
    }

    /// Right panel animation follows the same three rules as the left sidebar: Reduce Motion,
    /// no animation during a live window resize, and no animation when the checks pin a
    /// transition progress.
    private var panelAnimation: Animation? {
        if state.transitionProgressOverride != nil { return nil }
        return isLiveResizing ? nil : ReaderMotion.panelAnimation
    }

    /// One row slot, selected exactly like the old `if pageOverviewVisible … else if
    /// annotationToolsVisible` chain: page overview wins and the two can never be shown twice.
    private var secondaryToolbarVisible: Bool {
        state.pageOverviewVisible || state.annotationToolsVisible || state.contentEditEnabled
            || state.fillAndSignVisible || state.exportVisible || state.aiToolsVisible
    }

    private var secondaryToolbarInset: CGFloat {
        guard !state.pageOverviewVisible, state.sidebarVisible else { return 0 }
        return ReaderChrome.sidebarTotalWidthPt
    }

    /// The search results and right panels. The row covers the scroll lane, preventing a strip
    /// of track between the tools and the inspector. Page overview draws over the whole area, so it
    /// suppresses all three like it suppresses the leading inset.
    private var secondaryToolbarTrailingInset: CGFloat {
        guard !state.pageOverviewVisible, state.document != nil else { return 0 }
        return state.secondaryInspectorWidth + ReaderChrome.trailingChromeWidth(
            documentOpen: state.document != nil,
            pageOverviewVisible: state.pageOverviewVisible,
            searchVisible: state.searchSidebarVisible,
            rightPanelVisible: state.rightPanelVisible || state.performancePanelVisible,
            rightPanelContentWidth: state.rightPanelWidthPt
        )
    }

    /// What the in-place translation layer just did, including why an overlay disappeared after
    /// a page edit. It is a status sentence, not a warning about the file: the PDF is untouched.
    private var translationBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "character.bubble")
                .foregroundStyle(LyraReaderTheme.accent)
            VStack(alignment: .leading, spacing: 5) {
                Text(state.translationNotice ?? "")
                    .font(.callout)
                    .frame(maxWidth: 640, alignment: .leading)
                if let failure = state.translationFailure,
                   let hint = AIOfflineHint.forFailure(failure) {
                    AIOfflineHintView(hint: hint)
                        .frame(maxWidth: 640, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            Button {
                state.dismissTranslationNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss translation message")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(LyraReaderTheme.raisedBg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(LyraReaderTheme.accent.opacity(0.45), lineWidth: 1)
        )
        .shadow(radius: 3, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.translationNotice ?? "Translation status")
    }

    /// The read-only explanation for a digitally signed document or an XFA form.
    ///
    /// This is a *permanent* banner, not a pending-state one: the restriction belongs to the
    /// file, so it stays visible for as long as the document is open. A signed PDF names the
    /// evidence the engine found and says what still works (copying/exporting), because a banner
    /// that only said "read-only" would leave the reader guessing whether reading is affected
    /// too. An XFA form gets two sentences of reader-facing copy instead: packet names, field
    /// counts and the skipped list are diagnostics, not banner text.
    private var readOnlyBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.doc")
                .foregroundStyle(LyraReaderTheme.warningFg)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.readOnlyBannerTitle)
                    .font(.callout.weight(.semibold))
                Text(state.readOnlyBannerBody)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 640, alignment: .leading)
                if !state.isXfaDocument && !state.readOnlyBannerEvidence.isEmpty {
                    Text(state.readOnlyBannerEvidence)
                        .font(.caption2)
                        .foregroundStyle(LyraReaderTheme.textTertiary)
                        .frame(maxWidth: 640, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            if !state.readOnlyBannerNote.isEmpty {
                Text(state.readOnlyBannerNote)
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.textSecondary)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
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
            state.isXfaDocument
                ? "\(state.readOnlyBannerTitle). \(state.readOnlyBannerBody)"
                : "Signed PDF, read-only. \(state.readOnlyBannerBody) Saving a copy still works."
        )
    }

    /// The form session's version of the page-edit banner: the same raised panel, the same
    /// warning icon and the same sentence about the file on disk. It says exactly which fields
    /// changed and never calls the file saved.
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
                  ? (state.readOnlyReason ?? state.readOnlyBannerTitle)
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
    /// annotation cache, but the PDF on disk is untouched until an explicit save. Same panel, icon and
    /// sentence as the other pending banners; the only difference is that this one has no
    /// "Apply to Original" pair because it is a deletion, not a value.
    private var eraserPendingBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "eraser")
                .foregroundStyle(LyraReaderTheme.warningFg)
            VStack(alignment: .leading, spacing: 1) {
                Text("Annotation changes pending")
                    .font(.callout.weight(.semibold))
                Text(state.eraserPendingSummary ?? "The PDF on disk is unchanged until you save.")
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
            "Annotation deletions pending. The PDF on disk is unchanged until you save."
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

    /// The eraser's refusal when cutting a PDF-owned stroke would delete its review thread.
    /// The sentence comes from `AppState.inkAttachmentRefusal`, so the check and the banner
    /// cannot disagree about what would be lost.
    private var regionRefusalBanner: some View {
        HStack(spacing: 9) {
            Image(systemName: "rectangle.dashed")
                .foregroundStyle(LyraReaderTheme.warningFg)
            VStack(alignment: .leading, spacing: 1) {
                Text("Region question was not created")
                    .font(.caption.weight(.semibold))
                Text(state.regionRefusalMessage ?? "")
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button { state.regionRefusalMessage = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss region refusal")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(LyraReaderTheme.panelBg, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(LyraReaderTheme.warningFg.opacity(0.5), lineWidth: 0.75))
        .frame(maxWidth: 620)
    }

    private var eraserRefusalBanner: some View {
        let message = state.eraserRefusalNotice
            ?? "This stroke belongs to the PDF and carries review text; splitting it would delete it."
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(LyraReaderTheme.warningFg)
            VStack(alignment: .leading, spacing: 1) {
                Text("This stroke cannot be split here")
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520, alignment: .leading)
            }
            Divider().frame(height: 24)
            Button("Dismiss") { state.dismissEraserRefusal() }
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
