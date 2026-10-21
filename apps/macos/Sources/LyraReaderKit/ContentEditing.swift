import AppKit
import SwiftUI

public struct PDFContentBox: Codable, Equatable, Sendable {
  public var x: Double, y: Double, width: Double, height: Double
  public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
  public init(_ rect: CGRect) {
    x = rect.minX
    y = rect.minY
    width = rect.width
    height = rect.height
  }
}

public struct PDFContentItem: Codable, Identifiable, Equatable, Sendable {
  public var id: String, kind: String, bounds: PDFContentBox, text: String, font: String,
    size: Double
  public var colour: [UInt8], can_edit_text: Bool, reason: String?
  public var paths: [[Int]]
  public var link_page: Int?, link_uri: String?
}

public struct PDFContentPage: Codable, Equatable, Sendable {
  public var revision: String, page: Int, items: [PDFContentItem]
}

public struct PDFContentCommand: Encodable, Sendable {
  public var action: String, revision: String
  public var target: String? = nil
  public var bounds: PDFContentBox? = nil
  public var rotation: Double? = nil
  public var text: String? = nil
  public var font: String? = nil
  public var size: Double? = nil
  public var colour: [UInt8]? = nil
  public var alignment: Int? = nil
  public var blackout: Bool? = nil
  public var image_path: String? = nil
  public var crop: PDFContentBox? = nil
  public var page: Int? = nil
  public var uri: String? = nil
}

/// A native overlay owns pointer interaction only while Edit is active. The PDF itself stays
/// rendered by the regular canvas; selection chrome and a real NSTextView sit above it.
struct PDFContentEditor: NSViewRepresentable {
  @ObservedObject var state: AppState
  func makeNSView(context: Context) -> ContentEditorView { ContentEditorView() }
  static func dismantleNSView(_ view: ContentEditorView, coordinator: ()) {
    // SwiftUI tears down representables while its graph is being invalidated. Publishing an
    // editor-state change inside that transaction causes an exclusivity trap.
    Task { @MainActor in view.commitText() }
  }
  func updateNSView(_ view: ContentEditorView, context: Context) {
    view.state = state
    view.needsDisplay = true
    view.window?.acceptsMouseMovedEvents = true
  }
}

final class ContentEditorView: NSView, NSTextViewDelegate {
  weak var state: AppState? {
    didSet { state?.commitContentText = { [weak self] in self?.commitText() } }
  }
  private var tracking: NSTrackingArea?
  private var hover: String?
  var hoveredContentID: String? { hover }
  private var origin: CGPoint?
  private var original: CGRect?
  private var preview: CGRect?
  private var editor: NSTextView?
  private var editingItem: PDFContentItem?
  private var editingRevision: String?
  private var editingPage: Int?
  private var editingURL: URL?
  private var wasSelected = false
  private var guides: [CGFloat] = []
  private var horizontalGuides: [CGFloat] = []
  private var resizeCorner: Int?
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }
  private func frame(_ item: PDFContentItem) -> CGRect? {
    guard let state, let page = state.contentEditPage,
      let placement = state.canvasPageFrames.first(where: { $0.index == page.page })
    else { return nil }
    let z = state.zoomFactor
    let r = item.bounds.rect
    let offset = max(0, (bounds.width - state.contentWidthPt * z) / 2)
    // `viewRect(local:onPage:)` is the piecewise mapping: one rectangle for an ordinary page,
    // the union of the two pieces for an item that crosses a tear.
    if let rect = state.viewRect(local: r, onPage: page.page) { return rect }
    return CGRect(
      x: offset + (placement.leftPt + r.minX) * z,
      y: (placement.topPt + r.minY - state.scrollYPt) * z, width: r.width * z, height: r.height * z)
  }
  private func local(_ rect: CGRect) -> CGRect? {
    guard let state, let page = state.contentEditPage,
      let placement = state.canvasPageFrames.first(where: { $0.index == page.page })
    else { return nil }
    let z = state.zoomFactor
    let offset = max(0, (bounds.width - state.contentWidthPt * z) / 2)
    let contentY = rect.minY / z + state.scrollYPt
    let localY = state.pageLocalY(forContentY: contentY, onPage: page.page)
      ?? (rect.minY / z + state.scrollYPt - placement.topPt)
    return CGRect(
      x: (rect.minX - offset) / z - placement.leftPt,
      y: localY, width: rect.width / z,
      height: rect.height / z)
  }
  private func hit(_ point: CGPoint) -> PDFContentItem? {
    state?.contentEditPage?.items.filter {
      (state?.contentEditTool == "link" ? $0.kind == "link" :
        state?.contentEditTool == "text" ? $0.kind == "text" :
        state?.contentEditTool == "image" ? ["image", "graphic"].contains($0.kind) : $0.kind != "link")
        && frame($0)?.insetBy(dx: -3, dy: -3).contains(point) == true
    }
    .min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
  }
  override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    hover = hit(point)?.id
    if hover == state?.contentEditSelection {
      NSCursor.openHand.set()
    } else {
      NSCursor.arrow.set()
    }
    needsDisplay = true
  }
  override func mouseExited(with event: NSEvent) {
    hover = nil
    needsDisplay = true
  }
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    commitText()
    let point = convert(event.locationInWindow, from: nil)
    guard let state, !state.pageEditBusy, !state.contentEditLoading, !state.contentCommandInFlight,
      state.contentTextRecovery == nil
    else { return }
    if state.contentEditTool == "erase" || state.contentEditTool == "blackout" {
      origin = point
      original = nil
      preview = nil
      state.contentEditSelection = nil
      return
    }
    if state.contentEditTool == "link", hit(point) == nil {
      origin = point
      original = nil
      preview = nil
      state.contentEditSelection = nil
      return
    }
    if state.contentEditTool == "text", hit(point) == nil,
      let rect = local(CGRect(x: point.x, y: point.y, width: 250, height: 70))
    {
      state.insertContentText(at: rect)
      return
    }
    if state.contentEditTool == "image", hit(point) == nil,
      let rect = local(CGRect(origin: point, size: CGSize(width: 1, height: 1)))
    {
      state.chooseContentImage(at: rect)
      return
    }
    resizeCorner = nil
    if let item = state.selectedContentItem, let rect = frame(item) {
      let corners = [
        CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
        CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
      ]
      if let index = corners.firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) < 7 }) {
        resizeCorner = index
        origin = point
        original = rect
        preview = nil
        return
      }
    }
    guard let item = hit(point), let rect = frame(item) else {
      state.contentEditSelection = nil
      needsDisplay = true
      return
    }
    wasSelected = state.contentEditSelection == item.id
    state.contentEditSelection = item.id
    origin = point
    original = rect
    preview = nil
    guides = []
    horizontalGuides = []
    needsDisplay = true
  }
  override func mouseDragged(with event: NSEvent) {
    if let origin,
      state?.contentEditTool == "erase" || state?.contentEditTool == "blackout"
        || (state?.contentEditTool == "link" && original == nil)
    {
      let point = convert(event.locationInWindow, from: nil)
      preview = CGRect(
        x: min(origin.x, point.x), y: min(origin.y, point.y), width: abs(point.x - origin.x),
        height: abs(point.y - origin.y))
      needsDisplay = true
      return
    }
    guard let origin, let original, let state else { return }
    let point = convert(event.locationInWindow, from: nil)
    var rect = original.offsetBy(dx: point.x - origin.x, dy: point.y - origin.y)
    if let corner = resizeCorner {
      let left = (corner == 0 || corner == 3) ? min(point.x, original.maxX - 2) : original.minX
      let right = (corner == 1 || corner == 2) ? max(point.x, original.minX + 2) : original.maxX
      let top = (corner == 0 || corner == 1) ? min(point.y, original.maxY - 2) : original.minY
      let bottom = (corner == 2 || corner == 3) ? max(point.y, original.minY + 2) : original.maxY
      preview = CGRect(x: left, y: top, width: right - left, height: bottom - top)
      needsDisplay = true
      return
    }
    guides = []
    horizontalGuides = []
    for item in state.contentEditPage?.items ?? [] where item.id != state.contentEditSelection {
      guard let other = frame(item) else { continue }
      for x in [other.minX, other.midX, other.maxX] {
        for edge in [rect.minX, rect.midX, rect.maxX] where abs(x - edge) < 4 {
          rect.origin.x += x - edge
          guides.append(x)
          break
        }
      }
      for y in [other.minY, other.midY, other.maxY] {
        if let edge = [rect.minY, rect.midY, rect.maxY].first(where: { abs(y - $0) < 4 }) {
          rect.origin.y += y - edge
          horizontalGuides.append(y)
        }
      }
    }
    preview = rect
    NSCursor.closedHand.set()
    needsDisplay = true
  }
  override func mouseUp(with event: NSEvent) {
    defer {
      origin = nil
      original = nil
      preview = nil
      resizeCorner = nil
      guides = []
      horizontalGuides = []
      needsDisplay = true
    }
    if state?.contentEditTool == "erase" || state?.contentEditTool == "blackout" {
      if let preview, preview.width > 2, preview.height > 2, let rect = local(preview) {
        state?.redactContent(in: rect, blackout: state?.contentEditTool == "blackout")
      }
      return
    }
    if state?.contentEditTool == "link", original == nil {
      if let preview, preview.width > 2, preview.height > 2, let rect = local(preview) {
        state?.contentLinkDraft = rect
      }
      return
    }
    guard let state, let selected = state.selectedContentItem else { return }
    if let preview, let original,
      resizeCorner != nil || hypot(preview.minX - original.minX, preview.minY - original.minY) > 2,
      let rect = local(preview)
    {
      state.transformContent(selected, to: rect)
      return
    }
    if wasSelected && selected.can_edit_text {
      beginText(selected, at: convert(event.locationInWindow, from: nil))
    }
  }
  override func draw(_ dirtyRect: NSRect) {
    guard let state else { return }
    if let preview, state.contentEditTool == "erase" || state.contentEditTool == "blackout" {
      (state.contentEditTool == "erase" ? NSColor.white : NSColor.black).withAlphaComponent(0.7)
        .setFill()
      NSBezierPath(rect: preview).fill()
    }
    if state.contentEditTool == "link",
      let rect = preview
        ?? state.contentLinkDraft.flatMap({ local in
          guard let page = state.contentEditPage,
                let placement = state.canvasPageFrames.first(where: {
                  $0.index == page.page
                })
          else { return nil as CGRect? }
          let z = state.zoomFactor
          let offset = max(0, (bounds.width - state.contentWidthPt * z) / 2)
          return state.viewRect(local: local, onPage: page.page) ?? CGRect(
            x: offset + (placement.leftPt + local.minX) * z,
            y: (placement.topPt + local.minY - state.scrollYPt) * z, width: local.width * z,
            height: local.height * z)
        })
    {
      NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
      NSBezierPath(rect: rect).fill()
      NSColor.controlAccentColor.setStroke()
      NSBezierPath(rect: rect).stroke()
    }
    for item in state.contentEditPage?.items ?? [] {
      if state.contentEditTool == "link", item.kind == "link", let rect = frame(item) {
        NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(rect: rect).fill()
        (item.text as NSString).draw(
          in: rect,
          withAttributes: [
            .font: NSFont.systemFont(ofSize: min(12, max(7, rect.height - 1))),
            .foregroundColor: NSColor.white,
          ])
      }
      guard item.id == hover || item.id == state.contentEditSelection, let base = frame(item) else {
        continue
      }
      let selected = item.id == state.contentEditSelection
      let r = selected ? preview ?? base : base
      NSColor.controlAccentColor.setStroke()
      let path = NSBezierPath(rect: r)
      path.lineWidth = 1
      if selected { path.setLineDash([5, 4], count: 2, phase: 0) }
      path.stroke()
      if selected {
        for point in [
          CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
          CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
        ] {
          NSColor.white.setFill()
          let handle = NSBezierPath(
            ovalIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
          handle.fill()
          handle.stroke()
        }
      }
    }
    NSColor.systemPink.setStroke()
    for x in guides {
      let p = NSBezierPath()
      p.move(to: CGPoint(x: x, y: 0))
      p.line(to: CGPoint(x: x, y: bounds.height))
      p.stroke()
    }
    for y in horizontalGuides {
      let p = NSBezierPath()
      p.move(to: CGPoint(x: 0, y: y))
      p.line(to: CGPoint(x: bounds.width, y: y))
      p.stroke()
    }
  }
  private func beginText(_ item: PDFContentItem, at point: CGPoint) {
    guard let rect = frame(item), let state else { return }
    let scroll = NSScrollView(frame: rect.insetBy(dx: -2, dy: -3))
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    let textView = NSTextView(frame: CGRect(origin: .zero, size: scroll.contentSize))
    textView.isRichText = false
    textView.allowsUndo = true
    textView.drawsBackground = true
    textView.backgroundColor = .textBackgroundColor
    textView.font = contentEditorFont(item.font, size: item.size * state.zoomFactor)
    textView.string = item.text
    textView.textContainerInset = NSSize(width: 2, height: 2)
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.delegate = self
    scroll.documentView = textView
    addSubview(scroll)
    editor = textView
    editingItem = item
    editingRevision = state.contentEditPage?.revision
    editingPage = state.contentEditPage?.page
    editingURL = state.document?.url
    state.contentTextEditing = true
    window?.makeFirstResponder(textView)
    let position = textView.characterIndexForInsertion(at: convert(point, to: textView))
    textView.setSelectedRange(
      NSRange(location: min(position, textView.string.utf16.count), length: 0))
  }
  func commitText() {
    guard let editor, let item = editingItem else { return }
    state?.contentTextEditing = false
    let value = editor.string
    (editor.enclosingScrollView ?? editor).removeFromSuperview()
    self.editor = nil
    editingItem = nil
    if value != item.text, editingRevision == state?.contentEditPage?.revision {
      state?.replaceContentText(item, text: value)
    } else if value != item.text, let revision = editingRevision, let page = editingPage {
      state?.recoverDetachedContentText(
        item, text: value, revision: revision, page: page, url: editingURL)
    }
    editingRevision = nil
  }
  func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      (textView.enclosingScrollView ?? textView).removeFromSuperview()
      editor = nil
      editingItem = nil
      state?.contentTextEditing = false
      window?.makeFirstResponder(self)
      return true
    }
    if commandSelector == #selector(NSResponder.insertNewline(_:)),
      NSApp.currentEvent?.modifierFlags.contains(.command) == true
    {
      commitText()
      window?.makeFirstResponder(self)
      return true
    }
    return false
  }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 51, let item = state?.selectedContentItem {
      state?.deleteContent(item)
      return
    }
    if event.keyCode == 53 {
      commitText()
      state?.contentEditEnabled = false
      return
    }
    super.keyDown(with: event)
  }
  override func scrollWheel(with event: NSEvent) {
    guard editor == nil, let state else {
      super.scrollWheel(with: event)
      return
    }
    if event.hasPreciseScrollingDeltas {
      state.scroll(byScreenPoints: event.scrollingDeltaY)
    } else {
      state.scrollByWheelStep(event.scrollingDeltaY)
    }
  }
}

extension PageImage {
  func contentPNGData() -> Data? {
    guard pixelWidth > 0, pixelHeight > 0, bgra.count >= pixelWidth * pixelHeight * 4,
      let provider = CGDataProvider(data: bgra as CFData),
      let image = CGImage(
        width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(
          .byteOrder32Little),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
  }
}

/// Embedded subset names frequently have no installed AppKit face. Use a matching local family
/// for the temporary caret display; the PDF writer still reuses the actual embedded font.
func contentEditorFont(_ pdfName: String, size: CGFloat) -> NSFont {
  let name = pdfName.replacingOccurrences(of: "^[A-Z]{6}\\+", with: "", options: .regularExpression)
  if let font = NSFont(name: name, size: size) { return font }
  let lower = name.lowercased()
  let family =
    lower.contains("times") || lower.contains("nimbusrom") || lower.hasPrefix("cmr")
    ? "Times New Roman"
    : (lower.contains("courier") || lower.contains("nimbusmono") ? "Courier" : "Helvetica")
  let base = NSFont(name: family, size: size) ?? NSFont.systemFont(ofSize: size)
  var traits: NSFontTraitMask = []
  if lower.contains("bold") || lower.contains("-medi") || lower.hasPrefix("cmb") {
    traits.insert(.boldFontMask)
  }
  if lower.contains("italic") || lower.contains("oblique") || lower.contains("-ital") {
    traits.insert(.italicFontMask)
  }
  return NSFontManager.shared.convert(base, toHaveTrait: traits)
}
