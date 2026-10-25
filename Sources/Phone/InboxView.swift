import SwiftUI
import AlaudCore

struct InboxView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var recorder: MeetingRecorder
    @ObservedObject private var cloud: CloudLibrary
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var showRecorder = false
    @State private var search = ""
    @State private var followUpsOnly = false
    @State private var path: [UUID] = []

    init(model: AppModel) { self.model = model; recorder = model.recorder; cloud = model.cloud }
    private var filtered: [Meeting] {
        model.meetings.filter {
            (!followUpsOnly || $0.followUps.contains { !$0.completed }) &&
            (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
             || $0.transcript.contains { $0.text.localizedCaseInsensitiveContains(search) }
             || $0.followUps.contains { $0.title.localizedCaseInsensitiveContains(search) })
        }
    }
    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 10) { AlaudMark(size: 34); Text("Alaud").font(.system(size: 26, weight: .semibold)) }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("录音库").font(.system(size: 34, weight: .bold))
                            CloudStatusLine(cloud: cloud)
                        }
                        Picker("录音筛选", selection: $followUpsOnly) {
                            Text("全部录音").tag(false)
                            Text("待跟进").tag(true)
                        }.pickerStyle(.segmented)
                    }.padding(.top, 4).padding(.bottom, 10)
                }.listRowSeparator(.hidden)
                if filtered.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label(search.isEmpty ? "从下一场对话开始" : "没有找到会议", systemImage: search.isEmpty ? "waveform" : "magnifyingglass")
                        } description: {
                            Text(search.isEmpty ? "抬腕记录，或点下方开始录音。\n对话和下一步，留在同一个地方。" : "试试标题、原文或待办中的关键词。")
                        }.padding(.vertical, 42)
                    }.listRowSeparator(.hidden)
                } else {
                    Section {
                        ForEach(filtered) { meeting in
                            NavigationLink(value: meeting.id) { MeetingRow(meeting: meeting, cloudSaved: model.store.isCloudStored(meeting.id)) }
                        }
                    } header: { Text("\(filtered.count) 场对话").font(.caption).textCase(nil) }
                }
                if let error = recorder.errorMessage {
                    Section { Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden).background(Color.alaudPaper)
            .listRowSpacing(0)
            .navigationTitle("").alaudInlineTitle()
            .searchable(text: $search, prompt: "搜索对话、原文和待办")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("设置", systemImage: "slider.horizontal.3") { showSettings = true }
                }
            }
            .navigationDestination(for: UUID.self) { id in MeetingDetailView(model: model, id: id) }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    Rectangle().fill(Color.alaudLine).frame(height: 1)
                    Button {
                        if recorder.activeID != nil { showRecorder = true }
                        else { Task { await model.start(); if recorder.activeID != nil { showRecorder = true } } }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: recorder.activeID == nil ? "mic.fill" : "waveform")
                            Text(recorder.activeID == nil ? "开始录音" : (recorder.isRecording ? "正在录音 · 点击查看" : "录音已暂停"))
                            if recorder.isBusy { ProgressView().tint(Color.alaudPaper) }
                        }
                    }.buttonStyle(InkButtonStyle()).disabled(recorder.isBusy)
                        .padding(.horizontal, 24).padding(.vertical, 12)
                        .accessibilityIdentifier("recordButton")
                }.background(Color.alaudPaper)
            }
            .sheet(isPresented: $showSettings) { SettingsView(model: model) }
            .sheet(isPresented: $showRecorder) { RecordingView(model: model) }
            .alert("需要留意", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("知道了") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.becameActive() }
                if phase == .background { cloud.scheduleBackgroundSync() }
            }
            .onChange(of: recorder.activeID) { _, id in if id != nil { showRecorder = true } }
            .onAppear {
                if recorder.activeID != nil { showRecorder = true }; model.becameActive()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--demo-detail"), path.isEmpty,
                   let id = model.meetings.first?.id { path.append(id) }
                if ProcessInfo.processInfo.arguments.contains("--demo-settings") { showSettings = true }
                #endif
            }
            .task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    if scenePhase == .active { await cloud.sync() }
                }
            }
        }
    }
}
