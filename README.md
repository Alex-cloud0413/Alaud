# Alaud

Apple Watch、iPhone 和 Mac 上的会议录音入口，共用自己的 iCloud 录音库与会后跟进事项。

**阶段：0.2.0 开发原型。** 面向 5–10 人、超过一小时的线下会议。录音、保存、传输和本机转写已实现；多人真实收音、续航和系统中断恢复需要在真机上验收。Agent 的任务执行范围由后续产品讨论决定，当前通过 Markdown / JSON 导出交接，不会后台执行任务。

## 已实现

- iPhone / Watch / Mac 原生 SwiftUI 录音界面，开始、暂停、继续和结束。
- 持续使用同一条麦克风输入，约每 60 秒封存一个 16 kHz 单声道 PCM CAF 片段；切片不重启录音引擎。
- 音频先写本机，再传输。原音约 115 MB/小时。Watch 等待手机完整交接后清理；iPhone / Mac 等待 iCloud 上传确认后释放原音，播放、转写、导出按需下载。
- 每场会议独立、原子写入的 JSON 清单；异常退出后尝试恢复可读取的未登记 CAF，并明确记录缺口。
- WatchConnectivity 排队传输、SHA-256 校验、幂等落盘、应用层回执；传输完成回调不等于接收确认。手机完整保存整场原音、校验并返回完整存储回执后，手表自动删除该场本地文件；旧版回执会先重新核验。
- 手机录音库、Mac 侧栏与列表/详情、黑白图标和界面；标题与备注、手动跟进事项、关键词搜索、逐片回听、转写时间点回听。
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

- Xcode 26+，包含 iOS / watchOS / macOS SDK；项目目标 iOS 26+、watchOS 26+、macOS 26+。
- Swift 6.2+；XcodeGen 2.46+。没有外部 Swift Package 依赖。
- Watch 需要配对 iPhone。当前默认路线为 Watch → iPhone，不要求手表直接访问云端。

```sh
brew install xcodegen
xcodegen generate
open Alaud.xcodeproj
```

在 Xcode 为 `Alaud`、`AlaudWatch` 和 `AlaudMac` 选择自己的签名团队。仓库不含团队账号、签名产物或个人凭据。若要改包名，同时修改 `project.yml` 中手机包名、手表包名和 `WKCompanionAppBundleIdentifier`，再重新生成工程。手机与 Mac 需配置相同 iCloud Drive 容器（默认 `iCloud.com.gaoyiming.alaud`），并在设备上开启 iCloud Drive。Mac scheme 为 `AlaudMac`。

```sh
swift test
xcodebuild -project Alaud.xcodeproj -scheme Alaud \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Alaud.xcodeproj -scheme Alaud \
  -destination 'platform=iOS Simulator,id=<模拟器 ID>' CODE_SIGNING_ALLOWED=NO test
```

应用测试使用合成音频，覆盖 90 分钟音频分段和 48 kHz 双声道转为 16 kHz 单声道的连续偏移。它们不验证真实麦克风、后台续航或真人语音准确率。

## 本机数据与恢复

每台设备先在 `Library/Application Support/Alaud/Meetings/<UUID>/` 保存录音。iPhone / Mac 使用同一 iCloud Drive 容器，独立保存原音和可合并的标题、备注、转写、待办。只有全场原音和元数据均确认上传后才自动清理本地原音。断网、空间不足或账号变化时保留本地文件并提示重试。

录音、按需回听及转写仍需要临时磁盘空间；本地长期保留索引与文字，离线语音模型也会占空间。iOS 后台执行由系统调度，上传可能要等下次打开 App。详情见 [存储说明](docs/STORAGE.md)。

- GitHub：代码、需求、配置模板与验证记录。
- 飞书 Drive：仅合成内容的开发材料。
- 真实会议：用户设备及自己的 iCloud，开发归档不收集内容。
- 签名安装包、构建缓存和设备认证：仅本机，不提交。

## 文档

- [存储与手表清理](docs/STORAGE.md)
- [产品边界](docs/PRODUCT.md)
- [真机验收](docs/DEVICE_ACCEPTANCE.md)
- [研究与复用选择](docs/RESEARCH.md)
- [验证记录](docs/VALIDATION.md)
- [Agent 数据契约](docs/AGENT_CONTRACT.md)
