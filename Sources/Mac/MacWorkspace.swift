import SwiftUI
import AlaudCore

private enum LibraryArea: String, CaseIterable, Identifiable {
    case recordings = "录音库", followUps = "待跟进", settings = "设置"
    var id: Self { self }
    var symbol: String { switch self { case .recordings: return "waveform"; case .followUps: return "checkmark.circle"; case .settings: return "slider.horizontal.3" } }
}

struct MacWorkspace: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var cloud: CloudLibrary
    @ObservedObject private var recorder: MeetingRecorder
    @Environment(\.scenePhase) private var scenePhase
    @State private var area: LibraryArea? = .recordings
    @State private var selected: UUID?
    @State private var search = ""
    @State private var showRecorder = false
    init(model: AppModel) { self.model = model; cloud = model.cloud; recorder = model.recorder }
    private var filtered: [Meeting] {
        model.meetings.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
            || $0.transcript.contains { $0.text.localizedCaseInsensitiveContains(search) }
            || $0.followUps.contains { $0.title.localizedCaseInsensitiveContains(search) } }
    }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) { AlaudMark(size: 34); Text("Alaud").font(.system(size: 24, weight: .semibold)) }
                    .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 26)
                VStack(spacing: 5) {
                    ForEach(LibraryArea.allCases) { item in
                        Button { area = item } label: {
                            Label(item.rawValue, systemImage: item.symbol)
                                .font(.system(size: 14, weight: area == item ? .semibold : .regular))
                                .foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14).padding(.vertical, 12)
                                .background(area == item ? Color.primary.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityValue(area == item ? "已选中" : "")
                    }
                }.padding(.horizontal, 12)
                Spacer(minLength: 12)
                VStack(alignment: .leading, spacing: 16) {
                    CloudStatusLine(cloud: cloud)
                    Button {
                        if recorder.activeID != nil { showRecorder = true }
                        else { Task { await model.start(); if recorder.activeID != nil { showRecorder = true } } }
                    } label: {
                        Label(recorder.activeID == nil ? "开始录音" : "查看进行中的录音", systemImage: recorder.activeID == nil ? "mic.fill" : "waveform")
                    }.buttonStyle(InkButtonStyle()).disabled(recorder.isBusy)
                }.padding(18)
            }.background(Color.alaudWash).navigationSplitViewColumnWidth(min: 220, ideal: 230, max: 270)
        } detail: {
            Group {
                switch area ?? .recordings {
                case .recordings: recordings
                case .followUps: followUps
                case .settings: SettingsView(model: model)
                }
            }.background(Color.alaudPaper)
        }
        .frame(minWidth: 1000, minHeight: 640)
        .navigationTitle("Alaud")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("同步", systemImage: "arrow.triangle.2.circlepath") { Task { await cloud.sync() } }
                    .disabled(cloud.isSyncing).help("同步 iCloud 录音库")
            }
        }
        .sheet(isPresented: $showRecorder) { RecordingView(model: model).frame(width: 520, height: 620) }
        .alert("需要留意", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .onChange(of: recorder.activeID) { _, id in if id != nil { showRecorder = true } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.becameActive() } }
        .onAppear {
            model.becameActive()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--demo-detail") { selected = model.meetings.first?.id }
            if ProcessInfo.processInfo.arguments.contains("--demo-settings") { area = .settings }
            #endif
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await cloud.sync()
            }
        }
    }
    private var recordings: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Text("录音库").font(.system(size: 30, weight: .bold)); Spacer(); Text("\(model.meetings.count)").foregroundStyle(.secondary) }
                    TextField("搜索对话、原文和待办", text: $search).textFieldStyle(.roundedBorder)
                }.padding(24)
                Divider()
                if filtered.isEmpty {
                    ContentUnavailableView("还没有对话", systemImage: "waveform", description: Text("从手表、iPhone 或这台 Mac 开始录音。"))
                } else {
                    List(filtered, selection: $selected) { meeting in
                        MeetingRow(meeting: meeting, cloudSaved: model.store.isCloudStored(meeting.id)).tag(meeting.id)
                    }.listStyle(.plain).scrollContentBackground(.hidden)
                }
            }.frame(minWidth: 290, idealWidth: 340, maxWidth: 400)
                .frame(maxHeight: .infinity, alignment: .top).background(Color.alaudPaper)
            Group {
                if let selected { MeetingDetailView(model: model, id: selected).id(selected) }
                else {
                    VStack(spacing: 20) {
                        AlaudMark(size: 72)
                        Text("留下对话，接着推进。").font(.title2.weight(.semibold))
                        Text("选择一场对话，查看原文和下一步。\n原音保存在 iCloud，回听时才下载。")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(minWidth: 380)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private var followUps: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("待跟进").font(.system(size: 32, weight: .bold))
            Text("把对话里的下一步，留在手边。").foregroundStyle(.secondary)
            List {
                ForEach(model.meetings) { meeting in
                    let items = meeting.followUps.filter { !$0.completed }
                    if !items.isEmpty {
                        Section(meeting.title) {
                            ForEach(items) { item in
                                HStack(spacing: 14) {
                                    Button {
                                        model.update(meeting.id) { if let i = $0.followUps.firstIndex(where: { $0.id == item.id }) { $0.followUps[i].completed = true } }
                                    } label: { Image(systemName: "circle") }.buttonStyle(.borderless)
                                    Text(item.title); Spacer()
                                    Button("查看对话") { selected = meeting.id; area = .recordings }.buttonStyle(.borderless)
                                }.padding(.vertical, 8)
                            }
                        }
                    }
                }
            }.listStyle(.plain).scrollContentBackground(.hidden)
            if model.meetings.flatMap(\.followUps).allSatisfy(\.completed) { Text("没有待跟进的事项。").foregroundStyle(.secondary) }
        }.padding(32)
    }
}
