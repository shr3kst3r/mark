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
    public static func renderHTML(
        source: String, prefixBlocks: Int = 0, theme: String? = nil
    ) throws -> String {
        precondition(prefixBlocks >= 0, "prefixBlocks is a count, not an index")
        return try string(function: "mark_render_html") {
            withOptionalCString(theme) { themePointer in
                source.withCString { mark_render_html($0, size_t(prefixBlocks), themePointer) }
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
                        mark_diff_json(oldPointer, newPointer, themePointer)
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

    /// One directory level.
    ///
    /// `depth` is clamped to at least 1 by the core; there is no unlimited
    /// walk. The sidebar always passes 1, because the user's real tree holds
    /// 608k files (research §2.8) and an eager descent there is a multi-second
    /// hang.
    ///
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
                mark_tree_json($0, size_t(max(1, depth)), withStats ? 1 : 0, options.coreFlags)
            }
        }
        return try decode([TreeEntry].self, from: json, function: "mark_tree_json")
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
