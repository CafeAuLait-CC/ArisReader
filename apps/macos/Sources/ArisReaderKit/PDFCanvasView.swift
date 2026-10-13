import AppKit
import ArisReaderFFI
import Metal
import QuartzCore
import SwiftUI

/// Mirrors the C return codes declared in `aris_reader_ffi.h`.
///
/// Spelled out in Swift instead of relying on how Swift imports the anonymous C
/// enum, which keeps the interop surface obvious.
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
/// Integration (M0 T0.4/T0.5):
///
/// 1. `aris_reader_gpu_init()` creates the wgpu device;
/// 2. this view hands its layer pointer to `aris_reader_surface_attach()`;
/// 3. a timer asks the engine to render frames (`aris_reader_surface_render`), which
///    clears the surface and draws the spike triangle;
/// 4. on window teardown the order is fixed: detach the surface, *then* let AppKit
///    release the layer (a hard requirement of wgpu's Metal backend).
///
/// Both sides use the process-wide default `MTLDevice`, which is what makes the
/// layers interoperate — the M0 spike's device-ownership result (`docs/adr/0003`).
public final class MetalCanvasView: NSView {
    /// Reports frame statistics, throttled to a few times per second.
    public var onFrame: ((ArisFrameStats) -> Void)?
    /// Reports a fatal GPU/surface problem once; the canvas stops rendering.
    public var onFailure: ((String) -> Void)?

    private var surfaceId: UInt64 = 0
    /// `Task` rather than `Timer`: it is `Sendable`, so the nonisolated `deinit`
    /// may cancel it under Swift 6 strict concurrency.
    private var frameTask: Task<Void, Never>?
    private var configuredSize: CGSize = .zero
    private var framesRendered: UInt64 = 0

    /// Reports every Nth frame to the UI; 60 Hz state updates would be wasteful.
    private let frameReportInterval: UInt64 = 15

    public override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        // Same device as wgpu's adapter (see the class comment).
        metalLayer.device = MTLCreateSystemDefaultDevice()
        // The engine copies the drawable for verification/readback; production will
        // keep this false once the spike's self-check is gone.
        metalLayer.framebufferOnly = false
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
        startFrameLoop()

        // Verification aid for the M0 spike: macOS reports a window that is covered
        // by another app as occluded, and wgpu then skips drawing (correct behaviour,
        // but it makes automated checks impossible). Opt in with an env var.
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
    }

    private func detachSurface() {
        frameTask?.cancel()
        frameTask = nil
        guard surfaceId != 0 else { return }
        _ = aris_reader_surface_detach(surfaceId)
        surfaceId = 0
    }

    // MARK: - Frame loop

    private func startFrameLoop() {
        frameTask?.cancel()
        // A ~60 Hz task keeps the spike dependency-free. M1 T1.10 replaces it with a
        // display link driven by the session's dirty flags (render on demand).
        frameTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.renderFrame()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func renderFrame() {
        guard surfaceId != 0 else { return }

        var stats = ArisFrameStats()
        let code = aris_reader_surface_render(surfaceId, &stats)
        guard code == ArisStatus.ok.rawValue else {
            report("aris_reader_surface_render failed (\(ArisStatus.describe(code)))")
            detachSurface()
            return
        }

        framesRendered += 1
        if framesRendered == 1 || framesRendered % frameReportInterval == 0 {
            onFrame?(stats)
        }
    }

    // MARK: - Geometry

    private func backingScale() -> CGFloat {
        window?.backingScaleFactor ?? 2.0
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
///
/// Keeps the name used by the window code; the placeholder "paper" rendering of the
/// skeleton phase is gone now that real frames arrive from the engine.
public struct PDFCanvasView: NSViewRepresentable {
    private let onFrame: (ArisFrameStats) -> Void
    private let onFailure: (String) -> Void

    public init(
        onFrame: @escaping (ArisFrameStats) -> Void = { _ in },
        onFailure: @escaping (String) -> Void = { _ in }
    ) {
        self.onFrame = onFrame
        self.onFailure = onFailure
    }

    public func makeNSView(context: Context) -> MetalCanvasView {
        let view = MetalCanvasView(frame: .zero)
        view.onFrame = onFrame
        view.onFailure = onFailure
        return view
    }

    public func updateNSView(_ nsView: MetalCanvasView, context: Context) {
        nsView.onFrame = onFrame
        nsView.onFailure = onFailure
    }
}
