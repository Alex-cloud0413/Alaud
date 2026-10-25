import SwiftUI
import BackgroundTasks

@main
struct AlaudApp: App {
    init() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.gaoyiming.alaud.cloudsync", using: nil) { task in
            Task { @MainActor in
                guard let model = try? AppRuntime.model() else { task.setTaskCompleted(success: false); return }
                let work = Task {
                    await model.cloud.sync(); model.cloud.scheduleBackgroundSync()
                    task.setTaskCompleted(success: model.cloud.lastIssue == nil)
                }
                task.expirationHandler = { work.cancel() }
            }
        }
    }
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--cloud-probe") { CloudStorageProbeView() }
            else { application }
            #else
            application
            #endif
        }
    }
    @ViewBuilder private var application: some View {
            switch AppRuntime.result {
            case .success(let model): InboxView(model: model).tint(.alaudAccent)
            case .failure(let error):
                ContentUnavailableView("无法打开录音库", systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(error.localizedDescription))
            }
    }
}
