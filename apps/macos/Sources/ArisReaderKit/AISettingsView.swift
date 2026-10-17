import SwiftUI

/// Settings > AI. The read/write rules are in `AISettingsStore`; this view is only the form.
public struct AISettingsView: View {
    @ObservedObject private var store: AISettingsStore
    @State private var baseURL = ""
    @State private var model = ""
    @State private var temperature = AISettingsStore.defaultTemperature
    @State private var maxTokens = AISettingsStore.defaultMaxTokens
    @State private var keyDraft = ""
    @State private var savedMessage: String?

    public init(store: AISettingsStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    public var body: some View {
        Form {
            Section {
                TextField("Base URL", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Model", text: $model)
                    .textFieldStyle(.roundedBorder)
                Text("Examples: https://api.openai.com/v1, https://api.deepseek.com/v1, or http://localhost:11434/v1 for Ollama. Lyra appends /chat/completions; do not include it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let endpoint = store.endpointInfo {
                    Label(
                        endpoint.isLocal
                            ? "Local endpoint: page text stays on this Mac."
                            : "Remote endpoint: page text leaves this Mac when you send a request.",
                        systemImage: endpoint.isLocal ? "desktopcomputer" : "network"
                    )
                    .font(.caption)
                    .foregroundStyle(endpoint.isLocal ? Color.green : Color.orange)
                }
            } header: {
                Text("Provider (OpenAI-compatible)")
            } footer: {
                Text("Only the OpenAI-compatible chat-completions schema is implemented. No vendor SDK is used.")
            }

            Section {
                HStack(spacing: 6) {
                    Image(systemName: store.hasKey ? "key.fill" : "key")
                        .foregroundStyle(store.hasKey ? Color.green : Color.secondary)
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
                Text("The key is stored only in the macOS Keychain. It is never written to UserDefaults, a file, the request preview, or a log. Lyra reads it only when you press Send in the AI panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    Text("Temperature")
                    Slider(value: $temperature, in: 0...2, step: 0.1)
                    Text(String(format: "%.1f", temperature))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
                Stepper("Max tokens: \(maxTokens)", value: $maxTokens, in: 64...8192, step: 64)
                Text("These are sent as temperature and max_tokens. A provider may ignore or cap them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Generation")

            }

            if let message = savedMessage ?? store.invalidSettingsMessage {
                Section {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(message == "Saved." || message.hasPrefix("The API key was removed")
                                         ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    private func load() {
        baseURL = store.baseURL
        model = store.model
        temperature = store.temperature
        maxTokens = store.maxTokens
        keyDraft = ""
        savedMessage = nil
    }

    private func save() {
        let succeeded = store.save(
            baseURL: baseURL,
            model: model,
            temperature: temperature,
            maxTokens: maxTokens,
            apiKey: keyDraft
        )
        if succeeded {
            keyDraft = ""
            savedMessage = "Saved."
        } else {
            savedMessage = store.invalidSettingsMessage
        }
    }
}
