import AppKit
import SwiftUI

/// The AI panel's "Region questions" section.
///
/// Finished conversations are kept here for the window's session, newest first. Selecting one
/// shows the full question and answer in the panel (never by tearing the page again), with
/// "ask again here" and delete. The header states plainly that history is not written next to
/// the PDF and is not restored after relaunch.
struct AIRegionHistoryView: View {
    @ObservedObject var state: AppState
    @ObservedObject var aiAssistant: AIAssistantModel
    @State private var selectedID: UUID?

    private var entries: [AIRegionHistoryEntry] {
        state.currentRegionHistory.sorted { $0.createdAt > $1.createdAt }
    }

    private var selected: AIRegionHistoryEntry? {
        guard let selectedID else { return nil }
        return entries.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(LyraReaderTheme.separator)
            if let selected {
                detail(selected)
            } else if entries.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LyraReaderTheme.panelBg)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label("Region questions", systemImage: "rectangle.dashed")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    state.presentRegionHistoryExportPanel()
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .disabled(!state.hasExportableRegionHistory)
                .help(state.hasExportableRegionHistory
                      ? "Write one Markdown knowledge document with its pictures beside it"
                      : (AIRegionMarkdownExport.refusalReason(for: entries)
                         ?? "No answered conversations to export yet."))
                Button {
                    state.bringRegionSelectionForward()
                } label: {
                    Label("New", systemImage: "plus")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .disabled(!state.canArmRegionSelection)
                .help(state.regionSelectionUnavailableReason
                      ?? "Arm a region selection; the card opens below it")
            }
            Text("\(entries.count) kept · most recent \(AppState.regionHistoryLimit) per document. Kept for this session in this window: nothing is written next to the PDF and history is not restored after relaunch.")
                .font(.caption2)
                .foregroundStyle(LyraReaderTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(LyraReaderTheme.textTertiary)
            Text("No region questions yet")
                .font(.callout)
                .foregroundStyle(LyraReaderTheme.textSecondary)
            Text("Use the dashed-rectangle button in the toolbar, then drag over any part of the page. The question opens in a gap below the selection, not over it.")
                .font(.caption)
                .foregroundStyle(LyraReaderTheme.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Ask about a region") { state.bringRegionSelectionForward() }
                .disabled(!state.canArmRegionSelection)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(22)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(entries) { entry in
                    row(entry)
                }
            }
            .padding(10)
        }
    }

    private func row(_ entry: AIRegionHistoryEntry) -> some View {
        Button {
            selectedID = entry.id
        } label: {
            HStack(alignment: .top, spacing: 8) {
                if let image = NSImage(data: entry.attachment.png) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 58, height: 42)
                        .clipped()
                        .background(LyraReaderTheme.canvasBg)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(LyraReaderTheme.separator, lineWidth: 0.5))
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("Page \(entry.attachment.page + 1) · \(entry.attachment.sizeLabel)")
                            .font(.caption2.weight(.semibold))
                        if !entry.hasAnswer {
                            Text(entry.state == .cancelled ? "cancelled" : "no answer")
                                .font(.caption2)
                                .foregroundStyle(LyraReaderTheme.warningFg)
                        }
                        Spacer(minLength: 0)
                        Text(entry.timeLabel)
                            .font(.caption2)
                            .foregroundStyle(LyraReaderTheme.textTertiary)
                    }
                    Text(entry.question)
                        .font(.caption)
                        .foregroundStyle(LyraReaderTheme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(entry.hasAnswer ? entry.answerPreview : "No answer was produced.")
                        .font(.caption2)
                        .foregroundStyle(LyraReaderTheme.textTertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(7)
            .background(LyraReaderTheme.raisedBg, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(LyraReaderTheme.separator, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func detail(_ entry: AIRegionHistoryEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Button {
                        selectedID = nil
                    } label: {
                        Label("All region questions", systemImage: "chevron.left")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text(entry.timeLabel)
                        .font(.caption2)
                        .foregroundStyle(LyraReaderTheme.textTertiary)
                }
                if let image = NSImage(data: entry.attachment.png) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 150)
                        .frame(maxWidth: .infinity)
                        .background(LyraReaderTheme.canvasBg)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(LyraReaderTheme.separator, lineWidth: 0.5))
                }
                Text("Page \(entry.attachment.page + 1) · \(entry.attachment.sizeLabel) · \(entry.attachment.pixelLabel) · \(entry.attachment.characterCount.formatted()) text characters")
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.textSecondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Question")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(LyraReaderTheme.textSecondary)
                    Text(entry.question)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Answer")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(LyraReaderTheme.textSecondary)
                        Spacer()
                        if entry.hasAnswer {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.answer, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10.5))
                            }
                            .buttonStyle(.plain)
                            .help("Copy the Markdown source, including $…$ mathematics")
                        }
                    }
                    if entry.hasAnswer {
                        AIAnswerView(
                            text: entry.answer,
                            pageCount: state.document?.pageCount ?? 0,
                            verifiedPages: [entry.attachment.page + 1],
                            onJump: { page in state.gotoPage(page - 1) }
                        )
                    } else {
                        Text(entry.state == .cancelled
                             ? "The request was cancelled before an answer arrived."
                             : "The request failed: \(entry.error ?? "no error text was reported")")
                            .font(.caption)
                            .foregroundStyle(LyraReaderTheme.warningFg)
                            .fixedSize(horizontal: false, vertical: true)
                        if let failure = entry.failure,
                           let hint = AIOfflineHint.forFailure(failure) {
                            AIOfflineHintView(hint: hint)
                        }
                    }
                    if !entry.citedPages.isEmpty {
                        Text("Citations: " + entry.citedPages.map { "[p.\($0)]" }.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(LyraReaderTheme.textTertiary)
                    }
                }
                HStack(spacing: 8) {
                    Button("Ask again here") {
                        state.reopenRegionCard(from: entry)
                        selectedID = nil
                    }
                    .buttonStyle(ReaderPanelButtonStyle(prominent: true))
                    Button("Open in chat") {
                        guard let context = state.aiReaderContext else { return }
                        aiAssistant.importConversation(
                            question: entry.question,
                            answer: entry.answer,
                            attachment: entry.attachment,
                            context: context
                        )
                    }
                    .buttonStyle(ReaderPanelButtonStyle())
                    .disabled(!entry.hasAnswer)
                    Button(role: .destructive) {
                        state.deleteRegionHistoryEntry(id: entry.id)
                        selectedID = nil
                    } label: {
                        Text("Delete")
                    }
                    .buttonStyle(ReaderPanelButtonStyle())
                }
                Text("History is in memory for this session. Ask again re-opens the card at the same region without re-capturing it; nothing here is a PDF annotation.")
                    .font(.caption2)
                    .foregroundStyle(LyraReaderTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        }
    }
}
