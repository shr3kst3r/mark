# Homebrew *formula* for mark — builds from source on your machine.
#
# This is deliberately a formula and not a cask. Locally built code never gets a
# `com.apple.quarantine` xattr, so Gatekeeper is never consulted: no Developer ID,
# no notarization, no "damaged and can't be opened", and nothing to strip after
# install. A cask that downloads a prebuilt artifact would be quarantined, and
# `--no-quarantine` was removed in Homebrew 4.7.
#
# Head-only, on purpose. There is no release tarball to point a stable `url` at,
# and this is never going to a public tap — so every install is `--HEAD`:
#
#   brew tap shr3kst3r/mark /path/to/your/mark
#   brew install --HEAD shr3kst3r/mark/mark
#
# Or straight from the file, without a tap:
#
#   brew install --HEAD ./packaging/mark.rb
#
# **`--HEAD` builds what is committed, not what is in your working tree.** Both
# forms clone the repo at `head` into Homebrew's cache and build that clone, so
# uncommitted work is invisible to them — including, at the time of writing,
# effectively all of it. Until the tree is committed, use `just build` plus
# `just install-cli`; `packaging/README.md` spells that path out.
#
# Then, if you want it in /Applications (Homebrew formulae do not put it there):
#
#   ln -sfn "$(brew --prefix mark)/mark.app" /Applications/mark.app
#
class Mark < Formula
  desc "Fast native macOS markdown viewer with a scriptable CLI"
  homepage "https://github.com/shr3kst3r/mark"
  license "MIT"
  head "file:///path/to/your/mark", using: :git

  depends_on "just" => :build
  depends_on "rust" => :build
  # Implies the `:macos` requirement, so that is not stated separately.
  # `Package.swift` targets `.macOS(.v14)` and the bundle advertises
  # LSMinimumSystemVersion 14.0.
  depends_on macos: :sonoma

  # Deliberately no `depends_on xcode: :build`. `swift build` works against the
  # Command Line Tools alone, which is what this project is developed on, and
  # that requirement would demand a full Xcode install nobody here needs. If
  # `swift` is missing, `just build` fails saying so.

  def install
    # `.cargo/config.toml` pins this for cargo, but its `[env]` does not
    # override a value already in the environment — and Homebrew sets one, to
    # the *host* OS. Without this line the Rust half is built for macOS 26
    # while the Swift half and Info.plist say 14.0, and the result refuses to
    # run on anything older than the machine that built it.
    ENV["MACOSX_DEPLOYMENT_TARGET"] = "14.0"

    # `just build` runs cargo, then swift, then assembles the bundle. Neither
    # toolchain can produce a runnable app on its own — that is ADR-1's
    # accepted cost, and `scripts/assemble-bundle.sh` is where it lives.
    system "just", "build"

    prefix.install "target/mark.app"

    # The CLI is a separate Mach-O inside the bundle, per
    # docs/adrs/2026-08-24-rust-core-swift-appkit-shell.md. It resolves $0 through
    # its symlink chain to find the enclosing .app, so symlinking it is safe.
    bin.install_symlink prefix/"mark.app/Contents/MacOS/mark-cli" => "mark"

    # The man page and completions come from the source tree rather than out of
    # the installed bundle: `man1.install` *moves* what it is given, which would
    # quietly remove `mark.app`'s own copy. The bundle keeps its copies for
    # people who install by symlink instead (`just install-cli`).
    man1.install "packaging/mark.1"
    zsh_completion.install "packaging/completions/_mark" => "_mark"
    bash_completion.install "packaging/completions/mark.bash" => "mark"
    fish_completion.install "packaging/completions/mark.fish" => "mark.fish"
  end

  def caveats
    <<~EOS
      The app bundle is at:
        #{opt_prefix}/mark.app

      Homebrew formulae do not install into /Applications. To put it there:
        ln -sfn "#{opt_prefix}/mark.app" /Applications/mark.app

      The `mark` CLI is on your PATH and drives the running app over a Unix
      socket at $TMPDIR/mark-$UID.sock:
        mark open README.md
        mark tab list
        mark render notes.md --ansi
        mark nav ~/notes         # move the sidebar's root
        man mark                 # everything else

      This build is ad-hoc signed. That is fine because you built it locally —
      `spctl -a` will say "rejected", but Gatekeeper is never consulted without a
      quarantine xattr, and a local build has none.
    EOS
  end

  test do
    assert_match "mark", shell_output("#{bin}/mark --version")

    (testpath/"t.md").write("# Title\n\n- [ ] a task\n")
    assert_match "Title", shell_output("#{bin}/mark render #{testpath}/t.md --plain")

    # `mark tasks --json` is an array of tasks, one object each — there is no
    # summary object and no "total" key. Asserted against the real shape,
    # because a test block that passes on a formula whose binary is broken is
    # worse than no test block.
    tasks = shell_output("#{bin}/mark tasks #{testpath}/t.md --json")
    assert_match "\"text\": \"a task\"", tasks
    assert_match "\"checked\": false", tasks

    # The write path, which is the one that touches a user's file.
    system bin/"mark", "check", testpath/"t.md", "--item", "0", "--on"
    assert_equal "# Title\n\n- [x] a task\n", (testpath/"t.md").read

    # The socket commands need a GUI and are not testable here; `mark doctor`
    # is the one that reports on them without needing one.
    assert_match "socket", shell_output("#{bin}/mark doctor")

    # What this formula installs beyond the two binaries.
    assert_predicate man1/"mark.1", :exist?
    assert_predicate prefix/"mark.app/Contents/MacOS/mark", :exist?
    assert_predicate prefix/"mark.app/Contents/Resources/shell.js", :exist?
  end
end
