---
id: 2026-09-01-document-images-over-a-scoped-scheme
status: Proposed
supersedes: null
superseded-by: null
components: [app, core, cli, render]
date: 2026-09-01
ticket: null
---
# Serve a document's images over a second scheme, from an allowlist the core computes, and spend a fourteenth ABI function on it

## Context

`Resources/markdown-reference.md` has a section called **Images**. It says:
*"Paths are resolved relative to the document. Images are capped at the width of
the text column."* `shell.css` has an `img { max-width: 100% }` rule to make the
second sentence true. The first sentence has never been true.

The shell page is served over `mark-asset://shell/shell.html`, and
`ShellSchemeHandler` serves an allowlist of exactly three files — `shell.html`,
`shell.js`, `shell.css` — with everything else a named refusal
(`ShellAssets.swift:33`, `:199`). A document's `![alt](assets/x.png)` is a
relative URL, so it resolved against the shell page and arrived as
`mark-asset://shell/assets/x.png`. Not one of the three. Every local image in
every document has been a broken-image icon since M2.

This is the one place the "the reference cannot drift from the code, because it
is rendered by the renderer it documents" claim in
`2026-08-26-markdown-reference-window` fails. That claim holds for *constructs*:
a task list that stopped rendering would be visibly broken on the page that says
it works. It does not hold for a construct whose failure is a 404 on a
subresource, because the page still renders — it just has a hole in it, and the
reference's own Images section contains no actual image to have a hole.

`mark render --html` has the same gap in a different direction: it emits the
`<img>` with the destination the document wrote, so the HTML works if it is
written next to the document and breaks anywhere else, while the README calls
it "self-contained".

Three things constrain the fix.

**ADR-4's single configuration.** *"All web views share one
`WKWebViewConfiguration`"*, because per-tab configurations measured ~2× slower
to create and split the content process. A `WKURLSchemeHandler` is registered on
the configuration, not on a web view, so one handler instance serves every tab
and has to tell them apart itself — the problem `ScriptMessageRouter` already
solves for the message bridge.

**A document's HTML is not ours.** `pulldown-cmark` passes raw HTML through
(`render.rs:422`, `html::push_html`), so a `<script>` in a markdown file
executes in the shell page. This is true today, independently of images, and it
is not fixed here — but it sets the bar for what a new handler may do: whatever
this handler will read off disk, a hostile document can ask it to read.

**The C ABI ceiling.** `2026-08-28-git-differences-by-running-git` states:
*"The C ABI ceiling is thirteen and this ADR spends the thirteenth. The next
capability that wants to cross the boundary spends a flag or supersedes this."*
Knowing which files a document's images name is a core question — it needs the
parser, and the CLI wants the same answer for `mark links` — so it has to cross.

## Decision

**A second scheme, `mark-doc`, serves a document's own assets**, registered on
the shared configuration alongside `mark-asset`. The shell sets a `<base href>`
to `mark-doc:///<the document's directory>/` as part of the same
`setDocument(html, meta)` call that injects the document, so relative sources
resolve onto that scheme with no per-image rewriting anywhere.

**The handler serves from an allowlist the core computes**, not from a path
rule. `mark_links_json(source, base, MARK_LINKS_IMAGES)` reports the images a
document names, resolved against its own directory and `stat`ed;
`DocumentView.refreshDocumentAssets` hands the ones that exist to the handler,
keyed by web view, before the document is injected and again before every patch.
A request for a path not on that list is refused, whoever asked.

**That is the fourteenth ABI function, and this ADR raises the ceiling to
fourteen.** The rule is restated rather than dropped: the next capability
spends a flag on a function whose name already covers the answer, or supersedes
this ADR in turn.

> Amended by `2026-09-01-search-in-the-core`, which retires the numeric ceiling
> in favour of the shape rule it was a proxy for, and explains why. The naming
> half above survives; the count does not. Left in place rather than rewritten,
> because what this ADR decided is still what happened.



The CLI gets the same core module as `mark links [--broken] [--images]`.

## Consequences

**Easier.** Images work, in every document, on every path that puts HTML in the
page — first paint, background fill, patch, and rendered diff — because
`<base>` is applied by the parser to whatever arrives and there is no per-path
rewrite to forget. An image added in the editor appears without a reopen. A
notes tree can be checked for rot with `mark links --broken`, which is one
`stat` per local destination and no network access. Backlinks, when they land,
are this module run over a directory and filtered.

**The allowlist is the security boundary, and it is a narrow one.** Because a
document's raw HTML reaches the page, "resolve the path and check it is under
the document's directory" would have been a general file server for any
image-shaped path a hostile document cared to name — and it would not even have
worked, since `../assets/diagram.png` is ordinary in real notes and a rule wide
enough to allow it is wide enough to allow `../../../.ssh/`. Computing the set
instead means the handler reads exactly the files the document references and
nothing else. The extension check behind it is a second gate, not the first one.

**What we are accepting.** SVG is served, and an SVG is a document that can
carry script. It is served because a diagram in a notes directory is very often
an `.svg`, and it is safe *as loaded* — `<img>` does not execute script in
WebKit — but that safety is a property of how the page requests it, not of the
file. An `<embed>` pointing at the same path would be a different matter. The
refusal is on the file rather than on the request shape, so this is a real
residual and is named here rather than discovered later.

**A read on the main thread.** `resolve` does `FileManager.contents(atPath:)`
synchronously in `webView(_:start:)`. Fine for the pictures in a notes
directory; the thing to revisit if a 40 MB scan appears in one.

**A second parse per open, for documents that have a picture in them.**
`mark_links_json` takes source and parses it, and the render has already parsed
the same bytes — so this is real cost on the path ADR-2 budgets in single-digit
milliseconds, at a parse measured there at ~2.9 ms/MB. It is gated on
`source.contains("![")`: every markdown image starts with those two bytes,
reference-style `![alt][ref]` included, so a document with no pictures pays a
substring scan and nothing else. A document that *does* have one pays the parse
plus one `stat` per image reference. Measured only end-to-end
(`mark links --images` on the generated 1 MB corpus is indistinguishable from
`mark toc` at ~10 ms wall clock for the whole process); the in-process delta
against the first-paint budget is **not** measured and is stated as such.

**A raw `<img src>` in embedded HTML is not served.** The allowlist is built
from markdown images, so a document that writes its pictures as HTML gets
broken images. It got broken images before this change too, so nothing
regresses — but the reference documents `![alt](…)` and this is now the
supported spelling rather than an accident.

Constraints this imposes on future work:

- **`mark-doc` serves images and nothing else.** Widening the extension list to
  a type the page can load as a *document* rather than as an image reopens the
  question this ADR closed.
- **The allowlist is replaced wholesale, never added to.** A picture removed
  from a document must stop being servable at the next refresh; an accumulating
  set would keep the reader's whole session reachable from the last tab open.
- **Nothing else may register a handler for `mark-asset`.** Three schemes now
  have three jobs — `mark://` is ADR-3's LaunchServices entry point,
  `mark-asset` is the shell, `mark-doc` is the document — and a handler on the
  wrong one shadows the others silently.
- **The C ABI ceiling is fourteen.** As above.
- **A document with no file behind it gets no base.** The Today page and the
  markdown reference pass an empty base and the `<base>` element is removed, so
  one page's pictures are never requested from another page's directory.

**Deliberately not decided here:** whether a document's raw HTML should be
sanitized. It should — a `<script>` in a markdown file currently reaches the
bridge that writes bytes to the reader's files — but that is a larger decision
about what `mark` renders, it affects `mark render --html` as much as the app,
and bundling it into an image fix would hide it. This ADR is written so that it
does not depend on the answer: the allowlist holds whether or not the page's
script is ours.

## Alternatives considered

- **Rewrite every image `src` in the core, to an absolute `mark-doc://` URL.**
  Rejected: four render entry points put HTML in the page and each would need
  the base threaded through it, including `render_marked_ranges`, which the
  rendered diff composes from two parses. `<base>` is one line and cannot be
  forgotten on a path.
- **A static `<base>` in `shell.html`.** Rejected: `<base>` governs the `<link>`
  and `<script>` in the same head, so it would send the stylesheet and the shell
  script to the reader's notes directory. Setting it from JS after load is
  immune, because both have already been fetched.
- **Widen `ShellSchemeHandler` to serve document assets too.** Rejected: it
  would put "any file on disk" on the same origin that serves `shell.js`, which
  owns the bridge to Swift.
- **Serve any image under the document's directory, without an allowlist.**
  Rejected on both correctness and safety, above: it breaks `../assets/` and it
  is not a boundary anyone can reason about.
- **`loadHTMLString` with a `file:` base URL, per document.** Rejected twice
  over: ADR-2 forbids reloading the page per document, and research §2.13
  already found that `file:` origins hit WebKit's subresource restrictions —
  which is why `mark-asset` exists at all.
- **Inline every image as a `data:` URI at render time.** Rejected for the app:
  it re-encodes every picture on every patch and puts megabytes through
  `callAsyncJavaScript`. Kept as the right answer for `mark render --html`,
  where "self-contained" is the promise — that is a separate, smaller change.
- **Spend a flag on `mark_tasks_json` instead of a fourteenth function.**
  Genuinely available, and cheaper: the app already calls it once per document
  and the links would ride along with no extra parse. Rejected because the
  answer feeding a `WKURLSchemeHandler`'s allowlist should not be reachable only
  through a call whose name says "tasks". The precedent in the header — blocks
  riding on `mark_tasks_json` — is for data about the *same* subject; this is a
  different subject, and hiding it would be the "smuggling" ADR-1 warns about.
