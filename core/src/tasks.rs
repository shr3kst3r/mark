//! Task enumeration, counting, metadata, and the byte-range toggle.
//!
//! This is the module ADR-1 is really about. Checkbox identity is
//! `(file, task-index)` in document order, and **the byte span is
//! authoritative** — so nothing here scans for `[ ]` textually. GFM markers
//! come from `pulldown-cmark`'s `Event::TaskListMarker`, whose byte range is
//! the marker itself, which is why a literal `[ ]` in prose is neither counted
//! nor written.
//!
//! `2026-08-27-five-task-states` adds `[/]`, `[-]` and `[?]`, which
//! `pulldown-cmark` does not recognise, and keeps the same rule:
//! **recognition is structural, from the event stream, never a textual scan.**
//! An unrecognised marker arrives as three consecutive `Text` events with exact
//! byte spans at the head of a list `Item`, and the middle event's span *is*
//! the one-byte write target — see [`extended_marker`]. The one permitted
//! lookahead is the single byte after `]`, which is what GFM's own
//! trailing-whitespace rule needs (`- [x]nospace` is not a task, and neither
//! is `- [-]nospace`).
//!
//! `2026-08-27-inline-task-metadata` adds `@tag`, `@key(value)` and `!!!`
//! priority. Recognition runs over the same inline events that build the label,
//! so it can skip `Event::Code` and can report a source offset for
//! `mark check --stamp`. **No clock is read anywhere in this module**: dates are
//! carried as strings and compared only in the CLI's query path, where "today"
//! is an explicit argument (`2026-08-24-rust-side-math-and-diagrams`).
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

// `Tag` is aliased because this module defines its own — a task's `@tag` — and
// the markdown one is only ever matched on, never named in an API here.
use pulldown_cmark::{Event, Tag as MdTag, TagEnd};
use serde::Serialize;

use crate::lock::{DocumentLock, LockError};
use crate::parse::Document;

/// The state of one task, as the single byte between its brackets.
///
/// `2026-08-27-five-task-states`. Every state is exactly one byte, which is
/// what keeps the write primitive — "change the character between the
/// brackets" — unchanged: span re-verification, `write_atomically`, the
/// `flock`, and the stale-render check all sit on top of it and do not care
/// *which* byte goes in.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum State {
    #[default]
    Open,
    InProgress,
    Done,
    Cancelled,
    Blocked,
}

impl State {
    /// The byte this state is written as. `Done` is the canonical lowercase
    /// `x`; `[X]` reads as done and normalises on the round trip, exactly as it
    /// did before there were five states.
    #[must_use]
    pub fn byte(self) -> u8 {
        match self {
            State::Open => b' ',
            State::InProgress => b'/',
            State::Done => b'x',
            State::Cancelled => b'-',
            State::Blocked => b'?',
        }
    }

    /// The state a marker byte means, or `None` for a byte that is not a
    /// marker at all. `[X]` is accepted alongside `[x]`, per GFM.
    #[must_use]
    pub fn from_byte(byte: u8) -> Option<State> {
        match byte {
            b' ' => Some(State::Open),
            b'/' => Some(State::InProgress),
            b'x' | b'X' => Some(State::Done),
            b'-' => Some(State::Cancelled),
            b'?' => Some(State::Blocked),
            _ => None,
        }
    }

    /// The three bytes `pulldown-cmark` does not recognise. GFM's own
    /// ` `/`x`/`X` deliberately are **not** here: they keep arriving as
    /// `Event::TaskListMarker`, and accepting them from the text path as well
    /// would recognise items the parser refused (`- [ ]nospace` is not a task).
    #[must_use]
    fn from_extended_byte(byte: u8) -> Option<State> {
        match byte {
            b'/' => Some(State::InProgress),
            b'-' => Some(State::Cancelled),
            b'?' => Some(State::Blocked),
            _ => None,
        }
    }

    /// Still to do: open, in progress, or blocked. This is the badge's
    /// numerator.
    #[must_use]
    pub fn is_outstanding(self) -> bool {
        matches!(self, State::Open | State::InProgress | State::Blocked)
    }

    /// Finished with, one way or the other: done **or** cancelled. This is what
    /// `Task::checked` reports, so a script asking "is this still outstanding?"
    /// keeps getting the right answer.
    #[must_use]
    pub fn is_terminal(self) -> bool {
        matches!(self, State::Done | State::Cancelled)
    }

    /// The JSON and `data-mk-state` spelling.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            State::Open => "open",
            State::InProgress => "in-progress",
            State::Done => "done",
            State::Cancelled => "cancelled",
            State::Blocked => "blocked",
        }
    }

    /// The spelling for `aria-label`, where a hyphen would be read out.
    /// A five-state control announced as a two-state checkbox would lie to
    /// VoiceOver, which is why the attribute is emitted at all.
    #[must_use]
    pub fn spoken(self) -> &'static str {
        match self {
            State::InProgress => "in progress",
            other => other.as_str(),
        }
    }

    /// A state by name, for `mark check --state` and `mark tasks --state`.
    /// Unknown names are a usage error at the boundary, not a default here.
    #[must_use]
    pub fn from_name(name: &str) -> Option<State> {
        match name {
            "open" => Some(State::Open),
            "in-progress" => Some(State::InProgress),
            "done" => Some(State::Done),
            "cancelled" => Some(State::Cancelled),
            "blocked" => Some(State::Blocked),
            _ => None,
        }
    }

    /// Every state, in marker order. The single source for "what can I say?" —
    /// CLI help, `--state` validation, and the tests all read it from here.
    pub const ALL: [State; 5] = [
        State::Open,
        State::InProgress,
        State::Done,
        State::Cancelled,
        State::Blocked,
    ];
}

/// One `@tag` or `@key(value)` from a task's own text.
///
/// `name` excludes the `@`, so a tag is greppable and a filter can be spelled
/// either way. `2026-08-27-inline-task-metadata`: no tag ever affects a count.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Tag {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
}

/// One recognised metadata token, and where it is in the document.
///
/// The renderer draws these as neutral chips. This type carries no presentation
/// and no date arithmetic: `2026-08-27-inline-task-metadata` requires the
/// renderer to stay a pure function of its source, so "overdue" is not
/// expressible here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Chip {
    /// Byte range of the token in the document source.
    pub source: Range<usize>,
    pub kind: ChipKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChipKind {
    Tag { name: String, value: Option<String> },
    Priority(u8),
}

/// One task list item.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Task {
    /// Position in document order. This is half of the identity ADR-1 defines,
    /// and it is invalidated by anything that reorders tasks.
    pub index: usize,
    /// The state the marker byte carries.
    pub state: State,
    /// **Retained, and defined as "the state is terminal"** — true for done
    /// *and* cancelled (`2026-08-27-five-task-states`). It is a mild lie in its
    /// name in order to stay honest in its answer: every existing consumer is
    /// asking "is this still outstanding?", and this keeps answering that
    /// correctly. Read `state` when the distinction matters.
    pub checked: bool,
    /// Byte range of the marker itself — `[ ]`, `[x]`, `[X]`, `[/]`, `[-]` or
    /// `[?]`.
    pub start: usize,
    pub end: usize,
    /// 1-based line number of the marker.
    pub line: usize,
    /// The item's text, with markup flattened. **Unchanged in meaning:** the
    /// full text, metadata tokens included, because every existing consumer
    /// reads this field. `label` is the stripped one.
    pub text: String,
    /// `text` with the recognised metadata tokens removed and whitespace
    /// collapsed — what a human-facing list should show.
    pub label: String,
    pub tags: Vec<Tag>,
    /// `@due(YYYY-MM-DD)`, validated as a date. `@due(friday)` is a `tags`
    /// entry instead — not a date, not an error.
    pub due: Option<String>,
    /// `@start(YYYY-MM-DD)`.
    ///
    /// Named `start_date` rather than `start` in Rust *and on the wire*
    /// because `start` is already this struct's marker byte offset, and
    /// shadowing it would silently change what every existing consumer reads.
    pub start_date: Option<String>,
    /// `@done(YYYY-MM-DD)` as written in the text. Independent of `state`: the
    /// marker says done, this says when someone recorded it.
    pub done: Option<String>,
    /// `!` = 1, `!!` = 2, `!!!` = 3, absent = 0.
    pub priority: u8,
    /// Source offset just past the last non-whitespace byte of the item's
    /// inline content — where `mark check --stamp` inserts `@done(…)`. Taken
    /// from an event span rather than from a textual search, and deliberately
    /// not on the wire: `mark check --stamp` is the supported way to use it.
    #[serde(skip)]
    pub label_end: usize,
    /// Source offset of the item's **first** visible byte — the other end of
    /// the same span, which is what `mark normalize` wraps in `~~`. Equal to
    /// `label_end` for an item with no text at all.
    #[serde(skip)]
    pub text_start: usize,
    /// The metadata tokens' source ranges, for the renderer's chips. Not on the
    /// wire either: a consumer of the JSON has `tags`, `due` and friends.
    #[serde(skip)]
    pub chips: Vec<Chip>,
}

/// What [`toggle`] should do to a marker.
///
/// The discriminants are the C ABI's `action` values
/// (`2026-08-27-five-task-states`: "the old encoding is a prefix of the new
/// one"), so the mapping in [`crate::mark_toggle`] needs no table and cannot
/// drift from this enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Off = 0,
    On = 1,
    Toggle = 2,
    InProgress = 3,
    Cancel = 4,
    Block = 5,
}

impl Action {
    /// The state a marker ends up in.
    ///
    /// `Toggle` is open→done, done→open, and **every other state → done**: a
    /// click on a checkbox means "tick this box", so toggle is a one-way exit
    /// from in-progress, cancelled and blocked. That is why the property
    /// suite's round-trip invariant is stated for open and done inputs only —
    /// no mapping out of the extended states preserves it, and a click that
    /// silently does nothing is worse than one that does not round-trip.
    #[must_use]
    pub fn apply(self, state: State) -> State {
        match self {
            Action::Off => State::Open,
            Action::On => State::Done,
            Action::InProgress => State::InProgress,
            Action::Cancel => State::Cancelled,
            Action::Block => State::Blocked,
            Action::Toggle => match state {
                State::Open => State::Done,
                State::Done => State::Open,
                _ => State::Done,
            },
        }
    }

    /// The action that sets a marker to `state`, for `mark check --state`.
    #[must_use]
    pub fn for_state(state: State) -> Action {
        match state {
            State::Open => Action::Off,
            State::InProgress => Action::InProgress,
            State::Done => Action::On,
            State::Cancelled => Action::Cancel,
            State::Blocked => Action::Block,
        }
    }
}

/// Task counts, per state and in total.
///
/// `outstanding` and `active` are methods rather than fields so the five call
/// sites that ask "how many are left?" cannot each invent their own
/// arithmetic. For a document containing only GFM markers every extended count
/// is zero, `outstanding() == open` and `active() == total`, so **no existing
/// document's badge changes**.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize)]
pub struct Counts {
    pub open: usize,
    pub in_progress: usize,
    pub done: usize,
    pub cancelled: usize,
    pub blocked: usize,
    pub total: usize,
}

impl Counts {
    /// Still to do: open + in progress + blocked.
    #[must_use]
    pub fn outstanding(&self) -> usize {
        self.open + self.in_progress + self.blocked
    }

    /// The badge's denominator. **Cancelled is the only state that leaves it**
    /// (`2026-08-27-five-task-states`): a dropped item stops sitting in the
    /// denominator for ever, which is what stopped the counts lying.
    #[must_use]
    pub fn active(&self) -> usize {
        self.total - self.cancelled
    }

    fn record(&mut self, state: State) {
        self.total += 1;
        match state {
            State::Open => self.open += 1,
            State::InProgress => self.in_progress += 1,
            State::Done => self.done += 1,
            State::Cancelled => self.cancelled += 1,
            State::Blocked => self.blocked += 1,
        }
    }
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
    let source = doc.source();
    let lines = doc.lines();
    let mut out = Vec::new();

    for (position, (event, span)) in events.iter().enumerate() {
        // A GFM marker, or the three-`Text`-event triple an extended one
        // arrives as. Two shapes, one task list — and neither is found by
        // looking at the document's bytes for a bracket.
        let (state, marker, after) = match event {
            Event::TaskListMarker(checked) => (
                if *checked { State::Done } else { State::Open },
                span.clone(),
                position + 1,
            ),
            _ => match extended_marker(events, position, source) {
                Some((state, marker)) => (state, marker, position + 3),
                None => continue,
            },
        };

        let meta = metadata(events, after, marker.end);
        out.push(Task {
            index: out.len(),
            state,
            checked: state.is_terminal(),
            start: marker.start,
            end: marker.end,
            line: lines.line_of(marker.start),
            text: meta.text,
            label: meta.label,
            tags: meta.tags,
            due: meta.due,
            start_date: meta.start,
            done: meta.done,
            priority: meta.priority,
            label_end: meta.label_end,
            text_start: meta.text_start,
            chips: meta.chips,
        });
    }
    out
}

/// Convenience wrapper for callers holding only the source text.
#[must_use]
pub fn enumerate_source(source: &str) -> Vec<Task> {
    enumerate(&Document::parse(source))
}

/// Per-state counts without materialising the task list's text or metadata.
#[must_use]
pub fn counts(source: &str) -> Counts {
    counts_in(&Document::parse(source))
}

/// The same, for a document already parsed — `mark ls` opens a directory's
/// worth of files and has no use for their labels.
#[must_use]
pub fn counts_in(doc: &Document<'_>) -> Counts {
    let events = doc.events();
    let source = doc.source();
    let mut counts = Counts::default();
    for (position, (event, _)) in events.iter().enumerate() {
        match event {
            Event::TaskListMarker(checked) => {
                counts.record(if *checked { State::Done } else { State::Open });
            }
            _ => {
                if let Some((state, _)) = extended_marker(events, position, source) {
                    counts.record(state);
                }
            }
        }
    }
    counts
}

/// The extended marker at the head of a list item, if `at` is where one starts.
///
/// `at` is a position in `events`; the answer is `Some` only when
///
/// * `events[at]` is the first **inline** event of a list `Item` — directly
///   after `Start(Item)`, or after the `Start(Paragraph)` a loose list
///   interposes, which is where `Event::TaskListMarker` appears too;
/// * `events[at..at + 3]` are `Text("[")`, `Text(c)` with `c` exactly one byte
///   from the extended set, and `Text("]")`, with **contiguous spans**; and
/// * the byte after `]` is ASCII whitespace, or the source ends there.
///
/// The returned range is the whole marker, `[c]`, so it is interchangeable with
/// `Event::TaskListMarker`'s span everywhere downstream; the byte to write is
/// at offset 1 inside it, exactly as it is for `[ ]`.
///
/// The trailing-byte test is the one lookahead
/// `2026-08-27-five-task-states` permits, and it exists to match GFM: the
/// parser emits no `TaskListMarker` for `- [x]nospace`, so `- [-]nospace` is
/// not a task either. Everything else here is structure, which is what keeps
/// `- foo [-] bar`, `prose [-] bracket`, `- *[-]* x`, `- [x](url)` and
/// `- [ab] x` out.
#[must_use]
pub fn extended_marker(
    events: &[(Event<'_>, Range<usize>)],
    at: usize,
    source: &str,
) -> Option<(State, Range<usize>)> {
    if !is_item_head(events, at) {
        return None;
    }

    let (open, open_span) = text_event(events, at)?;
    let (inner, inner_span) = text_event(events, at + 1)?;
    let (close, close_span) = text_event(events, at + 2)?;

    if open != "[" || close != "]" || inner.len() != 1 {
        return None;
    }
    if open_span.end != inner_span.start || inner_span.end != close_span.start {
        return None;
    }

    let state = State::from_extended_byte(inner.as_bytes()[0])?;
    match source.as_bytes().get(close_span.end) {
        None => {}
        Some(byte) if byte.is_ascii_whitespace() => {}
        Some(_) => return None,
    }
    Some((state, open_span.start..close_span.end))
}

/// Whether `events[at]` is the first inline event inside a list item.
///
/// A tight list puts the item's first inline event directly after
/// `Start(Item)`; a loose one wraps the content in a paragraph first. Both are
/// accepted because `Event::TaskListMarker` appears in both positions, so `[ ]`
/// and `[-]` stay symmetric.
fn is_item_head(events: &[(Event<'_>, Range<usize>)], at: usize) -> bool {
    let Some(previous) = at.checked_sub(1) else {
        return false;
    };
    match events.get(previous).map(|(event, _)| event) {
        Some(Event::Start(MdTag::Item)) => true,
        Some(Event::Start(MdTag::Paragraph)) => matches!(
            previous
                .checked_sub(1)
                .and_then(|i| events.get(i))
                .map(|(event, _)| event),
            Some(Event::Start(MdTag::Item))
        ),
        _ => false,
    }
}

/// The text and span of `events[at]`, if it is an `Event::Text`.
fn text_event<'a>(
    events: &'a [(Event<'_>, Range<usize>)],
    at: usize,
) -> Option<(&'a str, &'a Range<usize>)> {
    match events.get(at) {
        Some((Event::Text(text), span)) => Some((text.as_ref(), span)),
        _ => None,
    }
}

/// The result of a successful toggle.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Toggled {
    /// The document after the edit.
    pub source: String,
    pub index: usize,
    /// State after the edit.
    pub state: State,
    /// `state.is_terminal()`, retained for every existing consumer — see
    /// [`Task::checked`].
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

    let state = action.apply(task.state);
    let offset = task.start + inner;

    let mut out = String::with_capacity(source.len());
    out.push_str(&source[..offset]);
    out.push(char::from(state.byte()));
    out.push_str(&source[offset + 1..]);

    Ok(Toggled {
        source: out,
        index,
        state,
        checked: state.is_terminal(),
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
///
/// **This is the staleness guard.** Every accepted state's byte has to be here:
/// a byte missing from [`State::from_byte`]'s set makes a live marker look like
/// one that moved, so the write is refused with `MarkerMoved` and the user is
/// told their file changed when it did not. A refusal, not a corruption, but a
/// confusing one.
fn marker_inner_offset(marker: &str) -> Option<usize> {
    let bytes = marker.as_bytes();
    let open = bytes.iter().position(|b| *b == b'[')?;
    let inner = open + 1;
    let close = inner + 1;
    if bytes.get(close) != Some(&b']') {
        return None;
    }
    State::from_byte(*bytes.get(inner)?).map(|_| inner)
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
        if let Some(existing) = &existing {
            // Finder tags, and every other extended attribute and ACL the
            // document carried, live on the inode — and the rename below
            // replaces the inode. Move them onto the new one first. Best
            // effort by design: the bytes are what the write is for, and a
            // volume that cannot hold an xattr must not refuse a save.
            copy_metadata(&target, &temp);
            // Preserve the mode the user had; a rename would otherwise
            // silently reset it to the process umask.
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

/// Copy `from`'s extended attributes and ACL onto `to`, leaving both files'
/// bytes alone. `copyfile(3)` with the metadata flags is the system's own way
/// of doing this — it is what Finder uses — and a failure is deliberately not
/// reported: see [`write_atomically`].
#[cfg(target_os = "macos")]
fn copy_metadata(from: &Path, to: &Path) {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    let (Ok(from), Ok(to)) = (
        CString::new(from.as_os_str().as_bytes()),
        CString::new(to.as_os_str().as_bytes()),
    ) else {
        return;
    };
    // SAFETY: both strings are valid, NUL-terminated, and outlive the call; a
    // null state asks for no progress callbacks.
    unsafe {
        libc::copyfile(
            from.as_ptr(),
            to.as_ptr(),
            std::ptr::null_mut(),
            libc::COPYFILE_XATTR | libc::COPYFILE_ACL,
        );
    }
}

#[cfg(not(target_os = "macos"))]
fn copy_metadata(_from: &Path, _to: &Path) {}

/// What one task item's inline events say: its text, its label, and its
/// metadata.
///
/// `2026-08-27-inline-task-metadata`. Built from the events rather than from
/// the raw line, which is what lets `Event::Code` be skipped and what gives
/// [`Metadata::label_end`] a parser-derived offset.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Metadata {
    /// The item's full flattened text, metadata included.
    pub text: String,
    /// `text` with the recognised tokens removed and whitespace collapsed.
    pub label: String,
    pub tags: Vec<Tag>,
    pub due: Option<String>,
    pub start: Option<String>,
    pub done: Option<String>,
    pub priority: u8,
    /// See [`Task::label_end`].
    pub label_end: usize,
    /// See [`Task::text_start`].
    pub text_start: usize,
    /// See [`Task::chips`].
    pub chips: Vec<Chip>,
}

/// One run of flattened text, and where it came from.
struct Chunk {
    /// Range within the flattened text.
    text: Range<usize>,
    /// Range within the document source.
    source: Range<usize>,
    /// Whether metadata recognition must ignore it: an inline code span, or
    /// math. `` `@due(x)` `` documents the syntax rather than using it, and
    /// `$a@b$` is TeX.
    immune: bool,
}

/// The text and metadata of the item a marker belongs to: everything up to the
/// end of the item's first paragraph, or the start of a nested list.
///
/// `after` is the position just past the marker — the marker event's index plus
/// one for `[ ]`, plus three for `[-]`. `content_start` is the marker's end
/// offset, which is where an item with no text at all gets stamped.
fn metadata(events: &[(Event<'_>, Range<usize>)], after: usize, content_start: usize) -> Metadata {
    let mut flat = String::new();
    let mut chunks: Vec<Chunk> = Vec::new();

    let mut push = |flat: &mut String, text: &str, source: &Range<usize>, immune: bool| {
        let start = flat.len();
        flat.push_str(text);
        chunks.push(Chunk {
            text: start..flat.len(),
            source: source.clone(),
            immune,
        });
    };

    for (event, span) in &events[after.min(events.len())..] {
        match event {
            Event::Text(text) => push(&mut flat, text, span, false),
            Event::Code(text) => push(&mut flat, text, span, true),
            // Flattened back to the source spelling, like `parse::plain_text`:
            // `mark tasks` output is read by humans and agents, and a task
            // reading "prove " because its `$x^2$` was dropped is worse than
            // one reading "prove $x^2$".
            Event::InlineMath(tex) => push(&mut flat, &format!("${tex}$"), span, true),
            Event::DisplayMath(tex) => push(&mut flat, &format!("$${tex}$$"), span, true),
            Event::SoftBreak | Event::HardBreak => push(&mut flat, " ", span, false),
            // Stop at the end of the item's first paragraph, or at any nested
            // block. Inline markup (emphasis, links) falls through and is
            // flattened rather than truncating the label.
            Event::End(TagEnd::Item | TagEnd::Paragraph)
            | Event::Start(
                MdTag::List(_)
                | MdTag::Item
                | MdTag::CodeBlock(_)
                | MdTag::BlockQuote(_)
                | MdTag::Table(_)
                | MdTag::Paragraph
                | MdTag::Heading { .. },
            ) => break,
            _ => {}
        }
    }

    let mut meta = Metadata {
        text: flat.trim().to_owned(),
        text_start: text_start(&chunks, &flat, content_start),
        label_end: label_end(&chunks, &flat, content_start),
        ..Metadata::default()
    };

    // One pass over the whitespace-delimited tokens. A token is metadata only
    // when it is delimited on *both* sides — which is what makes
    // `bob@example.com` an email address and `ship it!!!` prose — and only when
    // no part of it came from a code span or from math.
    let mut kept: Vec<&str> = Vec::new();
    let mut stripped = false;
    for token in tokens(&flat) {
        let text = &flat[token.clone()];
        let immune = chunks.iter().any(|chunk| {
            chunk.immune && chunk.text.start < token.end && token.start < chunk.text.end
        });
        match (immune, classify(text)) {
            (false, Some(Token::Priority(level))) => {
                meta.priority = meta.priority.max(level);
                if let Some(source) = source_range(&chunks, &token) {
                    meta.chips.push(Chip {
                        source,
                        kind: ChipKind::Priority(level),
                    });
                }
                stripped = true;
            }
            (false, Some(Token::Tag { name, value })) => {
                if let Some(source) = source_range(&chunks, &token) {
                    meta.chips.push(Chip {
                        source,
                        kind: ChipKind::Tag {
                            name: name.to_owned(),
                            value: value.map(str::to_owned),
                        },
                    });
                }
                match (name, &value) {
                    ("due", Some(date)) if parse_iso_date(date).is_some() => {
                        meta.due = Some((*date).to_owned());
                    }
                    ("start", Some(date)) if parse_iso_date(date).is_some() => {
                        meta.start = Some((*date).to_owned());
                    }
                    ("done", Some(date)) if parse_iso_date(date).is_some() => {
                        meta.done = Some((*date).to_owned());
                    }
                    // A known key with an unparseable value, or any other name:
                    // an untyped tag. `@due(friday)` is not a date, is not
                    // sorted as one, and is not an error.
                    _ => meta.tags.push(Tag {
                        name: name.to_owned(),
                        value: value.map(str::to_owned),
                    }),
                }
                stripped = true;
            }
            _ => kept.push(text),
        }
    }

    // Untouched text keeps its own spacing; only a document that actually used
    // metadata gets its whitespace collapsed at the seams the removal left.
    meta.label = if stripped {
        kept.join(" ")
    } else {
        meta.text.clone()
    };
    meta
}

/// Where a flattened-text range came from in the document, if that is known
/// exactly.
///
/// `None` when the token straddles two chunks, or when its chunk's text and
/// source differ in length — an entity reference or an escape, where the
/// mapping is not byte-for-byte. The token is still metadata; it simply renders
/// as prose rather than as a chip, which is the conservative direction.
fn source_range(chunks: &[Chunk], token: &Range<usize>) -> Option<Range<usize>> {
    let chunk = chunks
        .iter()
        .find(|chunk| chunk.text.start <= token.start && token.end <= chunk.text.end)?;
    if chunk.source.len() != chunk.text.len() {
        return None;
    }
    let offset = chunk.source.start + (token.start - chunk.text.start);
    Some(offset..offset + (token.end - token.start))
}

/// Source offset of the item's first non-whitespace inline byte.
fn text_start(chunks: &[Chunk], flat: &str, content_start: usize) -> usize {
    for chunk in chunks {
        let text = &flat[chunk.text.clone()];
        let leading = text.len() - text.trim_start().len();
        if leading < text.len() {
            return chunk.source.start.saturating_add(leading);
        }
    }
    content_start
}

/// Source offset just past the item's last non-whitespace inline byte.
///
/// Taken from an event span, never from a search: `mark check --stamp` writes
/// there.
fn label_end(chunks: &[Chunk], flat: &str, content_start: usize) -> usize {
    for chunk in chunks.iter().rev() {
        let text = &flat[chunk.text.clone()];
        let trailing = text.len() - text.trim_end().len();
        if trailing < text.len() {
            return chunk.source.end.saturating_sub(trailing);
        }
    }
    content_start
}

/// Whitespace-delimited token ranges within `flat`.
///
/// Byte-wise is safe and deliberate: an ASCII whitespace byte never occurs
/// inside a multi-byte UTF-8 sequence, so every boundary found here is a char
/// boundary.
fn tokens(flat: &str) -> Vec<Range<usize>> {
    let bytes = flat.as_bytes();
    let mut out = Vec::new();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index].is_ascii_whitespace() {
            index += 1;
            continue;
        }
        let start = index;
        while index < bytes.len() && !bytes[index].is_ascii_whitespace() {
            index += 1;
        }
        out.push(start..index);
    }
    out
}

/// What a single whitespace-delimited token means, if anything.
enum Token<'a> {
    Tag {
        name: &'a str,
        value: Option<&'a str>,
    },
    Priority(u8),
}

fn classify(token: &str) -> Option<Token<'_>> {
    // `!`, `!!`, `!!!` — and nothing longer, so `ship it!!!!` stays prose.
    if !token.is_empty() && token.len() <= 3 && token.bytes().all(|b| b == b'!') {
        return Some(Token::Priority(
            u8::try_from(token.len()).expect("at most 3"),
        ));
    }

    let rest = token.strip_prefix('@')?;
    let (name, value) = match rest.find('(') {
        Some(paren) => {
            let inner = rest.strip_suffix(')')?;
            (&inner[..paren], Some(&inner[paren + 1..]))
        }
        None => (rest, None),
    };
    // A name has to start like a name, and neither half may carry a stray
    // bracket: `@(x)`, `@!!` and `@a)b` are prose.
    let first = name.chars().next()?;
    if !(first.is_alphanumeric() || first == '_') {
        return None;
    }
    if name.contains([')', '(']) || value.is_some_and(|v| v.contains(['(', ')'])) {
        return None;
    }
    Some(Token::Tag { name, value })
}

/// `YYYY-MM-DD` as `(year, month, day)`, calendar-checked. Anything else is
/// `None` — a value, not a date, and not an error
/// (`2026-08-27-inline-task-metadata`: "Dates are ISO 8601 `YYYY-MM-DD` and
/// nothing else").
///
/// Public because the CLI's query path needs exactly the same notion of a date
/// as the parser that produced the field, and two implementations would drift.
#[must_use]
pub fn parse_iso_date(text: &str) -> Option<(i32, u32, u32)> {
    let bytes = text.as_bytes();
    if bytes.len() != 10 || bytes[4] != b'-' || bytes[7] != b'-' {
        return None;
    }
    let year: i32 = text[0..4].parse().ok()?;
    let month: u32 = text[5..7].parse().ok()?;
    let day: u32 = text[8..10].parse().ok()?;
    if !(1..=12).contains(&month) || day < 1 || day > days_in_month(year, month) {
        return None;
    }
    Some((year, month, day))
}

fn days_in_month(year: i32, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) => 29,
        2 => 28,
        _ => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The staleness guard's allowlist. Every byte any state can be written as
    /// has to be here or a live marker is misreported as `MarkerMoved`, so this
    /// is derived from `State::ALL` rather than hand-listed — a sixth state
    /// cannot be added without this test noticing.
    #[test]
    fn marker_inner_offset_accepts_every_state_byte() {
        for state in State::ALL {
            let marker = format!("[{}]", char::from(state.byte()));
            assert_eq!(marker_inner_offset(&marker), Some(1), "{marker}");
        }
        // GFM's shouty spelling, which is not a `State::byte` but is a marker.
        assert_eq!(marker_inner_offset("[X]"), Some(1));
    }

    #[test]
    fn marker_inner_offset_rejects_non_markers() {
        assert_eq!(marker_inner_offset("[]"), None);
        assert_eq!(marker_inner_offset("[ab]"), None);
        assert_eq!(marker_inner_offset("[!]"), None);
        assert_eq!(marker_inner_offset("[>]"), None);
        assert_eq!(marker_inner_offset("hello"), None);
        assert_eq!(marker_inner_offset(""), None);
    }

    /// Research §3's adversarial recognition table, verbatim: every input that
    /// was probed against `pulldown-cmark` with mark's own option set, and what
    /// the structural rule must say about it.
    ///
    /// This is the most valuable test in the change. Recognition is the only
    /// part of five-state support that is not obviously cheap, and the failure
    /// mode of getting it wrong — a false positive on `prose [-] bracket`, or a
    /// false negative on a real `- [/]` — is silent in both directions.
    ///
    /// Each row is `(input, expected tasks as (state, marker text))`.
    #[test]
    fn research_3_recognition_table() {
        use State::{Blocked, Cancelled, Done, InProgress, Open};

        let cases: &[(&str, &[(State, &str)])] = &[
            // --- recognised: one bullet spelling per row, all four bullets ---
            ("- [-] x\n", &[(Cancelled, "[-]")]),
            ("* [-] x\n", &[(Cancelled, "[-]")]),
            ("+ [-] x\n", &[(Cancelled, "[-]")]),
            ("1. [-] x\n", &[(Cancelled, "[-]")]),
            // ...and the other two extended states, which share the rule.
            ("- [/] x\n", &[(InProgress, "[/]")]),
            ("- [?] x\n", &[(Blocked, "[?]")]),
            // Tabs around the marker.
            ("-\t[-]\tx\n", &[(Cancelled, "[-]")]),
            // Bare, at end of line: matches `- [ ]`, which pulldown accepts.
            ("- [-]\n", &[(Cancelled, "[-]")]),
            // Bare, at end of file with no newline at all.
            ("- [?]", &[(Blocked, "[?]")]),
            // Inside a blockquote.
            ("> - [-] quoted\n", &[(Cancelled, "[-]")]),
            // A nested item carries its own marker, and both are counted.
            (
                "- [ ] parent\n  - [-] child\n",
                &[(Open, "[ ]"), (Cancelled, "[-]")],
            ),
            // A loose list interposes a paragraph; GFM markers survive it, so
            // extended ones must too.
            ("- [-] a\n\n- [ ] b\n", &[(Cancelled, "[-]"), (Open, "[ ]")]),
            // GFM markers keep working, unchanged, beside extended ones.
            (
                "- [x] done\n- [-] dropped\n",
                &[(Done, "[x]"), (Cancelled, "[-]")],
            ),
            // --- not recognised ------------------------------------------
            // No trailing whitespace. `- [x]nospace` is not a task either, so
            // the two vocabularies stay symmetric.
            ("- [-]nospace\n", &[]),
            ("- [/]**bold**\n", &[]),
            // The triple is not at the head of the item.
            ("- foo [-] bar\n", &[]),
            // Not in a list item at all.
            ("prose [-] bracket\n", &[]),
            // `Start(Emphasis)` comes first.
            ("- *[-]* weird\n", &[]),
            // Parsed as links — the bracket never reaches the text path, and
            // neither of these is a task today either.
            ("- [x](http://x)\n", &[]),
            ("- [-][ref]\n", &[]),
            // Two bytes between the brackets.
            ("- [ab] x\n", &[]),
            // A byte outside the allowlist.
            ("- [!] x\n", &[]),
            ("- [>] deferred\n", &[]),
            // Fenced and inline code are not documents.
            ("```\n- [-] fenced\n```\n", &[]),
            ("`- [-] inline`\n", &[]),
        ];

        for (input, expected) in cases {
            let tasks = enumerate_source(input);
            let actual: Vec<(State, &str)> = tasks
                .iter()
                .map(|task| (task.state, &input[task.start..task.end]))
                .collect();
            assert_eq!(
                actual,
                expected.to_vec(),
                "recognition disagreed for {input:?}"
            );

            // Counting takes a different path through the same rule, so it is
            // checked against the same table rather than trusted.
            let counts = counts(input);
            assert_eq!(
                counts.total,
                expected.len(),
                "counts disagreed with enumeration for {input:?}"
            );
        }
    }

    /// The lookahead is one byte, and it is the *source* byte after `]`.
    #[test]
    fn a_marker_needs_whitespace_or_the_end_after_it() {
        assert_eq!(enumerate_source("- [-] x\n").len(), 1);
        assert_eq!(enumerate_source("- [-]\tx\n").len(), 1);
        assert_eq!(enumerate_source("- [-]\n").len(), 1);
        assert_eq!(enumerate_source("- [-]").len(), 1);
        assert_eq!(enumerate_source("- [-]x\n").len(), 0);
        assert_eq!(enumerate_source("- [-]:\n").len(), 0);
    }

    #[test]
    fn extended_markers_are_written_like_gfm_ones() {
        let src = "- [-] dropped\n";
        let toggled = toggle(src, 0, Action::On).unwrap();
        assert_eq!(toggled.source, "- [x] dropped\n");
        assert_eq!(toggled.offset, 3);
        assert_eq!(toggled.state, State::Done);
        assert_eq!(src.len(), toggled.source.len());
    }

    #[test]
    fn every_state_is_reachable_from_every_other() {
        for from in State::ALL {
            for to in State::ALL {
                let src = format!("- [{}] item\n", char::from(from.byte()));
                let toggled = toggle(&src, 0, Action::for_state(to)).unwrap();
                assert_eq!(toggled.state, to, "{from:?} -> {to:?}");
                assert_eq!(
                    toggled.source,
                    format!("- [{}] item\n", char::from(to.byte()))
                );
            }
        }
    }

    #[test]
    fn toggle_ticks_the_box_from_every_extended_state() {
        for state in [State::InProgress, State::Cancelled, State::Blocked] {
            let src = format!("- [{}] item\n", char::from(state.byte()));
            let toggled = toggle(&src, 0, Action::Toggle).unwrap();
            assert_eq!(toggled.state, State::Done, "toggling {state:?}");
        }
        assert_eq!(
            toggle("- [ ] i\n", 0, Action::Toggle).unwrap().state,
            State::Done
        );
        assert_eq!(
            toggle("- [x] i\n", 0, Action::Toggle).unwrap().state,
            State::Open
        );
    }

    #[test]
    fn checked_means_terminal_not_done() {
        let tasks = enumerate_source("- [ ] a\n- [/] b\n- [x] c\n- [-] d\n- [?] e\n");
        let checked: Vec<bool> = tasks.iter().map(|t| t.checked).collect();
        assert_eq!(checked, vec![false, false, true, true, false]);
    }

    #[test]
    fn cancelled_leaves_the_denominator_and_nothing_else_does() {
        let counts = counts("- [ ] a\n- [/] b\n- [x] c\n- [-] d\n- [?] e\n");
        assert_eq!(counts.total, 5);
        assert_eq!(counts.outstanding(), 3);
        assert_eq!(counts.active(), 4);
        assert_eq!(
            (
                counts.open,
                counts.in_progress,
                counts.done,
                counts.cancelled,
                counts.blocked
            ),
            (1, 1, 1, 1, 1)
        );
    }

    /// The ADR's central compatibility claim, stated as arithmetic: for a
    /// document containing only GFM markers, the new badge reduces to the old
    /// one.
    #[test]
    fn a_gfm_only_documents_counts_are_unchanged() {
        let source = "- [x] done\n- [ ] one\n- [ ] two\n1. [ ] three\n\nA literal [ ] in prose.\n";
        let counts = counts(source);
        assert_eq!((counts.open, counts.total), (3, 4));
        assert_eq!(counts.outstanding(), counts.open);
        assert_eq!(counts.active(), counts.total);
        assert_eq!(
            (counts.in_progress, counts.cancelled, counts.blocked),
            (0, 0, 0)
        );
    }

    #[test]
    fn state_names_round_trip() {
        for state in State::ALL {
            assert_eq!(State::from_name(state.as_str()), Some(state));
            assert_eq!(State::from_byte(state.byte()), Some(state));
        }
        assert_eq!(State::from_name("doing"), None);
        assert_eq!(State::from_name("in progress"), None);
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

    // --- metadata (2026-08-27-inline-task-metadata) ----------------------

    #[test]
    fn text_keeps_its_meaning_and_label_is_the_stripped_one() {
        let tasks = enumerate_source("- [ ] ship the thing @work !! @due(2026-09-01)\n");
        let task = &tasks[0];
        assert_eq!(task.text, "ship the thing @work !! @due(2026-09-01)");
        assert_eq!(task.label, "ship the thing");
        assert_eq!(task.due.as_deref(), Some("2026-09-01"));
        assert_eq!(task.priority, 2);
        assert_eq!(
            task.tags,
            vec![Tag {
                name: "work".to_owned(),
                value: None
            }]
        );
    }

    #[test]
    fn a_metadata_free_label_is_the_text() {
        let tasks = enumerate_source("- [ ] ship `mark` **now**\n");
        assert_eq!(tasks[0].text, "ship mark now");
        assert_eq!(tasks[0].label, tasks[0].text);
        assert_eq!(tasks[0].priority, 0);
        assert!(tasks[0].tags.is_empty());
    }

    /// The whitespace-delimitation rule, which is what keeps the false-positive
    /// rate down to the cases the ADR accepts.
    #[test]
    fn a_token_must_be_whitespace_delimited_on_both_sides() {
        let tasks = enumerate_source("- [ ] email bob@example.com about it\n");
        assert_eq!(tasks[0].label, "email bob@example.com about it");
        assert!(tasks[0].tags.is_empty(), "{:?}", tasks[0].tags);

        let tasks = enumerate_source("- [ ] ship it!!!\n");
        assert_eq!(tasks[0].priority, 0);
        assert_eq!(tasks[0].label, "ship it!!!");

        // ...and the same characters, standing alone, are metadata.
        let tasks = enumerate_source("- [ ] ship it !!!\n");
        assert_eq!(tasks[0].priority, 3);
        assert_eq!(tasks[0].label, "ship it");
    }

    #[test]
    fn metadata_inside_a_code_span_is_not_metadata() {
        let tasks = enumerate_source("- [ ] document `@due(2026-09-01)` and `!!` today\n");
        assert_eq!(tasks[0].due, None);
        assert_eq!(tasks[0].priority, 0);
        assert!(tasks[0].tags.is_empty(), "{:?}", tasks[0].tags);
        assert_eq!(tasks[0].label, "document @due(2026-09-01) and !! today");
    }

    #[test]
    fn metadata_inside_math_is_not_metadata() {
        let tasks = enumerate_source("- [ ] prove $a@b$ now\n");
        assert!(tasks[0].tags.is_empty(), "{:?}", tasks[0].tags);
        assert_eq!(tasks[0].label, "prove $a@b$ now");
    }

    #[test]
    fn a_malformed_date_is_an_untyped_tag() {
        for value in ["friday", "2026-13-45", "2026-2-30", "26-09-01", ""] {
            let source = format!("- [ ] thing @due({value})\n");
            let tasks = enumerate_source(&source);
            assert_eq!(tasks[0].due, None, "@due({value}) parsed as a date");
            assert_eq!(
                tasks[0].tags,
                vec![Tag {
                    name: "due".to_owned(),
                    value: Some(value.to_owned())
                }],
                "@due({value})"
            );
            assert_eq!(tasks[0].label, "thing");
        }
    }

    #[test]
    fn known_keys_are_typed_and_everything_else_is_carried() {
        let tasks = enumerate_source(
            "- [x] a @start(2026-08-01) @due(2026-09-01) @done(2026-08-27) @owner(ana) @home\n",
        );
        let task = &tasks[0];
        assert_eq!(task.start_date.as_deref(), Some("2026-08-01"));
        assert_eq!(task.due.as_deref(), Some("2026-09-01"));
        assert_eq!(task.done.as_deref(), Some("2026-08-27"));
        assert_eq!(
            task.tags,
            vec![
                Tag {
                    name: "owner".to_owned(),
                    value: Some("ana".to_owned())
                },
                Tag {
                    name: "home".to_owned(),
                    value: None
                }
            ]
        );
        assert_eq!(task.label, "a");
    }

    #[test]
    fn tokens_that_only_look_like_tags_are_prose() {
        let tasks = enumerate_source("- [ ] read @ 5pm @(x) @!! and@then\n");
        assert!(tasks[0].tags.is_empty(), "{:?}", tasks[0].tags);
        assert_eq!(tasks[0].label, "read @ 5pm @(x) @!! and@then");
    }

    #[test]
    fn priority_takes_the_highest_it_is_told() {
        let tasks = enumerate_source("- [ ] a ! thing !!!\n");
        assert_eq!(tasks[0].priority, 3);
        assert_eq!(tasks[0].label, "a thing");
        // Four is not a priority; it stays in the text.
        let tasks = enumerate_source("- [ ] a !!!! thing\n");
        assert_eq!(tasks[0].priority, 0);
        assert_eq!(tasks[0].label, "a !!!! thing");
    }

    /// `--stamp`'s insertion point, taken from an event span rather than a
    /// search, so it is right for an item whose text ends inside inline markup
    /// and for one that has no text at all.
    #[test]
    fn label_end_points_just_past_the_items_last_visible_byte() {
        let cases = [
            ("- [ ] a thing\n", "- [ ] a thing"),
            ("- [ ] a **bold** thing\n", "- [ ] a **bold** thing"),
            ("- [ ] a thing   \n", "- [ ] a thing"),
            ("- [ ] a `code` end\n", "- [ ] a `code` end"),
            ("- [-]\n", "- [-]"),
            ("- [ ] parent\n  - [ ] child\n", "- [ ] parent"),
        ];
        for (source, upto) in cases {
            let tasks = enumerate_source(source);
            assert_eq!(
                &source[..tasks[0].label_end],
                upto,
                "label_end wrong for {source:?}"
            );
        }
    }

    #[test]
    fn iso_dates_are_the_only_dates() {
        assert_eq!(parse_iso_date("2026-09-01"), Some((2026, 9, 1)));
        assert_eq!(parse_iso_date("2024-02-29"), Some((2024, 2, 29)));
        assert_eq!(parse_iso_date("2026-02-29"), None);
        assert_eq!(parse_iso_date("2026-9-01"), None);
        assert_eq!(parse_iso_date("2026/09/01"), None);
        assert_eq!(parse_iso_date("friday"), None);
    }

    #[test]
    fn no_tag_participates_in_the_counts() {
        let counts = counts("- [ ] a @blocked @doing\n- [x] b @cancelled\n");
        assert_eq!(
            (
                counts.open,
                counts.done,
                counts.blocked,
                counts.in_progress,
                counts.cancelled
            ),
            (1, 1, 0, 0, 0)
        );
        assert_eq!(counts.active(), 2);
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
