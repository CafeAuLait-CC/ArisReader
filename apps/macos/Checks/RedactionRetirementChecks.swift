import AppKit
import Foundation
import LyraReaderKit

extension ReaderChecks {
    /// T3.12's retirement: redaction exists only in the Edit workspace.
    ///
    /// The reading view used to carry a second redaction implementation (mark rectangles as
    /// annotations, then apply them). This check pins the removal at the level a user or a
    /// maintainer can observe:
    ///
    /// * no canvas tool and no annotation-toolbar button;
    /// * no menu item, command handler or keyboard shortcut in the app's menu source, while the
    ///   Edit workspace's `Redact…` entry is present and keeps one R chord;
    /// * no page context-menu item (see `desktopInteractionChecks`, which builds a real menu with
    ///   a selection);
    /// * no production Swift source or FFI entry point names a removed symbol. The compiler
    ///   proves the enum case and the FFI methods are gone; scanning the sources keeps the
    ///   user-facing surface checkable even where a command is only a string label.
    ///
    /// It also proves the replacement is real: the menu entry opens Edit with Blackout armed.
    @MainActor static func redactionRetirementChecks(root: URL) async throws {
        // ── No canvas tool, no annotation-toolbar button ──────────────────────────────
        require(!AnnotationTool.allCases.contains(where: { $0.rawValue == "redact" }),
                "AnnotationTool has no redaction case")
        require(!AnnotationToolbarLayout.annotationToolIDs.contains(where: {
                    $0.caseInsensitiveCompare("Redact") == .orderedSame
                }), "the annotation row has no redaction button")
        require(AnnotationToolbarLayout.contentEditItemIDs.contains("Redact"),
                "the Edit row keeps its Redact tool")

        // ── No menu item and no shortcut; the Edit entry replaces them ───────────────
        let appMenuURL = root.appendingPathComponent(
            "apps/macos/Sources/LyraReader/LyraReaderApp.swift")
        let appMenu = try String(contentsOf: appMenuURL, encoding: .utf8)
        let retiredMenuCommands = [
            "CommandMenu(\"Redaction\")",
            "Button(\"Redact Tool\")",
            "Button(\"Mark Selection for Redaction\")",
            "Button(\"Remove Last Mark\")",
            "Button(\"Apply to Copy…\")",
            "Button(\"Replace Original…\")",
            "Button(\"Clear Pending Redactions\")",
            "toggleRedactionTool",
            "markSelectionForRedaction",
            "presentApplyRedactionsPanel",
            "presentReplaceRedactionsConfirmation",
        ]
        for command in retiredMenuCommands {
            require(!appMenu.contains(command),
                    "the app menu no longer contains the annotation-redaction command \(command)")
        }
        require(appMenu.contains("Button(\"Redact…\")"),
                "the app menu offers the Edit workspace's Redact… entry")
        require(appMenu.contains("openRedactionWorkspace()"),
                "Redact… opens the Edit workspace instead of arming a reading-view mark")
        require(!appMenu.contains(".keyboardShortcut(\"r\""),
                "neither retired R shortcut was rebound to another command")
        require(appMenu.contains(".keyboardShortcut("),
                "the app menu still declares its other shortcuts")

        // ── No production source names a removed annotation-path symbol ──────────────
        let sources = root.appendingPathComponent("apps/macos/Sources")
        guard let enumerator = FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil) else {
            fatalError("FAIL: could not enumerate \(sources.path)")
        }
        var swiftFiles: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "swift" { swiftFiles.append(url) }
        }
        require(!swiftFiles.isEmpty, "the production Swift sources are readable")
        let retiredSymbols = [
            "toggleRedactionTool", "canMarkRedactions", "canApplyRedactions",
            "canReplaceOriginalWithRedactions", "pendingRedactions", "pendingRedactionMarks",
            "pendingRedactionAreas", "addPendingRedaction", "markSelectionForRedaction",
            "presentApplyRedactionsPanel", "presentReplaceRedactionsConfirmation",
            "redactToCopy", "replaceWithRedactions", "previewRedactions",
            "suggestedRedactionCopyURL", "CanvasRedactionMark", "onRedactionDraft",
            "redactionMarks", "updateRedactions",
        ]
        var offenders: [String] = []
        for file in swiftFiles {
            let text = try String(contentsOf: file, encoding: .utf8)
            for symbol in retiredSymbols where text.contains(symbol) {
                offenders.append("\(file.lastPathComponent): \(symbol)")
            }
        }
        require(offenders.isEmpty,
                "no production Swift source names a removed annotation-path symbol"
                    + (offenders.isEmpty ? "" : " (found: \(offenders.prefix(5).joined(separator: ", ")))"))

        // ── The FFI entry points that existed only for the annotation path are gone ──
        let ffiAPI = try String(
            contentsOf: root.appendingPathComponent("crates/lyra-reader-ffi/src/api.rs"),
            encoding: .utf8)
        for entryPoint in [
            "redact_to_copy", "replace_with_redactions", "preview_redactions",
            "suggested_redaction_copy_path", "RedactionAreaRecord", "RedactionReportRecord",
            "RedactionPreviewRecord",
        ] {
            require(!ffiAPI.contains(entryPoint),
                    "the FFI no longer exposes the annotation-path entry point \(entryPoint)")
        }

        // The CLI redaction command is a separate user-facing path and stays alive.
        let cli = try String(
            contentsOf: root.appendingPathComponent("crates/lyra-reader-cli/src/main.rs"),
            encoding: .utf8)
        require(cli.contains("Some(\"redact\")"),
                "the CLI redact subcommand is still dispatched (not dead after the FFI removal)")

        // ── The replacement flow is real: Redact… arms Blackout in Edit ──────────────
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 1000, height: 800))
        state.newTab(url: root.appendingPathComponent("tests/fixtures/text-page.pdf"))
        try await eventually("the retirement fixture opens", { state.document != nil })
        require(state.canOpenRedactionWorkspace,
                "the Edit redaction entry is offered for an ordinary document")
        state.openRedactionWorkspace()
        require(state.contentEditEnabled,
                "Redact… opens the Edit workspace")
        require(state.contentEditTool == "blackout",
                "Redact… arms the Blackout tool, not a reading-view mark mode")
        require(state.annotationTool == .select,
                "opening Edit leaves no annotation tool armed")

        print("Redaction retirement checks passed")
    }
}
