import AppKit
import Foundation
import LyraReaderKit

extension ReaderChecks {
    /// The Mac-side contract, without a device session or the system/general pasteboard.
    @MainActor static func continuitySignatureChecks(
        state: AppState, refusedState: AppState, encryptedState: AppState,
        fixture: URL, picture: Data
    ) async throws {
        _ = NSApplication.shared
        let controller = FillSignCommandController(state: state)
        let button = ContinuitySignatureRequestor(controller: controller)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentLayoutRect)
        window.contentView = content
        content.addSubview(button)
        let otherField = NSTextField(frame: NSRect(x: 0, y: 60, width: 200, height: 24))
        content.addSubview(otherField)
        let pasteboard = NSPasteboard(name: .init("lyra-continuity-\(UUID())"))
        defer { window.close(); pasteboard.releaseGlobally() }

        func receiver(_ type: NSPasteboard.PasteboardType?) -> Any? {
            window.firstResponder?.validRequestor(forSendType: nil, returnType: type)
        }
        func resetPayload(_ type: NSPasteboard.PasteboardType, _ data: Data) {
            pasteboard.clearContents()
            pasteboard.setData(data, forType: type)
        }

        require(receiver(.tiff) == nil, "an idle button does not receive unrelated Services images")
        require(button.beginRequest(), "the device action captures the current signing document")
        require(window.firstResponder === button, "the button joins the active responder chain")
        for type in [NSPasteboard.PasteboardType.png, .tiff, .init("public.jpeg")] {
            require((receiver(type) as? ContinuitySignatureRequestor) === button,
                    "the first responder advertises \(type.rawValue) image returns")
        }
        require(receiver(.string) == nil && receiver(nil) == nil,
                "a sketch request does not claim text or a missing return type")
        require(button.validRequestor(forSendType: .string, returnType: .tiff) == nil,
                "sketch creation does not offer document text to an exporting service")

        state.armSignatureTool(imageData: picture)
        let status = state.statusMessage
        let previousError = state.lastError
        pasteboard.clearContents()
        require(!button.readSelection(from: pasteboard), "an empty cancelled result is refused")
        require(state.pendingSignatureImageData == picture && state.statusMessage == status
                    && state.lastError == previousError,
                "cancellation preserves the existing signature, status and error")
        require(receiver(.tiff) == nil, "the completed or cancelled request is consumed")

        require(button.beginRequest(), "another request can follow cancellation")
        resetPayload(.png, Data("not an image".utf8))
        require(!button.readSelection(from: pasteboard), "corrupt image bytes are refused")
        require(state.pendingSignatureImageData == picture,
                "a corrupt device result never replaces the existing signature")
        state.lastError = nil

        let bitmap = NSBitmapImageRep(data: picture)!
        require(button.beginRequest(), "TIFF delivery begins through the same button")
        resetPayload(.tiff, bitmap.tiffRepresentation!)
        require(button.readSelection(from: pasteboard), "the Services callback converts TIFF")
        let converted = state.pendingSignatureImageData.flatMap(NSBitmapImageRep.init(data:))
        require(converted?.pixelsWide == bitmap.pixelsWide
                    && converted?.pixelsHigh == bitmap.pixelsHigh,
                "TIFF conversion preserves the signature image dimensions")
        require(!button.readSelection(from: pasteboard), "a duplicate delivery cannot reuse a request")

        require(button.beginRequest(), "JPEG delivery begins through the same requestor")
        let jpeg = bitmap.representation(using: .jpeg, properties: [:])!
        resetPayload(.init("public.jpeg"), jpeg)
        require(button.readSelection(from: pasteboard), "a valid device JPEG is accepted")
        require(state.pendingSignatureImageData == jpeg, "JPEG bytes remain usable for PDF placement")

        let fileImage = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-device-signature-\(UUID()).png")
        try picture.write(to: fileImage)
        defer { try? FileManager.default.removeItem(at: fileImage) }
        require(button.beginRequest(), "a file-backed image uses the same signing destination")
        pasteboard.clearContents()
        pasteboard.writeObjects([fileImage as NSURL])
        require(button.readSelection(from: pasteboard), "a local image-file return is accepted")
        require(state.pendingSignatureImageData.flatMap(NSBitmapImageRep.init(data:)) != nil,
                "the file-backed result is a decoded image rather than an arbitrary file")

        require(button.beginRequest(), "a request can be pending before focus changes")
        require(window.makeFirstResponder(otherField), "another editing control can take focus")
        require(!button.readSelection(from: pasteboard),
                "late image delivery cannot overwrite an unrelated editing interaction")

        require(button.beginRequest(), "a request can be pending before a tab switch")
        let originalIndex = state.activeTabIndex!
        state.newTab(url: fixture)
        try await eventually("a new signing tab opens", { state.activeTabIndex != originalIndex })
        require(!button.readSelection(from: pasteboard),
                "a device result cannot be applied to a different document")
        button.update(controller: controller, enabled: true)
        state.selectTab(originalIndex)
        require(!button.readSelection(from: pasteboard),
                "returning to the original tab does not revive an invalidated request")

        button.update(controller: controller, enabled: false)
        require(!button.beginRequest(), "a disabled inspector cannot start device import")
        button.update(controller: controller, enabled: true)
        require(button.beginRequest(), "reenabling the inspector permits a fresh request")
        button.removeFromSuperview()
        require(!button.readSelection(from: pasteboard), "detaching the inspector invalidates delivery")
        require(!button.beginRequest(), "a detached view cannot advertise a Services receiver")
        content.addSubview(button)
        for refused in [refusedState, encryptedState] {
            button.update(controller: FillSignCommandController(state: refused), enabled: true)
            require(!button.beginRequest(), "read-only XFA/encrypted documents refuse device import")
            require(!button.readSelection(from: pasteboard),
                    "refused documents cannot receive a signature even with a valid image")
            require(refused.pendingSignatureImageData == nil,
                    "a rejected result leaves the protected document untouched")
        }
        state.clearFillSignTool()
        print("Continuity Mac-side requestor checks passed (device board not exercised)")
    }
}
