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
        editorVisible: Bool? = nil
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
