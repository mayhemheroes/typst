#!/usr/bin/env bash
#
# typst/mayhem/test.sh — RUN a tractable subset of typst/typst's own test suite (`cargo test`) and
# emit a CTRF summary. exit 0 iff no test failed.
#
# SCOPE (documented): typst's FULL test suite is the `typst-tests` integration crate
# (tests/src/tests.rs), which compiles ~the entire workspace, downloads/uses the typst-dev-assets +
# typst-assets font/image fixtures, and renders thousands of reference documents — far too heavy/slow
# and asset-dependent for a self-contained, deterministic build-time oracle. Instead we run the
# in-crate UNIT tests of the parser/lexer/AST crate that the `parse` fuzz target exercises directly:
#
#   typst-syntax  — lexer, parser, reparser, AST, source/lines/span, highlighting, set, kind, node,
#                   package + path parsing. These #[test]s assert CONCRETE parse trees, reparse
#                   equivalence, token kinds, and span arithmetic (assert_eq! / golden comparisons).
#   typst-utils   — the supporting collections/bit-set/hashing utilities (also pure, no assets).
#
# PATCH-grade oracle: these are byte/structure-exact assertions on parser output and utility
# behavior, so a no-op / "exit(0)" / output-altering patch to the lexer/parser CANNOT pass. They are
# fully self-contained (no font/dev-asset downloads). This script only RUNS the suite via
# `cargo test`; it never builds fuzz targets.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not available — cannot run the test suite" >&2
  emit_ctrf "cargo-test" 0 1 0; exit 2
fi

echo "=== running cargo test (typst parser/util crates: typst-syntax + typst-utils) ==="
# Use the image's DEFAULT toolchain (the Dockerfile pins it to the same nightly the fuzz build
# uses), so no `+toolchain` override — that would make rustup try to install a different channel
# into the read-only shared /opt/rust. --no-fail-fast so we count every test; RUSTFLAGS cleared so
# it inherits nothing from the sanitizer build. Scope to the self-contained parser/util crates.
out="$(RUSTFLAGS="" cargo test -p typst-syntax -p typst-utils --no-fail-fast --jobs "$MAYHEM_JOBS" 2>&1)"; rc=$?
echo "$out"

# libtest prints one line per test binary:
#   test result: ok. 12 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; ...
# Sum across all binaries.
PASSED=0; FAILED=0; IGNORED=0
while read -r p f i; do
  PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f )); IGNORED=$(( IGNORED + i ))
done < <(printf '%s\n' "$out" \
  | sed -n 's/^test result:.* \([0-9][0-9]*\) passed; \([0-9][0-9]*\) failed; \([0-9][0-9]*\) ignored.*/\1 \2 \3/p')

# If we parsed no result lines, fall back to the cargo exit code (e.g. compile error).
if [ "$(( PASSED + FAILED + IGNORED ))" -eq 0 ]; then
  echo "could not parse any 'test result:' lines; using cargo exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "cargo-test" 1 0 0; exit 0; }
  emit_ctrf "cargo-test" 0 1 0; exit 1
fi

emit_ctrf "cargo-test" "$PASSED" "$FAILED" "$IGNORED"
