import Foundation

// MARK: - API models (mirror bridge/src/server.js)

struct SessionStatus: Codable, Hashable {
    var state: String      // needs_input | busy | idle | ended
    var live: Bool
    var message: String?
    var pid: Int?
}

struct SessionSummary: Codable, Identifiable, Hashable {
    var id: String
    var title: String?
    var cwd: String?
    var project: String?
    var lastActivity: String?
    var messageCount: Int?
    var preview: String?
    var lastRole: String?
    var pendingTools: Bool?
    var model: String?
    var parsed: Bool?
    var startedAt: String?
    var entrypoint: String?
    var status: SessionStatus

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        if let p = project, !p.isEmpty { return p }
        return String(id.prefix(8))
    }

    var lastActivityDate: Date? { ISO8601.parse(lastActivity) }
}

struct ChatMessage: Codable, Identifiable, Hashable {
    var id: String
    var role: String       // user | assistant
    var text: String
    var tools: [String]?
    var ts: String?
    var toolResults: Int?

    var isUser: Bool { role == "user" }
    var date: Date? { ISO8601.parse(ts) }
}

struct SessionDetail: Codable {
    var session: SessionSummary
    var question: PendingQuestion?
    var messages: [ChatMessage]
    var hasMore: Bool
}

// MARK: - Pending questions (held hooks: permission / AskUserQuestion / Stop reply window)

struct AskOption: Codable, Hashable {
    var label: String
    var description: String?
}

struct AskQuestion: Codable, Hashable {
    var question: String
    var header: String?
    var multiSelect: Bool?
    var options: [AskOption]
}

struct QuestionPayload: Codable, Hashable {
    var toolName: String?
    var questions: [AskQuestion]?
    private enum CodingKeys: String, CodingKey { case toolName = "tool_name", questions }
}

struct PendingQuestion: Codable, Identifiable, Hashable {
    var id: String
    var kind: String        // permission | question | reply
    var sessionId: String
    var title: String?
    var body: String?
    var payload: QuestionPayload?
    var createdAt: Double
    var expiresAt: Double
    var status: String

    var expiresDate: Date { Date(timeIntervalSince1970: expiresAt / 1000) }
    var kindLabel: String {
        switch kind {
        case "permission": return "İzin istiyor"
        case "question": return "Soru soruyor"
        case "reply": return "Bitti, cevap bekliyor"
        default: return kind
        }
    }
}

struct PresenceInfo: Codable, Hashable {
    var away: Bool
    var forced: Bool
    var idleSec: Int?
    var afterSec: Int
}

/// Value sent as `answer` to POST /api/questions/:id/answer
enum AnswerValue: Encodable {
    case text(String)
    case answers([String])

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let s):
            var c = encoder.singleValueContainer()
            try c.encode(s)
        case .answers(let a):
            var c = encoder.container(keyedBy: Key.self)
            try c.encode(a, forKey: .answers)
        }
    }
    private enum Key: String, CodingKey { case answers }
}

struct AnswerBody: Encodable { var answer: AnswerValue }

struct AskResult: Codable {
    var run: RunInfo?
    var replied: Bool?
    var question: PendingQuestion?
}

struct SessionsResponse: Codable {
    var sessions: [SessionSummary]
    var claude: Bool
}

struct RunInfo: Codable, Identifiable, Hashable {
    var id: String
    var sessionId: String?
    var status: String     // running | done | error | cancelled
    var result: String?
    var error: String?
    var prompt: String?
    var liveText: String = ""   // accumulated from run.assistant events (not from JSON)

    private enum CodingKeys: String, CodingKey { case id, sessionId, status, result, error, prompt }
}

struct RunResponse: Codable { var run: RunInfo }

struct PairResponse: Codable {
    var token: String
    var device: String?
    var claude: Bool?
    var ntfyTopic: String?
    var ntfyUrl: String?
}

struct HealthResponse: Codable {
    var ok: Bool
    var device: String?
    var claude: Bool?
}

struct APIErrorBody: Codable {
    var error: String
    var message: String?
}

/// One WebSocket frame from the bridge. Fields are optional because every event type carries a different subset.
struct WSEvent: Decodable {
    var type: String
    var sessions: [SessionSummary]?
    var claude: Bool?
    var session: SessionSummary?
    var messages: [ChatMessage]?
    var id: String?
    var sessionId: String?
    var title: String?
    var body: String?
    var runId: String?
    var status: String?
    var result: String?
    var error: String?
    var text: String?
    var tools: [String]?
    var questions: [PendingQuestion]?
    var question: PendingQuestion?
    var presence: PresenceInfo?
    var ntfy: Bool?
}

enum BridgeError: LocalizedError {
    case notConfigured
    case http(Int, APIErrorBody?)
    case sessionLive(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Köprü ayarlanmadı"
        case .http(let code, let body): return body?.message ?? body?.error ?? "HTTP \(code)"
        case .sessionLive(let m): return m
        case .transport(let m): return m
        }
    }
}

enum ISO8601 {
    private static let withFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return withFrac.date(from: s) ?? plain.date(from: s)
    }
}

extension String {
    /// Inline Markdown (bold, code, links) rendered as an AttributedString; falls back to plain text.
    var markdownInline: AttributedString {
        (try? AttributedString(markdown: self, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(self)
    }

    func clipped(_ n: Int) -> String {
        count > n ? String(prefix(n - 1)) + "…" : self
    }
}

extension Date {
    var relativeShort: String {
        if abs(timeIntervalSinceNow) < 60 { return "şimdi" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.locale = Locale(identifier: "tr_TR")
        return f.localizedString(for: self, relativeTo: Date())
    }
}
