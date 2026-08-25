import Foundation
import WebKit

/// `shell.html`, `shell.js`, `shell.css` — where they live and how they reach
/// the web view.
///
/// They are served over a custom URL scheme through a ``ShellSchemeHandler``,
/// **not** via `loadHTMLString` with a `file:` base URL. That alternative looks
/// simpler and is not: WebKit applies subresource restrictions to `file:`
/// origins, so the stylesheet and script frequently fail to load, and there is
/// no caching story for the shell page at all.
public enum ShellAssets {

    /// The scheme the shell page and its subresources are served over.
    ///
    /// Deliberately **not** `mark:`. ADR-3 registers `mark://` with
    /// LaunchServices as the app's cold-launch entry point in M4, and a
    /// `WKURLSchemeHandler` registered for the same scheme would quietly
    /// shadow it inside the web view.
    public static let scheme = "mark-asset"

    /// The shell page's URL.
    public static let shellURL = URL(string: "\(scheme)://shell/shell.html")!

    /// Everything this handler will serve. Anything not on this list is a 404:
    /// the handler must not become a general file server for a tool that opens
    /// documents from anywhere on disk.
    /// The MIME type is the bare type with **no `; charset=` parameter**:
    /// `URLResponse(url:mimeType:...)` takes the encoding as a separate
    /// argument and does not parse parameters out of this one, so a value like
    /// `"text/html; charset=utf-8"` is not recognised and WebKit falls back to
    /// `text/plain` — which renders the shell page as its own source text.
    static let served: [String: String] = [
        "shell.html": "text/html",
        "shell.js": "text/javascript",
        "shell.css": "text/css",
    ]

    /// Load one shell asset.
    ///
    /// Two locations, because there are two ways the code runs: from
    /// `mark.app/Contents/Resources` once `scripts/assemble-bundle.sh` has run,
    /// and from SwiftPM's generated resource bundle under `swift run` and
    /// `swift test`.
    ///
    /// `Bundle.main` is tried on its own and returned from before
    /// ``moduleBundle`` is ever mentioned. That ordering is load-bearing, not
    /// style: SwiftPM generates `Bundle.module` as a `static let` whose
    /// initialiser calls `fatalError` when it cannot find
    /// `Mark_MarkKit.bundle`, and it looks in exactly two places —
    /// `Bundle.main.bundleURL/Mark_MarkKit.bundle` (the *root* of `mark.app`,
    /// not `Contents/Resources`) and the absolute `.build` path baked in at
    /// compile time. In an installed app neither exists: the bundle is at
    /// `Contents/Resources/`, and the build directory belonged to the machine
    /// or the Homebrew sandbox that compiled it. Writing the two bundles as one
    /// array — `for bundle in [Bundle.main, Bundle.module]` — evaluates both
    /// elements before the loop body runs, so the shipped app crashed on its
    /// first shell asset even though `Bundle.main` held the answer.
    public static func data(named name: String) -> Data? {
        if let data = data(named: name, in: Bundle.main) {
            return data
        }
        if let bundle = moduleBundle, let data = data(named: name, in: bundle) {
            return data
        }
        Log.shell.error("shell asset \(name, privacy: .public) not found in any bundle")
        return nil
    }

    private static func data(named name: String, in bundle: Bundle) -> Data? {
        guard let url = bundle.url(forResource: name, withExtension: nil) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Anchors ``moduleBundle`` to the bundle MarkKit's own code was loaded
    /// from, which is not always `Bundle.main`.
    private final class BundleFinder {}

    /// SwiftPM's generated resource bundle, or `nil` when there is not one.
    ///
    /// Internal rather than private so `ShellAssetsTests` can assert it
    /// resolves. That assertion is worth the exposure: when it does not
    /// resolve, the test suite hangs before its first line of output rather
    /// than failing.
    ///
    /// `Bundle.module` cannot be asked whether it exists — reading it either
    /// answers or kills the process — so this does the same search over
    /// `Bundle(url:)`, which returns `nil` instead of trapping.
    ///
    /// Two anchors, because `Bundle.main` is not always the thing that holds
    /// MarkKit. In `mark.app` it is, and `resourceURL` is the
    /// `Contents/Resources` copy `scripts/assemble-bundle.sh` writes. Under
    /// `swift test`, though, `Bundle.main` is SwiftPM's *test helper* over in
    /// `/Library/Developer/CommandLineTools/usr/libexec/swift/pm/` — nothing of
    /// ours is anywhere near it — while `Bundle(for: BundleFinder.self)` is
    /// `MarkPackageTests.xctest`, whose parent directory is the `.build`
    /// configuration directory the resource bundle sits in. Leaving that anchor
    /// out does not fail loudly: the shell page never loads, the first `await`
    /// on a rendered web view never returns, and the whole suite hangs with no
    /// output at all.
    static let moduleBundle: Bundle? = {
        let name = "Mark_MarkKit.bundle"
        let anchors = [Bundle.main, Bundle(for: BundleFinder.self)]
        // `resourceURL` first (an assembled .app or .xctest), then the bundle
        // itself (`swift run`, `mark-bench` — a bare executable's bundleURL is
        // the directory it sits in), then the parent (`swift test`, where the
        // resource bundle is a sibling of the .xctest).
        let candidates = anchors.flatMap { anchor -> [URL] in
            [
                anchor.resourceURL,
                anchor.bundleURL,
                anchor.bundleURL.deletingLastPathComponent(),
            ].compactMap { $0?.appendingPathComponent(name) }
        }
        for url in candidates {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return nil
    }()
}

/// Serves the shell's three assets, and nothing else.
public final class ShellSchemeHandler: NSObject, WKURLSchemeHandler {

    /// Why a shell asset request was refused. Surfaced to the web view as a
    /// failed load *and* to `OSLog`, so a missing asset is a named error rather
    /// than a blank window.
    public enum AssetError: Error, CustomStringConvertible {
        case malformedURL(URL?)
        case notServed(String)
        case unreadable(String)

        public var description: String {
            switch self {
            case .malformedURL(let url):
                return "shell asset request has no usable path: \(url?.absoluteString ?? "nil")"
            case .notServed(let name):
                return "\(name) is not a shell asset"
            case .unreadable(let name):
                return "\(name) is missing from the app bundle"
            }
        }
    }

    public func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        do {
            let (data, mime) = try resolve(task.request.url)
            let response = URLResponse(
                url: task.request.url!,
                mimeType: mime,
                expectedContentLength: data.count,
                textEncodingName: "utf-8"
            )
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        } catch {
            Log.shell.error("\(String(describing: error), privacy: .public)")
            task.didFailWithError(error)
        }
    }

    public func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        // Every asset is served synchronously from memory, so there is never
        // an in-flight task to cancel.
    }

    /// Split out so the routing — including the refusals — is testable without
    /// a web view.
    ///
    /// `nonisolated` because conforming to `WKURLSchemeHandler` makes this
    /// class `@MainActor`, and WebKit's `@preconcurrency` annotations turn a
    /// cross-isolation call into a *runtime* trap rather than a compile error —
    /// which is a `SIGTRAP` in a test rather than a diagnostic. Resolving a
    /// name to bytes needs no actor.
    nonisolated public func resolve(_ url: URL?) throws -> (data: Data, mime: String) {
        guard let url else { throw AssetError.malformedURL(nil) }
        let name = url.lastPathComponent
        guard !name.isEmpty, !name.contains("/") else { throw AssetError.malformedURL(url) }
        guard let mime = ShellAssets.served[name] else { throw AssetError.notServed(name) }
        guard let data = ShellAssets.data(named: name) else { throw AssetError.unreadable(name) }
        return (data, mime)
    }
}

/// Sends each page's messages to the right document.
///
/// This exists because of a collision between two things that are individually
/// fine. ADR-4 requires **one shared** `WKWebViewConfiguration`; a
/// configuration owns exactly one `WKUserContentController`; and a content
/// controller allows exactly one handler per message name. M2 handled that by
/// removing the previous handler and adding the new one on every
/// ``WebViewFactory/makeWebView(bridge:)`` — correct with one web view, and
/// silently wrong with N: only the most recently created tab would have
/// received `ready`, `toggle`, or `link`, and every other tab would have sat
/// there never painting, with nothing in the log to say why.
///
/// So there is one handler for the whole process, and it routes on
/// `WKScriptMessage.webView`.
@MainActor
final class ScriptMessageRouter: NSObject, WKScriptMessageHandler {

    /// Unowned by design: the router must not keep a torn-down tab's bridge —
    /// or, through it, its `DocumentView` and web view — alive past
    /// dehydration.
    private var routes: [ObjectIdentifier: WeakBridge] = [:]

    private struct WeakBridge {
        weak var bridge: ScriptBridge?
    }

    func register(_ bridge: ScriptBridge, for webView: WKWebView) {
        routes[ObjectIdentifier(webView)] = WeakBridge(bridge: bridge)
    }

    func unregister(_ webView: WKWebView) {
        routes.removeValue(forKey: ObjectIdentifier(webView))
        routes = routes.filter { $0.value.bridge != nil }
    }

    var routeCount: Int { routes.values.filter { $0.bridge != nil }.count }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let webView = message.webView else {
            Log.shell.error("script message with no source web view; dropped")
            return
        }
        guard let bridge = routes[ObjectIdentifier(webView)]?.bridge else {
            // Expected exactly once per dehydration: a message already in
            // flight when the web view was torn down. Debug, not error.
            Log.shell.debug("script message from an unrouted web view; dropped")
            return
        }
        bridge.userContentController(controller, didReceive: message)
    }
}

/// The one `WKWebViewConfiguration` every web view in the process shares.
///
/// ADR-4 makes this a constraint rather than an optimization: *"All web views
/// share one `WKWebViewConfiguration` — this is what keeps them in a single
/// content process and makes allocation ~1.3 ms. Per-tab configurations
/// measured ~2× slower to create."*
@MainActor
public enum WebViewFactory {

    /// Routes page messages to the web view that sent them. One instance,
    /// registered once, for the life of the process.
    static let router = ScriptMessageRouter()

    /// Built once, lazily, on first use.
    public static let configuration: WKWebViewConfiguration = {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(ShellSchemeHandler(), forURLScheme: ShellAssets.scheme)
        configuration.suppressesIncrementalRendering = false
        if #available(macOS 14.0, *) {
            // The documents this renders are the user's own files, but they can
            // still contain arbitrary embedded HTML. Nothing here needs to
            // navigate anywhere.
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        }
        // Registered here rather than per web view, so nothing ever removes a
        // live tab's handler. See ``ScriptMessageRouter``.
        configuration.userContentController.removeScriptMessageHandler(
            forName: ScriptBridge.messageName)
        configuration.userContentController.add(router, name: ScriptBridge.messageName)
        return configuration
    }()

    /// A web view on the shared configuration, with the script bridge attached.
    public static func makeWebView(bridge: ScriptBridge) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true
        router.register(bridge, for: webView)
        return webView
    }

    /// Stop routing to `webView`. Called on dehydration and on tab close;
    /// forgetting it would leak a routing-table entry per closed tab.
    public static func release(_ webView: WKWebView) {
        router.unregister(webView)
    }

    /// How many web views the router is currently delivering to. For the tests
    /// that assert dehydration actually released something.
    public static var routedWebViewCount: Int { router.routeCount }
}
