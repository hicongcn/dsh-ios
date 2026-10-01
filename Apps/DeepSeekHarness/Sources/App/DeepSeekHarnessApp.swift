import SwiftUI

/// DeepSeek Harness for iOS.
///
/// The app is a native client for a `dsh web` host: it speaks the same `/api`
/// RPC envelope and `/api/remote.mux` WebSocket protocol as the official browser
/// UI, which is what makes a session started here appear in the desktop client
/// and vice versa.
@main
struct DeepSeekHarnessApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .task {
                    // A stored cookie makes relaunch seamless; without one the UI
                    // stays on the connect screen.
                    await state.reconnectIfPossible()
                }
        }
    }
}

/// Switches between the connection screen and the session browser.
struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if state.isConnected {
                MainView()
            } else {
                ConnectView()
            }
        }
        .animation(.default, value: state.isConnected)
    }
}
