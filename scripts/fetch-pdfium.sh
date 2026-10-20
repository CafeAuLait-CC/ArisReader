#!/usr/bin/env bash
# Download the pinned PDFium dynamic library for macOS or Linux (bblanchon/pdfium-binaries, MIT).
#
# Usage: ./scripts/fetch-pdfium.sh [--universal] [--tag <release-tag>]
#
# Artifacts: vendor/pdfium/{lib/libpdfium.dylib (macOS) or lib/libpdfium.so (Linux), include/, licenses/, VERSION}
#
# Why post-processing is needed (docs/09-dev-setup.md §4):
#   * the prebuilt package's install_name is the relative path "./libpdfium.dylib"; it must become @rpath/...
#     so the library can live in .app/Contents/Frameworks and be found through rpath;
#   * it is adhoc/linker-signed and must be re-signed once inside the .app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TAG="chromium/8100"
UNIVERSAL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --universal) UNIVERSAL=1; shift ;;
    --tag) TAG="${2:?--tag requires a release tag}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

PLATFORM="$(uname -s)"
ARCH="$(uname -m)"
if [ "$PLATFORM" = "Linux" ]; then
  [ "$UNIVERSAL" = "0" ] || { echo "--universal is macOS-only" >&2; exit 1; }
  case "$ARCH" in
    aarch64|arm64) ASSET="pdfium-linux-arm64.tgz" ;;
    x86_64) ASSET="pdfium-linux-x64.tgz" ;;
    *) echo "Unsupported Linux architecture: $ARCH" >&2; exit 1 ;;
  esac
elif [ "$PLATFORM" != "Darwin" ]; then
  echo "Unsupported platform: $PLATFORM" >&2
  exit 1
elif [ "$UNIVERSAL" = "1" ]; then
  ASSET="pdfium-mac-univ.tgz"
else
  case "$ARCH" in
    arm64)  ASSET="pdfium-mac-arm64.tgz" ;;
    x86_64) ASSET="pdfium-mac-x64.tgz" ;;
    *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
  esac
fi

if [ "$TAG" = "latest" ]; then
  URL="https://github.com/bblanchon/pdfium-binaries/releases/latest/download/$ASSET"
else
  URL="https://github.com/bblanchon/pdfium-binaries/releases/download/$TAG/$ASSET"
fi

DEST="$ROOT/vendor/pdfium"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading ${ASSET} (${TAG})"
curl -fL --retry 3 --connect-timeout 15 -o "$TMP/$ASSET" "$URL"

if [ "$TAG" = "chromium/8100" ]; then
  expected="$(awk -v asset="$ASSET" '$2 == asset {print $1}' "$ROOT/scripts/pdfium-sha256.txt")"
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$TMP/$ASSET" | awk '{print $1}')"
  else
    actual="$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')"
  fi
  [ -n "$expected" ] && [ "$actual" = "$expected" ] || { echo "PDFium checksum mismatch" >&2; exit 1; }
else
  echo "WARNING: explicit non-baseline PDFium tag $TAG; no committed checksum" >&2
fi

echo "==> Unpacking into $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
tar -xzf "$TMP/$ASSET" -C "$DEST"

if [ "$PLATFORM" = "Darwin" ]; then
  LIB="$DEST/lib/libpdfium.dylib"
  [ -f "$LIB" ] || { echo "lib/libpdfium.dylib not found in the package" >&2; exit 1; }
  echo "==> Fixing install_name and signing"
  install_name_tool -id @rpath/libpdfium.dylib "$LIB"
  codesign --force --sign - "$LIB"
else
  LIB="$DEST/lib/libpdfium.so"
  [ -f "$LIB" ] || { echo "lib/libpdfium.so not found in the package" >&2; exit 1; }
fi

echo
echo "Done: $LIB"
printf '  size      : %s\n' "$(du -h "$LIB" | cut -f1)"
[ -f "$DEST/VERSION" ] && printf '  version   : %s\n' "$(cat "$DEST/VERSION")"
[ -d "$DEST/licenses" ] && printf '  licenses  : %s file(s) (shipped alongside the app)\n' "$(ls "$DEST/licenses" | wc -l | tr -d ' ')"
echo
if [ "$PLATFORM" = "Darwin" ]; then
  echo "Next: ./scripts/make-app-bundle.sh   (copies the dylib into Contents/Frameworks)"
fi
