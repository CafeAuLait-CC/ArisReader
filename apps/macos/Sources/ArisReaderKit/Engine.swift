import ArisReaderBindings
import CoreGraphics
import Foundation

/// Snapshot of a document the shell has opened.
///
/// Deliberately *not* called `DocumentSummary`: the UniFFI-generated control plane
/// already exports a record with that name, and this type carries the extra UI state
/// (stable identity, display title) on top of it.
public struct LoadedDocument: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var pageCount: Int
    public var url: URL?
    /// First page size in points, already accounting for `/Rotate`.
    public var firstPageSize: CGSize
    /// Which PDF backend produced this snapshot (shown in diagnostics).
    public var backend: String

    public init(
        id: UUID = UUID(),
        title: String,
        pageCount: Int,
        url: URL? = nil,
        firstPageSize: CGSize = .zero,
        backend: String = "unknown"
    ) {
        self.id = id
        self.title = title
        self.pageCount = pageCount
        self.url = url
        self.firstPageSize = firstPageSize
        self.backend = backend
    }
}

/// A rasterized page on its way to the GPU.
///
/// `bgra` is exactly what PDFium produced and exactly what the GPU layer expects, so
/// nothing converts it on the way (`docs/03-rendering.md` §5).
public struct PageImage: Sendable {
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Page size in points (already rotated); the canvas scales it by the zoom factor.
    public let pointSize: CGSize
    public let bgra: Data
    /// Monotonic id, so the canvas can tell a new rasterization from a repeated one.
    public let generation: UInt64

    public init(
        pixelWidth: Int,
        pixelHeight: Int,
        pointSize: CGSize,
        bgra: Data,
        generation: UInt64
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pointSize = pointSize
        self.bgra = bgra
        self.generation = generation
    }
}

/// Where one page sits in the scrolling content.
///
/// Content space uses PDF points with the origin at the top-left of the first page and Y
/// growing downwards (view space). The canvas multiplies by zoom × backing scale when it
/// draws, so nothing here depends on the display.
public struct PagePlacement: Equatable, Sendable {
    public let index: Int
    public let topPt: CGFloat
    public let leftPt: CGFloat
    public let widthPt: CGFloat
    public let heightPt: CGFloat

    public init(index: Int, topPt: CGFloat, leftPt: CGFloat, widthPt: CGFloat, heightPt: CGFloat) {
        self.index = index
        self.topPt = topPt
        self.leftPt = leftPt
        self.widthPt = widthPt
        self.heightPt = heightPt
    }
}

/// One character of a page's text layer, boxed in view space (points, top-left origin).
public struct TextChar: Sendable {
    public let unicode: UInt32
    public let xPt: CGFloat
    public let yPt: CGFloat
    public let widthPt: CGFloat
    public let heightPt: CGFloat
}

/// A page's text layer.
public struct TextPage: Sendable {
    public let page: Int
    public let chars: [TextChar]
    public let text: String
    public let hasUnicodeMapError: Bool
}

/// One search hit: a character range in a page's text layer.
public struct SearchHit: Sendable {
    public let page: Int
    public let start: Int
    public let end: Int
    public let snippet: String
}

/// One rasterized tile: what `rasterizeTile` hands back.
///
/// Tiles are the unit the shell thinks in once zoom passes what a single page texture can
/// hold; the canvas never learns the difference, because a tile is just another placement
/// with a bitmap.
public struct TileImage: Sendable {
    public let page: Int
    public let lod: UInt8
    public let tileX: Int
    public let tileY: Int
    public let sizePx: Int
    public let bgra: Data
    public let generation: UInt64

    public init(
        page: Int,
        lod: UInt8,
        tileX: Int,
        tileY: Int,
        sizePx: Int,
        bgra: Data,
        generation: UInt64
    ) {
        self.page = page
        self.lod = lod
        self.tileX = tileX
        self.tileY = tileY
        self.sizePx = sizePx
        self.bgra = bgra
        self.generation = generation
    }
}

/// One page ready to be drawn: where it goes and the bitmap that goes there.
public struct CanvasPage: Sendable {
    public let placement: PagePlacement
    public let image: PageImage

    public init(placement: PagePlacement, image: PageImage) {
        self.placement = placement
        self.image = image
    }
}

/// Engine interface.
///
/// The UI depends only on this protocol, so the real engine (`RustEngine`, backed by the
/// UniFFI control plane) and the fallback (`MockEngine`) are interchangeable.
@MainActor
public protocol PDFEngine: AnyObject {
    func openDocument(at url: URL) throws -> LoadedDocument
    /// Rasterizes a page at `scale` (1.0 = 72 dpi, so pass zoom × backing scale).
    ///
    /// Asynchronous because it runs off the main thread: PDFium is not thread-safe, so
    /// implementations serialise calls, but the UI must never wait for them.
    func renderPage(_ page: Int, scale: CGFloat) async throws -> PageImage
    /// Rasterizes one tile of a page at a discrete LOD (`scale = 2^lod`).
    func rasterizeTile(
        page: Int,
        lod: UInt8,
        tileX: Int,
        tileY: Int,
        tileSize: Int
    ) async throws -> TileImage
    /// Extracts the text layer of a page (character boxes in view space).
    func textPage(_ page: Int) async throws -> TextPage
    /// Searches every page for `pattern` (ASCII case-insensitive), in reading order.
    func search(_ pattern: String, limit: Int) async throws -> [SearchHit]
    /// Total height of the scrolling content, in points.
    func contentHeightPt(gapPt: CGFloat) -> CGFloat
    /// Width of the widest page, in points (the canvas centres the content with it).
    func contentWidthPt(gapPt: CGFloat) -> CGFloat
    /// Pages overlapping the viewport, in reading order.
    func visiblePages(
        scrollYPt: CGFloat,
        viewportHeightPt: CGFloat,
        gapPt: CGFloat,
        marginPt: CGFloat
    ) -> [PagePlacement]
    /// Page under the viewport top (the "current page" for the HUD).
    func pageIndex(atScrollYPt scrollYPt: CGFloat, gapPt: CGFloat) -> Int
    /// Top edge of a page in content space (used by "go to page").
    func pageTopPt(_ index: Int, gapPt: CGFloat) -> CGFloat
    /// Engine version plus backend description (About panel, diagnostics).
    var version: String { get }
}

/// The real engine: the UniFFI control plane described in `docs/05-ffi.md`.
@MainActor
public final class RustEngine: PDFEngine {
    private let engine: ArisEngine
    /// The open document. One document per engine for now; the full document/session
    /// graph (several windows, shared documents, event streams) is M1 work.
    private var document: ArisDocument?
    private var generation: UInt64 = 0
    /// Serialises PDFium: the library is not thread-safe, so rasterizations run one at a
    /// time on a dedicated queue and never on the main thread.
    private let rasterQueue = DispatchQueue(label: "com.arisreader.raster", qos: .userInitiated)

    public init() throws {
        self.engine = try ArisEngine()
    }

    public var version: String {
        "\(engine.version()) · \(engine.backend()) · \(engine.rasterThreads()) raster threads"
    }

    public func openDocument(at url: URL) throws -> LoadedDocument {
        let opened = try engine.openDocument(path: url.path, password: nil)
        document = opened

        let firstPage = opened.pageCount() > 0 ? try opened.pageSizePt(page: 0) : nil

        return LoadedDocument(
            title: url.deletingPathExtension().lastPathComponent,
            pageCount: Int(opened.pageCount()),
            url: url,
            firstPageSize: CGSize(
                width: firstPage?.widthPt ?? 0,
                height: firstPage?.heightPt ?? 0
            ),
            backend: engine.backend()
        )
    }

    public func renderPage(_ page: Int, scale: CGFloat) async throws -> PageImage {
        guard let document else {
            throw NSError(
                domain: "ArisReader",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No document is open"]
            )
        }

        generation += 1
        let generation = self.generation
        let requestedScale = Double(scale)

        return try await withCheckedThrowingContinuation { continuation in
            rasterQueue.async {
                let started = DispatchTime.now()
                do {
                    let bitmap = try document.rasterizePage(
                        page: UInt32(page),
                        scale: requestedScale
                    )
                    let milliseconds =
                        Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                    // Written to stderr (unbuffered) on purpose: it is how the
                    // "rasterisation really happens off the main thread" claim stays
                    // verifiable, including when the process is killed mid-run.
                    let line = String(
                        format: "aris-raster: page %d at %.2fx → %dx%d px in %.1f ms (main thread: %@)\n",
                        page,
                        bitmap.scaleUsed,
                        bitmap.widthPx,
                        bitmap.heightPx,
                        milliseconds,
                        Thread.isMainThread ? "yes" : "no"
                    )
                    FileHandle.standardError.write(Data(line.utf8))
                    continuation.resume(
                        returning: PageImage(
                            pixelWidth: Int(bitmap.widthPx),
                            pixelHeight: Int(bitmap.heightPx),
                            pointSize: CGSize(width: bitmap.widthPt, height: bitmap.heightPt),
                            bgra: bitmap.pixels,
                            generation: generation
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func rasterizeTile(
        page: Int,
        lod: UInt8,
        tileX: Int,
        tileY: Int,
        tileSize: Int
    ) async throws -> TileImage {
        guard let document else {
            throw NSError(
                domain: "ArisReader",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No document is open"]
            )
        }

        generation += 1
        let generation = self.generation

        return try await withCheckedThrowingContinuation { continuation in
            rasterQueue.async {
                do {
                    let tile = try document.rasterizeTile(
                        page: UInt32(page),
                        lod: lod,
                        tileX: UInt32(tileX),
                        tileY: UInt32(tileY),
                        tileSize: UInt32(tileSize)
                    )
                    continuation.resume(
                        returning: TileImage(
                            page: page,
                            lod: lod,
                            tileX: tileX,
                            tileY: tileY,
                            sizePx: Int(tile.sizePx),
                            bgra: tile.pixels,
                            generation: generation
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func textPage(_ page: Int) async throws -> TextPage {
        guard let document else {
            throw NSError(
                domain: "ArisReader",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No document is open"]
            )
        }

        return try await withCheckedThrowingContinuation { continuation in
            rasterQueue.async {
                do {
                    let extracted = try document.textPage(page: UInt32(page))
                    continuation.resume(
                        returning: TextPage(
                            page: page,
                            chars: extracted.chars.map { character in
                                TextChar(
                                    unicode: character.unicode,
                                    xPt: CGFloat(character.xPt),
                                    yPt: CGFloat(character.yPt),
                                    widthPt: CGFloat(character.widthPt),
                                    heightPt: CGFloat(character.heightPt)
                                )
                            },
                            text: extracted.text,
                            hasUnicodeMapError: extracted.hasUnicodeMapError
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func search(_ pattern: String, limit: Int) async throws -> [SearchHit] {
        guard let document else { return [] }

        return try await withCheckedThrowingContinuation { continuation in
            rasterQueue.async {
                do {
                    let hits = try document.search(pattern: pattern, limit: UInt32(limit))
                    continuation.resume(
                        returning: hits.map { hit in
                            SearchHit(
                                page: Int(hit.page),
                                start: Int(hit.start),
                                end: Int(hit.end),
                                snippet: hit.snippet
                            )
                        }
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func contentHeightPt(gapPt: CGFloat) -> CGFloat {
        guard let document else { return 0 }
        return CGFloat(document.contentHeightPt(gapPt: Double(gapPt)))
    }

    public func contentWidthPt(gapPt: CGFloat) -> CGFloat {
        guard let document else { return 0 }
        return CGFloat(document.contentWidthPt(gapPt: Double(gapPt)))
    }

    public func visiblePages(
        scrollYPt: CGFloat,
        viewportHeightPt: CGFloat,
        gapPt: CGFloat,
        marginPt: CGFloat
    ) -> [PagePlacement] {
        guard let document else { return [] }
        return document
            .visiblePages(
                scrollYPt: Double(scrollYPt),
                viewportHeightPt: Double(viewportHeightPt),
                gapPt: Double(gapPt),
                marginPt: Double(marginPt)
            )
            .map { record in
                PagePlacement(
                    index: Int(record.index),
                    topPt: CGFloat(record.topPt),
                    leftPt: CGFloat(record.leftPt),
                    widthPt: CGFloat(record.widthPt),
                    heightPt: CGFloat(record.heightPt)
                )
            }
    }

    public func pageIndex(atScrollYPt scrollYPt: CGFloat, gapPt: CGFloat) -> Int {
        guard let document else { return 0 }
        return Int(document.pageIndexAt(scrollYPt: Double(scrollYPt), gapPt: Double(gapPt)))
    }

    public func pageTopPt(_ index: Int, gapPt: CGFloat) -> CGFloat {
        guard let document else { return 0 }
        return CGFloat(document.pageTopPt(page: UInt32(index), gapPt: Double(gapPt)))
}

}

/// Fallback engine for builds where the Rust backend cannot start (for example a build
/// without PDFium): the UI stays usable and says what happened.
@MainActor
public final class MockEngine: PDFEngine {
    public init() {}

    public var version: String { "mock engine (the Rust backend did not start)" }

    public func openDocument(at url: URL) throws -> LoadedDocument {
        LoadedDocument(
            title: url.deletingPathExtension().lastPathComponent,
            pageCount: 0,
            url: url
        )
    }

    public func renderPage(_ page: Int, scale: CGFloat) async throws -> PageImage {
        throw NSError(
            domain: "ArisReader",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "The mock engine cannot rasterize pages"]
        )
    }

    public func rasterizeTile(
        page: Int,
        lod: UInt8,
        tileX: Int,
        tileY: Int,
        tileSize: Int
    ) async throws -> TileImage {
        throw NSError(
            domain: "ArisReader",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "The mock engine cannot rasterize tiles"]
        )
    }

    public func textPage(_ page: Int) async throws -> TextPage {
        throw NSError(
            domain: "ArisReader",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "The mock engine has no text layer"]
        )
    }

    public func search(_ pattern: String, limit: Int) async throws -> [SearchHit] { [] }

    public func contentHeightPt(gapPt: CGFloat) -> CGFloat { 0 }
    public func contentWidthPt(gapPt: CGFloat) -> CGFloat { 0 }
    public func visiblePages(
        scrollYPt: CGFloat,
        viewportHeightPt: CGFloat,
        gapPt: CGFloat,
        marginPt: CGFloat
    ) -> [PagePlacement] { [] }
    public func pageIndex(atScrollYPt scrollYPt: CGFloat, gapPt: CGFloat) -> Int { 0 }
    public func pageTopPt(_ index: Int, gapPt: CGFloat) -> CGFloat { 0 }
}
