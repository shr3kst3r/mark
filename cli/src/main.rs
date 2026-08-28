//! `mark-cli` — the headless half of `mark`.
//!
//! ADR-1 ships two Mach-O executables and this is the one an agent calls in a
//! loop, so per-invocation cost is a feature: the measured budget is ~2.84 ms
//! for a clap binary against a 2.28 ms `exec` floor. Nothing here does work
//! before dispatch — syntect's assets, in particular, load lazily on first use
//! so `mark toc` never pays for a highlighter it will not use.
//!
//! Every subcommand goes through `mark_core`. There is no second
//! implementation of parsing, task semantics, or directory queries for the CLI
//! to drift from.
//!
//! Exit codes: 0 success, 1 usage or unexpected failure, 2 unreadable or
//! missing file, 3 task index out of range (plan §3), 4 could not reach the
//! app, 5 the app refused the command, 6 another `mark` holds the document's
//! write lock. Those are a contract an agent scripts against, so usage errors
//! are mapped off clap's default of 2 — otherwise "you typo'd a flag" and
//! "that file does not exist" are the same answer.
//!
//! 4 and 5 are M4's, and the split is the useful one for a caller: 4 means the
//! command never arrived and is worth retrying, 5 means it arrived and the
//! answer was no. Plan §3 fixes 2 and 3 and says nothing about the IPC codes;
//! these extend it in the direction those two establish.
//!
//! 6 is `2026-08-25-flock-write-locking`'s, and it exists because that ADR
//! requires *"a distinct code so a caller can branch on 'locked' separately
//! from 'no such file' and 'refused'"*. It is the one code here that describes
//! **another process's state** rather than this one's: nothing about the
//! filesystem explains it, which is exactly why folding it into 2 would be
//! undebuggable.
//!
//! Every byte this prints goes through [`Output`]. A closed pipe is ordinary
//! use of a tool people run as `mark render big.md | head`, and Rust ignores
//! SIGPIPE, so `print!` would turn it into a panic and exit 101.

mod ansi;
mod client;
mod wire;

use std::collections::HashMap;
use std::fmt;
use std::fs;
use std::io::{self, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Instant;

use clap::{Args, Parser, Subcommand};
use mark_core::diff;
use mark_core::git::{self, GitError};
use mark_core::lines;
use mark_core::parse::Document;
use mark_core::render::{RenderOptions, render};
use mark_core::tasks::{self, Action, TaskError};
use mark_core::theme::{self, ThemeError};
use mark_core::tree::{self, TreeError};
use serde::Serialize;

use crate::client::{Client, IpcError};
use crate::wire::Request;

const EXIT_USAGE: u8 = 1;
const EXIT_FILE: u8 = 2;
const EXIT_TASK_RANGE: u8 = 3;
/// The app could not be reached: no socket, a launch that failed, a reply that
/// never came.
const EXIT_IPC: u8 = 4;
/// The app was reached and refused — ADR-3's "anchor not found exits non-zero
/// rather than silently succeeding".
const EXIT_REFUSED: u8 = 5;
/// Another `mark` holds the document's `flock(2)` write lock: a GUI window with
/// unsaved edits, or another CLI mid-write. Nothing was written, and the
/// message names the pid holding it (`2026-08-25-flock-write-locking`).
///
/// Distinct from 2 on purpose. A caller retrying "the file is busy" and a
/// caller reporting "there is no such file" want opposite behaviour, and the
/// only difference visible from the outside is this number.
const EXIT_LOCKED: u8 = 6;

/// Depth limit for the recursive commands. Deep enough for any real notes tree
/// and bounded, because a large source tree (`~/src`) holds 608k files (research 2.8).
const DEFAULT_RECURSIVE_DEPTH: usize = 64;

#[derive(Parser)]
#[command(
    name = "mark",
    // Not clap's bare `version`, which reports the semver alone. `mark` ships
    // as a Homebrew `--HEAD` formula, so the semver is the same across every
    // install between two bumps; the commit is what identifies a build, and
    // `mark --version` is the first thing anyone reads when the answer to
    // "which one am I running?" stops being obvious.
    version = mark_core::BUILD,
    // What a first-time reader of `mark --help` needs: what this is, and that
    // some of these commands need no app while others drive one. "Headless
    // half" was true when there was nothing else, and stopped being useful
    // once there was a window to be half of.
    about = "Read, search, and edit markdown. Drives mark.app when it is running; \
             render/toc/tasks/check/ls/grep/stats/doctor need no app at all.",
    after_help = "Exit codes: 0 ok, 1 usage, 2 unreadable file, 3 task index, \
                  4 app unreachable, 5 app refused, 6 document locked by \
                  another mark.  See `man mark`.",
    disable_help_subcommand = true
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Render a document to stdout.
    Render {
        file: PathBuf,
        #[command(flatten)]
        format: Format,
        /// Emit only the first N top-level blocks (ADR-2's first-paint prefix).
        #[arg(long, value_name = "N")]
        prefix: Option<usize>,
        /// Theme to render with. `mark theme --list` names them.
        ///
        /// `--html` carries **both** appearances whatever this says, because
        /// the page picks with `prefers-color-scheme`; this chooses the pair.
        /// `--ansi` has no CSS to defer to, so it takes the named theme's own
        /// colours.
        #[arg(long, value_name = "NAME")]
        theme: Option<String>,
    },
    /// Show what changed against git HEAD.
    ///
    /// A **file** shows its own changed lines; a **directory**, or nothing at
    /// all, shows one row per changed file in the repository — which is the
    /// same pair of meanings `mark open` and `mark ls` already give a path.
    ///
    /// Exits 0 for a path that is not in a git repository, saying so on stderr.
    /// That is not a failure: `2026-08-28-git-differences-by-running-git` makes
    /// "no git here" an ordinary answer rather than an error, and a script
    /// asking "what changed?" of a plain directory deserves an empty answer
    /// rather than a non-zero exit.
    Diff {
        path: Option<PathBuf>,
        #[command(flatten)]
        format: Format,
        #[arg(long)]
        json: bool,
        /// Counts only, with no hunks, even for a single file.
        #[arg(long)]
        stat: bool,
        /// Leave untracked files out. They are included by default, with every
        /// line counted as added.
        #[arg(long)]
        tracked: bool,
        /// Theme for `--html` and for the colours `--ansi` uses.
        #[arg(long, value_name = "NAME")]
        theme: Option<String>,
    },
    /// Print the heading tree, with anchors and byte offsets.
    Toc {
        file: PathBuf,
        #[arg(long)]
        json: bool,
    },
    /// List every task in a file or directory.
    Tasks {
        /// File or directory. Defaults to the current directory.
        path: Option<PathBuf>,
        /// Only tasks that are still outstanding: open, in progress, or
        /// blocked. Cancelled and done are both finished with.
        #[arg(long)]
        open: bool,
        /// Only this state. Repeatable, and any of them matches:
        /// open, in-progress, done, cancelled, blocked.
        #[arg(long = "state", value_name = "NAME")]
        states: Vec<String>,
        /// Only tasks carrying this `@tag`. Repeatable; the `@` is optional.
        #[arg(long = "tag", value_name = "TAG")]
        tags: Vec<String>,
        /// Only tasks at this priority or higher (1 = `!`, 3 = `!!!`).
        #[arg(long, value_name = "N")]
        priority: Option<u8>,
        /// Only tasks due strictly before a date, `today`, or `+Nd`.
        #[arg(long = "due-before", value_name = "WHEN")]
        due_before: Option<String>,
        /// Only tasks due strictly after a date, `today`, or `+Nd`.
        #[arg(long = "due-after", value_name = "WHEN")]
        due_after: Option<String>,
        /// Only tasks whose `@due(…)` is before today. Implies a clock; see
        /// `--today`.
        #[arg(long)]
        overdue: bool,
        /// Only tasks with no `@due(…)` at all.
        #[arg(long = "no-due")]
        no_due: bool,
        /// Order the answer: due, priority, state, or index (the default,
        /// document order).
        #[arg(long, value_name = "KEY")]
        sort: Option<String>,
        /// What "today" means, for `--overdue` and for `+Nd` offsets. Defaults
        /// to the local date. This is the only place a date comparison reads a
        /// clock, and it is overridable so the behaviour is testable
        /// (2026-08-27-inline-task-metadata).
        #[arg(long, value_name = "YYYY-MM-DD")]
        today: Option<String>,
        #[arg(long)]
        json: bool,
        #[arg(long, default_value_t = DEFAULT_RECURSIVE_DEPTH, value_name = "N")]
        depth: usize,
    },
    /// Set, clear, or flip one task's checkbox, in place.
    Check {
        file: PathBuf,
        /// Task index in document order, as reported by `mark tasks`.
        #[arg(long, value_name = "N")]
        item: usize,
        #[command(flatten)]
        action: CheckAction,
        /// Append `@done(YYYY-MM-DD)` to the item when it becomes done.
        /// Opt-in, because it is the only write in the product that is not one
        /// byte (2026-08-27-inline-task-metadata).
        #[arg(long)]
        stamp: bool,
        /// The date `--stamp` writes. Defaults to the local date.
        #[arg(long, value_name = "YYYY-MM-DD")]
        today: Option<String>,
        #[arg(long)]
        json: bool,
    },
    /// Rewrite mark's extended task markers as plain GFM, losslessly.
    ///
    /// `[-]` becomes `[x] ~~text~~`, `[/]` and `[?]` become `[ ]` carrying an
    /// `@doing` / `@blocked` tag. Writes to **stdout** unless `--in-place`.
    Normalize {
        file: PathBuf,
        /// Degrade to GFM. The only mode there is, and the default; naming it
        /// leaves room for the reverse without changing what a bare
        /// `mark normalize` does.
        #[arg(long)]
        gfm: bool,
        /// Rewrite the file itself, through the same atomic write and the same
        /// `flock` every other write takes (2026-08-25-flock-write-locking).
        #[arg(long = "in-place")]
        in_place: bool,
        /// Report what would change and write nothing, anywhere.
        #[arg(long)]
        check: bool,
    },
    /// List markdown files, with titles and task counts.
    Ls {
        dir: Option<PathBuf>,
        #[arg(long)]
        json: bool,
        /// Levels to descend. 1 lists this directory only.
        #[arg(long, default_value_t = 1, value_name = "N")]
        depth: usize,
        /// Include non-markdown files.
        #[arg(long)]
        all: bool,
        /// Add each file's changed lines against git HEAD, as `+12 -3`.
        ///
        /// One `git` query for the listing's repository, not one per file —
        /// see `2026-08-28-git-differences-by-running-git` for why that is the
        /// unit. Silently adds nothing for a directory that is not in a
        /// repository.
        #[arg(long)]
        git: bool,
    },
    /// Search markdown files, reporting the heading each match sits under.
    Grep {
        /// Regular expression.
        pattern: String,
        path: Option<PathBuf>,
        #[arg(long)]
        json: bool,
        /// Case-insensitive matching.
        #[arg(short = 'i', long)]
        ignore_case: bool,
        #[arg(long, default_value_t = DEFAULT_RECURSIVE_DEPTH, value_name = "N")]
        depth: usize,
    },
    /// Per-stage timings and counters for one document.
    Stats {
        file: PathBuf,
        #[arg(long)]
        json: bool,
    },
    /// Environment report to paste into a bug report.
    Doctor {
        #[arg(long)]
        json: bool,
    },

    // ---- ADR-3: everything below drives the running app over the socket ----
    /// Open a document in the app, starting it if it is not running.
    ///
    /// A **directory** roots the sidebar there instead, which is what
    /// `mark nav <dir>` does — the app answers with whichever it did, so a
    /// caller does not have to stat the path to know what happened.
    Open {
        #[arg(value_name = "PATH")]
        file: PathBuf,
        /// Add the tab without moving the reader off the current document.
        ///
        /// The default selects what it opens. Neither form activates the app:
        /// ADR-3 launches with `open -g` so focus is not stolen, and a command
        /// that raised the window afterwards would undo that.
        #[arg(long)]
        tab: bool,
        #[arg(long)]
        json: bool,
    },
    /// List, select, and close the app's tabs.
    Tab {
        #[command(subcommand)]
        action: TabAction,
    },
    /// Choose a theme, or inspect the ones there are.
    ///
    /// `mark theme <name>` and bare `mark theme` talk to the running app over
    /// the socket (ADR-3). `--list`, `--show`, and `--import` are answered
    /// **locally** by the core, so they work with no app running — which is the
    /// case an agent is usually in.
    ///
    /// Naming a theme shows *that* theme: `mark theme solarized-light` is light
    /// even on a Mac that is in dark mode. `--system` is the way back to
    /// following the system appearance between the pair's two halves.
    Theme {
        /// The theme to apply. With no name and no flags, report the active one.
        name: Option<String>,
        /// Follow the system appearance instead of pinning the named half.
        ///
        /// On its own, with no name: keep the theme and go back to switching
        /// with macOS.
        #[arg(long, conflicts_with_all = ["list", "show", "import"])]
        system: bool,
        /// List the available themes instead of applying one.
        #[arg(long)]
        list: bool,
        /// Dump a theme's resolved palette, chrome, scope map, and CSS.
        #[arg(long, value_name = "NAME")]
        show: Option<String>,
        /// Convert a .tmTheme or a base16 scheme .yaml into ~/.config/mark/themes.
        #[arg(long, value_name = "FILE")]
        import: Option<PathBuf>,
        #[arg(long)]
        json: bool,
    },
    /// Scroll the front document to a heading anchor.
    ///
    /// Exits 5 when the document has no such anchor, which is what makes this
    /// scriptable — ADR-3's own example of a failure the CLI must report.
    Goto {
        /// With or without the leading `#`.
        anchor: String,
        #[arg(long)]
        json: bool,
    },
    /// Re-read the front document from disk and patch the page.
    Reload {
        #[arg(long)]
        json: bool,
    },
    /// Report the sidebar: root, breadcrumb, history, and what it is showing.
    Sidebar {
        #[arg(long)]
        json: bool,
    },
    /// Move the sidebar's root.
    ///
    /// The CLI half of M8's navigation, and the same four moves the window
    /// offers: a directory to root at, its parent (⌘↑ in the app), or back and
    /// forward through the roots already visited (⌘[ / ⌘]).
    ///
    /// `mark open <dir>` does the same thing as `mark nav <dir>`; this form
    /// exists because `--up`, `--back`, and `--forward` have no path to name.
    Nav {
        /// The directory to root the sidebar at.
        dir: Option<PathBuf>,
        #[command(flatten)]
        to: NavTarget,
        #[arg(long)]
        json: bool,
    },
}

/// `mark nav`'s three relative moves. Mutually exclusive, and mutually
/// exclusive with a directory — which clap cannot express across a flattened
/// group and a positional, so [`NavTarget::request`] says it in a sentence.
#[derive(Args)]
#[group(multiple = false)]
struct NavTarget {
    /// The current root's parent directory.
    #[arg(long, visible_alias = "parent")]
    up: bool,
    /// The previous root. Exits 5 if there is nothing to go back to.
    #[arg(long)]
    back: bool,
    /// Forward again, after `--back`.
    #[arg(long)]
    forward: bool,
}

impl NavTarget {
    /// The `nav` request for this combination of a path and three flags.
    ///
    /// The app takes either a `path` or a `to` of parent/back/forward
    /// (`CommandRouter.swift`), so exactly one of the four has to be named.
    /// Saying which is missing beats clap's group message here, because the
    /// interesting case — `mark nav` with nothing at all — is a person who has
    /// not read `--help` yet.
    fn request(&self, dir: Option<&Path>) -> Result<Request, CliError> {
        // The names are the flags as typed, which is also what the app accepts:
        // `NavigationTarget(relative:)` takes "up" as a synonym for "parent",
        // so an error message and a wire argument can be the same string.
        let relative = [
            (self.up, "up"),
            (self.back, "back"),
            (self.forward, "forward"),
        ]
        .into_iter()
        .find(|(set, _)| *set)
        .map(|(_, name)| name);
        match (dir, relative) {
            (Some(dir), None) => {
                Ok(Request::new("nav").arg("path", absolute(dir)?.to_string_lossy()))
            }
            (None, Some(to)) => Ok(Request::new("nav").arg("to", to)),
            (None, None) => Err(CliError::Usage(
                "nav needs a directory, or one of --up, --back, --forward".to_owned(),
            )),
            (Some(dir), Some(to)) => Err(CliError::Usage(format!(
                "nav takes a directory or --{to}, not both (you gave {})",
                dir.display()
            ))),
        }
    }
}

#[derive(Subcommand)]
enum TabAction {
    /// Every open tab, in bar order.
    List {
        #[arg(long)]
        json: bool,
    },
    /// Bring a tab to the front.
    Select {
        /// A tab index from `mark tab list`, or a file path.
        target: String,
        #[arg(long)]
        json: bool,
    },
    /// Close a tab. With no argument, the selected one.
    Close {
        /// A tab index from `mark tab list`, or a file path.
        target: Option<String>,
        /// Close every tab in the window, both halves of a split included.
        ///
        /// The window stays open on its empty state, exactly as it does when
        /// the last tab is closed by hand — this is File > Close All Tabs, not
        /// Close Window. Conflicts with naming a tab: closing all of them and
        /// closing that one are two different requests.
        #[arg(long, conflicts_with = "target")]
        all: bool,
        #[arg(long)]
        json: bool,
    },
}

impl TabAction {
    /// An argument that is all digits is an index; anything else is a path.
    ///
    /// Ambiguity is theoretically possible — a file literally named `2` — and
    /// is resolved in favour of the index, which is what someone typing
    /// `mark tab close 2` means. `--path`-style disambiguation is available by
    /// passing `./2`, which is also how `rm` handles the same problem.
    fn selector(command: &str, target: &str) -> Result<Request, CliError> {
        let request = Request::new(command);
        if !target.is_empty() && target.chars().all(|c| c.is_ascii_digit()) {
            return Ok(request.arg("index", target));
        }
        Ok(request.arg("path", absolute(Path::new(target))?.to_string_lossy()))
    }
}

#[derive(Args)]
#[group(multiple = false)]
struct Format {
    /// A complete, self-contained HTML document.
    #[arg(long)]
    html: bool,
    /// Styled terminal output.
    #[arg(long)]
    ansi: bool,
    /// Terminal output with no escape sequences.
    #[arg(long)]
    plain: bool,
}

#[derive(Args)]
#[group(multiple = false)]
struct CheckAction {
    /// Check the box.
    #[arg(long)]
    on: bool,
    /// Uncheck the box.
    #[arg(long)]
    off: bool,
    /// Flip it. The default. Open becomes done, done becomes open, and any
    /// other state becomes done — ticking a box ticks it.
    #[arg(long)]
    toggle: bool,
    /// Set it to a named state: open, in-progress, done, cancelled, blocked.
    #[arg(long, value_name = "NAME")]
    state: Option<String>,
}

impl CheckAction {
    /// The action, or a usage error naming what was accepted.
    fn action(&self) -> Result<Action, CliError> {
        if let Some(name) = &self.state {
            return match tasks::State::from_name(name) {
                Some(state) => Ok(Action::for_state(state)),
                None => Err(CliError::Usage(unknown_state(name))),
            };
        }
        Ok(match (self.on, self.off) {
            (true, _) => Action::On,
            (_, true) => Action::Off,
            _ => Action::Toggle,
        })
    }
}

/// One message for every `--state` in the CLI, listing what is accepted.
fn unknown_state(name: &str) -> String {
    let names: Vec<&str> = tasks::State::ALL.iter().map(|s| s.as_str()).collect();
    format!(
        "unknown task state {name:?}; expected one of {}",
        names.join(", ")
    )
}

fn main() -> ExitCode {
    let cli = match Cli::try_parse() {
        Ok(cli) => cli,
        Err(error) => {
            // `--help` and `--version` are successes clap models as errors, and
            // it already knows which stream each belongs on.
            let _ = error.print();
            return if error.use_stderr() {
                ExitCode::from(EXIT_USAGE)
            } else {
                ExitCode::SUCCESS
            };
        }
    };

    match run(&cli.command) {
        Ok(()) => ExitCode::SUCCESS,
        // The reader went away (`| head`). There is nothing wrong and nowhere
        // left to complain to, so say nothing and succeed.
        Err(CliError::Output(error)) if error.kind() == io::ErrorKind::BrokenPipe => {
            ExitCode::SUCCESS
        }
        Err(error) => {
            let _ = writeln!(io::stderr(), "mark: {error}");
            ExitCode::from(error.code())
        }
    }
}

/// Anything a subcommand can fail with, carrying its exit code.
#[derive(Debug)]
enum CliError {
    Read {
        path: PathBuf,
        source: io::Error,
    },
    Task(TaskError),
    Tree(TreeError),
    Pattern(Box<regex::Error>),
    /// Writing to stdout failed. Broken pipe is handled in `main` and never
    /// reaches an exit code; anything else is a genuine I/O failure.
    Output(io::Error),
    /// ADR-3's socket: could not reach the app, or the app said no.
    Ipc(IpcError),
    /// We could not find out what git thinks. Never "not in a repository",
    /// which `2026-08-28-git-differences-by-running-git` makes an ordinary
    /// answer rather than a failure.
    Git(GitError),
    /// A theme that does not exist, will not parse, or is missing a slot.
    Theme(ThemeError),
    /// A combination of arguments clap accepts and this tool does not — today
    /// only `mark nav`, whose positional directory and three relative flags
    /// are mutually exclusive in a way a flattened group cannot state.
    Usage(String),
}

impl CliError {
    fn code(&self) -> u8 {
        match self {
            CliError::Read { .. } => EXIT_FILE,
            CliError::Tree(_) => EXIT_FILE,
            CliError::Task(TaskError::Io { .. }) => EXIT_FILE,
            CliError::Task(TaskError::IndexOutOfRange { .. }) => EXIT_TASK_RANGE,
            CliError::Task(TaskError::MarkerMoved { .. }) => EXIT_TASK_RANGE,
            CliError::Task(TaskError::Locked(_)) => EXIT_LOCKED,
            CliError::Pattern(_) | CliError::Output(_) => EXIT_USAGE,
            CliError::Ipc(error) => error.code(),
            // A theme file that will not load is a file problem when it is a
            // file, and a usage problem when the user simply named one that
            // does not exist.
            CliError::Theme(ThemeError::NotFound { .. }) => EXIT_USAGE,
            CliError::Theme(_) => EXIT_FILE,
            // A git query that failed is not the *file* being wrong, and it is
            // not usage. It is "the environment could not answer", which is
            // what EXIT_REFUSED already means for the socket and the anchor.
            CliError::Git(_) => EXIT_REFUSED,
            CliError::Usage(_) => EXIT_USAGE,
        }
    }
}

impl fmt::Display for CliError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CliError::Read { path, source } => write!(f, "{}: {source}", path.display()),
            CliError::Task(error) => error.fmt(f),
            CliError::Tree(error) => error.fmt(f),
            CliError::Pattern(error) => write!(f, "bad pattern: {error}"),
            CliError::Output(error) => write!(f, "writing to stdout: {error}"),
            CliError::Ipc(error) => error.fmt(f),
            CliError::Theme(error) => error.fmt(f),
            CliError::Git(error) => error.fmt(f),
            CliError::Usage(message) => write!(f, "{message}"),
        }
    }
}

impl std::error::Error for CliError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            CliError::Read { source, .. } | CliError::Output(source) => Some(source),
            CliError::Task(error) => Some(error),
            CliError::Tree(error) => Some(error),
            CliError::Pattern(error) => Some(error),
            CliError::Ipc(error) => Some(error),
            CliError::Theme(error) => Some(error),
            CliError::Git(error) => Some(error),
            CliError::Usage(_) => None,
        }
    }
}

impl From<IpcError> for CliError {
    fn from(error: IpcError) -> Self {
        CliError::Ipc(error)
    }
}

impl From<ThemeError> for CliError {
    fn from(error: ThemeError) -> Self {
        CliError::Theme(error)
    }
}

/// A locked stdout every subcommand writes through.
///
/// The point is the error type: a write into a closed pipe becomes a
/// [`CliError::Output`] that `main` turns into a silent exit 0, instead of the
/// panic and exit 101 that `print!` produces because Rust ignores SIGPIPE.
struct Output(io::StdoutLock<'static>);

impl Output {
    fn new() -> Output {
        Output(io::stdout().lock())
    }

    fn write(&mut self, args: fmt::Arguments<'_>) -> Result<(), CliError> {
        self.0.write_fmt(args).map_err(CliError::Output)
    }

    /// Flush before reporting success, so a failed write is an error rather
    /// than output that quietly never arrived.
    fn finish(mut self) -> Result<(), CliError> {
        self.0.flush().map_err(CliError::Output)
    }
}

/// `write!`, but into an [`Output`] and returning [`CliError`].
macro_rules! emit {
    ($out:expr, $($arg:tt)*) => { $out.write(format_args!($($arg)*)) };
}

/// `writeln!`, but into an [`Output`] and returning [`CliError`].
macro_rules! emitln {
    ($out:expr, $($arg:tt)*) => { $out.write(format_args!("{}\n", format_args!($($arg)*))) };
}

impl From<TaskError> for CliError {
    fn from(error: TaskError) -> Self {
        CliError::Task(error)
    }
}

impl From<GitError> for CliError {
    fn from(error: GitError) -> Self {
        CliError::Git(error)
    }
}

impl From<TreeError> for CliError {
    fn from(error: TreeError) -> Self {
        CliError::Tree(error)
    }
}

fn read(path: &Path) -> Result<String, CliError> {
    let started = Instant::now();
    let source = fs::read_to_string(path).map_err(|source| CliError::Read {
        path: path.to_path_buf(),
        source,
    })?;
    trace(
        || format!("read {} ({} bytes)", path.display(), source.len()),
        started,
    );
    Ok(source)
}

/// `MARK_TRACE=1` writes per-stage timings to stderr (plan §4). Off by default
/// and never touching stdout, so it cannot corrupt `--json` output.
fn trace(message: impl FnOnce() -> String, started: Instant) {
    if std::env::var_os("MARK_TRACE").is_some_and(|v| v != "0") {
        let _ = writeln!(
            io::stderr(),
            "mark[trace] {:>8.3} ms  {}",
            started.elapsed().as_secs_f64() * 1e3,
            message()
        );
    }
}

fn run(command: &Command) -> Result<(), CliError> {
    match command {
        Command::Render {
            file,
            format,
            prefix,
            theme,
        } => cmd_render(file, format, *prefix, theme.as_deref()),
        Command::Diff {
            path,
            format,
            json,
            stat,
            tracked,
            theme,
        } => cmd_diff(
            path.as_deref(),
            format,
            *json,
            *stat,
            *tracked,
            theme.as_deref(),
        ),
        Command::Toc { file, json } => cmd_toc(file, *json),
        Command::Tasks {
            path,
            open,
            states,
            tags,
            priority,
            due_before,
            due_after,
            overdue,
            no_due,
            sort,
            today,
            json,
            depth,
        } => cmd_tasks(
            path.as_deref(),
            &TaskQuery::new(
                *open,
                states,
                tags,
                *priority,
                due_before.as_deref(),
                due_after.as_deref(),
                *overdue,
                *no_due,
                sort.as_deref(),
                today.as_deref(),
            )?,
            *json,
            *depth,
        ),
        Command::Check {
            file,
            item,
            action,
            stamp,
            today,
            json,
        } => cmd_check(
            file,
            *item,
            action.action()?,
            *stamp,
            today.as_deref(),
            *json,
        ),
        Command::Normalize {
            file,
            gfm,
            in_place,
            check,
        } => cmd_normalize(file, *gfm, *in_place, *check),
        Command::Ls {
            dir,
            json,
            depth,
            all,
            git,
        } => cmd_ls(dir.as_deref(), *json, *depth, *all, *git),
        Command::Grep {
            pattern,
            path,
            json,
            ignore_case,
            depth,
        } => cmd_grep(pattern, path.as_deref(), *json, *ignore_case, *depth),
        Command::Stats { file, json } => cmd_stats(file, *json),
        Command::Doctor { json } => cmd_doctor(*json),
        Command::Open { file, tab, json } => cmd_open(file, *tab, *json),
        Command::Tab { action } => cmd_tab(action),
        Command::Theme {
            name,
            system,
            list,
            show,
            import,
            json,
        } => cmd_theme(
            name.as_deref(),
            *system,
            *list,
            show.as_deref(),
            import.as_deref(),
            *json,
        ),
        Command::Goto { anchor, json } => cmd_goto(anchor, *json),
        Command::Reload { json } => cmd_reload(*json),
        Command::Sidebar { json } => cmd_sidebar(*json),
        Command::Nav { dir, to, json } => cmd_nav(dir.as_deref(), to, *json),
    }
}

// ---------------------------------------------------------------------------
// ADR-3: the socket commands
// ---------------------------------------------------------------------------

/// An absolute path, without resolving symlinks.
///
/// Absolute because the app's working directory is not ours — it is wherever
/// LaunchServices started it — so a relative path would be resolved against the
/// wrong directory, silently, and open nothing.
///
/// **Not** `canonicalize`: that resolves symlinks, and opening the target of a
/// link instead of the link the user named would give the editing pane
/// (`2026-08-24-editing-pane-and-autosave`, M9) a file path that is not the one
/// it was asked for. That ADR already lists autosave-through-a-symlink as a
/// silent-corruption case; this is the same hazard one milestone earlier.
fn absolute(path: &Path) -> Result<PathBuf, CliError> {
    std::path::absolute(path).map_err(|source| CliError::Read {
        path: path.to_path_buf(),
        source,
    })
}

/// Send one command and hand back the app's `result`.
fn call(request: Request) -> Result<serde_json::Value, CliError> {
    let started = Instant::now();
    let client = Client::new()?;
    let result = client.send(&request);
    trace(|| format!("ipc {}", request.command), started);
    Ok(result?)
}

fn cmd_open(file: &Path, background: bool, json: bool) -> Result<(), CliError> {
    let path = absolute(file)?;
    // Checked here as well as in the app, so a typo does not launch a GUI to
    // be told about itself. The app keeps its own check: `mark://` reaches it
    // without passing through this function at all.
    if !path.exists() {
        return Err(CliError::Read {
            path: path.clone(),
            // Spelled out rather than `io::Error::from(NotFound)`, whose
            // `Display` is the unhelpful "entity not found".
            source: io::Error::new(io::ErrorKind::NotFound, "no such file"),
        });
    }

    let result = call(
        Request::new("open")
            .arg("path", path.to_string_lossy())
            .flag("tab", background),
    )?;

    if json {
        return print_json(&result);
    }
    let mut out = Output::new();
    // A directory is answered with a sidebar rather than a tab (M10): the app
    // roots the tree there, exactly as `mark nav <dir>` does. Keyed on which
    // answer arrived rather than on re-checking the path here, because the app
    // is the one that decided and a race would otherwise print the wrong
    // sentence.
    if !result["sidebar"].is_null() {
        emit_sidebar(&mut out, &result["sidebar"])?;
        return out.finish();
    }
    let tab = &result["tab"];
    emitln!(
        out,
        "{} -> tab {} of {}{}",
        tab["path"].as_str().unwrap_or_default(),
        tab["index"].as_i64().unwrap_or(-1),
        result["tabs"].as_i64().unwrap_or(0),
        if background { " (background)" } else { "" }
    )?;
    out.finish()
}

/// The sidebar, in the shape `mark sidebar`, `mark nav`, and `mark open <dir>`
/// all print — one function so the three cannot describe the same state three
/// ways.
fn emit_sidebar(out: &mut Output, sidebar: &serde_json::Value) -> Result<(), CliError> {
    let strings = |key: &str| -> Vec<String> {
        sidebar[key]
            .as_array()
            .map(|values| {
                values
                    .iter()
                    .filter_map(|value| value.as_str().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default()
    };
    emitln!(out, "{}", sidebar["root"].as_str().unwrap_or_default())?;
    // The components, not the path: the app's breadcrumb bar shows exactly
    // these, in this order, and the first one is always "/". Reading the two
    // side by side should not be an exercise in translation.
    emitln!(out, "  crumbs   {}", strings("breadcrumb").join(" > "))?;
    emitln!(
        out,
        "  history  {} back, {} forward",
        strings("back").len(),
        strings("forward").len()
    )?;
    let mut showing = vec![
        if sidebar["showsNonMarkdown"].as_bool() == Some(true) {
            "all files"
        } else {
            "markdown only"
        }
        .to_owned(),
    ];
    if sidebar["showsHidden"].as_bool() == Some(true) {
        showing.push("hidden files".to_owned());
    }
    showing.push(format!("by {}", sidebar["sort"].as_str().unwrap_or("name")));
    emitln!(out, "  showing  {}", showing.join(", "))?;
    let filter = sidebar["filter"].as_str().unwrap_or_default();
    if !filter.is_empty() {
        emitln!(out, "  filter   {filter:?}")?;
    }
    Ok(())
}

/// `mark sidebar` — where the tree is, without moving it.
fn cmd_sidebar(json: bool) -> Result<(), CliError> {
    let result = call(Request::new("sidebar"))?;
    if json {
        return print_json(&result["sidebar"]);
    }
    let mut out = Output::new();
    emit_sidebar(&mut out, &result["sidebar"])?;
    out.finish()
}

/// `mark nav` — M8's four moves, over the socket.
///
/// `--back` at the start of history exits 5 rather than succeeding quietly:
/// the app refuses the move and says so, which is ADR-3's reason for having a
/// reply channel and the reason this is scriptable at all.
fn cmd_nav(dir: Option<&Path>, to: &NavTarget, json: bool) -> Result<(), CliError> {
    let result = call(to.request(dir)?)?;
    if json {
        return print_json(&result["sidebar"]);
    }
    let mut out = Output::new();
    emit_sidebar(&mut out, &result["sidebar"])?;
    out.finish()
}

/// `text`, cut to `width` display columns with an ellipsis.
///
/// Counts `char`s rather than bytes: titles come from documents, and cutting a
/// multi-byte character in half would panic on the slice.
fn ellipsize(text: &str, width: usize) -> String {
    if text.chars().count() <= width {
        return text.to_owned();
    }
    let kept: String = text.chars().take(width.saturating_sub(1)).collect();
    format!("{}…", kept.trim_end())
}

fn cmd_tab(action: &TabAction) -> Result<(), CliError> {
    match action {
        TabAction::List { json } => {
            let result = call(Request::new("tab-list"))?;
            if *json {
                return print_json(&result["tabs"]);
            }
            let mut out = Output::new();
            let tabs = result["tabs"].as_array().cloned().unwrap_or_default();
            if tabs.is_empty() {
                emitln!(out, "no tabs are open")?;
            }
            // The location column appears only when there is more than one
            // place a tab can be: more than one window, or a window split into
            // two editor groups (2026-08-26-editor-groups-per-pane-tab-bars).
            // A `w0L` on every row of a single-group listing would be a column
            // of constants, and every existing script's parse would shift for
            // nothing. Absent entirely from an older app's reply, which reads
            // here as one window with one group.
            let windows: std::collections::BTreeSet<i64> = tabs
                .iter()
                .filter_map(|tab| tab["window"].as_i64())
                .collect();
            let split = tabs
                .iter()
                .any(|tab| tab["group"].as_i64().is_some_and(|group| group > 0));
            let show_windows = windows.len() > 1 || split;
            for tab in &tabs {
                let tasks = match (tab["openTasks"].as_i64(), tab["totalTasks"].as_i64()) {
                    (Some(open), Some(total)) if total > 0 => format!("{open}/{total}"),
                    _ => String::new(),
                };
                // `w0L` rather than a bare index: the number means nothing on
                // its own, and the group is what says *which half* of a split
                // window a document is in. Unlike the pane it replaces, every
                // tab has one — a group is a set of tabs, not a slot on screen
                // — so a tab that is merely open still says where it lives.
                let window = match (show_windows, tab["window"].as_i64(), tab["group"].as_i64()) {
                    (false, _, _) => String::new(),
                    (true, Some(w), Some(0)) => format!("w{w}L "),
                    (true, Some(w), Some(_)) => format!("w{w}R "),
                    (true, Some(w), None) => format!("w{w}  "),
                    (true, None, _) => "     ".to_string(),
                };
                emitln!(
                    out,
                    "{}{}{} {}  {:<24} {:>7}  {}  {}",
                    window,
                    if tab["selected"].as_bool() == Some(true) {
                        "*"
                    } else {
                        " "
                    },
                    // The preview tab is the one the next click in the sidebar
                    // replaces, so `mark tab list` says which it is rather than
                    // leaving "my tab vanished" to be worked out by experiment.
                    if tab["preview"].as_bool() == Some(true) {
                        "~"
                    } else {
                        " "
                    },
                    tab["index"].as_i64().unwrap_or(-1),
                    // Truncated, because a tab's title is the document's first
                    // heading and an ADR's is a whole sentence — one long title
                    // otherwise shifts every column on every other row.
                    ellipsize(tab["title"].as_str().unwrap_or_default(), 24),
                    tasks,
                    // ADR-4's residency, visible rather than inferred.
                    if tab["resident"].as_bool() == Some(true) {
                        "resident  "
                    } else {
                        "dehydrated"
                    },
                    tab["path"].as_str().unwrap_or_default()
                )?;
            }
            out.finish()
        }

        TabAction::Select { target, json } => {
            let result = call(TabAction::selector("tab-select", target)?)?;
            if *json {
                return print_json(&result);
            }
            let mut out = Output::new();
            emitln!(
                out,
                "selected tab {}: {}",
                result["tab"]["index"].as_i64().unwrap_or(-1),
                result["tab"]["path"].as_str().unwrap_or_default()
            )?;
            out.finish()
        }

        TabAction::Close { target, all, json } => {
            let request = match (all, target) {
                (true, _) => Request::new("tab-close-all"),
                (false, Some(target)) => TabAction::selector("tab-close", target)?,
                (false, None) => Request::new("tab-close"),
            };
            let result = call(request)?;
            if *json {
                return print_json(&result);
            }
            let mut out = Output::new();
            let left = result["tabs"].as_i64().unwrap_or(0);
            if *all {
                // The count, not the paths: `--all` on a window of twenty
                // documents would otherwise print twenty lines nobody asked
                // for, and `--json` is there for the caller that wants them.
                let closed = result["closed"].as_array().map_or(0, |tabs| tabs.len());
                emitln!(
                    out,
                    "closed {} tab{}, {} left",
                    closed,
                    if closed == 1 { "" } else { "s" },
                    left
                )?;
            } else {
                emitln!(
                    out,
                    "closed {}, {} left",
                    result["closed"]["path"].as_str().unwrap_or_default(),
                    left
                )?;
            }
            out.finish()
        }
    }
}

/// A theme name from the command line, or the default.
///
/// Resolving here rather than inside the renderer is deliberate: a bad name is
/// a **named error and a non-zero exit**, which is the whole difference between
/// "your theme has no base0D" and a page of invisible text.
fn resolve_theme(name: Option<&str>) -> Result<std::sync::Arc<theme::ThemePair>, CliError> {
    match name {
        Some(name) => Ok(theme::resolve(name)?),
        None => Ok(theme::default_pair()),
    }
}

/// `mark theme` — four operations that share a noun.
///
/// `--list`, `--show`, and `--import` are answered by the core in this process:
/// they are questions about files on disk, and an agent asking them usually has
/// no app running. Applying a theme goes over the socket, because the thing
/// that changes is the app's state (ADR-3), and so does bare `mark theme`,
/// which asks what is currently applied.
fn cmd_theme(
    name: Option<&str>,
    system: bool,
    list: bool,
    show: Option<&str>,
    import: Option<&Path>,
    json: bool,
) -> Result<(), CliError> {
    if let Some(path) = import {
        return cmd_theme_import(path, json);
    }
    if let Some(name) = show {
        return cmd_theme_show(name, json);
    }
    if list {
        return cmd_theme_list(json);
    }

    let mut request = Request::new("theme");
    if let Some(name) = name {
        // Resolve before asking the app, so `mark theme nosuch` fails here
        // with the near-miss suggestion rather than as a round trip.
        resolve_theme(Some(name))?;
        request = request.arg("name", name);
    }
    // Absent is "the half you named", which is what the app does with a name
    // and no appearance. Saying nothing here is therefore not the same as
    // saying "system", and must not be sent as one.
    if system {
        request = request.arg("appearance", "system");
    }
    let result = call(request)?;
    if json {
        return print_json(&result);
    }
    let mut out = Output::new();
    let theme = &result["theme"];
    emitln!(
        out,
        "{} ({}{})",
        theme["name"].as_str().unwrap_or("?"),
        theme["kind"].as_str().unwrap_or("?"),
        if theme["paired"].as_bool() == Some(true) {
            ", paired"
        } else {
            ", both appearances"
        }
    )?;
    // Which half is on screen, and why that one — the question `mark theme`
    // could not answer before, and the one behind "I chose the light theme and
    // the window is dark".
    let showing = theme["showing"].as_str().unwrap_or("?");
    match theme["appearance"].as_str() {
        Some("system") => emitln!(out, "showing {showing}, following the system appearance")?,
        Some(pinned) => emitln!(out, "showing {showing}, pinned to {pinned}")?,
        None => {}
    }
    if let Some(tabs) = result["tabs"].as_i64() {
        emitln!(out, "applied to {tabs} tab(s)")?;
    }
    out.finish()
}

fn cmd_theme_list(json: bool) -> Result<(), CliError> {
    let (themes, problems) = theme::list();
    if json {
        return print_json(&serde_json::json!({
            "themes": themes,
            "default": theme::DEFAULT_THEME,
            "dir": theme::user_dir().map(|dir| dir.display().to_string()),
            "problems": problems,
        }));
    }
    let mut out = Output::new();
    let width = themes.iter().map(|t| t.name.len()).max().unwrap_or(0);
    for summary in &themes {
        emitln!(
            out,
            "{:width$}  {:<5}  {}{}",
            summary.name,
            summary.kind.as_str(),
            summary.title,
            match &summary.pair {
                Some(pair) => format!("  (pairs with {pair})"),
                None => "  (both appearances)".to_owned(),
            }
        )?;
    }
    if let Some(dir) = theme::user_dir() {
        emitln!(out, "\nyour themes: {}", dir.display())?;
    }
    // A user file that will not parse is *reported*. Dropping it silently is
    // the failure this whole feature is trying not to have.
    for problem in &problems {
        emitln!(out, "warning: {problem}")?;
    }
    out.finish()
}

fn cmd_theme_show(name: &str, json: bool) -> Result<(), CliError> {
    let pair = theme::resolve(name)?;
    if json {
        return print_json(&serde_json::json!({
            "name": pair.name(),
            "kind": pair.primary().kind(),
            "paired": !pair.is_single(),
            "light": pair.light().name(),
            "dark": pair.dark().name(),
            "palette": palette_json(pair.primary()),
            "document": document_json(pair.primary()),
            "code": pair
                .primary()
                .code()
                .iter()
                .map(|(scope, slot)| serde_json::json!([scope, slot.name()]))
                .collect::<Vec<_>>(),
            "css": pair.css(),
        }));
    }

    let mut out = Output::new();
    let theme = pair.primary();
    emitln!(out, "{} — {}", theme.name(), theme.title())?;
    if let Some(author) = theme.author() {
        emitln!(out, "author      {author}")?;
    }
    emitln!(out, "kind        {}", theme.kind().as_str())?;
    emitln!(
        out,
        "light/dark  {} / {}{}",
        pair.light().name(),
        pair.dark().name(),
        if pair.is_single() {
            "  (one theme for both appearances)"
        } else {
            ""
        }
    )?;
    emitln!(out, "source      {}", source_label(theme.source()))?;

    emitln!(out, "\npalette")?;
    for (index, color) in theme.palette().iter().enumerate() {
        let (Some(slot), Some(color)) = (
            theme::Slot::parse(&format!("base{index:02X}")),
            color.as_ref(),
        ) else {
            continue;
        };
        emitln!(out, "  {}  {}", slot.name(), color.hex())?;
    }

    emitln!(out, "\ndocument")?;
    for (key, slot) in theme.document() {
        emitln!(
            out,
            "  {key:<11} {}  {}",
            slot.name(),
            theme.color(*slot).map(|c| c.hex()).unwrap_or_default()
        )?;
    }

    emitln!(out, "\ncode")?;
    for (scope, slot) in theme.code() {
        emitln!(out, "  {scope:<32} {}", slot.name())?;
    }

    emitln!(out, "\ncss")?;
    emit!(out, "{}", pair.css())?;
    out.finish()
}

fn cmd_theme_import(path: &Path, json: bool) -> Result<(), CliError> {
    let (toml, name) = theme::import(path)?;
    let Some(dir) = theme::user_dir() else {
        return Err(CliError::Read {
            path: path.to_path_buf(),
            source: io::Error::other("no home directory, so there is nowhere to put a user theme"),
        });
    };
    fs::create_dir_all(&dir).map_err(|source| CliError::Read {
        path: dir.clone(),
        source,
    })?;
    let target = dir.join(format!("{name}.toml"));
    fs::write(&target, &toml).map_err(|source| CliError::Read {
        path: target.clone(),
        source,
    })?;
    // Written, then read back through the same path a render uses: an import
    // that produces a file the loader rejects must fail *here*, not later on a
    // page of invisible text.
    theme::clear_cache();
    theme::resolve(&name)?;

    if json {
        return print_json(&serde_json::json!({
            "name": name,
            "path": target.display().to_string(),
        }));
    }
    let mut out = Output::new();
    emitln!(out, "{} -> {}", name, target.display())?;
    emitln!(out, "apply it with: mark theme {name}")?;
    out.finish()
}

fn palette_json(theme: &theme::Theme) -> serde_json::Value {
    let mut map = serde_json::Map::new();
    for (index, color) in theme.palette().iter().enumerate() {
        if let (Some(slot), Some(color)) = (
            theme::Slot::parse(&format!("base{index:02X}")),
            color.as_ref(),
        ) {
            map.insert(slot.name(), serde_json::Value::String(color.hex()));
        }
    }
    serde_json::Value::Object(map)
}

fn document_json(theme: &theme::Theme) -> serde_json::Value {
    let mut map = serde_json::Map::new();
    for (key, slot) in theme.document() {
        map.insert(
            key.clone(),
            serde_json::json!({
                "slot": slot.name(),
                "color": theme.color(*slot).map(|color| color.hex()),
            }),
        );
    }
    serde_json::Value::Object(map)
}

fn source_label(source: &theme::Source) -> String {
    match source {
        theme::Source::Builtin => "built in".to_owned(),
        theme::Source::User { path } => path.display().to_string(),
    }
}

fn cmd_goto(anchor: &str, json: bool) -> Result<(), CliError> {
    let result = call(Request::new("goto").arg("anchor", anchor))?;
    if json {
        return print_json(&result);
    }
    let mut out = Output::new();
    emitln!(
        out,
        "{} -> #{}",
        result["tab"]["path"].as_str().unwrap_or_default(),
        result["anchor"].as_str().unwrap_or(anchor)
    )?;
    out.finish()
}

fn cmd_reload(json: bool) -> Result<(), CliError> {
    let result = call(Request::new("reload"))?;
    if json {
        return print_json(&result);
    }
    let mut out = Output::new();
    emitln!(
        out,
        "reloaded {} ({} blocks)",
        result["tab"]["path"].as_str().unwrap_or_default(),
        result["blocks"].as_i64().unwrap_or(0)
    )?;
    out.finish()
}

fn cmd_render(
    path: &Path,
    format: &Format,
    prefix: Option<usize>,
    theme: Option<&str>,
) -> Result<(), CliError> {
    let source = read(path)?;
    let theme = resolve_theme(theme)?;

    let started = Instant::now();
    let doc = Document::parse(&source);
    trace(|| format!("parse {} blocks", doc.blocks().len()), started);

    let started = Instant::now();
    let text = if format.html {
        let options = RenderOptions {
            prefix_blocks: prefix,
            standalone: true,
            title: doc.title(),
            theme,
        };
        render(&doc, &options).html
    } else {
        // A terminal gets colour; a pipe gets plain text, unless told otherwise.
        let color = format.ansi || (!format.plain && io::stdout().is_terminal());
        // `--prefix` is ADR-2's first-paint tunable and applies to every format:
        // silently rendering the whole document for `--plain` would make the
        // flag a lie in the two modes an agent actually reads.
        ansi::render(&doc, color, terminal_width(), prefix, &theme)
    };
    trace(|| format!("render {} bytes", text.len()), started);

    let mut out = Output::new();
    emit!(out, "{text}")?;
    out.finish()
}

/// Columns available for terminal output.
///
/// `COLUMNS` wins so the width is scriptable and testable — `terminal_size`
/// reports nothing at all when stdout is a pipe, which is exactly the case a
/// test runs in. Failing that, ask the terminal; failing that, assume 80.
fn terminal_width() -> usize {
    if let Some(columns) = std::env::var_os("COLUMNS")
        .and_then(|value| value.to_string_lossy().trim().parse::<usize>().ok())
        .filter(|columns| *columns > 0)
    {
        return columns;
    }
    terminal_size::terminal_size()
        .map(|(terminal_size::Width(columns), _)| usize::from(columns))
        .filter(|columns| *columns > 0)
        .unwrap_or(ansi::DEFAULT_WIDTH)
}

#[derive(Serialize)]
struct TocEntry<'a> {
    level: u8,
    text: &'a str,
    anchor: &'a str,
    start: usize,
    end: usize,
    line: usize,
    block: String,
}

fn cmd_toc(path: &Path, json: bool) -> Result<(), CliError> {
    let source = read(path)?;
    let doc = Document::parse(&source);
    let headings = doc.headings();

    if json {
        let entries: Vec<TocEntry<'_>> = headings
            .iter()
            .map(|h| TocEntry {
                level: h.level,
                text: &h.text,
                anchor: &h.anchor,
                start: h.start,
                end: h.end,
                line: h.line,
                block: h.block.to_string(),
            })
            .collect();
        return print_json(&entries);
    }

    let mut out = Output::new();
    for heading in &headings {
        let indent = "  ".repeat(usize::from(heading.level).saturating_sub(1));
        emitln!(
            out,
            "{indent}{} (#{})  :{}  @{}",
            heading.text,
            heading.anchor,
            heading.line,
            heading.start
        )?;
    }
    out.finish()
}

// ---------------------------------------------------------------------------
// Dates: the one place in the product where a clock is read
// ---------------------------------------------------------------------------
//
// `2026-08-27-inline-task-metadata` puts date comparison in the query path and
// nowhere else: no renderer may read a clock, so `mark render --html` stays a
// pure function of its source. "Today" therefore arrives here as an argument —
// defaulted from the system clock, overridable with `--today` so the behaviour
// is testable without freezing one.
//
// Rolled by hand rather than pulled in: the whole requirement is ISO dates,
// day arithmetic and "what is today", and the core deliberately carries no
// clock dependency (its merman features disable `system-clock` for the same
// reason).

/// Days since 1970-01-01, proleptic Gregorian. Hinnant's `days_from_civil`.
fn days_from_civil(year: i32, month: u32, day: u32) -> i64 {
    let year = i64::from(year) - i64::from(month <= 2);
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let year_of_era = year - era * 400;
    let month = i64::from(month);
    let day_of_year = (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + i64::from(day) - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

/// The inverse, as `YYYY-MM-DD`.
fn civil_from_days(days: i64) -> String {
    let days = days + 719_468;
    let era = if days >= 0 { days } else { days - 146_096 } / 146_097;
    let day_of_era = days - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_prime = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_prime + 2) / 5 + 1;
    let month = month_prime + if month_prime < 10 { 3 } else { -9 };
    let year = year + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}")
}

/// Today, in the local timezone, as `YYYY-MM-DD`.
///
/// Local rather than UTC because "is this overdue?" is a question about the
/// user's day, and a note due today reading as overdue for the first eight
/// hours of it would be wrong in the direction that matters.
fn today_local() -> String {
    let seconds = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| since.as_secs() as i64);
    let mut parts: libc::tm = unsafe { std::mem::zeroed() };
    // SAFETY: `localtime_r` writes into `parts` and reads `seconds`; both are
    // live for the call, and this is the reentrant form.
    unsafe { libc::localtime_r(&seconds, &mut parts) };
    format!(
        "{:04}-{:02}-{:02}",
        parts.tm_year + 1900,
        parts.tm_mon + 1,
        parts.tm_mday
    )
}

/// A `--due-before` / `--due-after` argument: a date, `today`, or `±Nd`.
fn resolve_when(argument: &str, today: &str) -> Result<String, CliError> {
    if argument == "today" {
        return Ok(today.to_owned());
    }
    if tasks::parse_iso_date(argument).is_some() {
        return Ok(argument.to_owned());
    }
    if let Some(rest) = argument.strip_suffix('d')
        && let Ok(offset) = rest.parse::<i64>()
        && let Some((year, month, day)) = tasks::parse_iso_date(today)
    {
        return Ok(civil_from_days(days_from_civil(year, month, day) + offset));
    }
    Err(CliError::Usage(format!(
        "cannot read {argument:?} as a date: expected YYYY-MM-DD, `today`, or an \
         offset like +7d"
    )))
}

/// How a task list should be ordered.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Sort {
    Index,
    Due,
    Priority,
    State,
}

impl Sort {
    fn parse(name: &str) -> Result<Sort, CliError> {
        match name {
            "index" => Ok(Sort::Index),
            "due" => Ok(Sort::Due),
            "priority" => Ok(Sort::Priority),
            "state" => Ok(Sort::State),
            other => Err(CliError::Usage(format!(
                "unknown sort key {other:?}; expected due, priority, state, or index"
            ))),
        }
    }
}

/// Everything `mark tasks` was asked to filter and order by, resolved once.
///
/// Resolved here rather than per file so that `--today` is read once, `+7d` has
/// one answer for the whole run, and a bad argument fails before any file is
/// opened.
struct TaskQuery {
    outstanding_only: bool,
    states: Vec<tasks::State>,
    tags: Vec<String>,
    priority: Option<u8>,
    due_before: Option<String>,
    due_after: Option<String>,
    overdue: bool,
    no_due: bool,
    sort: Sort,
    today: String,
}

impl TaskQuery {
    #[allow(clippy::too_many_arguments)]
    fn new(
        outstanding_only: bool,
        states: &[String],
        tags: &[String],
        priority: Option<u8>,
        due_before: Option<&str>,
        due_after: Option<&str>,
        overdue: bool,
        no_due: bool,
        sort: Option<&str>,
        today: Option<&str>,
    ) -> Result<TaskQuery, CliError> {
        let today = match today {
            Some(given) => {
                if tasks::parse_iso_date(given).is_none() {
                    return Err(CliError::Usage(format!(
                        "cannot read {given:?} as a date: --today takes YYYY-MM-DD"
                    )));
                }
                given.to_owned()
            }
            None => today_local(),
        };
        Ok(TaskQuery {
            outstanding_only,
            states: states
                .iter()
                .map(|name| {
                    tasks::State::from_name(name)
                        .ok_or_else(|| CliError::Usage(unknown_state(name)))
                })
                .collect::<Result<_, _>>()?,
            // `@work` and `work` name the same tag: `@` needs no shell quoting,
            // which is half of why the sigil was chosen, but nobody should have
            // to remember which side of the flag it belongs on.
            tags: tags
                .iter()
                .map(|tag| tag.trim_start_matches('@').to_owned())
                .collect(),
            priority,
            due_before: due_before
                .map(|when| resolve_when(when, &today))
                .transpose()?,
            due_after: due_after
                .map(|when| resolve_when(when, &today))
                .transpose()?,
            overdue,
            no_due,
            sort: sort.map_or(Ok(Sort::Index), Sort::parse)?,
            today,
        })
    }

    /// Whether one task survives every filter. ISO dates compare
    /// lexicographically, which is the whole reason the format is fixed.
    fn matches(&self, task: &tasks::Task) -> bool {
        if self.outstanding_only && !task.state.is_outstanding() {
            return false;
        }
        if !self.states.is_empty() && !self.states.contains(&task.state) {
            return false;
        }
        if !self.tags.is_empty() && !task.tags.iter().any(|tag| self.tags.contains(&tag.name)) {
            return false;
        }
        if self.priority.is_some_and(|least| task.priority < least) {
            return false;
        }
        if self.no_due && task.due.is_some() {
            return false;
        }
        if self.overdue
            && task
                .due
                .as_deref()
                .is_none_or(|due| due >= self.today.as_str())
        {
            return false;
        }
        if let Some(before) = &self.due_before
            && task.due.as_deref().is_none_or(|due| due >= before.as_str())
        {
            return false;
        }
        if let Some(after) = &self.due_after
            && task.due.as_deref().is_none_or(|due| due <= after.as_str())
        {
            return false;
        }
        true
    }

    /// Order the collected rows. Every key is a stable sort over document
    /// order, so ties keep the order `mark tasks` would have printed anyway.
    fn order(&self, rows: &mut [TaskRow]) {
        match self.sort {
            Sort::Index => {}
            // Soonest first, and the undated last rather than first: an agenda
            // is a list of deadlines, and "no deadline" is not the nearest one.
            Sort::Due => rows.sort_by(|a, b| match (&a.due, &b.due) {
                (Some(a), Some(b)) => a.cmp(b),
                (Some(_), None) => std::cmp::Ordering::Less,
                (None, Some(_)) => std::cmp::Ordering::Greater,
                (None, None) => std::cmp::Ordering::Equal,
            }),
            // Highest first: `!!!` is the thing you wanted to see.
            Sort::Priority => rows.sort_by_key(|row| std::cmp::Reverse(row.priority)),
            Sort::State => rows.sort_by_key(|row| row.state),
        }
    }
}

/// One row of `mark tasks --json`.
///
/// `checked` is retained and means "the state is terminal" — see
/// `mark_tasks_json` in the header. `text` is unchanged; `label` is the
/// stripped one.
#[derive(Serialize)]
struct TaskRow {
    path: PathBuf,
    index: usize,
    state: tasks::State,
    checked: bool,
    start: usize,
    end: usize,
    line: usize,
    text: String,
    label: String,
    tags: Vec<tasks::Tag>,
    #[serde(skip_serializing_if = "Option::is_none")]
    due: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    start_date: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    done: Option<String>,
    priority: u8,
}

impl TaskRow {
    fn new(path: PathBuf, task: tasks::Task) -> TaskRow {
        TaskRow {
            path,
            index: task.index,
            state: task.state,
            checked: task.checked,
            start: task.start,
            end: task.end,
            line: task.line,
            text: task.text,
            label: task.label,
            tags: task.tags,
            due: task.due,
            start_date: task.start_date,
            done: task.done,
            priority: task.priority,
        }
    }

    /// The metadata, back in the spelling it was written in, for the human
    /// form. Empty for a document that uses none — which is what keeps that
    /// output byte-identical to what it printed before.
    fn chips(&self) -> String {
        let mut out = String::new();
        for (key, value) in [
            ("due", &self.due),
            ("start", &self.start_date),
            ("done", &self.done),
        ] {
            if let Some(value) = value {
                out.push_str(&format!(" @{key}({value})"));
            }
        }
        for tag in &self.tags {
            match &tag.value {
                Some(value) => out.push_str(&format!(" @{}({value})", tag.name)),
                None => out.push_str(&format!(" @{}", tag.name)),
            }
        }
        if self.priority > 0 {
            out.push(' ');
            out.push_str(&"!".repeat(usize::from(self.priority)));
        }
        out
    }
}

fn cmd_tasks(
    path: Option<&Path>,
    query: &TaskQuery,
    json: bool,
    depth: usize,
) -> Result<(), CliError> {
    let root = path.unwrap_or_else(|| Path::new("."));
    let mut rows = Vec::new();

    let started = Instant::now();
    let targets = markdown_targets(root, depth)?;
    trace(
        || format!("walk {} -> {} files", root.display(), targets.len()),
        started,
    );

    let started = Instant::now();
    let mut seen = 0usize;
    for file in &targets {
        let source = read_walked(root, file)?;
        for task in tasks::enumerate_source(&source) {
            seen += 1;
            if query.matches(&task) {
                rows.push(TaskRow::new(file.clone(), task));
            }
        }
    }
    // Plan §4: the metadata parse rides along inside the enumeration — one pass
    // over the events builds the label and reads the tokens — so it is reported
    // here rather than timed separately, and what it found is named. "Why is
    // this list empty?" is then answerable from telemetry alone.
    trace(
        || {
            let tagged = rows.iter().filter(|row| !row.tags.is_empty()).count();
            let dated = rows.iter().filter(|row| row.due.is_some()).count();
            format!(
                "enumerate {seen} tasks -> {} matched, metadata {tagged} tagged, {dated} due",
                rows.len()
            )
        },
        started,
    );

    let started = Instant::now();
    query.order(&mut rows);
    trace(
        || format!("sort {:?}, today {}", query.sort, query.today),
        started,
    );

    if json {
        return print_json(&rows);
    }

    let mut out = Output::new();
    for row in &rows {
        emitln!(
            out,
            "{}:{} [{}] {}{}  ({})",
            row.path.display(),
            row.index,
            char::from(row.state.byte()),
            row.label,
            row.chips(),
            row.line
        )?;
    }
    out.finish()
}

/// `mark check --json`. Deliberately not the whole document: the caller
/// already has the path, and echoing a megabyte back to say one byte changed
/// would make the flag unusable in the loop it exists for.
#[derive(Serialize)]
struct CheckedTask<'a> {
    path: &'a Path,
    index: usize,
    state: tasks::State,
    /// Retained, and "the state is terminal" — true for done *and* cancelled.
    checked: bool,
    text: &'a str,
    /// The single byte the write changed — ADR-1's *"a byte-range in-place edit
    /// of the character between the brackets"*, reported rather than described.
    offset: usize,
    /// The date `--stamp` appended, when it did. Absent otherwise, including
    /// when the item was already stamped.
    #[serde(skip_serializing_if = "Option::is_none")]
    stamped: Option<String>,
}

fn cmd_check(
    path: &Path,
    index: usize,
    action: Action,
    stamp: bool,
    today: Option<&str>,
    json: bool,
) -> Result<(), CliError> {
    let started = Instant::now();
    let (toggled, stamped) = if stamp {
        stamped_toggle(path, index, action, today)?
    } else {
        // The plain path is untouched: one read, one byte, one atomic write.
        (tasks::toggle_file(path, index, action)?, None)
    };
    trace(
        || {
            format!(
                "toggle {} item {index} -> {}{}",
                path.display(),
                toggled.state.as_str(),
                stamped
                    .as_ref()
                    .map_or_else(String::new, |date| format!(" stamped {date}"))
            )
        },
        started,
    );

    if json {
        return print_json(&CheckedTask {
            path,
            index: toggled.index,
            state: toggled.state,
            checked: toggled.checked,
            text: &toggled.text,
            offset: toggled.offset,
            stamped,
        });
    }

    let mut out = Output::new();
    emitln!(
        out,
        "[{}] {}:{}  {}",
        char::from(toggled.state.byte()),
        path.display(),
        toggled.index,
        toggled.text
    )?;
    out.finish()
}

/// `mark check --stamp`: the toggle, plus `@done(YYYY-MM-DD)` at the end of the
/// item, in **one** atomic write.
///
/// One write rather than two because two would take the `flock` twice and leave
/// a window where the file says done and does not say when.
/// `2026-08-27-inline-task-metadata` requires the insertion offset to come from
/// the label's own event span, which is what `Task::label_end` carries, and the
/// write to go through `write_atomically` — so this inherits
/// `2026-08-25-flock-write-locking` like every other writer.
fn stamped_toggle(
    path: &Path,
    index: usize,
    action: Action,
    today: Option<&str>,
) -> Result<(tasks::Toggled, Option<String>), CliError> {
    let date = match today {
        Some(given) => {
            if tasks::parse_iso_date(given).is_none() {
                return Err(CliError::Usage(format!(
                    "cannot read {given:?} as a date: --today takes YYYY-MM-DD"
                )));
            }
            given.to_owned()
        }
        None => today_local(),
    };

    let source = read(path)?;
    let mut toggled = tasks::toggle(&source, index, action)?;

    // Only a task that has *become* done gets a date, and only once: stamping
    // an already-stamped item twice is the failure mode this checks for.
    let task = tasks::enumerate_source(&toggled.source)
        .into_iter()
        .nth(index);
    let stamped = match task {
        Some(task) if task.state == tasks::State::Done && task.done.is_none() => {
            let mut out = String::with_capacity(toggled.source.len() + 20);
            out.push_str(&toggled.source[..task.label_end]);
            out.push_str(&format!(" @done({date})"));
            out.push_str(&toggled.source[task.label_end..]);
            toggled.source = out;
            toggled.text = format!("{} @done({date})", task.text);
            Some(date)
        }
        _ => None,
    };

    tasks::write_atomically(path, &toggled.source).map_err(tasks::TaskError::from)?;
    Ok((toggled, stamped))
}

/// `mark normalize`: the GFM escape hatch.
///
/// `2026-08-27-five-task-states` defines the degrade — `[-] text` becomes
/// `[x] ~~text~~`, and `[/]` / `[?]` become `[ ]` carrying an `@doing` /
/// `@blocked` tag, which is what makes it **lossless**: the state is still in
/// the file, in a spelling GitHub renders as prose.
///
/// Writes to **stdout by default**. `--in-place` is required to touch the file,
/// because a verb whose name does not obviously write should not rewrite a
/// user's document as its default behaviour.
fn cmd_normalize(path: &Path, gfm: bool, in_place: bool, check: bool) -> Result<(), CliError> {
    // `--gfm` is the only mode, and naming it is optional; the flag exists so
    // that a future `--extended` does not change what a bare invocation does.
    let _ = gfm;
    if in_place && check {
        return Err(CliError::Usage(
            "--in-place and --check are opposites; pick one".to_owned(),
        ));
    }

    let source = read(path)?;
    let started = Instant::now();
    let normalized = normalize_to_gfm(&source);
    let changed = normalized.edits;
    trace(
        || format!("normalize {} -> {changed} markers", path.display()),
        started,
    );

    if check {
        let mut out = Output::new();
        match changed {
            0 => emitln!(out, "{}: already GFM", path.display())?,
            _ => emitln!(
                out,
                "{}: {changed} extended marker(s) would be rewritten",
                path.display()
            )?,
        }
        return out.finish();
    }

    if in_place {
        if changed > 0 {
            tasks::write_atomically(path, &normalized.source).map_err(tasks::TaskError::from)?;
        }
        let mut out = Output::new();
        emitln!(out, "{}: {changed} marker(s) rewritten", path.display())?;
        return out.finish();
    }

    let mut out = Output::new();
    emit!(out, "{}", normalized.source)?;
    out.finish()
}

struct Normalized {
    source: String,
    edits: usize,
}

/// Every extended marker rewritten as GFM, applied back to front so earlier
/// offsets stay valid.
fn normalize_to_gfm(source: &str) -> Normalized {
    let mut edits: Vec<(std::ops::Range<usize>, String)> = Vec::new();

    for task in tasks::enumerate_source(source) {
        let tag = match task.state {
            tasks::State::InProgress => "doing",
            tasks::State::Blocked => "blocked",
            tasks::State::Cancelled => {
                edits.push((task.start..task.end, "[x]".to_owned()));
                // Struck *and* ticked, which is how a dropped item should read
                // on GitHub — but only if it is not struck already. Two checks,
                // because there are two ways it can be: `- [-] ~~gone~~` puts
                // the item's first *visible* byte inside the strikethrough, so
                // the raw source either side is what says so, and
                // `- [-] a ~~b~~` is partly struck, where wrapping again would
                // produce `~~a ~~b~~~~` and mangle the markup. Both make
                // normalizing twice a no-op, which `--in-place` depends on.
                let struck_already = source[..task.text_start].ends_with("~~");
                let struck_within = source[task.text_start..task.label_end].contains("~~");
                if task.text_start < task.label_end && !struck_already && !struck_within {
                    edits.push((task.text_start..task.text_start, "~~".to_owned()));
                    edits.push((task.label_end..task.label_end, "~~".to_owned()));
                }
                continue;
            }
            _ => continue,
        };
        edits.push((task.start..task.end, "[ ]".to_owned()));
        if !task.tags.iter().any(|carried| carried.name == tag) {
            edits.push((task.label_end..task.label_end, format!(" @{tag}")));
        }
    }

    let markers = edits.iter().filter(|(range, _)| !range.is_empty()).count();
    edits.sort_by(|a, b| b.0.start.cmp(&a.0.start).then(b.0.end.cmp(&a.0.end)));

    let mut out = source.to_owned();
    for (range, replacement) in edits {
        out.replace_range(range, &replacement);
    }
    Normalized {
        source: out,
        edits: markers,
    }
}

/// One row of `mark ls --json`.
///
/// `open` and `total` are kept, and keep meaning exactly what they meant: open
/// is the `[ ]` count. `outstanding` and `active` are the badge's numerator and
/// denominator — outstanding over total-minus-cancelled — and the per-state
/// counts are there so a script does not have to infer them.
#[derive(Serialize)]
struct LsRow {
    path: PathBuf,
    name: String,
    is_dir: bool,
    depth: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    open: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    total: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    outstanding: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    active: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    in_progress: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    done: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    cancelled: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    blocked: Option<usize>,
    /// `--git` only. Absent for a clean file, and for a directory.
    #[serde(skip_serializing_if = "Option::is_none")]
    git: Option<git::Status>,
    #[serde(skip_serializing_if = "Option::is_none")]
    added: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    removed: Option<u32>,
}

/// Every changed path in the repository containing `root`, keyed by the path
/// spelling `tree::list_dir` produced — so the join is a hash lookup per row.
///
/// Empty when `root` is not in a repository, or when git could not answer.
/// Both are ordinary: the columns simply do not appear.
fn git_changes_for(root: &Path) -> HashMap<PathBuf, git::Change> {
    let Some(repo) = git::discover(root) else {
        return HashMap::new();
    };
    let query = git::Query {
        // One shot, so an untracked file's lines are counted here rather than
        // deferred to a screen-bounded queue the way the sidebar defers them.
        count_untracked_lines: true,
        ..git::Query::default()
    };
    let Ok(changes) = git::changes(&repo, &query) else {
        return HashMap::new();
    };

    // `Change::path` is repository-relative; `Entry::path` is however the
    // caller spelled it. Rebuild the caller's spelling rather than making every
    // row canonicalize itself, which would be a syscall per row on a tree
    // research 2.8 measured at 608k files.
    let base = std::path::absolute(root).unwrap_or_else(|_| root.to_path_buf());
    let prefix = fs::canonicalize(&base)
        .ok()
        .and_then(|real| {
            fs::canonicalize(&repo.root)
                .ok()
                .and_then(|repo_root| real.strip_prefix(&repo_root).ok().map(Path::to_path_buf))
        })
        .unwrap_or_default();

    changes
        .into_iter()
        .filter_map(|change| {
            let below = change.path.strip_prefix(&prefix).ok()?.to_path_buf();
            Some((root.join(below), change))
        })
        .collect()
}

/// One changed file, as `mark diff` reports it.
#[derive(Serialize)]
struct DiffRow {
    path: PathBuf,
    status: git::Status,
    #[serde(skip_serializing_if = "Option::is_none")]
    from: Option<PathBuf>,
    /// `null` for a file with no countable lines — a binary, per
    /// `git diff --numstat`'s own `-` `-`. Never `0`, which would claim the
    /// file did not change.
    added: Option<u32>,
    removed: Option<u32>,
}

/// The whole answer, so `--json` is one object rather than a bare array and can
/// grow a field without breaking a consumer.
#[derive(Serialize)]
struct DiffReport {
    /// `null` when the path is not in a repository.
    repo: Option<PathBuf>,
    #[serde(skip_serializing_if = "Option::is_none")]
    head: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    branch: Option<String>,
    files: Vec<DiffRow>,
    added: u32,
    removed: u32,
    /// Present only when a single file was named: its line-level hunks.
    #[serde(skip_serializing_if = "Option::is_none")]
    hunks: Option<lines::LineDiff>,
}

/// `mark diff` — what changed against `HEAD`.
fn cmd_diff(
    path: Option<&Path>,
    format: &Format,
    json: bool,
    stat: bool,
    tracked_only: bool,
    theme: Option<&str>,
) -> Result<(), CliError> {
    let target = path.unwrap_or_else(|| Path::new("."));

    let Some(repo) = git::discover(target) else {
        // Not an error. See the `Diff` variant's own documentation for why.
        if json {
            return print_json(&DiffReport {
                repo: None,
                head: None,
                branch: None,
                files: Vec::new(),
                added: 0,
                removed: 0,
                hunks: None,
            });
        }
        eprintln!("{}: not in a git repository", target.display());
        return Ok(());
    };

    let query = git::Query {
        untracked: !tracked_only,
        // One shot, so counting an untracked file's lines here is fine — the
        // per-visible-row deferral in
        // `2026-08-28-git-badges-ride-the-sidebar-poll` exists for the sidebar's
        // 2-second tick, not for a command a person just typed.
        count_untracked_lines: true,
        ..git::Query::default()
    };
    let changes = git::changes(&repo, &query)?;

    // A single *file* narrows the report to itself and gains hunks.
    let single = (!target.is_dir())
        .then(|| relative_in(&repo, target))
        .flatten();

    let rows: Vec<DiffRow> = changes
        .iter()
        .filter(|change| single.as_ref().is_none_or(|only| change.path == *only))
        .map(|change| DiffRow {
            path: change.path.clone(),
            status: change.status,
            from: change.from.clone(),
            added: change.added,
            removed: change.removed,
        })
        .collect();

    let added = rows.iter().filter_map(|row| row.added).sum();
    let removed = rows.iter().filter_map(|row| row.removed).sum();

    // The two content-bearing formats need both versions of the file, so they
    // are only available for a single named file.
    if format.html || (!stat && single.is_some()) {
        if let Some(relative) = &single {
            return diff_one_file(&repo, target, relative, format, json, stat, theme, rows);
        }
        if format.html {
            return Err(CliError::Usage(
                "--html needs a single file: a directory has no one document to render".to_owned(),
            ));
        }
    }

    if json {
        return print_json(&DiffReport {
            repo: Some(repo.root.clone()),
            head: repo.head.clone(),
            branch: repo.branch.clone(),
            files: rows,
            added,
            removed,
            hunks: None,
        });
    }

    let color = format.ansi || (!format.plain && io::stdout().is_terminal());
    let paint = DiffPaint::new(color, theme)?;
    let mut out = Output::new();
    for row in &rows {
        emitln!(
            out,
            "{}  {}",
            paint.counts(row.added, row.removed),
            row.path.display()
        )?;
    }
    if rows.is_empty() {
        emitln!(out, "no changes against HEAD")?;
    }
    out.finish()
}

/// `mark diff <file>` — the counts, then the changed lines.
#[allow(clippy::too_many_arguments)]
fn diff_one_file(
    repo: &git::Repo,
    target: &Path,
    relative: &Path,
    format: &Format,
    json: bool,
    stat: bool,
    theme: Option<&str>,
    rows: Vec<DiffRow>,
) -> Result<(), CliError> {
    // HEAD's bytes, or empty for a file HEAD does not have — which is what
    // makes an untracked note read as "every line added" rather than as an
    // error.
    let base = git::base_bytes(repo, target, git::DEFAULT_TIMEOUT)?.unwrap_or_default();
    let working = read(target)?;
    let diff = lines::diff(&base, &working);

    if format.html {
        let theme = resolve_theme(theme)?;
        let old = Document::parse(&base);
        let new = Document::parse(&working);
        let document = diff::diff_document(&old, &new, &theme);
        let title = format!("{} — changes vs HEAD", relative.display());
        let mut out = Output::new();
        emit!(
            out,
            "{}",
            diff::standalone_diff(&title, &document.html, &theme)
        )?;
        return out.finish();
    }

    if json {
        return print_json(&DiffReport {
            repo: Some(repo.root.clone()),
            head: repo.head.clone(),
            branch: repo.branch.clone(),
            files: rows,
            added: diff.added,
            removed: diff.removed,
            hunks: Some(diff),
        });
    }

    let color = format.ansi || (!format.plain && io::stdout().is_terminal());
    let paint = DiffPaint::new(color, theme)?;
    let mut out = Output::new();
    emitln!(
        out,
        "{}  {}",
        paint.counts(Some(diff.added), Some(diff.removed)),
        relative.display()
    )?;
    if stat {
        return out.finish();
    }

    if diff.coarse {
        // Say so rather than printing a wall of lines that implies precision.
        emitln!(out, "  (too different to diff line by line)")?;
        return out.finish();
    }

    let base_lines: Vec<&str> = base.lines().collect();
    let working_lines: Vec<&str> = working.lines().collect();
    for hunk in &diff.hunks {
        emitln!(out, "{}", paint.hunk_header(hunk))?;
        for line in hunk.old.clone() {
            if let Some(text) = base_lines.get(line as usize) {
                emitln!(out, "{}", paint.removed_line(text))?;
            }
        }
        for line in hunk.new.clone() {
            if let Some(text) = working_lines.get(line as usize) {
                emitln!(out, "{}", paint.added_line(text))?;
            }
        }
    }
    if diff.hunks.is_empty() {
        emitln!(out, "  no changes against HEAD")?;
    }
    out.finish()
}

/// `target` as a repository-relative path, if it is inside `repo`.
///
/// Compared canonically, because `$TMPDIR` on macOS is a symlink into
/// `/private` and git reports the resolved spelling — so a plain
/// `strip_prefix` misses on exactly the paths the tests use.
fn relative_in(repo: &git::Repo, target: &Path) -> Option<PathBuf> {
    let absolute = std::path::absolute(target).ok()?;
    if let Ok(relative) = absolute.strip_prefix(&repo.root) {
        return Some(relative.to_path_buf());
    }
    let root = fs::canonicalize(&repo.root).ok()?;
    let real = fs::canonicalize(&absolute).ok()?;
    real.strip_prefix(&root).ok().map(Path::to_path_buf)
}

/// Colours for `mark diff`'s terminal output.
///
/// The same theme slots the rendered view uses — `success` for additions,
/// `error` for removals, `muted` for the hunk header — so the terminal and the
/// app agree about what green means. `--plain`, or a pipe, yields no escape
/// sequences at all.
struct DiffPaint {
    add: String,
    del: String,
    dim: String,
    reset: String,
}

impl DiffPaint {
    fn new(color: bool, theme: Option<&str>) -> Result<DiffPaint, CliError> {
        if !color {
            return Ok(DiffPaint {
                add: String::new(),
                del: String::new(),
                dim: String::new(),
                reset: String::new(),
            });
        }
        let pair = resolve_theme(theme)?;
        let primary = pair.primary();
        let fg = |key: &str, fallback: &str| {
            primary.chrome(key).map_or_else(
                || fallback.to_owned(),
                |rgb| format!("\x1b[38;2;{};{};{}m", rgb.r, rgb.g, rgb.b),
            )
        };
        Ok(DiffPaint {
            add: fg("success", "\x1b[32m"),
            del: fg("error", "\x1b[31m"),
            dim: fg("muted", "\x1b[2m"),
            reset: "\x1b[0m".to_owned(),
        })
    }

    /// `+12 −3`, or the status word for a file whose lines cannot be counted.
    fn counts(&self, added: Option<u32>, removed: Option<u32>) -> String {
        match (added, removed) {
            (Some(added), Some(removed)) => format!(
                "{}+{added}{} {}\u{2212}{removed}{}",
                self.add, self.reset, self.del, self.reset
            ),
            // A binary file. `+0 -0` would be a lie, so it says nothing
            // numeric at all.
            _ => format!("{}binary{}", self.dim, self.reset),
        }
    }

    fn hunk_header(&self, hunk: &lines::Hunk) -> String {
        // 1-based for display, which is the one place that conversion belongs
        // (`lines::Hunk` is zero-based like every other offset in the core).
        //
        // A zero-length range prints the line *before* it rather than the line
        // after, which is what `git diff` does and therefore what anyone
        // reading this expects: a pure insertion after old line 5 is `-5,0`.
        let start = |range: &std::ops::Range<u32>| {
            if range.is_empty() {
                range.start
            } else {
                range.start + 1
            }
        };
        format!(
            "{}  @@ -{},{} +{},{} @@{}",
            self.dim,
            start(&hunk.old),
            hunk.old.end - hunk.old.start,
            start(&hunk.new),
            hunk.new.end - hunk.new.start,
            self.reset
        )
    }

    fn removed_line(&self, text: &str) -> String {
        format!("  {}\u{2212} {text}{}", self.del, self.reset)
    }

    fn added_line(&self, text: &str) -> String {
        format!("  {}+ {text}{}", self.add, self.reset)
    }
}

fn cmd_ls(
    dir: Option<&Path>,
    json: bool,
    depth: usize,
    all: bool,
    git_columns: bool,
) -> Result<(), CliError> {
    let root = dir.unwrap_or_else(|| Path::new("."));
    let options = tree::Options {
        max_depth: depth.max(1),
        with_stats: true,
        markdown_only: !all,
        hidden: false,
    };
    let entries = tree::list_dir(root, &options)?;

    // One query for the whole repository, joined onto the entries in memory.
    // `2026-08-28-git-differences-by-running-git` measured why this is the
    // unit: above git's 5.9 ms process floor, the work over 1,709 files is
    // ~3.7 ms, so one call answering every row beats one call per row by an
    // order of magnitude.
    let changes = if git_columns {
        git_changes_for(root)
    } else {
        HashMap::new()
    };

    let rows: Vec<LsRow> = entries
        .into_iter()
        .map(|entry| {
            let change = changes.get(entry.path.as_path());
            LsRow {
                path: entry.path,
                name: entry.name,
                is_dir: entry.is_dir,
                depth: entry.depth,
                title: entry.title,
                open: entry.tasks.map(|t| t.open),
                total: entry.tasks.map(|t| t.total),
                outstanding: entry.tasks.map(|t| t.outstanding()),
                active: entry.tasks.map(|t| t.active()),
                in_progress: entry.tasks.map(|t| t.in_progress),
                done: entry.tasks.map(|t| t.done),
                cancelled: entry.tasks.map(|t| t.cancelled),
                blocked: entry.tasks.map(|t| t.blocked),
                git: change.map(|c| c.status),
                added: change.and_then(|c| c.added),
                removed: change.and_then(|c| c.removed),
            }
        })
        .collect();

    if json {
        return print_json(&rows);
    }

    let mut out = Output::new();
    for row in &rows {
        let indent = "  ".repeat(row.depth.saturating_sub(1));
        if row.is_dir {
            emitln!(out, "{indent}{}/", row.name)?;
            continue;
        }
        let title = row.title.as_deref().unwrap_or("");
        // Changes first, then the task badge — the same order the sidebar row
        // draws them in (`2026-08-28-git-badges-ride-the-sidebar-poll`), so the
        // two halves of the product read alike.
        let changed = match (row.added, row.removed) {
            (Some(added), Some(removed)) => format!("  +{added} \u{2212}{removed}"),
            _ if row.git.is_some() => "  binary".to_owned(),
            _ => String::new(),
        };
        // Outstanding over active, which for a document with no extended
        // markers *is* open over total — so no existing listing changes. A file
        // whose every task is cancelled shows no count, on the same grounds the
        // sidebar badge suppresses `0/0`.
        match (row.outstanding, row.active) {
            (Some(outstanding), Some(active)) if active > 0 => {
                emitln!(
                    out,
                    "{indent}{}{changed}  {title}  [{outstanding}/{active}]",
                    row.name
                )?;
            }
            _ => emitln!(out, "{indent}{}{changed}  {title}", row.name)?,
        }
    }
    out.finish()
}

#[derive(Serialize)]
struct Match {
    path: PathBuf,
    line: usize,
    /// Nearest preceding heading, as a `>`-joined path. Empty above the first
    /// heading.
    heading: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    anchor: Option<String>,
    text: String,
}

fn cmd_grep(
    pattern: &str,
    path: Option<&Path>,
    json: bool,
    ignore_case: bool,
    depth: usize,
) -> Result<(), CliError> {
    // Multi-line so `^` and `$` anchor to lines, which is what anyone typing a
    // pattern into something called `grep` expects.
    let regex = regex::RegexBuilder::new(pattern)
        .case_insensitive(ignore_case)
        .multi_line(true)
        .build()
        .map_err(|error| CliError::Pattern(Box::new(error)))?;

    let root = path.unwrap_or_else(|| Path::new("."));
    let mut matches = Vec::new();

    let started = Instant::now();
    let targets = markdown_targets(root, depth)?;
    trace(
        || format!("walk {} -> {} files", root.display(), targets.len()),
        started,
    );

    let started = Instant::now();
    for file in &targets {
        let source = read_walked(root, file)?;
        let doc = Document::parse(&source);
        let headings = doc.headings();
        let lines = doc.lines();

        for found in regex.find_iter(&source) {
            let context = heading_path(&headings, found.start());
            matches.push(Match {
                path: file.clone(),
                line: lines.line_of(found.start()),
                heading: context.0,
                anchor: context.1,
                text: source[line_bounds(&source, found.start())]
                    .trim_end()
                    .to_owned(),
            });
        }
    }
    trace(|| format!("search {} matches", matches.len()), started);

    if json {
        return print_json(&matches);
    }

    let mut out = Output::new();
    for found in &matches {
        if found.heading.is_empty() {
            emitln!(
                out,
                "{}:{}: {}",
                found.path.display(),
                found.line,
                found.text
            )?;
        } else {
            emitln!(
                out,
                "{}:{}: [{}] {}",
                found.path.display(),
                found.line,
                found.heading,
                found.text
            )?;
        }
    }
    out.finish()
}

/// The `>`-joined heading path a match sits under, plus the innermost anchor.
///
/// A match on a heading's own line is attributed to that heading, so
/// `## Middle` under `# Top` reports `Top > Middle` — the breadcrumb names
/// where the match is, not where it starts.
fn heading_path(headings: &[mark_core::parse::Heading], offset: usize) -> (String, Option<String>) {
    let mut stack: Vec<&mark_core::parse::Heading> = Vec::new();
    for heading in headings {
        if heading.start > offset {
            break;
        }
        while stack.last().is_some_and(|open| open.level >= heading.level) {
            stack.pop();
        }
        stack.push(heading);
    }
    let anchor = stack.last().map(|h| h.anchor.clone());
    let path = stack
        .iter()
        .map(|h| h.text.as_str())
        .collect::<Vec<_>>()
        .join(" > ");
    (path, anchor)
}

/// Byte range of the line containing `offset`.
fn line_bounds(source: &str, offset: usize) -> std::ops::Range<usize> {
    let start = source[..offset].rfind('\n').map_or(0, |i| i + 1);
    let end = source[offset..]
        .find('\n')
        .map_or(source.len(), |i| offset + i);
    start..end
}

/// A single file, or every markdown file below a directory.
fn markdown_targets(root: &Path, depth: usize) -> Result<Vec<PathBuf>, CliError> {
    let options = tree::Options {
        max_depth: depth.max(1),
        ..tree::Options::default()
    };
    Ok(tree::markdown_files(root, &options)?)
}

/// Read one file found by walking `root`.
///
/// The two cases are genuinely different and used to be conflated. When the
/// user named a file, an unreadable or non-UTF-8 file is a failure they asked
/// about: report it and exit 2 (plan §3). When we found it by walking a
/// directory, one bad file must not cost them the rest of the listing — skip
/// it, but leave a trace so the silence is explicable.
fn read_walked(root: &Path, file: &Path) -> Result<String, CliError> {
    match fs::read_to_string(file) {
        Ok(source) => Ok(source),
        Err(source) if root == file => Err(CliError::Read {
            path: file.to_path_buf(),
            source,
        }),
        Err(source) => {
            let started = Instant::now();
            trace(|| format!("skipped {}: {source}", file.display()), started);
            Ok(String::new())
        }
    }
}

#[derive(Serialize)]
struct Stats {
    path: PathBuf,
    bytes: usize,
    blocks: usize,
    code_blocks: usize,
    code_bytes: usize,
    /// ADR-5's two constructs, counted separately from code blocks so that
    /// "how much of this document is math we cannot render" is answerable
    /// without reading the page.
    math: usize,
    diagrams: usize,
    rich_failures: usize,
    headings: usize,
    tasks: tasks::Counts,
    parse_ms: f64,
    render_ms: f64,
    /// A second full render with the highlight cache warm — the file-watcher
    /// path ADR-2 is about, measured on a real document rather than a fixture.
    rerender_ms: f64,
    highlight_cold_ms: f64,
    highlight_cached_ms: f64,
    rich_cold_ms: f64,
    rich_cached_ms: f64,
    cache: mark_core::highlight::CacheStats,
    rich_cache: mark_core::highlight::CacheStats,
}

fn cmd_stats(path: &Path, json: bool) -> Result<(), CliError> {
    let source = read(path)?;

    let started = Instant::now();
    let doc = Document::parse(&source);
    let parse = started.elapsed();

    let started = Instant::now();
    let cold = render(&doc, &RenderOptions::default());
    let render_time = started.elapsed();

    // Second pass with a warm cache: ADR-2's memoization claim, checkable on
    // any real document rather than only on our fixtures.
    let started = Instant::now();
    let warm = render(&doc, &RenderOptions::default());
    let warm_time = started.elapsed();

    let stats = Stats {
        path: path.to_path_buf(),
        bytes: source.len(),
        blocks: cold.blocks_total,
        code_blocks: cold.code_blocks,
        code_bytes: cold.code_bytes,
        math: cold.math,
        diagrams: cold.diagrams,
        rich_failures: cold.rich_failures,
        headings: doc.headings().len(),
        tasks: tasks::counts(&source),
        parse_ms: ms(parse),
        render_ms: ms(render_time),
        rerender_ms: ms(warm_time),
        highlight_cold_ms: ms(cold.highlight_time),
        highlight_cached_ms: ms(warm.highlight_time),
        rich_cold_ms: ms(cold.rich_time),
        rich_cached_ms: ms(warm.rich_time),
        cache: mark_core::highlight::shared().stats(),
        rich_cache: mark_core::rich::stats(),
    };

    if json {
        return print_json(&stats);
    }

    let mut out = Output::new();
    emitln!(out, "path              {}", stats.path.display())?;
    emitln!(out, "bytes             {}", stats.bytes)?;
    emitln!(out, "blocks            {}", stats.blocks)?;
    emitln!(
        out,
        "code              {} blocks, {} bytes",
        stats.code_blocks,
        stats.code_bytes
    )?;
    emitln!(
        out,
        "rich              {} math, {} diagrams, {} failed",
        stats.math,
        stats.diagrams,
        stats.rich_failures
    )?;
    emitln!(out, "headings          {}", stats.headings)?;
    emitln!(
        out,
        "tasks             {} outstanding / {} active / {} total",
        stats.tasks.outstanding(),
        stats.tasks.active(),
        stats.tasks.total
    )?;
    emitln!(
        out,
        "task states       {} open / {} in progress / {} done / {} cancelled / {} blocked",
        stats.tasks.open,
        stats.tasks.in_progress,
        stats.tasks.done,
        stats.tasks.cancelled,
        stats.tasks.blocked
    )?;
    emitln!(out, "parse             {:.3} ms", stats.parse_ms)?;
    emitln!(out, "render            {:.3} ms", stats.render_ms)?;
    emitln!(out, "re-render         {:.3} ms", stats.rerender_ms)?;
    emitln!(out, "highlight cold    {:.3} ms", stats.highlight_cold_ms)?;
    emitln!(out, "highlight cached  {:.3} ms", stats.highlight_cached_ms)?;
    emitln!(out, "rich cold         {:.3} ms", stats.rich_cold_ms)?;
    emitln!(out, "rich cached       {:.3} ms", stats.rich_cached_ms)?;
    emitln!(
        out,
        "cache             {} hits / {} misses / {} entries / {} evictions",
        stats.cache.hits,
        stats.cache.misses,
        stats.cache.entries,
        stats.cache.evictions
    )?;
    emitln!(
        out,
        "rich cache        {} hits / {} misses / {} entries / {} evictions",
        stats.rich_cache.hits,
        stats.rich_cache.misses,
        stats.rich_cache.entries,
        stats.rich_cache.evictions
    )?;
    out.finish()
}

#[derive(Serialize)]
struct Doctor {
    core_version: String,
    cli_version: String,
    /// The commit both were built from, and its date. The pair that makes a
    /// `--HEAD` install identifiable, since the semver above only moves on a
    /// deliberate bump.
    build_commit: String,
    build_date: String,
    protocol_version: u32,
    executable: Option<PathBuf>,
    /// The enclosing `.app`, resolved from `$0` through its symlink chain
    /// (ADR-1). `None` when this binary is not inside a bundle.
    app_bundle: Option<PathBuf>,
    /// Every bundle LaunchServices has registered as `dev.mark.app`, first
    /// one first — see [`client::registered_bundles`]. More than one means
    /// `mark open` and a double-clicked `.md` may reach a build that is not
    /// ``app_bundle``, which is the failure this line exists to name.
    registered_bundles: Vec<PathBuf>,
    syntect_asset_load_ms: f64,
    /// The `git` this build would run, and its version.
    ///
    /// The first thing to ask when someone reports missing change badges,
    /// because `2026-08-28-git-differences-by-running-git` makes every git
    /// failure deliberately invisible in the UI. `None` means no usable git,
    /// which on macOS most often means the Command Line Tools are not
    /// installed — hence ``command_line_tools`` next to it, since `/usr/bin/git`
    /// exists either way and is a shim that would raise a modal dialog if
    /// invoked without them.
    git: Option<PathBuf>,
    git_version: Option<String>,
    command_line_tools: bool,
    /// The default theme, and how many there are to choose from. Named
    /// `theme`, not `syntax_theme`: since M7 a theme is chrome *and* code.
    theme: String,
    themes: usize,
    /// `$TMPDIR/mark-$UID.sock`, or the reason it is unusable.
    socket_path: Option<String>,
    socket_path_bytes: Option<usize>,
    socket_path_limit: usize,
    socket_error: Option<String>,
    app_running: bool,
    /// The **running app's** build string, when one is running.
    ///
    /// The whole point of the field: a `mark` on PATH and a `mark.app` that
    /// LaunchServices picked are two installs, and nothing else in this report
    /// would show that they had drifted apart.
    app_build: Option<String>,
    /// The bundle the running app was launched from — which is not necessarily
    /// ``app_bundle``, the one this CLI lives inside.
    app_path: Option<String>,
    theme_dir: Option<String>,
    /// Windows, tabs, and how many of those tabs hold a `WKWebView`.
    ///
    /// `2026-08-26-multiple-windows-and-split-panes` requires this, discharging
    /// a bullet its predecessor asked for and never got:
    ///
    /// > **`mark doctor` reports window count, tab count, resident count, the
    /// > budget computed from the formula, and the system-wide
    /// > `com.apple.WebKit.WebContent` process count.**
    ///
    /// `None` when no app is running — there is nothing to count, which is a
    /// different answer from zero.
    windows: Option<u64>,
    tabs: Option<u64>,
    resident_tabs: Option<u64>,
    /// Resident `WKWebView`s that are **not** tabs — today, the markdown
    /// reference's window (`2026-08-26-markdown-reference-window`).
    ///
    /// `tab-list` cannot see one by construction, so without asking the app
    /// directly this report would be short by ~52 MB whenever the reference is
    /// open. `None` from an older app that does not send the field, which is
    /// treated as zero below.
    auxiliary_web_views: Option<u64>,
    /// `~100 MB baseline + ~52 MB x resident web views`, in megabytes. The
    /// ADR's formula, evaluated rather than left for the reader.
    ///
    /// Counted over web views rather than over *tabs*: the budget is the
    /// application's, and the reference window's view spends from it.
    estimated_footprint_mb: Option<u64>,
    /// `com.apple.WebKit.WebContent` processes **on the machine**, not ours.
    ///
    /// Counted system-wide on purpose. The superseded ADR's entire correction
    /// was that WebKit's content processes are children of launchd, so a
    /// subtree walk from the app cannot see them:
    ///
    /// > **Never measure process memory by walking the app's process subtree.**
    ///
    /// The consequence is that other applications' web views are in this
    /// number, which is why the human-readable line says "system-wide" rather
    /// than implying they are all ours.
    webcontent_processes: Option<u64>,
}

/// `com.apple.WebKit.WebContent` processes on the machine.
///
/// `ps` rather than anything cleverer: it needs no entitlement, it sees
/// processes launchd owns, and being wrong here is cheap — the number is
/// diagnostic. `None` if `ps` cannot be run at all, so "we did not look" stays
/// distinguishable from "there are none".
fn webcontent_process_count() -> Option<u64> {
    let output = std::process::Command::new("/bin/ps")
        .args(["-axo", "comm="])
        .output()
        .ok()?;
    let listing = String::from_utf8_lossy(&output.stdout);
    Some(
        listing
            .lines()
            .filter(|line| line.contains("com.apple.WebKit.WebContent"))
            .count() as u64,
    )
}

fn cmd_doctor(json: bool) -> Result<(), CliError> {
    // Touching the highlighter is what loads the assets, so this measures a
    // real cold load rather than reporting a cached number.
    let highlighter = mark_core::highlight::shared();

    // ADR-3's 104-byte trap is exactly the thing a bug report needs to show,
    // so `doctor` prints the length next to the limit whether or not it fits —
    // and never launches the app to answer "is it running": that would make the
    // answer yes by asking the question.
    let socket = client::socket_path();
    // One `ping`, rather than a connect to answer "is it running?" and a second
    // round trip to ask what it is: the reply answers both, and a probing
    // client never launches, so asking still cannot make the answer yes.
    let pong = Client::probing()
        .ok()
        .and_then(|client| client.send(&Request::new("ping")).ok());
    let running = pong.is_some();
    let field = |key: &str| {
        pong.as_ref()
            .and_then(|value| value.get(key))
            .and_then(|value| value.as_str())
            .map(ToOwned::to_owned)
    };
    // Absent on an app older than `2026-08-26-markdown-reference-window`, which
    // is the same answer as zero: that build had nothing to count.
    let auxiliary = pong
        .as_ref()
        .and_then(|value| value.get("auxiliaryWebViews"))
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(0);

    // A second round trip, and only when an app is answering. `tab-list` is
    // reused rather than given a sibling command: it already reports every tab
    // in every window with its residency, which is the whole of what the
    // memory formula needs.
    struct Residency {
        windows: u64,
        tabs: u64,
        resident: u64,
    }
    let residency = if running {
        Client::probing()
            .ok()
            .and_then(|client| client.send(&Request::new("tab-list")).ok())
            .and_then(|reply| reply["tabs"].as_array().cloned())
            .map(|tabs| {
                let windows: std::collections::BTreeSet<i64> = tabs
                    .iter()
                    .map(|tab| tab["window"].as_i64().unwrap_or(0))
                    .collect();
                Residency {
                    // An app with a window and no tabs still has one window,
                    // and an older app reports no `window` field at all.
                    windows: windows.len().max(1) as u64,
                    tabs: tabs.len() as u64,
                    resident: tabs
                        .iter()
                        .filter(|tab| tab["resident"].as_bool() == Some(true))
                        .count() as u64,
                }
            })
    } else {
        None
    };

    let doctor = Doctor {
        core_version: mark_core::VERSION.to_owned(),
        cli_version: env!("CARGO_PKG_VERSION").to_owned(),
        build_commit: mark_core::COMMIT.to_owned(),
        build_date: mark_core::BUILD_DATE.to_owned(),
        protocol_version: wire::protocol_version(),
        executable: std::env::current_exe()
            .ok()
            .and_then(|path| path.canonicalize().ok()),
        app_bundle: client::app_bundle(),
        registered_bundles: client::registered_bundles(),
        syntect_asset_load_ms: ms(highlighter.asset_load()),
        git: git::program().map(Path::to_path_buf),
        git_version: git::version(),
        command_line_tools: git::command_line_tools(),
        theme: theme::default_pair().name().to_owned(),
        themes: theme::list().0.len(),
        socket_path: socket.as_ref().ok().map(|path| path.display().to_string()),
        socket_path_bytes: socket.as_ref().ok().map(|path| path.as_os_str().len()),
        socket_path_limit: client::MAX_SOCKET_PATH,
        socket_error: socket.as_ref().err().map(ToString::to_string),
        app_running: running,
        app_build: field("build"),
        app_path: field("app"),
        theme_dir: theme::user_dir().map(|dir| dir.display().to_string()),
        windows: residency.as_ref().map(|r| r.windows),
        tabs: residency.as_ref().map(|r| r.tabs),
        resident_tabs: residency.as_ref().map(|r| r.resident),
        auxiliary_web_views: residency.as_ref().map(|_| auxiliary),
        estimated_footprint_mb: residency
            .as_ref()
            .map(|r| 100 + 52 * (r.resident + auxiliary)),
        webcontent_processes: if running {
            webcontent_process_count()
        } else {
            None
        },
    };

    if json {
        return print_json(&doctor);
    }

    let mut out = Output::new();
    emitln!(out, "core version        {}", doctor.core_version)?;
    emitln!(out, "cli version         {}", doctor.cli_version)?;
    emitln!(
        out,
        "built from          {} ({})",
        doctor.build_commit,
        doctor.build_date
    )?;
    emitln!(out, "protocol version    {}", doctor.protocol_version)?;
    emitln!(
        out,
        "executable          {}",
        doctor
            .executable
            .as_ref()
            .map_or_else(|| "<unknown>".to_owned(), |p| p.display().to_string())
    )?;
    emitln!(
        out,
        "app bundle          {}",
        doctor.app_bundle.as_ref().map_or_else(
            || "<not inside a .app>".to_owned(),
            |p| p.display().to_string()
        )
    )?;
    // Silent when there is one claimant, which is the healthy machine and the
    // common case; loud, and listed, when there is more than one — the whole
    // value is telling a reader that `mark open` is not reaching the build
    // they think it is, at the moment they are already asking what is
    // installed.
    match doctor.registered_bundles.len() {
        0 => emitln!(
            out,
            "registered          none — LaunchServices has no {} (see `brew info mark`)",
            client::BUNDLE_ID
        )?,
        1 => emitln!(
            out,
            "registered          1 bundle claims {}",
            client::BUNDLE_ID
        )?,
        count => {
            emitln!(
                out,
                "registered          {count} bundles claim {} — * is the one `mark open` launches",
                client::BUNDLE_ID
            )?;
            for (index, path) in doctor.registered_bundles.iter().enumerate() {
                emitln!(
                    out,
                    "                    {} {}",
                    if index == 0 { "*" } else { " " },
                    path.display()
                )?;
            }
            if let (Some(winner), Some(mine)) = (
                doctor.registered_bundles.first(),
                doctor.app_bundle.as_ref(),
            ) && winner != mine
            {
                emitln!(
                    out,
                    "                    ! that is not the bundle this CLI is in; `mark open` and `mark render` are two builds"
                )?;
            }
        }
    }
    emitln!(
        out,
        "syntect assets      {:.3} ms",
        doctor.syntect_asset_load_ms
    )?;
    // The first thing to ask when change badges are missing, since every git
    // failure is invisible in the UI by design.
    match (&doctor.git, &doctor.git_version) {
        (Some(path), Some(version)) => {
            emitln!(out, "git                 {version} at {}", path.display())?;
        }
        _ => {
            emitln!(
                out,
                "git                 not found{}",
                if doctor.command_line_tools {
                    ""
                } else {
                    " (no Command Line Tools; run `xcode-select --install`)"
                }
            )?;
        }
    }
    emitln!(
        out,
        "default theme       {} ({} available)",
        doctor.theme,
        doctor.themes
    )?;
    if let (Some(windows), Some(tabs), Some(resident), Some(footprint)) = (
        doctor.windows,
        doctor.tabs,
        doctor.resident_tabs,
        doctor.estimated_footprint_mb,
    ) {
        emitln!(
            out,
            "windows             {windows} ({tabs} tab{}, {resident} resident)",
            if tabs == 1 { "" } else { "s" }
        )?;
        // Web views, not tabs: the reference window holds one and owns no tab,
        // and a formula that counted only tabs would be short by ~52 MB
        // without saying so (`2026-08-26-markdown-reference-window`).
        let auxiliary = doctor.auxiliary_web_views.unwrap_or(0);
        let views = resident + auxiliary;
        let breakdown = if auxiliary == 0 {
            String::new()
        } else {
            format!(
                ": {resident} tab{} + {auxiliary} reference window",
                if resident == 1 { "" } else { "s" }
            )
        };
        emitln!(
            out,
            "memory budget       ~{footprint} MB  (~100 MB + ~52 MB x {views} web view{}{breakdown})",
            if views == 1 { "" } else { "s" }
        )?;
        if let Some(processes) = doctor.webcontent_processes {
            // "system-wide" is not hedging. Every one of these is a child of
            // launchd, ours and everyone else's alike, and the line would be a
            // lie without the word.
            emitln!(out, "WebContent procs    {processes} system-wide")?;
        }
    }
    match (&doctor.socket_path, &doctor.socket_error) {
        (Some(path), _) => {
            emitln!(
                out,
                "socket path         {path}  ({} of {} bytes)",
                doctor.socket_path_bytes.unwrap_or(0),
                doctor.socket_path_limit
            )?;
        }
        (None, Some(error)) => emitln!(out, "socket path         UNUSABLE: {error}")?,
        (None, None) => emitln!(out, "socket path         <unknown>")?,
    }
    emitln!(
        out,
        "app running         {}",
        if doctor.app_running { "yes" } else { "no" }
    )?;
    // Only when there is one to describe: two "n/a" lines under "app running
    // no" would be noise in the report a bug lands with.
    if let Some(build) = &doctor.app_build {
        emitln!(out, "app build           {build}")?;
    }
    if let Some(path) = &doctor.app_path {
        emitln!(out, "app path            {path}")?;
    }
    emitln!(
        out,
        "theme dir           {}",
        doctor.theme_dir.as_deref().unwrap_or("unresolvable")
    )?;
    out.finish()
}

fn ms(duration: std::time::Duration) -> f64 {
    duration.as_secs_f64() * 1e3
}

/// Pretty-printed so `--json` output is readable in a terminal and stable
/// enough to diff.
fn print_json<T: Serialize>(value: &T) -> Result<(), CliError> {
    // Every type we serialize is a plain struct of owned scalars, so the only
    // way this fails is a formatter error — surface it rather than exiting 0
    // with nothing on stdout.
    let json = serde_json::to_string_pretty(value)
        .map_err(|error| CliError::Output(io::Error::other(error)))?;
    let mut out = Output::new();
    emitln!(out, "{json}")?;
    out.finish()
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::CommandFactory;

    #[test]
    fn clap_definition_is_valid() {
        Cli::command().debug_assert();
    }

    /// The man page and the three completion files are hand-written (M10), so
    /// the drift a generator would prevent is prevented here instead: every
    /// subcommand, every nested `tab` action, and every long flag clap knows
    /// about has to appear in all four files.
    ///
    /// Failing here means one of two things, and both are a one-line fix:
    /// either a new command needs documenting, or a flag was renamed and the
    /// docs still say the old name — which is the failure a user meets as a
    /// completion that offers something the binary rejects.
    #[test]
    fn the_man_page_and_completions_name_every_subcommand() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("the workspace root")
            .join("packaging");
        let files = [
            root.join("mark.1"),
            root.join("completions/_mark"),
            root.join("completions/mark.bash"),
            root.join("completions/mark.fish"),
        ];
        let documents: Vec<(String, String)> = files
            .iter()
            .map(|path| {
                let text = std::fs::read_to_string(path)
                    .unwrap_or_else(|error| panic!("{}: {error}", path.display()));
                // fish spells a long option `-l json`, so normalise it to the
                // form the user types before looking for it. Everything else —
                // troff, zsh, bash — writes the flag out.
                let text = if path.extension().is_some_and(|kind| kind == "fish") {
                    text.replace(" -l ", " --")
                } else {
                    text
                };
                (path.display().to_string(), text)
            })
            .collect();

        // clap's own auto-generated `--help`/`--version` are the shell's
        // business, not ours, and every file mentions `--help` anyway.
        let uninteresting = ["help", "version"];
        let command = Cli::command();
        let mut expected: Vec<String> = Vec::new();
        for sub in command.get_subcommands() {
            expected.push(sub.get_name().to_owned());
            for nested in sub.get_subcommands() {
                expected.push(nested.get_name().to_owned());
            }
            for argument in sub
                .get_arguments()
                .chain(sub.get_subcommands().flat_map(clap::Command::get_arguments))
            {
                if let Some(long) = argument.get_long()
                    && !uninteresting.contains(&long)
                {
                    expected.push(format!("--{long}"));
                }
                for alias in argument.get_all_aliases().unwrap_or_default() {
                    expected.push(format!("--{alias}"));
                }
            }
        }
        expected.sort();
        expected.dedup();

        for (name, text) in &documents {
            let missing: Vec<&String> = expected
                .iter()
                .filter(|token| !text.contains(token.as_str()))
                .collect();
            assert!(
                missing.is_empty(),
                "{name} does not mention {missing:?} — see packaging/"
            );
        }
    }

    #[test]
    fn check_defaults_to_toggle() {
        let action = CheckAction {
            on: false,
            off: false,
            toggle: false,
            state: None,
        };
        assert_eq!(action.action().unwrap(), Action::Toggle);
    }

    #[test]
    fn check_actions_map_to_the_core_enum() {
        let on = CheckAction {
            on: true,
            off: false,
            toggle: false,
            state: None,
        };
        assert_eq!(on.action().unwrap(), Action::On);
        let off = CheckAction {
            on: false,
            off: true,
            toggle: false,
            state: None,
        };
        assert_eq!(off.action().unwrap(), Action::Off);
    }

    /// `--state` reaches the same enum, for all five states, and an unknown
    /// name is a usage error rather than a default.
    #[test]
    fn check_state_names_map_to_the_core_enum() {
        for (name, expected) in [
            ("open", Action::Off),
            ("in-progress", Action::InProgress),
            ("done", Action::On),
            ("cancelled", Action::Cancel),
            ("blocked", Action::Block),
        ] {
            let action = CheckAction {
                on: false,
                off: false,
                toggle: false,
                state: Some(name.to_owned()),
            };
            assert_eq!(action.action().unwrap(), expected, "--state {name}");
        }

        let bad = CheckAction {
            on: false,
            off: false,
            toggle: false,
            state: Some("doing".to_owned()),
        };
        let error = bad.action().expect_err("unknown state is a usage error");
        assert_eq!(error.code(), EXIT_USAGE);
        assert!(error.to_string().contains("in-progress"), "{error}");
    }

    #[test]
    fn dates_round_trip_through_the_day_number() {
        for date in ["1970-01-01", "2000-02-29", "2026-08-27", "2100-03-01"] {
            let (year, month, day) = tasks::parse_iso_date(date).expect("a date");
            assert_eq!(civil_from_days(days_from_civil(year, month, day)), date);
        }
        assert_eq!(days_from_civil(1970, 1, 1), 0);
        assert_eq!(civil_from_days(1), "1970-01-02");
    }

    #[test]
    fn when_arguments_accept_a_date_today_and_an_offset() {
        assert_eq!(
            resolve_when("2026-09-01", "2026-08-27").unwrap(),
            "2026-09-01"
        );
        assert_eq!(resolve_when("today", "2026-08-27").unwrap(), "2026-08-27");
        assert_eq!(resolve_when("+7d", "2026-08-27").unwrap(), "2026-09-03");
        assert_eq!(resolve_when("-1d", "2026-08-27").unwrap(), "2026-08-26");
        let error = resolve_when("friday", "2026-08-27").expect_err("not a date");
        assert_eq!(error.code(), EXIT_USAGE);
    }

    /// `mark normalize`'s degrade, and its idempotence — running it twice must
    /// change nothing the second time, or `--in-place` would grow `~~` markers
    /// on every run.
    #[test]
    fn normalize_degrades_every_extended_marker_losslessly() {
        let source = "- [/] doing\n- [-] dropped\n- [?] stuck\n- [ ] plain\n- [x] done\n";
        let once = normalize_to_gfm(source);
        assert_eq!(once.edits, 3);
        assert_eq!(
            once.source,
            "- [ ] doing @doing\n- [x] ~~dropped~~\n- [ ] stuck @blocked\n- [ ] plain\n- [x] done\n"
        );

        // Lossless: the state is still readable from the file.
        let tasks = tasks::enumerate_source(&once.source);
        assert!(tasks[0].tags.iter().any(|tag| tag.name == "doing"));
        assert!(tasks[2].tags.iter().any(|tag| tag.name == "blocked"));
        // And the cancelled item is now done *and* struck, not merely done.
        assert_eq!(tasks[1].state, tasks::State::Done);
        assert_eq!(tasks[1].text, "dropped");

        // Pure GFM afterwards: no extended marker survives.
        let counts = tasks::counts(&once.source);
        assert_eq!(
            (counts.in_progress, counts.cancelled, counts.blocked),
            (0, 0, 0)
        );

        let twice = normalize_to_gfm(&once.source);
        assert_eq!(twice.edits, 0);
        assert_eq!(twice.source, once.source);
    }

    #[test]
    fn normalize_leaves_a_gfm_document_byte_identical() {
        let source = "# T\n\n- [ ] one\n- [x] two\n\nA literal [ ] in prose.\n";
        let out = normalize_to_gfm(source);
        assert_eq!(out.edits, 0);
        assert_eq!(out.source, source);
    }

    #[test]
    fn normalize_does_not_double_strike_an_already_struck_item() {
        let out = normalize_to_gfm("- [-] ~~gone~~\n");
        assert_eq!(out.source, "- [x] ~~gone~~\n");
    }

    #[test]
    fn normalize_leaves_a_partly_struck_item_alone() {
        // Wrapping this again would write `~~a ~~b~~~~`, which is worse than
        // not wrapping it.
        let out = normalize_to_gfm("- [-] a ~~b~~\n");
        assert_eq!(out.source, "- [x] a ~~b~~\n");
    }

    #[test]
    fn normalize_keeps_a_tag_it_would_have_added() {
        let out = normalize_to_gfm("- [/] a @doing\n");
        assert_eq!(out.source, "- [ ] a @doing\n");
    }

    #[test]
    fn a_query_filters_on_state_tag_priority_and_date() {
        let source = "- [ ] a @work @due(2026-09-10) !\n- [/] b @home @due(2026-08-01)\n\
                      - [x] c @work\n- [-] d\n- [?] e @work !!!\n";
        let tasks = tasks::enumerate_source(source);
        let labels = |query: &TaskQuery| -> Vec<String> {
            tasks
                .iter()
                .filter(|task| query.matches(task))
                .map(|task| task.label.clone())
                .collect()
        };
        let query = |args: &[(&str, &str)]| -> TaskQuery {
            let get = |name: &str| {
                args.iter()
                    .find(|(key, _)| *key == name)
                    .map(|(_, value)| *value)
            };
            let states: Vec<String> = args
                .iter()
                .filter(|(key, _)| *key == "state")
                .map(|(_, value)| (*value).to_owned())
                .collect();
            let tags: Vec<String> = args
                .iter()
                .filter(|(key, _)| *key == "tag")
                .map(|(_, value)| (*value).to_owned())
                .collect();
            TaskQuery::new(
                get("open").is_some(),
                &states,
                &tags,
                get("priority").map(|v| v.parse().unwrap()),
                get("due-before"),
                get("due-after"),
                get("overdue").is_some(),
                get("no-due").is_some(),
                get("sort"),
                Some("2026-08-27"),
            )
            .expect("a valid query")
        };

        assert_eq!(labels(&query(&[("open", "")])), ["a", "b", "e"]);
        assert_eq!(
            labels(&query(&[("state", "done"), ("state", "cancelled")])),
            ["c", "d"]
        );
        assert_eq!(labels(&query(&[("tag", "@work")])), ["a", "c", "e"]);
        assert_eq!(labels(&query(&[("priority", "2")])), ["e"]);
        assert_eq!(labels(&query(&[("overdue", "")])), ["b"]);
        assert_eq!(labels(&query(&[("no-due", "")])), ["c", "d", "e"]);
        assert_eq!(labels(&query(&[("due-before", "+14d")])), ["b"]);
        assert_eq!(labels(&query(&[("due-after", "today")])), ["a"]);

        // Ordering, over the same document.
        let ordered = |key: &str| -> Vec<String> {
            let mut rows: Vec<TaskRow> = tasks
                .iter()
                .cloned()
                .map(|task| TaskRow::new(PathBuf::from("q.md"), task))
                .collect();
            query(&[("sort", key)]).order(&mut rows);
            rows.into_iter().map(|row| row.label).collect()
        };
        assert_eq!(ordered("index"), ["a", "b", "c", "d", "e"]);
        assert_eq!(ordered("due"), ["b", "a", "c", "d", "e"]);
        assert_eq!(ordered("priority"), ["e", "a", "b", "c", "d"]);
        assert_eq!(ordered("state"), ["a", "b", "c", "d", "e"]);
    }

    #[test]
    fn exit_codes_follow_the_error_policy() {
        assert_eq!(
            CliError::Task(TaskError::IndexOutOfRange { index: 9, total: 1 }).code(),
            EXIT_TASK_RANGE
        );
        assert_eq!(
            CliError::Read {
                path: PathBuf::from("x"),
                source: io::Error::from(io::ErrorKind::NotFound),
            }
            .code(),
            EXIT_FILE
        );
    }

    #[test]
    fn line_bounds_covers_first_middle_and_last_lines() {
        let source = "alpha\nbeta\ngamma";
        assert_eq!(&source[line_bounds(source, 0)], "alpha");
        assert_eq!(&source[line_bounds(source, 7)], "beta");
        assert_eq!(&source[line_bounds(source, 12)], "gamma");
    }

    #[test]
    fn heading_path_is_a_breadcrumb() {
        let source = "# Top\n\n## Middle\n\ntext\n\n## Other\n\nmore\n";
        let doc = Document::parse(source);
        let headings = doc.headings();
        let offset = source.find("text").unwrap();
        assert_eq!(heading_path(&headings, offset).0, "Top > Middle");
        let offset = source.find("more").unwrap();
        assert_eq!(heading_path(&headings, offset).0, "Top > Other");
    }

    #[test]
    fn a_long_tab_title_is_cut_without_splitting_a_character() {
        assert_eq!(ellipsize("short", 24), "short");
        let long = "Talk to the running app over a Unix socket";
        assert_eq!(ellipsize(long, 10).chars().count(), 10);
        assert!(ellipsize(long, 10).ends_with('…'));
        // Multi-byte, cut mid-string: this panics if the cut is by bytes.
        assert_eq!(ellipsize("émoji → 🎯 title", 5).chars().count(), 5);
    }

    #[test]
    fn heading_path_is_empty_above_the_first_heading() {
        let doc = Document::parse("intro\n\n# Later\n");
        assert_eq!(heading_path(&doc.headings(), 0), (String::new(), None));
    }
}
