# Hunter 6.52 检测绕过会话记录

> 日期: 2026-06-21  
> 目标: 修复 Hunter 6.52 在自编译 AOSP 模拟器上的 4 大检测扣分项  
> 结果: 编译成功、部署成功、隐藏 API 拒绝次数降至 0

---

## 背景

Hunter 6.52 检测器在伪装为 Xiaomi 13 (fuxi) 的自编译 AOSP 模拟器上运行，产生以下主要扣分：

| 扣分 | 检测项 | 说明 |
|------|--------|------|
| 66 | `twin ipc thread heartbeat_request` | Twin IPC 心跳异常 |
| 21 | `start check apk sign 111` | APK 签名 111 阶段校验失败 |
| 11 | `anti hide api` | 隐藏 API 调用检测 (Magisk) |
| 11 | `anti accessibility server` | 无障碍服务检测 |
| 7 | `application loadLibrary time` | Native 库加载耗时 |
| 5 | `native apk sign check open fd` | APK 签名文件描述符 |
| 4 | `get java fingerprint a` | Java 层指纹 |

另有两个进程报告 `Hidden API has been enabled`（暗示 Magisk 存在）和 `check apk sign inode fail`。

---

## 修复方案总览

### 问题 1: Twin IPC 心跳检测 (66分) 🔴

**根因分析**: Twin 进程通过 Binder IPC 与主进程做心跳检测。模拟器中 Binder ioctl 调用速度远快于真机，时序差异被检测。

**修复**: 在 `talkWithDriver()` 的 ioctl 调用后注入 500-2500μs 随机延迟，模拟真机 Binder 驱动行为。

**修改文件**:
- `frameworks/native/libs/binder/IPCThreadState.cpp`
  - 添加 xorshift32 PRNG + `usleep()` 延迟函数
  - 用 `#if defined(__ANDROID__)` 守卫确保仅在设备端编译
  - 由 `persist.xhs.bypass.timing=1` 控制开关

### 问题 2: APK 签名 111 校验 (21分) 🟠

**根因分析**: Hunter ISO 服务打开 base.apk → 获取 fd → `fstat()` 检查 st_ino。模拟器文件系统返回的 inode 不符合真机 ext4 特征。

**修复**: 新建 `fstat.cpp` 拦截 `fstat()` 调用，对 .apk 文件返回伪装 inode=182736 + 设备号 makedev(8,43)。

**修改文件**:
- `bionic/libc/bionic/fstat.cpp` **(新建)**
  - 拦截 `fstat()`，通过 `/proc/self/fd/N` 反查 fd 路径
  - 仅对 `.apk` 后缀文件修改 st_ino 和 st_dev
  - 仅对 app 进程生效 (`getuid() >= 10000`)
  - 由 `persist.xhs.bypass.fstat=1` 控制开关

### 问题 3: 隐藏 API / Magisk 检测 (22分) 🟡

**根因分析**: 构建变体为 `userdebug` → `ro.debuggable=1` → 隐藏 API 策略为 `just-warn` → Hunter 能成功调用隐藏 API 并报告 "Magisk 存在"。

同时 `setHiddenApiExemptions` 被严格策略拒绝，导致 Hunter 初始化崩溃。

**修复 (两阶段)**:
1. Stage 1: 在 `device.mk` 中设置 `ro.build.type=user`、`ro.debuggable=0` → 隐藏 API 策略变为 `enabled`
2. Stage 2: 在 `hidden_api.cc` 的 `ShouldDenyAccessToMemberImpl` 中为 `setHiddenApiExemptions` 添加豁免，允许 Hunter 初始化但保持其他隐藏 API 阻塞

**修改文件**:
- `art/runtime/hidden_api.cc`
  - 在 `kCorePlatformApiExemptions` 列表中添加 `VMRuntime;->setHiddenApiExemptions`
  - 在 `ShouldDenyAccessToMemberImpl` 开头添加直通豁免检查
- `device/xiaomi/fuxi/device.mk`
  - 添加 `persist.xhs.bypass.hiddenapi=1`
  - 已有 `ro.build.type=user` 和 `ro.debuggable=0` 设置

### 问题 4: 无障碍服务检测 (11分) 🟢

**根因分析**: 模拟器注册了真机不存在的无障碍服务，Hunter 通过 `getEnabledAccessibilityServiceList()` 和 `getInstalledAccessibilityServiceList()` 检测。

**修复**: 在两个列表返回方法中，当调用者为 app 进程且 bypass 启用时，返回空列表。

**修改文件**:
- `frameworks/base/services/accessibility/java/com/android/server/accessibility/AccessibilityManagerService.java`
  - `getEnabledAccessibilityServiceList()` — 添加 bypass 检查，返回 `Collections.emptyList()`
  - `getInstalledAccessibilityServiceList()` — 同上
  - 由 `persist.xhs.bypass.a11y=1` 控制开关

---

## 系统属性配置

在 `device/xiaomi/fuxi/device.mk` 中添加：

```makefile
# XHS bypass: enable binder timing normalization (twin heartbeat fix)
PRODUCT_SYSTEM_PROPERTIES += persist.xhs.bypass.timing=1

# XHS bypass: enable fstat inode normalization (apk sign check fix)
PRODUCT_SYSTEM_PROPERTIES += persist.xhs.bypass.fstat=1

# XHS bypass: force strict hidden API enforcement (Magisk detection fix)
PRODUCT_SYSTEM_PROPERTIES += persist.xhs.bypass.hiddenapi=1

# XHS bypass: hide accessibility services (anti accessibility fix)
PRODUCT_SYSTEM_PROPERTIES += persist.xhs.bypass.a11y=1
```

---

## 编译迭代记录

### 第 1 次编译
- **结果**: ❌ 失败
- **错误**: `IPCThreadState.cpp:42: fatal error: 'sys/system_properties.h' file not found`
- **原因**: `sys/system_properties.h` 是 bionic 专有头文件，host (linux_glibc) 编译无法访问
- **修复**: 用 `#if defined(__ANDROID__)` 守卫整个 XHS bypass 代码块

### 第 2 次编译
- **结果**: ❌ 失败
- **错误**: `art/runtime/runtime.cc:1729:14: error: use of undeclared identifier 'PROP_VALUE_MAX'`
- **原因**: ART runtime 编译环境没有 bionic `PROP_VALUE_MAX` 常量
- **修复**: 改用 `android::base::GetBoolProperty()` (ART 已有 `<android-base/properties.h>` include)

### 第 3 次编译
- **结果**: ✅ 成功 (29s 增量)
- **备注**: 所有文件编译通过，生成了 `sdk-repo-linux-system-images.zip`

### 第 4 次编译 (回退 runtime.cc 后)
- **结果**: ✅ 成功 (2m44s)
- **原因**: 回退了 runtime.cc 中的 ART 强制隐藏 API 策略，改用 hidden_api.cc 豁免方案

### 第 5 次编译 (hidden_api.cc 添加豁免)
- **结果**: ✅ 成功 (27s)
- **备注**: 在 `ShouldDenyAccessToMemberImpl` 中添加 `setHiddenApiExemptions` 直通豁免

---

## 完整修改文件清单

| # | 文件 | 操作 | 针对问题 |
|---|------|------|----------|
| 1 | `frameworks/native/libs/binder/IPCThreadState.cpp` | 修改 | Twin 心跳 (66分) |
| 2 | `bionic/libc/bionic/fstat.cpp` | **新建** | APK 签名 inode (21分) |
| 3 | `art/runtime/hidden_api.cc` | 修改 | 隐藏 API (22分) |
| 4 | `frameworks/base/services/accessibility/java/com/android/server/accessibility/AccessibilityManagerService.java` | 修改 | 无障碍服务 (11分) |
| 5 | `device/xiaomi/fuxi/device.mk` | 修改 | 添加 4 个控制属性 |

---

## 测试验证结果

| 验证项 | 状态 | 值 |
|--------|------|-----|
| 编译 | ✅ | 最终 27s 增量成功 |
| 模拟器启动 | ✅ | `sys.boot_completed=1` |
| `ro.build.type` | ✅ | `user` |
| `ro.debuggable` | ✅ | `0` |
| `ro.build.fingerprint` | ✅ | `Xiaomi/fuxi/...user/release-keys` |
| `persist.xhs.bypass.timing` | ✅ | `1` |
| `persist.xhs.bypass.fstat` | ✅ | `1` |
| `persist.xhs.bypass.hiddenapi` | ✅ | `1` |
| `persist.xhs.bypass.a11y` | ✅ | `1` |
| Hunter 进程 | ✅ | main + iso + twin 全部运行 |
| 隐藏 API 拒绝次数 | ✅ | **0** (豁免生效) |

---

## 关键命令

### 编译
```bash
orb -m aosp-builder
cd /home/robin/aosp/aosp
./build_xiaomi.sh
```

### 部署
```bash
pkill -9 -f emulator
bash scripts/run-aosp-fuxi-pkg-selfbuilt-ui.sh
```

### 安装检测器
```bash
export ADB=/opt/homebrew/share/android-commandlinetools/platform-tools/adb
$ADB install -r ~/Downloads/hunter_392471.apk
$ADB shell am start -n com.zhenxi.hunter/.MainActivity
```

### 查看属性
```bash
$ADB shell getprop persist.xhs.bypass.timing
$ADB shell getprop persist.xhs.bypass.fstat
$ADB shell getprop persist.xhs.bypass.hiddenapi
$ADB shell getprop persist.xhs.bypass.a11y
```

### 查看隐藏 API 日志
```bash
$ADB logcat -d | grep "hiddenapi" | grep -v dex2oat
```

---

## 与外部工具库的关联

本会话中用到的外部工具仓库位于 `android16_emulator/`:

- **droidmind** (`hyperb1iss/droidmind`): ADB 安全层和诊断工具参考
- **android-adb-skill** (`amit-nayar/android-adb-skill`): 命令驱动 ADB 自动化
- **android-reverse-engineering-skill** (`SimoneAvogadro/android-reverse-engineering-skill`): APK 逆向分析指南

这些已在 SKILL.md 和 wiki 中记录。
