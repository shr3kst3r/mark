---
id: 2026-08-31-today-page
status: Proposed
supersedes: null
superseded-by: null
components: [app, render]
date: 2026-08-31
ticket: null
---
# Show the day's work as a document mark assembles and renders, in a window with no file behind it

## Context

The request is *"a page that I can view that shows me my current date daily
items in progress or not started and then each project and their open items."*

Every noun in it already exists somewhere. `2026-08-27-five-task-states` gives
`[ ]`, `[/]`, `[x]`, `[-]` and `[?]`, and the core's `State::is_outstanding`
already means *open, in progress, or blocked*.
`2026-08-27-inline-task-metadata` gives `@proj(slug)` and `!!` and the rule that
**no clock is read in the core** — a date comparison takes "today" as an
argument. `mark ls` and `mark tasks` already answer the two queries. What does
**not** exist is anything that reads more than one document at a time, or that
knows a directory can have a *shape*.

Because that is what the sentence turns on. "My current date daily items" and
"each project" are not properties of markdown; they are properties of a
journal, and the one this page is built for is laid out as:

```
daily/2026/08/2026-08-31.md      one file per day
projects/quarterly-report/index.md   a directory per ongoing effort
```

with `index.md` carrying `> Started … · **Status:** active · tag
`@proj(quarterly-report)``, and a carry-forward that copies every still-unchecked
task into the next day's daily. That last part matters more than it looks:
**because each day carries from the day before, today's daily already holds
everything still open from earlier days.** A page that reads one file is
therefore not a page that shows one day.

Four things about the answer were genuinely open, and were put to the
requester rather than guessed:

* **Where it lives.** A window, a tab, or a fourth sidebar tab.
* **How it finds the journal.** A configured root, the sidebar's current root,
  or no layout knowledge at all — "today" meaning `@due(today)` and "project"
  meaning the distinct `@proj(…)` values.
* **Whether it is interactive.** Read-only with links out, fully writable, or a
  static snapshot.
* **What a project's open items are.** Its own files only, or its own files plus
  the `@proj(slug)`-tagged items living elsewhere.

The last of those has a forcing answer. A typical daily holds several tasks
tagged `@proj(website-launch)` while that project's `index.md` holds none. "Its
own files only" would show that project as having nothing in flight while
several of the day's items belong to it.

One constraint pulls against the whole idea.
`2026-08-26-new-documents-are-files-on-disk` says mark never holds a document
that has no file, and the page is assembled from many files and is not one.

## Decision

**The page is a markdown document that mark assembles and then renders**, for
the reason `2026-08-26-markdown-reference-window` gives about the reference: a
task list written as markdown gets the five hand-drawn checkbox states, the
`@tag` and priority styling and the overdue colouring for free, from the same
code path that draws them in the file the item came from. A hand-built
`NSTableView` would be a second renderer that agrees with the first until it
does not.

**It opens in a single-instance window, from a new File ▸ Today (⇧⌘T)**, beside
File ▸ History because it is the same kind of thing: a way *in* to your
documents rather than one of them. No sidebar, no tab bar, no editor, no entry
in the session file. Its web view registers with `ResidencyGovernor` as an
auxiliary, exactly as the reference's does — the test is the web view, not the
window.

**Having no `DocumentTab` is what settles the fileless-document problem.**
`2026-08-25-flock-write-locking` makes ⌥⌘E open an editor and an 800 ms autosave
on whatever tab is *selected*; a surface with no tab cannot be selected, so
there is no path by which the synthesized page could be written anywhere. The
page is still given a URL — `<root>/Today`, extensionless — because a
`DocumentView` renders *for* one: it is what relative links resolve against and
what every log line names. Nothing reads that path.

**It reads the sidebar's current root, walking up to the nearest directory
holding both `daily/` and `projects/`.** No new setting. Both directories are
required, because `daily/` alone matches a great many note trees and
`projects/` alone matches most source repositories. The *nearest* one wins, so a
git worktree of the journal is its own journal and shows the dailies that are
checked out in the window you asked from. Finding none produces a page that says
what was looked for and where, because an empty page and "you have nothing to
do" must not look the same.

**What the page shows.**

* **Today** — every outstanding task in `daily/<yyyy>/<MM>/<yyyy-MM-dd>.md`, in
  document order, grouped by the heading it sits under, keeping its nesting.
  Blocked items are included alongside open and in-progress ones: the request
  named two states, and a `[?]` item silently dropped from today's list is the
  one failure mode worth more than the literal reading. The checkbox says which
  state each is. With no daily for today, the most recent one is shown **and
  labelled as such**, with the path that is missing named.
* **Projects** — every entry under `projects/`, sorted active first and then by
  title, each with the `**Status:**` word from its front page, its own files'
  outstanding tasks, and the items tagged `@proj(slug)` in the daily, captioned
  with the file they came from.

**Read-only, and every item links out.** The checkboxes are drawn but wired to a
`RefusingTaskWriter`: each one is a copy of a line in another file, and a click
has nowhere correct to go. Every item's link carries the heading it sits under,
so following it opens the real file and scrolls to that section rather than to
the top of a 200-line daily.

**An item's text is its own source line, copied verbatim** — not `Task::text` or
`Task::label`, which are flattened plain text that would turn
`[issue](https://…)` into the bare word "issue". This is the same choice a
journal's carry-forward makes, and for the same reason. It requires two
corrections, both of which are the page's own doing and neither of which the
core should know about:

* **Relative links are re-based.** `[the outline](./outline.md)` in a project's front
  page means that project's directory; on a page based at the root it would mean
  the root, and point at a file that does not exist. A small rewriter re-bases
  every relative destination as the line is copied, leaving anything it does not
  recognise exactly as it was.
* **Nesting is normalised.** A four-space indent copied into a list that starts
  at column zero is an *indented code block*, and a child whose parent was
  filtered out would be indented under nothing. Distinct indent widths become
  consecutive levels, no level is more than one deeper than the one before it,
  and a finished parent is kept as **context** for an unfinished child rather
  than dropped.
* **Empty tasks are skipped.** The journal's templates ship `## Open` with a
  bare `- [ ]` under it. It is a real marker in a real file and the core is
  right to report it; an empty checkbox on a page whose whole job is "what is
  outstanding" is noise.

**It re-reads itself.** A `FileWatcher` over exactly the files the page was
built from re-renders it through `DocumentView.apply(source:)` — ADR-2's block
patch, so the reader's scroll position survives. Becoming the key window
rebuilds from scratch, which is what picks up a project created since the window
opened, and what makes a window left open overnight say "Tuesday".

**The walk is bounded, in the shape `2026-08-27-sidebar-polls-listed-directories`
requires.** Today's daily is one path and no search. The most recent daily is a
newest-first descent of `daily/` that stops at the first hit. `projects/` is one
level, then each project one level, capped at 200 projects and 64 files each.
Nothing walks the journal at large — the tree that ADR was measured against
holds 608k files.

**Two fixes to the shared link path come with it**, because the page's own links
are the first thing in the app to need them. `DocumentView` percent-*decodes* a
destination before resolving it — the renderer percent-encodes on the way out,
so `projects/my project/index.md` has always arrived as `my%20project` and been
looked for under that literal name — and it splits a `#fragment` off, handing it
to a new optional `onFollowFragment`. `MainWindowController` wires that to a new
`open(_:scrollingTo:)`, so a cross-file anchor link now works in *any* document
rather than only on this page.

## Consequences

**What becomes easier.** The page costs no new C ABI function, no new socket
command and no new CLI verb: it is assembled in Swift out of `mark_tasks_json`,
`mark_toc_json` and `mark_tree_json`, all of which already exist. The digest is
a value with no AppKit in it, so the whole of what the page *says* is tested
against fixture journals on disk without a window. And cross-file `#anchor`
links, which have silently done nothing in every document since links were
followed at all, now work.

**What becomes harder, and what is being accepted.**

* **mark now knows a directory layout.** `daily/YYYY/MM/YYYY-MM-DD.md` and
  `projects/<slug>/index.md` are one journal's convention in a general-purpose
  markdown tool. It is confined to `JournalRoot` and read by nothing else, and
  the layout-agnostic alternative was declined below — but this is a product
  claim, not just a technical one, and it is the largest thing here to disagree
  with.
* **Opening the page can dehydrate a tab**, exactly as opening the reference
  can. The ceiling is a ceiling.
* **The Projects section duplicates the Today section.** A `@proj`-tagged item
  appears in both, deliberately, because the two sections answer different
  questions. Chosen by the requester over the non-duplicating alternative.
* **A multi-line task item loses its continuation.** An item is copied as the
  single source line its marker is on; `Task` carries the marker's byte range,
  not the item's, so the extent of a wrapped item is not available over the ABI.
  Nothing in the target journal layout wraps, and the honest fix is a core change
  rather than a guess in Swift.
* **A file whose name contains `#` cannot be linked.** The renderer does not
  encode it and the split cannot tell it from an anchor. That is markdown's
  ambiguity; it is now written down.
* **Percent-decoding a destination is not free of edge cases.** A file whose
  name genuinely contains `%20` will now be looked for with a space. Every
  markdown renderer makes this trade; the alternative is that no file with a
  space in its name is linkable, which is worse and is what shipped before.
* **The window is one more thing the theme fan-out has to be told about.** Two
  windows now need the explicit call `MainWindowController` makes outside its
  tab loop, which is the point at which "the loop cannot reach it" stops being a
  footnote about one window.
* **Nothing verifies the page against a running app in CI.** The suite asserts
  on the markdown and on the window's own state machine; that the page *looks*
  right is checked by rendering it through the CLI by hand.

**What is explicitly not in scope.** No `mark today` CLI verb and no socket
command — `mark tasks --open` and `mark ls --json` already answer these
questions for a script, and a shell one-liner covers the rest. No writing from the page. No per-item deep link to the exact task: the
digest carries each item's index and byte offset, so
`DocumentView.scrollToTask(index:byteOffset:)` is a later change to the link
format and not to the digest. No weekly or meeting sections. And the pre-existing
flakiness in `EditorRoundTripTests.closingATabWritesItsPendingBuffer` is left
alone; it is a real 800 ms autosave race and orthogonal to this.

## Alternatives considered

**No layout knowledge at all** — "today" meaning `@due(today)` or overdue, and
"projects" meaning the distinct `@proj(…)` values under the root. This keeps one
person's directory shape out of a general tool, which is a real virtue, and it
was offered first. Declined by the requester, and the measurement is why: the
dailies carry no `@due` tags, so the Today section would have come back empty on
the day it shipped.

**A configured journal root**, from `$MARK_JOURNAL` or a setting, defaulting to
the nearest ancestor with both directories. Offered as the recommendation and
declined in favour of the sidebar's root, which needs no configuration and is
already pointed at the notes — and the worktree of them — being worked in. The
cost is that the page means something different as you navigate, and shows the
empty state when the sidebar is rooted in an unrelated repository.

**A tab in the main window.** Reads most naturally as "a page", and puts
⌥⌘E, an editor and an 800 ms autosave on a document that has no file. Every
guard that would need is a guard somebody has to remember.

**A fourth sidebar tab**, beside Tree / Contents / Tasks / Diff. Always at hand,
and a whole day plus every project in a ~260 pt column reads badly. It would
also compete with the Tasks tab, which answers the same question for one
document.

**Fully interactive — tick an item from the page.** More useful, and materially
more work: every checkbox would have to carry `(source file, task index)` and
route its write to a different document, re-verifying against a file that may
have moved under it. Declined for this change, not forever; the digest already
carries the identity it would need.

**A static snapshot with no watching.** Simplest possible thing. Declined: a
page you have to close and reopen to trust is a page you stop trusting.

**Generating the page in Rust, behind a new ABI function.** The core owns
document parsing and does, here — every task, heading and directory listing on
this page comes from it. What is left is grouping and string building over
values the ABI already returns, and
`2026-08-24-rust-core-swift-appkit-shell` puts the ABI ceiling at "roughly a
dozen" functions. Spending one of those on a page layout would be the wrong
thing to spend it on.

**Skipping the percent-decode and fragment fixes**, and emitting only
fragment-less links from paths with no spaces. Two lines smaller, and it leaves
a real defect in place — a link to a file with a space in its name has never
worked — while making this page's correctness depend on nobody naming a project
directory with a space in it.
