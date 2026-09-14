import Foundation

/// 题日历：题日按 `Asia/Shanghai` 的自然日切分（设计文档 4.1）。
public enum PuzzleCalendar {
    /// 全局唯一的题日时区，排行榜重置时间与它一致。
    public static let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    /// 该时刻所属的题日，格式 `yyyy-MM-dd`。
    ///
    /// 用公历日历直接取年月日再拼字符串，不走 `DateFormatter`，
    /// 这样结果不受设备语言、日历偏好、格式化器区域设置影响。
    public static func dayString(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0
        let month = parts.month ?? 1
        let day = parts.day ?? 1
        return "\(pad(year, width: 4))-\(pad(month, width: 2))-\(pad(day, width: 2))"
    }

    /// 左补零，只处理非负整数（题日不会出现公元前）。
    private static func pad(_ value: Int, width: Int) -> String {
        let text = String(max(value, 0))
        if text.count >= width { return text }
        return String(repeating: "0", count: width - text.count) + text
    }
}

/// 种子字符串的构造与散列（设计文档 4.1）。
public enum PuzzleSeed {
    /// 每日题种子：`PlsInput-v1-<yyyy-MM-dd><salt>`。
    /// `salt` 来自远程配置的 `dayOverrides`，用于替换一道坏题。
    public static func daily(day: String, salt: String = "") -> String {
        "PlsInput-v1-\(day)\(salt)"
    }

    /// 练习模式种子：`PlsInput-practice-<16 位十六进制>`。
    public static func practice(using generator: inout some RandomNumberGenerator) -> String {
        let bits = generator.next()
        var hex = String(bits, radix: 16, uppercase: false)
        if hex.count < 16 {
            hex = String(repeating: "0", count: 16 - hex.count) + hex
        }
        return "PlsInput-practice-\(hex)"
    }

    /// FNV-1a 64 位散列，作用于种子的 UTF-8 字节，结果喂给 `SplitMix64`。
    public static func hash(_ seed: String) -> UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }
        return value
    }
}
