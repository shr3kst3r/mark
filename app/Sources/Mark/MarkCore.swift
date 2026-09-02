import AppKit
import CMarkCore
import Foundation

/// The Swift side of ADR-1's C ABI.
///
/// The ADR's ownership rule — *every pointer the core returns is freed with
/// `mark_free`, and with nothing else* — is not expressible in C and is not
/// checked by anything. So it is enforced structurally here rather than
/// remembered at each call site: the raw `mark_*` functions are called in
/// exactly one place per entry point, the result is immediately handed to
/// ``CoreString``, and ``CoreString/deinit`` is the only `mark_free` in the
/// app. Nothing outside this file sees a `char *`.
///
/// The ADR's other two constraints show up here as well:
///
/// * No `extern "C"` function unwinds, so failure arrives as `NULL` or `-1`
///   rather than as a trap. Every entry point below converts that into a typed
///   ``CoreError`` carrying `mark_last_error()`'s message.
/// * `mark_last_error()` is thread-local, so it is read on the thread that
///   failed — always synchronously, in the same function as the failing call.
public enum MarkCore {

    // MARK: - Version

    /// The core's version, e.g. `"0.2.0"`.
    public static func version() throws -> String {
        try string(function: "mark_version") { mark_version() }
    }

    // MARK: - Rendering

    /// Markdown → HTML fragments, one `<div class="mk-blk">` per top-level
    /// block.
    ///
    /// - Parameter prefixBlocks: ADR-2's first-paint tunable. Emits only the
    ///   first `N` blocks; `0` emits the whole document. This is deliberately a
    ///   parameter and not a constant — see ``ProgressiveRenderer/prefixBlockCount(viewportHeight:blockHeight:)``,
    ///   which derives it from viewport height at runtime.
    /// - Parameter theme: the theme to render in, or `nil` for the default.
    ///   Code tokens come out as palette *slots* — `<span class="t0B">` — whose
    ///   colours are CSS custom properties carrying both appearances, so this
    ///   chooses the *scope map*, not the colours. Two themes that share a map,
    ///   which every shipped theme does, produce byte-identical HTML.
    /// - Throws: ``CoreError`` when the theme does not exist or is missing a
    ///   slot. The core refuses rather than substituting the default, because
    ///   the failure it is guarding against is a page of invisible text.
    /// - Parameter standalone: wrap the result in a complete `<html>` document
    ///   with both palettes inline, instead of the bare `mk-blk` fragments the
    ///   shell injects. `File ▸ Export as HTML…` passes `true`, and takes the
    ///   same code path `mark render --html` does — so an exported document and
    ///   a piped one cannot disagree.
    public static func renderHTML(
        source: String, prefixBlocks: Int = 0, theme: String? = nil, standalone: Bool = false
    ) throws -> String {
        precondition(prefixBlocks >= 0, "prefixBlocks is a count, not an index")
        let flags: Int32 = standalone ? MARK_RENDER_STANDALONE : 0
        return try string(function: "mark_render_html") {
            withOptionalCString(theme) { themePointer in
                source.withCString {
                    mark_render_html($0, size_t(prefixBlocks), themePointer, flags)
                }
            }
        }
    }

    // MARK: - Diffing

    /// Two versions of one document as ADR-2's minimal edit script.
    ///
    /// The script is kept as **JSON text**, not decoded into Swift values, and
    /// that is deliberate: its only consumer is `shell.js`, which parses it and
    /// applies it to the DOM. Decoding it here would mean building a Swift
    /// model of every op and its inline HTML only to serialize it straight back
    /// out across `callAsyncJavaScript`. The counters are decoded, because they
    /// are what the app logs per patch — plan §4's "someone arriving cold at an
    /// incident" test is answered by "kept 3,730, replaced 1", not by the ops.
    public static func diff(old: String, new: String, theme: String? = nil) throws -> EditScript {
        let json = try string(function: "mark_diff_json") {
            withOptionalCString(theme) { themePointer in
                old.withCString { oldPointer in
                    new.withCString { newPointer in
                        mark_diff_json(oldPointer, newPointer, themePointer, 0)
                    }
                }
            }
        }
        let counters = try decode(EditScript.Counters.self, from: json, function: "mark_diff_json")
        return EditScript(json: json, counters: counters)
    }

    // MARK: - Queries

    /// Every task in the document, in document order.
    public static func tasks(source: String) throws -> [Task] {
        try decode([Task].self, from: tasksJSON(source: source), function: "mark_tasks_json")
    }

    /// The same, as the core's own JSON.
    ///
    /// The re-stamping path (``DocumentView``) hands this straight to the page,
    /// so decoding it into `[Task]` and re-encoding it would be two conversions
    /// of the same bytes for no gain. It is the *authority* for
    /// `data-mk-idx` / `data-mk-start` / `data-mk-end` after a patch, which is
    /// why it exists as a separate entry point rather than being reconstructed
    /// from the decoded form.
    public static func tasksJSON(source: String) throws -> String {
        try string(function: "mark_tasks_json") {
            source.withCString { mark_tasks_json($0, 0) }
        }
    }

    /// The document's tasks **and** its top-level blocks with their byte
    /// ranges, from one parse.
    ///
    /// What ``EditorPane`` highlights from.
    /// `2026-08-24-editing-pane-and-autosave` says markdown source
    /// highlighting *"is driven by the core's existing block byte ranges, not
    /// by a second parser"*, and M5 pinned the other half of that: those
    /// ranges must come from a **fresh parse of the buffer** and never off the
    /// DOM, where a kept block's `data-mk-start` / `data-mk-end` are stale
    /// after a patch and cannot be refreshed over this ABI
    /// (`DocumentPatchTests.blockByteSpansStayStaleOnKeptBlocks`).
    ///
    /// Tasks come along because the editor needs both and one parse answers
    /// both: the preview renders from the buffer while a tab is dirty, so the
    /// task indices it stamps have to come from the same bytes the blocks did.
    public static func structure(source: String) throws -> DocumentStructure {
        try decode(
            DocumentStructure.self,
            from: tasksBlocksJSON(source: source),
            function: "mark_tasks_json")
    }

    /// The same, undecoded — for measuring the two halves separately.
    public static func tasksBlocksJSON(source: String) throws -> String {
        try string(function: "mark_tasks_json") {
            source.withCString { mark_tasks_json($0, MARK_TASKS_BLOCKS) }
        }
    }

    /// The heading tree, with anchors and byte offsets.
    public static func toc(source: String) throws -> [Heading] {
        try decode([Heading].self, from: tocJSON(source: source), function: "mark_toc_json")
    }

    /// The same, as the core's own JSON. See ``tasksJSON(source:)``.
    public static func tocJSON(source: String) throws -> String {
        try string(function: "mark_toc_json") {
            source.withCString { mark_toc_json($0) }
        }
    }

    /// Every link and image in a document, with local destinations resolved
    /// against `base` and `stat`ed.
    ///
    /// The shell asks for `images: true` and nothing else. That answer is the
    /// allowlist ``DocumentAssetSchemeHandler`` serves from, and populating it
    /// from the core — rather than letting the handler resolve whatever path a
    /// page asks for — is what keeps it an allowlist instead of a file server
    /// aimed at the reader's home directory.
    ///
    /// - Parameter base: the directory holding the document. `nil` skips
    ///   resolution entirely, which is what a caller with no file on disk (an
    ///   unsaved buffer, the Today page) wants: `path` and `exists` come back
    ///   `nil`, which is a different answer from "checked and missing".
    public static func links(
        source: String,
        base: String? = nil,
        images: Bool = false,
        brokenOnly: Bool = false
    ) throws -> [Reference] {
        var flags: Int32 = 0
        if images { flags |= MARK_LINKS_IMAGES }
        if brokenOnly { flags |= MARK_LINKS_BROKEN }
        let json = try string(function: "mark_links_json") {
            source.withCString { source in
                guard let base else { return mark_links_json(source, nil, flags) }
                return base.withCString { mark_links_json(source, $0, flags) }
            }
        }
        return try decode([Reference].self, from: json, function: "mark_links_json")
    }

    /// Search a file, or every markdown file below a directory.
    ///
    /// The engine is the core's, not `NSRegularExpression`'s, and that is the
    /// point: Rust's `regex` and ICU disagree about `\d`, `(?i)`, lookaround,
    /// and `$` under multi-line, so a second implementation here would mean
    /// `mark grep` and this search box answering the same pattern differently
    /// (`2026-09-01-search-in-the-core`).
    ///
    /// **Call this off the main actor.** It opens every markdown file below
    /// `root`.
    ///
    /// - Parameter limit: cap on hits, across all files. The window passes one
    ///   because it searches on every keystroke; 0 means no cap.
    public static func search(
        root: String,
        pattern: String,
        depth: Int = 0,
        limit: Int = 0,
        ignoreCase: Bool = false,
        hidden: Bool = false
    ) throws -> SearchResults {
        var flags: Int32 = 0
        if ignoreCase { flags |= MARK_SEARCH_IGNORE_CASE }
        if hidden { flags |= MARK_SEARCH_HIDDEN }
        let json = try string(function: "mark_search_json") {
            root.withCString { root in
                pattern.withCString { pattern in
                    mark_search_json(root, pattern, size_t(depth), size_t(limit), flags)
                }
            }
        }
        return try decode(SearchResults.self, from: json, function: "mark_search_json")
    }

    /// Every reference below `root` that points at `target`.
    ///
    /// **Call this off the main actor.** It parses every markdown file below
    /// `root`.
    public static func backlinks(root: String, target: String, depth: Int = 0) throws
        -> [Backlink]
    {
        let json = try string(function: "mark_backlinks_json") {
            root.withCString { root in
                target.withCString { target in
                    mark_backlinks_json(root, target, size_t(max(0, depth)))
                }
            }
        }
        return try decode([Backlink].self, from: json, function: "mark_backlinks_json")
    }

    /// How long a document is, in the units a writer cares about.
    ///
    /// The counting is the core's because it needs the parser: frontmatter,
    /// fenced and inline code, math, diagrams, an image's alt text and a link's
    /// URL are none of them prose, and a whitespace split in Swift would count
    /// all of them. `mark stats` gets the same answer.
    public static func wordCount(source: String) throws -> WordCount {
        let json = try string(function: "mark_wordcount_json") {
            source.withCString { mark_wordcount_json($0) }
        }
        return try decode(WordCount.self, from: json, function: "mark_wordcount_json")
    }

    /// One directory level.
    ///
    /// `depth` is clamped to at least 1 by the core; there is no unlimited
    /// walk. The sidebar always passes 1, because the user's real tree holds
    /// 608k files (research §2.8) and an eager descent there is a multi-second
    /// hang.
    ///
    /// - Parameter depth: 0 means the whole tree, 1 means this directory only.
    ///   The sidebar always passes 1 — see below; `Open Quickly` passes 0.
    /// - Parameter withStats: opens every markdown file for its title and task
    ///   counts. Off by default: it is a read of every file in the directory.
    /// - Parameter options: the sidebar's two "show me more" toggles. Before M7
    ///   these were unreachable over the ABI and the app reimplemented them over
    ///   `FileManager`; the core has always modelled them, and it is the only
    ///   thing that knows whether a non-markdown file was `.gitignore`d.
    public static func tree(
        directory: String,
        depth: Int = 1,
        withStats: Bool = false,
        options: TreeListingOptions = TreeListingOptions()
    ) throws -> [TreeEntry] {
        let json = try string(function: "mark_tree_json") {
            directory.withCString {
                // `max(0, …)` and not `max(1, …)`: 0 is a *meaning* — the
                // whole tree — and clamping it to 1 quietly turned `Open
                // Quickly`'s recursive walk into a listing of one directory.
                // Negatives are still clamped, since `size_t(-1)` is a walk
                // that never ends.
                mark_tree_json($0, size_t(max(0, depth)), withStats ? 1 : 0, options.coreFlags)
            }
        }
        return try decode([TreeEntry].self, from: json, function: "mark_tree_json")
    }

    // MARK: - Git

    /// What git says about `path` — the whole repository's changed set.
    ///
    /// `path` may be a file or a directory; either way the answer covers the
    /// repository, because `2026-08-28-git-differences-by-running-git` measured
    /// that to be the unit: one ~12 ms call answers every row, where one call
    /// per row would be 6 ms of process startup each.
    ///
    /// Returns a report whose ``GitReport/repo`` is `nil` for a path outside any
    /// repository **and** for a machine with no usable git. That is not an
    /// error, and the two are deliberately indistinguishable: the row draws
    /// unbadged either way.
    ///
    /// - Important: never call this on the main thread. It forks `git`.
    public static func git(status path: String, includeUntracked: Bool = true) throws -> GitReport {
        let flags = includeUntracked ? 0 : MARK_GIT_NO_UNTRACKED
        let json = try string(function: "mark_git_json") {
            path.withCString { mark_git_json($0, flags) }
        }
        return try decode(GitReport.self, from: json, function: "mark_git_json")
    }

    /// `HEAD`'s bytes for one file, or `nil` when `HEAD` does not have it.
    ///
    /// `nil` covers a new note, a binary blob, and a non-UTF-8 one — all of
    /// which mean "there is nothing here we can diff", which is what the caller
    /// does with the answer.
    ///
    /// - Important: never call this on the main thread, and cache the result
    ///   against the repository's `HEAD` oid. The read costs ~7 ms and cannot
    ///   change while the oid does not.
    public static func git(base path: String) throws -> GitBase {
        let json = try string(function: "mark_git_json") {
            path.withCString { mark_git_json($0, MARK_GIT_BASE) }
        }
        return try decode(GitBase.self, from: json, function: "mark_git_json")
    }

    /// Just the line diff, for a caller that wants counts and hunks and not
    /// HTML.
    ///
    /// The gutter and the dirty-buffer badge both want this and neither wants
    /// the merged document, which costs a second render of every changed block.
    public static func lineDiff(old: String, new: String) throws -> LineDiff {
        let json = try string(function: "mark_diff_json") {
            old.withCString { oldPointer in
                new.withCString { newPointer in
                    mark_diff_json(oldPointer, newPointer, nil, MARK_DIFF_LINES)
                }
            }
        }
        struct Envelope: Decodable { let lines: LineDiff }
        return try decode(Envelope.self, from: json, function: "mark_diff_json").lines
    }

    /// A document's differences against another version of itself, at both
    /// granularities plus the merged diff document.
    ///
    /// One call, one parse of each side. The block diff drives the rendered
    /// view, the line diff drives the editor's change gutter, and neither is
    /// derivable from the other — a block spans many lines, so it cannot place
    /// a bar against line 41.
    public static func diffDetail(
        old: String,
        new: String,
        theme: String? = nil
    ) throws -> DiffDetail {
        let json = try string(function: "mark_diff_json") {
            withOptionalCString(theme) { themePointer in
                old.withCString { oldPointer in
                    new.withCString { newPointer in
                        mark_diff_json(
                            oldPointer, newPointer, themePointer,
                            MARK_DIFF_LINES | MARK_DIFF_DOCUMENT)
                    }
                }
            }
        }
        return try decode(DiffDetail.self, from: json, function: "mark_diff_json")
    }

    // MARK: - Themes

    /// Every theme that can be named, built in and from `~/.config/mark/themes`.
    public static func themes() throws -> ThemeCatalog {
        let json = try string(function: "mark_theme_json") {
            mark_theme_json(nil, MARK_THEME_LIST)
        }
        return try decode(ThemeCatalog.self, from: json, function: "mark_theme_json")
    }

    /// Resolve a theme name to a light/dark pair.
    ///
    /// - Parameter name: `nil` for the default.
    /// - Throws: ``CoreError`` naming the theme and what is wrong with it — no
    ///   such theme, a palette missing a slot, a chrome key pointing at one
    ///   that is not defined. Never a silent substitution.
    public static func theme(named name: String? = nil) throws -> ResolvedTheme {
        let json = try string(function: "mark_theme_json") {
            withOptionalCString(name) { mark_theme_json($0, 0) }
        }
        return try decode(ResolvedTheme.self, from: json, function: "mark_theme_json")
    }

    // MARK: - Writes

    /// What a toggle should do to a task marker.
    ///
    /// The raw values **are** the ABI's `action` domain, and
    /// `2026-08-27-five-task-states` widened it rather than adding a thirteenth
    /// entry point: *"the old encoding is a prefix of the new one"*, so `off`,
    /// `on` and `toggle` keep the numbers they always had.
    public enum ToggleAction: Int32 {
        case off = 0
        case on = 1
        case toggle = 2
        case inProgress = 3
        case cancel = 4
        case block = 5
    }

    /// Flip one checkbox in a file on disk, changing exactly one byte.
    ///
    /// Wired but unused in M2: clicking a checkbox is a logged no-op until M5
    /// (see ``ScriptBridge``). It exists here so the seam is the ABI wrapper
    /// rather than something M5 has to invent.
    ///
    /// - Returns: the task's new state.
    @discardableResult
    public static func toggle(path: String, index: Int, action: ToggleAction) throws -> TaskState {
        let result = path.withCString { mark_toggle($0, size_t(index), action.rawValue) }
        guard result >= 0 else {
            throw CoreError(function: "mark_toggle", detail: lastError())
        }
        guard let state = TaskState(code: result) else {
            // In range for the ABI's "not a failure" half, but not a state
            // this binary knows: the core is newer than the app. Reported
            // rather than rounded to `.done`, because a byte has been written
            // and the caller is about to log what it was.
            throw CoreError(
                function: "mark_toggle",
                detail: "the core returned state code \(result), which this app does not know")
        }
        return state
    }

    /// Save `source` to `path`, atomically, through the core.
    ///
    /// The **only** way the app writes an edited document.
    /// `2026-08-24-editing-pane-and-autosave`: *"Every write goes through
    /// `write_atomically`. No direct `fs::write` to a user's document, ever."*
    /// That primitive resolves symlinks before renaming — the M1 review's bug —
    /// which matters far more now that autosave runs it every 800 ms.
    ///
    /// - Returns: a receipt naming the **canonical** path the bytes landed at,
    ///   which is not `path` when `path` is a symlink.
    @discardableResult
    public static func save(_ source: String, to path: String) throws -> WriteReceipt {
        try write(path: path, source: source, index: nil, action: .toggle)
    }

    /// Toggle a task in a buffer, returning the edited buffer. **Writes
    /// nothing.**
    ///
    /// `2026-08-24-editing-pane-and-autosave`: *"Checkbox clicks while dirty
    /// apply to the buffer, not the file. The core's byte-range toggle runs
    /// against the buffer's bytes and the result re-enters the buffer, which
    /// autosave then persists."* The toggle is the core's, not a byte poked in
    /// Swift, so a dirty tab and a clean tab cannot disagree about what a
    /// checkbox click means.
    public static func toggleInBuffer(
        _ source: String, index: Int, action: ToggleAction
    ) throws -> WriteReceipt {
        try write(path: nil, source: source, index: index, action: action)
    }

    private static func write(
        path: String?, source: String, index: Int?, action: ToggleAction
    ) throws -> WriteReceipt {
        let json = try string(function: "mark_write_json") {
            withOptionalCString(path) { pathPointer in
                source.withCString { sourcePointer in
                    mark_write_json(
                        pathPointer,
                        sourcePointer,
                        index.map { size_t($0) } ?? MARK_NO_TASK,
                        action.rawValue
                    )
                }
            }
        }
        return try decode(WriteReceipt.self, from: json, function: "mark_write_json")
    }

    // MARK: - Plumbing

    /// The single place a `char *` from the core is turned into a `String`.
    private static func string(
        function: String,
        _ call: () -> UnsafeMutablePointer<CChar>?
    ) throws -> String {
        guard let owned = CoreString(call()) else {
            throw CoreError(function: function, detail: lastError())
        }
        return owned.value
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from json: String,
        function: String
    ) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(json.utf8))
        } catch {
            throw CoreError(
                function: function,
                detail: "response was not the expected JSON: \(error)"
            )
        }
    }

    /// `withCString` for an optional: `nil` in, `NULL` out.
    ///
    /// The ABI treats a null string as "the default", so this is the one place
    /// that translation happens rather than at every call site.
    private static func withOptionalCString<T>(
        _ value: String?, _ body: (UnsafePointer<CChar>?) -> T
    ) -> T {
        guard let value else { return body(nil) }
        return value.withCString { body($0) }
    }

    /// The last error recorded **on this thread**, or `nil`.
    ///
    /// Public because the leak test needs a second `char *`-returning entry
    /// point that is allowed to return `NULL`.
    public static func lastError() -> String? {
        CoreString(mark_last_error())?.value
    }
}

/// A `char *` owned by the core, freed exactly once, in `deinit`.
///
/// This type is the whole of ADR-1's "every pointer the core returns is freed
/// with `mark_free`" enforcement. It is a `final class` rather than a struct
/// with a `deinit` because only a class has one; the pointer is `let` and
/// private so no code path can free it twice or forget to free it once.
public final class CoreString {
    private let pointer: UnsafeMutablePointer<CChar>

    /// Takes ownership of `pointer`. `nil` in means `nil` out — the core's
    /// failure sentinel is not an error to be freed.
    public init?(_ pointer: UnsafeMutablePointer<CChar>?) {
        guard let pointer else { return nil }
        self.pointer = pointer
    }

    /// A Swift copy of the bytes. The core's allocation stays owned by `self`.
    public var value: String { String(cString: pointer) }

    deinit { mark_free(pointer) }
}

/// A failure reported across the C ABI.
///
/// The core cannot unwind (ADR-1), so it signals failure with `NULL` or `-1`
/// and leaves a message in `mark_last_error()`. This is that pair, given a
/// type, so callers get a domain-level error rather than an unexplained `nil`.
public struct CoreError: Error, CustomStringConvertible, Equatable, Sendable {
    /// The `mark_*` function that failed.
    public let function: String
    /// `mark_last_error()`, when the core left one.
    public let detail: String?

    public init(function: String, detail: String?) {
        self.function = function
        self.detail = detail
    }

    public var description: String {
        guard let detail else { return "\(function) failed (no message from the core)" }
        return "\(function) failed: \(detail)"
    }
}

// MARK: - Decoded shapes

/// ADR-2's edit script: the JSON the shell applies, plus the counters the app
/// logs.
///
/// `kept + deleted + replaced == oldBlocks` and
/// `kept + inserted + replaced == newBlocks` always hold; the core asserts it.
/// How a path differs from `HEAD` — `core::git::Status`.
public enum GitStatus: String, Decodable, Equatable, Sendable {
    case modified, added, deleted, renamed, copied
    case typechange, unmerged, untracked

    /// Whether a diff of this path's content is meaningful. False for a file
    /// that is not there to diff, and for an unresolved merge.
    public var hasContent: Bool { self != .deleted && self != .unmerged }

    /// What the row says when there are no numbers to show.
    public var label: String {
        switch self {
        case .modified: return "modified"
        case .added: return "added"
        case .deleted: return "deleted"
        case .renamed: return "renamed"
        case .copied: return "copied"
        case .typechange: return "type changed"
        case .unmerged: return "unmerged"
        case .untracked: return "new"
        }
    }
}

/// One path that differs from `HEAD` — `core::git::Change`.
public struct GitChange: Decodable, Equatable, Sendable {
    /// **Repository-relative**, as git reports it. Join it onto
    /// ``GitRepo/root`` to get something openable.
    public let path: String
    public let status: GitStatus
    public let from: String?

    /// `nil` means **not countable**, never zero. `git diff --numstat` prints
    /// `-` `-` for a binary file, and an untracked file's additions are
    /// deliberately left for the caller to count on its own queue. A `+0 −0`
    /// badge on a changed binary would be a lie about a file that did change.
    public let added: Int?
    public let removed: Int?

    public init(path: String, status: GitStatus, from: String? = nil, added: Int?, removed: Int?) {
        self.path = path
        self.status = status
        self.from = from
        self.added = added
        self.removed = removed
    }
}

/// A repository and the paths a caller needs from it — `core::git::Repo`.
public struct GitRepo: Decodable, Equatable, Sendable {
    public let root: String
    public let gitDir: String
    /// The two files ``2026-08-28-git-badges-ride-the-sidebar-poll``'s gate
    /// `stat`s. Resolved by the core through `rev-parse --git-path`, because a
    /// linked worktree, a shared index, and `$GIT_INDEX_FILE` each put them
    /// somewhere that is *not* `gitDir` plus a name.
    public let indexPath: String
    public let headPath: String
    /// Short oid, or `nil` in a repository with no commits.
    public let head: String?
    /// Branch name, `"HEAD"` when detached.
    public let branch: String?
}

/// What git says about a path — `core::git::Report`.
public struct GitReport: Decodable, Equatable, Sendable {
    /// `nil` for a path outside any repository **and** for a machine with no
    /// usable git. Not an error, and the two are indistinguishable on purpose:
    /// the row draws unbadged either way.
    public let repo: GitRepo?
    public let changes: [GitChange]

    public init(repo: GitRepo?, changes: [GitChange]) {
        self.repo = repo
        self.changes = changes
    }

    /// Whether git had anything to say about this path at all.
    public var isRepository: Bool { repo != nil }
}

/// `HEAD`'s bytes for one file.
public struct GitBase: Decodable, Equatable, Sendable {
    public let repo: String?
    public let head: String?
    public let branch: String?
    /// False for a file `HEAD` does not have, and for a blob that is binary or
    /// not UTF-8 — all of which mean "nothing here we can diff".
    public let tracked: Bool
    public let base: String?
}

/// What happened to a run of lines — `core::lines::HunkKind`.
public enum LineHunkKind: String, Decodable, Equatable, Sendable {
    case added, removed, changed
}

/// Zero-based, half-open line range — `core::lines::Hunk`.
///
/// **Zero-based**, like every other offset the core reports. A gutter printing
/// "42" adds one at the point of display, which is the only place that
/// conversion belongs.
public struct LineHunk: Decodable, Equatable, Sendable {
    public struct Span: Decodable, Equatable, Sendable {
        public let start: Int
        public let end: Int
        public var isEmpty: Bool { end <= start }
        public var count: Int { max(0, end - start) }
    }

    public let old: Span
    public let new: Span
    /// UTF-8 byte range of `new` in the new document. The editor converts it
    /// once through ``SourceOffsets/utf16(of:in:)`` rather than counting
    /// newlines again in Swift.
    public let newBytes: Span
    public let kind: LineHunkKind
}

/// A line diff — `core::lines::LineDiff`.
public struct LineDiff: Decodable, Equatable, Sendable {
    public let hunks: [LineHunk]
    public let added: Int
    public let removed: Int
    /// The changed region was past the core's table budget, so `hunks` is one
    /// span covering everything that is not common prefix or suffix. The counts
    /// are still exact.
    public let coarse: Bool
}

/// Both diff granularities plus the merged diff document, from one call.
public struct DiffDetail: Decodable, Equatable, Sendable {
    /// The **line** diff, for the editor's change gutter.
    public let lines: LineDiff
    /// The merged diff document's block HTML, for the preview.
    public let document: String
    public let diffAdded: Int
    public let diffRemoved: Int
    public let diffChanged: Int

    /// Nothing to show: the caller leaves the ordinary render up rather than
    /// swapping to a diff view that says nothing.
    public var isEmpty: Bool { diffAdded == 0 && diffRemoved == 0 && diffChanged == 0 }
}

public struct EditScript: Sendable, Equatable {

    /// The whole script, exactly as the core emitted it. Handed to `shell.js`
    /// as an argument, never interpolated into a script body.
    public let json: String

    public let oldBlocks: Int
    public let newBlocks: Int
    public let kept: Int
    public let inserted: Int
    public let deleted: Int
    public let replaced: Int

    /// The edit distance exceeded the core's search budget and the differing
    /// middle was replaced wholesale. Still correct, no longer minimal — and
    /// worth a log line, because a patch that is *always* coarse means the diff
    /// is not earning its keep.
    public let coarse: Bool

    /// Nothing changed: the shell can skip the patch entirely.
    public var isNoop: Bool { inserted == 0 && deleted == 0 && replaced == 0 }

    /// Blocks the patch will add, remove, or swap.
    public var touchedBlocks: Int { inserted + deleted + replaced }

    struct Counters: Decodable {
        let oldBlocks: Int
        let newBlocks: Int
        let kept: Int
        let inserted: Int
        let deleted: Int
        let replaced: Int
        let coarse: Bool

        private enum CodingKeys: String, CodingKey {
            case kept, inserted, deleted, replaced, coarse
            case oldBlocks = "old_blocks"
            case newBlocks = "new_blocks"
        }
    }

    init(json: String, counters: Counters) {
        self.json = json
        self.oldBlocks = counters.oldBlocks
        self.newBlocks = counters.newBlocks
        self.kept = counters.kept
        self.inserted = counters.inserted
        self.deleted = counters.deleted
        self.replaced = counters.replaced
        self.coarse = counters.coarse
    }
}

/// The state of one task marker — the single byte between its brackets.
///
/// The Swift half of `core::tasks::State`
/// (`2026-08-27-five-task-states`). The raw values are the JSON and
/// `data-mk-state` spellings, so this decodes straight out of
/// `mark_tasks_json` and compares straight against what the page reports.
public enum TaskState: String, Codable, Equatable, Sendable, CaseIterable {
    case open
    case inProgress = "in-progress"
    case done
    case cancelled
    case blocked

    /// Still to do: open, in progress, or blocked. The badge's numerator.
    public var isOutstanding: Bool {
        self == .open || self == .inProgress || self == .blocked
    }

    /// Finished with, one way or the other — done **or** cancelled. This is
    /// what ``Task/checked`` reports, and it is deliberately not the same
    /// question as "is it ticked".
    public var isTerminal: Bool { self == .done || self == .cancelled }

    /// The spelling for VoiceOver and for a log line, where a hyphen would be
    /// read out.
    public var spoken: String { self == .inProgress ? "in progress" : rawValue }

    /// The state's name where a person reads it — a group heading in the
    /// sidebar's Tasks tab, a summary line. Sentence case, so a column of five
    /// of them reads as prose rather than as Title Case Labels.
    public var title: String {
        switch self {
        case .open: return "Open"
        case .inProgress: return "In progress"
        case .done: return "Done"
        case .cancelled: return "Cancelled"
        case .blocked: return "Blocked"
        }
    }

    /// The marker as it is written in the document — the Swift side of
    /// `core::tasks::State::byte` (`2026-08-27-five-task-states`), brackets
    /// included.
    ///
    /// Shown rather than a drawn box or an SF Symbol: it is what the file says,
    /// what `mark tasks` prints, and what the reader would type. A sidebar that
    /// invented a sixth vocabulary for the same five bytes would be one more
    /// thing to learn.
    public var marker: String {
        switch self {
        case .open: return "[ ]"
        case .inProgress: return "[/]"
        case .done: return "[x]"
        case .cancelled: return "[-]"
        case .blocked: return "[?]"
        }
    }

    /// The five states in the order the Tasks tab groups them: outstanding
    /// first, in marker order, then the two that are finished with.
    ///
    /// Deliberately not ``allCases``, which is marker order and would put done
    /// between in-progress and blocked. The pane is read to answer "what is
    /// left", so what is left comes first
    /// (`2026-08-28-tabbed-document-pane`).
    public static let groupingOrder: [TaskState] = [
        .open, .inProgress, .blocked, .done, .cancelled,
    ]

    /// The action that puts a marker into this state.
    ///
    /// Every state is reachable, which is what lets the context menu and
    /// ⌥-click go down the same ``TaskToggle`` path a plain click takes rather
    /// than inventing a second write.
    public var action: MarkCore.ToggleAction {
        switch self {
        case .open: return .off
        case .inProgress: return .inProgress
        case .done: return .on
        case .cancelled: return .cancel
        case .blocked: return .block
        }
    }

    /// What a plain left-click asks for, from the state the page is showing.
    ///
    /// `2026-08-27-five-task-states`: *"a click still toggles open↔done […]
    /// toggling a marker that is in-progress, blocked or cancelled means 'tick
    /// this box', so it becomes done."* The page derives the same thing for
    /// itself — with five states the browser can no longer compute it during
    /// pre-click activation — and this is the Swift copy of that rule, which
    /// `ScriptBridgeTests` pins to the JavaScript one.
    public var toggled: TaskState { self == .done ? .open : .done }

    /// `mark_toggle`'s integer return: `0` open, `1` done, `2` in progress,
    /// `3` cancelled, `4` blocked.
    ///
    /// Done is `1` and not `2` deliberately — the ADR keeps it where it was so
    /// that an existing caller testing `result == 1` still reads "done" — so
    /// this is a table rather than `TaskState.allCases[Int(code)]`.
    public init?(code: Int32) {
        switch code {
        case 0: self = .open
        case 1: self = .done
        case 2: self = .inProgress
        case 3: self = .cancelled
        case 4: self = .blocked
        default: return nil
        }
    }
}

/// One `@tag` or `@key(value)` carried in a task's own text.
///
/// `name` excludes the `@`, matching the core, so a tag reads the same in a
/// filter as in a log line. `2026-08-27-inline-task-metadata`: **no tag ever
/// affects a count.**
public struct TaskTag: Decodable, Equatable, Sendable {
    public let name: String
    public let value: String?

    public init(name: String, value: String? = nil) {
        self.name = name
        self.value = value
    }
}

/// One task marker: `{index, state, checked, start, end, line, text, label,
/// tags, due, start_date, done, priority}`.
public struct Task: Decodable, Equatable, Sendable {
    public let index: Int
    /// The state the marker byte carries.
    public let state: TaskState
    /// **"The state is terminal"** — true for done *and* cancelled. Retained
    /// under that definition by `2026-08-27-five-task-states` so that every
    /// existing consumer asking "is this still outstanding?" keeps getting the
    /// right answer. Read ``state`` when the difference matters.
    public let checked: Bool
    public let start: Int
    public let end: Int
    public let line: Int
    /// The full flattened item text, metadata tokens included. Unchanged in
    /// meaning; ``label`` is the stripped one.
    public let text: String
    /// ``text`` with the recognised `@tag` / `!!!` tokens removed and
    /// whitespace collapsed — what a human-facing list shows.
    public let label: String
    public let tags: [TaskTag]
    /// `@due(YYYY-MM-DD)`, validated as a date by the core. A `@due(friday)`
    /// is a ``tags`` entry instead: not a date, not an error.
    public let due: String?
    /// `@start(YYYY-MM-DD)`. Named `start_date` on the wire because `start` is
    /// already this object's marker byte offset.
    public let startDate: String?
    /// `@done(YYYY-MM-DD)` as written in the text — independent of ``state``.
    public let done: String?
    /// `!` = 1, `!!` = 2, `!!!` = 3, absent = 0.
    public let priority: Int

    private enum CodingKeys: String, CodingKey {
        case index, state, checked, start, end, line, text, label, tags, due, done, priority
        case startDate = "start_date"
    }
}

/// One top-level block: its identity, its kind, and its byte range.
///
/// The byte range is the point. Everything else the editor could get from its
/// own text; where a heading *ends* and the next block begins is the core's
/// answer, and taking it from anywhere else means a second markdown parser.
public struct Block: Decodable, Equatable, Sendable {
    /// The `data-blk` value: content hash plus ordinal, never positional.
    public let id: String
    /// `heading`, `paragraph`, `code-block`, `list`, `block-quote`, `table`,
    /// `thematic-break`, `html`, `footnote-definition`, `definition-list`,
    /// `other`.
    public let kind: String
    /// Heading level, for `heading`.
    public let level: Int?
    /// Fence info string, for `code-block`.
    public let language: String?
    /// Byte offsets into the source the blocks were parsed from — **not**
    /// UTF-16 offsets, which is what `NSTextStorage` wants. ``EditorPane``
    /// converts.
    public let start: Int
    public let end: Int
}

/// One parse, answering both questions the editor asks of its buffer.
public struct DocumentStructure: Decodable, Equatable, Sendable {
    public let tasks: [Task]
    public let blocks: [Block]
}

/// What `mark_write_json` did.
public struct WriteReceipt: Decodable, Equatable, Sendable {
    /// Whether bytes reached the disk. False for a buffer-only toggle.
    public let written: Bool
    public let bytes: Int?
    /// The **canonical** path written, with symlinks resolved. `nil` when
    /// nothing was written.
    public let path: String?
    /// The document after a toggle. `nil` when this was a plain save.
    public let source: String?
    public let index: Int?
    /// The state the marker is in after the write.
    public let state: TaskState?
    /// "The state is terminal" — true for done *and* cancelled, exactly as on
    /// ``Task/checked``.
    public let checked: Bool?
    /// The single byte the toggle changed.
    public let offset: Int?
    public let text: String?
}

/// One heading: `{level, text, anchor, start, end, line, block}`.
public struct Heading: Decodable, Equatable, Sendable {
    public let level: Int
    public let text: String
    public let anchor: String
    public let start: Int
    public let end: Int
    public let line: Int
    public let block: String
}

/// One document pointing at another: `{path, line, offset, text, heading, …}`.
public struct Backlink: Decodable, Equatable, Sendable, Identifiable {
    public let path: String
    public let line: Int
    /// Byte offset of the reference — what the preview scrolls to.
    public let offset: Int
    /// The link's own text: what the *other* document calls this one, which is
    /// more useful in a list than repeating the filename you are looking at.
    public let text: String
    /// The `>`-joined headings the reference sits under.
    public let heading: String
    /// A `#fragment`, when the reference points at a section rather than the
    /// whole document.
    public let fragment: String?
    /// `link` or `image`.
    public let kind: Reference.Kind

    public var id: String { "\(path):\(offset)" }
}

/// How long a document is: `{words, characters, lines, reading_minutes, …}`.
public struct WordCount: Decodable, Equatable, Sendable {
    public let words: Int
    public let characters: Int
    public let charactersNoSpaces: Int
    public let lines: Int
    public let blocks: Int
    public let headings: Int
    public let codeBytes: Int
    /// Rounded up, and never zero for a document with any prose in it — "0 min"
    /// reads as a failure rather than as "quick".
    public let readingMinutes: Int

    private enum CodingKeys: String, CodingKey {
        case words, characters, lines, blocks, headings
        case charactersNoSpaces = "characters_no_spaces"
        case codeBytes = "code_bytes"
        case readingMinutes = "reading_minutes"
    }

    /// The one-line form the editor's status bar shows.
    ///
    /// Words first because it is what people look for, and the reading time
    /// last because it is the derived one. Grouping separators on the counts,
    /// since a five-figure word count with no comma is unreadable at 11pt.
    public var summary: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        func number(_ value: Int) -> String {
            formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        }
        var parts = [
            words == 1 ? "1 word" : "\(number(words)) words",
            "\(number(characters)) characters",
            lines == 1 ? "1 line" : "\(number(lines)) lines",
        ]
        if readingMinutes > 0 { parts.append("~\(readingMinutes) min read") }
        return parts.joined(separator: "  ·  ")
    }
}

/// What a search found.
public struct SearchResults: Decodable, Equatable, Sendable {
    public let matches: [SearchMatch]
    /// The limit was reached and there are more.
    ///
    /// Reported by the core rather than inferred from `matches.count == limit`,
    /// which is ambiguous when a tree holds exactly that many — and the window
    /// puts "showing the first 200" in front of the reader.
    public let truncated: Bool
    /// Files opened. The number that says whether a slow search is the walk or
    /// the pattern.
    public let files: Int
}

/// One hit: `{path, line, offset, column, heading, anchor?, text}`.
public struct SearchMatch: Decodable, Equatable, Sendable, Identifiable {
    public let path: String
    /// 1-based, as every editor counts them.
    public let line: Int
    /// Byte offset in the file — what the preview scrolls to. A line number
    /// alone would not be enough.
    public let offset: Int
    public let column: Span
    /// Enclosing headings, `>`-joined. Empty above the first heading.
    public let heading: String
    public let anchor: String?
    /// The whole line the hit sits on.
    public let text: String

    /// Stable within one result set: two hits never share a file *and* an
    /// offset.
    public var id: String { "\(path):\(offset)" }

    /// The hit's span within ``text``, so the row can embolden it without
    /// re-running a regex that might disagree with the one that found it.
    public struct Span: Decodable, Equatable, Sendable {
        public let start: Int
        public let end: Int
    }

    /// ``text`` with the matched range picked out, ready for a table cell.
    @MainActor
    public func styled(font: NSFont, highlight: NSColor) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: text, attributes: [.font: font])
        // The core reports UTF-8 byte offsets and `NSAttributedString` wants
        // UTF-16 ones. Converting through `String.Index` is what keeps an
        // emoji, or any non-ASCII text, from shifting the highlight.
        let utf8 = Array(text.utf8)
        guard column.start >= 0, column.end <= utf8.count, column.start < column.end,
            let from = String.Index(
                text.utf8.index(text.utf8.startIndex, offsetBy: column.start), within: text),
            let to = String.Index(
                text.utf8.index(text.utf8.startIndex, offsetBy: column.end), within: text)
        else { return attributed }

        let range = NSRange(from..<to, in: text)
        attributed.addAttributes(
            [
                .backgroundColor: highlight,
                .font: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask),
            ], range: range)
        return attributed
    }
}

/// One link or image: `{kind, span, dest, text, title, target, path?, exists?}`.
public struct Reference: Decodable, Equatable, Sendable {
    /// `link` or `image`.
    public let kind: Kind
    public let span: Span
    /// The destination exactly as the document wrote it, still percent-encoded.
    public let dest: String
    /// The link text, or the image's alt.
    public let text: String
    public let title: String
    public let target: Target
    /// The resolved absolute path, for a local destination that was checked.
    public let path: String?
    /// Whether the target is there. `nil` is **not checked** — an external URL,
    /// a fragment, or a call that passed no base — and reading it as `false`
    /// is how a working link gets reported broken.
    public let exists: Bool?

    public enum Kind: String, Decodable, Sendable {
        case link
        case image
    }

    /// The construct's byte span in the source, brackets included.
    public struct Span: Decodable, Equatable, Sendable {
        public let start: Int
        public let end: Int
    }

    /// The core's tagged `Destination`. Only the discriminant and the local
    /// path are decoded: nothing in the app needs the parsed fragment, and a
    /// model that decodes fields nobody reads is a model that breaks when the
    /// core adds one.
    public struct Target: Decodable, Equatable, Sendable {
        public let kind: Kind
        /// Present for `.local` only.
        public let path: String?

        public enum Kind: String, Decodable, Sendable {
            case fragment
            case external
            case local
        }
    }
}

/// One directory entry: `{path, name, is_dir, depth, title?, tasks?}`.
public struct TreeEntry: Decodable, Equatable, Sendable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let depth: Int
    public let title: String?
    public let tasks: TaskCounts?

    private enum CodingKeys: String, CodingKey {
        case path, name, depth, title, tasks
        case isDirectory = "is_dir"
    }
}

/// Per-state task counts for a markdown file — `core::tasks::Counts`.
///
/// ``outstanding`` and ``active`` are computed here rather than at the call
/// sites for the reason the core gives for making them methods: the five
/// places in the app that ask "how many are left?" must not each invent their
/// own arithmetic. `2026-08-27-five-task-states` fixes that arithmetic —
/// outstanding is open + in-progress + blocked, and **cancelled is the only
/// state that leaves the denominator.**
public struct TaskCounts: Decodable, Equatable, Sendable {
    public let open: Int
    public let inProgress: Int
    public let done: Int
    public let cancelled: Int
    public let blocked: Int
    public let total: Int

    /// Still to do: open + in progress + blocked. The badge's numerator.
    public var outstanding: Int { open + inProgress + blocked }

    /// The badge's denominator. A dropped item stops sitting in it for ever,
    /// which is what stopped the counts lying.
    public var active: Int { total - cancelled }

    public init(
        open: Int = 0, inProgress: Int = 0, done: Int = 0, cancelled: Int = 0,
        blocked: Int = 0, total: Int
    ) {
        self.open = open
        self.inProgress = inProgress
        self.done = done
        self.cancelled = cancelled
        self.blocked = blocked
        self.total = total
    }

    /// No tasks at all — what a pane shows for a document that has none, and
    /// for no document at all. Both are `0/0`; the two are told apart by
    /// whether there is a URL, not by the counts.
    public static let empty = TaskCounts(total: 0)

    /// Count a document's tasks. **The one place in the app that does.**
    ///
    /// `mark_tree_json` hands these counts over already computed, but
    /// `mark_tasks_json` answers with the tasks themselves — so the tab badge,
    /// the sidebar badge, and the dirty-buffer paths all arrive here, and all
    /// get the same answer as the core would have given.
    public init(_ tasks: [Task]) {
        var open = 0
        var inProgress = 0
        var done = 0
        var cancelled = 0
        var blocked = 0
        for task in tasks {
            switch task.state {
            case .open: open += 1
            case .inProgress: inProgress += 1
            case .done: done += 1
            case .cancelled: cancelled += 1
            case .blocked: blocked += 1
            }
        }
        self.init(
            open: open, inProgress: inProgress, done: done, cancelled: cancelled,
            blocked: blocked, total: tasks.count)
    }

    private enum CodingKeys: String, CodingKey {
        case open, done, cancelled, blocked, total
        case inProgress = "in_progress"
    }
}


// MARK: - Themes

/// `mark_theme_json(nil, MARK_THEME_LIST)`.
public struct ThemeCatalog: Decodable, Equatable, Sendable {
    public let themes: [ThemeSummary]
    /// The theme used when nothing else is chosen.
    public let `default`: String
    /// `~/.config/mark/themes`, for the menu item that reveals it in Finder.
    public let dir: String?
    /// User files that would not parse, with the reason. Reported rather than
    /// dropped: "my theme vanished" is the failure this layer exists to avoid.
    public let problems: [String]
}

/// One line of the theme menu.
public struct ThemeSummary: Decodable, Equatable, Sendable, Identifiable {
    public let name: String
    public let title: String
    public let kind: ThemeKind
    public let pair: String?
    public let author: String?
    /// Built in, or a file in `~/.config/mark/themes`.
    public let source: ThemeSource

    public var id: String { name }
    /// Whether this theme has a counterpart for the other appearance.
    public var isPaired: Bool { pair != nil }
}

/// Where a theme came from: `{"kind":"builtin"}` or
/// `{"kind":"user","path":"…"}`.
///
/// Carried into the menu as a tooltip, because "why is my edit not showing up"
/// is answered by the path a theme was actually loaded from — a user file
/// shadows a built-in of the same name, and nothing else in the list says so.
public enum ThemeSource: Decodable, Equatable, Sendable {
    case builtin
    case user(path: String)

    private enum CodingKeys: String, CodingKey {
        case kind, path
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "user":
            self = .user(path: try container.decode(String.self, forKey: .path))
        default:
            self = .builtin
        }
    }
}

public enum ThemeKind: String, Decodable, Sendable {
    case light
    case dark
}

/// A resolved light/dark pair: what the page needs, and what a menu shows.
public struct ResolvedTheme: Decodable, Equatable, Sendable {
    public let name: String
    public let kind: ThemeKind
    /// `false` when one theme is used for **both** appearances, which is what
    /// an unpaired theme like `dracula` means.
    public let paired: Bool
    public let light: ThemeHalf
    public let dark: ThemeHalf

    /// Custom properties for both appearances, the dark half behind
    /// `@media (prefers-color-scheme: dark)`. Injecting this is the *whole* of
    /// applying a theme to a page: no re-render, and an appearance switch after
    /// it costs nothing at all.
    public let css: String

    /// Identity of the scope → slot map, which is the only part of a theme the
    /// rendered HTML depends on. Equal stamps across a theme change mean the
    /// document does not need re-rendering.
    public let codeStamp: String

    /// The colour behind the web view for each appearance, so the window can be
    /// painted before the page has drawn anything.
    public var backgrounds: (light: NSColor?, dark: NSColor?) {
        (light.color(of: "background"), dark.color(of: "background"))
    }
}

public struct ThemeHalf: Decodable, Equatable, Sendable {
    public let name: String
    public let title: String
    public let kind: ThemeKind
    public let author: String?
    /// `base00` … `base0F`, as `#rrggbb`.
    public let palette: [String: String]
    /// Chrome key → the slot it takes and the colour that slot holds.
    public let document: [String: Chrome]

    public struct Chrome: Decodable, Equatable, Sendable {
        public let slot: String
        public let color: String?
    }

    /// One chrome colour, as AppKit sees it.
    public func color(of key: String) -> NSColor? {
        document[key]?.color.flatMap(NSColor.init(hex:))
    }
}

extension NSColor {
    /// `#rrggbb` → colour, in the sRGB space the CSS means.
    public convenience init?(hex: String) {
        let text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
