#!/usr/bin/env bash
# Assemble LyraReader.app (SwiftPM artifacts + Info.plist + optional PDFium + code signing).
#
# Usage: ./scripts/make-app-bundle.sh [--debug] [--no-sign]
#
# Artifacts: build/LyraReader.app
#
# The bundle and its SwiftPM executable are both named LyraReader.
#
# Works under Command Line Tools (no actool / stapler; see docs/09-dev-setup.md §2.1).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="release"
SIGN=1
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG="debug" ;;
    --no-sign) SIGN=0 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
  esac
done

APP="$ROOT/build/LyraReader.app"
PDFIUM_LIB="$ROOT/vendor/pdfium/lib/libpdfium.dylib"

mkdir -p "$ROOT/build"
echo "==> swift build -c $CONFIG"
BUILD_ARGS=(-c "$CONFIG")
if ! (cd apps/macos && swift build "${BUILD_ARGS[@]}" --product LyraReader) >"$ROOT/build/swift-bundle.log" 2>&1; then
  if grep -q "sandbox_apply" "$ROOT/build/swift-bundle.log"; then
    # A restricted sandbox (CI / agent environments) does not allow SwiftPM's nested sandbox-exec
    BUILD_ARGS+=(--disable-sandbox)
    echo "    (this environment forbids SwiftPM's nested sandbox; retrying with --disable-sandbox)"
    (cd apps/macos && swift build "${BUILD_ARGS[@]}" --product LyraReader)
  else
    cat "$ROOT/build/swift-bundle.log" >&2
    exit 1
  fi
fi
BIN_DIR="$(cd apps/macos && swift build "${BUILD_ARGS[@]}" --product LyraReader --show-bin-path)"
BIN="$BIN_DIR/LyraReader"
[ -x "$BIN" ] || { echo "Executable not found: $BIN" >&2; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/LyraReader"
cp apps/macos/Support/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -f "$ROOT/apps/macos/Support/AppIcon.icns" ]; then
  cp "$ROOT/apps/macos/Support/AppIcon.icns" "$APP/Contents/Resources/"
fi

# The appearance font and its licence ship side by side. The Rust writer resolves this path at
# run time (see crates/lyra-reader-pdfium/src/appearance_font.rs), so the bundle is the source of
# truth and the executable does not carry a second copy.
if [ -d "$ROOT/apps/macos/Resources/Fonts" ]; then
  echo "==> Bundling appearance font"
  mkdir -p "$APP/Contents/Resources/Fonts"
  cp -R "$ROOT/apps/macos/Resources/Fonts/." "$APP/Contents/Resources/Fonts/"
fi

# ── PDFium (dynamic library: fix install_name, then re-sign) ──────────────────
if [ -f "$PDFIUM_LIB" ]; then
  echo "==> Bundling PDFium"
  cp "$PDFIUM_LIB" "$APP/Contents/Frameworks/libpdfium.dylib"
  install_name_tool -id @rpath/libpdfium.dylib "$APP/Contents/Frameworks/libpdfium.dylib"
  if ! otool -l "$APP/Contents/MacOS/LyraReader" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/LyraReader"
  fi
  if [ -d "$ROOT/vendor/pdfium/licenses" ]; then
    mkdir -p "$APP/Contents/Resources/ThirdPartyLicenses"
    cp -R "$ROOT/vendor/pdfium/licenses/." "$APP/Contents/Resources/ThirdPartyLicenses/" 2>/dev/null || true
  fi
  [ "$SIGN" = "1" ] && codesign --force --sign - "$APP/Contents/Frameworks/libpdfium.dylib"
else
  echo "==> No PDFium found (optional, needed from M1 on): run ./scripts/fetch-pdfium.sh"
fi

if [ "$SIGN" = "1" ]; then
  echo "==> ad-hoc signing (personal use; distribution requires Developer ID + notarization)"
  codesign --force --sign - "$APP"
  codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /' || true
fi

echo
echo "Done: $APP"
echo "Run:  open \"$APP\"      (if Gatekeeper blocks it on first launch: right-click → Open)"
