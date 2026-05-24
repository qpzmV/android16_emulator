# Full Walkthrough

这份文档按时间顺序，把这次“macOS 上用 OrbStack 和 Rosetta 编译并运行 Android 16 emulator 镜像”的全过程完整记下来。

目标不是只给最终命令，而是把为什么这样做、哪里踩过坑、最后为什么选定 `emu_img_zip` 路线，全都说明白。

## 1. 场景和目标

已知条件：

- 宿主机是 Apple Silicon macOS
- 使用 OrbStack 提供 Linux VM
- VM 名称是 `aosp-builder`
- AOSP 源码在 VM 内：
  `/home/robin/aosp/aosp`
- 源码已经 `repo sync` 成功

目标：

1. 在 `aosp-builder` 里编译最新 AOSP
2. 目标产品使用 `sdk_phone64_arm64`
3. 让 macOS 宿主上的 Android Emulator 最终运行 `emu64a` 镜像

## 2. 为什么编译阶段会遇到 Rosetta 问题

一开始最容易误判的点是：
- 你要编译的是 ARM64 guest 镜像
- 但 AOSP 构建系统的 host 工具链并不等于完全 ARM64 原生

在这次源码树里，构建早期会依赖：
- `prebuilts/go/linux-x86`
- 以及其他 `linux-x86` host prebuilts

而当前 VM 自身是：
- `uname -m = aarch64`

于是如果直接 `source build/envsetup.sh`，构建脚本会尝试找：
- `prebuilts/go/linux-arm64`

但这棵树并没有提供完整对应目录，因此最开始会失败。

### 关键发现

虽然 VM 是 ARM64 Linux，但 OrbStack/Rosetta 允许在这个 VM 里执行 `linux/amd64` host 工具。

也就是说：
- 目标 guest 仍然是 `arm64`
- 但 host prebuilts 可以通过 Rosetta 跑 `linux-x86`

这就是为什么编译阶段需要一个“伪装成 x86_64 host”的小兼容层。

## 3. 编译阶段最终采用的办法

为了让构建链稳定走到 `linux-x86` host prebuilts，这次最终用了两个手段：

1. 在构建 shell 前面插一个临时 `uname` 包装脚本
   让 `uname -m` 返回 `x86_64`
2. 明确设置：
   `GOROOT=/home/robin/aosp/aosp/prebuilts/go/linux-x86`

这样做之后，`lunch` 和 Soong/bootstrap 能顺利通过。

### 成功的 lunch

在当前这版 AOSP 里，`lunch` 不是老式的两段格式，而是：

```bash
lunch sdk_phone64_arm64 trunk_staging userdebug
```

成功后能看到：

- `TARGET_PRODUCT=sdk_phone64_arm64`
- `TARGET_BUILD_VARIANT=userdebug`
- `HOST_OS_EXTRA=...x86_64...`

这里的 `HOST_OS_EXTRA` 带 `x86_64`，说明 host prebuilts 方向已经切对。

## 4. 编译成功后，产物到底在哪里

虽然产品名是 `sdk_phone64_arm64`，但实际产物目录是按设备名落盘：

```text
out/target/product/emu64a
```

里面的典型产物有：

- `kernel-ranchu`
- `ramdisk.img`
- `system.img`
- `vendor.img`
- `system-qemu.img`
- `vendor-qemu.img`
- `userdata.img`
- `vbmeta.img`
- `super.img`
- `vendor_boot.img`

这里很容易混淆：
- `sdk_phone64_arm64` 是产品名
- `emu64a` 是设备目录名

## 5. 第一次尝试为什么没有直接成功

最自然的第一反应通常是：
- 把 `kernel-ranchu`
- `ramdisk.img`
- `system-qemu.img`
- `vendor-qemu.img`
- `userdata.img`

这些文件拉到 macOS，然后直接喂给 emulator。

这个思路在某些历史版本、某些目标上确实能跑，但这次实际验证后，在当前 Android 15 / Baklava `emu64a` 产物上会失败。

### 失败时的真实症状

内核能起来，`init first stage` 也会开始执行，但会卡在：

```text
partition(s) not found after polling timeout: system, vendor
Failed to create devices required for first stage mount
```

这说明问题不是：
- emulator 起不来
- kernel 不对
- adb 配不好

真正的问题是：
- 现代 emulator 启动链需要的动态分区/验证启动相关元信息没有完整被提供

## 6. 为什么改用 `emu_img_zip`

继续硬拼裸镜像不是不可能，但已经偏离 AOSP 官方推荐路线，而且会越来越脆。

这次最后成功的关键转折，是切到：

```bash
m emu_img_zip
```

这个目标会生成：

```text
out/target/product/emu64a/sdk-repo-linux-system-images.zip
```

这个 zip 里并不只是 `system.img` 和 `vendor.img`，还包含：

- `build.prop`
- `advancedFeatures.ini`
- `VerifiedBootParams.textproto`
- `source.properties`
- `data/...`
- `kernel-ranchu`
- `ramdisk.img`

这让 emulator 能更完整地把自己当作一个标准 system image source 来处理，而不是只面对几块孤立的磁盘镜像。

## 7. `emu_img_zip` 是如何生成的

在 VM 内最终成功的流程是：

```bash
source build/envsetup.sh
lunch sdk_phone64_arm64 trunk_staging userdebug
m -j16
m emu_img_zip -j16
```

正式收进脚本后，使用的是：

```bash
./scripts/vm-build-emu64a-package.sh
```

它会自动完成：
- Rosetta/x86_64 host 兼容层
- 普通镜像编译
- `emu_img_zip` 打包
- 日志保存

## 8. macOS 侧为什么还要 AVD

你提到的那篇文章有一个很重要的点：
- 最终是在 Android Emulator 的 AVD 体系内运行，而不是完全绕过 AVD

这点在当前版本仍然成立。

实际经验是：
- 完全裸命令喂镜像，容易和 emulator 当前版本的内部推导逻辑打架
- 放进 AVD system image 路径后，行为更稳定，也更符合 Android Studio / emulator 的默认假设

所以最终采用的是：

1. 准备一个模板 AVD
2. 把 `emu_img_zip` 解出来
3. 让新 AVD 指向这套 packaged system image

## 9. 为什么还额外做了目录兼容处理

理论上，解开的 `arm64-v8a/` 目录已经很标准了。

但这次实际跑的时候发现，当前 emulator 某些解析分支会把：

```text
image.sysdir.1
```

向上看一层，导致它有时把 system path 识别成包根目录，而不是 `arm64-v8a/` 自身。

为了解决这个兼容问题，最终在包根目录补了一层符号链接，把下面这些文件映射到包根：

- `kernel-ranchu`
- `ramdisk.img`
- `system.img`
- `vendor.img`
- `build.prop`
- `source.properties`
- `advancedFeatures.ini`
- `VerifiedBootParams.textproto`
- `data/`

这个处理非常小，但对这次成功启动很关键。

## 10. 最终成功启动时，说明了什么

成功启动时，emulator 日志中能看到：

- `Found systemPath .../sysimg-package/arm64-v8a/`
- 自动注入了更完整的 `androidboot.*` 属性
- `adb` 设备状态转为 `device`

最终验证结果：

```text
product:sdk_phone64_arm64
device:emu64a
sys.boot_completed=1
```

这意味着：
- 不是只起了 kernel
- 不是只跑到了 splash/bootloader
- 是完整 Android userspace 已经启动完成

## 11. 仓库里的脚本应该怎么用

### 只在 VM 里重编和打包

```bash
./scripts/vm-build-emu64a-package.sh
```

适合：
- 你在 VM 里改了 AOSP 代码
- 只想先确认能否成功编译并生成 `emu_img_zip`

### 只在 macOS 上拉包并启动

```bash
./scripts/run-aosp-emu64a-pkg.sh
```

适合：
- VM 已经有新的 `sdk-repo-linux-system-images.zip`
- 你只想更新宿主机的 AVD 并重新启动

### 从宿主机一条命令走完整流程

```bash
./scripts/macos-rebuild-package-and-run.sh
```

适合：
- 你想把“VM 编译打包 + 宿主机更新启动”串成一个入口

## 12. 为什么保留 archive 脚本

仓库里还保留了：

```text
scripts/archive/run-emu64a-avd.sh
```

保留它不是因为还推荐继续用，而是因为它记录了这次排障路径：

- 最早的直觉方案是什么
- 为什么它在这次 Android 15 / Baklava 产物上不稳定
- 最终为什么转向 `emu_img_zip`

从工程记录角度，这份脚本比直接删掉更有价值。

## 13. 最少需要记住的结论

如果以后只记住三件事，记这三件：

1. 在 ARM64 Linux VM 上编这套 AOSP，需要让 host prebuilts 走 `linux-x86`
   这一步靠 Rosetta + `uname`/`GOROOT` 兼容层完成

2. `sdk_phone64_arm64` 的实际产物目录是：
   `out/target/product/emu64a`

3. 在 macOS emulator 上真正稳定成功的方式是：
   `m emu_img_zip` -> AVD 使用 packaged system image

## 14. 推荐的日常工作流

以后如果继续在这套环境里迭代，推荐固定成下面这个习惯：

1. 在 VM 里改代码
2. 执行：
   `./scripts/vm-build-emu64a-package.sh`
3. 回到 macOS 执行：
   `./scripts/run-aosp-emu64a-pkg.sh`

如果你懒得分两步，就直接：

```bash
./scripts/macos-rebuild-package-and-run.sh
```

这样你就不需要每次重新回忆：
- Rosetta host 兼容层怎么配
- `lunch` 要不要带 release
- `emu_img_zip` 的产物名字是什么
- AVD 应该指向哪个目录
- emulator 为什么不能直接吃裸镜像
