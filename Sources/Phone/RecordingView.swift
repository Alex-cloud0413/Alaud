import SwiftUI
import AlaudCore

struct RecordingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var recorder: MeetingRecorder
    @Environment(\.dismiss) private var dismiss
    init(model: AppModel) { self.model = model; recorder = model.recorder }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 20)
                Image(systemName: recorder.isRecording ? "waveform" : "pause.circle")
                    .font(.system(size: 68, weight: .light)).foregroundStyle(.primary)
                    .accessibilityHidden(true)
                Text(recorder.isRecording ? "正在录音" : "录音已暂停").font(.title2.weight(.semibold))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let start = recorder.activeID.flatMap { model.meeting($0)?.createdAt } ?? context.date
                    Text(audioClock(context.date.timeIntervalSince(start)))
                        .font(.system(size: 52, weight: .light, design: .monospaced))
                        .monospacedDigit().accessibilityLabel("会议经过时间")
                }
                Text("原音先保存在本机，上传确认后释放。\n锁屏或切换 App 后，录音继续。")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let error = recorder.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                Spacer()
                HStack(spacing: 16) {
                    Button {
                        if recorder.isRecording { recorder.pause() } else { model.resume() }
                    } label: {
                        Label(recorder.isRecording ? "暂停" : "继续录音", systemImage: recorder.isRecording ? "pause.fill" : "play.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                    }.buttonStyle(.bordered).controlSize(.large)
                    Button {
                        model.stop()
                        if recorder.activeID == nil { dismiss() }
                    } label: {
                        Label("结束", systemImage: "stop.fill").frame(maxWidth: .infinity).padding(.vertical, 12)
                    }.buttonStyle(.borderedProminent).tint(.primary).controlSize(.large)
                        .accessibilityIdentifier("stopRecordingButton")
                }
                Text("接听电话等系统操作仍可能中断录音；缺口会记录在会议中。")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(24)
            .navigationTitle("会议录音").alaudInlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("收起") { dismiss() } } }
        }
    }
}
