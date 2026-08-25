import Foundation
import Testing

@testable import MarkKit

/// History semantics, which are the part of M8 that is invisible in a
/// screenshot and wrong in a way nobody notices for weeks.
@Suite("Navigator — roots, breadcrumbs, and history")
@MainActor
struct NavigatorTests {

    private func navigator(_ path: String = "/tmp/project") -> Navigator {
        Navigator(root: URL(fileURLWithPath: path))
    }

    @Test("the breadcrumb is the root's components, outermost first, ending at the root")
    func breadcrumb() {
        let crumbs = navigator("/Users/you/notes/work").breadcrumb
        #expect(crumbs.map(\.name) == ["/", "Users", "you", "notes", "work"])
        #expect(crumbs.map(\.url.path) == [
            "/", "/Users", "/Users/you", "/Users/you/notes", "/Users/you/notes/work",
        ])
    }

    @Test("the filesystem root is one crumb and has no parent")
    func atTheTop() {
        let nav = navigator("/")
        #expect(nav.breadcrumb.map(\.name) == ["/"])
        #expect(!nav.canGoUp)
        #expect(!nav.goToParent())
    }

    @Test("going somewhere pushes the old root and clears forward")
    func forwardIsClearedByANewDestination() {
        let nav = navigator("/tmp/a")
        nav.go(to: URL(fileURLWithPath: "/tmp/b"))
        nav.goBack()
        #expect(nav.root.path == "/tmp/a")
        #expect(nav.forward.map(\.path) == ["/tmp/b"])

        nav.go(to: URL(fileURLWithPath: "/tmp/c"))
        #expect(nav.forward.isEmpty, "a new destination must discard the forward stack")
        #expect(nav.back.map(\.path) == ["/tmp/a"])
    }

    /// Plan §2 M8: *"'up, look, back down' is the actual navigation loop"*. If
    /// that loop grows history on every hop, ⌘[ becomes useless after a minute
    /// of browsing.
    @Test("up, look, back down returns to where it started")
    func theNavigationLoop() {
        let nav = navigator("/tmp/project/docs")
        #expect(nav.goToParent())
        #expect(nav.root.path == "/tmp/project")
        #expect(nav.goBack())
        #expect(nav.root.path == "/tmp/project/docs")
        #expect(nav.back.isEmpty)
        #expect(nav.forward.map(\.path) == ["/tmp/project"])
        #expect(nav.goForward())
        #expect(nav.root.path == "/tmp/project")
        #expect(nav.forward.isEmpty)
    }

    @Test("navigating to the root you are already on records nothing")
    func noSelfNavigation() {
        let nav = navigator("/tmp/a")
        #expect(!nav.go(to: URL(fileURLWithPath: "/tmp/a")))
        #expect(!nav.go(to: URL(fileURLWithPath: "/tmp/a/")))
        #expect(!nav.go(to: URL(fileURLWithPath: "/tmp/./a")))
        #expect(nav.back.isEmpty)
    }

    @Test("back and forward at the ends of history report that they did nothing")
    func endsOfHistory() {
        let nav = navigator()
        #expect(!nav.goBack())
        #expect(!nav.goForward())
        #expect(!nav.canGoBack)
        #expect(!nav.canGoForward)
    }

    /// The stacks go in the session file, so they cannot grow without bound.
    @Test("history is capped")
    func historyIsCapped() {
        let nav = navigator("/tmp/0")
        for index in 1...(Navigator.historyLimit + 20) {
            nav.go(to: URL(fileURLWithPath: "/tmp/\(index)"))
        }
        #expect(nav.back.count == Navigator.historyLimit)
        // The *oldest* entries are the ones dropped, so ⌘[ still walks back
        // through where you have just been.
        #expect(nav.back.last?.path == "/tmp/\(Navigator.historyLimit + 19)")
    }

    /// Restoring through `go(to:)` would push the launch root onto the back
    /// stack, so every relaunch would add one entry and ⌘[ would go somewhere
    /// the user has never been.
    @Test("restore adopts a persisted history without recording a navigation")
    func restoreRecordsNothing() {
        let nav = navigator("/tmp/launch")
        nav.restore(
            root: URL(fileURLWithPath: "/tmp/project/docs"),
            back: [URL(fileURLWithPath: "/tmp/project")],
            forward: [URL(fileURLWithPath: "/tmp/elsewhere")]
        )
        #expect(nav.root.path == "/tmp/project/docs")
        #expect(nav.back.map(\.path) == ["/tmp/project"])
        #expect(nav.forward.map(\.path) == ["/tmp/elsewhere"])
        #expect(!nav.back.contains { $0.path == "/tmp/launch" })
    }

    @Test("every change notifies once, with the reason")
    func changeNotifications() {
        let nav = navigator("/tmp/a")
        var reasons: [Navigator.Reason] = []
        nav.onChange = { _, reason in reasons.append(reason) }

        nav.go(to: URL(fileURLWithPath: "/tmp/a/b"))
        nav.goToParent()
        nav.goBack()
        nav.goForward()
        _ = nav.go(to: URL(fileURLWithPath: "/tmp/a"))  // a no-op: already there
        #expect(reasons == [.jump, .parent, .back, .forward])
    }
}
