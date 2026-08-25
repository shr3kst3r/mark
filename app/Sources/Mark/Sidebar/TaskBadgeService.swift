import Foundation

/// `3/7` — open and total tasks for one markdown file.
public struct TaskBadge: Equatable, Sendable {
    public let open: Int
    public let total: Int

    public init(open: Int, total: Int) {
        self.open = open
        self.total = total
    }

    /// What the sidebar draws. `nil` for a document with no tasks at all —
    /// a `0/0` on every prose file is noise, not information.
    public var label: String? {
        guard total > 0 else { return nil }
        return "\(open)/\(total)"
    }
}

/// Per-file task badges, computed **lazily and in the background** — never on
/// the walk.
///
/// This is the single hardest constraint in M8, and it is a measured one rather
/// than a stylistic preference. Research §2.8 timed 345 ms to read every `.md`
/// in `~/notes` (1,026 files), and `~/src` holds 608,597 files. So:
///
/// * `mark_tree_json` is called with `with_stats: false` for every listing —
///   see ``CoreDirectoryLister``. The listing never opens a file.
/// * Badges are asked for **by row, when a row is about to be drawn**, which is
///   bounded by the height of the sidebar rather than by the size of the tree.
/// * ``badge(for:)`` is a dictionary lookup. It never reads, never stats, and
///   never blocks — `NSOutlineView` calls it once per visible row per redraw.
/// * ``request(_:)`` puts the work on a utility-QoS queue and returns
///   immediately. The main thread does no file I/O for a badge, ever.
///
/// The queue is a **stack**, not a FIFO. Rows arrive in the order the outline
/// view draws them, and when a user scrolls fast the rows that matter are the
/// ones asked for most recently; a FIFO would spend its time computing badges
/// for rows that have already scrolled off.
@MainActor
public final class TaskBadgeService {

    /// A badge landed for this file. The sidebar redraws that row.
    public var onBadge: ((URL, TaskBadge) -> Void)?

    /// The unsaved bytes for a file, when a tab is holding some.
    ///
    /// `2026-08-24-editing-pane-and-autosave`: *"Nothing may read the file for
    /// rendering, task counts, or search on a dirty tab."* A sidebar badge is a
    /// task count, and it is computed on a background queue from a file read —
    /// so the one place that read happens asks here first, and counts the
    /// buffer's tasks instead when the answer is non-nil. Without this hook a
    /// ⌘R on the sidebar would quietly badge a document the reader is editing
    /// with the counts of the version on disk.
    public var dirtySource: ((URL) -> String?)?

    /// How many files may be read at once. One is enough — research §2.8
    /// measured ~0.34 ms per file, so a full sidebar's worth of rows lands
    /// inside a frame or two, and a single reader keeps the badge work off the
    /// same disk queue the user's next expansion needs.
    private let concurrency: Int

    /// The work queue. `.utility` so a badge never competes with the main
    /// thread or with a document open.
    private let queue = DispatchQueue(
        label: "dev.mark.sidebar.badges", qos: .utility, attributes: .concurrent)

    private var cache: [String: TaskBadge] = [:]
    private var pending: Set<String> = []
    private var stack: [URL] = []
    private var running = 0

    /// Counters for `mark-bench` and for the log line when the queue drains.
    public private(set) var computed = 0
    public private(set) var served = 0
    public private(set) var failed = 0

    public init(concurrency: Int = 1) {
        self.concurrency = max(1, concurrency)
    }

    // MARK: - Reading

    /// The badge, if it is already known. **Never touches the filesystem.**
    public func badge(for url: URL) -> TaskBadge? {
        let badge = cache[url.path]
        if badge != nil { served += 1 }
        return badge
    }

    /// Whether a badge for `url` is known or on its way, so a caller can tell
    /// "no tasks" from "not computed yet".
    public func isResolved(_ url: URL) -> Bool { cache[url.path] != nil }

    public var queueDepth: Int { stack.count + running }

    // MARK: - Asking

    /// Compute the badge for `url` in the background, unless it is already
    /// known or already queued.
    ///
    /// Safe to call from a draw path: it does a dictionary lookup and an array
    /// append, and returns.
    public func request(_ url: URL) {
        guard TreeNode.isMarkdown(url) else { return }
        let key = url.path
        guard cache[key] == nil, !pending.contains(key) else { return }
        pending.insert(key)
        stack.append(url)
        pump()
    }

    /// Ask for several at once, cheapest first in draw order.
    public func request<S: Sequence>(contentsOf urls: S) where S.Element == URL {
        for url in urls { request(url) }
    }

    // MARK: - Invalidation

    /// Forget one file's badge, so the next ``request(_:)`` recomputes it.
    /// Called when the watcher reports a change and when the sidebar refreshes.
    public func invalidate(_ url: URL) {
        cache.removeValue(forKey: url.path)
    }

    /// Forget everything. The sidebar's ⌘R.
    public func invalidateAll() {
        cache.removeAll()
    }

    // MARK: - The pump

    private func pump() {
        while running < concurrency, let url = stack.popLast() {
            running += 1
            // Read on the main actor, before the hop, because that is where
            // the buffer lives.
            let unsaved = dirtySource?(url)
            queue.async { [weak self] in
                let result = unsaved.map(Self.compute(source:)) ?? Self.compute(url)
                _Concurrency.Task { @MainActor [weak self] in
                    self?.finish(url, result)
                }
            }
        }
    }

    private func finish(_ url: URL, _ badge: TaskBadge?) {
        running -= 1
        pending.remove(url.path)
        if let badge {
            cache[url.path] = badge
            computed += 1
            onBadge?(url, badge)
        } else {
            failed += 1
            // Not cached, so a file that becomes readable later still gets a
            // badge — but also not retried on this pass, so an unreadable file
            // is not re-read on every redraw.
            Log.tree.debug("no badge for \(url.lastPathComponent, privacy: .public)")
        }
        if stack.isEmpty && running == 0 {
            Log.tree.debug(
                "badge queue drained: \(self.computed) computed, \(self.failed) unreadable")
        }
        pump()
    }

    /// The background half. `nonisolated` and `static` so it cannot reach any
    /// main-actor state by accident — the whole point is that this runs off the
    /// main thread.
    private nonisolated static func compute(source: String) -> TaskBadge? {
        guard let tasks = try? MarkCore.tasks(source: source) else { return nil }
        return TaskBadge(open: tasks.filter { !$0.checked }.count, total: tasks.count)
    }

    private nonisolated static func compute(_ url: URL) -> TaskBadge? {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            // A non-UTF-8 markdown file is a real thing; fall back the same way
            // ``DocumentMetadata/load(url:)`` does rather than reporting a
            // missing badge for a file that has tasks in it.
            var encoding = String.Encoding.utf8
            guard let guessed = try? String(contentsOf: url, usedEncoding: &encoding),
                let tasks = try? MarkCore.tasks(source: guessed)
            else { return nil }
            return TaskBadge(open: tasks.filter { !$0.checked }.count, total: tasks.count)
        }
        guard let tasks = try? MarkCore.tasks(source: source) else { return nil }
        return TaskBadge(open: tasks.filter { !$0.checked }.count, total: tasks.count)
    }
}
