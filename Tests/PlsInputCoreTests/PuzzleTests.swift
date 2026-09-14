import Foundation
import Testing
@testable import PlsInputCore

@Suite("Puzzle")
struct PuzzleTests {

    // MARK: - 种子与日历

    @Test func fnv1aKnownVectors() {
        #expect(PuzzleSeed.hash("") == 0xcbf2_9ce4_8422_2325)
        #expect(PuzzleSeed.hash("a") == 0xaf63_dc4c_8601_ec8c)
        #expect(PuzzleSeed.hash("foobar") == 0x8594_4171_f739_67e8)
    }

    @Test func dailySeedFormat() {
        #expect(PuzzleSeed.daily(day: "2026-09-14") == "PlsInput-v1-2026-09-14")
        #expect(PuzzleSeed.daily(day: "2026-09-30", salt: "-alt1") == "PlsInput-v1-2026-09-30-alt1")
    }

    @Test func practiceSeedFormat() {
        var rng = SplitMix64(seed: 42)
        let seed = PuzzleSeed.practice(using: &rng)
        let prefix = "PlsInput-practice-"
        #expect(seed.hasPrefix(prefix))
        let hex = seed.dropFirst(prefix.count)
        #expect(hex.count == 16)
        #expect(hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        // 同一生成器状态必产生同一个练习种子。
        var replay = SplitMix64(seed: 42)
        #expect(PuzzleSeed.practice(using: &replay) == seed)
        // 生成器继续推进就会给出不同的种子。
        #expect(PuzzleSeed.practice(using: &rng) != seed)
    }

    @Test func dayStringCrossesBeijingMidnight() {
        // 2026-09-14T15:59:59Z 是北京时间 2026-09-14 23:59:59，还算前一天的题。
        #expect(PuzzleCalendar.dayString(for: Date(timeIntervalSince1970: 1_789_401_599)) == "2026-09-14")
        // 2026-09-14T16:00:00Z 是北京时间 2026-09-15 00:00:00，换题。
        #expect(PuzzleCalendar.dayString(for: Date(timeIntervalSince1970: 1_789_401_600)) == "2026-09-15")
        #expect(PuzzleCalendar.timeZone.identifier == "Asia/Shanghai")
    }

    // MARK: - 确定性

    @Test func sameSeedSamePuzzle() {
        for index in 0..<50 {
            let seed = "PlsInput-v1-test-\(index)"
            #expect(PuzzleGenerator.generate(seed: seed) == PuzzleGenerator.generate(seed: seed))
        }
    }

    @Test func differentSeedsDifferentPuzzles() {
        var seen = Set<DailyPuzzle>()
        for index in 0..<100 {
            seen.insert(PuzzleGenerator.generate(seed: "PlsInput-v1-test-\(index)"))
        }
        #expect(seen.count == 100)
    }

    // MARK: - 生成约束

    @Test func constraintsHoldAcrossManySeeds() {
        let balance = BalanceParams.default
        var problems: [String] = []
        func check(_ condition: Bool, _ message: @autoclosure () -> String) {
            if !condition, problems.count < 20 { problems.append(message()) }
        }

        for index in 0..<10_000 {
            let seed = "PlsInput-v1-test-\(index)"
            let puzzle = PuzzleGenerator.generate(seed: seed, balance: balance)

            // 格子
            check(balance.startSlots.contains(puzzle.slots.count), "\(seed) 格子数 \(puzzle.slots.count)")
            let specials = puzzle.slots.filter { $0 != .normal }
            check(specials.count <= 1, "\(seed) 特殊格 \(specials)")
            check(!puzzle.slots.contains(.echo), "\(seed) 起手出现回声格")

            // 键
            let digits = puzzle.keys.filter { $0.symbol.isDigit }
            let ops = puzzle.keys.filter { !$0.symbol.isDigit }
            check(balance.digitKeys.contains(digits.count), "\(seed) 数字键 \(digits.count)")
            check(digits.count >= 2, "\(seed) 数字键不足两个")
            check(balance.opKeys.contains(ops.count), "\(seed) 运算符键 \(ops.count)")
            check(
                ops.allSatisfy { [.plus, .times, .pow].contains($0.symbol) },
                "\(seed) 出现了非法的起手运算符 \(ops.map(\.symbol))"
            )
            check(
                ops.contains { $0.symbol == .plus || $0.symbol == .times },
                "\(seed) 起手没有 + 或 ×"
            )
            check(
                Set(puzzle.keys.map(\.symbol)).count == puzzle.keys.count,
                "\(seed) 起手键有重复 \(puzzle.keys.map(\.symbol))"
            )
            check(
                puzzle.keys.map(\.symbol.sortOrder) == puzzle.keys.map(\.symbol.sortOrder).sorted(),
                "\(seed) 键未按 sortOrder 排序"
            )

            // 耐久
            check(
                puzzle.keys.allSatisfy { balance.keyDurability.contains($0.uses) },
                "\(seed) 单键耐久越界 \(puzzle.keys.map(\.uses))"
            )
            let total = puzzle.keys.reduce(0) { $0 + $1.uses }
            check(balance.totalDurability.contains(total), "\(seed) 总耐久 \(total)")

            // 腐烂与上限
            check(balance.rotInterval.contains(puzzle.rotInterval), "\(seed) 腐烂间隔 \(puzzle.rotInterval)")
            check(puzzle.runCapSeconds == balance.runCapSeconds, "\(seed) 局时上限不一致")
            check(puzzle.inventoryCap == 3, "\(seed) 背包上限 \(puzzle.inventoryCap)")

            // 阈值
            check(puzzle.thresholds.count == balance.thresholds.count, "\(seed) 阈值数量")
            check(puzzle.rewards.count == puzzle.thresholds.count, "\(seed) 奖励与阈值不等长")
            for tier in 1..<puzzle.thresholds.count {
                check(
                    puzzle.thresholds[tier - 1] < puzzle.thresholds[tier],
                    "\(seed) 阈值非严格递增于第 \(tier) 档"
                )
            }

            // 奖励
            var owned = Set(puzzle.keys.map(\.symbol))
            var firstTwoUnlocksPowerOrFactorial = false
            for (tier, reward) in puzzle.rewards.enumerated() {
                switch reward {
                case .unlockKeys(let defs):
                    check(!defs.isEmpty, "\(seed) 第 \(tier) 档解锁了空的键组")
                    for def in defs {
                        check(
                            !owned.contains(def.symbol),
                            "\(seed) 第 \(tier) 档重复解锁 \(def.symbol)"
                        )
                        check(
                            (def.symbol == .factorial ? balance.factorialUses : balance.keyDurability).contains(def.uses),
                            "\(seed) 第 \(tier) 档解锁键耐久 \(def.uses) 越界"
                        )
                        owned.insert(def.symbol)
                    }
                    // 括号必须成对送出。
                    let symbols = Set(defs.map(\.symbol))
                    check(
                        symbols.contains(.lparen) == symbols.contains(.rparen),
                        "\(seed) 第 \(tier) 档括号没有成对出现"
                    )
                    if tier <= 1, defs.count == 1, defs[0].symbol == .pow || defs[0].symbol == .factorial {
                        firstTwoUnlocksPowerOrFactorial = true
                    }
                case .addSlot(let choices):
                    check((2...3).contains(choices.count), "\(seed) 第 \(tier) 档加格候选 \(choices.count) 个")
                    check(Set(choices).count == choices.count, "\(seed) 第 \(tier) 档加格候选重复")
                    check(
                        choices == SlotKind.allCases.filter { choices.contains($0) },
                        "\(seed) 第 \(tier) 档加格候选未按固定顺序排列"
                    )
                case .convertSlot(let kind):
                    check(kind != .normal, "\(seed) 第 \(tier) 档改格目标是普通格")
                case .repair(let amount):
                    check(amount == balance.repairAmount, "\(seed) 第 \(tier) 档修键量 \(amount)")
                case .freeze(let seconds):
                    check(seconds == balance.freezeSeconds, "\(seed) 第 \(tier) 档冻结时长 \(seconds)")
                }
            }
            check(firstTwoUnlocksPowerOrFactorial, "\(seed) T1/T2 没有解锁 ^ 或 !")
        }

        #expect(problems.isEmpty, "\(problems.prefix(20))")
    }

    /// 五种奖励、五种格子类型在一万个种子里都出现过，说明权重分支都活着。
    @Test func allRewardKindsAppear() {
        var rewardKinds = Set<String>()
        var slotKinds = Set<SlotKind>()
        for index in 0..<10_000 {
            let puzzle = PuzzleGenerator.generate(seed: "PlsInput-v1-test-\(index)")
            for kind in puzzle.slots { slotKinds.insert(kind) }
            for reward in puzzle.rewards {
                switch reward {
                case .unlockKeys: rewardKinds.insert("unlockKey")
                case .addSlot(let choices):
                    rewardKinds.insert("addSlot")
                    for kind in choices { slotKinds.insert(kind) }
                case .convertSlot(let kind):
                    rewardKinds.insert("convertSlot")
                    slotKinds.insert(kind)
                case .repair: rewardKinds.insert("repair")
                case .freeze: rewardKinds.insert("freeze")
                }
            }
        }
        #expect(rewardKinds == ["unlockKey", "addSlot", "convertSlot", "repair", "freeze"])
        #expect(slotKinds == Set(SlotKind.allCases))
    }

    /// 校准后的规则：起手永远没有 `^` 和 `!`；T1 必解锁 `^`；`!` 最早在第 4 档出现且耐久走低区间。
    @Test func unlockRulesAfterCalibration() {
        let balance = BalanceParams.default
        var failures: [String] = []
        for index in 0..<10_000 {
            let seed = "PlsInput-v1-test-\(index)"
            let puzzle = PuzzleGenerator.generate(seed: seed)
            if puzzle.keys.contains(where: { $0.symbol == .pow || $0.symbol == .factorial }) {
                failures.append("\(seed) 起手带了 ^ 或 !")
            }
            if case .unlockKeys(let defs) = puzzle.rewards[0], defs.count == 1, defs[0].symbol == .pow,
               balance.keyDurability.contains(defs[0].uses) {
                // ok
            } else {
                failures.append("\(seed) T1 不是解锁 ^")
            }
            for (tier, reward) in puzzle.rewards.enumerated() {
                guard case .unlockKeys(let defs) = reward, defs.contains(where: { $0.symbol == .factorial }) else { continue }
                if tier < 3 { failures.append("\(seed) 第 \(tier + 1) 档就解锁了 !") }
                if !balance.factorialUses.contains(defs[0].uses) { failures.append("\(seed) ! 的耐久 \(defs[0].uses) 越界") }
            }
            if failures.count >= 10 { break }
        }
        #expect(failures.isEmpty, "\(failures)")
    }

    // MARK: - 序列化

    @Test func codableRoundTrip() throws {
        let puzzle = PuzzleGenerator.generate(seed: PuzzleSeed.daily(day: "2026-09-15"))
        let data = try JSONEncoder().encode(puzzle)
        let restored = try JSONDecoder().decode(DailyPuzzle.self, from: data)
        #expect(restored == puzzle)
    }
}
