# mark

A fast native markdown viewer and editor for macOS, with a headless CLI that is
fast enough to call in a loop.

Three panes in one window — a directory sidebar, a rendered preview, and an
optional source editor. Tabs. Sixteen themes that follow the system appearance
instantly. Math and Mermaid diagrams rendered ahead of time in Rust, so a
document ships no JavaScript. Click a checkbox and it writes one byte to your
file; edit in the third pane and autosave writes 800 ms after you stop typing.
The `mark` CLI does everything the window does, and drives the running app over
a Unix socket.

**Status: complete.** All ten milestones are implemented and tested —
382 Rust tests, 292 Swift tests, 43 integration checks, and committed
performance gates.

## Install

```sh
brew tap shr3kst3r/mark https://github.com/shr3kst3r/mark
brew install --HEAD shr3kst3r/mark/mark
```

Updating needs the full name and `--fetch-HEAD`. `mark` on its own is a
different formula in homebrew-core, and a head-only formula has no version
number for Homebrew to compare, so the short command reports nothing to do:

```sh
brew update && brew upgrade --fetch-HEAD shr3kst3r/mark/mark
```

The formula builds from source, which is the point: locally built code is never
quarantined, so Gatekeeper is never consulted — no Developer ID, no
notarization, no "damaged and can't be opened". It installs the app, puts `mark`
on your PATH, and installs the man page and zsh/bash/fish completions.

Or build it yourself:

```sh
just build          # cargo + swift, then assemble target/mark.app
just install-cli    # symlink mark-cli into $(brew --prefix)/bin/mark
just run README.md  # build and open the app on a file
```

`packaging/README.md` covers all three paths, including the cask, and what each
one costs.

Needs Rust **1.95 or newer** (the MSRV, pinned in `Cargo.toml`; it comes from
`merman`, the Mermaid renderer) and the Xcode command line tools — not a full
Xcode.

## The app

**One window, three panes.** The sidebar is a lazy directory tree: it never
walks ahead of what you have expanded, honours `.gitignore`, and computes per-file
`3/7` open-task badges in the background rather than on the walk. ⌘↑ moves the
root to the parent, ⌘[ and ⌘] go back and forward through where you have been,
and the breadcrumb bar's components are clickable. The tree follows the front
document: switch tabs and the sidebar expands to that file and selects it,
without moving the root or clearing your filter. ⌘⇧O is the deliberate version
that does move the root, for a file outside it; ⌘⌥R reveals it in Finder. Drop a
folder on the window to root there.

**Tabs**, in a hand-built bar with per-tab open-task badges, drag reordering, and
the accessibility roles VoiceOver needs. Only the three most recently used tabs
keep a live web view; the rest are dehydrated and rehydrate in ~4.7 ms when you
switch back. Switching between resident tabs is a show/hide and costs nothing
measurable. A tab with unsaved changes is never dehydrated.

> **What tabs cost, since the number here was wrong once.** Every `WKWebView`
> gets its own WebContent process at ~52 MB, so the budget is a formula rather
> than a constant: **~100 MB baseline + ~52 MB × resident tabs**, which is
> ~264 MB at the default of 3 resident. `MARK_RESIDENT_TABS` changes the limit.
> An earlier design claimed ~1.2 MB per tab and a 110 MB ceiling for 24 of them;
> that came from a benchmark that summed RSS by walking the app's process
> subtree, and WebKit's content processes are children of launchd, so it counted
> none of them. See `docs/adrs/2026-08-24-tab-residency-and-memory-model.md` —
> it is the clearest example in this repo of a measurement that reproduced
> perfectly and measured the wrong thing.

**Documents render progressively.** The core emits only the blocks that fit the
viewport, the shell paints those, and the rest is appended behind the paint by a
`setTimeout` pump. On the 1 MB benchmark corpus that is **5.9 ms to visible
against 145 ms for naive whole-document injection**. Block ids are content
derived, so inserting a paragraph does not renumber what is below it, and an
external save patches only the blocks that changed — already-laid-out diagrams
and math survive untouched.

**Math and diagrams.** `$x^2$` and `$$…$$` become inline MathML; ```` ```mermaid ````
fences become inline SVG. Both are rendered in Rust at render time and memoized,
so `mark render --html` produces exactly what the window shows, with no
JavaScript and no network access. A broken expression gets a styled badge with
the parser's message and keeps its source selectable, rather than disappearing.

**Themes.** Sixteen curated themes, eight light/dark pairs, derived from base16
palettes so the chrome and the code colours come from the same source and cannot
clash. Both appearances are injected as CSS custom properties, so switching macOS
between light and dark re-colours everything with zero IPC, zero re-render, and
no flash. Your own themes go in `~/.config/mark/themes/*.toml` and are picked up
without a rebuild. `mark theme --list` names them all.

**Editing.** ⌥⌘E opens the third pane on the selected document. It is a real
`NSTextView`, so undo, Find & Replace, spellcheck, text substitution, and
accessibility are the system's rather than ours. The preview updates as you
type, one block at a time. Autosave writes 800 ms after you stop, atomically,
through any symlink to the real file. If something else writes the file while
you have unsaved changes, autosave pauses and you are asked — keep mine, take
theirs, or show me the diff — and nothing is written until you answer. The pane
starts hidden: a document opens read-only until you ask to edit it, and the app
remembers that you asked.

**Checkboxes.** Clicking one in the preview writes one byte to the file — the
character between the brackets — via temp-file-plus-rename. The document is
re-parsed immediately before the write, and if the target span no longer holds a
task marker the write is refused rather than guessed. While a tab is dirty the
click applies to the buffer instead, so the preview and the file can never
disagree about which task you clicked.

**Session.** Tabs, order, selection, scroll offsets, sidebar root and history,
theme, and whether the editor was open all come back on relaunch, from our own
JSON file rather than `NSWindowRestoration`.

## The CLI

Answered locally, in milliseconds, with no app running — which is the situation a
script or an agent is usually in:

| Command | What it does |
|---|---|
| `mark render <f> [--html\|--ansi\|--plain] [--prefix N] [--theme NAME]` | A styled document on stdout. `--html` is self-contained: both palettes, inline MathML and SVG, no JavaScript. |
| `mark toc <f> [--json]` | The heading tree, with anchors, byte offsets, and block ids. |
| `mark tasks [path] [--open] [--json]` | Every task: path, index, state, text, byte span. |
| `mark check <f> --item N [--on\|--off\|--toggle] [--json]` | Flips one checkbox by changing exactly one byte. Refuses, with exit 6, if another `mark` holds the file — see below. |
| `mark ls [dir] [--json] [--depth N] [--all]` | Markdown files with titles and open/total task counts. |
| `mark grep <pat> [path] [--json] [-i]` | Regex search, reporting the heading each match sits under. |
| `mark stats <f> [--json]` | Per-stage timings and counters. |
| `mark doctor [--json]` | Environment report to paste into a bug report: socket path and length, whether the app is running, the resolved `.app`, theme dir, asset load time. |
| `mark theme --list\|--show <name>\|--import <file> [--json]` | List, inspect, or convert a `.tmTheme` or base16 scheme. |

These drive the running app over `$TMPDIR/mark-$UID.sock`, launching it if there
is none, and never stealing focus:

| Command | What it does |
|---|---|
| `mark open <path> [--tab] [--json]` | A file opens in a tab; a **directory** roots the sidebar there. The reply says which. `--tab` opens in the background. |
| `mark tab list [--json]` | Every open tab: index, title, open/total tasks, whether it holds a web view. |
| `mark tab select\|close <index\|path> [--json]` | Move or close a tab. `close` with no argument closes the selected one. |
| `mark goto <anchor> [--json]` | Scrolls the front document to a heading. Exits non-zero if there is no such anchor. |
| `mark reload [--json]` | Re-reads the front document from disk. Refuses when the tab has unsaved changes. |
| `mark sidebar [--json]` | The sidebar's root, breadcrumb, history depth, and what it is showing. |
| `mark nav <dir>\|--up\|--back\|--forward [--json]` | Moves the sidebar's root. The CLI half of ⌘↑, ⌘[, ⌘]. |
| `mark theme <name> [--json]` | Applies a theme to every open tab, dehydrated ones included. |

Exit codes: `0` success, `1` usage, `2` unreadable or missing file, `3` task
index out of range, `4` the app could not be reached, `5` the app refused the
command, `6` another `mark` holds the document's write lock. 4 and 5 are the
useful split for a caller: 4 is worth retrying, 5 is not. `MARK_TRACE=1` writes
per-stage timings to stderr, never to stdout, so it cannot corrupt `--json`.

**Writes take an `flock(2)`.** A window with unsaved edits holds an exclusive
lock on that document for exactly as long as it is dirty, and a CLI write to it
is refused with exit 6 and the holder's pid rather than clobbering it. A clean
tab holds nothing, so a document you merely have open stays writable. The lock
is never waited on, and it is released the instant its holder exits — there is
no lock file and nothing to clean up after a crash. It is also *advisory*: it
stops one `mark` from clobbering another and does not stop `vim` or VS Code,
which is why saving over a dirty document from an external editor still raises
the keep-mine / take-theirs prompt.

`man mark` documents all of it, including every environment variable. Shell
completions for zsh, bash, and fish are in `packaging/completions/` and inside
the app bundle at `Contents/Resources/completions/`.

## For agents

The CLI half exists to be called in a loop, and `skills/mark/SKILL.md` is what
makes that pay off: the `--json` shape of every command, the six exit codes and
which two are worth retrying, and which half of the CLI needs the app running.
It is a [Claude Code](https://claude.com/claude-code) skill, and it works in
any agent runtime that reads `~/.claude/skills` or `~/.agents/skills`.

`spg.toml` installs it:

```sh
spg install     # symlink the skill into ~/.claude/skills and ~/.agents/skills
```

[`spg`](https://github.com/shr3kst3r/spg) is a per-project command publisher,
but this `spg.toml` publishes no commands — only the two skill symlinks. The dev
loop is the `just` recipes below, which already work from a clone, and `mark`
itself is a symlink into an installed `mark.app`: a `~/bin` wrapper running this
checkout from source would shadow it silently, including in the agent sessions
the skill is for. `spg.toml` is unrelated to packaging either way —
`packaging/mark.rb` still owns installing the app and putting `mark` on your
PATH.

## Building

```sh
just setup     # asdf install, then pre-commit install
just check     # fmt + clippy + tests + release build + swift tests + ADR index
just build     # target/mark.app, both Mach-Os
just test      # cargo test --workspace
just bench     # the committed performance gates
just integration   # two real processes over a real socket
just doctor    # toolchain versions, asdf-resolved vs actually-resolved
just           # every recipe
```

`just check` is what CI runs, so local and CI cannot drift.

`just` and `pre-commit` are pinned in `.tool-versions`. Rust deliberately is
not: Cargo's `rust-version` owns the floor, and an asdf `rust` plugin would
shadow the Homebrew toolchain every measurement was taken against.

## Layout

```
core/    the document core: parsing, block identity, highlighting, tasks, tree,
         math, diagrams, themes, diffing
  src/lib.rs        the C ABI — the only pub extern surface, 12 functions (ADR-1)
cli/     clap dispatch, terminal rendering, and the socket client
app/     the Swift/AppKit shell
  Sources/Mark/         the window, sidebar, tabs, document view, IPC, editor
  Sources/Mark/MarkCore.swift  the wrapper over the C ABI
  Resources/            shell.html, shell.js, shell.css — no third-party JS
  Sources/MarkBench/    the performance gates, run in a real window
docs/adrs/          the decision records; accepted ones are immutable
packaging/          the formula, the cask, the man page, shell completions
scripts/            bundle assembly, integration checks, corpus generator
bench/              fixtures and the class-vs-inline highlighting pair
skills/mark/        the agent skill: how to drive the CLI, and its JSON shapes
```

Two toolchains, and neither can produce a runnable app alone:
`scripts/assemble-bundle.sh` is where that cost lives. `mark.app` ships two
Mach-O executables — the AppKit app and the CLI — and is 34 MB.

## Why it is like this

The decisions, with their measurements, are in `docs/adrs/`. Six are active and
one is superseded; `docs/adrs/INDEX.md` is generated from their frontmatter. The
short version:

- The core is **Rust** because `pulldown-cmark` gives every event a byte range,
  and mapping a clicked checkbox back to an exact byte span is what the product
  is built around. Parsing speed is *not* the reason — parsing is ~1% of the
  budget. The shell is **Swift/AppKit** because native tabs, `NSOutlineView`,
  system appearance, and `NSTextView`'s undo and spellcheck are not worth
  reimplementing. They meet at a hand-written C ABI of 12 flat, string-shaped
  functions.
- The CLI talks to the app over a **Unix socket**, with `mark://` registered for
  cold launch and Finder. Every other mechanism on macOS either raises a consent
  prompt, requires a Login Item, or drops messages.
- Documents **render progressively**, with content-derived block ids and memoized
  highlighting, because injection strategy is worth 123 ms on a 1 MB document and
  the parser is worth 2.
- Math and Mermaid render **in Rust**, not in JavaScript, so the CLI and the GUI
  cannot diverge and a rendered document has no scripts in it. It costs 10 MB of
  binary and the 1.95 MSRV, and that trade is recorded.
- **The buffer is the source of truth while a tab is dirty**, and the file when it
  is clean. Every feature that touches document bytes has to ask which.

There is **no telemetry of any kind**. This tool reads private notes.

## License

MIT. See `LICENSE`.
