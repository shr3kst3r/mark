# Installing `mark` locally

Three options, all local — nothing here is meant for submission to
`homebrew-cask`, and the cask deliberately violates its audit rules.

| | Builds | Puts the app in | Man page + completions | Gatekeeper |
|---|---|---|---|---|
| **Formula** (recommended) | from source | `$(brew --prefix mark)` | installed for you | never consulted |
| Cask | no, prebuilt zip | `/Applications` | man page only | needs the `postflight` |
| `just install-cli` | from source | wherever you built | printed, wire them yourself | never consulted |

## Recommended: the formula (builds from source)

```sh
brew tap shr3kst3r/mark /path/to/your/mark
brew install --HEAD shr3kst3r/mark/mark

# optional, if you want it in /Applications
ln -sfn "$(brew --prefix mark)/mark.app" /Applications/mark.app
```

**Why this one.** Locally built code never receives a `com.apple.quarantine`
xattr, so Gatekeeper is never consulted. No Developer ID, no notarization, no
"damaged and can't be opened", nothing to strip afterwards. Verified on this
machine: the built bundle carries no quarantine xattr and launches through
LaunchServices, even though `spctl -a` reports `rejected` — that assessment is
only consulted for a quarantined artifact.

It installs `mark.app`, symlinks `mark` onto your PATH, and installs `mark.1`
plus zsh, bash, and fish completions.

Costs: needs `rust`, `just`, and the Xcode command line tools (not a full
Xcode), and a build takes a couple of minutes — the `merman` LTO link alone is
~63 s.

**`--HEAD`, not `--build-from-source`.** There is no release tarball to point a
stable `url` at, so the formula is head-only and every install is `--HEAD`.
`brew install --build-from-source` asks for a stable spec that does not exist and
fails.

**`--HEAD` builds what is *committed*.** Both forms clone the repo into
Homebrew's cache and build the clone, so uncommitted work is invisible to them.
At the time of writing this repository has one stub commit and everything else
is untracked, which means the formula would build a tree with no source in it.
Until the work is committed, use the third option below; the formula is correct
and its steps are verified, but it cannot be exercised end to end yet.

## Alternative: the cask (installs a prebuilt bundle)

```sh
just build
ditto -c -k --keepParent target/mark.app target/mark.zip
brew tap shr3kst3r/mark /path/to/your/mark
brew install --cask shr3kst3r/mark/mark
```

Puts the app in `/Applications` the way a cask does, with no build dependencies.
But a downloaded artifact can be quarantined, `--no-quarantine` was removed in
Homebrew 4.7, and an ad-hoc-signed quarantined app reports "damaged and can't be
opened" with no right-click-Open override on macOS Tahoe. So the cask carries a
`postflight` that strips the xattr. That works, but it is a workaround; the
formula does not need one.

A cask can install a man page (`manpage`) but has no stanza for shell
completions, so it prints how to link them instead. One more reason the formula
is the recommended path.

## Neither: build and symlink

```sh
just build
just install-cli                  # symlinks mark-cli into $(brew --prefix)/bin/mark
just install-cli ~/.local         # ...or into any writable prefix on your PATH
just uninstall-cli                # removes the symlink again
ln -sfn "$PWD/target/mark.app" /Applications/mark.app   # optional
```

`install-cli` is the VS Code `code` trick: one symlink to
`mark.app/Contents/MacOS/mark-cli`, which resolves `$0` through the symlink
chain to find its enclosing bundle (ADR-1). It refuses rather than guessing when
the target directory does not exist, is not writable, or already holds a real
file, and it prints the paths to the bundled man page and completions so you can
wire up the ones you use.

Because the link points *into* the bundle, it breaks if you move or delete
`target/mark.app`. Rebuilding in place is fine — the path does not change.

## A note on the tap path

`brew tap <user>/<repo> <URL>` accepts any transport `git` understands, including
a local absolute path. Point it at the repo root, not at `packaging/` — Homebrew
looks for `Formula/`, `Casks/`, or top-level `*.rb`. If `brew tap` cannot find
the files, either move copies to `Formula/mark.rb` and `Casks/mark.rb`, or skip
the tap entirely:

```sh
brew install --HEAD ./packaging/mark.rb
```

## A warning about `brew audit` on this machine

`brew audit` turns Homebrew's developer mode on and reinstalls Homebrew's own
vendored Ruby gem bundle. On this machine (Homebrew 6.0.19, portable-ruby 4.0.6)
the reinstalled `json` gem is incompatible with the bundled Ruby, and every
subsequent *developer* command dies with
`undefined method 'default_sort_keys_proc='`. Ordinary commands keep working.
The recovery is to restore the tracked gems and turn developer mode back off:

```sh
git -C "$(brew --repository)" checkout -- Library/Homebrew/vendor/bundle
brew developer off
```

This has nothing to do with `mark`, and it is why the formula here is verified by
`ruby -c` plus a dry run of its `install` and `test` steps rather than by
`brew audit`.
