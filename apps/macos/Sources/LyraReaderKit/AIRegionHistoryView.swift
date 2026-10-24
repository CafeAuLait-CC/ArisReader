import AppKit
import SwiftUI

/// Durable reading conversations and editable distilled notes, scoped to the source document.
struct AIRegionHistoryView: View {
    @ObservedObject var state: AppState
    @ObservedObject var aiAssistant: AIAssistantModel
    @State private var selectedID: UUID?
    @State private var deletingID: UUID?
    private var entries: [AIRegionHistoryEntry] {
        state.currentRegionHistory.sorted { $0.createdAt > $1.createdAt }
    }
    private var selected: AIRegionHistoryEntry? { entries.first { $0.id == selectedID } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Reading notes").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { state.presentRegionHistoryExportPanel() } label: {
                    Image(systemName: "square.and.arrow.up")
                }.buttonStyle(.plain).disabled(!state.hasExportableRegionHistory)
                    .help("Export reading notes as Markdown").accessibilityLabel("Export reading notes")
                Button { state.bringRegionSelectionForward() } label: {
                    Image(systemName: "plus")
                }.buttonStyle(.plain).disabled(!state.canArmRegionSelection)
                    .help("Select a new region").accessibilityLabel("Select a new region")
            }.padding(.horizontal, 14).frame(height: 38)
            Divider().overlay(LyraReaderTheme.separator)
            if let selected {
                detail(selected)
            } else if entries.isEmpty {
                VStack(spacing: 10) {
                    LyraAIIcon().frame(width: 32, height: 32).foregroundStyle(LyraReaderTheme.accent)
                    Text("Keep the ideas you discover").font(.callout.weight(.medium))
                    Text("Choose Interleaf in the Lyra toolbar and draw over the page. Conversations and reading notes are saved locally.")
                        .font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Interleaf · Select & Ask") { state.bringRegionSelectionForward() }
                        .buttonStyle(ReaderPanelButtonStyle(prominent: true))
                        .disabled(!state.canArmRegionSelection)
                }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(entries) { entry in
                            Button { selectedID = entry.id } label: { row(entry) }.buttonStyle(.plain)
                        }
                    }.padding(10)
                }
                Text("Saved locally · \(entries.count) conversations")
                    .font(.caption2).foregroundStyle(LyraReaderTheme.textSecondary).padding(10)
            }
        }.foregroundStyle(LyraReaderTheme.textPrimary).background(LyraReaderTheme.panelBg)
        .confirmationDialog("Delete this conversation and its note?", isPresented: Binding(
            get: { deletingID != nil }, set: { if !$0 { deletingID = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let deletingID { state.deleteRegionHistoryEntry(id: deletingID) }
                    selectedID = nil; deletingID = nil
                }
                Button("Cancel", role: .cancel) { deletingID = nil }
            }
    }
    private func row(_ entry: AIRegionHistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let image = entry.attachment.thumbnail {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 52, height: 42).background(LyraReaderTheme.canvasBg)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Page \(entry.attachment.page + 1) · Region \(entry.regionNumber ?? 1)").font(.caption2.weight(.semibold))
                        .foregroundStyle(LyraReaderTheme.accent)
                    Spacer()
                    Text("\(entry.allTurns.count) turns").font(.caption2).foregroundStyle(LyraReaderTheme.textSecondary)
                }
                Text(entry.question.isEmpty ? (entry.draftQuestion?.isEmpty == false ? entry.draftQuestion! : "New region") : entry.question).font(.system(size: 12, weight: .medium)).lineLimit(2)
                if !entry.knowledgeNote.isEmpty {
                    Label("Reading note", systemImage: "note.text").font(.caption2)
                        .foregroundStyle(LyraReaderTheme.noteFg)
                }
                Text(entry.hasAnswer ? entry.answerPreview : "No answer yet")
                    .font(.caption2).foregroundStyle(LyraReaderTheme.textSecondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(10).background(LyraReaderTheme.raisedBg, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LyraReaderTheme.separator))
            .contentShape(Rectangle()).multilineTextAlignment(.leading)
    }
    private func detail(_ entry: AIRegionHistoryEntry) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { selectedID = nil } label: { Label("All notes", systemImage: "chevron.left") }
                    .buttonStyle(.plain)
                Spacer()
                Button { deletingID = entry.id } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).help("Delete conversation").accessibilityLabel("Delete conversation")
            }.font(.caption).padding(12)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if entry.locationInvalidated == true {
                        Text("Page layout changed · original selection preserved below")
                            .font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                        if !((entry.draftQuestion ?? "").isEmpty) { Text(entry.draftQuestion ?? "") }
                    } else if entry.attachment.page >= 0, entry.attachment.page < (state.document?.pageCount ?? 0) {
                        Button {
                            state.gotoPage(entry.attachment.page)
                        } label: { Label("Page \(entry.attachment.page + 1)", systemImage: "doc.text") }
                            .buttonStyle(.plain).foregroundStyle(LyraReaderTheme.accent)
                    } else {
                        Label("Original page is no longer in this PDF", systemImage: "doc.text")
                            .font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                    }
                    if !entry.knowledgeNote.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Label("Reading note", systemImage: "note.text").font(.caption.weight(.semibold))
                                .foregroundStyle(LyraReaderTheme.noteFg)
                            answer(entry.knowledgeNote, entry: entry)
                        }.padding(10).background(LyraReaderTheme.noteBg, in: RoundedRectangle(cornerRadius: 7))
                    }
                    if entry.locationInvalidated == true {
                        DisclosureGroup("Original selection") {
                            if let image = entry.attachment.thumbnail {
                                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 180)
                            }
                            Text(entry.attachment.text).font(.caption).textSelection(.enabled)
                        }
                    }
                    ForEach(entry.allTurns) { turn in
                        Text(turn.question).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
                        if !turn.answer.isEmpty { answer(turn.answer, entry: entry) }
                        if let error = turn.error {
                            Text(error).font(.caption).foregroundStyle(LyraReaderTheme.errorFg)
                        }
                        Divider().overlay(LyraReaderTheme.separator)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            if entry.locationInvalidated != true {
            Button("Continue conversation") {
                if state.reopenRegionCard(from: entry) != nil {
                    state.rightPanelVisible = false; selectedID = nil
                }
            }.buttonStyle(ReaderPanelButtonStyle(prominent: true))
                .disabled(entry.attachment.page < 0 || entry.attachment.page >= (state.document?.pageCount ?? 0))
                .padding(12)
            }
        }
    }
    private func answer(_ text: String, entry: AIRegionHistoryEntry) -> some View {
        AIAnswerView(text: text, pageCount: state.document?.pageCount ?? 0,
                     verifiedPages: Set(entry.citedPages), onJump: { state.gotoPage($0 - 1) })
    }
}
