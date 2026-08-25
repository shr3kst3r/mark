---
id: 2026-08-24-single-window-custom-tab-bar
status: Superseded
supersedes: null
superseded-by: 2026-08-24-tab-residency-and-memory-model
components: [app, tabs, sidebar]
ticket: null
date: 2026-08-24
---
# Use one window with a custom tab bar and N resident web views, not native NSWindow tabbing

## Context

`mark` needs tabs and a directory-tree sidebar. macOS offers native window
tabbing, and it is genuinely generous: setting `tabbingMode = .preferred` with a
shared `tabbingIdentifier` and calling `addTabbedWindow` yields the tab bar, ⌘T
via `newWindowForTab:`, ⌃⇥ cycling, drag-to-reorder, drag-out-to-detach,
⌘⇧\ "Show All Tabs" overview, the overflow menu, Window-menu items with
automatic validation, full VoiceOver support, and `NSWindowRestoration` of the
whole tab group. We verified this works: a probe reached
`tabGroup.windows.count == 12` with the tab bar auto-appearing at two tabs.

The two objections we expected to native tabbing both turned out to be false.
A per-tab close button is free (hover ✕, ⌥-click closes others), and a per-tab
task count is achievable via `NSWindowTab.accessoryView` — verified present,
and AppKit auto-constrains it y-centered and right-aligned inside the tab, which
is exactly where a badge belongs.

The objection that survived is structural. **Each native tab *is* a separate
`NSWindow`**; switching tabs swaps which window is on screen rather than swapping
content views. That forces one `NSWindowController` per document — sharing one is
documented as a mistake — and, decisively, it makes a shared sidebar into *N*
sidebars that must be manually kept in sync on selection, width, collapsed state,
and scroll position. AppKit offers no affordance for this.

The user confirmed the directory sidebar is **shared** across tabs: it shows the
project tree, not a per-document outline. That is the case native tabbing handles
worst. The industry split is stark and lines up exactly on this axis — Terminal,
iTerm2, Ghostty and Apple's document apps use native tabs and have no persistent
sidebar; Safari, VS Code, Sublime Text, and Zed all hand-build a tab bar, and all
have one.

Given one window, the remaining question was whether to keep one web view and
re-inject documents on tab switch, or keep a resident view per tab. We measured
both, one window with a real split view and sidebar, 256 KB per document:

| Strategy | 24 tabs, total RSS | Marginal per tab | Tab switch |
|---|---|---|---|
| N resident views, show/hide | 102.0 MB | **~1.2 MB** | **0.05 ms** |
| 1 view, re-inject on switch | 93.5 MB | 0 | 8–9 ms first paint, 27 ms full fill |

Resident views cost about 8 MB more at 24 tabs and switch **~170× faster**, and
they preserve scroll position and any per-document JS state for free rather than
requiring us to save and restore it. WebKit coalesces same-configuration web
views into a single WebContent process, so 24 views stayed at 2 processes total.
Sharing one `WKWebViewConfiguration` also makes allocation ~1.3 ms per view after
the first (the first pays ~56–86 ms of content-process spin-up).

The baseline before any web view exists is ~74 MB with the split view and
sidebar in place. The user has explicitly accepted a floor in this range.

## Decision

`mark` runs **one** `NSWindow` containing an `NSSplitView`: a shared sidebar with
the directory tree, and a document area with our own tab bar above it.

Each open document owns a resident `WKWebView`, all sharing one
`WKWebViewConfiguration`, stacked in the document container. Switching tabs
shows the target view and hides the others — no re-injection, no re-layout, no
scroll restoration.

To bound memory, tabs beyond a resident working set (default 20, most recently
used) are **dehydrated**: their web view is torn down and the tab retains only
its file path, scroll offset, and title. Selecting a dehydrated tab rehydrates
it, which costs the measured re-injection path — ~9 ms to first paint, which is
imperceptible.

We hand-build the tab bar and own what native tabbing would have given us: tab
rendering, close buttons, per-tab task-count badges, drag-to-reorder, overflow,
⌘T / ⌘W / ⌃⇥ / ⌘1–9 key equivalents, Window-menu items, accessibility, and
session restore. Session state is persisted to our own JSON file rather than
relying on `NSWindowRestoration`, so restore is deterministic regardless of the
user's "Close windows when quitting an app" setting.

## Consequences

**Easier.** One window, one `NSWindowController`, one sidebar — no cross-tab
synchronization of anything. Tab switching is effectively free and preserves
scroll and JS state with no code. The tab bar can show whatever we want, so the
per-tab open-task count the product wants is unconstrained rather than squeezed
into an accessory view. Session restore is explicit and debuggable: a JSON file
we control.

**Harder, and we are accepting it.** We are rebuilding a well-tested piece of
AppKit by hand, and the parts that look easy are not. Drag-to-reorder with a
drag-out-to-new-window affordance is the hardest single piece of UI in the app.
Accessibility is ours now: a hand-drawn tab bar is invisible to VoiceOver unless
we implement `NSAccessibility` roles deliberately, and it is the kind of work
that gets skipped and then never done. Full-screen tab-bar behavior, tab overflow
when 30 documents are open, and keyboard-navigation parity with system tabs are
all ours to get right.

We are also **giving up cross-window tab merging and detaching for free**, and
giving up the "Show All Tabs" overview grid entirely unless we build one.

The dehydration policy adds a state machine — hydrated, dehydrated, rehydrating —
and every feature touching a tab must tolerate a tab whose DOM does not currently
exist. That is a real source of latent bugs: "search all open tabs" or "toggle a
checkbox in a background tab" must go through the core and the file, not the DOM.

Constraints this imposes on future work:

- **There is exactly one `NSWindow` and one `NSWindowController`.** Anything
  wanting a second top-level window (preferences, a detached document) is a new
  decision, not an extension of this one.
- **Never call `addTabbedWindow` or set `tabbingMode = .preferred`.** Mixing
  native tabbing into this design produces two competing tab bars. Set
  `tabbingMode = .disallowed` explicitly so AppKit does not add one.
- **All web views share one `WKWebViewConfiguration`** — this is what keeps them
  in a single content process and makes allocation ~1.3 ms. Per-tab
  configurations measured ~2× slower to create.
- **No feature may assume a tab's web view exists.** Anything operating across
  all open documents goes through the core against the file on disk.
- **The resident working set is a tunable, not a constant.** 20 is a starting
  point derived from ~1.2 MB per tab, not a measured optimum.
- **Session state lives in our own file**, not `NSWindowRestoration`, and
  `NSQuitAlwaysKeepsWindows` is a user preference we must not write.

**Worth being honest about:** this is the ADR most likely to be regretted. If the
sidebar ever becomes per-document, or if the hand-built tab bar accumulates
enough accessibility and drag-and-drop debt, native tabbing becomes the better
trade and this should be superseded rather than patched. The measurement that
would trigger that is qualitative, not numeric: the tab bar costing more
maintenance than the sidebar sync it avoided.

## Alternatives considered

- **Native `NSWindow` tabbing.** Free tab bar, free drag-and-drop, free
  accessibility, free ⌘T and Window-menu integration, free state restoration —
  a large amount of correct behavior for almost no code, and both objections we
  expected to it proved false. Rejected solely because each tab is a separate
  window, which turns the confirmed-shared directory sidebar into N sidebars
  requiring manual synchronization of selection, width, collapse state, and
  scroll. Every surveyed app with a persistent sidebar made the same call.
- **Native tabs with the directory tree in a separate panel window.** Keeps all
  the free chrome and dodges the sync problem. Rejected on product grounds: a
  floating tree panel is not the "directory viewer" that was asked for, and it
  gives up the split-view layout that makes a file tree useful.
- **One window, custom tab bar, single reused web view.** ~8 MB lighter at 24
  tabs and no dehydration state machine. Rejected on switch latency: 8–9 ms to
  first paint plus 27 ms to fill, on every tab switch forever, versus 0.05 ms —
  and it would require us to save and restore scroll position manually on each
  switch, which the resident design gets for free.
- **N resident views with no dehydration cap.** Simpler — no state machine.
  Rejected as unbounded: ~1.2 MB per tab is cheap but not free, and a user with
  100 documents open should not pay 120 MB for 95 they are not looking at.
- **`NSTabView`.** The AppKit control literally named for this. Rejected: its
  tab rendering is not customizable enough for task-count badges and close
  buttons, and it offers no drag-to-reorder — so we would own most of the work
  anyway while fighting a control's assumptions.
