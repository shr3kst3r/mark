---
id: 2026-08-27-five-task-states
status: Accepted
supersedes: null
superseded-by: null
components: [core, render, cli, app]
ticket: null
date: 2026-08-27
---
# Recognise five one-byte task states, and draw every checkbox ourselves so the fifth one is possible

## Context

A task can only be open or done, so an item you have decided not to do has
nowhere to go. The two workarounds both cost something, measured against
`mark 0.2.0 (333513b)`:

- **`- [-] item`** is not a task at all. `pulldown-cmark`'s
  `scan_task_list_marker` accepts exactly `[ ]`, `[x]`, `[X]`, so the item is
  absent from `mark tasks`, from every count, and from the sidebar badge, and the
  bracket renders as literal prose.
- **`- [x] ~~item~~`** works today — `ENABLE_STRIKETHROUGH` is already on — but
  spells "cancelled" as "done". That is what makes the counts lie: a dropped
  item stays in the denominator for ever, so a list where you abandoned two of
  seven items reads `3/7` rather than `3/5`.

Four facts shaped the decision.

**The write primitive is already state-agnostic.** `tasks::toggle` changes exactly
the one byte between the brackets and nothing else; span re-verification,
`write_atomically`, the `flock`, and the stale-render check all sit on top of that
and do not care *which* byte. Every state anyone actually wants is one byte, so
widening the accepted set is cheap in the place that would have been expensive.

**Recognition does not require a textual scan, and this was the open question.**
`pulldown-cmark` has no option to widen the marker set, which makes forking it or
scanning the document for `[c]` look mandatory. Probed against 0.13.4 with mark's
own option set, it is not. An unrecognised marker arrives as three consecutive
`Text` events carrying exact byte spans at the head of a list `Item`:

```
"- [-] cancelled\n"
   0..16  Start(Item)
   2..3   Text("[")
   3..4   Text("-")     ← the byte to write, with its span
   4..5   Text("]")
   5..15  Text(" cancelled")
```

The middle event's span *is* the one-byte write target, so spans stay
parser-derived and authoritative exactly as they are today. Twenty adversarial
cases were probed and the structural rule holds for all of them: `- foo [-] bar`
(triple not at the head), `- *[-]* x` (`Start(Emphasis)` first), `prose [-] x`
(in a `Paragraph`, not an `Item`), `- [ab] x` (middle `Text` is two bytes),
`- [x](url)` and `- [-][ref]` (parsed as links — and not tasks today either),
`- [-]nospace` (rejected, matching GFM, which does not accept `- [x]nospace`
either), tabs, blockquotes, nested items, and `*`/`+`/ordered bullets.

**The C ABI cannot grow.** There are twelve `extern "C"` functions, and
`core/include/mark.h:170` states the position verbatim: *"ADR-1's surface is full
at twelve."* `2026-08-26-markdown-reference-window` declined to add one for the
same reason. So richer state has to travel through existing signatures.

**A half-done state cannot be drawn by a native checkbox.** `[/]` wants a
half-filled box, and the only way to get one from `<input type="checkbox">` is the
`indeterminate` IDL property, which is settable **only from JavaScript**.
`2026-08-24-rust-side-math-and-diagrams` forbids JavaScript in the emitted
document precisely so that `mark render --html` has the same capability as the
window, so an app-only `indeterminate` would reintroduce the GUI/CLI split that
ADR exists to prevent. Wanting five states therefore forces a second decision:
mark draws its own checkboxes. A three-state vocabulary (` `, `x`, `-`) was
considered first and would have avoided this entirely — cancelled renders fine as
an unticked native box with a struck label — but it pushes in-progress and blocked
out of the marker and into metadata, and the richer vocabulary was chosen
deliberately in the knowledge that it costs the native control.

The renumbering hazard was measured rather than assumed: recognising new markers
grows the task set, which renumbers the `(file, task-index)` identity
`2026-08-24-rust-core-swift-appkit-shell` fixes. Files matching any non-GFM marker
in this repository and in `~/notes`, the largest markdown tree on this machine
mark is routinely pointed at: **zero**.

## Decision

We recognise **five** task states, each exactly one byte between the brackets:

| Marker | State | Outstanding? | Terminal? |
|---|---|---|---|
| `[ ]` | open | yes | no |
| `[/]` | in progress | yes | no |
| `[x]`, `[X]` | done | no | yes |
| `[-]` | cancelled | no | yes |
| `[?]` | blocked | yes | no |

`Task.checked: bool` becomes `Task.state: State`, and `Counts` gains a per-state
total.

**A marker is recognised structurally, from the event stream, never by scanning
text.** GFM markers keep coming from `Event::TaskListMarker`. An extended marker
is recognised when an `Item`'s first three inline events are `Text("[")`,
`Text(c)` with `c` one byte from the extended set, and `Text("]")` with contiguous
spans, and the byte after `]` is whitespace or the item's inline content ends
there — the same trailing-whitespace rule GFM applies to `[x]`.

**Cancelled is the only state that leaves the badge's denominator.** Badges show
`outstanding / (total − cancelled)`, where outstanding is open + in-progress +
blocked. For a document containing only GFM markers every extended count is zero
and this reduces to `open / total`, so **no existing document's badge changes**.
A file whose every task is cancelled shows no badge, on the same grounds the
current code gives for suppressing `0/0`.

**`Task.checked` is retained in every JSON wire format** and defined as *the state
is terminal* — true for done **and** cancelled — so an existing script asking "is
this still outstanding?" keeps getting the right answer. A `state` string is added
beside it. `mark tasks --open` means "still outstanding", and a `--state` filter is
added for precision.

**We draw every checkbox ourselves.** The element stays
`<input type="checkbox" class="mk-task">` — `shell.js`'s patch verification
depends on that selector and on the element count — but it is styled with
`appearance: none` and painted from the existing `--mk-*` tokens, so all five
states are possible and consistent in one list:

```html
<input type="checkbox" class="mk-task" data-mk-idx="1"
       data-mk-start="14" data-mk-end="17" data-mk-state="cancelled"
       aria-label="cancelled">
```

`checked` is emitted for `done` only. In-progress paints a half-filled box,
blocked paints in `--mk-warning`, and **cancelled paints an emptied box with its
item struck through and dimmed** via `--mk-muted`. All of it is CSS; no
JavaScript enters the emitted page. An `aria-label` naming the state is emitted
because a five-state control announced as a two-state checkbox would otherwise
lie to VoiceOver.

**`shell.js` reports `state` and `renderedState` as strings** instead of
`checked`/`rendered` booleans, because with five states the browser can no longer
compute the requested state for us during pre-click activation.

**The ABI widens within its existing twelve functions, and the old encoding is a
prefix of the new one.** `mark_toggle`'s `action` gains `3` in-progress, `4`
cancelled and `5` blocked alongside `0` open, `1` done, `2` toggle. Its return
becomes the resulting state code — `0` open, `1` done, `2` in-progress, `3`
cancelled, `4` blocked — keeping `-1` for failure. An existing caller testing
`result == 1` still correctly reads "done" and reads every other state as
not-done. `mark_write_json` shares the decoder and inherits the new actions.

**Left-click behaviour does not change.** A click still toggles open↔done.
Reaching any other state is explicit: ⌥-click or the context menu in the app,
`mark check --state <name>` in the CLI. Toggling a marker that is in-progress,
blocked or cancelled means "tick this box", so it becomes done — which makes
toggle a one-way exit from those states and narrows the property suite's fourth
invariant: toggling twice restores the document **when the marker was open or
done**, and does not otherwise. No mapping out of the extended states can
preserve that invariant, and a click that silently does nothing is worse than one
that does not round-trip.

**`mark normalize` is the GFM escape hatch.** It rewrites `[-] text` to
`[x] ~~text~~` — struck and ticked, which is how GitHub should show a dropped
item — and `[/]`/`[?]` to `[ ]` carrying an `@doing` / `@blocked` tag, which makes
the degrade **lossless** and reversible. That tag spelling depends on
`2026-08-27-inline-task-metadata`; if that ADR is not accepted, `[/]` and `[?]`
degrade to a bare `[ ]` and `--gfm` is lossy for them. `normalize` **writes to
stdout by default**, with `--in-place` required to touch the file and `--check` to
report without writing.

## Consequences

**What becomes easier.** A dropped item has somewhere to go and the counts stop
lying about it; in-progress and blocked stop being a thing you track in your head.
The strikethrough is a consequence of the state rather than something you type, so
one action expresses the intent instead of two edits. `data-mk-state` plus a byte
allowlist means a sixth state is a CSS rule, not another contract negotiation.

**What becomes harder, and what we are accepting.**

- **Every existing document's checkboxes change appearance.** This is the largest
  cost in this ADR and it is unavoidable once five states are required: dropping
  the native macOS control is what buys `[/]`. Nobody asked for their existing
  checkboxes to be redrawn. The precedent is
  `2026-08-26-markdown-reference-window`, which accepted the same shape of cost
  for alert styling. Mitigation is limited to drawing them well and to matching
  the accent colour we already take from the theme.
- **We now own checkbox rendering, including the parts a browser gave us free** —
  hit area, focus ring, hover and active states, high-contrast mode, and both
  appearances of every one of the sixteen themes. A native control kept all of
  that correct without tests. This will produce visual bugs that a checkbox has
  never produced here before.
- **`[/]`, `[-]` and `[?]` are not GFM.** GitHub renders them as literal brackets
  in plain bullets. Obsidian and its ecosystem pass them through and style them,
  which is the larger ecosystem for personal notes, but the GitHub cost is real
  and `mark normalize` is the only mitigation.
- **Task indices renumber** for any document that gains an extended marker. This
  is the identity ADR-1 fixes, and an index held across the change — in a script,
  in an agent transcript, in an already-rendered page — becomes wrong. Measured as
  affecting zero existing files, which bounds the damage without eliminating it.
  It needs a note in the CLI documentation and a version bump.
- **`Task.checked` becomes a mild lie in its name** to stay honest in its answer.
  `checked == true` on a cancelled item is what keeps existing consumers correct,
  but a reader of the JSON who has not read this ADR will misread it. The `state`
  field beside it is the fix, and it must be documented at every wire format that
  carries it. Note also that `mark_toggle`'s integer return reads cancelled as
  not-done while the JSON `checked` field reads it as terminal — the two answer
  different questions, and only one in-repo caller reads the integer.
- **Five states is more vocabulary than most lists need,** and a reader of someone
  else's notes now has five glyphs to learn rather than two. We are accepting a
  literacy cost for expressiveness.
- **Cancelling a parent visually strikes its whole subtree**, because
  `text-decoration: line-through` propagates to descendants and CSS gives a child
  no way to cancel it. This matches intent — a dropped parent's subtasks are
  dropped — but a nested `[ ]` under a cancelled parent will render struck while
  still counting as outstanding. Deliberate, and named here so it is not read as a
  bug.
- **`mark normalize --in-place` is a new write path**, and therefore inherits
  `2026-08-25-flock-write-locking` in full: `write_atomically`, `LOCK_NB`, refuse
  rather than block.
- **Two stylesheets and two C headers must be edited in lockstep.**
  `core/src/render.rs` and `app/Resources/shell.css` are deliberately not
  generated from one source; `core/include/mark.h` and
  `app/Sources/CMarkCore/include/mark.h` are byte-identical copies and
  `core/tests/abi_c.rs` only compiles against the first, so editing one alone
  passes that test and breaks the app build.
- **The property suite's central assertion changes.**
  `core/tests/toggle_invariants.rs:129` asserts `after.checked == !before.checked`.
  One byte, unchanged length, and no byte outside the span all survive; the
  boolean relation does not, and invariant 4 narrows as described above.

Constraints this imposes on future work:

- **A task marker is always exactly one byte between brackets.** A state needing
  two bytes, or a sigil outside the brackets, is a superseding ADR — it breaks the
  write primitive, the property tests, and the "writes one byte to your file"
  promise the reference document makes in prose.
- **Markers are recognised from parser events, never by scanning the document for
  bracket patterns.** The one permitted lookahead is the single byte after `]`.
- **A task marker stays an `input.mk-task` element.** `shell.js`'s restamp refuses
  when the DOM's checkbox count differs from the source's task count, so a marker
  rendered as anything else breaks incremental patching silently.
- **No new C ABI function.** New capability widens an existing signature's integer
  domain or adds JSON fields. The surface stays at twelve.
- **`checked` is never removed from a JSON wire format,** and always means "the
  state is terminal". Removing it breaks every existing script.
- **The emitted page gains no JavaScript**, per
  `2026-08-24-rust-side-math-and-diagrams`. State styling is CSS, and
  `indeterminate` specifically is not to be reached for in the app as a shortcut —
  it would make the window and `mark render --html` disagree.
- **Only cancelled leaves the denominator.** A future state that is neither
  outstanding nor cancelled needs an explicit decision about the badge, not a
  default.

## Alternatives considered

- **Three states (` `, `x`, `-`) and nothing else.** Cancelled renders correctly
  as an unticked native box with a struck label, so this keeps the macOS control
  and changes *no* existing document's appearance — a materially cheaper ADR.
  Rejected: in-progress and blocked then have to live in metadata, and the richer
  marker vocabulary was wanted in its own right.
- **Five states, but `[/]` drawn with `indeterminate` from `shell.js`.** Keeps
  native checkboxes. Rejected: it works only in the app, so `mark render --html`
  would show in-progress as unticked, reintroducing exactly the GUI/CLI capability
  split `2026-08-24-rust-side-math-and-diagrams` exists to prevent.
- **The full Obsidian-ecosystem vocabulary (38 symbols).** Rejected: it is a
  theme, not a product. The transferable idea is symbol→status-type mapping, which
  the five states here already apply.
- **`- [x] ~~text~~` as the only spelling, with no new marker.** Pure GFM, renders
  everywhere, needs no parser work. Rejected: it cannot distinguish cancelled from
  done, which is the point, and it makes the write multi-byte.
- **Fork or patch `pulldown-cmark` to widen `scan_task_list_marker`.** Would give
  a real `TaskListMarker` event per state. Rejected as unnecessary once the event
  stream was probed — the spans are already there — and it would pin us to a fork
  of the parser this product's performance case rests on.
- **Scan lines textually for `^\s*[-*+]\s+\[(.)\]`.** Simple and obvious.
  Rejected: it re-derives byte offsets the parser already provides exactly, and it
  cannot tell a list item from prose or from a link without reimplementing block
  structure — which is how `prose [-] bracket` and `- [x](url)` would become false
  positives.
- **Encode the extended states as metadata (`- [x] thing @cancelled`).** Needs no
  parser change at all. Rejected: the *counts* need to know, and a state that
  changes the denominator belongs where the state is. It also still spells
  cancelled as done in the marker, which is the original problem.
- **Left-click cycles through all five states.** One gesture, no modifier.
  Rejected: it silently changes what a second click does to an existing document,
  and a five-stop cycle to reach one state is hostile.
- **Make `mark normalize --in-place` the default.** Fewer keystrokes for the
  publishing case. Rejected: it rewrites a user's document as the default
  behaviour of a verb whose name does not obviously write, which is exactly the
  shape of an accident.
