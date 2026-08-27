//! Two real processes competing for one document.
//!
//! `2026-08-25-flock-write-locking` is a statement about *processes*, and a
//! same-process test cannot make it: `flock` is per open file description, and
//! whether two descriptions inside one process conflict is a kernel detail this
//! suite should not be resting on. So everything here forks a real second
//! process — `cli/tests/kill_during_write.rs` is the precedent — and the
//! properties it checks are the ones that justified choosing `flock` over the
//! lock file the superseded ADR rejected:
//!
//! * a second `mark` is **refused**, with the holder's pid in the message and
//!   exit status 6, which is distinct from 2 ("no such file") and 5 ("the app
//!   refused");
//! * a holder killed with `SIGKILL` **releases the lock instantly**, with no
//!   cleanup code of ours involved — *"Nothing leaks: there is no lock file, no
//!   heartbeat, no stale detection, and no cleanup path to get wrong"*;
//! * a document nobody holds is written normally, which is the ADR's *"a clean
//!   tab holds no lock, so viewing a document never blocks anything"* seen from
//!   the CLI's side.
//!
//! The holder is this test binary re-executed as a child (see
//! [`holds_a_document_until_it_is_killed`]), rather than a second `mark-cli`:
//! the CLI has no verb that holds a lock open, because holding one is the app's
//! job, and inventing one purely for a test would be testing the test.

use std::io::{BufRead as _, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use tempfile::TempDir;

const DOCUMENT: &str = "# Notes\n\n- [ ] one\n- [ ] two\n";

/// Set on the child that plays the lock holder. Its value is the document.
const HOLD: &str = "MARK_TEST_HOLD_DOCUMENT";

fn cli() -> &'static str {
    env!("CARGO_BIN_EXE_mark-cli")
}

fn fixture() -> (TempDir, PathBuf) {
    let directory = TempDir::new().expect("temp dir");
    let path = directory.path().join("notes.md");
    std::fs::write(&path, DOCUMENT).expect("write the fixture");
    (directory, path)
}

/// Run `mark check --item 0 --on` and report `(code, stderr)`.
fn check(path: &Path) -> (i32, String) {
    let output = Command::new(cli())
        .args([
            "check",
            path.to_str().expect("utf-8 path"),
            "--item",
            "0",
            "--on",
        ])
        .output()
        .expect("spawn mark-cli");
    (
        output
            .status
            .code()
            .expect("mark-cli was killed by a signal"),
        String::from_utf8_lossy(&output.stderr).into_owned(),
    )
}

/// **A helper, not a test.** `#[ignore]`d so a plain `cargo test` skips it, and
/// re-executed with `--ignored` by [`spawn_holder`] to obtain a second process.
///
/// Re-executing this binary is how that second process is obtained without
/// adding a `mark` verb that exists only for tests. It takes the lock on
/// [`HOLD`], prints `locked <pid>` so the parent knows the race is over, and
/// blocks forever waiting to be killed.
///
/// It was briefly a real test as well, asserting in-process that a dropped
/// guard releases its lock. That flaked roughly once in a few hundred runs, and
/// the cause is worth writing down because it is a property of `flock` and not
/// of this code: **a `fork` duplicates the open file description, and `O_CLOEXEC`
/// does not take effect until the `exec`**, so for the width of that window a
/// child holds a second reference to the parent's lock and the parent's
/// `close()` does not release it. Sibling tests here spawn processes constantly.
/// Measured directly at ~1 in 4,000 acquire/release cycles under four concurrent
/// spawner threads. The property it was checking is asserted where nothing
/// forks, in `core::lock::tests::a_lock_is_held_and_released_with_its_guard`.
#[test]
#[ignore = "a lock-holding child process for the other tests in this file"]
fn holds_a_document_until_it_is_killed() {
    let document = std::env::var(HOLD).expect("run by spawn_holder, with the document to hold");
    let lock = mark_core::lock::DocumentLock::acquire(Path::new(&document)).expect("acquire");
    assert!(lock.is_held(), "the holder child did not get the lock");
    println!("locked {}", std::process::id());
    // Flushed by println!'s line buffering on a pipe? Not reliably — say so.
    use std::io::Write as _;
    std::io::stdout().flush().expect("flush");
    loop {
        std::thread::sleep(Duration::from_secs(3600));
    }
}

/// Spawn the holder and wait until it reports that it has the lock. Returns the
/// child and its pid.
fn spawn_holder(path: &Path) -> (Child, u32) {
    let mut child = Command::new(std::env::current_exe().expect("current exe"))
        .args([
            "--exact",
            "holds_a_document_until_it_is_killed",
            // `--ignored` because the helper is `#[ignore]`d: it is not a test,
            // and a plain `cargo test` must not sit in its sleep loop forever.
            "--ignored",
            "--nocapture",
        ])
        .env(HOLD, path)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn the holder");

    // Every failure below reaps the child before reporting, or a failing test
    // would leave a process holding a lock on a temp file forever.
    let announced = (|| -> Result<u32, String> {
        let stdout = child.stdout.take().ok_or("the holder has no stdout")?;
        let mut reader = BufReader::new(stdout);
        let deadline = Instant::now() + Duration::from_secs(20);
        let mut line = String::new();
        while Instant::now() < deadline {
            line.clear();
            match reader.read_line(&mut line) {
                Ok(0) => return Err("the holder exited before taking the lock".into()),
                Ok(_) => {}
                Err(error) => return Err(format!("reading the holder's stdout: {error}")),
            }
            if let Some(pid) = line.strip_prefix("locked ") {
                return pid
                    .trim()
                    .parse()
                    .map_err(|error| format!("the holder's pid: {error}"));
            }
        }
        Err("the holder never reported taking the lock".into())
    })();

    match announced {
        Ok(pid) => (child, pid),
        Err(why) => {
            let _ = child.kill();
            let _ = child.wait();
            panic!("{why}");
        }
    }
}

#[test]
fn a_second_process_is_refused_and_told_who_holds_the_document() {
    let (_directory, path) = fixture();
    let (mut holder, pid) = spawn_holder(&path);

    let (code, stderr) = check(&path);

    assert_eq!(
        code, 6,
        "a locked document must exit 6, not {code} — stderr was: {stderr}"
    );
    assert!(
        stderr.contains(&pid.to_string()),
        "the refusal does not name the holder's pid {pid}: {stderr}"
    );
    assert!(
        stderr.contains("locked for writing"),
        "the refusal does not say what went wrong: {stderr}"
    );
    assert_eq!(
        std::fs::read_to_string(&path).expect("read back"),
        DOCUMENT,
        "the refused process wrote anyway"
    );

    let _ = holder.kill();
    let _ = holder.wait();
}

/// `mark normalize --in-place` is a new write path, so it inherits the lock in
/// full — which it does structurally, by going through `write_atomically`, but
/// "structurally" is what this asserts rather than assumes.
///
/// `2026-08-27-five-task-states` states it as a consequence: *"inherits
/// `2026-08-25-flock-write-locking` in full: `write_atomically`, `LOCK_NB`,
/// refuse rather than block."*
#[test]
fn normalize_in_place_is_refused_on_a_locked_document() {
    let (_directory, path) = fixture();
    // A document with something to normalize, so a refusal cannot be confused
    // with "there was nothing to do".
    let extended = "# Notes\n\n- [-] dropped\n- [/] doing\n";
    std::fs::write(&path, extended).expect("write the fixture");
    let (mut holder, pid) = spawn_holder(&path);

    let output = Command::new(cli())
        .args([
            "normalize",
            path.to_str().expect("utf-8 path"),
            "--in-place",
        ])
        .output()
        .expect("spawn mark-cli");
    let code = output.status.code().expect("exited normally");
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();

    assert_eq!(
        code, 6,
        "a locked document must exit 6, not {code} — stderr was: {stderr}"
    );
    assert!(
        stderr.contains(&pid.to_string()) && stderr.contains("locked for writing"),
        "the refusal does not name the holder: {stderr}"
    );
    assert_eq!(
        std::fs::read_to_string(&path).expect("read back"),
        extended,
        "the refused process wrote anyway"
    );

    // Reading it is never blocked, and stdout is not a write.
    let output = Command::new(cli())
        .args(["normalize", path.to_str().expect("utf-8 path")])
        .output()
        .expect("spawn mark-cli");
    assert_eq!(output.status.code(), Some(0));
    assert!(String::from_utf8_lossy(&output.stdout).contains("- [x] ~~dropped~~"));

    let _ = holder.kill();
    let _ = holder.wait();
}

/// `mark check --stamp` is a second write path — one that is not one byte — and
/// it takes the same lock, for the same reason.
#[test]
fn stamping_is_refused_on_a_locked_document() {
    let (_directory, path) = fixture();
    let (mut holder, pid) = spawn_holder(&path);

    let output = Command::new(cli())
        .args([
            "check",
            path.to_str().expect("utf-8 path"),
            "--item",
            "0",
            "--on",
            "--stamp",
            "--today",
            "2026-08-27",
        ])
        .output()
        .expect("spawn mark-cli");
    let code = output.status.code().expect("exited normally");
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();

    assert_eq!(code, 6, "stamping a locked document must exit 6: {stderr}");
    assert!(stderr.contains(&pid.to_string()), "{stderr}");
    assert_eq!(
        std::fs::read_to_string(&path).expect("read back"),
        DOCUMENT,
        "the refused process wrote anyway"
    );

    let _ = holder.kill();
    let _ = holder.wait();
}

/// The property that justified `flock` over a lock file, proved rather than
/// asserted: *"A crashed or `kill -9`'d app releases every lock it held,
/// instantly, without our involvement."*
#[test]
fn a_killed_holder_releases_the_lock_with_no_cleanup() {
    let (directory, path) = fixture();
    let (mut holder, pid) = spawn_holder(&path);

    // While it lives, we are locked out.
    let (code, _) = check(&path);
    assert_eq!(code, 6, "the holder was not actually holding");

    // SIGKILL: no unwinding, no destructors, no atexit, nothing of ours runs.
    // A lock file would still be sitting there after this.
    assert_eq!(
        Command::new("/bin/kill")
            .args(["-9", &pid.to_string()])
            .status()
            .expect("kill -9")
            .code(),
        Some(0)
    );
    let status = holder.wait().expect("reap the holder");
    assert!(
        status.code().is_none(),
        "the holder exited normally ({status:?}); it was supposed to be killed"
    );

    // The very next writer succeeds. No sweep, no staleness check, no timeout:
    // the kernel dropped the lock when the process's descriptors were closed.
    let (code, stderr) = check(&path);
    assert_eq!(code, 0, "the lock outlived its killed holder: {stderr}");
    assert_eq!(
        std::fs::read_to_string(&path).expect("read back"),
        "# Notes\n\n- [x] one\n- [ ] two\n"
    );

    // And nothing is left on disk to clean up — the whole point.
    let leftovers: Vec<String> = std::fs::read_dir(directory.path())
        .expect("read the directory")
        .filter_map(Result::ok)
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| name != "notes.md")
        .collect();
    assert_eq!(
        leftovers,
        Vec::<String>::new(),
        "a killed holder left something behind"
    );
}

/// Exit 6 has to be *distinguishable*, which is the whole reason it is not 2.
/// A caller branching on "locked" must not catch "no such file" as well.
#[test]
fn locked_is_a_different_exit_code_from_missing_and_from_refused() {
    let (directory, path) = fixture();
    let missing = directory.path().join("nope.md");

    let (code, _) = check(&missing);
    assert_eq!(code, 2, "a missing file is 2");

    let (mut holder, _) = spawn_holder(&path);
    let (code, _) = check(&path);
    assert_eq!(code, 6, "a locked file is 6");
    let _ = holder.kill();
    let _ = holder.wait();

    // And with nobody holding it, the same command succeeds. This is the ADR's
    // "a clean tab holds no lock" from the CLI's side: an open document that
    // nobody is editing is writable.
    let (code, stderr) = check(&path);
    assert_eq!(code, 0, "an unheld document must be writable: {stderr}");
}

/// Two `mark check` processes at once. Neither may corrupt the document, and
/// the loser must say why rather than silently doing nothing.
#[test]
fn two_writers_at_once_serialise_or_refuse_but_never_corrupt() {
    let (_directory, path) = fixture();
    let both = "- [ ] one\n";
    std::fs::write(&path, both).expect("fixture");

    let mut children: Vec<Child> = (0..8)
        .map(|_| {
            Command::new(cli())
                .args([
                    "check",
                    path.to_str().expect("utf-8 path"),
                    "--item",
                    "0",
                    "--toggle",
                ])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .expect("spawn mark-cli")
        })
        .collect();

    let mut succeeded = 0;
    let mut locked_out = 0;
    for child in &mut children {
        let code = child
            .wait()
            .expect("wait for a concurrent writer")
            .code()
            .expect("a concurrent writer was killed by a signal");
        match code {
            0 => succeeded += 1,
            6 => locked_out += 1,
            other => panic!("unexpected exit {other} from a concurrent writer"),
        }
    }
    assert!(succeeded >= 1, "every concurrent writer was refused");
    println!("{succeeded} wrote, {locked_out} were locked out");

    let after = std::fs::read_to_string(&path).expect("read back");
    assert!(
        after == "- [ ] one\n" || after == "- [x] one\n",
        "concurrent writers corrupted the document: {after:?}"
    );
}
