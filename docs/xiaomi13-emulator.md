## 会话摘要

**目标：** 修改 AOSP 模拟器以伪装成小米 13（fuxi），用于研究小红书风险控制检测边界。

### 本次修复的问题

1. **运行时 `ro.hardware=taro`**：在 `PropertyInit()` 中，将 `ExportKernelBootProps()` 的执行顺序移到 `PropertyLoadBootDefaults()` 之后（`property_service.cpp:1443-1455`）。由于 `ro.*` 属性是写一次性的，build.prop 的 `ro.hardware=taro` 先写入，内核启动属性的 `ranchu` 赋值被丢弃。

2. **`ro.kernel.qemu=0`**：Goldfish 内核在启动时注入 `ro.kernel.qemu=1`（写一次性），导致 build.prop 的 `ro.kernel.qemu=0` 被静默丢弃。新增 `ForcePropertySet()` 函数，直接调用 `__system_property_update`（绕过 `PropertySet()` 中的 `ro.*` 写一次性检查），强制将 `ro.kernel.qemu` 更新为 `0`。

3. **模拟器启动失败**：`init.rc` 导入了 `init.${ro.hardware}.rc` 和 `vendor/etc/init/hw/init.${ro.hardware}.rc`。当 `ro.hardware=taro` 时，init 尝试加载 `init.taro.rc`（不存在）。创建了桥接文件 `init.taro.rc` → `import /vendor/etc/init/hw/init.ranchu.rc`，确保金鱼草 init 脚本（qemu-props、ranchu-adb-setup）仍能加载。

### 剩余问题
- `ro.build.description` 仍泄露 `fuxi-userdebug ... test-keys`（因 Make 空格分割难以修复）
- `ro.debuggable=1` 和 `ro.build.type=userdebug` 保留以支持 adb root
- 下一步：安装小红书 APK 并测试检测情况

---
$ ADB="/opt/homebrew/share/android-commandlinetools/platform-tools/adb"
SERIAL="emulator-5554"

echo "=== Critical disguise properties ==="
for p in ro.hardware ro.kernel.qemu ro.build.fingerprint ro.build.tags ro.build.type ro.debuggable ro.build.description; do
    printf "  %-35s = %s\n" "[$p]" "$("$ADB" -s "$SERIAL" shell getprop "$p" 2>/dev/null)"
done

echo ""
echo "=== Board/Platform ==="
for p in ro.board.platform ro.hardware.egl ro.hardware.vulkan; do
    printf "  %-35s = %s\n" "[$p]" "$("$ADB" -s "$SERIAL" shell getprop "$p" 2>/dev/null)"
done

echo ""
echo "=== qemu-props ==="
"$ADB" -s "$SERIAL" shell getprop init.svc.qemu-props 2>/dev/null

echo ""
echo "=== shell ==="
"$ADB" -s "$SERIAL" shell whoami 2>/dev/null

=== Critical disguise properties ===
  [ro.hardware]                       = taro
  [ro.kernel.qemu]                    = 0
  [ro.build.fingerprint]              = Xiaomi/fuxi/fuxi:16/BP2A.250605.031.A3/OS3.0.307.0.WMCCNXM:user/release-keys
  [ro.build.tags]                     = release-keys
  [ro.build.type]                     = userdebug
  [ro.debuggable]                     = 1
  [ro.build.description]              = fuxi-userdebug Baklava MAIN eng.robin test-keys

=== Board/Platform ===
  [ro.board.platform]                 = taro
  [ro.hardware.egl]                   = emulation
  [ro.hardware.vulkan]                = ranchu

=== qemu-props ===
running

=== shell ===
shell
你的执行日志里：  [ro.hardware.egl]                   = emulation
  [ro.hardware.vulkan]                = ranchu这两个字段还是能看出是模拟器吧
---


1.我的目标是把编译的aosp镜像运行在模拟器里，并且让
/Users/robin/Downloads/cqnc_472228.apk
/Users/robin/Downloads/duckdetector_461034.apk	
这两个检测器也安装到模拟器里的安卓里，要让检测器无法检测出我是模拟器环境

2.上一个问题让你记住的内容就是目前duckdetector检测出来的问题

3.adb路径：/opt/homebrew/share/android-commandlinetools/platform-tools/adb

4.aosp源码路径：4.1 orb -m aosp-builder 先进入虚拟机 4.2 cd /home/robin/aosp/aosp

5.编译和打包镜像的命令是： 在虚拟机里执行 ./home/robin/aosp/aosp/build_xiaomi.sh

6.本地主机 m5 max 拉取镜像并用模拟器运行的脚本是： /Users/robin/Documents/Codex/2026-05-23/robin-aosp-builder-aosp-aosp-repo/android16_emulator/scripts/run-aosp-fuxi-pkg-selfbuilt-ui.sh

7.前面6点，你要随时记住，然后开始帮我解决1里的目标

