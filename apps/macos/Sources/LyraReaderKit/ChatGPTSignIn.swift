import AppKit
import Combine
import CryptoKit
import Foundation
import Network
import Security

public enum AIConnectionMode: String, CaseIterable, Identifiable {
    case apiKey, chatGPT
    public var id: String { rawValue }
    public var title: String { self == .chatGPT ? "ChatGPT plan" : "API key" }
}

/// Official public-client SIWC flow. Tokens stay in the Keychain; no Codex credentials or
/// ChatGPT backend endpoints are read. Protocol: developers.openai.com/siwc/token-sharing-open-source.
@MainActor
public final class ChatGPTAccountStore: ObservableObject {
    public struct Account: Codable, Identifiable, Equatable {
        public let id: UUID
        public let clientID: String
        public let subject: String
        public let email: String
        public let label: String
        public var connected: Bool
        public var model: String
    }
    public struct Model: Identifiable, Equatable {
        public let id: String
        public let name: String
    }
    struct Credential: Codable {
        var accessToken: String
        var refreshToken: String
        var idToken: String
        var expiresAt: Date
        var scopes: [String]
    }

    @Published public private(set) var accounts: [Account]
    @Published public private(set) var selectedID: UUID?
    @Published public private(set) var models: [Model] = []
    @Published public private(set) var isSigningIn = false
    @Published public private(set) var isSigningOut = false
    @Published public private(set) var isLoadingModels = false
    @Published public private(set) var message: String?
    public var selected: Account? { accounts.first { $0.id == selectedID } }
    public var isConnected: Bool { selected?.connected == true && !isSigningOut }
    public static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!
    static let resource = "https://api.openai.com/v1"
    static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    private let defaults: UserDefaults
    private let vault: any AIAPIKeyStore
    package let session: URLSession
    private let openBrowser: (URL) -> Bool
    private var loginTask: Task<Void, Never>?
    private var refreshTasks: [UUID: Task<Credential, Error>] = [:]
    private var activeRequests: [UUID: () -> Void] = [:]
    private var epoch = 0

    public init(defaults: UserDefaults = .standard,
                vault: any AIAPIKeyStore = KeychainAPIKeyStore(account: "chatgpt-plan-credentials"),
                session: URLSession = URLSession(configuration: .ephemeral),
                openBrowser: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.defaults = defaults
        self.vault = vault
        self.session = session
        self.openBrowser = openBrowser
        accounts = defaults.data(forKey: "chatGPTAccounts").flatMap {
            try? JSONDecoder().decode([Account].self, from: $0)
        } ?? []
        selectedID = defaults.string(forKey: "chatGPTSelectedAccount").flatMap(UUID.init(uuidString:))
    }

    public func select(_ id: UUID) {
        guard accounts.contains(where: { $0.id == id }), selectedID != id else { return }
        invalidateRequests()
        selectedID = id; models = []; message = nil; persistMetadata()
    }

    public func setModel(_ id: String) {
        guard models.contains(where: { $0.id == id }),
              let index = accounts.firstIndex(where: { $0.id == selectedID }) else { return }
        accounts[index].model = id; persistMetadata()
    }

    /// No network or browser is touched until the user presses Continue with ChatGPT.
    public func signIn(addAccount: Bool = false) {
        guard !isSigningIn, !isSigningOut else { return }
        let returning = addAccount ? nil : selected
        isSigningIn = true; message = nil
        loginTask = Task {
            do {
                let pending = try ChatGPTAuthorization(hostID: hostID(), returning: returning,
                    registeredClientID: returning == nil ? defaults.string(forKey: "chatGPTPendingClientID") : nil)
                let callback = try await pending.authorize(open: openBrowser)
                let clientID = try pending.clientID(from: callback)
                // Retain the issued ID if exchange/consent fails; a retry must not register
                // another client. This pending ID is never an active or trusted identity.
                if returning == nil { defaults.set(clientID, forKey: "chatGPTPendingClientID") }
                var fields = ["grant_type": "authorization_code", "client_id": clientID,
                              "code": callback["code"] ?? "", "code_verifier": pending.verifier,
                              "redirect_uri": pending.redirectURI, "resource": Self.resource]
                defer { fields.removeAll() }
                let payload = try await tokenRequest(fields)
                guard let idToken = payload["id_token"] as? String else { throw failure("Sign-in returned no identity token.") }
                let identity = try await ChatGPTIdentity.verify(idToken, clientID: clientID, nonce: pending.nonce, session: session)
                if let returning, returning.subject != identity.subject {
                    throw failure("The signed-in account does not match the selected connection. Use Add Account instead.")
                }
                let credential = try Self.credential(payload)
                guard credential.scopes.contains("chatgpt.tokens.use.direct"), credential.scopes.contains("resource.invoke") else {
                    throw failure("ChatGPT plan usage was not enabled. Continue with ChatGPT again and approve plan usage.")
                }
                try Task.checkCancellation()
                let existing = accounts.first { $0.clientID == clientID && $0.subject == identity.subject }
                let id = existing?.id ?? UUID()
                let account = Account(id: id, clientID: clientID, subject: identity.subject,
                                      email: identity.email, label: existing?.label ?? "Connection \(accounts.count + 1)",
                                      connected: true, model: existing?.model ?? "")
                try saveCredential(credential, id: id)
                invalidateRequests()
                if let index = accounts.firstIndex(where: { $0.id == id }) { accounts[index] = account }
                else { accounts.append(account) }
                selectedID = id; models = []; persistMetadata()
                if defaults.string(forKey: "chatGPTPendingClientID") == clientID {
                    defaults.removeObject(forKey: "chatGPTPendingClientID")
                }
                message = "ChatGPT plan usage is enabled."
                await loadModels()
            } catch is CancellationError {
                message = "Sign-in cancelled."
            } catch {
                message = AIReadableError.message(error)
            }
            isSigningIn = false; loginTask = nil
        }
    }

    public func cancelSignIn() { loginTask?.cancel() }

    public func loadModels() async {
        guard let account = selected, account.connected, !isLoadingModels else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let token = try await accessToken(for: account.id)
            var request = URLRequest(url: URL(string: Self.resource + "/models")!)
            request.timeoutInterval = 30
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            try Self.check(response)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = object["models"] as? [[String: Any]] else { throw failure("ChatGPT returned an invalid model catalog.") }
            guard selectedID == account.id else { return }
            models = items.compactMap {
                guard $0["visibility"] as? String == "list", let slug = $0["slug"] as? String,
                      let name = $0["display_name"] as? String else { return nil }
                return Model(id: slug, name: name)
            }
            if !models.contains(where: { $0.id == selected?.model }), let first = models.first { setModel(first.id) }
            if models.isEmpty { message = "No eligible models were returned for this account." }
        } catch { if selectedID == account.id { message = AIReadableError.message(error) } }
    }

    public func signOut() async {
        guard let account = selected, !isSigningOut else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        cancelSignIn(); invalidateRequests()
        // Let an in-flight rotation finish before revoking its replacement refresh token.
        if let task = refreshTasks[account.id] { _ = try? await task.value }
        var revoked = false
        do {
            if let credential = try credentials()[account.id.uuidString] {
                let discovery = try await ChatGPTIdentity.discovery(session: session)
                guard let endpoint = discovery["revocation_endpoint"] as? String,
                      let url = URL(string: endpoint), url.scheme == "https", url.host == "auth.openai.com" else {
                    throw failure("The sign-out endpoint is unavailable.")
                }
                var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 20
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = ChatGPTAuthorization.form(["token": credential.refreshToken,
                    "token_type_hint": "refresh_token", "client_id": account.clientID])
                let (_, response) = try await session.data(for: request)
                try Self.check(response); revoked = true
            } else { revoked = true }
        } catch { /* Clear locally below and report unconfirmed remote revocation. */ }
        do {
            var all = try credentials(); all.removeValue(forKey: account.id.uuidString)
            try writeCredentials(all)
            if let index = accounts.firstIndex(where: { $0.id == account.id }) { accounts[index].connected = false }
            models = []; persistMetadata()
            message = revoked ? "Signed out." : "Signed out locally. Remote revocation was not confirmed; disconnect LyraReader in ChatGPT Settings > Usage."
        } catch { message = "Could not clear ChatGPT credentials from the Keychain. Please try signing out again." }
    }

    func registerRequest(_ id: UUID, cancel: @escaping () -> Void) { activeRequests[id] = cancel }
    func unregisterRequest(_ id: UUID) { activeRequests.removeValue(forKey: id) }
    private func invalidateRequests() {
        epoch += 1
        let actions = Array(activeRequests.values); activeRequests.removeAll()
        actions.forEach { $0() }
    }

    func accessToken(for id: UUID) async throws -> String {
        guard !isSigningOut, selectedID == id, let account = selected, account.connected,
              let credential = try credentials()[id.uuidString] else { throw failure("Sign in with ChatGPT in Settings > AI first.") }
        if credential.expiresAt.timeIntervalSinceNow > 60 { return credential.accessToken }
        if let running = refreshTasks[id] { return try await running.value.accessToken }
        let currentEpoch = epoch
        let task = Task<Credential, Error> {
            let payload = try await tokenRequest(["grant_type": "refresh_token", "client_id": account.clientID,
                "refresh_token": credential.refreshToken, "resource": Self.resource])
            let replacement = try Self.credential(payload, previous: credential)
            guard replacement.scopes.contains("chatgpt.tokens.use.direct"), replacement.scopes.contains("resource.invoke") else {
                throw failure("ChatGPT plan permission is no longer enabled. Sign in again.")
            }
            // Persist the rotation even if a different account has since been selected.
            try saveCredential(replacement, id: id)
            return replacement
        }
        refreshTasks[id] = task
        defer { refreshTasks[id] = nil }
        let refreshed = try await task.value
        guard epoch == currentEpoch, selectedID == id else { throw CancellationError() }
        return refreshed.accessToken
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = ChatGPTAuthorization.form(fields)
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw failure("ChatGPT returned an invalid token response.")
        }
        return payload
    }

    private static func credential(_ payload: [String: Any], previous: Credential? = nil) throws -> Credential {
        guard let access = payload["access_token"] as? String, !access.isEmpty,
              let refresh = payload["refresh_token"] as? String, !refresh.isEmpty,
              let expiry = payload["expires_in"] as? Double, expiry > 0,
              (payload["token_type"] as? String)?.lowercased() == "bearer" else {
            throw failure("ChatGPT returned incomplete credentials. Please sign in again.")
        }
        let scopes = (payload["scope"] as? String)?.split(separator: " ").map(String.init) ?? previous?.scopes ?? []
        return Credential(accessToken: access, refreshToken: refresh,
                          idToken: payload["id_token"] as? String ?? previous?.idToken ?? "",
                          expiresAt: Date().addingTimeInterval(expiry), scopes: scopes)
    }

    static func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let detail: String
            switch code {
            case 401: detail = "Your ChatGPT session expired. Sign in again."
            case 403: detail = "ChatGPT plan usage is unavailable or was not authorized for LyraReader. Check your plan and app permissions."
            case 429: detail = "The ChatGPT usage limit was reached. Review your usage in ChatGPT Settings."
            default: detail = "ChatGPT request failed (HTTP \(code)). Please try again."
            }
            throw failure(detail)
        }
    }

    private func hostID() -> String {
        if let saved = defaults.string(forKey: "chatGPTHostID") { return saved }
        let id = "urn:uuid:" + UUID().uuidString.lowercased()
        defaults.set(id, forKey: "chatGPTHostID"); return id
    }
    private func credentials() throws -> [String: Credential] {
        guard let text = try vault.readKey() else { return [:] }
        return try JSONDecoder().decode([String: Credential].self, from: Data(text.utf8))
    }
    private func saveCredential(_ credential: Credential, id: UUID) throws {
        var all = try credentials(); all[id.uuidString] = credential; try writeCredentials(all)
    }
    private func writeCredentials(_ all: [String: Credential]) throws {
        if all.isEmpty { try vault.deleteKey() }
        else { try vault.saveKey(String(decoding: JSONEncoder().encode(all), as: UTF8.self)) }
    }
    private func persistMetadata() {
        defaults.set(try? JSONEncoder().encode(accounts), forKey: "chatGPTAccounts")
        defaults.set(selectedID?.uuidString, forKey: "chatGPTSelectedAccount")
    }
}

private func failure(_ text: String) -> AISettingsError { .invalid(text) }

/// One short-lived OAuth transaction. Bind only to loopback, validate state before consuming a
/// code, cap request size, and close the listener on completion, timeout, or cancellation.
@MainActor
package final class ChatGPTAuthorization {
    let state: String
    let nonce: String
    let verifier: String
    private let hostID: String
    private let returning: ChatGPTAccountStore.Account?
    private let registeredClientID: String?
    private(set) var redirectURI = ""
    private var listener: NWListener?
    private var ready: CheckedContinuation<UInt16, Error>?
    private var callback: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?
    private var timeout: Task<Void, Never>?

    package init(hostID: String, returning: ChatGPTAccountStore.Account?, registeredClientID: String? = nil) throws {
        self.hostID = hostID; self.returning = returning
        self.registeredClientID = registeredClientID
        state = try Self.random(); nonce = try Self.random(); verifier = try Self.random()
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw failure("Could not create secure sign-in parameters.")
        }
        return base64URL(Data(bytes))
    }
    package nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(values.sorted(by: { $0.key < $1.key }).map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" +
            $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
    package func authorizationURL(port: UInt16) -> URL {
        redirectURI = "http://127.0.0.1:\(port)/auth/callback"
        var fields = ["client_id": returning?.clientID ?? registeredClientID ?? "dynamic_agent_client",
            "ext_agent_host_id": hostID, "response_type": "code", "redirect_uri": redirectURI,
            "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
            "resource": ChatGPTAccountStore.resource, "state": state, "nonce": nonce,
            "code_challenge_method": "S256", "code_challenge": Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))]
        if returning == nil && registeredClientID == nil { fields["agent_name_hint"] = "LyraReader" }
        if let returning, !returning.email.isEmpty { fields["login_hint"] = returning.email }
        var url = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        url.queryItems = fields.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }
    package func clientID(from values: [String: String]) throws -> String {
        guard values["state"] == state else { throw failure("Sign-in state did not match. Please try again.") }
        if values["error"] != nil { throw failure("ChatGPT sign-in was declined or cancelled.") }
        guard let code = values["code"], !code.isEmpty else { throw failure("The sign-in callback is incomplete.") }
        let expectedID = returning?.clientID ?? registeredClientID
        let id = values["client_id"] ?? expectedID
        guard let id, !id.isEmpty, id != "dynamic_agent_client" else { throw failure("ChatGPT did not issue a client registration.") }
        if let expectedID, expectedID != id { throw failure("ChatGPT returned a different client registration.") }
        return id
    }
    func authorize(open: (URL) -> Bool) async throws -> [String: String] {
        try await withTaskCancellationHandler {
            defer { listener?.cancel(); timeout?.cancel() }
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let server = try NWListener(using: params)
            listener = server
            server.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.receive(connection) }
            }
            server.stateUpdateHandler = { [weak self] status in
                Task { @MainActor in
                    guard let self else { return }
                    switch status {
                    case .ready:
                        if let port = self.listener?.port?.rawValue { self.ready?.resume(returning: port); self.ready = nil }
                    case .failed:
                        self.finish(.failure(failure("Could not start the local ChatGPT sign-in callback.")))
                    default: break
                    }
                }
            }
            let port = try await withCheckedThrowingContinuation { continuation in
                ready = continuation; server.start(queue: .main)
            }
            try Task.checkCancellation()
            guard open(authorizationURL(port: port)) else { throw failure("Could not open the browser for ChatGPT sign-in.") }
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(failure("ChatGPT sign-in timed out. Please try again.")))
            }
            return try await withCheckedThrowingContinuation { continuation in
                if let result { continuation.resume(with: result) } else { callback = continuation }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) } }
    }
    private func receive(_ connection: NWConnection, buffer: Data = Data()) {
        if buffer.isEmpty { connection.start(queue: .main) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var received = buffer; if let data { received.append(data) }
                guard received.count <= 8192, error == nil else { connection.cancel(); return }
                if !(received.range(of: Data("\r\n\r\n".utf8)) != nil) {
                    if !complete { self.receive(connection, buffer: received) } else { connection.cancel() }
                    return
                }
                let line = String(decoding: received, as: UTF8.self).components(separatedBy: "\r\n")[0]
                let parts = line.split(separator: " ")
                guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/auth/callback?"),
                      let url = URLComponents(string: "http://127.0.0.1" + parts[1]) else {
                    self.respond(connection, accepted: false); return
                }
                var values: [String: String] = [:]
                for item in url.queryItems ?? [] {
                    guard values[item.name] == nil else { self.respond(connection, accepted: false); return }
                    values[item.name] = item.value
                }
                guard values["state"] == self.state else { self.respond(connection, accepted: false); return }
                self.respond(connection, accepted: true)
                self.finish(.success(values))
            }
        }
    }
    private func respond(_ connection: NWConnection, accepted: Bool) {
        let body = accepted ? "Return to LyraReader to finish connecting your ChatGPT account." : "Invalid callback. Return to LyraReader and try again."
        let response = "HTTP/1.1 \(accepted ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
    private func finish(_ value: Result<[String: String], Error>) {
        guard result == nil else { return }
        result = value
        callback?.resume(with: value); callback = nil
        if case .failure(let error) = value { ready?.resume(throwing: error); ready = nil }
        listener?.cancel(); timeout?.cancel()
    }
}

/// Validate the signed OIDC identity before activating a registration. No identity is inferred
/// from an unverified JWT payload, email hint, or access token.
@MainActor
package enum ChatGPTIdentity {
    package struct Identity { package let subject: String; package let email: String }
    static func discovery(session: URLSession) async throws -> [String: Any] {
        let (data, response) = try await session.data(from: URL(string: "https://auth.openai.com/.well-known/openid-configuration")!)
        try ChatGPTAccountStore.check(response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["issuer"] as? String == "https://auth.openai.com" else { throw failure("Invalid ChatGPT identity configuration.") }
        return object
    }
    package static func verify(_ jwt: String, clientID: String, nonce: String, session: URLSession) async throws -> Identity {
        let pieces = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3, let headerData = decode(String(pieces[0])), let claimsData = decode(String(pieces[1])),
              let signature = decode(String(pieces[2])),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try JSONSerialization.jsonObject(with: claimsData) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String else {
            throw failure("Invalid ChatGPT identity token.")
        }
        let config = try await discovery(session: session)
        guard let uri = config["jwks_uri"] as? String, let url = URL(string: uri),
              url.scheme == "https", url.host == "auth.openai.com" else { throw failure("Invalid ChatGPT signing-key endpoint.") }
        let (data, response) = try await session.data(from: url)
        try ChatGPTAccountStore.check(response)
        guard let keys = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["keys"] as? [[String: Any]],
              let jwk = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }),
              let n = jwk["n"] as? String, let e = jwk["e"] as? String,
              let modulus = decode(n), let exponent = decode(e) else { throw failure("ChatGPT's signing key was not found.") }
        let der = element(0x30, integer(modulus) + integer(exponent))
        let attributes = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                          kSecAttrKeyClass as String: kSecAttrKeyClassPublic] as CFDictionary
        guard let key = SecKeyCreateWithData(der as CFData, attributes, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                Data("\(pieces[0]).\(pieces[1])".utf8) as CFData, signature as CFData, nil) else {
            throw failure("ChatGPT identity signature could not be verified.")
        }
        return try validateClaims(claims, clientID: clientID, nonce: nonce)
    }
    package static func validateClaims(_ claims: [String: Any], clientID: String, nonce: String, now: Date = Date()) throws -> Identity {
        let audience = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard claims["iss"] as? String == "https://auth.openai.com", audience.contains(clientID),
              claims["nonce"] as? String == nonce, let expiry = claims["exp"] as? Double, expiry > now.timeIntervalSince1970,
              let subject = claims["sub"] as? String, !subject.isEmpty,
              (claims["azp"] as? String).map({ $0 == clientID }) ?? (audience.count == 1) else {
            throw failure("ChatGPT identity validation failed. Please sign in again.")
        }
        if let issued = claims["iat"] as? Double, issued > now.timeIntervalSince1970 + 60 {
            throw failure("ChatGPT identity token has an invalid issue time.")
        }
        return Identity(subject: subject, email: claims["email"] as? String ?? "ChatGPT account")
    }
    private static func decode(_ value: String) -> Data? {
        var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text)
    }
    private static func integer(_ bytes: Data) -> Data {
        var value = bytes
        while value.count > 1 && value.first == 0 { value.removeFirst() }
        if (value.first ?? 0) >= 0x80 { value.insert(0, at: 0) }
        return element(0x02, value)
    }
    private static func element(_ tag: UInt8, _ value: Data) -> Data {
        var length = value.count
        var encoded: [UInt8] = []
        if length < 128 { encoded = [UInt8(length)] }
        else {
            while length > 0 { encoded.insert(UInt8(length & 255), at: 0); length >>= 8 }
            encoded.insert(0x80 | UInt8(encoded.count), at: 0)
        }
        return Data([tag] + encoded) + value
    }
}
