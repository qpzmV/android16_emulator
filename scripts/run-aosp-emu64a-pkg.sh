#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ORB_MACHINE="${ORB_MACHINE:-aosp-builder}"
VM_ZIP_PATH="${VM_ZIP_PATH:-aosp/aosp/out/target/product/emu64a/sdk-repo-linux-system-images.zip}"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/artifacts/emu64a-avd}"
PKG_DIR="${PKG_DIR:-$WORK_DIR/sysimg-package}"
AVD_NAME="${AVD_NAME:-AOSP_emu64a_pkg}"

EMULATOR_BIN="${EMULATOR_BIN:-/opt/homebrew/share/android-commandlinetools/emulator/emulator}"
ADB_BIN="${ADB_BIN:-/opt/homebrew/share/android-commandlinetools/platform-tools/adb}"
JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"

GPU_MODE="${GPU_MODE:-swiftshader_indirect}"
MEMORY_MB="${MEMORY_MB:-4096}"
CORES="${CORES:-4}"
WIPE_DATA="${WIPE_DATA:-1}"
WAIT_FOR_BOOT="${WAIT_FOR_BOOT:-1}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_file() {
  [[ -e "$1" ]] || die "Missing file: $1"
}

set_config_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  if grep -q "^${key}[[:space:]]*=" "$file"; then
    perl -0pi -e "s#^${key}[[:space:]]*=.*#${key} = ${value}#m" "$file"
  else
    printf '%s = %s\n' "$key" "$value" >> "$file"
  fi
}

[[ -x "$EMULATOR_BIN" ]] || die "Emulator not found at $EMULATOR_BIN"
[[ -x "$ADB_BIN" ]] || die "adb not found at $ADB_BIN"
[[ -x "$JAVA_HOME/bin/java" ]] || die "Java not found at $JAVA_HOME/bin/java"
command -v orb >/dev/null 2>&1 || die "orb not found"

mkdir -p "$WORK_DIR"

echo "Pulling packaged system image from $ORB_MACHINE ..."
(
  cd "$WORK_DIR"
  orb pull -m "$ORB_MACHINE" "$VM_ZIP_PATH" .
)

ZIP_PATH="$WORK_DIR/$(basename "$VM_ZIP_PATH")"
need_file "$ZIP_PATH"

echo "Refreshing packaged system image contents ..."
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"
unzip -q "$ZIP_PATH" -d "$PKG_DIR"

SYSIMG_DIR="$PKG_DIR/arm64-v8a"
need_file "$SYSIMG_DIR/kernel-ranchu"
need_file "$SYSIMG_DIR/ramdisk.img"
need_file "$SYSIMG_DIR/system.img"
need_file "$SYSIMG_DIR/vendor.img"
need_file "$SYSIMG_DIR/build.prop"

# This emulator build may resolve one level above the real abi directory.
# Mirror the key files at the package root so both lookup patterns work.
(
  cd "$PKG_DIR"
  ln -sfn arm64-v8a/kernel-ranchu kernel-ranchu
  ln -sfn arm64-v8a/ramdisk.img ramdisk.img
  ln -sfn arm64-v8a/system.img system.img
  ln -sfn arm64-v8a/vendor.img vendor.img
  ln -sfn arm64-v8a/build.prop build.prop
  ln -sfn arm64-v8a/source.properties source.properties
  ln -sfn arm64-v8a/advancedFeatures.ini advancedFeatures.ini
  ln -sfn arm64-v8a/VerifiedBootParams.textproto VerifiedBootParams.textproto
  ln -sfn arm64-v8a/data data
)

AVD_HOME="$HOME/.android/avd"
BASE_AVD_DIR="$AVD_HOME/test_baklava.avd"
BASE_AVD_INI="$AVD_HOME/test_baklava.ini"
AVD_DIR="$AVD_HOME/${AVD_NAME}.avd"
AVD_INI="$AVD_HOME/${AVD_NAME}.ini"

[[ -d "$BASE_AVD_DIR" ]] || die "Template AVD missing: $BASE_AVD_DIR"
[[ -f "$BASE_AVD_INI" ]] || die "Template AVD ini missing: $BASE_AVD_INI"

if [[ ! -d "$AVD_DIR" ]]; then
  echo "Creating AVD from template ..."
  cp -R "$BASE_AVD_DIR" "$AVD_DIR"
  cp "$BASE_AVD_INI" "$AVD_INI"
fi

perl -0pi -e "s#^path *=.*#path = ${AVD_DIR}#m; s#^path\\.rel *=.*#path.rel = avd/${AVD_NAME}.avd#m" "$AVD_INI"

set_config_value "$AVD_DIR/config.ini" "image.sysdir.1" "${PKG_DIR}/arm64-v8a/"
set_config_value "$AVD_DIR/config.ini" "abi.type" "arm64-v8a"
set_config_value "$AVD_DIR/config.ini" "hw.cpu.arch" "arm64"
set_config_value "$AVD_DIR/config.ini" "tag.id" "default"
set_config_value "$AVD_DIR/config.ini" "tag.display" "Default"
set_config_value "$AVD_DIR/config.ini" "hw.ramSize" "$MEMORY_MB"
set_config_value "$AVD_DIR/config.ini" "vm.heapSize" "576"
set_config_value "$AVD_DIR/config.ini" "disk.dataPartition.size" "6442450944"

EMULATOR_ARGS=(
  "@${AVD_NAME}"
  -no-snapshot
  -gpu "$GPU_MODE"
  -memory "$MEMORY_MB"
  -cores "$CORES"
  -no-metrics
)

if [[ "$WIPE_DATA" == "1" ]]; then
  EMULATOR_ARGS=(-wipe-data "${EMULATOR_ARGS[@]}")
fi

echo "Killing old emulator instances ..."
"$ADB_BIN" devices 2>/dev/null | awk '/^emulator-/{print $1}' | while read -r serial; do
  "$ADB_BIN" -s "$serial" emu kill >/dev/null 2>&1 || true
done
sleep 2

echo "Launching $AVD_NAME ..."
JAVA_HOME="$JAVA_HOME" "$EMULATOR_BIN" "${EMULATOR_ARGS[@]}" >/tmp/${AVD_NAME}.log 2>&1 &
EMU_PID=$!
echo "Emulator PID: $EMU_PID"

if [[ "$WAIT_FOR_BOOT" != "1" ]]; then
  echo "Started without boot wait. Log: /tmp/${AVD_NAME}.log"
  exit 0
fi

echo "Waiting for adb device ..."
for _ in {1..120}; do
  serial="$("$ADB_BIN" devices | awk '/^emulator-.*device$/{print $1; exit}')"
  if [[ -n "${serial:-}" ]]; then
    echo "Device online: $serial"
    break
  fi
  sleep 2
done

serial="${serial:-}"
[[ -n "$serial" ]] || die "Timed out waiting for emulator device. See /tmp/${AVD_NAME}.log"

echo "Waiting for sys.boot_completed=1 ..."
for _ in {1..180}; do
  booted="$("$ADB_BIN" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
  if [[ "$booted" == "1" ]]; then
    echo "Boot completed."
    "$ADB_BIN" -s "$serial" shell getprop ro.product.name | tr -d '\r'
    "$ADB_BIN" -s "$serial" shell getprop ro.build.fingerprint | tr -d '\r'
    echo "Log: /tmp/${AVD_NAME}.log"
    exit 0
  fi
  sleep 2
done

die "Timed out waiting for boot completion. See /tmp/${AVD_NAME}.log"
