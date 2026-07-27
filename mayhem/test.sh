#!/usr/bin/env bash
#
# mayhem/test.sh — RUN vSMTP's functional test suite (already compiled by build.sh
# into $SRC/target-tests). Oracle = vsmtp-mail-parser (the MIME/mail parser the
# mime_parser + receiver fuzz targets drive): its tests assert concrete parsed values
# / golden mail structures — not just exit 0 — so a PATCH that neuters the parser to a
# no-op FAILS here (anti-reward-hacking oracle). Emits a CTRF summary + a `CTRF {...}`
# marker line. Does NOT compile.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
SRC="${SRC:-/mayhem}"
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests, "passed": $passed, "failed": $failed,
      "pending": $pending, "skipped": $skipped, "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

TDIR="$SRC/target-tests"
if [ ! -d "$TDIR" ]; then
  echo "ERROR: test build dir $TDIR missing — build.sh should have produced it" >&2
  emit_ctrf "cargo-test" 0 1; exit 1
fi

# RUN the pre-built suite. --no-fail-fast so we count every test. Cargo re-links from
# target-tests without recompiling (same normal flags build.sh used).
LOG="$(mktemp)"
env CARGO_TARGET_DIR="$TDIR" CARGO_NET_OFFLINE=true RUSTFLAGS="--cap-lints=allow" \
    cargo test --no-fail-fast \
      -p vsmtp-mail-parser 2>&1 | tee "$LOG" || true

# Aggregate every "test result: ok. P passed; F failed; ... I ignored" line.
COUNTS="$(python3 - "$LOG" <<'PYEOF'
import re, sys
p=f=i=0
for line in open(sys.argv[1], errors="replace"):
    m=re.search(r"test result:.*?(\d+) passed; (\d+) failed;.*?(\d+) ignored", line)
    if m:
        p+=int(m.group(1)); f+=int(m.group(2)); i+=int(m.group(3))
print(p, f, i)
PYEOF
)"
read -r P F I <<< "$COUNTS"
: "${P:=0}" "${F:=0}" "${I:=0}"
echo "aggregate: passed=$P failed=$F ignored=$I"
if [ "$(( P + F ))" -eq 0 ]; then
  echo "ERROR: no test results parsed — suite did not run" >&2
  emit_ctrf "cargo-test" 0 1 "$I"; exit 1
fi
emit_ctrf "cargo-test" "$P" "$F" "$I"
