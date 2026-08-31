import Foundation

/// The **Today** page as markdown, ready for the renderer.
///
/// `2026-08-31-today-page`. The page is a *document mark renders*, for the same
/// reason `2026-08-26-markdown-reference-window` gives for the reference: a task
/// list written as markdown gets the five hand-drawn checkbox states, the
/// priority and `@tag` styling and the overdue colouring for nothing, and it
/// gets them from the same code path that draws them in the file the item came
/// from. A hand-built `NSTableView` would be a second renderer that agrees with
/// the first until it does not.
public enum TodayPage {

    /// The synthetic document's name, under the journal root.
    ///
    /// The page has no file, which is the one place this feature sits against
    /// `2026-08-26-new-documents-are-files-on-disk` — and it is why the window
    /// has no `DocumentTab` behind it and no editor: a document mark *holds* is
    /// still always a file. A `DocumentView` renders **for** a URL, though —
    /// it is what relative links resolve against and what every log line names —
    /// so the page is given one inside the journal. Extensionless, so it can
    /// never collide with a document somebody actually has.
    public static let name = "Today"

    public static func url(in root: JournalRoot) -> URL {
        root.url.appendingPathComponent(name)
    }

    // MARK: - The page

    public static func markdown(
        for digest: TodayDigest,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        var out = Writer()
        out.line("# \(readableDate(digest.date, locale: locale))")
        summary(of: digest, into: &out)
        today(digest, into: &out)
        projects(digest, into: &out)
        return out.text
    }

    /// The page shown when the window cannot find a journal at all.
    ///
    /// It names what was looked for and where, because the alternative — an
    /// empty page — is indistinguishable from "you have nothing to do".
    public static func notAJournal(startingFrom start: URL) -> String {
        var out = Writer()
        out.line("# Today")
        out.line("")
        out.line("No journal here.")
        out.line("")
        out.line(
            "The **Today** page reads the directory the sidebar is rooted at, and every "
                + "directory above it, looking for one that holds both a "
                + "`\(JournalRoot.dailyDirectory)/` and a `\(JournalRoot.projectsDirectory)/` "
                + "directory. Starting from:")
        out.line("")
        out.line("> `\(start.path)`")
        out.line("")
        out.line("nothing above it has both. Root the sidebar inside your journal and open this ")
        out.line("window again.")
        return out.text
    }

    // MARK: - Sections

    private static func summary(of digest: TodayDigest, into out: inout Writer) {
        var parts: [String] = []
        if digest.inProgress > 0 { parts.append("**\(digest.inProgress)** in progress") }
        if digest.notStarted > 0 { parts.append("**\(digest.notStarted)** not started") }
        if digest.blocked > 0 { parts.append("**\(digest.blocked)** blocked") }
        out.line("")
        out.line(parts.isEmpty ? "> Nothing outstanding today." : "> " + parts.joined(separator: " · "))
    }

    private static func today(_ digest: TodayDigest, into out: inout Writer) {
        out.line("")
        out.line("## Today")
        out.line("")

        guard let daily = digest.daily else {
            out.line(
                "_No daily note. `\(digest.expectedDailyPath)` does not exist — `nd` makes one._")
            return
        }

        let path = relativePath(of: daily.file, in: digest.root)
        if daily.isToday {
            out.line("_\(link(daily.file.lastPathComponent, to: path))_")
        } else {
            // Saying which day is being shown, and which day is missing, is the
            // whole content of this case: a page that quietly showed Friday on
            // Monday would be wrong in a way nobody would catch.
            out.line(
                "_No daily note for \(digest.today) — showing "
                    + "\(link(daily.date, to: path)) instead._")
        }

        let groups = daily.groups.filter { !$0.items.isEmpty }
        guard !groups.isEmpty else {
            out.line("")
            out.line("_Nothing outstanding._")
            return
        }

        // One group needs no caption: the heading above it already says
        // "Today", and `## Today` / **Today** reads like a mistake.
        let captioned = groups.count > 1
        for group in groups {
            if captioned, let heading = group.heading {
                out.line("")
                out.line("**\(link(heading, to: path, anchor: group.anchor))**")
            }
            out.line("")
            items(group.items, into: &out)
        }
    }

    private static func projects(_ digest: TodayDigest, into out: inout Writer) {
        out.line("")
        out.line("## Projects")

        guard !digest.projects.isEmpty else {
            out.line("")
            out.line("_Nothing under `\(JournalRoot.projectsDirectory)/`._")
            return
        }

        for project in digest.projects {
            let front = relativePath(of: project.front, in: digest.root)
            var heading = "### \(link(project.title, to: front))"
            if let status = project.status { heading += " · \(status)" }
            out.line("")
            out.line(heading)

            if project.hasNothingOpen {
                out.line("")
                out.line("_Nothing open._")
                continue
            }

            for group in project.own where !group.items.isEmpty {
                let path = relativePath(of: group.file, in: digest.root)
                // The front page's own items need no caption — the heading
                // above them already links there. Everything else in the
                // directory does, or the reader cannot tell which file an item
                // is in.
                if group.file != project.front {
                    out.line("")
                    out.line("_\(link(group.file.lastPathComponent, to: path))_")
                }
                out.line("")
                items(group.items, into: &out)
            }

            for group in project.tagged where !group.items.isEmpty {
                let path = relativePath(of: group.file, in: digest.root)
                out.line("")
                out.line(
                    "_\(link(group.file.lastPathComponent, to: path)) · `@proj(\(project.slug))`_")
                out.line("")
                items(group.items, into: &out)
            }
        }
    }

    /// The items themselves — each one its own source line, re-indented.
    private static func items(_ items: [TodayItem], into out: inout Writer) {
        for item in items {
            out.line(String(repeating: "  ", count: item.depth) + item.text)
        }
    }

    // MARK: - Links

    /// A markdown link whose destination is **always** angle-bracketed.
    ///
    /// `<…>` rather than percent-encoding, and that is load-bearing:
    /// `shell.js` reports `getAttribute("href")` verbatim and
    /// ``DocumentView`` resolves it as a *file path*, so a `%20` would be
    /// looked for literally and a project directory with a space in its name
    /// would silently fail to open. An angle-bracketed destination reaches the
    /// href as the path it is.
    ///
    /// A path containing `<` or `>` cannot be written this way and is emitted
    /// as plain text instead. Refusing to make a link is better than making one
    /// that goes somewhere else.
    static func link(_ text: String, to path: String, anchor: String? = nil) -> String {
        let destination = anchor.map { "\(path)#\($0)" } ?? path
        guard !destination.contains("<"), !destination.contains(">") else {
            return escaped(text)
        }
        return "[\(escaped(text))](<\(destination)>)"
    }

    /// `]` and `[` in link text would close the label early.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    /// `file`, written relative to the journal root.
    ///
    /// A file outside the root — which nothing here should produce — keeps its
    /// absolute path, so the link still works rather than pointing at a
    /// plausible-looking wrong place.
    static func relativePath(of file: URL, in root: JournalRoot) -> String {
        let base = root.url.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
    }

    // MARK: - Dates

    /// "Monday 31 August 2026", in the reader's locale.
    static func readableDate(_ date: Date, locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMMy")
        return formatter.string(from: date)
    }

    /// Lines, joined once at the end.
    ///
    /// A `String` appended to in a loop reallocates; this is the same thing
    /// with one join, and it keeps every call site reading as "emit a line".
    struct Writer {
        private var lines: [String] = []
        mutating func line(_ text: String) { lines.append(text) }
        var text: String { lines.joined(separator: "\n") + "\n" }
    }
}
