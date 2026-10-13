import Foundation

/// REST + WebSocket client for the Mac bridge.
final class BridgeClient: @unchecked Sendable {
    let host: String      // "192.168.1.125:7788" or "mac.local:7788"
    let token: String?

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    init(host: String, token: String?) {
        self.host = host
        self.token = token
    }

    var httpBase: URL? { URL(string: "http://\(host)") }
    var wsURL: URL? {
        guard let token else { return nil }
        return URL(string: "ws://\(host)/ws?token=\(token)")
    }

    // MARK: REST

    private func request(_ path: String, method: String = "GET", body: Encodable? = nil, auth: Bool = true) async throws -> Data {
        guard let base = httpBase, let url = URL(string: path, relativeTo: base) else { throw BridgeError.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if auth {
            guard let token else { throw BridgeError.notConfigured }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw BridgeError.transport(error.localizedDescription)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let err = try? JSONDecoder().decode(APIErrorBody.self, from: data)
            if code == 409, err?.error == "session_live" { throw BridgeError.sessionLive(err?.message ?? "Oturum açık") }
            throw BridgeError.http(code, err)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    func health() async throws -> HealthResponse {
        try decode(HealthResponse.self, try await request("/api/health", auth: false))
    }

    func pair(code: String) async throws -> PairResponse {
        try decode(PairResponse.self, try await request("/api/pair", method: "POST", body: ["code": code], auth: false))
    }

    func sessions(limit: Int = 40) async throws -> SessionsResponse {
        try decode(SessionsResponse.self, try await request("/api/sessions?limit=\(limit)"))
    }

    func session(_ id: String, limit: Int = 40, before: String? = nil) async throws -> SessionDetail {
        var path = "/api/sessions/\(id)?limit=\(limit)"
        if let before { path += "&before=\(before)" }
        return try decode(SessionDetail.self, try await request(path))
    }

    func ask(sessionId: String, text: String, force: Bool = false) async throws -> AskResult {
        try decode(AskResult.self, try await request("/api/sessions/\(sessionId)/ask", method: "POST", body: AskBody(text: text, force: force)))
    }

    func questions() async throws -> [PendingQuestion] {
        struct R: Codable { var questions: [PendingQuestion] }
        return try decode(R.self, try await request("/api/questions")).questions
    }

    func answer(questionId: String, _ value: AnswerValue) async throws -> PendingQuestion {
        struct R: Codable { var question: PendingQuestion }
        return try decode(R.self, try await request("/api/questions/\(questionId)/answer", method: "POST", body: AnswerBody(answer: value))).question
    }

    func setPresence(force: Bool) async throws -> PresenceInfo {
        try decode(PresenceInfo.self, try await request("/api/presence", method: "POST", body: ["force": force]))
    }

    func testPush() async throws -> Bool {
        struct R: Codable { var sent: Bool }
        return try decode(R.self, try await request("/api/test-push", method: "POST", body: [String: String]())).sent
    }

    func askNew(text: String, cwd: String? = nil) async throws -> RunInfo {
        try decode(RunResponse.self, try await request("/api/ask", method: "POST", body: AskBody(text: text, cwd: cwd))).run
    }

    func run(_ id: String) async throws -> RunInfo {
        try decode(RunResponse.self, try await request("/api/runs/\(id)")).run
    }

    // MARK: WebSocket

    /// Streams events until cancelled. Reconnects with backoff; yields `nil` whenever the socket drops.
    func events() -> AsyncStream<WSEvent?> {
        AsyncStream { continuation in
            let task = Task {
                var backoff: UInt64 = 1
                while !Task.isCancelled {
                    guard let url = wsURL else { continuation.finish(); return }
                    let ws = session.webSocketTask(with: url)
                    ws.resume()
                    do {
                        while !Task.isCancelled {
                            let msg = try await ws.receive()
                            let data: Data?
                            switch msg {
                            case .string(let s): data = s.data(using: .utf8)
                            case .data(let d): data = d
                            @unknown default: data = nil
                            }
                            if let data, let ev = try? JSONDecoder().decode(WSEvent.self, from: data) {
                                continuation.yield(ev)
                                backoff = 1
                            }
                        }
                    } catch {
                        // fall through to reconnect
                    }
                    ws.cancel(with: .goingAway, reason: nil)
                    continuation.yield(nil)
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                    backoff = min(backoff * 2, 15)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct AskBody: Encodable {
    var text: String
    var force: Bool? = nil
    var cwd: String? = nil
}

private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
