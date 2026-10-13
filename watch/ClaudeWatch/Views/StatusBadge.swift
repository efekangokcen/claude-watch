import SwiftUI

enum StatusStyle {
    static func color(_ state: String) -> Color {
        switch state {
        case "needs_input": return .orange
        case "busy": return .blue
        case "idle": return .green
        default: return .gray
        }
    }

    static func label(_ state: String) -> String {
        switch state {
        case "needs_input": return "Onay bekliyor"
        case "busy": return "Çalışıyor"
        case "idle": return "Hazır"
        default: return "Kapalı"
        }
    }
}

/// Small colored dot; pulses while a session is busy.
struct StatusDot: View {
    let state: String
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(StatusStyle.color(state))
            .frame(width: 9, height: 9)
            .opacity(state == "busy" ? (pulse ? 0.35 : 1) : 1)
            .animation(state == "busy" ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = true }
    }
}

struct StatusBadge: View {
    let status: SessionStatus

    var body: some View {
        HStack(spacing: 5) {
            StatusDot(state: status.state)
            Text(StatusStyle.label(status.state))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct ConnectionIndicator: View {
    let state: ConnectionState

    var body: some View {
        Circle()
            .fill(state == .connected ? Color.green : (state == .connecting ? Color.yellow : Color.red))
            .frame(width: 7, height: 7)
            .accessibilityLabel(state == .connected ? "Bağlı" : "Bağlanıyor")
    }
}
