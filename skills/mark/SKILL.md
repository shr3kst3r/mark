---
name: mark
description: "Drive the `mark` CLI — a fast markdown reader/editor for macOS with a scriptable, JSON-emitting headless half. Use it to get a document's heading tree with byte offsets (`mark toc`), search markdown reporting which heading each hit sits under (`mark grep`), enumerate and tick checkboxes with a one-byte in-place write (`mark tasks` / `mark check`), survey a notes tree with titles and task counts (`mark ls`), or emit a self-contained HTML document with inline MathML and Mermaid SVG and no JavaScript (`mark render --html`). Also drives the running mark.app over a Unix socket (open, tabs, goto, theme, sidebar). Trigger when the user mentions mark or mark.app, or asks to 'check off that task', 'what's left in my notes', 'outline this markdown', 'search my notes by section', 'render this markdown to HTML', or 'open this in mark'."
argument-hint: "toc <f> | tasks [path] --open | check <f> --item N --on | grep <pat> [path] | ls [dir] | render <f> --html | open <path>"
allowed-tools: [Bash]
---

# `mark` — markdown as a queryable, writable structure

`mark` is two Mach-Os in one bundle (ADR-1). This skill is about the second
one: `mark`, on `$PATH`, which parses markdown in Rust and answers in
milliseconds. Per-invocation cost is a design goal (~2.8 ms against a 2.3 ms
`exec` floor), so calling it in a loop is the intended use.

## Why reach for it instead of `cat` / `grep` / `sed`

Everything below is *structure* the text does not give you for free:

- **`mark toc`** — the heading tree with anchors, line numbers, and **byte
  offsets**, so you can slice a section out of a large file without re-parsing
  it yourself.
- **`mark grep`** — a regex search where every match carries the heading path
  it sits under (`"mark > The CLI"`). Answers "where in the document" and not
  just "which line".
- **`mark tasks` / `mark check`** — checkboxes as addressable items. `check`
  re-parses immediately before writing and changes **exactly one byte** (the
  character between the brackets) via temp-file-plus-rename. Never hand-edit a
  checkbox with `sed` when `mark check` is available.
- **`mark ls`** — a tree of markdown files with each one's title and `open/total`
  task counts. One call replaces a walk plus a parse per file.
- **`mark render --html`** — a self-contained page: both light and dark
  palettes, inline MathML for `$…$`, inline SVG for ```` ```mermaid ```` fences,
  no JavaScript, no network access.

If you only want the prose, read the file directly — that is cheaper.

## Agent rules — read first

- **Pass `--json` to everything that takes it.** Every command except `render`
  has it, and the plain forms are laid out for human eyes and are not a stable
  parsing target.
- **Two halves, and the split matters.** `render toc tasks check ls grep stats
  doctor theme --list/--show/--import` are answered **locally** with no app
  running. `open tab goto reload sidebar nav` and bare/named `mark theme` drive
  the GUI over `$TMPDIR/mark-$UID.sock` — and **`mark open` launches mark.app
  if it is not running.** Do not touch a socket command unless the user wants
  the window; stay in the local half otherwise.
- **Set `MARK_NO_LAUNCH=1`** when you want a socket command to fail with exit 4
  rather than start a GUI on the user's machine.
- **Task indices are 0-based, per file, in document order** — as reported by
  `mark tasks`. They renumber the moment a task is added or removed, so
  re-run `mark tasks` after anything else edits the file. Never carry an index
  across an edit you did not make with `mark check`.
- **`mark grep` exits 0 on no matches**, printing `[]`. Unlike `grep(1)`. Branch
  on the array being empty, never on `$?`.
- **`mark check` writes to the user's file.** It is one byte and it is atomic,
  but it is still a write — get intent before ticking anything, and never
  loop over `--toggle` to "clean up" tasks unasked.
- **Depth defaults differ.** `tasks` and `grep` recurse 64 levels; `ls`
  descends **1** (pass `--depth N` for more). All three honour `.gitignore`,
  skip hidden files, and treat `.md .markdown .mdown .mkd .mdx` as markdown.
- **`MARK_TRACE=1` writes to stderr only**, so it never corrupts `--json`. Use
  it to see per-stage timings.
- **Piped `render` output is plain text**; a TTY gets ANSI. Force either with
  `--plain` / `--ansi`, and set `COLUMNS` to control wrap width.

## Intent → command

| User intent | Command |
|---|---|
| "outline this document" | `mark toc <f> --json` |
| "what's left to do in my notes?" | `mark tasks <dir> --open --json` |
| "tick the third box in TODO.md" | `mark tasks TODO.md --json` to find the index, then `mark check TODO.md --item <n> --on --json` |
| "uncheck / flip it" | `mark check <f> --item <n> --off` / `--toggle` (toggle is the default) |
| "which of my notes have open tasks?" | `mark ls <dir> --depth 3 --json` — read `open`/`total` per row |
| "find X in my notes, with context" | `mark grep 'X' <dir> --json` (`-i` for case-insensitive) |
| "what section is this in?" | `mark grep '<needle>' <f> --json` — the `heading` field is the `>`-joined path |
| "turn this into a shareable HTML page" | `mark render <f> --html > out.html` |
| "show me the first screenful" | `mark render <f> --plain --prefix 20` |
| "read it styled in the terminal" | `mark render <f> --ansi` |
| "how big / how slow is this document?" | `mark stats <f> --json` |
| "what themes are there?" | `mark theme --list --json` (local — no app needed) |
| "convert my .tmTheme" | `mark theme --import <file>` → writes `~/.config/mark/themes/` |
| "is mark set up? paste this in a bug report" | `mark doctor --json` |
| "open this in mark" | `mark open <path> --json` (a **directory** roots the sidebar instead of opening a tab) |
| "open it without pulling me off what I'm reading" | `mark open <f> --tab --json` |
| "what's open?" | `mark tab list --json` |
| "switch to / close that tab" | `mark tab select <index\|path>` / `mark tab close [index\|path]` (bare `close` closes the selected tab) |
| "jump to the Install section" | `mark goto install --json` (leading `#` optional) |
| "re-read it from disk" | `mark reload --json` (refuses if the tab has unsaved changes) |
| "apply a theme to every tab" | `mark theme <name> --json` (shows the half you named, whatever macOS is in) |
| "go back to following light/dark" | `mark theme --system --json` |
| "where is the sidebar pointed?" | `mark sidebar --json` |
| "move the sidebar" | `mark nav <dir>` or `mark nav --up\|--back\|--forward` |

## Exit codes

Scripted contract, not advice. Note `0` for a search with no hits.

| Code | Meaning | Retry? |
|---|---|---|
| 0 | success | — |
| 1 | usage error, or a bad regex | no |
| 2 | file missing or unreadable | no |
| 3 | task index out of range, **or** the marker moved and the write was refused | no — re-run `mark tasks` |
| 4 | the app could not be reached (no socket, launch failed, no reply) | **yes** — the command never arrived |
| 5 | the app was reached and refused (no such anchor, no such tab, dirty tab) | no |
| 6 | another `mark` holds the document's `flock(2)` write lock | **yes**, once the holder exits |

**Exit 6 is the one code that describes another process.** A window with
unsaved edits holds an exclusive lock on that document for exactly as long as
it is dirty; nothing was written and the message names the holder's pid. A
*clean* tab holds nothing, so a document merely open in the app stays writable.
The lock is advisory — it stops one `mark` clobbering another and does not stop
`vim` or VS Code — and it is released the instant its holder exits, however it
exits, so there is nothing to clean up after a crash. It is unreliable on NFS
and SMB mounts, where a document is effectively unlocked.

## JSON shapes

So you can write the `jq` without a probe run.

```jsonc
// mark toc --json           → array
{"level":2, "text":"Install", "anchor":"install",
 "start":766, "end":777,      // byte offsets of the heading itself
 "line":18, "block":"f6eb14a7bfbe56df-0"}   // content-derived block id

// mark tasks --json         → array
{"path":"TODO.md", "index":0, "checked":false,
 "start":19, "end":22,        // byte span of the `[ ]` marker
 "line":4, "text":"first thing"}

// mark check --json         → one object, never the document
{"path":"TODO.md", "index":0, "checked":true, "text":"first thing",
 "offset":20}                 // the single byte the write changed

// mark ls --json            → array; directories appear too
{"path":"./notes/a.md", "name":"a.md", "is_dir":false, "depth":1,
 "title":"Notes", "open":1, "total":3}   // title/open/total absent on dirs
                                         // and on unreadable files

// mark grep --json          → array
{"path":"README.md", "line":151, "heading":"mark > The CLI",
 "anchor":"the-cli", "text":"**Writes take an `flock(2)`.** ..."}
// `heading` is "" and `anchor` absent for a match above the first heading

// mark stats --json         → one object
{"path":…, "bytes":70, "blocks":3, "code_blocks":0, "code_bytes":0,
 "math":0, "diagrams":0, "rich_failures":0, "headings":2,
 "tasks":{"open":1,"total":3},
 "parse_ms":…, "render_ms":…, "rerender_ms":…,
 "highlight_cold_ms":…, "highlight_cached_ms":…,
 "rich_cold_ms":…, "rich_cached_ms":…,
 "cache":{"hits":0,"misses":0,"entries":0,"evictions":0}, "rich_cache":{…}}

// mark doctor --json        → one object
{"core_version":"0.2.0", "cli_version":"0.2.0",
 "build_commit":"f63a7ca", "build_date":"2026-08-25", "protocol_version":1,
 "executable":…, "app_bundle":…, "syntect_asset_load_ms":0.59,
 "theme":"default-dark", "themes":17,
 "socket_path":"/var/…/mark-501.sock", "socket_path_bytes":62,
 "socket_path_limit":103, "socket_error":null,
 "app_running":true, "app_build":"0.2.0 (f63a7ca 2026-08-25)",
 "app_path":"/opt/homebrew/opt/mark/mark.app",
 "theme_dir":"~/.config/mark/themes"}
// `app_running` is probed, never launched — asking cannot make it true.
// `build_commit` identifies the build; the version alone does not, since every
// `--HEAD` install between two bumps reports the same one. `app_build` and
// `app_path` describe the app that answered, and are absent when none did —
// which is how you catch a CLI and an app from two different installs.
```

Socket commands print the app's reply verbatim:

```jsonc
mark tab list   → {"tabs":[{"index":0,"path":…,"title":…,"selected":true,
                            "resident":true,"openTasks":1,"totalTasks":3}]}
mark open <f>   → {"tab":{…},"tabs":2}       // a file became a tab
mark open <dir> → {"sidebar":{…},"tabs":2}   // a directory rooted the sidebar
mark tab select → {"tab":{…}}
mark tab close  → {"closed":{…},"tabs":1}
mark goto       → {"anchor":"install","tab":{…}}
mark reload     → {"blocks":12,"tab":{…}}    // blocks actually patched
mark theme <n>  → {"theme":{"name":…,"kind":"dark","light":…,"dark":…,
                            "paired":true,"appearance":"dark","showing":…,
                            "applied":3,"rerendered":1},"tabs":3}
mark sidebar    → {"sidebar":{"root":…,"breadcrumb":[…],"back":[…],
                              "forward":[…],"showsNonMarkdown":false,
                              "showsHidden":false,"sort":…,"filter":…}}
```

Key the branch on **which key came back** from `mark open`, not on stat-ing the
path yourself — the app is the one that decided, and a race would make you
print the wrong answer.

## Patterns

**Tick a task by its text, not by a guessed index.** The index is only valid
against the listing you just read.

```sh
idx=$(mark tasks TODO.md --json | jq -r '.[] | select(.text == "ship it") | .index')
[ -n "$idx" ] && mark check TODO.md --item "$idx" --on --json
```

**Slice one section out of a large document** using `toc`'s byte offsets — the
section runs from a heading's `start` to the `start` of the next heading at the
same or a shallower level.

```sh
mark toc big.md --json | jq -r --arg a install '
  [ .[] ] as $h
  | ($h | map(.anchor) | index($a)) as $i
  | $h[$i].level as $lv
  | { start: $h[$i].start,
      end: ( [ $h[($i+1):][] | select(.level <= $lv) ][0].start // null ) }'
# then: dd / tail -c +START | head -c LEN, or jq the numbers into your slicer
```

**Survey a notes tree for work in flight**, cheapest first:

```sh
mark ls ~/notes --depth 4 --json | jq -r '.[] | select((.open // 0) > 0)
  | "\(.open)/\(.total)\t\(.path)"'
```

**Retry the two retryable failures** and nothing else:

```sh
for _ in 1 2 3; do
  mark check notes.md --item 0 --on --json && break
  case $? in 4|6) sleep 1 ;; *) break ;; esac   # 4 = unreachable, 6 = locked
done
```

## Environment

| Variable | Effect |
|---|---|
| `MARK_TRACE=1` | per-stage timings on **stderr** (and OSLog in the app) |
| `MARK_NO_LAUNCH=1` | socket commands fail with exit 4 instead of launching the app |
| `TMPDIR` | where the socket lives; the full path must stay under 104 bytes (`sun_path` on macOS) or the app refuses to start |
| `MARK_APP` | an explicit `mark.app` to talk to and launch, instead of the one resolved from `$0` |
| `MARK_IPC_TIMEOUT_MS`, `MARK_IPC_LAUNCH_TIMEOUT_MS` | reply and cold-launch timeouts. Default 30000 and 15000 |
| `MARK_PROTOCOL_VERSION` | wire version to claim — for exercising the mismatch path |
| `MARK_THEME_DIR` | user themes, instead of `~/.config/mark/themes` |
| `MARK_SESSION_FILE`, `MARK_NO_SESSION=1` | where the app keeps its session, or don't keep one |
| `MARK_RESIDENT_TABS` | tabs keeping a live web view. Default 3, ~52 MB each |
| `COLUMNS` | wrap width for `render`, overriding what the terminal reports |

## Gotchas

- **`mark tab close 2` treats an all-digit argument as an index**, so a file
  literally named `2` needs `./2`. Same convention as `rm`.
- **`mark nav` needs exactly one destination** — a directory *or* one of
  `--up` / `--back` / `--forward`, never both and never neither.
- **`mark theme` is split across the two halves.** `--list`, `--show`, and
  `--import` are local; a bare `mark theme` or `mark theme <name>` needs the
  app and will launch it.
- **Naming a theme pins its half.** A theme is a light/dark pair, and
  `mark theme solarized-light` shows the light one even on a Mac in dark mode.
  The reply's `appearance` says `light`, `dark`, or `system`; `--system` is how
  you go back to following macOS.
- **`--prefix N` counts top-level blocks, not lines**, and applies to every
  format including `--plain`.
- **A directory walk swallows one bad file rather than the whole listing.** An
  unreadable or non-UTF-8 file found by walking is skipped (with a `MARK_TRACE`
  line); the same file *named directly* is exit 2.
- **Neither `mark open` form activates the app.** It launches with `open -g`, so
  focus is never stolen — and there is no command that raises the window.
- **Nothing is uploaded and no file contents are ever logged.** The app is not
  sandboxed and there is no telemetry; documents are read where they are.

`man mark` is the reference for all of the above. The reasoning and the
measurements live in `docs/adrs/`.
