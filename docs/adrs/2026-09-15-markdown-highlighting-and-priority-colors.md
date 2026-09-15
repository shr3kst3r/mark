---
id: 2026-09-15-markdown-highlighting-and-priority-colors
status: Accepted
supersedes: null
superseded-by: null
components: [core, render, cli, app]
ticket: null
date: 2026-09-15
---
# Support double-equal markdown text highlighting and assign visual colors to task priorities

## Context

Two visual and syntactical gaps exist in mark's reading and editing experience:

1. **Priority markers have no visual colors.** `2026-08-27-inline-task-metadata` added `!`, `!!`, and `!!!` (levels 1, 2, 3) to list item tasks and emits `<span class="mk-tag" data-mk-priority="{level}">`. However, neither `core/src/render.rs` nor `app/Resources/shell.css` provides CSS rules for `data-mk-priority`. Priorities render as neutral gray chips indistinguishable in color from regular `@tags`. In the sidebar Tasks tab (`TaskListViewController.swift`), `row.priorityMark` is drawn in the row's trailing text with generic secondary label styling, providing no immediate visual differentiation between low, medium, and urgent tasks.

2. **No inline syntax exists for highlighting text.** Highlighting is a standard feature in modern note-taking tools (Obsidian, Bear, iA Writer) and documentation writers using `==highlighted text==`. `pulldown-cmark 0.13.4` does not support an `ENABLE_HIGHLIGHT` option, meaning `==text==` parses as literal text. While HTML `<mark>` is allowed by `core/src/sanitize.rs`, writing raw HTML tags in markdown is cumbersome and foreign to a plain-text workflow. Furthermore, mark's editor provides Format menu shortcuts for bold (⌘B), italic (⌘I), inline code (⌃⌘E), and strikethrough, but offers no highlight command.

Four facts constrain the solution:
- **`2026-08-24-progressive-document-rendering`**: Blocks are segmented at top-level depth 0, and block content hashes drive incremental patching. Any inline delimiter parsing must preserve top-level block boundaries and byte ranges.
- **`2026-08-24-rust-core-swift-appkit-shell`**: The C ABI surface is fixed at twelve functions. No new C ABI function may be added.
- **`2026-08-27-five-task-states`**: `core/src/render.rs` (`document_css()`) and `app/Resources/shell.css` must remain in strict lockstep.
- **`2026-08-24-rust-side-math-and-diagrams`**: Emitted documents must not contain JavaScript; all styling must be pure CSS derived from the active theme's base16 palette.

## Decision

**1. Style priority chips with theme tokens for gray, orange, and red.**
- Priority 1 (`!`): `var(--mk-subtle)` text with `color-mix(in srgb, var(--mk-subtle) 14%, transparent)` background.
- Priority 2 (`!!`): `var(--mk-s09)` text (base09 orange) with `color-mix(in srgb, var(--mk-s09) 14%, transparent)` background.
- Priority 3 (`!!!`): `var(--mk-error)` text (base08 red) with `color-mix(in srgb, var(--mk-error) 14%, transparent)` background.
- In `TaskListViewController.swift`, task rows color their trailing priority indicator (`!`, `!!`, `!!!`) using `NSColor.secondaryLabelColor` for level 1, `NSColor.systemOrange` for level 2, and `NSColor.systemRed` for level 3.

**2. Recognize `==text==` as highlighted text rendering as `<mark>text</mark>`.**
- Delimiter recognition runs during `Document::parse` per top-level block across `Event::Text` runs.
- Left-flanking delimiter: `==` not followed by whitespace and not backslash-escaped.
- Right-flanking delimiter: `==` not preceded by whitespace and not backslash-escaped.
- Paired `==...==` delimiters within a block are transformed into `Event::InlineHtml("<mark>")`, inner content events, and `Event::InlineHtml("</mark>")`, with exact source byte ranges assigned to each event slice.
- `Event::Code`, `Tag::CodeBlock`, `Event::InlineMath`, `Event::DisplayMath`, and raw HTML are immune and never scanned for delimiters.
- Isolated equality expressions such as `a == b` remain untouched as literal text.
- `<mark>` elements are styled with `background-color: var(--mk-s0A); color: var(--mk-s00); border-radius: 2px; padding: 0.05em 0.2em;` across both `core/src/render.rs` and `app/Resources/shell.css`.
- In `cli/src/ansi.rs`, `<mark>` switches to reverse video / standout (`self.style("7")`) and `</mark>` resets.
- `plain_text` ignores `InlineHtml`, so headings like `## ==Important== Notice` slugify cleanly to `important-notice`.
- `wordcount` ignores `InlineHtml`, counting the text inside `<mark>` without counting delimiters.

**3. Provide Format ▸ Highlight (⇧⌘H) in the editor.**
- The **Format** menu gains a **Highlight** item with shortcut ⇧⌘H.
- `MainWindowController.toggleHighlight(_:)` wraps or unwraps the selection with `"=="` via `MarkdownEditing.toggleWrap`.
- An empty selection inserts `====` with the insertion point between them.

## Consequences

**What becomes easier.**
- Users can highlight words and phrases in markdown with standard `==text==` syntax and keyboard shortcut ⇧⌘H.
- Priorities 1, 2, and 3 are immediately distinguishable at a glance in both preview and sidebar.
- Existing documents with `<mark>` HTML continue to render with theme-matching highlight styling.
- Headings, tasks, and plain-text operations remain clean and anchor-stable.

**What becomes harder, and what we are accepting.**
- **`==` is an extension beyond CommonMark / GFM.** While widely used in Obsidian and Bear, GitHub renders `==text==` as literal text. `mark normalize` does not currently strip `==` (raw `<mark>` would be needed for GitHub).
- **Non-highlight double equals in prose must follow spacing rules.** While `a == b` is protected by whitespace rules, an unusual unspaced sequence like `foo==bar` could be misparsed if paired elsewhere on the line.
- **Two stylesheets must be updated in lockstep.** `core/src/render.rs` and `app/Resources/shell.css` must maintain identical declarations for `.mk-tag[data-mk-priority="..."]` and `mark`.

## Alternatives considered

- **Require raw `<mark>` HTML instead of `==` syntax.** Rejected: raw HTML is tedious to type, disrupts reading in plain text, and fails mark's principle of comfortable keyboard-driven editing.
- **Custom inline span syntax like `::highlight::` or `!text!`.** Rejected: `==` is the established convention in the markdown ecosystem (Obsidian, Bear, Typora), and `!` already means priority.
- **Color priority chips only in the preview and leave sidebar plain.** Rejected: the sidebar's Tasks tab is an essential navigation pane, and having priorities colored in one view but monochrome in the other is inconsistent.
- **Use JavaScript to color priorities or highlights.** Rejected: prohibited by `2026-08-24-rust-side-math-and-diagrams`. All document styling must be pure CSS.
