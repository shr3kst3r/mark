---
id: 2026-09-01-search-in-the-core
status: Proposed
supersedes: null
superseded-by: null
components: [core, cli, app, ipc]
date: 2026-09-01
ticket: null
---
# Move search into the core, and replace the ABI's function-count ceiling with the rule it was standing in for

## Context

There has been no way to search across files from the window. `mark grep` has
existed since M1 and answers the useful question — it reports the heading each
match sits under, so a hit reads `notes.md › Deploys › Rollback` rather than
`notes.md:412` — but nothing in `app/Sources/Mark/` calls it, and the sidebar's
filter is name-only and deliberately covers only rows already on screen
(`TreeDataSource.swift:614-629`). For a tool whose subject is a directory of
notes, "find that note" was missing.

The implementation lived in `cli/src/main.rs`: a `regex` build, a walk, and
`heading_path`/`line_bounds` as private functions. Two ways to give the window
the same feature:

**Reimplement in Swift.** `NSRegularExpression` is ICU. Rust's `regex` is not.
`\d`, `(?i)`, lookaround, and the meaning of `$` under multi-line all differ, so
`mark grep 'foo(?=bar)'` and the window's search box would disagree about the
same pattern in the same file. ADR-1 exists to stop exactly this: *"the CLI
cannot drift from the GUI because there is no second implementation to drift."*

**Move it into the core.** Then there is one dialect, one breadcrumb, one set of
line offsets — and the CLI gets smaller rather than larger.

The second is obviously right, and it runs into a constraint this branch has now
met twice. `2026-08-28-git-differences-by-running-git` said *"The C ABI ceiling
is thirteen and this ADR spends the thirteenth."*
`2026-09-01-document-images-over-a-scoped-scheme` spent a fourteenth on
`mark_links_json` and restated the rule with the number moved up one. Search is
a fifteenth, and no existing function's name covers "find text across a
directory", so the flag escape hatch does not apply either.

A rule that requires an architecture decision record every time a feature needs
the parser is not protecting anything. It is also not what ADR-1 actually asked
for. ADR-1's words are:

> **The C ABI stays small and string-shaped.** New capability is a new flat
> function, not a struct crossing the boundary. If the surface grows past
> roughly a dozen functions **or needs to pass structured data**, that is a
> signal to reconsider, via a superseding ADR rather than by smuggling a struct
> across.

The load-bearing half is *string-shaped*: the risk ADR-1 is guarding against is
a `#[repr(C)]` struct crossing the boundary, where a field added on one side and
not the other is silent memory corruption rather than a compile error. "Roughly
a dozen" was a proxy for that risk, and it has turned into the thing being
managed.

## Decision

**`core/src/search.rs` owns searching.** It holds the regex build, the walk, the
heading breadcrumb, and the line arithmetic. `cmd_grep` calls it and keeps only
its output formatting; `heading_path` and `line_bounds` are deleted from the CLI
along with their unit tests, which moved with them.

**`mark_search_json` is the fifteenth ABI function**, and it is the last one this
ADR counts.

**The numeric ceiling is retired.** It is replaced by the rule it was a proxy
for, which is the one a reviewer can actually apply:

> Every function on this boundary takes and returns NUL-terminated UTF-8 strings
> and C scalars, and nothing else. No struct crosses it, no pointer to one, no
> callback, no ownership that `mark_free` does not describe. A capability whose
> answer does not fit that shape is the signal to reconsider the design in a
> superseding ADR — not the number of functions that have.
>
> A new capability is a new function when no existing function's *name* covers
> the answer, and a flag on an existing one when it does. `mark_links_json` was
> a function because "tasks" does not cover "links"; `MARK_RENDER_STANDALONE`
> was a flag because "render this document to HTML" covers "as a whole page".

This does not loosen anything that was protecting the boundary. It removes a
count and keeps the invariant.

**The window searches on a background actor with a limit; the CLI passes none.**
A search runs on every keystroke, and a one-letter pattern over a real notes tree
has more hits than anyone will read.

## Consequences

**Easier.** The window and `mark grep` cannot disagree about a pattern, a
breadcrumb, or a line number, because there is one implementation. The CLI is
~90 lines smaller. `matches_in` takes an already-parsed `Document`, so the
window searching the file it is showing does not parse it twice. The next
capability that needs the parser does not need an ADR to reach the boundary.

**`regex` is now a core dependency.** It was already in the tree — `mark-cli`
has had it since M1 — so this costs the workspace nothing new, but the core's
dependency list is a thing this repository justifies one line at a time, and
this is the justification.

**A behaviour distinction had to be carried across, and was nearly lost.** The
CLI's `read_walked` errored for a file the *caller named* and skipped one found
by *walking* — so `mark grep pat broken.md` exits 2 and a walk past the same file
keeps its other results. The first move of this code dropped that and
`an_unreadable_named_file_exits_two_but_a_walk_skips_it` caught it. It is now
`SearchError::Read`, tested in the core as well as end-to-end.

**Unmeasured, and stated as such:** search over the user's real 608k-file tree.
`tree::markdown_files` bounds the walk at `DEFAULT_RECURSIVE_DEPTH`, and the
limit bounds the results, but nothing bounds the *files opened* — a search reads
every markdown file below the root, every time. On a notes directory that is
fine. On a home directory it is not, and the window's root is wherever the reader
pointed the sidebar.

Constraints this imposes on future work:

- **The ABI stays string-and-scalar-shaped.** As above. This replaces the count,
  it does not relax the shape.
- **No second regex engine.** Anything in Swift that wants to match a
  user-supplied pattern goes through the core, or it is a dialect fork.
- **A search that reads files must be cancellable and off the main actor.** The
  window's is; a future caller's has to be.
- **`heading_path` is the breadcrumb, everywhere.** `mark grep`, the window's
  search, and anything later that reports a position in a document use the same
  function, so "where is this?" has one answer.

**Deliberately not decided here:** an index. Everything above re-reads the tree
on every search, which is the right first version — it has no invalidation bugs,
and the tree it is aimed at is a notes directory. If that stops being fast
enough, the decision to keep a persistent index is a separate one with its own
staleness questions.

## Alternatives considered

- **`NSRegularExpression` in Swift.** Rejected: a second regex dialect, which is
  precisely the drift ADR-1's shared core exists to prevent.
- **Shell out to the bundled `mark-cli`.** Genuinely tempting — the binary ships
  in `Contents/MacOS`, a subprocess is cancellable and isolated, and it would
  have needed no ABI change or ADR at all. Rejected because it makes a process
  spawn part of a keystroke path, it cannot see an unsaved buffer, and "the app
  shells out to its own CLI" is an architecture nobody would choose on purpose —
  it would just be the shape that avoided this conversation.
- **Spend a flag on `mark_tree_json`.** It already walks a directory. Rejected:
  the answer shape is entirely different, and "tree" does not cover "search" by
  the naming rule above — which is the rule that would have had to be bent.
- **Keep the ceiling and bump it to fifteen.** What the previous two ADRs did.
  Rejected because it is the third time in one branch, and a rule that produces a
  decision record per feature is measuring the wrong thing.
- **Keep search in the CLI and have the window call `mark grep --json`.** The
  same objection as shelling out, plus it would make the window depend on the
  CLI being installed and on PATH rather than on the core it already links.
