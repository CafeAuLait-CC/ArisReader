import Foundation

/// One run inside a rendered Markdown block.
///
/// The parser never interprets HTML: `<b>` stays literal text, and the renderer puts it in an
/// attributed string, so a model cannot inject a view or a script.
public indirect enum ReaderMarkdownInline: Equatable, Sendable {
    case text(String)
    case bold([ReaderMarkdownInline])
    case italic([ReaderMarkdownInline])
    case strikethrough([ReaderMarkdownInline])
    case code(String)
    case link(text: [ReaderMarkdownInline], destination: String)
    /// A strict `[p.N]` citation for a page that was actually sent.
    case citation(page: Int, raw: String)
    /// LaTeX between `$…$` or `\(…\)`. The renderer tries the local math subset and falls back
    /// to the monospace source of this exact string.
    case math(String)
    /// Math the parser already knows it cannot render, with the reason in plain words.
    case mathFallback(source: String, reason: String)
}

public enum ReaderMarkdownAlignment: String, Equatable, Sendable {
    case leading, center, trailing
}

/// One block of a rendered answer.
public indirect enum ReaderMarkdownBlock: Equatable, Sendable {
    case heading(level: Int, inlines: [ReaderMarkdownInline])
    case paragraph([ReaderMarkdownInline])
    case bullet(depth: Int, inlines: [ReaderMarkdownInline])
    case numbered(depth: Int, number: Int, inlines: [ReaderMarkdownInline])
    case quote([ReaderMarkdownBlock])
    case code(language: String?, source: String)
    case table(headers: [[ReaderMarkdownInline]], alignments: [ReaderMarkdownAlignment],
               rows: [[[ReaderMarkdownInline]]])
    /// Display mathematics, from `$$…$$` or `\[…\]`.
    case mathBlock(source: String, reason: String?)
    case divider
}

public struct ReaderMarkdownDocument: Equatable, Sendable {
    public let blocks: [ReaderMarkdownBlock]

    public init(blocks: [ReaderMarkdownBlock]) {
        self.blocks = blocks
    }

    /// True when any block is mathematics. The renderer uses this to decide whether a text view
    /// needs CoreText attachments; answers without math can still use the same rich text view.
    public var containsMath: Bool {
        func inlineHasMath(_ inlines: [ReaderMarkdownInline]) -> Bool {
            inlines.contains { inline in
                switch inline {
                case .math, .mathFallback: return true
                case .bold(let runs), .italic(let runs), .strikethrough(let runs):
                    return inlineHasMath(runs)
                case .link(let runs, _): return inlineHasMath(runs)
                default: return false
                }
            }
        }
        func blockHasMath(_ block: ReaderMarkdownBlock) -> Bool {
            switch block {
            case .heading(_, let runs), .paragraph(let runs):
                return inlineHasMath(runs)
            case .bullet(_, let runs):
                return inlineHasMath(runs)
            case .numbered(_, _, let runs):
                return inlineHasMath(runs)
            case .quote(let blocks):
                return blocks.contains(where: blockHasMath)
            case .table(let headers, _, let rows):
                return headers.contains(where: inlineHasMath)
                    || rows.contains { $0.contains(where: inlineHasMath) }
            case .mathBlock: return true
            case .code, .divider: return false
            }
        }
        return blocks.contains(where: blockHasMath)
    }
}

/// A parser for the Markdown a paper answer actually uses: headings, paragraphs, nested lists,
/// block quotes, fenced code, tables, links, emphasis, inline/display mathematics and the strict
/// `[p.N]` citations the panel already relies on.
///
/// **Streaming.** The parser is total: every prefix is a document. An unclosed fence, display
/// math delimiter or table collects the rest of the text into that construct, so the answer never
/// flickers between literal `$$`/fence markers and rendered content. An unclosed emphasis or
/// inline math is still rendered (without its opening marker) and keeps its source for copying;
/// a lone `$` is left as text because it is far more likely to be currency than unfinished math.
/// HTML is never interpreted, only shown as text.
public enum ReaderMarkdown {
    public static func parse(
        _ text: String,
        pageCount: Int,
        verifiedPages: Set<Int>? = nil
    ) -> ReaderMarkdownDocument {
        var parser = ReaderMarkdownParser(
            text: text, pageCount: pageCount, verifiedPages: verifiedPages
        )
        return parser.parse()
    }
}

private struct ReaderMarkdownParser {
    let lines: [String]
    let pageCount: Int
    let verifiedPages: Set<Int>?
    var index = 0
    var listIndents: [Int] = []

    init(text: String, pageCount: Int, verifiedPages: Set<Int>?) {
        self.lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        self.pageCount = pageCount
        self.verifiedPages = verifiedPages
    }

    mutating func parse() -> ReaderMarkdownDocument {
        var blocks: [ReaderMarkdownBlock] = []
        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                index += 1
                listIndents.removeAll()
                continue
            }
            if let fence = fenceStart(line) {
                blocks.append(parseFence(marker: fence.marker, language: fence.language))
                continue
            }
            if let math = displayMathStart(line) {
                blocks.append(parseDisplayMath(opener: math.opener, rest: math.rest))
                continue
            }
            if let heading = headingLine(line) {
                blocks.append(.heading(level: heading.level,
                                        inlines: inline(heading.text)))
                index += 1
                listIndents.removeAll()
                continue
            }
            if isDivider(line) {
                blocks.append(.divider)
                index += 1
                listIndents.removeAll()
                continue
            }
            if looksLikeTable(line) {
                blocks.append(parseTable())
                listIndents.removeAll()
                continue
            }
            if line.hasPrefix(">") {
                blocks.append(parseQuote())
                listIndents.removeAll()
                continue
            }
            if let item = listItem(raw) {
                blocks.append(parseListItem(item))
                continue
            }
            blocks.append(parseParagraph())
            listIndents.removeAll()
        }
        return ReaderMarkdownDocument(blocks: blocks)
    }

    // MARK: - Blocks

    private func fenceStart(_ line: String) -> (marker: String, language: String?)? {
        for marker in ["```", "~~~"] where line.hasPrefix(marker) {
            let language = line.dropFirst(marker.count)
                .trimmingCharacters(in: .whitespaces)
            return (marker, language.isEmpty ? nil : language)
        }
        return nil
    }

    private mutating func parseFence(marker: String, language: String?) -> ReaderMarkdownBlock {
        index += 1
        var source: [String] = []
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(marker) {
                index += 1
                break
            }
            source.append(lines[index])
            index += 1
        }
        return .code(language: language, source: source.joined(separator: "\n"))
    }

    private func displayMathStart(_ line: String) -> (opener: String, rest: String)? {
        if line.hasPrefix("$$") {
            return ("$$", String(line.dropFirst(2)))
        }
        if line.hasPrefix("\\[") {
            return ("\\[", String(line.dropFirst(2)))
        }
        return nil
    }

    private mutating func parseDisplayMath(opener: String, rest: String) -> ReaderMarkdownBlock {
        let closer = opener == "$$" ? "$$" : "\\]"
        index += 1
        var body: [String] = []
        var first = rest
        if let range = first.range(of: closer) {
            let source = String(first[..<range.lowerBound])
            return .mathBlock(source: source.trimmingCharacters(in: .whitespacesAndNewlines),
                              reason: nil)
        }
        if !rest.isEmpty { body.append(rest) }
        while index < lines.count {
            let line = lines[index]
            index += 1
            if let range = line.range(of: closer) {
                let before = String(line[..<range.lowerBound])
                if !before.isEmpty { body.append(before) }
                break
            }
            body.append(line)
        }
        let source = body.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .mathBlock(source: source, reason: source.isEmpty ? "The expression is empty." : nil)
    }

    private mutating func parseQuote() -> ReaderMarkdownBlock {
        var inner: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            var text = String(trimmed.dropFirst())
            if text.hasPrefix(" ") { text.removeFirst() }
            inner.append(text)
            index += 1
        }
        let nested = ReaderMarkdown.parse(
            inner.joined(separator: "\n"),
            pageCount: pageCount,
            verifiedPages: verifiedPages
        )
        return .quote(nested.blocks)
    }

    private struct ListMarker {
        let ordered: Bool
        let number: Int
        let depth: Int
        let text: String
        let indent: Int
    }

    private func listMarkerInfo(
        _ raw: String
    ) -> (ordered: Bool, number: Int, text: String, indent: Int)? {
        let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return nil }
        let chars = Array(trimmed)
        var markerLength = 0
        var ordered = false
        var number = 1
        if chars[0] == "-" || chars[0] == "*" || chars[0] == "+" {
            markerLength = 1
        } else {
            var digits = 0
            while digits < chars.count, chars[digits].isNumber { digits += 1 }
            guard digits > 0, digits + 1 < chars.count,
                  chars[digits] == "." || chars[digits] == ")" else { return nil }
            ordered = true
            number = Int(String(chars[0..<digits])) ?? 1
            markerLength = digits + 1
        }
        guard markerLength < chars.count, chars[markerLength] == " " else { return nil }
        let textStart = markerLength + 1
        guard textStart <= chars.count else { return nil }
        return (ordered, number, String(chars[textStart...]), indent)
    }

    private mutating func listItem(_ raw: String) -> ListMarker? {
        guard let info = listMarkerInfo(raw) else { return nil }
        while listIndents.last ?? -1 > info.indent { listIndents.removeLast() }
        if listIndents.isEmpty || info.indent > (listIndents.last ?? 0) {
            listIndents.append(info.indent)
        }
        let depth = max(0, listIndents.count - 1)
        return ListMarker(ordered: info.ordered, number: info.number,
                          depth: min(depth, 5), text: info.text, indent: info.indent)
    }

    private mutating func parseListItem(_ item: ListMarker) -> ReaderMarkdownBlock {
        index += 1
        var text = item.text
        while index < lines.count {
            let raw = lines[index]
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { break }
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```")
                || raw.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") {
                break
            }
            if listMarkerInfo(raw) != nil { break }
            guard indent > item.indent else { break }
            text += " " + raw.trimmingCharacters(in: .whitespaces)
            index += 1
        }
        let runs = inline(text)
        if item.ordered {
            return .numbered(depth: item.depth, number: item.number, inlines: runs)
        }
        return .bullet(depth: item.depth, inlines: runs)
    }

    private mutating func parseParagraph() -> ReaderMarkdownBlock {
        var collected: [(text: String, hardBreak: Bool)] = []
        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { break }
            if !collected.isEmpty, startsBlock(raw) { break }
            collected.append((line, raw.hasSuffix("  ")))
            index += 1
        }
        if collected.isEmpty { index += 1 }
        var joined = ""
        for (offset, item) in collected.enumerated() {
            if offset == 0 {
                joined = item.text
            } else if collected[offset - 1].hardBreak {
                joined += "\n" + item.text
            } else {
                joined += " " + item.text
            }
        }
        return .paragraph(inline(joined))
    }

    private func startsBlock(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return true }
        if line.hasPrefix("```") || line.hasPrefix("~~~") { return true }
        if line.hasPrefix("$$") || line.hasPrefix("\\[") { return true }
        if headingLine(line) != nil { return true }
        if isDivider(line) { return true }
        if line.hasPrefix(">") { return true }
        if listMarkerInfo(raw) != nil { return true }
        if looksLikeTable(line) { return true }
        return false
    }

    private func isDivider(_ line: String) -> Bool {
        let stripped = line.filter { !$0.isWhitespace }
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" }
            || stripped.allSatisfy { $0 == "_" }
    }

    private func headingLine(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for char in line {
            if char == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6, line.count > level else { return nil }
        let rest = line.dropFirst(level)
        guard rest.hasPrefix(" ") else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    private func looksLikeTable(_ line: String) -> Bool {
        guard !line.isEmpty, !line.hasPrefix("```") else { return false }
        return line.contains("|")
    }

    private mutating func parseTable() -> ReaderMarkdownBlock {
        var rawRows: [String] = []
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty || !looksLikeTable(line) { break }
            rawRows.append(line)
            index += 1
        }
        guard !rawRows.isEmpty else { return .paragraph([]) }
        var headerCells: [String] = []
        var alignments: [ReaderMarkdownAlignment] = []
        var body: [[[ReaderMarkdownInline]]] = []
        var headerFound = false
        for (rowIndex, row) in rawRows.enumerated() {
            let cells = splitTableRow(row)
            if !headerFound, rowIndex + 1 < rawRows.count, isTableSeparator(cells) {
                // The first row is the header, the next is the alignment row.
                headerCells = cells
                alignments = cells.map(alignment(from:))
                headerFound = true
                continue
            }
            if isTableSeparator(cells) {
                if !headerFound {
                    headerCells = cells
                    alignments = cells.map(alignment(from:))
                    headerFound = true
                }
                continue
            }
            if !headerFound {
                headerCells = cells
                headerFound = true
                continue
            }
            body.append(cells.map { inline($0) })
        }
        if alignments.count < headerCells.count {
            alignments += Array(repeating: .leading, count: headerCells.count - alignments.count)
        }
        let headers = headerCells.map { inline($0) }
        let columns = max(headers.count, body.map(\.count).max() ?? 0)
        let paddedHeaders = headers + Array(repeating: [.text("")], count: max(0, columns - headers.count))
        let paddedRows = body.map { row in
            row + Array(repeating: [ReaderMarkdownInline](), count: max(0, columns - row.count))
        }
        return .table(headers: paddedHeaders, alignments: alignments, rows: paddedRows)
    }

    private func isTableSeparator(_ cells: [String]) -> Bool {
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            let body = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return body.count >= 1 && body.allSatisfy { $0 == "-" }
        }
    }

    private func alignment(from cell: String) -> ReaderMarkdownAlignment {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        let left = trimmed.hasPrefix(":")
        let right = trimmed.hasSuffix(":")
        if left && right { return .center }
        if right { return .trailing }
        return .leading
    }

    private func splitTableRow(_ row: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var index = row.startIndex
        var inCode = false
        while index < row.endIndex {
            let char = row[index]
            if char == "\\", row.index(after: index) < row.endIndex {
                let next = row[row.index(after: index)]
                if next == "|" {
                    current.append("|")
                    index = row.index(index, offsetBy: 2)
                    continue
                }
            }
            if char == "`" { inCode.toggle() }
            if char == "|" && !inCode {
                cells.append(current)
                current = ""
            } else {
                current.append(char)
            }
            index = row.index(after: index)
        }
        cells.append(current)
        if row.hasPrefix("|"), cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            cells.removeFirst()
        }
        if row.hasSuffix("|"), cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            cells.removeLast()
        }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Inline

    func inline(_ text: String) -> [ReaderMarkdownInline] {
        var result: [ReaderMarkdownInline] = []
        let chars = Array(text)
        var i = 0
        var buffer = ""

        func flush() {
            if !buffer.isEmpty {
                result.append(.text(buffer))
                buffer = ""
            }
        }

        while i < chars.count {
            let char = chars[i]
            if char == "\\", i + 1 < chars.count, chars[i + 1] == "(" {
                if let end = findClosingPair("\\(", "\\)", from: i + 2, chars: chars) {
                    flush()
                    result.append(.math(String(chars[(i + 2)..<end])))
                    i = end + 2
                    continue
                }
            }
            if char == "\\", i + 1 < chars.count {
                buffer.append(chars[i + 1])
                i += 2
                continue
            }
            if char == "`" {
                if let end = findClosing("`", from: i + 1, chars: chars) {
                    flush()
                    result.append(.code(String(chars[(i + 1)..<end])))
                    i = end + 1
                } else {
                    flush()
                    result.append(.code(String(chars[(i + 1)...])))
                    i = chars.count
                }
                continue
            }
            if char == "$" {
                if i + 1 < chars.count, chars[i + 1] == "$" {
                    buffer.append("$")
                    i += 1
                    continue
                }
                if let end = findClosing("$", from: i + 1, chars: chars), end > i + 1 {
                    flush()
                    let source = String(chars[(i + 1)..<end])
                    result.append(.math(source))
                    i = end + 1
                    continue
                }
                buffer.append("$")
                i += 1
                continue
            }
            if char == "*" || char == "_" {
                let double = i + 1 < chars.count && chars[i + 1] == char
                let marker = double ? String([char, char]) : String(char)
                if let end = findClosing(marker, from: i + marker.count, chars: chars),
                   end > i + marker.count {
                    flush()
                    let inner = inline(String(chars[(i + marker.count)..<end]))
                    result.append(double ? .bold(inner) : .italic(inner))
                    i = end + marker.count
                    continue
                }
                if double {
                    flush()
                    let innerText = String(chars[(i + 2)...])
                    result.append(.bold(inline(innerText)))
                    i = chars.count
                    continue
                }
            }
            if char == "~", i + 1 < chars.count, chars[i + 1] == "~" {
                if let end = findClosing("~~", from: i + 2, chars: chars), end > i + 2 {
                    flush()
                    result.append(.strikethrough(inline(String(chars[(i + 2)..<end]))))
                    i = end + 2
                    continue
                }
            }
            if char == "[" {
                if let citation = citationAt(i, chars: chars) {
                    flush()
                    result.append(citation.inline)
                    i = citation.end
                    continue
                }
                if let link = linkAt(i, chars: chars) {
                    flush()
                    result.append(link.inline)
                    i = link.end
                    continue
                }
            }
            if char == "<" {
                if let link = autolinkAt(i, chars: chars) {
                    flush()
                    result.append(link.inline)
                    i = link.end
                    continue
                }
            }
            buffer.append(char)
            i += 1
        }
        flush()
        return result
    }

    private func findClosing(_ marker: String, from start: Int, chars: [Character]) -> Int? {
        let markerChars = Array(marker)
        guard !markerChars.isEmpty, start <= chars.count else { return nil }
        let markerStartsWithBackslash = markerChars.first == "\\"
        var i = start
        while i + markerChars.count <= chars.count {
            // A backslash escapes the next character for ordinary markers (`\*`, ``\` ``), but
            // a marker that itself starts with a backslash (`\)`) must still be findable.
            if !markerStartsWithBackslash, chars[i] == "\\" { i += 2; continue }
            if Array(chars[i..<(i + markerChars.count)]) == markerChars {
                return i
            }
            i += 1
        }
        return nil
    }

    private func findClosingPair(
        _ opener: String, _ closer: String, from start: Int, chars: [Character]
    ) -> Int? {
        findClosing(closer, from: start, chars: chars)
    }

    private func citationAt(
        _ start: Int, chars: [Character]
    ) -> (inline: ReaderMarkdownInline, end: Int)? {
        guard start + 2 < chars.count, chars[start] == "[", chars[start + 1] == "p",
              chars[start + 2] == "." else { return nil }
        var i = start + 3
        var digits = ""
        while i < chars.count, chars[i].isNumber {
            digits.append(chars[i])
            i += 1
        }
        guard !digits.isEmpty, i < chars.count, chars[i] == "]", let page = Int(digits),
              page >= 1, page <= pageCount else { return nil }
        if let verifiedPages, !verifiedPages.contains(page) { return nil }
        let raw = String(chars[start...i])
        return (.citation(page: page, raw: raw), i + 1)
    }

    private func linkAt(
        _ start: Int, chars: [Character]
    ) -> (inline: ReaderMarkdownInline, end: Int)? {
        var i = start + 1
        var depth = 1
        var label = ""
        while i < chars.count {
            let char = chars[i]
            if char == "\\", i + 1 < chars.count {
                label.append(chars[i + 1])
                i += 2
                continue
            }
            if char == "[" { depth += 1 }
            if char == "]" {
                depth -= 1
                if depth == 0 { break }
            }
            label.append(char)
            i += 1
        }
        guard i + 1 < chars.count, chars[i] == "]", chars[i + 1] == "(" else { return nil }
        i += 2
        var destination = ""
        var parentheses = 1
        while i < chars.count {
            let char = chars[i]
            if char == "(" { parentheses += 1 }
            if char == ")" {
                parentheses -= 1
                if parentheses == 0 { break }
            }
            destination.append(char)
            i += 1
        }
        guard i < chars.count, chars[i] == ")", let url = safeURL(destination) else { return nil }
        let runs = inline(label)
        return (.link(text: runs, destination: url), i + 1)
    }

    private func autolinkAt(
        _ start: Int, chars: [Character]
    ) -> (inline: ReaderMarkdownInline, end: Int)? {
        guard let end = chars[start...].firstIndex(of: ">") else { return nil }
        let urlText = String(chars[(start + 1)..<end])
        guard let url = safeURL(urlText), !url.isEmpty else { return nil }
        return (.link(text: [.text(urlText)], destination: url), end + 1)
    }

    private func safeURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return nil
        }
        guard ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url.absoluteString
    }
}
