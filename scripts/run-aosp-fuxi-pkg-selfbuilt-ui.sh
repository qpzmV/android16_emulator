#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ORB_MACHINE="${ORB_MACHINE:-aosp-builder}"
VM_ZIP_PATH="${VM_ZIP_PATH:-aosp/aosp/out/target/product/fuxi/sdk-repo-linux-system-images.zip}"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/artifacts/fuxi-avd}"
PKG_DIR="${PKG_DIR:-$WORK_DIR/sysimg-package}"
AVD_NAME="${AVD_NAME:-AOSP_fuxi_pkg}"

EMULATOR_BIN="${EMULATOR_BIN:-/Users/robin/workspace/my_android_emulator/my_emulator/external/qemu/objs/distribution/emulator/emulator}"
ADB_BIN="${ADB_BIN:-/opt/homebrew/share/android-commandlinetools/platform-tools/adb}"
JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}"

GPU_MODE="${GPU_MODE:-host}"
MEMORY_MB="${MEMORY_MB:-4096}"
CORES="${CORES:-4}"
WIPE_DATA="${WIPE_DATA:-1}"
WAIT_FOR_BOOT="${WAIT_FOR_BOOT:-1}"
NO_WINDOW="${NO_WINDOW:-0}"
EMULATOR_FEATURES="${EMULATOR_FEATURES:--VulkanVirtualQueue,-VulkanRobustness,-VulkanQueueSubmitWithCommands,-HostComposition,-VirtioGpuNext,-VulkanIgnoredHandles,-VulkanAstcLdrEmulation}"

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
[[ -d "$ANDROID_SDK_ROOT/platform-tools" ]] || die "ANDROID_SDK_ROOT is not a valid SDK root: $ANDROID_SDK_ROOT"
command -v orb >/dev/null 2>&1 || die "orb not found"

mkdir -p "$WORK_DIR"

echo "Pulling packaged system image from $ORB_MACHINE ..."
(
  cd "$WORK_DIR"
  # orb pull uses /containers/ro/ path which may be a stale read-only snapshot;
  # the shared folder at ~/OrbStack/<machine>/ has the live data.
  cp "$HOME/OrbStack/$ORB_MACHINE/home/robin/$VM_ZIP_PATH" .
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
need_file "$SYSIMG_DIR/source.properties"

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
AVD_DIR="$AVD_HOME/${AVD_NAME}.avd"
AVD_INI="$AVD_HOME/${AVD_NAME}.ini"
API_LEVEL="$(grep '^AndroidVersion.ApiLevel=' "$SYSIMG_DIR/source.properties" | cut -d= -f2)"
TAG_ID="$(grep '^SystemImage.TagId=' "$SYSIMG_DIR/source.properties" | cut -d= -f2)"
TAG_DISPLAY="$(grep '^SystemImage.TagDisplay=' "$SYSIMG_DIR/source.properties" | cut -d= -f2-)"

[[ -n "$API_LEVEL" ]] || die "Failed to read AndroidVersion.ApiLevel from $SYSIMG_DIR/source.properties"
[[ -n "$TAG_ID" ]] || die "Failed to read SystemImage.TagId from $SYSIMG_DIR/source.properties"
[[ -n "$TAG_DISPLAY" ]] || die "Failed to read SystemImage.TagDisplay from $SYSIMG_DIR/source.properties"

if [[ ! -d "$AVD_DIR" ]]; then
  echo "Creating AVD directory from scratch ..."
  mkdir -p "$AVD_DIR"
fi

cat > "$AVD_INI" <<EOF
avd.ini.encoding = UTF-8
target = android-${API_LEVEL}
path = ${AVD_DIR}
path.rel = avd/${AVD_NAME}.avd
EOF

CONFIG_INI="$AVD_DIR/config.ini"
if [[ ! -f "$CONFIG_INI" ]]; then
  cat > "$CONFIG_INI" <<'EOF'
avd.ini.encoding = UTF-8
hw.cpu.ncore = 4
hw.device.manufacturer = Xiaomi
hw.device.name = Xiaomi 13
hw.gpu.enabled = yes
hw.gpu.mode = host
hw.lcd.density = 440
hw.lcd.height = 2400
hw.lcd.width = 1080
hw.display.cutout = none
hw.useext4 = yes
PlayStore.enabled = no
EOF
fi

set_config_value "$CONFIG_INI" "image.sysdir.1" "${PKG_DIR}/arm64-v8a/"
set_config_value "$CONFIG_INI" "abi.type" "arm64-v8a"
set_config_value "$CONFIG_INI" "hw.cpu.arch" "arm64"
set_config_value "$CONFIG_INI" "hw.cpu.ncore" "$CORES"
set_config_value "$CONFIG_INI" "tag.id" "$TAG_ID"
set_config_value "$CONFIG_INI" "tag.display" "$TAG_DISPLAY"
set_config_value "$CONFIG_INI" "target" "android-${API_LEVEL}"
set_config_value "$CONFIG_INI" "hw.ramSize" "$MEMORY_MB"
set_config_value "$CONFIG_INI" "vm.heapSize" "576"
set_config_value "$CONFIG_INI" "disk.dataPartition.size" "17179869184"
set_config_value "$CONFIG_INI" "hw.display.cutout" "none"

EMULATOR_ARGS=(
  "@${AVD_NAME}"
  -no-snapshot
  -gpu "$GPU_MODE"
  -memory "$MEMORY_MB"
  -cores "$CORES"
  -no-metrics
  -show-kernel
)

if [[ "$WIPE_DATA" == "1" ]]; then
  EMULATOR_ARGS=(-wipe-data "${EMULATOR_ARGS[@]}")
fi

if [[ "$NO_WINDOW" == "1" ]]; then
  EMULATOR_ARGS=(-no-window "${EMULATOR_ARGS[@]}")
fi

echo "Killing old emulator instances ..."
"$ADB_BIN" devices 2>/dev/null | awk '/^emulator-/{print $1}' | while read -r serial; do
  "$ADB_BIN" -s "$serial" emu kill >/dev/null 2>&1 || true
done
sleep 2

echo "Launching $AVD_NAME ..."
JAVA_HOME="$JAVA_HOME" ANDROID_SDK_ROOT="$ANDROID_SDK_ROOT" ANDROID_EMULATOR_FEATURES="$EMULATOR_FEATURES" "$EMULATOR_BIN" "${EMULATOR_ARGS[@]}" >/tmp/${AVD_NAME}.log 2>&1 &
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
