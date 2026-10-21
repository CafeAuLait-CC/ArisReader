import AppKit
import LyraReaderBindings
import SwiftUI

/// The cards drawn in the gaps opened in the document flow.
///
/// This is an overlay only in the drawing sense: the gap itself is real (pages below the card's
/// row are shifted down by `AppState`), so a card never covers page content. Its top follows the
/// page point through scroll and zoom because both coordinates come from the same
/// `CanvasGeometry` conversion the canvas uses for pages.
public struct AIRegionCardsOverlay: View {
    @ObservedObject private var state: AppState
    private let onOpenInPanel: (AIRegionHistoryEntry) -> Void
    private let onShowHistory: () -> Void

    public init(
        state: AppState,
        onOpenInPanel: @escaping (AIRegionHistoryEntry) -> Void,
        onShowHistory: @escaping () -> Void
    ) {
        self.state = state
        self.onOpenInPanel = onOpenInPanel
        self.onShowHistory = onShowHistory
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(state.regionCards) { card in
                    if let frame = AIRegionCardPlacement.frame(for: card, state: state, in: geometry.size) {
                        let visible = frame.y + card.heightViewPt > 0
                            && frame.y < geometry.size.height
                        AIRegionCardView(
                            state: state,
                            card: card,
                            width: frame.width,
                            onOpenInPanel: onOpenInPanel,
                            onShowHistory: onShowHistory
                        )
                        .frame(width: frame.width)
                        .offset(x: frame.x, y: frame.y)
                        .opacity(visible ? 1 : 0)
                        .allowsHitTesting(visible)
                        .transition(.opacity)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .clipped()
        .animation(.easeOut(duration: 0.16), value: state.regionCards.count)
    }


}

/// One Jupyter-style cell: the question and the answer beneath it, with a small header that
/// names the page and region and offers the three lifecycle actions.
struct AIRegionCardView: View {
    @ObservedObject var state: AppState
    @ObservedObject var card: AIRegionCard
    @ObservedObject private var assistant: AIAssistantModel
    let width: CGFloat
    let onOpenInPanel: (AIRegionHistoryEntry) -> Void
    let onShowHistory: () -> Void

    @State private var confirmingDelete = false
    @FocusState private var questionFocused: Bool

    init(
        state: AppState,
        card: AIRegionCard,
        width: CGFloat,
        onOpenInPanel: @escaping (AIRegionHistoryEntry) -> Void,
        onShowHistory: @escaping () -> Void
    ) {
        self.state = state
        self.card = card
        self.width = width
        self.onOpenInPanel = onOpenInPanel
        self.onShowHistory = onShowHistory
        _assistant = ObservedObject(wrappedValue: card.assistant)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            attachmentStrip
            Divider().overlay(LyraReaderTheme.separator)
            questionCell
            if let plan = assistant.plan, assistant.phase == .preview {
                preview(plan)
            }
            answerCell
            footer
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(LyraReaderTheme.panelBg,
                    in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(LyraReaderTheme.separator, lineWidth: 0.75)
        )
        .overlay(alignment: .topLeading) {
            // A small tear-like accent at the top-left: the card is inserted where the page
            // flow was cut, not floating over the page.
            Rectangle()
                .fill(LyraReaderTheme.accent.opacity(0.65))
                .frame(width: 44, height: 2)
                .offset(x: 12, y: -1)
        }
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .background(heightReporter)
        .background(AIRegionCardMarkerHost())
        .confirmationDialog("Delete this region conversation?",
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete Conversation", role: .destructive) {
                assistant.cancel()
                state.closeRegionCard(id: card.id, keepHistory: false,
                                      reason: "Region conversation deleted. The page layout returned to normal.")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The question and answer are discarded. This cannot be undone; nothing is written to the PDF either way.")
        }
        .onAppear {
            if card.question.isEmpty { questionFocused = true }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LyraReaderTheme.accent)
            Text("Page \(card.attachment.page + 1) · \(card.attachment.sizeLabel)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(LyraReaderTheme.textPrimary)
                .lineLimit(1)
            if card.attachment.textTruncated {
                Text("text capped")
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.warningFg)
            }
            Spacer(minLength: 4)
            headerButton("arrow.up.forward.app", help: "Copy this conversation into the AI panel chat") {
                guard let entry = card.historyEntry else { return }
                onOpenInPanel(entry)
            }
            .disabled(card.askedQuestion == nil || assistant.answer.isEmpty)
            headerButton("chevron.down", help: "Close the gap and keep this conversation in Region questions") {
                close(keepHistory: true, showHistory: true)
            }
            headerButton("trash", help: "Delete this conversation and close the gap") {
                confirmingDelete = true
            }
        }
    }

    private func headerButton(
        _ systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10.5, weight: .semibold))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(LyraReaderTheme.textSecondary)
        .help(help)
        .accessibilityLabel(help)
    }

    private var attachmentStrip: some View {
        HStack(alignment: .top, spacing: 9) {
            if let image = card.attachment.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 92, height: 62)
                    .background(LyraReaderTheme.canvasBg)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(LyraReaderTheme.separator, lineWidth: 0.5))
                    .accessibilityLabel("Selected region on page \(card.attachment.page + 1)")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(card.attachment.pageLabel)
                    .font(.caption2.weight(.semibold))
                Text(card.attachment.sizeLabel)
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.textSecondary)
                Text(card.attachment.pixelLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(LyraReaderTheme.textTertiary)
                Text("\(card.attachment.characterCount.formatted()) characters · capture \(card.attachment.captureScale, specifier: "%.2f")×")
                    .font(.caption2)
                    .foregroundStyle(card.attachment.textTruncated
                        ? LyraReaderTheme.warningFg : LyraReaderTheme.textSecondary)
                    .lineLimit(2)
                Text(imageStatement)
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.textTertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    private var imageStatement: String {
        if let plan = assistant.plan {
            return plan.parts.first?.includesRegionImage == true
                ? "Image included in the request as PNG."
                : "Text-only request: the picture is shown here and kept for export, but not sent."
        }
        let vision = (try? assistant.settings.providerSettings().vision) ?? false
        if !vision {
            return "Text-only model: the picture is shown here and kept for export, but not sent."
        }
        return "Image included in the request as PNG."
    }

    private var questionCell: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Question")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(LyraReaderTheme.textSecondary)
            HStack(alignment: .bottom, spacing: 6) {
                TextField("Ask about this region…", text: $card.question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(2...6)
                    .padding(7)
                    .background(LyraReaderTheme.raisedBg,
                                in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(questionFocused ? LyraReaderTheme.accent
                                                      : LyraReaderTheme.separator,
                                      lineWidth: questionFocused ? 1 : 0.5))
                    .focused($questionFocused)
                    .onSubmit { ask() }
                    .disabled(assistant.phase == .streaming)
                questionActions
            }
        }
    }

    @ViewBuilder
    private var questionActions: some View {
        if assistant.phase == .preparing {
            ProgressView().controlSize(.small)
                .frame(width: 54, height: 28)
        } else if assistant.phase == .preview, assistant.plan != nil {
            Button("Send") { assistant.send() }
                .buttonStyle(RegionCardButtonStyle(prominent: true))
                .help("Send the previewed request")
        } else if assistant.phase == .streaming {
            Button("Cancel") { assistant.cancel() }
                .buttonStyle(RegionCardButtonStyle())
                .help("Stop the request; the partial answer is kept")
        } else {
            Button(assistant.phase == .failed || assistant.phase == .cancelled ? "Retry" : "Ask") {
                if assistant.phase == .failed, assistant.plan != nil, assistant.canRetry {
                    assistant.retry()
                } else {
                    ask()
                }
            }
            .buttonStyle(RegionCardButtonStyle(prominent: true))
            .disabled(card.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Build the exact request preview first; nothing is sent until Send")
        }
    }

    private func ask() {
        guard let context = state.aiReaderContext else { return }
        let question = card.question
        Task { @MainActor in
            await assistant.prepareRegion(
                question: question,
                attachment: card.attachment,
                context: context
            )
        }
    }

    private func preview(_ plan: AiPlanRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Request preview")
                    .font(.caption2.weight(.semibold))
                Spacer()
                Text("\(plan.estimatedTokens) est. tokens")
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.textTertiary)
            }
            Text(plan.isLocal
                 ? "This endpoint runs on this Mac; the region stays here."
                 : "This is a remote endpoint: the region's text and picture leave this Mac when you press Send.")
                .font(.caption2)
                .foregroundStyle(plan.isLocal ? LyraReaderTheme.textSecondary
                                              : LyraReaderTheme.warningFg)
                .fixedSize(horizontal: false, vertical: true)
            previewRow("Model", plan.model)
            previewRow("Pages", plan.sourcePageLabel)
            previewRow("Region", card.attachment.sizeLabel)
            previewRow("Text", "\(card.attachment.characterCount.formatted()) characters")
            previewRow("Picture", plan.parts.first?.includesRegionImage == true
                ? "\(card.attachment.pixelLabel) PNG included"
                : "Not sent (text-only model configuration)")
            if card.attachment.textTruncated {
                Text("The region text was capped at \(AIRegionLimits.maximumTextCharacters.formatted()) characters; the preview sends the capped text.")
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.warningFg)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = plan.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.warningFg)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("Prompts and exact JSON body") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("User prompt")
                        .font(.caption2.weight(.semibold))
                    promptBox(plan.parts.first?.userPrompt ?? "")
                    Text("Exact JSON body")
                        .font(.caption2.weight(.semibold))
                    promptBox(plan.parts.first?.wireBody ?? "")
                }
                .padding(.top, 3)
            }
            .font(.caption2)
        }
        .padding(8)
        .background(LyraReaderTheme.raisedBg, in: RoundedRectangle(cornerRadius: 6))
    }

    private func previewRow(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(name)
                .font(.caption2.weight(.medium))
                .foregroundStyle(LyraReaderTheme.textSecondary)
                .frame(width: 48, alignment: .leading)
            Text(value)
                .font(.caption2)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func promptBox(_ text: String) -> some View {
        ScrollView(.vertical) {
            Text(text)
                .font(.system(size: 9, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 150)
        .padding(5)
        .background(LyraReaderTheme.panelBg, in: RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private var answerCell: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text("Answer")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LyraReaderTheme.textSecondary)
                if assistant.phase == .streaming {
                    ProgressView().controlSize(.mini)
                    Text("\(assistant.answer.count) characters")
                        .font(.caption2)
                        .foregroundStyle(LyraReaderTheme.textTertiary)
                }
                Spacer(minLength: 4)
                if !assistant.answer.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(assistant.answer, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10.5))
                    }
                    .buttonStyle(.plain)
                    .help("Copy the Markdown source, including $…$ mathematics")
                    .accessibilityLabel("Copy answer as Markdown")
                }
            }
            if assistant.answer.isEmpty {
                emptyAnswerView
            } else {
                AIAnswerView(
                    text: assistant.answer,
                    pageCount: state.document?.pageCount ?? 0,
                    verifiedPages: [card.attachment.page + 1],
                    onJump: { page in state.gotoPage(page - 1) }
                )
                if assistant.phase == .streaming {
                    Text("Streaming in place. The gap grows with the answer; pages below stay pushed down.")
                        .font(.caption2)
                        .foregroundStyle(LyraReaderTheme.textTertiary)
                }
            }
            if let error = assistant.errorMessage, assistant.phase == .failed {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(LyraReaderTheme.errorFg)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(LyraReaderTheme.errorFg)
                            .fixedSize(horizontal: false, vertical: true)
                        if assistant.canRetry {
                            Button("Retry the same request") { assistant.retry() }
                                .buttonStyle(.plain)
                                .font(.caption2.weight(.semibold))
                        }
                    }
                }
            }
            if assistant.phase == .cancelled {
                HStack(spacing: 5) {
                    Image(systemName: "stop.circle")
                        .foregroundStyle(LyraReaderTheme.warningFg)
                    Text(assistant.answer.isEmpty
                         ? "Cancelled before the first token. The question is kept."
                         : "Cancelled. The partial answer above is kept.")
                        .font(.caption2)
                        .foregroundStyle(LyraReaderTheme.warningFg)
                    if assistant.canRetry {
                        Button("Retry") { assistant.retry() }
                            .buttonStyle(.plain)
                            .font(.caption2.weight(.semibold))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyAnswerView: some View {
        if assistant.phase == .streaming {
            Text("Waiting for the first token…")
                .font(.caption)
                .foregroundStyle(LyraReaderTheme.textSecondary)
        } else if assistant.phase == .cancelled {
            EmptyView()
        } else if assistant.phase == .failed {
            EmptyView()
        } else {
            Text("No answer yet. Ask a question about the selected region.")
                .font(.caption)
                .foregroundStyle(LyraReaderTheme.textTertiary)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(card.askedQuestion == nil
                 ? "Ask creates a preview; Send starts the request."
                 : "This conversation lives in the document flow, not in the PDF.")
                .font(.caption2)
                .foregroundStyle(LyraReaderTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Done") { close(keepHistory: true, showHistory: true) }
                .buttonStyle(RegionCardButtonStyle())
                .help("Close the gap, keep the conversation in Region questions")
            Button("Open in AI panel") {
                guard let entry = card.historyEntry else { return }
                onOpenInPanel(entry)
            }
            .buttonStyle(RegionCardButtonStyle())
            .disabled(card.askedQuestion == nil || assistant.answer.isEmpty)
            .help("Copy the question and answer into the panel's chat")
        }
    }

    private func close(keepHistory: Bool, showHistory: Bool) {
        assistant.cancel()
        state.closeRegionCard(id: card.id, keepHistory: keepHistory)
        if showHistory { onShowHistory() }
    }

    private var heightReporter: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: AIRegionCardHeightKey.self, value: proxy.size.height)
        }
        .onPreferenceChange(AIRegionCardHeightKey.self) { height in
            card.updateHeight(height)
        }
    }
}

private struct AIRegionCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}


/// A compact button that fits the card's width without the panel style's full-width frame.
private struct RegionCardButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 9)
            .frame(minHeight: 26)
            .foregroundStyle(!enabled ? LyraReaderTheme.textDisabled
                             : prominent ? LyraReaderTheme.onAccent : LyraReaderTheme.textPrimary)
            .background(!enabled ? LyraReaderTheme.panelBg
                        : prominent
                            ? (configuration.isPressed ? LyraReaderTheme.accentPressed
                                                       : LyraReaderTheme.accent)
                            : (configuration.isPressed ? LyraReaderTheme.pressedBg
                                                       : LyraReaderTheme.fieldBg),
                        in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(prominent ? Color.clear : LyraReaderTheme.controlBorder))
            .opacity(enabled ? 1 : 0.5)
    }
}


/// A zero-size AppKit marker behind the card, so the hosted checks can measure the shipped card
/// frame without inspecting SwiftUI's private view tree.
public final class AIRegionCardMarkerView: NSView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityLabel("Region question card")
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityLabel("Region question card")
    }
}

private struct AIRegionCardMarkerHost: NSViewRepresentable {
    func makeNSView(context: Context) -> AIRegionCardMarkerView {
        AIRegionCardMarkerView(frame: .zero)
    }

    func updateNSView(_ nsView: AIRegionCardMarkerView, context: Context) {}
}


@MainActor
enum AIRegionCardPlacement {
    /// The card's top-left frame in the canvas's view space. The same arithmetic places both the
    /// SwiftUI card and the pass-through hit-test rectangles, so the visible card and the
    /// clickable card cannot drift apart.
    static func frame(
        for card: AIRegionCard,
        state: AppState,
        in size: CGSize
    ) -> (x: CGFloat, y: CGFloat, width: CGFloat)? {
        guard let placement = state.canvasPageFrames.first(where: { $0.index == card.attachment.page }),
              let gapTop = state.regionGapTop(for: card.id),
              size.width > 120, size.height > 80
        else { return nil }
        let zoom = max(state.zoomFactor, 0.01)
        let offsetX = CanvasGeometry.contentOffsetX(
            viewportWidthPt: size.width,
            contentWidthPt: state.contentWidthPt,
            zoom: zoom
        )
        let pageWidth = placement.widthPt * zoom
        let maxWidth = min(size.width - 32, 780)
        let width = min(max(320, pageWidth - 36), max(240, maxWidth))
        let centreX = offsetX + (placement.leftPt + placement.widthPt / 2) * zoom
        let x = min(max(16, centreX - width / 2), max(16, size.width - width - 16))
        let y = CanvasGeometry.viewY(contentY: gapTop, scrollYPt: state.scrollYPt, zoom: zoom)
        return (x, y, width)
    }
}

/// Hosts the region cards behind a pass-through `NSView`.
///
/// A plain SwiftUI overlay covering the canvas makes the whole canvas its hit-test area: the
/// `NSHostingView` returns itself even over empty space, so page clicks and scrolling stop
/// working as soon as one card exists. This wrapper is the same overlay with a hit test limited
/// to the cards' own rectangles; everywhere else the event falls through to the canvas.
public struct AIRegionOverlayHost: NSViewRepresentable {
    @ObservedObject private var state: AppState
    private let onOpenInPanel: (AIRegionHistoryEntry) -> Void
    private let onShowHistory: () -> Void

    public init(
        state: AppState,
        onOpenInPanel: @escaping (AIRegionHistoryEntry) -> Void,
        onShowHistory: @escaping () -> Void
    ) {
        self.state = state
        self.onOpenInPanel = onOpenInPanel
        self.onShowHistory = onShowHistory
    }

    public func makeNSView(context: Context) -> AIRegionOverlayPassthroughView {
        let view = AIRegionOverlayPassthroughView()
        view.configure(state: state, onOpenInPanel: onOpenInPanel,
                       onShowHistory: onShowHistory)
        return view
    }

    public func updateNSView(_ nsView: AIRegionOverlayPassthroughView, context: Context) {
        nsView.configure(state: state, onOpenInPanel: onOpenInPanel,
                         onShowHistory: onShowHistory)
    }
}

public final class AIRegionOverlayPassthroughView: NSView {
    fileprivate var host: NSHostingView<AIRegionCardsOverlay>?
    fileprivate var state: AppState?
    fileprivate var interactiveRects: [CGRect] = []

    /// Build or update the card overlay. The native checks create this view directly so the
    /// hit-test pass-through is measured without a second hosting view above it.
    public func configure(
        state: AppState,
        onOpenInPanel: @escaping (AIRegionHistoryEntry) -> Void,
        onShowHistory: @escaping () -> Void
    ) {
        self.state = state
        let root = AIRegionCardsOverlay(
            state: state, onOpenInPanel: onOpenInPanel, onShowHistory: onShowHistory
        )
        if let host {
            host.rootView = root
        } else {
            let created = NSHostingView(rootView: root)
            created.frame = bounds
            created.autoresizingMask = [.width, .height]
            addSubview(created)
            host = created
        }
        updateInteractiveRects()
    }

    public override func layout() {
        super.layout()
        host?.frame = bounds
        updateInteractiveRects()
    }

    fileprivate func updateInteractiveRects() {
        guard let state else {
            interactiveRects = []
            return
        }
        let size = bounds.size
        interactiveRects = state.regionCards.compactMap { card in
            guard let topLeft = AIRegionCardPlacement.frame(for: card, state: state, in: size)
            else { return nil }
            let height = max(44, card.heightViewPt)
            return CGRect(x: topLeft.x, y: size.height - topLeft.y - height,
                          width: topLeft.width, height: height)
        }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveRects.contains(where: { $0.contains(point) }) else { return nil }
        return super.hitTest(point)
    }
}
