//! Lazy, `.gitignore`-aware directory queries.
//!
//! Research 2.8 makes this a hard constraint rather than a preference: the
//! user's `~/src` holds **608,597 files**, so an eager full-tree walk is a
//! multi-second stall and computing per-file task counts eagerly means parsing
//! 37 MB of markdown. Two rules follow, and both are tested:
//!
//! * **One level per call.** [`list_dir`] reads exactly one directory. Deeper
//!   listing is opt-in via [`Options::max_depth`], and there is no "unlimited"
//!   that a caller can reach by accident.
//! * **Stats are opt-in.** Titles and task counts require opening files, so
//!   they only happen when [`Options::with_stats`] is set.
//!
//! [`dir_reads`] and [`file_reads`] are process-wide counters. They exist so a
//! test can assert the bound directly — "does not descend eagerly" is otherwise
//! the kind of property that regresses silently and only shows up as a hang on
//! somebody's real tree.

use std::fmt;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use ignore::gitignore::{Gitignore, GitignoreBuilder};
use serde::Serialize;

use crate::parse::Document;
use crate::tasks;

static DIR_READS: AtomicU64 = AtomicU64::new(0);
static FILE_READS: AtomicU64 = AtomicU64::new(0);

/// Number of `read_dir` calls made since process start.
#[must_use]
pub fn dir_reads() -> u64 {
    DIR_READS.load(Ordering::Relaxed)
}

/// Number of markdown files opened since process start.
#[must_use]
pub fn file_reads() -> u64 {
    FILE_READS.load(Ordering::Relaxed)
}

/// Extensions treated as markdown.
const MARKDOWN: &[&str] = &["md", "markdown", "mdown", "mkd", "mdx"];

/// Is this path a markdown file by extension?
#[must_use]
pub fn is_markdown(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| MARKDOWN.iter().any(|m| e.eq_ignore_ascii_case(m)))
}

/// How much of the tree to look at.
#[derive(Debug, Clone)]
pub struct Options {
    /// Levels below the starting directory. 1 means "this directory only".
    pub max_depth: usize,
    /// Open markdown files to fill in `title` and task counts.
    pub with_stats: bool,
    /// Drop non-markdown files from the listing. Directories are always kept:
    /// dropping them would hide the path to a nested document.
    pub markdown_only: bool,
    /// Include dotfiles and dot-directories.
    pub hidden: bool,
}

impl Default for Options {
    fn default() -> Self {
        Options {
            max_depth: 1,
            with_stats: false,
            markdown_only: true,
            hidden: false,
        }
    }
}

/// One entry in a listing.
#[derive(Debug, Clone, Serialize)]
pub struct Entry {
    pub path: PathBuf,
    pub name: String,
    pub is_dir: bool,
    /// Depth below the starting directory, starting at 1.
    pub depth: usize,
    /// First heading of the document. `None` unless `with_stats`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// Task counts. `None` unless `with_stats`, or if the file was unreadable.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tasks: Option<tasks::Counts>,
}

/// A directory that could not be listed.
#[derive(Debug)]
pub struct TreeError {
    pub path: PathBuf,
    pub source: io::Error,
}

impl fmt::Display for TreeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.path.display(), self.source)
    }
}

impl std::error::Error for TreeError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(&self.source)
    }
}

/// List `root` to `options.max_depth`, in a stable order: directories first,
/// then files, each alphabetically.
///
/// Only `root` itself failing to be read is an error. A subdirectory that
/// cannot be read is skipped, because one unreadable directory should not cost
/// a user the rest of the listing.
pub fn list_dir(root: &Path, options: &Options) -> Result<Vec<Entry>, TreeError> {
    // Ignore matching runs against absolute paths so that `mark ls docs` and
    // `mark ls /abs/docs` reach the same verdict. `absolute` is lexical — it
    // reads the cwd and touches nothing else, and deliberately does not resolve
    // symlinks, so a symlinked notes directory keeps the name the user typed.
    let base = std::path::absolute(root).unwrap_or_else(|_| root.to_path_buf());
    let ignore = Ignores::collect(&base, options.hidden);

    let mut out = Vec::new();
    walk(root, &base, 1, options, &ignore, &mut out).map_err(|source| TreeError {
        path: root.to_path_buf(),
        source,
    })?;
    Ok(out)
}

/// Every markdown file at or below `root`, honouring the same ignore rules.
/// This is what `mark tasks` and `mark grep` walk.
pub fn markdown_files(root: &Path, options: &Options) -> Result<Vec<PathBuf>, TreeError> {
    if root.is_file() {
        return Ok(vec![root.to_path_buf()]);
    }
    Ok(list_dir(root, options)?
        .into_iter()
        .filter(|entry| !entry.is_dir)
        .map(|entry| entry.path)
        .collect())
}

/// `dir` is the path the caller gave, which is what ends up in an [`Entry`];
/// `absolute` is the same directory made absolute, which is what ignore rules
/// are matched against. They are carried separately rather than derived,
/// because deriving one from the other per entry would mean a syscall each on a
/// tree research 2.8 measured at 608k files.
fn walk(
    dir: &Path,
    absolute: &Path,
    depth: usize,
    options: &Options,
    ignore: &Ignores,
    out: &mut Vec<Entry>,
) -> io::Result<()> {
    DIR_READS.fetch_add(1, Ordering::Relaxed);
    let mut dirs = Vec::new();
    let mut files = Vec::new();

    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().into_owned();

        if name == ".git" || (!options.hidden && name.starts_with('.')) {
            continue;
        }
        let is_dir = entry.file_type().is_ok_and(|t| t.is_dir());
        if ignore.is_ignored(&absolute.join(&name), is_dir) {
            continue;
        }
        if is_dir {
            dirs.push((path, name));
        } else if !options.markdown_only || is_markdown(&path) {
            files.push((path, name));
        }
    }

    dirs.sort_by(|a, b| a.1.cmp(&b.1));
    files.sort_by(|a, b| a.1.cmp(&b.1));

    for (path, name) in dirs {
        let child = absolute.join(&name);
        out.push(Entry {
            name,
            is_dir: true,
            depth,
            title: None,
            tasks: None,
            path: path.clone(),
        });
        if depth < options.max_depth {
            // A subdirectory we cannot read is skipped, not fatal.
            let _ = walk(&path, &child, depth + 1, options, ignore, out);
        }
    }
    for (path, name) in files {
        let (title, counts) = if options.with_stats {
            stats(&path)
        } else {
            (None, None)
        };
        out.push(Entry {
            name,
            is_dir: false,
            depth,
            title,
            tasks: counts,
            path,
        });
    }
    Ok(())
}

/// Title and task counts for one file. An unreadable file yields `None` rather
/// than failing the listing.
fn stats(path: &Path) -> (Option<String>, Option<tasks::Counts>) {
    FILE_READS.fetch_add(1, Ordering::Relaxed);
    let Ok(source) = fs::read_to_string(path) else {
        return (None, None);
    };
    let doc = Document::parse(&source);
    // Per-state, and through the core's own counter rather than a local
    // `!checked` — `2026-08-27-five-task-states` puts the badge arithmetic
    // (outstanding over total-minus-cancelled) in one place, and this is one of
    // the call sites that used to decide for itself what "open" meant. It also
    // no longer materialises every label, which a directory listing never
    // reads.
    (doc.title(), Some(tasks::counts_in(&doc)))
}

/// The ignore rules in force for one listing: one matcher per directory that
/// owns an ignore file, outermost first.
///
/// **One matcher per directory is the whole point.** A `Gitignore` interprets
/// its patterns relative to a single root, so folding a repository-root
/// `.gitignore` into a matcher rooted at the subdirectory being listed
/// re-anchors every path-bearing pattern by however many levels down we are:
/// `/target` at the repo root would then hide `<subdir>/target` and stop hiding
/// `target`, and `sub/ignored.md` would stop matching `sub/ignored.md`. Both
/// directions are wrong and both are silent — a file quietly missing from a
/// listing is the failure this tree is supposed to prevent, not cause.
struct Ignores(Vec<Gitignore>);

impl Ignores {
    /// Collect ignore files for `root` and every ancestor up to the git root,
    /// so listing a subdirectory of a repository honours the repository's rules.
    fn collect(root: &Path, hidden: bool) -> Ignores {
        let mut ancestors: Vec<&Path> = Vec::new();
        let mut current = Some(root);
        while let Some(dir) = current {
            ancestors.push(dir);
            if dir.join(".git").exists() {
                break;
            }
            current = dir.parent().filter(|parent| !parent.as_os_str().is_empty());
        }

        // Outermost first, so a nested ignore file can override its parent.
        let matchers = ancestors
            .into_iter()
            .rev()
            .filter_map(|dir| {
                let mut builder = GitignoreBuilder::new(dir);
                let mut any = builder.add(dir.join(".gitignore")).is_none();
                if !hidden {
                    any |= builder.add(dir.join(".ignore")).is_none();
                }
                if !any {
                    return None;
                }
                builder.build().ok().filter(|matcher| !matcher.is_empty())
            })
            .collect();
        Ignores(matchers)
    }

    /// Gitignore precedence: the innermost file that has an opinion wins, and
    /// within a file the last matching pattern wins (which `ignore` already
    /// does for us).
    fn is_ignored(&self, path: &Path, is_dir: bool) -> bool {
        self.0
            .iter()
            .rev()
            .find_map(
                |matcher| match matcher.matched_path_or_any_parents(path, is_dir) {
                    ignore::Match::None => None,
                    other => Some(other.is_ignore()),
                },
            )
            .unwrap_or(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn markdown_extensions_are_case_insensitive() {
        assert!(is_markdown(Path::new("a.md")));
        assert!(is_markdown(Path::new("a.MD")));
        assert!(is_markdown(Path::new("a.markdown")));
        assert!(!is_markdown(Path::new("a.rs")));
        assert!(!is_markdown(Path::new("md")));
    }

    #[test]
    fn a_missing_directory_names_itself() {
        let err = list_dir(Path::new("/definitely/not/here"), &Options::default()).unwrap_err();
        assert!(
            err.to_string().starts_with("/definitely/not/here:"),
            "{err}"
        );
    }
}
