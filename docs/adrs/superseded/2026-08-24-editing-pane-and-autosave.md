---
id: 2026-08-24-editing-pane-and-autosave
status: Superseded
supersedes: null
superseded-by: 2026-08-25-flock-write-locking
components: [app, editor, core]
ticket: null
date: 2026-08-24
---
# Edit markdown in a native NSTextView pane, with the buffer as truth while dirty and debounced autosave

## Context

`mark` was scoped as a viewer whose only write was a checkbox toggle. The user
has since asked for editing: a pane to the right of the preview, the preview
updating live as you type, and autosave.

**No accepted ADR forecloses this.** The word "viewer" appears in the corpus only
in Context prose describing the product, never in a Decision or a Consequences
constraint. The "only write is a checkbox toggle" line lives in `.adr-rpi/plan.md`
§1, which is plan material and freely changed. So this ADR is additive rather
than a supersession, and nothing already settled needs re-opening.

It does, however, collide with four accepted decisions in ways that must be
recorded now, because each is a silent-corruption risk rather than a compile
error:

1. **The file watcher will observe our own writes.**
   `2026-08-24-progressive-document-rendering` fixes FSEvents watching the parent
   directory with a 25–50 ms debounce. Autosave writes the file; the watcher
   fires; the document re-renders underneath the cursor. Left alone this is a
   feedback loop that fights the typist.
2. **ADR-2's block diff was designed for external changes at human-save cadence,
   not typing cadence.** It re-parses (2 ms/MB) and diffs block hashes. At an
   800 ms debounce that is fine; at every keystroke it would not be.
3. **The checkbox contract assumes the file is the single source of truth.**
   `2026-08-24-rust-core-swift-appkit-shell` defines toggling as a byte-range
   in-place edit of the file, and identity as `(file, task-index)`. With an
   unsaved buffer open there are two candidate sources, and clicking a checkbox
   in the preview must not write a file whose bytes no longer match what the
   preview was rendered from.
4. **Dehydration would discard an unsaved buffer.**
   `2026-08-24-single-window-custom-tab-bar` evicts the web view of tabs beyond a
   20-tab MRU working set. A dirty tab evicted is lost work.

Two existing pieces make this cheaper than it looks. `core::tasks::write_atomically`
already does temp-file-plus-rename and — after the M1 review pass — resolves
symlinks before renaming, so the write primitive is sound. And ADR-2's block-level
patching already exists to update a rendered document from changed source without
losing scroll position, which is exactly what a live preview needs.

On the editor component: `NSTextView` with TextKit 2 supplies undo/redo, Find &
Replace, spellcheck, text substitutions, system keybindings, and accessibility at
zero cost, and ships no JavaScript. The alternative — CodeMirror 6 in a second
`WKWebView` — has better markdown-source affordances out of the box but costs
~400 KB of JS, a second web view per tab against a measured ~1.2 MB marginal tab
budget, and requires re-bridging undo and find to ⌘Z/⌘F. It would also cut
against the no-JS line drawn in `2026-08-24-rust-side-math-and-diagrams`.

## Decision

We add an editing pane. The window becomes three panes: **sidebar, preview,
editor** — the editor to the right of the preview, per the requested layout. The
pane is collapsible and hidden by default; a document opens read-only until the
user asks to edit it.

The editor is an **`NSTextView` backed by TextKit 2**. We do not reimplement
undo, find, spellcheck, or text substitution; we inherit them. Markdown *source*
highlighting in the editor is driven by the core's existing block byte ranges,
not by a second parser.

**While a tab is dirty, the buffer is the source of truth**, and the preview
renders from the buffer rather than from the file. When a tab is clean, the file
is truth, exactly as before.

**Autosave writes 800 ms after typing stops**, through
`core::tasks::write_atomically`. Each write records the content hash we wrote;
the file watcher ignores any event whose content hash matches a hash we
originated, so our own saves never trigger a re-render.

**A dirty tab is never dehydrated.** It is excluded from MRU eviction until it is
clean.

**Checkbox clicks while dirty apply to the buffer, not the file.** The core's
byte-range toggle runs against the buffer's bytes and the result re-enters the
buffer, which autosave then persists. A checkbox click on a clean tab keeps
writing the file directly, unchanged.

**On external conflict we prompt and never guess.** If the watcher reports
content matching neither our buffer nor our last-written hash while the tab is
dirty, autosave pauses and the user chooses: keep mine, take theirs, or show a
diff. Autosave stays paused until the conflict is resolved.

## Consequences

**Easier.** Real editing with undo, Find & Replace, spellcheck, and full
accessibility for almost no code, and no JavaScript added. The live preview falls
out of ADR-2's existing block diff rather than needing new machinery — a
one-paragraph edit re-renders one block. The write primitive is already
symlink-safe and atomic.

**Harder, and we are accepting it.**

- **There are now two possible sources of truth**, and which one is authoritative
  depends on tab state. This is the central new complexity, and every feature
  touching document bytes must ask "is this tab dirty?" first. Getting it wrong
  means rendering one thing and writing another.
- **`mark` is no longer a viewer**, and its risk profile changes accordingly. A
  bug can now corrupt a file at typing speed rather than one byte at a time. The
  M1 review already found that `fs::rename` silently destroyed symlinked notes;
  that class of bug is far more expensive once we write continuously.
- **ADR-4's memory bound is weakened.** Exempting dirty tabs from eviction does
  not contradict its "the working set is a tunable" constraint, but a user with
  30 dirty tabs pays full residency for all of them. We accept this rather than
  ever evicting unsaved work.
- **A conflict state machine and a modal prompt**, neither of which a viewer
  needed, plus a diff view to make "show me" meaningful.
- **Autosave produces more git churn** than manual saving, and more watcher
  traffic that self-write suppression must filter correctly. A suppression bug
  shows up as a cursor that jumps while typing — annoying, hard to reproduce.

Constraints this imposes on future work:

- **While a tab is dirty, the buffer is authoritative.** Nothing may read the
  file for rendering, task counts, or search on a dirty tab.
- **A dirty tab is never dehydrated**, regardless of MRU position.
- **Every write goes through `write_atomically`.** No direct `fs::write` to a
  user's document, ever.
- **Every write records its content hash, and the watcher suppresses matches.**
  A write path that skips this reintroduces the feedback loop.
- **Autosave is paused while a conflict is unresolved.** Never resolve a conflict
  by writing.
- **The CLI may still write a file the GUI holds dirty.** `mark check` from a
  terminal writes the file; the GUI detects the change and raises the normal
  conflict prompt. We deliberately do not add cross-process locking — the prompt
  is the answer, and the alternative is a lock file to leak.
- **The editor pane must not assume a `WKWebView` exists**, since ADR-4 allows
  the preview side to be dehydrated independently.

**Deliberately not decided here:** rich/WYSIWYG editing, a vim keymap, and
multi-cursor. All are plausible later and none is foreclosed; adding them would
be plan work unless they require replacing `NSTextView`, which would be a
supersession.

## Alternatives considered

- **CodeMirror 6 in a second `WKWebView`.** Best-in-class markdown source
  editing, bracket matching, multi-cursor, and vim keymaps in the box. Rejected:
  ~400 KB of JavaScript, a second web view per tab against a ~1.2 MB marginal tab
  budget, undo and find needing manual re-bridging to the macOS menu bar, and a
  direct conflict with the zero-JS position taken in
  `2026-08-24-rust-side-math-and-diagrams`. Genuinely the stronger editor; the
  wrong trade for this app.
- **`contenteditable` on the rendered preview (WYSIWYG).** No second pane, edit
  what you see. Rejected: round-tripping HTML back to markdown loses fidelity in
  exactly the constructs this project cares about — task lists, tables, fenced
  code — and it would put the checkbox byte-range contract in permanent conflict
  with a DOM-derived one. That is a different product.
- **Last-write-wins on external conflict.** Trivial, no dialog, no state machine.
  Rejected: it silently destroys another tool's save, which is the same failure
  class as the symlink bug the M1 review caught, and this project has already
  decided once that refusing to write beats writing the wrong bytes.
- **Reload-theirs on external conflict.** Treats disk as truth, no dialog.
  Rejected: destroys the user's in-flight typing without asking.
- **Fixed-interval autosave (every 5 s if dirty).** Simplest timer. Rejected:
  writes mid-word, produces more git churn, and generates watcher noise
  proportional to session length rather than to editing.
- **Explicit save only (⌘S, no autosave).** Fewest write paths and no
  suppression machinery. Rejected: autosave was explicitly requested, and it is
  what keeps the file fresh for the external tools this app is meant to sit
  alongside.
- **Cross-process locking so the CLI cannot write a dirty file.** Rejected: a
  lock file that leaks on crash is worse than the conflict prompt we already need
  for external editors, and it would make the CLI's behaviour depend on whether
  the GUI happens to be running.
