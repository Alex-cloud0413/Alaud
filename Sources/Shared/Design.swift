import SwiftUI

extension Color {
    static let alaudAccent = Color.primary
    static let alaudButton = Color.primary
    static var alaudPaper: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #elseif os(watchOS)
        Color.black
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
    static var alaudWash: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #elseif os(watchOS)
        Color.white.opacity(0.1)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
    static let alaudLine = Color.primary.opacity(0.09)
}

struct AlaudMark: View {
    var size: CGFloat = 36
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27).fill(Color.primary)
            AlaudGlyph().stroke(Color.alaudPaper, style: StrokeStyle(lineWidth: size * 0.072, lineCap: .round, lineJoin: .round))
                .padding(size * 0.2)
            AlaudWave().stroke(Color.alaudPaper, style: StrokeStyle(lineWidth: size * 0.032, lineCap: .round))
                .padding(size * 0.2)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

private struct AlaudGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y) }
        p.move(to: point(0.05, 0.9)); p.addLine(to: point(0.41, 0.12))
        p.addQuadCurve(to: point(0.59, 0.12), control: point(0.5, -0.07)); p.addLine(to: point(0.95, 0.9))
        return p
    }
}

private struct AlaudWave: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (x, height) in [(CGFloat(0.39), CGFloat(0.10)), (0.5, 0.24), (0.61, 0.10)] {
            path.move(to: CGPoint(x: rect.width * x, y: rect.height * (0.64 - height / 2)))
            path.addLine(to: CGPoint(x: rect.width * x, y: rect.height * (0.64 + height / 2)))
        }
        return path
    }
}

struct InkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).foregroundStyle(Color.alaudPaper)
            .padding(.horizontal, 22).padding(.vertical, 17).frame(maxWidth: .infinity)
            .background(Color.primary.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 16))
    }
}

func audioClock(_ seconds: TimeInterval) -> String {
    let value = max(0, Int(seconds))
    return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
        : String(format: "%02d:%02d", value / 60, value % 60)
}

extension View {
    @ViewBuilder func alaudInlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
