# android16_emulator

记录一次在 macOS 宿主上，借助 OrbStack + Rosetta 在 Linux VM 中编译最新 AOSP `sdk_phone64_arm64`，并最终让 Android Emulator 成功运行 `emu64a` 镜像的完整实践。

## 这次验证成功的目标

- 宿主机：macOS on Apple Silicon
- Linux VM：OrbStack `aosp-builder`
- AOSP 目标：`sdk_phone64_arm64 trunk_staging userdebug`
- 实际产物目录：`out/target/product/emu64a`
- 成功运行方式：先生成 `emu_img_zip`，再在 macOS 侧通过 AVD 使用打包后的 system image

## 仓库内容

- [scripts/run-aosp-emu64a-pkg.sh](./scripts/run-aosp-emu64a-pkg.sh)
  macOS 端脚本，拉取 `emu_img_zip`、自建或更新 AVD、启动模拟器
- [scripts/vm-build-emu64a-package.sh](./scripts/vm-build-emu64a-package.sh)
  VM 端脚本，在 `aosp-builder` 中编译并执行 `m emu_img_zip`
- [scripts/macos-rebuild-package-and-run.sh](./scripts/macos-rebuild-package-and-run.sh)
  双端组合脚本，先触发 VM 编译打包，再回到 macOS 侧拉包和启动
- [scripts/archive/run-emu64a-avd.sh](./scripts/archive/run-emu64a-avd.sh)
  早期直接喂裸镜像的尝试，保留做对照参考

## 推荐使用方式

只想复用已经验证成功的整套流程，直接运行：

```bash
cd /Users/robin/Documents/Codex/2026-05-23/robin-aosp-builder-aosp-aosp-repo/android16_emulator
./scripts/macos-rebuild-package-and-run.sh
```

如果 VM 里已经编译并打好 `emu_img_zip`，只想在 macOS 上重新拉包并启动：

```bash
./scripts/run-aosp-emu64a-pkg.sh
```

## 文档导航

- [docs/scripts.md](./docs/scripts.md)
  每个脚本的职责、输入输出、常用参数和推荐场景
- [docs/full-walkthrough.md](./docs/full-walkthrough.md)
  从零开始、从环境检查到最终 `adb` 验证的完整过程说明

## 关键结论

这次最重要的经验不是“编译成功”，而是“启动路径选对”：

- 在 ARM64 Linux VM 里编译最新 AOSP，可以通过 Rosetta 兼容 `linux-x86` host prebuilts
- 对 Android 15 / Baklava 这套 `emu64a` 产物，直接手喂裸 `system/vendor` 镜像在 macOS emulator 上会卡在 first-stage init
- 稳定方案是走 AOSP 官方支持的 `emu_img_zip` 路线，再让 AVD 使用打包后的 system image
