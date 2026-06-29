# Plan: kprobe 模块 VFS 拦截测试

## 目标
在原版 Google 内核上加载扩展后的 kprobe 模块，拦截 `do_sys_openat2`，
对 app 进程隐藏模拟器文件路径。

## 步骤

### Step 1: 编译 kprobe 模块
- 使用已编译的 `xhs_kp.ko`（含 `do_sys_openat2` + `vfs_statx` 两个 kprobe）
- 或编译新模块仅含 `do_sys_openat2`（减少崩溃风险）

### Step 2: ELF 扩展
- 用已验证的 Python 脚本将 this_module 从 1280B 扩展到 1536B
- 验证 string table 完整性

### Step 3: 部署 + 加载
- `adb push` → `insmod`
- 检查 dmesg 确认 kprobe 注册成功
- 检查 lsmod 确认模块在列

### Step 4: VFS 拦截测试
- 以 app uid 执行 `stat /vendor/bin/qemu-props`
- 预期：ENOENT（文件不存在）
- 以 root uid 执行相同命令
- 预期：正常返回（系统进程不受影响）
- 同样测试 ranchu/goldfish/hwsim 路径

### Step 5: 验证无副作用
- 检查系统稳定性（ADB、UI、已有服务）
- 检查 dmesg 无 kernel panic/oops

## 风险
| 风险 | 概率 | 缓解 |
|---|---|---|
| kprobe 注册失败（符号不匹配） | 中 | dmesg 诊断 |
| kprobe handler 崩溃内核 | 低 | 先只注册 openat，不加 statx |
| 路径匹配逻辑有 bug | 中 | dmesg 加 pr_info 调 |
