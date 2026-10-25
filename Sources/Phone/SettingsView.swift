import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var transcription: TranscriptionService
    @ObservedObject private var cloud: CloudLibrary
    @Environment(\.dismiss) private var dismiss
    @AppStorage("reduceCallInterruptions") private var reduceCallInterruptions = true
    @AppStorage("autoTranscribe") private var autoTranscribe = true
    @AppStorage("transcriptionLocale") private var locale = "zh-CN"
    init(model: AppModel) { self.model = model; transcription = model.transcription; cloud = model.cloud }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CloudStatusLine(cloud: cloud)
                    if let issue = cloud.lastIssue { Label(issue, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.secondary) }
                    #if DEBUG
                    if let diagnostic = cloud.diagnosticDetails {
                        DisclosureGroup("连接诊断") { Text(diagnostic).font(.caption.monospaced()).textSelection(.enabled) }
                    }
                    #endif
                    if let date = cloud.lastSync { LabeledContent("最近同步", value: date.formatted(date: .omitted, time: .shortened)) }
                    LabeledContent("本机原音缓存", value: ByteCountFormatter.string(fromByteCount: cloud.cacheBytes, countStyle: .file))
                    Button("立即同步", systemImage: "arrow.triangle.2.circlepath") { Task { await cloud.sync() } }.disabled(cloud.isSyncing)
                    Button("释放已上传的原音缓存", systemImage: "internaldrive") { Task { await cloud.releaseCaches() } }
                } header: { Text("iCloud 录音库") } footer: {
                    Text("原音完整上传后自动释放本机副本，回听时按需下载。正在使用和未上传的原音会保留。iPhone 和 Mac 使用同一 Apple 账号即可同步，云端文件占用你的 iCloud 空间。")
                }
                Section {
                    Toggle("录音结束后自动转写", isOn: $autoTranscribe)
                    Picker("录音语言", selection: $locale) { Text("简体中文").tag("zh-CN"); Text("English").tag("en-US") }
                        .disabled(transcription.isWorking || transcription.preparing)
                    Button {
                        Task { await transcription.prepareModel(); model.processPending() }
                    } label: {
                        HStack { Text("准备离线转写模型"); if transcription.preparing { Spacer(); ProgressView() } }
                    }.disabled(transcription.preparing || transcription.isWorking)
                    if let message = transcription.preparationMessage { Text(message).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("本机转写") } footer: {
                    Text("首次需要下载 Apple 语音模型，之后在本机处理。模型会占用本机空间；云端原音在转写时临时下载，完成后释放。")
                }
                #if os(iOS)
                Section {
                    Toggle("减少来电造成的录音中断", isOn: $reduceCallInterruptions)
                } header: { Text("录音保护") } footer: {
                    Text("横幅来电可减少中断；全屏来电和接听仍可能打断录音。设置在下次开始或继续录音时生效。")
                }
                Section("专注模式与快捷入口") {
                    Text("在快捷指令中，先开启「会议」专注模式，再运行 Alaud「开始会议录音」；结束时先结束录音，再关闭专注模式。")
                    Text("可将「开始或结束会议录音」绑定到操作按钮。锁屏或切换 App 时应保留专注模式，系统闹钟仍可能响起。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                #endif
                Section("数据与交接") {
                    Text("手表在 iPhone 完整接收后清理原音；iPhone 和 Mac 在 iCloud 完整保存确认后清理本机原音。上传失败时，本机文件继续保留。")
                    Text("转写、备注和待办保留轻量本地索引。详情可导出 Markdown、JSON 和原音；Agent 执行范围尚未定义。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("iCloud Drive 中的 Alaud 文件夹保存云端原音与历史版本。云端同步不替代独立备份，重要会议仍建议导出。")
                        .font(.footnote).foregroundStyle(.secondary)
                    LabeledContent("版本", value: "Alaud 0.2.0 · 开发版")
                }
            }
            .formStyle(.grouped).tint(.primary)
            .navigationTitle("设置").alaudInlineTitle()
            #if os(iOS)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 500)
        #endif
    }
}
