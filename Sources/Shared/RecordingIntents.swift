import AppIntents

struct StartRecordingIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource = "开始会议录音"
    static var description = IntentDescription("使用 Alaud 开始录音。首次使用需要打开 App 授予麦克风权限。")
    static var openAppWhenRun: Bool = true
    @MainActor func perform() async throws -> some IntentResult {
        let app = try AppRuntime.model()
        if app.recorder.activeID == nil { try await app.recorder.start() }
        else if !app.recorder.isRecording { try app.recorder.resume() }
        return .result()
    }
}

struct StopRecordingIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource = "结束会议录音"
    static var openAppWhenRun: Bool = true
    @MainActor func perform() async throws -> some IntentResult {
        try AppRuntime.model().recorder.stop()
        return .result()
    }
}

struct ToggleRecordingIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource = "开始或结束会议录音"
    static var openAppWhenRun: Bool = true
    @MainActor func perform() async throws -> some IntentResult {
        let app = try AppRuntime.model()
        if app.recorder.activeID == nil { try await app.recorder.start() }
        else { try app.recorder.stop() }
        return .result()
    }
}

struct AlaudShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRecordingIntent(), phrases: ["用\(.applicationName)开始录音"],
                    shortTitle: "开始录音", systemImageName: "mic.fill")
        AppShortcut(intent: StopRecordingIntent(), phrases: ["用\(.applicationName)结束录音"],
                    shortTitle: "结束录音", systemImageName: "stop.fill")
        AppShortcut(intent: ToggleRecordingIntent(), phrases: ["切换\(.applicationName)录音"],
                    shortTitle: "切换录音", systemImageName: "record.circle")
    }
}
