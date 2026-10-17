import CoreGraphics
import Foundation

/// The contiguous run of pages one thumbnail drag moves.
///
/// A drag starts on one thumbnail. When that thumbnail is part of a contiguous page selection the
/// whole selection travels, in its existing order; when it is not selected only the pressed page
/// travels. That rule is decided once, when the drag begins, so the block the drag image advertises
/// is the block the drop stages.
public struct ThumbnailDragBlock: Equatable, Sendable {
    /// Sorted, contiguous, 0-based page indices.
    public let pages: [Int]
    /// The thumbnail the reader grabbed.
    public let pressedPage: Int

    public init(pages: [Int], pressedPage: Int) {
        self.pages = pages
        self.pressedPage = pressedPage
    }

    public var count: Int { pages.count }

    public var isSelection: Bool { pages.count > 1 || pages.first != pressedPage }
}

/// Why a drag cannot become a page move.
///
/// The thumbnail strip shows no insertion indicator for these, so a reader never sees a landing
/// mark for a drop the staged session would refuse.
public enum ThumbnailDragRefusal: Equatable, Sendable {
    case noDocument
    /// The page-edit session is busy (an annotation save or another operation is in flight).
    case cannotEdit
    /// The page selection has gaps, so there is no block to move in order.
    case scatteredSelection
    /// The block would be inserted exactly where it already is.
    case noChange
    /// The pointer is not over the thumbnail strip (a cancelled drag).
    case outsideStrip

    public var message: String {
        switch self {
        case .noDocument:
            return "Open a document to reorder its pages."
        case .cannotEdit:
            return "Page changes are unavailable while another change is being saved."
        case .scatteredSelection:
            return "Move requires a contiguous selection; select a range of pages, not a scattered set."
        case .noChange:
            return "The pages would land where they already are."
        case .outsideStrip:
            return "Drop the pages on the thumbnail strip to move them."
        }
    }
}

/// What a drag that starts on a thumbnail would move, or why it cannot move at all.
public enum ThumbnailDragBlockResolution: Equatable, Sendable {
    case block(ThumbnailDragBlock)
    case refused(ThumbnailDragRefusal)

    public var block: ThumbnailDragBlock? {
        if case .block(let block) = self { return block }
        return nil
    }
}

/// A request to stage one drag. `destination` is the page index **after** the block is removed,
/// which is exactly what ``PageEditOperation/move(pages:destination:)`` takes.
public struct ThumbnailDropRequest: Equatable, Sendable {
    public let pages: [Int]
    public let destination: Int
    public let pressedPage: Int

    public init(pages: [Int], destination: Int, pressedPage: Int) {
        self.pages = pages
        self.destination = destination
        self.pressedPage = pressedPage
    }

    /// The block's final page range, after the move.
    public var finalRange: Range<Int> { destination..<(destination + pages.count) }
}

/// What dropping at one insertion boundary would do.
public enum ThumbnailDropResolution: Equatable, Sendable {
    case move(ThumbnailDropRequest)
    case refused(ThumbnailDragRefusal)

    public var request: ThumbnailDropRequest? {
        if case .move(let request) = self { return request }
        return nil
    }
}

/// The rules shared by the AppKit drag source, the drop target and the headless checks.
///
/// Everything here is a value decision: which pages a drag carries, where a pointer between two
/// thumbnails lands, and whether that landing is a no-op. The view layer owns only the AppKit drag
/// session and drawing; it asks these rules rather than re-deriving them.
public enum ThumbnailDrag {
    /// How far the pointer must travel before a press becomes a drag. Below this the press remains
    /// a click, so clicking a thumbnail still navigates exactly as it did before drag support.
    public static let thresholdPt: CGFloat = 4

    /// The block a drag starting on `pressedPage` carries.
    public static func block(
        pressedPage: Int,
        selection: Set<Int>,
        pageCount: Int,
        isEditable: Bool
    ) -> ThumbnailDragBlockResolution {
        guard pageCount > 0, pressedPage >= 0, pressedPage < pageCount else {
            return .refused(.noDocument)
        }
        guard isEditable else { return .refused(.cannotEdit) }

        let selected = selection.filter { $0 >= 0 && $0 < pageCount }
        guard selected.contains(pressedPage) else {
            return .block(ThumbnailDragBlock(pages: [pressedPage], pressedPage: pressedPage))
        }
        let pages = selected.sorted()
        guard let first = pages.first, let last = pages.last,
              last - first + 1 == pages.count else {
            return .refused(.scatteredSelection)
        }
        return .block(ThumbnailDragBlock(pages: pages, pressedPage: pressedPage))
    }

    /// Where a block dropped at `boundary` lands.
    ///
    /// `boundary` counts gaps in the *current* page list: 0 is before the first page and
    /// `pageCount` is after the last. A boundary inside the dragged block — or immediately after
    /// it, which is the same position once the block is lifted out — is a no-op and is refused.
    public static func drop(
        block: ThumbnailDragBlock,
        boundary: Int?,
        pageCount: Int
    ) -> ThumbnailDropResolution {
        guard let boundary else { return .refused(.outsideStrip) }
        guard pageCount > 0, boundary >= 0, boundary <= pageCount,
              let first = block.pages.first, let last = block.pages.last,
              first >= 0, last < pageCount,
              last - first + 1 == block.pages.count else {
            return .refused(.noDocument)
        }
        if boundary > first, boundary <= last + 1 {
            return .refused(.noChange)
        }
        let destination = boundary > last ? boundary - block.count : boundary
        guard destination >= 0, destination + block.count <= pageCount else {
            return .refused(.outsideStrip)
        }
        guard destination != first else { return .refused(.noChange) }
        return .move(ThumbnailDropRequest(
            pages: block.pages,
            destination: destination,
            pressedPage: block.pressedPage
        ))
    }
}

/// Decides whether a press is still a click.
///
/// The thumbnail strip needs both gestures on the same pixels: a press that does not move must
/// keep navigating, and only a press that travels past ``ThumbnailDrag/thresholdPt`` becomes a
/// drag. This is deliberately a value type so the headless checks can drive the same decision the
/// AppKit source uses.
public struct ThumbnailPressTracker: Equatable, Sendable {
    public let page: Int
    public let start: CGPoint
    public let thresholdPt: CGFloat
    public private(set) var isDragging = false

    public init(
        page: Int,
        at start: CGPoint,
        thresholdPt: CGFloat = ThumbnailDrag.thresholdPt
    ) {
        self.page = page
        self.start = start
        self.thresholdPt = thresholdPt
    }

    /// Records a pointer move. Returns `true` once the press has become a drag.
    @discardableResult
    public mutating func moved(to point: CGPoint) -> Bool {
        guard !isDragging else { return true }
        let dx = point.x - start.x
        let dy = point.y - start.y
        if dx * dx + dy * dy >= thresholdPt * thresholdPt {
            isDragging = true
        }
        return isDragging
    }

    /// A release without crossing the threshold is a click, not a drag.
    public var isClick: Bool { !isDragging }
}

/// One visible thumbnail cell, in the strip's own coordinate space (top-left origin).
public struct ThumbnailCellFrame: Equatable, Sendable {
    public let page: Int
    public let rect: CGRect

    public init(page: Int, rect: CGRect) {
        self.page = page
        self.rect = rect
    }
}

/// The visible thumbnail cells and the area a drop may land in.
///
/// The strip is an adaptive grid, so the insertion boundary is derived from reading order: rows
/// top to bottom, cells left to right. In a single-column row the pointer's half of the thumbnail
/// decides before/after; in a multi-column row the horizontal midpoint does. Dropping outside the
/// strip returns no boundary, which the caller treats as a cancelled drag.
public struct ThumbnailStripGeometry: Equatable, Sendable {
    public let pageCount: Int
    /// Visible cells only, keyed by page. Lazy grids only lay out what is on screen.
    public let frames: [Int: CGRect]
    /// The strip's bounds in its own coordinate space.
    public let bounds: CGRect

    public init(pageCount: Int, frames: [Int: CGRect], bounds: CGRect) {
        self.pageCount = pageCount
        self.frames = frames
        self.bounds = bounds
    }

    /// The insertion boundary (0...pageCount) for a pointer at `point`, or `nil` outside the strip.
    public func insertionBoundary(at point: CGPoint) -> Int? {
        guard bounds.contains(point), pageCount > 0 else { return nil }
        let cells = frames
            .filter { $0.key >= 0 && $0.key < pageCount }
            .sorted { lhs, rhs in
                lhs.value.minY == rhs.value.minY
                    ? lhs.value.minX < rhs.value.minX
                    : lhs.value.minY < rhs.value.minY
            }
            .map { (page: $0.key, rect: $0.value) }
        guard !cells.isEmpty else { return nil }

        // Split cells into visual rows by vertical overlap: taller cells can shift a row's top,
        // and an adaptive grid gives every cell in a row the same slot.
        var rows: [[(page: Int, rect: CGRect)]] = []
        for cell in cells {
            if var row = rows.last,
               let rowBottom = row.map(\.rect.maxY).max(),
               cell.rect.minY < rowBottom - 0.5 {
                row.append(cell)
                rows[rows.count - 1] = row
            } else {
                rows.append([cell])
            }
        }
        guard !rows.isEmpty else { return nil }

        // Above or below every visible row the vertical position decides, not the horizontal
        // one: dropping in the blank area under a two-column grid means "after the last row",
        // not "before whichever cell happens to sit above the pointer's x".
        if let finalRow = rows.last,
           let finalBottom = finalRow.map(\.rect.maxY).max(),
           let finalPage = finalRow.map(\.page).max(),
           point.y > finalBottom {
            return clamp(finalPage + 1)
        }
        if let firstRow = rows.first,
           let firstTop = firstRow.map(\.rect.minY).min(),
           let firstPage = firstRow.map(\.page).min(),
           point.y < firstTop {
            return clamp(firstPage)
        }

        let row = rows.min { lhs, rhs in
            verticalDistance(from: point.y, to: lhs) < verticalDistance(from: point.y, to: rhs)
        } ?? rows[0]
        let ordered = row.sorted { $0.rect.minX < $1.rect.minX }
        guard let first = ordered.first, let last = ordered.last else { return nil }

        if ordered.count == 1 {
            // One thumbnail across: insertion is above or below it.
            let cell = first
            return clamp(cell.rect.midY > point.y ? cell.page : cell.page + 1)
        }

        // Multi-column row: the horizontal midpoint is the boundary between cells.
        if point.x < first.rect.midX {
            return clamp(first.page)
        }
        if point.x >= last.rect.midX {
            return clamp(last.page + 1)
        }
        for cell in ordered where point.x < cell.rect.midX {
            return clamp(cell.page)
        }
        return clamp(last.page + 1)
    }

    /// Where to draw the insertion line for a boundary, in strip coordinates.
    ///
    /// A boundary before a visible page sits just left of that page; the end-of-document boundary
    /// sits just right of the last page. Every other case (an off-screen boundary, which a valid
    /// drop does not produce) uses the nearest visible cell.
    public func indicatorRect(for boundary: Int) -> CGRect? {
        guard boundary >= 0, boundary <= pageCount else { return nil }
        let anchor: (rect: CGRect, before: Bool)?
        if boundary < pageCount, let frame = frames[boundary] {
            anchor = (frame, true)
        } else if boundary == pageCount, let last = frames[pageCount - 1] {
            anchor = (last, false)
        } else if let nearest = nearestFrame(to: boundary) {
            anchor = (nearest, nearestPage(before: boundary))
        } else {
            anchor = nil
        }
        guard let anchor else { return nil }
        let x = anchor.before ? anchor.rect.minX - 5 : anchor.rect.maxX + 2
        let clampedX = min(max(x, bounds.minX + 1), bounds.maxX - 4)
        return CGRect(
            x: clampedX,
            y: anchor.rect.minY,
            width: 3,
            height: max(anchor.rect.height, 8)
        )
    }

    private func clamp(_ boundary: Int) -> Int {
        min(max(boundary, 0), pageCount)
    }

    private func verticalDistance(from y: CGFloat, to row: [(page: Int, rect: CGRect)]) -> CGFloat {
        guard let top = row.map(\.rect.minY).min(), let bottom = row.map(\.rect.maxY).max() else {
            return .greatestFiniteMagnitude
        }
        if y < top { return top - y }
        if y > bottom { return y - bottom }
        return 0
    }

    private func nearestFrame(to boundary: Int) -> CGRect? {
        let candidates = frames.keys.filter { $0 >= 0 && $0 < pageCount }.sorted()
        guard let page = candidates.min(by: {
            abs($0 - boundary) < abs($1 - boundary)
        }) else { return nil }
        return frames[page]
    }

    private func nearestPage(before boundary: Int) -> Bool {
        let candidates = frames.keys.filter { $0 >= 0 && $0 < pageCount }
        guard let page = candidates.min(by: {
            abs($0 - boundary) < abs($1 - boundary)
        }) else { return true }
        return page < boundary
    }
}
