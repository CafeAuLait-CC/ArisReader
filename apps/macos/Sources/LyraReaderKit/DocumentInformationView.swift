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
                    .buttonStyle(.borderedProminent).tint(LyraReaderTheme.accent)
            }.padding(18)
            Divider()
            DocumentInformationContent(state: state)
        }
        .frame(width: 600, height: 580)
        .onExitCommand { dismiss() }
        .background(LyraReaderTheme.panelBg).foregroundStyle(LyraReaderTheme.textPrimary).tint(LyraReaderTheme.accent)
    }
}

struct DocumentInformationContent: View {
    @ObservedObject var state: AppState
    var body: some View {
        metadataPanel
            .scrollContentBackground(.hidden)
            .background(LyraReaderTheme.panelBg)
            .onAppear { state.loadDocumentInfo() }
    }
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
                        .foregroundStyle(LyraReaderTheme.textTertiary)
                    Text("No document")
                        .font(.callout)
                        .foregroundStyle(LyraReaderTheme.textSecondary)
                    Text("Open a PDF to read and correct its title, authors, venue, year, DOI and arXiv id.")
                        .font(.caption)
                        .foregroundStyle(LyraReaderTheme.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else if state.metadataLoading {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading metadata…")
                        .font(.caption)
                        .foregroundStyle(LyraReaderTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure = state.metadataError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(LyraReaderTheme.warningFg)
                    Text("Metadata could not be read")
                        .font(.callout)
                        .foregroundStyle(LyraReaderTheme.textSecondary)
                    Text(failure)
                        .font(.caption2)
                        .foregroundStyle(LyraReaderTheme.textTertiary)
                        .lineLimit(4)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                List {
                    propertiesSection
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

    // MARK: - Document properties (/Info)

    /// The four entries the reader writes into the document's information dictionary, plus the
    /// facts it will not write: page count, PDF version and encryption. The recognized metadata
    /// below is a layout-based reading of the same file; this section is the file's own
    /// dictionary, and saving here does not regenerate BibTeX.
    @ViewBuilder
    private var propertiesSection: some View {
        Section {
            if state.documentInfoLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading document properties…")
                        .font(.caption)
                        .foregroundStyle(LyraReaderTheme.textSecondary)
                }
            } else {
                HStack(spacing: 18) {
                    fact("Pages", value: state.documentInfo.map { "\($0.pageCount)" }
                        ?? state.document.map { "\($0.pageCount)" } ?? "—")
                    fact("PDF version", value: state.documentInfo?.pdfVersion ?? "—")
                    fact("Encrypted", value: (state.documentInfo?.isEncrypted ?? false) ? "Yes" : "No")
                    Spacer(minLength: 0)
                }
                if let failure = state.documentInfoError {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(LyraReaderTheme.errorFg)
                }
                if let refusal = state.documentPropertiesRefusal {
                    Label(refusal, systemImage: "lock.doc")
                        .font(.caption)
                        .foregroundStyle(LyraReaderTheme.warningFg)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 2)
                }
                if state.documentPropertiesRefusal == nil {
                    ForEach(DocumentPropertyKey.allCases, id: \.self) { key in
                        propertyRow(key)
                    }
                    HStack(spacing: 10) {
                        Button {
                            state.presentSaveDocumentPropertiesPanel()
                        } label: {
                            Label("Save Copy…", systemImage: "square.and.arrow.down")
                        }
                        .disabled(!state.canSaveDocumentProperties)
                        Button {
                            state.presentReplaceOriginalWithPropertiesConfirmation()
                        } label: {
                            Label("Write to This File…", systemImage: "doc.badge.arrow.up")
                        }
                        .disabled(!state.canReplaceOriginalWithDocumentProperties)
                        .help(state.isReadOnlyDocument
                              ? (state.readOnlyReason ?? "Signed PDF · read-only in place")
                              : "Back up and replace the original file's information")
                        Spacer()
                        if state.documentPropertiesAreDirty {
                            Text("Unsaved")
                                .font(.caption2)
                                .foregroundStyle(LyraReaderTheme.warningFg)
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    if state.isReadOnlyDocument {
                        Text(
                            "Signed PDF: edits here can be saved to a copy. A modified copy "
                            + "has its signature fields removed, so it does not look signed."
                        )
                        .font(.caption2)
                        .foregroundStyle(LyraReaderTheme.warningFg)
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(
                            "Save Copy writes the entries into a new PDF and leaves this file "
                            + "untouched; Write to This File backs it up first and then replaces it. "
                            + "Changing the recognized metadata above does not write anything."
                        )
                        .font(.caption2)
                        .foregroundStyle(LyraReaderTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if state.documentInfo?.hasInfoDictionary == false {
                    Text("This PDF has no information dictionary yet; a save adds one.")
                        .font(.caption2)
                        .foregroundStyle(LyraReaderTheme.textTertiary)
                }
            }
        } header: {
            Text("Document properties in the PDF")
        }
    }

    private func fact(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(LyraReaderTheme.textTertiary)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private func propertyRow(_ key: DocumentPropertyKey) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key.label)
                .font(.caption)
                .fontWeight(.semibold)
            TextField(key.prompt, text: Binding(
                get: {
                    switch key {
                    case .title: return state.documentPropertiesDraft.title
                    case .author: return state.documentPropertiesDraft.author
                    case .subject: return state.documentPropertiesDraft.subject
                    case .keywords: return state.documentPropertiesDraft.keywords
                    }
                },
                set: { state.updateDocumentProperty(key, text: $0) }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .accessibilityLabel(key.label)
        }
        .padding(.vertical, 1)
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
                .foregroundStyle(LyraReaderTheme.textTertiary)
        } else if field.source == .edited {
            Text("Edited")
                .font(.caption2)
                .foregroundStyle(LyraReaderTheme.textSecondary)
        } else if field.guessed || field.source.isGuessed {
            Label(field.source.label, systemImage: "questionmark.circle")
                .font(.caption2)
                .foregroundStyle(LyraReaderTheme.warningFg)
        } else {
            Text(field.source.label)
                .font(.caption2)
                .foregroundStyle(field.source.isEmbedded ? Color.secondary : Color.blue)
        }
    }

}
