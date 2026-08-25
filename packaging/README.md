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
brew tap shr3kst3r/mark https://github.com/shr3kst3r/mark
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

**It collides with `just install-cli`.** Both put a `mark` at
`$(brew --prefix)/bin/mark`, and Homebrew will not link over a file it does not
own — the build succeeds and then `brew link` fails with `Could not symlink
bin/mark`. Run `just uninstall-cli` first, or `brew link --overwrite mark` after.

**`--HEAD`, not `--build-from-source`.** There is no release tarball to point a
stable `url` at, so the formula is head-only and every install is `--HEAD`.
`brew install --build-from-source` asks for a stable spec that does not exist and
fails.

**`--HEAD` builds what is *committed and pushed*.** Both forms clone `head`
into Homebrew's cache and build the clone, so uncommitted work is invisible to
them. While you are iterating locally, use the third option below — or tap your
checkout instead of the remote, which builds its committed state:

```sh
brew tap shr3kst3r/mark /path/to/your/mark
brew install --HEAD shr3kst3r/mark/mark
```

## Alternative: the cask (installs a prebuilt bundle)

```sh
just build
ditto -c -k --keepParent target/mark.app target/mark.zip
brew tap shr3kst3r/mark https://github.com/shr3kst3r/mark
MARK_ZIP="$PWD/target/mark.zip" brew install --cask shr3kst3r/mark/mark
```

There is no published release artifact, so the cask installs the zip you just
built. `MARK_ZIP` is where it looks; without it the cask falls back to
`../target/mark.zip` relative to itself, which only resolves when you tapped a
local checkout.

Puts the app in `/Applications` the way a cask does, with no build dependencies.
But a downloaded artifact can be quarantined, `--no-quarantine` was removed in
Homebrew 4.7, and an ad-hoc-signed quarantined app reports "damaged and can't be
opened" with no right-click-Open override on macOS Tahoe. So the cask carries a
`postflight` that strips the xattr. That works, but it is a workaround; the
formula does not need one.

A cask can install a man page (`manpage`) but has no stanza for shell
completions, so it prints how to link them instead. One more reason the formula
is the recommended path.

## Updating

Which command depends on which of the three paths you installed by, and the
formula's is not the obvious one.

**Formula.** `brew update` refreshes the tap; `--fetch-HEAD` is what makes the
upgrade look at the upstream repo:

```sh
brew update
brew upgrade --fetch-HEAD mark
```

Without `--fetch-HEAD`, `brew upgrade mark` and `brew outdated` both report
nothing to do no matter how far behind you are. A head-only formula has no
version number that moves, so Homebrew treats any installed HEAD keg as current
unless you explicitly ask it to go and compare commits — `head_version_outdated?`
returns false before it ever looks at the remote. It is not a bug and there is no
warning; it just silently does nothing.

Two things worth knowing:

- `brew update` is what picks up changes to the *formula*, since the tap is a
  clone. New commits to `mark` itself only need `--fetch-HEAD`.
- To rebuild at the same commit — after a toolchain upgrade, say — use
  `brew reinstall --HEAD mark`. Homebrew keeps the previous keg until the new
  build succeeds, so a failed rebuild leaves the working install alone.

**Cask.** `brew upgrade --cask` will not do it. The cask's `version` is a literal
`"0.1.0"` and its `sha256` is `:no_check`, so nothing Homebrew compares ever
changes and the cask is never outdated. Rebuild the zip and reinstall over it:

```sh
git pull
just build
ditto -c -k --keepParent target/mark.app target/mark.zip
MARK_ZIP="$PWD/target/mark.zip" brew reinstall --cask shr3kst3r/mark/mark
```

**`just install-cli`.** Nothing to update. The symlink points into
`target/mark.app`, so `git pull && just build` is the whole procedure and the
path does not change.

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

## Where the formula and cask live, and why

`Formula/mark.rb` and `Casks/mark.rb`, at the repo root — not in this directory.
Homebrew reads a tap's formulae from `Formula/`, `HomebrewFormula/`, or the tap
root (the first of those three that exists wins), and its casks only from
`Casks/`. Both files used to sit in `packaging/`, which is none of those places,
so tapping the repo produced a tap with zero formulae in it and

```
Warning: No available formula or cask with the name "<tap>/mark".
```

`brew tap <user>/<repo> <URL>` accepts any transport `git` understands, including
a local absolute path — so `brew tap shr3kst3r/mark /path/to/your/mark` works and
builds that checkout's committed state. Either way, point it at the repo root.

There is no longer a way to skip the tap. Homebrew 6 rejects a formula that is
not in one:

```
Error: Homebrew requires formulae to be in a tap, rejecting:
  .../Formula/mark.rb
```

so `brew install --HEAD ./Formula/mark.rb` — which earlier revisions of this
document offered as the fallback — no longer works on any Homebrew new enough to
matter. Tap the checkout instead.

Everything else about packaging — the man page, the shell completions, and this
document — stays here in `packaging/`; only the two Ruby files had to move.

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

This has nothing to do with `mark`, and it is why the formula is verified by
`ruby -c` plus a dry run of its `install` and `test` steps rather than by
`brew audit`.
