import XCTest
@testable import AlaudCore

final class WatchCleanupTests: XCTestCase {
    private var temporary: URL!
    private var watch: MeetingStore!
    private var phone: MeetingStore!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        watch = try MeetingStore(root: temporary.appendingPathComponent("watch"))
        phone = try MeetingStore(root: temporary.appendingPathComponent("phone"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    private func recording(parts count: Int = 2) throws -> Meeting {
        var meeting = Meeting(source: .watch)
        meeting.captureState = .finished; meeting.endedAt = Date(); meeting.expectedPartCount = count
        try watch.save(meeting)
        for index in 0..<count {
            let url = watch.directory(for: meeting.id).appendingPathComponent(MeetingStore.filename(index: index))
            try Data("original-\(meeting.id)-\(index)".utf8).write(to: url)
            meeting.parts.append(AudioPart(index: index, filename: url.lastPathComponent,
                offset: Double(index * 60), duration: 60, sha256: try MeetingStore.digest(url)))
        }
        try watch.save(meeting); return meeting
    }
    private func transfer(_ meeting: Meeting, indices: [Int]? = nil) throws {
        for part in meeting.parts where indices?.contains(part.index) ?? true {
            try phone.importPart(from: watch.audioURL(meetingID: meeting.id, part: part),
                                 envelope: TransferEnvelope(meeting: meeting, part: part))
        }
        try phone.importFinalManifest(meeting)
    }

    func testFullPhoneProofReleasesOnlyWatchCopyWithoutWaitingForTranscription() throws {
        let meeting = try recording(); try transfer(meeting)
        let receipt = try XCTUnwrap(phone.storedMeetingReceipt(for: meeting.id))
        XCTAssertEqual(try phone.load(meeting.id).transcriptState, .waiting)
        XCTAssertTrue(try watch.removeConfirmedWatchCopy(receipt))
        XCTAssertFalse(FileManager.default.fileExists(atPath: watch.directory(for: meeting.id).path))
        XCTAssertTrue(try watch.list().isEmpty)
        for part in meeting.parts {
            XCTAssertEqual(try MeetingStore.digest(phone.audioURL(meetingID: meeting.id, part: part)), part.sha256)
        }
    }

    func testPartialDeliveryNeverProducesCleanupProof() throws {
        let meeting = try recording(); try transfer(meeting, indices: [0])
        XCTAssertNil(try phone.storedMeetingReceipt(for: meeting.id))
        XCTAssertEqual(try phone.missingPartIndices(from: meeting), [1])
        XCTAssertTrue(watch.contains(meeting.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try watch.audioURL(meetingID: meeting.id, part: meeting.parts[1]).path))
    }

    func testCorruptPhoneOriginalKeepsTheWatchBackup() throws {
        let meeting = try recording(); try transfer(meeting)
        let url = try phone.audioURL(meetingID: meeting.id, part: meeting.parts[0])
        try Data("damaged".utf8).write(to: url)
        XCTAssertThrowsError(try phone.storedMeetingReceipt(for: meeting.id))
        XCTAssertTrue(watch.contains(meeting.id))
    }

    func testMissingPhoneFileRequestsReplayAndPreventsCleanup() throws {
        let meeting = try recording(); try transfer(meeting)
        try FileManager.default.removeItem(at: phone.audioURL(meetingID: meeting.id, part: meeting.parts[1]))
        XCTAssertNil(try phone.storedMeetingReceipt(for: meeting.id))
        XCTAssertEqual(try phone.missingPartIndices(from: meeting), [1])
        try transfer(meeting, indices: [1])
        XCTAssertNotNil(try phone.storedMeetingReceipt(for: meeting.id))
    }

    func testMismatchedProofCannotDeleteAnyOriginal() throws {
        let meeting = try recording(); try transfer(meeting)
        let valid = try XCTUnwrap(phone.storedMeetingReceipt(for: meeting.id))
        var badHash = valid; badHash.parts[0].sha256 = String(repeating: "0", count: 64)
        var badCount = valid; badCount.expectedPartCount += 1
        var partial = valid; partial.parts.removeLast()
        var unknownVersion = valid; unknownVersion.schemaVersion = 2
        for invalid in [badHash, badCount, partial, unknownVersion] {
            XCTAssertThrowsError(try watch.removeConfirmedWatchCopy(invalid))
        }
        XCTAssertTrue(watch.contains(meeting.id))
        for part in meeting.parts {
            XCTAssertEqual(try MeetingStore.digest(watch.audioURL(meetingID: meeting.id, part: part)), part.sha256)
        }
    }

    func testRecordingAndPausedMeetingsCannotBeCleaned() throws {
        var meeting = try recording()
        for state in [CaptureState.recording, .paused] {
            meeting.captureState = state; try watch.save(meeting)
            XCTAssertThrowsError(try watch.removeConfirmedWatchCopy(StoredMeetingReceipt(meeting: meeting)))
        }
        XCTAssertTrue(watch.contains(meeting.id))
    }

    func testUnregisteredAudioBlocksWholeMeetingCleanup() throws {
        let meeting = try recording(); try transfer(meeting)
        let orphan = watch.directory(for: meeting.id).appendingPathComponent("part-00099.caf")
        try Data("not yet registered or delivered".utf8).write(to: orphan)
        let receipt = try XCTUnwrap(phone.storedMeetingReceipt(for: meeting.id))
        XCTAssertThrowsError(try watch.removeConfirmedWatchCopy(receipt))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(watch.contains(meeting.id))
    }

    func testDuplicateAndLateReceiptsAreHarmless() throws {
        let meeting = try recording(); try transfer(meeting)
        let receipt = try XCTUnwrap(phone.storedMeetingReceipt(for: meeting.id))
        XCTAssertTrue(try watch.removeConfirmedWatchCopy(receipt))
        XCTAssertFalse(try watch.removeConfirmedWatchCopy(receipt))
        XCTAssertTrue(try watch.list().isEmpty)
    }

    func testLegacyAcknowledgementsKeepOriginalsUntilFreshPhoneProof() throws {
        let meeting = try recording()
        try watch.update(meeting.id) {
            $0.finalManifestAcknowledged = true
            $0.parts = $0.parts.map { var part = $0; part.receivedByPhone = true; return part }
        }
        XCTAssertTrue(try watch.load(meeting.id).transferComplete)
        XCTAssertNil(try phone.storedMeetingReceipt(for: meeting.id))
        for part in meeting.parts {
            XCTAssertTrue(FileManager.default.fileExists(atPath: try watch.audioURL(meetingID: meeting.id, part: part).path))
        }
        try transfer(meeting)
        XCTAssertTrue(try watch.removeConfirmedWatchCopy(XCTUnwrap(phone.storedMeetingReceipt(for: meeting.id))))
    }

    func testInterruptedCleanupIsFinishedAfterStoreRelaunch() throws {
        let meeting = try recording(); try transfer(meeting)
        XCTAssertNotNil(try phone.storedMeetingReceipt(for: meeting.id))
        let cleanup = watch.root.appendingPathComponent(".cleanup", isDirectory: true)
        try FileManager.default.createDirectory(at: cleanup, withIntermediateDirectories: true)
        let staged = cleanup.appendingPathComponent(meeting.id.uuidString)
        try FileManager.default.moveItem(at: watch.directory(for: meeting.id), to: staged)
        let reopened = try MeetingStore(root: watch.root)
        XCTAssertTrue(try reopened.list().isEmpty)
        try reopened.finishConfirmedCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testCleanupLeavesOtherPendingMeetingsUntouched() throws {
        let complete = try recording(); let pending = try recording()
        try transfer(complete)
        let receipt = try XCTUnwrap(phone.storedMeetingReceipt(for: complete.id))
        try watch.removeConfirmedWatchCopy(receipt)
        XCTAssertEqual(try watch.list().map(\.id), [pending.id])
        for part in pending.parts {
            XCTAssertEqual(try MeetingStore.digest(watch.audioURL(meetingID: pending.id, part: part)), part.sha256)
        }
    }
}
