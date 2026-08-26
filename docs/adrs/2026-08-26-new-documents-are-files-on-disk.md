---
id: 2026-08-26-new-documents-are-files-on-disk
status: Accepted
supersedes: null
superseded-by: null
components: [app, editor, tabs, sidebar]
ticket: null
date: 2026-08-26
---
# Name a new document before it exists, so mark never holds a document that has no file

## Context

The request is *"I want to be able to open and create new markdown files."*
Opening exists. Creating does not, and the File menu says why in two places:

> ⌘N is the platform's "another one of these", and until that ADR there was
> nothing for it to mean — **a viewer has no blank document to make.**

> A viewer has no blank document to open, so "New Tab" is the open panel — the
> tab is what you get, and the file is what you choose.

Both are code comments from when mark was a viewer, not decisions in this
corpus — there is nothing here to supersede. The premise behind them has since
gone: `2026-08-25-flock-write-locking` shipped an `NSTextView` editor, a
buffer, debounced autosave and a conflict prompt. mark writes documents now. It
just cannot make one.

### The app is keyed on a path that exists

Every subsystem that knows about a document identifies it by its URL:

| Subsystem | Keyed on | Evidence |
|---|---|---|
| Tab identity | `url.standardizedFileURL` | `MainWindowController.swift:365` |
| "Open in at most one place" | dedupe by URL | `MainWindowController.swift:311` |
| Session restore | `SessionTab.path`, a `String` | `Session.swift:4` |
| Write locking | `flock(2)` on a descriptor | `Editor/DocumentLock.swift` |
| Autosave | temp file renamed over the target | `core/src/tasks.rs:339` |
| File watcher | a watched path | `Watch/FileWatcher.swift` |
| Tab badge and title | reads the file | `Tabs/DocumentTab.swift:97` |
| `mark tab list` / `tab select <path>` | a path in the reply | `MainWindowController.swift:1435` |

A URL-less "untitled buffer" is a new state each of those must tolerate, and
two of them cannot express it at all. `2026-08-25-flock-write-locking` says,
without qualification:

> **Every path that writes a user's document takes the lock first.** No
> exceptions, including future features.

There is nothing to `flock` until there is a file — `DocumentLock.acquire`
opens `O_RDONLY` with no `O_CREAT` (`DocumentLock.swift:85`), so on a missing
path it throws before it reaches the lock. And "a document is open in at most
one place" is a rule about URLs; two untitled tabs both have none.

### Creating a file needs no new write machinery

Verified rather than assumed: the core's `write_atomically` already handles a
target that does not exist. `DocumentLock::acquire` returns
`LockState::DocumentAbsent` instead of an error for a missing path
(`core/src/lock.rs:180-188`), and the write proceeds to create it. So
`MarkCore.save("", to: path)` — `mark_write_json` with a path and
`MARK_NO_TASK` — creates an empty document atomically, under the lock, through
the one write path the flock ADR requires. Nothing new is needed, and the
Replace case is covered for free: a save panel aimed at a file another `mark`
holds dirty is refused by the same mechanism that refuses `mark check`.

### There is no rename

Not in the sidebar (the tree has no context menu), not in the tab bar, not in
the CLI. Any scheme that creates a file under a placeholder name and leaves the
reader to fix it has no in-app way to finish the job. This is the single fact
that decides the shape below.

### What markdown is, and who gets to say

`core/src/tree.rs:47` and `TreeDataSource.markdownExtensions` both list
`md, markdown, mdown, mkd, mdx`, pinned together by `MarkCoreTests`. The open
panels ignore that list and filter by UTType. Measured on macOS 26: `.mdown`,
`.mkd` and `.mdx` resolve to synthesised `dyn.…` types that do not conform to
`public.plain-text`, so they are **greyed out and unselectable** in both panels
while the sidebar opens them happily. Whatever this ADR decides about creating
a file has to answer the same question — which extension a new document gets —
so it is answered once, here, for both.

## Decision

**mark never holds a document that has no file.** There is no untitled state,
no URL-less tab, and no `SessionTab` without a path. A new document is named
first, created on disk, and then opened as an ordinary tab.

Specifically:

- **File ▸ New Document… runs an `NSSavePanel`.** On OK the app writes an empty
  document through `MarkCore.save("", to:)` — the core's one write path, so the
  creation takes the `flock` like every other write — and opens the result as a
  permanent tab in the **focused group**, exactly as every other route in does
  (`2026-08-26-editor-groups-per-pane-tab-bars`).

- **The new file is empty.** No template, no seeded heading, no front matter.

- **The editor pane is shown and takes the keyboard**, because a document that
  was just made has nothing to read. This is the one route that opens the pane
  for you; `2026-08-25-flock-write-locking` carries forward *"a document opens
  read-only until you ask to edit it"*, and making a file **is** asking.

- **The panel opens where the reader is**: the selected tab's directory, else
  the sidebar root — the rule ⌘T already uses — with `Untitled.md` in the name
  field.

- **What counts as markdown is `TreeDataSource.markdownExtensions`, never
  UTType and never LaunchServices.** A typed name whose extension is not in
  that list gets `.md` appended. The same list filters both open panels,
  through an `NSOpenSavePanelDelegate`, rather than `allowedContentTypes`.

- **⌘N stays New Window.** New Document… takes ⇧⌘N. The shipped, documented
  shortcut does not move for a new feature.

- **The socket gains nothing.** No `mark new`, no `--create` on `mark open`.
  `touch x.md && mark open x.md` already does this from a terminal, and
  `mark open` keeps refusing a path that does not exist.

- **A refusal is said out loud.** A target held dirty by another `mark`, or a
  write that fails, raises an alert naming the reason. Creating a file is a
  deliberate act and a silent no-op reads as a broken menu item.

## Consequences

**Easier.** A created document is indistinguishable from an opened one, from
the first frame: the session records it, the watcher watches it, the lock locks
it, `mark tab list` finds it, the badge counts its tasks, ⌘S and autosave and
the conflict prompt all apply, and none of that needed a line of new code or a
new case in a state machine. Nothing can be lost by quitting — there is no
unnamed buffer to lose. The Replace case is handled by machinery that already
exists.

**Harder, and we are accepting it.**

- **A modal stands between the reader and typing.** Every other editor on this
  machine gives you a buffer first and asks later. This is the cost of the
  file-backed model and it is paid every single time, not once.
- **There is no scratch space.** "Jot this down and decide where it goes later"
  is not a thing mark can do. For a markdown reader that is a plausible thing
  to want, and the answer is a terminal and `touch`.
- **The name is chosen at the worst possible moment** — before the content
  exists — and with no rename in the app, changing it later means Finder.
- **`notes.txt` typed into the panel becomes `notes.txt.md`**, which is
  surprising. Accepted over the alternative, which is creating a file mark
  itself then refuses to reopen and draws dimmed in its own sidebar.
- **We hand-roll a panel delegate where `allowedContentTypes` is the obvious
  idiom.** A future engineer will reach for the idiom, and the three orphan
  extensions will silently stop being selectable — *only in installed builds*,
  because a bundle's type declarations are inert until LaunchServices registers
  it. That is a bug that cannot reproduce under `swift test`, which is why the
  rule is stated here and pinned by a test rather than left to review.

Constraints this imposes on future work:

- **Never introduce a document with no file.** An untitled buffer supersedes
  this ADR, and it has to re-answer `2026-08-25-flock-write-locking`'s "every
  write path takes the lock first" — which cannot be satisfied by a path that
  does not exist.
- **Every file mark creates goes through the core's one write path.** No
  `FileManager.createFile` on a user's document, for the same reason there is
  no direct `fs::write`.
- **Markdown is the extension list, in one place.** Mirrored between
  `core/src/tree.rs` and `TreeDataSource`, pinned by `MarkCoreTests`, consulted
  by every panel. LaunchServices' opinion is advisory and build-dependent.
- **A rename facility is what would let this be revisited.** If one lands,
  creating `Untitled.md` immediately with no modal becomes available and this
  ADR is the one to supersede.
- **New Document lands in the focused group**, like every other route in.

## Alternatives considered

- **An untitled in-memory buffer, saved on ⌘S** (VS Code, TextEdit). What most
  people expect, and the only option with no modal in the way. Rejected: it is
  a new state for the eight subsystems above, and two of them cannot express it
  — you cannot `flock` a file that does not exist, and "open in at most one
  place" is a rule about URLs. It is reachable later by superseding this and
  the flock ADR together; it is not reachable cheaply.
- **Create `Untitled.md` in the sidebar root immediately, no panel.** Fast, and
  what a notes app does. Genuinely tempting, and the modal above is a real cost
  it does not pay. Rejected because there is no rename anywhere in mark, so
  every use leaves a file the reader cannot fix from inside the app — and the
  second one has to be `Untitled 2.md`. Revisit when rename exists.
- **A save panel that seeds `# <filename>`.** Rejected: content you have to
  delete is worse than no content, and it makes an assumption about the reader's
  heading style on their behalf.
- **`mark new <path>` on the socket.** Rejected as unnecessary rather than
  wrong: `touch x.md && mark open x.md` already does it with tools an agent
  has, and `2026-08-24-cli-app-unix-socket-ipc`'s surface is better left alone
  than grown for a verb the shell already spells.
- **Do nothing — `touch`, then ⌘O.** Rejected: it is the request, and an editor
  with autosave, write locking and a conflict prompt that cannot make a
  document is a strange thing to have built.
