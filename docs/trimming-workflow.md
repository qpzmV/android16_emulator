# Trimming Workflow

这份文档描述的是本仓库推荐的源码精简实验流程。

目标不是“一次性删到最小”，而是：

1. 每次只移动一批候选目录
2. 保留原始相对路径，确保可恢复
3. 每一批都真实执行构建验证
4. 逐步得到“目前实验上确认可移除”的目录集合

## 原则

不要在源码树里重命名目录来模拟删除。

原因：
- 目录仍然留在源码树中
- AOSP/Soong/Kati 可能仍然扫描到这些目录
- 这样得到的结论不等价于真实删除

正确做法：
- 把目录移到源码树外
- 暂存区保留原始相对路径
- 失败时再恢复回原位

## 目录约定

源码根目录：

```text
/home/robin/aosp/aosp
```

暂存根目录：

```text
/home/robin/aosp/_trim_staging
```

manifest：

```text
/home/robin/aosp/_trim_staging/trim-manifest.log
```

## 使用到的脚本

- `scripts/trim-status.sh`
- `scripts/trim-move-out.sh`
- `scripts/trim-restore.sh`
- `scripts/vm-build-emu64a-package.sh`

## 这次实测后的稳定状态

截至这次实验，下面这组目录已经被真实移出源码树外，并且仍然通过了：

- `lunch sdk_phone64_arm64 trunk_staging userdebug`
- `m -j16`
- `m emu_img_zip -j16`

当前稳定保留在 `_trim_staging/` 的集合大约是 `41.4G`：

```text
developers
device/linaro
device/amlogic
device/google_car
device/google/akita-kernels
device/google/bluejay-kernels
device/google/caimito-kernels
device/google/comet-kernels
device/google/felix-kernels
device/google/lynx-kernels
device/google/pantah-kernels
device/google/raviole-kernels
device/google/shusky-kernels
device/google/tangorpro-kernels
device/google/caimito
device/google/pantah
device/google/tangorpro
device/google/comet
device/google/shusky
device/google/raviole
device/google/akita
device/google/lynx
device/google/felix
device/google/bluejay
device/google/trout
```

注意：
- 这一组是“当前已验证可移走集合”
- 不是“理论猜测”
- 文档里的后续建议都应该以这组结果为起点

另外，这组目录移走后，`ckati` 阶段会打印一些类似下面的噪声：

```text
find: 'device/google/.../overlay/.../values/*': No such file or directory
```

这批 `find` 告警在本次实验里不影响最终通过，因为后续 `m` 和 `m emu_img_zip` 都成功完成并打印了成功标记
`__TRIM_OK__`。

## 标准实验循环

### 1. 先看当前状态

```bash
./scripts/trim-status.sh
```

### 2. 先 dry-run 看看这批目录会移动什么

```bash
./scripts/trim-move-out.sh --dry-run cts test platform_testing
```

### 3. 真正 move out

```bash
./scripts/trim-move-out.sh cts test platform_testing
```

### 4. 立即验证构建

推荐至少验证：

```bash
./scripts/vm-build-emu64a-package.sh
```

这一步应该覆盖：
- `lunch sdk_phone64_arm64 trunk_staging userdebug`
- `m`
- `m emu_img_zip`

### 5. 结果判断

如果构建成功：
- 这批目录暂时保留在 `_trim_staging`
- 进入下一批实验

如果构建失败：
- 先恢复刚刚移动的那一批

```bash
./scripts/trim-restore.sh cts test platform_testing
```

- 然后把这批再拆小，重新试

## 推荐实验顺序

### 第一批：低风险测试树

```text
cts
test
platform_testing
developers
development
```

这次实测结果：

- `developers` 可移走
- `cts` 不能整块移走
- `test` 不能整块移走
- `platform_testing` 不能整块移走
- `development` 不能整块移走

### 第二批：其他设备树

```text
device/linaro
device/amlogic
device/sample
device/google_car
```

这次实测结果：

- `device/linaro` 可移走
- `device/amlogic` 可移走
- `device/google_car` 可移走
- `device/sample` 不能移走

`device/sample` 的直接失败点是：

```text
device/sample/etc/apns-full-conf.xml
```

### 第三批：最大候选

```text
device/google
```

这次实测结果不是“整块移走 `device/google`”，而是拆小以后得到：

- 大量 Pixel kernel 目录可移走
- 多个具体 Pixel 设备目录可移走
- `device/google/cuttlefish`
- `device/google/cuttlefish_vmm`
- `device/google/cuttlefish_prebuilts`

这 3 个 cuttlefish 相关目录都不能整块移走

失败原因分别包括：

```text
"automotive_vsock_proxy" depends on undefined module "cuttlefish_base"
"android.hardware.dumpstate@1.1-service.trout" depends on undefined module "cuttlefish_guest_only"
assemble_cvd requires non-existent HOST module: bootloader_crosvm_aarch64
assemble_cvd requires non-existent HOST module: rewrapper
```

### 第四批：较大但需谨慎验证的 prebuilts / external

示例：

```text
prebuilts/abi-dumps
prebuilts/android-emulator
prebuilts/remoteexecution-client
external/deqp
external/google-cloud-java
```

注意：
- 这一批开始风险明显升高
- 强烈建议一项一项试

这次已经实测过的 prebuilt 结果：

- `prebuilts/android-emulator` 不能整块移走
- `prebuilts/remoteexecution-client` 不能整块移走
- `prebuilts/abi-dumps` 不能整块移走

对应失败线索：

```text
"trusty-host_package" depends on undefined module "trusty_qemu_shared_files"
art/test/... depends on undefined module "rewrapper"
"vts_vndk_abi_dump_zip" depends on undefined module "vndk_abi_dump_zip"
```

## 为什么要分批

因为 AOSP 构建依赖复杂：

- 一次移动太多目录
- 一旦编译失败
- 很难知道真正触发失败的是哪一项

分批移动的好处：
- 失败时定位更快
- 恢复更简单
- 结论更可信

## 如何理解 manifest

`trim-manifest.log` 会记录每次 move out 和 restore：

```text
timestamp    action      relative_path    size
```

它的作用不是替代真实文件状态，而是帮助你追踪实验过程。

真正的“目前可移除集合”仍然应以 `_trim_staging/` 目录中的内容为准。

## 如何得到最终“确认可删”的目录集合

当你完成若干轮实验后：

1. `_trim_staging/` 里仍然保留下来的目录
2. 且在这些目录移出后，`vm-build-emu64a-package.sh` 仍然成功

这两者同时成立，才表示：

> 到目前为止，这些目录在你的目标场景下看起来可以移除

然后你可以再对 `_trim_staging/` 做一次大小统计：

```bash
./scripts/trim-status.sh
```

或直接在 VM 里：

```bash
du -sh /home/robin/aosp/_trim_staging/*
```

## 恢复策略

恢复单个目录：

```bash
./scripts/trim-restore.sh device/google
```

恢复一批目录：

```bash
./scripts/trim-restore.sh cts test platform_testing
```

全部恢复：

```bash
./scripts/trim-restore.sh --all
```

## 推荐实践

- 每次 move out 后立刻构建验证
- 一旦失败，先恢复最近一批，不要继续叠加变量
- 对超大目录如 `device/google`，最好单独验证
- 对 `prebuilts/` 和大型 `external/`，尽量一次只试一个

## 一句话总结

最稳的精简方法不是“猜哪些能删”，而是：

> 把候选目录移出树外，真实编译验证，失败就恢复，成功就继续。

而在这次 `sdk_phone64_arm64` / `emu_img_zip` 目标上，当前已经真实验证拿下的稳定裁剪量大约是：

> `41.4G`
