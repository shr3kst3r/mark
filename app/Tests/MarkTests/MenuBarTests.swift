import AppKit
import Foundation
import Testing

@testable import MarkKit

/// The menu bar, as a whole.
@Suite("The menu bar")
@MainActor
struct MenuBarTests {

    /// **The general form of a real defect.**
    ///
    /// ⌥⌘F was assigned twice: `Edit ▸ Find ▸ Replace…` and
    /// `View ▸ Filter Files…`. AppKit matches key equivalents in menu-bar order
    /// and stops at the first hit, so Edit won and `Filter Files…` drew a
    /// shortcut that did nothing — worse than no shortcut, because the menu
    /// advertised it.
    ///
    /// Nothing could have caught that except reading the whole menu bar at
    /// once, which is what this does. The next collision fails the build
    /// instead of being found by eye.
    @Test("no two menu items share a key equivalent")
    func keyEquivalentsAreUnique() throws {
        let delegate = AppDelegate()
        let menu = try #require(delegate.buildMainMenu())

        var seen: [String: String] = [:]
        var collisions: [String] = []

        func walk(_ menu: NSMenu, path: String) {
            for item in menu.items {
                if let submenu = item.submenu {
                    walk(submenu, path: path.isEmpty ? item.title : "\(path) ▸ \(item.title)")
                }
                guard !item.keyEquivalent.isEmpty else { continue }
                // The modifiers are part of the identity: ⌘W and ⇧⌘W are two
                // different shortcuts, and both are deliberately in this menu.
                let key = "\(item.keyEquivalentModifierMask.rawValue):\(item.keyEquivalent)"
                let here = "\(path) ▸ \(item.title)"
                if let previous = seen[key] {
                    collisions.append("\(key) is claimed by both “\(previous)” and “\(here)”")
                } else {
                    seen[key] = here
                }
            }
        }
        walk(menu, path: "")

        #expect(collisions.isEmpty, "\(collisions.joined(separator: "; "))")
    }

    /// The specific fix, pinned so it cannot silently revert.
    @Test("Replace keeps ⌥⌘F and Filter Files moves to ⌥⌘J")
    func filterFilesMovedOffReplace() throws {
        let delegate = AppDelegate()
        let menu = try #require(delegate.buildMainMenu())

        var replace: NSMenuItem?
        var filter: NSMenuItem?
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if item.title == "Replace…" { replace = item }
                if item.title == "Filter Files…" { filter = item }
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        walk(menu)

        let replaceItem = try #require(replace)
        #expect(replaceItem.keyEquivalent == "f")
        #expect(replaceItem.keyEquivalentModifierMask == [.command, .option])

        let filterItem = try #require(filter)
        #expect(filterItem.keyEquivalent == "j")
        #expect(filterItem.keyEquivalentModifierMask == [.command, .option])
    }

    /// The three closes, and the order they are in.
    ///
    /// ⌘W is one tab, ⌥⌘W is all of them, ⇧⌘W is the window: one modifier apart
    /// and widening as it goes, which is the only reason ⌥⌘W is guessable at
    /// all. `keyEquivalentsAreUnique` above says they collide with nothing;
    /// this says which is which, so a later tidy-up cannot swap them.
    @Test("Close Tab, Close All Tabs and Close Window widen in that order")
    func closeItemsWiden() throws {
        let delegate = AppDelegate()
        let menu = try #require(delegate.buildMainMenu())
        // The top-level items carry no title of their own — the submenu does,
        // which is what AppKit draws in the bar.
        let file = try #require(menu.items.compactMap(\.submenu).first { $0.title == "File" })

        func item(_ title: String) throws -> NSMenuItem {
            try #require(file.items.first { $0.title == title }, "File has no \(title)")
        }
        let one = try item("Close Tab")
        let all = try item("Close All Tabs")
        let window = try item("Close Window")

        #expect(one.keyEquivalent == "w")
        #expect(one.keyEquivalentModifierMask == [.command])
        #expect(all.keyEquivalent == "w")
        #expect(all.keyEquivalentModifierMask == [.command, .option])
        #expect(window.keyEquivalent == "w")
        #expect(window.keyEquivalentModifierMask == [.command, .shift])
        #expect(all.action == #selector(MainWindowController.closeAllTabs(_:)))

        let order = file.items.map(\.title)
        let positions = ["Close Tab", "Close All Tabs", "Close Window"].compactMap {
            order.firstIndex(of: $0)
        }
        #expect(positions == positions.sorted(), "the three closes are out of order in File")
    }

    /// The pane and window commands exist and are reachable, since a shortcut
    /// nobody can find is not a feature.
    @Test("the split and window commands are in the menu bar")
    func paneCommandsArePresent() throws {
        let delegate = AppDelegate()
        let menu = try #require(delegate.buildMainMenu())

        var titles: Set<String> = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                titles.insert(item.title)
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        walk(menu)

        for expected in [
            "Split Right", "Close Split", "Focus Other Pane", "Move Tab to Other Pane",
            "New Window", "Move Tab to New Window",
        ] {
            #expect(titles.contains(expected), "\(expected) is not in the menu bar")
        }
    }

    /// `2026-08-28-tabbed-document-pane`: the document pane's two tabs are two
    /// View items, next to each other, one rule between them.
    ///
    /// ⌃⌘T keeps the key it has always had — a reader who never opens the Tasks
    /// tab must find nothing changed — and Tasks takes ⌃⌘Y, which
    /// `keyEquivalentsAreUnique` above is what proves was free. ⌘Y is File ▸
    /// History and stays that; the modifier is the difference.
    @Test("View ▸ Show Tasks sits under Show Table of Contents, on ⌃⌘Y")
    func documentPaneItems() throws {
        let delegate = AppDelegate()
        let menu = try #require(delegate.buildMainMenu())
        // The bar's own items carry no titles; the submenu does.
        let view = try #require(
            menu.items.compactMap(\.submenu).first { $0.title == "View" })

        let contents = try #require(view.items.first { $0.title == "Show Table of Contents" })
        let tasks = try #require(view.items.first { $0.title == "Show Tasks" })
        #expect(contents.keyEquivalent == "t")
        #expect(contents.keyEquivalentModifierMask == [.command, .control])
        #expect(tasks.keyEquivalent == "y")
        #expect(tasks.keyEquivalentModifierMask == [.command, .control])
        #expect(tasks.action == #selector(MainWindowController.toggleTaskList(_:)))

        let order = view.items.map(\.title)
        let contentsIndex = try #require(order.firstIndex(of: "Show Table of Contents"))
        let tasksIndex = try #require(order.firstIndex(of: "Show Tasks"))
        #expect(
            tasksIndex == contentsIndex + 1,
            "the two tabs of one pane belong next to each other")
    }

    /// `2026-08-26-new-documents-are-files-on-disk`.
    ///
    /// Three separate claims, and each has been wrong somewhere before:
    ///
    /// * **⌘N is still New Window.** The ADR declines VS Code's ⌘N/⇧⌘N split
    ///   because ⌘N is shipped and documented. This is the assertion that stops
    ///   a later "tidy-up" from taking it.
    /// * **New Document… is first in File**, where every document app on this
    ///   platform puts the item that makes one.
    /// * **The ellipsis is there.** It opens a save panel — the ADR's whole
    ///   shape is that a document is named before it exists — and an item that
    ///   opens a panel without saying so is a small lie the platform has a
    ///   convention for telling.
    ///
    /// `keyEquivalentsAreUnique` above already guarantees ⇧⌘N collides with
    /// nothing; this pins what it is.
    @Test("New Document… is first in File on ⇧⌘N, and ⌘N still makes a window")
    func newDocumentIsFirstInFile() throws {
        let delegate = AppDelegate()
        let menu = delegate.buildMainMenu()

        let file = try #require(
            menu.items.compactMap(\.submenu).first { $0.title == "File" })

        let first = try #require(file.items.first)
        #expect(first.title == "New Document…")
        #expect(first.keyEquivalent == "N")
        #expect(first.keyEquivalentModifierMask == [.command, .shift])
        #expect(first.action == #selector(MainWindowController.newDocument(_:)))

        let newWindow = try #require(file.items.first { $0.title == "New Window" })
        #expect(newWindow.keyEquivalent == "n")
        #expect(newWindow.keyEquivalentModifierMask == [.command])
    }

    /// **Help ▸ Markdown Reference** on ⇧⌘/
    /// (`2026-08-26-markdown-reference-window`).
    ///
    /// `2026-08-26-opened-file-history`. Under Open…, because it is the other
    /// way to open a file you already have, and on ⌘Y because that is what a
    /// browser has meant by History for twenty years.
    ///
    /// `keyEquivalentsAreUnique` above is what guarantees ⌘Y was free.
    @Test("File ▸ History is under Open…, on ⌘Y")
    func historyItem() throws {
        let delegate = AppDelegate()
        let menu = try #require(delegate.buildMainMenu())
        let file = try #require(menu.items.first { $0.submenu?.title == "File" }?.submenu)

        let open = try #require(file.items.firstIndex { $0.title == "Open…" })
        let history = try #require(file.items.firstIndex { $0.title == "History" })
        #expect(history == open + 1)

        let item = file.items[history]
        #expect(item.keyEquivalent == "y")
        #expect(item.keyEquivalentModifierMask == [.command])
        #expect(item.action == #selector(AppDelegate.showHistory(_:)))
        #expect(item.target === delegate)
        // No ellipsis: it shows a window, it does not ask for input first.
        #expect(!item.title.hasSuffix("…"))
    }

    /// Last, because that is where macOS puts Help and where a reader looks
    /// for it. `installMainMenu(for:)` finds it by title rather than by
    /// position, so a menu appended after it would fail here and not in the
    /// Help search field.
    @Test("Help ▸ Markdown Reference is last, on ⇧⌘/")
    func helpMenuIsPresentAndLast() throws {
        let delegate = AppDelegate()
        let menu = try #require(delegate.buildMainMenu())

        let last = try #require(menu.items.last?.submenu)
        #expect(last.title == "Help", "Help belongs at the end of the menu bar")

        let item = try #require(last.items.first { $0.title == "Markdown Reference" })
        #expect(item.keyEquivalent == "?")
        #expect(item.keyEquivalentModifierMask == [.command])
        #expect(item.action == #selector(AppDelegate.showMarkdownReference(_:)))
        #expect(item.target === delegate)
        // Enabled, because this build ships the resource. The validation exists
        // for a bundle assembled without it.
        #expect(delegate.validateMenuItem(item))
    }
}
