import Foundation
import Testing
@testable import PlsInputCore

@Suite("Config")
struct ConfigTests {
    /// 仓库里的 remote/config.json，从测试文件位置往上走三层到包根。
    private static var repoConfigURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/PlsInputCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // 包根
            .appendingPathComponent("remote/config.json")
    }

    /// 在 `.default` 基础上改一个字段，用来区分不同的 balance 条目。
    private static func params(repairAmount: Int) -> BalanceParams {
        var p = BalanceParams.default
        p.repairAmount = repairAmount
        return p
    }

    @Test func builtInMatchesRepositoryFile() throws {
        let data = try Data(contentsOf: Self.repoConfigURL)
        let decoded = try RemoteConfig.decode(data)
        #expect(decoded == RemoteConfig.builtIn)
        #expect(decoded.notice == nil)
        #expect(decoded.dayOverrides.isEmpty)
        #expect(decoded.balance.count == 1)
        #expect(decoded.balance[0].applyFrom == "2026-09-15")
        #expect(decoded.balance[0].params == .default)
    }

    @Test func roundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(RemoteConfig.builtIn)
        let decoded = try RemoteConfig.decode(data)
        #expect(decoded == RemoteConfig.builtIn)
    }

    /// 平铺的参数字段确实和 applyFrom 在同一层，而不是嵌在 params 下面。
    @Test func balanceParamsAreFlattenedInJSON() throws {
        let data = try JSONEncoder().encode(RemoteConfig.builtIn)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let balance = try #require(object["balance"] as? [[String: Any]])
        #expect(balance[0]["applyFrom"] as? String == "2026-09-15")
        #expect(balance[0]["repairAmount"] as? Int == 8)
        #expect(balance[0]["params"] == nil)
        #expect(balance[0]["startSlots"] as? [Int] == [4, 5])
    }

    @Test func picksLatestApplicableBalance() {
        let config = RemoteConfig(
            schemaVersion: 1,
            configVersion: 2,
            minAppBuild: 1,
            balance: [
                BalanceEntry(applyFrom: "2026-09-15", params: Self.params(repairAmount: 1)),
                BalanceEntry(applyFrom: "2026-10-01", params: Self.params(repairAmount: 2)),
            ]
        )
        let resolver = ConfigResolver(config)
        #expect(resolver.balance(for: "2026-09-15").repairAmount == 1)
        #expect(resolver.balance(for: "2026-09-30").repairAmount == 1)
        #expect(resolver.balance(for: "2026-10-01").repairAmount == 2)
        #expect(resolver.balance(for: "2026-12-31").repairAmount == 2)
        // 没有任何一条生效时用内置默认值。
        #expect(resolver.balance(for: "2026-09-01") == .default)
    }

    @Test func balanceOrderInArrayDoesNotMatter() {
        let config = RemoteConfig(
            schemaVersion: 1,
            configVersion: 2,
            minAppBuild: 1,
            balance: [
                BalanceEntry(applyFrom: "2026-10-01", params: Self.params(repairAmount: 2)),
                BalanceEntry(applyFrom: "2026-09-15", params: Self.params(repairAmount: 1)),
            ]
        )
        let resolver = ConfigResolver(config)
        #expect(resolver.balance(for: "2026-09-30").repairAmount == 1)
        #expect(resolver.balance(for: "2026-10-01").repairAmount == 2)
    }

    /// applyFrom 并列时取数组里最后一条。
    @Test func tiesTakeTheLastEntry() {
        let config = RemoteConfig(
            schemaVersion: 1,
            configVersion: 2,
            minAppBuild: 1,
            balance: [
                BalanceEntry(applyFrom: "2026-09-15", params: Self.params(repairAmount: 1)),
                BalanceEntry(applyFrom: "2026-09-15", params: Self.params(repairAmount: 9)),
            ]
        )
        #expect(ConfigResolver(config).balance(for: "2026-09-20").repairAmount == 9)
    }

    @Test func emptyBalanceFallsBackToDefault() {
        let config = RemoteConfig(schemaVersion: 1, configVersion: 1, minAppBuild: 1, balance: [])
        #expect(ConfigResolver(config).balance(for: "2026-09-15") == .default)
    }

    @Test func seedSaltUsesDayOverride() {
        let config = RemoteConfig(
            schemaVersion: 1,
            configVersion: 1,
            minAppBuild: 1,
            balance: [],
            dayOverrides: [
                "2026-09-30": DayOverride(seedSalt: "-alt1"),
                "2026-10-02": DayOverride(seedSalt: nil),
            ]
        )
        let resolver = ConfigResolver(config)
        #expect(resolver.seedSalt(for: "2026-09-30") == "-alt1")
        #expect(resolver.seedSalt(for: "2026-09-29") == "")
        // 有这一天但 seedSalt 是 null，同样当作没有盐。
        #expect(resolver.seedSalt(for: "2026-10-02") == "")
    }

    @Test func requiresUpdateComparesBuildNumber() {
        let config = RemoteConfig(schemaVersion: 1, configVersion: 1, minAppBuild: 12, balance: [])
        let resolver = ConfigResolver(config)
        #expect(resolver.requiresUpdate(appBuild: 11))
        #expect(!resolver.requiresUpdate(appBuild: 12))
        #expect(!resolver.requiresUpdate(appBuild: 13))
    }

    /// 语言匹配：先精确、再按 "-" 前的前缀。本实现不区分简繁，
    /// "zh-Hant-TW" 归一化成 "zh" 后一样命中 "zh-Hans"。
    @Test func noticeMatchesPreferredLanguage() {
        let config = RemoteConfig(
            schemaVersion: 1,
            configVersion: 1,
            minAppBuild: 1,
            notice: ["zh-Hans": "中文公告", "en": "English notice"],
            balance: []
        )
        let resolver = ConfigResolver(config)
        #expect(resolver.notice(preferredLanguages: ["zh-Hans-CN"]) == "中文公告")
        #expect(resolver.notice(preferredLanguages: ["zh-Hans"]) == "中文公告")
        #expect(resolver.notice(preferredLanguages: ["zh"]) == "中文公告")
        #expect(resolver.notice(preferredLanguages: ["zh-Hant-TW"]) == "中文公告")
        #expect(resolver.notice(preferredLanguages: ["en-US"]) == "English notice")
        // 没有任何 fr 键，回落到 en。
        #expect(resolver.notice(preferredLanguages: ["fr"]) == "English notice")
        #expect(resolver.notice(preferredLanguages: []) == "English notice")
        // 偏好列表按顺序优先。
        #expect(resolver.notice(preferredLanguages: ["fr", "zh-Hans"]) == "中文公告")
    }

    @Test func noticeFallsBackToAnyNonEmptyValue() {
        let config = RemoteConfig(
            schemaVersion: 1,
            configVersion: 1,
            minAppBuild: 1,
            notice: ["ja": "お知らせ", "de": ""],
            balance: []
        )
        let resolver = ConfigResolver(config)
        #expect(resolver.notice(preferredLanguages: ["fr"]) == "お知らせ")
        // 空串不算有公告，不会被当成 de 的匹配结果。
        #expect(resolver.notice(preferredLanguages: ["de"]) == "お知らせ")
    }

    @Test func noticeIsNilWhenMissingOrEmpty() {
        let none = RemoteConfig(schemaVersion: 1, configVersion: 1, minAppBuild: 1, notice: nil, balance: [])
        #expect(ConfigResolver(none).notice(preferredLanguages: ["zh-Hans"]) == nil)

        let allEmpty = RemoteConfig(
            schemaVersion: 1,
            configVersion: 1,
            minAppBuild: 1,
            notice: ["zh-Hans": "", "en": ""],
            balance: []
        )
        #expect(ConfigResolver(allEmpty).notice(preferredLanguages: ["zh-Hans"]) == nil)
        #expect(ConfigResolver(allEmpty).notice(preferredLanguages: ["en"]) == nil)
    }

    @Test func decodeRejectsNewerSchema() throws {
        let json = """
        {
          "schemaVersion": 2,
          "configVersion": 5,
          "minAppBuild": 1,
          "notice": null,
          "balance": [],
          "dayOverrides": {}
        }
        """
        #expect(throws: ConfigError.unsupportedSchema(2)) {
            _ = try RemoteConfig.decode(Data(json.utf8))
        }
    }

    /// dayOverrides 缺省时当作空字典，notice 可以整条缺省。
    @Test func decodeToleratesMissingOptionalFields() throws {
        let json = """
        {
          "schemaVersion": 1,
          "configVersion": 3,
          "minAppBuild": 7,
          "balance": []
        }
        """
        let config = try RemoteConfig.decode(Data(json.utf8))
        #expect(config.configVersion == 3)
        #expect(config.minAppBuild == 7)
        #expect(config.notice == nil)
        #expect(config.dayOverrides.isEmpty)
    }
}
