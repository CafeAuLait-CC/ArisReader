import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Runs the Fill & Sign inspector's commands and builds the one small AppKit menu it needs.
///
/// Fill & Sign is a sub-toolbar row, not a menu. The only real `NSMenu` left is the Signature
/// inspector's "From iPhone or iPad" pop-up: AppKit's Continuity Camera handoff requires an
/// `NSMenuItem` carrying `NSMenuItemImportFromDeviceIdentifier` and the
/// `NSServicesMenuRequestor` action, and a look-alike SwiftUI button cannot receive the sketch.
/// The other three methods are ordinary buttons in the inspector and call ``dispatch(_:)``.
@MainActor
package final class FillSignCommandController: NSObject {
    package let state: AppState

    package init(state: AppState) {
        self.state = state
        super.init()
    }

    // MARK: - The continuity menu

    /// The four Signature methods as a real menu, in #153's submenu order.
    package func makeSignatureMethodMenu() -> NSMenu {
        let menu = NSMenu(title: "Signature")
        menu.autoenablesItems = false
        for command in state.fillSignSignatureMethods {
            menu.addItem(makeSignatureMethodItem(command))
        }
        return menu
    }

    /// The one item the inspector's pop-up shows. Exposed so the checks can assert the
    /// identifier, selector and target AppKit requires without opening a menu.
    package func makeContinuityMenuItem() -> NSMenuItem {
        let command = state.fillSignSignatureMethods.first { $0.action == .continuity }
            ?? SignatureMethodCommand(
                action: .continuity, title: "From iPhone or iPad",
                icon: "iphone.and.arrow.forward", enabled: false, help: "")
        return makeSignatureMethodItem(command)
    }

    private func makeSignatureMethodItem(_ command: SignatureMethodCommand) -> NSMenuItem {
        let item = NSMenuItem(title: command.title,
                              action: #selector(performMenuAction(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = "signature-\(command.action.rawValue)"
        item.isEnabled = command.enabled
        item.toolTip = command.help
        if let image = NSImage(systemSymbolName: command.icon, accessibilityDescription: nil) {
            image.isTemplate = true
            item.image = image
        }
        if command.action == .continuity {
            // AppKit looks for this identifier and replaces the row with the paired devices'
            // sketch entry. The action must be the NSServicesMenuRequestor method.
            item.identifier = NSMenuItem.importFromDeviceIdentifier
            item.action = #selector(receiveContinuitySelection(_:))
        }
        return item
    }

    /// Menu actions run after the menu has closed: the transient menu must not own a modal
    /// dialog's event loop.
    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        DispatchQueue.main.async { [weak self] in
            self?.dispatch(id)
        }
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
        case "signature-continuity":
            // AppKit normally replaces this row with the paired device submenu. If the action
            // is reached without a device, say why rather than doing nothing.
            state.statusMessage = "No iPhone or iPad sketch was received"
            NSSound.beep()
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

    /// The Continuity Camera path: macOS hands the sketch over on a pasteboard after the reader
    /// finishes it on the paired device.
    ///
    /// This is `NSServicesMenuRequestor.readSelectionFromPasteboard:`. The Objective-C selector
    /// is pinned explicitly rather than depending on the Swift importer's name for it: recent
    /// SDKs call the method `readSelection(from:)`, older ones
    /// `readSelectionFromPasteboard(_:)`, and the selector AppKit sends is the same either way.
    /// TIFF is the usual transport; the writer accepts PNG or JPEG, so convert when needed.
    @objc(readSelectionFromPasteboard:)
    package func receiveContinuitySelection(_ pasteboard: NSPasteboard) -> Bool {
        prepareSignatureTool()
        guard state.canPlaceFillSignAnnotation else {
            state.lastError = state.fillSignPlacementRefusal
            return false
        }
        guard let data = Self.imageData(from: pasteboard) else {
            state.lastError = "The sketch from the device could not be read as an image."
            state.statusMessage = "No signature sketch was received"
            return false
        }
        state.armSignatureTool(imageData: data)
        state.statusMessage = "Sketch received · click the page to place it as a signature image"
        return true
    }

    static func imageData(from pasteboard: NSPasteboard) -> Data? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.png.identifier, UTType.jpeg.identifier],
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options)
            as? [URL], let url = urls.first,
           let data = try? Data(contentsOf: url), !data.isEmpty {
            return data
        }
        if let data = pasteboard.data(forType: .png), !data.isEmpty { return data }
        if let data = pasteboard.data(forType: .tiff), !data.isEmpty {
            return pngData(from: data)
        }
        let jpegType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
        if let data = pasteboard.data(forType: jpegType), !data.isEmpty { return data }
        if let string = pasteboard.string(forType: .fileURL),
           let url = URL(string: string),
           let data = try? Data(contentsOf: url), !data.isEmpty {
            return data
        }
        return nil
    }

    private static func pngData(from data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
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

/// The Signature inspector's Continuity Camera button.
///
/// It is a pull-down `NSPopUpButton` whose menu holds the real
/// `NSMenuItemImportFromDeviceIdentifier` item. AppKit only replaces the item with the paired
/// devices' sketch entry when it is inside an actual menu being tracked, which is why this stays
/// AppKit rather than becoming a SwiftUI button.
package struct SignatureContinuityButton: NSViewRepresentable {
    package let controller: FillSignCommandController
    package let enabled: Bool

    package init(controller: FillSignCommandController, enabled: Bool) {
        self.controller = controller
        self.enabled = enabled
    }

    package func makeNSView(context: Context) -> NSPopUpButton {
        let button = StretchingPopUpButton(
            frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: true)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = NSFont.systemFont(ofSize: 12)
        button.autoenablesItems = false
        button.addItem(withTitle: "From iPhone or iPad")
        button.menu?.autoenablesItems = false
        button.menu?.addItem(controller.makeContinuityMenuItem())
        button.isEnabled = enabled
        button.toolTip =
            "Sign on a paired iPhone or iPad and place the sketch as a signature image"
        return button
    }

    package func updateNSView(_ button: NSPopUpButton, context: Context) {
        button.isEnabled = enabled
        let item = button.menu?.items.first {
            $0.identifier == NSMenuItem.importFromDeviceIdentifier
        }
        item?.isEnabled = enabled
    }

    /// A pop-up whose width follows the inspector's column instead of its title.
    package final class StretchingPopUpButton: NSPopUpButton {
        package override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: 26)
        }
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
