import AppKit
import Foundation

/// The secondary rows that share the one slot below the toolbar.
///
/// Page overview is deliberately not a case: it covers the whole content area rather than one
/// row, and opening it while a row is open leaves the row's state alone so closing the overview
/// returns the same row instead of an empty strip.
public enum SecondaryRow: String, CaseIterable, Sendable {
    case annotations
    case contentEdit
    case fillAndSign
    case export

    /// The row's human name, also used by the checks' failure messages.
    public var title: String {
        switch self {
        case .annotations: return "Annotate"
        case .contentEdit: return "Edit"
        case .fillAndSign: return "Fill & Sign"
        case .export: return "Export"
        }
    }
}

/// One tool in the Fill & Sign sub-toolbar row, in display order.
///
/// The row is placement-first: Text, Signature, Date, Checkmark, Cross, Stamp and Image are the
/// seven commands the #153 menu offered, in the same order. Choosing one arms it and opens the
/// right-hand inspector; the inspector holds the tool's secondary options (a signature method
/// and preview, a stamp style grid, a date format and rotation, or a picture size).
public enum FillSignTool: String, CaseIterable, Identifiable, Sendable {
    case text
    case signature
    case date
    case checkmark
    case cross
    case stamp
    case image

    public var id: String { rawValue }

    /// The row's left-to-right order. ``allCases`` already follows it, but the checks and the
    /// layout both read this array so a future reordering is one edit.
    public static let rowOrder: [FillSignTool] = [
        .text, .signature, .date, .checkmark, .cross, .stamp, .image,
    ]

    /// The row label, exactly as the request names the seven items.
    public var title: String {
        switch self {
        case .text: return "Text"
        case .signature: return "Signature"
        case .date: return "Date"
        case .checkmark: return "Checkmark"
        case .cross: return "Cross"
        case .stamp: return "Stamp"
        case .image: return "Image"
        }
    }

    /// The SF Symbol on the row button. None of these is the system Share glyph.
    public var icon: String {
        switch self {
        case .text: return "textbox"
        case .signature: return "signature"
        case .date: return "calendar"
        case .checkmark: return "checkmark"
        case .cross: return "xmark"
        case .stamp: return "seal"
        case .image: return "photo"
        }
    }

    /// The inspector section title for this tool.
    public var inspectorTitle: String {
        switch self {
        case .text: return "Text"
        case .signature: return "Signature"
        case .date: return "Date"
        case .checkmark: return "Checkmark"
        case .cross: return "Cross"
        case .stamp: return "Stamp"
        case .image: return "Image"
        }
    }

}

/// The date style the Date tool places, chosen in the Fill & Sign inspector.
public enum FillSignDateFormat: String, CaseIterable, Identifiable, Sendable {
    case medium
    case long
    case short
    case iso

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .medium: return "Medium"
        case .long: return "Long"
        case .short: return "Short"
        case .iso: return "ISO"
        }
    }


    /// The date rendered in this style, in the reader's locale and time zone.
    public func string(
        for date: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.timeStyle = .none
        switch self {
        case .medium: formatter.dateStyle = .medium
        case .long: formatter.dateStyle = .long
        case .short: formatter.dateStyle = .short
        case .iso:
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
        }
        return formatter.string(from: date)
    }
}

/// How the Date tool turns the placed date, chosen in the Fill & Sign inspector.
///
/// A quarter turn is placed as a picture annotation: `/FreeText` has no rotation in the reader's
/// writer, while the image `/Stamp` path already writes an appearance every viewer paints in the
/// same orientation. A 0° date keeps the editable text box (and its select-all editor) that
/// #153's Date command created.
public enum FillSignDateRotation: Int, CaseIterable, Identifiable, Sendable {
    case none = 0
    case quarter = 90
    case half = 180
    case threeQuarters = 270

    public var id: Int { rawValue }

    public var title: String { "\(rawValue)°" }

    public var isRotated: Bool { self != .none }
}

/// The initial height class for a placed picture, chosen in the Fill & Sign inspector.
public enum FillSignImageSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case medium
    case large

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    /// The page-point height the picture is placed at. Medium is the historical
    /// ``AppState.Annotation/defaultPictureHeight`` so the default flow is unchanged.
    public var height: CGFloat {
        switch self {
        case .small: return 80
        case .medium: return AppState.Annotation.defaultPictureHeight
        case .large: return 220
        }
    }
}

/// One row item of the Fill & Sign sub-toolbar, as data.
///
/// The row and the checks read the same list: the order, the enabled state and the help text are
/// facts about the reader's state, not about a particular SwiftUI call.
public struct FillSignRowCommand: Identifiable, Equatable, Sendable {
    public let tool: FillSignTool
    public let title: String
    public let icon: String
    public let enabled: Bool
    public let help: String

    public var id: String { tool.rawValue }

    public init(tool: FillSignTool, title: String, icon: String, enabled: Bool, help: String) {
        self.tool = tool
        self.title = title
        self.icon = icon
        self.enabled = enabled
        self.help = help
    }
}

/// The Fill & Sign inspector's Signature methods, in the order #153's submenu used.
///
/// `continuity` is the item AppKit recognises by identifier; the inspector hosts it inside a
/// small pop-up button (see ``ContinuitySignatureButton``) rather than drawing a look-alike.
public struct SignatureMethodCommand: Identifiable, Equatable, Sendable {
    public enum Action: String, Equatable, Sendable {
        case type
        case draw
        case image
        case continuity
    }

    public let action: Action
    public let title: String
    public let icon: String
    public let enabled: Bool
    public let help: String

    public var id: String { action.rawValue }

    public init(action: Action, title: String, icon: String, enabled: Bool, help: String) {
        self.action = action
        self.title = title
        self.icon = icon
        self.enabled = enabled
        self.help = help
    }
}
