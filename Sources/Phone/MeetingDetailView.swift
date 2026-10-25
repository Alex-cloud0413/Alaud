import SwiftUI
import AVFoundation
import AlaudCore
import UniformTypeIdentifiers

@MainActor
final class AudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var currentPart: Int?
    @Published var errorMessage: String?
    private var player: AVAudioPlayer?
    func play(_ url: URL, part: Int, at time: TimeInterval = 0) {
        do {
            guard !AppRuntime.modelOrNilIsRecording else {
                errorMessage = "请结束当前录音后再回听原音。"; return
            }
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            player?.stop(); player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.currentTime = max(0, time); player?.play(); currentPart = part
        } catch { errorMessage = error.localizedDescription }
    }
    func stop() { player?.stop(); player = nil; currentPart = nil }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard self?.player === player else { return }
            self?.currentPart = nil; self?.player = nil
        }
    }
}

extension AppRuntime {
    static var modelOrNilIsRecording: Bool { (try? model().recorder.activeID) != nil }
}

struct MarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .json] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

struct MeetingDetailView: View {
    @ObservedObject var model: AppModel
    let id: UUID
    @StateObject private var playback = AudioPlayback()
    @State private var title = ""
    @State private var notes = ""
    @State private var newFollowUp = ""
    @State private var exporting = false
    @State private var exportingJSON = false
    @State private var exportDocument = MarkdownDocument(text: "")
    @ObservedObject private var transcription: TranscriptionService

    init(model: AppModel, id: UUID) { self.model = model; self.id = id; transcription = model.transcription }
    private var meeting: Meeting? { model.meeting(id) }

    var body: some View {
        Group {
            if let meeting {
                List {
                    Section {
                        TextField("会议标题", text: $title, axis: .vertical).font(.title2.weight(.semibold))
                            .onSubmit { saveTitle() }
                        LabeledContent("时间", value: meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("录音来源", value: meeting.source.title)
                        LabeledContent("已保存音频", value: audioClock(meeting.audioDuration))
                        LabeledContent("状态", value: meeting.stateTitle)
                    }
                    if !meeting.gaps.isEmpty {
                        Section("录音缺口") {
                            ForEach(meeting.gaps) { gap in
                                VStack(alignment: .leading, spacing: 5) {
                                    Label(gap.reason, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                                    HStack {
                                        Text(gap.beganAt, format: .dateTime.hour().minute().second())
                                        if let end = gap.endedAt { Text("→"); Text(end, format: .dateTime.hour().minute().second()) }
                                    }.font(.caption).foregroundStyle(.secondary)
                                }.font(.subheadline)
                            }
                        }
                    }
                    Section("跟进事项") {
                        ForEach(meeting.followUps) { item in
                            Button {
                                model.update(id) { if let i = $0.followUps.firstIndex(where: { $0.id == item.id }) { $0.followUps[i].completed.toggle() } }
                            } label: {
                                Label(item.title, systemImage: item.completed ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item.completed ? .secondary : .primary)
                                    .strikethrough(item.completed)
                            }.buttonStyle(.plain)
                        }
                        HStack {
                            TextField("添加需要跟进的事", text: $newFollowUp, axis: .vertical)
                            Button("添加", systemImage: "plus.circle.fill") { addFollowUp() }.labelStyle(.iconOnly)
                                .frame(minWidth: 44, minHeight: 44)
                                .disabled(newFollowUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    Section("会议备注") {
                        TextField("人物、项目，或需要特别留意的事", text: $notes, axis: .vertical).lineLimit(3...8)
                    }
                    Section {
                        if meeting.transcriptState == .processing {
                            HStack { ProgressView(); Text("正在本机转写…").foregroundStyle(.secondary) }
                        }
                        if let error = meeting.transcriptError { Text(error).font(.footnote).foregroundStyle(.orange) }
                        if meeting.transcript.isEmpty && meeting.transcriptState != .processing {
                            Text(meeting.transcriptState == .ready ? "这些片段中未识别出文字，请回听原音。" : "转写完成后，点时间点可回听对应原音。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        ForEach(meeting.transcript) { line in
                            Button {
                                guard let part = meeting.parts.first(where: { $0.index == line.partIndex }),
                                      let url = try? model.store.audioURL(meetingID: id, part: part) else { return }
                                playback.play(url, part: part.index, at: line.offset - part.offset)
                            } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    Label(audioClock(line.offset), systemImage: "play.circle")
                                        .font(.caption.monospacedDigit()).foregroundStyle(Color.alaudAccent)
                                    Text(line.text).font(.body).foregroundStyle(.primary).textSelection(.enabled)
                                }.padding(.vertical, 5)
                            }.buttonStyle(.plain)
                        }
                        if meeting.isComplete && meeting.transcriptState != .ready {
                            Button(meeting.transcriptState == .failed ? "继续转写" : "转写这场会议", systemImage: "text.bubble") {
                                Task { await transcription.transcribe(id); model.refresh() }
                            }.disabled(transcription.isWorking || model.recorder.activeID != nil)
                        }
                    } header: { Text("转写原文") } footer: { Text("机器转写可能有误，重要结论请核对原音。") }

                    Section("原音 · \(meeting.parts.count) 个片段") {
                        ForEach(meeting.parts) { part in
                            HStack {
                                Button {
                                    if playback.currentPart == part.index { playback.stop() }
                                    else if let url = try? model.store.audioURL(meetingID: id, part: part) { playback.play(url, part: part.index) }
                                } label: {
                                    Label("\(audioClock(part.offset)) · \(audioClock(part.duration))", systemImage: playback.currentPart == part.index ? "stop.circle.fill" : "play.circle")
                                        .monospacedDigit()
                                        .frame(minHeight: 44).contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(playback.currentPart == part.index ? "停止片段 \(part.index + 1)" : "播放片段 \(part.index + 1)")
                                .accessibilityIdentifier("audio-play-\(part.index)")
                                Spacer()
                                if let url = try? model.store.audioURL(meetingID: id, part: part) {
                                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
                                        .buttonStyle(.borderless)
                                        .accessibilityLabel("导出原音片段 \(part.index + 1)")
                                        .accessibilityIdentifier("audio-share-\(part.index)")
                                }
                            }
                        }
                    }
                }
                .navigationTitle("会议详情").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("导出", systemImage: "square.and.arrow.up") {
                            Button("导出 Markdown", systemImage: "doc.text") { export(meeting, json: false) }
                            Button("导出 Agent 数据包（JSON）", systemImage: "curlybraces") { export(meeting, json: true) }
                        }
                    }
                }
                .onAppear { title = meeting.title; notes = meeting.notes }
                .onDisappear { playback.stop(); saveTitle(); model.update(id) { $0.notes = notes } }
                .onChange(of: notes) { _, value in model.update(id) { $0.notes = value } }
            } else { ContentUnavailableView("会议暂不可用", systemImage: "waveform") }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: exportingJSON ? .json : .plainText,
                      defaultFilename: "Alaud-\(id.uuidString.prefix(8)).\(exportingJSON ? "json" : "md")") { result in
            if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
        }
        .alert("无法回听", isPresented: Binding(get: { playback.errorMessage != nil }, set: { if !$0 { playback.errorMessage = nil } })) {
            Button("知道了") { playback.errorMessage = nil }
        } message: { Text(playback.errorMessage ?? "") }
    }

    private func addFollowUp() {
        let text = newFollowUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.update(id) { $0.followUps.append(FollowUp(title: text)) }; newFollowUp = ""
    }
    private func saveTitle() {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, meeting?.title != value { model.update(id) { $0.title = value } }
    }
    private func export(_ meeting: Meeting, json: Bool) {
        saveTitle()
        let current = model.meeting(id) ?? meeting
        do {
            if json {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                exportDocument = MarkdownDocument(text: String(decoding: try encoder.encode(current), as: UTF8.self))
            } else { exportDocument = MarkdownDocument(text: MeetingExport.markdown(current)) }
            exportingJSON = json; exporting = true
        } catch { model.errorMessage = error.localizedDescription }
    }
}
