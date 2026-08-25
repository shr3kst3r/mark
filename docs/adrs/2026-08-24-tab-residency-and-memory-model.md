---
id: 2026-08-24-tab-residency-and-memory-model
status: Accepted
supersedes: [2026-08-24-single-window-custom-tab-bar]
superseded-by: null
components: [app, tabs, sidebar]
ticket: null
date: 2026-08-24
---
# Keep one window and a custom tab bar, but hold only 3 web views resident — a tab costs ~52 MB, not ~1.2 MB

## Context

`2026-08-24-single-window-custom-tab-bar` chose one window, a hand-built tab bar,
a shared sidebar, and N resident `WKWebView`s with MRU dehydration at 20. Its
Context claimed, from research §2.7:

> WebKit coalesces same-configuration web views into a single WebContent
> process, so 24 views stayed at 2 processes total … ~1.2 MB marginal per tab.

**That measurement was wrong, and M3 proved it.** On macOS 26.6.2 every
`WKWebView` gets its own WebContent process, and each costs ~52 MB.

**How the error arose, because it is instructive.** The research benchmark summed
RSS by walking the process subtree from its own pid via `ppid`. But WebKit's
content processes are launched by launchd, so **their parent pid is 1, not the
app.** Verified directly:

```
$ ps -axo pid=,ppid=,rss=,comm= | grep WebKit.WebContent
  pid 2315   parent 1     5.4 MB
  pid 2318   parent 1    24.0 MB
  pid 18337  parent 1     7.5 MB
```

A subtree walk from the app's pid structurally cannot see any of them. What it
did measure — the app process growing ~1.2–1.8 MB per resident view — is real and
reproduces exactly; it is simply not the cost that matters. "2 processes" is
likewise what you count if you see GPU and Networking and miss WebContent.

M3 re-measured with a standalone probe containing none of our code, 24 bare web
views on one shared `WKWebViewConfiguration`, cross-checked against system-wide
`vm_statistics64` across a teardown:

| views | new WebContent processes | sum of `phys_footprint` |
|---|---|---|
| 1 | 1 | 100.5 MB |
| 8 | 8 | 365.0 MB |
| 24 | **24** | **969.0 MB** |

Releasing 23 extra views returned ~909 MB to the machine — ~39.5 MB each,
agreeing with `phys_footprint` and refuting ~1.2 MB. `WKProcessPool` sharing was
also tested and does not coalesce; the API is documented as "no longer has any
effect."

Measured cost of the shipped design, tab bar and sidebar included:

| resident limit | WebContent processes | total footprint |
|---|---|---|
| 24 | 24 | 1,386.6 MB |
| 20 (the superseded default) | 20 | 1,158.3 MB |
| 12 | 12 | 737.6 MB |
| 6 | 6 | 421.9 MB |
| 3 | 3 | 263.8 MB |
| 1 | 1 | 152.2 MB |

Two consequences follow. First, the superseded ADR's ≤110 MB gate is
**unreachable by any `WKWebView` design** — the floor with a single resident tab
is 152 MB. Second, its reason for rejecting the single-reused-view alternative —
that resident views cost *"about 8 MB more at 24 tabs"* — is false by two orders
of magnitude. The real difference at the old default is ~1.0 GB.

What does *not* change is everything the superseded ADR got right, and M3
confirmed each: switching a resident tab is 0.0001 ms (show/hide) and 0.325 ms
end-to-end; the shared sidebar argument against native `NSWindow` tabbing stands;
and the tab bar, badges, drag-reorder, overflow, accessibility tree, and session
restore all work.

The number that rescues the architecture is **rehydration: 4.690 ms** to
reallocate a web view, re-render, and restore scroll. That is imperceptible. So
the design survives; only the residency default was derived from the bad figure.
The superseded ADR even said so: *"20 is a starting point derived from ~1.2 MB
per tab, not a measured optimum."* The derivation is precisely what was wrong.

An untried option is noted rather than pursued: the `_relatedWebView` SPI would
likely restore one-process behaviour. Shipping SPI is a decision in its own right
and is not made here.

## Decision

We keep the architecture of the superseded ADR unchanged: **one `NSWindow`, one
`NSWindowController`, a hand-built tab bar, a shared sidebar, resident
`WKWebView`s with MRU dehydration, and session state in our own JSON file.**
Native `NSWindow` tabbing stays rejected, for the shared-sidebar reason.

What changes is the residency model, now derived from measurement:

- **The resident working set defaults to 3, not 20.** Current tab plus the two
  most recently used switch in 0.0001 ms; everything beyond rehydrates in
  ~4.7 ms. Overridable at runtime via `MARK_RESIDENT_TABS`.
- **A tab costs ~52 MB while resident**, and this is the number any future
  decision about tab residency must use.
- **The memory budget is stated as a formula, not a constant:**
  `~100 MB baseline + ~52 MB × resident tabs`. At the default that is ~264 MB.
- **`mark doctor` reports WebContent process count and total footprint**, so the
  real cost is visible rather than inferred from a subtree walk.

Benchmarks that measure process memory **must count `com.apple.WebKit.WebContent`
processes system-wide and attribute them by launch delta**, never by walking the
app's process subtree.

## Consequences

**Easier.** The memory model is now measured rather than assumed, and stated as a
formula so the next person can compute the cost of a change instead of
rediscovering it. At the new default the app uses ~264 MB rather than ~1.16 GB — a
~900 MB reduction for a 4.7 ms cost on tabs the user is not currently looking at.

**Harder, and we are accepting it.**

- **Switching to a non-resident tab now costs ~4.7 ms instead of 0.0001 ms.**
  Imperceptible, but no longer free, and it will show up as a hitch on a very
  slow machine or a very large document.
- **~264 MB is the honest cost of this app**, well above the ~61 MB figure
  previously accepted — which came from the same flawed measurement and was
  never real. The true single-tab floor is ~152 MB. Anyone who agreed to "61 MB"
  agreed to a number that did not exist.
- **A user with many dirty tabs pays full residency**, because
  `2026-08-24-editing-pane-and-autosave` forbids dehydrating unsaved work. At
  ~52 MB per tab that is now a much sharper constraint than when it was written
  against ~1.2 MB. Ten dirty tabs is ~620 MB.
- **The WKWebView-versus-native-text question reopens.** Research §4 flagged
  TextKit 2 as the unexplored alternative and deferred it on the strength of the
  memory figure. That figure was wrong by ~40×. This ADR does not reopen it —
  M2 is built and its rendering gates pass — but a future reader should know the
  comparison was made against a bad number.

Constraints this imposes on future work:

- **Any feature that holds a `WKWebView` resident must budget ~52 MB for it**,
  and say so where the decision is recorded.
- **Never measure process memory by walking the app's process subtree.** WebKit's
  content processes are children of launchd. This is the error that produced the
  superseded ADR.
- **The resident limit stays a runtime tunable**, never a compile-time constant.
- Everything else the superseded ADR constrained still holds: exactly one window
  and one window controller; never `addTabbedWindow`; `tabbingMode` stays
  `.disallowed`; all web views share one `WKWebViewConfiguration`; no feature may
  assume a tab's web view exists; session state is our own file and
  `NSQuitAlwaysKeepsWindows` is never written.

## Alternatives considered

- **Keep the default at 20.** No code change. Rejected: ~1.16 GB for a markdown
  viewer, and the superseded ADR's own text calls 20 a starting point derived
  from the figure now known to be wrong.
- **A single reused web view** (resident limit 1, ~152 MB). Now far more
  attractive than when it was rejected at "8 MB more" — the real saving over the
  old default is ~1.0 GB. Rejected only because 3 costs ~112 MB more and makes
  the common flip between two or three documents genuinely instant. This is the
  closest call in this ADR, and a 1 is a defensible setting rather than a wrong
  one — `MARK_RESIDENT_TABS=1` gets it.
- **A memory-pressure-driven limit** (`DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`,
  evict under pressure). Genuinely better behaviour and not foreclosed. Rejected
  for now as unnecessary at ~264 MB steady state; worth doing if residency ever
  becomes adaptive.
- **The `_relatedWebView` SPI** to coalesce content processes. Would plausibly
  restore something near the original assumption. Rejected: shipping SPI risks
  breaking on any macOS update, and it is a decision that deserves its own record
  rather than being smuggled in as a memory fix.
- **Abandon `WKWebView` for TextKit 2 rendering.** The measurement that deferred
  this was wrong by ~40×, so the comparison deserves redoing. Rejected here
  because M2 is built and passing, and rewriting the renderer to fix a residency
  default would be a far larger change than lowering a tunable.
