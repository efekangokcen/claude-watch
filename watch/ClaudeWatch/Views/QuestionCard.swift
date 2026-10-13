import SwiftUI

/// A held Claude Code hook waiting for the user: permission, multiple-choice question, or the
/// post-task reply window. Answering here resolves the hook on the Mac.
struct QuestionCard: View {
    @Environment(AppState.self) private var state
    let question: PendingQuestion
    @State private var picked: [Int: Set<String>] = [:]

    private var busy: Bool { state.answering.contains(question.id) }
    static let quickReplies = ["Devam et", "Evet", "Hayır", "Dur"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon).foregroundStyle(.orange)
                Text(question.kindLabel).font(.caption2).foregroundStyle(.orange)
                Spacer()
                Countdown(until: question.expiresDate)
            }
            if let t = question.title {
                Text(t).font(.caption).bold().lineLimit(1)
            }
            if question.kind != "question", let b = question.body, !b.isEmpty {
                Text(b).font(.caption2).foregroundStyle(.secondary).lineLimit(5)
            }
            switch question.kind {
            case "permission": permissionButtons
            case "question": questionOptions
            case "reply": replyControls
            default: EmptyView()
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.14)))
        .disabled(busy)
        .overlay(alignment: .topTrailing) { if busy { ProgressView().padding(6) } }
    }

    private var icon: String {
        switch question.kind {
        case "permission": return "lock.shield"
        case "question": return "questionmark.bubble"
        default: return "arrowshape.turn.up.left"
        }
    }

    private var permissionButtons: some View {
        HStack(spacing: 6) {
            Button { Task { await state.answer(question, .text("allow")) } } label: {
                Label("İzin ver", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .tint(.green)
            Button { Task { await state.answer(question, .text("deny")) } } label: {
                Label("Reddet", systemImage: "xmark").frame(maxWidth: .infinity)
            }
            .tint(.red)
        }
        .buttonStyle(.borderedProminent)
        .labelStyle(.titleOnly)
    }

    private var questionOptions: some View {
        let qs = question.payload?.questions ?? []
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(qs.enumerated()), id: \.offset) { i, q in
                VStack(alignment: .leading, spacing: 4) {
                    if let h = q.header { Text(h).font(.caption2).foregroundStyle(.secondary) }
                    Text(q.question).font(.caption)
                    ForEach(q.options, id: \.label) { o in
                        let on = picked[i]?.contains(o.label) ?? false
                        Button {
                            if q.multiSelect == true {
                                var s = picked[i] ?? []
                                if on { s.remove(o.label) } else { s.insert(o.label) }
                                picked[i] = s
                            } else {
                                picked[i] = [o.label]
                                if qs.count == 1 { submitAnswers(qs) }
                            }
                        } label: {
                            HStack {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading) {
                                    Text(o.label).font(.caption)
                                    if let d = o.description { Text(d).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(on ? .orange : nil)
                    }
                }
            }
            if qs.count > 1 || qs.first?.multiSelect == true {
                Button("Gönder") { submitAnswers(qs) }
                    .buttonStyle(.borderedProminent)
                    .disabled(qs.indices.contains { (picked[$0] ?? []).isEmpty })
            }
        }
    }

    private func submitAnswers(_ qs: [AskQuestion]) {
        let answers = qs.indices.map { (picked[$0] ?? []).sorted().joined(separator: ", ") }
        Task { await state.answer(question, .answers(answers)) }
    }

    private var replyControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                ForEach(Self.quickReplies, id: \.self) { r in
                    Button(r) { Task { await state.answer(question, .text(r)) } }
                        .buttonStyle(.bordered)
                        .font(.caption)
                }
            }
            TextFieldLink(prompt: Text("Cevabını söyle veya yaz")) {
                Label("Yaz / Söyle", systemImage: "mic.fill").frame(maxWidth: .infinity)
            } onSubmit: { value in
                let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { Task { await state.answer(question, .text(t)) } }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct Countdown: View {
    let until: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let s = max(0, Int(until.timeIntervalSince(ctx.date)))
            Text(s >= 90 ? "\(s / 60) dk" : "\(s) sn")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(s < 15 ? .red : .secondary)
        }
    }
}
