---
id: 2026-08-26-multiple-windows-and-split-panes
status: Accepted
supersedes: [2026-08-24-tab-residency-and-memory-model]
superseded-by: null
components: [app, tabs, sidebar, ipc]
ticket: null
date: 2026-08-26
---
# Allow more than one window and two documents on screen at once, with residency budgeted across the whole app rather than per window

## Context

Two requests arrived together: *"I would like to pop out tabs so I can look at
them individually"* and *"I would like to be able to have two tabs side by
side."*

`2026-08-24-tab-residency-and-memory-model` forecloses both. Its Decision line
is "**one `NSWindow`, one `NSWindowController`**, a hand-built tab bar, a shared
sidebar, resident `WKWebView`s with MRU dehydration, and session state in our own
JSON file", and its constraint list repeats it: "exactly one window and one
window controller". The code is built to match — `AppDelegate` holds a singular
`mainWindowController`, `WindowMenu.shared` is documented as "there is one window
and therefore one Window menu", `DocumentContainerView` says "showing a tab
unhides one and hides the rest", and `TabBarView`'s own header lists "drag-out to
a new window (there is exactly one `NSWindow`)" among the things it deliberately
does not implement.

**This supersession is a change of scope, not a correction.** The last one was a
re-measurement: the ~1.2 MB-per-tab figure was wrong by ~40× and the ADR existed
to say so. Nothing found here disputes any measurement in that ADR. A resident
`WKWebView` still costs ~52 MB, WebKit's content processes are still children of
launchd rather than of us, and rehydration is still ~4.7 ms. A future reader
should not infer from this file that the numbers became suspect again. Everything
that ADR established about *cost* is carried forward verbatim; only the window
count and the eviction rules change.

The superseded ADR anticipated this arriving:

> Anything wanting a second top-level window (preferences, a detached document)
> is a new decision, not an extension of this one.

This is that new decision.

### What actually blocks the features

Not the window count on its own — the eviction policy.
`TabStore.enforceResidentLimit()` exempts exactly two things: the **selected**
tab, and any **dirty** tab. Everything else is MRU-evicted down to
`residentLimit`.

Both features introduce a third category the policy has no name for: *a tab that
is on screen but is not `selected`*. That is the right-hand pane of a split, and
it is every tab displayed in a window that is not currently key. Evicting one of
those tears the `WKWebView` out from under a document the user is looking at —
the failure is a pane going blank while being read.

### The trap that would ship silently

`residentLimit` is a property of a `TabStore`. The obvious implementation gives
each window its own store, and three windows then license 3 × 3 = 9 resident
views — about 470 MB — while `MARK_RESIDENT_TABS`, every log line, and any
future `mark doctor` output still report the limit as 3. The budget would be
exceeded by a factor of the window count, invisibly, and the formula in the
superseded ADR would quietly stop describing the app.

### What it costs to show two documents

Under the superseded ADR's formula, `~100 MB baseline + ~52 MB × resident tabs`,
with the default limit of 3:

| Arrangement | Displayed | Resident | Footprint |
|---|---|---|---|
| One window, no split (today) | 1 | 3 | ~264 MB |
| One window, split | 2 | 3 | ~264 MB |
| Two windows, one split | 3 | 3 | ~264 MB |
| Two windows, both split | 4 | 4 | ~316 MB |

The first three rows cost nothing extra, because displayed tabs count *toward*
the limit rather than on top of it — a split does not add a web view, it stops
one from being evicted. Only the fourth row exceeds the budget, and it does so
the same way dirty tabs already do: the limit is a target that on-screen work
outranks.

A window's own chrome — `NSWindow`, split view, sidebar, tab bar, no web view —
is AppKit views rather than a content process, and is small against 52 MB. That
is reasoning, not a measurement, and is stated as such.

### An unfinished bullet from the superseded ADR

That ADR required "**`mark doctor` reports WebContent process count and total
footprint**, so the real cost is visible rather than inferred from a subtree
walk." It was never implemented: neither `WebContent` nor `footprint` appears
anywhere in `cli/`. The requirement mattered when the cost was a constant. With
the cost now varying by window and pane arrangement, it matters more.

## Decision

**We allow more than one window, and up to two documents visible at once within
a window. Residency is budgeted across the whole application.**

Specifically:

- **`MainWindowController` becomes multi-instance.** A popped-out window is
  another instance of the same class — same sidebar, tab bar, editor, find bar,
  themes and checkbox behaviour — created with its sidebar collapsed. There is no
  second, lesser window class, so no document feature has a second place to
  drift.

- **A tab is displayed in at most one place, ever.** Popping a tab out *moves*
  it: it leaves the source window's tab bar and its `DocumentView` is reparented
  into the new window. A document therefore still has at most one `WKWebView`,
  which is what keeps the memory formula true.

- **A window shows a primary pane and, when split, a secondary pane**, with one
  tab bar and a focused pane. `selected` means "the tab in the focused pane", so
  the window title, table of contents, find bar, editor binding and every socket
  command keep their existing meaning. With no split the model is exactly today's.

- **Displayed tabs are never evicted, and count toward the limit.** This is the
  third exemption, alongside the selected tab and dirty tabs. Where displayed
  tabs alone exceed the limit, the limit is exceeded and the fact is logged —
  the same accepted trade already made for dirty tabs.

- **One residency governor for the application, not one per window.** The MRU
  clock and the eviction pass span every window's tabs. `MARK_RESIDENT_TABS`
  remains the single runtime tunable and keeps its meaning: total resident web
  views across the app.

- **The memory budget is unchanged in form and in value:**
  `~100 MB baseline + ~52 MB × resident tabs`, ~264 MB at the default. Opening
  windows does not raise it; only displayed-or-dirty tabs beyond the limit do.

- **`mark doctor` reports window count, tab count, resident count, the budget
  computed from the formula, and the system-wide `com.apple.WebKit.WebContent`
  process count.** This discharges the superseded ADR's unimplemented bullet.
  Counted system-wide and labelled as such, never by walking our own subtree.

- **The socket keeps one router and one command surface.** Commands act on the
  **key window**, falling back to the first window when none is key. `mark tab
  list` reports which window each tab is in. No new verbs.

- **Session state gains a window dimension**, in our own file, additively: the
  existing top-level fields continue to describe the first window, and a new
  optional `windows` array describes all of them. `SessionState.currentVersion`
  does not move, for the reason already recorded in `Session.swift` — a version
  bump would refuse yesterday's file and lose the user's tabs to buy nothing.

Carried forward from the superseded ADR, unchanged and still binding:

- A resident tab costs **~52 MB**, and this is the number any future decision
  about tab residency must use.
- **Never measure process memory by walking the app's process subtree.** WebKit's
  content processes are children of launchd.
- Native `NSWindow` tabbing stays rejected. **`tabbingMode` stays `.disallowed`
  on every window** and `addTabbedWindow` is never called — now a per-window
  obligation rather than a single one.
- All web views share one `WKWebViewConfiguration`.
- Session state is our own file; `isRestorable` stays false and
  `NSQuitAlwaysKeepsWindows` is never written.
- The resident limit stays a runtime tunable, never a compile-time constant.
- No feature may assume a tab's web view exists.

## Consequences

**Easier.** The two requested features exist, and a third falls out of the same
mechanism: a document can be read on a second display without giving up the tab
bar or the sidebar. Because a popped-out window is the same class, find, the
editor pane, themes, the table of contents and checkbox writes work there on the
first day rather than being a list of things that do not work yet. The residency
governor makes the memory budget an application-level fact for the first time —
previously it was a per-store property that happened to have one store.

**Harder, and we are accepting it.**

- **The budget can now be pinned above the limit by the screen, not just by
  unsaved work.** Four displayed documents is ~316 MB and no eviction can help,
  because every one of them is being looked at. This is a real and permanent
  widening of the worst case.
- **"The window" stops being unambiguous for the CLI.** `mark open notes.md`
  previously had exactly one place to go. It now goes to the key window, so the
  same command run twice with a different window in front does different things.
  That is the correct behaviour and it is still a behaviour change for any
  script that assumed otherwise.
- **Moving a dirty tab between windows moves live machinery**, not just a row in
  a list. The tab carries its `Buffer`, its `flock(2)` write lock, its autosave
  debounce and its conflict state, and every callback wired to the old window
  must be re-wired to the new one. `2026-08-25-flock-write-locking` is unchanged
  and unforgiving here: a half-moved buffer writes a file on behalf of a window
  that no longer shows it.
- **More AppKit we own by hand.** A pane divider, a focus indicator, per-window
  menu validation, a Window menu that follows the key window, and window frame
  restoration. The superseded ADR's "we are rebuilding a well-tested piece of
  AppKit by hand" bill gets larger, not smaller.
- **The session file gets a shape that two readers must agree on.** The
  duplication between the flat fields and `windows[0]` is deliberate
  compatibility cost: an older build restores one window instead of failing, and
  a newer build ignores the flat fields when `windows` is present.

Constraints this imposes on future work:

- **Anywhere a document is put on screen must register as a displayed tab.** A
  new surface that shows a `DocumentView` without doing so will have it evicted
  underneath the user, and the bug will look like WebKit's fault.
- **Never give one tab two views.** If a feature seems to need the same document
  in two places at once, that is a new decision with a ~52 MB price on it, not an
  implementation detail.
- **Residency accounting stays application-wide.** A per-window limit multiplies
  the budget by the window count while continuing to report the old number.
- **`tabbingMode = .disallowed` is set on every window, at creation.** One window
  missing it reintroduces the competing-tab-bar failure on a user with "Prefer
  tabs: always".
- **Two panes is what is built.** More panes per window is not foreclosed, but
  the focus model here is a boolean, and generalising it is a design change
  rather than a loop bound.

## Alternatives considered

- **Native `NSWindow` tabbing** (`addTabbedWindow`, `tabbingMode = .preferred`).
  Would supply drag-out, merging and the tab overview for free. Rejected again,
  on the superseded ADR's own ground: the sidebar is shared within a window and
  native tabbing gives each tab its own window, plus we would then have two
  competing tab bars. Nothing about that argument changed.
- **Per-window residency limits.** The obvious implementation, and the one the
  code shape invites. Rejected: it multiplies the memory budget by the window
  count while every log line and tunable keeps reporting the per-window number.
  This is the single most likely way to get this change wrong.
- **Show the same tab in both panes** (a mirror, or a source/preview pair).
  Rejected: two `WKWebView`s for one document is ~104 MB, and two DOMs fed from
  one `Buffer` is a synchronisation problem `2026-08-25-flock-write-locking`
  does not describe and should not have to.
- **A stripped detached-document window** — one document, a find bar, nothing
  else. Genuinely more "popped out" in feel, and it was the first shape
  considered. Rejected: it is *more* code than reusing the existing controller,
  it makes ⌥⌘E and the table of contents dead in the detached window, and it
  creates a second place where every future document feature has to be
  implemented or consciously skipped.
- **Editor groups — a tab bar per pane, tabs dragged between them** (VS Code's
  model). The most capable option. Rejected for now as disproportionate: two
  stores per window, a split session shape, and "which store" threaded through
  the socket surface and every menu validation, to answer a request for two
  documents side by side. The pane model here does not foreclose it.
- **Do nothing and rely on two copies of the app.** Rejected: the second copy
  takes the socket over (`2026-08-24-cli-app-unix-socket-ipc`'s stale-socket
  rule), so the CLI would then drive whichever copy launched last.
