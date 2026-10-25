import SwiftUI
import AVFoundation
import AlaudCore
import UniformTypeIdentifiers

@MainActor
final class AudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var currentPart: Int?
    @Published var loadingPart: Int?
    @Published var errorMessage: String?
    private var player: AVAudioPlayer?
    private var audioLease: (CloudLibrary, AudioLease)?
    private var request = UUID()

    func play(meetingID: UUID, part: AudioPart, cloud: CloudLibrary, at time: TimeInterval = 0) {
        stop()
        guard !AppRuntime.modelOrNilIsRecording else { errorMessage = "请结束当前录音后再回听原音。"; return }
        let token = UUID(); request = token; loadingPart = part.index
        Task {
            do {
                let lease = try await cloud.acquireAudio(meetingID: meetingID, part: part)
                guard request == token, !AppRuntime.modelOrNilIsRecording else { await cloud.releaseAudio(lease); return }
                audioLease = (cloud, lease)
                #if os(iOS)
                try AVAudioSession.sharedInstance().setCategory(.playback)
                try AVAudioSession.sharedInstance().setActive(true)
                #endif
                let next = try AVAudioPlayer(contentsOf: lease.url)
                next.delegate = self; next.currentTime = max(0, time)
                guard next.play() else { throw CloudLibraryError.missingOriginal }
                player = next; currentPart = part.index; loadingPart = nil
            } catch {
                guard request == token else { return }
                stop(); errorMessage = error.localizedDescription
            }
        }
    }
    func stop() {
        request = UUID(); player?.stop(); player = nil; currentPart = nil; loadingPart = nil
        if let (cloud, lease) = audioLease { audioLease = nil; Task { await cloud.releaseAudio(lease) } }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in guard self?.player === player else { return }; self?.stop() }
    }
}

extension AppRuntime {
    static var modelOrNilIsRecording: Bool { (try? model().recorder.activeID) != nil }
}

struct MarkdownDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText, .json]
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
struct RawAudioDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.audio]
    var data = Data()
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
private struct AudioExportItem: Identifiable { let id = UUID(); let url: URL }

struct MeetingDetailView: View {
    @ObservedObject var model: AppModel
    let id: UUID
    @StateObject private var playback = AudioPlayback()
    @ObservedObject private var transcription: TranscriptionService
    @ObservedObject private var cloud: CloudLibrary
    @State private var newFollowUp = ""
    @State private var exporting = false
    @State private var exportingJSON = false
    @State private var exportDocument = MarkdownDocument(text: "")
    @State private var audioExport: AudioExportItem?
    @State private var activeExportURL: URL?
    @State private var audioPreparing: Int?
    @State private var audioDocument = RawAudioDocument()
    @State private var audioSave = false
    @State private var audioFilename = "Alaud.caf"

    init(model: AppModel, id: UUID) { self.model = model; self.id = id; transcription = model.transcription; cloud = model.cloud }
    private var meeting: Meeting? { model.meeting(id) }
    private var title: Binding<String> { Binding(get: { meeting?.title ?? "" }, set: { value in model.update(id) { $0.title = value } }) }
    private var notes: Binding<String> { Binding(get: { meeting?.notes ?? "" }, set: { value in model.update(id) { $0.notes = value } }) }

    var body: some View {
        Group {
            if let meeting {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 14) {
                            TextField("会议标题", text: title, axis: .vertical)
                                .font(.system(size: 28, weight: .semibold)).textFieldStyle(.plain)
                                .accessibilityIdentifier("meeting-title")
                            HStack(spacing: 14) {
                                Label(meeting.source.title, systemImage: meeting.source.symbol)
                                Text(audioClock(meeting.audioDuration)).monospacedDigit()
                            }.font(.caption).foregroundStyle(.secondary)
                            Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                            Label(cloud.storageTitle(meeting), systemImage: model.store.isCloudStored(id) ? "checkmark.icloud" : "icloud.and.arrow.up")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 10)
                    }.listRowSeparator(.hidden)
                    if !meeting.gaps.isEmpty {
                        Section("录音缺口") {
                            ForEach(meeting.gaps) { gap in
                                Label(gap.reason, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("待跟进") {
                        ForEach(meeting.followUps) { item in
                            Button {
                                model.update(id) { if let i = $0.followUps.firstIndex(where: { $0.id == item.id }) { $0.followUps[i].completed.toggle() } }
                            } label: {
                                Label(item.title, systemImage: item.completed ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item.completed ? .secondary : .primary).strikethrough(item.completed)
                                    .padding(.vertical, 5)
                            }.buttonStyle(.borderless)
                        }
                        HStack {
                            TextField("添加需要跟进的事", text: $newFollowUp, axis: .vertical).textFieldStyle(.plain)
                            Button("添加", systemImage: "plus") { addFollowUp() }.labelStyle(.iconOnly)
                                .buttonStyle(.borderless).frame(minWidth: 44, minHeight: 44)
                                .disabled(newFollowUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    Section("备注") {
                        TextField("人物、项目，或需要特别留意的事", text: notes, axis: .vertical)
                            .textFieldStyle(.plain).lineLimit(3...10).padding(.vertical, 6)
                    }
                    Section {
                        if meeting.transcriptState == .processing { HStack { ProgressView(); Text("正在本机转写…") }.foregroundStyle(.secondary) }
                        if let error = meeting.transcriptError { Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.secondary) }
                        if meeting.transcript.isEmpty && meeting.transcriptState != .processing {
                            Text(meeting.transcriptState == .ready ? "未识别出文字，请回听原音。" : "转写完成后，点时间点回听对应原音。")
                                .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 6)
                        }
                        ForEach(meeting.transcript) { line in
                            Button {
                                guard let part = meeting.parts.first(where: { $0.index == line.partIndex }) else { return }
                                playback.play(meetingID: id, part: part, cloud: cloud, at: line.offset - part.offset)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(audioClock(line.offset), systemImage: "play.circle")
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Text(line.text).font(.body).foregroundStyle(.primary).textSelection(.enabled)
                                }.padding(.vertical, 8)
                            }.buttonStyle(.borderless)
                        }
                        if meeting.isComplete && meeting.transcriptState != .ready {
                            Button(meeting.transcriptState == .failed ? "继续转写" : "转写这场会议", systemImage: "text.bubble") {
                                playback.stop(); Task { await transcription.transcribe(id); model.refresh() }
                            }.buttonStyle(.borderless).disabled(transcription.isWorking || model.recorder.activeID != nil)
                        }
                    } header: { Text("转写原文") } footer: { Text("机器转写可能有误，重要结论请核对原音。") }
                    Section {
                        ForEach(meeting.parts) { part in
                            HStack {
                                Button {
                                    if playback.currentPart == part.index || playback.loadingPart == part.index { playback.stop() }
                                    else { playback.play(meetingID: id, part: part, cloud: cloud) }
                                } label: {
                                    HStack(spacing: 10) {
                                        if playback.loadingPart == part.index { ProgressView().controlSize(.small) }
                                        else { Image(systemName: playback.currentPart == part.index ? "stop.circle.fill" : "play.circle").font(.title3) }
                                        Text("\(audioClock(part.offset)) · \(audioClock(part.duration))").font(.subheadline.monospacedDigit())
                                    }.frame(minHeight: 44).contentShape(Rectangle())
                                }.buttonStyle(.borderless)
                                    .accessibilityLabel(playback.currentPart == part.index ? "停止片段 \(part.index + 1)" : "播放片段 \(part.index + 1)")
                                    .accessibilityIdentifier("audio-play-\(part.index)")
                                Spacer()
                                Button { shareAudio(part) } label: {
                                    Group {
                                        if audioPreparing == part.index { ProgressView() }
                                        else { Image(systemName: "square.and.arrow.up") }
                                    }.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                                }.buttonStyle(.borderless).disabled(audioPreparing != nil)
                                    .accessibilityLabel("导出原音片段 \(part.index + 1)")
                                    .accessibilityIdentifier("audio-share-\(part.index)")
                            }
                        }
                    } header: { Text("原音 · \(meeting.parts.count) 个片段") } footer: {
                        Text(model.store.isCloudStored(id) ? "原音按需从 iCloud 下载，使用后自动释放本机缓存。" : "iCloud 完整保存确认前，本机原音继续保留。")
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden).background(Color.alaudPaper)
                .navigationTitle("").alaudInlineTitle()
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu("导出", systemImage: "square.and.arrow.up") {
                            Button("导出 Markdown", systemImage: "doc.text") { export(meeting, json: false) }
                            Button("导出 Agent 数据包（JSON）", systemImage: "curlybraces") { export(meeting, json: true) }
                        }
                    }
                }
                .onDisappear { playback.stop() }
            } else { ContentUnavailableView("会议暂不可用", systemImage: "waveform") }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: exportingJSON ? .json : .plainText,
            defaultFilename: "Alaud-\(id.uuidString.prefix(8)).\(exportingJSON ? "json" : "md")") { result in
                if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
            }
        #if os(iOS)
        .sheet(item: $audioExport, onDismiss: {
            if let url = activeExportURL { cloud.removeExport(url); activeExportURL = nil }
        }) { item in AudioShareSheet(url: item.url) { audioExport = nil } }
        #else
        .fileExporter(isPresented: $audioSave, document: audioDocument, contentType: UTType(filenameExtension: "caf") ?? .audio,
            defaultFilename: audioFilename) { result in
                audioDocument = RawAudioDocument()
                if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
            }
        #endif
        .alert("无法回听或导出", isPresented: Binding(get: { playback.errorMessage != nil }, set: { if !$0 { playback.errorMessage = nil } })) {
            Button("知道了") { playback.errorMessage = nil }
        } message: { Text(playback.errorMessage ?? "") }
    }
    private func shareAudio(_ part: AudioPart) {
        audioPreparing = part.index
        Task {
            defer { audioPreparing = nil }
            do {
                let url = try await cloud.exportAudio(meetingID: id, part: part)
                #if os(iOS)
                activeExportURL = url; audioExport = AudioExportItem(url: url)
                #else
                defer { cloud.removeExport(url) }
                audioDocument = RawAudioDocument(data: try Data(contentsOf: url)); audioFilename = url.lastPathComponent; audioSave = true
                #endif
            } catch { playback.errorMessage = error.localizedDescription }
        }
    }
    private func addFollowUp() {
        let value = newFollowUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        model.update(id) { $0.followUps.append(FollowUp(title: value)) }; newFollowUp = ""
    }
    private func export(_ meeting: Meeting, json: Bool) {
        exportingJSON = json
        do {
            if json {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                exportDocument = MarkdownDocument(text: String(decoding: try encoder.encode(meeting), as: UTF8.self))
            } else { exportDocument = MarkdownDocument(text: MeetingExport.markdown(meeting)) }
            exporting = true
        } catch { model.errorMessage = error.localizedDescription }
    }
}
