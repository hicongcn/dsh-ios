import Foundation

/// One displayable row of a Session timeline.
///
/// The Harness log is an event stream, not a transcript: a turn emits
/// `turn/start`, `step/start`, `user/message`, assistant text as either durable
/// `assistant/message` or process-local chunks, and finally `turn/end`. Folding
/// that stream into rows is presentation logic, which keeps it testable here
/// instead of buried in a view.
public struct DSHTimelineRow: Sendable, Identifiable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// A human prompt.
        case user
        /// Assistant output, durable or in flight.
        case assistant
        /// Model reasoning, shown collapsed.
        case reasoning
        /// A system or request-context message, shown compactly.
        case system(String)
        /// A tool invocation with its arguments.
        case toolCall(name: String, arguments: String)
        /// A tool result, with error state.
        case toolResult(isError: Bool)
        /// A turn that ended abnormally.
        case turnError(String)
    }

    public let id: String
    public let kind: Kind
    public let text: String
    /// Durable log position; nil for process-local frames.
    public let seq: Int?
    /// True while the row is still receiving chunks.
    public let isStreaming: Bool

    public init(id: String, kind: Kind, text: String, seq: Int?, isStreaming: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.seq = seq
        self.isStreaming = isStreaming
    }
}

/// Folds durable events and assistant chunks into timeline rows.
///
/// The folder is deliberately append-mostly: durable events arrive in order after
/// the snapshot, and assistant chunks arrive between them keyed by attempt id.
/// Rendering directly from this state keeps SwiftUI updates cheap and avoids
/// reinterpreting the raw log on every frame.
public struct DSHTimeline: Sendable {
    public private(set) var rows: [DSHTimelineRow] = []
    /// Session identity from the follow snapshot.
    public private(set) var header: DSHSessionWireHeader?
    /// Latest durable cursor, used to page backwards and to resync.
    public private(set) var cursor: Int = 0
    /// Whether the Host has older messages before this window.
    public private(set) var hasMoreHistory = false

    /// Row id of the currently open streaming row per attempt.
    private var streamingRows: [String: String] = [:]
    /// Every row id produced by one attempt, so a committed message can replace
    /// the whole in-flight group (text plus reasoning) instead of duplicating it.
    private var attemptRows: [String: [String]] = [:]
    /// Attempt id owning each turn, bridging chunk frames (keyed by attempt) to
    /// committed events (keyed by turn).
    private var turnAttempts: [Int: String] = [:]
    /// Text/reasoning block identity per attempt, to separate blocks cleanly.
    private var activeBlock: [String: String] = [:]
    /// Monotone source for row ids that survive prepending.
    private var streamSerial = 0

    public init() {}

    // MARK: - Frame intake

    /// Apply one follow frame.
    public mutating func apply(_ frame: DSHSessionFollowFrame) {
        switch frame {
        case .snapshot(let snapshot):
            applySnapshot(snapshot)
        case .event(let event):
            apply(event: event)
        case .assistantStream(let frame):
            apply(assistantFrame: frame)
        }
    }

    /// Replace the timeline with a snapshot's opening window.
    public mutating func applySnapshot(_ snapshot: DSHSessionSnapshot) {
        header = snapshot.header
        cursor = snapshot.cursorValue
        hasMoreHistory = snapshot.hasMore
        rows.removeAll()
        streamingRows.removeAll()
        activeBlock.removeAll()
        for record in snapshot.records {
            apply(event: record.event)
        }
    }

    /// Prepend one page of older events, preserving the current rows.
    public mutating func prepend(page: DSHSessionPage) {
        var older: [DSHTimelineRow] = []
        for record in page.records {
            // Reuse the event folder against a throwaway timeline so paging and
            // live folding cannot drift apart.
            var scratch = DSHTimeline()
            scratch.apply(event: record.event)
            older.append(contentsOf: scratch.rows)
        }
        hasMoreHistory = page.hasMore
        rows.insert(contentsOf: older, at: 0)
    }

    /// Apply one durable event.
    public mutating func apply(event: DSHSessionWireEvent) {
        let seq = event.seqValue
        cursor = max(cursor, seq)

        switch event.type {
        case "user/message":
            let text = Self.text(fromContent: event.data["content"])
            guard !text.isEmpty else { return }
            rows.append(DSHTimelineRow(
                id: "user-\(seq)",
                kind: .user,
                text: text,
                seq: seq
            ))

        case "system/message":
            let text = Self.text(fromContent: event.data["message"]?["content"])
            guard !text.isEmpty else { return }
            rows.append(DSHTimelineRow(id: "system-\(seq)", kind: .system("system"), text: text, seq: seq))

        case "assistant/message":
            let text = Self.text(fromContent: event.data["message"]?["content"])
            guard !text.isEmpty else { return }
            // The durable message supersedes the in-flight row for the same turn.
            // Chunks are keyed by attempt id while the committed event carries only
            // the turn, so turn->attempt bridges the two; the streamed row is then
            // upgraded in place so the reply is never shown twice.
            let turn = event.data["turn"]?.intValue
            let attemptId = turn.flatMap { turnAttempts[$0] }

            if let attemptId,
               let index = (attemptRows[attemptId] ?? [])
                   .compactMap({ rowIndex(id: $0) })
                   .first(where: { rows[$0].kind == .assistant })
            {
                let existing = rows[index]
                rows[index] = DSHTimelineRow(id: existing.id, kind: .assistant, text: text, seq: seq)
                sealRows(attemptId)
                retireAttempt(attemptId)
                return
            }

            rows.append(DSHTimelineRow(id: "assistant-\(seq)", kind: .assistant, text: text, seq: seq))
            if let attemptId { retireAttempt(attemptId) }

        case "assistant/attempt":
            // A failed or abandoned attempt carries its partial stream inline.
            let text = Self.text(fromStream: event.data["stream"])
            guard !text.isEmpty else { return }
            rows.append(DSHTimelineRow(id: "attempt-\(seq)", kind: .assistant, text: text, seq: seq))

        case "turn/end":
            let reason = event.data["reason"]
            let kind = reason?["kind"]?.stringValue
            if kind == "error" {
                let message = reason?["error"]?["message"]?.stringValue
                    ?? reason?["failure"]?["message"]?.stringValue
                    ?? "turn failed"
                rows.append(DSHTimelineRow(id: "error-\(seq)", kind: .turnError(message), text: message, seq: seq))
            }

        default:
            break
        }
    }

    /// Apply one process-local assistant frame.
    public mutating func apply(assistantFrame frame: DSHAssistantStreamFrame) {
        switch frame {
        case .start(let attemptId, _, let turn, _, _):
            turnAttempts[turn] = attemptId

        case .chunk(let attemptId, _, _, _, let chunk):
            guard let type = chunk["type"]?.stringValue else { return }
            switch type {
            case "block-start":
                activeBlock[attemptId] = chunk["blockType"]?.stringValue ?? "text"

            case "text-delta", "reasoning-delta":
                let isReasoning = type == "reasoning-delta" || activeBlock[attemptId] == "reasoning"
                guard let delta = chunk["text"]?.stringValue, !delta.isEmpty else { return }
                appendStreaming(attemptId: attemptId, delta: delta, isReasoning: isReasoning)

            case "tool-call":
                let name = chunk["name"]?.stringValue ?? "tool"
                let arguments = chunk["arguments"]?.stringValue ?? ""
                inccurSerial()
                let row = DSHTimelineRow(
                    id: "tool-\(attemptId)-\(streamSerial)",
                    kind: .toolCall(name: name, arguments: arguments),
                    text: name,
                    seq: nil
                )
                rows.append(row)
                attemptRows[attemptId, default: []].append(row.id)

            case "tool-result":
                inccurSerial()
                let row = DSHTimelineRow(
                    id: "result-\(attemptId)-\(streamSerial)",
                    kind: .toolResult(isError: chunk["isError"]?.boolValue ?? false),
                    text: "",
                    seq: nil
                )
                rows.append(row)
                attemptRows[attemptId, default: []].append(row.id)

            case "finish":
                // Seal the streaming row so the next attempt starts a new one.
                sealStreaming(attemptId: attemptId)

            default:
                break
            }

        case .end(let attemptId, _, _, _):
            sealStreaming(attemptId: attemptId)
        }
    }

    // MARK: - Streaming rows

    /// Monotone id source.
    ///
    /// Row ids must never be derived from `rows.count`: paging prepends rows, so
    /// a count-based id can collide with an id minted earlier.
    private mutating func inccurSerial() {
        streamSerial += 1
    }

    /// Look up a live row by its stable id.
    private func rowIndex(id: String) -> Int? {
        rows.firstIndex { $0.id == id }
    }

    private mutating func appendStreaming(attemptId: String, delta: String, isReasoning: Bool) {
        let kindIsReasoning = isReasoning

        if let currentId = streamingRows[attemptId], let index = rowIndex(id: currentId) {
            let existing = rows[index]
            let sameKind: Bool
            switch existing.kind {
            case .reasoning: sameKind = kindIsReasoning
            case .assistant: sameKind = !kindIsReasoning
            default: sameKind = false
            }
            if sameKind {
                rows[index] = DSHTimelineRow(
                    id: existing.id,
                    kind: existing.kind,
                    text: existing.text + delta,
                    seq: nil,
                    isStreaming: true
                )
                return
            }
        }

        // No row of this kind yet: open one and remember it for this attempt.
        inccurSerial()
        let row = DSHTimelineRow(
            id: "stream-\(attemptId)-\(streamSerial)",
            kind: kindIsReasoning ? .reasoning : .assistant,
            text: delta,
            seq: nil,
            isStreaming: true
        )
        rows.append(row)
        streamingRows[attemptId] = row.id
        attemptRows[attemptId, default: []].append(row.id)
    }

    private mutating func sealStreaming(attemptId: String) {
        streamingRows.removeValue(forKey: attemptId)
        sealRows(attemptId)
        activeBlock.removeValue(forKey: attemptId)
    }

    /// Mark every row produced by an attempt as no longer streaming.
    private mutating func sealRows(_ attemptId: String) {
        for id in attemptRows[attemptId] ?? [] {
            guard let index = rowIndex(id: id) else { continue }
            let row = rows[index]
            rows[index] = DSHTimelineRow(
                id: row.id,
                kind: row.kind,
                text: row.text,
                seq: row.seq,
                isStreaming: false
            )
        }
    }

    /// Drop the bookkeeping for one finished attempt.
    private mutating func retireAttempt(_ attemptId: String) {
        activeBlock.removeValue(forKey: attemptId)
        turnAttempts = turnAttempts.filter { $0.value != attemptId }
    }

    // MARK: - Content extraction

    /// Join the `text` parts of a content-block array.
    ///
    /// Content blocks also carry images and files; only text is rendered as a
    /// transcript line, and non-text parts are counted so the UI can note them.
    public static func text(fromContent content: DSHJSON?) -> String {
        guard let parts = content?.arrayValue else { return "" }
        return parts.compactMap { part -> String? in
            guard part["type"]?.stringValue == "text" else { return nil }
            return part["text"]?.stringValue
        }.joined()
    }

    /// Extract assistant text from a detached in-flight stream snapshot.
    public static func text(fromStream stream: DSHJSON?) -> String {
        guard let chunks = stream?.arrayValue else { return "" }
        var text = ""
        for entry in chunks {
            guard let chunk = entry["chunk"] else { continue }
            switch chunk["type"]?.stringValue {
            case "text-delta", "reasoning-delta":
                text += chunk["text"]?.stringValue ?? ""
            default:
                break
            }
        }
        return text
    }

    /// Count non-text parts so the UI can show an attachment note.
    public static func nonTextPartCount(in content: DSHJSON?) -> Int {
        guard let parts = content?.arrayValue else { return 0 }
        return parts.filter { $0["type"]?.stringValue != "text" }.count
    }
}
