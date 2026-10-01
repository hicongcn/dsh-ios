import SwiftUI
import WebKit
import DSHAssetServer

/// Evidence the app leaves on disk for an automated smoke test.
///
/// Console output proved unreliable across launch modes — `simctl launch
/// --console-pty` produced an empty log on CI — so the app records what it knows
/// in its own container, where a test can read it deterministically. This exists
/// because a live process turned out to be a false positive: WebKit's own
/// "The URL can't be shown" page keeps the process alive while rendering nothing.
enum BootEvidence {
    /// Append-only progress log, so a failure can be placed exactly rather than
    /// inferred from a screenshot.
    static let logFile = "dsh-boot.log"

    private static var directory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// Record one startup stage.
    static func stage(_ line: String) {
        append(line)
    }

    /// Record a successful harness boot.
    static func recordBooted(_ detail: String) {
        append("BOOTED \(detail)")
    }

    /// Record a failure with enough context to act on it.
    static func recordError(_ message: String) {
        append("ERROR \(message)")
    }

    private static func append(_ line: String) {
        guard let directory else { return }
        let url = directory.appendingPathComponent(logFile)
        let stamped = Data("\(Date().timeIntervalSince1970) \(line)\n".utf8)

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: stamped)
        } else {
            try? stamped.write(to: url, options: .atomic)
        }
    }
}

/// The standalone DeepSeek Harness client.
///
/// This app ships the whole harness inside its own bundle: the Web Worker
/// bundle, the packed VFS image, and the UI assets are all local. It starts the
/// embedded loopback server, points a web view at it, and the harness boots on
/// device with no external host and no network beyond the model API.
///
/// The loopback server is not incidental. The harness runs inside a Web Worker,
/// and WebKit gives a `file://` page no origin at all — a worker cannot be
/// started from one. Serving the bundle over `http://127.0.0.1:<port>` supplies
/// the origin without any off-device surface.
@main
struct DeepSeekHarnessApp: App {
    @State private var model = HarnessModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task { await model.start() }
        }
    }
}

/// Owns the asset server, the web view's load state, and reload control.
@Observable
@MainActor
final class HarnessModel {
    /// Which filesystem source the harness boots from.
    ///
    /// The preview page renders a developer-facing source chooser unless the
    /// fixture query says otherwise, so a real client must always pass one.
    /// These values are the runtime's own sentinels — `EMPTY_SOURCE` is the
    /// literal `'none'`, not `'empty'` — and the page rejects anything it does
    /// not recognise, so they are read from `source-chooser.ts` rather than
    /// inferred. `none` returns no overlays and skips the chooser entirely.
    enum Source: String, CaseIterable, Identifiable {
        /// The runtime's `EMPTY_SOURCE`.
        case empty = "none"
        /// The bundled sample fixture, by its manifest id.
        case showcase = "vfs-example"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .empty: return "Empty environment"
            case .showcase: return "Showcase sample"
            }
        }

        var detail: String {
            switch self {
            case .empty: return "Start clean and connect your own model."
            case .showcase: return "Bundled sample workspace and history."
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case starting
        case running(URL)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Set when a load error arrives, so the UI can offer a retry.
    private(set) var loadError: String?
    private(set) var source: Source = .empty
    /// True once the page reports its plugin tree is live.
    ///
    /// A running process is not a running harness: WebKit's own error page keeps
    /// the process alive while showing nothing. This flag is the difference.
    private(set) var harnessBooted = false

    /// The marker CI greps for. Emitted on stdout and in the log so a smoke test
    /// can assert the harness booted instead of only that the app launched.
    static let bootMarker = "DSH_HARNESS_BOOTED"

    @ObservationIgnored private var server: LocalAssetServer?
    /// Bumped to force SwiftUI to rebuild the web view for a genuine reload.
    private(set) var generation = 0

    /// The worker-preview entry point inside the bundled assets.
    private static let entryPath = "preview.html"

    /// The entry URL carrying the source selection.
    ///
    /// Built from absolute components on purpose. `URLComponents(url:relativeTo:)`
    /// with `resolvingAgainstBaseURL: false` keeps a relative URL relative, so
    /// the result loses scheme, host and port — the web view then reports "The
    /// URL can't be shown". Starting from the absolute URL avoids that entirely.
    private func entryURL(base: URL) -> URL? {
        guard var components = URLComponents(
            url: base.appendingPathComponent(Self.entryPath),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        components.queryItems = [URLQueryItem(name: "preview-fixture", value: source.rawValue)]
        return components.url
    }

    func start() async {
        guard case .idle = phase else { return }
        phase = .starting
        BootEvidence.stage("start source=\(source.rawValue)")

        guard let root = Bundle.main.url(forResource: "HarnessAssets", withExtension: nil) else {
            BootEvidence.recordError("bundled assets missing")
            phase = .failed("The bundled harness assets are missing from this build.")
            return
        }
        BootEvidence.stage("assets at \(root.path)")

        let server = LocalAssetServer(root: root)
        do {
            try server.start()
            guard let base = server.baseURL, let entry = entryURL(base: base) else {
                server.stop()
                BootEvidence.recordError("server reported no usable address")
                phase = .failed("The embedded server did not report a usable address.")
                return
            }
            self.server = server
            BootEvidence.stage("entry \(entry.absoluteString)")
            phase = .running(entry)
        } catch {
            BootEvidence.recordError("server bind failed: \(error)")
            phase = .failed("Could not start the embedded server: \(error)")
        }
    }

    /// Boot the harness from a different filesystem source.
    func use(_ newSource: Source) {
        guard newSource != source else { return }
        source = newSource
        reload()
    }

    /// Reload the harness from the bundled assets.
    func reload() {
        loadError = nil
        harnessBooted = false

        // Rebuilding the web view is the only reliable reset; the URL must be
        // recomputed because the source may have changed.
        if case .running = phase, let server, let base = server.baseURL, let entry = entryURL(base: base) {
            phase = .running(entry)
        }
        generation += 1
    }

    func reportLoadFailure(_ message: String) {
        loadError = message
        harnessBooted = false
        BootEvidence.recordError(message)
    }

    /// Record that the page reported its plugin tree live.
    func reportBooted(_ detail: String) {
        harnessBooted = true
        loadError = nil
        BootEvidence.recordBooted(detail)
        // Printed too, so a launch that does capture stdout still shows it.
        print("\(Self.bootMarker) \(detail)")
    }

    func shutdown() {
        server?.stop()
        server = nil
        phase = .idle
    }
}

/// Hosts the web view and overlays startup, error, and reload states.
struct ContentView: View {
    @Environment(HarnessModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .idle, .starting:
                StartupView()
            case .running(let url):
                HarnessWebView(
                    url: url,
                    generation: model.generation,
                    onLoadError: { model.reportLoadFailure($0) },
                    onBooted: { model.reportBooted($0) }
                )
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .topTrailing) { SourceMenu() }
            case .failed(let message):
                FailureView(message: message) {
                    Task { await model.start() }
                }
            }
        }
        .overlay(alignment: .top) {
            if let error = model.loadError {
                LoadErrorBanner(message: error) { model.reload() }
            }
        }
        .overlay(alignment: .bottom) {
            // Until the page reports its plugin tree, say so. Without this a slow
            // first boot is indistinguishable from a page that failed to load.
            if !model.harnessBooted, model.loadError == nil, case .running = model.phase {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Starting the harness…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 16)
            }
        }
    }
}

/// Switches the filesystem source and reloads.
///
/// The harness is the app's whole interface, so this stays a small floating
/// control rather than native chrome that would compete with it.
private struct SourceMenu: View {
    @Environment(HarnessModel.self) private var model

    var body: some View {
        Menu {
            ForEach(HarnessModel.Source.allCases) { source in
                Button {
                    model.use(source)
                } label: {
                    if source == model.source {
                        Label(source.title, systemImage: "checkmark")
                    } else {
                        Text(source.title)
                    }
                }
            }
            Divider()
            Button {
                model.reload()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .padding(8)
                .background(.thinMaterial, in: Circle())
        }
        .padding(.trailing, 12)
        .padding(.top, 4)
    }
}

/// Shown while the embedded server binds and the first frame loads.
private struct StartupView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("DeepSeek Harness")
                .font(.title2.weight(.semibold))
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Starting the local harness…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

/// Shown when the bundle is unusable, with a retry.
private struct FailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Harness unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try again", action: retry)
        }
    }
}

/// A non-blocking notice for a failed subresource or navigation.
private struct LoadErrorBanner: View {
    let message: String
    let reload: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button("Reload", action: reload)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }
}

/// A `WKWebView` pointed at the embedded server.
///
/// The view is rebuilt when `generation` changes, which is the only reliable way
/// to reset a web view whose page is in a bad state.
struct HarnessWebView: UIViewRepresentable {
    let url: URL
    let generation: Int
    let onLoadError: (String) -> Void
    /// Called once the harness reports that its plugin tree is live.
    let onBooted: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoadError: onLoadError, onBooted: onBooted)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        // The harness announces its progress with console.log, including the
        // "tree active" line the worker emits once the plugin tree is up.
        // Forwarding console output is what lets the app — and CI — assert that
        // the harness actually booted, rather than that a process merely exists.
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: Coordinator.logHandlerName)
        controller.addUserScript(WKUserScript(
            source: Coordinator.consoleForwarder,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        configuration.userContentController = controller

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.scrollView.keyboardDismissMode = .interactive
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onLoadError = onLoadError
        context.coordinator.onBooted = onBooted

        guard context.coordinator.generation != generation else { return }
        context.coordinator.generation = generation
        view.stopLoading()
        view.load(URLRequest(url: url))
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let logHandlerName = "dshLog"

        /// Mirror console output to the native side.
        ///
        /// Installed before any page script runs so nothing is missed, and it
        /// re-throws nothing: a failure to post must never break the page.
        static let consoleForwarder = """
        (function () {
          var post = function (level, args) {
            try {
              window.webkit.messageHandlers.\(logHandlerName).postMessage(
                level + '\\u0000' + args.map(function (a) {
                  try { return typeof a === 'string' ? a : JSON.stringify(a); }
                  catch (e) { return String(a); }
                }).join(' ')
              );
            } catch (e) {}
          };
          ['log', 'info', 'warn', 'error'].forEach(function (key) {
            var original = console[key];
            console[key] = function () {
              post(key, Array.prototype.slice.call(arguments));
              if (original) original.apply(console, arguments);
            };
          });
          window.addEventListener('error', function (event) {
            post('error', [event.message || 'script error']);
          });
          window.addEventListener('unhandledrejection', function (event) {
            post('error', ['unhandled rejection: ' + String(event.reason)]);
          });
        })();
        """

        var onLoadError: (String) -> Void
        var onBooted: (String) -> Void
        var generation = 0
        private var reportedBoot = false
        /// Bounds the forwarded console output kept on disk. The page logs its
        /// plugin inventory, which is long enough to matter but finite; a cap
        /// keeps a chatty failure from filling the container.
        private static let maxConsoleLines = 400
        private var consoleLines = 0

        init(onLoadError: @escaping (String) -> Void, onBooted: @escaping (String) -> Void) {
            self.onLoadError = onLoadError
            self.onBooted = onBooted
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.logHandlerName, let text = message.body as? String else { return }

            // Keep the page's own output. Without it, a page that failed to boot
            // is indistinguishable from one that never ran any script at all.
            if consoleLines < Self.maxConsoleLines {
                consoleLines += 1
                BootEvidence.stage("console: \(text.prefix(400))")
            }

            // The worker prints this once the whole plugin tree is mounted; it is
            // the strongest in-page evidence that the harness is running.
            if !reportedBoot, text.contains("tree active") {
                reportedBoot = true
                onBooted(text)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            // A fresh navigation may reach the harness after an earlier failure.
            reportedBoot = false
            BootEvidence.stage("navigation started")
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            BootEvidence.stage("content committing")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            BootEvidence.stage("document finished")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // The harness holds a large VFS image in memory; a terminated content
            // process is recoverable by reloading, not a silent blank screen.
            BootEvidence.stage("content process terminated")
            onLoadError("The page process was terminated. Reload to continue.")
        }

        /// Report only a failed top-level document, not every missing subresource.
        ///
        /// The page requests two paths the tunnel does not serve (the HMR event
        /// channel and the desktop open-in-app route); surfacing those as errors
        /// would train the user to ignore the banner.
        private func report(_ error: Error) {
            let code = (error as NSError).code
            // -999 is a cancelled load, which happens on an intentional reload.
            guard code != NSURLErrorCancelled else { return }
            onLoadError(error.localizedDescription)
        }
    }
}
