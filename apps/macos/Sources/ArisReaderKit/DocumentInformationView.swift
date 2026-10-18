import SwiftUI

struct DocumentInformationView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Document Information", systemImage: "info.circle").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(LyraTheme.accent)
            }.padding(18)
            Divider()
            DocumentInformationContent(state: state)
        }
        .frame(width: 600, height: 580)
        .onExitCommand { dismiss() }
        .background(LyraTheme.panelBg).foregroundStyle(LyraTheme.textPrimary).tint(LyraTheme.accent)
    }
}

struct DocumentInformationContent: View {
    @ObservedObject var state: AppState
    var body: some View { metadataPanel.scrollContentBackground(.hidden).background(LyraTheme.panelBg) }
    // MARK: - Metadata

    /// Title, authors, venue, year, DOI and arXiv id, each editable and each labelled with the
    /// source that produced it. An empty field stays empty; the note at the bottom says so, and
    /// the panel never fills a value from the filename or the file's creation date.
    private var metadataPanel: some View {
        Group {
            if state.document == nil {
                VStack(spacing: 10) {
                    Image(systemName: "text.badge.checkmark")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(LyraTheme.textTertiary)
                    Text("No document")
                        .font(.callout)
                        .foregroundStyle(LyraTheme.textSecondary)
                    Text("Open a PDF to read and correct its title, authors, venue, year, DOI and arXiv id.")
                        .font(.caption)
                        .foregroundStyle(LyraTheme.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else if state.metadataLoading {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading metadata…")
                        .font(.caption)
                        .foregroundStyle(LyraTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure = state.metadataError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(LyraTheme.warningFg)
                    Text("Metadata could not be read")
                        .font(.callout)
                        .foregroundStyle(LyraTheme.textSecondary)
                    Text(failure)
                        .font(.caption2)
                        .foregroundStyle(LyraTheme.textTertiary)
                        .lineLimit(4)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                List {
                    Section {
                        ForEach(MetadataFieldKey.allCases, id: \.self) { key in
                            metadataRow(key)
                        }
                    } header: {
                        Text("Found in this PDF")
                    } footer: {
                        if state.metadataIsEmpty() {
                            Text(
                                "No metadata was found. An empty field stays empty rather than "
                                + "being filled with a plausible-looking guess."
                            )
                        } else {
                            Text(
                                "“Guessed” fields come from the page layout. Correct anything "
                                + "that is wrong; edits regenerate the entry below."
                            )
                        }
                    }

                    Section("Generated BibTeX") {
                        Text(state.metadataBibtex)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 10) {
                            Button {
                                state.copyMetadataBibtex()
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .disabled(!state.canCopyMetadataBibtex)
                            Button {
                                state.presentSaveBibtexPanel()
                            } label: {
                                Label("Save…", systemImage: "square.and.arrow.down")
                            }
                            .disabled(!state.canCopyMetadataBibtex)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func metadataRow(_ key: MetadataFieldKey) -> some View {
        let field = state.metadata?.field(key) ?? .empty
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(key.label)
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer(minLength: 0)
                metadataBadge(field)
            }
            TextField(key.prompt, text: metadataBinding(key))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .accessibilityLabel(key.label)
        }
        .padding(.vertical, 2)
    }

    private func metadataBinding(_ key: MetadataFieldKey) -> Binding<String> {
        Binding(
            get: { state.metadataDraft.text(for: key) },
            set: { state.updateMetadata(key, text: $0) }
        )
    }

    @ViewBuilder
    private func metadataBadge(_ field: MetadataField) -> some View {
        if field.source == .absent {
            Text("empty")
                .font(.caption2)
                .foregroundStyle(LyraTheme.textTertiary)
        } else if field.source == .edited {
            Text("Edited")
                .font(.caption2)
                .foregroundStyle(LyraTheme.textSecondary)
        } else if field.guessed || field.source.isGuessed {
            Label(field.source.label, systemImage: "questionmark.circle")
                .font(.caption2)
                .foregroundStyle(LyraTheme.warningFg)
        } else {
            Text(field.source.label)
                .font(.caption2)
                .foregroundStyle(field.source.isEmbedded ? Color.secondary : Color.blue)
        }
    }

}
