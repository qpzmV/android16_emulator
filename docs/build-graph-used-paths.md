# Build Graph Used Paths

这份文档回答的是：

- 对这次已经成功构建过的 `sdk_phone64_arm64`
- 从 `out/soong/*.ninja`、`*.mk` 这些真实构建图反推
- 目前哪些源码目录是“明确出现在构建过程中”的

这能帮助你做一件事：

- 手动清理源码时，优先避开这些“已经在构建图里出现过”的目录
- 优先去研究那些“当前图里没命中”的目录

## 重要边界

这里的“用到”指的是：

- 在本次成功构建后的 Soong/Ninja/Make 产物里，能明确抽取出对应源码路径

它不等于：

- 没出现在图里就 `100%` 可以删
- 出现在图里就代表该目录内每个文件都一定参与了编译

所以这份文档应该这样使用：

1. `图里明确出现过`
   - 先不要碰，或者只做更细粒度实验
2. `当前图里没命中`
   - 可以作为下一轮人工排查重点
3. 真正删除前
   - 仍然建议走 `trim-move-out -> build 验证 -> trim-restore` 的实验流程

## 数据来源

本次统计使用的是 VM 里这 4 个文件：

```text
out/soong/build.sdk_phone64_arm64.ninja
out/soong/Android-sdk_phone64_arm64.mk
out/soong/installs-sdk_phone64_arm64.mk
out/.module_paths/Android.bp.list
```

统计时间对应的是：

- 你已经成功完成过 `sdk_phone64_arm64 trunk_staging userdebug` 构建之后

## 顶层目录结论

结论先说：

- 除了 `.repo/` 和 `out/` 之外，你源码树里几乎所有主要顶层目录都在当前构建图里出现过
- 所以如果目标是继续瘦身，重点已经不是“删哪个顶层目录”，而是“删哪个二级目录”

当前命中统计如下：

```text
  19162  external
   5143  frameworks
   4905  cts
   4346  packages
   3232  prebuilts
   2869  hardware
   2621  system
   1696  art
   1194  build
    929  device
    867  tools
    539  platform_testing
    338  test
    305  development
    108  bootable
     81  bionic
     55  libcore
     38  trusty
     37  kernel
     16  dalvik
     12  sdk
      9  libnativehelper
      8  pdk
      1  toolchain
```

这组数字不是“文件数”，而是从构建图中抽出的有效路径 token 数量。

你可以把它理解为：

- 数字越大，说明这个顶层目录在当前构建图里出现得越频繁

## 二级目录里明确高频命中的大块头

下面这些是当前构建图里非常明确地反复出现的大目录。

它们不是“不能动”，但绝对不适合直接整块删。

```text
external/cronet                 1.8G   5782
external/perfetto               95M    4782
packages/modules                1.3G   3050
external/deqp                   1.6G   2816
cts/hostsidetests               1.2G   2613
hardware/interfaces             108M   2321
frameworks/base                 1.9G   2128
cts/tests                       697M   2042
art/test                        1520   1520
prebuilts/cmake                 60M    1123
external/rust                   334M   1072
frameworks/av                   176M   1024
prebuilts/vndk                  2.1G   987
frameworks/native               49M    952
prebuilts/sdk                   5.0G   823
build/release                   32M    777
device/google                   2.2G   704
system/core                     15M    658
packages/services               274M   632
tools/security                  5.1M   551
packages/apps                   689M   493
external/bc                     7.3M   445
external/OpenCL-CTS             38M    392
system/extras                   446M   382
system/unwinding                67M    353
external/noto-fonts             153M   326
hardware/google                 73M    317
frameworks/proto_logging        3.9M   312
platform_testing/libraries      294    294
external/boringssl              117M   264
frameworks/libs                 113M   234
device/generic                  6.2M   208
platform_testing/tests          205    205
build/soong                     15M    204
build/make                      18M    175
system/tools                    21M    172
development/samples             235M   166
external/llvm                   197M   157
external/libsrtp2               11M    153
packages/providers              81M    145
external/crosvm                 21M    143
tools/asuite                    4.9M   140
external/pigweed                54M    126
test/vts-testcase               49M    126
system/linkerconfig             3.1M   120
```

## 大目录里“明确命中过”的关键结论

### `external/`

当前 `sdk_phone64_arm64` 的构建图对 `external/` 依赖很广，远比直觉上多。

特别是这些大目录，已经明确命中过：

```text
external/cronet            1.8G
external/deqp              1.6G
external/google-cloud-java 1.1G
external/swiftshader       1.3G
external/chromium-webview  639M
external/jackson-databind  547M
external/angle             428M
external/icu               426M
external/python            405M
external/tensorflow        361M
external/rust              334M
external/mesa3d            302M
external/robolectric       167M
external/virglrenderer      78M
external/crosvm             21M
```

其中几个也和你之前的真实裁剪实验吻合：

- `external/google-cloud-java` 不能整块移走
- `external/deqp` 不能整块移走
- `external/robolectric` 不能整块移走
- `external/virglrenderer` 不能整块移走

### `prebuilts/`

`prebuilts/` 是当前源码树里最大的顶级目录，而且命中范围很广。

明确高频命中的大块包括：

```text
prebuilts/clang               14G
prebuilts/rust                12G
prebuilts/sdk                 5.0G
prebuilts/vndk                2.1G
prebuilts/module_sdk          1.9G
prebuilts/jdk                 1.3G
prebuilts/build-tools         1002M
prebuilts/go                  691M
prebuilts/runtime             531M
prebuilts/gcc                 502M
prebuilts/tools               387M
prebuilts/misc                2.6G
prebuilts/cmake                60M
```

所以如果你的目标只是继续保住 `sdk_phone64_arm64` 编译，`prebuilts/` 不能粗暴按顶层删，只能继续往更细粒度切。

### `device/`

虽然你这次的目标产品是 emulator 路线，但 `device/google` 在当前图里仍然明显出现了很多次。

这也和之前的实测一致：

- `device/google` 不能整块移走
- 但其中大量 Pixel 设备目录和 kernel 目录已经被你成功移出并验证通过

当前明确命中的重点是：

```text
device/google   2.2G   704
device/generic  6.2M   208
device/sample   12M     17
```

所以后续对 `device/` 的思路应该是：

- 继续保留 `device/generic`
- 对 `device/google` 只做更细粒度拆分
- `device/sample` 当前不能整块删

### `cts / test / platform_testing / development`

这几个目录虽然看起来像“非镜像主路径”，但当前图里都明确出现了。

而且这也和之前构建失败记录一致：

- `cts` 不能整块移走
- `test` 不能整块移走
- `platform_testing` 不能整块移走
- `development` 不能整块移走

所以如果你还想继续从这些目录里瘦身，必须走“二级甚至三级目录逐个试”的路线。

## 当前图里没命中的较大二级目录

下面这些目录是这次扫描里“当前没看到明确引用”的较大二级目录。

它们不是自动等于“可删”，但很适合作为你下一轮人工排查入口。

```text
external/cldr                        385M
external/autotest                    146M
external/mbedtls                      46M
external/bazelbuild-rules_rust        36M
external/geonames                     24M
external/vulkan-validation-layers     14M
external/bazelbuild-rules_go          14M
external/kernel-headers               10M
prebuilts/ktlint                      64M
prebuilts/checkstyle                  19M
tools/rr_prebuilt                     32M
tools/ndkports                        23M
```

如果你要自己先手工处理，建议优先从这批里挑。

原因很简单：

- 它们在当前 `sdk_phone64_arm64` 构建图里没有被明确命中
- 体积也不算完全可以忽略

## 你现在最值得采用的清理策略

### 第一优先级

只动“当前图里没命中的较大目录”。

这批风险相对最低：

```text
external/cldr
external/autotest
external/mbedtls
prebuilts/ktlint
prebuilts/checkstyle
tools/rr_prebuilt
tools/ndkports
```

### 第二优先级

对已经确认“顶层必须保留”的大树做更细粒度拆分，比如：

```text
external/*
prebuilts/sdk/*
prebuilts/module_sdk/*
device/google/*
cts/*
test/*
platform_testing/*
development/*
```

### 不建议再做的事情

不要再试图按顶层整块删这些目录：

```text
external
prebuilts
frameworks
packages
system
hardware
cts
test
platform_testing
development
device
```

对 `sdk_phone64_arm64` 来说，它们都已经明确在当前图里出现过。

## 建议的手动工作流

如果你要自己手动清理，建议还是按这个顺序：

1. 先看这份文档，挑“没命中的较大目录”
2. 不直接删除，先移出源码树外
3. 跑：

```bash
lunch sdk_phone64_arm64 trunk_staging userdebug
m -j16
m emu_img_zip -j16
```

4. 成功后，再把这一批记为“目前实测可移除”
5. 失败就恢复，再拆更细

## 和已有裁剪文档的关系

配合阅读：

- `docs/source-tree-trimming.md`
- `docs/trimming-workflow.md`

区别是：

- `source-tree-trimming.md` 更偏经验和候选分析
- `trimming-workflow.md` 更偏实验流程
- 本文档更偏“当前真实构建图明确命中过哪些目录”

