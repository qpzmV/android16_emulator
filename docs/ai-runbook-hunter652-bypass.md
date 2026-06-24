# AI 操作手册：Hunter 6.52 Bypass 完整流程

> **目标读者**：AI 大模型（Claude Code 等）。本手册让 AI 能独立完成从"修改 AOSP 源码"到"验证 Hunter 6.52 绕过"的完整闭环，无需人工干预（编译步骤除外）。
>
> **任务背景**：在自编译 AOSP 模拟器（伪装 Xiaomi 13 fuxi）中，通过修改 AOSP 源码绕过 Hunter 6.52（`com.zhenxi.hunter`）的检测，最终目标是让 Hunter UI 显示绿色笑脸（全部检测项通过）。

---

## 一、环境速查

### 关键路径

| 项目 | 路径 |
|------|------|
| 项目根目录 | `/Users/robin/aosp_xiaomi_xhs_by_pass/android16_emulator/` |
| ADB | `/opt/homebrew/share/android-commandlinetools/platform-tools/adb` |
| Hunter APK | `/Users/robin/Downloads/hunter_392471.apk` |
| 部署脚本 | `scripts/run-aosp-fuxi-pkg-selfbuilt-ui.sh` |
| 模拟器日志 | `/tmp/AOSP_fuxi_pkg.log` |
| **AOSP 源码（Mac 侧共享）** | `~/OrbStack/aosp-builder/home/robin/aosp/aosp/` |
| **AOSP 源码（VM 内）** | `/home/robin/aosp/aosp/` |
| 编译 VM | OrbStack VM `aosp-builder`，进入命令：`orb -m aosp-builder <cmd>` |
| 编译脚本 | VM 内：`/home/robin/aosp/aosp/build_xiaomi.sh` |
| Hunter 检测报告（设备）| `/sdcard/Download/hunter_device_info_6.52_*.txt` |
| Hunter 反编译源码 | `hunter_decompiled/sources/` (6737 个 .java 文件) |

### 别名（本手册后续使用）
```bash
ADB=/opt/homebrew/share/android-commandlinetools/platform-tools/adb
AOSP_MAC=~/OrbStack/aosp-builder/home/robin/aosp/aosp   # Mac 侧直接修改源码
AOSP_VM=/home/robin/aosp/aosp                            # VM 内路径（用于 orb 命令）
PROJECT=/Users/robin/aosp_xiaomi_xhs_by_pass/android16_emulator
HUNTER_APK=/Users/robin/Downloads/hunter_392471.apk
```

---

## 二、AOSP 源码修改

> **⚠️ 规则**：
> - AI 只修改源码文件，**不触发编译**（编译由用户手动执行）
> - **禁止 `rm -rf`** 任何形式的删除目录
> - 通过 Mac 侧共享路径 `~/OrbStack/aosp-builder/home/robin/aosp/aosp/` 直接修改，VM 内同步可见

### 当前已有的关键修改（Round 5，已验证通过）

#### 1. `art/runtime/hidden_api.cc` — 阻止 Hidden API Exemptions

**位置**：`ShouldDenyAccessToMemberImpl` 函数，约第 670 行附近

**作用**：删除了对 `setHiddenApiExemptions` 的显式放行块。Hunter 通过反射调用这个方法来探测 Magisk；删除后该调用被 blocked，"Hidden API has been enabled" 告警消失。

**当前状态**（已修改，保持不变）：
```cpp
// Check for an exemption first. Exempted APIs are treated as SDK.
if (member_signature.DoesPrefixMatchAny(runtime->GetHiddenApiExemptions())) {
```
（5 行显式 allow 块已删除）

#### 2. `art/runtime/runtime.h` — 锁定 Exemptions 列表

**作用**：新增 `LockHiddenApiExemptions()` 和 `hidden_api_exemptions_locked_` 字段，防止 exemptions 被修改。

**关键代码**（约第 690 行）：
```cpp
// XHS bypass: silently ignore exemption updates when locked.
void SetHiddenApiExemptions(const std::vector<std::string>& exemptions) {
  if (!hidden_api_exemptions_locked_) {
    hidden_api_exemptions_ = exemptions;
  }
}

void LockHiddenApiExemptions() {
  hidden_api_exemptions_locked_ = true;
  hidden_api_exemptions_.clear();
}
```

#### 3. `art/runtime/native/dalvik_system_ZygoteHooks.cc` — Fork 后锁定

**作用**：app 进程 fork 后立即调用 `LockHiddenApiExemptions()`，作为双重保险。

**关键代码**（约第 419 行）：
```cpp
// XHS bypass: defense-in-depth — lock exemptions list after fork.
if (api_enforcement_policy == hiddenapi::EnforcementPolicy::kEnabled) {
  runtime->LockHiddenApiExemptions();
}
```

#### 4. `bionic/libc/bionic/open.cpp` — 拦截关键路径

**作用**：
- `/proc/self/maps`：流式过滤，去掉模拟器特征 so 名（`_stream.so`, `OpenglCodecCommon` 等）
- `/proc/version`：返回伪造的 Xiaomi 内核版本字符串
- `/proc/net/route`：返回伪造的路由表
- `/dev/goldfish*`, `/sys/module/goldfish*`, `/sys/class/drm/card0/device/*`：返回 ENOENT

**⚠️ 关键实现细节**：
- `/proc/self/maps` 必须流式读取（maps 文件 315KB，base.apk 在第 434 行）
- pipe buffer 必须扩到 1MB：`fcntl(pfd[1], F_SETPIPE_SZ, 1024 * 1024)`（否则写 300KB 会阻塞 = ANR）
- static 缓冲区用 `pthread_mutex` 保护并发访问

#### 5. `bionic/libc/SYSCALLS.TXT` + `bionic/libc/bionic/stat.cpp` — fstat/fstatat wrapper

**作用**：添加 NQE trace 支持，调试用。lp64 的 `fstat`/`fstatat` 改名为 `__fstat`/`__fstatat` 内部符号，stat.cpp 提供带 trace 的 C wrapper。

**⚠️ 注意**：`nqe_trace_fd_s()` 里用 `__openat` 而不是 `open()`，避免递归进入自己的拦截逻辑。

#### 6. `frameworks/base/services/accessibility/java/com/android/server/accessibility/AccessibilityManagerService.java` — 返回假无障碍服务

**作用**：当 uid ≥ 10000 的 app 查询无障碍服务列表时，返回伪造的 MIUI 无障碍服务，而非真实的模拟器服务列表。通过 `persist.xhs.bypass.a11y` 属性配置返回的服务名。

---

## 三、编译流程

> **注意**：AI 不执行编译，只负责确认编译产物状态。下面是告知用户的编译命令。

### 用户需要执行的命令

```bash
# 进入 VM 执行编译
orb -m aosp-builder bash -c "cd /home/robin/aosp/aosp && ./build_xiaomi.sh"
```

### 编译耗时估计

| 改动范围 | 预计时长 |
|----------|---------|
| 只改 `art/runtime/` | 10–20 分钟 |
| 改 `bionic/libc/bionic/` | 5–10 分钟 |
| 改 `frameworks/base/` | 5–15 分钟 |
| 首次完整编译 | 2–4 小时 |

### 确认编译成功

```bash
# 检查编译产物是否更新（时间戳）
ls -la ~/OrbStack/aosp-builder/home/robin/aosp/aosp/out/target/product/fuxi/sdk-repo-linux-system-images.zip
```

---

## 四、部署：启动模拟器

编译完成后，在 Mac 主机执行（**不需要进入 VM**）：

```bash
cd /Users/robin/aosp_xiaomi_xhs_by_pass/android16_emulator

# 标准部署（清除数据，确保干净状态）
WIPE_DATA=1 bash scripts/run-aosp-fuxi-pkg-selfbuilt-ui.sh
```

脚本自动完成：
1. 从 OrbStack 共享目录复制 `sdk-repo-linux-system-images.zip`
2. 解压系统镜像到 AVD
3. 配置 AVD（伪装 Xiaomi 13 fuxi，1080×2400，440dpi）
4. 启动模拟器，等待 boot 完成

### 等待模拟器就绪

```bash
ADB=/opt/homebrew/share/android-commandlinetools/platform-tools/adb

# 等待 boot 完成（最长 120 秒）
until $ADB shell getprop sys.boot_completed 2>/dev/null | grep -q 1; do
  echo "等待启动..."
  sleep 3
done
echo "模拟器已就绪"
```

### 常用环境变量

```bash
WIPE_DATA=0    # 保留用户数据（如已安装的 APK），跨版本测试时建议 WIPE_DATA=1
NO_WINDOW=1    # headless 模式（无 GUI 窗口）
MEMORY_MB=8192 # 自定义内存（默认 4096）
CORES=8        # CPU 核数
```

---

## 五、测试前配置（必须每次部署后执行）

### 5.1 获取 root 并关闭 SELinux

```bash
ADB=/opt/homebrew/share/android-commandlinetools/platform-tools/adb

$ADB root
sleep 2
$ADB shell setenforce 0    # 关闭 SELinux 强制模式（permissive）
$ADB shell getenforce      # 验证：应输出 Permissive
```

> **为什么**：NQE trace 文件写入 `/data/local/tmp/`，SELinux 默认会阻止 untrusted_app 写 shell_data_file 标签的目录。permissive 模式下允许写入（仅记录 audit）。

### 5.2 创建 NQE trace 文件（可选，调试用）

只在需要抓 fstat/open trace 时执行：

```bash
ADB=/opt/homebrew/share/android-commandlinetools/platform-tools/adb

# 创建 trace 文件（需要 root 权限）
$ADB shell touch /data/local/tmp/nqe_open.txt
$ADB shell touch /data/local/tmp/nqe_trace.txt
$ADB shell chmod 666 /data/local/tmp/nqe_open.txt
$ADB shell chmod 666 /data/local/tmp/nqe_trace.txt

# 开启 trace（设置后立即生效，Hunter 启动后开始记录）
$ADB shell setprop debug.nqe.trace 1

# 关闭 trace（正常测试时保持关闭，避免 open() 递归问题）
$ADB shell setprop debug.nqe.trace 0
```

> **⚠️ 警告**：开启 `debug.nqe.trace=1` 时，`fstat`/`fstatat` 的 trace 逻辑会调用 `nqe_trace_fd_s()`，如果此函数使用了我们自己拦截的 `open()` 而非 `__openat`，会触发递归崩溃（已在 Round 5 修复）。正常绕过测试时保持 `debug.nqe.trace=0`。

---

## 六、Hunter 安装与测试

### 6.1 安装 Hunter APK

```bash
ADB=/opt/homebrew/share/android-commandlinetools/platform-tools/adb
HUNTER_APK=/Users/robin/Downloads/hunter_392471.apk

# push 到设备（大文件用 push + pm install，避免超时）
$ADB push "$HUNTER_APK" /data/local/tmp/h.apk
$ADB shell pm install -r /data/local/tmp/h.apk
# 输出 "Success" 则安装成功
```

### 6.2 清除数据并授权

```bash
ADB=/opt/homebrew/share/android-commandlinetools/platform-tools/adb

# 清除历史数据（重要！避免上次检测结果缓存影响）
$ADB shell pm clear com.zhenxi.hunter

# 授予存储权限（Hunter 需要此权限保存检测报告）
$ADB shell pm grant com.zhenxi.hunter android.permission.WRITE_EXTERNAL_STORAGE
$ADB shell pm grant com.zhenxi.hunter android.permission.READ_EXTERNAL_STORAGE
```

### 6.3 启动 Hunter 并等待三进程就绪

```bash
ADB=/opt/homebrew/share/android-commandlinetools/platform-tools/adb

# 启动 MainActivity
$ADB shell am start -n com.zhenxi.hunter/.MainActivity

# 等待三进程全部启动（约 10–30 秒）
echo "等待 Hunter 三进程启动..."
for i in $(seq 1 30); do
  PROCS=$($ADB shell ps -ef 2>/dev/null | grep "com.zhenxi.hunter" | grep -v grep | wc -l)
  if [ "$PROCS" -ge 3 ]; then
    echo "✓ 三进程已就绪（共 $PROCS 个进程）"
    break
  fi
  echo "  当前 $PROCS 个进程，等待中... ($i/30)"
  sleep 2
done

# 确认三进程名称
$ADB shell ps -ef | grep "com.zhenxi.hunter" | grep -v grep
# 期望看到：
#   com.zhenxi.hunter:hunter_main_process
#   com.zhenxi.hunter:hunter_server_iso:com.zhenxi.hunter.ZhenxiServer:hunter_iso_service
#   com.zhenxi.hunter:hunter_server_twin
```

> **三进程说明**：
> - `hunter_main_process`：主检测进程，负责 Java 层检测和 UI
> - `hunter_server_iso`：隔离进程，负责 APK 签名/inode 校验（关键！）
> - `hunter_server_twin`：Twin 进程，与主进程交叉验证 IPC 心跳

### 6.4 触发 Hunter 检测并保存报告

Hunter 启动后会自动运行检测。检测完成后需要手动触发保存（点击 UI 按钮或等待自动保存）。

**方法一：等待自动生成（推荐，约 30–60 秒）**
```bash
ADB=/opt/homebrew/share/android-commandlinetools/platform-tools/adb

# 等待报告文件出现
for i in $(seq 1 30); do
  FILE=$($ADB shell ls /sdcard/Download/ 2>/dev/null | grep hunter_device_info | tail -1 | tr -d '\r')
  if [ -n "$FILE" ]; then
    echo "✓ 报告已生成：$FILE"
    break
  fi
  echo "  等待报告... ($i/30)"
  sleep 3
done
```

**方法二：网格点击触发 UI 操作**（如果自动保存未触发）
```bash
ADB=/opt/homebrew/share/android-commandlinetools/platform-tools/adb

sleep 15  # 先等 Hunter 完成检测
# 屏幕网格扫描（5×7 = 35 个坐标点，覆盖全屏可能的按钮）
for X in 200 400 540 700 900; do
  for Y in 200 500 800 1100 1400 1700 2000; do
    $ADB shell input tap $X $Y
    sleep 0.5
  done
done
sleep 3
```

### 6.5 拉取检测报告

```bash
ADB=/opt/homebrew/share/android-commandlinetools/platform-tools/adb
PROJECT=/Users/robin/aosp_xiaomi_xhs_by_pass/android16_emulator

# 查找最新报告
LATEST=$($ADB shell ls /sdcard/Download/ 2>/dev/null | grep hunter_device_info | sort | tail -1 | tr -d '\r')
echo "最新报告：$LATEST"

# 拉取到本地（加时间戳）
$ADB pull "/sdcard/Download/$LATEST" "$PROJECT/$LATEST"
echo "已保存到：$PROJECT/$LATEST"
```

---

## 七、结果分析

### 7.1 快速判断：查看 UI 状态

- **绿色笑脸** = 全部检测通过，bypass 成功
- **红色/哭脸** = 有检测项失败，查看报告定位问题

### 7.2 解读检测报告

报告格式：

```
{title=Hunter Main Thread Event(28)
 risk=[..., 检测项(时间偏移ms), ...]
检测项(时间偏移ms)
...
}

{title=Hunter ISO Service Event(34)
 risk=[..., native apk check inode&uid&gid success(8), ...]
...
}
```

**关键检测项说明**：

| 检测项 | 含义 | 期望状态 |
|--------|------|----------|
| `check hide api (N)` | Hidden API 检测（N 是时间偏移毫秒）| 出现即正常（不是错误） |
| `Android 9.0 Hidden API has been enabled` | Hunter 成功调用了 exemptions，判定 Magisk 存在 | **不应出现** |
| `native apk check inode&uid&gid success` | APK inode 与 maps 文件中的 inode 一致 | **应出现** |
| `check apk sign inode fail` | APK inode 不匹配 | **不应出现** |
| `anti accessibility server (N)` | 无障碍服务检测（N 是时间偏移） | 出现但不影响结果 |
| `iso ipc thread heartbeat_request` | ISO 进程 IPC 心跳 | 应正常出现 |
| `twin ipc thread heartbeat_request` | Twin 进程 IPC 心跳 | 应正常出现 |

### 7.3 成功标志（对比修改前后）

| 状态 | 修改前 | 修改后（Round 5） |
|------|--------|------------------|
| Hidden API | `Android 9.0 Hidden API has been enabled`（三进程各一次） | 不出现 |
| APK inode | `check apk sign inode fail` | `native apk check inode&uid&gid success` |
| UI | 红色/告警 | **绿色笑脸** |

---

## 八、NQE Trace 调试（排查 fstat/open 问题时使用）

### 开启 trace

```bash
ADB=/opt/homebrew/share/android-commandlinetools/platform-tools/adb

$ADB root
$ADB shell setenforce 0
$ADB shell touch /data/local/tmp/nqe_open.txt
$ADB shell touch /data/local/tmp/nqe_trace.txt
$ADB shell chmod 666 /data/local/tmp/nqe_open.txt /data/local/tmp/nqe_trace.txt
$ADB shell setprop debug.nqe.trace 1
```

### 清除旧数据并启动 Hunter

```bash
$ADB shell pm clear com.zhenxi.hunter
$ADB shell > /data/local/tmp/nqe_open.txt   # 清空
$ADB shell > /data/local/tmp/nqe_trace.txt  # 清空
$ADB shell pm grant com.zhenxi.hunter android.permission.WRITE_EXTERNAL_STORAGE
$ADB shell am start -n com.zhenxi.hunter/.MainActivity
sleep 20
```

### 拉取 trace 并分析

```bash
$ADB pull /data/local/tmp/nqe_open.txt  /tmp/nqe_open.txt
$ADB pull /data/local/tmp/nqe_trace.txt /tmp/nqe_trace.txt

# 查找 Hunter 对 base.apk 的 open 记录
grep "base.apk\|hunter.*apk" /tmp/nqe_open.txt | head -20

# 查找 fstat 记录（格式：F|fd|path|inode|result）
grep "base.apk" /tmp/nqe_trace.txt | head -10

# 查找 maps 里的 inode（如果 maps 过滤正常，base.apk 的 inode 应该能找到）
# Hunter 会对比 fstat inode 和 maps inode，两者必须一致
```

### Trace 格式说明

```
# nqe_open.txt：open() 调用记录
O|路径|返回fd

# nqe_trace.txt：fstat/fstatat/stat 记录
F|fd|路径|inode|result         # fstat
T|dirfd|路径|flags|inode|result # fstatat
S|路径|inode|result            # stat
```

---

## 九、logcat 分析

### 9.1 查看 Hunter 关键日志

```bash
ADB=/opt/homebrew/share/android-commandlinetools/platform-tools/adb

# 查看 Hidden API 拦截日志（确认我们的修改生效）
$ADB logcat -d 2>/dev/null | grep -E "hiddenapi.*hunter|hunter.*hiddenapi|setHiddenApiExemptions"

# 查看 Hunter 崩溃信息
$ADB logcat -d 2>/dev/null | grep -E "AndroidRuntime.*hunter|FATAL.*hunter" | head -30

# 查看 Hunter 进程启动日志
$ADB logcat -d 2>/dev/null | grep -E "nativeloader.*hunter|hunter.*nativeloader" | head -20

# 查看 inode 相关日志
$ADB logcat -d 2>/dev/null | grep -E "inode|apk sign" | head -20
```

### 9.2 确认 hidden_api.cc 修改生效

修改生效后，Hunter 调用 `setHiddenApiExemptions` 时应看到：
```
E er_main_process: hiddenapi: Accessing hidden method Ldalvik/system/VMRuntime;->setHiddenApiExemptions([Ljava/lang/String;)V ... api=blocked,core-platform-api ... denied
```

### 9.3 检查崩溃原因

```bash
# 查看 tombstone（native 崩溃）
$ADB shell ls /data/tombstones/
$ADB shell cat /data/tombstones/tombstone_00 | head -60

# 查看完整 AndroidRuntime 崩溃堆栈
$ADB logcat -d 2>/dev/null | grep -A 30 "FATAL EXCEPTION.*hunter" | head -60
```

---

## 十、常见问题处理

### 问题 1：Hunter 启动后 ANR（无响应）

**症状**：Hunter 进程启动后挂起，logcat 显示 "failed to complete startup"

**根因**：`/proc/self/maps` 拦截中 pipe write 阻塞。写 300KB+ 数据到默认 64KB pipe buffer 会导致无限阻塞。

**修复**：确认 `open.cpp` 里有 `fcntl(pfd[1], F_SETPIPE_SZ, 1024 * 1024)` 在 write 循环之前。

### 问题 2：Hunter 主进程崩溃（Firebase 线程 ENOTSOCK）

**症状**：
```
E AndroidRuntime: FATAL EXCEPTION: Firebase Background Thread #3
E AndroidRuntime: java.io.IOException: Socket operation on non-socket
    at java.io.UnixFileSystem.canonicalize0(Native Method)
    at YouAreLoser.Aj.invoke(Unknown Source:19)
```

**根因**：`debug.nqe.trace=1` 时，`fstat()` wrapper 内调用 `open()` 打开 trace 文件，如果用的是我们拦截的 `open()` 而不是 `__openat`，在某些路径下导致问题。

**修复**：确认 `stat.cpp` 里 `nqe_trace_fd_s()` 使用 `__openat` 而非 `open()`：
```cpp
sFd = __openat(AT_FDCWD, "/data/local/tmp/nqe_trace.txt",
               O_WRONLY|O_CREAT|O_APPEND|O_CLOEXEC, 0666);
```

**临时绕过**：`$ADB shell setprop debug.nqe.trace 0`（关闭 trace，Hunter 正常运行）

### 问题 3：`check apk sign inode fail`

**症状**：报告中出现 `check apk sign inode fail`，UI 告警

**根因**：`/proc/self/maps` 被截断，base.apk 的映射条目（在 maps 文件第 434 行）未被写入 pipe，Hunter native 代码从 maps 里找不到 base.apk 的 inode，与 `fstat(fd)` 结果不匹配。

**修复**：确认 `open.cpp` 里的 maps 拦截是**流式读取**全文件，不是固定大小读取：
```cpp
while ((n = read(rfd, chunk, sizeof(chunk))) > 0) {
  // 逐字符处理，完整过滤所有行
}
```

### 问题 4：`Hidden API has been enabled` 检测

**症状**：报告中出现 `Android 9.0 Hidden API has been enabled`

**根因**：Hunter 通过反射调用 `VMRuntime.setHiddenApiExemptions()` 成功，判定存在 Magisk

**修复**：
1. 确认 `hidden_api.cc` 里没有对 `setHiddenApiExemptions` 的显式 allow 块
2. 确认 `runtime.h` 里有 `LockHiddenApiExemptions()` 实现
3. 确认 `ZygoteHooks.cc` 里 fork 后调用了 `LockHiddenApiExemptions()`

### 问题 5：报告文件找不到

```bash
# 在设备上搜索
$ADB shell find /sdcard -name "hunter_device_info_*" 2>/dev/null

# Hunter 可能保存在 /sdcard/Download/ 而非 /sdcard/ 根目录
$ADB shell ls /sdcard/Download/ | grep hunter
```

### 问题 6：模拟器启动失败

```bash
# 查看模拟器日志
tail -100 /tmp/AOSP_fuxi_pkg.log

# 杀死残留进程
pkill -f "emulator.*AOSP_fuxi_pkg"

# 重新部署（强制 WIPE_DATA）
WIPE_DATA=1 bash scripts/run-aosp-fuxi-pkg-selfbuilt-ui.sh
```

### 问题 7：adb 找不到设备

```bash
ADB=/opt/homebrew/share/android-commandlinetools/platform-tools/adb
$ADB kill-server
$ADB start-server
$ADB devices  # 应该看到 emulator-5554
```

### 问题 8：SELinux 阻止 trace 写入

**症状**：`/data/local/tmp/nqe_*.txt` 文件大小为 0，logcat 有 AVC denied（非 permissive）

**修复**：
```bash
$ADB root
$ADB shell setenforce 0   # 切换到 permissive 模式
$ADB shell getenforce     # 确认输出 Permissive
```

---

## 十一、完整一键测试脚本

```bash
#!/bin/bash
# Hunter 6.52 bypass 完整测试流程（deploy → install → test → report）
# 前置条件：模拟器已启动（run-aosp-fuxi-pkg-selfbuilt-ui.sh 已执行）

set -e
ADB=/opt/homebrew/share/android-commandlinetools/platform-tools/adb
HUNTER_APK=/Users/robin/Downloads/hunter_392471.apk
PROJECT=/Users/robin/aosp_xiaomi_xhs_by_pass/android16_emulator

echo "=== Step 1: 等待模拟器就绪 ==="
until $ADB shell getprop sys.boot_completed 2>/dev/null | grep -q 1; do
  sleep 3
done
echo "✓ 模拟器已就绪"

echo "=== Step 2: root + 关闭 SELinux ==="
$ADB root
sleep 2
$ADB shell setenforce 0
echo "✓ root + permissive"

echo "=== Step 3: 关闭 trace（避免 open 递归问题） ==="
$ADB shell setprop debug.nqe.trace 0

echo "=== Step 4: 安装 Hunter ==="
$ADB push "$HUNTER_APK" /data/local/tmp/h.apk
$ADB shell pm install -r /data/local/tmp/h.apk
echo "✓ Hunter 安装完成"

echo "=== Step 5: 清除数据 + 授权 ==="
$ADB shell pm clear com.zhenxi.hunter
sleep 1
$ADB shell pm grant com.zhenxi.hunter android.permission.WRITE_EXTERNAL_STORAGE
$ADB shell pm grant com.zhenxi.hunter android.permission.READ_EXTERNAL_STORAGE

echo "=== Step 6: 启动 Hunter ==="
$ADB shell am start -n com.zhenxi.hunter/.MainActivity

echo "=== Step 7: 等待三进程就绪 ==="
for i in $(seq 1 40); do
  PROCS=$($ADB shell ps -ef 2>/dev/null | grep "com.zhenxi.hunter" | grep -v grep | wc -l | tr -d ' ')
  if [ "$PROCS" -ge 3 ]; then
    echo "✓ 三进程就绪（$PROCS 个）"
    break
  fi
  [ "$i" -eq 40 ] && { echo "✗ 超时：三进程未全部启动"; exit 1; }
  sleep 2
done

echo "=== Step 8: 等待检测报告生成（最长 60 秒） ==="
for i in $(seq 1 30); do
  FILE=$($ADB shell ls /sdcard/Download/ 2>/dev/null | grep hunter_device_info | tail -1 | tr -d '\r')
  if [ -n "$FILE" ]; then
    echo "✓ 报告：$FILE"
    break
  fi
  sleep 2
done

if [ -z "$FILE" ]; then
  echo "报告未自动生成，尝试网格点击..."
  for X in 200 400 540 700 900; do
    for Y in 500 900 1300 1700; do
      $ADB shell input tap $X $Y; sleep 0.3
    done
  done
  sleep 5
  FILE=$($ADB shell ls /sdcard/Download/ 2>/dev/null | grep hunter_device_info | tail -1 | tr -d '\r')
fi

echo "=== Step 9: 拉取报告 ==="
$ADB pull "/sdcard/Download/$FILE" "$PROJECT/$FILE"

echo ""
echo "=== 检测结果摘要 ==="
grep -E "Hidden API|inode fail|inode.*success|check hide api" "$PROJECT/$FILE" | head -10

echo ""
echo "=== 完成！报告已保存：$PROJECT/$FILE ==="
```

---

## 十二、迭代修改指南

当发现新的检测失败项时，按以下流程处理：

### 确定检测原理

1. 查看报告里失败项的名称
2. 在 Hunter 反编译代码里搜索：
   ```bash
   grep -rn "失败项关键词" hunter_decompiled/sources/
   ```
3. 在 AOSP 源码里找对应拦截点

### 常见检测维度与修改位置

| 检测类型 | 典型修改文件 |
|----------|-------------|
| Hidden API 访问 | `art/runtime/hidden_api.cc`, `art/runtime/runtime.h` |
| APK 签名/inode | `bionic/libc/bionic/open.cpp`（maps 拦截） |
| 文件系统特征 | `bionic/libc/bionic/open.cpp`（路径拦截） |
| 无障碍服务 | `frameworks/base/services/accessibility/java/.../AccessibilityManagerService.java` |
| `/proc/version` 内核版本 | `bionic/libc/bionic/open.cpp`（已伪造） |
| Build 属性 | `device/*/system.prop`, `build.prop` |
| 网络接口 | `bionic/libc/bionic/open.cpp`（/proc/net/route 已伪造） |

### 修改后的编译与验证

```bash
# 1. 修改源码（直接编辑 Mac 侧共享目录下的文件）
# 2. 通知用户编译（AI 不自行执行编译）
# 3. 编译完成后：
WIPE_DATA=1 bash scripts/run-aosp-fuxi-pkg-selfbuilt-ui.sh
# 4. 执行上面的完整测试脚本
# 5. 分析新报告
```

---

## 十三、已知的遗留问题

| 问题 | 状态 | 说明 |
|------|------|------|
| `anti accessibility server` | 仍出现，不影响通过 | Hunter 检测到模拟器输入服务，但当前 UI 仍绿色 |
| `static` 缓冲区并发 | 已修复（Round 5）| 加了 `pthread_mutex` |
| `debug.nqe.trace=1` 时偶发崩溃 | 已修复（Round 5）| 改用 `__openat` |
| Hunter 三进程启动顺序 | 正常 | 三进程通过 IPC 心跳互相验证，顺序有一定随机性 |

---

## 十四、关键经验总结

1. **`/proc/self/maps` 截断是 inode fail 的根本原因**：maps 文件 315KB，base.apk 在第 434 行，只读 8192 字节（72 行）必然找不到。

2. **pipe buffer 必须扩大**：写 300KB+ 数据到默认 64KB pipe → 阻塞 → ANR。`F_SETPIPE_SZ` 是关键。

3. **static 缓冲区不能在 open() 这种高频路径上放不加锁的 mutable state**：多线程并发读 maps 会数据混乱。

4. **不要在 `fstat` wrapper 里调用拦截的 `open()`**：`fstat` → `nqe_trace_fd_s()` → `open()` → （如果 open 内又调用了什么）→ 递归崩溃。应使用 `__openat` 直接调用。

5. **SELinux 必须 permissive**：trace 文件写入到 `shell_data_file` 标签目录，untrusted_app 在 enforcing 模式下被阻止。

6. **三进程都必须启动才算成功**：只有主进程启动但 iso/twin 未启动，IPC 心跳检测会失败。

7. **`pm clear` 是必须的**：Hunter 会缓存上次检测结果，不清除可能读到旧数据。
