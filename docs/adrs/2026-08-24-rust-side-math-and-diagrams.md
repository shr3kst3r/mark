---
id: 2026-08-24-rust-side-math-and-diagrams
status: Accepted
supersedes: null
superseded-by: null
components: [render, core, build]
ticket: null
date: 2026-08-24
---
# Render math to MathML and Mermaid to SVG in Rust, shipping no JavaScript

## Context

Math and Mermaid diagrams are v1 features. The conventional way to get them into
an HTML-rendering viewer is to ship JavaScript into the WebView: KaTeX for math,
`mermaid.js` for diagrams. Both alternatives are Rust libraries that pre-render
to inline markup instead. We measured the options rather than assuming.

**Math.** `pulldown-cmark`'s `ENABLE_MATH` yields `Event::InlineMath` and
`Event::DisplayMath` carrying raw TeX, each with a byte range, which feeds a Rust
LaTeX→MathML converter directly. `pulldown-latex` 0.8 builds on rustc 1.86,
converts at **0.0063 ms per expression**, and costs ~400 KB of binary. Rendered
in `WKWebView`, all 13 test expressions produced real layout boxes — fractions,
radicals with proper vinculum, integrals with limits, `pmatrix`, `cases`,
`align`, `\mathbb{R}`, `\mathcal{H}`, `\lim` with subscript — resolving to the
system `math` font (STIX Two Math, which ships with macOS). Visual inspection of
a snapshot confirmed the typesetting is comparable to KaTeX.

**A verified gap:** `pulldown-latex` does not support `\newcommand`. Note the way
this surfaces — it returns `Ok` with an embedded `<merror>` node rather than
`Err`, so a naive success check reports it as working. Our first pass did exactly
that and reported "13 ok, 0 failed"; only looking at the rendered pixels revealed
2 of 13 had failed. Detection must test for `merror` in the output, not just the
`Result`. `pulldown-latex`'s default error markup is also verbose enough to
overflow the page width.

**Diagrams.** No Rust Mermaid renderer builds on rustc 1.86:
`mermaid-rs-renderer` 0.3 requires 1.87, `merman` 0.7 requires 1.88, and
`merman` 0.8.0-alpha.5 requires **1.95**. Note that `cargo generate-lockfile`
reports success for all three because the MSRV-aware resolver back-solves to
older transitive deps; only an actual build reveals the wall. The toolchain was
upgraded from Homebrew's 1.86.0 to **1.98.0** to unblock this, and every existing
crate in the project rebuilt with no regression (1 MB parse 2.25 ms, highlight
105 ms — both within noise of the 1.86 figures).

On 1.98, `merman` 0.8.0-alpha.5 renders 8 of 8 valid diagram families —
flowchart, sequence, class, state, gantt, pie, ER, journey — at **0.23–0.34 ms
each**, producing 4–28 KB of inline SVG. The two invalid inputs returned clean
`Err` values with useful messages ("Unterminated node label (missing `)))`)"),
and `RenderSvgError::NoDiagram` cleanly distinguishes prose from a broken
diagram. **Zero panics** across all ten cases. Visual inspection confirmed
flowchart and sequence output matches Mermaid's own styling. Its
`render_svg_with_id` entry point exists specifically for embedding multiple
diagrams in one document.

**The cost, and it is larger than expected.** `merman` adds **10.2 MB** to the
binary with `lto`, `strip`, `opt-level = "z"`, and `panic = "abort"` (24 MB
without), against a 0.27 MB empty-binary baseline, and pulls **173 crates** with
a ~63 s LTO link. `mermaid.js` is 3.4 MB minified.

**So the Rust path is roughly 3× larger on disk than the JavaScript it replaces.**
That inverts the size argument, which was part of why this option was chosen. It
is recorded prominently because a reader comparing 10.2 MB against 3.4 MB will
otherwise conclude we did not check.

The decision holds anyway, on three grounds the size comparison misses:

1. **The CLI needs diagrams too, and JavaScript cannot serve it.** `mark render
   file.md --html` must emit a complete, self-contained document, and
   `mark render --ansi` renders in a terminal. `mermaid.js` requires a browser to
   execute; pre-rendered SVG works in both. A JS renderer would mean the GUI has
   diagrams and the CLI does not — a permanent capability split between two
   consumers that this project has otherwise kept identical.
2. **JS execution lands on the render path, which is already the bottleneck.**
   WebKit layout is ~96% of time-to-visible. Adding a 3.4 MB parse-plus-layout
   step in JavaScript on the main thread works directly against the progressive
   rendering strategy, and diagrams would pop in asynchronously after first paint
   rather than being present in it.
3. **Disk is not the constraint that was accepted.** "Lightweight" was pinned to
   memory, where a ~61 MB floor was explicitly accepted. A ~12 MB bundle remains
   an order of magnitude below an Electron equivalent.

## Decision

We render both math and Mermaid diagrams in the Rust core, emitting inline
MathML and inline SVG. **The WebView receives no JavaScript for either feature,
and we ship no KaTeX and no `mermaid.js`.**

Math: `Event::InlineMath` / `Event::DisplayMath` → `pulldown-latex` → inline
`<math>`. Diagrams: a fenced code block whose info string is `mermaid` →
`merman::render_svg_with_id` → inline `<svg>`, with the id derived from the
block's `data-blk` so it is unique within the document.

When either renderer fails, we emit **our own styled inline badge** carrying the
parser's message, and keep the raw source selectable next to it. We do not fall
back to KaTeX or `mermaid.js`; a construct we cannot render shows as an
explicitly failed construct, not as a silently blank region and not as a reason
to load a JavaScript runtime. Failure detection tests for `<merror>` in MathML
output as well as the `Result`, and every diagram render is wrapped in
`catch_unwind` because `merman` is pre-1.0.

The project's MSRV becomes **1.95**, pinned via `rust-version` in `Cargo.toml`.
`merman` is pinned to an exact version, not a caret range.

## Consequences

**Easier.** Math and diagrams are present in the very first painted frame, with
no async pop-in and no layout shift. They cost 0.006 ms and 0.34 ms
respectively — effectively free against a 16 ms budget. The CLI has identical
capability to the GUI, so `mark render --html` produces a genuinely
self-contained document. Zero third-party JavaScript executes in the WebView,
which removes an entire class of injection surface from a tool that renders
untrusted files. Rendered SVG and MathML are inert DOM, so incremental patching
never re-decodes or re-lays-out them.

**Harder, and we are accepting it.**

- **+10.2 MB of binary and 173 crates**, taking the bundle from ~684 KB to
  roughly 12 MB. Release LTO links take ~63 s, which slows the build for everyone
  including CI.
- **MSRV 1.95 is aggressive**, six weeks old at the time of writing. Contributors
  need a very recent Rust, and distro-packaged toolchains will often be too old.
  This is the constraint most likely to annoy someone.
- **`merman` is 0.8.0-alpha.** We are depending on pre-1.0 software for a
  user-facing feature. It behaved well under test (no panics, clean errors), but
  parity gaps against `mermaid.js` should be expected, and we visually verified
  only flowchart and sequence output in detail.
- **`\newcommand` and macro definitions do not work**, and any LaTeX beyond
  `pulldown-latex`'s coverage shows a badge rather than rendering. Users coming
  from Obsidian or Typora will notice. We are accepting a visible-failure design
  over a 556 KB KaTeX fallback.
- **Two renderers can panic or hang on adversarial input.** `catch_unwind` covers
  panics; a pathological diagram that is merely slow is not covered.

Constraints this imposes on future work:

- **No JavaScript library may be introduced to render math or diagrams.** If
  `pulldown-latex`'s coverage becomes the binding problem, the answer is a
  superseding ADR, not a lazily injected KaTeX — because that would silently
  reintroduce the GUI/CLI capability split this decision exists to prevent.
- **Every `merman` call is wrapped in `catch_unwind`** and falls back to the
  badge. No exceptions while it is pre-1.0.
- **Math failure detection checks for `merror`, not just `Result::is_err`.**
  This is the trap that already fooled us once.
- **`merman` stays pinned to an exact version.** A pre-1.0 alpha must not float.
- **`rust-version` stays pinned** and CI must build on exactly that version, so
  an MSRV bump is a deliberate, visible change.
- **Diagram SVG ids derive from `data-blk`** so they remain unique and stable
  under incremental patching.
- **Renderers must stay pure functions of their source text** so their output can
  be memoized alongside highlighted code.

**Reversibility:** this is cheaper to reverse than it looks. Both renderers sit
behind one function per construct in the core, so swapping either for a JS path
is a renderer change plus an asset-pipeline change — under a day. The expensive,
sticky part is the MSRV bump and the 10 MB, not the rendering approach.

## Alternatives considered

- **KaTeX (556 KB, WOFF2 fonts only) for math.** Complete LaTeX coverage
  including `\newcommand`, and the ecosystem default. Rejected: it puts JS on the
  render path, cannot serve the CLI, and its coverage advantage applies to
  constructs a viewer sees rarely. Explicitly reconsidered as a *fallback* for
  failed expressions and rejected there too — maintaining two math renderers whose
  output must look consistent is real ongoing cost, and it would mean the CLI
  renders less math than the GUI.
- **MathJax.** Rejected on size alone: 962 KB (`tex-chtml`) to 1.8 MB
  (`tex-svg`), ~3.5× KaTeX for no benefit we need.
- **`math-core` 0.7 instead of `pulldown-latex`.** Actively developed and a
  direct competitor. Not chosen because `pulldown-latex` builds on a lower MSRV
  (1.86 vs 1.91), is a pull parser matching `pulldown-cmark`'s design, and
  verified sufficient on our test set. Worth revisiting if `\newcommand` support
  becomes necessary — checking whether `math-core` handles it is the cheap first
  move before considering KaTeX.
- **`mermaid.js` (3.4 MB), lazily injected only into documents containing a
  mermaid fence.** **Genuinely 3× smaller on disk than what we chose**, needs no
  toolchain upgrade, and keeps MSRV at 1.86. Rejected on the three grounds in
  Context — chiefly that it cannot serve the CLI, permanently splitting GUI and
  CLI capability. This is the closest call in this ADR.
- **`@mermaid-js/tiny`.** About half the size of full `mermaid.js`. Rejected: it
  drops mindmap and architecture diagrams *and* lazy loading, so it is a worse
  version of an option already rejected.
- **`mermaid-rs-renderer` 0.3 (MSRV 1.87).** A much gentler MSRV bump for the
  same zero-JS benefit. Rejected: no flagship adopter, and it pulls the
  `resvg`/`usvg` rasterization stack, so the binary saving over `merman` is
  unproven. `merman` is what Zed ships, which is the strongest availability
  signal in this space.
- **Shelling out to `mmdc` (mermaid-cli).** Rejected: requires Node on the user's
  machine, adds process-spawn latency per diagram, and makes diagrams silently
  unavailable on a machine without Node.
- **Rendering diagrams at build time.** Rejected as a category error — diagrams
  live in user documents that do not exist at build time.
