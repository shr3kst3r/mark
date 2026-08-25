//! The socket half of the CLI, against a fake app.
//!
//! ADR-3's contract has two sides and this exercises ours without a GUI: a real
//! `UnixListener` on a real `$TMPDIR/mark-$UID.sock`, a canned response, and
//! assertions on what went over the wire and what came back out as an exit
//! code. `scripts/integration.sh` does the same round trip against the actual
//! app; this runs in `cargo test`, in milliseconds, and fails with a diff
//! rather than a screenshot.
//!
//! Nothing here may launch the app: `MARK_NO_LAUNCH=1` is set on every
//! invocation that expects to fail to connect, so `cargo test` never puts a
//! window on screen.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use tempfile::TempDir;

fn binary() -> &'static str {
    env!("CARGO_BIN_EXE_mark-cli")
}

fn uid() -> u32 {
    // SAFETY: `getuid` cannot fail and touches no memory we own.
    unsafe { libc::getuid() }
}

/// A scratch `$TMPDIR` under `/tmp` rather than under the default
/// `/var/folders/...`, so the socket path stays comfortably inside ADR-3's
/// 104-byte limit no matter how deep the runner's temp directory is.
fn scratch() -> TempDir {
    tempfile::Builder::new()
        .prefix("mark-ipc")
        .tempdir_in("/tmp")
        .expect("a temp dir under /tmp")
}

/// A fake `mark.app`: accepts one connection, reads one line, answers with
/// `response`, and hands the request back to the test.
struct FakeApp {
    _directory: TempDir,
    tmpdir: PathBuf,
    requests: mpsc::Receiver<String>,
    handle: Option<thread::JoinHandle<()>>,
}

impl FakeApp {
    fn answering(response: &str) -> FakeApp {
        let directory = scratch();
        let tmpdir = directory.path().to_path_buf();
        let socket = tmpdir.join(format!("mark-{}.sock", uid()));
        let listener = UnixListener::bind(&socket).expect("bind the fake socket");
        let (sender, requests) = mpsc::channel();
        let response = response.to_owned();

        let handle = thread::spawn(move || {
            // One connection is all any single CLI invocation makes.
            if let Ok((stream, _)) = listener.accept() {
                let mut reader = BufReader::new(&stream);
                let mut line = String::new();
                if reader.read_line(&mut line).is_ok() {
                    let _ = sender.send(line.trim().to_owned());
                }
                let mut writer = &stream;
                let _ = writer.write_all(response.as_bytes());
                let _ = writer.write_all(b"\n");
                let _ = writer.flush();
            }
        });

        FakeApp {
            _directory: directory,
            tmpdir,
            requests,
            handle: Some(handle),
        }
    }

    /// The request the CLI sent, decoded.
    fn request(&mut self) -> serde_json::Value {
        let line = self
            .requests
            .recv_timeout(Duration::from_secs(5))
            .expect("the CLI sent a request");
        serde_json::from_str(&line).expect("the request is JSON")
    }

    fn saw_no_request(&self) -> bool {
        self.requests
            .recv_timeout(Duration::from_millis(200))
            .is_err()
    }

    fn run(&self, args: &[&str]) -> Output {
        Command::new(binary())
            .args(args)
            .env("TMPDIR", &self.tmpdir)
            .env("MARK_NO_LAUNCH", "1")
            .output()
            .expect("the binary was built by cargo test")
    }
}

impl Drop for FakeApp {
    fn drop(&mut self) {
        if let Some(handle) = self.handle.take() {
            // The accept thread exits after one connection; if the test never
            // connected, unblock it.
            let socket = self.tmpdir.join(format!("mark-{}.sock", uid()));
            let _ = std::os::unix::net::UnixStream::connect(socket);
            let _ = handle.join();
        }
    }
}

fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned()
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

fn code(output: &Output) -> i32 {
    output.status.code().expect("process exited normally")
}

fn note(dir: &Path) -> PathBuf {
    let path = dir.join("note.md");
    std::fs::write(&path, "# Note\n\n- [ ] one\n").expect("write the fixture");
    path
}

const OPEN_OK: &str = r#"{"version":1,"ok":true,"result":{"tab":{"index":1,"path":"/tmp/note.md","title":"Note","selected":true,"resident":true},"tabs":2}}"#;

#[test]
fn open_sends_a_versioned_request_with_an_absolute_path() {
    let mut app = FakeApp::answering(OPEN_OK);
    let file = note(&app.tmpdir);

    let output = app.run(&["open", file.to_str().unwrap()]);
    let request = app.request();

    assert_eq!(code(&output), 0, "{}", stderr(&output));
    assert_eq!(request["version"], serde_json::json!(1));
    assert_eq!(request["command"], serde_json::json!("open"));
    assert_eq!(
        request["arguments"]["path"],
        serde_json::json!(file.to_str().unwrap())
    );
    assert!(request["arguments"].get("tab").is_none(), "{request}");
    assert!(
        stdout(&output).contains("tab 1 of 2"),
        "{}",
        stdout(&output)
    );
}

#[test]
fn open_from_a_relative_path_still_sends_an_absolute_one() {
    let mut app = FakeApp::answering(OPEN_OK);
    let file = note(&app.tmpdir);

    let output = Command::new(binary())
        .args(["open", "note.md"])
        .current_dir(&app.tmpdir)
        .env("TMPDIR", &app.tmpdir)
        .env("MARK_NO_LAUNCH", "1")
        .output()
        .expect("run");
    let request = app.request();

    assert_eq!(code(&output), 0, "{}", stderr(&output));
    let sent = request["arguments"]["path"].as_str().unwrap().to_owned();
    assert!(sent.starts_with('/'), "{sent}");
    assert!(sent.ends_with("note.md"), "{sent}");
    assert!(Path::new(&sent).exists(), "{sent}");
    assert_eq!(
        std::fs::canonicalize(&sent).unwrap(),
        std::fs::canonicalize(&file).unwrap()
    );
}

/// A symlinked document must reach the app as the **link**, not its target.
///
/// `std::path::absolute` is used rather than `canonicalize` for exactly this:
/// `2026-08-24-editing-pane-and-autosave` (M9) writes the buffer back to the
/// path it was opened with, and the M1 review already found one bug where a
/// symlink was resolved and the wrong file written. Opening is where that path
/// is chosen, so the property belongs here too.
#[test]
fn a_symlinked_document_is_sent_as_the_link_the_user_named() {
    let mut app = FakeApp::answering(OPEN_OK);
    let file = note(&app.tmpdir);
    let link = app.tmpdir.join("link.md");
    std::os::unix::fs::symlink(&file, &link).expect("symlink");

    let output = app.run(&["open", link.to_str().unwrap()]);
    let request = app.request();

    assert_eq!(code(&output), 0, "{}", stderr(&output));
    assert_eq!(
        request["arguments"]["path"],
        serde_json::json!(link.to_str().unwrap()),
        "the link must not be resolved to its target"
    );
}

#[test]
fn the_tab_flag_travels_as_an_argument() {
    let mut app = FakeApp::answering(OPEN_OK);
    let file = note(&app.tmpdir);

    let output = app.run(&["open", file.to_str().unwrap(), "--tab"]);
    let request = app.request();

    assert_eq!(code(&output), 0, "{}", stderr(&output));
    assert_eq!(request["arguments"]["tab"], serde_json::json!("1"));
    assert!(
        stdout(&output).contains("background"),
        "{}",
        stdout(&output)
    );
}

#[test]
fn a_refused_command_exits_five_with_the_apps_message() {
    let mut app = FakeApp::answering(
        r#"{"version":1,"ok":false,"error":{"code":"anchor-not-found","message":"README.md has no anchor \"nope\"","anchor":"nope"}}"#,
    );

    let output = app.run(&["goto", "#nope"]);
    let request = app.request();

    assert_eq!(request["command"], serde_json::json!("goto"));
    // The `#` is stripped by the app, not here — one place decides.
    assert_eq!(request["arguments"]["anchor"], serde_json::json!("#nope"));
    assert_eq!(code(&output), 5, "{}", stderr(&output));
    assert!(
        stderr(&output).contains("has no anchor"),
        "{}",
        stderr(&output)
    );
}

#[test]
fn a_missing_file_the_app_reports_keeps_exit_code_two() {
    let app = FakeApp::answering(
        r#"{"version":1,"ok":false,"error":{"code":"not-found","message":"/gone.md: no such file"}}"#,
    );
    // `tab select` does not pre-check the path locally, so this really is the
    // app's answer producing the exit code.
    let output = app.run(&["tab", "select", "/gone.md"]);
    assert_eq!(code(&output), 2, "{}", stderr(&output));
    assert!(
        stderr(&output).contains("no such file"),
        "{}",
        stderr(&output)
    );
}

#[test]
fn a_version_mismatch_is_a_structured_answer_not_a_parse_failure() {
    let mut app = FakeApp::answering(
        r#"{"version":1,"ok":false,"error":{"code":"unsupported-version","message":"this mark speaks protocol version 1; the request said 99","expected":1,"received":99}}"#,
    );

    let output = Command::new(binary())
        .args(["reload"])
        .env("TMPDIR", &app.tmpdir)
        .env("MARK_NO_LAUNCH", "1")
        .env("MARK_PROTOCOL_VERSION", "99")
        .output()
        .expect("run");
    let request = app.request();

    assert_eq!(request["version"], serde_json::json!(99));
    assert_eq!(code(&output), 5, "{}", stderr(&output));
    assert!(
        stderr(&output).contains("protocol version 1"),
        "{}",
        stderr(&output)
    );
}

#[test]
fn tab_list_json_passes_the_apps_answer_through() {
    let app = FakeApp::answering(
        r#"{"version":1,"ok":true,"result":{"tabs":[{"index":0,"path":"/a.md","title":"a","selected":true,"resident":true,"openTasks":2,"totalTasks":5}]}}"#,
    );
    let output = app.run(&["tab", "list", "--json"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    let parsed: serde_json::Value = serde_json::from_str(&stdout(&output)).expect("json");
    assert_eq!(parsed[0]["path"], serde_json::json!("/a.md"));
    assert_eq!(parsed[0]["openTasks"], serde_json::json!(2));
}

#[test]
fn tab_list_prints_residency_and_the_selection_marker() {
    let app = FakeApp::answering(
        r#"{"version":1,"ok":true,"result":{"tabs":[{"index":0,"path":"/a.md","title":"a","selected":true,"resident":true,"openTasks":2,"totalTasks":5},{"index":1,"path":"/b.md","title":"b","selected":false,"resident":false}]}}"#,
    );
    let output = app.run(&["tab", "list"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    let text = stdout(&output);
    assert!(text.contains("* 0"), "{text}");
    assert!(text.contains("2/5"), "{text}");
    assert!(text.contains("resident"), "{text}");
    assert!(text.contains("dehydrated"), "{text}");
}

#[test]
fn tab_close_with_no_target_names_no_tab() {
    let mut app = FakeApp::answering(
        r#"{"version":1,"ok":true,"result":{"closed":{"index":0,"path":"/a.md","title":"a","selected":true,"resident":true},"tabs":0}}"#,
    );
    let output = app.run(&["tab", "close"]);
    let request = app.request();
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    assert_eq!(request["command"], serde_json::json!("tab-close"));
    assert_eq!(request["arguments"], serde_json::json!({}));
}

#[test]
fn tab_select_by_number_sends_an_index_and_by_name_sends_a_path() {
    let mut app = FakeApp::answering(
        r#"{"version":1,"ok":true,"result":{"tab":{"index":2,"path":"/c.md","title":"c","selected":true,"resident":true}}}"#,
    );
    let output = app.run(&["tab", "select", "2"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    assert_eq!(app.request()["arguments"]["index"], serde_json::json!("2"));

    let mut app = FakeApp::answering(
        r#"{"version":1,"ok":true,"result":{"tab":{"index":2,"path":"/c.md","title":"c","selected":true,"resident":true}}}"#,
    );
    let output = app.run(&["tab", "select", "notes.md"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    let sent = app.request()["arguments"]["path"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(sent.starts_with('/'), "{sent}");
}

/// Applying a theme is the app's business, so it goes over the socket — and
/// the CLI validates the name *first*, so an obvious mistake costs no round
/// trip and comes back with a suggestion.
#[test]
fn theme_applies_over_the_socket() {
    let mut app = FakeApp::answering(
        r#"{"version":1,"ok":true,"result":{"theme":{"name":"dracula","kind":"dark","light":"dracula","dark":"dracula","paired":false,"applied":2,"rerendered":0},"tabs":2}}"#,
    );
    let output = app.run(&["theme", "dracula"]);
    let request = app.request();

    assert_eq!(request["command"], serde_json::json!("theme"));
    assert_eq!(request["arguments"]["name"], serde_json::json!("dracula"));
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    let out = stdout(&output);
    assert!(out.contains("dracula"), "{out}");
    assert!(out.contains("applied to 2 tab(s)"), "{out}");
}

#[test]
fn a_theme_that_does_not_exist_never_reaches_the_app() {
    let app = FakeApp::answering(r#"{"version":1,"ok":true,"result":{}}"#);
    let output = app.run(&["theme", "no-such-theme"]);
    assert_eq!(code(&output), 1, "{}", stderr(&output));
    let message = stderr(&output);
    assert!(
        message.contains("no theme named \"no-such-theme\""),
        "{message}"
    );
    // Resolved locally, so the app was never asked.
    assert!(app.requests.try_recv().is_err(), "the app was asked anyway");
}

#[test]
fn a_nonexistent_file_fails_locally_without_waking_the_app() {
    let app = FakeApp::answering(OPEN_OK);
    let output = app.run(&["open", "/nonexistent-mark-fixture.md"]);

    assert_eq!(code(&output), 2, "{}", stderr(&output));
    assert!(
        stderr(&output).contains("nonexistent-mark-fixture.md"),
        "{}",
        stderr(&output)
    );
    assert!(
        app.saw_no_request(),
        "a typo must not start a GUI or bother a running one"
    );
}

#[test]
fn no_socket_and_no_launch_exits_four_naming_the_path() {
    let directory = scratch();
    let output = Command::new(binary())
        .args(["reload"])
        .env("TMPDIR", directory.path())
        .env("MARK_NO_LAUNCH", "1")
        .output()
        .expect("run");

    assert_eq!(code(&output), 4, "{}", stderr(&output));
    assert!(
        stderr(&output).contains(&format!("mark-{}.sock", uid())),
        "{}",
        stderr(&output)
    );
}

/// ADR-3's 104-byte trap, from the CLI's side: refused before a connection is
/// attempted, with the limit in the message.
#[test]
fn a_tmpdir_that_overflows_sun_path_fails_loudly() {
    let long = format!("/tmp/{}", "d".repeat(120));
    let output = Command::new(binary())
        .args(["reload"])
        .env("TMPDIR", &long)
        .env("MARK_NO_LAUNCH", "1")
        .output()
        .expect("run");

    assert_eq!(code(&output), 4, "{}", stderr(&output));
    let message = stderr(&output);
    assert!(message.contains("104"), "{message}");
    assert!(message.contains("TMPDIR"), "{message}");
}

#[test]
fn doctor_reports_the_socket_path_its_length_and_whether_the_app_answers() {
    let app = FakeApp::answering(OPEN_OK);
    let output = app.run(&["doctor", "--json"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));

    let report: serde_json::Value = serde_json::from_str(&stdout(&output)).expect("json");
    let socket = report["socket_path"].as_str().expect("a socket path");
    assert!(
        socket.ends_with(&format!("mark-{}.sock", uid())),
        "{socket}"
    );
    assert_eq!(report["socket_path_bytes"], serde_json::json!(socket.len()));
    assert_eq!(report["socket_path_limit"], serde_json::json!(103));
    assert_eq!(report["protocol_version"], serde_json::json!(1));
    // The fake app is listening, and `doctor` must find that out by connecting
    // rather than by launching anything.
    assert_eq!(report["app_running"], serde_json::json!(true));
}

#[test]
fn doctor_reports_no_app_when_nothing_is_listening() {
    let directory = scratch();
    let output = Command::new(binary())
        .args(["doctor", "--json"])
        .env("TMPDIR", directory.path())
        .output()
        .expect("run");
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    let report: serde_json::Value = serde_json::from_str(&stdout(&output)).expect("json");
    assert_eq!(report["app_running"], serde_json::json!(false));
    // No `MARK_NO_LAUNCH` above on purpose: `doctor` must never launch the app
    // to answer a question about it.
    assert!(report["socket_error"].is_null());
}

#[test]
fn a_reply_that_is_not_json_is_reported_rather_than_swallowed() {
    let app = FakeApp::answering("this is not JSON");
    let output = app.run(&["reload"]);
    assert_eq!(code(&output), 4, "{}", stderr(&output));
    assert!(stderr(&output).contains("unusable"), "{}", stderr(&output));
}

#[test]
fn a_connection_that_closes_without_answering_is_an_error_not_a_hang() {
    let directory = scratch();
    let socket = directory.path().join(format!("mark-{}.sock", uid()));
    let listener = UnixListener::bind(&socket).expect("bind");
    let handle = thread::spawn(move || {
        if let Ok((stream, _)) = listener.accept() {
            drop(stream);
        }
    });

    let output = Command::new(binary())
        .args(["reload"])
        .env("TMPDIR", directory.path())
        .env("MARK_NO_LAUNCH", "1")
        .output()
        .expect("run");
    let _ = handle.join();

    // **Three** outcomes are legitimate here, and which one happens is a race
    // between our first syscall on the connection and the peer's `close`:
    //
    //   1. the write lands and the read sees EOF — "closed the connection
    //      without answering";
    //   2. the write itself hits `EPIPE`;
    //   3. `set_read_timeout` — the *first* thing `Client::send` does with the
    //      stream — hits `EINVAL`, because on macOS `setsockopt(SO_RCVTIMEO)`
    //      against a UNIX socket whose peer has already closed is refused.
    //
    // (3) was found in M7, not caused by it: a bigger debug binary starts
    // slightly later, the peer's close started winning every time, and a race
    // that had been landing on (1) or (2) started landing on (3). Verified
    // with a standalone twenty-line probe containing none of our code —
    // `set_read_timeout: Err(Os { code: 22 })`, `write: Err(Os { code: 32 })`
    // — so this is a property of the platform, not of the client.
    //
    // What must hold in all three, and is what the test is actually for: this
    // is an error rather than a hang, it exits 4 rather than dying of SIGPIPE,
    // and the message names the socket so the reader knows what failed.
    assert_eq!(code(&output), 4, "{}", stderr(&output));
    let message = stderr(&output);
    assert!(
        message.contains("closed the connection")
            || message.contains("Broken pipe")
            || message.contains("Invalid argument"),
        "{message}"
    );
    assert!(
        message.contains(&format!("mark-{}.sock", uid())),
        "{message}"
    );
}

// ---------------------------------------------------------------------------
// M10: `nav`, `sidebar`, and `open` on a directory
// ---------------------------------------------------------------------------

/// The sidebar shape the app answers `sidebar`, `nav`, and a directory `open`
/// with. One constant, because the CLI prints all three through one function
/// and a test that used three literals could not notice if it stopped.
const SIDEBAR_OK: &str = r#"{"version":1,"ok":true,"result":{"sidebar":{"root":"/notes/project","breadcrumb":["/","notes","project"],"back":["/notes"],"forward":[],"showsNonMarkdown":false,"showsHidden":true,"sort":"modified","filter":"todo"},"tabs":3}}"#;

#[test]
fn sidebar_reports_root_breadcrumb_history_and_options() {
    let mut app = FakeApp::answering(SIDEBAR_OK);
    let output = app.run(&["sidebar"]);
    let request = app.request();

    assert_eq!(code(&output), 0, "{}", stderr(&output));
    assert_eq!(request["command"], serde_json::json!("sidebar"));
    assert_eq!(request["arguments"], serde_json::json!({}));

    let text = stdout(&output);
    assert!(text.contains("/notes/project"), "{text}");
    assert!(text.contains("/ > notes > project"), "{text}");
    assert!(text.contains("1 back, 0 forward"), "{text}");
    assert!(
        text.contains("markdown only, hidden files, by modified"),
        "{text}"
    );
    assert!(text.contains("\"todo\""), "{text}");
}

#[test]
fn sidebar_json_passes_the_apps_answer_through() {
    let app = FakeApp::answering(SIDEBAR_OK);
    let output = app.run(&["sidebar", "--json"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    let parsed: serde_json::Value = serde_json::from_str(&stdout(&output)).expect("json");
    assert_eq!(parsed["root"], serde_json::json!("/notes/project"));
    assert_eq!(parsed["sort"], serde_json::json!("modified"));
}

#[test]
fn nav_to_a_directory_sends_an_absolute_path() {
    let mut app = FakeApp::answering(SIDEBAR_OK);
    let output = app.run(&["nav", "."]);
    let request = app.request();
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    assert_eq!(request["command"], serde_json::json!("nav"));
    let sent = request["arguments"]["path"].as_str().unwrap().to_owned();
    assert!(sent.starts_with('/'), "{sent}");
    assert!(request["arguments"].get("to").is_none(), "{request}");
}

#[test]
fn nav_relative_moves_travel_as_a_to_argument() {
    for (flag, expected) in [
        ("--up", "up"),
        ("--parent", "up"),
        ("--back", "back"),
        ("--forward", "forward"),
    ] {
        let mut app = FakeApp::answering(SIDEBAR_OK);
        let output = app.run(&["nav", flag]);
        let request = app.request();
        assert_eq!(code(&output), 0, "{flag}: {}", stderr(&output));
        assert_eq!(request["arguments"]["to"], serde_json::json!(expected));
        assert!(request["arguments"].get("path").is_none(), "{request}");
    }
}

/// The whole reason `nav` is worth having over the socket: a move the app
/// refuses is a non-zero exit, not a quiet success (ADR-3).
#[test]
fn nav_back_with_no_history_exits_five() {
    let app = FakeApp::answering(
        r#"{"version":1,"ok":false,"error":{"code":"unsupported","message":"there is nothing to go back to"}}"#,
    );
    let output = app.run(&["nav", "--back"]);
    assert_eq!(code(&output), 5, "{}", stderr(&output));
    assert!(
        stderr(&output).contains("nothing to go back to"),
        "{}",
        stderr(&output)
    );
}

/// Neither a path nor a flag never reaches the socket: it is a usage error, and
/// exit 1 rather than 4 tells the caller the app was never the problem.
#[test]
fn nav_with_nothing_to_go_on_is_a_usage_error() {
    let app = FakeApp::answering(SIDEBAR_OK);
    let output = app.run(&["nav"]);
    assert_eq!(code(&output), 1, "{}", stderr(&output));
    assert!(stderr(&output).contains("--up"), "{}", stderr(&output));

    let app = FakeApp::answering(SIDEBAR_OK);
    let output = app.run(&["nav", "/tmp", "--back"]);
    assert_eq!(code(&output), 1, "{}", stderr(&output));
    assert!(stderr(&output).contains("not both"), "{}", stderr(&output));
}

/// M10 made `mark open <dir>` root the sidebar rather than refuse. The CLI
/// prints whichever answer arrived, so a success with no tab in it is no longer
/// the empty line that kept this refused through M8 and M9.
#[test]
fn open_on_a_directory_prints_the_sidebar_it_got_back() {
    let mut app = FakeApp::answering(SIDEBAR_OK);
    let directory = app.tmpdir.join("notes");
    std::fs::create_dir(&directory).expect("mkdir");

    let output = app.run(&["open", directory.to_str().unwrap()]);
    let request = app.request();

    assert_eq!(code(&output), 0, "{}", stderr(&output));
    // Still an `open`: the CLI does not pre-empt the app's decision by sending
    // `nav` itself, because the app is the one that knows what the path is now.
    assert_eq!(request["command"], serde_json::json!("open"));
    let text = stdout(&output);
    assert!(text.contains("/notes/project"), "{text}");
    assert!(
        !text.contains("tab"),
        "printed a tab line for a directory: {text}"
    );
}

#[test]
fn goto_and_reload_and_tab_moves_all_carry_json() {
    let app = FakeApp::answering(
        r#"{"version":1,"ok":true,"result":{"anchor":"install","tab":{"index":0,"path":"/a.md","title":"a","selected":true,"resident":true}}}"#,
    );
    let output = app.run(&["goto", "install", "--json"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    let parsed: serde_json::Value = serde_json::from_str(&stdout(&output)).expect("json");
    assert_eq!(parsed["anchor"], serde_json::json!("install"));

    let app = FakeApp::answering(
        r#"{"version":1,"ok":true,"result":{"blocks":42,"tab":{"index":0,"path":"/a.md","title":"a","selected":true,"resident":true}}}"#,
    );
    let output = app.run(&["reload", "--json"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    let parsed: serde_json::Value = serde_json::from_str(&stdout(&output)).expect("json");
    assert_eq!(parsed["blocks"], serde_json::json!(42));

    let app = FakeApp::answering(
        r#"{"version":1,"ok":true,"result":{"tab":{"index":2,"path":"/c.md","title":"c","selected":true,"resident":true}}}"#,
    );
    let output = app.run(&["tab", "select", "2", "--json"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    let parsed: serde_json::Value = serde_json::from_str(&stdout(&output)).expect("json");
    assert_eq!(parsed["tab"]["index"], serde_json::json!(2));

    let app = FakeApp::answering(
        r#"{"version":1,"ok":true,"result":{"closed":{"index":0,"path":"/a.md","title":"a","selected":true,"resident":true},"tabs":0}}"#,
    );
    let output = app.run(&["tab", "close", "--json"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    let parsed: serde_json::Value = serde_json::from_str(&stdout(&output)).expect("json");
    assert_eq!(parsed["closed"]["path"], serde_json::json!("/a.md"));
    assert_eq!(parsed["tabs"], serde_json::json!(0));
}
