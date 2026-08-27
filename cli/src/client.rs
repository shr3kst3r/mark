//! Talking to the running app, and starting it when there is none.
//!
//! ADR-3 (`2026-08-24-cli-app-unix-socket-ipc`):
//!
//! > `mark-cli` connects and sends its command. On `ENOENT` or `ECONNREFUSED`
//! > it treats the app as not running: it launches via `open -g -b <bundle-id>`
//! > (`-g` so focus is not stolen), then retries the connection with backoff
//! > until the socket appears.
//!
//! Three failures this file exists to get right, all of which the ADR names as
//! costs it is accepting:
//!
//! * **The 104-byte `sun_path` limit.** Asserted before we touch a socket, so
//!   a long `$TMPDIR` produces one clear sentence instead of a connect that
//!   cannot possibly succeed.
//! * **The stale socket.** A file left behind by a crash refuses connections
//!   (`ECONNREFUSED`), which is indistinguishable from "not running" — so it is
//!   *treated* as not running: launch, and the app unlinks and rebinds.
//! * **Two CLIs racing to launch.** Both find no socket, both run `open`, and
//!   LaunchServices starts one app; whichever loses simply finds the winner's
//!   socket on a later retry. No lock file, because the operating system
//!   already owns this problem.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::wire::{RemoteError, Request, Response};

/// `sizeof(struct sockaddr_un.sun_path)` on macOS: 104, not the 108 every Linux
/// example assumes (`sys/un.h:79`). The path plus its NUL must fit.
pub const SUN_PATH_CAPACITY: usize = 104;

/// The longest socket path that fits.
pub const MAX_SOCKET_PATH: usize = SUN_PATH_CAPACITY - 1;

/// ADR-3's launch target. Matches `CFBundleIdentifier` in
/// `scripts/assemble-bundle.sh`.
pub const BUNDLE_ID: &str = "dev.mark.app";

/// How long to wait for a launch to produce a socket before asking
/// LaunchServices again. Cold start is ~270 ms (ADR-1), so three seconds means
/// "this launch is not happening" rather than "be patient".
const RELAUNCH_AFTER_SECS: u64 = 3;

/// How many times to ask. Three: the first, and two chances for a
/// LaunchServices refusal to clear.
const MAX_LAUNCHES: u32 = 3;

/// How long to keep retrying a connection after launching the app.
///
/// Cold start to a visible rendered document measured ~270 ms (ADR-1), and the
/// socket is bound before the first paint — but a first launch after a build
/// also pays Gatekeeper's first-run checks, so the budget is generous. It is a
/// *deadline*, not a sleep: a warm app answers in microseconds.
fn launch_deadline() -> Duration {
    duration_env("MARK_IPC_LAUNCH_TIMEOUT_MS", 15_000)
}

/// How long to wait for the app to answer a command it has accepted.
///
/// Distinct from the launch deadline because it covers different work: `goto`
/// forces ADR-2's background fill to completion, which on an 8 MB document is
/// seconds rather than milliseconds.
fn reply_timeout() -> Duration {
    duration_env("MARK_IPC_TIMEOUT_MS", 30_000)
}

fn duration_env(name: &str, default_ms: u64) -> Duration {
    let ms = std::env::var(name)
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|ms| *ms > 0)
        .unwrap_or(default_ms);
    Duration::from_millis(ms)
}

/// Everything that can go wrong between here and the app.
///
/// Separate from a [`RemoteError`] on purpose: this is "could not reach the
/// app", which is worth retrying, and that is "the app said no", which is not.
#[derive(Debug)]
pub enum IpcError {
    /// The socket path would not fit in `sun_path`. ADR-3 requires this to be
    /// asserted rather than discovered via a truncated path.
    PathTooLong { path: PathBuf, length: usize },
    /// `open(1)` could not be run, or reported a failure.
    Launch { detail: String },
    /// The app never answered on the socket within the deadline.
    Unreachable {
        path: PathBuf,
        waited: Duration,
        launched: bool,
        source: std::io::Error,
    },
    /// Connected, but the conversation failed.
    Transport {
        path: PathBuf,
        source: std::io::Error,
    },
    /// The app answered with something that is not a response.
    Malformed { line: String, detail: String },
    /// The app answered, and the answer was no.
    Refused(RemoteError),
}

impl std::fmt::Display for IpcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            IpcError::PathTooLong { path, length } => write!(
                f,
                "socket path is {length} bytes and the macOS limit is {MAX_SOCKET_PATH} \
                 (sizeof sockaddr_un.sun_path is {SUN_PATH_CAPACITY}, not Linux's 108): \
                 {}. Set TMPDIR to a shorter directory.",
                path.display()
            ),
            IpcError::Launch { detail } => {
                write!(f, "could not launch mark.app: {detail}")
            }
            IpcError::Unreachable {
                path,
                waited,
                launched,
                source,
            } => write!(
                f,
                "no mark is listening on {} after {:.1}s{}: {source}",
                path.display(),
                waited.as_secs_f64(),
                if *launched {
                    " (the app was launched and never bound the socket)"
                } else {
                    ""
                }
            ),
            IpcError::Transport { path, source } => {
                write!(f, "talking to {}: {source}", path.display())
            }
            IpcError::Malformed { line, detail } => {
                write!(
                    f,
                    "the app answered with something unusable ({detail}): {line}"
                )
            }
            IpcError::Refused(error) => write!(f, "{error}"),
        }
    }
}

impl std::error::Error for IpcError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            IpcError::Unreachable { source, .. } | IpcError::Transport { source, .. } => {
                Some(source)
            }
            IpcError::Refused(error) => Some(error),
            _ => None,
        }
    }
}

impl IpcError {
    /// The exit code an agent scripts against (see `main.rs`).
    pub fn code(&self) -> u8 {
        match self {
            IpcError::Refused(error) => error.exit_code(),
            // Everything else is "we never got an answer", which is one
            // situation from the caller's point of view even though it has
            // several causes.
            _ => crate::EXIT_IPC,
        }
    }
}

/// `$TMPDIR/mark-$UID.sock`, asserted to fit.
///
/// The app computes the same string from the same two inputs (`SocketPath` in
/// `SocketServer.swift`), including the trailing-slash trim — `$TMPDIR` almost
/// always ends in `/`, and `…/T//mark-501.sock` connects fine but reads as a
/// different path in `mark doctor`, which is precisely the moment someone is
/// trying to work out why nothing is connecting.
pub fn socket_path() -> Result<PathBuf, IpcError> {
    // SAFETY: `getuid` cannot fail and touches no memory we own.
    let uid = unsafe { libc::getuid() };
    socket_path_in(std::env::var("TMPDIR").ok().as_deref(), uid)
}

/// [`socket_path`], with its two inputs passed rather than read.
///
/// Split out so the length assertion is testable without a test mutating
/// `TMPDIR` for every other test in the process — which Rust 2024 marks
/// `unsafe` precisely because it is a data race in a threaded test runner.
pub fn socket_path_in(tmpdir: Option<&str>, uid: u32) -> Result<PathBuf, IpcError> {
    let base = tmpdir.unwrap_or_default().trim_end_matches('/');
    let base = if base.is_empty() { "/tmp" } else { base };
    let path = PathBuf::from(format!("{base}/mark-{uid}.sock"));

    let length = path.as_os_str().len();
    if length > MAX_SOCKET_PATH {
        return Err(IpcError::PathTooLong { path, length });
    }
    Ok(path)
}

/// Every bundle LaunchServices has registered under [`BUNDLE_ID`], in its own
/// preference order — **the first is the one `open -g -b` launches**, and so
/// the one the cold-start path in this file reaches.
///
/// Worth a line in `mark doctor` because the bundle id, the `mark://` scheme
/// and the markdown UTIs are *machine-wide* and have exactly one winner, while
/// a development machine accumulates claimants: every assembled bundle used to
/// register one, and a registration outlives the directory it names. When the
/// winner is not the bundle this CLI lives in, `mark open` and a double-clicked
/// `.md` reach a **different build** than `mark render` does — which is a
/// confusing afternoon, and nothing else in the report would have said so.
///
/// `LSCopyApplicationURLsForBundleIdentifier` rather than parsing
/// `lsregister -dump`: the dump is the entire database and takes seconds, and
/// this is one call that answers exactly the question. It is deprecated as of
/// macOS 12 and used anyway — the successor, `NSWorkspace`'s
/// `urlsForApplications(toOpen:)`, is Objective-C and takes a URL rather than a
/// bundle id, so it cannot answer this from here. If it ever stops working the
/// failure is an empty list, which the report prints as "none" rather than
/// mistaking for a clean machine.
pub fn registered_bundles() -> Vec<PathBuf> {
    use std::ffi::OsStr;
    use std::os::raw::c_void;
    use std::os::unix::ffi::OsStrExt;

    type CFTypeRef = *const c_void;
    type CFIndex = isize;
    /// `kCFStringEncodingUTF8`.
    const UTF8: u32 = 0x0800_0100;

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringCreateWithBytes(
            allocator: CFTypeRef,
            bytes: *const u8,
            num_bytes: CFIndex,
            encoding: u32,
            is_external_representation: u8,
        ) -> CFTypeRef;
        fn CFArrayGetCount(array: CFTypeRef) -> CFIndex;
        fn CFArrayGetValueAtIndex(array: CFTypeRef, index: CFIndex) -> CFTypeRef;
        fn CFURLGetFileSystemRepresentation(
            url: CFTypeRef,
            resolve_against_base: u8,
            buffer: *mut u8,
            max_buffer_length: CFIndex,
        ) -> u8;
        fn CFRelease(cf: CFTypeRef);
    }

    #[link(name = "CoreServices", kind = "framework")]
    unsafe extern "C" {
        fn LSCopyApplicationURLsForBundleIdentifier(
            bundle_id: CFTypeRef,
            out_error: *mut CFTypeRef,
        ) -> CFTypeRef;
    }

    let mut bundles = Vec::new();

    // SAFETY: three Core Foundation calls under the Create Rule, which is the
    // whole of the contract here. `CFStringCreateWithBytes` and the `Copy…`
    // below return +1 references, and both are released on every path out —
    // including the early returns, which is why the null checks come before
    // the next allocation rather than after it. Everything from
    // `CFArrayGetValueAtIndex` is a borrow owned by the array and must not be
    // released. The buffer handed to `CFURLGetFileSystemRepresentation` is a
    // fixed `PATH_MAX` array and its length is passed with it, so the callee
    // cannot run past it; a path that does not fit returns false and is
    // skipped rather than truncated into a plausible-looking wrong path.
    unsafe {
        let identifier = CFStringCreateWithBytes(
            std::ptr::null(),
            BUNDLE_ID.as_ptr(),
            BUNDLE_ID.len() as CFIndex,
            UTF8,
            0,
        );
        if identifier.is_null() {
            return bundles;
        }
        let urls = LSCopyApplicationURLsForBundleIdentifier(identifier, std::ptr::null_mut());
        CFRelease(identifier);
        if urls.is_null() {
            // Not an error: this is what "nothing is registered" looks like,
            // and it is the honest answer on a machine that has never launched
            // mark.
            return bundles;
        }

        let count = CFArrayGetCount(urls);
        let mut buffer = [0u8; libc::PATH_MAX as usize];
        for index in 0..count {
            let url = CFArrayGetValueAtIndex(urls, index);
            if url.is_null() {
                continue;
            }
            let ok = CFURLGetFileSystemRepresentation(
                url,
                1,
                buffer.as_mut_ptr(),
                buffer.len() as CFIndex,
            );
            if ok == 0 {
                continue;
            }
            let end = buffer
                .iter()
                .position(|byte| *byte == 0)
                .unwrap_or(buffer.len());
            bundles.push(PathBuf::from(OsStr::from_bytes(&buffer[..end])));
        }
        CFRelease(urls);
    }

    bundles
}

/// The `.app` this binary lives in, if it lives in one.
///
/// ADR-1: *"`mark-cli` resolves `$0` through its symlink chain to locate the
/// enclosing `.app`, so it works when invoked from `/opt/homebrew/bin`."*
/// `current_exe` on macOS reports the path as invoked, which for a Homebrew
/// install is the symlink; `canonicalize` is what walks the chain.
pub fn app_bundle() -> Option<PathBuf> {
    if let Some(override_path) = std::env::var_os("MARK_APP") {
        let path = PathBuf::from(override_path);
        return if path.as_os_str().is_empty() {
            None
        } else {
            Some(path)
        };
    }
    let executable = std::env::current_exe().ok()?.canonicalize().ok()?;
    // …/mark.app/Contents/MacOS/mark-cli
    let macos = executable.parent()?;
    let contents = macos.parent()?;
    let bundle = contents.parent()?;
    if macos.file_name()? == "MacOS"
        && contents.file_name()? == "Contents"
        && bundle
            .extension()
            .is_some_and(|extension| extension == "app")
    {
        Some(bundle.to_path_buf())
    } else {
        None
    }
}

/// A connection attempt's outcome, for tracing and for `mark doctor`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reach {
    /// The app was already running.
    Warm,
    /// We launched it and it appeared.
    Launched,
}

/// One request, one response.
pub struct Client {
    path: PathBuf,
    /// Whether a failure to connect should launch the app. `false` for
    /// `mark doctor`, which is asking a question, not giving an order.
    launches: bool,
}

impl Client {
    pub fn new() -> Result<Client, IpcError> {
        Ok(Client {
            path: socket_path()?,
            // The escape hatch the CLI tests use so `cargo test` never puts a
            // window on screen.
            launches: std::env::var("MARK_NO_LAUNCH").map_or(true, |value| value == "0"),
        })
    }

    /// A client that will never start the app.
    pub fn probing() -> Result<Client, IpcError> {
        let mut client = Client::new()?;
        client.launches = false;
        Ok(client)
    }

    /// Send `request`, and return the app's `result` on success.
    pub fn send(&self, request: &Request) -> Result<serde_json::Value, IpcError> {
        let (mut stream, reach) = self.connect()?;
        crate::trace(
            || {
                format!(
                    "{} on {} ({})",
                    request.command,
                    self.path.display(),
                    match reach {
                        Reach::Warm => "already running",
                        Reach::Launched => "launched",
                    }
                )
            },
            Instant::now(),
        );

        stream
            .set_read_timeout(Some(reply_timeout()))
            .and_then(|()| stream.write_all(request.encode().as_bytes()))
            .and_then(|()| stream.write_all(b"\n"))
            .and_then(|()| stream.flush())
            .map_err(|source| IpcError::Transport {
                path: self.path.clone(),
                source,
            })?;

        let mut line = String::new();
        let read = BufReader::new(&stream)
            .read_line(&mut line)
            .map_err(|source| IpcError::Transport {
                path: self.path.clone(),
                source,
            })?;
        if read == 0 {
            return Err(IpcError::Transport {
                path: self.path.clone(),
                source: std::io::Error::new(
                    std::io::ErrorKind::UnexpectedEof,
                    "the app closed the connection without answering",
                ),
            });
        }

        let response: Response =
            serde_json::from_str(line.trim()).map_err(|error| IpcError::Malformed {
                line: line.trim().to_owned(),
                detail: error.to_string(),
            })?;

        if response.ok {
            return Ok(response.result);
        }
        Err(IpcError::Refused(response.error.unwrap_or(RemoteError {
            code: "internal".to_owned(),
            message: "the app refused the command without saying why".to_owned(),
            detail: Default::default(),
        })))
    }

    /// Connect, launching and retrying if nothing answers.
    fn connect(&self) -> Result<(UnixStream, Reach), IpcError> {
        let started = Instant::now();
        let first = match UnixStream::connect(&self.path) {
            Ok(stream) => return Ok((stream, Reach::Warm)),
            Err(error) => error,
        };

        // ENOENT: no socket file. ECONNREFUSED: a socket file nobody is
        // listening on — a crash left it behind. ADR-3 treats both as "not
        // running", and the app unlinks the stale node when it binds.
        let kind = first.kind();
        let recoverable = matches!(
            kind,
            std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
        );
        if !recoverable || !self.launches {
            return Err(IpcError::Unreachable {
                path: self.path.clone(),
                waited: started.elapsed(),
                launched: false,
                source: first,
            });
        }

        launch()?;
        let mut launches = 1;
        let mut relaunch_at = Duration::from_secs(RELAUNCH_AFTER_SECS);

        let deadline = launch_deadline();
        // Backoff rather than a tight spin: a cold start is ~270 ms of process
        // launch and WebKit spin-up (ADR-1), and hammering `connect()` for that
        // long is 10k syscalls to save nothing.
        let mut wait = Duration::from_millis(20);
        let mut last = first;
        while started.elapsed() < deadline {
            std::thread::sleep(wait);
            match UnixStream::connect(&self.path) {
                Ok(stream) => return Ok((stream, Reach::Launched)),
                Err(error) => last = error,
            }
            wait = std::cmp::min(wait.mul_f64(1.4), Duration::from_millis(200));

            // `open` can report success and start nothing. Reproduced on this
            // machine: rebuild `mark.app` while an instance is running, quit
            // it, and the next `open -g` exits 0 while LaunchServices quietly
            // refuses — Gatekeeper is still evaluating the rewritten bundle
            // (`syspolicyd … GK evaluateScanResult`). It clears by itself in
            // seconds, so the recovery is to ask again rather than to wait out
            // the whole deadline and fail.
            //
            // Asking again is free when the app *is* coming up: LaunchServices
            // coalesces a launch of an already-running app into an activation,
            // and `-g` makes that a no-op. This is the same reason the
            // two-CLI race needs no lock.
            if launches < MAX_LAUNCHES && started.elapsed() >= relaunch_at {
                launch()?;
                launches += 1;
                relaunch_at = started.elapsed() + Duration::from_secs(RELAUNCH_AFTER_SECS);
            }
        }
        Err(IpcError::Unreachable {
            path: self.path.clone(),
            waited: started.elapsed(),
            launched: true,
            source: last,
        })
    }
}

/// Start the app without stealing focus.
///
/// `-g` is ADR-3's, and it is load-bearing: an agent running `mark open` in a
/// loop must not keep pulling the user out of what they are doing.
///
/// The bundle is named by **path** when this binary is inside one, and by
/// bundle id otherwise. ADR-3 writes the launch as `open -g -b <bundle-id>`;
/// preferring the enclosing bundle is ADR-1's `$0` resolution applied to the
/// same step, and it removes a real footgun — with two copies of mark.app on a
/// machine, `-b` picks whichever LaunchServices prefers, so a development CLI
/// would silently drive the installed app. `-b` remains the fallback, and is
/// what a Homebrew symlink outside any bundle uses.
fn launch() -> Result<(), IpcError> {
    let mut command = Command::new("/usr/bin/open");
    command.arg("-g");
    match app_bundle() {
        Some(bundle) => {
            command.arg(&bundle);
        }
        None => {
            command.args(["-b", BUNDLE_ID]);
        }
    }
    let output = command
        .stdin(Stdio::null())
        .output()
        .map_err(|error| IpcError::Launch {
            detail: format!("running /usr/bin/open: {error}"),
        })?;
    if !output.status.success() {
        let detail = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        return Err(IpcError::Launch {
            detail: if detail.is_empty() {
                format!("open exited {}", output.status)
            } else {
                detail
            },
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What can be asserted about a machine whose LaunchServices database is
    /// not ours to arrange: that the FFI is sound and that what comes back is
    /// shaped like an answer.
    ///
    /// The count is deliberately not asserted — a CI box has no mark
    /// registered and a development machine has one, and a test that demanded
    /// either would fail on the other. What *is* worth pinning is that this
    /// returns rather than trapping (the Create Rule is hand-written above,
    /// and a double release or a missing null check would show up here under
    /// the address sanitizer), that it does not leak a truncated path, and
    /// that every entry is a real bundle path rather than whatever happened to
    /// be left in the buffer.
    #[test]
    fn registered_bundles_are_app_paths_or_nothing_at_all() {
        for path in registered_bundles() {
            assert!(
                path.is_absolute(),
                "LaunchServices handed back a relative path: {}",
                path.display()
            );
            assert_eq!(
                path.extension().and_then(|extension| extension.to_str()),
                Some("app"),
                "not a bundle: {}",
                path.display()
            );
            assert!(
                !path.as_os_str().is_empty(),
                "an empty path means the NUL scan ran off the buffer"
            );
        }
    }

    /// Called twice because the interesting failure is the *second* call: a
    /// `CFRelease` too many on the array or the string is invisible on one
    /// pass and an over-release on the next.
    #[test]
    fn registering_can_be_asked_twice() {
        assert_eq!(registered_bundles(), registered_bundles());
    }

    /// The two sides must agree byte for byte, so the trailing slash `$TMPDIR`
    /// almost always carries has to be handled the same way in both.
    #[test]
    fn the_socket_path_is_tmpdir_slash_mark_uid_sock() {
        let with = socket_path_in(Some("/tmp/marktest/"), 501).unwrap();
        let without = socket_path_in(Some("/tmp/marktest"), 501).unwrap();
        assert_eq!(with, PathBuf::from("/tmp/marktest/mark-501.sock"));
        assert_eq!(with, without, "a trailing slash changes nothing");
    }

    #[test]
    fn an_unset_tmpdir_falls_back_to_tmp() {
        assert_eq!(
            socket_path_in(None, 501).unwrap(),
            PathBuf::from("/tmp/mark-501.sock")
        );
        assert_eq!(
            socket_path_in(Some(""), 501).unwrap(),
            PathBuf::from("/tmp/mark-501.sock")
        );
    }

    #[test]
    fn a_path_over_104_bytes_is_refused_rather_than_truncated() {
        let long = format!("/tmp/{}", "d".repeat(120));
        let error = socket_path_in(Some(&long), 501).expect_err("must not truncate");
        match &error {
            IpcError::PathTooLong { length, .. } => {
                assert!(*length > MAX_SOCKET_PATH, "{length}");
            }
            other => panic!("expected PathTooLong, got {other:?}"),
        }
        assert!(error.to_string().contains("104"), "{error}");
        assert_eq!(error.code(), crate::EXIT_IPC);
    }

    /// The boundary itself, because "under 104" and "at most 104" differ by
    /// exactly the NUL terminator, which is the kind of off-by-one that binds
    /// successfully onto a path nobody else computes.
    #[test]
    fn the_limit_is_103_bytes_of_path_plus_a_nul() {
        let directory = format!(
            "/tmp/{}",
            "d".repeat(MAX_SOCKET_PATH - "/tmp//mark-501.sock".len())
        );
        let fits = socket_path_in(Some(&directory), 501).expect("103 bytes fits");
        assert_eq!(fits.as_os_str().len(), MAX_SOCKET_PATH);
        assert!(socket_path_in(Some(&format!("{directory}x")), 501).is_err());
    }

    #[test]
    fn sun_path_is_104_on_macos_not_108() {
        // `sockaddr_un` is sun_len + sun_family + sun_path.
        assert_eq!(
            SUN_PATH_CAPACITY,
            std::mem::size_of::<libc::sockaddr_un>() - 2
        );
        assert_eq!(MAX_SOCKET_PATH, 103);
    }
}
