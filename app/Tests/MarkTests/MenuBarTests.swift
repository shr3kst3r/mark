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
}
