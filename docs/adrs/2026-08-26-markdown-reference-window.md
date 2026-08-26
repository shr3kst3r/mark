---
id: 2026-08-26-markdown-reference-window
status: Proposed
supersedes: null
superseded-by: null
components: [app, render, cli]
date: 2026-08-26
ticket: null
---
# Ship the markdown reference as a document mark renders, in a window of its own that is budgeted like a tab

## Context

The request is *"a help screen that allows me to see all the supported markdown
and how to use it"*. Two decisions are hiding in it, and neither is obvious
from the sentence.

**The first is what the help *is*.** A help screen for a renderer can be a
hand-written page that describes the renderer, or it can be a document the
renderer renders. The two look identical on the day they ship and diverge
immediately afterwards: the first has no way of noticing that a construct
stopped working, and it cannot show a Mermaid diagram or a MathML expression at
all without reimplementing `2026-08-24-rust-side-math-and-diagrams`. Writing
this reference already found one such divergence before a line of it was
rendered — GFM alerts (`> [!NOTE]`) have been *parsed* since `ENABLE_GFM` was
turned on, and `app/Resources/shell.css` has never had a rule for the class
pulldown-cmark attaches, so every alert in every document has rendered as a
plain blockquote with its marker silently removed.

**The second is what the window costs.** `2026-08-26-editor-groups-per-pane-tab-bars`
makes the residency budget the application's rather than each window's, in
those words, and enforces it through one governor that ranks *tabs*:

> `residentLimit` is a property of a `TabStore`. The obvious implementation
> gives each window its own store, and three windows then license 3 × 3 = 9
> resident views — about 470 MB — while `MARK_RESIDENT_TABS`, every log line,
> and any future `mark doctor` output still report the limit as 3.

A help window holds a `WKWebView`, which is ~52 MB of WebContent process, and
it is not a tab. Left alone it is invisible to `ResidencyGovernor.residentCount`,
to the `estimatedFootprintMB` formula, and to `mark doctor` — which does not ask
the app for the number at all but derives it from `tab-list` and evaluates the
formula itself. The corpus already keeps a superseded ADR whose entire
correction was a memory measurement that reproduced perfectly and counted the
wrong processes. Under-reporting by 52 MB through a second route is the same
defect wearing a different hat.

A **tab** was offered as the presentation and declined in favour of a separate
window. There is an independent reason to be glad of that answer.
`2026-08-25-flock-write-locking` makes the editor pane available on any selected
tab, so ⌥⌘E on a reference tab would point an `NSTextView` and an 800 ms
autosave at a file inside `mark.app/Contents/Resources`: on a locally built
bundle that write succeeds and edits the shipped reference, and on a signed one
it fails and breaks the seal. A surface with no `DocumentTab` behind it cannot
reach either state, and does not need a guard to stay out of them.

The window does need ⌘F — a syntax reference is a thing you search — and the
find machinery is 110 lines inside `MainWindowController`, a 2,656-line file,
with `FindBar` and `PreviewPaneView` already generic beneath it.

## Decision

**The markdown reference is a markdown document, shipped in the bundle and
rendered by the core** — `app/Resources/markdown-reference.md` in the
repository, beside the shell assets it is delivered with, and
`Contents/Resources/markdown-reference.md` in `mark.app`. It goes through
`mark_render_html` and a `DocumentView` like any other document, so it shows the
active theme, real syntax highlighting, real MathML and a real Mermaid diagram —
and `mark render app/Resources/markdown-reference.md --ansi` prints the same
document without the app.

There is exactly **one copy of it in the repository**. SwiftPM resources must
live under the target root, so a second copy in `docs/` would need a sync recipe
and a staleness check to stop the two drifting — machinery in exchange for a
nicer path.

**It opens in a single-instance window**, from a new **Help ▸ Markdown
Reference** (⇧⌘/), owned by `AppDelegate`. The window has no sidebar, no tab bar
and no editor. Its `DocumentView` is given a `TaskWriteTarget` that refuses, so
the reference's own example checkboxes cannot write anywhere. Closing the window
releases the web view.

**That web view is counted against the application's residency budget.** The
governor learns about resident views that are not tabs: they raise the count
`enforce()` works from, so opening the reference dehydrates the least recently
used background tab rather than adding 52 MB on top of the ceiling, and they are
included in `estimatedFootprintMB`. The `ping` reply gains an additive
`auxiliaryWebViews` field and `mark doctor` adds it to the formula it prints.

**Find is extracted, not duplicated.** A `DocumentFinder` owns the query, the
generation counter, the four `NSTextFinder` actions and their validation, over a
`DocumentView` it is handed on demand. `MainWindowController` keeps its existing
public surface — `findBar`, `isFindBarVisible`, `showFindBar()`,
`setFindBarVisible(_:)`, `performFindAction(_:)` — as forwarding, and the help
window uses the same type.

**Alerts are given the styling their class has always implied**: a coloured left
border and a label, per severity, from the palette tokens `shell.css` already
defines. Pure CSS; no JavaScript enters the page.

## Consequences

**What becomes easier.** The reference cannot drift from the renderer, because
it *is* a render: a construct that breaks breaks visibly on the help screen. It
costs one markdown file to extend. It is readable outside the app through
`mark render`, so the CLI gains the capability without gaining a verb. And
`DocumentFinder` means the next surface that shows a document gets ⌘F by
construction rather than by a third copy of a generation counter.

**What becomes harder, and what is being accepted.**

* **Opening the reference can dehydrate a tab.** With `MARK_RESIDENT_TABS=3`,
  three resident tabs and the reference open, one tab loses its web view and
  rehydrates in ~4.7 ms when next selected. This is the deliberate choice: the
  ceiling is a ceiling. Anyone who wants the reference to be free raises the
  limit.
* **`mark doctor`'s memory line changes shape.** It has printed
  `~100 MB + ~52 MB × N resident` where N came from `tab-list`. It now counts
  web views rather than tabs and says when one of them is the reference. A
  script parsing the human-readable line will need updating; the `--json` field
  `resident_tabs` keeps its meaning and `auxiliary_web_views` is added beside it.
* **The reference window has no sidebar and no table of contents.** Its own
  headings are the navigation, plus ⌘F. Giving it a sidebar would make it a
  second `MainWindowController`, which is the thing this ADR is avoiding.
* **`MainWindowController` gains an indirection.** Five members that were
  fields and private methods become forwarding to `finder`. The existing
  `FindTests` are the check that the forwarding is faithful; they were written
  against the public surface and are not modified.
* **The reference is one more thing to keep true.** It is a claim about the
  renderer's behaviour that lives outside the renderer's tests. A test asserts
  that it parses, that its headings and task markers are there, and that its
  diagram and its math actually rendered — which catches the constructs that
  fail loudly, and not the ones that quietly stop being supported. (The page
  contains exactly one *deliberate* failure: the section on broken math is a
  demonstration of the badge.)
* **Alert styling changes how existing documents look.** Any document already
  containing `> [!NOTE]` renders differently after this. That is the point, and
  it is still a visible change to output that nobody asked for.

**What is explicitly not in scope.** No new socket command and no new CLI verb:
the reference is a document, and the CLI's way of opening a document is
`mark render`. No new C ABI function — `2026-08-24-rust-core-swift-appkit-shell`
puts the ceiling at "roughly a dozen" and nothing here needs one. And the
pre-existing gap where `mark theme` re-colours only the key window's tabs is
left alone; it is real and orthogonal, and fixing it inside this change would
bury a multi-window rendering fix in a help-screen commit.

## Alternatives considered

**A hand-written HTML help page.** Cheapest, and it describes the renderer
instead of demonstrating it. It cannot show MathML or a Mermaid diagram without
reimplementing ADR-5, and nothing would ever tell anyone it had gone stale.

**The reference as an ordinary tab.** Free find, table of contents, themes and
residency. Rejected by the requester in favour of a window, and separately
hazardous: ⌥⌘E would aim autosave at a file inside the app bundle.

**A floating `NSPanel`.** Offered and declined. A document-sized reference that
sits above every window until dismissed is the wrong shape for something you
read a paragraph of.

**Leave the help window out of the memory budget.** One line of code and a
50 MB lie in `mark doctor`. The corpus's own history is the argument against it.

**Give the help window its own copy of the find glue.** 110 duplicated lines
including a generation counter whose whole job is a race that only shows up
under load. Duplicated once, fixed once.

**Document alerts as unsupported instead of styling them.** They parse today, so
"unsupported" would be false; and the reader who tries one gets a blockquote
with its first line deleted, which is worse than either answer.
