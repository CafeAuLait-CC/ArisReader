#!/usr/bin/env bash
# ArisReader environment self-check + build check.
#
# Usage: ./scripts/check.sh [--no-swift]
#
# Does four things:
#   1. Print toolchain facts (Rust / Swift / SDK / Xcode / PDFium)
#   2. Diagnose known Swift toolchain mismatches (see docs/09-dev-setup.md §2)
#   3. cargo check / test / clippy
#   4. swift build + ArisReaderChecks (only when the Swift probe passes)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SKIP_SWIFT=0
for arg in "$@"; do
  case "$arg" in
    --no-swift) SKIP_SWIFT=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
  esac
done

mkdir -p "$ROOT/build"

PASS=0
FAIL=0
WARN=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; WARN=$((WARN + 1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── 1. Toolchain facts ────────────────────────────────────────────────────────
section "Toolchain"
printf '  macOS      : %s (%s)\n' "$(sw_vers -productVersion 2>/dev/null)" "$(uname -m)"
printf '  rustc      : %s\n' "$(rustc --version 2>/dev/null || echo 'missing')"
printf '  cargo      : %s\n' "$(cargo --version 2>/dev/null || echo 'missing')"

DEV_DIR="$(xcode-select -p 2>/dev/null || echo 'unknown')"
printf '  developer  : %s\n' "$DEV_DIR"
if [ -d /Applications/Xcode.app ] || ls -d /Applications/Xcode*.app >/dev/null 2>&1; then
  ok "Full Xcode detected (actool / metallib / XCTest / stapler / Instruments available)"
else
  warn "Command Line Tools only: no actool / metallib / XCTest / stapler (wgpu does not need metallib, see docs/adr/0006)"
fi

if [ -f vendor/pdfium/lib/libpdfium.dylib ]; then
  ok "PDFium is ready: $(lipo -archs vendor/pdfium/lib/libpdfium.dylib 2>/dev/null || echo '?')"
else
  warn "PDFium not downloaded (needed from M1 on): run ./scripts/fetch-pdfium.sh"
fi

# ── 2. Swift toolchain diagnostics ────────────────────────────────────────────
section "Swift toolchain diagnostics"
SWIFT_OK=0
if ! command -v swiftc >/dev/null 2>&1; then
  bad "swiftc not found"
else
  COMPILER_LINE="$(swiftc --version 2>&1 | head -1)"
  printf '  compiler   : %s\n' "$COMPILER_LINE"
  CC_VER="$(printf '%s' "$COMPILER_LINE" | sed -nE 's/.*swiftlang-([0-9.]+).*/\1/p')"

  SDK_VER="?"
  SDK_PATH="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
  if [ -n "$SDK_PATH" ]; then
    printf '  sdk        : %s (macOS %s)\n' "$SDK_PATH" "$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo '?')"
    IFACE="$(ls "$SDK_PATH"/usr/lib/swift/Swift.swiftmodule/*.swiftinterface 2>/dev/null | head -1)"
    if [ -n "$IFACE" ]; then
      SDK_VER="$(grep -m1 -o 'user-module-version [0-9.]*' "$IFACE" | awk '{print $2}')"
    fi
  fi
  # For diagnostics only: a version mismatch does **not** necessarily mean trouble (on CLT 26.3 the SDK reports
  # 6.2.3.3.2 while the compiler is 6.2.4.1.4 and compilation still works), so usability is decided by the probe below.
  printf '  swift mod  : %s (in SDK) vs %s (compiler)\n' "$SDK_VER" "${CC_VER:-?}"

  # Ground truth: actually compile once (more reliable than any heuristic)
  PROBE_DIR="$ROOT/build/swift-probe"
  mkdir -p "$PROBE_DIR"
  printf 'import AppKit\nimport Metal\nprint("swift-probe-ok")\n' > "$PROBE_DIR/probe.swift"
  if swiftc -module-cache-path "$PROBE_DIR/modulecache" \
       "$PROBE_DIR/probe.swift" -o "$PROBE_DIR/probe" > "$PROBE_DIR/probe.log" 2>&1; then
    ok "Swift compile probe passed ($( "$PROBE_DIR/probe" 2>/dev/null || echo 'ok'))"
    SWIFT_OK=1
  else
    bad "Swift compile probe failed"
    sed -n '1,6p' "$PROBE_DIR/probe.log" | sed 's/^/      /'
    if [ "$SDK_VER" != "${CC_VER:-?}" ]; then
      printf '\n      \033[1mHint\033[0m: the Swift module in the SDK (%s) and the compiler (%s) are from different builds\n' "$SDK_VER" "${CC_VER:-?}"
    fi
    if grep -q "is not supported by the compiler" "$PROBE_DIR/probe.log"; then
      printf '      \033[1mDiagnosis\033[0m: SDK and compiler are not from the same release (docs/09-dev-setup.md §2)\n'
      printf '      Fix: reinstall Command Line Tools, or install the full Xcode\n'
      printf '            sudo rm -rf /Library/Developer/CommandLineTools && sudo xcode-select --install\n'
    fi
    if grep -q "redefinition of module 'SwiftBridging'" "$PROBE_DIR/probe.log"; then
      printf '      \033[1mDiagnosis\033[0m: a stale swift/module.modulemap left in the CLT conflicts with the new bridging.modulemap\n'
      printf '      Conservative fix (reversible): sudo mv /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap{,.stale}\n'
    fi
    printf '      The Rust side is unaffected: you can continue on the "Rust first" track (route P-C in docs/07-roadmap.md)\n'
  fi
fi

# ── 3. Rust ───────────────────────────────────────────────────────────────────
section "Rust workspace"
if cargo check --workspace --quiet 2>"$ROOT/build/cargo-check.log"; then
  ok "cargo check --workspace"
else
  bad "cargo check --workspace (see build/cargo-check.log)"
  tail -20 "$ROOT/build/cargo-check.log" | sed 's/^/      /'
fi

if cargo test --workspace --quiet >"$ROOT/build/cargo-test.log" 2>&1; then
  TESTS="$(grep -oE '[0-9]+ passed' "$ROOT/build/cargo-test.log" | awk '{s += $1} END {print s + 0}')"
  ok "cargo test --workspace (${TESTS:-?} tests passed)"
else
  bad "cargo test --workspace (see build/cargo-test.log)"
  grep -E "^(error|failures)" "$ROOT/build/cargo-test.log" | head -10 | sed 's/^/      /'
fi

if cargo clippy --version >/dev/null 2>&1; then
  if cargo clippy --workspace --all-targets --quiet -- -D warnings >"$ROOT/build/clippy.log" 2>&1; then
    ok "cargo clippy -D warnings"
  else
    warn "cargo clippy reported warnings (see build/clippy.log)"
  fi
else
  warn "clippy not installed: rustup component add clippy"
fi

if cargo fmt --version >/dev/null 2>&1; then
  if cargo fmt --all --check >/dev/null 2>&1; then
    ok "cargo fmt --check"
  else
    warn "formatting differs: run cargo fmt"
  fi
fi

# ── 4. Swift build ────────────────────────────────────────────────────────────
section "Native macOS shell"
SWIFT_BUILT=0
if [ "$SKIP_SWIFT" = "1" ]; then
  warn "skipped (--no-swift)"
elif [ "$SWIFT_OK" = "1" ]; then
  # In a restricted sandbox (including CI/agent environments) SwiftPM's nested sandbox-exec is rejected, so fall back to --disable-sandbox
  if (cd apps/macos && swift build >"$ROOT/build/swift-build.log" 2>&1); then
    ok "swift build (apps/macos)"
    SWIFT_BUILT=1
  elif grep -q "sandbox_apply" "$ROOT/build/swift-build.log" \
    && (cd apps/macos && swift build --disable-sandbox >"$ROOT/build/swift-build.log" 2>&1); then
    ok "swift build (apps/macos, --disable-sandbox: this environment forbids SwiftPM's nested sandbox-exec)"
    SWIFT_BUILT=1
  else
    bad "swift build failed (see build/swift-build.log)"
    tail -15 "$ROOT/build/swift-build.log" | sed 's/^/      /'
  fi
else
  warn "skipping swift build (compile probe did not pass)"
fi

if [ "$SWIFT_BUILT" = "1" ]; then
  if ARIS_READER_PDFIUM_PATH="${ARIS_READER_PDFIUM_PATH:-$ROOT/vendor/pdfium/lib/libpdfium.dylib}" \
    "$ROOT/apps/macos/.build/debug/ArisReaderChecks" "$ROOT" >"$ROOT/build/reader-checks.log" 2>&1; then
    ok "ArisReaderChecks (complete native regression suite)"
  else
    bad "ArisReaderChecks failed (see build/reader-checks.log)"
    tail -30 "$ROOT/build/reader-checks.log"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
section "Summary"
WARN_LABEL="warnings"
[ "$WARN" -eq 1 ] && WARN_LABEL="warning"
printf '  %d passed · %d %s · %d failed\n' "$PASS" "$WARN" "$WARN_LABEL" "$FAIL"
if [ "$SWIFT_OK" != "1" ]; then
  printf '  \033[33mNote\033[0m: Swift toolchain unavailable → the UI is blocked, but the Rust engine can proceed as usual (route P-C)\n'
  printf '        Fix: docs/09-dev-setup.md §2 (install Xcode or reinstall the CLT)\n'
fi
[ "$FAIL" -eq 0 ] || exit 1
