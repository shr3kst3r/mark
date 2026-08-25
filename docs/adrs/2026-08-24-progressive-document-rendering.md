---
id: 2026-08-24-progressive-document-rendering
status: Accepted
supersedes: null
superseded-by: null
components: [render, core, app]
ticket: null
date: 2026-08-24
---
# Process only the visible prefix of a document before first paint, and finish the rest behind it

## Context

"Very fast" is the product's headline requirement, so we measured where the time
on a 1 MB document actually goes. The intuitive answer — markdown parsing — is
wrong by an order of magnitude.

| Stage | 1 MB document |
|---|---|
| Markdown parse (`pulldown-cmark`) | 2.0 ms |
| Syntax highlighting (`syntect`, 400 code blocks) | **98.2 ms** |
| HTML assembly | ~3 ms |
| WebKit `innerHTML` + layout | **124.0 ms** |

Parsing is ~1% of the budget. The two real costs are highlighting and handing
HTML to WebKit, and both scale with how much of the document we process before
showing anything.

Measured injection strategies (1 MB document, best of 4 warm runs, reading only
the first block's geometry so that skipped subtrees are legitimately allowed to
stay skipped):

| Strategy | Time to lay out visible content |
|---|---|
| Plain `innerHTML` | 124 ms |
| `content-visibility: auto` on every top-level block | **225 ms** |
| `content-visibility: auto`, full layout forced | 183 ms |
| **First 40 blocks, then append the remaining 3,731** | **1 ms** + 140 ms background |

`content-visibility: auto` is the obvious optimization and it is a **measured
1.8× pessimization** here. `CSS.supports()` confirms WebKit implements it;
establishing 3,771 containment scopes simply costs more than the layout it skips
at this block size. This is recorded because the next person will reach for it,
find it plausible, and need the number to be talked out of it. (Our first
measurement of this was invalid — it read `document.body.scrollHeight`, which
forces layout of everything and defeats the feature entirely. Re-measured
correctly, the conclusion held.)

Highlighting responds to the same treatment, and to memoization. A content-hash
cache keyed on `(language, code)` turns 98.15 ms into **0.074 ms** — a ~1,300×
saving on the re-render path, which matters because a file-watcher re-render
changes almost nothing. `syntect` asset loading is a non-issue at 0.33–1.4 ms for
75 syntaxes and 7 themes; binary cost is 617 KB → 1.79 MB.

Combining both levers:

| | Naive | Progressive |
|---|---|---|
| Time to visible, 1 MB cold | ~227 ms | **~16 ms** |

Three WebKit-specific facts constrain the implementation, each verified rather
than assumed, and each of which would otherwise be discovered the hard way:

- **`requestIdleCallback` does not exist in `WKWebView`** (probed directly:
  `content-visibility` ✓, `contain-intrinsic-size` ✓, `requestIdleCallback` ✗).
  It silently broke a first version of our benchmark harness.
- **`overflow-anchor` is unsupported in WebKit.** The CSS feature that would
  preserve scroll position across a re-render is unavailable to us.
- **`document.body.scrollTop` returns 0 in `WKWebView`.** Use
  `window.pageYOffset`.

## Decision

We render documents progressively. On open, the core parses the whole document
(cheap), then highlights and emits HTML for only the first ~40 top-level blocks;
the shell injects that prefix and paints. The remaining blocks are highlighted and
appended behind the paint, driven by a `setTimeout` pump.

Highlighted code is memoized in the core, keyed on a content hash of
`(language, code)`, so re-renders re-highlight only blocks whose bytes changed.

Every top-level block element carries a stable identity in the emitted HTML:

```html
<div class="mk-blk" data-blk="<content-hash>-<ordinal>" data-mk-start="…" data-mk-end="…">
```

The id derives from the block's content hash plus its ordinal among identical
hashes — **not** from its position — so inserting a paragraph does not renumber
everything below it. On a file change the core re-parses, diffs the block-hash
sequence, and emits a minimal edit script; the shell patches only the affected
blocks by `data-blk` and leaves every other DOM node untouched.

We do not use `content-visibility: auto`.

Scroll position is preserved manually, since WebKit gives us no automatic
mechanism: before patching, record the first block crossing the viewport top and
its offset; after patching, `scrollBy` the delta. Read, patch, and correct all
happen inside **one** `requestAnimationFrame` so no intermediate state is
painted, with `scroll-behavior: smooth` disabled for the duration.

## Consequences

**Easier.** Time-to-visible becomes roughly independent of document size, which
is the property that makes the app feel fast. Because block identity and byte
ranges already exist for incremental patching, the checkbox contract, the
file-watcher re-render, and "scroll to the block that changed" all fall out of
the same machinery. Node-preserving patches mean already-rendered MathML and
pre-rendered diagram SVGs are never re-laid-out or re-decoded.

**Harder, and we are accepting it.** This is materially more complex than
`innerHTML = html`. We own a block-diff algorithm, a background pump, a scroll
anchor, and a highlight cache with an eviction policy — none of which a naive
renderer needs. The document exists in two states (prefix painted, tail
pending), so anything that queries the DOM must tolerate a partially populated
document: in-page search, "scroll to heading", and print all need to either wait
for the fill to finish or force it.

We are also accepting a **correctness surface**: a block-diff bug shows up as a
subtly stale or duplicated document rather than a crash, which is harder to
notice than a hard failure. This needs tests that assert the patched DOM equals a
freshly rendered one.

Constraints this imposes on future work:

- **Nothing may depend on the whole document being in the DOM** without first
  awaiting or forcing completion of the background fill. Provide one explicit
  `ensureFullyRendered()` path and route such features through it.
- **`content-visibility: auto` is not to be reintroduced** without a fresh
  measurement on the then-current WebKit that beats plain injection. The
  reasoning is in Context; a future WebKit may change it, and that would be a
  supersession, not an edit.
- **`requestIdleCallback` is unavailable** — do not reach for it.
- **Block ids are content-derived, never positional.** Any change making them
  positional breaks incremental patching's whole point.
- **Highlighted output is cached by content hash**, so highlighting must stay a
  pure function of `(language, code, theme)`. No ambient state.
- **The first-paint block count (~40) is a tunable, not a constant** — it should
  be derived from viewport height at runtime rather than hardcoded forever.

**Known ceiling:** the 8 MB / 119k-line document is untested end to end. Parsing
it costs 18 ms, but highlighting ~3,200 code blocks would be ~800 ms and
appending ~30k blocks is unmeasured. That case likely needs windowed rendering
(mount and unmount blocks around the viewport) rather than "prefix then all". We
are deliberately not building that now; the point of recording it is so the
ceiling is a known number rather than a surprise bug report.

**Open and deliberately deferred:** class-based highlighting
(`ClassedHTMLGenerator`) re-themes with zero re-render but emits 2.7× more HTML
into the layout path that is already our bottleneck. Inline styles are the
opposite trade. We will measure both during implementation rather than guess now;
whichever wins is an implementation detail under this ADR, not a new decision.

## Alternatives considered

- **Plain `innerHTML` with the whole document.** Simplest by far, and correct.
  Rejected on 124 ms versus 1 ms for the visible result — a difference the user
  feels on every open.
- **`content-visibility: auto` with `contain-intrinsic-size`.** The
  standards-blessed answer to exactly this problem, and what we expected to
  adopt. Rejected on measurement: 225 ms versus 124 ms for plain injection, i.e.
  1.8× worse than doing nothing.
- **`loadHTMLString` per document.** Rejected: full document teardown, loses
  scroll position and all JS state, and produces a visible white flash. It is
  the documented cause of the "live preview jumps to the top" complaint in every
  markdown-preview implementation we surveyed.
- **`morphdom` / `idiomorph` DOM diffing alone.** Genuinely good at preserving
  DOM and scroll, and we will keep `idiomorph` (~5 KB) as a fallback for
  structurally messy diffs. Rejected as the primary mechanism because it only
  makes the *DOM patch* incremental — the core would still re-parse, re-highlight,
  and re-serialize the entire document to produce the new tree to diff against,
  leaving the 98 ms highlighting cost fully in place. Block-level diffing makes
  the Rust side incremental too.
- **Virtualized/windowed rendering from the start** (mount only blocks near the
  viewport). Strictly better for the 8 MB case and the eventual answer there.
  Rejected for now as unnecessary complexity: prefix-then-fill already reaches
  1 ms first paint at 1 MB, and windowing breaks in-page search and ⌘F in ways
  that need their own design.
- **Highlight everything eagerly on a background thread.** Simpler than a prefix
  split. Rejected as insufficient alone — it fixes the 98 ms highlight but not
  the 124 ms layout, and the two must be solved together to reach 16 ms.
