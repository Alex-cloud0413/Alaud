# Alaud

Apple Watch 和 iPhone 上的会议录音入口，以及手机上的会后跟进收件箱。

**阶段：0.1 开发原型。** 面向 5–10 人、超过一小时的线下会议。录音、保存、传输和本机转写已实现；多人真实收音、续航和系统中断恢复需要在真机上验收。Agent 的任务执行范围由后续产品讨论决定，当前通过 Markdown / JSON 导出交接，不会后台执行任务。

## 已实现

- iPhone / Watch 原生 SwiftUI 录音界面，开始、暂停、继续和结束。
- 持续使用同一条麦克风输入，约每 60 秒封存一个 16 kHz 单声道 PCM CAF 片段；切片不重启录音引擎。
- 音频先写本机，再传输。原音约 115 MB/小时，双端保留时分别占用各设备存储。
- 每场会议独立、原子写入的 JSON 清单；异常退出后尝试恢复可读取的未登记 CAF，并明确记录缺口。
- WatchConnectivity 排队传输、SHA-256 校验、幂等落盘、应用层回执；传输完成回调不等于接收确认。当前不自动删除手表原音。
- 手机收件箱、标题与备注、手动跟进事项、关键词搜索、逐片回听、转写时间点回听。
- Apple SpeechAnalyzer 本机文件转写，逐片保存进度；模型需首次显式准备下载。失败保留原音，允许继续转写。
- 开始、结束、切换录音的 App Intents，可组合成快捷指令并绑定设备支持的操作按钮。首次运行会打开 App 获取麦克风授权。
- 导出带时间点、缺口和跟进事项的 Markdown / JSON；单片原音可通过系统分享导出。

## 录音保护的实际范围

App 使用 Apple 的音频会话偏好减少来电提示造成的中断。iPhone 的横幅来电、全屏来电、实际接听的行为不同，无法保证不中断。

会议专注模式需由用户在快捷指令里首次配置，建议分别组合：

1. 开始：开启「会议」专注模式 → Alaud「开始会议录音」。
2. 结束：Alaud「结束会议录音」→ 关闭本次开启的会议专注模式。

不要按 App 离开前台自动关闭专注模式，锁屏和切换 App 时录音仍可能继续。若需要恢复原有专注模式、尊重中途手动切换，需在个人快捷指令中单独配置并验收。**本版本不会自动更改专注模式、关闭闹钟或拒接电话。** 系统中断后，只在系统允许恢复时尝试续录，否则保留暂停状态和提示。

## 构建

- Xcode 26+，包含 iOS / watchOS SDK；项目目标 iOS 26+、watchOS 26+。
- Swift 6.2+；XcodeGen 2.46+。没有外部 Swift Package 依赖。
- Watch 需要配对 iPhone。当前默认路线为 Watch → iPhone，不要求手表直接访问云端。

```sh
brew install xcodegen
xcodegen generate
open Alaud.xcodeproj
```

在 Xcode 为 `Alaud` 和 `AlaudWatch` 选择自己的签名团队。仓库不含团队账号、签名产物或个人凭据。若要改包名，同时修改 `project.yml` 中手机包名、手表包名和 `WKCompanionAppBundleIdentifier`，再重新生成工程。

```sh
swift test
xcodebuild -project Alaud.xcodeproj -scheme Alaud \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Alaud.xcodeproj -scheme Alaud \
  -destination 'platform=iOS Simulator,id=<模拟器 ID>' CODE_SIGNING_ALLOWED=NO test
```

应用测试使用合成音频，覆盖 90 分钟音频分段和 48 kHz 双声道转为 16 kHz 单声道的连续偏移。它们不验证真实麦克风、后台续航或真人语音准确率。

## 本机数据与恢复

每台设备的 App 沙盒 `Library/Application Support/Alaud/Meetings/<UUID>/` 保存 `meeting.json`、`part-00000.caf` 等文件。iOS/watchOS 数据目录设置为首次解锁后可访问，以支持锁屏录音。当前没有独立 iCloud 同步或远程备份；删除 App 会删除该设备数据，重要会议请先导出。

- GitHub：源码、配置模板、需求、研究与验证记录。
- 飞书 Drive：运行截图等开发交付材料。
- 设备录音与转写：留在设备；开发归档不收集真实会议数据。
- `.build`、DerivedData、日志、签名信息：本地缓存，不提交。

## 文档

- [产品边界](docs/PRODUCT.md)
- [真机验收](docs/DEVICE_ACCEPTANCE.md)
- [研究与复用选择](docs/RESEARCH.md)
- [验证记录](docs/VALIDATION.md)
- [Agent 数据契约](docs/AGENT_CONTRACT.md)
