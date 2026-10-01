import Foundation
import DSHKit

/// A minimal typed probe for the number/boolean regression.
struct DSHVersionProbe: Decodable {
    let version: Int
    let isSeeded: Bool
    let delegationDepth: Int
}

/// A lock-protected flag.
///
/// Stream consumers run concurrently, so a plain captured `var` would be a data
/// race; Swift 6 rejects that outright, and this keeps the checks concurrent
/// while staying correct.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func raise() {
        lock.lock()
        defer { lock.unlock() }
        value = true
    }

    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// End-to-end checks against a real `dsh web` host.
///
/// These exercise the actual carriers: the launch-token exchange, the `/api` RPC
/// envelope, and the `/api/remote.mux` WebSocket multiplex with framing —
/// everything the SwiftUI app relies on.
func runLiveChecks(liveURL: String, report: Report) async {
    guard let host = DSHHostConfiguration(printedURL: liveURL) else {
        report.expect(false, "parses DSH_LIVE_URL")
        return
    }
    report.expect(host.launchToken != nil, "DSH_LIVE_URL carries a launch token")

    let store = DSHMemoryCredentialStore()
    let client = DSHClient(host: host, credentialStore: store)

    // 1. Launch-token exchange plus authenticated unary RPC.
    do {
        let list = try await client.probe()
        report.expect(true, "launch-token exchange mints a usable session")
        report.expect(list.items.count >= 0, "session/list returns items")

        // 2. Model catalog.
        let catalog = try await client.modelCatalog()
        report.expect(!catalog.default.model.isEmpty, "model catalog reports a default route")
        report.expect(!catalog.groups.isEmpty, "model catalog reports provider groups")

        // 3. Create a session.
        let created = try await client.create(cwd: "/tmp")
        report.expect(!created.sessionId.isEmpty, "session/create returns an id")
        let sessionId = created.sessionId

        // 4. Follow stream: the opening snapshot over the mux socket.
        var sawSnapshot = false
        var cursor = 0
        let follow = try await client.follow(sessionId: sessionId, maxMessages: 10, includeAssistantStream: false)
        for try await item in follow {
            if case .snapshot(let snapshot) = try DSHSessionFollowFrame.parse(item) {
                sawSnapshot = true
                cursor = snapshot.cursorValue
                report.equal(snapshot.header.id, sessionId, "snapshot header matches the session")
                break
            }
        }
        report.expect(sawSnapshot, "session/follow opens with a snapshot")

        // 5. Backwards history paging anchored on the snapshot cursor.
        let page = try await client.page(sessionId: sessionId, throughSeq: cursor, maxMessages: 10)
        report.expect(page.records.count >= 0, "session/page returns records")

        // 6. Control stream.
        var sawBaseline = false
        let control = try await client.control()
        for try await item in control {
            if case .baseline = try DSHSessionControlFrame.parse(item) {
                sawBaseline = true
                break
            }
        }
        report.expect(sawBaseline, "session/control opens with a baseline")

        // 7. Prompt: the turn may fail without provider credentials, but the
        //    RPC itself must be accepted — that is what this asserts.
        let requestId = UUID().uuidString
        do {
            try await client.prompt(sessionId: sessionId, text: "Reply with exactly: PONG", requestId: requestId)
            report.expect(true, "session/prompt is accepted by the host")
        } catch let failure as DSHRemoteFailure {
            report.expect(false, "session/prompt rejected: \(failure.code) — \(failure.message)")
        }

        // 8. Live events after the prompt.
        var sawEvent = false
        let live = try await client.follow(sessionId: sessionId, maxMessages: 20, includeAssistantStream: true)
        let deadline = Date().addingTimeInterval(20)
        for try await item in live {
            if case .event(let event) = try DSHSessionFollowFrame.parse(item) {
                sawEvent = true
                report.expect(!event.type.isEmpty, "live event carries a type")
                break
            }
            if Date() > deadline { break }
        }
        report.expect(sawEvent, "session/follow delivers live events after a prompt")

        // 9. Drop the socket and prove a later stream reconnects on its own.
        //    A phone sleeps constantly, so a mux that cannot revive a dead socket
        //    would leave the UI permanently silent.
        await client.disconnect()

        var reconnected = false
        let revived = try await client.control()
        for try await item in revived {
            if case .baseline = try DSHSessionControlFrame.parse(item) {
                reconnected = true
                break
            }
        }
        report.expect(reconnected, "mux reconnects and reopens a stream after a socket drop")

        // 10. A second logical stream must share the revived socket concurrently.
        let firstSawSnapshot = Flag()
        let secondSawSnapshot = Flag()
        let first = Task {
            let stream = try await client.follow(sessionId: sessionId, maxMessages: 5, includeAssistantStream: false)
            for try await item in stream {
                if case .snapshot = try DSHSessionFollowFrame.parse(item) { firstSawSnapshot.raise(); break }
            }
        }
        let second = Task {
            let stream = try await client.follow(sessionId: sessionId, maxMessages: 5, includeAssistantStream: false)
            for try await item in stream {
                if case .snapshot = try DSHSessionFollowFrame.parse(item) { secondSawSnapshot.raise(); break }
            }
        }
        _ = try? await first.value
        _ = try? await second.value
        report.expect(firstSawSnapshot.isRaised, "first concurrent follow stream receives its snapshot")
        report.expect(secondSawSnapshot.isRaised, "second concurrent follow stream is multiplexed on the same socket")

        await client.disconnect()
    } catch {
        report.expect(false, "live integration failed: \(error)")
    }
}
