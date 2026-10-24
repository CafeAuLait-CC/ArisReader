import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Runs the Fill & Sign inspector's signature and image commands.
@MainActor
package final class FillSignCommandController: NSObject {
    package let state: AppState

    package init(state: AppState) {
        self.state = state
        super.init()
    }

    /// Runs a signature method (or a form command) with a stable id. Exposed to the checks so
    /// the inspector's wiring can be exercised without opening a real menu.
    package func dispatch(_ id: String) {
        switch id {
        case "signature-type":
            chooseTypedSignature()
        case "signature-draw":
            chooseDrawnSignature()
        case "signature-image":
            chooseSignatureImage()
        case "save-filled-copy":
            state.performFillAndSignCommand("save-filled-copy")
        case "write-form-values":
            state.performFillAndSignCommand("write-form-values")
        default:
            break
        }
    }

    /// Arms the Signature row item without toggling it off when it is already armed.
    private func prepareSignatureTool() {
        if state.armedFillSignTool != .signature {
            state.selectFillSignTool(.signature)
        }
    }

    // MARK: - Signature methods

    /// Type a name and render it into a PNG in a built-in handwriting font.
    package func chooseTypedSignature() {
        prepareSignatureTool()
        let dialog = TypedSignatureDialog()
        guard let choice = dialog.run() else { return }
        guard state.armTypedSignature(name: choice.name, fontName: choice.fontName) else {
            return
        }
    }

    /// Draw a signature on a small pad and place the strokes as an ink annotation.
    package func chooseDrawnSignature() {
        prepareSignatureTool()
        let dialog = DrawnSignatureDialog()
        guard let signature = dialog.run() else { return }
        state.armDrawnSignature(signature)
    }

    package func chooseSignatureImage() {
        prepareSignatureTool()
        guard state.canPlaceFillSignAnnotation else {
            state.lastError = state.fillSignPlacementRefusal
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose a Signature Image"
        panel.message =
            "This places a picture of a signature, not a digital signature. Only a digital "
            + "signature can detect later changes. Choose a PNG with a transparent background "
            + "(or a JPEG); it stays an annotation until you save."
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        state.armSignatureTool(imageData: data)
    }

    /// Called by the Continuity requestor after it has verified the originating document.
    /// Validate before arming: a cancelled or unreadable sketch must preserve the current tool.
    package func receiveContinuitySelection(_ pasteboard: NSPasteboard) -> Bool {
        guard state.canPlaceFillSignAnnotation else { return false }
        guard !(pasteboard.types ?? []).isEmpty else { return false }
        guard let data = Self.imageData(from: pasteboard) else {
            state.lastError = "The sketch from the device could not be read as an image."
            return false
        }
        state.armSignatureTool(imageData: data)
        state.statusMessage = "Sketch received · click the page to place it as a signature image"
        return true
    }

    static func imageData(from pasteboard: NSPasteboard) -> Data? {
        // Services may return PNG, JPEG or TIFF. Decode every payload before passing it to
        // the PDF writer, including file URLs; a nonempty pasteboard is not necessarily an image.
        for type in [NSPasteboard.PasteboardType.png,
                     NSPasteboard.PasteboardType(UTType.jpeg.identifier), .tiff] {
            if let data = pasteboard.data(forType: type),
               let result = validatedImageData(data, type: type) { return result }
        }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.png.identifier, UTType.jpeg.identifier],
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options)
            as? [URL], let url = urls.first, url.isFileURL,
           let data = try? Data(contentsOf: url) {
            return validatedImageData(data, type: nil)
        }
        // Match the full set of image return types advertised by the requestor. AppKit may
        // negotiate another image representation; normalize it to the writer's PNG format.
        if pasteboard.canReadItem(withDataConformingToTypes: NSImage.imageTypes),
           let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation {
            return validatedImageData(tiff, type: .tiff)
        }
        return nil
    }

    private static func validatedImageData(
        _ data: Data, type: NSPasteboard.PasteboardType?
    ) -> Data? {
        guard let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0,
              rep.pixelsHigh > 0 else { return nil }
        if type == .png || type?.rawValue == UTType.jpeg.identifier { return data }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Image placement

    /// The Image inspector's "Choose Image…" button. The row item arms the tool first; this
    /// then asks for the picture whose size the inspector controls.
    package func chooseImage() {
        if state.armedFillSignTool != .image {
            state.selectFillSignTool(.image)
        }
        guard state.canPlaceFillSignAnnotation else {
            state.lastError = state.fillSignPlacementRefusal
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Place an Image"
        panel.message =
            "Choose a PNG or JPEG to place on the page as a picture annotation, not a "
            + "signature. It stays an annotation until you save."
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        state.armPicturePlacement(imageData: data)
    }
}

// MARK: - Typed signature dialog

/// A small dialog: a name field, a handwriting-font popup, and a preview of what will be placed.
@MainActor
private final class TypedSignatureDialog: NSObject, NSTextFieldDelegate {
    private let nameField = NSTextField()
    private let fontPopup = NSPopUpButton()
    private let preview = NSImageView()
    private let accessory: NSView
    private let fontNames: [String]

    override init() {
        fontNames = TypedSignatureRenderer.availableFontNames
        accessory = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 176))
        super.init()
        buildAccessory()
    }

    private func buildAccessory() {
        let nameLabel = NSTextField(labelWithString: "Name")
        nameLabel.frame = NSRect(x: 0, y: 150, width: 44, height: 18)
        accessory.addSubview(nameLabel)

        nameField.frame = NSRect(x: 48, y: 146, width: 220, height: 24)
        nameField.placeholderString = "Your name"
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(refreshPreview)
        accessory.addSubview(nameField)

        let fontLabel = NSTextField(labelWithString: "Font")
        fontLabel.frame = NSRect(x: 276, y: 150, width: 30, height: 18)
        accessory.addSubview(fontLabel)

        fontPopup.frame = NSRect(x: 310, y: 144, width: 110, height: 26)
        fontPopup.addItems(withTitles: fontNames.isEmpty ? ["System"] : fontNames)
        fontPopup.target = self
        fontPopup.action = #selector(refreshPreview)
        accessory.addSubview(fontPopup)

        preview.frame = NSRect(x: 0, y: 0, width: 420, height: 134)
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.white.cgColor
        preview.layer?.borderColor = NSColor.separatorColor.cgColor
        preview.layer?.borderWidth = 1
        preview.layer?.cornerRadius = 4
        accessory.addSubview(preview)

        refreshPreview()
    }

    @objc private func refreshPreview() {
        guard let data = TypedSignatureRenderer.pngData(
            name: nameField.stringValue, fontName: selectedFontName) else {
            preview.image = nil
            return
        }
        preview.image = NSImage(data: data)
    }

    private var selectedFontName: String? {
        guard let title = fontPopup.titleOfSelectedItem, !fontNames.isEmpty else { return nil }
        return title
    }

    func controlTextDidChange(_ notification: Notification) {
        refreshPreview()
    }

    func run() -> (name: String, fontName: String?)? {
        let alert = NSAlert()
        alert.messageText = "Type a Signature"
        alert.informativeText =
            "This places a picture of a signature, not a digital signature. Only a digital "
            + "signature can detect later changes.\n\nType your name; the picture is rendered "
            + "in a handwriting font built into macOS."
        alert.addButton(withTitle: "Place")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = nameField
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.nameField.becomeFirstResponder()
            self.refreshPreview()
        }
        while alert.runModal() == .alertFirstButtonReturn {
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                NSSound.beep()
                continue
            }
            guard TypedSignatureRenderer.pngData(
                name: name, fontName: selectedFontName) != nil else {
                NSSound.beep()
                continue
            }
            return (name, selectedFontName)
        }
        return nil
    }
}

// MARK: - Drawn signature dialog

/// A small in-dialog canvas. The strokes are sampled as the pointer moves; when the dialog is
/// accepted they become a single ink annotation, not an image.
@MainActor
private final class DrawnSignatureDialog {
    private let pad = SignaturePadView(frame: NSRect(x: 0, y: 0, width: 420, height: 170))

    func run() -> DrawnSignature? {
        let alert = NSAlert()
        alert.messageText = "Draw a Signature"
        alert.informativeText =
            "This is a picture of a signature, not a digital signature. Only a digital "
            + "signature can detect later changes.\n\nDraw with the pointer on the pad. The "
            + "strokes are placed as an ink annotation."
        alert.addButton(withTitle: "Place")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = pad
        while alert.runModal() == .alertFirstButtonReturn {
            if let signature = pad.drawnSignature { return signature }
            NSSound.beep()
        }
        return nil
    }
}

/// The pad's coordinate space is flipped so the normalised y axis points down, matching the
/// annotation cache and making the conversion a division rather than a subtraction.
@MainActor
private final class SignaturePadView: NSView {
    private var strokes: [[CGPoint]] = []
    private var current: [CGPoint] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        current = [point]
        strokes.append(current)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !strokes.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let last = current.last, hypot(point.x - last.x, point.y - last.y) < 1 { return }
        current.append(point)
        strokes[strokes.count - 1] = current
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if current.count < 2 {
            // A click is a dot, not a signature stroke. Drop it so "Place" cannot succeed on a
            // single accidental click.
            strokes.removeLast()
        } else if let last = current.last,
                  hypot(point.x - last.x, point.y - last.y) >= 1 {
            current.append(point)
            strokes[strokes.count - 1] = current
        }
        current = []
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                  xRadius: 4, yRadius: 4)
        border.lineWidth = 1
        border.stroke()
        if strokes.isEmpty {
            let hint = "Sign here"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            let size = (hint as NSString).size(withAttributes: attributes)
            (hint as NSString).draw(
                at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                withAttributes: attributes)
            return
        }
        NSColor.black.setStroke()
        for stroke in strokes where stroke.count >= 2 {
            let path = NSBezierPath()
            path.lineWidth = 2.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: stroke[0])
            for point in stroke.dropFirst() { path.line(to: point) }
            path.stroke()
        }
    }

    /// Normalise the ink into a 0…1 box with its own aspect ratio. A purely horizontal stroke is
    /// given a minimum height so placement does not divide by zero.
    var drawnSignature: DrawnSignature? {
        let usable = strokes.filter { $0.count >= 2 }
        let points = usable.flatMap { $0 }
        guard !points.isEmpty else { return nil }
        var minX = points[0].x, maxX = points[0].x
        var minY = points[0].y, maxY = points[0].y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let width = max(maxX - minX, 1)
        let height = max(maxY - minY, 1)
        let aspect = min(max(width / height, 0.3), 6)
        let normalized = usable.map { stroke in
            stroke.map { CGPoint(x: (($0.x - minX) / width).clamped(to: 0...1),
                                 y: (($0.y - minY) / height).clamped(to: 0...1)) }
        }
        return DrawnSignature(strokes: normalized, aspect: aspect)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
