#!/usr/bin/env bash
#
# ADR-4's session gate, across a real quit and relaunch.
#
#   > Session state is persisted to our own JSON file rather than relying on
#   > `NSWindowRestoration`, so restore is deterministic regardless of the
#   > user's "Close windows when quitting an app" setting.
#
# `mark-bench` covers the in-process half — snapshot, write, read, restore into
# a fresh controller. What it cannot cover is the part the ADR is actually
# about: that a *second launch of the process* comes back with the same tabs.
# So this is a script rather than a recipe body, per plan §6: multi-process
# checks are real scripts.
#
# ---------------------------------------------------------------------------
# Why this looks different from the version M3 shipped, which was flaky.
#
# That version launched the app with three files, waited for a session file to
# appear, slept two seconds, killed the app, and compared the file against
# whatever a second launch wrote. Three separate races, and the observed
# symptom was launch 1 recording a different `selectedIndex` between runs:
#
#   * **The selection was implicit.** It was whatever the last command-line
#     file happened to leave selected, so *any* other code path that touches
#     the selection — now or later — silently changes what the test asserts,
#     and the test cannot tell that from a restore bug.
#   * **The wait was for the wrong event.** `[[ -s session.json ]]` is true as
#     soon as the *first* debounced save lands. Saves are coalesced on a 500 ms
#     timer and rescheduled by every subsequent tab change, so the file can be
#     read mid-sequence, and the `sleep 2` that followed was a guess about how
#     long the rest would take on a loaded machine.
#   * **The assertion was relative.** Comparing launch 2's file to launch 1's
#     passes if both launches are wrong in the same way.
#
# All three are gone. M4's socket (`2026-08-24-cli-app-unix-socket-ipc`) makes
# the selection an instruction rather than a side effect: `mark tab select`
# picks a specific tab, and the script then waits for that exact state to
# appear in the session file — an event, not an interval. Both launches are
# checked against a constant, so "wrong in the same way twice" fails.
#
# Usage: scripts/session-roundtrip.sh <path-to-mark-executable> [path-to-mark-cli]

set -euo pipefail

mark_bin="${1:?usage: session-roundtrip.sh <path-to-mark-executable> [mark-cli]}"
[[ -x "${mark_bin}" ]] || { echo "not executable: ${mark_bin}" >&2; exit 2; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cli_bin="${2:-${root}/target/release/mark-cli}"
[[ -x "${cli_bin}" ]] || {
    echo "not executable: ${cli_bin} — run 'cargo build --release' first" >&2
    exit 2
}

# Short, and ours. The socket is `$TMPDIR/mark-$UID.sock`, so a private $TMPDIR
# keeps this run off the developer's own socket entirely — and keeps the path
# far inside ADR-3's 104-byte limit, which `/var/folders/...` plus a mktemp
# suffix does not always do.
work="$(mktemp -d /tmp/mark-session.XXXXXX)"
export TMPDIR="${work}"
session="${work}/session.json"
trap 'rm -rf "${work}"' EXIT

# The tab this run pins the selection to. Deliberately the middle one: it is
# neither "the last file on the command line" (which is what launch 1 would
# select on its own) nor "the first row in the sidebar", so a stray selection
# from either direction shows up as a failure instead of coinciding with the
# expected value.
select_index=1
expected="alpha.md beta.md gamma.md ${select_index}"

for name in alpha beta gamma; do
    printf '# %s\n\n- [ ] a task in %s\n\n%s\n' \
        "${name}" "${name}" "$(head -c 2000 /dev/urandom | base64)" > "${work}/${name}.md"
done

# --- M8: the sidebar half -------------------------------------------------
#
# Plan section 2's M8 gate is "breadcrumb and history survive a session
# restore", and the breadcrumb is derived from the root, so what actually has to
# survive is the root **plus both history stacks**. A run that only moved the
# root would pass against an implementation that saved the root and dropped the
# history, which is precisely the bug worth catching: the app comes back in the
# right place with Cmd-[ pointing at nothing.
#
# So launch 1 is driven into a state no single navigation produces:
#
#   nav path=<work>/sub   root=<work>/sub   back=[<work>]        forward=[]
#   nav to=parent         root=<work>       back=[<work>, sub]   forward=[]
#   nav to=back           root=<work>/sub   back=[<work>]        forward=[<work>]
#
# Both stacks non-empty and different, which no "save the root" shortcut
# reproduces.
mkdir -p "${work}/sub"
printf '# nested\n\n- [ ] a task\n' > "${work}/sub/nested.md"
expected_root="${work}/sub"
expected_back="${work}"
expected_forward="${work}"

# One NDJSON request over ADR-3's socket, because `mark-cli` has no subcommand
# for `nav` yet: the app's command surface grew in M8 and `cli/` belongs to
# another milestone. The transport is the real one either way -- same socket,
# same CommandRouter, same Command type, so this exercises the path the CLI
# will use rather than a side door.
ask() {
    python3 "${root}/scripts/session-ask.py" "$@"
}

# The sidebar's live state as "<root> <back...> | <forward...>", with every path
# realpath'd: $TMPDIR here is under /tmp, which is a symlink to /private/tmp,
# and neither the app nor the core resolves symlinks (deliberately -- see
# core/src/tree.rs). Comparing resolved paths on both sides keeps that
# deliberate choice from making this check flaky.
sidebar_state() {
    ask --state sidebar
}

sidebar_breadcrumb() {
    ask --breadcrumb sidebar
}

expected_sidebar="$(python3 "${root}/scripts/session-ask.py" --expect-state \
    "${expected_root}" "${expected_back}" "${expected_forward}")"
expected_breadcrumb="$(python3 "${root}/scripts/session-ask.py" --expect-breadcrumb \
    "${expected_root}")"

# `MARK_NO_SESSION` is deliberately NOT set here: this is the one check that
# wants the session machinery live.
launch() {
    MARK_SESSION_FILE="${session}" MARK_TRACE=0 "${mark_bin}" "$@" >/dev/null 2>&1 &
    echo $!
}

# The app is up and answering on its socket.
wait_for_app() {
    for _ in $(seq 1 80); do
        if "${cli_bin}" doctor --json 2>/dev/null | grep -q '"app_running": true'; then
            return 0
        fi
        sleep 0.25
    done
    return 1
}

# The sidebar half of the session file, in the same shape `sidebar_state`
# reports from the running app, so the file and the live app can be compared
# against one constant rather than against each other.
read_session_sidebar() {
    python3 "${root}/scripts/session-ask.py" --file "${session}"
}

# What the session file says, as "<files...> <selectedIndex>".
read_session() {
    python3 - "${session}" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as handle:
        state = json.load(handle)
except (OSError, ValueError):
    print("<unreadable>")
    sys.exit(0)
print(" ".join(tab["path"].rsplit("/", 1)[-1] for tab in state["tabs"]),
      state.get("selectedIndex"))
PY
}

# Wait for the *save to land*, not for a fixed interval. Saves are debounced
# 500 ms and rescheduled by every tab change, so the only safe signal that the
# app has finished writing what we asked for is the file saying it.
wait_for_session() {
    local want="$1"
    for _ in $(seq 1 80); do
        [[ "$(read_session)" == "${want}" ]] && return 0
        sleep 0.25
    done
    return 1
}

# The sidebar half of the same wait: the save is debounced and rescheduled by
# every navigation, so the only safe signal is the file saying what we asked
# for.
wait_for_session_sidebar() {
    local want="$1"
    for _ in $(seq 1 80); do
        [[ "$(read_session_sidebar)" == "${want}" ]] && return 0
        sleep 0.25
    done
    return 1
}

stop() {
    local pid="$1"
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
}

echo "session round trip — a real quit and relaunch"
echo "  session file: ${session}"

# --- launch 1: three documents, then an explicit selection ----------------
pid=$(launch "${work}/alpha.md" "${work}/beta.md" "${work}/gamma.md")
if ! wait_for_app; then
    echo "  FAIL  the first launch never answered on its socket" >&2
    stop "${pid}"
    exit 1
fi

"${cli_bin}" tab select "${select_index}" >/dev/null || {
    echo "  FAIL  could not select tab ${select_index}" >&2
    stop "${pid}"
    exit 1
}

if ! wait_for_session "${expected}"; then
    echo "  FAIL  launch 1 never wrote the state it was told to hold" >&2
    echo "          wanted ${expected}" >&2
    echo "          got    $(read_session)" >&2
    stop "${pid}"
    exit 1
fi
first_tabs="$(read_session)"
echo "  after launch 1: ${first_tabs}"
echo "  ok    the tab selected over the socket is the one that was saved"

# --- launch 1, part two: move the sidebar's root around (M8) --------------
#
# Three navigations, so both history stacks end up non-empty and holding
# different things. Each one is checked for a non-zero exit, because ADR-3's
# whole reason for a reply channel is that a refusal is reportable.
for step in "path=${work}/sub" "to=parent" "to=back"; do
    reply="$(ask --raw nav "${step}")" || {
        echo "  FAIL  nav ${step} was refused: ${reply}" >&2
        stop "${pid}"
        exit 1
    }
done

live_sidebar="$(sidebar_state)"
live_breadcrumb="$(sidebar_breadcrumb)"
echo "  sidebar live:   ${live_sidebar}"
echo "  breadcrumb:     ${live_breadcrumb}"

if ! wait_for_session_sidebar "${expected_sidebar}"; then
    echo "  FAIL  launch 1 never wrote the sidebar state it was told to hold" >&2
    echo "          wanted ${expected_sidebar}" >&2
    echo "          got    $(read_session_sidebar)" >&2
    stop "${pid}"
    exit 1
fi
first_sidebar="$(read_session_sidebar)"
echo "  ok    the root and both history stacks reached the session file"
stop "${pid}"

# --- launch 2: no arguments at all ---------------------------------------
#
# The check is deliberately indirect, and worth explaining, because "the file
# still says the same thing" sounds weaker than it is. The app rewrites the
# session file from its live `TabStore` whenever the tab list changes. So if
# the second launch had failed to restore, it would have rewritten the file
# with an empty or one-tab list. The file still naming all three documents, in
# order, with the same selection, after a launch that was given no arguments at
# all, is only possible if the restore populated the store.
pid=$(launch)
if ! wait_for_app; then
    echo "  FAIL  the second launch never answered on its socket" >&2
    stop "${pid}"
    exit 1
fi

# The live state, straight out of the running app rather than out of a file it
# may not have rewritten yet. This is the stronger assertion: it is what the
# user would see on screen.
live="$("${cli_bin}" tab list --json | python3 -c '
import json, sys
tabs = json.load(sys.stdin)
selected = next((tab["index"] for tab in tabs if tab["selected"]), None)
print(" ".join(tab["path"].rsplit("/", 1)[-1] for tab in tabs), selected)
')"
echo "  restored live:  ${live}"

# The sidebar, straight out of the relaunched app. This is the M8 gate: the
# process was given no arguments at all, so a root of <work>/sub with a
# one-entry back stack and a one-entry forward stack can only have come from
# the session file — and the breadcrumb is read from the running app rather
# than recomputed here, because it is what the user actually sees.
restored_sidebar="$(sidebar_state)"
restored_breadcrumb="$(sidebar_breadcrumb)"
echo "  sidebar live:   ${restored_sidebar}"
echo "  breadcrumb:     ${restored_breadcrumb}"
stop "${pid}"

second_tabs="$(read_session)"
second_sidebar="$(read_session_sidebar)"
echo "  after launch 2: ${second_tabs}"

status=0
if [[ "${live}" == "${expected}" ]]; then
    echo "  ok    the relaunched app restored the tab order and the selection"
else
    echo "  FAIL  the relaunched app came back with different tabs:" >&2
    echo "          wanted ${expected}" >&2
    echo "          got    ${live}" >&2
    status=1
fi

# Both launches against a constant, not against each other: two launches wrong
# in the same way must not pass.
if [[ "${first_tabs}" == "${expected}" && "${second_tabs}" == "${expected}" ]]; then
    echo "  ok    both launches wrote exactly the expected session"
else
    echo "  FAIL  a launch wrote something other than the expected session:" >&2
    echo "          wanted ${expected}" >&2
    echo "          launch 1 ${first_tabs}" >&2
    echo "          launch 2 ${second_tabs}" >&2
    status=1
fi

# --- M8's gate: root, breadcrumb, and history survive the relaunch --------
if [[ "${restored_sidebar}" == "${expected_sidebar}" ]]; then
    echo "  ok    the relaunched app restored the root and both history stacks"
else
    echo "  FAIL  the relaunched app's sidebar came back different:" >&2
    echo "          wanted ${expected_sidebar}" >&2
    echo "          got    ${restored_sidebar}" >&2
    status=1
fi

if [[ "${restored_breadcrumb}" == "${expected_breadcrumb}" ]]; then
    echo "  ok    the breadcrumb bar shows the restored root's components"
else
    echo "  FAIL  the restored breadcrumb is wrong:" >&2
    echo "          wanted ${expected_breadcrumb}" >&2
    echo "          got    ${restored_breadcrumb}" >&2
    status=1
fi

# Both launches against a constant, for the sidebar as well as the tabs: an app
# that restored nothing and then rewrote the file from its own empty state
# would otherwise agree with itself.
if [[ "${first_sidebar}" == "${expected_sidebar}" && "${second_sidebar}" == "${expected_sidebar}" ]]; then
    echo "  ok    both launches wrote exactly the expected sidebar state"
else
    echo "  FAIL  a launch wrote something other than the expected sidebar state:" >&2
    echo "          wanted ${expected_sidebar}" >&2
    echo "          launch 1 ${first_sidebar}" >&2
    echo "          launch 2 ${second_sidebar}" >&2
    status=1
fi

# The other half of the constraint: we must never have written the user
# preference that AppKit's own restoration mechanism reads.
if defaults read -g NSQuitAlwaysKeepsWindows >/dev/null 2>&1; then
    echo "  note  NSQuitAlwaysKeepsWindows is set in this user's defaults (by System"
    echo "        Settings, not by us) — restore worked regardless, which is the point."
else
    echo "  ok    NSQuitAlwaysKeepsWindows is unset, and restore worked anyway"
fi

exit "${status}"
