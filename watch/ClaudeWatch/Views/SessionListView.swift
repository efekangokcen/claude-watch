import SwiftUI

struct SessionListView: View {
    @Environment(AppState.self) private var state
    @State private var showNewAsk = false
    @State private var showSettings = false

    private var live: [SessionSummary] { state.sessions.filter { $0.status.live } }
    private var ended: [SessionSummary] { state.sessions.filter { !$0.status.live } }

    var body: some View {
        List {
            if let err = state.lastError, state.sessions.isEmpty {
                Section {
                    Label(err, systemImage: "wifi.exclamationmark")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Button("Tekrar dene") { Task { await state.refresh() } }
                }
            }
            if !state.questions.isEmpty {
                Section("Bekleyen") {
                    ForEach(state.questions) { q in
                        QuestionCard(question: q)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                    }
                }
            }
            if !live.isEmpty {
                Section("Açık") {
                    ForEach(live) { s in
                        NavigationLink(value: s.id) { SessionRow(session: s) }
                    }
                }
            }
            Section(live.isEmpty ? "Oturumlar" : "Son") {
                if ended.isEmpty && live.isEmpty {
                    Text("Oturum yok").foregroundStyle(.secondary)
                }
                ForEach(ended) { s in
                    NavigationLink(value: s.id) { SessionRow(session: s) }
                }
            }
        }
        .navigationTitle("Claude")
        .navigationDestination(for: String.self) { id in
            SessionDetailView(sessionId: id)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: {
                    HStack(spacing: 4) {
                        ConnectionIndicator(state: state.connection)
                        Image(systemName: "gearshape")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNewAsk = true } label: { Image(systemName: "plus.bubble") }
                    .disabled(!state.claudeAvailable)
            }
        }
        .refreshable { await state.refresh() }
        .sheet(isPresented: $showNewAsk) {
            AskView(sessionId: nil)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
}

struct SessionRow: View {
    let session: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                StatusDot(state: session.status.state)
                Text(session.displayTitle)
                    .font(.headline)
                    .lineLimit(2)
            }
            HStack(spacing: 4) {
                if let p = session.project, p != session.title {
                    Text(p).lineLimit(1)
                }
                if let d = session.lastActivityDate {
                    Text("·")
                    Text(d.relativeShort)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if let preview = session.preview, !preview.isEmpty {
                Text(preview)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var pushResult: String?

    var body: some View {
        List {
            Section("Uzakta modu") {
                Toggle("Mac'ten uzaktayım", isOn: Binding(
                    get: { state.presence?.forced ?? false },
                    set: { v in Task { await state.setAway(v) } }
                ))
                if let p = state.presence {
                    LabeledContent("Durum", value: p.away ? "Uzakta" : "Mac başında")
                    if let i = p.idleSec { LabeledContent("Mac boşta", value: "\(i) sn") }
                }
                Text("Uzaktayken izin ve sorular saate düşer, bildirim telefona gider. Mac'e dönünce otomatik kapanır.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section("Bildirim (ntfy)") {
                if let t = state.ntfyTopic {
                    Text(t).font(.system(.caption2, design: .monospaced)).lineLimit(3)
                    Text("iPhone'daki ntfy uygulamasında bu konuya abone ol.").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Köprüde kapalı").foregroundStyle(.secondary)
                }
                Button("Test bildirimi gönder") {
                    Task { pushResult = await state.sendTestPush() ? "Gönderildi" : "Gönderilemedi" }
                }
                if let r = pushResult { Text(r).font(.caption2).foregroundStyle(.secondary) }
            }
            Section("Köprü") {
                LabeledContent("Mac", value: state.deviceName ?? "—")
                LabeledContent("Adres", value: state.host ?? "—")
                LabeledContent("Bağlantı", value: state.connection == .connected ? "Bağlı" : "Bağlı değil")
                LabeledContent("Claude CLI", value: state.claudeAvailable ? "Hazır" : "Yok")
            }
            Section {
                Button("Yeniden bağlan") {
                    state.disconnect()
                    state.connect()
                    dismiss()
                }
                Button("Eşleştirmeyi kaldır", role: .destructive) {
                    state.unpair()
                    dismiss()
                }
            }
        }
        .navigationTitle("Ayarlar")
    }
}
