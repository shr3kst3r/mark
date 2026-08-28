import Foundation

/// `+12 −3` — one file's changed lines against git `HEAD`.
///
/// `added` and `removed` are optional together, and `nil` means **not
/// countable**, never zero. `git diff --numstat` prints `-` `-` for a binary
/// file; a `logo.png` badged `+0 −0` would be a lie about a file that did
/// change, so such a row shows its status word instead.
public struct GitBadge: Equatable, Sendable {
    public let status: GitStatus
    public let added: Int?
    public let removed: Int?

    public init(status: GitStatus, added: Int?, removed: Int?) {
        self.status = status
        self.added = added
        self.removed = removed
    }

    /// What the sidebar draws, or `nil` for a row with nothing to say.
    ///
    /// A clean file has no badge at all, on the same grounds
    /// ``TaskBadge/label`` suppresses `0/0`: a marker on every unchanged row is
    /// noise, not information.
    public var label: String? {
        switch (added, removed) {
        case let (added?, removed?):
            // U+2212 MINUS SIGN, not a hyphen: the two numbers are drawn in a
            // monospaced-digit font and a hyphen sits too high and too short
            // next to the `+`.
            return "+\(added) \u{2212}\(removed)"
        default:
            return status.label
        }
    }

    /// Whether this row changed at all. Every status this service reports has,
    /// which is why it is a property of the *presence* of a badge rather than
    /// of its contents.
    public var isDirty: Bool { true }
}

/// Per-file git badges, refreshed on the sidebar's own poll.
///
/// `2026-08-28-git-badges-ride-the-sidebar-poll` decides the shape, and it is
/// **not** ``TaskBadgeService``'s shape even though the two draw next to each
/// other. The cost models are inverted:
///
/// * A task badge costs ~0.34 ms **per file**, so it is requested per visible
///   row and never for a row nobody can see.
/// * A git badge costs ~12 ms **per repository**, and one query answers every
///   row in it. Asking per row would be 6 ms of process startup each, for an
///   answer we already have.
///
/// So this service is keyed by repository, not by file:
///
/// 1. ``request(for:)`` names the repository owning a row. Discovery is cached,
///    including the negative answer — a notes folder that is not in a
///    repository must not pay a `git` process per redraw.
/// 2. Each repository's `index` and `HEAD` are `stat`ed on every poll. Two
///    syscalls, the same order as the poll's existing per-directory `stat`.
/// 3. `git` runs **only** when a stamp moved. That is the constraint the ADR
///    names as the one that regresses silently, and
///    `SidebarPollTests.quietPollRunsNoGit` asserts it against a counting fake.
///
/// One deliberate gap, inherited rather than invented: an in-place edit to a
/// tracked file moves neither `index` nor `HEAD`, so its badge goes stale until
/// ⌘R, until the document watcher reports it, or until something stages a
/// change. `2026-08-27-sidebar-polls-listed-directories` already accepted
/// exactly that for task badges, so this adds no new class of staleness to the
/// product.
@MainActor
public final class GitBadgeService {

    /// Badges landed for these files. The sidebar redraws those rows.
    public var onBadges: (([URL]) -> Void)?

    /// The unsaved bytes for a file, when a tab is holding some.
    ///
    /// The same hook ``TaskBadgeService/dirtySource`` uses, for the same reason:
    /// a badge must not describe a version the reader is not looking at. Here it
    /// matters more, not less — the whole claim of a git badge is "this is how
    /// far the file is from what is committed", and answering that from disk
    /// while the reader has unsaved edits is answering a different question.
    public var dirtySource: ((URL) -> String?)?

    /// What actually runs git. Injectable so tests can count invocations, which
    /// is the only way to assert "a quiet poll runs no git process".
    public var query: GitQuerying

    private struct Cached {
        var repo: GitRepo
        /// The repository root **in the spelling the app uses**, which is not
        /// always `repo.root`.
        ///
        /// `git rev-parse --show-toplevel` answers with symlinks resolved, and
        /// `core/src/tree.rs` deliberately does *not* resolve them — "a
        /// symlinked notes directory keeps the name the user typed". So a
        /// notes folder reached through a symlink gives the app
        /// `/tmp/notes/weekly.md` while git says the root is
        /// `/private/tmp/notes`, and a prefix match between the two fails.
        ///
        /// Resolved once per repository, off the draw path, because
        /// canonicalizing per visible row would be a syscall per row on a tree
        /// research §2.8 measured at 608k files.
        var appRoot: String
        var stamp: GitStamp?
        /// Repository-relative path → badge.
        var badges: [String: GitBadge]
        /// A query failed or timed out. Not retried until ⌘R: otherwise an
        /// unreadable or hung repository is re-queried every two seconds for
        /// the life of the window.
        var quiet: Bool
    }

    /// Repository root → its state. Also holds the *negative* answer, as a
    /// `nil` value under the directory that was asked about.
    private var repos: [String: Cached?] = [:]

    /// Directory path → the repository root that owns it, so the second row in
    /// a folder is a dictionary hit rather than another discovery.
    private var owners: [String: String?] = [:]

    /// Discoveries and queries in flight, so a burst of rows asks once.
    private var inFlight: Set<String> = []

    /// Badges recomputed from a tab's **unsaved** bytes, keyed by absolute path.
    ///
    /// These win over the repository's own answer. ADR-6: *"nothing may read the
    /// file for […] task counts […] on a dirty tab"*, and a git badge is a count
    /// of the same kind. It matters more here than for a task badge, not less:
    /// the whole claim of `+12 −3` is "this is how far the file is from what is
    /// committed", and answering that from disk while the reader has unsaved
    /// edits answers a different question.
    private var dirtyOverrides: [String: GitBadge] = [:]

    /// Line counts for untracked files, keyed by absolute path.
    ///
    /// `2026-08-28-git-badges-ride-the-sidebar-poll` puts these **per visible
    /// row** rather than in the repository-scoped query: `git diff --numstat`
    /// reports nothing for a file with no blob, so the count is ours to make,
    /// and it is a file read. Bounded by the screen, on the badge queue, and
    /// only for paths git has already called untracked — never a speculative
    /// read of a file nobody is looking at.
    private var untrackedCounts: [String: Int] = [:]
    private var untrackedPending: Set<String> = []

    /// `HEAD`'s bytes, keyed by `path` and the oid they came from. The read
    /// costs ~7 ms and cannot change while the oid does not, so a buffer being
    /// retyped pays it once rather than per keystroke.
    private var baseCache: [String: (head: String?, base: String?)] = [:]

    private let work = DispatchQueue(
        label: "dev.mark.sidebar.git", qos: .utility)

    /// Counters for `mark-bench` and for the log line when a pass settles.
    public private(set) var queries = 0
    public private(set) var gateHits = 0
    public private(set) var failures = 0

    public init(query: GitQuerying = CoreGitQuery()) {
        self.query = query
    }

    // MARK: - Reading

    /// The badge for `url`, if it is known. **Never touches the filesystem and
    /// never runs a process** — safe to call from a draw path, which is where it
    /// is called from.
    public func badge(for url: URL) -> GitBadge? {
        if let override = dirtyOverrides[url.path] { return override }
        guard let root = owners[url.deletingLastPathComponent().path] ?? nil,
            let cached = repos[root] ?? nil
        else { return nil }
        // Against the app's own spelling of the root, not git's — see
        // ``Cached/appRoot``.
        guard let relative = Self.relative(of: url, under: cached.appRoot) else { return nil }
        guard let badge = cached.badges[relative] else { return nil }
        // An untracked file's additions arrive separately, per row. Until they
        // do, the row reads "new" rather than a number — which is the honest
        // intermediate state, not a placeholder zero.
        if badge.status == .untracked, badge.added == nil,
            let counted = untrackedCounts[url.path]
        {
            return GitBadge(status: .untracked, added: counted, removed: badge.removed ?? 0)
        }
        return badge
    }

    /// The branch a row's repository is on, for the status line. `nil` when the
    /// row is not in a repository or nothing has been discovered yet.
    public func branch(for url: URL) -> String? {
        guard let root = owners[url.deletingLastPathComponent().path] ?? nil,
            let cached = repos[root] ?? nil
        else { return nil }
        return cached.repo.branch
    }

    // MARK: - Asking

    /// Note that `url`'s directory is on screen, discovering its repository if
    /// this is the first time.
    ///
    /// Cheap and idempotent: after the first call for a directory it is one
    /// dictionary lookup. Called from the row-drawing path like
    /// ``TaskBadgeService/request(_:)``, but what it schedules is per
    /// *repository* rather than per file.
    public func request(for url: URL) {
        let directory = url.deletingLastPathComponent().path
        if owners[directory] != nil {
            // Discovery already happened. Either it found a repository — whose
            // badges are already cached or on their way — or it did not, and
            // this row will never have a badge. Either way the only thing left
            // to schedule is an untracked row's own line count.
            requestUntrackedCount(for: url)
            return
        }
        guard !inFlight.contains(directory) else { return }
        inFlight.insert(directory)

        work.async { [weak self, query] in
            let report = try? query.status(path: directory)
            _Concurrency.Task { @MainActor [weak self] in
                self?.adopt(directory: directory, report: report)
            }
        }
    }

    /// Count an untracked row's lines, if that is what this row is and the
    /// count is not already known.
    ///
    /// Called from the draw path, so the common case is two dictionary lookups
    /// and a return.
    private func requestUntrackedCount(for url: URL) {
        guard let root = owners[url.deletingLastPathComponent().path] ?? nil,
            let cached = repos[root] ?? nil,
            let relative = Self.relative(of: url, under: cached.appRoot),
            cached.badges[relative]?.status == .untracked,
            cached.badges[relative]?.added == nil,
            untrackedCounts[url.path] == nil,
            !untrackedPending.contains(url.path)
        else { return }

        let path = url.path
        untrackedPending.insert(path)
        // The buffer when a tab is holding one, read here on the main actor
        // because that is where it lives.
        let unsaved = dirtySource?(url)
        work.async { [weak self, query] in
            let counted: Int? =
                unsaved.map { (try? query.counts(base: "", new: $0))?.added ?? 0 }
                ?? query.lineCount(path: path)
            _Concurrency.Task { @MainActor [weak self] in
                guard let self else { return }
                self.untrackedPending.remove(path)
                guard let counted else { return }
                guard self.untrackedCounts[path] != counted else { return }
                self.untrackedCounts[path] = counted
                self.onBadges?([url])
            }
        }
    }

    /// One poll tick: `stat` each known repository's gate and re-query only the
    /// ones that moved.
    ///
    /// Returns the repositories it decided to re-query, which is what the log
    /// line reports and what the tests assert on.
    @discardableResult
    public func poll() -> [String] {
        var stale: [String] = []
        for (root, entry) in repos {
            guard let cached = entry, !cached.quiet else { continue }
            let stamp = query.stamp(indexPath: cached.repo.indexPath, headPath: cached.repo.headPath)
            if stamp == cached.stamp {
                gateHits += 1
                continue
            }
            stale.append(root)
        }
        for root in stale { refresh(root: root) }
        return stale
    }

    /// Re-query one repository, whatever its gate says. ⌘R, and the document
    /// watcher's report for a file inside it.
    public func refresh(root: String) {
        guard !inFlight.contains(root) else { return }
        inFlight.insert(root)
        // A repository that had gone quiet gets another chance on an explicit
        // refresh — that is what ⌘R is for.
        if var cached = repos[root] ?? nil {
            cached.quiet = false
            repos[root] = cached
        }
        work.async { [weak self, query] in
            let report = try? query.status(path: root)
            _Concurrency.Task { @MainActor [weak self] in
                self?.adopt(directory: root, report: report)
            }
        }
    }

    /// The repository owning `url`, if one is known.
    public func repositoryRoot(for url: URL) -> String? {
        owners[url.deletingLastPathComponent().path] ?? nil
    }

    /// Re-query whichever repository owns `url`. What the file watcher calls,
    /// and what closes the in-place-edit gap for the file that is open.
    public func invalidate(_ url: URL) {
        untrackedCounts.removeValue(forKey: url.path)
        requestUntrackedCount(for: url)
        recountDirty(url)
        guard let root = repositoryRoot(for: url) else { return }
        refresh(root: root)
    }

    /// Recount `url` against `HEAD` from the tab's unsaved bytes, or drop the
    /// override when there are none.
    ///
    /// Bounded by the number of dirty tabs, which is a handful — so this is the
    /// one per-file `git` read in a service whose whole design is per
    /// repository, and it is affordable for exactly that reason.
    public func recountDirty(_ url: URL) {
        guard let unsaved = dirtySource?(url) else {
            if dirtyOverrides.removeValue(forKey: url.path) != nil {
                onBadges?([url])
            }
            return
        }
        let path = url.path
        let head = (repos[repositoryRoot(for: url) ?? ""] ?? nil)?.repo.head
        if let cached = baseCache[path], cached.head == head {
            adoptDirty(url, base: cached.base, unsaved: unsaved)
            return
        }
        work.async { [weak self, query] in
            let base = try? query.base(path: path)
            _Concurrency.Task { @MainActor [weak self] in
                guard let self else { return }
                self.baseCache[path] = (head: head, base: base?.base)
                self.adoptDirty(url, base: base?.base, unsaved: unsaved)
            }
        }
    }

    private func adoptDirty(_ url: URL, base: String?, unsaved: String) {
        let path = url.path
        // No committed version: every line of the buffer is an addition, which
        // is the same rule an untracked file follows.
        let previousStatus = badge(for: url)?.status
        let status: GitStatus = base == nil ? .untracked : (previousStatus ?? .modified)
        work.async { [weak self, query] in
            let counted = try? query.counts(base: base ?? "", new: unsaved)
            _Concurrency.Task { @MainActor [weak self] in
                guard let self, let counted else { return }
                let badge = GitBadge(
                    status: status, added: counted.added, removed: counted.removed)
                guard self.dirtyOverrides[path] != badge else { return }
                self.dirtyOverrides[path] = badge
                self.onBadges?([url])
            }
        }
    }

    /// Forget everything, including the negative answers. The sidebar's ⌘R.
    public func invalidateAll() {
        repos.removeAll()
        owners.removeAll()
        inFlight.removeAll()
        dirtyOverrides.removeAll()
        baseCache.removeAll()
        untrackedCounts.removeAll()
        untrackedPending.removeAll()
    }

    // MARK: - Landing an answer

    private func adopt(directory: String, report: GitReport?) {
        inFlight.remove(directory)

        guard let report, let repo = report.repo else {
            // Not a repository, no usable git, or the query failed. All three
            // look the same to the reader, on purpose.
            if report == nil { failures += 1 }
            owners[directory] = String?.none
            return
        }

        queries += 1
        var badges: [String: GitBadge] = [:]
        badges.reserveCapacity(report.changes.count)
        for change in report.changes {
            badges[change.path] = GitBadge(
                status: change.status, added: change.added, removed: change.removed)
        }

        // The root as the *app* spells it. Keyed on that rather than on git's
        // answer, so every lookup below is a string prefix against a path the
        // app actually holds.
        let appRoot = Self.appVisibleRoot(askedAbout: directory, gitRoot: repo.root)
        let previous = repos[appRoot] ?? nil
        let stamp = query.stamp(indexPath: repo.indexPath, headPath: repo.headPath)
        repos[appRoot] = Cached(
            repo: repo, appRoot: appRoot, stamp: stamp, badges: badges, quiet: false)
        owners[directory] = appRoot
        // The root itself, so a row drawn directly under it resolves without a
        // second discovery. Both spellings, because either can reach us.
        owners[appRoot] = appRoot
        owners[repo.root] = appRoot

        // Only the rows whose badge actually changed. A repository with two
        // hundred changed files, re-queried because someone staged one of them,
        // must not redraw two hundred rows.
        var touched: [URL] = []
        let base = URL(fileURLWithPath: appRoot, isDirectory: true)
        let paths = Set(badges.keys).union(previous.map { Set($0.badges.keys) } ?? [])
        for relative in paths where badges[relative] != previous?.badges[relative] {
            touched.append(base.appendingPathComponent(relative))
        }
        if !touched.isEmpty { onBadges?(touched) }
        Log.git.debug(
            "git: \(badges.count) changed in \(repo.root, privacy: .public), \(touched.count) row(s) redrawn"
        )
    }

    /// The repository root as the app spells it.
    ///
    /// Found by walking **up from the directory the app asked about** until a
    /// `.git` entry appears — the same walk `Ignores::collect` does in
    /// `core/src/tree.rs`, and for the same reason: it works in whatever
    /// spelling the caller used and resolves nothing.
    ///
    /// Path arithmetic against `gitRoot` was the obvious alternative and it is
    /// wrong: it needs `resolvingSymlinksInPath`, which does not resolve a
    /// component that does not exist, so it fails on exactly the paths worth
    /// handling. One `stat` per ancestor, once per repository, off the draw
    /// path, is cheaper *and* correct.
    ///
    /// Falls back to `gitRoot` when the walk finds nothing, which loses the
    /// badges rather than showing wrong ones.
    private static func appVisibleRoot(askedAbout: String, gitRoot: String) -> String {
        var directory = URL(fileURLWithPath: askedAbout, isDirectory: true)
        // `.git` is a directory in an ordinary checkout and a *file* in a linked
        // worktree, so this asks whether it exists rather than whether it is a
        // directory.
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".git").path)
            {
                return directory.path
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return gitRoot
    }

    /// `url` relative to `root`, matching the spelling git reports.
    ///
    /// String-level and deliberately not `URL.standardized` or
    /// `resolvingSymlinksInPath`: this runs on the draw path, and resolving
    /// symlinks there would be a syscall per visible row. The reconciliation
    /// happens once, in ``appVisibleRoot(askedAbout:gitRoot:)``.
    private static func relative(of url: URL, under root: String) -> String? {
        let path = url.path
        guard path.count > root.count, path.hasPrefix(root) else { return nil }
        let cut = path.index(path.startIndex, offsetBy: root.count)
        var relative = String(path[cut...])
        if relative.hasPrefix("/") { relative.removeFirst() }
        return relative.isEmpty ? nil : relative
    }
}

/// The two mtimes `2026-08-28-git-badges-ride-the-sidebar-poll` gates on.
public struct GitStamp: Equatable, Sendable {
    public let index: TimeInterval?
    public let head: TimeInterval?

    public init(index: TimeInterval?, head: TimeInterval?) {
        self.index = index
        self.head = head
    }
}

/// What `GitBadgeService` needs from the world. A protocol so a test can count
/// invocations — "a quiet poll runs no git process" cannot be asserted against
/// the real thing.
public protocol GitQuerying: Sendable {
    /// Discover and query in one call, off the main thread.
    func status(path: String) throws -> GitReport
    /// `stat` the gate. Must not run a process.
    func stamp(indexPath: String, headPath: String) -> GitStamp
    /// `HEAD`'s bytes for one file, for the dirty-buffer recount.
    func base(path: String) throws -> GitBase
    /// Count `new` against `base`, by line.
    func counts(base: String, new: String) throws -> (added: Int, removed: Int)
    /// Lines in a file on disk, for an untracked row's added count. `nil` for
    /// anything that is not readable text — a directory, a binary.
    func lineCount(path: String) -> Int?
}

/// The real one: `mark_git_json`, plus two `stat` calls.
public struct CoreGitQuery: GitQuerying {
    public init() {}

    public func status(path: String) throws -> GitReport {
        try MarkCore.git(status: path)
    }

    public func base(path: String) throws -> GitBase {
        try MarkCore.git(base: path)
    }

    public func counts(base: String, new: String) throws -> (added: Int, removed: Int) {
        let diff = try MarkCore.lineDiff(old: base, new: new)
        return (diff.added, diff.removed)
    }

    public func lineCount(path: String) -> Int? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        // Through the core, so the number a new note is badged with is the same
        // number `mark ls --git` prints for it — `lines::count` is one
        // definition of "how many lines", and there must not be a second.
        return (try? MarkCore.lineDiff(old: "", new: text))?.added
    }

    /// Two `stat(2)` calls and no process.
    ///
    /// The paths come from the core, which resolved them through
    /// `rev-parse --git-path` — a linked worktree, a shared index, and
    /// `$GIT_INDEX_FILE` each put them somewhere that is *not* the git
    /// directory plus a name. Resolving them here would cost a `git` process
    /// per tick, which is the cost this gate exists to avoid.
    public func stamp(indexPath: String, headPath: String) -> GitStamp {
        GitStamp(index: Self.mtime(indexPath), head: Self.mtime(headPath))
    }

    private static func mtime(_ path: String) -> TimeInterval? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        // Nanoseconds included: on APFS the gate is exact, and truncating to
        // whole seconds would miss two commits in the same second.
        return TimeInterval(info.st_mtimespec.tv_sec)
            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
    }
}
