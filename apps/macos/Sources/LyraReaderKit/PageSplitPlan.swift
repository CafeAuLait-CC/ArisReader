import Foundation

/// Why a split dialog's input cannot be turned into a page plan.
public enum PageSplitPlanError: Error, LocalizedError, Equatable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        }
    }
}

/// The shell half of splitting: parse the reader's ranges, chunk by a fixed count, and name the
/// output files. Kept free of PDF and AppKit so the rules are exercised by the headless checks.
///
/// Ranges are typed 1-based (what the page HUD shows) and become 0-based page lists for the
/// engine. The plan refuses overlapping ranges, reversed ranges and pages outside the document
/// **before** any output is written; the engine repeats the validation independently.
public enum PageSplitPlan {
    /// Parses `"1-5, 6-10"` (also accepts a single page, spaces, tabs and an en dash) into
    /// disjoint 0-based page lists, in the order typed.
    public static func ranges(_ text: String, pageCount: Int) throws -> [[Int]] {
        guard pageCount > 0 else {
            throw PageSplitPlanError.invalid("The document has no pages to split.")
        }
        let normalized = text
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
        let tokens = normalized
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else {
            throw PageSplitPlanError.invalid(
                "Type at least one page or range, for example 1-5, 6-10."
            )
        }

        var ranges: [[Int]] = []
        for token in tokens {
            let parts = token.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 1 || parts.count == 2 else {
                throw PageSplitPlanError.invalid(
                    "“\(token)” is not a page or range. Use 7 or 1-5."
                )
            }
            guard let start = Int(parts[0]), start >= 1, start <= pageCount else {
                throw PageSplitPlanError.invalid(
                    "“\(token)” starts outside the document (1–\(pageCount))."
                )
            }
            let end: Int
            if parts.count == 2 {
                guard let parsed = Int(parts[1]), parsed >= 1, parsed <= pageCount else {
                    throw PageSplitPlanError.invalid(
                        "“\(token)” ends outside the document (1–\(pageCount))."
                    )
                }
                end = parsed
            } else {
                end = start
            }
            guard start <= end else {
                throw PageSplitPlanError.invalid(
                    "“\(token)” runs backwards; write the smaller page first."
                )
            }
            let pages = Array((start - 1)...(end - 1))
            if let earlier = ranges.first(where: { !Set($0).isDisjoint(with: pages) }) {
                throw PageSplitPlanError.invalid(
                    "The range “\(token)” overlaps “\(label(earlier))”; each page can only be written once."
                )
            }
            ranges.append(pages)
        }

        ranges.sort { ($0.first ?? 0) < ($1.first ?? 0) }
        return ranges
    }

    /// `[0..<n]` split into chunks of `every` pages, the last chunk shorter.
    public static func chunks(pageCount: Int, every: Int) throws -> [[Int]] {
        guard pageCount > 0 else {
            throw PageSplitPlanError.invalid("The document has no pages to split.")
        }
        guard every >= 1 else {
            throw PageSplitPlanError.invalid("Split every N pages needs N of at least 1.")
        }
        return stride(from: 0, to: pageCount, by: every).map { start in
            Array(start..<min(start + every, pageCount))
        }
    }

    /// `1-5` / `7` for one 0-based page list, the form the dialogs and file names use.
    public static func label(_ pages: [Int]) -> String {
        guard let first = pages.first, let last = pages.last else { return "no pages" }
        if first == last { return "\(first + 1)" }
        return "\(first + 1)-\(last + 1)"
    }

    /// `<stem> (pages 1-5).pdf`, `<stem> (page 7).pdf`, beside the document or in the chosen
    /// folder. The reader sees these names in the confirmation and in Finder.
    public static func outputURLs(base: URL, ranges: [[Int]]) -> [URL] {
        let stem = base.deletingPathExtension().lastPathComponent
        let folder = base.deletingLastPathComponent()
        return ranges.map { pages in
            let noun = pages.count == 1 ? "page" : "pages"
            return folder.appendingPathComponent("\(stem) (\(noun) \(label(pages))).pdf")
        }
    }
}
