#!/usr/bin/env bash
# Build the Rust-side artifacts: static library (for SwiftPM to link) + (after M0 T0.8) UniFFI Swift bindings.
#
# Usage: ./scripts/build-rust.sh [--debug]
#
# Artifacts:
#   target/<profile>/libaris_reader_ffi.a            (static library)
#   apps/macos/.rust/lib/libaris_reader_ffi.a        (SwiftPM link directory, gitignored)
#   apps/macos/Sources/ArisReaderFFI/Generated/     (generated Swift bindings, gitignored)
#   apps/macos/Sources/aris_reader_ffiFFI/           (C header + modulemap, gitignored)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROFILE="release"
CARGO_FLAG="--release"
for arg in "$@"; do
  case "$arg" in
    --debug) PROFILE="debug"; CARGO_FLAG="" ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
  esac
done

echo "==> cargo build -p aris-reader-ffi $CARGO_FLAG"
cargo build -p aris-reader-ffi $CARGO_FLAG

LIB_DIR="$ROOT/target/$PROFILE"
DST_DIR="$ROOT/apps/macos/.rust/lib"
mkdir -p "$DST_DIR"

for name in libaris_reader_ffi.a libaris_reader_ffi.dylib; do
  if [ -f "$LIB_DIR/$name" ]; then
    cp "$LIB_DIR/$name" "$DST_DIR/"
    echo "    copied $name → apps/macos/.rust/lib/"
  fi
done

# ── UniFFI binding generation (M0 T0.8) ───────────────────────────────────────
if cargo metadata --format-version 1 --no-deps 2>/dev/null | grep -q '"uniffi"'; then
  echo "==> Generating UniFFI Swift bindings"
  OUT_SWIFT="$ROOT/apps/macos/Sources/ArisReaderFFI/Generated"
  OUT_FFI="$ROOT/apps/macos/Sources/aris_reader_ffiFFI"
  mkdir -p "$OUT_SWIFT" "$OUT_FFI"
  cargo run -p aris-reader-ffi --bin uniffi-bindgen -- generate \
    --library "$LIB_DIR/libaris_reader_ffi.dylib" \
    --language swift --out-dir "$OUT_SWIFT"
  cp "$OUT_SWIFT"/*.h "$OUT_FFI/" 2>/dev/null || true
  cp "$OUT_SWIFT"/*.modulemap "$OUT_FFI/module.modulemap" 2>/dev/null || true
else
  echo "==> Skipping UniFFI bindings (not wired up yet, see task T0.8)"
  echo "    Once wired up, this script generates the Swift bindings into apps/macos/Sources/ArisReaderFFI/Generated/"
fi

echo
echo "Done. Next steps:"
echo "  cd apps/macos && swift build        # requires a working Swift toolchain (docs/09-dev-setup.md §2)"
echo "  ./scripts/make-app-bundle.sh        # package into a .app"
