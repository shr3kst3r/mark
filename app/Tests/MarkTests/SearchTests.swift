import AppKit
import Foundation
import Testing

@testable import MarkKit

/// Finding text across a folder of notes.
///
/// The gap: `mark grep` has reported the heading each hit sits under since M1,
/// and nothing in the window called it. Half of these assert on the *core's*
/// answer, because that is the half that must not differ from the CLI's; the
/// rest assert on the window's behaviour around it — debouncing, cancelling,
/// and not showing a result for a pattern the reader has typed past.
@Suite("Find in folder")
@MainActor
struct SearchTests {

    /// A small notes tree with a heading structure worth reporting.
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mark-search-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("deploys")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try """
            # Runbook

            ## Deploys

            the deploy runbook

            ### Rollback

            roll it back with care
            """.write(
            to: nested.appendingPathComponent("runbook.md"), atomically: true, encoding: .utf8)
        try "# Index\n\nnothing to see\n".write(
            to: root.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
        return root
    }

    // ---- the core's answer, which is also the CLI's -----------------------

    @Test("a hit knows which heading it is under")
    func hitsCarryTheirBreadcrumb() throws {
        let root = try fixture()
        let results = try MarkCore.search(root: root.path, pattern: "roll it back")
        #expect(results.matches.count == 1)
        let hit = try #require(results.matches.first)
        #expect(hit.heading == "Runbook > Deploys > Rollback")
        #expect(hit.anchor == "rollback")
        #expect(hit.line == 9)
        #expect(hit.text == "roll it back with care")
    }

    @Test("a hit carries the byte offset the preview scrolls to")
    func hitsCarryAnOffset() throws {
        let root = try fixture()
        let results = try MarkCore.search(root: root.path, pattern: "roll it back")
        let hit = try #require(results.matches.first)
        // A line number alone would not be enough: `follow(sourceByte:)` is
        // what puts a hit inside a diagram or a table in the right place.
        let source = try String(
            contentsOf: root.appendingPathComponent("deploys/runbook.md"), encoding: .utf8)
        let index = source.utf8.index(source.utf8.startIndex, offsetBy: hit.offset)
        #expect(source[index...].hasPrefix("roll it back"))
    }

    @Test("case folding is the window's default and a choice")
    func caseFolding() throws {
        let root = try fixture()
        #expect(try MarkCore.search(root: root.path, pattern: "ROLL IT").matches.isEmpty)
        #expect(
            try !MarkCore.search(root: root.path, pattern: "ROLL IT", ignoreCase: true)
                .matches.isEmpty)
    }

    @Test("the search walks into subdirectories")
    func itRecurses() throws {
        let root = try fixture()
        // The hit is two levels down; the sidebar's own filter would never
        // have found it, which is the point of this feature.
        let results = try MarkCore.search(root: root.path, pattern: "runbook")
        #expect(results.matches.contains { $0.path.hasSuffix("deploys/runbook.md") })
    }

    @Test("a limit is reported rather than left to be inferred")
    func truncationIsReported() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mark-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try String(repeating: "hit\n", count: 20).write(
            to: root.appendingPathComponent("many.md"), atomically: true, encoding: .utf8)

        let capped = try MarkCore.search(root: root.path, pattern: "hit", limit: 5)
        #expect(capped.matches.count == 5)
        #expect(capped.truncated)

        // Exactly as many hits as the cap: ambiguous if inferred from the
        // count, which is why the core reports it.
        let exact = try MarkCore.search(root: root.path, pattern: "hit", limit: 20)
        #expect(exact.matches.count == 20)
        #expect(!exact.truncated)
    }

    @Test("an invalid pattern is an error rather than an empty result")
    func invalidPatternThrows() throws {
        let root = try fixture()
        #expect(throws: (any Error).self) {
            _ = try MarkCore.search(root: root.path, pattern: "(unclosed")
        }
    }

    // ---- picking the hit out of its line -----------------------------------

    @Test("the matched span is emboldened using the core's own offsets")
    func theMatchIsPickedOut() throws {
        let root = try fixture()
        let hit = try #require(
            MarkCore.search(root: root.path, pattern: "deploy runbook").matches.first)
        let styled = hit.styled(font: .systemFont(ofSize: 11), highlight: .findHighlightColor)

        var highlighted = ""
        styled.enumerateAttribute(
            .backgroundColor, in: NSRange(location: 0, length: styled.length)
        ) { value, range, _ in
            if value != nil { highlighted = (styled.string as NSString).substring(with: range) }
        }
        #expect(highlighted == "deploy runbook")
    }

    @Test("a multi-byte line does not shift the highlight")
    func multiByteOffsetsSurvive() throws {
        // The core counts UTF-8 bytes and `NSAttributedString` counts UTF-16
        // units. An emoji before the match is what tells them apart.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mark-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# T\n\n🎯 émoji then TARGET here\n".write(
            to: root.appendingPathComponent("wide.md"), atomically: true, encoding: .utf8)

        let hit = try #require(MarkCore.search(root: root.path, pattern: "TARGET").matches.first)
        let styled = hit.styled(font: .systemFont(ofSize: 11), highlight: .findHighlightColor)
        var highlighted = ""
        styled.enumerateAttribute(
            .backgroundColor, in: NSRange(location: 0, length: styled.length)
        ) { value, range, _ in
            if value != nil { highlighted = (styled.string as NSString).substring(with: range) }
        }
        #expect(highlighted == "TARGET", "the highlight slid off the match")
    }

    // ---- the window --------------------------------------------------------

    @Test("an empty pattern shows nothing rather than everything")
    func emptyPatternIsEmpty() async throws {
        let root = try fixture()
        let controller = SearchWindowController(root: root) { _, _ in }
        defer { controller.tearDown() }

        controller.runSearch()
        try await _Concurrency.Task.sleep(for: .milliseconds(400))
        #expect(controller.rows.isEmpty)
    }

    @Test("typing a pattern fills the table")
    func typingSearches() async throws {
        let root = try fixture()
        let controller = SearchWindowController(root: root) { _, _ in }
        defer { controller.tearDown() }

        controller.setPatternForTesting("roll it back")
        try await _Concurrency.Task.sleep(for: .milliseconds(600))
        #expect(controller.rows.count == 1)
        #expect(controller.table.numberOfRows == 1)
    }

    @Test("a result for a pattern the reader has typed past is dropped")
    func staleResultsAreDropped() async throws {
        let root = try fixture()
        let controller = SearchWindowController(root: root) { _, _ in }
        defer { controller.tearDown() }

        // Two searches in quick succession, inside one debounce window. Only
        // the second may reach the table — otherwise a slow search over a big
        // tree lands on top of a newer one.
        controller.setPatternForTesting("roll it back")
        controller.setPatternForTesting("nothing to see")
        try await _Concurrency.Task.sleep(for: .milliseconds(600))

        #expect(controller.rows.count == 1)
        #expect(controller.rows.first?.text == "nothing to see")
    }

    @Test("an invalid pattern leaves the last results alone")
    func invalidPatternKeepsWhatIsThere() async throws {
        let root = try fixture()
        let controller = SearchWindowController(root: root) { _, _ in }
        defer { controller.tearDown() }

        controller.setPatternForTesting("roll")
        try await _Concurrency.Task.sleep(for: .milliseconds(600))
        // Two: the `### Rollback` heading and the line under it, since the
        // window folds case by default.
        let before = controller.rows.count
        #expect(before == 2)

        // `roll(` is what "roll(it)" looks like halfway through being typed.
        // Blanking the table there would make the window flicker on the way to
        // a valid pattern.
        controller.setPatternForTesting("roll(")
        try await _Concurrency.Task.sleep(for: .milliseconds(600))
        #expect(controller.rows.count == before, "a half-typed pattern cleared the results")
    }

    @Test("opening a result hands back the file and the offset")
    func openingAResult() async throws {
        let root = try fixture()
        var opened: (URL, Int)?
        let controller = SearchWindowController(root: root) { url, offset in
            opened = (url, offset)
        }
        defer { controller.tearDown() }

        controller.setPatternForTesting("roll it back")
        try await _Concurrency.Task.sleep(for: .milliseconds(600))
        controller.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.openSelected(nil)

        let result = try #require(opened)
        #expect(result.0.lastPathComponent == "runbook.md")
        #expect(result.1 == controller.rows[0].offset)
    }

    @Test("moving the sidebar moves the search")
    func settingTheRootResearches() async throws {
        let root = try fixture()
        let controller = SearchWindowController(root: root) { _, _ in }
        defer { controller.tearDown() }

        controller.setPatternForTesting("nothing to see")
        try await _Concurrency.Task.sleep(for: .milliseconds(600))
        #expect(controller.rows.count == 1)

        // Down into the subdirectory, where that text does not appear.
        controller.setRoot(root.appendingPathComponent("deploys"))
        try await _Concurrency.Task.sleep(for: .milliseconds(600))
        #expect(controller.rows.isEmpty, "the search kept the old scope")
    }
}
