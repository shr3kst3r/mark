# Homebrew *cask* for mark — the alternative to Formula/mark.rb.
#
# This file lives in `Casks/` because that is the only directory a tap's casks
# are read from; anywhere else and `brew install --cask` reports that no cask
# with the name exists.
#
# Use this one only if you want the app in /Applications the way a cask does it.
# It installs a prebuilt bundle rather than compiling, which means the artifact
# CAN pick up a `com.apple.quarantine` xattr — and `--no-quarantine` was removed
# in Homebrew 4.7, so the `postflight` below strips it instead. That is a
# deliberate workaround, not a clean path; the formula avoids the problem
# entirely by building locally.
#
#   just build && ditto -c -k --keepParent target/mark.app target/mark.zip
#   brew tap shr3kst3r/mark https://github.com/shr3kst3r/mark
#   MARK_ZIP="$PWD/target/mark.zip" brew install --cask shr3kst3r/mark/mark
#
cask "mark" do
  # Kept in step with `Cargo.toml` by hand — `just bump` prints a reminder.
  # It is not what makes an install identifiable: the commit stamped into the
  # bundle by `scripts/assemble-bundle.sh` is (`MarkBuildCommit` in Info.plist,
  # the About panel, `mark doctor`). Homebrew never compares this to anything,
  # because the sha256 below is `:no_check`.
  version "0.4.0"

  # A locally built artifact has no stable checksum across rebuilds.
  # `:no_check` is correct here and would be rejected by homebrew-cask upstream —
  # which is fine, since this is never going upstream.
  sha256 :no_check

  # There is no published release artifact, so the zip is the one you just built
  # with `ditto`. `MARK_ZIP` says where it is; the default assumes the checkout
  # is next to this file, which holds when you tapped a local checkout and is
  # wrong when you tapped the GitHub remote — hence the env var.
  url "file://#{ENV.fetch("MARK_ZIP", "#{__dir__}/../target/mark.zip")}"
  name "mark"
  desc "Fast native macOS markdown viewer with a scriptable CLI"
  homepage "https://github.com/shr3kst3r/mark"

  # A bare symbol, not `">= :sonoma"`: a cask's `depends_on macos:` parses with
  # a `>=` comparator already, and the string form is deprecated — it made every
  # load of this file print Homebrew's "report this issue to the tap" warning.
  depends_on macos: :sonoma

  app "mark.app"

  # Two Mach-Os ship in the bundle (ADR-1). `binary` symlinks rather than moves,
  # which is what the Cask Cookbook prescribes for a binary inside an app bundle.
  binary "#{appdir}/mark.app/Contents/MacOS/mark-cli", target: "mark"

  # M10 ships the man page inside the bundle, so `man mark` works on this path
  # too. Shell completions have no cask stanza; the caveat below says where they
  # are. That asymmetry is one more reason the formula is the recommended path.
  manpage "#{appdir}/mark.app/Contents/Resources/man/man1/mark.1"

  postflight do
    # Ad-hoc signed + quarantined = "damaged and can't be opened", and macOS Tahoe
    # removed the right-click-Open override for that case. Stripping the xattr is
    # the only local remedy.
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/mark.app"],
                   sudo: false
  end

  caveats <<~EOS
    Shell completions are inside the bundle; a cask has no stanza for them:

      zsh:  ln -sfn "#{appdir}/mark.app/Contents/Resources/completions/_mark" \
              "$(brew --prefix)/share/zsh/site-functions/_mark"
      bash: source "#{appdir}/mark.app/Contents/Resources/completions/mark.bash"
      fish: ln -sfn "#{appdir}/mark.app/Contents/Resources/completions/mark.fish" \
              ~/.config/fish/completions/mark.fish
  EOS

  # `Session.defaultURL` writes to Application Support/**mark**, not to the
  # bundle id — it is our own JSON file (ADR-4), not a preferences domain. The
  # themes directory is under ~/.config because it is user-editable (M7), and it
  # is listed here because `zap` means "leave nothing behind"; a user with
  # hand-written themes should back them up before zapping.
  zap trash: [
    "~/Library/Application Support/mark",
    "~/.config/mark",
    "~/Library/Preferences/dev.mark.app.plist",
    "~/Library/Saved Application State/dev.mark.app.savedState",
  ]
end
