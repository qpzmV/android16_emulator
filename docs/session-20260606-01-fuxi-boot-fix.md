# 会话 2026-06-06: 修复 fuxi 模拟器启动 & Build.prop 伪装

## 摘要

修复了 `fuxi`（小米 13）AOSP 模拟器系统镜像，使其能在 Android 模拟器中正常启动，并带有正确的小米 13 build.prop 伪装。

**启动失败根因：** `device/xiaomi/fuxi/` 中的两个 Bug：

1. `device.mk` 用了 `PRODUCT_PROPERTY_OVERRIDES +=` —— 基础产品 `sdk_phone64_arm64`
   在继承后用 `:=` 重置了这个列表，导致所有覆盖被**静默丢弃**。改为 `PRODUCT_SYSTEM_PROPERTIES`（加法式，不会被重置）。
2. `device.mk` 设置了 `ro.hardware=taro` / `ro.hardware.egl=adreno` / `ro.hardware.vulkan=adreno`。
   模拟器系统镜像只有 `ranchu` 前缀的 HAL 模块（gralloc.ranchu.so、hwcomposer.ranchu.so 等）。
   设置 `ro.hardware=taro` 后，init 尝试加载 `gralloc.taro.so` 等不存在的 HAL → HAL 服务失败 →
   启动挂起（约 74 秒后客户机触发关机）。

**修复的次要问题：**
- `BoardConfig.mk` 设置了小米 13 平台的 `BOARD_KERNEL_CMDLINE`；模拟器构建忽略此变量
  （b/361341981），但代码有误导性。
- `PRODUCT_BUILD_PROP_OVERRIDES` 中的 `TARGET_BUILD_TYPE=user` 对 `ro.build.type` 无效果
  但造成困惑。
- `ro.product.locale=zh-CN` 与基础产品的 `en-US` 冲突 → 构建错误。
- `run-aosp-fuxi-pkg-selfbuilt-ui.sh` 使用 `orb pull` 失败，因为 OrbStack 的
  `/containers/ro/` 路径是只读快照；改为直接从共享文件夹 `cp`。

---

## 问答

### 初始问题：模拟器启动了但没有 UI

**用户：** 运行了 `run-aosp-emu64a-pkg-selfbuilt-ui.sh` —— adb 显示 "Device online:
emulator-5554" 但没有 UI。

**排查：** 用户构建的是 `fuxi` 产品（不是 `emu64a`），但运行了 `emu64a` 的启动脚本，
该脚本查找 `out/target/product/emu64a/sdk-repo-linux-system-images.zip`。
fuxi 构建输出在 `out/target/product/fuxi/`。修复方法：改用 fuxi 启动脚本。

### 从 OrbStack 容器复制文件失败

**问题：** `orb pull -m aosp-builder aosp/aosp/out/... .` 失败：
```
lstat /containers/ro/aosp-builder/home/robin/aosp/aosp/out/... : no such file
```
**根因：** `orb pull` 访问容器原始磁盘镜像路径 `/containers/ro/`，
这是一个**只读快照**，可能不反映最近的文件更改。实际文件存在于共享文件夹
`~/OrbStack/<machine>/home/robin/...` 中。

**修复：** 将 `orb pull` 替换为直接 `cp "$HOME/OrbStack/$ORB_MACHINE/home/robin/$VM_ZIP_PATH" .`

### 模拟器启动后约 20 秒自动关闭

**问题：** 模拟器启动、配置显示器，然后立即显示
"Wait for emulator...20 seconds to shutdown gracefully before kill" 并退出。

**根因：** 模拟器本身没有崩溃——是 **Android 客户机**触发了关机。
因为 `ro.hardware=taro` 导致 init 无法加载 HAL 模块，init 崩溃后客户机自动关机。

**修复：** 从 `device.mk` 中删除 `ro.hardware=taro`、`ro.hardware.egl=adreno`、
`ro.hardware.vulkan=adreno` —— 模拟器的 `ranchu` HAL 与这些值不兼容。

### 模拟器保持运行但 adb 从不显示 "device"

**问题：** 修复 ro.hardware 后，模拟器保持运行 10 分钟以上，
但 adb 保持 "offline" —— 客户机从未完成启动。

**根因：** device.mk 中的 `PRODUCT_PROPERTY_OVERRIDES +=` 被构建系统**静默丢弃**。
基础产品 `sdk_phone64_arm64.mk`（通过其父链）使用了 `PRODUCT_PROPERTY_OVERRIDES :=`
**重置**了该变量，清除了 device.mk 的所有 `+=` 添加。
大多数覆盖（ro.sf.lcd_density、ro.board.platform、MIUI 属性等）从未进入 build.prop。

**修复：** 将所有 `PRODUCT_PROPERTY_OVERRIDES +=` 改为 `PRODUCT_SYSTEM_PROPERTIES +=`，
这是安全的加法操作，永远不会被重置。

### `ro.product.locale=zh-CN` 导致构建失败

**错误：**
```
error: found duplicate sysprop assignments:
ro.product.locale=en-US
ro.product.locale=zh-CN
```

**修复：** 删除了 locale 覆盖 —— 基础产品已设置 `en-US`，
构建系统禁止同一个键的重复 sysprop 赋值。

### 为什么 `adb root` 失败

**问题：** `adb root` 返回 "Device must be bootloader unlocked"
**原因：** `ro.secure=1`（由构建系统为 userdebug 变体设置）阻止了 `adb root`。
但 `adb shell` 仍然提供 root shell（uid=0）。

---

## 执行的脚本及输出

### 1. build_xiaomi.sh（在 OrbStack 容器内）

```bash
AOSP_DIR=/home/robin/aosp/aosp
TARGET_PRODUCT=fuxi
TARGET_RELEASE=trunk_staging
TARGET_VARIANT=userdebug
JOBS=16

# 伪造 uname 返回 x86_64，让 envsetup.mk 选择 x86 工具链
cat > /tmp/uname <<'EOF'
#!/bin/sh
[ "$1" = "-m" ] && echo x86_64 && exit 0
[ "$1" = "-sm" -o "$1" = "-ms" ] && echo "Linux x86_64" && exit 0
exec /usr/bin/uname "$@"
EOF

export PATH=/tmp:$PATH
cd $AOSP_DIR
source build/envsetup.sh
lunch fuxi trunk_staging userdebug
m -j16
m emu_img_zip -j16
```

输出：构建成功完成（增量更改约 6 分钟，完整构建约 2-3 小时）。
最终产物：`out/target/product/fuxi/sdk-repo-linux-system-images.zip`

### 2. run-aosp-fuxi-pkg-selfbuilt-ui.sh（在 macOS 上）

```bash
# 关键行（修复后）：
ORB_MACHINE=aosp-builder
VM_ZIP_PATH=aosp/aosp/out/target/product/fuxi/sdk-repo-linux-system-images.zip
WORK_DIR=$REPO_ROOT/artifacts/fuxi-avd

# 从共享文件夹复制而非 orb pull：
cp "$HOME/OrbStack/$ORB_MACHINE/home/robin/$VM_ZIP_PATH" .

# 解压、创建 AVD、用 -no-snapshot -gpu host -memory 4096 启动
# 等待 adb 设备，等待 sys.boot_completed=1
```

### 3. 模拟器验证命令

```bash
adb -s emulator-5554 shell getprop ro.build.fingerprint
# → Xiaomi/fuxi/fuxi:16/BP2A.250605.031.A3/OS3.0.307.0.WMCCNXM:user/release-keys

adb -s emulator-5554 shell getprop ro.product.model
# → 2211133C

adb -s emulator-5554 shell getprop ro.build.tags
# → release-keys

adb -s emulator-5554 shell getprop ro.hardware
# → ranchu

adb -s emulator-5554 shell getprop ro.sf.lcd_density
# → 440

adb -s emulator-5554 shell wm size
# → Physical size: 1080x2400
```

---

## 创建/修改的文件

### device/xiaomi/fuxi/BoardConfig.mk
- 删除了 `BOARD_KERNEL_CMDLINE` 覆盖（对模拟器无效；有误导性）
- 添加注释说明其不受支持

### device/xiaomi/fuxi/device.mk
- `PRODUCT_PROPERTY_OVERRIDES +=` → `PRODUCT_SYSTEM_PROPERTIES +=`
- 删除了 `ro.hardware=taro`、`ro.hardware.egl=adreno`、`ro.hardware.vulkan=adreno`
- 从 `PRODUCT_BUILD_PROP_OVERRIDES` 中删除了 `TARGET_BUILD_TYPE=user`
- 删除了 `ro.secure=1`、`ro.adb.secure=1`、`ro.debuggable=0`、`ro.allow.mock.location=0`
  （通过 PRODUCT_PROPERTY_OVERRIDES 设置不起作用；保留 userdebug 默认值）
- 删除了 `ro.product.locale=zh-CN`（重复赋值构建错误）
- 删除了 Dalvik 堆覆盖（PRODUCT_SYSTEM_PROPERTIES 也可能有重复）

### run-aosp-fuxi-pkg-selfbuilt-ui.sh
- `orb pull -m` → 从共享文件夹路径 `cp`

---

## 关键发现

### AOSP 中 Build.prop 覆盖机制

| 机制 | 行为 | 对 fuxi 有效？ |
|------|------|----------------|
| `PRODUCT_BUILD_PROP_OVERRIDES :=` | 设置特定的构建时变量（BUILD_FINGERPRINT 等） | ✅ Fingerprint 有效 |
| `PRODUCT_SYSTEM_PROPERTIES +=` | 添加到 /system/build.prop，永不重置 | ✅ 所有覆盖生效 |
| `PRODUCT_PROPERTY_OVERRIDES +=` | 添加到列表，但基础产品可能用 `:=` 重置 | ❌ 所有值被丢弃 |
| `PRODUCT_{BRAND,NAME,MODEL,DEVICE,MANUFACTURER}` | 自动生成 build.prop 条目 | ✅ |

### ro.build.description 限制
`PRODUCT_BUILD_PROP_OVERRIDES` 中的 `PRIVATE_BUILD_DESC` 不能包含空格，
因为 Makefile 按空格分割。描述始终显示自动生成的值，包含 `userdebug` 和 `test-keys`。

### 仍存在的模拟器检测泄露
- `ro.kernel.qemu=1` —— 由模拟器内核 cmdline 在运行时注入
- `qemu-props`、`ranchu-*`、`goldfish-*` 服务在 `init.svc.*` 属性中可见
- 要隐藏这些，需要修改 Android init 源代码来屏蔽或更改这些值

---

## 后续步骤

1. **修复 ro.build.description** —— 编辑 build/make/core/sysprop.mk 或添加
   后处理脚本来从描述中去除 `userdebug/test-keys`。
2. **隐藏 ro.kernel.qemu** —— 修改 `system/core/init/property_service.cpp`
   来检查模拟器并跳过设置此属性，或重命名它。
3. **测试小红书 APK** —— 安装真实应用并检查它是否能运行、检测到什么内容。
