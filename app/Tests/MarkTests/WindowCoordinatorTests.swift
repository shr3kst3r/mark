import AppKit
import Foundation
import Testing

@testable import MarkKit

/// Moving a tab between windows
/// (`2026-08-26-multiple-windows-and-split-panes`).
///
/// The ADR calls this the risky part of the change, and it is: a tab carries a
/// `Buffer`, an `flock(2)` lock, an autosave debounce and seven callbacks that
/// all captured the window it is leaving.
@Suite("Pop-out — a tab moves, and takes its machinery with it")
@MainActor
struct WindowCoordinatorTests {

    /// A move is not a close.
    ///
    /// `close` fires `willClose`, which writes and then **discards** the
    /// buffer. Correct for a document going away; catastrophic for one changing
    /// windows, which would arrive having lost its undo stack and its lock.
    @Test("detach keeps the buffer that close would have discarded")
    func detachKeepsTheBuffer() throws {
        let harness = try TabHarness(files: ["a.md", "b.md"])
        let store = harness.store
        let tab = try #require(store.selected)
        let buffer = try Buffer.open(url: tab.url, autosaveDelay: 60, previewDelay: 60)
        buffer.replaceContents("# moved while dirty\n")
        tab.attach(buffer: buffer)
        #expect(tab.isDirty)

        let moved = store.detach(tab)

        #expect(moved.tab === tab)
        #expect(tab.buffer === buffer, "the unsaved text did not travel with the tab")
        #expect(tab.isDirty)
        #expect(!store.tabs.contains(tab))
        #expect(store.tabs.count == 1)
    }

    /// The document keeps its DOM, its scroll position and its JS state across
    /// the move — which is also what lets a *dirty* tab move at all, since
    /// `2026-08-25-flock-write-locking` forbids dehydrating unsaved work.
    @Test("the live view moves rather than being remade")
    func theViewIsReparentedNotRebuilt() throws {
        let source = try TabHarness(files: ["a.md", "b.md"])
        let destination = try TabHarness(governor: source.store.governor)
        let tab = try #require(source.store.selected)
        source.reportScroll(1234, on: tab)

        let moved = source.store.detach(tab)
        #expect(moved.view != nil, "the tab was dehydrated by a move")
        destination.store.adopt(moved.tab, view: moved.view)

        #expect(destination.hydrator.adopted == [tab.url])
        #expect(
            destination.hydrator.hydrated.isEmpty,
            "the destination remade the view instead of adopting it, losing the DOM")
        #expect(tab.scrollOffset == 1234)
        #expect(tab.state.isResident)
    }

    @Test("an adopted tab belongs to its new store and is selected there")
    func adoptionRebindsOwnership() throws {
        let source = try TabHarness(files: ["a.md", "b.md"])
        let destination = try TabHarness(governor: source.store.governor)
        let tab = try #require(source.store.selected)

        let moved = source.store.detach(tab)
        destination.store.adopt(moved.tab, view: moved.view)

        #expect(tab.store === destination.store)
        #expect(destination.store.selected === tab)
        #expect(destination.store.tabs.contains(tab))
        // And it counts against the *shared* budget from its new home, not
        // twice and not not-at-all.
        #expect(source.store.governor.allTabs.filter { $0 === tab }.count == 1)
    }

    /// The source window must stop showing a document it no longer owns.
    @Test("the source window promotes a survivor rather than showing nothing")
    func sourceRecoversAfterTheMove() throws {
        let source = try TabHarness(files: ["a.md", "b.md"])
        let destination = try TabHarness(governor: source.store.governor)
        let tab = try #require(source.store.selected)

        let moved = source.store.detach(tab)
        destination.store.adopt(moved.tab, view: moved.view)

        #expect(source.store.selected != nil)
        #expect(source.store.selected !== tab)
        #expect(source.store.displayedTabs.allSatisfy { $0 !== tab })
    }

    /// Detaching the right-hand pane's document collapses the split it leaves
    /// behind, rather than leaving half a window blank.
    @Test("popping the split's right pane out collapses the split")
    func detachingSecondaryCollapsesTheSplit() throws {
        let source = try TabHarness(files: ["a.md", "b.md"])
        let destination = try TabHarness(governor: source.store.governor)
        source.store.splitRight()
        let right = try #require(source.store.secondary)

        let moved = source.store.detach(right)
        destination.store.adopt(moved.tab, view: moved.view)

        #expect(!source.store.isSplit)
        #expect(source.store.focus == .primary)
    }

    /// A tab that is not in this store is not this store's to give away.
    @Test("detaching a tab the store does not hold changes nothing")
    func detachingAStrangerIsANoOp() throws {
        let a = try TabHarness(files: ["a.md"])
        let b = try TabHarness(files: ["b.md"], governor: a.store.governor)
        let theirs = try #require(b.store.selected)

        let moved = a.store.detach(theirs)

        #expect(moved.view == nil)
        #expect(b.store.tabs.contains(theirs))
        #expect(a.store.tabs.count == 1)
    }
}

/// The session file's window dimension.
@Suite("Session — more than one window")
@MainActor
struct MultiWindowSessionTests {

    /// The compatibility promise: the flat fields keep describing window 0, so
    /// a build without multi-window support restores one window rather than
    /// nothing.
    @Test("the flat fields still describe the first window")
    func flatFieldsMirrorTheFirstWindow() throws {
        let first = SessionWindow(
            tabs: [SessionTab(path: "/a.md"), SessionTab(path: "/b.md")],
            selectedIndex: 1,
            sidebarRoot: "/notes")
        let second = SessionWindow(
            tabs: [SessionTab(path: "/c.md")], selectedIndex: 0, sidebarRoot: "/other")

        let state = SessionState(windows: [first, second])

        #expect(state.tabs.map(\.path) == ["/a.md", "/b.md"])
        #expect(state.selectedIndex == 1)
        #expect(state.sidebarRoot == "/notes")
        #expect(state.windows?.count == 2)
        #expect(state.effectiveWindows.count == 2)
    }

    /// A session file written before this change has no `windows` key at all.
    @Test("a pre-multi-window session file restores as one window")
    func legacyFileRestoresOneWindow() throws {
        let json = """
            {"version":1,"tabs":[{"path":"/a.md","scrollOffset":12}],
             "selectedIndex":0,"sidebarRoot":"/notes"}
            """
        let state = try JSONDecoder().decode(SessionState.self, from: Data(json.utf8))

        #expect(state.windows == nil)
        let windows = state.effectiveWindows
        #expect(windows.count == 1)
        #expect(windows[0].tabs.map(\.path) == ["/a.md"])
        #expect(windows[0].selectedIndex == 0)
        #expect(windows[0].sidebarRoot == "/notes")
        // Absent means "not split", which is what every old file says by
        // omission.
        #expect(windows[0].repairedSecondaryIndex == nil)
    }

    @Test("a session file round-trips more than one window")
    func multiWindowRoundTrip() throws {
        let state = SessionState(windows: [
            SessionWindow(
                tabs: [SessionTab(path: "/a.md"), SessionTab(path: "/b.md")],
                selectedIndex: 0, secondaryIndex: 1, focus: "secondary",
                splitFraction: 0.4, sidebarRoot: "/notes"),
            SessionWindow(tabs: [SessionTab(path: "/c.md")], selectedIndex: 0),
        ])

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SessionState.self, from: data)

        #expect(decoded == state)
        #expect(decoded.effectiveWindows[0].repairedSecondaryIndex == 1)
        #expect(decoded.effectiveWindows[0].focus == "secondary")
        #expect(decoded.effectiveWindows[0].splitFraction == 0.4)
    }

    /// A hand-edited file naming one tab in both panes asks for the one thing
    /// the ADR forbids. Repaired to "not split" — the same posture this file
    /// already takes on a second preview tab.
    @Test("a session naming the same tab in both panes restores unsplit")
    func sameTabInBothPanesIsRepaired() {
        let window = SessionWindow(
            tabs: [SessionTab(path: "/a.md"), SessionTab(path: "/b.md")],
            selectedIndex: 1, secondaryIndex: 1)
        #expect(window.repairedSecondaryIndex == nil)
    }

    @Test("a session naming an out-of-range pane restores unsplit")
    func outOfRangeSecondaryIsRepaired() {
        let window = SessionWindow(
            tabs: [SessionTab(path: "/a.md")], selectedIndex: 0, secondaryIndex: 7)
        #expect(window.repairedSecondaryIndex == nil)
    }

    /// The theme and its pinned appearance are the **app's**, not a window's,
    /// so they live on ``SessionState`` and every path that builds one has to
    /// carry them.
    ///
    /// This has now been got wrong twice in one change, which is why it is a
    /// test rather than a comment. First when `sessionSnapshot()` was
    /// restructured around windows and quietly stopped setting `theme` — caught
    /// by `ThemeTests`. Then again when `WindowCoordinator` gained a snapshot of
    /// its own and set `theme` but not `themeAppearance`, which no test could
    /// catch because the multi-window path did not exist when the appearance
    /// was added. A relaunch would have dropped a light theme back under a dark
    /// system, which is the exact thing pinning exists to stop.
    @Test("a window's theme and its pinned appearance survive the app-wide snapshot")
    func themeAndAppearanceRoundTripThroughTheCoordinator() throws {
        let controller = ThemeController.shared
        let previousName = controller.chosenName
        let previousAppearance = controller.appearance
        defer { controller.restore(named: previousName, appearance: previousAppearance) }

        // A light theme pinned light: the combination that goes wrong silently,
        // because the name alone restores something plausible.
        try controller.apply(named: "solarized-light", appearance: .light)

        let coordinator = WindowCoordinator()
        coordinator.makeWindow(root: URL(fileURLWithPath: "/tmp"))
        let state = coordinator.snapshot()

        #expect(state.theme == "solarized-light")
        #expect(state.themeAppearance == ThemeAppearance.light.rawValue)

        // And the coordinator puts both back, not just the name.
        controller.restore(named: nil, appearance: .system)
        #expect(controller.appearance == .system)

        coordinator.restore(state)
        #expect(controller.chosenName == "solarized-light")
        #expect(controller.appearance == .light)
    }

    /// The same for the single-window path, which is what `mark-bench` and a
    /// controller built without a coordinator take.
    @Test("a controller without a coordinator carries the theme too")
    func themeSurvivesTheSingleWindowSnapshot() throws {
        let controller = ThemeController.shared
        let previousName = controller.chosenName
        let previousAppearance = controller.appearance
        defer { controller.restore(named: previousName, appearance: previousAppearance) }

        try controller.apply(named: "solarized-light", appearance: .light)

        let fixture = try TabFixture()
        let window = MainWindowController(root: fixture.directory, session: fixture.session)
        let state = window.sessionSnapshot()

        #expect(state.theme == "solarized-light")
        #expect(state.themeAppearance == ThemeAppearance.light.rawValue)
    }

    /// The split has to come back, or "two side by side" is a thing you set up
    /// again on every launch.
    @Test("a split survives a store round trip")
    func splitRoundTripsThroughAStore() throws {
        let harness = try TabHarness(files: ["a.md", "b.md", "c.md"])
        let store = harness.store
        store.splitRight()
        let expectedSecondary = try #require(store.secondary).url

        let snapshot = store.snapshotWindow(sidebarRoot: harness.fixture.directory)
        let restored = try TabHarness()
        restored.store.restore(snapshot)

        #expect(restored.store.isSplit)
        #expect(restored.store.secondary?.url == expectedSecondary)
        #expect(restored.store.primary !== restored.store.secondary)
    }
}
