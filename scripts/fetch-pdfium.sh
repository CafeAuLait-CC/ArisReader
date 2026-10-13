#!/usr/bin/env bash
# Download the prebuilt PDFium dynamic library (bblanchon/pdfium-binaries, MIT) and prepare it for shipping with the app.
#
# Usage: ./scripts/fetch-pdfium.sh [--universal] [--tag <release-tag>]
#
# Artifacts: vendor/pdfium/{lib/libpdfium.dylib, include/, licenses/, VERSION}
#
# Why post-processing is needed (docs/09-dev-setup.md §4):
#   * the prebuilt package's install_name is the relative path "./libpdfium.dylib"; it must become @rpath/...
#     so the library can live in .app/Contents/Frameworks and be found through rpath;
#   * it is adhoc/linker-signed and must be re-signed once inside the .app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TAG="latest"
UNIVERSAL=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --tag) shift; TAG="${1:-latest}" ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
  esac
done

ARCH="$(uname -m)"
if [ "$UNIVERSAL" = "1" ]; then
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

echo "==> Unpacking into $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
tar -xzf "$TMP/$ASSET" -C "$DEST"

LIB="$DEST/lib/libpdfium.dylib"
[ -f "$LIB" ] || { echo "lib/libpdfium.dylib not found in the package" >&2; exit 1; }

echo "==> Fixing install_name and signing"
install_name_tool -id @rpath/libpdfium.dylib "$LIB"
codesign --force --sign - "$LIB"

echo
echo "Done:"
printf '  arch      : %s\n' "$(lipo -archs "$LIB" 2>/dev/null || echo '?')"
printf '  size      : %s\n' "$(du -h "$LIB" | cut -f1)"
printf '  install_id: %s\n' "$(otool -D "$LIB" | tail -1)"
[ -f "$DEST/VERSION" ] && printf '  version   : %s\n' "$(cat "$DEST/VERSION")"
[ -d "$DEST/licenses" ] && printf '  licenses  : %s file(s) (shipped alongside the app)\n' "$(ls "$DEST/licenses" | wc -l | tr -d ' ')"
echo
echo "Next: ./scripts/make-app-bundle.sh   (copies the dylib into Contents/Frameworks)"
