# XHS 登录风控绕过 Plan

> 当前状态（2026-06-24）：NQE score 正常（83-93），CPU 频率伪造生效，
> 但登录依然失败"login failed, please try again later"。
> 登录 API 走原生 C++ HTTP（libxyhttpdns.so），logcat 看不到请求内容和 errCode。

---

## 问题一：model_portrait/model_score POST 被 Canceled

### 现象
XHS 启动时向 `modelportrait.xiaohongshu.com/api/model_portrait/model_score` 发 POST，
但每次都被 XHS 自己取消（`java.io.IOException: Canceled`），服务端未收到最新 CPU 评分。
若服务端无最新评分，则沿用旧的（可能含模拟器特征的）历史画像。

### 根因
该请求在 `LoginDelaySplashActivity.onCreate` 期间发出，但 Activity 在 POST 响应回来前
就因页面跳转被销毁，导致关联的 OkHttp Call 被 cancel。

### 解决方案
**方案 A（推荐）：让请求不绑定 Activity 生命周期**
在 AOSP 的 open.cpp 里无法干预 Java 层 OkHttp Call 的取消逻辑。
但可以在 `nqe_props.txt` 里记录到 XHS 读取的 property，确认 model_score 是否影响登录。

**方案 B：Frida hook model_portrait POST**
用 Frida hook OkHttp `RealCall.cancel()`，使 model_score 请求不被取消，
观察服务端评分结果是否影响登录通过率。

**方案 C（观察是否真的影响）**
`detect_items` 已返回 `{"model_portrait_created":true,"items":[]}`，
说明服务端已有该设备的画像且不需要额外检测。
model_score 被 Canceled 可能对登录影响有限，先解决 OAID 和 MAC 再验证。

---

## 问题二：登录 API 走 libxyhttpdns.so，看不到 errCode

### 现象
SMS 验证码登录请求（passport API）不经过 OkHttp logger，
logcat 里看不到请求 URL、参数、响应 body 和 errCode。

### 根因
XHS 的 `libxyhttpdns.so` 是自研 Native HTTP 客户端，
绕过了 OkHttp 的 logging interceptor，直接在 C++ 层发 HTTPS 请求。

### 解决方案
**方案 A：在 bionic 层插桩（推荐）**
在 `NetdClientDispatch.cpp` 的 `connect()` 里已有 nqe_net.txt 记录，
进一步在 `write()` / `send()` 系统调用层面记录 TLS 握手后的数据，
但 TLS 加密后无法直接读内容。

**方案 B：Frida hook SSL_write / SSL_read（最有效）**
```
frida -U -n com.xingin.xhs \
  --eval 'Interceptor.attach(Module.findExportByName("libssl.so","SSL_write"), {
    onEnter(args) { console.log(args[1].readCString(args[2].toInt32())); }
  })'
```
可以直接看到 TLS 层发出的明文 HTTP 请求和收到的响应，拿到 errCode。

**方案 C：mitmproxy + 证书固定绕过**
1. 在模拟器上安装 mitmproxy 的 CA 证书
2. Frida hook `X509TrustManager` 绕过证书固定
3. 所有 HTTPS 流量解密可见

> **行动项**：先用方案 B（Frida SSL_write hook）确认服务端实际返回的 errCode，
> 再针对性地修复。

---

## 问题三：OAID 不可用（最高优先级）

### 现象
```
OAIDSDK: [MainMdidSdk] initResult: infoCode:1008610
ClassNotFoundException: com.android.id.impl.IdProviderImpl
```
OAID（Open Anonymous Device Identifier）是国内手机厂商联盟的设备唯一标识。
所有真实小米手机都有 OAID，没有时服务端将设备归为高风险/模拟器。

### 根因
OAID 由各厂商的系统 ROM 提供（小米通过 `com.android.id.impl.IdProviderImpl` 这个系统类），
AOSP 标准构建不包含该类，MSA SDK 初始化失败。

### 解决方案
**方案 A：在 AOSP 里实现假的 IdProviderImpl（推荐）**
在 AOSP framework 里添加 `com.android.id.impl.IdProviderImpl` 空实现，
返回一个固定的合法格式 OAID（32位十六进制，类似 UUID 去掉横线）：

```java
// frameworks/base/core/java/com/android/id/impl/IdProviderImpl.java
package com.android.id.impl;
import android.content.Context;
public class IdProviderImpl {
    // 固定的假 OAID，格式与真实小米 OAID 相同
    public String getOAID(Context context) {
        return "a1b2c3d4e5f6789012345678901234ab";
    }
}
```
需要在 framework 的 Android.mk 里注册并打包到系统。

**方案 B：Frida hook MSA SDK**
Hook `com.bun.miitmdid.provider.IdProviderImpl.getOAID()` 返回固定字符串，
无需修改 AOSP，但每次启动 XHS 都要 attach Frida。

**方案 C：提供 ContentProvider（更接近真实）**
在 AOSP 里实现一个 ContentProvider，注册为 `com.android.id`，
MSA SDK 通过 `context.getContentResolver().query("content://com.android.id/getOAID")` 获取 OAID。
这是真实小米手机的实现方式，兼容性最好。

> **行动项**：优先实现方案 A，快速验证 OAID 是否是导致登录失败的关键因素。

---

## 问题四：WiFi MAC 地址是模拟器特征

### 现象
```
MAC: 02:15:b2:00:00:00
```
第一个字节 `02` 的 bit1=1，表示 locally-administered（本地管理），
真实手机的 WiFi MAC 是全球唯一（bit1=0，厂商分配）。
XHS 通过 `/sys/class/net/wlan0/address` 或 WiFi API 读取 MAC。

### 解决方案
**方案 A：在 open.cpp 里拦截 MAC 地址文件（推荐）**
```cpp
// 在 open() 的 getuid()>=10000 拦截块里添加：
if (strstr(pathname, "/net/wlan0/address") != nullptr ||
    strstr(pathname, "/net/eth0/address") != nullptr) {
  int pfd[2];
  if (pipe(pfd) == 0) {
    // 小米 fuxi 真实 MAC 格式，globally-administered
    const char* fake_mac = "ac:d6:18:5a:3b:7f\n";
    write(pfd[1], fake_mac, strlen(fake_mac));
    close(pfd[1]);
    return FDTRACK_CREATE(pfd[0]);
  }
}
```

**方案 B：拦截 Android WifiInfo API**
XHS 也可能通过 `WifiManager.getConnectionInfo().getMacAddress()` 获取 MAC，
这个 API 在 Android 10+ 已经对 app 屏蔽，但 XHS 可能通过反射或 native 读取。
如果 open.cpp 拦截后仍有问题，再考虑 Java 层 hook。

> **注意**：MAC 地址用固定值（不要全零，不要 02: 开头，要用合法的 ac/d4/c0 等厂商前缀）。

---

## 问题五：WiFi SSID 显示 unknown

### 现象
```
SSID: <unknown ssid>
BSSID: 02:00:00:00:00:00
```
模拟器没有真实 WiFi AP 连接，SSID 为空。

### 解决方案
**方案 A：伪造 WiFi 信息（AOSP WifiManager 层）**
修改 `frameworks/opt/net/wifi` 里的 `WifiInfo`，让模拟器上的 SSID 返回固定字符串。
这需要修改系统 framework，影响范围较大。

**方案 B：Frida hook WifiInfo.getSSID()**
```javascript
Java.perform(() => {
  const WifiInfo = Java.use('android.net.wifi.WifiInfo');
  WifiInfo.getSSID.implementation = function() { return '"HomeWiFi"'; };
  WifiInfo.getBSSID.implementation = function() { return 'ac:d6:18:5a:3b:7e'; };
});
```
影响范围小，验证成本低。

> **优先级**：SSID 是次要特征，先解决 OAID 和 MAC 后再处理。

---

## 执行优先级

```
P0 - OAID 伪造（方案A：framework添加IdProviderImpl）
P1 - MAC 地址伪造（open.cpp 拦截 wlan0/address）
P2 - Frida SSL_write hook 拿到登录 errCode（用于确认风控原因）
P3 - model_portrait POST Canceled 问题（确认是否影响登录）
P4 - SSID/BSSID 伪造
```

## 验证方法

每次修改后：
```bash
./build_xiaomi.sh
bash scripts/run-aosp-fuxi-pkg-selfbuilt-ui.sh
bash scripts/xhs_login_bypass.sh
# 然后尝试登录，观察是否通过
```

## 当前已解决

- [x] Hunter 6.52 全部检测项通过（绿色笑脸）
- [x] XHS 启动不卡在 splash screen（stat.cpp errno 修复）
- [x] NQE score 从 33 提升到 83-93（xt_qtaguid/stats 伪造）
- [x] CPU 频率正常上报（1804800/2803200 kHz）
- [x] qemu-props / libqemupipe stat 返回 ENOENT
- [x] errno 污染修复（open/stat/connect 全系列）
