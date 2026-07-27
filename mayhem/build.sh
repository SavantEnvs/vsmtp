#!/usr/bin/env bash
#
# mayhem/build.sh — build vSMTP's four cargo-fuzz targets as sanitized libFuzzer
# binaries (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS) AND the
# functional test suite. Runs inside the commit image (RUST mayhem/Dockerfile) as
# `mayhem` in /mayhem.
#
# ADDITIVE: all harness sources live under mayhem/fuzz/ and reference the upstream
# crates by relative path — nothing under src/ is modified. Dependency versions are
# pinned by seeding mayhem/fuzz/Cargo.lock from the upstream root Cargo.lock, so the
# isolated fuzz workspace resolves exactly the versions upstream tested (no source
# patches needed on this nightly).
#
# AIR-GAPPED (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE. The FIRST
# (online) build vendors every crates.io dep into mayhem/vendor and writes a
# source-replacement into $CARGO_HOME/config.toml; the offline re-run then resolves
# everything from vendor/ (dir already present → vendoring skipped). Do NOT add
# `--offline` here (it would break this first, online build).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

SRC="${SRC:-/mayhem}"
cd "$SRC"

FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

# vSMTP's config layer picks the run identity at COMPILE time via option_env!("CI"):
# with CI set it uses the always-present "root" user/group; unset it looks up a
# "vsmtp" system user that does not exist in the image and PANICS on every input.
# Build with CI set so the config/rule-engine/receiver harnesses drive real code.
export CI=true

# §6.2 item 10: Mayhem triage can't read DWARF >= 4. Pin DWARF 3 in rustc and (for
# the C shims in -sys crates) in clang. The prebuilt std + ASan archives are
# debug-stripped in the Dockerfile so no DWARF-5 CU leaks in. Overridable.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=1 -C force-frame-pointers=yes -Zdwarf-version=3}"
export RUST_DEBUG_FLAGS

# $SANITIZER_FLAGS are clang flags rustc ignores; the Rust ASan path is via RUSTFLAGS.
: "${SANITIZER_FLAGS:=}"
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address ${RUST_DEBUG_FLAGS}"
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"

# ---- air-gapped vendor (first, online build only) ----------------------------------
VENDOR_DIR="$SRC/mayhem/vendor"
if [ ! -d "$VENDOR_DIR" ]; then
  echo "=== seeding fuzz lockfile from the upstream root Cargo.lock ==="
  # Start from upstream's tested dependency set so every shared dependency stays at
  # the exact version upstream tested. Do NOT `generate-lockfile` (it re-resolves
  # everything to newest, pulling in crates that need an unstable edition on this
  # nightly). The `cargo update -p ahash` below performs the minimal resolve that
  # adds only the fuzz-only crates (libfuzzer-sys, arbitrary, …) while keeping pins.
  # proc-macro2 1.0.51 (upstream's pin) uses the since-removed
  # `feature(proc_macro_span_shrink)` and fails to compile on this nightly (E0635).
  # Bump it in the ROOT lock FIRST so both the seeded fuzz lock AND the `--sync`ed
  # root vendor below inherit the fix — a version bump, not a source patch (the git
  # tree stays additive).
  ( cd "$SRC" && cargo update -p proc-macro2 --precise 1.0.86 )
  cp "$SRC/Cargo.lock" "$FUZZ_DIR/Cargo.lock"

  # rhai 1.12 pulls ahash 0.8.3, whose nightly path uses the since-removed
  # `feature(stdsimd)` and does not compile on this nightly. Bump ONLY ahash to a
  # semver-compatible patch release that dropped that usage — a version bump, not a
  # source patch (keeps the git tree additive). This same invocation reconciles the
  # seeded lock with the fuzz manifest (adding the fuzz-only crates at newest).
  ( cd "$FUZZ_DIR" && cargo update -p ahash@0.8.3 --precise 0.8.11 )

  echo "=== vendoring crates.io deps for offline re-runs ==="
  # Vendor the fuzz workspace (primary) AND the root workspace (for the mail-parser
  # test suite's dev-deps) into one tree; both source sets get replaced offline.
  cargo vendor --versioned-dirs \
    --manifest-path "$FUZZ_DIR/Cargo.toml" \
    --sync "$SRC/Cargo.toml" \
    "$VENDOR_DIR" >/dev/null

  : "${CARGO_HOME:?CARGO_HOME must be set (pinned by the Dockerfile)}"
  if ! grep -q 'vendored-sources' "$CARGO_HOME/config.toml" 2>/dev/null; then
    cat >> "$CARGO_HOME/config.toml" <<CFG

[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "$VENDOR_DIR"
CFG
  fi
fi

# ---- build the four sanitized libFuzzer targets ------------------------------------
FUZZ_TARGETS=(mime_parser server_config rules receiver)

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# Force a clean relink so no stale DWARF-5 object lingers from a prior cache.
rm -rf "$FUZZ_DIR/target"
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# ---- build the functional test suite (oracle) --------------------------------------
# Oracle = vsmtp-mail-parser (the MIME/mail parser the mime_parser + receiver targets
# drive). Its tests assert concrete parsed values (golden mail structures), so a PATCH
# that neuters the parser to a no-op FAILS the suite (anti-reward-hack). Built here with
# the project's NORMAL flags into a separate target dir so mayhem/test.sh only RUNS it.
echo "=== building functional test suite (vsmtp-mail-parser) ==="
env CARGO_TARGET_DIR="$SRC/target-tests" \
    RUSTFLAGS="--cap-lints=allow" \
    cargo test --no-run -p vsmtp-mail-parser 2>&1 | tail -25

echo "build.sh complete"
