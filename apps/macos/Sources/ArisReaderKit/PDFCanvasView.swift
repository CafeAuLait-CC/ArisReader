import AppKit
import QuartzCore
import SwiftUI

/// The `NSView` that hosts GPU rendering (**its backing layer is a `CAMetalLayer`**).
///
/// Integration (landed in M0 T0.4, see `docs/05-ffi.md` §6):
///
/// 1. The Rust side creates the wgpu device via `aris_reader_gpu_init()`;
/// 2. This view obtains that same `MTLDevice` through `aris_reader_gpu_metal_device_ptr()` and uses it as the layer's device;
/// 3. It hands the `layer` pointer to `aris_reader_surface_attach(...)` to register it as a render surface;
/// 4. **Lifetime**: when the window closes, call `aris_reader_surface_detach` first, then release this view.
///
/// Until then, this view only draws a "paper" placeholder layer to validate window, theme, and layout.
public final class CanvasLayerView: NSView {
    private let pageLayer = CALayer()

    public override func makeBackingLayer() -> CALayer {
        CAMetalLayer()
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setupPlaceholder()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("CanvasLayerView only supports programmatic creation")
    }

    private func setupPlaceholder() {
        applyAppearanceColors()
        pageLayer.shadowOpacity = 0.20
        pageLayer.shadowRadius = 6
        pageLayer.shadowOffset = CGSize(width: 0, height: -2)
        pageLayer.cornerRadius = 2
        layer?.addSublayer(pageLayer)
    }

    public override func layout() {
        super.layout()
        layoutPage()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    /// Semantic colors follow light/dark appearance changes (`docs/04-ui-ux.md` §6).
    private func applyAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            pageLayer.backgroundColor = NSColor.textBackgroundColor.cgColor
            pageLayer.shadowColor = NSColor.black.cgColor
        }
    }

    private func layoutPage() {
        let available = bounds.insetBy(dx: 24, dy: 24)
        guard available.width > 1, available.height > 1 else { return }

        // Keep the A4 aspect ratio (595 : 842)
        let aspect: CGFloat = 595.0 / 842.0
        var size = CGSize(width: available.height * aspect, height: available.height)
        if size.width > available.width {
            size = CGSize(width: available.width, height: available.width / aspect)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageLayer.frame = CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        pageLayer.shadowPath = CGPath(rect: pageLayer.bounds, transform: nil)
        CATransaction.commit()
    }
}

/// SwiftUI wrapper that puts [`CanvasLayerView`] into the view tree.
public struct PDFCanvasView: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> CanvasLayerView {
        CanvasLayerView(frame: .zero)
    }

    public func updateNSView(_ nsView: CanvasLayerView, context: Context) {}
}
