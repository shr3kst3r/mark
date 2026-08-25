---
id: 2026-08-25-flock-write-locking
status: Accepted
supersedes: [2026-08-24-editing-pane-and-autosave]
superseded-by: null
components: [app, editor, core, cli]
ticket: null
date: 2026-08-25
---
# Take an flock(2) write lock on a dirty document, and keep the conflict prompt for editors that ignore it

## Context

`2026-08-24-editing-pane-and-autosave` decided the editing pane, buffer-is-truth-
while-dirty, an 800 ms debounced autosave, and a conflict prompt. All of that is
implemented, tested, and working. It also decided one thing this ADR reverses:

> **The CLI may still write a file the GUI holds dirty.** `mark check` from a
> terminal writes the file; the GUI detects the change and raises the normal
> conflict prompt. We deliberately do not add cross-process locking — the prompt
> is the answer, and the alternative is a lock file to leak.

and, in its Alternatives:

> **Cross-process locking so the CLI cannot write a dirty file.** Rejected: a lock
> file that leaks on crash is worse than the conflict prompt we already need for
> external editors, and it would make the CLI's behaviour depend on whether the
> GUI happens to be running.

**That rejection reasoned about one implementation and generalised to all of
them.** A sidecar lock file does leak on crash, and the stale-detection it then
needs — is that pid alive, is it still `mark`, was the pid reused — has its own
race. But `flock(2)` is not a lock file. The kernel holds the lock against an
open file description and releases it when the last descriptor closes, including
when the process dies of `SIGKILL`, a panic, or a power loss. **It cannot leak,
and there is no cleanup code to write.** The stated objection does not apply to
the mechanism, so the decision deserves remaking rather than defending.

The second objection — that the CLI's behaviour would depend on whether the GUI
is running — is true and is now accepted rather than dismissed. It is also
already true of every other CLI verb: `mark open` launches the app, `mark tab
list` fails without it. A refusal that names the holder is better than a silent
clobber followed by a dialog on someone else's screen.

Two facts shape the design and were verified rather than assumed:

1. **`flock` is advisory.** `vim`, VS Code, IntelliJ and Sublime do not take it
   and are not blocked by it. So a lock protects `mark` against `mark`, and
   nothing else. **ADR-6's conflict prompt therefore remains the only defence
   against an external editor, and is kept.**
2. **An atomic write breaks the lock's association with the path.** The core's
   `write_atomically` writes a temp file and renames over the target, which
   replaces the inode. A lock held on the old descriptor is then held on an
   orphaned inode that no longer answers to that path. The lock must be
   re-acquired after every autosave, or a second writer walks straight in.

## Decision

**The GUI holds an exclusive `flock(2)` on a document for exactly as long as its
buffer is dirty**, and releases it when the buffer becomes clean. A clean tab —
however long it has been open — holds no lock, so viewing a document never
blocks anything.

Because `write_atomically` replaces the inode, the app **re-acquires the lock
immediately after each autosave**, on the new file. A test asserts the lock is
held again after a write, not merely before it.

**Every `mark` write path takes `flock(…, LOCK_EX | LOCK_NB)` before writing and
refuses on `EWOULDBLOCK`**, rather than blocking. Refusal is a real error naming
the holder — pid and, where obtainable, that it is `mark` — and exits with a
distinct code so a caller can branch on "locked" separately from "no such file"
and "refused".

**Everything else from the superseded ADR is carried forward unchanged**: the
`NSTextView` + TextKit 2 editor pane right of the preview; buffer-is-truth while
dirty; 800 ms debounced autosave through `write_atomically`; self-write content-
hash suppression; dirty tabs never dehydrated; checkbox clicks applying to the
buffer while dirty and to the file while clean; autosave paused while a conflict
is unresolved; and **the keep-mine / take-theirs / show-diff conflict prompt**,
which is now the defence against non-`mark` writers specifically.

## Consequences

**Easier.** Two `mark` processes can no longer clobber each other, and the common
case — a terminal `mark check` against a document the GUI has open and dirty —
now fails loudly instead of succeeding into a conflict dialog. Nothing leaks:
there is no lock file, no heartbeat, no stale detection, and no cleanup path to
get wrong. A crashed or `kill -9`'d app releases every lock it held, instantly,
without our involvement.

**Harder, and we are accepting it.**

- **The lock is advisory, so it protects `mark` from `mark` and nothing else.**
  A user who assumes their file is protected from `vim` is wrong. This is the
  most likely misunderstanding this feature creates, and the reason the conflict
  prompt is kept rather than replaced.
- **A CLI verb can now fail for a reason that is invisible on the filesystem.**
  `mark check` refusing because "some GUI has unsaved edits" is a worse error to
  debug than a missing file, and it depends on another process's state.
- **The lock must be re-acquired after every autosave**, because the atomic write
  replaces the inode. A missed re-acquire is silent: the file simply becomes
  writable again while the buffer is still dirty. This is the sharp edge.
- **`flock` on network filesystems is unreliable.** On NFS and some SMB mounts it
  is a no-op or an error. A document on a network share is effectively unlocked,
  and we do not detect or warn about it.
- **A long-dirty tab holds a lock indefinitely**, so a forgotten window with
  unsaved edits blocks CLI writes to that file until it is saved or closed. That
  is the intended behaviour, but it will surprise someone.

Constraints this imposes on future work:

- **Every path that writes a user's document takes the lock first.** No
  exceptions, including future features. A write that skips it silently defeats
  the mechanism.
- **The lock is re-acquired after every atomic write**, and a test must assert
  the held state *after* a write, not only before.
- **Never block on the lock.** `LOCK_NB` always; a blocking acquire in a GUI
  event handler or a CLI an agent calls in a loop is a hang.
- **The conflict prompt is not removed.** It is the only defence against writers
  that ignore advisory locks, and removing it would make external-editor saves
  silently destructive again.
- **A clean tab holds no lock.** Holding one for every open document would make
  the app hostile to the CLI it is meant to be driven by.

## Alternatives considered

- **No locking — the superseded ADR's position.** Simplest, and the conflict
  prompt already exists. Rejected because it lets two `mark` processes clobber
  each other when refusing is both easy and free, and because the reasoning that
  produced it does not survive contact with `flock`.
- **A sidecar `.mark.lock` file with pid and staleness detection.** Visible,
  debuggable, and works across any tool that agrees to check it. Rejected for
  exactly the reason the superseded ADR gave: it leaks on crash, and the "is that
  pid still alive and still `mark`" check races pid reuse. `flock` gets the same
  protection with none of that.
- **`fcntl`/POSIX record locks (`F_SETLK`).** Finer-grained, byte-range capable,
  and what most databases use. Rejected: their semantics are notoriously
  surprising — they are released when *any* descriptor for the file is closed by
  the process, which makes them fragile in a codebase that opens documents in
  several places. `flock`'s per-description ownership is the simpler contract,
  and we do not need byte ranges.
- **Blocking acquisition with a timeout.** Would let a CLI write succeed once the
  GUI saves. Rejected: it turns a fast, explicable refusal into a stall, and an
  agent calling `mark` in a loop would hang on a window someone left open.
- **Holding the lock for every open document, clean or dirty.** Stronger
  mutual exclusion. Rejected: it would make `mark open` and then any CLI write to
  the same file mutually exclusive, which breaks the workflow this app exists to
  support.
