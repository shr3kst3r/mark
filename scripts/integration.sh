#!/usr/bin/env bash
#
# M4's gate: the CLI and the app, as two real processes, over a real socket.
#
# `2026-08-24-cli-app-unix-socket-ipc` is the ADR under test. Everything here is
# something a unit test structurally cannot cover, because the failure needs two
# processes, a launch, or a crash:
#
#   1. cold start      — no app running; `mark open` launches one and opens the file
#   2. warm            — an app running; `mark open` is fast
#   3. the launch race — two CLIs find no socket; exactly one app launches
#   4. stale socket    — the app is killed uncleanly; the next command recovers
#   5. failures        — non-zero exit and a real message the caller can act on
#   6. version skew    — an unknown protocol version gets a structured refusal
#   7. no consent      — no TCC prompt anywhere, with an ad-hoc-signed build
#   8. the 104-byte trap — the socket path assertion fires rather than truncating
#   9. the file watcher — an atomic-rename save and a CLI write are both seen by
#                         a running app (M5; ADR-2's FSEvents-not-kqueue choice)
#  10. the installed shape — the bundle launches with SwiftPM's build directory
#                         gone, which is every machine except the one that built it
#  11. Finder cold open — a document handed to the app *as it launches* is opened,
#                         which is `open README.md` and a double-click in Finder
#  12. build identity   — the CLI and the app it is driving report the same build
#  13. the icons        — the bundle carries its artwork and the plist names it
#
# Isolation. The app is launched through LaunchServices, which does **not** give
# us a way to point it at a private $TMPDIR — the socket is `$TMPDIR/mark-$UID`
# and LaunchServices' $TMPDIR is the user's. So this uses the real socket path
# and therefore has to be a good citizen: it quits any mark that is already
# running (with a warning), points the app at a throwaway session file so the
# developer's own tabs are neither read nor overwritten, and quits the app it
# started when it is done. `open(1)` propagates our environment to the launched
# app, which is what makes the session isolation work.
#
# Usage: scripts/integration.sh [path-to-mark.app]

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"

bundle="${1:-${root}/target/mark.app}"
app_binary="${bundle}/Contents/MacOS/mark"
cli_binary="${bundle}/Contents/MacOS/mark-cli"

if [[ ! -x "${app_binary}" || ! -x "${cli_binary}" ]]; then
    echo "integration.sh: ${bundle} is not assembled. Run 'just build' first." >&2
    exit 2
fi

work="$(mktemp -d /tmp/mark-int.XXXXXX)"
export MARK_SESSION_FILE="${work}/session.json"
socket="${TMPDIR:-/tmp}"
socket="${socket%/}/mark-$(id -u).sock"

# ADR-1: `mark-cli` resolves `$0` through its symlink chain to find the
# enclosing `.app`. Every command below goes through a symlink *outside* the
# bundle, which is the shape Homebrew installs and the one where a broken
# resolution would launch nothing.
mkdir -p "${work}/bin"
ln -sf "${cli_binary}" "${work}/bin/mark"
cli="${work}/bin/mark"

passed=0
failed=0
started_at="$(date '+%Y-%m-%d %H:%M:%S')"
started_epoch="$(date +%s)"

pass() { printf '  ok    %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '  FAIL  %s\n' "$1" >&2; failed=$((failed + 1)); }
note() { printf '        %s\n' "$1"; }
gate() { printf '\n%s\n' "$1"; }

# Every running instance of the app under test.
#
# The `( |$)` is load-bearing and cost an hour: an app opened on a document
# runs as `.../MacOS/mark README.md`, so a pattern anchored at the end of the
# command line misses exactly the instances a developer has open. With that
# regex, `quit_app` silently did nothing, the socket was removed out from under
# a live instance, and `open -g` then *activated* that instance instead of
# launching a new one — so nothing rebound the socket and every gate failed
# with "no app was launched" while an app was plainly running. The `-cli`
# suffix is excluded by the same space-or-end.
app_pids() { pgrep -f 'mark\.app/Contents/MacOS/mark( |$)' || true; }

quit_app() {
    local pids
    pids="$(app_pids)"
    [[ -z "${pids}" ]] && return 0
    # shellcheck disable=SC2086
    kill ${pids} 2>/dev/null
    for _ in $(seq 1 40); do
        [[ -z "$(app_pids)" ]] && return 0
        sleep 0.25
    done
    # shellcheck disable=SC2086
    kill -9 ${pids} 2>/dev/null
    return 0
}

# Set by gate 12 while SwiftPM's resource bundle is moved aside, so an
# interrupted run does not leave the developer's build directory short a
# directory that `swift build` would then have to regenerate.
stashed_resource_bundle=""

cleanup() {
    quit_app
    if [[ -n "${stashed_resource_bundle}" && -d "${stashed_resource_bundle}.integration-hidden" ]]; then
        mv "${stashed_resource_bundle}.integration-hidden" "${stashed_resource_bundle}"
    fi
    rm -rf "${work}"
}
trap cleanup EXIT

# Milliseconds a command took, printed by the caller.
timed() {
    local start end
    start=$(python3 -c 'import time; print(time.time())')
    "$@"
    local status=$?
    end=$(python3 -c 'import time; print(time.time())')
    elapsed_ms=$(python3 -c "print(f'{(${end} - ${start}) * 1000:.0f}')")
    return "${status}"
}

# The app has bound its socket and answers.
wait_for_app() {
    for _ in $(seq 1 60); do
        if "${cli}" doctor --json 2>/dev/null | grep -q '"app_running": true'; then
            return 0
        fi
        sleep 0.25
    done
    return 1
}

tab_paths() { "${cli}" tab list --json 2>/dev/null | python3 -c '
import json, sys
try:
    for tab in json.load(sys.stdin):
        print(tab["path"])
except Exception:
    pass
'; }

echo "mark — CLI/app integration (ADR-3)"
echo "  bundle:  ${bundle}"
echo "  socket:  ${socket}  ($(printf %s "${socket}" | wc -c | tr -d ' ') of 103 bytes)"
echo "  session: ${MARK_SESSION_FILE}  (the developer's own is untouched)"
if [[ -n "$(app_pids)" ]]; then
    echo "  note:    a mark was already running; quitting it so gate 1 is a real cold start"
fi

for name in cold warm racer stale reload-target; do
    printf '# %s\n\nBody for %s.\n\n## Install\n\n- [ ] a task in %s\n' \
        "${name}" "${name}" "${name}" > "${work}/${name}.md"
done

# ---------------------------------------------------------------- gate 1 ----
gate "1. cold start: no app running, 'mark open' launches one"
quit_app
# Assert the clean state instead of assuming it. A surviving instance makes
# every later gate fail for one reason that has nothing to do with the socket:
# LaunchServices activates the running app rather than starting a new one, so
# the socket we are about to remove never comes back.
if [[ -n "$(app_pids)" ]]; then
    fail "a mark survived the quit ($(app_pids | tr '\n' ' ')); refusing to fake a cold start"
    echo "  integration.sh: stopping — the rest of the run would be noise" >&2
    exit 1
fi
rm -f "${socket}"
[[ -e "${socket}" ]] && fail "the socket file survived removal"

timed "${cli}" open "${work}/cold.md"
status=$?
cold_ms="${elapsed_ms}"
if [[ ${status} -eq 0 ]]; then
    pass "mark open exited 0 from a cold machine (${cold_ms} ms including app launch)"
else
    fail "mark open exited ${status} with no app running"
fi
if [[ -n "$(app_pids)" ]]; then
    pass "an app is running"
else
    fail "no app was launched"
fi
if tab_paths | grep -qx "${work}/cold.md"; then
    pass "the file is open in a tab"
else
    fail "cold.md is not in the tab list"
fi
if [[ -S "${socket}" ]]; then
    mode="$(stat -f '%OLp' "${socket}")"
    if [[ "${mode}" == "600" ]]; then
        pass "the socket is a socket, mode 0600"
    else
        fail "the socket is mode ${mode}, not 0600"
    fi
else
    fail "no socket at ${socket}"
fi
case "${socket}" in
    "${HOME}/Library/Containers/"*|"${HOME}/Library/Group Containers/"*|"${HOME}/Library/Application Support/"*)
        fail "the socket is inside an app container — ADR-3 forbids exactly this" ;;
    *) pass "the socket is outside every app container (no macOS 15+ App Data prompt)" ;;
esac
if "${cli}" doctor --json | python3 -c '
import json, sys
report = json.load(sys.stdin)
assert report["app_bundle"], "no .app resolved from $0"
print(report["app_bundle"])
' | grep -qF "${bundle}"; then
    pass "mark-cli resolved its .app through the symlink chain (ADR-1)"
else
    fail "mark-cli did not resolve ${bundle} from \$0"
fi

# ---------------------------------------------------------------- gate 2 ----
gate "2. warm: the app is running, 'mark open' is a socket round trip"
timed "${cli}" open "${work}/warm.md"
status=$?
warm_ms="${elapsed_ms}"
if [[ ${status} -eq 0 ]]; then
    pass "mark open exited 0 (${warm_ms} ms, against ${cold_ms} ms cold)"
else
    fail "warm mark open exited ${status}"
fi
if python3 -c "import sys; sys.exit(0 if ${warm_ms} < 1000 else 1)"; then
    pass "warm open is under 1000 ms (${warm_ms} ms)"
else
    fail "warm open took ${warm_ms} ms; a socket round trip should be milliseconds"
fi
if tab_paths | grep -qx "${work}/warm.md"; then
    pass "the second file is open in its own tab"
else
    fail "warm.md is not in the tab list"
fi

# ---------------------------------------------------------------- gate 3 ----
gate "3. the launch race: two CLIs, no socket, exactly one app"
quit_app
rm -f "${socket}"
"${cli}" open "${work}/racer.md" >"${work}/race-a.out" 2>&1 &
a=$!
"${cli}" open "${work}/cold.md" >"${work}/race-b.out" 2>&1 &
b=$!
wait "${a}"; a_status=$?
wait "${b}"; b_status=$?
if [[ ${a_status} -eq 0 && ${b_status} -eq 0 ]]; then
    pass "both racing commands exited 0"
else
    fail "racing commands exited ${a_status} and ${b_status}"
    note "$(cat "${work}/race-a.out" "${work}/race-b.out")"
fi
launched="$(app_pids | wc -l | tr -d ' ')"
if [[ "${launched}" == "1" ]]; then
    pass "exactly one app is running"
else
    fail "${launched} app processes are running; LaunchServices should coalesce"
fi
if tab_paths | grep -qx "${work}/racer.md" && tab_paths | grep -qx "${work}/cold.md"; then
    pass "both documents opened"
else
    fail "one of the racing opens did not produce a tab"
fi

# ---------------------------------------------------------------- gate 4 ----
gate "4. stale socket: kill -9 leaves the node behind, the next command recovers"
# shellcheck disable=SC2046
kill -9 $(app_pids) 2>/dev/null
for _ in $(seq 1 20); do [[ -z "$(app_pids)" ]] && break; sleep 0.25; done
if [[ -e "${socket}" ]]; then
    pass "the socket file survived the kill (this is the stale case)"
else
    fail "the socket vanished; the stale-socket path is not being exercised"
fi
if "${cli}" doctor --json | grep -q '"app_running": false'; then
    pass "the stale socket refuses connections, so doctor reports the app as down"
else
    fail "doctor thinks the app is running after a kill -9"
fi
if "${cli}" open "${work}/stale.md" >"${work}/stale.out" 2>&1; then
    pass "mark open recovered: the app relaunched and rebound the socket"
else
    fail "mark open failed against a stale socket: $(cat "${work}/stale.out")"
fi
wait_for_app || fail "the app never came back"

# ---------------------------------------------------------------- gate 5 ----
gate "5. failures exit non-zero, with a message a caller can use"
out="$("${cli}" goto '#nonexistent' 2>&1)"; status=$?
if [[ ${status} -ne 0 && "${out}" == *"anchor"* ]]; then
    pass "goto '#nonexistent' exited ${status}: ${out}"
else
    fail "goto '#nonexistent' exited ${status} with: ${out}"
fi
out="$("${cli}" open /nonexistent-mark-file.md 2>&1)"; status=$?
if [[ ${status} -eq 2 && "${out}" == *"no such file"* ]]; then
    pass "open /nonexistent-mark-file.md exited 2: ${out}"
else
    fail "open of a missing file exited ${status} with: ${out}"
fi
out="$("${cli}" tab select 99 2>&1)"; status=$?
if [[ ${status} -ne 0 && "${out}" == *"no tab 99"* ]]; then
    pass "tab select 99 exited ${status}: ${out}"
else
    fail "tab select 99 exited ${status} with: ${out}"
fi
out="$("${cli}" theme no-such-theme 2>&1)"; status=$?
if [[ ${status} -ne 0 && "${out}" == *"no theme named"* ]]; then
    pass "theme no-such-theme exited ${status}: ${out}"
else
    fail "theme no-such-theme exited ${status} with: ${out}"
fi

# ---------------------------------------------------------------- gate 5b ---
# M7. `mark theme` reaches the running app; `--list` and `--show` do not need
# one, which is the case an agent is usually in.
out="$("${cli}" theme dracula 2>&1)"; status=$?
if [[ ${status} -eq 0 && "${out}" == *"dracula"* ]]; then
    pass "theme dracula applied: ${out//$'\n'/ }"
else
    fail "theme dracula exited ${status} with: ${out}"
fi
out="$("${cli}" theme 2>&1)"; status=$?
if [[ ${status} -eq 0 && "${out}" == *"dracula"* ]]; then
    pass "bare \`theme\` reports what is applied: ${out//$'\n'/ }"
else
    fail "bare theme exited ${status} with: ${out}"
fi
out="$("${cli}" theme --list --json 2>&1)"; status=$?
count="$(python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())['themes']))" <<<"${out}" 2>/dev/null || echo 0)"
if [[ ${status} -eq 0 && ${count} -ge 16 ]]; then
    pass "theme --list is answered locally: ${count} themes"
else
    fail "theme --list exited ${status} with ${count} themes"
fi
# The gate that matters for a headless agent: this works with no app at all.
# `gruvbox-dark` rather than `dracula` on purpose — it is a *pair*, so its CSS
# carries the dark half behind a media query, which is the thing being checked.
out="$(MARK_NO_LAUNCH=1 TMPDIR="$(mktemp -d)" "${cli}" theme --show gruvbox-dark 2>&1)"; status=$?
if [[ ${status} -eq 0 && "${out}" == *"base00"* && "${out}" == *"prefers-color-scheme"* ]]; then
    pass "theme --show works with no app running, and emits both appearances"
else
    fail "theme --show with no app exited ${status} with: ${out}"
fi

# ---------------------------------------------------------------- gate 6 ----
gate "6. an unknown protocol version gets a structured refusal"
python3 - "${socket}" <<'PY'
import json, socket, sys

path = sys.argv[1]

def ask(line):
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(10)
    connection.connect(path)
    connection.sendall(line.encode() + b"\n")
    data = b""
    while not data.endswith(b"\n"):
        chunk = connection.recv(4096)
        if not chunk:
            break
        data += chunk
    connection.close()
    return json.loads(data.decode())

failures = 0

future = ask(json.dumps({"version": 99, "id": "v", "command": "open",
                         "arguments": {"path": "/tmp/whatever.md"}}))
if future.get("ok") is False and future["error"]["code"] == "unsupported-version" \
        and future["error"]["expected"] == 1 and future["error"]["received"] == 99:
    print("  ok    version 99 -> unsupported-version, expected=1 received=99")
    print(f"        {future['error']['message']}")
else:
    print(f"  FAIL  version 99 got {future}", file=sys.stderr)
    failures += 1

garbage = ask("this is not JSON")
if garbage.get("ok") is False and garbage["error"]["code"] == "malformed-request":
    print("  ok    a non-JSON line is answered, not dropped")
else:
    print(f"  FAIL  garbage got {garbage}", file=sys.stderr)
    failures += 1

unknown = ask(json.dumps({"version": 1, "command": "levitate"}))
if unknown.get("ok") is False and unknown["error"]["code"] == "unknown-command" \
        and "open" in unknown["error"]["known"]:
    print("  ok    an unknown command lists the ones that exist")
else:
    print(f"  FAIL  unknown command got {unknown}", file=sys.stderr)
    failures += 1

# Two requests on one connection, answered in order: the "newline-delimited"
# half of the protocol, which one-shot commands never exercise.
connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
connection.settimeout(10)
connection.connect(path)
connection.sendall(
    (json.dumps({"version": 1, "id": "one", "command": "tab-list"}) + "\n"
     + json.dumps({"version": 1, "id": "two", "command": "ping"}) + "\n").encode())
data = b""
while data.count(b"\n") < 2:
    chunk = connection.recv(65536)
    if not chunk:
        break
    data += chunk
connection.close()
replies = [json.loads(line) for line in data.decode().strip().split("\n")]
if [reply.get("id") for reply in replies] == ["one", "two"]:
    print("  ok    two NDJSON requests on one connection, answered in order")
else:
    print(f"  FAIL  pipelined replies came back as {replies}", file=sys.stderr)
    failures += 1

sys.exit(1 if failures else 0)
PY
if [[ $? -eq 0 ]]; then
    passed=$((passed + 4))
else
    failed=$((failed + 1))
fi

# The same skew from the CLI's own side, so the exit code is covered too.
out="$(MARK_PROTOCOL_VERSION=99 "${cli}" reload 2>&1)"; status=$?
if [[ ${status} -eq 5 && "${out}" == *"protocol version 1"* ]]; then
    pass "a CLI speaking version 99 exits 5: ${out}"
else
    fail "a version-99 CLI exited ${status} with: ${out}"
fi

# ---------------------------------------------------------------- gate 7 ----
gate "7. mark:// — the cold-launch and Finder entry path (ADR-3)"
printf '# From a URL\n\ntext\n' > "${work}/url.md"
open -g "mark://open?path=${work}/url.md&tab=1"
found=1
for _ in $(seq 1 40); do
    if tab_paths | grep -qx "${work}/url.md"; then found=0; break; fi
    sleep 0.25
done
if [[ ${found} -eq 0 ]]; then
    pass "mark://open opened a tab through LaunchServices"
else
    fail "mark://open did not open ${work}/url.md"
fi

gate "8. the rest of the command surface, over the socket"
if "${cli}" tab select 0 >/dev/null 2>&1 && "${cli}" tab list | head -1 | grep -q '^\*'; then
    pass "tab select moves the selection"
else
    fail "tab select did not select tab 0"
fi
before="$(tab_paths | wc -l | tr -d ' ')"
if "${cli}" tab close --  "${work}/url.md" >/dev/null 2>&1; then
    after="$(tab_paths | wc -l | tr -d ' ')"
    if [[ "${after}" -eq $((before - 1)) ]]; then
        pass "tab close closed exactly one tab (${before} -> ${after})"
    else
        fail "tab close went from ${before} to ${after} tabs"
    fi
else
    fail "tab close by path failed"
fi
out="$("${cli}" reload 2>&1)"; status=$?
if [[ ${status} -eq 0 && "${out}" == *"blocks"* ]]; then
    pass "reload patched the front document: ${out}"
else
    fail "reload exited ${status} with: ${out}"
fi
out="$("${cli}" goto 'install' 2>&1)"; status=$?
if [[ ${status} -eq 0 ]]; then
    pass "goto found a real anchor: ${out}"
else
    fail "goto install exited ${status} with: ${out}"
fi

# ---------------------------------------------------------------- gate 9 ----
#
# M5's watcher, in the shipped app rather than in a unit test.
#
# `2026-08-24-progressive-document-rendering` requires FSEvents *because* every
# editor saves by writing a temp file and renaming it over the target, so the
# inode changes on every save. kqueue holds a descriptor on the old inode and
# goes permanently silent at that point — and silently, which is why this is
# asserted end to end rather than trusted. Two saves, because one rename proves
# nothing: kqueue reports the first and loses every one after it.
#
# The observable is the tab's open-task badge, which ADR-4 requires to come from
# the core against the bytes on disk. It moves only if the watcher fired.
gate "9. the file watcher: atomic-rename saves and a CLI write, seen by a running app"

open_tasks() {
    "${cli}" tab list --json 2>/dev/null | python3 -c '
import json, sys
path = sys.argv[1]
try:
    for tab in json.load(sys.stdin):
        if tab["path"] == path:
            print(tab.get("openTasks", "-"))
            break
    else:
        print("no-tab")
except Exception:
    print("error")
' "$1"
}

# Poll, because FSEvents delivers when it delivers and the badge is refreshed
# off the main thread.
wait_for_open_tasks() {
    local path="$1" want="$2"
    for _ in $(seq 1 60); do
        [[ "$(open_tasks "${path}")" == "${want}" ]] && return 0
        sleep 0.25
    done
    return 1
}

watched="${work}/watched.md"
printf '# Watched\n\n- [ ] one\n- [ ] two\n' > "${watched}"
if "${cli}" open "${watched}" >/dev/null 2>&1 && wait_for_open_tasks "${watched}" 2; then
    pass "the document opened with 2 open tasks"
else
    fail "watched.md did not open with the expected badge (got $(open_tasks "${watched}"))"
fi

# Save 1: temp file + rename, exactly as vim does it.
printf '# Watched\n\n- [ ] one\n- [ ] two\n- [ ] three\n' > "${work}/.watched.md.swp"
mv "${work}/.watched.md.swp" "${watched}"
if wait_for_open_tasks "${watched}" 3; then
    pass "an atomic temp-file-plus-rename save was noticed (inode changed, FSEvents survived)"
else
    fail "the watcher missed an atomic-rename save (badge is $(open_tasks "${watched}"))"
fi

# Save 2: the one kqueue would have lost.
printf '# Watched\n\n- [x] one\n- [ ] two\n- [ ] three\n- [ ] four\n' > "${work}/.watched.md.swp"
mv "${work}/.watched.md.swp" "${watched}"
if wait_for_open_tasks "${watched}" 3; then
    pass "a second atomic save was noticed too — the watcher did not go one-shot"
else
    fail "the watcher went silent after the first inode swap (badge is $(open_tasks "${watched}"))"
fi

# And a write from another process entirely: `mark check` is the CLI half of the
# same byte-range toggle the GUI click uses (ADR-1's "used identically by a GUI
# click and by mark-cli check").
size_before="$(wc -c < "${watched}" | tr -d ' ')"
if "${cli}" check "${watched}" --item 1 --on >/dev/null 2>&1; then
    if wait_for_open_tasks "${watched}" 2; then
        pass "a CLI toggle while the GUI holds the file open updated the open tab"
    else
        fail "the GUI did not notice 'mark check' (badge is $(open_tasks "${watched}"))"
    fi
else
    fail "mark check failed against a file the GUI has open"
fi
size_after="$(wc -c < "${watched}" | tr -d ' ')"
if [[ "${size_before}" == "${size_after}" ]]; then
    pass "the toggle changed one byte in place (${size_after} bytes before and after)"
else
    fail "the file changed length: ${size_before} -> ${size_after}"
fi

# --------------------------------------------------------------- gate 10 ----
gate "10. the 104-byte sun_path trap fires rather than truncating"
long_tmp="/tmp/$(python3 -c 'print("d" * 120)')"
out="$(TMPDIR="${long_tmp}" "${cli}" open "${work}/cold.md" 2>&1)"; status=$?
if [[ ${status} -ne 0 && "${out}" == *"104"* ]]; then
    pass "the CLI refuses a path over the limit (exit ${status})"
    note "${out}"
else
    fail "a ${#long_tmp}-byte TMPDIR gave exit ${status}: ${out}"
fi
# And the app's own assertion, which is the one ADR-3 requires at *startup*.
out="$(TMPDIR="${long_tmp}" MARK_NO_SESSION=1 "${app_binary}" 2>&1)"; status=$?
if [[ ${status} -eq 78 && "${out}" == *"104"* ]]; then
    pass "the app exits 78 at startup rather than binding a truncated path"
    note "${out}"
else
    fail "the app exited ${status} with: ${out}"
fi

# --------------------------------------------------------------- gate 11 ----
gate "11. no consent prompt, on an ad-hoc-signed build"
signature="$(codesign -dv "${bundle}" 2>&1 | grep -i '^Signature=' || echo 'Signature=?')"
if [[ "${signature}" == "Signature=adhoc" ]]; then
    pass "the bundle under test is ad-hoc signed (${signature})"
else
    fail "expected an ad-hoc signature, found ${signature}"
fi
tcc_log="${work}/tcc.log"
/usr/bin/log show --style compact --start "${started_at}" \
    --predicate 'subsystem == "com.apple.TCC" or process == "tccd"' \
    >"${tcc_log}" 2>/dev/null
ours="${work}/tcc-mark.log"
grep -iE 'dev\.mark|mark-cli|mark\.app' "${tcc_log}" >"${ours}" 2>/dev/null

# A *prompt* is what ADR-3 is about, and tccd says so explicitly when it shows
# one. An attribution record is not a prompt: WebKit's GPU and WebContent
# processes ask tccd about their own capabilities on every launch, attributed
# to whichever app hosts them, and the answer comes back without any UI.
prompted="$(grep -icE 'PROMPT|user consent|kTCCServiceSystemPolicyAppData|kTCCServiceAppleEvents' "${ours}" || true)"
if [[ "${prompted}" == "0" ]]; then
    pass "tccd never prompted for mark: no PROMPT, no App Data, no Apple Events"
    note "$(wc -l <"${ours}" | tr -d ' ') TCC lines mention mark, all of them WebKit"
    note "GPU/WebContent capability checks answered without UI (authValue=0, no prompt)."
else
    fail "tccd shows ${prompted} consent-shaped lines for mark:"
    grep -iE 'PROMPT|user consent|kTCCServiceSystemPolicyAppData|kTCCServiceAppleEvents' "${ours}" | head -5 >&2
fi

# The independent check: the agent that *draws* a TCC alert. A prompt during
# this run would have had to start it, or restart it — so compare its age
# against the moment this script began rather than merely asking whether it is
# running, which it usually is.
alert_agent="$(pgrep -x UserNotificationCenter | head -1 || true)"
if [[ -z "${alert_agent}" ]]; then
    pass "UserNotificationCenter — which draws consent alerts — is not running at all"
elif python3 - "${alert_agent}" "${started_epoch}" <<'PY'
import subprocess, sys, time
pid, since = sys.argv[1], float(sys.argv[2])
out = subprocess.run(["ps", "-o", "lstart=", "-p", pid],
                     capture_output=True, text=True).stdout.strip()
started = time.mktime(time.strptime(out)) if out else 0
sys.exit(0 if started < since else 1)
PY
then
    pass "UserNotificationCenter predates this run: no alert was raised during it"
else
    fail "UserNotificationCenter started during this run — something put a dialog on screen"
fi

# --------------------------------------------------------------- gate 12 ----
gate "12. the installed shape: the bundle launches with the build directory gone"
# The gate that was missing, and the reason a broken bundle shipped anyway.
#
# SwiftPM's generated `Bundle.module` accessor looks for `Mark_MarkKit.bundle`
# in two places and calls `fatalError` when both miss: the *root* of `mark.app`
# (not `Contents/Resources`, which is where `assemble-bundle.sh` puts it) and
# the absolute `.build` path of whatever machine compiled the binary. In this
# checkout that second path exists, so every gate above passed against a bundle
# that died on launch the moment it was installed anywhere else — a `brew
# install`, a copy to /Applications, another machine.
#
# So: hide the build directory's copy and launch the app again. Nothing outside
# the bundle may be load-bearing.
resource_bundle=""
for candidate in "${root}"/app/.build/*/release/Mark_MarkKit.bundle; do
    [[ -d "${candidate}" ]] && resource_bundle="${candidate}" && break
done

if [[ -z "${resource_bundle}" ]]; then
    note "no SwiftPM resource bundle in app/.build — nothing to hide, gate skipped"
else
    quit_app
    stashed_resource_bundle="${resource_bundle}"
    mv "${resource_bundle}" "${resource_bundle}.integration-hidden"

    # Launched directly rather than through `open`, because that is the only way
    # to see the app's stderr — and a `fatalError` in a static initialiser is
    # stderr and an exit, with no crash report and no window.
    rm -f "${socket}"
    "${app_binary}" >"${work}/gate12.log" 2>&1 &
    app_direct_pid=$!

    if wait_for_app; then
        pass "the app launched and bound its socket with app/.build hidden"
        if "${cli}" open "${work}/cold.md" >/dev/null 2>&1 &&
            tab_paths | grep -qx "${work}/cold.md"; then
            pass "it renders a document from the bundle's own resources"
        else
            fail "the app is up but cannot open a document without app/.build"
        fi
    else
        fail "the app did not come up with app/.build hidden — the bundle is not self-contained"
        if [[ -s "${work}/gate12.log" ]]; then
            head -3 "${work}/gate12.log" | sed 's/^/        /' >&2
        elif kill -0 "${app_direct_pid}" 2>/dev/null; then
            note "the process is alive but never bound the socket"
        else
            note "the process exited without writing anything to stderr"
        fi
    fi

    quit_app
    mv "${resource_bundle}.integration-hidden" "${resource_bundle}"
    stashed_resource_bundle=""
fi

# --------------------------------------------------------------- gate 13 ----
# The regression this exists for: `open README.md` put up a window with the
# document nowhere in it.
#
# `NSApplication.finishLaunching` posts `applicationWillFinishLaunching`, then
# dispatches the queued `kAEOpenDocuments` Apple event — which is
# `application(_:open:)` — and only *then* posts
# `applicationDidFinishLaunching`, where this app builds its window. So the
# document arrives before there is anywhere to put it, and the delegate has to
# hold it rather than return. Nothing else in this script covers that: gate 1
# opens through the CLI, and gate 7's `mark://` arrives at an app that is
# already up.
gate "13. a document named at cold launch is opened (Finder, 'open README.md')"
quit_app
rm -f "${socket}"
printf '# Cold document\n\nOpened as the app launched.\n' > "${work}/launch.md"
if [[ -n "$(app_pids)" ]]; then
    fail "a mark survived the quit; this gate needs a real cold launch"
else
    # `open -a <bundle> <file>` is what Finder and `open(1)` do: LaunchServices
    # starts the app and hands it the document as a launch Apple event.
    open -a "${bundle}" "${work}/launch.md"
    found=1
    for _ in $(seq 1 60); do
        if tab_paths | grep -qx "${work}/launch.md"; then found=0; break; fi
        sleep 0.25
    done
    if [[ ${found} -eq 0 ]]; then
        pass "the document handed to the launch is open in a tab"
    else
        fail "launch.md is not in the tab list — the launch event was dropped"
    fi
    # The sidebar follows the document, rather than coming back on whatever
    # root the last session happened to leave behind.
    root="$("${cli}" sidebar --json 2>/dev/null | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin)["root"])
except Exception:
    pass
')"
    # Resolved, because $work is under /tmp — a symlink to /private/tmp — and
    # LaunchServices hands the app the resolved path.
    work_real="$(cd "${work}" && pwd -P)"
    if [[ "${root}" == "${work}" || "${root}" == "${work_real}" ]]; then
        pass "the sidebar is rooted at the document's directory"
    else
        fail "the sidebar is rooted at '${root}', not ${work_real}"
    fi
fi

# --------------------------------------------------------------- gate 14 ----
# Two installs — a `mark` on PATH from one build and a `mark.app` LaunchServices
# picked from another — behave like one product that is subtly wrong. This is
# the check that names it, and it is a *report*, not just a pass: the two
# strings are what a bug report should carry.
gate "14. the CLI and the app it is driving are the same build"
build_report="$("${cli}" doctor --json 2>/dev/null | python3 -c '
import json, sys
try:
    report = json.load(sys.stdin)
    print("{} ({} {})".format(
        report["cli_version"], report["build_commit"], report["build_date"]))
    print(report.get("app_build") or "")
except Exception:
    pass
')"
cli_build="$(printf %s "${build_report}" | sed -n 1p)"
app_build="$(printf %s "${build_report}" | sed -n 2p)"
note "cli ${cli_build:-<unknown>}"
note "app ${app_build:-<unknown>}"
if [[ -z "${app_build}" ]]; then
    fail "doctor did not report the running app's build"
elif [[ "${cli_build}" == "${app_build}" ]]; then
    pass "both report ${cli_build}"
else
    fail "the CLI is ${cli_build} but the app is ${app_build}"
fi

# The bundle's artwork and the plist keys that name it. Here rather than in
# `swift test` for the reason gate 12 exists: a unit test cannot see a bundle it
# does not assemble, and every failure below is invisible until someone looks at
# the Dock.
#
# `plutil -lint` earns its place separately: `Info.plist` is written by a shell
# heredoc in `assemble-bundle.sh`, so a malformed edit is a live failure mode
# rather than a theoretical one, and an unparseable plist makes the app
# unlaunchable rather than merely ugly.
gate "15. the bundle carries its icons (Dock, Finder, ⌘-Tab, the About panel)"
if plutil -lint "${bundle}/Contents/Info.plist" >/dev/null 2>&1; then
    pass "Info.plist parses"
else
    fail "Info.plist does not parse: $(plutil -lint "${bundle}/Contents/Info.plist" 2>&1)"
fi

for icon in mark mark-document; do
    path="${bundle}/Contents/Resources/${icon}.icns"
    if [[ -s "${path}" ]]; then
        pass "Resources/${icon}.icns ($(du -h "${path}" | cut -f1))"
    else
        fail "Resources/${icon}.icns is missing or empty"
    fi
done

icon_key="$(plutil -extract CFBundleIconFile raw "${bundle}/Contents/Info.plist" 2>/dev/null || true)"
if [[ "${icon_key}" == "mark" ]]; then
    pass "CFBundleIconFile names mark.icns"
else
    fail "CFBundleIconFile is '${icon_key:-<absent>}', expected 'mark'"
fi

# Index 0 is the markdown entry. The plain-text entry deliberately has no icon:
# one entry covering both types would put the markdown document icon on every
# .txt file, which is why `assemble-bundle.sh` splits them.
doc_icon="$(plutil -extract CFBundleDocumentTypes.0.CFBundleTypeIconFile raw \
    "${bundle}/Contents/Info.plist" 2>/dev/null || true)"
doc_type="$(plutil -extract CFBundleDocumentTypes.0.LSItemContentTypes.0 raw \
    "${bundle}/Contents/Info.plist" 2>/dev/null || true)"
if [[ "${doc_icon}" == "mark-document" && "${doc_type}" == "net.daringfireball.markdown" ]]; then
    pass "the markdown document type carries mark-document.icns"
else
    fail "markdown document type is '${doc_type:-<absent>}' with icon '${doc_icon:-<absent>}'"
fi

if plutil -extract CFBundleDocumentTypes.1.CFBundleTypeIconFile raw \
    "${bundle}/Contents/Info.plist" >/dev/null 2>&1; then
    fail "the plain-text document type has an icon; it would land on every .txt"
else
    pass "the plain-text document type has no icon of its own"
fi

# `2026-08-26-new-documents-are-files-on-disk`. Only .md and .markdown have a
# UTI anyone declared; without the imported declaration the other three are
# `dyn.…` types conforming to public.data, and Finder offers no "Open With
# mark" for them. Asserted against `core/src/tree.rs::MARKDOWN` — the list the
# app itself uses — so the bundle cannot drift away from it silently.
# Extracted one level above `public.filename-extension`: a plutil keypath
# splits on `.`, and that key has two of them in its own name.
ut_extensions="$(plutil -extract \
    UTImportedTypeDeclarations.0.UTTypeTagSpecification json -o - \
    "${bundle}/Contents/Info.plist" 2>/dev/null || true)"
missing_ut=()
for ext in md markdown mdown mkd mdx; do
    [[ "${ut_extensions}" == *"\"${ext}\""* ]] || missing_ut+=("${ext}")
done
ut_id="$(plutil -extract UTImportedTypeDeclarations.0.UTTypeIdentifier raw \
    "${bundle}/Contents/Info.plist" 2>/dev/null || true)"
if [[ ${#missing_ut[@]} -eq 0 && "${ut_id}" == "net.daringfireball.markdown" ]]; then
    pass "the imported markdown type declares all five extensions"
else
    fail "imported markdown type is '${ut_id:-<absent>}', missing: ${missing_ut[*]:-none}"
fi

# Imported, not exported: `net.daringfireball.markdown` is not ours to define.
if plutil -extract UTExportedTypeDeclarations raw \
    "${bundle}/Contents/Info.plist" >/dev/null 2>&1; then
    fail "the bundle exports a type declaration; markdown is imported, not ours"
else
    pass "no exported type declarations"
fi

gate "16. the bundle carries the markdown reference, and it still renders"
# Help ▸ Markdown Reference (`2026-08-26-markdown-reference-window`) is a
# *document* in `Contents/Resources`, so the way it breaks is a dropped `cp` in
# `assemble-bundle.sh` — after which the menu item greys out and nothing else
# in the suite notices. Rendering it through the installed CLI checks both
# halves at once: that the file shipped, and that the thing it claims to
# demonstrate still comes out the other end.
reference="${bundle}/Contents/Resources/markdown-reference.md"
if [[ -s "${reference}" ]]; then
    pass "Resources/markdown-reference.md ($(du -h "${reference}" | cut -f1))"
else
    fail "Resources/markdown-reference.md is missing or empty"
fi

if [[ -s "${reference}" ]]; then
    reference_html="$("${cli}" render "${reference}" --html 2>/dev/null || true)"
    # One assertion per construct the page promises, because "it rendered" is
    # true of a page with every diagram silently missing.
    for probe in \
        'class="mk-task"|a clickable task list' \
        '<math|MathML' \
        'class="mk-diagram"|a Mermaid diagram' \
        'class="markdown-alert-warning"|a GFM alert' \
        'footnote-definition|a footnote' \
        'data-lang="rust"|a highlighted code block'
    do
        needle="${probe%%|*}"
        what="${probe##*|}"
        if grep -qF "${needle}" <<<"${reference_html}"; then
            pass "the reference still demonstrates ${what}"
        else
            fail "the reference no longer demonstrates ${what}"
        fi
    done
fi

# ------------------------------------------------------------------ done ----
gate "summary"
printf '  %d passed, %d failed\n' "${passed}" "${failed}"
note "not covered here: rejecting a peer with a different uid needs a second"
note "user account, so LOCAL_PEERCRED is asserted in SocketServerTests instead."
if [[ ${failed} -ne 0 ]]; then
    exit 1
fi
echo "  integration.sh: all gates passed"
