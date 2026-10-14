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

LIB_DIR="${CARGO_TARGET_DIR:-${CARGO_TARGET_DIR:-$ROOT/target}}/$PROFILE"
DST_DIR="$ROOT/apps/macos/.rust/lib"
mkdir -p "$DST_DIR"

for name in libaris_reader_ffi.a libaris_reader_ffi.dylib; do
  if [ -f "$LIB_DIR/$name" ]; then
    cp "$LIB_DIR/$name" "$DST_DIR/"
    echo "    copied $name → apps/macos/.rust/lib/"
  fi
done

# ── UniFFI bindings (task T0.8) ──────────────────────────────────────────────
# The control plane (objects, records, errors) is generated from the Rust interface in
# crates/aris-reader-ffi/src/api.rs. Generated sources are NOT committed: run this
# script after a fresh clone, before `swift build`.
LIB="$LIB_DIR/libaris_reader_ffi.dylib"
if [ -f "$LIB" ]; then
  BINDINGS_DIR="$ROOT/apps/macos/Sources/ArisReaderBindings"
  HEADERS_DIR="$ROOT/apps/macos/Sources/ArisReaderFFI/include"

  echo "==> Generating UniFFI Swift bindings"
  rm -rf "$BINDINGS_DIR"
  mkdir -p "$BINDINGS_DIR" "$HEADERS_DIR"
  cargo run -q -p aris-reader-ffi --bin uniffi-bindgen -- generate \
    --library "$LIB" --language swift --out-dir "$BINDINGS_DIR"

  # SwiftPM generates the modulemap for the C target itself. The scaffolding header must
  # NOT be named after that target: SwiftPM would treat it as the umbrella header and
  # hide the hand-written data-plane declarations (aris_reader_ffi.h).
  cp "$BINDINGS_DIR"/*FFI.h "$HEADERS_DIR/uniffi_scaffolding.h"
  rm -f "$BINDINGS_DIR"/*.modulemap "$BINDINGS_DIR"/*.h
  echo "    bindings: $(ls "$BINDINGS_DIR" | tr '\n' ' ')"
  echo "    header  : include/uniffi_scaffolding.h"
else
  echo "==> Skipping UniFFI bindings (libaris_reader_ffi.dylib not built)"
fi

echo
echo "Done. Next steps:"
echo "  cd apps/macos && swift build        # requires a working Swift toolchain (docs/09-dev-setup.md §2)"
echo "  ./scripts/make-app-bundle.sh        # package into a .app"
