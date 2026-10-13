import SwiftUI

@main
struct ClaudeWatchApp: App {
    @State private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        if state.isPaired { state.connect() }
                    case .background:
                        state.disconnect()
                    default:
                        break
                    }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.isPaired {
            NavigationStack {
                SessionListView()
            }
            .task { state.connect() }
        } else {
            NavigationStack {
                PairingView()
            }
        }
    }
}
