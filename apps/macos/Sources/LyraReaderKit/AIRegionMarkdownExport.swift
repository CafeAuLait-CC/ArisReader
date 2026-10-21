import Foundation

public struct AIRegionExportImage: Equatable, Sendable {
    public let fileName: String
    public let data: Data

    public init(fileName: String, data: Data) {
        self.fileName = fileName
        self.data = data
    }
}

public struct AIRegionExportDocument: Equatable, Sendable {
    public let markdown: String
    public let images: [AIRegionExportImage]
    public let omittedCount: Int
    public let imageFolderName: String

    public init(
        markdown: String,
        images: [AIRegionExportImage],
        omittedCount: Int,
        imageFolderName: String
    ) {
        self.markdown = markdown
        self.images = images
        self.omittedCount = omittedCount
        self.imageFolderName = imageFolderName
    }
}

public struct AIRegionExportOutcome: Equatable, Sendable {
    public let markdownURL: URL
    public let imageFolderURL: URL
    public let imageCount: Int
    public let omittedCount: Int
}

public enum AIRegionExportError: LocalizedError, Equatable {
    case nothingToExport

    public var errorDescription: String? {
        switch self {
        case .nothingToExport:
            return "There are no region conversations with an answer to export. Ask a region question first."
        }
    }
}

/// Writes one Markdown knowledge document and its pictures.
///
/// The document is the reader's: a title, the source file and export date, a table of contents,
/// and one numbered section per answered conversation. Pictures go into a sibling folder and are
/// linked relatively; no base64 is written into the `.md`, so a diff of the export is readable.
///
/// Conversations that never produced an answer (cancelled before the first token, or failed) are
/// omitted: a knowledge document should not present an error as knowledge. The omission is
/// stated in the front matter and counted in the outcome, never silent.
public enum AIRegionMarkdownExport {
    public static func refusalReason(for entries: [AIRegionHistoryEntry]) -> String? {
        entries.contains(where: \.hasAnswer) ? nil : AIRegionExportError.nothingToExport.localizedDescription
    }

    /// Build the document without touching the disk. The native checks use this directly.
    public static func render(
        documentTitle: String,
        documentFileName: String,
        entries: [AIRegionHistoryEntry],
        exportedAt: Date = Date(),
        imageFolderName: String
    ) -> AIRegionExportDocument {
        let answered = entries
            .filter(\.hasAnswer)
            .sorted { $0.createdAt < $1.createdAt }
        let omitted = entries.count - answered.count
        let title = singleLine(documentTitle).replacingOccurrences(of: "#", with: "\\#")
        let fileName = singleLine(documentFileName)
        var markdown = ""
        markdown += "# Region questions — \(title)\n\n"
        markdown += "- **Document:** `\(codeSpan(fileName))`\n"
        markdown += "- **Exported:** \(AIRegionDates.iso.string(from: exportedAt))\n"
        markdown += "- **Conversations:** \(answered.count)\n"
        if omitted > 0 {
            markdown += "- **Omitted:** \(omitted) conversation\(omitted == 1 ? "" : "s") with no answer\n"
        }
        markdown += "\n"
        markdown += "This document was exported from LyraReader. Region captures are stored in `\(imageFolderName)/` beside it; the `.md` itself contains relative links, not image data.\n\n"
        markdown += "## Contents\n\n"
        for (index, entry) in answered.enumerated() {
            markdown += "\(index + 1). [\(sectionTitle(index: index, entry: entry))](#\(sectionAnchor(index: index, entry: entry)))\n"
        }
        markdown += "\n"

        var images: [AIRegionExportImage] = []
        for (index, entry) in answered.enumerated() {
            let imageName = String(format: "region-%02d.png", index + 1)
            images.append(AIRegionExportImage(fileName: imageName, data: entry.attachment.png))
            markdown += "## \(sectionTitle(index: index, entry: entry))\n\n"
            if entry.state != .finished {
                markdown += "**Status:** \(entry.state == .cancelled ? "cancelled; the answer below is partial" : "failed; the answer below may be partial")\n\n"
            }
            markdown += "![\(altText(index: index, entry: entry))](\(linkPath(folder: imageFolderName, file: imageName)))\n\n"
            markdown += "**Page:** \(entry.attachment.page + 1) · **Region:** \(Int(entry.attachment.rect.width.rounded())) × \(Int(entry.attachment.rect.height.rounded())) pt · **Asked:** \(AIRegionDates.iso.string(from: entry.createdAt))\n\n"
            markdown += "**Question**\n\n"
            markdown += questionParagraph(entry.question)
            markdown += "\n\n**Answer**\n\n"
            markdown += entry.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            markdown += "\n\n"
            let citations = entry.citedPages
            if citations.isEmpty {
                markdown += "**Citations:** none\n\n"
            } else {
                markdown += "**Citations:** " + citations.map { "[p.\($0)]" }.joined(separator: " · ") + "\n\n"
            }
        }
        return AIRegionExportDocument(
            markdown: markdown,
            images: images,
            omittedCount: omitted,
            imageFolderName: imageFolderName
        )
    }

    /// Write the document and its images. The caller chooses the `.md`; the folder is created
    /// beside it with a name derived from the file's, so two exports in one directory do not
    /// overwrite each other's pictures.
    @discardableResult
    public static func write(
        entries: [AIRegionHistoryEntry],
        documentTitle: String,
        documentFileName: String,
        to markdownURL: URL,
        exportedAt: Date = Date()
    ) throws -> AIRegionExportOutcome {
        guard refusalReason(for: entries) == nil else {
            throw AIRegionExportError.nothingToExport
        }
        let folderName = imageFolderName(for: markdownURL)
        let document = render(
            documentTitle: documentTitle,
            documentFileName: documentFileName,
            entries: entries,
            exportedAt: exportedAt,
            imageFolderName: folderName
        )
        let directory = markdownURL.deletingLastPathComponent()
        let folderURL = directory.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        for image in document.images {
            try image.data.write(to: folderURL.appendingPathComponent(image.fileName), options: .atomic)
        }
        try document.markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
        return AIRegionExportOutcome(
            markdownURL: markdownURL,
            imageFolderURL: folderURL,
            imageCount: document.images.count,
            omittedCount: document.omittedCount
        )
    }

    /// `<basename>-images`, reduced to characters that need no escaping in a Markdown link.
    public static func imageFolderName(for markdownURL: URL) -> String {
        let base = markdownURL.deletingPathExtension().lastPathComponent
        let safe = base.map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_"
                || character == "." {
                return character
            }
            return "-"
        }
        let collapsed = String(safe).split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let name = collapsed.isEmpty ? "region-questions" : collapsed
        return name + "-images"
    }

    // MARK: - Formatting

    private static func sectionTitle(index: Int, entry: AIRegionHistoryEntry) -> String {
        let width = Int(entry.attachment.rect.width.rounded())
        let height = Int(entry.attachment.rect.height.rounded())
        return "\(index + 1). Page \(entry.attachment.page + 1) (\(width) x \(height) pt)"
    }

    private static func sectionAnchor(index: Int, entry: AIRegionHistoryEntry) -> String {
        anchor(sectionTitle(index: index, entry: entry))
    }

    private static func anchor(_ title: String) -> String {
        var result = ""
        var lastWasHyphen = false
        for scalar in title.lowercased().unicodeScalars {
            let isWord = CharacterSet.alphanumerics.contains(scalar)
            if isWord {
                result.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen, !result.isEmpty {
                result.append("-")
                lastWasHyphen = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }

    private static func linkPath(folder: String, file: String) -> String {
        let path = "\(folder)/\(file)"
        return path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }

    private static func altText(index: Int, entry: AIRegionHistoryEntry) -> String {
        "Selected region \(index + 1) on page \(entry.attachment.page + 1)"
    }

    private static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func codeSpan(_ text: String) -> String {
        text.replacingOccurrences(of: "`", with: "'")
    }

    /// A question is prose, not Markdown the model wrote. Escape the characters that would turn
    /// it into structure (a heading, a list, a fence, a quote) and the angle brackets that would
    /// start inline HTML; keep the reader's words themselves.
    private static func questionParagraph(_ question: String) -> String {
        let lines = question
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        return lines.map { rawLine -> String in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return "" }
            line = line.replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            if let first = line.first, "#>-+*|`".contains(first) {
                line = "\\" + line
            }
            if let range = line.range(of: #"^\d+[.)]\s"#, options: .regularExpression) {
                line.insert("\\", at: range.lowerBound)
            }
            return line
        }.joined(separator: "\n")
    }
}
