import SwiftUI

nonisolated enum AppAccent: String, CaseIterable, Sendable {
    case mint, blue, cyan, purple, pink, orange
    var label: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .mint: Color(red: 0.27, green: 0.89, blue: 0.66)
        case .blue: Color(red: 0.36, green: 0.65, blue: 1)
        case .cyan: Color(red: 0.25, green: 0.85, blue: 0.95)
        case .purple: Color(red: 0.73, green: 0.56, blue: 1)
        case .pink: Color(red: 1, green: 0.46, blue: 0.67)
        case .orange: Color(red: 1, green: 0.65, blue: 0.32)
        }
    }
}

nonisolated private struct InverterAccentKey: EnvironmentKey {
    static let defaultValue = AppAccent.mint.color
}
extension EnvironmentValues {
    var inverterAccent: Color {
        get { self[InverterAccentKey.self] }
        set { self[InverterAccentKey.self] = newValue }
    }
}
