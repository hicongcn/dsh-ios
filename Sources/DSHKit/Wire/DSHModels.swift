import Foundation

// MARK: - Session list

/// One row of `session/list`.
public struct DSHSessionSummary: Decodable, Sendable, Identifiable, Hashable {
    public let sessionId: String
    public let updatedAt: Double
    public let running: Bool
    public let blank: Bool
    public let parentSessionId: String?
    public let origin: String?
    public let cwd: String?
    public let projections: DSHProjectionBaseline?

    public init(
        sessionId: String,
        updatedAt: Double,
        running: Bool,
        blank: Bool,
        parentSessionId: String? = nil,
        origin: String? = nil,
        cwd: String? = nil,
        projections: DSHProjectionBaseline? = nil
    ) {
        self.sessionId = sessionId
        self.updatedAt = updatedAt
        self.running = running
        self.blank = blank
        self.parentSessionId = parentSessionId
        self.origin = origin
        self.cwd = cwd
        self.projections = projections
    }

    public var id: String { sessionId }
    public var updatedDate: Date { Date(timeIntervalSince1970: updatedAt / 1000) }
    /// The durable title, when the Host has folded one.
    public var title: String? { projections?.values.title ?? nil }
}

/// Projection values folded at one Session cursor.
public struct DSHProjectionBaseline: Decodable, Sendable, Hashable {
    public let asOfSeq: Double
    public let values: DSHProjectionValues

    public init(asOfSeq: Double, values: DSHProjectionValues) {
        self.asOfSeq = asOfSeq
        self.values = values
    }
}

/// The projection keys the browser client presents.
///
/// The Host ships a merge-extensible record here, so unknown keys are preserved
/// in `extras` rather than dropped.
public struct DSHProjectionValues: Decodable, Sendable, Hashable {
    public let title: String?
    public let agentPreset: String?
    public let modelSelection: DSHModelSelectionProjection?
    public let todos: [DSHTodoItem]?
    public let extras: [String: DSHJSON]

    public init(
        title: String? = nil,
        agentPreset: String? = nil,
        modelSelection: DSHModelSelectionProjection? = nil,
        todos: [DSHTodoItem]? = nil,
        extras: [String: DSHJSON] = [:]
    ) {
        self.title = title
        self.agentPreset = agentPreset
        self.modelSelection = modelSelection
        self.todos = todos
        self.extras = extras
    }

    private enum Known: String, CodingKey {
        case title, agentPreset, modelSelection, todos
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Known.self)
        title = try? container.decodeIfPresent(String.self, forKey: .title) ?? nil
        agentPreset = try? container.decodeIfPresent(String.self, forKey: .agentPreset) ?? nil
        modelSelection = try? container.decodeIfPresent(DSHModelSelectionProjection.self, forKey: .modelSelection)
        todos = try? container.decodeIfPresent([DSHTodoItem].self, forKey: .todos)

        // Preserve everything else so new Host projections stay visible.
        let dynamic = try decoder.container(keyedBy: DSHAnyKey.self)
        var extras: [String: DSHJSON] = [:]
        for key in dynamic.allKeys where Known(rawValue: key.stringValue) == nil {
            if let value = try? dynamic.decode(DSHJSON.self, forKey: key) {
                extras[key.stringValue] = value
            }
        }
        self.extras = extras
    }
}

/// A coding key for the extensible projection record.
public struct DSHAnyKey: CodingKey {
    public let stringValue: String
    public var intValue: Int? { nil }
    public init?(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { return nil }
    public init(_ string: String) { self.stringValue = string }
}

/// Durable model selection, both consumed and pending.
public struct DSHModelSelectionProjection: Decodable, Sendable, Hashable {
    public let lastUsed: DSHModelSelection?
    public let next: DSHModelSelection?
}

/// One provider plus model route.
public struct DSHModelSelection: Codable, Sendable, Hashable {
    public let provider: String
    public let model: String
    public let reasoningEffort: String?
}

/// One todo row carried by the `todos` projection.
public struct DSHTodoItem: Decodable, Sendable, Hashable {
    public let content: String
    public let status: String
}

// MARK: - Session list value

/// The `session/list` result.
public struct DSHSessionListValue: Decodable, Sendable {
    public let items: [DSHSessionSummary]
}

// MARK: - Model catalog

/// The `session/modelCatalog` result.
public struct DSHModelCatalog: Decodable, Sendable {
    public let `default`: DSHModelSelection
    public let routableProviders: [String]
    public let groups: [DSHModelProviderGroup]
}

public struct DSHModelProviderGroup: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let models: [DSHModelCatalogModel]
}

public struct DSHModelCatalogModel: Decodable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let description: String?
}

// MARK: - Session creation

/// The `session/create` result.
public struct DSHSessionCreateValue: Decodable, Sendable {
    public let sessionId: String
    public let agentPreset: String?
}

// MARK: - Session history

/// One durable event envelope.
public struct DSHSessionWireEvent: Decodable, Sendable, Hashable {
    public let type: String
    public let seq: Double
    public let time: Double
    public let data: DSHJSON
    public let surfaceOp: DSHJSON?

    public var seqValue: Int { Int(seq) }
    public var timestamp: Date { Date(timeIntervalSince1970: time / 1000) }
}

/// One record of a history page or follow snapshot.
public struct DSHSessionHistoryRecord: Decodable, Sendable, Hashable {
    public let type: String
    public let event: DSHSessionWireEvent
}

/// Session identity header carried by a follow snapshot.
public struct DSHSessionWireHeader: Decodable, Sendable, Hashable {
    public let version: Double
    public let id: String
    public let createdAt: Double
    public let cwd: String?
    public let parentSession: String?
    public let isSeeded: Bool
    public let origin: String?
    public let delegationDepth: Double?
    public let agentPreset: String?

    public var createdAtDate: Date { Date(timeIntervalSince1970: createdAt / 1000) }
}

/// One frame of `session/follow`.
///
/// A follow stream opens with exactly one `snapshot`, then emits `event` entries
/// and, when `assistantStream` is requested, process-local `assistant-stream`
/// frames carrying in-flight text before it is durable.
public enum DSHSessionFollowFrame: Sendable {
    case snapshot(DSHSessionSnapshot)
    case event(DSHSessionWireEvent)
    case assistantStream(DSHAssistantStreamFrame)

    /// Parse one stream item into the typed frame.
    public static func parse(_ json: DSHJSON) throws -> DSHSessionFollowFrame {
        guard let type = json["type"]?.stringValue else {
            throw DSHTransportError.malformedResponse("follow frame has no type")
        }
        switch type {
        case "snapshot":
            return .snapshot(try DSHRPCClient.decodeObject(DSHSessionSnapshot.self, from: json))
        case "event":
            guard let event = json["event"] else {
                throw DSHTransportError.malformedResponse("event frame has no event")
            }
            return .event(try DSHRPCClient.decodeObject(DSHSessionWireEvent.self, from: event))
        case "assistant-stream":
            guard let frame = json["frame"] else {
                throw DSHTransportError.malformedResponse("assistant-stream frame has no frame")
            }
            return .assistantStream(DSHAssistantStreamFrame(anyValue: frame))
        default:
            throw DSHTransportError.malformedResponse("unknown follow frame type \(type)")
        }
    }
}

/// One backwards page of a Session log.
public struct DSHSessionPage: Decodable, Sendable {
    public let records: [DSHSessionHistoryRecord]
    public let hasMore: Bool
}

/// The opening window of a follow stream.
public struct DSHSessionSnapshot: Decodable, Sendable {
    public let header: DSHSessionWireHeader
    public let cursor: Double
    public let records: [DSHSessionHistoryRecord]
    public let hasMore: Bool
    public let projections: DSHProjectionBaseline?

    public var cursorValue: Int { Int(cursor) }
}

/// A process-local assistant frame, kept untyped on purpose.
///
/// The chunk payload is an open vocabulary (text deltas, reasoning deltas, tool
/// calls, usage, finish reasons) that the Host extends per release, so the
/// envelope is typed while the chunk stays raw wire JSON.
public enum DSHAssistantStreamFrame: Sendable {
    case start(attemptId: String, revision: Int, turn: Int, step: Int, startedAfterSeq: Double)
    case chunk(attemptId: String, revision: Int, index: Int, time: Double, chunk: DSHJSON)
    case end(attemptId: String, revision: Int, index: Int, outcome: DSHJSON)

    init(anyValue json: DSHJSON) {
        let attemptId = json["attemptId"]?.stringValue ?? ""
        let revision = json["revision"]?.intValue ?? 0
        switch json["type"]?.stringValue {
        case "start":
            self = .start(
                attemptId: attemptId,
                revision: revision,
                turn: json["turn"]?.intValue ?? 0,
                step: json["step"]?.intValue ?? 0,
                startedAfterSeq: json["startedAfterSeq"]?.doubleValue ?? -1
            )
        case "chunk":
            self = .chunk(
                attemptId: attemptId,
                revision: revision,
                index: json["index"]?.intValue ?? 0,
                time: json["time"]?.doubleValue ?? 0,
                chunk: json["chunk"] ?? .null
            )
        default:
            self = .end(
                attemptId: attemptId,
                revision: revision,
                index: json["index"]?.intValue ?? 0,
                outcome: json["outcome"] ?? .null
            )
        }
    }

    public var attemptId: String {
        switch self {
        case .start(let id, _, _, _, _): return id
        case .chunk(let id, _, _, _, _): return id
        case .end(let id, _, _, _): return id
        }
    }
}

// MARK: - Session control

/// One frame of `session/control`: the live queue, jobs, and projections.
public enum DSHSessionControlFrame: Sendable {
    case baseline(DSHSessionControlBaseline)
    case queue(sessionId: String, items: [DSHQueuedItem])
    case jobs(sessionId: String, jobs: [DSHSessionJob])
    case projection(sessionId: String, key: String, value: DSHJSON, seq: Double)

    public static func parse(_ json: DSHJSON) throws -> DSHSessionControlFrame {
        guard let type = json["type"]?.stringValue else {
            throw DSHTransportError.malformedResponse("control frame has no type")
        }
        switch type {
        case "baseline":
            guard let value = json["value"] else {
                throw DSHTransportError.malformedResponse("baseline frame has no value")
            }
            return .baseline(try DSHRPCClient.decodeObject(DSHSessionControlBaseline.self, from: value))
        case "queue":
            let items = (json["items"]?.arrayValue ?? []).compactMap {
                try? DSHRPCClient.decodeObject(DSHQueuedItem.self, from: $0)
            }
            return .queue(sessionId: json["sessionId"]?.stringValue ?? "", items: items)
        case "jobs":
            let jobs = (json["jobs"]?.arrayValue ?? []).compactMap {
                try? DSHRPCClient.decodeObject(DSHSessionJob.self, from: $0)
            }
            return .jobs(sessionId: json["sessionId"]?.stringValue ?? "", jobs: jobs)
        case "projection":
            return .projection(
                sessionId: json["sessionId"]?.stringValue ?? "",
                key: json["key"]?.stringValue ?? "",
                value: json["value"] ?? .null,
                seq: json["seq"]?.doubleValue ?? 0
            )
        default:
            throw DSHTransportError.malformedResponse("unknown control frame type \(type)")
        }
    }
}

/// The initial control snapshot for every known Session.
public struct DSHSessionControlBaseline: Decodable, Sendable {
    public let queues: [String: [DSHQueuedItem]]
    public let jobs: [String: [DSHSessionJob]]
    public let projections: [String: DSHProjectionBaseline]
}

/// One pending inbox item.
public struct DSHQueuedItem: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let placement: String
    public let rpcId: String?
    public let message: DSHQueuedMessage

    /// `id` is the inbox item id; the message id is separate.
    public var messageId: String { message.id }
}

public struct DSHQueuedMessage: Decodable, Sendable, Hashable {
    public let id: String
    public let content: [DSHJSON]
}

/// One background job row.
public struct DSHSessionJob: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let kind: String
    public let label: String
    public let status: String
    public let detail: String?
    public let startedAt: Double
    public let finishedAt: Double?
}

// MARK: - Skills

/// The `skills/list` result.
public struct DSHSkillListValue: Decodable, Sendable {
    public let skills: [DSHSkillEntry]
}

public struct DSHSkillEntry: Decodable, Sendable, Hashable, Identifiable {
    public let name: String
    public let description: String
    public let whenToUse: String?
    public let modelInvocable: Bool

    public var id: String { name }
}
