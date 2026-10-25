import Foundation
import CryptoKit

public enum StoreError: LocalizedError {
    case invalidPart, checksumMismatch, conflictingPart, missingMeeting, incompleteMeeting
    public var errorDescription: String? {
        switch self {
        case .invalidPart: return "录音片段格式无效，原文件已保留。"
        case .checksumMismatch: return "录音校验失败，需要重新传输。"
        case .conflictingPart: return "片段与已保存的录音冲突，未覆盖现有内容。"
        case .missingMeeting: return "找不到这场会议。"
        case .incompleteMeeting: return "录音尚未全部同步。"
        }
    }
}

/// One atomic manifest per meeting. All entry points, including WCSession callbacks, share this lock.
public final class MeetingStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSRecursiveLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

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
