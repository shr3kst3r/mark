---
id: 2026-08-28-git-differences-by-running-git
status: Accepted
supersedes: null
superseded-by: null
components: [core, cli, app, render, sidebar]
ticket: null
date: 2026-08-28
---
# Learn what changed by running `git --no-optional-locks` as a child process, and show it as rendered markdown rather than as patch text

## Context

The request is *"if the file is in a git repo, I want to be able to see the
differences, and I want the directory view to show the changed lines."*

Today `mark` knows one thing about git: `core/src/tree.rs` uses `.git` as the
stop condition when collecting `.gitignore` matchers, and skips any entry named
`.git` because *"it is never a document."* There is no repository object, no
index read, no HEAD. `core/build.rs` does run `git`, but at build time, to stamp
`MARK_BUILD_COMMIT`. The shipping app spawns no child process at all.

### One thing we already have, and it decides the display

ADR-2 (`2026-08-24-progressive-document-rendering`) built a block-hash diff so a
file-watcher re-render could patch only the blocks that moved. `core/src/diff.rs`
is 1,062 lines of it and `mark_diff_json` already exposes it: given two versions
of a document it returns `keep`/`delete`/`insert`/`replace` ops addressed by the
`data-blk` ids the page carries, with rendered HTML for every block it
introduces. A markdown reader showing *rendered* differences is therefore
mostly reuse. A unified-diff text pane would reuse none of it, and would put a
patch view inside a tool whose entire premise is that you read markdown
rendered.

Two gaps in that reuse, found by reading the module: `Op::Delete` carries no
HTML, so an edit script alone cannot show removed content in place; and a block
diff cannot put a bar against line 41, which an editor gutter needs.

### Which mechanism, measured

Three candidates: run the `git` binary, link libgit2 through `git2`, or link
gitoxide through `gix`. Measured on this machine (macOS, APFS, git 2.55.0,
libgit2 1.9.7) against a 1,709-file repository with 12 modified files and 2
untracked ones — 12–15 runs, medians:

| | stale index stat-data | fresh index stat-data |
|---|---|---|
| `git --no-optional-locks diff --numstat HEAD` | 31.6 ms | **11.6 ms** |
| `git --no-optional-locks status --porcelain=v2 -uall` | 42.9 ms | 26.6 ms |
| `git status --porcelain=v2 -uall` (writes the index) | 46.0 ms | 23.7 ms |
| libgit2 `diff_tree_to_workdir_with_index` + `stats()` | 76.0 ms | 31.2 ms |

libgit2 is **2.4× slower than `git` for the same answer**, in both columns. It
wins exactly one thing, and wins it enormously: reading a blob out of HEAD is
**0.43 ms** against 7.0 ms for `git cat-file blob HEAD:<path>`. That is the base
content the diff view and the gutter need — but HEAD's bytes do not change while
someone types, so one cache keyed on the HEAD oid pays the 7 ms once and the
advantage evaporates.

`cargo add git2` also linked `/opt/homebrew/opt/libgit2/lib/libgit2.1.9.dylib`.
Shipping that needs `vendored-libgit2` — cmake and a C build in the toolchain,
against an ADR-1 that explicitly rejected dynamic linking for `@rpath` and
per-dylib notarization. `gix` measured **141 crates**, next to the 166 ADR-1
rejected `wry` over.

### Two mechanics that are not obvious and cost real time to discover

**`git status` writes the user's repository.** Verified by watching
`.git/index`'s mtime: a plain `git status` rewrites the index to save refreshed
stat data; `git --no-optional-locks status` does not. A markdown *reader*
polling on a timer would be taking `index.lock` and racing the user's own git
commands every couple of seconds. `--no-optional-locks` is therefore not a
tuning flag here, it is a correctness requirement.

**Not writing the index costs 2.7× on the read.** `git diff --numstat` does not
refresh the index either way, so on a repository whose stat data is stale it
re-hashes the worktree on **every** invocation: 95 ms before a
`git update-index --refresh`, 11 ms after. The two facts pull against each
other, and there is no flag that gives both. We take the read penalty rather
than write to somebody's repository.

**`--numstat` reports nothing for an untracked file** — no blob, no diff. Adding
untracked paths is a second call (`ls-files --others --exclude-standard`,
22 ms), and their line counts have to be counted by us.

### The boundary is the expensive part

ADR-1 (`2026-08-24-rust-core-swift-appkit-shell`) caps the C ABI at *"roughly a
dozen"* flat functions. `core/src/lib.rs` holds exactly twelve, and its module
docs record M7's and M8's decisions to spend a *flag* rather than a slot, then
conclude: *"The surface is now full. Anything further is a superseding ADR."*

Part of what git needs does fit as a flag, following exactly that precedent:
`mark_diff_json` already takes `(old_source, new_source, theme)`, which is
precisely the shape both a line diff and a merged diff document need, so they
are a `flags` parameter on it rather than two new entry points. What has no
honest home is *"what does git say about this path, and what are HEAD's bytes
for it"* — that is a different question from "list this directory" or "diff
these two strings", and hiding it behind `mark_tree_json` would be the smuggling
ADR-1 forbids. It is also the wrong shape for that function twice over: the
listing is deliberately called with `with_stats: false` so it never opens a file,
and it is per directory where a git query is per repository
(`2026-08-28-git-badges-ride-the-sidebar-poll`).

So this decision spends one function and stops. Whether that is inside ADR-1's
"roughly a dozen" or past it is a judgment call, and it is recorded here rather
than resolved silently: ADR-1's own wording is deliberately approximate, while
`lib.rs`'s "now full" is one milestone's self-discipline in code rather than
corpus. Thirteen is the last one either way.

## Decision

We answer git questions by running the `git` binary as a child process, always
with `--no-optional-locks`, from a new `core/src/git.rs`. The core owns it, so
the CLI and the app get the same answers from the same implementation and
neither can drift.

Concretely:

- **`git` is resolved explicitly, and `/usr/bin/git` only after
  `xcode-select -p` succeeds.** `/usr/bin/git` is an `xcrun` shim that puts up a
  modal Command Line Tools install dialog when they are absent, and a
  Finder-launched app inherits launchd's minimal `PATH`, so it is the most
  likely `git` the app finds. No git, or no CLT, means every query answers "not
  a repository" and the feature is invisible. It never blocks and never prompts.
- **Every invocation has a timeout and runs off the main thread.** A repository
  on a stalled mount, or a contended `index.lock`, degrades to "unknown" rather
  than to a beachball.
- **The base is `HEAD`, and staged and unstaged changes are one number.** A
  reader wants "how far is this from what is committed". An untracked file
  counts every line as added.
- **We do not refresh the index**, accepting the measured 31.6 ms rather than
  11.6 ms on a repository nobody has run `git status` in.
- **The core carries two diff granularities, and they are not interchangeable.**
  `core/src/diff.rs`'s block diff drives the rendered display; a new line diff
  drives the editor gutter, `mark diff`, and the added-line count for untracked
  files. Neither is derived from the other.
- **Differences are shown as rendered markdown, not as patch text.** The core
  emits a *merged diff document*: `mk-blk` divs in document order, each classed
  unchanged / added / removed / changed, with removed blocks rendered from
  HEAD's own parse so deleted content is visible in place. The shell injects it
  through the machinery it already has. Tints come from the existing base16
  `success` / `error` / `muted` document slots, so **no new theme slot is
  introduced** and `codeStamp` is unaffected.
- **The boundary grows by exactly one function, and then stops.** One new
  `mark_git_json(path, flags)` answers "what does git say about this path"
  (repository-scoped, which is the unit the query actually has) and "give me
  HEAD's bytes for it". `mark_diff_json` gains a `flags` parameter for line hunks
  and for the merged diff document; `mark_tree_json` is untouched. Thirteen
  functions is the ceiling this ADR sets, and it is the last increment: anything
  further supersedes this. The CLI needs no ABI at all — it links the core's
  Rust API directly.
- **HEAD's bytes are cached per `(repo, path, HEAD oid)`**, because reading them
  costs 7 ms and they cannot change while the oid does not.

## Consequences

A reader can see what changed in a note without leaving the tool, in the form
the tool is for — rendered — and an agent can ask the same question over
`mark diff` and get the same answer, because there is one implementation. The
rendered display is largely existing code, and the theme work is zero.

**`mark.app` now forks child processes.** That is a new property of the shipping
app: previously only `mark-bench` spawned anything. It is permitted — the app is
not sandboxed — but it means process-spawn failures, timeouts, zombie reaping
and `PATH` resolution are now the app's problem, and a hostile or broken `git`
on `PATH` is now in the app's trust boundary.

**We depend on an external binary we do not ship.** No `git`, no Command Line
Tools, or a `git` too old for the flags used, and the feature silently does not
exist. We prefer that to a dependency we would have to vendor, but it does mean
"works on my machine" has a new axis.

**We accept the slower read.** 31.6 ms rather than 11.6 ms per repository on
stale stat data, permanently, in exchange for never writing to the user's
repository. Refreshing the index would be 2.7× faster and is deliberately
refused.

**Two diff implementations now live in the core**, at different granularities,
and a reader of `core/src/diff.rs` has to know which one they are in. The block
diff's existing property test (*applying the script to the old block list yields
the new block list*) does not cover the line diff, which needs its own.

**Untracked line counts are ours to compute**, from a file read git will not do
for us — so "untracked" is the one status whose cost is per file rather than per
repository.

Constraints this imposes on future work:

- **Every `git` invocation goes through `core/src/git.rs`.** No second call site
  in Swift, and none in the CLI. That is what keeps the app and the CLI
  agreeing, and it is the same rule ADR-1 states for the core generally.
- **`--no-optional-locks` on every invocation, without exception.** `mark` reads
  repositories; it does not write them. A future call site that drops the flag
  makes a viewer a writer.
- **No git call on the main thread, and every one has a timeout.**
- **`/usr/bin/git` is never invoked without a successful `xcode-select -p`
  first.** The failure mode is a modal dialog at a reader who opened a folder.
- **The C ABI ceiling is thirteen and this ADR spends the thirteenth.** The next
  capability that wants to cross the boundary spends a flag or supersedes this.
- **`.git` is resolved through `git rev-parse --git-path`, never by joining onto
  `.git/`.** It is a *file* in a worktree, and this repository is developed in
  worktrees — `core/build.rs:174` learned this already.
- **No new theme slot for diff colours.** They come from `success`, `error`, and
  `muted`, so a theme change stays a CSS swap with no re-render.
- **Binary and non-UTF-8 files are not diffed.** `--numstat` prints `-` `-` for
  them; that is a status, not a number, and must never be parsed as one.

**Deliberately not decided here:** how often the sidebar asks, and what that
does to its cost model. That is
`2026-08-28-git-badges-ride-the-sidebar-poll`.

**Unmeasured, and stated as such:** every number above is one repository of
1,709 files on a local APFS volume. A repository on a network mount, a
submodule-heavy tree, and a sparse checkout are all untested, and the timeout
exists because of that rather than in spite of it.

## Alternatives considered

- **`git2` / libgit2.** No subprocess, no `PATH` problem, no CLT dialog, no hang
  on spawn, and only 7 crates — genuinely attractive, and measured rather than
  dismissed. Rejected on two numbers: 2.4× slower than `git` for the answer we
  actually want (76.0 vs 31.6 ms stale, 31.2 vs 11.6 ms fresh), and it linked a
  Homebrew dylib, so shipping means `vendored-libgit2` — cmake and a C build —
  against an ADR-1 that rejected dynamic linking over `@rpath` and notarization.
  Its one big win, a 0.43 ms blob read against 7.0 ms, is cached away. Worth
  revisiting if we ever need per-keystroke repository queries, which we do not.
- **`gix` / gitoxide.** Pure Rust, no C, no dylib. Rejected on 141 crates,
  next to the 166 ADR-1 rejected `wry` over, for a feature that is one badge and
  one view.
- **Reading `.git` ourselves.** Zero dependencies and total control. Rejected
  outright: index v2/v3/v4, split index, the untracked cache, `.gitattributes`,
  `core.autocrlf`, sparse checkouts, submodules and worktrees are a
  reimplementation of git with silent wrongness as its failure mode, in a tool
  whose job is reading markdown.
- **`git status --porcelain=v2 -uall` as the single query.** One process for
  statuses *and* untracked files, and it self-heals the index. Rejected because
  it gives no line counts — the thing that was actually asked for — and because
  the self-healing *is* a write to the user's repository; with
  `--no-optional-locks` it is 42.9 ms against `--numstat`'s 31.6 ms and still
  has no numbers in it.
- **Refreshing the index ourselves to get the 11.6 ms path.** 2.7× faster and
  one extra call. Rejected: a reader that mutates the repository it is reading
  will eventually lose a race with the user's own `git`, and "mark broke my
  commit" is not a bug we are willing to be able to have.
- **Shelling out from Swift for the app, and from Rust for the CLI.** No ABI
  growth at all, which is the one thing that made it tempting. Rejected because
  it is exactly the drift ADR-1 exists to prevent: *"the CLI cannot drift from
  the GUI because there is no second implementation to drift."* Repo discovery,
  worktree handling, `--no-optional-locks`, the CLT precondition and the timeout
  policy would all exist twice.
- **A unified-diff text pane.** Familiar, and the cheapest thing to build. Rejected
  as the wrong product: it reuses none of ADR-2's block machinery, and a tool
  whose premise is reading markdown rendered should not answer "what changed?"
  with a patch. Kept in mind as the fallback if the merged diff document turns
  out to read badly on real documents.
- **Change marks only, with no removed content.** Cheaper still — the existing
  edit script already carries everything needed. Rejected because a diff that
  cannot show what was deleted does not answer "see the differences"; it answers
  "which parts are new".
