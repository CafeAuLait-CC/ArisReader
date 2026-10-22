import SwiftUI

/// Settings > AI. The read/write rules are in `AISettingsStore`; this view is only the form.
public struct AISettingsView: View {
    @ObservedObject private var store: AISettingsStore
    @ObservedObject private var route = AISettingsRoute.shared
    @FocusState private var baseURLFocused: Bool
    @State private var baseURL = ""
    @State private var model = ""
    @State private var temperature = AISettingsStore.defaultTemperature
    @State private var maxTokens = AISettingsStore.defaultMaxTokens
    @State private var reasoningMode = AISettingsStore.defaultReasoningMode
    @State private var reasoningEncoding = AISettingsStore.defaultReasoningEncoding
    @State private var modelAcceptsImages = AISettingsStore.defaultModelAcceptsImages
    @State private var keyDraft = ""
    @State private var savedMessage: String?

    public init(store: AISettingsStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    public var body: some View {
        Form {
            Section("Connection") {
                Picker("Use AI with", selection: $store.connectionMode) {
                    ForEach(AIConnectionMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
            }
            if store.connectionMode == .chatGPT {
                ChatGPTConnectionView(accounts: store.chatGPT)
            } else {
            Section {
                TextField("Base URL", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .focused($baseURLFocused)
                TextField("Model", text: $model)
                    .textFieldStyle(.roundedBorder)
                Text("Examples: https://api.openai.com/v1, https://api.deepseek.com/v1, or http://localhost:11434/v1 for Ollama. LyraReader appends /chat/completions; do not include it here.")
                    .font(.caption)
                    .foregroundStyle(LyraReaderTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let endpoint = store.endpointInfo {
                    Label(
                        endpoint.isLocal
                            ? "Local endpoint: page text stays on this Mac."
                            : "Remote endpoint: page text leaves this Mac when you send a request.",
                        systemImage: endpoint.isLocal ? "desktopcomputer" : "network"
                    )
                    .font(.caption)
                    .foregroundStyle(endpoint.isLocal ? LyraReaderTheme.successFg : LyraReaderTheme.warningFg)
                }
            } header: {
                Text("Provider (OpenAI-compatible)")
            } footer: {
                Text("Only the OpenAI-compatible chat-completions schema is implemented. No vendor SDK is used.")
            }

            Section {
                HStack(spacing: 6) {
                    Image(systemName: store.hasKey ? "key.fill" : "key")
                        .foregroundStyle(store.hasKey ? LyraReaderTheme.successFg : Color.secondary)
                    Text(store.hasKey ? "A key is configured in the Keychain." : "No key is configured.")
                        .font(.callout)
                }
                SecureField(store.hasKey ? "New API key (leave blank to keep the current key)" : "API key", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Clear Key") {
                        if store.clearKey() {
                            keyDraft = ""
                            savedMessage = "The API key was removed from the Keychain."
                        } else {
                            savedMessage = store.invalidSettingsMessage
                        }
                    }
                    .disabled(!store.hasKey)
                    Spacer()
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                }
            } header: {
                Text("API key")
            } footer: {
                Text("The key is stored only in the macOS Keychain. It is never written to UserDefaults, a file, the request preview, or a log. LyraReader reads it only when you press Send in the AI panel.")
                    .font(.caption)
                    .foregroundStyle(LyraReaderTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Model accepts image input (vision)", isOn: $modelAcceptsImages)
                Text(modelAcceptsImages
                     ? "Region questions send the selected rectangle as a PNG, plus its extracted text. The preview names the pixel size before you send."
                     : "Text-only configuration: region questions send the extracted text only. The picture is captured for the preview and the knowledge export, but it is not sent to the model.")
                    .font(.caption)
                    .foregroundStyle(LyraReaderTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Region pictures")
            } footer: {
                Text("LyraReader never guesses from the model name. Leave this off for a text-only model; turn it on only when the provider documents image input for the model above.")
                    .font(.caption)
                    .foregroundStyle(LyraReaderTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("Reasoning", selection: $reasoningMode) {
                    ForEach(AIReasoningMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("Encoding", selection: $reasoningEncoding) {
                    ForEach(AIReasoningEncoding.allCases) { encoding in
                        Text(encoding.title).tag(encoding)
                    }
                }
                Text(previewSettings.reasoningSummary)
                    .font(.caption)
                    .foregroundStyle(LyraReaderTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(previewSettings.reasoningFieldDescription)
                    .font(.caption)
                    .foregroundStyle(LyraReaderTheme.textSecondary)
                if let message = AISettingsStore.reasoningValidationMessage(
                    mode: reasoningMode,
                    encoding: reasoningEncoding
                ) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(LyraReaderTheme.errorFg)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Reasoning control")
            } footer: {
                Text("Plain OpenAI compatibility has no standard reasoning switch. This provider documents several encodings, so LyraReader sends exactly the one selected here and nothing else. The default is off via thinking, because it changes cost and latency. A strict provider may reject an encoding; the error will name the parameter and point back to this setting.")
                    .font(.caption)
                    .foregroundStyle(LyraReaderTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    Text("Temperature")
                    Slider(value: $temperature, in: 0...2, step: 0.1)
                    Text(String(format: "%.1f", temperature))
                        .monospacedDigit()
                        .foregroundStyle(LyraReaderTheme.textSecondary)
                        .frame(width: 30, alignment: .trailing)
                }
                Stepper("Max tokens: \(maxTokens)", value: $maxTokens, in: 64...8192, step: 64)
                Text("These are sent as temperature and max_tokens. A provider may ignore or cap them.")
                    .font(.caption)
                    .foregroundStyle(LyraReaderTheme.textSecondary)
            } header: {
                Text("Generation")

            }

            }
            if store.connectionMode == .apiKey, let message = savedMessage ?? store.invalidSettingsMessage {
                Section {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(message == "Saved." || message.hasPrefix("The API key was removed")
                                         ? Color.secondary : LyraReaderTheme.errorFg)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            load()
            focusBaseURLIfRequested()
        }
        .onChange(of: route.pendingBaseURLFocus) { _, pending in
            if pending { focusBaseURLIfRequested() }
        }
        .task(id: store.connectionMode) {
            if store.connectionMode == .chatGPT { await store.chatGPT.loadModels() }
        }
    }

    /// Consume a request from the offline hint. The field takes focus after the tab has been
    /// installed, so the reader can type a local URL immediately.
    private func focusBaseURLIfRequested() {
        guard route.pendingBaseURLFocus else { return }
        route.consumeBaseURLFocus()
        Task { @MainActor in
            baseURLFocused = true
        }
    }

    private func load() {
        baseURL = store.baseURL
        model = store.model
        temperature = store.temperature
        maxTokens = store.maxTokens
        reasoningMode = store.reasoningMode
        reasoningEncoding = store.reasoningEncoding
        modelAcceptsImages = store.modelAcceptsImages
        keyDraft = ""
        savedMessage = nil
    }

    private var previewSettings: AIProviderSettings {
        AIProviderSettings(
            baseURL: baseURL,
            model: model,
            temperature: temperature,
            maxTokens: maxTokens,
            reasoningMode: reasoningMode,
            reasoningEncoding: reasoningEncoding,
            vision: modelAcceptsImages
        )
    }

    private func save() {
        let succeeded = store.save(
            baseURL: baseURL,
            model: model,
            temperature: temperature,
            maxTokens: maxTokens,
            apiKey: keyDraft,
            reasoningMode: reasoningMode,
            reasoningEncoding: reasoningEncoding,
            modelAcceptsImages: modelAcceptsImages
        )
        if succeeded {
            keyDraft = ""
            savedMessage = "Saved."
        } else {
            savedMessage = store.invalidSettingsMessage
        }
    }
}
