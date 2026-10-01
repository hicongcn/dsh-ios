import SwiftUI
import DSHKit

/// One session's transcript, with live streaming output and a prompt bar.
struct ConversationView: View {
    @Environment(AppState.self) private var state
    let sessionId: String

    var body: some View {
        VStack(spacing: 0) {
            TimelineList()
            Divider()
            PromptBar()
        }
        .navigationTitle(state.selectedSession?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ModelMenu(catalog: state.catalog, active: state.activeModel) { selection in
                    Task { await state.selectModel(selection) }
                } onFork: {
                    Task { await state.forkSelected() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await state.cancelTurn() }
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .disabled(!(state.selectedSession?.running ?? false))
            }
        }
        .task {
            // Selecting drives the follow stream; re-selecting the same session
            // after a push is harmless because the previous task is cancelled.
            if state.selectedSessionId != sessionId || state.timeline.rows.isEmpty {
                await state.select(sessionId)
            }
        }
        .overlay(alignment: .top) {
            if !state.queued.isEmpty {
                QueueBanner(count: state.queued.count)
            }
        }
    }
}

/// Model picker plus the fork action.
///
/// Extracted from the toolbar, then split further, because CI showed the Swift
/// type checker cannot solve this shape: nesting `Menu → ForEach → Section →
/// ForEach → Button` with optional comparisons makes it either time out or fail
/// to emit a diagnostic at all.
///
/// Every value here carries an explicit type and each `@ViewBuilder` body stays
/// shallow, which is what keeps inference tractable. Note the explicit `groups`
/// property: `catalog?.groups ?? []` leaves the empty-array literal without a
/// type, and that ambiguity is what tipped the checker over.
private struct ModelMenu: View {
    let catalog: DSHModelCatalog?
    let active: DSHModelSelection?
    let onSelect: (DSHModelSelection) -> Void
    let onFork: () -> Void

    private var groups: [DSHModelProviderGroup] {
        catalog?.groups ?? []
    }

    var body: some View {
        Menu {
            menuItems
        } label: {
            Label("Model", systemImage: "cpu")
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        ForEach(groups) { group in
            Section(group.name) {
                ModelGroupRows(
                    group: group,
                    active: active,
                    onSelect: onSelect
                )
            }
        }

        Divider()

        Button {
            onFork()
        } label: {
            Label("Fork from here", systemImage: "arrow.triangle.branch")
        }
    }
}

/// The models of one provider group.
private struct ModelGroupRows: View {
    let group: DSHModelProviderGroup
    let active: DSHModelSelection?
    let onSelect: (DSHModelSelection) -> Void

    var body: some View {
        ForEach(group.models, id: \.id) { model in
            Button {
                onSelect(DSHModelSelection(
                    provider: group.id,
                    model: model.id,
                    reasoningEffort: nil
                ))
            } label: {
                Text(label(for: model))
            }
        }
    }

    /// Prefix the active route so it is identifiable without a custom row view.
    private func label(for model: DSHModelCatalogModel) -> String {
        guard let active else { return model.name }
        guard active.provider == group.id, active.model == model.id else { return model.name }
        return "✓ \(model.name)"
    }
}

/// The transcript, rendered from the folded timeline.
private struct TimelineList: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if state.timeline.hasMoreHistory {
                        Button("Load earlier messages") {
                            Task { await state.loadOlderHistory() }
                        }
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                    }

                    ForEach(state.timeline.rows) { row in
                        TimelineRowView(row: row)
                            .id(row.id)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: state.timeline.rows.last?.id) { _, newValue in
                // Follow new output, but never fight the user's own scrolling.
                guard let newValue else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(newValue, anchor: .bottom)
                }
            }
        }
    }
}

/// One timeline row, styled per kind.
private struct TimelineRowView: View {
    let row: DSHTimelineRow

    var body: some View {
        switch row.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(row.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                    .textSelection(.enabled)
            }

        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Assistant").font(.caption2).foregroundStyle(.secondary)
                    if row.isStreaming {
                        ProgressView().controlSize(.mini)
                    }
                }
                Text(row.text).textSelection(.enabled)
            }

        case .reasoning:
            DisclosureGroup {
                Text(row.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } label: {
                Label("Reasoning", systemImage: "brain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .system(let label):
            Text(row.text)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .accessibilityLabel("\(label) message")

        case .toolCall(let name, let arguments):
            DisclosureGroup {
                Text(arguments)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            } label: {
                Label(name, systemImage: "wrench.and.screwdriver")
                    .font(.caption)
            }

        case .toolResult(let isError):
            Label(isError ? "Tool failed" : "Tool finished",
                  systemImage: isError ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(isError ? .red : .secondary)

        case .turnError(let message):
            Label(message, systemImage: "exclamationmark.octagon")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

/// The prompt composer.
private struct PromptBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message the Harness…", text: $state.draft, axis: .vertical)
                .lineLimit(1...6)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))

            Button {
                Task { await state.sendPrompt() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if state.selectedSession?.running ?? false {
                Button {
                    Task { await state.sendPrompt(steer: true) }
                } label: {
                    Image(systemName: "arrow.triangle.turn.up.right.circle")
                        .font(.title2)
                }
                .disabled(state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Steer the running turn")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Shows how many prompts are waiting in the session inbox.
private struct QueueBanner: View {
    let count: Int

    var body: some View {
        Text("\(count) queued")
            .font(.caption2)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
            .padding(.top, 6)
    }
}
