---
id: 2026-08-28-git-badges-ride-the-sidebar-poll
status: Accepted
supersedes: null
superseded-by: null
components: [app, sidebar]
ticket: null
date: 2026-08-28
---
# Refresh git badges on the sidebar's existing poll, one query per repository that owns a listed row, gated on that repository's own `index` and `HEAD`

## Context

`2026-08-27-sidebar-polls-listed-directories` states the sidebar's cost
invariant as plainly as an ADR can:

> **The sidebar's whole design is "read nothing you are not showing"** … the
> refresh scales with what is expanded rather than with the tree, so a build
> churning through a hundred thousand files under an unopened folder costs
> nothing.

`TreeDataSourceTests` asserts it with a counting lister, and
`SidebarPollTests.quietPollReadsNothing` asserts it for the poll specifically.
Steady state today is one `stat(2)` per expanded directory every 2 seconds, and
no directory read at all.

A `+12 −3` badge cannot be had on those terms, and pretending otherwise would be
the quiet invariant break that ADR is written to prevent.
`2026-08-28-git-differences-by-running-git` measured why: the cheapest correct
query is `git --no-optional-locks diff --numstat HEAD`, which reads the whole
index and stats every tracked file in the repository regardless of what is
expanded. It costs 11.6 ms with fresh stat data and 31.6 ms without, on a
1,709-file repository.

The saving grace is that it is **one call per repository, not one per file** —
above git's 5.9 ms process floor, the work over 1,709 files is about 3.7 ms. So
where the task badge's cost model is 0.34 ms × N files (research §2.8), this
one is ~30 ms × N *repositories*. That inversion is what the design has to
exploit.

### The number that rules out the naive version

Newly measured under `~/src`, which research §2.8 put at 608,597
files: **33 repositories at depth ≤ 2, and 99 `.git` entries at depth ≤ 4** once
worktrees are counted. A sidebar rooted there with a few folders expanded can
span dozens of repositories. Refreshing all of them on the 2-second tick is
33 × ~30 ms ≈ **1 second of work every 2 seconds** — half a core, forever, in a
window somebody left open. Even the optimistic 11.6 ms figure is a 19% duty
cycle.

So the query has to be gated on something cheap, and the gate has to be as
nearly free as the `stat` gate the poll already uses.

### The gate exists, and the same ADR already licensed its inaccuracy

A repository's `index` and `HEAD` move on commit, staging, checkout, branch
switch, merge, rebase, stash, and file add/remove/rename. Two `stat(2)` calls
per repository therefore separate "nothing to do" from "re-ask git", at the same
cost per repository that the existing poll pays per directory.

What they miss is an in-place edit to a tracked file: writing new bytes into a
file that is already tracked moves neither `HEAD` nor the index. That is
**exactly** the gap `2026-08-27-sidebar-polls-listed-directories` already
identified and accepted for its own feature:

> Two deliberate gaps, both left to ⌘R and to the document watcher: a file whose
> *bytes* changed under an unopened row keeps its stale task badge …

Adopting the same contract for git badges adds no new class of staleness to the
product — it reuses one the reader has already been taught, and the document
watcher already closes it for the file that is actually open.

One trap: finding a repository's git directory costs a `git rev-parse
--git-path` process, measured at 5.9 ms. Paying that on every tick would defeat
the gate it is meant to enable. It has to be resolved once per repository and
cached for the window's lifetime — which is sound, because a repository's git
directory does not move under a live window.

### Untracked files are the one per-file cost

The accepted product shape counts every line of an untracked file as added. `git
diff --numstat` reports nothing for such a file (no blob to compare against),
and the separate `ls-files --others --exclude-standard` call that finds them
(22.5 ms) reports paths and no counts. Their line counts are therefore ours to
compute, from a file read — the one part of this feature whose cost is per file
rather than per repository.

That is affordable only if it is bounded by the screen, which is the same
constraint `TaskBadgeService` already solves: request by visible row, LIFO stack,
`.utility` queue, concurrency 1, dictionary-lookup reads.

### One badge slot, two badges

`TreeCellView` has a single right-aligned `badgeLabel`, and the accepted product
shape puts changed lines *and* the task count in the row —
`weekly.md   +12 −3   3/7`. The row is narrow and the name already truncates in
the middle.

## Decision

Git badges ride the sidebar's existing `TreeDataSource.reconcile()` tick. On
each pass, for every repository that owns at least one **already-listed** row:

1. `stat(2)` that repository's `index` and `HEAD`, at paths resolved once and
   cached per repository for the window's lifetime.
2. Re-ask git only for repositories whose stamps have moved, on a `.utility`
   queue, never on the main thread.
3. Adopt the answer into a per-repository cache keyed by path, and redraw only
   the rows whose numbers changed.

A repository that cannot be `stat`ed, or whose query fails or times out, is
treated as **unchanged** rather than as always-stale — otherwise an unreadable
or hung repository would be re-queried every two seconds for the life of the
window. This mirrors the existing poll's ruling for unreadable directories.

Untracked line counts are computed per **visible row**, on the badge queue, and
only for paths git has already reported as untracked. A file with unsaved bytes
in a tab is counted from the buffer rather than from disk, through the same
`dirtySource` hook `TaskBadgeService` uses — a badge must not describe a version
the reader is not looking at.

The row draws changed lines first, then the task badge:
`weekly.md   +12 −3   3/7`. Both are dimmed when they are zero, the name keeps
truncating in the middle, and the two numbers are one accessibility phrase
rather than two elements, on the same grounds
`TreeCellView.accessibilityLabel(for:badge:)` already gives: `+12 −3` read on
its own is meaningless.

We accept the staleness contract
`2026-08-27-sidebar-polls-listed-directories` already set: an in-place edit to a
tracked file under an unopened row keeps a stale badge until ⌘R, until the
document watcher reports it, or until something moves the index.

## Consequences

Changed lines appear in the directory view within about two seconds of anything
git notices, at a steady-state cost of two extra `stat` calls per repository per
tick — the same order as the poll's existing per-directory `stat`, and flat
whether the repository holds 200 files or 200,000.

**The sidebar's cost invariant is now weaker, and this ADR is where that is
recorded.** "Read nothing you are not showing" no longer holds strictly: when a
repository's index moves, we read the whole of that repository's index and stat
every tracked file in it, including files under folders nobody expanded. The
honest statement of the new bound is *expansion-bounded for the gate,
repository-bounded for the answer, and paid only when the repository actually
changed*. A `cargo build` under an unopened folder still costs nothing, because
it moves no index; a `git checkout` in a repository with one listed row costs one
query.

**A repository being worked on is the expensive case.** Commit, stage, stash and
rebase all move the index, so a reader with mark open beside an active
repository pays ~30 ms per repository per affected tick. Bounded by human
gesture rate rather than by the timer, which is why the gate is on the index
rather than on a schedule.

**Rows are busier.** Two badges in a narrow row means names truncate sooner,
and a file that is both changed and full of tasks shows `+12 −3   3/7` in space
that was designed for `3/7`.

**Untracked files cost a file read each**, bounded by the visible rows, and the
`ls-files` call that finds them is 22.5 ms on top of the `--numstat` call. A
directory of a hundred new notes is the worst case for this feature, and it is
also the case where the badges matter most.

Constraints this imposes on future work:

- **No git query outside the gate.** A query on a schedule, on scroll, or on
  redraw is a regression, not an optimization.
- **The gate's cost stays syscall-shaped.** Anything that puts a process in the
  per-tick path — including `git rev-parse` to find a git directory — belongs in
  the once-per-repository cache, not in `reconcile()`.
- **A failing or hung repository is quiet, and stays quiet.** Never retried on
  the next tick.
- **The laziness assertions extend to git.** `SidebarPollTests` must gain the
  git equivalent of `quietPollReadsNothing`: a quiet poll over a repository
  whose index has not moved runs **no** git process. Without that test this
  decision regresses silently, which is the whole reason the existing one is
  asserted rather than described.
- **A dirty buffer is the truth for its own file**, for the git badge as much as
  for the task badge.

**Deliberately unresolved:** a repository whose `index` is on a network mount
makes even the `stat` gate slow. The timeout in
`2026-08-28-git-differences-by-running-git` covers the query; nothing covers the
`stat`. We are recording it rather than solving it, because every measurement
here is local-APFS and a fix aimed at an unmeasured case would be a guess.

## Alternatives considered

- **FSEvents on each repository's `.git`.** Instant instead of two seconds late,
  and the app already owns an FSEvents wrapper. Rejected for the same reason the
  sidebar poll rejected it: FSEvents roots are recursive and would have to be
  torn down and rebuilt on every root change, which is a routine gesture here
  (⌘↑, a crumb, a double-clicked folder) — and it would need one stream per
  repository, up to 33 under `~/src`, to replace two `stat` calls that
  already cost nothing.
- **Re-ask git on every tick with no gate.** About forty lines simpler.
  Rejected on the measurement: 33 repositories × ~30 ms is a second of work
  every two seconds, forever.
- **⌘R only.** Free, and honest about being manual. Rejected because it
  reintroduces exactly the complaint that produced the sidebar poll in the first
  place — being told the sidebar can be stale — one release after fixing it.
- **Refresh on window activation.** Cheap, and covers "I committed in the
  terminal, then came back". Rejected on the same grounds the poll ADR rejected
  it: mark sits *beside* the terminal rather than behind it, so activation never
  fires.
- **One query per listed directory, path-scoped with a pathspec.** Would restore
  the strict "bounded by what is expanded" invariant. Rejected on cost: it is
  one process per directory rather than per repository, and path-scoping saves
  almost nothing — 7.1 ms scoped against 9.6 ms unscoped on a clean 1,709-file
  repository, because the index read dominates. Twenty expanded directories in
  one repository would be twenty processes to replace one.
- **Watching each tracked file's mtime to close the in-place-edit gap.** Exact.
  Rejected because it is a walk of every tracked file in the repository per
  tick, which is strictly worse than the query it is trying to avoid.
- **Fold the git badge into `mark_tree_json`'s listing path.** Tempting: one
  call, already on a background hop. Rejected because the listing is called with
  `with_stats: false` precisely so it never opens a file, and it is per
  directory, so it would multiply the per-repository query by the number of
  expanded directories.
- **A status dot instead of numbers**, keeping the numeric slot for tasks.
  Compact and never crowded. Rejected because it does not answer "how much
  changed", which is what was asked for.
