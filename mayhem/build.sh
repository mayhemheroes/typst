#!/usr/bin/env bash
#
# typst/mayhem/build.sh — build typst/typst's cargo-fuzz targets as sanitized libFuzzer binaries,
# replicating OSS-Fuzz's Rust path (oss-fuzz/projects/typst/build.sh, which runs
# `cargo +nightly fuzz build -O --debug-assertions` from tests/fuzz and ships every
# tests/fuzz/src/bin/*.rs binary).
#
# typst is a large pure-Rust typesetting workspace. The cargo-fuzz crate `typst-fuzz` lives at
# tests/fuzz and is a WORKSPACE MEMBER (root Cargo.toml `members = [.., "tests/fuzz", ..]`), so
# `cargo fuzz build` emits its binaries under the WORKSPACE-ROOT target dir
# ($SRC/target/<triple>/release), not tests/fuzz/target. We resolve that dir via `cargo metadata`
# (robust to layout changes) and fall back to the conventional path.
#
# cargo-fuzz drives the build:
#   - it provides its own libFuzzer runtime (the produced binary IS a libFuzzer target — Mayhem
#     runs it directly via `libfuzzer: true`);
#   - ASan is enabled the Rust way, through RUSTFLAGS `-Zsanitizer=address` (NOT clang's
#     $SANITIZER_FLAGS / CFLAGS — those don't apply to rustc), which is exactly what OSS-Fuzz's
#     `compile` sets for FUZZING_LANGUAGE=rust. nightly is required for `-Zsanitizer`.
#
# Targets (tests/fuzz/src/bin/*.rs — all built by `cargo fuzz build` in tests/fuzz):
#   parse   — typst_syntax::parse on the input as typst source (parser fuzzing).
#   paged   — compile the source to a PagedDocument, then render PNG + SVG + PDF (full pipeline).
#   html    — compile the source to an HtmlDocument, then emit HTML.
#   compile — compile the source to a PagedDocument, then render the first page (the historical
#             OSS-Fuzz/mayhemheroes target, restored for parity with the archived original — see
#             tests/fuzz/src/bin/compile.rs, auto-discovered as a [[bin]] under edition-2024 autobins).
# All take the input as a typst-source `&str`.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer (kept for parity even
# though the Rust build doesn't invoke clang directly; cargo's cc-built deps might).
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS

# ── Memory-bounded parallelism (avoid OOM-kill on constrained CI runners) ─────────────────────────
# Each parallel ASan + full-debuginfo rustc/link can use ~2 GB. On a many-core host cargo would spawn
# nproc jobs and the final ASan links of the 4 fuzz targets run concurrently — multiplying peak RAM
# and OOM-killing (exit 137) a small GitHub runner (~7-16 GB). We bound parallelism to the available
# memory budget: jobs = min(nproc, mem_GB/4, max 16), floor 1. The /4 budgets ~4 GB per parallel
# rustc — typst-library's single-threaded frontend alone peaks ~4-5 GB under ASan + full debuginfo
# (codegen-units does NOT shrink the frontend), so a smaller budget OOMs. Reads the cgroup limit
# first (so `docker run/build --memory=7g` is respected), falling back to physical RAM. On a big box
# this is min(nproc,16); under a 7 GB cap it collapses to 1 (serial, slow but it fits). cargo-fuzz
# has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS. (Target LINKS are serialized below.)
detect_mem_gb() {
  local bytes=""
  [ -r /sys/fs/cgroup/memory.max ] && bytes="$(cat /sys/fs/cgroup/memory.max 2>/dev/null)"          # cgroup v2
  case "$bytes" in ''|max) bytes="";; esac
  [ -z "$bytes" ] && [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ] && \
    bytes="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)"                            # cgroup v1
  # treat absurd "unlimited" sentinels as unset → fall back to physical RAM
  if [ -n "$bytes" ] && [ "$bytes" -gt 0 ] 2>/dev/null && [ "$bytes" -lt 1000000000000000 ] 2>/dev/null; then
    echo $(( bytes / 1024 / 1024 / 1024 )); return
  fi
  awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 8
}
MEM_GB="$(detect_mem_gb)"; [ "${MEM_GB:-0}" -ge 1 ] 2>/dev/null || MEM_GB=8
MEM_CAP_JOBS=$(( MEM_GB / 4 )); [ "$MEM_CAP_JOBS" -ge 1 ] || MEM_CAP_JOBS=1
JOBS="$MAYHEM_JOBS"
[ "$JOBS" -gt "$MEM_CAP_JOBS" ] && JOBS="$MEM_CAP_JOBS"
[ "$JOBS" -gt 16 ] && JOBS=16          # diminishing returns past 16; keeps peak RAM sane on big hosts
export CARGO_BUILD_JOBS="$JOBS"
echo "build parallelism: MAYHEM_JOBS=$MAYHEM_JOBS MEM_GB=$MEM_GB -> CARGO_BUILD_JOBS=$CARGO_BUILD_JOBS"

# ── Release-profile memory overrides (the real OOM fix) ───────────────────────────────────────────
# typst's root [profile.release] sets `lto = "thin"` + `codegen-units = 1`, which `cargo fuzz build`
# inherits. Whole-program thin-LTO codegen at LINK time and single-codegen-unit crate compiles each
# need many GB under ASan + full debuginfo — a single LTO link of a workspace this large can blow
# past a 7-16 GB CI runner on its own (OOM-kill / exit 137), no matter how few targets link at once.
# Override the release profile for THIS build via cargo's env knobs (NOT a Cargo.toml edit, so the
# integration stays additive): turn LTO off and split codegen into 16 units. This slashes peak
# link/compile RAM while preserving the fuzz binaries' sanitizers, opt-level, behavior, and — crucial
# for §6.2 item 10 — the DWARF debuginfo (we do NOT lower debuginfo to save memory).
export CARGO_PROFILE_RELEASE_LTO=off
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16

cd "$SRC"

TRIPLE="x86_64-unknown-linux-gnu"

# Every tests/fuzz/src/bin/*.rs. `parse`/`paged`/`html` are upstream's; `compile` is the restored
# archive target (tests/fuzz/src/bin/compile.rs, auto-discovered by cargo, NOT a Cargo.toml edit).
FUZZ_TARGETS=(
  parse
  paged
  html
  compile
)

# §6.2 item 10 — debug-info contract: every fuzz binary MUST carry a .debug_info section with DWARF
# version < 4 (Mayhem's triage cannot read DWARF >= 4, and recent rustc/LLVM default to DWARF 5).
# $RUST_DEBUG_FLAGS forces our Rust code's DWARF to version 2 via LLVM (and keeps full debuginfo +
# frame pointers). The rlenv PATCH tier may export RUST_DEBUG_FLAGS before the offline re-run; the
# `:-` default only applies when unset/empty.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=--dwarf-version=2}"
export RUST_DEBUG_FLAGS

# ── DWARF < 4 enforcement (§6.2 item 10) ─────────────────────────────────────────────────────────
# RUST_DEBUG_FLAGS alone is NECESSARY but NOT SUFFICIENT: Rust's nightly ASan runtime
# (librustc-nightly_rt.asan.a) is precompiled with the bundled LLVM at DWARF 5 and is linked BEFORE
# the project code, so without intervention the FIRST compilation unit in the final binary's
# .debug_info is DWARF 5 — failing the verify-repo check on every target. Fix: strip the debug
# sections from the ASan archive ONCE (idempotent — stripping an already-stripped archive is a
# no-op), so it contributes no debug info and our project's DWARF-2 CU appears first. The stripped
# .a is baked into the image, so the offline PATCH re-run sees the same file and reproduces it.
ASAN_RT="$(find "$RUSTUP_HOME/toolchains" -name "librustc-nightly_rt.asan.a" 2>/dev/null | head -1)"
if [ -n "$ASAN_RT" ] && [ -f "$ASAN_RT" ]; then
  echo "Stripping debug info from Rust ASan runtime to enforce DWARF < 4: $ASAN_RT"
  objcopy --strip-debug "$ASAN_RT"
fi

# libfuzzer-sys compiles libFuzzer from C++ via the cc crate; force DWARF 3 so those CUs also
# satisfy the check (the cc crate respects CFLAGS/CXXFLAGS). On the offline re-run these flags are
# identical, so cargo reuses the cached libfuzzer.a (stable fingerprint) without recompiling.
export CFLAGS="${CFLAGS:+$CFLAGS }-gdwarf-3"
export CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }-gdwarf-3"

# Replicate OSS-Fuzz `compile` RUSTFLAGS for a libFuzzer+ASan Rust build. cargo-fuzz sets the ASan
# flag itself by default, but we set it explicitly so the behavior is pinned and visible. `--cfg
# fuzzing` matches what libfuzzer-sys expects. $RUST_DEBUG_FLAGS adds DWARF-2 debug info + frame
# pointers; combined with the stripped ASan runtime the first .debug_info CU is < 4 (§6.2 item 10).
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address ${RUST_DEBUG_FLAGS}"

echo "=== cargo fuzz build (image-default nightly toolchain, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"

# OSS-Fuzz runs `cargo fuzz build` from tests/fuzz; cargo-fuzz reads its targets from the crate's
# own Cargo.toml. We build ONE TARGET AT A TIME (not a single all-targets pass) so only one ASan +
# full-debuginfo executable link is resident at once — linking all 4 (compile/html/paged/parse)
# concurrently multiplied peak RAM and OOM-killed the CI runner. Shared deps compile during the
# first target and are cached for the rest, so the cost is bounded memory, not 4x work.
# Use the image's DEFAULT toolchain (Dockerfile pins it to the required nightly); a `+toolchain`
# override would make rustup try to install a different channel into the read-only shared toolchain.
# `-O` (release w/ opt) + `--debug-assertions` mirrors OSS-Fuzz's build.sh. cargo-fuzz 0.12 doesn't
# accept --jobs; parallelism is via CARGO_BUILD_JOBS (capped above). NB: typst is a big workspace.
#
# `compile` is the restored archive target. Its source lives in the ADDITIVE overlay
# (mayhem/fuzz_targets/compile.rs) so the integration never adds a file to upstream's tree; stage it
# into the cargo-fuzz bin dir at BUILD time (where cargo auto-discovers [[bin]]s). Idempotent: re-runs
# (incl. the offline PATCH rebuild) just overwrite an identical file. `parse`/`paged`/`html` are
# upstream's own targets and need no staging.
mkdir -p "$SRC/tests/fuzz/src/bin"
cp "$SRC/mayhem/fuzz_targets/compile.rs" "$SRC/tests/fuzz/src/bin/compile.rs"

cd "$SRC/tests/fuzz"
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- cargo fuzz build (target: $t, from tests/fuzz) ---"
  cargo fuzz build -O --debug-assertions "$t"
done
cd "$SRC"

# `tests/fuzz` is a workspace member, so cargo-fuzz emits binaries under the WORKSPACE-ROOT target
# dir ($SRC/target/<triple>/release) — exactly the path OSS-Fuzz's build.sh uses
# (FUZZ_TARGET_OUTPUT_DIR=$SRC/typst/target/x86_64-unknown-linux-gnu/release). Resolve it from
# cargo metadata so we're robust to layout changes, falling back to the conventional path.
TARGET_DIR="$(cargo metadata --no-deps --format-version 1 2>/dev/null \
  | sed -n 's/.*"target_directory":"\([^"]*\)".*/\1/p')"
[ -n "$TARGET_DIR" ] || TARGET_DIR="$SRC/target"
RELEASE_DIR="$TARGET_DIR/$TRIPLE/release"
echo "RELEASE_DIR=$RELEASE_DIR"

for t in "${FUZZ_TARGETS[@]}"; do
  bin="$RELEASE_DIR/$t"
  if [ ! -x "$bin" ]; then
    echo "ERROR: expected fuzz binary not found at $bin" >&2
    echo "--- contents of $RELEASE_DIR ---" >&2
    ls -la "$RELEASE_DIR" 2>&1 >&2 || true
    exit 1
  fi
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

echo "build.sh complete:"
ls -la "${FUZZ_TARGETS[@]/#//mayhem/}" 2>&1 || true
