import XCTest
@testable import AlaudCore

private actor FakeCloud: CloudTransport {
    enum Failure { case audio, manifest, catalog, receipt, download }
    var account = "first-account"
    var failure: Failure?
    var meetings: [UUID: CloudMeetingSnapshot] = [:]
    var audio: [String: Data] = [:]
    var index: [UUID: String] = [:]
    var uploads = 0
    var downloads = 0
    var serial = 0
    var duringSave: (@Sendable () throws -> Void)?
    func configure(failure: Failure? = nil) { self.failure = failure }
    func changeAccount() { account = "another-account" }
    func setSaveHook(_ hook: @escaping @Sendable () throws -> Void) { duringSave = hook }
    func identity() async throws -> String { account }
    func meetingIndex() async throws -> [CloudIndexEntry] { index.map { .init(id: $0.key, revision: $0.value) } }
    func fetchMeeting(_ id: UUID) async throws -> CloudMeetingSnapshot? { meetings[id] }
    func saveMeeting(_ meeting: Meeting, expectedRevision: String?) async throws -> CloudMeetingSnapshot {
        if failure == .manifest { throw CloudLibraryError.unavailable }
        guard meetings[meeting.id]?.revision == expectedRevision else { throw CloudLibraryError.conflict }
        serial += 1; let result = CloudMeetingSnapshot(meeting: meeting, revision: "revision-\(serial)")
        meetings[meeting.id] = result
        try duringSave?(); duringSave = nil
        return result
    }
    func saveAudio(meeting: Meeting, part: AudioPart, localURL: URL?) async throws -> CloudPartProof {
        if failure == .audio { throw CloudLibraryError.unavailable }
        let key = "\(meeting.id)-\(part.index)"
        if audio[key] == nil {
            guard let localURL else { throw CloudLibraryError.missingOriginal }
            audio[key] = try Data(contentsOf: localURL); uploads += 1
        }
        return CloudPartProof(index: part.index, sha256: failure == .receipt ? "wrong" : part.sha256,
            byteCount: Int64(audio[key]!.count), revision: "asset-stored")
    }
    func publishMeeting(_ id: UUID, revision: String) async throws -> String {
        if failure == .catalog { throw CloudLibraryError.unavailable }
        index[id] = revision; return "catalog-stored"
    }
    func downloadAudio(meetingID: UUID, part: AudioPart, destination: URL) async throws {
        downloads += 1
        guard let data = audio["\(meetingID)-\(part.index)"] else { throw CloudLibraryError.missingOriginal }
        try (failure == .download ? Data("corruption".utf8) : data).write(to: destination)
    }
    func counts() -> (Int, Int) { (uploads, downloads) }
}

final class CloudStorageTests: XCTestCase {
    private var temporary: URL!
    private var store: MeetingStore!
    private var remote: FakeCloud!
    private var cloud: CloudLibraryCoordinator!
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try MeetingStore(root: temporary.appendingPathComponent("phone"))
        remote = FakeCloud(); cloud = try CloudLibraryCoordinator(store: store, remote: remote)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }
    private func recording() throws -> Meeting {
        var meeting = Meeting(source: .watch)
        meeting.captureState = .finished; meeting.endedAt = Date(); meeting.expectedPartCount = 2
        meeting.notes = "Local note"; try store.save(meeting)
        for index in 0..<2 {
            let url = store.directory(for: meeting.id).appendingPathComponent(MeetingStore.filename(index: index))
            try Data("audio-\(index)".utf8).write(to: url)
            meeting.parts.append(.init(index: index, filename: url.lastPathComponent, offset: Double(index * 60),
                duration: 60, sha256: try MeetingStore.digest(url)))
        }
        try store.save(meeting); return try store.load(meeting.id)
    }
    private func exists(_ meeting: Meeting, _ index: Int = 0) throws -> Bool {
        FileManager.default.fileExists(atPath: try store.audioURL(meetingID: meeting.id, part: meeting.parts[index]).path)
    }
    private func syncFails() async {
        do { try await cloud.sync(); XCTFail("Expected a failure") } catch {}
    }

    func testCloudCommitEvictsAudioButRetainsMetadataAndWatchHandoff() async throws {
        let meeting = try recording(); try await cloud.sync()
        XCTAssertFalse(try exists(meeting)); XCTAssertFalse(try exists(meeting, 1))
        XCTAssertEqual(try store.load(meeting.id), meeting)
        XCTAssertEqual(try store.cachedAudioBytes(), 0)
        XCTAssertTrue(store.isCloudStored(meeting.id))
        XCTAssertNotNil(try store.storedMeetingReceipt(for: meeting.id))
    }
    func testAnyIncompleteCloudStagePreservesAllLocalOriginals() async throws {
        let meeting = try recording()
        for failure in [FakeCloud.Failure.audio, .manifest, .catalog, .receipt] {
            await remote.configure(failure: failure); await syncFails()
            XCTAssertTrue(try exists(meeting)); XCTAssertTrue(try exists(meeting, 1))
            XCTAssertNil(try store.cloudProof(for: meeting.id))
        }
    }
    func testOnDemandDownloadIsPinnedUntilItsLastConsumerFinishes() async throws {
        let meeting = try recording(); try await cloud.sync()
        let first = try await cloud.acquireAudio(meetingID: meeting.id, part: meeting.parts[0])
        let second = try await cloud.acquireAudio(meetingID: meeting.id, part: meeting.parts[0])
        XCTAssertEqual(try MeetingStore.digest(first.url), meeting.parts[0].sha256)
        try await cloud.sync(); XCTAssertTrue(try exists(meeting))
        try await cloud.releaseAudio(first); XCTAssertTrue(try exists(meeting))
        try await cloud.releaseAudio(second); XCTAssertFalse(try exists(meeting))
    }
    func testBadDownloadNeverBecomesPlayableOrOverwritesMetadata() async throws {
        let meeting = try recording(); try await cloud.sync(); await remote.configure(failure: .download)
        do { _ = try await cloud.acquireAudio(meetingID: meeting.id, part: meeting.parts[0]); XCTFail("Must reject corrupt audio") } catch {}
        XCTAssertFalse(try exists(meeting)); XCTAssertEqual(try store.load(meeting.id), meeting)
    }
    func testAnotherDeviceListsMetadataWithoutDownloadingAllRecordings() async throws {
        let meeting = try recording(); try await cloud.sync()
        let mac = try MeetingStore(root: temporary.appendingPathComponent("mac"))
        let macCloud = try CloudLibraryCoordinator(store: mac, remote: remote)
        try await macCloud.sync()
        XCTAssertEqual(try mac.load(meeting.id), meeting); XCTAssertEqual(try mac.cachedAudioBytes(), 0)
        var counts = await remote.counts(); XCTAssertEqual(counts.1, 0)
        let lease = try await macCloud.acquireAudio(meetingID: meeting.id, part: meeting.parts[1])
        XCTAssertEqual(try MeetingStore.digest(lease.url), meeting.parts[1].sha256)
        try await macCloud.releaseAudio(lease)
        counts = await remote.counts(); XCTAssertEqual(counts.1, 1); XCTAssertEqual(try mac.cachedAudioBytes(), 0)
    }
    func testAccountChangePausesInsteadOfUploadingIntoAnotherAccount() async throws {
        _ = try recording(); try await cloud.sync()
        let next = try recording(); await remote.changeAccount(); await syncFails()
        XCTAssertTrue(try exists(next)); XCTAssertFalse(store.isCloudStored(next.id))
    }
    func testOrphanAudioBlocksEvictionOfTheWholeMeeting() async throws {
        let meeting = try recording()
        let orphan = store.directory(for: meeting.id).appendingPathComponent("part-99999.caf")
        try Data("unregistered".utf8).write(to: orphan)
        await syncFails(); XCTAssertTrue(try exists(meeting)); XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
    }
    func testOfflineLocalAudioRemainsPlayableWithoutICloud() async throws {
        let meeting = try recording(); await remote.configure(failure: .audio); await syncFails()
        let lease = try await cloud.acquireAudio(meetingID: meeting.id, part: meeting.parts[0])
        try await cloud.releaseAudio(lease); XCTAssertTrue(try exists(meeting))
    }
    func testRelaunchRequiresFreshAccountBeforeUsingPersistedEvictionProof() async throws {
        let meeting = try recording(); try await cloud.sync()
        let reopened = try MeetingStore(root: store.root)
        XCTAssertFalse(reopened.isCloudStored(meeting.id)); XCTAssertNil(try reopened.storedMeetingReceipt(for: meeting.id))
        let next = try CloudLibraryCoordinator(store: reopened, remote: remote); try await next.sync()
        XCTAssertTrue(reopened.isCloudStored(meeting.id)); XCTAssertNotNil(try reopened.storedMeetingReceipt(for: meeting.id))
    }
    func testNoOpSyncDoesNotUploadOrDownloadAudioAgain() async throws {
        _ = try recording(); try await cloud.sync(); try await cloud.sync()
        let counts = await remote.counts(); XCTAssertEqual(counts.0, 2); XCTAssertEqual(counts.1, 0)
    }
    func testEditsDuringUploadAreNotOverwrittenByAcceptedSnapshot() async throws {
        let meeting = try recording(); let store = store!
        await remote.setSaveHook { try store.update(meeting.id) { $0.notes = "Edited while uploading" } }
        try await cloud.sync(); XCTAssertEqual(try store.load(meeting.id).notes, "Edited while uploading")
        try await cloud.sync()
        let saved = try await remote.fetchMeeting(meeting.id)
        XCTAssertEqual(saved?.meeting.notes, "Edited while uploading")
    }
    func testWrongAccountOrIncompleteProofCannotEvictLocalAudio() throws {
        let meeting = try recording(); store.setVerifiedCloudAccount("first-account")
        let proof = CloudStorageProof(accountID: "another-account", meetingID: meeting.id, parts: [], manifestRevision: "saved", catalogRevision: "saved")
        XCTAssertThrowsError(try store.saveCloudProof(proof, accountID: "first-account"))
        XCTAssertTrue(try exists(meeting))
    }
    func testThreeWayMergePreservesUnrelatedEditsAndTextConflicts() throws {
        var base = try recording(); base.followUps = [FollowUp(title: "Ship")]
        var local = base; local.title = "Phone title"; local.followUps[0].completed = true
        var other = base; other.notes = "Mac note"; other.followUps.append(FollowUp(title: "Review"))
        let merged = try CloudMeetingMerge.merge(base: base, local: local, remote: other)
        XCTAssertEqual(merged.title, "Phone title"); XCTAssertEqual(merged.notes, "Mac note")
        XCTAssertEqual(merged.followUps.count, 2); XCTAssertTrue(merged.followUps[0].completed)
        other.title = "Mac title"; local.notes = "Phone note"
        let conflict = try CloudMeetingMerge.merge(base: base, local: local, remote: other)
        XCTAssertTrue(conflict.notes.contains("Phone note")); XCTAssertTrue(conflict.notes.contains("Mac note")); XCTAssertTrue(conflict.notes.contains("Mac title"))
    }
}
