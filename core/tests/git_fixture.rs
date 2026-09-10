//! `git.rs` against real repositories, built at test time.
//!
//! Every assertion here runs the actual `git` binary, because the whole point
//! of `2026-08-28-git-differences-by-running-git` is that git is the reference
//! implementation and we do not reimplement its judgment. A mock would only
//! prove that the parser agrees with the parser.
//!
//! The fixtures are built rather than committed, for the reason
//! `tree_lazy.rs` gives about `.gitignore`: a nested repository inside this
//! repository's tree would confuse both git and the sidebar.
//!
//! **Every test skips rather than fails when there is no usable git.** A
//! machine without Command Line Tools is a supported configuration — the ADR's
//! degradation policy is that the feature is simply invisible there — so a red
//! test would be asserting the opposite of the decision.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Mutex, MutexGuard};

use mark_core::git::{self, Query, Status};
use tempfile::TempDir;

/// Is there a git we can test against? Mirrors what `git::program` decides.
fn have_git() -> bool {
    git::program().is_some()
}

/// `git::invocations()` is a process-wide counter and these tests share a
/// process, so every one of them holds this while it runs. `tree_lazy.rs` takes
/// the same measure around `dir_reads` for the same reason: a concurrent test
/// merely running git would otherwise inflate another's measured delta.
static SERIAL: Mutex<()> = Mutex::new(());

fn serialized() -> MutexGuard<'static, ()> {
    SERIAL
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

macro_rules! needs_git {
    () => {
        if !have_git() {
            eprintln!("skipped: no usable git on this machine");
            return;
        }
        let _serial = serialized();
    };
}

/// Run git in `dir`, panicking on failure — this is fixture *setup*, where a
/// failure is a broken test rather than a condition to degrade around.
fn git_in(dir: &Path, args: &[&str]) -> String {
    let out = Command::new(git::program().expect("git"))
        .args(args)
        .current_dir(dir)
        // A committer identity and a fixed branch name, so the fixtures do not
        // depend on the developer's global config or on git's default-branch
        // setting changing under us.
        .env("GIT_AUTHOR_NAME", "mark tests")
        .env("GIT_AUTHOR_EMAIL", "tests@mark.invalid")
        .env("GIT_COMMITTER_NAME", "mark tests")
        .env("GIT_COMMITTER_EMAIL", "tests@mark.invalid")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .output()
        .expect("run git");
    assert!(
        out.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

fn write(path: &PathBuf, contents: &str) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("mkdir");
    }
    fs::write(path, contents).expect("write");
}

/// A repository with one commit:
///
/// ```text
/// keep.md      "a\nb\nc\nd\n"     untouched
/// edit.md      "1\n2\n3\n"        one line changed, one added
/// gone.md      "bye\n"            deleted
/// moved.md     "move\nme\n"       renamed to renamed.md
/// logo.bin     binary             modified
/// ```
/// plus, uncommitted: `fresh.md` (untracked, 2 lines) and `scratch/` (an
/// untracked directory).
fn fixture() -> TempDir {
    let temp = TempDir::new().expect("tempdir");
    let root = temp.path().to_path_buf();
    git_in(&root, &["init", "--quiet", "--initial-branch=main"]);

    write(&root.join("keep.md"), "a\nb\nc\nd\n");
    write(&root.join("edit.md"), "1\n2\n3\n");
    write(&root.join("gone.md"), "bye\n");
    write(&root.join("moved.md"), "move\nme\n");
    fs::write(root.join("logo.bin"), [0xffu8, 0xfe, 0, 1, 0x80, 0]).expect("binary");
    git_in(&root, &["add", "."]);
    git_in(&root, &["commit", "--quiet", "-m", "init"]);

    // Now dirty it.
    write(&root.join("edit.md"), "1\nTWO\n3\nfour\n");
    fs::remove_file(root.join("gone.md")).expect("rm");
    git_in(&root, &["mv", "moved.md", "renamed.md"]);
    fs::write(root.join("logo.bin"), [0u8, 0xff, 0xff, 9]).expect("binary");
    write(&root.join("fresh.md"), "brand\nnew\n");
    write(&root.join("scratch/inner.md"), "deep\n");

    temp
}

fn changes_of(root: &Path) -> Vec<mark_core::git::Change> {
    let repo = git::discover(root).expect("a repository");
    git::changes(&repo, &Query::default()).expect("changes")
}

fn find<'a>(
    changes: &'a [mark_core::git::Change],
    name: &str,
) -> Option<&'a mark_core::git::Change> {
    changes.iter().find(|c| c.path == Path::new(name))
}

#[test]
fn discover_finds_the_root_the_head_and_the_gate_paths() {
    needs_git!();
    let temp = fixture();
    let repo = git::discover(temp.path()).expect("a repository");

    // `canonicalize`, because `$TMPDIR` on macOS is a symlink into `/private`
    // and git reports the resolved spelling.
    assert_eq!(
        fs::canonicalize(&repo.root).expect("canon"),
        fs::canonicalize(temp.path()).expect("canon")
    );
    assert_eq!(repo.branch.as_deref(), Some("main"));
    assert_eq!(
        repo.head.as_deref().map(str::len),
        Some(7),
        "a short oid, as `--short=7` asks for"
    );
    assert!(
        repo.index_path.exists(),
        "the gate has to be able to stat the index: {:?}",
        repo.index_path
    );
    assert!(repo.head_path.exists(), "and HEAD: {:?}", repo.head_path);
}

#[test]
fn discover_from_a_file_and_from_a_subdirectory_reach_the_same_repository() {
    needs_git!();
    let temp = fixture();
    let from_root = git::discover(temp.path()).expect("root");
    let from_file = git::discover(&temp.path().join("keep.md")).expect("file");
    let from_deep = git::discover(&temp.path().join("scratch")).expect("subdir");

    assert_eq!(from_root.root, from_file.root);
    assert_eq!(from_root.root, from_deep.root);
    // The trap this guards: `--git-path` answers relative to the cwd, so a
    // subdirectory gets `../../.git/index` and it has to be resolved against
    // that cwd rather than against the repository root.
    assert!(
        from_deep.index_path.exists(),
        "index path from a subdirectory does not exist: {:?}",
        from_deep.index_path
    );
    assert!(from_file.index_path.exists());
}

#[test]
fn a_path_outside_any_repository_is_none_and_not_an_error() {
    needs_git!();
    let temp = TempDir::new().expect("tempdir");
    assert!(
        git::discover(temp.path()).is_none(),
        "a bare directory is not a repository"
    );
}

#[test]
fn a_missing_path_does_not_panic() {
    needs_git!();
    let temp = fixture();
    // A document the reader deleted from under us: the parent still resolves.
    let repo = git::discover(&temp.path().join("never-existed.md"));
    assert!(repo.is_some(), "the parent directory is still a repository");
    assert!(git::discover(Path::new("/definitely/not/here/x.md")).is_none());
}

#[test]
fn an_unchanged_file_is_not_reported() {
    needs_git!();
    let temp = fixture();
    let changes = changes_of(temp.path());
    assert!(
        find(&changes, "keep.md").is_none(),
        "a clean file must not appear: {changes:?}"
    );
}

#[test]
fn a_modified_file_carries_both_counts() {
    needs_git!();
    let temp = fixture();
    let changes = changes_of(temp.path());
    let edit = find(&changes, "edit.md").expect("edit.md is modified");
    assert_eq!(edit.status, Status::Modified);
    // "1\n2\n3\n" -> "1\nTWO\n3\nfour\n": line 2 replaced, one appended.
    assert_eq!(edit.counts(), Some((2, 1)));
}

#[test]
fn a_deleted_file_is_reported_with_its_removed_lines() {
    needs_git!();
    let temp = fixture();
    let changes = changes_of(temp.path());
    let gone = find(&changes, "gone.md").expect("gone.md is deleted");
    assert_eq!(gone.status, Status::Deleted);
    assert_eq!(gone.counts(), Some((0, 1)));
    assert!(
        !gone.status.has_content(),
        "nothing to diff for a file that is not there"
    );
}

#[test]
fn a_rename_reports_the_new_path() {
    needs_git!();
    let temp = fixture();
    let changes = changes_of(temp.path());
    // git may report this as a rename or as an add+delete pair depending on
    // its similarity judgment; either is correct, and both must name the new
    // path. What must *not* happen is the old path showing up as a live row.
    let renamed = find(&changes, "renamed.md").expect("renamed.md is present");
    assert!(matches!(
        renamed.status,
        Status::Renamed | Status::Added | Status::Modified
    ));
    if renamed.status == Status::Renamed {
        assert_eq!(renamed.from.as_deref(), Some(Path::new("moved.md")));
    }
}

#[test]
fn a_binary_file_has_no_counts_and_they_are_not_zero() {
    needs_git!();
    let temp = fixture();
    let changes = changes_of(temp.path());
    let logo = find(&changes, "logo.bin").expect("logo.bin is modified");
    assert_eq!(logo.status, Status::Modified);
    assert_eq!(
        logo.counts(),
        None,
        "`+0 -0` on a changed binary would be a lie"
    );
    assert_eq!(logo.added, None);
    assert_eq!(logo.removed, None);
}

#[test]
fn untracked_files_are_reported_and_directories_are_not_walked() {
    needs_git!();
    let temp = fixture();
    let changes = changes_of(temp.path());

    let fresh = find(&changes, "fresh.md").expect("fresh.md is untracked");
    assert_eq!(fresh.status, Status::Untracked);
    assert_eq!(
        fresh.added, None,
        "line counting is opt-in, and off for the sidebar's repo-scoped query"
    );
    assert_eq!(fresh.removed, Some(0), "an untracked file removed nothing");

    // `--directory`: one entry for the folder, not one per file inside it.
    assert!(
        find(&changes, "scratch/").is_some() || find(&changes, "scratch").is_some(),
        "the untracked directory should be collapsed to itself: {changes:?}"
    );
    assert!(
        find(&changes, "scratch/inner.md").is_none(),
        "an untracked directory must not be walked: {changes:?}"
    );
}

#[test]
fn untracked_line_counts_are_filled_in_when_asked_for() {
    needs_git!();
    let temp = fixture();
    let repo = git::discover(temp.path()).expect("repo");
    let changes = git::changes(
        &repo,
        &Query {
            count_untracked_lines: true,
            ..Query::default()
        },
    )
    .expect("changes");

    let fresh = find(&changes, "fresh.md").expect("fresh.md");
    assert_eq!(
        fresh.counts(),
        Some((2, 0)),
        "every line of a new note counts as added"
    );
}

#[test]
fn untracked_can_be_turned_off_entirely() {
    needs_git!();
    let temp = fixture();
    let repo = git::discover(temp.path()).expect("repo");
    let changes = git::changes(
        &repo,
        &Query {
            untracked: false,
            ..Query::default()
        },
    )
    .expect("changes");
    assert!(
        !changes.iter().any(|c| c.status == Status::Untracked),
        "asked for no untracked files and got some: {changes:?}"
    );
    assert!(
        find(&changes, "edit.md").is_some(),
        "tracked changes are still there"
    );
}

#[test]
fn changes_are_sorted_by_path() {
    needs_git!();
    let temp = fixture();
    let changes = changes_of(temp.path());
    let paths: Vec<_> = changes.iter().map(|c| c.path.clone()).collect();
    let mut sorted = paths.clone();
    sorted.sort();
    assert_eq!(paths, sorted, "order must not depend on git's internals");
}

#[test]
fn base_bytes_returns_heads_version() {
    needs_git!();
    let temp = fixture();
    let repo = git::discover(temp.path()).expect("repo");
    let base = git::base_bytes(&repo, &temp.path().join("edit.md"), git::DEFAULT_TIMEOUT)
        .expect("no error");
    assert_eq!(
        base.as_deref(),
        Some("1\n2\n3\n"),
        "the committed bytes, not the working ones"
    );
}

#[test]
fn base_bytes_is_none_for_a_file_head_does_not_have() {
    needs_git!();
    let temp = fixture();
    let repo = git::discover(temp.path()).expect("repo");
    // The common case for a new note, and it must not be an error.
    let base = git::base_bytes(&repo, &temp.path().join("fresh.md"), git::DEFAULT_TIMEOUT)
        .expect("not an error");
    assert_eq!(base, None);
}

#[test]
fn base_bytes_is_none_for_a_binary_blob() {
    needs_git!();
    let temp = fixture();
    let repo = git::discover(temp.path()).expect("repo");
    let base = git::base_bytes(&repo, &temp.path().join("logo.bin"), git::DEFAULT_TIMEOUT)
        .expect("not an error");
    assert_eq!(base, None, "a binary blob is not something we can diff");
}

#[test]
fn base_bytes_is_none_for_a_path_outside_the_repository() {
    needs_git!();
    let temp = fixture();
    let repo = git::discover(temp.path()).expect("repo");
    let base = git::base_bytes(&repo, Path::new("/etc/hosts"), git::DEFAULT_TIMEOUT)
        .expect("not an error");
    assert_eq!(base, None);
}

#[test]
fn a_repository_with_no_commits_still_reports_its_files_as_added() {
    needs_git!();
    let temp = TempDir::new().expect("tempdir");
    let root = temp.path().to_path_buf();
    git_in(&root, &["init", "--quiet", "--initial-branch=main"]);
    write(&root.join("first.md"), "one\ntwo\nthree\n");
    git_in(&root, &["add", "first.md"]);

    let repo = git::discover(&root).expect("a repository with no commits");
    assert_eq!(repo.head, None, "there is no HEAD to resolve yet");
    assert_eq!(
        repo.branch.as_deref(),
        Some("main"),
        "the branch is known even before it has a commit, because it is read \
         from the HEAD file rather than from `rev-parse --abbrev-ref`"
    );

    // The empty-tree base is what makes this work at all: `git diff HEAD` is a
    // fatal error here.
    let changes = git::changes(&repo, &Query::default()).expect("changes");
    let first = find(&changes, "first.md").expect("first.md");
    assert_eq!(first.status, Status::Added);
    assert_eq!(first.counts(), Some((3, 0)));

    // And HEAD has no bytes for anything.
    assert_eq!(
        git::base_bytes(&repo, &root.join("first.md"), git::DEFAULT_TIMEOUT).expect("no error"),
        None
    );
}

#[test]
fn a_detached_head_reports_head_as_its_branch() {
    needs_git!();
    let temp = fixture();
    let root = temp.path().to_path_buf();
    let oid = git_in(&root, &["rev-parse", "HEAD"]);
    // Stash the dirt so the checkout is allowed.
    git_in(&root, &["checkout", "--quiet", "--detach", &oid]);

    let repo = git::discover(&root).expect("repo");
    assert_eq!(
        repo.branch.as_deref(),
        Some("HEAD"),
        "that is what --abbrev-ref says when detached, and it must not crash"
    );
    assert!(repo.head.is_some());
}

#[test]
fn a_linked_worktree_resolves_its_own_index_and_head() {
    needs_git!();
    // The case `core/build.rs:174` already learned about, and the one this
    // repository is itself developed in: `.git` is a *file*, and the index
    // lives under `<main>/.git/worktrees/<name>/`. Joining onto `<root>/.git`
    // would produce a path that does not exist, and a `stat` of a missing path
    // reads as "nothing changed" — a silently dead gate.
    let temp = fixture();
    let main = temp.path().to_path_buf();
    let linked = main.join("linked-wt");
    git_in(
        &main,
        &[
            "worktree",
            "add",
            "--quiet",
            "--detach",
            linked.to_str().expect("utf8"),
        ],
    );

    let repo = git::discover(&linked).expect("the worktree is a repository");
    assert!(
        repo.git_dir.ends_with("worktrees/linked-wt"),
        "git dir should be the worktree's own: {:?}",
        repo.git_dir
    );
    assert!(
        repo.index_path.exists(),
        "the worktree's index must be reachable: {:?}",
        repo.index_path
    );
    assert!(
        repo.head_path.exists(),
        "and its HEAD: {:?}",
        repo.head_path
    );
    assert!(
        !repo.index_path.starts_with(linked.join(".git")),
        "the index is not under the worktree's own .git file: {:?}",
        repo.index_path
    );

    // And it must still answer questions.
    write(&linked.join("keep.md"), "changed in the worktree\n");
    let changes = git::changes(&repo, &Query::default()).expect("changes");
    assert!(find(&changes, "keep.md").is_some(), "{changes:?}");
}

#[test]
fn a_path_with_a_space_and_a_quote_survives() {
    needs_git!();
    // `-z` exists for this. Without it git quotes the name and the parser would
    // have to un-quote it, which is where a file quietly stops being reported.
    let temp = TempDir::new().expect("tempdir");
    let root = temp.path().to_path_buf();
    git_in(&root, &["init", "--quiet", "--initial-branch=main"]);
    let awkward = "a note \"with quotes\" and spaces.md";
    write(&root.join(awkward), "one\n");
    git_in(&root, &["add", "."]);
    git_in(&root, &["commit", "--quiet", "-m", "init"]);
    write(&root.join(awkward), "one\ntwo\n");

    let repo = git::discover(&root).expect("repo");
    let changes = git::changes(&repo, &Query::default()).expect("changes");
    let change = find(&changes, awkward).expect("the awkward path is reported");
    assert_eq!(change.counts(), Some((1, 0)));

    // And its base content is reachable.
    assert_eq!(
        git::base_bytes(&repo, &root.join(awkward), git::DEFAULT_TIMEOUT).expect("no error"),
        Some("one\n".to_owned())
    );
}

#[test]
fn the_gate_stamp_moves_when_the_index_does_and_not_otherwise() {
    needs_git!();
    // The property `2026-08-28-git-badges-ride-the-sidebar-poll` gates its
    // whole poll on, asserted directly rather than described.
    let temp = fixture();
    let repo = git::discover(temp.path()).expect("repo");
    let before = repo.stamp();

    // An in-place edit to a tracked file: the ADR *accepts* that this does not
    // move the stamp, inheriting the gap the sidebar poll already accepted for
    // task badges. Asserting it keeps the accepted limitation honest.
    write(&temp.path().join("keep.md"), "edited in place\n");
    assert_eq!(
        repo.stamp(),
        before,
        "an in-place edit moves neither index nor HEAD — this is the accepted gap"
    );

    // Staging does move it.
    git_in(temp.path(), &["add", "keep.md"]);
    assert_ne!(repo.stamp(), before, "staging must move the index stamp");
}

#[test]
fn a_quiet_repository_costs_a_bounded_number_of_processes() {
    needs_git!();
    // Not a laziness assertion — that one lives in Swift, where the poll is —
    // but a guard on the shape of this module: discovery plus a full query must
    // not turn into a process per file.
    let temp = fixture();
    let before = git::invocations();
    let repo = git::discover(temp.path()).expect("repo");
    let _ = git::changes(&repo, &Query::default()).expect("changes");
    let spent = git::invocations() - before;
    assert!(
        spent == 4,
        "discovery (2: paths, then the oid) + diff (1) + untracked (1). The \
         branch name costs none, because it is read out of the HEAD file. \
         Spent {spent}"
    );
}

#[test]
fn base_bytes_through_a_symlinked_directory_finds_the_tracked_file() {
    needs_git!();
    let temp = fixture();
    let repo = git::discover(temp.path()).expect("repo");
    // The repository as git spells it, so the lexical `strip_prefix` would
    // succeed and hand back `linked/edit.md` — a path HEAD has never heard of.
    let root = fs::canonicalize(temp.path()).expect("canonical root");
    std::os::unix::fs::symlink(&root, root.join("linked")).expect("symlink");

    let via_link = git::base_bytes(&repo, &root.join("linked/edit.md"), git::DEFAULT_TIMEOUT)
        .expect("no error");
    let direct =
        git::base_bytes(&repo, &root.join("edit.md"), git::DEFAULT_TIMEOUT).expect("no error");
    assert_eq!(via_link.as_deref(), Some("1\n2\n3\n"));
    assert_eq!(via_link, direct);
    assert_eq!(
        git::relative_to(&repo, &root.join("linked/edit.md")).as_deref(),
        Some(Path::new("edit.md"))
    );
}
