import Foundation
import Speech
import AVFoundation
import Combine
import AlaudCore

enum TranscriptionError: LocalizedError {
    case unavailable, unsupportedLanguage, modelMissing
    var errorDescription: String? {
        switch self {
        case .unavailable: return "这台设备暂不支持离线转写。原音已保存，可导出后处理。"
        case .unsupportedLanguage: return "当前设备不支持所选转写语言。请在设置中切换语言。"
        case .modelMissing: return "请先在设置中准备离线转写模型，然后重试。"
        }
    }
}

@MainActor
final class TranscriptionService: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var preparing = false
    @Published private(set) var preparationMessage: String?
    var onChange: (() -> Void)?
    private let store: MeetingStore
    private let cloud: CloudLibrary

    init(store: MeetingStore, cloud: CloudLibrary) { self.store = store; self.cloud = cloud }

    func prepareModel() async {
        guard !preparing, !isWorking else { return }
        preparing = true; preparationMessage = "正在准备模型…"; defer { preparing = false }
        do {
            let module = try await makeModule()
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                preparationMessage = "正在下载离线模型，请保持网络连接。"
                try await request.downloadAndInstall()
            }
            preparationMessage = "离线模型已就绪。"
        } catch { preparationMessage = error.localizedDescription }
    }

    func transcribe(_ id: UUID) async {
        guard !isWorking, !preparing else { return }
        isWorking = true; defer { isWorking = false; onChange?() }
        do {
            let meeting = try store.load(id)
            guard meeting.isComplete else { throw StoreError.incompleteMeeting }
            let module = try await makeModule()
            guard await AssetInventory.status(forModules: [module]) == .installed else { throw TranscriptionError.modelMissing }
            try store.update(id) { $0.transcriptState = .processing; $0.transcriptError = nil }
            onChange?()
            for part in meeting.parts where !meeting.transcribedPartIndices.contains(part.index) {
                try Task.checkCancellation()
                let lease = try await cloud.acquireAudio(meetingID: id, part: part)
                defer { Task { await cloud.releaseAudio(lease) } }
                let file = try AVAudioFile(forReading: lease.url)
                let module = try await makeModule()
                let analyzer = SpeechAnalyzer(modules: [module])
                let collect = Task { () throws -> [TranscriptLine] in
                    var lines: [TranscriptLine] = []
                    for try await result in module.results {
                        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        lines.append(TranscriptLine(partIndex: part.index,
                            offset: part.offset + max(0, result.range.start.seconds), text: text))
                    }
                    return lines
                }
                let lines: [TranscriptLine]
                do {
                    try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                    lines = try await collect.value
                } catch {
                    await analyzer.cancelAndFinishNow(); collect.cancel(); throw error
                }
                try store.update(id) {
                    $0.transcript.removeAll { $0.partIndex == part.index }
                    $0.transcript.append(contentsOf: lines); $0.transcript.sort { $0.offset < $1.offset }
                    if !$0.transcribedPartIndices.contains(part.index) { $0.transcribedPartIndices.append(part.index) }
                }
                onChange?()
            }
            try store.update(id) { $0.transcriptState = .ready; $0.transcriptError = nil }
        } catch {
            do { try store.update(id) { $0.transcriptState = .failed; $0.transcriptError = error.localizedDescription } }
            catch { preparationMessage = "转写状态保存失败：\(error.localizedDescription)" }
        }
    }

    private func makeModule() async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unavailable }
        let identifier = UserDefaults.standard.string(forKey: "transcriptionLocale") ?? "zh-CN"
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            throw TranscriptionError.unsupportedLanguage
        }
        return SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)
    }
}
