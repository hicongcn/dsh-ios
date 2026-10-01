import SwiftUI
import DSHKit

/// Browses the Host's sessions and pushes into one conversation.
struct MainView: View {
    @Environment(AppState.self) private var state
    @State private var showingNewSession = false
    @State private var cwd = ""

    var body: some View {
        NavigationStack {
            List {
                if state.sessions.isEmpty {
                    ContentUnavailableView {
                        Label("No sessions", systemImage: "bubble.left.and.text.bubble.right")
                    } description: {
                        Text("Start one to talk to the Harness running on your computer.")
                    } actions: {
                        Button("New session") { showingNewSession = true }
                    }
                } else {
                    ForEach(state.sessions) { session in
                        NavigationLink(value: session.sessionId) {
                            SessionRow(session: session)
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .navigationDestination(for: String.self) { sessionId in
                ConversationView(sessionId: sessionId)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNewSession = true
                    } label: {
                        Label("New session", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Disconnect") {
                        Task { await state.disconnect() }
                    }
                }
            }
            .refreshable { await state.refresh() }
            .sheet(isPresented: $showingNewSession) {
                NewSessionSheet(cwd: $cwd) {
                    let target = cwd.trimmingCharacters(in: .whitespaces)
                    Task { await state.createSession(cwd: target.isEmpty ? nil : target) }
                }
            }
            .overlay {
                if state.phase.isBusy {
                    ProgressView().controlSize(.large)
                }
            }
        }
    }

    /// Sessions cannot be deleted from here.
    ///
    /// The Host protocol exposes no destructive session delete — only workspace
    /// archiving — so the list deliberately offers no swipe-to-delete rather than
    /// implying an erasure the client cannot perform.
}

/// One session row: title, recency, and live state.
private struct SessionRow: View {
    let session: DSHSessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if session.running {
                    ProgressView().controlSize(.mini)
                }
                Text(session.title ?? "Untitled session")
                    .font(.body)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(session.sessionId)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(session.updatedDate, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let cwd = session.cwd {
                Text(cwd)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Collects the working directory for a new session.
private struct NewSessionSheet: View {
    @Binding var cwd: String
    let onCreate: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Working directory (optional)", text: $cwd)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                } footer: {
                    Text("Leave empty to let the Host choose. The directory must already exist on the computer running `dsh web`.")
                }
            }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate()
                        dismiss()
                    }
                }
            }
        }
    }
}
