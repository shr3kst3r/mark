import AppKit
import Foundation
import UniformTypeIdentifiers
import WebKit

/// The pictures a document points at, served to the web view that is showing
/// it.
///
/// ## Why this exists at all
///
/// The shell page is served over `mark-asset://shell/shell.html`, and
/// ``ShellSchemeHandler`` serves exactly three files from that origin. A
/// document's own `![alt](assets/x.png)` therefore resolved to
/// `mark-asset://shell/assets/x.png`, which is not one of the three — so every
/// local image in every document was a broken-image icon, silently, while
/// `Resources/markdown-reference.md` told the reader that "paths are resolved
/// relative to the document".
///
/// ## Why a second scheme rather than widening the first
///
/// `mark-asset` is the *app's* origin: its three files are shipped in the
/// bundle and are the same for every document. Adding "…and also any file on
/// disk" to that handler would turn a fixed allowlist into a general file
/// server, and it would do so on the origin that also serves `shell.js` — the
/// script that owns the bridge to Swift. Two schemes keep the two questions
/// apart: `mark-asset` answers "what is the shell made of", and this one
/// answers "what pictures may *this document* show".
///
/// ## Why an allowlist rather than a path check
///
/// The obvious design — resolve the requested path, check it is under the
/// document's directory, serve it — does not survive contact with real notes,
/// where `../assets/diagram.png` is an ordinary thing to write. Widening the
/// rule to "anywhere under the sidebar root" makes the handler's behaviour
/// depend on where the reader happens to be browsing, which is not a security
/// boundary anyone can reason about.
///
/// So the set is computed instead: `mark_links_json` reports the images a
/// document actually names, resolved against its own directory, and this
/// handler serves those paths and refuses everything else. A page that asks for
/// a path the document does not reference gets a refusal, whatever that page's
/// script had in mind — which matters, because `pulldown-cmark` passes a
/// document's raw HTML through, so the page's script is not necessarily ours.
///
/// The set is replaced wholesale each time a document is set, so a picture
/// removed from a document stops being served the moment the edit lands.
@MainActor
public final class DocumentAssetSchemeHandler: NSObject, WKURLSchemeHandler {

    /// The scheme documents' own assets are served over.
    ///
    /// Distinct from ``ShellAssets/scheme`` (`mark-asset`) and from the
    /// `mark://` that ADR-3 registers with LaunchServices — three schemes, three
    /// jobs, and a handler registered for the wrong one shadows the others.
    public static let scheme = "mark-doc"

    /// What may be served, by path extension.
    ///
    /// An allowlist of *image* types, not "anything WebKit can display": the
    /// only thing a markdown document can ask this handler for is an `<img>`
    /// source, so anything that is not an image is a request nobody legitimate
    /// made.
    ///
    /// SVG is on the list and is the one that needs saying out loud. An SVG is
    /// a document, it can carry script, and it is served here from the
    /// document's own origin. It is served anyway because a diagram in a notes
    /// directory is very often an `.svg`, and because it is loaded through
    /// `<img>`, which does not execute script in any browser engine — WebKit
    /// included. An `<embed>` or `<object>` pointing at the same file would be
    /// a different matter, which is why the refusal below is on the *file*, not
    /// on how the page asked for it.
    static let servedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "heic", "heif",
        "bmp", "ico", "tif", "tiff",
    ]

    /// Why a request was refused. Named rather than silent, because the symptom
    /// of every one of these is the same broken-image icon.
    public enum AssetError: Error, CustomStringConvertible {
        case malformedURL(URL?)
        case noDocument(URL)
        case notReferenced(String)
        case notAnImage(String)
        case unreadable(String)

        public var description: String {
            switch self {
            case .malformedURL(let url):
                return "document asset request has no usable path: \(url?.absoluteString ?? "nil")"
            case .noDocument(let url):
                return "\(url.path) requested by a web view showing no document"
            case .notReferenced(let path):
                return "\(path) is not an image this document references"
            case .notAnImage(let path):
                return "\(path) is not an image type mark serves"
            case .unreadable(let path):
                return "\(path) could not be read"
            }
        }
    }

    /// Per-web-view allowlists.
    ///
    /// Keyed the way ``ScriptMessageRouter`` keys its bridges, and for the same
    /// reason: one handler instance is registered on the one shared
    /// `WKWebViewConfiguration` (ADR-4 requires the single configuration), so
    /// the handler has to tell the views apart itself. Entries are removed on
    /// dehydration rather than being held weakly — a `Set<String>` has no
    /// object to hang a weak reference off.
    private var allowed: [ObjectIdentifier: Set<String>] = [:]

    /// Declare the images a web view may load, replacing whatever it could
    /// load before.
    ///
    /// - Parameter paths: absolute, already resolved. `MarkCore.links` produces
    ///   exactly this from the document's source and its directory.
    public func allow(_ paths: Set<String>, for webView: WKWebView) {
        allowed[ObjectIdentifier(webView)] = paths
    }

    /// Forget a web view's allowlist, on dehydration or teardown.
    public func forget(_ webView: WKWebView) {
        allowed.removeValue(forKey: ObjectIdentifier(webView))
    }

    /// What `webView` may currently load. Test seam, and what `mark doctor`
    /// would print if this ever needs to be visible.
    public func allowedPaths(for webView: WKWebView) -> Set<String> {
        allowed[ObjectIdentifier(webView)] ?? []
    }

    public func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        do {
            let (data, mime) = try resolve(task.request.url, for: webView)
            let response = URLResponse(
                url: task.request.url!,
                mimeType: mime,
                expectedContentLength: data.count,
                // Binary. Naming an encoding here would be a lie for every type
                // on the list except SVG, and WebKit does not need one.
                textEncodingName: nil
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
        // Every asset is read synchronously, so there is never an in-flight
        // task to cancel. A large image is a `Data(contentsOf:)` on the main
        // thread and is the thing to revisit if a 40 MB scan ever appears in a
        // notes directory.
    }

    /// Route one request to bytes, or to a named refusal.
    ///
    /// Split out from ``webView(_:start:)`` so every refusal is testable
    /// without a live web view — which is the half that matters, since the
    /// refusals are the security boundary.
    func resolve(_ url: URL?, for webView: WKWebView) throws -> (data: Data, mime: String) {
        guard let url else { throw AssetError.malformedURL(nil) }
        // `url.path` is percent-decoded by Foundation, which is what turns
        // `mark-doc:///notes/my%20pic.png` back into the name on disk.
        let path = url.path
        guard !path.isEmpty, path.hasPrefix("/") else {
            throw AssetError.malformedURL(url)
        }

        let allowlist = allowed[ObjectIdentifier(webView)]
        guard let allowlist else { throw AssetError.noDocument(url) }

        // The allowlist is checked **before** the extension and before the
        // disk, so a refusal for an unreferenced path cannot be told apart
        // from a refusal for a missing one by timing it.
        guard allowlist.contains(path) else { throw AssetError.notReferenced(path) }

        let ext = (path as NSString).pathExtension.lowercased()
        guard Self.servedExtensions.contains(ext) else { throw AssetError.notAnImage(path) }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            !isDirectory.boolValue,
            let data = FileManager.default.contents(atPath: path)
        else {
            throw AssetError.unreadable(path)
        }
        return (data, Self.mime(forExtension: ext))
    }

    /// The MIME type for a served extension.
    ///
    /// From `UTType` where the system knows one, so a format macOS learns about
    /// later needs no change here; the fallback matters only for a type the
    /// system cannot name, and `application/octet-stream` would make WebKit
    /// refuse to draw it.
    static func mime(forExtension ext: String) -> String {
        if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            return mime
        }
        return "image/\(ext)"
    }

    /// The URL a web view should be given as its document base, so that the
    /// relative `src` in `![alt](assets/x.png)` resolves onto this scheme.
    ///
    /// A directory URL with a trailing slash, which is what makes a relative
    /// reference resolve *inside* it rather than beside it —
    /// `mark-doc:///notes/2026` would put `x.png` at `/notes/x.png`.
    public static func base(forDocumentAt url: URL) -> URL? {
        let directory = url.deletingLastPathComponent().standardizedFileURL
        var components = URLComponents()
        components.scheme = scheme
        // An empty host, so the path is the whole of the filesystem path and
        // the URL reads `mark-doc:///Users/…`. A host component would eat the
        // first path segment.
        components.host = ""
        components.path = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        return components.url
    }
}
