import Foundation
import CryptoKit

public enum StoreError: LocalizedError {
    case invalidPart, checksumMismatch, conflictingPart, missingMeeting, incompleteMeeting, unconfirmedCleanup
    public var errorDescription: String? {
        switch self {
        case .invalidPart: return "录音片段格式无效，原文件已保留。"
        case .checksumMismatch: return "录音校验失败，需要重新传输。"
        case .conflictingPart: return "片段与已保存的录音冲突，未覆盖现有内容。"
        case .missingMeeting: return "找不到这场会议。"
        case .incompleteMeeting: return "录音尚未全部同步。"
        case .unconfirmedCleanup: return "完整保存确认与本地录音不符，手表原音继续保留。"
        }
    }
}

/// One atomic manifest per meeting. All entry points, including WCSession callbacks, share this lock.
public final class MeetingStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSRecursiveLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var verifiedCloudAccount: String?

    public init(root: URL) throws {
        self.root = root
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS) || os(watchOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        #endif
    }

    private func synchronized<T>(_ action: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try action()
    }

    public func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func audioURL(meetingID: UUID, part: AudioPart) throws -> URL {
        guard Self.valid(part) else { throw StoreError.invalidPart }
        return directory(for: meetingID).appendingPathComponent(part.filename)
    }
    public static func filename(index: Int) -> String { String(format: "part-%05d.caf", index) }

    public func load(_ id: UUID) throws -> Meeting {
        try synchronized { try decoder.decode(Meeting.self, from: Data(contentsOf: manifestURL(id))) }
    }

    public func contains(_ id: UUID) -> Bool {
        synchronized { FileManager.default.fileExists(atPath: manifestURL(id).path) }
    }

    public func list() throws -> [Meeting] {
        try synchronized {
            let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            return try directories.compactMap { directory -> Meeting? in
                guard let id = UUID(uuidString: directory.lastPathComponent) else { return nil }
                return try load(id)
            }.sorted { $0.createdAt > $1.createdAt }
        }
    }

    public func save(_ meeting: Meeting) throws {
        try synchronized {
            guard meeting.parts.allSatisfy(Self.valid), meeting.schemaVersion == 1 else { throw StoreError.invalidPart }
            try FileManager.default.createDirectory(at: directory(for: meeting.id), withIntermediateDirectories: true)
            try encoder.encode(meeting).write(to: manifestURL(meeting.id), options: .atomic)
        }
    }

    @discardableResult
    public func update(_ id: UUID, _ change: (inout Meeting) throws -> Void) throws -> Meeting {
        try synchronized { var meeting = try load(id); try change(&meeting); try save(meeting); return meeting }
    }

    public func append(_ part: AudioPart, to id: UUID) throws {
        try update(id) { meeting in
            guard Self.valid(part) else { throw StoreError.invalidPart }
            if let existing = meeting.parts.first(where: { $0.index == part.index }) {
                guard existing.sha256 == part.sha256 else { throw StoreError.conflictingPart }; return
            }
            meeting.parts.append(part); meeting.parts.sort { $0.index < $1.index }
        }
    }

    public func setVerifiedCloudAccount(_ accountID: String?) { synchronized { verifiedCloudAccount = accountID } }

    public func mergeCloudMeeting(_ remote: Meeting, base: Meeting?) throws {
        try synchronized {
            guard remote.isComplete, remote.schemaVersion == 1, remote.parts.allSatisfy(Self.valid),
                  remote.captureState == .finished || remote.captureState == .interrupted else { throw StoreError.invalidPart }
            if contains(remote.id) {
                try save(CloudMeetingMerge.merge(base: base, local: load(remote.id), remote: remote))
            } else { try save(remote) }
        }
    }

    public func cloudProof(for id: UUID) throws -> CloudStorageProof? {
        try synchronized {
            let url = directory(for: id).appendingPathComponent("cloud-receipt.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try decoder.decode(CloudStorageProof.self, from: Data(contentsOf: url))
        }
    }
    public func isCloudStored(_ id: UUID) -> Bool {
        synchronized {
            guard let account = verifiedCloudAccount, let proof = try? cloudProof(for: id), let meeting = try? load(id) else { return false }
            return proof.confirms(meeting, accountID: account)
        }
    }
    public func saveCloudProof(_ proof: CloudStorageProof, accountID: String) throws {
        try synchronized {
            guard verifiedCloudAccount == accountID, proof.confirms(try load(proof.meetingID), accountID: accountID) else { throw CloudLibraryError.invalidReceipt }
            let url = directory(for: proof.meetingID).appendingPathComponent("cloud-receipt.json")
            try encoder.encode(proof).write(to: url, options: .atomic)
            try Self.synchronizeFile(url)
        }
    }

    /// Remove only recoverable originals. Metadata and pending edits remain local.
    public func evictCloudAudio(meetingID id: UUID, accountID: String, protectedIndices: Set<Int>) throws {
        try synchronized {
            guard verifiedCloudAccount == accountID, let proof = try cloudProof(for: id) else { return }
            let meeting = try load(id)
            guard proof.confirms(meeting, accountID: accountID) else { throw CloudLibraryError.invalidReceipt }
            let entries = try FileManager.default.contentsOfDirectory(at: directory(for: id), includingPropertiesForKeys: nil)
            let registered = Set(meeting.parts.map(\.filename))
            guard entries.filter({ ["caf", "wav", "m4a"].contains($0.pathExtension.lowercased()) })
                .allSatisfy({ registered.contains($0.lastPathComponent) }) else { throw CloudLibraryError.invalidReceipt }
            // Check the complete candidate set before deleting any part.
            let candidates = try meeting.parts.filter { !protectedIndices.contains($0.index) }.compactMap { part -> URL? in
                let url = try audioURL(meetingID: id, part: part)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                guard try Self.digest(url) == part.sha256 else { throw StoreError.checksumMismatch }
                return url
            }
            for url in candidates { try FileManager.default.removeItem(at: url) }
        }
    }

    public func installCloudAudio(from incoming: URL, meetingID: UUID, part: AudioPart) throws {
        try synchronized {
            let meeting = try load(meetingID)
            guard meeting.parts.contains(where: { $0.index == part.index && $0.sha256 == part.sha256 }),
                  try Self.digest(incoming) == part.sha256 else { throw StoreError.checksumMismatch }
            let destination = try audioURL(meetingID: meetingID, part: part)
            if FileManager.default.fileExists(atPath: destination.path) {
                guard try Self.digest(destination) == part.sha256 else { throw StoreError.conflictingPart }; return
            }
            let staging = directory(for: meetingID).appendingPathComponent(UUID().uuidString + ".incoming")
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.copyItem(at: incoming, to: staging)
            try Self.synchronizeFile(staging)
            try FileManager.default.moveItem(at: staging, to: destination)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var copy = destination; try copy.setResourceValues(values)
        }
    }

    public func cachedAudioBytes() throws -> Int64 {
        try synchronized {
            try list().flatMap { meeting in try meeting.parts.map { try audioURL(meetingID: meeting.id, part: $0) } }
                .reduce(Int64(0)) { total, url in
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                    return total + size
                }
        }
    }

    /// Copy and commit synchronously before returning from didReceive(file:). Ack only after this succeeds.
    public func importPart(from incoming: URL, envelope: TransferEnvelope) throws {
        try synchronized {
            let part = envelope.part
            guard Self.valid(part), envelope.meeting.source == .watch else { throw StoreError.invalidPart }
            guard try Self.digest(incoming) == part.sha256 else { throw StoreError.checksumMismatch }
            let id = envelope.meeting.id
            var meeting = try existingOrNew(envelope.meeting)
            if let existing = meeting.parts.first(where: { $0.index == part.index }), existing.sha256 != part.sha256 {
                throw StoreError.conflictingPart
            }
            let destination = try audioURL(meetingID: id, part: part)
            try FileManager.default.createDirectory(at: directory(for: id), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                guard try Self.digest(destination) == part.sha256 else { throw StoreError.conflictingPart }
            } else {
                let staging = directory(for: id).appendingPathComponent(UUID().uuidString + ".incoming")
                try FileManager.default.copyItem(at: incoming, to: staging)
                try FileManager.default.moveItem(at: staging, to: destination)
            }
            var received = part; received.receivedByPhone = true
            meeting.parts.removeAll { $0.index == part.index }; meeting.parts.append(received)
            meeting.parts.sort { $0.index < $1.index }
            mergeCapture(from: envelope.meeting, into: &meeting)
            try save(meeting)
        }
    }

    public func importFinalManifest(_ incoming: Meeting) throws {
        try synchronized {
            guard incoming.source == .watch, incoming.schemaVersion == 1,
                  let count = incoming.expectedPartCount, count >= 0, count <= 100_000,
                  incoming.endedAt != nil else { throw StoreError.invalidPart }
            var meeting = try existingOrNew(incoming)
            mergeCapture(from: incoming, into: &meeting)
            try save(meeting)
        }
    }

    /// Only the phone calls this. A transferred file or a saved final manifest alone is insufficient.
    public func storedMeetingReceipt(for id: UUID) throws -> StoredMeetingReceipt? {
        try synchronized {
            guard contains(id) else { return nil }
            let meeting = try load(id)
            guard meeting.source == .watch, meeting.isComplete,
                  meeting.captureState == .finished || meeting.captureState == .interrupted else { return nil }
            for part in meeting.parts {
                let url = try audioURL(meetingID: id, part: part)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    // Cloud-backed originals may already be evicted. A newly verified account and
                    // full server proof still let the phone safely complete the watch handoff.
                    guard isCloudStored(id) else { return nil }
                    continue
                }
                guard try Self.digest(url) == part.sha256 else { throw StoreError.checksumMismatch }
                try Self.synchronizeFile(url)
            }
            try Self.synchronizeFile(manifestURL(id))
            return StoredMeetingReceipt(meeting: meeting)
        }
    }

    /// Used for pre-upgrade meetings whose legacy acknowledgements were already saved on the watch.
    public func missingPartIndices(from incoming: Meeting) throws -> [Int] {
        try synchronized {
            guard incoming.source == .watch, incoming.isComplete, incoming.parts.allSatisfy(Self.valid) else { throw StoreError.invalidPart }
            guard contains(incoming.id) else { return incoming.parts.map(\.index) }
            if let account = verifiedCloudAccount, let proof = try cloudProof(for: incoming.id), proof.confirms(incoming, accountID: account) { return [] }
            let local = try load(incoming.id)
            return try incoming.parts.compactMap { part in
                guard let saved = local.parts.first(where: { $0.index == part.index }) else { return part.index }
                guard saved.sha256 == part.sha256 else { throw StoreError.conflictingPart }
                let url = try audioURL(meetingID: incoming.id, part: part)
                guard FileManager.default.fileExists(atPath: url.path) else { return part.index }
                guard try Self.digest(url) == part.sha256 else { throw StoreError.checksumMismatch }
                return nil
            }
        }
    }

    /// Only the watch calls this. Atomically leave the queue before deleting, so an interrupted cleanup
    /// cannot leave a half-deleted UUID directory that prevents the next launch from opening its store.
    @discardableResult
    public func removeConfirmedWatchCopy(_ receipt: StoredMeetingReceipt) throws -> Bool {
        try synchronized {
            guard contains(receipt.meetingID) else { return false } // duplicate or late receipt
            let meeting = try load(receipt.meetingID)
            guard receipt.confirms(meeting) else { throw StoreError.unconfirmedCleanup }
            let directory = directory(for: meeting.id)
            let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let originals = entries.filter { ["caf", "m4a", "wav"].contains($0.pathExtension.lowercased()) }
            let expected = Set(meeting.parts.map(\.filename))
            guard originals.allSatisfy({ expected.contains($0.lastPathComponent) }) else { throw StoreError.unconfirmedCleanup }
            // No transport receipt can authorize dropping an unregistered/orphaned audio file.
            let cleanup = root.appendingPathComponent(".cleanup", isDirectory: true)
            try FileManager.default.createDirectory(at: cleanup, withIntermediateDirectories: true)
            let staged = cleanup.appendingPathComponent(meeting.id.uuidString, isDirectory: true)
            try FileManager.default.moveItem(at: directory, to: staged)
            try FileManager.default.removeItem(at: staged)
            return true
        }
    }

    /// The .cleanup rename is itself the persisted authorization; retry removal after a crash.
    public func finishConfirmedCleanup() throws {
        try synchronized {
            let cleanup = root.appendingPathComponent(".cleanup", isDirectory: true)
            guard FileManager.default.fileExists(atPath: cleanup.path) else { return }
            for entry in try FileManager.default.contentsOfDirectory(at: cleanup, includingPropertiesForKeys: nil)
                where UUID(uuidString: entry.lastPathComponent) != nil {
                try FileManager.default.removeItem(at: entry)
            }
        }
    }

    private static func synchronizeFile(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func existingOrNew(_ incoming: Meeting) throws -> Meeting {
        if FileManager.default.fileExists(atPath: manifestURL(incoming.id).path) { return try load(incoming.id) }
        var new = Meeting(id: incoming.id, title: incoming.title, createdAt: incoming.createdAt, source: .watch)
        new.gaps = incoming.gaps
        return new
    }
    private func mergeCapture(from incoming: Meeting, into local: inout Meeting) {
        // Late audio must never reopen an already finalized meeting or erase phone-side edits.
        if incoming.endedAt != nil && local.endedAt == nil {
            local.endedAt = incoming.endedAt; local.expectedPartCount = incoming.expectedPartCount
            local.captureState = incoming.captureState; local.gaps = incoming.gaps
        }
    }
    private func manifestURL(_ id: UUID) -> URL { directory(for: id).appendingPathComponent("meeting.json") }
    private static func valid(_ part: AudioPart) -> Bool {
        part.index >= 0 && part.index < 100_000 && part.filename == filename(index: part.index)
            && part.duration.isFinite && part.duration > 0 && part.offset.isFinite && part.offset >= 0
            && part.sha256.count == 64 && part.sha256.allSatisfy { $0.isHexDigit }
    }
    public static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty { hash.update(data: block) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
