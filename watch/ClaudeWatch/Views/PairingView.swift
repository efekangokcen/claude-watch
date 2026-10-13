import SwiftUI

/// First-run flow: find the Mac via Bonjour (or type its address), then enter the 6-digit pair code.
struct PairingView: View {
    @Environment(AppState.self) private var state
    @State private var discovery = BridgeDiscovery()
    @State private var manualHost = ""
    @State private var selectedHost: String?

    var body: some View {
        List {
            Section {
                Text("Mac'te köprü çalışıyor olmalı:\n`bun run start`")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section("Bulunan Mac'ler") {
                if discovery.found.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text("Aranıyor…").foregroundStyle(.secondary)
                    }
                }
                ForEach(discovery.found) { f in
                    Button {
                        if let hp = f.hostPort { selectedHost = hp }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(f.name)
                            Text(f.hostPort ?? "çözümleniyor…")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(f.hostPort == nil)
                }
            }
            Section("Elle adres") {
                TextFieldLink(prompt: Text("192.168.1.10:7788")) {
                    Label(manualHost.isEmpty ? "Adres yaz" : manualHost, systemImage: "keyboard")
                } onSubmit: { value in
                    var h = value.trimmingCharacters(in: .whitespaces)
                    guard !h.isEmpty else { return }
                    if !h.contains(":") { h += ":7788" }
                    manualHost = h
                    selectedHost = h
                }
            }
        }
        .navigationTitle("Eşleştir")
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
        .navigationDestination(item: $selectedHost) { host in
            CodeEntryView(host: host)
        }
    }
}

struct CodeEntryView: View {
    @Environment(AppState.self) private var state
    let host: String
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                Text(code.isEmpty ? "······" : code.padding(toLength: 6, withPad: "·", startingAt: 0))
                    .font(.system(.title3, design: .monospaced))
                    .tracking(3)
                    .padding(.top, 2)
                if let error {
                    Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
                } else {
                    Text("Mac'teki köprü logundaki 6 haneli kod")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                    ForEach(["1","2","3","4","5","6","7","8","9","⌫","0","✓"], id: \.self) { k in
                        Button {
                            tap(k)
                        } label: {
                            Text(k).font(.system(.body, design: .rounded)).frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .buttonStyle(.bordered)
                        .tint(k == "✓" ? .green : (k == "⌫" ? .red : nil))
                        .disabled(busy || (k == "✓" && code.count != 6))
                    }
                }
                Text(host).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .navigationTitle("Kod")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if busy { ProgressView() } }
    }

    private func tap(_ k: String) {
        switch k {
        case "⌫": if !code.isEmpty { code.removeLast() }
        case "✓": submit()
        default: if code.count < 6 { code += k; if code.count == 6 { submit() } }
        }
    }

    private func submit() {
        guard code.count == 6 else { return }
        busy = true
        error = nil
        Task {
            do {
                try await state.pair(host: host, code: code)
            } catch {
                self.error = error.localizedDescription
                code = ""
            }
            busy = false
        }
    }
}
