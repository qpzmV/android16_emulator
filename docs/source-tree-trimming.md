# Source Tree Trimming Notes

这份文档只回答一个问题：

在 `aosp-builder` 里，如果目标只是“还能继续编译 `sdk_phone64_arm64`”，那么当前约 `121G` 的源码工作树里，哪些目录看起来最有机会精简，哪些不建议动。

## 重要前提

这里讨论的是：

- 仅针对源码工作树本身
- 不包括 `out/`
- 不包括 `.repo/`
- 目标是尽量保住：
  - `lunch sdk_phone64_arm64 trunk_staging userdebug`
  - `m`
  - `m emu_img_zip`

也就是说，这不是“如何安全瘦身一个任意 AOSP checkout”，而是“围绕你这次的 emulator 目标，哪些目录最像无关大块”。

## 你当前的体积分布

根据这次在 VM 里的实际盘点：

```text
源码树总量（不含 out，不含 .repo）≈ 121G
```

顶层主要大项：

```text
50G  prebuilts
43G  device
18G  external
2.4G packages
2.3G frameworks
2.0G cts
1.9G kernel
1.2G tools
720M system
```

## 结论先说

如果你的唯一目标是“继续编 `sdk_phone64_arm64`”，最值得优先研究的不是 `frameworks/`、`system/` 这些核心平台目录，而是：

1. `device/google` 这类明显面向大量 Pixel/Google 设备的目录
2. `cts/`、`test/`、`platform_testing/` 这类测试树
3. 一部分大型 `external/` 依赖树
4. 一部分与当前 host/target 不直接相关的 `prebuilts/`

但要非常明确：

- 这份文档是“候选精简清单”
- 不是“无脑删除清单”
- 其中有些目录理论上很可能无关，但实际依赖关系复杂，删之前最好先备份或克隆一份实验树

## 分级说明

### A 级：高概率与当前目标弱相关，可优先研究

这类目录看起来最像“不是 `sdk_phone64_arm64` 主线依赖”，而且体积大。

#### `device/google` — `42G`

建议级别：
- 最值得优先排查

理由：
- 当前构建目标是 `device/generic/goldfish` 路线下的 `emu64a`
- `sdk_phone64_arm64` 的产品定义来自 `device/generic/goldfish/...`
- 而 `device/google` 是海量 Google 设备/Pixel 相关设备树，体积异常大

风险：
- AOSP 里有些通用组件可能被 Google 设备树复用
- 不建议直接在唯一工作树里暴力删

结论：
- 这是全树中最像“大头但与当前 emulator 目标弱相关”的目录

#### `cts` — `2.0G`

建议级别：
- 高概率可去掉，如果你不跑 CTS

理由：
- CTS 是兼容性测试套件
- 你当前目标只是编译并运行 emulator 镜像，不是跑 CTS

风险：
- 如果你后面要做平台测试或交付兼容性验证，就不能删

#### `test` — `358M`

建议级别：
- 高概率可去掉

理由：
- 测试树通常不影响正常平台镜像构建

#### `platform_testing` — `174M`

建议级别：
- 高概率可去掉

理由：
- 偏平台测试与自动化
- 不属于正常 `sdk_phone64_arm64` 镜像主产物链

#### `development` — `390M`

建议级别：
- 较可能可去掉

理由：
- 许多是开发辅助示例/工具/测试资产

风险：
- 某些模块可能引用其中工具或模板，删除前要验证

#### `developers` — `402M`

建议级别：
- 较可能可去掉

理由：
- 大多偏示例、文档、开发者资源

## B 级：有机会精简，但必须验证

这类目录很大，看起来不是每一块都对当前目标必需，但直接删风险比 A 级高。

### `prebuilts` — 总计 `50G`

最值得关注的子项：

```text
14G   prebuilts/clang
12G   prebuilts/rust
5.0G  prebuilts/sdk
3.9G  prebuilts/abi-dumps
2.6G  prebuilts/misc
2.1G  prebuilts/vndk
1.9G  prebuilts/module_sdk
1.8G  prebuilts/android-emulator
1.6G  prebuilts/remoteexecution-client
1.3G  prebuilts/jdk
1002M prebuilts/build-tools
691M  prebuilts/go
```

#### `prebuilts/abi-dumps` — `3.9G`

建议级别：
- 比较有机会精简

理由：
- API/ABI 检查相关
- 如果你只是编译 emulator 镜像，很多时候不是启动路径上的硬依赖

风险：
- 某些 framework API 检查、兼容性检查目标可能用到

#### `prebuilts/sdk` — `5.0G`

建议级别：
- 有机会精简，但风险中等

理由：
- 很大一部分是 SDK 相关历史或发布资产

风险：
- 你这次最后成功运行依赖 `emu_img_zip`
- system image 打包和 SDK 风格产物链可能会间接用到这里的一些内容

#### `prebuilts/android-emulator` — `1.8G`

建议级别：
- Linux VM 内如果你不在 VM 里运行 emulator，可考虑删

理由：
- 你最终是在 macOS 宿主上跑 emulator
- VM 里不一定需要 Linux host emulator 二进制

风险：
- 如果未来想在 VM 里本地跑 emulator 或依赖相关 host 工具，则不能删

#### `prebuilts/remoteexecution-client` — `1.6G`

建议级别：
- 有机会精简

理由：
- 如果你不使用远程执行/远程构建，这块可能是非核心

风险：
- 某些构建环境会静态引用相关工具

#### `prebuilts/clang` — `14G`

建议级别：
- 基本不建议删

理由：
- 这是核心编译器

#### `prebuilts/rust` — `12G`

建议级别：
- 不建议动，除非你做非常细的依赖分析

理由：
- 现代 AOSP 里 Rust 已经不是边缘角色

#### `prebuilts/go` / `prebuilts/build-tools` / `prebuilts/jdk`

建议级别：
- 不建议动

理由：
- 这次能编成功，本身就依赖它们

### `external` — 总计 `18G`

大项包括：

```text
1.8G external/cronet
1.6G external/deqp
1.3G external/swiftshader
1.1G external/google-cloud-java
639M external/chromium-webview
547M external/jackson-databind
428M external/angle
426M external/icu
412M external/vixl
405M external/python
361M external/tensorflow
302M external/mesa3d
238M external/pytorch
```

#### `external/deqp` — `1.6G`

建议级别：
- 比较有机会精简

理由：
- 图形 conformance / 测试方向

风险：
- 如果你后续要做 GLES/Vulkan/CTS/graphics 测试，不适合删

#### `external/google-cloud-java` — `1.1G`

建议级别：
- 有机会精简

理由：
- 看起来不像 `sdk_phone64_arm64` 基本镜像编译主路径的关键依赖

#### `external/tensorflow` — `361M`
#### `external/pytorch` — `238M`
#### `external/executorch` — `117M`

建议级别：
- 有机会精简

理由：
- 对纯 emulator bring-up 来说，看起来不是最核心主线

风险：
- 某些模块或 test build 可能会引用

#### `external/cronet` — `1.8G`
#### `external/chromium-webview` — `639M`

建议级别：
- 有机会精简，但风险不低

理由：
- 体积很大
- 与系统 Web 组件相关

风险：
- WebView / 网络栈是系统功能的一部分
- 直接删很可能影响系统镜像可编译性

#### `external/swiftshader` — `1.3G`
#### `external/angle` — `428M`
#### `external/mesa3d` — `302M`

建议级别：
- 不建议轻易删

理由：
- 你的目标本来就是 emulator
- 图形栈相关目录和 emulator 关系很密切

### `device/linaro` — `779M`
### `device/amlogic` — `102M`
### `device/sample` — `12M`

建议级别：
- 有机会精简

理由：
- 当前目标明确是 `device/generic/goldfish`
- 这些其他 SoC/board 目录通常不是 `emu64a` 直系依赖

风险：
- 有些通用 mk/bp 继承关系可能跨目录存在

## C 级：不建议动

### `device/generic` — `7.6M`

不建议删。

理由：
- 这是这次目标最核心的设备树来源

### `frameworks` — `2.3G`
### `packages` — `2.4G`
### `system` — `720M`
### `build` — `69M`
### `art` — `104M`
### `bionic` — `63M`
### `bootable` — `189M`
### `hardware` — `219M`
### `kernel` — `1.9G`

总体建议：
- 不要把这些当成优先删减对象

理由：
- 它们和平台本身、运行时、系统服务、引导链、HAL、内核相关性很高
- 任何一个删错，都比删 `device/google` 或 `cts` 的破坏性大得多

## 一份更实际的优先级清单

如果你的目标是“在可控风险下试着把 121G 往下压”，建议按这个顺序研究：

1. `device/google` — `42G`
2. `cts` — `2.0G`
3. `test` — `358M`
4. `platform_testing` — `174M`
5. `developers` — `402M`
6. `development` — `390M`
7. `device/linaro` — `779M`
8. `device/amlogic` — `102M`
9. `device/sample` — `12M`
10. `prebuilts/abi-dumps` — `3.9G`
11. `prebuilts/android-emulator` — `1.8G`
12. `prebuilts/remoteexecution-client` — `1.6G`
13. `external/deqp` — `1.6G`
14. `external/google-cloud-java` — `1.1G`
15. `external/tensorflow` / `pytorch` / `executorch`

## 我对“能删到多少”的判断

如果只看“看起来可能与当前目标弱相关”的体积，大头主要在：

- `device/google` — `42G`
- `cts` — `2.0G`
- `prebuilts/abi-dumps` — `3.9G`
- `prebuilts/android-emulator` — `1.8G`
- `prebuilts/remoteexecution-client` — `1.6G`
- `external/deqp` — `1.6G`
- 其他测试/开发树若干

理论上的可精简空间很可观。

但实际能不能都删，要取决于你接受多大风险：

- 保守删法：
  只删测试树和明显不跑的 host 工具
- 激进删法：
  对 `device/google`、大块 `external`、某些 `prebuilts` 动刀

## 最重要的提醒

这份文档不是删除脚本，也不建议你直接按它批量 `rm -rf`。

更稳的做法是：

1. 先克隆一份新的实验工作树
2. 每次只删一类目录
3. 立刻验证：
   - `source build/envsetup.sh`
   - `lunch sdk_phone64_arm64 trunk_staging userdebug`
   - `m -j16`
   - `m emu_img_zip -j16`

只要其中任何一步挂了，就说明这类目录不能简单归为“无关”。

## 总结

如果只围绕 `sdk_phone64_arm64`：

- 最像“无关大头”的是 `device/google`
- 最像“安全边缘精简”的是 `cts/test/platform_testing/developers/development`
- 最值得谨慎验证的，是 `prebuilts/*` 和大型 `external/*`
- 最不该先动的，是 `device/generic`、`frameworks`、`system`、`build`、`art`、`bionic`、`hardware`

如果你愿意，我下一步可以继续基于这份文档，帮你整理出一版“实验性删除顺序清单”，按最小风险一批一批列出建议删除顺序。 
