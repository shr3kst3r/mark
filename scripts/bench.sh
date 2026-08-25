#!/usr/bin/env bash
#
# Performance regression gate. Run with `just bench`.
#
# The thresholds are the research numbers with headroom (plan §5): generous
# enough not to flake on slower hardware, tight enough to catch the change that
# quietly turns memoized highlighting back into re-highlighting everything —
# exactly the kind of change that looks harmless in review.
#
# M1 covers the core-side budget only. First paint, tab memory, and bundle size
# need the app (M2, M3, M8); math and diagrams need M6.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"

corpus="bench/corpus"
binary="target/release/mark-cli"

# Thresholds, in milliseconds, for the 1 MB document.
readonly PARSE_MAX=5.0
readonly HIGHLIGHT_COLD_MAX=150.0
readonly HIGHLIGHT_CACHED_MAX=1.0
readonly RENDER_MAX=200.0

if [[ ! -f "${corpus}/1mb.md" ]]; then
    echo "generating corpus..."
    python3 scripts/gen-corpus.py
fi

echo "building release binary..."
cargo build --release --quiet

failures=0

check() {
    local label="$1" actual="$2" limit="$3"
    if python3 -c "import sys; sys.exit(0 if float('${actual}') <= float('${limit}') else 1)"; then
        printf '  %-22s %8.3f ms  (limit %s)\n' "${label}" "${actual}" "${limit}"
    else
        printf '  %-22s %8.3f ms  OVER LIMIT %s\n' "${label}" "${actual}" "${limit}" >&2
        failures=$((failures + 1))
    fi
}

field() {
    python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])" <<<"$2"
}

for size in 8kb 256kb 1mb; do
    file="${corpus}/${size}.md"
    [[ -f "${file}" ]] || continue
    echo "${file}:"

    # Best of three: the first run pays for page-ins that a warm app does not.
    best=""
    for _ in 1 2 3; do
        run="$("${binary}" stats "${file}" --json)"
        if [[ -z "${best}" ]] || python3 -c "
import json,sys
a = json.loads(sys.argv[1])['render_ms']
b = json.loads(sys.argv[2])['render_ms']
sys.exit(0 if a < b else 1)" "${run}" "${best}"; then
            best="${run}"
        fi
    done

    parse="$(field parse_ms "${best}")"
    render="$(field render_ms "${best}")"
    cold="$(field highlight_cold_ms "${best}")"
    cached="$(field highlight_cached_ms "${best}")"

    if [[ "${size}" == "1mb" ]]; then
        check "parse" "${parse}" "${PARSE_MAX}"
        check "render" "${render}" "${RENDER_MAX}"
        check "highlight cold" "${cold}" "${HIGHLIGHT_COLD_MAX}"
        check "highlight cached" "${cached}" "${HIGHLIGHT_CACHED_MAX}"
    else
        printf '  parse %.3f ms, render %.3f ms, highlight %.3f/%.3f ms\n' \
            "${parse}" "${render}" "${cold}" "${cached}"
    fi
done

# Per-invocation CLI cost. ADR-1's baseline is 2.84 ms for a clap binary
# against a 2.28 ms `exec` floor, and the whole point of the CLI is that an
# agent can call it in a loop.
echo "cli startup (100 invocations of \`mark-cli --version\`):"
startup="$(python3 - "${binary}" <<'PY'
import subprocess
import sys
import time

binary = sys.argv[1]
start = time.perf_counter()
for _ in range(100):
    subprocess.run([binary, "--version"], stdout=subprocess.DEVNULL, check=True)
print(f"{(time.perf_counter() - start) * 1000 / 100:.3f}")
PY
)"
printf '  %-22s %8.3f ms/invocation  (ADR-1 baseline 2.84)\n' "startup" "${startup}"

echo
echo "binary sizes:"
ls -l target/release/mark-cli target/release/libmark_core.a 2>/dev/null |
    awk '{ printf "  %-40s %10.2f MB\n", $9, $5 / 1048576 }'

if (( failures > 0 )); then
    echo >&2
    echo "${failures} threshold(s) exceeded" >&2
    exit 1
fi
echo
echo "all thresholds met"
