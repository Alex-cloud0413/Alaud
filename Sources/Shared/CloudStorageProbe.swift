#if DEBUG && !os(watchOS)
import Foundation
import SwiftUI
import AlaudCore

/// Real-network verification in a separate iCloud Drive folder. It never reads the user's recording store.
enum CloudStorageProbe {
    static func run(verifyOnly: Bool) async throws -> String {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Alaud/CloudProbe", isDirectory: true)
        let store = try MeetingStore(root: root)
        let remote = ICloudDriveTransport(folder: "StorageValidation-v1")
        let cloud = try CloudLibraryCoordinator(store: store, remote: remote, stateFilename: ".cloud-state-drive-probe.json")
        _ = try await remote.identity()
        let serverIndex = try await remote.meetingIndex()
        if verifyOnly, serverIndex.isEmpty { throw CloudLibraryError.missingOriginal }
        if !verifyOnly, serverIndex.isEmpty, try store.list().isEmpty {
            var meeting = Meeting(title: "[验证] 合成数据云端恢复", createdAt: Date(timeIntervalSince1970: 1_700_000_000), source: .mac)
            meeting.captureState = .finished; meeting.endedAt = meeting.createdAt.addingTimeInterval(120)
            meeting.expectedPartCount = 2; meeting.transcriptState = .ready
            try store.save(meeting)
            for index in 0..<2 {
                let url = store.directory(for: meeting.id).appendingPathComponent(MeetingStore.filename(index: index))
                try Data(repeating: UInt8(17 + index), count: 4096).write(to: url)
                meeting.parts.append(AudioPart(index: index, filename: url.lastPathComponent, offset: Double(index * 60),
                    duration: 60, sha256: try MeetingStore.digest(url)))
            }
            try store.save(meeting)
        }
        try await cloud.sync()
        let before = try await cloud.cachedAudioBytes()
        guard before == 0, let meeting = try store.list().first, let part = meeting.parts.first else { throw CloudLibraryError.invalidReceipt }
        let lease = try await cloud.acquireAudio(meetingID: meeting.id, part: part)
        let downloadedBytes = try await cloud.cachedAudioBytes()
        let matches = try MeetingStore.digest(lease.url) == part.sha256
        try await cloud.releaseAudio(lease)
        let after = try await cloud.cachedAudioBytes()
        guard matches, downloadedBytes == 4096, after == 0 else { throw CloudLibraryError.invalidReceipt }
        let report: [String: Any] = ["passed": true, "backend": "iCloud Drive", "syntheticOnly": true,
            "readExistingRemoteFixture": !serverIndex.isEmpty, "verifyOnly": verifyOnly,
            "meetingCount": try store.list().count, "downloadedBytes": downloadedBytes, "hashMatches": matches,
            "cachedAudioBytesBeforeDownload": before, "cachedAudioBytesAfterRelease": after,
            "verifiedAt": ISO8601DateFormatter().string(from: Date())]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("probe-result.json"), options: .atomic)
        let text = String(decoding: data, as: UTF8.self)
        print("ALAUD_CLOUD_PROBE \(text)")
        return "iCloud 验证通过：\(downloadedBytes) bytes 下载校验一致，释放后原音缓存为 0。"
    }
}

struct CloudStorageProbeView: View {
    @State private var message = "正在用合成数据验证 iCloud…"
    var body: some View {
        VStack(spacing: 22) {
            AlaudMark(size: 56)
            Text("iCloud 存储验证").font(.title2.weight(.semibold))
            Text(message).multilineTextAlignment(.center).textSelection(.enabled)
            Text("独立测试区域，不读取真实会议，也不会启动麦克风。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                do { message = try await CloudStorageProbe.run(verifyOnly: ProcessInfo.processInfo.arguments.contains("--cloud-probe-verify-only")) }
                catch { message = error.localizedDescription; print("ALAUD_CLOUD_PROBE_FAILED \(error)") }
            }
    }
}
#endif
