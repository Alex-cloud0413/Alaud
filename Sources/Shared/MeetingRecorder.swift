import AVFoundation
import AlaudCore
import Combine
#if os(watchOS)
import WatchKit
#endif

@MainActor
final class MeetingRecorder: ObservableObject {
    @Published private(set) var activeID: UUID?
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    var onChange: (() -> Void)?
    private let store: MeetingStore
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.gaoyiming.alaud.audio", qos: .userInitiated)
    private var writer: SegmentWriter?
    private var hasTap = false
    private var observers: [NSObjectProtocol] = []
    private var resumeAfterInterruption = false

    init(store: MeetingStore) {
        self.store = store
        #if !os(macOS)
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] notification in
            let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            Task { @MainActor [weak self] in self?.interrupted(type: type, options: options) }
        })
        #endif
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, !self.engine.isRunning else { return }
                self.pause(reason: "音频设备或系统配置发生变化，请检查后继续录音。")
            }
        })
    }

    func start() async throws {
        guard activeID == nil, !isBusy else { throw CaptureError.busy }
        isBusy = true; defer { isBusy = false }
        #if os(macOS)
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        #else
        let allowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        #endif
        guard allowed else { throw CaptureError.microphoneDenied }
        let capacity = try FileManager.default.attributesOfFileSystem(forPath: store.root.path)
        if let bytes = (capacity[.systemFreeSize] as? NSNumber)?.int64Value, bytes < 200_000_000 { throw CaptureError.storageFull }
        #if os(watchOS)
        let source: RecordingSource = .watch
        #elseif os(macOS)
        let source: RecordingSource = .mac
        #else
        let source: RecordingSource = .phone
        #endif
        let meeting = Meeting(source: source)
        try store.save(meeting); activeID = meeting.id
        do { try activate(meeting) }
        catch {
            activeID = nil
            _ = try? store.update(meeting.id) {
                $0.captureState = .interrupted; $0.endedAt = Date(); $0.expectedPartCount = $0.parts.count
                $0.gaps.append(RecordingGap(reason: error.localizedDescription))
            }
            onChange?(); throw error
        }
        onChange?(); feedback()
    }

    func resume() throws {
        guard let id = activeID, !isRecording else { return }
        let meeting = try store.load(id)
        try activate(meeting)
        try store.update(id) {
            $0.captureState = .recording
            if let index = $0.gaps.indices.last, $0.gaps[index].endedAt == nil { $0.gaps[index].endedAt = Date() }
        }
        onChange?()
    }

    func pause(reason: String = "手动暂停") {
        guard let id = activeID, isRecording else { return }
        stopEngine(); isRecording = false
        do { try store.update(id) { $0.captureState = .paused; $0.gaps.append(RecordingGap(reason: reason)) } }
        catch { errorMessage = error.localizedDescription }
        onChange?(); feedback()
    }

    func stop() throws {
        guard let id = activeID else { return }
        resumeAfterInterruption = false
        stopEngine(); isRecording = false
        try store.update(id) {
            $0.endedAt = Date(); $0.expectedPartCount = $0.parts.count; $0.captureState = .finished
        }
        activeID = nil
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        onChange?(); feedback()
    }

    private func activate(_ meeting: Meeting) throws {
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        let protect = UserDefaults.standard.object(forKey: "reduceCallInterruptions") as? Bool ?? true
        try session.setPrefersNoInterruptionsFromSystemAlerts(protect)
        try session.setActive(true)
        #endif
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.invalidFormat }
        let writer = try SegmentWriter(store: store, meeting: meeting, inputFormat: format,
            didSave: { [weak self] in Task { @MainActor in self?.onChange?() } },
            didFail: { [weak self] error in Task { @MainActor in
                self?.errorMessage = error.localizedDescription
                self?.pause(reason: "保存音频失败：\(error.localizedDescription)")
            } })
        self.writer = writer
        let queue = queue
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let copy = SegmentWriter.copy(buffer) else {
                Task { @MainActor [weak self] in self?.pause(reason: "无法保存麦克风缓冲，录音已暂停。") }
                return
            }
            queue.async { writer.consume(copy) }
        }
        hasTap = true
        do { engine.prepare(); try engine.start(); isRecording = true; errorMessage = nil }
        catch { stopEngine(); throw error }
    }

    private func stopEngine() {
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        let writer = writer
        queue.sync { writer?.finish() }
        self.writer = nil
    }

    private func interrupted(type: UInt, options: UInt) {
        #if !os(macOS)
        if type == AVAudioSession.InterruptionType.began.rawValue {
            resumeAfterInterruption = isRecording
            pause(reason: "系统音频中断，期间没有录音。")
        } else if type == AVAudioSession.InterruptionType.ended.rawValue, resumeAfterInterruption {
            resumeAfterInterruption = false
            guard AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) else {
                errorMessage = "系统中断已结束，请点「继续录音」。"; return
            }
            do { try resume() } catch { errorMessage = error.localizedDescription }
        }
        #endif
    }

    func recoverPreviousSessions(source: RecordingSource) throws {
        for meeting in try store.list() where meeting.source == source && meeting.endedAt == nil {
            var recovered = meeting
            let urls = try FileManager.default.contentsOfDirectory(at: store.directory(for: meeting.id), includingPropertiesForKeys: [.contentModificationDateKey])
            for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "caf" {
                let name = url.deletingPathExtension().lastPathComponent
                guard name.hasPrefix("part-"), let index = Int(name.dropFirst(5)),
                      !recovered.parts.contains(where: { $0.index == index }) else { continue }
                if let file = try? AVAudioFile(forReading: url), file.length > 0 {
                    let duration = Double(file.length) / file.processingFormat.sampleRate
                    let part = AudioPart(index: index, filename: url.lastPathComponent,
                        offset: recovered.audioDuration, duration: duration, sha256: try MeetingStore.digest(url))
                    recovered.parts.append(part)
                }
            }
            recovered.parts.sort { $0.index < $1.index }
            recovered.captureState = .interrupted; recovered.expectedPartCount = recovered.parts.count
            recovered.endedAt = urls.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max() ?? meeting.createdAt
            recovered.gaps.append(RecordingGap(beganAt: recovered.endedAt!, reason: "上次录音异常结束；已恢复可读取的片段，请核对原音。"))
            try store.save(recovered)
        }
    }

    private func feedback() {
        #if os(watchOS)
        WKInterfaceDevice.current().play(.click)
        #endif
    }
}
