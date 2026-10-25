import XCTest
@testable import AlaudCore

final class MeetingStoreTests: XCTestCase {
    private var temporary: URL!
    private var store: MeetingStore!
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try MeetingStore(root: temporary.appendingPathComponent("store"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    private func fixture(index: Int = 0) throws -> (URL, AudioPart) {
        let url = temporary.appendingPathComponent(UUID().uuidString)
        try Data("audio-\(index)".utf8).write(to: url)
        let part = AudioPart(index: index, filename: MeetingStore.filename(index: index), offset: Double(index * 60),
                             duration: 60, sha256: try MeetingStore.digest(url))
        return (url, part)
    }

    func testRetryIsIdempotentAndPreservesPhoneEdits() throws {
        let (url, part) = try fixture()
        let watch = Meeting(source: .watch)
        let envelope = TransferEnvelope(meeting: watch, part: part)
        try store.importPart(from: url, envelope: envelope)
        try store.update(watch.id) { $0.title = "已在手机改名"; $0.notes = "会议背景"; $0.followUps = [FollowUp(title: "跟进报价")] }
        try store.importPart(from: url, envelope: envelope)
        let restored = try MeetingStore(root: store.root).load(watch.id)
        XCTAssertEqual(restored.parts.count, 1)
        XCTAssertEqual(restored.title, "已在手机改名")
        XCTAssertEqual(restored.followUps.count, 1)
        XCTAssertEqual(restored.notes, "会议背景")
        XCTAssertTrue(restored.parts[0].receivedByPhone)
    }

    func testFinalManifestCanArriveBeforeAudioAndNeverReopens() throws {
        let (url, part) = try fixture()
        let early = Meeting(source: .watch)
        var final = early; final.endedAt = final.createdAt.addingTimeInterval(60)
        final.captureState = .finished; final.expectedPartCount = 1; final.parts = [part]
        try store.importFinalManifest(final)
        XCTAssertFalse(try store.load(final.id).isComplete)
        try store.importPart(from: url, envelope: TransferEnvelope(meeting: early, part: part))
        let loaded = try store.load(final.id)
        XCTAssertTrue(loaded.isComplete)
        XCTAssertEqual(loaded.captureState, .finished)
        XCTAssertEqual(loaded.endedAt!.timeIntervalSince1970, final.endedAt!.timeIntervalSince1970, accuracy: 1)
    }

    func testRejectsCorruptionBeforeAcknowledgement() throws {
        let (url, part) = try fixture()
        try Data("damaged".utf8).write(to: url)
        let meeting = Meeting(source: .watch)
        XCTAssertThrowsError(try store.importPart(from: url, envelope: TransferEnvelope(meeting: meeting, part: part)))
        XCTAssertTrue(try store.list().isEmpty)
    }

    func testRejectsTraversalAndInvalidDurations() throws {
        let (url, part) = try fixture()
        let meeting = Meeting(source: .watch)
        for badName in ["../escape.caf", "/tmp/escape.caf", "part-00001.caf"] {
            var invalid = part; invalid.filename = badName
            XCTAssertThrowsError(try store.importPart(from: url, envelope: TransferEnvelope(meeting: meeting, part: invalid)))
        }
        var invalid = part; invalid.duration = -.infinity
        XCTAssertThrowsError(try store.audioURL(meetingID: meeting.id, part: invalid))
    }

    func testConflictingRetryCannotOverwriteOriginal() throws {
        let (url, part) = try fixture()
        let meeting = Meeting(source: .watch)
        try store.importPart(from: url, envelope: TransferEnvelope(meeting: meeting, part: part))
        try Data("different audio".utf8).write(to: url)
        var conflict = part; conflict.sha256 = try MeetingStore.digest(url)
        XCTAssertThrowsError(try store.importPart(from: url, envelope: TransferEnvelope(meeting: meeting, part: conflict)))
        XCTAssertEqual(try MeetingStore.digest(store.audioURL(meetingID: meeting.id, part: part)), part.sha256)
    }

    func testCompletenessRequiresEveryPartIndex() throws {
        let (_, part) = try fixture()
        var meeting = Meeting(source: .watch)
        meeting.endedAt = Date(); meeting.expectedPartCount = 2
        meeting.parts = [part, part]
        XCTAssertFalse(meeting.isComplete)
        var last = part; last.index = 1; last.filename = MeetingStore.filename(index: 1)
        meeting.parts = [part, last]
        XCTAssertTrue(meeting.isComplete)
        XCTAssertFalse(meeting.transferComplete)
        meeting.parts = meeting.parts.map { var value = $0; value.receivedByPhone = true; return value }
        meeting.finalManifestAcknowledged = true
        XCTAssertTrue(meeting.transferComplete)
    }

    func testCorruptManifestIsReportedInsteadOfSilentlyHidingMeeting() throws {
        let meeting = Meeting(source: .phone); try store.save(meeting)
        try Data("{broken".utf8).write(to: store.directory(for: meeting.id).appendingPathComponent("meeting.json"))
        XCTAssertThrowsError(try store.list())
    }

    func testExportKeepsSourceAndGapsSeparateFromFollowUps() {
        var meeting = Meeting(title: "范围评审", source: .watch)
        meeting.gaps = [RecordingGap(reason: "系统中断")]
        meeting.followUps = [FollowUp(title: "核对报价")]
        meeting.transcript = [TranscriptLine(partIndex: 1, offset: 125, text: "周三前确认报价。")]
        let text = MeetingExport.markdown(meeting)
        XCTAssertTrue(text.contains("[02:05 · 片段 2]"))
        XCTAssertTrue(text.contains("## 录音缺口"))
        XCTAssertTrue(text.contains("- [ ] 核对报价"))
        XCTAssertTrue(text.contains(meeting.id.uuidString))
    }
}
