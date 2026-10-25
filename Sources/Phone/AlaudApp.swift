import SwiftUI

@main
struct AlaudApp: App {
    var body: some Scene {
        WindowGroup {
            switch AppRuntime.result {
            case .success(let model): InboxView(model: model).tint(.alaudAccent)
            case .failure(let error):
                ContentUnavailableView("无法打开录音库", systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(error.localizedDescription))
            }
        }
    }
}

extension Color {
    static let alaudAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.48, green: 0.78, blue: 0.70, alpha: 1)
            : UIColor(red: 0.16, green: 0.42, blue: 0.39, alpha: 1)
    })
    static let alaudButton = Color(red: 0.16, green: 0.42, blue: 0.39)
}

func audioClock(_ seconds: TimeInterval) -> String {
    let value = max(0, Int(seconds))
    return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
        : String(format: "%02d:%02d", value / 60, value % 60)
}
