import XCTest
import AVFoundation
import AlaudCore
@testable import Alaud

final class SegmentWriterTests: XCTestCase {
    private var temporary: URL!
    private var store: MeetingStore!
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try MeetingStore(root: temporary)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    func testNinetyMinuteSyntheticRecordingPersistsEveryFrameAcrossRelaunch() throws {
        let meeting = Meeting(source: .phone); try store.save(meeting)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        for i in 0..<16_000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.1)) * 0.2 }
        var error: Error?
        let writer = try SegmentWriter(store: store, meeting: meeting, inputFormat: format, didSave: {}, didFail: { error = $0 })
        for _ in 0..<5400 { writer.consume(buffer) }
        writer.finish()
        XCTAssertNil(error)
        let restored = try MeetingStore(root: temporary).load(meeting.id)
        XCTAssertEqual(restored.parts.count, 90)
        XCTAssertEqual(restored.audioDuration, 5400, accuracy: 0.01)
        var totalFrames: AVAudioFramePosition = 0
        for part in restored.parts {
            let url = try store.audioURL(meetingID: meeting.id, part: part)
            XCTAssertEqual(try MeetingStore.digest(url), part.sha256)
            let file = try AVAudioFile(forReading: url)
            totalFrames += file.length
            XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
            XCTAssertEqual(file.fileFormat.channelCount, 1)
        }
        XCTAssertEqual(totalFrames, 86_400_000)
    }

    func testHardwareFormatConversionKeepsContinuousOffsets() throws {
        let meeting = Meeting(source: .watch); try store.save(meeting)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        for channel in 0..<2 { for i in 0..<4800 { buffer.floatChannelData![channel][i] = 0.1 } }
        var error: Error?
        let writer = try SegmentWriter(store: store, meeting: meeting, inputFormat: format, didSave: {}, didFail: { error = $0 })
        for _ in 0..<1210 { writer.consume(buffer) }
        writer.finish()
        XCTAssertNil(error)
        let restored = try store.load(meeting.id)
        XCTAssertEqual(restored.parts.count, 3)
        XCTAssertEqual(restored.audioDuration, 121, accuracy: 0.02)
        XCTAssertEqual(restored.parts[1].offset, restored.parts[0].duration, accuracy: 0.0001)
        XCTAssertEqual(restored.parts[2].offset, restored.parts[0].duration + restored.parts[1].duration, accuracy: 0.0001)
    }

    func testResumeNeverOverwritesUncommittedAudio() throws {
        let meeting = Meeting(source: .phone); try store.save(meeting)
        let url = store.directory(for: meeting.id).appendingPathComponent(MeetingStore.filename(index: 0))
        let original = Data("uncommitted audio".utf8); try original.write(to: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600; memset(buffer.floatChannelData![0], 0, 1600 * MemoryLayout<Float>.size)
        var error: Error?
        let writer = try SegmentWriter(store: store, meeting: meeting, inputFormat: format, didSave: {}, didFail: { error = $0 })
        writer.consume(buffer); writer.finish()
        XCTAssertNotNil(error)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor
    func testRecoveryFindsOrphanedCAFAfterAppTermination() throws {
        let meeting = Meeting(source: .phone); try store.save(meeting)
        let url = store.directory(for: meeting.id).appendingPathComponent(MeetingStore.filename(index: 0))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000; memset(buffer.floatChannelData![0], 0, 16_000 * MemoryLayout<Float>.size)
        try file.write(from: buffer); file.close()
        let recorder = MeetingRecorder(store: store)
        try recorder.recoverPreviousSessions(source: .phone)
        let recovered = try store.load(meeting.id)
        XCTAssertEqual(recovered.parts.count, 1)
        XCTAssertTrue(recovered.isComplete)
        XCTAssertEqual(recovered.captureState, .interrupted)
        XCTAssertEqual(recovered.gaps.count, 1)
        XCTAssertNil(recorder.activeID)
    }
}
