import ArisReaderKit
import Foundation

extension ReaderChecks {
    /// The outline fixture's real hierarchy: `depth` has to survive the backend, because the
    /// numbering (`1`, `1.1`, `1.1.1`) and the indentation are both functions of it.
    @MainActor static func outlineNumberingChecks(url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("INFO: skipping outline numbering (no outlined fixture at \(url.path))")
            return
        }
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        state.open(url: url)
        try await eventually("the three-level outline is read", { state.outline.count == 8 })

        let rows = OutlineNumbering.rows(for: state.outline)
        require(
            rows.map(\.number) == ["1", "1.1", "1.1.1", "2", "2.1", "2.1.1", "2.2", "3"],
            "section numbers follow depth, including the section with no page ("
                + "\(rows.map(\.number)))"
        )
        require(
            rows.map(\.depth) == [0, 1, 2, 0, 1, 2, 1, 0],
            "the three levels arrive as three depths, got \(rows.map(\.depth))"
        )
        require(
            rows.map(\.entry.title) == [
                "Chapter One", "Background", "Prior work",
                "Chapter Two", "Method", "Detail", "Setup", "Chapter Three",
            ],
            "the outline is flattened depth-first in document order"
        )
        require(rows[3].entry.page == nil,
                "the section without a destination is still in the outline")
        require(rows[4].depth == 1 && rows[5].depth == 2,
                "its children are indented under it, not promoted to top level")
        // 10 pt per level, down from 14: the user asked for a tighter outline whose left edge
        // sits closer to the sidebar, with hierarchy carried by indentation alone.
        require(rows[0].indentPt == 0 && rows[1].indentPt == 10 && rows[2].indentPt == 20,
                "indentation follows depth by one step per level")
        require(rows[2].entry.page == 1 && rows[7].entry.page == 2,
                "the page targets survive the hierarchy walk")
    }

    /// `/IRT` replies on a committed fixture: nesting, cross-page replies, a hidden parent, an
    /// empty reply and a malformed cycle. The model is the same one the sidebar renders.
    @MainActor static func annotationReplyChecks(url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("INFO: skipping reply checks (no reply fixture at \(url.path))")
            return
        }
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        state.open(url: url)
        try await eventually("the reply fixture's annotations are read", {
            state.documentAnnotations.count == 11 || state.documentAnnotationsError != nil
        })
        require(state.documentAnnotationsError == nil, "reading /IRT annotations does not fail")
        require(state.documentAnnotations.filter(\.isReply).count == 8,
                "all eight /IRT annotations carry isReply")

        let panel = AnnotationPanelModel.build(from: state.documentAnnotations)
        require(panel.sections.count == 2, "one disclosure group per page with a thread")
        require(panel.replyCount == 8 && panel.nestedReplyCount == 4
                    && panel.orphanedReplyCount == 4,
                "eight replies: four nested, four orphaned ("
                    + "\(panel.nestedReplyCount) nested, \(panel.orphanedReplyCount) orphaned)")

        let first = panel.sections[0]
        require(first.page == 0 && first.annotationCount == 5,
                "page 1 has the parent, three replies and the cross-page reply")
        require(first.title == "Page 1 · 5 annotations", "the group label carries the count")
        require(first.rows.map(\.annotation.id) == [
            "nm:parent-highlight", "nm:reply-one", "nm:reply-two", "nm:reply-empty",
            "nm:reply-cross-page",
        ], "replies are nested directly under their parent, in document order")
        require(first.rows.map(\.depth) == [0, 1, 2, 1, 1],
                "a reply to a reply is one level deeper, got \(first.rows.map(\.depth))")
        require(first.rows[2].annotation.author == "Reviewer C",
                "a reply carries its author")
        require(first.rows[2].replyDate == "2024-01-02 03:20",
                "a reply carries its formatted /M date, got \(first.rows[2].replyDate ?? "nil")")
        require(first.rows[2].annotation.contents == "Second-level reply, answering the first reply.",
                "a reply carries its own text")
        require(first.rows[3].annotation.contents == nil,
                "a hidden reply with no text is still part of the thread")
        require(first.rows[4].annotation.page == 1 && first.rows[4].showsPage,
                "a cross-page reply stays in its parent's group and says which page it is on")

        let second = panel.sections[1]
        require(second.page == 1 && second.annotationCount == 5,
                "page 2 has its own note and the replies that could not be nested")
        require(second.rows.map(\.annotation.id) == [
            "nm:parent-note", "nm:reply-to-hidden", "nm:cycle-a", "nm:cycle-b",
            "nm:reply-to-link",
        ], "orphaned replies are shown, not dropped")
        require(second.rows[1].orphanReason == .parentHidden(page: 1),
                "a reply under a hidden parent says the parent is hidden")
        require(second.rows[2].orphanReason == .cycle && second.rows[3].orphanReason == .cycle,
                "a two-annotation cycle is broken and both replies stay visible")
        require(second.rows[4].orphanReason == .parentMissing,
                "a reply to a skipped /Link says its parent is not in the list")

        // The existing row action is still the way a reply opens its page.
        let crossPage = first.rows[4].annotation
        state.jump(toDocumentAnnotation: crossPage)
        require(state.selectedDocumentAnnotationID == "nm:reply-cross-page",
                "clicking a reply row selects that reply")
    }

    /// The sidebar's raster request must burn in the PDF's annotations; the canvas's plain
    /// request must not. The appearance-stream fixture carries a yellow highlight, which the
    /// page's black text and blue border cannot produce.
    @MainActor static func thumbnailAnnotationChecks(url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("INFO: skipping annotated thumbnail check (no fixture at \(url.path))")
            return
        }
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        state.open(url: url)
        try await eventually("the annotated thumbnail is rasterized", {
            state.thumbnails[0] != nil
        })
        guard let thumbnail = state.thumbnails[0] else {
            fatalError("FAIL: the thumbnail left the frame it was just seen in")
        }
        let width = thumbnail.pixelWidth
        var yellow = 0
        for offset in stride(from: 0, to: thumbnail.bgra.count, by: 4) {
            let blue = thumbnail.bgra[offset]
            let green = thumbnail.bgra[offset + 1]
            let red = thumbnail.bgra[offset + 2]
            if red > 180 && green > 180 && blue < 150 {
                yellow += 1
            }
        }
        require(width > 0 && yellow > 50,
                "the thumbnail carries the file's yellow highlight (\(yellow) px of \(width) wide)")

        // The canvas path is deliberately unchanged: a plain page raster has no yellow mark.
        let plain = try await state.engine.renderPage(0, scale: CGFloat(width) / 595.0)
        var plainYellow = 0
        for offset in stride(from: 0, to: plain.bgra.count, by: 4) {
            let blue = plain.bgra[offset]
            let green = plain.bgra[offset + 1]
            let red = plain.bgra[offset + 2]
            if red > 180 && green > 180 && blue < 150 {
                plainYellow += 1
            }
        }
        require(plainYellow < yellow / 4,
                "the canvas raster stays annotation-free (\(plainYellow) yellow px)")
    }
}
