import Foundation
import Testing

@testable import MarkKit

/// Plan §5: *"`CommandRouter` decodes the same `Command` from a socket line and
/// from a `mark://` URL, and the two produce identical effects."*
///
/// That test is the whole reason this file exists, because it is the assertion
/// ADR-3's warning turns into:
///
/// > there are now **two** entry paths into the same commands (socket and
/// > URL), which must not drift
///
/// Drift here is not a crash. It is `mark://open?path=…` quietly opening in a
/// new tab while `mark open` reuses one, six months from now, for a reason
/// nobody remembers.
@Suite("CommandRouter — one command type, two entry paths")
@MainActor
struct CommandRouterTests {

    // MARK: - Decoding

    /// Every command, decoded from both doors, asserted equal.
    @Test("a socket line and a mark:// URL decode to the same Command")
    func bothDoorsAgree() throws {
        let cases: [(line: String, url: String, expected: Command)] = [
            (
                #"{"version":1,"command":"open","arguments":{"path":"/n.md"}}"#,
                "mark://open?path=/n.md",
                .open(path: "/n.md", background: false)
            ),
            (
                #"{"version":1,"command":"open","arguments":{"path":"/n.md","tab":true}}"#,
                "mark://open?path=/n.md&tab=1",
                .open(path: "/n.md", background: true)
            ),
            (
                #"{"version":1,"command":"tab-list","arguments":{}}"#,
                "mark://tab-list",
                .tabList
            ),
            (
                #"{"version":1,"command":"tab-select","arguments":{"index":2}}"#,
                "mark://tab-select?index=2",
                .tabSelect(.index(2))
            ),
            (
                #"{"version":1,"command":"tab-select","arguments":{"path":"/n.md"}}"#,
                "mark://tab-select?path=/n.md",
                .tabSelect(.path("/n.md"))
            ),
            (
                #"{"version":1,"command":"tab-close","arguments":{}}"#,
                "mark://tab-close",
                .tabClose(.selected)
            ),
            (
                #"{"version":1,"command":"theme","arguments":{"name":"dracula"}}"#,
                "mark://theme?name=dracula",
                .theme(name: "dracula")
            ),
            (
                ##"{"version":1,"command":"goto","arguments":{"anchor":"#install"}}"##,
                "mark://goto?anchor=%23install",
                .goTo(anchor: "install")
            ),
            (
                #"{"version":1,"command":"reload","arguments":{}}"#,
                "mark://reload",
                .reload
            ),
            (
                #"{"version":1,"command":"sidebar","arguments":{}}"#,
                "mark://sidebar",
                .sidebar
            ),
            (
                #"{"version":1,"command":"nav","arguments":{"path":"/notes"}}"#,
                "mark://nav?path=/notes",
                .navigate(.path("/notes"))
            ),
            (
                #"{"version":1,"command":"nav","arguments":{"to":"parent"}}"#,
                "mark://nav?to=parent",
                .navigate(.parent)
            ),
            (
                #"{"version":1,"command":"nav","arguments":{"to":"back"}}"#,
                "mark://nav?to=back",
                .navigate(.back)
            ),
        ]

        for (line, url, expected) in cases {
            let fromSocket = try CommandRequest.decode(line: line)
            let fromURL = try CommandRequest.decode(url: #require(URL(string: url)))
            #expect(fromSocket.name == fromURL.name, "\(line) vs \(url)")
            // The argument *map* may differ in spelling — JSON's `true` and a
            // URL's `tab=1` are both true, and neither is more correct. What
            // must not differ is the `Command` they produce, which is the type
            // ADR-3 says the two entry paths have to share.

            let socketCommand = try Command.make(
                name: fromSocket.name, arguments: fromSocket.arguments)
            let urlCommand = try Command.make(name: fromURL.name, arguments: fromURL.arguments)
            #expect(socketCommand == expected, "\(line)")
            #expect(urlCommand == expected, "\(url)")
        }
    }

    /// Every command name round-trips, so `Command.name` and `Command.make`
    /// cannot drift from each other either — that pair is what the CLI's own
    /// command strings are checked against by hand today.
    @Test("every known command name decodes to a command that reports the same name")
    func namesRoundTrip() throws {
        let arguments = [
            "open": ["path": "/n.md"],
            "tab-select": ["index": "0"],
            "goto": ["anchor": "x"],
            "theme": ["list": "1"],
            "nav": ["to": "parent"],
        ]
        for name in Command.knownNames {
            let command = try Command.make(name: name, arguments: arguments[name] ?? [:])
            #expect(command.name == name)
        }
    }

    @Test("a URL's booleans and a JSON body's booleans mean the same thing")
    func flagCoercion() throws {
        // `?tab` with no value at all, which is how a hand-written URL looks.
        let bare = try CommandRequest.decode(url: #require(URL(string: "mark://open?path=/n.md&tab")))
        #expect(try Command.make(name: bare.name, arguments: bare.arguments)
            == .open(path: "/n.md", background: true))

        let explicitFalse = try CommandRequest.decode(
            line: #"{"version":1,"command":"open","arguments":{"path":"/n.md","tab":false}}"#)
        #expect(try Command.make(name: explicitFalse.name, arguments: explicitFalse.arguments)
            == .open(path: "/n.md", background: false))
    }

    @Test("mark:open with no slashes decodes too")
    func schemeWithoutAuthority() throws {
        let request = try CommandRequest.decode(url: #require(URL(string: "mark:reload")))
        #expect(request.name == "reload")
    }

    // MARK: - The version constraint

    /// ADR-3: *"Every socket command carries a protocol version, and the app
    /// must respond intelligibly to a version it does not know."*
    @Test("an unknown protocol version is a structured refusal, not a parse failure")
    func versionMismatch() async throws {
        let target = FakeCommandTarget()
        let router = CommandRouter(target: target)
        let response = await router.handle(
            line: #"{"version":99,"id":"7","command":"open","arguments":{"path":"/n.md"}}"#)

        let json = try decode(response)
        #expect(json["ok"] as? Bool == false)
        #expect(json["id"] as? String == "7")
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["code"] as? String == "unsupported-version")
        #expect(error["expected"] as? Int == MarkProtocol.version)
        #expect(error["received"] as? Int == 99)
        // The message has to be readable by a person, not only by a switch
        // statement: this is what an agent puts in front of a user.
        let message = try #require(error["message"] as? String)
        #expect(message.contains("99") && message.contains("\(MarkProtocol.version)"))
    }

    /// The version is checked *before* the command, so a future CLI is told the
    /// truth rather than "unknown command".
    @Test("a future version of a command we do not have still reports the version")
    func versionBeatsUnknownCommand() async throws {
        let target = FakeCommandTarget()
        let router = CommandRouter(target: target)
        let response = await router.handle(
            line: #"{"version":2,"command":"split-pane","arguments":{}}"#)
        let error = try #require(try decode(response)["error"] as? [String: Any])
        #expect(error["code"] as? String == "unsupported-version")
    }

    @Test("a request with no version at all is refused the same way")
    func missingVersion() async throws {
        let target = FakeCommandTarget()
        let router = CommandRouter(target: target)
        let response = await router.handle(line: #"{"command":"reload"}"#)
        let error = try #require(try decode(response)["error"] as? [String: Any])
        #expect(error["code"] as? String == "unsupported-version")
        #expect(error["received"] as? Int == 0)
    }

    // MARK: - Malformed input

    @Test("garbage on the socket gets an answer rather than a dropped connection")
    func malformed() async throws {
        let target = FakeCommandTarget()
        let router = CommandRouter(target: target)
        for line in ["not json at all", "[1,2,3]", "{}", #"{"version":1}"#] {
            let json = try decode(await router.handle(line: line))
            #expect(json["ok"] as? Bool == false, "\(line)")
            let error = try #require(json["error"] as? [String: Any], "\(line)")
            #expect(error["code"] as? String == "malformed-request", "\(line)")
        }
    }

    @Test("an unknown command lists the ones that exist")
    func unknownCommand() async throws {
        let target = FakeCommandTarget()
        let router = CommandRouter(target: target)
        let json = try decode(
            await router.handle(line: #"{"version":1,"command":"levitate","arguments":{}}"#))
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["code"] as? String == "unknown-command")
        let known = try #require(error["known"] as? [String])
        #expect(known.contains("open"))
    }

    @Test("a command missing a required argument says which one")
    func missingArgument() async throws {
        let target = FakeCommandTarget()
        let router = CommandRouter(target: target)
        let json = try decode(await router.handle(line: #"{"version":1,"command":"open"}"#))
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["code"] as? String == "bad-arguments")
        #expect((error["message"] as? String)?.contains("path") == true)
    }

    // MARK: - Effects

    /// The other half of plan §5's test: not just "the same `Command`", but
    /// "the same thing happened".
    @Test("the socket and mark:// produce identical effects")
    func identicalEffects() async throws {
        let viaSocket = FakeCommandTarget()
        let viaURL = FakeCommandTarget()

        let socketRouter = CommandRouter(target: viaSocket)
        let urlRouter = CommandRouter(target: viaURL)

        _ = await socketRouter.handle(
            line: #"{"version":1,"command":"open","arguments":{"path":"/a.md"}}"#)
        _ = await urlRouter.handle(url: try #require(URL(string: "mark://open?path=/a.md")))

        _ = await socketRouter.handle(
            line: #"{"version":1,"command":"open","arguments":{"path":"/b.md","tab":true}}"#)
        _ = await urlRouter.handle(url: try #require(URL(string: "mark://open?path=/b.md&tab=1")))

        _ = await socketRouter.handle(
            line: #"{"version":1,"command":"tab-select","arguments":{"index":0}}"#)
        _ = await urlRouter.handle(url: try #require(URL(string: "mark://tab-select?index=0")))

        _ = await socketRouter.handle(line: #"{"version":1,"command":"reload"}"#)
        _ = await urlRouter.handle(url: try #require(URL(string: "mark://reload")))

        // M8's two. `nav to=back` is included on purpose: it is the one command
        // whose result depends on state the *previous* command left behind, so
        // it is where the two doors would drift first if they ever stopped
        // sharing a target.
        _ = await socketRouter.handle(
            line: #"{"version":1,"command":"nav","arguments":{"path":"/tmp"}}"#)
        _ = await urlRouter.handle(url: try #require(URL(string: "mark://nav?path=/tmp")))

        _ = await socketRouter.handle(
            line: #"{"version":1,"command":"nav","arguments":{"to":"back"}}"#)
        _ = await urlRouter.handle(url: try #require(URL(string: "mark://nav?to=back")))

        _ = await socketRouter.handle(line: #"{"version":1,"command":"sidebar"}"#)
        _ = await urlRouter.handle(url: try #require(URL(string: "mark://sidebar")))

        #expect(viaSocket.log == viaURL.log)
        #expect(
            viaSocket.log == [
                "open /a.md foreground",
                "open /b.md background",
                "select index 0",
                "reload",
                "nav /tmp",
                "nav back",
                "sidebar",
            ])
        #expect(viaSocket.navigator.root.path == viaURL.navigator.root.path)
        #expect(viaSocket.navigator.forward.map(\.path) == ["/tmp"])
    }

    /// The sidebar command reports the shape `scripts/session-roundtrip.sh`
    /// reads. A rename here would make that gate silently stop asserting.
    @Test("sidebar reports root, breadcrumb, and both history stacks")
    func sidebarResult() async throws {
        let target = FakeCommandTarget()
        let router = CommandRouter(target: target)
        _ = await router.handle(line: #"{"version":1,"command":"nav","arguments":{"to":"parent"}}"#)
        let json = try decode(await router.handle(line: #"{"version":1,"command":"sidebar"}"#))

        #expect(json["ok"] as? Bool == true)
        let result = try #require(json["result"] as? [String: Any])
        let sidebar = try #require(result["sidebar"] as? [String: Any])
        #expect(sidebar["root"] as? String == "/tmp/mark-fake")
        #expect(sidebar["breadcrumb"] as? [String] == ["/", "tmp", "mark-fake"])
        #expect(sidebar["back"] as? [String] == ["/tmp/mark-fake/project"])
        #expect(sidebar["forward"] as? [String] == [])
        #expect(sidebar["sort"] as? String == "name")
    }

    /// ADR-3's reason for having a reply channel: the CLI must be able to exit
    /// non-zero. Pressing ⌘[ at the start of history is a real "no".
    @Test("nav with nothing to go back to is refused rather than ignored")
    func navRefusals() async throws {
        let target = FakeCommandTarget()
        let router = CommandRouter(target: target)

        let back = try decode(
            await router.handle(line: #"{"version":1,"command":"nav","arguments":{"to":"back"}}"#))
        #expect(back["ok"] as? Bool == false)

        let nonsense = try decode(
            await router.handle(line: #"{"version":1,"command":"nav","arguments":{"to":"sideways"}}"#))
        let error = try #require(nonsense["error"] as? [String: Any])
        #expect(error["code"] as? String == "bad-arguments")
        #expect((error["message"] as? String)?.contains("sideways") == true)

        let empty = try decode(await router.handle(line: #"{"version":1,"command":"nav"}"#))
        #expect((empty["error"] as? [String: Any])?["code"] as? String == "bad-arguments")
    }

    @Test("a successful open reports the tab it produced")
    func openResult() async throws {
        let target = FakeCommandTarget()
        let router = CommandRouter(target: target)
        let json = try decode(
            await router.handle(
                line: #"{"version":1,"id":"c1","command":"open","arguments":{"path":"/a.md"}}"#))

        #expect(json["ok"] as? Bool == true)
        #expect(json["id"] as? String == "c1")
        let result = try #require(json["result"] as? [String: Any])
        let tab = try #require(result["tab"] as? [String: Any])
        #expect(tab["path"] as? String == "/a.md")
        #expect(tab["index"] as? Int == 0)
        #expect(tab["selected"] as? Bool == true)
    }

    /// ADR-3's own example of the failure the CLI must be able to exit
    /// non-zero on.
    @Test("a missing anchor is anchor-not-found, not a silent success")
    func anchorNotFound() async throws {
        let target = FakeCommandTarget()
        target.anchors = ["install"]
        let router = CommandRouter(target: target)
        _ = await router.handle(line: #"{"version":1,"command":"open","arguments":{"path":"/a.md"}}"#)

        let found = try decode(
            await router.handle(line: ##"{"version":1,"command":"goto","arguments":{"anchor":"#install"}}"##))
        #expect(found["ok"] as? Bool == true)

        let missing = try decode(
            await router.handle(line: #"{"version":1,"command":"goto","arguments":{"anchor":"nope"}}"#))
        #expect(missing["ok"] as? Bool == false)
        let error = try #require(missing["error"] as? [String: Any])
        #expect(error["code"] as? String == "anchor-not-found")
        #expect(error["anchor"] as? String == "nope")
    }

    /// M7. Applying a theme reports what was applied; a name that does not
    /// resolve is refused **by name** and changes nothing.
    @Test("theme applies, reports, and refuses a name that does not exist")
    func theme() async throws {
        let target = FakeCommandTarget()
        let router = CommandRouter(target: target)
        _ = await router.handle(line: #"{"version":1,"command":"open","arguments":{"path":"/a.md"}}"#)

        let applied = try decode(
            await router.handle(
                line: #"{"version":1,"command":"theme","arguments":{"name":"dracula"}}"#))
        #expect(applied["ok"] as? Bool == true)
        let theme = try #require((applied["result"] as? [String: Any])?["theme"] as? [String: Any])
        #expect(theme["name"] as? String == "dracula")
        #expect(theme["kind"] as? String == "dark")
        // Dracula has no base16 light counterpart, so it is used for both
        // appearances — and says so rather than silently pairing with
        // something the user did not ask for.
        #expect(theme["paired"] as? Bool == false)
        #expect(theme["light"] as? String == "dracula")
        #expect(theme["applied"] as? Int == 1)
        #expect(theme["rerendered"] as? Int == 0, "a shipped theme needs no re-render")

        // No name is "what is applied?", not an error.
        let reported = try decode(
            await router.handle(line: #"{"version":1,"command":"theme","arguments":{}}"#))
        let current = try #require((reported["result"] as? [String: Any])?["theme"] as? [String: Any])
        #expect(current["name"] as? String == "dracula")

        // And a name that does not resolve leaves it alone, with a reason.
        let refused = try decode(
            await router.handle(
                line: #"{"version":1,"command":"theme","arguments":{"name":"no-such-theme"}}"#))
        let error = try #require(refused["error"] as? [String: Any])
        #expect(error["code"] as? String == "bad-arguments")
        let message = try #require(error["message"] as? String)
        #expect(message.contains("no theme named"), "\(message)")
        #expect(target.appliedTheme == "dracula", "a refused theme was applied anyway")
    }

    /// A paired theme carries both halves, which is what makes an appearance
    /// switch need no round trip at all.
    @Test("a paired theme reports both halves")
    func pairedTheme() async throws {
        let target = FakeCommandTarget()
        let router = CommandRouter(target: target)
        let applied = try decode(
            await router.handle(
                line: #"{"version":1,"command":"theme","arguments":{"name":"gruvbox-dark"}}"#))
        let theme = try #require((applied["result"] as? [String: Any])?["theme"] as? [String: Any])
        #expect(theme["paired"] as? Bool == true)
        #expect(theme["light"] as? String == "gruvbox-light")
        #expect(theme["dark"] as? String == "gruvbox-dark")
    }

    @Test("a tab index that does not exist is tab-not-found with the count")
    func tabNotFound() async throws {
        let target = FakeCommandTarget()
        let router = CommandRouter(target: target)
        _ = await router.handle(line: #"{"version":1,"command":"open","arguments":{"path":"/a.md"}}"#)

        let json = try decode(
            await router.handle(line: #"{"version":1,"command":"tab-select","arguments":{"index":9}}"#))
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["code"] as? String == "tab-not-found")
        #expect(error["tabs"] as? Int == 1)
    }

    @Test("ping reports enough to identify which app answered")
    func ping() async throws {
        let target = FakeCommandTarget()
        let router = CommandRouter(target: target)
        let result = try #require(
            try decode(await router.handle(line: #"{"version":1,"command":"ping"}"#))["result"]
                as? [String: Any])
        #expect(result["pid"] as? Int == Int(ProcessInfo.processInfo.processIdentifier))
        #expect((result["socket"] as? String)?.contains("mark-") == true)
        #expect(result["tabs"] as? Int == 0)
    }

    /// A `mark://` URL that names nothing is a log line, not a crash — it is
    /// the one entry path a stranger can point at us.
    @Test("a nonsense mark:// URL is refused without a reply channel")
    func nonsenseURL() async throws {
        let target = FakeCommandTarget()
        let router = CommandRouter(target: target)
        let response = await router.handle(url: try #require(URL(string: "mark://")))
        #expect(response.ok == false)
        #expect(response.failure?.code == .malformedRequest)
    }

    // MARK: - Helpers

    private func decode(_ line: String) throws -> [String: Any] {
        let data = try #require(line.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// A ``CommandTarget`` that records rather than does.
///
/// The point is the ``log``: two routers driven through different doors must
/// produce identical logs, which is a stronger statement than "they decoded to
/// the same enum" and is the one that would actually catch drift.
@MainActor
final class FakeCommandTarget: CommandTarget {

    private(set) var log: [String] = []
    private(set) var tabs: [TabSummary] = []
    var anchors: Set<String> = []
    var reloadedBlocks = 12

    func openDocument(at url: URL, background: Bool) throws -> OpenOutcome {
        log.append("open \(url.path) \(background ? "background" : "foreground")")
        // The real window decides file-or-directory from the filesystem, so
        // this does too: a fake that decided from the path string would agree
        // with itself and prove nothing about `mark open <dir>`.
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            return .sidebar(try navigateSidebar(to: .path(url.path)))
        }
        if let existing = tabs.firstIndex(where: { $0.path == url.path }) {
            if !background { select(existing) }
            return .tab(tabs[existing])
        }
        let summary = TabSummary(
            index: tabs.count, path: url.path, title: url.lastPathComponent,
            selected: false, resident: true)
        tabs.append(summary)
        if !background || tabs.count == 1 { select(tabs.count - 1) }
        return .tab(tabs[tabs.count - 1])
    }

    func documentTabs() -> [TabSummary] { tabs }

    func selectTab(matching selector: TabSelector) throws -> TabSummary {
        let index = try resolve(selector)
        switch selector {
        case .index(let value): log.append("select index \(value)")
        case .path(let value): log.append("select path \(value)")
        case .selected: log.append("select selected")
        }
        select(index)
        return tabs[index]
    }

    func closeTab(matching selector: TabSelector) throws -> TabSummary {
        let index = try resolve(selector)
        log.append("close \(tabs[index].path)")
        let closed = tabs.remove(at: index)
        for position in tabs.indices { tabs[position].index = position }
        if !tabs.isEmpty && !tabs.contains(where: \.selected) { select(0) }
        return closed
    }

    func scrollSelectedDocument(toAnchor anchor: String) async throws -> TabSummary {
        log.append("goto \(anchor)")
        guard let selected = tabs.first(where: \.selected) else {
            throw CommandFailure(.noDocument, "no document is open")
        }
        guard anchors.contains(anchor) else {
            throw CommandFailure(
                .anchorNotFound, "no anchor \"\(anchor)\"",
                detail: ["anchor": .string(anchor)])
        }
        return selected
    }

    func reloadSelectedDocument() async throws -> Int {
        log.append("reload")
        return reloadedBlocks
    }

    // MARK: M7's themes

    /// The real controller, not a stub: `mark theme nosuch` has to fail the way
    /// it will in the app, which means the core resolving the name.
    var appliedTheme = ThemeController.shared.name

    func applyTheme(named name: String?) async throws -> ThemeSummaryForCLI {
        log.append("theme \(name ?? "-")")
        let resolved: ResolvedTheme
        if let name {
            do {
                resolved = try MarkCore.theme(named: name)
            } catch {
                throw CommandFailure(
                    .badArguments, String(describing: error),
                    detail: ["theme": .string(name)])
            }
            appliedTheme = resolved.name
        } else {
            resolved = try MarkCore.theme(named: appliedTheme)
        }
        return ThemeSummaryForCLI(
            name: resolved.name, kind: resolved.kind.rawValue,
            light: resolved.light.name, dark: resolved.dark.name,
            paired: resolved.paired, applied: tabs.count, rerendered: 0)
    }

    // MARK: M8's sidebar

    /// A ``Navigator`` rather than a stub, so the two doors are compared
    /// against the real history semantics: a fake that just recorded the call
    /// would agree with itself about `nav to=back` and prove nothing.
    let navigator = Navigator(root: URL(fileURLWithPath: "/tmp/mark-fake/project"))

    func sidebarSummary() -> SidebarSummary {
        log.append("sidebar")
        return summary()
    }

    func navigateSidebar(to target: NavigationTarget) throws -> SidebarSummary {
        log.append("nav \(target.argument)")
        let moved: Bool
        switch target {
        case .path(let path): moved = navigator.go(to: URL(fileURLWithPath: path))
        case .parent: moved = navigator.goToParent()
        case .back: moved = navigator.goBack()
        case .forward: moved = navigator.goForward()
        }
        guard moved else {
            throw CommandFailure(.unsupported, "the sidebar did not move")
        }
        return summary()
    }

    private func summary() -> SidebarSummary {
        SidebarSummary(
            root: navigator.root.path,
            breadcrumb: navigator.breadcrumb.map(\.name),
            back: navigator.back.map(\.path),
            forward: navigator.forward.map(\.path),
            showsNonMarkdown: false,
            showsHidden: false,
            sort: TreeSort.name.rawValue,
            filter: ""
        )
    }

    private func select(_ index: Int) {
        for position in tabs.indices { tabs[position].selected = position == index }
    }

    private func resolve(_ selector: TabSelector) throws -> Int {
        switch selector {
        case .selected:
            guard let index = tabs.firstIndex(where: \.selected) else {
                throw CommandFailure(.noDocument, "no document is open")
            }
            return index
        case .index(let index):
            guard tabs.indices.contains(index) else {
                throw CommandFailure(
                    .tabNotFound, "there is no tab \(index)",
                    detail: ["index": .int(index), "tabs": .int(tabs.count)])
            }
            return index
        case .path(let path):
            guard let index = tabs.firstIndex(where: { $0.path == path }) else {
                throw CommandFailure(
                    .tabNotFound, "no tab is open on \(path)",
                    detail: ["path": .string(path)])
            }
            return index
        }
    }
}
