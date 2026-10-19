import LyraReaderKit
import CoreGraphics
import Foundation

extension ReaderChecks {
    /// Annotation text export: exact Markdown structure, RFC 4180 round trip, the no-annotation
    /// path, document order, source labelling, suggested names and the real fixtures.
    @MainActor static func annotationExportChecks(root: URL) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-reader-annotation-export-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        try markdownStructureCheck()
        try csvRoundTripCheck()
        try documentOrderCheck()
        try suggestedFilenameCheck()
        try await emptyExportCheck(root: root, scratch: scratch)
        try await mixedSourceExportCheck(root: root, scratch: scratch)
    }

    // MARK: - Exact Markdown structure

    /// A document with a highlight, a sticky note, a reply and an annotation that came from the
    /// file. The expected text is written out in full on purpose: this is the format's contract,
    /// not a property this test re-derives from the implementation.
    @MainActor static func markdownStructureCheck() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        let longQuote = String(
            repeating: "A long highlighted passage that must not be truncated. ",
            count: 12
        ).trimmingCharacters(in: .whitespaces)
        let entries = [
            AnnotationExportEntry(
                id: "nm:reply",
                page: 0,
                kind: "text",
                colorHex: nil,
                author: "Reviewer B",
                date: exportDate("2024-01-02T03:10:00Z"),
                quote: nil,
                comment: "Agreed.",
                source: .pdf,
                parentID: "nm:pdf-note",
                yPt: 40
            ),
            AnnotationExportEntry(
                id: "sidecar-highlight",
                page: 0,
                kind: "highlight",
                colorHex: "#FFD84066",
                author: "Alex",
                date: exportDate("2024-06-01T10:00:00Z"),
                quote: longQuote + "\nsecond line",
                comment: "Reader's note.",
                source: .sidecar,
                yPt: 120
            ),
            AnnotationExportEntry(
                id: "nm:pdf-note",
                page: 0,
                kind: "text",
                colorHex: "#FFCC33FF",
                author: "Reviewer A",
                date: exportDate("2024-01-02T03:04:05Z"),
                quote: nil,
                comment: "A sticky note body.",
                source: .pdf,
                yPt: 40
            ),
            AnnotationExportEntry(
                id: "sidecar-underline",
                page: 1,
                kind: "underline",
                colorHex: "#60A0F0AA",
                author: "Alex",
                date: exportDate("2024-06-01T10:05:00Z"),
                quote: "Something underlined.",
                comment: nil,
                source: .sidecar,
                yPt: 200
            ),
        ]
        let document = AnnotationExportDocument(
            fileName: "paper.pdf",
            pageCount: 3,
            exportedAt: exportDate("2026-10-17T17:40:00Z"),
            timeZone: utc,
            entries: entries
        )
        let markdown = AnnotationExport.markdown(document)
        let expected = """
        # Annotations — paper.pdf

        - **Pages:** 3
        - **Annotations:** 4
        - **Exported:** 2026-10-17T17:40:00Z

        ## Page 1

        ### Sticky note

        - **Colour:** #FFCC33FF
        - **Author:** Reviewer A
        - **Date:** 2024-01-02T03:04:05Z
        - **Source:** PDF annotation (read from the file)

        **Comment**

        A sticky note body.

        #### Reply · Sticky note

        - **Colour:** not set in the file
        - **Author:** Reviewer B
        - **Date:** 2024-01-02T03:10:00Z
        - **Source:** PDF annotation (read from the file)
        - **In reply to:** `nm:pdf-note`

        **Comment**

        Agreed.

        ### Highlight

        - **Colour:** #FFD84066
        - **Author:** Alex
        - **Date:** 2024-06-01T10:00:00Z
        - **Source:** LyraReader annotation sidecar (saved beside the PDF)

        **Quote**

        > \(longQuote)
        > second line

        **Comment**

        Reader's note.

        ## Page 2

        ### Underline

        - **Colour:** #60A0F0AA
        - **Author:** Alex
        - **Date:** 2024-06-01T10:05:00Z
        - **Source:** LyraReader annotation sidecar (saved beside the PDF)

        **Quote**

        > Something underlined.
        """
        if markdown != expected + "\n" {
            print("--- annotation export Markdown (actual) ---")
            print(markdown)
            print("--- annotation export Markdown (expected) ---")
            print(expected + "\n")
        }
        require(markdown == expected + "\n", "Markdown has the exact expected structure")
        require(markdown.contains(longQuote),
                "a long quote is exported in full, not truncated")
        require(!markdown.contains("## Page 3"),
                "a page with no annotations is omitted")
        require(markdown.contains("- **In reply to:** `nm:pdf-note`"),
                "a reply names its parent")
    }

    // MARK: - CSV round trip

    /// A quote containing a comma, a double quote and a newline has to survive the writer and a
    /// small independent parser. The parser is deliberately not the writer's inverse: it is the
    /// RFC 4180 state machine a consumer would implement.
    @MainActor static func csvRoundTripCheck() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        let quote = """
        First line, with a comma
        and "double quotes"
        and a final line.
        """
        let comment = "A comment, with \"quotes\" and a newline\nsecond line."
        let document = AnnotationExportDocument(
            fileName: "csv.pdf",
            pageCount: 1,
            exportedAt: exportDate("2026-10-17T17:40:00Z"),
            timeZone: utc,
            entries: [
                AnnotationExportEntry(
                    id: "root-id",
                    page: 0,
                    kind: "highlight",
                    colorHex: "#FFD84066",
                    author: "Alex",
                    date: exportDate("2024-06-01T10:00:00Z"),
                    quote: quote,
                    comment: comment,
                    source: .sidecar,
                    yPt: 10
                ),
                AnnotationExportEntry(
                    id: "reply-id",
                    page: 0,
                    kind: "text",
                    colorHex: nil,
                    author: "Reviewer B",
                    date: exportDate("2024-01-02T03:10:00Z"),
                    quote: nil,
                    comment: "Reply body.",
                    source: .pdf,
                    parentID: "root-id",
                    yPt: 10
                ),
            ]
        )

        let csv = AnnotationExport.csv(document)
        let rows = ExportCSVTable.parse(csv)
        if rows.count != 3 {
            FileHandle.standardError.write(Data((
                "--- annotation export CSV (actual) ---\n\(csv.debugDescription)\nrows: \(rows)\n"
            ).utf8))
        }
        require(rows.count == 3, "CSV has one header and one row per annotation")
        require(rows[0] == AnnotationExport.csvHeader, "CSV header names every column")
        require(rows.allSatisfy { $0.count == AnnotationExport.csvHeader.count },
                "every CSV row has the same number of fields as the header")
        require(rows[1][5] == quote,
                "a comma, a double quote and a newline all survive the CSV round trip")
        require(rows[1][6] == comment,
                "a comment with quotes and a newline also round-trips")
        require(rows[1][7] == "" && rows[1][8] == "root-id" && rows[1][9] == "sidecar",
                "a top-level sidecar row has an empty reply-to, its id and its source")
        require(rows[2][7] == "root-id",
                "a reply row names its immediate parent")
        require(csv.contains("\"\"double quotes\"\""),
                "embedded double quotes are doubled, as RFC 4180 requires")
        require(csv.hasSuffix("\r\n"), "CSV rows are terminated by CRLF")
    }

    // MARK: - Document order

    @MainActor static func documentOrderCheck() throws {
        func entry(
            _ id: String,
            page: Int,
            y: CGFloat,
            seconds: TimeInterval,
            parent: String? = nil
        ) -> AnnotationExportEntry {
            AnnotationExportEntry(
                id: id,
                page: page,
                kind: "highlight",
                date: Date(timeIntervalSince1970: seconds),
                source: .sidecar,
                parentID: parent,
                yPt: y
            )
        }
        let document = AnnotationExportDocument(
            fileName: "order.pdf",
            pageCount: 2,
            exportedAt: exportDate("2026-10-17T17:40:00Z"),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            entries: [
                entry("page1", page: 1, y: 0, seconds: 10),
                entry("low", page: 0, y: 200, seconds: 5),
                entry("high-late", page: 0, y: 100, seconds: 9),
                entry("high-early", page: 0, y: 100, seconds: 7),
                entry("reply", page: 0, y: 0, seconds: 2, parent: "low"),
            ]
        )
        require(
            document.rows.map(\.entry.id) == ["high-early", "high-late", "low", "reply", "page1"],
            "order is page, then vertical position, then creation time, with replies under parents"
        )
        require(document.rows.map(\.depth) == [0, 0, 0, 1, 0],
                "the reply row is one level deep")
        require(document.rows.map(\.sectionPage) == [0, 0, 0, 0, 1],
                "a reply belongs to its parent's page section")
    }

    // MARK: - Suggested names

    @MainActor static func suggestedFilenameCheck() throws {
        let document = URL(fileURLWithPath: "/tmp/paper.v2.pdf")
        require(
            AnnotationExport.suggestedFilename(documentURL: document, format: .markdown)
                == "paper.v2 (annotations).md",
            "the Markdown name is derived from the document name"
        )
        require(
            AnnotationExport.suggestedFilename(documentURL: document, format: .csv)
                == "paper.v2 (annotations).csv",
            "the CSV name keeps the same stem and changes the extension"
        )
        require(
            AnnotationExport.suggestedFilename(documentURL: nil, format: .markdown)
                == "Document (annotations).md",
            "a document without a URL still gets a usable name"
        )
    }

    // MARK: - Nothing to export

    @MainActor static func emptyExportCheck(root: URL, scratch: URL) async throws {
        let documentURL = scratch.appendingPathComponent("empty.pdf")
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("tests/fixtures/text-page.pdf"),
            to: documentURL
        )
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        require(state.open(url: documentURL), "the empty fixture opens")
        try await eventually("the empty fixture's annotation read finishes", {
            !state.documentAnnotationsLoading
        })
        require(state.documentAnnotations.isEmpty,
                "the fixture carries no PDF annotations, so this is the empty case")

        let markdownURL = scratch.appendingPathComponent("empty (annotations).md")
        let wroteMarkdown = await state.exportAnnotations(
            to: markdownURL,
            format: .markdown,
            exportedAt: exportDate("2026-10-17T17:40:00Z"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        require(!wroteMarkdown, "exporting nothing reports failure instead of writing")
        require(!FileManager.default.fileExists(atPath: markdownURL.path),
                "no Markdown file is written for an empty document")
        require(state.statusMessage == "There are no annotations to export",
                "the status line says plainly that there are no annotations (got \"\(state.statusMessage)\")")
        require(state.lastError?.contains("no annotations") == true,
                "the reader is told why nothing was written (got \"\(state.lastError ?? "nil")\")")

        let csvURL = scratch.appendingPathComponent("empty (annotations).csv")
        let wroteCSV = await state.exportAnnotations(
            to: csvURL,
            format: .csv,
            exportedAt: exportDate("2026-10-17T17:40:00Z"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        require(!wroteCSV && !FileManager.default.fileExists(atPath: csvURL.path),
                "the CSV path writes nothing either")
        require(!state.hasAnnotationsToExport,
                "the state itself reports that there is nothing to export")
    }

    // MARK: - The real fixtures: sidecar and file annotations together

    @MainActor static func mixedSourceExportCheck(root: URL, scratch: URL) async throws {
        let fixture = root.appendingPathComponent("tests/fixtures/annotated-replies.pdf")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            print("INFO: skipping annotation text export (no reply fixture at \(fixture.path))")
            return
        }
        let documentURL = scratch.appendingPathComponent("replies.pdf")
        try FileManager.default.copyItem(at: fixture, to: documentURL)

        // A sidecar entry is seeded through the real file format, so loading it exercises the
        // same decoder an ordinary reader does. Its range is a real span of page text.
        let probe = try RustEngine()
        _ = try probe.openDocument(at: documentURL)
        let textPage = try await probe.textPage(0)
        guard let firstGlyph = textPage.chars.firstIndex(where: { character in
            Unicode.Scalar(character.unicode).map {
                !CharacterSet.whitespacesAndNewlines.contains($0)
            } ?? false
        }), textPage.chars.count > 1 else {
            fatalError("FAIL: the reply fixture has no usable text layer")
        }
        let lastGlyph = min(firstGlyph + 24, textPage.chars.count - 1)
        let range = firstGlyph...lastGlyph
        let sidecarAnnotation = AppState.Annotation(
            id: UUID(),
            kind: .highlight,
            page: 0,
            start: range.lowerBound,
            end: range.upperBound,
            color: AppState.highlightPalette[2].color,
            note: "Reader's note, with a comma and a \"quote\".",
            createdAt: exportDate("2026-10-16T09:30:00Z")
        )
        let encoder = JSONEncoder()
        try encoder.encode([sidecarAnnotation]).write(
            to: documentURL.appendingPathExtension("lyra-reader-annotations.json")
        )
        let expectedQuote = AnnotationExport.normalized(
            AnnotationExport.text(in: textPage, range: range) ?? ""
        )

        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        require(state.open(url: documentURL), "the mixed-source fixture opens")
        try await eventually("the PDF's own annotations are read", {
            state.documentAnnotationsError != nil || state.documentAnnotations.count == 11
        })
        require(state.documentAnnotationsError == nil,
                "reading the reply fixture's annotations does not fail")
        require(state.documentAnnotations.count == 11,
                "all eleven /IRT annotations are available for export")
        require(state.annotations.count == 1, "the seeded sidecar annotation is loaded")

        let utc = TimeZone(secondsFromGMT: 0)!
        let exportedAt = exportDate("2026-10-17T17:40:00Z")
        guard let export = await state.annotationExportDocument(
            exportedAt: exportedAt,
            timeZone: utc
        ) else {
            fatalError("FAIL: the mixed document produced no export")
        }
        let expectedCount = state.annotations.count + state.documentAnnotations.count
        require(export.rows.count == expectedCount,
                "every sidecar and PDF annotation is in the export")
        require(export.rows.filter { $0.entry.source == .sidecar }.count == 1,
                "the sidecar annotation is marked as the reader's")
        require(export.rows.filter { $0.entry.source == .pdf }.count == 11,
                "the file's own annotations are marked as coming from the PDF")
        require(export.rows.filter { $0.entry.parentID != nil }.count
                    == state.documentAnnotations.filter(\.isReply).count,
                "every reply keeps its reply-to link")
        require(export.rows.contains { $0.depth >= 2 },
                "a reply to a reply is nested deeper than its parent")

        let markdownURL = scratch.appendingPathComponent(
            AnnotationExport.suggestedFilename(documentURL: documentURL, format: .markdown)
        )
        let wroteMarkdown = await state.exportAnnotations(
            to: markdownURL,
            format: .markdown,
            exportedAt: exportedAt,
            timeZone: utc
        )
        require(wroteMarkdown, "the Markdown export writes a file")
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        guard let loaded = state.document else {
            fatalError("FAIL: the mixed fixture left no loaded document")
        }
        require(markdown.hasPrefix("# Annotations — replies.pdf\n\n"),
                "the document heading names the file")
        require(markdown.contains("- **Pages:** \(loaded.pageCount)\n"),
                "the document heading carries the page count")
        require(markdown.contains("- **Annotations:** \(expectedCount)\n"),
                "the document heading counts every exported annotation")
        require(markdown.contains("- **Exported:** 2026-10-17T17:40:00Z"),
                "the document heading carries the export date")
        require(markdown.contains("- **Source:** LyraReader annotation sidecar (saved beside the PDF)"),
                "sidecar annotations say where they came from")
        require(markdown.contains("- **Source:** PDF annotation (read from the file)"),
                "the file's annotations are marked as such")
        require(markdown.contains("#### Reply ·"),
                "a first-level reply gets its own deeper heading")
        require(markdown.contains("##### Reply ·"),
                "a second-level reply gets one level deeper still")
        require(markdown.contains(sidecarAnnotation.note),
                "the sidecar note's text is in the export")
        if let firstLine = expectedQuote?.split(separator: "\n").first {
            require(markdown.contains("> \(firstLine)"),
                    "the quote under the sidecar highlight is recovered from the page text")
        }
        let pageOne = markdown.range(of: "## Page 1")
        let pageTwo = markdown.range(of: "## Page 2")
        require(pageOne != nil && pageTwo != nil
                    && pageOne!.lowerBound < pageTwo!.lowerBound,
                "page sections are in document order")
        require(markdown.contains("- **Date:** 2024-01-02T03:04:05Z"),
                "the file's /M date is carried into the export")
        require(markdown.contains("- **In reply to:** `nm:parent-highlight`"),
                "a reply names its parent")

        let csvURL = scratch.appendingPathComponent(
            AnnotationExport.suggestedFilename(documentURL: documentURL, format: .csv)
        )
        let wroteCSV = await state.exportAnnotations(
            to: csvURL,
            format: .csv,
            exportedAt: exportedAt,
            timeZone: utc
        )
        require(wroteCSV, "the CSV export writes a file")
        let csvText = try String(contentsOf: csvURL, encoding: .utf8)
        let rows = ExportCSVTable.parse(csvText)
        require(rows.count == expectedCount + 1,
                "the CSV has one row per exported annotation plus the header")
        require(rows.allSatisfy { $0.count == AnnotationExport.csvHeader.count },
                "every mixed-source CSV row has all its columns")
        let header = rows[0]
        guard let idColumn = header.firstIndex(of: "id"),
              let replyColumn = header.firstIndex(of: "reply_to"),
              let sourceColumn = header.firstIndex(of: "source") else {
            fatalError("FAIL: the CSV header is missing an expected column")
        }
        let body = Array(rows.dropFirst())
        let sources = Set(body.map { $0[sourceColumn] })
        require(sources == ["pdf", "sidecar"], "both sources appear in the CSV")
        let sidecarRow = body.first { $0[idColumn] == sidecarAnnotation.id.uuidString }
        require(sidecarRow?[sourceColumn] == "sidecar" && sidecarRow?[replyColumn] == "",
                "the sidecar annotation is a top-level sidecar row")
        let replyRows = body.filter { !$0[replyColumn].isEmpty }
        require(replyRows.count == state.documentAnnotations.filter(\.isReply).count,
                "every reply row names the annotation it answers")
        let ids = Set(body.map { $0[idColumn] })
        require(replyRows.contains { ids.contains($0[replyColumn]) },
                "at least one reply-to names an exported annotation")
        require(csvText.contains("\"Reader's note, with a comma and a \"\"quote\"\".\""),
                "the sidecar note's comma and quote survive CSV quoting")

        // Human-eye evidence: the same fixtures' export, kept outside the scratch directory so
        // it can be opened in a Markdown viewer or spreadsheet (the full check suite uses
        // LYRA_READER_CHECK_SNAPSHOT_DIR for its other visual artifacts too).
        if let directory = ProcessInfo.processInfo.environment["LYRA_READER_CHECK_SNAPSHOT_DIR"] {
            let snapshots = URL(fileURLWithPath: directory)
            try? FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(
                at: markdownURL,
                to: snapshots.appendingPathComponent("annotation-export.md")
            )
            try? FileManager.default.copyItem(
                at: csvURL,
                to: snapshots.appendingPathComponent("annotation-export.csv")
            )
        }

        require(state.suggestedAnnotationExportFilename(for: .markdown)
                    == "replies (annotations).md",
                "the state suggests the Markdown name from the open document")
        require(state.suggestedAnnotationExportFilename(for: .csv)
                    == "replies (annotations).csv",
                "the state suggests the CSV name from the open document")

        // A destination in a directory that does not exist fails the atomic write; no partial
        // file may be left behind.
        let unwritable = scratch.appendingPathComponent("missing/deeper/export.md")
        let failed = await state.exportAnnotations(
            to: unwritable,
            format: .markdown,
            exportedAt: exportedAt,
            timeZone: utc
        )
        require(!failed && !FileManager.default.fileExists(atPath: unwritable.path),
                "a failed export writes no destination file")
        require(state.lastError?.contains("Could not export annotations") == true,
                "a failed export reports why (got \"\(state.lastError ?? "nil")\")")
    }

    // MARK: - Helpers

    @MainActor static func exportDate(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else {
            fatalError("FAIL: the check's own ISO date \"\(value)\" did not parse")
        }
        return date
    }
}

/// A minimal RFC 4180 reader, independent of the writer: quoted fields may contain commas,
/// doubled quotes and CRLF or LF newlines, and rows end at an unquoted line break.
///
/// It walks UTF-8 bytes rather than `Character`s because Swift folds `\r\n` into one grapheme,
/// which would hide a row terminator from a parser that compared characters.
private enum ExportCSVTable {
    static func parse(_ text: String) -> [[String]] {
        let bytes = Array(text.utf8)
        let comma = UInt8(ascii: ",")
        let quote = UInt8(ascii: "\"")
        let carriageReturn = UInt8(ascii: "\r")
        let lineFeed = UInt8(ascii: "\n")

        var rows: [[String]] = []
        var fields: [String] = []
        var field: [UInt8] = []
        var inQuotes = false
        var index = 0

        func finishField() {
            fields.append(String(decoding: field, as: UTF8.self))
            field = []
        }
        func finishRow() {
            finishField()
            rows.append(fields)
            fields = []
        }

        while index < bytes.count {
            let byte = bytes[index]
            if inQuotes {
                if byte == quote {
                    let next = index + 1
                    if next < bytes.count, bytes[next] == quote {
                        field.append(quote)
                        index += 2
                        continue
                    }
                    inQuotes = false
                } else {
                    field.append(byte)
                }
                index += 1
                continue
            }

            switch byte {
            case quote:
                inQuotes = true
            case comma:
                finishField()
            case carriageReturn:
                if index + 1 < bytes.count, bytes[index + 1] == lineFeed {
                    index += 1
                }
                finishRow()
            case lineFeed:
                finishRow()
            default:
                field.append(byte)
            }
            index += 1
        }
        if !field.isEmpty || !fields.isEmpty {
            finishRow()
        }
        return rows
    }
}
