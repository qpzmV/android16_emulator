#!/usr/bin/env bash

# xhs_login_bypass.sh — 小红书登录风控绕过测试环境初始化
# 功能：adb root/selinux 配置、安装小红书、配置NQE trace、授权、启动

ADB_BIN="${ADB_BIN:-/opt/homebrew/share/android-commandlinetools/platform-tools/adb}"
DOWNLOADS=~/Downloads
#com.xingin.xhs_9.1.0
#XHS_APK="$DOWNLOADS/rednote-9-35-0.apk"
XHS_APK="$DOWNLOADS/com.xingin.xhs_9.1.0.apk"
XHS_PKG="com.xingin.xhs"
LARGE_THRESHOLD=52428800  # 50 MB

# 日志输出目录
LOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/outputs/xhs_login_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"

[[ -x "$ADB_BIN" ]] || { echo "ERROR: adb not found at $ADB_BIN"; exit 1; }

SERIAL="$($ADB_BIN devices 2>/dev/null | awk '/emulator-.*device/{print $1; exit}')"
[[ -n "$SERIAL" ]] || { echo "ERROR: 未找到模拟器设备，请先启动模拟器"; exit 1; }
echo "设备: $SERIAL"

adb_sh() { $ADB_BIN -s "$SERIAL" shell "$@"; }

pkg_exists() { $ADB_BIN -s "$SERIAL" shell pm list packages "$1" 2>/dev/null | grep -q "$1"; }

get_version() { $ADB_BIN -s "$SERIAL" shell "dumpsys package $1 | grep versionName" 2>/dev/null | sed 's/.*versionName=//' | tr -d '\r' | xargs; }

maybe_wait() {
  local i=0
  while ! $ADB_BIN -s "$SERIAL" shell echo ready >/dev/null 2>&1; do
    (( i++ > 15 )) && { echo "ERROR: 设备无响应"; exit 1; }
    sleep 1
  done
}

# ─── 1. adb root + selinux ───

echo ""
echo "[1/4] ADB 配置"
$ADB_BIN -s "$SERIAL" root 2>&1 | tail -1
sleep 3; maybe_wait
# goldfish 设备权限修复（ueventd.ranchu.rc 编译前的临时 patch）
# goldfish_address_space / goldfish_sync 需要 0666 才能让 app 进程使用 GPU 渲染
# 否则 mapper.adreno 崩溃 → System UI 无法启动
echo "  修复 goldfish 设备权限..."
for dev in goldfish_address_space goldfish_sync goldfish_pipe; do
  adb_sh "[ -e /dev/$dev ] && chmod 0666 /dev/$dev" 2>/dev/null || true
done
echo "  goldfish 权限: $(adb_sh 'ls -la /dev/goldfish_* 2>/dev/null | awk "{print \$1, \$9}"' | tr '\r' ' ')"
# SELinux 保持 Enforcing — Hunter SDK 会检测 permissive 状态并标记为"可能被 root"
adb_sh setenforce 1 2>/dev/null || true
echo "  SELinux: $(adb_sh getenforce 2>/dev/null | tr -d '\r')"

# ─── 2. NQE trace 文件 ───

echo ""
echo "[2/4] NQE trace 配置"
for f in nqe_trace.txt nqe_open.txt nqe_read.txt nqe_props.txt nqe_net.txt; do
  adb_sh "touch /data/local/tmp/$f; chmod 666 /data/local/tmp/$f" 2>/dev/null || true
done
adb_sh setprop debug.nqe.trace 1
echo "  trace 文件已就绪，debug.nqe.trace=1（已开启）"

# ─── 3. 安装小红书 ───

echo ""
echo "[3/4] 安装小红书"

if pkg_exists "$XHS_PKG"; then
  ver=$(get_version "$XHS_PKG")
  echo "  已安装 v${ver}，跳过（如需重装请先 adb uninstall $XHS_PKG）"
else
  [[ -f "$XHS_APK" ]] || { echo "ERROR: 找不到 $XHS_APK"; exit 1; }
  size=$(stat -f%z "$XHS_APK" 2>/dev/null || echo 0)
  echo "  安装 v9.1.0 ($(( size / 1048576 ))MB)..."

  if (( size > LARGE_THRESHOLD )); then
    tmp="/data/local/tmp/xhs.apk.push"
    ok=0
    for retry in 1 2 3; do
      echo "  push (attempt $retry)..."
      adb_sh rm -f "$tmp" 2>/dev/null || true
      $ADB_BIN -s "$SERIAL" push "$XHS_APK" "$tmp" 2>&1 || true
      sleep 5; maybe_wait
      adb_sh pm install "$tmp" 2>&1 | grep -q "Success" && { ok=1; break; }
    done
    adb_sh rm -f "$tmp" 2>/dev/null || true
    (( ok )) && echo "  ✓ 安装成功" || { echo "  ✗ 安装失败"; exit 1; }
  else
    $ADB_BIN -s "$SERIAL" install "$XHS_APK" 2>&1 | grep -q "Success" \
      && echo "  ✓ 安装成功" || { echo "  ✗ 安装失败"; exit 1; }
  fi
fi

# 授予权限
echo "  授予运行时权限..."
for perm in \
  android.permission.READ_EXTERNAL_STORAGE \
  android.permission.WRITE_EXTERNAL_STORAGE \
  android.permission.CAMERA \
  android.permission.RECORD_AUDIO \
  android.permission.ACCESS_FINE_LOCATION \
  android.permission.ACCESS_COARSE_LOCATION \
  android.permission.READ_CONTACTS \
  android.permission.READ_PHONE_STATE; do
  adb_sh pm grant "$XHS_PKG" "$perm" 2>/dev/null || true
done
adb_sh dumpsys deviceidle whitelist "+$XHS_PKG" 2>/dev/null || true
echo "  权限授予完成"

# ─── 4. 启动日志抓取 ───
rm -rf $LOG_DIR/*
echo ""
echo "[4/5] 启动后台日志抓取"

# 清空 logcat 缓存
$ADB_BIN -s "$SERIAL" logcat -c 2>/dev/null || true
sleep 1

# 后台持续抓取 logcat（全量 + 过滤 XHS 进程）
$ADB_BIN -s "$SERIAL" logcat -v threadtime > "$LOG_DIR/logcat_full.txt" 2>&1 &
LOGCAT_FULL_PID=$!

$ADB_BIN -s "$SERIAL" logcat -v threadtime --pid="$(adb_sh pidof $XHS_PKG 2>/dev/null | tr -d '\r')" \
  > "$LOG_DIR/logcat_xhs.txt" 2>&1 &
LOGCAT_XHS_PID=$!

echo "  logcat 全量  → $LOG_DIR/logcat_full.txt  (PID $LOGCAT_FULL_PID)"
echo "  logcat XHS   → $LOG_DIR/logcat_xhs.txt   (PID $LOGCAT_XHS_PID)"

# NQE trace 同步脚本（后台轮询，每 5s 拉一次）
(
  while true; do
    sleep 5
    $ADB_BIN -s "$SERIAL" shell cat /data/local/tmp/nqe_open.txt  2>/dev/null > "$LOG_DIR/nqe_open.txt"
    $ADB_BIN -s "$SERIAL" shell cat /data/local/tmp/nqe_trace.txt 2>/dev/null > "$LOG_DIR/nqe_trace.txt"
    $ADB_BIN -s "$SERIAL" shell cat /data/local/tmp/nqe_props.txt 2>/dev/null > "$LOG_DIR/nqe_props.txt"
    $ADB_BIN -s "$SERIAL" shell cat /data/local/tmp/nqe_net.txt   2>/dev/null > "$LOG_DIR/nqe_net.txt"
  done
) &
NQE_PULL_PID=$!
echo "  NQE trace 轮询 → $LOG_DIR/nqe_*.txt  (PID $NQE_PULL_PID)"

# 保存 PID 供后续手动 kill
echo "$LOGCAT_FULL_PID $LOGCAT_XHS_PID $NQE_PULL_PID" > "$LOG_DIR/bg_pids.txt"

# ─── 5. 启动小红书 ───

echo ""
echo "[5/5] 启动小红书"
maybe_wait
$ADB_BIN -s "$SERIAL" shell am start -a android.intent.action.MAIN \
  -n com.xingin.xhs/com.xingin.xhs.index.v2.IndexActivityV2 2>/dev/null \
  || $ADB_BIN -s "$SERIAL" shell monkey -p "$XHS_PKG" -c android.intent.category.LAUNCHER 1 2>/dev/null \
  || true

# 重新抓 XHS PID（进程此时已起来）
sleep 3
XHS_PID=$(adb_sh pidof $XHS_PKG 2>/dev/null | tr -d '\r' | awk '{print $1}')
if [[ -n "$XHS_PID" ]]; then
  kill "$LOGCAT_XHS_PID" 2>/dev/null || true
  $ADB_BIN -s "$SERIAL" logcat -v threadtime --pid="$XHS_PID" \
    > "$LOG_DIR/logcat_xhs.txt" 2>&1 &
  LOGCAT_XHS_PID=$!
  echo "  重绑 XHS logcat (pid=$XHS_PID, PID $LOGCAT_XHS_PID)"
  echo "$LOGCAT_FULL_PID $LOGCAT_XHS_PID $NQE_PULL_PID" > "$LOG_DIR/bg_pids.txt"
fi

echo ""
echo "=== 环境就绪 ==="
echo "  SELinux    : $(adb_sh getenforce 2>/dev/null | tr -d '\r')"
echo "  NQE trace  : $(adb_sh getprop debug.nqe.trace 2>/dev/null | tr -d '\r')"
echo "  XHS 版本   : $(get_version $XHS_PKG)"
echo "  XHS PID    : ${XHS_PID:-未知}"
echo "  日志目录   : $LOG_DIR"
echo ""
echo "  现在可以在模拟器里操作小红书登录。"
echo "  输入验证码前告知 Claude，届时将拉取日志分析。"
echo "  停止抓取: kill \$(cat $LOG_DIR/bg_pids.txt)"
