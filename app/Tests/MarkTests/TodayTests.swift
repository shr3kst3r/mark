import Foundation
import Testing

@testable import MarkKit

/// A journal on disk, written a file at a time.
///
/// A real directory rather than a protocol the digest reads through: what is
/// under test *is* "does this find the journal's files", and a fake filesystem
/// would agree with whatever the code believes about paths.
final class JournalFixture {
    let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mark-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ source: String, to relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try source.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func makeDirectory(_ relative: String) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(relative, isDirectory: true),
            withIntermediateDirectories: true)
    }

    /// The empty `daily/` and `projects/` that make this a journal at all.
    func makeJournal() throws {
        try makeDirectory(JournalRoot.dailyDirectory)
        try makeDirectory(JournalRoot.projectsDirectory)
    }

    var journal: JournalRoot { JournalRoot(url: root.resolvingSymlinksInPath()) }
}

/// A fixed day, in the calendar the digest is given.
func day(_ iso: String) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let parts = iso.split(separator: "-").map { Int($0)! }
    return calendar.date(
        from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
}

var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

// MARK: - Finding the journal

/// `2026-08-31-today-page`: the page reads the sidebar's current root, walking
/// up until it finds a directory holding both `daily/` and `projects/`.
@Suite("Today — finding the journal")
struct JournalRootTests {

    @Test("a directory holding both daily/ and projects/ is a journal")
    func rootItself() throws {
        let fixture = try JournalFixture()
        try fixture.makeJournal()
        let found = try #require(JournalRoot.find(from: fixture.root))
        #expect(found.url.path == fixture.journal.url.path)
    }

    @Test("the search walks up from inside the journal")
    func fromInside() throws {
        let fixture = try JournalFixture()
        try fixture.makeJournal()
        try fixture.makeDirectory("daily/2026/08")
        let found = try #require(
            JournalRoot.find(from: fixture.root.appendingPathComponent("daily/2026/08")))
        #expect(found.url.path == fixture.journal.url.path)
    }

    @Test("a file starts the search at its own directory")
    func fromAFile() throws {
        let fixture = try JournalFixture()
        try fixture.makeJournal()
        let file = try fixture.write("# x\n", to: "daily/2026/08/2026-08-31.md")
        let found = try #require(JournalRoot.find(from: file))
        #expect(found.url.path == fixture.journal.url.path)
    }

    /// **Both** directories, not either. `daily/` alone matches a great many
    /// note trees and `projects/` alone matches most source repositories.
    @Test("one of the two directories is not a journal")
    func needsBoth() throws {
        let fixture = try JournalFixture()
        try fixture.makeDirectory(JournalRoot.dailyDirectory)
        #expect(JournalRoot.find(from: fixture.root) == nil)
    }

    /// A worktree is a journal in its own right: its dailies are the ones the
    /// window you asked from is looking at.
    @Test("the nearest journal wins, so a worktree is its own")
    func nearestWins() throws {
        let fixture = try JournalFixture()
        try fixture.makeJournal()
        try fixture.makeDirectory(".worktrees/mellow/daily")
        try fixture.makeDirectory(".worktrees/mellow/projects")
        let inner = fixture.root.appendingPathComponent(".worktrees/mellow")
        let found = try #require(JournalRoot.find(from: inner))
        #expect(found.url.lastPathComponent == "mellow")
    }
}

// MARK: - The digest

@Suite("Today — the digest")
struct TodayDigestTests {

    /// The shape of a typical daily: five states, nesting, `@proj(…)`, and two
    /// headings' worth of items.
    private static let daily = """
        # 2026-08-31 Monday

        ## Today

        - [/] Review the draft
        - [ ] Fix the broken links
        - [x] Triage the report
          - [ ] WEB-1892 broken image @proj(launch)
          - [x] WEB-1893 done already
        - [-] Dropped this one
        - [?] Waiting on legal @waiting(legal)

        ## Carried over

        _from 2026-08-28_

        - [/] Quarterly report !!

        ## Done
        """

    private func fixture(dailyDate: String = "2026-08-31") throws -> JournalFixture {
        let fixture = try JournalFixture()
        try fixture.makeJournal()
        let parts = dailyDate.split(separator: "-")
        try fixture.write(
            Self.daily, to: "daily/\(parts[0])/\(parts[1])/\(dailyDate).md")
        return fixture
    }

    @Test("only outstanding items are shown, in document order")
    func outstandingOnly() throws {
        let fixture = try self.fixture()
        let digest = TodayDigest.build(
            root: fixture.journal, on: day("2026-08-31"), calendar: utc)
        let daily = try #require(digest.daily)
        #expect(daily.isToday)

        let substantive = daily.items.filter { !$0.isContext }.map(\.text)
        #expect(
            substantive == [
                "- [/] Review the draft",
                "- [ ] Fix the broken links",
                "- [ ] WEB-1892 broken image @proj(launch)",
                "- [?] Waiting on legal @waiting(legal)",
                "- [/] Quarterly report !!",
            ])
        // `[x]` and `[-]` are gone; the cancelled one is not hiding as context.
        #expect(!substantive.contains { $0.contains("Dropped this one") })
        #expect(!substantive.contains { $0.contains("WEB-1893") })
    }

    /// A ticked parent with an unticked child is the common case. Dropping it
    /// would leave the child indented under nothing.
    @Test("a finished parent is kept as context for an unfinished child")
    func ancestorContext() throws {
        let fixture = try self.fixture()
        let digest = TodayDigest.build(
            root: fixture.journal, on: day("2026-08-31"), calendar: utc)
        let items = try #require(digest.daily).groups[0].items
        let parent = try #require(items.first { $0.text.contains("Triage the report") })
        #expect(parent.isContext)
        #expect(parent.state == .done)
        #expect(parent.depth == 0)

        let child = try #require(items.first { $0.text.contains("WEB-1892") })
        #expect(!child.isContext)
        #expect(child.depth == 1)
    }

    @Test("items are grouped by the heading they sit under")
    func headingGroups() throws {
        let fixture = try self.fixture()
        let digest = TodayDigest.build(
            root: fixture.journal, on: day("2026-08-31"), calendar: utc)
        let groups = try #require(digest.daily).groups
        #expect(groups.map(\.heading) == ["Today", "Carried over"])
        #expect(groups[0].anchor == "today")
        #expect(groups[1].anchor == "carried-over")
        // `## Done` holds nothing outstanding, so it is not a group at all.
        #expect(!groups.contains { $0.heading == "Done" })
    }

    @Test("the counts are of substantive items, not of context")
    func counts() throws {
        let fixture = try self.fixture()
        let digest = TodayDigest.build(
            root: fixture.journal, on: day("2026-08-31"), calendar: utc)
        #expect(digest.inProgress == 2)
        #expect(digest.notStarted == 2)
        #expect(digest.blocked == 1)
        #expect(digest.outstanding == 5)
    }

    /// A page that quietly showed Friday's list on Monday would be wrong in a
    /// way nobody would catch, so the fallback is marked as one.
    @Test("with no daily for today, the most recent one is shown and said so")
    func fallsBackToTheMostRecentDaily() throws {
        let fixture = try self.fixture(dailyDate: "2026-08-28")
        let digest = TodayDigest.build(
            root: fixture.journal, on: day("2026-08-31"), calendar: utc)
        let daily = try #require(digest.daily)
        #expect(!daily.isToday)
        #expect(daily.date == "2026-08-28")
        #expect(digest.expectedDailyPath == "daily/2026/08/2026-08-31.md")
    }

    /// The descent is newest-first and steps back a month, which is the case
    /// the first of a month would otherwise get wrong.
    @Test("the fallback steps back across a month and a year boundary")
    func fallbackCrossesBoundaries() throws {
        let fixture = try JournalFixture()
        try fixture.makeJournal()
        try fixture.write("# old\n\n- [ ] a\n", to: "daily/2025/12/2025-12-31.md")
        try fixture.write("# older\n\n- [ ] b\n", to: "daily/2025/11/2025-11-02.md")
        let digest = TodayDigest.build(
            root: fixture.journal, on: day("2026-01-01"), calendar: utc)
        #expect(try #require(digest.daily).date == "2025-12-31")
    }

    /// A daily dated *after* the day being asked about is not today's work.
    @Test("a future daily is not used as the fallback")
    func fallbackIgnoresTheFuture() throws {
        let fixture = try JournalFixture()
        try fixture.makeJournal()
        try fixture.write("# later\n\n- [ ] a\n", to: "daily/2026/09/2026-09-04.md")
        let digest = TodayDigest.build(
            root: fixture.journal, on: day("2026-08-31"), calendar: utc)
        #expect(digest.daily == nil)
    }

    @Test("no daily at all is a digest with none, and the path it wanted")
    func noDaily() throws {
        let fixture = try JournalFixture()
        try fixture.makeJournal()
        let digest = TodayDigest.build(
            root: fixture.journal, on: day("2026-08-31"), calendar: utc)
        #expect(digest.daily == nil)
        #expect(digest.expectedDailyPath == "daily/2026/08/2026-08-31.md")
        #expect(digest.outstanding == 0)
    }
}

// MARK: - Projects

@Suite("Today — projects")
struct TodayProjectTests {

    private static let launch = """
        # Website launch

        > Started 2026-08-31 · **Status:** active · tag `@proj(launch)`

        ## Open

        - [ ] Rebuild the landing page
        - [x] Read the report

        ## Done
        """

    private static let talks = """
        # Conference talks

        > Started 2026-08-28 · **Status:** paused · tag `@proj(talks)`

        ## Open

        - [/] Draft the abstract
        """

    private func fixture() throws -> JournalFixture {
        let fixture = try JournalFixture()
        try fixture.makeJournal()
        try fixture.write(Self.launch, to: "projects/website-launch/index.md")
        try fixture.write(Self.talks, to: "projects/conference-talks/index.md")
        try fixture.write(
            """
            # 2026-08-31 Monday

            ## Today

            - [ ] Triage the report
              - [ ] WEB-1892 broken image @proj(launch)
              - [/] WEB-1894 missing alt text @proj(launch)
              - [x] WEB-1893 done @proj(launch)
            """, to: "daily/2026/08/2026-08-31.md")
        return fixture
    }

    @Test("title, status and slug come from the front page")
    func headerFacts() throws {
        let fixture = try self.fixture()
        let digest = TodayDigest.build(
            root: fixture.journal, on: day("2026-08-31"), calendar: utc)
        let launch = try #require(digest.projects.first { $0.slug == "launch" })
        #expect(launch.title == "Website launch")
        #expect(launch.status == "active")
        // The slug is the `@proj(…)` that is actually written, not the
        // directory name — the rollup has to match what the tags say.
        #expect(launch.front.deletingLastPathComponent().lastPathComponent == "website-launch")
    }

    @Test("active projects sort above paused ones")
    func statusOrder() throws {
        let fixture = try self.fixture()
        let digest = TodayDigest.build(
            root: fixture.journal, on: day("2026-08-31"), calendar: utc)
        #expect(digest.projects.map(\.slug) == ["launch", "talks"])
    }

    /// The whole point of the rollup: a project's open items include the ones
    /// tagged for it in today's daily, which is where the day's work is.
    @Test("@proj-tagged items in the daily roll up under their project")
    func rollup() throws {
        let fixture = try self.fixture()
        let digest = TodayDigest.build(
            root: fixture.journal, on: day("2026-08-31"), calendar: utc)
        let launch = try #require(digest.projects.first { $0.slug == "launch" })

        #expect(launch.own.flatMap(\.items).map(\.text) == ["- [ ] Rebuild the landing page"])

        let tagged = try #require(launch.tagged.first)
        #expect(tagged.file.lastPathComponent == "2026-08-31.md")
        #expect(
            tagged.items.map(\.text) == [
                "- [ ] WEB-1892 broken image @proj(launch)",
                "- [/] WEB-1894 missing alt text @proj(launch)",
            ])
        // Lifted out of the daily's structure: the untagged parent does not
        // come with them, and neither does their indentation.
        #expect(tagged.items.allSatisfy { $0.depth == 0 })
        #expect(!tagged.items.contains { $0.text.contains("Triage") })
    }

    @Test("a project with nothing open says so rather than vanishing")
    func nothingOpen() throws {
        let fixture = try JournalFixture()
        try fixture.makeJournal()
        try fixture.write(
            """
            # Quiet

            > **Status:** active · tag `@proj(quiet)`

            ## Open
            """, to: "projects/quiet/index.md")
        let digest = TodayDigest.build(
            root: fixture.journal, on: day("2026-08-31"), calendar: utc)
        let quiet = try #require(digest.projects.first)
        #expect(quiet.hasNothingOpen)
    }

    /// `projects/<slug>.md`, the flat form of a project's front page. A
    /// file sitting there that the page ignored would look like a
    /// bug.
    @Test("a bare projects/<slug>.md is a project too")
    func flatProject() throws {
        let fixture = try JournalFixture()
        try fixture.makeJournal()
        try fixture.write(
            "# Flat\n\n> **Status:** active\n\n- [ ] one thing\n", to: "projects/flat.md")
        let digest = TodayDigest.build(
            root: fixture.journal, on: day("2026-08-31"), calendar: utc)
        let flat = try #require(digest.projects.first)
        #expect(flat.slug == "flat")
        #expect(flat.title == "Flat")
        #expect(flat.own.flatMap(\.items).map(\.text) == ["- [ ] one thing"])
    }

    /// The front page sorts first, and a sub-note's items are captioned with
    /// the file they are in.
    @Test("a project's other files contribute their own groups")
    func subNotes() throws {
        let fixture = try JournalFixture()
        try fixture.makeJournal()
        try fixture.write(
            "# P\n\n> **Status:** active\n\n- [ ] front\n", to: "projects/p/index.md")
        try fixture.write("# Notes\n\n- [/] side\n", to: "projects/p/notes.md")
        let digest = TodayDigest.build(
            root: fixture.journal, on: day("2026-08-31"), calendar: utc)
        let p = try #require(digest.projects.first)
        #expect(p.own.map { $0.file.lastPathComponent } == ["index.md", "notes.md"])
    }

    @Test("every file the page was built from is watched")
    func sourceFiles() throws {
        let fixture = try self.fixture()
        let digest = TodayDigest.build(
            root: fixture.journal, on: day("2026-08-31"), calendar: utc)
        let names = Set(digest.sourceFiles.map(\.lastPathComponent))
        #expect(names == ["2026-08-31.md", "index.md"])
    }
}

// MARK: - Nesting

@Suite("Today — nesting")
struct TodayNestingTests {

    /// A four-space indent copied verbatim into a list that starts at column
    /// zero is an **indented code block**, not a nested item. Normalising is
    /// what stops that.
    @Test("indent widths become consecutive levels")
    func ranks() {
        #expect(TodayDigest.depthRanks(for: [0, 2, 4, 2, 0]) == [0, 1, 2, 1, 0])
        #expect(TodayDigest.depthRanks(for: [4, 8, 12]) == [0, 1, 2])
    }

    /// A child whose parent was filtered out cannot be two levels deeper than
    /// the item above it — there is nothing in between for it to hang from.
    @Test("no level is more than one deeper than the one before it")
    func clamped() {
        #expect(TodayDigest.depthRanks(for: [0, 8]) == [0, 1])
        #expect(TodayDigest.depthRanks(for: [4, 0]) == [0, 0])
    }

    @Test("a tab counts as four columns")
    func tabs() {
        #expect(TodayDigest.indentWidth(of: "\t- [ ] x") == 4)
        #expect(TodayDigest.indentWidth(of: "  - [ ] x") == 2)
        #expect(TodayDigest.indentWidth(of: "- [ ] x") == 0)
    }
}

// MARK: - The page

@Suite("Today — the page")
struct TodayPageTests {

    private func digest(on date: String = "2026-08-31") throws -> TodayDigest {
        let fixture = try JournalFixture()
        try fixture.makeJournal()
        try fixture.write(
            """
            # 2026-08-31 Monday

            ## Today

            - [/] Review the draft
            - [ ] Copy edits @proj(launch)

            ## Carried over

            - [ ] Quarterly report !!
            """, to: "daily/2026/08/2026-08-31.md")
        try fixture.write(
            """
            # Website launch

            > **Status:** active · tag `@proj(launch)`

            ## Open

            - [ ] Rebuild the landing page
            """, to: "projects/launch/index.md")
        // Held for the life of the call: the fixture deletes its directory on
        // `deinit`, and the digest is built by reading it.
        let built = TodayDigest.build(root: fixture.journal, on: day(date), calendar: utc)
        withExtendedLifetime(fixture) {}
        return built
    }

    @Test("the page opens with the date and a count of what is outstanding")
    func header() throws {
        let page = TodayPage.markdown(for: try digest(), locale: Locale(identifier: "en_GB"))
        let lines = page.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0].contains("Monday"))
        #expect(lines[0].contains("2026"))
        #expect(page.contains("> **1** in progress · **2** not started"))
        // Nothing is blocked, so nothing says so.
        #expect(!page.contains("blocked"))
    }

    /// **Angle brackets, always.** `shell.js` reports `getAttribute("href")`
    /// verbatim and ``DocumentView`` resolves it as a file path, so a
    /// destination that reached the page as `my%20project` would be looked for
    /// under that literal name.
    @Test("every link destination is angle-bracketed and relative to the root")
    func links() throws {
        let page = TodayPage.markdown(for: try digest())
        #expect(page.contains("(<daily/2026/08/2026-08-31.md>)"))
        #expect(page.contains("(<daily/2026/08/2026-08-31.md#carried-over>)"))
        #expect(page.contains("(<projects/launch/index.md>)"))
        #expect(!page.contains("](/"))
    }

    @Test("items keep their own source line, tags and priority included")
    func verbatimItems() throws {
        let page = TodayPage.markdown(for: try digest())
        #expect(page.contains("- [/] Review the draft"))
        #expect(page.contains("- [ ] Quarterly report !!"))
        #expect(page.contains("- [ ] Copy edits @proj(launch)"))
    }

    @Test("a project shows its own items and the ones tagged for it")
    func projectSection() throws {
        let page = TodayPage.markdown(for: try digest())
        #expect(page.contains("### [Website launch](<projects/launch/index.md>) · active"))
        #expect(page.contains("- [ ] Rebuild the landing page"))
        #expect(page.contains("`@proj(launch)`"))
    }

    /// `## Today` followed by **Today** reads as a mistake.
    @Test("a single heading group gets no caption")
    func singleGroupIsUncaptioned() throws {
        let fixture = try JournalFixture()
        try fixture.makeJournal()
        try fixture.write(
            "# 2026-08-31\n\n## Today\n\n- [ ] one\n", to: "daily/2026/08/2026-08-31.md")
        let page = TodayPage.markdown(
            for: TodayDigest.build(root: fixture.journal, on: day("2026-08-31"), calendar: utc))
        #expect(!page.contains("**[Today]"))
        #expect(page.contains("- [ ] one"))
    }

    @Test("no daily names the file it wanted")
    func noDaily() throws {
        let fixture = try JournalFixture()
        try fixture.makeJournal()
        let page = TodayPage.markdown(
            for: TodayDigest.build(root: fixture.journal, on: day("2026-08-31"), calendar: utc))
        #expect(page.contains("daily/2026/08/2026-08-31.md"))
        #expect(page.contains("Nothing outstanding today."))
    }

    /// An empty page and "you have nothing to do" must not look the same.
    @Test("with no journal the page says what it looked for and where")
    func notAJournal() {
        let page = TodayPage.notAJournal(startingFrom: URL(fileURLWithPath: "/tmp/somewhere"))
        #expect(page.contains("`daily/`"))
        #expect(page.contains("`projects/`"))
        #expect(page.contains("/tmp/somewhere"))
    }

    @Test("a path that cannot be angle-bracketed is not made into a link")
    func refusesAnImpossibleLink() {
        #expect(TodayPage.link("t", to: "a<b>.md") == "t")
        #expect(TodayPage.link("t", to: "ok.md") == "[t](<ok.md>)")
    }

    @Test("brackets in an item's own text do not close the link label")
    func escapesLabels() {
        #expect(TodayPage.link("a [b] c", to: "x.md") == "[a \\[b\\] c](<x.md>)")
    }
}

// MARK: - Following a link with a fragment

/// `2026-08-31-today-page`. Both halves used to be missing, which is why they
/// are pinned: a destination is percent-encoded on its way into the page, and a
/// `#heading` on a cross-file link was looked for as part of the filename.
@Suite("Documents — link destinations")
struct LinkDestinationTests {

    @Test("the first # separates the path from the anchor")
    func split() {
        #expect(DocumentView.split(href: "a.md#open").path == "a.md")
        #expect(DocumentView.split(href: "a.md#open").fragment == "open")
        #expect(DocumentView.split(href: "a.md").fragment == nil)
        // An empty fragment is no fragment.
        #expect(DocumentView.split(href: "a.md#").fragment == nil)
        // The first, so an anchor containing one keeps it.
        #expect(DocumentView.split(href: "a.md#a#b").fragment == "a#b")
    }
}

// MARK: - Copied lines

/// `2026-08-31-today-page`. Copying an item's line verbatim is what keeps its
/// links and tags intact, and it is also the one thing that can silently point
/// a link at the wrong file.
@Suite("Today — re-basing a copied line")
struct MarkdownLinkTests {

    private let project = URL(fileURLWithPath: "/j/projects/talks", isDirectory: true)
    private let root = URL(fileURLWithPath: "/j", isDirectory: true)

    @Test("a relative link is re-based onto the root")
    func relative() {
        #expect(
            MarkdownLinks.rebase("- [/] See [notes](./notes.md)", from: project, to: root)
                == "- [/] See [notes](<projects/talks/notes.md>)")
        #expect(
            MarkdownLinks.rebase("[a](sub/b.md)", from: project, to: root)
                == "[a](<projects/talks/sub/b.md>)")
        #expect(
            MarkdownLinks.rebase("[a](../other/b.md)", from: project, to: root)
                == "[a](<projects/other/b.md>)")
    }

    @Test("an anchor on a relative link survives the move")
    func fragment() {
        #expect(
            MarkdownLinks.rebase("[a](./notes.md#open)", from: project, to: root)
                == "[a](<projects/talks/notes.md#open>)")
    }

    /// A bare `#anchor` means "this page" and is the one relative destination
    /// that must not be re-based.
    @Test("absolute destinations and bare anchors are left alone")
    func untouched() {
        for line in [
            "[a](https://example.com/x)",
            "[a](mailto:someone@example.com)",
            "[a](/absolute/x.md)",
            "[a](#a-heading)",
            "an autolink <https://example.com/x>",
        ] {
            #expect(MarkdownLinks.rebase(line, from: project, to: root) == line)
        }
    }

    @Test("a link out of the journal keeps an absolute path")
    func outsideTheRoot() {
        #expect(
            MarkdownLinks.rebase("[a](../../../elsewhere.md)", from: project, to: root)
                == "[a](</elsewhere.md>)")
    }

    /// The rewriter is not a markdown parser, so what it does with things it
    /// does not understand is part of the contract.
    @Test("code spans, titles and unbalanced parentheses")
    func edges() {
        // Inside a code span it is not a link.
        #expect(
            MarkdownLinks.rebase("`[a](./b.md)`", from: project, to: root) == "`[a](./b.md)`")
        // A title survives.
        #expect(
            MarkdownLinks.rebase("[a](./b.md \"t\")", from: project, to: root)
                == "[a](<projects/talks/b.md> \"t\")")
        // An already-bracketed destination is understood.
        #expect(
            MarkdownLinks.rebase("[a](<./b c.md>)", from: project, to: root)
                == "[a](<projects/talks/b c.md>)")
        // Nothing that could be a link is left as it was.
        #expect(MarkdownLinks.rebase("just ](text", from: project, to: root) == "just ](text")
        #expect(MarkdownLinks.rebase("no links here", from: project, to: root) == "no links here")
    }

    @Test("an item copied out of a project has its link fixed")
    func endToEnd() throws {
        let fixture = try JournalFixture()
        try fixture.makeJournal()
        try fixture.write(
            """
            # Talks

            > **Status:** active

            ## Open

            - [/] Review [the outline](./outline.md)
            """, to: "projects/talks/index.md")
        try fixture.write("# Outline\n", to: "projects/talks/outline.md")
        let digest = TodayDigest.build(
            root: fixture.journal, on: day("2026-08-31"), calendar: utc)
        let item = try #require(digest.projects.first?.own.first?.items.first)
        #expect(item.text == "- [/] Review [the outline](<projects/talks/outline.md>)")
    }
}

// MARK: - Placeholders

/// The journal's templates ship `## Open` with a bare `- [ ]` under it. It is a
/// real marker in a real file, and an empty checkbox on a page whose whole job
/// is "what is outstanding" is noise.
@Suite("Today — template placeholders")
struct TodayPlaceholderTests {

    @Test("an empty task is not an outstanding item")
    func emptyTaskIsSkipped() throws {
        let fixture = try JournalFixture()
        try fixture.makeJournal()
        try fixture.write(
            "# P\n\n> **Status:** active\n\n## Open\n\n- [ ] \n", to: "projects/p/index.md")
        try fixture.write(
            "# 2026-08-31\n\n## Today\n\n- [ ] \n- [ ] real work\n",
            to: "daily/2026/08/2026-08-31.md")
        let digest = TodayDigest.build(
            root: fixture.journal, on: day("2026-08-31"), calendar: utc)

        #expect(try #require(digest.projects.first).hasNothingOpen)
        #expect(digest.daily?.items.map(\.text) == ["- [ ] real work"])
        #expect(digest.notStarted == 1)
    }

    /// A task whose text is only a tag says something; it is not a placeholder.
    @Test("a task that is only a tag is kept")
    func tagOnlyTaskIsKept() throws {
        let fixture = try JournalFixture()
        try fixture.makeJournal()
        try fixture.write(
            "# 2026-08-31\n\n## Today\n\n- [ ] @hold\n", to: "daily/2026/08/2026-08-31.md")
        let digest = TodayDigest.build(
            root: fixture.journal, on: day("2026-08-31"), calendar: utc)
        #expect(digest.daily?.items.map(\.text) == ["- [ ] @hold"])
    }
}
