# Phase 1 — 内核魔改完整报告

> **时间**：2026-06-28 ~ 2026-06-29  
> **目标**：在 Android 16 模拟器 (6.6.66-android15) 上实现 VFS 层文件拦截，对 app 进程隐藏模拟器特征路径

---

## 一、代码产出总览

### 1.1 内核源码级补丁（5 个文件）

| 文件 | 功能 | 状态 |
|---|---|---|
| `include/linux/vfs_filter.h` | VFS 路径过滤：对 app(uid>=10000) 的 openat/statx 拦截 ranchu/goldfish/qemu/hwsim/virtio 路径 | ✅ 可编译 |
| `include/linux/proc_filter.h` | /proc/cpuinfo + /proc/modules 伪装：app 读到 Qualcomm SM8550 + 隐藏 goldfish 模块 | ✅ 可编译 |
| `arch/arm64/kvm/cpuid_hook.h` | KVM CPUID 劫持：EL0 MIDR_EL1 返回 Cortex-X3 (0x410FD4E0) | ⚠️ 编译通过但未验证 |
| `fs/open.c`（patch） | 在 `do_sys_openat2()` 入口调用 `vfs_filter_path()` | ✅ 可编译 |
| `fs/stat.c`（patch） | 在 `vfs_statx()` 入口调用 `vfs_filter_path()` | ✅ 可编译 |
| `arch/arm64/kernel/cpuinfo.c`（patch） | 在 `c_show()` 中对 app 返回伪装 CPU 信息 | ✅ 可编译 |
| `kernel/module/procfs.c`（patch） | 在 `m_show()` 中对 app 隐藏 goldfish/hwsim/virtio 模块 | ✅ 可编译 |
| `arch/arm64/kvm/sys_regs.c`（patch） | 在 `access_id_reg()` 中对 app 劫持 CPUID 返回值 | ✅ 可编译 |

### 1.2 编译工具链

| 工具 | 版本 | 来源 |
|---|---|---|
| clang | 18.0.0 (commit `477610d4d`) | 从 `android.googlesource.com/toolchain/llvm-project` `llvm-r510928` 分支**源码编译** |
| LLD | 18.0.0 | 同上，一并编译 |
| 目标架构 | AArch64, ARM, X86, BPF | CMake `LLVM_TARGETS_TO_BUILD` |
| 交叉编译器 | aarch64-linux-gnu-gcc (Ubuntu 11.4.0) | `apt-get install` |

### 1.3 内核编译

| 源码 | 版本 | config | 编译产物 | 结果 |
|---|---|---|---|---|
| `goldfish-6.6` | 6.6.139 (android15) | 原版 ikconfig | 30MB Image + 96 .ko | 自编内核启动不了 |
| `goldfish-6.6` | 6.6.139 (vanilla, 无补丁) | 原版 ikconfig | 30MB Image | 也启动不了（排除补丁问题） |
| `linux-stable` | v6.6.66 (上游) | gki_defconfig+virt | 27MB Image | 启动不了 |
| `linux-stable` | v6.6.66 (上游) | 原版 ikconfig | 27MB Image | 启动不了 |
| `linux-stable` | v6.6.66 (上游) | 原版 ikconfig + clang 18 自编 | 27MB Image | 启动不了 |
| `goldfish-6.6` | 6.6.139 | 原版 ikconfig + Google prebuilt clang r547379 | 32MB Image | 启动不了 |

**关键结论**：**任何**我们编译的内核都无法在模拟器中启动（无论哪个源码树、哪个编译器、有无补丁）。原版 Google 编译的内核（35MB Image）正常启动。根因未完全确定，疑与 Google CI 的编译优化（PGO/BOLT）导致的驱动行为差异有关。

---

## 二、模块加载探索（核心突破点）

由于自编内核始终无法启动，转向**在原版内核上加载 kprobe 模块**的方案。

### 2.1 直接编译模块 → 失败

| 尝试 | 源码 | compiler | config | 结果 |
|---|---|---|---|---|
| 1 | goldfish-6.6 | clang 20 (r547379) | 原版 | `module_layout` size mismatch (1280 vs 1536) |
| 2 | goldfish-6.6 | clang 19 (r530567) | 原版 | 同上 |
| 3 | goldfish-6.6 | clang 18 (自编) | 原版 | 同上 |
| 4 | linux-stable v6.6.66 | clang 18 (自编) | 原版 | 同上 |
| 5 | goldfish-6.6 | clang 18 | +MODULE_SCMVERSION +LOCALVERSION_AUTO +GKI_CRC | 同上 |

**根因**：原版内核的 `struct module` 大小 = 1536 字节；我们编译的任何模块 = 1280 字节。差异 256 字节来自于 Google 内部源码树特有的 `struct module` 字段（Android patch），这些 patch 不在公开的 AOSP 内核源码中。

### 2.2 GKI 预编译模块 → 加载成功 ✅

GKI 预编译模块（`gki-headers/*.ko`）直接 `insmod` 成功，证明 ABI 完美。但无法直接使用（没有 kprobe 功能）。

### 2.3 二进制补丁 → 成功 🎉

#### 2.3.1 ELF this_module 扩展

**核心操作**：将我们编译的模块的 ELF 文件中 `.gnu.linkonce.this_module` section 从 1280 字节扩展到 1536 字节。

**Python 脚本** (`~/kernel/expand_elf.py`)：
1. 解析 ELF header，定位 `this_module` section
2. 在该 section 数据末尾插入 256 字节零值
3. 更新 section header 中的 `sh_size`
4. 更新所有受影响 section 的 `sh_offset`
5. 更新 program headers 的 `p_offset`
6. 更新 `e_shoff`（section header table offset）
7. 验证 string table 的正确性

**关键技术细节**：
- 使用 `bytearray.insert()` 在正确位置插入零字节
- 必须在插入**之前**记录所有 section header 位置
- 插入后**重新计算** `new_e_shoff = old_e_shoff + diff`（如果 shoff > insert_at）
- 确保 section name string table（`.shstrtab`）不被损坏

#### 2.3.2 测试结果

| 步骤 | 测试模块 | 结果 |
|---|---|---|
| 原始模块（1280B） | `xhs_test.ko` | ❌ "section size must match" |
| 扩展模块（1536B） | `xhs_test_final.ko` | ✅ 加载成功 |
| 检查 lsmod | | ✅ `xhs_test 12288 0` |
| 检查 /sys/module/ | | ✅ `initstate = live` |
| rmmod | | ✅ 卸载成功，无崩溃 |
| 重新加载 | | ✅ 再次成功 |
| 系统稳定性 | | ✅ ADB 正常，无 kernel panic |

---

## 三、探索过的死胡同

### 3.1 kprobe 内核模块（独立编译）

编译成功，但始终无法在原版内核上加载。`module_layout` size 不匹配。

### 3.2 代码注入 GKI 壳模块

尝试用 `objcopy --update-section` 替换 GKI 壳模块的 `.text`/`.init.text`/`.exit.text`。模块加载成功但 init 函数崩溃（函数指针 relocation 不匹配）。

### 3.3 eBPF progs

| 方案 | 结果 | 原因 |
|---|---|---|
| kprobe BPF + `bpf_override_return` | ❌ | 内核未启用 `CONFIG_BPF_KPROBE_OVERRIDE` |
| LSM `file_open` BPF | ❌ | `libbpf` 版本过旧（Ubuntu 0.5 vs 内核 6.6），attach 失败 `ENOTSUPP` |
| fentry BPF | ❌ | 同上，`libbpf` 不支持 |
| tracefs kprobe_events | ❌ | 只能 trace，不能拦截 |

### 3.4 全内核编译

所有自编内核（无论配置、编译器、源码版本）都无法在模拟器中启动。跳过了。

### 3.5 全系统构建（AOSP 集成）

将内核补丁放入 AOSP 树，执行完整 `build_xiaomi.sh`。内核被替换为自编版本后同样无法启动。

---

## 四、当前状态（2026-06-29 15:30）

### 4.1 工作内容

```
✅ 内核源码级补丁（VFS/CPU/proc/KVM）        → 可编译
✅ clang 18.0.0 源码编译                       → 与 Google 原版 commit hash 一致
✅ LLD 18.0.0 源码编译                         → 含 ARM/AArch64/X86/BPF 后端
✅ GKI 符号表（1675 个 CRC）                   → 从 96 个预编译模块提取
✅ Module.symvers 格式修复                     → 补全 namespace 字段
✅ ELF this_module 二进制扩展                  → 从 1280B 扩展到 1536B
✅ 测试模块在原版内核加载/卸载                 → 稳定运行，无崩溃
```

### 4.2 未完成 / 待继续

| 事项 | 状态 |
|---|---|
| kprobe 模块（带 VFS 拦截）的原型加载 | ⬜ 下一步 |
| VFS 拦截实际效果验证（stat qemu-props） | ⬜ |
| 风险评分下降验证（Hunter SDK） | ⬜ |

### 4.3 当前阻塞

- 全内核编译启动（不在此路线中，已放弃）
- BPF 方案（不在此路线中，已放弃）
- 代码注入 GKI 壳（不在此路线中，已放弃）

### 4.4 当前路线（二进制补丁）

```
我们编译的模块 .ko
     ↓
ELF 扩展（this_module 1280B → 1536B）
     ↓
insmod 到原版 Google 内核
     ↓
kprobe 注册 → VFS 拦截生效
```

---

## 五、重要文件路径

### Mac 侧
```
~/aosp_xiaomi_xhs_by_pass/android16_emulator/
├── XHS_KERNEL_BYPASS_PLAN.md          # 原始方案文档
├── PHASE1_KERNEL_BYPASS_REPORT.md     # 本报告
├── scripts/
│   ├── run-aosp-fuxi-pkg-selfbuilt-ui.sh  # 模拟器部署脚本
│   └── xhs_login_bypass.sh            # XHS 登录脚本
└── artifacts/fuxi-avd/sysimg-package/arm64-v8a/
    ├── kernel-ranchu                  # 模拟器内核（原版 / 自编）
    └── ramdisk.img                    # 启动 ramdisk

~/aosp_xiaomi_xhs_by_pass/kernel/
├── xhs_vfs_bpf.c                      # BPF 程序（未使用）
├── xhs_bypass_module.c                # kprobe 模块源码
├── vfs_filter.h                       # VFS 路径过滤头文件
├── proc_filter.h                      # /proc 伪装头文件
├── cpuid_hook.h                       # KVM CPUID 劫持头文件
├── expand_elf.py                      # ELF 二进制扩展脚本
└── xhs_test_final.ko                  # ✅ 成功加载的测试模块
```

### VM 侧 (`orb -m aosp-builder`, `/home/robin/`)
```
kernel/
├── goldfish-6.6/                      # Android 内核源码 (6.6.139)
├── linux-stable/                      # 上游 Linux 内核 (v6.6.66)
├── gki-headers/                       # GKI 预编译模块 + kernel-6.6 + System.map
├── llvm-r510928/                      # LLVM/clang 18.0.0 源码
│   └── build/bin/{clang,lld}          # 编译产物
├── Module.symvers.gki                 # 从 GKI 模块提取的符号 CRC（1675 条）
├── orig_config.txt                    # 原版内核 ikconfig（7742 行）
├── orig_kernel.gz                     # 原版内核 Image.gz（14MB）
├── xhs_test66/                        # 测试模块编译
│   └── xhs_test.ko                    # 原始测试模块（1280B this_module）
├── xhs_kp_mod/                        # kprobe 模块编译
│   └── xhs_kp.ko                      # kprobe 模块（1280B）
└── patches/                           # 内核补丁头文件
    ├── vfs_filter.h
    ├── proc_filter.h
    └── cpuid_hook.h
```

---

## 六、模拟器启动成功的配置

- **AVD**: `AOSP_fuxi_pkg`
- **系统镜像**: AOSP 构建 `fuxi-trunk_staging-userdebug`
- **内核**: 原版 Google 编译 `6.6.66-android15-8-gb66429556fb8`（35MB 解压）
- **ramdisk**: AOSP 构建（2MB LZ4 压缩，仅含 init + 设备节点）
- **vendor**: AOSP 构建（95MB，含 96 个 GKI 预编译驱动模块）
- **SELinux**: Enforcing
- **GPU**: host 模式
- **ADB**: root 可用
