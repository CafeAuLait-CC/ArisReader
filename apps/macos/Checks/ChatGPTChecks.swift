import AppKit
import ArisReaderBindings
import ArisReaderKit
import CryptoKit
import Foundation
import Security

/// All HTTP responses are synthetic. These checks never log into an account or use plan quota.
private final class ChatGPTStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var route: (@Sendable (URLRequest) throws -> (Int, Data, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data, type) = try Self.route!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": type])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

extension ReaderChecks {
    @MainActor static func chatGPTChecks(root: URL) async throws {
        func rejects(_ title: String, _ body: () throws -> Void) {
            do { try body(); require(false, title) } catch { require(true, title) }
        }
        func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
        func base64(_ data: Data) -> String { ChatGPTAuthorization.base64URL(data) }
        func params(_ url: URL) -> [String: String] {
            Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        }
        let authorization = try ChatGPTAuthorization(hostID: "urn:uuid:test-host", returning: nil)
        let url = authorization.authorizationURL(port: 1455)
        let query = params(url)
        require(url.host == "auth.openai.com" && query["client_id"] == "dynamic_agent_client",
                "first sign-in uses the official dynamic registration endpoint")
        require(query["agent_name_hint"] == "Lyra" && query["redirect_uri"] == "http://127.0.0.1:1455/auth/callback",
                "Lyra identifies itself and uses an exact loopback callback")
        require(query["scope"]?.contains("chatgpt.tokens.use.direct") == true && query["code_challenge_method"] == "S256",
                "ChatGPT plan permission and PKCE are requested explicitly")
        rejects("a callback with the wrong state cannot be exchanged") {
            _ = try authorization.clientID(from: ["state": "wrong", "code": "x", "client_id": "oaiapp_test"])
        }
        rejects("an unissued dynamic client ID cannot be saved") {
            _ = try authorization.clientID(from: ["state": query["state"]!, "code": "x", "client_id": "dynamic_agent_client"])
        }
        rejects("a denied OAuth callback cannot be exchanged") {
            _ = try authorization.clientID(from: ["state": query["state"]!, "error": "access_denied"])
        }
        let retry = try ChatGPTAuthorization(hostID: "urn:uuid:test-host", returning: nil, registeredClientID: "oaiapp_retry")
        let retryQuery = params(retry.authorizationURL(port: 54321))
        require(retryQuery["client_id"] == "oaiapp_retry" && retryQuery["agent_name_hint"] == nil,
                "retrying an incomplete registration reuses its issued client ID")
        let retryID = try retry.clientID(from: ["state": retryQuery["state"]!, "code": "fresh-code"])
        require(retryID == "oaiapp_retry", "returning callbacks may omit the already-bound client ID")
        rejects("a returning callback cannot substitute another client ID") {
            _ = try retry.clientID(from: ["state": retryQuery["state"]!, "code": "fresh-code", "client_id": "oaiapp_wrong"])
        }
        var claims: [String: Any] = ["iss": "https://auth.openai.com", "aud": "oaiapp_test", "sub": "subject",
                                     "nonce": "nonce", "exp": Date().timeIntervalSince1970 + 3600]
        let identity = try ChatGPTIdentity.validateClaims(claims, clientID: "oaiapp_test", nonce: "nonce")
        require(identity.subject == "subject",
                "validated identity binds the issued client ID and nonce")
        for (field, value) in [("iss", "https://example.invalid"), ("aud", "wrong"), ("nonce", "wrong")] {
            var bad = claims; bad[field] = value
            rejects("identity rejects the wrong \(field)") { _ = try ChatGPTIdentity.validateClaims(bad, clientID: "oaiapp_test", nonce: "nonce") }
        }
        claims["exp"] = 0
        rejects("expired identity tokens are rejected") { _ = try ChatGPTIdentity.validateClaims(claims, clientID: "oaiapp_test", nonce: "nonce") }
        for type in ["response.failed", "response.incomplete", "error"] {
            rejects("\(type) is not treated as a completed answer") {
                _ = try ChatGPTResponses.events(String(decoding: json(["type": type]), as: UTF8.self))
            }
        }
        var decoder = ChatGPTEventDecoder()
        var decoded: [String] = []
        for byte in Data(": comment\r\nevent: response\r\ndata: {\"type\":\"response.output_text.delta\",\r\ndata: \"delta\":\"你好\"}\r\n\r\n".utf8) {
            if let event = try decoder.push(byte) { decoded.append(event) }
        }
        require(decoded.count == 1 && decoded[0].contains("你好"),
                "SSE preserves blank boundaries, multiline data, CRLF, and split UTF-8")
        var partial = ChatGPTEventDecoder()
        var emittedPartial = false
        for byte in Data("data: {\"type\":\"response.completed\"}".utf8) {
            if try partial.push(byte) != nil { emittedPartial = true }
        }
        require(!emittedPartial, "an unterminated event cannot complete an interrupted stream")
        let quotaError = "{\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}}"
        do { _ = try ChatGPTResponses.events(quotaError); require(false, "usage limit must fail") }
        catch { require(AIReadableError.message(error).contains("usage limit"), "streamed subscription limits have an actionable error") }

        // Sign a real RS256 JWT with an ephemeral test key and serve its public JWKS locally.
        let key = SecKeyCreateRandomKey([kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                        kSecAttrKeySizeInBits as String: 2048] as CFDictionary, nil)!
        let publicKey = SecKeyCopyPublicKey(key)!
        let publicDER = SecKeyCopyExternalRepresentation(publicKey, nil)! as Data
        func readElement(_ bytes: [UInt8], _ offset: inout Int) -> [UInt8] {
            offset += 1
            var length = Int(bytes[offset]); offset += 1
            if length & 128 != 0 {
                let count = length & 127; length = 0
                for _ in 0..<count { length = length * 256 + Int(bytes[offset]); offset += 1 }
            }
            let value = Array(bytes[offset..<(offset + length)]); offset += length; return value
        }
        var offset = 0
        let sequence = readElement(Array(publicDER), &offset)
        offset = 0
        var modulus = readElement(sequence, &offset)
        while modulus.first == 0 { modulus.removeFirst() }
        let exponent = readElement(sequence, &offset)
        let jwks = try json(["keys": [["kty": "RSA", "kid": "lyra-test", "n": base64(Data(modulus)), "e": base64(Data(exponent))]]])
        let signingHeader = base64(try json(["alg": "RS256", "kid": "lyra-test"]))
        func signedIdentity(nonce: String) throws -> String {
            let payload = try json(["iss": "https://auth.openai.com", "aud": "oaiapp_test", "sub": "test-user",
                                    "email": "reader@example.invalid", "nonce": nonce, "exp": Date().timeIntervalSince1970 + 3600])
            let unsigned = signingHeader + "." + base64(payload)
            let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(unsigned.utf8) as CFData, nil)! as Data
            return unsigned + "." + base64(signature)
        }
        let suite = "lyra-chatgpt-checks-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); ChatGPTStubProtocol.route = nil }
        let vault = InMemoryAPIKeyStore()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChatGPTStubProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        // URLProtocol invokes this test-only route on its delegate queue, after the browser
        // closure has captured the transaction. No real secrets or provider endpoints are used.
        nonisolated(unsafe) var loginQuery: [String: String] = [:]
        nonisolated(unsafe) var refreshCount = 0
        nonisolated(unsafe) var inferenceCount = 0
        nonisolated(unsafe) var revokeCount = 0
        nonisolated(unsafe) var requestBodies: [Data] = []
        nonisolated(unsafe) var tokenID = ""
        ChatGPTStubProtocol.route = { request in
            let path = request.url!.path
            let body: [String: String] = {
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
                    }
                }
                let text = String(decoding: data, as: UTF8.self)
                return Dictionary(uniqueKeysWithValues: (URLComponents(string: "http://test/?" + text)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            }()
            switch path {
            case "/.well-known/openid-configuration":
                return (200, try JSONSerialization.data(withJSONObject: ["issuer": "https://auth.openai.com",
                    "jwks_uri": "https://auth.openai.com/.well-known/jwks.json",
                    "revocation_endpoint": "https://auth.openai.com/api/accounts/oauth/revoke"]), "application/json")
            case "/.well-known/jwks.json": return (200, jwks, "application/json")
            case "/api/accounts/oauth/token":
                guard body["client_id"] == "oaiapp_test" else { throw AISettingsError.invalid("wrong client") }
                if body["grant_type"] == "refresh_token" { refreshCount += 1 }
                else {
                    guard body["redirect_uri"] == loginQuery["redirect_uri"], let verifier = body["code_verifier"],
                          ChatGPTAuthorization.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) == loginQuery["code_challenge"] else {
                        throw AISettingsError.invalid("wrong PKCE/callback")
                    }
                }
                return (200, try JSONSerialization.data(withJSONObject: ["access_token": "synthetic-access-\(refreshCount)",
                    "refresh_token": "synthetic-refresh-\(refreshCount)", "id_token": tokenID,
                    "expires_in": refreshCount == 0 ? 1 : 3600, "token_type": "Bearer",
                    "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"]), "application/json")
            case "/v1/models":
                return (200, try JSONSerialization.data(withJSONObject: ["models": [
                    ["slug": "test-model", "display_name": "Test Model", "visibility": "list"],
                    ["slug": "hidden", "display_name": "Hidden", "visibility": "hidden"]]]), "application/json")
            case "/v1/responses":
                inferenceCount += 1
                if let body = request.httpBody { requestBodies.append(body) }
                else if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
                    }
                    requestBodies.append(data)
                }
                return (200, Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"A synthetic answer.\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":12,\"output_tokens\":4,\"total_tokens\":16}}}\n\n".utf8), "text/event-stream")
            case "/api/accounts/oauth/revoke": revokeCount += 1; return (200, Data(), "application/json")
            default: throw AISettingsError.invalid("Unexpected endpoint: \(path)")
            }
        }
        let accounts = ChatGPTAccountStore(defaults: defaults, vault: vault, session: session, openBrowser: { url in
            loginQuery = params(url)
            tokenID = try! signedIdentity(nonce: loginQuery["nonce"]!)
            var callback = URLComponents(string: loginQuery["redirect_uri"]!)!
            callback.queryItems = [URLQueryItem(name: "state", value: loginQuery["state"]),
                                   URLQueryItem(name: "code", value: "synthetic-code"),
                                   URLQueryItem(name: "client_id", value: "oaiapp_test")]
            Task { _ = try? await URLSession.shared.data(from: callback.url!) }
            return true
        })
        accounts.signIn()
        try await eventually("official loopback sign-in validates the JWT and loads the model catalog", {
            !accounts.isSigningIn && accounts.isConnected && accounts.models.count == 1
        })
        do {
            let pieces = tokenID.split(separator: ".")
            let tampered = String(pieces[0]) + "." + String(pieces[1]) + "." + base64(Data(repeating: 0, count: 256))
            _ = try await ChatGPTIdentity.verify(tampered, clientID: "oaiapp_test", nonce: loginQuery["nonce"]!, session: session)
            require(false, "a tampered identity signature must fail")
        } catch { require(true, "a tampered identity signature cannot activate an account") }
        require(accounts.selected?.email == "reader@example.invalid" && accounts.selected?.model == "test-model",
                "account display and model choice come from validated identity and eligible catalog")
        require(refreshCount == 1, "an expiring token rotates once before model discovery")
        require(defaults.dictionaryRepresentation().description.contains("synthetic-access") == false,
                "OAuth access tokens are absent from UserDefaults")
        let protectedCredential = try vault.readKey()
        require(protectedCredential?.contains("synthetic-refresh-1") == true, "the replacement refresh token is stored in the protected vault")

        let settings = AISettingsStore(defaults: defaults, keyStore: InMemoryAPIKeyStore(), chatGPT: accounts)
        settings.connectionMode = .chatGPT
        let engine = try RustEngine()
        let state = AppState(engine: engine)
        require(state.open(url: root.appendingPathComponent("tests/fixtures/text-page.pdf")), "the AI context fixture opens")
        let model = AIAssistantModel(settings: settings)
        let context = AIReaderContext(documentKey: "siwc-test", documentTitle: "Fixture", pageCount: 1, currentPage: 1, selection: nil)
        model.attach(service: RustAIChatService(engine: engine), context: context)
        await model.prepare(action: .summarizePage, context: context)
        require(model.phase == .preview && inferenceCount == 0, "preparing ChatGPT context consumes no inference quota")
        require(model.plan?.endpoint == ChatGPTResponses.endpoint, "ChatGPT preview names the actual Responses endpoint")
        if let plan = model.plan, let part = plan.parts.first {
            let body = try JSONSerialization.jsonObject(with: Data(part.wireBody.utf8)) as! [String: Any]
            require(body["store"] as? Bool == false && body["stream"] as? Bool == true && body["input"] != nil,
                    "the previewed Responses body disables storage and enables streaming")
        }
        model.send()
        try await eventually("ChatGPT responses stream through the real AI state machine", { model.phase.isTerminal })
        require(model.phase == .finished && model.answer == "A synthetic answer." && model.usage?.totalTokens == 16,
                "only completed Responses streams finish, with text and token usage (\(model.phase), \(model.errorMessage ?? "no error"))")
        require(inferenceCount == 1 && settings.hasKey == false, "ChatGPT inference needs no API key and makes one explicit request")
        await model.prepare(action: .summarizePage, context: context)
        settings.connectionMode = .apiKey
        model.send()
        require(model.phase == .failed && inferenceCount == 1, "changing provider after preview cannot silently reroute the request")
        await accounts.signOut()
        let signedOutCredential = try vault.readKey()
        require(!accounts.isConnected && revokeCount == 1 && signedOutCredential == nil,
                "sign-out revokes the renewable session and clears protected credentials")
        require(accounts.accounts.count == 1, "sign-out retains the issued client mapping for future sign-in")
        print("ChatGPT sign-in and Responses checks passed")
    }
}
