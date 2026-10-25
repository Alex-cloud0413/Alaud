import AVFoundation
import AlaudCore

/// Called only on the recorder's serial writer queue. One continuous engine tap, no restart at part boundaries.
final class SegmentWriter {
    private let store: MeetingStore
    private let meetingID: UUID
    private let converter: AVAudioConverter
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var file: AVAudioFile?
    private var index: Int
    private var offset: TimeInterval
    private var frames: AVAudioFramePosition = 0
    private var failed = false
    private let didSave: () -> Void
    private let didFail: (Error) -> Void

    init(store: MeetingStore, meeting: Meeting, inputFormat: AVAudioFormat,
         didSave: @escaping () -> Void, didFail: @escaping (Error) -> Void) throws {
        self.store = store; meetingID = meeting.id
        index = (meeting.parts.map(\.index).max() ?? -1) + 1
        offset = meeting.audioDuration; self.didSave = didSave; self.didFail = didFail
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CaptureError.invalidFormat
        }
        self.converter = converter
    }

    func consume(_ input: AVAudioPCMBuffer) {
        guard !failed else { return }
        do {
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate)) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { throw CaptureError.invalidFormat }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return input
            }
            if let conversionError { throw conversionError }
            guard status != .error else { throw CaptureError.invalidFormat }
            guard output.frameLength > 0 else { return }
            if file == nil { try openPart() }
            try file?.write(from: output)
            frames += AVAudioFramePosition(output.frameLength)
            if frames >= 16_000 * 60 { try closePart() }
        } catch { failed = true; didFail(error) }
    }

    func finish() {
        do { try closePart() } catch { if !failed { failed = true; didFail(error) } }
    }

    private func openPart() throws {
        let url = store.directory(for: meetingID).appendingPathComponent(MeetingStore.filename(index: index))
        guard !FileManager.default.fileExists(atPath: url.path) else { throw StoreError.conflictingPart }
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        frames = 0
    }

    private func closePart() throws {
        guard let url = file?.url else { return }
        file?.close()
        file = nil
        guard frames > 0 else { return }
        let duration = Double(frames) / 16_000
        let part = AudioPart(index: index, filename: url.lastPathComponent, offset: offset,
                             duration: duration, sha256: try MeetingStore.digest(url))
        try store.append(part, to: meetingID)
        index += 1; offset += duration; frames = 0; didSave()
    }

    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copied = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copied.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copied.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let sourceData = from.mData, let destinationData = to.mData else { return nil }
            memcpy(destinationData, sourceData, Int(from.mDataByteSize))
        }
        return copied
    }
}

enum CaptureError: LocalizedError {
    case microphoneDenied, invalidFormat, busy, storageFull
    var errorDescription: String? {
        switch self {
        case .microphoneDenied: return "请在系统设置中允许「Alaud」使用麦克风。"
        case .invalidFormat: return "麦克风暂时不可用，请检查通话或音频设备后重试。"
        case .busy: return "已有一场录音正在进行。"
        case .storageFull: return "设备可用空间不足 200 MB，请释放空间后录音。"
        }
    }
}
