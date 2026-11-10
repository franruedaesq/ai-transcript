import SwiftUI

enum AppLayoutMode: Sendable {
    case phone
    case pad
}

private struct AppLayoutModeKey: EnvironmentKey {
    static let defaultValue: AppLayoutMode = .phone
}

extension EnvironmentValues {
    var appLayoutMode: AppLayoutMode {
        get { self[AppLayoutModeKey.self] }
        set { self[AppLayoutModeKey.self] = newValue }
    }
}
