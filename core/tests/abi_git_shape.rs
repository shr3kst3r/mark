//! The exact JSON `mark_git_json` and `mark_diff_json`'s flags put on the wire.
//!
//! Pinned by a test rather than described in a comment, because Swift decodes
//! these with hand-written `CodingKeys` (`core/src/lib.rs` documents the shapes;
//! `app/Sources/Mark/MarkCore.swift` mirrors them). A silent rename on this side
//! is not a compile error over there — it surfaces as "the sidebar stopped
//! badging", which is exactly the class of failure ADR-1's hand-written boundary
//! trades for its small size.
//!
//! This file caught one real mistake already: `Report`'s `#[serde(flatten)]`
//! emitted `root` where the documentation promised `repo`, and dropped the key
//! entirely for a path that was not in a repository.

use std::ffi::{CStr, CString};
use std::fs;
use std::path::Path;
use std::process::Command;

use serde_json::Value;
use tempfile::TempDir;

fn git_json(path: &str, flags: i32) -> Value {
    let c = CString::new(path).expect("no interior NUL");
    let raw = unsafe { mark_core::mark_git_json(c.as_ptr(), flags) };
    assert!(!raw.is_null(), "mark_git_json returned null for {path:?}");
    let text = unsafe { CStr::from_ptr(raw) }
        .to_string_lossy()
        .into_owned();
    unsafe { mark_core::mark_free(raw) };
    serde_json::from_str(&text).expect("valid JSON")
}

fn diff_json(old: &str, new: &str, flags: i32) -> Value {
    let old = CString::new(old).expect("no NUL");
    let new = CString::new(new).expect("no NUL");
    let raw =
        unsafe { mark_core::mark_diff_json(old.as_ptr(), new.as_ptr(), std::ptr::null(), flags) };
    assert!(!raw.is_null(), "mark_diff_json returned null");
    let text = unsafe { CStr::from_ptr(raw) }
        .to_string_lossy()
        .into_owned();
    unsafe { mark_core::mark_free(raw) };
    serde_json::from_str(&text).expect("valid JSON")
}

fn have_git() -> bool {
    mark_core::git::program().is_some()
}

/// A repository with one modified file, one untracked file, and one binary.
fn fixture() -> TempDir {
    let temp = TempDir::new().expect("tempdir");
    let root = temp.path();
    let run = |args: &[&str]| {
        let out = Command::new(mark_core::git::program().expect("git"))
            .args(args)
            .current_dir(root)
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@t")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@t")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null")
            .output()
            .expect("run git");
        assert!(out.status.success(), "git {args:?}");
    };
    run(&["init", "--quiet", "--initial-branch=main"]);
    fs::write(root.join("weekly.md"), "# Weekly\n\nold\n").expect("write");
    fs::write(root.join("logo.bin"), [0xffu8, 0, 0xfe]).expect("write");
    run(&["add", "."]);
    run(&["commit", "--quiet", "-m", "init"]);
    fs::write(root.join("weekly.md"), "# Weekly\n\nnew\nmore\n").expect("write");
    fs::write(root.join("logo.bin"), [0u8, 0xfe, 0xff, 1]).expect("write");
    fs::write(root.join("ideas.md"), "a\nb\nc\n").expect("write");
    temp
}

#[test]
fn a_status_report_carries_repo_then_changes() {
    if !have_git() {
        eprintln!("skipped: no usable git");
        return;
    }
    let temp = fixture();
    let value = git_json(temp.path().to_str().expect("utf8"), 0);

    // The repository is a nested object, not flattened into the top level.
    let repo = value
        .get("repo")
        .expect("a `repo` key")
        .as_object()
        .expect("an object");
    for key in ["root", "gitDir", "indexPath", "headPath", "head", "branch"] {
        assert!(repo.contains_key(key), "repo is missing {key:?}: {repo:?}");
    }
    assert_eq!(repo["branch"], "main");

    // The two paths the sidebar's poll gate stats. They must exist on disk, or
    // the gate is silently dead: a `stat` of a missing path reads as
    // "unchanged".
    for key in ["indexPath", "headPath"] {
        let path = repo[key].as_str().expect("a string");
        assert!(Path::new(path).exists(), "{key} does not exist: {path}");
    }

    let changes = value["changes"].as_array().expect("an array");
    let by_path = |name: &str| {
        changes
            .iter()
            .find(|c| c["path"] == name)
            .unwrap_or_else(|| panic!("no change for {name}: {changes:?}"))
            .clone()
    };

    let weekly = by_path("weekly.md");
    assert_eq!(weekly["status"], "modified");
    assert_eq!(weekly["added"], 2);
    assert_eq!(weekly["removed"], 1);

    // The contract that must never drift: a binary file's counts are `null`.
    // Rendering those as `0` would badge a changed file `+0 −0`.
    let logo = by_path("logo.bin");
    assert_eq!(logo["status"], "modified");
    assert!(logo["added"].is_null(), "a binary file has no added count");
    assert!(logo["removed"].is_null());

    // And an untracked file: `removed` is a known 0, `added` is the caller's to
    // count on its own screen-bounded queue.
    let ideas = by_path("ideas.md");
    assert_eq!(ideas["status"], "untracked");
    assert!(ideas["added"].is_null());
    assert_eq!(ideas["removed"], 0);
}

#[test]
fn a_path_outside_a_repository_is_an_explicit_null_and_not_an_error() {
    let temp = TempDir::new().expect("tempdir");
    let value = git_json(temp.path().to_str().expect("utf8"), 0);
    // An explicit `null`, not a missing key: a consumer must be able to tell
    // "asked, and there is none" from "this build does not report it".
    assert!(
        value.get("repo").is_some_and(Value::is_null),
        "expected an explicit null repo: {value}"
    );
    assert_eq!(value["changes"].as_array().map(Vec::len), Some(0));
}

#[test]
fn untracked_files_can_be_left_out() {
    if !have_git() {
        eprintln!("skipped: no usable git");
        return;
    }
    let temp = fixture();
    let value = git_json(
        temp.path().to_str().expect("utf8"),
        mark_core::MARK_GIT_NO_UNTRACKED,
    );
    let changes = value["changes"].as_array().expect("an array");
    assert!(
        !changes.iter().any(|c| c["status"] == "untracked"),
        "{changes:?}"
    );
    assert!(changes.iter().any(|c| c["path"] == "weekly.md"));
}

#[test]
fn a_base_report_carries_the_committed_bytes() {
    if !have_git() {
        eprintln!("skipped: no usable git");
        return;
    }
    let temp = fixture();
    let path = temp.path().join("weekly.md");
    let value = git_json(path.to_str().expect("utf8"), mark_core::MARK_GIT_BASE);

    assert_eq!(value["tracked"], true);
    assert_eq!(value["base"], "# Weekly\n\nold\n");
    assert!(value["head"].is_string());
}

#[test]
fn a_base_report_for_an_untracked_file_is_null_and_not_an_error() {
    if !have_git() {
        eprintln!("skipped: no usable git");
        return;
    }
    let temp = fixture();
    let path = temp.path().join("ideas.md");
    let value = git_json(path.to_str().expect("utf8"), mark_core::MARK_GIT_BASE);
    assert_eq!(value["tracked"], false);
    assert!(value["base"].is_null());
}

#[test]
fn a_base_report_for_a_binary_blob_is_null() {
    if !have_git() {
        eprintln!("skipped: no usable git");
        return;
    }
    let temp = fixture();
    let path = temp.path().join("logo.bin");
    let value = git_json(path.to_str().expect("utf8"), mark_core::MARK_GIT_BASE);
    assert_eq!(value["tracked"], false, "nothing here we can diff");
    assert!(value["base"].is_null());
}

/// A `MARK_GIT_BASE` call must answer in the **base** shape even when there is
/// no repository, because the caller decodes one type and not two.
///
/// This is a bug this test was written for rather than against: the first
/// version returned the *status* shape here, which has no `tracked` key, so
/// Swift's decode failed and the app reported "nothing here that can be
/// diffed" for a document whose real problem was that it was not in a
/// repository at all. `DiffViewTests` caught it end to end; this pins it at the
/// boundary, where the fix belongs.
#[test]
fn a_base_report_outside_a_repository_keeps_the_base_shape() {
    let temp = TempDir::new().expect("tempdir");
    let path = temp.path().join("loose.md");
    fs::write(&path, "# Loose\n").expect("write");
    let value = git_json(path.to_str().expect("utf8"), mark_core::MARK_GIT_BASE);

    assert!(
        value.get("repo").is_some_and(Value::is_null),
        "expected an explicit null repo: {value}"
    );
    assert_eq!(
        value.get("tracked"),
        Some(&Value::Bool(false)),
        "the `tracked` key must be present even with no repository: {value}"
    );
    assert!(
        value.get("base").is_some_and(Value::is_null),
        "and `base` must be an explicit null: {value}"
    );
    // And emphatically *not* the status shape.
    assert!(
        value.get("changes").is_none(),
        "a base call must not answer with a changes array: {value}"
    );
}

#[test]
fn diff_json_with_no_flags_is_unchanged() {
    // ADR-2's patch path and `core/tests/diff_apply.rs` both consume this, so
    // the zero-flag response must stay exactly what it always was: the edit
    // script's own fields, and nothing else.
    let value = diff_json("# A\n\nold\n", "# A\n\nnew\n", 0);
    let object = value.as_object().expect("an object");
    let mut keys: Vec<&str> = object.keys().map(String::as_str).collect();
    keys.sort_unstable();
    assert_eq!(
        keys,
        [
            "coarse",
            "deleted",
            "inserted",
            "kept",
            "new_blocks",
            "old_blocks",
            "ops",
            "replaced"
        ],
        "the zero-flag response grew or lost a key"
    );
}

#[test]
fn diff_json_lines_flag_adds_the_line_diff() {
    let value = diff_json("a\nb\nc\n", "a\nZ\nc\n", mark_core::MARK_DIFF_LINES);
    // The edit script's own fields survive alongside it.
    assert!(value.get("ops").is_some());
    assert!(value.get("document").is_none(), "not asked for");

    let lines = value.get("lines").expect("a `lines` key");
    assert_eq!(lines["added"], 1);
    assert_eq!(lines["removed"], 1);
    let hunks = lines["hunks"].as_array().expect("an array");
    assert_eq!(hunks.len(), 1);
    assert_eq!(hunks[0]["kind"], "changed");
    // Zero-based, half-open, and camelCase on the wire — all three are what
    // Swift's `CodingKeys` expect.
    assert_eq!(hunks[0]["new"]["start"], 1);
    assert_eq!(hunks[0]["new"]["end"], 2);
    assert!(hunks[0].get("newBytes").is_some(), "{:?}", hunks[0]);
}

#[test]
fn diff_json_document_flag_adds_the_merged_document() {
    let value = diff_json(
        "# A\n\ngone\n\nkept\n",
        "# A\n\nkept\n\nfresh\n",
        mark_core::MARK_DIFF_DOCUMENT,
    );
    let html = value["document"].as_str().expect("a string");
    assert!(html.contains("mk-diff-del"), "{html}");
    assert!(html.contains("data-mk-side=\"old\""), "{html}");
    assert!(
        html.contains("gone"),
        "removed content must be present: {html}"
    );
    assert_eq!(value["diffRemoved"], 1);
    assert_eq!(value["diffAdded"], 1);
    assert!(value.get("lines").is_none(), "not asked for");
}

#[test]
fn both_flags_together_give_both() {
    let value = diff_json(
        "a\n",
        "b\n",
        mark_core::MARK_DIFF_LINES | mark_core::MARK_DIFF_DOCUMENT,
    );
    assert!(value.get("lines").is_some());
    assert!(value.get("document").is_some());
    assert!(value.get("ops").is_some());
}
