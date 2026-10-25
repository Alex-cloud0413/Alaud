# Alaud 0.1 验证记录

日期：2026-10-25，Asia/Shanghai。

## 已通过

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| Swift package | 8/8 通过 | 原子保存与重载、重复传输、乱序结束信息、数据校验、路径约束、冲突保护、完整性与来源导出 |
| iOS hosted tests | 4/4 通过 | 90 分钟合成音频完整落盘、48 kHz 双声道转换、未登记音频不被覆盖、可读孤立 CAF 恢复 |
| iOS + Watch 模拟器目标编译 | 通过 | Xcode 27.1；没有安装 watchOS 模拟器运行时，因此没有运行 Watch 界面 |
| iOS + Watch 真机目标编译、开发签名 | 通过 | 开发版 0.1.0 (1)，同一手机包内包含 Watch App |
| iPhone 模拟器界面自查 | 已检查 | 空收件箱、有内容收件箱、会议详情、明暗外观及设置；示例标题标记为「演示」 |
| iPhone 真机安装与启动 | 通过 | iPhone 17 上回读确认 Alaud 0.1.0 (1) 已安装，启动后仍有运行进程；未开始录音 |
| Watch 真机安装与启动 | 通过 | Apple Watch Series 11 上回读确认 Alaud 0.1.0 (1) 已安装，启动后仍有运行进程；未由安装流程触发录音 |
| 本地安装包 | 已更新 | `artifacts/Alaud-0.1.0-development-watch-ready.ipa`；签名描述文件已包含这块手表，完整手机包内包含 Watch App，仅在本机保存 |

90 分钟测试使用 86,400,000 个 16 kHz 合成样本，以加速方式写入 90 个文件，并在重载后验证总帧数、时长和每个文件的 SHA-256。它不是 90 分钟真机运行或续航测试。

## 未完成

- 两端已完成安装和启动核验。手表此前停留在功能调试选项页，开启系统开发者模式后连接恢复；已为这块手表更新签名并安装。实际麦克风、录音、转写和两端音频同步仍待验证，安装流程没有主动录音。
- 未验收 5–10 人会议的收音、真人中文转写、长时续航、来电/闹钟/Siri 中断或真实断线补传。
- 未运行后台 Agent。转写依赖设备支持和首次下载的 Apple 语言资产，模型准备与实际识别质量仍需真机验证。
- Watch App 已在真机安装并启动；尚未进行真机页面视觉和录音交互验收。
- 尚未实现一键导出整场会议的全部原音包、App 内批量清理或独立云备份；当前逐片分享原音。
- Life · OS portfolio-sync 失败：既有项目缺少 `articles/2026-09-14-lifeos-app-and-execution-system/execution-plan.json`。Alaud 已写入项目台账，进度前端尚未同步；未修改或伪造该旧项目的执行计划。

## 复现

核心测试：`swift test`。

应用测试：

```sh
xcodebuild -project Alaud.xcodeproj -scheme Alaud \
  -destination 'platform=iOS Simulator,id=<本机模拟器 ID>' \
  CODE_SIGNING_ALLOWED=NO test
```

模拟器界面示例仅在 DEBUG 构建通过 `--demo` 参数启用；额外参数 `--demo-detail` / `--demo-settings` 可定位到真实详情/设置视图。示例原音是合成静音，不含真实会议数据，开发签名安装包不传入这些参数。
