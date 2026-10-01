import Foundation
// `SecItem*` and the `kSec*` attributes live in Security, and iOS does not
// transitively import it through Foundation the way a macOS build can.
import Security

/// Persist one authority-bound browser cookie.
///
/// The Harness cookie is `dsh-auth-<sha256(authority)>=v1.<payload>.<hmac>`, so a
/// stored value is only meaningful for the authority that minted it. The name
/// already encodes that authority, which lets the store keep one cookie per host
/// and reuse it across launches until the Host rotates its signing secret.
public protocol DSHCredentialStore: Sendable {
    func cookie(forAuthority authority: String) -> String?
    func setCookie(_ cookie: String, forAuthority authority: String)
    func clearCookie(forAuthority authority: String)
}

/// In-memory credential store, suitable for tests and ephemeral sessions.
public final class DSHMemoryCredentialStore: DSHCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var cookies: [String: String] = [:]

    public init() {}

    public func cookie(forAuthority authority: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cookies[authority]
    }

    public func setCookie(_ cookie: String, forAuthority authority: String) {
        lock.lock()
        defer { lock.unlock() }
        cookies[authority] = cookie
    }

    public func clearCookie(forAuthority authority: String) {
        lock.lock()
        defer { lock.unlock() }
        cookies.removeValue(forKey: authority)
    }
}

/// Keychain-backed credential store for the iOS app.
///
/// The cookie is a bearer credential, so it belongs in the Keychain rather than
/// `UserDefaults`. One generic-password item per authority keeps the mapping
/// explicit and lets a rotated host be cleared without touching other entries.
public final class DSHKeychainCredentialStore: DSHCredentialStore, @unchecked Sendable {
    private let service: String
    private let lock = NSLock()

    public init(service: String = "ai.deepseek.harness.ios") {
        self.service = service
    }

    private func query(authority: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: authority,
        ]
    }

    public func cookie(forAuthority authority: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        var query = query(authority: authority)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setCookie(_ cookie: String, forAuthority authority: String) {
        lock.lock()
        defer { lock.unlock() }
        let data = Data(cookie.utf8)
        let base = query(authority: authority)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = base
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    public func clearCookie(forAuthority authority: String) {
        lock.lock()
        defer { lock.unlock() }
        SecItemDelete(query(authority: authority) as CFDictionary)
    }
}
/// Resolve a usable cookie for one host, performing the launch-token exchange
/// when the store holds nothing reusable.
///
/// Mirrors `BrowserAuth.authorizeIndex`: a `GET /?token=…` returns `303` with the
/// `dsh-auth-…` cookie, after which the token is no longer needed. Only a `303`
/// with a parseable `Set-Cookie` is accepted, so a 401 or an unrelated redirect
/// surfaces as a real error instead of a silent empty session.
public struct DSHAuthBootstrap: Sendable {
    private let session: URLSession
    private let store: DSHCredentialStore

    public init(session: URLSession = .shared, store: DSHCredentialStore) {
        self.session = session
        self.store = store
    }

    /// The authority string the Harness binds cookies to (`host:port`).
    public static func authority(for baseURL: URL) -> String {
        guard let host = baseURL.host else { return baseURL.absoluteString }
        let port = baseURL.port ?? (baseURL.scheme == "https" ? 443 : 80)
        return "\(host):\(port)"
    }

    /// Return a valid cookie, exchanging the launch token when necessary.
    ///
    /// - Parameters:
    ///   - configuration: the target host and the available credential material.
    ///   - forceRefresh: skip the stored cookie, e.g. after the Host has restarted.
    /// - Returns: the cookie to send as a `Cookie` header.
    public func resolveCookie(
        for configuration: DSHHostConfiguration,
        forceRefresh: Bool = false
    ) async throws -> String {
        let authority = Self.authority(for: configuration.baseURL)

        if !forceRefresh, let stored = store.cookie(forAuthority: authority) {
            return stored
        }

        guard let token = configuration.launchToken, !token.isEmpty else {
            throw DSHAuthError.missingCredential(authority: authority)
        }

        let cookie = try await exchange(launchToken: token, configuration: configuration)
        store.setCookie(cookie, forAuthority: authority)
        return cookie
    }

    /// Perform the one-time launch-token exchange.
    public func exchange(launchToken: String, configuration: DSHHostConfiguration) async throws -> String {
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "token", value: launchToken)]
        guard let url = components?.url else {
            throw DSHAuthError.invalidHost(configuration.baseURL.absoluteString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // The caller owns redirect handling so the 303 can be inspected directly.
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let delegate = DSHNoRedirectDelegate()
        let (data, response) = try await session.data(for: request, delegate: delegate)

        guard let http = response as? HTTPURLResponse else {
            throw DSHTransportError.malformedResponse("token exchange returned a non-HTTP response")
        }
        guard http.statusCode == 303 || http.statusCode == 302 || http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DSHTransportError.httpStatus(http.statusCode, body: body.prefix(200).description)
        }

        guard let raw = http.value(forHTTPHeaderField: "Set-Cookie"),
              let cookie = Self.cookieValue(fromSetCookie: raw)
        else {
            throw DSHAuthError.tokenRejected
        }
        return cookie
    }

    /// Extract the `name=value` pair from one `Set-Cookie` header.
    ///
    /// Public so the exchange logic is unit-testable without a live host.
    public static func cookieValue(fromSetCookie header: String) -> String? {
        guard let pair = header.split(separator: ";").first else { return nil }
        let text = pair.trimmingCharacters(in: .whitespaces)
        guard let separator = text.firstIndex(of: "=") else { return nil }
        let name = String(text[text.startIndex..<separator])
        guard name.hasPrefix("dsh-auth-"), text.count > name.count + 1 else { return nil }
        return text
    }
}

/// Failures raised while establishing a browser session.
public enum DSHAuthError: Error, Sendable {
    /// No stored cookie and no launch token to exchange.
    case missingCredential(authority: String)
    /// The host did not return the expected session cookie.
    case tokenRejected
    /// The configured host URL could not be used.
    case invalidHost(String)
}

extension DSHAuthError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingCredential(let authority):
            return "no stored session for \(authority); paste the URL printed by dsh web (it carries a one-time token)"
        case .tokenRejected:
            return "the host rejected the launch token; open the URL printed by the running dsh web process"
        case .invalidHost(let host):
            return "invalid host URL: \(host)"
        }
    }
}

/// Suppress automatic redirects so the token exchange can read `Set-Cookie`.
private final class DSHNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
