import Foundation
import Observation
import UserNotifications
import WatchKit

enum ConnectionState: Equatable {
    case disconnected, connecting, connected
}

@MainActor
@Observable
final class AppState {
    // Settings (persisted)
    var host: String? { didSet { UserDefaults.standard.set(host, forKey: "bridge.host") } }
    var token: String? { didSet { UserDefaults.standard.set(token, forKey: "bridge.token") } }
    var deviceName: String? { didSet { UserDefaults.standard.set(deviceName, forKey: "bridge.device") } }
    var ntfyTopic: String? { didSet { UserDefaults.standard.set(ntfyTopic, forKey: "bridge.ntfyTopic") } }
    var ntfyUrl: String? { didSet { UserDefaults.standard.set(ntfyUrl, forKey: "bridge.ntfyUrl") } }

    // Live data
    private(set) var sessions: [SessionSummary] = []
    private(set) var messages: [String: [ChatMessage]] = [:]
    private(set) var hasMore: [String: Bool] = [:]
    private(set) var runs: [String: RunInfo] = [:]
    private(set) var questions: [PendingQuestion] = []
    private(set) var presence: PresenceInfo?
    private(set) var ntfyEnabled = false
    var askReplied: Set<String> = []
    var answering: Set<String> = []
    /// Ask-sheet state keyed by session id ("new" for a fresh chat); lives here so view rebuilds don't lose it.
    var askDraft: [String: String] = [:]
    var askRunId: [String: String] = [:]
    var askConflict: Set<String> = []
    var askError: [String: String] = [:]
    var askSending: Set<String> = []
    private(set) var connection: ConnectionState = .disconnected
    private(set) var claudeAvailable = true
    private(set) var lastError: String?
    private(set) var lastNotice: (title: String, body: String, at: Date)?

    var isPaired: Bool { host != nil && token != nil }
    var client: BridgeClient? {
        guard let host else { return nil }
        return BridgeClient(host: host, token: token)
    }

    private var eventTask: Task<Void, Never>?
    private var pendingSessions: [String: SessionSummary] = [:]
    private var flushTask: Task<Void, Never>?

    init() {
        host = UserDefaults.standard.string(forKey: "bridge.host")
        token = UserDefaults.standard.string(forKey: "bridge.token")
        deviceName = UserDefaults.standard.string(forKey: "bridge.device")
        ntfyTopic = UserDefaults.standard.string(forKey: "bridge.ntfyTopic")
        ntfyUrl = UserDefaults.standard.string(forKey: "bridge.ntfyUrl")
    }

    // MARK: Pairing

    func pair(host: String, code: String) async throws {
        let c = BridgeClient(host: host, token: nil)
        let r = try await c.pair(code: code)
        self.host = host
        self.token = r.token
        self.deviceName = r.device
        self.ntfyTopic = r.ntfyTopic
        self.ntfyUrl = r.ntfyUrl
        self.claudeAvailable = r.claude ?? true
        connect()
    }

    func unpair() {
        disconnect()
        host = nil
        token = nil
        deviceName = nil
        sessions = []
        messages = [:]
        runs = [:]
        questions = []
    }

    // MARK: Questions / presence

    func answer(_ q: PendingQuestion, _ value: AnswerValue) async {
        guard let client else { return }
        answering.insert(q.id)
        do {
            _ = try await client.answer(questionId: q.id, value)
            questions.removeAll { $0.id == q.id }
            WKInterfaceDevice.current().play(.success)
        } catch {
            lastError = error.localizedDescription
        }
        answering.remove(q.id)
    }

    func setAway(_ force: Bool) async {
        guard let client else { return }
        do { presence = try await client.setPresence(force: force) } catch { lastError = error.localizedDescription }
    }

    func sendTestPush() async -> Bool {
        guard let client else { return false }
        return (try? await client.testPush()) ?? false
    }

    func question(for sessionId: String) -> PendingQuestion? {
        questions.first { $0.sessionId == sessionId }
    }

    // MARK: Connection

    func connect() {
        guard let client, eventTask == nil else { return }
        connection = .connecting
        requestNotificationPermission()
        eventTask = Task { [weak self] in
            for await ev in client.events() {
                guard let self else { return }
                if let ev { self.handle(ev) } else { self.connection = .connecting }
            }
        }
        Task { await refresh() }
    }

    func disconnect() {
        eventTask?.cancel()
        eventTask = nil
        connection = .disconnected
    }

    func refresh() async {
        guard let client else { return }
        do {
            let r = try await client.sessions()
            sessions = r.sessions
            claudeAvailable = r.claude
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadMessages(_ id: String, more: Bool = false) async {
        guard let client else { return }
        do {
            let before = more ? messages[id]?.first?.id : nil
            let d = try await client.session(id, limit: 40, before: before)
            upsert(d.session)
            if more, var cur = messages[id] {
                let existing = Set(cur.map(\.id))
                cur.insert(contentsOf: d.messages.filter { !existing.contains($0.id) }, at: 0)
                messages[id] = cur
            } else {
                messages[id] = d.messages
            }
            hasMore[id] = d.hasMore
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Ask

    /// Returns the run, or nil when the text was delivered into the live desktop chat (Stop reply window).
    func ask(sessionId: String?, text: String, force: Bool = false) async throws -> RunInfo? {
        guard let client else { throw BridgeError.notConfigured }
        var r: RunInfo
        if let sessionId {
            let res = try await client.ask(sessionId: sessionId, text: text, force: force)
            if res.replied == true {
                if let q = res.question { questions.removeAll { $0.id == q.id } }
                return nil
            }
            guard let run = res.run else { throw BridgeError.transport("Boş cevap") }
            r = run
        } else {
            r = try await client.askNew(text: text)
        }
        r.prompt = text
        runs[r.id] = r
        return r
    }

    /// Full ask flow used by AskView; `key` is the session id or "new".
    func submitAsk(key: String, force: Bool) async {
        let text = (askDraft[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !askSending.contains(key) else { return }
        askSending.insert(key)
        askError[key] = nil
        askConflict.remove(key)
        do {
            if let r = try await ask(sessionId: key == "new" ? nil : key, text: text, force: force) {
                askRunId[key] = r.id
            } else {
                askReplied.insert(key)
                WKInterfaceDevice.current().play(.success)
            }
        } catch BridgeError.sessionLive {
            askConflict.insert(key)
        } catch {
            askError[key] = error.localizedDescription
        }
        askSending.remove(key)
    }

    func resetAsk(key: String) {
        askDraft[key] = nil
        askRunId[key] = nil
        askConflict.remove(key)
        askError[key] = nil
        askReplied.remove(key)
    }

    func sessionIsLive(_ id: String) -> Bool {
        sessions.first { $0.id == id }?.status.live ?? false
    }

    // MARK: Event handling

    private func handle(_ ev: WSEvent) {
        connection = .connected
        switch ev.type {
        case "snapshot":
            if let s = ev.sessions { sessions = s }
            if let q = ev.questions { questions = q }
            if let p = ev.presence { presence = p }
            if let c = ev.claude { claudeAvailable = c }
            if let n = ev.ntfy { ntfyEnabled = n }
        case "question.new":
            if let q = ev.question {
                questions.removeAll { $0.id == q.id }
                questions.append(q)
                WKInterfaceDevice.current().play(.notification)
            }
        case "question.resolved":
            if let q = ev.question { questions.removeAll { $0.id == q.id } }
        case "presence":
            if let p = ev.presence { presence = p }
        case "session.update":
            if let s = ev.session { queueUpsert(s) }
            if let id = ev.session?.id, let incoming = ev.messages, !incoming.isEmpty, messages[id] != nil {
                var cur = messages[id] ?? []
                for m in incoming {
                    if let i = cur.firstIndex(where: { $0.id == m.id }) { cur[i] = m } else { cur.append(m) }
                }
                messages[id] = cur
            }
        case "session.removed":
            if let id = ev.id {
                sessions.removeAll { $0.id == id }
                messages[id] = nil
            }
        case "notify":
            let title = ev.title ?? "Claude Code"
            let body = ev.body ?? ""
            lastNotice = (title, body, Date())
            WKInterfaceDevice.current().play(.notification)
            postLocalNotification(title: title, body: body, sessionId: ev.sessionId)
        case "run.started", "run.init", "run.assistant", "run.finished":
            guard let runId = ev.runId else { return }
            var r = runs[runId] ?? RunInfo(id: runId, sessionId: ev.sessionId, status: "running")
            if let sid = ev.sessionId { r.sessionId = sid }
            if ev.type == "run.assistant", let t = ev.text, !t.isEmpty {
                r.liveText += (r.liveText.isEmpty ? "" : "\n") + t
            }
            if ev.type == "run.finished" {
                r.status = ev.status ?? "done"
                r.result = ev.result
                r.error = ev.error
                WKInterfaceDevice.current().play(r.status == "done" ? .success : .failure)
            }
            runs[runId] = r
        default:
            break
        }
    }

    /// Busy sessions emit an update per tool call; batch them so the list re-sorts at most ~once a second.
    private func queueUpsert(_ s: SessionSummary) {
        let current = sessions.first { $0.id == s.id }
        let statusChanged = current?.status.state != s.status.state
        pendingSessions[s.id] = s
        if statusChanged || current == nil {
            flushPending()
            return
        }
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.flushPending()
        }
    }

    private func flushPending() {
        flushTask?.cancel()
        flushTask = nil
        let batch = pendingSessions
        pendingSessions = [:]
        for s in batch.values { upsert(s) }
    }

    private func upsert(_ s: SessionSummary) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.append(s) }
        let rank: [String: Int] = ["needs_input": 0, "busy": 1, "idle": 2, "ended": 3]
        sessions.sort {
            let ra = rank[$0.status.state] ?? 9, rb = rank[$1.status.state] ?? 9
            if ra != rb { return ra < rb }
            return ($0.lastActivity ?? "") > ($1.lastActivity ?? "")
        }
    }

    // MARK: Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postLocalNotification(title: String, body: String, sessionId: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let sessionId { content.userInfo = ["sessionId": sessionId] }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
