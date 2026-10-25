import SwiftUI
import AlaudCore

@main
struct AlaudWatchApp: App {
    var body: some Scene {
        WindowGroup {
            switch AppRuntime.result {
            case .success(let model): WatchRecordingView(model: model)
            case .failure(let error): Text(error.localizedDescription).font(.footnote).padding()
            }
        }
    }
}

struct WatchRecordingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var recorder: MeetingRecorder
    @Environment(\.scenePhase) private var scenePhase
    init(model: AppModel) { self.model = model; recorder = model.recorder }

    private var waiting: Int { model.meetings.filter { $0.source == .watch && $0.endedAt != nil }.count }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if let id = recorder.activeID, let meeting = model.meeting(id) {
                        Text(recorder.isRecording ? "正在录音" : "已暂停").font(.headline).foregroundStyle(.primary)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(clock(context.date.timeIntervalSince(meeting.createdAt)))
                                .font(.system(.title2, design: .monospaced)).monospacedDigit()
                        }
                        HStack(spacing: 10) {
                            Button {
                                if recorder.isRecording { recorder.pause() } else { model.resume() }
                            } label: { Image(systemName: recorder.isRecording ? "pause.fill" : "play.fill").frame(minHeight: 42) }
                                .accessibilityLabel(recorder.isRecording ? "暂停录音" : "继续录音")
                            Button { model.stop() } label: { Image(systemName: "stop.fill").frame(minHeight: 42) }
                                .tint(.white).accessibilityLabel("结束录音")
                        }
                        Text("原音已在手表保存\n结束后到 iPhone 跟进")
                            .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    } else {
                        Button { Task { await model.start() } } label: {
                            VStack(spacing: 8) {
                                Image(systemName: "mic.fill").font(.system(size: 34, weight: .medium))
                                Text("开始录音").font(.headline)
                            }.frame(maxWidth: .infinity).padding(.vertical, 18).foregroundStyle(.black)
                        }.buttonStyle(.borderedProminent).tint(.white).disabled(recorder.isBusy)
                        Text(waiting > 0 ? "\(waiting) 场录音等待手机确认" : "抬腕记录，手机跟进")
                            .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        if waiting > 0 { Button("重试同步") { model.transfer.pump(); model.refresh() }.font(.caption) }
                        Text("交接确认后\n自动释放手表空间")
                            .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if let error = model.errorMessage ?? recorder.errorMessage {
                        Text(error).font(.caption2).foregroundStyle(.secondary)
                        Button("关闭提示") { model.errorMessage = nil }.font(.caption2)
                    }
                }.padding(.horizontal, 4)
            }.navigationTitle("Alaud")
            .onChange(of: scenePhase) { _, phase in if phase == .active { model.becameActive() } }
            .onAppear { model.becameActive() }
        }
    }
    private func clock(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%02d:%02d", value / 60, value % 60)
    }
}
