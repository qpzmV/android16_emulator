#!/usr/bin/env bash
set -euo pipefail

AOSP_DIR="${AOSP_DIR:-/home/robin/aosp/aosp}"
TARGET_PRODUCT="${TARGET_PRODUCT:-sdk_phone64_arm64}"
TARGET_RELEASE="${TARGET_RELEASE:-trunk_staging}"
TARGET_VARIANT="${TARGET_VARIANT:-userdebug}"
JOBS="${JOBS:-16}"
LOG_DIR="${LOG_DIR:-$HOME/aosp-logs}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -d "$AOSP_DIR" ]] || die "AOSP tree not found: $AOSP_DIR"
mkdir -p "$LOG_DIR"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/uname" <<'EOF'
#!/bin/sh
if [ "$#" -eq 0 ]; then
  exec /usr/bin/uname
fi
if [ "$1" = "-m" ]; then
  echo x86_64
  exit 0
fi
if [ "$1" = "-sm" ] || [ "$1" = "-ms" ]; then
  echo "Linux x86_64"
  exit 0
fi
exec /usr/bin/uname "$@"
EOF

chmod +x "$TMP_DIR/uname"

export PATH="$TMP_DIR:$PATH"
export GOROOT="$AOSP_DIR/prebuilts/go/linux-x86"
export BUILD_USERNAME="${BUILD_USERNAME:-robin}"
export BUILD_HOSTNAME="${BUILD_HOSTNAME:-aosp-builder}"

cd "$AOSP_DIR"
source build/envsetup.sh
lunch "${TARGET_PRODUCT}" "${TARGET_RELEASE}" "${TARGET_VARIANT}"

STAMP="$(date +%Y%m%d-%H%M%S)"
BUILD_LOG="$LOG_DIR/${TARGET_PRODUCT}-${TARGET_RELEASE}-${TARGET_VARIANT}-build-${STAMP}.log"
PKG_LOG="$LOG_DIR/${TARGET_PRODUCT}-${TARGET_RELEASE}-${TARGET_VARIANT}-emu-img-zip-${STAMP}.log"

echo "Building target image ..."
m -j"${JOBS}" 2>&1 | tee "$BUILD_LOG"

echo "Packaging emulator system image ..."
m emu_img_zip -j"${JOBS}" 2>&1 | tee "$PKG_LOG"

ZIP_PATH="$AOSP_DIR/out/target/product/emu64a/sdk-repo-linux-system-images.zip"
[[ -f "$ZIP_PATH" ]] || die "Expected package not found: $ZIP_PATH"

echo
echo "Build log: $BUILD_LOG"
echo "Package log: $PKG_LOG"
echo "Package: $ZIP_PATH"
