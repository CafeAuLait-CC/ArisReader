import AppKit
import CoreGraphics
import CoreText
import Foundation

/// A rendered mathematics expression: an image plus the metrics needed to align it on a text
/// baseline. `source` is the exact LaTeX between the delimiters, which is what a fallback and
/// the copy command use.
public struct ReaderMathImage {
    public let image: NSImage
    public let size: CGSize
    public let ascent: CGFloat
    public let descent: CGFloat
    public let source: String
}

public enum ReaderMathError: Error, Equatable, LocalizedError {
    case empty
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "The expression is empty."
        case .unsupported(let detail): return detail
        }
    }
}

/// A small, dependency-free LaTeX subset renderer.
///
/// **Covered:** letters, digits, Greek letters, common binary operators and relations, explicit
/// spacing, superscripts and subscripts, `\frac`, `\sqrt` (including an index), `\sum`, `\prod`,
/// `\int` and `\oint` with limits, `\left … \right` delimiters, `\text`, `\mathrm`, `\mathbf`,
/// `\mathbb` (as a plain math font fallback), `\hat`, `\bar`, `\vec`, `\dot`, and the
/// `matrix`/`pmatrix`/`bmatrix`/`vmatrix`/`cases`/`aligned` environments.
///
/// **Not covered:** colour, macros, alignment other than simple matrices, commutative diagrams,
/// chemistry, or any command not named above. An unsupported expression is **not** rendered
/// partially: the caller receives nil and shows the monospace source of the whole expression,
/// which is also what the copy command keeps.
public enum ReaderMathRenderer {
    /// A small cache keyed by source, size, display mode and appearance. Streaming answers rebuild
    /// the same expressions on every token; re-laying them out each time would show as a stutter.
    nonisolated(unsafe) private static let cache = NSCache<NSString, CachedMath>()
    private final class CachedMath {
        let image: NSImage
        let size: CGSize
        let ascent: CGFloat
        let descent: CGFloat
        init(_ rendered: ReaderMathImage) {
            self.image = rendered.image
            self.size = rendered.size
            self.ascent = rendered.ascent
            self.descent = rendered.descent
        }
    }

    public static func render(
        _ source: String,
        fontSize: CGFloat = 13,
        display: Bool = false
    ) -> Result<ReaderMathImage, ReaderMathError> {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua)
        let dark = appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = "\(trimmed)|\(fontSize)|\(display)|\(dark)" as NSString
        if let cached = cache.object(forKey: key) {
            return .success(ReaderMathImage(
                image: cached.image, size: cached.size, ascent: cached.ascent,
                descent: cached.descent, source: trimmed
            ))
        }
        do {
            var parser = MathParser(source: trimmed, display: display)
            let nodes = try parser.parse()
            let box = MathLayout.layoutRow(nodes, size: fontSize, display: display, baseSize: fontSize)
            let padding = max(1, fontSize * 0.14)
            let width = max(1, box.width + padding * 2)
            let height = max(1, box.ascent + box.descent + padding * 2)
            let image = NSImage(size: NSSize(width: width, height: height))
            image.lockFocus()
            defer { image.unlockFocus() }
            if let context = NSGraphicsContext.current?.cgContext {
                context.setShouldAntialias(true)
                context.textMatrix = .identity
                box.draw(context, padding, padding + box.descent)
            }
            let rendered = ReaderMathImage(
                image: image,
                size: CGSize(width: width, height: height),
                ascent: box.ascent + padding,
                descent: box.descent + padding,
                source: trimmed
            )
            cache.setObject(CachedMath(rendered), forKey: key)
            return .success(rendered)
        } catch let error as ReaderMathError {
            return .failure(error)
        } catch {
            return .failure(.unsupported(error.localizedDescription))
        }
    }

    public static func unsupportedReason(for source: String) -> String? {
        if case .failure(let error) = render(source) { return error.localizedDescription }
        return nil
    }
}

// MARK: - Box model

/// A laid-out math fragment. `draw` receives the current point as the fragment's baseline.
private struct MathBox {
    var width: CGFloat
    var ascent: CGFloat
    var descent: CGFloat
    var draw: (CGContext, CGFloat, CGFloat) -> Void

    var height: CGFloat { ascent + descent }

    func shifted(dx: CGFloat, dy: CGFloat) -> MathBox {
        MathBox(width: width, ascent: ascent + dy, descent: descent - dy) { context, x, y in
            draw(context, x + dx, y + dy)
        }
    }

    static func empty() -> MathBox {
        MathBox(width: 0, ascent: 0, descent: 0) { _, _, _ in }
    }
}

private indirect enum MathNode {
    case text(String, size: CGFloat, italic: Bool, bold: Bool)
    case space(CGFloat)
    case row([MathNode])
    case fraction(MathNode, MathNode)
    case squareRoot(index: MathNode?, body: MathNode)
    case script(base: MathNode, superscript: MathNode?, subscriptNode: MathNode?, limits: Bool)
    case bigOperator(String, lower: MathNode?, upper: MathNode?, display: Bool)
    case delimited(left: String, body: MathNode, right: String)
    case matrix(rows: [[MathNode]], left: String, right: String)
    case accent(MathNode, symbol: String)
}

// MARK: - Parser

private enum MathToken: Equatable {
    case command(String)
    case character(Character)
    case open
    case close
    case superscript
    case subscriptMark
    case ampersand
    case rowBreak
    case space
}

private struct MathParser {
    let source: String
    let display: Bool
    private var tokens: [MathToken] = []
    private var index = 0

    init(source: String, display: Bool) {
        self.source = source
        self.display = display
        self.tokens = Self.tokenize(source)
    }

    static func tokenize(_ source: String) -> [MathToken] {
        var tokens: [MathToken] = []
        let chars = Array(source)
        var i = 0
        while i < chars.count {
            let char = chars[i]
            if char == "\\" {
                guard i + 1 < chars.count else {
                    tokens.append(.character("\\"))
                    i += 1
                    continue
                }
                let next = chars[i + 1]
                if next.isLetter {
                    var name = ""
                    var j = i + 1
                    while j < chars.count, chars[j].isLetter {
                        name.append(chars[j])
                        j += 1
                    }
                    tokens.append(.command(name))
                    i = j
                    continue
                }
                switch next {
                case "{", "}":
                    tokens.append(.character(next))
                case ",":
                    tokens.append(.space)
                case ";":
                    tokens.append(.space)
                    tokens.append(.space)
                case "!":
                    tokens.append(.space)
                case "\\":
                    tokens.append(.rowBreak)
                default:
                    tokens.append(.character(next))
                }
                i += 2
                continue
            }
            switch char {
            case "{": tokens.append(.open)
            case "}": tokens.append(.close)
            case "^": tokens.append(.superscript)
            case "_": tokens.append(.subscriptMark)
            case "&": tokens.append(.ampersand)
            case " ", "\n", "\t": break
            default: tokens.append(.character(char))
            }
            i += 1
        }
        return tokens
    }

    private var current: MathToken? { index < tokens.count ? tokens[index] : nil }

    mutating func parse() throws -> [MathNode] {
        let body = try parseSequence(stop: nil)
        guard index == tokens.count else {
            throw ReaderMathError.unsupported("Unexpected trailing math tokens.")
        }
        guard !body.isEmpty else { throw ReaderMathError.empty }
        return body
    }

    /// Stops before `stop` (a closing brace or a `\right`/`\end` command), consumed by the caller.
    private mutating func parseSequence(stop: StopCondition?) throws -> [MathNode] {
        var nodes: [MathNode] = []
        while let token = current {
            if let stop, stop.matches(token, index: index, tokens: tokens) { break }
            if token == .space {
                index += 1
                nodes.append(.space(0.16))
                continue
            }
            switch token {
            case .close:
                if stop == nil { throw ReaderMathError.unsupported("Unmatched closing brace.") }
                return nodes
            case .ampersand, .rowBreak:
                if stop == nil {
                    throw ReaderMathError.unsupported("A matrix separator appeared outside an environment.")
                }
                return nodes
            case .command("right"), .command("end"):
                if stop == nil { throw ReaderMathError.unsupported("Unexpected \\right or \\end.") }
                return nodes
            default:
                break
            }
            var atom = try parseAtom()
            // Attach scripts to the atom (or to the big operator's limits).
            var superscript: MathNode?
            var subscriptNode: MathNode?
            var attached = false
            while true {
                if current == .superscript {
                    index += 1
                    superscript = try parseScriptGroup()
                    attached = true
                } else if current == .subscriptMark {
                    index += 1
                    subscriptNode = try parseScriptGroup()
                    attached = true
                } else {
                    break
                }
            }
            if attached {
                if case .bigOperator(let symbol, let lower, let upper, _) = atom {
                    atom = .bigOperator(symbol, lower: lower ?? subscriptNode,
                                        upper: upper ?? superscript, display: display)
                } else {
                    atom = .script(base: atom, superscript: superscript,
                                   subscriptNode: subscriptNode, limits: false)
                }
            }
            nodes.append(atom)
        }
        if stop?.isRequired == true, current == nil {
            throw ReaderMathError.unsupported("A group was not closed.")
        }
        return nodes
    }

    enum StopCondition: Equatable {
        case closingBrace
        case rightDelimiter
        case environmentEnd(String)
        case environmentCellOrRow

        var isRequired: Bool {
            switch self {
            case .closingBrace, .rightDelimiter, .environmentEnd: return true
            case .environmentCellOrRow: return false
            }
        }

        func matches(_ token: MathToken, index: Int, tokens: [MathToken]) -> Bool {
            switch self {
            case .closingBrace:
                return token == .close
            case .rightDelimiter:
                return token == .command("right")
            case .environmentEnd:
                return token == .command("end")
            case .environmentCellOrRow:
                return token == .ampersand || token == .rowBreak
            }
        }
    }

    private mutating func parseAtom() throws -> MathNode {
        guard let token = current else { throw ReaderMathError.unsupported("Unexpected end of expression.") }
        index += 1
        switch token {
        case .open:
            let inner = try parseSequence(stop: .closingBrace)
            guard current == .close else { throw ReaderMathError.unsupported("A group was not closed.") }
            index += 1
            return .row(inner)
        case .character(let char):
            if char == "-" || char == "+" {
                return .text(String(char), size: 0, italic: false, bold: false)
            }
            return .text(String(char), size: 0, italic: false, bold: false)
        case .command(let name):
            return try parseCommand(name)
        case .superscript, .subscriptMark:
            throw ReaderMathError.unsupported("A superscript or subscript has no base.")
        case .close, .ampersand, .rowBreak, .space:
            throw ReaderMathError.unsupported("Unexpected math token.")
        }
    }

    private mutating func parseScriptGroup() throws -> MathNode {
        if current == .open {
            index += 1
            let inner = try parseSequence(stop: .closingBrace)
            guard current == .close else { throw ReaderMathError.unsupported("A script group was not closed.") }
            index += 1
            return .row(inner)
        }
        return try parseAtom()
    }

    private mutating func readGroup() throws -> MathNode {
        guard current == .open else {
            throw ReaderMathError.unsupported("This command needs a braced argument.")
        }
        index += 1
        let inner = try parseSequence(stop: .closingBrace)
        guard current == .close else { throw ReaderMathError.unsupported("A command argument was not closed.") }
        index += 1
        return .row(inner)
    }

    private mutating func readRawGroup() throws -> String {
        guard current == .open else {
            throw ReaderMathError.unsupported("This command needs a braced argument.")
        }
        index += 1
        var depth = 1
        var result = ""
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            switch token {
            case .open: depth += 1; result.append("{")
            case .close:
                depth -= 1
                if depth == 0 { return result }
                result.append("}")
            case .character(let char): result.append(char)
            case .command(let name): result.append("\\" + name)
            case .superscript: result.append("^")
            case .subscriptMark: result.append("_")
            case .ampersand: result.append("&")
            case .rowBreak: result.append("\\\\")
            case .space: result.append(" ")
            }
        }
        throw ReaderMathError.unsupported("A command argument was not closed.")
    }

    private mutating func readDelimiter() throws -> String {
        guard let token = current else { throw ReaderMathError.unsupported("\\left or \\right has no delimiter.") }
        index += 1
        switch token {
        case .character(let char): return String(char)
        case .command(let name):
            switch name {
            case "lvert", "vert": return "|"
            case "rvert": return "|"
            case "lbrace": return "{"
            case "rbrace": return "}"
            case "langle": return "⟨"
            case "rangle": return "⟩"
            default: throw ReaderMathError.unsupported("Unsupported delimiter \\\(name).")
            }
        default:
            throw ReaderMathError.unsupported("Unexpected delimiter.")
        }
    }

    private mutating func parseCommand(_ name: String) throws -> MathNode {
        switch name {
        case "frac", "dfrac", "tfrac":
            let numerator = try readGroup()
            let denominator = try readGroup()
            return .fraction(numerator, denominator)
        case "sqrt":
            var index: MathNode?
            if current == .character("[") {
                index = try readBracketGroup()
            }
            let body = try readGroup()
            return .squareRoot(index: index, body: body)
        case "text", "mathrm":
            return .text(try readRawGroup(), size: 0, italic: false, bold: false)
        case "mathbf", "boldsymbol":
            return .text(try readRawGroup(), size: 0, italic: false, bold: true)
        case "mathit":
            return .text(try readRawGroup(), size: 0, italic: true, bold: false)
        case "operatorname":
            return .text(try readRawGroup(), size: 0, italic: false, bold: false)
        case "mathbb", "mathcal", "mathsf", "mathtt":
            return .text(try readRawGroup(), size: 0, italic: false, bold: false)
        case "hat", "widehat":
            return .accent(try readGroup(), symbol: "^")
        case "bar", "overline":
            return .accent(try readGroup(), symbol: "‾")
        case "vec":
            return .accent(try readGroup(), symbol: "→")
        case "dot":
            return .accent(try readGroup(), symbol: "·")
        case "left":
            let left = try readDelimiter()
            let body = try parseSequence(stop: .rightDelimiter)
            guard current == .command("right") else {
                throw ReaderMathError.unsupported("\\left has no matching \\right.")
            }
            index += 1
            let right = try readDelimiter()
            return .delimited(left: left, body: .row(body), right: right)
        case "begin":
            return try parseEnvironment()
        case "sum", "prod", "coprod", "bigcup", "bigcap":
            return .bigOperator(Self.glyph(for: name) ?? name, lower: nil, upper: nil, display: display)
        case "int", "iint", "iiint", "oint":
            return .bigOperator(Self.glyph(for: name) ?? name, lower: nil, upper: nil, display: display)
        case "quad": return .space(1.0)
        case "qquad": return .space(2.0)
        case ",", ":", ";", "!": return .space(name == "!" ? -0.1 : 0.16)
        case "displaystyle", "textstyle", "limits", "nolimits":
            return .space(0)
        default:
            if let glyph = Self.glyph(for: name) {
                return .text(glyph, size: 0, italic: Self.italicCommands.contains(name), bold: false)
            }
            throw ReaderMathError.unsupported("Unsupported math command \\\(name).")
        }
    }

    private mutating func readBracketGroup() throws -> MathNode {
        guard current == .character("[") else {
            throw ReaderMathError.unsupported("Expected an optional argument.")
        }
        index += 1
        var depth = 1
        var inner: [MathNode] = []
        while let token = current {
            index += 1
            if case .character("]") = token {
                depth -= 1
                if depth == 0 { return .row(inner) }
            }
            if case .character("[") = token { depth += 1 }
            // Re-parse the consumed token by pushing it back through a tiny local mapping.
            switch token {
            case .character(let char): inner.append(.text(String(char), size: 0, italic: false, bold: false))
            case .command(let name):
                if let glyph = Self.glyph(for: name) {
                    inner.append(.text(glyph, size: 0, italic: false, bold: false))
                } else {
                    throw ReaderMathError.unsupported("Unsupported command in a root index.")
                }
            case .space: inner.append(.space(0.16))
            default: break
            }
        }
        throw ReaderMathError.unsupported("The root index was not closed.")
    }

    private mutating func parseEnvironment() throws -> MathNode {
        let name = try readRawGroup()
        let supported = ["matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix",
                         "cases", "aligned", "array"]
        guard supported.contains(name) else {
            throw ReaderMathError.unsupported("Unsupported math environment \(name).")
        }
        if name == "array" {
            _ = try? readRawGroup()
        }
        var rows: [[MathNode]] = []
        var currentRow: [MathNode] = []
        var currentCell: [MathNode] = []
        let stop = StopCondition.environmentEnd(name)

        func finishCell() {
            currentRow.append(.row(currentCell))
            currentCell = []
        }
        func finishRow() {
            finishCell()
            rows.append(currentRow)
            currentRow = []
        }

        while true {
            if stop.matches(current ?? .space, index: index, tokens: tokens) {
                if !currentCell.isEmpty || !currentRow.isEmpty {
                    finishRow()
                }
                index += 1 // \end
                guard current == .open else {
                    throw ReaderMathError.unsupported("\\end has no environment name.")
                }
                index += 1
                while let token = current, token != .close { index += 1 }
                guard current == .close else {
                    throw ReaderMathError.unsupported("\\end has no closing brace.")
                }
                index += 1
                break
            }
            if current == nil { throw ReaderMathError.unsupported("A matrix environment was not closed.") }
            if current == .ampersand {
                index += 1
                finishCell()
                continue
            }
            if current == .rowBreak {
                index += 1
                finishRow()
                continue
            }
            var atom = try parseAtom()
            var superscript: MathNode?
            var subscriptNode: MathNode?
            var attached = false
            while current == .superscript || current == .subscriptMark {
                if current == .superscript {
                    index += 1
                    superscript = try parseScriptGroup()
                } else {
                    index += 1
                    subscriptNode = try parseScriptGroup()
                }
                attached = true
            }
            if attached {
                atom = .script(base: atom, superscript: superscript,
                               subscriptNode: subscriptNode, limits: false)
            }
            currentCell.append(atom)
        }
        let left: String
        let right: String
        switch name {
        case "pmatrix": left = "("; right = ")"
        case "bmatrix": left = "["; right = "]"
        case "Bmatrix": left = "{"; right = "}"
        case "vmatrix": left = "|"; right = "|"
        case "Vmatrix": left = "‖"; right = "‖"
        case "cases": left = "{"; right = ""
        case "aligned": left = ""; right = ""
        default: left = ""; right = ""
        }
        return .matrix(rows: rows, left: left, right: right)
    }

    static let italicCommands: Set<String> = []
    static let glyphs: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ",
        "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ",
        "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
        "omicron": "ο", "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ",
        "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ",
        "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
        "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "times": "×", "cdot": "·", "div": "÷", "pm": "±", "mp": "∓",
        "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥", "ne": "≠", "neq": "≠",
        "approx": "≈", "sim": "∼", "simeq": "≃", "equiv": "≡", "propto": "∝",
        "infty": "∞", "partial": "∂", "nabla": "∇", "forall": "∀", "exists": "∃",
        "in": "∈", "notin": "∉", "subset": "⊂", "subseteq": "⊆", "supset": "⊃",
        "supseteq": "⊇", "cup": "∪", "cap": "∩", "to": "→", "rightarrow": "→",
        "leftarrow": "←", "Rightarrow": "⇒", "Leftarrow": "⇐", "leftrightarrow": "↔",
        "ldots": "…", "cdots": "⋯", "dots": "…", "prime": "′",
        "sum": "∑", "prod": "∏", "coprod": "∐", "bigcup": "⋃", "bigcap": "⋂",
        "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮",
        "sqrt": "√", "angle": "∠", "perp": "⊥", "parallel": "∥", "mid": "|",
        "langle": "⟨", "rangle": "⟩", "lbrace": "{", "rbrace": "}",
    ]

    static func glyph(for name: String) -> String? { glyphs[name] }
}

// MARK: - Layout

private enum MathLayout {
    static func font(size: CGFloat, italic: Bool = false, bold: Bool = false) -> NSFont {
        let family = NSFont(name: "Times New Roman", size: size)
            ?? NSFont.systemFont(ofSize: size)
        var font = family
        if bold {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    static func textBox(
        _ text: String,
        size: CGFloat,
        italic: Bool = false,
        bold: Bool = false
    ) -> MathBox {
        let font = font(size: size, italic: italic, bold: bold)
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        return MathBox(width: max(0, width), ascent: ascent, descent: descent) { context, x, y in
            context.saveGState()
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }

    static func layoutRow(
        _ nodes: [MathNode],
        size: CGFloat,
        display: Bool,
        baseSize: CGFloat
    ) -> MathBox {
        var boxes: [MathBox] = []
        for node in nodes {
            boxes.append(layout(node, size: size, display: display, baseSize: baseSize))
        }
        let width = boxes.reduce(0) { $0 + $1.width }
        let ascent = boxes.map(\.ascent).max() ?? 0
        let descent = boxes.map(\.descent).max() ?? 0
        let captured = boxes
        return MathBox(width: width, ascent: ascent, descent: descent) { context, x, y in
            var cursor = x
            for box in captured {
                box.draw(context, cursor, y)
                cursor += box.width
            }
        }
    }

    static func layout(
        _ node: MathNode,
        size: CGFloat,
        display: Bool,
        baseSize: CGFloat
    ) -> MathBox {
        switch node {
        case .text(let text, let explicitSize, let italic, let bold):
            let actual = explicitSize > 0 ? explicitSize : size
            if isOperator(text) {
                return spaced(textBox(text, size: actual, italic: italic, bold: bold), em: size)
            }
            return textBox(text, size: actual, italic: italic, bold: bold)
        case .space(let em):
            return MathBox(width: em * size, ascent: 0, descent: 0) { _, _, _ in }
        case .row(let nodes):
            return layoutRow(nodes, size: size, display: display, baseSize: baseSize)
        case .fraction(let numerator, let denominator):
            let scale: CGFloat = display ? 0.95 : 0.86
            let num = layout(numerator, size: size * scale, display: false, baseSize: baseSize)
            let den = layout(denominator, size: size * scale, display: false, baseSize: baseSize)
            let gap = size * 0.12
            let barThickness = max(0.6, size * 0.055)
            let width = max(num.width, den.width) + size * 0.36
            let ascent = num.height + gap + barThickness * 0.5
            let descent = den.height + gap + barThickness * 0.5
            return MathBox(width: width, ascent: ascent, descent: descent) { context, x, y in
                let numX = x + (width - num.width) / 2
                let denX = x + (width - den.width) / 2
                num.draw(context, numX, y + barThickness / 2 + gap + num.descent)
                den.draw(context, denX, y - barThickness / 2 - gap - den.ascent)
                context.setFillColor(NSColor.labelColor.cgColor)
                context.fill(CGRect(x: x + size * 0.10, y: y - barThickness / 2,
                                    width: width - size * 0.20, height: barThickness))
            }
        case .squareRoot(let indexNode, let bodyNode):
            let body = layout(bodyNode, size: size, display: display, baseSize: baseSize)
            let radicalSize = max(8, body.height * 0.95)
            let radical = textBox("√", size: radicalSize)
            var indexBox = MathBox.empty()
            if let indexNode {
                indexBox = layout(indexNode, size: size * 0.55, display: false, baseSize: baseSize)
            }
            let width = max(radical.width, indexBox.width) + body.width + size * 0.06
            let ascent = body.ascent + size * 0.16
            let descent = body.descent
            return MathBox(width: width, ascent: ascent, descent: descent) { context, x, y in
                let bodyX = x + max(radical.width, indexBox.width) + size * 0.02
                body.draw(context, bodyX, y)
                context.setStrokeColor(NSColor.labelColor.cgColor)
                context.setLineWidth(max(0.6, size * 0.055))
                context.beginPath()
                context.move(to: CGPoint(x: bodyX, y: y + body.ascent + size * 0.10))
                context.addLine(to: CGPoint(x: x + width, y: y + body.ascent + size * 0.10))
                context.strokePath()
                radical.draw(context, x, y - body.descent * 0.35)
                if indexBox.width > 0 {
                    indexBox.draw(context, x + radical.width - indexBox.width,
                                  y + body.ascent + size * 0.12)
                }
            }
        case .script(let baseNode, let superscript, let subscriptNode, let limits):
            let base = layout(baseNode, size: size, display: display, baseSize: baseSize)
            let small = size * 0.70
            let sup = superscript.map { layout($0, size: small, display: false, baseSize: baseSize) }
            let sub = subscriptNode.map { layout($0, size: small, display: false, baseSize: baseSize) }
            let supShift = max(size * 0.34, (sup?.descent ?? 0) + size * 0.14)
            let subShift = max(size * 0.18, (sub?.ascent ?? 0) - size * 0.04)
            let scriptWidth = max(sup?.width ?? 0, sub?.width ?? 0) + size * 0.06
            let ascent = max(base.ascent, supShift + (sup?.ascent ?? 0))
            let descent = max(base.descent, subShift + (sub?.descent ?? 0))
            return MathBox(width: base.width + scriptWidth, ascent: ascent, descent: descent) { context, x, y in
                base.draw(context, x, y)
                if let sup {
                    sup.draw(context, x + base.width + size * 0.04, y + supShift)
                }
                if let sub {
                    sub.draw(context, x + base.width + size * 0.04, y - subShift)
                }
            }
        case .bigOperator(let symbol, let lower, let upper, let display):
            let opSize = size * (display ? 1.45 : 1.15)
            let op = textBox(symbol, size: opSize)
            let lowerBox = lower.map { layout($0, size: size * 0.65, display: false, baseSize: baseSize) }
            let upperBox = upper.map { layout($0, size: size * 0.65, display: false, baseSize: baseSize) }
            let stackLimits = display && !["∫", "∬", "∭", "∮"].contains(symbol)
            if stackLimits, lowerBox != nil || upperBox != nil {
                let gap = size * 0.12
                let width = max(op.width, max(lowerBox?.width ?? 0, upperBox?.width ?? 0))
                let ascent = (upperBox?.height ?? 0) + gap + op.ascent
                let descent = (lowerBox?.height ?? 0) + gap + op.descent
                return MathBox(width: width, ascent: ascent, descent: descent) { context, x, y in
                    op.draw(context, x + (width - op.width) / 2, y)
                    if let upperBox {
                        upperBox.draw(context, x + (width - upperBox.width) / 2,
                                      y + op.ascent + gap + upperBox.descent)
                    }
                    if let lowerBox {
                        lowerBox.draw(context, x + (width - lowerBox.width) / 2,
                                      y - op.descent - gap - lowerBox.ascent)
                    }
                }
            }
            let subWidth = max(lowerBox?.width ?? 0, upperBox?.width ?? 0)
            let ascent = max(op.ascent, (upperBox?.height ?? 0) + size * 0.06)
            let descent = max(op.descent, (lowerBox?.height ?? 0) + size * 0.06)
            return MathBox(width: op.width + subWidth + size * 0.06, ascent: ascent, descent: descent) { context, x, y in
                op.draw(context, x, y)
                if let upperBox {
                    upperBox.draw(context, x + op.width + size * 0.04,
                                  y + op.ascent - upperBox.descent)
                }
                if let lowerBox {
                    lowerBox.draw(context, x + op.width + size * 0.04,
                                  y - op.descent + lowerBox.ascent)
                }
            }
        case .delimited(let left, let bodyNode, let right):
            let body = layout(bodyNode, size: size, display: display, baseSize: baseSize)
            let leftBox = delimiter(left, height: max(body.height, size))
            let rightBox = delimiter(right, height: max(body.height, size))
            let gap = size * 0.06
            let width = leftBox.width + gap + body.width + gap + rightBox.width
            let ascent = max(body.ascent, max(leftBox.ascent, rightBox.ascent))
            let descent = max(body.descent, max(leftBox.descent, rightBox.descent))
            return MathBox(width: width, ascent: ascent, descent: descent) { context, x, y in
                leftBox.draw(context, x, y)
                body.draw(context, x + leftBox.width + gap, y)
                rightBox.draw(context, x + leftBox.width + gap + body.width + gap, y)
            }
        case .matrix(let rows, let left, let right):
            let cellGap = size * 0.55
            let rowGap = size * 0.30
            let laidOut: [[MathBox]] = rows.map { row in
                row.map { layout($0, size: size * 0.96, display: false, baseSize: baseSize) }
            }
            let columns = laidOut.map(\.count).max() ?? 0
            var widths = Array(repeating: CGFloat(0), count: max(columns, 1))
            for row in laidOut {
                for (column, cell) in row.enumerated() where column < widths.count {
                    widths[column] = max(widths[column], cell.width)
                }
            }
            let rowHeights = laidOut.map { row -> (ascent: CGFloat, descent: CGFloat) in
                (row.map(\.ascent).max() ?? size * 0.6, row.map(\.descent).max() ?? size * 0.2)
            }
            let totalWidth = widths.reduce(0, +) + cellGap * CGFloat(max(columns - 1, 0))
            let totalHeight = rowHeights.reduce(0) { $0 + $1.ascent + $1.descent + rowGap }
            let bodyAscent = totalHeight / 2 + size * 0.15
            let leftBox = delimiter(left, height: max(totalHeight, size))
            let rightBox = delimiter(right, height: max(totalHeight, size))
            let gap = size * 0.10
            let width = leftBox.width + gap + totalWidth + gap + rightBox.width
            let ascent = max(bodyAscent, max(leftBox.ascent, rightBox.ascent))
            let descent = max(totalHeight - bodyAscent, max(leftBox.descent, rightBox.descent))
            return MathBox(width: width, ascent: ascent, descent: descent) { context, x, y in
                leftBox.draw(context, x, y)
                var rowBottom = y + totalHeight / 2
                for (rowIndex, row) in laidOut.enumerated() {
                    let metrics = rowHeights[rowIndex]
                    rowBottom -= metrics.ascent
                    var cellX = x + leftBox.width + gap
                    for (column, cell) in row.enumerated() {
                        let width = widths[column]
                        cell.draw(context, cellX + (width - cell.width) / 2, rowBottom)
                        cellX += width + cellGap
                    }
                    rowBottom -= metrics.descent + rowGap
                }
                rightBox.draw(context, x + leftBox.width + gap + totalWidth + gap, y)
            }
        case .accent(let bodyNode, let symbol):
            let body = layout(bodyNode, size: size, display: display, baseSize: baseSize)
            let accent = textBox(symbol, size: max(size * 0.55, 6))
            let width = max(body.width, accent.width)
            let ascent = body.ascent + accent.height * 0.65
            return MathBox(width: width, ascent: ascent, descent: body.descent) { context, x, y in
                body.draw(context, x + (width - body.width) / 2, y)
                accent.draw(context, x + (width - accent.width) / 2,
                            y + body.ascent + accent.height * 0.15)
            }
        }
    }

    static func isOperator(_ text: String) -> Bool {
        guard text.count == 1, let scalar = text.unicodeScalars.first else { return false }
        return "=<>≤≥≠≈±∓×÷⇒→←↔∈∉⊂⊆⊃⊇∪∩".unicodeScalars.contains(scalar)
    }

    static func spaced(_ box: MathBox, em: CGFloat) -> MathBox {
        let pad = em * 0.16
        return MathBox(width: box.width + pad * 2, ascent: box.ascent, descent: box.descent) { context, x, y in
            box.draw(context, x + pad, y)
        }
    }

    static func delimiter(_ symbol: String, height: CGFloat) -> MathBox {
        guard !symbol.isEmpty else { return MathBox.empty() }
        let size = max(10, height * 1.02)
        let font = font(size: size)
        let attributed = NSAttributedString(string: symbol, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let yShift = (height - (ascent + descent)) / 2
        return MathBox(width: max(width, size * 0.18), ascent: max(ascent, height / 2),
                       descent: max(descent, height / 2)) { context, x, y in
            context.saveGState()
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: x, y: y - yShift)
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }
}
