import SwiftUI
import AppKit

@main
struct AlaudMacApp: App {
    @NSApplicationDelegateAdaptor(AlaudMacDelegate.self) private var delegate
    @State private var probeMessage: String?
    @State private var probeRunning = false
    var body: some Scene {
        WindowGroup {
            Group {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--cloud-probe") { CloudStorageProbeView() }
            else { application }
            #else
            application
            #endif
            }.overlay(alignment: .bottomTrailing) {
                if probeRunning { HStack { ProgressView().controlSize(.small); Text("正在验证 iCloud 存储…") }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(20) }
            }.alert("iCloud 存储验证", isPresented: Binding(get: { probeMessage != nil }, set: { if !$0 { probeMessage = nil } })) {
                Button("知道了") { probeMessage = nil }
            } message: { Text(probeMessage ?? "") }
        }
        .defaultSize(width: 1240, height: 820)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("开始录音") { Task { await (try? AppRuntime.model())?.start() } }.keyboardShortcut("r", modifiers: .command)
                Button("结束录音") { (try? AppRuntime.model())?.stop() }.keyboardShortcut(".", modifiers: .command)
                Divider()
                Button("同步 iCloud 录音库") { Task { await (try? AppRuntime.model())?.cloud.sync() } }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            #if DEBUG
            CommandMenu("开发验证") {
                Button("验证 iCloud 存储与按需恢复") {
                    probeRunning = true
                    Task {
                        defer { probeRunning = false }
                        do { probeMessage = try await CloudStorageProbe.run(verifyOnly: false) }
                        catch { probeMessage = String(describing: error) }
                    }
                }.disabled(probeRunning)
            }
            #endif
        }
    }
    @ViewBuilder private var application: some View {
            switch AppRuntime.result {
            case .success(let model): MacWorkspace(model: model).tint(.primary)
            case .failure(let error): ContentUnavailableView("无法打开录音库", systemImage: "externaldrive.badge.exclamationmark", description: Text(error.localizedDescription))
            }
    }
}

final class AlaudMacDelegate: NSObject, NSApplicationDelegate {
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let model = try? AppRuntime.model(), model.recorder.activeID != nil { model.stop() }
        return .terminateNow
    }
}
