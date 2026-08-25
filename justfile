# mark — a fast native markdown viewer for macOS.
# `just` with no args lists every recipe.
#
# This is the entry point for everything, matching the convention in the other
# repos: nobody should need to remember that this project will
# eventually have two toolchains.
#
# All ten milestones are implemented: the Rust core and headless CLI (M1), the
# AppKit shell and progressive rendering (M2), tabs (M3), CLI->app IPC (M4),
# checkbox write-back and the file watcher (M5), math and diagrams (M6), themes
# (M7), the full directory viewer (M8), the editing pane and autosave (M9), and
# packaging (M10). No recipe here is a placeholder for a later milestone.

set shell := ["bash", "-cu"]

adr_scripts := env_var('HOME') / ".claude/skills/adr-rpi/scripts"

# Show all recipes.
default:
    @just --list

# --- onboarding --------------------------------------------------------

# The whole onboarding story: asdf tools, then the git hook.
setup:
    asdf install
    pre-commit install
    @echo
    @echo "Rust is not asdf-managed: Cargo enforces the MSRV floor itself."
    @cargo --version
    @echo "Cargo will fail loudly if this is below the rust-version in Cargo.toml."

# Install the pre-commit git hook.
hooks:
    pre-commit install

# --- the one thing to run before pushing -------------------------------

# fmt-check + clippy + test + release build + swift test + ADR index check.
# What CI runs.
check: fmt-check lint test build-rust swift-test adr-check

# Formatting, without rewriting anything.
fmt-check:
    cargo fmt --check

# Reformat in place.
fmt:
    cargo fmt

# Clippy with warnings denied, across tests and benches too.
lint:
    cargo clippy --workspace --all-targets -- -D warnings

# The full Rust test suite.
test *args:
    cargo test --workspace {{args}}

# Two things this recipe carries that a bare `swift test` does not, both
# explained where they are defined:
#
#   * `--no-parallel`, because the MarkCore leak test measures process RSS,
#     which another suite allocating a WKWebView would pollute.
#   * the swift-testing framework search path and rpaths, because this machine
#     has Command Line Tools rather than a full Xcode and SwiftPM does not wire
#     swift-testing up in that configuration. Without them the generated test
#     runner compiles `#if canImport(Testing)` as false and the run reports
#     nothing, silently, with exit code 0. See app/Package.swift.
#
# The Swift test suite. Needs the core staticlib, so it builds that first.
swift-test *args: build-rust
    #!/usr/bin/env bash
    set -euo pipefail
    fw=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
    lib=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
    flags=()
    if [[ -d "${fw}" ]]; then
        flags=(-Xswiftc -F -Xswiftc "${fw}"
               -Xlinker -rpath -Xlinker "${fw}"
               -Xlinker -rpath -Xlinker "${lib}")
    fi
    cd app
    log=$(mktemp)
    trap 'rm -f "${log}"' EXIT
    set +e
    swift test --no-parallel "${flags[@]}" {{args}} 2>&1 | tee "${log}"
    status=${PIPESTATUS[0]}
    set -e
    # The failure mode this guards against is silent: without the flags above,
    # the generated runner compiles `#if canImport(Testing)` as false, runs
    # nothing, prints nothing, and exits 0. A green build that tested nothing is
    # worse than a red one.
    grep -qE 'Test run with [1-9][0-9]* tests' "${log}" || {
        echo "just swift-test: no tests were run — see app/Package.swift" >&2
        exit 1
    }
    exit "${status}"

# In `check` because the MSRV floor and any binary-size regression surface at
# release-profile link time, not in a debug build.
#
# Extra flags for `swift build`, overridden on the command line — empty here so
# the dev loop keeps SwiftPM's own sandbox:
#
#   just swift_build_flags=--disable-sandbox build
#
# `Formula/mark.rb` passes exactly that. Homebrew runs the whole install inside
# `sandbox-exec` and SwiftPM shells out to `sandbox-exec` again to compile
# `Package.swift`; sandboxes do not nest, so without the flag the build dies on
# `sandbox_apply: Operation not permitted` before compiling a line. It is a just
# variable rather than an environment variable on purpose — Homebrew's superenv
# scrubs the build environment down to an allowlist, so an exported
# `SWIFT_BUILD_FLAGS` never reaches the recipe (verified: it arrives empty).
swift_build_flags := ""

# Release build of the core staticlib and the CLI.
build-rust:
    cargo build --release

# --- running -----------------------------------------------------------

# The CLI, built in debug. `just cli render README.md --plain`
cli *args:
    cargo run -q -p mark-cli -- {{args}}

# Assemble mark.app from the two Mach-O executables (ADR-1).
build: build-rust
    cd app && swift build -c release {{swift_build_flags}}
    ./scripts/assemble-bundle.sh release

# The bundle's own Mach-O is exec'd directly rather than going through `open`,
# so stdout and OSLog land in this terminal. `open -b` is M4's cold-launch
# path, not the dev loop.
#
# Build and open mark.app on a file.
run FILE: build
    MARK_TRACE=1 ./target/mark.app/Contents/MacOS/mark "{{FILE}}"

# Cold start, warm start, the launch race, stale sockets, version skew, and
# the 104-byte sun_path trap — two real processes over a real socket (ADR-3).
#
# Needs the assembled bundle, so it builds first. It quits any mark that is
# already running: gate 1 is only a cold start if nothing is listening.
integration: _quit-app build
    ./scripts/integration.sh

# Quit a running mark before `build` replaces its bundle underneath it.
#
# Not hygiene: rebuilding `mark.app` while an instance is running leaves
# LaunchServices refusing to launch the new one for several seconds — `open`
# exits 0 and starts nothing — which makes gate 1 fail for a reason that has
# nothing to do with the socket. Reproduced deterministically; `mark-cli` also
# re-asks on its own (see `client.rs`), and this removes the cause rather than
# relying on the recovery.
_quit-app:
    @pkill -f 'mark\.app/Contents/MacOS/mark( |$)' 2>/dev/null || true

# VS Code's `code` trick, and plan §7's alternative to brew: one symlink from
# a directory already on PATH to the CLI inside the bundle. `mark-cli` resolves
# $0 through the symlink chain to find its enclosing .app (ADR-1), so the link
# is all it needs.
#
# Pass a prefix to override `brew --prefix`, e.g. `just install-cli ~/.local`.
#
# Symlink mark.app's mark-cli into <prefix>/bin/mark.
install-cli prefix="": build
    #!/usr/bin/env bash
    set -euo pipefail
    bundle="$(pwd)/target/mark.app"
    target="${bundle}/Contents/MacOS/mark-cli"
    prefix="{{prefix}}"
    if [[ -z "${prefix}" ]]; then
        prefix="$(brew --prefix 2>/dev/null || true)"
    fi
    if [[ -z "${prefix}" ]]; then
        echo "just install-cli: no Homebrew, so no default prefix." >&2
        echo "  Name one:  just install-cli ~/.local" >&2
        exit 1
    fi
    bin="${prefix}/bin"
    link="${bin}/mark"
    # Checked before writing, because the failure otherwise arrives as
    # "ln: /usr/local/bin/mark: Permission denied", which does not say what to
    # do about it. A Homebrew prefix the user does not own is the normal case
    # on an Intel Mac (/usr/local) and on a shared machine.
    if [[ ! -d "${bin}" ]]; then
        echo "just install-cli: ${bin} does not exist." >&2
        echo "  Create it, or name a different prefix: just install-cli ~/.local" >&2
        exit 1
    fi
    if [[ ! -w "${bin}" ]]; then
        echo "just install-cli: ${bin} is not writable by $(id -un)." >&2
        echo "  Either:  sudo ln -sfn '${target}' '${link}'" >&2
        echo "  or:      just install-cli ~/.local   (any writable prefix on your PATH)" >&2
        exit 1
    fi
    if [[ -e "${link}" && ! -L "${link}" ]]; then
        echo "just install-cli: ${link} exists and is not a symlink." >&2
        echo "  Refusing to replace a real file. Move it aside first." >&2
        exit 1
    fi
    ln -sfn "${target}" "${link}"
    echo "${link} -> ${target}"
    echo
    echo "The link points *into* the bundle, so it breaks if you move or delete"
    echo "${bundle}."
    echo "Rebuilding in place is fine — the path does not change."
    if [[ ":${PATH}:" != *":${bin}:"* ]]; then
        echo
        echo "NOTE: ${bin} is not on your PATH."
    fi
    echo
    echo "Man page and completions (the formula installs these for you):"
    echo "  man ${bundle}/Contents/Resources/man/man1/mark.1"
    echo "  zsh:  ln -sfn '${bundle}/Contents/Resources/completions/_mark' <a dir on \$fpath>/_mark"
    echo "  bash: source ${bundle}/Contents/Resources/completions/mark.bash"
    echo "  fish: ln -sfn '${bundle}/Contents/Resources/completions/mark.fish' ~/.config/fish/completions/mark.fish"

# Remove the symlink `install-cli` made. Same prefix rules.
uninstall-cli prefix="":
    #!/usr/bin/env bash
    set -euo pipefail
    prefix="{{prefix}}"
    if [[ -z "${prefix}" ]]; then
        prefix="$(brew --prefix 2>/dev/null || true)"
    fi
    link="${prefix}/bin/mark"
    if [[ -L "${link}" ]]; then
        rm "${link}"
        echo "removed ${link}"
    else
        echo "no symlink at ${link}"
    fi

# Convert tinted-theming base16 schemes into core/themes/*.toml.
#
# The output is committed, so this only runs when the roster changes. Pass
# `--schemes <dir>` (or set MARK_SCHEMES_DIR) to convert from a local clone
# instead of fetching; `--check` fails if the committed files are out of date.
#
# `tinted-theming/schemes` is MIT, so its YAML is parsed directly.
# `tinted-builder`, which would otherwise do the conversion, is GPL-3.0-only
# and would relicense this project — see the header of the script.
themes-import *args:
    python3 scripts/themes-import.py {{args}}

# --- versioning --------------------------------------------------------

# Set the workspace version, and Cargo.lock with it.
#
# The version is one number in `Cargo.toml` and everything downstream reads it:
# both crates inherit it, `scripts/assemble-bundle.sh` greps it into
# `CFBundleShortVersionString`, and `mark --version` and the About panel report
# it. What identifies an individual build is the *commit*, stamped by
# `core/build.rs` — so this is the deliberate marker ("that is a newer mark"),
# not the identifier.
#
#   just bump patch      0.2.0 -> 0.2.1
#   just bump minor      0.2.0 -> 0.3.0
#   just bump major      0.2.0 -> 1.0.0
#   just bump 0.4.2      exactly that
#
# Bump in the PR that changes behaviour, not in a release commit afterwards:
# a `--HEAD` tap has no releases to hang one on.
bump level="patch":
    #!/usr/bin/env bash
    set -euo pipefail
    current="$(grep -m1 '^version' Cargo.toml | cut -d'"' -f2)"
    IFS=. read -r major minor patch <<<"${current}"
    case "{{level}}" in
        major) next="$((major + 1)).0.0" ;;
        minor) next="${major}.$((minor + 1)).0" ;;
        patch) next="${major}.${minor}.$((patch + 1))" ;;
        [0-9]*.[0-9]*.[0-9]*) next="{{level}}" ;;
        *)
            echo "just bump: '{{level}}' is not major, minor, patch, or an X.Y.Z version." >&2
            exit 1 ;;
    esac
    # Anchored at the start of the line and applied once: the same three
    # numbers appear in `[workspace.package]` and could appear in a dependency
    # pin, and only the first is this project's own.
    /usr/bin/sed -i '' "1,/^version = /s/^version = \"${current}\"/version = \"${next}\"/" Cargo.toml
    # Cargo.lock records both crates' versions, and a lockfile left behind
    # fails `cargo build --locked` in CI rather than in the editor.
    cargo update --workspace --offline >/dev/null 2>&1 || cargo update --workspace >/dev/null
    echo "${current} -> ${next}"
    echo
    echo "Also update, if the version is quoted there:"
    echo "  Casks/mark.rb        version"
    echo "  packaging/mark.1     the .TH line"
    grep -rn "${current}" Casks packaging skills 2>/dev/null | sed 's/^/  /' || true

# What this build is: version, commit, and commit date.
version: build-rust
    @./target/release/mark-cli --version

# --- measurement -------------------------------------------------------

# Generate the corpus if needed, then check the committed perf thresholds.
bench: bench-core bench-app

# Core-side budget: parse, highlight, render, CLI startup.
bench-core:
    ./scripts/bench.sh

# It puts a window on screen and activates the app on purpose:
# requestAnimationFrame is throttled when the window is not frontmost, which
# hung an earlier research harness.
#
# ADR-2's gate (first paint, scroll anchor), ADR-4's (24 tabs, switch latency,
# accessibility tree, dehydration, session), and M8's (bounded directory reads
# while navigating a real 608k-file tree, progressive badges, the filter, and
# reveal), then the session round trip across a real quit and relaunch — which
# is where root, breadcrumb, and history are checked against a real process
# restart rather than an in-process one.
#
# M8's section navigates `~/src` by default; `MARK_BENCH_TREE=<dir>` points
# it somewhere else, and `MARK_BENCH_SIDEBAR_SNAPSHOT=<file.png>` moves the
# sidebar snapshot off its `target/mark-sidebar.png` default.
bench-app: build-rust
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ ! -f bench/corpus/1mb.md ]]; then
        echo "generating corpus..."
        python3 scripts/gen-corpus.py
    fi
    if [[ ! -f bench/corpus/format.classed.html ]]; then
        echo "generating the class-vs-inline highlighting pair..."
        (cd bench/highlight-format && cargo run --release -q -- ../corpus/1mb.md ../corpus/format)
    fi
    (cd app && swift build -c release {{swift_build_flags}} --product mark-bench --product mark)
    # Both gates run even if the first fails. A memory regression hiding the
    # session round trip would mean fixing one thing and discovering the next
    # only on the following run.
    status=0
    ./app/.build/release/mark-bench bench/corpus/1mb.md || status=$?
    echo
    ./scripts/session-roundtrip.sh ./app/.build/release/mark || status=$?
    exit "${status}"

# Regenerate the benchmark corpus (gitignored; the generator is committed).
corpus *args:
    python3 scripts/gen-corpus.py {{args}}

# --- ADR corpus --------------------------------------------------------

# Regenerate INDEX.md and validate the supersession chain.
adr: _adr-tools-present
    python3 "{{adr_scripts}}/adr_index.py" docs/adrs
    python3 "{{adr_scripts}}/adr_chain.py" docs/adrs --validate

# Same, but fail on a stale INDEX.md instead of regenerating it.
adr-check: _adr-tools-present
    python3 "{{adr_scripts}}/adr_index.py" docs/adrs --check
    python3 "{{adr_scripts}}/adr_chain.py" docs/adrs --validate

# The corpus tooling lives in the adr-rpi skill, not in this repo. Say so
# plainly rather than failing with "No such file or directory".
_adr-tools-present:
    @test -f "{{adr_scripts}}/adr_index.py" || { \
        echo "ADR tooling not found at {{adr_scripts}} — install the adr-rpi skill." >&2; \
        exit 1; }

# --- diagnostics -------------------------------------------------------

# Shadowing is the failure this exists to make visible: an asdf shim that
# resolves to a different binary than the pin says is otherwise silent.
#
# Toolchain versions, asdf-resolved vs actually-resolved, plus core state.
doctor:
    #!/usr/bin/env bash
    set -uo pipefail
    printf '%-14s %s\n' "tool" "resolved"
    printf '%-14s %s\n' "----" "--------"
    for tool in just pre-commit; do
        pinned=$(grep -E "^${tool} " .tool-versions | awk '{print $2}')
        actual=$(command -v "${tool}" >/dev/null 2>&1 && "${tool}" --version 2>&1 | head -1 || echo "MISSING")
        printf '%-14s pinned %-10s resolved %s\n' "${tool}" "${pinned}" "${actual}"
        printf '%-14s path     %s\n' "" "$(command -v "${tool}" || echo '-')"
    done
    printf '%-14s %s\n' "rustc" "$(rustc --version 2>&1)"
    printf '%-14s %s\n' "cargo" "$(cargo --version 2>&1)"
    printf '%-14s %s\n' "msrv" "$(grep -m1 '^rust-version' Cargo.toml | cut -d'"' -f2) (Cargo.toml)"
    echo
    echo "core:"
    cargo run -q -p mark-cli -- doctor
    echo
    echo "The socket path, its length against ADR-3's 104-byte limit, the .app"
    echo "resolved from \$0, and whether the app is running are in the report above."

clean:
    cargo clean
    rm -rf bench/corpus
