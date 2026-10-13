import Foundation

/// Summary of an opened document (a value-semantics snapshot mirroring the Rust-side `DocumentSnapshot`).
///
/// This is a hand-written struct during the skeleton phase; after M0 T0.9 it is replaced by the
/// UniFFI-generated type, at which point only the `DocumentSummary` definition in this file
/// needs to be deleted.
public struct DocumentSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var pageCount: Int
    public var url: URL?

    public init(id: UUID = UUID(), title: String, pageCount: Int, url: URL? = nil) {
        self.id = id
        self.title = title
        self.pageCount = pageCount
        self.url = url
    }
}

/// Engine interface.
///
/// **Design intent**: the UI depends only on this protocol, so the real implementation (the Rust
/// engine) and the fake one (`MockEngine`) are interchangeable. That way UI work is not blocked
/// while the Swift toolchain or the Rust bindings are still being prepared
/// (route P-C in `docs/07-roadmap.md`).
///
/// During the skeleton phase it is synchronous and pinned to the main actor; after M0 it becomes
/// `async` and the real work moves down to the Rust control thread
/// (see `docs/02-architecture.md` §3).
@MainActor
public protocol PDFEngine: AnyObject {
    func openDocument(at url: URL) throws -> DocumentSummary
    /// Engine version string (used by the About panel and for diagnostics).
    var version: String { get }
}

/// Mock engine for the skeleton phase: it does not parse PDFs, it only reports file information.
@MainActor
public final class MockEngine: PDFEngine {
    public init() {}

    public var version: String { "mock-engine (the Rust engine arrives in M0 T0.8)" }

    public func openDocument(at url: URL) throws -> DocumentSummary {
        let title = url.deletingPathExtension().lastPathComponent
        return DocumentSummary(title: title, pageCount: 0, url: url)
    }
}
