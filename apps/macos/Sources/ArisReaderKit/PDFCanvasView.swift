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

    /// The page to draw; a new image is uploaded as a texture.
    public var pageImage: PageImage? {
        didSet {
            guard pageImage?.generation != oldValue?.generation else { return }
            uploadPageTexture()
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
    private var textureId: UInt64 = 0
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

        if pageImage != nil {
            uploadPageTexture()
        }
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
        releasePageTexture()
        guard surfaceId != 0 else { return }
        _ = aris_reader_surface_detach(surfaceId)
        surfaceId = 0
    }

    // MARK: - Page texture

    private func uploadPageTexture() {
        releasePageTexture()
        guard let image = pageImage, surfaceId != 0 else { return }

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
            return
        }
        textureId = newTextureId
    }

    private func releasePageTexture() {
        guard textureId != 0 else { return }
        _ = aris_reader_gpu_release_texture(textureId)
        textureId = 0
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
        guard surfaceId != 0, textureId != 0, let image = pageImage else {
            // Nothing to draw yet; leaving the surface untouched keeps the window valid.
            return
        }

        let (surfaceWidth, surfaceHeight) = pixelSize()
        let scale = backingScale()
        let destinationWidth = Float(image.pointSize.width * zoom * scale)
        let destinationHeight = Float(image.pointSize.height * zoom * scale)
        let destinationX = (Float(surfaceWidth) - destinationWidth) / 2
        let destinationY = (Float(surfaceHeight) - destinationHeight) / 2

        var stats = ArisFrameStats()
        let code = aris_reader_surface_draw_page(
            surfaceId,
            textureId,
            destinationX,
            destinationY,
            destinationWidth,
            destinationHeight,
            &stats
        )
        guard code == ArisStatus.ok.rawValue else {
            report("aris_reader_surface_draw_page failed (\(ArisStatus.describe(code)))")
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
    private let pageImage: PageImage?
    private let zoom: CGFloat
    private let onFrame: (ArisFrameStats) -> Void
    private let onFailure: (String) -> Void
    private let onDeviceScale: (CGFloat) -> Void

    public init(
        pageImage: PageImage? = nil,
        zoom: CGFloat = 1.0,
        onFrame: @escaping (ArisFrameStats) -> Void = { _ in },
        onFailure: @escaping (String) -> Void = { _ in },
        onDeviceScale: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.pageImage = pageImage
        self.zoom = zoom
        self.onFrame = onFrame
        self.onFailure = onFailure
        self.onDeviceScale = onDeviceScale
    }

    public func makeNSView(context: Context) -> MetalCanvasView {
        let view = MetalCanvasView(frame: .zero)
        view.pageImage = pageImage
        view.zoom = zoom
        view.onFrame = onFrame
        view.onFailure = onFailure
        view.onDeviceScale = onDeviceScale
        return view
    }

    public func updateNSView(_ nsView: MetalCanvasView, context: Context) {
        nsView.onFrame = onFrame
        nsView.onFailure = onFailure
        nsView.onDeviceScale = onDeviceScale
        nsView.zoom = zoom
        nsView.pageImage = pageImage
    }
}
