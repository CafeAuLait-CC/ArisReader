import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One command in the Fill & Sign menu, as data.
///
/// The same list feeds the real `NSMenu` and the checks: the menu's order, the disabled reasons,
/// and the help are facts about the reader's state rather than about a particular AppKit call.
/// The Signature and Stamp entries carry children; the two form-save commands stay at the bottom
/// under a separator, where they were before the menu became a placement menu.
public struct FillSignMenuCommand: Identifiable, Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case text
        case date
        case checkmark
        case cross
        case image
        case signatureType
        case signatureDraw
        case signatureImage
        case signatureContinuity
        case stamp(AppState.StampStyle)
        case saveFilledCopy
        case writeFormValues
        case submenu
        case separator
    }

    public let id: String
    public let title: String
    public let action: Action
    public let enabled: Bool
    public let help: String?
    public let children: [FillSignMenuCommand]
    /// Shows the menu's checkmark for the choice the current tool is already using.
    public let selected: Bool

    public init(
        id: String,
        title: String,
        action: Action,
        enabled: Bool,
        help: String?,
        children: [FillSignMenuCommand] = [],
        selected: Bool = false
    ) {
        self.id = id
        self.title = title
        self.action = action
        self.enabled = enabled
        self.help = help
        self.children = children
        self.selected = selected
    }

    public var isSeparator: Bool { action == .separator }

    /// The seven placement entries a Fill & Sign menu starts with, in order.
    public static let placementTitles = ["Text", "Signature", "Date", "Checkmark", "Cross",
                                         "Stamp", "Image…"]
}

/// Builds and runs the Fill & Sign `NSMenu`.
///
/// A real AppKit menu, not the SwiftUI toolbar panel, is what makes the requirements possible:
/// genuine submenus for Signature and Stamp, and the Continuity Camera item, which AppKit only
/// recognises when it is an `NSMenuItem` with `NSMenuItemImportFromDeviceIdentifier` and a
/// `NSServicesMenuRequestor` target.
@MainActor
package final class FillSignMenuController: NSObject {
    package let state: AppState

    package init(state: AppState) {
        self.state = state
        super.init()
    }

    /// The menu the toolbar shows, built from ``AppState/fillSignMenuCommands``.
    package func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Fill & Sign")
        menu.autoenablesItems = false
        for command in state.fillSignMenuCommands {
            menu.addItem(makeItem(command))
        }
        return menu
    }

    private func makeItem(_ command: FillSignMenuCommand) -> NSMenuItem {
        guard !command.isSeparator else { return .separator() }
        let item = NSMenuItem(title: command.title,
                              action: #selector(performMenuAction(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = command.id
        item.isEnabled = command.enabled
        item.state = command.selected ? .on : .off
        item.toolTip = command.help
        if let symbol = Self.symbolName(for: command.action) {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            image?.isTemplate = true
            item.image = image
        }
        if !command.children.isEmpty {
            let submenu = NSMenu(title: command.title)
            submenu.autoenablesItems = false
            for child in command.children { submenu.addItem(makeItem(child)) }
            item.submenu = submenu
        }
        if command.action == .signatureContinuity {
            // AppKit looks for this identifier and replaces the row with the paired devices'
            // "Add a sketch" entry. The action must be the NSServicesMenuRequestor method.
            item.identifier = NSMenuItem.importFromDeviceIdentifier
            item.action = #selector(receiveContinuitySelection(_:))
        }
        return item
    }

    private static func symbolName(for action: FillSignMenuCommand.Action) -> String? {
        switch action {
        case .text: return "textbox"
        case .date: return "calendar"
        case .checkmark: return "checkmark"
        case .cross: return "xmark"
        case .image: return "photo"
        case .signatureType: return "keyboard"
        case .signatureDraw: return "scribble"
        case .signatureImage: return "photo"
        case .signatureContinuity: return "iphone.and.arrow.forward"
        case .stamp: return "seal"
        case .saveFilledCopy: return "square.and.arrow.down"
        case .writeFormValues: return "doc.badge.arrow.up"
        case .submenu: return "signature"
        case .separator: return nil
        }
    }

    /// Menu actions run after the menu has closed: the transient menu must not own a modal
    /// dialog's event loop.
    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        DispatchQueue.main.async { [weak self] in
            self?.dispatch(id)
        }
    }

    /// Runs the command with a stable id. Exposed to the checks so the menu's wiring can be
    /// exercised without opening a real menu.
    package func dispatch(_ id: String) {
        switch id {
        case "text":
            state.armFillSignText()
        case "date":
            state.armFillSignDate()
        case "checkmark":
            state.armFillSignMark(.checkmark)
        case "cross":
            state.armFillSignMark(.cross)
        case "image":
            chooseImage()
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
            if id.hasPrefix("stamp-"),
               let style = AppState.StampStyle(rawValue: String(id.dropFirst("stamp-".count))) {
                state.armStampTool(style)
            }
        }
    }

    // MARK: - Signature submenu

    /// Type a name and render it into a PNG in a built-in handwriting font.
    private func chooseTypedSignature() {
        let dialog = TypedSignatureDialog()
        guard let choice = dialog.run() else { return }
        guard state.armTypedSignature(name: choice.name, fontName: choice.fontName) else {
            return
        }
    }

    /// Draw a signature on a small pad and place the strokes as an ink annotation.
    private func chooseDrawnSignature() {
        let dialog = DrawnSignatureDialog()
        guard let signature = dialog.run() else { return }
        state.armDrawnSignature(signature)
    }

    private func chooseSignatureImage() {
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

    private func chooseImage() {
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

/// Presents the Fill & Sign menu below its toolbar button.
@MainActor
package final class FillSignMenuPresenter {
    package static let shared = FillSignMenuPresenter()
    private var controller: FillSignMenuController?

    package func present(for state: AppState, from view: NSView?) {
        guard let view, view.window != nil else { return }
        let controller = FillSignMenuController(state: state)
        self.controller = controller
        // The menu's actions must outlive the tracking loop: the controller stays here until the
        // next presentation, and each action also captures it.
        let menu = controller.makeMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: view)
    }
}

/// The SwiftUI toolbar button plus the AppKit anchor the menu is positioned against.
package struct FillSignMenuButton: View {
    @ObservedObject package var state: AppState
    @State private var anchor = FillSignMenuAnchorBox()

    package init(state: AppState) {
        self.state = state
    }

    package var body: some View {
        Button {
            FillSignMenuPresenter.shared.present(for: state, from: anchor.view)
        } label: {
            Image(systemName: AnnotationToolbarLayout.fillAndSignIcon)
        }
        .buttonStyle(LyraReaderToolStyle())
        .disabled(!state.canOpenFillAndSignMenu)
        .help(state.fillAndSignMenuHelp)
        .accessibilityLabel(AnnotationToolbarLayout.fillAndSignLabel)
        .accessibilityValue(state.canOpenFillAndSignMenu ? "" : "No document")
        .background(FillSignMenuAnchor(box: anchor))
    }

    /// The button itself is SwiftUI; this zero-drawing view only supplies its window frame.
    private struct FillSignMenuAnchor: NSViewRepresentable {
        let box: FillSignMenuAnchorBox

        func makeNSView(context: Context) -> AnchorView {
            let view = AnchorView()
            box.view = view
            return view
        }

        func updateNSView(_ view: AnchorView, context: Context) {
            box.view = view
        }

        final class AnchorView: NSView {
            override var isFlipped: Bool { false }
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
    }
}

package final class FillSignMenuAnchorBox {
    package weak var view: NSView?
    package init() {}
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
