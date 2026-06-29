# kretprobe 崩溃根因分析（2026-06-29）

## 一、背景

在绕过 Hunter SDK 模拟器检测的项目中，我们试图通过内核 kretprobe 模块拦截 `vfs_statx` 系统调用，对特定 app UID（≥10000）隐藏模拟器特征路径（ranchu、goldfish、qemu 等），返回 ENOENT。

ELF patch 方案（expand_elf.py）已经解决了 GKI struct module 大小不匹配问题，基础 kretprobe 框架已验证可用（极简版稳定，19408+ hits/5sec）。

本次会话目标：找到 kretprobe 在添加实际逻辑后反复崩溃的根因。

---

## 二、已确认的前提事实

### 2.1 struct filename 内存布局（tracefs 确认）

通过 tracefs 双重解引用探测：

```
echo 'p:probe_fn3 vfs_statx name=+0(+0(%x1)):string' > /sys/kernel/tracing/kprobe_events
```

输出：
```
probe_fn3: name="/dev/__properties__"
probe_fn3: name="/proc/self/exe"
probe_fn3: name="/system/bin/sh"
```

**结论**：
- GKI 的 `vfs_statx` x1 参数确实是 `struct filename *`
- `fn->name`（offset 0）是有效内核指针
- tracefs 能安全读取该字符串
- GKI 的 struct filename 布局与 linux-stable 6.6 一致（offset 0 = name ptr）

### 2.2 kallsyms 可探测函数

```
T vfs_fstatat
T __arm64_sys_fstatat64
T security_inode_getattr
```

`do_fstatat` 不在 kallsyms（static/inline）。

---

## 三、控制变量实验

通过逐步剥离，精确隔离崩溃触发条件。

### 3.1 实验矩阵

| # | 版本 | data_size | entry_handler | ret_handler | 结果 |
|---|------|-----------|--------------|-------------|------|
| 1 | minimal | 0 | `atomic_inc` | `return 0` | ✅ 稳定 |
| 2 | C | 4 | `*(int*)ri->data = 0` | `return 0` | ✅ 稳定 |
| 3 | D | 0 | `atomic_inc` | `regs[0] = regs[0]`（恒等） | ✅ 稳定 |
| 4 | F | 4 | `current_euid()`（结果废弃）+ `ri->data=0` | `return 0` | ✅ 稳定 |
| 5 | G | 4 | `ri->data=1`（始终） | `regs[0]=0`（始终） | ✅ 稳定 |
| 6 | UID-only | 4 | `current_euid()` + 条件 `ri->data` | 条件 `regs[0]=-ENOENT` | ❌ 崩溃 |
| 7 | E | 4 | `current_euid()` + 条件 `ri->data` | 条件 `regs[0]=0` | ❌ 崩溃 |
| 8 | IS_ERR | 1 | `current_euid()` + `fn->name` + `strstr` | 条件 `regs[0]=-ENOENT` | ❌ 崩溃 |
| 9 | sec | 4 | `current_euid()` + `path->dentry->d_name` | 条件 `regs[0]=-ENOENT` | ❌ 崩溃 |

### 3.2 各实验意义

**实验 2（C 稳定）** → `data_size=4` 本身没有问题，写 `ri->data` 没有问题。

**实验 3（D 稳定）** → 在 ret_handler 中写 `regs->regs[0]` 本身没有问题（恒等写，不改变实际值）。

**实验 4（F 稳定）** → 调用 `current_euid()` 本身没有问题。

**实验 5（G 稳定）** → ret_handler **始终**写 `regs[0]=0`（无条件）没有问题。

**实验 7（E 崩溃）** → 组合了 F 和 G 的功能（current_euid + 条件写 regs），却崩溃。注意：ret 写的是 `0`（非 `-ENOENT`），排除"写错误码"本身的影响。

**实验 9（sec 崩溃）** → 换了完全不同的钩点（security_inode_getattr），访问 `path->dentry->d_name.name`（确定有效的内核指针），结果同样崩溃。

---

## 四、崩溃规律归纳

### 4.1 崩溃充分条件（观察）

所有崩溃版本共同特征：
1. `current_euid()` 检查 app UID
2. **条件性**地写 `regs->regs[0]`（只对 uid >= 10000 的调用写）

### 4.2 排除项

| 假设 | 反例 |
|------|------|
| `fn->name` 内存非法 | tracefs 能安全读出字符串 |
| `data_size != 0` 导致问题 | 版本 C（data_size=4）稳定 |
| `current_euid()` 不安全 | 版本 F（调 current_euid，不写 regs）稳定 |
| 写 `regs[0]` 本身危险 | 版本 D（恒等写）、版本 G（始终写 0）稳定 |
| 只是 `-ENOENT` 数值有问题 | 版本 E（写 0）同样崩溃 |
| `bool` 对齐问题（data_size=1） | 版本 A（改用 int）同样崩溃 |
| 函数选择问题（vfs_statx） | 换 security_inode_getattr 同样崩溃 |
| struct filename 布局不同 | tracefs 确认 offset 0 是 name ptr，与 linux-stable 一致 |

### 4.3 尚未排除的假设

1. **GKI kretprobe 框架的 SCS（Shadow Call Stack）交互问题**：GKI 有 CONFIG_SHADOW_CALL_STACK=y，条件性修改 ret 值时可能与 SCS trampoline 有特殊交互。

2. **CFI（Control Flow Integrity）违规**：GKI 有 CONFIG_CFI_CLANG=y。当 ret_handler 条件性写 regs 时，可能触发某种 CFI 检查失败（路径相关的类型检查？）。

3. **kretprobe 在特定 UID 上下文中的 IRQ 状态问题**：app 进程的 syscall 上下文可能有不同的中断状态，导致 ret_handler 中的内存访问顺序问题。

4. **race condition**：maxactive=64 的实例池在高并发 app stat 调用下耗尽，触发某个 GKI 特有的路径。

5. **实际崩溃是 app 进程崩溃的连锁反应**：强制某个系统关键 app 的 stat 返回不一致值（成功但 kstat 未初始化），导致该 app 以危险方式使用垃圾数据并回调内核。

---

## 五、未能捕获崩溃日志的原因

| 机制 | 原因 |
|------|------|
| `dmesg -w` adb 流 | panic 发生时设备立即掉线，消息来不及传输 |
| `/proc/last_kmsg` | 不存在（设备未配置） |
| `/sys/fs/pstore/` | 无内容（无 ramoops） |
| QEMU verbose log | 只有模拟器框架信息，无内核串口输出 |

**结论**：在当前环境下无法获取完整 kernel panic 调用栈，是诊断的主要障碍。

---

## 六、技术债务与当前状态

### 6.1 已解决
- ✅ expand_elf.py：ELF patch 正确（RELA 偏移 + this_module 大小）
- ✅ 基础 kretprobe 框架在 GKI 6.6 上可用
- ✅ struct filename 内存布局确认，tracefs 可读路径字符串

### 6.2 未解决
- ❌ 带实际拦截逻辑的 kretprobe 稳定加载
- ❌ kernel panic 调用栈捕获
- ❌ Hunter SDK 路径拦截验证

---

## 七、下一步建议（优先级排序）

### 优先级 1：获取 panic 调用栈

只要拿到调用栈，一切都可以解释和修复。

方案：在模拟器启动参数中加入串口重定向：
```bash
# 在启动 QEMU 时添加
-serial file:/tmp/qemu_serial.log
```
或者使用 QEMU monitor（telnet）监控串口输出。panic 消息会先写到串口，再写 dmesg。

### 优先级 2：测试 security_inode_getattr 极简版

只做 atomic_inc，不访问任何参数，不改 regs：

```c
static int sec_entry(struct kretprobe_instance *ri, struct pt_regs *regs)
{
    atomic_inc(&cnt);
    return 0;
}
static int sec_ret(struct kretprobe_instance *ri, struct pt_regs *regs)
{
    return 0;
}
```

如果稳定 → security_inode_getattr 的 kretprobe 基础设施可用，问题在参数访问或 regs 修改。

### 优先级 3：使用 copy_from_kernel_nofault 替代直接解引用

```c
const char *name_ptr = NULL;
if (copy_from_kernel_nofault(&name_ptr, (void *)fn_addr, sizeof(name_ptr)) != 0)
    return 0;
```

tracefs 内部使用类似机制安全读取内核内存，避免直接解引用导致的任何潜在 fault。

### 优先级 4：尝试纯 kprobe（pre_handler）方案

放弃 kretprobe，改用 kprobe pre_handler 拦截函数入口。在 ARM64 上，pre_handler 无法直接修改返回值，但可以通过修改函数的输入参数（如 dfd、filename 指针）或者使用 jprobe-like 机制达到绕过效果。

### 优先级 5：eBPF 方案

检查 GKI 是否支持 eBPF kfunc/kprobe：

```bash
ls /sys/fs/bpf/
cat /proc/config.gz | gunzip | grep BPF
```

若支持，用 BPF LSM hook `security_inode_getattr` 是最干净的方案（内核有专门的 BPF hook 支持，无 ELF patch 需求）。

---

## 八、关键文件索引

| 文件/路径 | 说明 |
|-----------|------|
| `/Users/robin/OrbStack/aosp-builder/home/robin/expand_elf.py` | ELF patch 脚本 |
| `/home/robin/kernel/xhs_vfs_mod/` (VM) | 各版本源码目录 |
| `/Users/robin/OrbStack/aosp-builder/home/robin/xhs_*_gki.ko` | 各版本 patch 后的 ko |
| `docs/session-260629-vfs-kretprobe-debug-dump.md` | 本次会话原始 dump |
| `PLAN_VFS_KPROBE_TEST.md` | 原始计划文档 |
| `/tmp/dmesg_vfs_crash.txt`，`/tmp/dmesg_v2.txt` | 崩溃前 dmesg 捕获（无 panic 消息） |
