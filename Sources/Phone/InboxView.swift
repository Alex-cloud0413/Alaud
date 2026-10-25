import SwiftUI
import AlaudCore

struct InboxView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var recorder: MeetingRecorder
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var showRecorder = false
    @State private var search = ""
    @State private var path: [UUID] = []

    init(model: AppModel) { self.model = model; recorder = model.recorder }

    private var filtered: [Meeting] {
        model.meetings.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
            || $0.transcript.contains(where: { $0.text.localizedCaseInsensitiveContains(search) })
            || $0.followUps.contains(where: { $0.title.localizedCaseInsensitiveContains(search) }) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("会后跟进").font(.title2.weight(.semibold))
                        Text("留下对话，接着推进。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if !model.meetings.isEmpty {
                            HStack(spacing: 18) {
                                Label("\(model.meetings.count) 场会议", systemImage: "waveform")
                                Label("\(model.meetings.flatMap(\.followUps).filter { !$0.completed }.count) 项待办", systemImage: "checkmark.circle")
                            }.font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                        }
                    }.padding(.vertical, 12)
                }.listRowBackground(Color.clear).listRowSeparator(.hidden)

                if filtered.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label(search.isEmpty ? "下一场会议，从这里开始" : "没有找到会议", systemImage: search.isEmpty ? "waveform" : "magnifyingglass")
                        } description: {
                            Text(search.isEmpty ? "在手机或手表上开始录音，结束后回到这里查看原音、转写和跟进事项。" : "试试会议标题、原文或待办中的关键词。")
                        }.padding(.vertical, 30)
                    }.listRowBackground(Color.clear)
                } else {
                    Section("会议 · \(filtered.count)") {
                        ForEach(filtered) { meeting in
                            NavigationLink(value: meeting.id) { MeetingRow(meeting: meeting) }
                        }
                    }
                }
                if let error = recorder.errorMessage {
                    Section { Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Alaud")
            .searchable(text: $search, prompt: "搜索会议、原文和待办")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("设置", systemImage: "slider.horizontal.3") { showSettings = true }
                }
            }
            .navigationDestination(for: UUID.self) { id in MeetingDetailView(model: model, id: id) }
            .safeAreaInset(edge: .bottom) {
                Button {
                    if recorder.activeID != nil { showRecorder = true }
                    else { Task { await model.start(); if recorder.activeID != nil { showRecorder = true } } }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: recorder.activeID == nil ? "mic.fill" : "waveform")
                            .font(.title3)
                        Text(recorder.activeID == nil ? "开始录音" : (recorder.isRecording ? "录音正在进行" : "录音已暂停"))
                            .font(.headline)
                        Spacer()
                        if recorder.isBusy { ProgressView().tint(.white) }
                        else { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)) }
                    }.foregroundStyle(.white).padding(20)
                        .background(recorder.activeID == nil ? Color.alaudButton : Color.red, in: RoundedRectangle(cornerRadius: 22))
                }.buttonStyle(.plain).disabled(recorder.isBusy)
                    .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
                    .background(.bar)
                    .accessibilityIdentifier("recordButton")
            }
            .sheet(isPresented: $showSettings) { SettingsView(model: model) }
            .sheet(isPresented: $showRecorder) { RecordingView(model: model) }
            .alert("需要留意", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("知道了") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
            .onChange(of: scenePhase) { _, phase in if phase == .active { model.becameActive() } }
            .onChange(of: recorder.activeID) { _, id in if id != nil { showRecorder = true } }
            .onAppear {
                if recorder.activeID != nil { showRecorder = true }; model.becameActive()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--demo-detail"), path.isEmpty,
                   let id = model.meetings.first?.id { path.append(id) }
                if ProcessInfo.processInfo.arguments.contains("--demo-settings") { showSettings = true }
                #endif
            }
        }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: meeting.source == .watch ? "applewatch" : "waveform")
                .font(.title3).foregroundStyle(Color.alaudAccent)
                .frame(width: 42, height: 46)
                .background(Color.alaudAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 7) {
                Text(meeting.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                HStack(spacing: 5) {
                    Text(meeting.createdAt, format: .dateTime.month().day().hour().minute())
                    Text("·")
                    Text(audioClock(meeting.audioDuration))
                }.font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 7) {
                    Text(meeting.stateTitle).font(.caption.weight(.medium))
                        .foregroundStyle(meeting.transcriptState == .failed ? Color.orange : .alaudAccent)
                    if !meeting.gaps.isEmpty {
                        Label("有录音缺口", systemImage: "exclamationmark.circle").font(.caption2).foregroundStyle(.orange)
                    }
                    let count = meeting.followUps.filter { !$0.completed }.count
                    if count > 0 { Text("\(count) 项跟进").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.padding(.vertical, 9)
    }
}
