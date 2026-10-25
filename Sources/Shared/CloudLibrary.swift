#if !os(watchOS)
import Foundation
import Combine
import AlaudCore
#if os(iOS)
import UIKit
import BackgroundTasks
#endif

@MainActor
final class CloudLibrary: ObservableObject {
    @Published private(set) var status = "等待连接 iCloud"
    @Published private(set) var isSyncing = false
    @Published private(set) var lastIssue: String?
    @Published private(set) var diagnosticDetails: String?
    @Published private(set) var lastSync: Date?
    @Published private(set) var cacheBytes: Int64 = 0
    var onSynchronized: (() -> Void)?
    let coordinator: CloudLibraryCoordinator
    private let store: MeetingStore
    private let demonstration: Bool
    private var scheduled: Task<Void, Never>?
    private var needsAnotherSync = false
    private var observer: NSObjectProtocol?
    private let exports: URL

    init(store: MeetingStore) throws {
        self.store = store
        demonstration = ProcessInfo.processInfo.arguments.contains("--demo") || ProcessInfo.processInfo.arguments.contains("--cloud-probe")
        let transport: any CloudTransport
        #if targetEnvironment(simulator)
        transport = UnavailableCloudTransport()
        #else
        transport = demonstration ? UnavailableCloudTransport() : ICloudDriveTransport()
        #endif
        coordinator = try CloudLibraryCoordinator(store: store, remote: transport, stateFilename: ".cloud-state-drive.json")
        exports = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Alaud/Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        cleanOldExports(); refreshCacheSize()
        observer = NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.coordinator.accountDidChange(); self.scheduleSync()
            }
        }
        if demonstration { status = "演示录音库 · 仅合成原音" }
    }

    func scheduleSync() {
        guard !demonstration else { return }
        if isSyncing { needsAnotherSync = true; return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(800)); try Task.checkCancellation() }
            catch { return }
            self?.scheduled = nil; await self?.sync()
        }
        scheduleBackgroundSync()
    }

    func sync() async {
        guard !demonstration else { return }
        guard !isSyncing else { needsAnotherSync = true; return }
        isSyncing = true; lastIssue = nil
        #if os(iOS)
        var background: UIBackgroundTaskIdentifier = .invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "Save recordings to iCloud") {
            Task { @MainActor in
                if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid }
            }
        }
        #endif
        defer {
            isSyncing = false; refreshCacheSize(); onSynchronized?()
            #if os(iOS)
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            #endif
            if needsAnotherSync { needsAnotherSync = false; scheduleSync() }
        }
        do {
            try await coordinator.sync { [weak self] message in Task { @MainActor in self?.status = message } }
            lastSync = Date(); status = "已同步到 iCloud"
        } catch {
            #if DEBUG
            diagnosticDetails = String(describing: error)
            let diagnostic = ["description": String(describing: error), "stage": status]
            if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: store.root.appendingPathComponent(".cloud-diagnostics.json"), options: .atomic)
            }
            #endif
            lastIssue = error.localizedDescription
            status = "同步未完成"
        }
    }

    func acquireAudio(meetingID: UUID, part: AudioPart) async throws -> AudioLease {
        let lease = try await coordinator.acquireAudio(meetingID: meetingID, part: part)
        refreshCacheSize(); return lease
    }
    func releaseAudio(_ lease: AudioLease) async {
        do { try await coordinator.releaseAudio(lease) } catch { lastIssue = error.localizedDescription }
        refreshCacheSize()
    }
    func releaseCaches() async {
        do { try await coordinator.releaseCaches() } catch { lastIssue = error.localizedDescription }
        cleanOldExports(); refreshCacheSize()
    }
    func exportAudio(meetingID: UUID, part: AudioPart) async throws -> URL {
        let lease = try await acquireAudio(meetingID: meetingID, part: part)
        do {
            let directory = exports.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("Alaud-\(part.filename)")
            try FileManager.default.copyItem(at: lease.url, to: url)
            await releaseAudio(lease); return url
        } catch { await releaseAudio(lease); throw error }
    }
    func removeExport(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    func storageTitle(_ meeting: Meeting) -> String {
        if store.isCloudStored(meeting.id) { return "已存 iCloud · 按需回听" }
        return meeting.endedAt == nil ? "原音保存在录音设备" : "等待 iCloud 保存确认"
    }
    private func refreshCacheSize() {
        cacheBytes = (try? store.cachedAudioBytes()) ?? 0
        Task { if let total = try? await coordinator.cachedAudioBytes() { cacheBytes = total } }
    }
    private func cleanOldExports() {
        guard let directories = try? FileManager.default.contentsOfDirectory(at: exports, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for directory in directories {
            if let date = try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate,
               Date().timeIntervalSince(date) > 3600 { try? FileManager.default.removeItem(at: directory) }
        }
    }
    func scheduleBackgroundSync() {
        #if os(iOS)
        guard !demonstration else { return }
        let request = BGProcessingTaskRequest(identifier: "com.gaoyiming.alaud.cloudsync")
        request.requiresNetworkConnectivity = true; request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }
}
#endif
