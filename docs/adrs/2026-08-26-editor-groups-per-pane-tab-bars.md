---
id: 2026-08-26-editor-groups-per-pane-tab-bars
status: Accepted
supersedes: [2026-08-26-multiple-windows-and-split-panes]
superseded-by: null
components: [app, tabs, sidebar, ipc]
date: 2026-08-26
ticket: null
---
# Give each pane its own tab bar and its own tabs, so a split window is two editor groups rather than one tab bar pointing at two documents

## Context

`2026-08-26-multiple-windows-and-split-panes` shipped the split, and it
considered exactly this shape as an alternative:

> **Editor groups — a tab bar per pane, tabs dragged between them** (VS Code's
> model). The most capable option. Rejected for now as disproportionate: two
> stores per window, a split session shape, and "which store" threaded through
> the socket surface and every menu validation, to answer a request for two
> documents side by side. The pane model here does not foreclose it.

The request arrived anyway, in those words — *"could we split it in to two
different panes, with their own tabs?"* — with a screenshot of Chrome's split
view. So this is the deferred alternative being asked for directly, and the cost
estimate above is still the estimate. Nothing here disputes it. What changed is
that the estimate is now being weighed against a user asking for the feature
rather than against a cheaper way to answer a different request.

**On acceptance this supersedes `2026-08-26-multiple-windows-and-split-panes`**,
whose Decision says "one tab bar and a focused pane". A Proposed ADR cannot
declare `supersedes` without `just adr-check` demanding that the predecessor
already be `Superseded`, which is a human's call and not an author's — so both
frontmatter links are flipped at the same gate that flips this file to
`Accepted`, and until then they read `null`.

### What the one-bar model actually costs the reader

The predecessor's model is *one* list of tabs with two slots, so the bar has to
say which two of six documents are on screen. It does that by drawing the other
pane's tab as a "companion" — a third visual state alongside selected and
unselected, invented for this feature, that a reader has to learn. Ownership is
not expressible at all: a tab does not belong to a pane, so "close the right
half" means "collapse the split and keep whatever was focused", and the four
documents the reader had been comparing on the right are not a set the window
can name.

Three of its own consequences are the same fact from different angles: the
companion state, `show(_:in:)`'s swap rule so that no tab is in two panes, and
`primaryIsNeverEmptyAlone` — a test that exists because the model admits a state
("blank on the left, a document on the right") that no menu item can get out of.
Groups make all three vacuous: a tab is in a group, a group has one selection,
and an empty group is not a state, it is a group that closed.

### What the split cost to get on screen at all

Two rendering bugs, both from the same source, and they are the reason this ADR
is more confident about the *view* half than the estimate above was.

The first shipped: ⌘\ split the window and left half of it blank. The cause was
`DocumentView.draw(_:)` filling its background, which — around a layer-hosted
`WKWebView` — is composited over the whole of the sibling pane rather than
clipped to the overlap. Every assertion in `mark-bench`'s pane gate passed
while the window showed one document, because nothing in this process can see a
composited pixel: frames, layers, residency, hydration, `visibilityState` and
`WKWebView.takeSnapshot` all reported a working split. Fixed by making the
colour behind a page a layer background.

The second is still there: the focused pane's accent stripe is drawn by
`DocumentContainerView`, which is *under* the web views, so it cannot be seen.
The focus indicator the predecessor billed as "more AppKit we own by hand" was
never actually on screen.

Both say the same thing. Hand-drawn chrome that shares a coordinate space with a
layer-hosted `WKWebView` is where this feature's bugs live, and it is invisible
to every test the repo can write. Groups move the focus indicator into a tab
bar — a view that already draws correctly, above nothing, and that a reader
already looks at to answer "which document am I acting on?"

### What this does not change

The memory model. A group is AppKit views: a tab bar, a container, and a list of
tabs that mostly have no web view. Displayed tabs are still one per group, so a
split window still displays two documents and the formula from the predecessor
holds unchanged:

| Arrangement | Displayed | Resident | Footprint |
|---|---|---|---|
| One window, one group | 1 | 3 | ~264 MB |
| One window, two groups | 2 | 3 | ~264 MB |
| Two windows, three groups | 3 | 3 | ~264 MB |
| Two windows, four groups | 4 | 4 | ~316 MB |

The predecessor's trap generalises rather than going away. It warned that a
`residentLimit` per *window* licenses `limit × windows` resident views while
every log line still reports `limit`. A limit per *group* is the same bug with a
larger multiplier and an easier accident, because a group is exactly the object
that now owns a tab list — which is where a reader looking for the limit will
reach first.

## Decision

**A window contains one or two editor groups. A group owns an ordered list of
tabs, a selection, a tab bar and a document container. Residency stays budgeted
across the whole application.**

Specifically:

- **A group is the unit that owns tabs.** `TabStore` becomes per-group rather
  than per-window: one store, one `TabBarView`, one `DocumentContainerView` per
  group. `Pane` and `PaneArrangement` — a window-level map from a side to a tab
  — are removed, along with the companion tab state and the swap rule that
  existed to keep one tab out of two panes.

- **A window has a focused group, and `selected` means the focused group's
  selected tab.** The window title, the table of contents, the find bar, the
  editor pane binding and every socket command keep the meaning they have now.
  With one group the model is exactly today's single-pane window.

- **The focused group is where documents land.** A sidebar click, `mark open`,
  File ▸ Open and a drop all open into the focused group. Focus follows a click
  into a pane, a click on either bar, and ⌥⌘\.

- **The unfocused group's tab bar is drawn as inactive**, and that is the focus
  indicator. The accent stripe drawn under the web views is deleted rather than
  fixed: a second thing to notice, in a place where drawing has already produced
  two invisible bugs, buys nothing that dimming a bar does not.

- **A tab is in exactly one group, and a document is open in at most one place.**
  Carried forward verbatim from the predecessor, and now cheap to enforce:
  opening a file that is already open in the other group focuses it there rather
  than making a second `WKWebView`. Two views of one document is still ~104 MB
  and still a new decision.

- **⌘\ splits by moving.** The focused group's selected tab moves into a new
  second group when the group has more than one tab; with a single tab there is
  nothing to compare it against and the menu item is disabled, as it is today.
  ⇧⌘\ closes the split by moving the second group's tabs back into the first,
  keeping every document open — the current behaviour silently drops the other
  pane's document from the window, which was defensible when a tab belonged to no
  pane and is not defensible when it belongs to a group.

- **Tabs move between groups by dragging across the divider**, reusing
  `TabBarView`'s existing modal drag loop, and by a menu item — "Move to Other
  Pane" replacing "Open in Right Pane" — which is the accessible path and the
  one the tests drive.

- **Closing the last tab in a group collapses the split.** The surviving group
  takes the full width and the focus. A window with no tabs at all keeps its
  empty state, as now.

- **One residency governor for the application.** Groups register with it exactly
  as stores do today. `MARK_RESIDENT_TABS` keeps its meaning: total resident web
  views across the app. **A per-group limit is forbidden**, for the reason the
  predecessor gave about per-window limits, with the multiplier doubled.

- **Session state gains a group dimension additively.** A window entry keeps its
  existing `tabs`, `selected` and `splitFraction` fields describing the first
  group, and gains an optional `groups` array. `secondaryIndex` is read on
  restore, for one version, as "that tab starts the second group"; it is never
  written again. `SessionState.currentVersion` does not move, for the reason
  already recorded in `Session.swift`.

- **The socket keeps one command surface and no new verbs.** `mark tab list`
  reports the window and the group of each tab, indexing per window in group
  order, and `mark tab select <n>` takes that same index and focuses the group
  that owns it. Everything else continues to act on the key window's focused
  group.

- **One find bar and one editor pane per window, both following the focused
  group.** A find bar per group is not built: ⌘F is about the document being
  acted on, and the focused group is what says which that is.

Carried forward from the predecessor, unchanged and still binding: multiple
windows, each a `MainWindowController`; a resident tab costs **~52 MB**; never
measure memory by walking our process subtree; `tabbingMode = .disallowed` on
every window; one shared `WKWebViewConfiguration`; session state is our own file
with `isRestorable` false; the resident limit is a runtime tunable; no feature
may assume a tab's web view exists; `mark doctor` reports window count, tab
count, resident count, the budget and the system-wide WebContent process count —
still unimplemented, and now owing a group count as well.

Added by this ADR, from the two bugs above:

- **Nothing draws around a `WKWebView` in a shared coordinate space.** A colour
  behind a page is a layer background. Chrome that has to be seen goes in a view
  that is not a sibling of a web view, or above every one of them, and never in
  the superview's `draw(_:)`.

## Consequences

**Easier.** The window can say what it is showing: two groups, each with its own
documents, its own history and its own close button. The companion tab state,
the swap rule, the never-empty-primary invariant and the invisible focus stripe
all go away — four mechanisms replaced by one, and three of them existed only to
paper over the fact that a tab had no owner. ⇧⌘\ stops discarding a document.
Two documents from two directories can be compared without either group losing
the tabs the reader had lined up. `TabBarView` and `DocumentContainerView`
becoming per-group makes them ordinary components rather than window singletons,
which is also what a third group would need.

**Harder, and we are accepting it.**

- **Two tab bars is more chrome in a window that has a sidebar and may have an
  editor pane.** At a 640 pt minimum width a split window gives each group about
  300 pt of bar, which is two or three tabs before it scrolls. The predecessor's
  one bar was, for that width, the better bar. This is a real regression for
  small windows and it is the price of ownership being visible.
- **"Which group" is threaded through everything.** Menu validation, the socket
  router, session restore, the theme pass, the file watcher's set of watched
  files, drag targets, and every one of the ~40 places that says `tabs.selected`
  today. The predecessor called this disproportionate and it is the bulk of the
  work; the mitigation is that a window keeps a single `focusedGroup` and most
  of those places ask it rather than taking a group as a parameter.
- **The session file gets a second additive shape.** Three readers must now
  agree: the flat window fields, `windows`, and `groups`. Each layer is there so
  an older build restores something rather than failing, and each is a place
  where two readers can disagree.
- **Moving a tab between groups moves live machinery**, exactly as popping a tab
  out to another window does — its `Buffer`, its `flock(2)` lock, its autosave
  debounce, its conflict state, and every callback wired to a window. The move
  is now *within* a window, so the temptation to skip the re-wiring is stronger
  and the failure is the same: a buffer writing on behalf of a view nobody is
  looking at.
- **Tests still cannot see a pixel.** Groups reduce hand-drawn chrome but they do
  not change what the repo can assert. A split window that lays out perfectly
  and shows one document is still a thing that can ship, and the only guards
  against it are the layer-background constraint above and a human looking at the
  window.

Constraints this imposes on future work:

- **A group is not a memory allowance.** Residency accounting stays
  application-wide.
- **Anywhere a document is put on screen must register as a displayed tab**, or
  the governor will evict it while it is being read.
- **Never give one tab two views**, in one group, in two groups, or in two
  windows.
- **Two groups is what is built.** A third is not foreclosed — the types stop
  being singletons here — but the focus model is still "which group", the split
  is still one divider, and generalising the layout is a design change rather
  than a loop bound.

## Alternatives considered

- **Keep one tab bar and add Chrome's picker** — ⌘\ opens a "choose a document
  for the other pane" list instead of silently taking the most recently used
  tab. Much cheaper, and it fixes the one thing about ⌘\ that is genuinely
  confusing today. Rejected because it leaves ownership unexpressible: the
  companion state, the swap rule and ⇧⌘\ dropping a document all survive, and
  the request was for panes with their own tabs.
- **Two windows instead of two groups.** Already shipped, and for two documents
  on two displays it is the better answer. Rejected as a substitute: it gives up
  one sidebar, one window frame and one set of menus for a comparison inside a
  single document tree, which is what a split is for.
- **N groups with a general layout tree** (Zed, tmux). Rejected: nothing in the
  request needs a third pane, the divider drag and the session shape both get
  materially harder, and a boolean focus model is honest about what is built.
- **A find bar and an editor pane per group.** Rejected for now: ⌘F and ⌥⌘E act
  on the document being acted on, the focused group already says which that is,
  and two find bars in a 640 pt window is chrome competing with the documents.
- **Do nothing; the split works now.** Rejected: it works, and the reader still
  cannot tell which of six tabs are on screen without learning a third tab
  state, still loses a document to ⇧⌘\, and still cannot keep two sets of tabs.
