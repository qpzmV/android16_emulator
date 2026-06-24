---
name: xhs_bypass_emulator_detector
description: 小红书模拟器检测绕过全套工作流。用于编译自定义 AOSP 镜像、在模拟器中运行、安装小红书 APK、监控日志并迭代修改源码以绕过模拟器检测。当用户提及小红书、XHS、模拟器检测绕过、AOSP 编译、模拟器伪装、emulator detection bypass、或需要让应用无法检测模拟器环境时触发。即使没有明确说"绕过检测"，只要涉及在模拟器中运行小红书也应触发。
---

# XHS Emulator Detection Bypass

让小红书 (com.xingin.xhs) 在自编译 AOSP 模拟器中运行且无法检测出模拟器环境，实现成功登录。

## 核心上下文（始终记住）

### 路径速查表
| 项目 | 路径 |
|---|---|
| 小红书 APK | `/Users/robin/Downloads/com.xingin.xhs_9.1.0.apk` |
| ADB 二进制 | `/opt/homebrew/share/android-commandlinetools/platform-tools/adb` |
| Android SDK Root | `/opt/homebrew/share/android-commandlinetools` |
| Java Home | `/opt/homebrew/opt/openjdk@17` |
| 模拟器二进制 | `/Users/robin/workspace/my_android_emulator/my_emulator/external/qemu/objs/distribution/emulator/emulator` |
| 项目根目录 | `/Users/robin/aosp_xiaomi_xhs_by_pass` |
| 脚本目录 | `{项目根目录}/scripts/` |
| wiki 知识库 | `/Users/robin/.zcode/skills/llm-wiki-agent/` |
| 外部工具仓库 | `{项目根目录}/android16_emulator/droidmind/` (ADB 自动化) |
| 外部工具仓库 | `{项目根目录}/android16_emulator/android-adb-skill/` (ADB 命令层) |
| 外部工具仓库 | `{项目根目录}/android16_emulator/android-reverse-engineering-skill/` (APK 逆向) |

### 虚拟机编译环境
- **进入虚拟机**: `orb -m aosp-builder`
- **源码目录** (VM 内): `/home/robin/aosp/aosp`
- **编译命令** (VM 内): `./home/robin/aosp/aosp/build_xiaomi.sh`
- **编译产物** (VM 内): `out/target/product/fuxi/sdk-repo-linux-system-images.zip`
- **共享目录** (Mac 侧): `~/OrbStack/aosp-builder/home/robin/`
- **目标设备**: fuxi (Xiaomi 13), arm64-v8a

### 模拟器伪装配置
- AVD 名称: `AOSP_fuxi_pkg`
- 伪装设备: Xiaomi 13, 1080x2400, 440dpi
- GPU: host 模式
- 内存: 4096MB, CPU: 4 核
- 禁用的模拟器特性: `VulkanVirtualQueue,VulkanRobustness,VulkanQueueSubmitWithCommands,HostComposition,VirtioGpuNext,VulkanIgnoredHandles,VulkanAstcLdrEmulation`

### 检测器 APK（用于验证反检测效果）
| APK | 包名 | 用途 |
|---|---|---|
| cqnc_472228.apk | com.chunqiunativecheck | Native 检测 |
| hunter_392471.apk | com.zhenxi.hunter | 综合设备信息检测 |
| memorydetector_462280.apk | io.github.huskydg.memorydetector | 内存检测 |
| nativedetector_404052.apk | io.github.huskydg.nativedetector | Native 层检测 |
| nativetest32_445543.apk | io.github.huskydg.nativetest32 | 32位 Native 测试 |
| rjcq_415611.apk | com.rjcq | 软件环境检测 |
| KeyAttestation-v1.8.4.apk | com.keyat | 密钥认证检测 |

---

## 工作流

### 完整迭代闭环

```
编译 AOSP → 拉取镜像 → 启动模拟器 → 安装 APK → 监控日志 → 分析检测点 → 修改源码 → 重新编译
```

每次用户请求时，先了解当前处于哪个阶段，然后执行对应步骤。

### 阶段 1: 修改源码 & 编译 AOSP 镜像

**⚠️ 关键规则：**
- **禁止 Agent 自行编译**：改完代码后，由用户手动执行 `./build_xiaomi.sh` 编译。Agent 只负责修改源码文件，不触发编译。
- **禁止删除目录**：只允许在源码文件中做修改（增删行、替换内容），不允许 `rm -rf` 删除目录或 `mv` 移动目录。

**修改源码**：修改 VM 共享目录下的源码文件：
```
~/OrbStack/aosp-builder/home/robin/aosp/aosp/
```

**编译（由用户执行）**：
```bash
# 在虚拟机中执行编译
orb -m aosp-builder
cd /home/robin/aosp/aosp
./home/robin/aosp/aosp/build_xiaomi.sh
```

编译产物位于 VM 内的 `out/target/product/fuxi/sdk-repo-linux-system-images.zip`。

### 阶段 2: 拉取镜像并启动模拟器

**⚠️ 必须使用 `run-aosp-fuxi-pkg-selfbuilt-ui.sh` 加载镜像。** 该脚本是唯一受支持的镜像部署和模拟器启动方式。

在 Mac 主机执行（无需进入 VM）：

```bash
bash /Users/robin/aosp_xiaomi_xhs_by_pass/android16_emulator/scripts/run-aosp-fuxi-pkg-selfbuilt-ui.sh
```

该脚本自动完成：
1. 从 OrbStack 共享目录复制 zip
2. 解压系统镜像
3. 创建/更新 AVD 配置（伪装为 Xiaomi 13）
4. 启动模拟器并等待 boot 完成

环境变量可覆盖默认值，例如：
```bash
WIPE_DATA=0 NO_WINDOW=1 bash scripts/run-aosp-fuxi-pkg-selfbuilt-ui.sh
```

- `WIPE_DATA=0` — 保留上次数据
- `NO_WINDOW=1` — 无窗口模式（headless）
- `MEMORY_MB=8192` — 自定义内存
- `CORES=8` — 自定义核心数

### 阶段 3: 安装 APK

模拟器启动后，安装检测器和小红书：

```bash
bash /Users/robin/aosp_xiaomi_xhs_by_pass/android16_emulator/scripts/install-detectors.sh
```

选项：
- `--force` — 强制重装所有 APK
- `--force-latest` — 仅当有新版本时重装

脚本安装完成后会自动启动小红书。

如果只需单独安装小红书：
```bash
/opt/homebrew/share/android-commandlinetools/platform-tools/adb install /Users/robin/Downloads/com.xingin.xhs_9.1.0.apk
```

### 阶段 4: 监控日志

```bash
bash /Users/robin/aosp_xiaomi_xhs_by_pass/android16_emulator/scripts/monitor-xhs.sh
```

或指定输出文件：
```bash
bash scripts/monitor-xhs.sh /path/to/output.log
```

监控脚本关注的关键词：
- `com.xingin.xhs` — 小红书进程
- `onNQEResult` — 网络质量评估结果
- `detect` — 检测逻辑
- `NQE` — 网络质量评估
- `safety` — 安全检测
- `token` — 令牌
- `login` — 登录
- `okhttp` — 网络请求
- `wuji` / `wsCoral` — 风控组件
- `ToastWithout` — 提示信息

### 阶段 5: 分析 & 迭代

根据日志分析小红书的检测点。分析策略按优先级排序：

**第一步：解读 Hunter 检测器日志**（最直接的检测点反馈）

从 `hunter_device_info_*.txt` 中提取高扣分项：
1. 查看 `risk=[...]` 数组内的 `(N)` 数字——数字越大扣分越重
2. 关注分数 >10 的项目，这些是关键突破口
3. 关注 `Hidden API has been enabled` 报告——表明检测到 Magisk 特征
4. 如果出现 `HunterCheckApkSignError`，说明 APK 签名校验失败
5. 如果出现 `YouAreLoser` 类标记，说明反调试被触发

**第二步：对照源码定位检测逻辑**

在 AOSP 源码中搜索对应关键路径：
```
# 常见需要修改的源码路径模式
frameworks/base/core/java/android/os/Build.java         # Build 属性
frameworks/base/core/java/android/os/SystemProperties.java  # 系统属性
frameworks/base/services/core/java/com/android/server/   # 系统服务
device/generic/goldfish/                                  # 模拟器 HIDL 定义
system/core/init/property_service.cpp                     # 属性服务
bionic/libc/bionic/                                       # libc 检测
```

**第三步：修改策略**

按检测维度分类修改：
| 检测维度 | 修改方向 | 典型文件 |
|----------|----------|----------|
| Build 属性 | 伪装为 Xiaomi 13 真机属性 | `build.prop`, `Build.java` |
| 文件系统 | 移除 `/sys/`, `/proc/` 下的模拟器痕迹 | kernel, init.rc |
| 硬件特征 | 修改传感器、基带、GPU 信息 | HAL 层, `sensors/` |
| IPC/Binder | 处理 Twin 进程通信异常 | `servicemanager`, `binder` |
| 签名校验 | 绕过 APK inode/签名检查 | 检测器服务端代码 |
| 隐藏 API | 阻止隐藏 API 可访问性检测 | `hiddenapi` 相关 |
| 无障碍服务 | 移除模拟器输入服务特征 | `accessibility` 服务 |

**第四步：日志模式匹配**

根据 XHS 日志关键词定位问题：
1. **日志中出现 "detect" 或 "emulator" 相关输出** → 说明模拟器被检测到，需要进一步修改 AOSP 源码
2. **NQE 相关日志异常** → 可能需要修改网络相关系统属性
3. **token/safety 相关日志异常** → 可能需要修改 SafetyNet 相关实现或 build.prop
4. **hunter 等检测器也报告模拟器特征** → 参照检测器的发现来修补
5. **出现 "wuji" / "wsCoral" 风控日志** → 风控组件可能在服务端做了二次校验，需要排查网络侧行为

**第五步：迭代闭环**

每次修改后回到阶段 1 重新编译：
```
修改源码 → 用户编译 → 拉取镜像 → 启动模拟器 → 安装 APK → 监控日志 → 分析检测点 → 修改源码
```

### 阶段 6: 验证

确认小红书成功运行且未检测到模拟器：
```bash
# 查看当前运行的 Activity
/opt/homebrew/share/android-commandlinetools/platform-tools/adb shell dumpsys activity activities | grep top-activity

# 查看小红书进程
/opt/homebrew/share/android-commandlinetools/platform-tools/adb shell ps -A | grep xingin

# 获取设备信息（验证伪装效果）
/opt/homebrew/share/android-commandlinetools/platform-tools/adb shell getprop ro.product.manufacturer  # 应输出: Xiaomi
/opt/homebrew/share/android-commandlinetools/platform-tools/adb shell getprop ro.product.model       # 应输出: 2106118C 或类似
/opt/homebrew/share/android-commandlinetools/platform-tools/adb shell getprop ro.build.fingerprint
```

---

## ADB 高级调试命令速查

以下命令整合自 droidmind 和 android-adb-skill，优先使用结构化命令，必要时回退到原始 adb。

### 设备信息与诊断

```bash
# 获取完整设备属性（验证伪装效果）
adb shell getprop | grep -E "ro.product|ro.build|ro.boot|ro.hardware|gsm.version|ril."

# 快速设备指纹检查（一条命令检验伪装效果）
adb shell getprop ro.product.manufacturer && \
adb shell getprop ro.product.model && \
adb shell getprop ro.product.name && \
adb shell getprop ro.build.fingerprint

# 获取当前顶层 Activity（确认 XHS 是否成功进入）
adb shell dumpsys activity activities | grep -E "topResumedActivity|mResumedActivity"

# 检查 SELinux 状态（部分检测器关注此项）
adb shell getenforce

# 获取进程列表（查看 XHS 和检测器进程）
adb shell ps -A | grep -E "xingin|zhenxi|hunter"

# 获取电池状态（某些检测器检查模拟器的假电池）
adb shell dumpsys battery
```

### 日志分析

```bash
# 清空 logcat 缓冲区（开始新测试前执行）
adb logcat -c

# 按包名过滤日志（先获取 PID 再精确过滤）
adb shell pidof com.xingin.xhs        # 获取 XHS PID
adb logcat --pid=<PID> -v threadtime  # 精确按 PID 过滤

# 按优先级 + 标签过滤（聚焦关键检测日志）
adb logcat -v threadtime '*:E' 'HunterMain:*' 'zhenxi:*' 'XHSDetect:*'

# 获取 tombstone/crash 日志（Native 层崩溃）
adb shell ls -la /data/tombstones/
adb shell cat /data/tombstones/tombstone_01

# 获取 ANR 日志
adb shell ls -la /data/anr/
adb shell cat /data/anr/anr_*
```

### 设备验证命令组

```bash
# === 完整伪装验证 ===
echo "=== 制造商 ===" && adb shell getprop ro.product.manufacturer
echo "=== 型号 ===" && adb shell getprop ro.product.model
echo "=== 品牌 ===" && adb shell getprop ro.product.brand
echo "=== 设备 ===" && adb shell getprop ro.product.device
echo "=== 主板 ===" && adb shell getprop ro.product.board
echo "=== 硬件 ===" && adb shell getprop ro.hardware
echo "=== Build 指纹 ===" && adb shell getprop ro.build.fingerprint
echo "=== Build 描述 ===" && adb shell getprop ro.build.description
echo "=== SDK 版本 ===" && adb shell getprop ro.build.version.sdk
echo "=== 安全补丁 ===" && adb shell getprop ro.build.version.security_patch
echo "=== Bootloader ===" && adb shell getprop ro.bootloader
echo "=== 基带版本 ===" && adb shell getprop gsm.version.baseband
echo "=== SELinux ===" && adb shell getenforce
echo "=== 内核版本 ===" && adb shell cat /proc/version
echo "=== CPU 信息 ===" && adb shell cat /proc/cpuinfo | head -5
```

### 应用管理

```bash
# 列出已安装包（检查检测器是否安装成功）
adb shell pm list packages | grep -E "zhenxi|chunqiu|husky|rjcq|keyat"

# 获取应用详细信息
adb shell dumpsys package com.zhenxi.hunter

# 清除应用数据（重置检测器状态）
adb shell pm clear com.zhenxi.hunter

# 强制停止应用
adb shell am force-stop com.xingin.xhs

# 查看应用权限
adb shell dumpsys package com.zhenxi.hunter | grep -A 20 "requested permissions"
```

---

## 检测器 APK 逆向分析指南

来自 android-reverse-engineering-skill 的方法论，用于分析检测器和小红书的检测逻辑。

### Phase 0: APK 指纹识别（先分类再动手）

在反编译之前，先判断 APK 类型——Flutter/RN/WebView 应用的反编译方向完全不同：

```bash
bash android16_emulator/android-reverse-engineering-skill/plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/fingerprint.sh <apk_path>
```

指纹脚本输出：框架类型（Native/Flutter/RN/WebView）、HTTP 栈、混淆程度、Native 库列表、第三方 SDK。对于 Hunter 这类 Native 检测器，这一步可以确认它是纯原生 Android 应用，适合用 jadx 反编译。

### Phase 1: 反编译检测器 APK

```bash
# 使用 jadx 反编译（首选引擎）
bash android16_emulator/android-reverse-engineering-skill/plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/decompile.sh \
  --engine jadx --deobf <detector_apk>

# 如果混淆严重，使用双引擎对比
bash android16_emulator/android-reverse-engineering-skill/plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/decompile.sh \
  --engine both --deobf <detector_apk>
```

### Phase 2: 关键检测代码定位

反编译后，在 `sources/` 目录下搜索关键检测逻辑：

```bash
# 搜索模拟器检测相关关键词
grep -rn "emulator\|simulator\|qemu\|goldfish\|ranchu\|vbox\|genymotion" sources/

# 搜索文件系统检测（/sys, /proc 检查）
grep -rn "/sys/\|/proc/\|/dev/" sources/ | grep -v "android/support\|androidx\|google"

# 搜索属性检测（getprop 调用）
grep -rn "getprop\|SystemProperties\|ro.build\|ro.product\|ro.hardware" sources/

# 搜索 Build 类检测
grep -rn "Build\.\|BRAND\|MANUFACTURER\|MODEL\|FINGERPRINT\|HARDWARE" sources/

# 搜索 Native 方法声明（JNI 检测入口）
grep -rn "native\s\+\w\+\|System\.loadLibrary\|System\.load" sources/

# 搜索包名检测（检测 Magisk/SuperSU/Xposed）
grep -rn "magisk\|supersu\|xposed\|de.robv\|top.johnwu" sources/

# 搜索无障碍服务检测
grep -rn "AccessibilityService\|AccessibilityManager\|getEnabledAccessibilityServiceList" sources/
```

### Phase 3: API 端点提取（分析 XHS 网络行为）

XHS 可能通过服务端进行模拟器检测，需要分析其网络请求：

```bash
# 提取所有 API 路径（R8 不混淆字符串，路径会泄露）
bash android16_emulator/android-reverse-engineering-skill/plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/find-api-calls.sh sources/ --paths

# 提取 hardcoded URLs 和 API keys
grep -rn '"https\?://[^"]*"' sources/
grep -rni 'api[_-]\?key\|api[_-]\?secret\|token\|bearer' sources/
grep -rni 'BASE_URL\|API_URL\|SERVER_URL' sources/

# 搜索 Retrofit/OkHttp 接口定义
grep -rn '@GET\|@POST\|@PUT\|@DELETE\|@Headers' sources/
grep -rn 'Interceptor\|addInterceptor\|intercept(' sources/
```

### Phase 4: 调用链追踪

从入口点追踪到检测逻辑：

```bash
# 从 Application 类开始
grep -rn "extends Application\|: Application(" sources/

# 查找静态初始化块（JNI_OnLoad 等）
grep -rn "static\s*{\|JNI_OnLoad\|init\s*(" sources/

# 查找线程创建（Hunter 的多进程检测）
grep -rn "Thread\|Runnable\|Executors\|ThreadPool" sources/
```

### Hunter 特定分析参考

- **进程结构**: Hunter 使用多进程架构 — `hunter_main_process` + `hunter_server_iso` + `hunter_server_twin`
- **IPC 通信**: 通过 Binder IPC 在不同进程间传递检测结果
- **关键检测点**（从日志推测）:
  - `check hide api` — 调用隐藏 API（检测 Magisk）
  - `anti accessibility server` — 检测无障碍服务
  - `check apk sign` — APK 签名校验（包括 inode 检查）
  - `twin ipc thread heartbeat` — Twin 进程心跳检测
  - `get java fingerprint` — Java 层指纹采集
  - `check unidbg` — 检测 unidbg 模拟
  - `check_arch_seccomp` — seccomp 机制检测

---

## 重要注意事项

1. **Agent 禁止自行编译**：改完代码后，由用户手动执行 `./build_xiaomi.sh` 编译。Agent 只负责修改源码，不触发编译流程。
2. **必须使用 run-aosp-fuxi-pkg-selfbuilt-ui.sh 加载镜像**：编译产物必须通过该脚本部署到模拟器，不允许绕过脚本直接操作 AVD 或模拟器。
3. **禁止删除目录**：Agent 修改代码时只允许在源码文件内做修改（增删行、替换内容），不允许 `rm -rf` 删除目录或移动目录。
4. **编译耗时**: Android 完整编译可能需要数小时。优先考虑增量编译 (`make` 而非 `make clean`)。
5. **虚拟机资源**: AOSP 编译需要大量内存和磁盘。确保 OrbStack VM 有足够资源（建议 16GB+ 内存，200GB+ 磁盘）。
6. **镜像产物路径**: VM 中的 `out/target/product/fuxi/sdk-repo-linux-system-images.zip` 是通过 `build_xiaomi.sh` 生成的打包产物。
7. **AVD 数据持久化**: 默认 `WIPE_DATA=1` 每次启动会清除用户数据。调试阶段可用 `WIPE_DATA=0` 保留数据（如登录状态）。
8. **模拟器日志**: 模拟器运行日志位于 `/tmp/AOSP_fuxi_pkg.log`，如启动失败可查看此文件。
9. **知识库**: 项目的完整知识已存储在 `/Users/robin/.zcode/skills/llm-wiki-agent/wiki/` 中，包含 entities（Xiaomi13Fuxi, AOSPBuilderVM, XHSDetectorAPKs, ADBToolchain）和 concepts（EmulatorDetectionBypass, AOSPBuildWorkflow）。可通过 wiki-agent 的 query 功能检索。

---

## 常见问题排查

### 模拟器启动失败
- 检查 `/tmp/AOSP_fuxi_pkg.log`
- 确认模拟器二进制可执行: `ls -la /Users/robin/workspace/my_android_emulator/my_emulator/external/qemu/objs/distribution/emulator/emulator`
- 检查是否有残留的模拟器进程: `pkill -f emulator`

### adb 找不到设备
```bash
/opt/homebrew/share/android-commandlinetools/platform-tools/adb kill-server
/opt/homebrew/share/android-commandlinetools/platform-tools/adb start-server
/opt/homebrew/share/android-commandlinetools/platform-tools/adb devices
```

### APK 安装失败
- 大 APK（>50MB）使用 push + pm install 策略，小 APK 使用 adb install
- 如果 `adb install` 失败，尝试先卸载再安装: `adb uninstall <包名> && adb install <apk>`

### 编译产物拉取失败
- 确认 VM 中编译成功: 检查 `~/OrbStack/aosp-builder/home/robin/aosp/aosp/out/target/product/fuxi/sdk-repo-linux-system-images.zip` 是否存在
- OrbStack 共享目录可能有延迟，等待几秒后重试

---

## 外部知识库与工具参考

本 skill 整合了以下开源仓库的有用知识：

### droidmind — Android 设备 AI 控制框架
- **仓库**: `android16_emulator/droidmind/` (来自 hyperb1iss/droidmind)
- **核心价值**:
  - ADB 命令安全层：命令验证、风险评估、注入检测（`security.py`）
  - 设备诊断：bugreport、heap dump、ANR/crash 日志、电池统计
  - 应用管理：安装/卸载/启停、manifest/权限/组件提取
  - 日志分析：按包名/PID 过滤 logcat，支持多 buffer
- **可复用模式**: 安全命令执行框架、结构化日志检索、设备属性批量采集

### android-adb-skill — 命令驱动 Android 自动化
- **仓库**: `android16_emulator/android-adb-skill/` (来自 amit-nayar/android-adb-skill)
- **核心价值**:
  - 统一命令层 `tools/android` — 设备/截图/UI/输入/等待/滚动/应用/调试
  - AI 开发工作流：edit → build → install → verify 循环
  - UI 自动化：元素查找、点击、滚动、等待（支持 resource-id/text/content-desc）
  - 结构化输出：`--json` 标志提供机器可读结果
  - 文本输入安全转义：处理空格、特殊字符
- **可复用模式**: `tools/android device info`、`tools/android debug logs --package`、`tools/android app current`、`tools/android ui dump`

### android-reverse-engineering-skill — APK 逆向分析
- **仓库**: `android16_emulator/android-reverse-engineering-skill/` (来自 SimoneAvogadro/android-reverse-engineering-skill)
- **核心价值**:
  - Phase 0 指纹识别：框架检测（Flutter/RN/Xamarin/Kotlin）、HTTP 栈检测、混淆度评估
  - jadx + Fernflower/Vineflower 双引擎反编译
  - R8 混淆 Kotlin 类名恢复（`recover-kotlin-names.sh`）
  - API 端点提取：Retrofit/OkHttp/Ktor/Apollo/Volley 全覆盖
  - 调用链追踪：从 Activity → ViewModel → Repository → HTTP 请求
  - 第三方 SDK 识别：AppsFlyer/Datadog/Sentry/Firebase 等
- **可复用模式**: APK 指纹识别、反编译 + grep 定位检测逻辑、API 路径提取

### 工具集成使用示例

```bash
# 1. 对 Hunter 检测器做快速指纹识别
bash android16_emulator/android-reverse-engineering-skill/plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/fingerprint.sh \
  /Users/robin/aosp_xiaomi_xhs_by_pass/android16_emulator/detector_apks/hunter_392471.apk

# 2. 反编译检测器，分析检测逻辑
bash android16_emulator/android-reverse-engineering-skill/plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/decompile.sh \
  --engine jadx --deobf /Users/robin/aosp_xiaomi_xhs_by_pass/android16_emulator/detector_apks/hunter_392471.apk

# 3. 使用 android-adb-skill 工具检查设备状态
cd android16_emulator/android-adb-skill
python3 tools/android device info --json
python3 tools/android debug logs --package com.zhenxi.hunter --level E --lines 200
python3 tools/android screenshot --out /tmp/xhs_screen.png
```

---

## 迭代记录知识

### Hunter 6.52 检测扣分参考（2026-06-21）
上次检测结果显示主要扣分：
- **66分** `twin ipc thread heartbeat` — Twin 进程 IPC 心跳异常（最大扣分项）
- **21分** `start check apk sign 111` — APK 签名 111 阶段校验失败
- **11分** `anti hide api` — 检测到隐藏 API 调用（暗示 Magisk 存在）
- **11分** `anti accessibility server` — 无障碍服务检测（模拟器 input 子系统）
- **7分** `application loadLibrary time` — Native 库加载耗时异常
- **5分** `native apk sign check open fd` — APK 签名文件描述符异常
- **Hidden API enabled** (x2) — ISO 和 Twin 进程都检测到隐藏 API 访问
- **check apk sign inode fail** — APK inode 校验失败
