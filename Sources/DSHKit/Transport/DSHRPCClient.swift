import Foundation

/// Browser-side caller for Harness unary RPC channels.
///
/// One call is `POST <api>/<endpoint>` carrying the `client-request` envelope.
/// The correlation id is minted here and verified on the response, so a stale or
/// mismatched reply is rejected rather than delivered to the wrong caller.
public struct DSHRPCClient: Sendable {
    /// The absolute channel root, mirroring the browser caller's `/api` channel.
    public static let channel = "/api"

    private let host: DSHHostConfiguration
    private let cookieProvider: @Sendable () async throws -> String
    private let urlSession: URLSession

    public init(
        host: DSHHostConfiguration,
        urlSession: URLSession? = nil,
        cookieProvider: @escaping @Sendable () async throws -> String
    ) {
        self.host = host
        self.urlSession = urlSession ?? DSHRPCClient.makeSession()
        self.cookieProvider = cookieProvider
    }

    /// Build a session whose request lifetime suits a long-lived desktop host.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        // Cookies are supplied explicitly; the shared jar must not interfere.
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// Invoke one endpoint on the `/api` channel.
    ///
    /// - Parameters:
    ///   - endpoint: channel-relative endpoint such as `session/list`.
    ///   - args: the endpoint's wire arguments, already shaped per its descriptor.
    public func call(_ endpoint: String, args: DSHJSON = .object([:])) async throws -> DSHResult<DSHJSON> {
        let request = DSHClientRequest(method: endpoint, args: args)
        let url = host.apiBaseURL.appendingPathComponent(endpoint)
        let cookie = try await cookieProvider()

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
        urlRequest.httpBody = try DSHRPCClient.encode(request.body)

        let (data, response) = try await urlSession.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw DSHTransportError.malformedResponse("\(endpoint): non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DSHTransportError.httpStatus(http.statusCode, body: String(body.prefix(300)))
        }

        let decoded = try DSHRPCClient.decode(data)
        let parsed = try DSHServerResponse.parse(decoded)
        guard parsed.rpcId == request.rpcId else {
            throw DSHTransportError.malformedResponse(
                "rpcId mismatch for \(endpoint): sent \(request.rpcId), got \(parsed.rpcId)"
            )
        }
        return parsed.result
    }

    /// Invoke one endpoint and unwrap its value, throwing on a Harness failure.
    public func value(_ endpoint: String, args: DSHJSON = .object([:])) async throws -> DSHJSON {
        try await call(endpoint, args: args).get()
    }

    // MARK: - JSON bridging

    /// Encode one wire value to UTF-8 JSON.
    public static func encode(_ value: DSHJSON) throws -> Data {
        try JSONSerialization.data(withJSONObject: value.anyValue, options: [.sortedKeys])
    }

    /// Decode UTF-8 JSON into the lossless wire model.
    public static func decode(_ data: Data) throws -> DSHJSON {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw DSHTransportError.malformedResponse("response body is not JSON: \(error.localizedDescription)")
        }
        guard let value = DSHJSON(anyValue: raw) else {
            throw DSHTransportError.malformedResponse("response body is outside the wire JSON contract")
        }
        return value
    }

    /// Decode one JSON object into a typed model.
    public static func decodeObject<T: Decodable>(_ type: T.Type, from value: DSHJSON) throws -> T {
        let data = try encode(value)
        return try JSONDecoder().decode(type, from: data)
    }
}
