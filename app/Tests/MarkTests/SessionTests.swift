import AppKit
import Foundation
import Testing

@testable import MarkKit

/// Plan §5: *"Session round-trip: serialize, restore, assert tab order and
/// scroll offsets."* Plus the two ADR-4 constraints that are about what we
/// must **not** do.
@Suite("Session — ADR-4's own JSON file")
@MainActor
struct SessionTests {

    // MARK: - Round trip

    @Test("a session round-trips tab order, selection, and scroll offsets")
    func roundTrip() throws {
        let harness = try TabHarness()
        let fixture = harness.fixture
        let store = harness.store
        harness.openAll(try fixture.makeDocuments(count: 5))
        store.move(from: 0, to: 4)
        store.select(index: 2)
        // Through the page's real `scroll` message, because that is the only
        // writer in production: ``TabStore/snapshot(sidebarRoot:)`` prefers the
        // live view's offset over the tab's cached one, so a test that poked
        // the tab directly would assert against a value the app never uses.
        for (offset, tab) in store.tabs.enumerated() {
            harness.reportScroll(Double(offset) * 137, on: tab)
        }

        let snapshot = store.snapshot(sidebarRoot: fixture.directory)
        try fixture.session.save(snapshot)
        let loaded = try #require(try fixture.session.load())
        #expect(loaded == snapshot)

        let restored = try TabHarness()
        let restoredStore = restored.store
        restoredStore.restore(loaded)

        #expect(restoredStore.tabs.map(\.url) == store.tabs.map(\.url))
        #expect(restoredStore.tabs.map(\.scrollOffset) == store.tabs.map(\.scrollOffset))
        #expect(restoredStore.selectedIndex == 2)
        #expect(restoredStore.selected?.url == store.selected?.url)
    }

    @Test("which tab was the preview tab survives a relaunch")
    func previewRoundTrips() throws {
        let harness = try TabHarness(files: ["a.md", "b.md"])
        harness.store.open(harness.file(named: "c.md"), preview: true)

        let snapshot = harness.store.snapshot(sidebarRoot: harness.fixture.directory)
        #expect(snapshot.tabs.map(\.preview) == [false, false, true])
        try harness.fixture.session.save(snapshot)
        let loaded = try #require(try harness.fixture.session.load())

        let restored = try TabHarness()
        restored.store.restore(loaded)
        #expect(restored.store.tabs.map(\.isPreview) == [false, false, true])
        #expect(restored.store.previewTab?.title == "c.md")

        // And the slot still works after the relaunch, rather than the restored
        // tab being italic but permanent.
        restored.store.open(restored.file(named: "d.md"), preview: true)
        #expect(restored.store.tabs.map(\.title) == ["a.md", "b.md", "d.md"])
    }

    /// The compatibility case that would otherwise lose every tab: `preview`
    /// is a field older builds never wrote, and Swift's synthesized decoder
    /// throws on a missing `Bool` rather than using the property's default.
    @Test("a session file written before preview tabs existed still decodes")
    func previewIsOptionalInTheFile() throws {
        let json = #"{"version":1,"tabs":[{"path":"/tmp/a.md","scrollOffset":12,"title":"A"}],"selectedIndex":0}"#
        let decoded = try JSONDecoder().decode(SessionState.self, from: Data(json.utf8))
        #expect(decoded.tabs.count == 1)
        #expect(decoded.tabs[0].preview == false)
        #expect(decoded.tabs[0].scrollOffset == 12)
    }

    /// *At most one preview tab* is this type's invariant, not a hope about the
    /// file it reads. Two of them means the next single click replaces one and
    /// strands the other in italics for good.
    @Test("a session naming two preview tabs restores one, and keeps the other")
    func twoPreviewTabsInTheFile() throws {
        let harness = try TabHarness()
        harness.store.restore(
            SessionState(
                tabs: [
                    SessionTab(path: harness.file(named: "a.md").path, preview: true),
                    SessionTab(path: harness.file(named: "b.md").path, preview: true),
                ],
                selectedIndex: 0
            ))
        #expect(harness.store.count == 2, "no document may be dropped to fix the invariant")
        #expect(harness.store.tabs.map(\.isPreview) == [true, false])
    }

    /// The property that makes restore cheap. A session with a hundred tabs
    /// must not cost a hundred web views on launch.
    @Test("restoring hydrates only the selected tab")
    func restoreHydratesOne() throws {
        let fixture = try TabFixture()
        let urls = try fixture.makeDocuments(count: 12)
        let state = SessionState(
            tabs: urls.map { SessionTab(path: $0.path, scrollOffset: 42) },
            selectedIndex: 5,
            sidebarRoot: fixture.directory.path
        )
        let harness2 = try TabHarness()
        let (store, hydrator) = (harness2.store, harness2.hydrator)
        store.restore(state)

        #expect(store.count == 12)
        #expect(store.residentCount == 1)
        #expect(hydrator.hydrated == [urls[5]])
        #expect(hydrator.restoredOffsets == [42])
    }

    /// Dropping a missing file shifts every index after it, so restoring the
    /// selection by index alone would silently open the wrong document.
    @Test("a session whose files have moved restores the survivors and the right selection")
    func missingFilesAreDropped() throws {
        let fixture = try TabFixture()
        let urls = try fixture.makeDocuments(count: 4)
        try FileManager.default.removeItem(at: urls[0])
        try FileManager.default.removeItem(at: urls[1])

        let state = SessionState(
            tabs: urls.map { SessionTab(path: $0.path) },
            selectedIndex: 3,
            sidebarRoot: nil
        )
        let harness2 = try TabHarness()
        let store = harness2.store
        store.restore(state)

        #expect(store.tabs.map(\.url) == [urls[2], urls[3]])
        #expect(store.selected?.url == urls[3], "selection followed the path, not the index")
    }

    @Test("the sidebar root survives a relaunch")
    func sidebarRootRoundTrips() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        controller.open(fixture.file(named: "a.md"))
        let snapshot = controller.sessionSnapshot()
        #expect(snapshot.sidebarRoot == fixture.directory.path)

        let relaunched = MainWindowController(
            root: FileManager.default.temporaryDirectory, session: fixture.session)
        relaunched.restore(snapshot)
        #expect(relaunched.sidebar.root.standardizedFileURL == fixture.directory.standardizedFileURL)
        #expect(relaunched.tabs.tabs.map(\.title) == ["a.md"])
        // The tree follows the front document (issue #7), and a restore is the
        // first switch of the launch — so a relaunch comes back with the
        // reopened document selected rather than with nothing selected.
        #expect(relaunched.sidebar.selectedNode?.url.lastPathComponent == "a.md")
    }

    /// The M8 gate: *"breadcrumb, root, and history survive a session
    /// restore"*. The breadcrumb is derived from the root, so what has to
    /// survive on top of it is the **history** — without it a relaunch comes
    /// back in the right place with ⌘[ pointing at nothing, which reads as
    /// "it forgot" rather than as a missing feature.
    @Test("the sidebar's history, toggles, and sort survive a relaunch too")
    func sidebarHistoryRoundTrips() throws {
        let fixture = try TabFixture()
        let nested = fixture.directory.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        controller.open(fixture.file(named: "a.md"))
        controller.sidebar.navigate(to: nested)
        controller.sidebar.navigateToParent()
        controller.sidebar.navigateBack()
        controller.sidebar.listingOptions.showsHidden = true
        controller.sidebar.sort = .modified

        let snapshot = controller.sessionSnapshot()
        #expect(snapshot.sidebarRoot == nested.path)
        #expect(snapshot.sidebarBack == [fixture.directory.path])
        #expect(snapshot.sidebarForward == [fixture.directory.path])
        #expect(snapshot.sidebarOptions?.showsHidden == true)
        #expect(snapshot.sidebarOptions?.sort == "modified")

        // Through the file, not just the struct: the gate is about a relaunch.
        try fixture.session.save(snapshot)
        let reloaded = try #require(try fixture.session.load())

        let relaunched = MainWindowController(
            root: FileManager.default.temporaryDirectory, session: fixture.session)
        relaunched.restore(reloaded)
        #expect(relaunched.sidebar.root.path == nested.path)
        #expect(relaunched.sidebar.navigator.back.map(\.path) == [fixture.directory.path])
        #expect(relaunched.sidebar.navigator.forward.map(\.path) == [fixture.directory.path])
        #expect(relaunched.sidebar.navigator.canGoBack)
        #expect(relaunched.sidebar.listingOptions.showsHidden)
        #expect(relaunched.sidebar.sort == .modified)
        #expect(relaunched.sidebar.breadcrumbBar.crumbTitles.last == "sub")
    }

    /// M10. M9 shipped the pane without this, so a relaunch came back
    /// read-only however long you had been editing.
    @Test("the editor pane's visibility survives a relaunch")
    func editorVisibilityRoundTrips() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        controller.open(fixture.file(named: "a.md"))
        #expect(controller.sessionSnapshot().editorVisible == false, "ADR-6's default")

        controller.setEditorVisible(true)
        let snapshot = controller.sessionSnapshot()
        #expect(snapshot.editorVisible == true)

        try fixture.session.save(snapshot)
        let reloaded = try #require(try fixture.session.load())
        let relaunched = MainWindowController(
            root: fixture.directory, session: fixture.session)
        relaunched.restore(reloaded)
        #expect(relaunched.isEditorVisible, "the relaunch came back read-only")
        // Shown *and* bound: a visible pane with no buffer behind it is a
        // read-only rectangle, which is the same failure with a nicer look.
        #expect(relaunched.tabs.selected?.buffer != nil)
    }

    /// A session that was never edited restores no pane, and a session with no
    /// tabs restores none either — an editor bound to nothing has nothing to
    /// show.
    @Test("a hidden editor pane stays hidden, and no tabs means no pane")
    func editorVisibilityDefaults() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        controller.restore(SessionState(sidebarRoot: fixture.directory.path))
        #expect(!controller.isEditorVisible)

        let tabless = MainWindowController(root: fixture.directory, session: fixture.session)
        tabless.restore(
            SessionState(sidebarRoot: fixture.directory.path, editorVisible: true))
        #expect(!tabless.isEditorVisible)
    }

    /// Additive optional fields, so a session written before M8 still restores
    /// rather than being refused for a version that did not change.
    @Test("a session file with no sidebar history decodes to no history")
    func preM8SessionStillDecodes() throws {
        let json = """
            {"version":1,"tabs":[],"selectedIndex":null,"sidebarRoot":"/tmp"}
            """
        let state = try JSONDecoder().decode(SessionState.self, from: Data(json.utf8))
        #expect(state.sidebarRoot == "/tmp")
        #expect(state.sidebarBack == nil)
        #expect(state.sidebarOptions == nil)
        // M10's field is optional for the same reason, and absent means the
        // read-only default rather than a decode failure that costs the tabs.
        #expect(state.editorVisible == nil)

        // And a partial options object falls back rather than throwing, which
        // would cost the user every tab.
        let partial = """
            {"version":1,"tabs":[],"sidebarRoot":"/tmp","sidebarOptions":{"showsHidden":true}}
            """
        let decoded = try JSONDecoder().decode(SessionState.self, from: Data(partial.utf8))
        #expect(decoded.sidebarOptions?.showsHidden == true)
        #expect(decoded.sidebarOptions?.showsNonMarkdown == false)
        #expect(decoded.sidebarOptions?.sort == "name")
    }

    // MARK: - Failure modes

    @Test("no session file yet is nil, not an error")
    func missingFileIsNil() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mark-no-such-session-\(UUID().uuidString).json")
        #expect(try Session(url: url).load() == nil)
    }

    /// Starting empty because the JSON drifted is the kind of data loss that
    /// gets reported as "it forgot my tabs" with no way to find out why.
    @Test("a corrupt session file is a named error, not a silent empty start")
    func corruptFileThrows() throws {
        let fixture = try TabFixture()
        let url = fixture.directory.appendingPathComponent("broken.json")
        try "{ this is not json".write(to: url, atomically: true, encoding: .utf8)
        let session = Session(url: url)
        #expect(throws: SessionError.self) { try session.load() }
        #expect(session.loadOrLogging() == nil, "the launch path still starts")
    }

    @Test("a session from a future version is refused rather than half-read")
    func futureVersionRefused() throws {
        let fixture = try TabFixture()
        let url = fixture.directory.appendingPathComponent("future.json")
        try #"{"version":99,"tabs":[],"selectedIndex":null,"sidebarRoot":null}"#
            .write(to: url, atomically: true, encoding: .utf8)
        do {
            _ = try Session(url: url).load()
            Issue.record("a version-99 session was accepted")
        } catch let error as SessionError {
            guard case .unsupportedVersion(_, let found, let expected) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(found == 99)
            #expect(expected == SessionState.currentVersion)
        }
    }

    // MARK: - The constraints ADR-4 states as prohibitions

    /// > **Session state lives in our own file**, not `NSWindowRestoration`,
    /// > and `NSQuitAlwaysKeepsWindows` is a user preference we must not write.
    ///
    /// That default belongs to the user's System Settings checkbox. An app that
    /// flips it to make its own restore work has changed the behaviour of every
    /// other app on the machine.
    @Test("nothing in the session path writes NSQuitAlwaysKeepsWindows")
    func neverWritesQuitAlwaysKeepsWindows() throws {
        let key = "NSQuitAlwaysKeepsWindows"
        let before = UserDefaults.standard.object(forKey: key)

        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        controller.open(fixture.file(named: "a.md"))
        controller.saveSessionNow()
        _ = try fixture.session.load()

        let after = UserDefaults.standard.object(forKey: key)
        #expect(
            String(describing: before) == String(describing: after),
            "NSQuitAlwaysKeepsWindows changed from \(String(describing: before)) to \(String(describing: after))"
        )
    }

    /// The source-level half of the same rule. A future edit that reaches for
    /// `UserDefaults` to "make restore work" trips this rather than shipping.
    @Test("the app source never mentions NSQuitAlwaysKeepsWindows or NSWindowRestoration")
    func sourceIsFreeOfTheForbiddenMechanisms() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MarkTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // app
            .appendingPathComponent("Sources/Mark")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty, "found no Swift sources under \(sources.path)")

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            // Comments explaining *why* we do not use these are allowed and
            // wanted; a `set(...forKey:)` or a restoration-class registration
            // is not. Anything outside a comment is a failure.
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
            {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///"), !trimmed.hasPrefix("*")
                else { continue }
                #expect(
                    !trimmed.contains("NSQuitAlwaysKeepsWindows"),
                    "\(file.lastPathComponent):\(number + 1) writes a user preference ADR-4 forbids")
                #expect(
                    !trimmed.contains("restorationClass"),
                    "\(file.lastPathComponent):\(number + 1) uses NSWindowRestoration")
            }
        }
    }

    // MARK: - Durability

    @Test("saving is atomic, so a reader never sees a half-written file")
    func saveIsAtomic() throws {
        let fixture = try TabFixture()
        try fixture.session.save(
            SessionState(tabs: [SessionTab(path: fixture.file(named: "a.md").path)]))
        let first = try #require(try fixture.session.load())
        #expect(first.tabs.count == 1)

        // Overwrite with a much larger state; a non-atomic write of a shorter
        // payload over a longer one is the classic way to leave trailing bytes.
        let many = (0..<200).map { SessionTab(path: "/tmp/\($0).md", scrollOffset: Double($0)) }
        try fixture.session.save(SessionState(tabs: many))
        #expect(try fixture.session.load()?.tabs.count == 200)
        try fixture.session.save(SessionState(tabs: []))
        #expect(try fixture.session.load()?.tabs.isEmpty == true)
    }

    @Test("the default session path is under Application Support, not ~/.config")
    func defaultPath() {
        let path = Session.defaultURL.path
        #expect(path.hasSuffix("/mark/session.json"))
        #expect(path.contains("Application Support"))
    }
}
