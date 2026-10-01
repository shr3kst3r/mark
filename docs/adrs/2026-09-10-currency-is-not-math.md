---
id: 2026-09-10-currency-is-not-math
status: Proposed
supersedes: null
superseded-by: null
components: [core, render, cli, app]
ticket: null
date: 2026-09-10
---
# Demote an inline math span to literal text when both of its delimiters are followed by a digit

## Context

ADR-5 turned on `pulldown-cmark`'s `ENABLE_MATH` so `$x^2$` reaches
`pulldown-latex`. The risk it created was obvious at the time and is recorded in
`parse.rs`: prose about money must not become mathematics. Two tests were
written to hold that line, `a_dollar_sign_in_prose_is_still_a_dollar_sign` and
`dollar_signs_in_prose_are_left_alone`, and the module doc states the conclusion
outright — "`$5 and $10` and `a $ b $ c` both stay literal text, so enabling it
does not turn currency in prose into mathematics."

That conclusion is wrong, and both tests happen to assert on the one shape that
survives.

`pulldown-cmark` opens inline math at a `$` followed by a non-space and closes
it at the next `$` preceded by a non-space. Whether a sentence about money
survives therefore depends entirely on the character sitting immediately in
front of its second dollar sign. A space saves it. An approximation sign, a
range hyphen, or a currency prefix does not.

| Prose | Today |
|---|---|
| `costs $5 or $10.` | text |
| `costs $5, up from $10.` | text |
| `spend $5 then $10 then $15.` | text |
| `coffee $4.50 vs latte ~$7.` | math |
| `a range of $5-$10 today.` | math |
| `US$5 and US$10.` | math |

The failure is not subtle when it fires. A note containing

```markdown
Coffee is $4.50 vs a fancy latte at ~$7
```

renders in the preview as one `<math display="inline">` element holding
a row of `<mi>` nodes, which reads on screen as

```
Coffee is 4.50vsa fancy latte at 7
```

Both dollar signs are consumed as delimiters, the words between them are
typeset as italic single-letter identifiers, and the amounts are pulled apart.
Nothing is marked as failed, because nothing did fail: `pulldown-latex` was
handed `4.50 vs a fancy latte at ~` and typeset it correctly. ADR-5's
`<merror>` check cannot help here, and neither can any renderer-side guard. The
misreading is complete before the LaTeX layer is reached.

The terminal is unaffected in substance. `mark render --ansi` keeps every
character of the source and only italicises the span, and `mark grep` reports
the line verbatim. This is a GUI-and-HTML defect, so it is invisible to the
CLI-driven tests that cover most of the render path.

Three properties of this codebase rule out the obvious fixes. Byte offsets are
load-bearing everywhere downstream: `data-mk-start` and `data-mk-end`, block
hashes, ADR-2's incremental patching, ADR-1's one-byte checkbox writes and
`render_range` all index the file as it sits on disk, so escaping the source
before parsing is not available. `ENABLE_MATH` is a single switch with no
inline-only half, so turning it off to protect prose would take display math
with it. And `pulldown-cmark` exposes no hook into its inline scanner, so the
decision cannot be pushed upstream into the parse itself.

## Decision

We post-process `pulldown-cmark`'s output in `Document::parse`. An
`Event::InlineMath` whose opening `$` is immediately followed by an ASCII digit
**and** whose closing `$` is immediately followed by an ASCII digit becomes a
single `Event::Text` carrying its own source slice, delimiters included.

That pair of conditions is the signature of two currency amounts and is not the
signature of one expression. A real expression's closing delimiter is followed
by prose, punctuation, or the end of the line, never by a digit that belongs to
a second number. `$2x$` stays math. `$5-$10` does not.

The demotion happens before block segmentation, so every consumer — the HTML
renderer, the ANSI renderer, `plain_text`, headings and their anchors, task
labels, the word count — sees one `Text` event and none of them needs to know
this rule exists. The rewritten event keeps the original event's byte range
unchanged.

Display math is untouched. `$$…$$` is a different event, its delimiters are
unambiguous, and no one writes a price with two dollar signs.

## Consequences

**Easier.** The six shapes in the table above all render as what they say.
Prose that mentions prices stops being corrupted by a feature it never asked
for. The rule is four lines of predicate over a byte range and costs one slice comparison per inline math
event, so it is free against ADR-2's budget. Because the demoted event carries
the source spelling, round-tripping through the editor is byte-identical, and
the anchor of a heading containing a price no longer depends on whether a math
parser liked it.

**Harder, and we are accepting it.**

- **Inline markup inside a demoted span stops being parsed.** In
  `$4.50 vs a **fancy** latte at ~$7` the emphasis was already swallowed by
  the math scan, and restoring the span as literal text means the asterisks now
  render visibly rather than as bold. This is a strictly smaller wrong than the
  status quo, and it is the reason the alternative below was considered, but it
  is still wrong. A document that hits it looks like an authoring mistake rather
  than a tool bug, which is the trade being made.
- **The heuristic can be fooled, in one direction only.** Genuine inline math
  that both opens on a digit and is followed immediately by another digit —
  `$2x$3` — will be demoted to text. We could not construct a realistic
  document containing that shape, and the failure is visible source rather than
  silent garbling.
- **Currency prose that does not end on a digit is still broken.**
  `$5 and change~$` has no second amount, so the rule does not fire. The shape
  is degenerate and no test asserts on it.
- **We now own a divergence from `pulldown-cmark`'s inline grammar**, which
  means a `pulldown-cmark` upgrade can change what our documents mean without
  changing our code. The predicate is one function with its own tests, so the
  divergence is at least located in one place.

Constraints this imposes on future work:

- **The demotion stays in `Document::parse`**, ahead of block segmentation. Any
  consumer that special-cases currency for itself is a bug, because the CLI, the
  app, and the anchors would then disagree about what a document says.
- **The demoted event keeps the source range it was given.** Rewriting the event
  is allowed; rewriting the offsets is not, because ADR-1 and ADR-2 both index
  the file through them.
- **The predicate is tested on shapes that break, not only on shapes that
  pass.** That is the specific mistake this ADR exists to correct, and the two
  tests that made it are still in the tree as the examples to not repeat.

**Reversibility:** trivial. One function and one call site, no persisted state,
no schema. Deleting it restores the previous behaviour exactly.

## Alternatives considered

- **Re-parse the demoted span's interior as inline markdown and splice the
  events back in, with ranges offset into the parent.** The only option that
  keeps `**real**` bold. Rejected for now: it means synthesising an event
  subrange whose offsets must line up with the parent document exactly, in the
  one part of this codebase where an off-by-one silently corrupts a checkbox
  write. The benefit is emphasis inside a sentence that already contains two
  prices, which is not worth that risk. Worth revisiting if it turns out to be
  common.
- **Require the span to contain whitespace as well.** A tighter rule, and it
  would protect `$2x$3` from demotion. Rejected because it drops `$5-$10`, the
  most common broken shape in the set, whose span interior is just `5-`.
- **Match a fuller currency grammar — thousands separators, decimals, a `M`,
  `bn` or `k` suffix, an optional `~` or `-` — rather than "digit on both
  sides".** Rejected as a worse rule wearing more work: every symbol it adds is
  a locale it gets wrong, and the two-digit test already separates the shapes we
  found.
- **Turn `ENABLE_MATH` off and require `$$…$$` for all math.** Fixes prose
  completely and costs inline math, which ADR-5 shipped deliberately and which
  is the notation every other markdown tool uses. Rejected.
- **Escape `$` in the source before parsing.** Rejected outright: it changes
  every byte offset after the first price, and ADR-1's checkbox contract,
  ADR-2's patching, and `render_range` all read those offsets against the file
  on disk.
- **Fix it upstream in `pulldown-cmark`.** The right long-term home, and worth
  filing regardless. Rejected as the fix here because the behaviour is arguably
  correct per its own grammar, we do not control the release, and documents are
  being misrendered now.
