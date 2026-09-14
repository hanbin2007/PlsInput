import Foundation

/// 远程配置里 `balance` 数组的一条。
///
/// JSON 里平衡参数是和 `applyFrom` 平铺在同一层的（见设计文档 6.2 节），
/// 所以这里手写 Codable：`applyFrom` 从 keyed container 取，`params` 交给
/// `BalanceParams` 在同一个 decoder 上解析。
public struct BalanceEntry: Codable, Sendable, Hashable {
    /// 生效日期，yyyy-MM-dd。
    public var applyFrom: String
    public var params: BalanceParams

    public init(applyFrom: String, params: BalanceParams) {
        self.applyFrom = applyFrom
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case applyFrom
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.applyFrom = try container.decode(String.self, forKey: .applyFrom)
        self.params = try BalanceParams(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(applyFrom, forKey: .applyFrom)
        try params.encode(to: encoder)
    }
}

/// 单日覆盖。第一版只支持换种子盐，用来替换一道坏题。
public struct DayOverride: Codable, Sendable, Hashable {
    public var seedSalt: String?

    public init(seedSalt: String? = nil) {
        self.seedSalt = seedSalt
    }
}

/// 远程配置的完整结构，对应设计文档 6.2 节的 schemaVersion 1。
public struct RemoteConfig: Codable, Sendable, Hashable {
    public var schemaVersion: Int
    public var configVersion: Int
    /// 小于此构建号的客户端需要更新。
    public var minAppBuild: Int
    /// 语言代码 → 公告文案；JSON 里允许是 null。
    public var notice: [String: String]?
    public var balance: [BalanceEntry]
    /// 题日（yyyy-MM-dd）→ 覆盖项；JSON 里缺省时视为空。
    public var dayOverrides: [String: DayOverride]

    public init(
        schemaVersion: Int,
        configVersion: Int,
        minAppBuild: Int,
        notice: [String: String]? = nil,
        balance: [BalanceEntry],
        dayOverrides: [String: DayOverride] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.configVersion = configVersion
        self.minAppBuild = minAppBuild
        self.notice = notice
        self.balance = balance
        self.dayOverrides = dayOverrides
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, configVersion, minAppBuild, notice, balance, dayOverrides
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.configVersion = try container.decode(Int.self, forKey: .configVersion)
        self.minAppBuild = try container.decode(Int.self, forKey: .minAppBuild)
        self.notice = try container.decodeIfPresent([String: String].self, forKey: .notice)
        self.balance = try container.decode([BalanceEntry].self, forKey: .balance)
        self.dayOverrides = try container.decodeIfPresent([String: DayOverride].self, forKey: .dayOverrides) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(configVersion, forKey: .configVersion)
        try container.encode(minAppBuild, forKey: .minAppBuild)
        try container.encode(notice, forKey: .notice)
        try container.encode(balance, forKey: .balance)
        try container.encode(dayOverrides, forKey: .dayOverrides)
    }

    /// 客户端支持的最高 schema 版本。
    public static let supportedSchemaVersion = 1

    /// 内置默认配置，与仓库 `remote/config.json` 的初版逐字段相等（有测试保证）。
    public static let builtIn = RemoteConfig(
        schemaVersion: 1,
        configVersion: 1,
        minAppBuild: 1,
        notice: nil,
        balance: [BalanceEntry(applyFrom: "2026-09-15", params: .default)],
        dayOverrides: [:]
    )

    /// 解析远程配置。schema 版本高于客户端支持的版本时直接拒绝，不做部分解析。
    public static func decode(_ data: Data) throws -> RemoteConfig {
        let decoder = JSONDecoder()
        let probe = try decoder.decode(SchemaProbe.self, from: data)
        guard probe.schemaVersion <= supportedSchemaVersion else {
            throw ConfigError.unsupportedSchema(probe.schemaVersion)
        }
        return try decoder.decode(RemoteConfig.self, from: data)
    }

    /// 只取 schemaVersion，用于在完整解析前做版本闸门。
    private struct SchemaProbe: Decodable {
        var schemaVersion: Int
    }
}
