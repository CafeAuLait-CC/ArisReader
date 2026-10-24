import AppKit
import Foundation

/// One command in the Export sub-toolbar row, as data.
///
/// #153 carried these in a toolbar menu. They are now items in a row, in this order, and the
/// checks assert the same list the row lays out. Nothing opens a nested menu: each item is the
/// command itself, and its options live in the save/print panel it opens.
public struct ExportCommand: Identifiable, Equatable, Sendable {
    public enum Action: String, CaseIterable, Sendable {
        case save
        case saveAs
        case saveAnnotatedCopy
        case exportFlattenedCopy
        case saveFilledFormCopy
        case writeFormValuesToOriginal
        case exportAnnotations
        case print
    }

    public let action: Action
    /// The row label: short enough for eight items in one 46 pt row.
    public let title: String
    /// The command's full name, used by the accessibility label and the menu-bar wording.
    public let fullTitle: String
    public let icon: String
    public let help: String

    public var id: String { action.rawValue }

    public init(action: Action, title: String, fullTitle: String, icon: String, help: String) {
        self.action = action
        self.title = title
        self.fullTitle = fullTitle
        self.icon = icon
        self.help = help
    }

    /// The eight commands, left to right: save first, print last, with the copy/export forms
    /// between them exactly where the old Export menu had them.
    public static let all: [ExportCommand] = [
        ExportCommand(action: .save, title: "Save", fullTitle: "Save",
                      icon: "square.and.arrow.down",
                      help: "Save the document (⌘S)"),
        ExportCommand(action: .saveAs, title: "Save As…", fullTitle: "Save As…",
                      icon: "doc.on.doc",
                      help: "Save a copy at a new location (⇧⌘S)"),
        ExportCommand(action: .saveAnnotatedCopy, title: "Annotated…",
                      fullTitle: "Save Annotated Copy…", icon: "highlighter",
                      help: "Write every annotation and bookmark into a new PDF; the original is unchanged"),
        ExportCommand(action: .exportFlattenedCopy, title: "Flattened…",
                      fullTitle: "Export as Flattened Copy…", icon: "rectangle.stack",
                      help: "Write a new PDF with annotations and filled form values painted into the page. Not tamper-proof."),
        ExportCommand(action: .saveFilledFormCopy, title: "Filled Form…",
                      fullTitle: "Save Filled Form Copy…", icon: "signature",
                      help: "Write the values in the reader into a copy; the original is unchanged"),
        ExportCommand(action: .writeFormValuesToOriginal, title: "Form Values…",
                      fullTitle: "Write Form Values to Original…",
                      icon: "doc.badge.arrow.up",
                      help: "Write the filled values into the original file, with a verified backup first"),
        ExportCommand(action: .exportAnnotations, title: "Annotations…",
                      fullTitle: "Export Annotations…", icon: "text.badge.plus",
                      help: "Export the annotation text as Markdown or CSV (⌘E)"),
        ExportCommand(action: .print, title: "Print…", fullTitle: "Print…", icon: "printer",
                      help: "Print the document (⌘P)"),
    ]

    /// Whether this command can run for the open document.
    @MainActor
    public func isEnabled(_ state: AppState) -> Bool {
        switch action {
        case .save, .saveAs:
            return state.canSaveDocument
        case .saveAnnotatedCopy:
            return state.document != nil && !state.annotationSaveInProgress
        case .exportFlattenedCopy:
            return state.canFlattenDocument
        case .saveFilledFormCopy:
            return state.canSaveFilledForm
        case .writeFormValuesToOriginal:
            return state.canReplaceOriginalWithFilledForm
        case .exportAnnotations:
            return state.canExportAnnotations
        case .print:
            return state.document != nil
        }
    }

    /// The command's help, with the reason it is disabled when there is one.
    @MainActor
    public func helpText(_ state: AppState) -> String {
        switch action {
        case .saveAnnotatedCopy:
            return help
        case .exportFlattenedCopy:
            return state.flattenRefusal ?? help
        case .saveFilledFormCopy, .writeFormValuesToOriginal:
            return state.isReadOnlyDocument
                ? (state.readOnlyReason ?? state.readOnlyBannerTitle) : help
        default:
            return help
        }
    }

    /// Runs the command. The panels belong to `AppState`, so the row and the menu bar cannot
    /// drift into two implementations.
    @MainActor
    public func perform(on state: AppState) {
        switch action {
        case .save: state.saveDocument()
        case .saveAs: state.presentSaveDocumentCopyPanel()
        case .saveAnnotatedCopy: state.presentSaveAnnotatedCopyPanel()
        case .exportFlattenedCopy: state.presentFlattenCopyPanel()
        case .saveFilledFormCopy: state.presentSaveFilledFormPanel()
        case .writeFormValuesToOriginal:
            state.presentReplaceOriginalWithFilledFormConfirmation()
        case .exportAnnotations: state.presentExportAnnotationsPanel()
        case .print: state.printDocument()
        }
    }
}

/// Page operations that used to live in the toolbar's Organise pages menu.
///
/// The app already had every one of them in the system menu bar's Pages menu. This model also
/// feeds an Edit > Page Operations submenu, so the commands have a second, discoverable home
/// next to the other editing commands and removing the toolbar menu loses nothing.
public struct PageOperationCommand: Identifiable, Equatable, Sendable {
    public enum Action: String, CaseIterable, Sendable {
        case rotateClockwise
        case rotateAnticlockwise
        case insertBlankPageAfter
        case extractSelectedPages
        case appendPagesFromPDFs
        case splitPages
    }

    public let action: Action
    public let title: String
    public let help: String

    public var id: String { action.rawValue }

    public init(action: Action, title: String, help: String) {
        self.action = action
        self.title = title
        self.help = help
    }

    /// The six commands #153's toolbar menu carried, in the same order.
    public static let all: [PageOperationCommand] = [
        PageOperationCommand(action: .rotateClockwise, title: "Rotate Clockwise",
                             help: "Rotate the selected pages a quarter turn clockwise"),
        PageOperationCommand(action: .rotateAnticlockwise, title: "Rotate Anticlockwise",
                             help: "Rotate the selected pages a quarter turn anticlockwise"),
        PageOperationCommand(action: .insertBlankPageAfter, title: "Insert Blank Page After",
                             help: "Insert a blank page after the current page"),
        PageOperationCommand(action: .extractSelectedPages, title: "Extract Selected Pages…",
                             help: "Write the selected pages to a new PDF"),
        PageOperationCommand(action: .appendPagesFromPDFs, title: "Append Pages from PDFs…",
                             help: "Append pages from other PDFs to a new copy"),
        PageOperationCommand(action: .splitPages, title: "Split Pages…",
                             help: "Split the document into several PDFs"),
    ]

    @MainActor
    public func isEnabled(_ state: AppState) -> Bool {
        switch action {
        case .rotateClockwise, .rotateAnticlockwise, .insertBlankPageAfter:
            return state.canPageEdit
        case .extractSelectedPages, .appendPagesFromPDFs, .splitPages:
            return state.canPageOperations
        }
    }

    @MainActor
    public func helpText(_ state: AppState) -> String {
        guard !isEnabled(state) else { return help }
        return state.readOnlyReason.map { "\(help) · \($0)" } ?? help
    }

    @MainActor
    public func perform(on state: AppState) {
        switch action {
        case .rotateClockwise: state.rotateSelectedPages(clockwise: true)
        case .rotateAnticlockwise: state.rotateSelectedPages(clockwise: false)
        case .insertBlankPageAfter: state.insertBlankPage(before: false)
        case .extractSelectedPages: state.presentExtractPagesPanel()
        case .appendPagesFromPDFs: state.presentMergeDocumentsPanel()
        case .splitPages: state.presentSplitPagesPanel()
        }
    }
}

/// The names the app menu bar uses for the page-operations home.
public enum PageOperationsMenu {
    public static let title = "Page Operations"
    public static let commands = PageOperationCommand.all
}
