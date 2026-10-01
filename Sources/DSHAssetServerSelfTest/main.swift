import Foundation
import DSHAssetServer

/// Minimal assertion harness, matching the other self-test target.
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

let report = Report()

// A realistic root tree, so resolution is exercised against real files rather
// than string comparisons alone.
let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("dsh-asset-server-test-\(UUID().uuidString)")
let fileManager = FileManager.default
try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
try Data("<html>ok</html>".utf8).write(to: root.appendingPathComponent("index.html"))
try Data("console.log('worker')".utf8).write(to: root.appendingPathComponent("worker-abc.js"))
try Data("gzip-bytes".utf8).write(to: root.appendingPathComponent("vfs-image.tar.gz"))
try fileManager.createDirectory(at: root.appendingPathComponent("preview"), withIntermediateDirectories: true)
try Data("nested".utf8).write(to: root.appendingPathComponent("preview/bootstrap-x.js"))

// A secret outside the served root, to prove traversal is refused.
let outside = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("dsh-outside-\(UUID().uuidString).txt")
try Data("SECRET".utf8).write(to: outside)

let server = LocalAssetServer(root: root)

report.group("Path resolution")
do {
    report.equal(server.resolve(path: "/")?.lastPathComponent, "index.html", "root maps to index.html")
    report.equal(server.resolve(path: "")?.lastPathComponent, "index.html", "empty path maps to index.html")
    report.equal(server.resolve(path: "/worker-abc.js")?.lastPathComponent, "worker-abc.js", "flat asset resolves")
    report.equal(
        server.resolve(path: "/preview/bootstrap-x.js")?.path,
        root.appendingPathComponent("preview/bootstrap-x.js").path,
        "nested asset resolves"
    )
    report.equal(
        server.resolve(path: "/preview")?.lastPathComponent,
        "index.html",
        "a directory falls back to its index.html"
    )
    report.equal(
        server.resolve(path: "/worker-abc.js?v=1")?.lastPathComponent,
        "worker-abc.js",
        "query string is stripped before parsing"
    )
    report.equal(
        server.resolve(path: "/%77orker-abc.js")?.lastPathComponent,
        "worker-abc.js",
        "percent-encoding is decoded"
    )
}

report.group("Traversal is refused")
do {
    // Each of these must fail; a nil result is the refusal.
    let attacks = [
        "/../dsh-outside-\(outside.lastPathComponent)",
        "/../../etc/passwd",
        "/preview/../../etc/passwd",
        "/..%2f..%2fetc%2fpasswd",
        "/%2e%2e/%2e%2e/etc/passwd",
        "/./../../etc/passwd",
        "/preview/../../../etc/hosts",
    ]
    for attack in attacks {
        let resolved = server.resolve(path: attack)
        report.expect(resolved == nil, "refuses \(attack)")
    }

    // The real invariant: whenever a path resolves at all, the result must live
    // inside the served root. Stating it this way covers inputs not enumerated
    // here, which a list of specific strings cannot.
    let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    let adversarial = [
        "//etc/passwd",
        "/etc/passwd",
        "/....//....//etc/passwd",
        "/..;/etc/passwd",
        "/preview/..%2f..%2f..%2fetc%2fpasswd",
        "/index.html/../../etc/passwd",
        "/./././etc/passwd",
        "/%252e%252e/etc/passwd",
    ]
    for input in adversarial {
        if let resolved = server.resolve(path: input) {
            report.expect(
                resolved.path.hasPrefix(rootPrefix),
                "resolved path for \(input) stays inside the root"
            )
        } else {
            report.expect(true, "refuses \(input)")
        }
    }
}

report.group("Content types")
do {
    report.equal(LocalAssetServer.contentType(for: "html"), "text/html; charset=utf-8", "html")
    // A worker script served as anything but JavaScript is refused by WebKit,
    // which would stop the harness from starting.
    report.equal(LocalAssetServer.contentType(for: "js"), "text/javascript; charset=utf-8", "js is JavaScript")
    report.equal(LocalAssetServer.contentType(for: "mjs"), "text/javascript; charset=utf-8", "mjs is JavaScript")
    report.equal(LocalAssetServer.contentType(for: "css"), "text/css; charset=utf-8", "css")
    report.equal(LocalAssetServer.contentType(for: "json"), "application/json; charset=utf-8", "json")
    report.equal(
        LocalAssetServer.contentType(for: "webmanifest"),
        "application/manifest+json; charset=utf-8",
        "webmanifest"
    )
    report.equal(LocalAssetServer.contentType(for: "gz"), "application/gzip", "gz")
    report.equal(LocalAssetServer.contentType(for: "svg"), "image/svg+xml", "svg")
    report.equal(LocalAssetServer.contentType(for: "wasm"), "application/wasm", "wasm")
    report.equal(LocalAssetServer.contentType(for: "unknownext"), "application/octet-stream", "unknown falls back")
    report.equal(LocalAssetServer.contentType(for: "JS"), "text/javascript; charset=utf-8", "extension case is ignored")
}

report.group("Request line parsing")
do {
    func parse(_ raw: String) -> LocalAssetServer.RequestLine? {
        LocalAssetServer.parseRequestLine(Data(raw.utf8))
    }
    report.equal(parse("GET /index.html HTTP/1.1")?.method, "GET", "method")
    report.equal(parse("GET /index.html HTTP/1.1")?.path, "/index.html", "path")
    report.equal(parse("get /a HTTP/1.1")?.method, "GET", "method is upper-cased")
    report.equal(parse("GET /a?b=c HTTP/1.1")?.path, "/a", "query removed")
    report.equal(parse("HEAD / HTTP/1.0")?.method, "HEAD", "HEAD parsed")
    report.expect(parse("") == nil, "empty head rejected")
    report.expect(parse("GARBAGE") == nil, "single-token line rejected")
    report.expect(parse("GET") == nil, "method without target rejected")
}

report.group("Live server")
do {
    do {
        let port = try server.start()
        report.expect(port != 0, "binds an ephemeral port")
        report.equal(server.port, port, "port is reported")

        guard let base = server.baseURL else {
            report.expect(false, "baseURL is available after start")
            throw NSError(domain: "test", code: 1)
        }
        report.expect(base.absoluteString.hasPrefix("http://127.0.0.1:"), "baseURL is loopback")

        // Exercise the real socket, not just the resolver.
        func fetch(_ path: String, method: String = "GET") async -> (Int, Data)? {
            var request = URLRequest(url: URL(string: base.absoluteString + path.dropFirst())!)
            request.httpMethod = method
            request.timeoutInterval = 10
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse
            else { return nil }
            return (http.statusCode, data)
        }

        let root200 = await fetch("/")
        report.equal(root200?.0, 200, "GET / returns 200")
        report.equal(String(data: root200?.1 ?? Data(), encoding: .utf8), "<html>ok</html>", "GET / body")

        let worker = await fetch("/worker-abc.js")
        report.equal(worker?.0, 200, "GET worker returns 200")
        report.equal(String(data: worker?.1 ?? Data(), encoding: .utf8), "console.log('worker')", "worker body")

        let missing = await fetch("/nope.js")
        report.equal(missing?.0, 404, "missing asset returns 404")

        let traversal = await fetch("/../\(outside.lastPathComponent)")
        report.expect(traversal?.0 != 200, "traversal over HTTP is not served 200")

        let post = await fetch("/", method: "POST")
        report.equal(post?.0, 405, "POST is rejected")

        let head = await fetch("/", method: "HEAD")
        report.equal(head?.0, 200, "HEAD returns 200")
        report.equal(head?.1.count, 0, "HEAD sends no body")

        // Two concurrent reads prove the server handles parallel requests, which
        // the page does constantly for worker chunks and the VFS image.
        async let a = fetch("/index.html")
        async let b = fetch("/preview/bootstrap-x.js")
        let (first, second) = await (a, b)
        report.equal(first?.0, 200, "concurrent request 1 succeeds")
        report.equal(second?.0, 200, "concurrent request 2 succeeds")

        server.stop()
        report.equal(server.port, 0, "stop clears the port")
    } catch {
        report.expect(false, "live server failed: \(error)")
    }
}

try? fileManager.removeItem(at: root)
try? fileManager.removeItem(at: outside)

exit(report.finish())
