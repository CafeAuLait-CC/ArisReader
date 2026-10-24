import AppKit
import Foundation

// MARK: - Page canvas context menu

/// One command a right-click on the page offers.
///
/// The cases name **existing** commands, not new behaviour: what the menu adds is a way to reach
/// them where the reader's pointer already is. ``CanvasContextMenu/perform(_:state:at:note:)``
/// is the only place that turns a case into an `AppState` call, so a menu item cannot drift into
/// a second implementation of copying, highlighting or page rotation.
public enum CanvasContextMenuAction: Equatable, Sendable {
    case copySelection
    case highlightSelection
    case addNoteToSelection
    case translateSelection
    case openLink
    case rotatePage(Int, clockwise: Bool)
    case extractPage(Int)
}

/// A title and a command, decided before the menu is shown.
///
/// The app builds a command list from these; the checks read the same list, which is how "no
/// selection means no copy item" is asserted without putting a window on the reader's screen.
public struct CanvasContextMenuItem: Equatable, Sendable {
    public let title: String
    public let action: CanvasContextMenuAction
    /// Always `true` for an item that is present: see ``CanvasContextMenu/sections(state:at:)``
    /// — an item whose precondition fails is omitted, not shown dead. The property exists because
    /// a menu is the wrong place to discover a disabled item with no explanation.
    public let isEnabled: Bool
}

/// The page canvas' right-click menu, built from the reader's state and the right-click point.
///
/// Grouping is the reader's mental model, top to bottom: what the menu can do to the text under
/// the pointer, then where the link goes, then what it can do to the page. Empty groups are not
/// emitted, so a right-click on the margin of a document with no selection offers the page
/// operations alone, and a right-click in the gap between pages offers nothing (the caller then
/// leaves AppKit's default menu alone).
public enum CanvasContextMenu {
    /// The menu's sections, in display order. Each section becomes one command group.
    @MainActor
    public static func sections(state: AppState, at point: CGPoint) -> [[CanvasContextMenuItem]] {
        var sections: [[CanvasContextMenuItem]] = []

        // Text range. Every one of these calls a command that already exists: copySelection,
        // addAnnotationFromSelection and addNoteFromSelection. The note one is last because it
        // asks for text before it writes anything.
        if state.selection != nil {
            sections.append([
                CanvasContextMenuItem(
                    title: "Copy Selection", action: .copySelection, isEnabled: true),
                CanvasContextMenuItem(
                    title: "Highlight Selection", action: .highlightSelection, isEnabled: true),
                CanvasContextMenuItem(
                    title: "Add Note to Selection…", action: .addNoteToSelection, isEnabled: true),
                CanvasContextMenuItem(
                    title: state.translationSelectionTitle,
                    action: .translateSelection,
                    isEnabled: true),
            ])
        }

        // A link is only offered where there is one. `link(at:)` answers from the same link cache
        // a click uses, so the item cannot disagree with what the click would do.
        if state.link(at: point) != nil {
            sections.append([
                CanvasContextMenuItem(title: "Open Link", action: .openLink, isEnabled: true),
            ])
        }

        // Page-level commands. The page is the one under the pointer, not the current page: a
        // right-click is a statement about where the reader is pointing.
        if let page = state.pageIndex(at: point) {
            var pageItems: [CanvasContextMenuItem] = []
            if state.canPageEdit {
                pageItems.append(CanvasContextMenuItem(
                    title: "Rotate Page 90° Clockwise",
                    action: .rotatePage(page, clockwise: true),
                    isEnabled: true
                ))
                pageItems.append(CanvasContextMenuItem(
                    title: "Rotate Page 90° Anticlockwise",
                    action: .rotatePage(page, clockwise: false),
                    isEnabled: true
                ))
            }
            if state.document != nil {
                pageItems.append(CanvasContextMenuItem(
                    title: "Extract Page…",
                    action: .extractPage(page),
                    isEnabled: true
                ))
            }
            if !pageItems.isEmpty { sections.append(pageItems) }
        }

        return sections
    }

    /// The flat list, in display order, with group boundaries dropped. The checks read this.
    @MainActor
    public static func items(state: AppState, at point: CGPoint) -> [CanvasContextMenuItem] {
        sections(state: state, at: point).flatMap { $0 }
    }

    /// Runs one item through the command it names.
    ///
    /// Returns whether the command was handed the action; the page-edit commands stage their
    /// work asynchronously and report through `AppState.lastError`/`pageEditPendingSummary`, just
    /// as the Pages menu does. A note item needs its text from the caller (a modal prompt in the
    /// app), so `note` is required for exactly that case and ignored otherwise.
    @MainActor
    @discardableResult
    public static func perform(
        _ action: CanvasContextMenuAction,
        state: AppState,
        at point: CGPoint,
        note: String? = nil
    ) -> Bool {
        switch action {
        case .copySelection:
            guard state.selection != nil else { return false }
            state.copySelection()
            return true
        case .highlightSelection:
            guard state.selection != nil else { return false }
            return state.addAnnotationFromSelection(kind: .highlight)
        case .addNoteToSelection:
            guard state.selection != nil, let note else { return false }
            return state.addNoteFromSelection(note: note)
        case .translateSelection:
            guard state.selection != nil else { return false }
            return state.performTranslationAction()
        case .openLink:
            guard state.link(at: point) != nil else { return false }
            return state.followLink(at: point)
        case .rotatePage(let page, let clockwise):
            guard state.canPageEdit, state.document != nil else { return false }
            // Selecting the page first is the same step the thumbnail menu takes: the page
            // commands act on the page selection, and the reader's right-click names one page.
            state.selectPage(page, extending: false, toggling: false)
            state.rotateSelectedPages(clockwise: clockwise)
            return true
        case .extractPage(let page):
            guard state.document != nil else { return false }
            state.selectPage(page, extending: false, toggling: false)
            state.presentExtractPagesPanel()
            return true
        }
    }

    /// Builds the AppKit-backed command list rendered by the LyraReader menu panel, or `nil` when
    /// there is nothing to offer. AppKit does not present this as a system menu.
    ///
    /// Nothing to offer is a real answer: a right-click in the gap between two pages should not
    /// pop an empty menu. Notes begin an inline editing session; the other commands run through
    /// ``perform(_:state:at:note:)``.
    @MainActor
    public static func menu(
        state: AppState,
        at point: CGPoint
    ) -> NSMenu? {
        let sections = sections(state: state, at: point)
        guard !sections.isEmpty else { return nil }

        let menu = NSMenu()
        // The item list already decided what is available; AppKit must not enable an item the
        // reader cannot use (or disable one it can) behind our back.
        menu.autoenablesItems = false

        for (sectionIndex, section) in sections.enumerated() {
            if sectionIndex > 0 { menu.addItem(.separator()) }
            for item in section {
                let handler = ContextMenuHandler { [weak state] in
                    guard let state else { return }
                    if item.action == .addNoteToSelection {
                        state.beginNoteFromSelection()
                    } else {
                        _ = perform(item.action, state: state, at: point)
                    }
                }
                let menuItem = NSMenuItem(
                    title: item.title,
                    action: #selector(ContextMenuHandler.invoke),
                    keyEquivalent: ""
                )
                menuItem.target = handler
                // NSMenuItem's target is not retained; the handler travels with the item.
                menuItem.representedObject = handler
                menuItem.isEnabled = item.isEnabled
                let icon: String
                switch item.action {
                case .copySelection: icon = "doc.on.doc"
                case .highlightSelection: icon = "highlighter"
                case .addNoteToSelection: icon = "text.bubble"
                case .translateSelection: icon = "character.bubble"
                case .openLink: icon = "link"
                case .rotatePage(_, let clockwise): icon = clockwise ? "rotate.right" : "rotate.left"
                case .extractPage: icon = "square.and.arrow.up"
                }
                menuItem.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
                if item.action == .copySelection { menuItem.keyEquivalent = "c" }
                menu.addItem(menuItem)
            }
        }
        return menu
    }
}

/// Retains the closure behind one `NSMenuItem` for as long as the item lives.
@MainActor
private final class ContextMenuHandler: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func invoke() {
        handler()
    }
}

// MARK: - Thumbnail context menu

/// One command a right-click on a sidebar thumbnail offers.
///
/// Same rule as the canvas menu: the cases are existing commands. "Open in current window" is
/// ``AppState/gotoPage(_:)``, and "Open in new window" is the window registry's new-window path
/// (the same one a drop on the sidebar uses) — not a second loader.
public enum PageContextMenuAction: Equatable, Sendable {
    case openInCurrentWindow(Int)
    case openInNewWindow(Int)
    case selectPage(Int)
    case selectRangeTo(Int)
    case rotate(Int, clockwise: Bool)
    case resetRotation(Int)
    case insertBlankPage(Int, before: Bool)
    case deletePage(Int)
    case extractPage(Int)
}

public struct PageContextMenuItem: Equatable, Sendable {
    public let title: String
    public let action: PageContextMenuAction
    public let isEnabled: Bool
}

/// The thumbnail strip's right-click menu.
///
/// The page operations carry the same preconditions as the Pages menu
/// (`AppState.canPageEdit`, at least one page left to delete); an unavailable command is omitted
/// rather than shown dead. Selection commands stay available so the reader can build the page
/// selection the operations act on.
public enum PageContextMenu {
    @MainActor
    public static func sections(
        state: AppState,
        page: Int,
        canOpenNewWindow: Bool
    ) -> [[PageContextMenuItem]] {
        guard let document = state.document, page >= 0, page < document.pageCount else {
            return []
        }
        var sections: [[PageContextMenuItem]] = []

        var windowItems: [PageContextMenuItem] = [
            PageContextMenuItem(
                title: "Open in Current Window",
                action: .openInCurrentWindow(page),
                isEnabled: true
            ),
        ]
        if canOpenNewWindow {
            windowItems.append(PageContextMenuItem(
                title: "Open in New Window",
                action: .openInNewWindow(page),
                isEnabled: true
            ))
        }
        sections.append(windowItems)

        sections.append([
            PageContextMenuItem(
                title: "Select Page", action: .selectPage(page), isEnabled: true),
            PageContextMenuItem(
                title: "Select Range to Here", action: .selectRangeTo(page), isEnabled: true),
        ])

        var editItems: [PageContextMenuItem] = [
            PageContextMenuItem(
                title: "Rotate 90° Clockwise",
                action: .rotate(page, clockwise: true),
                isEnabled: state.canPageEdit
            ),
            PageContextMenuItem(
                title: "Rotate 90° Anticlockwise",
                action: .rotate(page, clockwise: false),
                isEnabled: state.canPageEdit
            ),
            PageContextMenuItem(
                title: "Reset Rotation to Original",
                action: .resetRotation(page),
                isEnabled: state.canPageEdit
            ),
            PageContextMenuItem(
                title: "Insert Blank Page Before",
                action: .insertBlankPage(page, before: true),
                isEnabled: state.canPageEdit
            ),
            PageContextMenuItem(
                title: "Insert Blank Page After",
                action: .insertBlankPage(page, before: false),
                isEnabled: state.canPageEdit
            ),
            PageContextMenuItem(
                title: "Delete Page…",
                action: .deletePage(page),
                // A PDF must keep one page; the command itself refuses the last one, and the
                // menu should not offer a refusal it already knows.
                isEnabled: state.canPageEdit && document.pageCount > 1
            ),
        ]
        editItems.append(PageContextMenuItem(
            title: "Extract This Page…",
            action: .extractPage(page),
            isEnabled: state.canPageEdit
        ))
        sections.append(editItems)
        return sections
    }

    /// Runs one item through the command it names. `newWindow` is the registry path, injected so
    /// this type never creates a window itself.
    @MainActor
    @discardableResult
    public static func perform(
        _ action: PageContextMenuAction,
        state: AppState,
        newWindow: (URL, Int) -> Bool
    ) -> Bool {
        switch action {
        case .openInCurrentWindow(let page):
            guard state.document != nil else { return false }
            state.selectPage(page, extending: false, toggling: false)
            state.gotoPage(page)
            return true
        case .openInNewWindow(let page):
            guard let url = state.document?.url else { return false }
            return newWindow(url, page)
        case .selectPage(let page):
            state.selectPage(page, extending: false, toggling: false)
            return true
        case .selectRangeTo(let page):
            state.selectPage(page, extending: true, toggling: false)
            return true
        case .rotate(let page, let clockwise):
            guard state.canPageEdit else { return false }
            state.selectPage(page, extending: false, toggling: false)
            state.rotateSelectedPages(clockwise: clockwise)
            return true
        case .resetRotation(let page):
            guard state.canPageEdit else { return false }
            state.selectPage(page, extending: false, toggling: false)
            state.resetSelectedPageRotations()
            return true
        case .insertBlankPage(let page, let before):
            guard state.canPageEdit else { return false }
            state.selectPage(page, extending: false, toggling: false)
            state.insertBlankPage(before: before)
            return true
        case .deletePage(let page):
            guard state.canPageEdit else { return false }
            state.selectPage(page, extending: false, toggling: false)
            state.confirmDeleteSelectedPages()
            return true
        case .extractPage(let page):
            guard state.canPageEdit else { return false }
            state.selectPage(page, extending: false, toggling: false)
            state.presentExtractPagesPanel()
            return true
        }
    }

    /// Builds the AppKit menu the thumbnail strip shows, from the same items ``sections``
    /// decides. The drag overlay owns the pointer now, so this is where the thumbnail's
    /// right-click menu is attached; it must not grow a second command list.
    @MainActor
    public static func menu(
        state: AppState,
        page: Int,
        canOpenNewWindow: Bool,
        newWindow: @escaping (URL, Int) -> Bool
    ) -> NSMenu? {
        let sections = sections(state: state, page: page, canOpenNewWindow: canOpenNewWindow)
        guard !sections.isEmpty else { return nil }

        let menu = NSMenu()
        menu.autoenablesItems = false
        for (sectionIndex, section) in sections.enumerated() {
            if sectionIndex > 0 { menu.addItem(.separator()) }
            for item in section {
                let handler = ContextMenuHandler { [weak state] in
                    guard let state else { return }
                    _ = perform(item.action, state: state, newWindow: newWindow)
                }
                let menuItem = NSMenuItem(
                    title: item.title,
                    action: #selector(ContextMenuHandler.invoke),
                    keyEquivalent: ""
                )
                menuItem.target = handler
                menuItem.representedObject = handler
                menuItem.isEnabled = item.isEnabled
                menu.addItem(menuItem)
            }
        }
        return menu
    }
}
