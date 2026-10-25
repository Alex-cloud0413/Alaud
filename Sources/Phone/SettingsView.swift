import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var transcription: TranscriptionService
    @Environment(\.dismiss) private var dismiss
    @AppStorage("reduceCallInterruptions") private var reduceCallInterruptions = true
    @AppStorage("autoTranscribe") private var autoTranscribe = true
    @AppStorage("transcriptionLocale") private var locale = "zh-CN"
    init(model: AppModel) { self.model = model; transcription = model.transcription }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("减少来电造成的录音中断", isOn: $reduceCallInterruptions)
                } header: { Text("录音保护") } footer: {
                    Text("iPhone 使用横幅来电时可减少中断；全屏来电和接听电话仍可能打断录音。设置在下次开始或继续录音时生效。")
                }
                Section("会议专注模式") {
                    Text("在快捷指令里，把「设置专注模式」放在「开始会议录音」之前；结束时先运行「结束会议录音」，再关闭本次会议专注模式。")
                        .font(.subheadline)
                    Text("专注模式应覆盖整段录音，切换 App 或锁屏时继续保留。系统闹钟不会因此关闭。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("录音结束后自动转写", isOn: $autoTranscribe)
                    Picker("录音语言", selection: $locale) {
                        Text("简体中文").tag("zh-CN")
                        Text("English").tag("en-US")
                    }.disabled(transcription.isWorking || transcription.preparing)
                    Button {
                        Task { await transcription.prepareModel(); model.processPending() }
                    } label: {
                        HStack {
                            Text("准备离线转写模型")
                            if transcription.preparing { Spacer(); ProgressView() }
                        }
                    }.disabled(transcription.preparing || transcription.isWorking)
                    if let message = transcription.preparationMessage { Text(message).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("本机转写") } footer: {
                    Text("首次准备需要联网下载 Apple 的语音模型，之后在 iPhone 上处理。录音不会发送给云端转写服务；系统暂停处理时，可回到 App 继续。")
                }
                Section("快捷指令与操作按钮") {
                    Text("在「快捷指令」中搜索 Alaud，可添加「开始会议录音」「结束会议录音」或「开始或结束会议录音」，再绑定到支持的操作按钮。首次使用请打开 App 授予麦克风权限。")
                        .font(.subheadline)
                }
                Section("交给 Agent") {
                    Text("在会议详情中导出 Markdown 或 JSON，保留原文时间点、录音缺口和跟进事项。")
                        .font(.subheadline)
                }
                Section("存储") {
                    Text("手机录音保存在本机；手表录音通过配对连接传到手机。手表原音会继续保留，当前版本不会自动清理。卸载 App 会删除该设备的本地数据，请先导出重要会议。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    LabeledContent("版本", value: "Alaud 0.1 · 开发版")
                }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
