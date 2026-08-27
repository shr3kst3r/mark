---
id: 2026-08-27-inline-task-metadata
status: Accepted
supersedes: null
superseded-by: null
components: [core, render, cli, app]
ticket: null
date: 2026-08-27
---
# Carry task metadata as TaskPaper-style `@tag` and `@key(value)` tokens in the item's own text, parsed in the core and never compared against a clock at render time

## Context

`2026-08-27-five-task-states` puts five states in the marker byte: open, in
progress, done, cancelled, blocked. That covers *where a task is*, and it stops
there deliberately, because everything else a task wants to say — due Friday,
urgent, belongs to a project, waiting on a named person — is richer than a single
byte can carry and does not belong in the byte that drives the arithmetic. This
ADR is where the rest goes.

The division of labour between the two is worth stating, because it is the thing a
later reader will want to argue with: **the marker carries what the counts depend
on, and metadata carries everything else.** A state that changes whether an item
is outstanding has to be in the marker, because the badge arithmetic reads it. A
due date does not.

The constraint that matters is that it must stay ordinary markdown. mark's value
is that the file is the database; a sidecar index, a frontmatter block, or an HTML
comment would all work and would all make the notes worse to read and worse to
grep. So the metadata has to live in the item's visible text and survive every
other markdown tool as plain prose.

Three grammars are in real-world use and were compared directly:

| Grammar | Example | Assessment |
|---|---|---|
| Obsidian Tasks emoji | `📅 2026-09-01 ⏫ 🔁 every week` | Widely deployed and unambiguous, but unwritable without a picker and hostile on a CLI, which is half of what mark is. |
| todo.txt | `due:2026-09-01 +proj @ctx (A)` | Battle-tested. But `key:value` collides visually with markdown links and times (`14:30`), and it needs three sigils for three concepts. |
| TaskPaper | `@due(2026-09-01) @work` | One sigil covers both a bare tag and a keyed value. ASCII, typeable, greppable, and `@` needs no shell quoting — unlike `#`, which does. |

TaskPaper's grammar wins on the CLI axis, which is the axis mark is unusual on:
`mark tasks -r ~/notes --tag @work --overdue` is a thing no GUI notes app offers
an agent, and it should not require quoting.

Two hazards were identified before choosing. `@` is common in prose — an email
address in a task (`email bob@example.com`) would otherwise yield a spurious
`@example.com` tag — and both `@` and `!` occur inside inline code spans.
`core/src/tasks.rs`'s `label` builder already flattens `Event::Code` into the
label text, so a naive scan would read metadata out of `` `@foo` ``.

One corpus constraint bites directly. `2026-08-24-rust-side-math-and-diagrams`
requires that renderers stay pure functions of their source so their output can be
memoized, and `mark render --html` is meant to be reproducible. Colouring an
overdue chip red at render time would make the output a function of source *and*
today's date, breaking both.

## Decision

**Metadata is a set of whitespace-delimited tokens in the task item's label**, in
one grammar plus one shorthand:

- `@name` — a bare tag. `@work`, `@home`, `@waiting-on-legal`.
- `@name(value)` — a keyed tag. Three names are **known** and typed:
  `@due(YYYY-MM-DD)`, `@start(YYYY-MM-DD)`, `@done(YYYY-MM-DD)`. Every other name
  is carried through as an untyped tag with a value.
- `!`, `!!`, `!!!` — priority, low to high, mapped to 1/2/3 with 0 for absent.

**No tag ever affects a count.** `2026-08-27-five-task-states` owns the
arithmetic; a tag is a filter and a chip, never a state. `@doing` and `@blocked`
are reserved names with one narrow job — they are what `mark normalize --gfm`
writes when it degrades `[/]` and `[?]`, and what a future `--extended` would read
back — and even they do not make an item in-progress. The marker does.

**A token is only recognised when preceded by whitespace or the start of the
label, and terminated by whitespace or the end of it.** That is what makes
`bob@example.com` an email address rather than a tag, and `ship it!!!` prose
rather than a priority.

**Metadata inside an inline code span is not metadata.** Recognition runs over the
inline events that build the label and skips `Event::Code`, so `` `@due(x)` ``
documents the syntax instead of using it.

**Dates are ISO 8601 `YYYY-MM-DD` and nothing else.** A `@due(friday)` is a valid
untyped tag with the value `friday`; it is not a date, is not sorted as one, and
is not an error.

**`Task` gains `label`, `tags`, `due`, `start`, `done` and `priority`, and
`text` is unchanged.** `text` remains the full flattened item text, so every
existing consumer keeps working; `label` is `text` with the recognised metadata
tokens removed and whitespace collapsed, which is what a human-facing list should
show. Both travel in `mark_tasks_json` as new fields — no new C ABI function, per
`2026-08-24-rust-core-swift-appkit-shell`'s full-at-twelve surface.

**The renderer never reads a clock.** Metadata renders as neutral chips carrying
their own data — `<span class="mk-tag" data-mk-due="2026-09-01">` — so
`mark render --html` stays a pure function of its source and stays reproducible.
**Overdue and due-today colouring happens in the app**, in the already-injected
`shell.js`, which is not JavaScript in the emitted document and so does not touch
`2026-08-24-rust-side-math-and-diagrams`' constraint.

**Date comparison lives in the query path, where a clock is explicit.**
`mark tasks` gains `--tag`, `--priority`, `--due-before`, `--due-after`,
`--overdue`, `--no-due` and `--sort due|priority|state|index`, with
`--today YYYY-MM-DD` overriding "now" so the behaviour is testable without
freezing a clock. `--due-before` and friends accept a date, `today`, or a `+Nd`
offset.

**`mark check --stamp` appends `@done(YYYY-MM-DD)`** when a task becomes done,
and is **opt-in**, because it is the first write in the product that is not one
byte. It inserts at the end of the label, at an offset taken from the label's
last inline event span — not from a textual search — and goes through
`write_atomically`, inheriting `2026-08-25-flock-write-locking` in full.

## Consequences

**What becomes easier.** A task can say what it needs to without spending marker
bytes on it, and the tag vocabulary is the user's rather than ours: `@work`,
`@waiting-on-legal`, `@errand` all work on day one with no release, which is what
keeps `2026-08-27-five-task-states` at five rather than growing a state per
workflow. `mark tasks -r ~/notes --overdue --tag @work --sort due` makes a
cross-tree agenda answerable in milliseconds with no app running, which is the
thing mark can do that a GUI notes app cannot. And `mark normalize --gfm` becomes
lossless, because `[/]` and `[?]` can degrade to `[ ] … @doing` / `@blocked`
rather than being flattened away. Because it is all plain text in the item, every
other markdown tool shows it unharmed.

**What becomes harder, and what we are accepting.**

- **The item's text now has syntax in it.** A reader who has not seen this ADR
  sees `@due(2026-09-01)` and cannot tell whether mark is interpreting it. That is
  the inherent cost of a plain-text format and the reason the chips render
  distinctly rather than as prose.
- **False positives remain possible.** The whitespace rule kills the common cases,
  but `Wow !!!` in a task becomes priority 3, and a task mentioning a Twitter
  handle as a standalone word gains a tag. We are accepting this: it is quiet,
  harmless, and the alternative is a heavier sigil nobody wants to type.
- **`mark tasks`' human output changes shape** for documents that use metadata,
  since it shows `label` plus chips rather than raw `text`. Documents without
  metadata are byte-identical.
- **`--stamp` breaks the one-byte promise, by design.** The markdown reference
  states "clicking a checkbox writes one byte to your file" as prose, and that
  stays true — `--stamp` is a CLI flag, not the click path. If stamping is ever
  wired to a click, that sentence and this consequence both change.
- **`priority` is a second grammar** alongside `@`. One sigil would have been
  cleaner; `!!!` is kept because it is what people actually type. Named here so
  the inconsistency is a choice on record rather than an oversight.
- **Overdue styling exists in the app and not in `mark render --html`.** The same
  document is coloured in a window and neutral on stdout. This is deliberate —
  reproducible output is worth more than a red chip in a pipe — and
  `mark tasks --overdue` is the CLI's answer.

Constraints this imposes on future work:

- **Metadata recognition runs over inline events and skips `Event::Code`.** A
  regex over the raw line would reintroduce the code-span bug and lose the
  offsets `--stamp` needs.
- **A token is whitespace-delimited on both sides.** Any relaxation makes email
  addresses and prose into metadata.
- **No renderer may read a clock.** Anything time-dependent is either a chip
  attribute styled by the app, or a query-path filter with an explicit
  `--today`. This keeps `2026-08-24-rust-side-math-and-diagrams`' memoization
  claim true.
- **`Task.text` keeps its current meaning** — full flattened text, metadata
  included. `label` is the stripped one. Swapping them would silently change every
  existing consumer.
- **New known keys are additive and typed in the core**, not configurable. A
  user-configurable key set would make one person's notes unreadable by another
  person's mark.
- **No new C ABI function.** Metadata travels as fields in `mark_tasks_json`.
- **No tag participates in `Counts`.** If a workflow state needs to change the
  badge, it belongs in the marker byte under
  `2026-08-27-five-task-states`, not here. Two sources of truth for "is this
  outstanding?" is the failure mode this constraint exists to prevent.

## Alternatives considered

- **Obsidian Tasks' emoji fields (📅 ⏳ 🔁 ⏫).** The widest-deployed convention,
  and unambiguous — no false positives are possible. Rejected on typeability: it
  needs an emoji picker or an autocomplete plugin, and mark's CLI half is meant to
  be driven from a keyboard and from scripts.
- **todo.txt's `key:value` plus `+project` and `@context`.** Battle-tested and
  ASCII. Rejected: three sigils for three concepts where one will do, and
  `key:value` is visually noisy next to markdown links and ambiguous with times
  (`14:30`).
- **Dataview-style inline fields (`[due:: 2026-09-01]`).** Already used in the
  Obsidian ecosystem. Rejected: square brackets in a task item are exactly what
  the marker grammar uses, and `[due:: …]` at the head of an item would collide
  with marker recognition.
- **`#tag` instead of `@tag`.** More familiar from social software and from
  Obsidian's own tags. Rejected: `#` requires quoting in every shell invocation,
  which is a tax on the interface this feature exists to serve.
- **`@p1`/`@p2`/`@p3` for priority, keeping a single sigil.** Genuinely more
  consistent, and it was close. Rejected because `!!!` is what people type and
  the consistency buys nothing a reader needs.
- **YAML frontmatter or a sidecar index for task metadata.** Structured,
  unambiguous, no false positives. Rejected: it moves the truth out of the line
  the task is on, which breaks grep, breaks every other markdown tool, and breaks
  the property that makes this product worth using.
- **Colouring overdue chips at render time.** Simpler, and the obvious first
  instinct. Rejected: it makes the renderer impure, invalidates the memoization
  `2026-08-24-rust-side-math-and-diagrams` depends on, and makes
  `mark render --html` output vary by the day you ran it.
- **Recurrence (`@every(week)` spawning the next instance on check).** A natural
  extension of this grammar and genuinely useful. Deliberately out of scope: it is
  a multi-line write with its own conflict rules, and it deserves its own ADR
  rather than arriving as a consequence of this one.
