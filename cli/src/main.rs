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

use std::fmt;
use std::fs;
use std::io::{self, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Instant;

use clap::{Args, Parser, Subcommand};
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
        /// Only unchecked tasks.
        #[arg(long)]
        open: bool,
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
        #[arg(long)]
        json: bool,
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
    /// Flip it. The default.
    #[arg(long)]
    toggle: bool,
}

impl CheckAction {
    fn action(&self) -> Action {
        match (self.on, self.off) {
            (true, _) => Action::On,
            (_, true) => Action::Off,
            _ => Action::Toggle,
        }
    }
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
        Command::Toc { file, json } => cmd_toc(file, *json),
        Command::Tasks {
            path,
            open,
            json,
            depth,
        } => cmd_tasks(path.as_deref(), *open, *json, *depth),
        Command::Check {
            file,
            item,
            action,
            json,
        } => cmd_check(file, *item, action.action(), *json),
        Command::Ls {
            dir,
            json,
            depth,
            all,
        } => cmd_ls(dir.as_deref(), *json, *depth, *all),
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
            // The window column appears only when there is more than one
            // window (2026-08-26-multiple-windows-and-split-panes). A `w0` on
            // every row of a single-window listing would be a column of
            // constants, and every existing script's parse would shift for
            // nothing. Absent entirely from an older app's reply, which reads
            // here as one window.
            let windows: std::collections::BTreeSet<i64> = tabs
                .iter()
                .filter_map(|tab| tab["window"].as_i64())
                .collect();
            let show_windows = windows.len() > 1;
            for tab in &tabs {
                let tasks = match (tab["openTasks"].as_i64(), tab["totalTasks"].as_i64()) {
                    (Some(open), Some(total)) if total > 0 => format!("{open}/{total}"),
                    _ => String::new(),
                };
                // `w0/2` rather than a bare index: the number means nothing on
                // its own, and the pane is what says *which half* of a split
                // window a document is in.
                let window = if show_windows {
                    match (tab["window"].as_i64(), tab["pane"].as_str()) {
                        (Some(w), Some("secondary")) => format!("w{w}R "),
                        (Some(w), Some(_)) => format!("w{w}L "),
                        (Some(w), None) => format!("w{w}  "),
                        (None, _) => "     ".to_string(),
                    }
                } else {
                    String::new()
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

        TabAction::Close { target, json } => {
            let request = match target {
                Some(target) => TabAction::selector("tab-close", target)?,
                None => Request::new("tab-close"),
            };
            let result = call(request)?;
            if *json {
                return print_json(&result);
            }
            let mut out = Output::new();
            emitln!(
                out,
                "closed {}, {} left",
                result["closed"]["path"].as_str().unwrap_or_default(),
                result["tabs"].as_i64().unwrap_or(0)
            )?;
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

#[derive(Serialize)]
struct TaskRow {
    path: PathBuf,
    index: usize,
    checked: bool,
    start: usize,
    end: usize,
    line: usize,
    text: String,
}

fn cmd_tasks(
    path: Option<&Path>,
    open_only: bool,
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
    for file in &targets {
        let source = read_walked(root, file)?;
        for task in tasks::enumerate_source(&source) {
            if open_only && task.checked {
                continue;
            }
            rows.push(TaskRow {
                path: file.clone(),
                index: task.index,
                checked: task.checked,
                start: task.start,
                end: task.end,
                line: task.line,
                text: task.text,
            });
        }
    }
    trace(|| format!("enumerate {} tasks", rows.len()), started);

    if json {
        return print_json(&rows);
    }

    let mut out = Output::new();
    for row in &rows {
        emitln!(
            out,
            "{}:{} [{}] {}  ({})",
            row.path.display(),
            row.index,
            if row.checked { 'x' } else { ' ' },
            row.text,
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
    checked: bool,
    text: &'a str,
    /// The single byte the write changed — ADR-1's *"a byte-range in-place edit
    /// of the character between the brackets"*, reported rather than described.
    offset: usize,
}

fn cmd_check(path: &Path, index: usize, action: Action, json: bool) -> Result<(), CliError> {
    let started = Instant::now();
    let toggled = tasks::toggle_file(path, index, action)?;
    trace(
        || format!("toggle {} item {index}", path.display()),
        started,
    );

    if json {
        return print_json(&CheckedTask {
            path,
            index: toggled.index,
            checked: toggled.checked,
            text: &toggled.text,
            offset: toggled.offset,
        });
    }

    let mut out = Output::new();
    emitln!(
        out,
        "[{}] {}:{}  {}",
        if toggled.checked { 'x' } else { ' ' },
        path.display(),
        toggled.index,
        toggled.text
    )?;
    out.finish()
}

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
}

fn cmd_ls(dir: Option<&Path>, json: bool, depth: usize, all: bool) -> Result<(), CliError> {
    let root = dir.unwrap_or_else(|| Path::new("."));
    let options = tree::Options {
        max_depth: depth.max(1),
        with_stats: true,
        markdown_only: !all,
        hidden: false,
    };
    let entries = tree::list_dir(root, &options)?;

    let rows: Vec<LsRow> = entries
        .into_iter()
        .map(|entry| LsRow {
            path: entry.path,
            name: entry.name,
            is_dir: entry.is_dir,
            depth: entry.depth,
            title: entry.title,
            open: entry.tasks.map(|t| t.open),
            total: entry.tasks.map(|t| t.total),
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
        match (row.open, row.total) {
            (Some(open), Some(total)) if total > 0 => {
                emitln!(out, "{indent}{}  {title}  [{open}/{total}]", row.name)?;
            }
            _ => emitln!(out, "{indent}{}  {title}", row.name)?,
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
        "tasks             {} open / {} total",
        stats.tasks.open,
        stats.tasks.total
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
    syntect_asset_load_ms: f64,
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
    /// `~100 MB baseline + ~52 MB x resident tabs`, in megabytes. The ADR's
    /// formula, evaluated rather than left for the reader.
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
        syntect_asset_load_ms: ms(highlighter.asset_load()),
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
        estimated_footprint_mb: residency.as_ref().map(|r| 100 + 52 * r.resident),
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
    emitln!(
        out,
        "syntect assets      {:.3} ms",
        doctor.syntect_asset_load_ms
    )?;
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
        emitln!(
            out,
            "memory budget       ~{footprint} MB  (~100 MB + ~52 MB x {resident} resident)"
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
        };
        assert_eq!(action.action(), Action::Toggle);
    }

    #[test]
    fn check_actions_map_to_the_core_enum() {
        let on = CheckAction {
            on: true,
            off: false,
            toggle: false,
        };
        assert_eq!(on.action(), Action::On);
        let off = CheckAction {
            on: false,
            off: true,
            toggle: false,
        };
        assert_eq!(off.action(), Action::Off);
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
