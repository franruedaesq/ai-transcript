import SwiftUI

struct RecorderGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.blue)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.72), lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == RecorderGlassButtonStyle {
    static var recorderGlass: RecorderGlassButtonStyle { RecorderGlassButtonStyle() }
}
