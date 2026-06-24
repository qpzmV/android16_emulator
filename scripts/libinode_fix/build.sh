#!/bin/bash
# Build libinode_fix.so for aarch64 Android.
# Requires Android NDK — adjust NDK path as needed.
set -euo pipefail

NDK="${NDK_HOME:-$HOME/Library/Android/sdk/ndk/27.0.12077973}"
CLANG="${NDK}/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android33-clang"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "$CLANG" ]; then
    echo "ERROR: aarch64-linux-android33-clang not found at: $CLANG"
    echo "Set NDK_HOME or edit this script."
    exit 1
fi

echo "→ Compiling libinode_fix.so ..."
"$CLANG" -shared -fPIC -O2 -s \
    -o "${SCRIPT_DIR}/libinode_fix.so" \
    "${SCRIPT_DIR}/libinode_fix.c"

echo "✅ Built: ${SCRIPT_DIR}/libinode_fix.so"
file "${SCRIPT_DIR}/libinode_fix.so"
