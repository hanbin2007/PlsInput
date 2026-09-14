import Testing
@testable import PlsInputCore

/// 端到端场景：用真实种子跑一遍关键交互，作为回归。
/// 2026-09-15：格子 [普通, 烂, 普通, 普通]，键 3 4 5 + ×，
/// 奖励 T1 解锁^ T2 冻结 T3 解锁() T4 改格增幅 T5 加格(稳定/增幅) T6 加格(增幅/烂)。
@Suite("Scenario")
struct ScenarioTests {
    @Test func seed20260915RewardFlow() {
        let p = PuzzleGenerator.generate(seed: "PlsInput-v1-2026-09-15")
        var s = RunState(puzzle: p)
        #expect(!p.keys.contains { $0.symbol == .pow })
        let five = p.keys.firstIndex { $0.symbol == .digit(5) }!

        // 5555 → 跨 T1，解锁 ^
        for _ in 0..<4 { s.apply(.pressKey(five)) }
        #expect(s.currentValue == BigNum(5555))
        #expect(s.crossedTiers == 1)
        let pow = s.keys.firstIndex { $0.symbol == .pow }!
        #expect(s.keys[pow].uses == 8)

        // 把烂格里的 5 换成 ^：5^55 ≈ 2.8e38，跨 T2 冻结、T3 括号、T4 改格
        s.apply(.selectSlot(1))
        s.apply(.pressKey(pow))
        #expect(s.currentValue == BigNum(5).power(BigNum(55)))
        #expect(s.crossedTiers == 4)
        #expect(s.inventory == [.freeze(seconds: 10)])
        #expect(s.keys.contains { $0.symbol == .lparen } && s.keys.contains { $0.symbol == .rparen })
        #expect(s.currentChoice == .convertSlot(.amp))

        // 末位改成增幅：5^510 ≈ 3e356，跨 T5 加格
        s.apply(.chooseConvertSlot(3))
        #expect(s.currentValue == BigNum(5).power(BigNum(510)))
        #expect(s.crossedTiers == 5)
        #expect(s.currentChoice == .addSlot(choices: [.stable, .amp]))

        // 加一个增幅格到末尾并填 5：5^51010 ≈ 10^35655，跨 T6 加格
        s.apply(.chooseAddSlot(kind: .amp, position: 4))
        #expect(s.slots.count == 5)
        s.apply(.pressKey(five))
        #expect(s.currentValue == BigNum(5).power(BigNum(51010)))
        #expect(s.crossedTiers == 6)
        #expect(s.currentChoice == .addSlot(choices: [.amp, .rotten]))
        s.apply(.chooseAddSlot(kind: .rotten, position: 0))
        #expect(s.pendingChoices.isEmpty)
        #expect(s.slots.count == 6)
        #expect(s.peak == BigNum(5).power(BigNum(51010)))
    }
}
