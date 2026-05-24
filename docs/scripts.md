# Script Guide

这份文档专门解释仓库里的脚本是干什么的、为什么这样设计，以及应该在什么场景下使用哪一个。

## 脚本总览

### `scripts/vm-build-emu64a-package.sh`

用途：
- 在 OrbStack 的 `aosp-builder` VM 里编译最新 AOSP `sdk_phone64_arm64`
- 额外执行 `m emu_img_zip`
- 产出 `out/target/product/emu64a/sdk-repo-linux-system-images.zip`

为什么需要它：
- 当前这套 AOSP 源码在 ARM64 Linux host 上，部分 host prebuilts 仍然默认走 `linux-x86`
- 这个脚本会临时把构建链切到 `x86_64` 视角，让 Rosetta 去执行 `linux-x86` host prebuilts
- 这是这次成功编译的关键之一

它做了什么：
- 进入 `/home/robin/aosp/aosp`
- 创建一个临时 `uname` shim，让 `uname -m` 返回 `x86_64`
- 设置 `GOROOT` 为 `prebuilts/go/linux-x86`
- `source build/envsetup.sh`
- `lunch sdk_phone64_arm64 trunk_staging userdebug`
- `m -j16`
- `m emu_img_zip -j16`

产出：
- 镜像目录：`/home/robin/aosp/aosp/out/target/product/emu64a`
- 打包产物：`/home/robin/aosp/aosp/out/target/product/emu64a/sdk-repo-linux-system-images.zip`
- 日志目录：`~/aosp-logs`

常用调用：

```bash
./scripts/vm-build-emu64a-package.sh
```

可调参数：
- `AOSP_DIR`
- `TARGET_PRODUCT`
- `TARGET_RELEASE`
- `TARGET_VARIANT`
- `JOBS`
- `LOG_DIR`

### `scripts/run-aosp-emu64a-pkg.sh`

用途：
- 在 macOS 宿主上从 `aosp-builder` 拉 `sdk-repo-linux-system-images.zip`
- 解包成 AVD 可用的 packaged system image
- 更新或创建 `AOSP_emu64a_pkg` AVD
- 启动 emulator 并等待 `sys.boot_completed=1`

为什么它是主脚本：
- 这是最终验证成功的启动方式
- 不再直接依赖裸 `system-qemu.img/vendor-qemu.img`
- 改用 `emu_img_zip` 产物，符合新版本 AOSP/emulator 的实际行为

它做了什么：
- `orb pull` 从 VM 拉 `sdk-repo-linux-system-images.zip`
- 解压到 `artifacts/emu64a-avd/sysimg-package`
- 检查 `arm64-v8a` 目录里是否存在 `kernel-ranchu`、`ramdisk.img`、`system.img`、`vendor.img`
- 在包根目录补符号链接，以兼容本次 emulator 对 `systemPath` 的解析方式
- 直接在 `~/.android/avd/` 下自建 `AOSP_emu64a_pkg`，不依赖任何已有模板 AVD
- 把 `config.ini` 的 `image.sysdir.1` 指向打包后的 `arm64-v8a/`
- 启动 emulator
- 使用 `adb` 等待设备上线并确认 `sys.boot_completed=1`

常用调用：

```bash
./scripts/run-aosp-emu64a-pkg.sh
```

常用参数：
- `WIPE_DATA=0`
  保留已有用户数据启动
- `WAIT_FOR_BOOT=0`
  只启动，不等待开机完成
- `GPU_MODE=host`
  使用宿主 GPU
- `GPU_MODE=swiftshader_indirect`
  使用软件渲染，兼容性更稳

示例：

```bash
WIPE_DATA=0 ./scripts/run-aosp-emu64a-pkg.sh
```

### `scripts/macos-rebuild-package-and-run.sh`

用途：
- 提供一个从 macOS 侧发起的“一条命令跑完整流程”的入口

它做了什么：
- 用 `orb -m aosp-builder -u robin bash ...` 在 VM 中执行 `vm-build-emu64a-package.sh`
- VM 打包完成后，立即执行 `run-aosp-emu64a-pkg.sh`

适用场景：
- 你改了 AOSP 代码，想从宿主机上一条命令触发“重新编译 + 重新打包 + 重新启动”

常用调用：

```bash
./scripts/macos-rebuild-package-and-run.sh
```

### `scripts/archive/run-emu64a-avd.sh`

用途：
- 存档最早的“直接拉裸镜像、直接塞 AVD”的方案

为什么保留：
- 它记录了这次摸索过程中的关键中间阶段
- 对比它和正式脚本，可以清楚看到为什么最后要改用 `emu_img_zip`

为什么不推荐继续用：
- 这条路在本次 Android 15 / Baklava `emu64a` 产物上，会卡在 first-stage init
- 典型症状是：
  `partition(s) not found after polling timeout: system, vendor`

## 脚本之间的关系

### 关系图

1. `vm-build-emu64a-package.sh`
   负责在 Linux VM 中产出官方打包 system image
2. `run-aosp-emu64a-pkg.sh`
   负责在 macOS 上消费这个产物并启动模拟器
3. `macos-rebuild-package-and-run.sh`
   只是把上面两个串起来

## 为什么最终路线是 `emu_img_zip`

这次验证里，脚本设计不是拍脑袋定的，而是被实际日志逼出来的：

- 直接使用 `kernel-ranchu + ramdisk.img + system-qemu.img + vendor-qemu.img`
  能拉起内核，但 `init first stage` 会失败
- 核心错误是找不到动态分区所需的挂载信息，表现为 `system/vendor` 不出现
- `emu_img_zip` 产物里包含了更完整的 emulator 运行元信息
  例如 `build.prop`、`advancedFeatures.ini`、`VerifiedBootParams.textproto`、`data/...`
- 切到 packaged system image 后，emulator 能注入正确的 boot properties，最后成功上线 `adb`

## 你以后最常用的两条命令

只重启宿主机模拟器：

```bash
./scripts/run-aosp-emu64a-pkg.sh
```

从改代码到宿主机重新启动全走一遍：

```bash
./scripts/macos-rebuild-package-and-run.sh
```
