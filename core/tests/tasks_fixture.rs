//! Golden byte ranges, and the two regressions this project has already hit.
//!
//! The fixture is the shape research 2.4 verified against: a `[x]`, two `[ ]`,
//! an ordered-list task, and a literal `[ ]` in prose. Expected counts are
//! `open = 3, total = 4`.

use std::fs;
use std::path::{Path, PathBuf};

use mark_core::render::{RenderOptions, render};
use mark_core::tasks::{self, Action};

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

fn tasks_md() -> String {
    fs::read_to_string(fixture("tasks.md")).expect("fixture is committed")
}

/// Snapshot of every task's `(index, start, end, checked)`. These are literal
/// numbers on purpose: an accidental change to how spans are computed shows up
/// here as a diff rather than as a mis-toggled file six months from now.
#[test]
fn task_byte_ranges_are_golden() {
    let source = tasks_md();
    let tasks = tasks::enumerate_source(&source);

    let actual: Vec<(usize, usize, usize, bool)> = tasks
        .iter()
        .map(|t| (t.index, t.start, t.end, t.checked))
        .collect();

    assert_eq!(
        actual,
        vec![
            (0, 160, 163, true),
            (1, 179, 182, false),
            (2, 196, 199, false),
            (3, 291, 294, false),
        ]
    );

    // Each recorded span really is a marker, not an offset that happens to
    // land nearby.
    for task in &tasks {
        let marker = &source[task.start..task.end];
        assert!(
            matches!(marker, "[ ]" | "[x]" | "[X]"),
            "task {} span holds {marker:?}",
            task.index
        );
    }
}

/// The regression from research 2.4: a literal `[ ]` in a paragraph is neither
/// counted nor written.
#[test]
fn a_prose_bracket_is_never_counted() {
    let source = tasks_md();
    assert!(source.contains("A literal [ ] in prose"));

    let counts = tasks::counts(&source);
    assert_eq!((counts.open, counts.total), (3, 4));

    let prose = source.find("A literal [ ]").unwrap() + "A literal ".len();
    for task in tasks::enumerate_source(&source) {
        assert_ne!(task.start, prose, "the prose bracket was enumerated");
    }
}

/// ...and toggling every real task leaves the prose bracket byte-identical.
#[test]
fn a_prose_bracket_is_never_written() {
    let source = tasks_md();
    let prose = source.find("A literal [ ]").unwrap() + "A literal ".len();

    let mut current = source.clone();
    for index in 0..tasks::enumerate_source(&source).len() {
        current = tasks::toggle(&current, index, Action::Toggle)
            .expect("index from the same document")
            .source;
        assert_eq!(
            &current[prose..prose + 3],
            "[ ]",
            "toggling task {index} disturbed the prose bracket"
        );
    }
}

/// The other regression: `1. [ ]` counts. This fixture reports total = 4, not
/// 3, and the ordered task is last in document order.
#[test]
fn ordered_list_tasks_are_counted() {
    let source = tasks_md();
    let tasks = tasks::enumerate_source(&source);

    assert_eq!(tasks.len(), 4);
    assert_eq!(tasks[3].text, "an ordered-list task");
    assert_eq!(&source[tasks[3].start..tasks[3].end], "[ ]");

    // The line really is an ordered-list item, not a bullet.
    let line_start = source[..tasks[3].start].rfind('\n').unwrap() + 1;
    assert!(
        source[line_start..].starts_with("1. "),
        "expected an ordered marker, got {:?}",
        &source[line_start..line_start + 8]
    );
}

/// A fenced `- [ ]` is code, not a task.
#[test]
fn a_task_inside_inline_code_is_not_a_task() {
    let counts = tasks::counts("`- [ ] not a task`\n\n- [ ] a task\n");
    assert_eq!((counts.open, counts.total), (1, 1));

    let counts = tasks::counts("```\n- [ ] not a task\n```\n");
    assert_eq!((counts.open, counts.total), (0, 0));
}

/// The rendered HTML carries exactly the indices the enumeration reports —
/// ADR-1's `(file, task-index)` identity must agree across both surfaces.
#[test]
fn rendered_indices_match_enumerated_indices() {
    let source = tasks_md();
    let doc = mark_core::parse::Document::parse(&source);
    let html = render(&doc, &RenderOptions::default()).html;

    for task in tasks::enumerate_source(&source) {
        let expected = format!(
            "<input type=\"checkbox\" class=\"mk-task\" data-mk-idx=\"{}\" \
             data-mk-start=\"{}\" data-mk-end=\"{}\"{}>",
            task.index,
            task.start,
            task.end,
            if task.checked { " checked" } else { "" }
        );
        assert!(html.contains(&expected), "missing {expected} in\n{html}");
    }
    assert_eq!(html.matches("class=\"mk-task\"").count(), 4);
}

/// The write path goes through a temp file and a rename, and leaves no debris.
#[test]
fn toggle_file_writes_in_place_and_cleans_up() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("notes.md");
    let original = tasks_md();
    fs::write(&path, &original).expect("write fixture");

    let toggled = tasks::toggle_file(&path, 1, Action::On).expect("task 1 exists");
    assert!(toggled.checked);

    let after = fs::read_to_string(&path).expect("read back");
    assert_eq!(after.len(), original.len());
    assert_eq!(&after[179..182], "[x]");

    // Exactly one byte differs from the original.
    let differing = original
        .bytes()
        .zip(after.bytes())
        .filter(|(a, b)| a != b)
        .count();
    assert_eq!(differing, 1);

    // No temp file left behind.
    let leftovers: Vec<_> = fs::read_dir(dir.path())
        .expect("list tempdir")
        .filter_map(Result::ok)
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|name| name != "notes.md")
        .collect();
    assert!(leftovers.is_empty(), "left behind {leftovers:?}");
}

/// Toggling through a symlink writes the real document and keeps the link.
///
/// The regression: `rename(2)` replaces a *name*, so renaming the temp file
/// onto the link path deleted the symlink, left a regular file in its place,
/// and left the document the link pointed at holding the old bytes. Silent, and
/// on the one path in the product that writes to a user's file.
#[cfg(unix)]
#[test]
fn toggling_through_a_symlink_writes_the_real_file() {
    let dir = tempfile::tempdir().expect("tempdir");
    let real = dir.path().join("real.md");
    let link = dir.path().join("link.md");
    let original = tasks_md();
    fs::write(&real, &original).expect("write fixture");
    std::os::unix::fs::symlink(&real, &link).expect("symlink");

    let toggled = tasks::toggle_file(&link, 1, Action::On).expect("task 1 exists");
    assert!(toggled.checked);

    // The link is still a link...
    assert!(
        fs::symlink_metadata(&link)
            .expect("link still exists")
            .file_type()
            .is_symlink(),
        "the symlink was replaced by a regular file"
    );
    // ...and the bytes landed in the file it points at.
    let after = fs::read_to_string(&real).expect("read the real file");
    assert_eq!(&after[179..182], "[x]");
    assert_eq!(after.len(), original.len());

    // No temp debris beside either name.
    let leftovers: Vec<_> = fs::read_dir(dir.path())
        .expect("list tempdir")
        .filter_map(Result::ok)
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|name| name != "real.md" && name != "link.md")
        .collect();
    assert!(leftovers.is_empty(), "left behind {leftovers:?}");
}

/// Permissions survive the temp-file-plus-rename: a `rename` would otherwise
/// reset the mode to the process umask.
#[cfg(unix)]
#[test]
fn toggling_preserves_the_files_mode() {
    use std::os::unix::fs::PermissionsExt;

    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("notes.md");
    fs::write(&path, tasks_md()).expect("write fixture");
    fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).expect("chmod");

    tasks::toggle_file(&path, 1, Action::On).expect("task 1 exists");

    let mode = fs::metadata(&path).expect("stat").permissions().mode() & 0o777;
    assert_eq!(mode, 0o640, "mode became {mode:o}");
}

/// A refused toggle does not touch the file at all.
#[test]
fn a_refused_toggle_leaves_the_file_untouched() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("notes.md");
    let original = tasks_md();
    fs::write(&path, &original).expect("write fixture");

    let error = tasks::toggle_file(&path, 99, Action::On).expect_err("no task 99");
    assert!(matches!(
        error,
        tasks::TaskError::IndexOutOfRange {
            index: 99,
            total: 4
        }
    ));
    assert_eq!(fs::read_to_string(&path).expect("read back"), original);
}
