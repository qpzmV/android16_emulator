# 会话原始 Dump：kretprobe 崩溃调试（2026-06-29）

> 机械导出，事无巨细，保留所有细节、命令、输出、失败、顺序。

---

## 背景与目标

目标：在 XiaoHongShu (XHS) v9.1.0 + 自定义 AOSP Android 16 模拟器上，绕过 Hunter SDK 的模拟器检测。
方案：编写内核 kretprobe 模块，拦截 stat()/open() 调用，对 app UID (≥10000) 隐藏模拟器特征路径（ranchu、goldfish、qemu 等），返回 ENOENT。

---

## 技术背景（继承自上次会话）

### GKI 内核信息
- 内核版本：`6.6.66-android15-8-gb66429556fb8`
- struct module 大小：GKI=1536B，linux-stable=1280B（差 256B）
- RELA 偏移问题：GKI 从 0x0188 读 init，linux-stable 写在 0x0150

### expand_elf.py 核心逻辑
两步 ELF patch：
1. 在 `.rela.gnu.linkonce.this_module` 段末尾插入新 RELA 条目（GKI 偏移 0x0188/init，0x05b8/cleanup）
2. 将 `.gnu.linkonce.this_module` 从 1280B 扩展到 1536B（插入 256 字节零）

### 已知稳定的基础
- kprobe on `do_sys_openat2`：confirmed 17770+ hits/sec，稳定
- kretprobe on `vfs_statx`（极简版，只有 atomic_inc，data_size=0）：confirmed 19408+ hits in 5sec，稳定
- tracefs 确认 `vfs_statx` x1 是 `struct filename *`（内核地址 0xffffff80...）

---

## 本次会话流程

### 阶段 1：模拟器重启，推送 IS_ERR 版本

**现状**：上次会话中 IS_ERR_OR_NULL 版 vfs_statx kretprobe 崩溃，设备掉线。

```bash
pkill -f "qemu-system-aarch64"
NO_WINDOW=0 WIPE_DATA=1 WAIT_FOR_BOOT=0 bash scripts/run-aosp-fuxi-pkg-selfbuilt-ui.sh &
# 等待 boot_completed
```

等待 ~30 秒，boot_completed=1。

adb root 确认：
```
uid=0(root) gid=0(root) groups=0(root),1004(input),...
```

### 阶段 2：tracefs 诊断 struct filename 内存布局

**目的**：确认 GKI vfs_statx 的 x1 参数是否真的是 struct filename *，以及 fn->name 是否可访问。

#### 实验 1：读取 x1 前 4 个字段

```bash
echo "p:probe_fn vfs_statx fn0=+0(%x1):x64 fn8=+8(%x1):x64 fn16=+16(%x1):x64 fn24=+24(%x1):x64" > /sys/kernel/tracing/kprobe_events
echo 1 > /sys/kernel/tracing/events/kprobes/probe_fn/enable
echo 1 > /sys/kernel/tracing/tracing_on
stat /vendor/bin/qemu-props
```

输出（5条）：
```
stat-2508 [001] d.... 34.612402: probe_fn: (vfs_statx+0x0/0x1ec)
  fn0=0xffffff80f8340020 fn8=0x739cf084a9 fn16=0x1 fn24=0x0
stat-2508 [001] d.... 34.612437: probe_fn: (vfs_statx+0x0/0x1ec)
  fn0=0xffffff80f8340020 fn8=0x739cd5984c fn16=0x1 fn24=0x0
stat-2508 [001] d.... 34.612446: probe_fn: (vfs_statx+0x0/0x1ec)
  fn0=0xffffff80f8340020 fn8=0x7feeaaa540 fn16=0x1 fn24=0x0
stat-2508 [001] d.... 34.612468: probe_fn: (vfs_statx+0x0/0x1ec)
  fn0=0xffffff80f8340020 fn8=0x739cee90c0 fn16=0x1 fn24=0x0
stat-2508 [001] d.... 34.612470: probe_fn: (vfs_statx+0x0/0x1ec)
  fn0=0xffffff80f8340020 fn8=0x739cd5e75b fn16=0x1 fn24=0x0
```

分析：
- fn0（offset 0）= 0xffffff80f8340020 → 内核地址，所有调用相同（slab 重用）→ fn->name
- fn8（offset 8）= 不同的用户态地址 → fn->uptr（原始用户指针）
- fn16（offset 16）= 0x1 → fn->refcnt（atomic_t = 1）
- fn24（offset 24）= 0x0 → fn->aname（NULL）

结论：GKI struct filename 布局与 linux-stable 6.6 一致。

#### 实验 2：双重解引用读字符串

```bash
echo "p:probe_fn3 vfs_statx name=+0(+0(%x1)):string" > /sys/kernel/tracing/kprobe_events
```

输出：
```
sh-3913 [003] d.... 135.438790: probe_fn3: (vfs_statx+0x0/0x1ec) name="/dev/__properties__"
sh-3913 [003] d.... 135.438834: probe_fn3: (vfs_statx+0x0/0x1ec) name="/proc/self/exe"
sh-3913 [003] d.... 135.438845: probe_fn3: (vfs_statx+0x0/0x1ec) name="/system/bin/sh"
sh-3913 [003] d.... 135.438878: probe_fn3: (vfs_statx+0x0/0x1ec) name="/system/etc/ld.config.arm64.txt"
sh-3913 [003] d.... 135.438879: probe_fn3: (vfs_statx+0x0/0x1ec) name="/linkerconfig/ld.config.txt"
```

**关键结论**：tracefs 能通过 `+0(+0(%x1)):string` 读出完整路径字符串，说明：
- fn 是有效 struct filename 指针
- fn->name（offset 0）是有效内核指针
- 该指针指向的字符串完全可读

---

### 阶段 3：崩溃版本 (IS_ERR) 推送测试

推送之前编译好的 xhs_vfs_gki.ko（IS_ERR_OR_NULL 版）：

```bash
adb push xhs_vfs_gki.ko /data/local/tmp/
# 启动 dmesg 流式捕获
adb shell "su root dmesg -w" > /tmp/dmesg_vfs_crash.txt &
# insmod
timeout 10 adb shell "su root insmod /data/local/tmp/xhs_vfs_gki.ko"
# exit=255，device offline
```

**dmesg 捕获分析**：
- /tmp/dmesg_vfs_crash.txt 有 791 行，最后时间戳 33.395455s
- insmod 在 boot_completed 后（~33s）执行，崩溃立即发生
- **未捕获到 panic 消息**：kernel panic 写入速度快于 adb 传输

---

### 阶段 4：逐步隔离崩溃根因

#### 诊断版 A（xhs_vfs_v2）：只检 UID，int 替代 bool，不访问 fn

```c
struct call_data { int block; };

static int statx_entry(struct kretprobe_instance *ri, struct pt_regs *regs)
{
    struct call_data *d = (struct call_data *)ri->data;
    d->block = 0;
    if ((unsigned int)current_euid().val >= (unsigned int)app_uid_min)
        d->block = 1;
    return 0;
}
static int statx_ret(struct kretprobe_instance *ri, struct pt_regs *regs)
{
    struct call_data *d = (struct call_data *)ri->data;
    if (d->block)
        regs->regs[0] = (unsigned long)(long)(-ENOENT);
    return 0;
}
// data_size = sizeof(struct call_data) = 4
// .kp.symbol_name = "vfs_statx"
```

结果：**insmod exit=255，device offline**（崩溃）

结论：崩溃不是 fn->name 访问问题，是更底层的原因。

---

#### 诊断版 C：data_size=4，只写 ri->data=0，ret 不改 regs

```c
static int entry_c(struct kretprobe_instance *ri, struct pt_regs *regs)
{
    *(int *)ri->data = 0;
    atomic_inc(&cnt);
    return 0;
}
static int ret_c(struct kretprobe_instance *ri, struct pt_regs *regs)
{
    return 0;
}
// data_size = 4
```

结果：**insmod exit=0，device stable**，cnt=正常值

结论：`data_size=4` 本身没问题；写 `ri->data` 没问题。

---

#### 诊断版 D：data_size=0，ret 写 `regs->regs[0]=regs->regs[0]`（恒等）

```c
static int entry_d(struct kretprobe_instance *ri, struct pt_regs *regs)
{
    atomic_inc(&cnt);
    return 0;
}
static int ret_d(struct kretprobe_instance *ri, struct pt_regs *regs)
{
    regs->regs[0] = regs->regs[0];  // 恒等写入
    return 0;
}
// data_size = 0
```

结果：**insmod exit=0，device stable**，cnt=4523

结论：写 `regs->regs[0]` 本身没问题（恒等写）。

---

#### 诊断版 E：data_size=4，current_euid()+条件 ri->data，ret 条件写 regs[0]=0

```c
static int entry_e(struct kretprobe_instance *ri, struct pt_regs *regs)
{
    int *d = (int *)ri->data;
    *d = 0;
    if ((unsigned int)current_euid().val >= (unsigned int)app_uid_min)
        *d = 1;
    atomic_inc(&cnt);
    return 0;
}
static int ret_e(struct kretprobe_instance *ri, struct pt_regs *regs)
{
    int *d = (int *)ri->data;
    if (*d)
        regs->regs[0] = 0;  // 写 0（非 -ENOENT）
    return 0;
}
// data_size = 4
```

结果：**insmod exit=255，device offline**（崩溃）

结论：current_euid() + 条件写 regs 组合崩溃，且值为 0（非 -ENOENT）也崩溃，排除"只是 -ENOENT 导致系统崩"。

---

#### 诊断版 F：data_size=4，current_euid()（结果废弃），ret 不改 regs

```c
static int entry_f(struct kretprobe_instance *ri, struct pt_regs *regs)
{
    unsigned int uid = current_euid().val;
    (void)uid;  // 显式丢弃结果
    *(int *)ri->data = 0;
    atomic_inc(&cnt);
    return 0;
}
static int ret_f(struct kretprobe_instance *ri, struct pt_regs *regs)
{
    return 0;  // 不写 regs
}
// data_size = 4
```

结果：**insmod exit=0，device stable**，cnt=4523

结论：`current_euid()` 本身不导致崩溃。

---

#### 诊断版 G：data_size=4，不调 current_euid，ret 始终写 regs[0]=0

```c
static int entry_g(struct kretprobe_instance *ri, struct pt_regs *regs)
{
    *(int *)ri->data = 1;  // 始终 1
    atomic_inc(&cnt);
    return 0;
}
static int ret_g(struct kretprobe_instance *ri, struct pt_regs *regs)
{
    regs->regs[0] = 0;  // 始终写 0（无条件）
    return 0;
}
// data_size = 4
```

结果：**insmod exit=0，device stable**，cnt=2906

结论：ret_handler 始终写 `regs[0]=0` 没问题（等价于：大多数 stat 本来就返回 0，这是 no-op）。

---

### 阶段 5：security_inode_getattr 方案尝试

#### kallsyms 查询

```bash
grep -E 'do_fstatat|vfs_fstatat|sys_fstatat|security_inode_getattr' /proc/kallsyms
```

输出：
```
0000000000000000 T vfs_fstatat
0000000000000000 T __arm64_sys_fstatat64
0000000000000000 T security_inode_getattr
0000000000000000 r __BTF_ID__func__security_inode_getattr__755937
```

`do_fstatat` 不在 kallsyms（可能是 inline 或 static），`security_inode_getattr` 在。

#### xhs_sec.c 完整代码

```c
// int security_inode_getattr(const struct path *path)
// ARM64: x0 = const struct path *

struct call_data { int block; };

static int sec_entry(struct kretprobe_instance *ri, struct pt_regs *regs)
{
    struct call_data *d = (struct call_data *)ri->data;
    const struct path *path;
    struct dentry *dentry;
    const char *dname;

    d->block = 0;
    if ((unsigned int)current_euid().val < (unsigned int)app_uid_min)
        return 0;

    path = (const struct path *)regs->regs[0];
    if (IS_ERR_OR_NULL(path)) return 0;

    dentry = path->dentry;
    if (IS_ERR_OR_NULL(dentry)) return 0;

    dname = dentry->d_name.name;
    if (!dname) return 0;

    if (name_is_blocked(dname))
        d->block = 1;
    return 0;
}

static int sec_ret(struct kretprobe_instance *ri, struct pt_regs *regs)
{
    struct call_data *d = (struct call_data *)ri->data;
    if (d->block) {
        regs->regs[0] = (unsigned long)(long)(-ENOENT);
        atomic_inc(&blocked_count);
    }
    return 0;
}

static struct kretprobe sec_krp = {
    .kp.symbol_name = "security_inode_getattr",
    .entry_handler  = sec_entry,
    .handler        = sec_ret,
    .data_size      = sizeof(struct call_data),
    .maxactive      = 64,
};
```

结果：**insmod exit=255，device offline**（崩溃）

---

## 全部测试结果汇总表

| 版本 | data_size | entry 内容 | ret 内容 | 结果 |
|------|-----------|-----------|---------|------|
| minimal | 0 | atomic_inc | return 0 | ✅ 稳定 |
| C | 4 | ri->data=0 | return 0 | ✅ 稳定 |
| D | 0 | atomic_inc | regs[0]=regs[0] | ✅ 稳定 |
| F | 4 | current_euid()(废弃)+ri->data=0 | return 0 | ✅ 稳定 |
| G | 4 | ri->data=1(始终) | regs[0]=0(始终) | ✅ 稳定 |
| UID-only | 4 | current_euid()+条件 ri->data | 条件 regs[0]=-ENOENT | ❌ 崩溃 |
| E | 4 | current_euid()+条件 ri->data | 条件 regs[0]=0 | ❌ 崩溃 |
| IS_ERR | 1(bool) | current_euid()+fn->name+strstr | 条件 regs[0]=-ENOENT | ❌ 崩溃 |
| sec | 4 | current_euid()+path->dentry->d_name | 条件 regs[0]=-ENOENT | ❌ 崩溃 |

---

## 崩溃捕获失败原因

- `dmesg -w` 流式捕获：panic 发生时设备立即掉线，panic 消息写入速度快于 adb 流传输
- `/proc/last_kmsg`：不存在
- `/sys/fs/pstore/`：没有内容（无 ramoops 配置）
- QEMU 串口日志（`/tmp/AOSP_fuxi_pkg_verbose.log`）：只有模拟器框架日志，无内核串口
- 结论：**至今未拿到完整 kernel panic 调用栈**

---

## 环境信息

- ADB 路径：`/Users/robin/workspace/my_android_emulator/my_emulator/prebuilts/android-emulator-build/system-images/darwin/platform-tools/adb`
- 模拟器启动脚本：`scripts/run-aosp-fuxi-pkg-selfbuilt-ui.sh`（`NO_WINDOW=0 WIPE_DATA=1 WAIT_FOR_BOOT=0`）
- VM 编译环境：`orb run -m aosp-builder sh -c '...'`
- expand_elf.py：`/Users/robin/OrbStack/aosp-builder/home/robin/expand_elf.py`
- 源码目录：`/home/robin/kernel/xhs_vfs_mod/`（VM 内）
- 产物路径：`/Users/robin/OrbStack/aosp-builder/home/robin/xhs_vfs_*_gki.ko`
- 编译工具链：clang `llvm-r510928`，linux-stable 6.6，KBUILD_MODPOST_WARN=1

---

## 当前未解决问题

**崩溃规律**：`current_euid() 结合条件写 regs[0]` 导致崩溃，但两者单独都稳定，组合则崩溃。

**未测试的下一步**：
1. security_inode_getattr 极简版（只计数，不改 regs）— 判断该函数是否可被 kretprobe
2. `copy_from_kernel_nofault` 安全读取 fn->name
3. hook `__arm64_sys_fstatat64`（syscall 入口）
4. 捕获完整 kernel panic 调用栈（需要串口重定向）
