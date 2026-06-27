# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) — builds ON TOP of the org C/C++ base image
# (ghcr.io/mayhemheroes/base). The base provides debian + clang/llvm + libFuzzer + the
# identities + the build-contract ENV. typst is a RUST workspace, and the base ships NO Rust
# toolchain, so this image installs rustup (nightly) + cargo-fuzz as root into a SHARED
# location (/opt/rust) usable by the non-root `mayhem` user, then runs build.sh + test.sh.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t typst-commit:test .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never bake it as ENV — an empty value
# breaks clang. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default,
# but cargo-fuzz drives Rust instrumentation via RUSTFLAGS (-Zsanitizer=address), NOT $SANITIZER_FLAGS.
# Declared here for parity; build.sh wires ASan into RUSTFLAGS the cargo-fuzz way.
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# Pin the nightly toolchain (cargo-fuzz needs nightly for `-Z` flags / -Zsanitizer=address).
# typst pins no rust-toolchain file, but its workspace sets `rust-version = "1.92"` and several
# deps (hayro/krilla) require rustc >= 1.92, so we cannot use the older shared nightly-2025-09-05
# (that reports as 1.91.0-nightly and is rejected). Use a nightly new enough to satisfy 1.92.
ARG RUST_TOOLCHAIN=nightly-2025-11-15
ARG CARGO_FUZZ_VERSION=0.12.0

# Shared Rust install under /opt/toolchains/rust (§6.2 item 8 — $HOME-independent so the toolchain
# + cargo registry resolve identically at the commit tier and at the air-gapped PATCH re-run),
# world-readable so the non-root `mayhem` user can invoke cargo/rustc/cargo-fuzz without owning it.
ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:$PATH

USER root
RUN set -eux; \
    mkdir -p "$RUSTUP_HOME" "$CARGO_HOME"; \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal --default-toolchain "$RUST_TOOLCHAIN"; \
    rustup component add rust-src --toolchain "$RUST_TOOLCHAIN"; \
    cargo install cargo-fuzz --version "$CARGO_FUZZ_VERSION" --locked; \
    # Hand the whole toolchain prefix to uid 2000 (`mayhem`). The non-root build (a) WRITES into
    # CARGO_HOME (registry cache, git checkouts) and (b) `objcopy --strip-debug`s the bundled Rust
    # ASan runtime archive in build.sh to enforce DWARF < 4 (§6.2 item 10) — both need write access.
    # Build image, not a hardened runtime. (Same as the tar-rs/unsafe-libyaml Rust integrations.)
    chown -R 2000:2000 /opt/toolchains/rust; \
    rustc --version; cargo --version; cargo fuzz --version
USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history)
# is copied to /mayhem as `mayhem`; build.sh builds in place.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run typst's parser/util unit tests at build time; a failing suite fails the image build.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
