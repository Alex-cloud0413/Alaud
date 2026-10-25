import Foundation
import Combine
import AlaudCore

@MainActor
enum AppRuntime {
    static let result: Result<AppModel, Error> = Result { try AppModel() }
    static func model() throws -> AppModel { try result.get() }
}

@MainActor
final class AppModel: ObservableObject {
    let store: MeetingStore
    let recorder: MeetingRecorder
    let transfer: WatchTransfer
    @Published private(set) var meetings: [Meeting] = []
    @Published var errorMessage: String?
    #if os(iOS)
    let transcription: TranscriptionService
    #endif

    init(root: URL? = nil) throws {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Alaud/Meetings", isDirectory: true)
        store = try MeetingStore(root: base)
        recorder = MeetingRecorder(store: store)
        transfer = WatchTransfer(store: store)
        #if os(iOS)
        transcription = TranscriptionService(store: store)
        #endif
        #if os(watchOS)
        try recorder.recoverPreviousSessions(source: .watch)
        #else
        try recorder.recoverPreviousSessions(source: .phone)
        #endif
        for meeting in try store.list() where meeting.transcriptState == .processing {
            try store.update(meeting.id) {
                $0.transcriptState = .failed; $0.transcriptError = "上次转写被系统中止；已保存的进度会在重试时继续。"
            }
        }
        recorder.onChange = { [weak self] in self?.refresh(); self?.transfer.pump(); self?.processPending() }
        transfer.onChange = { [weak self] in self?.refresh(); self?.processPending() }
        transfer.onError = { [weak self] in self?.errorMessage = $0 }
        #if os(iOS)
        transcription.onChange = { [weak self] in self?.refresh() }
        #endif
        refresh()
        #if DEBUG && os(iOS)
        if ProcessInfo.processInfo.arguments.contains("--demo") { try seedDemo() }
        #endif
    }

    func refresh() {
        do { meetings = try store.list() } catch { errorMessage = "读取会议失败：\(error.localizedDescription)" }
    }
    func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }
    func update(_ id: UUID, _ change: (inout Meeting) -> Void) {
        do { try store.update(id, change); refresh() } catch { errorMessage = error.localizedDescription }
    }
    func start() async {
        do { try await recorder.start() } catch { errorMessage = error.localizedDescription }
    }
    func stop() {
        do { try recorder.stop() } catch { errorMessage = error.localizedDescription }
    }
    func resume() {
        do { try recorder.resume() } catch { errorMessage = error.localizedDescription }
    }
    func becameActive() { refresh(); transfer.pump(); processPending() }
    func processPending() {
        #if os(iOS)
        guard (UserDefaults.standard.object(forKey: "autoTranscribe") as? Bool ?? true),
              !transcription.isWorking, recorder.activeID == nil else { return }
        guard let next = meetings.first(where: { $0.isComplete && $0.transcriptState == .waiting }) else { return }
        Task {
            await transcription.transcribe(next.id)
            refresh()
            processPending()
        }
        #endif
    }
}
