#!/usr/bin/env bash
set -euo pipefail

# Historical script kept for reference.
# This was the earlier direct-image AVD path before switching to emu_img_zip.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ORB_MACHINE="${ORB_MACHINE:-aosp-builder}"
VM_IMAGE_DIR="${VM_IMAGE_DIR:-aosp/aosp/out/target/product/emu64a}"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/artifacts/legacy-emu64a-avd}"
AVD_NAME="${AVD_NAME:-AOSP_emu64a}"

EMULATOR_BIN="${EMULATOR_BIN:-/opt/homebrew/share/android-commandlinetools/emulator/emulator}"
ADB_BIN="${ADB_BIN:-/opt/homebrew/share/android-commandlinetools/platform-tools/adb}"

SYSTEM_IMAGE_PKG="${SYSTEM_IMAGE_PKG:-system-images;android-35;google_apis;arm64-v8a}"
DEVICE_ID="${DEVICE_ID:-pixel_5}"

GPU_MODE="${GPU_MODE:-host}"
MEMORY_MB="${MEMORY_MB:-4096}"
CORES="${CORES:-4}"
START_EMULATOR="${START_EMULATOR:-1}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

find_sdkmanager() {
  local candidates=(
    "${SDKMANAGER_BIN:-}"
    "/opt/homebrew/share/android-commandlinetools/cmdline-tools/latest/bin/sdkmanager"
    "/opt/homebrew/share/android-commandlinetools/bin/sdkmanager"
  )
  local p
  for p in "${candidates[@]}"; do
    [[ -n "$p" && -x "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

find_avdmanager() {
  local candidates=(
    "${AVDMANAGER_BIN:-}"
    "$HOME/Library/Android/sdk/cmdline-tools/latest/bin/avdmanager"
    "/opt/homebrew/share/android-commandlinetools/cmdline-tools/latest/bin/avdmanager"
    "/opt/homebrew/share/android-commandlinetools/bin/avdmanager"
  )
  local p
  for p in "${candidates[@]}"; do
    [[ -n "$p" && -x "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

set_config_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  if grep -q "^${key}=" "$file"; then
    perl -0pi -e "s#^${key}=.*#${key}=${value}#m" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

need_cmd orb
[[ -x "$EMULATOR_BIN" ]] || die "Emulator not found at $EMULATOR_BIN"
[[ -x "$ADB_BIN" ]] || die "adb not found at $ADB_BIN"

SDKMANAGER_BIN="$(find_sdkmanager)" || die "sdkmanager not found"
AVDMANAGER_BIN="$(find_avdmanager)" || die "avdmanager not found"

SYS_DIR="$WORK_DIR/sysdir"
mkdir -p "$SYS_DIR"

(
  cd "$WORK_DIR"
  orb pull -m "$ORB_MACHINE" \
    "$VM_IMAGE_DIR/kernel-ranchu" \
    "$VM_IMAGE_DIR/ramdisk.img" \
    "$VM_IMAGE_DIR/system-qemu.img" \
    "$VM_IMAGE_DIR/vendor-qemu.img" \
    "$VM_IMAGE_DIR/userdata.img" \
    "$VM_IMAGE_DIR/vbmeta.img" \
    .
)

cp "$WORK_DIR/kernel-ranchu" "$SYS_DIR/kernel-ranchu"
cp "$WORK_DIR/ramdisk.img" "$SYS_DIR/ramdisk.img"
cp "$WORK_DIR/userdata.img" "$SYS_DIR/userdata.img"
cp "$WORK_DIR/vbmeta.img" "$SYS_DIR/vbmeta.img"
cp "$WORK_DIR/system-qemu.img" "$SYS_DIR/system.img"
cp "$WORK_DIR/vendor-qemu.img" "$SYS_DIR/vendor.img"

yes | "$SDKMANAGER_BIN" "$SYSTEM_IMAGE_PKG" >/dev/null

AVD_DIR="$HOME/.android/avd/${AVD_NAME}.avd"
if [[ ! -d "$AVD_DIR" ]]; then
  echo no | "$AVDMANAGER_BIN" create avd \
    -n "$AVD_NAME" \
    -k "$SYSTEM_IMAGE_PKG" \
    -d "$DEVICE_ID"
fi

CONFIG_INI="$AVD_DIR/config.ini"
[[ -f "$CONFIG_INI" ]] || die "Missing AVD config: $CONFIG_INI"

set_config_value "$CONFIG_INI" "image.sysdir.1" "$SYS_DIR"
set_config_value "$CONFIG_INI" "abi.type" "arm64-v8a"
set_config_value "$CONFIG_INI" "hw.cpu.arch" "arm64"
set_config_value "$CONFIG_INI" "tag.id" "default"
set_config_value "$CONFIG_INI" "tag.display" "Default"
set_config_value "$CONFIG_INI" "disk.dataPartition.size" "6442450944"
set_config_value "$CONFIG_INI" "vm.heapSize" "576"
set_config_value "$CONFIG_INI" "hw.ramSize" "$MEMORY_MB"

if [[ "$START_EMULATOR" != "1" ]]; then
  exit 0
fi

"$EMULATOR_BIN" \
  "@${AVD_NAME}" \
  -wipe-data \
  -no-snapshot \
  -gpu "$GPU_MODE" \
  -memory "$MEMORY_MB" \
  -cores "$CORES" &

"$ADB_BIN" wait-for-device
until [[ "$("$ADB_BIN" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; do
  sleep 5
done
