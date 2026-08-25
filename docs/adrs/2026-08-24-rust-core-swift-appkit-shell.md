---
id: 2026-08-24-rust-core-swift-appkit-shell
status: Accepted
supersedes: null
superseded-by: null
components: [core, app, cli]
ticket: null
date: 2026-08-24
---
# Build the document core in Rust and the shell in Swift/AppKit, joined by a small C ABI

## Context

`mark` is a new macOS-only markdown viewer with two first-class consumers of the
same logic: a GUI app, and a CLI that must be fast enough for an agent to call in
a loop. Nothing about the stack was settled, so we measured the candidates on the
target machine (macOS 26.6.2, arm64, Swift 6.3.3, rustc 1.86.0) against a
generated corpus of 8 KB / 256 KB / 1 MB / 8 MB documents with a realistic
construct mix.

Markdown parsing, ms per document:

| Document | `pulldown-cmark` | Apple `swift-markdown` |
|---|---|---|
| 8 KB | 0.045 | 0.636 (14×) |
| 256 KB | 0.603 | 15.51 (26×) |
| 1 MB | 2.15 | 60.08 (28×) |
| 8 MB | 18.35 | 497.15 (27×) |

Two facts mattered more than the ratio. First, `swift-markdown` ships **no HTML
emitter** — choosing it means owning a renderer over its tree. Second, and
decisive: clicking a checkbox requires mapping a DOM element back to an exact
byte span in the file. `pulldown-cmark`'s `into_offset_iter()` yields a byte
`Range` with every event, so capturing spans for all 2,002 checkboxes in the 1 MB
document costs **2.04 ms** — the same as a bare parse. The `swift-markdown`
equivalent costs **154 ms**. `comrak` was also rejected here: it exposes only
line:column, and its own documentation calls sourcepos unreliable for lists and
list items, which is exactly where task lists live.

CLI startup, 100 sequential invocations of a subcommand-dispatching binary:

| CLI | Binary | ms/invocation | Overhead over `exec` floor |
|---|---|---|---|
| Rust + `clap` 4 | 568 KB | 2.84 | ~0.6 ms |
| Swift + `swift-argument-parser` 1.4 | 1,639 KB | 8.04 | ~5.8 ms |
| `/bin/echo` (floor) | 101 KB | 2.28 | — |

The objection to a two-language design was the FFI boundary. We built it to find
out: a Rust `staticlib` exposing a five-function C API, linked into a Swift binary
via `-import-objc-header`. A full round trip including allocation, free, and the
Rust→Swift `String` copy measured **0.0007 ms (700 ns)**. The resulting Swift
binary with the core statically linked is 666 KB, and the `.app` bundle 684 KB
with no bundled runtime. Cold start to a visible rendered document is ~270 ms,
almost all of it process launch and WebKit spin-up.

The counter-option was a Rust-only shell (Tauri/`wry`), and we did not benchmark
it. At the time of evaluation `wry 0.52` would not build: it pulls `icu_*@2.3`,
requiring rustc ≥ 1.88 against a local Homebrew 1.86.

**That particular obstacle has since gone away** — the toolchain was subsequently
upgraded to 1.98.0 for unrelated reasons (see
`2026-08-24-rust-side-math-and-diagrams`), so `wry` would now build. The MSRV wall
is therefore *not* part of this decision's justification, and a reader should not
treat it as one. What remains, and what the rejection actually rests on: Tauri
renders in the same `WKWebView`, so it inherits every layout cost identically;
`cargo tree` reports 166 crates for a minimal `wry`+`tao` window; and native
chrome — window tabbing, `NSOutlineView`, system appearance — is AppKit API that
Tauri would have to reimplement. The user's requirement is explicitly "a mac
tool", so cross-platform portability has no value here. Those three grounds are
sufficient, but they are arguments rather than measurements, and if the shell
choice is ever revisited a real Tauri benchmark is now cheap to run.

Worth recording plainly: parser choice is **not** what makes this app fast. On a
1 MB document, Rust-over-Swift saves 58 ms, while syntax-highlighting strategy is
worth 98 ms and HTML-injection strategy 123 ms. The core is in Rust for the CLI
and the byte ranges, not for the parse.

## Decision

We build the document core as a Rust library (`pulldown-cmark` for parsing,
`syntect` for highlighting) and the GUI shell in Swift with AppKit, linking the
core into both the app and a Rust CLI binary.

The core is compiled as a `staticlib` and consumed from Swift through a small,
hand-written C ABI — flat functions taking and returning C strings, with a single
`mark_free` for every pointer the core hands out. No binding generator.

We ship **two Mach-O executables** in `mark.app/Contents/MacOS/`: `mark` (the
AppKit app) and `mark-cli` (the Rust CLI). `mark-cli` resolves `$0` through its
symlink chain to locate the enclosing `.app`, so it works when invoked from
`/opt/homebrew/bin`.

The core owns the checkbox contract. Rendered HTML carries each task marker's
byte span on the element itself:

```html
<input type="checkbox" class="mk-task" data-mk-idx="1"
       data-mk-start="14" data-mk-end="17" checked>
```

Toggling is a byte-range in-place edit of the character between the brackets,
exposed as one core function used identically by a GUI click and by
`mark-cli check`. Verified on a fixture containing `[x]`, `[ ]`, an ordered-list
task, and a literal `[ ]` in prose: a single byte changes, the file round-trips
byte-for-byte, and the prose bracket is untouched. Cost on a 1 MB file: 3.07 ms.

## Consequences

**Easier.** One implementation of parsing, highlighting, checkbox semantics, and
directory queries, shared by both consumers — the CLI cannot drift from the GUI
because there is no second implementation to drift. The CLI is genuinely fast
enough for loop invocation. Byte-range source mapping, the feature the product is
built around, is nearly free.

**Harder, and we are accepting it.** Two toolchains in the build: contributors
need both Rust and Xcode, and CI must build and link both. A `cargo build` cannot
produce a runnable app on its own, and `swift build` cannot either — the real
build is a script that does both and assembles the bundle. Debugging across the
ABI means lldb showing you a C frame in the middle of a Swift stack; a Rust panic
crossing the boundary is undefined behavior, so every `extern "C"` function must
be panic-safe at its edge.

**Mac-only, permanently.** AppKit is not portable. Choosing this forecloses
Linux and Windows without a shell rewrite. That is a deliberate response to the
stated requirement, not an oversight.

Constraints this imposes on future work:

- **The C ABI stays small and string-shaped.** New capability is a new flat
  function, not a struct crossing the boundary. If the surface grows past roughly
  a dozen functions or needs to pass structured data, that is a signal to
  reconsider, via a superseding ADR rather than by smuggling a struct across.
- **Every pointer the core returns is freed with `mark_free`.** No other
  deallocation path.
- **No `extern "C"` function may unwind.** Catch at the boundary and return an
  error sentinel.
- **The core never imports AppKit and never assumes a GUI.** Anything the app
  needs and the CLI cannot use belongs in Swift, not in the core.
- **`Cargo.toml` pins `rust-version`,** so a dependency that raises the MSRV
  fails loudly rather than mysteriously. The value is set by
  `2026-08-24-rust-side-math-and-diagrams`, not here.
- **Checkbox identity is `(file, task-index)` in document order,** and the byte
  span is authoritative. Anything that reorders tasks invalidates indices held
  across an edit.

**Unmeasured, and stated as such:** the Tauri comparison rests on transferable
evidence and reasoning, not on a benchmark — and its one measured fact, the MSRV
wall, has since been invalidated by the toolchain upgrade. Settling it properly
now costs about thirty minutes and no toolchain work.

## Alternatives considered

- **All Swift (`swift-markdown` + SwiftUI/AppKit).** One toolchain, one language,
  simplest build. Rejected on measurements: 27× slower parsing, 76× slower source
  mapping, no HTML emitter, and a CLI with ~10× the per-invocation overhead. The
  source-mapping gap alone disqualifies it, since checkbox interaction is a
  headline feature.
- **All Rust (Tauri or `wry` + `tao`).** One toolchain, cross-platform optionality.
  Rejected: no value from portability for an explicitly mac-only tool, 166 crates
  for a bare window, a dependency tree that already exceeds the local MSRV, the
  same `WKWebView` layout costs, and native tabs/sidebar/appearance reduced to
  hand-built imitations.
- **Rust core exposed to Swift via a generated binding layer (`uniffi`,
  `cbindgen`, `swift-bridge`).** Rejected as unnecessary weight: the surface is
  five string-returning functions, and a hand-written header is smaller than the
  generator's configuration. Reconsider if the ABI ever outgrows the constraint
  above.
- **Rust core as a dynamic library.** Rejected: static linking keeps the bundle a
  single self-contained binary per executable, avoids `@rpath` setup and
  per-dylib codesigning during notarization, and the 2.0 MB `.a` costs nothing
  meaningful.
- **Node/Electron.** Rejected outright against "very fast" and "lightweight": a
  bundled Chromium is ~10× our measured bundle before any code is written.
