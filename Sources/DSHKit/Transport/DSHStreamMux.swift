import Foundation

/// One logical stream delivered over the Gateway's shared WebSocket.
///
/// An `AsyncThrowingStream` naturally exposes the mux's three frame kinds: items
/// are yielded, `end` finishes the sequence, and `error` throws. Callers iterate
/// with `for try await`, and dropping the iteration cancels the logical stream.
public typealias DSHStream = AsyncThrowingStream<DSHJSON, Error>

/// Multiplexed stream client for `/api/remote.mux`.
///
/// Every logical stream — `session/follow`, `session/control`, `$events` — shares
/// one socket. Opening a stream mints an id, sends an `open` frame, and routes
/// later frames back to its continuation. The Task on this actor serializes all
/// socket access, so concurrent callers never interleave writes or receive loops.
public actor DSHStreamMux {
    /// One active logical stream awaiting frames.
    private struct Inbox {
        let continuation: DSHStream.Continuation
        let endpoint: String
    }

    private let host: DSHHostConfiguration
    private let urlSession: URLSession
    private let cookieProvider: @Sendable () async throws -> String

    private var socket: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var inboxes: [String: Inbox] = [:]
    private var isShuttingDown = false

    public init(
        host: DSHHostConfiguration,
        urlSession: URLSession,
        cookieProvider: @escaping @Sendable () async throws -> String
    ) {
        self.host = host
        self.urlSession = urlSession
        self.cookieProvider = cookieProvider
    }

    // MARK: - Lifetime

    /// Open the shared socket if it is not already connected.
    ///
    /// The Gateway authenticates the upgrade with the very same cookie the `/api`
    /// carrier uses, so this reuses the resolved browser session.
    public func connect() async throws {
        if let existing = socket, existing.state == .running { return }

        isShuttingDown = false
        let cookie = try await cookieProvider()

        var request = URLRequest(url: host.streamMuxURL)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")

        let task = urlSession.webSocketTask(with: request)
        socket = task
        task.resume()
        receiveLoop = Task { [weak self] in
            await self?.pump(task)
        }
    }

    /// Close the socket and fail every active logical stream.
    public func shutdown() {
        isShuttingDown = true
        receiveLoop?.cancel()
        receiveLoop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        failAll(with: DSHTransportError.socket("stream mux shut down"))
    }

    private func failAll(with error: Error) {
        let pending = inboxes
        inboxes.removeAll()
        for (_, inbox) in pending {
            inbox.continuation.finish(throwing: error)
        }
    }

    // MARK: - Streams

    /// Open one logical stream and return its item sequence.
    ///
    /// - Parameters:
    ///   - endpoint: the Remote endpoint, e.g. `session/follow`.
    ///   - args: the endpoint's wire arguments.
    ///   - onTermination: invoked when the caller cancels iteration, so the
    ///     logical stream is cancelled on the Host as well.
    public func open(
        _ endpoint: String,
        args: DSHJSON,
        onTermination: (@Sendable (String) async -> Void)? = nil
    ) async throws -> DSHStream {
        try await connect()

        let streamId = UUID().uuidString
        let (stream, continuation) = DSHStream.makeStream(of: DSHJSON.self)

        inboxes[streamId] = Inbox(continuation: continuation, endpoint: endpoint)
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.cancelStream(streamId)
                await onTermination?(streamId)
            }
        }

        do {
            try await send(.open(streamId: streamId, endpoint: endpoint, args: args))
        } catch {
            inboxes.removeValue(forKey: streamId)
            throw error
        }
        return stream
    }

    /// Cancel one logical stream on the Host and finish it locally.
    private func cancelStream(_ streamId: String) {
        guard let inbox = inboxes.removeValue(forKey: streamId) else { return }
        inbox.continuation.finish()
        Task { try? await self.send(.cancel(streamId: streamId)) }
    }

    // MARK: - Socket plumbing

    private func send(_ message: DSHStreamClientMessage) async throws {
        guard let socket else {
            throw DSHTransportError.socket("stream mux is not connected")
        }
        let data = try DSHRPCClient.encode(message.wire)
        guard let text = String(data: data, encoding: .utf8) else {
            throw DSHTransportError.malformedResponse("outbound frame is not valid UTF-8")
        }
        try await socket.send(.string(text))
    }

    /// Receive frames until the socket fails, routing each to its inbox.
    private func pump(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                try route(message)
            } catch {
                guard !isShuttingDown else { return }
                failAll(with: DSHTransportError.socket(error.localizedDescription))
                socket = nil
                return
            }
        }
    }

    private func route(_ message: URLSessionWebSocketTask.Message) throws {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let payload): data = payload
        @unknown default:
            throw DSHTransportError.malformedResponse("unknown WebSocket message kind")
        }

        let json = try DSHRPCClient.decode(data)
        let parsed = try DSHStreamServerMessage.parse(json)

        switch parsed {
        case .item(let streamId, let value):
            inboxes[streamId]?.continuation.yield(value)
        case .end(let streamId):
            guard let inbox = inboxes.removeValue(forKey: streamId) else { return }
            inbox.continuation.finish()
        case .error(let streamId, let failure):
            guard let inbox = inboxes.removeValue(forKey: streamId) else { return }
            inbox.continuation.finish(throwing: failure)
        }
    }
}
