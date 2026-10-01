import Foundation

/// Owns the resolved browser cookie for one host generation.
///
/// Harness cookie validation is per process: a restarted host rotates its signing
/// secret, so a cached cookie starts returning `401` and must be exchanged again
/// from a fresh launch token. This actor serializes that refresh so concurrent
/// callers cannot race the store.
public actor DSHCredentialProvider {
    private let bootstrap: DSHAuthBootstrap
    private let configuration: DSHHostConfiguration

    public init(bootstrap: DSHAuthBootstrap, configuration: DSHHostConfiguration) {
        self.bootstrap = bootstrap
        self.configuration = configuration
    }

    /// The cookie for ordinary calls, using the stored value when available.
    public func cookie() async throws -> String {
        try await bootstrap.resolveCookie(for: configuration)
    }

    /// Exchange the launch token again, e.g. after a `401` from a restarted host.
    public func refreshedCookie() async throws -> String {
        try await bootstrap.resolveCookie(for: configuration, forceRefresh: true)
    }
}

/// The Harness Session API surface an iOS client needs.
///
/// Every method maps to one Remote endpoint on the `/api` channel; stream methods
/// open a logical stream on the shared `/api/remote.mux` socket. Argument shapes
/// follow each endpoint's generated descriptor, so the wire layout is identical to
/// the browser client's.
public actor DSHClient {
    public let host: DSHHostConfiguration

    private let rpc: DSHRPCClient
    private let mux: DSHStreamMux
    private let credentials: DSHCredentialProvider

    public init(
        host: DSHHostConfiguration,
        credentialStore: DSHCredentialStore,
        urlSession: URLSession? = nil
    ) {
        let session = urlSession ?? DSHRPCClient.makeSession()
        let bootstrap = DSHAuthBootstrap(session: session, store: credentialStore)
        let credentials = DSHCredentialProvider(bootstrap: bootstrap, configuration: host)

        self.host = host
        self.credentials = credentials
        self.rpc = DSHRPCClient(host: host, urlSession: session) {
            try await credentials.cookie()
        }
        self.mux = DSHStreamMux(host: host, urlSession: session) {
            try await credentials.cookie()
        }
    }

    // MARK: - Connection

    /// Verify that the host accepts this client's credential.
    ///
    /// Using `session/list` as the probe keeps the check on the same carrier and
    /// authentication path every later call uses.
    @discardableResult
    public func probe() async throws -> DSHSessionListValue {
        try await list()
    }

    /// Close the shared stream socket.
    public func disconnect() async {
        await mux.shutdown()
    }

    // MARK: - Session lifecycle

    /// List every Session known to the Host.
    public func list() async throws -> DSHSessionListValue {
        let value = try await callWithAuthRetry("session/list", args: .object(["_request": .object([:])]))
        return try DSHRPCClient.decodeObject(DSHSessionListValue.self, from: value)
    }

    /// Create a Session, optionally in an explicit working directory.
    public func create(
        cwd: String? = nil,
        sessionId: String? = nil,
        agentPreset: String? = nil
    ) async throws -> DSHSessionCreateValue {
        var request: [String: DSHJSON] = [:]
        if let cwd { request["cwd"] = .string(cwd) }
        if let sessionId { request["sessionId"] = .string(sessionId) }
        if let agentPreset { request["agentPreset"] = .string(agentPreset) }

        let value = try await callWithAuthRetry(
            "session/create",
            args: .object(["request": .object(request)])
        )
        return try DSHRPCClient.decodeObject(DSHSessionCreateValue.self, from: value)
    }

    /// Send one prompt to a Session.
    ///
    /// - Parameters:
    ///   - mode: `queue` appends to the inbox; `steer` redirects the running turn.
    ///   - requestId: client-minted identity echoed back on the accepted message,
    ///     used to retire the local submission echo.
    ///   - text: the prompt body.
    public func prompt(
        sessionId: String,
        text: String,
        mode: String = "queue",
        requestId: String = UUID().uuidString,
        clientTimeZone: String? = TimeZone.current.identifier
    ) async throws {
        var request: [String: DSHJSON] = [
            "requestId": .string(requestId),
            "sessionId": .string(sessionId),
            "mode": .string(mode),
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
        ]
        if let clientTimeZone { request["clientTimeZone"] = .string(clientTimeZone) }

        // The receipt is `{"accepted": true}`; a failure throws the Harness code.
        _ = try await callWithAuthRetry("session/prompt", args: .object(["request": .object(request)]))
    }

    /// Cancel a Session's active turn.
    public func cancel(sessionId: String) async throws {
        _ = try await callWithAuthRetry(
            "session/cancel",
            args: .object(["request": .object(["sessionId": .string(sessionId)])])
        )
    }

    /// Rename a Session; returns the normalized title and its committed seq.
    public func rename(sessionId: String, title: String) async throws -> DSHJSON {
        try await callWithAuthRetry(
            "session/rename",
            args: .object(["request": .object([
                "sessionId": .string(sessionId),
                "title": .string(title),
            ])])
        )
    }

    /// Fork a Session at an optional event position.
    public func fork(sessionId: String, atSeq: Int? = nil) async throws -> String {
        var request: [String: DSHJSON] = ["sessionId": .string(sessionId)]
        if let atSeq { request["atSeq"] = .number(Double(atSeq)) }
        let value = try await callWithAuthRetry("session/fork", args: .object(["request": .object(request)]))
        return value["sessionId"]?.stringValue ?? ""
    }

    // MARK: - History

    /// Read one backwards page of a Session log.
    ///
    /// `throughSeq` must come from the matching follow snapshot's `cursor`, which
    /// is what keeps paging aligned with the live stream.
    public func page(
        sessionId: String,
        throughSeq: Int,
        beforeSeq: Int? = nil,
        maxMessages: Int? = nil
    ) async throws -> DSHSessionPage {
        var request: [String: DSHJSON] = [
            "address": .object(["kind": .string("session"), "sessionId": .string(sessionId)]),
            "throughSeq": .number(Double(throughSeq)),
        ]
        if let beforeSeq { request["beforeSeq"] = .number(Double(beforeSeq)) }
        if let maxMessages { request["maxMessages"] = .number(Double(maxMessages)) }

        let value = try await callWithAuthRetry("session/page", args: .object(["request": .object(request)]))
        return try DSHRPCClient.decodeObject(DSHSessionPage.self, from: value)
    }

    // MARK: - Models and skills

    /// Read the routable model catalog.
    public func modelCatalog() async throws -> DSHModelCatalog {
        let value = try await callWithAuthRetry("session/modelCatalog", args: .object([:]))
        return try DSHRPCClient.decodeObject(DSHModelCatalog.self, from: value)
    }

    /// Select the model route a Session's next request uses.
    public func selectModel(
        sessionId: String,
        provider: String,
        model: String,
        reasoningEffort: String? = nil
    ) async throws -> DSHModelSelection {
        var request: [String: DSHJSON] = [
            "sessionId": .string(sessionId),
            "provider": .string(provider),
            "model": .string(model),
        ]
        if let reasoningEffort { request["reasoningEffort"] = .string(reasoningEffort) }
        let value = try await callWithAuthRetry("session/selectModel", args: .object(["request": .object(request)]))
        return try DSHRPCClient.decodeObject(DSHModelSelection.self, from: value["selected"] ?? value)
    }

    /// List the skills visible to one Session.
    public func skills(sessionId: String) async throws -> DSHSkillListValue {
        let value = try await callWithAuthRetry(
            "skills/list",
            args: .object(["request": .object(["sessionId": .string(sessionId)])])
        )
        return try DSHRPCClient.decodeObject(DSHSkillListValue.self, from: value)
    }

    // MARK: - Streams

    /// Follow one Session: the opening snapshot, then durable events.
    ///
    /// - Parameter includeAssistantStream: also receive process-local frames that
    ///   carry in-flight assistant output before it becomes durable.
    public func follow(
        sessionId: String,
        maxMessages: Int = 50,
        includeAssistantStream: Bool = true
    ) async throws -> DSHStream {
        var request: [String: DSHJSON] = [
            "address": .object(["kind": .string("session"), "sessionId": .string(sessionId)]),
            "maxMessages": .number(Double(maxMessages)),
        ]
        if includeAssistantStream { request["assistantStream"] = .bool(true) }
        return try await mux.open("session/follow", args: .object(["request": .object(request)]))
    }

    /// Follow one subagent Session addressed through its parent.
    public func followSubagent(
        parentSessionId: String,
        childSessionId: String,
        mode: String = "continuable",
        maxMessages: Int = 50,
        includeAssistantStream: Bool = true
    ) async throws -> DSHStream {
        var request: [String: DSHJSON] = [
            "address": .object([
                "kind": .string("subagent"),
                "parentSessionId": .string(parentSessionId),
                "childSessionId": .string(childSessionId),
                "mode": .string(mode),
            ]),
            "maxMessages": .number(Double(maxMessages)),
        ]
        if includeAssistantStream { request["assistantStream"] = .bool(true) }
        return try await mux.open("session/follow", args: .object(["request": .object(request)]))
    }

    /// Observe live control state: pending queue, jobs, and projections.
    public func control() async throws -> DSHStream {
        try await mux.open("session/control", args: .object([:]))
    }

    /// Observe forwarded Host events (the browser client's `$events` stream).
    public func events() async throws -> DSHStream {
        try await mux.open("$events", args: .object([:]))
    }

    // MARK: - Auth-aware invocation

    /// Invoke one endpoint, re-exchanging the launch token once on `401`.
    ///
    /// A Harness host that restarted behind the same address invalidates every
    /// cookie it previously minted; retrying once with a fresh exchange turns that
    /// into a transparent reconnect instead of a hard failure.
    private func callWithAuthRetry(_ endpoint: String, args: DSHJSON) async throws -> DSHJSON {
        do {
            return try await rpc.value(endpoint, args: args)
        } catch DSHTransportError.httpStatus(let status, _) where status == 401 {
            try await credentials.refreshedCookie()
            return try await rpc.value(endpoint, args: args)
        }
    }
}
