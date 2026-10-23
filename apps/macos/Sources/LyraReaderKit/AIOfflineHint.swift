import LyraReaderBindings
import SwiftUI

/// The transport-failure categories the panel can describe honestly.
///
/// This mirrors `AiFailureRecord` on the Rust side, which is computed from the platform error
/// (never from message text) at the one HTTP transport. Every AI action uses that transport, so
/// the panel, the region card, document chat and the layered summary all read the same category.
public enum AIRequestFailure: Codable, Equatable, Sendable {
    case other
    case offline
    case localServer

    public init(_ record: AiFailureRecord) {
        switch record {
        case .other: self = .other
        case .offline: self = .offline
        case .localServer: self = .localServer
        }
    }
}

/// The one hint the reader sees after a transport failure. The copy and the control live here so
/// no action-specific view invents its own wording.
public struct AIOfflineHint: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A remote endpoint could not be reached because this Mac has no route to it.
        case noNetwork
        /// The endpoint is loopback and nothing is listening there. This is not "no network".
        case localServer
    }

    public let kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    /// Nil for every failure that is not one of the two recognized transport cases. The existing
    /// error display stays in place for those.
    public static func forFailure(_ failure: AIRequestFailure) -> AIOfflineHint? {
        switch failure {
        case .offline: return AIOfflineHint(kind: .noNetwork)
        case .localServer: return AIOfflineHint(kind: .localServer)
        case .other: return nil
        }
    }

    public static let noNetworkSentence =
        "The request did not go out because this Mac has no network connection."
    public static let localModelSentence =
        "A local model can be used offline: point the base URL at a server on this Mac (for example http://localhost:11434/v1)."
    public static let localServerSentence =
        "The request did not go out because the local AI server is not running."
    public static let localServerAdvice =
        "Start the server (for example Ollama, LM Studio or llama.cpp), then press Retry."
    public static let controlTitle = "Open AI Settings…"

    public var title: String {
        switch kind {
        case .noNetwork: return "No network connection"
        case .localServer: return "Local server not running"
        }
    }

    public var icon: String {
        switch kind {
        case .noNetwork: return "wifi.slash"
        case .localServer: return "desktopcomputer"
        }
    }

    public var sentence: String {
        switch kind {
        case .noNetwork: return Self.noNetworkSentence
        case .localServer: return Self.localServerSentence
        }
    }

    public var controlTitle: String { Self.controlTitle }

    /// The second sentence: what to do about it. Both cases point at AI settings' base URL.
    public var advice: String {
        switch kind {
        case .noNetwork: return Self.localModelSentence
        case .localServer: return Self.localServerAdvice
        }
    }
}

/// Where Settings should open and which field should take focus. One shared route keeps the
/// hint's control independent of whichever view is hosting the hint.
@MainActor
public final class AISettingsRoute: ObservableObject {
    public enum Tab: Hashable, Sendable {
        case performance
        case reading
        case ai
    }

    public static let shared = AISettingsRoute()

    @Published public var selectedTab: Tab = .performance
    /// Set when a control asked for the base-URL field. The AI settings view consumes it once,
    /// so switching tabs later does not steal focus again.
    @Published public private(set) var pendingBaseURLFocus = false

    public init() {}

    /// Ask Settings to show its AI tab with the base-URL field focused.
    public func revealBaseURL() {
        selectedTab = .ai
        pendingBaseURLFocus = true
    }

    public func consumeBaseURLFocus() {
        pendingBaseURLFocus = false
    }
}

/// A calm, specific hint shown beside the transport error it explains. It never replaces the
/// error text and never hides the retry control the surrounding cell already has.
public struct AIOfflineHintView: View {
    public let hint: AIOfflineHint
    @Environment(\.openSettings) private var openSettings

    public init(hint: AIOfflineHint) {
        self.hint = hint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(hint.title, systemImage: hint.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(LyraReaderTheme.infoFg)
            Text(hint.sentence)
                .font(.caption2)
                .foregroundStyle(LyraReaderTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(hint.advice)
                .font(.caption2)
                .foregroundStyle(LyraReaderTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(AIOfflineHint.controlTitle) {
                AISettingsRoute.shared.revealBaseURL()
                openSettings()
            }
            .buttonStyle(ReaderPanelButtonStyle())
            .font(.caption)
            .controlSize(.small)
            .accessibilityHint("Shows the AI settings with the base URL field focused")
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LyraReaderTheme.infoBg, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(LyraReaderTheme.infoFg.opacity(0.25), lineWidth: 0.5)
        )
    }
}
