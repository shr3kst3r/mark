import Foundation

/// One restored tab.
public struct SessionTab: Codable, Equatable, Sendable {
    /// Absolute path. Not a bookmark: a moved file should reopen as "missing"
    /// rather than silently follow a rename the user did not ask us to track.
    public var path: String
    /// `window.pageYOffset` when the session was written.
    public var scrollOffset: Double
    /// The document's first heading, for a tooltip before the file is re-read.
    /// Advisory only — the badge and the label are recomputed from disk.
    public var title: String?

    /// Whether this was the italic **preview** tab — the single-click slot the
    /// next single click replaces.
    ///
    /// Persisted so a session that ended with one skim tab comes back with one,
    /// rather than silently making it permanent and leaving the user to close
    /// by hand what they never asked to keep.
    public var preview: Bool

    public init(
        path: String, scrollOffset: Double = 0, title: String? = nil, preview: Bool = false
    ) {
        self.path = path
        self.scrollOffset = scrollOffset
        self.title = title
        self.preview = preview
    }

    private enum CodingKeys: String, CodingKey {
        case path, scrollOffset, title, preview
    }

    /// Decoded by hand for the reason ``SessionSidebarOptions`` is: Swift's
    /// synthesized decoder does **not** fall back to a property's default value
    /// for a missing key, it throws. ``preview`` did not exist before preview tabs did, so a
    /// synthesized decoder would refuse every session file written by an
    /// earlier build and lose the user's tabs to buy nothing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        scrollOffset = try container.decodeIfPresent(Double.self, forKey: .scrollOffset) ?? 0
        title = try container.decodeIfPresent(String.self, forKey: .title)
        preview = try container.decodeIfPresent(Bool.self, forKey: .preview) ?? false
    }
}

/// The sidebar's toggles and sort order, as the session file records them.
///
/// A nested struct rather than four more top-level keys so the sidebar's
/// persisted state reads as one thing, and so a session file written before M8
/// simply has no `sidebarOptions` key rather than four missing ones.
///
/// Decoded field by field with defaults, because Swift's synthesized decoder
/// does **not** fall back to a property's default value for a missing key — it
/// throws, and a session file hand-edited to drop one boolean would then lose
/// the user's tabs. An unknown `sort` decodes to `name` for the same reason.
public struct SessionSidebarOptions: Codable, Equatable, Sendable {
    public var showsNonMarkdown: Bool
    public var showsHidden: Bool
    public var sort: String

    public init(showsNonMarkdown: Bool = false, showsHidden: Bool = false, sort: String = TreeSort.name.rawValue) {
        self.showsNonMarkdown = showsNonMarkdown
        self.showsHidden = showsHidden
        self.sort = sort
    }

    private enum CodingKeys: String, CodingKey {
        case showsNonMarkdown, showsHidden, sort
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showsNonMarkdown = try container.decodeIfPresent(Bool.self, forKey: .showsNonMarkdown) ?? false
        showsHidden = try container.decodeIfPresent(Bool.self, forKey: .showsHidden) ?? false
        sort = try container.decodeIfPresent(String.self, forKey: .sort) ?? TreeSort.name.rawValue
    }
}

/// One editor group — a pane's own tabs and its own selection.
///
/// New with `2026-08-26-editor-groups-per-pane-tab-bars`, and the third
/// additive layer in this file: the flat ``SessionState`` fields describe the
/// first window, ``SessionWindow/tabs`` describes that window's first group,
/// and this describes every group. Each layer exists so a build that predates
/// the one above it restores something rather than nothing.
public struct SessionGroup: Codable, Equatable, Sendable {
    public var tabs: [SessionTab]
    public var selectedIndex: Int?

    public init(tabs: [SessionTab] = [], selectedIndex: Int? = nil) {
        self.tabs = tabs
        self.selectedIndex = selectedIndex
    }

    private enum CodingKeys: String, CodingKey {
        case tabs, selectedIndex
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try container.decodeIfPresent([SessionTab].self, forKey: .tabs) ?? []
        selectedIndex = try container.decodeIfPresent(Int.self, forKey: .selectedIndex)
    }

    /// The selection, or the first tab, or nothing — never an index the list
    /// does not have.
    public var repairedSelectedIndex: Int? {
        guard let selectedIndex, tabs.indices.contains(selectedIndex) else {
            return tabs.isEmpty ? nil : 0
        }
        return selectedIndex
    }
}

/// One window, as the session file records it.
///
/// New with `2026-08-26-multiple-windows-and-split-panes`. Everything here used
/// to be a top-level field of ``SessionState``, because there used to be one
/// window; the fields are unchanged in meaning, and the flat ones are still
/// written for the reason ``SessionState/windows`` explains.
///
/// Decoded field by field with defaults, like everything else in this file:
/// Swift's synthesized decoder does **not** fall back to a property's default
/// for a missing key, it throws, and losing a user's tabs to one absent boolean
/// is the failure that convention exists to prevent.
public struct SessionWindow: Codable, Equatable, Sendable {
    public var tabs: [SessionTab]
    public var selectedIndex: Int?

    /// The split's right-hand pane, as an index into ``tabs``.
    ///
    /// Written by `2026-08-26-multiple-windows-and-split-panes`' one-bar model,
    /// where the split was one tab shown beside another rather than a group of
    /// its own. **Read on restore, never written again**
    /// (`2026-08-26-editor-groups-per-pane-tab-bars`): a file with this field
    /// and no ``groups`` comes back as two groups, the named tab alone in the
    /// second. Absent means the window was not split.
    public var secondaryIndex: Int?

    /// Which group has the focus, as an index into ``groups``.
    ///
    /// A string because it used to be ``Pane``'s raw value, and a session file
    /// written by the one-bar build says `"primary"` or `"secondary"`. Both
    /// spellings are read; only the index is written.
    public var focus: String?

    /// This window's editor groups, left to right.
    ///
    /// Absent in every file written before
    /// `2026-08-26-editor-groups-per-pane-tab-bars`, which is what
    /// ``effectiveGroups`` migrates. Present, it is the truth and ``tabs``
    /// duplicates its first entry.
    public var groups: [SessionGroup]?

    /// Where the divider sat, as a fraction of the window's width.
    public var splitFraction: Double?

    /// `NSStringFromRect` of the window's frame.
    ///
    /// A window that comes back somewhere other than where it was left reads as
    /// the app forgetting — and with more than one window it also reads as them
    /// being shuffled. Validated on restore: a frame entirely off every screen
    /// falls back to cascading, because a window the user cannot see is
    /// indistinguishable from a window that did not come back.
    public var frame: String?

    public var sidebarCollapsed: Bool?
    public var sidebarRoot: String?
    public var sidebarBack: [String]?
    public var sidebarForward: [String]?
    public var sidebarOptions: SessionSidebarOptions?
    public var editorVisible: Bool?

    public init(
        tabs: [SessionTab] = [],
        selectedIndex: Int? = nil,
        secondaryIndex: Int? = nil,
        focus: String? = nil,
        groups: [SessionGroup]? = nil,
        splitFraction: Double? = nil,
        frame: String? = nil,
        sidebarCollapsed: Bool? = nil,
        sidebarRoot: String? = nil,
        sidebarBack: [String]? = nil,
        sidebarForward: [String]? = nil,
        sidebarOptions: SessionSidebarOptions? = nil,
        editorVisible: Bool? = nil
    ) {
        self.tabs = tabs
        self.selectedIndex = selectedIndex
        self.secondaryIndex = secondaryIndex
        self.focus = focus
        self.groups = groups
        self.splitFraction = splitFraction
        self.frame = frame
        self.sidebarCollapsed = sidebarCollapsed
        self.sidebarRoot = sidebarRoot
        self.sidebarBack = sidebarBack
        self.sidebarForward = sidebarForward
        self.sidebarOptions = sidebarOptions
        self.editorVisible = editorVisible
    }

    private enum CodingKeys: String, CodingKey {
        case tabs, selectedIndex, secondaryIndex, focus, groups, splitFraction, frame
        case sidebarCollapsed, sidebarRoot, sidebarBack, sidebarForward, sidebarOptions
        case editorVisible
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try container.decodeIfPresent([SessionTab].self, forKey: .tabs) ?? []
        selectedIndex = try container.decodeIfPresent(Int.self, forKey: .selectedIndex)
        secondaryIndex = try container.decodeIfPresent(Int.self, forKey: .secondaryIndex)
        focus = try container.decodeIfPresent(String.self, forKey: .focus)
        groups = try container.decodeIfPresent([SessionGroup].self, forKey: .groups)
        splitFraction = try container.decodeIfPresent(Double.self, forKey: .splitFraction)
        frame = try container.decodeIfPresent(String.self, forKey: .frame)
        sidebarCollapsed = try container.decodeIfPresent(Bool.self, forKey: .sidebarCollapsed)
        sidebarRoot = try container.decodeIfPresent(String.self, forKey: .sidebarRoot)
        sidebarBack = try container.decodeIfPresent([String].self, forKey: .sidebarBack)
        sidebarForward = try container.decodeIfPresent([String].self, forKey: .sidebarForward)
        sidebarOptions = try container.decodeIfPresent(
            SessionSidebarOptions.self, forKey: .sidebarOptions)
        editorVisible = try container.decodeIfPresent(Bool.self, forKey: .editorVisible)
    }

    /// The split's right-hand tab as the one-bar model recorded it, repaired if
    /// the file lies.
    ///
    /// A hand-edited or truncated file can name a `secondaryIndex` that is out
    /// of range, or the same index as `selectedIndex` — which would put one tab
    /// in two places, which is still forbidden. Repaired to "not split" rather
    /// than refused, matching this file's posture on a second preview tab: a bad
    /// session file costs the user a pane, never their documents.
    public var repairedSecondaryIndex: Int? {
        guard let secondaryIndex, tabs.indices.contains(secondaryIndex) else { return nil }
        guard secondaryIndex != selectedIndex else { return nil }
        return secondaryIndex
    }

    /// The groups to restore: ``groups`` when the file has it, otherwise the
    /// one-bar model's fields read as groups.
    ///
    /// The migration is the whole of this property's reason to exist. A file
    /// from the one-bar build says "these are the window's tabs, and tab *n* is
    /// also on the right" — so the tab named by ``repairedSecondaryIndex``
    /// becomes a second group holding it alone, and everything else stays in
    /// the first. That is the arrangement the user was looking at when the file
    /// was written, expressed in the model that replaced it.
    ///
    /// Empty groups are dropped rather than restored: a group with no tabs is
    /// not a state this model has, and a window with no tabs at all is one
    /// empty group, not two.
    public var effectiveGroups: [SessionGroup] {
        if let groups {
            let kept = groups.filter { !$0.tabs.isEmpty }
            return kept.isEmpty ? [SessionGroup()] : Array(kept.prefix(2))
        }
        guard let secondary = repairedSecondaryIndex else {
            return [SessionGroup(tabs: tabs, selectedIndex: selectedIndex)]
        }
        var first: [SessionTab] = []
        var selected: Int?
        for (index, tab) in tabs.enumerated() where index != secondary {
            if index == selectedIndex { selected = first.count }
            first.append(tab)
        }
        return [
            SessionGroup(tabs: first, selectedIndex: selected ?? (first.isEmpty ? nil : 0)),
            SessionGroup(tabs: [tabs[secondary]], selectedIndex: 0),
        ]
    }

    /// Which group had the focus, as an index into ``effectiveGroups``.
    ///
    /// Reads both spellings: an index written by this model, and the one-bar
    /// build's `"primary"` / `"secondary"`. Out of range means the first group,
    /// because a focused group that does not exist would leave every menu item
    /// greyed out.
    public var focusedGroupIndex: Int {
        guard let focus else { return 0 }
        let index: Int
        switch focus {
        case "primary": index = 0
        case "secondary": index = 1
        default: index = Int(focus) ?? 0
        }
        return effectiveGroups.indices.contains(index) ? index : 0
    }
}

/// One file in the opened-file history, as the session file records it.
///
/// `2026-08-26-opened-file-history`. A path and an epoch timestamp — the same
/// `String` path ``SessionTab`` uses, for the same stated reason, and a `Double`
/// rather than a `Date` because this file has no date-encoding strategy and
/// should not grow one for a scalar that `JSONEncoder` would otherwise spell
/// differently than every other number here.
///
/// Decoded by hand with defaults, like everything else in this file.
public struct SessionHistoryEntry: Codable, Equatable, Sendable {
    public var path: String
    /// Seconds since 1970.
    public var lastOpened: Double

    public init(path: String, lastOpened: Double) {
        self.path = path
        self.lastOpened = lastOpened
    }

    private enum CodingKeys: String, CodingKey {
        case path, lastOpened
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        lastOpened = try container.decodeIfPresent(Double.self, forKey: .lastOpened) ?? 0
    }
}

/// What `mark` remembers between launches.
public struct SessionState: Codable, Equatable, Sendable {

    /// Bumped when the shape changes. An unknown version is refused rather
    /// than half-decoded — a session file is a convenience, and starting empty
    /// is strictly better than restoring something wrong.
    public static let currentVersion = 1

    public var version: Int
    public var tabs: [SessionTab]
    public var selectedIndex: Int?
    public var sidebarRoot: String?

    /// M8's navigation history over roots, oldest first. Optional so a session
    /// written by an M3-era build still decodes: every field added here is
    /// additive and optional, which is why ``currentVersion`` does **not** move
    /// — bumping it would refuse yesterday's session file and lose the user's
    /// tabs to buy nothing, since a v1 reader ignores keys it does not know and
    /// a v2 reader finds them absent.
    public var sidebarBack: [String]?
    public var sidebarForward: [String]?
    public var sidebarOptions: SessionSidebarOptions?

    /// M7's chosen theme, by name. Optional for the same reason the sidebar
    /// fields are: a session written before M7 still decodes, and its absence
    /// means "the default".
    public var theme: String?

    /// Which half of that theme was on screen — `"system"`, `"light"`, or
    /// `"dark"`.
    ///
    /// Recorded because pinning is a choice the user made, and a relaunch that
    /// dropped it would put a light theme back under a dark system — the exact
    /// thing pinning exists to stop. Absent — a session written before there
    /// was anything to record — means the named theme's own kind, because back
    /// then naming one was already how you asked for it.
    public var themeAppearance: String?

    /// Whether M9's editor pane was on screen (M10).
    ///
    /// ADR-6 opens a document *"read-only until the user asks to edit it"*, and
    /// that is about a **document**, not about a session: having asked once and
    /// then relaunched into a read-only window reads as the app forgetting,
    /// which is what every other pane in this window already avoids. Absent —
    /// a pre-M10 session file — still means hidden, so the ADR's default is
    /// what a first launch gets.
    ///
    /// Restoring it shows the pane and binds the selected tab's buffer;
    /// nothing is written, and a tab is still clean until the user types.
    public var editorVisible: Bool?

    /// Whether the editor draws a mark for every space, tab and stranger.
    ///
    /// **Top-level, beside ``theme``, rather than on ``SessionWindow``**, for
    /// the reason the theme is: it is one choice about how source looks, not one
    /// per window, and two editors disagreeing about whether a space is visible
    /// is not a state anyone means to be in.
    ///
    /// Optional and additive like every field added since M8, so
    /// ``currentVersion`` does not move. Absent — every session file written
    /// before the marks existed — means the default, which is *on*: the feature
    /// is "show me what is there", and a first launch that hid it would need
    /// explaining.
    public var editorInvisibles: Bool?

    /// How large document text is drawn — ``TextZoom``.
    ///
    /// The *scale* rather than the ladder index, so changing `TextZoom.steps`
    /// cannot silently move an existing reader's setting to a different size.
    /// Optional and additive like the fields around it; absent means 100%, and
    /// 100% writes nothing.
    public var textZoom: Double?

    /// Whether documents use the whole window rather than the measure —
    /// ``DocumentWidth``.
    ///
    /// Top-level, beside ``theme`` and ``textZoom``, rather than on
    /// ``SessionWindow``: it is one choice about how a document looks, not one
    /// per window. Optional and additive like the fields around it, so
    /// ``currentVersion`` does not move; absent means the measure, which is
    /// the default, so the common case writes nothing.
    public var documentFullWidth: Bool?

    /// Whether the editor's margin numbers its lines — ``LineNumbers``.
    ///
    /// Optional and additive like the fields around it. Absent means off,
    /// which is the default, so the common case writes nothing.
    public var editorLineNumbers: Bool?

    /// Every window, in creation order
    /// (`2026-08-26-multiple-windows-and-split-panes`).
    ///
    /// **The duplication with the flat fields above is deliberate.** They keep
    /// describing `windows[0]`, and both are written, so:
    ///
    /// * a build without multi-window support reads the flat fields and
    ///   restores one window rather than failing or coming back empty;
    /// * a build with it prefers `windows` and ignores the flat copies.
    ///
    /// That is what buys a two-way downgrade for the price of a few duplicated
    /// keys, and it is why ``currentVersion`` does not move: the rule this file
    /// has followed since M8 is that every added field is optional and additive,
    /// because a version bump refuses yesterday's session and loses the user's
    /// tabs to buy nothing.
    public var windows: [SessionWindow]?

    /// The opened-file history, most recent first
    /// (`2026-08-26-opened-file-history`).
    ///
    /// **Top-level, beside ``theme``, rather than on ``SessionWindow``**,
    /// because the history is the application's and not a window's — a file
    /// opened in one window is a file that was opened. The two app-wide things
    /// this file records therefore sit together.
    ///
    /// It lives here rather than in a `history.json` of its own for one
    /// practical reason: `MARK_SESSION_FILE` is how `mark-bench` and the
    /// integration checks stay out of a developer's real state, so a history
    /// inside this file is hermetic in those runs for free, while a second file
    /// would write a developer's real history on every bench until a second
    /// override was added everywhere.
    ///
    /// Optional and additive like every field added since M8, so
    /// ``currentVersion`` does not move.
    public var history: [SessionHistoryEntry]?

    /// The windows to restore: the new field when present, else the flat
    /// fields read as a single window.
    ///
    /// The one place that fallback is expressed, so no caller has to remember
    /// which shape it is holding.
    public var effectiveWindows: [SessionWindow] {
        if let windows, !windows.isEmpty { return windows }
        guard !tabs.isEmpty || sidebarRoot != nil else { return [] }
        return [
            SessionWindow(
                tabs: tabs,
                selectedIndex: selectedIndex,
                sidebarRoot: sidebarRoot,
                sidebarBack: sidebarBack,
                sidebarForward: sidebarForward,
                sidebarOptions: sidebarOptions,
                editorVisible: editorVisible
            )
        ]
    }

    public init(
        version: Int = SessionState.currentVersion,
        tabs: [SessionTab] = [],
        selectedIndex: Int? = nil,
        sidebarRoot: String? = nil,
        sidebarBack: [String]? = nil,
        sidebarForward: [String]? = nil,
        sidebarOptions: SessionSidebarOptions? = nil,
        theme: String? = nil,
        themeAppearance: String? = nil,
        editorVisible: Bool? = nil,
        editorInvisibles: Bool? = nil,
        textZoom: Double? = nil,
        documentFullWidth: Bool? = nil,
        editorLineNumbers: Bool? = nil,
        windows: [SessionWindow]? = nil,
        history: [SessionHistoryEntry]? = nil
    ) {
        self.version = version
        self.tabs = tabs
        self.selectedIndex = selectedIndex
        self.sidebarRoot = sidebarRoot
        self.sidebarBack = sidebarBack
        self.sidebarForward = sidebarForward
        self.sidebarOptions = sidebarOptions
        self.theme = theme
        self.themeAppearance = themeAppearance
        self.editorVisible = editorVisible
        self.editorInvisibles = editorInvisibles
        self.textZoom = textZoom
        self.documentFullWidth = documentFullWidth
        self.editorLineNumbers = editorLineNumbers
        self.windows = windows
        self.history = history
    }

    /// Assemble a state from windows, mirroring the first into the flat fields.
    ///
    /// The only place the mirroring happens, so the two halves cannot disagree.
    public init(windows: [SessionWindow]) {
        let first = windows.first ?? SessionWindow()
        self.init(
            tabs: first.tabs,
            selectedIndex: first.selectedIndex,
            sidebarRoot: first.sidebarRoot,
            sidebarBack: first.sidebarBack,
            sidebarForward: first.sidebarForward,
            sidebarOptions: first.sidebarOptions,
            editorVisible: first.editorVisible,
            windows: windows
        )
    }
}

/// Why a session could not be read or written.
public enum SessionError: Error, CustomStringConvertible {
    case unreadable(path: String, underlying: any Error)
    case unwritable(path: String, underlying: any Error)
    case malformed(path: String, underlying: any Error)
    case unsupportedVersion(path: String, found: Int, expected: Int)

    public var description: String {
        switch self {
        case .unreadable(let path, let underlying):
            return "session \(path) could not be read: \(underlying.localizedDescription)"
        case .unwritable(let path, let underlying):
            return "session \(path) could not be written: \(underlying.localizedDescription)"
        case .malformed(let path, let underlying):
            return "session \(path) is not a session file: \(underlying)"
        case .unsupportedVersion(let path, let found, let expected):
            return "session \(path) is version \(found); this build reads \(expected)"
        }
    }
}

/// Session persistence, as **our own JSON file**.
///
/// ADR-4 makes this a constraint, not a preference:
///
/// > Session state is persisted to our own JSON file rather than relying on
/// > `NSWindowRestoration`, so restore is deterministic regardless of the
/// > user's "Close windows when quitting an app" setting.
/// >
/// > **Session state lives in our own file**, not `NSWindowRestoration`, and
/// > `NSQuitAlwaysKeepsWindows` is a user preference we must not write.
///
/// Two things follow, and both are asserted in `SessionTests`:
///
/// * Nothing in this file — or anywhere else in the app — writes
///   `NSQuitAlwaysKeepsWindows`, or any other key, into `UserDefaults`. That
///   default belongs to the user's System Settings checkbox; an app that
///   flips it to make its own restore work has broken every other app on the
///   machine.
/// * ``MainWindowController`` sets `window.isRestorable = false`, so AppKit
///   does not *also* try to restore the window and race this. The ADR names
///   the file as the mechanism; turning the competing mechanism off is the
///   implementation choice that makes "deterministic" true rather than
///   merely intended.
///
/// The write is temp-file-plus-rename, matching plan §3's rule for the
/// checkbox write path. A session file is less precious than a user's
/// document, but a crash mid-write that leaves a truncated JSON file would
/// lose every tab, and the atomic write costs one line.
public final class Session: @unchecked Sendable {

    /// `~/Library/Application Support/mark/session.json`, or whatever
    /// `MARK_SESSION_FILE` points at.
    ///
    /// Not `~/.config`: that is where *user-editable* configuration goes (M7's
    /// themes will live there). This is app state the user never edits.
    ///
    /// The override exists so `mark-bench` and the integration checks can drive
    /// a real launch-quit-relaunch cycle without touching — or destroying — the
    /// developer's actual session.
    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["MARK_SESSION_FILE"],
            !override.isEmpty
        {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return support.appendingPathComponent("mark", isDirectory: true)
            .appendingPathComponent("session.json")
    }

    public let url: URL

    /// Coalesces the burst of saves a single user action produces — opening a
    /// tab changes the list, the selection, and the metadata, which is three
    /// notifications and one meaningful state.
    private let debounce: TimeInterval
    private var pendingSave: DispatchWorkItem?

    public init(url: URL = Session.defaultURL, debounce: TimeInterval = 0.5) {
        self.url = url
        self.debounce = debounce
    }

    // MARK: - Reading

    /// The stored session, or `nil` when there is no file yet.
    ///
    /// A file that exists but does not parse is an error rather than a `nil`:
    /// silently starting empty because the JSON drifted is exactly the kind of
    /// data loss that gets reported as "it forgot my tabs" with no way to find
    /// out why.
    public func load() throws -> SessionState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SessionError.unreadable(path: url.path, underlying: error)
        }
        let state: SessionState
        do {
            state = try JSONDecoder().decode(SessionState.self, from: data)
        } catch {
            throw SessionError.malformed(path: url.path, underlying: error)
        }
        guard state.version == SessionState.currentVersion else {
            throw SessionError.unsupportedVersion(
                path: url.path,
                found: state.version,
                expected: SessionState.currentVersion
            )
        }
        return state
    }

    /// ``load()``, reporting failure to the log instead of throwing.
    ///
    /// The launch path: a bad session file must not stop the app from
    /// starting, but it must not be invisible either.
    public func loadOrLogging() -> SessionState? {
        do {
            return try load()
        } catch {
            Log.app.error("\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Writing

    public func save(_ state: SessionState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(state)
        } catch {
            throw SessionError.unwritable(path: url.path, underlying: error)
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // `.atomic` is temp-file-plus-rename, the same discipline the
            // checkbox write path uses (plan §3).
            try data.write(to: url, options: .atomic)
        } catch {
            throw SessionError.unwritable(path: url.path, underlying: error)
        }
        Log.app.debug("session saved: \(state.tabs.count) tabs")
    }

    /// Save after the debounce interval, replacing any save already queued.
    @MainActor
    public func scheduleSave(_ provider: @escaping @MainActor () -> SessionState) {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                do {
                    try self.save(provider())
                } catch {
                    Log.app.error("\(String(describing: error), privacy: .public)")
                }
            }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// Write now, dropping any queued save. The quit path — `applicationWill\
    /// Terminate` does not get a debounce interval.
    @MainActor
    public func saveNow(_ state: SessionState) {
        pendingSave?.cancel()
        pendingSave = nil
        do {
            try save(state)
        } catch {
            Log.app.error("\(String(describing: error), privacy: .public)")
        }
    }
}
