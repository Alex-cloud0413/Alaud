#if !os(watchOS)
import Foundation
import CryptoKit
import AlaudCore

private struct DriveCommit: Codable {
    var meeting: Meeting
    var parents: [String]
}
private struct DriveHead: Codable {
    var id: UUID
    var revision: String
    var parents: [String]
}
private struct DriveIdentity: Codable { var token: Data; var id: String }

/// Immutable, content-addressed audio and metadata commits. A tiny head is published only after the
/// referenced body is uploaded. Concurrent edits form branches, then a merge commit preserves both.
/// There is no mutable global catalog and no dependence on CloudKit query indexes or custom zones.
actor ICloudDriveTransport: CloudTransport {
    static let containerIdentifier = "iCloud.com.gaoyiming.alaud"
    private let folder: String
    private var root: URL?
    private var account: String?
    private var headsCache: [String: DriveHead] = [:]
    private var protectedCloudURLs = Set<URL>()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }()
    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    init(folder: String = "Library") { self.folder = folder }

    func identity() async throws -> String {
        guard let token = FileManager.default.ubiquityIdentityToken,
              let container = FileManager.default.url(forUbiquityContainerIdentifier: Self.containerIdentifier) else {
            throw CloudLibraryError.unavailable
        }
        let identityURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Alaud/drive-identities.json")
        var identities: [DriveIdentity] = []
        if FileManager.default.fileExists(atPath: identityURL.path) { identities = try decoder.decode([DriveIdentity].self, from: Data(contentsOf: identityURL)) }
        let tokenData = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false)
        var matching: String?
        for entry in identities {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: entry.token); unarchiver.requiresSecureCoding = false
            let old = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
            unarchiver.finishDecoding()
            if token.isEqual(old) { matching = entry.id; break }
        }
        let id = matching ?? "drive-\(UUID().uuidString)"
        if let account, account != id { throw CloudLibraryError.accountChanged }
        if matching == nil {
            identities.append(DriveIdentity(token: tokenData, id: id))
            try FileManager.default.createDirectory(at: identityURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(identities).write(to: identityURL, options: .atomic)
        }
        account = id
        if root == nil {
            let value = container.appendingPathComponent("Documents/\(folder)", isDirectory: true)
            try FileManager.default.createDirectory(at: value.appendingPathComponent("Meetings"), withIntermediateDirectories: true)
            root = value
        }
        return id
    }

    func meetingIndex() async throws -> [CloudIndexEntry] {
        _ = try await identity()
        let directory = root!.appendingPathComponent("Meetings")
        return try await FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).asyncCompactMap { url in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            let heads = try await self.heads(for: id)
            let tips = self.tips(heads)
            guard !tips.isEmpty else { return nil }
            return CloudIndexEntry(id: id, revision: tips.map(\.revision).sorted().joined(separator: "+"))
        }
    }

    func fetchMeeting(_ id: UUID) async throws -> CloudMeetingSnapshot? {
        let all = try await heads(for: id), tips = tips(all)
        guard let first = tips.first else { return nil }
        var merged = try await commit(id: id, revision: first.revision).meeting
        let baseID = commonAncestor(tips: tips, all: all)
        let base = try await baseID.asyncMap { try await self.commit(id: id, revision: $0).meeting }
        for head in tips.dropFirst() {
            let other = try await commit(id: id, revision: head.revision).meeting
            merged = try CloudMeetingMerge.merge(base: base, local: merged, remote: other)
        }
        return CloudMeetingSnapshot(meeting: merged, revision: tips.map(\.revision).sorted().joined(separator: "+"), requiresWriteback: tips.count > 1)
    }

    func saveMeeting(_ meeting: Meeting, expectedRevision: String?) async throws -> CloudMeetingSnapshot {
        _ = try await identity()
        let current = tips(try await heads(for: meeting.id)).map(\.revision).sorted()
        let revision = current.isEmpty ? nil : current.joined(separator: "+")
        guard revision == expectedRevision else { throw CloudLibraryError.conflict }
        let body = DriveCommit(meeting: meeting, parents: current)
        let data = try encoder.encode(body), hash = digest(data)
        let url = meetingRoot(meeting.id).appendingPathComponent("Snapshots/\(hash).json")
        try await writeImmutable(data, to: url)
        // Only the immutable uploaded body, not a local queued write, is accepted.
        return CloudMeetingSnapshot(meeting: meeting, revision: hash)
    }

    func publishMeeting(_ id: UUID, revision: String) async throws -> String {
        _ = try await identity()
        let body = try await commit(id: id, revision: revision)
        let marker = DriveHead(id: id, revision: revision, parents: body.parents)
        let data = try encoder.encode(marker)
        try await writeImmutable(data, to: meetingRoot(id).appendingPathComponent("Heads/\(revision).json"))
        return digest(data)
    }

    func saveAudio(meeting: Meeting, part: AudioPart, localURL: URL?) async throws -> CloudPartProof {
        _ = try await identity()
        let url = audioURL(id: meeting.id, part: part)
        let proofURL = url.appendingPathExtension("json")
        if cloudExists(proofURL), cloudExists(url) {
            let data = try await read(proofURL)
            let proof = try decoder.decode(CloudPartProof.self, from: data)
            guard proof.index == part.index, proof.sha256 == part.sha256, proof.byteCount > 0 else { throw CloudLibraryError.invalidReceipt }
            if let localURL {
                guard try MeetingStore.digest(localURL) == proof.sha256,
                      (try FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.int64Value == proof.byteCount else { throw CloudLibraryError.invalidReceipt }
            }
            try await waitForUpload(proofURL)
            try await waitForUpload(url)
            try? FileManager.default.evictUbiquitousItem(at: url)
            return proof
        }
        guard let localURL, try MeetingStore.digest(localURL) == part.sha256,
              let size = (try FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.int64Value else { throw CloudLibraryError.missingOriginal }
        if !cloudExists(url) { try coordinatedCopy(from: localURL, to: url) }
        try await waitForUpload(url)
        let proof = CloudPartProof(index: part.index, sha256: part.sha256, byteCount: size, revision: "drive-\(part.sha256)")
        try await writeImmutable(encoder.encode(proof), to: proofURL)
        try? FileManager.default.evictUbiquitousItem(at: url)
        return proof
    }

    func downloadAudio(meetingID: UUID, part: AudioPart, destination: URL) async throws {
        _ = try await identity()
        let url = audioURL(id: meetingID, part: part)
        protectedCloudURLs.insert(url)
        defer { protectedCloudURLs.remove(url); try? FileManager.default.evictUbiquitousItem(at: url) }
        try await download(url)
        guard try MeetingStore.digest(url) == part.sha256 else { throw StoreError.checksumMismatch }
        var error: NSError?; var failure: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { readable in
            do { try FileManager.default.copyItem(at: readable, to: destination) } catch { failure = error }
        }
        if let failure { throw failure }; if let error { throw error }
    }

    func releaseRemoteCaches() async throws {
        for url in try audioFiles() where !protectedCloudURLs.contains(url) {
            if (try? freshValues(url).ubiquitousItemIsUploaded) == true { try? FileManager.default.evictUbiquitousItem(at: url) }
        }
    }
    func localAudioCacheBytes() async throws -> Int64 {
        try audioFiles().reduce(0) { total, url in
            let values = try freshValues(url)
            if values.ubiquitousItemDownloadingStatus != .notDownloaded, FileManager.default.fileExists(atPath: url.path) {
                return total + Int64(values.fileSize ?? 0)
            }
            return total
        }
    }

    private func heads(for id: UUID) async throws -> [DriveHead] {
        let directory = meetingRoot(id).appendingPathComponent("Heads")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).map(canonical))
        var result: [DriveHead] = []
        for listed in urls {
            let url = canonical(listed)
            guard url.pathExtension == "json" else { continue }
            if let saved = headsCache[url.path] { result.append(saved); continue }
            let data = try await read(url)
            let head = try decoder.decode(DriveHead.self, from: data)
            guard head.id == id, head.revision == url.deletingPathExtension().lastPathComponent,
                  validHash(head.revision), head.parents.allSatisfy(validHash) else { throw CloudLibraryError.invalidReceipt }
            result.append(head); headsCache[url.path] = head
        }
        return result
    }
    private func tips(_ all: [DriveHead]) -> [DriveHead] {
        let parents = Set(all.flatMap(\.parents))
        return all.filter { !parents.contains($0.revision) }.sorted { $0.revision < $1.revision }
    }
    private func commonAncestor(tips: [DriveHead], all: [DriveHead]) -> String? {
        guard tips.count > 1 else { return nil }
        let nodes = Dictionary(uniqueKeysWithValues: all.map { ($0.revision, $0) })
        let distances = tips.map { tip -> [String: Int] in
            var found = [tip.revision: 0], queue = [(tip.revision, 0)], offset = 0
            while offset < queue.count {
                let (id, depth) = queue[offset]; offset += 1
                for parent in nodes[id]?.parents ?? [] where found[parent] == nil { found[parent] = depth + 1; queue.append((parent, depth + 1)) }
            }
            return found
        }
        let shared = distances.dropFirst().reduce(Set(distances[0].keys)) { $0.intersection($1.keys) }
        return shared.sorted { lhs, rhs in
            let a = distances.reduce(0) { $0 + ($1[lhs] ?? 0) }
            let b = distances.reduce(0) { $0 + ($1[rhs] ?? 0) }
            return a == b ? lhs < rhs : a < b
        }.first
    }
    private func commit(id: UUID, revision: String) async throws -> DriveCommit {
        guard validHash(revision) else { throw CloudLibraryError.invalidReceipt }
        let url = meetingRoot(id).appendingPathComponent("Snapshots/\(revision).json")
        let data = try await read(url)
        guard digest(data) == revision else { throw StoreError.checksumMismatch }
        let body = try decoder.decode(DriveCommit.self, from: data)
        guard body.meeting.id == id, body.meeting.isComplete, body.parents.allSatisfy(validHash) else { throw CloudLibraryError.invalidReceipt }
        try? FileManager.default.evictUbiquitousItem(at: url)
        return body
    }
    private func read(_ url: URL) async throws -> Data {
        try await download(url)
        var error: NSError?; var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { readable in result = Result { try Data(contentsOf: readable) } }
        if let error { throw error }; guard let result else { throw CloudLibraryError.unavailable }
        return try result.get()
    }
    private func download(_ url: URL) async throws {
        guard cloudExists(url) else { throw CloudLibraryError.missingOriginal }
        if FileManager.default.isUbiquitousItem(at: url) { try FileManager.default.startDownloadingUbiquitousItem(at: url) }
        for _ in 0..<120 {
            try Task.checkCancellation()
            let values = try freshValues(url)
            if let error = values.ubiquitousItemDownloadingError { throw error }
            if values.ubiquitousItemDownloadingStatus == .current || values.ubiquitousItemDownloadingStatus == .downloaded { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw CloudLibraryError.unavailable
    }
    private func writeImmutable(_ data: Data, to url: URL) async throws {
        if cloudExists(url) {
            guard try await read(url) == data else { throw CloudLibraryError.invalidReceipt }
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: staging) }
            try data.write(to: staging, options: .atomic)
            try FileManager.default.setUbiquitous(true, itemAt: staging, destinationURL: url)
        }
        try await waitForUpload(url)
    }
    private func coordinatedCopy(from source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        try FileManager.default.setUbiquitous(true, itemAt: staging, destinationURL: destination)
    }
    private func waitForUpload(_ url: URL) async throws {
        // Poll only outside coordinated read/write blocks; each check uses fresh resource values.
        for _ in 0..<120 {
            try Task.checkCancellation()
            do {
                let values = try freshValues(url)
                if let error = values.ubiquitousItemUploadingError { throw error }
                if values.isUbiquitousItem == true, values.ubiquitousItemIsUploaded == true, values.ubiquitousItemIsUploading != true { return }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && [4355, 260].contains(error.code) {
                // The ubiquitous item may not have reached the metadata service yet.
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw CloudLibraryError.unavailable
    }
    private func freshValues(_ url: URL) throws -> URLResourceValues {
        var fresh = URL(fileURLWithPath: url.path); fresh.removeAllCachedResourceValues()
        return try fresh.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
            .ubiquitousItemUploadingErrorKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey, .fileSizeKey])
    }
    private func audioFiles() throws -> [URL] {
        guard let root, let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent("Audio"), includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { ($0 as? URL).map(canonical) }.filter { $0.pathExtension == "caf" }
    }
    private func meetingRoot(_ id: UUID) -> URL { root!.appendingPathComponent("Meetings/\(id.uuidString)", isDirectory: true) }
    private func audioURL(id: UUID, part: AudioPart) -> URL { root!.appendingPathComponent("Audio/\(id.uuidString)/\(part.index)-\(part.sha256).caf") }
    private func cloudExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || FileManager.default.isUbiquitousItem(at: url)
            || FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud").path)
    }
    private func canonical(_ url: URL) -> URL {
        let name = url.lastPathComponent
        return name.hasPrefix(".") && name.hasSuffix(".icloud") ? url.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst().dropLast(7))) : url
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func validHash(_ value: String) -> Bool { value.count == 64 && value.allSatisfy(\.isHexDigit) }
}

private extension Array {
    func asyncCompactMap<T>(_ transform: (Element) async throws -> T?) async rethrows -> [T] {
        var result: [T] = []; for value in self { if let item = try await transform(value) { result.append(item) } }; return result
    }
}
private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        switch self { case .some(let value): return try await transform(value); case .none: return nil }
    }
}
#endif
