import Foundation

/// One task, as the **Today** page will emit it.
///
/// The text is the task's **own source line**, not ``Task/text`` or
/// ``Task/label``. Both of those are flattened plain text, and a daily is full
/// of items like `- [ ] More website issues <https://…>` whose link would
/// arrive as bare words. Copying the line verbatim is also exactly what the
/// journal's own carry-forward does, and for the same reason: *links, `@tags`,
/// priorities and the state byte all survive*.
public struct TodayItem: Equatable, Sendable {

    /// The source line with its indentation stripped and trailing whitespace
    /// removed. Trailing whitespace goes because two trailing spaces are a hard
    /// line break, which would be a stray `<br>` in a list the reader never
    /// asked for.
    public let text: String

    /// Nesting, normalised so the shallowest item in its group is `0` and no
    /// item is ever more than one level deeper than the one before it.
    ///
    /// Both halves matter. A four-space indent copied verbatim into a page
    /// whose list starts at column zero is an **indented code block**, not a
    /// nested item; and a child whose parent was filtered out would otherwise
    /// be indented under nothing.
    public let depth: Int

    public let state: TaskState

    /// Whether this item is here in its own right, or only to keep an included
    /// descendant attached to something.
    ///
    /// A finished parent with unfinished children is the common case — a
    /// "Triage WEB-1892–1896" ticked off while three of its five children are
    /// not — and dropping it would leave the children floating.
    public let isContext: Bool

    /// The task's index and its marker's byte offset in the file it came from.
    ///
    /// Carried, and currently read by nothing: they are the identity
    /// `DocumentView.scrollToTask(index:byteOffset:)` wants, so landing on the
    /// item itself rather than on the heading above it is a later change to the
    /// link and not to the digest.
    public let index: Int
    public let byteOffset: Int
}

/// Items from one file, under one of that file's headings.
public struct TodayGroup: Equatable, Sendable {

    public let file: URL

    /// The heading these items sit under in `file`, and its anchor — so the
    /// caption can be a link that lands on that section rather than on the top
    /// of the document. `nil` for items above the file's first heading.
    public let heading: String?
    public let anchor: String?

    public let items: [TodayItem]

    /// Items that are here in their own right, context excluded. What the
    /// counts are taken over.
    public var substantive: [TodayItem] { items.filter { !$0.isContext } }
}

/// The daily note the page is reporting on.
public struct DailySection: Equatable, Sendable {
    public let file: URL
    /// The date in the file's name, `yyyy-MM-dd`.
    public let date: String
    /// Whether that is the date the page was built for. `false` means today's
    /// daily does not exist and this is the most recent one instead.
    public let isToday: Bool
    public let groups: [TodayGroup]

    public var items: [TodayItem] { groups.flatMap(\.items) }
}

/// One effort under `projects/`.
public struct ProjectSection: Equatable, Sendable {

    /// The value the `@proj(…)` tag uses. Taken from the `@proj(…)` written in
    /// the project's own front page when there is one, so the rollup matches
    /// what is actually tagged rather than what the directory happens to be
    /// called; the directory name is the fallback.
    public let slug: String

    public let title: String

    /// The word after `**Status:**` in the front page's header line — `active`,
    /// `paused`, `blocked`, `done`, `dropped` — or `nil` when there is no such
    /// line. Not validated against that list: an unrecognised status is the
    /// author's word and is shown as written.
    public let status: String?

    /// The front page. `projects/<slug>/index.md`, or `projects/<slug>.md`.
    public let front: URL

    /// Outstanding tasks in the project's own files, front page first.
    public let own: [TodayGroup]

    /// Outstanding tasks tagged `@proj(slug)` in the daily.
    public let tagged: [TodayGroup]

    public var hasNothingOpen: Bool { own.isEmpty && tagged.isEmpty }

    /// Where a status sorts. Work in flight first, parked next, finished last;
    /// an unrecognised word and a missing one both sit in the middle, because
    /// the one thing that can be said about them is that they are not one of
    /// the states with a defined meaning.
    public var statusRank: Int {
        switch status?.lowercased() {
        case "active": return 0
        case "blocked": return 1
        case "paused", "hold", "on-hold": return 2
        case "done": return 4
        case "dropped": return 5
        default: return 3
        }
    }
}

/// Everything the **Today** page shows, assembled from the journal.
///
/// `2026-08-31-today-page`. Deliberately a value with no AppKit in it: the
/// window renders it and the tests build one against a fixture journal on disk,
/// and neither needs the other.
public struct TodayDigest: Equatable, Sendable {

    public let root: JournalRoot

    /// The date this was built for. Supplied by the caller — the core reads no
    /// clock (`2026-08-27-inline-task-metadata`) and neither does this, so a
    /// test can ask for any day and get a deterministic answer.
    public let date: Date

    /// `yyyy-MM-dd` for ``date``.
    public let today: String

    /// Where today's daily would be, relative to the root — named even when it
    /// exists, because it is the thing the empty state has to say.
    public let expectedDailyPath: String

    public let daily: DailySection?

    public let projects: [ProjectSection]

    /// Outstanding counts across ``daily``, context excluded.
    public let inProgress: Int
    public let notStarted: Int
    public let blocked: Int

    public var outstanding: Int { inProgress + notStarted + blocked }

    // MARK: - Bounds

    /// How many entries under `projects/` are read before the walk stops, and
    /// how many files are read inside one project.
    ///
    /// The sidebar is forbidden from descending eagerly because the real tree
    /// it was measured against holds 608k files
    /// (`2026-08-27-sidebar-polls-listed-directories`). This walk is already
    /// narrow — `projects/` one level down, then each project one level down —
    /// but a bound is what makes that a property of the code rather than of the
    /// directory it happened to be pointed at.
    public static let maximumProjects = 200
    public static let maximumFilesPerProject = 64

    // MARK: - Building

    /// Read the journal and assemble the page's contents.
    ///
    /// Every file read here is one of: today's daily (one path, no search), the
    /// most recent daily (a bounded descent of `daily/`, newest first), or a
    /// markdown file under `projects/`. Nothing walks the journal at large.
    public static func build(
        root: JournalRoot,
        on date: Date,
        calendar: Calendar = .current
    ) -> TodayDigest {
        let today = isoDate(date, calendar: calendar)
        let relativeDaily = dailyRelativePath(for: date, calendar: calendar)
        let todaysFile = root.url.appendingPathComponent(relativeDaily)

        var daily: DailySection?
        var dailySource: String?
        if let source = try? DocumentSource.read(todaysFile) {
            dailySource = source
            daily = DailySection(
                file: todaysFile,
                date: today,
                isToday: true,
                groups: groups(for: todaysFile, source: source, root: root.url))
        } else if let recent = mostRecentDaily(in: root, notAfter: today),
            let source = try? DocumentSource.read(recent.url)
        {
            dailySource = source
            daily = DailySection(
                file: recent.url,
                date: recent.date,
                isToday: false,
                groups: groups(for: recent.url, source: source, root: root.url))
        }

        let tagged: [String: [TodayItem]]
        if let daily, let dailySource {
            tagged = taggedItems(in: daily.file, source: dailySource, root: root.url)
        } else {
            tagged = [:]
        }

        let items = (daily?.items ?? []).filter { !$0.isContext }
        return TodayDigest(
            root: root,
            date: date,
            today: today,
            expectedDailyPath: relativeDaily,
            daily: daily,
            projects: projectSections(in: root, tagged: tagged, taggedFile: daily?.file),
            inProgress: items.filter { $0.state == .inProgress }.count,
            notStarted: items.filter { $0.state == .open }.count,
            blocked: items.filter { $0.state == .blocked }.count)
    }

    /// Every file this digest drew an item from, plus each project's front
    /// page — what the window watches.
    ///
    /// Deliberately not "every file under `projects/`": a sub-note with no
    /// outstanding task in it contributed nothing to the page, so a save to it
    /// has nothing to re-render. Adding the *first* task to such a file is
    /// therefore picked up when the window next becomes key rather than
    /// immediately, which is the same bound that applies to a project created
    /// while the window is open.
    public var sourceFiles: Set<URL> {
        var files: Set<URL> = []
        if let daily { files.insert(daily.file) }
        for project in projects {
            files.insert(project.front)
            for group in project.own { files.insert(group.file) }
        }
        return files
    }

    // MARK: - Dailies

    /// `daily/2026/08/2026-08-31.md`, the journal's own layout.
    public static func dailyRelativePath(for date: Date, calendar: Calendar = .current) -> String {
        let iso = isoDate(date, calendar: calendar)
        let year = String(iso.prefix(4))
        let month = String(iso.dropFirst(5).prefix(2))
        return "\(JournalRoot.dailyDirectory)/\(year)/\(month)/\(iso).md"
    }

    /// `yyyy-MM-dd` in the calendar's own time zone.
    ///
    /// Hand-formatted rather than `DateFormatter`'d because this string is a
    /// *path component* and a filename, not something a reader sees: a locale
    /// with a non-Gregorian calendar or non-ASCII digits would name a file that
    /// does not exist.
    public static func isoDate(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The newest daily on or before `date`.
    ///
    /// Found by listing directories newest-first and stopping at the first hit
    /// — `daily/` for years, then that year for months, then that month for
    /// days — rather than by walking `daily/`. A journal with ten years of
    /// history costs the same three listings as one with a week, and the step
    /// back to an earlier month (and then an earlier year) is what makes the
    /// first day of a month behave.
    static func mostRecentDaily(
        in root: JournalRoot,
        notAfter date: String
    ) -> (url: URL, date: String)? {
        for year in numericDirectories(in: root.daily) {
            for month in numericDirectories(in: year) {
                let newest =
                    markdownFiles(in: month)
                    .compactMap { url -> (url: URL, date: String)? in
                        let name = url.deletingPathExtension().lastPathComponent
                        guard isISODate(name), name <= date else { return nil }
                        return (url, name)
                    }
                    .max { $0.date < $1.date }
                if let newest { return newest }
            }
        }
        return nil
    }

    /// Sub-directories whose names are numbers, newest first. `daily/` holds
    /// years and a year holds months; anything else in there is not ours.
    private static func numericDirectories(in url: URL) -> [URL] {
        guard let entries = try? MarkCore.tree(directory: url.path, depth: 1) else { return [] }
        return
            entries
            .filter { $0.isDirectory && Int($0.name) != nil }
            .sorted { $0.name > $1.name }
            .map { URL(fileURLWithPath: $0.path) }
    }

    /// The markdown files in one directory. The core's listing rather than
    /// `FileManager`'s, so "which files are markdown" has one answer in this
    /// app.
    private static func markdownFiles(in url: URL) -> [URL] {
        guard let entries = try? MarkCore.tree(directory: url.path, depth: 1) else { return [] }
        return entries.filter { !$0.isDirectory }.map { URL(fileURLWithPath: $0.path) }
    }

    static func isISODate(_ name: String) -> Bool {
        guard name.count == 10 else { return false }
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2
        else { return false }
        return parts.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    // MARK: - Projects

    static func projectSections(
        in root: JournalRoot,
        tagged: [String: [TodayItem]],
        taggedFile: URL?
    ) -> [ProjectSection] {
        guard let entries = try? MarkCore.tree(directory: root.projects.path, depth: 1) else {
            return []
        }

        var sections: [ProjectSection] = []
        for entry in entries.prefix(maximumProjects) {
            let url = URL(fileURLWithPath: entry.path)
            let section =
                entry.isDirectory
                ? directoryProject(
                    at: url, root: root.url, tagged: tagged, taggedFile: taggedFile)
                : fileProject(at: url, root: root.url, tagged: tagged, taggedFile: taggedFile)
            if let section { sections.append(section) }
        }

        return sections.sorted {
            if $0.statusRank != $1.statusRank { return $0.statusRank < $1.statusRank }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    /// `projects/<slug>/`, whose front page is `index.md`.
    ///
    /// A directory with no `index.md` is still a project — the front page is
    /// then whichever markdown file sorts first — because a directory under
    /// `projects/` that the page silently ignored would be worse than one shown
    /// without a status.
    private static func directoryProject(
        at url: URL,
        root: URL,
        tagged: [String: [TodayItem]],
        taggedFile: URL?
    ) -> ProjectSection? {
        guard let entries = try? MarkCore.tree(directory: url.path, depth: 1) else { return nil }
        let files = Array(
            entries
                .filter { !$0.isDirectory }
                .map { URL(fileURLWithPath: $0.path) }
                .sorted(by: frontPageOrder)
                .prefix(maximumFilesPerProject))
        guard let front = files.first,
            let frontSource = try? DocumentSource.read(front)
        else { return nil }

        let directoryName = url.lastPathComponent
        let header = headerFacts(of: frontSource, fallbackTitle: directoryName)
        let slug = header.slug ?? directoryName

        var own: [TodayGroup] = []
        for file in files {
            let source = file == front ? frontSource : (try? DocumentSource.read(file))
            guard let source else { continue }
            own += groups(for: file, source: source, root: root)
        }

        return ProjectSection(
            slug: slug,
            title: header.title,
            status: header.status,
            front: front,
            own: own,
            tagged: taggedGroups(for: slug, from: tagged, file: taggedFile))
    }

    /// `projects/<slug>.md` — the flat form the tag table in the journal's own
    /// README describes. Rarer than the directory form and supported for the
    /// same reason: a file sitting there that the page ignored would look like
    /// a bug.
    private static func fileProject(
        at url: URL,
        root: URL,
        tagged: [String: [TodayItem]],
        taggedFile: URL?
    ) -> ProjectSection? {
        guard let source = try? DocumentSource.read(url) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        let header = headerFacts(of: source, fallbackTitle: name)
        let slug = header.slug ?? name
        return ProjectSection(
            slug: slug,
            title: header.title,
            status: header.status,
            front: url,
            own: groups(for: url, source: source, root: root),
            tagged: taggedGroups(for: slug, from: tagged, file: taggedFile))
    }

    /// `index.md` first, then everything else by name — the ordering the
    /// journal's own README relies on (*"`index.md` sorts first, so the front
    /// page is always the top of the listing"*), stated here rather than
    /// inherited from the alphabet.
    static func frontPageOrder(_ a: URL, _ b: URL) -> Bool {
        let aIsIndex = a.lastPathComponent.lowercased() == "index.md"
        let bIsIndex = b.lastPathComponent.lowercased() == "index.md"
        if aIsIndex != bIsIndex { return aIsIndex }
        return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent)
            == .orderedAscending
    }

    /// Title, status and slug, from a project's front page.
    static func headerFacts(of source: String, fallbackTitle: String)
        -> (title: String, status: String?, slug: String?)
    {
        let headings = (try? MarkCore.toc(source: source)) ?? []
        let heading = headings.first(where: { $0.level == 1 }) ?? headings.first
        let title = heading?.text ?? ""

        var status: String?
        var slug: String?
        // The header line is the second or third line of the journal's project
        // template, so a bounded scan finds it. Scanning the whole document
        // would also find a `**Status:**` quoted down in the log, which is
        // somebody's note about the past rather than the project's state now.
        for line in source.split(separator: "\n", omittingEmptySubsequences: false).prefix(12) {
            if status == nil { status = word(in: line, after: "**Status:**") }
            if slug == nil { slug = projectTagValue(in: line) }
        }
        return (title.isEmpty ? fallbackTitle : title, status, slug)
    }

    /// The first bare word after `marker` on a line.
    static func word(in line: Substring, after marker: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        let word =
            line[range.upperBound...]
            .drop(while: { $0 == " " || $0 == "*" })
            .prefix(while: { $0.isLetter || $0 == "-" })
        return word.isEmpty ? nil : String(word)
    }

    /// The value in the first `@proj(…)` on a line.
    static func projectTagValue(in line: Substring) -> String? {
        guard let start = line.range(of: "@proj(") else { return nil }
        let rest = line[start.upperBound...]
        guard let close = rest.firstIndex(of: ")") else { return nil }
        let value = rest[rest.startIndex..<close]
        return value.isEmpty ? nil : String(value)
    }

    /// The daily's outstanding tasks that carry a `@proj(…)`, by slug.
    ///
    /// **Flat, and only the tagged item.** A tagged item is lifted out of the
    /// daily's structure and shown under its project, so neither its nesting
    /// nor its untagged parent travels with it: `- [ ] Triage WEB-1892–1896`
    /// is not tagged, and the five children that are belong under the project
    /// on their own terms.
    static func taggedItems(in file: URL, source: String, root: URL) -> [String: [TodayItem]] {
        guard let tasks = try? MarkCore.tasks(source: source) else { return [:] }
        let lines = sourceLines(source)
        var bySlug: [String: [TodayItem]] = [:]
        for task in tasks where isOutstandingWork(task) {
            for tag in task.tags where tag.name == "proj" {
                guard let slug = tag.value, !slug.isEmpty else { continue }
                bySlug[slug, default: []].append(
                    TodayItem(
                        text: strippedLine(for: task, in: lines, of: file, in: root),
                        depth: 0,
                        state: task.state,
                        isContext: false,
                        index: task.index,
                        byteOffset: task.start))
            }
        }
        return bySlug
    }

    /// The rollup as a group, keyed to the file it came from so the caption can
    /// link there.
    private static func taggedGroups(
        for slug: String,
        from tagged: [String: [TodayItem]],
        file: URL?
    ) -> [TodayGroup] {
        guard let items = tagged[slug], !items.isEmpty, let file else { return [] }
        return [TodayGroup(file: file, heading: nil, anchor: nil, items: items)]
    }

    // MARK: - Selecting and nesting

    /// One file's matching tasks, grouped by the heading they sit under, with
    /// their nesting normalised per group.
    static func groups(
        for file: URL,
        source: String,
        root: URL,
        include: (Task) -> Bool = isOutstandingWork
    ) -> [TodayGroup] {
        guard let tasks = try? MarkCore.tasks(source: source), !tasks.isEmpty else { return [] }
        let headings = (try? MarkCore.toc(source: source)) ?? []
        let lines = sourceLines(source)
        let indents = tasks.map { indentWidth(of: lineText(for: $0, in: lines)) }

        let chosen = withAncestors(of: tasks, indents: indents, include: include)
        guard !chosen.isEmpty else { return [] }

        // Runs of consecutive tasks under the same heading. Document order
        // throughout: the reader's mental model of the page is the file.
        var runs: [(heading: Heading?, entries: [(index: Int, isContext: Bool)])] = []
        for entry in chosen {
            let heading = headings.last(where: { $0.start <= tasks[entry.index].start })
            if !runs.isEmpty, runs[runs.count - 1].heading?.anchor == heading?.anchor {
                runs[runs.count - 1].entries.append(entry)
            } else {
                runs.append((heading, [entry]))
            }
        }

        return runs.compactMap { run -> TodayGroup? in
            // A run holding nothing but context is an ancestor whose included
            // descendants all landed under a later heading. It is not a group.
            guard run.entries.contains(where: { !$0.isContext }) else { return nil }
            let ranks = depthRanks(for: run.entries.map { indents[$0.index] })
            let items = run.entries.enumerated().map { position, entry -> TodayItem in
                let task = tasks[entry.index]
                return TodayItem(
                    text: strippedLine(for: task, in: lines, of: file, in: root),
                    depth: ranks[position],
                    state: task.state,
                    isContext: entry.isContext,
                    index: task.index,
                    byteOffset: task.start)
            }
            return TodayGroup(
                file: file,
                heading: run.heading?.text,
                anchor: run.heading?.anchor,
                items: items)
        }
    }

    /// The indices `include` chose, plus every ancestor needed to keep them
    /// attached, in document order.
    static func withAncestors(
        of tasks: [Task],
        indents: [Int],
        include: (Task) -> Bool
    ) -> [(index: Int, isContext: Bool)] {
        var wanted = Set<Int>()
        for (i, task) in tasks.enumerated() where include(task) {
            wanted.insert(i)
        }
        var context = Set<Int>()
        for i in wanted {
            // Walk back, taking each task shallower than the shallowest one
            // taken so far. That is the ancestor chain: a sibling is never
            // shallower than its sibling, and the walk stops at column zero.
            var floor = indents[i]
            var j = i - 1
            while j >= 0, floor > 0 {
                if indents[j] < floor {
                    floor = indents[j]
                    if !wanted.contains(j) { context.insert(j) }
                }
                j -= 1
            }
        }
        return wanted.union(context).sorted().map {
            (index: $0, isContext: !wanted.contains($0))
        }
    }

    /// Indent widths to nesting levels: distinct widths become 0, 1, 2…, and no
    /// level is ever more than one deeper than its predecessor.
    static func depthRanks(for indents: [Int]) -> [Int] {
        let ladder = Set(indents).sorted()
        var previous = -1
        return indents.map { width in
            let rank = ladder.firstIndex(of: width) ?? 0
            let clamped = min(rank, previous + 1)
            previous = clamped
            return clamped
        }
    }

    // MARK: - Source lines

    static func sourceLines(_ source: String) -> [Substring] {
        source.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// The whole source line a task's marker is on. `Task.line` is 1-based.
    static func lineText(for task: Task, in lines: [Substring]) -> String {
        let index = task.line - 1
        guard lines.indices.contains(index) else { return "" }
        // A file with CRLF endings keeps its `\r` after a split on `\n`.
        var line = String(lines[index])
        if line.hasSuffix("\r") { line.removeLast() }
        return line
    }

    /// The same line, with its indentation and trailing whitespace gone and
    /// its relative links re-based onto the journal root.
    ///
    /// The re-basing is what makes copying the line verbatim safe: `./notes.md`
    /// in a project's front page means that project's directory, and on a page
    /// based at the root it would mean the root. See ``MarkdownLinks``.
    static func strippedLine(for task: Task, in lines: [Substring], of file: URL, in root: URL)
        -> String
    {
        var trimmed = String(lineText(for: task, in: lines).drop(while: { $0 == " " || $0 == "\t" }))
        while let last = trimmed.last, last == " " || last == "\t" { trimmed.removeLast() }
        return MarkdownLinks.rebase(trimmed, from: file.deletingLastPathComponent(), to: root)
    }

    /// Outstanding, and actually says something.
    ///
    /// The journal's own templates ship `## Open` with a bare `- [ ]` under it,
    /// waiting to be typed into. It is a real task marker in a real file and
    /// the core is right to report it — but an empty checkbox on a page whose
    /// whole job is "what is outstanding" is noise, and a project whose only
    /// open item is its own placeholder should read as having nothing open.
    static func isOutstandingWork(_ task: Task) -> Bool {
        task.state.isOutstanding
            && !task.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A line's indentation in columns, with tabs counted as four.
    ///
    /// Four because that is the width markdown's own indented-code-block rule
    /// uses, so a document mixing tabs and spaces nests here the way it nests
    /// when rendered.
    static func indentWidth(of line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " {
                width += 1
            } else if character == "\t" {
                width += 4
            } else {
                break
            }
        }
        return width
    }
}
