//! End-to-end tests for every M1 subcommand, run against the real binary.
//!
//! These assert on stdout, stderr, and exit codes because those are the actual
//! contract with the thing calling `mark` in a loop. A unit test on the same
//! functions would not catch an argument that never reaches the core, or an
//! exit code that says success while stderr says otherwise.

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use tempfile::TempDir;

fn binary() -> &'static str {
    env!("CARGO_BIN_EXE_mark-cli")
}

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("workspace root")
        .join("core/tests/fixtures")
}

fn run(args: &[&str]) -> Output {
    Command::new(binary())
        .args(args)
        .output()
        .expect("the binary was built by cargo test")
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

/// A scratch copy of the tasks fixture, so tests that write cannot disturb the
/// committed one.
fn scratch() -> (TempDir, PathBuf) {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("tasks.md");
    std::fs::copy(fixtures().join("tasks.md"), &path).expect("copy fixture");
    (dir, path)
}

#[test]
fn render_html_is_a_self_contained_document() {
    let file = fixtures().join("mixed.md");
    let output = run(&["render", file.to_str().unwrap(), "--html"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));

    let html = stdout(&output);
    assert!(html.starts_with("<!DOCTYPE html>"), "{html}");
    assert!(html.contains("<title>Mixed constructs</title>"));
    assert!(html.contains("<style>"), "styles must be inline");
    assert!(html.contains("data-blk="), "block ids must be present");
    // ADR-5: no third-party JavaScript ships in rendered output.
    assert!(!html.contains("<script"), "rendered HTML must ship no JS");
    // ADR-5: the mermaid fence is inline SVG and the math is inline MathML,
    // both in the document itself rather than fetched.
    // M7: a diagram is rendered once per appearance, so the wrapper holds two
    // SVGs and `prefers-color-scheme` picks. (The mermaid palette comes from
    // the theme now — a diagram used to be a white box on a dark page.)
    assert!(html.contains("<div class=\"mk-diagram\">"), "{html}");
    assert!(html.contains("class=\"mk-appear-light\"><svg"), "{html}");
    assert!(html.contains("class=\"mk-appear-dark\"><svg"), "{html}");
    assert!(html.contains("<math display=\"inline\""), "{html}");
    assert!(html.contains("<math display=\"block\""), "{html}");
    assert!(!html.contains("data-lang=\"mermaid\""), "{html}");
}

#[test]
fn render_html_of_the_rich_fixture_needs_no_network() {
    // M6's gate: one document holding inline and display math, two diagrams, a
    // rust fence that must not be treated as a diagram, math in a task label, a
    // deliberately broken expression, and a malformed diagram — self-contained,
    // and with no construct silently missing.
    let file = fixtures().join("rich.md");
    let output = run(&["render", file.to_str().unwrap(), "--html"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    let html = stdout(&output);

    assert_eq!(
        html.matches("<math display=\"inline\"").count(),
        4,
        "{html}"
    );
    assert_eq!(html.matches("<math display=\"block\"").count(), 2, "{html}");
    assert_eq!(html.matches("<div class=\"mk-diagram\">").count(), 2);
    // Two diagrams, each in both appearances.
    assert_eq!(html.matches("class=\"mk-appear-light\"><svg").count(), 2);
    assert_eq!(html.matches("class=\"mk-appear-dark\"><svg").count(), 2);

    // The two failures show as badges, not as blank regions. Matched on the
    // whole class attribute, since the stylesheet mentions the names too.
    assert_eq!(
        html.matches("class=\"mk-rich-error mk-math-error\"")
            .count(),
        1,
        "{html}"
    );
    assert_eq!(
        html.matches("class=\"mk-rich-error mk-diagram-error\"")
            .count(),
        1,
        "{html}"
    );
    assert!(html.contains("\\newcommand{\\R}{\\mathbb{R}}"), "{html}");
    assert!(html.contains("A[[[Start"), "{html}");

    // The rust fence, and the mermaid fence that holds prose, are code blocks.
    assert!(html.contains("data-lang=\"rust\""), "{html}");
    assert!(html.contains("data-lang=\"mermaid\""), "{html}");

    // Prose dollars survive.
    assert!(html.contains("That costs $5 and $10 total,"), "{html}");

    // Nothing is fetched: no script, no stylesheet link, no image, no font.
    for forbidden in [
        "<script",
        "<link",
        "<iframe",
        "<image",
        "@import",
        "src=",
        "url(http",
        "xlink:href",
    ] {
        assert!(!html.contains(forbidden), "{forbidden} in rendered HTML");
    }
    // The only absolute URLs left are XML namespaces and the fixture's own
    // links, neither of which the page fetches.
    for reference in html.split("http").skip(1) {
        assert!(
            reference.starts_with("://www.w3.org/"),
            "an external reference survived: http{}",
            &reference[..reference.len().min(60)]
        );
    }
}

#[test]
fn render_plain_has_no_escape_sequences() {
    let file = fixtures().join("mixed.md");
    let output = run(&["render", file.to_str().unwrap(), "--plain"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));

    let text = stdout(&output);
    assert!(!text.contains('\x1b'), "found an escape sequence");
    assert!(text.contains("# Mixed constructs"));
    assert!(text.contains("[ ] a task inside a mixed document"));
}

#[test]
fn render_ansi_emits_escape_sequences() {
    let file = fixtures().join("mixed.md");
    let output = run(&["render", file.to_str().unwrap(), "--ansi"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    assert!(stdout(&output).contains('\x1b'));
}

#[test]
fn render_defaults_to_plain_when_stdout_is_not_a_terminal() {
    // `Command::output()` gives us a pipe, which is the agent-invocation case.
    let file = fixtures().join("mixed.md");
    let output = run(&["render", file.to_str().unwrap()]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    assert!(!stdout(&output).contains('\x1b'));
}

#[test]
fn render_prefix_emits_only_the_first_n_blocks() {
    let file = fixtures().join("mixed.md");
    let output = run(&["render", file.to_str().unwrap(), "--html", "--prefix", "2"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    assert_eq!(stdout(&output).matches("data-blk=").count(), 2);
}

#[test]
fn render_prefix_applies_to_the_terminal_formats_too() {
    // `--prefix` used to be accepted and silently ignored for anything but
    // `--html`, which made ADR-2's first-paint tunable a lie in the two formats
    // an agent actually reads.
    let file = fixtures().join("mixed.md");
    for format in ["--plain", "--ansi"] {
        let all = stdout(&run(&["render", file.to_str().unwrap(), format]));
        let two = stdout(&run(&[
            "render",
            file.to_str().unwrap(),
            format,
            "--prefix",
            "2",
        ]));
        assert!(two.contains("Mixed constructs"), "{format}: {two}");
        assert!(all.contains("Structure"), "{format}: {all}");
        assert!(
            !two.contains("Structure"),
            "{format}: --prefix 2 rendered the whole document:\n{two}"
        );
        assert!(two.len() < all.len(), "{format}");
    }
}

/// `mark render big.md | head` is ordinary use. Rust ignores SIGPIPE, so a bare
/// `print!` turned the closed pipe into a panic and exit 101 — a crash report
/// where there should have been output.
#[test]
fn a_closed_pipe_is_not_a_crash() {
    use std::io::Write as _;
    use std::process::Stdio;

    let dir = TempDir::new().expect("tempdir");
    let path = dir.path().join("big.md");
    let mut big = String::new();
    for n in 0..20_000 {
        big.push_str(&format!("Paragraph number {n} with some words in it.\n\n"));
    }
    std::fs::write(&path, &big).expect("write");

    for format in ["--plain", "--html"] {
        let mut child = Command::new(binary())
            .args(["render", path.to_str().unwrap(), format])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn");

        // Read one small chunk, then close the pipe under the writer.
        {
            let mut out = child.stdout.take().expect("piped stdout");
            let mut buffer = [0u8; 64];
            let _ = std::io::Read::read(&mut out, &mut buffer);
        }

        let output = child.wait_with_output().expect("wait");
        let message = String::from_utf8_lossy(&output.stderr).into_owned();
        assert!(
            !message.contains("panicked"),
            "{format} panicked on a closed pipe:\n{message}"
        );
        assert_eq!(
            output.status.code(),
            Some(0),
            "{format} exited {:?} on a closed pipe: {message}",
            output.status.code()
        );
    }

    // ...and stdout itself being closed outright is equally not a crash.
    let mut child = Command::new(binary())
        .args(["toc", path.to_str().unwrap(), "--json"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn");
    drop(child.stdout.take());
    let output = child.wait_with_output().expect("wait");
    let _ = std::io::stderr().flush();
    assert!(
        !String::from_utf8_lossy(&output.stderr).contains("panicked"),
        "toc panicked on a closed pipe"
    );
}

/// Plan §3 gives exit 2 one meaning: unreadable or missing file. A usage error
/// must not answer with the same number, or a caller cannot tell "you typo'd a
/// flag" from "that file does not exist".
#[test]
fn usage_errors_exit_one_and_leave_two_to_mean_missing_file() {
    for args in [
        vec!["--no-such-flag"],
        vec!["render"],
        vec!["not-a-subcommand"],
        vec!["check", "x.md"],
        vec!["ls", "--depth", "not-a-number"],
    ] {
        let output = run(&args);
        assert_eq!(
            code(&output),
            1,
            "`mark {}`: {}",
            args.join(" "),
            stderr(&output)
        );
    }

    // ...while help and version are successes clap models as errors.
    for args in [vec!["--help"], vec!["--version"], vec!["render", "--help"]] {
        let output = run(&args);
        assert_eq!(code(&output), 0, "`mark {}`", args.join(" "));
        assert!(!stdout(&output).is_empty(), "`mark {}`", args.join(" "));
    }
}

/// A file the user named by hand is theirs to hear about; a file we found by
/// walking a directory is not worth losing the rest of the listing over.
#[test]
fn an_unreadable_named_file_exits_two_but_a_walk_skips_it() {
    let dir = TempDir::new().expect("tempdir");
    let good = dir.path().join("good.md");
    let bad = dir.path().join("bad.md");
    std::fs::write(&good, "# Good\n\n- [ ] visible\n").expect("write");
    // Invalid UTF-8: unreadable for our purposes, and does not need chmod to
    // behave differently when the suite runs as root.
    std::fs::write(&bad, b"# Bad\n\n- [ ] \xff\xfe\n").expect("write");

    for command in [["tasks"], ["grep"]] {
        let named = if command[0] == "grep" {
            run(&["grep", "visible", bad.to_str().unwrap(), "--json"])
        } else {
            run(&["tasks", bad.to_str().unwrap(), "--json"])
        };
        assert_eq!(
            code(&named),
            2,
            "`mark {} <unreadable file>` exited {} with {:?}",
            command[0],
            code(&named),
            stdout(&named)
        );
        assert!(stdout(&named).is_empty());
        assert!(stderr(&named).starts_with("mark: "), "{}", stderr(&named));

        let walked = if command[0] == "grep" {
            run(&["grep", "visible", dir.path().to_str().unwrap(), "--json"])
        } else {
            run(&["tasks", dir.path().to_str().unwrap(), "--json"])
        };
        assert_eq!(code(&walked), 0, "{}", stderr(&walked));
        let parsed: serde_json::Value = serde_json::from_str(&stdout(&walked)).expect("valid json");
        assert_eq!(
            parsed.as_array().expect("array").len(),
            1,
            "the readable file's row is missing: {}",
            stdout(&walked)
        );
    }
}

#[test]
fn a_missing_file_exits_two_and_says_why() {
    let output = run(&["render", "/definitely/not/here.md"]);
    assert_eq!(code(&output), 2);
    assert!(stdout(&output).is_empty());
    let message = stderr(&output);
    assert!(
        message.starts_with("mark: /definitely/not/here.md:"),
        "{message}"
    );
}

#[test]
fn toc_json_carries_anchors_and_offsets() {
    let file = fixtures().join("mixed.md");
    let output = run(&["toc", file.to_str().unwrap(), "--json"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));

    let parsed: serde_json::Value = serde_json::from_str(&stdout(&output)).expect("valid json");
    let headings = parsed.as_array().expect("an array");
    assert_eq!(headings[0]["level"], 1);
    assert_eq!(headings[0]["text"], "Mixed constructs");
    assert_eq!(headings[0]["anchor"], "mixed-constructs");
    assert_eq!(headings[0]["start"], 0);
    assert_eq!(headings[0]["line"], 1);
    assert!(
        headings[1]["block"]
            .as_str()
            .is_some_and(|b| b.contains('-'))
    );
}

#[test]
fn toc_text_indents_by_level() {
    let file = fixtures().join("mixed.md");
    let output = run(&["toc", file.to_str().unwrap()]);
    let text = stdout(&output);
    assert!(
        text.starts_with("Mixed constructs (#mixed-constructs)"),
        "{text}"
    );
    assert!(text.contains("\n  Code (#code)"), "{text}");
}

#[test]
fn tasks_json_reports_four_tasks_for_the_fixture() {
    let file = fixtures().join("tasks.md");
    let output = run(&["tasks", file.to_str().unwrap(), "--json"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));

    let parsed: serde_json::Value = serde_json::from_str(&stdout(&output)).expect("valid json");
    let tasks = parsed.as_array().expect("an array");
    assert_eq!(tasks.len(), 4, "the ordered-list task must be counted");
    assert_eq!(tasks[3]["text"], "an ordered-list task");
    assert_eq!(tasks[0]["checked"], true);
}

#[test]
fn tasks_open_filters_out_checked_boxes() {
    let file = fixtures().join("tasks.md");
    let output = run(&["tasks", file.to_str().unwrap(), "--open", "--json"]);
    let parsed: serde_json::Value = serde_json::from_str(&stdout(&output)).expect("valid json");
    let tasks = parsed.as_array().expect("an array");
    assert_eq!(tasks.len(), 3);
    assert!(tasks.iter().all(|t| t["checked"] == false));
}

#[test]
fn tasks_walks_a_directory() {
    let dir = fixtures();
    let output = run(&["tasks", dir.to_str().unwrap(), "--json"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    let parsed: serde_json::Value = serde_json::from_str(&stdout(&output)).expect("valid json");
    // tasks.md contributes 4, mixed.md 1, frontmatter.md 1, rich.md 2.
    assert_eq!(parsed.as_array().expect("array").len(), 8);
}

#[test]
fn check_toggles_one_byte_and_prints_the_new_state() {
    let (_dir, path) = scratch();
    let before = std::fs::read_to_string(&path).expect("read");

    let output = run(&["check", path.to_str().unwrap(), "--item", "1", "--on"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    assert!(stdout(&output).starts_with("[x] "), "{}", stdout(&output));
    assert!(stdout(&output).contains("first open"));

    let after = std::fs::read_to_string(&path).expect("read");
    assert_eq!(before.len(), after.len());
    assert_eq!(
        before
            .bytes()
            .zip(after.bytes())
            .filter(|(a, b)| a != b)
            .count(),
        1
    );
}

#[test]
fn check_round_trips() {
    let (_dir, path) = scratch();
    let before = std::fs::read_to_string(&path).expect("read");

    for _ in 0..2 {
        let output = run(&["check", path.to_str().unwrap(), "--item", "2", "--toggle"]);
        assert_eq!(code(&output), 0, "{}", stderr(&output));
    }

    assert_eq!(std::fs::read_to_string(&path).expect("read"), before);
}

#[test]
fn check_defaults_to_toggle() {
    let (_dir, path) = scratch();
    let output = run(&["check", path.to_str().unwrap(), "--item", "0"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    // Task 0 starts checked, so a bare toggle clears it.
    assert!(stdout(&output).starts_with("[ ] "), "{}", stdout(&output));
}

#[test]
fn check_out_of_range_exits_three_and_writes_nothing() {
    let (_dir, path) = scratch();
    let before = std::fs::read_to_string(&path).expect("read");

    let output = run(&["check", path.to_str().unwrap(), "--item", "99", "--on"]);
    assert_eq!(code(&output), 3);
    assert!(stdout(&output).is_empty());
    assert_eq!(
        stderr(&output).trim(),
        "mark: no task 99: the document has 4 (0..3)"
    );
    assert_eq!(std::fs::read_to_string(&path).expect("read"), before);
}

/// M10's `--json` sweep. The point of the flag here is a loop: an agent
/// toggles a box and needs the new state and the byte it changed without
/// parsing `[x] path:1  text`.
#[test]
fn check_json_reports_the_new_state_and_the_byte_that_moved() {
    let (_dir, path) = scratch();
    let before = std::fs::read_to_string(&path).expect("read");

    let output = run(&[
        "check",
        path.to_str().unwrap(),
        "--item",
        "1",
        "--on",
        "--json",
    ]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    let parsed: serde_json::Value = serde_json::from_str(&stdout(&output)).expect("valid json");
    assert_eq!(parsed["index"], serde_json::json!(1));
    assert_eq!(parsed["checked"], serde_json::json!(true));
    assert_eq!(parsed["path"], serde_json::json!(path.to_str().unwrap()));
    assert_eq!(parsed["text"], serde_json::json!("first open"));

    // The offset is the one byte that changed, so it is checkable against the
    // file rather than merely present.
    let after = std::fs::read_to_string(&path).expect("read");
    let offset = parsed["offset"].as_u64().expect("an offset") as usize;
    assert_eq!(after.as_bytes()[offset], b'x');
    assert_eq!(before.as_bytes()[offset], b' ');

    // No document in the answer: `--json` in a loop must not echo the file back.
    assert!(parsed.get("source").is_none(), "{parsed}");
}

#[test]
fn check_on_a_missing_file_exits_two() {
    let output = run(&["check", "/definitely/not/here.md", "--item", "0"]);
    assert_eq!(code(&output), 2);
}

#[test]
fn ls_reports_titles_and_task_counts() {
    let dir = fixtures();
    let output = run(&["ls", dir.to_str().unwrap(), "--json"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));

    let parsed: serde_json::Value = serde_json::from_str(&stdout(&output)).expect("valid json");
    let rows = parsed.as_array().expect("an array");
    let tasks_row = rows
        .iter()
        .find(|r| r["name"] == "tasks.md")
        .expect("tasks.md is listed");
    assert_eq!(tasks_row["title"], "Tasks fixture");
    assert_eq!(tasks_row["open"], 3);
    assert_eq!(tasks_row["total"], 4);
}

#[test]
fn ls_text_shows_counts_in_brackets() {
    let dir = fixtures();
    let output = run(&["ls", dir.to_str().unwrap()]);
    let text = stdout(&output);
    assert!(text.contains("tasks.md  Tasks fixture  [3/4]"), "{text}");
}

#[test]
fn ls_depth_bounds_the_listing() {
    let dir = TempDir::new().expect("tempdir");
    std::fs::create_dir_all(dir.path().join("a/b")).expect("dirs");
    std::fs::write(dir.path().join("top.md"), "# Top\n").expect("write");
    std::fs::write(dir.path().join("a/mid.md"), "# Mid\n").expect("write");
    std::fs::write(dir.path().join("a/b/deep.md"), "# Deep\n").expect("write");

    let shallow = stdout(&run(&["ls", dir.path().to_str().unwrap()]));
    assert!(shallow.contains("top.md"));
    assert!(!shallow.contains("mid.md"));

    let deeper = stdout(&run(&["ls", dir.path().to_str().unwrap(), "--depth", "2"]));
    assert!(deeper.contains("mid.md"));
    assert!(!deeper.contains("deep.md"));
}

#[test]
fn ls_on_a_missing_directory_exits_two() {
    let output = run(&["ls", "/definitely/not/here"]);
    assert_eq!(code(&output), 2);
}

#[test]
fn grep_reports_the_heading_a_match_sits_under() {
    let dir = fixtures();
    let output = run(&["grep", "blockquote", dir.to_str().unwrap(), "--json"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));

    let parsed: serde_json::Value = serde_json::from_str(&stdout(&output)).expect("valid json");
    let matches = parsed.as_array().expect("an array");
    assert_eq!(matches.len(), 1, "{}", stdout(&output));
    assert_eq!(matches[0]["heading"], "Mixed constructs > Structure");
    assert_eq!(matches[0]["anchor"], "structure");
    assert!(matches[0]["text"].as_str().unwrap().contains("blockquote"));
}

#[test]
fn grep_is_a_regex_and_honours_ignore_case() {
    let dir = fixtures();
    let sensitive = run(&["grep", "^## Code$", dir.to_str().unwrap(), "--json"]);
    let parsed: serde_json::Value = serde_json::from_str(&stdout(&sensitive)).expect("json");
    assert_eq!(parsed.as_array().expect("array").len(), 1);

    let insensitive = run(&[
        "grep",
        "TASKS FIXTURE",
        dir.to_str().unwrap(),
        "-i",
        "--json",
    ]);
    let parsed: serde_json::Value = serde_json::from_str(&stdout(&insensitive)).expect("json");
    assert_eq!(parsed.as_array().expect("array").len(), 1);
}

#[test]
fn grep_rejects_a_bad_pattern_with_exit_one() {
    let output = run(&["grep", "(unclosed", "."]);
    assert_eq!(code(&output), 1);
    assert!(
        stderr(&output).starts_with("mark: bad pattern:"),
        "{}",
        stderr(&output)
    );
}

#[test]
fn stats_reports_the_adr_two_pipeline() {
    let file = fixtures().join("mixed.md");
    let output = run(&["stats", file.to_str().unwrap(), "--json"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));

    let parsed: serde_json::Value = serde_json::from_str(&stdout(&output)).expect("valid json");
    assert!(parsed["blocks"].as_u64().unwrap() > 5);
    assert!(parsed["code_blocks"].as_u64().unwrap() >= 3);
    assert!(parsed["parse_ms"].as_f64().is_some());
    // The memoization claim, on a real document: the warm pass must be cheaper.
    let cold = parsed["highlight_cold_ms"].as_f64().unwrap();
    let cached = parsed["highlight_cached_ms"].as_f64().unwrap();
    assert!(
        cached <= cold,
        "cached {cached} ms was not cheaper than cold {cold} ms"
    );
    assert_eq!(parsed["tasks"]["total"], 1);
}

#[test]
fn stats_counts_math_and_diagrams_separately_from_code() {
    // Plan §4 wants a production incident reconstructable from telemetry. For
    // ADR-5 that means "how many constructs did this document have, and how
    // many of them did we fail to render" is answerable without reading the
    // page — and that a diagram is not silently filed under code blocks.
    let file = fixtures().join("rich.md");
    let output = run(&["stats", file.to_str().unwrap(), "--json"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));

    let parsed: serde_json::Value = serde_json::from_str(&stdout(&output)).expect("valid json");
    assert_eq!(parsed["math"], 7);
    assert_eq!(parsed["diagrams"], 3);
    assert_eq!(parsed["rich_failures"], 2);
    // The rust fence and the mermaid fence holding prose; the two rendered
    // diagrams are not counted here.
    assert_eq!(parsed["code_blocks"], 2);

    // The memoization claim, on the rich path: the warm pass must be cheaper.
    let cold = parsed["rich_cold_ms"].as_f64().expect("rich_cold_ms");
    let cached = parsed["rich_cached_ms"].as_f64().expect("rich_cached_ms");
    assert!(cold > 0.0, "the rich renderers did no work");
    assert!(
        cached <= cold,
        "cached {cached} ms was not cheaper than cold {cold} ms"
    );
    assert!(parsed["rich_cache"]["entries"].as_u64().unwrap() >= 10);
}

#[test]
fn doctor_reports_the_toolchain_state() {
    let output = run(&["doctor", "--json"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));

    let parsed: serde_json::Value = serde_json::from_str(&stdout(&output)).expect("valid json");
    assert_eq!(parsed["core_version"], env!("CARGO_PKG_VERSION"));
    // The provenance `core/build.rs` stamps in. Asserted as "present and not
    // empty" rather than against a literal, because the whole point is that it
    // changes with every commit — but a blank here would be the reporting
    // silently losing the only field that identifies a `--HEAD` install.
    for key in ["build_commit", "build_date"] {
        let value = parsed[key]
            .as_str()
            .unwrap_or_else(|| panic!("{key} is missing: {parsed}"));
        assert!(!value.is_empty(), "{key} is empty");
    }
    assert!(parsed["syntect_asset_load_ms"].as_f64().unwrap() >= 0.0);
    assert_eq!(parsed["theme"], "default-dark");
    assert!(parsed["themes"].as_u64().unwrap() >= 16, "{parsed}");
    // M4: the socket path and its length are the first thing a bug report
    // needs, because ADR-3's 104-byte limit is invisible until it bites.
    let socket = parsed["socket_path"].as_str().expect("a socket path");
    assert!(socket.ends_with(".sock"), "{socket}");
    assert_eq!(parsed["socket_path_bytes"], socket.len());
    assert_eq!(parsed["socket_path_limit"], 103);
    assert_eq!(parsed["protocol_version"], 1);
    assert!(parsed["app_running"].is_boolean());
    // M7: where a user's own themes go, so "why is my theme not showing up"
    // has an answer in the first thing a bug report includes.
    let dir = parsed["theme_dir"].as_str().expect("a theme dir");
    assert!(dir.ends_with("/mark/themes"), "{dir}");
}

#[test]
fn mark_trace_writes_timings_to_stderr_only() {
    let file = fixtures().join("mixed.md");
    let output = Command::new(binary())
        .args(["render", file.to_str().unwrap(), "--html"])
        .env("MARK_TRACE", "1")
        .output()
        .expect("run");

    assert_eq!(code(&output), 0);
    assert!(
        stderr(&output).contains("mark[trace]"),
        "{}",
        stderr(&output)
    );
    assert!(
        !stdout(&output).contains("mark[trace]"),
        "trace leaked into stdout"
    );
}

/// Regression: frontmatter used to render as an H2 whose text was the first
/// metadata line, in every output format at once.
#[test]
fn frontmatter_reaches_neither_the_body_nor_the_toc() {
    let file = fixtures().join("frontmatter.md");
    let path = file.to_str().unwrap();

    for format in ["--plain", "--ansi", "--html"] {
        let output = run(&["render", path, format]);
        assert_eq!(code(&output), 0, "{}", stderr(&output));
        let text = stdout(&output);
        for leaked in ["status:", "tags:", "2026-08-24-a-fixture"] {
            assert!(
                !text.contains(leaked),
                "{leaked:?} leaked into {format}:\n{text}"
            );
        }
    }

    let output = run(&["toc", path, "--json"]);
    let parsed: serde_json::Value = serde_json::from_str(&stdout(&output)).expect("valid json");
    let headings = parsed.as_array().expect("an array");
    assert_eq!(headings.len(), 1, "{}", stdout(&output));
    assert_eq!(headings[0]["text"], "Body Heading");

    // ...and the `title:` key is what `mark ls` reports.
    let output = run(&["ls", fixtures().to_str().unwrap(), "--json"]);
    let parsed: serde_json::Value = serde_json::from_str(&stdout(&output)).expect("valid json");
    let row = parsed
        .as_array()
        .expect("an array")
        .iter()
        .find(|r| r["name"] == "frontmatter.md")
        .expect("the fixture is listed");
    assert_eq!(row["title"], "Frontmatter Title");
}

/// Regression: at an 80-column terminal a wide table produced an 810-character
/// line, because the `───┼───` rule was emitted at full content width.
#[test]
fn wide_tables_are_wrapped_to_the_terminal_width() {
    // Every ADR in the corpus has tables; this one had the worst offender.
    let file = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("workspace root")
        .join("docs/adrs/2026-08-24-cli-app-unix-socket-ipc.md");

    for width in ["40", "80", "120"] {
        for format in ["--plain", "--ansi"] {
            let output = Command::new(binary())
                .args(["render", file.to_str().unwrap(), format])
                .env("COLUMNS", width)
                .output()
                .expect("run");
            assert_eq!(code(&output), 0, "{}", stderr(&output));

            let limit: usize = width.parse().unwrap();
            let text = stdout(&output);

            // Table lines only. Prose is deliberately left to the terminal's
            // own soft wrap (see the module docs on `cli/src/ansi.rs`); a table
            // is the thing that cannot soft-wrap without destroying the
            // alignment of every row after it.
            let widest = text
                .lines()
                .map(strip_escapes)
                .filter(|line| line.contains('│') || line.contains('┼'))
                .map(|line| line.chars().count())
                .max()
                .expect("this ADR has tables");
            assert!(
                widest <= limit,
                "{format} at COLUMNS={width}: longest table line is {widest} chars"
            );
        }
    }
}

/// Strip SGR sequences so a line's printed width can be measured.
fn strip_escapes(text: &str) -> String {
    let mut out = String::new();
    let mut chars = text.chars();
    while let Some(ch) = chars.next() {
        if ch != '\x1b' {
            out.push(ch);
            continue;
        }
        for ch in chars.by_ref() {
            if ch.is_ascii_alphabetic() {
                break;
            }
        }
    }
    out
}

#[test]
fn the_m4_subcommands_exist_and_are_documented() {
    // M4 landed these; before it, this test asserted the opposite. What it
    // guards now is that the socket surface is reachable and self-describing —
    // `--help` never touches the socket, so this cannot launch a GUI from
    // `cargo test`. Their behaviour is in `tests/ipc.rs`, against a fake app.
    for command in ["open", "tab", "theme", "goto", "reload"] {
        let output = run(&[command, "--help"]);
        assert_eq!(
            code(&output),
            0,
            "`mark {command} --help`: {}",
            stderr(&output)
        );
        assert!(
            !stdout(&output).is_empty(),
            "`mark {command}` has no help text"
        );
    }
}

/// `mark theme` splits along one line: questions about **files** are answered
/// here, and only *applying* a theme needs the app.
///
/// That split is the reason `--list` and `--show` are worth having for an agent
/// at all — it usually has no GUI running — so it is asserted rather than
/// assumed, with no socket anywhere in reach.
#[test]
fn the_local_half_of_theme_needs_no_app() {
    let windowless = |args: &[&str]| {
        Command::new(binary())
            .args(args)
            .env("MARK_NO_LAUNCH", "1")
            // A directory with no socket in it — and none that needs creating,
            // since the connect fails at ENOENT either way.
            .env(
                "TMPDIR",
                format!("/tmp/mark-no-socket-{}", std::process::id()),
            )
            .output()
            .expect("run")
    };

    let listed = windowless(&["theme", "--list", "--json"]);
    assert_eq!(code(&listed), 0, "{}", stderr(&listed));
    let parsed: serde_json::Value = serde_json::from_str(&stdout(&listed)).expect("valid json");
    let themes = parsed["themes"].as_array().expect("a themes array");
    assert!(themes.len() >= 16, "only {} themes", themes.len());
    assert_eq!(parsed["default"], "default-dark");
    assert!(parsed["problems"].as_array().is_some_and(Vec::is_empty));

    let shown = windowless(&["theme", "--show", "gruvbox-dark", "--json"]);
    assert_eq!(code(&shown), 0, "{}", stderr(&shown));
    let parsed: serde_json::Value = serde_json::from_str(&stdout(&shown)).expect("valid json");
    assert_eq!(parsed["light"], "gruvbox-light");
    assert_eq!(parsed["dark"], "gruvbox-dark");
    assert!(parsed["palette"]["base00"].as_str().is_some());
    // Both appearances in one string, which is the whole light/dark mechanism.
    let css = parsed["css"].as_str().expect("css");
    assert!(css.contains("@media (prefers-color-scheme: dark)"), "{css}");

    // Applying one, though, is the app's state to change — and with no app
    // there is nothing to change, so it fails rather than quietly succeeding.
    let applied = windowless(&["theme", "dracula"]);
    assert_ne!(
        code(&applied),
        0,
        "`mark theme <name>` succeeded with no app"
    );
}

/// A theme name is resolved before the socket is touched, so a typo comes back
/// with a suggestion rather than as a transport failure.
#[test]
fn a_bad_theme_name_is_a_local_error_with_a_suggestion() {
    let output = Command::new(binary())
        .args(["theme", "dracola"])
        .env("MARK_NO_LAUNCH", "1")
        .env(
            "TMPDIR",
            format!("/tmp/mark-no-socket-{}", std::process::id()),
        )
        .output()
        .expect("run");
    assert_eq!(code(&output), 1, "{}", stderr(&output));
    let message = stderr(&output);
    assert!(message.contains("no theme named"), "{message}");
    assert!(message.contains("dracula"), "{message}");
}
