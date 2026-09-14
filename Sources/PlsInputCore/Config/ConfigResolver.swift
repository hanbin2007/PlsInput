import Foundation

/// 远程配置相关的错误。
public enum ConfigError: Error, Equatable {
    /// 配置声明的 schemaVersion 高于客户端支持的版本。
    case unsupportedSchema(Int)
}

/// 把一份 `RemoteConfig` 按设计文档 6.3 节的规则解释成具体某一题日的取值。
public struct ConfigResolver: Sendable {
    public let config: RemoteConfig

    public init(_ config: RemoteConfig) {
        self.config = config
    }

    /// 取 `applyFrom` 不晚于题日的最新一条平衡参数。
    ///
    /// 日期都是 yyyy-MM-dd，定长且字段按高位到低位排列，字符串比较即日期比较。
    /// `applyFrom` 相同时取数组里靠后的一条；一条都不适用时回落到内置默认值。
    public func balance(for day: String) -> BalanceParams {
        var best: BalanceEntry?
        for entry in config.balance where entry.applyFrom <= day {
            if let current = best, entry.applyFrom < current.applyFrom { continue }
            // 相等也覆盖，于是并列时留下数组里最后一条。
            best = entry
        }
        return best?.params ?? .default
    }

    /// 题日的种子盐，没有覆盖时是空串（见设计文档 4.1 节）。
    public func seedSalt(for day: String) -> String {
        config.dayOverrides[day]?.seedSalt ?? ""
    }

    /// 当前构建号低于 `minAppBuild` 时需要提示更新并禁用每日模式。
    public func requiresUpdate(appBuild: Int) -> Bool {
        appBuild < config.minAppBuild
    }

    /// 按用户的语言偏好挑一条公告。
    ///
    /// 匹配顺序（空串一律当作"没有文案"跳过）：
    /// 1. 按偏好顺序精确匹配键，例如 "zh-Hans" 命中键 "zh-Hans"；
    /// 2. 按偏好顺序做前缀匹配：两边都截取第一个 "-" 之前的部分再比较。
    ///    因此 "zh-Hans-CN" 和 "zh-Hant-TW" 都归一化成 "zh"，都会命中键 "zh-Hans"，
    ///    也就是说本实现不区分简繁——只要有 "zh" 开头的键就给它。
    ///    同一前缀有多个键时取字典序最小的那个，保证结果稳定。
    /// 3. 回落到键 "en"；
    /// 4. 再回落到任意一条非空文案（同样按键的字典序取第一条）。
    /// 全部为空或 `notice` 为 nil 时返回 nil。
    public func notice(preferredLanguages: [String]) -> String? {
        guard let notice = config.notice else { return nil }
        let available = notice.filter { !$0.value.isEmpty }
        guard !available.isEmpty else { return nil }

        for language in preferredLanguages {
            if let text = available[language] { return text }
        }

        for language in preferredLanguages {
            let prefix = Self.languagePrefix(language)
            let match = available.keys
                .filter { Self.languagePrefix($0) == prefix }
                .sorted()
                .first
            if let match { return available[match] }
        }

        if let english = available["en"] { return english }

        return available.keys.sorted().first.flatMap { available[$0] }
    }

    /// 取第一个 "-" 之前的部分，"zh-Hans-CN" → "zh"。
    private static func languagePrefix(_ code: String) -> Substring {
        code[code.startIndex..<(code.firstIndex(of: "-") ?? code.endIndex)]
    }
}
