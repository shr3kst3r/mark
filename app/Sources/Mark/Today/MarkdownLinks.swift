import Foundation

/// Re-basing the inline links inside a line of markdown that has been moved.
///
/// `2026-08-31-today-page`. The **Today** page copies an item's source line
/// verbatim, which is what keeps its links, `@tags`, priority and state byte
/// intact — and which quietly breaks exactly one thing. A project's front page
/// may say
///
/// ```markdown
/// - [/] Review [the speaker notes](./speaker-notes.md)
/// ```
///
/// where `./` means *that project's directory*. Copied onto a page whose base
/// is the journal root, `./` means the root, and the link points at a file that
/// does not exist. The item has to be rewritten as it is copied, or it has to
/// stop being a link; rewriting is the one of those that keeps the page useful.
///
/// This is deliberately **not** a markdown parser. It walks the line looking for
/// `](`, skipping code spans, and rewrites the one thing it understands. A
/// construct it does not recognise is left exactly as it was, which is the
/// failure mode to have: an unrewritten link is the bug this fixes, and a
/// mangled line would be a worse one.
enum MarkdownLinks {

    /// `line`, with every relative link destination in it re-based from
    /// `directory` to `root`.
    static func rebase(_ line: String, from directory: URL, to root: URL) -> String {
        guard line.contains("](") else { return line }

        let characters = Array(line)
        var out = ""
        var index = 0
        /// The length of the backtick run that opened the code span we are in,
        /// or `nil` outside one. A span opened by ``n`` backticks is closed by
        /// a run of exactly ``n``, which is the whole of the rule that matters
        /// here: `` `[a](b)` `` is not a link.
        var openFence: Int?

        while index < characters.count {
            let character = characters[index]

            if character == "`" {
                var run = 0
                while index + run < characters.count, characters[index + run] == "`" { run += 1 }
                out += String(repeating: "`", count: run)
                if openFence == nil {
                    openFence = run
                } else if openFence == run {
                    openFence = nil
                }
                index += run
                continue
            }

            if openFence == nil, character == "]", index + 1 < characters.count,
                characters[index + 1] == "(",
                let close = closingParenthesis(in: characters, after: index + 1)
            {
                let inner = String(characters[(index + 2)..<close])
                out += "](" + rewrite(inner, from: directory, to: root) + ")"
                index = close + 1
                continue
            }

            out.append(character)
            index += 1
        }
        return out
    }

    /// The `)` that closes the `(` at `open`, counting nesting — markdown
    /// allows balanced parentheses in a destination. `nil` when the line has
    /// none, which is a `](` that is not a link.
    private static func closingParenthesis(in characters: [Character], after open: Int) -> Int? {
        var depth = 0
        var index = open
        while index < characters.count {
            if characters[index] == "(" {
                depth += 1
            } else if characters[index] == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    /// The inside of a link's parentheses: a destination and an optional title.
    static func rewrite(_ inner: String, from directory: URL, to root: URL) -> String {
        let (destination, title) = split(inner)
        guard !isAbsolute(destination) else { return inner }

        let (path, fragment) = fragmentSplit(destination)
        guard !path.isEmpty else { return inner }

        let resolved = URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
        let rebased = relative(resolved, to: root)

        // Angle-bracketed on the way out for the same reason the page's own
        // links are: it is the one form that survives a space in a directory
        // name. A destination that already contains an angle bracket cannot be
        // written this way, and is left alone rather than mangled.
        guard !rebased.contains("<"), !rebased.contains(">") else { return inner }
        let anchored = fragment.map { "\(rebased)#\($0)" } ?? rebased
        return title.map { "<\(anchored)> \($0)" } ?? "<\(anchored)>"
    }

    /// A destination and whatever followed it — a title, usually.
    static func split(_ inner: String) -> (destination: String, title: String?) {
        let trimmed = inner.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("<"), let close = trimmed.firstIndex(of: ">") {
            let destination = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
            return (destination, rest.isEmpty ? nil : rest)
        }
        guard let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return (trimmed, nil)
        }
        let rest = trimmed[space...].trimmingCharacters(in: .whitespaces)
        return (String(trimmed[trimmed.startIndex..<space]), rest.isEmpty ? nil : rest)
    }

    /// Whether a destination already means the same thing from anywhere.
    ///
    /// A URL with a scheme, a site-absolute path, a filesystem-absolute path,
    /// and a bare `#anchor` — which stays inside the page it is on and is
    /// therefore the one relative destination that must **not** be re-based.
    static func isAbsolute(_ destination: String) -> Bool {
        if destination.isEmpty { return true }
        if destination.hasPrefix("#") || destination.hasPrefix("/") { return true }
        guard let colon = destination.firstIndex(of: ":") else { return false }
        let scheme = destination[destination.startIndex..<colon]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
    }

    /// A destination as its path and its anchor, split on the first `#`.
    static func fragmentSplit(_ destination: String) -> (path: String, fragment: String?) {
        guard let hash = destination.firstIndex(of: "#") else { return (destination, nil) }
        let fragment = String(destination[destination.index(after: hash)...])
        return (String(destination[destination.startIndex..<hash]), fragment.isEmpty ? nil : fragment)
    }

    /// `url` written relative to `root`, or absolute when it is outside it.
    ///
    /// An absolute path still resolves correctly from the page — it is what
    /// `URL(fileURLWithPath:relativeTo:)` ignores the base for — so a link out
    /// of the journal keeps working rather than being silently re-pointed at
    /// something inside it.
    static func relative(_ url: URL, to root: URL) -> String {
        let base = root.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
    }
}
