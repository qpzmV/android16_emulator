#!/usr/bin/env bash
set -euo pipefail

# 监控模拟器里的小红书 (com.xingin.xhs) 日志
# 用法:
#   bash monitor-xhs.sh          # 当前目录输出日志
#   bash monitor-xhs.sh out.log  # 指定输出文件

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${1:-$SCRIPT_DIR/xhs_monitor.log}"

ADB_BIN="${ADB_BIN:-/opt/homebrew/share/android-commandlinetools/platform-tools/adb}"

[[ -x "$ADB_BIN" ]] || { echo "ERROR: adb not found at $ADB_BIN"; exit 1; }

SERIAL="$($ADB_BIN -e 2>/dev/null devices | awk '/emulator-.*device/{print $1; exit}')"
[[ -n "$SERIAL" ]] || { echo "ERROR: No emulator device found"; exit 1; }

echo "Device: $SERIAL"
echo "Log file: $LOG_FILE"
echo ""

# 清空旧的 buffer
$ADB_BIN -s "$SERIAL" logcat -c

# 定义小红书相关日志的正则
XHS_REGEX="com\.xingin\.xhs|onNQEResult|ToastWithout|wuji|wsCoral|detect|NQE|safety|token|xhs|login|okhttp"
SKIP_REGEX="nativeloader|hiddenapi|JIGUANG|MMKV|filehook|GC freed"

# logcat → grep 过滤 → tee 输出 + 写文件
$ADB_BIN -s "$SERIAL" logcat \
  | grep -E "$XHS_REGEX" \
  | grep -v "$SKIP_REGEX" \
  | tee "$LOG_FILE"
