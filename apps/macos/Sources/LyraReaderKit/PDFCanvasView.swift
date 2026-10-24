import AppKit
import LyraReaderFFI
import Metal
import QuartzCore
import SwiftUI

/// Diagnostic layer: observe the drawable wgpu acquires without acquiring another one.
/// Metal reports its actual presentation host time asynchronously, including zero for drops.
final class PresentationTraceLayer: CAMetalLayer {
    var traceSurface: UInt64 = 0
    var traceY: Double = 0
    private(set) var traceSequence: UInt64 = 0

    override func nextDrawable() -> (any CAMetalDrawable)? {
        guard let drawable = super.nextDrawable() else { return nil }
        traceSequence += 1
        let sequence = traceSequence
        let surface = traceSurface
        let y = traceY
        drawable.addPresentedHandler { drawable in
            let line = "lyra-reader-scroll-trace: {\"kind\":\"presentation\",\"time\":\(drawable.presentedTime),\"callback_time\":\(CACurrentMediaTime()),\"surface\":\(surface),\"sequence\":\(sequence),\"y\":\(y)}\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        return drawable
    }
}

/// Mirrors the C return codes declared in `lyra_reader_ffi.h`.
///
/// Spelled out in Swift instead of relying on how Swift imports the anonymous C enum,
/// which keeps the interop surface obvious.
enum LyraReaderStatus: Int32 {
    case ok = 0
    case invalidArgument = 1
    case notImplemented = 2
    case notInitialized = 3
    case gpuUnavailable = 4
    case gpuDeviceLost = 5
    case internalError = 6

    static func describe(_ code: Int32) -> String {
        guard let status = LyraReaderStatus(rawValue: code) else { return "unknown status \(code)" }
        return "\(status)"
    }
}

/// The `NSView` that hosts GPU rendering: **its backing layer is a `CAMetalLayer`**
/// which the Rust engine attaches to as a render surface.
///
/// Lifecycle (M0 T0.4/T0.5) and page drawing (M1):
///
/// 1. `lyra_reader_gpu_init()` creates the wgpu device;
/// 2. this view hands its layer pointer to `lyra_reader_surface_attach()`;
/// 3. a page bitmap arrives from the engine, is uploaded once
///    (`lyra_reader_gpu_upload_texture`) and drawn as a textured quad
///    (`lyra_reader_surface_draw_page`) at the current zoom;
/// 4. frames are produced **on demand** — a change of page, zoom or size — so an idle
///    window costs no GPU work;
/// 5. **an empty page list still produces a frame**, with the background and no quads:
///    the last presented drawable would otherwise keep showing the closed document, which
///    is what the empty state was drawn over. Every path that empties the document (the
///    last tab closing, a failed first open, launch) therefore clears by construction;
/// 6. on teardown the order is fixed: detach the surface, release textures, *then* let
///    AppKit release the layer (a hard requirement of wgpu's Metal backend).
///
/// Both sides use the process-wide default `MTLDevice`, which is what makes the layers
/// interoperate — the M0 spike's device-ownership result (`docs/adr/0003`).
public final class MetalCanvasView: NSView {
    /// Reports frame statistics (the view throttles them itself).
    public var onFrame: ((LyraReaderFrameStats) -> Void)?
    /// The performance panel's seam. Weak: the reader owns the probe, and an unopened panel's
    /// only cost is the nil/bool check in `renderFrame` before any sample is built.
    public weak var performanceProbe: CanvasPerformanceProbe?
    /// Reports a fatal GPU/surface problem; rendering stops afterwards.
    public var onFailure: ((String) -> Void)?
    /// Reports the backing scale so the engine can rasterize at device resolution.
    public var onDeviceScale: ((CGFloat) -> Void)?
    /// Reports the screen's zoom calibration when the view attaches to a window, the window
    /// moves to another screen, or the display mode changes. The shell keeps the reader's
    /// percentage and only changes the physical scale (`AppState.setDisplayCalibration`).
    public var onDisplayCalibration: ((DisplayCalibration) -> Void)?

    /// Pages to draw; new bitmaps are uploaded as textures and old ones released.
    public var pages: [CanvasPage] = [] {
        didSet {
            let unchanged = pages.count == oldValue.count && zip(pages, oldValue).allSatisfy {
                $0.placement == $1.placement && $0.image.generation == $1.image.generation
                    && $0.source == $1.source && $0.blend == $1.blend
            }
            guard !unchanged else { return }
            syncTextures()
            markNeedsRender()
        }
    }

    /// Scroll offset in content points (0 = top of the first page).
    public var scrollYPt: CGFloat = 0 {
        didSet {
            guard scrollYPt != oldValue else { return }
            syncAnnotationOverlay()
            markNeedsRender()
        }
    }

    /// The reader's ink and shape marks, in page-local view space.
    public var annotationMarks: [CanvasAnnotationMark] = [] {
        didSet {
            guard annotationMarks != oldValue else { return }
            syncAnnotationOverlay()
        }
    }

    /// Where each visible page sits in content points, for mapping page-local marks.
    public var annotationPageFrames: [PagePlacement] = [] {
        didSet {
            guard annotationPageFrames != oldValue else { return }
            syncAnnotationOverlay()
        }
    }

    /// In-place translations to draw over their source blocks. The model is page-local; the
    /// overlay applies the same placement and zoom as the annotation layer.
    public var translationOverlays: [TranslationOverlay] = [] {
        didSet {
            guard translationOverlays != oldValue else { return }
            syncTranslationOverlay()
        }
    }

    /// Paper colours sampled from each visible page. A missing page falls back to the display
    /// appearance's paper colour.
    public var translationPaperColors: [Int: TranslationPaperColor] = [:] {
        didSet {
            guard translationPaperColors != oldValue else { return }
            syncTranslationOverlay()
        }
    }

    /// The chip was pressed. AppState decides whether this is a flip, a retry or a fresh request.
    public var onTranslationToggle: ((String) -> Void)?
    /// The cancel affordance on a translating block.
    public var onTranslationCancel: ((String) -> Void)?

    /// One-shot region selection: the pointer becomes a crosshair, a drag draws a marquee with
    /// visible bounds, and the release hands the page rectangle to the shell.
    ///
    /// The gesture is checked before every annotation, text-selection and page-edit path, so it
    /// cannot fight a text-selection handle or a drawing tool. `AppState` refuses to arm it while
    /// any of those modes owns the pointer; this view is the second guard.
    public var regionSelectionArmed = false {
        didSet {
            guard regionSelectionArmed != oldValue else { return }
            if !regionSelectionArmed { cancelRegionGesture() }
            window?.invalidateCursorRects(for: self)
        }
    }
    /// A completed marquee: 0-based page and page-local rectangle, in points.
    public var onRegionSelection: ((Int, CGRect) -> Void)?
    /// The drag was too small or left the page; the shell shows the reason and disarms.
    public var onRegionSelectionCancelled: ((String) -> Void)?

    private var regionMarquee: AIRegionMarqueeOverlayView?
    private var regionGestureActive = false
    private var regionGesturePage: Int?
    private var regionGestureStart: CGPoint?
    private var regionGestureCurrent: CGPoint?

    /// The tool a pointer drag uses. `.select` leaves text selection and mark selection intact.
    ///
    /// The eraser owns the gesture in the same way the pen does: a press starts a gesture, every
    /// drag sample extends it, and the release ends it. Nothing about selection runs while it is
    /// armed. Leaving the mode drops any gesture in flight (the model has already cancelled it).
    public var annotationTool: AnnotationTool = .select {
        didSet {
            guard annotationTool != oldValue else { return }
            if annotationTool == .eraser {
                // mouseMoved: is only generated when the window opts in. Arming the eraser is
                // the one moment the canvas needs it; leaving it on afterwards is harmless.
                window?.acceptsMouseMovedEvents = true
                return
            }
            eraserGestureActive = false
            eraserLastContentPoint = nil
        }
    }

    /// Colour and width of the mark a drag creates. `AppState` owns both; the canvas only draws.
    public var annotationColor = AnnotationColor(red: 0xE8, green: 0xBC, blue: 0x55, alpha: 255)
    public var annotationStrokeWidth: CGFloat = 2 {
        didSet { syncAnnotationOverlay() }
    }

    /// A finished stroke or shape, handed to the shell once, on mouse-up.
    public var onAnnotationDraft: ((AnnotationDraft) -> Void)?
    /// The eraser gesture, in content points. `dragged` receives the segment's previous and
    /// current points, so the model tests the path the pointer travelled, not isolated samples.
    public var onEraseGestureBegan: ((CGPoint) -> Void)?
    public var onEraseGestureDragged: ((CGPoint, CGPoint) -> Void)?
    public var onEraseGestureEnded: (() -> Void)?
    /// The pointer over an armed eraser, in content points; `nil` leaves the view.
    public var onEraserHover: ((CGPoint?) -> Void)?
    /// Delete the selected mark (Delete/Backspace). Returns whether something was deleted.
    public var onDeleteAnnotation: (() -> Bool)?
    /// The sticky-note tool's click: place a note at a content point, or open one already there.
    public var onPlaceStickyNote: ((CGPoint) -> Bool)?
    /// A double-click on a placed text annotation; true means the shell opened its editor and
    /// the gesture must not become text selection.
    public var onAnnotationDoubleClick: ((CGPoint) -> Bool)?
    /// The text-box tool's double-click: place a box with its top-left at this content point, or
    /// open the box already under it. Returns whether the shell acted.
    public var onPlaceTextBox: ((CGPoint) -> Bool)?
    /// A click with the stamp tool armed, in content points.
    public var onPlaceStamp: ((CGPoint) -> Bool)?
    /// A click with the image-signature tool armed, in content points.
    public var onPlaceSignature: ((CGPoint) -> Bool)?
    /// A Fill & Sign placement is armed: the next click commits it (text, date, check, cross or
    /// a drawn signature). Set from `AppState.pendingFillSignPlacement` on every update.
    public var fillSignPlacementPending = false
    /// A Fill & Sign click placement, in content points.
    public var onPlaceFillSign: ((CGPoint) -> Bool)?
    /// Escape while the canvas is the first responder: leave a mode (sticky markup or the
    /// eraser). Returns whether a mode was left, so Escape is only consumed when it did something.
    public var onCancelTool: (() -> Bool)?

    private let regionHost = AIRegionCanvasHost()
    package var regionCardFrames: [CGRect] { regionHost.cardFrames }
    public func configureRegionCards(state: AppState?,
        onOpenInPanel: @escaping (AIRegionHistoryEntry) -> Void = { _ in },
        onShowHistory: @escaping () -> Void = {}) {
        if regionHost.superview == nil { addSubview(regionHost) }
        if regionHost.configure(state: state, onOpenInPanel: onOpenInPanel, onShowHistory: onShowHistory) {
            markNeedsRender()
        }
    }

    private var pageChrome: PageChromeOverlayView?
    package var pageChromeRectangles: [CGRect] { pageChrome?.pageRectangles ?? [] }
    private var annotationOverlay: AnnotationOverlayView?
    private var translationOverlay: TranslationOverlayView?
    private var drawingPage: Int?
    private var drawingKind: AppState.Annotation.Kind?
    private var annotationSelectGesture = false
    /// The press was the sticky-note tool's; placement happens on mouse-up if it stayed a click.
    private var notePlacementPending = false
    private var stampPlacementPending = false
    private var signaturePlacementPending = false
    /// The press belonged to an armed Fill & Sign placement; the click commits on mouse-up.
    private var fillSignPlacementPressPending = false
    /// The text-box tool owns a press from down to up, but only a double-click creates a box.
    /// The flag keeps a drag with the tool armed from falling through to text selection.
    private var textBoxPlacementPending = false
    /// The press opened an editor on a double-click; the release must not also select text.
    private var annotationDoubleClickConsumed = false
    /// An eraser drag is in flight, and where its last sample landed (content points).
    private var eraserGestureActive = false
    private var eraserLastContentPoint: CGPoint?
    /// Delivers pointer movement for the eraser's pre-erase halo. Installed once; AppKit
    /// re-creates tracking areas when the view moves or resizes.
    private var hoverTrackingArea: NSTrackingArea?

    /// Scroll gestures, reported as deltas in screen points.
    ///
    /// This is the *continuous* path: a trackpad's precise deltas, and its momentum, arrive here
    /// already animated by the system and are applied one to one.
    public var onScroll: ((CGFloat) -> Void)?
    /// Wheel input, accelerated by cadence and reported as a distance in screen points.
    public var onScrollStep: ((CGFloat) -> Void)?
    /// Keyboard paging, when the shell wants to treat it differently from a wheel notch: a page key
    /// names an animated destination, while a wheel distance is applied immediately.
    /// Falls back to `onScrollStep` when unset, so a canvas that does not care still pages.
    public var onKeyboardStep: ((CGFloat) -> Void)?
    /// Scroll gestures that carry a zoom modifier (Ctrl or ⌘), reported as the same screen-point
    /// delta the plain path would have scrolled by, plus the pointer's view-space Y (top-left
    /// origin) so the shell can keep the point under the pointer still.
    public var onZoomScroll: ((CGFloat, CGFloat) -> Void)?
    /// Trackpad pinch, reported as `NSEvent.magnification` (0.1 = +10%) and the pointer's
    /// view-space Y. Pinch is the one zoom gesture the Accessibility zoom setting cannot take
    /// away from us, because it is not a scroll gesture.
    public var onMagnify: ((CGFloat, CGFloat) -> Void)?
    /// Pointer events, reported in **content points** (the shell's layout space).
    ///
    /// `onPointerDown` is not delivered the moment the button goes down: a press that is released
    /// without moving is a **click** — it follows a reference — and must not start a selection.
    /// See `clickSlopPt`.
    public var onPointerDown: ((CGPoint) -> Void)?
    public var onPointerDragged: ((CGPoint) -> Void)?
    /// The release point and whether the gesture stayed inside the click slop.
    public var onPointerUp: ((CGPoint, Bool) -> Void)?
    /// How far the pointer may travel between press and release and still count as a click, in
    /// view points.
    ///
    /// 3 pt is the drag slop macOS itself uses to tell the two apart (AppKit/WebKit hysteresis is
    /// 3-4 pt): small enough that a reader who means to drag crosses it on the way to the first
    /// character they want, large enough to absorb the point or two a hand moves during a click.
    public static let clickSlopPt: CGFloat = 3
    /// Where the press landed, in view coordinates, while a gesture is in flight.
    private var pressLocation: CGPoint?
    /// Whether the pointer left the click slop: a click follows a reference, a drag selects.
    private var pointerMoved = false
    /// ⌘C.
    public var onCopy: (() -> Void)?
    /// ⌘Z / ⇧⌘Z.
    public var onUndo: (() -> Void)?
    public var onRedo: (() -> Void)?
    /// Horizontal offset of the content inside the viewport, in screen points.
    private var contentOffsetX: CGFloat = 0
    /// Viewport size in screen points, so the shell can compute what is visible.
    public var onViewportSize: ((CGSize) -> Void)?

    /// File drag and drop. The view owns no policy — the shell decides what the dragged URLs mean
    /// (`DocumentOpenCoordinator`), so a drop and the Dock icon end up at the same entry point.
    ///
    /// While a drag is over the view, `onFileDragEntered`/`onFileDragExited` drive the hover
    /// highlight; `onFileDrop` runs when the reader lets go and reports whether anything opened.
    /// With no `onFileDrop` the view is not a drop target at all.
    public var onFileDragEntered: (([URL]) -> FileDropPreview?)?
    public var onFileDragExited: (() -> Void)?
    public var onFileDrop: (([URL]) -> Bool)?
    /// Whether the drag now over the view carries files this view will handle (see
    /// `draggingEntered`).
    private var dragCarriesFiles = false

    /// Builds the right-click menu for a point in content space.
    ///
    /// The view owns no menu policy — the shell decides what is available from the reader's state
    /// (`CanvasContextMenu`) — and `nil` means "nothing to offer here", which leaves AppKit's
    /// default menu unused. The command list is rendered in the shared LyraReader panel and reaches the same
    /// `AppState` commands the toolbar and the Pages menu use.
    public var onContextMenu: ((CGPoint) -> NSMenu?)?

    /// Display-only conversion; changing the profile redraws without uploading source pixels again.
    public var paperAppearance: PaperAppearance = .original {
        didSet {
            guard oldValue != paperAppearance else { return }
            syncAnnotationOverlay()
            markNeedsRender()
        }
    }

    /// The colour the GPU clears to behind transparent texture pixels.
    ///
    /// `nil` keeps the reader canvas colour. The floating preview sets its own card colour for
    /// figure/table crops: their page background is transparent, so whatever the canvas clears
    /// to is what the crop's margin becomes.
    public var canvasClearColor: NSColor? {
        didSet {
            guard oldValue != canvasClearColor else { return }
            markNeedsRender()
        }
    }

    /// Width of the widest page in points; used to centre narrow documents.
    public var contentWidthPt: CGFloat = 0 {
        didSet {
            guard contentWidthPt != oldValue else { return }
            syncAnnotationOverlay()
            markNeedsRender()
        }
    }

    /// Zoom factor as the canvas draws with it: `percent/100 × display calibration`.
    ///
    /// 1.0 is therefore not "100%" in general — it means 72 physical dpi. At 100% on a display
    /// whose logical density is 108.5 ppi this is ≈1.507 (see ``DisplayCalibration``).
    public var zoom: CGFloat = 1.0 {
        didSet {
            guard zoom != oldValue else { return }
            syncAnnotationOverlay()
            markNeedsRender()
        }
    }

    private var surfaceId: UInt64 = 0
    /// One texture per page, with the generation it was uploaded from.
    private var textures: [Int: (generation: UInt64, id: UInt64)] = [:]
    package var residentTextureIDs: [Int: UInt64] { textures.mapValues(\.id) }
    /// Whether to print what this view submits (`LYRA_READER_CANVAS_DUMP=1`).
    ///
    /// A quad's `placement.index` is the key its texture is cached under, so **two quads sharing
    /// one index in a single frame is always a bug**: the later upload replaces the earlier
    /// bitmap, and the first quad is then drawn with the other one's pixels. That is how a
    /// page-sized preview backdrop once came out as a full-page wash of the first highlight's
    /// colour, so the dump prints — per submitted quad — the index, the device rectangle, the
    /// texture and generation it resolved to, the bitmap behind it and the blend it is drawn
    /// with, plus any index claimed twice in one frame. Off unless the variable is set, and
    /// bounded to the frames whose quad list differs from the last one dumped.
    private let canvasDumpEnabled =
        ProcessInfo.processInfo.environment["LYRA_READER_CANVAS_DUMP"] == "1"
    private var dumpedQuadLists = 0
    private var lastDumpedQuadList = ""
    private var reportedIndexCollisions: Set<Int> = []
    private var pendingFrame: DispatchWorkItem?
    private var frameEpoch: UInt64 = 0
    private var wheelMotion = WheelMotion()
    /// Whether the scroll gesture in flight is a zoom (a modifier was down when it began).
    private var gestureIsZoom = false
    /// Reads the just-updated model during AppKit event tracking, before SwiftUI commits:
    /// pages, scroll offset in content points, and zoom factor.
    public var interactionSnapshot: (() -> ([CanvasPage], CGFloat, CGFloat))?

    private func syncInteraction() {
        if let snapshot = interactionSnapshot?() {
            pages = snapshot.0
            scrollYPt = snapshot.1
            zoom = snapshot.2
        }
        if needsRender {
            needsRender = false
            renderFrame()
        }
    }
    private var configuredSize: CGSize = .zero
    private var reportedDeviceScale: CGFloat = 0
    /// The last calibration sent to the shell, so a redundant screen notification does not
    /// rebuild the band. Factor equality is what matters; the reason only changes on fallback.
    private var reportedDisplayCalibration: DisplayCalibration?
    /// Observers for the window's screen and for display-mode changes. Removed and re-added when
    /// the view changes window (`viewDidMoveToWindow` runs more than once for one window).
    private var screenObservers: [NSObjectProtocol] = []
    private var needsRender = true
    private var framesRendered: UInt64 = 0
    /// Native regression checks observe successful submissions without the HUD's throttle.
    package var submittedFrameCount: UInt64 { framesRendered }
    /// Page quads in the most recent frame the GPU accepted (`nil` before the first one).
    ///
    /// `0` is a real, observable frame: the background with nothing drawn over it. A check can
    /// wait for `submittedFrameCount` to advance after the last tab closes and then require this
    /// to be zero, which catches the regression where the model empties but the old page stays
    /// on screen because no new frame was submitted.
    package private(set) var lastSubmittedQuadCount: Int?
    /// Pyramid-tile quads in the most recent frame the GPU accepted (`nil` before the first one).
    ///
    /// Tile placements are the only positive indices the canvas draws (`PlacementIndex` gives
    /// every overlay a negative block), so this is the exact "tiles per frame" the panel reports.
    package private(set) var lastSubmittedTileCount: Int?
    /// Frames this view has handed to the engine, whether or not the WindowServer allowed the
    /// surface to present them.
    ///
    /// Presentation depends on the environment, not on the reader: another app's window in
    /// front, a full-screen Space, or an inactive display makes wgpu report the surface as
    /// occluded and skip the present. The submission still runs and is exactly what replaces a
    /// stale drawable, so checks observe this counter when presentation is not observable.
    package private(set) var frameAttemptCount: UInt64 = 0
    /// Page quads in the most recent frame handed to the engine, presented or not. `0` means the
    /// submission was a clearing frame: the background with nothing drawn over it.
    package private(set) var lastAttemptedQuadCount: Int?
    /// Whether this view's layer is attached to an engine surface. Checks use it where they
    /// cannot ask for a presented frame (an occluded window never presents).
    package var hasAttachedSurface: Bool { surfaceId != 0 }
    private let traceFrames = ProcessInfo.processInfo.environment["LYRA_READER_SCROLL_TRACE_SECONDS"] != nil
    private let traceScheduling = ProcessInfo.processInfo.environment["LYRA_READER_SCROLL_TRACE_SCHEDULING"] == "1"

    public override func makeBackingLayer() -> CALayer {
        let metalLayer = traceFrames ? PresentationTraceLayer() : CAMetalLayer()
        // Same device as wgpu's adapter (see the class comment).
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.isOpaque = true
        // wgpu's Metal backend waits until the command buffer is scheduled before presenting
        // transaction-backed drawables. This keeps the paper and its AppKit edge/shadow layers
        // in one Core Animation presentation during scrollbar tracking.
        metalLayer.presentsWithTransaction = true
        return metalLayer
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        // Files dragged in from Finder, the Dock or a browser download shelf (T2.12).
        registerForDraggedTypes(Self.fileDropTypes)
        // Ink and shapes are vector overlays above the Metal surface: a `CAShapeLayer` path is
        // re-used across zoom and scroll, and the live pen is updated from the pointer event
        // itself rather than through a SwiftUI pass.
        let chrome = PageChromeOverlayView(frame: bounds)
        chrome.autoresizingMask = [.width, .height]
        addSubview(chrome)
        pageChrome = chrome
        let overlay = AnnotationOverlayView(frame: bounds)
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        annotationOverlay = overlay
        let translations = TranslationOverlayView(frame: bounds)
        translations.autoresizingMask = [.width, .height]
        translations.onToggle = { [weak self] id in self?.onTranslationToggle?(id) }
        translations.onCancel = { [weak self] id in self?.onTranslationCancel?(id) }
        addSubview(translations)
        translationOverlay = translations
        let marquee = AIRegionMarqueeOverlayView(frame: bounds)
        marquee.autoresizingMask = [.width, .height]
        addSubview(marquee)
        regionMarquee = marquee
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("MetalCanvasView only supports programmatic creation")
    }

    isolated deinit {
        pendingFrame?.cancel()
        removeScreenObservers()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeScreenObservers()
        if window == nil {
            detachSurface()
        } else {
            if annotationTool == .eraser { window?.acceptsMouseMovedEvents = true }
            installScreenObservers()
            attachSurfaceIfNeeded()
            // `attachSurfaceIfNeeded` reports it too, but a view added to an already-attached
            // surface skips that path; one call here keeps the first report unconditional.
            reportDisplayCalibration()
        }
    }

    /// The window can move between displays and the display mode can change (a different
    /// "looks like" resolution on the same panel), and both change the calibration while the
    /// reader's zoom percentage stays put.
    private func installScreenObservers() {
        guard let window else { return }
        let center = NotificationCenter.default
        screenObservers.append(center.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportDisplayCalibration() }
        })
        screenObservers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportDisplayCalibration() }
        })
        screenObservers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let clip = note.object as? NSClipView else { return }
            let identifier = ObjectIdentifier(clip)
            MainActor.assumeIsolated {
                guard let self, let parentClip = self.enclosingScrollView?.contentView,
                      identifier == ObjectIdentifier(parentClip) else { return }
                self.markNeedsRender()
            }
        })
    }

    private func removeScreenObservers() {
        for observer in screenObservers { NotificationCenter.default.removeObserver(observer) }
        screenObservers.removeAll()
    }

    // MARK: - Pointer hover (eraser indication)

    /// The eraser shows which stroke a press would remove, so pointer movement matters only
    /// while it is armed. `.inVisibleRect` keeps the area correct across scrolling and resizing.
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        guard annotationTool == .eraser, !eraserGestureActive else {
            super.mouseMoved(with: event)
            return
        }
        onEraserHover?(contentPoint(for: event))
    }

    public override func mouseExited(with event: NSEvent) {
        if annotationTool == .eraser, !eraserGestureActive { onEraserHover?(nil) }
        super.mouseExited(with: event)
    }

    /// The crosshair is a real cursor rect: it appears over the whole canvas while the region
    /// tool is armed and disappears with it, without a global cursor push that could leak.
    public override func resetCursorRects() {
        super.resetCursorRects()
        if regionSelectionArmed {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        syncPageChrome()
        markNeedsRender()
    }

    public override func layout() {
        super.layout()
        pageChrome?.frame = bounds
        annotationOverlay?.frame = bounds
        translationOverlay?.frame = bounds
        regionMarquee?.frame = bounds
        syncAnnotationOverlay()
        resizeSurfaceIfNeeded()
        onViewportSize?(bounds.size)
    }

    // MARK: - File drag and drop (T2.12)

    /// The pasteboard types this view accepts as an open request.
    ///
    /// `public.file-url` is what Finder and the Dock hand over; the legacy
    /// `NSFilenamesPboardType` array is still sent by older drag sources, and costs one entry (the
    /// constant is written out rather than referenced, so the build stays free of a deprecation
    /// warning for an API that is still the only way to read those senders).
    public static let fileDropTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        NSPasteboard.PasteboardType("NSFilenamesPboardType"),
    ]

    /// The file URLs a drag is carrying, in pasteboard order, with duplicates removed.
    public static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        for item in pasteboard.pasteboardItems ?? [] {
            if let raw = item.string(forType: .fileURL), let url = URL(string: raw) {
                urls.append(url)
            }
        }
        if urls.isEmpty,
           let paths = pasteboard.propertyList(
               forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
           ) as? [String] {
            urls = paths.map { URL(fileURLWithPath: $0) }
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// A drag entered the canvas carrying files. Accepted whenever it carries at least one file
    /// URL — including files that will be *refused* on drop, because a refusal the reader cannot
    /// see is the failure mode this replaces: the shell gets to say why, and the cursor shows the
    /// refusal is coming. A drag with no file behind it (text, an image promise) is not our
    /// business and returns `[]`.
    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = Self.fileURLs(from: sender.draggingPasteboard)
        dragCarriesFiles = !urls.isEmpty && onFileDrop != nil
        guard dragCarriesFiles else { return [] }
        // Once per drag: the shell's preview stats the files, and a pasteboard cannot change
        // while the drag is in flight.
        _ = onFileDragEntered?(urls)
        return .copy
    }

    /// AppKit calls this on every pointer move inside the view, so it answers from the decision
    /// `draggingEntered` already made instead of probing the files again.
    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragCarriesFiles ? .copy : []
    }

    /// The drag left the canvas (or was cancelled): drop the highlight with it.
    public override func draggingExited(_ sender: NSDraggingInfo?) {
        dragCarriesFiles = false
        onFileDragExited?()
    }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragCarriesFiles
    }

    /// The reader let go: hand the URLs to the shell, which opens what it can and reports what it
    /// cannot. Returning `false` means nothing was opened; the shell has already said so.
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(from: sender.draggingPasteboard)
        dragCarriesFiles = false
        onFileDragExited?()
        guard !urls.isEmpty else { return false }
        return onFileDrop?(urls) ?? false
    }

    /// AppKit's final callback, whether or not the drop was accepted; clearing here as well means
    /// the highlight cannot survive a drag that ends in an unexpected way.
    public override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        dragCarriesFiles = false
        onFileDragExited?()
    }

    // MARK: - Scrolling and keyboard

    /// Self-managed scrolling (decision T1.4): `NSScrollView` would size its document view
    /// to the whole document, and a `CAMetalLayer` cannot be hundreds of thousands of
    /// pixels tall. AppKit still delivers the trackpad's momentum as scroll events.
    ///
    /// A scroll carrying Ctrl or ⌘ zooms instead (the *whole* gesture: see `gestureIsZoom`).
    /// The two actions stay mutually exclusive, so holding a modifier can never scroll *and*
    /// zoom on the same event. Known system-level conflict: Accessibility ▸ Zoom ▸ "Use scroll
    /// gesture with modifier keys to zoom" makes the system swallow the configured modifier
    /// before AppKit sees the event at all — see `AppState.zoomByScroll` for what still works.
    public override func scrollWheel(with event: NSEvent) {
        // NSEvent already applies the user's natural-scrolling preference. Convert
        // content motion to a top-origin offset exactly once; never invert by device.
        let delta = wheelMotion.delta(
            scrollingDeltaY: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas,
            timestamp: event.timestamp
        )
        guard delta != 0 else { return }

        let modifierZoom = event.modifierFlags.contains(.control)
            || event.modifierFlags.contains(.command)
        // Momentum events are synthesised by the trackpad driver and are not guaranteed to carry
        // the modifier that started the gesture. Zooming the finger-driven half of a flick and
        // scrolling its momentum half would be worse than either, so the whole gesture keeps the
        // decision its first event made.
        if event.phase == .began { gestureIsZoom = modifierZoom }
        if event.phase == .cancelled || event.momentumPhase == .ended { gestureIsZoom = false }
        let zooming = modifierZoom || (event.momentumPhase != [] && gestureIsZoom)

        if zooming {
            onZoomScroll?(delta, pointerViewY(for: event))
        } else if event.hasPreciseScrollingDeltas || event.momentumPhase != [] {
            // A trackpad (and a Magic Mouse) reports the distance the fingers travelled, already
            // animated, including the momentum the system synthesises after they lift. Applying
            // it 1:1 is what keeps the content under the fingers; gliding it here would be the
            // same gesture applied twice.
            onScroll?(delta)
        } else {
            // Apply the cadence-scaled distance now; wheel input must leave no animation debt.
            onScrollStep?(delta)
        }
        syncInteraction()
    }

    /// Pinch to zoom, anchored at the pointer like the scroll form (`docs/04-ui-ux.md` §3).
    ///
    /// A canvas without a handler (the preview panel's) forwards the gesture instead of
    /// swallowing it.
    public override func magnify(with event: NSEvent) {
        guard event.magnification != 0, let onMagnify else {
            super.magnify(with: event)
            return
        }
        onMagnify(event.magnification, pointerViewY(for: event))
        syncInteraction()
    }

    /// The pointer in view space (top-left origin), the frame the zoom anchor is expressed in.
    private func pointerViewY(for event: NSEvent) -> CGFloat {
        let point = convert(event.locationInWindow, from: nil)
        return bounds.height - point.y
    }

    public override var acceptsFirstResponder: Bool { true }

    // MARK: - Context menu

    /// AppKit asks for this when the reader right-clicks. The point is converted to the same
    /// content space selection and link hit-testing use, so a command in the menu acts on exactly
    /// the thing under the pointer.
    public override func menu(for event: NSEvent) -> NSMenu? {
        guard let onContextMenu else { return super.menu(for: event) }
        guard let menu = onContextMenu(contentPoint(for: event)), let window else { return nil }
        LyraReaderMenuPresenter.shared.show(menu: menu, at: window.convertPoint(toScreen: event.locationInWindow),
                                      in: window, owner: self)
        return nil
    }

    // MARK: - Pointer

    /// Converts an event location into content points (origin at the first page's top-left,
    /// one unit per PDF point, independent of the zoom), which is the space the shell thinks in.
    private func contentPoint(for event: NSEvent) -> CGPoint {
        contentPoint(forViewPoint: convert(event.locationInWindow, from: nil))
    }

    /// The same conversion for a point already in view coordinates (bottom-left origin), which is
    /// what the press location is stored as.
    ///
    /// `zoom` is `AppState.zoomFactor`, calibration included, so the inverse keeps the page
    /// coordinate under the pointer the same at every display density.
    private func contentPoint(forViewPoint point: CGPoint) -> CGPoint {
        let fromTop = CGPoint(x: point.x, y: bounds.height - point.y)
        return CanvasGeometry.contentPoint(
            viewX: fromTop.x,
            viewYTop: fromTop.y,
            scrollYPt: scrollYPt,
            zoom: zoom,
            contentOffsetX: contentOffsetX
        )
    }

    /// The page under a content point and the point in that page's top-left space.
    ///
    /// `annotationPageFrames` are display **segments**: an untorn page contributes one, a torn
    /// page two. The conversion subtracts the segment's top and adds its page-local offset, so a
    /// click below the tear still names the same page point it would without the card.
    private func pageLocalPoint(atContent point: CGPoint) -> (page: Int, point: CGPoint,
                                                              frame: PagePlacement)? {
        for frame in annotationPageFrames {
            let rect = CGRect(x: frame.leftPt, y: frame.topPt,
                              width: frame.widthPt, height: frame.heightPt)
            guard rect.contains(point) else { continue }
            return (
                frame.index,
                CGPoint(
                    x: point.x - frame.leftPt,
                    y: point.y - frame.topPt + frame.sourceTopPt
                ),
                frame
            )
        }
        return nil
    }

    /// The page-local point under `content` on one page, or nil in the card's gap.
    private func pageLocalPoint(atContent point: CGPoint,
                                page: Int) -> (point: CGPoint, frame: PagePlacement)? {
        for frame in annotationPageFrames where frame.index == page {
            let rect = CGRect(x: frame.leftPt, y: frame.topPt,
                              width: frame.widthPt, height: frame.heightPt)
            guard rect.contains(point) else { continue }
            return (CGPoint(x: point.x - frame.leftPt,
                            y: point.y - frame.topPt + frame.sourceTopPt), frame)
        }
        return nil
    }

    /// The display segments of one page, in reading order.
    private func pageSegments(_ page: Int) -> [PagePlacement] {
        annotationPageFrames.filter { $0.index == page }
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        wheelMotion.reset()
        pressLocation = convert(event.locationInWindow, from: nil)
        pointerMoved = false
        let content = contentPoint(for: event)
        annotationDoubleClickConsumed = false

        // The region marquee owns the gesture while it is armed. It is checked before every
        // other path so a text handle, a mark or a drawing tool can never start underneath it.
        if regionSelectionArmed {
            beginRegionGesture(atContent: content)
            return
        }

        // A Fill & Sign placement claims the click before every other pointer path. It is not a
        // tool: a drag with it armed is still inert, and only a press that stays inside the
        // click slop commits the mark.
        if fillSignPlacementPending {
            fillSignPlacementPressPending = true
            return
        }

        // A double-click on a placed text annotation opens its editor. It is decided before the
        // ordinary press paths so the second press of the pair cannot start a move.
        if annotationTool == .select, event.clickCount == 2,
           onAnnotationDoubleClick?(content) == true {
            annotationDoubleClickConsumed = true
            return
        }

        // The eraser owns the gesture from press to release, exactly like the pen. It erases on
        // the press as well as on the drag: the hover halo has already shown which stroke that
        // press will remove, so touching the eraser down on ink behaves like touching an eraser
        // to paper. Nothing about text selection or mark selection runs in this mode.
        if annotationTool == .eraser {
            eraserGestureActive = true
            eraserLastContentPoint = content
            onEraserHover?(nil)
            onEraseGestureBegan?(content)
            return
        }

        // The sticky-note tool places on a click. Waiting for mouse-up is what lets a press that
        // turns into a drag be ignored instead of leaving a note wherever the hand twitched.
        if annotationTool.placesNote {
            notePlacementPending = true
            return
        }

        // A stamp or a signature picture is placed on a click, like a sticky note. The model owns
        // the default size, the clamping to the page and the undo step.
        if annotationTool.placesStamp {
            stampPlacementPending = true
            return
        }
        if annotationTool.placesSignature {
            signaturePlacementPending = true
            return
        }

        // The text-box tool places on a double-click, not by dragging a rectangle. The first
        // press of the pair does nothing; the second creates the one-line box at the click (or
        // reopens the box already there) and opens its editor with the caret at that point.
        // Holding the press for release keeps a drag with the tool armed inert.
        if annotationTool.placesTextBox {
            textBoxPlacementPending = true
            if event.clickCount == 2 {
                _ = onPlaceTextBox?(content)
            }
            return
        }

        // A drawing tool owns the gesture from press to release. The live preview lives entirely
        // inside the overlay: nothing reaches AppState until mouse-up.
        if annotationTool.draws, let kind = annotationTool.kind,
           let hit = pageLocalPoint(atContent: content) {
            drawingPage = hit.page
            drawingKind = kind
            annotationOverlay?.beginLiveStroke(kind: kind, page: hit.page, at: hit.point)
            return
        }

        // Selecting a mark is decided on the press, not after the drag slop: the mark is what
        // the reader aimed at, and waiting would let the text under it start a text selection.
        // Only an editable mark (one in the annotation cache) qualifies.
        if annotationTool == .select,
           annotationOverlay?.hitTestMark(atContentPoint: content,
                                         toleranceViewPt: AnnotationGeometry.hitTolerancePt) != nil {
            annotationSelectGesture = true
            onPointerDown?(content)
            return
        }

        // Text selection waits: see `clickSlopPt`. Nothing about the model changes until the
        // pointer has moved far enough to mean a drag.
        syncInteraction()
    }

    public override func mouseDragged(with event: NSEvent) {
        if regionGestureActive {
            extendRegionGesture(toContent: contentPoint(for: event))
            return
        }
        if eraserGestureActive {
            let content = contentPoint(for: event)
            let previous = eraserLastContentPoint ?? content
            eraserLastContentPoint = content
            onEraseGestureDragged?(previous, content)
            syncInteraction()
            return
        }
        if notePlacementPending {
            let location = convert(event.locationInWindow, from: nil)
            if hypot(location.x - (pressLocation?.x ?? location.x),
                     location.y - (pressLocation?.y ?? location.y)) > Self.clickSlopPt {
                pointerMoved = true
            }
            return
        }
        if fillSignPlacementPressPending {
            let location = convert(event.locationInWindow, from: nil)
            if hypot(location.x - (pressLocation?.x ?? location.x),
                     location.y - (pressLocation?.y ?? location.y)) > Self.clickSlopPt {
                pointerMoved = true
            }
            return
        }
        if textBoxPlacementPending {
            // Dragging with the text-box tool armed is deliberately not a gesture: it neither
            // creates a rectangle nor starts a text selection.
            return
        }
        if drawingKind != nil, drawingPage != nil {
            annotationOverlay?.extendLiveStroke(atContentPoint: contentPoint(for: event))
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        guard pointerMoved
            || hypot(location.x - (pressLocation?.x ?? location.x),
                     location.y - (pressLocation?.y ?? location.y)) > Self.clickSlopPt
        else {
            // Still a click as far as anyone can tell: leave the selection alone and wait.
            syncInteraction()
            return
        }
        if !pointerMoved {
            pointerMoved = true
            // The anchor is where the press landed, not where the threshold was crossed: the
            // reader aims at the character they pressed on. A mark selection already sent its
            // press (so AppState's move began there); only text selection needs this anchor.
            if !annotationSelectGesture, let press = pressLocation {
                onPointerDown?(contentPoint(forViewPoint: press))
            }
        }
        onPointerDragged?(contentPoint(for: event))
        syncInteraction()
    }

    public override func mouseUp(with event: NSEvent) {
        if regionGestureActive {
            finishRegionGesture(atContent: contentPoint(for: event))
            pressLocation = nil
            pointerMoved = false
            return
        }
        if regionSelectionArmed {
            // The press missed every page, so no marquee started. Do not fall through to a
            // text selection in the same gesture.
            pressLocation = nil
            pointerMoved = false
            return
        }
        if eraserGestureActive {
            eraserGestureActive = false
            eraserLastContentPoint = nil
            onEraseGestureEnded?()
            pressLocation = nil
            pointerMoved = false
            syncInteraction()
            return
        }
        if annotationDoubleClickConsumed {
            annotationDoubleClickConsumed = false
            pressLocation = nil
            pointerMoved = false
            return
        }
        if fillSignPlacementPressPending {
            fillSignPlacementPressPending = false
            if !pointerMoved {
                _ = onPlaceFillSign?(contentPoint(for: event))
            }
            pressLocation = nil
            pointerMoved = false
            return
        }
        if notePlacementPending {
            notePlacementPending = false
            if !pointerMoved {
                _ = onPlaceStickyNote?(contentPoint(for: event))
            }
            pressLocation = nil
            pointerMoved = false
            return
        }
        if stampPlacementPending {
            stampPlacementPending = false
            if !pointerMoved {
                _ = onPlaceStamp?(contentPoint(for: event))
            }
            pressLocation = nil
            pointerMoved = false
            return
        }
        if signaturePlacementPending {
            signaturePlacementPending = false
            if !pointerMoved {
                _ = onPlaceSignature?(contentPoint(for: event))
            }
            pressLocation = nil
            pointerMoved = false
            return
        }
        if textBoxPlacementPending {
            textBoxPlacementPending = false
            pressLocation = nil
            pointerMoved = false
            return
        }
        if drawingKind != nil {
            let draft = annotationOverlay?.finishLiveStroke(in: annotationPageFrames)
            drawingKind = nil
            drawingPage = nil
            if let draft { onAnnotationDraft?(draft) }
            pressLocation = nil
            pointerMoved = false
            return
        }
        // A press that never left the slop is a click even if the release lands a little off it.
        onPointerUp?(contentPoint(for: event), !pointerMoved)
        pressLocation = nil
        pointerMoved = false
        annotationSelectGesture = false
        syncInteraction()
    }

    // MARK: - Region marquee

    /// A press with the region tool armed. Only a press that lands on a page starts a marquee.
    private func beginRegionGesture(atContent point: CGPoint) {
        guard let hit = pageLocalPoint(atContent: point) else { return }
        regionGestureActive = true
        regionGesturePage = hit.page
        regionGestureStart = hit.point
        regionGestureCurrent = hit.point
        updateRegionMarquee()
    }

    private func extendRegionGesture(toContent point: CGPoint) {
        guard regionGestureActive, let page = regionGesturePage,
              let local = regionLocalPoint(atContent: point, page: page)
        else { return }
        regionGestureCurrent = local
        updateRegionMarquee()
    }

    private func finishRegionGesture(atContent point: CGPoint) {
        guard regionGestureActive, let page = regionGesturePage,
              let start = regionGestureStart,
              let local = regionLocalPoint(atContent: point, page: page)
        else {
            cancelRegionGesture()
            return
        }
        let rect = CGRect(
            x: min(start.x, local.x),
            y: min(start.y, local.y),
            width: abs(local.x - start.x),
            height: abs(local.y - start.y)
        )
        let viewRects = CanvasGeometry.viewRects(
            pageSegments: pageSegments(page), region: rect,
            scrollYPt: scrollYPt, zoom: zoom, contentOffsetX: contentOffsetX
        )
        guard var union = viewRects.first else {
            cancelRegionGesture()
            return
        }
        for viewRect in viewRects.dropFirst() { union = union.union(viewRect) }
        cancelRegionGesture()
        guard union.width >= Self.regionMinimumViewPt,
              union.height >= Self.regionMinimumViewPt
        else {
            onRegionSelectionCancelled?(
                "The selected area is too small to ask about. Drag a larger rectangle."
            )
            return
        }
        onRegionSelection?(page, rect)
    }

    /// A page-local point for the marquee, clamped to the page and to the tear when the pointer
    /// is in the card's gap. The marquee is a page rectangle, so its two display pieces are
    /// derived from the same rectangle by `CanvasGeometry.viewRects`.
    private func regionLocalPoint(atContent point: CGPoint, page: Int) -> CGPoint? {
        if let hit = pageLocalPoint(atContent: point, page: page) { return hit.point }
        let segments = pageSegments(page)
        guard !segments.isEmpty else { return nil }
        let first = segments[0]
        let last = segments[segments.count - 1]
        let x = min(max(point.x - first.leftPt, 0), first.widthPt)
        if point.y < first.topPt { return CGPoint(x: x, y: first.sourceTopPt) }
        if point.y > last.topPt + last.heightPt {
            return CGPoint(x: x, y: last.sourceTopPt + last.sourceHeightPt)
        }
        // Inside the gap between the pieces: the page-local answer is the tear itself.
        return CGPoint(x: x, y: first.sourceTopPt + first.sourceHeightPt)
    }

    /// The marquee's minimum on-screen size. Below this a press is a click, not a rectangle.
    static let regionMinimumViewPt: CGFloat = 6

    private func updateRegionMarquee() {
        guard let page = regionGesturePage,
              let start = regionGestureStart,
              let current = regionGestureCurrent
        else {
            regionMarquee?.update(nil)
            return
        }
        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        let viewRects = CanvasGeometry.viewRects(
            pageSegments: pageSegments(page), region: rect,
            scrollYPt: scrollYPt, zoom: zoom, contentOffsetX: contentOffsetX
        )
        var union = viewRects.first ?? .null
        for viewRect in viewRects.dropFirst() { union = union.union(viewRect) }
        regionMarqueeRectForTesting = viewRects.isEmpty ? nil : union
        regionMarquee?.update(rects: viewRects)
    }

    private func cancelRegionGesture() {
        regionGestureActive = false
        regionGesturePage = nil
        regionGestureStart = nil
        regionGestureCurrent = nil
        regionMarqueeRectForTesting = nil
        regionMarquee?.update(nil)
    }

    /// The marquee rectangle in view space while a drag is in flight; nil otherwise.
    package private(set) var regionMarqueeRectForTesting: CGRect?

    /// Drives the same gesture the mouse events drive, in content points. The native checks use
    /// this instead of synthesising AppKit events, so the geometry under test is the shipped one.
    package func simulateRegionGesture(fromContent start: CGPoint, toContent end: CGPoint) {
        beginRegionGesture(atContent: start)
        extendRegionGesture(toContent: end)
        finishRegionGesture(atContent: end)
    }

    /// The same drag without the release, for the marquee evidence screenshot.
    package func simulateRegionDrag(fromContent start: CGPoint, toContent end: CGPoint) {
        beginRegionGesture(atContent: start)
        extendRegionGesture(toContent: end)
    }

    package func simulateRegionRelease(atContent point: CGPoint) {
        finishRegionGesture(atContent: point)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Delete removes the selected ink/shape mark. It is consumed only when there is one, so
        // a Delete meant for a text field still reaches it.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
           event.keyCode == 51 || event.keyCode == 117,
           onDeleteAnnotation?() == true {
            return true
        }
        // ⌘C without a menu item: the canvas is the first responder while reading.
        if event.modifierFlags.contains(.command),
           let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "c":
                onCopy?()
                return true
            case "z":
                // ⇧⌘Z is redo, the convention every macOS app follows.
                if event.modifierFlags.contains(.shift) {
                    onRedo?()
                } else {
                    onUndo?()
                }
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    public override func keyDown(with event: NSEvent) {
        let page = bounds.height * 0.9
        // A page key names a destination, not a speed, so it goes through its own step when the
        // shell has one (AppState.scrollByKeyboardStep) and falls back to the wheel step otherwise.
        let step = onKeyboardStep ?? onScrollStep
        switch event.charactersIgnoringModifiers {
        case "\u{7F}", "\u{8}":
            if onDeleteAnnotation?() == true { return }
            super.keyDown(with: event)
        case "\u{1B}":
            if regionSelectionArmed || regionGestureActive {
                cancelRegionGesture()
                onRegionSelectionCancelled?("Region selection cancelled. Nothing was created.")
                return
            }
            annotationOverlay?.cancelLiveStroke()
            drawingKind = nil
            drawingPage = nil
            notePlacementPending = false
            textBoxPlacementPending = false
            stampPlacementPending = false
            signaturePlacementPending = false
            fillSignPlacementPressPending = false
            if eraserGestureActive {
                eraserGestureActive = false
                eraserLastContentPoint = nil
            }
            // Leaving the eraser (or a sticky markup mode) consumes Escape; the model cancels
            // any eraser gesture in flight when the tool changes.
            if onCancelTool?() == true { return }
            super.keyDown(with: event)
        case " ":
            // Keyboard paging animates to its destination.
            step?(event.modifierFlags.contains(.shift) ? -page : page)
        case "\u{F72D}": // page down
            step?(page)
        case "\u{F72C}": // page up
            step?(-page)
        case "\u{F701}": // down arrow
            step?(40)
        case "\u{F700}": // up arrow
            step?(-40)
        default:
            super.keyDown(with: event)
        }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportDeviceScale()
        // A display-mode change can keep the same backing scale but alter the logical width;
        // the calibration is part of that change too.
        reportDisplayCalibration()
        resizeSurfaceIfNeeded()
        markNeedsRender()
    }

    // MARK: - Surface lifecycle

    private func attachSurfaceIfNeeded() {
        guard surfaceId == 0 else {
            resizeSurfaceIfNeeded()
            return
        }
        guard let metalLayer = layer as? CAMetalLayer else {
            report("backing layer is not a CAMetalLayer")
            return
        }

        let initCode = lyra_reader_gpu_init(0)
        guard initCode == LyraReaderStatus.ok.rawValue else {
            report("lyra_reader_gpu_init failed (\(LyraReaderStatus.describe(initCode)))")
            return
        }

        let (width, height) = pixelSize()
        var newSurfaceId: UInt64 = 0
        let attachCode = lyra_reader_surface_attach(
            Unmanaged.passUnretained(metalLayer).toOpaque(),
            UInt32(width),
            UInt32(height),
            backingScale(),
            &newSurfaceId
        )
        guard attachCode == LyraReaderStatus.ok.rawValue else {
            report("lyra_reader_surface_attach failed (\(LyraReaderStatus.describe(attachCode)))")
            return
        }

        surfaceId = newSurfaceId
        configuredSize = bounds.size
        reportDeviceScale()
        reportDisplayCalibration()
        onViewportSize?(bounds.size)

        syncTextures()
        markNeedsRender()

        // Verification aid for headless runs: macOS reports a window covered by another
        // app as occluded, and wgpu then skips drawing (correct behaviour, but it makes
        // automated checks impossible). Opt in with an env var.
        if ProcessInfo.processInfo.environment["LYRA_READER_SPIKE_FORCE_FRONT"] == "1" {
            window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private func resizeSurfaceIfNeeded() {
        guard surfaceId != 0, bounds.size != configuredSize, bounds.size.width > 0 else { return }
        let (width, height) = pixelSize()
        let code = lyra_reader_surface_resize(surfaceId, UInt32(width), UInt32(height), backingScale())
        if code != LyraReaderStatus.ok.rawValue {
            report("lyra_reader_surface_resize failed (\(LyraReaderStatus.describe(code)))")
            return
        }
        configuredSize = bounds.size
        markNeedsRender()
    }

    private func detachSurface() {
        pendingFrame?.cancel()
        pendingFrame = nil
        frameEpoch &+= 1
        releaseAllTextures()
        guard surfaceId != 0 else { return }
        _ = lyra_reader_surface_detach(surfaceId)
        surfaceId = 0
    }

    // MARK: - Page texture

    private func syncTextures() {
        guard surfaceId != 0 else { return }

        var wanted = Set<Int>()
        var claimed: [Int: UInt64] = [:]
        for page in pages {
            let index = page.placement.index
            if let firstGeneration = claimed[index], firstGeneration != page.image.generation,
               reportedIndexCollisions.insert(index).inserted {
                canvasDump(
                    "index \(index) is claimed by two quads in one frame (generations "
                        + "\(firstGeneration) and \(page.image.generation)); the texture cache is "
                        + "keyed by this index, so one quad draws the other's bitmap")
            }
            claimed[index] = page.image.generation
            wanted.insert(index)
            if textures[index]?.generation == page.image.generation { continue }
            if let stale = textures.removeValue(forKey: index) {
                _ = lyra_reader_gpu_release_texture(stale.id)
            }
            if let id = uploadTexture(page.image) {
                textures[index] = (page.image.generation, id)
            }
        }

        // Release pages that scrolled away; the shell keeps a slightly larger cache, so
        // this only drops what it no longer hands us.
        for index in textures.keys where !wanted.contains(index) {
            if let stale = textures.removeValue(forKey: index) {
                _ = lyra_reader_gpu_release_texture(stale.id)
            }
        }
    }

    private func uploadTexture(_ image: PageImage) -> UInt64? {
        var newTextureId: UInt64 = 0
        let code: Int32 = image.bgra.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return LyraReaderStatus.invalidArgument.rawValue
            }
            return lyra_reader_gpu_upload_texture(
                UInt32(image.pixelWidth),
                UInt32(image.pixelHeight),
                base,
                raw.count,
                &newTextureId
            )
        }
        guard code == LyraReaderStatus.ok.rawValue else {
            report("lyra_reader_gpu_upload_texture failed (\(LyraReaderStatus.describe(code)))")
            return nil
        }
        return newTextureId
    }

    private func releaseAllTextures() {
        for (_, texture) in textures {
            _ = lyra_reader_gpu_release_texture(texture.id)
        }
        textures.removeAll()
    }

    // MARK: - Frame loop

    private func markNeedsRender() {
        needsRender = true
        scheduleFrame()
    }

    /// Coalesce model/texture updates into one main-queue job. Run-loop timers can
    /// stall while main-actor input continues, leaving a dirty canvas undisplayed.
    /// Metal's FIFO surface still controls actual presentation; idle views enqueue nothing.
    private func scheduleFrame(after delay: TimeInterval = 0) {
        guard surfaceId != 0, pendingFrame == nil else { return }
        let epoch = frameEpoch
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.frameEpoch == epoch else { return }
                self.pendingFrame = nil
                guard self.needsRender, self.surfaceId != 0 else { return }
                if self.traceScheduling, let snapshot = self.interactionSnapshot?() {
                    let line = "lyra-reader-scroll-trace: {\"kind\":\"frame_job\",\"time\":\(ProcessInfo.processInfo.systemUptime),\"y\":\(self.scrollYPt),\"model_y\":\(snapshot.1)}\n"
                    FileHandle.standardError.write(Data(line.utf8))
                }
                self.needsRender = false
                self.renderFrame()
            }
        }
        pendingFrame = work
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func renderFrame() {
        guard surfaceId != 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // Borders and paper quads must use the same submitted scroll position. Publishing
        // borders from a setter moved the gap a frame ahead of Metal during scrollbar tracking.
        syncPageChrome()

        // Every visible page goes into one frame; the shell only hands us pages it has
        // already rasterized, so an empty list simply means "nothing to draw yet".
        let scale = backingScale()
        let (surfaceWidth, _) = pixelSize()
        // Centre the document horizontally when it is narrower than the viewport, which
        // is the normal case for a maximised window.
        let contentWidthPx = contentWidthPt * zoom * scale
        let offsetX = max(0, (CGFloat(surfaceWidth) - contentWidthPx) / 2)
        contentOffsetX = offsetX / scale
        regionHost.sync(size: bounds.size, viewport: visibleRect, scroll: scrollYPt, zoom: zoom)

        var textureIds: [UInt64] = []
        var rects: [Float] = []
        var sources: [Float] = []
        var blends: [UInt8] = []
        var submitted: [String] = []
        var tileQuadCount = 0
        for page in pages {
            guard let texture = textures[page.placement.index] else { continue }
            // Tiles are the only positive placement block (`PlacementIndex`); this is what the
            // performance panel calls "tiles per frame".
            if page.placement.index >= 0 { tileQuadCount += 1 }
            // `zoom` already includes the display calibration; `scale` is the backing scale.
            // This shared helper is the only place the two are multiplied for a page quad, so
            // calibration cannot be applied a second time here.
            let quad = CanvasGeometry.pageRectInDevicePixels(
                pageTopPt: page.placement.topPt,
                pageLeftPt: page.placement.leftPt,
                widthPt: page.placement.widthPt,
                heightPt: page.placement.heightPt,
                scrollYPt: scrollYPt,
                zoom: zoom,
                backingScale: scale,
                contentOffsetXPx: offsetX
            )
            let x = quad.minX
            let y = quad.minY
            let width = quad.width
            let height = quad.height
            textureIds.append(texture.id)
            rects.append(Float(x))
            rects.append(Float(y))
            rects.append(Float(width))
            rects.append(Float(height))
            // A torn page gives two quads the same texture with complementary source
            // rectangles. The whole-page case is (0, 0, 1, 1).
            sources.append(Float(page.source.minX))
            sources.append(Float(page.source.minY))
            sources.append(Float(page.source.maxX))
            sources.append(Float(page.source.maxY))
            // A page is painted over the background; a highlight loaded from a PDF is usually
            // stored `/BM /Multiply` and has to multiply into the page under it.
            blends.append(page.blend.rawValue)
            if canvasDumpEnabled {
                // The 1x1 tints are the ones whose bytes say what colour a highlight is drawn in;
                // a real bitmap is reported by its size instead.
                let pixels = page.image.pixelWidth == 1 && page.image.pixelHeight == 1
                    ? " tint=\(Self.hex(page.image.bgra))"
                    : ""
                let source = page.source == CGRect(x: 0, y: 0, width: 1, height: 1)
                    ? ""
                    : " source=(\(page.source.minX),\(page.source.minY))"
                        + "(\(page.source.width)x\(page.source.height))"
                submitted.append(
                    "idx=\(page.placement.index) tex=\(texture.id) gen=\(texture.generation) "
                        + "rect=(\(Int(x.rounded())),\(Int(y.rounded())) "
                        + "\(Int(width.rounded()))x\(Int(height.rounded())))px "
                        + "bitmap=\(page.image.pixelWidth)x\(page.image.pixelHeight)"
                        + "\(source)\(pixels) blend=\(page.blend)")
            }
        }

        if canvasDumpEnabled, !submitted.isEmpty, dumpedQuadLists < 20 {
            let signature = submitted.joined(separator: "|")
            if signature != lastDumpedQuadList {
                lastDumpedQuadList = signature
                dumpedQuadLists += 1
                canvasDump(
                    "frame \(dumpedQuadLists): \(submitted.count) quad(s) submitted "
                        + "(scroll \(Int(scrollYPt))pt, zoom \(Int((zoom * 100).rounded()))%, "
                        + "scale \(scale))")
                for line in submitted { canvasDump("  \(line)") }
            }
        }

        // No `guard !textureIds.isEmpty else { return }` here on purpose. A frame with zero
        // quads is still a frame: the Rust side clears the surface to the reading background
        // and presents it. Skipping the submission is what left the last drawn document on
        // screen behind the empty state when its last tab closed, because a `CAMetalLayer`
        // keeps showing the last drawable until another one is presented.
        if let traceLayer = layer as? PresentationTraceLayer {
            traceLayer.traceSurface = surfaceId
            traceLayer.traceY = Double(scrollYPt)
        }
        let clear = canvasClearColor.map {
            LyraReaderTheme.clearComponents(of: $0, appearance: effectiveAppearance)
        } ?? LyraReaderTheme.canvasClear(appearance: effectiveAppearance)
        var stats = LyraReaderFrameStats()
        let code: Int32 = textureIds.withUnsafeBufferPointer { ids in
            rects.withUnsafeBufferPointer { rectangles in
                sources.withUnsafeBufferPointer { sourceRects in
                    blends.withUnsafeBufferPointer { modes in
                        lyra_reader_surface_draw_pages_with_appearance_uv(
                            surfaceId,
                            ids.baseAddress,
                            rectangles.baseAddress,
                            sourceRects.baseAddress,
                            modes.baseAddress,
                            textureIds.count,
                            clear[0], clear[1], clear[2], paperAppearance.code,
                            &stats
                        )
                    }
                }
            }
        }
        guard code == LyraReaderStatus.ok.rawValue else {
            report("lyra_reader_surface_draw_pages failed (\(LyraReaderStatus.describe(code)))")
            return
        }

        if traceFrames {
            let now = ProcessInfo.processInfo.systemUptime
            let sequence = (layer as? PresentationTraceLayer)?.traceSequence ?? 0
            let line = "lyra-reader-scroll-trace: {\"kind\":\"frame\",\"time\":\(now),\"surface\":\(surfaceId),\"sequence\":\(sequence),\"presented\":\(stats.presented),\"cpu_us\":\(stats.elapsed_us),\"y\":\(scrollYPt)}\n"
            FileHandle.standardError.write(Data(line.utf8))
        }

        // Count the submission before presentation is decided: an occluded window still runs
        // this path, and the emitted frame (with its quad count) is what replaces a stale
        // drawable once the window can present again.
        frameAttemptCount += 1
        lastAttemptedQuadCount = textureIds.count

        if stats.presented == 0 {
            // The window is occluded (minimised, hidden, or covered by another app): wgpu
            // deliberately skips the draw. The frame loop retries at a low rate.
            recordPerformanceSample(
                stats: stats, presented: false, tileQuadCount: tileQuadCount, quadCount: textureIds.count)
            needsRender = true
            scheduleFrame(after: 0.133)
            return
        }

        framesRendered += 1
        // Recorded only for frames the surface actually presented, so it pairs with
        // `submittedFrameCount`: together they say "a new frame reached the screen, and it had
        // this many page quads".
        lastSubmittedQuadCount = textureIds.count
        lastSubmittedTileCount = tileQuadCount
        recordPerformanceSample(
            stats: stats, presented: true, tileQuadCount: tileQuadCount, quadCount: textureIds.count)
        if framesRendered == 1 || framesRendered % 15 == 0 {
            onFrame?(stats)
        }
    }

    /// Hands one frame to the performance probe, but only when it asked for samples.
    ///
    /// The nil/bool check is the entire closed-panel cost on the frame path; the sample value
    /// (a POD struct) is not constructed unless a probe is sampling or the one-shot
    /// open-to-first-frame measurement is pending.
    private func recordPerformanceSample(
        stats: LyraReaderFrameStats, presented: Bool, tileQuadCount: Int, quadCount: Int
    ) {
        guard let probe = performanceProbe, probe.wantsFrameSamples else { return }
        probe.record(CanvasFrameSample(
            presented: presented,
            elapsedMicroseconds: stats.elapsed_us,
            tileQuadCount: tileQuadCount,
            quadCount: quadCount,
            surfaceFrameIndex: stats.surface_frame_index
        ))
    }

    /// Hands the current marks, page frames and view transform to the overlay.
    ///
    /// Called from every setter that changes the view mapping and from the event path after a
    /// live gesture. The overlay owns the actual layer tree; this method contains no drawing.
    private func syncPageChrome() {
        pageChrome?.update(frames: annotationPageFrames, contentWidthPt: contentWidthPt,
                           zoom: zoom, scrollYPt: scrollYPt, scale: backingScale())
    }

    private func syncAnnotationOverlay() {
        guard let overlay = annotationOverlay else { return }
        let color = annotationColor.nsColor
        overlay.update(
            marks: annotationMarks,
            frames: annotationPageFrames,
            zoom: zoom,
            scrollYPt: scrollYPt,
            contentWidthPt: contentWidthPt,
            color: color,
            strokeWidth: annotationStrokeWidth,
            themeColor: NSColor.controlAccentColor,
            paperAppearance: paperAppearance
        )
        syncTranslationOverlay()
    }

    /// Hands the translation model to its own layer. It is separate from the annotation overlay
    /// so hiding a translation cannot disturb a mark, and so the chip can take a click without
    /// giving the annotation layer pointer ownership.
    private func syncTranslationOverlay() {
        translationOverlay?.update(
            overlays: translationOverlays,
            frames: annotationPageFrames,
            zoom: zoom,
            scrollYPt: scrollYPt,
            contentWidthPt: contentWidthPt,
            paperAppearance: paperAppearance,
            paperColors: translationPaperColors
        )
    }

    // MARK: - Geometry

    private func backingScale() -> CGFloat {
        window?.backingScaleFactor ?? 2.0
    }

    private func reportDeviceScale() {
        let scale = backingScale()
        guard scale != reportedDeviceScale else { return }
        reportedDeviceScale = scale
        onDeviceScale?(scale)
    }

    /// Reports the display's calibration once per distinct value.
    ///
    /// Called from `viewDidMoveToWindow` (first attach), `viewDidChangeBackingProperties`
    /// (backing-store changes, including a move to a display with another scale), the window's
    /// `didChangeScreen` notification and the application's screen-parameters notification
    /// (display mode changes). The closure is also the only place that knows the shell exists;
    /// this view never computes a zoom itself.
    private func reportDisplayCalibration() {
        let calibration = DisplayCalibration.forScreen(window?.screen)
        guard calibration != reportedDisplayCalibration else { return }
        reportedDisplayCalibration = calibration
        FileHandle.standardError.write(Data(calibration.diagnosticLine.utf8))
        onDisplayCalibration?(calibration)
    }

    private func pixelSize() -> (Int, Int) {
        let scale = backingScale()
        return (
            max(1, Int((bounds.width * scale).rounded())),
            max(1, Int((bounds.height * scale).rounded()))
        )
    }

    private func report(_ message: String) {
        NSLog("LyraReader canvas: %@", message)
        onFailure?(message)
    }

    /// A diagnostic line for `LYRA_READER_CANVAS_DUMP=1`, on stderr like every other `lyra-reader-…`
    /// line, so it can be captured without a debugger attached.
    private func canvasDump(_ message: String) {
        FileHandle.standardError.write(Data("lyra-reader-canvas: \(message)\n".utf8))
    }

    /// `#RRGGBBAA` of one BGRA pixel, as `AnnotationColor.bgra` stores it.
    private static func hex(_ bgra: Data) -> String {
        guard bgra.count >= 4 else { return "?" }
        return String(format: "#%02X%02X%02X%02X", bgra[2], bgra[1], bgra[0], bgra[3])
    }
}

/// SwiftUI wrapper around [`MetalCanvasView`].
public struct PDFCanvasView: NSViewRepresentable {
    private let regionState: AppState?
    private let onOpenRegionInPanel: (AIRegionHistoryEntry) -> Void
    private let onShowRegionHistory: () -> Void
    private let pages: [CanvasPage]
    private let scrollYPt: CGFloat
    private let zoom: CGFloat
    private let contentWidthPt: CGFloat
    private let paperAppearance: PaperAppearance
    private let canvasClearColor: NSColor?
    private let annotationMarks: [CanvasAnnotationMark]
    private let annotationPageFrames: [PagePlacement]
    private let translationOverlays: [TranslationOverlay]
    private let translationPaperColors: [Int: TranslationPaperColor]
    private let annotationTool: AnnotationTool
    private let regionSelectionArmed: Bool
    private let onRegionSelection: ((Int, CGRect) -> Void)?
    private let onRegionSelectionCancelled: ((String) -> Void)?
    private let annotationColor: AnnotationColor
    private let annotationStrokeWidth: CGFloat
    private let onAnnotationDraft: ((AnnotationDraft) -> Void)?
    private let onEraseGestureBegan: ((CGPoint) -> Void)?
    private let onEraseGestureDragged: ((CGPoint, CGPoint) -> Void)?
    private let onEraseGestureEnded: (() -> Void)?
    private let onEraserHover: ((CGPoint?) -> Void)?
    private let onDeleteAnnotation: (() -> Bool)?
    private let onPlaceStickyNote: ((CGPoint) -> Bool)?
    private let onAnnotationDoubleClick: ((CGPoint) -> Bool)?
    private let onPlaceTextBox: ((CGPoint) -> Bool)?
    private let onPlaceStamp: ((CGPoint) -> Bool)?
    private let onPlaceSignature: ((CGPoint) -> Bool)?
    private let fillSignPlacementPending: Bool
    private let onPlaceFillSign: ((CGPoint) -> Bool)?
    private let onCancelTool: (() -> Bool)?
    private let onFrame: (LyraReaderFrameStats) -> Void
    private let onFailure: (String) -> Void
    /// The window's performance probe. Only the reader's canvas gets one; the floating preview
    /// draws its own surface and must not report into the main window's panel.
    private let performanceProbe: CanvasPerformanceProbe?
    private let onDeviceScale: (CGFloat) -> Void
    private let onDisplayCalibration: (DisplayCalibration) -> Void
    private let onViewportSize: (CGSize) -> Void
    private let onScroll: (CGFloat) -> Void
    private let onScrollStep: (CGFloat) -> Void
    /// Paging keys, when the shell wants them to keep their whole destination (see `AppState`).
    private let onKeyboardStep: ((CGFloat) -> Void)?
    private let onZoomScroll: (CGFloat, CGFloat) -> Void
    private let onMagnify: (CGFloat, CGFloat) -> Void
    private let onPointerDown: (CGPoint) -> Void
    private let onPointerDragged: (CGPoint) -> Void
    private let onPointerUp: (CGPoint, Bool) -> Void
    private let onCopy: () -> Void
    private let onUndo: () -> Void
    private let onRedo: () -> Void
    private let interactionSnapshot: (() -> ([CanvasPage], CGFloat, CGFloat))?
    /// Documents dropped on the canvas: the shell's open funnel (see `DocumentOpenCoordinator`).
    private let fileDrop: DocumentOpenCoordinator?
    /// Right-click command list, rendered in the shared LyraReader panel. `nil` offers no menu.
    private let onContextMenu: ((CGPoint) -> NSMenu?)?
    private let onTranslationToggle: ((String) -> Void)?
    private let onTranslationCancel: ((String) -> Void)?

    public init(
        pages: [CanvasPage] = [],
        scrollYPt: CGFloat = 0,
        zoom: CGFloat = 1.0,
        contentWidthPt: CGFloat = 0,
        paperAppearance: PaperAppearance = .original,
        canvasClearColor: NSColor? = nil,
        annotationMarks: [CanvasAnnotationMark] = [],
        annotationPageFrames: [PagePlacement] = [],
        translationOverlays: [TranslationOverlay] = [],
        translationPaperColors: [Int: TranslationPaperColor] = [:],
        annotationTool: AnnotationTool = .select,
        regionSelectionArmed: Bool = false,
        onRegionSelection: ((Int, CGRect) -> Void)? = nil,
        onRegionSelectionCancelled: ((String) -> Void)? = nil,
        annotationColor: AnnotationColor = AnnotationColor(red: 0xE8, green: 0xBC, blue: 0x55, alpha: 255),
        annotationStrokeWidth: CGFloat = 2,
        onAnnotationDraft: ((AnnotationDraft) -> Void)? = nil,
        onEraseGestureBegan: ((CGPoint) -> Void)? = nil,
        onEraseGestureDragged: ((CGPoint, CGPoint) -> Void)? = nil,
        onEraseGestureEnded: (() -> Void)? = nil,
        onEraserHover: ((CGPoint?) -> Void)? = nil,
        onDeleteAnnotation: (() -> Bool)? = nil,
        onPlaceStickyNote: ((CGPoint) -> Bool)? = nil,
        onAnnotationDoubleClick: ((CGPoint) -> Bool)? = nil,
        onPlaceTextBox: ((CGPoint) -> Bool)? = nil,
        onPlaceStamp: ((CGPoint) -> Bool)? = nil,
        onPlaceSignature: ((CGPoint) -> Bool)? = nil,
        fillSignPlacementPending: Bool = false,
        onPlaceFillSign: ((CGPoint) -> Bool)? = nil,
        onCancelTool: (() -> Bool)? = nil,
        onFrame: @escaping (LyraReaderFrameStats) -> Void = { _ in },
        onFailure: @escaping (String) -> Void = { _ in },
        performanceProbe: CanvasPerformanceProbe? = nil,
        onDeviceScale: @escaping (CGFloat) -> Void = { _ in },
        onDisplayCalibration: @escaping (DisplayCalibration) -> Void = { _ in },
        onViewportSize: @escaping (CGSize) -> Void = { _ in },
        onScroll: @escaping (CGFloat) -> Void = { _ in },
        onScrollStep: @escaping (CGFloat) -> Void = { _ in },
        onKeyboardStep: ((CGFloat) -> Void)? = nil,
        onZoomScroll: @escaping (CGFloat, CGFloat) -> Void = { _, _ in },
        onMagnify: @escaping (CGFloat, CGFloat) -> Void = { _, _ in },
        onPointerDown: @escaping (CGPoint) -> Void = { _ in },
        onPointerDragged: @escaping (CGPoint) -> Void = { _ in },
        onPointerUp: @escaping (CGPoint, Bool) -> Void = { _, _ in },
        onCopy: @escaping () -> Void = {},
        onUndo: @escaping () -> Void = {},
        onRedo: @escaping () -> Void = {},
        interactionSnapshot: (() -> ([CanvasPage], CGFloat, CGFloat))? = nil,
        fileDrop: DocumentOpenCoordinator? = nil,
        onContextMenu: ((CGPoint) -> NSMenu?)? = nil,
        onTranslationToggle: ((String) -> Void)? = nil,
        onTranslationCancel: ((String) -> Void)? = nil,
        regionState: AppState? = nil,
        onOpenRegionInPanel: @escaping (AIRegionHistoryEntry) -> Void = { _ in },
        onShowRegionHistory: @escaping () -> Void = {}
    ) {
        self.regionState = regionState
        self.onOpenRegionInPanel = onOpenRegionInPanel
        self.onShowRegionHistory = onShowRegionHistory
        self.pages = pages
        self.scrollYPt = scrollYPt
        self.zoom = zoom
        self.contentWidthPt = contentWidthPt
        self.paperAppearance = paperAppearance
        self.canvasClearColor = canvasClearColor
        self.annotationMarks = annotationMarks
        self.annotationPageFrames = annotationPageFrames
        self.translationOverlays = translationOverlays
        self.translationPaperColors = translationPaperColors
        self.annotationTool = annotationTool
        self.regionSelectionArmed = regionSelectionArmed
        self.onRegionSelection = onRegionSelection
        self.onRegionSelectionCancelled = onRegionSelectionCancelled
        self.annotationColor = annotationColor
        self.annotationStrokeWidth = annotationStrokeWidth
        self.onAnnotationDraft = onAnnotationDraft
        self.onEraseGestureBegan = onEraseGestureBegan
        self.onEraseGestureDragged = onEraseGestureDragged
        self.onEraseGestureEnded = onEraseGestureEnded
        self.onEraserHover = onEraserHover
        self.onDeleteAnnotation = onDeleteAnnotation
        self.onPlaceStickyNote = onPlaceStickyNote
        self.onAnnotationDoubleClick = onAnnotationDoubleClick
        self.onPlaceTextBox = onPlaceTextBox
        self.onPlaceStamp = onPlaceStamp
        self.onPlaceSignature = onPlaceSignature
        self.fillSignPlacementPending = fillSignPlacementPending
        self.onPlaceFillSign = onPlaceFillSign
        self.onCancelTool = onCancelTool
        self.onFrame = onFrame
        self.onFailure = onFailure
        self.performanceProbe = performanceProbe
        self.onDeviceScale = onDeviceScale
        self.onDisplayCalibration = onDisplayCalibration
        self.onViewportSize = onViewportSize
        self.onScroll = onScroll
        self.onScrollStep = onScrollStep
        self.onKeyboardStep = onKeyboardStep
        self.onZoomScroll = onZoomScroll
        self.onMagnify = onMagnify
        self.onPointerDown = onPointerDown
        self.onPointerDragged = onPointerDragged
        self.onPointerUp = onPointerUp
        self.onCopy = onCopy
        self.onUndo = onUndo
        self.onRedo = onRedo
        self.interactionSnapshot = interactionSnapshot
        self.fileDrop = fileDrop
        self.onContextMenu = onContextMenu
        self.onTranslationToggle = onTranslationToggle
        self.onTranslationCancel = onTranslationCancel
    }

    public func makeNSView(context: Context) -> MetalCanvasView {
        let view = MetalCanvasView(frame: .zero)
        configure(view)
        return view
    }

    public func updateNSView(_ nsView: MetalCanvasView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: MetalCanvasView) {
        view.configureRegionCards(state: regionState, onOpenInPanel: onOpenRegionInPanel,
                                  onShowHistory: onShowRegionHistory)
        view.interactionSnapshot = interactionSnapshot
        view.onFrame = onFrame
        view.onFailure = onFailure
        view.performanceProbe = performanceProbe
        view.onDeviceScale = onDeviceScale
        view.onDisplayCalibration = onDisplayCalibration
        view.onViewportSize = onViewportSize
        view.onScroll = onScroll
        view.onScrollStep = onScrollStep
        view.onKeyboardStep = onKeyboardStep
        view.onZoomScroll = onZoomScroll
        view.onMagnify = onMagnify
        view.onPointerDown = onPointerDown
        view.onPointerDragged = onPointerDragged
        view.onPointerUp = onPointerUp
        view.onCopy = onCopy
        view.onUndo = onUndo
        view.onRedo = onRedo
        view.onContextMenu = onContextMenu
        view.onTranslationToggle = onTranslationToggle
        view.onTranslationCancel = onTranslationCancel
        view.zoom = zoom
        view.scrollYPt = scrollYPt
        view.contentWidthPt = contentWidthPt
        view.paperAppearance = paperAppearance
        view.canvasClearColor = canvasClearColor
        view.annotationMarks = annotationMarks
        view.annotationPageFrames = annotationPageFrames
        view.translationOverlays = translationOverlays
        view.translationPaperColors = translationPaperColors
        view.annotationTool = annotationTool
        view.regionSelectionArmed = regionSelectionArmed
        view.onRegionSelection = onRegionSelection
        view.onRegionSelectionCancelled = onRegionSelectionCancelled
        view.annotationColor = annotationColor
        view.annotationStrokeWidth = annotationStrokeWidth
        view.onAnnotationDraft = onAnnotationDraft
        view.onEraseGestureBegan = onEraseGestureBegan
        view.onEraseGestureDragged = onEraseGestureDragged
        view.onEraseGestureEnded = onEraseGestureEnded
        view.onEraserHover = onEraserHover
        view.onDeleteAnnotation = onDeleteAnnotation
        view.onPlaceStickyNote = onPlaceStickyNote
        view.onAnnotationDoubleClick = onAnnotationDoubleClick
        view.onPlaceTextBox = onPlaceTextBox
        view.onPlaceStamp = onPlaceStamp
        view.onPlaceSignature = onPlaceSignature
        view.fillSignPlacementPending = fillSignPlacementPending
        view.onPlaceFillSign = onPlaceFillSign
        view.onCancelTool = onCancelTool
        view.pages = pages
        // Drag & drop is rewired on every update: `connect` only assigns closures, and the
        // coordinator is the one long-lived object (it also serves the Dock and Finder paths).
        if let fileDrop { fileDrop.connect(view) }
    }
}

/// Precise devices carry system acceleration. Discrete wheels scale with event cadence;
/// a pause or reversal resets the gain, and no velocity survives the final event.
public struct WheelMotion {
    public static let pointsPerLine: CGFloat = 40
    private var lastTime: TimeInterval?
    private var lastDelta: CGFloat = 0
    public init() {}
    public mutating func reset() {
        lastTime = nil
        lastDelta = 0
    }
    public mutating func delta(scrollingDeltaY: CGFloat, precise: Bool, timestamp: TimeInterval) -> CGFloat {
        if precise {
            reset()
            return -scrollingDeltaY
        }
        guard scrollingDeltaY != 0 else { return 0 }
        var gain: CGFloat = 1
        if let lastTime, timestamp > lastTime, scrollingDeltaY * lastDelta > 0 {
            // 100 ms per event is a deliberate line scroll; faster turns increase the distance,
            // up to 3x at 33 ms. This uses the current rate rather than the length of a burst.
            gain = min(3, max(1, CGFloat(0.1 / (timestamp - lastTime))))
        }
        lastTime = timestamp
        lastDelta = scrollingDeltaY
        return -scrollingDeltaY * Self.pointsPerLine * gain
    }
}
