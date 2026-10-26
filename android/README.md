# CarSentinel 360 · Android 车机端

Camera2 采集 → MediaCodec H.264 硬编 → 自研 TCP/UDP 服务器 → Compose 状态页。
协议契约以 `docs/PROTOCOL.md` 为准，本目录只负责实现。

## 目录

```
android/
├─ settings.gradle.kts / build.gradle.kts / gradle.properties
├─ app/build.gradle.kts
├─ app/proguard-rules.pro
└─ app/src/main/
   ├─ AndroidManifest.xml
   ├─ java/com/carsentinel/carunit/
   │  ├─ MainActivity.kt              底部两个 tab 的壳（无 Navigation 库）
   │  ├─ CarSentinelApp.kt            Application
   │  ├─ service/StreamService.kt      前台服务，持有全部推流组件
   │  ├─ service/ServiceController.kt  UI ↔ Service 薄壳（StateFlow）
   │  ├─ net/Protocol.kt               端口/魔数/帧格式/共享类型/日志总线
   │  ├─ net/Json.kt                   手写 JSON（扁平对象 + 一层对象数组）
   │  ├─ net/Announcer.kt              UDP 45677 广播 + 45676 DISCOVER 应答
   │  ├─ net/StreamServer.kt           TCP 45678 accept 循环 + 首字节分流
   │  ├─ net/ControlSession.kt         JSON Lines 控制通道，15s 空闲断开
   │  ├─ net/VideoSession.kt           SUBSCRIBE 握手 + 有界丢帧写循环
   │  ├─ camera/CameraHub.kt           枚举 + 位置映射 + 并发打开
   │  ├─ camera/CameraFeeder.kt        一个 Camera2 设备 → 一个编码输入面
   │  ├─ codec/H264Encoder.kt          Surface 输入 H.264 编码器
   │  └─ ui/theme/Theme.kt             Aurora 设计 token（AuroraTheme → CarSentinelTheme）
   │     ui/common/Common.kt            Aurora 组件（含 GradientButton / QuietButton）
   │     ui/StatusScreen.kt
   │     └─ ui/LogScreen.kt
   └─ res/values/{strings,themes,ic_launcher_background}.xml
      res/mipmap-anydpi-v26/ic_launcher.xml
      res/drawable/{ic_launcher_foreground,ic_stat_shield}.xml
```

## 摄像头 → 位置映射

`CameraManager.cameraIdList` 按枚举顺序分配协议 id `0,1,2,…`（重启后同一台机器稳定）。
`CameraCharacteristics.LENS_FACING` 决定 `pos`：

| LENS_FACING | pos | 名字 |
| --- | --- | --- |
| `FRONT` | `front` | 前视 |
| `BACK` | `rear` | 后视 |
| `EXTERNAL` | `left` / `right` / `inner` 轮转 | 左视 / 右视 / 内视 |
| 其他 | `unknown` | 摄像头 N |

外置摄像头用 `abs(cameraId.hashCode()) % 3` 决定轮转槽位，**不用枚举下标**：
旁边那路掉线时下标会漂移，哈希不会。同一台机器重启结果一致。

并发打开：`openCamera` 本身异步，连续调用即并发。任何一路
`CameraAccessException` / `StateCallback.onError` / `onDisconnected` 只把该路标成
unavailable 并从 `announce.cameras` 里移除，不影响其他路，也不阻断启动。

## 关键实现取舍

- **Camera2，不用 CameraX**：要精确控制 `StreamConfigurationMap` 选尺寸、
  `TEMPLATE_RECORD`、以及一路一个编码输入面的拓扑。
- **不用 Navigation / ViewModel / Retrofit / OkHttp / Ktor / Netty**：
  一个 tab 开关足够，网络层用 `java.net`（`ServerSocket` / `DatagramSocket`）就够，
  省掉一堆传递依赖，APK 更小。
- **不用 androidx.camera 也不用 kotlinx.serialization**：JSON 是扁平对象 + 一层数组，
  手写 ~250 行比引入一个代码生成插件更可控，也让 `publish` 顺序肉眼可读。
- **SPS/PPS 不当帧发**：`BUFFER_FLAG_CODEC_CONFIG` 只进缓存，
  `BUFFER_FLAG_KEY_FRAME` 时与 IDR 拼成**一帧**（`00 00 00 01` 前缀），满足 §5.3。
- **每视频会话一个 2 帧有界队列，满则丢最旧**：`offer()` 永不阻塞，
  编码线程永远不被慢手机拖住。
- **`PrefixedSocket`**：为了「读一个首字节后不改会话类签名」而包了一层
  `Socket` 子类，把已读的第一行作为待读前缀注入。比改构造函数更集中。

## 构建

```bash
# 从仓库根目录
./scripts/build-android.sh
```

产物（都在 `build/` 下）：

| 文件 | 说明 |
| --- | --- |
| `CarSentinelCarUnit-release.apk` | **已签名**，可直接安装 |
| `carsentinel.jks.base64` | 签名 keystore 的 base64，**请备份** |
| `gradle.log` | 构建日志（失败时） |

### 签名

未签名 APK 装不上，所以脚本会自动签。keystore 按优先级取自：
`ANDROID_KEYSTORE_BASE64` 环境变量（GitHub Secret）→ 本地已有 → 固定参数现生成。

第一次构建是「现生成」，那把 key 只活在那次 CI 里。要覆盖升级，得把这次的
`carsentinel.jks.base64` 存成名为 `ANDROID_KEYSTORE_BASE64` 的 Secret。
keystore 在 `build/` 下，被 `.gitignore` 忽略，不会进仓库。

## 摄像头采集层

车机上「打不开摄像头」的原因很多，所以采集分三层，全部自动：

| 层 | 走什么 | 什么时候用 |
| --- | --- | --- |
| **Camera2 STANDARD** | 常规 Camera2，优先 1280×720 | 内置摄像头（前/后） |
| **Camera2 EXTERNAL** | 同一套 Camera2 但**低分辨率优先**（640×480 → 320×240） | `LENS_FACING_EXTERNAL` 的外接摄像头。车机 UVC 常因带宽/供电不足在高分辨率下直接失败 |
| **设备诊断** | 全量探测，结果进日志 | 上面两层都不行时，一次说清「这台机器到底有什么」 |

### 为什么没有「USB UVC 直采」

纯 Java 层**做不了** UVC 视频采集：UVC 摄像头必须走 USB isochronous 传输，
而 Android 的 `UsbRequest` 只支持 bulk/interrupt。要做只能上 native
（libusb/libuvc + JNI），那是另一个量级的工程。

如果诊断显示「有 USB 视频设备但 Camera2 枚举不到」，说明系统没把 UVC 注册成摄像头，
此时要么让系统加载 UVC 驱动，要么走 native 方案。

### 自动重试

0 路时每 5 秒重试一次，最多 6 次（30 秒），到量停止并明说。
很多车机首次枚举时摄像头服务还没就绪，第一次全失败很常见。
也可以点状态页的「再试一次」手动重试。

### 设备诊断

服务启动时若 0 路会自动跑一次；也可以随时点状态页「设备诊断」。
输出到「日志」页，包含：

- 相机权限是否授予
- Camera2 报告的摄像头数、每个的朝向 / 硬件级别 / 支持的分辨率
- 旧 Camera API 报告的摄像头数（有些车机只在老 API 里暴露）
- USB 视频类设备列表（vid/pid/接口数）
- 设备型号 / Android 版本 / API level

把日志贴出来就能定位问题，不用反复试。

### 关于没有 Gradle Wrapper JAR

本仓库**刻意不提交 `gradle/wrapper/gradle-wrapper.jar`** —— 它是二进制，
无法在本环境里生成，伪造一个只会让 CI 挂掉。因此：

- 脚本优先调用 `./gradlew`（若有人本地生成过 wrapper）；
- 否则回落到系统 `gradle`。GitHub `ubuntu-latest` 镜像自带 Gradle 与完整
  Android SDK，直接可用。
- 若两者都没有，脚本会打印明确提示并退出 1。

Release 是**未签名**的（无 `signingConfig`、`isMinifyEnabled false`），
CI 原样上传，签名由后续发布流程负责。

## 给 iOS 端的对齐点（PROTOCOL.md 之外）

1. `announce` 里 `cameras[]` 的 `w`/`h` 是**实际打开**的分辨率（通常 1280×720，
   但设备不支持时会退到最接近的支持尺寸），不是写死的 1280×720。
2. 首帧一定是关键帧：视频会话握手成功后车机端会立刻 `requestKeyframe`，
   手机端收到 `OK ...` 后的第一帧即可直接建解码器，无需等下一个 GOP。
3. `SUBSCRIBE` 行允许 `\r\n` 与 `\n` 两种结尾，`<cameraId>` 前后可有空白。
4. 控制通道首行也允许 `\r\n`。
5. `ping` 的 `id` 是 int，可能很大（脚本生成单调 id），车机端原样回。
6. `stats.netKbps` 是**车机端所有 socket 写出的总带宽**（含控制通道），
   不是单路视频带宽。
7. `camera_state` 只在 `active` / `fps` / `bitrateKbps`（≥100 kbps 跳变）变化时推，
   不会每秒刷屏。
8. 视频会话不设读取超时（靠 TCP 保活），对端关闭时靠 `read()` 返回 -1 或写失败感知。
9. UDP 45676 的 DISCOVER 应答是**单播回来源地址:端口**，不是广播。
