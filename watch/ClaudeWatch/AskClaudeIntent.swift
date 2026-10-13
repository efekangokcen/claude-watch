import AppIntents
import Foundation

/// Siri / Shortcuts: "Claude'a sor" → sends a new question through the bridge and speaks the answer.
struct AskClaudeIntent: AppIntent {
    static var title: LocalizedStringResource = "Claude'a sor"
    static var description = IntentDescription("Mac'teki Claude Code'a yeni bir soru gönderir ve cevabı okur.")
    static var openAppWhenRun = false

    @Parameter(title: "Soru", requestValueDialog: "Claude'a ne soracaksın?")
    var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let host = UserDefaults.standard.string(forKey: "bridge.host"),
              let token = UserDefaults.standard.string(forKey: "bridge.token") else {
            return .result(dialog: "Önce Claude Watch uygulamasında Mac ile eşleştir.")
        }
        let client = BridgeClient(host: host, token: token)
        let run = try await client.askNew(text: text)
        for _ in 0..<25 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let r = try await client.run(run.id)
            if r.status != "running" {
                let answer = r.result ?? r.error ?? "Bitti"
                return .result(dialog: IntentDialog(stringLiteral: String(answer.prefix(600))))
            }
        }
        return .result(dialog: "Claude hâlâ çalışıyor, cevabı Claude Watch uygulamasında görebilirsin.")
    }
}

struct ClaudeWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskClaudeIntent(),
            phrases: ["\(.applicationName) ile Claude'a sor", "Ask Claude with \(.applicationName)"],
            shortTitle: "Claude'a sor",
            systemImageName: "bubble.left.and.text.bubble"
        )
    }
}
