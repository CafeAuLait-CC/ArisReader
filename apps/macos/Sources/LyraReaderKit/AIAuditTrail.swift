import Combine
import Foundation
import LyraReaderBindings

// MARK: - What a record contains

/// The action kinds the local audit trail distinguishes. These are the six reader-facing
/// categories, not the internal Rust action names: three summary actions share `summarise`, and
/// the separately previewed consolidation is `summaryLayer`.
public enum AIAuditAction: String, Codable, CaseIterable, Sendable {
    case summarise
    case selectionQuestion = "selection_question"
    case translation
    case documentChat = "document_chat"
    case regionQuestion = "region_question"
    case summaryLayer = "summary_layer"

    /// Short label for the audit list.
    public var label: String {
        switch self {
        case .summarise: return "Summarise"
        case .selectionQuestion: return "Selection question"
        case .translation: return "Translation"
        case .documentChat: return "Document chat"
        case .regionQuestion: return "Region question"
        case .summaryLayer: return "Summary layer"
        }
    }

    public init(_ action: AiActionRecord) {
        switch action {
        case .summarizePage, .summarizeDocument, .summarizeSelection:
            self = .summarise
        case .askSelection:
            self = .selectionQuestion
        case .translateSelection:
            self = .translation
        case .documentChat:
            self = .documentChat
        case .regionQuestion:
            self = .regionQuestion
        case .summarizeAbstract, .summarizeSection, .summarizePageLine:
            self = .summaryLayer
        }
    }

    /// Used for a refusal that happens before a plan exists.
    public init(_ action: AIAssistantAction) {
        switch action {
        case .summarizePage, .summarizeDocument, .summarizeSelection:
            self = .summarise
        case .askSelection:
            self = .selectionQuestion
        case .translateSelection:
            self = .translation
        case .documentChat:
            self = .documentChat
        case .regionQuestion:
            self = .regionQuestion
        }
    }
}

/// How one attempt ended. `sent` means the transport accepted and completed the request.
public enum AIAuditOutcome: String, Codable, CaseIterable, Sendable {
    case sent
    case refused
    case failed
    case cancelled

    public var label: String {
        switch self {
        case .sent: return "Sent"
        case .refused: return "Refused before sending"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Stable, non-text failure and refusal categories. The trail never stores an error message:
/// provider messages can quote document text, and a message field would be a content leak by
/// construction.
public enum AIAuditCode: String, Codable, CaseIterable, Sendable {
    case noEndpoint = "no_endpoint"
    case noApiKey = "no_api_key"
    case signedOut = "signed_out"
    case connectionChanged = "connection_changed"
    case keychainUnavailable = "keychain_unavailable"
    case visionUnsupported = "vision_unsupported"
    case emptyContext = "empty_context"
    case nothingRelevant = "nothing_relevant"
    case invalidSettings = "invalid_settings"
    case notConfigured = "not_configured"
    case unauthorized
    case rateLimited = "rate_limited"
    case httpError = "http_error"
    case unreachable
    case timeout
    case protocolError = "protocol_error"
    case unsupportedCapability = "unsupported_capability"
    case providerError = "provider_error"
    case other

    /// Short label for the audit list. Deliberately a fixed vocabulary, not a message.
    public var label: String {
        switch self {
        case .noEndpoint: return "no endpoint configured"
        case .noApiKey: return "no API key"
        case .signedOut: return "not signed in"
        case .connectionChanged: return "connection changed"
        case .keychainUnavailable: return "keychain unavailable"
        case .visionUnsupported: return "image input is off"
        case .emptyContext: return "nothing to send"
        case .nothingRelevant: return "nothing relevant"
        case .invalidSettings: return "settings not usable"
        case .notConfigured: return "not configured"
        case .unauthorized: return "unauthorized"
        case .rateLimited: return "rate limited"
        case .httpError: return "HTTP error"
        case .unreachable: return "unreachable"
        case .timeout: return "timed out"
        case .protocolError: return "protocol error"
        case .unsupportedCapability: return "unsupported by the model"
        case .providerError: return "provider error"
        case .other: return "other"
        }
    }

    /// Classify an error thrown while starting a previewed request. Only the category is
    /// recorded; the message stays out of the trail.
    static func classifyStartFailure(_ error: Error) -> AIAuditCode {
        guard let settingsError = error as? AISettingsError else { return .other }
        switch settingsError {
        case .invalid(let message):
            if message.contains("No API key") { return .noApiKey }
            if message.contains("connection changed") { return .connectionChanged }
            if message.contains("ChatGPT account") || message.contains("Connect ChatGPT") {
                return .signedOut
            }
            if message.contains("engine is not available") { return .notConfigured }
            if message.contains("Keychain") { return .keychainUnavailable }
            return .invalidSettings
        }
    }

    /// Classify an error thrown while building a plan locally. Nothing was sent; the code says
    /// which local guard refused.
    static func classifyPreparationFailure(_ error: Error, baseURL: String) -> AIAuditCode {
        let message = AIReadableError.message(error)
        if message.contains("Nothing in this document is relevant") { return .nothingRelevant }
        if message.contains("Turn on image input") { return .visionUnsupported }
        if message.contains("no text layer") || message.contains("not available")
            || message.contains("too large") || message.contains("too long")
            || message.contains("nothing to send") || message.contains("nothing to ask")
            || message.contains("has no pages") || message.contains("outside this document")
        {
            return .emptyContext
        }
        if baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .noEndpoint
        }
        if message.contains("base URL") || message.contains("endpoint")
            || message.contains("model") || message.contains("Temperature")
            || message.contains("Max tokens") || message.contains("reasoning")
        {
            return .invalidSettings
        }
        return .other
    }

    /// Classify a stream error event. Provider messages are inspected only here, in memory;
    /// no substring of them is ever written to disk.
    static func classifyStreamFailure(message: String) -> AIAuditCode {
        let lower = message.lowercased()
        if lower.contains("unauthorized") || lower.contains("401") || lower.contains("api key") {
            return .unauthorized
        }
        if lower.contains("rate limit") || lower.contains("429") { return .rateLimited }
        if lower.contains("timed out") || lower.contains("timeout") { return .timeout }
        if lower.contains("http ") { return .httpError }
        if lower.contains("stream") || lower.contains("protocol") || lower.contains("malformed") {
            return .protocolError
        }
        if lower.contains("unreachable") || lower.contains("connection") { return .unreachable }
        if lower.contains("unsupported") || lower.contains("does not support") {
            return .unsupportedCapability
        }
        return .providerError
    }
}

/// Pixel size of the picture the request carried. The image bytes themselves are never kept.
public struct AIAuditImage: Codable, Equatable, Sendable {
    public let widthPixels: Int
    public let heightPixels: Int

    public init(widthPixels: Int, heightPixels: Int) {
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
    }

    enum CodingKeys: String, CodingKey {
        case widthPixels = "width_px"
        case heightPixels = "height_px"
    }

    public var label: String { "\(widthPixels) × \(heightPixels) px" }
}

/// One append-only audit record.
///
/// The shape is the content guard: there is no field for document text, prompt text, question
/// or answer text, a file path, a document title, a provider message, or image bytes. A caller
/// cannot add content to a record without changing this type, which is a visible, reviewed act.
public struct AIAuditRecord: Codable, Equatable, Sendable {
    /// When the request attempt started.
    public let at: Date
    public let action: AIAuditAction
    /// Host only: never the full URL (a URL can contain a path the reader typed).
    public let host: String
    public let model: String
    /// Characters in the request body's system and user messages. Counts only.
    public let characters: Int
    /// 1-based page numbers whose text the request carried, sorted and de-duplicated.
    public let pages: [Int]
    public let image: AIAuditImage?
    public let outcome: AIAuditOutcome
    /// A fixed category, never free text. Nil for `sent` and `cancelled`.
    public let code: AIAuditCode?
    public let durationMilliseconds: Int

    public init(
        at: Date,
        action: AIAuditAction,
        host: String,
        model: String,
        characters: Int,
        pages: [Int],
        image: AIAuditImage?,
        outcome: AIAuditOutcome,
        code: AIAuditCode?,
        durationMilliseconds: Int
    ) {
        self.at = at
        self.action = action
        self.host = host
        self.model = model
        self.characters = characters
        self.pages = pages
        self.image = image
        self.outcome = outcome
        self.code = code
        self.durationMilliseconds = durationMilliseconds
    }

    enum CodingKeys: String, CodingKey {
        case at, action, host, model, characters, pages, image, outcome, code
        case durationMilliseconds = "duration_ms"
    }
}

// MARK: - Storage

/// The local, bounded audit trail.
///
/// The file is `<application cache>/LyraReader/Audit/ai-requests.jsonl`, so it is per macOS
/// user and never beside a PDF. Each attempt appends one JSON line. At the bound the file is
/// rewritten with the newest records only; that rotation is the one non-append operation.
/// Clears truncate the file to zero bytes.
@MainActor
public final class AIAuditTrail: ObservableObject {
    /// Newest records kept. The count bound and the byte bound are applied together.
    nonisolated public static let maximumRecords = 500
    /// Byte bound for the JSONL file (256 KiB).
    nonisolated public static let maximumBytes = 256 * 1024
    nonisolated public static var maximumKilobytes: Int { maximumBytes / 1024 }

    /// The app's cache directory, or the checks' explicit override.
    public static var defaultDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["LYRA_READER_AI_AUDIT_DIR"],
           !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LyraReader/Audit", isDirectory: true)
    }

    public static let shared = AIAuditTrail()

    /// Newest first, so the panel lists recent requests without reversing anything.
    @Published public private(set) var records: [AIAuditRecord] = []
    /// The last local read/write problem. The trail is best-effort: a failure to write must
    /// never fail the AI request itself.
    @Published public private(set) var lastError: String?

    public let fileURL: URL
    private let maxRecords: Int
    private let maxBytes: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL? = nil, maxRecords: Int = AIAuditTrail.maximumRecords,
                maxBytes: Int = AIAuditTrail.maximumBytes) {
        let root = directory ?? Self.defaultDirectory
        self.fileURL = root.appendingPathComponent("ai-requests.jsonl", isDirectory: false)
        self.maxRecords = max(1, maxRecords)
        self.maxBytes = max(1, maxBytes)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        load()
    }

    public var isEmpty: Bool { records.isEmpty }

    /// Append one record, rotating first if this record would cross the bound.
    public func append(_ record: AIAuditRecord) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let line = try encodedLine(record)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            records.insert(record, at: 0)
            lastError = nil
            if records.count > maxRecords || fileByteCount() > maxBytes {
                rotate()
            }
        } catch {
            lastError = "The local audit record could not be written: \(error.localizedDescription)"
        }
    }

    /// Delete every record and truncate the file. The file stays in place (empty), so a reader
    /// can verify that clearing removed the bytes rather than moving them.
    public func clear() {
        records = []
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.truncate(atOffset: 0)
                try handle.close()
            } else {
                FileManager.default.createFile(atPath: fileURL.path, contents: Data())
            }
            lastError = nil
        } catch {
            lastError = "The local audit trail could not be cleared: \(error.localizedDescription)"
        }
    }

    /// Re-read the file. Used after an external truncation and by checks.
    public func reload() { load() }

    /// Start timing one request attempt. The attempt is only written when `finish` is called,
    /// so an abandoned preview never leaves a record.
    func begin(plan: AiPlanRecord, kind: AIAuditAction) -> AIAuditAttempt {
        let parts = plan.parts.map { part in
            AIAuditPart(
                index: Int(part.index),
                characters: Int(clamping: part.requestCharacters),
                pages: part.pages.map(Int.init),
                image: part.image.map {
                    AIAuditImage(widthPixels: Int($0.widthPx), heightPixels: Int($0.heightPx))
                }
            )
        }
        return AIAuditAttempt(
            trail: self,
            kind: kind,
            host: Self.host(plan: plan),
            model: plan.model,
            parts: parts,
            startedAt: Date()
        )
    }

    /// Record an attempt refused before a plan could be built. A refusal always has zero
    /// characters and no pages: nothing left this Mac.
    func refuse(kind: AIAuditAction, host: String, model: String,
                code: AIAuditCode, startedAt: Date) {
        append(AIAuditRecord(
            at: startedAt,
            action: kind,
            host: host,
            model: model,
            characters: 0,
            pages: [],
            image: nil,
            outcome: .refused,
            code: code,
            durationMilliseconds: elapsedMilliseconds(since: startedAt)
        ))
    }

    // MARK: File

    private func encodedLine(_ record: AIAuditRecord) throws -> Data {
        var data = try encoder.encode(record)
        data.append(0x0A)
        return data
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            records = []
            return
        }
        var decoded: [AIAuditRecord] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let record = try? decoder.decode(AIAuditRecord.self, from: Data(line)) {
                decoded.append(record)
            }
        }
        records = decoded.reversed()
        if records.count > maxRecords || data.count > maxBytes {
            rotate()
        }
    }

    /// Keep the newest records that fit both bounds and replace the file atomically. The newest
    /// record is always kept even if it alone is larger than the byte bound.
    private func rotate() {
        var kept: [AIAuditRecord] = []
        var data = Data()
        for record in records {
            guard let line = try? encodedLine(record) else { continue }
            if !kept.isEmpty && (kept.count >= maxRecords || data.count + line.count > maxBytes) {
                break
            }
            kept.append(record)
            data.append(line)
        }
        do {
            try data.write(to: fileURL, options: .atomic)
            records = kept
            lastError = nil
        } catch {
            lastError = "The local audit trail could not be rotated: \(error.localizedDescription)"
        }
    }

    private func fileByteCount() -> Int {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
    }

    // MARK: Derivation (counts only)

    private func elapsedMilliseconds(since start: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(start) * 1000).rounded()))
    }

    /// Host of the exact endpoint the transport will contact. For the ChatGPT plan transport
    /// this is the fixed `api.openai.com/v1/responses` endpoint, because the plan record was
    /// converted before it reached this hook.
    private static func host(plan: AiPlanRecord) -> String {
        URL(string: plan.endpoint)?.host ?? plan.host
    }
}

/// One part of a previewed plan, reduced to counts and page numbers at attempt start.
struct AIAuditPart {
    let index: Int
    let characters: Int
    let pages: [Int]
    let image: AIAuditImage?
}

/// The in-flight half of one attempt. One record is written per part that actually starts:
/// a plan with several parts is several outgoing requests, and the audit must not turn them into
/// one line. `markPartStarted` closes the previous part as sent (the transport only moves on
/// after it succeeded); the terminal event closes the current part with its real outcome.
@MainActor
final class AIAuditAttempt {
    private let trail: AIAuditTrail
    private let kind: AIAuditAction
    private let host: String
    private let model: String
    private let parts: [AIAuditPart]
    private let startedAt: Date
    private var currentPart: (index: Int, startedAt: Date)?
    private var recordedParts: Set<Int> = []
    private var startedAnyPart = false
    private var refusalRecorded = false
    private var finished = false

    init(trail: AIAuditTrail, kind: AIAuditAction, host: String, model: String,
         parts: [AIAuditPart], startedAt: Date) {
        self.trail = trail
        self.kind = kind
        self.host = host
        self.model = model
        self.parts = parts
        self.startedAt = startedAt
    }

    func markPartStarted(_ index: Int) {
        guard !finished, currentPart?.index != index else { return }
        if let previous = currentPart {
            // The transport started a later part, so the previous part completed. Its own
            // duration ends here, not at the end of the whole plan.
            record(part: previous.index, outcome: .sent, code: nil, startedAt: previous.startedAt)
        }
        currentPart = (index, Date())
        startedAnyPart = true
    }

    func finish(_ outcome: AIAuditOutcome, code: AIAuditCode?) {
        guard !finished else { return }
        finished = true
        if let currentPart {
            record(part: currentPart.index, outcome: outcome, code: code,
                   startedAt: currentPart.startedAt)
            self.currentPart = nil
            return
        }
        // No part started: this is a refusal before sending (or a transport that stopped before
        // its first part). One zero-count record documents the attempt without inventing pages.
        guard !startedAnyPart, !refusalRecorded else { return }
        refusalRecorded = true
        trail.append(AIAuditRecord(
            at: startedAt,
            action: kind,
            host: host,
            model: model,
            characters: 0,
            pages: [],
            image: nil,
            outcome: outcome,
            code: code,
            durationMilliseconds: max(0, Int((Date().timeIntervalSince(startedAt) * 1000).rounded()))
        ))
    }

    private func record(part index: Int, outcome: AIAuditOutcome, code: AIAuditCode?,
                        startedAt: Date) {
        guard !recordedParts.contains(index),
              let part = parts.first(where: { $0.index == index })
        else { return }
        recordedParts.insert(index)
        trail.append(AIAuditRecord(
            at: startedAt,
            action: kind,
            host: host,
            model: model,
            characters: part.characters,
            pages: Array(Set(part.pages)).sorted(),
            image: part.image,
            outcome: outcome,
            code: code,
            durationMilliseconds: max(0, Int((Date().timeIntervalSince(startedAt) * 1000).rounded()))
        ))
    }
}

/// The one start site for audited AI transports.
///
/// Both the assistant panel and the in-place translator build their transport inside the
/// closure; this function appends the attempt before the transport exists, wraps the handle, and
/// turns a start failure into a `refused` record. There is deliberately no second audit path.
@MainActor
enum AIAuditedRequestStart {
    static func start(
        plan: AiPlanRecord,
        kind: AIAuditAction,
        audit: AIAuditTrail,
        makeHandle: () throws -> any AIChatHandle
    ) throws -> any AIChatHandle {
        let attempt = audit.begin(plan: plan, kind: kind)
        do {
            return AIAuditedChatHandle(base: try makeHandle(), attempt: attempt)
        } catch {
            attempt.finish(.refused, code: AIAuditCode.classifyStartFailure(error))
            throw error
        }
    }
}

/// Wraps the transport handle so every AI request — API-key, ChatGPT plan, or one unit of a
/// layered-summary batch — inherits the same audit hook. A handle is created only after a
/// previewed plan is approved; it observes the same terminal events the panel does.
@MainActor
final class AIAuditedChatHandle: AIChatHandle {
    private let base: any AIChatHandle
    private let attempt: AIAuditAttempt
    private var recorded = false

    init(base: any AIChatHandle, attempt: AIAuditAttempt) {
        self.base = base
        self.attempt = attempt
    }

    func poll() -> [AIStreamEvent] {
        let events = base.poll()
        for event in events {
            switch event {
            case .partStarted(let index, _, _):
                attempt.markPartStarted(Int(index))
            case .done:
                record(.sent, code: nil)
            case .error(let message, let cancelled):
                if cancelled {
                    record(.cancelled, code: nil)
                } else {
                    record(.failed, code: AIAuditCode.classifyStreamFailure(message: message))
                }
            default:
                break
            }
        }
        // A transport that stops without a terminal event is a failure, not a silent success.
        if base.isFinished && !recorded {
            record(.failed, code: .providerError)
        }
        return events
    }

    func cancel() {
        base.cancel()
        record(.cancelled, code: nil)
    }

    var isFinished: Bool { base.isFinished }

    private func record(_ outcome: AIAuditOutcome, code: AIAuditCode?) {
        guard !recorded else { return }
        recorded = true
        attempt.finish(outcome, code: code)
    }
}

// MARK: - Panel copy

/// The reader-facing audit section and what-is-sent inventory. Kept as constants so the checks
/// can assert the inventory against the prompts the builders actually produce.
public enum AIAuditPanelCopy {
    public static let sectionTitle = "Local audit trail"
    public static let note = """
    Stored only on this Mac, in the application cache. Each entry records one outgoing request: \
    when, the action, endpoint host, model, characters sent, pages, image size, outcome and \
    duration. It never records document text, questions, answers, file paths, document names, \
    or image bytes. Nothing in this trail is uploaded or reported anywhere.
    """
    public static let bounds = "Newest \(AIAuditTrail.maximumRecords) entries or \(AIAuditTrail.maximumKilobytes) KiB are kept; older entries are dropped."
    public static let empty = "No requests recorded yet."
    public static let clearButton = "Clear Audit Trail…"
    public static let clearConfirmationTitle = "Clear the local audit trail?"
    public static let clearConfirmationMessage = "This permanently deletes every audit entry on this Mac. It cannot be undone, and nothing is sent anywhere."
    public static let whatIsSentTitle = "What AI requests send"
    /// Derived from `chat.rs` prompt builders and the two transports (see the checks). Every line
    /// here is asserted against a real preview, not aspirational copy.
    public static let whatIsSent: [String] = [
        "Selected text. A selection question also carries the current page's text and related passages; a selection summary or translation carries only the selection.",
        "Page text: the current page for a page summary (plus related passages), every page for a whole-document summary, up to six retrieved passages for document chat, and the selected region's text for a region question.",
        "The layered summary's abstract sample, section text and page text, one bounded request per entry.",
        "The part summaries you already saw, when you send the consolidation request.",
        "The selected region's picture, when image input is on (both connections carry the same capture).",
        "Your question, and for document chat the last six question/answer turns.",
        "The document's display name (the file name without its path) in the prompts that name the document.",
        "The instruction prompts, the model name and the generation settings.",
    ]
    public static let neverSentTitle = "What AI requests never send"
    public static let neverSent: [String] = [
        "The PDF file itself, its embedded files or its attachments.",
        "The file path or folder name.",
        "Annotations, notes, highlights, bookmarks or ink.",
        "Reading history, recent documents, or any document you did not ask about.",
        "A region picture when image input is off.",
        "Any further bytes after you cancel.",
    ]
    public static let wholeDocumentNote = "A whole-document summary does send the extracted text of every page, split across requests. The PDF file is never uploaded."
}
