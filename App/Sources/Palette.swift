import SwiftUI
import PlsInputCore

enum Palette {
    static let background = Color(red: 0.06, green: 0.07, blue: 0.09)
    static let panel = Color(red: 0.11, green: 0.12, blue: 0.15)
    static let tile = Color(red: 0.17, green: 0.18, blue: 0.22)
    static let tileRaised = Color(red: 0.22, green: 0.23, blue: 0.28)
    static let text = Color.white
    static let dim = Color.white.opacity(0.55)
    static let accent = Color(red: 1.0, green: 0.78, blue: 0.25)
    static let stable = Color(red: 0.35, green: 0.62, blue: 1.0)
    static let echo = Color(red: 0.72, green: 0.55, blue: 1.0)
    static let amp = Color(red: 1.0, green: 0.55, blue: 0.2)
    static let rotten = Color(red: 0.55, green: 0.75, blue: 0.3)
    static let freeze = Color(red: 0.55, green: 0.85, blue: 1.0)
    static let danger = Color(red: 1.0, green: 0.35, blue: 0.35)

    static func color(for kind: SlotKind) -> Color {
        switch kind {
        case .normal: return Color.white.opacity(0.18)
        case .stable: return stable
        case .echo: return echo
        case .amp: return amp
        case .rotten: return rotten
        }
    }

    /// 数字越烂颜色越警告。
    static func digitColor(_ value: Int?) -> Color {
        guard let value else { return text }
        switch value {
        case 7...: return text
        case 4...6: return accent
        case 1...3: return amp
        default: return danger
        }
    }
}
