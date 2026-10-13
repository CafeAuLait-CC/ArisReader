import AppKit
import ArisReaderFFI
import Metal
import QuartzCore
import SwiftUI

/// Mirrors the C return codes declared in `aris_reader_ffi.h`.
///
/// Spelled out in Swift instead of relying on how Swift imports the anonymous C enum,
/// which keeps the interop surface obvious.
enum ArisStatus: Int32 {
    case ok = 0
    case invalidArgument = 1
    case notImplemented = 2
    case notInitialized = 3
    case gpuUnavailable = 4
    case gpuDeviceLost = 5
    case internalError = 6

    static func describe(_ code: Int32) -> String {
        guard let status = ArisStatus(rawValue: code) else { return "unknown status \(code)" }
        return "\(status)"
    }
}

/// The `NSView` that hosts GPU rendering: **its backing layer is a `CAMetalLayer`**
/// which the Rust engine attaches to as a render surface.
///
/// Lifecycle (M0 T0.4/T0.5) and page drawing (M1):
///
/// 1. `aris_reader_gpu_init()` creates the wgpu device;
/// 2. this view hands its layer pointer to `aris_reader_surface_attach()`;
/// 3. a page bitmap arrives from the engine, is uploaded once
///    (`aris_reader_gpu_upload_texture`) and drawn as a textured quad
///    (`aris_reader_surface_draw_page`) at the current zoom;
/// 4. frames are produced **on demand** — a change of page, zoom or size — so an idle
///    window costs no GPU work;
/// 5. on teardown the order is fixed: detach the surface, release textures, *then* let
///    AppKit release the layer (a hard requirement of wgpu's Metal backend).
///
/// Both sides use the process-wide default `MTLDevice`, which is what makes the layers
/// interoperate — the M0 spike's device-ownership result (`docs/adr/0003`).
public final class MetalCanvasView: NSView {
    /// Reports frame statistics (the view throttles them itself).
    public var onFrame: ((ArisFrameStats) -> Void)?
    /// Reports a fatal GPU/surface problem; rendering stops afterwards.
    public var onFailure: ((String) -> Void)?
    /// Reports the backing scale so the engine can rasterize at device resolution.
    public var onDeviceScale: ((CGFloat) -> Void)?

    /// Pages to draw; new bitmaps are uploaded as textures and old ones released.
    public var pages: [CanvasPage] = [] {
        didSet {
            guard pages.map(\.image.generation) != oldValue.map(\.image.generation) else { return }
            syncTextures()
            markNeedsRender()
        }
    }

    /// Scroll offset in content points (0 = top of the first page).
    public var scrollYPt: CGFloat = 0 {
        didSet {
            guard scrollYPt != oldValue else { return }
            markNeedsRender()
        }
    }

    /// Scroll gestures, reported as deltas in screen points.
    public var onScroll: ((CGFloat) -> Void)?
    /// Pointer events, reported in **content points** (the shell's layout space).
    public var onPointerDown: ((CGPoint) -> Void)?
    public var onPointerDragged: ((CGPoint) -> Void)?
    public var onPointerUp: ((CGPoint, Bool) -> Void)?
    /// Whether the pointer moved since mouseDown (a click follows links; a drag selects).
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
    /// Width of the widest page in points; used to centre narrow documents.
    public var contentWidthPt: CGFloat = 0 {
        didSet {
            guard contentWidthPt != oldValue else { return }
            markNeedsRender()
        }
    }

    /// Zoom factor (1.0 = 100%: one PDF point per point on screen).
    public var zoom: CGFloat = 1.0 {
        didSet {
            guard zoom != oldValue else { return }
            markNeedsRender()
        }
    }

    private var surfaceId: UInt64 = 0
    /// One texture per page, with the generation it was uploaded from.
    private var textures: [Int: (generation: UInt64, id: UInt64)] = [:]
    private var frameTask: Task<Void, Never>?
    private var configuredSize: CGSize = .zero
    private var reportedDeviceScale: CGFloat = 0
    private var needsRender = true
    private var framesRendered: UInt64 = 0
    /// Set while the window server is skipping our frames (window hidden or covered).
    private var wasOccluded = false

    public override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        // Same device as wgpu's adapter (see the class comment).
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.isOpaque = true
        return metalLayer
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("MetalCanvasView only supports programmatic creation")
    }

    deinit {
        frameTask?.cancel()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            detachSurface()
        } else {
            attachSurfaceIfNeeded()
        }
    }

    public override func layout() {
        super.layout()
        resizeSurfaceIfNeeded()
        onViewportSize?(bounds.size)
    }

    // MARK: - Scrolling and keyboard

    /// Self-managed scrolling (decision T1.4): `NSScrollView` would size its document view
    /// to the whole document, and a `CAMetalLayer` cannot be hundreds of thousands of
    /// pixels tall. AppKit still delivers the trackpad's momentum as scroll events.
    public override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        guard delta != 0 else { return }
        onScroll?(delta)
    }

    public override var acceptsFirstResponder: Bool { true }

    // MARK: - Pointer

    /// Converts an event location into content points (origin at the first page's top-left,
    /// one unit per PDF point at 100% zoom), which is the space the shell thinks in.
    private func contentPoint(for event: NSEvent) -> CGPoint {
        let view = convert(event.locationInWindow, from: nil)
        let fromTop = CGPoint(x: view.x, y: bounds.height - view.y)
        return CGPoint(
            x: (fromTop.x - contentOffsetX) / max(zoom, 0.01),
            y: fromTop.y / max(zoom, 0.01) + scrollYPt
        )
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pointerMoved = false
        onPointerDown?(contentPoint(for: event))
    }

    public override func mouseDragged(with event: NSEvent) {
        pointerMoved = true
        onPointerDragged?(contentPoint(for: event))
    }

    public override func mouseUp(with event: NSEvent) {
        onPointerUp?(contentPoint(for: event), !pointerMoved)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
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
        switch event.charactersIgnoringModifiers {
        case " ":
            onScroll?(event.modifierFlags.contains(.shift) ? -page : page)
        case "\u{F72D}": // page down
            onScroll?(page)
        case "\u{F72C}": // page up
            onScroll?(-page)
        case "\u{F701}": // down arrow
            onScroll?(40)
        case "\u{F700}": // up arrow
            onScroll?(-40)
        default:
            super.keyDown(with: event)
        }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportDeviceScale()
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

        let initCode = aris_reader_gpu_init(0)
        guard initCode == ArisStatus.ok.rawValue else {
            report("aris_reader_gpu_init failed (\(ArisStatus.describe(initCode)))")
            return
        }

        let (width, height) = pixelSize()
        var newSurfaceId: UInt64 = 0
        let attachCode = aris_reader_surface_attach(
            Unmanaged.passUnretained(metalLayer).toOpaque(),
            UInt32(width),
            UInt32(height),
            backingScale(),
            &newSurfaceId
        )
        guard attachCode == ArisStatus.ok.rawValue else {
            report("aris_reader_surface_attach failed (\(ArisStatus.describe(attachCode)))")
            return
        }

        surfaceId = newSurfaceId
        configuredSize = bounds.size
        reportDeviceScale()
        onViewportSize?(bounds.size)

        syncTextures()
        markNeedsRender()
        startFrameLoop()

        // Verification aid for headless runs: macOS reports a window covered by another
        // app as occluded, and wgpu then skips drawing (correct behaviour, but it makes
        // automated checks impossible). Opt in with an env var.
        if ProcessInfo.processInfo.environment["ARIS_READER_SPIKE_FORCE_FRONT"] == "1" {
            window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private func resizeSurfaceIfNeeded() {
        guard surfaceId != 0, bounds.size != configuredSize, bounds.size.width > 0 else { return }
        let (width, height) = pixelSize()
        let code = aris_reader_surface_resize(surfaceId, UInt32(width), UInt32(height), backingScale())
        if code != ArisStatus.ok.rawValue {
            report("aris_reader_surface_resize failed (\(ArisStatus.describe(code)))")
            return
        }
        configuredSize = bounds.size
        markNeedsRender()
    }

    private func detachSurface() {
        frameTask?.cancel()
        frameTask = nil
        releaseAllTextures()
        guard surfaceId != 0 else { return }
        _ = aris_reader_surface_detach(surfaceId)
        surfaceId = 0
    }

    // MARK: - Page texture

    private func syncTextures() {
        guard surfaceId != 0 else { return }

        var wanted = Set<Int>()
        for page in pages {
            let index = page.placement.index
            wanted.insert(index)
            if textures[index]?.generation == page.image.generation { continue }
            if let stale = textures.removeValue(forKey: index) {
                _ = aris_reader_gpu_release_texture(stale.id)
            }
            if let id = uploadTexture(page.image) {
                textures[index] = (page.image.generation, id)
            }
        }

        // Release pages that scrolled away; the shell keeps a slightly larger cache, so
        // this only drops what it no longer hands us.
        for index in textures.keys where !wanted.contains(index) {
            if let stale = textures.removeValue(forKey: index) {
                _ = aris_reader_gpu_release_texture(stale.id)
            }
        }
    }

    private func uploadTexture(_ image: PageImage) -> UInt64? {
        var newTextureId: UInt64 = 0
        let code: Int32 = image.bgra.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return ArisStatus.invalidArgument.rawValue
            }
            return aris_reader_gpu_upload_texture(
                UInt32(image.pixelWidth),
                UInt32(image.pixelHeight),
                base,
                raw.count,
                &newTextureId
            )
        }
        guard code == ArisStatus.ok.rawValue else {
            report("aris_reader_gpu_upload_texture failed (\(ArisStatus.describe(code)))")
            return nil
        }
        return newTextureId
    }

    private func releaseAllTextures() {
        for (_, texture) in textures {
            _ = aris_reader_gpu_release_texture(texture.id)
        }
        textures.removeAll()
    }

    // MARK: - Frame loop

    private func markNeedsRender() {
        needsRender = true
    }

    private func startFrameLoop() {
        frameTask?.cancel()
        // Render on demand: the task only notices a dirty flag, so an idle window does no
        // GPU work. M1 T1.10 replaces it with a display link driven by the session's
        // dirty flags.
        frameTask = Task { @MainActor [weak self] in
            var tick: UInt64 = 0
            while !Task.isCancelled {
                tick += 1
                if let self {
                    // Render when something changed, and — while the window is occluded —
                    // retry at ~7 Hz so the page appears as soon as it becomes visible.
                    let retryWhileOccluded = self.wasOccluded && tick % 8 == 0
                    if self.needsRender || retryWhileOccluded {
                        self.needsRender = false
                        self.renderFrame()
                    }
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func renderFrame() {
        guard surfaceId != 0 else { return }

        // Every visible page goes into one frame; the shell only hands us pages it has
        // already rasterized, so an empty list simply means "nothing to draw yet".
        let scale = backingScale()
        let (surfaceWidth, _) = pixelSize()
        // Centre the document horizontally when it is narrower than the viewport, which
        // is the normal case for a maximised window.
        let contentWidthPx = contentWidthPt * zoom * scale
        let offsetX = max(0, (CGFloat(surfaceWidth) - contentWidthPx) / 2)
        contentOffsetX = offsetX / scale

        var textureIds: [UInt64] = []
        var rects: [Float] = []
        for page in pages {
            guard let texture = textures[page.placement.index] else { continue }
            textureIds.append(texture.id)
            rects.append(Float(offsetX + page.placement.leftPt * zoom * scale))
            rects.append(Float((page.placement.topPt - scrollYPt) * zoom * scale))
            rects.append(Float(page.placement.widthPt * zoom * scale))
            rects.append(Float(page.placement.heightPt * zoom * scale))
        }

        guard !textureIds.isEmpty else { return }

        var stats = ArisFrameStats()
        let code: Int32 = textureIds.withUnsafeBufferPointer { ids in
            rects.withUnsafeBufferPointer { rectangles in
                aris_reader_surface_draw_pages(
                    surfaceId,
                    ids.baseAddress,
                    rectangles.baseAddress,
                    textureIds.count,
                    &stats
                )
            }
        }
        guard code == ArisStatus.ok.rawValue else {
            report("aris_reader_surface_draw_pages failed (\(ArisStatus.describe(code)))")
            return
        }

        if stats.presented == 0 {
            // The window is occluded (minimised, hidden, or covered by another app): wgpu
            // deliberately skips the draw. The frame loop retries at a low rate.
            wasOccluded = true
            return
        }
        wasOccluded = false

        framesRendered += 1
        if framesRendered == 1 || framesRendered % 15 == 0 {
            onFrame?(stats)
        }
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

    private func pixelSize() -> (Int, Int) {
        let scale = backingScale()
        return (
            max(1, Int((bounds.width * scale).rounded())),
            max(1, Int((bounds.height * scale).rounded()))
        )
    }

    private func report(_ message: String) {
        NSLog("ArisReader canvas: %@", message)
        onFailure?(message)
    }
}

/// SwiftUI wrapper around [`MetalCanvasView`].
public struct PDFCanvasView: NSViewRepresentable {
    private let pages: [CanvasPage]
    private let scrollYPt: CGFloat
    private let zoom: CGFloat
    private let contentWidthPt: CGFloat
    private let onFrame: (ArisFrameStats) -> Void
    private let onFailure: (String) -> Void
    private let onDeviceScale: (CGFloat) -> Void
    private let onViewportSize: (CGSize) -> Void
    private let onScroll: (CGFloat) -> Void
    private let onPointerDown: (CGPoint) -> Void
    private let onPointerDragged: (CGPoint) -> Void
    private let onPointerUp: (CGPoint, Bool) -> Void
    private let onCopy: () -> Void
    private let onUndo: () -> Void
    private let onRedo: () -> Void

    public init(
        pages: [CanvasPage] = [],
        scrollYPt: CGFloat = 0,
        zoom: CGFloat = 1.0,
        contentWidthPt: CGFloat = 0,
        onFrame: @escaping (ArisFrameStats) -> Void = { _ in },
        onFailure: @escaping (String) -> Void = { _ in },
        onDeviceScale: @escaping (CGFloat) -> Void = { _ in },
        onViewportSize: @escaping (CGSize) -> Void = { _ in },
        onScroll: @escaping (CGFloat) -> Void = { _ in },
        onPointerDown: @escaping (CGPoint) -> Void = { _ in },
        onPointerDragged: @escaping (CGPoint) -> Void = { _ in },
        onPointerUp: @escaping (CGPoint, Bool) -> Void = { _, _ in },
        onCopy: @escaping () -> Void = {},
        onUndo: @escaping () -> Void = {},
        onRedo: @escaping () -> Void = {}
    ) {
        self.pages = pages
        self.scrollYPt = scrollYPt
        self.zoom = zoom
        self.contentWidthPt = contentWidthPt
        self.onFrame = onFrame
        self.onFailure = onFailure
        self.onDeviceScale = onDeviceScale
        self.onViewportSize = onViewportSize
        self.onScroll = onScroll
        self.onPointerDown = onPointerDown
        self.onPointerDragged = onPointerDragged
        self.onPointerUp = onPointerUp
        self.onCopy = onCopy
        self.onUndo = onUndo
        self.onRedo = onRedo
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
        view.onFrame = onFrame
        view.onFailure = onFailure
        view.onDeviceScale = onDeviceScale
        view.onViewportSize = onViewportSize
        view.onScroll = onScroll
        view.onPointerDown = onPointerDown
        view.onPointerDragged = onPointerDragged
        view.onPointerUp = onPointerUp
        view.onCopy = onCopy
        view.onUndo = onUndo
        view.onRedo = onRedo
        view.zoom = zoom
        view.scrollYPt = scrollYPt
        view.contentWidthPt = contentWidthPt
        view.pages = pages
    }
}
