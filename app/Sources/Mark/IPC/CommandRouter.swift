import AppKit
import Foundation

/// The wire protocol `mark-cli` and `mark.app` share, and the **one** command
/// type both entry paths decode into.
///
/// ADR-3 (`2026-08-24-cli-app-unix-socket-ipc`) names this as the cost of
/// having two doors into the same house:
///
/// > And there are now **two** entry paths into the same commands (socket and
/// > URL), which must not drift; the URL handler should parse into the same
/// > command type the socket decodes to.
///
/// The way that is made structural rather than aspirational: both paths reduce
/// to a command **name** and a `[String: String]` argument map before anything
/// interprets them, and ``Command/make(name:arguments:)`` is the only thing
/// that turns those into a ``Command``. A URL's query items already *are* a
/// string map, so the socket meets the URL on the URL's terms and there is no
/// second parser to keep in step.
///
///     {"version":1,"id":"7","command":"open","arguments":{"path":"/n.md","tab":"1"}}
///     mark://open?path=/n.md&tab=1
///
/// Both produce `Command.open(path: "/n.md", background: true)`, and
/// `CommandRouterTests` asserts exactly that for every command.
public enum MarkProtocol {

    /// Bumped when the shape of a request or a response changes.
    ///
    /// ADR-3: *"Every socket command carries a protocol version, and the app
    /// must respond intelligibly to a version it does not know."* The version
    /// is checked **before** the command name is looked at, so a future CLI
    /// talking to this app gets `unsupported-version` and not the far more
    /// confusing `unknown-command`.
    public static let version = 1

    /// The `mark://` scheme ADR-3 registers with LaunchServices.
    ///
    /// Deliberately not the scheme the shell's assets use — those are served
    /// over `mark-asset://` (see ``ShellAssets/scheme``) precisely so a
    /// `WKURLSchemeHandler` cannot shadow this one inside the web view.
    public static let urlScheme = "mark"
}

// MARK: - Errors

/// Why a command was refused, in a form the CLI can turn into an exit code.
public struct CommandFailure: Error, Equatable, Sendable {

    /// The stable, machine-readable half. `mark-cli` maps these to exit codes;
    /// the human-readable ``message`` is free to change.
    public enum Code: String, Sendable {
        /// The line was not a JSON object, or the envelope was unusable.
        case malformedRequest = "malformed-request"
        /// ADR-3's version constraint, refused intelligibly.
        case unsupportedVersion = "unsupported-version"
        case unknownCommand = "unknown-command"
        case badArguments = "bad-arguments"
        /// A file the caller named does not exist or cannot be read.
        case notFound = "not-found"
        /// The ADR's own example of a failure the CLI must be able to report.
        case anchorNotFound = "anchor-not-found"
        case tabNotFound = "tab-not-found"
        /// The command is well-formed but there is no document to apply it to.
        case noDocument = "no-document"
        /// A real command that this build does not implement yet.
        case unsupported = "unsupported"
        case internalError = "internal"
    }

    public var code: Code
    public var message: String
    /// Extra machine-readable context — the expected and received protocol
    /// versions, the tab index that was out of range, and so on.
    public var detail: [String: JSONValue]

    public init(_ code: Code, _ message: String, detail: [String: JSONValue] = [:]) {
        self.code = code
        self.message = message
        self.detail = detail
    }
}

// MARK: - JSON values

/// A JSON value, so responses are built from typed pieces rather than from
/// `Any` and hope.
public enum JSONValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    /// What `JSONSerialization` wants.
    public var foundationValue: Any {
        switch self {
        case .string(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        case .array(let values): return values.map(\.foundationValue)
        case .object(let values): return values.mapValues(\.foundationValue)
        }
    }

    /// The string form used for a request argument, so JSON `true` and a URL's
    /// `tab=1` arrive at the same place.
    var argumentString: String? {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return nil
        case .array, .object: return nil
        }
    }

    static func from(_ value: Any) -> JSONValue {
        switch value {
        case is NSNull: return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if number.stringValue.contains(".") { return .double(number.doubleValue) }
            return .int(number.intValue)
        case let string as String: return .string(string)
        case let array as [Any]: return .array(array.map(JSONValue.from))
        case let object as [String: Any]: return .object(object.mapValues(JSONValue.from))
        default: return .string(String(describing: value))
        }
    }
}

// MARK: - The request envelope

/// One line of the protocol, before it means anything.
///
/// Deliberately dumb: version, id, name, string arguments. Everything that can
/// fail *interestingly* — an unknown version, an unknown command, a missing
/// argument — fails after this, where there is a version to answer with.
public struct CommandRequest: Equatable, Sendable {

    public var version: Int
    /// Echoed back so a client that pipelines can match replies. `nil` from a
    /// `mark://` URL, which has no reply channel at all.
    public var id: String?
    public var name: String
    public var arguments: [String: String]

    public init(version: Int = MarkProtocol.version, id: String? = nil, name: String, arguments: [String: String] = [:]) {
        self.version = version
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// Decode one NDJSON line.
    ///
    /// `JSONSerialization` rather than `Codable` on purpose: arguments are
    /// accepted as strings, numbers, or booleans and coerced to their string
    /// form, so `{"tab": true}` and `{"tab": "1"}` and `?tab=1` are the same
    /// request. A `Codable` model would need a custom decoder to achieve the
    /// same thing, and would reject rather than coerce.
    public static func decode(line: String) throws -> CommandRequest {
        guard let data = line.data(using: .utf8) else {
            throw CommandFailure(.malformedRequest, "request is not valid UTF-8")
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw CommandFailure(
                .malformedRequest, "request is not JSON: \(error.localizedDescription)")
        }
        guard let object = parsed as? [String: Any] else {
            throw CommandFailure(.malformedRequest, "request must be a JSON object")
        }
        guard let name = object["command"] as? String, !name.isEmpty else {
            throw CommandFailure(.malformedRequest, "request has no \"command\"")
        }

        // A request with no version is a request from something that has not
        // read the protocol. Refusing it as version 0 gets the same structured
        // version-mismatch answer as a request from the future, which is the
        // useful reply in both directions.
        let version = (object["version"] as? NSNumber)?.intValue ?? 0

        var arguments: [String: String] = [:]
        if let raw = object["arguments"] as? [String: Any] {
            for (key, value) in raw {
                if let string = JSONValue.from(value).argumentString {
                    arguments[key] = string
                }
            }
        }

        let id = (object["id"] as? String) ?? (object["id"] as? NSNumber)?.stringValue
        return CommandRequest(version: version, id: id, name: name, arguments: arguments)
    }

    /// Decode a `mark://` URL.
    ///
    /// The command is the **host** and the arguments are the query items, so
    /// `mark://open?path=/n.md` and the socket's `"command":"open"` land on the
    /// same two values. `version` is an ordinary query item and defaults to the
    /// current one: a URL arriving from Finder or a browser was not written by
    /// a client that knows about protocol versions, and refusing it would make
    /// the cold-launch path — the reason ADR-3 keeps the scheme at all —
    /// depend on the sender knowing our version number.
    public static func decode(url: URL) throws -> CommandRequest {
        guard url.scheme?.lowercased() == MarkProtocol.urlScheme else {
            throw CommandFailure(
                .malformedRequest, "\(url.absoluteString) is not a \(MarkProtocol.urlScheme):// URL")
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw CommandFailure(.malformedRequest, "\(url.absoluteString) is not a usable URL")
        }
        // `mark://open?...` puts the command in the host; `mark:open?...`
        // (no slashes) puts it in the path. Accept both — a hand-typed URL
        // takes the second form more often than not.
        var name = components.host ?? ""
        if name.isEmpty {
            name = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard !name.isEmpty else {
            throw CommandFailure(.malformedRequest, "\(url.absoluteString) names no command")
        }

        var arguments: [String: String] = [:]
        for item in components.queryItems ?? [] {
            arguments[item.name] = item.value ?? ""
        }
        let version = arguments.removeValue(forKey: "version").flatMap(Int.init)
            ?? MarkProtocol.version
        let id = arguments.removeValue(forKey: "id")
        return CommandRequest(version: version, id: id, name: name.lowercased(), arguments: arguments)
    }
}

/// What goes back down the socket.
public struct CommandResponse: Equatable, Sendable {

    public var version: Int
    public var id: String?
    public var ok: Bool
    public var result: [String: JSONValue]
    public var failure: CommandFailure?

    public static func success(id: String?, _ result: [String: JSONValue] = [:]) -> CommandResponse {
        CommandResponse(version: MarkProtocol.version, id: id, ok: true, result: result, failure: nil)
    }

    public static func failed(id: String?, _ failure: CommandFailure) -> CommandResponse {
        CommandResponse(version: MarkProtocol.version, id: id, ok: false, result: [:], failure: failure)
    }

    /// One line of NDJSON, with no newline of its own — framing belongs to the
    /// transport.
    public func encoded() -> String {
        var object: [String: Any] = [
            "version": version,
            "ok": ok,
        ]
        if let id { object["id"] = id }
        if !result.isEmpty { object["result"] = result.mapValues(\.foundationValue) }
        if let failure {
            var error: [String: Any] = [
                "code": failure.code.rawValue,
                "message": failure.message,
            ]
            for (key, value) in failure.detail { error[key] = value.foundationValue }
            object["error"] = error
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let line = String(data: data, encoding: .utf8)
        else {
            // Every value here is a string, number, or bool, so this is
            // unreachable — but a response that fails to serialize must still
            // be a *response*, or the CLI hangs waiting for a line.
            return
                "{\"version\":\(MarkProtocol.version),\"ok\":false,\"error\":{\"code\":\"internal\",\"message\":\"response could not be serialized\"}}"
        }
        return line
    }
}

// MARK: - The command

/// Which tab a command is about.
public enum TabSelector: Equatable, Sendable {
    case index(Int)
    case path(String)
    /// Whatever is selected right now.
    case selected
}

/// What the CLI asked for. One type, two entry paths (ADR-3).
public enum Command: Equatable, Sendable {
    /// Liveness and identity: which app, which version, how many tabs. Used by
    /// `mark doctor` and by the integration checks to wait for a launch.
    case ping
    /// `background` is `mark open --tab`: make the tab, leave the selection
    /// and the window where they are.
    case open(path: String, background: Bool)
    case tabList
    case tabSelect(TabSelector)
    case tabClose(TabSelector)
    /// Apply a theme, or — with no name — report the one in force. The
    /// appearance is which half of it to show: absent means *the one you
    /// named*, and ``ThemeAppearance/system`` is `mark theme --system`.
    case theme(name: String?, appearance: ThemeAppearance?)
    case goTo(anchor: String)
    case reload
    /// M8. Read the sidebar's root, breadcrumb, and history.
    case sidebar
    /// M8. Move the sidebar's root, recording history.
    case navigate(NavigationTarget)

    /// The **only** place a name and an argument map become a command.
    public static func make(name: String, arguments: [String: String]) throws -> Command {
        switch name {
        case "ping":
            return .ping

        case "open":
            let path = try require("path", in: arguments, for: name)
            return .open(path: path, background: flag("tab", in: arguments))

        case "tab-list":
            return .tabList

        case "tab-select":
            return .tabSelect(try selector(from: arguments, for: name, allowSelected: false))

        case "tab-close":
            // Closing with no target closes the selected tab, which is what
            // `mark tab close` with no argument means and what ⌘W does.
            return .tabClose(try selector(from: arguments, for: name, allowSelected: true))

        case "theme":
            // No name is "what is applied?" rather than an error: listing and
            // showing are answered by `mark-cli` from the core without an app,
            // so the only questions that reach here are about *this* app's
            // state, and "which theme are you using" is one of them.
            var appearance: ThemeAppearance?
            if let requested = arguments["appearance"], !requested.isEmpty {
                guard let parsed = ThemeAppearance(argument: requested) else {
                    throw CommandFailure(
                        .badArguments,
                        "theme: \"\(requested)\" is not system, light, or dark",
                        detail: ["appearance": .string(requested)])
                }
                appearance = parsed
            }
            return .theme(
                name: arguments["name"].flatMap { $0.isEmpty ? nil : $0 },
                appearance: appearance)

        case "goto":
            var anchor = try require("anchor", in: arguments, for: name)
            // `mark goto '#install'` and `mark goto install` are the same
            // request; the `#` is how anchors are written everywhere else.
            if anchor.hasPrefix("#") { anchor.removeFirst() }
            guard !anchor.isEmpty else {
                throw CommandFailure(.badArguments, "goto needs a non-empty anchor")
            }
            return .goTo(anchor: anchor)

        case "reload":
            return .reload

        case "sidebar":
            return .sidebar

        case "nav":
            // `path` and `to` are the two ways to say where: an absolute
            // destination, or a move relative to where the sidebar already is.
            if let path = arguments["path"], !path.isEmpty {
                return .navigate(.path(path))
            }
            let to = (arguments["to"] ?? "").lowercased()
            guard let target = NavigationTarget(relative: to) else {
                throw CommandFailure(
                    .badArguments,
                    to.isEmpty
                        ? "nav needs a \"path\" or a \"to\" of parent, back, or forward"
                        : "nav: \"\(to)\" is not parent, back, or forward",
                    detail: ["to": .string(to)]
                )
            }
            return .navigate(target)

        default:
            throw CommandFailure(
                .unknownCommand,
                "unknown command \"\(name)\"",
                detail: ["known": .array(Command.knownNames.map(JSONValue.string))]
            )
        }
    }

    /// Every command this build understands, for the `unknown-command` reply
    /// and for `mark --help`'s counterpart on the app side.
    public static let knownNames = [
        "ping", "open", "tab-list", "tab-select", "tab-close", "theme", "goto", "reload",
        "sidebar", "nav",
    ]

    /// The name this command travels under. Round-trips with ``make(name:arguments:)``.
    public var name: String {
        switch self {
        case .ping: return "ping"
        case .open: return "open"
        case .tabList: return "tab-list"
        case .tabSelect: return "tab-select"
        case .tabClose: return "tab-close"
        case .theme: return "theme"
        case .goTo: return "goto"
        case .reload: return "reload"
        case .sidebar: return "sidebar"
        case .navigate: return "nav"
        }
    }

    private static func require(
        _ key: String, in arguments: [String: String], for command: String
    ) throws -> String {
        guard let value = arguments[key], !value.isEmpty else {
            throw CommandFailure(.badArguments, "\(command) needs a \"\(key)\" argument")
        }
        return value
    }

    /// `1`, `true`, `yes`, or a bare `?tab` with no value.
    private static func flag(_ key: String, in arguments: [String: String]) -> Bool {
        guard let value = arguments[key] else { return false }
        return value.isEmpty || ["1", "true", "yes", "on"].contains(value.lowercased())
    }

    private static func selector(
        from arguments: [String: String], for command: String, allowSelected: Bool
    ) throws -> TabSelector {
        if let raw = arguments["index"], !raw.isEmpty {
            guard let index = Int(raw), index >= 0 else {
                throw CommandFailure(.badArguments, "\(command): \"\(raw)\" is not a tab index")
            }
            return .index(index)
        }
        if let path = arguments["path"], !path.isEmpty {
            return .path(path)
        }
        guard allowSelected else {
            throw CommandFailure(.badArguments, "\(command) needs an \"index\" or a \"path\"")
        }
        return .selected
    }
}

/// Where `nav` is asking the sidebar to go.
public enum NavigationTarget: Equatable, Sendable {
    /// An absolute directory.
    case path(String)
    /// ⌘↑.
    case parent
    /// ⌘[.
    case back
    /// ⌘].
    case forward

    init?(relative: String) {
        switch relative {
        case "parent", "up": self = .parent
        case "back": self = .back
        case "forward": self = .forward
        default: return nil
        }
    }

    /// The argument form, so a decoded command round-trips back to the wire.
    public var argument: String {
        switch self {
        case .path(let path): return path
        case .parent: return "parent"
        case .back: return "back"
        case .forward: return "forward"
        }
    }
}

/// The sidebar, as the CLI sees it (M8).
///
/// Its reason for existing is the same as ``TabSummary``'s: the session file
/// records the root, the breadcrumb, and the history, and *"breadcrumb, root,
/// and history survive a session restore"* is a gate. Asserting it against the
/// file alone would pass if the app wrote the right JSON and restored none of
/// it, so `scripts/session-roundtrip.sh` asks the **running app** what its
/// sidebar actually says, which is what the user would see on screen.
public struct SidebarSummary: Equatable, Sendable {
    public var root: String
    /// The clickable path components, outermost first. The last one is `root`.
    public var breadcrumb: [String]
    public var back: [String]
    public var forward: [String]
    public var showsNonMarkdown: Bool
    public var showsHidden: Bool
    public var sort: String
    public var filter: String

    public init(
        root: String,
        breadcrumb: [String],
        back: [String],
        forward: [String],
        showsNonMarkdown: Bool,
        showsHidden: Bool,
        sort: String,
        filter: String
    ) {
        self.root = root
        self.breadcrumb = breadcrumb
        self.back = back
        self.forward = forward
        self.showsNonMarkdown = showsNonMarkdown
        self.showsHidden = showsHidden
        self.sort = sort
        self.filter = filter
    }

    public var json: JSONValue {
        .object([
            "root": .string(root),
            "breadcrumb": .array(breadcrumb.map(JSONValue.string)),
            "back": .array(back.map(JSONValue.string)),
            "forward": .array(forward.map(JSONValue.string)),
            "showsNonMarkdown": .bool(showsNonMarkdown),
            "showsHidden": .bool(showsHidden),
            "sort": .string(sort),
            "filter": .string(filter),
        ])
    }
}

// MARK: - What a command acts on

/// One open document, as the CLI sees it.
public struct TabSummary: Equatable, Sendable {
    public var index: Int
    public var path: String
    public var title: String
    public var selected: Bool
    /// ADR-4's residency, reported rather than inferred: a dehydrated tab is a
    /// real state the CLI can see, and `mark tab list` is where someone
    /// debugging a memory question will look first.
    public var resident: Bool
    /// Whether this is the single-click **preview** tab, the one the next
    /// single click in the sidebar replaces. Reported for the same reason
    /// ``resident`` is: it is a real state a tab can be in, it decides whether
    /// the tab survives the next click, and someone asking "why did my tab
    /// vanish" will look at `mark tab list` first.
    public var preview: Bool
    public var openTasks: Int?
    public var totalTasks: Int?

    /// Which window holds this tab, in creation order
    /// (`2026-08-26-multiple-windows-and-split-panes`).
    ///
    /// Reported because ``index`` is only unique *within* a window, and because
    /// a command acts on the key window — so "why did `mark open` put it over
    /// there" is a question `mark tab list` should be able to answer. `nil`
    /// when the app has no window coordinator, which is every test and
    /// `mark-bench`.
    public var window: Int?

    /// Which editor group holds this tab: `0` for the left, `1` for the right
    /// half of a split (`2026-08-26-editor-groups-per-pane-tab-bars`).
    ///
    /// Replaces the one-bar model's `pane`, which named the *side a document
    /// was displayed on* and was null for every tab that was merely open. A
    /// group is a set of tabs, so every tab in a window has one, and "which
    /// half of the window is this in" is answerable for all of them rather than
    /// for the one or two on screen.
    public var group: Int?

    public init(
        index: Int, path: String, title: String, selected: Bool, resident: Bool,
        preview: Bool = false, openTasks: Int? = nil, totalTasks: Int? = nil,
        window: Int? = nil, group: Int? = nil
    ) {
        self.index = index
        self.path = path
        self.title = title
        self.selected = selected
        self.resident = resident
        self.preview = preview
        self.openTasks = openTasks
        self.totalTasks = totalTasks
        self.window = window
        self.group = group
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = [
            "index": .int(index),
            "path": .string(path),
            "title": .string(title),
            "selected": .bool(selected),
            "resident": .bool(resident),
            "preview": .bool(preview),
        ]
        if let openTasks { object["openTasks"] = .int(openTasks) }
        if let totalTasks { object["totalTasks"] = .int(totalTasks) }
        // Both omitted rather than null when absent, so an older CLI reading
        // this reply sees exactly the object it saw before — additive on the
        // wire, which is what `2026-08-24-cli-app-unix-socket-ipc` requires of
        // a protocol change that does not bump the version.
        if let window { object["window"] = .int(window) }
        if let group { object["group"] = .int(group) }
        return .object(object)
    }
}

/// What an `open` did.
///
/// M8 made a directory a *place* rather than a document, and M10 made
/// `mark open <dir>` mean it: a file becomes a tab, a directory becomes the
/// sidebar's root. Both are real answers, so the command returns which one it
/// gave rather than a `TabSummary` that would have to be empty for half of
/// them — a success carrying no tab is the shape that made this refuse a
/// directory outright until now.
public enum OpenOutcome: Equatable, Sendable {
    /// A file: it is open in this tab.
    case tab(TabSummary)
    /// A directory: the sidebar is rooted there. Same answer `nav` gives, so a
    /// caller can treat the two identically.
    case sidebar(SidebarSummary)
}

/// The window operations a command needs.
///
/// A protocol rather than a direct dependency on ``MainWindowController``, for
/// the same reason ``TabHydrator`` and ``DirectoryLister`` are: it is the only
/// way to assert that a socket line and a `mark://` URL *produce the same
/// effects* — plan §5's test — without putting a window on screen.
@MainActor
public protocol CommandTarget: AnyObject {
    /// A file opens as a tab; a directory moves the sidebar's root (M10).
    func openDocument(at url: URL, background: Bool) throws -> OpenOutcome
    func documentTabs() -> [TabSummary]
    func selectTab(matching selector: TabSelector) throws -> TabSummary
    func closeTab(matching selector: TabSelector) throws -> TabSummary
    /// - Throws: ``CommandFailure`` with `anchor-not-found` when the heading is
    ///   not in the document — ADR-3's own example of a failure the CLI must be
    ///   able to exit non-zero on.
    func scrollSelectedDocument(toAnchor anchor: String) async throws -> TabSummary
    func reloadSelectedDocument() async throws -> Int
    /// M8. The sidebar's root, breadcrumb, and history.
    func sidebarSummary() -> SidebarSummary
    /// M8. Move the root. Throws when the destination is not a readable
    /// directory, or when there is nothing to go back or forward to — a CLI
    /// that pressed ⌘[ at the start of history should exit non-zero, not
    /// silently succeed (ADR-3's reason for having a reply channel at all).
    func navigateSidebar(to target: NavigationTarget) throws -> SidebarSummary
    /// M7. Apply a theme to every tab, or — with `nil` — report the one in
    /// force without changing anything.
    ///
    /// - Throws: ``CommandFailure`` naming the theme and what is wrong with it.
    ///   A theme that does not resolve leaves the current one alone; the CLI
    ///   exits non-zero and says why, which is the whole point of having a
    ///   reply channel (ADR-3).
    func applyTheme(named name: String?, appearance: ThemeAppearance?) async throws
        -> ThemeSummaryForCLI
}

/// The applied theme, as the CLI sees it.
public struct ThemeSummaryForCLI: Equatable, Sendable {
    public var name: String
    public var kind: String
    public var light: String
    public var dark: String
    /// False when one theme is used for both appearances.
    public var paired: Bool
    /// `"system"`, `"light"`, or `"dark"` — whether the half on screen is
    /// pinned, and to which.
    public var appearance: String
    /// The half on screen right now, by name. Equal to ``name`` unless the
    /// appearance is following a system that disagrees with it.
    public var showing: String
    /// Hydrated tabs the CSS was pushed to. Dehydrated ones need nothing: they
    /// have no DOM, and they come back rendered against the new theme.
    public var applied: Int
    /// Tabs that had to be re-rendered because the incoming theme's scope →
    /// slot map differs. Zero for every theme that ships.
    public var rerendered: Int

    public init(
        name: String, kind: String, light: String, dark: String, paired: Bool,
        appearance: String, showing: String, applied: Int, rerendered: Int
    ) {
        self.name = name
        self.kind = kind
        self.light = light
        self.dark = dark
        self.paired = paired
        self.appearance = appearance
        self.showing = showing
        self.applied = applied
        self.rerendered = rerendered
    }

    public var json: JSONValue {
        .object([
            "name": .string(name),
            "kind": .string(kind),
            "light": .string(light),
            "dark": .string(dark),
            "paired": .bool(paired),
            "appearance": .string(appearance),
            "showing": .string(showing),
            "applied": .int(applied),
            "rerendered": .int(rerendered),
        ])
    }
}

// MARK: - The router

/// Decodes and performs commands, for both entry paths.
@MainActor
public final class CommandRouter {

    /// Resolved per command rather than held, because with more than one window
    /// there is no such thing as "the" target.
    ///
    /// `2026-08-26-multiple-windows-and-split-panes`:
    ///
    /// > Commands act on the **key window**, falling back to the first window
    /// > when none is key.
    ///
    /// Binding a controller once at launch would have meant every `mark open`
    /// landing in the window that happened to exist first, no matter which one
    /// the user was looking at.
    private let resolveTarget: () -> (any CommandTarget)?

    /// The window a command would act on right now.
    public var target: (any CommandTarget)? { resolveTarget() }

    /// Commands performed since launch, for `ping` and the tests.
    public private(set) var commandCount = 0

    /// A router that asks for its target on every command. The app's path.
    public init(_ resolveTarget: @escaping () -> (any CommandTarget)?) {
        self.resolveTarget = resolveTarget
    }

    /// A router bound to one target for its lifetime.
    ///
    /// Every test's path, and correct there: a test that builds one window is
    /// entitled to assume commands reach it. Held weakly, matching the property
    /// this replaced — a router must not keep a closed window alive.
    public convenience init(target: (any CommandTarget)? = nil) {
        weak let weakTarget = target
        self.init { weakTarget }
    }

    // MARK: Entry path 1 — the socket

    /// One NDJSON request line in, one response line out.
    public func handle(line: String) async -> String {
        let started = DispatchTime.now().uptimeNanoseconds
        let request: CommandRequest
        do {
            request = try CommandRequest.decode(line: line)
        } catch let failure as CommandFailure {
            Log.ipc.error("malformed request: \(failure.message, privacy: .public)")
            return CommandResponse.failed(id: nil, failure).encoded()
        } catch {
            return CommandResponse.failed(
                id: nil, CommandFailure(.malformedRequest, String(describing: error))
            ).encoded()
        }

        let response = await handle(request)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        // Plan §4: command name and duration, never file *contents*. The path
        // an `open` carries is an argument, not content, and without it the
        // log cannot answer "which document did it open".
        Log.ipc.debug(
            "\(request.name, privacy: .public) -> \(response.ok ? "ok" : (response.failure?.code.rawValue ?? "error"), privacy: .public) in \(elapsed, privacy: .public) ms"
        )
        return response.encoded()
    }

    // MARK: Entry path 2 — mark://

    /// Handle a `mark://` URL. No reply channel, so failures go to the log.
    ///
    /// ADR-3 keeps this registered *"even if the socket becomes the only
    /// transport used in practice — it is the cold-launch and Finder path"*.
    @discardableResult
    public func handle(url: URL) async -> CommandResponse {
        let request: CommandRequest
        do {
            request = try CommandRequest.decode(url: url)
        } catch let failure as CommandFailure {
            Log.ipc.error("\(url.absoluteString, privacy: .public): \(failure.message, privacy: .public)")
            return .failed(id: nil, failure)
        } catch {
            return .failed(id: nil, CommandFailure(.malformedRequest, String(describing: error)))
        }

        let response = await handle(request)
        if let failure = response.failure {
            Log.ipc.error(
                "mark:// \(request.name, privacy: .public) failed: \(failure.code.rawValue, privacy: .public) \(failure.message, privacy: .public)"
            )
        } else {
            Log.ipc.info("mark:// \(request.name, privacy: .public) ok")
        }
        return response
    }

    // MARK: The shared middle

    /// Version check, decode, perform. Everything above this point is framing.
    public func handle(_ request: CommandRequest) async -> CommandResponse {
        // ADR-3: the version is checked before the command name, so a client
        // from the future is told the truth ("I speak 1") rather than being
        // told its perfectly good command does not exist.
        guard request.version == MarkProtocol.version else {
            let failure = CommandFailure(
                .unsupportedVersion,
                "this mark speaks protocol version \(MarkProtocol.version); the request said \(request.version)",
                detail: [
                    "expected": .int(MarkProtocol.version),
                    "received": .int(request.version),
                ]
            )
            Log.ipc.error(
                "refused protocol version \(request.version, privacy: .public) (this build speaks \(MarkProtocol.version, privacy: .public))"
            )
            return .failed(id: request.id, failure)
        }

        let command: Command
        do {
            command = try Command.make(name: request.name, arguments: request.arguments)
        } catch let failure as CommandFailure {
            return .failed(id: request.id, failure)
        } catch {
            return .failed(id: request.id, CommandFailure(.internalError, String(describing: error)))
        }

        do {
            let result = try await perform(command)
            return .success(id: request.id, result)
        } catch let failure as CommandFailure {
            return .failed(id: request.id, failure)
        } catch {
            return .failed(id: request.id, CommandFailure(.internalError, String(describing: error)))
        }
    }

    /// Perform a decoded command. The one place a ``Command`` has an effect.
    public func perform(_ command: Command) async throws -> [String: JSONValue] {
        commandCount += 1
        let state = Log.signposter.beginInterval("ipc command")
        defer { Log.signposter.endInterval("ipc command", state) }

        guard let target else {
            throw CommandFailure(.internalError, "the app has no window to act on")
        }

        switch command {
        case .ping:
            return [
                "app": .string(Bundle.main.bundleURL.path),
                "bundleIdentifier": .string(Bundle.main.bundleIdentifier ?? "none"),
                "pid": .int(Int(ProcessInfo.processInfo.processIdentifier)),
                "core": .string((try? MarkCore.version()) ?? "unavailable"),
                // `mark doctor` prints this next to its own. A CLI and an app
                // from different installs is the failure this makes visible,
                // and until now the only symptom was behaviour that did not
                // match the code in front of you.
                "build": .string(BuildInfo.summary),
                "socket": .string(socketPathForReport),
                "tabs": .int(target.documentTabs().count),
                // Resident web views that no tab owns — today, the markdown
                // reference's window (`2026-08-26-markdown-reference-window`).
                // `mark doctor` derives the memory formula from `tab-list`,
                // which by construction cannot see one, so without this the
                // report is short by ~52 MB whenever the reference is open.
                //
                // Read from the shared governor rather than from `target`: the
                // budget is the application's, not the key window's, and there
                // is one of it.
                "auxiliaryWebViews": .int(ResidencyGovernor.shared.auxiliaryWebViews),
                "commands": .int(commandCount),
            ]

        case .open(let path, let background):
            let url = Self.fileURL(from: path)
            let tabs = { JSONValue.int(target.documentTabs().count) }
            switch try target.openDocument(at: url, background: background) {
            case .tab(let tab):
                return ["tab": tab.json, "tabs": tabs()]
            case .sidebar(let sidebar):
                // Deliberately the same key `nav` and `sidebar` answer under,
                // so a caller that already understands one understands this.
                return ["sidebar": sidebar.json, "tabs": tabs()]
            }

        case .tabList:
            return ["tabs": .array(target.documentTabs().map(\.json))]

        case .tabSelect(let selector):
            return ["tab": try target.selectTab(matching: selector).json]

        case .tabClose(let selector):
            let closed = try target.closeTab(matching: selector)
            return ["closed": closed.json, "tabs": .int(target.documentTabs().count)]

        case .theme(let name, let appearance):
            let applied = try await target.applyTheme(named: name, appearance: appearance)
            return [
                "theme": applied.json,
                "tabs": .int(target.documentTabs().count),
            ]

        case .goTo(let anchor):
            let tab = try await target.scrollSelectedDocument(toAnchor: anchor)
            return ["anchor": .string(anchor), "tab": tab.json]

        case .sidebar:
            return ["sidebar": target.sidebarSummary().json]

        case .navigate(let where_):
            return ["sidebar": try target.navigateSidebar(to: where_).json]

        case .reload:
            let blocks = try await target.reloadSelectedDocument()
            var result: [String: JSONValue] = ["blocks": .int(blocks)]
            if let selected = target.documentTabs().first(where: \.selected) {
                result["tab"] = selected.json
            }
            return result
        }
    }

    /// A path the CLI handed us, which may be relative to *its* working
    /// directory — so `mark-cli` always sends an absolute one. Expanding `~`
    /// here as well costs nothing and makes a hand-written `mark://` URL work.
    static func fileURL(from path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    /// For `ping`. Never throws: a report is not the place to discover the
    /// path is unusable, and by the time anything can ping us the server is
    /// already bound.
    private var socketPathForReport: String {
        (try? SocketPath.resolve()) ?? "unresolvable"
    }
}
