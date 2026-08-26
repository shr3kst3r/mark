import Foundation

/// The document behind **Help ▸ Markdown Reference**.
///
/// `2026-08-26-markdown-reference-window`: the help screen is a markdown
/// document that mark renders, not a page that describes mark. It goes through
/// `mark_render_html`, the highlighter, `pulldown-latex` and `merman` exactly
/// as your own files do, so a construct that stops working stops working
/// *visibly*, on the page whose whole job is to claim it works.
///
/// It ships in `Contents/Resources` beside the shell assets (and in SwiftPM's
/// generated bundle under `swift test`), which is why the lookup is
/// ``ShellAssets``' rather than a second copy of that search — the ordering in
/// there is load-bearing and documented once.
///
/// It is deliberately **not** on ``ShellAssets/served``. The scheme handler
/// serves the shell page and its two subresources and 404s everything else, on
/// purpose; this file is read by Swift and injected as rendered HTML like any
/// other document.
public enum MarkdownReference {

    /// The resource's name in the bundle.
    public static let resourceName = "markdown-reference.md"

    /// Where the shipped copy lives, or `nil` if this build has none.
    ///
    /// Wanted as well as ``source`` because a `DocumentView` renders *for* a
    /// URL: it is what `#anchor` links resolve against, what the window puts in
    /// `representedURL`, and what every log line about this document names.
    public static var url: URL? { ShellAssets.url(named: resourceName) }

    /// The reference's markdown, or `nil` if this build has none.
    ///
    /// `nil` is a real answer rather than a crash: a bundle assembled without
    /// the resource should disable one menu item, not take the app down. The
    /// missing-resource case is already logged by ``ShellAssets``.
    public static var source: String? {
        guard let data = ShellAssets.data(named: resourceName) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether this build can show the reference at all. Drives the menu
    /// item's validation.
    public static var isAvailable: Bool { url != nil }
}

/// A ``TaskWriteTarget`` that writes nothing, for a document that is not the
/// reader's.
///
/// The reference demonstrates task lists, so it contains checkboxes, and a
/// checkbox in a `DocumentView` is wired to a writer. The shipped copy lives
/// inside `mark.app/Contents/Resources`: on a locally built bundle a write
/// there would succeed and quietly edit the reference, and on a signed one it
/// would fail and break the seal. Neither is a state one click should reach.
///
/// It **refuses** rather than silently doing nothing, so the click takes the
/// path every other refused write takes — logged with a reason, and followed by
/// the reload that puts the box back where the file says it is.
public final class RefusingTaskWriter: TaskWriteTarget {

    public init() {}

    public func apply(_ toggle: TaskToggle, to url: URL) throws -> TaskWriteResult {
        throw TaskWriteRefusal.core(
            function: "RefusingTaskWriter",
            detail: "the markdown reference ships inside the app bundle and is never written to",
            path: url.path)
    }
}
