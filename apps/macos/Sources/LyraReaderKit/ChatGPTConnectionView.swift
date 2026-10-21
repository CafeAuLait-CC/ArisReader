import SwiftUI

/// The same connection controls are reachable from Settings and the AI panel.
struct ChatGPTConnectionView: View {
    @ObservedObject var accounts: ChatGPTAccountStore

    var body: some View {
        Section("ChatGPT account") {
            Text("Connect your ChatGPT plan")
                .font(.headline)
            Text("Use an eligible ChatGPT plan for LyraReader's AI features. Approve plan usage in your browser; usage is shared with your plan and its limits. No API key is needed.")
                .font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !accounts.accounts.isEmpty {
                Picker("Connection", selection: Binding(
                    get: { accounts.selectedID },
                    set: { if let id = $0 { accounts.select(id) } }
                )) {
                    ForEach(accounts.accounts) { account in
                        Text("\(account.label) · \(account.email)").tag(Optional(account.id))
                    }
                }.disabled(accounts.isSigningIn || accounts.isSigningOut)
            }
            if accounts.isConnected {
                Label("ChatGPT plan usage is enabled", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(LyraReaderTheme.successFg).font(.callout)
                if !accounts.models.isEmpty {
                    Picker("Model", selection: Binding(
                        get: { accounts.selected?.model ?? "" }, set: { accounts.setModel($0) }
                    )) {
                        ForEach(accounts.models) { Text($0.name).tag($0.id) }
                    }
                }
                HStack {
                    Button("Refresh Models") { Task { await accounts.loadModels() } }
                        .disabled(accounts.isLoadingModels || accounts.isSigningOut)
                    if accounts.isLoadingModels { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Sign Out") { Task { await accounts.signOut() } }
                        .disabled(accounts.isSigningOut)
                }
            }
            HStack {
                if accounts.isSigningIn {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser…").font(.caption)
                    Button("Cancel") { accounts.cancelSignIn() }
                } else {
                    Button("Continue with ChatGPT") { accounts.signIn() }
                        .buttonStyle(.borderedProminent).tint(.black).foregroundStyle(.white)
                        .disabled(accounts.isSigningOut)
                    if !accounts.accounts.isEmpty {
                        Button("Add Account…") { accounts.signIn(addAccount: true) }
                            .disabled(accounts.isSigningOut)
                    }
                }
            }
            Link("Manage usage in ChatGPT", destination: ChatGPTAccountStore.usageURL)
            if let message = accounts.message {
                Text(message).font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
