import Foundation

public enum RecordingSource: String, Codable, Sendable {
    case phone, watch
    public var title: String { self == .phone ? "iPhone" : "Apple Watch" }
}

public enum CaptureState: String, Codable, Sendable {
    case recording, paused, finished, interrupted
}

public enum TranscriptState: String, Codable, Sendable {
    case waiting, processing, ready, failed
}

public struct AudioPart: Codable, Equatable, Identifiable, Sendable {
    public var id: Int { index }
    public var index: Int
    public var filename: String
    public var offset: TimeInterval
    public var duration: TimeInterval
    public var sha256: String
    public var receivedByPhone: Bool

    public init(index: Int, filename: String, offset: TimeInterval, duration: TimeInterval,
                sha256: String, receivedByPhone: Bool = false) {
        self.index = index; self.filename = filename; self.offset = offset
        self.duration = duration; self.sha256 = sha256; self.receivedByPhone = receivedByPhone
    }
}

public struct RecordingGap: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var beganAt: Date
    public var endedAt: Date?
    public var reason: String
    public init(beganAt: Date = Date(), endedAt: Date? = nil, reason: String) {
        id = UUID(); self.beganAt = beganAt; self.endedAt = endedAt; self.reason = reason
    }
}

public struct TranscriptLine: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var partIndex: Int
    public var offset: TimeInterval
    public var text: String
    public init(partIndex: Int, offset: TimeInterval, text: String) {
        id = UUID(); self.partIndex = partIndex; self.offset = offset; self.text = text
    }
}

public struct FollowUp: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var completed: Bool
    public init(title: String) { id = UUID(); self.title = title; completed = false }
}

public struct Meeting: Codable, Equatable, Identifiable, Sendable {
    public var schemaVersion = 1
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var endedAt: Date?
    public var source: RecordingSource
    public var captureState: CaptureState
    public var parts: [AudioPart]
    public var expectedPartCount: Int?
    public var gaps: [RecordingGap]
    public var finalManifestAcknowledged: Bool
    public var transcriptState: TranscriptState
    public var transcript: [TranscriptLine]
    public var transcribedPartIndices: [Int]
    public var transcriptError: String?
    public var followUps: [FollowUp]
    public var notes: String

    public init(id: UUID = UUID(), title: String = "", createdAt: Date = Date(), source: RecordingSource) {
        self.id = id; self.title = title.isEmpty ? "会议录音" : title
        self.createdAt = createdAt; self.source = source; captureState = .recording
        parts = []; gaps = []; finalManifestAcknowledged = false
        transcriptState = .waiting; transcript = []; transcribedPartIndices = []; followUps = []; notes = ""
    }

    public var audioDuration: TimeInterval { parts.reduce(0) { $0 + $1.duration } }
    public var isComplete: Bool {
        guard endedAt != nil, let expectedPartCount else { return false }
        return expectedPartCount > 0 && parts.count == expectedPartCount
            && Set(parts.map(\.index)) == Set(0..<expectedPartCount)
    }
    public var transferComplete: Bool {
        isComplete && finalManifestAcknowledged && parts.allSatisfy(\.receivedByPhone)
    }
    public var stateTitle: String {
        if captureState == .recording { return source == .watch ? "手表录音中" : "录音中" }
        if captureState == .paused { return "录音已暂停" }
        if !isComplete { return source == .watch ? "等待手表同步" : "没有完整音频" }
        switch transcriptState {
        case .waiting: return "待转写"
        case .processing: return "正在转写"
        case .ready: return "待跟进"
        case .failed: return "转写待重试"
        }
    }
}

public struct TransferEnvelope: Codable, Sendable {
    public var meeting: Meeting
    public var part: AudioPart
    public init(meeting: Meeting, part: AudioPart) { self.meeting = meeting; self.part = part }
}

public enum MeetingExport {
    public static func markdown(_ meeting: Meeting) -> String {
        let date = meeting.createdAt.formatted(date: .abbreviated, time: .shortened)
        var text = "# \(meeting.title)\n\n时间：\(date)\n来源：\(meeting.source.title)\n会议 ID：\(meeting.id.uuidString)\n"
        if !meeting.gaps.isEmpty {
            text += "\n## 录音缺口\n\n"
            for gap in meeting.gaps {
                text += "- \(gap.beganAt.formatted(date: .omitted, time: .standard))：\(gap.reason)"
                if let end = gap.endedAt { text += "，\(end.formatted(date: .omitted, time: .standard))恢复" }
                text += "\n"
            }
        }
        if !meeting.notes.isEmpty { text += "\n## 会议备注\n\n\(meeting.notes)\n" }
        text += "\n## 跟进事项\n\n"
        text += meeting.followUps.isEmpty ? "尚未添加。\n" : meeting.followUps.map { "- [\($0.completed ? "x" : " ")] \($0.title)" }.joined(separator: "\n") + "\n"
        text += "\n## 转写原文\n\n"
        text += meeting.transcript.isEmpty ? "尚未转写。\n" : meeting.transcript.map {
            let stamp = Int($0.offset)
            return "[\(String(format: "%02d:%02d", stamp / 60, stamp % 60)) · 片段 \($0.partIndex + 1)] \($0.text)"
        }.joined(separator: "\n\n")
        return text
    }
}
