import Darwin
import Foundation

/// Why a document could not be locked. Both cases mean **we are not holding
/// it**.
public enum DocumentLockError: Error, CustomStringConvertible {
    /// Someone else has it — another `mark` window, or a `mark` CLI mid-write.
    /// `flock` records no owner anywhere a second process can read, so unlike
    /// the core's refusal this one cannot name a pid; the core names it on the
    /// write attempt that follows, which is where the user sees it.
    case busy(path: String)
    /// The document could not be opened at all to lock it.
    case unopenable(path: String, code: Int32)

    public var description: String {
        switch self {
        case .busy(let path):
            return "\(path): another mark process holds the write lock"
        case .unopenable(let path, let code):
            return "\(path): could not be opened to lock it: \(String(cString: strerror(code)))"
        }
    }
}

/// An exclusive, non-blocking `flock(2)` on one document, held for as long as
/// this object lives.
///
/// `2026-08-25-flock-write-locking`:
///
/// > **The GUI holds an exclusive `flock(2)` on a document for exactly as long
/// > as its buffer is dirty**, and releases it when the buffer becomes clean. A
/// > clean tab — however long it has been open — holds no lock, so viewing a
/// > document never blocks anything.
///
/// This is the app's half of that; ``Buffer`` owns the lifetime. It calls
/// `flock(2)` directly through Darwin rather than through the core, because
/// ADR-1's C ABI is full at twelve functions and a lock/unlock pair would be
/// the thirteenth and fourteenth. The core takes the *same* lock, on the *same*
/// canonicalized path, from `core::lock::DocumentLock` — one kernel primitive,
/// reached two ways, which is what makes the app and the CLI actually exclude
/// each other.
///
/// Three properties are worth knowing before touching this:
///
/// * **It cannot leak.** The kernel drops the lock when the descriptor closes,
///   including on `SIGKILL` and on power loss. So there is no cleanup path
///   here, and none is needed at quit.
/// * **It is advisory.** `vim` and VS Code neither take it nor respect it, so
///   this protects `mark` from `mark` and from nothing else. The conflict
///   prompt (``ConflictController``) is what defends against them, and it stays.
/// * **It follows the inode, not the name.** An atomic write — ours or theirs —
///   renames a new inode over the path, and a lock held across that is held on
///   an orphan. ``isCurrent`` is how a holder finds out; ``Buffer/syncLock()``
///   is what acts on it.
public final class DocumentLock {

    /// The path asked for. Not necessarily the path locked — a symlinked note
    /// resolves to the real file, because that is the inode the core competes
    /// for.
    public let url: URL

    private var descriptor: Int32 = -1
    private var device: dev_t = 0
    private var inode: ino_t = 0

    private init(url: URL, descriptor: Int32, device: dev_t, inode: ino_t) {
        self.url = url
        self.descriptor = descriptor
        self.device = device
        self.inode = inode
    }

    deinit { close() }

    /// Take the lock, or throw. **Never blocks** — the ADR is explicit that a
    /// blocking acquire in a GUI event handler is a hang.
    public static func acquire(_ url: URL) throws -> DocumentLock {
        // `resolvingSymlinksInPath` for the same reason the core canonicalizes:
        // `~/notes -> ~/vault` means the app and a CLI can be handed different
        // spellings of one inode, and two writers that disagree about which
        // file they are competing for exclude nobody.
        let resolved = url.resolvingSymlinksInPath()
        let path = resolved.path

        let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC) }
        guard descriptor >= 0 else {
            throw DocumentLockError.unopenable(path: path, code: errno)
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            // ENOTSUP is a network filesystem that does not implement flock.
            // The ADR accepts that explicitly — *"A document on a network share
            // is effectively unlocked, and we do not detect or warn about it"* —
            // so it is reported as busy-free rather than as a failure the user
            // is asked to do something about. It still throws, because we are
            // genuinely not holding anything and pretending otherwise would be
            // the lie this whole mechanism exists to avoid.
            throw code == EWOULDBLOCK
                ? DocumentLockError.busy(path: path)
                : DocumentLockError.unopenable(path: path, code: code)
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw DocumentLockError.unopenable(path: path, code: code)
        }
        return DocumentLock(
            url: resolved, descriptor: descriptor, device: status.st_dev, inode: status.st_ino)
    }

    /// Whether the kernel is still holding this lock for us.
    public var isHeld: Bool { descriptor >= 0 }

    /// Whether the locked inode is still the file at ``url``.
    ///
    /// **The ADR's sharp edge, made checkable.** After `write_atomically`
    /// renames its temp file over the target — or after `vim` does the same —
    /// the descriptor still names a perfectly valid inode that nothing can
    /// reach by path any more. Nothing about the lock changes when that
    /// happens, and no error is raised: the file simply becomes writable again
    /// while the buffer is still dirty. Asking is the only way to find out.
    public var isCurrent: Bool {
        guard isHeld else { return false }
        var status = stat()
        guard url.path.withCString({ stat($0, &status) }) == 0 else { return false }
        return status.st_dev == device && status.st_ino == inode
    }

    /// Release now. Idempotent.
    ///
    /// Closing the descriptor is what releases the lock; there is no
    /// `flock(LOCK_UN)` first, because it would only add a syscall that can
    /// fail on a path where failure means nothing.
    public func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }
}
