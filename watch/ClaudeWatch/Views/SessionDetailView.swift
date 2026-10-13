import SwiftUI

struct SessionDetailView: View {
    @Environment(AppState.self) private var state
    let sessionId: String
    @State private var showAsk = false
    @State private var loadingMore = false

    private var session: SessionSummary? { state.sessions.first { $0.id == sessionId } }
    private var messages: [ChatMessage] { state.messages[sessionId] ?? [] }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if state.hasMore[sessionId] == true {
                        Button {
                            loadingMore = true
                            Task {
                                await state.loadMessages(sessionId, more: true)
                                loadingMore = false
                            }
                        } label: {
                            if loadingMore { ProgressView() } else { Text("Öncekiler").font(.caption2) }
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    }
                    if messages.isEmpty {
                        Text(state.messages[sessionId] == nil ? "Yükleniyor…" : "Mesaj yok")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 20)
                    }
                    ForEach(messages) { m in
                        MessageBubble(message: m).id(m.id)
                    }
                    if let q = state.question(for: sessionId) {
                        QuestionCard(question: q).id("question")
                    }
                    if let s = session, s.status.live {
                        HStack(spacing: 6) {
                            StatusDot(state: s.status.state)
                            Text(s.status.state == "needs_input" ? (s.status.message ?? "Onayın gerekiyor") : (s.status.state == "busy" ? "Çalışıyor…" : "Hazır"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                        .id("status")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 2)
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: state.question(for: sessionId)?.id) { _, id in
                if id != nil { withAnimation { proxy.scrollTo("question", anchor: .bottom) } }
            }
            .task {
                await state.loadMessages(sessionId)
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .navigationTitle((session?.displayTitle ?? "Oturum").clipped(18))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    showAsk = true
                } label: {
                    Label("Soru sor", systemImage: "mic.fill")
                }
                .disabled(!state.claudeAvailable)
            }
        }
        .sheet(isPresented: $showAsk) {
            AskView(sessionId: sessionId)
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.isUser { Spacer(minLength: 24) }
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 3) {
                if !message.text.isEmpty {
                    Text(message.isUser ? AttributedString(message.text) : message.text.markdownInline)
                        .font(.footnote)
                        .multilineTextAlignment(message.isUser ? .trailing : .leading)
                }
                if let tools = message.tools, !tools.isEmpty {
                    Text("🔧 " + summarize(tools))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(message.isUser ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.12))
            )
            .foregroundStyle(message.isUser ? Color.black : Color.primary)
            if !message.isUser { Spacer(minLength: 24) }
        }
    }

    /// "Bash ×3, Read" instead of "Bash, Bash, Bash, Read"
    private func summarize(_ tools: [String]) -> String {
        var counts: [(String, Int)] = []
        for t in tools {
            if let i = counts.firstIndex(where: { $0.0 == t }) { counts[i].1 += 1 } else { counts.append((t, 1)) }
        }
        return counts.map { $0.1 > 1 ? "\($0.0) ×\($0.1)" : $0.0 }.joined(separator: ", ")
    }
}
