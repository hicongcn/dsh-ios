import Foundation
import Network

/// A loopback HTTP server that serves assets embedded in the app bundle.
///
/// Why this exists instead of `WKWebView.loadFileURL`: the Harness preview is a
/// Web Worker application — the page starts a worker, the worker inflates the
/// packed VFS image and boots the whole plugin tree. Web Workers are subject to
/// origin rules, and a `file://` page cannot start one at all. The page
/// therefore needs a real origin, and binding loopback is the smallest way to
/// grant one while keeping the app fully offline.
///
/// Trust boundary: the listener binds 127.0.0.1 only, so nothing off-device can
/// reach it. Path resolution is confined to the served root, so a crafted URL
/// cannot read outside the bundle.
public final class LocalAssetServer: @unchecked Sendable {
    /// The HTTP status codes this server can produce.
    public enum Status: Int, Sendable {
        case ok = 200
        case notFound = 404
        case badRequest = 400
        case methodNotAllowed = 405
        case internalError = 500

        public var reason: String {
            switch self {
            case .ok: return "OK"
            case .notFound: return "Not Found"
            case .badRequest: return "Bad Request"
            case .methodNotAllowed: return "Method Not Allowed"
            case .internalError: return "Internal Server Error"
            }
        }
    }

    /// One fully materialized response, so the socket write is a single buffer.
    public struct Response: Sendable {
        public let status: Status
        public let contentType: String
        public let body: Data
        /// Length advertised in `Content-Length`, which for a HEAD reply is the
        /// length a GET would have returned.
        public let declaredLength: Int

        public init(status: Status, contentType: String, body: Data, declaredLength: Int? = nil) {
            self.status = status
            self.contentType = contentType
            self.body = body
            self.declaredLength = declaredLength ?? body.count
        }

        var header: String {
            [
                "HTTP/1.1 \(status.rawValue) \(status.reason)",
                "Content-Type: \(contentType)",
                "Content-Length: \(declaredLength)",
                // The bundle is immutable for a given install, and the page is a
                // single long-lived document; revalidation is pure overhead.
                "Cache-Control: no-cache",
                // Every request is answered on its own connection, which keeps the
                // implementation small and avoids pipelining state entirely.
                "Connection: close",
                "",
                "",
            ].joined(separator: "\r\n")
        }
    }

    private let root: URL
    private let queue = DispatchQueue(label: "ai.deepseek.harness.asset-server", attributes: .concurrent)
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var portValue: UInt16 = 0

    /// The port actually bound once started, or 0 before that.
    public var port: UInt16 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return portValue
    }

    /// The base URL to load in the web view, or nil before the server starts.
    public var baseURL: URL? {
        let bound = port
        guard bound != 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(bound)/")
    }

    /// - Parameter root: directory whose contents are served.
    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    // MARK: - Lifetime

    /// Bind loopback on an ephemeral port and begin accepting connections.
    ///
    /// Blocks briefly until the port is known, because the caller needs a usable
    /// URL before it can load the page.
    @discardableResult
    public func start() throws -> UInt16 {
        if let existing = listener, existing.state == .ready { return port }

        let parameters = NWParameters.tcp
        // Loopback only: never reachable from the LAN.
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        let failure = LockedBox<Error?>(nil)

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                failure.set(error)
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        listener.start(queue: queue)

        // A listener that cannot bind reports failure here rather than hanging.
        if ready.wait(timeout: .now() + 10) == .timedOut {
            listener.cancel()
            throw ServerError.timedOut
        }
        if let error = failure.get() {
            listener.cancel()
            throw ServerError.cannotBind(error.localizedDescription)
        }

        let bound = listener.port?.rawValue ?? 0
        guard bound != 0 else {
            listener.cancel()
            throw ServerError.cannotBind("no port assigned")
        }

        stateLock.lock()
        self.listener = listener
        self.portValue = bound
        stateLock.unlock()

        return bound
    }

    /// Stop accepting connections.
    public func stop() {
        stateLock.lock()
        let current = listener
        listener = nil
        portValue = 0
        stateLock.unlock()
        current?.cancel()
    }

    /// Failures raised while binding.
    public enum ServerError: Error, Sendable {
        case cannotBind(String)
        case timedOut
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequestHead(connection, buffer: Data())
    }

    /// Read until the request head is complete, then answer.
    ///
    /// Only the head is needed: this server answers `GET`/`HEAD` and never reads
    /// a request body, so no framing rules apply.
    private func receiveRequestHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }

            if error != nil {
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let chunk { accumulated.append(chunk) }

            // Bound the head so a malformed request cannot grow unbounded.
            if accumulated.count > 64 * 1024 {
                self.write(Response(status: .badRequest, contentType: "text/plain", body: Data("request head too large".utf8)), to: connection)
                return
            }

            guard let headEnd = accumulated.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete {
                    connection.cancel()
                } else {
                    self.receiveRequestHead(connection, buffer: accumulated)
                }
                return
            }

            let head = accumulated.subdata(in: accumulated.startIndex..<headEnd.lowerBound)
            self.respond(to: head, on: connection)
        }
    }

    private func respond(to head: Data, on connection: NWConnection) {
        guard let requestLine = Self.parseRequestLine(head) else {
            write(Response(status: .badRequest, contentType: "text/plain", body: Data("malformed request".utf8)), to: connection)
            return
        }

        guard requestLine.method == "GET" || requestLine.method == "HEAD" else {
            write(Response(status: .methodNotAllowed, contentType: "text/plain", body: Data("only GET and HEAD are served".utf8)), to: connection)
            return
        }

        guard let fileURL = resolve(path: requestLine.path) else {
            // A traversal attempt and a genuine miss are answered identically.
            write(Response(status: .notFound, contentType: "text/plain", body: Data("not found".utf8)), to: connection)
            return
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            write(Response(status: .notFound, contentType: "text/plain", body: Data("not found".utf8)), to: connection)
            return
        }

        // A HEAD reply carries the headers a GET would produce but no body, so it
        // declares the full length while sending nothing.
        let response: Response
        if requestLine.method == "HEAD" {
            response = Response(
                status: .ok,
                contentType: Self.contentType(for: fileURL.pathExtension),
                body: Data(),
                declaredLength: data.count
            )
        } else {
            response = Response(
                status: .ok,
                contentType: Self.contentType(for: fileURL.pathExtension),
                body: data
            )
        }
        write(response, to: connection)
    }

    private func write(_ response: Response, to connection: NWConnection) {
        var payload = Data(response.header.utf8)
        payload.append(response.body)

        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Request parsing

    public struct RequestLine: Equatable, Sendable {
        public let method: String
        public let path: String
    }

    /// Parse `METHOD /path HTTP/1.1`, discarding the query string.
    public static func parseRequestLine(_ head: Data) -> RequestLine? {
        guard let text = String(data: head, encoding: .utf8),
              let firstLine = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first
        else { return nil }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0]).uppercased()
        var target = String(parts[1])
        if let queryStart = target.firstIndex(of: "?") {
            target = String(target[target.startIndex..<queryStart])
        }
        return RequestLine(method: method, path: target)
    }

    /// Map a request path onto a file inside the served root.
    ///
    /// Returns nil for anything that escapes the root, so traversal cannot read
    /// outside the bundle.
    public func resolve(path rawPath: String) -> URL? {
        var path = rawPath

        // Defence in depth: the request-line parser already drops the query, but
        // a caller that passes a full target must not turn `a.js?v=1` into a
        // filename.
        if let queryStart = path.firstIndex(of: "?") {
            path = String(path[path.startIndex..<queryStart])
        }
        if let fragmentStart = path.firstIndex(of: "#") {
            path = String(path[path.startIndex..<fragmentStart])
        }
        if let percentDecoded = path.removingPercentEncoding {
            path = percentDecoded
        }
        if path.isEmpty || path == "/" {
            path = "/index.html"
        }

        // Reject an encoded traversal before touching the filesystem.
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if segments.contains("..") { return nil }

        var candidate = root
        for segment in segments {
            candidate.appendPathComponent(segment)
        }
        candidate = candidate.standardizedFileURL

        // Second gate: the resolved path must still live under the root.
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath) else { return nil }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
            candidate.appendPathComponent("index.html")
        }
        return candidate
    }

    /// Content type by extension.
    ///
    /// `text/javascript` matters: a worker script served with the wrong type is
    /// refused by WebKit, which would prevent the harness from starting at all.
    public static func contentType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "webmanifest": return "application/manifest+json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "map": return "application/json; charset=utf-8"
        case "gz", "tgz": return "application/gzip"
        case "txt", "md": return "text/plain; charset=utf-8"
        case "wasm": return "application/wasm"
        default: return "application/octet-stream"
        }
    }
}

/// A tiny mutex-guarded box, used to move a value across the listener's callback.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }
}
