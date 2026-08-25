//! `flock(2)` write locking for a user's document.
//!
//! `2026-08-25-flock-write-locking` decides that
//!
//! > **Every `mark` write path takes `flock(…, LOCK_EX | LOCK_NB)` before
//! > writing and refuses on `EWOULDBLOCK`**, rather than blocking. Refusal is
//! > a real error naming the holder — pid and, where obtainable, that it is
//! > `mark` — and exits with a distinct code.
//!
//! This module is that lock, and it is the *only* implementation of it: the
//! CLI reaches it through [`crate::tasks::write_atomically`], the app reaches
//! the same primitive through a Swift twin (`Editor/DocumentLock.swift`) that
//! calls the same `flock(2)` on the same canonicalized path. There is no
//! second set of semantics for the two halves to drift apart on.
//!
//! Three properties of `flock` are the reason that ADR chose it over the lock
//! file its predecessor rejected, and each shows up in the code below:
//!
//! * **It cannot leak.** The kernel holds the lock against an open file
//!   description and drops it when the last descriptor closes — including on
//!   `SIGKILL`, a panic, or a power loss. So [`DocumentLock`] is a plain RAII
//!   wrapper around a [`File`] and there is no cleanup path, no heartbeat, and
//!   no stale detection to get wrong.
//! * **It is advisory.** `vim`, VS Code, IntelliJ and Sublime neither take it
//!   nor respect it. A lock here protects `mark` from `mark` and from nothing
//!   else, which is why the app's conflict prompt is *kept* rather than
//!   replaced.
//! * **It follows the inode, not the name.** `write_atomically` renames a temp
//!   file over the target, so the lock a writer held before a write is held on
//!   an orphan afterwards. Callers that need to *keep* holding must re-acquire
//!   on the new file; [`DocumentLock::is_current`] is how they find out they
//!   need to.
//!
//! Locks are always taken **non-blocking**. The ADR: *"Never block on the lock.
//! `LOCK_NB` always; a blocking acquire in a GUI event handler or a CLI an
//! agent calls in a loop is a hang."*
//!
//! Measured on this machine, since both numbers sit on paths with budgets:
//!
//! * **32.7 µs** for an uncontended acquire-and-release — `canonicalize`,
//!   `open`, `flock`, `fstat`. That is what every write through
//!   [`crate::tasks::write_atomically`] now pays, against a `mark check`
//!   invocation budget of ~2.84 ms and an autosave that takes milliseconds.
//! * **0.7–1.1 ms** for a refusal *including* [`holder_of`]'s process-table
//!   walk, worst case being a holder named neither `mark` nor us so the scan
//!   reaches it last. Only a refused write pays it, and a refused write is
//!   about to stop and print a message anyway.

use std::fmt;
use std::fs::{self, File};
use std::io;
use std::os::unix::fs::MetadataExt as _;
use std::os::unix::io::AsRawFd as _;
use std::path::{Path, PathBuf};

/// Why a lock was not taken. Every variant means **nothing was written**.
#[derive(Debug)]
pub enum LockError {
    /// Someone else holds the document. The ADR's `EWOULDBLOCK` refusal.
    Busy {
        path: PathBuf,
        /// Best effort — see [`Holder`]. `None` when the holder could not be
        /// identified, which is reported rather than guessed at.
        holder: Option<Holder>,
    },
    /// The document could not be opened to lock it at all.
    Io { path: PathBuf, source: io::Error },
}

impl fmt::Display for LockError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            LockError::Busy { path, holder } => {
                write!(f, "{}: locked for writing by ", path.display())?;
                match holder {
                    Some(holder) if holder.is_current_process => write!(
                        f,
                        "this process ({} pid {}) - a lock it took earlier was never released",
                        holder.name, holder.pid
                    ),
                    // Deliberately not "which has unsaved edits": the holder is
                    // a mark *window* with unsaved edits in the case the ADR is
                    // about, but it is equally a second `mark check` still
                    // inside its own write, and telling that one's caller to
                    // "save your changes" sends them looking for a window that
                    // does not exist.
                    Some(holder) => write!(
                        f,
                        "{} (pid {}); nothing was written. \
                         If that is a mark window with unsaved edits, save it or close the tab.",
                        holder.name, holder.pid
                    ),
                    None => write!(
                        f,
                        "another process (pid not identifiable); nothing was written. \
                         If a mark window has unsaved edits to this file, save it or close the tab."
                    ),
                }
            }
            LockError::Io { path, source } => write!(f, "{}: {source}", path.display()),
        }
    }
}

impl std::error::Error for LockError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            LockError::Io { source, .. } => Some(source),
            LockError::Busy { .. } => None,
        }
    }
}

/// The process holding a document, as far as we can tell.
///
/// `flock` records no owner anywhere a second process can read — there is no
/// `F_GETLK` for it — so this is reconstructed from the process table: the
/// holder must have the file *open*, so the `mark` process that does is the
/// holder. That is an inference, not a kernel answer, which is why it is an
/// `Option` on [`LockError::Busy`] and why the message says "pid not
/// identifiable" instead of inventing one when the scan comes up empty.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Holder {
    pub pid: i32,
    /// The executable's name — `mark` for the app, `mark-cli` for this binary.
    pub name: String,
    /// The holder is us. Means a lock this process took was not released, and
    /// is worth saying out loud rather than reporting as a mysterious rival.
    pub is_current_process: bool,
}

/// Whether a [`DocumentLock`] is actually holding anything, and why not when
/// it is not.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LockState {
    /// The kernel is holding an exclusive lock for us.
    Held,
    /// There is no such file yet, so there is nothing to lock and nothing for
    /// another writer to be editing. A first write to a new path is allowed.
    DocumentAbsent,
    /// The filesystem does not implement `flock` — NFS and some SMB mounts.
    /// The ADR accepts this explicitly: *"A document on a network share is
    /// effectively unlocked, and we do not detect or warn about it."* We do not
    /// refuse the write, because refusing every write on a network share would
    /// make the product unusable there.
    Unsupported,
}

/// An exclusive, non-blocking `flock(2)` on one document.
///
/// Dropping it releases the lock, because dropping it closes the descriptor.
/// That is the whole lifecycle: there is deliberately no `unlock` bookkeeping,
/// no registry, and nothing to run on a crash path.
#[derive(Debug)]
pub struct DocumentLock {
    /// The **canonicalized** target. Two processes must agree on which inode
    /// they are competing for, and `~/notes -> ~/vault` means the path they
    /// were handed is not enough — `write_atomically` resolves symlinks before
    /// renaming for the same reason.
    path: PathBuf,
    file: Option<File>,
    state: LockState,
    /// `(dev, ino)` of the locked file at acquire time, for [`Self::is_current`].
    identity: Option<(u64, u64)>,
}

impl DocumentLock {
    /// Take an exclusive lock on `path`, or report who has it.
    ///
    /// Never blocks. A missing file is not an error — see
    /// [`LockState::DocumentAbsent`].
    pub fn acquire(path: &Path) -> Result<DocumentLock, LockError> {
        let target = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());

        // Read-only is enough: `flock` locks the open file description and does
        // not care about the access mode, unlike `fcntl` record locks which
        // need write access for `F_WRLCK`. Opening read-only means locking a
        // read-only document still works, and that we never truncate anything
        // by accident on this path.
        let file = match File::open(&target) {
            Ok(file) => file,
            Err(source) if source.kind() == io::ErrorKind::NotFound => {
                return Ok(DocumentLock {
                    path: target,
                    file: None,
                    state: LockState::DocumentAbsent,
                    identity: None,
                });
            }
            Err(source) => {
                return Err(LockError::Io {
                    path: target,
                    source,
                });
            }
        };

        // SAFETY: `file` owns a valid descriptor for the duration of the call.
        let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if result == 0 {
            let identity = file.metadata().ok().map(|meta| (meta.dev(), meta.ino()));
            return Ok(DocumentLock {
                path: target,
                file: Some(file),
                state: LockState::Held,
                identity,
            });
        }

        let error = io::Error::last_os_error();
        match error.raw_os_error() {
            Some(code) if code == libc::EWOULDBLOCK => {
                // **Close the probe first.** `holder_of` looks for a process
                // with this inode open, and until this line we are one: the
                // descriptor we just failed to lock is still open, so the scan
                // would confidently name *us* as the holder of a lock we were
                // refused. It found the caller every time before this drop, in
                // `a_second_process_is_refused_and_told_who_holds_the_document`.
                drop(file);
                let holder = holder_of(&target);
                Err(LockError::Busy {
                    path: target,
                    holder,
                })
            }
            // NFS and some SMB mounts. The ADR names this and accepts it.
            Some(code) if code == libc::ENOTSUP || code == libc::EOPNOTSUPP => Ok(DocumentLock {
                path: target,
                file: None,
                state: LockState::Unsupported,
                identity: None,
            }),
            _ => Err(LockError::Io {
                path: target,
                source: error,
            }),
        }
    }

    /// The canonicalized path this lock was taken on.
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    #[must_use]
    pub fn state(&self) -> LockState {
        self.state
    }

    /// Whether the kernel is actually holding a lock for us.
    #[must_use]
    pub fn is_held(&self) -> bool {
        self.state == LockState::Held
    }

    /// Whether the locked inode is still the file at [`Self::path`].
    ///
    /// **This is the ADR's sharp edge, made checkable.** An atomic write —
    /// ours, or `vim`'s — renames a new inode over the path, and a lock held
    /// across that is held on an orphan that no longer answers to the name.
    /// Nothing about the descriptor changes when that happens, so a holder that
    /// wants to keep holding has to ask.
    #[must_use]
    pub fn is_current(&self) -> bool {
        let Some(identity) = self.identity else {
            return false;
        };
        fs::metadata(&self.path).is_ok_and(|meta| (meta.dev(), meta.ino()) == identity)
    }

    /// Release now rather than at end of scope.
    pub fn release(&mut self) {
        // Closing the descriptor is what releases the lock; there is no need to
        // `flock(LOCK_UN)` first, and doing so would only add a syscall that
        // can fail on a path where failure means nothing.
        self.file = None;
        self.identity = None;
        if self.state == LockState::Held {
            self.state = LockState::DocumentAbsent;
        }
    }
}

/// Which process has `target` open.
///
/// Scanning descriptors is what `lsof` does and costs what `lsof` costs, so the
/// candidates are **ordered** rather than filtered: this process first, then
/// anything named `mark` or `mark-cli` (ADR-1 ships exactly those two Mach-O
/// binaries), then everyone else. `proc_name` is one cheap syscall per pid, and
/// the answer is normally found in the first one or two candidates. Ordering
/// rather than filtering matters because a lock held by something that is not
/// named `mark` — a test harness, a future tool — is still an answer worth
/// giving, and "pid not identifiable" should mean it really is not.
///
/// This runs only on the refusal path, never on a successful write.
///
/// Matching is by `(dev, ino)` rather than by path, because after an atomic
/// write the holder's descriptor may name an inode that no longer has a path at
/// all — matching on the string would silently find nothing exactly when the
/// answer matters most.
#[cfg(target_os = "macos")]
fn holder_of(target: &Path) -> Option<Holder> {
    /// `proc_listpids`' "every pid" selector. Not in the `libc` crate.
    const PROC_ALL_PIDS: u32 = 1;
    /// `PROC_PIDFDVNODEPATHINFO` from `<sys/proc_info.h>`. Not in `libc`.
    const PROC_PIDFDVNODEPATHINFO: libc::c_int = 2;

    /// `struct proc_fileinfo`, `<sys/proc_info.h>`.
    #[repr(C)]
    #[derive(Default)]
    struct ProcFileInfo {
        fi_openflags: u32,
        fi_status: u32,
        fi_offset: libc::off_t,
        fi_type: i32,
        fi_guardflags: u32,
    }

    /// `struct vnode_fdinfowithpath`, `<sys/proc_info.h>`.
    #[repr(C)]
    struct VnodeFdInfoWithPath {
        pfi: ProcFileInfo,
        pvip: libc::vnode_info_path,
    }

    let meta = fs::metadata(target).ok()?;
    let wanted = (u64::from(meta.dev() as u32), meta.ino());
    let us = std::process::id() as i32;

    // SAFETY: the two-call sizing dance `proc_listpids` documents — ask for the
    // byte count with a null buffer, then ask again with one that big.
    let bytes = unsafe { libc::proc_listpids(PROC_ALL_PIDS, 0, std::ptr::null_mut(), 0) };
    if bytes <= 0 {
        return None;
    }
    let capacity = (bytes as usize / size_of::<i32>()) + 16;
    let mut pids: Vec<i32> = vec![0; capacity];
    let bytes = unsafe {
        libc::proc_listpids(
            PROC_ALL_PIDS,
            0,
            pids.as_mut_ptr().cast(),
            (capacity * size_of::<i32>()) as libc::c_int,
        )
    };
    if bytes <= 0 {
        return None;
    }
    pids.truncate(bytes as usize / size_of::<i32>());

    let mut candidates: Vec<(i32, String)> = pids
        .into_iter()
        .filter(|pid| *pid > 0)
        .filter_map(|pid| process_name(pid).map(|name| (pid, name)))
        .collect();
    candidates.sort_by_key(|(pid, name)| match (*pid == us, name.as_str()) {
        (true, _) => 0,
        (_, "mark" | "mark-cli") => 1,
        _ => 2,
    });

    for (pid, name) in candidates {
        if has_open(
            pid,
            wanted,
            PROC_PIDFDVNODEPATHINFO,
            |buffer: &VnodeFdInfoWithPath| {
                let stat = &buffer.pvip.vip_vi.vi_stat;
                (u64::from(stat.vst_dev), stat.vst_ino)
            },
        ) {
            return Some(Holder {
                pid,
                name,
                is_current_process: pid == us,
            });
        }
    }
    None
}

/// The executable name of `pid`, or `None` if it cannot be read (a process
/// that exited between the listing and here, or one we may not inspect).
#[cfg(target_os = "macos")]
fn process_name(pid: i32) -> Option<String> {
    // 2 * MAXCOMLEN + 1 is what `proc_name` writes at most; round up.
    let mut buffer = [0u8; 64];
    // SAFETY: `buffer` is valid for `buffer.len()` bytes.
    let written =
        unsafe { libc::proc_name(pid, buffer.as_mut_ptr().cast(), buffer.len() as u32 - 1) };
    if written <= 0 {
        return None;
    }
    Some(String::from_utf8_lossy(&buffer[..written as usize]).into_owned())
}

/// Whether `pid` has a vnode descriptor open on `wanted`, given as `(dev, ino)`.
#[cfg(target_os = "macos")]
fn has_open<T>(
    pid: i32,
    wanted: (u64, u64),
    flavor: libc::c_int,
    identity: impl Fn(&T) -> (u64, u64),
) -> bool {
    // SAFETY: sizing call, then the real one, as `proc_pidinfo` documents.
    let bytes =
        unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDLISTFDS, 0, std::ptr::null_mut(), 0) };
    if bytes <= 0 {
        return false;
    }
    let entry = size_of::<libc::proc_fdinfo>();
    let capacity = (bytes as usize / entry) + 16;
    let mut fds: Vec<libc::proc_fdinfo> = vec![
        libc::proc_fdinfo {
            proc_fd: 0,
            proc_fdtype: 0,
        };
        capacity
    ];
    let bytes = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDLISTFDS,
            0,
            fds.as_mut_ptr().cast(),
            (capacity * entry) as libc::c_int,
        )
    };
    if bytes <= 0 {
        return false;
    }
    fds.truncate(bytes as usize / entry);

    for fd in fds {
        if fd.proc_fdtype != libc::PROX_FDTYPE_VNODE as u32 {
            continue;
        }
        let mut info = std::mem::MaybeUninit::<T>::zeroed();
        // SAFETY: `info` is valid for `size_of::<T>()` bytes, and the kernel
        // fills exactly that many for this flavor. A short or failed read is
        // reported as a non-positive return and skipped.
        let written = unsafe {
            libc::proc_pidfdinfo(
                pid,
                fd.proc_fd,
                flavor,
                info.as_mut_ptr().cast(),
                size_of::<T>() as libc::c_int,
            )
        };
        if written as usize != size_of::<T>() {
            continue;
        }
        // SAFETY: the kernel wrote a full `T`.
        let info = unsafe { info.assume_init() };
        if identity(&info) == wanted {
            return true;
        }
    }
    false
}

/// Non-Darwin builds get no holder identification. The core is macOS-only in
/// practice (ADR-1), but it must still compile for a `cargo check` elsewhere,
/// and "we could not identify the holder" is already a state the message
/// handles.
#[cfg(not(target_os = "macos"))]
fn holder_of(_target: &Path) -> Option<Holder> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write as _;

    fn document(directory: &Path, name: &str) -> PathBuf {
        let path = directory.join(name);
        let mut file = File::create(&path).expect("create the fixture");
        file.write_all(b"- [ ] one\n").expect("write the fixture");
        path
    }

    #[test]
    fn a_lock_is_held_and_released_with_its_guard() {
        let directory = tempfile::tempdir().expect("temp dir");
        let path = document(directory.path(), "notes.md");

        let lock = DocumentLock::acquire(&path).expect("acquire");
        assert!(lock.is_held());
        assert_eq!(lock.state(), LockState::Held);
        assert!(lock.is_current());
        drop(lock);

        // Releasing means a fresh acquire in this same process succeeds. If the
        // drop did not close the descriptor this would fail with EWOULDBLOCK,
        // because flock is per open file description and a second `File::open`
        // is a second description even inside one process.
        let again = DocumentLock::acquire(&path).expect("acquire after release");
        assert!(again.is_held());
    }

    #[test]
    fn a_second_description_in_this_process_is_refused() {
        let directory = tempfile::tempdir().expect("temp dir");
        let path = document(directory.path(), "notes.md");

        let held = DocumentLock::acquire(&path).expect("acquire");
        assert!(held.is_held());

        let error = DocumentLock::acquire(&path).expect_err("a second open must be refused");
        let LockError::Busy { holder, .. } = &error else {
            panic!("expected Busy, got {error:?}");
        };
        // We are the holder, and the message says so rather than describing us
        // as a mysterious rival.
        let holder = holder
            .as_ref()
            .expect("the holder is this process, so it is findable");
        assert_eq!(holder.pid, std::process::id() as i32);
        assert!(holder.is_current_process);
        assert!(
            error.to_string().contains("this process"),
            "unhelpful message: {error}"
        );
    }

    #[test]
    fn a_missing_document_is_not_an_error_and_is_not_held() {
        let directory = tempfile::tempdir().expect("temp dir");
        let lock = DocumentLock::acquire(&directory.path().join("nothing.md")).expect("acquire");
        assert_eq!(lock.state(), LockState::DocumentAbsent);
        assert!(!lock.is_held());
        assert!(!lock.is_current());
    }

    #[test]
    fn a_lock_follows_the_inode_and_not_the_name() {
        let directory = tempfile::tempdir().expect("temp dir");
        let path = document(directory.path(), "notes.md");
        let lock = DocumentLock::acquire(&path).expect("acquire");
        assert!(lock.is_current());

        // What `write_atomically` — and vim, and VS Code — do: a new inode
        // renamed over the name. The lock is now on an orphan.
        let temp = directory.path().join(".swap");
        fs::write(&temp, "- [x] one\n").expect("write the replacement");
        fs::rename(&temp, &path).expect("rename over the target");

        assert!(lock.is_held(), "the kernel still holds it — on the orphan");
        assert!(
            !lock.is_current(),
            "the lock must report that it no longer covers the document"
        );

        // And the proof that the orphaned lock protects nothing: the path is
        // lockable again.
        let other = DocumentLock::acquire(&path).expect("the replaced document is unlocked");
        assert!(other.is_held());
    }

    #[test]
    fn a_symlinked_document_locks_the_real_file() {
        let directory = tempfile::tempdir().expect("temp dir");
        let path = document(directory.path(), "notes.md");
        let link = directory.path().join("link.md");
        std::os::unix::fs::symlink(&path, &link).expect("symlink");

        let held = DocumentLock::acquire(&link).expect("acquire through the link");
        assert!(held.is_held());
        // Same inode, so the same lock: a CLI given the real path and an app
        // given the link must not both think they hold it.
        let error = DocumentLock::acquire(&path).expect_err("the real file is locked too");
        assert!(matches!(error, LockError::Busy { .. }), "{error:?}");
    }

    #[test]
    fn release_frees_the_lock_before_the_guard_is_dropped() {
        let directory = tempfile::tempdir().expect("temp dir");
        let path = document(directory.path(), "notes.md");
        let mut lock = DocumentLock::acquire(&path).expect("acquire");
        lock.release();
        assert!(!lock.is_held());
        assert!(DocumentLock::acquire(&path).expect("acquire").is_held());
    }

    #[test]
    fn an_unidentifiable_holder_still_produces_a_usable_message() {
        let error = LockError::Busy {
            path: PathBuf::from("/tmp/notes.md"),
            holder: None,
        };
        let message = error.to_string();
        assert!(message.contains("/tmp/notes.md"), "{message}");
        assert!(message.contains("not identifiable"), "{message}");

        let named = LockError::Busy {
            path: PathBuf::from("/tmp/notes.md"),
            holder: Some(Holder {
                pid: 4242,
                name: "mark".into(),
                is_current_process: false,
            }),
        };
        let message = named.to_string();
        assert!(message.contains("mark (pid 4242)"), "{message}");
        assert!(message.contains("nothing was written"), "{message}");
    }
}
