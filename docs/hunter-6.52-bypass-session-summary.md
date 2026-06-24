# Hunter 6.52 绕过技术总结

> 时间：2026-06-24  
> 环境：自编译 AOSP Android 16（fuxi 设备配置），运行于 OrbStack 模拟器  
> 目标：在 AOSP 源码层绕过 Hunter 6.52（com.zhenxi.hunter）的安全检测

---

## 1. 背景与目标

### Hunter 是什么

Hunter（com.zhenxi.hunter）是小红书（XHS）使用的安全检测 SDK，版本 6.52。它在 App 启动时对运行环境进行多维度扫描，检测模拟器、Root、Xposed/Magisk、篡改 APK 等风险因素，并将检测结果上报给服务端，用于设备风险评分。

### 为什么从 AOSP 源码层做

常规绕过思路（Frida hook、Xposed 模块、Magisk 模块）本身会被 Hunter 检测到。Hunter 在 native 层通过多重校验（seccomp 过滤、进程监控、符号扫描）识别上述框架的存在。

在 AOSP 源码层直接修改系统行为，让系统在 libc/ART 层面对目标 App 提供"经过过滤的事实"，是不留痕迹的最干净方案：无需注入进程、不改变 Hunter APK 本身、Hunter 的 anti-debug 和 anti-hook 检测均无法发现。

---

## 2. Hunter 架构分析

Hunter 6.52 采用三进程架构，相互 IPC 心跳校验，任一进程被杀死或篡改均会触发告警：

| 进程名 | 角色 |
|--------|------|
| `com.zhenxi.hunter:hunter_main_process` | 主进程，负责 Java 层检测和协调 |
| `com.zhenxi.hunter:hunter_server_iso` | 隔离服务进程，运行 native 签名/inode 检测 |
| `com.zhenxi.hunter:hunter_server_twin` | 孪生监控进程，负责进程存活监控 |

三进程通过 IPC（Binder）互相发送心跳（`heartbeat_request`），并交叉校验 APK 签名和 inode。如果任何进程崩溃或 IPC 超时，检测项会标记为异常。

### 主要检测项（本次会话涉及）

- **Hidden API 检测**：调用 `VMRuntime.setHiddenApiExemptions()` 探测 Magisk 环境
- **APK 签名 inode 检测**：对比 `fstat(fd).st_ino` 与 `/proc/self/maps` 里的 inode 字段
- **无障碍服务检测**：枚举已安装的 Accessibility Service，识别辅助工具
- **进程监控**：读取 `/proc/stat`，监控 CPU/进程状态

---

## 3. 问题一：Hidden API 检测

### 检测原理

Hunter 通过 `YouAreLoser` 混淆模块（Kotlin coroutine），用 Java 反射调用：

```java
// 伪代码
VMRuntime runtime = VMRuntime.getRuntime();          // getRuntime 是 kMax，始终允许
runtime.setHiddenApiExemptions(new String[]{"L"});   // 尝试白名单整个命名空间
```

在正常 AOSP（user build）环境下，`setHiddenApiExemptions` 是 `blocked`，反射调用会被 ART 拒绝并抛出异常。Hunter 的逻辑是：**如果这个调用成功了**，说明 hidden API enforcement 被绕过（Magisk 的常见行为），触发"Hidden API has been enabled"告警。

### 排查过程

项目前期代码在 `art/runtime/hidden_api.cc` 的 `ShouldDenyAccessToMemberImpl` 里插入了一段特殊 allow 逻辑：

```cpp
// 旧代码（错误！）
if (member_signature.DoesPrefixMatch("Ldalvik/system/VMRuntime;->setHiddenApiExemptions")) {
    MaybeUpdateAccessFlags(runtime, member, kAccPublicApi);
    return false;  // 允许调用
}
```

目的是让自定义代码能调用此接口，但这**反而让 Hunter 的探测成功**——Hunter 的调用从抛出异常变成了成功返回，正好触发了它的判断逻辑。

### 修复方案

**双保险机制：**

**第一层 —— `art/runtime/hidden_api.cc`**：删除上述 5 行特殊 allow 块，让 `setHiddenApiExemptions` 恢复为 `blocked`。Hunter 通过反射调用时会得到 `denied`（抛出异常），调用失败，不触发告警。

**第二层 —— `art/runtime/runtime.h` + `dalvik_system_ZygoteHooks.cc`**：新增 `LockHiddenApiExemptions()` 机制。在 App 进程 fork 后（`ZygoteHooks_nativePostForkChild`），如果 enforcement policy 是 `kEnabled`，立即锁定 exemptions 列表：

```cpp
// runtime.h 新增
void LockHiddenApiExemptions() {
    hidden_api_exemptions_locked_ = true;
    hidden_api_exemptions_.clear();
}

void SetHiddenApiExemptions(const std::vector<std::string>& exemptions) {
    if (!hidden_api_exemptions_locked_) {
        hidden_api_exemptions_ = exemptions;
    }
    // 锁定后忽略所有设置，静默成功（不崩溃）
}
```

这样即使 Hunter 绕过了反射检查成功调用了 `setHiddenApiExemptions`，exemptions 也不会被设置，后续的 hidden API 调用依然会被 deny。

---

## 4. 问题二：APK 签名 inode 检测

### 检测原理

Hunter 的 ISO 进程通过 native 代码执行双重 inode 校验：

1. **来源 A**：`open("/data/.../base.apk")` 打开 APK 文件，`fstat(fd)` 获取 `st_ino`
2. **来源 B**：读取 `/proc/self/maps`，解析其中 base.apk 对应的 inode 字段（第6列）

两者必须完全一致。如果不一致，说明 APK 被替换或 fd 被重定向，触发 "check apk sign inode fail"。

Hunter 同时通过 4 个阶段校验：
```
start check apk sign 111    # 开始
tee check apk sign start    # TEE 层参与
native apk sign check       # native 签名检查
native apk check inode&uid&gid success  # inode 校验
```

### 根因分析

项目在 `bionic/libc/bionic/open.cpp` 里对 `/proc/self/maps` 的拦截**只读取了 8192 字节**（约 72 行）：

```cpp
// 旧代码（错误！）
static char rbuf[8192];
ssize_t rn = read(rfd, rbuf, sizeof(rbuf) - 1);  // 只读 8192 字节
```

而实际上：
- `/proc/self/maps` 文件总大小约 **315KB**，包含 **4000+ 行**
- base.apk 的映射条目位于约**第 434 行**
- 8192 字节只能覆盖前 **72 行**，完全读不到 base.apk 条目

导致的后果：Hunter 从我们伪造的 maps 里找不到 base.apk 对应的 inode，而 `fstat(fd)` 能正常得到 inode，两者不一致 → 检测失败。

### ANR 陷阱

修复方案是流式读取完整的 maps 文件：读取原始 maps → 过滤掉模拟器相关 so → 写入 pipe 返回给调用方。

但这里有个陷阱：**Linux pipe 默认缓冲区只有 64KB**，而 maps 过滤后仍有约 300KB，`write()` 会阻塞等待对方读取。而 Hunter 在读完 pipe 之前还没进入读取阶段，造成**双向死锁**：

- Hunter 等待 open() 返回 fd 才开始读
- 我们的代码在 open() 返回前就要把内容全写入 pipe
- 300KB > 64KB，写入阻塞 → Hunter 也永远等不到 fd → ANR

### 最终修复方案

```cpp
if (strcmp(pathname, "/proc/self/maps") == 0) {
    int rfd = __openat(AT_FDCWD, "/proc/self/maps", O_RDONLY|O_CLOEXEC, 0);
    if (rfd >= 0) {
        int pfd[2];
        if (pipe(pfd) == 0) {
            // 关键：扩大 pipe 缓冲区到 1MB，大于 maps 文件总大小
            fcntl(pfd[1], F_SETPIPE_SZ, 1024 * 1024);

            static char chunk[4096];  // static 避免栈溢出（bionic 限 2048 字节）
            static char line[512];
            size_t line_pos = 0;

            // 流式逐字节处理，按行过滤
            ssize_t n;
            while ((n = read(rfd, chunk, sizeof(chunk))) > 0) {
                for (ssize_t i = 0; i < n; i++) {
                    char c = chunk[i];
                    if (c == '\n') {
                        if (line_pos > 0 &&
                            !strstr(line, "_stream.so") &&
                            !strstr(line, "OpenglCodecCommon") &&
                            !strstr(line, "OpenglSystemCommon") &&
                            !strstr(line, "qti_rcenc")) {
                            write(pfd[1], line, line_pos);
                            write(pfd[1], "\n", 1);
                        }
                        line_pos = 0;
                    } else if (line_pos < sizeof(line) - 1) {
                        line[line_pos++] = c;
                    }
                }
            }
            close(rfd);
            close(pfd[1]);
            return FDTRACK_CREATE(pfd[0]);
        }
    }
}
```

过滤掉的 so 名称（模拟器特征）：
- `_stream.so`（QEMU 渲染流）
- `OpenglCodecCommon`、`OpenglSystemCommon`（goldfish OpenGL）
- `qti_rcenc`（高通编码器，模拟器特有命名）

---

## 5. 调试手段：NQE Trace 系统

为了在不重启模拟器的情况下观察 Hunter 的文件访问行为，项目在 bionic 层建立了一套轻量 trace 系统。

### 工作原理

在 `open.cpp`、`stat.cpp` 的系统调用包装器里，根据 `debug.nqe.trace` 属性开关，将关键操作记录到 `/data/local/tmp/` 下的文件：

| Trace 文件 | 记录内容 | 格式 |
|-----------|---------|------|
| `nqe_open.txt` | 所有 open/openat 调用 | `O\|路径\|返回fd` |
| `nqe_trace.txt` | fstat/fstatat/stat 调用 | `F\|fd\|路径\|inode\|result` |
| `nqe_props.txt` | 属性读取 | 属性名=值 |

### 开关方式

```bash
adb root
adb shell setenforce 0          # SELinux permissive（必须，见下）
adb shell setprop debug.nqe.trace 1
# 启动 Hunter，复现场景
adb pull /data/local/tmp/nqe_open.txt
adb pull /data/local/tmp/nqe_trace.txt
```

### 实现要点

在 `stat.cpp` 的 `nqe_trace_fd_s()` 里，trace 文件的 fd 需要用 `__openat` 直接调用，而不是 `open()`，原因见踩坑记录第3条。

---

## 6. 踩坑记录

### 6.1 栈帧超限（-Wframe-larger-than=2048）

**现象**：编译时报错 `error: stack frame size (4928) exceeds limit (2048) in function 'open'`

**原因**：bionic 的编译选项有 `-Wframe-larger-than=2048`，作为 error 处理。在 `open()` 里定义 `char chunk[4096]` 和 `char line[512]` 共约 4.6KB，超限。

**修复**：将这两个缓冲区改为 `static` 局部变量，放到 BSS 段而不是栈上：
```cpp
static char chunk[4096];
static char line[512];
```

**遗留问题**：static 变量被所有线程共享，理论上存在线程安全隐患（见 6.4）。

### 6.2 -Wold-style-cast 编译错误

**现象**：`(unsigned long long)sb->st_ino` 在 C++ 编译时报 old-style cast 警告（被当作 error）

**修复**：统一改为 `static_cast<unsigned long long>(sb->st_ino)`

### 6.3 stat.cpp 里的递归调用问题

**现象**：开启 trace 时 Hunter 崩溃，关闭时正常

**根因**：`nqe_trace_fd_s()` 里用 `open()` 打开 trace 文件：
```cpp
sFd = open("/data/local/tmp/nqe_trace.txt", O_WRONLY|O_CREAT|O_APPEND, 0666);
```
这会调用我们自己拦截的 `open()` 函数。在 `fstat()` → `nqe_trace_fd_s()` → `open()` 的调用链里，`open()` 内部又会触发各种检测逻辑，在某些条件下形成不期望的副作用。

**修复**：改用 `__openat` 直接系统调用，完全绕过我们的 open() 拦截层：
```cpp
sFd = __openat(AT_FDCWD, "/data/local/tmp/nqe_trace.txt",
               O_WRONLY|O_CREAT|O_APPEND|O_CLOEXEC, 0666);
```

### 6.4 static 缓冲区线程安全隐患（已修复）

**问题**：`open.cpp` 里处理 `/proc/self/maps` 的 `static char chunk[4096]` 和 `static char line[512]` 是全局共享的，`line_pos` 是栈变量但指向同一个 `line[]`。多线程并发调用 `open("/proc/self/maps")` 会导致缓冲区内容相互覆盖。

**修复**（Round 5）：改为动态分配，每次调用独立缓冲区：
```cpp
char* chunk = static_cast<char*>(malloc(4096));
char* line  = static_cast<char*>(malloc(512));
if (chunk && line) {
    // ... 处理逻辑
}
free(line);
free(chunk);
```

### 6.5 SELinux 阻断 trace 文件写入

**现象**：trace 文件权限被 SELinux 拒绝（`shell_data_file` 标签）

**说明**：`/data/local/tmp/` 下的文件在 SELinux enforcing 模式下，`untrusted_app` 域无法写入。必须先 `setenforce 0` 切换到 permissive 模式。

用户确认："NQE的trace之前一直能输出啊，用adb设置下属性就行了"——`adb root && setenforce 0` 后 trace 正常工作，这是正常预期行为。

---

## 7. 最终验证结果

### 检测报告对比

**修改前**（`hunter_device_info_6.52_1782058149310.txt`，代表性失败报告）：
```
{title=Android 9.0 Hidden API has been enabled
 risk=[The attempt to invoke @HideApi was successful,
       indicating the potential presence of Magisk on the current device.]}

risk=[check apk sign inode fail]
check apk sign inode fail
```

**修改后**（`hunter_device_info_6.52_1782293110275.txt`，最终成功报告）：
```
check hide api (0)                              ← Hidden API 检测：无风险
native apk check inode&uid&gid success          ← inode 校验：通过
native check apk sign 222                       ← 二次签名验证：通过
creator check apk sign 333                      ← 创建者验证：通过
ipc check apk sign 444                          ← IPC 跨进程验证：通过
check apk sign finish                           ← 完成，无错误
```

### Hunter UI 结果

Hunter 6.52 界面显示**绿色笑脸**，三进程（28 个 main event + 34 个 ISO event）全部正常运行。

---

## 8. 文件改动清单

### AOSP 源码（OrbStack VM: /home/robin/aosp/aosp）

| 文件 | 改动摘要 | 原因 |
|------|---------|------|
| `art/runtime/hidden_api.cc` | 删除 `setHiddenApiExemptions` 的 5 行特殊 allow 块 | 该 allow 让 Hunter 的探测成功，触发 Magisk 告警 |
| `art/runtime/runtime.h` | 新增 `hidden_api_exemptions_locked_` 字段和 `LockHiddenApiExemptions()` 方法 | 双保险：锁定后 `setHiddenApiExemptions` 静默忽略 |
| `art/runtime/native/dalvik_system_ZygoteHooks.cc` | fork child 后调用 `LockHiddenApiExemptions()` | 在 App 进程启动时立即锁定 exemptions |
| `bionic/libc/SYSCALLS.TXT` | lp64 的 `fstat`/`fstatat` 符号改为 `__fstat`/`__fstatat` | 为 C wrapper 腾出公开符号名 |
| `bionic/libc/bionic/stat.cpp` | 新增 `fstat`/`fstatat`/`stat` C wrapper，内含 NQE trace；`nqe_trace_fd_s()` 改用 `__openat` | inode 调试可见性；避免递归调用 open() |
| `bionic/libc/bionic/open.cpp` | `/proc/self/maps` 拦截改为流式读取，`F_SETPIPE_SZ` 扩大到 1MB；其他：goldfish/drm/ranchu 节点拦截，`/proc/version` 和 `/proc/net/route` 返回假内容 | 修复截断导致 inode 丢失；修复 ANR；隐藏模拟器特征 |
| `frameworks/base/.../AccessibilityManagerService.java` | XHS bypass 代码移到 `resolvedUserId` 解析之前，确保对 uid≥10000 的 App 优先返回假服务列表 | 无障碍服务检测绕过 |

### 项目文档（android16_emulator 仓库）

| 文件 | 说明 |
|------|------|
| `hunter_device_info_6.52_*.txt`（10份）| 历史检测报告，含失败和最终成功对比 |
| `docs/hunter-6.52-bypass-plan.md` | Bypass 计划文档 |
| `hunter-6.52-reverse-analysis.md` | 逆向分析笔记 |
| `session-hunter6.52-bypass-20260621.md` | 会话记录 |
| `outputs/` | NQE trace 输出样本 |
| `scripts/libinode_fix/` | inode 辅助工具 |
