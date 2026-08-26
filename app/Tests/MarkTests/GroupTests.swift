import AppKit
import Foundation
import Testing

@testable import MarkKit

/// The two-group model of `2026-08-26-editor-groups-per-pane-tab-bars`.
@Suite("Editor groups — two panes, each with its own tabs")
@MainActor
struct GroupTests {

    /// The property that makes this change safe to land: with nothing split, a
    /// window is indistinguishable from the one-group window it always was.
    @Test("an unsplit window is one group and behaves like no groups at all")
    func unsplitIsUnchanged() throws {
        let harness = try TabHarness(files: ["a.md", "b.md"])
        let groups = harness.makeGroups()
        #expect(!groups.isSplit)
        #expect(groups.groups.count == 1)
        #expect(groups.focusIndex == 0)
        #expect(groups.focused === harness.store)
        #expect(groups.unfocused == nil)
        #expect(groups.focused.selected === harness.store.tabs[1])
        #expect(groups.displayedTabs.count == 1)
        groups.focused.select(harness.store.tabs[0])
        #expect(groups.focused.selected === harness.store.tabs[0])
    }

    /// > **Never give one tab two views.** If a feature seems to need the same
    /// > document in two places at once, that is a new decision with a ~52 MB
    /// > price on it.
    ///
    /// A group *owns* its tabs, so the one-bar model's swap rule is not needed
    /// to keep this true — it is true by construction, and this is the test
    /// that says so.
    @Test("a tab is in exactly one group")
    func aTabIsInOneGroup() throws {
        let harness = try TabHarness(files: ["a.md", "b.md"])
        let groups = harness.makeGroups()
        let moved = try #require(groups.focused.selected)

        #expect(groups.splitRight())
        #expect(groups.isSplit)
        #expect(groups.groups[0] !== groups.groups[1])
        #expect(groups.groups[1].tabs == [moved])
        #expect(!groups.groups[0].tabs.contains(moved))
        let all = groups.allTabs
        #expect(all.count == 2)
        #expect(all.count == Set(all.map(ObjectIdentifier.init)).count)
        // And exactly one place holds it, asked the other way round.
        #expect(groups.index(of: moved) == 1)
        #expect(groups.group(of: moved) === groups.groups[1])
    }

    /// **Splitting moves a document; it never copies one.**
    @Test("splitting needs two tabs and moves the selected one")
    func splitMovesTheSelection() throws {
        let single = try TabHarness(files: ["a.md"])
        let onlyOne = single.makeGroups()
        #expect(onlyOne.splitRight() == false, "one document has nothing to be split against")
        #expect(!onlyOne.isSplit)

        let harness = try TabHarness(files: ["a.md", "b.md", "c.md"])
        let groups = harness.makeGroups()
        let moving = try #require(groups.focused.selected)
        #expect(groups.splitRight())

        #expect(groups.groups[0].count == 2)
        #expect(groups.groups[1].tabs == [moving])
        // The focus follows the document: ⌘\ is "put this over there", and the
        // reader's attention goes with it.
        #expect(groups.focusIndex == 1)
        #expect(groups.focused.selected === moving)
    }

    /// The behaviour the one-bar model could not have, because a tab belonged
    /// to no pane: ⇧⌘\ **keeps every document**.
    @Test("closing the split merges the groups rather than dropping documents")
    func closeSplitKeepsEveryDocument() throws {
        let harness = try TabHarness(files: ["a.md", "b.md", "c.md"])
        let groups = harness.makeGroups()
        #expect(groups.splitRight())
        let moved = try #require(groups.groups[1].selected)
        let openBefore = Set(groups.allTabs.map(ObjectIdentifier.init))

        #expect(groups.closeSplit())

        #expect(!groups.isSplit)
        #expect(groups.focusIndex == 0)
        #expect(Set(groups.allTabs.map(ObjectIdentifier.init)) == openBefore)
        #expect(groups.focused.tabs.contains(moved))
        // The focused group's selection survives being merged into.
        #expect(groups.focused.selected === moved)
    }

    @Test("the focus decides which group is acted on, and refuses a group that is not there")
    func focusPicksAGroup() throws {
        let harness = try TabHarness(files: ["a.md", "b.md"])
        let groups = harness.makeGroups()
        #expect(groups.focus(1) == false, "there is no second group to focus")
        #expect(groups.focusOther() == false)

        #expect(groups.splitRight())
        #expect(groups.focusIndex == 1)
        #expect(groups.focusOther())
        #expect(groups.focusIndex == 0)
        #expect(groups.focused === groups.groups[0])
        #expect(groups.unfocused === groups.groups[1])
        #expect(groups.focus(0) == false, "already there")
    }

    /// New documents land in the focused group — the sidebar's click,
    /// `mark open`, ⌘T and a drop all go through it.
    @Test("opening a document lands in the focused group")
    func openingLandsInTheFocusedGroup() throws {
        let harness = try TabHarness(files: ["a.md", "b.md"])
        let groups = harness.makeGroups()
        #expect(groups.splitRight())
        #expect(groups.focusIndex == 1)

        let opened = groups.focused.open(harness.file(named: "c.md"))
        #expect(groups.groups[1].tabs.contains(opened))
        #expect(!groups.groups[0].tabs.contains(opened))

        groups.focusOther()
        let other = groups.focused.open(harness.file(named: "d.md"))
        #expect(groups.groups[0].tabs.contains(other))
    }

    /// **An empty group is not a state; it is a group that closed.**
    @Test("closing a group's last tab collapses the split")
    func closingTheLastTabCollapses() throws {
        let harness = try TabHarness(files: ["a.md", "b.md"])
        let groups = harness.makeGroups()
        let collapser = GroupCollapser(groups: groups)
        groups.configureStore = { [hydrator = harness.hydrator] store in
            store.hydrator = hydrator
            store.delegate = collapser
        }
        harness.store.delegate = collapser
        #expect(groups.splitRight())
        let alone = try #require(groups.groups[1].selected)

        groups.groups[1].close(alone)

        #expect(!groups.isSplit)
        #expect(groups.focusIndex == 0)
        #expect(groups.focused.count == 1)
        #expect(groups.focused.selected != nil, "every menu item would grey out")
    }

    /// The last tab in the *only* group leaves the window open on its empty
    /// state — it still has the sidebar.
    @Test("closing the only group's last tab leaves one empty group")
    func closingEverythingLeavesOneGroup() throws {
        let harness = try TabHarness(files: ["a.md"])
        let groups = harness.makeGroups()
        let collapser = GroupCollapser(groups: groups)
        harness.store.delegate = collapser

        groups.focused.closeAll()

        #expect(groups.groups.count == 1)
        #expect(groups.focused.isEmpty)
        #expect(groups.focused.selected == nil)
    }

    @Test("moving a tab to the other group splits when there is only one")
    func moveSplitsWhenUnsplit() throws {
        let harness = try TabHarness(files: ["a.md", "b.md"])
        let groups = harness.makeGroups()
        let moving = try #require(groups.focused.tabs.first)

        #expect(groups.moveToOtherGroup(moving))

        #expect(groups.isSplit)
        #expect(groups.groups[1].tabs == [moving])
        #expect(groups.focusIndex == 1)
    }

    /// Moving a group's **only** tab to the other side is a legitimate way to
    /// say "stop splitting", so it collapses rather than being refused.
    @Test("moving a group's last tab across collapses the split")
    func moveOfTheLastTabCollapses() throws {
        let harness = try TabHarness(files: ["a.md", "b.md"])
        let groups = harness.makeGroups()
        #expect(groups.splitRight())
        let alone = try #require(groups.groups[1].tabs.first)

        #expect(groups.moveToOtherGroup(alone))

        #expect(!groups.isSplit)
        #expect(groups.focused.count == 2)
        #expect(groups.focused.tabs.contains(alone))
    }

    @Test("a single group with a single tab has nowhere to move it")
    func moveRefusedWithOneTab() throws {
        let harness = try TabHarness(files: ["a.md"])
        let groups = harness.makeGroups()
        let only = try #require(groups.focused.tabs.first)
        #expect(groups.moveToOtherGroup(only) == false)
        #expect(!groups.isSplit)
    }

    /// A moved tab carries its live view, exactly as a pop-out does: the move
    /// is between groups in one window, which makes skipping the re-adoption
    /// more tempting and no less wrong.
    @Test("a moved tab keeps its web view rather than being remade")
    func moveKeepsTheView() throws {
        let harness = try TabHarness(files: ["a.md", "b.md"])
        let groups = harness.makeGroups()
        let moving = try #require(groups.focused.selected)
        let view = try #require(moving.documentView)
        let hydratedBefore = harness.hydrator.hydrated.count

        #expect(groups.splitRight())

        #expect(moving.documentView === view, "the same view, moved")
        #expect(harness.hydrator.adopted.contains(moving.url))
        #expect(
            harness.hydrator.hydrated.count == hydratedBefore,
            "nothing was hydrated: the moved view was adopted, not remade")
        #expect(moving.state.isResident)
    }

    /// `mark tab list` reports a window-flat index and `mark tab select <n>`
    /// takes the same one, which is what keeps one command surface over two
    /// lists of tabs.
    @Test("the window-flat index spans the groups in order")
    func windowIndexSpansGroups() throws {
        let harness = try TabHarness(files: ["a.md", "b.md", "c.md"])
        let groups = harness.makeGroups()
        #expect(groups.splitRight())

        let flat = groups.allTabs
        #expect(flat.count == 3)
        for (index, tab) in flat.enumerated() {
            #expect(groups.windowIndex(of: tab) == index)
            let resolved = groups.tab(atWindowIndex: index)
            #expect(resolved?.tab === tab)
        }
        #expect(groups.tab(atWindowIndex: 3) == nil)
        #expect(groups.tab(atWindowIndex: -1) == nil)
        // The last index belongs to the second group, which is the half of this
        // that a per-group index would get wrong.
        #expect(groups.tab(atWindowIndex: 2)?.group == 1)
    }

    /// The bar's job is now to say which of *its* documents is current — and
    /// which of the two bars is being acted on.
    @Test("each group's bar draws only its own tabs, and only one bar is active")
    func barsAreOwnedByGroups() throws {
        let harness = try TabHarness(files: ["a.md", "b.md", "c.md"])
        let groups = harness.makeGroups()
        #expect(groups.splitRight())

        let left = TabBarView(store: groups.groups[0])
        let right = TabBarView(store: groups.groups[1])
        left.frame = NSRect(x: 0, y: 0, width: 450, height: TabBarView.barHeight)
        right.frame = left.frame
        left.isActive = groups.focusIndex == 0
        right.isActive = groups.focusIndex == 1
        left.reload()
        right.reload()

        #expect(left.items.count == 2)
        #expect(right.items.count == 1)
        #expect(left.isActive != right.isActive)
        #expect(right.isActive, "the split moved the focus to the new group")
        // One selected tab per bar: a group has one selection, so there is no
        // third "on screen but not current" state to draw any more.
        #expect(left.items.filter(\.isSelected).count == 1)
        #expect(right.items.filter(\.isSelected).count == 1)
        #expect(right.items.allSatisfy { $0.isBarActive })
        #expect(left.items.allSatisfy { !$0.isBarActive })
    }

    // MARK: - The window

    /// The indirection that keeps ~40 call sites from having to pick a group:
    /// `tabs`, `tabBar` and `documentContainer` all mean *the focused group's*.
    @Test("a split window has two bars and two containers, and the focus picks one")
    func theWindowFollowsTheFocusedGroup() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        controller.open(fixture.file(named: "a.md"))
        controller.open(fixture.file(named: "b.md"))
        #expect(controller.areas.count == 1)

        controller.splitRight(nil)

        #expect(controller.groups.isSplit)
        #expect(controller.areas.count == 2)
        #expect(controller.areas[0].tabBar !== controller.areas[1].tabBar)
        #expect(controller.areas[0].container !== controller.areas[1].container)
        #expect(controller.groupSplit.areas == controller.areas)
        // The window's "the tabs" is the focused group's, which the split moved.
        #expect(controller.tabs === controller.groups.groups[1])
        #expect(controller.tabBar === controller.areas[1].tabBar)
        #expect(controller.documentContainer === controller.areas[1].container)
        // Each container holds its own group's web views, and one per group is
        // on screen.
        for (index, area) in controller.areas.enumerated() {
            let group = controller.groups.groups[index]
            #expect(
                Set(area.container.documentViews.map(ObjectIdentifier.init))
                    == Set(group.tabs.compactMap(\.documentView).map(ObjectIdentifier.init)),
                "group \(index)'s views live in group \(index)'s container")
            #expect(area.container.visibleDocumentViews.count == 1)
            #expect(area.container.visibleDocumentView === group.selected?.documentView)
        }
    }

    /// **A document is open in at most one place**, which a store cannot enforce
    /// on its own because a store is one group. Every route in goes through the
    /// window, and the window goes to the document rather than making a second
    /// one.
    @Test("opening a document already open in the other group goes there")
    func openingGoesToTheOtherGroup() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        let a = fixture.file(named: "a.md")
        controller.open(a)
        controller.open(fixture.file(named: "b.md"))
        controller.splitRight(nil)
        #expect(controller.groups.focusIndex == 1)
        #expect(controller.groups.groups[0].tab(for: a) != nil, "a.md stayed on the left")

        controller.open(a)

        #expect(controller.groups.allTabs.count == 2, "no second tab for a document on screen")
        #expect(controller.groups.focusIndex == 0, "the focus went to the document")
        #expect(controller.tabs.selected?.url == a)
        let views = controller.areas.flatMap { $0.container.documentViews }
        #expect(
            views.count == Set(views.map(ObjectIdentifier.init)).count,
            "and no second web view either — that is the ~52 MB the ADR refuses")
    }

    /// ⇧⌘\ keeps every document, and the window's watcher keeps watching all of
    /// them: a file open in the other group is open in this window.
    @Test("the window watches every group's files")
    func watchingSpansGroups() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        controller.open(fixture.file(named: "a.md"))
        controller.open(fixture.file(named: "b.md"))
        controller.splitRight(nil)

        #expect(controller.groups.allTabs.count == 2)
        #expect(
            controller.tab(for: fixture.file(named: "a.md")) != nil,
            "the other group's document is still open in this window")

        controller.closeSplit(nil)
        #expect(!controller.groups.isSplit)
        #expect(controller.tabs.count == 2, "closing the split kept both documents")
    }

    /// Dragging a tab across the divider is the gesture the ADR asks for; the
    /// bar reports a drop that left it and the window decides whether that
    /// landed in the other group.
    @Test("a tab dropped over the other group moves there")
    func draggingAcrossTheDividerMoves() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        controller.open(fixture.file(named: "a.md"))
        controller.open(fixture.file(named: "b.md"))
        controller.open(fixture.file(named: "c.md"))
        controller.splitRight(nil)
        controller.window?.setContentSize(NSSize(width: 1200, height: 700))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(controller.groups.groups[0].count == 2)

        let leftBar = controller.areas[0].tabBar
        let dragged = try #require(controller.groups.groups[0].tabs.first)
        // A point in the middle of the right-hand group, in window coordinates
        // — which is what the bar's tracking loop reports.
        let rightArea = controller.areas[1]
        let target = controller.groupSplit.convert(
            NSPoint(x: rightArea.frame.midX, y: rightArea.frame.midY), to: nil)
        let handled = leftBar.onDragOut?(dragged, target) ?? false

        #expect(handled, "the window took the drop")
        #expect(controller.groups.groups[1].tabs.contains(dragged))
        #expect(!controller.groups.groups[0].tabs.contains(dragged))
        #expect(controller.groups.focusIndex == 1)
        // The view moved with it, into the other group's container.
        #expect(controller.areas[1].container.documentViews.contains { $0 === dragged.documentView })
    }

    /// A drop that never left the group it started in is a reorder, not a move.
    @Test("a tab dropped over its own group is not a move")
    func draggingWithinAGroupIsNotAMove() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        controller.open(fixture.file(named: "a.md"))
        controller.open(fixture.file(named: "b.md"))
        controller.open(fixture.file(named: "c.md"))
        controller.splitRight(nil)
        controller.window?.setContentSize(NSSize(width: 1200, height: 700))
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        let leftBar = controller.areas[0].tabBar
        let dragged = try #require(controller.groups.groups[0].tabs.first)
        let leftArea = controller.areas[0]
        let target = controller.groupSplit.convert(
            NSPoint(x: leftArea.frame.midX, y: leftArea.frame.midY), to: nil)

        #expect(leftBar.onDragOut?(dragged, target) == false)
        #expect(controller.groups.groups[0].tabs.contains(dragged))
        #expect(controller.groups.groups.count == 2)
    }

    /// The session file is where "two side by side" has to survive a relaunch.
    @Test("a split window's groups survive the session file")
    func groupsSurviveTheSessionFile() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        controller.open(fixture.file(named: "a.md"))
        controller.open(fixture.file(named: "b.md"))
        controller.splitRight(nil)
        controller.groups.splitFraction = 0.35

        let encoded = try JSONEncoder().encode(controller.sessionSnapshot())
        let decoded = try JSONDecoder().decode(SessionState.self, from: encoded)
        let restored = MainWindowController(root: fixture.directory, session: fixture.session)
        restored.restore(decoded)

        #expect(restored.groups.isSplit)
        #expect(restored.groups.groups.count == 2)
        #expect(restored.groups.groups[0].tabs.map(\.url) == [fixture.file(named: "a.md")])
        #expect(restored.groups.groups[1].tabs.map(\.url) == [fixture.file(named: "b.md")])
        #expect(restored.groups.focusIndex == 1)
        #expect(abs(restored.groups.splitFraction - 0.35) < 0.001)
        #expect(restored.areas.count == 2, "and the window built an area for each")
    }

    /// **The bug that made every one of the tests above pass while the window
    /// showed one document.**
    ///
    /// `WebViewFactory` turns the web view's own background off, so the host
    /// view supplies the colour behind the page. Doing that in `draw(_:)` put
    /// an opaque fill into the window's backing store, and — the note in
    /// ``PreviewPaneView`` says why — drawing around a layer-hosted
    /// `WKWebView` is composited over the whole of it rather than clipped to
    /// the overlap. So one pane's background painted over the *other* pane's
    /// document: harmless with one document on screen, and with two it left
    /// the loser blank while its frame, its layer, its `visibilityState` and
    /// `WKWebView.takeSnapshot` all said the page was there and rendered.
    ///
    /// A layer background cannot leave its own bounds, which is the whole
    /// reason this is pinned as a test: nothing else here can see a pixel.
    @Test("the colour behind a page is a layer background, not a fill")
    func backgroundIsALayerNotAFill() throws {
        let view = DocumentView(frame: NSRect(x: 0, y: 0, width: 450, height: 638))
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view

        #expect(view.wantsLayer, "no layer, nowhere to put the colour")
        #expect(
            view.wantsUpdateLayer,
            "false here sends AppKit back to draw(_:), and the other pane goes blank again")

        view.displayIfNeeded()
        let painted = try #require(view.layer?.backgroundColor)
        #expect(painted == ThemeController.shared.backgroundColor.cgColor)
    }

    /// The other half of that: the colour is a theme *pair*, so it has to
    /// re-resolve on every pass rather than bake one `CGColor` in for the life
    /// of the view — which is what `draw(_:)` got for free and a layer does
    /// not.
    ///
    /// Asserted by resolving under both appearances rather than by switching
    /// the app's theme, so this test does not leave a pinned appearance behind
    /// for the rest of the suite.
    @Test("the layer background re-resolves against the appearance")
    func layerBackgroundFollowsTheAppearance() throws {
        let view = DocumentView(frame: NSRect(x: 0, y: 0, width: 450, height: 638))
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view

        var painted: [CGColor] = []
        var expected: [CGColor] = []
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            let appearance = try #require(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                view.updateLayer()
                if let colour = view.layer?.backgroundColor { painted.append(colour) }
                expected.append(ThemeController.shared.backgroundColor.cgColor)
            }
        }

        #expect(painted == expected)
        #expect(painted.count == 2)
        #expect(painted.first != painted.last, "dark and light are not the same colour")
    }
}
