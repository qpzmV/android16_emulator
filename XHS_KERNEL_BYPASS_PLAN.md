# XHS 反检测全栈魔改方案 — 内核到应用层

> **目标**：让小红书 (com.xingin.xhs) 在自编译 AOSP Android 16 模拟器中无法检测出模拟器环境
>
> **策略**：不是绕过检测，而是从底层重新定义"什么是真实手机"

---

## 架构总览

```
┌─────────────────────────────────────────────────────┐
│                XHS APK (Hunter SDK)                  │
│  检测：文件探测 / 属性查询 / syscall / CPUID         │
│        / 硬件信息 / 传感器 / 网络特征                │
│  绕过手段：shadowhook PLT 劫持 → 绕过我们 libc 拦截  │
│             syscall(__NR_openat) 直调内核             │
└─────────────────────┬───────────────────────────────┘
                      │
         ╔════════════╧═══════════════╗
         ║  Phase 1 — 魔改内核       ║
         ║  (goldfish/ranchu kernel) ║
         ╚════════════╤══════════════╝
                      │
┌─────────────────────▼───────────────────────────────┐
│  ① VFS 层路径过滤                                    │
│     openat() / fstatat() / statx() → 检测 ranchu     │
│     /qemu/goldfish/hwsim/virtio → 返回 -ENOENT       │
│                                                      │
│  ② Ghost Mem 分配器                                  │
│     分配物理页但不注册 VMA                            │
│     → /proc/self/maps 完全不可见                      │
│                                                      │
│  ③ R^X Shadow 页                                     │
│     同一虚拟地址两个物理页                            │
│     读页(原始代码) → CRC/MD5 校验通过                │
│     执行页(hook代码) → 实际执行的是我们的逻辑          │
│                                                      │
│  ④ CPUID 劫持                                        │
│     KVM 层拦截 EL0 CPUID 指令                        │
│     MIDR_EL1 → 0x410FD4E0 (Cortex-X3 / Kryo Prime)  │
│                                                      │
│  ⑤ /proc 虚拟文件系统过滤                            │
│     /proc/cpuinfo → Hardware: Qualcomm               │
│     /proc/modules → 过滤 goldfish/ranchu             │
│     /sys/devices/system/cpu/ → Snapdragon 8 Gen2     │
└─────────────────────┬───────────────────────────────┘
                      │
         ╔════════════╧═══════════════╗
         ║  Phase 2 — 魔改 ART      ║
         ║  (libart 编译时植入)      ║
         ╚════════════╤══════════════╝
                      │
┌─────────────────────▼───────────────────────────────┐
│  ① 编译时植入 Hook 引擎                              │
│     · 非运行时注入，编译进 libart.so                   │
│     · 无 /proc/maps 痕迹                              │
│                                                      │
│  ② SystemProperties Hook                             │
│     · 拦截 get()/getInt()/getBoolean()               │
│     · 对 app 进程返回伪造值                            │
│                                                      │
│  ③ 类加载器 Hook                                     │
│     · 监控 XHS 加载的类 (发现检测逻辑)                 │
│     · 可选择性阻止 Hunter SDK 检测模块加载             │
│                                                      │
│  ④ native 库加载拦截                                 │
│     · System.loadLibrary() 拦截                       │
│     · 替换 libshield/libargus/libsentry 为空实现      │
└─────────────────────┬───────────────────────────────┘
                      │
         ╔════════════╧═══════════════╗
         ║  Phase 3 — bionic 增强   ║
         ║  (libc 编译时拦截兜底)    ║
         ╚════════════╤══════════════╝
                      │
┌─────────────────────▼───────────────────────────────┐
│  ① __openat() 拦截                                   │
│     内核 VFS 是主防线，bionic 是兜底                    │
│                                                      │
│  ② __fstatat() + statx() 拦截                        │
│     拦截所有用户态 stat 变体                           │
│                                                      │
│  ③ 属性系统伪装                                      │
│     ✅ pthread_atfork 修复 (已完成)                   │
│     ✅ NQE trace 属性监控                             │
│     · 虚拟 MIUI 属性返回                              │
└─────────────────────┬───────────────────────────────┘
                      │
         ╔════════════╧═══════════════╗
         ║  Phase 4 — HAL 层伪装    ║
         ║  (硬件抽象层)             ║
         ╚════════════╤══════════════╝
                      │
┌─────────────────────▼───────────────────────────────┐
│  ① 传感器 HAL                                        │
│     BOSCH BMI26x 加速度计/陀螺仪                      │
│     ST LSM6DSO 磁力计                                 │
│     AMS TCS3701 光线传感器                            │
│                                                      │
│  ② GPS/GNSS HAL                                      │
│     模拟真实基站/卫星定位数据                          │
│                                                      │
│  ③ GPU / Graphics                                    │
│     ✅ adreno mapper (已完成)                         │
│     · 完整 adreno GPU 属性                            │
└─────────────────────────────────────────────────────┘
```

---

## Phase 1 — 内核魔改详细设计

### 1.1 内核源码获取

```bash
# Android 16 (Baklava) 对应 Android Common Kernel 6.6
# emulator 使用 goldfish 分支

# 方案 A: AOSP manifest
git clone https://android.googlesource.com/kernel/manifest \
  -b android16-6.6

# 方案 B: 直接 clone goldfish 分支
git clone https://android.googlesource.com/kernel/common \
  -b android16-6.6

# 方案 C: GKI 内核（Android 通用内核镜像）
# 下载预编译 GKI + 内核源码
# aosp-main 对应 GKI 6.6
```

### 1.2 内核配置

```bash
cd kernel/
make ARCH=arm64 goldfish_defconfig
# 或
make ARCH=arm64 gki_defconfig

# 启用所需特性
./scripts/config -e CONFIG_KPROBES
./scripts/config -e CONFIG_KALLSYMS
./scripts/config -e CONFIG_KALLSYMS_ALL
./scripts/config -e CONFIG_DEBUG_INFO
./scripts/config -e CONFIG_MODULES
./scripts/config -e CONFIG_MODULE_UNLOAD
```

### 1.3 魔改点

| 文件 | 功能 | 说明 |
|---|---|---|
| `fs/namei.c` | VFS 路径过滤 | openat/fstatat/statx 拦截 |
| `mm/ghost.c` (新) | Ghost Mem 分配器 | 无 VMA 注册的内存分配 |
| `mm/shadow_page.c` (新) | R^X Shadow 页 | 读写分离 |
| `arch/arm64/kvm/sys_regs.c` | CPUID 劫持 | KVM 层拦截 |
| `fs/proc/cpuinfo.c` | /proc 过滤 | 伪装 CPU 信息 |
| `fs/proc/devices.c` | /proc 过滤 | 隐藏模拟器设备 |
| `drivers/base/cpu.c` | sysfs 过滤 | 伪装 CPU 拓扑 |

### 1.4 编译与部署

```bash
# 交叉编译
export CROSS_COMPILE=aarch64-linux-gnu-
export ARCH=arm64
make goldfish_defconfig
make -j$(nproc)

# 替换模拟器内核
# 产物: arch/arm64/boot/Image.gz
# 复制到: ~/aosp_xiaomi_xhs_by_pass/android16_emulator/artifacts/fuxi-avd/sysimg-package/arm64-v8a/
```

---

## 执行路线图

| 阶段 | 内容 | 状态 |
|---|---|---|
| **P0** | bionic pthread_atfork 修复 | ✅ 已提交 |
| **P0** | bionic 属性伪装 | ✅ 已完成 |
| **P1.1** | 获取内核源码 | 🔄 进行中 |
| **P1.2** | VFS 层路径过滤 | ⬜ |
| **P1.3** | Ghost Mem | ⬜ |
| **P1.4** | CPUID 劫持 | ⬜ |
| **P1.5** | /proc + sysfs 过滤 | ⬜ |
| **P1.6** | 编译 + 部署 + 测试 | ⬜ |
| **P2.1** | libart Hook 引擎 | ⬜ |
| **P3.1** | bionic __openat/statx 兜底 | ⬜ |
| **P4.1** | HAL 传感器伪装 | ⬜ |
