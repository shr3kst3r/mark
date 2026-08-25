import Foundation

/// Where the sidebar is rooted, how it got there, and how to get back.
///
/// M2's sidebar was rooted wherever the opened file lived and stayed there.
/// M8 makes the root a *place you move*, and the moment a root can move, three
/// things stop being derivable from it and have to be modelled: the breadcrumb
/// (which is just the root's components, but each one has to be clickable), the
/// back stack, and the forward stack.
///
/// This type is deliberately free of AppKit and of the filesystem. It never
/// lists a directory, never stats one, and never checks that a root exists —
/// that is ``TreeViewController``'s and ``DirectoryLister``'s job. What it owns
/// is the *history semantics*, which are the part that is easy to get subtly
/// wrong and impossible to see in a screenshot:
///
/// * Navigating to the root you are already on is a no-op, so a ⌘⇧O reveal that
///   happens to land in the current root does not fill the back stack with
///   duplicates.
/// * Any ordinary navigation clears the forward stack, exactly as a browser
///   does. Going back and then somewhere new means forward is gone.
/// * ``goBack()`` and ``goForward()`` move the current root *between* the two
///   stacks rather than pushing onto them, so "up, look, back down" — plan §2
///   M8's stated navigation loop — returns to where it started rather than
///   growing history on every hop.
///
/// The stacks are capped at ``historyLimit`` because they are persisted to the
/// session file, and an unbounded list of every directory visited in a long
/// session is both a large file and a small privacy leak in a tool that reads
/// private notes.
@MainActor
public final class Navigator {

    /// One clickable component of the breadcrumb.
    public struct Crumb: Equatable, Sendable {
        /// What the button shows. `/` for the filesystem root.
        public let name: String
        /// Where clicking it navigates to.
        public let url: URL

        public init(name: String, url: URL) {
            self.name = name
            self.url = url
        }
    }

    /// Why the root moved. Only used for logging, but a log line that says
    /// *how* the user got somewhere is the difference between "the root is
    /// wrong" and "the root is wrong because reveal moved it".
    public enum Reason: String, Sendable {
        case jump
        case parent
        case back
        case forward
        case reveal
        case restore
    }

    /// How many roots each stack remembers. Not a UI limit; a session-file one.
    public static let historyLimit = 64

    public private(set) var root: URL

    /// Roots visited before this one, oldest first.
    public private(set) var back: [URL] = []

    /// Roots returned *from* by ``goBack()``, most recent first.
    public private(set) var forward: [URL] = []

    /// Called after any change, including a restore.
    public var onChange: ((Navigator, Reason) -> Void)?

    public init(root: URL) {
        self.root = Self.normalize(root)
    }

    // MARK: - Reading

    /// Whether there is a parent directory to go up to. False at `/`.
    public var canGoUp: Bool {
        let parent = root.deletingLastPathComponent()
        return Self.normalize(parent).path != root.path
    }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// The root's path, as clickable components, outermost first.
    ///
    /// `/Users/you/notes` yields `/`, `Users`, `you`, `notes` — the last
    /// crumb is the current root, so the bar always shows where you are and
    /// never needs a separate label.
    public var breadcrumb: [Crumb] {
        var crumbs = [Crumb(name: "/", url: URL(fileURLWithPath: "/", isDirectory: true))]
        var url = URL(fileURLWithPath: "/", isDirectory: true)
        for component in root.pathComponents.dropFirst() where !component.isEmpty {
            url = url.appendingPathComponent(component, isDirectory: true)
            crumbs.append(Crumb(name: component, url: Self.normalize(url)))
        }
        return crumbs
    }

    // MARK: - Moving

    /// Make `url` the root, remembering where we were.
    ///
    /// - Returns: whether anything moved. `false` means `url` is already the
    ///   root, which is not a failure — it is the reason a reveal into the
    ///   current root does not push history.
    @discardableResult
    public func go(to url: URL, reason: Reason = .jump) -> Bool {
        let target = Self.normalize(url)
        guard target.path != root.path else { return false }
        push(&back, root)
        forward.removeAll()
        root = target
        note(reason)
        return true
    }

    /// ⌘↑.
    @discardableResult
    public func goToParent() -> Bool {
        guard canGoUp else { return false }
        return go(to: root.deletingLastPathComponent(), reason: .parent)
    }

    /// ⌘[.
    @discardableResult
    public func goBack() -> Bool {
        guard let previous = back.popLast() else { return false }
        push(&forward, root)
        root = previous
        note(.back)
        return true
    }

    /// ⌘].
    @discardableResult
    public func goForward() -> Bool {
        guard let next = forward.popLast() else { return false }
        push(&back, root)
        root = next
        note(.forward)
        return true
    }

    // MARK: - Session

    /// Adopt a persisted root and history **without recording a navigation**.
    ///
    /// The distinction matters: restoring through ``go(to:reason:)`` would push
    /// the launch-directory root onto the back stack, so every relaunch would
    /// add one entry and ⌘[ after a restore would go somewhere the user never
    /// was.
    public func restore(root: URL, back: [URL], forward: [URL]) {
        self.root = Self.normalize(root)
        self.back = Array(back.map(Self.normalize).suffix(Self.historyLimit))
        self.forward = Array(forward.map(Self.normalize).suffix(Self.historyLimit))
        note(.restore)
    }

    // MARK: - Plumbing

    private func push(_ stack: inout [URL], _ url: URL) {
        stack.append(url)
        if stack.count > Self.historyLimit {
            stack.removeFirst(stack.count - Self.historyLimit)
        }
    }

    private func note(_ reason: Reason) {
        Log.tree.info(
            "root -> \(self.root.path, privacy: .public) (\(reason.rawValue, privacy: .public); back \(self.back.count), forward \(self.forward.count))"
        )
        onChange?(self, reason)
    }

    /// One canonical spelling of a directory URL, so `/tmp/x`, `/tmp/x/`, and
    /// `/tmp/./x` compare equal.
    ///
    /// Symlinks are deliberately **not** resolved, matching `core/src/tree.rs`:
    /// *"deliberately does not resolve symlinks, so a symlinked notes directory
    /// keeps the name the user typed"*. Resolving here and not there would make
    /// the breadcrumb disagree with the listing.
    public static func normalize(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    }
}
