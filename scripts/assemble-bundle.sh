#!/usr/bin/env bash
#
# Assemble mark.app. Run with `just build`.
#
# ADR-1 (2026-08-24-rust-core-swift-appkit-shell) puts **two Mach-O
# executables** in one bundle: `mark`, the AppKit app built by SwiftPM, and
# `mark-cli`, the Rust CLI built by cargo. Neither toolchain can produce a
# runnable app on its own, which is exactly the cost that ADR's Consequences
# section accepts — this script is that cost, made explicit and repeatable
# instead of living in someone's shell history.
#
#   mark.app/
#     Contents/
#       Info.plist
#       MacOS/mark          <- swift build -c release
#       MacOS/mark-cli      <- cargo build --release
#       Resources/          <- shell.html, shell.js, shell.css (+ the SwiftPM
#                              resource bundle, found via Bundle.main.resourceURL)
#       Resources/man/man1/mark.1        <- M10, installed by Formula/mark.rb
#       Resources/completions/           <- M10, zsh/bash/fish
#
# M4 adds ADR-3's `mark://` to CFBundleURLTypes and registers the assembled
# bundle with LaunchServices, so `open -g -b dev.mark.app` — the CLI's
# cold-start path — resolves to *this* build rather than to some other copy of
# mark.app the user happens to have.
#
# M10 puts the man page and the shell completions in `Resources`, so the bundle
# is the single artifact both install paths read from: `Formula/mark.rb`
# installs them out of it, and `just install-cli` points at them for anyone not
# using brew. They are documentation of the CLI that ships *next to* the CLI,
# which is why they live in the bundle rather than only in `packaging/`.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"

configuration="${1:-release}"
bundle="${root}/target/mark.app"
bundle_id="dev.mark.app"
version="$(grep -m1 '^version' "${root}/Cargo.toml" | cut -d'"' -f2)"

# The same provenance `core/build.rs` stamps into the two Mach-O binaries, in
# the plist as well. Both come from one checkout in one run of this script, so
# they agree by construction — and Finder's Get Info, `mdls`, and anything else
# that reads a bundle without launching it can then answer "which build is
# this?" too. Overridable for a build from a tarball with no `.git`.
commit="${MARK_BUILD_COMMIT:-$(git -C "${root}" rev-parse --short=7 HEAD 2>/dev/null || echo unknown)}"
if [[ -z "${MARK_BUILD_COMMIT:-}" && -n "$(git -C "${root}" status --porcelain 2>/dev/null)" ]]; then
    commit="${commit}-dirty"
fi
build_date="${MARK_BUILD_DATE:-$(git -C "${root}" log -1 --date=format:%Y-%m-%d --format=%cd 2>/dev/null || echo unknown)}"

swift_bin="${root}/app/.build/${configuration}/mark"
cli_bin="${root}/target/${configuration}/mark-cli"

for binary in "${swift_bin}" "${cli_bin}"; do
    if [[ ! -x "${binary}" ]]; then
        echo "assemble-bundle.sh: ${binary} is missing." >&2
        echo "  Build both toolchains first: cargo build --${configuration} && (cd app && swift build -c ${configuration})" >&2
        exit 1
    fi
done

rm -rf "${bundle}"
mkdir -p "${bundle}/Contents/MacOS" "${bundle}/Contents/Resources"

cat >"${bundle}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>mark</string>
    <key>CFBundleDisplayName</key>     <string>mark</string>
    <key>CFBundleIdentifier</key>      <string>${bundle_id}</string>
    <key>CFBundleExecutable</key>      <string>mark</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${version}</string>
    <key>CFBundleVersion</key>         <string>${version}</string>
    <!--
      Names \`Resources/mark.icns\` (the extension is optional and conventionally
      omitted). Without this the Dock, Finder, the ⌘-Tab switcher and the About
      panel all draw the generic application icon — which is what \`open
      README.md\` showed for every build up to this one.
    -->
    <key>CFBundleIconFile</key>        <string>mark</string>
    <!--
      Not Apple keys, and deliberately not folded into CFBundleVersion:
      Homebrew's cask machinery and LaunchServices both compare that as a
      version number, and "0.2.0+f63a7ca" is not one. The App's About panel
      reads its build string out of the linked core instead (AppDelegate); these
      are for everything that inspects a bundle without launching it.
    -->
    <key>MarkBuildCommit</key>         <string>${commit}</string>
    <key>MarkBuildDate</key>           <string>${build_date}</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <!--
      ADR-3 (2026-08-24-cli-app-unix-socket-ipc). The socket is the primary
      transport, and this stays registered anyway:

        > \`mark://\` stays registered even if the socket becomes the only
        > transport used in practice — it is the cold-launch and Finder path.

      Note the scheme is \`mark\`, not the \`mark-asset\` the shell's own
      assets are served over. That split is deliberate and M2 made it: a
      WKURLSchemeHandler registered for \`mark\` would shadow this LaunchServices
      registration inside the web view.
    -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>    <string>${bundle_id}.command</string>
            <key>CFBundleTypeRole</key>   <string>Viewer</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>mark</string>
            </array>
        </dict>
    </array>
    <!--
      Two entries, where there used to be one covering both types.

      The split is required rather than tidy: \`CFBundleTypeIconFile\` attaches
      to the *entry*, so a single entry naming both types would put the markdown
      document icon on every .txt file on the machine.

      \`LSHandlerRank\` is now explicit on both. It was absent before, which
      LaunchServices reads as \`Default\` — so mark was quietly claiming to be
      the preferred opener for **all plain text**. Markdown keeps that claim,
      which is the status quo written down and is what the app is for;
      plain text drops to \`Alternate\`, which narrows an over-claim rather than
      changing what mark can open. An explicit user choice in Finder still wins
      over both.
    -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>     <string>Markdown Document</string>
            <key>CFBundleTypeRole</key>     <string>Viewer</string>
            <key>CFBundleTypeIconFile</key> <string>mark-document</string>
            <key>LSHandlerRank</key>        <string>Default</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>net.daringfireball.markdown</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>   <string>Plain Text Document</string>
            <key>CFBundleTypeRole</key>   <string>Viewer</string>
            <key>LSHandlerRank</key>      <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.plain-text</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

cp "${swift_bin}" "${bundle}/Contents/MacOS/mark"
cp "${cli_bin}" "${bundle}/Contents/MacOS/mark-cli"

# The shell assets, flat in Resources. `ShellAssets.data(named:)` looks in
# Bundle.main first, so this is the path the shipped app takes.
cp "${root}/app/Resources/shell.html" \
   "${root}/app/Resources/shell.js" \
   "${root}/app/Resources/shell.css" \
   "${bundle}/Contents/Resources/"

# The two icons, named by `CFBundleIconFile` and by the markdown document type's
# `CFBundleTypeIconFile`. Committed artifacts, like the man page below — drawn
# by `scripts/make-icons.swift` and regenerated with `just icons`, not built
# here.
cp "${root}/packaging/mark.icns" \
   "${root}/packaging/mark-document.icns" \
   "${bundle}/Contents/Resources/"

# The man page and the shell completions (M10). Copied rather than symlinked, so
# a bundle moved to /Applications carries its own documentation.
mkdir -p "${bundle}/Contents/Resources/man/man1" \
         "${bundle}/Contents/Resources/completions"
cp "${root}/packaging/mark.1" "${bundle}/Contents/Resources/man/man1/"
cp "${root}/packaging/completions/_mark" \
   "${root}/packaging/completions/mark.bash" \
   "${root}/packaging/completions/mark.fish" \
   "${bundle}/Contents/Resources/completions/"

# ...and SwiftPM's generated resource bundle, as a second copy of the same three
# assets. `ShellAssets` finds it here through `Bundle.main.resourceURL`, which is
# what makes one asset lookup work under `swift run`, `swift test`, and here,
# with no build-configuration branch in the Swift code.
#
# Note that plain `Bundle.module` would *not* find it here. SwiftPM's generated
# accessor looks at `Bundle.main.bundleURL/Mark_MarkKit.bundle` — the root of the
# .app, not `Contents/Resources` — and at the absolute `.build` path of whatever
# machine compiled the binary, and calls `fatalError` when both miss. Copying to
# the .app root instead would satisfy it, at the cost of an unsealed file outside
# `Contents/`; `ShellAssets.moduleBundle` does the lookup by hand instead.
resource_bundle="${root}/app/.build/${configuration}/Mark_MarkKit.bundle"
if [[ -d "${resource_bundle}" ]]; then
    cp -R "${resource_bundle}" "${bundle}/Contents/Resources/"
fi

# Ad-hoc signature. ADR-3 requires the app to work with no Developer ID: dev
# builds must behave identically to released ones, so there is no class of bug
# that only appears unsigned.
codesign --force --sign - --timestamp=none "${bundle}" >/dev/null 2>&1 ||
    echo "assemble-bundle.sh: codesign --sign - failed; the app will still run locally" >&2

# Tell LaunchServices about this bundle, so `open -b dev.mark.app` and
# `mark://` resolve here. Without it, the CLI's cold-start path (ADR-3) can
# launch a different copy of mark.app — or nothing at all on a machine that has
# never seen one.
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "${lsregister}" ]]; then
    "${lsregister}" -f "${bundle}" ||
        echo "assemble-bundle.sh: lsregister failed; 'mark open' may launch a different mark.app" >&2
fi

size="$(du -sh "${bundle}" | cut -f1)"
echo "assembled ${bundle} (${size}, ${configuration})"
