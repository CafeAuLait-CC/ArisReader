import Foundation

/// A numbered sidebar row for one outline entry.
///
/// The hierarchy is carried by `OutlineEntry.depth`, flattening included. Numbering is
/// deliberately computed here rather than in the reader: it is a presentation decision, and the
/// fixture's three-level tree is the only input it gets.
public enum OutlineNumbering {
    public struct Row: Identifiable {
        /// Position in the flattened outline, which is stable for one document.
        public let id: Int
        public let entry: OutlineEntry
        /// `1`, `1.1`, `1.1.1`, … according to depth.
        public let number: String

        public var depth: Int { Int(entry.depth) }
        /// Indentation in points. One step per level, including for an entry with no page.
        public var indentPt: CGFloat { CGFloat(depth) * 14 }
    }

    /// Numbers a depth-first, flat outline: `1`, `1.1`, `1.1.1`, then `2`, `2.1`, …
    ///
    /// A new entry at depth `d` increments the counter for that level and resets every deeper
    /// counter, so a section without a page still consumes its number and its children still
    /// number under it. A malformed jump from depth 0 to 2 fills the gap with zeroes rather than
    /// guessing a parent that was never in the list.
    public static func rows(for entries: [OutlineEntry]) -> [Row] {
        var counters: [Int] = []
        return entries.enumerated().map { index, entry in
            let depth = max(0, Int(entry.depth))
            while counters.count <= depth {
                counters.append(0)
            }
            counters[depth] += 1
            if counters.count > depth + 1 {
                counters.removeSubrange((depth + 1)...)
            }
            let number = counters.map(String.init).joined(separator: ".")
            return Row(id: index, entry: entry, number: number)
        }
    }
}

/// Why a reply found in the file cannot be nested under a shown parent.
public enum AnnotationOrphanReason: Equatable {
    /// The parent exists but the reader does not show it (its `/F` hides it).
    case parentHidden(page: Int)
    /// The parent identity is not among the reader's content annotations (for example `/Link`).
    case parentMissing
    /// `/IRT` is present but PDFium could not follow it.
    case parentUnreadable
    /// Following `/IRT` leads back to an annotation already in the chain.
    case cycle

    /// The line the sidebar shows under an orphaned reply. Short, and specific enough to act on.
    public var message: String {
        switch self {
        case .parentHidden(let page):
            return "Parent is hidden on page \(page + 1); shown here instead."
        case .parentMissing:
            return "Parent is not in the reader's annotation list (skipped or not content)."
        case .parentUnreadable:
            return "The /IRT reply link could not be read."
        case .cycle:
            return "Reply chain loops back on itself; nesting stops here."
        }
    }
}

/// One annotation row in the panel, including replies indented under their parent.
public struct AnnotationPanelRow: Identifiable {
    public let id: String
    public let annotation: DocumentAnnotation
    /// 0 for a root annotation, 1 for its reply, 2 for a reply to that reply.
    public let depth: Int
    /// Page of the thread's root. A cross-page reply keeps its own page in `annotation.page`.
    public let sectionPage: Int
    public let orphanReason: AnnotationOrphanReason?

    public var showsPage: Bool { annotation.page != sectionPage }

    /// Display identity repeated by a reply: author, date and text, each when the file has one.
    public var replyAuthor: String? {
        guard annotation.isReply else { return nil }
        let author = annotation.author?.trimmingCharacters(in: .whitespacesAndNewlines)
        return author?.isEmpty == false ? author : "Reply"
    }

    public var replyDate: String? {
        guard annotation.isReply else { return nil }
        return annotation.displayDate
    }
}

/// One disclosure group: the roots on a page and every reply nested under them.
public struct AnnotationPanelSection: Identifiable {
    public let page: Int
    public let rows: [AnnotationPanelRow]

    public var id: Int { page }
    public var annotationCount: Int { rows.count }
    public var title: String {
        annotationCount == 1 ? "Page \(page + 1) · 1 annotation"
            : "Page \(page + 1) · \(annotationCount) annotations"
    }
}

/// The annotation panel's content and the reply accounting the checks and the CLI share.
///
/// **Which annotations are roots.** A root is an annotation the reader shows on the page
/// (`visible`) or one that is itself a reply. Hidden parents are not roots, matching the panel's
/// existing rule; a hidden reply *is* listed, because `/F` says what to paint, not whether a
/// review conversation may be read. That is why `review_tang_0923.pdf`'s 21 hidden replies are
/// visible in the panel and why a hidden parent becomes an orphan rather than a silent drop.
/// A reply with no `/Contents` is listed too, as "No text": dropping it would silently break the
/// link between its parent and any reply that answers it.
///
/// **Cross-page replies.** A reply stays in its parent's page group even when its own page is
/// different: a conversation split across a page boundary should not be read in two places. The
/// row says which page it is on.
public struct AnnotationPanelModel {
    public let sections: [AnnotationPanelSection]
    public let replyCount: Int
    /// Replies attached to a shown chain (any depth).
    public let nestedReplyCount: Int
    public let orphanedReplyCount: Int

    public static func build(from annotations: [DocumentAnnotation]) -> Self {
        var byID: [String: DocumentAnnotation] = [:]
        var order: [String] = []
        for annotation in annotations where byID[annotation.id] == nil {
            byID[annotation.id] = annotation
            order.append(annotation.id)
        }

        let included = Set(order.filter {
            guard let annotation = byID[$0] else { return false }
            return annotation.visible || annotation.isReply
        })

        var parentFor: [String: String] = [:]
        var orphanFor: [String: AnnotationOrphanReason] = [:]
        for id in order where included.contains(id) {
            guard let annotation = byID[id], annotation.isReply else { continue }

            var current = annotation
            var seen: Set<String> = [annotation.id]
            var immediateParent: String?
            var failure: AnnotationOrphanReason?

            while true {
                guard let parentID = current.parentID else {
                    failure = .parentUnreadable
                    break
                }
                if seen.contains(parentID) {
                    failure = .cycle
                    break
                }
                guard let parent = byID[parentID] else {
                    failure = .parentMissing
                    break
                }
                if immediateParent == nil {
                    immediateParent = parentID
                }
                if !included.contains(parentID) {
                    failure = .parentHidden(page: parent.page)
                    break
                }
                if !parent.isReply {
                    break
                }
                seen.insert(parentID)
                current = parent
            }

            if let failure {
                orphanFor[id] = failure
            } else if let immediateParent {
                parentFor[id] = immediateParent
            } else {
                orphanFor[id] = .parentUnreadable
            }
        }

        var children: [String: [String]] = [:]
        for id in order {
            if let parent = parentFor[id] {
                children[parent, default: []].append(id)
            }
        }

        var rowsByPage: [Int: [AnnotationPanelRow]] = [:]
        var rendered: Set<String> = []

        func append(_ id: String, depth: Int, sectionPage: Int, to rows: inout [AnnotationPanelRow]) {
            guard !rendered.contains(id), let annotation = byID[id] else { return }
            rendered.insert(id)
            rows.append(
                AnnotationPanelRow(
                    id: id,
                    annotation: annotation,
                    depth: depth,
                    sectionPage: sectionPage,
                    orphanReason: depth == 0 ? orphanFor[id] : nil
                )
            )
            for child in children[id] ?? [] {
                append(child, depth: depth + 1, sectionPage: sectionPage, to: &rows)
            }
        }

        for id in order where included.contains(id) {
            guard let annotation = byID[id] else { continue }
            guard !annotation.isReply || orphanFor[id] != nil else { continue }
            var rows: [AnnotationPanelRow] = []
            append(id, depth: 0, sectionPage: annotation.page, to: &rows)
            rowsByPage[annotation.page, default: []].append(contentsOf: rows)
        }

        let sections = rowsByPage.keys.sorted().map {
            AnnotationPanelSection(page: $0, rows: rowsByPage[$0] ?? [])
        }

        return Self(
            sections: sections,
            replyCount: order.reduce(0) { $0 + ((byID[$1]?.isReply ?? false) ? 1 : 0) },
            nestedReplyCount: parentFor.count,
            orphanedReplyCount: orphanFor.count
        )
    }
}

public extension DocumentAnnotation {
    /// `/M` as a readable date, or the file's own string when it is not the PDF `D:…` shape.
    var displayDate: String? {
        guard let modified, !modified.isEmpty else { return nil }
        var digits = modified
        if digits.hasPrefix("D:") {
            digits.removeFirst(2)
        }
        guard digits.count >= 14 else { return modified }
        let stamp = String(digits.prefix(14))
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyyMMddHHmmss"
        guard let date = parser.date(from: stamp) else { return modified }
        let display = DateFormatter()
        display.locale = Locale(identifier: "en_US_POSIX")
        display.timeZone = TimeZone(secondsFromGMT: 0)
        display.dateFormat = "yyyy-MM-dd HH:mm"
        return display.string(from: date)
    }
}

/// One page's bookmarks, in the reader's own order.
public struct BookmarkGroup: Identifiable {
    public let page: Int
    public let bookmarks: [Bookmark]

    public var id: Int { page }

    public var title: String {
        bookmarks.count == 1 ? "Page \(page + 1) · 1 bookmark"
            : "Page \(page + 1) · \(bookmarks.count) bookmarks"
    }
}

/// The sidebar's bookmark grouping, kept apart from the view so it can be checked directly.
///
/// A bookmark list is the reader's outline, not a sorted index: the order is whatever they set
/// with the move commands. Grouping therefore preserves first appearance — a page's section
/// sits where its first bookmark is — and within a section the array order is kept.
public enum BookmarkGrouping {
    public static func groups(for bookmarks: [Bookmark]) -> [BookmarkGroup] {
        var pageOrder: [Int] = []
        var byPage: [Int: [Bookmark]] = [:]
        for bookmark in bookmarks {
            if byPage[bookmark.page] == nil { pageOrder.append(bookmark.page) }
            byPage[bookmark.page, default: []].append(bookmark)
        }
        return pageOrder.map { BookmarkGroup(page: $0, bookmarks: byPage[$0] ?? []) }
    }
}
