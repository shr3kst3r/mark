import Foundation

/// What a new document starts out as.
///
/// `2026-08-26-new-documents-are-files-on-disk` made ⇧⌘N name a file and create
/// it, so mark never holds a document with no file behind it. What it created
/// was an **empty** file, which is right as a default and wrong as the only
/// option: a journal's daily notes have a shape, and so does anything anyone
/// writes more than twice.
///
/// # The mechanism
///
/// A file called `_template.md` **beside** the new document. That is the whole
/// rule. No preference, no config directory, no registry — a template is a file
/// you can see in the sidebar, edit in mark, and put under version control with
/// everything around it. It is opt-in by existing, and a directory with no
/// template behaves exactly as it did before.
///
/// The search walks *up* from the target directory to the journal or sidebar
/// root, so `notes/daily/_template.md` covers every daily without a copy in
/// each month's folder — which matters, because the journal layout puts
/// dailies three directories deep.
///
/// # Substitutions
///
/// Deliberately four, and all of them things the file cannot know about itself:
///
/// | token | becomes |
/// |---|---|
/// | `{{title}}` | the new document's name, without its extension |
/// | `{{date}}` | `2026-09-01` |
/// | `{{time}}` | `14:05` |
/// | `{{filename}}` | the name with its extension |
///
/// A clock is read here, and that is allowed: this is not the renderer. ADR-5's
/// rule is that a *render* must be a pure function of its source, and creating
/// a file is not a render — but the date is passed in rather than reached for,
/// so the substitution itself stays testable without freezing one.
public enum DocumentTemplate {

    /// The name a template file has.
    public static let filename = "_template.md"

    /// Find the template that governs a document created at `url`.
    ///
    /// Walks up from the document's own directory to `stopAt` inclusive, and
    /// returns the first `_template.md` it finds — nearest wins, so a
    /// `projects/_template.md` can differ from the one at the root.
    ///
    /// - Parameter stopAt: the highest directory to look in. The journal root
    ///   or the sidebar root; never `/`, because walking to the filesystem root
    ///   would let a stray file in a home directory silently seed every new
    ///   document in the app.
    public static func find(
        for url: URL,
        stoppingAt stopAt: URL?,
        fileManager: FileManager = .default
    ) -> URL? {
        var directory = url.deletingLastPathComponent().standardizedFileURL
        let ceiling = stopAt?.standardizedFileURL

        // A bound rather than `while true`: a symlink loop, or a `stopAt` that
        // is not actually an ancestor, must not spin.
        for _ in 0..<JournalRoot.maximumAscent {
            let candidate = directory.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
            if let ceiling, directory.path == ceiling.path { return nil }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            if parent.path == directory.path { return nil }
            directory = parent
        }
        return nil
    }

    /// The body a new document at `url` should start with.
    ///
    /// `nil` when there is no template — which the caller turns into an empty
    /// file, exactly as before.
    public static func body(
        for url: URL,
        stoppingAt stopAt: URL?,
        date: Date = Date(),
        calendar: Calendar = .current,
        fileManager: FileManager = .default
    ) -> String? {
        guard let template = find(for: url, stoppingAt: stopAt, fileManager: fileManager),
            // Its own file, which a reader may well open and edit: seeding a
            // new template from itself would be a surprise.
            template.lastPathComponent != url.lastPathComponent
                || template.path != url.path,
            let source = try? String(contentsOf: template, encoding: .utf8)
        else { return nil }
        return substitute(source, for: url, date: date, calendar: calendar)
    }

    /// Fill a template's tokens in.
    public static func substitute(
        _ template: String,
        for url: URL,
        date: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let replacements: [String: String] = [
            "{{title}}": url.deletingPathExtension().lastPathComponent,
            "{{filename}}": url.lastPathComponent,
            // The same hand-formatted ISO date `TodayDigest` uses, and for the
            // same reason: a locale with a non-Gregorian calendar or non-ASCII
            // digits would put something unexpected in the file.
            "{{date}}": TodayDigest.isoDate(date, calendar: calendar),
            "{{time}}": String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0),
        ]
        var out = template
        for (token, value) in replacements {
            out = out.replacingOccurrences(of: token, with: value)
        }
        return out
    }
}
