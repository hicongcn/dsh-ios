import Foundation
import DSHKit

// MARK: - Assertions

/// Tiny harness so unit checks run where XCTest is unavailable.
///
/// `swift test` needs the Xcode-bundled TestingMacros plugin; a command-line
/// tools-only machine fails to link both XCTest and swift-testing. Keeping the
/// checks here means `swift run dshkit-selftest` verifies the protocol layer
/// everywhere, and the same assertions stay runnable in CI with a real Xcode.
final class Report {
    private(set) var passed = 0
    private(set) var failed = 0
    private var failures: [String] = []

    func expect(_ condition: Bool, _ label: String) {
        if condition {
            passed += 1
        } else {
            failed += 1
            failures.append(label)
            print("  FAIL  \(label)")
        }
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        if actual == expected {
            passed += 1
        } else {
            failed += 1
            failures.append("\(label): got \(actual), expected \(expected)")
            print("  FAIL  \(label): got \(actual), expected \(expected)")
        }
    }

    func group(_ name: String) {
        print("\n== \(name) ==")
    }

    func finish() -> Int32 {
        print("\n----------------------------------------")
        if failed == 0 {
            print("PASS  \(passed) checks")
            return 0
        }
        print("FAIL  \(failed) failed, \(passed) passed")
        for failure in failures { print("  - \(failure)") }
        return 1
    }
}

// MARK: - Helpers

func makeJSON(_ raw: String) -> DSHJSON? {
    guard let data = raw.data(using: .utf8) else { return nil }
    return try? DSHKit.DSHRPCClient.decode(data)
}

// MARK: - Checks

let report = Report()

report.group("DSHHostConfiguration")
do {
    let fromPrinted = DSHHostConfiguration(printedURL: "http://127.0.0.1:3080/?token=AbC_-123")
    report.expect(fromPrinted != nil, "parses the URL printed by dsh web")
    report.equal(fromPrinted?.launchToken, "AbC_-123", "extracts the launch token")
    report.equal(fromPrinted?.baseURL.absoluteString, "http://127.0.0.1:3080", "strips the token query")
    report.equal(
        fromPrinted?.streamMuxURL.absoluteString,
        "ws://127.0.0.1:3080/api/remote.mux",
        "derives the ws mux URL"
    )
    report.equal(
        fromPrinted?.apiBaseURL.absoluteString,
        "http://127.0.0.1:3080/api",
        "derives the api base URL"
    )

    let lan = DSHHostConfiguration(printedURL: "http://192.168.1.20:8080/?token=xyz")
    report.equal(lan?.baseURL.absoluteString, "http://192.168.1.20:8080", "keeps a LAN authority intact")

    let bare = DSHHostConfiguration(printedURL: "http://127.0.0.1:3080")
    report.equal(bare?.launchToken, nil, "bare origin yields no token")

    report.expect(DSHHostConfiguration(printedURL: "") == nil, "rejects an empty URL")
    report.expect(DSHHostConfiguration(printedURL: "ftp://host/") == nil, "rejects a non-http scheme")

    report.equal(
        DSHAuthBootstrap.authority(for: URL(string: "http://127.0.0.1:7799")!),
        "127.0.0.1:7799",
        "computes the cookie authority"
    )
    report.equal(
        DSHAuthBootstrap.authority(for: URL(string: "https://host.example")!),
        "host.example:443",
        "defaults the https port"
    )
}

report.group("Set-Cookie parsing")
do {
    let header = "dsh-auth-abc123=v1.eyJ2ZXJzaW9uIjoxfQ.sig; Max-Age=2592000; Path=/; HttpOnly; SameSite=Strict"
    report.equal(
        DSHAuthBootstrap.cookieValue(fromSetCookie: header),
        "dsh-auth-abc123=v1.eyJ2ZXJzaW9uIjoxfQ.sig",
        "extracts name=value from Set-Cookie"
    )
    report.expect(
        DSHAuthBootstrap.cookieValue(fromSetCookie: "session=1; Path=/") == nil,
        "rejects a foreign cookie name"
    )
    report.expect(
        DSHAuthBootstrap.cookieValue(fromSetCookie: "dsh-auth-abc=") == nil,
        "rejects an empty cookie value"
    )
}

report.group("RPC envelope")
do {
    let request = DSHClientRequest(rpcId: "rpc-1", method: "session/list", args: .object(["_request": .object([:])]))
    let body = request.body
    report.equal(body["type"]?.stringValue, "client-request", "envelope carries the request type")
    report.equal(body["rpcId"]?.stringValue, "rpc-1", "envelope carries the rpcId")
    report.equal(body["method"]?.stringValue, "session/list", "envelope carries the method")
    report.equal(body["payload"]?["args"]?["_request"]?.objectValue != nil, true, "payload is nested under args")
    report.equal(body.objectValue?.count, 4, "envelope has exactly the four wire keys")

    let success = makeJSON(#"{"type":"server-response","rpcId":"rpc-1","result":{"ok":true,"value":{"items":[]}}}"#)
    report.expect(success != nil, "decodes a success response")
    if let success {
        let parsed = try? DSHServerResponse.parse(success)
        report.equal(parsed?.rpcId, "rpc-1", "parses the response rpcId")
        report.equal(parsed?.result.value?["items"]?.arrayValue?.count, 0, "unwraps the success value")
    }

    let failure = makeJSON(#"{"type":"server-response","rpcId":"r2","result":{"ok":false,"error":{"code":"session/not-found","message":"no session x","details":{"sessionId":"x"}}}}"#)
    if let failure, let parsed = try? DSHServerResponse.parse(failure) {
        report.equal(parsed.result.failure?.code, "session/not-found", "unwraps the failure code")
        report.equal(parsed.result.failure?.details["sessionId"]?.stringValue, "x", "keeps failure details")
    } else {
        report.expect(false, "decodes a failure response")
    }

    let badEnvelope = makeJSON(#"{"type":"nope","rpcId":"r","result":{"ok":true,"value":null}}"#)
    var threw = false
    if let badEnvelope { do { _ = try DSHServerResponse.parse(badEnvelope) } catch { threw = true } }
    report.expect(threw, "rejects a malformed envelope")

    let noValue = makeJSON(#"{"type":"server-response","rpcId":"r","result":{"ok":false}}"#)
    threw = false
    if let noValue { do { _ = try DSHServerResponse.parse(noValue) } catch { threw = true } }
    report.expect(threw, "rejects a failure branch without error fields")
}

report.group("Stream envelopes")
do {
    let open = DSHStreamClientMessage.open(streamId: "s1", endpoint: "session/follow", args: .object(["request": .object([:])])).wire
    report.equal(open.objectValue?.count, 4, "open frame has exactly four keys")
    report.equal(open["type"]?.stringValue, "open", "open frame type")
    report.equal(open["streamId"]?.stringValue, "s1", "open frame streamId")
    report.equal(open["endpoint"]?.stringValue, "session/follow", "open frame endpoint")
    report.equal(open["payload"]?["args"]?["request"] != nil, true, "open frame payload nests args")

    let cancel = DSHStreamClientMessage.cancel(streamId: "s1").wire
    report.equal(cancel.objectValue?.count, 2, "cancel frame has exactly two keys")
    report.equal(cancel["type"]?.stringValue, "cancel", "cancel frame type")

    let item = makeJSON(#"{"type":"item","streamId":"s1","value":{"type":"baseline"}}"#)
    if let item, case .item(let id, let value)? = try? DSHStreamServerMessage.parse(item) {
        report.equal(id, "s1", "parses item streamId")
        report.equal(value["type"]?.stringValue, "baseline", "parses item value")
    } else {
        report.expect(false, "parses an item frame")
    }

    let end = makeJSON(#"{"type":"end","streamId":"s1"}"#)
    if let end, case .end(let id)? = try? DSHStreamServerMessage.parse(end) {
        report.equal(id, "s1", "parses an end frame")
    } else {
        report.expect(false, "parses an end frame")
    }

    let errorFrame = makeJSON(#"{"type":"error","streamId":"s1","error":{"code":"gateway/cancelled","message":"aborted","details":{}}}"#)
    if let errorFrame, case .error(_, let failure)? = try? DSHStreamServerMessage.parse(errorFrame) {
        report.equal(failure.code, "gateway/cancelled", "parses an error frame")
    } else {
        report.expect(false, "parses an error frame")
    }

    let unknown = makeJSON(#"{"type":"wat","streamId":"s1"}"#)
    var rejectedUnknown = false
    if let unknown {
        do { _ = try DSHStreamServerMessage.parse(unknown) } catch { rejectedUnknown = true }
    }
    report.expect(rejectedUnknown, "rejects an unknown frame type")
}

report.group("Lossless JSON model")
do {
    let roundTrip = makeJSON(#"{"a":[1,2.5,true,null,"s"],"b":{"c":false}}"#)
    report.expect(roundTrip != nil, "decodes mixed JSON")
    if let roundTrip {
        report.equal(roundTrip["a"]?[1]?.doubleValue, 2.5, "keeps fractional numbers")
        report.equal(roundTrip["a"]?[3]?.isNull, true, "keeps null")
        report.equal(roundTrip["b"]?["c"]?.boolValue, false, "keeps nested booleans")
        report.equal(roundTrip["a"]?[9]?.stringValue, nil, "out-of-range index is nil")
        report.equal(roundTrip["missing"]?.stringValue, nil, "missing key is nil")
    }
    report.expect(makeJSON("not json") == nil, "rejects a non-JSON body")
}

report.group("Typed decoding")
do {
    let listValue = makeJSON(#"""
    {"items":[{"sessionId":"s-1","updatedAt":1790834924361,"running":true,"blank":false,
    "cwd":"/tmp","projections":{"asOfSeq":9,"values":{"title":"Hello","agentPreset":"standard",
    "modelSelection":{"lastUsed":null,"next":{"provider":"deepseek-official","model":"deepseek-flash"}},
    "todos":[{"content":"ship","status":"pending"}],"novelKey":{"x":1}}}}]}
    """#)
    var decoded = false
    if let listValue {
        if let list = try? DSHRPCClient.decodeObject(DSHSessionListValue.self, from: listValue) {
            decoded = true
            report.equal(list.items.count, 1, "decodes one summary")
            report.equal(list.items[0].sessionId, "s-1", "decodes the session id")
            report.equal(list.items[0].running, true, "decodes the running flag")
            report.equal(list.items[0].title, "Hello", "reads the folded title")
            report.equal(list.items[0].projections?.values.agentPreset, "standard", "reads the agent preset")
            report.equal(list.items[0].projections?.values.modelSelection?.next?.model, "deepseek-flash", "reads the pending model")
            report.equal(list.items[0].projections?.values.todos?.first?.content, "ship", "reads todos")
            report.equal(
                list.items[0].projections?.values.extras["novelKey"]?["x"]?.intValue,
                1,
                "preserves unknown projection keys"
            )
        }
    }
    report.expect(decoded, "decodes the session list value")

    let follow = makeJSON(#"{"type":"snapshot","header":{"version":1,"id":"s-1","createdAt":1,"isSeeded":false},"cursor":7,"records":[{"type":"event","event":{"type":"user/message","seq":3,"time":2,"data":{"content":[]}}}],"hasMore":false}"#)
    if let follow, case .snapshot(let snapshot)? = try? DSHSessionFollowFrame.parse(follow) {
        report.equal(snapshot.cursorValue, 7, "decodes the follow cursor")
        report.equal(snapshot.header.id, "s-1", "decodes the header id")
        report.equal(snapshot.records.first?.event.type, "user/message", "decodes durable records")
    } else {
        report.expect(false, "decodes a snapshot frame")
    }

    let eventFrame = makeJSON(#"{"type":"event","event":{"type":"turn/end","seq":9,"time":5,"data":{"turn":1}}}"#)
    if let eventFrame, case .event(let event)? = try? DSHSessionFollowFrame.parse(eventFrame) {
        report.equal(event.type, "turn/end", "decodes an event frame")
        report.equal(event.seqValue, 9, "decodes the event seq")
    } else {
        report.expect(false, "decodes an event frame")
    }

    let chunk = makeJSON(#"{"type":"assistant-stream","frame":{"type":"chunk","attemptId":"a-1","revision":2,"index":0,"time":3,"chunk":{"type":"text-delta","text":"hi"}}}"#)
    if let chunk, case .assistantStream(.chunk(_, _, let index, _, let payload))? = try? DSHSessionFollowFrame.parse(chunk) {
        report.equal(index, 0, "decodes an assistant chunk index")
        report.equal(payload["text"]?.stringValue, "hi", "decodes the chunk payload")
    } else {
        report.expect(false, "decodes an assistant-stream frame")
    }

    let control = makeJSON(#"{"type":"baseline","value":{"queues":{},"jobs":{},"projections":{}}}"#)
    if let control, case .baseline(let baseline)? = try? DSHSessionControlFrame.parse(control) {
        report.equal(baseline.queues.isEmpty, true, "decodes an empty baseline")
    } else {
        report.expect(false, "decodes a control baseline")
    }

    let queue = makeJSON(#"{"type":"queue","sessionId":"s-1","items":[{"id":"i-1","placement":"queued","message":{"id":"m-1","content":[]}}]}"#)
    if let queue, case .queue(let sessionId, let items)? = try? DSHSessionControlFrame.parse(queue) {
        report.equal(sessionId, "s-1", "decodes the queue session")
        report.equal(items.first?.messageId, "m-1", "decodes the queued message id")
    } else {
        report.expect(false, "decodes a queue frame")
    }
}

report.group("Memory credential store")
do {
    let store = DSHMemoryCredentialStore()
    report.expect(store.cookie(forAuthority: "a:1") == nil, "starts empty")
    store.setCookie("c1", forAuthority: "a:1")
    report.equal(store.cookie(forAuthority: "a:1"), "c1", "stores per authority")
    report.expect(store.cookie(forAuthority: "a:2") == nil, "isolates authorities")
    store.clearCookie(forAuthority: "a:1")
    report.expect(store.cookie(forAuthority: "a:1") == nil, "clears one authority")
}

// Regression: JSONSerialization bridges NSNumber so that `1 as? Bool` is true.
// Reading booleans by casting would silently turn numeric fields into booleans;
// `header.version` and todo payloads both admit numbers that must stay numbers.
report.group("Number/boolean disambiguation")
do {
    let cases: [(String, String)] = [
        (#"{"v":1}"#, "number"),
        (#"{"v":0}"#, "number"),
        (#"{"v":2}"#, "number"),
        (#"{"v":1.5}"#, "number"),
        (#"{"v":-1}"#, "number"),
        (#"{"v":true}"#, "bool"),
        (#"{"v":false}"#, "bool"),
    ]
    for (raw, expected) in cases {
        guard let json = makeJSON(raw) else {
            report.expect(false, "decodes \(raw)")
            continue
        }
        switch expected {
        case "number":
            report.equal(json["v"]?.doubleValue != nil, true, "\(raw) stays a number")
            report.equal(json["v"]?.boolValue, nil, "\(raw) is not a boolean")
        default:
            report.equal(json["v"]?.boolValue != nil, true, "\(raw) stays a boolean")
            report.equal(json["v"]?.doubleValue, nil, "\(raw) is not a number")
        }
    }

    // The exact shape that previously failed.
    let header = makeJSON(#"{"version":1,"isSeeded":false,"delegationDepth":0}"#)
    if let header {
        let version = try? DSHRPCClient.decodeObject(DSHVersionProbe.self, from: header)
        report.equal(version?.version, 1, "decodes a numeric version field")
        report.equal(version?.isSeeded, false, "decodes a boolean alongside it")
        report.equal(version?.delegationDepth, 0, "decodes a zero-valued number")
    }
}

// Timeline folding: the shapes below are copied verbatim from a real Host log
// (session/page on an isolated dsh web instance), so the folder is tested against
// actual wire payloads rather than invented ones.
report.group("Timeline folding")
do {
    var timeline = DSHTimeline()

    let snapshot = makeJSON(#"""
    {"type":"snapshot","header":{"version":1,"id":"s-1","createdAt":1000,"isSeeded":false,
    "agentPreset":"standard"},"cursor":16,"hasMore":false,"records":[
      {"type":"event","event":{"type":"turn/start","seq":1,"time":1,"data":{"turn":1}}},
      {"type":"event","event":{"type":"user/message","seq":2,"time":2,"surfaceOp":"append",
        "data":{"content":[{"type":"text","text":"Reply with exactly: PONG"}],
        "source":{"kind":"user","rpcId":"r-1"},"role":"user","id":"m-1"}}},
      {"type":"event","event":{"type":"assistant/message","seq":3,"time":3,"surfaceOp":"append",
        "data":{"turn":1,"step":1,"message":{"role":"assistant","content":[{"type":"text","text":"PONG"}]}}}},
      {"type":"event","event":{"type":"turn/end","seq":4,"time":4,"data":{"turn":1,"reason":{"kind":"completed"}}}}
    ]}
    """#)
    if let snapshot, case .snapshot(let parsed)? = try? DSHSessionFollowFrame.parse(snapshot) {
        timeline.apply(.snapshot(parsed))
        report.equal(timeline.header?.id, "s-1", "timeline keeps the session header")
        report.equal(timeline.cursor, 16, "timeline tracks the cursor")
        report.equal(timeline.rows.count, 2, "fold one user row and one assistant row")
        report.equal(timeline.rows.first?.kind, .user, "first row is the prompt")
        report.equal(timeline.rows.first?.text, "Reply with exactly: PONG", "prompt text is extracted")
        report.equal(timeline.rows.last?.kind, .assistant, "second row is the reply")
        report.equal(timeline.rows.last?.text, "PONG", "assistant text is extracted")
        report.equal(timeline.rows.last?.seq, 3, "assistant row keeps its durable seq")
    } else {
        report.expect(false, "parses the timeline snapshot")
    }

    // Streaming chunks accumulate into one in-flight row, then the durable
    // message replaces it rather than duplicating it.
    var live = DSHTimeline()
    live.apply(assistantFrame: .start(attemptId: "a-1", revision: 1, turn: 1, step: 1, startedAfterSeq: -1))
    live.apply(assistantFrame: .chunk(attemptId: "a-1", revision: 1, index: 0, time: 1,
        chunk: .object(["type": .string("block-start"), "blockType": .string("text")])))
    live.apply(assistantFrame: .chunk(attemptId: "a-1", revision: 1, index: 1, time: 2,
        chunk: .object(["type": .string("text-delta"), "text": .string("PO")])))
    live.apply(assistantFrame: .chunk(attemptId: "a-1", revision: 1, index: 2, time: 3,
        chunk: .object(["type": .string("text-delta"), "text": .string("NG")])))
    report.equal(live.rows.count, 1, "chunks accumulate into a single row")
    report.equal(live.rows.first?.text, "PONG", "chunks concatenate in order")
    report.equal(live.rows.first?.isStreaming, true, "in-flight row is marked streaming")

    // Reasoning deltas form their own row.
    live.apply(assistantFrame: .chunk(attemptId: "a-1", revision: 1, index: 3, time: 4,
        chunk: .object(["type": .string("block-start"), "blockType": .string("reasoning")])))
    live.apply(assistantFrame: .chunk(attemptId: "a-1", revision: 1, index: 4, time: 5,
        chunk: .object(["type": .string("reasoning-delta"), "text": .string("thinking")])))
    report.equal(live.rows.count, 2, "reasoning opens a separate row")
    report.equal(live.rows.last?.kind, .reasoning, "reasoning row is typed")
    report.equal(live.rows.last?.text, "thinking", "reasoning text accumulates")

    // The durable message seals the in-flight row in place.
    if let durable = makeJSON(#"{"type":"event","event":{"type":"assistant/message","seq":9,"time":9,"surfaceOp":"append","data":{"turn":1,"step":1,"message":{"role":"assistant","content":[{"type":"text","text":"PONG"}]}}}}"#),
       case .event(let event)? = try? DSHSessionFollowFrame.parse(durable) {
        live.apply(event: event)
        let assistantRows = live.rows.filter { $0.kind == .assistant }
        report.equal(assistantRows.count, 1, "durable message does not duplicate the streamed row")
        report.equal(assistantRows.first?.seq, 9, "durable row adopts the committed seq")
        report.equal(assistantRows.first?.isStreaming, false, "durable row is sealed")
    } else {
        report.expect(false, "parses the durable assistant message")
    }

    // A failed turn surfaces as an error row.
    var failed = DSHTimeline()
    if let end = makeJSON(#"{"type":"event","event":{"type":"turn/end","seq":5,"time":5,"data":{"turn":1,"reason":{"kind":"error","error":{"message":"llm-deepseek: no API key"}}}}}"#),
       case .event(let event)? = try? DSHSessionFollowFrame.parse(end) {
        failed.apply(event: event)
        if case .turnError(let message)? = failed.rows.first?.kind {
            report.equal(message, "llm-deepseek: no API key", "turn failure message is surfaced")
        } else {
            report.expect(false, "failed turn produces a turnError row")
        }
    }

    // Tool calls and results become their own rows.
    var tools = DSHTimeline()
    tools.apply(assistantFrame: .chunk(attemptId: "a-2", revision: 1, index: 0, time: 1,
        chunk: .object([
            "type": .string("tool-call"),
            "id": .string("t-1"),
            "name": .string("bash"),
            "arguments": .string("{\"command\":\"ls\"}"),
        ])))
    report.equal(tools.rows.count, 1, "tool call produces a row")
    if case .toolCall(let name, let arguments)? = tools.rows.first?.kind {
        report.equal(name, "bash", "tool name is captured")
        report.equal(arguments, "{\"command\":\"ls\"}", "tool arguments are captured")
    } else {
        report.expect(false, "tool call row is typed")
    }

    // Older-page prepending keeps live rows in place.
    var paged = DSHTimeline()
    paged.apply(.snapshot(try! DSHRPCClient.decodeObject(DSHSessionSnapshot.self, from: makeJSON(#"""
    {"header":{"version":1,"id":"s-1","createdAt":1000,"isSeeded":false},"cursor":20,"hasMore":true,"records":[
      {"type":"event","event":{"type":"user/message","seq":19,"time":9,"surfaceOp":"append",
        "data":{"content":[{"type":"text","text":"newer"}],"role":"user","id":"m-2"}}}]}
    """#)!)))
    let older = try! DSHRPCClient.decodeObject(DSHSessionPage.self, from: makeJSON(#"""
    {"hasMore":true,"records":[
      {"type":"event","event":{"type":"user/message","seq":5,"time":1,"surfaceOp":"append",
        "data":{"content":[{"type":"text","text":"older"}],"role":"user","id":"m-0"}}}]}
    """#)!)
    paged.prepend(page: older)
    report.equal(paged.rows.count, 2, "prepended page adds rows")
    report.equal(paged.rows.first?.text, "older", "older rows land before live rows")
    report.equal(paged.rows.last?.text, "newer", "live rows stay in place")
    report.equal(paged.hasMoreHistory, true, "paging state is retained")
}

// Live integration: set DSH_LIVE_URL to a running `dsh web` URL (with its
// launch token) to exercise the real wire against a real Host.
if let liveURL = ProcessInfo.processInfo.environment["DSH_LIVE_URL"], !liveURL.isEmpty {
    report.group("Live Host integration")
    await runLiveChecks(liveURL: liveURL, report: report)
} else {
    print("\n(unit checks only; set DSH_LIVE_URL='<dsh web url with token>' for live integration)")
}

exit(report.finish())

