#!/usr/bin/env bash
set -euo pipefail

ADB_BIN="${ADB_BIN:-/opt/homebrew/share/android-commandlinetools/platform-tools/adb}"

APKS=(
  /Users/robin/Downloads/cqnc_472228.apk
  /Users/robin/Downloads/duckdetector_461034.apk
  /Users/robin/Downloads/hunter_392471.apk
  /Users/robin/Downloads/memorydetector_462280.apk
  /Users/robin/Downloads/nativedetector_404052.apk
  /Users/robin/Downloads/nativetest32_445543.apk
  /Users/robin/Downloads/rjcq_415611.apk
  /Users/robin/Downloads/KeyAttestation-v1.8.4.apk
)

[[ -x "$ADB_BIN" ]] || { echo "adb not found at $ADB_BIN"; exit 1; }

SERIAL="$("$ADB_BIN" devices | awk '/emulator-.*device/{print $1; exit}')"
[[ -n "$SERIAL" ]] || { echo "No emulator device found"; exit 1; }
echo "Device: $SERIAL"

for apk in "${APKS[@]}"; do
  echo "Installing $(basename "$apk")..."
  if [[ ! -f "$apk" ]]; then
    echo "  SKIP: file not found"
    continue
  fi
  "$ADB_BIN" -s "$SERIAL" install "$apk"
done

echo "Launching duckdetector..."
"$ADB_BIN" -s "$SERIAL" shell am start -a android.intent.action.MAIN -n com.studio.duckdetector/android.app.NativeActivity 2>/dev/null || true

echo "Done."
