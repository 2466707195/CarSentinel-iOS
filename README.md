# CarSentinel 360 · 360 车载哨兵

两端应用：**Android 车机端**采集摄像头并推流，**iOS 手机端**随时查看。

```
┌──────────────────────┐                      ┌──────────────────────┐
│   Android 车机端      │                      │    iOS 手机端         │
│                      │   UDP 广播 / TCP 45678│                      │
│  4 路摄像头           │ ◄──────────────────► │  四宫格实时画面       │
│  MediaCodec H.264    │                      │  点格 → 单路全屏      │
│  本地 TCP 推流服务    │                      │  VideoToolbox 硬解    │
└──────────────────────┘                      └──────────────────────┘
```

**没有本地录制**（按需求定的：车机端只负责采集 + 编码 + 推流，不落盘）。
**4 路是上限不是承诺** —— 普通 Android 设备通常只能同时开 1~2 个物理摄像头，
车机端启动时枚举实际能开的，有几路就服务几路，协议和手机端都是 N 路通用。

---

## 仓库结构

```
CarSentinel360/
├─ docs/
│  ├─ PROTOCOL.md      ← 两端唯一的契约（端口/JSON/帧格式），改任何一端先改这里
│  └─ RELAY.md         ← 公网中继扩展方案（现在没实现，设计已经留好口）
├─ project.yml         ← iOS 工程定义（XcodeGen）
├─ codemagic.yaml      ← Codemagic 备用构建配置
├─ .github/workflows/build.yml   ← 一个 workflow 同时出两端产物
├─ scripts/
│  ├─ publish-github.ps1     ← ★ Windows 一键发布 + 云端编译 + 取包
│  ├─ build-unsigned-ipa.sh  ← CI：编译 iOS 出未签名 ipa
│  ├─ build-android.sh       ← CI：编译 Android 出未签名 apk
│  ├─ install-xcodegen.sh    ← 锁 XcodeGen 2.38.0
│  └─ inspect-ipa.ps1        ← 本地验包
├─ ios/CarSentinel/           ← iOS 手机端源码（SwiftUI + Aurora UI）
└─ android/                   ← Android 车机端源码（Kotlin + Compose + Aurora UI）
```

两端共用同一套 **Aurora UI** 设计系统（色值/字阶/圆角逐值一致），
源码分别在 `ios/CarSentinel/{Theme,UI}` 和 `android/app/src/main/java/.../ui/{theme,common}`。

---

## 怎么出包（本机没有 Mac、没有 Android SDK、没有 git）

全靠 GitHub Actions。只需要一个 **PAT**（classic token，勾 `repo` + `workflow`：
<https://github.com/settings/tokens/new>，只显示一次）。

```powershell
# 一条命令：建仓库 → 推代码 → 触发编译 → 把两端包都下回来
powershell -File scripts\publish-github.ps1 -Token ghp_xxx
```

产物落在 `build\`：

| 文件 | 是什么 | 怎么装 |
| --- | --- | --- |
| `CarSentinel-unsigned.ipa` | iOS 手机端 | 拖进全能签 / ESign → 选证书重签 → 下载 → 装到 iPhone |
| `CarSentinelCarUnit-release-unsigned.apk` | Android 车机端 | 传到车机，文件管理器安装（允许未知来源） |
| `Info.json` | ipa 里的 Info.plist 转成的 JSON | Windows 上没有 `plutil`，验包靠它 |

### 构建失败怎么办

浏览器常常连不上 GitHub，所以 CI 会把**构建日志也打成 artifact**。
`publish-github.ps1` 会自动把它下到 `build\logs\`：

```
build\logs\ios-build-log\xcodebuild.log     ← Swift 编译错误在这
build\logs\android-build-log\gradle.log     ← Kotlin 编译错误在这
```

脚本检测到没产出 ipa/apk 时会直接提示去看这两个文件。
把日志末尾几十行贴回来就能定位问题。

### 第一次构建前，先知道这几个「本机验不了的签名」

这份代码**一次都没有真正编译过**（开发机没有 Mac、没有 Android SDK）。
除了两个独立静态审查 + 9 项机械校验，下面这几处是**唯一**没法在本机验证的，
CI 报错时按这张表改，不用重新推理：

| 位置 | 如果 CI 报这个错 | 改成 |
| --- | --- | --- |
| `ios/CarSentinel/Net/H264Decoder.swift` 的 `makeFormatDescription` | `cannot convert value of type '[UnsafePointer<UInt8>?]' to expected argument type 'UnsafePointer<UnsafePointer<UInt8>>'` | 把 `let pointers: [UnsafePointer<UInt8>?]` 的 `?` 去掉。两种写法互斥，只可能对一种 |
| `ios/CarSentinel/Net/H264Decoder.swift` 的 `emitDecodedFrame` | `CMSampleBufferCreateReadyWithImageBuffer` 参数标签不符 | `sampleTiming:` 可能要写成 `sampleTimingEntryArray:`，按报错提示对齐 |

其余 VideoToolbox / AVFoundation 调用（`VTDecompressionSessionCreate`、
`VTDecompressionOutputCallbackRecord`、`decodeFlags:`、`CMBlockBufferCreateWithMemoryBlock`、
`AVSampleBufferDisplayLayer.isReadyForMoreMediaData` 等）都已由独立审查逐签名核对过，
大概率不需要动。

> 公开仓库的 Actions 分钟数不限；私有仓库免费版 macOS 按 10 倍折算 ≈ 200 分钟/月
> （一次构建 3~6 分钟，够用）。

**只想推代码不编译**：加 `-SkipBuild`。
**改完代码**：再跑一次同一条命令即可增量同步。

---

## 装机前置条件

**iPhone（手机端）**
1. 设置 → 隐私与安全性 → 开发者模式 → 开 → 重启
2. 全能签里把手机 UDID 加进证书（免费证书必须先登记设备）
3. 装好后：设置 → 通用 → VPN与设备管理 → 信任证书
4. ⚠️ **免费 Apple ID 证书 7 天过期**，App 会从桌面消失，要重签重装。
   长期用买开发者账号（688/年）。局域网自用场景免费证书够。

**Android（车机端）**
1. 允许安装未知来源应用
2. 首次打开授 `CAMERA` 和 `POST_NOTIFICATIONS` 权限
3. 把「车载哨兵」服务打开（常驻通知，别杀掉）

**网络**：手机和车机必须在**同一个 WiFi** 下。手机端靠 UDP 广播自动发现车机；
路由器挡了广播就用「附近设备」页里的手动输入 IP。

---

## 两端怎么配合

1. 车机端开服务 → 每 1 秒往 `255.255.255.255:45677` 广播一次自己的存在和摄像头列表
2. 手机端「附近设备」页收到广播，列出车机；也可以主动往 `45676` 发 `DISCOVER`
3. 点某台车机 → TCP 连 `45678`，发 `hello`，拿到摄像头列表
4. 点某一路 → 新开一条 TCP 到 `45678`，第一行发 `SUBSCRIBE <id>`，
   车机回 `OK <w> <h> <fps> h264` 之后开始吐 24 字节帧头 + H.264 负载
5. 手机端 VideoToolbox 硬解 → `AVSampleBufferDisplayLayer` 显示

完整契约（含每个字段的偏移量、错误码、保活规则）在 [`docs/PROTOCOL.md`](docs/PROTOCOL.md)。

---

## 当前状态

| 端 | 代码 | 云端出包 | 装机验证 |
| --- | --- | --- | --- |
| iOS 手机端 | ✅ 完成 | 待跑 | 待用户提供 PAT |
| Android 车机端 | ✅ 完成 | 待跑 | 待用户提供 PAT |

**没做的**：公网远程查看（`docs/RELAY.md` 有完整方案，两端协议不用改）、
本地/云端录像存储、事件视频（碰撞触发）、音频。

---

## 自带的校验工具（`tools/`，改完代码跑一遍再发布）

```bash
python tools/check-braces.py         # 44 个 Kotlin/Swift 文件括号配平
python tools/preflight.py            # YAML / project.yml 路径 / CI 脚本存在性 /
                                     # 上传文件清单 / .ps1 BOM 检查
python tools/protocol-crosscheck.py  # 从两端真实源码抽常量对账（端口/魔数/偏移/键名/消息类型）
python tools/kotlin-imports.py       # Kotlin：裸用的类型是否都有 import / 同包声明
python tools/kotlin-interfaces.py    # Kotlin：interface 成员是否全部实现、委托是否接线
python tools/swift-api-check.py      # Swift：Aurora 组件调用的参数标签是否都存在于声明
```

```powershell
powershell -File tools\make-appicon.ps1   # 重新生成 1024 App 图标
```

> ⚠️ `.ps1` 必须保持 UTF-8 **with BOM**。PS 5.1 按 ANSI 读无 BOM 的 UTF-8，
> 中文会变乱码并把双引号串里合法的 `&` 暴露成裸运算符，报一堆莫名的语法错误。
> `preflight.py` 会检查这一项 —— 用编辑类工具改过 `.ps1` 之后务必重跑。

---

## 排查看哪里

- 手机端「诊断」Tab：连接状态、车机 CPU/上行、每路视频的帧数/码率、日志
- 车机端「日志」页：摄像头开关结果、推流错误
- 画面花屏/卡住：单路全屏下点右上角刷新按钮，请求一个关键帧
