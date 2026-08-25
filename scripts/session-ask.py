#!/usr/bin/env python3
"""One NDJSON request to a running `mark`, and the sidebar-shaped answers
`session-roundtrip.sh` compares.

A separate file rather than a heredoc inside the shell script for one reason:
the script already nests two heredocs, and a third would have to agree with them
about its terminator. A file also means this can be run by hand while debugging
a failing round trip:

    TMPDIR=/tmp/mark-session.XXXX python3 scripts/session-ask.py --state sidebar

M10 added `mark sidebar --json`, which asks the same question over the same
socket — so this script's `--state` and `--breadcrumb` shapes could now be built
by piping that through `jq`. It deliberately still speaks the socket directly,
for two reasons: what is under test is the **app's** session restore, and routing
the assertion through a second binary would let a CLI bug read as a session bug;
and `--file` has to produce the *same* shape from the session JSON, which no CLI
subcommand does. `--raw` is also how a command the CLI does not expose gets sent.

Every path is compared through `os.path.realpath`. `$TMPDIR` in that script is
under `/tmp`, which is a symlink to `/private/tmp`, and neither the app nor the
core resolves symlinks — `core/src/tree.rs` says so deliberately, *"so a
symlinked notes directory keeps the name the user typed"*. Resolving on both
sides of the comparison keeps that choice from turning into a flaky assertion.
"""

import json
import os
import socket
import sys


def socket_path() -> str:
    """ADR-3's `$TMPDIR/mark-$UID.sock`."""
    return os.path.join(os.environ.get("TMPDIR", "/tmp"), "mark-%d.sock" % os.getuid())


def ask(command: str, arguments: dict[str, str]) -> dict:
    request = {"version": 1, "id": "rt", "command": command, "arguments": arguments}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(10)
        client.connect(socket_path())
        client.sendall((json.dumps(request) + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            chunk = client.recv(65536)
            if not chunk:
                break
            data += chunk
    return json.loads(data.decode().strip())


def state_line(root: str, back: list[str], forward: list[str]) -> str:
    real = os.path.realpath
    return "%s %s | %s" % (
        real(root) if root else "<none>",
        " ".join(real(path) for path in back),
        " ".join(real(path) for path in forward),
    )


def breadcrumb_line(root: str) -> str:
    """The crumbs the app will show for `root`.

    Deliberately **not** realpath'd, unlike `state_line`. The breadcrumb is what
    the user reads, and it shows the path they typed: `/tmp/x`, not
    `/private/tmp/x`. That is `Navigator.normalize`'s documented choice, made to
    match `core/src/tree.rs`, so the expectation has to be built the same way.
    """
    parts = [part for part in root.split("/") if part]
    return " ".join(["/"] + parts)


def main(argv: list[str]) -> int:
    mode = argv[0] if argv else ""

    # Expectations, computed here so the shell script and the app are compared
    # through exactly one formatter.
    if mode == "--expect-state":
        print(state_line(argv[1], [argv[2]], [argv[3]]))
        return 0
    if mode == "--expect-breadcrumb":
        print(breadcrumb_line(argv[1]))
        return 0

    # The session *file*, in the same shape as the live answer.
    if mode == "--file":
        try:
            with open(argv[1]) as handle:
                session = json.load(handle)
        except (OSError, ValueError):
            print("<unreadable>")
            return 0
        print(
            state_line(
                session.get("sidebarRoot") or "",
                session.get("sidebarBack") or [],
                session.get("sidebarForward") or [],
            )
        )
        return 0

    shape = None
    if mode in ("--state", "--breadcrumb", "--raw"):
        shape = mode
        argv = argv[1:]

    if not argv:
        print("usage: session-ask.py [--state|--breadcrumb|--raw] <command> [k=v ...]", file=sys.stderr)
        return 2

    arguments = {}
    for pair in argv[1:]:
        key, _, value = pair.partition("=")
        arguments[key] = value

    try:
        response = ask(argv[0], arguments)
    except (OSError, ValueError) as error:
        print("<unreachable:%s>" % error)
        return 0

    if shape is None or shape == "--raw":
        print(json.dumps(response, sort_keys=True))
        return 0 if response.get("ok") else 1

    if not response.get("ok"):
        print("<error:%s>" % response.get("error", {}).get("code", "?"))
        return 1

    sidebar = response["result"]["sidebar"]
    if shape == "--breadcrumb":
        print(" ".join(sidebar["breadcrumb"]))
    else:
        print(state_line(sidebar["root"], sidebar["back"], sidebar["forward"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
