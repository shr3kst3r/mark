//! `write_atomically` under `2026-08-25-flock-write-locking`.
//!
//! The ADR puts one constraint on this crate and it is absolute:
//!
//! > **Every path that writes a user's document takes the lock first.** No
//! > exceptions, including future features. A write that skips it silently
//! > defeats the mechanism.
//!
//! `core::tasks::write_atomically` is the only function in the crate that
//! writes to a path, so these tests are the whole of that constraint: if the
//! acquire is here, every writer — `mark check`, `mark_toggle`,
//! `mark_write_json`, and anything added later — inherits it without being told.
//!
//! **Everything here holds the competing lock on a second open file
//! description in this same process, which really does conflict**: `flock` is
//! per open file description, so `File::open` twice inside one process is two
//! descriptions and the second `LOCK_EX | LOCK_NB` fails with `EWOULDBLOCK`.
//! That is verified directly in `lock::tests::a_second_description_in_this_
//! process_is_refused` and again below, because a same-process test that
//! *did* silently succeed would prove nothing. The genuinely cross-process
//! case — a real second `mark`, and a real `kill -9` — is in
//! `cli/tests/write_lock.rs`, where there is a binary to spawn.

use std::path::{Path, PathBuf};

use mark_core::lock::{DocumentLock, LockError};
use mark_core::tasks::{self, Action, TaskError, WriteError};
use tempfile::TempDir;

const DOCUMENT: &str = "# Notes\n\n- [ ] one\n- [ ] two\n";

fn fixture() -> (TempDir, PathBuf) {
    let directory = TempDir::new().expect("temp dir");
    let path = directory.path().join("notes.md");
    std::fs::write(&path, DOCUMENT).expect("write the fixture");
    (directory, path)
}

/// Anything `write_atomically` might have left lying around. A refusal must
/// leave the directory exactly as it found it — no half-written temp file for
/// the user to find in `git status`.
fn strays(directory: &Path) -> Vec<String> {
    std::fs::read_dir(directory)
        .expect("read the directory")
        .filter_map(Result::ok)
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| name != "notes.md")
        .collect()
}

#[test]
fn a_locked_document_is_refused_rather_than_written() {
    let (directory, path) = fixture();
    let held = DocumentLock::acquire(&path).expect("take the competing lock");
    assert!(held.is_held(), "the competing lock is not actually held");

    let error = tasks::write_atomically(&path, "# Clobbered\n").expect_err("must refuse");
    let WriteError::Locked(LockError::Busy { holder, .. }) = &error else {
        panic!("expected a Busy refusal, got {error:?}");
    };
    let holder = holder.as_ref().expect("the holder is this process");
    assert_eq!(holder.pid, std::process::id() as i32);

    assert_eq!(
        std::fs::read_to_string(&path).expect("read back"),
        DOCUMENT,
        "the document was written despite the refusal"
    );
    assert_eq!(
        strays(directory.path()),
        Vec::<String>::new(),
        "a refused write left debris behind"
    );
}

/// The refusal has to survive the trip through `TaskError`, because that is
/// what the CLI turns into exit status 6. Collapsing it into `TaskError::Io`
/// would compile, pass every other test, and exit 2.
#[test]
fn a_locked_document_refuses_a_toggle_with_its_own_variant() {
    let (_directory, path) = fixture();
    let _held = DocumentLock::acquire(&path).expect("take the competing lock");

    let error = tasks::toggle_file(&path, 0, Action::On).expect_err("must refuse");
    assert!(
        matches!(error, TaskError::Locked(_)),
        "a lock refusal must not arrive as {error:?}"
    );
    let message = error.to_string();
    assert!(message.contains("locked for writing"), "{message}");
    assert!(
        message.contains(&std::process::id().to_string()),
        "the refusal does not name the holding pid: {message}"
    );
    assert_eq!(std::fs::read_to_string(&path).expect("read back"), DOCUMENT);
}

/// The other half of the ADR's *"a clean tab holds no lock"*: a write must not
/// leave one behind either, or the first `mark check` in an agent's loop would
/// lock the file against the second.
#[test]
fn a_completed_write_leaves_the_document_unlocked() {
    let (_directory, path) = fixture();
    tasks::write_atomically(&path, "# Fresh\n").expect("write");

    let after = DocumentLock::acquire(&path).expect("acquire after the write");
    assert!(
        after.is_held(),
        "write_atomically kept the lock; the next writer would be refused"
    );
}

/// The inode the lock was taken on is not the inode the document ends up
/// with — the ADR's sharp edge, stated as a fact about this function so that
/// the app-side re-acquire has something to point at.
#[test]
fn a_write_replaces_the_inode_the_lock_was_taken_on() {
    let (_directory, path) = fixture();
    let before = DocumentLock::acquire(&path).expect("acquire");
    assert!(before.is_current());
    drop(before);

    let watching = DocumentLock::acquire(&path).expect("acquire");
    assert!(watching.is_current());
    // Hand it over the way the app does, write, and observe what happened to
    // the inode the holder had.
    let identity_survives = {
        let mut watching = watching;
        watching.release();
        tasks::write_atomically(&path, "# Fresh\n").expect("write");
        // Re-acquire on the new file, which is what the app must do.
        let after = DocumentLock::acquire(&path).expect("re-acquire");
        assert!(after.is_held());
        after.is_current()
    };
    assert!(identity_survives, "the re-acquired lock is already stale");

    // And the negative: a lock held *across* the write is stranded.
    let stranded = DocumentLock::acquire(&path).expect("acquire");
    let temp = stranded.path().parent().expect("parent").join(".swap");
    std::fs::write(&temp, "# Replaced\n").expect("write the replacement");
    std::fs::rename(&temp, &path).expect("rename over the document");
    assert!(stranded.is_held(), "the kernel still holds it");
    assert!(
        !stranded.is_current(),
        "a lock held across an inode replacement must report itself stale"
    );
    assert!(
        DocumentLock::acquire(&path)
            .expect("the replaced document is lockable")
            .is_held(),
        "the stranded lock still protects the path, which is the failure the ADR names"
    );
}

/// A document that does not exist yet is not a lock failure. The write creates
/// it, and there is no earlier writer to be excluded from a file that has never
/// existed.
#[test]
fn a_new_document_is_written_rather_than_refused() {
    let directory = TempDir::new().expect("temp dir");
    let path = directory.path().join("new.md");
    tasks::write_atomically(&path, DOCUMENT).expect("write a new document");
    assert_eq!(std::fs::read_to_string(&path).expect("read back"), DOCUMENT);
}

/// `~/notes -> ~/vault` is ordinary. The lock has to be on the inode both
/// spellings reach, or the app holding the link and a CLI given the real path
/// would each think they were alone.
#[test]
fn a_lock_through_a_symlink_refuses_a_write_to_the_real_path() {
    let (directory, path) = fixture();
    let link = directory.path().join("link.md");
    std::os::unix::fs::symlink(&path, &link).expect("symlink");

    let _held = DocumentLock::acquire(&link).expect("lock through the link");
    let error = tasks::write_atomically(&path, "# Clobbered\n").expect_err("must refuse");
    assert!(matches!(error, WriteError::Locked(_)), "{error:?}");
    assert_eq!(std::fs::read_to_string(&path).expect("read back"), DOCUMENT);
}
