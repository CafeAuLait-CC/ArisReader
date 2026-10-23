import AppKit
import LyraReaderBindings
import SwiftUI

/// Compatibility host for previews and isolated native checks. The reader uses the native
/// canvas child below so the card and paper share the very same submitted scroll transform.
public struct AIRegionCardsOverlay: View {
    @ObservedObject var state: AppState
    let onOpenInPanel: (AIRegionHistoryEntry) -> Void
    let onShowHistory: () -> Void
    public init(state: AppState, onOpenInPanel: @escaping (AIRegionHistoryEntry) -> Void,
                onShowHistory: @escaping () -> Void) {
        self.state = state; self.onOpenInPanel = onOpenInPanel; self.onShowHistory = onShowHistory
    }
    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(state.regionCards) { card in
                    if let frame = AIRegionCardPlacement.frame(for: card, state: state, in: geometry.size) {
                        AIRegionCardView(state: state, card: card, width: frame.width,
                            maximumHeight: AIRegionCard.maximumHeight(in: geometry.size.height),
                            onOpenInPanel: onOpenInPanel, onShowHistory: onShowHistory)
                            .frame(width: frame.width)
                            .offset(x: frame.x, y: frame.y)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.clipped()
    }
}

/// A small reading conversation: paper context, a bounded transcript and a fixed composer.
struct AIRegionCardView: View {
    let state: AppState
    @ObservedObject var card: AIRegionCard
    @ObservedObject private var assistant: AIAssistantModel
    @ObservedObject private var notes: AIAssistantModel
    let width: CGFloat
    var maximumHeight: CGFloat = 420
    let onOpenInPanel: (AIRegionHistoryEntry) -> Void
    let onShowHistory: () -> Void
    @State private var showingSelection = false
    @State private var showingDetails = false
    @State private var showingNote = false
    @State private var editingNote = false
    @State private var confirmingDelete = false
    @State private var transcriptHeight: CGFloat = 40
    @State private var composerHeight: CGFloat = 54
    @State private var followLatest = true
    @FocusState private var questionFocused: Bool

    init(state: AppState, card: AIRegionCard, width: CGFloat, maximumHeight: CGFloat = 420,
         onOpenInPanel: @escaping (AIRegionHistoryEntry) -> Void,
         onShowHistory: @escaping () -> Void) {
        self.state = state; self.card = card; self.width = width
        self.maximumHeight = maximumHeight
        self.onOpenInPanel = onOpenInPanel; self.onShowHistory = onShowHistory
        _assistant = ObservedObject(wrappedValue: card.assistant)
        _notes = ObservedObject(wrappedValue: card.notesAssistant)
    }
    private var transcriptLimit: CGFloat { max(30, maximumHeight - 58 - composerHeight) }
    private var transcriptViewHeight: CGFloat { min(max(32, transcriptHeight), transcriptLimit) }
    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(LyraReaderTheme.accentBorder.opacity(0.18)).frame(height: 1).padding(.horizontal, 18)
            transcript
            Rectangle().fill(LyraReaderTheme.accentBorder.opacity(0.18)).frame(height: 1).padding(.horizontal, 18)
            composer.background(GeometryReader { p in
                Color.clear.preference(key: AIRegionComposerHeightKey.self, value: p.size.height)
            })
            .onPreferenceChange(AIRegionComposerHeightKey.self) { composerHeight = $0 }
        }
        .foregroundStyle(LyraReaderTheme.textPrimary)
        .background(RegionNotePaper())
        .padding(.vertical, 8)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: AIRegionCardHeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(AIRegionCardHeightKey.self) { height in
            Task { @MainActor in state.updateRegionCardHeight(cardID: card.id, viewHeight: height) }
        }
        .background(AIRegionCardMarkerHost())
        .onAppear { questionFocused = true }
        .sheet(isPresented: $editingNote, onDismiss: { state.persistRegionHistory() }) {
            VStack(spacing: 12) {
                HStack {
                    Text("Edit Reading Note").font(.headline)
                    Spacer()
                    Button("Done") { editingNote = false }.keyboardShortcut(.defaultAction)
                }
                Text("Edit the Markdown source. Your changes appear in the reading preview.")
                    .font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TextEditor(text: $card.knowledgeNote)
                    .font(.system(size: 13, design: .monospaced))
                    .accessibilityLabel("Reading note Markdown source")
            }.padding(18).frame(width: 600, height: 460)
                .background(LyraReaderTheme.panelBg)
        }
        .onChange(of: notes.phase) { _, phase in
            if phase == .finished {
                card.keepGeneratedNote(); showingNote = true; state.persistRegionHistory()
            }
        }
        .confirmationDialog("Delete this conversation?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete Conversation", role: .destructive) {
                state.closeRegionCard(id: card.id, keepHistory: false)
            }
            Button("Cancel", role: .cancel) {}
        }
    }
    private var header: some View {
        HStack(spacing: 7) {
            LyraAIIcon(isActive: card.isBusy || card.notesBusy)
                .frame(width: 21, height: 21).foregroundStyle(LyraReaderTheme.accent)
                .accessibilityLabel(card.isBusy || card.notesBusy ? "Lyra is responding" : "Lyra")
            Button { showingSelection.toggle() } label: {
                HStack(spacing: 5) {
                    Text("Page \(card.attachment.page + 1)").font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
            }.buttonStyle(.plain).help("View selected region")
                .popover(isPresented: $showingSelection) { selectionPreview }
            if showingNote {
                Text("Reading note").font(.system(size: 12, design: .serif)).foregroundStyle(LyraReaderTheme.noteFg)
            } else if card.isBusy || card.notesBusy {
                Text(card.notesBusy ? "Making notes…" : assistant.answer.isEmpty ? "Thinking…" : "Responding…")
                    .font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
            }
            Spacer(minLength: 4)
            if showingNote && !card.notesBusy && !card.knowledgeNote.isEmpty {
                Button { editingNote = true } label: {
                    Image(systemName: "square.and.pencil").frame(width: 24, height: 24)
                }.buttonStyle(.plain).help("Edit reading note")
                    .accessibilityLabel("Edit reading note")
            }
            Menu {
                Button(showingNote ? "Show Conversation" : "Show Reading Note") { showingNote.toggle() }
                    .disabled(card.knowledgeNote.isEmpty && !card.notesBusy)
                Button("Distill into Reading Note") {
                    guard let context = state.aiReaderContext else { return }
                    showingNote = true
                    Task { await card.distill(context: context) }
                }.disabled(card.conversationContext.isEmpty || card.isBusy || card.notesBusy)
                Button("Export Reading Notes…") { state.presentRegionHistoryExportPanel() }
                    .disabled(!state.hasExportableRegionHistory)
                Divider()
                Button("Request Details") { showingDetails.toggle() }
                Button("All Reading Notes") { onShowHistory() }
                if let entry = card.historyEntry {
                    Button("Open in AI Panel") { onOpenInPanel(entry) }
                }
                Divider()
                Button("Delete Conversation…", role: .destructive) { confirmingDelete = true }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                .menuStyle(.borderlessButton).fixedSize().help("Conversation actions")
                .accessibilityLabel("Conversation actions")
            Button { state.closeRegionCard(id: card.id, keepHistory: true) } label: {
                Image(systemName: "chevron.up").font(.system(size: 11, weight: .medium))
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Collapse and keep conversation")
                .accessibilityLabel("Collapse and keep conversation")
        }.padding(.horizontal, 18).frame(height: 40)
    }
    private var selectionPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image = card.attachment.thumbnail {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 360, maxHeight: 230)
            }
            Text("Page \(card.attachment.page + 1) · \(card.attachment.sizeLabel)")
                .font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
            Text(card.attachment.text).font(.caption).lineLimit(5).textSelection(.enabled)
        }.padding(14).frame(width: 360).background(LyraReaderTheme.raisedBg)
    }
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    if showingDetails { requestDetails }
                    if showingNote {
                        noteContent
                    } else if card.allTurns.isEmpty {
                        Text("What would you like to understand about this region?")
                            .font(.system(size: 12)).foregroundStyle(LyraReaderTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(card.allTurns) { turn in turnView(turn) }
                    }
                    Color.clear.frame(height: 1).id("latest")
                        .background(GeometryReader { p in
                            Color.clear.preference(key: AIRegionBottomKey.self,
                                value: p.frame(in: .named("regionTranscript")).maxY)
                        })
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { p in
                        Color.clear.preference(key: AIRegionTranscriptHeightKey.self, value: p.size.height)
                    })
            }
            .coordinateSpace(name: "regionTranscript")
            .frame(height: transcriptViewHeight)
            .onPreferenceChange(AIRegionTranscriptHeightKey.self) { transcriptHeight = $0 }
            .onPreferenceChange(AIRegionBottomKey.self) { followLatest = $0 < transcriptViewHeight + 48 }
            .onChange(of: assistant.answer) { _, _ in
                if followLatest { proxy.scrollTo("latest", anchor: .bottom) }
            }
            .onChange(of: assistant.regionAskedQuestion) { _, _ in
                followLatest = true; proxy.scrollTo("latest", anchor: .bottom)
            }
        }
    }
    private func turnView(_ turn: AIRegionTurn) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Spacer(minLength: 30)
                Text(turn.question).font(.system(size: 13)).textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(LyraReaderTheme.accentSoft.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(alignment: .leading) {
                        Rectangle().fill(LyraReaderTheme.accentBorder.opacity(0.45)).frame(width: 2)
                    }
            }
            if !turn.answer.isEmpty {
                AIAnswerView(text: turn.answer, pageCount: state.document?.pageCount ?? 0,
                             verifiedPages: [card.attachment.page + 1],
                             onJump: { state.gotoPage($0 - 1) })
            } else if card.isBusy && turn.id == card.allTurns.last?.id {
                Text("Thinking…").font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
            }
            if let error = turn.error {
                Text(error).font(.caption).foregroundStyle(LyraReaderTheme.errorFg).textSelection(.enabled)
            }
            if turn.state == .cancelled {
                Text("Stopped · partial answer kept").font(.caption2).foregroundStyle(LyraReaderTheme.textSecondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private var noteContent: some View {
        if card.notesBusy {
            AIAnswerView(text: notes.answer.isEmpty ? "Organizing key points…" : notes.answer,
                         pageCount: state.document?.pageCount ?? 0,
                         verifiedPages: [card.attachment.page + 1], onJump: { state.gotoPage($0 - 1) })
        } else if !card.knowledgeNote.isEmpty {
            AIAnswerView(text: card.knowledgeNote, pageCount: state.document?.pageCount ?? 0,
                         verifiedPages: [card.attachment.page + 1], onJump: { state.gotoPage($0 - 1) })
        } else {
            Text(notes.errorMessage ?? "Choose Distill into Reading Note to collect the key points.")
                .font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
        }
    }
    private var requestDetails: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(card.attachment.pixelLabel) · \(card.attachment.characterCount) text characters")
            if let plan = assistant.plan {
                Text("\(plan.model) · \(plan.estimatedTokens) estimated tokens")
                Text(plan.isLocal ? "Local endpoint" : "Remote endpoint · selected text and enabled image are sent")
                ForEach(Array(plan.parts.enumerated()), id: \.offset) { _, part in
                    Text(part.wireBody).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                }
            }
        }.font(.caption2).foregroundStyle(LyraReaderTheme.textSecondary)
    }
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 9) {
            TextField(card.allTurns.isEmpty ? "Ask about this region…" : "Ask a follow-up…",
                      text: $card.question, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...3)
                .focused($questionFocused).onSubmit { send() }
                .disabled(card.isBusy || card.notesBusy)
                .padding(9).background(LyraReaderTheme.raisedBg.opacity(0.45), in: RoundedRectangle(cornerRadius: 3))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(questionFocused ? LyraReaderTheme.focusRing : LyraReaderTheme.controlBorder)
                        .frame(height: questionFocused ? 1.5 : 0.7)
                }
                .accessibilityLabel("Region question")
            if card.isBusy || card.notesBusy {
                Button { assistant.cancelRegionWork(); notes.cancelRegionWork() } label: {
                    Image(systemName: "stop.fill").frame(width: 24, height: 28)
                }.buttonStyle(RegionCardButtonStyle()).help("Stop response").accessibilityLabel("Stop response")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold))
                        .frame(width: 24, height: 28)
                }.buttonStyle(RegionCardButtonStyle(prominent: true))
                    .disabled(card.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send · ⌘Return").accessibilityLabel("Send region question")
            }
        }.padding(.leading, 18).padding(.trailing, 24).padding(.vertical, 10)
    }
    private func send() {
        guard let context = state.aiReaderContext else { return }
        showingNote = false
        Task { await card.send(context: context) }
    }
}

private struct AIRegionCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct AIRegionComposerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 54
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct AIRegionTranscriptHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 40
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct AIRegionBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct RegionCardButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 4)
            .foregroundStyle(!enabled ? LyraReaderTheme.textDisabled
                : prominent ? LyraReaderTheme.onAccent : LyraReaderTheme.textPrimary)
            .background(!enabled ? LyraReaderTheme.panelBg
                : prominent ? (configuration.isPressed ? LyraReaderTheme.accentPressed : LyraReaderTheme.accent)
                : LyraReaderTheme.fieldBg, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(
                prominent && enabled ? Color.clear : LyraReaderTheme.controlBorder))
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
        in size: CGSize,
        scroll: CGFloat? = nil,
        zoom submittedZoom: CGFloat? = nil,
        viewport clip: CGRect? = nil
    ) -> (x: CGFloat, y: CGFloat, width: CGFloat)? {
        guard let placement = state.canvasPageFrames.first(where: { $0.index == card.attachment.page }),
              let gapTop = state.regionGapTop(for: card.id),
              size.width > 120, size.height > 80
        else { return nil }
        let zoom = max(submittedZoom ?? state.zoomFactor, 0.01)
        let offsetX = CanvasGeometry.contentOffsetX(
            viewportWidthPt: size.width,
            contentWidthPt: state.contentWidthPt,
            zoom: zoom
        )
        let viewport = clip ?? CGRect(origin: .zero, size: size)
        let pageWidth = placement.widthPt * zoom
        let maxWidth = min(viewport.width - 24, 760)
        let width = min(max(320, pageWidth - 24), max(240, maxWidth))
        let centreX = offsetX + (placement.leftPt + placement.widthPt / 2) * zoom
        let x = min(max(viewport.minX + 12, centreX - width / 2),
                    max(viewport.minX + 12, viewport.maxX - width - 12))
        let y = CanvasGeometry.viewY(contentY: gapTop, scrollYPt: scroll ?? state.scrollYPt, zoom: zoom)
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

/// Native children move in the same transaction as the Metal paper and page borders.
/// Root views survive scroll frames, preserving focus, selection and the transcript's scroll.
@MainActor
final class AIRegionCanvasHost: NSView {
    override var isFlipped: Bool { true }
    private weak var state: AppState?
    private var onOpenInPanel: (AIRegionHistoryEntry) -> Void = { _ in }
    private var onShowHistory: () -> Void = {}
    private var hosts: [UUID: NSHostingView<AIRegionCardView>] = [:]
    private var sizes: [UUID: CGSize] = [:]
    private var placementSignature = ""
    var cardFrames: [CGRect] { hosts.values.map(\.frame) }

    func configure(state: AppState?, onOpenInPanel: @escaping (AIRegionHistoryEntry) -> Void,
                   onShowHistory: @escaping () -> Void) -> Bool {
        let signature = state?.regionCards.map {
            "\($0.id):\($0.heightViewPt):\(state?.regionGapTop(for: $0.id) ?? 0)"
        }.joined(separator: "|") ?? ""
        let changed = self.state !== state || placementSignature != signature
        placementSignature = signature
        self.state = state; self.onOpenInPanel = onOpenInPanel; self.onShowHistory = onShowHistory
        return changed
    }
    func sync(size: CGSize, viewport: CGRect, scroll: CGFloat, zoom: CGFloat) {
        let viewportFrame = CGRect(origin: .zero, size: size)
        if frame != viewportFrame { frame = viewportFrame }
        guard let state else {
            hosts.values.forEach { $0.removeFromSuperview() }; hosts.removeAll(); sizes.removeAll()
            return
        }
        let ids = Set(state.regionCards.map(\.id))
        for id in hosts.keys where !ids.contains(id) {
            hosts.removeValue(forKey: id)?.removeFromSuperview(); sizes[id] = nil
        }
        for card in state.regionCards {
            guard let place = AIRegionCardPlacement.frame(for: card, state: state, in: size,
                                                          scroll: scroll, zoom: zoom, viewport: viewport) else { continue }
            let maxHeight = AIRegionCard.maximumHeight(in: viewport.height)
            let dimensions = CGSize(width: place.width, height: maxHeight)
            let host: NSHostingView<AIRegionCardView>
            if let existing = hosts[card.id] {
                host = existing
                if sizes[card.id] != dimensions {
                    host.rootView = AIRegionCardView(state: state, card: card, width: place.width,
                        maximumHeight: maxHeight, onOpenInPanel: onOpenInPanel, onShowHistory: onShowHistory)
                }
            } else {
                host = NSHostingView(rootView: AIRegionCardView(state: state, card: card, width: place.width,
                    maximumHeight: maxHeight, onOpenInPanel: onOpenInPanel, onShowHistory: onShowHistory))
                host.sizingOptions = []
                addSubview(host)
                hosts[card.id] = host
            }
            sizes[card.id] = dimensions
            let frame = CGRect(x: place.x, y: place.y, width: place.width, height: card.heightViewPt)
            if host.frame != frame { host.frame = frame }
            host.isHidden = host.frame.maxY <= 0 || host.frame.minY >= size.height
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // AppKit passes a point in the superview's coordinates. The Metal parent is
        // bottom-up while this host is top-down; hit-test in the host's own coordinates.
        let local = convert(point, from: superview)
        guard hosts.values.contains(where: { !$0.isHidden && $0.frame.contains(local) }) else { return nil }
        return super.hitTest(point)
    }
}


/// A quiet sheet of note paper inside the PDF split. Decoration stays behind the
/// content so it cannot intercept selection, scrolling, or the fixed composer.
private struct RegionNotePaper: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(LyraReaderTheme.panelBg)
            .overlay {
                if !reduceTransparency {
                    LinearGradient(colors: [LyraReaderTheme.accentSoft.opacity(0.75),
                                            LyraReaderTheme.raisedBg.opacity(0.25),
                                            LyraReaderTheme.accentSoft.opacity(0.45)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Canvas { context, size in
                        // Deterministic short fibres, capped independently of response length.
                        for index in 0..<180 {
                            let x = CGFloat((index * 137 + 29) % 997) / 997 * size.width
                            let y = CGFloat((index * 263 + 71) % 991) / 991 * size.height
                            var fibre = Path()
                            fibre.move(to: CGPoint(x: x, y: y))
                            fibre.addLine(to: CGPoint(x: x + 2 + CGFloat(index % 4), y: y + 0.4))
                            context.stroke(fibre, with: .color(LyraReaderTheme.accentBorder.opacity(0.055)), lineWidth: 0.5)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(LyraReaderTheme.accentBorder.opacity(contrast == .increased ? 0.8 : 0.28), lineWidth: 0.8)
            }
            .overlay(alignment: .bottomTrailing) {
                // A small turned corner, clear of the send button and transcript.
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 14))
                    path.addLine(to: CGPoint(x: 14, y: 0))
                    path.addLine(to: CGPoint(x: 14, y: 11))
                    path.addQuadCurve(to: CGPoint(x: 11, y: 14), control: CGPoint(x: 14, y: 14))
                    path.closeSubpath()
                }
                .fill(LyraReaderTheme.accentSoft)
                .overlay {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 14))
                        path.addQuadCurve(to: CGPoint(x: 14, y: 0), control: CGPoint(x: 10, y: 11))
                    }.stroke(LyraReaderTheme.accentBorder.opacity(0.3), lineWidth: 0.7)
                }
                .frame(width: 14, height: 14).padding(1)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.09), radius: 5, x: 0, y: 3)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
