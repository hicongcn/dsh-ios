import Foundation

/// How to reach one DeepSeek Harness Web host.
///
/// The Harness `/api` fence accepts an authority when it is loopback or is
/// explicitly listed in the host's `trustedHosts`. A device therefore reaches a
/// desktop host either over loopback (simulator sharing the Mac, or a local
/// forward) or through a LAN address the host was started with.
public struct DSHHostConfiguration: Sendable, Hashable {
    /// Canonical base URL of the host, without a trailing slash.
    public let baseURL: URL
    /// Process launch token read from the host's printed `dsh web:` URL.
    ///
    /// It is single-use per process: the exchange mints a signed browser cookie
    /// and the token stops being required afterwards.
    public let launchToken: String?
    /// A previously obtained `dsh-auth-…=v1.…` browser cookie.
    ///
    /// Cookies are authority-bound, so a stored cookie is only reusable while
    /// `baseURL` keeps the same host and port.
    public let cookie: String?

    public init(baseURL: URL, launchToken: String? = nil, cookie: String? = nil) {
        self.baseURL = baseURL
        self.launchToken = launchToken
        self.cookie = cookie
    }

    /// Parse the URL printed by `dsh web`, extracting its launch token.
    ///
    /// Accepts `http://127.0.0.1:3080/?token=…`, the LAN variant, or a bare
    /// origin; a bare origin simply yields a configuration with no token.
    public init?(printedURL: String) {
        let trimmed = printedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed), let scheme = url.scheme,
              scheme == "http" || scheme == "https"
        else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        let token = components.queryItems?.first(where: { $0.name == "token" })?.value
        components.queryItems = nil
        components.path = ""
        components.fragment = nil
        guard let origin = components.url else { return nil }

        self.init(baseURL: origin, launchToken: token, cookie: nil)
    }

    /// The `ws://` (or `wss://`) form of the base URL.
    public var webSocketBaseURL: URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        return components?.url ?? baseURL
    }

    /// The Gateway's multiplexed stream route.
    public var streamMuxURL: URL {
        webSocketBaseURL.appendingPathComponent("api/remote.mux")
    }

    /// The absolute `/api` channel root.
    public var apiBaseURL: URL {
        baseURL.appendingPathComponent("api")
    }
}
