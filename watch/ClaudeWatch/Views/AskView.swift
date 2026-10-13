import SwiftUI

/// Ask a question: into an existing session (via `claude -p --resume`) or as a new chat.
struct AskView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let sessionId: String?

    private var key: String { sessionId ?? "new" }
    private var text: String { state.askDraft[key] ?? "" }
    private var run: RunInfo? { state.askRunId[key].flatMap { state.runs[$0] } }
    private var sending: Bool { state.askSending.contains(key) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if state.askReplied.contains(key) {
                    Label("Cevabın Mac'teki sohbete iletildi, Claude devam ediyor.", systemImage: "checkmark.circle.fill")
                        .font(.footnote).foregroundStyle(.green)
                    Button("Kapat") {
                        state.resetAsk(key: key)
                        dismiss()
                    }
                } else if run == nil {
                    if !text.isEmpty {
                        Text(text)
                            .font(.footnote)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.12)))
                    }
                    // TextFieldLink opens the system input (dictation / scribble / keyboard) and hands back the text.
                    TextFieldLink(prompt: Text("Sorunu söyle veya yaz")) {
                        Label(text.isEmpty ? "Yaz / Söyle" : "Düzenle", systemImage: "mic.fill")
                    } onSubmit: { value in
                        state.askDraft[key] = value
                        if !value.trimmingCharacters(in: .whitespaces).isEmpty {
                            Task { await state.submitAsk(key: key, force: false) }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sending)

                    if sending {
                        HStack(spacing: 6) { ProgressView(); Text("Gönderiliyor…").font(.caption2).foregroundStyle(.secondary) }
                    } else if !text.isEmpty {
                        Button { Task { await state.submitAsk(key: key, force: false) } } label: {
                            Label("Gönder", systemImage: "paperplane.fill")
                        }
                        .buttonStyle(.bordered)
                    }

                    if state.askConflict.contains(key) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Bu sohbet şu an Mac'te açık. Mesaj oraya canlı eklenemiyor.")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            Button("Ayrı devam olarak sor") { Task { await state.submitAsk(key: key, force: true) } }
                                .buttonStyle(.bordered)
                        }
                    }
                    if let error = state.askError[key] {
                        Text(error).font(.caption2).foregroundStyle(.red)
                    }
                } else if let run {
                    RunResultView(run: run)
                    if run.status != "running" {
                        Button("Yeni soru") { state.resetAsk(key: key) }
                            .buttonStyle(.bordered)
                        Button("Kapat") {
                            state.resetAsk(key: key)
                            dismiss()
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(sessionId == nil ? "Yeni sohbet" : "Soru sor")
    }
}

struct RunResultView: View {
    let run: RunInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let p = run.prompt {
                Text(p)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.25)))
            }
            switch run.status {
            case "running":
                HStack(spacing: 6) {
                    ProgressView()
                    Text(run.liveText.isEmpty ? "Claude düşünüyor…" : "Yazıyor…")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if !run.liveText.isEmpty {
                    Text(run.liveText.markdownInline).font(.footnote)
                }
            case "done":
                Text((run.result ?? run.liveText).markdownInline).font(.footnote)
            case "cancelled":
                Text("İptal edildi").foregroundStyle(.secondary)
            default:
                Label(run.error ?? "Hata", systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.red)
            }
        }
    }
}
