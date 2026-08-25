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

The first attempt will refuse:

```
Error: Refusing to load cask shr3kst3r/mark/mark from untrusted tap shr3kst3r/mark.
```

Homebrew will not run a cask from a third-party tap until you say so, because a
cask can run arbitrary code — this one's `postflight` does. `brew trust
shr3kst3r/mark` clears it. The formula is not subject to this.

Puts the app in `/Applications` the way a cask does, with no build dependencies.
But a downloaded artifact can be quarantined, `--no-quarantine` was removed in
Homebrew 4.7, and an ad-hoc-signed quarantined app reports "damaged and can't be
opened" with no right-click-Open override on macOS Tahoe. So the cask carries a
`postflight` that strips the xattr. That works, but it is a workaround; the
formula does not need one.

A cask can install a man page (`manpage`) but has no stanza for shell
completions, so it prints how to link them instead. One more reason the formula
is the recommended path.

## `mark` is also a formula in homebrew-core

A different one — a tool that syncs markdown to Confluence. It owns the short
name, so always say `shr3kst3r/mark/mark`:

```
$ brew info --formula mark
==> mark: stable 16.12.1 (bottled), HEAD
Sync your markdown files with Confluence pages
```

`brew install mark`, `brew upgrade mark`, and `brew reinstall mark` all resolve
to that one and not to this one, even while this one is the version installed.
Homebrew tries its loaders in a fixed order and the homebrew-core API loader runs
before the ones that would consider a tap or an installed keg, so there is no
state you can get into where the bare name means ours.

The one thing that does work unqualified is `brew --prefix mark`, and only by
coincidence: both formulae are named `mark`, so both answer
`$(brew --prefix)/opt/mark`, which is where our keg is linked. Do not read
anything into that.

## Updating

Which command depends on which of the three paths you installed by, and the
formula's is not the obvious one.

**Formula.** `brew update` refreshes the tap; `--fetch-HEAD` is what makes the
upgrade look at the upstream repo. Spell the name out in full:

```sh
brew update
brew upgrade --fetch-HEAD shr3kst3r/mark/mark
```

Without `--fetch-HEAD`, `brew upgrade` and `brew outdated` both report nothing to
do no matter how far behind you are. A head-only formula has no version number
that moves, so Homebrew treats any installed HEAD keg as current unless you
explicitly ask it to go and compare commits — `head_version_outdated?` returns
false before it ever looks at the remote. It is not a bug and there is no
warning; it just silently does nothing.

`--fetch-HEAD` only works because the formula says `using: :git`, and that is
worth spelling out because the failure it avoids looks exactly like success.
Homebrew picks a download strategy from the URL, and a bare
`https://github.com/<user>/<repo>.git` gets `GitHubGitDownloadStrategy`, which
resolves "the latest commit" by asking the GitHub REST API rather than by
fetching. It sends that request unauthenticated — `GitHub.last_commit` calls
curl with an `Accept` header and nothing else, so `HOMEBREW_GITHUB_API_TOKEN`
does not enter into it — and this repo is private, so the API answers 404. The
strategy then falls back to `git rev-parse HEAD` in Homebrew's cached clone of
the repo, and nothing on that path ever fetches, so the cache still holds the
commit you last installed. "Latest HEAD" comes back equal to the installed HEAD
and you get:

```
Warning: shr3kst3r/mark/mark HEAD-5bb4c6a already installed
```

forever, however far behind you are. `brew outdated --fetch-HEAD` disagrees and
correctly says you are behind — it reaches that answer down a different code
path — which is how this got noticed. `using: :git` forces the plain
`GitDownloadStrategy`, whose `commit_outdated?` runs a real `git fetch` with
your credentials and compares real commits. Making the repo public would also
fix it; the formula does not rely on that happening.

Three things worth knowing:

- `brew update` is what picks up changes to the *formula*, since the tap is a
  clone. New commits to `mark` itself only need `--fetch-HEAD`.
- To rebuild at the same commit — after a toolchain upgrade, say — use
  `brew reinstall --HEAD shr3kst3r/mark/mark`. Homebrew keeps the previous keg
  until the new build succeeds, so a failed rebuild leaves the working install
  alone.
- If you are stuck on the old formula, `brew update` first. The `using: :git`
  fix lives in the formula, so an upgrade run against the tap you already have
  is the broken one.

**Cask.** `brew upgrade --cask` will not do it. The cask's `version` is a literal
(`"0.2.0"`) and its `sha256` is `:no_check`, so nothing Homebrew compares ever
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

## Which `mark.app` opens my files, and which build is it?

Every `mark.app` — the installed one, and every `just build` in every worktree —
carries the same `CFBundleIdentifier`, `dev.mark.app`. LaunchServices registers
all of them and picks one for a double-click or an `open notes.md`, and its
choice is not the one you last built. So "I opened a file and got behaviour I
fixed an hour ago" is a real thing that happens, and it is not a mystery worth
guessing at:

```sh
mark doctor | grep -E 'built from|app (build|path)'
```

`built from` is the CLI on your PATH. `app build` and `app path` are the app
that actually answered — its bundle, and the commit it was built from. Two
different commits on those lines is the whole diagnosis.

**The formula's app is not registered until you symlink it.** Homebrew installs
into the Cellar, and LaunchServices does not scan it — so out of the box the
*only* `dev.mark.app` bundles it knows about are your `target/mark.app` build
directories, and `open notes.md` picks one of those. This is what the formula's
caveat is for:

```sh
ln -sfn "$(brew --prefix mark)/mark.app" /Applications/mark.app
```

To see every bundle LaunchServices knows about:

```sh
lsr=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$lsr" -dump | grep -E 'path:.*mark\.app' | sort -u
```

Expect that list to be longer than you think: it keeps registrations for
directories that no longer exist, including Homebrew's own `/private/tmp` build
dirs from past `--HEAD` installs. Nothing prunes them on its own. Rebuilding the
database drops the dead entries and rescans:

```sh
"$lsr" -kill -r -domain local -domain system -domain user
```

While iterating on a worktree build, drive it explicitly rather than through
LaunchServices' choice — `open -a "$PWD/target/mark.app" notes.md`, or `just run
notes.md`, which execs the bundle's own Mach-O so its stdout and OSLog land in
your terminal.

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
