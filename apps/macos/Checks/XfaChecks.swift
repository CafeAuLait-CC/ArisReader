import AppKit
import Foundation
import LyraReaderKit

/// Read-only XFA support against the real sample.
///
/// The form is the user's `~/Downloads/xml_form.pdf`; it is copied to a scratch directory and
/// never written in place. When the sample is absent the checks print SKIP and return: it is
/// not a repository fixture and must not be committed.
///
/// What is asserted:
/// * structural detection (not "the page is blank"), five rendered pages, source encryption;
/// * text from the template and a value resolved from the dataset's LOV table (Canada);
/// * the read-only policy in the engine and in `AppState` (annotation, form, page-edit,
///   content-edit, redaction, save and copy commands are all unavailable);
/// * an ordinary PDF is unchanged and is not treated as XFA;
/// * an empty-user-password XFA opens without a prompt, while a genuinely password-protected
///   PDF still refuses.
extension ReaderChecks {
    @MainActor static func xfaChecks(root: URL) async throws {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let sample = home.appendingPathComponent("Downloads/xml_form.pdf")
        guard fileManager.fileExists(atPath: sample.path) else {
            print("SKIP: ~/Downloads/xml_form.pdf is not present; XFA checks need the local sample")
            return
        }
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-reader-xfa-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let copied = scratch.appendingPathComponent("xml_form.pdf")
        try fileManager.copyItem(at: sample, to: copied)
        let sourceBytes = try Data(contentsOf: sample)
        let copiedBytes = try Data(contentsOf: copied)
        require(sourceBytes == copiedBytes, "the sample was copied byte-for-byte and is never modified")

        // ── Engine detection, rendering and text ────────────────────────────────────────
        let engine = try RustEngine()
        let loaded = try engine.openDocument(at: copied)
        require(loaded.pageCount == 5, "the XFA form renders the five pages of the reference")
        let xfa = loaded.xfa
        require(xfa.isXfa, "the document is detected as XFA from /AcroForm /XFA")
        require(xfa.rendered, "the synthetic PDF was produced")
        require(xfa.pageCount == 5, "the status reports the rendered page count")
        require(xfa.packetNames.count == 10, "the /XFA array carries ten entries")
        require(xfa.packetNames.contains("template") && xfa.packetNames.contains("datasets"),
                "the structural read exposes the template and datasets packets")
        require(xfa.encrypted, "the permission-encrypted source is reported encrypted")
        require(xfa.fieldCount > 250, "the template field count is reported (got \(xfa.fieldCount))")
        require(!xfa.skipped.isEmpty, "the honest fallback list is populated")
        let reason = xfa.readOnlyReason ?? ""
        require(reason.contains("XFA form") && reason.contains("read-only"),
                "the read-only reason names the XFA rendering: \(reason)")

        let text = try await engine.textPage(0).text
        require(text.contains("APPLICATION TO CHANGE CONDITIONS"),
                "page one carries the template title")
        require(text.contains("PAGE 1 OF 5"), "the synthetic page numbers are printed")
        require(text.contains("Canada"),
                "page one carries Canada, resolved through the dataset's LOV code 511")

        let form = try await engine.formInfo()
        require(form.fields.isEmpty, "an XFA form offers no fillable fields")
        require(form.refusal?.contains("XFA") == true,
                "the form info explains why filling is unavailable: \(form.refusal ?? "nil")")
        let annotations = try await engine.annotations()
        require(annotations.isEmpty,
                "annotation reading is empty for the synthetic document")
        let info = try await engine.documentInfo()
        require(info.pageCount == 5, "document info reports the rendered pages")
        require(info.isEncrypted, "document info reports the source encryption")

        // ── Every write path refuses with the shared sentence ───────────────────────────
        let destination = scratch.appendingPathComponent("out.pdf")
        var refused = false
        do {
            _ = try await engine.extractPages([0], to: destination)
        } catch {
            refused = true
            require(String(describing: error).localizedCaseInsensitiveContains("XFA"),
                    "extractPages refused with the XFA reason: \(error)")
        }
        require(refused, "extractPages is refused for an XFA document")
        let afterWrites = try Data(contentsOf: copied)
        require(afterWrites == sourceBytes,
                "the source file is byte-identical after every refused write")

        // ── The shell's read-only state ─────────────────────────────────────────────────
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 900, height: 650))
        state.newTab(url: copied)
        try await eventually("the XFA document opens in the shell", {
            state.document?.pageCount == 5 && state.documentXfa.isXfa
        })
        require(state.isXfaDocument && state.isReadOnlyDocument,
                "the shell marks the XFA document read-only")
        require(state.readOnlyBannerTitle.contains("XFA form"),
                "the banner says this is an XFA form rendered from XML")
        require(state.readOnlyReason?.contains("XFA") == true,
                "the banner's reason is the XFA one")
        require(state.statusMessage.contains("XFA"),
                "the status line says the page count and skips: \(state.statusMessage)")
        require(!state.canEditAnnotations,
                "annotation tools are not offered for an XFA form")
        require(!state.canPageEdit && !state.canPageOperations,
                "page editing and page operations are not offered")
        require(!state.canUseFormTool, "the Fill & Sign tool is not offered")
        require(!state.canSaveDocument, "Save/Save As are disabled (no copy of edits)")
        require(!state.canSaveFilledForm && !state.canSaveDocumentProperties,
                "form and properties copies are disabled")
        require(!state.canMarkRedactions, "the redaction tool is not offered")
        try await eventually("the form info finishes loading", {
            state.formLoadCompleted && !state.formLoading
        })
        require(state.formInfo.fields.isEmpty,
                "the shell's form model has no fields to fill")
        require(state.formInfo.refusal?.contains("XFA") == true,
                "the form model carries the read-only explanation")
        state.loadDocumentInfo(force: true)
        try await eventually("the information panel sees five pages", {
            state.documentInfo?.pageCount == 5
        })
        require(state.documentInfo?.isEncrypted == true,
                "the information panel reports the permission encryption")

        // ── An ordinary PDF is not touched by the feature ──────────────────────────────
        let ordinaryURL = root.appendingPathComponent("tests/fixtures/text-page.pdf")
        let ordinary = try engine.openDocument(at: ordinaryURL)
        require(!ordinary.xfa.isXfa, "an ordinary PDF is not XFA")
        require(ordinary.xfa.readOnlyReason == nil,
                "an ordinary PDF has no XFA read-only reason")
        require(ordinary.pageCount == 1, "the ordinary PDF's page count is unchanged")
        let ordinaryForm = try await engine.formInfo()
        require(!ordinaryForm.encrypted && ordinaryForm.refusal == nil,
                "an ordinary PDF is not refused a form by the XFA path")
        let ordinaryText = try await engine.textPage(0).text
        require(!ordinaryText.isEmpty, "the ordinary PDF's text layer is unchanged")
        let ordinaryState = AppState(engine: try RustEngine())
        ordinaryState.setViewportSize(CGSize(width: 900, height: 650))
        ordinaryState.newTab(url: ordinaryURL)
        try await eventually("the ordinary PDF opens in the shell", {
            ordinaryState.document != nil
        })
        require(!ordinaryState.isXfaDocument && !ordinaryState.isReadOnlyDocument,
                "an ordinary PDF is not made read-only")
        require(ordinaryState.canEditAnnotations,
                "annotation tools remain available for an ordinary PDF")

        // ── Password-protected PDF still refuses; empty-password XFA does not prompt ──
        require(info.isEncrypted,
                "the encrypted XFA opened with no password prompt")
        let protected = scratch.appendingPathComponent("protected.pdf")
        let ghostscript = try? runGhostscriptEncrypt(
            source: ordinaryURL, destination: protected)
        if ghostscript == true {
            do {
                _ = try engine.openDocument(at: protected)
                require(false, "a genuinely password-protected PDF must not open without a password")
            } catch {
                require(String(describing: error).localizedCaseInsensitiveContains("password"),
                        "the password-protected refusal names the password: \(error)")
            }
        } else {
            print("SKIP: Ghostscript is not available, so the password-protected refusal was not exercised")
        }

        state.closeTab(0)
        ordinaryState.closeTab(0)
        print("PASS: XFA read-only checks completed for \(copied.lastPathComponent)")
    }

    /// Creates a genuinely user-password-protected PDF for the refusal check. Returns nil when
    /// Ghostscript is unavailable; the caller skips rather than fails.
    @MainActor
    private static func runGhostscriptEncrypt(source: URL, destination: URL) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "gs", "-q", "-dBATCH", "-dNOPAUSE", "-sDEVICE=pdfwrite",
            "-dEncryptionR=3", "-dKeyLength=128", "-dPermissions=-4",
            "-sOwnerPassword=owner-secret", "-sUserPassword=user-secret",
            "-sOutputFile=\(destination.path)", source.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
            && FileManager.default.fileExists(atPath: destination.path)
    }
}
