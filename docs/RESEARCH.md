# 研究与实现选择

2026-10-25 查看 GitHub README、许可证、仓库结构及部分录音/传输源码。

| 项目 | 值得参考 | 边界 |
| --- | --- | --- |
| [Recly](https://github.com/rokrokss/recly) | Watch → 手机，持久回执、文件接口、Agent 交接 | AGPL-3.0-or-later；未作为代码底座 |
| [小鹿录音](https://github.com/xiaolu-ai26/xiaolu-watch) | 分片保留、直接上传、自托管中文笔记 | MIT；真机覆盖边界由作者披露 |
| [open-hemory](https://github.com/duanyu119/open-hemory) | 本地转写、来源映射、原音回查 | MIT；实验性 |
| [Murmur](https://github.com/sushildalavi/murmur) | 本地检索和带引用的历史问答 | MIT；未做编译/中文真机验证 |

Alaud 采用独立实现，没有复制以上仓库的源文件或依赖其服务。优先复用 Apple 系统框架，避免在 Agent 任务范围尚未明确时绑定某个完整产品或云端服务。

## Apple 平台依据

- [音频系统中断](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions)
- [减少系统提示中断的偏好及横幅/全屏来电区别](https://developer.apple.com/documentation/avfaudio/avaudiosession/setprefersnointerruptionsfromsystemalerts(_:))
- [专注模式的通知与来电规则](https://support.apple.com/guide/iphone/allow-or-silence-notifications-for-a-focus-iph21d43af5b/ios)
- [闹钟不受勿扰或静音影响](https://support.apple.com/en-in/118444)
- [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- 实现时核对了本机 Xcode 27.1 SDK 中 SpeechAnalyzer、AssetInventory、AVAudioFile.close 和 AudioRecordingIntent 的公开声明。
