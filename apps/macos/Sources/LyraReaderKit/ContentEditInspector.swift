import AppKit
import SwiftUI

/// Tool properties only; mode selection belongs to the shared secondary toolbar.
struct ContentEditInspector: View {
    @ObservedObject var state: AppState
    @State private var font = "Original"
    @State private var size = 12.0
    @State private var alignment = 0
    @State private var colour = Color.black
    @State private var x = 0.0
    @State private var y = 0.0
    @State private var width = 100.0
    @State private var height = 40.0
    @State private var imagePreview: NSImage?
    @State private var showCrop = false
    @State private var cropLeft = 0.0
    @State private var cropTop = 0.0
    @State private var cropRight = 100.0
    @State private var cropBottom = 100.0
    @State private var linkDestination = "page"
    @State private var linkPage = 1
    @State private var linkURL = "https://"
    private let fonts = ["Original", "Helvetica", "Helvetica-Bold", "Helvetica-Oblique",
        "Helvetica-BoldOblique", "Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic",
        "Courier", "Courier-Bold", "LyraReader Sans SC"]

    private var redacting: Bool { ["erase", "blackout"].contains(state.contentEditTool) }
    private var title: String {
        if redacting { return "Redact" }
        if state.contentEditTool == "select" { return state.selectedContentItem?.kind.capitalized ?? "Edit PDF" }
        return state.contentEditTool.capitalized + " Tool"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { state.toggleContentEditing() } label: { Image(systemName: "xmark") }
                    .buttonStyle(LyraReaderToolStyle())
                    .accessibilityLabel("Close PDF editing")
            }.padding(.horizontal, 16).padding(.vertical, 9)
            Divider().overlay(LyraReaderTheme.separator)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if state.contentEditLoading || state.pageEditBusy { ProgressView().controlSize(.small) }
                    if state.contentTextRecovery != nil { recovery }
                    if redacting { redactionOptions }
                    if state.contentEditTool == "link" { linkOptions }
                    if let item = state.selectedContentItem {
                        if ["image", "graphic"].contains(item.kind) { imageOptions(item) }
                        if item.kind == "text" { textOptions(item) }
                        geometry(item)
                    } else if !redacting {
                        emptySelection
                    }
                }.padding(16)
            }
            Divider().overlay(LyraReaderTheme.separator)
            footer.padding(16)
        }
        .frame(width: 292).frame(maxHeight: .infinity)
        .background(LyraReaderTheme.panelBg)
        .overlay(alignment: .leading) { LyraReaderTheme.separator.frame(width: 1) }
        .foregroundStyle(LyraReaderTheme.textPrimary)
        .textFieldStyle(ReaderPanelFieldStyle())
        .buttonStyle(ReaderPanelButtonStyle())
        .task(id: "\(state.contentEditPage?.revision ?? "")-\(state.contentEditSelection ?? "")") {
            syncSelection()
            imagePreview = nil
            showCrop = false
            cropLeft = 0; cropTop = 0; cropRight = 100; cropBottom = 100
            guard let item = state.selectedContentItem, ["image", "graphic"].contains(item.kind),
                  let data = try? await state.contentImageData(item), !Task.isCancelled else { return }
            imagePreview = NSImage(data: data)
        }
        .disabled(state.pageEditBusy || state.contentCommandInFlight)
    }

    private var emptySelection: some View {
        VStack(spacing: 12) {
            Image(systemName: state.contentEditTool == "image" ? "photo.badge.plus" : "cursorarrow.click")
                .font(.system(size: 28, weight: .light)).foregroundStyle(LyraReaderTheme.iconSecondary)
            Text(state.contentEditTool == "image" ? "Click a page to insert an image, or select an existing image." :
                state.contentEditTool == "text" ? "Select text to edit it, or click an empty area to add text." :
                state.contentEditTool == "link" ? "Drag a region to add a link, or select an existing link." :
                "Select text, an image or a graphic on the page to edit its properties.")
                .font(.system(size: 12)).multilineTextAlignment(.center)
            if state.contentEditTool != "image" && state.contentEditTool != "link" {
                Text("Click selected text again to type. ⌘Return applies; Escape cancels.")
                    .font(.caption).foregroundStyle(LyraReaderTheme.textTertiary).multilineTextAlignment(.center)
            }
        }.foregroundStyle(LyraReaderTheme.textSecondary)
            .frame(maxWidth: .infinity).padding(.vertical, 34)
    }

    private var redactionOptions: some View {
        ReaderPanelSection(title: "Remove content") {
            redactionChoice("Erase", "Remove content and leave white space.", "erase", "eraser")
            redactionChoice("Blackout", "Remove content and cover the area in black.", "blackout", "rectangle.fill")
            Text("Drag a rectangle on the page. Undo restores the previous revision.")
                .font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
        }
    }

    private func redactionChoice(_ title: String, _ detail: String, _ tool: String, _ icon: String) -> some View {
        Button { state.selectContentTool(tool) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(detail).font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(10)
        }.buttonStyle(ReaderPanelButtonStyle(selected: state.contentEditTool == tool))
    }

    private var linkOptions: some View {
        ReaderPanelSection(title: "Destination") {
            if state.selectedContentItem?.kind == "link" || state.contentLinkDraft != nil {
                Picker("Destination", selection: $linkDestination) {
                    Text("Page").tag("page"); Text("Web address").tag("url")
                }.pickerStyle(.segmented).labelsHidden()
                if linkDestination == "page" { TextField("Page", value: $linkPage, format: .number) }
                else { TextField("https://example.com", text: $linkURL) }
                Button("Apply Link") {
                    state.setContentLink(state.selectedContentItem,
                        page: linkDestination == "page" ? linkPage - 1 : nil,
                        uri: linkDestination == "url" ? linkURL : nil)
                }.buttonStyle(ReaderPanelButtonStyle(prominent: true))
            } else {
                Text("Link to a page in this document or a web address.")
                    .font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
            }
        }
    }

    private func imageOptions(_ item: PDFContentItem) -> some View {
        ReaderPanelSection(title: "Image") {
            if let imagePreview {
                Image(nsImage: imagePreview).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 150).padding(8)
                    .background(LyraReaderTheme.fieldBg, in: RoundedRectangle(cornerRadius: 6))
            }
            Button { state.chooseContentImage(replacing: item) } label: { Label("Replace Image…", systemImage: "photo") }
                .disabled(item.paths.contains { $0.count != 1 })
            Button { state.exportContentImage(item) } label: { Label("Export Image…", systemImage: "square.and.arrow.up") }
            if item.paths.allSatisfy({ $0.count == 1 }) {
                Button { showCrop.toggle() } label: { Label("Crop…", systemImage: "crop") }
                if showCrop {
                    Text("Retained edges (%)").font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                    HStack { number("Left", $cropLeft); number("Right", $cropRight) }
                    HStack { number("Top", $cropTop); number("Bottom", $cropBottom) }
                    Button("Apply Crop") {
                        state.cropContentImage(item, to: CGRect(x: cropLeft / 100, y: cropTop / 100,
                            width: (cropRight - cropLeft) / 100, height: (cropBottom - cropTop) / 100))
                    }.disabled(cropLeft < 0 || cropTop < 0 || cropRight > 100 || cropBottom > 100 ||
                        cropRight <= cropLeft || cropBottom <= cropTop)
                }
            }
        }
    }

    private func textOptions(_ item: PDFContentItem) -> some View {
        ReaderPanelSection(title: "Text") {
            Text(item.text).font(.custom(font == "Original" ? item.font : font, size: min(24, max(10, size))))
                .foregroundStyle(colour).lineLimit(4).frame(maxWidth: .infinity, minHeight: 88)
                .padding(10).background(LyraReaderTheme.fieldBg, in: RoundedRectangle(cornerRadius: 6))
            if let reason = item.reason { Text(reason).font(.caption).foregroundStyle(LyraReaderTheme.textSecondary) }
            if item.can_edit_text {
                Picker("Font", selection: $font) { ForEach(fonts, id: \.self) { Text($0) } }
                    .labelsHidden().frame(maxWidth: .infinity)
                number("Size (pt)", $size)
                Picker("Alignment", selection: $alignment) {
                    Image(systemName: "text.alignleft").tag(0)
                    Image(systemName: "text.aligncenter").tag(1)
                    Image(systemName: "text.alignright").tag(2)
                }.pickerStyle(.segmented)
                ColorPicker("Text Color", selection: $colour, supportsOpacity: false).font(.system(size: 12))
                Button("Apply Text Style") {
                    let c = NSColor(colour).usingColorSpace(.deviceRGB) ?? .black
                    state.replaceContentText(item, text: item.text, font: font, size: size,
                        colour: [UInt8((c.redComponent * 255).rounded()), UInt8((c.greenComponent * 255).rounded()),
                            UInt8((c.blueComponent * 255).rounded()), 255], alignment: alignment)
                }.buttonStyle(ReaderPanelButtonStyle(prominent: true))
            }
        }
    }

    private func geometry(_ item: PDFContentItem) -> some View {
        ReaderPanelSection(title: "Position & Size") {
            HStack { number("X", $x); number("Y", $y) }
            HStack { number("Width", $width); number("Height", $height) }
            Button("Apply Position & Size") {
                state.transformContent(item, to: CGRect(x: x, y: y, width: width, height: height))
            }
            HStack(spacing: 8) {
                Button { state.transformContent(item, to: item.bounds.rect, rotation: -90) } label: { Image(systemName: "rotate.left") }
                    .accessibilityLabel("Rotate left")
                Button { state.transformContent(item, to: item.bounds.rect, rotation: 90) } label: { Image(systemName: "rotate.right") }
                    .accessibilityLabel("Rotate right")
                Button("Delete", role: .destructive) { state.deleteContent(item) }
                    .disabled(item.paths.contains { $0.count != 1 })
            }
        }
    }

    private func number(_ label: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
            TextField(label, value: value, format: .number).labelsHidden()
        }
    }

    private var recovery: some View {
        ReaderPanelSection(title: "Recovered Text Draft") {
            TextEditor(text: Binding(get: { state.contentTextRecovery ?? "" }, set: { state.contentTextRecovery = $0 }))
                .frame(minHeight: 100).scrollContentBackground(.hidden).background(LyraReaderTheme.fieldBg)
            Picker("Font", selection: $font) { ForEach(fonts, id: \.self) { Text($0) } }
            HStack {
                Button("Retry") { state.retryContentText(font: font) }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.contentTextRecovery ?? "", forType: .string)
                }
                Button("Discard") { state.discardContentTextRecovery() }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if state.isReadOnlyDocument {
                Text("Signed original is read-only. Save an unsigned copy to keep changes.")
                    .font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
            }
            HStack {
                Button { state.undoPageEdit() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.disabled(!state.canUndoPageEdit)
                Button { state.redoPageEdit() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }.disabled(!state.canRedoPageEdit)
            }
            Button(state.isReadOnlyDocument ? "Save a Copy…" : "Save") { state.saveDocument() }
                .buttonStyle(ReaderPanelButtonStyle(prominent: true)).disabled(!state.canSaveDocument)
        }
    }

    private func syncSelection() {
        guard let item = state.selectedContentItem else { return }
        font = "Original"; size = item.size
        x = item.bounds.x; y = item.bounds.y; width = item.bounds.width; height = item.bounds.height
        linkDestination = item.link_uri == nil ? "page" : "url"
        linkPage = (item.link_page ?? 0) + 1; linkURL = item.link_uri ?? "https://"
        if item.colour.count == 4 {
            colour = Color(red: Double(item.colour[0]) / 255, green: Double(item.colour[1]) / 255, blue: Double(item.colour[2]) / 255)
        }
    }
}
