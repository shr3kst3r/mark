---
id: 2026-08-27-sidebar-polls-listed-directories
status: Superseded
supersedes: null
superseded-by: 2026-09-01-sidebar-poll-gates-the-tick-not-the-timer
components: [app, sidebar]
ticket: null
date: 2026-08-27
---
# Refresh the sidebar by polling the directories it has already listed, gated on each one's own mtime

## Context

The request is *"the sidebar with directory should refresh the files every so
often — otherwise you will open it and if a new file is written, you won't be
able to see it."*

That is exactly what happened. `TreeNode.children` is `nil` until a directory is
expanded, and once read it was never re-read. The only ways back to the disk
were ⌘R (`MainWindowController.refreshSidebar`) and the two places that already
knew they had changed the tree themselves — a drop onto a breadcrumb, and File ▸
New Document. A file written by anything else — a script, `git checkout`, an
editor in another window, `mark` itself in a terminal — was invisible until the
reader thought to press ⌘R, which means being told the sidebar can be stale.

Three existing facts decide most of what follows.

### The app already has a file watcher, and it is the wrong shape for this

`Watch/FileWatcher.swift` is an FSEvents stream, and
`2026-08-24-editing-pane-and-autosave` sets out why it is built the way it is:
paths not descriptors, parent directories not files, debounce, content-hash
before reporting. But it watches **the directories holding the open documents**
— typically one or two — and its whole output is `FileChange`, a document's new
bytes. It exists to re-render a tab.

Pointing it at the sidebar instead means watching the sidebar's *root*, and
FSEvents streams are recursive from each root. The root of this window is
routinely `~/src`, which research §2.8 measured at **608,597 files**. A
`cargo build` under it produces a continuous firehose of events, every one of
which wakes the app to discover that the path is under a directory nobody
expanded. The cost of the watch is set by the size of the tree rather than by
what is on screen, which is the one property this sidebar is written to avoid
everywhere else.

### The sidebar's whole design is "read nothing you are not showing"

`TreeDataSource` says it in three places and `TreeDataSourceTests` asserts it
with a counting lister: moving the root is one directory read, filtering and
sorting are none, badges are computed off the listing entirely. A refresh that
walks is not a refresh this sidebar can have.

### A directory's own mtime already answers the question

Adding, removing, or renaming an entry moves the containing directory's
`st_mtime`. Writing new bytes into a file that is already there does not — and
does not change the listing either, so the two agree. One `stat(2)` per listed
directory therefore separates "nothing to do" from "re-read this one", and
nothing else needs touching.

## Decision

The sidebar polls. Every `TreeViewController.pollInterval` (2 s, with 0.5 s
timer tolerance) while it is on screen, `TreeDataSource.reconcile()` walks the
directories whose listings have **already been read**, `stat`s each one, and
re-lists only those whose own mtime has moved. Steady-state cost is one syscall
per expanded directory and no directory read at all.

A re-listed directory **adopts** the new entries rather than being rebuilt: every
name that is still present keeps its existing `TreeNode`. Identity is
load-bearing — `NSOutlineView` addresses rows by object and the controller keys
its expansion set by one — so keeping it is what stops a refresh from collapsing
folders and moving the selection while someone is reading. The reload afterwards
replays expansion and puts the selection back on the same node under
`isFollowing`, so a row that moved down because a file appeared above it does not
read as the reader choosing a different file and open a tab.

The timer runs only while the view is in a window that `occlusionState` reports
visible and the split view has not collapsed it, and fires once immediately on
appearing and on being uncovered.

Two deliberate gaps, both left to ⌘R and to the document watcher: a file whose
*bytes* changed under an unopened row keeps its stale task badge, and a
`.gitignore` edited in place does not re-filter the listing. Neither moves a row.

## Consequences

Files written by anything at all show up within about two seconds, with no
configuration and nothing for the reader to remember. The refresh scales with
what is expanded rather than with the tree, so a build churning through a
hundred thousand files under an unopened folder costs nothing, and a window left
open overnight is a few dozen syscalls every two seconds.

We accept a refresh that is up to two seconds late, and up to one interval later
still while a menu is open or a drag is in flight — the timer is on `.default`
mode on purpose, because a tree that reloaded out from under an open context menu
would be the worse bug.

We accept a correctness dependency on directory timestamps. On APFS they are
nanosecond-resolution and the gate is exact. On HFS+ and most network mounts they
round to the second, so a file written in the same second as the listing would
leave the stamp unchanged; a listing taken within a second of its own stamp is
therefore marked provisional and re-read once on the next poll. That costs one
extra listing per directory the reader expands, and it is the difference between
a refresh that works everywhere and one that works on the developer's laptop.

We accept that a directory that cannot be `stat`ed is treated as *not* stale
rather than as always stale — otherwise an unreadable folder would be re-listed
every two seconds for the life of the window. Its disappearance is still noticed,
by its parent, whose listing loses the row.

`TreeNode` grows two fields and three methods, and `TreeDataSource` grows
`reconcile()`. The laziness gate now has to be asserted for the poll as well as
for the listing, which `SidebarPollTests.quietPollReadsNothing` does.

## Alternatives considered

**FSEvents rooted at the sidebar root.** Instant instead of two seconds late, and
it reuses machinery the app already has. Rejected because FSEvents roots are
recursive: the cost is set by the size of the tree under the root, not by what is
expanded, and `~/src` is 608k files. It would also have to be torn down and
rebuilt on every root change, which is a gesture in this app (⌘↑, a crumb, a
double-clicked folder), and every event would still need the same
is-this-under-a-listed-directory filter the poll does.

**Re-list every listed directory on every tick, with no mtime gate.** Simpler by
about forty lines. Rejected on cost: each listing is a readdir plus `.gitignore`
matching over every entry, so twenty expanded directories is real work twice a
second, forever, to discover that nothing changed.

**Only refresh on window activation.** Cheap, and covers the common
edit-in-a-terminal case. Rejected because the reported case is a sidebar that is
already in front of you when the file arrives — mark sits beside the terminal
rather than behind it — and activation would never fire.

**A `mark refresh` CLI verb, so the writer tells the app.** Exact and free. It is
still worth having, but it cannot be the answer: it only helps files written by
something that knows about mark, and the whole complaint is about the ones that
do not.
