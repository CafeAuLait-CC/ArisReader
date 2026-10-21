import Foundation

/// One run inside a rendered paragraph.
public enum AIInlineRun: Equatable, Sendable {
    case text(String)
    /// A page citation LyraReader asked the model to produce (`[p.12]`) and that is inside the document.
    case citation(page: Int, raw: String)
}

/// What the answer renderer supports. Deliberately small and stated in the panel: paragraphs,
/// headings, bullet lists and numbered lists. Other Markdown is shown as literal text.
public enum AIAnswerBlock: Equatable, Sendable {
    case paragraph([AIInlineRun])
    case heading(level: Int, runs: [AIInlineRun])
    case bullet([AIInlineRun])
    case numbered(number: Int, runs: [AIInlineRun])
}

/// A small Markdown-ish parser for streamed answers.
///
/// Citation linkification is intentionally strict: only the exact form `[p.N]` is turned into a
/// link, and only when `1 <= N <= pageCount`. Bare numbers, `[12]`, `[p. 12]`, `[pp.1-2]` and
/// out-of-range pages stay plain text, because LyraReader only asked for `[p.N]` and must not invent
/// clickable references the model did not make.
public struct AIAnswerMarkdown: Equatable, Sendable {
    public let blocks: [AIAnswerBlock]

    public init(blocks: [AIAnswerBlock]) {
        self.blocks = blocks
    }

    public static func parse(
        _ text: String,
        pageCount: Int,
        verifiedPages: Set<Int>? = nil
    ) -> AIAnswerMarkdown {
        var blocks: [AIAnswerBlock] = []
        var paragraphLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let joined = paragraphLines.joined(separator: " ")
            paragraphLines.removeAll()
            let runs = inlineRuns(joined, pageCount: pageCount, verifiedPages: verifiedPages)
            if !runs.isEmpty {
                blocks.append(.paragraph(runs))
            }
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                continue
            }
            if let heading = headingLine(line) {
                flushParagraph()
                blocks.append(.heading(
                    level: heading.level,
                    runs: inlineRuns(heading.text, pageCount: pageCount, verifiedPages: verifiedPages)
                ))
                continue
            }
            if let bullet = bulletLine(line) {
                flushParagraph()
                blocks.append(.bullet(inlineRuns(
                    bullet, pageCount: pageCount, verifiedPages: verifiedPages
                )))
                continue
            }
            if let numbered = numberedLine(line) {
                flushParagraph()
                blocks.append(.numbered(
                    number: numbered.number,
                    runs: inlineRuns(
                        numbered.text, pageCount: pageCount, verifiedPages: verifiedPages
                    )
                ))
                continue
            }
            paragraphLines.append(line)
        }
        flushParagraph()
        return AIAnswerMarkdown(blocks: blocks)
    }

    /// Split one line into plain text and strict `[p.N]` citations.
    public static func inlineRuns(
        _ text: String,
        pageCount: Int,
        verifiedPages: Set<Int>? = nil
    ) -> [AIInlineRun] {
        guard !text.isEmpty else { return [] }
        var runs: [AIInlineRun] = []
        var plain = ""
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            if characters[index] == "[",
               index + 2 < characters.count,
               characters[index + 1] == "p",
               characters[index + 2] == "." {
                var cursor = index + 3
                var digits = ""
                while cursor < characters.count, characters[cursor].isNumber {
                    digits.append(characters[cursor])
                    cursor += 1
                }
                if !digits.isEmpty, cursor < characters.count, characters[cursor] == "]",
                   let page = Int(digits), page >= 1, page <= pageCount,
                   verifiedPages?.contains(page) ?? true {
                    if !plain.isEmpty {
                        runs.append(.text(plain))
                        plain = ""
                    }
                    runs.append(.citation(page: page, raw: String(characters[index...cursor])))
                    index = cursor + 1
                    continue
                }
            }
            plain.append(characters[index])
            index += 1
        }
        if !plain.isEmpty {
            runs.append(.text(plain))
        }
        return runs
    }

    /// Every strict `[p.N]` marker in the answer, whether or not the page is in this document
    /// or was sent. The chat panel compares this with the pages that went out to decide which
    /// citations are verified and which need a stated reason.
    public static func allCitedPages(in text: String) -> [Int] {
        var pages: [Int] = []
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            guard characters[index] == "[",
                  index + 2 < characters.count,
                  characters[index + 1] == "p",
                  characters[index + 2] == "." else {
                index += 1
                continue
            }
            var cursor = index + 3
            var digits = ""
            while cursor < characters.count, characters[cursor].isNumber {
                digits.append(characters[cursor])
                cursor += 1
            }
            if !digits.isEmpty, cursor < characters.count, characters[cursor] == "]",
               let page = Int(digits), !pages.contains(page) {
                pages.append(page)
            }
            index = max(index + 1, cursor)
        }
        return pages
    }

    /// Every page number the answer would link to, for checks and for the panel's footer.
    public var citedPages: [Int] {
        var pages: [Int] = []
        for block in blocks {
            let runs: [AIInlineRun]
            switch block {
            case .paragraph(let value), .bullet(let value):
                runs = value
            case .heading(_, let value), .numbered(_, let value):
                runs = value
            }
            for run in runs {
                if case .citation(let page, _) = run, !pages.contains(page) {
                    pages.append(page)
                }
            }
        }
        return pages
    }

    private static func headingLine(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for character in line {
            if character == "#" {
                level += 1
            } else {
                break
            }
        }
        guard level > 0, level <= 6 else { return nil }
        let remainder = line.dropFirst(level)
        guard remainder.isEmpty || remainder.first == " " else { return nil }
        let text = remainder.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (level, text)
    }

    private static func bulletLine(_ line: String) -> String? {
        for prefix in ["- ", "* ", "• "] where line.hasPrefix(prefix) {
            let text = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        return nil
    }

    private static func numberedLine(_ line: String) -> (number: Int, text: String)? {
        let characters = Array(line)
        var cursor = 0
        while cursor < characters.count, characters[cursor].isNumber, cursor < 4 {
            cursor += 1
        }
        guard cursor > 0, cursor + 1 < characters.count else { return nil }
        guard characters[cursor] == "." || characters[cursor] == ")" else { return nil }
        guard characters[cursor + 1] == " " else { return nil }
        let numberText = String(characters[0..<cursor])
        guard let number = Int(numberText) else { return nil }
        let text = String(characters[(cursor + 2)...]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (number, text)
    }
}
