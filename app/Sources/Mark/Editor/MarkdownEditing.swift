import Foundation

/// The markdown the editor knows about.
///
/// `2026-08-25-flock-write-locking` chose `NSTextView` precisely to inherit the
/// system's undo, spellcheck, Find & Replace and accessibility rather than
/// reimplementing them. The cost of that choice was that the editor knew
/// nothing about the *language* it was editing: ⏎ in the middle of a list
/// started a paragraph, and there was no ⌘B.
///
/// Everything here is a **pure function on a string**, and the `NSTextView`
/// glue is a thin layer over it in ``EditorPane``. That split is deliberate:
/// the interesting failures are all about which characters end up where —
/// an ordered list that stops renumbering, a bold that eats the space after the
/// word, an unwrap that removes the wrong pair of asterisks — and none of them
/// need a text view to demonstrate.
public enum MarkdownEditing {

    // MARK: - Continuing a list

    /// What a list item's line begins with, if it is one.
    public struct ListPrefix: Equatable, Sendable {
        /// Leading whitespace, preserved exactly — markdown's nesting rules
        /// count it, and a continuation that re-indents with a different number
        /// of spaces silently changes the structure.
        public var indent: String
        /// `-`, `*`, `+`, or `3.` / `3)` for an ordered item.
        public var marker: String
        /// `[ ]`, `[x]`, `[/]`, `[-]`, `[?]` for a task, else nil.
        public var task: String?
        /// The item's own text, after the marker and its space.
        public var content: String
        /// The number, for an ordered item.
        public var number: Int?

        /// What to type to start the next item in this list.
        ///
        /// An ordered list counts on; an unordered one repeats its marker. A
        /// task carries its brackets and is always **open** — continuing a done
        /// item into another done item would tick something nobody did.
        public var continuation: String {
            var out = indent
            if let number {
                // The delimiter the reader used — `1.` or `1)` — kept, since
                // both are legal and switching is a change they did not make.
                let delimiter = marker.hasSuffix(")") ? ")" : "."
                out += "\(number + 1)\(delimiter) "
            } else {
                out += "\(marker) "
            }
            if task != nil { out += "[ ] " }
            return out
        }

        /// The line with its content removed but its marker kept — what an
        /// empty item becomes when ⏎ ends the list.
        public var emptied: String { indent }
    }

    /// Read a line as a list item, or `nil` if it is not one.
    ///
    /// Recognises `-`, `*`, `+`, `1.`, `1)`, and any of those followed by one
    /// of the five task markers. A marker with no space after it is not a list
    /// item — GFM's rule, and the same one `tasks.rs` applies to `- [x]nospace`.
    public static func listPrefix(of line: String) -> ListPrefix? {
        var index = line.startIndex
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            index = line.index(after: index)
        }
        let indent = String(line[line.startIndex..<index])
        guard index < line.endIndex else { return nil }

        var marker = ""
        var number: Int?

        if "-*+".contains(line[index]) {
            marker = String(line[index])
            index = line.index(after: index)
        } else if line[index].isNumber {
            var digits = ""
            while index < line.endIndex, line[index].isNumber {
                digits.append(line[index])
                index = line.index(after: index)
            }
            guard index < line.endIndex, line[index] == "." || line[index] == ")" else {
                return nil
            }
            marker = digits + String(line[index])
            number = Int(digits)
            index = line.index(after: index)
        } else {
            return nil
        }

        // The space after the marker is required. Without it `-text` is a
        // paragraph beginning with a hyphen, not a list.
        guard index < line.endIndex, line[index] == " " else {
            // …unless the line is *only* the marker, which is an empty item
            // someone has just started.
            if index == line.endIndex {
                return ListPrefix(
                    indent: indent, marker: marker, task: nil, content: "", number: number)
            }
            return nil
        }
        index = line.index(after: index)

        // A task marker, if there is one.
        var task: String?
        let rest = line[index...]
        if rest.count >= 3, rest.first == "[" {
            let state = rest[rest.index(after: rest.startIndex)]
            let closeIndex = rest.index(rest.startIndex, offsetBy: 2)
            if rest[closeIndex] == "]", " xX/-?".contains(state) {
                task = String(rest[rest.startIndex...closeIndex])
                index = rest.index(after: closeIndex)
                // The space after `]` is required too, for the same reason.
                if index < line.endIndex, line[index] == " " {
                    index = line.index(after: index)
                } else if index != line.endIndex {
                    task = nil
                    index = rest.startIndex
                }
            }
        }

        return ListPrefix(
            indent: indent,
            marker: marker,
            task: task,
            content: String(line[index...]),
            number: number)
    }

    /// What ⏎ should insert, given the line the caret is on.
    ///
    /// * In a list item with content: a newline and the next item's marker.
    /// * In an **empty** list item: nothing to continue — the list is over, so
    ///   the marker is removed instead. That is the behaviour every editor has
    ///   and the reason ⏎⏎ ends a list rather than producing bullets forever.
    /// * Anywhere else: `nil`, meaning "let `NSTextView` do what it does".
    public enum NewlineAction: Equatable, Sendable {
        /// Insert this text at the caret.
        case insert(String)
        /// Replace the current line with this, then insert a newline.
        case clearLine(String)
    }

    public static func newlineAction(forLine line: String) -> NewlineAction? {
        guard let prefix = listPrefix(of: line) else { return nil }
        if prefix.content.trimmingCharacters(in: .whitespaces).isEmpty {
            return .clearLine(prefix.emptied)
        }
        return .insert("\n" + prefix.continuation)
    }

    // MARK: - Wrapping a selection

    /// Wrap `range` of `text` in `marker`, or unwrap it if it is already
    /// wrapped. Returns the new text and where the selection should end up.
    ///
    /// Two behaviours worth naming, because both are what makes this feel
    /// right rather than merely work:
    ///
    /// * **Trailing spaces are left outside.** Selecting `word ` (with the
    ///   space, which a double-click often gives you) and pressing ⌘B produces
    ///   `**word** `, not `**word **` — the second is not even bold in most
    ///   parsers, since GFM will not open emphasis before a space.
    /// * **An empty selection inserts the pair and sits between them**, so ⌘B
    ///   then typing works.
    public static func toggleWrap(
        _ text: String, range: Range<String.Index>, marker: String
    ) -> (text: String, selection: Range<String.Index>) {
        let selected = String(text[range])

        // Already wrapped, inside the selection: `**word**` -> `word`.
        if selected.count >= marker.count * 2, selected.hasPrefix(marker),
            selected.hasSuffix(marker)
        {
            let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
            var out = text
            out.replaceSubrange(range, with: inner)
            let start = out.index(range.lowerBound, offsetBy: 0)
            let end = out.index(start, offsetBy: inner.count)
            return (out, start..<end)
        }

        // Already wrapped, just outside the selection: `**|word|**` -> `word`.
        let before = text[text.startIndex..<range.lowerBound]
        let after = text[range.upperBound...]
        if before.hasSuffix(marker), after.hasPrefix(marker) {
            let outerStart = text.index(range.lowerBound, offsetBy: -marker.count)
            let outerEnd = text.index(range.upperBound, offsetBy: marker.count)
            var out = text
            out.replaceSubrange(outerStart..<outerEnd, with: selected)
            let end = out.index(outerStart, offsetBy: selected.count)
            return (out, outerStart..<end)
        }

        // Not wrapped. Keep trailing whitespace outside the markers.
        let trimmed = selected.drop(while: { $0 == " " })
        let leading = selected.count - trimmed.count
        let core = String(trimmed.reversed().drop(while: { $0 == " " }).reversed())
        let trailing = trimmed.count - core.count

        let replacement =
            String(repeating: " ", count: leading) + marker + core + marker
            + String(repeating: " ", count: trailing)
        var out = text
        out.replaceSubrange(range, with: replacement)

        let selectionStart = out.index(range.lowerBound, offsetBy: leading + marker.count)
        let selectionEnd = out.index(selectionStart, offsetBy: core.count)
        return (out, selectionStart..<selectionEnd)
    }

    /// Wrap `range` as a link: `[selected]()`, with the caret inside the
    /// parentheses so a URL can be typed or pasted straight in.
    ///
    /// A URL already on the pasteboard goes in the parentheses instead, which
    /// is the case this is most often reached for.
    public static func makeLink(
        _ text: String, range: Range<String.Index>, url: String = ""
    ) -> (text: String, selection: Range<String.Index>) {
        let selected = String(text[range])
        var out = text
        out.replaceSubrange(range, with: "[\(selected)](\(url))")

        if url.isEmpty {
            // Caret between the parentheses.
            let at = out.index(range.lowerBound, offsetBy: selected.count + 3)
            return (out, at..<at)
        }
        // A URL was supplied, so the useful selection is the link *text*,
        // which is usually what still needs writing.
        let start = out.index(range.lowerBound, offsetBy: 1)
        let end = out.index(start, offsetBy: selected.count)
        return (out, start..<end)
    }

    // MARK: - Headings

    /// Set a line's heading level. `0` removes it.
    ///
    /// Idempotent, and it does not stack: applying `##` to `# Title` gives
    /// `## Title`, never `## # Title`.
    public static func setHeading(_ line: String, level: Int) -> String {
        var index = line.startIndex
        var hashes = 0
        while index < line.endIndex, line[index] == "#", hashes < 6 {
            hashes += 1
            index = line.index(after: index)
        }
        // A run of `#` with no space after it is not a heading — it is prose
        // that starts with hashes, and rewriting it would change the document
        // in a way nobody asked for.
        var body = line
        if hashes > 0, index < line.endIndex, line[index] == " " {
            body = String(line[line.index(after: index)...])
        } else if hashes > 0, index == line.endIndex {
            body = ""
        }

        guard level > 0 else { return body }
        return String(repeating: "#", count: min(level, 6)) + " " + body
    }

    /// The level a line currently is, or 0.
    public static func headingLevel(of line: String) -> Int {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#", level < 6 {
            level += 1
            index = line.index(after: index)
        }
        guard level > 0 else { return 0 }
        // Same rule as above: `###text` is prose.
        guard index == line.endIndex || line[index] == " " else { return 0 }
        return level
    }
}
