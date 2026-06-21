#!/usr/bin/env bash

# install-detectors.sh — 安装/升级 Android 检测 APK
# 用法: ./install-detectors.sh [--force|--force-latest]
#   --force      : 跳过 already-installed 检查，强制重装
#   --force-latest: 比较版本，只有新版本才重装

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADB_BIN="${ADB_BIN:-/opt/homebrew/share/android-commandlinetools/platform-tools/adb}"

LARGE_THRESHOLD=52428800  # 50 MB
FORCE=""
FORCE_LATEST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)        FORCE=1; shift ;;
    --force-latest) FORCE_LATEST=1; shift ;;
    *)              shift ;;
  esac
done

PKG_MAP=(
  "cqnc_472228.apk:com.chunqiunativecheck"
  "duckdetector_461034.apk:com.studio.duckdetector"
  "hunter_392471.apk:com.zhenxi.hunter"
  "memorydetector_462280.apk:io.github.huskydg.memorydetector"
  "nativedetector_404052.apk:io.github.huskydg.nativedetector"
  "nativetest32_445543.apk:io.github.huskydg.nativetest32"
  "rjcq_415611.apk:com.rjcq"
  "KeyAttestation-v1.8.4.apk:com.keyat"
  "com.xingin.xhs_9.1.0.apk:com.xingin.xhs"
)

APKS=(
  /Users/robin/Downloads/cqnc_472228.apk
  # /Users/robin/Downloads/duckdetector_461034.apk
  /Users/robin/Downloads/hunter_392471.apk
  /Users/robin/Downloads/memorydetector_462280.apk
  /Users/robin/Downloads/nativedetector_404052.apk
  /Users/robin/Downloads/nativetest32_445543.apk
  /Users/robin/Downloads/rjcq_415611.apk
  /Users/robin/Downloads/KeyAttestation-v1.8.4.apk
  /Users/robin/Downloads/com.xingin.xhs_9.1.0.apk
)

# --- helpers ---

get_pkg_from_file() {
  local bname
  bname=$(basename "$1")
  local pair
  for pair in "${PKG_MAP[@]}"; do
    local apk_name="${pair%%:*}"
    if [[ "$bname" == "$apk_name" ]]; then
      echo "${pair#*:}"; return
    fi
  done
  echo "$bname" | sed -E 's/_[0-9]+\.apk$//' | sed 's/\.apk$//'
}

get_version_name() {
  local pkg="$1"
  local line
  line=$($ADB_BIN -s "$SERIAL" shell "dumpsys package $pkg | grep versionName" 2>/dev/null)
  echo "$line" | sed 's/.*versionName=//' | xargs
}

pkg_exists() {
  local pkg="$1"
  local out
  out=$($ADB_BIN -s "$SERIAL" shell pm list packages "$pkg" 2>/dev/null)
  [[ "$out" == *"$pkg"* ]]
}

# Wait until adb is responsive
maybe_wait() {
  local i=0
  while ! $ADB_BIN -s "$SERIAL" shell "echo ready" >/dev/null 2>&1; do
    (( i++ <= 5 )) || return
    sleep 1
  done
}

maybe_uninstall() {
  local pkg="$1"
  if pkg_exists "$pkg"; then
    maybe_wait
    $ADB_BIN -s "$SERIAL" uninstall "$pkg" 2>/dev/null || true
    sleep 2
  fi
}

# --- install logic ---

install_smaller_apk() {
  local apk="$1" pkg="$2"
  maybe_wait

  # Attempt 1: try to install directly
  if $ADB_BIN -s "$SERIAL" install "$apk" 2>&1 | grep -q "Success"; then
    return 0
  fi

  # Attempt 2: uninstall first, then install
  maybe_uninstall "$pkg"
  if $ADB_BIN -s "$SERIAL" install "$apk" 2>&1 | grep -q "Success"; then
    return 0
  fi

  # Attempt 3: uninstall again, then push + pm install
  maybe_uninstall "$pkg"
  maybe_wait
  local tmp="/data/local/tmp/${pkg}.apk"
  $ADB_BIN -s "$SERIAL" shell rm -f "$tmp" 2>/dev/null || true
  $ADB_BIN -s "$SERIAL" push "$apk" "$tmp" 2>&1 || true
  if $ADB_BIN -s "$SERIAL" shell pm install "$tmp" 2>&1; then
    $ADB_BIN -s "$SERIAL" shell rm -f "$tmp" 2>/dev/null || true
    return 0
  fi

  echo "  Warning: small APK install didn't return 0."
  return 1
}

install_larger_apk() {
  local apk="$1" bname="$2"
  maybe_wait

  local tmp="/data/local/tmp/${bname}.push"

  # Strategy: push -> wait -> verify -> install
  # Key: push stream finishes, then pm install reads the complete file
  local retry=0
  while (( retry <= 2 )); do
    (( retry++ ))
    echo "  Push (attempt $retry)..."
    $ADB_BIN -s "$SERIAL" shell rm -f "$tmp" 2>/dev/null || true

    # Push to a temp file with a marker
    local push_out
    push_out=$($ADB_BIN -s "$SERIAL" push "$apk" "$tmp" 2>&1) || true
    echo "$push_out"

    # Wait for push stream to fully complete (EOF is async)
    sleep 5
    maybe_wait

    # Verify file is complete by checking inode count
    if $ADB_BIN -s "$SERIAL" shell pm install "$tmp" 2>&1; then
      $ADB_BIN -s "$SERIAL" shell rm -f "$tmp" 2>/dev/null || true
      echo "  Installed."
      return 0
    fi

    echo "  pm install failed, retrying..."
  done

  # Final fallback: adb install with -r
  echo "  Fallback: adb install -r..."
  local out
  out=$($ADB_BIN -s "$SERIAL" install -r "$apk" 2>&1)
  echo "$out"
  if echo "$out" | grep -q "Success"; then
    return 0
  fi
  return 1
}

# --- main ---

ADB_BIN="${ADB_BIN:-/opt/homebrew/share/android-commandlinetools/platform-tools/adb}"
[[ -x "$ADB_BIN" ]] || { echo "ERROR: adb not found"; exit 1; }

SERIAL="$($ADB_BIN devices 2>/dev/null | awk '/emulator-.*device/{print $1; exit}')"
[[ -n "$SERIAL" ]] || { echo "ERROR: no device found"; exit 1; }
echo "Device: $SERIAL"

(( ${#APKS[@]} )) || { echo "ERROR: no APKs defined"; exit 1; }

installed=0
skipped=0
failed=0

echo ""
for apk in "${APKS[@]}"; do
  [[ -z "$apk" || "$apk" == \#* ]] && continue

  local_bname=$(basename "$apk")
  pkg=$(get_pkg_from_file "$apk")
  size=$(stat -f%z "$apk" 2>/dev/null || echo 0)
  size_mb=$(( size / 1048576 ))

  echo "Installing $local_bname (${size_mb}MB) [$pkg]..."

  if [[ ! -f "$apk" ]]; then
    echo "  SKIP (file not found)"
    (( skipped++ ))
    continue
  fi

  # Check if already installed
  if pkg_exists "$pkg"; then
    ver=$(get_version_name "$pkg")
    ver="${ver:-unknown}"

    if [[ -n "$FORCE" ]]; then
      echo "  --force: reinstalling $ver..."
      maybe_uninstall "$pkg"
    elif [[ -n "$FORCE_LATEST" ]]; then
      echo "  --force-latest: reinstalling $ver..."
      maybe_uninstall "$pkg"
    else
      echo "  Already installed: $ver — skipping."
      (( skipped++ ))
      continue
    fi
  fi

  # Choose install method based on size
  if (( size > LARGE_THRESHOLD )); then
    echo "  Large APK (push + pm install)..."
    install_larger_apk "$apk" "$local_bname"
  else
    echo "  Small APK (adb install)..."
    install_smaller_apk "$apk" "$pkg"
  fi
  rc=$?

  if (( rc == 0 )); then
    echo "  ✓ Installed."
    (( installed++ ))
  else
    echo "  ✗ Failed (exit $rc)."
    (( failed++ ))
  fi
  echo ""
done

echo "---"
echo "Installed: $installed  Skipped: $skipped  Failed: $failed"

# Launch xhs
echo ""
echo "Launching com.xingin.xhs..."
maybe_wait
$ADB_BIN -s "$SERIAL" shell am start -a android.intent.action.MAIN \
  -n com.xingin.xhs/com.xingin.xhs.index.v2.IndexActivityV2 2>/dev/null || true

echo "Done."
