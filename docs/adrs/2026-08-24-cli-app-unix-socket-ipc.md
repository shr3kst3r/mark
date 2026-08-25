---
id: 2026-08-24-cli-app-unix-socket-ipc
status: Accepted
supersedes: null
superseded-by: null
components: [cli, app, ipc]
ticket: null
date: 2026-08-24
---
# Talk to the running app over a Unix socket in $TMPDIR, and cold-start it through a mark:// URL

## Context

The CLI must drive a running GUI instance — open a file in a new tab, set the
theme, scroll to an anchor — and launch the app first if it is not running. Cold
start costs ~270 ms, almost all of it process launch and WebKit spin-up, so a
resident app that the CLI signals is worth far more than a process per
invocation. That makes the transport a load-bearing choice rather than an
incidental one.

Two hard constraints shaped the evaluation:

1. **No user-facing consent prompts.** A tool invoked by an agent cannot stop to
   ask permission.
2. **Must work ad-hoc-signed.** Local development builds have no Developer ID and
   no Team ID.

Six mechanisms were evaluated. Only one combination satisfies both constraints:

| Mechanism | Verdict |
|---|---|
| **Unix domain socket** | ~50–200 µs round trip, no signing requirement, no prompt, and a real reply channel. |
| XPC / `NSXPCConnection` | A named Mach endpoint requires a launchd job. `SMAppService` makes the **user approve a Login Item in System Settings** — a consent step by definition. Also carries well-documented `kSMErrorInvalidPlist` failures even when fully notarized. |
| Apple Events | Raises a TCC prompt ("«Terminal» wants to control «mark»"). Exempt only for same-Team-ID targets — and an ad-hoc build has no Team ID, so the prompt fires *precisely* during development. |
| Custom URL scheme via LaunchServices | No prompt, no signing requirement, and launches the app if needed. But fire-and-forget: no reply channel. |
| Distributed notifications | **Dropped when the receiver is busy.** Disqualifying for "open this file". Sandboxed senders also lose `userInfo` entirely. |
| `NSPasteboard` | No delivery event at all, and macOS 15.4+/26 added programmatic-read paste protection. |

Two traps were found that are invisible until they bite. `sun_path` is **104
bytes on macOS**, not Linux's 108 (`sys/un.h:79`) — container paths routinely
exceed it. And macOS 15+ raises a "would like to access data from other apps"
TCC prompt when a non-sandboxed process touches another bundle's container, so a
socket under `~/Library/Containers` reintroduces exactly the prompt we are
avoiding.

The URL scheme and the socket are complementary rather than competing: the socket
has a reply channel but cannot start a process, and LaunchServices can start a
process but cannot reply.

## Decision

The app binds a Unix domain socket at `$TMPDIR/mark-$UID.sock` on launch, mode
`0600`, unlinking any stale socket first. The protocol is newline-delimited JSON,
request/response, so the CLI can surface real errors — "anchor not found" exits
non-zero rather than silently succeeding. The app verifies the peer's uid via
`LOCAL_PEERCRED` and rejects anything else.

The app is **not sandboxed**.

`mark-cli` connects and sends its command. On `ENOENT` or `ECONNREFUSED` it
treats the app as not running: it launches via `open -g -b <bundle-id>`
(`-g` so focus is not stolen), then retries the connection with backoff until the
socket appears.

We also register a `mark://` URL scheme in `CFBundleURLTypes` and handle it in
`application(_:open:)`. It carries the initial request atomically on cold launch,
and it is the entry point for Finder, browsers, and other applications.

## Consequences

**Easier.** Sub-millisecond command latency with a genuine reply channel, so the
CLI can report failures instead of guessing. Zero consent prompts and zero
codesigning requirements means `codesign -s -` dev builds work identically to
released ones — no class of bug that only appears unsigned, and no prompt
interrupting an agent mid-task. This is the same design VS Code's `code` and
`kitty @` use, so the failure modes are well-charted.

**Harder, and we are accepting it.** We own a wire protocol: framing, versioning,
and the compatibility question when a new CLI meets an old running app. We own
socket lifecycle — stale sockets after a crash, the race where two CLI
invocations both find no socket and both launch the app, and the absence of any
notification when the app dies mid-request. Ordering across concurrent
invocations is our problem, not the transport's. And there are now **two** entry
paths into the same commands (socket and URL), which must not drift; the URL
handler should parse into the same command type the socket decodes to.

**We are accepting not being sandboxed.** That forecloses the Mac App Store and
means we do not get the App Sandbox's containment. For a local developer tool
reading files the user points it at, that is the right trade — but it is a real
one, and reversing it later is not a small change: it would move the socket,
reintroduce the container TCC prompt, and require the LaunchServices path for
file access.

Constraints this imposes on future work:

- **The socket path stays out of `~/Library/Containers`, `~/Library/Application
  Support/<bundle-id>`, and `~/Library/Group Containers`.** Any of those
  reintroduces the macOS 15+ App Data prompt.
- **The full socket path must stay under 104 bytes.** Assert this at startup
  rather than discovering it via a truncated path.
- **No feature may depend on Apple Events, XPC, or distributed notifications**
  for CLI↔app communication. Each was rejected for a specific reason above; using
  one anyway silently reintroduces a prompt or drops messages.
- **Every socket command carries a protocol version,** and the app must respond
  intelligibly to a version it does not know.
- **The socket is uid-scoped and single-user.** Nothing here is a
  security boundary against other users on the machine beyond file permissions
  and the peer-uid check.
- **`mark://` stays registered even if the socket becomes the only transport
  used in practice** — it is the cold-launch and Finder path.

## Alternatives considered

- **XPC via `SMAppService`.** The Apple-blessed IPC mechanism, with typed
  interfaces and `setCodeSigningRequirement` peer authentication. Rejected: a
  named Mach service requires a launchd agent, whose registration requires the
  user to approve a Login Item in System Settings. That is the consent prompt we
  are explicitly avoiding, and the plist-loading failures reported even for
  notarized apps make it fragile on top.
- **`NSXPCListener.anonymousListener()`.** Avoids launchd entirely. Rejected as
  circular: `NSXPCListenerEndpoint` can only be transferred over an existing XPC
  connection, so it needs a bootstrap channel — which is the problem we were
  solving.
- **Apple Events only.** The traditional macOS answer, and genuinely exempt from
  the TCC gate for same-Team-ID senders. Rejected because ad-hoc dev builds have
  no Team ID, so the prompt appears during exactly the workflow we care most
  about.
- **URL scheme only.** Simplest possible design, no socket lifecycle, no
  protocol. Genuinely tempting. Rejected because it is fire-and-forget: the CLI
  could never report that a file failed to parse or an anchor did not exist, and
  an agent needs a non-zero exit code to react to. Kept as the cold-launch half
  of the design.
- **A local HTTP server on a TCP port.** Trivially debuggable with `curl`.
  Rejected: binds a port other processes on the machine can reach, needs port
  discovery or a fixed port that can collide, and gains nothing over a socket for
  a same-machine single-user tool.
- **A file-drop directory the app watches.** No protocol, no socket. Rejected:
  we already own a file watcher, but latency is debounce-bound, there is no reply
  channel, and it turns every CLI invocation into filesystem garbage to clean up.
