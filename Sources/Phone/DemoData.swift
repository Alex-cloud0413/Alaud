#if DEBUG
import Foundation
import AVFoundation
import AlaudCore

extension AppModel {
    func seedDemo() throws {
        guard meetings.isEmpty else { return }
        let definitions: [(String, TimeInterval, RecordingSource, TranscriptState)] = [
            ("产品周会 · 下一版范围", -3600, .watch, .ready),
            ("客户沟通 · 交付节奏", -86400, .phone, .waiting),
            ("方案评审 · 预算与依赖", -172800, .watch, .failed)
        ]
        for (index, definition) in definitions.enumerated() {
            var meeting = Meeting(title: "[演示] " + definition.0, createdAt: Date().addingTimeInterval(definition.1), source: definition.2)
            meeting.endedAt = meeting.createdAt.addingTimeInterval(1)
            meeting.captureState = .finished; meeting.expectedPartCount = 1
            meeting.transcriptState = definition.3
            meeting.notes = "这是界面验证用的虚构会议；原音为 1 秒合成静音，不含真实会议内容。"
            if index == 0 {
                meeting.followUps = [FollowUp(title: "整理下一版需求范围，列出仍待确认的依赖"), FollowUp(title: "周三前同步收音测试结果")]
                meeting.transcript = [TranscriptLine(partIndex: 0, offset: 0, text: "先验证五到十人的会议里，远端发言能不能清楚录到。"),
                    TranscriptLine(partIndex: 0, offset: 0.5, text: "这周先把录音、同步和会后收件箱跑通，任务执行范围另行确认。")]
            }
            if index == 2 { meeting.transcriptError = "演示状态：转写进程被中断，可继续处理。" }
            try store.save(meeting)
            let url = store.directory(for: meeting.id).appendingPathComponent(MeetingStore.filename(index: 0))
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
            silence.frameLength = 16_000
            memset(silence.floatChannelData![0], 0, 16_000 * MemoryLayout<Float>.size)
            try file.write(from: silence); file.close()
            meeting.parts = [AudioPart(index: 0, filename: url.lastPathComponent, offset: 0, duration: 1,
                sha256: try MeetingStore.digest(url), receivedByPhone: true)]
            meeting.finalManifestAcknowledged = true
            // Mark fixtures processed to prevent an automatic speech-model request during layout review.
            if meeting.transcriptState == .waiting { meeting.transcriptState = .failed; meeting.transcriptError = "演示内容：未发起转写。" }
            try store.save(meeting)
        }
        refresh()
    }
}
#endif
