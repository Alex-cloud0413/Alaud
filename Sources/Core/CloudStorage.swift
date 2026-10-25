import Foundation

public enum CloudLibraryError: LocalizedError {
    case unavailable, accountChanged, invalidReceipt, missingOriginal, conflict, oversizedMetadata
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "iCloud 暂不可用，尚未上传的原音继续保留在本机。"
        case .accountChanged: return "iCloud 账号已改变。已暂停同步，避免把原有录音上传到另一个账号。"
        case .invalidReceipt: return "云端保存确认与原音不符，本机文件已保留。"
        case .missingOriginal: return "暂时无法取得原音，请检查网络与 iCloud 账号后重试。"
        case .conflict: return "另一台设备正在修改这场会议，请稍后重试。"
        case .oversizedMetadata: return "这场会议的文字超过当前同步上限，请先导出保存。"
        }
    }
}

public struct CloudPartProof: Codable, Equatable, Sendable {
    public var index: Int
    public var sha256: String
    public var byteCount: Int64
    public var revision: String
    public init(index: Int, sha256: String, byteCount: Int64, revision: String) {
        self.index = index; self.sha256 = sha256; self.byteCount = byteCount; self.revision = revision
    }
}

/// Created only after assets, the manifest and its discoverable catalog entry are accepted by the server.
public struct CloudStorageProof: Codable, Equatable, Sendable {
    public var accountID: String
    public var meetingID: UUID
    public var parts: [CloudPartProof]
    public var manifestRevision: String
    public var catalogRevision: String
    public init(accountID: String, meetingID: UUID, parts: [CloudPartProof], manifestRevision: String, catalogRevision: String) {
        self.accountID = accountID; self.meetingID = meetingID; self.parts = parts
        self.manifestRevision = manifestRevision; self.catalogRevision = catalogRevision
    }
    public func confirms(_ meeting: Meeting, accountID current: String) -> Bool {
        guard !current.isEmpty, accountID == current, meeting.id == meetingID,
              meeting.isComplete, meeting.captureState == .finished || meeting.captureState == .interrupted,
              !manifestRevision.isEmpty, !catalogRevision.isEmpty,
              parts.count == meeting.parts.count, Set(parts.map(\.index)).count == parts.count else { return false }
        return meeting.parts.allSatisfy { part in
            parts.contains { $0.index == part.index && $0.sha256 == part.sha256 && $0.byteCount > 0 && !$0.revision.isEmpty }
        }
    }
}

public struct CloudMeetingSnapshot: Sendable {
    public var meeting: Meeting
    public var revision: String
    public var requiresWriteback: Bool
    public init(meeting: Meeting, revision: String, requiresWriteback: Bool = false) {
        self.meeting = meeting; self.revision = revision; self.requiresWriteback = requiresWriteback
    }
}

public struct CloudIndexEntry: Codable, Sendable {
    public var id: UUID
    public var revision: String
    public init(id: UUID, revision: String) { self.id = id; self.revision = revision }
}

public protocol CloudTransport: Sendable {
    func identity() async throws -> String
    func meetingIndex() async throws -> [CloudIndexEntry]
    func fetchMeeting(_ id: UUID) async throws -> CloudMeetingSnapshot?
    func saveMeeting(_ meeting: Meeting, expectedRevision: String?) async throws -> CloudMeetingSnapshot
    func saveAudio(meeting: Meeting, part: AudioPart, localURL: URL?) async throws -> CloudPartProof
    func publishMeeting(_ id: UUID, revision: String) async throws -> String
    func downloadAudio(meetingID: UUID, part: AudioPart, destination: URL) async throws
    func releaseRemoteCaches() async throws
    func localAudioCacheBytes() async throws -> Int64
}
extension CloudTransport {
    public func releaseRemoteCaches() async throws {}
    public func localAudioCacheBytes() async throws -> Int64 { 0 }
}

public struct AudioLease: Sendable {
    public let token: UUID
    public let url: URL
    public init(token: UUID, url: URL) { self.token = token; self.url = url }
}

private struct CloudState: Codable {
    var accountID: String?
    var bases: [String: Meeting] = [:]
    var revisions: [String: String] = [:]
}

/// Serializes syncing and audio leases. The store keeps metadata; originals are recoverable caches only
/// after a server proof. The transport is replaceable so failure paths can be tested without iCloud.
public actor CloudLibraryCoordinator {
    private let store: MeetingStore
    private let remote: any CloudTransport
    private var state: CloudState
    private let stateURL: URL
    private var syncing = false
    private var leases: [UUID: (UUID, Int)] = [:]
    private var activeAccount: String?

    public init(store: MeetingStore, remote: any CloudTransport, stateFilename: String = ".cloud-state.json") throws {
        self.store = store; self.remote = remote
        guard stateFilename == (stateFilename as NSString).lastPathComponent, stateFilename.hasPrefix(".") else { throw StoreError.invalidPart }
        stateURL = store.root.appendingPathComponent(stateFilename)
        state = FileManager.default.fileExists(atPath: stateURL.path)
            ? try JSONDecoder().decode(CloudState.self, from: Data(contentsOf: stateURL)) : CloudState()
    }

    public func accountDidChange() {
        activeAccount = nil; store.setVerifiedCloudAccount(nil)
    }

    public func sync(progress: (@Sendable (String) -> Void)? = nil) async throws {
        guard !syncing else { return }
        syncing = true; defer { syncing = false }
        let account = try await checkAccount()
        progress?("正在同步录音库…")
        let index = try await remote.meetingIndex()
        var writeback = Set<UUID>()
        for entry in index {
            let id = entry.id
            if state.revisions[id.uuidString] == entry.revision, store.contains(id) { continue }
            try Task.checkCancellation()
            guard let snapshot = try await remote.fetchMeeting(id) else { continue }
            if snapshot.requiresWriteback { writeback.insert(id) }
            try store.mergeCloudMeeting(snapshot.meeting, base: state.bases[id.uuidString])
            state.bases[id.uuidString] = snapshot.meeting; state.revisions[id.uuidString] = snapshot.revision
            try saveState()
        }
        for original in try store.list() where original.isComplete && original.captureState != .recording && original.captureState != .paused {
            try Task.checkCancellation()
            let published = index.contains { $0.id == original.id }
            let knownProof = try store.cloudProof(for: original.id)
            var normalized = original
            if normalized.transcriptState == .processing { normalized.transcriptState = .waiting }
            if published, !writeback.contains(original.id), state.bases[original.id.uuidString] == normalized, store.isCloudStored(original.id) {
                try evict(original.id); continue
            }
            var proofs: [CloudPartProof] = []
            for part in original.parts {
                if published, let knownProof, knownProof.confirms(original, accountID: account),
                   let proof = knownProof.parts.first(where: { $0.index == part.index }) {
                    proofs.append(proof); continue
                }
                progress?("正在保存原音 \(part.index + 1) / \(original.parts.count)…")
                let url = try store.audioURL(meetingID: original.id, part: part)
                let exists = FileManager.default.fileExists(atPath: url.path)
                if exists, try MeetingStore.digest(url) != part.sha256 { throw StoreError.checksumMismatch }
                let proof = try await remote.saveAudio(meeting: original, part: part, localURL: exists ? url : nil)
                guard proof.index == part.index, proof.sha256 == part.sha256, proof.byteCount > 0, !proof.revision.isEmpty else {
                    throw CloudLibraryError.invalidReceipt
                }
                proofs.append(proof)
            }
            var accepted: CloudMeetingSnapshot?
            for attempt in 0..<3 {
                let current = try store.load(original.id)
                var outgoing = current
                if outgoing.transcriptState == .processing { outgoing.transcriptState = .waiting }
                if !writeback.contains(original.id), state.bases[original.id.uuidString] == outgoing, let revision = state.revisions[original.id.uuidString] {
                    accepted = CloudMeetingSnapshot(meeting: outgoing, revision: revision); break
                }
                do {
                    accepted = try await remote.saveMeeting(outgoing, expectedRevision: state.revisions[original.id.uuidString])
                    break
                } catch CloudLibraryError.conflict {
                    guard attempt < 2, let latest = try await remote.fetchMeeting(original.id) else { throw CloudLibraryError.conflict }
                    try store.mergeCloudMeeting(latest.meeting, base: state.bases[original.id.uuidString])
                    if latest.requiresWriteback { writeback.insert(original.id) }
                    state.bases[original.id.uuidString] = latest.meeting; state.revisions[original.id.uuidString] = latest.revision
                    try saveState()
                }
            }
            guard let accepted, !accepted.revision.isEmpty else { throw CloudLibraryError.invalidReceipt }
            let catalogRevision = try await remote.publishMeeting(original.id, revision: accepted.revision)
            let confirmedAccount = try await checkAccount()
            guard account == confirmedAccount, account == activeAccount else { throw CloudLibraryError.accountChanged }
            let proof = CloudStorageProof(accountID: account, meetingID: original.id, parts: proofs,
                manifestRevision: accepted.revision, catalogRevision: catalogRevision)
            guard proof.confirms(try store.load(original.id), accountID: account) else { throw CloudLibraryError.invalidReceipt }
            // Do not overwrite edits made while the network operation was suspended.
            state.bases[original.id.uuidString] = accepted.meeting; state.revisions[original.id.uuidString] = accepted.revision
            try saveState()
            try store.saveCloudProof(proof, accountID: account)
            try evict(original.id)
        }
        try await remote.releaseRemoteCaches()
        progress?("已同步到 iCloud")
    }

    public func acquireAudio(meetingID: UUID, part: AudioPart) async throws -> AudioLease {
        let token = UUID(); leases[token] = (meetingID, part.index)
        do {
            let meeting = try store.load(meetingID)
            guard meeting.parts.contains(where: { $0.index == part.index && $0.sha256 == part.sha256 }) else { throw StoreError.invalidPart }
            let url = try store.audioURL(meetingID: meetingID, part: part)
            if !FileManager.default.fileExists(atPath: url.path) {
                _ = try await checkAccount()
                let temporary = store.root.appendingPathComponent(".download-\(token.uuidString)")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try await remote.downloadAudio(meetingID: meetingID, part: part, destination: temporary)
                try store.installCloudAudio(from: temporary, meetingID: meetingID, part: part)
            }
            guard try MeetingStore.digest(url) == part.sha256 else { throw StoreError.checksumMismatch }
            return AudioLease(token: token, url: url)
        } catch { leases.removeValue(forKey: token); throw error }
    }

    public func releaseAudio(_ lease: AudioLease) throws {
        guard let (id, _) = leases.removeValue(forKey: lease.token) else { return }
        try evict(id)
    }

    public func releaseCaches() async throws {
        for meeting in try store.list() { try evict(meeting.id) }
        try await remote.releaseRemoteCaches()
    }
    public func cachedAudioBytes() async throws -> Int64 { try await store.cachedAudioBytes() + remote.localAudioCacheBytes() }

    private func evict(_ id: UUID) throws {
        guard let account = activeAccount else { return }
        let protected = Set(leases.values.filter { $0.0 == id }.map { $0.1 })
        try store.evictCloudAudio(meetingID: id, accountID: account, protectedIndices: protected)
    }
    private func checkAccount() async throws -> String {
        let account: String
        do { account = try await remote.identity() }
        catch { accountDidChange(); throw error }
        guard !account.isEmpty else { throw CloudLibraryError.unavailable }
        if let bound = state.accountID, bound != account { accountDidChange(); throw CloudLibraryError.accountChanged }
        state.accountID = account; activeAccount = account
        store.setVerifiedCloudAccount(account); try saveState()
        return account
    }
    private func saveState() throws { try JSONEncoder().encode(state).write(to: stateURL, options: .atomic) }
}
