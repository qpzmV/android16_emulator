# Hunter 6.52 逆向分析报告

> 反编译日期: 2026-06-23
> APK: `/Users/robin/Downloads/hunter_392471.apk`
> 工具: jadx 1.5.5（6737 个 Java 文件）
> 输出目录: `hunter_decompiled/sources/`

---

## 一、Hunter 6.52 架构

### 三进程模型

| 进程 | 类 | 用途 |
|------|-----|------|
| `hunter_main_process` | `App.java`, `MainActivity.java` | UI + 主控 + 事件聚合 |
| `hunter_server_iso` | `ZhenxiServerIpc.java` | 隔离 Binder 服务，独立检测 |
| `hunter_server_twin` | `ZhenxiServerTwinIpc.java` | 对偶验证 Binder 服务 |

### 关键原生库

- **`libhunter.so`** (`resources/lib/arm64-v8a/`): 所有核心检测逻辑在 Native 层
- 调试符号显示编译源: `F:/HunterNew/app/src/main/cpp/main.cpp`
- 包含 **80+ JNI native 方法**

### 代码混淆

- 主检测逻辑封装在 `YouAreLoser/` 包下
- 大量使用控制流平坦化（JADX 无法完整反编译若干方法）
- 字符串全部用 `byte[]{97,110,116,...}` 数组混淆

---

## 二、检测机制详解

### 2.1 APK 签名 / 文件系统检测（270 分）

#### Java 层

**主类**: `YouAreLoser/AbstractC0136C9.java` (method `m480a()`)

```java
// 包名校验
context.getPackageName() ?= "com.zhenxi.hunter"

// 系统签名采集
context.getPackageManager().getPackageInfo("android", 64).signatures

// ApplicationInfo className 校验
context.getApplicationInfo().className ?= "com.zhenxi.hunter.App"

// PackageManager API 完整性探测
getPackageInfo(packageName, 0)
getApplicationInfo(packageName, 0)
getPackageGids(packageName, 0)
getApplicationLogo(packageName)
getInstallSourceInfo(packageName)        // API >= 30
getLaunchIntentForPackage(packageName)
getTargetSdkVersion(packageName)         // API >= 31
getInstallerPackageName(packageName)
checkPermission("android.permission.INTERNET", packageName)

// Assets 文件枚举（检测 .so 和 .apk 残留）
context.getAssets().list("")

// APK 指纹获取
getPackageInfo(packageName, 64).signatures  // flag 64 = GET_SIGNATURES
```

#### Native 层（libhunter.so）— **最关键**

完整的 APK 验证流水线（从调试字符串还原）：

```
Step 1: getApkPath                    → 获取 base.apk 路径
Step 2: start native open base.apk success → 打开 APK 文件
Step 3: native apk sign check open fd → 获取文件描述符
Step 4: native apk check fd path success → readlink /proc/self/fd/N
Step 5: ⚠️ fstat64(fd, &stat)        → 检查 uid/gid
Step 6: ⚠️ __NR_fstat 原始系统调用     → 绕过 libc，再次检查！
Step 7: ⚠️ 读取 /proc/self/map_files  → 获取映射 inode
Step 8: ⚠️ 对比 fd inode vs map inode  → APK 替换检测
Step 9: APK 证书提取（base64 + hex）   → 签名指纹验证
Step 10: tee check apk sign start      → TEE 环境验证
```

#### ⚠️ 为何现有 fstat.cpp bypass 无效

| Hunter 做了什么 | 我们的拦截 | 结果 |
|:---|:---|:---|
| 调 `fstat64()` (libc wrapper) | `fstat.cpp` 拦截了 ✅ | 被伪造 |
| 调 `syscall(__NR_fstat, fd, &stat)` (原生) | **未拦截** ❌ | **真实值泄露** |
| 读 `/proc/self/map_files/` 获取 inode | **未处理** ❌ | **map inode 真实** |
| 对比 fd inode vs map inode | — | **不一致 → 检测触发** |

**结论**: 需要在内核/seccomp 层拦截 `__NR_fstat` 系统调用，同时伪造 `/proc/self/map_files` 中的 inode 值。

---

### 2.2 IPC / Binder 心跳检测（326分）

#### ProcessMonitor 进程采样（每秒）

**类**: `YouAreLoser/C1156SJ.java`, `C1282UJ.java`

```
RxJava interval(1, SECONDS)
  → System.nanoTime() 打时间戳
  → /proc/[pid]/stat    (进程 CPU tick)
  → /proc/stat          (全局 CPU tick)
  → /proc/[pid]/fd      (文件描述符数量)
  → /proc/[pid]/io      (IO 读写字节)
  → /proc/[pid]/status  (线程数, vm 大小)
```

#### Binder Loop Check（每5秒）

**类**: `com/zhenxi/hunter/ZhenxiServerIpc.java`

```java
// 每 5000ms 调度一次
scheduleAtFixedRate(() -> {
    NativeEngine.getZhenxiInfoC(i);  // → JNI → libhunter.so
}, 5000, 5000, MILLISECONDS)
```

**Native 层** (`libhunter.so`):
```
getZhenxiInfoC() 内部:
  1. 构造 Binder 事务
  2. clock_gettime(CLOCK_MONOTONIC) 起点
  3. ioctl(BINDER_WRITE_READ)        ← Binder 通信
  4. clock_gettime(CLOCK_MONOTONIC) 终点
  5. 计算 delta → 判定设备类型
```

#### ⚠️ 为何 IPCThreadState.cpp delay 无效

| 我们的修改 | Hunter 的测量 | 结果 |
|:---|:---|:---|
| `IPCThreadState::talkWithDriver()` 中加 `usleep()` | Native `clock_gettime()` 在 usleep 前后测 | **延迟成为异常信号** |

**结论**: Binder 时序检测在 Native 层。需要 hook `clock_gettime()` 或在 `getZhenxiInfoC` 返回前注入延迟。

---

### 2.3 隐藏 API / Magisk 检测（44分）

#### Java 层

**主类**: `com/zhenxi/hunter/utils/HiddenAPIEnforcementPolicyUtils.java`

```java
// Hunter 自己调用隐藏 API 来测试
import sun.misc.Unsafe;

// 解码 "anti hide api" 标签用于日志
byte[]{97, 110, 116, 105, 32, 104, 105, 100, 101, 32, 97, 112, 105, 32}

// 调用 VMRuntime.setHiddenApiExemptions() 来豁免自己
Unsafe unsafe = AbstractC1824cw.f6953a;
HashSet hashSet = AbstractC1383Vv.f5157a;
AbstractC1824cw.m3998b(strArr);  // → setHiddenApiExemptions(strArr)
```

#### Native 层

```java
// NativeEngine.java 中的相关 native 方法
public static native ArrayList checkFromZygote();
public static native ListItemBean checkZygisk();         // Zygisk 检测
public static native ListItemBean checkRootFromAVCLog(); // Root 日志检测
public static native ListItemBean checkRiskFile();       // 风险文件扫描
```

#### 第三方 Magisk 检测工具

Hunter 内置了开源项目 `top.canyie.magiskkiller`:
- **类**: `top/canyie/magiskkiller/SubprocessMain.java`
- 使用 `ParcelFileDescriptor.adoptFd()` 检测 Magisk daemon socket

#### 根因

Hunter 的 Hidden API 检测不是检查"进程名是否在白名单"，而是：
1. 用 `sun.misc.Unsafe` 绕开 API 限制调用 `VMRuntime.setHiddenApiExemptions()`
2. **尝试调用受限 API**
3. 如果成功 → 说明隐藏 API 策略宽松 → 判定为 Magisk/模拟器环境

删除 `IsHunterProcess()` 不影响这个检测逻辑。

---

### 2.4 无障碍服务检测（131分）

**主类**: `YouAreLoser/AbstractC0136C9.java` (lines 269-271, 467-474)

```java
// ⚠️ 注意 flags=-1：遍历所有用户的无障碍服务
List<AccessibilityServiceInfo> list = 
    accessibilityManager.getEnabledAccessibilityServiceList(-1);

for (AccessibilityServiceInfo info : list) {
    String pkg = info.getId().split("/")[0];
    String svc = info.getId().split("/")[1];
    String desc = info.getDescription();
    // 每一个都作为检测数据点上报
}
```

其他辅助类：
- `AbstractC1740ba.java`: 检查 `isTouchExplorationEnabled()`
- `C3163yD.java`: 检查 `SwitchAccess` 服务配置

#### ⚠️ 为何 AccessibilityManagerService.java 返回空列表可能无效

Hunter 调用的是 `getEnabledAccessibilityServiceList(-1)` (flags=-1)，我们的 bypass 可能只拦截了 flags=0 的调用路径。

---

### 2.5 环境 / 模拟器特征检测

**主类**: `YouAreLoser/AbstractC0136C9.java` (method `m480a()`)

#### 系统属性检测（getprop）

```
ro.boot.vm           ro.boot.hypervisor       ro.hardware.virtual
ro.cloudphone.instance  persist.sys.vm        ro.build.cloud
ro.device.owner      ro.sys.cloud_env        ro.kernel.qemu
ro.hardware          (含 "virtual" 关键词)
```

#### 文件系统检测

```
/proc/self/status    → TracerPid: 0 检查
/proc/cpuinfo        → QEMU/Virtual CPU 标记
/proc/self/cgroup    → docker/lxc 容器
/proc/self/mounts    → 异常挂载点
/sys/class/dmi/id/product_name  → 云手机特征
/dev/socket/qemud    → 模拟器标记文件
```

#### 进程检测

```bash
ps -A | grep -E "qemu|vmm|cloud|vbox"
```

#### 网络检测

```bash
ip link | grep -E "veth|tun|tap|docker"
```

#### GPU 检测

```bash
dumpsys SurfaceFlinger | grep GLES  # QEMU/software GPU
```

#### debuggable 标志

```java
(context.getApplicationInfo().flags & 2) != 0  // FLAG_DEBUGGABLE
```

---

### 2.6 反调试 / 反篡改

#### Java 层

- `App.java:3817` — `lambda$attachBaseContext$2(YouAreLoser.VA, YouAreLoser.MA)` — 控制流平坦化，JADX 无法完整反编译
- `MainActivity.java:2129` — `YouAreLoser.yH` — 另一个反篡改方法

#### Native 层

```java
// NativeEngine.java
public static native void DetectHardwareBreakpoints();  // 硬件断点检测
public static native void hideLinkerAndMaps();           // 隐藏 linker maps
```

```bash
# libhunter.so 调试字符串
checkPtraceTracerForMain
check ptrace thread start success
checkTracerPid read error
check class loader == null
```

---

### 2.7 风险文件/路径扫描

Native 代码中的硬编码黑名单路径：

```
/data/local/tmp/txysvr.apk
/data/local/tmp/yijianwanservice.apk
/data/magisk.apk
/system/app/SuperUser/SuperUser.apk
/system/app/LDAppStore/LDAppStore.apk
```

与 Magisk 相关的检测:
```
Check Find Root File
Check Find Root In Linker
Check Find Root In Mounts
Check Find Root Magisk Mode
Check Find Root Mark
Check Find Root Permission
```

---

## 三、检测分类与分数来源

| 检测类别 | 主要来源 | 分数范围 | 备注 |
|----------|----------|:---:|------|
| `anti hide api` (44) | Java + Native | 0-100 | VMRuntime 隐藏 API 调用测试 |
| `anti accessibility server` (131) | Java | 0-200 | 枚举所有无障碍服务 |
| `application loadLibrary time` (34) | Java | 0-50 | SO 库加载耗时 |
| `JNI_OnLoad init lib path natives` (160) | Native | 0-200 | Native 初始化时序 |
| `start main check thread` (145) | Java/Native | 0-200 | 主进程检测线程启动 |
| `iso ipc thread heartbeat` (326) | Java/Native | 0-500 | ISO Binder 心跳往返延迟 |
| `twin ipc thread heartbeat` (2) | Java/Native | 0-500 | Twin Binder 心跳往返延迟 |
| `start check apk sign 111` (270) | Native | 0-500 | APK 签名全链路验证 |
| `native apk sign check open fd` (49) | Native | 0-100 | APK 文件描述符属性 |
| `check apk sign for iso` (90) | Native | 0-200 | ISO 进程独立 APK 校验 |
| `native check apk sign 222` (32) | Native | 0-100 | 第二阶证书链校验 |
| `check apk sign inode fail` | Native | 布尔值 | inode 不一致标记 |
| `Hidden API enabled` | Java | 布尔值 | ISO/Twin 双进程告警 |
| `YouAreLoser` | Java/Native | 布尔值 | 反调试/反篡改标记 |

---

## 四、现有 Bypass 方案失败原因总览

| 我们的修改 | Hunter 的实际检测 | 失败原因 |
|:---|:---|:---|
| `fstat.cpp` 拦截 libc `fstat()` | `__NR_fstat` 原始 syscall + `/proc/self/map_files` inode 双端对比 | 没拦截原始 syscall，没伪造 map_files |
| `IPCThreadState.cpp` `usleep()` 延迟 | Native `clock_gettime()` 在 Binder ioctl 前后测时 | Native 层测量不受 Java/Binder 层延迟影响 |
| `AccessibilityManagerService.java` 返回空列表 | `getEnabledAccessibilityServiceList(-1)` flags=-1 | 可能只拦截了 flags=0 路径 |
| `hidden_api.cc` 删除 `IsHunterProcess()` | `HiddenAPIEnforcementPolicyUtils` + `sun.misc.Unsafe` 直接调用 | 检测的是 API 是否可调用，不是进程名 |

---

## 五、修正方案

| 检测项 | 优先级 | 新方案 | 修改层 | 难度 |
|--------|:---:|--------|--------|:---:|
| APK inode 绕过 | **P0** | seccomp-bpf 拦截 `__NR_fstat` + 伪造 `/proc/self/map_files` | kernel/seccomp | 高 |
| Binder 心跳 | **P1** | hook `clock_gettime()` 返回值或修改 `getZhenxiInfoC()` 逻辑 | libhunter.so / libc | 中 |
| 无障碍服务 | **P2** | 确认拦截 `getEnabledAccessibilityServiceList(-1)` 的 flags=-1 路径 | Java framework | 低 |
| 隐藏 API | **P3** | 阻止 `sun.misc.Unsafe` 访问 `VMRuntime.setHiddenApiExemptions` | ART runtime | 中 |
| 环境特征 | **P3** | 修改 `ro.hardware` 等 build.prop，删除 `/dev/socket/qemud` | init.rc / build.prop | 低 |

---

## 六、关键文件索引

### decompiled Java（hunter_decompiled/sources/）

| 文件 | 检测类别 |
|------|----------|
| `YouAreLoser/AbstractC0136C9.java` | 主环境检测类：20+ 项系统特征检测 |
| `YouAreLoser/C1156SJ.java` | 进程采样：/proc/pid/stat 等 |
| `YouAreLoser/C1282UJ.java` | ProcessMonitor：RxJava 1秒定时采样 |
| `YouAreLoser/AbstractC0422Gh.java` | APK 签名指纹获取 |
| `com/zhenxi/hunter/ZhenxiServerIpc.java` | ISO Binder 服务：5秒 loop check |
| `com/zhenxi/hunter/ZhenxiServerTwinIpc.java` | Twin Binder 服务 |
| `com/zhenxi/hunter/NativeEngine.java` | JNI 桥接：80+ native 方法声明 |
| `com/zhenxi/hunter/HiddenAPIEnforcementPolicyUtils.java` | 隐藏 API 豁免 + 检测 |
| `com/zhenxi/hunter/HunterPreload.java` | ZygotePreload：最早阶段检测 |
| `com/zhenxi/hunter/App.java` | 主进程入口 + SO 加载 |
| `com/zhenxi/hunter/MainActivity.java` | 主 Activity + dalvik/system 导入 |
| `top/canyie/magiskkiller/SubprocessMain.java` | 第三方 Magisk 检测工具 |
| `com/zhenxi/hunter/HunterDataBean.java` | 事件数据模型（2秒去重阈值） |

### Native 库

| 文件 | 包含 |
|------|------|
| `hunter_decompiled/resources/lib/arm64-v8a/libhunter.so` | 所有核心检测的 Native 实现 |

---

*分析工具: jadx 1.5.5 | Java 版本: 17 | 反编译耗时: ~5分钟 | 总文件: 6737 Java sources*
