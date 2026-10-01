---
id: 2026-09-01-sidebar-poll-gates-the-tick-not-the-timer
status: Accepted
supersedes: 2026-08-27-sidebar-polls-listed-directories
superseded-by: null
components: [app, sidebar]
ticket: null
date: 2026-09-01
---
# The sidebar poll's visibility check gates each tick's work, not the timer's existence

## Context

`2026-08-27-sidebar-polls-listed-directories` decided the refresh, and every part
of it holds except one sentence: *"The timer runs only while the view is in a
window that `occlusionState` reports visible and the split view has not collapsed
it, and fires once immediately on appearing and on being uncovered."*

That sentence is what shipped, and it does not work. Observed on a running
0.3.0 (`a0b523f`) with three windows open for four hours:

* A file written into an expanded directory never appeared. ⌘⇧O on it logged
  `reveal: notes-….md is not listed under …/notes` twice, sixteen seconds
  apart, while that window was frontmost.
* Files written into that directory, into a sibling, and into the sidebar's own
  root moved each directory's mtime and produced no `dev.mark:tree` activity
  over four intervals, while `dev.mark:git` logged its badge poll every two
  seconds from another window.
* Forcing a fresh listing (`mark nav` into the folder) logged `listed …: 7
  entries`, including the missing file. The core was right the whole time; the
  cached listing was three minutes old and nothing was going to re-read it.
* Hiding and reactivating the app logged `sidebar poll stopped` **twice** —
  two of three windows had a timer — then `sidebar poll started` three times,
  and the pending change landed within a second.

The mechanism: `updatePolling()` was reachable from exactly two places,
`viewDidAppear` and the `NSWindow.didChangeOcclusionStateNotification` handler.
A window whose sidebar is not "visible" at the single instant `viewDidAppear`
runs therefore starts with no timer — which is the normal case for a window
restored behind another one, and `occlusionState` is not reliable immediately
after `orderFront` either. From then on, only an occlusion *transition* can
start one. Bringing that window to the front need not produce one: the change
either already happened before the observer existed, or AppKit considered the
window visible all along. The tree then never refreshes again for the life of
the window, silently, because a listing that is merely old looks exactly like a
listing that is right.

The gate was also the one part of the refresh with no test.
`SidebarPollTests` said so in a comment — *"the timer's own lifecycle needs a
window on screen and is left to the app"* — and that is where the bug lived.

## Decision

Everything in `2026-08-27-sidebar-polls-listed-directories` stands: the sidebar
polls every `TreeViewController.pollInterval` (2 s, 0.5 s tolerance,
`.default` run loop mode), `TreeDataSource.reconcile()` `stat`s only the
directories whose listings have already been read and re-lists only those whose
own mtime moved, a re-listed directory adopts entries so surviving rows keep
their `TreeNode`, and the two deliberate gaps — a stale badge under an unopened
row, a `.gitignore` edited in place — are still left to ⌘R and the document
watcher.

The one change: **the visibility check gates the work a tick does, not whether
the timer exists.** The timer runs for as long as the view is in a window —
started in `viewDidAppear`, stopped in `viewDidDisappear` — and `pollTick()`
asks `shouldPoll` (view in a window, not collapsed, `occlusionState` visible)
and returns without a syscall when the answer is no.

Window notifications become a way to bring the catch-up *forward* rather than
the only way to get one. `didChangeOcclusionState`, `didBecomeKey`,
`didDeminiaturize`, and `NSApplication.didBecomeActive` each poll immediately
when the sidebar is visible. Any of them may be missed with no lasting
consequence, which is the property the list needs to have, because no set of
AppKit notifications is ever provably complete.

`TreeViewController.pollVisibility` lets a test answer for the window, so the
gate is testable without one.

## Consequences

A missed transition now costs one interval instead of a window's lifetime. The
failure mode it replaces was unbounded, silent, and indistinguishable from a
correct sidebar — the worst shape a bug can have in a tree whose whole job is to
tell you what is on disk.

We accept one timer wakeup every two seconds per window whose sidebar nobody is
looking at. The tick reads two properties and returns; it makes no syscall, no
directory read, and no `git` call, and `SidebarPollTests.aHiddenTickReadsNothing`
holds that. The incremental cost is smaller than it looks: any window being
looked at already wakes the app on the same interval, so this is only a real
change when every window is hidden, and it is one coalesced wakeup — 0.5 s
tolerance — doing nothing.

We accept that "is this worth polling?" is now asked 30 times a minute rather
than on transitions. It is cheaper than the notification bookkeeping it replaces
and it is the reason a collapsed-then-reopened sidebar, a window moved between
spaces, or any AppKit path nobody enumerated self-heals within one interval.

The catch-up poll on appearing still runs whether or not the sidebar is visible,
so a window coming back to a directory that changed while it was gone is right
by the time it is drawn.

## Alternatives considered

**Observe more notifications, keep starting and stopping the timer.**
`didBecomeKey` plus `NSApplication.didBecomeActive` would have fixed the
observed case. Rejected as the primary mechanism: it is the same design — a gate
that can only be reopened by a notification arriving at the right moment — with
a longer list of moments, and the next window state nobody thought of fails the
same way, just as silently.

**Re-evaluate on `viewDidLayout`.** Catches the collapsed-sidebar case for free.
Rejected: it fires on every resize and scroll, so the poll's lifecycle would
depend on layout traffic, and it still says nothing about occlusion.

**Drop the visibility gate entirely and always poll.** Simplest of all.
Rejected because the gate is load-bearing for the cost model, not for
correctness: one `stat` per expanded directory plus a `git` stamp per repository,
twice a second, for windows on another space and for an app that has been in the
background since morning, is exactly the background cost
`2026-08-27-sidebar-polls-listed-directories` refused.

**Have `pollTick` invalidate its own timer when hidden, and rely on
notifications to restart.** Saves the wakeup. Rejected: it is the shipped bug
with extra steps.
