import Foundation

// MARK: - Unary RPC envelope

/// One Harness unary RPC failure.
///
/// Mirrors `ConnectionRpcFailure`; discrimination is always by `code`.
public struct DSHRemoteFailure: Error, Sendable, Hashable {
    public let code: String
    public let message: String
    public let details: DSHJSON

    public init(code: String, message: String, details: DSHJSON) {
        self.code = code
        self.message = message
        self.details = details
    }
}

extension DSHRemoteFailure: LocalizedError {
    public var errorDescription: String? { "\(code): \(message)" }
}

/// Result of one logical RPC endpoint.
public enum DSHResult<Value: Sendable>: Sendable {
    case success(Value)
    case failure(DSHRemoteFailure)

    /// The value, or the Harness failure as a thrown error.
    public func get() throws -> Value {
        switch self {
        case .success(let value): return value
        case .failure(let failure): throw failure
        }
    }

    public var value: Value? {
        if case .success(let value) = self { return value }
        return nil
    }

    public var failure: DSHRemoteFailure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

/// The browser-to-Host request envelope.
///
/// `method` repeats the endpoint for transport-level traceability while the URL
/// path carries the authoritative target. `payload` is always `{"args": {...}}`.
public struct DSHClientRequest: Sendable {
    public let rpcId: String
    public let method: String
    public let args: DSHJSON

    public init(rpcId: String = UUID().uuidString, method: String, args: DSHJSON) {
        self.rpcId = rpcId
        self.method = method
        self.args = args
    }

    /// The exact JSON body posted to `/api/<endpoint>`.
    public var body: DSHJSON {
        .object([
            "type": .string("client-request"),
            "rpcId": .string(rpcId),
            "method": .string(method),
            "payload": .object(["args": args]),
        ])
    }
}

/// The Host-to-browser response envelope, as decoded from the wire.
public struct DSHServerResponse: Sendable {
    public let rpcId: String
    public let result: DSHResult<DSHJSON>

    /// Parse one `server-response` frame.
    ///
    /// Throws on any envelope violation, matching the browser caller's strictness:
    /// a mismatched or malformed response must never be mistaken for success.
    public static func parse(_ json: DSHJSON) throws -> DSHServerResponse {
        guard json["type"]?.stringValue == "server-response",
              let rpcId = json["rpcId"]?.stringValue,
              let result = json["result"]
        else {
            throw DSHTransportError.malformedResponse("not a server-response envelope")
        }

        if result["ok"]?.boolValue == true {
            return DSHServerResponse(rpcId: rpcId, result: .success(result["value"] ?? .null))
        }

        guard result["ok"]?.boolValue == false,
              let error = result["error"],
              let code = error["code"]?.stringValue,
              let message = error["message"]?.stringValue
        else {
            throw DSHTransportError.malformedResponse("invalid server-response failure branch")
        }

        return DSHServerResponse(
            rpcId: rpcId,
            result: .failure(DSHRemoteFailure(code: code, message: message, details: error["details"] ?? .null))
        )
    }
}

// MARK: - Gateway stream envelopes

/// A browser-to-Host message on `/api/remote.mux`.
///
/// The Host rejects any frame whose keys are not exactly the ones written here.
public enum DSHStreamClientMessage: Sendable {
    /// Open one logical stream on the shared socket.
    case open(streamId: String, endpoint: String, args: DSHJSON)
    /// Cancel a stream previously opened under the same id.
    case cancel(streamId: String)

    public var wire: DSHJSON {
        switch self {
        case .open(let streamId, let endpoint, let args):
            return .object([
                "type": .string("open"),
                "streamId": .string(streamId),
                "endpoint": .string(endpoint),
                "payload": .object(["args": args]),
            ])
        case .cancel(let streamId):
            return .object([
                "type": .string("cancel"),
                "streamId": .string(streamId),
            ])
        }
    }
}

/// One Host-to-browser message carried on a logical stream.
public enum DSHStreamServerMessage: Sendable {
    /// One decoded item of the logical stream.
    case item(streamId: String, value: DSHJSON)
    /// The logical stream ended normally.
    case end(streamId: String)
    /// The logical stream failed.
    case error(streamId: String, failure: DSHRemoteFailure)

    /// Parse and validate one mux text message.
    public static func parse(_ json: DSHJSON) throws -> DSHStreamServerMessage {
        guard let type = json["type"]?.stringValue,
              let streamId = json["streamId"]?.stringValue, !streamId.isEmpty
        else {
            throw DSHTransportError.malformedResponse("invalid remote stream message")
        }

        switch type {
        case "item":
            guard let value = json["value"] else {
                throw DSHTransportError.malformedResponse("item frame has no value")
            }
            return .item(streamId: streamId, value: value)
        case "end":
            return .end(streamId: streamId)
        case "error":
            guard let error = json["error"],
                  let code = error["code"]?.stringValue,
                  let message = error["message"]?.stringValue
            else {
                throw DSHTransportError.malformedResponse("error frame is malformed")
            }
            return .error(
                streamId: streamId,
                failure: DSHRemoteFailure(code: code, message: message, details: error["details"] ?? .null)
            )
        default:
            throw DSHTransportError.malformedResponse("unknown remote stream message type \(type)")
        }
    }
}

// MARK: - Transport errors

/// Local transport failures that never crossed the Harness.
public enum DSHTransportError: Error, Sendable {
    /// The HTTP carrier returned a non-2xx status.
    case httpStatus(Int, body: String)
    /// The response envelope did not satisfy the wire contract.
    case malformedResponse(String)
    /// The socket failed to open or dropped.
    case socket(String)
    /// The logical stream ended before delivering a result.
    case streamEnded(String)

    public var message: String {
        switch self {
        case .httpStatus(let status, let body):
            return body.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(body)"
        case .malformedResponse(let detail): return detail
        case .socket(let detail): return detail
        case .streamEnded(let endpoint): return "stream ended before delivering items: \(endpoint)"
        }
    }
}

extension DSHTransportError: LocalizedError {
    public var errorDescription: String? { message }
}
