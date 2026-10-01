import SwiftUI
import WebKit
import DSHAssetServer

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
    enum Phase: Equatable {
        case idle
        case starting
        case running(URL)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Set when a load error arrives, so the UI can offer a retry.
    private(set) var loadError: String?

    @ObservationIgnored private var server: LocalAssetServer?
    /// Bumped to force SwiftUI to rebuild the web view for a genuine reload.
    private(set) var generation = 0

    /// The bundled harness and the worker-preview entry point.
    ///
    /// `preview-fixture` is deliberately omitted: with no query the page shows
    /// its source chooser, whose default is the empty environment. That is the
    /// right first run for a real client — the showcase fixture is sample data,
    /// not the user's own workspace.
    private static let entryPath = "preview.html"

    func start() async {
        guard case .idle = phase else { return }
        phase = .starting

        guard let root = Bundle.main.url(forResource: "HarnessAssets", withExtension: nil) else {
            phase = .failed("The bundled harness assets are missing from this build.")
            return
        }

        let server = LocalAssetServer(root: root)
        do {
            try server.start()
            guard let base = server.baseURL,
                  let entry = URL(string: Self.entryPath, relativeTo: base)
            else {
                server.stop()
                phase = .failed("The embedded server did not report a usable address.")
                return
            }
            self.server = server
            phase = .running(entry)
        } catch {
            phase = .failed("Could not start the embedded server: \(error)")
        }
    }

    /// Reload the harness from the bundled assets.
    func reload() {
        loadError = nil
        generation += 1
    }

    func reportLoadFailure(_ message: String) {
        loadError = message
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
                HarnessWebView(url: url, generation: model.generation) { message in
                    model.reportLoadFailure(message)
                }
                .ignoresSafeArea(edges: .bottom)
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

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoadError: onLoadError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.coordinator = context.coordinator

        // The harness keeps its state in the page and reloads often; leaving the
        // default process pool avoids serialising anything unusual.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        // The harness UI is a fixed layout; letting it bounce behind the
        // keyboard makes the composer awkward to use.
        view.scrollView.keyboardDismissMode = .interactive
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onLoadError = onLoadError

        // A generation change means an explicit reload was requested.
        guard context.coordinator.generation != generation else { return }
        context.coordinator.generation = generation
        view.stopLoading()
        view.load(URLRequest(url: url))
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var onLoadError: (String) -> Void
        var generation = 0

        init(onLoadError: @escaping (String) -> Void) {
            self.onLoadError = onLoadError
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        /// Report only a failed top-level document, not every missing subresource.
        ///
        /// The deployed preview shows two benign 404s (the HMR event channel and
        /// the desktop open-in-app route, neither of which the tunnel serves), and
        /// surfacing those as errors would train the user to ignore the banner.
        private func report(_ error: Error) {
            let code = (error as NSError).code
            // -999 is a cancelled load, which happens on an intentional reload.
            guard code != NSURLErrorCancelled else { return }
            onLoadError(error.localizedDescription)
        }
    }
}
