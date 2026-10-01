import Foundation
import Observation
import DSHKit

/// Application model: owns the connection, the session list, and one live timeline.
///
/// Everything that touches the network lives here so the SwiftUI views stay
/// declarative. The object is `@MainActor`-isolated, which lets stream consumers
/// mutate observed state directly without hopping actors.
@Observable
@MainActor
final class AppState {
    /// Connection lifecycle, mirrored into the UI.
    enum Phase: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)

        var label: String {
            switch self {
            case .disconnected: return "Not connected"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .failed(let message): return message
            }
        }

        var isBusy: Bool { self == .connecting }
    }

    // MARK: - Observed state

    private(set) var phase: Phase = .disconnected
    private(set) var sessions: [DSHSessionSummary] = []
    private(set) var timeline = DSHTimeline()
    private(set) var catalog: DSHModelCatalog?
    private(set) var jobs: [DSHSessionJob] = []
    private(set) var queued: [DSHQueuedItem] = []
    private(set) var skills: [DSHSkillEntry] = []
    var selectedSessionId: String?
    var draft: String = ""
    var alertMessage: String?

    /// The host URL the user last connected with, kept for one-tap reconnect.
    var rememberedHostURL: String {
        get { UserDefaults.standard.string(forKey: Self.rememberedHostKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.rememberedHostKey) }
    }

    private static let rememberedHostKey = "dsh.host.url"

    // MARK: - Internals

    @ObservationIgnored private var client: DSHClient?
    @ObservationIgnored private var followTask: Task<Void, Never>?
    @ObservationIgnored private var controlTask: Task<Void, Never>?
    @ObservationIgnored private let credentialStore = DSHKeychainCredentialStore()

    var isConnected: Bool { phase == .connected }

    var selectedSession: DSHSessionSummary? {
        sessions.first { $0.sessionId == selectedSessionId }
    }

    /// The model route the selected session will use next.
    var activeModel: DSHModelSelection? {
        selectedSession?.projections?.values.modelSelection?.next ?? catalog?.default
    }

    // MARK: - Connection

    /// Connect using the URL printed by `dsh web`, which carries the launch token.
    func connect(printedURL: String) async {
        guard let host = DSHHostConfiguration(printedURL: printedURL) else {
            phase = .failed("That does not look like a dsh web URL.")
            return
        }

        // A token-less URL can still work when a cookie is already stored for the
        // same authority, so it is not rejected outright.
        phase = .connecting
        alertMessage = nil

        let client = DSHClient(host: host, credentialStore: credentialStore)
        do {
            _ = try await client.probe()
            self.client = client
            rememberedHostURL = printedURL
            phase = .connected
            await refresh()
            await startControlStream()
        } catch {
            self.client = nil
            phase = .failed(Self.describe(error))
        }
    }

    /// Connect using a stored URL and cookie, without a fresh token.
    func reconnectIfPossible() async {
        let saved = rememberedHostURL
        guard !saved.isEmpty, client == nil else { return }
        await connect(printedURL: saved)
    }

    func disconnect() async {
        followTask?.cancel()
        controlTask?.cancel()
        followTask = nil
        controlTask = nil
        await client?.disconnect()
        client = nil
        sessions = []
        timeline = DSHTimeline()
        jobs = []
        queued = []
        skills = []
        selectedSessionId = nil
        phase = .disconnected
    }

    // MARK: - Sessions

    /// Reload the session list and the model catalog.
    func refresh() async {
        guard let client else { return }
        do {
            async let listTask = client.list()
            async let catalogTask = client.modelCatalog()
            sessions = try await listTask.items
            catalog = try await catalogTask
        } catch {
            alertMessage = Self.describe(error)
        }
    }

    /// Create a session and select it.
    func createSession(cwd: String? = nil) async {
        guard let client else { return }
        do {
            let created = try await client.create(cwd: cwd)
            await refresh()
            await select(created.sessionId)
        } catch {
            alertMessage = Self.describe(error)
        }
    }

    /// Select a session and follow it live.
    func select(_ sessionId: String) async {
        guard let client else { return }
        selectedSessionId = sessionId
        timeline = DSHTimeline()

        followTask?.cancel()
        followTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await client.follow(sessionId: sessionId, includeAssistantStream: true)
                for try await item in stream {
                    if Task.isCancelled { return }
                    let frame = try DSHSessionFollowFrame.parse(item)
                    self.timeline.apply(frame)
                }
            } catch is CancellationError {
                // Switching sessions cancels the previous follow; not an error.
            } catch {
                if !Task.isCancelled {
                    self.alertMessage = Self.describe(error)
                }
            }
        }

        // Skills are per-session composition, so they refresh with the selection.
        if let loaded = try? await client.skills(sessionId: sessionId) {
            skills = loaded.skills
        }
    }

    /// Load one page of older history and prepend it.
    func loadOlderHistory() async {
        guard let client, let sessionId = selectedSessionId, timeline.hasMoreHistory else { return }
        let oldest = timeline.rows.compactMap(\.seq).min()
        do {
            let page = try await client.page(
                sessionId: sessionId,
                throughSeq: timeline.cursor,
                beforeSeq: oldest,
                maxMessages: 30
            )
            timeline.prepend(page: page)
        } catch {
            alertMessage = Self.describe(error)
        }
    }

    // MARK: - Prompting

    /// Send the current draft as a prompt.
    func sendPrompt(steer: Bool = false) async {
        guard let client, let sessionId = selectedSessionId else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        do {
            try await client.prompt(sessionId: sessionId, text: text, mode: steer ? "steer" : "queue")
            draft = ""
            await refresh()
        } catch {
            alertMessage = Self.describe(error)
        }
    }

    /// Cancel the selected session's active turn.
    func cancelTurn() async {
        guard let client, let sessionId = selectedSessionId else { return }
        do {
            try await client.cancel(sessionId: sessionId)
            await refresh()
        } catch {
            alertMessage = Self.describe(error)
        }
    }

    /// Select the model route used by the next request.
    func selectModel(_ selection: DSHModelSelection) async {
        guard let client, let sessionId = selectedSessionId else { return }
        do {
            _ = try await client.selectModel(
                sessionId: sessionId,
                provider: selection.provider,
                model: selection.model,
                reasoningEffort: selection.reasoningEffort
            )
            await refresh()
            await select(sessionId)
        } catch {
            alertMessage = Self.describe(error)
        }
    }

    /// Fork the selected session at its current cursor.
    func forkSelected() async {
        guard let client, let sessionId = selectedSessionId else { return }
        do {
            // Only a completed turn can be forked from, so use the last durable seq.
            let lastSeq = timeline.rows.compactMap(\.seq).max()
            let forked = try await client.fork(sessionId: sessionId, atSeq: lastSeq)
            await refresh()
            if !forked.isEmpty { await select(forked) }
        } catch {
            alertMessage = Self.describe(error)
        }
    }

    // MARK: - Control stream

    /// Follow the live control stream for queue, jobs, and projections.
    private func startControlStream() async {
        guard let client else { return }
        controlTask?.cancel()
        controlTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await client.control()
                for try await item in stream {
                    if Task.isCancelled { return }
                    let frame = try DSHSessionControlFrame.parse(item)
                    self.apply(control: frame)
                }
            } catch {
                // A dropped control stream is recoverable; the next follow resyncs.
            }
        }
    }

    private func apply(control frame: DSHSessionControlFrame) {
        guard let sessionId = selectedSessionId else {
            if case .baseline(let baseline) = frame {
                queued = baseline.queues.values.first ?? []
                jobs = baseline.jobs.values.first ?? []
            }
            return
        }

        switch frame {
        case .baseline(let baseline):
            queued = baseline.queues[sessionId] ?? []
            jobs = baseline.jobs[sessionId] ?? []
        case .queue(let id, let items):
            guard id == sessionId else { return }
            queued = items
        case .jobs(let id, let list):
            guard id == sessionId else { return }
            jobs = list
        case .projection(let id, let key, let value, _):
            guard id == sessionId else { return }
            applyProjection(key: key, value: value)
        }
    }

    /// Merge one projection update into the matching session summary.
    private func applyProjection(key: String, value: DSHJSON) {
        guard let sessionId = selectedSessionId,
              let index = sessions.firstIndex(where: { $0.sessionId == sessionId })
        else { return }

        if key == "title", let title = value.stringValue {
            sessions[index] = sessions[index].replacingTitle(title)
        }
    }

    // MARK: - Errors

    /// Turn any thrown value into one readable line.
    static func describe(_ error: Error) -> String {
        switch error {
        case let failure as DSHRemoteFailure:
            return "\(failure.code): \(failure.message)"
        case let transport as DSHTransportError:
            return transport.message
        case let auth as DSHAuthError:
            return auth.errorDescription ?? "authentication failed"
        default:
            return error.localizedDescription
        }
    }
}

extension DSHSessionSummary {
    /// Return a copy with an updated title, preserving every other field.
    func replacingTitle(_ newTitle: String) -> DSHSessionSummary {
        DSHSessionSummary(
            sessionId: sessionId,
            updatedAt: updatedAt,
            running: running,
            blank: blank,
            parentSessionId: parentSessionId,
            origin: origin,
            cwd: cwd,
            projections: projections?.replacingTitle(newTitle)
        )
    }
}

extension DSHProjectionBaseline {
    func replacingTitle(_ newTitle: String) -> DSHProjectionBaseline {
        DSHProjectionBaseline(
            asOfSeq: asOfSeq,
            values: values.replacingTitle(newTitle)
        )
    }
}

extension DSHProjectionValues {
    func replacingTitle(_ newTitle: String) -> DSHProjectionValues {
        DSHProjectionValues(
            title: newTitle,
            agentPreset: agentPreset,
            modelSelection: modelSelection,
            todos: todos,
            extras: extras
        )
    }
}
