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
#                              resource bundle, so Bundle.module resolves)
#       Resources/man/man1/mark.1        <- M10, installed by packaging/mark.rb
#       Resources/completions/           <- M10, zsh/bash/fish
#
# M4 adds ADR-3's `mark://` to CFBundleURLTypes and registers the assembled
# bundle with LaunchServices, so `open -g -b dev.mark.app` — the CLI's
# cold-start path — resolves to *this* build rather than to some other copy of
# mark.app the user happens to have.
#
# M10 puts the man page and the shell completions in `Resources`, so the bundle
# is the single artifact both install paths read from: `packaging/mark.rb`
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
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>   <string>Markdown Document</string>
            <key>CFBundleTypeRole</key>   <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>net.daringfireball.markdown</string>
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

# The man page and the shell completions (M10). Copied rather than symlinked, so
# a bundle moved to /Applications carries its own documentation.
mkdir -p "${bundle}/Contents/Resources/man/man1" \
         "${bundle}/Contents/Resources/completions"
cp "${root}/packaging/mark.1" "${bundle}/Contents/Resources/man/man1/"
cp "${root}/packaging/completions/_mark" \
   "${root}/packaging/completions/mark.bash" \
   "${root}/packaging/completions/mark.fish" \
   "${bundle}/Contents/Resources/completions/"

# ...and SwiftPM's generated resource bundle, so `Bundle.module` resolves in the
# assembled app too. Belt and braces: it means the same asset lookup works under
# `swift run`, `swift test`, and here, with no build-configuration branch in the
# Swift code.
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
