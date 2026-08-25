//! Task enumeration, counting, and the byte-range toggle.
//!
//! This is the module ADR-1 is really about. Checkbox identity is
//! `(file, task-index)` in document order, and **the byte span is
//! authoritative** — so nothing here scans for `[ ]` textually. Markers come
//! from `pulldown-cmark`'s `Event::TaskListMarker`, whose byte range is the
//! marker itself, which is why a literal `[ ]` in prose is neither counted nor
//! written.
//!
//! The write path is deliberately the most conservative code in the core (plan
//! §3): re-parse immediately before writing, verify the target span still holds
//! a task marker, then write through a temp file and rename so a crash
//! mid-write cannot truncate the user's document. Refusing to write is always
//! better than writing the wrong byte.

use std::fmt;
use std::fs;
use std::io::{self, Write as _};
use std::ops::Range;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use pulldown_cmark::{Event, Tag, TagEnd};
use serde::Serialize;

use crate::lock::{DocumentLock, LockError};
use crate::parse::Document;

/// One task list item.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Task {
    /// Position in document order. This is half of the identity ADR-1 defines,
    /// and it is invalidated by anything that reorders tasks.
    pub index: usize,
    pub checked: bool,
    /// Byte range of the marker itself — `[ ]`, `[x]`, or `[X]`.
    pub start: usize,
    pub end: usize,
    /// 1-based line number of the marker.
    pub line: usize,
    /// The item's text, with markup flattened.
    pub text: String,
}

/// What [`toggle`] should do to a marker.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    On,
    Off,
    Toggle,
}

impl Action {
    fn apply(self, checked: bool) -> bool {
        match self {
            Action::On => true,
            Action::Off => false,
            Action::Toggle => !checked,
        }
    }
}

/// Open and total task counts.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize)]
pub struct Counts {
    pub open: usize,
    pub total: usize,
}

/// Why a toggle was refused. Every variant means "we did not write".
#[derive(Debug)]
pub enum TaskError {
    /// No task with this index. CLI exit 3; the GUI logs and ignores.
    IndexOutOfRange {
        index: usize,
        total: usize,
    },
    /// The bytes at the recorded span are not a task marker any more — the file
    /// changed underneath us. Re-render rather than guessing.
    MarkerMoved {
        index: usize,
        span: Range<usize>,
        found: String,
    },
    /// Another `mark` holds the document's write lock — a GUI window with
    /// unsaved edits, or another CLI mid-write.
    /// `2026-08-25-flock-write-locking` requires this to be *distinguishable*
    /// from a missing file, so it is its own variant and its own exit code
    /// rather than an `Io` with a suggestive message.
    Locked(LockError),
    Io {
        path: PathBuf,
        source: io::Error,
    },
}

impl fmt::Display for TaskError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TaskError::IndexOutOfRange { index, total } => match total {
                0 => write!(f, "no task {index}: the document has no tasks"),
                _ => write!(
                    f,
                    "no task {index}: the document has {total} (0..{})",
                    total - 1
                ),
            },
            TaskError::MarkerMoved { index, span, found } => write!(
                f,
                "task {index} is no longer a task marker at bytes {}..{} (found {found:?}); \
                 the file changed - refusing to write",
                span.start, span.end
            ),
            TaskError::Locked(error) => error.fmt(f),
            TaskError::Io { path, source } => write!(f, "{}: {source}", path.display()),
        }
    }
}

impl std::error::Error for TaskError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            TaskError::Io { source, .. } => Some(source),
            TaskError::Locked(error) => Some(error),
            _ => None,
        }
    }
}

/// Why [`write_atomically`] did not write.
///
/// Two outcomes, kept apart because a caller has to be able to tell them apart:
/// *"A CLI verb can now fail for a reason that is invisible on the filesystem"*
/// (`2026-08-25-flock-write-locking`), and "locked" is a different thing to
/// report, and a different thing to retry, than "the disk is full".
#[derive(Debug)]
pub enum WriteError {
    /// Someone else holds the document.
    Locked(LockError),
    Io {
        path: PathBuf,
        source: io::Error,
    },
}

impl fmt::Display for WriteError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            WriteError::Locked(error) => error.fmt(f),
            WriteError::Io { path, source } => write!(f, "{}: {source}", path.display()),
        }
    }
}

impl std::error::Error for WriteError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            WriteError::Locked(error) => Some(error),
            WriteError::Io { source, .. } => Some(source),
        }
    }
}

impl From<LockError> for WriteError {
    fn from(error: LockError) -> Self {
        WriteError::Locked(error)
    }
}

impl From<WriteError> for TaskError {
    fn from(error: WriteError) -> Self {
        match error {
            WriteError::Locked(error) => TaskError::Locked(error),
            WriteError::Io { path, source } => TaskError::Io { path, source },
        }
    }
}

/// Every task in a parsed document, in document order.
#[must_use]
pub fn enumerate(doc: &Document<'_>) -> Vec<Task> {
    let events = doc.events();
    let lines = doc.lines();
    let mut out = Vec::new();

    for (position, (event, span)) in events.iter().enumerate() {
        let Event::TaskListMarker(checked) = event else {
            continue;
        };
        out.push(Task {
            index: out.len(),
            checked: *checked,
            start: span.start,
            end: span.end,
            line: lines.line_of(span.start),
            text: label(events, position),
        });
    }
    out
}

/// Convenience wrapper for callers holding only the source text.
#[must_use]
pub fn enumerate_source(source: &str) -> Vec<Task> {
    enumerate(&Document::parse(source))
}

/// Open/total counts without materialising the task list's text.
#[must_use]
pub fn counts(source: &str) -> Counts {
    let doc = Document::parse(source);
    let mut counts = Counts::default();
    for (event, _) in doc.events() {
        if let Event::TaskListMarker(checked) = event {
            counts.total += 1;
            if !*checked {
                counts.open += 1;
            }
        }
    }
    counts
}

/// The result of a successful toggle.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Toggled {
    /// The document after the edit.
    pub source: String,
    pub index: usize,
    /// State after the edit.
    pub checked: bool,
    /// The single byte offset that changed.
    pub offset: usize,
    pub text: String,
}

/// Toggle one marker in a document held in memory.
///
/// Exactly one byte changes — the character between the brackets — so the
/// document's length is unchanged and no byte outside the marker span differs.
/// Those invariants are property-tested in `core/tests/toggle_invariants.rs`.
pub fn toggle(source: &str, index: usize, action: Action) -> Result<Toggled, TaskError> {
    let tasks = enumerate_source(source);
    let task = tasks.get(index).ok_or(TaskError::IndexOutOfRange {
        index,
        total: tasks.len(),
    })?;

    let marker = &source[task.start..task.end];
    let inner = marker_inner_offset(marker).ok_or_else(|| TaskError::MarkerMoved {
        index,
        span: task.start..task.end,
        found: marker.to_owned(),
    })?;

    let checked = action.apply(task.checked);
    let offset = task.start + inner;

    let mut out = String::with_capacity(source.len());
    out.push_str(&source[..offset]);
    out.push(if checked { 'x' } else { ' ' });
    out.push_str(&source[offset + 1..]);

    Ok(Toggled {
        source: out,
        index,
        checked,
        offset,
        text: task.text.clone(),
    })
}

/// Toggle one marker in a file on disk.
///
/// Re-reads and re-parses first, so an index computed against a stale render is
/// checked against current bytes rather than trusted.
pub fn toggle_file(path: &Path, index: usize, action: Action) -> Result<Toggled, TaskError> {
    let source = fs::read_to_string(path).map_err(|source| TaskError::Io {
        path: path.to_path_buf(),
        source,
    })?;
    let toggled = toggle(&source, index, action)?;
    write_atomically(path, &toggled.source)?;
    Ok(toggled)
}

/// Byte offset, within a marker, of the character between the brackets. `None`
/// if this is not a marker at all — which is how a moved span is caught.
fn marker_inner_offset(marker: &str) -> Option<usize> {
    let bytes = marker.as_bytes();
    let open = bytes.iter().position(|b| *b == b'[')?;
    let inner = open + 1;
    let close = inner + 1;
    if bytes.get(close) != Some(&b']') {
        return None;
    }
    match bytes.get(inner) {
        Some(b' ' | b'x' | b'X') => Some(inner),
        _ => None,
    }
}

/// Distinguishes concurrent writers inside one process. The pid alone is not
/// enough: the GUI's watcher thread and its main thread can both toggle, and
/// two writers sharing a temp path would corrupt each other's rename.
static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// Write through a temp file in the same directory, then rename. A crash
/// mid-write leaves the original intact.
///
/// **The only way a user's document is written.**
/// `2026-08-24-editing-pane-and-autosave` states it as a constraint —
/// *"Every write goes through `write_atomically`. No direct `fs::write` to a
/// user's document, ever."* — and M9's autosave runs this path every 800 ms,
/// so it is `pub` for [`crate::mark_write_json`] rather than private to the
/// toggle. Nothing else in the crate writes to a path.
///
/// **Symlinks are followed before the rename.** `rename(2)` replaces the name,
/// not the file, so renaming onto a symlink would delete the link and leave the
/// document it pointed at holding the *old* bytes — a silent divergence in the
/// one code path that writes to a user's file. Symlinked notes are ordinary
/// (`~/notes -> ~/vault`, a dotfiles repo), so the link is resolved first and
/// the temp file is written beside the real document.
///
/// **The document is `flock`ed for the duration of the write.**
/// `2026-08-25-flock-write-locking` requires that *"every path that writes a
/// user's document takes the lock first. No exceptions, including future
/// features."* Putting the acquire here rather than at each call site is what
/// makes that structurally true instead of a rule to remember: this is the only
/// function in the crate that writes to a path, so every writer — `mark check`,
/// `mark_toggle`, `mark_write_json`, and anything added later — inherits the
/// refusal without doing anything.
///
/// The lock is held for the write and **released when this returns**. A holder
/// that needs to keep it — the GUI, for exactly as long as its buffer is dirty
/// — hands it over for the duration of the call and re-acquires afterwards on
/// the new inode, because the rename below replaces the one it was holding.
/// See `app/Sources/Mark/Editor/Buffer.swift`.
pub fn write_atomically(path: &Path, contents: &str) -> Result<(), WriteError> {
    // Before anything is created, so a refusal leaves no debris. `acquire`
    // canonicalizes for itself, and must: two writers given `~/notes/x.md` and
    // `~/vault/x.md` through a symlink are competing for one inode.
    let _lock = DocumentLock::acquire(path)?;

    // `canonicalize` needs the file to exist, which it does: the caller has
    // already read it. Falling back to the given path keeps a caller that
    // passes a not-yet-existing path working rather than failing here.
    let target = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());

    let directory = target.parent().unwrap_or_else(|| Path::new("."));
    let name = target
        .file_name()
        .map_or_else(|| "mark".into(), |n| n.to_string_lossy().into_owned());
    let temp = directory.join(format!(
        ".{name}.mark-{}-{}.tmp",
        std::process::id(),
        TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));

    let existing = fs::metadata(&target).ok();
    let result = (|| -> io::Result<()> {
        let mut file = fs::File::create(&temp)?;
        file.write_all(contents.as_bytes())?;
        file.sync_all()?;
        drop(file);
        // Preserve the mode the user had; a rename would otherwise silently
        // reset it to the process umask.
        if let Some(existing) = existing {
            fs::set_permissions(&temp, existing.permissions())?;
        }
        fs::rename(&temp, &target)
    })();

    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result.map_err(|source| WriteError::Io {
        path: target,
        source,
    })
}

/// The text of the item a marker belongs to: everything up to the end of the
/// item's first paragraph, or the start of a nested list.
fn label(events: &[(Event<'_>, Range<usize>)], marker: usize) -> String {
    let mut out = String::new();
    for (event, _) in &events[marker + 1..] {
        match event {
            Event::Text(text) | Event::Code(text) => out.push_str(text),
            // Flattened back to the source spelling, like `parse::plain_text`:
            // `mark tasks` output is read by humans and agents, and a task
            // reading "prove " because its `$x^2$` was dropped is worse than
            // one reading "prove $x^2$".
            Event::InlineMath(tex) => out.push_str(&format!("${tex}$")),
            Event::DisplayMath(tex) => out.push_str(&format!("$${tex}$$")),
            Event::SoftBreak | Event::HardBreak => out.push(' '),
            // Stop at the end of the item's first paragraph, or at any nested
            // block. Inline markup (emphasis, links) falls through and is
            // flattened rather than truncating the label.
            Event::End(TagEnd::Item | TagEnd::Paragraph)
            | Event::Start(
                Tag::List(_)
                | Tag::Item
                | Tag::CodeBlock(_)
                | Tag::BlockQuote(_)
                | Tag::Table(_)
                | Tag::Paragraph
                | Tag::Heading { .. },
            ) => break,
            _ => {}
        }
    }
    out.trim().to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn marker_inner_offset_accepts_the_three_spellings() {
        assert_eq!(marker_inner_offset("[ ]"), Some(1));
        assert_eq!(marker_inner_offset("[x]"), Some(1));
        assert_eq!(marker_inner_offset("[X]"), Some(1));
    }

    #[test]
    fn marker_inner_offset_rejects_non_markers() {
        assert_eq!(marker_inner_offset("[]"), None);
        assert_eq!(marker_inner_offset("[ab]"), None);
        assert_eq!(marker_inner_offset("hello"), None);
        assert_eq!(marker_inner_offset(""), None);
    }

    #[test]
    fn toggle_flips_exactly_one_byte() {
        let src = "- [ ] one\n";
        let out = toggle(src, 0, Action::Toggle).unwrap();
        assert_eq!(out.source, "- [x] one\n");
        assert_eq!(out.offset, 3);
        assert!(out.checked);
        assert_eq!(src.len(), out.source.len());
    }

    #[test]
    fn on_and_off_are_idempotent() {
        let src = "- [ ] one\n";
        let on = toggle(src, 0, Action::On).unwrap();
        assert_eq!(on.source, "- [x] one\n");
        assert_eq!(toggle(&on.source, 0, Action::On).unwrap().source, on.source);
        let off = toggle(&on.source, 0, Action::Off).unwrap();
        assert_eq!(off.source, src);
        assert_eq!(toggle(&off.source, 0, Action::Off).unwrap().source, src);
    }

    #[test]
    fn out_of_range_index_names_the_total() {
        let err = toggle("- [ ] one\n", 4, Action::Toggle).unwrap_err();
        assert!(matches!(
            err,
            TaskError::IndexOutOfRange { index: 4, total: 1 }
        ));
        assert_eq!(err.to_string(), "no task 4: the document has 1 (0..0)");
    }

    #[test]
    fn no_tasks_at_all_still_gives_a_useful_message() {
        let err = toggle("nothing here\n", 0, Action::Toggle).unwrap_err();
        assert_eq!(err.to_string(), "no task 0: the document has no tasks");
    }

    #[test]
    fn uppercase_marker_is_recognised_as_checked() {
        let tasks = enumerate_source("- [X] shouty\n");
        assert_eq!(tasks.len(), 1);
        assert!(tasks[0].checked);
        assert_eq!(
            toggle("- [X] shouty\n", 0, Action::Toggle).unwrap().source,
            "- [ ] shouty\n"
        );
    }

    #[test]
    fn uppercase_marker_normalises_on_the_round_trip() {
        // GFM allows `[X]`, but clearing the box discards the letter case, so
        // re-checking writes the canonical `x`. Still one byte, still inside
        // the marker. The property test states the same thing generally.
        let off = toggle("- [X] shouty\n", 0, Action::Toggle).unwrap();
        let on = toggle(&off.source, 0, Action::Toggle).unwrap();
        assert_eq!(on.source, "- [x] shouty\n");
    }

    #[test]
    fn labels_stop_at_a_nested_list() {
        let tasks = enumerate_source("- [ ] parent\n  - child\n");
        assert_eq!(tasks[0].text, "parent");
    }

    #[test]
    fn labels_flatten_inline_markup() {
        let tasks = enumerate_source("- [ ] ship `mark` **now**\n");
        assert_eq!(tasks[0].text, "ship mark now");
    }

    #[test]
    fn multibyte_text_does_not_shift_the_marker() {
        let src = "- [ ] naïve — ünicode ✅\n- [ ] second\n";
        let tasks = enumerate_source(src);
        assert_eq!(&src[tasks[0].start..tasks[0].end], "[ ]");
        assert_eq!(&src[tasks[1].start..tasks[1].end], "[ ]");
        let out = toggle(src, 1, Action::On).unwrap();
        assert_eq!(out.source, "- [ ] naïve — ünicode ✅\n- [x] second\n");
    }
}
