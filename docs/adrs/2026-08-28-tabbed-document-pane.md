---
id: 2026-08-28-tabbed-document-pane
status: Accepted
supersedes: null
superseded-by: null
components: [app, sidebar, tabs]
ticket: null
date: 2026-08-28
---
# Make the sidebar's lower half a tabbed document pane, and give the five task states somewhere to be read

## Context

`2026-08-27-five-task-states` shipped a vocabulary the window cannot show. The
counts exist, per state, everywhere they are computed:

```
$ mark stats demo.md | grep -i task
tasks             4 outstanding / 5 active / 6 total
task states       2 open / 1 in progress / 1 done / 1 cancelled / 1 blocked
```

The window, for that same file, says `4/5` on the sidebar row
(`TaskBadgeService.swift:34`) and `4` on the tab (`TabBarView.swift:762`). Both
numbers are correct and neither can be decomposed. The only place a state is
named at all is VoiceOver on a sidebar row, for cancelled alone
(`TreeCellView.swift:118`). A reader who wants to know what is blocked in the
document they are reading scrolls the preview looking for `[?]`, or leaves the app
and runs `mark tasks --state blocked`.

So the request — *"can mark show the todo counts for the various states"*, then
*"I want it to be tabbed, so I can switch between current and the todo
information"* — is not asking for a new computation. It is asking for a place to
put one.

### The data is already in hand, and already discarded

`DocumentMetadata.load` calls `MarkCore.tasks(source:)`, receives `[Task]` —
every task with its state, its `label`, its tags, its priority, its due date and
its byte span — and reduces it to `TaskCounts(tasks)`, dropping the array
(`DocumentTab.swift:79`). `headings` made the opposite choice for the same
reason, and says so:

> Free, in the sense that matters: `documentTitle` was already a `toc` call, and
> this keeps the result instead of throwing all but the first entry away.

Keeping the tasks is that trade a second time. It means the pane needs no new
parse, no new C ABI function — `2026-08-24-rust-core-swift-appkit-shell`'s
surface is full at twelve and this feature does not touch it — no file read of
its own, and it works for a tab whose `WKWebView` has been torn down, which
`2026-08-26-editor-groups-per-pane-tab-bars` requires of anything that operates
across open documents.

### Why tabs, when the pane above it is deliberately not tabbed

`TableOfContentsViewController.swift:56` records the current intent:

> The tree above it answers *"which file"*; this answers *"where in it"*, and
> the two are stacked rather than tabbed because moving between them is the
> normal reading loop rather than a mode switch.

That reasoning holds and is not being reversed: tree and outline stay stacked,
both visible, because a reader moves between "which file" and "where in it"
constantly. Headings and tasks are a different relationship. They answer the same
question — *where in this document* — for two different activities, and a reader
outlining a document is not simultaneously working its checklist. Stacking a
third pane would put three scroll views and two dividers in a 260 pt column and
charge every reader for the one they are not using; tabs charge the reader one
click and no vertical space.

### What the pane cannot see, and the bug that hides in it

The pane has exactly one refresh point: `updateTableOfContents()`, called from
`updateChrome()` (`MainWindowController.swift:844`), which runs on every tab
switch, every tab-list change and every metadata load, and whose `show(_:for:)`
compares before rebuilding so that calling it often costs an array comparison.

Five other paths refresh a tab's metadata and do **not** call it: the file
watcher's adopted, converged and conflicted outcomes (lines 618, 629), the buffer
going dirty and being saved (752, 757), and ⌘R (2275). Each ends in
`tab.refreshMetadata { tabBar.reload() }`.

For headings that is latent: an external edit adds a heading and the outline is
stale until something else calls `updateChrome()`. For tasks it is the *main*
path. A checkbox click in the preview writes one byte to the file
(`DocumentView.write(_:)`), the watcher reports the change, metadata is
recomputed, the tab badge moves — and a Tasks pane would go on showing the state
the reader just clicked away from. The one path that is already correct is the
dirty-buffer one, because `updatePreview(of:from:)` is the single place that calls
both (line 791).

A tabbed pane whose second tab is wrong after every click is not worth shipping,
so the funnel is part of this decision rather than a follow-up.

### A task has no anchor

`toc.onSelect` scrolls the preview through `shell.js`'s `mark.scrollToAnchor`,
which forces `ensureFullyRendered()` first — `2026-08-24-progressive-document-rendering`'s
constraint, and the reason a heading three quarters down a long document can be
navigated to at all — and returns `false` when the anchor does not exist.

Tasks carry no anchor. What every task `<input>` does carry, re-stamped from
`mark_tasks_json` after every patch, is `data-mk-idx`, `data-mk-start`,
`data-mk-end` and `data-mk-state` (`shell.js:619`). Two identities are therefore
available, and they fail differently. `data-mk-idx` is the `(file, task-index)`
identity `2026-08-24-rust-core-swift-appkit-shell` fixes — and the one
`2026-08-27-five-task-states` had to measure a renumbering hazard for, because
recognising new markers grows the task set. `data-mk-start` is the marker's byte
offset: what the write path re-verifies before it changes a byte, and what
`sourceTop()` already uses to map the preview back to the source.

The pane's list and the page's attributes are computed from the same bytes almost
always, and from different bytes for the moment between a metadata refresh and a
re-render. Index alone lands on the wrong item in that moment. The byte offset
does not, and costs one extra argument.

## Decision

**The sidebar's lower half is a tabbed document pane. It has two tabs —
Contents and Tasks — both scoped to the focused group's selected document, and
both fed by that tab's `DocumentMetadata`.**

Specifically:

- **`SidebarPaneController` keeps its two stacked halves.** The tree stays on
  top, always visible. What changes is that the lower half is a container with a
  mode rather than a single view controller, and `TableOfContentsViewController`
  becomes one of the two things it can show. ⌃⌘T continues to show and hide the
  lower half as a whole; the split view, its `autosaveName`, its minimum heights
  and its collapse behaviour are untouched.

- **The mode is chosen from a two-segment `NSSegmentedControl` in the pane's
  existing 22 pt header**, replacing the static "Contents" label. A standard
  control rather than two hand-drawn text buttons: it is keyboard- and
  VoiceOver-reachable without our writing either, and this repo has already paid
  twice for chrome it drew itself
  (`2026-08-26-editor-groups-per-pane-tab-bars`, both invisible bugs).

- **Each View-menu item shows the pane on its own tab, or hides the pane if that
  tab is already showing.** ⌃⌘T is Contents and keeps its exact current
  behaviour for a reader who never opens Tasks; ⌃⌘Y is Tasks. One rule, both
  items, and it is what the menu-validation tests assert.

- **The Tasks tab shows a five-state summary line and the document's tasks
  grouped under collapsible state headings, in document order within each
  group.** Document order is the only order the pane can show without arguing
  with `mark tasks --sort`, which is where sorting belongs.

- **Every number in the pane comes from `TaskCounts`.** Outstanding is open +
  in-progress + blocked; cancelled is the only state that leaves the
  denominator. `2026-08-27-five-task-states` fixed that arithmetic and
  `TaskCounts` is where it lives — the pane must not re-derive it, and a group
  heading's count is a count of markers, never affected by a tag
  (`2026-08-27-inline-task-metadata`).

- **A row shows `label`, not `text`** — the metadata tokens stripped — with
  priority and due date as trailing decoration. The tokens are still in the
  document and still in the preview; a list that repeated them would be showing
  its source rather than its content.

- **The pane's input is `DocumentMetadata` and nothing else.** `DocumentMetadata`
  gains the task list beside the counts and headings it already carries, out of
  the `mark_tasks_json` call it already makes. No DOM query, no file read, no ABI
  addition: *"no feature may assume a tab's web view exists"*.

- **The document pane is refreshed everywhere a tab's metadata changes.** The
  five paths that call `refreshMetadata` and reload only the tab bar are funnelled
  through one place that also refreshes the pane. A pane fed by metadata must be
  refreshed wherever metadata is, or it is a cache with no invalidation.

- **Clicking a task scrolls the preview to it, identified by byte offset with the
  task index as a fallback.** A new `mark.scrollToTask(index, start)` in
  `shell.js`, in the shape of `mark.scrollToAnchor`: force the background fill,
  prefer the element whose `data-mk-start` matches, fall back to `data-mk-idx`,
  scroll the item into view, and return whether it was found. Focus stays in the
  pane, exactly as it does for a heading, so ↑/↓ keeps walking the list.

- **The pane never writes.** Ticking a box stays in the preview and in
  `mark check`. `2026-08-25-flock-write-locking` and
  `2026-08-27-five-task-states` put every state change through one locked,
  span-verified, one-byte path, and a second control that wrote would be a second
  caller of it for no new capability — the preview's own checkbox is two clicks
  away and already offers all five states.

- **The selected tab is a `UserDefaults` preference, not session state.** The
  same rule the divider already follows: *"where the reader put the divider is a
  preference, not session state, and it is the same one for every project they
  open."* `SessionState.currentVersion` does not move, and no session field is
  added.

- **Two tabs is what is built.** The container takes a mode, not a list of
  plugins. A third tab is not foreclosed and is also not designed for.

- **Per-document only.** The pane answers "where in this document"; a
  project-wide task list across the sidebar tree is a different feature with a
  different cost, and `mark tasks <dir>` already answers it in the CLI.

- **No socket verb.** ⌃⌘T has none either — the lower pane is app-only today —
  so this adds no `mark` subcommand and no `SidebarSummary` field.
  `2026-08-24-cli-app-unix-socket-ipc` governs that surface if it is ever wanted,
  and a headless caller has `mark tasks` already.

## Consequences

**Easier.** The five states become readable in the window that owns them, in the
place a reader is already looking to navigate the document. A checklist can be
worked from the sidebar: see what is blocked, click it, read it in context. The
Tasks tab costs no parse, no ABI call and no file read, and it is correct for a
dehydrated tab. The refresh funnel fixes a staleness bug the outline has had
since it shipped, and gives any future document-scoped pane one place to hook.

**Harder, and we are accepting it.**

- **A mode is a thing a reader can be lost in.** The pane can be showing Tasks
  for a document with no tasks while the reader is looking for the outline. That
  is what the header control is for, and it is why the empty state has to name
  the mode ("No tasks in this document") rather than saying "empty".
- **`DocumentMetadata` grows with the document.** A tab now holds every task,
  each with a label and its tags, in addition to every heading. For the notes
  this app is written for that is kilobytes; for a generated 20k-task file it is
  megabytes per open tab, and it is held for tabs that are dehydrated precisely
  to save memory. We accept it because the array is already materialised on every
  metadata load — we are keeping it rather than allocating it — but it is a real
  cost, and it is the first thing to measure if a tab's footprint moves.
- **Two navigation identities now exist for a task.** The pane prefers the byte
  offset, the click path in the page reports the index, and `mark check --item N`
  is the index. Three consumers, two identities, and a reader of any one of them
  has to know which. The fallback ordering is written down here because it is
  otherwise the kind of thing that gets "simplified" to index-only by someone who
  has not hit the stale moment.
- **The pane's correctness now depends on a funnel that is easy to bypass.** The
  next `refreshMetadata` call site added anywhere in the window will silently not
  refresh the pane unless it goes through the funnel. That is strictly better than
  the five bypasses that exist today, and it is still a rule rather than a
  mechanism.
- **Another key equivalent spent.** ⌃⌘Y for a second sidebar mode is a
  keystroke a future feature cannot have, in a window that already binds ⌃⌘S,
  ⌥⌘E, ⌃⌘T and three modifiers of ⌘\.
- **Tests still cannot see a pixel.** A segmented control that lays out
  correctly and a pane that shows the wrong tab are indistinguishable to this
  repo's test suite, as
  `2026-08-26-editor-groups-per-pane-tab-bars` already says of the split. What
  can be asserted is the mode, the model, the counts, the grouping, the menu
  validation and the page function's existence — and that is what will be.

Constraints this imposes on future work:

- **The document pane's tabs are fed by `DocumentMetadata`.** A tab that needs
  something else needs that something in metadata first, computed off the main
  thread from the bytes, or it will read a file on the main thread the first time
  someone opens a large document.
- **Nothing in the document pane writes to a document.** If a pane ever needs
  to, it goes through the existing locked path and it is a new decision, not an
  extension of this one.
- **The pane holds no state that is not derivable from the selected tab**, other
  than its mode and the reader's collapse choices. It is redrawn from metadata,
  and anything else it remembers is a cache that will go stale on a path nobody
  listed.

## Alternatives considered

- **A per-state breakdown in the existing badges and tooltips.** Far cheaper: the
  sidebar row's tooltip is currently just the file path, and `TaskBadge` already
  holds all five counts, so `4/5 · 1?` or a tooltip line is a formatting change.
  Rejected as an answer to *this* request — it shows counts and still gives the
  reader nowhere to see *which* tasks are blocked, and a tooltip cannot be
  clicked. Worth doing anyway, and not foreclosed by this ADR.
- **A third stacked pane under the outline.** No mode to be lost in, both visible
  at once. Rejected on space: three scroll views and two dividers in a 260 pt
  sidebar, with the reader paying vertical room for the half they are not using,
  and the minimum-height constraint (72 pt each) would leave the tree with almost
  nothing on a short window.
- **Tab the whole sidebar — Files | Contents | Tasks.** One control instead of
  the current stack plus a new control. Rejected because it reverses the
  tree/outline decision quoted above for no gain: the reader would lose sight of
  the file tree to read an outline, and moving between "which file" and "where in
  it" is the normal loop, not a mode switch.
- **A separate Tasks window.** Precedent exists — `2026-08-26-opened-file-history`
  and `2026-08-26-markdown-reference-window` both put a thing in its own window.
  Rejected: a task list is about the document you are reading, and a window that
  has to follow the front document while not being next to it is the worst of
  both. A project-wide task list, if it is ever built, is the shape that would
  earn a window.
- **Let the pane tick boxes.** The obvious next request, and deliberately not
  built. Rejected for now: it adds a second caller to the locked write path, and
  it adds the dirty-buffer fork (`BufferTaskWriter` vs `FileTaskWriter`) to a view
  that currently cannot be wrong about which bytes are truth. The preview's
  checkbox already reaches all five states, and `mark check` already scripts it.
- **Render the task list into the preview instead** — a generated summary block
  at the top of the document. Rejected outright: it would make
  `mark render --html` a function of something other than the file, which
  `2026-08-24-rust-side-math-and-diagrams` exists to prevent.
- **Do nothing; `mark stats` and `mark ls --json` already answer it.** Rejected:
  they answer it in a terminal, for a reader who is in a window, about the
  document that window is already showing.
