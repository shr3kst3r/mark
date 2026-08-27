---
id: 2026-08-26-opened-file-history
status: Accepted
supersedes: null
superseded-by: null
components: [app, tabs, sidebar, ipc]
ticket: null
date: 2026-08-26
---
# Remember which files were deliberately opened, application-wide, and show them in a window that holds no web view

## Context

The request is *"I want to be able to view a history of opened files."*

mark already has two histories, both of the wrong noun. `Navigator`
(`Sidebar/Navigator.swift`) remembers sidebar **roots** — directories — with a
back stack, a forward stack, and a cap; `TabStore` keeps an MRU order over the
tabs that are **currently open**, which drives eviction and is erased the moment
a tab closes. Neither can answer "what did I have open last Tuesday". Nothing in
the app, the CLI or the core records a file having been opened: there is no
`NSDocumentController`, no `noteNewRecentDocumentURL`, no File ▸ Open Recent.

Three facts about the existing code decide most of what follows.

### There is exactly one place a file becomes open

`MainWindowController.openInFocusedGroup(_:preview:)`
(`MainWindowController.swift:333`) is the funnel for every route in — the
sidebar's single and double click, ⌘O and ⌘T's panel, a drop on the window,
`mark open`, a `mark://` URL, LaunchServices at launch, and File ▸ New Document.
`2026-08-26-editor-groups-per-pane-tab-bars` put it there deliberately, so that
"a document is open in at most one place" could be enforced once.

That funnel already carries the distinction this feature needs. The sidebar's
single click passes `preview: true`, and `TabStore.open` explains what that is
for: a preview open reuses one slot, *"so clicking down forty files leaves one
tab rather than forty"* (`TabStore.swift:205-216`). Browsing past a file is
already modelled as not the same act as opening it.

### Session restore does not go through that funnel — today, by accident

Restore builds tabs directly in `TabStore.restore(_:)` (`TabStore.swift:600-660`)
and never calls `open(_:)`. So a history hooked at the funnel is not rewritten
every launch by the tabs that were already open.

This is currently a property of where two methods happen to sit, and it is
load-bearing: a refactor that routed restore through `open(_:)` — an entirely
reasonable-looking simplification — would stamp every restored tab with the
launch time and turn the history into a list of every launch. It needs to be a
stated rule rather than a happy accident.

### The privacy cost is already on the record, for a weaker version of this

`Navigator` caps its stacks and says why:

> The stacks are capped at `historyLimit` because they are persisted to the
> session file, and an unbounded list of every directory visited in a long
> session is both a large file **and a small privacy leak in a tool that reads
> private notes**.

That is about *directories*. A list of every file opened is the same leak,
sharper, and this feature additionally puts it on screen in a window — where a
screenshot shows the shape of someone's notes tree.

### What a viewing surface costs, and what it does not

`2026-08-26-markdown-reference-window` establishes the second-window shape:
single-instance, owned by `AppDelegate`, `HelpWindowController` as the template.
Its central cost is that the window holds a `WKWebView` — ~52 MB — so it must
register with `ResidencyGovernor` or the application-wide budget under-reports by
exactly one web view, which is the defect the superseded residency ADR exists to
record.

**That cost does not transfer.** A list of paths is an `NSTableView`. It holds no
web view, spawns no WebContent process, and there is nothing for the governor to
count. Saying so explicitly is the point: the next person to add a window will
find one precedent that registers with the governor and one that does not, and
the difference has to be legible as a rule rather than as an oversight.

## Decision

**mark keeps one application-wide list of files that were deliberately opened,
most recent first, and shows it in a window of its own.**

Specifically:

- **A file enters the history when it is opened permanently, and only then.**
  The hook is `openInFocusedGroup(_:preview:)`, the one funnel. A **preview
  open** — the sidebar's single click — records nothing; arrow-keying down a
  folder of forty notes leaves the history untouched, for the same reason it
  leaves one tab. Promoting a preview tab to permanent (a double click, or
  `mark open` on the file being skimmed) **does** record: that is the moment the
  reader named the file.

- **Session restore never records, and this is a rule, not a side effect of
  where the hook sits.** Restoring tabs is the app remembering, not the user
  opening. Any future change that routes restore through `open(_:)` must skip
  recording explicitly.

- **The list is the application's, not a window's.** One list shared by every
  window, matching `ResidencyGovernor`'s application-wide scope rather than
  `Navigator`'s per-window one. A file opened in another window is still a file
  that was opened.

- **An entry is a path and a timestamp.** Absolute path, standardized the way
  tab identity already is (`url.standardizedFileURL`), plus when it was last
  opened. **Never a security-scoped bookmark**, carrying forward `SessionTab`'s
  recorded position: *"a moved file should reopen as 'missing' rather than
  silently follow a rename the user did not ask us to track."*

- **One entry per path.** Re-opening a file moves its entry to the front and
  updates its timestamp rather than adding a second. A history of *files*, not
  of open events.

- **The list is capped**, at `Navigator.historyLimit`'s 64 — the same number for
  the same two reasons, and one number for a reader to learn instead of two. The
  cap's *existence* is what this ADR fixes; the integer is a detail a future
  change may move without superseding anything.

- **It is persisted in `session.json`**, as an additive optional top-level field
  beside `theme` — which is already application-wide rather than per-window.
  `SessionState.currentVersion` **does not move**, for the reason that file has
  given since M8: every added field is optional and additive, and a version bump
  refuses yesterday's session and loses the user's tabs to buy nothing.

- **It is viewed in a single-instance window** — `HistoryWindowController`,
  owned by `AppDelegate`, modelled on `HelpWindowController` — from **File ▸
  History** (⌘Y, the browsers' shortcut, unclaimed here). An `NSTableView`
  showing each file's name, its containing directory and when it was last
  opened, with a filter field over the list.

- **That window holds no `WKWebView` and does not register with
  `ResidencyGovernor`.** It renders no markdown and displaces no tab.

- **Opening from the window uses the existing route and no new one.** A row
  opens into the key window's **focused group**, exactly as every other route in
  does (`2026-08-26-editor-groups-per-pane-tab-bars`), through
  `MainWindowController.open(_:)`. With no window open, one is made first.

- **A missing file stays in the list, dimmed and labelled.** Entries are never
  auto-pruned on a failed `stat`: an unmounted volume is not a deleted file, and
  a path that comes back should come back. Opening one says so out loud rather
  than doing nothing, matching `2026-08-26-new-documents-are-files-on-disk` on
  refusals being audible.

- **Clear History empties it, from a button in that window, behind a
  confirmation.** It is the only way to forget, and it is irreversible.

- **The socket surface gains nothing.** No `mark history`, no new C ABI
  function. `2026-08-26-new-documents-are-files-on-disk` declined a verb for a
  whole feature on the grounds that `2026-08-24-cli-app-unix-socket-ipc`'s
  surface is *"better left alone than grown"*, and nothing here is weaker than
  that case.

## Consequences

**What becomes easier.** The question "what was I reading" gets an answer that
survives closing a tab, closing a window, and quitting — which is the one thing
neither existing history can do. Reopening a file from three projects ago stops
requiring that you remember which directory it was in. Because the hook is the
funnel every route already passes through, `mark open`, a drop, a `mark://` URL
and the open panel all record without a line of code each, and a future route in
records by construction rather than by remembering to.

**What becomes harder, and what is being accepted.**

- **A durable, viewable record of private note paths now exists.** Before this,
  the closest thing was a capped list of directories in a JSON file nobody
  looks at. This is a window you can put on screen — and screenshot — showing
  the shape of someone's notes tree. The cap bounds it and Clear History empties
  it; neither makes it not exist. There is deliberately **no off switch**: it
  would be a preference, mark has no preferences window, and inventing one for a
  boolean is a larger decision than this feature.
- **Clearing the history rewrites the session file.** History lives in
  `session.json`, so Clear History goes through the same debounced write as the
  tabs, and a `session.json` that fails to decode now loses the history along
  with the tabs. Both are already true of `theme` and of the sidebar's stacks;
  this adds one more thing to the file whose loss is a real loss.
- **`AppDelegate` gains a third kind of window to own**, after the main window
  and the reference. It is the second single-instance one, and the second static
  `shared` that must be strong for `HelpWindowController`'s documented
  reason — `NSWindow` does not retain its controller — and torn down on close.
- **The permanent/preview rule will surprise someone.** A reader who skimmed a
  file in the sidebar, closed mark, and comes back looking for it will not find
  it in the history, because mark decided that was browsing. That is a real
  miss, and it is the price of the history not being 90% skim noise.
- **Timestamps make staleness visible.** "3 months ago" next to a file is
  information the app has never shown before, and it is only as accurate as a
  clock and a debounced write; a crash loses the entries since the last save,
  exactly as it loses tab state.
- **The window is a fourth list of files in an app whose sidebar already has
  two.** Tree, table of contents, tab bar, history — four ways to see file names,
  and a reader has to learn which one answers which question.

Constraints this imposes on future work:

- **Restore never records.** Anything that makes session restore reuse the open
  path must suppress recording explicitly, or the history becomes a list of
  launches.
- **The history is application-wide.** A per-window history is the `Navigator`
  shape and is not this; splitting it later means deciding what happens to
  entries when a window closes, which this ADR deliberately does not have to
  answer.
- **A surface that shows documents without rendering them owes the residency
  governor nothing.** A surface that holds a `WKWebView` owes it registration,
  per `2026-08-26-markdown-reference-window`. The test is the web view, not the
  window.
- **History entries are paths.** Not bookmarks, not aliases, not inodes — the
  same position `SessionTab` takes, for the same reason.
- **Opening from any new surface goes through the focused group**, via the
  existing route.

## Alternatives considered

- **`NSDocumentController.noteNewRecentDocumentURL`.** The platform idiom, and it
  would give the Dock menu and a system-managed Open Recent for free. Rejected
  on three counts: mark is not an `NSDocument` app; the corpus already chose our
  own file over AppKit-managed state once, hard enough to set
  `isRestorable = false` so AppKit would not race it; and the list's length is a
  System Settings slider we do not control, in a list we cannot filter, cannot
  timestamp and cannot mark as missing. The reader asked to *view* a history,
  which is the half this option is worst at.
- **A File ▸ Open Recent submenu as the surface.** Cheapest by a wide margin —
  ~30 lines in a file that already hand-builds every menu. Rejected as the
  primary surface for what a menu cannot do: no filter, no sort, no timestamp, no
  way to show that an entry has gone missing. Not foreclosed; it is a second view
  onto the same store if it turns out to be wanted.
- **A third pane in the sidebar.** Mechanically easy — `SidebarPaneController` is
  a plain `NSSplitView`. Rejected on crowding and on scope: the sidebar is
  already two panes in a window that may also carry an editor pane and, when
  split, two tab bars, a regression `2026-08-26-editor-groups-per-pane-tab-bars`
  accepted at 640 pt and would be paying for a second time; and a per-window pane
  is the wrong shape for an application-wide list.
- **A filter-as-you-type palette.** The fastest way to *reopen* a file you can
  name, and the worst way to *browse* what you have been reading. Rejected as the
  first surface, and cheap to add later against the same store — which is part of
  why the store is a separate type from the window.
- **A separate `history.json` beside the session file.** A log and a snapshot do
  have different lifetimes, and clearing one would not touch the other. Rejected
  because `MARK_SESSION_FILE` is how `mark-bench` and the integration checks stay
  out of a developer's real state: history inside `session.json` is hermetic in
  those runs for free, while a second file would silently write a developer's
  real history on every bench until a second override was added everywhere.
- **Record skims too.** Truest to "files I looked at", and it catches the file
  you glanced at and now cannot find. Rejected: clicking down a forty-file folder
  would write forty entries and evict everything deliberately opened, which is
  the exact failure the preview tab was invented to prevent, reproduced in the
  history.
- **Record restored tabs.** Rejected: relaunching would stamp every restored tab
  with the launch time, and a history in which everything happened at 09:14 is
  not a history.
- **Prune entries whose file has gone.** Tidier, and wrong on a laptop: an
  unmounted volume, a detached network share and a not-yet-cloned repo all look
  like deletion for as long as the `stat` fails.
- **Do nothing.** Rejected: it is the request, and an app that already keeps two
  histories — one of directories, one of tabs it has not yet closed — declining
  to keep the one of documents is a strange place to stop.
