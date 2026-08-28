//! What git says about a path, by running `git`.
//!
//! `2026-08-28-git-differences-by-running-git` decides the mechanism:
//!
//! > We answer git questions by running the `git` binary as a child process,
//! > always with `--no-optional-locks`, from a new `core/src/git.rs`. The core
//! > owns it, so the CLI and the app get the same answers from the same
//! > implementation and neither can drift.
//!
//! That ADR measured the alternatives rather than assuming them. libgit2
//! through `git2` is only 7 crates and needs no subprocess, and it still lost:
//! **2.4× slower** for the same answer (76.0 ms against 31.6 ms on a
//! 1,709-file repository with stale index stat-data), and `cargo add git2`
//! linked a Homebrew dylib, so shipping it means `vendored-libgit2` against an
//! ADR-1 that rejected dynamic linking outright. `gix` is 141 crates, next to
//! the 166 ADR-1 rejected `wry` over.
//!
//! # Four things here are not obvious, and each cost real time to find
//!
//! * **`--no-optional-locks` is a correctness requirement, not a tuning flag.**
//!   A plain `git status` rewrites `.git/index` to save refreshed stat data —
//!   verified by watching its mtime. `mark` reads repositories; a viewer
//!   polling every two seconds must not be taking `index.lock` and racing the
//!   reader's own git commands. [`run`] prepends the flag itself so no call
//!   site can forget it.
//! * **Not writing the index costs 2.7× on the read**, and we pay it. `git
//!   diff` never refreshes the index, so on a repository whose stat data is
//!   stale it re-hashes the worktree on *every* invocation: 95 ms before a
//!   `git update-index --refresh`, 11 ms after. There is no flag that gives
//!   both, and losing a race with somebody's own `git` is the worse outcome.
//! * **`/usr/bin/git` is an `xcrun` shim, not git.** With no Command Line Tools
//!   installed it puts up a *modal install dialog*, and a Finder-launched app
//!   inherits launchd's minimal `PATH`, so it is the most likely `git` the app
//!   finds. [`program`] therefore probes it last and only behind a successful
//!   `xcode-select -p`.
//! * **`rev-parse --git-path` answers relative to the cwd**, not to the
//!   repository: from `sub/deep` it returns `../../.git/index`. [`discover`]
//!   resolves the results against the directory it ran in. Getting this wrong
//!   is silent — a `stat` of a path that does not exist reads as "nothing
//!   changed".
//!
//! # What this module does not do
//!
//! It never writes to a repository: no staging, no committing, no index
//! refresh, no `gc`. Every invocation is a read, and
//! [`GitError`] is always "we could not find out", never "we broke something".
//!
//! Untracked *line counts* are deliberately not filled in by default. The
//! sidebar computes them per visible row on its own queue
//! (`2026-08-28-git-badges-ride-the-sidebar-poll`), because they are the one
//! part of this feature whose cost is per file rather than per repository.
//! [`Query::count_untracked_lines`] is the opt-in the one-shot CLI uses.

use std::fmt;
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use serde::Serialize;

/// git's empty tree. It exists in every repository without being written,
/// which is what makes a repository with no commits diffable at all: `HEAD`
/// does not resolve there, so `git diff HEAD` is a fatal error and this is the
/// tree to compare against instead.
const EMPTY_TREE: &str = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

/// How long any one `git` invocation may take before it is killed.
///
/// **This is a guess, not a measurement**, and the ADR says so: every timing in
/// it was taken on a local APFS volume. The timeout exists for the case that
/// was never measured — a repository on a stalled network mount, or an
/// `index.lock` held by somebody else's rebase — where the alternative is a
/// sidebar that stops redrawing.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(2);

/// Number of `git` processes spawned since process start.
///
/// The twin of [`crate::tree::dir_reads`], and it exists for the same reason:
/// `2026-08-28-git-badges-ride-the-sidebar-poll` makes "a quiet poll runs no
/// git process" a named constraint, and that is the kind of property that
/// regresses silently unless a test can assert the number directly.
static INVOCATIONS: AtomicU64 = AtomicU64::new(0);

/// How many times `git` has been run since process start.
#[must_use]
pub fn invocations() -> u64 {
    INVOCATIONS.load(Ordering::Relaxed)
}

/// Why we could not find out what git thinks.
///
/// Every variant means **nothing was read and nothing was written**. None of
/// them is worth showing a reader: the ADR's policy is that a git failure
/// leaves the product looking exactly as it does for a file that is not in a
/// repository at all.
#[derive(Debug)]
pub enum GitError {
    /// No usable `git` on this machine. Also what a missing Command Line Tools
    /// installation looks like, deliberately — see [`program`].
    NoGit,
    /// The child could not be started.
    Spawn(io::Error),
    /// The child outlived [`Query::timeout`] and was killed.
    Timeout(Duration),
    /// `git` ran and refused. `stderr` is trimmed to one line: these end up in
    /// a debug log, and git's multi-line hints are noise there.
    Failed { command: String, stderr: String },
    /// `git` succeeded and said something this module could not parse. A bug
    /// here rather than a problem with the repository.
    Output(String),
}

impl fmt::Display for GitError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            GitError::NoGit => write!(f, "no usable git found"),
            GitError::Spawn(error) => write!(f, "could not run git: {error}"),
            GitError::Timeout(after) => {
                write!(f, "git did not finish within {:.1}s", after.as_secs_f64())
            }
            GitError::Failed { command, stderr } => {
                if stderr.is_empty() {
                    write!(f, "git {command} failed")
                } else {
                    write!(f, "git {command} failed: {stderr}")
                }
            }
            GitError::Output(detail) => write!(f, "could not read git's output: {detail}"),
        }
    }
}

impl std::error::Error for GitError {}

/// How a path differs from `HEAD`.
///
/// `Deleted` is reported even though the sidebar can never draw it — a file
/// that is gone is not in a directory listing — because `mark diff` and
/// `mark ls --git` both describe a repository rather than a listing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    Modified,
    Added,
    Deleted,
    Renamed,
    Copied,
    TypeChange,
    Unmerged,
    Untracked,
}

impl Status {
    /// From a `git diff --raw` status letter. `R100` and `C75` carry a
    /// similarity score after the letter, which is why this looks at the first
    /// byte rather than comparing whole strings.
    fn from_raw(field: &str) -> Option<Status> {
        Some(match field.as_bytes().first()? {
            b'M' => Status::Modified,
            b'A' => Status::Added,
            b'D' => Status::Deleted,
            b'R' => Status::Renamed,
            b'C' => Status::Copied,
            b'T' => Status::TypeChange,
            b'U' => Status::Unmerged,
            _ => return None,
        })
    }

    /// Whether a diff of this path's *content* is meaningful. False for a file
    /// that is not there to diff and for an unresolved merge.
    #[must_use]
    pub fn has_content(self) -> bool {
        !matches!(self, Status::Deleted | Status::Unmerged)
    }
}

/// One path that differs from `HEAD`.
///
/// `added` and `removed` are [`Option`] because **"not countable" is a real
/// answer** and must not collapse to zero. `git diff --numstat` prints `-` `-`
/// for a binary file, and prints nothing at all for an untracked one; a
/// `logo.png` badged `+0 −0` would be a lie about a file that changed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Change {
    /// Repository-relative, exactly as git reports it. Callers join it onto
    /// [`Repo::root`] once rather than the core emitting absolute paths per
    /// entry.
    pub path: PathBuf,
    pub status: Status,
    /// Where the path came from, for a rename or a copy.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub from: Option<PathBuf>,
    pub added: Option<u32>,
    pub removed: Option<u32>,
}

impl Change {
    /// Both counts, when both are known. The form a badge wants.
    #[must_use]
    pub fn counts(&self) -> Option<(u32, u32)> {
        Some((self.added?, self.removed?))
    }
}

/// The mtimes `2026-08-28-git-badges-ride-the-sidebar-poll` gates its poll on.
///
/// Seconds and nanoseconds separately rather than one number: APFS timestamps
/// are nanosecond-resolution, and nanoseconds-since-epoch is ~1.8e18, past the
/// 2^53 where a JSON consumer decoding into a float starts losing digits. A
/// gate that silently stops noticing changes is worse than a verbose one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct FileStamp {
    pub sec: i64,
    pub nsec: u32,
}

impl FileStamp {
    fn of(path: &Path) -> Option<FileStamp> {
        use std::os::unix::fs::MetadataExt as _;
        let meta = fs::metadata(path).ok()?;
        Some(FileStamp {
            sec: meta.mtime(),
            nsec: u32::try_from(meta.mtime_nsec()).unwrap_or(0),
        })
    }
}

/// A repository, and the four paths a caller needs from it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Repo {
    /// The worktree root.
    pub root: PathBuf,
    /// The git directory. In a linked worktree this is
    /// `<main>/.git/worktrees/<name>`, not `<root>/.git` — this repository is
    /// developed in worktrees and `core/build.rs:174` already learned it.
    #[serde(rename = "gitDir")]
    pub git_dir: PathBuf,
    /// Absolute path to the index, as `rev-parse --git-path index` resolves it.
    /// Not `git_dir.join("index")`: a shared index or a `$GIT_INDEX_FILE` puts
    /// it somewhere else.
    #[serde(rename = "indexPath")]
    pub index_path: PathBuf,
    /// Absolute path to `HEAD`, resolved the same way.
    #[serde(rename = "headPath")]
    pub head_path: PathBuf,
    /// Short oid of `HEAD`, or `None` in a repository with no commits.
    pub head: Option<String>,
    /// Branch name, `"HEAD"` when detached, `None` with no commits.
    pub branch: Option<String>,
}

impl Repo {
    /// The two mtimes the sidebar's gate compares.
    #[must_use]
    pub fn stamp(&self) -> (Option<FileStamp>, Option<FileStamp>) {
        (
            FileStamp::of(&self.index_path),
            FileStamp::of(&self.head_path),
        )
    }

    /// What `git diff` should compare against: `HEAD`, or the empty tree in a
    /// repository that has no commits yet.
    fn base_rev(&self) -> &str {
        if self.head.is_some() {
            "HEAD"
        } else {
            EMPTY_TREE
        }
    }
}

/// What to ask for.
#[derive(Debug, Clone)]
pub struct Query {
    /// Include files git does not track. Costs a second invocation, measured at
    /// 22.5 ms — `git diff` cannot report them because there is no blob to
    /// compare against.
    pub untracked: bool,
    /// Read each untracked file to count its lines, so it can be badged
    /// `+40 −0` rather than just "untracked".
    ///
    /// Off by default: this is per-file work in an otherwise per-repository
    /// query, and `2026-08-28-git-badges-ride-the-sidebar-poll` puts it on the
    /// sidebar's own screen-bounded queue instead. The one-shot CLI turns it
    /// on.
    pub count_untracked_lines: bool,
    pub timeout: Duration,
}

impl Default for Query {
    fn default() -> Self {
        Query {
            untracked: true,
            count_untracked_lines: false,
            timeout: DEFAULT_TIMEOUT,
        }
    }
}

/// Everything the ABI and the CLI report about one path. `repo: None` is the
/// ordinary answer for a path outside any repository, and it is a **success**.
#[derive(Debug, Clone, Serialize)]
pub struct Report {
    /// `None` for a path outside any repository, **and** for a machine with no
    /// usable git. Serializes as an explicit `null` rather than a missing key,
    /// so a consumer can tell "asked and there is none" from "this build does
    /// not report it". Deliberately not `#[serde(flatten)]`: flattening emitted
    /// `root` instead of `repo` and dropped the key entirely in the `None`
    /// case, which `core/tests/abi_git_shape.rs` caught.
    pub repo: Option<Repo>,
    pub changes: Vec<Change>,
}

impl Report {
    /// Not in a repository, or git could not tell us. Indistinguishable on
    /// purpose: the ADR's degradation policy is that both look like "no git
    /// here" to the reader.
    #[must_use]
    pub fn none() -> Report {
        Report {
            repo: None,
            changes: Vec::new(),
        }
    }
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

/// The repository containing `path`, or `None` if there is not one.
///
/// One `git` invocation. `path` may be a file or a directory; a file's parent
/// is used as the cwd, because `git -C <a file>` is an error.
///
/// A second invocation resolves `HEAD`, and is *allowed to fail*: a repository
/// with no commits has no `HEAD`, which is a normal state and not an error.
pub fn discover(path: &Path) -> Option<Repo> {
    discover_with_timeout(path, DEFAULT_TIMEOUT)
}

/// [`discover`] with an explicit timeout, for tests and for callers on a
/// budget.
pub fn discover_with_timeout(path: &Path, timeout: Duration) -> Option<Repo> {
    let dir = cwd_for(path)?;

    // One call for all four paths. `--show-toplevel` and `--absolute-git-dir`
    // never fail inside a repository, including one with no commits, which is
    // why HEAD's identity is asked for separately below: folding `HEAD` into
    // this call would make `rev-parse` fatal on a fresh `git init` and lose all
    // four paths with it.
    let out = run(
        &dir,
        &[
            "rev-parse",
            "--show-toplevel",
            "--absolute-git-dir",
            "--git-path",
            "index",
            "--git-path",
            "HEAD",
        ],
        timeout,
    )
    .ok()?;
    let text = String::from_utf8_lossy(&out);
    let mut lines = text.lines();
    let root = PathBuf::from(lines.next()?.trim());
    let git_dir = PathBuf::from(lines.next()?.trim());
    // Relative to the *cwd we ran in*, not to the repository: from `sub/deep`
    // git answers `../../.git/index`.
    let index_path = absolutize(&dir, lines.next()?.trim());
    let head_path = absolutize(&dir, lines.next()?.trim());

    if root.as_os_str().is_empty() {
        return None;
    }

    // Allowed to fail, and does on a repository with no commits — which is a
    // normal state, not an error.
    //
    // `--short=7` and `--abbrev-ref` cannot share one `rev-parse`: both are
    // positional modifiers applying to the revisions after them, so
    // `rev-parse --short=7 HEAD --abbrev-ref HEAD` is `fatal: Needed a single
    // revision`. Rather than spend a second process on the branch name, it is
    // read out of the `HEAD` file whose path we just resolved — see
    // [`branch_of`].
    let head = run(&dir, &["rev-parse", "--short=7", "HEAD"], timeout)
        .ok()
        .and_then(|out| {
            String::from_utf8_lossy(&out)
                .lines()
                .next()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
        });
    let branch = branch_of(&head_path);

    Some(Repo {
        root,
        git_dir,
        index_path,
        head_path,
        head,
        branch,
    })
}

/// The branch name, from the `HEAD` file rather than from a `git` process.
///
/// `HEAD` holds either `ref: refs/heads/<branch>` or a raw oid, and that is the
/// whole format. Reading it costs one `open` instead of the 5.9 ms a process
/// costs, it works in a linked worktree (whose `HEAD` is its own file), and it
/// works in a repository with **no commits** — where `rev-parse --abbrev-ref
/// HEAD` is a fatal error even though the branch is perfectly well known.
///
/// `Some("HEAD")` for a detached head, matching what `--abbrev-ref` reports, so
/// a caller comparing against that spelling is not surprised.
fn branch_of(head_path: &Path) -> Option<String> {
    let contents = fs::read_to_string(head_path).ok()?;
    let text = contents.trim();
    if text.is_empty() {
        return None;
    }
    match text.strip_prefix("ref: ") {
        Some(reference) => Some(
            reference
                .strip_prefix("refs/heads/")
                .unwrap_or(reference)
                .to_owned(),
        ),
        // A raw oid: detached.
        None => Some("HEAD".to_owned()),
    }
}

/// A directory to run `git` in. `git` needs a directory, and the caller may
/// hand us a file.
fn cwd_for(path: &Path) -> Option<PathBuf> {
    let absolute = std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf());
    if absolute.is_dir() {
        return Some(absolute);
    }
    // A path that does not exist at all still has a parent that might, which
    // is the case for a document the reader has just deleted from under us.
    absolute
        .parent()
        .map(Path::to_path_buf)
        .filter(|p| p.is_dir())
}

fn absolutize(base: &Path, candidate: &str) -> PathBuf {
    let path = Path::new(candidate);
    if path.is_absolute() {
        return path.to_path_buf();
    }
    // No `canonicalize`: it resolves symlinks, and a notes directory reached
    // through one should keep the name the reader is looking at. `stat`
    // follows the `..` components here perfectly well.
    base.join(path)
}

// ---------------------------------------------------------------------------
// Changes
// ---------------------------------------------------------------------------

/// Every path in `repo` that differs from `HEAD`.
///
/// One invocation for tracked changes, plus one for untracked paths when
/// [`Query::untracked`] is set. Both are repository-wide: the ADR's measurement
/// is that above git's 5.9 ms process floor the work over 1,709 files is about
/// 3.7 ms, so one call answering every row beats one call per row by an order
/// of magnitude.
pub fn changes(repo: &Repo, query: &Query) -> Result<Vec<Change>, GitError> {
    // `--raw` and `--numstat` together: one diff computation, both answers.
    // `--raw` carries the status letter, `--numstat` the counts, and neither
    // has the other. Two separate calls would compute the same diff twice.
    //
    // `-z` because a notes tree has spaces, quotes and non-ASCII in filenames
    // as a matter of course, and git's default quoting would have to be undone
    // by hand.
    let out = run(
        &repo.root,
        &[
            "diff",
            "--raw",
            "--numstat",
            "-z",
            "--find-renames",
            repo.base_rev(),
        ],
        query.timeout,
    )?;
    let mut changes = parse_diff(&out)?;

    if query.untracked {
        changes.extend(untracked(repo, query)?);
    }

    // Stable, and by path: the sidebar looks entries up by name and `mark diff`
    // prints them in order, so neither should depend on git's internal
    // ordering.
    changes.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(changes)
}

/// Parse the concatenated `--raw` and `--numstat` streams.
///
/// The two sections are told apart per record rather than by position: a raw
/// record starts with `:`, a numstat record with a digit or `-`. That makes the
/// parser independent of which section git emits first, which is worth having
/// because the order is a property of the argument order rather than a
/// documented guarantee.
///
/// Record shapes, all NUL-separated:
///
/// ```text
/// raw       :100644 100644 d68dd40 0000000 M \0 keep.md \0
/// raw+move  :100644 100644 02d4b6a 02d4b6a R100 \0 moved.md \0 renamed.md \0
/// numstat   1 \t 1 \t keep.md \0
/// numstat+  0 \t 0 \t \0 moved.md \0 renamed.md \0
/// ```
fn parse_diff(bytes: &[u8]) -> Result<Vec<Change>, GitError> {
    // Status first, then counts merged onto it. A path present in `--numstat`
    // but not in `--raw` cannot happen, but if it did the count would be
    // dropped rather than inventing a status for it.
    let mut order: Vec<PathBuf> = Vec::new();
    let mut records: std::collections::HashMap<PathBuf, Change> = std::collections::HashMap::new();

    let mut tokens = bytes
        .split(|b| *b == 0)
        .filter(|t| !t.is_empty() || true)
        .peekable();

    while let Some(token) = tokens.next() {
        if token.is_empty() {
            continue;
        }
        let record = String::from_utf8_lossy(token).into_owned();

        if let Some(rest) = record.strip_prefix(':') {
            // `:<oldmode> <newmode> <oldsha> <newsha> <status>`
            let status_field = rest
                .rsplit(' ')
                .next()
                .ok_or_else(|| GitError::Output(format!("raw record has no status: {record:?}")))?;
            let status = Status::from_raw(status_field)
                .ok_or_else(|| GitError::Output(format!("unknown raw status {status_field:?}")))?;

            let first = next_path(&mut tokens, &record)?;
            let (path, from) = if matches!(status, Status::Renamed | Status::Copied) {
                let second = next_path(&mut tokens, &record)?;
                (second, Some(first))
            } else {
                (first, None)
            };

            order.push(path.clone());
            records.insert(
                path.clone(),
                Change {
                    path,
                    status,
                    from,
                    added: None,
                    removed: None,
                },
            );
            continue;
        }

        // numstat: `added \t removed \t path`, path empty for a rename.
        let mut fields = record.splitn(3, '\t');
        let added = fields.next().unwrap_or_default();
        let removed = fields.next().ok_or_else(|| {
            GitError::Output(format!("numstat record has no removed count: {record:?}"))
        })?;
        let inline = fields.next().unwrap_or_default();

        let path = if inline.is_empty() {
            // Rename: old then new follow as separate tokens. The *new* path is
            // the one the counts belong to.
            let _from = next_path(&mut tokens, &record)?;
            next_path(&mut tokens, &record)?
        } else {
            PathBuf::from(inline)
        };

        // `-` for a binary file: not a number, and must never become one.
        let added = added.parse::<u32>().ok();
        let removed = removed.parse::<u32>().ok();

        if let Some(existing) = records.get_mut(&path) {
            existing.added = added;
            existing.removed = removed;
        } else {
            // No raw record for it. Treat it as modified rather than dropping
            // the numbers, which is the more useful of the two wrong answers.
            order.push(path.clone());
            records.insert(
                path.clone(),
                Change {
                    path,
                    status: Status::Modified,
                    from: None,
                    added,
                    removed,
                },
            );
        }
    }

    Ok(order
        .into_iter()
        .filter_map(|path| records.remove(&path))
        .collect())
}

fn next_path<'a, I>(tokens: &mut std::iter::Peekable<I>, context: &str) -> Result<PathBuf, GitError>
where
    I: Iterator<Item = &'a [u8]>,
{
    let token = tokens
        .next()
        .ok_or_else(|| GitError::Output(format!("record {context:?} has no path after it")))?;
    if token.is_empty() {
        return Err(GitError::Output(format!(
            "record {context:?} has an empty path"
        )));
    }
    Ok(PathBuf::from(String::from_utf8_lossy(token).into_owned()))
}

/// Paths git does not track, honouring `.gitignore`.
///
/// `--directory` collapses an unignored untracked *directory* to its own name
/// instead of walking it, so dropping a ten-thousand-file folder into a notes
/// tree produces one entry rather than ten thousand.
fn untracked(repo: &Repo, query: &Query) -> Result<Vec<Change>, GitError> {
    let out = run(
        &repo.root,
        &[
            "ls-files",
            "--others",
            "--exclude-standard",
            "--directory",
            "-z",
        ],
        query.timeout,
    )?;

    Ok(out
        .split(|b| *b == 0)
        .filter(|t| !t.is_empty())
        .map(|token| {
            let path = PathBuf::from(String::from_utf8_lossy(token).into_owned());
            let added = if query.count_untracked_lines {
                line_count(&repo.root.join(&path))
            } else {
                None
            };
            Change {
                path,
                status: Status::Untracked,
                from: None,
                // `removed` is 0 rather than `None`: an untracked file removed
                // nothing, and that *is* known, unlike its additions.
                added,
                removed: Some(0),
            }
        })
        .collect())
}

/// Lines in a file, for an untracked file's added count. `None` for anything
/// that is not readable UTF-8 text — a directory (which `--directory` can
/// report), a binary, an unreadable file.
fn line_count(path: &Path) -> Option<u32> {
    let text = fs::read_to_string(path).ok()?;
    u32::try_from(crate::lines::count(&text)).ok()
}

// ---------------------------------------------------------------------------
// Base content
// ---------------------------------------------------------------------------

/// `HEAD`'s version of `path`, as text.
///
/// `Ok(None)` means HEAD does not have this path — an untracked or newly added
/// file — which is a normal answer and not an error. So is a repository with no
/// commits.
///
/// Callers should cache this against `(repo, path, HEAD oid)`: the read costs
/// ~7 ms, and HEAD's bytes cannot change while the oid does not. The editor
/// gutter re-diffs at typing cadence and must not pay it per keystroke.
pub fn base_bytes(repo: &Repo, path: &Path, timeout: Duration) -> Result<Option<String>, GitError> {
    if repo.head.is_none() {
        return Ok(None);
    }
    let Some(relative) = relative_to(repo, path) else {
        return Ok(None);
    };
    // `HEAD:./<path>` rather than `HEAD:<path>`: the `./` form is resolved
    // relative to the cwd, and without it a path is taken from the repository
    // root. We pass a root-relative path, so either works — but the explicit
    // form means a future caller passing a cwd-relative path gets the answer it
    // expects rather than a silent miss.
    let spec = format!("HEAD:{}", relative.display());
    match run(&repo.root, &["cat-file", "blob", &spec], timeout) {
        Ok(bytes) => match String::from_utf8(bytes) {
            // An interior NUL is git's own binary heuristic, and it is also the
            // one thing the C ABI cannot carry — `out()` rejects a string
            // containing one. Rejecting it here means the diff view is simply
            // unavailable for such a blob, rather than the ABI returning null
            // and the app reporting a failure for a file that is merely binary.
            Ok(text) if !text.contains('\0') => Ok(Some(text)),
            // Not something this product can diff. Not an error: the caller
            // disables the diff view for it.
            Ok(_) | Err(_) => Ok(None),
        },
        // `cat-file` fails for a path HEAD does not have, which is the common
        // case for a new note and must not surface as an error.
        Err(GitError::Failed { .. }) => Ok(None),
        Err(other) => Err(other),
    }
}

/// `path` relative to the repository root. `None` when it is not inside it.
fn relative_to(repo: &Repo, path: &Path) -> Option<PathBuf> {
    let absolute = std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf());
    absolute
        .strip_prefix(&repo.root)
        .ok()
        .map(Path::to_path_buf)
        .or_else(|| {
            // The root may be a symlinked or `/private`-prefixed spelling of the
            // same directory — `$TMPDIR` on macOS is exactly this. Compare
            // canonical forms before giving up.
            let root = fs::canonicalize(&repo.root).ok()?;
            let real = fs::canonicalize(&absolute).ok()?;
            real.strip_prefix(&root).ok().map(Path::to_path_buf)
        })
}

// ---------------------------------------------------------------------------
// Running git
// ---------------------------------------------------------------------------

/// The `git` to run, resolved once per process.
///
/// Order matters and `/usr/bin/git` is last on purpose. It is a 118 KB `xcrun`
/// shim: with no Command Line Tools installed, invoking it raises a **modal
/// system dialog** offering to install them. A Finder-launched `mark.app`
/// inherits launchd's minimal `PATH`, so it is also the *most likely* git the
/// app finds — the two facts combine into "a reader who opened a notes folder
/// gets an Xcode install prompt", which is why it is gated on `xcode-select -p`
/// succeeding first.
///
/// `None` is cached as firmly as a hit: a machine with no git must not pay a
/// failed `PATH` search per query.
pub fn program() -> Option<&'static Path> {
    static PROGRAM: OnceLock<Option<PathBuf>> = OnceLock::new();
    PROGRAM
        .get_or_init(|| {
            for candidate in path_candidates() {
                if candidate == Path::new("/usr/bin/git") && !command_line_tools_present() {
                    continue;
                }
                if is_executable(&candidate) && probes_ok(&candidate) {
                    return Some(candidate);
                }
            }
            None
        })
        .as_deref()
}

/// Where to look, in order: `$PATH`, then the two Homebrew prefixes, then the
/// shim.
fn path_candidates() -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Some(path) = std::env::var_os("PATH") {
        out.extend(std::env::split_paths(&path).map(|dir| dir.join("git")));
    }
    for fixed in [
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/usr/bin/git",
    ] {
        let fixed = PathBuf::from(fixed);
        if !out.contains(&fixed) {
            out.push(fixed);
        }
    }
    out
}

fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt as _;
    fs::metadata(path).is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
}

/// Does this binary actually work? A `git` on `PATH` that is a broken wrapper,
/// or a shim whose tools are half-installed, answers `--version` and nothing
/// else. One cheap invocation at resolution time beats every query afterwards
/// failing mysteriously.
fn probes_ok(program: &Path) -> bool {
    Command::new(program)
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

/// Whether the Command Line Tools are installed, checked **without** touching
/// `/usr/bin/git`.
fn command_line_tools_present() -> bool {
    static PRESENT: OnceLock<bool> = OnceLock::new();
    *PRESENT.get_or_init(|| {
        Command::new("/usr/bin/xcode-select")
            .arg("-p")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|status| status.success())
    })
}

/// `git --version`, or `None` when there is no usable git.
///
/// What `mark doctor` reports. Kept here rather than assembled by the CLI so
/// that "which git would this build actually run" has exactly one answer.
#[must_use]
pub fn version() -> Option<String> {
    let program = program()?;
    let out = Command::new(program)
        .arg("--version")
        .stdin(Stdio::null())
        .output()
        .ok()?;
    out.status.success().then(|| {
        String::from_utf8_lossy(&out.stdout)
            .trim()
            .trim_start_matches("git version ")
            .to_owned()
    })
}

/// Whether the Command Line Tools are installed, for `mark doctor`.
#[must_use]
pub fn command_line_tools() -> bool {
    command_line_tools_present()
}

/// Run `git` in `dir` and return stdout.
///
/// Everything in this module goes through here, and this is where the ADR's
/// two non-negotiables live: `--no-optional-locks` is prepended *here* rather
/// than by callers so it cannot be forgotten, and every invocation is bounded
/// by `timeout`.
fn run(dir: &Path, args: &[&str], timeout: Duration) -> Result<Vec<u8>, GitError> {
    let program = program().ok_or(GitError::NoGit)?;
    INVOCATIONS.fetch_add(1, Ordering::Relaxed);

    let mut command = Command::new(program);
    command
        .arg("--no-optional-locks")
        .args(args)
        .current_dir(dir)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        // Belt and braces with `--no-optional-locks`: the flag covers the
        // commands we run, the variable covers anything they run themselves.
        .env("GIT_OPTIONAL_LOCKS", "0")
        // Never prompt. A repository with a credential helper or a
        // `.gitattributes` filter must not be able to block a sidebar redraw
        // on a terminal that is not there.
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_PAGER", "cat")
        .env("GIT_ASKPASS", "")
        // The killer if left in: `mark` launched from a git hook, or from a
        // shell inside `git rebase`, inherits `GIT_DIR` and every query would
        // silently describe *that* repository instead of the reader's file.
        // `core/build.rs` already learned that `$GIT_DIR` is real.
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_COMMON_DIR")
        .env_remove("GIT_OBJECT_DIRECTORY");

    let mut child = command.spawn().map_err(GitError::Spawn)?;

    // Both pipes are drained on their own threads. Polling `try_wait` and
    // reading afterwards would deadlock the moment output exceeds the pipe
    // buffer, and `git diff --numstat` on a busy repository exceeds 64 KB
    // easily.
    let stdout = drain(child.stdout.take());
    let stderr = drain(child.stderr.take());

    // stdout closing is the completion signal. It beats polling: no sleep
    // granularity to choose, and no busy loop.
    let out = match stdout.recv_timeout(timeout) {
        Ok(out) => out,
        Err(mpsc::RecvTimeoutError::Timeout) => {
            kill(&mut child);
            return Err(GitError::Timeout(timeout));
        }
        // The reader thread died without sending. Treat as empty output and let
        // the exit status below decide.
        Err(mpsc::RecvTimeoutError::Disconnected) => Vec::new(),
    };

    let status = child.wait().map_err(GitError::Spawn)?;
    if status.success() {
        return Ok(out);
    }

    let stderr = stderr
        .recv_timeout(Duration::from_millis(200))
        .unwrap_or_default();
    Err(GitError::Failed {
        command: args.join(" "),
        stderr: String::from_utf8_lossy(&stderr)
            .lines()
            .next()
            .unwrap_or_default()
            .trim()
            .to_owned(),
    })
}

/// Read a pipe to EOF on its own thread.
fn drain<R: Read + Send + 'static>(pipe: Option<R>) -> mpsc::Receiver<Vec<u8>> {
    let (tx, rx) = mpsc::channel();
    if let Some(mut pipe) = pipe {
        thread::spawn(move || {
            let mut buffer = Vec::new();
            let _ = pipe.read_to_end(&mut buffer);
            // The receiver may already be gone, on the timeout path. Dropping
            // the bytes is the right answer there.
            let _ = tx.send(buffer);
        });
    }
    rx
}

/// Kill and reap. `wait` after `kill` is what keeps a timed-out query from
/// leaving a zombie behind, and a sidebar polling every two seconds would
/// accumulate them.
fn kill(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn binary_counts_are_none_not_zero() {
        let stream = b"-\t-\tlogo.png\0";
        let changes = parse_diff(stream).expect("parse");
        assert_eq!(changes.len(), 1);
        assert_eq!(changes[0].added, None, "a binary file has no line count");
        assert_eq!(changes[0].removed, None);
        assert_eq!(changes[0].counts(), None);
    }

    #[test]
    fn raw_and_numstat_merge_onto_one_change() {
        let mut stream = Vec::new();
        stream.extend_from_slice(b":100644 100644 d68dd40 0000000 M\0keep.md\0");
        stream.extend_from_slice(b"1\t1\tkeep.md\0");
        let changes = parse_diff(&stream).expect("parse");
        assert_eq!(changes.len(), 1, "one path, one change");
        assert_eq!(changes[0].status, Status::Modified);
        assert_eq!(changes[0].counts(), Some((1, 1)));
    }

    #[test]
    fn a_rename_reports_the_new_path_and_remembers_the_old() {
        let mut stream = Vec::new();
        stream.extend_from_slice(b":100644 100644 02d4b6a 02d4b6a R100\0moved.md\0renamed.md\0");
        stream.extend_from_slice(b"0\t0\t\0moved.md\0renamed.md\0");
        let changes = parse_diff(&stream).expect("parse");
        assert_eq!(changes.len(), 1);
        assert_eq!(changes[0].path, PathBuf::from("renamed.md"));
        assert_eq!(changes[0].from, Some(PathBuf::from("moved.md")));
        assert_eq!(changes[0].status, Status::Renamed);
        assert_eq!(changes[0].counts(), Some((0, 0)));
    }

    #[test]
    fn a_deletion_keeps_its_removed_count() {
        let mut stream = Vec::new();
        stream.extend_from_slice(b":100644 000000 286c5f5 0000000 D\0gone.md\0");
        stream.extend_from_slice(b"0\t4\tgone.md\0");
        let changes = parse_diff(&stream).expect("parse");
        assert_eq!(changes[0].status, Status::Deleted);
        assert_eq!(changes[0].counts(), Some((0, 4)));
        assert!(!changes[0].status.has_content());
    }

    #[test]
    fn a_path_with_a_tab_in_it_survives_z_parsing() {
        // The whole reason for `-z`: this filename would be quoted, and the
        // tab would look like a field separator, without it.
        let stream = b"3\t1\tweird\tname.md\0";
        let changes = parse_diff(stream).expect("parse");
        assert_eq!(changes[0].path, PathBuf::from("weird\tname.md"));
        assert_eq!(changes[0].counts(), Some((3, 1)));
    }

    #[test]
    fn an_empty_stream_is_a_clean_tree() {
        assert!(parse_diff(b"").expect("parse").is_empty());
        assert!(parse_diff(b"\0").expect("parse").is_empty());
    }

    #[test]
    fn an_unknown_raw_status_is_an_error_not_a_guess() {
        let stream = b":100644 100644 aaa bbb Z\0what.md\0";
        assert!(matches!(parse_diff(stream), Err(GitError::Output(_)),));
    }

    #[test]
    fn absolutize_resolves_git_paths_against_the_directory_we_ran_in() {
        // `rev-parse --git-path index` from `sub/deep` answers `../../.git/index`.
        let resolved = absolutize(Path::new("/repo/sub/deep"), "../../.git/index");
        assert_eq!(resolved, PathBuf::from("/repo/sub/deep/../../.git/index"));
        // And an absolute answer, which is what a linked worktree gives, is
        // taken as-is.
        let resolved = absolutize(Path::new("/repo"), "/main/.git/worktrees/w/index");
        assert_eq!(resolved, PathBuf::from("/main/.git/worktrees/w/index"));
    }

    #[test]
    fn the_empty_tree_is_the_base_without_a_head() {
        let mut repo = Repo {
            root: PathBuf::from("/repo"),
            git_dir: PathBuf::from("/repo/.git"),
            index_path: PathBuf::from("/repo/.git/index"),
            head_path: PathBuf::from("/repo/.git/HEAD"),
            head: None,
            branch: None,
        };
        assert_eq!(repo.base_rev(), EMPTY_TREE);
        repo.head = Some("abc1234".to_owned());
        assert_eq!(repo.base_rev(), "HEAD");
    }
}
