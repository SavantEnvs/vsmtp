# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — RUST target (cargo / cargo-fuzz) for vSMTP.
# Builds ON TOP of the org C/C++ base (ghcr.io/savantenvs/base), adding a pinned
# Rust nightly + cargo-fuzz under /opt/toolchains/rust, then runs mayhem/build.sh.
#
# The pinned toolchain + cargo registry live at a FIXED, $HOME-independent prefix
# so (a) the task tier can lock it and (b) the air-gapped PATCH re-run resolves
# the SAME cargo cache by absolute CARGO_HOME (SPEC §6.2 items 8/9, §6.5).

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (an empty ENV breaks clang). build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH
# Undefaulted (no '=') so the base ENV default flows through unless --build-arg overrides it.
ARG SANITIZER_FLAGS

# Pin the channel by DATE. -Zsanitizer=address (the OSS-Fuzz Rust ASan path) needs
# nightly. This nightly is contemporaneous with vSMTP fd26c87f (2024-01) so the
# upstream-pinned deps (rhai 1.12, rsasl 2.0.0, time 0.3.20, …) compile cleanly —
# it predates the rustc 1.80 `time 0.3.20` break, and the seeded root Cargo.lock
# keeps every dependency at the exact version upstream tested (no source patches).
ARG RUST_CHANNEL=nightly-2024-05-10
ARG CARGO_FUZZ_VERSION=0.11.4

ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:${PATH}

USER root
RUN install -d /opt/toolchains/rust \
 && curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh \
 && sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal \
        --default-toolchain "${RUST_CHANNEL}" \
 && rustup component add rust-src --toolchain "${RUST_CHANNEL}" \
 && cargo install cargo-fuzz --version "${CARGO_FUZZ_VERSION}" --locked \
 && rm -f /tmp/rustup-init.sh \
 # The commit build AND the air-gapped PATCH re-run run as `mayhem` (2000): it must
 # read the toolchain and read/refresh the cargo registry cache, so hand it 2000.
 && chown -R 2000:2000 /opt/toolchains/rust \
 && mkdir -p "$CARGO_HOME/registry" "$CARGO_HOME/git" \
 && chmod -R a+rwX "$CARGO_HOME/registry" "$CARGO_HOME/git"

# -- DWARF<4 gate (SPEC §6.2 item 10): Mayhem triage cannot read DWARF >= 4. --
# The prebuilt std rlibs and the clang-built ASan runtime archives carry DWARF 4/5
# debug CUs that -Zdwarf-version cannot rewrite, so the linked fuzz binary would
# inherit a DWARF>=4 first CU. Strip their debug info (rmeta/code preserved) so only
# our own DWARF-3 CUs remain.
RUN set -eux; \
    for L in /opt/toolchains/rust/rustup/toolchains/*/lib/rustlib/x86_64-unknown-linux-gnu/lib; do \
      find "$L" -maxdepth 1 -type f \( -name '*.rlib' -o -name '*.a' \) \
        -exec objcopy --strip-debug '{}' ';' ; \
    done; \
    rustc --version; cargo --version; cargo fuzz --version

# Source enters from the build CONTEXT (CI checkout): the FULL repo (incl. .git) → /mayhem.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Populates $CARGO_HOME + vendors deps (online, this first build) and builds the sanitized targets.
RUN bash mayhem/build.sh

# Run the project's functional suite at build time IF present (a failing suite fails the build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
